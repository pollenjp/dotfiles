#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-cc-pages.sh --status が出すビューアの URL を、使い捨ての HOME で確かめる。
#
#   bash nix/tests/bootstrap-cc-pages.test.sh [<script のパス>]
#
# flake の checks (bootstrap-cc-pages-test) が Nix のサンドボックスで流す。
# 使うのは bash・coreutils・sed だけ。clone もビルドもしない (--status だけを流す)。
#
# ## 確かめること
#
# URL は daemon と同じく ~/.config/cc-pages/config.toml の addr から組む。host は cc-pages の
# BaseURL と同じく 127.0.0.1 を localhost にし、ほかの host はそのまま出す。
#
#   - config.toml が無ければ cc-pages の既定の http://localhost:7777
#   - addr が 127.0.0.1:<port> なら http://localhost:<port>
#   - addr の host が 127.0.0.1 でなければ、その host のまま
#   - config.toml に addr が無ければ既定の http://localhost:7777

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-cc-pages.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-cc-pages-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

# $1: HOME、$2: config.toml の中身 (空なら置かない)。--status の出力を <HOME>/out に書く
status_with() {
  local h=$1 toml=$2
  mkdir -p "${h}"
  if [[ -n ${toml} ]]; then
    mkdir -p "${h}/.config/cc-pages"
    printf '%s\n' "${toml}" >"${h}/.config/cc-pages/config.toml"
  fi
  # クローン先も HOME の中に向ける (ghq がある環境で流しても、手元のクローンを見に行かない)
  env HOME="${h}" CC_PAGES_DIR="${h}/clone" "${BASH}" "${script}" --status >"${h}/out" 2>&1
  echo $? >"${h}/rc"
}

# $1: 項目の名前、$2: HOME、$3: 出てほしい URL
expect_viewer() {
  local got
  got=$(sed -n 's/^ビューア: //p' "$2/out")
  if [[ $(cat "$2/rc") == 0 && ${got} == "$3" ]]; then
    ok "$1"
  else
    ng "$1" "rc=$(cat "$2/rc") ビューア=${got:-(無し)}"$'\n'"$(cat "$2/out")"
  fi
}

echo "== bootstrap-cc-pages.sh --status: ${script}"

h="${work}/t1"
status_with "${h}" ""
expect_viewer "config.toml が無ければ既定の http://localhost:7777" "${h}" "http://localhost:7777"

h="${work}/t2"
status_with "${h}" 'addr = "127.0.0.1:7778"'
expect_viewer "addr が 127.0.0.1:<port> なら http://localhost:<port>" "${h}" "http://localhost:7778"

h="${work}/t3"
status_with "${h}" 'addr = "192.168.1.5:7000"'
expect_viewer "addr の host が 127.0.0.1 でなければ、その host のまま" "${h}" "http://192.168.1.5:7000"

h="${work}/t4"
status_with "${h}" 'root = "/srv/cc-pages"'
expect_viewer "config.toml に addr が無ければ既定の http://localhost:7777" "${h}" "http://localhost:7777"

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
