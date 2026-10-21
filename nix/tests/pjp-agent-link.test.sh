#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/pjp-agent-link/ (herdr の session ごとの固定名の向け先を決める pjp-agent-link.sh と、herdr を包む
# herdr.sh) と、nix/files/starship.toml の PJP_SSH_CLIENT の警告の振る舞いを、偽の HOME・偽の ssh-add・
# 本物の unix socket で確かめる (ADR 025)。
#
#   bash nix/tests/pjp-agent-link.test.sh [<nix/pkgs/pjp-agent-link のパス> [<starship.toml のパス>]]
#
# flake の checks (pjp-agent-link-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・python3
# (socket を bind する・starship.toml を読む)・flock (script が使う)・starship。引数を省けば repo のものを使う。
#
# ## 確かめること
#
#   - attach (herdr を開いた接続) は、開いた session の固定名だけを決め直す。今の先が生きていて持ち主が
#     開いた接続と同じ値なら変えず、死んでいる・持ち主が分からない・別の値・値が届いていないなら開いた接続へ
#     向け、持ち主をその値にする。返事をしない先は 1 秒で見切る。何も無い HOME でも ~/.ssh と記録の場所を
#     0700 で作って通る。持ち主の記録の「張った先」が今の先と違えば持ち主は分からない扱い。張り替えに失敗したら
#     (~/.ssh に書けない) 先も持ち主も変えず、直れば次の attach で移る。生死は USE_LINUX_SSH=1 を付けて PATH の
#     ssh-add に聞く。flock の無いホストでも (lock を取らずに) 張り替える
#   - PJP_SSH_CLIENT は、空・% を含む (展開されていない %u@%L)・制御文字を含む・local なら届いていない扱い
#   - open の「開いた接続」: ssh の shell は自分の socket と値、ssh -a と SSH_AGENT_PID の shell は張り替えずに
#     固定名だけ、herdr の pane は同じ session なら何もせず別の session なら pane の固定名の先と持ち主で張る、
#     手元の 1Password は socket が無くても張って持ち主 local、WSL の手元は何も出さず何も作らない。start は
#     張り替えずに固定名を出す。session の名前が herdr の規則に外れたら何もしない
#   - link (ssh-agent-link) は今の接続へ強制で向ける。session は引数・HERDR_SESSION・default の順。pane の中と
#     張る先の無い shell では張らずに exit 1
#   - rc (~/.ssh/rc) は stdout に何も書かず (xauth が stdout に書いても)、forward された socket と値 (届いていなければ
#     空) と開いた時刻を socket の basename の名前で記録する (/tmp/ssh-XXXXXX/agent.<pid> の形も)。同じ socket の
#     2 回目の session (ControlMaster) は開いた時刻を引き継ぐ。forward の無い接続・SSH_AGENT_PID・ssh でない shell は
#     記録しない。DISPLAY があれば cookie を xauth へ渡し (localhost:N は unix:N)、無ければ閉じない stdin でも
#     読まずに終わる。何も無い HOME でも記録の場所を 0700 で作る
#   - watch は cc-page 0003 の場面 1 (同じ PC から 4 本・別の PC から 2 本、1〜11) を表のとおりに動かす: 先が
#     生きていれば何もせず (覗くだけの接続は奪わない)、死んでいれば持ち主と同じ値の生きている一番古い接続を
#     借り (socket の名前の順ではなく開いた順)、別の値・届いていない値の接続は借りず、持ち主が空の固定名には
#     (値の届いていない接続も) 借りない。借りても持ち主は変えない。
#     返事をしない記録は 1 秒で見切る。死んだ socket の記録を消す。先を確かめている間に attach が張り替えたら
#     上書きしない。先が手元の 1Password なら触らない。stdout に何も出さない
#   - status は固定名の先・持ち主と、記録にある接続と、PATH の herdr が包んだものかを出す
#   - herdr を包む実行ファイルは、引数をそのまま本物の herdr へ渡す。herdr (サブコマンドなし)・--session <名前>・
#     --session=<名前>・session attach <名前>・remote-client-bridge [--idle-timeout-v1] では決め直して
#     SSH_AUTH_SOCK をその session の固定名にし、herdr server では決め直さずに固定名にする。それ以外
#     (status・server stop・pane・--remote・--remote-keybindings・--version・--help・session attach help・値の無い
#     --session) では env も固定名も変えない。session は引数・HERDR_SESSION・default の順。bridge の stdin を読まず、
#     stdout には本物の herdr の出力だけが出る (pjp-agent-link が stdin を読もうとしても・stderr に書いても漏れない)。
#     WSL の手元では env を変えない。pjp-agent-link が失敗しても・返事をしなくても (10 秒で打ち切る)、元の env で
#     herdr を起こす
#   - starship.toml の custom.pjp_ssh_client は sh で判定し、ssh で入った shell で PJP_SSH_CLIENT が空・% を含む
#     とき、herdr の pane で固定名の持ち主が空・無いときだけ警告を出す (値がある・持ち主がある・local・手元の
#     shell では出さない)。本物の starship でも同じに出る。判定で ssh-add を呼ばない
#
# ## 作り
#
# socket は python3 で bind して置く (listen しない。生死は偽の ssh-add が決める)。偽の ssh-add は SSH_AUTH_SOCK の
# basename で ${FAKE_AGENT_MODES}/<basename> を引き、keys (exit 0)・empty (exit 1)・hang (返事をしない)・refuse
# (exit 2) のふりをする。socket が無ければ exit 2。script は env -i で、HOME と PATH と渡した変数だけで流す。
# herdr を包む実行ファイルは、herdr.sh の置き換え (本物の herdr・pjp-agent-link・timeout) を偽の herdr (argv・
# SSH_AUTH_SOCK・読んだ stdin を書き留める) と包む前の script にした写しで流す。
# unix socket のパスは 108 byte までなので、TMPDIR が長いときは /tmp に作業場所を作る。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
pkgdir=$(realpath -- "${1:-${here}/../pkgs/pjp-agent-link}")
starship_toml=$(realpath -- "${2:-${here}/../files/starship.toml}")
agent_sh="${pkgdir}/pjp-agent-link.sh"
wrapper_sh="${pkgdir}/herdr.sh"

