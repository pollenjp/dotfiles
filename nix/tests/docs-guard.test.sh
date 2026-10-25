#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/docs-guard.sh の振る舞いを、使い捨ての git の repo と合成した PreToolUse の入力で確かめる。
#
#   bash nix/tests/docs-guard.test.sh [<docs-guard.sh のパス>]
#
# flake の checks (docs-guard-test) が Nix のサンドボックスで流す。使うのは bash・jq・git・coreutils だけ。
#
# ## 確かめること
#
#   - 表の repo (pollenjp/dotfiles) の work tree の直下の docs/ への Write・Edit・MultiEdit・NotebookEdit を止め
#     (permissionDecision の deny)、理由に書き先 (pollenjp/dotfiles-private の docs/ の同じ相対パス)・手元と cloud での
#     取り方・Bash で回り込まないこと・CLAUDE.md を返す
#   - docs/ がまだ無い repo の深い新しいファイル・worktree・symlink の祖先を通した path・cwd から解く相対パスでも止める
#   - origin の URL の形 (https・ssh・.git 付き・cloud の proxy・大文字) によらず、owner/repo で当てる
#   - docs/ の外・下の階層の docs/・docs.md・docsite/、表に無い repo (owner だけ違う dotfiles も)・origin の無い repo・
#     git の外、ほかのツール (Read・Bash)、path の無い入力・cwd の無い相対パス・壊れた入力・空の入力・jq が無いときは
#     黙って通す
#   - いつも exit 0

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/docs-guard.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/docs-guard-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

# git は手元とサンドボックスの設定に依らせない
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

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

# new_repo <名前> [<origin の URL>] : ${work}/<名前> に repo を作り、パスを出す。URL が無ければ origin を付けない
new_repo() {
  local d="${work}/$1"
  git init -q "${d}"
  if [[ -n ${2:-} ]]; then
    git -C "${d}" remote add origin "$2"
  fi
  printf '%s' "${d}"
}

# input <tool> <path> [<cwd>] : PreToolUse の入力。NotebookEdit は notebook_path、ほかは file_path
input() {
  local key=file_path
  [[ $1 == NotebookEdit ]] && key=notebook_path
  jq -cn --arg t "$1" --arg k "${key}" --arg p "$2" --arg c "${3:-}" \
    '{session_id: "s", hook_event_name: "PreToolUse", tool_name: $t, tool_input: {($k): $p}}
     + (if $c == "" then {} else {cwd: $c} end)'
}

# run <入力> : stdout を ${work}/out に、exit code を ${work}/rc に残す
run() {
  printf '%s' "$1" | bash "${script}" >"${work}/out" 2>"${work}/err"
  echo $? >"${work}/rc"
}
reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "${work}/out" 2>/dev/null
}
silent() {
  [[ ! -s ${work}/out && $(cat "${work}/rc") == 0 ]]
}
# 止めたか: exit 0・1 行の JSON・hookEventName が PreToolUse・permissionDecision が deny
denied() {
  [[ $(cat "${work}/rc") == 0 ]] \
    && [[ $(wc -l <"${work}/out") == 1 ]] \
    && [[ $(jq -r '.hookSpecificOutput.hookEventName // empty' "${work}/out" 2>/dev/null) == PreToolUse ]] \
    && [[ $(jq -r '.hookSpecificOutput.permissionDecision // empty' "${work}/out" 2>/dev/null) == deny ]]
}
detail() {
  echo "rc=$(cat "${work}/rc") out=$(cat "${work}/out") err=$(cat "${work}/err")"
}

# expect_deny <説明> <入力> [<理由に含む文字>...]
expect_deny() {
  local desc=$1 in=$2 r s
  shift 2
  run "${in}"
  if ! denied; then
    ng "${desc}" "$(detail)"
    return
  fi
  r=$(reason)
  for s in "$@"; do
    if [[ ${r} != *"${s}"* ]]; then
      ng "${desc}" "理由に「${s}」が無い: ${r}"
      return
    fi
  done
  ok "${desc}"
}
# expect_silent <説明> <入力>
expect_silent() {
  run "$2"
  if silent; then
    ok "$1"
  else
    ng "$1" "$(detail)"
  fi
}

echo "== docs-guard.sh"

