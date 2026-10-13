#!/usr/bin/env bash
# shellcheck shell=bash
#
# D3.js / Observable Plot の chart module (*.mjs) を SVG / PNG へ書き出す。
# 既定は「カレントの *.mjs (_ で始まるものを除く) を out/ へ SVG」。
#
# ## なぜスクリプトが要るか
#
# chart module は「SVG 要素を返す関数」を default export する ES module で、単体では
# 動かない (Node には DOM が無く、プロジェクトには node_modules も無い)。
# ここで固めているのは 4 つ。
#
#   - 依存の用意 (devShell の外なら入り直す)
#   - DOM と import の解決 (lib/render.mjs。linkedom と resolve hook)
#   - 白背景と出力先を揃える
#   - PNG への変換 (resvg に日本語フォントを渡す)
#
# ## 依存
#
# node・d3・Observable Plot・linkedom・resvg・日本語フォントは、この skill の
# flake.nix が持っている。devShell が渡す PJP_D3JS_NODE_MODULES が無ければ自動で
# devShell へ入り直す。PATH に別の node (mise など) があっても、それでは走らせない
# (d3 が無いので)。

set -eu -o pipefail

# ~/.claude/skills/pjp-d3js は store への symlink なので、$0 のままでは flake の
# 位置を見失う。symlink を path: へ渡すと解決先を外部パス扱いされてこう落ちる。
#
#   error: access to absolute path '/nix/store/...' is forbidden in pure evaluation mode
#
# 実体まで解決してから親を取る。
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
usage: d3js-export.sh [options] [FILE...]

FILE を省略するとカレントディレクトリの *.mjs すべてを対象にする
(_ で始まるものは部品とみなして除く)。

options:
  -f, --format <fmt>   svg (既定) / png。カンマ区切りで両方指定できる
  -o, --out-dir <dir>  出力先 (既定: out)
  -s, --scale <n>      PNG の拡大率 (既定: 1)
      --transparent    白背景を敷かない
  -h, --help           これ

例:
  d3js-export.sh                    # *.mjs -> out/*.svg
  d3js-export.sh -f svg,png         # 目視確認用の PNG も
  d3js-export.sh -f png -s 2        # 2 倍の PNG だけ
  d3js-export.sh 01_downloads.mjs   # 1 ファイルだけ
EOS
}

# 使い方は devShell に入らずに出す。
for arg in "$@"; do
  case ${arg} in
    -h | --help)
      usage
      exit 0
      ;;
  esac
done

##############################
# 依存が無ければ devShell へ #
##############################

# 印を付けて 1 回だけにする (devShell に入っても揃わない場合の無限ループ防止)。
if [[ -z ${PJP_D3JS_NODE_MODULES:-} || -z ${PJP_D3JS_FONTS_DIR:-} ]] || ! have node || ! have resvg; then
  if [[ -z ${D3JS_SKILL_REEXEC:-} ]] && have nix; then
    export D3JS_SKILL_REEXEC=1
    # store 上の実体を指す。symlink のままでは flake が見つからない。
    exec nix develop "path:${skill_dir}" --command "$0" "$@"
  fi
  die "d3 の node_modules が見つかりません (PJP_D3JS_NODE_MODULES が空)。
nix があれば devShell へ自動で入り直します。nix が無い環境では nix を入れる:
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install"
fi

############
# 引数解析 #
############

formats=svg
out_dir=out
scale=1
transparent=0
inputs=()

need_value() {
  [[ $# -ge 2 ]] || die "$1 に値がありません"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -f | --format)
      need_value "$@"
      formats=$2
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
    --transparent)
      transparent=1
      shift
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

want_svg=0
want_png=0
IFS=',' read -ra format_list <<<"${formats}"
for fmt in "${format_list[@]}"; do
  case ${fmt} in
    svg) want_svg=1 ;;
    png) want_png=1 ;;
    '') ;;
    *) die "知らない形式: ${fmt} (svg / png)" ;;
  esac
