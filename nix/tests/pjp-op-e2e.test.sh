#!/usr/bin/env bash
# shellcheck shell=bash
#
# WSL の op (nix/pkgs/pjp-op/op.sh) から本物の launcher (launcher.ps1。Linux の pwsh) までを、偽の op だけで端から端まで通す。
# op.sh と launcher の間の取り決め (payload・status・起動の式・env) がずれると、ここで落ちる (pjp-op.test.sh は偽の
# powershell で、pjp-op-launcher.test.sh は launcher だけを確かめるので、両方が同じ誤りに合わせると見えない)。
#
#   bash nix/tests/pjp-op-e2e.test.sh <op.sh のパス> <package の launcher の dir>
#
# flake の checks (pjp-op-e2e-test) が Nix のサンドボックスで流す。pwsh (nixpkgs の powershell)・jq・git・flock (util-linux) が要る。
# 偽の powershell.exe は受けた引数のまま pwsh を起こし、偽の wslpath はパスをそのまま返す。窓と通知は Linux では出ない。
#
# ## 確かめること
#
#   desktop
#     - 難しい引数 (空白・引用符・日本語・空) がそのまま op に届き、stdin の binary が stdout にそのまま出て、stderr は op の
#       出したものだけ、終了コードは op の終了コード
#     - op の後に launcher が whoami を打ち、承認があれば signout --all を打つ。記録の end は approved で、signout は ok
#   拒否: op の stderr が拒否の文言なら、記録の end は denied、signout は not-signed-in (launcher の whoami が通らない)
#   service account: token と OP_BIOMETRIC_UNLOCK_ENABLED=false が op に届き、launcher は whoami も signout も打たない
#     (記録の kind は service-account、signout は skipped)
#
# ## 作り
#
# 偽の op.exe は、呼ばれるたびに引数を NUL 区切りで FAKE_DIR/call.<番号> に、誰から呼ばれたか (親の comm が timeout なら
# op.sh の見張り、ほかは launcher。Nix の pwsh は包みの名前で動くので comm は pwsh と限らない) と token まわりの env を
# FAKE_DIR/env.<番号> に書く。whoami は launcher からのときだけ FAKE_WHOAMI_RC で終わり (見張りの直の whoami はいつも 1)、
# signout は 0。ほかは stdin を stdout へ写し、stderr に FAKE_STDERR を出して FAKE_RC で終わる。

set -u -o pipefail

script=${1:?op.sh のパスを渡す}
launcher_dir=${2:?package の launcher の dir を渡す}
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-op-e2e-test.XXXXXX")
work=$(cd "${work}" && pwd -P)
trap 'rm -rf "${work}"' EXIT

export LC_ALL=C.UTF-8
export HOME=${work}/home XDG_STATE_HOME=${work}/state FAKE_DIR=${work}/fake
export POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
unset WSLENV HERDR_ENV CLAUDE_CODE_SESSION_ID OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN XDG_RUNTIME_DIR
mkdir -p "${HOME}" "${XDG_STATE_HOME}" "${FAKE_DIR}" "${work}/bin"
export PATH=${work}/bin:${PATH}
export PJP_OP_LAUNCHER=${launcher_dir} PJP_OP_EXE=${work}/bin/op.exe

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

fake() {
  {
    printf '#!%s\n' "${BASH}"
    cat
  } >"${work}/bin/$1"
  chmod +x "${work}/bin/$1"
}

