#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/op-reason-guard.sh (Claude の op.exe の直打ちを止め、op の承認の拒否・時間切れのあとは問いを出させる
# hook) を、使い捨ての HOME と作り物の op の記録で確かめる。
#
#   bash nix/tests/op-reason-guard.test.sh [<op-reason-guard.sh のパス>]
#
# flake の checks (op-reason-guard-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils と偽の herdr。
#
# ## 確かめること
#
#   打つ前 (PreToolUse)
#     - op.exe を直に起こすコマンドは止める (deny)。パスつき (\ の Windows のパスも)・大文字・timeout や env で包んだもの・
#       cd の後・bash -c の中・パイプの先・$( ) の中・powershell (pwsh) の -Command・-c の中・cmd の /c の中も。返す文に
#       op --reason と、呼ぶ回数を減らす例と、Bash の timeout を長くする勧めと、止めたコマンドがある
#     - op.exe の文字があっても起こさないものは止めない: grep の引数・commit のメッセージ・heredoc の本文・command -v・ls の
#       引数・コメント。op --reason … (wrapper) と、承認の要らない op.exe の whoami・signout・--version・--help も止めない
#     - claude-op-reason.json が無い・enable が false のマシンでは何も止めない
#   拒否・時間切れのあと (PostToolUse・PostToolUseFailure)
#     - この会話の end が denied なら、打ち直さない指示と ①②③ の問い・時刻・理由・コマンド・どこからを additionalContext に、
#       1 行を systemMessage に出す。hookEventName は入力の event
#     - timeout なら時間切れの文、interrupted (承認を待つ間に止められた) なら止められた文と Bash の timeout の勧め
#     - この会話の refused が lock-timeout (ほかの op の承認待ちが終わらない)・interrupted (それを待つ間に止められた) でも
#       問いを出させる。refused のほかの why (no-reason など) では何も出さない
#     - ほかの会話の end・approved・failed では何も出さない。同じ end は 2 回目に出さない (見た印)
#     - subagent (入力に agent_id) では、問いを出させず報告に書かせる
#     - herdr の workspace に子の印 (token parent) があれば、AskUserQuestion を使わずに問いを書くと言い切る
#     - hc の端末 (HC_TERMINAL_ID がある) では、hc get <端末> --json に親の端末か label pjp.role=child があれば hc の子の決まりを
#       言い切り、どちらも無ければ条件つきで書く。どちらでも、漏れた HERDR_ENV があっても herdr を呼ばない
#
# ## 作り
#
# 偽の herdr は workspace get に FAKE_HERDR_JSON を返す。記録は XDG_STATE_HOME の pjp-op/log.jsonl に jq で並べる。
# shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/op-reason-guard.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/op-reason-guard-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

export LC_ALL=C.UTF-8
export HOME=${work}/home XDG_STATE_HOME=${work}/state
mkdir -p "${HOME}/.local/state/dotfiles" "${XDG_STATE_HOME}/pjp-op" "${work}/bin"
unset HERDR_ENV HERDR_WORKSPACE_ID
state=${HOME}/.local/state/dotfiles/claude-op-reason.json
echo '{"enable":true}' >"${state}"
log=${XDG_STATE_HOME}/pjp-op/log.jsonl

{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
if [[ "$1 $2" == "workspace get" ]]; then
  printf '%s\n' "${FAKE_HERDR_JSON:-{\}}"
  exit 0
fi
exit 1
EOF
} >"${work}/bin/herdr"
chmod +x "${work}/bin/herdr"
export PATH=${work}/bin:${PATH}
# 手元 (hc の端末の中の Claude の会話) で流しても同じになるよう、hc の端末の印を外す (hc のケースは最後に足す)
unset HC_TERMINAL_ID

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

# pre <コマンド>: PreToolUse で流す
pre() {
  jq -cn --arg c "$1" \
    '{session_id: "s1", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: "/w"}' >"${work}/in"
  bash "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
}

# post <event> [agent_id]: PostToolUse か PostToolUseFailure で流す
post() {
  jq -cn --arg ev "$1" --arg agent "${2:-}" \
    '{session_id: "s1", hook_event_name: $ev, tool_name: "Bash", tool_input: {command: "op --reason x item get a"}, cwd: "/w"}
     + (if $agent == "" then {} else {agent_id: $agent, agent_type: "general-purpose"} end)' >"${work}/in"
  bash "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
}

