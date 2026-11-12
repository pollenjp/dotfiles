#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/statusline-command.sh (Claude Code の status line) の先頭の 📄top (cc-pages の会話のトップページへの
# OSC 8 のリンク) と、それに続く今の 4 つを、作った入力と偽の cc-pages で確かめる。
#
#   bash nix/tests/statusline-command.test.sh [<port を埋めた statusline-command.sh のパス>]
#
# flake の checks (statusline-command-test) が Nix のサンドボックスで、home の設定 (既定の port 7777) から作った
# statusline-command.sh を渡して流す。引数を省けば、repo の script の @ccPagesPort@ を 7777 で埋めた写しを使う。使うのは
# bash・jq・git・coreutils。status line は、要るコマンドだけを symlink で並べた PATH で起こす (cc-pages の無い PATH を
# 作るため)。色 (SGR) は除いてから比べる (OSC 8 のリンクは残す)。📄top の SGR だけは生の出力で見る。
#
# ## 確かめること
#
#   - session_id が英数字と - だけで、CC_PAGES_DISABLE が空で、cc-pages が PATH にあれば、先頭に
#     ESC]8;;http://localhost:7777/s/<session_id>/ BEL 📄top ESC]8;; BEL を出し、区切り「 · 」の後ろに今の 4 つ
#     (model・dir・branch・context の残り) を続ける
#   - 📄top は色も dim も付けず、下線 (ESC[4m) だけで描く。Claude Code が status line を dimColor (テーマの inactive 色)
#     で包むので、footer のバッジ (dimColor に下線) と同じ見え方になる
#   - session_id が無い・空・形が違う (/ や空白を含む)、cc-pages が PATH に無い、CC_PAGES_DISABLE が空でないときは、
#     📄top を出さずに今の 4 つだけを出す
#   - remaining_percentage が無い (会話の始め) ときも、session_id を取り違えずに 📄top を出す
#   - 出力は 1 行 (改行を含まない)

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
work=$(mktemp -d "${TMPDIR:-/tmp}/statusline-command-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

if [[ -n ${1:-} ]]; then
  script=$1
else
  script="${work}/statusline-command.sh"
  sed 's/@ccPagesPort@/7777/g' "${here}/../files/claude/statusline-command.sh" >"${script}"
fi

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

# status line が使うコマンドだけを並べた PATH (cc-pages を足すかはケースごと)
tools="${work}/tools"
mkdir -p "${tools}"
for cmd in jq git basename; do
  ln -s "$(command -v "${cmd}")" "${tools}/${cmd}"
done
with_cc_pages="${work}/with-cc-pages"
mkdir -p "${with_cc_pages}"
printf '#!%s\nexit 0\n' "${BASH}" >"${with_cc_pages}/cc-pages"
chmod +x "${with_cc_pages}/cc-pages"

# branch の出る作業ディレクトリ (commit の無い main)
repo="${work}/repo"
git init -q -b main "${repo}"

ESC=$'\033'
BEL=$'\a'
top() {
  printf '%s]8;;http://localhost:7777/s/%s/%s📄top%s]8;;%s · ' "${ESC}" "$1" "${BEL}" "${ESC}" "${BEL}"
}
rest="Opus · repo · main · 42% left"

# run <名前> <入力の JSON> <PATH> [<env の代入>…]: status line を起こし、色を除いた出力を <名前>.out に、生の出力を <名前>.raw に書く
run() {
  local name=$1 input=$2 path=$3
  shift 3
  printf '%s' "${input}" | env -i PATH="${path}" HOME="${work}" "$@" "${BASH}" "${script}" >"${work}/${name}.raw" 2>"${work}/${name}.err"
  sed "s/${ESC}\[[0-9;]*m//g" "${work}/${name}.raw" >"${work}/${name}.out"
}
input() {
  jq -cn --arg dir "${repo}" --argjson extra "${1:-"{}"}" \
    '{model: {display_name: "Opus"}, workspace: {current_dir: $dir}, context_window: {remaining_percentage: 42}} + $extra'
}
expect() {
  local name=$1 want=$2 label=$3
  if [[ $(cat "${work}/${name}.out") == "${want}" ]]; then
    ok "${label}"
  else
    ng "${label}" "got:  $(cat -v "${work}/${name}.out")"$'\n'"want: $(printf '%s' "${want}" | cat -v)"$'\n'"err: $(cat "${work}/${name}.err")"
  fi
}

echo "== statusline-command.sh: ${script}"

run full "$(input '{"session_id":"5b3f99c8-206d-4f10-a25c-404756fcc1ea"}')" "${with_cc_pages}:${tools}"
expect full "$(top 5b3f99c8-206d-4f10-a25c-404756fcc1ea)${rest}" \
  "session_id があり cc-pages が PATH にあれば、先頭に /s/<session_id>/ への 📄top を出し、今の 4 つを続ける"
if [[ $(wc -l <"${work}/full.raw") == 0 ]]; then
  ok "出力は 1 行 (改行を含まない)"
else
  ng "出力は 1 行 (改行を含まない)" "$(cat -v "${work}/full.raw")"
fi
# 📄top の SGR は生の出力で見る。下線だけで、色も dim も付けない
top_sgr="${BEL}${ESC}[4m📄top${ESC}[0m${ESC}]8;;${BEL}"
if [[ $(cat "${work}/full.raw") == *"${top_sgr}"* ]]; then
  ok "📄top は色も dim も付けず、下線 (ESC[4m) だけで描く"
else
  ng "📄top は色も dim も付けず、下線 (ESC[4m) だけで描く" "got:  $(cat -v "${work}/full.raw")"
fi

run no-session "$(input)" "${with_cc_pages}:${tools}"
expect no-session "${rest}" "session_id が無ければ 📄top を出さない"

run empty-session "$(input '{"session_id":""}')" "${with_cc_pages}:${tools}"
expect empty-session "${rest}" "session_id が空なら 📄top を出さない"

run bad-session "$(input '{"session_id":"../x y"}')" "${with_cc_pages}:${tools}"
expect bad-session "${rest}" "session_id に英数字と - のほかがあれば 📄top を出さない"

run no-cc-pages "$(input '{"session_id":"abc-123"}')" "${tools}"
expect no-cc-pages "${rest}" "cc-pages が PATH に無ければ 📄top を出さない"

run disabled "$(input '{"session_id":"abc-123"}')" "${with_cc_pages}:${tools}" CC_PAGES_DISABLE=1
expect disabled "${rest}" "CC_PAGES_DISABLE が空でなければ 📄top を出さない"

run no-remaining "$(jq -cn --arg dir "${repo}" '{session_id: "abc-123", model: {display_name: "Opus"}, workspace: {current_dir: $dir}}')" \
  "${with_cc_pages}:${tools}"
expect no-remaining "$(top abc-123)Opus · repo · main" "remaining_percentage が無くても、session_id を取り違えずに 📄top を出す"

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
