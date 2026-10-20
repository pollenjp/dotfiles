#!/usr/bin/env bash
# shellcheck shell=bash
#
# herdr の session ごとの固定名 (~/.ssh/agent.sock・~/.ssh/agent.<session>.sock) の向け先を決める (ADR 025)。
#
#   pjp-agent-link open attach <session>  herdr を開いた。開いた接続へ向けるかを決め、SSH_AUTH_SOCK に入れるパスを出す
#   pjp-agent-link open start <session>   herdr の server を起こすだけ。決め直さずに、SSH_AUTH_SOCK に入れるパスを出す
#   pjp-agent-link link [<session>]       今の接続へ強制で向ける (ssh-agent-link。手で打つ逃げ道)
#
# open は herdr を包む実行ファイル (herdr.sh) が呼ぶ (nix/home/modules/agent-link.nix)。
#
# ## なぜ固定名か
#
# herdr の server は起こした接続の env を抱えて常駐し、pane はそれを継ぐ。sshd が接続ごとに作る agent の socket は
# 接続が閉じると消え、実行中のプロセスの env は外から書き換えられない。そこで server と pane には session ごとの
# 固定名 (symlink) を渡し、その先だけを生きている接続の socket へ向け直す (ADR 008 の形を session ごとにしたもの)。
#
# ## 向け先の決め方
#
#   attach (herdr を開いた)  今の先が生きていて、持ち主 (張ったときの PJP_SSH_CLIENT) が開いた接続の値と同じなら
#                           変えない (切断前の接続を優先する)。死んでいる・持ち主が分からない・値が違う・値が
#                           届いていないなら、開いた接続へ向けて持ち主をその値にする。開いた session の固定名だけ
#   link (手で打つ)          今の session の固定名を今の接続へ強制で向ける
#
# 「生きている」は ssh-add -l が 1 秒以内に 0 か 1 を返すこと (回線断で返事をしない socket で固まらない)。
# PJP_SSH_CLIENT は、空・% を含む (OpenSSH 10.0 より古い ssh は SetEnv の %u@%L を展開せずに送る)・制御文字を含む・
# local (手元の 1Password の値) なら「届いていない」として扱い、どの接続とも同じマシンとみなさない。
#
# 「開いた接続」は呼んだ env で決める:
#
#   SSH_AUTH_SOCK が固定名 (herdr の pane)   別の session を開くなら、その固定名の先と持ち主。同じ session なら無し
#   SSH_CONNECTION がある                    SSH_AUTH_SOCK が socket で SSH_AGENT_PID が空なら、その socket と値。
#                                            ssh -a・フォールバックのローカル agent は無し (固定名は渡す)
#   手元で SSH_AUTH_SOCK が 1Password        ~/.1password/agent.sock と local (生死は見ない。ADR 022)
#   それ以外 (WSL の手元など)                何もしない (何も出さない)
#
# ## 記録 (~/.local/state/pjp-agent-link。0700。XDG_STATE_HOME は見ない)
#
#   owner/<session>   固定名ごとの持ち主 (1 行。無い・空は「分からない」)
#   log               張り替えのたびに 1 行 (256 KiB を超えたら後ろの 1000 行にする)
#   lock              張り替えの排他 (flock)
#   tmp/              書きかけ (rename で入れ替える)
#
# 張り替えは、ssh-add で生死を見る間は lock を持たず、入れ替える直前に lock を取って「決めたときの先と持ち主の
# まま」かを見てから、一時名の symlink を rename で入れ替える (固定名が消える瞬間を作らない)。変わっていたら
# 決め直す。
#
# ## stdout
#
# open は SSH_AUTH_SOCK に入れるパスの 1 行だけを出す (包む実行ファイルが $(…) で受ける)。
#
# nix/pkgs/pjp-agent-link/default.nix が writeShellApplication で PATH に置く (coreutils・openssh・flock)。
# 単体でも bash pjp-agent-link.sh で動く (nix/tests/pjp-agent-link.test.sh がそうして流す)。

set -euo pipefail
umask 077

prog=pjp-agent-link
ssh_dir="${HOME}/.ssh"
state="${HOME}/.local/state/pjp-agent-link"
onepassword="${HOME}/.1password/agent.sock"
# 手元の 1Password から開いたときの持ち主。%u@%L の形 (user@host) にならない値にする
local_client=local

usage() {
  cat <<'EOS'
herdr の session ごとの固定名 (~/.ssh/agent.sock・~/.ssh/agent.<session>.sock) の向け先を決める。

使い方:
  pjp-agent-link open attach <session>   herdr を開いた接続から呼ぶ (herdr を包む実行ファイルが打つ)
  pjp-agent-link open start <session>    herdr の server を起こすだけの呼び出しから呼ぶ (決め直さない)
  pjp-agent-link link [<session>]        今の接続へ強制で向ける (ssh-agent-link。session は省けば HERDR_SESSION か default)
EOS
}