denied() {
  [[ $(cat "${work}/rc") == 0 && $(jq -r '.hookSpecificOutput.permissionDecision // empty' "${work}/stdout" 2>/dev/null) == deny ]]
}
silent() {
  [[ $(cat "${work}/rc") == 0 && ! -s ${work}/stdout ]]
}
detail() {
  echo "rc=$(cat "${work}/rc") stdout=$(cat "${work}/stdout") stderr=$(cat "${work}/stderr")"
}
context() {
  jq -r '.hookSpecificOutput.additionalContext // empty' "${work}/stdout" 2>/dev/null
}

echo "== 打つ前"
# shellcheck disable=SC2016 # $( ) の中の op.exe を確かめる (展開しない)
for c in 'op.exe vault list' '/mnt/c/x/op.exe item get a' 'OP.EXE item get a' 'timeout 30 op.exe item get a' \
  'env A=1 op.exe read op://v/i/f' 'cd x && op.exe item get a' "bash -c 'op.exe item list'" \
  'echo x | op.exe item create -' 'v=$(op.exe read op://v/i/f)' 'powershell.exe -NoProfile -Command "op.exe item list"' \
  "pwsh -c 'op.exe item list'" 'cmd.exe /c op.exe item list' "'C:\\x\\op.exe' item get a"; do
  pre "${c}"
  if denied; then
    ok "止める: ${c}"
  else
    ng "止める: ${c}" "$(detail)"
  fi
done
pre 'op.exe vault list'
why=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "${work}/stdout")
if [[ ${why} == *'op --reason'* && ${why} == *'vault list --format json'* && ${why} == *呼ぶ回数を減らす* &&
  ${why} == *600000* && ${why} == *"(止めたもの: op.exe vault list)"* ]]; then
  ok "返す文に op --reason と、呼ぶ回数を減らす例と、Bash の timeout の勧めと、止めたコマンドがある"
else
  ng "返す文に op --reason と、呼ぶ回数を減らす例と、Bash の timeout の勧めと、止めたコマンドがある" "${why}"
fi
for c in 'grep -rn op.exe nix/' 'git commit -m "op.exe を直す"' $'cat <<\'EOF\'\nop.exe item get a\nEOF' \
  'command -v op.exe' 'ls /mnt/c/x/op.exe' 'echo hi # op.exe item get a' 'op --reason "x" item get a' \
  'op.exe --version' 'op.exe whoami' 'op.exe signout' 'op.exe --help' 'op.exe'; do
  pre "${c}"
  if silent; then
    ok "止めない: ${c//$'\n'/⏎}"
  else
    ng "止めない: ${c//$'\n'/⏎}" "$(detail)"
  fi
done
echo '{"enable":false}' >"${state}"
pre 'op.exe vault list'
if silent; then
  ok "enable が false のマシンでは止めない"
else
  ng "enable が false のマシンでは止めない" "$(detail)"
fi
rm -f "${state}"
pre 'op.exe vault list'
if silent; then
  ok "claude-op-reason.json が無いマシンでは止めない"
else
  ng "claude-op-reason.json が無いマシンでは止めない" "$(detail)"
fi
echo '{"enable":true}' >"${state}"

echo "== 拒否・時間切れのあと"
# put_call <id> <session> <result> <epoch>: start と end を記録に足す
put_call() {
  jq -cn --arg id "$1" --arg s "$2" --argjson e "$4" \
    '{v: 1, id: $id, event: "start", time: "2026-11-08T10:11:12+09:00", epoch: $e, session: $s, mode: "desktop", kind: "desktop",
      caller: {type: "claude", herdr: {workspace: "wX", label: "TKT-1 テスト", pane: "wX:p1"}},
      reason: "設定を読む", args: ["item", "get", "a"]}' >>"${log}"
  jq -cn --arg id "$1" --arg s "$2" --arg r "$3" --argjson e "$4" \
    '{v: 1, id: $id, event: "end", time: "2026-11-08T10:11:20+09:00", epoch: ($e + 8), session: $s, result: $r, exit: 1, seconds: 8}' \
    >>"${log}"
}
reset_log() {
  rm -rf "${XDG_STATE_HOME}/pjp-op"
  mkdir -p "${XDG_STATE_HOME}/pjp-op"
}

