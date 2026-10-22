#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/ssh-agent-notice.sh の振る舞いを、合成した hook の入力で確かめる。
#
#   bash nix/tests/ssh-agent-notice.test.sh [<ssh-agent-notice.sh のパス>]
#
# flake の checks (ssh-agent-notice-test) が Nix のサンドボックスで流す。使うのは bash・jq・git・coreutils と
# stdenv の awk だけ。HOME・XDG_STATE_HOME は使い捨ての dir に向け、git の設定は GIT_CONFIG_GLOBAL と
# GIT_CONFIG_COUNT で場面ごとに渡す。時刻は TZ=UTC0 で比べる。手元 (Claude の会話の中) で流しても同じになるよう、
# 始めに GIT_CONFIG_*・HERDR_*・SSH_AUTH_SOCK を外す。
#
# ## 確かめること
#
#   打つ前 (PreToolUse):
#   - ssh・scp・rsync の <host>:・nixos-rebuild の --target-host・nix の ssh://・ssh-keygen -Y sign・ssh-add -T を、
#     包むコマンド (timeout・sudo・env・bash -c・nix develop -c)・$( )・<( )・for の中でも当て、種類を添えて知らせる
#   - 引用符の中・heredoc の本文・コメント・grep や echo の引数・ssh -G・command -v ssh・ローカルの rsync には当てない
#   - git は署名するときだけ当てる (env の commit.gpgsign=false は外れ・global の true と -c と -S は当たり・
#     --no-gpg-sign と rebase --abort は外れ・tag は作るときだけ)
#   - git の相手が ssh の remote (cd と -C の先も・clone の URL も) なら当て、insteadOf で https になれば外す
#   - 知らせる文は「🔑 … (<種類>): <頭> — 承認の画面は <接続>」の 1 行の JSON だけで、頭は包むコマンドを外して 80 文字で切る
#   - 承認の画面の接続は、pjp-agent-link の記録の時刻と値・記録が無ければファイルの時刻・より新しい接続・手元の agent・
#     先が無い・SSH_AUTH_SOCK が無い、の形で出し、コマンドの頭の SSH_AUTH_SOCK= が env より勝つ
#   - Bash 以外・壊れた入力・空の入力・jq が無いときは黙り、いつも exit 0

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/ssh-agent-notice.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/ssh-agent-notice-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

while IFS= read -r v; do
  case ${v} in
    GIT_CONFIG_* | HERDR_* | SSH_AUTH_SOCK) unset "${v}" ;;
  esac
done < <(compgen -e)
export HOME="${work}/home" XDG_STATE_HOME="${work}/state" TZ=UTC0 GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${work}/empty.gitconfig"
mkdir -p "${HOME}" "${XDG_STATE_HOME}"
: >"${GIT_CONFIG_GLOBAL}"

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