fake powershell.exe <<'EOF'
exec pwsh "$@"
EOF
fake wslpath <<'EOF'
printf '%s\n' "$2"
EOF
fake op.exe <<'EOF'
d=${FAKE_DIR}
n=$(($(cat "${d}/n" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${d}/n"
printf '%s\0' "$@" >"${d}/call.${n}"
role=launcher
[[ $(cat "/proc/${PPID}/comm" 2>/dev/null) != timeout ]] || role=watch
{
  echo "role=${role}"
  echo "sa=${OP_SERVICE_ACCOUNT_TOKEN-<unset>}"
  echo "bio=${OP_BIOMETRIC_UNLOCK_ENABLED-<unset>}"
} >"${d}/env.${n}"
case ${1-} in
  whoami)
    [[ ${role} == launcher ]] && exit "${FAKE_WHOAMI_RC:-1}"
    exit 1
    ;;
  signout) exit 0 ;;
esac
cat
printf '%s\n' "${FAKE_STDERR:-FAKE-ERR}" >&2
exit "${FAKE_RC:-0}"
EOF

reset() {
  rm -rf "${FAKE_DIR:?}"/* "${XDG_STATE_HOME}/pjp-op"
}

# run_op <名前> <引数>…: op.sh を流す。stdin は stdin_file (無ければ /dev/null)
run_op() {
  local name=$1
  shift
  rc=0
  "${BASH}" "${script}" "$@" <"${stdin_file:-/dev/null}" >"${work}/${name}.out" 2>"${work}/${name}.err" || rc=$?
}

# calls_from <launcher | watch>: そこから呼ばれた偽の op の番号を並べる
calls_from() {
  local f
  for f in "${FAKE_DIR}"/env.*; do
    [[ -e ${f} ]] || continue
    if grep -qx "role=$1" "${f}"; then
      echo "${f##*.}"
    fi
  done | sort -n
}
call_is() {
  local n=$1
  shift
  cmp -s "${FAKE_DIR}/call.${n}" <(printf '%s\0' "$@")
}
end_field() {
  jq -r "select(.event == \"end\") | $1" "${XDG_STATE_HOME}/pjp-op/log.jsonl" 2>/dev/null | tail -n 1
}

stdin_file=${work}/in.bin
for i in $(seq 0 255); do
  printf -v oct '\\%03o' "${i}"
  printf '%b' "${oct}"
done >"${stdin_file}"
printf '\r\n\0end\n' >>"${stdin_file}"

echo "== desktop"
reset
export FAKE_WHOAMI_RC=0
args=(item get "a b" 'x"y' "日本語 の 値" "")
run_op desktop --reason "端から端" "${args[@]}"
mapfile -t from_pwsh < <(calls_from launcher)
if [[ ${rc} == 0 ]] && cmp -s "${stdin_file}" "${work}/desktop.out" && [[ $(<"${work}/desktop.err") == FAKE-ERR ]] \
  && ((${#from_pwsh[@]} == 3)) && call_is "${from_pwsh[0]}" "${args[@]}"; then
  ok "引数・stdin の binary・stderr・終了コードが端から端まで通る"
else
  ng "引数・stdin の binary・stderr・終了コードが端から端まで通る" \
    "rc=${rc} err=$(cat "${work}/desktop.err") calls=${from_pwsh[*]}"
fi
if ((${#from_pwsh[@]} == 3)) && call_is "${from_pwsh[1]}" whoami && call_is "${from_pwsh[2]}" signout --all \
  && [[ $(end_field .result) == approved && $(end_field .signout) == ok ]]; then
  ok "launcher が whoami の後に signout --all を打ち、記録は approved・signout ok"
else
  ng "launcher が whoami の後に signout --all を打ち、記録は approved・signout ok" \
    "calls=${from_pwsh[*]} $(cat "${XDG_STATE_HOME}/pjp-op/log.jsonl" 2>&1)"
fi

echo "== 拒否"
reset
export FAKE_WHOAMI_RC=1 FAKE_RC=1 FAKE_STDERR="[ERROR] 2026/11/08 00:00:00 authorization prompt dismissed, please try again"
run_op denied --reason "拒否を見る" item get a
unset FAKE_RC FAKE_STDERR
if [[ ${rc} == 1 && $(end_field .result) == denied && $(end_field .signout) == not-signed-in ]]; then
  ok "拒否の文言なら記録は denied・signout は not-signed-in"
else
  ng "拒否の文言なら記録は denied・signout は not-signed-in" "rc=${rc} $(cat "${XDG_STATE_HOME}/pjp-op/log.jsonl" 2>&1)"
fi

echo "== service account"
reset
export OP_SERVICE_ACCOUNT_TOKEN=tok-e2e FAKE_WHOAMI_RC=0
run_op service --reason "SA で読む" vault list
unset OP_SERVICE_ACCOUNT_TOKEN
mapfile -t from_pwsh < <(calls_from launcher)
if [[ ${rc} == 0 ]] && ((${#from_pwsh[@]} == 1)) && call_is "${from_pwsh[0]}" vault list \
  && grep -qx 'sa=tok-e2e' "${FAKE_DIR}/env.${from_pwsh[0]}" && grep -qx 'bio=false' "${FAKE_DIR}/env.${from_pwsh[0]}" \
  && [[ $(end_field .signout) == skipped && $(jq -r 'select(.event == "start") | .kind' "${XDG_STATE_HOME}/pjp-op/log.jsonl") == service-account ]]; then
  ok "token と OP_BIOMETRIC_UNLOCK_ENABLED=false が op に届き、launcher は承認を閉じる手順を打たない"
else
  ng "token と OP_BIOMETRIC_UNLOCK_ENABLED=false が op に届き、launcher は承認を閉じる手順を打たない" \
    "rc=${rc} calls=${from_pwsh[*]} $(cat "${FAKE_DIR}"/env.* 2>&1)"
fi
unset FAKE_WHOAMI_RC

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
