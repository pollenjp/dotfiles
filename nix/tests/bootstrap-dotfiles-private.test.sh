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
#   - 無ければ clone し、あれば pull --ff-only する
#   - 未コミットの変更があれば pull を飛ばす。git の repo でないものがあれば触らない
#   - clone できなくても exit 0 (警告だけ)。知らない引数は exit 2
#   - setup から走るとき (DOTFILES_SETUP_WARNINGS がある) は、警告を続きの行ごと setup の最後の
#     まとめ用のファイルにも残す

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
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

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

rc() { cat "$1/rc"; }
outerr() { cat "$1/out" "$1/err"; }

echo "== bootstrap-dotfiles-private.sh: ${script}"

# 1. 無ければ clone する
h="${work}/t1"
run "${h}"
if [[ $(rc "${h}") == 0 && -f ${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv ]] && outerr "${h}" | grep -q 'clone しました'; then
  ok "無ければ clone する"
else
  ng "clone" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 2. あれば pull --ff-only する
printf 'あ\t亜\t名詞\t\n' >>"${work}/author/google-japanese-input/dictionaries/テスト辞書.tsv"
git -C "${work}/author" commit --quiet -am second
git -C "${work}/author" push --quiet origin HEAD:main
run "${h}"
if [[ $(rc "${h}") == 0 ]] && grep -q '^あ' "${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv" && outerr "${h}" | grep -q '更新しました'; then
  ok "あれば pull --ff-only で追いつく"
else
  ng "pull" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 3. 未コミットの変更があれば pull を飛ばす (変更は残す)
printf 'い\t伊\t名詞\t\n' >>"${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv"
run "${h}"
if [[ $(rc "${h}") == 0 ]] && outerr "${h}" | grep -q '未コミットの変更' && grep -q '^い' "${h}/private/google-japanese-input/dictionaries/テスト辞書.tsv"; then
  ok "未コミットの変更があれば pull を飛ばし、変更を残す"
else
  ng "未コミット" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 4. git の repo でないものがあれば触らない
h="${work}/t4"
mkdir -p "${h}/private"
printf 'keep\n' >"${h}/private/file"
run "${h}"
if [[ $(rc "${h}") == 0 && $(cat "${h}/private/file") == keep ]] && outerr "${h}" | grep -q 'git の repo ではありません'; then
  ok "git の repo でないものがあれば触らずに exit 0"
else
  ng "repo でない" "rc=$(rc "${h}") $(outerr "${h}")"
fi

# 5. clone できない: 警告して exit 0 (何も作らない)
h="${work}/t5"
DOTFILES_PRIVATE_URL_OVERRIDE="file://${work}/no-such.git" run "${h}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/private ]] && outerr "${h}" | grep -q 'clone に失敗しました'; then
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
  && grep -qE '^[[:space:]]+private な repo なので SSH 鍵が要ります' "${h}/warnings" \
  && grep -qE '^[[:space:]]+取れないあいだ' "${h}/warnings"; then
  ok "setup から走るとき、clone できない警告を続きの行ごとまとめ用に残す"
else
  ng "clone できないときのまとめ" "rc=$(rc "${h}") warnings=$(cat "${h}/warnings" 2>/dev/null)"
fi
if grep -qx '   private な repo なので SSH 鍵が要ります。ssh -T git@github.com で疎通を確かめてください。' "${h}/err"; then
  ok "その場の続きの行は今のまま (3 文字字下げして stderr に出す)"
else
  ng "その場の続きの行が変わった" "$(cat "${h}/err")"
fi

# 6. 知らない引数: exit 2
h="${work}/t6"
run "${h}" --bogus
if [[ $(rc "${h}") == 2 && ! -e ${h}/private ]]; then
  ok "知らない引数は exit 2"
else
  ng "知らない引数" "rc=$(rc "${h}") $(outerr "${h}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