# 記録の場所と ~/.ssh を作る (umask 077 なので 0700)
ensure_dirs() {
  mkdir -p -- "${ssh_dir}" "${state}/owner" "${state}/tmp"
}

# herdr の session の名前の規則 (英数字と . _ -、64 byte まで、. と .. を除く)
valid_session() {
  local s=$1
  ((${#s} >= 1 && ${#s} <= 64)) && [[ ${s} != . && ${s} != .. && ${s} =~ ^[A-Za-z0-9._-]+$ ]]
}

fixed_path() {
  if [[ $1 == default ]]; then
    printf '%s\n' "${ssh_dir}/agent.sock"
  else
    printf '%s\n' "${ssh_dir}/agent.$1.sock"
  fi
}

# パスが固定名なら、その session の名前を出す (固定名でなければ 1)
session_of_fixed() {
  local p=$1 s
  if [[ ${p} == "${ssh_dir}/agent.sock" ]]; then
    echo default
    return 0
  fi
  case ${p} in
    "${ssh_dir}"/agent.*.sock)
      s=${p#"${ssh_dir}/agent."}
      s=${s%.sock}
      if valid_session "${s}" && [[ ${s} != default ]]; then
        printf '%s\n' "${s}"
        return 0
      fi
      ;;
  esac
  return 1
}

# PJP_SSH_CLIENT の値。届いていないもの (空・% を含む・制御文字を含む・local) は空にする
normalize_client() {
  local v=$1
  if [[ ${v} == *%* || ${v} == "${local_client}" || ${v} =~ [[:cntrl:]] ]]; then
    v=""
  fi
  printf '%s' "${v}"
}

# socket の状態: keys・empty (生きている)、missing・refused・timeout (死んでいる)。
# 返事をしない socket (回線断で sshd に残った接続) は 1 秒で打ち切る (ssh-add に待ちの上限は無い)
probe() {
  local rc=0
  if [[ ! -S $1 ]]; then
    echo missing
    return 0
  fi
  SSH_AUTH_SOCK=$1 timeout -k 1 1 ssh-add -l </dev/null >/dev/null 2>&1 || rc=$?
  case ${rc} in
    0) echo keys ;;
    1) echo empty ;;
    124 | 137) echo timeout ;;
    *) echo refused ;;
  esac
}

alive() {
  case $(probe "$1") in
    keys | empty) return 0 ;;
  esac
  return 1
}

read_target() {
  readlink -- "$1" 2>/dev/null || true
}

read_owner() {
  local v=""
  if [[ -f ${state}/owner/$1 ]]; then
    IFS= read -r v <"${state}/owner/$1" || true
  fi
  printf '%s' "${v}"
}

# 張り替えの記録に 1 行足す (書けなくても止めない)
log_line() {
  local f="${state}/log" size
  { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"${f}"; } 2>/dev/null || return 0
  size=$(stat -c %s -- "${f}" 2>/dev/null || echo 0)
  if ((size > 262144)); then
    { tail -n 1000 -- "${f}" >"${state}/tmp/log.$$" && mv -f -- "${state}/tmp/log.$$" "${f}"; } 2>/dev/null || true
  fi
}

# 固定名の先と持ち主が決めたときのまま (exp_*) なら、new_* へ入れ替える。
#   $1: session、$2・$3: 決めたときの先・持ち主、$4・$5: 新しい先・持ち主、$6: 由来 (log 用)
#   0: 入れ替えた / 1: 決めたあとに変わっていた (入れ替えない) / 2: lock を取れない
swap() {
  local s=$1 exp_t=$2 exp_o=$3 new_t=$4 new_o=$5 why=$6 fixed
  fixed=$(fixed_path "${s}")
  ensure_dirs
  (
    flock -w 5 9 || exit 2
    if [[ $(read_target "${fixed}") != "${exp_t}" || $(read_owner "${s}") != "${exp_o}" ]]; then
      exit 1
    fi
    printf '%s\n' "${new_o}" >"${state}/tmp/owner.${s}.$$"
    mv -f -- "${state}/tmp/owner.${s}.$$" "${state}/owner/${s}"
    tmp="${ssh_dir}/.pjp-agent-link.${s}.$$"
    rm -f -- "${tmp}"
    ln -s -- "${new_t}" "${tmp}"
    mv -fT -- "${tmp}" "${fixed}"
    log_line "${why} ${s}: ${exp_t:-(無し)} [${exp_o:-?}] -> ${new_t} [${new_o:-?}]"
  ) 9>>"${state}/lock"
}

