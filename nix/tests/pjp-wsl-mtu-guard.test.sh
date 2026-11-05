#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/pjp-wsl-mtu-guard/pjp-wsl-mtu-guard.sh (WSL の eth0 の MTU を上限まで下げ続ける見張り) を、偽の ip で確かめる。
#
#   bash nix/tests/pjp-wsl-mtu-guard.test.sh [<pjp-wsl-mtu-guard.sh のパス>]
#
# flake の checks (pjp-wsl-mtu-guard-test) が Nix のサンドボックスで流す。使うのは bash と coreutils・grep だけ
# (本物の ip は使わない。MTU を変えるには root が要る)。
#
# ## 確かめること
#
#   - 起動したときに interface の MTU が上限を超えていれば上限まで下げ、「eth0 mtu 1392 -> 1350」の 1 行を出す。
#     ip monitor link が終わったら (エラーのときだけ終わる)、それを stderr に出して 1 で終わる (systemd が起こし直す)
#   - 上限ちょうど・上限より小さい MTU には触らない (上げもしない)
#   - ip monitor link のイベントのたびに見直し、上限を超えていれば下げる。1 回の変化に ip monitor は 2 行を出すが、
#     下げるのは 1 回だけ
#   - interface がまだ無いとき (WSL の起動直後) は、ip のエラーを出さずに待ち、できたイベントで下げる
#   - ip link set が失敗しても止まらず、次のイベントで下げ直す
#   - イベントが来なくても、見直す秒数ごとに見直して下げる (監視を始める前の変化を取りこぼしても直る)。見直す秒数が
#     過ぎる前に ip monitor が終われば、イベントの無い変化は見ない
#   - 引数が足りない・上限が数でない・見直す秒数が正の数でないときは、ip を呼ばずに使い方を stderr に出して 2 で終わる。
#     --help は使い方を stdout に出して 0
#
# ## 作り
#
# 偽の ip は状態のディレクトリ (FAKE_IP_DIR) で動く。<dir>/mtu が今の MTU (無ければ interface が無い)。
#   ip -o link show dev eth0       本物と同じ形の 1 行を出す (<dir>/shown に印を付ける)。interface が無ければ 1
#   ip link set dev eth0 mtu <値>  <dir>/calls に書き、FAKE_IP_SET_FAIL があれば 2、無ければ <dir>/mtu を値にする
#   ip monitor link                <dir>/calls に書き、<dir>/events を 1 行ずつ流してから 0 で終わる:
#                                    mtu <値>     MTU を変え、本物と同じ 2 行のイベントを出す
#                                    quiet <値>   イベントを出さずに MTU を変える
#                                    sleep <秒>   待つ
#                                    wait-shown   見張りが 1 回目の見直しで MTU を読むまで待つ (順番をタイミングに頼らない)
# shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../pkgs/pjp-wsl-mtu-guard/pjp-wsl-mtu-guard.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-wsl-mtu-guard-test.XXXXXX")
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

mkdir -p "${work}/bin"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
d=${FAKE_IP_DIR:?}
link_line() {
  printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu %s qdisc mq state UP mode DEFAULT group default qlen 1000\\    link/ether 00:15:5d:00:00:01 brd ff:ff:ff:ff:ff:ff\n' "$1"
}
case "$*" in
  "-o link show dev eth0")
    : >"${d}/shown"
    if [[ ! -r ${d}/mtu ]]; then
      echo 'Device "eth0" does not exist.' >&2
      exit 1
    fi
    link_line "$(<"${d}/mtu")"
    ;;
  "link set dev eth0 mtu "*)
    printf '%s\n' "$*" >>"${d}/calls"
    if [[ -n ${FAKE_IP_SET_FAIL-} ]]; then
      echo 'RTNETLINK answers: Operation not permitted' >&2
      exit 2
    fi
    printf '%s\n' "${!#}" >"${d}/mtu"
    ;;
  "monitor link")
    printf '%s\n' "$*" >>"${d}/calls"
    [[ -r ${d}/events ]] || exit 0
    while read -r op v; do
      case ${op} in
        mtu)
          printf '%s\n' "${v}" >"${d}/mtu"
          printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu %s qdisc mq state UP group default \n' "${v}"
          printf '    link/ether 00:15:5d:00:00:01 brd ff:ff:ff:ff:ff:ff\n'
          ;;
        quiet) printf '%s\n' "${v}" >"${d}/mtu" ;;
        sleep) sleep "${v}" ;;
        wait-shown)
          for _ in $(seq 200); do
            [[ ! -e ${d}/shown ]] || break
            sleep 0.05
          done
          ;;
      esac
    done <"${d}/events"
    ;;
  *)
    echo "偽の ip が知らない引数: $*" >&2
    exit 99
    ;;
esac
EOF
} >"${work}/bin/ip"
chmod +x "${work}/bin/ip"

# 1 ケースぶんの状態のディレクトリを作り、その場所を出す。$1: 名前、$2: 起動時の MTU (- なら interface が無い)、
# 残り: ip monitor link が流す events の行
new_case() {
  local c="${work}/$1"
  mkdir -p "${c}"
  if [[ $2 != - ]]; then
    printf '%s\n' "$2" >"${c}/mtu"
  fi
  shift 2
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" >"${c}/events"
  fi
  : >"${c}/calls"
  echo "${c}"
}

