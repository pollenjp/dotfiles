#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-claude-hook.sh の振る舞いを、使い捨ての HOME で確かめる。
#
#   bash nix/tests/bootstrap-claude-hook.test.sh [<bootstrap-claude-hook.sh のパス>]
#
# flake の checks (bootstrap-claude-hook-test) が Nix のサンドボックスで流す。使うのは
# bash・jq・coreutils だけ。配置済みの hook は空の実行ファイルで代える。
#
# ## 確かめること
#
#   - PreToolUse の 4 件 (ガード / Bash の ssh-agent-notice / Bash の xref-guard / Write・Edit・MultiEdit・NotebookEdit の
#     docs-guard)、PostToolUse の 5 件 (Bash + if / Write / Skill / Bash の ssh-agent-notice / Bash + if の
#     pr-assignee-nudge)、PostToolUseFailure の 2 件 (Bash の ssh-agent-notice / Bash + if の pr-assignee-nudge) を登録する
#   - 2 回目は何も変えない (setup --update のたびに流れる)
#   - 他の道具の hook (matcher Skill のものも) と settings.json の他のキーを残す
#   - 古い形 (ガードだけ登録済み) には残りを足し、ガードは足さない
#   - 5 つ前の形 (ガードと解説動画の 2 件が登録済み) には Skill の 1 件・ssh-agent-notice の 3 件・xref-guard の 1 件・
#     docs-guard の 1 件・pr-assignee-nudge の 2 件だけを足す
#   - 4 つ前の形 (ガード・解説動画の 2 件・Skill の 1 件が登録済み) には ssh-agent-notice の 3 件・xref-guard の 1 件・
#     docs-guard の 1 件・pr-assignee-nudge の 2 件だけを足す
#   - 3 つ前の形 (ssh-agent-notice の 3 件まで登録済み) には xref-guard の 1 件・docs-guard の 1 件・pr-assignee-nudge の
#     2 件だけを足す
#   - 2 つ前の形 (xref-guard まで登録済み) には docs-guard の 1 件と pr-assignee-nudge の 2 件だけを足す
#   - 1 つ前の形 (docs-guard まで登録済み) には pr-assignee-nudge の 2 件だけを足す。前の形の登録は、どの形でも
#     event ごとの先頭にそのまま残す
#   - hook が配置されていない (pr-assignee-nudge.sh だけが無いときも)・settings.json が壊れているときは
#     止まり、ファイルを変えない

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-claude-hook.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-claude-hook-test.XXXXXX")
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

# new_home <名前> <settings.json の中身 (空なら作らない)> <置く hook>
#   置く hook: yes = 7 つとも / old = pr-assignee-nudge.sh の無い 1 つ前の世代 / no = 置かない
new_home() {
  local h="${work}/$1" hooks=()
  mkdir -p "${h}/.claude/hooks"
  case $3 in
    yes) hooks=(nix-managed-guard.sh video-offer-nudge.sh run-through-nudge.sh ssh-agent-notice.sh xref-guard.sh docs-guard.sh pr-assignee-nudge.sh) ;;
    old) hooks=(nix-managed-guard.sh video-offer-nudge.sh run-through-nudge.sh ssh-agent-notice.sh xref-guard.sh docs-guard.sh) ;;
  esac
  for f in "${hooks[@]}"; do
    printf '#!/bin/sh\n' >"${h}/.claude/hooks/${f}"
    chmod +x "${h}/.claude/hooks/${f}"
  done
  if [[ -n $2 ]]; then
    printf '%s' "$2" >"${h}/.claude/settings.json"
  fi
  printf '%s' "${h}"
}
run() {
  HOME="$1" bash "${script}" >"$1/out" 2>"$1/err"
  echo $? >"$1/rc"
}

echo "== bootstrap-claude-hook.sh"