base=${TMPDIR:-/tmp}
if ((${#base} > 40)); then
  base=/tmp
fi
work=$(mktemp -d "${base}/pal-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT
work=$(realpath -- "${work}")

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

for cmd in python3 flock timeout; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "見つからない: ${cmd}" >&2
    exit 1
  fi
done

# 偽の ssh-add。問い合わせた socket と USE_LINUX_SSH を FAKE_SSH_ADD_LOG に書き留める。FAKE_SSH_ADD_HOOK の script があり、
# 問い合わせた socket の basename が FAKE_SSH_ADD_HOOK_MATCH なら、1 回だけそれを流してから答える
bin="${work}/bin"
modes="${work}/modes"
mkdir -p "${bin}" "${modes}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
s=${SSH_AUTH_SOCK-}
printf '%s USE_LINUX_SSH=%s\n' "${s}" "${USE_LINUX_SSH-}" >>"${FAKE_SSH_ADD_LOG}"
if [[ -n ${FAKE_SSH_ADD_HOOK-} && -f ${FAKE_SSH_ADD_HOOK} && ${s##*/} == "${FAKE_SSH_ADD_HOOK_MATCH-}" ]]; then
  bash "${FAKE_SSH_ADD_HOOK}"
  rm -f "${FAKE_SSH_ADD_HOOK}"
fi
if [[ ! -S ${s} ]]; then
  echo "Error connecting to agent: No such file or directory" >&2
  exit 2
fi
mode=keys
if [[ -f ${FAKE_AGENT_MODES}/${s##*/} ]]; then
  mode=$(cat "${FAKE_AGENT_MODES}/${s##*/}")
fi
case ${mode} in
  keys)
    echo "256 SHA256:fake fake@test (ED25519)"
    exit 0
    ;;
  empty)
    echo "The agent has no identities."
    exit 1
    ;;
  hang)
    sleep 30
    exit 0
    ;;
  *)
    echo "error fetching identities: communication with agent failed" >&2
    exit 2
    ;;
esac
EOF
} >"${bin}/ssh-add"
chmod +x "${bin}/ssh-add"
export PATH="${bin}:${PATH}"
ssh_add_log="${work}/ssh-add.log"
: >"${ssh_add_log}"

# 偽の xauth。引数と stdin を FAKE_XAUTH_LOG に書き留め、stdout にも書く (rc が stdout を捨てているかを見る)
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
{
  printf 'args: %s\n' "$*"
  cat
} >>"${FAKE_XAUTH_LOG}"
echo XAUTH-STDOUT
EOF
} >"${bin}/xauth"
chmod +x "${bin}/xauth"
xauth_log="${work}/xauth.log"
: >"${xauth_log}"

# HOME を作り直して H に入れる。$1: 名前。~/.ssh/agent (sshd が socket を置く場所) まで作る
newhome() {
  H="${work}/h/$1"
  mkdir -p "${H}/.ssh/agent"
  chmod 700 "${H}/.ssh" "${H}/.ssh/agent"
}

# socket を bind して置く。$1: パス、$2: 偽の ssh-add の答え方 (省けば keys)
mksock() {
  mkdir -p "$(dirname "$1")"
  python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
  printf '%s\n' "${2:-keys}" >"${modes}/${1##*/}"
}
setmode() {
  printf '%s\n' "$2" >"${modes}/${1##*/}"
}

# 固定名を先と持ち主つきで置く (前の attach や watch が張った状態)。$1: session、$2: 先、$3: 持ち主 (省けば
# 持ち主のファイルを置かない)、$4: 持ち主の記録に書く張った先 (省けば $2。記録は「値」と「張った先」の 2 行)
seed() {
  local fixed
  if [[ $1 == default ]]; then
    fixed="${H}/.ssh/agent.sock"
  else
    fixed="${H}/.ssh/agent.$1.sock"
  fi
  ln -sfn "$2" "${fixed}"
  if [[ $# -ge 3 ]]; then
    mkdir -p "${H}/.local/state/pjp-agent-link/owner"
    printf '%s\n%s\n' "$3" "${4:-$2}" >"${H}/.local/state/pjp-agent-link/owner/$1"
  fi
}

# script を 1 回流す。$1: 置き場所の名前、続けて env に渡す VAR=値… (名前=値 の形のもの) と、script の引数。
# env -i で、HOME と PATH と渡した変数だけにする。stdin は agent_stdin (省けば /dev/null)。stdout・stderr・
# 終了コードを <置き場所>/{out,err,rc} に書き、置き場所を返す
agent() {
  local d="${work}/out/$1" envs=()
  shift
  while [[ $# -gt 0 && $1 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    envs+=("$1")
    shift
  done
  mkdir -p "${d}"
  env -i HOME="${H}" PATH="${PATH}" FAKE_AGENT_MODES="${modes}" FAKE_SSH_ADD_LOG="${ssh_add_log}" \
    FAKE_XAUTH_LOG="${xauth_log}" "${envs[@]}" bash "${agent_sh}" "$@" \
    >"${d}/out" 2>"${d}/err" <"${agent_stdin:-/dev/null}"
  echo $? >"${d}/rc"
  printf '%s' "${d}"
}
# agent と同じで、stdin を $1 のファイルにする
agent_in() {
  local agent_stdin=$1
  shift
  agent "$@"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }

link_of() { readlink "${H}/.ssh/$1" 2>/dev/null || echo "(無い)"; }
owner_of() {
  if [[ -f ${H}/.local/state/pjp-agent-link/owner/$1 ]]; then
    head -n 1 "${H}/.local/state/pjp-agent-link/owner/$1"
  else
    echo "(無い)"
  fi
}
perm() { stat -c %a "$1" 2>/dev/null || echo "(無い)"; }

PC=alice@ALICE-PC
OTHER=taro@LAPTOP-7QX2
conn="SSH_CONNECTION=192.0.2.1 50000 192.0.2.2 22"

echo "== attach (herdr を開いた接続)"

# 1. 何も無い HOME (~/.ssh も記録の場所も無い)
H="${work}/h/empty"
mkdir -p "${H}"
A="${work}/sock/s.t.sshd.empty-A"
mksock "${A}"
d=$(agent attach-empty "${conn}" "SSH_AUTH_SOCK=${A}" "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d}") == 0 && $(out "${d}") == "${H}/.ssh/agent.sock" && $(link_of agent.sock) == "${A}" &&
$(owner_of default) == "${PC}" && $(perm "${H}/.ssh") == 700 &&
$(perm "${H}/.local/state/pjp-agent-link") == 700 ]]; then
  ok "何も無い HOME: ~/.ssh と記録の場所を 0700 で作り、開いた接続へ張る"
else
  ng "何も無い HOME" "rc=$(rc "${d}") out=$(out "${d}") link=$(link_of agent.sock) owner=$(owner_of default) ssh=$(perm "${H}/.ssh") state=$(perm "${H}/.local/state/pjp-agent-link") err=$(err "${d}")"
fi

# 2. 生きていて同じマシン
newhome alive-same
A="${H}/.ssh/agent/s.t.sshd.as-A"
B="${H}/.ssh/agent/s.t.sshd.as-B"
mksock "${A}"
mksock "${B}"
seed default "${A}" "${PC}"
d=$(agent attach-alive-same "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d}") == 0 && $(out "${d}") == "${H}/.ssh/agent.sock" && $(link_of agent.sock) == "${A}" &&
$(owner_of default) == "${PC}" ]]; then
  ok "生きていて同じマシンなら、切断前の接続を使い続ける (B から開いても A のまま)"
else
  ng "生きていて同じマシン" "rc=$(rc "${d}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
fi

# 3. 死んでいる (socket が消えた)
newhome dead
A="${H}/.ssh/agent/s.t.sshd.dead-A"
B="${H}/.ssh/agent/s.t.sshd.dead-B"
mksock "${B}"
seed default "${A}" "${PC}"
d=$(agent attach-dead "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d}") == 0 && $(link_of agent.sock) == "${B}" && $(owner_of default) == "${PC}" ]]; then
  ok "先が死んでいれば、開いた接続へ向ける"
else
  ng "先が死んでいる" "rc=$(rc "${d}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
fi

# 4. 別のマシンから開く (前の接続は生きている)
newhome other
A="${H}/.ssh/agent/s.t.sshd.other-A"
E="${H}/.ssh/agent/s.t.sshd.other-E"
mksock "${A}"
mksock "${E}"
seed default "${A}" "${PC}"
d=$(agent attach-other "${conn}" "SSH_AUTH_SOCK=${E}" "PJP_SSH_CLIENT=${OTHER}" open attach default)
if [[ $(rc "${d}") == 0 && $(link_of agent.sock) == "${E}" && $(owner_of default) == "${OTHER}" ]]; then
  ok "別のマシンから開けば、前の接続が生きていても移り、持ち主も移る"
else
  ng "別のマシンから開く" "rc=$(rc "${d}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
fi

# 5. 持ち主が分からない (この変更の前に張られた固定名)
newhome unknown
A="${H}/.ssh/agent/s.t.sshd.unknown-A"
B="${H}/.ssh/agent/s.t.sshd.unknown-B"
mksock "${A}"
mksock "${B}"
seed default "${A}"
d=$(agent attach-unknown "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d}") == 0 && $(link_of agent.sock) == "${B}" && $(owner_of default) == "${PC}" ]]; then
  ok "持ち主が分からない固定名は、先が生きていても開いた接続へ移る"
else
  ng "持ち主が分からない" "rc=$(rc "${d}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
fi

# 6. 値が届いていない接続から開く (2 回続けて)
newhome novalue
B="${H}/.ssh/agent/s.t.sshd.novalue-B"
C="${H}/.ssh/agent/s.t.sshd.novalue-C"
mksock "${B}"
mksock "${C}"
d1=$(agent attach-novalue-1 "${conn}" "SSH_AUTH_SOCK=${B}" open attach default)
l1=$(link_of agent.sock)
o1=$(owner_of default)
d2=$(agent attach-novalue-2 "${conn}" "SSH_AUTH_SOCK=${C}" open attach default)
if [[ $(rc "${d1}") == 0 && ${l1} == "${B}" && -z ${o1} && $(rc "${d2}") == 0 && $(link_of agent.sock) == "${C}" ]]; then
  ok "値が届いていない接続から開いても向き、持ち主は空 (次に値の無い接続から開いても移る)"
else
  ng "値が届いていない" "1: rc=$(rc "${d1}") link=${l1} owner=${o1} / 2: rc=$(rc "${d2}") link=$(link_of agent.sock) err=$(err "${d2}")"
fi

