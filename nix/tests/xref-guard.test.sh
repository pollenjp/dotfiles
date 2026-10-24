#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/xref-guard.sh の振る舞いを、合成した hook の入力・使い捨ての git の repo・偽の gh で確かめる。
#
#   bash nix/tests/xref-guard.test.sh [<xref-guard.sh のパス>]
#
# flake の checks (xref-guard-test) が Nix のサンドボックスで流す。使うのは bash・jq・git・coreutils と stdenv の awk
# だけ。gh は、公開範囲を FAKE_GH_VIS から答え、呼ばれた引数を書き留める偽物で代える (ネットワークに出ない)。repo の
# remote の URL は github.com にするが push はしない (hook は打つ前に止めるか通すかを決めるだけ)。remote-tracking ref は
# update-ref で作る。手元 (Claude の会話の中) で流しても同じになるよう、始めに GIT_CONFIG_*・GH_*・PJP_ALLOW_XREF を外す。
#
# ## 確かめること
#
#   gh (pr create・edit・comment・review・merge と issue create・edit・comment):
#   - タイトル (-t・--title・--title=・-tX・-t=X) の参照は backquote で囲んでいても止める
#   - 本文 (-b・--body・-F・--body-file) は code block (``` と ~~~) と inline code の外の参照だけで止め、[`文`](URL) の
#     リンクの URL は止める。日本語の直後の参照も拾う。止めた文に行の番号と参照と直し方を書く
#   - "$(cat <<'EOF' … EOF)" の本文は、対にならない ) があっても最後まで読む。--body-file (cd の先からの相対も)・
#     -F - の heredoc・パイプの前の cat <<EOF・< file・$(cat file)・前の BODY=… を "$BODY" で渡したものも本文として読む
#   - gh pr merge の件名と本文は backquote の中も数え、コメント・review の本文は本文と同じに数える
#   - 拾う形は ticket.py と同じ (owner/repo#番号・owner/repo@sha・github.com の issues・pull・discussions・commit の URL)。
#     同じ repo (大文字小文字は問わない)・#番号・似た形 (foo.bar/baz#1・owner/repo#12abc・6 桁の sha) は通し、gh を呼ばない
#   - 公開範囲は -R・引数の PR の URL・GH_REPO の repo を、無ければ dir の repo を gh で引く。PRIVATE・INTERNAL は通し、
#     PUBLIC と、gh が落ちたときは止める
#   - PJP_ALLOW_XREF=1 (頭と env の引数) は通し、ほかの値は通さない。包むコマンド (timeout・bash -c) の中も見る
#   - echo・grep の引数・引用符の中の gh、gh pr view・list は見ない
#
#   - Bash 以外・壊れた入力・空の入力は黙り、いつも exit 0。止める出力は permissionDecision が deny の 1 行の JSON だけ

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/xref-guard.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/xref-guard-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

# compgen は readline の無い bash (Nix のサンドボックスの bash) に無いので、名前の頭で引く形を使う
for v in ${!GIT_CONFIG_@} ${!GH_@} PJP_ALLOW_XREF; do
  unset "${v}"
done
export HOME="${work}/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${work}/empty.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "${HOME}" "${work}/bin"
: >"${GIT_CONFIG_GLOBAL}"

# 偽の gh: gh repo view [<[host/]owner/repo>] --json … だけに答える。公開範囲は FAKE_GH_VIS (owner/repo=VIS を空白で
# 区切る。名前は小文字)、引数の無いときの repo は FAKE_GH_DEFAULT。FAKE_GH_MODE=fail は未ログインの形で落ちる
cat >"${work}/bin/gh" <<EOF
#!${BASH}
printf '%s\n' "\$*" >>"${work}/gh.log"
[[ \$1 == repo && \$2 == view ]] || { echo "fake gh: \$*" >&2; exit 2; }
if [[ \${FAKE_GH_MODE:-} == fail ]]; then
  echo 'To get started with GitHub CLI, please run:  gh auth login' >&2
  exit 4