done
((want_svg + want_png > 0)) || die "形式がありません: ${formats}"
[[ ${scale} =~ ^[0-9]+([.][0-9]+)?$ ]] || die "拡大率は正の数で: ${scale}"

if [[ ${#inputs[@]} -eq 0 ]]; then
  shopt -s nullglob
  for f in ./*.mjs; do
    # _ で始まるものは部品 (色・軸の共通化など)。書き出さない
    [[ $(basename "${f}") == _* ]] || inputs+=("${f}")
  done
  shopt -u nullglob
fi

[[ ${#inputs[@]} -gt 0 ]] || die "対象の .mjs がありません ($(pwd))"

# 出力は <out_dir>/<basename>.svg なので、別のディレクトリの同じ名前は書く前に止める。
seen=$'\n'
for input in "${inputs[@]}"; do
  [[ -f ${input} ]] || die "ファイルがありません: ${input}"
  [[ ${input} == *.mjs ]] || die ".mjs ではありません: ${input}"
  base=$(basename "${input}")
  base=${base%.mjs}
  case ${seen} in
    *$'\n'"${base}"$'\n'*) die "出力の名前がぶつかります: ${base} (${input})" ;;
  esac
  seen+="${base}"$'\n'
done

##########
# 変換   #
##########

mkdir -p "${out_dir}"

tmp_dir=$(mktemp -d)
trap 'rm -rf "${tmp_dir}"' EXIT

# PNG だけ欲しいときは、SVG を一時ディレクトリに書いてから変換する。
svg_dir=${out_dir}
if ((! want_svg)); then
  svg_dir=${tmp_dir}
fi

# 作り直すものだけ先に消す。失敗した chart module の古い出力を、新しいものと取り違えない。
for input in "${inputs[@]}"; do
  base=$(basename "${input}")
  base=${base%.mjs}
  if ((want_svg)); then
    rm -f "${out_dir}/${base}.svg"
  fi
  if ((want_png)); then
    rm -f "${out_dir}/${base}.png"
  fi
done

render_args=(--out-dir "${svg_dir}")
if ((transparent)); then
  render_args+=(--transparent)
fi

# 失敗した chart module があっても、通ったものは最後まで書き出す
# (render.mjs は失敗の理由を出して 1 で終わる)。
render_status=0
node "${skill_dir}/scripts/lib/render.mjs" "${render_args[@]}" -- "${inputs[@]}" || render_status=$?

# resvg の無害な警告。Plot の <style> にある :where() を読めない、など。
resvg_noise='is not supported\. Selector skipped'

count=0
for input in "${inputs[@]}"; do
  base=$(basename "${input}")
  base=${base%.mjs}
  svg="${svg_dir}/${base}.svg"
  # 無ければ render.mjs が失敗の理由を出している
  [[ -f ${svg} ]] || continue

  if ((want_svg)); then
    echo "==> ${out_dir}/${base}.svg"
    count=$((count + 1))
  fi

  if ((want_png)); then
    png="${out_dir}/${base}.png"
    echo "==> ${png}"
    # resvg は fontconfig を読まないので、flake のフォントのディレクトリを直に渡す。
    # font-family が無い・知らない名前 (system-ui など) のときも日本語が出るよう、
    # 既定と sans-serif を Noto Sans CJK JP にする。
    if ! resvg --use-fonts-dir "${PJP_D3JS_FONTS_DIR}" \
      --font-family "Noto Sans CJK JP" \
      --sans-serif-family "Noto Sans CJK JP" \
      --zoom "${scale}" \
      "${svg}" "${png}" 2>"${tmp_dir}/resvg.log"; then
      cat "${tmp_dir}/resvg.log" >&2
      die "resvg が失敗しました: ${svg}"
    fi
    grep -vE "${resvg_noise}" "${tmp_dir}/resvg.log" >&2 || true
    [[ -f ${png} ]] || die "出力が作られませんでした: ${png}"
    count=$((count + 1))
  fi
done

((render_status == 0)) || die "失敗した chart module があります (理由は上)"
echo "${count} 件を ${out_dir}/ へ出力しました"
