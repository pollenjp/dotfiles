#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/bootstrap-claude-skills.sh の取得 (手元の clone を進めるところ) を、使い捨ての HOME と手元の bare repo で
# 確かめる。
#
#   bash nix/tests/bootstrap-claude-skills.test.sh [<script のパス>]
#
# flake の checks (bootstrap-claude-skills-test) が Nix のサンドボックスで流す。
# 使うのは bash・git・coreutils・grep だけ。GitHub には出ない (--dir に手元の bare repo の clone を渡す。clone の
# URL は固定なので、clone は見ない)。
#
# ## 確かめること
#
#   - gitViaGh のマシンでない (状態ファイルが無い) なら、gh があっても使わずに git (ssh) で取得して進め、
#     増えた skill のリンクを ~/.claude/skills/ に張る
#   - gitViaGh のマシン (~/.local/state/dotfiles/git-via-gh.json の enable が true) では、gh の資格情報
#     (git gh) で取得して進める (TKT-221)
#   - git gh で取れなければ ssh (git) で取り直し、setup の最後のまとめにも警告を残す
#   - 履歴が分岐していたら fast-forward できない警告を出し、ssh で取り直さない。手元の clone のままリンクは張る
#   - --dry-run では取得も merge もせず、走るコマンド (git_github -C <dir> fetch) を見せるだけ
#   - rules/ の rule も ~/.claude/rules/ へ 1 つずつ張り (README.md は張らない)、repo から消えた rule の symlink は外す
#   - 公開の土台の skill (home-manager が ~/.local/state/dotfiles/claude-base-skills.tsv に名前と store のパスを書いたもの): claude-skills の
#     clone に同じ名前があればそちらを張り (前に張った土台のリンクも張り替える)、無ければ store のパスを張る。store のパスが替われば張り
#     替え、表から外れた名前の土台のリンクは外す。土台の形でないリンク・実体は張り替えず、警告する。clone が無くても土台は張る
#     (store は NIX_STORE_DIR の一時のディレクトリ)
#
# git gh の代わりに偽の git-gh を置く (引数を書き留めて本物の git に渡すか、落ちる)。gh も偽物で、
# auth token の終了コードだけを返す。偽のコマンドの shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/bootstrap-claude-skills.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-claude-skills-test.XXXXXX")
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

# 偽の gh と git-gh。gh は auth token なら FAKE_GH_AUTH_RC で終わる。git-gh は引数を GITGH_LOG に書き、
# FAKE_GITGH_FAIL=1 なら落ち、でなければ本物の git に渡す (gh の資格情報で通った代わり)
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

# 手元の「GitHub」: bare repo と、そこへ commit を足すための作業用の clone。script には別の clone を渡す
bare="${work}/remote.git"
clone="${work}/claude-skills"
git init --quiet --bare "${bare}"
git -C "${bare}" symbolic-ref HEAD refs/heads/main
git clone --quiet "${bare}" "${work}/author" 2>/dev/null
mkdir -p "${work}/author/skills/a"
printf '# a\n' >"${work}/author/skills/a/SKILL.md"
git -C "${work}/author" add -A
git -C "${work}/author" commit --quiet -m a
git -C "${work}/author" push --quiet origin HEAD:main
git clone --quiet "${bare}" "${clone}"

# bare repo へ skill を 1 つ足した commit を送る。$1: skill の名前
remote_skill() {
  mkdir -p "${work}/author/skills/$1"
  printf '# %s\n' "$1" >"${work}/author/skills/$1/SKILL.md"
  git -C "${work}/author" add -A
  git -C "${work}/author" commit --quiet -m "$1"
  git -C "${work}/author" push --quiet origin HEAD:main
}

# $1: HOME (ケースのディレクトリ)、残り: script の引数。VIA_GH があれば状態ファイルに書く (無ければ置かない)。
# 偽の gh・git-gh を PATH の先頭に足し、--dir に手元の clone を渡す。stdout・stderr・終了コード・git-gh の
# 書き留めを <HOME>/{out,err,rc,gitgh.log} に残す
run() {
  local h=$1
  shift
  mkdir -p "${h}"
  if [[ -n ${VIA_GH-} ]]; then
    mkdir -p "${h}/.local/state/dotfiles"
    printf '%s\n' "${VIA_GH}" >"${h}/.local/state/dotfiles/git-via-gh.json"
  fi
  env HOME="${h}" PATH="${fakebin}:${PATH}" GITGH_LOG="${h}/gitgh.log" \
    "${BASH}" "${script}" --dir "${clone}" "$@" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}

