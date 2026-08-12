#!/usr/bin/env bash
# shellcheck shell=bash
#
# 公式 MCP サーバ (@drawio/mcp) を起動する。図を draw.io エディタで開くための
# もので、SVG / PNG への書き出しには要らない。登録手順は references/mcp.md。
#
# ## なぜ薄いラッパを挟むか
#
# サーバ本体は flake.nix が持っているが、MCP の設定に書けるのはコマンド 1 つで、
# store のパスは home-manager switch ごとに変わる。~/.claude/skills/drawio は
# 変わらないので、ここで実体を解決してから nix へ渡す。
#
# symlink をそのまま path: に渡すと、解決先を外部パス扱いされて失敗する。
#
#   nix run "path:${HOME}/.claude/skills/drawio#drawio-mcp"
#   error: access to absolute path '/nix/store/...' is forbidden in
#          pure evaluation mode

set -eu -o pipefail

skill_dir=$(
  cd -- "$(dirname -- "$(readlink -f -- "$0")")/.." &>/dev/null
  pwd -P
)

# 既に PATH にあるならそれを使う (devShell の中、home.packages へ入れた場合)。
if command -v drawio-mcp &>/dev/null; then
  exec drawio-mcp "$@"
fi

if ! command -v nix &>/dev/null; then
  echo "drawio-mcp も nix も見つかりません。" >&2
  echo "nix を入れる: curl -fsSL https://install.determinate.systems/nix | sh -s -- install" >&2
  exit 1
fi

exec nix run "path:${skill_dir}#drawio-mcp" -- "$@"