# $1: ケース、残り: 見張りの引数。stdout・stderr・終了コードを <ケース>/{out,err,rc} に残す
run() {
  local c=$1
  shift
  FAKE_IP_DIR=${c} PATH="${work}/bin:${PATH}" timeout 20 "${BASH}" "${script}" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}

rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }
sets() { grep -c '^link set ' "$1/calls"; }
# ip monitor link を起こし、それが終わるまで走って 1 で終わったか (何もしないケースが、script が無くて通らないように)
ran_to_end() { [[ $(rc "$1") == 1 ]] && grep -qx 'monitor link' "$1/calls" && grep -q 'ip monitor link が終わりました' "$1/err"; }
show() { printf 'rc=%s\nout=%s\nerr=%s\ncalls=%s' "$(rc "$1")" "$(out "$1")" "$(err "$1")" "$(cat "$1/calls")"; }

echo "== pjp-wsl-mtu-guard (${script})"

c=$(new_case start 1392)
run "${c}" eth0 1350
if [[ $(out "${c}") == 'eth0 mtu 1392 -> 1350' && $(sets "${c}") == 1 && $(cat "${c}/mtu") == 1350 && $(rc "${c}") == 1 ]] \
  && grep -q 'ip monitor link が終わりました' "${c}/err"; then
  ok "起動時に上限を超えていれば下げて 1 行出し、ip monitor が終われば 1 で終わる"
else
  ng "起動時に下げる" "$(show "${c}")"
fi

for m in 1350 1280; do
  c=$(new_case keep-${m} "${m}")
  run "${c}" eth0 1350
  if [[ -z $(out "${c}") && $(sets "${c}") == 0 && $(cat "${c}/mtu") == "${m}" ]] && ran_to_end "${c}"; then
    ok "上限 1350 で MTU ${m} には触らない"
  else
    ng "MTU ${m} に触らない" "$(show "${c}")"
  fi
done

c=$(new_case event 1350 wait-shown 'mtu 1420')
run "${c}" eth0 1350
if [[ $(out "${c}") == 'eth0 mtu 1420 -> 1350' && $(sets "${c}") == 1 && $(cat "${c}/mtu") == 1350 ]]; then
  ok "イベントで上限を超えたら下げる (2 行のイベントでも下げるのは 1 回)"
else
  ng "イベントで下げる" "$(show "${c}")"
fi

c=$(new_case appear - wait-shown 'mtu 1500')
run "${c}" eth0 1350
if [[ $(out "${c}") == 'eth0 mtu 1500 -> 1350' ]] && ! grep -q 'does not exist' "${c}/err"; then
  ok "interface が無ければ ip のエラーを出さずに待ち、できたイベントで下げる"
else
  ng "interface が後からできる" "$(show "${c}")"
fi

c=$(new_case set-fails 1392 wait-shown 'mtu 1400')
FAKE_IP_SET_FAIL=1 run "${c}" eth0 1350
if [[ $(sets "${c}") -ge 2 && -z $(out "${c}") && $(rc "${c}") == 1 ]] \
  && grep -q 'Operation not permitted' "${c}/err" && grep -q 'ip monitor link が終わりました' "${c}/err"; then
  ok "ip link set が失敗しても止まらず、次のイベントで下げ直す (失敗は ip の stderr だけ)"
else
  ng "下げられなくても続ける" "$(show "${c}")"
fi

c=$(new_case recheck 1350 wait-shown 'quiet 1392' 'sleep 1')
run "${c}" eth0 1350 0.2
if [[ $(out "${c}") == 'eth0 mtu 1392 -> 1350' && $(cat "${c}/mtu") == 1350 ]]; then
  ok "イベントが来なくても、見直す秒数ごとに見直して下げる"
else
  ng "見直しで下げる" "$(show "${c}")"
fi

c=$(new_case no-recheck 1350 wait-shown 'quiet 1392' 'sleep 1')
run "${c}" eth0 1350
if [[ -z $(out "${c}") && $(sets "${c}") == 0 ]] && ran_to_end "${c}"; then
  ok "見直す秒数 (既定 30) が過ぎる前に ip monitor が終われば、イベントの無い変化は見ない"
else
  ng "見直す秒数の前" "$(show "${c}")"
fi

i=0
for args in '' 'eth0' 'eth0 13x0' 'eth0 1350 x' 'eth0 1350 0' 'eth0 1350 30 extra'; do
  i=$((i + 1))
  c=$(new_case usage-${i} 1392)
  # shellcheck disable=SC2086 # 空白で引数に割る
  run "${c}" ${args}
  if [[ $(rc "${c}") == 2 && -z $(out "${c}") && ! -s ${c}/calls && $(cat "${c}/mtu") == 1392 ]] && grep -q '使い方' "${c}/err"; then
    ok "引数 [${args}] は ip を呼ばずに使い方を出して 2"
  else
    ng "引数 [${args}]" "$(show "${c}")"
  fi
done

c=$(new_case help 1392)
run "${c}" --help
if [[ $(rc "${c}") == 0 && ! -s ${c}/calls ]] && grep -q '使い方' "${c}/out"; then
  ok "--help は使い方を stdout に出して 0"
else
  ng "--help" "$(show "${c}")"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
