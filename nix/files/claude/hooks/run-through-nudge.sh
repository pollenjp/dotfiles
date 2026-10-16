#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の PostToolUse フック (matcher Skill)。superpowers の 4 つの skill を読み込んだ直後に、
# 「確認を挟まずに PR まで走り切る」と Claude の文脈へ 1 文を差し込む (ADR 019)。
#
# 何をするかの正本は ~/.claude/CLAUDE.md の「方針を承認したら PR まで走り切る」節。skill の文面は
# 問いを出させる直前に読まれるので、その隣でこの節を思い出させるだけ。
#
# ## 知らせる場面
#
#   superpowers:brainstorming                    方針の承認に「PR まで進む」と書き添え、spec の承認を待たない
#   superpowers:writing-plans                    計画のレビューと実行方式の選択を聞かず、推奨の方式で実行に入る
#   superpowers:using-git-worktrees              worktree を作るかを聞かない
#   superpowers:finishing-a-development-branch   merge / PR / そのまま の 3 択を聞かず、push して PR を作る
#
# skill の名前は plugin の名前つき (superpowers:<名前>) だけを見る。Skill の入力には名前つきで入る。
#
# ## 黙る場面
#
#   - 上の 4 つ以外の skill・Skill 以外の tool
#   - subagent の中 (入力に agent_id がある)。subagent はユーザーに聞かないので念押しは要らない
#   - skill の読み込みが失敗したとき (tool_response.success が false)。success が無い入力は、
#     読み込めたものとして知らせる (Claude Code が入力の形を変えても黙り込まないように)
#   - 想定外の入力・jq が無いとき。tool の流れを止めないよう、何があっても exit 0 で終える
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks.PostToolUse に 1 件足す (matcher Skill)。
# hook の if で skill の名前を絞る書き方 (Skill(<名前>)) は 2.1.299 で発火しなかったので、
# 名前はここで見る。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0

command -v jq &>/dev/null || exit 0

# 入力の 1 項目を取り出す。無い・壊れている → 空文字
field() {
  jq -r "$1 // empty" <<<"${input}" 2>/dev/null || true
}

[[ $(field '.tool_name') == Skill ]] || exit 0
[[ -z $(field '.agent_id') ]] || exit 0
# field() は使わない (// は false も空にする)
[[ $(jq -r '.tool_response.success | tostring' <<<"${input}" 2>/dev/null) != false ]] || exit 0

skill=$(field '.tool_input.skill')
section='方針を承認したら PR まで走り切る'
follow='ユーザーがこの会話で別の進め方を言っていれば、そちらに従う。'

case ${skill} in
  superpowers:brainstorming)
    msg="[走り切り] ${skill} を読んだ。このユーザーは方針の承認 1 回のあと PR まで走り切る (~/.claude/CLAUDE.md「${section}」)。方針の承認を聞くとき「承認したら PR まで確認を挟まずに進める」と、その先の段階 (spec → 実装計画 → 実装 → PR など) とともに書き添える。承認のあとは spec の承認を待たずに writing-plans へ進み、builder check の問いは自分で決めて spec に「こちらの判断」として残す。${follow}"
    ;;
  superpowers:writing-plans)
    msg="[走り切り] ${skill} を読んだ。実装計画を書いたら、計画のレビューも実行方式 (Subagent-driven / Native) の選択も聞かず、推奨の方式を理由 1 文とともに告げてそのまま実行に入る (~/.claude/CLAUDE.md「${section}」)。${follow}"
    ;;
  superpowers:using-git-worktrees)
    msg="[走り切り] ${skill} を読んだ。worktree を作るかは聞かない。worktree の外なら、その場で feature branch を切って進める (main では作業しない。~/.claude/CLAUDE.md「${section}」)。${follow}"
    ;;
  superpowers:finishing-a-development-branch)
    msg="[走り切り] ${skill} を読んだ。merge / PR / そのまま の 3 択を聞かず、テストが通っていれば push して PR を作る (merge はしない)。自分で決めたこと (builder check の判断・ruling) は PR を返すときに並べる (~/.claude/CLAUDE.md「${section}」)。${follow}"
    ;;
  *)
    exit 0
    ;;
esac

jq -cn --arg msg "${msg}" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}' || true
exit 0
