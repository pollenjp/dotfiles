#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/footer-links-archive.sh (Stop フックの入口) が、cc-pages・node の有無と CC_PAGES_DISABLE を見て、
# 黙って抜けるか本体を起こすかを、偽の node と偽の cc-pages で確かめる。
#
#   bash nix/tests/footer-links-archive-gate.test.sh [<footer-links-archive.sh のパス>]
#
# flake の checks (footer-links-archive-gate-test) が Nix のサンドボックスで流す。使うのは bash と coreutils だけ。
# 入口は要るコマンドだけを symlink で並べた PATH で起こす (node・cc-pages の無い PATH を作るため)。偽の node は、受け取った
# 引数と stdin を書き留め、stdout と stderr に文字を出して FAKE_NODE_RC (既定 1) で終わる。本体 (footer-links-archive.mjs) の
# 振る舞いは node の試験 (footer-links-archive.test.mjs) が見る。
#
# ## 確かめること
#
#   - hook の口 (引数なし): cc-pages が PATH に無い・CC_PAGES_DISABLE が空でない・node が PATH に無いときは、node を起こさず
#     (transcript を読まず)、stdout にも stderr にも何も出さずに 0 で終わる
#   - hook の口で揃っていれば、node に <入口の dir>/footer-links-archive.mjs --cc-pages <PATH の cc-pages> と、stdin の入力を
#     そのまま渡す。node が 1 で終わり stdout・stderr に書いても、入口は何も出さずに 0 で終わる
#   - 手で流す口 (引数あり): cc-pages が無い・CC_PAGES_DISABLE が空でない・node が無いときは、理由を stderr に出して 1 で、
#     node を起こさない。揃っていれば引数をそのまま node に渡し、node の終了コードで終わる。-h・--help は cc-pages が無くても
#     node に渡す

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/footer-links-archive.sh}
# 入口は自分のパスの dir から本体を指すので、正規化した絶対パスで起こし、その dir の本体と比べる
script_dir=$(
  cd -- "$(dirname "${script}")" &>/dev/null || exit
  pwd -P
)
script="${script_dir}/$(basename "${script}")"
body="${script_dir}/footer-links-archive.mjs"
work=$(mktemp -d "${TMPDIR:-/tmp}/footer-links-archive-gate-test.XXXXXX")
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

# 偽の node: 引数を 1 行ずつ、stdin をそのまま書き留める (bash の組み込みだけで書く。PATH に coreutils が無い)
fake_node="${work}/fake-node"
cat >"${fake_node}" <<EOF
#!${BASH}
printf '%s\n' "\$@" >"\${FAKE_LOG}/node.args"
IFS= read -r -d '' input || true
printf '%s' "\${input}" >"\${FAKE_LOG}/node.stdin"
echo "node の stdout"
echo "node の stderr" >&2
exit "\${FAKE_NODE_RC:-1}"
EOF
chmod +x "${fake_node}"
fake_cc_pages="${work}/fake-cc-pages"
printf '#!%s\nexit 0\n' "${BASH}" >"${fake_cc_pages}"
chmod +x "${fake_cc_pages}"

# new_case <名前> <PATH に並べるもの: node と cc-pages を空白区切りで>: PATH の dir と書き留めの dir を作り、その dir を出す
new_case() {
  local d="${work}/$1" tool
  mkdir -p "${d}/bin" "${d}/log"
  for tool in $2; do
    case ${tool} in
      node) ln -s "${fake_node}" "${d}/bin/node" ;;
      cc-pages) ln -s "${fake_cc_pages}" "${d}/bin/cc-pages" ;;
    esac
  done
  printf '%s' "${d}"
}
# run <case の dir> [<入口の引数>…]: 入口を、その case の PATH だけで起こす。stdin には hook の入力を流す。
# 足す env は呼ぶ側で前に置く (CC_PAGES_DISABLE=1 run …)
run() {
  local d=$1
  shift
  printf '{"session_id":"abc","transcript_path":"/x.jsonl"}' \
    | env PATH="${d}/bin" FAKE_LOG="${d}/log" "${BASH}" "${script}" "$@" >"${d}/out" 2>"${d}/err"
  echo $? >"${d}/rc"
}
called() {
  [[ -e "$1/log/node.args" ]]
}

echo "== footer-links-archive.sh: ${script}"

# 1. hook の口で、cc-pages が無い・CC_PAGES_DISABLE・node が無い → node を起こさず黙って 0
d=$(new_case no-cc-pages node)
run "${d}"
if [[ $(cat "${d}/rc") == 0 && ! -s "${d}/out" && ! -s "${d}/err" ]] && ! called "${d}"; then
  ok "hook の口: cc-pages が PATH に無ければ、node を起こさず黙って 0"
else
  ng "hook の口: cc-pages が PATH に無ければ、node を起こさず黙って 0" "rc=$(cat "${d}/rc") out=$(cat "${d}/out") err=$(cat "${d}/err")"
fi

d=$(new_case disabled "node cc-pages")
CC_PAGES_DISABLE=1 run "${d}"
if [[ $(cat "${d}/rc") == 0 && ! -s "${d}/out" && ! -s "${d}/err" ]] && ! called "${d}"; then
  ok "hook の口: CC_PAGES_DISABLE が空でなければ、node を起こさず黙って 0"
