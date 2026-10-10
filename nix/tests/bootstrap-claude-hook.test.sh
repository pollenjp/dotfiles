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
#   - PreToolUse のガードと、PostToolUse の 2 件 (Bash + if / Write) を登録する
#   - 2 回目は何も変えない (setup --update のたびに流れる)
#   - 他の道具の hook と settings.json の他のキーを残す
#   - 古い形 (ガードだけ登録済み) には PostToolUse だけを足す
#   - hook が配置されていない・settings.json が壊れているときは止まり、ファイルを変えない

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

# new_home <名前> <settings.json の中身 (空なら作らない)> <hook を置くか (yes/no)>
new_home() {
  local h="${work}/$1"
  mkdir -p "${h}/.claude/hooks"
  if [[ $3 == yes ]]; then
    for f in nix-managed-guard.sh video-offer-nudge.sh; do
      printf '#!/bin/sh\n' >"${h}/.claude/hooks/${f}"
      chmod +x "${h}/.claude/hooks/${f}"
    done
  fi
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

# 1. 空の settings.json → 3 件登録
h=$(new_home t1 '{}' yes)
run "${h}"
nudge="${h}/.claude/hooks/video-offer-nudge.sh"
guard="${h}/.claude/hooks/nix-managed-guard.sh"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq --arg c "${guard}" '[.hooks.PreToolUse[] | select(.matcher == "Edit|Write|NotebookEdit|Bash") | .hooks[] | select(.command == $c)] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq --arg c "${nudge}" '[.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c and .["if"] == "Bash(gh pr create *)")] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq --arg c "${nudge}" '[.hooks.PostToolUse[] | select(.matcher == "Write") | .hooks[] | select(.command == $c and (has("if") | not))] | length' "${h}/.claude/settings.json") == 1 ]]; then
  ok "空の settings.json にガードと PostToolUse の 2 件を登録する"
else
  ng "空の settings.json にガードと PostToolUse の 2 件を登録する" "rc=$(cat "${h}/rc") $(cat "${h}/.claude/settings.json" 2>/dev/null) $(cat "${h}/err")"
fi

# 2. 2 回目は何も変えない
cp "${h}/.claude/settings.json" "${work}/t1-first.json"
run "${h}"
if [[ $(cat "${h}/rc") == 0 ]] && cmp -s "${h}/.claude/settings.json" "${work}/t1-first.json"; then
  ok "2 回目は settings.json を変えない"
else
  ng "2 回目は settings.json を変えない" "$(diff "${work}/t1-first.json" "${h}/.claude/settings.json")"
fi

# 3. 他の道具の hook と他のキーを残す
other='{"model":"opus","env":{"A":"1"},"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"orca-hook"}]}],"Stop":[{"hooks":[{"type":"command","command":"orca-stop"}]}]}}'
h=$(new_home t3 "${other}" yes)
run "${h}"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq -r '.model + "," + .env.A' "${h}/.claude/settings.json") == "opus,1" ]] \
  && [[ $(jq '[.hooks.PostToolUse[] | .hooks[] | select(.command == "orca-hook")] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq '[.hooks.Stop[] | .hooks[] | select(.command == "orca-stop")] | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq '.hooks.PostToolUse | length' "${h}/.claude/settings.json") == 3 ]]; then
  ok "他の道具の hook と他のキーを残す"
else
  ng "他の道具の hook と他のキーを残す" "$(cat "${h}/.claude/settings.json")"
fi

# 4. ガードだけ登録済み (今までの形) → PostToolUse だけ足す
h=$(new_home t4 '' yes)
jq -n --arg c "${h}/.claude/hooks/nix-managed-guard.sh" \
  '{hooks: {PreToolUse: [{matcher: "Edit|Write|NotebookEdit|Bash", hooks: [{type: "command", command: $c}]}]}}' \
  >"${h}/.claude/settings.json"
run "${h}"
if [[ $(cat "${h}/rc") == 0 ]] \
  && [[ $(jq '.hooks.PreToolUse | length' "${h}/.claude/settings.json") == 1 ]] \
  && [[ $(jq '.hooks.PostToolUse | length' "${h}/.claude/settings.json") == 2 ]]; then
  ok "ガードだけ登録済みなら PostToolUse だけを足す"
else
  ng "ガードだけ登録済みなら PostToolUse だけを足す" "$(cat "${h}/.claude/settings.json")"
fi

# 5. hook が配置されていない → 止まり、settings.json を変えない
h=$(new_home t5 '{}' no)
run "${h}"
if [[ $(cat "${h}/rc") != 0 ]] && [[ $(cat "${h}/.claude/settings.json") == '{}' ]] && grep -q 'home-manager switch' "${h}/err"; then
  ok "hook が無ければ止まり、switch を促す"
else
  ng "hook が無ければ止まり、switch を促す" "rc=$(cat "${h}/rc") err=$(cat "${h}/err")"
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