reset_log
put_call a s1 denied 1000
post PostToolUseFailure
ctx=$(context)
if [[ ${ctx} == *打ち直さない* && ${ctx} == *①* && ${ctx} == *②* && ${ctx} == *③* && ${ctx} == *10:11:20* &&
  ${ctx} == *設定を読む* && ${ctx} == *"op item get a"* && ${ctx} == *"workspace「TKT-1 テスト」・pane wX:p1"* &&
  $(jq -r '.systemMessage // empty' "${work}/stdout") == *拒否* &&
  $(jq -r '.hookSpecificOutput.hookEventName' "${work}/stdout") == PostToolUseFailure ]]; then
  ok "この会話の denied で、打ち直さない指示と ①②③ の問い・時刻・理由・コマンド・どこからを出す"
else
  ng "この会話の denied で、打ち直さない指示と ①②③ の問い・時刻・理由・コマンド・どこからを出す" "$(detail)"
fi
post PostToolUseFailure
if silent; then
  ok "同じ end は 2 回目に出さない"
else
  ng "同じ end は 2 回目に出さない" "$(detail)"
fi
sleep 0.01
put_call b s1 timeout 2000
post PostToolUse
if [[ $(context) == *時間切れ* && $(jq -r '.hookSpecificOutput.hookEventName' "${work}/stdout") == PostToolUse ]]; then
  ok "timeout なら時間切れの文 (hookEventName は PostToolUse)"
else
  ng "timeout なら時間切れの文 (hookEventName は PostToolUse)" "$(detail)"
fi
for case in "s2 denied" "s1 approved" "s1 failed"; do
  read -r s r <<<"${case}"
  reset_log
  put_call c "${s}" "${r}" 3000
  post PostToolUse
  if silent; then
    ok "何も出さない: session ${s} の ${r}"
  else
    ng "何も出さない: session ${s} の ${r}" "$(detail)"
  fi
done
reset_log
put_call i s1 interrupted 3500
post PostToolUseFailure
if [[ $(context) == *止められた* && $(context) == *600000* && $(context) == *拒否してもらう* ]]; then
  ok "interrupted なら止められた文と、Bash の timeout を長くして打ち直す選択肢"
else
  ng "interrupted なら止められた文と、Bash の timeout を長くして打ち直す選択肢" "$(detail)"
fi
# put_refused <session> <why> <epoch>: refused を記録に足す
put_refused() {
  jq -cn --arg s "$1" --arg why "$2" --argjson e "$3" \
    '{v: 1, id: "r", event: "refused", time: "2026-11-08T10:12:00+09:00", epoch: $e, session: $s, why: $why,
      caller: {type: "claude", herdr: null}, reason: "待たされる", args: ["item", "get", "b"]}' >>"${log}"
}
for case in "lock-timeout:承認待ちが終わらず" "interrupted:承認待ちを待つ間に止められた"; do
  reset_log
  put_refused s1 "${case%%:*}" 3600
  post PostToolUseFailure
  if [[ $(context) == *"${case#*:}"* && $(context) == *"op item get b"* && $(context) == *"herdr の外の会話"* ]]; then
    ok "refused の ${case%%:*} でも問いを出させる"
  else
    ng "refused の ${case%%:*} でも問いを出させる" "$(detail)"
  fi
done
reset_log
put_refused s1 no-reason 3700
post PostToolUseFailure
if silent; then
  ok "refused の no-reason では何も出さない"
else
  ng "refused の no-reason では何も出さない" "$(detail)"
fi
reset_log
put_call d s1 denied 4000
post PostToolUse agent-1
if [[ $(context) == *"subagent の中なので、ユーザーには聞かない"* && $(context) != *①* ]]; then
  ok "subagent では問いを出させず報告に書かせる"
else
  ng "subagent では問いを出させず報告に書かせる" "$(detail)"
