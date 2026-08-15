#!/usr/bin/env bash
# shellcheck shell=bash
#
# .drawio を SVG / PNG などへ書き出す。既定は「カレントの *.drawio を out/ へ SVG」。
#
# ## なぜスクリプトが要るか
#
# drawio の CLI は Electron (Chromium) なので、SVG 出力であってもレンダリング
# コンテキスト (X のディスプレイ) が要る。加えて headless では大量のノイズを
# 吐き、SVG のルートは透過のまま出る。素で叩くと毎回これらを踏むので、
# 効くフラグと後処理をここに固めてある。個々の理由は
# references/troubleshooting.md に書いた。
#
# ## 依存
#
# drawio 本体・日本語フォント・仮想ディスプレイは、この skill の flake.nix が
# 持っている。PATH に drawio が無ければ自動で devShell へ入り直すので、
# 呼ぶ側は nix develop を意識しなくてよい。

set -eu -o pipefail

# ~/.claude/skills/pjp-drawio は store への symlink なので、$0 のままでは flake の
# 位置を見失う。実体まで解決してから親を取る。
skill_dir=$(
  cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." &>/dev/null
  pwd -P
)

have() {
  command -v "$1" &>/dev/null
}

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<'EOS'
usage: drawio-export.sh [options] [FILE...]

FILE を省略するとカレントディレクトリの *.drawio すべてを対象にする。

options:
  -f, --format <fmt>   svg (既定) / png / pdf / jpg
  -o, --out-dir <dir>  出力先 (既定: out)
  -s, --scale <n>      拡大率 (png / jpg 向け。例: 1.4)
      --no-white-bg    SVG に白背景を差し込まない (透過のまま出す)
      --keep-noise     Electron の無害なエラー出力を隠さない
  -h, --help           これ

例:
  drawio-export.sh                      # *.drawio -> out/*.svg (白背景)
  drawio-export.sh -f png -s 1.4        # 目視確認用の PNG
  drawio-export.sh 01_network.drawio    # 1 ファイルだけ
EOS
}

##############################
# 依存が無ければ devShell へ #
##############################

# 印を付けて 1 回だけにする (devShell に入っても揃わない場合の無限ループ防止)。
if ! have drawio; then
  if [[ -z ${DRAWIO_SKILL_REEXEC:-} ]] && have nix; then
    export DRAWIO_SKILL_REEXEC=1
    # store 上の実体を指す。symlink のままでは flake が見つからない。
    exec nix develop "path:${skill_dir}" --command "$0" "$@"
  fi
  die "drawio が見つかりません。nix があれば devShell へ自動で入り直します。
nix が無い環境では次のいずれかを:
  - nix を入れる (curl -fsSL https://install.determinate.systems/nix | sh -s -- install)
  - drawio-desktop を手で入れる (https://github.com/jgraph/drawio-desktop/releases)"
fi

############
# 引数解析 #
############

format=svg
out_dir=out
scale=
white_bg=1
keep_noise=0
inputs=()

need_value() {
  [[ $# -ge 2 ]] || die "$1 に値がありません"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -f | --format)
      need_value "$@"
      format=$2
      shift 2
      ;;
    -o | --out-dir)
      need_value "$@"
      out_dir=$2
      shift 2
      ;;
    -s | --scale)
      need_value "$@"
      scale=$2
      shift 2
      ;;
    --no-white-bg)
      white_bg=0
      shift
      ;;
    --keep-noise)
      keep_noise=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      inputs+=("$@")
      break
      ;;
    -*)
      die "知らないオプション: $1 (--help を見る)"
      ;;
    *)
      inputs+=("$1")
      shift
      ;;
  esac
done