# notice_registered <settings.json> <ssh-agent-notice.sh のパス>: ssh-agent-notice の 3 件 (if なし) が 1 件ずつあるか
notice_registered() {
  local ev
  for ev in PreToolUse PostToolUse PostToolUseFailure; do
    [[ $(jq --arg ev "${ev}" --arg c "$2" '[.hooks[$ev] // [] | .[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c and (has("if") | not))] | length' "$1") == 1 ]] || return 1
  done
}
# xref_registered <settings.json> <xref-guard.sh のパス>: xref-guard の 1 件 (PreToolUse・Bash・if なし) だけがあるか
xref_registered() {
  [[ $(jq --arg c "$2" '[.hooks[] | .[] | .hooks[] | select(.command == $c)] | length' "$1") == 1 ]] \
    && [[ $(jq --arg c "$2" '[.hooks.PreToolUse // [] | .[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c and (has("if") | not))] | length' "$1") == 1 ]]
}
# docs_registered <settings.json> <docs-guard.sh のパス>: docs-guard の 1 件 (PreToolUse・Write|Edit|MultiEdit|NotebookEdit・if なし) だけがあるか
docs_registered() {
  [[ $(jq --arg c "$2" '[.hooks[] | .[] | .hooks[] | select(.command == $c)] | length' "$1") == 1 ]] \
    && [[ $(jq --arg c "$2" '[.hooks.PreToolUse // [] | .[] | select(.matcher == "Write|Edit|MultiEdit|NotebookEdit") | .hooks[] | select(.command == $c and (has("if") | not))] | length' "$1") == 1 ]]
}
# assignee_registered <settings.json> <pr-assignee-nudge.sh のパス>: pr-assignee-nudge の 2 件 (PostToolUse・
# PostToolUseFailure の Bash + if "Bash(gh pr create *)") だけがあるか
assignee_registered() {
  local ev
  [[ $(jq --arg c "$2" '[.hooks[] | .[] | .hooks[] | select(.command == $c)] | length' "$1") == 2 ]] || return 1
  for ev in PostToolUse PostToolUseFailure; do
    [[ $(jq --arg ev "${ev}" --arg c "$2" '[.hooks[$ev] // [] | .[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c and .["if"] == "Bash(gh pr create *)")] | length' "$1") == 1 ]] || return 1
  done
}
# kept <settings.json> <前の settings.json>: 前の形の登録が、event ごとの先頭にそのまま残っているか
kept() {
  jq -e --slurpfile before "$2" '
    .hooks as $now
    | $before[0].hooks | to_entries | all(.value as $v | $now[.key][0:($v | length)] == $v)
  ' "$1" >/dev/null
}

# 1. 空の settings.json → 11 件登録 (PreToolUse の 4 件・PostToolUse の 5 件・PostToolUseFailure の 2 件)
h=$(new_home t1 '{}' yes)
run "${h}"
nudge="${h}/.claude/hooks/video-offer-nudge.sh"
guard="${h}/.claude/hooks/nix-managed-guard.sh"
run_through="${h}/.claude/hooks/run-through-nudge.sh"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq --arg c "${guard}" '[.hooks.PreToolUse[] | select(.matcher == "Edit|Write|NotebookEdit|Bash") | .hooks[] | select(.command == $c)] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq --arg c "${nudge}" '[.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c and .["if"] == "Bash(gh pr create *)")] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq --arg c "${nudge}" '[.hooks.PostToolUse[] | select(.matcher == "Write") | .hooks[] | select(.command == $c and (has("if") | not))] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq --arg c "${run_through}" '[.hooks.PostToolUse[] | select(.matcher == "Skill") | .hooks[] | select(.command == $c and (has("if") | not))] | length' "${h}/.claude/settings.json") == 1 ]] \
  && notice_registered "${h}/.claude/settings.json" "${h}/.claude/hooks/ssh-agent-notice.sh" \
  && xref_registered "${h}/.claude/settings.json" "${h}/.claude/hooks/xref-guard.sh" \
  && docs_registered "${h}/.claude/settings.json" "${h}/.claude/hooks/docs-guard.sh" \
  && assignee_registered "${h}/.claude/settings.json" "${h}/.claude/hooks/pr-assignee-nudge.sh" \
  && [[ $(jq '[.hooks[] | .[] | .hooks[]] | length' "${h}/.claude/settings.json") == 11 ]]; then
  ok "空の settings.json に、PreToolUse の 4 件・PostToolUse の 5 件・PostToolUseFailure の 2 件を登録する"
