#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/video-offer-nudge.sh の振る舞いを、合成した PostToolUse の入力で確かめる。
#
#   bash nix/tests/video-offer-nudge.test.sh [<video-offer-nudge.sh のパス>]
#
# flake の checks (video-offer-nudge-test) が Nix のサンドボックスで流す。使うのは
# bash・jq・coreutils・grep だけ。skill の有無は CLAUDE_CONFIG_DIR を使い捨ての dir に向けて作る。
#
# ## 確かめること
#
#   - gh pr create の成功・タグ「設計」の cc-page・spec / ADR の新規作成で知らせる
#   - それ以外 (失敗した PR・タグの無いページ・上書き・関係ないファイル・ADR の dir の中の
#     textbook や図・ADR の一覧) では黙る
#   - subagent の中・skill が無いマシン・壊れた入力・「このセッションでは聞かない」の印が
#     あるセッションでも黙り、いつも exit 0
#
# 印 (XDG_STATE_HOME の pjp-video-offer/off-<session_id>) は使い捨ての dir に作る。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/video-offer-nudge.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/video-offer-nudge-test.XXXXXX")
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

# skill が入っている設定 dir と、入っていない設定 dir
with_skill="${work}/with-skill"
mkdir -p "${with_skill}/skills/pjp-video-explainer-offer"
echo '---' >"${with_skill}/skills/pjp-video-explainer-offer/SKILL.md"
without_skill="${work}/without-skill"
mkdir -p "${without_skill}"

# 「このセッションでは聞かない」の印を置く dir (XDG_STATE_HOME)
state="${work}/state"
mkdir -p "${state}"

# run <設定 dir> <入力> : stdout を ${work}/out に、exit code を ${work}/rc に残す
run() {
  printf '%s' "$2" | CLAUDE_CONFIG_DIR="$1" XDG_STATE_HOME="${state}" bash "${script}" >"${work}/out" 2>"${work}/err"
  echo $? >"${work}/rc"
}
context() {
  jq -r '.hookSpecificOutput.additionalContext // empty' "${work}/out" 2>/dev/null
}
silent() {
  [[ ! -s ${work}/out && $(cat "${work}/rc") == 0 ]]
}

bash_input() {
  jq -cn --arg cmd "$1" --arg out "$2" \
    '{session_id: "s", hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: $cmd}, tool_response: {stdout: $out, stderr: "", interrupted: false, isImage: false}}'
}
write_input() {
  jq -cn --arg path "$1" --arg type "$2" \
    '{session_id: "s", hook_event_name: "PostToolUse", tool_name: "Write", tool_input: {file_path: $path, content: "x"}, tool_response: {filePath: $path, type: $type}}'
}
# new_page <dir 名> <page.json の中身 (空なら作らない)> : cc-pages のページ dir を作り、パスを返す
new_page() {
  local dir="${work}/cc-pages/sessions/20261010-abcdef12/$1"
  mkdir -p "${dir}"
  if [[ -n $2 ]]; then
    printf '%s' "$2" >"${dir}/page.json"
  fi
  printf '%s' "${dir}"
}

echo "== video-offer-nudge.sh"

# 1. gh pr create が成功 → pr の文と URL
run "${with_skill}" "$(bash_input 'gh pr create --title t --body b' 'https://github.com/pollenjp/claude-skills/pull/71')"
c=$(context)
if [[ ${c} == "[解説動画] PR を作った (https://github.com/pollenjp/claude-skills/pull/71)。"* && ${c} == *"PR の URL を返すときに"* ]]; then
  ok "gh pr create の成功で知らせる"
else
  ng "gh pr create の成功で知らせる" "out=$(cat "${work}/out")"
fi

# 2. cd x && gh pr create → pr の文
run "${with_skill}" "$(bash_input 'cd /r && gh pr create --draft --title t --body b' 'https://github.com/o/r/pull/3')"
if [[ $(context) == "[解説動画] PR を作った (https://github.com/o/r/pull/3)。"* ]]; then
  ok "つないだコマンドの gh pr create でも知らせる"
else
  ng "つないだコマンドの gh pr create でも知らせる" "out=$(cat "${work}/out")"
fi

