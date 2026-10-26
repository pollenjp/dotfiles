#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/hooks/ssh-agent-notice.sh の振る舞いを、合成した hook の入力で確かめる。
#
#   bash nix/tests/ssh-agent-notice.test.sh [<ssh-agent-notice.sh のパス>]
#
# flake の checks (ssh-agent-notice-test) が Nix のサンドボックスで流す。使うのは bash・jq・git・coreutils と
# stdenv の awk だけ。HOME・XDG_STATE_HOME は使い捨ての dir に向け、git の設定は GIT_CONFIG_GLOBAL と
# GIT_CONFIG_COUNT で場面ごとに渡す。herdr は呼ばれた引数を書き留める偽物で代える。時刻は TZ=UTC0 で比べる。
# 手元 (Claude の会話の中) で流しても同じになるよう、始めに GIT_CONFIG_*・HERDR_*・SSH_AUTH_SOCK を外す。
#
# ## 確かめること
#
#   打つ前 (PreToolUse):
#   - ssh・scp・rsync の <host>:・nixos-rebuild の --target-host・nix の ssh://・ssh-keygen -Y sign・ssh-add -T を、
#     包むコマンド (timeout・sudo・env・bash -c・nix develop -c・flock FILE -c)・$( )・<( )・"…" の中の $( )・for の中・
#     heredoc (<<-  も) の後ろでも当て、種類を添えて知らせる
#   - 引用符の中・heredoc の本文・コメント・grep や echo の引数・ssh -G・command -v ssh・ローカルの rsync には当てない。
#     64 KB を超えるコマンドは読まずに抜ける
#   - git は署名するときだけ当てる (env の commit.gpgsign=false は外れ・global の true と -c と -S は当たり・
#     --no-gpg-sign と rebase --abort は外れ・tag は作るときだけ)
#   - git の相手が ssh の remote (cd と -C の先も・clone の URL も) なら当て、insteadOf で https になれば外す
#   - 一覧に足した道具 (claude-ssh-agent-notice.json の extraCommands) は、1 語目を頭の語に、残りを引数に順に (間に
#     別の語があってよい) glob で当てる。JSON が壊れていても組み込みの一覧は効く
#   - 知らせる文は「🔑 … (<種類>): <頭> — 承認の画面は <接続>」の 1 行の JSON だけで、頭は包むコマンドを外して 80 文字で切る
#   - 承認の画面の接続は、pjp-agent-link の記録の時刻と値・記録が無ければファイルの時刻・より新しい接続・手元の agent・
#     先が無い・SSH_AUTH_SOCK が空 (分からない)・WSL で空 (Windows の 1Password) の形で出す。コマンドの頭の
#     SSH_AUTH_SOCK= (~ と $HOME は置き換える) が env より勝つ
#   - herdr の pane で当たれば、herdr の通知 (どこから・頭・接続の 3 行、--sound request) も出す。どこからは
#     workspace の名前・pane の ID・agent の名前 (無ければ pane まで)。同じ pane からは 10 分に 1 回で、別の pane は
#     間を置かない
#   - herdr が落ちる・返事をしない (2 秒で切る。timeout の無いマシンでも) ときも会話の 1 行は出して exit 0。その回の
#     残りと続く 60 秒は herdr を呼ばず、落ちた通知は間引きに数えない
#   - herdr の外と、当たらないコマンドでは herdr を呼ばない
#
#   断られたあと (PostToolUse・PostToolUseFailure):
#   - Bash の出力 (OpenSSH の行の終わりの \r を外して見る) に、agent の断り (ssh・git の署名)・agent との通信が
#     切れた・agent に届かない (git の署名・口の先が無いときの鍵の認証の失敗) があれば、理由ごとの指示 (打ち直さない・
#     何をとどこからを書く・3 つの選択肢・herdr の子の決まり) を additionalContext で足し、会話の 1 行と herdr の通知
#     (理由ごとの title。間引かない) も出す。hookEventName は入力の event に合わせる
#   - 1 つ目の選択肢は、断られたら承認、通信が切れた・届かないなら agent の口の種類 (転送された接続・手元の agent・
#     WSL の Windows の 1Password・空) ごとの直し方
#   - 子の印 (token parent・token kin の 🌱・名前の先頭の 🌱) のある workspace では子の決まりを言い切り、親だけの印
#     (kin の 🌳) や印の無い workspace では条件つきで書く。subagent の中では問いを出させず報告に書かせる
#   - 失敗した Bash は行の終わりが文言のとき、成功した Bash はさらに ssh・git の出す行の頭のときだけ当て、diff・cat・
#     grep の結果や行の途中の文言、行をまたいだ Permission denied と publickey では黙る。口が生きている・空のときの
#     鍵の認証の失敗・断りの無い失敗・Bash 以外でも黙る
#
#   - Bash 以外・壊れた入力・空の入力・jq が無いときは黙り、いつも exit 0

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/ssh-agent-notice.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/ssh-agent-notice-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

