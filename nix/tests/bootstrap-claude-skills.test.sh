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

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
