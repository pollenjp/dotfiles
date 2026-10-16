#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/run-through-nudge.sh の振る舞いを、合成した PostToolUse の入力で確かめる。
#
#   bash nix/tests/run-through-nudge.test.sh [<run-through-nudge.sh のパス>]
#
# flake の checks (run-through-nudge-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils だけ。
# 期待する 4 つの文は ADR 019 §2 B の表から写したもので、hook の中の組み立て方に依らずに比べる。
#
# ## 確かめること
#
#   - superpowers の 4 つの skill (brainstorming・writing-plans・using-git-worktrees・
#     finishing-a-development-branch) の読み込みで、ADR 019 の表のとおりの 1 文を返す
#   - tool_response に success が無い入力でも知らせる
#   - それ以外 (他の skill・plugin の名前が無い / 違う同名の skill・Skill 以外の tool) では黙る
#   - subagent の中・読み込みに失敗した skill・壊れた入力・空の入力・jq が無いときも黙り、いつも exit 0

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/run-through-nudge.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/run-through-nudge-test.XXXXXX")
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

# run <入力> : stdout を ${work}/out に、exit code を ${work}/rc に残す
run() {
  printf '%s' "$1" | bash "${script}" >"${work}/out" 2>"${work}/err"
  echo $? >"${work}/rc"
}
context() {
  jq -r '.hookSpecificOutput.additionalContext // empty' "${work}/out" 2>/dev/null
}
silent() {
  [[ ! -s ${work}/out && $(cat "${work}/rc") == 0 ]]
}
# 知らせたか: exit 0・1 行の JSON・hookEventName が PostToolUse・文が $1 と同じ
nudged_with() {
  [[ $(cat "${work}/rc") == 0 ]] \
    && [[ $(wc -l <"${work}/out") == 1 ]] \
    && [[ $(jq -r '.hookSpecificOutput.hookEventName // empty' "${work}/out" 2>/dev/null) == PostToolUse ]] \
    && [[ $(context) == "$1" ]]
}
detail() {
  echo "rc=$(cat "${work}/rc") out=$(cat "${work}/out") err=$(cat "${work}/err")"
}

# skill_input <skill> [<success: true / false / none>]。none は success の無い tool_response
skill_input() {
  case ${2:-true} in
    none)
      jq -cn --arg s "$1" \
        '{session_id: "s", hook_event_name: "PostToolUse", tool_name: "Skill", tool_input: {skill: $s}, tool_response: {commandName: $s}}'
      ;;
    *)
      jq -cn --arg s "$1" --argjson ok "${2:-true}" \
        '{session_id: "s", hook_event_name: "PostToolUse", tool_name: "Skill", tool_input: {skill: $s}, tool_response: {success: $ok, commandName: $s}}'
      ;;
  esac
}

# ADR 019 §2 B の表の 4 文
want_brainstorming='[走り切り] superpowers:brainstorming を読んだ。このユーザーは方針の承認 1 回のあと PR まで走り切る (~/.claude/CLAUDE.md「方針を承認したら PR まで走り切る」)。方針の承認は spec を書く前に 1 回聞き、「承認したら PR まで確認を挟まずに進める」と、その先の段階 (spec → 実装計画 → 実装 → PR など) とともに書き添える。承認のあとは spec の承認を待たずに writing-plans へ進み、builder check の問いは自分で決めて spec に「こちらの判断」として残す。ユーザーがこの会話で別の進め方を言っていれば、そちらに従う。'
want_writing_plans='[走り切り] superpowers:writing-plans を読んだ。この会話で「承認したら PR まで確認を挟まずに進める」と書き添えた方針の承認を得ていれば、実装計画を書いたあと、計画のレビューも実行方式 (Subagent-driven / Native) の選択も聞かず、推奨の方式を理由 1 文とともに告げてそのまま実行に入る。まだ得ていなければ、計画と推奨の方式を見せるときに 1 回だけ、同じく書き添えて承認を聞く (~/.claude/CLAUDE.md「方針を承認したら PR まで走り切る」)。ユーザーがこの会話で別の進め方を言っていれば、そちらに従う。'
want_worktrees='[走り切り] superpowers:using-git-worktrees を読んだ。worktree を作るかは聞かない。worktree の外なら、その場で既定の branch から feature branch を切って進める (main では作業しない。~/.claude/CLAUDE.md「方針を承認したら PR まで走り切る」)。ユーザーがこの会話で別の進め方を言っていれば、そちらに従う。'
want_finishing='[走り切り] superpowers:finishing-a-development-branch を読んだ。この会話で「承認したら PR まで確認を挟まずに進める」と書き添えた方針の承認を得ていれば、merge / PR / そのまま の 3 択を聞かず、テストが通っていれば push して PR を作る (merge はしない)。push の前に、PR に載る commit が今回の作業だけかを git log で確かめ、他の commit が混ざっていれば止まって聞く。自分で決めたこと (builder check の判断・ruling) は PR を返すときに並べる。まだ承認を得ていなければ、3 択の代わりに PR を出してよいかを 1 回だけ聞く (~/.claude/CLAUDE.md「方針を承認したら PR まで走り切る」)。ユーザーがこの会話で別の進め方を言っていれば、そちらに従う。'