# compgen は readline の無い bash (Nix のサンドボックスの bash) に無いので、名前の頭で引く形を使う
for v in ${!GIT_CONFIG_@} ${!HERDR_@} SSH_AUTH_SOCK; do
  unset "${v}"
done
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
# SSH_AUTH_SOCK が空 (WSL でない) ときの接続の文
none_conn='承認の画面がどこに出るかは分からない (SSH_AUTH_SOCK が空)'

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
expect_hit "ssh の接続" 'flock /tmp/lock -c "ssh h true"'
expect_hit "ssh の接続" $'cat <<EOF >x\nbody\nEOF\nssh h true'
expect_hit "ssh の接続" $'cat <<-EOF >x\n\tbody\n\tEOF\nssh h true'

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
expect_miss $'cat <<-EOF >x\n\tssh h true\n\tEOF\necho done'
expect_miss $'cat <<EOF >x\nssh h true\nEOF'
# 64 KB を超えるコマンドは読まずに抜ける (macOS の awk では読むのに数十秒かかる)
pre "cat <<'EOF' >x"$'\n'"$(printf 'filler line with git push and more text here%.0s\n' {1..1500})"$'\nEOF\nssh h true'
if silent; then
  ok "64 KB を超えるコマンドは読まずに抜ける"
else
  ng "64 KB を超えるコマンドは読まずに抜ける" "$(detail)"
fi

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

# --- 一覧に足した道具 (dotfiles.claude.sshAgentNotice.extraCommands が置く JSON)
extras="${HOME}/.local/state/dotfiles/claude-ssh-agent-notice.json"
mkdir -p "${extras%/*}"
jq -cn '{extraCommands: ["nix run .#vm", "*/deploy.sh"]}' >"${extras}"
expect_hit "設定の一覧" 'nix run .#vm -- create a'
expect_hit "設定の一覧" 'nix run -L .#vm -- ip a'
expect_hit "設定の一覧" './scripts/deploy.sh x'
expect_hit "設定の一覧" 'cd infra && nix run .#vm -- deploy a'
expect_miss 'nix run .#vm-test'
expect_miss 'nix build .#vm'
expect_miss 'echo nix run .#vm'
printf '{"extraCommands": ' >"${extras}"
expect_hit "ssh の接続" 'ssh h true'
expect_miss 'nix run .#vm -- create a'
rm -f "${extras}"

# --- 知らせる文: 頭は包むコマンドを外し、80 文字で切る
long="ssh h $(printf 'x%.0s' {1..100})"
expect_notice "頭は包むコマンドを外したもの" \
  "${title} (ssh の接続): ssh h true — ${none_conn}" 'timeout 5 ssh h true'
expect_notice "頭は 80 文字で切る" \
  "${title} (ssh の接続): ${long:0:79}… — ${none_conn}" "${long}"
expect_notice "WSL で SSH_AUTH_SOCK が空なら、Windows の 1Password が出すと言う (ssh は ssh.exe へのラッパー)" \
  "${title} (ssh の接続): ssh h — 承認の画面は Windows の 1Password が出す (要求元は「Windows Terminal」としか出ない)" \
  'ssh h' "${work}" WSL_DISTRO_NAME=Ubuntu

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
expect_notice "コマンドの頭の SSH_AUTH_SOCK= の ~ を置き換える" \
  "${title} (ssh の接続): ssh h — 承認の画面は 10/22 08:59 に polle@pjp-raiden から入った接続の端末に出る (より新しい接続: 10/22 11:54 polle@pjp-raiden)" \
  'SSH_AUTH_SOCK=~/.ssh/agent.a.sock ssh h'
# shellcheck disable=SC2016 # hook に渡すコマンドの文字 ($HOME は hook が置き換える)
expect_notice "コマンドの頭の SSH_AUTH_SOCK= の \$HOME を置き換える" \
  "${title} (ssh の接続): ssh h — 承認の画面は 10/22 08:59 に polle@pjp-raiden から入った接続の端末に出る (より新しい接続: 10/22 11:54 polle@pjp-raiden)" \
  'SSH_AUTH_SOCK=$HOME/.ssh/agent.a.sock ssh h'

