#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-dotfiles-private.sh の振る舞いを、使い捨ての HOME と手元の bare repo で確かめる。
#
#   bash nix/tests/bootstrap-dotfiles-private.test.sh [<script のパス>]
#
# flake の checks (bootstrap-dotfiles-private-test) が Nix のサンドボックスで流す。
# 使うのは bash・git・coreutils・grep だけ。GitHub には出ない (DOTFILES_PRIVATE_URL を file:// に向ける)。
#
# ## 確かめること
#
#   - 無ければ clone し、あれば取得 (fetch) して fast-forward する
#   - 未コミットの変更があれば pull を飛ばす。git の repo でないものがあれば触らない
#   - clone できなくても exit 0 (警告だけ)。知らない引数は exit 2
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、警告を続きの行ごと setup の最後の
#     まとめ用のファイルにも残す
#   - gitViaGh のマシン (~/.local/state/dotfiles/git-via-gh.json の enable が true) では、gh の資格情報
#     (git gh) で clone・取得する。git gh で取れなければ ssh (git) で取り直し、まとめにも警告を残す。
#     false なら gh があっても使わない (TKT-221)
#   - 履歴が分岐していたら fast-forward できない警告だけを出し、ssh で取り直さない (手元の commit は残す)
#
# git gh の代わりに偽の git-gh を置く (引数を書き留めて本物の git に渡すか、落ちる)。gh も偽物で、
# auth token の終了コードだけを返す。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-dotfiles-private.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-dotfiles-private-test.XXXXXX")
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

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# 流す人の env の git の設定 (Claude のセッションの GIT_CONFIG_* など) も効かせない
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_COUNT=0

# 手元の「GitHub」: bare repo と、そこへ commit を足すための作業用の clone
bare="${work}/remote.git"
git init --quiet --bare "${bare}"
git -C "${bare}" symbolic-ref HEAD refs/heads/main
git clone --quiet "${bare}" "${work}/author" 2>/dev/null
mkdir -p "${work}/author/google-japanese-input/dictionaries"
printf 'てすと\tテスト\t名詞\t\n' >"${work}/author/google-japanese-input/dictionaries/テスト辞書.tsv"
git -C "${work}/author" add -A
git -C "${work}/author" commit --quiet -m first
git -C "${work}/author" push --quiet origin HEAD:main

# $1: HOME、残り: script の引数。clone 先は <HOME>/private、取りに行く先は bare repo
run() {
  local h=$1
  shift
  mkdir -p "${h}"
  env HOME="${h}" DOTFILES_PRIVATE_DIR="${h}/private" DOTFILES_PRIVATE_URL="${DOTFILES_PRIVATE_URL_OVERRIDE:-file://${bare}}" \
    "${BASH}" "${script}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

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

# run と同じく流す。HOME に状態ファイル (既定は {"enable":true}。VIA_GH で変える) を置き、偽の gh・git-gh を
# PATH の先頭に足す。git-gh の書き留めは <HOME>/gitgh.log
run_gh() {
  local h=$1 state=${VIA_GH-}
  [[ -n ${state} ]] || state='{"enable":true}'
  mkdir -p "${h}/.local/state/dotfiles"
  printf '%s\n' "${state}" >"${h}/.local/state/dotfiles/git-via-gh.json"
  PATH="${fakebin}:${PATH}" GITGH_LOG="${h}/gitgh.log" run "$@"
}

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }
# 判定の grep -q はパイプで受けず、ファイルを直に読む。outerr を grep -q へパイプでつなぐと、grep が
# out で合って先に抜けたあと cat が err を書こうとして SIGPIPE (141) で終わり、pipefail で「合わない」
# に見える (check-test-grep-q.sh が CI の lint で落とす)。$1: ケースのディレクトリ、残り: grep の引数
seen() {
  local d=$1
  shift
  grep -q "$@" "${d}/out" "${d}/err"
}

echo "== bootstrap-dotfiles-private.sh: ${script}"

# 1. 無ければ clone する
h="${work}/t1"
run "${h}"
if [[ $(rc "${h}") == 0 && -f ${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv ]] && seen "${h}" 'clone しました'; then
  ok "無ければ clone する"
else
  ng "clone" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. あれば取得して fast-forward する
printf 'あ\t亜\t名詞\t\n' >>"${work}/author/google-japanese-input/dictionaries/テスト辞書.tsv"
git -C "${work}/author" commit --quiet -am second
git -C "${work}/author" push --quiet origin HEAD:main
run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -q '^あ' "${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv" && seen "${h}" '更新しました'; then
  ok "あれば取得して fast-forward で追いつく"
else
  ng "pull" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. 未コミットの変更があれば pull を飛ばす (変更は残す)
printf 'い\t伊\t名詞\t\n' >>"${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && seen "${h}" '未コミットの変更' && grep -q '^い' "${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv"; then
  ok "未コミットの変更があれば pull を飛ばし、変更を残す"
else
  ng "未コミット" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. git の repo でないものがあれば触らない
h="${work}/t4"
mkdir -p "${h}/private"
printf 'keep\n' >"${h}/private/file"
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${h}/private/file") == keep ]] && seen "${h}" 'git の repo ではありません'; then
  ok "git の repo でないものがあれば触らずに exit 0"
else
  ng "repo でない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. clone できない: 警告して exit 0 (何も作らない)
h="${work}/t5"
DOTFILES_PRIVATE_URL_OVERRIDE="file://${work}/no-such.git" run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/private ]] && seen "${h}" 'clone に失敗しました'; then
  ok "clone できなくても exit 0 (警告だけ)"