else
  ng "空の settings.json に、PreToolUse の 4 件・PostToolUse の 5 件・PostToolUseFailure の 2 件を登録する" "rc=$(cat "${h}/rc") $(cat "${h}/.claude/settings.json" 2>/dev/null) $(cat "${h}/err")"
fi

# 2. 2 回目は何も変えない
cp "${h}/.claude/settings.json" "${work}/t1-first.json"
run "${h}"
if [[ $(cat "${h}/rc") == 0 ]] && cmp -s "${h}/.claude/settings.json" "${work}/t1-first.json"; then
  ok "2 回目は settings.json を変えない"
else
  ng "2 回目は settings.json を変えない" "$(diff "${work}/t1-first.json" "${h}/.claude/settings.json")"
fi

# 3. 他の道具の hook (matcher Skill のものも) と他のキーを残す
other='{"model":"opus","env":{"A":"1"},"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"orca-hook"}]},{"matcher":"Skill","hooks":[{"type":"command","command":"orca-skill"}]}],"Stop":[{"hooks":[{"type":"command","command":"orca-stop"}]}]}}'
h=$(new_home t3 "${other}" yes)
run "${h}"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq -r '.model + "," + .env.A' "${h}/.claude/settings.json") == "opus,1" ]] \
  && [[ $(jq '[.hooks.PostToolUse[] | .hooks[] | select(.command == "orca-hook")] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq '[.hooks.PostToolUse[] | select(.matcher == "Skill") | .hooks[] | select(.command == "orca-skill")] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq '[.hooks.Stop[] | .hooks[] | select(.command == "orca-stop")] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq '.hooks.PostToolUse | length' "${h}/.claude/settings.json") == 7 ]]; then
  ok "他の道具の hook (matcher Skill のものも) と他のキーを残す"
else
  ng "他の道具の hook (matcher Skill のものも) と他のキーを残す" "$(cat "${h}/.claude/settings.json")"
fi

# 4. ガードだけ登録済み (古い形) → 残りを足し、ガードは足さない
h=$(new_home t4 '' yes)
jq -n --arg c "${h}/.claude/hooks/nix-managed-guard.sh" \
  '{hooks: {PreToolUse: [{matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: $c}]}]}}' \
  >"${h}/.claude/settings.json"
run "${h}"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq '.hooks.PreToolUse | length' "${h}/.claude/settings.json") == 4 ]] \
  && [[ $(jq '.hooks.PostToolUse | length' "${h}/.claude/settings.json") == 5 ]] \
  && [[ $(jq '.hooks.PostToolUseFailure | length' "${h}/.claude/settings.json") == 2 ]]; then
  ok "ガードだけ登録済みなら残りを足し、ガードは足さない"
else
  ng "ガードだけ登録済みなら残りを足し、ガードは足さない" "$(cat "${h}/.claude/settings.json")"
fi

# 4b. ガードと解説動画の 2 件が登録済み (5 つ前の形) → Skill の 1 件・ssh-agent-notice の 3 件・xref-guard の 1 件・
#     docs-guard の 1 件・pr-assignee-nudge の 2 件だけ足す
h=$(new_home t4b '' yes)
jq -n --arg g "${h}/.claude/hooks/nix-managed-guard.sh" --arg n "${h}/.claude/hooks/video-offer-nudge.sh" \
  '{hooks: {
    PreToolUse: [{matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: $g}]}],
    PostToolUse: [
      {matcher: "Bash", hooks: [{type: "command", command: $n, "if": "Bash(gh pr create *)"}]},
      {matcher: "Write", hooks: [{type: "command", command: $n}]}
    ]
  }}' >"${h}/.claude/settings.json"