# 7. 展開されていない値・おかしな値は届いていない扱い
i=0
for v in '%u@%L' $'alice@ALICE-PC\nx' 'local'; do
  i=$((i + 1))
  newhome "weird-${i}"
  A="${H}/.ssh/agent/s.t.sshd.weird${i}-A"
  mksock "${A}"
  d=$(agent "attach-weird-${i}" "${conn}" "SSH_AUTH_SOCK=${A}" "PJP_SSH_CLIENT=${v}" open attach default)
  if [[ $(rc "${d}") == 0 && $(link_of agent.sock) == "${A}" && -z $(owner_of default) ]]; then
    ok "展開されていない値は届いていない扱い: $(printf '%q' "${v}") の持ち主は空"
  else
    ng "おかしな値 $(printf '%q' "${v}")" "rc=$(rc "${d}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
  fi
done

# 8. 返事をしない先は 1 秒で見切る (回線断で sshd に残った接続)
newhome hang
A="${H}/.ssh/agent/s.t.sshd.hang-A"
B="${H}/.ssh/agent/s.t.sshd.hang-B"
mksock "${A}" hang
mksock "${B}"
seed default "${A}" "${PC}"
t0=$(date +%s)
d=$(agent attach-hang "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach default)
t1=$(date +%s)
if [[ $(rc "${d}") == 0 && $(link_of agent.sock) == "${B}" ]] && ((t1 - t0 < 5)); then
  ok "返事をしない先は 1 秒で見切る: $((t1 - t0)) 秒で開いた接続へ移る"
else
  ng "返事をしない先" "rc=$(rc "${d}") link=$(link_of agent.sock) 秒=$((t1 - t0)) err=$(err "${d}")"
fi

# 9. session ごと: s2 を開いても default の固定名は触らない
newhome session
A="${H}/.ssh/agent/s.t.sshd.session-A"
B="${H}/.ssh/agent/s.t.sshd.session-B"
mksock "${A}"
mksock "${B}"
seed default "${A}" "${PC}"
d=$(agent attach-session "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach s2)
if [[ $(rc "${d}") == 0 && $(out "${d}") == "${H}/.ssh/agent.s2.sock" && $(link_of agent.s2.sock) == "${B}" &&
$(owner_of s2) == "${PC}" && $(link_of agent.sock) == "${A}" ]]; then
  ok "session ごと: s2 の attach は agent.s2.sock だけを張り、agent.sock は触らない"
else
  ng "session ごと" "rc=$(rc "${d}") out=$(out "${d}") s2=$(link_of agent.s2.sock) default=$(link_of agent.sock) err=$(err "${d}")"
fi

# 9b. 持ち主の記録の「張った先」が今の固定名の先と違えば、持ち主は分からないとして扱う
newhome stale-owner
A="${H}/.ssh/agent/s.t.sshd.stale-A"
B="${H}/.ssh/agent/s.t.sshd.stale-B"
mksock "${A}"
mksock "${B}"
seed default "${A}" "${PC}" "${H}/.ssh/agent/s.t.sshd.stale-OLD"
d=$(agent attach-stale-owner "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d}") == 0 && $(link_of agent.sock) == "${B}" && $(owner_of default) == "${PC}" ]]; then
  ok "持ち主の記録の先が今の先と違えば (張り替えの途中で止まった)、持ち主は分からないとして開いた接続へ移る"
else
  ng "持ち主の記録の先が違う" "rc=$(rc "${d}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
fi

# 9c. 張り替えに失敗したら (~/.ssh に書けない)、先も持ち主も変えない。直れば次の attach で移る
newhome swapfail
A="${H}/.ssh/agent/s.t.sshd.swapfail-A"
B="${H}/.ssh/agent/s.t.sshd.swapfail-B"
mksock "${A}"
mksock "${B}"
seed default "${A}" "${OTHER}"
chmod 500 "${H}/.ssh"
d1=$(agent attach-swapfail-1 "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach default)
l1=$(link_of agent.sock)
o1=$(owner_of default)
chmod 700 "${H}/.ssh"
d2=$(agent attach-swapfail-2 "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d1}") == 0 && $(out "${d1}") == "${H}/.ssh/agent.sock" && ${l1} == "${A}" && ${o1} == "${OTHER}" &&
$(rc "${d2}") == 0 && $(link_of agent.sock) == "${B}" && $(owner_of default) == "${PC}" ]]; then
  ok "張り替えに失敗したら先も持ち主も変えず (新しい持ち主と古い先の組を残さない)、直れば次の attach で移る"
else
  ng "張り替えの失敗" "1: rc=$(rc "${d1}") link=${l1} owner=${o1} / 2: rc=$(rc "${d2}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d2}")"
fi

# 9d. 生死は USE_LINUX_SSH=1 を付けて ssh-add に聞く (WSL の ssh-add のラッパーが PATH の先にあっても、
#     SSH_AUTH_SOCK を見る Linux の ssh-add に落ちる)
newhome usels
A="${H}/.ssh/agent/s.t.sshd.usels-A"
B="${H}/.ssh/agent/s.t.sshd.usels-B"
mksock "${A}"
mksock "${B}"
seed default "${A}" "${PC}"
: >"${ssh_add_log}"
d=$(agent attach-usels "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d}") == 0 ]] && grep -qx "${A} USE_LINUX_SSH=1" "${ssh_add_log}"; then
  ok "生死は USE_LINUX_SSH=1 を付けて ssh-add に聞く (WSL のラッパーでも Linux の ssh-add に落ちる)"
else
  ng "USE_LINUX_SSH" "rc=$(rc "${d}") log=$(cat "${ssh_add_log}")"
fi

# 9e. flock の無いホスト (macOS) でも、lock を取らずに張り替える。要るコマンドだけを symlink で並べた PATH で流す
nolock_bin="${work}/nolock-bin"
mkdir -p "${nolock_bin}"
for c in readlink mkdir mv ln rm date stat tail sort ls timeout env cat cut head grep sleep basename; do
  if ! p=$(command -v "${c}"); then
    echo "見つからない: ${c}" >&2
    exit 1
  fi
  ln -s "${p}" "${nolock_bin}/${c}"
done
ln -s "${bin}/ssh-add" "${nolock_bin}/ssh-add"
ln -s "${BASH}" "${nolock_bin}/bash"
newhome nolock
A="${H}/.ssh/agent/s.t.sshd.nolock-A"
B="${H}/.ssh/agent/s.t.sshd.nolock-B"
mksock "${A}"
mksock "${B}"
seed default "${A}" "${OTHER}"
d=$(agent attach-nolock "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" "PATH=${nolock_bin}" open attach default)
if [[ $(rc "${d}") == 0 && $(link_of agent.sock) == "${B}" && $(owner_of default) == "${PC}" && -z $(err "${d}") ]]; then
  ok "flock の無いホスト (macOS) でも、lock を取らずに張り替える"
else
  ng "flock の無いホスト" "rc=$(rc "${d}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
fi

echo "== open の「開いた接続」"

# 10. ssh -a (forward が無い) と、SSH_AGENT_PID のある shell (フォールバックのローカル agent)
newhome noforward
A="${H}/.ssh/agent/s.t.sshd.noforward-A"
L="${H}/.ssh/agent/s.t.agent.noforward-L"
mksock "${L}"
seed default "${A}" "${PC}"
d1=$(agent open-noforward "${conn}" "PJP_SSH_CLIENT=${PC}" open attach default)
d2=$(agent open-agentpid "${conn}" "SSH_AUTH_SOCK=${L}" SSH_AGENT_PID=4242 "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d1}") == 0 && $(out "${d1}") == "${H}/.ssh/agent.sock" && $(rc "${d2}") == 0 &&
$(out "${d2}") == "${H}/.ssh/agent.sock" && $(link_of agent.sock) == "${A}" ]]; then
  ok "ssh -a と SSH_AGENT_PID の shell からは張り替えず、SSH_AUTH_SOCK には固定名を渡す"
else
  ng "ssh -a と SSH_AGENT_PID" "1: rc=$(rc "${d1}") out=$(out "${d1}") / 2: rc=$(rc "${d2}") out=$(out "${d2}") / link=$(link_of agent.sock)"
fi

# 11. herdr の pane の中 (同じ session)。SSH_CONNECTION は server を起こした接続のものが残っている
newhome pane-same
A="${H}/.ssh/agent/s.t.sshd.pane-same-A"
mksock "${A}"
seed default "${A}" "${PC}"
d=$(agent open-pane-same "${conn}" "SSH_AUTH_SOCK=${H}/.ssh/agent.sock" "PJP_SSH_CLIENT=${PC}" open attach default)
if [[ $(rc "${d}") == 0 && $(out "${d}") == "${H}/.ssh/agent.sock" && $(link_of agent.sock) == "${A}" ]]; then
  ok "pane の中で同じ session を開いても張り替えない (自分自身を指す symlink にしない)"
