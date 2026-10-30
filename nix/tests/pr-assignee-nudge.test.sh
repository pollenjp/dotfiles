#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/pr-assignee-nudge.sh の振る舞いを、合成した PostToolUse・PostToolUseFailure の入力で確かめる。
#
#   bash nix/tests/pr-assignee-nudge.test.sh [<pr-assignee-nudge.sh のパス>]
#
# flake の checks (pr-assignee-nudge-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils・grep だけ。
# skill の有無は CLAUDE_CONFIG_DIR を使い捨ての dir に向けて作り、skillOverrides を書いた settings.json も同じ dir に置く。
#
# ## 確かめること
#
#   - gh pr create が assignee を指定せずに PR を作った (出力に PR の URL がある) とき、PR の URL と
#     gh pr edit <URL> --add-assignee @me を言う文を差し込む。cd・git push とつないだもの・行を \ で継いだもの・
#     GitHub Enterprise の URL・subagent の中でも知らせ、hookEventName は来た event にする
#   - assignee の指定 (--assignee・--assignee=…・-a・-a=…・-a…・-da のように束ねたもの) があれば黙る。heredoc の
#     本文 (<<-EOF も)・引用符の中・ほかのコマンド (git commit -a) の --assignee・-a は指定と数えない
#   - 128 KB を超えるコマンド (長い日本語の本文の heredoc) も読む
#   - 出力に gh の pull request update failed があれば (PR は出来ていて、作ったあとの段で落ちた)、assignee を指定して
#     いても、作り直さずに gh pr view で確かめるよう知らせる
#   - 0 以外で終わった Bash (PostToolUseFailure) は、入力の error に入った出力を読む
#   - 既存の PR を返しただけ (a pull request for branch … already exists。stdout でも stderr でも)・PR の URL が無い
#     (--web など)・gh pr create でないコマンド・Bash でない tool・知らない event では黙る
#   - 引用符の中にだけ gh pr create があるコマンド (bash -c の中) は、引用符を外して読み直す。gh pr create が 2 つ
#     あり、片方にだけ指定があるときも知らせる
#   - skill が無いマシン・settings.json の skillOverrides で off・user-invocable-only なら黙る。on・壊れた
#     settings.json なら知らせる
#   - 壊れた入力でも黙って exit 0

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/pr-assignee-nudge.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/pr-assignee-nudge-test.XXXXXX")
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

# config_dir <dir 名> <settings.json の中身 (空なら作らない)> <skill を置くか (yes / no)> : 設定 dir を作り、パスを返す
config_dir() {
  local dir="${work}/$1"
  mkdir -p "${dir}"
  if [[ $3 == yes ]]; then
    mkdir -p "${dir}/skills/pjp-gh-pr-create"
    echo '---' >"${dir}/skills/pjp-gh-pr-create/SKILL.md"
  fi
  if [[ -n $2 ]]; then
    printf '%s' "$2" >"${dir}/settings.json"
  fi
  printf '%s' "${dir}"
}
cfg=$(config_dir default '' yes)

# run <設定 dir> <入力> : stdout を ${work}/out に、exit code を ${work}/rc に残す
run() {
  printf '%s' "$2" | HOME="${work}/home" CLAUDE_CONFIG_DIR="$1" bash "${script}" >"${work}/out" 2>"${work}/err"
  echo $? >"${work}/rc"
}
context() {
  jq -r '.hookSpecificOutput.additionalContext // empty' "${work}/out" 2>/dev/null
}
event_of() {
  jq -r '.hookSpecificOutput.hookEventName // empty' "${work}/out" 2>/dev/null
}
silent() {
  [[ ! -s ${work}/out && $(cat "${work}/rc") == 0 ]]
}
# nudged <URL> : assignee を付けるよう知らせたか (URL と、その URL への gh pr edit を言う)
nudged() {
  local c
  c=$(context)
  [[ ${c} == "[assignee] "*"($1)"* && ${c} == *"gh pr edit $1 --add-assignee @me"* && ${c} == *pjp-gh-pr-create* ]]
}

