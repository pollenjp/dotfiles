#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の Stop フック (の入口)。会話に出たリンク (footer のバッジと同じ規則で拾う PR・チケット・cc-page) を、
# cc-pages の会話のトップページの「リンク」の節に全部残す。footer のバッジは今の branch の PR を含めて 5 個までで、
# 長い会話では前に出たリンクが押し出されるため。
#
# 本体は隣の footer-links-archive.mjs (node)。ここは、使える状態かを見てから本体を起こすだけ。
#
#   footer-links-archive.sh                                       Stop フックとして (stdin に Stop の入力)
#   footer-links-archive.sh --session <id> --transcript <path>    1 つの会話を 0 から流す (終わった会話を埋める・試す)
#
# ## 黙って抜ける場面 (hook の口)
#
#   - CC_PAGES_DISABLE が空でない (cc-page の skill と同じく、cc-pages を使わない合図)
#   - cc-pages が PATH に無い (~/bin/cc-pages は bootstrap-cc-pages.sh が置き、取れないマシンには無い)
#   - node が PATH に無い (node は mise が入れる言語ランタイム。home の閉包には入れない)
#
# どれも transcript を読まずに 0 で終わる。揃っていれば本体を起こし、本体の stdout・stderr は捨てて、何が起きても 0 で
# 終わる (Stop の stdout の JSON は decision: "block" などとして読まれうる)。手で流す口は、足りなければ理由を stderr に出して
# 1 で終わり、揃っていれば本体の終了コードで終わる (報告は本体が stderr に書く)。
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks.Stop に async: true で足す (turn の終わりを遅らせない)。
# 使い方と控えの場所は nix/README.md の「溢れたリンクを会話のトップページに残す」。

set -u -o pipefail

here=${BASH_SOURCE[0]%/*}
[[ ${here} == "${BASH_SOURCE[0]}" ]] && here=.
body="${here}/footer-links-archive.mjs"

if [[ $# -eq 0 ]]; then
  # stdin を読み捨ててから抜ける (書き手の Claude Code を待たせない)
  if [[ -n ${CC_PAGES_DISABLE:-} ]] || ! cc_pages=$(type -P cc-pages) || ! type -P node &>/dev/null; then
    IFS= read -r -d '' _ || true
    exit 0
  fi
  node "${body}" --cc-pages "${cc_pages}" >/dev/null 2>&1
  exit 0
fi

for arg in "$@"; do
  if [[ ${arg} == -h || ${arg} == --help ]]; then
    type -P node &>/dev/null || {
      echo "footer-links-archive: node が PATH にありません" >&2
      exit 1
    }
    exec node "${body}" --help
  fi
done

if [[ -n ${CC_PAGES_DISABLE:-} ]]; then
  echo "footer-links-archive: CC_PAGES_DISABLE が立っているので流しません" >&2
  exit 1
fi
if ! cc_pages=$(type -P cc-pages); then
  echo "footer-links-archive: cc-pages が PATH にありません" >&2
  exit 1
fi
if ! type -P node &>/dev/null; then
  echo "footer-links-archive: node が PATH にありません" >&2
  exit 1
fi
exec node "${body}" --cc-pages "${cc_pages}" "$@"
