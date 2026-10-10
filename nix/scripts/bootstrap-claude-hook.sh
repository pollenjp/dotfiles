#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code のフックを ~/.claude/settings.json へ登録する。
# 冪等。`setup.sh --update` でも毎回走る。
#
# ## なぜ Nix でやらないのか
#
# フックの定義は settings.json にしか書けない (プラグインを除く)。
# そして settings.json は Claude Code 自身が書き換える
# (権限の「常に許可」を選んだときなど) ため、store 上の read-only ファイルに
# できない。スクリプト本体だけを Nix が配置し、登録はここで行う。
#
# ## 何を登録するか
#
#   PreToolUse   Edit|Write|NotebookEdit|Bash   nix-managed-guard.sh
#                Nix 管理パスを編集しようとしたら止めて、正しい手順を返す
#   PostToolUse  Bash (if "Bash(gh pr create *)")  video-offer-nudge.sh
#   PostToolUse  Write                           video-offer-nudge.sh
#                設計の書き出しと PR の作成を Claude に知らせる (解説動画を作るか聞く)
#
# 既存の設定は保持する。同じ event・matcher・if・command の組が既にあれば足さない。

set -eu -o pipefail

settings="${HOME}/.claude/settings.json"
hooks_dir="${HOME}/.claude/hooks"
guard="${hooks_dir}/nix-managed-guard.sh"
nudge="${hooks_dir}/video-offer-nudge.sh"

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

for hook in "${guard}" "${nudge}"; do
  if [[ ! -x ${hook} ]]; then
    echo "フックが配置されていません: ${hook}" >&2
    echo "先に home-manager switch を実行してください。" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "${settings}")"
[[ -f ${settings} ]] || echo '{}' >"${settings}"

if ! jq -e . "${settings}" >/dev/null 2>&1; then
  echo "${settings} が JSON として壊れています。手で直してください。" >&2
  exit 1
fi

changed=0

# register <event> <matcher> <if (空なら付けない)> <command>
register() {
  local event=$1 matcher=$2 cond=$3 cmd=$4 tmp
  if jq -e --arg ev "${event}" --arg m "${matcher}" --arg cond "${cond}" --arg c "${cmd}" '
      [.hooks[$ev] // [] | .[] | select(.matcher == $m) | .hooks // [] | .[]
        | select(.command == $c and ((.["if"] // "") == $cond))]
      | length > 0
    ' "${settings}" >/dev/null; then
    echo "登録済みです: ${event} ${matcher}${cond:+ (${cond})} -> ${cmd}"
    return 0
  fi
  tmp=$(mktemp "${settings}.XXXXXX")
  jq --arg ev "${event}" --arg m "${matcher}" --arg cond "${cond}" --arg c "${cmd}" '
    .hooks //= {}
    | .hooks[$ev] //= []
    | .hooks[$ev] += [{
        matcher: $m,
        hooks: [{type: "command", command: $c} + (if $cond == "" then {} else {"if": $cond} end)]
      }]
  ' "${settings}" >"${tmp}"
  mv "${tmp}" "${settings}"
  echo "登録しました: ${event} ${matcher}${cond:+ (${cond})} -> ${cmd}"
  changed=1
}

register PreToolUse "Edit|Write|NotebookEdit|Bash" "" "${guard}"
register PostToolUse "Bash" "Bash(gh pr create *)" "${nudge}"
register PostToolUse "Write" "" "${nudge}"

if [[ ${changed} == 1 ]]; then
  echo
  echo "--- ${settings} の hooks ---"
  jq '.hooks' "${settings}"
  echo
  echo "Claude Code を再起動すると有効になります。"
fi
