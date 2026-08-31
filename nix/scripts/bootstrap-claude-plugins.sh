#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の公式プラグインを導入する。
# **マシンごとに一度だけ** 実行する (冪等なので更新時に再実行してもよい)。
#
# order: 20
#
# ^ setup.sh が読む実行順。claude を入れる bootstrap-mise.sh (order: 10) の
#   後、かつ他の bootstrap-* (既定の 50) より前に走らせる。
#   仕組みは nix/README.md 「bootstrap の実行順」。
#
# ## なぜ Nix でやらないのか
#
# プラグインの実体は ~/.claude/plugins/ 以下へ clone され、有効/無効は
# settings.json の enabledPlugins に載る。どちらも Claude Code 自身が
# 書き換えるので store 管理下に置けない。bootstrap-claude-hook.sh と同じ切り分け。
#
# ## なぜ jq で settings.json を書かないのか
#
# 他の bootstrap-claude-*.sh は jq でキーを刺しているが、プラグインだけは
# それでは足りない。enabledPlugins は「既に入っているものを有効にする」
# フラグでしかなく、書いても**実体は取得されない**。使い捨ての
# CLAUDE_CONFIG_DIR に enabledPlugins だけを書いて実セッションを起動し、
# installed_plugins.json が {} のままであることを確認済み。
#
# marketplace の登録も別途要る。公式 marketplace すら事前登録されていない。
# どちらも CLI が settings.json へ書く (extraKnownMarketplaces / enabledPlugins)
# ので、ここで jq を触る必要はない。
#
# ## 何をするか
#
#   1. 公式 marketplace (anthropics/claude-plugins-official) を登録する
#   2. 下の plugins を install する (enabledPlugins も CLI が立てる)
#
# 冪等。既に在れば「already installed」と出て exit 0 する。
# 版は上げない (plugin update は呼ばない)。「先端は取らない」方針に合わせ、
# 導入済みのものはそのままにする。

set -eu -o pipefail

marketplace_repo="anthropics/claude-plugins-official"
marketplace="claude-plugins-official"

plugins=(
  superpowers
  frontend-design
  playwright
)

# claude の探し方。
#
# claude は mise 管理 (bootstrap-mise.sh が入れる)。そして mise は
# `mise activate` 方式で、install 先を **シェル起動時に** PATH へ前置する
# (shim ディレクトリは PATH に無い)。同じ setup.sh の実行内で mise が
# claude を入れた直後は PATH が古いままなので command -v では見つからない。
# その場合は mise which で実体を引く。
claude=""
if command -v claude &>/dev/null; then
  claude=$(command -v claude)
elif command -v mise &>/dev/null; then
  claude=$(mise which claude 2>/dev/null || true)
fi

# 見つからないときに exit 1 しないのは、setup.sh が手順を 1 つ失敗させると
# 残りを走らせないため。ここで落とすと後続の bootstrap が巻き添えになる。
# bootstrap-claude-skills.sh が鍵の無いマシンで exit 0 しているのと同じ扱い。
if [[ -z ${claude} || ! -x ${claude} ]]; then
  echo "claude が見つかりません。プラグインの導入は飛ばします。" >&2
  echo "先に ./nix/scripts/bootstrap-mise.sh を実行してから" >&2
  echo "  ~/dotfiles/setup --steps bootstrap-claude-plugins" >&2
  echo "で入れ直してください。" >&2
  exit 0
fi

echo "==> marketplace: ${marketplace_repo}"

# clone は SSH (git@github.com:) で行われる。public な repo だが Claude Code
# 側の既定がそうなっているので、GitHub の鍵が無いマシンでは失敗する。
# これも「環境がまだ整っていない」側の失敗なので exit 0 で流す。
if ! "${claude}" plugin marketplace add "${marketplace_repo}"; then
  echo >&2
  echo "marketplace の登録に失敗しました。プラグインの導入は飛ばします。" >&2
  echo "clone は SSH (git@github.com:) で行われるので、GitHub の鍵が要ります。" >&2
  exit 0
fi

echo
echo "==> plugins"
for p in "${plugins[@]}"; do
  "${claude}" plugin install "${p}@${marketplace}" -y
done

echo
echo "--- claude plugin list ---"
"${claude}" plugin list
echo
echo "Claude Code を再起動すると有効になります。"
