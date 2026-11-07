#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/pjp-op/op.sh (WSL の op。理由を必須にし、呼び出しごとの powershell で op.exe を起こす) を、偽の powershell.exe・
# op.exe・wslpath・herdr で確かめる。
#
#   bash nix/tests/pjp-op.test.sh [<op.sh のパス>]
#
# flake の checks (pjp-op-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・jq・git・flock (util-linux)。
# 本物の powershell.exe・op.exe・1Password は使わない (launcher の中身は pjp-op-launcher.test.sh が確かめる)。
#
# ## 確かめること
#
#   理由
#     - --reason が無い・空・空白だけなら 2 で終わり、stderr に使い方を出し、powershell を呼ばず、ログに refused (no-reason)
#     - --reason X・--reason=X は op の引数のどこに置いてもよく、op には外した残りが届く。-- の後ろの --reason は op の引数
#     - 改行・タブ・制御文字は空白 1 つに畳み、前後の空白を外す。窓は 200 字・ログは 500 字で切る
#   理由なしで通るもの (--version・--help・-h・help・引数なし・-- より前の --help) は、窓の無い help の mode で powershell を通す
#   通すもの
#     - stdin の binary は op にそのまま届いて stdout に出る。stderr は op の出したものだけ。終了コードは op の終了コード
#     - powershell は -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand <launcher> で起こす
#   desktop
#     - payload の mode は desktop、op は op.exe の Windows のパス、args64 は op の引数
#     - WSLENV は呼び手の WSLENV に PJP_OP_PAYLOAD を足したもので、token は渡さない (env からも外す)
#     - 窓の行に 時刻・呼び手・場所・理由・コマンド、footer に「この窓が出ていない」
#   service account・Connect
#     - OP_SERVICE_ACCOUNT_TOKEN があれば service の mode で窓は無く、WSLENV に OP_SERVICE_ACCOUNT_TOKEN/w と
#       OP_BIOMETRIC_UNLOCK_ENABLED/w を足し、OP_BIOMETRIC_UNLOCK_ENABLED=false で起こす。ログの kind は service-account
#     - OP_CONNECT_HOST と OP_CONNECT_TOKEN が両方あれば同じく service (kind は connect)。片方だけなら desktop
#     - token はログに書かない
#   伏せる: password=… の値・--session と --secret-key の値は、ログの args と窓のコマンドで *** にする (op にはそのまま渡す)
#   結果: 0 → approved、拒否の文言 → denied、時間切れの文言 → timeout、ほか → failed、status が無い → launcher-failed。
#     start と end は同じ id で、end の seconds は 0 以上の整数
#   呼び手: proc の祖先に claude があれば claude (pid も)、無ければ human。herdr の workspace の label と pane、git の repo と
#     branch、CLAUDE_CODE_SESSION_ID を start と end の session に書く
#   lock: ほかの呼び出しが lock を持ったまま上限を超えたら 75 で終わり、待った秒と待たせている呼び出しの理由を出し、
#     powershell を呼ばない (ログに refused (lock-timeout))
#   共有の承認の見張り: WSL の直の op.exe whoami が通れば op.exe signout で消し、ログに shared-approval、通知を出す
#     (powershell の notify と herdr)。通らなければ signout を打たない
#   op.exe・powershell.exe が無ければ 127 (ログに refused)
#   TERM を受けたら end に interrupted を書いて 143 で終わる
#   ログが 1 MiB を超えたら log.1.jsonl へ回す。呼び出しの後に run/ の下 (status・stderr の写し) を残さない
#
# ## 作り
#
# 偽の powershell.exe は、notify なら payload を FAKE_DIR/notify.<pid>.payload に書いて 0 で終わる (裏で起こされ、ほかの呼び出しと
# 重なる)。ほかは引数・PJP_OP_PAYLOAD・WSLENV と token まわりの env を FAKE_DIR/ps.<番号>.* に書き、payload の args64 を戻して
# 偽の op.exe (payload の op を偽の wslpath で戻したもの) を stdio を継いで起こし、status を書いて op の終了コードで終わる
# (FAKE_PS_NO_STATUS=1 なら status を書かずに 1)。偽の op.exe は whoami (FAKE_DIR/shared が
# あれば 0) と signout (shared を消す) を FAKE_DIR/op.direct に書き、ほかは引数を FAKE_DIR/op.args に書いて stdin を stdout へ写し、
# stderr に FAKE_STDERR を出して FAKE_RC で終わる。偽の wslpath は /x/y と C:\fake\x\y を行き来する。偽の proc の木は
# PJP_OP_PROC と PJP_OP_PROC_START で渡す。shebang は $BASH から作る。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../pkgs/pjp-op/op.sh}
# 呼び手のテストは別の dir に cd してから流すので、絶対パスにする
script=$(cd -- "$(dirname "${script}")" && pwd -P)/$(basename "${script}")
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-op-test.XXXXXX")
work=$(cd "${work}" && pwd -P)
trap 'rm -rf "${work}"' EXIT

