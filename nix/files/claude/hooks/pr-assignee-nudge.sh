#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の PostToolUse・PostToolUseFailure フック。gh pr create が assignee を指定せずに PR を作ったとき、
# 「gh の認証ユーザーを Assignees に付けて確かめよ」と Claude の文脈へ 1 文を差し込む (ADR 039)。
#
# PR を作るたびに gh の認証ユーザー (@me) を Assignees に付ける決まりと、付け方・確かめ方の正本は skill
# (pjp-gh-pr-create) の側。ここは skill が読まれずに PR が出来た瞬間を見つけて知らせるだけで、PR はもう
# 出来ているので止めない。
#
# ## 知らせる場面
#
#   指定なし     gh pr create が PR を作った (出力に PR の URL がある) のに、その gh pr create に assignee の指定
#                (--assignee・--assignee=…・-a・-a=…・-a… と、-d・-e・-f・-w と束ねた -da など) が無い
#   作ったあとで落ちた
#                出力に gh の「pull request update failed」がある。PR は出来ていて、assignee などを付ける段で
#                落ちた (gh は URL を出してから exit 1)。指定があっても、作り直さずに確かめるよう知らせる
#
# ## 黙る場面
#
#   - 指定して作り、作ったあとの段でも落ちていない
#   - 既存の PR を返しただけ (出力に「a pull request for branch … already exists」)
#   - 出力に PR の URL が無い (作れなかった・--web・--dry-run)・gh pr create でないコマンド
#   - skill を Claude が呼べないマシン: skill が無い・user の settings.json (${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json)
#     の skillOverrides で pjp-gh-pr-create を off か user-invocable-only にした。付けたくないマシンは skill を止めれば
#     この hook も黙る
#   - 想定外の入力。tool の流れを止めないよう、何があっても exit 0 で終える
#
# subagent の中でも知らせる (subagent も PR を出す。video-offer-nudge.sh と違って、受け取るのは PR を作った本人)。
#
# ## コマンドの読み方
#
# 近似で読む (xref-guard.sh・ssh-agent-notice.sh の lexer ほど細かく読まない)。heredoc の本文を外し、'…'・"…" を
# 中身ごと外し、\ の行の継ぎをつなぎ、; & | 改行で分けて、gh pr create の後ろの語に指定があるかを見る。本文や
# タイトルに --assignee・-a と書いても指定と数えない。引用符の中にだけ gh pr create があるとき (bash -c '…') は、
# 外した引用符の中を読み直す。読み違えたときは知らせる側に倒れることが多い (余分な知らせは gh pr view 1 回で済む)。
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks の PostToolUse と PostToolUseFailure に 1 件ずつ足す
# (どちらも matcher Bash + if "Bash(gh pr create *)")。0 以外で終わった Bash (gh pr create の後ろにつないだ
# コマンドが落ちた・作ったあとの段で落ちた) には PostToolUse が来ず、PostToolUseFailure が来る (出力は入力の
# error に入る。ssh-agent-notice.sh と同じ)。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0
command -v jq &>/dev/null || exit 0

config="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
[[ -f ${config}/skills/pjp-gh-pr-create/SKILL.md ]] || exit 0
# skill を Claude が呼べない値なら黙る。読めない・壊れている・知らない値なら知らせる
case $(jq -r '.skillOverrides["pjp-gh-pr-create"] // empty' "${config}/settings.json" 2>/dev/null) in
  off | user-invocable-only) exit 0 ;;
esac

# 入力の 1 項目を取り出す。無い・壊れている → 空文字
field() {
  jq -r "$1 // empty" <<<"${input}" 2>/dev/null || true
}

event=$(field '.hook_event_name')
case ${event} in
  PostToolUse | PostToolUseFailure) ;;
  *) exit 0 ;;
esac
[[ $(field '.tool_name') == Bash ]] || exit 0
cmd=$(field '.tool_input.command')
[[ ${cmd} == *gh*pr*create* ]] || exit 0