rc() { cat "$1/rc"; }
detail() { printf 'rc=%s\nout=%s\nerr=%s' "$(cat "$1/rc")" "$(cat "$1/out")" "$(cat "$1/err")"; }
head_of() { git -C "$1" rev-parse HEAD; }

echo "== bootstrap-claude-skills.sh の取得: ${script}"

# 1. gitViaGh のマシンでない: gh があっても使わずに git (ssh) で取得して進め、増えた skill をリンクする
remote_skill b
h="${work}/t1"
run "${h}"
if [[ $(rc "${h}") == 0 && $(head_of "${clone}") == $(head_of "${bare}") ]] \
  && [[ $(readlink "${h}/.claude/skills/b" 2>/dev/null) == "${clone}/skills/b" && ! -e ${h}/gitgh.log ]]; then
  ok "gitViaGh のマシンでなければ、gh があっても使わずに git (ssh) で取得して進め、増えた skill をリンクする"
else
  ng "gitViaGh でない" "$(detail "${h}")"
fi

# 2. gitViaGh のマシン: gh の資格情報 (git gh) で取得して進める
remote_skill c
h="${work}/t2"
VIA_GH='{"enable":true}' run "${h}"
if [[ $(rc "${h}") == 0 && $(head_of "${clone}") == $(head_of "${bare}") ]] \
  && grep -q 'gh の資格情報 (HTTPS) で取りました。' "${h}/out" && grep -q 'fetch' "${h}/gitgh.log" 2>/dev/null \
  && [[ -L ${h}/.claude/skills/c ]]; then
  ok "gitViaGh のマシンでは gh の資格情報 (git gh) で取得して進める"
else
  ng "gh で取得" "$(detail "${h}")"
fi

# 3. git gh で取れなければ ssh (git) で取り直し、まとめにも警告を残す
remote_skill d
h="${work}/t3"
VIA_GH='{"enable":true}' FAKE_GITGH_FAIL=1 DOTFILES_SETUP_WARNINGS="${work}/t3-warnings" run "${h}"
if [[ $(rc "${h}") == 0 && $(head_of "${clone}") == $(head_of "${bare}") ]] && grep -q '取り直します' "${h}/out" \
  && [[ $(head -n 1 "${work}/t3-warnings" 2>/dev/null) == 'gh の資格情報では取れず、ssh (ssh-agent) で取りました。' ]]; then
  ok "git gh で取れなければ ssh で取り直し、まとめにも警告を残す"
else
  ng "gh で落ちて ssh で取る" "$(detail "${h}")"$'\n'"warnings=$(cat "${work}/t3-warnings" 2>/dev/null)"
fi

# 4. 履歴が分岐している: fast-forward できない警告を出し、ssh で取り直さない。手元の clone のままリンクは張る
mkdir -p "${clone}/skills/local"
printf '# local\n' >"${clone}/skills/local/SKILL.md"
git -C "${clone}" add -A
git -C "${clone}" commit --quiet -m local
local_head=$(head_of "${clone}")
remote_skill e
h="${work}/t4"
VIA_GH='{"enable":true}' run "${h}"
if [[ $(rc "${h}") == 0 && $(head_of "${clone}") == "${local_head}" ]] \
  && grep -q 'fast-forward できません' "${h}/err" && grep -q 'claude-skills を更新できていません' "${h}/err" \
  && ! grep -q '取り直します' "${h}/out" && [[ -L ${h}/.claude/skills/local ]]; then
  ok "履歴が分岐していたら fast-forward できない警告を出し、ssh で取り直さず、手元の clone でリンクを張る"
else
  ng "履歴の分岐" "$(detail "${h}")"
fi

# 5. --dry-run: 取得も merge もせず、走るコマンドを見せるだけ
h="${work}/t5"
VIA_GH='{"enable":true}' run "${h}" --dry-run
if [[ $(rc "${h}") == 0 && $(head_of "${clone}") == "${local_head}" && ! -e ${h}/gitgh.log ]] \
  && grep -qF "+ git_github -C ${clone} fetch" "${h}/out"; then
  ok "--dry-run では取得も merge もせず、git_github -C <dir> fetch を見せるだけ"
else
  ng "--dry-run" "$(detail "${h}")"
fi

