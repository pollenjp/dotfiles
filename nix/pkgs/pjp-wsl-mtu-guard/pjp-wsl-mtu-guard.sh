#!/usr/bin/env bash
# shellcheck shell=bash
#
# WSL の eth0 の MTU を上限まで下げ続ける見張り (dotfiles.wsl.mtuGuard)。
#
#   pjp-wsl-mtu-guard <interface> <上限の MTU> [<見直す秒数>]
#
# VPN のトンネルの実効 MTU が interface の MTU より小さく、トンネルの奥から返る ICMP (Fragmentation Needed) が
# WSL (NAT) まで届かないと、実効 MTU を超える大きさのパケットが黙って捨てられ続ける (PMTU ブラックホール)。
# 小さい通信は通るので、つながっているのに大きな送信だけが止まる。WSL はホスト側のネットワークが変わるたびに
# (VPN の接続・切断など) eth0 の MTU を設定し直すので、起動時に 1 回下げるだけでは足りない。
#
# 起動したときに 1 回と、ip monitor link のイベントのたびに、interface の MTU が上限を超えていたら上限まで下げる。
# 上げはしない。下げたときだけ「eth0 mtu 1392 -> 1350」の 1 行を stdout に出す (systemd の下では journal に残る)。
# interface がまだ無ければ、できたイベントで下げる。ip monitor link が終わったら (エラーのときだけ終わる)、この
# script も 1 で終わり、systemd が起こし直す。
#
# 監視を始める前の変化を取りこぼさないよう、ip monitor link を先に起こしてから 1 回目を下げる。ip monitor が
# netlink を購読し終えた合図は無いので、イベントが来なくても <見直す秒数> (既定 30) ごとに見直す。
#
# MTU を変えるには root (CAP_NET_ADMIN) が要る。nix/pkgs/pjp-wsl-mtu-guard/default.nix が writeShellApplication で
# 包み (iproute2 を PATH の先頭に置く)、home/modules/wsl-mtu-guard.nix が system の unit の ExecStart にする。
# 単体でも bash pjp-wsl-mtu-guard.sh で動く (nix/tests/pjp-wsl-mtu-guard.test.sh が偽の ip でそうして流す)。

set -euo pipefail

usage() {
  cat <<'EOS'
使い方: pjp-wsl-mtu-guard <interface> <上限の MTU> [<見直す秒数>]
  interface の MTU が上限を超えるたびに、上限まで下げる (上げはしない)。root で動かす。
  見直す秒数 (既定 30) ごとに、イベントが来なくても見直す。
EOS
}

if [[ ${1-} == -h || ${1-} == --help ]]; then
  usage
  exit 0
fi
# 見直す秒数は正の数だけ (0 だと read -t が待たずに返り、ip を打ち続ける)
if (($# < 2 || $# > 3)) || [[ -z $1 || ! $2 =~ ^[0-9]+$ || ! ${3:-30} =~ ^[0-9]+([.][0-9]+)?$ || ! ${3:-30} =~ [1-9] ]]; then
  usage >&2
  exit 2
fi
dev=$1
max=$2
interval=${3:-30}

# interface の MTU が上限を超えていたら下げる。interface が無い・読めない・下げられないときも 0 を返す
# (下げられなかったわけは ip の stderr に出る。次のイベントか見直しで下げ直す)
clamp() {
  local out cur re=' mtu ([0-9]+)'
  out=$(ip -o link show dev "${dev}" 2>/dev/null) || return 0
  [[ ${out} =~ ${re} ]] || return 0
  cur=${BASH_REMATCH[1]}
  if ((cur > max)) && ip link set dev "${dev}" mtu "${max}"; then
    echo "${dev} mtu ${cur} -> ${max}"
  fi
  return 0
}

exec {events}< <(exec ip monitor link)
clamp
while :; do
  # 行が来た (0) か、見直す秒数が過ぎた (128 より大きい) なら見直す。ip monitor が終わった (1) なら抜ける
  rc=0
  read -r -t "${interval}" -u "${events}" _ || rc=$?
  if ((rc == 0 || rc > 128)); then
    clamp
  else
    break
  fi
done
echo "ip monitor link が終わりました (systemd が起こし直します)" >&2
exit 1