fi
reset_log
put_call e s1 denied 5000
export HERDR_ENV=1 HERDR_WORKSPACE_ID=wX
export FAKE_HERDR_JSON='{"result":{"workspace":{"label":"dotfiles: op","tokens":{"parent":"↑ TKT-1"}}}}'
post PostToolUse
unset HERDR_ENV HERDR_WORKSPACE_ID FAKE_HERDR_JSON
if [[ $(context) == *"この pane は herdr の指揮役の子"* && $(context) == *"AskUserQuestion を使わず"* ]]; then
  ok "herdr の子の印があれば、AskUserQuestion を使わずに問いを書くと言い切る"
else
  ng "herdr の子の印があれば、AskUserQuestion を使わずに問いを書くと言い切る" "$(detail)"
fi

# hc (herdr-core) の端末 (HC_TERMINAL_ID がある): hc get <端末> --json の親の端末か label pjp.role=child で見分け、HERDR_ENV が
# 漏れていても herdr を呼ばない。偽の hc は get に FAKE_HC_JSON を返し、偽の herdr (子の印のある workspace を返す) は呼ばれた
# ことを herdr.calls に残す。どちらも PATH の先頭の dir に置く
mkdir -p "${work}/bin-hc"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
if [[ $1 == get && $3 == --json ]]; then
  printf '%s\n' "${FAKE_HC_JSON:-{\}}"
  exit 0
fi
exit 1
EOF
} >"${work}/bin-hc/hc"
{
  printf '#!%s\n' "${BASH}"
  printf 'echo "$*" >>%q\n' "${work}/herdr.calls"
  printf '%s\n' "echo '{\"result\":{\"workspace\":{\"label\":\"🌱 dotfiles: op\",\"tokens\":{\"parent\":\"↑ TKT-1\"}}}}'"
} >"${work}/bin-hc/herdr"
chmod +x "${work}/bin-hc/hc" "${work}/bin-hc/herdr"
# hc_case <id> <epoch> <hc get の JSON>: この会話の denied を記録に置き、hc の端末の env (漏れた HERDR_* も) で PostToolUse を流す
hc_case() {
  local saved_path=${PATH}
  reset_log
  put_call "$1" s1 denied "$2"
  : >"${work}/herdr.calls"
  export PATH="${work}/bin-hc:${PATH}" HC_TERMINAL_ID=t1h HERDR_ENV=1 HERDR_WORKSPACE_ID=wX FAKE_HC_JSON="$3"
  post PostToolUse
  export PATH="${saved_path}"
  unset HC_TERMINAL_ID HERDR_ENV HERDR_WORKSPACE_ID FAKE_HC_JSON
}
hc_case f 6000 '{"address":"t1h","name":"dotfiles-x","parent":"e56d/t8","labels":{"herdr.space":"sp1"}}'
if [[ $(context) == *"この端末は hc の指揮役の子"* && $(context) == *"AskUserQuestion を使わず"* && ! -s ${work}/herdr.calls ]]; then
  ok "hc の端末で親の端末がいれば、herdr を呼ばずに hc の子の決まりを言い切る"
else
  ng "hc の端末で親の端末がいれば、herdr を呼ばずに hc の子の決まりを言い切る" "$(detail) herdr=$(cat "${work}/herdr.calls")"
fi
hc_case g 7000 '{"address":"t1h","parent":null,"labels":{"pjp.role":"child"}}'
if [[ $(context) == *"この端末は hc の指揮役の子"* && ! -s ${work}/herdr.calls ]]; then
  ok "hc の端末で label pjp.role=child なら、親が無くても hc の子の決まりを言い切る"
else
  ng "hc の端末で label pjp.role=child なら、親が無くても hc の子の決まりを言い切る" "$(detail) herdr=$(cat "${work}/herdr.calls")"
fi
hc_case h 8000 '{"address":"t1h","parent":null,"labels":{"pjp.role":"hub"}}'
ctx=$(context)
if [[ ${ctx} == *"herdr や hc の指揮役から依頼を受けて動いている子は"* && ${ctx} != *"指揮役の子 ("* && ! -s ${work}/herdr.calls ]]; then
  ok "hc の端末で親も label pjp.role=child も無ければ、漏れた HERDR_ENV の workspace に子の印があっても herdr を呼ばず、条件つきで書く"
else
  ng "hc の端末で親も label pjp.role=child も無ければ、漏れた HERDR_ENV の workspace に子の印があっても herdr を呼ばず、条件つきで書く" \
    "$(detail) herdr=$(cat "${work}/herdr.calls")"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