run "${h}"
s="${h}/.claude/settings.json"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq '.hooks.PreToolUse | length' "${s}") == 4 ]] \
  && [[ $(jq '.hooks.PostToolUse | length' "${s}") == 5 ]] \
  && [[ $(jq '[.hooks.PostToolUse[] | select(.matcher == "Bash")] | length' "${s}") == 3 ]] \
  && [[ $(jq '[.hooks.PostToolUse[] | select(.matcher == "Write")] | length' "${s}") == 1 ]] \
  && [[ $(jq --arg c "${h}/.claude/hooks/run-through-nudge.sh" '[.hooks.PostToolUse[] | select(.matcher == "Skill") | .hooks[] | select(.command == $c)] | length' "${s}") == 1 ]] \
  && notice_registered "${s}" "${h}/.claude/hooks/ssh-agent-notice.sh" \
  && xref_registered "${s}" "${h}/.claude/hooks/xref-guard.sh" \
  && docs_registered "${s}" "${h}/.claude/hooks/docs-guard.sh" \
  && assignee_registered "${s}" "${h}/.claude/hooks/pr-assignee-nudge.sh"; then
  ok "ガードと解説動画が登録済みなら Skill の 1 件・ssh-agent-notice の 3 件・xref-guard と docs-guard の 1 件ずつ・pr-assignee-nudge の 2 件だけを足す"
else
  ng "ガードと解説動画が登録済みなら Skill の 1 件・ssh-agent-notice の 3 件・xref-guard と docs-guard の 1 件ずつ・pr-assignee-nudge の 2 件だけを足す" "rc=$(cat "${h}/rc") $(cat "${s}")"
fi

# 4c. ガード・解説動画の 2 件・Skill の 1 件が登録済み (4 つ前の形) → ssh-agent-notice の 3 件・xref-guard の 1 件・
#     docs-guard の 1 件・pr-assignee-nudge の 2 件だけ足す
h=$(new_home t4c '' yes)
jq -n --arg g "${h}/.claude/hooks/nix-managed-guard.sh" --arg n "${h}/.claude/hooks/video-offer-nudge.sh" \
  --arg r "${h}/.claude/hooks/run-through-nudge.sh" \
  '{hooks: {
    PreToolUse: [{matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: $g}]}],
    PostToolUse: [
      {matcher: "Bash", hooks: [{type: "command", command: $n, "if": "Bash(gh pr create *)"}]},
      {matcher: "Write", hooks: [{type: "command", command: $n}]},
      {matcher: "Skill", hooks: [{type: "command", command: $r}]}
    ]
  }}' >"${h}/.claude/settings.json"
cp "${h}/.claude/settings.json" "${work}/t4c-before.json"
run "${h}"
s="${h}/.claude/settings.json"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq '[.hooks[] | .[] | .hooks[]] | length' "${s}") == 11 ]] \
  && notice_registered "${s}" "${h}/.claude/hooks/ssh-agent-notice.sh" \
  && xref_registered "${s}" "${h}/.claude/hooks/xref-guard.sh" \
  && docs_registered "${s}" "${h}/.claude/hooks/docs-guard.sh" \
  && assignee_registered "${s}" "${h}/.claude/hooks/pr-assignee-nudge.sh" \
  && kept "${s}" "${work}/t4c-before.json"; then
  ok "ガード・解説動画・Skill が登録済みなら ssh-agent-notice の 3 件・xref-guard と docs-guard の 1 件ずつ・pr-assignee-nudge の 2 件だけを足す"
else
  ng "ガード・解説動画・Skill が登録済みなら ssh-agent-notice の 3 件・xref-guard と docs-guard の 1 件ずつ・pr-assignee-nudge の 2 件だけを足す" "rc=$(cat "${h}/rc") $(cat "${s}")"
fi

