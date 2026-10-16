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
#   superpowers:brainstorming                    方針の承認を spec の前に 1 回聞き、「PR まで進む」と書き添える。
#                                                承認のあとは spec の承認を待たない
#   superpowers:writing-plans                    書き添えつきの承認を得ていれば、計画のレビューと実行方式の選択を
#                                                聞かずに推奨の方式で実行に入る。得ていなければ、ここで 1 回だけ聞く
#   superpowers:using-git-worktrees              worktree を作るかを聞かない (外なら既定の branch から切る)
#   superpowers:finishing-a-development-branch   書き添えつきの承認を得ていれば、3 択を聞かずに push して PR を作る
#                                                (載る commit を先に確かめる)。得ていなければ、PR を出してよいかだけ聞く
#
# writing-plans と finishing は、承認を得ていない会話 (計画だけ頼まれたなど) で告げずに push と PR まで
# 進まないよう、「承認を得ていれば」の条件つきにしてある (ADR 019)。
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
phrase='「承認したら PR まで確認を挟まずに進める」'
follow='ユーザーがこの会話で別の進め方を言っていれば、そちらに従う。'

case ${skill} in
  superpowers:brainstorming)
    msg="[走り切り] ${skill} を読んだ。このユーザーは方針の承認 1 回のあと PR まで走り切る (~/.claude/CLAUDE.md「${section}」)。方針の承認は spec を書く前に 1 回聞き、${phrase}と、その先の段階 (spec → 実装計画 → 実装 → PR など) とともに書き添える。承認のあとは spec の承認を待たずに writing-plans へ進み、builder check の問いは自分で決めて spec に「こちらの判断」として残す。${follow}"
    ;;
  superpowers:writing-plans)
    msg="[走り切り] ${skill} を読んだ。この会話で${phrase}と書き添えた方針の承認を得ていれば、実装計画を書いたあと、計画のレビューも実行方式 (Subagent-driven / Native) の選択も聞かず、推奨の方式を理由 1 文とともに告げてそのまま実行に入る。まだ得ていなければ、計画と推奨の方式を見せるときに 1 回だけ、同じく書き添えて承認を聞く (~/.claude/CLAUDE.md「${section}」)。${follow}"
    ;;
  superpowers:using-git-worktrees)
    msg="[走り切り] ${skill} を読んだ。worktree を作るかは聞かない。worktree の外なら、その場で既定の branch から feature branch を切って進める (main では作業しない。~/.claude/CLAUDE.md「${section}」)。${follow}"
    ;;
  superpowers:finishing-a-development-branch)
    msg="[走り切り] ${skill} を読んだ。この会話で${phrase}と書き添えた方針の承認を得ていれば、merge / PR / そのまま の 3 択を聞かず、テストが通っていれば push して PR を作る (merge はしない)。push の前に、PR に載る commit が今回の作業だけかを git log で確かめ、他の commit が混ざっていれば止まって聞く。自分で決めたこと (builder check の判断・ruling) は PR を返すときに並べる。まだ承認を得ていなければ、3 択の代わりに PR を出してよいかを 1 回だけ聞く (~/.claude/CLAUDE.md「${section}」)。${follow}"
    ;;
  *)
    exit 0
    ;;
esac

jq -cn --arg msg "${msg}" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}' || true
exit 0