else
  ng "pane の中 (同じ session)" "rc=$(rc "${d}") out=$(out "${d}") link=$(link_of agent.sock) err=$(err "${d}")"
fi

# 12. herdr の pane の中 (別の session)
newhome pane-other
A="${H}/.ssh/agent/s.t.sshd.pane-other-A"
mksock "${A}"
seed default "${A}" "${PC}"
d=$(agent open-pane-other "${conn}" "SSH_AUTH_SOCK=${H}/.ssh/agent.sock" open attach s3)
if [[ $(rc "${d}") == 0 && $(out "${d}") == "${H}/.ssh/agent.s3.sock" && $(link_of agent.s3.sock) == "${A}" &&
$(owner_of s3) == "${PC}" && $(link_of agent.sock) == "${A}" ]]; then
  ok "pane の中から別の session を開くと、pane の固定名と同じ先・同じ持ち主で張る"
else
  ng "pane の中 (別の session)" "rc=$(rc "${d}") out=$(out "${d}") s3=$(link_of agent.s3.sock) owner=$(owner_of s3) err=$(err "${d}")"
fi

# 13. 手元の 1Password (NixOS の laptop の前で開く。socket がまだ無くても張る)
newhome onepassword
A="${H}/.ssh/agent/s.t.sshd.op-A"
mksock "${A}"
seed default "${A}" "${PC}"
d=$(agent open-1password "SSH_AUTH_SOCK=${H}/.1password/agent.sock" open attach default)
l=$(link_of agent.sock)
if [[ $(rc "${d}") == 0 && $(out "${d}") == "${H}/.ssh/agent.sock" &&
${l} == "${H}/.1password/agent.sock" && $(owner_of default) == local ]]; then
  ok "手元の 1Password から開くと、ssh の接続を指していても 1Password へ張り、持ち主は local (ADR 022)"
else
  ng "手元の 1Password" "rc=$(rc "${d}") out=$(out "${d}") link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
fi

# 14. WSL の手元 (SSH_CONNECTION も SSH_AUTH_SOCK も無い)
H="${work}/h/wsl"
mkdir -p "${H}"
d=$(agent open-wsl open attach default)
if [[ $(rc "${d}") == 0 && -z $(out "${d}") && ! -e ${H}/.ssh && ! -e ${H}/.local ]]; then
  ok "WSL の手元では何も出さず、固定名も記録の場所も作らない"
else
  ng "WSL の手元" "rc=$(rc "${d}") out=$(out "${d}") ls=$(ls -A "${H}") err=$(err "${d}")"
fi

