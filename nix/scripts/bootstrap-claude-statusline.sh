#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の statusLine を ~/.claude/settings.json へ登録する。
# **マシンごとに一度だけ** 実行する。
#
# ## なぜ Nix でやらないのか
#
# statusLine の定義は settings.json にしか書けない。そして settings.json は
# Claude Code 自身が書き換える (権限の「常に許可」を選んだときなど) ため、
# store 上の read-only ファイルにできない。スクリプト本体だけを Nix が配置し、
# 登録はここで行う。bootstrap-claude-hook.sh とまったく同じ切り分け。
#
# ## 何をするか
#
# ~/.claude/settings.json の statusLine を、Nix が配置したスクリプトへ向ける。
# 他のキーは保持する。冪等 (既に同じなら何もしない)。
# 別の statusLine が設定されていたら、元の値を表示してから置き換える。

set -eu -o pipefail

settings="${HOME}/.claude/settings.json"
statusline="${HOME}/.claude/statusline-command.sh"

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if [[ ! -x ${statusline} ]]; then
  echo "statusLine のスクリプトが配置されていません: ${statusline}" >&2
  echo "先に home-manager switch を実行してください。" >&2
  exit 1
fi

mkdir -p "$(dirname "${settings}")"
[[ -f ${settings} ]] || echo '{}' >"${settings}"

if ! jq -e . "${settings}" >/dev/null 2>&1; then
  echo "${settings} が JSON として壊れています。手で直してください。" >&2
  exit 1
fi

current=$(jq -r '.statusLine.command // empty' "${settings}")

if [[ ${current} == "${statusline}" ]]; then
  echo "登録済みです: ${statusline}"
  exit 0
fi

if [[ -n ${current} ]]; then
  echo "既存の statusLine を置き換えます: ${current}"
fi

tmp=$(mktemp "${settings}.XXXXXX")
jq --arg cmd "${statusline}" '
  .statusLine = { type: "command", command: $cmd }
' "${settings}" >"${tmp}"
mv "${tmp}" "${settings}"

echo "登録しました: ${statusline}"
echo
echo "--- ${settings} の statusLine ---"
jq '.statusLine' "${settings}"
echo
echo "Claude Code を再起動すると有効になります。"