# --- herdr の通知
# 偽の herdr: 呼ばれた引数を JSON の配列で log に足し、workspace get・agent get には決まった値を返す。
# FAKE_HERDR_RC で終了コード、FAKE_LABEL で workspace の名前、FAKE_PARENT・FAKE_KIN で workspace の token parent・kin
# (空なら置かない)、FAKE_AGENT で agent の名前 (null なら名前なし)、FAKE_HERDR_SLEEP で返事をするまでの秒を変える
fakebin="${work}/bin"
hlog="${work}/herdr.log"
mkdir -p "${fakebin}"
cat >"${fakebin}/herdr" <<EOF
#!${BASH}
jq -cn '\$ARGS.positional' --args -- "\$@" >>"${hlog}"
[[ -z \${FAKE_HERDR_SLEEP:-} ]] || sleep "\${FAKE_HERDR_SLEEP}"
case "\$1 \$2" in
  "workspace get")
    jq -cn --arg l "\${FAKE_LABEL:-🌱 dotfiles: x}" --arg p "\${FAKE_PARENT:-}" --arg k "\${FAKE_KIN:-}" \
      '{result: {workspace: {label: \$l, tokens: ({parent: \$p, kin: \$k} | with_entries(select(.value != "")))}}}'
    ;;
  "agent get") jq -cn --arg n "\${FAKE_AGENT:-dot-x}" '{result: {agent: {name: (if \$n == "null" then null else \$n end)}}}' ;;
  *) echo '{"result":{"shown":true}}' ;;