# pre <コマンド> [<cwd>] [NAME=VALUE…]: PreToolUse の入力で流す (NAME=VALUE は hook の env に足す)
pre() {
  local cmd=$1 cwd=${2:-${work}}
  shift
  (($# > 0)) && shift
  jq -cn --arg c "${cmd}" --arg d "${cwd}" \
    '{session_id: "s", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c, description: "d"}, cwd: $d}' \
    >"${work}/in"
  env "$@" bash "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
}
notice() {
  jq -r '.systemMessage // empty' "${work}/stdout" 2>/dev/null
}
silent() {
  [[ ! -s ${work}/stdout && $(cat "${work}/rc") == 0 ]]
}
# 知らせたか: exit 0・1 行の JSON・キーは systemMessage だけ
noticed() {
  [[ $(cat "${work}/rc") == 0 ]] \
    && [[ $(wc -l <"${work}/stdout") == 1 ]] \
    && [[ $(jq -c 'keys' "${work}/stdout" 2>/dev/null) == '["systemMessage"]' ]]
}
detail() {
  echo "rc=$(cat "${work}/rc") stdout=$(cat "${work}/stdout") stderr=$(cat "${work}/stderr")"
}

title='🔑 1Password の承認が出るかも'

# expect_hit <種類> <コマンド> [<cwd>] [NAME=VALUE…]
expect_hit() {
  local kind=$1
  shift
  pre "$@"
  if noticed && [[ $(notice) == "${title} (${kind}): "* ]]; then
    ok "当てる (${kind}): ${1//$'\n'/⏎}"
  else
    ng "当てる (${kind}): ${1//$'\n'/⏎}" "$(detail)"
  fi
}
# expect_miss <コマンド> [<cwd>] [NAME=VALUE…]
expect_miss() {
  pre "$@"
  if silent; then
    ok "当てない: ${1//$'\n'/⏎}"
  else
    ng "当てない: ${1//$'\n'/⏎}" "$(detail)"
  fi
}
# expect_notice <説明> <期待する文> <コマンド> [<cwd>] [NAME=VALUE…]
expect_notice() {
  local what=$1 want=$2
  shift 2
  pre "$@"
  if noticed && [[ $(notice) == "${want}" ]]; then
    ok "${what}"
  else
    ng "${what}" "want=${want}"$'\n'"$(detail)"
  fi
}

echo "== ssh-agent-notice.sh: 打つ前 (PreToolUse)"

# --- 当てるもの
expect_hit "ssh の接続" 'ssh h true'
expect_hit "ssh の接続" 'scp a h:b'
expect_hit "ssh の接続" 'timeout 5 ssh h true'
expect_hit "ssh の接続" 'sudo -u x ssh h true'
expect_hit "ssh の接続" 'env A=1 ssh h true'
expect_hit "ssh の接続" "bash -c 'ssh h true'"
expect_hit "ssh の接続" 'nix develop -c ssh h true'
# shellcheck disable=SC2016 # hook に渡すコマンドの文字
expect_hit "ssh の接続" 'x=$(ssh h cat f); echo "${x}"'
expect_hit "ssh の接続" 'diff <(ssh h cat a) b'
# shellcheck disable=SC2016 # hook に渡すコマンドの文字
expect_hit "ssh の接続" 'echo "uptime: $(ssh h uptime)"'
# shellcheck disable=SC2016 # hook に渡すコマンドの文字
expect_hit "ssh の接続" 'echo "uptime: `ssh h uptime`"'
# shellcheck disable=SC2016 # hook に渡すコマンドの文字
expect_hit "ssh の接続" 'for h in a b; do ssh "$h" true; done'
expect_hit "ssh の接続" $'cat <<EOF | ssh h bash\necho hi\nEOF'
expect_hit "ssh の接続" 'rsync -a d/ h:d/'
expect_hit "ssh の接続" 'nixos-rebuild switch --flake .#x --target-host root@h'
expect_hit "ssh の接続" 'nix copy --to ssh://h .#x'
expect_hit "署名" 'ssh-keygen -Y sign -f k -n git f'
expect_hit "署名" 'ssh-add -T k.pub'

# --- 当てないもの
expect_miss 'ls -la'
expect_miss 'echo "ssh h"'
expect_miss "printf '%s\n' 'ssh h'"
expect_miss $'cat <<\'EOF\' >notes.md\nssh h true\nEOF'
expect_miss 'grep -rn ssh nix/'
expect_miss 'echo ssh'
expect_miss 'ls ~/.ssh'
expect_miss 'ssh -G h'
expect_miss 'command -v ssh'
expect_miss 'man ssh'
expect_miss '# ssh h'
expect_miss 'rsync -a a/ b/'
expect_miss 'rsync -a rsync://h/m d/'
expect_miss 'nixos-rebuild build --flake .#x'

# --- git の署名
signing="${work}/signing.gitconfig"
printf '[commit]\n\tgpgsign = true\n[tag]\n\tgpgsign = true\n' >"${signing}"
off=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false)
expect_miss 'git commit -m x' "${work}" "GIT_CONFIG_GLOBAL=${signing}" "${off[@]}"
expect_hit "署名" 'git commit -m x' "${work}" "GIT_CONFIG_GLOBAL=${signing}"
expect_hit "署名" 'git -c commit.gpgsign=true commit -m x' "${work}" "${off[@]}"
expect_hit "署名" 'git commit -S -m "fix ssh"'
expect_miss 'git commit -m "fix ssh"'
expect_miss 'git commit --no-gpg-sign -m x' "${work}" "GIT_CONFIG_GLOBAL=${signing}"
expect_miss 'git rebase --abort' "${work}" "GIT_CONFIG_GLOBAL=${signing}"
expect_hit "署名" 'git rebase --continue' "${work}" "GIT_CONFIG_GLOBAL=${signing}"
expect_hit "署名" 'git tag -s v1 -m v1'
expect_hit "署名" 'git tag v1' "${work}" "GIT_CONFIG_GLOBAL=${signing}"
expect_miss 'git tag v1'
expect_miss 'git tag -l' "${work}" "GIT_CONFIG_GLOBAL=${signing}"
expect_miss 'git tag -d v1' "${work}" "GIT_CONFIG_GLOBAL=${signing}"
expect_miss 'git status' "${work}" "GIT_CONFIG_GLOBAL=${signing}"

# --- git の相手が ssh の remote
git init -q "${work}/sshrepo"
git -C "${work}/sshrepo" remote add origin git@example.invalid:x/y.git
git init -q "${work}/httpsrepo"
git -C "${work}/httpsrepo" remote add origin https://example.invalid/x/y.git
expect_hit "ssh の接続" 'git push' "${work}/sshrepo"
expect_hit "ssh の接続" "cd ${work}/sshrepo && git push origin HEAD"
expect_hit "ssh の接続" "git -C ${work}/sshrepo fetch"
expect_hit "ssh の接続" 'git fetch --all' "${work}/sshrepo"
expect_hit "ssh の接続" 'git clone ssh://h/x.git'
expect_miss 'git clone https://example.invalid/x.git'
expect_miss 'git push' "${work}/httpsrepo"
expect_miss 'git push' "${work}/sshrepo" GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=url.https://example.invalid/.insteadOf GIT_CONFIG_VALUE_0=git@example.invalid:

# --- 知らせる文: 頭は包むコマンドを外し、80 文字で切る
long="ssh h $(printf 'x%.0s' {1..100})"
expect_notice "頭は包むコマンドを外したもの" \
  "${title} (ssh の接続): ssh h true — 承認の画面は出ない (SSH_AUTH_SOCK が無い)" 'timeout 5 ssh h true'
expect_notice "頭は 80 文字で切る" \
  "${title} (ssh の接続): ${long:0:79}… — 承認の画面は出ない (SSH_AUTH_SOCK が無い)" "${long}"

# --- 承認の画面の接続
agent="${HOME}/.ssh/agent"
conn="${HOME}/.local/state/pjp-agent-link/conn"
mkdir -p "${agent}" "${conn}" "${HOME}/.1password"
# 10/22 08:59 と 11:54 (UTC)
t0859=1792659540
t1154=1792670040
record() {
  printf 'sock=%s\nclient=%s\nopened=%s000000000\n' "${agent}/$1" "$2" "$3" >"${conn}/$1"
}
: >"${agent}/s.k.sshd.A"
record s.k.sshd.A polle@pjp-raiden "${t0859}"
ln -s "${agent}/s.k.sshd.A" "${HOME}/.ssh/agent.a.sock"
expect_notice "記録のある接続は、記録の時刻と値で出す" \
  "${title} (ssh の接続): ssh h — 承認の画面は 10/22 08:59 に polle@pjp-raiden から入った接続の端末に出る" \
  'ssh h' "${work}" "SSH_AUTH_SOCK=${HOME}/.ssh/agent.a.sock"

mkdir -p "${HOME}/b/agent"
: >"${HOME}/b/agent/s.k.sshd.B"
touch -d "@${t0859}" "${HOME}/b/agent/s.k.sshd.B"
expect_notice "記録の無い接続は、ファイルの時刻で出す" \
  "${title} (ssh の接続): ssh h — 承認の画面は 10/22 08:59 に入った接続の端末に出る" \
  'ssh h' "${work}" "SSH_AUTH_SOCK=${HOME}/b/agent/s.k.sshd.B"

: >"${agent}/s.k.sshd.C"
record s.k.sshd.C polle@pjp-raiden "${t1154}"
expect_notice "より新しい接続があれば添える" \
  "${title} (ssh の接続): ssh h — 承認の画面は 10/22 08:59 に polle@pjp-raiden から入った接続の端末に出る (より新しい接続: 10/22 11:54 polle@pjp-raiden)" \
  'ssh h' "${work}" "SSH_AUTH_SOCK=${HOME}/.ssh/agent.a.sock"

: >"${HOME}/.1password/agent.sock"
expect_notice "手元の agent は path で出す" \
  "${title} (ssh の接続): ssh h — 承認の画面はこのマシンの agent (~/.1password/agent.sock) が出す" \
  'ssh h' "${work}" "SSH_AUTH_SOCK=${HOME}/.1password/agent.sock"

ln -s "${agent}/s.k.sshd.GONE" "${HOME}/.ssh/agent.dead.sock"
expect_notice "先の無い口は、出ないと言う" \
  "${title} (ssh の接続): ssh h — 承認の画面は出ない (agent の口 ~/.ssh/agent.dead.sock の先が無い)" \
  'ssh h' "${work}" "SSH_AUTH_SOCK=${HOME}/.ssh/agent.dead.sock"

expect_notice "コマンドの頭の SSH_AUTH_SOCK= が env より勝つ" \
  "${title} (ssh の接続): ssh h — 承認の画面はこのマシンの agent (~/.1password/agent.sock) が出す" \
  "SSH_AUTH_SOCK=${HOME}/.1password/agent.sock ssh h" "${work}" "SSH_AUTH_SOCK=${HOME}/.ssh/agent.dead.sock"

# --- 黙るもの
run_raw() {
  printf '%s' "$1" | bash "${script}" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
}
run_raw "$(jq -cn '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: "/tmp/x", content: "ssh h"}}')"
if silent; then ok "Bash 以外の tool では黙る"; else ng "Bash 以外の tool では黙る" "$(detail)"; fi
run_raw '{"tool_name": "Bash", '
s1=$(silent && echo yes)
run_raw ''
if [[ ${s1} == yes ]] && silent; then
  ok "壊れた入力・空の入力でも黙って exit 0"
else
  ng "壊れた入力・空の入力でも黙って exit 0" "s1=${s1} $(detail)"
fi
# jq が無い: PATH には cat だけを置き、bash は絶対パスで起動する
nojq="${work}/nojq"
mkdir -p "${nojq}"
ln -s "$(command -v cat)" "${nojq}/cat"
bash_bin=$(command -v bash)
jq -cn '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "ssh h"}}' >"${work}/in"
PATH="${nojq}" "${bash_bin}" "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
echo $? >"${work}/rc"
if silent; then ok "jq が無いときは黙って exit 0"; else ng "jq が無いときは黙って exit 0" "$(detail)"; fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