fi
shift 2
target=""
[[ \${1-} == --json ]] || target=\$1
[[ -n \${target} ]] || target=\${FAKE_GH_DEFAULT:-}
case \${target} in
  github.com/*) target=\${target#github.com/} ;;
  */*/*) echo "none of the git remotes configured for this repository point to a known GitHub host" >&2; exit 1 ;;
esac
want=\${target,,}
for kv in \${FAKE_GH_VIS:-}; do
  if [[ \${kv%%=*} == "\${want}" ]]; then
    printf '{"nameWithOwner":"%s","visibility":"%s"}\n' "\${target}" "\${kv#*=}"
    exit 0
  fi
done
echo "GraphQL: Could not resolve to a Repository with the name '\${target}'. (repository)" >&2
exit 1
EOF
chmod +x "${work}/bin/gh"
export PATH="${work}/bin:${PATH}"
export FAKE_GH_VIS="pollenjp/dotfiles=PUBLIC pollenjp/secret=PRIVATE acme/inner=INTERNAL acme/open=PUBLIC"
export FAKE_GH_DEFAULT=pollenjp/dotfiles

# 作業する repo (origin は public な pollenjp/dotfiles。push はしない)
repo="${work}/repo"
git init -q -b main "${repo}"
git -C "${repo}" remote add origin https://github.com/pollenjp/dotfiles.git
git -C "${repo}" commit -q --allow-empty -m "init"
git -C "${repo}" update-ref refs/remotes/origin/main HEAD
mkdir -p "${repo}/sub"

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

# pre <コマンド> [<cwd>] [NAME=VALUE…]: PreToolUse の入力で流す (NAME=VALUE は hook の env に足す)。gh.log は空にする
pre() {
  local cmd=$1 cwd=${2:-${repo}}
  shift
  (($# > 0)) && shift
  jq -cn --arg c "${cmd}" --arg d "${cwd}" \
    '{session_id: "s", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c, description: "d"}, cwd: $d}' \
    >"${work}/in"
  : >"${work}/gh.log"
  env "$@" bash "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
}
silent() {
  [[ ! -s ${work}/stdout && $(cat "${work}/rc") == 0 ]]
}
# 止めたか: exit 0・1 行の JSON・PreToolUse の deny と理由だけ
denied_shape='[["hookSpecificOutput"],["hookEventName","permissionDecision","permissionDecisionReason"],"PreToolUse","deny"]'
denied() {
  local got
  got=$(jq -c '[keys, (.hookSpecificOutput | keys), .hookSpecificOutput.hookEventName, .hookSpecificOutput.permissionDecision]' \
    "${work}/stdout" 2>/dev/null)
  [[ $(cat "${work}/rc") == 0 && $(wc -l <"${work}/stdout") == 1 && ${got} == "${denied_shape}" ]]
}
reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "${work}/stdout" 2>/dev/null
}
gh_calls() {
  wc -l <"${work}/gh.log"
}
detail() {
  echo "rc=$(cat "${work}/rc") stdout=$(cat "${work}/stdout") stderr=$(cat "${work}/stderr") gh=$(tr '\n' ';' <"${work}/gh.log")"
}
show() {
  local s=${1//$'\n'/⏎}
  printf '%s' "${s:0:100}"
}

# expect_deny <コマンド> [<cwd>] [NAME=VALUE…]: 止める
expect_deny() {
  pre "$@"
  if denied; then
    ok "止める: $(show "$1")"
  else
    ng "止める: $(show "$1")" "$(detail)"
  fi
}
# expect_allow <コマンド> [<cwd>] [NAME=VALUE…]: 黙って通し、gh を呼ばない
expect_allow() {
  pre "$@"
  if silent && [[ $(gh_calls) == 0 ]]; then
    ok "通す: $(show "$1")"
  else
    ng "通す: $(show "$1")" "$(detail)"
  fi
}
# expect_allow_after_gh <コマンド> [<cwd>] [NAME=VALUE…]: 公開範囲を引いてから通す
expect_allow_after_gh() {
  pre "$@"
  if silent && [[ $(gh_calls) -ge 1 ]]; then
    ok "公開範囲を引いて通す: $(show "$1")"
  else
    ng "公開範囲を引いて通す: $(show "$1")" "$(detail)"
  fi
}
# expect_reason <説明> <コマンド> <cwd> <理由に含む文>…: 止めて、理由にどの文も含む
expect_reason() {
  local what=$1 cmd=$2 cwd=$3 r s missing=""
  shift 3
  pre "${cmd}" "${cwd}"
  r=$(reason)
  for s in "$@"; do
    [[ ${r} == *"${s}"* ]] || missing+="「${s}」"
  done
  if denied && [[ -z ${missing} ]]; then
    ok "${what}"
  else
    ng "${what}" "無い: ${missing} / $(detail)"
  fi
}

ref='NixOS/nixpkgs#577218'

echo "== xref-guard.sh: gh のタイトルと本文"

heredoc_body() {
  # shellcheck disable=SC2016 # Bash に打たせるコマンドの文字そのもの ($( ) は hook が読む)
  printf 'gh pr create --title "x" --body "$(cat <<'"'"'EOF'"'"'\n%s\nEOF\n)"' "$1"
}

expect_reason "本文の参照: 行の番号・参照・公開範囲・直し方・通す口を返す" \
  "$(heredoc_body $'## 概要\n- '"${ref}"' を待つ')" "${repo}" \
  "本文の 2 行目 (backquote の外): ${ref}" "pollenjp/dotfiles (public な repo)" "gh pr create" \
  "backquote で囲む" "PJP_ALLOW_XREF=1" "自分の判断では付けない"
if [[ $(gh_calls) == 1 && $(cat "${work}/gh.log") == "repo view --json nameWithOwner,visibility" ]]; then
  ok "repo を渡していない gh は、dir で gh repo view を 1 回だけ引く"
else
  ng "repo を渡していない gh は、dir で gh repo view を 1 回だけ引く" "$(detail)"
fi
expect_allow "$(heredoc_body '- `'"${ref}"'` を待つ')"
expect_allow "$(heredoc_body $'```\n'"${ref}"$'\n```')"
expect_allow "$(heredoc_body $'~~~sh\n'"${ref}"$'\n~~~')"
# shellcheck disable=SC2016 # 本文の Markdown の backquote そのもの
expect_allow "$(heredoc_body $'``a `'"${ref}"'` b``')"
# shellcheck disable=SC2016 # 本文の Markdown の backquote そのもの
expect_deny "$(heredoc_body '[`x`](https://github.com/NixOS/nixpkgs/pull/577218)')"
expect_deny "$(heredoc_body "これは${ref}を待つ")"
expect_deny "$(heredoc_body $'1) 先に\n2) '"${ref}"' を待つ')"
expect_deny "$(heredoc_body $'```\nx\n```\n'"${ref}")"
expect_deny "$(heredoc_body $'`閉じない\n\n'"${ref}"' `')"
expect_reason "対にならない ) の後ろの行も数える" "$(heredoc_body $'a)\nb)\n'"${ref}")" "${repo}" "本文の 3 行目"

for body in \
  "https://github.com/NixOS/nixpkgs/pull/577218" \
  "https://github.com/NixOS/nixpkgs/issues/1" \
  "https://GitHub.com/NixOS/nixpkgs/discussions/2" \
  "https://www.github.com/NixOS/nixpkgs/commit/abcdef1" \
  "NixOS/nixpkgs@abcdef1234" \
  "acme/inner#3"; do
  expect_deny "gh pr create --title x --body '${body}'"
done
for body in "foo.bar/baz#1" "owner/repo#12abc" "owner/repo@abcde1" "#12" "pollenjp/dotfiles#3" "PollenJP/Dotfiles#3" \
  "https://github.com/pollenjp/dotfiles/pull/1" "https://github.com/NixOS/nixpkgs" "a/b/c#1"; do
  expect_allow "gh pr create --title x --body '${body}'"
done

expect_reason "タイトルの参照は backquote の中も数える" "gh pr create --title 'x \`${ref}\`' --body y" "${repo}" \
  "タイトル: ${ref}" "タイトルからは消す"
expect_deny "gh pr create -t '${ref}' -b y"
expect_deny "gh pr create --title='${ref}' --body y"
expect_deny "gh pr create -t${ref} --body y"
expect_deny "gh pr create -t=${ref} --body y"
expect_deny "gh pr create --body y --title ${ref}"
expect_deny "gh pr create -db '${ref}' --title x"
expect_allow "gh pr create --title 'x' --body 'y' --head '${ref}'"
expect_allow "gh pr create -t x -b y -l '${ref}'"

echo "== xref-guard.sh: 本文の出どころ"

printf '## 概要\n\n%s を待つ\n' "${ref}" >"${repo}/body.md"
printf 'ok\n' >"${repo}/sub/body.md"
printf '%s\n' "${ref}" >"${repo}/sub/ref.md"
expect_reason "--body-file の中身を読む" "gh pr create --title x --body-file body.md" "${repo}" "本文の 3 行目 (backquote の外): ${ref}"
expect_deny "gh pr create -t x -F ${repo}/body.md"
expect_deny "gh pr create -t x --body-file=body.md"
expect_allow "cd sub && gh pr create -t x -F body.md"
expect_deny "cd sub && gh pr create -t x -F ref.md"
expect_deny "gh pr create -t x -F - <<'EOF'
${ref}
EOF"
expect_deny "cat <<'EOF' | gh pr create -t x -F -
${ref}
EOF"
expect_deny "gh pr create -t x -F - < body.md"
expect_deny "gh pr create -t x -F - <<< '${ref}'"
expect_deny "printf '%s\\n' '${ref}' | gh pr create -t x -F -"
expect_deny "gh pr create -t x --body \"\$(cat body.md)\""
expect_deny "gh pr create -t x --body \"\$(< body.md)\""
expect_allow "gh pr create -t x --body \"\$(cat sub/body.md)\""
expect_deny "BODY=\$(cat <<'EOF'
${ref}
EOF
)
gh pr create --title x --body \"\$BODY\""
expect_deny "export BODY='${ref}'; gh pr create --title x --body \"\${BODY}\""
expect_deny "gh pr create --title x --body \"\$(printf '%s' '${ref}')\""

echo "== xref-guard.sh: gh のほかのコマンド"

expect_reason "gh pr comment の本文" "gh pr comment 12 --body 'see ${ref}'" "${repo}" "コメントの 1 行目 (backquote の外): ${ref}"
expect_allow "gh pr comment 12 --body 'see \`${ref}\`'"
expect_deny "gh issue create -t '${ref}' -b y"
expect_deny "gh issue create -t x -b '${ref}'"
expect_deny "gh issue comment 3 -b '${ref}'"
expect_deny "gh issue edit 3 --title '${ref}'"
expect_deny "gh issue edit 3 --body '${ref}'"
expect_deny "gh pr edit 3 --body '${ref}'"
expect_deny "gh pr review 3 --comment -b '${ref}'"
expect_reason "gh pr merge の本文は backquote の中も数える" "gh pr merge 3 --squash --subject x --body 'see \`${ref}\`'" "${repo}" \
  "merge の commit の本文の 1 行目: ${ref}"
expect_deny "gh pr merge 3 -s -t '${ref}'"
expect_allow "gh pr view 3"
expect_allow "gh pr list --search '${ref}'"
expect_allow "gh issue view 3 --comments"
expect_allow "echo gh pr create --title '${ref}'"
expect_allow "grep 'gh pr create --title ${ref}' notes.md"
expect_allow "echo 'gh pr create --body ${ref}' >/dev/null"

echo "== xref-guard.sh: 公開範囲"

expect_allow_after_gh "gh pr create -R pollenjp/secret --title '${ref}' --body y"
if [[ $(cat "${work}/gh.log") == "repo view github.com/pollenjp/secret --json nameWithOwner,visibility" ]]; then
  ok "-R の repo を github.com を付けて引く"
else
  ng "-R の repo を github.com を付けて引く" "$(detail)"
fi
expect_allow_after_gh "gh pr create --repo acme/inner --title '${ref}' --body y"
expect_allow_after_gh "gh pr create --repo=pollenjp/secret --title '${ref}' --body y"
expect_allow_after_gh "gh pr edit https://github.com/pollenjp/secret/pull/3 --body '${ref}'"
expect_allow_after_gh "GH_REPO=pollenjp/secret gh pr create --title '${ref}' --body y"
expect_deny "gh pr create -R acme/open --title 'pollenjp/dotfiles#1' --body y"
expect_allow "gh pr create -R acme/open --title 'acme/open#1' --body y"
pre "gh pr create --title '${ref}' --body y" "${repo}" FAKE_GH_MODE=fail
if denied && [[ $(reason) == *"公開範囲を確かめられない"* && $(reason) == *"gh auth login"* ]]; then
  ok "gh が落ちたら止め、確かめられないわけを書く"
else
  ng "gh が落ちたら止め、確かめられないわけを書く" "$(detail)"
fi
# gh だけが無い PATH (今の PATH の dir の中身を、gh を除いて 1 つの dir に張る)
mkdir -p "${work}/nogh"
IFS=: read -r -a path_dirs <<<"${PATH}"
for d in "${path_dirs[@]}"; do
  for f in "${d}"/*; do
    [[ -x ${f} && ${f##*/} != gh && ! -e ${work}/nogh/${f##*/} ]] && ln -s "${f}" "${work}/nogh/${f##*/}"
  done
done
pre "gh pr create --title '${ref}' --body y" "${repo}" PATH="${work}/nogh"
if denied && [[ $(reason) == *"gh が見つからない"* ]]; then
  ok "gh が無ければ止め、見つからないと書く"
else
  ng "gh が無ければ止め、見つからないと書く" "$(detail)"
fi

echo "== xref-guard.sh: 通す口と包むコマンド"

expect_allow "PJP_ALLOW_XREF=1 gh pr create --title '${ref}' --body y"
expect_allow "env PJP_ALLOW_XREF=1 gh pr create --title '${ref}' --body y"
expect_deny "PJP_ALLOW_XREF=0 gh pr create --title '${ref}' --body y"
expect_deny "PJP_ALLOW_XREF=1 true && gh pr create --title '${ref}' --body y"
expect_deny "timeout 60 gh pr create --title '${ref}' --body y"
expect_deny "bash -c \"gh pr create --title '${ref}' --body y\""
expect_deny "cd sub && gh pr create --title '${ref}' --body y"

echo "== xref-guard.sh: git push"

# new_repo <名前> [<origin の URL>]: init の commit を origin/main に置き、branch feat に移った repo を作る
new_repo() {
  local r="${work}/$1"
  git init -q -b main "${r}"
  git -C "${r}" remote add origin "${2:-https://github.com/pollenjp/dotfiles.git}"
  git -C "${r}" commit -q --allow-empty -m "init"
  git -C "${r}" update-ref refs/remotes/origin/main HEAD
  git -C "${r}" switch -q -c feat
  printf '%s' "${r}"
}
# commit_in <repo> <message>
commit_in() {
  git -C "$1" commit -q --allow-empty -m "$2"
}

r=$(new_repo p1)
commit_in "${r}" "feat: ok"
commit_in "${r}" $'feat: x\n\nmise は nixpkgs (NixOS/nixpkgs#577218) を待つ'
sha=$(git -C "${r}" rev-parse --short=7 HEAD)
expect_reason "押す commit の参照: commit・行・参照・公開範囲・直し方を返す" "git push -u origin feat" "${r}" \
  "git push → pollenjp/dotfiles (public な repo):" "commit ${sha}「feat: x」の 3 行目: ${ref}" \
  "「nixpkgs の PR 577218」" "commit の message は Markdown ではないので、backquote で囲んでも跡が付く" \
  "push し直す (同じコマンドで作る commit なら" "git commit --amend" "PJP_ALLOW_XREF=1"
if [[ $(cat "${work}/gh.log") == "repo view github.com/pollenjp/dotfiles --json nameWithOwner,visibility" ]]; then
  ok "push 先の repo を github.com を付けて引く"
else
  ng "push 先の repo を github.com を付けて引く" "$(detail)"
fi
for cmd in "git push" "git push origin" "git push origin HEAD" "git push origin HEAD:refs/heads/x" "git push origin +feat:feat" \
  "git push origin $(git -C "${r}" rev-parse HEAD):refs/heads/x" "git push --force-with-lease origin feat" "git push -fu origin feat" \
  "git -c push.default=current push" "git -C ${r} push" "cd ${r} && git push" "timeout 60 git push" "env FOO=1 git push" \
  "bash -c 'git push origin feat'" "git push --all origin" "git push https://github.com/pollenjp/dotfiles.git feat" \
  "git gh push"; do
  expect_deny "${cmd}" "${r}"
done
pre "git -C ${r} push" "${work}"
if denied; then ok "git -C の先の repo を見る (cwd は repo の外)"; else ng "git -C の先の repo を見る (cwd は repo の外)" "$(detail)"; fi
for cmd in "git push origin main" "git push origin :feat" "git push origin --delete feat" "git push -d origin feat" \
  "git push --dry-run" "git push -n origin feat" "git push --help" "PJP_ALLOW_XREF=1 git push" \
  "git stash push -m x" "git log --grep push" "echo git push" "git push ../bare.git feat" "git push /tmp/bare.git feat"; do
  expect_allow "${cmd}" "${r}"
done
git -C "${r}" tag v1 HEAD
expect_deny "git push origin tag v1" "${r}"
expect_deny "git push origin --tags" "${r}"

r=$(new_repo p2)
commit_in "${r}" "fix: x (\`${ref}\`)"
expect_deny "git push" "${r}"
git -C "${r}" reset -q --hard origin/main
for body in "https://github.com/NixOS/nixpkgs/pull/577218" "NixOS/nixpkgs@abcdef1234" "https://github.com/acme/inner/issues/1"; do
  commit_in "${r}" "fix: ${body}"
  expect_deny "git push" "${r}"
  git -C "${r}" reset -q --hard HEAD~1
done
git -C "${r}" reset -q --hard origin/main
commit_in "${r}" $'fix: same repo\n\nCloses #12 (pollenjp/dotfiles#3, PollenJP/Dotfiles#4)'
expect_allow "git push" "${r}"
git -C "${r}" update-ref refs/remotes/origin/feat HEAD
commit_in "${r}" "fix: ${ref}"
git -C "${r}" update-ref refs/remotes/origin/feat HEAD
expect_allow "git push" "${r}"

# fork の clone: upstream の remote-tracking ref にある commit は数えない
r=$(new_repo p3)
git -C "${r}" remote add upstream https://github.com/NixOS/nixpkgs.git
commit_in "${r}" "upstream: fix ${ref}"
git -C "${r}" update-ref refs/remotes/upstream/master HEAD
commit_in "${r}" "feat: mine"
expect_allow "git push origin feat" "${r}"

# 押す先: remote.pushDefault・pushurl・手元の path・private・github.com でない host
r=$(new_repo p4)
commit_in "${r}" "fix: ${ref}"
git -C "${r}" remote add inner https://github.com/acme/inner.git
git -C "${r}" config remote.pushDefault inner
expect_allow_after_gh "git push" "${r}"
git -C "${r}" config --unset remote.pushDefault
git -C "${r}" config remote.origin.pushurl https://github.com/pollenjp/secret.git
expect_allow_after_gh "git push origin feat" "${r}"
git -C "${r}" config --unset remote.origin.pushurl
git -C "${r}" remote add backup "${work}/backup.git"
expect_allow "git push backup feat" "${r}"
git -C "${r}" remote set-url origin git@github.com:pollenjp/secret.git
expect_allow_after_gh "git push origin feat" "${r}"
git -C "${r}" remote set-url origin https://gitlab.com/pollenjp/dotfiles.git
expect_reason "github.com でない host は公開範囲を確かめられないので止める" "git push origin feat" "${r}" \
  "git push → pollenjp/dotfiles (公開範囲を確かめられない: gh: "

# 同じコマンドで push より前に作る commit の message
r=$(new_repo p5)
commit_in "${r}" "feat: ok"
expect_reason "git commit -m の message も数える" "git commit -q --allow-empty -m 'fix: x ${ref}' && git push" "${r}" \
  "これから作る commit (git commit) の 1 行目: ${ref}"
expect_deny "git commit -am 'fix: x' -m 'see ${ref}' && git push origin feat" "${r}"
expect_deny "git commit --message='${ref}'; git push" "${r}"
expect_deny "git commit -m \"\$(cat <<'EOF'
fix: x

see ${ref}
EOF
)\" && git push" "${r}"
expect_deny "git commit -F - <<'EOF' && git push
${ref}
EOF" "${r}"
printf 'fix: x\n\n%s\n' "${ref}" >"${r}/msg.txt"
expect_deny "git commit -F msg.txt && git push" "${r}"
expect_allow "git commit -m 'fix: ok' && git push" "${r}"
expect_allow "git commit -m 'fix: ${ref}'" "${r}"
expect_allow "PJP_ALLOW_XREF=1 git commit -m 'fix: ${ref}' && git push" "${r}"

