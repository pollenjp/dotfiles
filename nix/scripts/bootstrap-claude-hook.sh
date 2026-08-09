#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の PreToolUse フックを ~/.claude/settings.json へ登録する。
# **マシンごとに一度だけ** 実行する。
#
# ## なぜ Nix でやらないのか
#
# フックの定義は settings.json にしか書けない (プラグインを除く)。
# そして settings.json は Claude Code 自身が書き換える
# (権限の「常に許可」を選んだときなど) ため、store 上の read-only ファイルに
# できない。スクリプト本体だけを Nix が配置し、登録はここで行う。
#
# ## 何をするか
#
# ~/.claude/settings.json の hooks.PreToolUse に、Nix 管理パスのガードを追加する。
# 既存の設定は保持する。冪等 (既に登録済みなら何もしない)。

set -eu -o pipefail

settings="${HOME}/.claude/settings.json"
hook_path="${HOME}/.claude/hooks/nix-managed-guard.sh"
matcher="Edit|Write|NotebookEdit|Bash"

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if [[ ! -x ${hook_path} ]]; then
  echo "フックが配置されていません: ${hook_path}" >&2
  echo "先に home-manager switch を実行してください。" >&2
  exit 1
fi

mkdir -p "$(dirname "${settings}")"
[[ -f ${settings} ]] || echo '{}' >"${settings}"

if ! jq -e . "${settings}" >/dev/null 2>&1; then
  echo "${settings} が JSON として壊れています。手で直してください。" >&2
  exit 1
fi

# 既に登録済みなら何もしない
if jq -e --arg cmd "${hook_path}" \
  '[.hooks.PreToolUse // [] | .[].hooks // [] | .[].command] | index($cmd)' \
  "${settings}" >/dev/null 2>&1; then
  echo "登録済みです: ${hook_path}"
  exit 0
fi

tmp=$(mktemp "${settings}.XXXXXX")
jq --arg cmd "${hook_path}" --arg matcher "${matcher}" '
  .hooks //= {}
  | .hooks.PreToolUse //= []
  | .hooks.PreToolUse += [{
      matcher: $matcher,
      hooks: [{ type: "command", command: $cmd }]
    }]
' "${settings}" >"${tmp}"
mv "${tmp}" "${settings}"

echo "登録しました: ${hook_path}"
echo
echo "--- ${settings} の hooks ---"
jq '.hooks' "${settings}"
echo
echo "Claude Code を再起動すると有効になります。"