# 6. rules/ の rule: ~/.claude/rules/ へ張り (README.md は張らない)、repo から消えたら外す。ケース 4 で分岐させた
#    clone の履歴に依らないよう、別の bare repo と clone で流す
rbare="${work}/rules-remote.git"
rclone="${work}/rules-skills"
git init --quiet --bare "${rbare}"
git -C "${rbare}" symbolic-ref HEAD refs/heads/main
git clone --quiet "${rbare}" "${work}/rules-author" 2>/dev/null
mkdir -p "${work}/rules-author/rules"
printf -- '---\npaths:\n  - "**/*.rs"\n---\n# rust\n' >"${work}/rules-author/rules/pjp-rust.md"
printf '# rules\n' >"${work}/rules-author/rules/README.md"
git -C "${work}/rules-author" add -A
git -C "${work}/rules-author" commit --quiet -m rules
git -C "${work}/rules-author" push --quiet origin HEAD:main
git clone --quiet "${rbare}" "${rclone}"
h="${work}/t6"
mkdir -p "${h}"
env HOME="${h}" PATH="${fakebin}:${PATH}" GITGH_LOG="${h}/gitgh.log" \
  "${BASH}" "${script}" --dir "${rclone}" >"${h}/out" 2>"${h}/err"
echo $? >"${h}/rc"
linked_rule=$(readlink "${h}/.claude/rules/pjp-rust.md" 2>/dev/null)
if [[ $(rc "${h}") == 0 && ${linked_rule} == "${rclone}/rules/pjp-rust.md" && ! -e ${h}/.claude/rules/README.md ]]; then
  ok "rules/ の rule を ~/.claude/rules/ へ張り、README.md は張らない"
else
  ng "rules/ の rule を張る" "$(detail "${h}")"$'\n'"rules=$(ls -la "${h}/.claude/rules" 2>&1)"
fi
git -C "${work}/rules-author" rm --quiet rules/pjp-rust.md
git -C "${work}/rules-author" commit --quiet -m 'drop rust'
git -C "${work}/rules-author" push --quiet origin HEAD:main
env HOME="${h}" PATH="${fakebin}:${PATH}" GITGH_LOG="${h}/gitgh.log" \
  "${BASH}" "${script}" --dir "${rclone}" >"${h}/out" 2>"${h}/err"
echo $? >"${h}/rc"
if [[ $(rc "${h}") == 0 && ! -L ${h}/.claude/rules/pjp-rust.md && ! -e ${h}/.claude/rules/pjp-rust.md ]]; then
  ok "repo から消えた rule の symlink は外す"
else
  ng "消えた rule を外す" "$(detail "${h}")"$'\n'"rules=$(ls -la "${h}/.claude/rules" 2>&1)"
fi

# 7. 公開の土台の skill (claude-base-skills.tsv)。ケース 4 で分岐させた clone に依らないよう、別の bare repo と clone で流す
bbare="${work}/base-remote.git"
bclone="${work}/base-skills"
git init --quiet --bare "${bbare}"
git -C "${bbare}" symbolic-ref HEAD refs/heads/main
git clone --quiet "${bbare}" "${work}/base-author" 2>/dev/null
mkdir -p "${work}/base-author/skills/pjp-hub"
printf '# hub (claude-skills の写し)\n' >"${work}/base-author/skills/pjp-hub/SKILL.md"
git -C "${work}/base-author" add -A
git -C "${work}/base-author" commit --quiet -m hub
git -C "${work}/base-author" push --quiet origin HEAD:main
git clone --quiet "${bbare}" "${bclone}"
store="${work}/store"
hash1=0123456789abcdefghijklmnopqrstuv
hash2=vutsrqponmlkjihgfedcba9876543210
for b in "${hash1}-pjp-hub" "${hash1}-pjp-child" "${hash2}-pjp-child"; do
  mkdir -p "${store}/${b}"
  printf '# %s (dotfiles の土台)\n' "${b}" >"${store}/${b}/SKILL.md"
