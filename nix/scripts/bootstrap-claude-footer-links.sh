#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の footer に会話のチケットと PR と cc-page のリンクを出す設定 (footerLinksRegexes) を
# ~/.claude/settings.json へ登録する。冪等。`setup.sh --update` でも毎回走る。
#
# ## 何のために
#
# 会話の中で触れた Dev Tracker のチケット (TKT-n / WRK-TKT-n) と GitHub の PR、cc-page のページを、
# プロンプト下の footer にクリックできるバッジとして並べる。Claude Code の
# footerLinksRegexes (2.1.176〜) が、turn の出力 (tool の結果と Claude の応答の文章) に
# 当たった正規表現からバッジを作る。並ぶのは今の branch の PR バッジ込みで最大 5 個で、
# 新しいものが先頭に入り、6 個目が来ると一番古いものが落ちる。ユーザーが打った文は拾わない。
#
# 正規表現そのものと、なぜその形なのかは nix/README.md の
# 「footer に会話のチケットと PR と cc-page のリンクを出す」を参照。
#
# ## 何を読むか
#
# home-manager が置く ~/.local/state/dotfiles/claude-footer-links.json
# (footerLinksRegexes の配列そのもの。中身は nix/files/claude/footer-links.json の cc-page の規則の
# @ccPagesPort@ を、このマシンの cc-pages の port で埋めたもの。home/modules/claude.nix が作る)。
#
# 無ければ、この形を置く世代へまだ switch していないということなので、
# 警告して exit 0 する (setup.sh は手順が 1 つ失敗すると残りを走らせないため)。
#
# ## 何をするか
#
# ~/.claude/settings.json の .footerLinksRegexes を、生成ファイルの配列で丸ごと置き換える。
#
#   - このキーは dotfiles が持つ。手で足した項目も次の実行で消える
#     (statusLine と同じ扱い。足したいなら nix/files/claude/footer-links.json に書く)
#   - 他のキーは保持する。同じ内容なら何もしない
#   - 別の値が入っていたら、元の値を表示してから置き換える
#
# 実行中の Claude Code にも効く。settings.json を読み直すので、次の turn の終わりから
# バッジが付く (2.1.292 で確認)。
#
# ## なぜ Nix でやらないのか
#
# settings.json は Claude Code 自身が書き換える (権限の「常に許可」など) ため、
# store 上の read-only ファイルにできない。bootstrap-claude-skill-overrides.sh と
# まったく同じ切り分け。footerLinksRegexes は user / flag / managed の settings からしか
# 読まれず、repo の .claude/settings.json に置いても効かない点でも、ここに書くしかない。

set -eu -o pipefail

settings="${HOME}/.claude/settings.json"
generated="${HOME}/.local/state/dotfiles/claude-footer-links.json"

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
    "footer-links.json を置く世代へ先に home-manager switch してください。" \
    "この手順は飛ばします。"
  exit 0
fi

# Claude Code は形の合わない項目を黙って捨てる (debug log に警告が出るだけ)。
# 書く前に、配列であることと各項目の型をここで見ておく。
if ! jq -e '
  type == "array"
  and all(.[];
    type == "object" and .type == "regex"
    and (.pattern | type == "string") and (.url | type == "string")
    and ((.label // "") | type == "string"))
' "${generated}" >/dev/null 2>&1; then
  echo "${generated} が footerLinksRegexes の配列 ({type: \"regex\", pattern, url, label?} の並び) ではありません。" >&2
  exit 1
fi

mkdir -p "$(dirname "${settings}")"
[[ -f ${settings} ]] || echo '{}' >"${settings}"

if ! jq -e . "${settings}" >/dev/null 2>&1; then
  echo "${settings} が JSON として壊れています。手で直してください。" >&2
  exit 1
fi

current=$(jq -cS '.footerLinksRegexes // empty' "${settings}")
desired=$(jq -cS . "${generated}")

if [[ ${current} == "${desired}" ]]; then
  echo "登録済みです: ${settings} の .footerLinksRegexes ($(jq 'length' "${generated}") 件)"
  exit 0
fi

if [[ -n ${current} ]]; then
  echo "既存の footerLinksRegexes を置き換えます:"
  jq '.footerLinksRegexes' "${settings}"
  echo
fi

tmp=$(mktemp "${settings}.XXXXXX")
# jq が落ちたときに settings.json の隣へ中間ファイルを残さない。
trap 'rm -f "${tmp}"' EXIT

jq --slurpfile gen "${generated}" '.footerLinksRegexes = $gen[0]' "${settings}" >"${tmp}"
mv "${tmp}" "${settings}"

echo "登録しました: footerLinksRegexes ($(jq 'length' "${generated}") 件)"
echo
echo "--- ${settings} の footerLinksRegexes (label と url) ---"
jq -r '.footerLinksRegexes[] | "  \(.label // "(一致した文字列)")  \(.url)"' "${settings}"
echo
echo "実行中の session にも、次の turn の終わりから効きます。"