if [[ ${#inputs[@]} -eq 0 ]]; then
  shopt -s nullglob
  inputs=(./*.drawio)
  shopt -u nullglob
fi

[[ ${#inputs[@]} -gt 0 ]] || die "対象の .drawio がありません ($(pwd))"

######################
# ディスプレイの用意 #
######################

# 使えるディスプレイが既にあるならそれを使い、無ければ xvfb-run で作る。
#
# **順序が重要。** WSL2 (WSLg) では xvfb を先に試すと失敗する: /tmp/.X11-unix が
# read-only mount かつ mode 0777 (1777 でない) なので Xvfb が socket を作れない。
#
#   _XSERVTransmkdir: Mode of /tmp/.X11-unix should be set to 1777
#
# WSLg は :0 を提供しているので、既存ディスプレイを優先すれば素通りできる。
# 逆に CI や素の headless サーバには DISPLAY が無いので xvfb-run が要る。
display_available() {
  # macOS は X を経由しない
  [[ $(uname -s) == Linux ]] || return 0
  [[ -n ${DISPLAY:-} ]] || return 1

  local num=${DISPLAY##*:}
  num=${num%%.*}
  case ${DISPLAY} in
    :* | unix:*) [[ -S "/tmp/.X11-unix/X${num}" ]] ;;
    # host:N 形式 (TCP)。手元で生死を確かめる手段が無いのでそのまま使う
    *) return 0 ;;
  esac
}

use_xvfb=0
if ! display_available; then
  have xvfb-run || die "使えるディスプレイが無く、xvfb-run もありません"
  use_xvfb=1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

# Electron は設定ディレクトリが無いと "Error: Failed to get 'appData' path" で
# 死ぬ。実 HOME を汚さないよう、毎回捨てる一時ディレクトリを渡す。
export XDG_CONFIG_HOME="${tmp_dir}/config"
mkdir -p "${XDG_CONFIG_HOME}"

run_drawio() {
  if ((use_xvfb)); then
    # --error-file を渡さないと Xvfb 側の失敗が /dev/null に消えて、
    # 「何も出ないのに exit 1」になる。--auth-file は既定が ./.Xauthority で
    # カレントを汚すので一時ディレクトリへ逃がす。
    xvfb-run --auto-display \
      --auth-file="${tmp_dir}/Xauthority" \
      --error-file=/dev/stderr \
      drawio "$@"
  else
    drawio "$@"
  fi
}

# headless では毎回出るが出力には影響しないもの。落としておくと本当のエラーが見える。
noise='dbus|Failed to call method|autoupdate|package-type|viz_main_impl'
noise+='|angle_platform_impl|egl_util|gl_display|gl_ozone_egl|gl_surface_egl'
noise+='|glXQueryExtensionsString|ANGLE Display::initialize|ERR: Display\.cpp'
noise+='|Exiting GPU process|Failed to create GLES3 context'

############
# 白背景   #
############

# drawio の SVG はルートが background: transparent のまま出る
# (mxGraphModel の background 属性は SVG に反映されない)。そのままだと
# ダークモードのビューアで下地が黒くなるので、ルート直下に全面を覆う
# 白い矩形を差し込む。sed の 0,/re/ は GNU 拡張なので awk で書いてある。
insert_white_bg() {
  local svg=$1
  local rect='<rect x="0" y="0" width="100%" height="100%" fill="#ffffff"/>'

  awk -v rect="${rect}" '
    !inserted && match($0, /<svg[^>]*>/) {
      $0 = substr($0, 1, RSTART + RLENGTH - 1) rect substr($0, RSTART + RLENGTH)
      inserted = 1
    }
    { print }
  ' "${svg}" >"${tmp_dir}/bg.svg"

  # 黙って透過のまま出すと後で気付けないので、入ったことを確かめる
  if ! grep -q 'width="100%" height="100%" fill="#ffffff"' "${tmp_dir}/bg.svg"; then
    die "白背景を差し込めませんでした (drawio の出力形式が変わった可能性): ${svg}
--no-white-bg で無効にできる"
  fi
  mv "${tmp_dir}/bg.svg" "${svg}"
}

##########
# 変換   #
##########

mkdir -p "${out_dir}"

# NOTE: --disable-gpu は付けない。古い drawio では Electron のフラグが drawio CLI
#       (commander) の引数解析に混ざり、位置引数がずれて
#       "Error: input file/directory not found" になった。30.2.6 では再現しないが、
#       GPU 関連のエラー出力はもともと無害なので付ける利点も無い
#       (references/troubleshooting.md)。
args=(
  --export
  --format "${format}"
  # 付けないと SVG ルートが color-scheme: light dark になり、
  # ダークモードのビューアで色が反転する
  --svg-theme light
  # フォント埋め込みを外す。日本語は <text> のまま残るので表示は変わらず、
  # ファイルサイズが桁で減る (実測 17KB -> 3.8KB、大きい図では MB 単位で効く)
  --embed-svg-fonts false
  --disable-update
)
[[ -z ${scale} ]] || args+=(--scale "${scale}")
# root で動かす場合だけ必要 (コンテナや CI)。付けられるフラグは最小限にする。
[[ $(id -u) -ne 0 ]] || args+=(--no-sandbox)

log="${tmp_dir}/drawio.log"
count=0

for input in "${inputs[@]}"; do
  [[ -f ${input} ]] || die "ファイルがありません: ${input}"

  base=$(basename "${input}")
  base=${base%.drawio}
  output="${out_dir}/${base}.${format}"

  echo "==> ${output}"
  if run_drawio "${args[@]}" --output "${output}" "${input}" >"${log}" 2>&1; then
    if ((keep_noise)); then
      cat "${log}"
    else
      grep -viE "${noise}" "${log}" || true
    fi
  else
    # 失敗したときはノイズも含めて全部見せる (原因がそこに混ざっている)
    cat "${log}" >&2
    die "drawio が失敗しました: ${input}"
  fi

  [[ -f ${output} ]] || die "出力が作られませんでした: ${output}"
  if [[ ${format} == svg ]] && ((white_bg)); then
    insert_white_bg "${output}"
  fi
  count=$((count + 1))
done

echo "${count} 件を ${out_dir}/ へ出力しました"