# 見つけた参照は 20 件まで並べ、残りは件数だけ
r=$(new_repo p6)
for i in $(seq 1 25); do
  commit_in "${r}" "fix: acme/open#${i}"
done
expect_reason "21 件目からは件数だけ書く" "git push" "${r}" "- ほか 5 件"

echo "== xref-guard.sh: 長いコマンド"

# 64 KB (Nix のサンドボックスの stdenv には gawk がある) を超えるコマンドは中を読まず、参照か git … push があれば止める
long=$(printf 'あいうえおかきくけこ%.0s' $(seq 1 2500))
expect_reason "長いコマンドに参照があれば、ファイルにするよう返して止める" \
  "gh pr create --title x --body '${long} ${ref}'" "${repo}" "コマンドが長すぎて" "${ref}" "--body-file"
expect_reason "長いコマンドに git … push があれば止める" "cat >/dev/null <<'EOF'
${long}
EOF
git push" "${repo}" "コマンドが長すぎて" "git push は別のコマンドで打つ"
expect_allow "gh pr create --title x --body '${long}'"
expect_allow "PJP_ALLOW_XREF=1 gh pr create --title x --body '${long} ${ref}'"
expect_allow_after_gh "gh pr create --title x --body '${long} ${ref}'" "${repo}" FAKE_GH_DEFAULT=pollenjp/secret

echo "== xref-guard.sh: 黙るとき"

for in in '' 'not json' '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"gh pr create --title NixOS/nixpkgs#1"}}'; do
  printf '%s' "${in}" | bash "${script}" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
  if silent; then
    ok "黙る: $(show "${in:-(空)}")"
  else
    ng "黙る: $(show "${in:-(空)}")" "$(detail)"
  fi
done

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
