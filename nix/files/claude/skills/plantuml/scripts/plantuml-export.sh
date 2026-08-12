#!/usr/bin/env bash
# shellcheck shell=bash
#
# .puml を SVG / PNG などへ書き出す。既定は「カレントの *.puml を out/ へ SVG」。
#
# ## なぜスクリプトが要るか
#
# plantuml を素で叩くのに比べて、ここで固めているのは 3 つ。
#
#   - 依存の用意 (PATH に無ければ devShell へ入り直す)
#   - 出力先を入力の位置に依らず一箇所へ揃える (-o は .puml からの相対で解釈される)
#   - 複数形式をまとめて出す (-f svg,png)
#
# ## 依存
#
# plantuml 本体と日本語フォントは、この skill の flake.nix が持っている。
# JDK と graphviz は nixpkgs の plantuml が同梱しているので別途要らない。
# PATH に plantuml が無ければ自動で devShell へ入り直すので、呼ぶ側は
# nix develop を意識しなくてよい。

set -eu -o pipefail

# ~/.claude/skills/plantuml は store への symlink なので、$0 のままでは flake の
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
usage: plantuml-export.sh [options] [FILE...]

FILE を省略するとカレントディレクトリの *.puml すべてを対象にする。

options:
  -f, --format <fmt>   svg (既定) / png / pdf / txt。カンマ区切りで複数指定できる
  -o, --out-dir <dir>  出力先 (既定: out)
      --transparent    背景を透過にする (既定は白背景)
  -h, --help           これ

例:
  plantuml-export.sh                    # *.puml -> out/*.svg
  plantuml-export.sh -f png             # 目視確認用の PNG
  plantuml-export.sh -f svg,png         # 両方まとめて
  plantuml-export.sh 01_auth.puml       # 1 ファイルだけ
EOS
}

##############################
# 依存が無ければ devShell へ #
##############################

# 印を付けて 1 回だけにする (devShell に入っても揃わない場合の無限ループ防止)。
if ! have plantuml; then
  if [[ -z ${PLANTUML_SKILL_REEXEC:-} ]] && have nix; then
    export PLANTUML_SKILL_REEXEC=1
    # store 上の実体を指す。symlink のままでは flake が見つからない。
    exec nix develop "path:${skill_dir}" --command "$0" "$@"
  fi
  die "plantuml が見つかりません。nix があれば devShell へ自動で入り直します。
nix が無い環境では次のいずれかを:
  - nix を入れる (curl -fsSL https://install.determinate.systems/nix | sh -s -- install)
  - plantuml と graphviz を手で入れる (java も要る)"
fi

############
# 引数解析 #
############

formats=svg
out_dir=out
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
    --transparent)
      transparent=1
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
  inputs=(./*.puml)
  shopt -u nullglob
fi

[[ ${#inputs[@]} -gt 0 ]] || die "対象の .puml がありません ($(pwd))"

for input in "${inputs[@]}"; do
  [[ -f ${input} ]] || die "ファイルがありません: ${input}"
done

##########
# 変換   #
##########

mkdir -p "${out_dir}"

# -o は **.puml からの相対** として解釈されるので、入力がサブディレクトリに
# あると出力もそこへ散らばる。絶対パスへ直して一箇所に集める。
out_abs=$(
  cd -- "${out_dir}" &>/dev/null
  pwd -P
)

args=(
  # 既定の文字コードに依らず UTF-8 で読む。JDK 18 以降は既定が UTF-8 (JEP 400)
  # なので普段は効かないが、古い JDK で動かしたときのために明示しておく
  -charset UTF-8
  # 複数ファイルを並列に処理する
  -nbthread auto
)

# PlantUML の背景は既定で白 (SVG は style="background:#FFFFFF"、PNG は
# アルファ無し)。透過が要るときだけ skinparam を上書きする。
if ((transparent)); then
  args+=(-SbackgroundColor=transparent)
fi

IFS=',' read -ra format_list <<<"${formats}"

count=0
for fmt in "${format_list[@]}"; do
  [[ -n ${fmt} ]] || continue
  echo "==> ${out_dir}/*.${fmt}"
  # plantuml は複数入力をまとめて受けられる (1 ファイルずつ JVM を起動しない)
  plantuml "${args[@]}" -t"${fmt}" -o "${out_abs}" "${inputs[@]}"

  for input in "${inputs[@]}"; do
    base=$(basename "${input}")
    base=${base%.puml}
    # txt 形式だけ拡張子が .atxt になる
    output="${out_abs}/${base}.${fmt}"
    [[ ${fmt} != txt ]] || output="${out_abs}/${base}.atxt"
    [[ -f ${output} ]] || die "出力が作られませんでした: ${output}"
    count=$((count + 1))
  done
done

echo "${count} 件を ${out_dir}/ へ出力しました"