# 4d. ssh-agent-notice の 3 件まで登録済み (3 つ前の形) → xref-guard と docs-guard の 1 件ずつ・pr-assignee-nudge の 2 件だけ
#     足し、前の 7 件は変えない
h=$(new_home t4d '' yes)
jq -n --arg g "${h}/.claude/hooks/nix-managed-guard.sh" --arg n "${h}/.claude/hooks/video-offer-nudge.sh" \
  --arg r "${h}/.claude/hooks/run-through-nudge.sh" --arg a "${h}/.claude/hooks/ssh-agent-notice.sh" \
  '{hooks: {
    PreToolUse: [
      {matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: $g}]},
      {matcher: "Bash", hooks: [{type: "command", command: $a}]}
    ],
    PostToolUse: [
      {matcher: "Bash", hooks: [{type: "command", command: $n, "if": "Bash(gh pr create *)"}]},
      {matcher: "Write", hooks: [{type: "command", command: $n}]},
      {matcher: "Skill", hooks: [{type: "command", command: $r}]},
      {matcher: "Bash", hooks: [{type: "command", command: $a}]}
    ],
    PostToolUseFailure: [{matcher: "Bash", hooks: [{type: "command", command: $a}]}]
  }}' >"${h}/.claude/settings.json"
cp "${h}/.claude/settings.json" "${work}/t4d-before.json"
run "${h}"
s="${h}/.claude/settings.json"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq '[.hooks[] | .[] | .hooks[]] | length' "${s}") == 11 ]] \
  && xref_registered "${s}" "${h}/.claude/hooks/xref-guard.sh" \
  && docs_registered "${s}" "${h}/.claude/hooks/docs-guard.sh" \
  && assignee_registered "${s}" "${h}/.claude/hooks/pr-assignee-nudge.sh" \
  && kept "${s}" "${work}/t4d-before.json"; then
  ok "ssh-agent-notice まで登録済みなら xref-guard と docs-guard の 1 件ずつ・pr-assignee-nudge の 2 件だけを足す"
else
  ng "ssh-agent-notice まで登録済みなら xref-guard と docs-guard の 1 件ずつ・pr-assignee-nudge の 2 件だけを足す" "rc=$(cat "${h}/rc") $(cat "${s}")"
fi

# 4e. xref-guard まで登録済み (2 つ前の形) → docs-guard の 1 件と pr-assignee-nudge の 2 件だけ足し、前の 8 件は変えない
h=$(new_home t4e '' yes)
jq -n --arg g "${h}/.claude/hooks/nix-managed-guard.sh" --arg n "${h}/.claude/hooks/video-offer-nudge.sh" \
  --arg r "${h}/.claude/hooks/run-through-nudge.sh" --arg a "${h}/.claude/hooks/ssh-agent-notice.sh" \
  --arg x "${h}/.claude/hooks/xref-guard.sh" \
  '{hooks: {
    PreToolUse: [
      {matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: $g}]},
      {matcher: "Bash", hooks: [{type: "command", command: $a}]},
      {matcher: "Bash", hooks: [{type: "command", command: $x}]}
    ],
    PostToolUse: [
      {matcher: "Bash", hooks: [{type: "command", command: $n, "if": "Bash(gh pr create *)"}]},
      {matcher: "Write", hooks: [{type: "command", command: $n}]},
      {matcher: "Skill", hooks: [{type: "command", command: $r}]},
      {matcher: "Bash", hooks: [{type: "command", command: $a}]}
    ],
    PostToolUseFailure: [{matcher: "Bash", hooks: [{type: "command", command: $a}]}]
  }}' >"${h}/.claude/settings.json"
cp "${h}/.claude/settings.json" "${work}/t4e-before.json"
run "${h}"
s="${h}/.claude/settings.json"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq '[.hooks[] | .[] | .hooks[]] | length' "${s}") == 11 ]] \
  && docs_registered "${s}" "${h}/.claude/hooks/docs-guard.sh" \
  && assignee_registered "${s}" "${h}/.claude/hooks/pr-assignee-nudge.sh" \
  && kept "${s}" "${work}/t4e-before.json"; then
  ok "xref-guard まで登録済みなら docs-guard の 1 件と pr-assignee-nudge の 2 件だけを足す"
else
  ng "xref-guard まで登録済みなら docs-guard の 1 件と pr-assignee-nudge の 2 件だけを足す" "rc=$(cat "${h}/rc") $(cat "${s}")"