else
  ng "clone できない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 7. setup から走るとき (DOTFILES_SETUP_WARNINGS がある): clone できない警告を、続きの行 (鍵の確かめ方と、
#    取れないあいだに配られないもの) ごとまとめ用に残す
h="${work}/t7"
mkdir -p "${h}"
DOTFILES_SETUP_WARNINGS="${h}/warnings" DOTFILES_PRIVATE_URL_OVERRIDE="file://${work}/no-such.git" run "${h}"
if [[ $(rc "${h}") == 0 && $(head -n 1 "${h}/warnings" 2>/dev/null) == 'clone に失敗しました: '* ]] \
  && grep -qE '^[[:space:]]+SSH 鍵 \(ssh-agent\) で取れませんでした' "${h}/warnings" \
  && grep -qE '^[[:space:]]+取れないあいだ' "${h}/warnings"; then
  ok "setup から走るとき、clone できない警告を続きの行ごとまとめ用に残す"
else
  ng "clone できないときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi
if grep -qx '   SSH 鍵 (ssh-agent) で取れませんでした。疎通は ssh -T git@github.com で確かめられます。' "${h}/err"; then
  ok "その場の続きの行は 3 文字字下げして stderr に出す (gitViaGh でなければ ssh の確かめ方だけ)"
else
  ng "その場の続きの行" "$(cat "${h}/err")"
fi

# 6. 知らない引数: exit 2
h="${work}/t6"
run "${h}" --bogus
if [[ $(rc "${h}") == 2 && ! -e ${h}/private ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

dict=google-japanese-input/dictionaries/テスト辞書.tsv
# bare repo へ 1 行足した commit を送る。$1: 足す行
remote_commit() {
  printf '%s\n' "$1" >>"${work}/author/${dict}"
  git -C "${work}/author" commit --quiet -am "$1"
  git -C "${work}/author" push --quiet origin HEAD:main
}

# 8. gitViaGh のマシン: gh の資格情報 (git gh) で clone する
h="${work}/t8"
run_gh "${h}"
if [[ $(rc "${h}") == 0 && -f ${h}/private/${dict} ]] && [[ $(head -n 1 "${h}/gitgh.log" 2>/dev/null) == 'clone '* ]] \
  && seen "${h}" 'gh の資格情報 (HTTPS) で取りました。'; then
  ok "gitViaGh のマシンでは gh の資格情報 (git gh) で clone する"
else
  ng "gh で clone" "rc=$(rc "${h}") log=$(cat "${h}/gitgh.log" 2>/dev/null) $(outerr "${h}")"
fi

# 9. gitViaGh のマシン: gh の資格情報 (git gh) で取得して追いつく
remote_commit $'う\t宇\t名詞\t'
run_gh "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -q '^う' "${h}/private/${dict}" && grep -q 'fetch --quiet' "${h}/gitgh.log" \
  && seen "${h}" '更新しました'; then
  ok "gitViaGh のマシンでは gh の資格情報 (git gh) で取得して追いつく"
else
  ng "gh で取得" "rc=$(rc "${h}") log=$(cat "${h}/gitgh.log" 2>/dev/null) $(outerr "${h}")"
fi

# 10. git gh で取れなければ ssh (git) で取り直し、まとめにも警告を残す
remote_commit $'え\t絵\t名詞\t'
FAKE_GITGH_FAIL=1 DOTFILES_SETUP_WARNINGS="${h}/warnings10" run_gh "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -q '^え' "${h}/private/${dict}" && seen "${h}" '取り直します' \
  && [[ $(head -n 1 "${h}/warnings10" 2>/dev/null) == 'gh の資格情報では取れず、ssh (ssh-agent) で取りました。' ]]; then
  ok "git gh で取れなければ ssh で取り直し、まとめにも警告を残す"
else
  ng "gh で落ちて ssh で取る" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings10" 2>/dev/null) $(outerr "${h}")"
fi

# 11. 履歴が分岐している: fast-forward できない警告だけを出し、ssh で取り直さない (手元の commit は残す)
printf 'お\t尾\t名詞\t\n' >>"${h}/private/${dict}"
git -C "${h}/private" commit --quiet -am local
local_head=$(git -C "${h}/private" rev-parse HEAD)
remote_commit $'か\t蚊\t名詞\t'
run_gh "${h}"
if [[ $(rc "${h}") == 0 ]] && seen "${h}" 'fast-forward できません' && ! seen "${h}" '取り直します' \
  && [[ $(git -C "${h}/private" rev-parse HEAD) == "${local_head}" ]]; then
  ok "履歴が分岐していたら fast-forward できない警告だけを出し、ssh で取り直さない"
else
  ng "履歴の分岐" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 12. gitViaGh が false: gh があっても使わず、今までどおり git (ssh) で取る
h="${work}/t12"
VIA_GH='{"enable":false}' run_gh "${h}"
if [[ $(rc "${h}") == 0 && -f ${h}/private/${dict} && ! -e ${h}/gitgh.log ]] && ! seen "${h}" 'gh の資格情報'; then
  ok "gitViaGh が false なら、gh があっても使わずに git (ssh) で取る"
else
  ng "gitViaGh が false" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
