#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-cc-pages.sh --status が出すビューアの URL と、手元の clone の取得を、使い捨ての HOME で確かめる。
#
#   bash nix/tests/bootstrap-cc-pages.test.sh [<script のパス>]
#
# flake の checks (bootstrap-cc-pages-test) が Nix のサンドボックスで流す。
# 使うのは bash・coreutils・sed・git だけ。GitHub には出ない (取得は手元の bare repo から)。ビルドはしない
# (go を PATH に入れず、ビルドの手前の「go が見つかりません」で止まる形で流す)。
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
#
# 手元の clone の取得 (TKT-221。clone の URL は固定なので、clone は見ない):
#
#   - gitViaGh のマシン (~/.local/state/dotfiles/git-via-gh.json の enable が true) では、gh の資格情報
#     (git gh) で取得して fast-forward する
#   - git gh で取れなければ ssh (git) で取り直し、setup の最後のまとめにも警告を残す
#   - 履歴が分岐していたら fast-forward できない警告だけを出し、ssh で取り直さない (手元の commit は残す)
#
# git gh の代わりに偽の git-gh を置く (引数を書き留めて本物の git に渡すか、落ちる)。gh も偽物で、
# auth token の終了コードだけを返す。

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

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# 流す人の env の git の設定 (Claude のセッションの GIT_CONFIG_* など) も効かせない
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0

# 要るコマンドだけを並べた PATH (go は入れない)
sys_bin="${work}/sys-bin"
mkdir -p "${sys_bin}"
for c in git mkdir dirname cat rm ln env sed; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${sys_bin}/${c}"
done

# 偽の gh と git-gh。gh は auth token なら FAKE_GH_AUTH_RC で終わる。git-gh は引数を GITGH_LOG に書き、
# FAKE_GITGH_FAIL=1 なら落ち、でなければ本物の git に渡す (gh の資格情報で通った代わり)。shebang は $BASH
# から作る (サンドボックスに /usr/bin/env が無い)
fakebin="${work}/fake-bin"
mkdir -p "${fakebin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
if [[ ${1-} == auth && ${2-} == token ]]; then
  exit "${FAKE_GH_AUTH_RC:-0}"
fi
exit 0
EOF
} >"${fakebin}/gh"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$*" >>"${GITGH_LOG}"
if [[ ${FAKE_GITGH_FAIL-} == 1 ]]; then
  echo "git-gh (偽物): gh の資格情報で通れませんでした" >&2
  exit 128
fi
exec git "$@"
EOF
} >"${fakebin}/git-gh"
chmod +x "${fakebin}/gh" "${fakebin}/git-gh"

# 手元の「GitHub」: bare repo と、そこへ commit を足すための作業用の clone。script には別の clone (cc) を渡す
bare="${work}/cc-remote.git"
git init --quiet --bare "${bare}"
git -C "${bare}" symbolic-ref HEAD refs/heads/main
git clone --quiet "${bare}" "${work}/cc-author" 2>/dev/null
printf 'package main\n' >"${work}/cc-author/main.go"
git -C "${work}/cc-author" add -A
git -C "${work}/cc-author" commit --quiet -m first
git -C "${work}/cc-author" push --quiet origin HEAD:main
git clone --quiet "${bare}" "${work}/cc"
# bare repo へ 1 行足した commit を送る。$1: 足す行
remote_commit() {
  printf '%s\n' "$1" >>"${work}/cc-author/main.go"
  git -C "${work}/cc-author" commit --quiet -am "$1"
  git -C "${work}/cc-author" push --quiet origin HEAD:main
}

# --dir の clone (cc) を取得するところまで流す。$1: HOME。状態ファイル ({"enable":true}) を置き、偽の gh・
# git-gh と要るコマンドだけの PATH で流す。stdout・stderr・終了コード・git-gh の書き留めを <HOME>/ に残す
run_fetch() {
  local h=$1
  mkdir -p "${h}/.local/state/dotfiles"
  printf '%s\n' '{"enable":true}' >"${h}/.local/state/dotfiles/git-via-gh.json"
  env HOME="${h}" PATH="${fakebin}:${sys_bin}" GITGH_LOG="${h}/gitgh.log" \
    "${BASH}" "${script}" --dir "${work}/cc" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}
fetch_detail() { printf 'rc=%s\nout=%s\nerr=%s' "$(cat "$1/rc")" "$(cat "$1/out")" "$(cat "$1/err")"; }

echo "== bootstrap-cc-pages.sh の取得: ${script}"

# 5. gitViaGh のマシン: gh の資格情報 (git gh) で取得して進め、ビルドの手前 (go が無い) まで進む
remote_commit second
h="${work}/t5"
run_fetch "${h}"
if [[ $(cat "${h}/rc") == 0 && $(git -C "${work}/cc" rev-parse HEAD) == $(git -C "${bare}" rev-parse main) ]] \
  && grep -q 'fetch' "${h}/gitgh.log" 2>/dev/null && grep -q 'gh の資格情報 (HTTPS) で取りました。' "${h}/out" \
  && grep -q 'go が見つかりません' "${h}/err"; then
  ok "gitViaGh のマシンでは gh の資格情報 (git gh) で取得して進める"
else
  ng "gh で取得" "$(fetch_detail "${h}")"
fi

# 6. git gh で取れなければ ssh (git) で取り直し、まとめにも警告を残す
remote_commit third
h="${work}/t6"
FAKE_GITGH_FAIL=1 DOTFILES_SETUP_WARNINGS="${h}/warnings" run_fetch "${h}"
if [[ $(cat "${h}/rc") == 0 && $(git -C "${work}/cc" rev-parse HEAD) == $(git -C "${bare}" rev-parse main) ]] \
  && grep -q '取り直します' "${h}/out" \
  && [[ $(head -n 1 "${h}/warnings" 2>/dev/null) == 'gh の資格情報では取れず、ssh (ssh-agent) で取りました。' ]]; then
  ok "git gh で取れなければ ssh で取り直し、まとめにも警告を残す"
else
  ng "gh で落ちて ssh で取る" "$(fetch_detail "${h}")"$'\n'"warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi

# 7. 履歴が分岐している: fast-forward できない警告だけを出し、ssh で取り直さない (手元の commit は残す)
printf 'local\n' >>"${work}/cc/main.go"
git -C "${work}/cc" commit --quiet -am local
local_head=$(git -C "${work}/cc" rev-parse HEAD)
remote_commit fourth
h="${work}/t7"
run_fetch "${h}"
if [[ $(cat "${h}/rc") == 0 && $(git -C "${work}/cc" rev-parse HEAD) == "${local_head}" ]] \
  && grep -q 'fast-forward できませんでした' "${h}/err" && ! grep -q '取り直します' "${h}/out"; then
  ok "履歴が分岐していたら fast-forward できない警告だけを出し、ssh で取り直さない"
else
  ng "履歴の分岐" "$(fetch_detail "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