esac
exit "\${FAKE_HERDR_RC:-0}"
EOF
chmod +x "${fakebin}/herdr"
: >"${hlog}"
# in_herdr <pane> [NAME=VALUE…]: herdr の pane の env (と偽の herdr を先にした PATH) を並べる
in_herdr() {
  local pane=$1
  shift
  printf '%s\n' HERDR_ENV=1 "HERDR_PANE_ID=${pane}" HERDR_WORKSPACE_ID=w9 HERDR_SESSION=s2 "PATH=${fakebin}:${PATH}" "$@"
}
notified() {
  jq -s '[.[] | select(.[0] == "notification")] | length' "${hlog}"
}
calls() {
  jq -s 'length' "${hlog}"
}
# age_stamps: 印 (通知の間引き・herdr が落ちたこと) を 601 秒前にする
age_stamps() {
  local f
  for f in "${XDG_STATE_HOME}"/pjp-ssh-agent-notice/*; do
    [[ -e ${f} ]] && touch -d "@$(($(date +%s) - 601))" "${f}"
  done
  return 0
}
# ms_since <date +%s%N の値>: そこからの ms
ms_since() {
  echo $((($(date +%s%N) - $1) / 1000000))
}
mapfile -t hp1 < <(in_herdr w9:p1)
pre 'timeout 5 ssh h true' "${work}" "${hp1[@]}"
want_body="workspace「🌱 dotfiles: x」・pane w9:p1・agent dot-x"$'\n'"ssh h true"$'\n'"${none_conn}"
if noticed && [[ $(notified) == 1 ]] \
  && [[ $(jq -sc '[.[] | select(.[0] == "notification")][0]' "${hlog}") == "$(jq -cn --arg b "${want_body}" '["notification", "show", "🔑 1Password の承認が出るかも", "--body", $b, "--sound", "request"]')" ]]; then
  ok "当たれば herdr に「どこから・頭・接続」の通知を音つきで出す"
else
  ng "当たれば herdr に「どこから・頭・接続」の通知を音つきで出す" "$(detail) log=$(cat "${hlog}")"
fi

pre 'ssh h true' "${work}" "${hp1[@]}"
if noticed && [[ $(notified) == 1 ]]; then
  ok "同じ pane から 10 分の間は、通知を出さず会話の 1 行だけ出す"
else
  ng "同じ pane から 10 分の間は、通知を出さず会話の 1 行だけ出す" "$(detail) log=$(cat "${hlog}")"
fi

age_stamps
pre 'ssh h true' "${work}" "${hp1[@]}"
if noticed && [[ $(notified) == 2 ]]; then
  ok "前の通知から 10 分を過ぎれば、また出す"
else
  ng "前の通知から 10 分を過ぎれば、また出す" "$(detail) log=$(cat "${hlog}")"
fi

mapfile -t hp2 < <(in_herdr w9:p2)
pre 'ssh h true' "${work}" "${hp2[@]}"
if noticed && [[ $(notified) == 3 ]]; then
  ok "別の pane からは、間を置かずに出す"
else
  ng "別の pane からは、間を置かずに出す" "$(detail) log=$(cat "${hlog}")"
fi

mapfile -t hp3 < <(in_herdr w9:p3 FAKE_AGENT=null)
pre 'ssh h true' "${work}" "${hp3[@]}"
if [[ $(jq -sr '[.[] | select(.[0] == "notification")][-1][4]' "${hlog}") == "workspace「🌱 dotfiles: x」・pane w9:p3"$'\n'* ]]; then
  ok "agent に名前が無ければ、どこからは pane の ID まで"
else
  ng "agent に名前が無ければ、どこからは pane の ID まで" "log=$(cat "${hlog}")"
fi

n0=$(calls)
pre 'ssh h true' "${work}" "PATH=${fakebin}:${PATH}"
if noticed && [[ $(calls) == "${n0}" ]]; then
  ok "herdr の外 (HERDR_ENV が無い) では herdr を呼ばず、会話の 1 行だけ出す"
else
  ng "herdr の外 (HERDR_ENV が無い) では herdr を呼ばず、会話の 1 行だけ出す" "$(detail) log=$(cat "${hlog}")"
fi

n0=$(calls)
pre 'ls -la' "${work}" "${hp2[@]}"
s1=$(silent && echo yes)
pre 'git status' "${work}" "${hp2[@]}"
if [[ ${s1} == yes ]] && silent && [[ $(calls) == "${n0}" ]]; then
  ok "当たらないコマンドでは herdr を呼ばない"
else
  ng "当たらないコマンドでは herdr を呼ばない" "s1=${s1} $(detail) log=$(cat "${hlog}")"
fi

mapfile -t hp4 < <(in_herdr w9:p4 FAKE_HERDR_RC=1)
n0=$(calls)
pre 'ssh h true' "${work}" "${hp4[@]}"
s1=$(noticed && echo yes)
n1=$(calls)
mapfile -t hp4 < <(in_herdr w9:p4)
pre 'ssh h true' "${work}" "${hp4[@]}"
if [[ ${s1} == yes && ${n1} == $((n0 + 1)) ]] && noticed && [[ $(calls) == "${n1}" ]]; then
  ok "herdr が落ちても会話の 1 行は出て exit 0。その回の残りと、続く 60 秒は herdr を呼ばない"
else
  ng "herdr が落ちても会話の 1 行は出て exit 0。その回の残りと、続く 60 秒は herdr を呼ばない" "s1=${s1} n0=${n0} n1=${n1} $(detail) log=$(cat "${hlog}")"
fi
age_stamps
n0=$(notified)
pre 'ssh h true' "${work}" "${hp4[@]}"
if noticed && [[ $(notified) == $((n0 + 1)) ]]; then
  ok "60 秒を過ぎれば herdr をまた呼ぶ (落ちた通知は間引きに数えない)"
else
  ng "60 秒を過ぎれば herdr をまた呼ぶ (落ちた通知は間引きに数えない)" "n0=${n0} $(detail) log=$(cat "${hlog}")"
fi

mapfile -t hp7 < <(in_herdr w9:p7 FAKE_HERDR_SLEEP=5)
t0=$(date +%s%N)
pre 'ssh h true' "${work}" "${hp7[@]}"
e1=$(ms_since "${t0}")
s1=$(noticed && echo yes)
n1=$(calls)
t0=$(date +%s%N)
pre 'ssh h true' "${work}" "${hp7[@]}"
e2=$(ms_since "${t0}")
if [[ ${s1} == yes ]] && ((e1 < 4000 && e2 < 2000)) && noticed && [[ $(calls) == "${n1}" ]]; then
  ok "返事をしない herdr は 2 秒で切り、続く 60 秒は呼ばない"
else
  ng "返事をしない herdr は 2 秒で切り、続く 60 秒は呼ばない" "e1=${e1}ms e2=${e2}ms s1=${s1} $(detail)"
fi

# timeout の無いマシン (macOS) を、timeout を置かない PATH で作る
farm="${work}/farm"
mkdir -p "${farm}"
for c in bash env jq git awk gawk mawk cat date stat readlink touch mkdir rm mktemp sleep grep; do
  p=$(command -v "${c}") && ln -sf "${p}" "${farm}/${c}"
done
ln -sf "${fakebin}/herdr" "${farm}/herdr"
age_stamps
mapfile -t hp8 < <(in_herdr w9:p8 FAKE_HERDR_SLEEP=5 "PATH=${farm}")
t0=$(date +%s%N)
pre 'ssh h true' "${work}" "${hp8[@]}"
e1=$(ms_since "${t0}")
if [[ ! -e ${farm}/timeout ]] && noticed && ((e1 < 4000)); then
  ok "timeout の無いマシンでも、返事をしない herdr を 2 秒で切る"
else
  ng "timeout の無いマシンでも、返事をしない herdr を 2 秒で切る" "e1=${e1}ms $(detail)"
fi
age_stamps

echo "== ssh-agent-notice.sh: 断られたあと (PostToolUse・PostToolUseFailure)"

# 偽の agent と使い捨ての sshd で集めた文言 (spec §9)。この file を cat しても行の頭に来ないよう、変数に入れて使う。
# OpenSSH は自分のエラー行を \r\n で終える (Claude Code は tool の出力の \r を残す)。git は ssh-keygen の出力の \r を
# ? に変えて出す
key_comment='"1pass SSH Key (test)"'
ssh_refused="sign_and_send_pubkey: signing failed for ED25519 ${key_comment} from agent: agent refused operation"$'\r'
ssh_broken="sign_and_send_pubkey: signing failed for ED25519 ${key_comment} from agent: communication with agent failed"$'\r'
git_refused=$'error: Signing file /tmp/.git_signing_buffer_tmpAB\nCouldn\'t sign message (signer): agent refused operation?\nSigning /tmp/.git_signing_buffer_tmpAB failed: agent refused operation?\n\nfatal: failed to write commit object'
git_nosock=$'error: Couldn\'t get agent socket?\n\nfatal: failed to write commit object'
git_nokey=$'error: Couldn\'t load public key /tmp/.git_signing_key_tmpQ1: No such file or directory?\n\nfatal: failed to write commit object'
denied=$'u@h: Permission denied (publickey).\r'

# Claude に足す文の部品 (spec §10 から写したもの)
desc_refused='1Password に断られた (承認の画面で断られたか、応えないまま時間切れになったか、1Password がロック中だった)'
desc_broken='agent との通信が切れた (agent への接続が途中で閉じた)'
desc_unreachable='agent に届かない (SSH_AUTH_SOCK の先に agent がいない)'
first_refused='1Password を開いて承認するので、打ち直す'
first_reconnect='手元の PC からこのマシンへ接続し直す (agent の口を張り替える) ので、打ち直す'
first_local='1Password を起動してロックを解除するので、打ち直す'
first_windows='Windows の 1Password を起動してロックを解除するので、打ち直す'
first_none='agent を使えるようにする (SSH_AUTH_SOCK を設定する) ので、打ち直す'
child_default='herdr の指揮役から依頼を受けて動いている子は、AskUserQuestion を使わず、問いと選択肢を書いてターンを終える (指揮役がユーザーに聞く)。それ以外は AskUserQuestion で聞く。'
child_sprout='この pane は herdr の指揮役の子 (workspace に子の印 🌱 か、親を示す ↑ がある) なので、AskUserQuestion を使わず、問いと選択肢を書いてターンを終える (指揮役がユーザーに聞く)。'
outside='herdr の外の会話'
# 接続の文 (fwd_sock は「承認の画面の接続」の節で作った、記録のある転送された agent と、より新しい接続のある口)
fwd_sock="${HOME}/.ssh/agent.a.sock"
fwd_conn='承認の画面は 10/22 08:59 に polle@pjp-raiden から入った接続の端末に出る (より新しい接続: 10/22 11:54 polle@pjp-raiden)'
local_sock="${HOME}/.1password/agent.sock"
local_conn='承認の画面はこのマシンの agent (~/.1password/agent.sock) が出す'
dead_conn='承認の画面は出ない (agent の口 ~/.ssh/agent.dead.sock の先が無い)'
windows_conn='承認の画面は Windows の 1Password が出す (要求元は「Windows Terminal」としか出ない)'

# want_ctx <説明> <1 つ目> <頭> <どこから> <接続> <子の決まり>
want_ctx() {
  printf '%s\n%s\n%s\n%s\n%s' \
    "[ssh-agent] 直前の Bash は SSH agent (1Password) を使えずに失敗した: $1。" \
    "同じコマンドを打ち直さない (承認されないまま同じ失敗を繰り返す)。" \
    "1. 何を ($3 の接続先や署名する対象) と、どこから ($4) を書く。$5。" \
    "2. 選択肢の問いを出す: ① $2 (推奨) ② この手順を飛ばして進める ③ ここで止める。① が選ばれたら、同じコマンドを 1 回だけ打ち直す。" \
    "$6"
}
# want_sub_ctx <説明> <頭> <どこから> <接続>
want_sub_ctx() {
  printf '%s\n%s\n%s' \
    "[ssh-agent] 直前の Bash は SSH agent (1Password) を使えずに失敗した: $1。" \
    "同じコマンドを打ち直さない (承認されないまま同じ失敗を繰り返す)。" \
    "subagent の中なので、ユーザーには聞かない。ここまでの結果と、失敗したこと (何を: $2 の接続先や署名する対象。どこから: $3。$4) を報告に書いて作業を終える。問いは呼び出した会話が出す。"
}

# post <event> <コマンド> <出力> [NAME=VALUE…]: 失敗 (PostToolUseFailure) なら出力を error に、成功 (PostToolUse) なら
# tool_response.stdout に入れて流す。extra_json (既定 {}) を入力に重ねる
extra_json='{}'
post() {
  local ev=$1 cmd=$2 text=$3
  shift 3
  jq -cn --arg ev "${ev}" --arg c "${cmd}" --arg t "${text}" --arg d "${work}" --argjson x "${extra_json}" '
    {session_id: "s", hook_event_name: $ev, tool_name: "Bash", tool_input: {command: $c}, cwd: $d}
    + (if $ev == "PostToolUseFailure" then {error: $t, is_interrupt: false}
       else {tool_response: {stdout: $t, stderr: "", interrupted: false, isImage: false}} end)
    + $x' >"${work}/in"
  env "$@" bash "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
  echo $? >"${work}/rc"
}
ctx() {
  jq -r '.hookSpecificOutput.additionalContext // empty' "${work}/stdout" 2>/dev/null
}
# 指示を足したか: exit 0・1 行の JSON・hookEventName が $1・会話の 1 行が $2・指示が $3
told() {
  [[ $(cat "${work}/rc") == 0 ]] \
    && [[ $(wc -l <"${work}/stdout") == 1 ]] \
    && [[ $(jq -r '.hookSpecificOutput.hookEventName // empty' "${work}/stdout" 2>/dev/null) == "$1" ]] \
    && [[ $(notice) == "$2" ]] \
    && [[ $(ctx) == "$3" ]]
}
# expect_told <説明> <event> <会話の 1 行> <指示> <コマンド> <出力> [NAME=VALUE…]
expect_told() {
  local what=$1 ev=$2 sys=$3 want=$4
  shift 4
  post "${ev}" "$@"
  if told "${ev}" "${sys}" "${want}"; then
    ok "${what}"
  else
    ng "${what}" "want_sys=${sys}"$'\n'"want_ctx=${want}"$'\n'"$(detail)"
  fi
}
# expect_quiet <説明> <event> <コマンド> <出力> [NAME=VALUE…]
expect_quiet() {
  local what=$1
  shift
  post "$@"
  if silent; then
    ok "${what}"
  else
    ng "${what}" "$(detail)"
  fi
}

expect_told "ssh が断られたら、打ち直さずに 3 つの選択肢を出させる" PostToolUseFailure \
  "🔑 1Password に断られた: ssh h true — ${fwd_conn}" \
  "$(want_ctx "${desc_refused}" "${first_refused}" "ssh h true" "${outside}" "${fwd_conn}" "${child_default}")" \
  'ssh h true' "Exit code 255"$'\n'"${ssh_refused}"$'\n'"${denied}" "SSH_AUTH_SOCK=${fwd_sock}"
expect_told "git の署名が断られても同じ" PostToolUseFailure \
  "🔑 1Password に断られた: git commit -S -m x — ${none_conn}" \
  "$(want_ctx "${desc_refused}" "${first_refused}" "git commit -S -m x" "${outside}" "${none_conn}" "${child_default}")" \
  'git commit -S -m x' "Exit code 128"$'\n'"${git_refused}"
expect_told "転送された agent との通信が切れたら、接続し直す選択肢にする" PostToolUseFailure \
  "🔑 SSH agent との通信が切れた: ssh h true — ${fwd_conn}" \
  "$(want_ctx "${desc_broken}" "${first_reconnect}" "ssh h true" "${outside}" "${fwd_conn}" "${child_default}")" \
  'ssh h true' "Exit code 255"$'\n'"${ssh_broken}"$'\n'"${denied}" "SSH_AUTH_SOCK=${fwd_sock}"
expect_told "手元の agent との通信が切れたら、1Password を起動する選択肢にする" PostToolUseFailure \
  "🔑 SSH agent との通信が切れた: ssh h true — ${local_conn}" \
  "$(want_ctx "${desc_broken}" "${first_local}" "ssh h true" "${outside}" "${local_conn}" "${child_default}")" \
  'ssh h true' "Exit code 255"$'\n'"${ssh_broken}"$'\n'"${denied}" "SSH_AUTH_SOCK=${local_sock}"
expect_told "git の署名で agent の口が無ければ (SSH_AUTH_SOCK が空)、届かない" PostToolUseFailure \
  "🔑 SSH agent に届かない: git commit -S -m x — ${none_conn}" \
  "$(want_ctx "${desc_unreachable}" "${first_none}" "git commit -S -m x" "${outside}" "${none_conn}" "${child_default}")" \
  'git commit -S -m x' "Exit code 128"$'\n'"${git_nosock}"
expect_told "WSL で鍵を ssh-add -L から引けずに署名に落ちたら、Windows の 1Password を起動する選択肢にする" PostToolUseFailure \
  "🔑 SSH agent に届かない: git tag -s v1 -m v1 — ${windows_conn}" \
  "$(want_ctx "${desc_unreachable}" "${first_windows}" "git tag -s v1 -m v1" "${outside}" "${windows_conn}" "${child_default}")" \
  'git tag -s v1 -m v1' "Exit code 128"$'\n'"${git_nokey}" WSL_DISTRO_NAME=Ubuntu
expect_told "鍵の認証の失敗は、agent の口の先が無いときだけ届かないとみなす" PostToolUseFailure \
  "🔑 SSH agent に届かない: ssh h true — ${dead_conn}" \
  "$(want_ctx "${desc_unreachable}" "${first_reconnect}" "ssh h true" "${outside}" "${dead_conn}" "${child_default}")" \
  'ssh h true' "Exit code 255"$'\n'"${denied}" "SSH_AUTH_SOCK=${HOME}/.ssh/agent.dead.sock"
expect_quiet "agent の口が生きているときの鍵の認証の失敗では黙る" PostToolUseFailure \
  'ssh h true' "Exit code 255"$'\n'"${denied}" "SSH_AUTH_SOCK=${local_sock}"
expect_quiet "SSH_AUTH_SOCK が空のときの鍵の認証の失敗では黙る (WSL の ssh.exe など。たいてい相手に鍵が無いだけ)" PostToolUseFailure \
  'ssh h true' "Exit code 255"$'\n'"${denied}"
expect_told "成功した Bash (2>&1 | tail で終了コードが隠れた) でも、ssh の出す形の行 (\\r で終わる) があれば当てる" PostToolUse \
  "🔑 1Password に断られた: ssh h true — ${fwd_conn}" \
  "$(want_ctx "${desc_refused}" "${first_refused}" "ssh h true" "${outside}" "${fwd_conn}" "${child_default}")" \
  'ssh h true 2>&1 | tail -3' "${ssh_refused}"$'\n'"${denied}" "SSH_AUTH_SOCK=${fwd_sock}"
expect_quiet "成功した grep の結果 (file:行: の後ろの断り) では黙る" PostToolUse \
  'grep -rn signing nix/' "nix/x.sh:12:${ssh_refused}"
expect_quiet "成功した Bash の行の途中の断りでは黙る" PostToolUse \
  'cat notes.md' "- ${ssh_refused%$'\r'} が出たら"$'\n'"  echo \"${git_nosock%%$'\n'*}\""
phrase=${ssh_refused%$'\r'}
phrase=${phrase##*: }
expect_quiet "失敗した diff の、行の途中の断りでは黙る" PostToolUseFailure 'git diff --exit-code' \
  "Exit code 1"$'\n'"-      *\"${phrase}\"*) echo refused ;;"$'\n'"+      *\"${phrase}\"*) echo r ;;"
expect_quiet "失敗した diff の、見本を変数に入れた行の鍵の読み込みの失敗では黙る" PostToolUseFailure 'git diff --exit-code' \
  "Exit code 1"$'\n'"+git_nokey=\$'${git_nokey%%$'\n'*}'"
expect_quiet "失敗した cat の、文書の表の中の断りでは黙る" PostToolUseFailure 'cat docs/x.md missing.md' \
  "Exit code 1"$'\n'"| 断られた | \`${git_nosock%%$'\n'*}\` (git) |"$'\n'"cat: missing.md: No such file or directory"
expect_quiet "失敗した出力の、行をまたいだ Permission denied と publickey では黙る" PostToolUseFailure 'cp a b' \
  $'Exit code 1\ncp: cannot open \'a\': Permission denied (os error 13)\n/home/u/.ssh/id_ed25519.publickey' \
  "SSH_AUTH_SOCK=${HOME}/.ssh/agent.dead.sock"
expect_quiet "断りの無い失敗では黙る" PostToolUseFailure 'ssh h true' $'Exit code 1\nssh: connect to host h port 22: Connection refused'
post PostToolUseFailure 'ssh h true' "Exit code 255"$'\n'"${ssh_refused}"
sed -i 's/"tool_name":"Bash"/"tool_name":"Write"/' "${work}/in"
bash "${script}" <"${work}/in" >"${work}/stdout" 2>"${work}/stderr"
echo $? >"${work}/rc"
if silent; then ok "Bash 以外の失敗では黙る"; else ng "Bash 以外の失敗では黙る" "$(detail)"; fi

# herdr の pane: 🌱 の workspace では子の決まりを言い切る。通知は理由ごとの title で、間引かない
mapfile -t hp5 < <(in_herdr w9:p5)
n0=$(notified)
where5='workspace「🌱 dotfiles: x」・pane w9:p5・agent dot-x'
expect_told "🌱 の workspace の子には、AskUserQuestion を使わず問いを書いて終えるよう言い切る" PostToolUseFailure \
  "🔑 1Password に断られた: ssh h true — ${none_conn}" \
  "$(want_ctx "${desc_refused}" "${first_refused}" "ssh h true" "${where5}" "${none_conn}" "${child_sprout}")" \
  'ssh h true' "Exit code 255"$'\n'"${ssh_refused}" "${hp5[@]}"
post PostToolUseFailure 'ssh h true' "Exit code 255"$'\n'"${ssh_refused}" "${hp5[@]}"
if [[ $(notified) == $((n0 + 2)) ]] \
  && [[ $(jq -sc '[.[] | select(.[0] == "notification")][-1]' "${hlog}") == "$(jq -cn --arg b "${where5}"$'\n'"ssh h true"$'\n'"${none_conn}" '["notification", "show", "🔑 1Password に断られた", "--body", $b, "--sound", "request"]')" ]]; then
  ok "断られたことは herdr にも理由ごとの title で知らせ、続けても間引かない"
else
  ng "断られたことは herdr にも理由ごとの title で知らせ、続けても間引かない" "n0=${n0} log=$(cat "${hlog}")"
fi
mapfile -t hp6 < <(in_herdr w9:p6 FAKE_LABEL="dotfiles: x")
expect_told "🌱 でない workspace では、子の決まりを条件つきで書く" PostToolUseFailure \
  "🔑 1Password に断られた: ssh h true — ${none_conn}" \
  "$(want_ctx "${desc_refused}" "${first_refused}" "ssh h true" 'workspace「dotfiles: x」・pane w9:p6・agent dot-x' "${none_conn}" "${child_default}")" \
  'ssh h true' "Exit code 255"$'\n'"${ssh_refused}" "${hp6[@]}"
# 子の印は token でも見る (ws-mark.sh が名前に印を付けなくなった後の形)。親だけの印 (kin の 🌳) は子でない
mapfile -t hp7 < <(in_herdr w9:p7 FAKE_LABEL="dotfiles: x" FAKE_PARENT="↑ TKT-n")
expect_told "名前に 🌱 が無くても、token parent のある workspace の子には言い切る" PostToolUseFailure \
  "🔑 1Password に断られた: ssh h true — ${none_conn}" \
  "$(want_ctx "${desc_refused}" "${first_refused}" "ssh h true" 'workspace「dotfiles: x」・pane w9:p7・agent dot-x' "${none_conn}" "${child_sprout}")" \
  'ssh h true' "Exit code 255"$'\n'"${ssh_refused}" "${hp7[@]}"
for kin in 🌱 🌱🌳; do
  mapfile -t hp8 < <(in_herdr w9:p8 FAKE_LABEL="dotfiles: x" FAKE_KIN="${kin}")
  expect_told "名前に 🌱 が無くても、token kin が ${kin} の workspace の子には言い切る" PostToolUseFailure \
    "🔑 1Password に断られた: ssh h true — ${none_conn}" \
    "$(want_ctx "${desc_refused}" "${first_refused}" "ssh h true" 'workspace「dotfiles: x」・pane w9:p8・agent dot-x' "${none_conn}" "${child_sprout}")" \
    'ssh h true' "Exit code 255"$'\n'"${ssh_refused}" "${hp8[@]}"
done
mapfile -t hp9 < <(in_herdr w9:p9 FAKE_LABEL="TKT-n 親の会話" FAKE_KIN="🌳")
expect_told "token kin が 🌳 だけ (親) で parent の無い workspace では、子の決まりを条件つきで書く" PostToolUseFailure \
  "🔑 1Password に断られた: ssh h true — ${none_conn}" \
  "$(want_ctx "${desc_refused}" "${first_refused}" "ssh h true" 'workspace「TKT-n 親の会話」・pane w9:p9・agent dot-x' "${none_conn}" "${child_default}")" \
  'ssh h true' "Exit code 255"$'\n'"${ssh_refused}" "${hp9[@]}"

extra_json='{"agent_id": "agent-1", "agent_type": "general-purpose"}'
expect_told "subagent の中では問いを出させず、報告に書いて終えさせる" PostToolUseFailure \
  "🔑 1Password に断られた: ssh h true — ${none_conn}" \
  "$(want_sub_ctx "${desc_refused}" "ssh h true" "${where5}・subagent general-purpose" "${none_conn}")" \
  'ssh h true' "Exit code 255"$'\n'"${ssh_refused}" "${hp5[@]}"
extra_json='{}'

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