fi

# 4f. docs-guard まで登録済み (1 つ前の形) → pr-assignee-nudge の 2 件だけ足し、前の 9 件は変えない
h=$(new_home t4f '' yes)
jq -n --arg g "${h}/.claude/hooks/nix-managed-guard.sh" --arg n "${h}/.claude/hooks/video-offer-nudge.sh" \
  --arg r "${h}/.claude/hooks/run-through-nudge.sh" --arg a "${h}/.claude/hooks/ssh-agent-notice.sh" \
  --arg x "${h}/.claude/hooks/xref-guard.sh" --arg d "${h}/.claude/hooks/docs-guard.sh" \
  '{hooks: {
    PreToolUse: [
      {matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: $g}]},
      {matcher: "Bash", hooks: [{type: "command", command: $a}]},
      {matcher: "Bash", hooks: [{type: "command", command: $x}]},
      {matcher: "Write|Edit|MultiEdit|NotebookEdit", hooks: [{type: "command", command: $d}]}
    ],
    PostToolUse: [
      {matcher: "Bash", hooks: [{type: "command", command: $n, "if": "Bash(gh pr create *)"}]},
      {matcher: "Write", hooks: [{type: "command", command: $n}]},
      {matcher: "Skill", hooks: [{type: "command", command: $r}]},
      {matcher: "Bash", hooks: [{type: "command", command: $a}]}
    ],
    PostToolUseFailure: [{matcher: "Bash", hooks: [{type: "command", command: $a}]}]
  }}' >"${h}/.claude/settings.json"
cp "${h}/.claude/settings.json" "${work}/t4f-before.json"
run "${h}"
s="${h}/.claude/settings.json"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq '[.hooks[] | .[] | .hooks[]] | length' "${s}") == 11 ]] \
  && assignee_registered "${s}" "${h}/.claude/hooks/pr-assignee-nudge.sh" \
  && kept "${s}" "${work}/t4f-before.json"; then
  ok "docs-guard まで登録済みなら pr-assignee-nudge の 2 件だけを足す"
else
  ng "docs-guard まで登録済みなら pr-assignee-nudge の 2 件だけを足す" "rc=$(cat "${h}/rc") $(cat "${s}")"
fi

# 5. hook が配置されていない → 止まり、settings.json を変えない
h=$(new_home t5 '{}' no)
run "${h}"
if [[ $(cat "${h}/rc") != 0 ]] && [[ $(cat "${h}/.claude/settings.json") == '{}' ]] && grep -q 'home-manager switch' "${h}/err"; then
  ok "hook が無ければ止まり、switch を促す"
else
  ng "hook が無ければ止まり、switch を促す" "rc=$(cat "${h}/rc") err=$(cat "${h}/err")"
fi

# 5b. pr-assignee-nudge.sh だけが配置されていない (1 つ前の世代の switch) → 止まり、settings.json を変えない
h=$(new_home t5b '{}' old)
run "${h}"
if [[ $(cat "${h}/rc") != 0 ]] && [[ $(cat "${h}/.claude/settings.json") == '{}' ]] \
  && grep -q 'pr-assignee-nudge.sh' "${h}/err" && grep -q 'home-manager switch' "${h}/err"; then
  ok "pr-assignee-nudge.sh だけが無くても止まり、switch を促す"
else
  ng "pr-assignee-nudge.sh だけが無くても止まり、switch を促す" "rc=$(cat "${h}/rc") err=$(cat "${h}/err")"
fi

# 6. settings.json が壊れている → 止まり、ファイルを変えない
h=$(new_home t6 '{"hooks": ' yes)
run "${h}"
if [[ $(cat "${h}/rc") != 0 ]] && [[ $(cat "${h}/.claude/settings.json") == '{"hooks": ' ]]; then
  ok "壊れた settings.json では止まり、ファイルを変えない"
else
  ng "壊れた settings.json では止まり、ファイルを変えない" "rc=$(cat "${h}/rc")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