# 3. URL の前後に案内の行がある stdout → URL を拾う
run "${with_skill}" "$(bash_input 'gh pr create --title t --body b' $'Creating pull request for feat/x into main in o/r\n\nhttps://github.com/o/r/pull/9\nWarning: 1 uncommitted change')"
if [[ $(context) == "[解説動画] PR を作った (https://github.com/o/r/pull/9)。"* ]]; then
  ok "案内の行に挟まれた URL を拾う"
else
  ng "案内の行に挟まれた URL を拾う" "out=$(cat "${work}/out")"
fi

# 4. GitHub Enterprise のホスト
run "${with_skill}" "$(bash_input 'gh pr create --title t --body b' 'https://ghe.example.co.jp/org/repo/pull/7')"
if [[ $(context) == "[解説動画] PR を作った (https://ghe.example.co.jp/org/repo/pull/7)。"* ]]; then
  ok "GitHub Enterprise のホストの URL も拾う"
else
  ng "GitHub Enterprise のホストの URL も拾う" "out=$(cat "${work}/out")"
fi

# 5. gh pr create が失敗 (URL が無い) → 黙る
run "${with_skill}" "$(bash_input 'gh pr create --title t --body b' 'a pull request for branch "feat/x" into branch "main" already exists')"
if silent; then ok "URL の無い gh pr create では黙る"; else ng "URL の無い gh pr create では黙る" "out=$(cat "${work}/out")"; fi

# 6. タグ「設計」の cc-page を新規作成 (dir に日本語と空白) → design-page の文と dir
page=$(new_page '0002-通知の流し方 案-b-の設計' '{"title":"通知の流し方 (案 B) の設計","tags":["設計","TKT-1"]}')
run "${with_skill}" "$(write_input "${page}/index.html" create)"
if [[ $(context) == "[解説動画] タグ「設計」の cc-page を作った (${page})。"* && $(context) == *"承認を聞く前に"* ]]; then
  ok "タグ「設計」の cc-page の新規作成で知らせる (日本語と空白の dir)"
else
  ng "タグ「設計」の cc-page の新規作成で知らせる" "out=$(cat "${work}/out")"
fi

# 7. タグに「設計」を含むもの (「設計案」) も当てる。「設計」の無いページでは黙る
page=$(new_page '0003-x' '{"tags":["設計案"]}')
run "${with_skill}" "$(write_input "${page}/index.html" create)"
r1=$(context)
page=$(new_page '0004-y' '{"tags":["調査"]}')
run "${with_skill}" "$(write_input "${page}/index.html" create)"
if [[ ${r1} == "[解説動画] タグ「設計」の cc-page を作った"* ]] && silent; then
  ok "「設計」を含むタグで知らせ、含まないタグでは黙る"
else
  ng "「設計」を含むタグで知らせ、含まないタグでは黙る" "r1=${r1} out=$(cat "${work}/out")"
fi

# 8. page.json が無い → 黙る
page=$(new_page '0005-z' '')
run "${with_skill}" "$(write_input "${page}/index.html" create)"
if silent; then ok "page.json が無いページでは黙る"; else ng "page.json が無いページでは黙る" "out=$(cat "${work}/out")"; fi

# 9. page.json が壊れている・tags が配列でない → 黙る
page=$(new_page '0006-w' '{"tags": ')
run "${with_skill}" "$(write_input "${page}/index.html" create)"
s1=$(silent && echo yes)
page=$(new_page '0007-v' '{"tags":"設計"}')
run "${with_skill}" "$(write_input "${page}/index.html" create)"
if [[ ${s1} == yes ]] && silent; then ok "壊れた page.json・配列でない tags では黙る"; else ng "壊れた page.json・配列でない tags では黙る" "out=$(cat "${work}/out")"; fi

# 10. 同じ index.html の上書き (type: update) → 黙る
page=$(new_page '0008-u' '{"tags":["設計"]}')
run "${with_skill}" "$(write_input "${page}/index.html" update)"
if silent; then ok "上書きでは黙る"; else ng "上書きでは黙る" "out=$(cat "${work}/out")"; fi

# 11. tool_response に type が無い → 黙る
run "${with_skill}" "$(jq -cn --arg p "${page}/index.html" '{tool_name: "Write", tool_input: {file_path: $p}, tool_response: {filePath: $p}}')"
if silent; then ok "type の無い Write では黙る"; else ng "type の無い Write では黙る" "out=$(cat "${work}/out")"; fi

