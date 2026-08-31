#!/usr/bin/env bash
# shellcheck shell=bash
#
# mise のグローバル設定 (~/.config/mise/config.toml) を初期化する。
# **マシンごとに一度だけ** 実行する。
#
# order: 10
#
# ^ setup.sh が読む実行順。既定は 50 で、小さいほど先に走る。
#   bootstrap-claude-plugins.sh が claude を要求し、その claude を入れるのは
#   ここなので、辞書順 (bootstrap-mise は最後尾) より前に出す必要がある。
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
#
# NOTE: テンプレートの install_before は現在の mise では minimum_release_age に
#       改名されている。install_before は `mise settings ls --all` に存在せず、
#       set しても黙って書き込まれるだけで **無視される** (エラーにならないので
#       気付きにくい)。
mise settings set minimum_release_age 9d
mise settings set lockfile true
mise settings set fetch_remote_versions_timeout 14d

echo "==> 言語ランタイム"
# CLI ツール (bat/eza/fd/ripgrep/fzf/jq/...) は Nix が管理するので入れない。
# ここに書くのはプロジェクト毎の切り替えが必要なものだけ (例外は下の claude)。
mise use -g usage@latest # mise 自身の補完に必要
mise use -g go@latest
mise use -g node@24

echo "==> claude (役割分担の例外)"
# claude は「グローバルな CLI」なので、上の役割分担どおりなら Nix
# (packages.nix) 側が筋。nixpkgs にも claude-code は在り、wrapper が
# DISABLE_AUTOUPDATER を立てるので Nix 管理でも動作自体は問題ない。
#
# それでも mise に置くのは **リリース頻度が flake.lock の更新周期に
# 合わない**ため。nixpkgs pin にすると、版は flake.lock を上げるまで動かない。
# mise の `latest` + 上の minimum_release_age = 9d なら「先端は取らないが
# nixpkgs pin よりは速い」中間の刻みになり、repo の「先端は取らない」方針
# (flake-lock-age.sh) とも矛盾しない。
#
# ここで入れておかないと bootstrap-claude-plugins.sh が動けない。
# そのためヘッダの `order: 10` で bootstrap-* の先頭に出してある。
mise use -g claude@latest

echo
echo "完了しました。現在のグローバル設定:"
mise config ls --json 2>/dev/null | head -20 || true
echo
echo "--- ~/.config/mise/config.toml ---"
cat "${XDG_CONFIG_HOME:-${HOME}/.config}/mise/config.toml"