# 出力。PostToolUse は tool_response の stdout・stderr、PostToolUseFailure は error に入る
out=$(jq -r '[(.tool_response | objects | .stdout, .stderr), .error] | map(strings) | join("\n")' <<<"${input}" 2>/dev/null) || exit 0
# 既存の PR を返しただけなら、作ったのではない (gh の文: a pull request for branch "x" into branch "y" already exists:)
[[ ${out} != *"a pull request for branch"*"already exists"* ]] || exit 0
pr_url=$(
  grep -oE 'https://[^[:space:]/]+/[^[:space:]/]+/[^[:space:]/]+/pull/[0-9]+' <<<"${out}" \
    | tail -n 1
)
[[ -n ${pr_url} ]] || exit 0

# gh pr create の assignee の指定を見る (上の「コマンドの読み方」)。all = どの gh pr create にも指定がある、
# some = 指定の無いものがある、none = gh pr create が無い (heredoc の本文にだけ書いたものなど)
read -r -d '' parse <<'JQ' || true
# heredoc の本文 (<<EOF・<<'EOF'・<<"EOF"・<<-EOF の次の行から、終わりの印の行まで) を外す。1 行に heredoc が
# 2 つあれば前の 1 つだけ。<<< (here-string) は heredoc と読まない
def strip_heredocs:
  reduce (split("\n")[]) as $line ({out: [], end: null, tabs: false};
    if .end != null then
      if (if .tabs then ($line | sub("^\t+"; "")) else $line end) == .end then .end = null else . end
    else
      .out += [$line]
      | (first($line | match("(?:^|[^<])<<(-?)[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\\2")) // null) as $m
      | if $m == null then . else .end = $m.captures[2].string | .tabs = ($m.captures[0].string == "-") end
    end)
  | .out | join("\n");
# '…'・"…" を中身ごと 1 語 (Q) にする。左から先に始まる方を取るので、"it's" の ' では切れない
def strip_quotes: gsub("'[^']*'|\"(?:[^\"\\\\]|\\\\[\\s\\S])*\""; "Q");
# \ の行の継ぎをつなぎ、; & | 改行で単純コマンドの並びに分ける (2>&1 の & でも切れるので、その後ろの語は読まない)
def simple_commands: gsub("\\\\\n"; " ") | [splits("[;&|\n]")];
def create_args: capture("(?:^|[\\s/(`])gh\\s+pr\\s+create(?<a>(?:\\s.*)?)$").a;
def has_assignee: [splits("\\s+")] | any(.[]; test("^--assignee(=|$)") or test("^-[defw]*a"));
.tool_input.command
| strip_heredocs
| if test("gh\\s+pr\\s+create") | not then "none"
  else
    [strip_quotes | simple_commands[] | create_args | has_assignee] as $found
    | if $found == [] then
        # 引用符の中にだけある (bash -c '…')。最初の gh pr create の後ろを、引用符を空白にして次の区切りまで読む
        [capture("gh\\s+pr\\s+create(?<a>[^;&|\n]*)").a | gsub("['\"]"; " ") | has_assignee]
      else $found end
    | if all(.[]; .) then "all" else "some" end
  end
JQ
# コマンドは入力の JSON から読む (--arg で渡すと、128 KB を超える 1 つの引数で exec が落ちる)
state=$(jq -r "${parse}" <<<"${input}" 2>/dev/null) || exit 0

if [[ ${out} == *"pull request update failed"* ]]; then
  msg="[assignee] gh pr create は PR を作ったあとの段で落ちた (pull request update failed) が、PR は出来ている (${pr_url})。作り直さず、pjp-gh-pr-create skill を読み、gh pr view ${pr_url} で Assignees を確かめ、空なら gh pr edit ${pr_url} --add-assignee @me で付けること。"
elif [[ ${state} == some ]]; then
  msg="[assignee] assignee を指定せずに PR を作った (${pr_url}) ので、Assignees が空かもしれない。pjp-gh-pr-create skill を読み、gh pr edit ${pr_url} --add-assignee @me で gh の認証ユーザーを付け、gh pr view で確かめること。"
else
  exit 0
fi

jq -cn --arg ev "${event}" --arg msg "${msg}" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $msg}}' || true
exit 0
