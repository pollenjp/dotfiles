#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/files/claude/skills/pjp-drawio/scripts/drawio-export.sh (skill pjp-drawio の書き出し) を、偽の drawio・xvfb-run・id と、
# 差し替えた /proc/sys で確かめる。
#
#   bash nix/tests/pjp-drawio-export.test.sh [<drawio-export.sh のパス>]
#
# flake の checks (pjp-drawio-export-test) が Nix のサンドボックスで流す。使うのは bash と coreutils・grep・awk だけ
# (本物の drawio と Xvfb は使わない。重いうえに、sandbox が立つかは流すマシンの kernel の設定で変わるので)。
#
# ## 確かめること
#
#   sandbox
#     - 一般ユーザで、user namespace を止める kernel の設定が無ければ、drawio に --no-sandbox を渡さず、注意も出さない
#       (設定のファイルが無い kernel でも、止めていない値でも)
#     - kernel.apparmor_restrict_unprivileged_userns が 1・kernel.unprivileged_userns_clone が 0・user.max_user_namespaces が 0 の
#       どれかなら、drawio に --no-sandbox を渡して書き出し、その設定の名前と値を入れた注意を stderr に出す (図が 2 つでも 1 回)
#     - root なら、kernel の設定に依らず --no-sandbox を渡し、注意は出さない
#   失敗したときの出力
#     - drawio が落ちたら 1 で終わり、drawio の出力 (sandbox の FATAL) を stderr に出す。xvfb-run が終わりに --error-file を
#       開き直して切り詰めても消えない
#     - Xvfb が立たずに xvfb-run が途中で抜けたら、drawio の出力に加えて、xvfb-run の --error-file に残った Xvfb の出力も出す
#   書き出した SVG には、いつも白背景の矩形が入る
#
# ## 作り
#
# 偽の drawio は引数を 1 回 1 行で FAKE_DIR/calls に書き、--output に小さな SVG を書く。DISPLAY が無い・":" なら本物と
# 同じく X に繋がらずに 1 で終わる。FAKE_SANDBOX_BROKEN があれば、--no-sandbox の無い呼び出しで本物と同じ FATAL を出して
# 133 (SIGTRAP) で終わる (一般ユーザが user namespace を使えないマシンの、nixpkgs の drawio)。偽の xvfb-run は本物
# (nixpkgs の xvfb-run) の後始末 `xauth remove … >"$ERRORFILE"` を真似て、コマンドが終わったら --error-file を `>` で
# 開き直す。FAKE_XVFB_BROKEN があれば、--error-file に Xvfb の失敗を書き、DISPLAY=: でコマンドを起こして、後始末を
# せずに 1 で終わる (本物は Xvfb が死んでいると、set -e の下の kill で抜ける)。偽の id は FAKE_UID を返す (既定は 1000)。
# /proc/sys は DRAWIO_SKILL_PROC_SYS で差し替え、DISPLAY は外して、いつも xvfb-run を通す。shebang は $BASH から作る
# (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/skills/pjp-drawio/scripts/drawio-export.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-drawio-export-test.XXXXXX")
work=$(cd "${work}" && pwd -P)
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

bin=${work}/bin
mkdir -p "${bin}"

printf '#!%s\n' "${BASH}" >"${bin}/drawio"
cat >>"${bin}/drawio" <<'EOS'
set -u
printf '%s\n' "$*" >>"${FAKE_DIR}/calls"
case " $* " in
  *" --no-sandbox "*) ;;
  *)
    if [[ -n ${FAKE_SANDBOX_BROKEN:-} ]]; then
      echo "[1:1109/000000.000000:FATAL:sandbox/linux/suid/client/setuid_sandbox_host.cc:166] The SUID sandbox helper binary was found, but is not configured correctly. Rather than run without sandboxing I'm aborting now." >&2
      exit 133
    fi
    ;;
esac
if [[ -z ${DISPLAY:-} || ${DISPLAY} == : ]]; then
  echo "[1:1109/000000.000000:ERROR:ui/ozone/platform/x11/ozone_platform_x11.cc:250] Missing X server or \$DISPLAY" >&2
  exit 1
fi
# headless で毎回出るノイズ (script が落とす)
echo "[1:1109/000000.000000:ERROR:dbus/bus.cc:408] Failed to connect to the bus" >&2
output=
while [[ $# -gt 0 ]]; do
  case $1 in
    --output)
      output=$2
      shift 2
      ;;
    *) shift ;;
  esac
