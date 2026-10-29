#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の公式プラグインを導入する。
# 冪等。`setup.sh --update` でも毎回走る。
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
#   2. 下の plugins を install する (enabledPlugins も CLI が立てる)。入れられない plugin があっても
#      警告して残りを入れ、exit 0 する (setup.sh は手順が 1 つ失敗すると残りを走らせないため)
#
# 冪等。既に在れば「already installed」と出て exit 0 する。
# 版は上げない (plugin update は呼ばない)。「先端は取らない」方針に合わせ、
# 導入済みのものはそのままにする。

set -eu -o pipefail

# 入れる先は ~/.claude。claude-personal / claude-work のセッションの中から setup を流すと
# CLAUDE_CONFIG_DIR が引き継がれ、そちらの dir へ入ってしまうので外す。
# (~/.claude を指定するのも不可。.claude.json の置き場所まで変わる)
unset CLAUDE_CONFIG_DIR

marketplace_repo="anthropics/claude-plugins-official"
marketplace="claude-plugins-official"

plugins=(
  superpowers
  frontend-design
  playwright
  # 前提の python3 (3.9 以上) は home/modules/python.nix が入れる。Pro のアカウントは dynamic workflows を
  # /config で on にする (nix/README.md「2.1 Claude Code の公式プラグイン」)
  claude-security
)

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
# setup.sh が手順ごとに DOTFILES_SETUP_WARNINGS でファイルを渡す。単体で流したときは何もしない。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
}

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
  warn "claude が見つかりません。プラグインの導入は飛ばします。" \
    "先に ./nix/scripts/bootstrap-mise.sh を実行してから" \
    "  ~/dotfiles/setup --steps bootstrap-claude-plugins" \
    "で入れ直してください。"
  exit 0
fi

echo "==> marketplace: ${marketplace_repo}"

# clone は SSH (git@github.com:) で行われる。public な repo だが Claude Code
# 側の既定がそうなっているので、GitHub の鍵が無いマシンでは失敗する。
# これも「環境がまだ整っていない」側の失敗なので exit 0 で流す。
if ! "${claude}" plugin marketplace add "${marketplace_repo}"; then
  echo >&2
  warn "marketplace の登録に失敗しました。プラグインの導入は飛ばします。" \
    "clone は SSH (git@github.com:) で行われるので、GitHub の鍵が要ります。"
  exit 0
fi

echo
echo "==> plugins"
for p in "${plugins[@]}"; do
  # 手元の marketplace の一覧が古いと、足したばかりの plugin は「not found in marketplace」で入らない。
  # 入れ直し方を添えて、残りの plugin と後続の手順へ進む
  if ! "${claude}" plugin install "${p}@${marketplace}" -y; then
    warn "plugin を入れられませんでした: ${p}@${marketplace}" \
      "「not found in marketplace」なら手元の一覧が古いので、" \
      "  claude plugin marketplace update ${marketplace}" \
      "で新しくしてから ~/dotfiles/setup --steps bootstrap-claude-plugins で入れ直してください。"
  fi
done

echo
echo "--- claude plugin list ---"
"${claude}" plugin list
echo
echo "Claude Code を再起動すると有効になります。"
