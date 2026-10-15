#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-test-headers.sh の振る舞いを、使い捨ての nix ディレクトリ (tests/ と pkgs/) で確かめる。
#
#   bash nix/tests/check-test-headers.test.sh [<script のパス>]
#
# flake の checks (check-test-headers-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・grep だけ。
#
# ## 確かめること
#
#   - 先頭のコメントに「## 確かめること」があれば通る。先頭のコメントは、*.test.sh と *.nix は 1 行目から
#     続く # の行、*.test.mjs は // の行、nix/pkgs/*/test_*.py は module の docstring。見出しの後ろに
#     続き (「## 確かめること (script ごと)」など) があってもよい。nix/pkgs の test_*.py でない .py は見ない
#   - 無いテストがあれば、全部の名前を出して exit 1。先頭のコメントの外 (空行やコードの後・関数の docstring)
#     の見出しと、### の見出しは数えない
#   - nix/tests に読み方を知らない種類のファイルがあれば、名前を出して exit 1。nix/tests の中のディレクトリは見ない
#   - テストが 1 つも無ければ exit 1。知らない引数は exit 2
#   - --show は、各テストの「## 確かめること」の節 (次の ## の見出しか、先頭のコメントの終わりまで) を、
#     コメントの印を外して並べる。見出しの無いテストがあれば、ほかを出したうえで exit 1
#   - script に実行ビットがある (CI の lint ジョブが ./nix/scripts/check-test-headers.sh で直に呼ぶ)

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/check-test-headers.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/check-test-headers-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

# 見出しを持つテスト (種類ごと)。見出しの節の後ろに、出してはいけない行 (次の節・コード) を置く
good_sh=$'#!/usr/bin/env bash\n# shellcheck shell=bash\n#\n# 何かを確かめる。\n#\n# ## 確かめること\n#\n#   - sh の 1 つ目\n#   - sh の 2 つ目\n#\n# ## 作り\n#\n# 作りの説明\n\nset -u\necho done'
good_nix=$'# 何かを評価時に確かめる。\n#\n# ## 確かめること\n#\n#   - nix の 1 つ目\n{ lib }:\nlib'
good_mjs=$'// 何かを確かめる。\n//\n// ## 確かめること\n//\n//   - mjs の 1 つ目\n\nimport fs from "node:fs";'
good_py=$'"""何かのテスト。\n\n## 確かめること\n\n- py の 1 つ目\n"""\n\nimport unittest'

# $1: ケースの名前。<work>/<ケース>/nix に tests/ と pkgs/ を作り、nix の場所を出す
new_nix() {
  local n="${work}/$1/nix"
  mkdir -p "${n}/tests" "${n}/pkgs"
  echo "${n}"
}

# $1: 置き先、$2: 中身
put() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >"$1"
}

# $1: nix の場所、残り: script に渡す引数 (nix の場所の前に置く)。<ケース>/out・err・rc に残す
run() {
  local n=$1 c
  c=$(dirname "${n}")
  shift
  "${BASH}" "${script}" "$@" "${n}" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}
rc() { cat "$(dirname "$1")/rc"; }
out() { cat "$(dirname "$1")/out"; }
err() { cat "$(dirname "$1")/err"; }
# 判定の grep -q にはファイルを直に読ませる。cat からパイプで渡すと、grep が先に抜けたときに
# cat が SIGPIPE で終わり、pipefail で「合わない」に見えることがある
outf() { echo "$(dirname "$1")/out"; }
errf() { echo "$(dirname "$1")/err"; }

echo "== check-test-headers.sh: ${script}"

# 1. 4 種類とも見出しがあれば通る。nix/pkgs の test_*.py でない .py は数えない
n=$(new_nix t1)
put "${n}/tests/a.test.sh" "${good_sh}"
put "${n}/tests/b.nix" "${good_nix}"
put "${n}/tests/c.test.mjs" "${good_mjs}"
put "${n}/pkgs/tool/test_tool.py" "${good_py}"
put "${n}/pkgs/tool/tool.py" $'import sys\nprint(sys.argv)'
run "${n}"
if [[ $(rc "${n}") == 0 && ! -s $(errf "${n}") ]] && grep -q '4 本' "$(outf "${n}")"; then
  ok "4 種類 (*.test.sh・*.nix・*.test.mjs・test_*.py) とも見出しがあれば通る (4 本と数える)"
else
  ng "4 種類とも見出しがある" "rc=$(rc "${n}") out=$(out "${n}") err=$(err "${n}")"
fi

# 2. 見出しの後ろに続きがあってもよい
n=$(new_nix t2)
put "${n}/tests/a.test.sh" $'#!/usr/bin/env bash\n# ## 確かめること (script ごと)\n#\n#   - 続きつき'
run "${n}"
if [[ $(rc "${n}") == 0 ]]; then
  ok "「## 確かめること (script ごと)」のように見出しの後ろに続きがあっても通る"
else
  ng "見出しの後ろの続き" "rc=$(rc "${n}") err=$(err "${n}")"
fi

# 3. 見出しの無いテストが種類ごとにあれば、全部の名前を出して exit 1。見出しのあるテストの名前は出さない
n=$(new_nix t3)
put "${n}/tests/good.test.sh" "${good_sh}"
put "${n}/tests/no-heading.test.sh" $'#!/usr/bin/env bash\n# 説明だけ\n\nset -u'
put "${n}/tests/no-heading.nix" $'# 何かを評価時に確かめる。\n#\n#   - 箇条だけ\n{ lib }:\nlib'
put "${n}/tests/no-heading.test.mjs" $'// 何かを確かめる。\n//\n// ## なぜ JavaScript なのか\n\nimport fs from "node:fs";'
put "${n}/pkgs/tool/test_tool.py" $'"""何かのテスト。"""\n\nimport unittest'
run "${n}"
missing_all=1
for f in tests/no-heading.test.sh tests/no-heading.nix tests/no-heading.test.mjs pkgs/tool/test_tool.py; do
  grep -qF "nix/${f}" "$(errf "${n}")" || missing_all=0