done
printf '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><g/></svg>\n' >"${output}"
EOS

printf '#!%s\n' "${BASH}" >"${bin}/xvfb-run"
cat >>"${bin}/xvfb-run" <<'EOS'
set -u
errfile=/dev/null
while [[ $# -gt 0 ]]; do
  case $1 in
    --error-file=*)
      errfile=${1#*=}
      shift
      ;;
    --auto-display | --auth-file=*) shift ;;
    *) break ;;
  esac
done
if [[ -n ${FAKE_XVFB_BROKEN:-} ]]; then
  echo "_XSERVTransmkdir: Mode of /tmp/.X11-unix should be set to 1777" >>"${errfile}"
  DISPLAY=: "$@"
  exit 1
fi
DISPLAY=:99 "$@"
rc=$?
: >"${errfile}"
exit "${rc}"
EOS

printf '#!%s\n' "${BASH}" >"${bin}/id"
cat >>"${bin}/id" <<'EOS'
case ${1:-} in
  -u) echo "${FAKE_UID:-1000}" ;;
  *) echo "uid=${FAKE_UID:-1000}" ;;
esac
EOS
chmod +x "${bin}/drawio" "${bin}/xvfb-run" "${bin}/id"

# proc <名前> [<sysctl の /proc/sys からのパス>=<値>]… : 差し替える /proc/sys を作り、その場所を出す
proc() {
  local dir=${work}/proc/$1 kv
  shift
  mkdir -p "${dir}"
  for kv in "$@"; do
    mkdir -p "${dir}/$(dirname "${kv%%=*}")"
    printf '%s\n' "${kv#*=}" >"${dir}/${kv%%=*}"
  done
  echo "${dir}"
}

# run <case> [<変数>=<値>]… : 図 2 つ (a・b) を書き出す。stdout・stderr・rc を ${work}/<case>/ に残す
run() {
  local c=$1
  shift
  local d=${work}/${c}
  mkdir -p "${d}/drawio"
  : >"${d}/calls"
  printf '<mxfile/>\n' >"${d}/drawio/a.drawio"
  printf '<mxfile/>\n' >"${d}/drawio/b.drawio"
  (
    cd "${d}/drawio" || exit
    env -u DISPLAY PATH="${bin}:${PATH}" FAKE_DIR="${d}" "$@" bash "${script}" </dev/null >"${d}/out" 2>"${d}/err"
    echo $? >"${d}/rc"
  )
}
detail() {
  local d=${work}/$1
  echo "rc=$(cat "${d}/rc")"
  echo "calls:"
  cat "${d}/calls"
  echo "stdout:"
  cat "${d}/out"
  echo "stderr:"
  cat "${d}/err"
}
rc_of() {
  cat "${work}/$1/rc"
}
# sandbox_calls <case> : drawio の呼び出しのうち --no-sandbox を渡したものの数
sandbox_calls() {
  grep -c -e ' --no-sandbox ' -e '^--no-sandbox ' "${work}/$1/calls"
}
call_count() {
  grep -c '' "${work}/$1/calls"
}
notice_count() {
  grep -c '^注意:' "${work}/$1/err"
}

# expect_plain <case> <説明> : 2 つとも書き出せて、--no-sandbox を渡さず、注意も出さない
expect_plain() {
  if [[ $(rc_of "$1") == 0 && $(call_count "$1") == 2 && $(sandbox_calls "$1") == 0 && $(notice_count "$1") == 0 ]]; then
    ok "$2"
  else
    ng "$2" "$(detail "$1")"
  fi
}
# expect_no_sandbox <case> <説明> <注意に入る文字列> : 2 つとも --no-sandbox で書き出し、その文字列の注意を 1 回だけ出す
expect_no_sandbox() {
  if [[ $(rc_of "$1") == 0 && $(call_count "$1") == 2 && $(sandbox_calls "$1") == 2 && $(notice_count "$1") == 1 ]] \
    && grep -qF -e "$3" "${work}/$1/err"; then
    ok "$2"
  else
    ng "$2" "$(detail "$1")"
  fi
}

echo "== drawio-export.sh"

restrict=kernel/apparmor_restrict_unprivileged_userns
clone=kernel/unprivileged_userns_clone
maxns=user/max_user_namespaces