export LC_ALL=C.UTF-8
export HOME=${work}/home XDG_STATE_HOME=${work}/state
export FAKE_DIR=${work}/fake
fake_bin=${work}/bin
mkdir -p "${HOME}" "${XDG_STATE_HOME}" "${FAKE_DIR}" "${fake_bin}" "${work}/win"
export PATH=${fake_bin}:${PATH}
unset WSLENV HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID CLAUDE_CODE_SESSION_ID OP_SERVICE_ACCOUNT_TOKEN \
  OP_CONNECT_HOST OP_CONNECT_TOKEN OP_BIOMETRIC_UNLOCK_ENABLED

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

# fake <名前> <<'EOF' … EOF: 偽のコマンドを fake_bin (か、パスを渡せばそこ) に置く。本文は stdin から読む
fake() {
  local path=$1
  [[ ${path} == /* ]] || path=${fake_bin}/${path}
  {
    printf '#!%s\n' "${BASH}"
    cat
  } >"${path}"
  chmod +x "${path}"
}

fake wslpath <<'EOF'
case $1 in
  -w) p=${2//\//\\}; printf "C:\\\\fake%s\n" "${p}" ;;
  -u) p=${2#C:\\fake}; printf "%s\n" "${p//\\//}" ;;
  *) exit 2 ;;
esac
EOF

fake powershell.exe <<'EOF'
d=${FAKE_DIR}
mode=$(jq -r .mode <<<"${PJP_OP_PAYLOAD}")
if [[ ${mode} == notify ]]; then
  printf "%s" "${PJP_OP_PAYLOAD}" >"${d}/notify.$$.payload"
  exit 0
fi
n=$(($(cat "${d}/ps.n" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${d}/ps.n"
printf "%s\n" "$@" >"${d}/ps.${n}.argv"
printf "%s" "${PJP_OP_PAYLOAD-}" >"${d}/ps.${n}.payload"
{
  echo "WSLENV=${WSLENV-<unset>}"
  echo "SA=${OP_SERVICE_ACCOUNT_TOKEN-<unset>}"
  echo "BIO=${OP_BIOMETRIC_UNLOCK_ENABLED-<unset>}"
  echo "CH=${OP_CONNECT_HOST-<unset>}"
  echo "CT=${OP_CONNECT_TOKEN-<unset>}"
} >"${d}/ps.${n}.env"
mapfile -d "" args < <(jq -j ".args64[] | (@base64d) + \"\u0000\"" <<<"${PJP_OP_PAYLOAD}")
op=$(wslpath -u "$(jq -r .op <<<"${PJP_OP_PAYLOAD}")")
status=$(wslpath -u "$(jq -r .status <<<"${PJP_OP_PAYLOAD}")")
rc=0
"${op}" "${args[@]}" || rc=$?
if [[ -n ${FAKE_PS_NO_STATUS:-} ]]; then
  exit 1
fi
jq -cn --argjson rc "${rc}" "{started: true, exit: \$rc, error: \"\", window: \"shown\", toast: \"shown\", others: 0, signout: \"ok\"}" >"${status}"
exit "${rc}"
EOF

op_exe=${work}/win/op.exe
fake "${op_exe}" <<'EOF'
d=${FAKE_DIR}
case ${1-} in
  whoami)
    echo whoami >>"${d}/op.direct"
    [[ -e ${d}/shared ]] && exit 0
    exit 1
    ;;
  signout)
    echo signout >>"${d}/op.direct"
    rm -f "${d}/shared"
    exit 0
    ;;
esac
printf "%s\0" "$@" >"${d}/op.args"
if [[ -n ${FAKE_SLEEP:-} ]]; then sleep "${FAKE_SLEEP}"; fi
cat
printf "%s\n" "${FAKE_STDERR:-fake-err}" >&2
exit "${FAKE_RC:-0}"
EOF
export PJP_OP_EXE=${op_exe}

fake herdr <<'EOF'
case "$1 $2" in
  "workspace get") printf "%s\n" "{\"result\":{\"workspace\":{\"workspace_id\":\"$3\",\"label\":\"TKT-1 テスト\"}}}" ;;
  "notification show") printf "%s\n" "$*" >>"${FAKE_DIR}/herdr.notify" ;;
  *) exit 1 ;;
esac
EOF

printf 'TEST-LAUNCHER-B64' >"${work}/launcher.b64"
export PJP_OP_LAUNCHER=${work}/launcher.b64

# 偽の proc の木: 1000 (bash) → 999 (<comm>) → 500 (fish) → 1
make_proc() {
  local root=${work}/proc
  rm -rf "${root}"
  mkdir -p "${root}/1000" "${root}/999" "${root}/500"
  echo "1000 (bash) S 999 1000 1000" >"${root}/1000/stat"
  echo bash >"${root}/1000/comm"
  echo "999 ($1) S 500 999 999" >"${root}/999/stat"
  echo "$1" >"${root}/999/comm"
  echo "500 (fish) S 1 500 500" >"${root}/500/stat"
  echo fish >"${root}/500/comm"
}
make_proc fish
export PJP_OP_PROC=${work}/proc PJP_OP_PROC_START=1000

log=${XDG_STATE_HOME}/pjp-op/log.jsonl

reset() {
  rm -rf "${FAKE_DIR:?}"/* "${XDG_STATE_HOME}/pjp-op"
}

# run_op <名前> <引数>…: op.sh を流す。stdin は stdin_file (無ければ /dev/null)。out・err・rc に入れる
run_op() {
  local name=$1
  shift
  rc=0
  "${BASH}" "${script}" "$@" <"${stdin_file:-/dev/null}" >"${work}/${name}.out" 2>"${work}/${name}.err" || rc=$?
}

ps_count() {
  cat "${FAKE_DIR}/ps.n" 2>/dev/null || echo 0
}
payload_of() {
  cat "${FAKE_DIR}/ps.${1:-1}.payload" 2>/dev/null
}
payload_field() {
  jq -r "$1" <<<"$(payload_of "${2:-1}")" 2>/dev/null
}
# payload の args64 を NUL 区切りに戻す
payload_args() {
  jq -j '.args64[] | (@base64d) + "\u0000"' <<<"$(payload_of "${1:-1}")" 2>/dev/null
}
expect_payload_args() {
  cmp -s <(payload_args) <(printf '%s\0' "$@")
}
env_of() {
  cat "${FAKE_DIR}/ps.${1:-1}.env" 2>/dev/null
}
last() {
  jq -c "select(.event == \"$1\")" "${log}" 2>/dev/null | tail -n 1
}
last_field() {
  jq -r "$2" <<<"$(last "$1")" 2>/dev/null
}

echo "== 理由"
reset
run_op noreason item get a
if [[ ${rc} == 2 && $(<"${work}/noreason.err") == *--reason* && $(ps_count) == 0 &&
$(last_field refused '.why') == no-reason ]]; then
  ok "--reason が無ければ 2・使い方・powershell を呼ばない・ログに refused (no-reason)"
else
  ng "--reason が無ければ 2・使い方・powershell を呼ばない・ログに refused (no-reason)" "rc=${rc} ps=$(ps_count) err=$(cat "${work}/noreason.err")"
fi
reset
run_op empty --reason "" item get a
rc_empty=${rc}
run_op blank --reason $'  \t ' item get a
if [[ ${rc_empty} == 2 && ${rc} == 2 && $(ps_count) == 0 ]]; then
  ok "--reason が空・空白だけなら 2"
else
  ng "--reason が空・空白だけなら 2" "empty=${rc_empty} blank=${rc} ps=$(ps_count)"
fi
for form in front middle eq; do
  reset
  case ${form} in
    front) run_op where --reason X a b ;;
    middle) run_op where a --reason X b ;;
    eq) run_op where a b --reason=X ;;
  esac
  if [[ ${rc} == 0 ]] && expect_payload_args a b; then
    ok "--reason の置き場所 (${form}) によらず op には a b が届く"
  else
    ng "--reason の置き場所 (${form}) によらず op には a b が届く" "rc=${rc} args=$(payload_args | tr '\0' '|') err=$(cat "${work}/where.err")"
  fi
done
reset
run_op dashdash a -- b --reason X
if [[ ${rc} == 2 && $(ps_count) == 0 ]]; then
  ok "-- の後ろの --reason は op の引数のまま (理由なしとして断る)"
else
  ng "-- の後ろの --reason は op の引数のまま (理由なしとして断る)" "rc=${rc} ps=$(ps_count)"
fi
reset
long=$(printf 'あ%.0s' $(seq 600))
run_op norm --reason $'  直す\tため\nに\x01読む  '"${long}" item get a
reason_line=$(payload_field '.ui.lines[] | select(.[0] == "理由") | .[1]')
log_reason=$(last_field start '.reason')
if [[ ${log_reason} == "直す ため に 読む "* && ${#log_reason} == 501 && ${log_reason} == *… &&
  ${#reason_line} == 201 && ${reason_line} == "直す ため に 読む "* ]]; then
  ok "理由は 1 行に畳み、窓は 200 字・ログは 500 字で切る"
else
  ng "理由は 1 行に畳み、窓は 200 字・ログは 500 字で切る" "log(${#log_reason})=${log_reason:0:40} ui(${#reason_line})=${reason_line:0:40}"
fi

echo "== 理由なしで通るもの"
for c in "--version" "--help" "item get --help" "help item" ""; do
  reset
  read -r -a words <<<"${c}"
  run_op help "${words[@]}"
  if [[ ${rc} == 0 && $(payload_field '.mode') == help && $(payload_field '.ui') == null &&
  $(last_field start '.kind') == help ]]; then
    ok "理由なしの「op ${c}」は help の mode で通す (窓なし)"
  else
    ng "理由なしの「op ${c}」は help の mode で通す (窓なし)" "rc=${rc} payload=$(payload_of) err=$(cat "${work}/help.err")"
  fi
done

echo "== 通すもの"
reset
stdin_file=${work}/in.bin
for i in $(seq 0 255); do
  printf -v oct '\\%03o' "${i}"
  printf '%b' "${oct}"
done >"${stdin_file}"
printf '\r\n\0end\n' >>"${stdin_file}"
export FAKE_RC=3 FAKE_STDERR="op の stderr"
run_op pass --reason "読むため" document get x
unset FAKE_RC FAKE_STDERR
stdin_file=""
if cmp -s "${work}/in.bin" "${work}/pass.out"; then
  ok "stdin の binary は op を通って stdout にそのまま出る"
else
  ng "stdin の binary は op を通って stdout にそのまま出る" "out=$(stat -c %s "${work}/pass.out")"
fi
if [[ $(<"${work}/pass.err") == "op の stderr" ]]; then
  ok "stderr は op の出したものだけ"
else
  ng "stderr は op の出したものだけ" "$(cat "${work}/pass.err")"
fi
if [[ ${rc} == 3 ]]; then
  ok "終了コードは op の終了コード"
else
  ng "終了コードは op の終了コード" "rc=${rc}"
fi
if [[ $(<"${FAKE_DIR}/ps.1.argv") == $'-NoProfile\n-NonInteractive\n-ExecutionPolicy\nBypass\n-OutputFormat\nText\n-EncodedCommand\nTEST-LAUNCHER-B64' ]]; then
  ok "powershell は -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand <launcher> で起こす"
else
  ng "powershell は -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand <launcher> で起こす" "$(cat "${FAKE_DIR}/ps.1.argv")"
fi

echo "== desktop"
reset
export WSLENV="WT_SESSION:WT_PROFILE_ID:"
export OP_CONNECT_HOST=https://connect.example
run_op desktop --reason "設定を読む" item get "a b"
unset WSLENV OP_CONNECT_HOST
if [[ $(payload_field '.mode') == desktop && $(payload_field '.op') == 'C:\fake'"${op_exe//\//\\}" ]] \
  && expect_payload_args item get "a b"; then
  ok "payload の mode は desktop、op は Windows のパス、args64 は op の引数"
else
  ng "payload の mode は desktop、op は Windows のパス、args64 は op の引数" "$(payload_of)"
fi
if grep -qx 'WSLENV=WT_SESSION:WT_PROFILE_ID:PJP_OP_PAYLOAD' <<<"$(env_of)" && grep -qx 'SA=<unset>' <<<"$(env_of)" \
  && grep -qx 'CH=<unset>' <<<"$(env_of)"; then
  ok "WSLENV は呼び手の値に PJP_OP_PAYLOAD を足したもので、token と Connect の env は渡さない"
else
  ng "WSLENV は呼び手の値に PJP_OP_PAYLOAD を足したもので、token と Connect の env は渡さない" "$(env_of)"
fi
labels=$(payload_field '[.ui.lines[][0]] | join(",")')
if [[ ${labels} == 時刻,呼び手,場所,理由,コマンド && $(payload_field '.ui.lines[] | select(.[0] == "理由") | .[1]') == 設定を読む &&
$(payload_field '.ui.lines[] | select(.[0] == "コマンド") | .[1]') == 'op item get "a b"' &&
$(payload_field '.ui.footer') == *この窓が出ていない* && $(payload_field '.ui.toast | length') == 3 ]]; then
  ok "窓の行は 時刻・呼び手・場所・理由・コマンドで、footer に「この窓が出ていない」"
else
  ng "窓の行は 時刻・呼び手・場所・理由・コマンドで、footer に「この窓が出ていない」" "$(payload_field '.ui')"
fi

echo "== service account・Connect"
reset
export OP_SERVICE_ACCOUNT_TOKEN=tok-SECRET
run_op sa --reason "CI で読む" vault list
unset OP_SERVICE_ACCOUNT_TOKEN
if [[ ${rc} == 0 && $(payload_field '.mode') == service && $(payload_field '.ui') == null ]] \
  && grep -qx 'WSLENV=PJP_OP_PAYLOAD:OP_SERVICE_ACCOUNT_TOKEN/w:OP_BIOMETRIC_UNLOCK_ENABLED/w' <<<"$(env_of)" \
  && grep -qx 'SA=tok-SECRET' <<<"$(env_of)" && grep -qx 'BIO=false' <<<"$(env_of)" \
  && [[ $(last_field start '.kind') == service-account ]]; then
  ok "service account は service の mode・token と OP_BIOMETRIC_UNLOCK_ENABLED=false を /w で渡す・kind は service-account"
else
  ng "service account は service の mode・token と OP_BIOMETRIC_UNLOCK_ENABLED=false を /w で渡す・kind は service-account" "rc=${rc} $(env_of) $(payload_of)"
fi
reset
export OP_CONNECT_HOST=https://connect.example OP_CONNECT_TOKEN=ctok-SECRET
run_op connect --reason "Connect で読む" item get a
unset OP_CONNECT_HOST OP_CONNECT_TOKEN
if [[ $(payload_field '.mode') == service && $(last_field start '.kind') == connect ]] \
  && grep -qx 'WSLENV=PJP_OP_PAYLOAD:OP_CONNECT_HOST/w:OP_CONNECT_TOKEN/w:OP_BIOMETRIC_UNLOCK_ENABLED/w' <<<"$(env_of)"; then
  ok "Connect の 2 つが揃えば service (kind は connect)"
else
  ng "Connect の 2 つが揃えば service (kind は connect)" "$(env_of) $(payload_of)"
fi
if ! grep -qE 'tok-SECRET|ctok-SECRET' "${log}"; then
  ok "token はログに書かない"
else
  ng "token はログに書かない" "$(cat "${log}")"
fi

echo "== 伏せる"
reset
run_op mask --reason "項目を作る" item create password=hunter2 --session sess1 --secret-key=A3-XYZ op://v/i/f?attribute=otp
masked=$(last_field start '.args | join(" ")')
cmdline=$(payload_field '.ui.lines[] | select(.[0] == "コマンド") | .[1]')
if [[ ${masked} == 'item create password=*** --session *** --secret-key=*** op://v/i/f?attribute=otp' &&
  ${cmdline} == "op ${masked}" ]] && ! grep -qE 'hunter2|sess1|A3-XYZ' "${log}" \
  && expect_payload_args item create password=hunter2 --session sess1 --secret-key=A3-XYZ op://v/i/f?attribute=otp; then
  ok "password=… と --session・--secret-key の値はログと窓で *** にし、op にはそのまま渡す"
else
  ng "password=… と --session・--secret-key の値はログと窓で *** にし、op にはそのまま渡す" "log=${masked} ui=${cmdline}"
fi

echo "== 結果"
check_result() {
  local want=$1
  reset
  run_op result --reason "結果を見る" item get a
  local id_s id_e secs
  id_s=$(last_field start '.id')
  id_e=$(last_field end '.id')
  secs=$(last_field end '.seconds')
  if [[ $(last_field end '.result') == "${want}" && -n ${id_s} && ${id_s} == "${id_e}" && ${secs} =~ ^[0-9]+$ ]]; then
    ok "$2 → ${want} (start と end は同じ id)"
  else
    ng "$2 → ${want} (start と end は同じ id)" "$(cat "${log}" 2>&1)"
  fi
}
check_result approved "op が 0 で終わる"
export FAKE_RC=1 FAKE_STDERR="[ERROR] 2026/11/08 00:00:00 authorization prompt dismissed, please try again"
check_result denied "拒否の文言"
export FAKE_STDERR="[ERROR] 2026/11/08 00:00:00 authorization timeout"
check_result timeout "時間切れの文言"
export FAKE_STDERR="[ERROR] 2026/11/08 00:00:00 \"a\" isn't an item"
check_result failed "ほかの失敗"
unset FAKE_RC FAKE_STDERR
export FAKE_PS_NO_STATUS=1
check_result launcher-failed "launcher が status を書かない"
unset FAKE_PS_NO_STATUS

echo "== 呼び手"
reset
make_proc claude
export HERDR_ENV=1 HERDR_WORKSPACE_ID=wX HERDR_PANE_ID=wX:p1 CLAUDE_CODE_SESSION_ID=s1
git init -q -b feat/x "${work}/repo"
git -C "${work}/repo" remote add origin git@github.com:o/r.git
(cd "${work}/repo" && "${BASH}" "${script}" --reason "呼び手を見る" item get a </dev/null >/dev/null 2>&1)
unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID CLAUDE_CODE_SESSION_ID
start=$(last start)
if [[ $(jq -r '.caller.type' <<<"${start}") == claude && $(jq -r '.caller.claude_pid' <<<"${start}") == 999 &&
$(jq -r '.caller.herdr.label' <<<"${start}") == "TKT-1 テスト" && $(jq -r '.caller.herdr.pane' <<<"${start}") == wX:p1 &&
$(jq -r '.caller.repo' <<<"${start}") == o/r && $(jq -r '.caller.branch' <<<"${start}") == feat/x &&
$(jq -r '.session' <<<"${start}") == s1 && $(last_field end '.session') == s1 ]]; then
  ok "claude の祖先・herdr の label と pane・git の repo と branch・session を書く"
else
  ng "claude の祖先・herdr の label と pane・git の repo と branch・session を書く" "${start}"
fi
if [[ $(payload_field '.ui.lines[] | select(.[0] == "herdr") | .[1]') == "workspace「TKT-1 テスト」 · pane wX:p1" &&
$(payload_field '.ui.lines[] | select(.[0] == "呼び手") | .[1]') == "Claude Code (pid 999)" ]]; then
  ok "窓に Claude Code (pid) と herdr の workspace・pane を出す"
else
  ng "窓に Claude Code (pid) と herdr の workspace・pane を出す" "$(payload_field '.ui.lines')"
fi
reset
make_proc fish
run_op human --reason "人が打つ" item get a
if [[ $(last_field start '.caller.type') == human && $(last_field start '.caller.herdr') == null &&
$(payload_field '.ui.lines[] | select(.[0] == "呼び手") | .[1]') == "人 (端末)" ]]; then
  ok "claude の祖先が無ければ human、herdr の外なら herdr は null"
else
  ng "claude の祖先が無ければ human、herdr の外なら herdr は null" "$(last start)"
fi

echo "== lock"
reset
mkdir -p "${XDG_STATE_HOME}/pjp-op"
printf '%s\n' '{"time":"00:00:00","caller":"Claude Code","reason":"前の理由","command":"op item get z"}' >"${XDG_STATE_HOME}/pjp-op/current.json"
flock "${XDG_STATE_HOME}/pjp-op/lock" sleep 3 &
holder=$!
sleep 0.5
export PJP_OP_LOCK_WAIT=1
run_op lock --reason "待つ" item get a
unset PJP_OP_LOCK_WAIT
err=$(<"${work}/lock.err")
if [[ ${rc} == 75 && ${err} == *"1 秒"* && ${err} == *前の理由* && $(ps_count) == 0 &&
$(last_field refused '.why') == lock-timeout ]]; then
  ok "lock の上限を超えたら 75・待った秒と待たせている呼び出しの理由・powershell を呼ばない"
else
  ng "lock の上限を超えたら 75・待った秒と待たせている呼び出しの理由・powershell を呼ばない" "rc=${rc} ps=$(ps_count) err=${err}"
fi
wait "${holder}" 2>/dev/null

echo "== 共有の承認の見張り"
reset
touch "${FAKE_DIR}/shared"
export HERDR_ENV=1 HERDR_WORKSPACE_ID=wX HERDR_PANE_ID=wX:p1
run_op shared --reason "見張りを見る" item get a
unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID
notify_mode=""
for _ in $(seq 50); do
  # サンドボックスの bash は compgen (補完の組み込み) を持たないので、glob で見る
  for f in "${FAKE_DIR}"/notify.*.payload; do
    [[ ! -e ${f} ]] || notify_mode=yes
  done
  [[ -z ${notify_mode} ]] || break
  sleep 0.1
done
if grep -qx signout "${FAKE_DIR}/op.direct" && [[ $(last_field shared-approval '.when') == start &&
$(last_field shared-approval '.cleared') == true && $(last_field end '.watch.start') == cleared &&
-n ${notify_mode} && -s ${FAKE_DIR}/herdr.notify ]]; then
  ok "直の whoami が通れば signout で消し、ログ・powershell の notify・herdr の通知で知らせる"
else
  ng "直の whoami が通れば signout で消し、ログ・powershell の notify・herdr の通知で知らせる" \
    "direct=$(tr '\n' ' ' <"${FAKE_DIR}/op.direct" 2>&1) notify=${notify_mode} herdr=$(cat "${FAKE_DIR}/herdr.notify" 2>&1) files=$(ls "${FAKE_DIR}") log=$(cat "${log}")"
fi
reset
run_op noshared --reason "見張りを見る" item get a
if ! grep -qx signout "${FAKE_DIR}/op.direct" 2>/dev/null && [[ $(grep -c whoami "${FAKE_DIR}/op.direct") == 2 &&
$(last_field end '.watch.start') == none && $(last_field end '.watch.end') == none ]]; then
  ok "直の whoami が通らなければ signout を打たない (始まりと終わりに 1 回ずつ見る)"
else
  ng "直の whoami が通らなければ signout を打たない (始まりと終わりに 1 回ずつ見る)" "$(tr '\n' ' ' <"${FAKE_DIR}/op.direct" 2>&1)"
fi

echo "== 無いとき"
reset
PJP_OP_EXE=${work}/win/no-such-op.exe run_op noop --reason "無い" item get a
if [[ ${rc} == 127 && $(last_field refused '.why') == no-op-exe && $(ps_count) == 0 ]]; then
  ok "op.exe が無ければ 127 (refused no-op-exe)"
else
  ng "op.exe が無ければ 127 (refused no-op-exe)" "rc=${rc} err=$(cat "${work}/noop.err")"
fi
reset
PJP_OP_POWERSHELL=${work}/no-such-powershell.exe run_op nops --reason "無い" item get a
if [[ ${rc} == 127 && $(last_field refused '.why') == no-powershell ]]; then
  ok "powershell.exe が無ければ 127 (refused no-powershell)"
else
  ng "powershell.exe が無ければ 127 (refused no-powershell)" "rc=${rc} err=$(cat "${work}/nops.err")"
fi

echo "== TERM"
reset
export FAKE_SLEEP=2
"${BASH}" "${script}" --reason "止める" item get a </dev/null >"${work}/term.out" 2>"${work}/term.err" &
pid=$!
for _ in $(seq 50); do
  [[ -e ${FAKE_DIR}/op.args ]] && break
  sleep 0.1
done
kill -TERM "${pid}"
rc=0
wait "${pid}" || rc=$?
unset FAKE_SLEEP
if [[ ${rc} == 143 && $(last_field end '.result') == interrupted ]]; then
  ok "TERM を受けたら end に interrupted を書いて 143 で終わる"
else
  ng "TERM を受けたら end に interrupted を書いて 143 で終わる" "rc=${rc} log=$(cat "${log}" 2>&1)"
fi
sleep 2.5

echo "== ログを回す・片付け"
reset
mkdir -p "${XDG_STATE_HOME}/pjp-op"
pad=$(printf 'x%.0s' $(seq 1000))
for _ in $(seq 1100); do
  printf '{"v":1,"event":"pad","pad":"%s"}\n' "${pad}"
done >"${log}"
run_op rotate --reason "回す" item get a
if [[ -s ${XDG_STATE_HOME}/pjp-op/log.1.jsonl && $(jq -r .event "${log}" | tr '\n' ' ') == "start end " ]]; then
  ok "1 MiB を超えたら log.1.jsonl へ回す"
else
  ng "1 MiB を超えたら log.1.jsonl へ回す" "$(jq -r .event "${log}" | sort | uniq -c)"
fi
if [[ -z $(ls -A "${XDG_STATE_HOME}/pjp-op/run" 2>/dev/null) ]]; then
  ok "呼び出しの後に run/ の下を残さない"
else
  ng "呼び出しの後に run/ の下を残さない" "$(ls -lR "${XDG_STATE_HOME}/pjp-op/run")"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