dot=$(new_repo dotfiles https://github.com/pollenjp/dotfiles)
mkdir -p "${dot}/docs/adr" "${dot}/nix/pkgs/x/docs"
printf 'x\n' >"${dot}/docs/adr/README.md"
git -C "${dot}" add docs
git -C "${dot}" commit -q -m init

# 1. 4 つのツールで docs/ の既存のファイル → 止め、書き先・取り方・回り込まないこと・CLAUDE.md を返す
for t in Write Edit MultiEdit NotebookEdit; do
  expect_deny "${t} で dotfiles の docs/ のファイルに書くと止める" "$(input "${t}" "${dot}/docs/adr/README.md")" \
    "pollenjp/dotfiles-private の docs/adr/README.md" "ghq" "cloud" "Bash" "CLAUDE.md"
done

# 2. docs/ がまだ無い repo の深い新しいファイル → 止め、その相対パスを書き先に出す
bare=$(new_repo dotfiles-bare https://github.com/pollenjp/dotfiles)
expect_deny "docs/ がまだ無い repo の深い新しいファイルでも止め、書き先に相対パスを出す" \
  "$(input Write "${bare}/docs/superpowers/specs/2026-10-25-x-design.md")" \
  "pollenjp/dotfiles-private の docs/superpowers/specs/2026-10-25-x-design.md"

# 3. worktree の docs/ → 止める
git -C "${dot}" worktree add -b wt "${work}/wt" >/dev/null 2>&1
expect_deny "worktree の docs/ でも止める" "$(input Write "${work}/wt/docs/new.md")" "pollenjp/dotfiles-private の docs/new.md"

# 4. symlink の祖先を通した path → 止める
ln -s "${dot}" "${work}/link"
expect_deny "symlink の祖先を通した path でも止める" "$(input Edit "${work}/link/docs/adr/README.md")" \
  "pollenjp/dotfiles-private の docs/adr/README.md"

# 5. origin の URL の形によらず owner/repo で当てる
i=0
for url in git@github.com:pollenjp/dotfiles.git https://github.com/pollenjp/dotfiles.git \
  ssh://git@github.com/pollenjp/dotfiles.git http://local_proxy@127.0.0.1:12345/git/pollenjp/dotfiles \
  https://github.com/PollenJP/Dotfiles/; do
  i=$((i + 1))
  r=$(new_repo "url-${i}" "${url}")
  expect_deny "origin が ${url} でも止める" "$(input Write "${r}/docs/a.md")" "pollenjp/dotfiles-private の docs/a.md"
done

# 6. 相対パスは cwd から解いて止める。cwd の無い相対パスは通す
expect_deny "相対パスは cwd から解いて止める" "$(input Write docs/a.md "${dot}")" "pollenjp/dotfiles-private の docs/a.md"
expect_silent "cwd の無い相対パスは通す" "$(input Write docs/a.md)"

# 7. docs/ の外・下の階層の docs/・docs.md・docsite/ → 通す
expect_silent "docs/ の外 (nix/x.sh) は通す" "$(input Write "${dot}/nix/x.sh")"
expect_silent "下の階層の docs/ (nix/pkgs/x/docs/a.md) は通す" "$(input Write "${dot}/nix/pkgs/x/docs/a.md")"
expect_silent "docs.md は通す" "$(input Write "${dot}/docs.md")"
expect_silent "docsite/ は通す" "$(input Write "${dot}/docsite/a.md")"

# 8. 表に無い repo (owner だけ違う dotfiles も)・origin の無い repo・git の外 → 通す
oss=$(new_repo oss https://github.com/someone/project)
expect_silent "表に無い repo の docs/ は通す" "$(input Write "${oss}/docs/a.md")"
other=$(new_repo other-dotfiles https://github.com/someone/dotfiles)
expect_silent "owner の違う dotfiles の docs/ は通す" "$(input Write "${other}/docs/a.md")"
noorigin=$(new_repo noorigin)
expect_silent "origin の無い repo の docs/ は通す" "$(input Write "${noorigin}/docs/a.md")"
mkdir -p "${work}/plain/docs"
expect_silent "git の外の docs/ は通す" "$(input Write "${work}/plain/docs/a.md")"

# 9. ほかのツール → 通す
expect_silent "Read は通す" "$(input Read "${dot}/docs/adr/README.md")"
expect_silent "Bash は通す" "$(jq -cn --arg c "echo x > ${dot}/docs/a.md" '{tool_name: "Bash", tool_input: {command: $c}, cwd: "/"}')"

# 10. path の無い入力・壊れた入力・空の入力 → 黙って exit 0
expect_silent "path の無い入力は通す" '{"tool_name": "Write", "tool_input": {}}'
run '{"tool_name": "Write", '
s1=$(silent && echo yes)
run ''
if [[ ${s1} == yes ]] && silent; then
  ok "壊れた入力・空の入力でも黙って exit 0"
else
  ng "壊れた入力・空の入力でも黙って exit 0" "s1=${s1} $(detail)"
fi

# 11. jq が無い → 黙って exit 0 (PATH には cat と git だけを置き、bash は絶対パスで起動する)
nojq="${work}/nojq"
mkdir -p "${nojq}"
ln -s "$(command -v cat)" "${nojq}/cat"
ln -s "$(command -v git)" "${nojq}/git"
bash_bin=$(command -v bash)
input Write "${dot}/docs/adr/README.md" >"${work}/in"
PATH="${nojq}" "${bash_bin}" "${script}" <"${work}/in" >"${work}/out" 2>"${work}/err"
echo $? >"${work}/rc"
if silent; then
  ok "jq が無いときは黙って exit 0"
else
  ng "jq が無いときは黙って exit 0" "$(detail)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