# 1. kernel の設定のファイルが無い (AppArmor の無い kernel など) → そのまま
run none DRAWIO_SKILL_PROC_SYS="$(proc none)"
expect_plain none "設定のファイルが無い kernel では、--no-sandbox を渡さず、注意も出さない"

# 2. どれも止めていない値 → そのまま
open=$(proc open "${restrict}=0" "${clone}=1" "${maxns}=63000")
run open DRAWIO_SKILL_PROC_SYS="${open}"
expect_plain open "user namespace を止めていない kernel では、--no-sandbox を渡さず、注意も出さない"

# 3〜5. 止める設定のどれか → --no-sandbox。sandbox が立たない drawio (FAKE_SANDBOX_BROKEN) でも書き出せる
run apparmor DRAWIO_SKILL_PROC_SYS="$(proc apparmor "${restrict}=1" "${clone}=1" "${maxns}=63000")" FAKE_SANDBOX_BROKEN=1
expect_no_sandbox apparmor "apparmor_restrict_unprivileged_userns が 1 なら、--no-sandbox で書き出して注意を 1 回出す" \
  "kernel.apparmor_restrict_unprivileged_userns = 1"
run clone DRAWIO_SKILL_PROC_SYS="$(proc clone "${restrict}=0" "${clone}=0" "${maxns}=63000")" FAKE_SANDBOX_BROKEN=1
expect_no_sandbox clone "unprivileged_userns_clone が 0 なら、--no-sandbox で書き出して注意を 1 回出す" \
  "kernel.unprivileged_userns_clone = 0"
run maxns DRAWIO_SKILL_PROC_SYS="$(proc maxns "${maxns}=0")" FAKE_SANDBOX_BROKEN=1
expect_no_sandbox maxns "max_user_namespaces が 0 なら、--no-sandbox で書き出して注意を 1 回出す" \
  "user.max_user_namespaces = 0"

# 6. root → kernel の設定に依らず --no-sandbox。注意は出さない
run root DRAWIO_SKILL_PROC_SYS="${open}" FAKE_UID=0
if [[ $(rc_of root) == 0 && $(call_count root) == 2 && $(sandbox_calls root) == 2 && $(notice_count root) == 0 ]]; then
  ok "root なら --no-sandbox を渡し、注意は出さない"
else
  ng "root なら --no-sandbox を渡し、注意は出さない" "$(detail root)"
fi

# 7. drawio が落ちる (kernel の設定に出ない理由で sandbox が立たない) → 1 で終わり、drawio の出力が残る
run broken DRAWIO_SKILL_PROC_SYS="${open}" FAKE_SANDBOX_BROKEN=1
if [[ $(rc_of broken) == 1 ]] \
  && grep -qF 'FATAL:sandbox/linux/suid/client/setuid_sandbox_host.cc' "${work}/broken/err" \
  && grep -qF 'drawio が失敗しました' "${work}/broken/err"; then
  ok "drawio が落ちたら 1 で終わり、drawio の出力を stderr に出す (xvfb-run の後始末に消されない)"
else
  ng "drawio が落ちたら 1 で終わり、drawio の出力を stderr に出す (xvfb-run の後始末に消されない)" "$(detail broken)"
fi

# 8. Xvfb が立たない → drawio の出力と Xvfb の出力の両方を出す
run xvfb DRAWIO_SKILL_PROC_SYS="${open}" FAKE_XVFB_BROKEN=1
if [[ $(rc_of xvfb) == 1 ]] \
  && grep -qF 'Missing X server' "${work}/xvfb/err" \
  && grep -qF '_XSERVTransmkdir' "${work}/xvfb/err"; then
  ok "Xvfb が立たなければ、drawio の出力と Xvfb の出力を stderr に出す"
else
  ng "Xvfb が立たなければ、drawio の出力と Xvfb の出力を stderr に出す" "$(detail xvfb)"
fi

# 9. 白背景 (書き出した SVG のルート直下に入る)
if grep -qF '<rect x="0" y="0" width="100%" height="100%" fill="#ffffff"/>' "${work}/apparmor/drawio/out/a.svg" \
  && grep -qF '<rect x="0" y="0" width="100%" height="100%" fill="#ffffff"/>' "${work}/open/drawio/out/b.svg"; then
  ok "書き出した SVG に白背景の矩形が入る"
else
  ng "書き出した SVG に白背景の矩形が入る" "$(cat "${work}/apparmor/drawio/out/a.svg" "${work}/open/drawio/out/b.svg" 2>&1)"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} -eq 0 ]]