else
  ng "hook の口: CC_PAGES_DISABLE が空でなければ、node を起こさず黙って 0" "rc=$(cat "${d}/rc") out=$(cat "${d}/out") err=$(cat "${d}/err")"
fi

d=$(new_case no-node cc-pages)
run "${d}"
if [[ $(cat "${d}/rc") == 0 && ! -s "${d}/out" && ! -s "${d}/err" ]]; then
  ok "hook の口: node が PATH に無ければ、黙って 0"
else
  ng "hook の口: node が PATH に無ければ、黙って 0" "rc=$(cat "${d}/rc") out=$(cat "${d}/out") err=$(cat "${d}/err")"
fi

# 2. hook の口で揃っている → 本体と cc-pages の path と stdin を渡し、node が 1 で書いても黙って 0
d=$(new_case ready "node cc-pages")
CC_PAGES_DISABLE='' run "${d}"
want_args=$(printf '%s\n' "${body}" --cc-pages "${d}/bin/cc-pages")
if [[ $(cat "${d}/rc") == 0 && ! -s "${d}/out" && ! -s "${d}/err" ]] \
  && [[ $(cat "${d}/log/node.args" 2>/dev/null) == "${want_args}" ]] \
  && [[ $(cat "${d}/log/node.stdin" 2>/dev/null) == '{"session_id":"abc","transcript_path":"/x.jsonl"}' ]]; then
  ok "hook の口: 揃っていれば本体・cc-pages の path・stdin を node に渡し、node が 1 で書いても黙って 0 (CC_PAGES_DISABLE が空も)"
else
  ng "hook の口: 揃っていれば本体・cc-pages の path・stdin を node に渡し、node が 1 で書いても黙って 0 (CC_PAGES_DISABLE が空も)" \
    "rc=$(cat "${d}/rc") out=$(cat "${d}/out") err=$(cat "${d}/err") args=$(cat "${d}/log/node.args" 2>/dev/null)"
fi

# 3. 手で流す口で足りない → 理由を stderr に出して 1、node を起こさない
d=$(new_case manual-no-cc-pages node)
run "${d}" --session abc --transcript /x.jsonl
if [[ $(cat "${d}/rc") == 1 ]] && grep -q 'cc-pages' "${d}/err" && ! called "${d}"; then
  ok "手で流す口: cc-pages が無ければ、理由を stderr に出して 1"
else
  ng "手で流す口: cc-pages が無ければ、理由を stderr に出して 1" "rc=$(cat "${d}/rc") err=$(cat "${d}/err")"
fi

d=$(new_case manual-disabled "node cc-pages")
CC_PAGES_DISABLE=1 run "${d}" --session abc --transcript /x.jsonl
if [[ $(cat "${d}/rc") == 1 ]] && grep -q 'CC_PAGES_DISABLE' "${d}/err" && ! called "${d}"; then
  ok "手で流す口: CC_PAGES_DISABLE が空でなければ、理由を stderr に出して 1"
else
  ng "手で流す口: CC_PAGES_DISABLE が空でなければ、理由を stderr に出して 1" "rc=$(cat "${d}/rc") err=$(cat "${d}/err")"
fi

d=$(new_case manual-no-node cc-pages)
run "${d}" --session abc --transcript /x.jsonl
if [[ $(cat "${d}/rc") == 1 ]] && grep -q 'node' "${d}/err"; then
  ok "手で流す口: node が無ければ、理由を stderr に出して 1"
else
  ng "手で流す口: node が無ければ、理由を stderr に出して 1" "rc=$(cat "${d}/rc") err=$(cat "${d}/err")"
fi

# 4. 手で流す口で揃っている → 引数をそのまま渡し、node の終了コードで終わる
d=$(new_case manual-ready "node cc-pages")
FAKE_NODE_RC=3 run "${d}" --session abc --transcript /x.jsonl
want_args=$(printf '%s\n' "${body}" --cc-pages "${d}/bin/cc-pages" --session abc --transcript /x.jsonl)
if [[ $(cat "${d}/rc") == 3 ]] && [[ $(cat "${d}/log/node.args" 2>/dev/null) == "${want_args}" ]]; then
  ok "手で流す口: 揃っていれば引数をそのまま node に渡し、node の終了コードで終わる"
else
  ng "手で流す口: 揃っていれば引数をそのまま node に渡し、node の終了コードで終わる" \
    "rc=$(cat "${d}/rc") args=$(cat "${d}/log/node.args" 2>/dev/null)"
fi

d=$(new_case manual-help node)
FAKE_NODE_RC=0 run "${d}" --help
if [[ $(cat "${d}/rc") == 0 ]] && [[ $(cat "${d}/log/node.args" 2>/dev/null) == "$(printf '%s\n' "${body}" --help)" ]]; then
  ok "手で流す口: --help は cc-pages が無くても node に渡す"
else
  ng "手で流す口: --help は cc-pages が無くても node に渡す" "rc=$(cat "${d}/rc") args=$(cat "${d}/log/node.args" 2>/dev/null) err=$(cat "${d}/err")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