# 12. spec と ADR の新規作成 → design-doc の文
run "${with_skill}" "$(write_input /r/docs/superpowers/specs/2026-10-10-x-design.md create)"
r1=$(context)
run "${with_skill}" "$(write_input /r/docs/adr/010_x/README.md create)"
r2=$(context)
if [[ ${r1} == "[解説動画] 設計の文書を作った (/r/docs/superpowers/specs/2026-10-10-x-design.md)。"* && ${r2} == "[解説動画] 設計の文書を作った (/r/docs/adr/010_x/README.md)。"* ]]; then
  ok "spec と ADR の新規作成で知らせる"
else
  ng "spec と ADR の新規作成で知らせる" "r1=${r1} r2=${r2}"
fi

# 13. 関係ないファイルの新規作成 → 黙る
run "${with_skill}" "$(write_input /r/src/main.py create)"
if silent; then ok "関係ないファイルでは黙る"; else ng "関係ないファイルでは黙る" "out=$(cat "${work}/out")"; fi

# 14. subagent の中 (agent_id がある) → 黙る
run "${with_skill}" "$(bash_input 'gh pr create --title t --body b' 'https://github.com/o/r/pull/5' | jq -c '. + {agent_id: "agent-1", agent_type: "general-purpose"}')"
if silent; then ok "subagent の中では黙る"; else ng "subagent の中では黙る" "out=$(cat "${work}/out")"; fi

# 15. skill が無いマシン → 黙る
run "${without_skill}" "$(bash_input 'gh pr create --title t --body b' 'https://github.com/o/r/pull/5')"
if silent; then ok "skill が無いマシンでは黙る"; else ng "skill が無いマシンでは黙る" "out=$(cat "${work}/out")"; fi

# 16. 壊れた入力 → 黙って exit 0
run "${with_skill}" '{"tool_name": "Bash", '
if silent; then ok "壊れた入力でも黙って exit 0"; else ng "壊れた入力でも黙って exit 0" "rc=$(cat "${work}/rc") out=$(cat "${work}/out")"; fi

# 17. 1 ファイルの ADR (docs/adr/<名前>.md) の新規作成 → design-doc の文
run "${with_skill}" "$(write_input /r/docs/adr/0011-use-x.md create)"
if [[ $(context) == "[解説動画] 設計の文書を作った (/r/docs/adr/0011-use-x.md)。"* ]]; then
  ok "1 ファイルの ADR の新規作成で知らせる"
else
  ng "1 ファイルの ADR の新規作成で知らせる" "out=$(cat "${work}/out")"
fi

# 18. ADR の一覧 (docs/adr/README.md) の新規作成 → 黙る
run "${with_skill}" "$(write_input /r/docs/adr/README.md create)"
if silent; then ok "ADR の一覧の新規作成では黙る"; else ng "ADR の一覧の新規作成では黙る" "out=$(cat "${work}/out")"; fi

# 19. ADR の dir の中の textbook の章 → 黙る
run "${with_skill}" "$(write_input /r/docs/adr/010_x/textbook/01-intro.md create)"
if silent; then ok "ADR の dir の中の textbook では黙る"; else ng "ADR の dir の中の textbook では黙る" "out=$(cat "${work}/out")"; fi

# 20. ADR の dir の中の図 → 黙る
run "${with_skill}" "$(write_input /r/docs/adr/010_x/plantuml/flow.puml create)"
if silent; then ok "ADR の dir の中の図では黙る"; else ng "ADR の dir の中の図では黙る" "out=$(cat "${work}/out")"; fi

# 21. このセッションに「聞かない」の印がある → 黙る。別のセッションの印では黙らない
mkdir -p "${state}/pjp-video-offer"
touch "${state}/pjp-video-offer/off-s"
run "${with_skill}" "$(bash_input 'gh pr create --title t --body b' 'https://github.com/o/r/pull/8')"
s1=$(silent && echo yes)
run "${with_skill}" "$(bash_input 'gh pr create --title t --body b' 'https://github.com/o/r/pull/8' | jq -c '.session_id = "other"')"
if [[ ${s1} == yes && $(context) == "[解説動画] PR を作った (https://github.com/o/r/pull/8)。"* ]]; then
  ok "「聞かない」の印があるセッションでは黙り、別のセッションでは知らせる"
else
  ng "「聞かない」の印があるセッションでは黙り、別のセッションでは知らせる" "s1=${s1} out=$(cat "${work}/out")"
fi
rm -f "${state}/pjp-video-offer/off-s"

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