# post <コマンド> <stdout> [<stderr>] : PostToolUse の入力。コマンドは stdin から jq に渡す (--arg で渡すと、128 KB を
# 超える 1 つの引数で exec が落ちる)
post() {
  printf '%s' "$1" | jq -cRs --arg out "$2" --arg err "${3:-}" \
    '{session_id: "s", hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: .}, tool_response: {stdout: $out, stderr: $err, interrupted: false, isImage: false}}'
}
# failure <コマンド> <error> : PostToolUseFailure の入力 (0 以外で終わった Bash。出力は error に入る)
failure() {
  jq -cn --arg cmd "$1" --arg e "$2" \
    '{session_id: "s", hook_event_name: "PostToolUseFailure", tool_name: "Bash", tool_input: {command: $cmd}, tool_use_id: "t", error: $e, is_interrupt: false}'
}

url=https://github.com/o/r/pull/7

echo "== pr-assignee-nudge.sh"

# 1. assignee を指定しない gh pr create が PR を作った → URL と gh pr edit を言い、hookEventName は PostToolUse
run "${cfg}" "$(post 'gh pr create --title t --body b' "${url}")"
if nudged "${url}" && [[ $(event_of) == PostToolUse && $(cat "${work}/rc") == 0 ]]; then
  ok "assignee の無い gh pr create が PR を作ったら知らせる"
else
  ng "assignee の無い gh pr create が PR を作ったら知らせる" "rc=$(cat "${work}/rc") out=$(cat "${work}/out")"
fi

# 2. --assignee @me・--assignee=@me・"@me" を引用符で囲んだもの → 黙る
s=""
for c in 'gh pr create --title t --body b --assignee @me' 'gh pr create --assignee=@me --fill' 'gh pr create -t t -b b --assignee "@me"'; do
  run "${cfg}" "$(post "${c}" "${url}")"
  silent || s+="[${c}] $(cat "${work}/out") "
done
if [[ -z ${s} ]]; then ok "--assignee の指定があれば黙る"; else ng "--assignee の指定があれば黙る" "${s}"; fi

# 3. -a @me・-a=@me・-a@me・-da @me (-d と束ねたもの) → 黙る
s=""
for c in 'gh pr create -t t -b b -a @me' 'gh pr create -a=@me --fill' 'gh pr create -a@me --fill' 'gh pr create -da @me --fill' "gh pr create -a '@me' --fill"; do
  run "${cfg}" "$(post "${c}" "${url}")"
  silent || s+="[${c}] $(cat "${work}/out") "
done
if [[ -z ${s} ]]; then ok "-a の指定 (束ねたものも) があれば黙る"; else ng "-a の指定 (束ねたものも) があれば黙る" "${s}"; fi

# 4. cd・git push とつないだもの → 知らせる。指定があれば黙る
run "${cfg}" "$(post 'cd /r && git push -u origin feat/x && gh pr create --title t --body b' "${url}")"
r1=$(nudged "${url}" && echo yes)
run "${cfg}" "$(post 'cd /r && git push -u origin feat/x && gh pr create --title t --body b --assignee @me 2>&1 | tail -n 2' "${url}")"
if [[ ${r1} == yes ]] && silent; then
  ok "つないだコマンドの gh pr create を読む"
else
  ng "つないだコマンドの gh pr create を読む" "r1=${r1} out=$(cat "${work}/out")"
fi

# 5. 行を \ で継いだもの: 継いだ先の行の --assignee を読む
c=$'gh pr create \\\n  --title t \\\n  --body b \\\n  --assignee @me'
run "${cfg}" "$(post "${c}" "${url}")"
s1=$(silent && echo yes)
c=$'gh pr create \\\n  --title t \\\n  --body b'
run "${cfg}" "$(post "${c}" "${url}")"
if [[ ${s1} == yes ]] && nudged "${url}"; then
  ok "\\ で継いだ行の指定を読む"
else
  ng "\\ で継いだ行の指定を読む" "s1=${s1} out=$(cat "${work}/out")"
fi

# 6. heredoc の本文に --assignee・-a・引用符・gh pr create と書いても指定と数えない → 知らせる。本文の閉じない "
#    (27") の後ろも、gh pr create の語と読まない
c=$(
  cat <<'EOS'
gh pr create --title "skill を足す" --body "$(cat <<'EOF'
## 変えたこと
- 27" の画面で --assignee を試した
- gh pr create に --assignee @me を足す。-a @me でもよい
- don't "quote" me (gh pr create -a x)
EOF
)"
EOS
)
run "${cfg}" "$(post "${c}" "${url}")"
if nudged "${url}"; then
  ok "heredoc の本文の --assignee・-a は指定と数えない"
else
  ng "heredoc の本文の --assignee・-a は指定と数えない" "out=$(cat "${work}/out")"