# attach: 開いた session の固定名を決め直す。$1: session、$2・$3: 開いた接続の socket と値、$4: 由来 (log 用)
decide_attach() {
  local s=$1 open_sock=$2 open_client=$3 why=$4 fixed t o rc
  fixed=$(fixed_path "${s}")
  for _ in 1 2 3; do
    t=$(read_target "${fixed}")
    o=$(read_owner "${s}")
    if [[ ${t} == "${open_sock}" ]]; then
      if [[ ${o} == "${open_client}" ]]; then
        return 0
      fi
    elif [[ -n ${t} && -n ${o} && ${o} == "${open_client}" ]] && alive "${t}"; then
      # 切断前の接続が生きていて、同じマシンから開いた
      return 0
    fi
    rc=0
    swap "${s}" "${t}" "${o}" "${open_sock}" "${open_client}" "attach(${why})" || rc=$?
    if ((rc != 1)); then
      return 0
    fi
  done
  return 0
}

cmd_open() {
  local mode=${1-} s=${2-} fixed cur src t
  if [[ ${mode} != attach && ${mode} != start ]] || [[ -z ${s} ]]; then
    usage >&2
    exit 2
  fi
  if ! valid_session "${s}"; then
    return 0
  fi
  fixed=$(fixed_path "${s}")
  cur=${SSH_AUTH_SOCK-}
  if src=$(session_of_fixed "${cur}"); then
    # herdr の pane の中。別の session を開くなら、呼んだ pane の固定名と同じ先・同じ持ち主で張る
    if [[ ${mode} == attach && ${src} != "${s}" ]]; then
      t=$(read_target "${cur}")
      if [[ -n ${t} ]]; then
        decide_attach "${s}" "${t}" "$(read_owner "${src}")" "pane ${src}"
      fi
    fi
  elif [[ -n ${SSH_CONNECTION-} ]]; then
    # ssh 先。forward の無い接続 (ssh -a) や、フォールバックが起こしたローカル agent からは張らないが、
    # server には固定名を渡す (渡さないと、その server の pane は寿命が尽きるまで agent 無しになる)
    if [[ ${mode} == attach && -S ${cur} && -z ${SSH_AGENT_PID-} ]]; then
      decide_attach "${s}" "${cur}" "$(normalize_client "${PJP_SSH_CLIENT-}")" ssh
    fi
  elif [[ ${cur} == "${onepassword}" ]]; then
    # 手元の 1Password。場所が決まっているので、アプリの起動前でも張る (ADR 022)
    if [[ ${mode} == attach ]]; then
      decide_attach "${s}" "${onepassword}" "${local_client}" 1password
    fi
  else
    # WSL の手元など。SSH_AUTH_SOCK を変えない
    return 0
  fi
  printf '%s\n' "${fixed}"
}

cmd_link() {
  local s=${1:-${HERDR_SESSION:-default}} fixed cur client t o rc
  if ! valid_session "${s}"; then
    echo "${prog}: session の名前が herdr の規則に合いません: ${s}" >&2
    return 2
  fi
  fixed=$(fixed_path "${s}")
  cur=${SSH_AUTH_SOCK-}
  if session_of_fixed "${cur}" >/dev/null; then
    echo "${prog}: この shell の SSH_AUTH_SOCK は固定名 (${cur}) なので張り替えません。herdr の外の、agent を forward した ssh の shell で打ってください。" >&2
    return 1
  elif [[ -n ${SSH_CONNECTION-} && -S ${cur} && -z ${SSH_AGENT_PID-} ]]; then
    client=$(normalize_client "${PJP_SSH_CLIENT-}")
  elif [[ -z ${SSH_CONNECTION-} && ${cur} == "${onepassword}" ]]; then
    client=${local_client}
  else
    echo "${prog}: この shell には張る先がありません (SSH_AUTH_SOCK が forward された agent の socket ではない: ${cur:-空})。" >&2
    return 1
  fi
  for _ in 1 2 3; do
    t=$(read_target "${fixed}")
    o=$(read_owner "${s}")
    rc=0
    swap "${s}" "${t}" "${o}" "${cur}" "${client}" link || rc=$?
    if ((rc == 0)); then
      printf '%s -> %s (持ち主 %s)\n' "${fixed}" "${cur}" "${client:-分からない}"
      return 0
    elif ((rc != 1)); then
      break
    fi
  done
  echo "${prog}: 張り替えられませんでした (${state}/lock を取れない、か張り替えが続いた)。" >&2
  return 1
}

cmd=${1-}
if (($# > 0)); then
  shift
fi
case ${cmd} in
  open) cmd_open "$@" ;;
  link) cmd_link "$@" ;;
  -h | --help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
