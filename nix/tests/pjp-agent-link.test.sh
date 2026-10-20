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
#     0700 で作って通る
#   - PJP_SSH_CLIENT は、空・% を含む (展開されていない %u@%L)・制御文字を含む・local なら届いていない扱い
#   - open の「開いた接続」: ssh の shell は自分の socket と値、ssh -a と SSH_AGENT_PID の shell は張り替えずに
#     固定名だけ、herdr の pane は同じ session なら何もせず別の session なら pane の固定名の先と持ち主で張る、
#     手元の 1Password は socket が無くても張って持ち主 local、WSL の手元は何も出さず何も作らない。start は
#     張り替えずに固定名を出す。session の名前が herdr の規則に外れたら何もしない
#   - link (ssh-agent-link) は今の接続へ強制で向ける。session は引数・HERDR_SESSION・default の順。pane の中と
#     張る先の無い shell では張らずに exit 1
#
# ## 作り
#
# socket は python3 で bind して置く (listen しない。生死は偽の ssh-add が決める)。偽の ssh-add は SSH_AUTH_SOCK の
# basename で ${FAKE_AGENT_MODES}/<basename> を引き、keys (exit 0)・empty (exit 1)・hang (返事をしない)・refuse
# (exit 2) のふりをする。socket が無ければ exit 2。script は env -i で、HOME と PATH と渡した変数だけで流す。
# unix socket のパスは 108 byte までなので、TMPDIR が長いときは /tmp に作業場所を作る。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
pkgdir=$(realpath -- "${1:-${here}/../pkgs/pjp-agent-link}")
agent_sh="${pkgdir}/pjp-agent-link.sh"

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

# 偽の ssh-add。問い合わせた socket を FAKE_SSH_ADD_LOG に書き留める。FAKE_SSH_ADD_HOOK の script があり、
# 問い合わせた socket の basename が FAKE_SSH_ADD_HOOK_MATCH なら、1 回だけそれを流してから答える
bin="${work}/bin"
modes="${work}/modes"
mkdir -p "${bin}" "${modes}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
s=${SSH_AUTH_SOCK-}
printf '%s\n' "${s}" >>"${FAKE_SSH_ADD_LOG}"
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
# 持ち主のファイルを置かない)
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
    printf '%s\n' "$3" >"${H}/.local/state/pjp-agent-link/owner/$1"
  fi
}

# script を 1 回流す。$1: 置き場所の名前、続けて env に渡す VAR=値… と、script の引数。
# env -i で、HOME と PATH と渡した変数だけにする。stdout・stderr・終了コードを <置き場所>/{out,err,rc} に書き、
# 置き場所を返す
agent() {
  local d="${work}/out/$1" envs=()
  shift
  while [[ $# -gt 0 && $1 == *=* ]]; do
    envs+=("$1")
    shift
  done
  mkdir -p "${d}"
  env -i HOME="${H}" PATH="${PATH}" FAKE_AGENT_MODES="${modes}" FAKE_SSH_ADD_LOG="${ssh_add_log}" \
    "${envs[@]}" bash "${agent_sh}" "$@" >"${d}/out" 2>"${d}/err" </dev/null
  echo $? >"${d}/rc"
  printf '%s' "${d}"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }

link_of() { readlink "${H}/.ssh/$1" 2>/dev/null || echo "(無い)"; }
owner_of() {
  if [[ -f ${H}/.local/state/pjp-agent-link/owner/$1 ]]; then
    cat "${H}/.local/state/pjp-agent-link/owner/$1"
  else
    echo "(無い)"
  fi
}
perm() { stat -c %a "$1" 2>/dev/null || echo "(無い)"; }

PC=polle@PJP-RAIDEN
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
for v in '%u@%L' $'polle@PJP-RAIDEN\nx' 'local'; do
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

echo
echo "pass: ${pass}  fail: ${fail}"
((fail == 0))