fi

# 7. heredoc の後ろ (閉じた引用符の後) の --assignee は読む。本文の ' と " で読み違えない
c=$(
  cat <<'EOS'
gh pr create --title "it's" --body "$(cat <<'EOF'
- don't "quote" me
- 1) 箇条
EOF
)" --assignee @me
EOS
)
run "${cfg}" "$(post "${c}" "${url}")"
if silent; then
  ok "heredoc の後ろの --assignee を読む"
else
  ng "heredoc の後ろの --assignee を読む" "out=$(cat "${work}/out")"
fi

# 8. <<-EOF (終わりの印の前にタブ) と、--body-file - の heredoc: 本文の指定は数えない
c=$'gh pr create --title t --body-file - <<-EOF\n\t--assignee @me\n\tEOF'
run "${cfg}" "$(post "${c}" "${url}")"
r1=$(nudged "${url}" && echo yes)
c=$'gh pr create --title t --body-file - --assignee @me <<\'EOF\'\nbody\nEOF'
run "${cfg}" "$(post "${c}" "${url}")"
if [[ ${r1} == yes ]] && silent; then
  ok "<<-EOF と --body-file - の heredoc の本文は数えず、heredoc の前の指定は読む"
else
  ng "<<-EOF と --body-file - の heredoc の本文は数えず、heredoc の前の指定は読む" "r1=${r1} out=$(cat "${work}/out")"
fi

