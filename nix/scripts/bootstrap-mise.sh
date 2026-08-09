#!/usr/bin/env bash
# shellcheck shell=bash
#
# mise のグローバル設定 (~/.config/mise/config.toml) を初期化する。
# **マシンごとに一度だけ** 実行する。
#
# ## なぜ Nix で管理しないのか
#
# このファイルは mise 自身が実行時に書き換える (mise use --pin など)。
# store 上のファイルは read-only なので Nix 管理下には置けない。
#
# 投入も mise のコマンドで行う。config.toml は mise のスキーマであり、
# Nix 側にスナップショットを持たせると mise が形式を変えたときに
# 追随が必要になるため。`mise settings set` なら該当キーだけを触るので
# 既存の [tools] エントリも壊さない。
#
# ## なぜ home.activation でやらないのか
#
# `mise use -g` はネットワークアクセスとインストールを伴う。
# home-manager switch は hermetic に保ちたいので分けている。
#
# ## 役割分担
#
#   グローバルな CLI ツール    -> Nix (nix/home/modules/packages.nix)
#   言語ランタイム (go/node)   -> mise (このスクリプト)
#   プロジェクト毎のツール固定 -> mise (各リポジトリの mise.toml)

set -eu -o pipefail

if ! command -v mise &>/dev/null; then
  echo "mise が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

echo "==> settings"
# 複製元: .config_tmpl/mise/config.toml の [settings]
mise settings set install_before 9d
mise settings set lockfile true
mise settings set fetch_remote_versions_timeout 14d

echo "==> 言語ランタイム"
# CLI ツール (bat/eza/fd/ripgrep/fzf/jq/...) は Nix が管理するので入れない。
# ここに書くのはプロジェクト毎の切り替えが必要なものだけ。
mise use -g usage@latest # mise 自身の補完に必要
mise use -g go@latest
mise use -g node@24

echo
echo "完了しました。現在のグローバル設定:"
mise config ls --json 2>/dev/null | head -20 || true
echo
echo "--- ~/.config/mise/config.toml ---"
cat "${XDG_CONFIG_HOME:-${HOME}/.config}/mise/config.toml"