# expect_nudge <skill> <期待する文>
expect_nudge() {
  run "$(skill_input "$1")"
  if nudged_with "$2"; then
    ok "$1 を読んだら、表のとおりの文で知らせる"
  else
    ng "$1 を読んだら、表のとおりの文で知らせる" "$(detail)"
  fi
}
# expect_silent <説明> <入力>
expect_silent() {
  run "$2"
  if silent; then
    ok "$1"
  else
    ng "$1" "$(detail)"
  fi
}

echo "== run-through-nudge.sh"

# 1〜4. 4 つの skill → 表のとおりの文
expect_nudge superpowers:brainstorming "${want_brainstorming}"
expect_nudge superpowers:writing-plans "${want_writing_plans}"
expect_nudge superpowers:using-git-worktrees "${want_worktrees}"
expect_nudge superpowers:finishing-a-development-branch "${want_finishing}"

# 5. tool_response に success が無い → 読み込めたものとして知らせる
run "$(skill_input superpowers:writing-plans none)"
if nudged_with "${want_writing_plans}"; then
  ok "success の無い入力でも知らせる"
else
  ng "success の無い入力でも知らせる" "$(detail)"
fi

# 6. 他の superpowers の skill → 黙る
expect_silent "他の superpowers の skill では黙る" "$(skill_input superpowers:test-driven-development)"

# 7. plugin の名前が無い・違う同名の skill → 黙る
run "$(skill_input writing-plans)"
s1=$(silent && echo yes)
run "$(skill_input other:writing-plans)"
if [[ ${s1} == yes ]] && silent; then
  ok "plugin の名前が無い・違う同名の skill では黙る"
else
  ng "plugin の名前が無い・違う同名の skill では黙る" "s1=${s1} $(detail)"
fi

# 8. 自作の skill → 黙る
expect_silent "自作の skill では黙る" "$(skill_input pjp-cc-page)"

# 9. Skill 以外の tool → 黙る
expect_silent "Skill 以外の tool では黙る" "$(jq -cn '{session_id: "s", hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: "echo superpowers:writing-plans"}, tool_response: {stdout: "superpowers:writing-plans", stderr: ""}}')"

# 10. subagent の中 (agent_id がある) → 黙る
expect_silent "subagent の中では黙る" "$(skill_input superpowers:writing-plans | jq -c '. + {agent_id: "agent-1", agent_type: "general-purpose"}')"

# 11. 読み込みに失敗 (success が false) → 黙る
expect_silent "読み込みに失敗した skill では黙る" "$(skill_input superpowers:writing-plans false)"

# 12. 壊れた入力・空の入力 → 黙って exit 0
run '{"tool_name": "Skill", '
s1=$(silent && echo yes)
run ''
if [[ ${s1} == yes ]] && silent; then
  ok "壊れた入力・空の入力でも黙って exit 0"
else
  ng "壊れた入力・空の入力でも黙って exit 0" "s1=${s1} $(detail)"
fi

# 13. jq が無い → 黙って exit 0 (PATH には cat だけを置き、bash は絶対パスで起動する)
nojq="${work}/nojq"
mkdir -p "${nojq}"
ln -s "$(command -v cat)" "${nojq}/cat"
bash_bin=$(command -v bash)
skill_input superpowers:writing-plans >"${work}/in"
PATH="${nojq}" "${bash_bin}" "${script}" <"${work}/in" >"${work}/out" 2>"${work}/err"
echo $? >"${work}/rc"
if silent; then
  ok "jq が無いときは黙って exit 0"
else
  ng "jq が無いときは黙って exit 0" "$(detail)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