# 8b. 128 KB を超えるコマンド (長い日本語の本文の heredoc) も読む。指定が無ければ知らせ、あれば黙る
long=$(printf 'あいうえおかきくけこ%.0s' {1..5000})
c=$'gh pr create --title t --body "$(cat <<\'EOF\'\n'"${long}"$'\nEOF\n)"'
run "${cfg}" "$(post "${c}" "${url}")"
r1=$(nudged "${url}" && echo yes)
run "${cfg}" "$(post "${c} --assignee @me" "${url}")"
if [[ ${#c} -gt 50000 && ${r1} == yes ]] && silent; then
  ok "128 KB を超えるコマンドも読む"
else
  ng "128 KB を超えるコマンドも読む" "len=${#c} r1=${r1} rc=$(cat "${work}/rc") out=$(cat "${work}/out")"
fi

# 9. 引用符の中の -a・--assignee (タイトル) と、ほかのコマンドの -a (git commit -a) は指定と数えない → 知らせる
s=""
for c in 'gh pr create --title "x -a y" --body b' "gh pr create --title 'use --assignee' --body b" 'git commit -a -m m && gh pr create --title t --body b'; do
  run "${cfg}" "$(post "${c}" "${url}")"
  nudged "${url}" || s+="[${c}] $(cat "${work}/out") "
done
if [[ -z ${s} ]]; then ok "引用符の中とほかのコマンドの -a・--assignee は数えない"; else ng "引用符の中とほかのコマンドの -a・--assignee は数えない" "${s}"; fi

# 10. 値を $( ) で渡したもの (引用符の中の $( ) も) の後ろの指定を読む
# shellcheck disable=SC2016 # hook に渡すコマンドの $( ) を文字のまま書く
run "${cfg}" "$(post 'gh pr create --title "$(git log -1 --format=%s)" --body b --assignee @me' "${url}")"
if silent; then
  ok "\$( ) で渡した値の後ろの指定を読む"
else
  ng "\$( ) で渡した値の後ろの指定を読む" "out=$(cat "${work}/out")"
fi

# 11. 案内の行に挟まれた URL と GitHub Enterprise の URL を拾う
run "${cfg}" "$(post 'gh pr create --title t --body b' $'\nhttps://ghe.example.co.jp/org/repo/pull/12\n' $'Creating pull request for feat/x into main in org/repo\nWarning: 1 uncommitted change')"
if nudged https://ghe.example.co.jp/org/repo/pull/12; then
  ok "案内の行に挟まれた GitHub Enterprise の URL を拾う"
else
  ng "案内の行に挟まれた GitHub Enterprise の URL を拾う" "out=$(cat "${work}/out")"
fi

# 12. 既存の PR を返しただけ (stdout に出たもの・stderr に出たもの) → 黙る。gh のその文でない already exists では知らせる
exists=$'a pull request for branch "feat/x" into branch "main" already exists:\nhttps://github.com/o/r/pull/3'
run "${cfg}" "$(post 'gh pr create --title t --body b 2>&1 | tail -n 2' "${exists}")"
s1=$(silent && echo yes)
run "${cfg}" "$(post 'gh pr create --title t --body b || true' '' "${exists}")"
s2=$(silent && echo yes)
run "${cfg}" "$(post 'gh pr create --title t --body b 2>&1 | tail -n 2' $'warning: tag v1 already exists\nhttps://github.com/o/r/pull/8')"
if [[ ${s1} == yes && ${s2} == yes ]] && nudged https://github.com/o/r/pull/8; then
  ok "既存の PR を返しただけなら黙り、ほかの文の already exists では知らせる"
else
  ng "既存の PR を返しただけなら黙り、ほかの文の already exists では知らせる" "s1=${s1} s2=${s2} out=$(cat "${work}/out")"
fi

# 13. PR の URL が無い (作れなかった・--web で開いただけ・push の案内の pull/new) → 黙る
s=""
run "${cfg}" "$(post 'gh pr create --title t --body b 2>&1 | tail -n 1' 'pull request create failed: GraphQL: No commits between main and feat/x (createPullRequest)')"
silent || s+="[create failed] $(cat "${work}/out") "
run "${cfg}" "$(post 'gh pr create --web' '' 'Opening https://github.com/o/r/compare/main...feat/x in your browser.')"
silent || s+="[--web] $(cat "${work}/out") "
run "${cfg}" "$(post 'git push -u origin feat/x 2>&1 && gh pr create --web' $'remote: Create a pull request for \'feat/x\' on GitHub by visiting:\nremote:      https://github.com/o/r/pull/new/feat/x')"
silent || s+="[pull/new] $(cat "${work}/out") "
if [[ -z ${s} ]]; then ok "PR の URL が無ければ黙る"; else ng "PR の URL が無ければ黙る" "${s}"; fi

# 14. gh pr create でないコマンドの出力の PR の URL (gh pr view・heredoc の本文にだけ gh pr create と書いたもの) → 黙る
s=""
run "${cfg}" "$(post 'gh pr view 7 --json url --jq .url' "${url}")"
silent || s+="[gh pr view] $(cat "${work}/out") "
run "${cfg}" "$(post $'cat <<\'EOF\' >notes.md\ngh pr create を打つ\nEOF\ngh pr view 7 --json url --jq .url' "${url}")"
silent || s+="[heredoc] $(cat "${work}/out") "
if [[ -z ${s} ]]; then ok "gh pr create でないコマンドでは黙る"; else ng "gh pr create でないコマンドでは黙る" "${s}"; fi

# 15. 引用符の中にだけ gh pr create がある (bash -c の中) → 引用符を外して読み直す
run "${cfg}" "$(post "bash -c 'gh pr create --title t --body b'" "${url}")"
r1=$(nudged "${url}" && echo yes)
run "${cfg}" "$(post "bash -c 'gh pr create --title t --body b --assignee @me' && git commit -a -m m" "${url}")"
if [[ ${r1} == yes ]] && silent; then
  ok "引用符の中にだけ gh pr create があれば、引用符を外して読み直す"
else
  ng "引用符の中にだけ gh pr create があれば、引用符を外して読み直す" "r1=${r1} out=$(cat "${work}/out")"
fi

# 16. gh pr create が 2 つあり、片方にだけ指定がある → 知らせる (URL は最後のもの)
run "${cfg}" "$(post 'gh pr create -R o/a --fill --assignee @me && gh pr create -R o/r --fill' $'https://github.com/o/a/pull/1\nhttps://github.com/o/r/pull/7')"
if nudged "${url}"; then
  ok "指定の無い gh pr create が 1 つでもあれば知らせる"
else
  ng "指定の無い gh pr create が 1 つでもあれば知らせる" "out=$(cat "${work}/out")"
fi

# 17. PostToolUseFailure: gh pr create の後ろにつないだコマンドが落ちた → error の URL で知らせ、hookEventName を合わせる
run "${cfg}" "$(failure 'gh pr create --title t --body b && false' $'Exit code 1\nhttps://github.com/o/r/pull/7')"
if nudged "${url}" && [[ $(event_of) == PostToolUseFailure ]]; then
  ok "PostToolUseFailure の error の URL で知らせる"
else
  ng "PostToolUseFailure の error の URL で知らせる" "out=$(cat "${work}/out")"
fi

# 18. pull request update failed (作ったあとの段で落ちた): 指定があっても、作り直さずに確かめるよう知らせる
#     (PostToolUseFailure の error に出たもの・2>&1 | tail で stdout に出たもの)
update=$'https://github.com/o/r/pull/7\npull request update failed: GraphQL: pollenjp does not have the correct permissions to execute `ReplaceActorsForAssignable` (replaceActorsForAssignable)'
run "${cfg}" "$(failure 'gh pr create --title t --body b --assignee @me' $'Exit code 1\n'"${update}")"
r1=$(context)
e1=$(event_of)
run "${cfg}" "$(post 'gh pr create --title t --body b --assignee @me 2>&1 | tail -n 2' "${update}")"
r2=$(context)
if [[ ${r1} == "[assignee] "*"pull request update failed"*"(${url})"*"作り直さず"*"gh pr view ${url}"*"gh pr edit ${url} --add-assignee @me"* && ${e1} == PostToolUseFailure && ${r2} == "${r1}" ]]; then
  ok "pull request update failed なら、指定があっても作り直さずに確かめるよう知らせる"
else
  ng "pull request update failed なら、指定があっても作り直さずに確かめるよう知らせる" "r1=${r1} e1=${e1} r2=${r2}"
fi

# 19. subagent の中 (agent_id がある) でも知らせる (subagent も PR を出す)
run "${cfg}" "$(post 'gh pr create --title t --body b' "${url}" | jq -c '. + {agent_id: "agent-1", agent_type: "general-purpose"}')"
if nudged "${url}"; then
  ok "subagent の中でも知らせる"
else
  ng "subagent の中でも知らせる" "out=$(cat "${work}/out")"
fi

# 20. Bash でない tool・知らない event・壊れた入力 → 黙って exit 0
s=""
run "${cfg}" "$(post 'gh pr create --title t --body b' "${url}" | jq -c '.tool_name = "Write"')"
silent || s+="[Write] $(cat "${work}/out") "
run "${cfg}" "$(post 'gh pr create --title t --body b' "${url}" | jq -c '.hook_event_name = "PreToolUse"')"
silent || s+="[PreToolUse] $(cat "${work}/out") "
run "${cfg}" '{"tool_name": "Bash", '
silent || s+="[壊れた入力] rc=$(cat "${work}/rc") $(cat "${work}/out") "
run "${cfg}" "$(post 'gh pr create --title t --body b' "${url}" | jq -c '.tool_response = "x"')"
silent || s+="[tool_response が文字列] rc=$(cat "${work}/rc") $(cat "${work}/out") "
if [[ -z ${s} ]]; then ok "Bash でない tool・知らない event・壊れた入力では黙って exit 0"; else ng "Bash でない tool・知らない event・壊れた入力では黙って exit 0" "${s}"; fi

# 21. skill が無いマシン → 黙る
cfg2=$(config_dir no-skill '' no)
run "${cfg2}" "$(post 'gh pr create --title t --body b' "${url}")"
if silent; then ok "skill が無いマシンでは黙る"; else ng "skill が無いマシンでは黙る" "out=$(cat "${work}/out")"; fi

# 22. skillOverrides で off・user-invocable-only → 黙る。on・ほかの skill だけ off・壊れた settings.json → 知らせる
s=""
for v in off user-invocable-only; do
  cfg2=$(config_dir "override-${v}" "{\"skillOverrides\":{\"pjp-gh-pr-create\":\"${v}\"}}" yes)
  run "${cfg2}" "$(post 'gh pr create --title t --body b' "${url}")"
  silent || s+="[${v}] $(cat "${work}/out") "
done
for pair in 'on|{"skillOverrides":{"pjp-gh-pr-create":"on"}}' 'other|{"skillOverrides":{"pjp-dev-tracker":"off"}}' 'broken|{"skillOverrides": '; do
  cfg2=$(config_dir "override-${pair%%|*}" "${pair#*|}" yes)
  run "${cfg2}" "$(post 'gh pr create --title t --body b' "${url}")"
  nudged "${url}" || s+="[${pair%%|*}] rc=$(cat "${work}/rc") $(cat "${work}/out") "
done
if [[ -z ${s} ]]; then
  ok "skillOverrides で off・user-invocable-only なら黙り、on・ほかの skill・壊れた settings.json では知らせる"
else
  ng "skillOverrides で off・user-invocable-only なら黙り、on・ほかの skill・壊れた settings.json では知らせる" "${s}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