done
if [[ $(rc "${n}") == 1 && ${missing_all} == 1 ]] && ! grep -qF 'good.test.sh' "$(errf "${n}")"; then
  ok "見出しの無いテストは種類を問わず全部の名前を出して exit 1 (見出しのあるテストは出さない)"
else
  ng "見出しの無いテスト" "rc=$(rc "${n}") err=$(err "${n}")"
fi

# 4. 先頭のコメントの外にある見出しは数えない (空行の後・コードの後・関数の docstring)。### も数えない
i=0
for bad in \
  "a.test.sh|"$'#!/usr/bin/env bash\n# 説明\n\n# ## 確かめること\n#   - 空行の後' \
  "b.test.sh|"$'#!/usr/bin/env bash\n# 説明\nset -u\n# ## 確かめること\n#   - コードの後' \
  "c.nix|"$'# 説明\n{ lib }:\n# ## 確かめること\nlib' \
  "d.test.sh|"$'#!/usr/bin/env bash\n# ### 確かめること\n#   - 見出しの深さが違う' \
  "pkgs/tool/test_tool.py|"$'"""何かのテスト。"""\n\nimport unittest\n\n\nclass T(unittest.TestCase):\n    """## 確かめること"""'; do
  i=$((i + 1))
  n=$(new_nix "t4-${i}")
  case ${bad%%|*} in
    pkgs/*) put "${n}/${bad%%|*}" "${bad#*|}" ;;
    *) put "${n}/tests/${bad%%|*}" "${bad#*|}" ;;
  esac
  run "${n}"
  if [[ $(rc "${n}") == 1 ]] && grep -qF "${bad%%|*}" "$(errf "${n}")"; then
    ok "先頭のコメントの外か、深さの違う見出しは数えない: ${bad%%|*}"
  else
    ng "先頭のコメントの外の見出し: ${bad%%|*}" "rc=$(rc "${n}") err=$(err "${n}")"
  fi
done

# 5. nix/tests に読み方を知らない種類のファイルがあれば exit 1。nix/tests の中のディレクトリは見ない
n=$(new_nix t5)
put "${n}/tests/a.test.sh" "${good_sh}"
put "${n}/tests/fixtures/data.txt" "テストが読むデータ"
run "${n}"
rc_dir=$(rc "${n}")
put "${n}/tests/notes.md" "# メモ"
run "${n}"
if [[ ${rc_dir} == 0 && $(rc "${n}") == 1 ]] && grep -qF 'nix/tests/notes.md' "$(errf "${n}")"; then
  ok "nix/tests の知らない種類のファイルは名前を出して exit 1 (中のディレクトリは見ない)"
else
  ng "知らない種類のファイル" "ディレクトリだけのとき rc=${rc_dir} / rc=$(rc "${n}") err=$(err "${n}")"
fi

# 6. テストが 1 つも無ければ exit 1 (取り違えた場所を渡して、何も見ずに通さない)
n=$(new_nix t6)
run "${n}"
if [[ $(rc "${n}") == 1 && -n $(err "${n}") ]]; then
  ok "テストが 1 つも無ければ exit 1"
else
  ng "テストが無い" "rc=$(rc "${n}") out=$(out "${n}") err=$(err "${n}")"
fi

# 7. 知らない引数は exit 2
n=$(new_nix t7)
put "${n}/tests/a.test.sh" "${good_sh}"
run "${n}" --no-such-option
if [[ $(rc "${n}") == 2 ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${n}") err=$(err "${n}")"
fi

# 8. --show: 節だけを、コメントの印を外して並べる
n="${work}/t1/nix"
want_show='== nix/tests/a.test.sh
## 確かめること

  - sh の 1 つ目
  - sh の 2 つ目

== nix/tests/b.nix
## 確かめること

  - nix の 1 つ目

== nix/tests/c.test.mjs
## 確かめること

  - mjs の 1 つ目

== nix/pkgs/tool/test_tool.py
## 確かめること

- py の 1 つ目'
run "${n}" --show
if [[ $(rc "${n}") == 0 && $(out "${n}") == "${want_show}" ]]; then
  ok "--show は「## 確かめること」の節だけを、コメントの印を外して並べる"
else
  ng "--show" "rc=$(rc "${n}") err=$(err "${n}")"$'\n'"$(diff <(printf '%s\n' "${want_show}") <(out "${n}"))"
fi

# 9. --show でも、見出しの無いテストがあれば、ほかを出したうえで名前を出して exit 1
n="${work}/t3/nix"
run "${n}" --show
if [[ $(rc "${n}") == 1 ]] && grep -q '^== nix/tests/good.test.sh$' "$(outf "${n}")" \
  && grep -qF 'nix/tests/no-heading.test.sh' "$(errf "${n}")"; then
  ok "--show でも見出しの無いテストがあれば、ほかを出したうえで exit 1"
else
  ng "--show と見出しの無いテスト" "rc=$(rc "${n}") out=$(out "${n}") err=$(err "${n}")"
fi

# 10. 実行ビット
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある"
else
  ng "script に実行ビットが無い (CI の lint ジョブが直に呼べない)" "${script}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