# 15. start (herdr server を起こすだけ) は張り替えない
newhome start
A="${H}/.ssh/agent/s.t.sshd.start-A"
B="${H}/.ssh/agent/s.t.sshd.start-B"
mksock "${B}"
seed default "${A}" "${PC}"
d=$(agent open-start "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open start default)
if [[ $(rc "${d}") == 0 && $(out "${d}") == "${H}/.ssh/agent.sock" && $(link_of agent.sock) == "${A}" ]]; then
  ok "start は張り替えずに固定名を出す"
else
  ng "start" "rc=$(rc "${d}") out=$(out "${d}") link=$(link_of agent.sock) err=$(err "${d}")"
fi

# 16. session の名前が herdr の規則に外れる
newhome badname
B="${H}/.ssh/agent/s.t.sshd.badname-B"
mksock "${B}"
all_ok=1
for name in 'a/b' '..' '.' '' "$(printf 'x%.0s' {1..65})" 'a b'; do
  d=$(agent "open-badname-${#name}" "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" open attach "${name}")
  if [[ -z ${name} ]]; then
    # 名前を空で渡すのは使い方の誤り
    [[ $(rc "${d}") == 2 ]] || all_ok=0
  else
    [[ $(rc "${d}") == 0 && -z $(out "${d}") ]] || all_ok=0
  fi
done
if ((all_ok)) && [[ -z $(find "${H}/.ssh" -maxdepth 1 -name 'agent*.sock') ]]; then
  ok "session の名前が herdr の規則に外れたら何もしない (空の名前は exit 2)"
else
  ng "session の名前が規則外" "$(find "${H}/.ssh" -maxdepth 1 -name 'agent*.sock')"
fi

# 17. 使い方の誤り
d=$(agent open-usage open)
if [[ $(rc "${d}") == 2 ]]; then
  ok "open の引数が足りなければ exit 2"
else
  ng "open の引数が足りない" "rc=$(rc "${d}")"
fi

echo "== link (ssh-agent-link)"

# 18. 今の接続へ強制で向ける
newhome link
A="${H}/.ssh/agent/s.t.sshd.link-A"
B="${H}/.ssh/agent/s.t.sshd.link-B"
mksock "${A}"
mksock "${B}"
seed default "${A}" "${PC}"
d=$(agent link-force "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" link)
if [[ $(rc "${d}") == 0 && $(link_of agent.sock) == "${B}" && $(out "${d}") == *"${H}/.ssh/agent.sock -> ${B}"* ]]; then
  ok "link は、先が生きていて同じマシンでも今の接続へ向ける"
else
  ng "link の強制" "rc=$(rc "${d}") out=$(out "${d}") link=$(link_of agent.sock) err=$(err "${d}")"
fi

# 19. session は引数・HERDR_SESSION の順
d1=$(agent link-arg "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" HERDR_SESSION=s5 link s4)
d2=$(agent link-env "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" HERDR_SESSION=s5 link)
if [[ $(rc "${d1}") == 0 && $(link_of agent.s4.sock) == "${B}" && $(rc "${d2}") == 0 && $(link_of agent.s5.sock) == "${B}" ]]; then
  ok "link の session は引数、無ければ HERDR_SESSION"
else
  ng "link の session" "1: rc=$(rc "${d1}") s4=$(link_of agent.s4.sock) / 2: rc=$(rc "${d2}") s5=$(link_of agent.s5.sock)"
fi

# 20. pane の中と、張る先の無い shell では張らない
d1=$(agent link-pane "${conn}" "SSH_AUTH_SOCK=${H}/.ssh/agent.sock" "PJP_SSH_CLIENT=${PC}" link)
d2=$(agent link-none "${conn}" "PJP_SSH_CLIENT=${PC}" link)
l=$(link_of agent.sock)
if [[ $(rc "${d1}") == 1 && -n $(err "${d1}") && $(rc "${d2}") == 1 && -n $(err "${d2}") &&
${l} == "${B}" ]]; then
  ok "pane の中と張る先の無い shell では張らずに exit 1 (理由を stderr に出す)"
else
  ng "link を張らない shell" "1: rc=$(rc "${d1}") err=$(err "${d1}") / 2: rc=$(rc "${d2}") err=$(err "${d2}") / link=$(link_of agent.sock)"
fi

echo "== rc (~/.ssh/rc。接続を記録する)"

state_of() { printf '%s' "${H}/.local/state/pjp-agent-link"; }
# 記録のある key の値。$1: socket の basename、$2: key
rec_field() {
  local f k v
  f="$(state_of)/conn/$1"
  [[ -f ${f} ]] || return 0
  while IFS='=' read -r k v; do
    if [[ ${k} == "$2" ]]; then
      printf '%s' "${v}"
    fi
  done <"${f}"
}

# 21. 記録を書く。stdout は空
newhome rc
A="${H}/.ssh/agent/s.t.sshd.rc-A"
N="${H}/.ssh/agent/s.t.sshd.rc-N"
W="${H}/.ssh/agent/s.t.sshd.rc-W"
mksock "${A}"
mksock "${N}"
mksock "${W}"
d1=$(agent rc-pc "${conn}" "SSH_AUTH_SOCK=${A}" "PJP_SSH_CLIENT=${PC}" rc)
d2=$(agent rc-novalue "${conn}" "SSH_AUTH_SOCK=${N}" rc)
d3=$(agent rc-weird "${conn}" "SSH_AUTH_SOCK=${W}" 'PJP_SSH_CLIENT=%u@%L' rc)
opened=$(rec_field s.t.sshd.rc-A opened)
if [[ $(rc "${d1}") == 0 && -z $(out "${d1}") && $(rec_field s.t.sshd.rc-A sock) == "${A}" &&
$(rec_field s.t.sshd.rc-A client) == "${PC}" && ${opened} =~ ^[0-9]+$ ]]; then
  ok "rc は socket と値と開いた時刻を記録し、stdout には何も書かない"
else
  ng "rc の記録" "rc=$(rc "${d1}") out=$(out "${d1}") sock=$(rec_field s.t.sshd.rc-A sock) client=$(rec_field s.t.sshd.rc-A client) opened=${opened} err=$(err "${d1}")"
fi
if [[ $(rc "${d2}") == 0 && $(rec_field s.t.sshd.rc-N sock) == "${N}" && -z $(rec_field s.t.sshd.rc-N client) &&
$(rc "${d3}") == 0 && $(rec_field s.t.sshd.rc-W sock) == "${W}" && -z $(rec_field s.t.sshd.rc-W client) ]]; then
  ok "rc: 値が届いていない・展開されていない接続も記録し、値は空にする"
else
  ng "rc の値が届いていない接続" "N: client=$(rec_field s.t.sshd.rc-N client) / W: client=$(rec_field s.t.sshd.rc-W client)"
fi

# 21b. 同じ socket の 2 回目の rc (ControlMaster で多重化した接続の 2 つ目の session) は開いた時刻を変えない
o1=$(rec_field s.t.sshd.rc-A opened)
d=$(agent rc-pc-again "${conn}" "SSH_AUTH_SOCK=${A}" "PJP_SSH_CLIENT=${PC}" rc)
if [[ $(rc "${d}") == 0 && -n ${o1} && $(rec_field s.t.sshd.rc-A opened) == "${o1}" ]]; then
  ok "rc: 同じ socket の 2 回目の session では、開いた時刻を引き継ぐ (多重化した古い接続が新しく見えない)"
else
  ng "rc の 2 回目の session" "1 回目=${o1} 2 回目=$(rec_field s.t.sshd.rc-A opened)"
fi

# 22. 記録しないもの (forward が無い・SSH_AGENT_PID・SSH_CONNECTION が無い)
before=$(ls "$(state_of)/conn")
d1=$(agent rc-noforward "${conn}" "PJP_SSH_CLIENT=${PC}" rc)
L="${H}/.ssh/agent/s.t.agent.rc-L"
mksock "${L}"
d2=$(agent rc-agentpid "${conn}" "SSH_AUTH_SOCK=${L}" SSH_AGENT_PID=4242 rc)
d3=$(agent rc-local "SSH_AUTH_SOCK=${L}" rc)
if [[ $(rc "${d1}") == 0 && $(rc "${d2}") == 0 && $(rc "${d3}") == 0 && $(ls "$(state_of)/conn") == "${before}" ]]; then
  ok "rc: forward の無い接続・SSH_AGENT_PID・ssh でない shell は記録しない"
else
  ng "rc が記録しないもの" "$(ls "$(state_of)/conn")"
fi

# 23. X11: DISPLAY と cookie を xauth へ渡す (sshd(8) の SSHRC の例どおり)
printf 'MIT-MAGIC-COOKIE-1 c0ffee\n' >"${work}/cookie1"
printf 'MIT-MAGIC-COOKIE-1 beef\n' >"${work}/cookie2"
: >"${xauth_log}"
d1=$(agent_in "${work}/cookie1" rc-x11-local "${conn}" "SSH_AUTH_SOCK=${A}" DISPLAY=localhost:10.0 rc)
d2=$(agent_in "${work}/cookie2" rc-x11-host "${conn}" DISPLAY=host:3.0 rc)
want=$'args: -q -\nadd unix:10.0 MIT-MAGIC-COOKIE-1 c0ffee\nargs: -q -\nadd host:3.0 MIT-MAGIC-COOKIE-1 beef'
if [[ $(rc "${d1}") == 0 && -z $(out "${d1}") && $(rc "${d2}") == 0 && -z $(out "${d2}") && $(cat "${xauth_log}") == "${want}" ]]; then
  ok "rc: DISPLAY があれば cookie を xauth へ渡し (localhost:N は unix:N)、stdout は空"
else
  ng "rc の X11" "xauth: $(cat "${xauth_log}") / out1=$(out "${d1}") out2=$(out "${d2}")"
fi
: >"${xauth_log}"
d=$(agent rc-x11-none "${conn}" "SSH_AUTH_SOCK=${A}" rc)
if [[ $(rc "${d}") == 0 && ! -s ${xauth_log} ]]; then
  ok "rc: DISPLAY が無ければ xauth を呼ばない (stdin も読まない)"
else
  ng "rc の X11 なし" "xauth: $(cat "${xauth_log}")"
fi

# 23b. DISPLAY が無ければ stdin を読まない (読むと、閉じない stdin で固まる)
t0=$(date +%s)
d=$(agent_in <(sleep 5) rc-x11-block "${conn}" "SSH_AUTH_SOCK=${A}" rc)
t1=$(date +%s)
if [[ $(rc "${d}") == 0 ]] && ((t1 - t0 < 3)); then
  ok "rc: DISPLAY が無ければ、閉じない stdin でも待たずに終わる ($((t1 - t0)) 秒)"
else
  ng "rc の stdin" "rc=$(rc "${d}") 秒=$((t1 - t0))"
fi

# 24. 何も無い HOME (~/.local も無い)
H="${work}/h/rc-empty"
mkdir -p "${H}"
A="${work}/sock/s.t.sshd.rc-empty-A"
mksock "${A}"
d=$(agent rc-empty "${conn}" "SSH_AUTH_SOCK=${A}" "PJP_SSH_CLIENT=${PC}" rc)
if [[ $(rc "${d}") == 0 && $(rec_field s.t.sshd.rc-empty-A client) == "${PC}" && $(perm "$(state_of)") == 700 &&
$(perm "$(state_of)/conn") == 700 ]]; then
  ok "rc: 何も無い HOME でも記録の場所を 0700 で作って書く"
else
  ng "rc の何も無い HOME" "rc=$(rc "${d}") state=$(perm "$(state_of)") err=$(err "${d}")"
fi

# 25. OpenSSH 10.1 より前の形 (/tmp/ssh-XXXXXX/agent.<pid>)
newhome rc-old
O="${work}/tmpssh/ssh-AbCdEf/agent.4321"
mksock "${O}"
d=$(agent rc-old "${conn}" "SSH_AUTH_SOCK=${O}" "PJP_SSH_CLIENT=${PC}" rc)
if [[ $(rc "${d}") == 0 && $(rec_field agent.4321 sock) == "${O}" ]]; then
  ok "rc: /tmp/ssh-XXXXXX/agent.<pid> の形も socket の basename で記録する"
else
  ng "rc の古い形" "rc=$(rc "${d}") sock=$(rec_field agent.4321 sock) err=$(err "${d}")"
fi

echo "== watch (接続が増えた・減った)"

# 接続を開く (socket を作って rc で記録する)。$1: socket のパス、$2: PJP_SSH_CLIENT (省けば送らない)
open_conn() {
  mksock "$1"
  if [[ -n ${2:-} ]]; then
    agent "rc-${1##*/}" "${conn}" "SSH_AUTH_SOCK=$1" "PJP_SSH_CLIENT=$2" rc >/dev/null
  else
    agent "rc-${1##*/}" "${conn}" "SSH_AUTH_SOCK=$1" rc >/dev/null
  fi
}
close_conn() { rm -f "$1"; }
# herdr を開く。$1: session、$2: 開いた接続の socket、$3: PJP_SSH_CLIENT
attach() {
  agent "attach-$1-${2##*/}" "${conn}" "SSH_AUTH_SOCK=$2" "PJP_SSH_CLIENT=$3" open attach "$1" >/dev/null
}
watch() {
  agent "watch-$1" watch
}
# 2 つの固定名の先が期待どおりか。$1: 場面の説明、$2: default の先、$3: s2 の先
expect2() {
  local got
  got="default=$(link_of agent.sock) s2=$(link_of agent.s2.sock)"
  if [[ ${got} == "default=$2 s2=$3" ]]; then
    ok "$1"
  else
    ng "$1" "got:  ${got}"$'\n'"want: default=$2 s2=$3"
  fi
}

# 26. 場面 1 (cc-page 0003): 同じ PC から 4 本、別の PC から 2 本。socket の名前は開いた順と逆の並びにする
#     (9A・8B・7C・6D・5E・4X)。名前の順で選ぶと 1-5 で B ではなく C を選んで落ちる
newhome scene
p="${H}/.ssh/agent/s.t.sshd.scene"
open_conn "${p}-9A" "${PC}"
attach default "${p}-9A" "${PC}"
expect2 "場面 1-1: PC から hr default を開く (A)" "${p}-9A" "(無い)"
open_conn "${p}-8B" "${PC}"
attach s2 "${p}-8B" "${PC}"
expect2 "場面 1-2: PC から hr s2 を開く (B)。default は触らない" "${p}-9A" "${p}-8B"
open_conn "${p}-7C" "${PC}"
watch scene-3 >/dev/null
expect2 "場面 1-3: PC から素の ssh の端末 (C)。どちらの先も生きているので何もしない" "${p}-9A" "${p}-8B"
open_conn "${p}-4X" "${OTHER}"
watch scene-4 >/dev/null
expect2 "場面 1-4: 別の PC から素の ssh (X)。何もしない" "${p}-9A" "${p}-8B"
close_conn "${p}-9A"
watch scene-5 >/dev/null
expect2 "場面 1-5: default を detach (A が閉じる)。PC の B・C のうち一番古い B を借りる" "${p}-8B" "${p}-8B"
close_conn "${p}-8B"
watch scene-6 >/dev/null
expect2 "場面 1-6: s2 を detach (B が閉じる)。PC の接続は C だけなので両方が C" "${p}-7C" "${p}-7C"
open_conn "${p}-6D" "${PC}"
attach default "${p}-6D" "${PC}"
expect2 "場面 1-7: PC から hr default を開き直す (D)。C が生きていて同じ PC なので変えない" "${p}-7C" "${p}-7C"
close_conn "${p}-7C"
watch scene-8 >/dev/null
expect2 "場面 1-8: C の端末を閉じる。両方が D を借りる" "${p}-6D" "${p}-6D"
close_conn "${p}-6D"
watch scene-9 >/dev/null
expect2 "場面 1-9: default を detach (D が閉じる)。X は値が違うので借りない (dangling)" "${p}-6D" "${p}-6D"
open_conn "${p}-5E" "${OTHER}"
attach default "${p}-5E" "${OTHER}"
expect2 "場面 1-10: 別の PC から hr default を開く (E)。s2 は触らない" "${p}-5E" "${p}-6D"
close_conn "${p}-5E"
watch scene-11 >/dev/null
expect2 "場面 1-11: E が閉じる。default は同じ値の X を借り、s2 は持ち主が PC のままなので借りない" "${p}-4X" "${p}-6D"
if [[ $(owner_of default) == "${OTHER}" && $(owner_of s2) == "${PC}" ]]; then
  ok "場面 1: 借りても持ち主は変わらない (default は 10 で別の PC、s2 は PC のまま)"
else
  ng "場面 1 の持ち主" "default=$(owner_of default) s2=$(owner_of s2)"
fi
left=$(ls "$(state_of)/conn")
if [[ ${left} == "s.t.sshd.scene-4X" ]]; then
  ok "watch は死んだ socket の記録を消す (残るのは生きている X だけ)"
else
  ng "死んだ記録の掃除" "${left}"
fi

# 27. 覗くだけの接続
newhome peek
p="${H}/.ssh/agent/s.t.sshd.peek"
open_conn "${p}-A" "${PC}"
attach default "${p}-A" "${PC}"
open_conn "${p}-P" "${PC}"
watch peek-1 >/dev/null
l1=$(link_of agent.sock)
close_conn "${p}-P"
watch peek-2 >/dev/null
if [[ ${l1} == "${p}-A" && $(link_of agent.sock) == "${p}-A" ]]; then
  ok "覗くだけの接続は、開いても閉じても固定名の先を変えない"
else
  ng "覗くだけの接続" "開いた後=${l1} 閉じた後=$(link_of agent.sock)"
fi

# 28. 値が届いていない接続は借りない / 持ち主が空の固定名は借りない
newhome noval
p="${H}/.ssh/agent/s.t.sshd.noval"
seed default "${p}-A" "${PC}"
open_conn "${p}-N"
watch noval >/dev/null
l1=$(link_of agent.sock)
newhome noowner
p="${H}/.ssh/agent/s.t.sshd.noowner"
seed default "${p}-A" ""
open_conn "${p}-C" "${PC}"
open_conn "${p}-N"
watch noowner >/dev/null
if [[ ${l1} == "${work}/h/noval/.ssh/agent/s.t.sshd.noval-A" && $(link_of agent.sock) == "${p}-A" ]]; then
  ok "値が届いていない接続は借りず、持ち主が空の固定名には (値の届いていない接続も) 借りない"
else
  ng "値が届いていない" "noval=${l1} noowner=$(link_of agent.sock)"
fi

# 29. 返事をしない記録を飛ばす
newhome hangrec
p="${H}/.ssh/agent/s.t.sshd.hangrec"
seed default "${p}-A" "${PC}"
open_conn "${p}-H" "${PC}"
setmode "${p}-H" hang
open_conn "${p}-C" "${PC}"
t0=$(date +%s)
watch hangrec >/dev/null
t1=$(date +%s)
if [[ $(link_of agent.sock) == "${p}-C" ]] && ((t1 - t0 < 5)); then
  ok "返事をしない記録 (古い方) を 1 秒で見切って、次に古い生きている接続を借りる ($((t1 - t0)) 秒)"
else
  ng "返事をしない記録" "link=$(link_of agent.sock) 秒=$((t1 - t0))"
fi

# 30. 決めている間に attach が張り替えたら上書きしない (見張りと attach が同時に走る)
newhome race
p="${H}/.ssh/agent/s.t.sshd.race"
mksock "${p}-A" refuse
seed default "${p}-A" "${PC}"
open_conn "${p}-C" "${PC}"
mksock "${p}-E"
cat >"${work}/race-hook.sh" <<EOF
ln -sfn "${p}-E" "${H}/.ssh/agent.sock"
printf '%s\n' "${OTHER}" >"$(state_of)/owner/default"
EOF
d=$(agent race-watch FAKE_SSH_ADD_HOOK="${work}/race-hook.sh" FAKE_SSH_ADD_HOOK_MATCH=s.t.sshd.race-A watch)
if [[ ! -e ${work}/race-hook.sh && $(link_of agent.sock) == "${p}-E" && $(owner_of default) == "${OTHER}" ]]; then
  ok "watch が死んだ先を確かめている間に別のマシンから開き直されたら、前の持ち主の接続で上書きしない"
else
  ng "見張りと attach が同時" "hook=$([[ -e ${work}/race-hook.sh ]] && echo 残っている) link=$(link_of agent.sock) owner=$(owner_of default) err=$(err "${d}")"
fi

# 31. 1Password の先は触らない
newhome opwatch
p="${H}/.ssh/agent/s.t.sshd.opwatch"
seed default "${H}/.1password/agent.sock" local
open_conn "${p}-C" "${PC}"
watch opwatch >/dev/null
if [[ $(link_of agent.sock) == "${H}/.1password/agent.sock" ]]; then
  ok "固定名が手元の 1Password を指していれば、socket が無くても watch は触らない"
else
  ng "1Password の先" "link=$(link_of agent.sock)"
fi

# 32. watch は stdout に何も出さない。何も無い HOME でも通る
H="${work}/h/watch-empty"
mkdir -p "${H}"
d=$(agent watch-empty watch)
if [[ $(rc "${d}") == 0 && -z $(out "${d}") && -z $(err "${d}") ]]; then
  ok "watch は何も無い HOME でも通り、何も出さない"
else
  ng "watch の何も無い HOME" "rc=$(rc "${d}") out=$(out "${d}") err=$(err "${d}")"
fi

echo "== status"

# 33. 固定名と記録を出す
H="${work}/h/scene"
d=$(agent status status)
if [[ $(rc "${d}") == 0 && $(out "${d}") == *"${H}/.ssh/agent.sock -> ${H}/.ssh/agent/s.t.sshd.scene-4X"* &&
$(out "${d}") == *"${OTHER}"*"${H}/.ssh/agent/s.t.sshd.scene-4X"* ]]; then
  ok "status は固定名の先・持ち主と、記録にある接続を出す"
else
  ng "status" "rc=$(rc "${d}") out=$(out "${d}") err=$(err "${d}")"
fi

# 33b. status は PATH の herdr が包んだものか (pjp-agent-link を呼ぶか) を出す
mkdir -p "${work}/path-wrapped" "${work}/path-plain"
printf '#!%s\nexec @agentLink@-like pjp-agent-link open attach\n' "${BASH}" >"${work}/path-wrapped/herdr"
printf '#!%s\necho plain herdr\n' "${BASH}" >"${work}/path-plain/herdr"
chmod +x "${work}/path-wrapped/herdr" "${work}/path-plain/herdr"
d1=$(agent status-wrapped "PATH=${work}/path-wrapped:${PATH}" status)
d2=$(agent status-plain "PATH=${work}/path-plain:${PATH}" status)
if [[ $(out "${d1}") == *"${work}/path-wrapped/herdr (包んだもの)"* &&
$(out "${d2}") == *"${work}/path-plain/herdr (包んでいない"* ]]; then
  ok "status は PATH の herdr が包んだものかを出す (~/.local/bin などに包んでいない herdr があると気づける)"
else
  ng "status の herdr" "wrapped: $(out "${d1}" | grep herdr) / plain: $(out "${d2}" | grep herdr)"
fi

echo "== herdr を包む実行ファイル"

# 本物の herdr の代わり。argv・SSH_AUTH_SOCK・読んだ stdin を FAKE_HERDR_LOG に書き、HERDR-OUT を出す
mkdir -p "${work}/real" "${work}/shim"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
{
  printf 'argv:'
  printf ' [%s]' "$@"
  printf '\n'
  printf 'sock: %s\n' "${SSH_AUTH_SOCK-(無い)}"
  printf 'stdin: %s\n' "$(cat)"
} >"${FAKE_HERDR_LOG}"
printf 'HERDR-OUT'
EOF
} >"${work}/real/herdr"
chmod +x "${work}/real/herdr"
# pjp-agent-link の代わり: 包む前の script をそのまま流すもの・失敗するもの・返事をしないもの
printf '#!%s\nexec bash %q "$@"\n' "${BASH}" "${agent_sh}" >"${work}/shim/agent-ok"
printf '#!%s\necho /bogus\nexit 1\n' "${BASH}" >"${work}/shim/agent-fail"
printf '#!%s\nsleep 30\necho /bogus\n' "${BASH}" >"${work}/shim/agent-hang"
# stdin を読み切り、stderr に書いてから本物の script を流すもの (包む実行ファイルが </dev/null と 2>/dev/null で
# 守っていなければ、bridge の stdin を食い、stderr に漏れる)
printf '#!%s\ncat >/dev/null\necho noise >&2\nexec bash %q "$@"\n' "${BASH}" "${agent_sh}" >"${work}/shim/agent-noisy"
chmod +x "${work}/shim/agent-ok" "${work}/shim/agent-fail" "${work}/shim/agent-hang" "${work}/shim/agent-noisy"
# herdr.sh の置き換え (herdr.nix が store のパスにするもの) を、偽物と手元の timeout にした写しを作る。
# $1: 写しの名前、$2: pjp-agent-link の代わり
make_wrapper() {
  sed -e "s#@herdr@#${work}/real/herdr#g" -e "s#@agentLink@#$2#g" -e "s#@timeout@#$(command -v timeout)#g" \
    "${wrapper_sh}" >"${work}/shim/$1"
}
make_wrapper wrapper "${work}/shim/agent-ok"
make_wrapper wrapper-fail "${work}/shim/agent-fail"
make_wrapper wrapper-hang "${work}/shim/agent-hang"
make_wrapper wrapper-noisy "${work}/shim/agent-noisy"