done
h="${work}/t7"
mkdir -p "${h}/.local/state/dotfiles" "${h}/.claude/skills"
base_tsv="${h}/.local/state/dotfiles/claude-base-skills.tsv"
# $@: 名前<TAB>パス の行
write_base() { printf '%s\n' "$@" >"${base_tsv}"; }
run_base() {
  env HOME="${h}" NIX_STORE_DIR="${store}" PATH="${fakebin}:${PATH}" GITGH_LOG="${h}/gitgh.log" \
    "${BASH}" "${script}" --dir "$1" >"${h}/out" 2>"${h}/err"
  echo $? >"${h}/rc"
}
# pjp-hub は前に張った土台のリンクがある (claude-skills の写しへ張り替わる)。pjp-child は claude-skills に無い
ln -s "${store}/${hash1}-pjp-hub" "${h}/.claude/skills/pjp-hub"
write_base "pjp-hub"$'\t'"${store}/${hash1}-pjp-hub" "pjp-child"$'\t'"${store}/${hash1}-pjp-child"
run_base "${bclone}"
if [[ $(rc "${h}") == 0 && $(readlink "${h}/.claude/skills/pjp-hub") == "${bclone}/skills/pjp-hub" ]] \
  && [[ $(readlink "${h}/.claude/skills/pjp-child") == "${store}/${hash1}-pjp-child" ]] && ! grep -q '飛ばし' "${h}/err"; then
  ok "claude-skills に同じ名前があればそちら (前の土台のリンクも張り替える)、無ければ土台の store のパスを張る"
else
  ng "土台の skill を張る" "$(detail "${h}")"$'\n'"skills=$(ls -la "${h}/.claude/skills" 2>&1)"
fi
# store のパスが替わった (home-manager の新しい世代): 張り替える
write_base "pjp-hub"$'\t'"${store}/${hash1}-pjp-hub" "pjp-child"$'\t'"${store}/${hash2}-pjp-child"
run_base "${bclone}"
if [[ $(rc "${h}") == 0 && $(readlink "${h}/.claude/skills/pjp-child") == "${store}/${hash2}-pjp-child" ]]; then
  ok "土台の store のパスが替われば張り替える"
else
  ng "土台の張り替え" "$(detail "${h}")"$'\n'"skills=$(ls -la "${h}/.claude/skills" 2>&1)"
fi
# claude-skills から消えた (片付けの PR の後): claude-skills のリンクを外し、土台を張る
git -C "${work}/base-author" rm --quiet -r skills/pjp-hub
git -C "${work}/base-author" commit --quiet -m 'drop hub'
git -C "${work}/base-author" push --quiet origin HEAD:main
run_base "${bclone}"
if [[ $(rc "${h}") == 0 && $(readlink "${h}/.claude/skills/pjp-hub") == "${store}/${hash1}-pjp-hub" ]]; then
  ok "claude-skills から消えた名前は、claude-skills のリンクを外して土台を張る"
else
  ng "片付けの後の土台" "$(detail "${h}")"$'\n'"skills=$(ls -la "${h}/.claude/skills" 2>&1)"
fi
# 表から外れた名前の土台のリンクは外す。土台の形でないリンク・実体には触らず、警告する
write_base "pjp-hub"$'\t'"${store}/${hash1}-pjp-hub" "pjp-own"$'\t'"${store}/${hash1}-pjp-own" "pjp-real"$'\t'"${store}/${hash1}-pjp-real"
ln -s "${work}/somewhere" "${h}/.claude/skills/pjp-own"
mkdir -p "${h}/.claude/skills/pjp-real"
run_base "${bclone}"
if [[ $(rc "${h}") == 0 && ! -e ${h}/.claude/skills/pjp-child && ! -L ${h}/.claude/skills/pjp-child ]] \
  && [[ $(readlink "${h}/.claude/skills/pjp-own") == "${work}/somewhere" && -d ${h}/.claude/skills/pjp-real && ! -L ${h}/.claude/skills/pjp-real ]] \
  && grep -q 'skills/pjp-own: 別の symlink' "${h}/err" && grep -q 'skills/pjp-real: 実体' "${h}/err"; then
  ok "表から外れた名前の土台のリンクは外し、土台の形でないリンクと実体には触らずに警告する"
else
  ng "土台の外し方と衝突" "$(detail "${h}")"$'\n'"skills=$(ls -la "${h}/.claude/skills" 2>&1)"
fi
# clone を取れない (git の repo でないディレクトリ。GitHub へは出ない) ときも土台は張る
h="${work}/t7b"
mkdir -p "${h}/.local/state/dotfiles" "${work}/not-a-clone"
base_tsv="${h}/.local/state/dotfiles/claude-base-skills.tsv"
write_base "pjp-child"$'\t'"${store}/${hash2}-pjp-child"
run_base "${work}/not-a-clone"
if [[ $(rc "${h}") == 0 && $(readlink "${h}/.claude/skills/pjp-child") == "${store}/${hash2}-pjp-child" ]]; then
  ok "claude-skills の clone が無くても土台の skill は張る"
else
  ng "clone の無いときの土台" "$(detail "${h}")"$'\n'"skills=$(ls -la "${h}/.claude/skills" 2>&1)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
