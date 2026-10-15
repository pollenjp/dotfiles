#!/usr/bin/env bash
# shellcheck shell=bash
#
# テストの先頭のコメントに「## 確かめること」があるかを確かめる。
#
#   check-test-headers.sh [--show] [<nix のパス>]
#
# 何を確かめるかは nix/README.md に写さず、各テストの先頭の「## 確かめること」にだけ書く
# (TKT-162)。見るのは <nix>/tests 直下のファイル全部と <nix>/pkgs/*/test_*.py で、先頭の
# コメントはファイルの種類で読み分ける。
#
#   *.test.sh・*.nix   1 行目から続く「#」の行
#   *.test.mjs         1 行目から続く「//」の行
#   test_*.py          module の docstring
#
# どれにも「## 確かめること」で始まる行があれば exit 0。無いテストがあれば、その名前を全部出して
# exit 1。nix/tests に読み方を知らない種類のファイルがあっても exit 1 (新しい種類のテストが
# 黙ってこの検査から外れないように)。--show は、各テストの「## 確かめること」の節 (次の ## の
# 見出しか、先頭のコメントの終わりまで) を、コメントの印を外して並べる (テストの一覧の代わり)。
#
# CI の lint ジョブが流す。<nix のパス> を省けば、この script の隣の nix/ を見る。

set -eu -o pipefail

usage() {
  echo "使い方: $(basename "$0") [--show] [<nix のパス>]" >&2
}

show=0
case ${1:-} in
  --show)
    show=1
    shift
    ;;
  -*)
    usage
    exit 2
    ;;
esac
if (($# > 1)); then
  usage
  exit 2
fi

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
nix_dir=${1:-$(dirname "${script_dir}")}

# 先頭の印を外した行 (コメントの印と、その後ろの空白 1 つまで) を出す
strip_marker() {
  local line=${1#"$2"}
  printf '%s\n' "${line# }"
}

# <file> の先頭のコメントを、コメントの印を外して 1 行ずつ出す。読み方を知らない種類なら 2 を返す
head_of() {
  local file=$1 marker line n=0 open=0
  case ${file##*/} in
    *.test.sh | *.nix) marker='#' ;;
    *.test.mjs) marker='//' ;;
    test_*.py) marker='"""' ;;
    *) return 2 ;;
  esac
  while IFS= read -r line || [[ -n ${line} ]]; do
    n=$((n + 1))
    # 1 行目の shebang は印に関わらず飛ばす
    if ((n == 1)) && [[ ${line} == '#!'* ]]; then
      continue
    fi
    if [[ ${marker} != '"""' ]]; then
      [[ ${line} == "${marker}"* ]] || return 0
      strip_marker "${line}" "${marker}"
      continue
    fi
    # module の docstring。その前に置けるのは # のコメントと空行だけ
    if ((open == 0)); then
      if [[ ${line} == '#'* || -z ${line} ]]; then
        continue
      fi
      [[ ${line} == '"""'* ]] || return 0
      line=${line#'"""'}
      open=1
    fi
    if [[ ${line} == *'"""'* ]]; then
      printf '%s\n' "${line%%'"""'*}"
      return 0
    fi
    printf '%s\n' "${line}"
  done <"${file}"
}

# 先頭のコメント (標準入力) から「## 確かめること」の節を出す。末尾の空行は落とす。無ければ何も出さない
section_of() {
  local line in=0 lines=()
  while IFS= read -r line; do
    if ((in == 0)); then
      if [[ ${line} == '## 確かめること' || ${line} == '## 確かめること '* ]]; then
        in=1
        lines+=("${line}")
      fi
      continue
    fi
    [[ ${line} == '## '* ]] && break
    lines+=("${line}")
  done
  while ((${#lines[@]} > 0)) && [[ -z ${lines[-1]//[[:space:]]/} ]]; do
    unset 'lines[-1]'
  done
  if ((${#lines[@]} > 0)); then
    printf '%s\n' "${lines[@]}"
  fi
}

files=()
for f in "${nix_dir}"/tests/* "${nix_dir}"/pkgs/*/test_*.py; do
  if [[ -f ${f} ]]; then
    files+=("${f}")
  fi
done
if ((${#files[@]} == 0)); then
  echo "!! テストが 1 つも見つかりません (${nix_dir}/tests と ${nix_dir}/pkgs/*/test_*.py)。" >&2
  exit 1
fi

base=$(basename "${nix_dir}")
missing=()
unknown=()
for f in "${files[@]}"; do
  name="${base}/${f#"${nix_dir}/"}"
  if ! head=$(head_of "${f}"); then
    unknown+=("${name}")
    continue
  fi
  section=$(section_of <<<"${head}")
  if [[ -z ${section} ]]; then
    missing+=("${name}")
    continue
  fi
  if ((show)); then
    printf '== %s\n%s\n\n' "${name}" "${section}"
  fi
done

if ((${#missing[@]} > 0)); then
  echo "!! 先頭のコメントに「## 確かめること」が無いテストがあります:" >&2
  printf '   %s\n' "${missing[@]}" >&2
  echo "   何を確かめるかを、先頭のコメント (test_*.py は module の docstring) の「## 確かめること」に" >&2
  echo "   書いてください (nix/README.md の「テスト」)。" >&2
fi
if ((${#unknown[@]} > 0)); then
  echo "!! 先頭のコメントの読み方を知らない種類のファイルが tests にあります:" >&2
  printf '   %s\n' "${unknown[@]}" >&2
  echo "   テストなら $(basename "$0") に読み方を足し、テストでなければ tests の外へ移してください。" >&2
fi
if ((${#missing[@]} > 0 || ${#unknown[@]} > 0)); then
  exit 1
fi
if ((! show)); then
  echo "テストの先頭の「## 確かめること」: ${#files[@]} 本とも書いてある"
fi
