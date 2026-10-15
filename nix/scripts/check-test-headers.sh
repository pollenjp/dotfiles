#!/usr/bin/env bash
# shellcheck shell=bash
#
# テストの先頭のコメントに「## 確かめること」があるかを確かめる。
#
#   check-test-headers.sh [--show] [<nix のパス>]
#
# 何を確かめるかは nix/README.md に写さず、各テストの先頭の「## 確かめること」にだけ書く
# (TKT-162)。見るのは <nix>/tests 直下のファイル全部と <nix>/pkgs/*/test_*.py で、先頭の
# コメントはファイルの種類で読み分ける (1 行目の shebang は飛ばす)。
#
#   *.test.sh・*.nix   1 行目から空行を挟まずに続く「#」の行
#   *.test.mjs         1 行目から空行を挟まずに続く「//」の行
#   test_*.py          module の docstring (""" で囲む。前に置けるのは # の行と空行だけ)
#
# どれにも「## 確かめること」で始まる行と、その下に空でない行があれば exit 0。無いテストがあれば、
# その名前を全部出して exit 1。nix/tests に読み方を知らない種類のファイルがあっても exit 1 (新しい
# 種類のテストが黙ってこの検査から外れないように)。--show は、各テストの「## 確かめること」の節
# (次の ## の見出しか、先頭のコメントの終わりまで) を、コメントの印を外して並べる (テストの一覧の代わり)。
#
# CI の lint ジョブが流す。<nix のパス> を省けば、この script の隣の nix/ を見る。

set -eu -o pipefail

usage() {
  cat <<'EOS'
テストの先頭のコメントに「## 確かめること」があるかを確かめる。

使い方:
  check-test-headers.sh [<nix のパス>]          確かめる (省けば、この script の隣の nix/)
  check-test-headers.sh --show [<nix のパス>]   各テストの「## 確かめること」を並べる
  check-test-headers.sh -h, --help              これ
EOS
}

show=0
nix_dir=
for arg in "$@"; do
  case ${arg} in
    --show) show=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n ${nix_dir} ]]; then
        echo "<nix のパス> は 1 つだけです: ${arg}" >&2
        usage >&2
        exit 2
      fi
      nix_dir=${arg}
      ;;
  esac
done

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
nix_dir=${nix_dir:-$(dirname "${script_dir}")}

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

# 先頭のコメント (標準入力) から「## 確かめること」の節を出す。末尾の空行は落とす。
# 見出しが無いか、見出しの下が空なら何も出さない
section_of() {
  local line found=0 lines=()
  while IFS= read -r line; do
    if ((found == 0)); then
      if [[ ${line} == '## 確かめること'* ]]; then
        found=1
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
  if ((${#lines[@]} > 1)); then
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
    # 見えているのに「無い」と言われて迷わないよう、見出しの文字がファイルにあればそう添える
    if grep -qF '## 確かめること' "${f}"; then
      name+=" (「## 確かめること」の文字はあるが、先頭のコメントの外にあるか、見出しの形が違うか、下が空)"
    fi
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
  echo "   何を確かめるかを、先頭のコメントの「## 確かめること」の下に書いてください (nix/README.md の「テスト」)。" >&2
  echo "   先頭のコメントは、1 行目 (shebang の次) から空行を挟まずに続く「#」(*.test.mjs は「//」) の行で、" >&2
  echo "   test_*.py は module の docstring です。" >&2
fi
if ((${#unknown[@]} > 0)); then
  echo "!! 先頭のコメントの読み方を知らない種類のファイルが tests にあります:" >&2
  printf '   %s\n' "${unknown[@]}" >&2
  echo "   テストなら $(basename "$0") に読み方を足し、テストでなければ tests の中のディレクトリか tests の外へ移してください。" >&2
fi
if ((${#missing[@]} > 0 || ${#unknown[@]} > 0)); then
  exit 1
fi
if ((! show)); then
  echo "テストの先頭の「## 確かめること」: ${#files[@]} 本とも書いてある"
fi
