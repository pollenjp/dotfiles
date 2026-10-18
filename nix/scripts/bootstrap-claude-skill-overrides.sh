#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の skillOverrides を host option の値どおりに ~/.claude/settings.json へ登録する。
# 冪等。`setup.sh --update` でも毎回走る。
#
# ## 何のために
#
# skill の見え方 (Claude が自動で起動するか / `/` の一覧に出るか) は settings.json の
# skillOverrides でしか変えられない。使う skill はマシンごとに違う (例: 会社のマシンでは
# Notion Dev Tracker の pjp-dev-tracker を発火させない) ので、その宣言は host option
# (dotfiles.claude.devTracker.enable) に置き、ここで settings.json へ写す。
#
# ## 何を読むか
#
# home-manager が置く ~/.local/state/dotfiles/claude-skill-overrides.json
# (nix/home/modules/claude.nix)。中身は skillOverrides に merge する map そのもの:
#
#   {"pjp-dev-tracker":"off"}
#
# 無ければ、この option を含む世代へまだ switch していないということなので、
# 警告して exit 0 する (setup.sh は手順が 1 つ失敗すると残りを走らせないため)。
#
# ## 何をするか
#
# ~/.claude/settings.json の .skillOverrides に、生成ファイルの key を上書きで merge する。
#
#   - 生成ファイルに載っている key だけ触る。手で足した他の skill の key はそのまま
#   - 逆に載っている key は、user の settings.json では option が正で、手で変えても次の実行で戻る。
#     /skills の切り替えは project の .claude/settings.local.json に保存され (user の値より優先される)、
#     ここでは触らない
#   - 他のキーは保持する。同じ内容なら何もしない
#
# 実行中の Claude Code には効かない。新しい session から反映される。
#
# ## なぜ Nix でやらないのか
#
# settings.json は Claude Code 自身が書き換える (権限の「常に許可」など) ため、
# store 上の read-only ファイルにできない。bootstrap-claude-env.sh とまったく同じ切り分け。
# home.activation で書く手も採らない。store 管理でないファイルを switch が作ると
# 「Nix 管理か否か」の線が曖昧になる (bootstrap-local-env.sh と同じ理由)。

set -eu -o pipefail

settings="${HOME}/.claude/settings.json"
generated="${HOME}/.local/state/dotfiles/claude-skill-overrides.json"

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

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if [[ ! -r ${generated} ]]; then
  warn "生成ファイルがありません: ${generated}" \
    "dotfiles.claude.devTracker.enable を持つ世代へ先に home-manager switch してください。" \
    "この手順は飛ばします。"
  exit 0
fi

if ! jq -e 'type == "object"' "${generated}" >/dev/null 2>&1; then
  echo "${generated} が skillOverrides の map (JSON object) ではありません。" >&2
  exit 1
fi

mkdir -p "$(dirname "${settings}")"
[[ -f ${settings} ]] || echo '{}' >"${settings}"

if ! jq -e . "${settings}" >/dev/null 2>&1; then
  echo "${settings} が JSON として壊れています。手で直してください。" >&2
  exit 1
fi

# merge 先が object でないと jq の加算が生エラーで落ちる。生成ファイル側と同じく型を見る。
if ! jq -e '(.skillOverrides // {}) | type == "object"' "${settings}" >/dev/null 2>&1; then
  echo "${settings} の skillOverrides が map (JSON object) ではありません。手で直してください。" >&2
  exit 1
fi

tmp=$(mktemp "${settings}.XXXXXX")
# jq が落ちたときに settings.json の隣へ中間ファイルを残さない。
trap 'rm -f "${tmp}"' EXIT

# 生成ファイルの key だけ上書きし、他は残す (右辺が勝つ object の加算)。
jq --slurpfile gen "${generated}" '
  .skillOverrides = ((.skillOverrides // {}) + $gen[0])
' "${settings}" >"${tmp}"

if [[ $(jq -S . "${settings}") == "$(jq -S . "${tmp}")" ]]; then
  echo "登録済みです: ${settings} の .skillOverrides"
  exit 0
fi

mv "${tmp}" "${settings}"

echo "登録しました: skillOverrides ($(jq -c . "${generated}"))"
echo
echo "--- ${settings} の skillOverrides ---"
jq '.skillOverrides' "${settings}"
echo
echo "新しい Claude Code の session から効きます (実行中の session は再起動)。"
echo "確認: /skills で pjp-dev-tracker の状態を見る"