# 包む実行ファイルを 1 回流す。引数は agent と同じ (先頭に写しの名前)。偽の herdr の書き留めは <置き場所>/herdr.log
wrap() {
  local w=$1 d="${work}/out/$2" envs=()
  shift 2
  while [[ $# -gt 0 && $1 =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    envs+=("$1")
    shift
  done
  mkdir -p "${d}"
  env -i HOME="${H}" PATH="${PATH}" FAKE_AGENT_MODES="${modes}" FAKE_SSH_ADD_LOG="${ssh_add_log}" \
    FAKE_HERDR_LOG="${d}/herdr.log" "${envs[@]}" bash "${work}/shim/${w}" "$@" \
    >"${d}/out" 2>"${d}/err" <"${agent_stdin:-/dev/null}"
  echo $? >"${d}/rc"
  printf '%s' "${d}"
}
# wrap と同じで、stdin を $1 のファイルにする
wrap_in() {
  local agent_stdin=$1
  shift
  wrap "$@"
}
hlog() { cat "$1/herdr.log" 2>/dev/null; }
hsock() { sed -n 's/^sock: //p' "$1/herdr.log" 2>/dev/null; }

# 34. 引数はそのまま渡る (何もしない呼び出し)
newhome wrap-args
B="${H}/.ssh/agent/s.t.sshd.wrap-args-B"
mksock "${B}"
d=$(wrap wrapper wrap-args "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" pane split --cwd 'a b' -- --session x)
if [[ $(rc "${d}") == 0 && $(out "${d}") == HERDR-OUT && $(hlog "${d}") == *'argv: [pane] [split] [--cwd] [a b] [--] [--session] [x]'* &&
$(hsock "${d}") == "${B}" && $(link_of agent.sock) == "(無い)" ]]; then
  ok "引数は空白入りも -- の後ろもそのまま渡り、何もしない呼び出しでは env も固定名も変えない"
else
  ng "引数の受け渡し" "rc=$(rc "${d}") out=$(out "${d}") log=$(hlog "${d}") err=$(err "${d}")"
fi

# 35. attach とみなす呼び出し
i=0
while IFS='|' read -r session_want args; do
  i=$((i + 1))
  newhome "wrap-attach-${i}"
  B="${H}/.ssh/agent/s.t.sshd.wrap-attach${i}-B"
  mksock "${B}"
  read -r -a argv <<<"${args}"
  d=$(wrap wrapper "wrap-attach-${i}" "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" "${argv[@]}")
  if [[ ${session_want} == default ]]; then
    f=agent.sock
  else
    f="agent.${session_want}.sock"
  fi
  if [[ $(rc "${d}") == 0 && $(hsock "${d}") == "${H}/.ssh/${f}" && $(link_of "${f}") == "${B}" &&
  $(owner_of "${session_want}") == "${PC}" ]]; then
    ok "attach とみなす: herdr ${args:-(サブコマンドなし)} は ${f} を開いた接続へ張り、SSH_AUTH_SOCK にする"
  else
    ng "attach とみなす: herdr ${args}" "rc=$(rc "${d}") sock=$(hsock "${d}") link=$(link_of "${f}") err=$(err "${d}")"
  fi
done <<'EOF'
default|
s2|--session s2
s2|--session=s2
s2|session attach s2
default|remote-client-bridge
default|remote-client-bridge --idle-timeout-v1
s2|--session s2 remote-client-bridge
s2|--session s2 remote-client-bridge --idle-timeout-v1
EOF

# 36. herdr server (起こすだけ) は決め直さずに固定名を渡す
newhome wrap-start
B="${H}/.ssh/agent/s.t.sshd.wrap-start-B"
mksock "${B}"
d=$(wrap wrapper wrap-start "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" server)
if [[ $(rc "${d}") == 0 && $(hsock "${d}") == "${H}/.ssh/agent.sock" && $(link_of agent.sock) == "(無い)" ]]; then
  ok "herdr server は決め直さずに SSH_AUTH_SOCK を固定名にする"
else
  ng "herdr server" "rc=$(rc "${d}") sock=$(hsock "${d}") link=$(link_of agent.sock) err=$(err "${d}")"
fi

# 37. 何もしない呼び出し
i=0
while IFS= read -r args; do
  i=$((i + 1))
  newhome "wrap-none-${i}"
  B="${H}/.ssh/agent/s.t.sshd.wrap-none${i}-B"
  mksock "${B}"
  read -r -a argv <<<"${args}"
  d=$(wrap wrapper "wrap-none-${i}" "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" "${argv[@]}")
  if [[ $(rc "${d}") == 0 && $(hsock "${d}") == "${B}" && -z $(find "${H}/.ssh" -maxdepth 1 -name 'agent*.sock') ]]; then
    ok "何もしない: herdr ${args} は env も固定名も変えない"
  else
    ng "何もしない: herdr ${args}" "rc=$(rc "${d}") sock=$(hsock "${d}") fixed=$(find "${H}/.ssh" -maxdepth 1 -name 'agent*.sock') err=$(err "${d}")"
  fi
done <<'EOF'
status client --json
--session s2 status server --json
server stop
server live-handoff --import-exe /x
pane list
--remote box.local
--remote=box.local --session s2
--version
--help
session attach help
session list
--remote-keybindings server
--session
--session=
EOF

# 38. HERDR_SESSION (pane の中の env など)
newhome wrap-env
B="${H}/.ssh/agent/s.t.sshd.wrap-env-B"
mksock "${B}"
d=$(wrap wrapper wrap-env "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" HERDR_SESSION=s7 remote-client-bridge)
if [[ $(rc "${d}") == 0 && $(hsock "${d}") == "${H}/.ssh/agent.s7.sock" && $(link_of agent.s7.sock) == "${B}" ]]; then
  ok "引数に session が無ければ HERDR_SESSION の session"
else
  ng "HERDR_SESSION" "rc=$(rc "${d}") sock=$(hsock "${d}") link=$(link_of agent.s7.sock) err=$(err "${d}")"
fi

# 39. bridge の stdin と stdout はそのまま (herdr の通信)
newhome wrap-stdio
B="${H}/.ssh/agent/s.t.sshd.wrap-stdio-B"
mksock "${B}"
printf 'PING' >"${work}/ping"
d=$(wrap_in "${work}/ping" wrapper wrap-stdio "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" remote-client-bridge)
if [[ $(rc "${d}") == 0 && $(out "${d}") == HERDR-OUT && -z $(err "${d}") && $(hlog "${d}") == *'stdin: PING'* &&
$(link_of agent.sock) == "${B}" ]]; then
  ok "bridge の stdin は本物の herdr が全部読み、stdout には本物の herdr の出力だけが出る (stderr も空)"
else
  ng "bridge の stdin と stdout" "out=$(out "${d}") err=$(err "${d}") log=$(hlog "${d}")"
fi

# 39b. pjp-agent-link が stdin を読もうとしても・stderr に書いても、bridge の stdin と stderr には届かない
newhome wrap-noisy
B="${H}/.ssh/agent/s.t.sshd.wrap-noisy-B"
mksock "${B}"
d=$(wrap_in "${work}/ping" wrapper-noisy wrap-noisy "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" remote-client-bridge)
if [[ $(rc "${d}") == 0 && $(out "${d}") == HERDR-OUT && -z $(err "${d}") && $(hlog "${d}") == *'stdin: PING'* &&
$(link_of agent.sock) == "${B}" ]]; then
  ok "pjp-agent-link には </dev/null と 2>/dev/null で呼ぶので、bridge の stdin を食わず stderr にも漏れない"
else
  ng "bridge の stdin と stderr の守り" "out=$(out "${d}") err=$(err "${d}") log=$(hlog "${d}")"
fi

# 40. WSL の手元
newhome wrap-wsl
d=$(wrap wrapper wrap-wsl)
if [[ $(rc "${d}") == 0 && $(hsock "${d}") == "(無い)" && -z $(find "${H}/.ssh" -maxdepth 1 -name 'agent*.sock') ]]; then
  ok "WSL の手元では SSH_AUTH_SOCK を足さない"
else
  ng "WSL の手元" "rc=$(rc "${d}") sock=$(hsock "${d}")"
fi

# 41. pjp-agent-link が失敗しても・返事をしなくても herdr は起きる
newhome wrap-fail
B="${H}/.ssh/agent/s.t.sshd.wrap-fail-B"
mksock "${B}"
d1=$(wrap wrapper-fail wrap-fail "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" remote-client-bridge)
t0=$(date +%s)
d2=$(wrap wrapper-hang wrap-hang "${conn}" "SSH_AUTH_SOCK=${B}" "PJP_SSH_CLIENT=${PC}" remote-client-bridge)
t1=$(date +%s)
if [[ $(rc "${d1}") == 0 && $(hsock "${d1}") == "${B}" && $(out "${d1}") == HERDR-OUT && $(rc "${d2}") == 0 &&
$(hsock "${d2}") == "${B}" ]] && ((t1 - t0 < 20)); then
  ok "pjp-agent-link が失敗しても・返事をしなくても ($((t1 - t0)) 秒で打ち切る)、元の env で herdr を起こす"
else
  ng "pjp-agent-link の失敗" "1: rc=$(rc "${d1}") sock=$(hsock "${d1}") / 2: rc=$(rc "${d2}") sock=$(hsock "${d2}") 秒=$((t1 - t0))"
fi

echo "== starship の PJP_SSH_CLIENT の警告"

# starship.toml の custom.pjp_ssh_client の when と shell を取り出す
python3 -I -c '
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    m = tomllib.load(f)["custom"]["pjp_ssh_client"]
open(sys.argv[2], "w").write(m["when"])
print(" ".join(m.get("shell", [])))
' "${starship_toml}" "${work}/when.sh" >"${work}/when-shell"
if [[ $(cat "${work}/when-shell") == sh ]]; then
  ok "custom.pjp_ssh_client は sh で判定する (fish を起こさない)"
else
  ng "custom.pjp_ssh_client の shell" "$(cat "${work}/when-shell")"
fi

# when を流して、警告を出すか (0) 出さないか (1) を返す。引数は env に渡す VAR=値…
shows() {
  env -i HOME="${H}" PATH="${PATH}" FAKE_AGENT_MODES="${modes}" FAKE_SSH_ADD_LOG="${ssh_add_log}" "$@" \
    sh "${work}/when.sh" </dev/null >/dev/null 2>&1
}
# 警告を出す・出さないの期待と結果を比べる。$1: 説明、$2: show / hide、残り: env に渡す VAR=値…
expect_warn() {
  local what=$1 want=$2 got=hide
  shift 2
  if shows "$@"; then
    got=show
  fi
  if [[ ${got} == "${want}" ]]; then
    ok "starship: ${what}"
  else
    ng "starship: ${what}" "want=${want} got=${got}"
  fi
}

newhome starship
seed default "${H}/.ssh/agent/s.t.sshd.starship-A"
: >"${ssh_add_log}"
expect_warn "ssh で入った shell で値が無ければ出す" show "${conn}"
expect_warn "ssh で入った shell で値が展開されていない (%u@%L) なら出す" show "${conn}" 'PJP_SSH_CLIENT=%u@%L'
expect_warn "ssh で入った shell で値があれば出さない" hide "${conn}" "PJP_SSH_CLIENT=${PC}"
expect_warn "herdr の pane で固定名の持ち主の記録が無ければ出す" show "${conn}" "PJP_SSH_CLIENT=${PC}" "SSH_AUTH_SOCK=${H}/.ssh/agent.sock"
seed default "${H}/.ssh/agent/s.t.sshd.starship-A" ""
expect_warn "herdr の pane で固定名の持ち主が空なら出す (pane の env の値は見ない)" show "${conn}" "PJP_SSH_CLIENT=${PC}" "SSH_AUTH_SOCK=${H}/.ssh/agent.sock"
seed default "${H}/.ssh/agent/s.t.sshd.starship-A" "${PC}"
expect_warn "herdr の pane で固定名の持ち主があれば出さない (pane の env に値が無くても)" hide "${conn}" "SSH_AUTH_SOCK=${H}/.ssh/agent.sock"
seed s2 "${H}/.ssh/agent/s.t.sshd.starship-B" ""
expect_warn "session ごと: s2 の pane は s2 の持ち主を見る" show "SSH_AUTH_SOCK=${H}/.ssh/agent.s2.sock"
seed default "${H}/.1password/agent.sock" local
expect_warn "手元の 1Password から開いた pane (持ち主 local) では出さない" hide "SSH_AUTH_SOCK=${H}/.ssh/agent.sock"
expect_warn "手元の shell では出さない" hide "SSH_AUTH_SOCK=${H}/.1password/agent.sock"
expect_warn "WSL の手元の shell では出さない" hide

# 本物の starship で読ませる (TOML の書き方と、format に出る文言)
if command -v starship &>/dev/null; then
  starship_out() {
    env -i HOME="${H}" PATH="${PATH}" FAKE_AGENT_MODES="${modes}" FAKE_SSH_ADD_LOG="${ssh_add_log}" \
      STARSHIP_CONFIG="${starship_toml}" STARSHIP_SHELL=bash STARSHIP_CACHE="${work}/starship-cache" "$@" \
      starship module custom.pjp_ssh_client </dev/null 2>/dev/null
  }
  s1=$(starship_out "${conn}")
  s2=$(starship_out "${conn}" "PJP_SSH_CLIENT=${PC}")
  if [[ ${s1} == *"PJP_SSH_CLIENT なし"* && -z ${s2} ]]; then
    ok "本物の starship でも、値の無い ssh の shell でだけ「PJP_SSH_CLIENT なし」を出す"
  else
    ng "本物の starship" "値なし: $(printf '%q' "${s1}") / 値あり: $(printf '%q' "${s2}")"
  fi
else
  ng "本物の starship" "starship が見つからない"
fi
if [[ ! -s ${ssh_add_log} ]]; then
  ok "starship: 判定で ssh-add を呼ばない"
else
  ng "starship が ssh-add を呼んだ" "$(cat "${ssh_add_log}")"
fi

echo
echo "pass: ${pass}  fail: ${fail}"
((fail == 0))
