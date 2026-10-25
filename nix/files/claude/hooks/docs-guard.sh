#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の PreToolUse フック。
#
# public な repo の work tree の直下の docs/ に、Write・Edit・MultiEdit・NotebookEdit で書こうとしたら止め、
# その repo の設計の文書を置く private な repo (下の表) の docs/ に書くよう Claude に返す。止めるのは表に書いた
# repo だけ (今は pollenjp/dotfiles → pollenjp/dotfiles-private)。
#
# ## なぜ必要か
#
# dotfiles は public で、spec・実装計画・ADR には設計のやり取り (依頼の原文・問いと答え・検討した案) が入る。
# push した時点で公開されるので、書く前に止める。決まりの正本は dotfiles の直下の CLAUDE.md、経緯は
# dotfiles-private の ADR 035。
#
# ## 判定
#
#   1. path に /docs/ を含まなければ、git を呼ばずに抜ける
#   2. 書き先の、在る一番近い祖先のディレクトリで `git rev-parse --show-prefix` を引き、まだ無い分を足して
#      work tree の中の相対パスにする。docs/ で始まるときだけ先へ進む (祖先の symlink・worktree でもずれない。
#      下の階層の docs/ は止めない)
#   3. その work tree の origin の URL の最後の 2 つ (owner/repo。小文字) を表で引き、当たれば止める
#
# 公開範囲は gh で引かない。表に書いた repo だけを止めるので要らず、gh の無い cloud でも同じに動く。OSS の
# public な repo の docs/ を直す作業は止めない。ほかの repo にも効かせるなら、表に足す。
#
# ## 限界
#
# Bash で書くもの (`cat > docs/…`・`git mv`) は見ない。そこは CLAUDE.md と CI (lint の「docs/ を置かない」) が
# 受け持つ。通す口は持たない (public に置く文書が要るようになったら、表と CI を直す)。
#
# ## 登録方法
#
# スクリプトだけを Nix が配置し、登録は nix/scripts/bootstrap-claude-hook.sh が行う (冪等)。手で書くならこの形:
#
#   {
#     "hooks": {
#       "PreToolUse": [
#         {
#           "matcher": "Write|Edit|MultiEdit|NotebookEdit",
#           "hooks": [
#             { "type": "command", "command": "~/.claude/hooks/docs-guard.sh" }
#           ]
#         }
#       ]
#     }
#   }
#
# ## 入出力
#
# stdin  : {"tool_name": "...", "tool_input": {"file_path"|"notebook_path": ...}, "cwd": ...}
# stdout : 止めるときだけ hookSpecificOutput (permissionDecision: deny) を 1 行。通すときは何も出さない
# exit   : 常に 0 (止めるのは JSON の permissionDecision で表す)
#
# 依存: jq・git (無ければ黙って通す)

set -u -o pipefail

# 手元の GIT_DIR などに引かれず、書き先のディレクトリの repo を見る
unset GIT_DIR GIT_WORK_TREE

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

# public な repo (origin の owner/repo。小文字) → その repo の設計の文書を置く private な repo
docs_home() {
  case $1 in
    pollenjp/dotfiles) printf '%s' pollenjp/dotfiles-private ;;
    *) return 1 ;;
  esac
}

# origin_slug <URL> : URL の最後の 2 つを owner/repo (小文字) にして出す。https・ssh・scp の形・proxy の URL のどれでも
origin_slug() {
  local u=${1%/}
  u=${u%.git}
  local name=${u##*/}
  local rest=${u%/*}
  local owner=${rest##*[/:]}
  printf '%s/%s' "${owner,,}" "${name,,}"
}

input=$(cat)
fields=$(jq -r '[.tool_name // "", (.tool_input.file_path // .tool_input.notebook_path // ""), .cwd // ""]
  | map(tostring) | join("\u001f")' <<<"${input}" 2>/dev/null) || exit 0
IFS=$'\x1f' read -r tool path cwd <<<"${fields}"

case ${tool} in
  Write | Edit | MultiEdit | NotebookEdit) ;;
  *) exit 0 ;;
esac
[[ -n ${path} ]] || exit 0
if [[ ${path} != /* ]]; then
  [[ ${cwd} == /* ]] || exit 0
  path="${cwd%/}/${path}"
fi
[[ ${path} == */docs/* ]] || exit 0

# 在る一番近い祖先のディレクトリと、そこから先のまだ無い分
dir=${path%/*}
rest=${path##*/}
while [[ ! -d ${dir} ]]; do
  [[ -n ${dir} ]] || exit 0
  rest="${dir##*/}/${rest}"
  dir=${dir%/*}
done

prefix=$(git -C "${dir}" rev-parse --show-prefix 2>/dev/null) || exit 0
rel="${prefix}${rest}"
[[ ${rel} == docs/* ]] || exit 0

url=$(git -C "${dir}" remote get-url origin 2>/dev/null) || exit 0
slug=$(origin_slug "${url}")
home=$(docs_home "${slug}") || exit 0

reason=$(
  cat <<EOF
'${path}' は public な ${slug} の docs/ の中です。${slug} の設計の文書 (spec・実装計画・ADR・textbook・図) は
この repo に置かず、private な ${home} の docs/ に書きます (${slug} の直下の CLAUDE.md)。

書き先: ${home} の ${rel}
  手元: \$(ghq root)/github.com/${home} の clone から worktree を切り、その branch で書いて PR を出す
        (clone が無ければ ghq get ${home})
  cloud: session に ${home} を足し (add_repo)、その clone に書いて PR を出す
取れなければ書かずに、そのことをユーザーに伝える (この repo には置かない)。

Bash (cat > … など) に書き換えて回り込まない (CI の lint も、この repo に docs/ があれば落ちる)。
public な repo に置く文書が要るなら、ユーザーに聞く。
EOF
)

jq -cn --arg reason "${reason}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
