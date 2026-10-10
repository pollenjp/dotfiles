#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の PostToolUse フック。設計を書き出した・PR を作った瞬間に、
# 「解説動画を作るか聞く場面か判断せよ」と Claude の文脈へ 1 文を差し込む。
#
# 聞くかどうかはここでは決めない。決めるのは skill (pjp-video-explainer-offer。
# private な claude-skills にある) の側で、ここは瞬間を見つけて知らせるだけ。
#
# ## 知らせる場面
#
#   PR の作成     Bash で gh pr create が成功した (stdout に PR の URL がある)
#   設計のページ  Write でタグ「設計」を含む cc-page の index.html を新しく作った
#   設計の文書    Write で docs/superpowers/specs/*.md か、ADR そのもの (docs/adr/<名前>.md か
#                 docs/adr/<名前>/README.md) を新しく作った
#
# ## 黙る場面
#
#   - subagent の中 (入力に agent_id がある)。subagent はユーザーに質問できない
#   - skill が入っていないマシン (claude-skills を取れない、public な dotfiles だけの環境)
#   - ユーザーが「このセッションでは聞かない」を選んだセッション。skill がそのとき
#     ${XDG_STATE_HOME:-~/.local/state}/pjp-video-offer/off-<session_id> を置く。
#     会話の圧縮で選んだことが消えても、ここで黙らせる
#   - 新しく作ったのではない書き込み (type が create でない)。版を直すたびに知らせない
#   - ADR の dir の中の textbook や図、ADR の一覧 (docs/adr/README.md)。1 本の ADR で何度も知らせない
#   - 想定外の入力。tool の流れを止めないよう、何があっても exit 0 で終える
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks.PostToolUse に 2 件足す
# (matcher Bash + if "Bash(gh pr create *)" と、matcher Write)。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0

skill_md="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/pjp-video-explainer-offer/SKILL.md"
[[ -f ${skill_md} ]] || exit 0
command -v jq &>/dev/null || exit 0

# 入力の 1 項目を取り出す。無い・壊れている → 空文字
field() {
  jq -r "$1 // empty" <<<"${input}" 2>/dev/null || true
}

[[ -z $(field '.agent_id') ]] || exit 0

# 「このセッションでは聞かない」の印。session_id は Claude Code の UUID だが、パスに使うので形を確かめる
session_id=$(field '.session_id')
if [[ ${session_id} =~ ^[A-Za-z0-9_-]+$ && -e "${XDG_STATE_HOME:-${HOME}/.local/state}/pjp-video-offer/off-${session_id}" ]]; then
  exit 0
fi

kind=""
target=""
case $(field '.tool_name') in
  Bash)
    if [[ $(field '.tool_input.command') == *"gh pr create"* ]]; then
      target=$(
        field '.tool_response.stdout' \
          | grep -oE 'https://[^[:space:]/]+/[^[:space:]/]+/[^[:space:]/]+/pull/[0-9]+' \
          | tail -n 1
      )
      [[ -z ${target} ]] || kind="pr"
    fi
    ;;
  Write)
    [[ $(field '.tool_response.type') == create ]] || exit 0
    path=$(field '.tool_input.file_path')
    case ${path} in
      */cc-pages/sessions/*/*/index.html)
        dir=$(dirname -- "${path}")
        if jq -e '(.tags | type) == "array" and (.tags | any(type == "string" and contains("設計")))' \
          "${dir}/page.json" &>/dev/null; then
          kind="design-page"
          target=${dir}
        fi
        ;;
      */docs/superpowers/specs/*.md)
        kind="design-doc"
        target=${path}
        ;;
      */docs/adr/*)
        # ADR そのものだけ。case の * は / もまたぐので、docs/adr/ から後ろの形で絞る
        rest=${path#*/docs/adr/}
        if [[ ${rest} =~ ^[^/]+/README\.md$ || (${rest} =~ ^[^/]+\.md$ && ${rest} != README.md) ]]; then
          kind="design-doc"
          target=${path}
        fi
        ;;
    esac
    ;;
esac

case ${kind} in
  pr)
    msg="[解説動画] PR を作った (${target})。pjp-video-explainer-offer skill を読み、聞く条件に合えば、PR の URL を返すときに解説動画を作るかを聞くこと。合わなければ何もしない。"
    ;;
  design-page)
    msg="[解説動画] タグ「設計」の cc-page を作った (${target})。pjp-video-explainer-offer skill を読み、聞く条件に合えば、承認を聞く前に解説動画を作るかを聞くこと。合わなければ何もしない。"
    ;;
  design-doc)
    msg="[解説動画] 設計の文書を作った (${target})。pjp-video-explainer-offer skill を読み、聞く条件に合えば、レビューや承認を頼む前に解説動画を作るかを聞くこと。合わなければ何もしない。"
    ;;
  *)
    exit 0
    ;;
esac

jq -cn --arg msg "${msg}" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}' || true
exit 0
