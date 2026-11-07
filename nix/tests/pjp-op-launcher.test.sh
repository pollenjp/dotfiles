#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/pjp-op/launcher.ps1 (WSL の op が呼び出しごとに起こす powershell の中身) を、Linux の pwsh と偽の op で確かめる。
#
#   bash nix/tests/pjp-op-launcher.test.sh [<launcher.ps1 のパス> [<package の launcher の dir>]]
#
# flake の checks (pjp-op-launcher-test) が Nix のサンドボックスで流す。pwsh (nixpkgs の powershell) と jq が要る。
# 本物の Windows PowerShell 5.1・op.exe・窓・通知は使わない (Linux の launcher は窓と通知を出さずに skipped と書く)。
# 2 つ目の引数は package が build のときに作る dir (script.b64 と command.b64。pkgs/pjp-op/default.nix)。省くと、本番と同じ
# 起動の式で流す確かめを飛ばす (flake の check は渡す)。
#
# ## 確かめること
#
#   op に届くもの (desktop の mode で流す)
#     - 引数は、空・空白・引用符・末尾の \・\"・& | < > ^ % !・日本語・前後の空白・改行・タブ・" だけ・\ だけ・絵文字を
#       含んでも、1 つずつそのままの並びで届く (launcher が Windows の規則で command line を組み、.NET が同じ規則で分ける)
#     - stdin の binary (0〜255 と \r\n と \0) が、そのまま stdout に出る (PowerShell の pipeline を通さない)
#     - stderr は op の出したものだけ (CLIXML・進捗の文を混ぜない)
#     - 終了コードは op の終了コード
#     - payload の env (PJP_OP_PAYLOAD) を op に継がせない
#   本番と同じ起動の式 (-EncodedCommand の command.b64 が env の PJP_OP_SCRIPT から本体を読む) でも、引数・stdin・stderr・
#   終了コードが同じに通り、PJP_OP_SCRIPT を op に継がせない
#   承認を閉じる
#     - desktop は op の後に whoami を打ち、承認があったときだけ signout --all を打つ (status の signout は ok か not-signed-in)
#     - whoami と signout の stdout・stderr は、launcher の stdout・stderr に出さない
#     - help も同じく whoami で確かめてから閉じ、service は whoami も signout も打たない (status の signout は skipped)
#   service は呼び手の OP_SERVICE_ACCOUNT_TOKEN を op にそのまま継がせる
#   Linux では窓と通知を出さない (status の window・toast は skipped)。status の started は true、exit は op の終了コード
#   op が無い → 127 で終わり、stderr は pjp-op: で始まる 1 行、status の started は false
#   notify は 0 で終わり、op を起こさない
#
# ## 作り
#
# 偽の op (bash) は、呼ばれるたびに番号を 1 つ進め、引数を NUL 区切りで FAKE_DIR/call.<番号> に、PJP_OP_PAYLOAD の有無と
# OP_SERVICE_ACCOUNT_TOKEN を FAKE_DIR/env.<番号> に書く。第 1 引数が whoami なら FAKE_WHOAMI_RC (既定 1) で終わり、
# signout なら stdout に SIGNOUT-OUT・stderr に SIGNOUT-ERR を出して 0 で終わる。ほかは stdin を stdout へ写し、stderr に
# 「FAKE-ERR 日本語」を出して FAKE_RC (既定 0) で終わる。payload の args64 は引数ごとの UTF-8 の base64 (本物の op.sh と同じ)。
# shebang は $BASH から作る (サンドボックスに /usr/bin/env が無い)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
launcher=${1:-${here}/../pkgs/pjp-op/launcher.ps1}
launcher_dir=${2:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-op-launcher-test.XXXXXX")
work=$(cd "${work}" && pwd -P)
trap 'rm -rf "${work}"' EXIT

export HOME=${work}/home
mkdir -p "${HOME}"
export POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
export LC_ALL=C.UTF-8

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

fake_dir=${work}/fake
mkdir -p "${fake_dir}"
export FAKE_DIR=${fake_dir}
fake_op=${fake_dir}/op
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
d=${FAKE_DIR}
n=$(($(cat "${d}/n" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${d}/n"
printf '%s\0' "$@" >"${d}/call.${n}"
{
  if [[ -n ${PJP_OP_PAYLOAD+x} ]]; then echo "payload=present"; else echo "payload=absent"; fi
  if [[ -n ${PJP_OP_SCRIPT+x} ]]; then echo "script=present"; else echo "script=absent"; fi
  echo "sa=${OP_SERVICE_ACCOUNT_TOKEN-<unset>}"
} >"${d}/env.${n}"
case ${1-} in
  whoami) exit "${FAKE_WHOAMI_RC:-1}" ;;
  signout)
    echo SIGNOUT-OUT
    echo SIGNOUT-ERR >&2
    exit 0
    ;;
esac
cat
printf 'FAKE-ERR 日本語\n' >&2
exit "${FAKE_RC:-0}"
EOF
} >"${fake_op}"
chmod +x "${fake_op}"

launcher_command=""
launcher_script=""
if [[ -n ${launcher_dir} ]]; then
  launcher_command=$(<"${launcher_dir}/command.b64")
  launcher_script=$(<"${launcher_dir}/script.b64")
fi

# payload <mode> <op のパス> <引数>…: payload の JSON (args64 は引数ごとの UTF-8 の base64)
payload() {
  local mode=$1 op=$2 a
  shift 2
  local -a enc=()
  for a in "$@"; do
    enc+=("$(printf '%s' "${a}" | base64 -w0)")
  done
  jq -cn --arg mode "${mode}" --arg op "${op}" --arg status "${work}/status.json" \
    '{mode: $mode, op: $op, status: $status, args64: $ARGS.positional}' --args -- "${enc[@]}"
}

# run <名前> <payload> [encoded]: launcher を流す。stdin は stdin_file (無ければ /dev/null)。
# stdout・stderr を ${work}/<名前>.out・.err に、終了コードを rc に入れる
run() {
  local name=$1 json=$2 how=${3:-file}
  rm -f "${fake_dir}"/n "${fake_dir}"/call.* "${fake_dir}"/env.* "${work}/status.json"
  rc=0
  if [[ ${how} == encoded ]]; then
    PJP_OP_SCRIPT=${launcher_script} PJP_OP_PAYLOAD=${json} pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass \
      -OutputFormat Text -EncodedCommand "${launcher_command}" \
      <"${stdin_file:-/dev/null}" >"${work}/${name}.out" 2>"${work}/${name}.err" || rc=$?
  else
    PJP_OP_PAYLOAD=${json} pwsh -NoProfile -NonInteractive -OutputFormat Text -File "${launcher}" \
      <"${stdin_file:-/dev/null}" >"${work}/${name}.out" 2>"${work}/${name}.err" || rc=$?
  fi
}

# call_args <番号>: 偽の op の <番号> 回目の引数 (NUL 区切りのまま)
call_args() {
  cat "${fake_dir}/call.$1" 2>/dev/null
}

# expect_args <番号> <引数>…: <番号> 回目の引数が、渡した並びと同じなら 0
expect_args() {
  local n=$1
  shift
  cmp -s <(call_args "${n}") <(printf '%s\0' "$@")
}

calls() {
  cat "${fake_dir}/n" 2>/dev/null || echo 0
}

status_field() {
  jq -r "$1" "${work}/status.json" 2>/dev/null
}

# shellcheck disable=SC1003 # \ で終わる引数そのものを確かめる
tricky=(
  "" "a b" 'x"y' 'tr\\' 'q\"z' '&|<>^%PATH%!' "日本語 の 引数" "  lead" "trail  " $'new\nline' $'tab\there' '"' '\' "😀"
)
in_bin=${work}/in.bin
for _ in $(seq 40); do
  for i in $(seq 0 255); do
    printf -v oct '\\%03o' "${i}"
    printf '%b' "${oct}"
  done
done >"${in_bin}"
printf '\r\n\0end\n' >>"${in_bin}"

echo "== op に届くもの (desktop)"
stdin_file=${in_bin}
export FAKE_RC=42
run desktop "$(payload desktop "${fake_op}" "${tricky[@]}")"
unset FAKE_RC
stdin_file=""
if expect_args 1 "${tricky[@]}"; then
  ok "難しい引数が 1 つずつそのままの並びで届く"
else
  ng "難しい引数が 1 つずつそのままの並びで届く" "$(call_args 1 | tr '\0' '|')"
fi
if cmp -s "${in_bin}" "${work}/desktop.out"; then
  ok "stdin の binary が stdout にそのまま出る"
else
  ng "stdin の binary が stdout にそのまま出る" "in=$(stat -c %s "${in_bin}") out=$(stat -c %s "${work}/desktop.out")"
fi
if [[ $(<"${work}/desktop.err") == "FAKE-ERR 日本語" ]]; then
  ok "stderr は op の出したものだけ"
else
  ng "stderr は op の出したものだけ" "$(head -c 400 "${work}/desktop.err")"
fi
if [[ ${rc} == 42 ]]; then
  ok "終了コードは op の終了コード"
else
  ng "終了コードは op の終了コード" "rc=${rc}"
fi
if grep -qx "payload=absent" "${fake_dir}/env.1"; then
  ok "PJP_OP_PAYLOAD を op に継がせない"
else
  ng "PJP_OP_PAYLOAD を op に継がせない" "$(cat "${fake_dir}/env.1" 2>&1)"
fi
if [[ $(status_field '.window') == skipped && $(status_field '.toast') == skipped &&
$(status_field '.started') == true && $(status_field '.exit') == 42 ]]; then
  ok "Linux では窓と通知を出さず、status に started と op の終了コードを書く"
else
  ng "Linux では窓と通知を出さず、status に started と op の終了コードを書く" "$(cat "${work}/status.json" 2>&1)"
fi

echo "== 本番と同じ起動の式で流す"
if [[ -z ${launcher_dir} ]]; then
  echo "  skip 2 つ目の引数 (package の launcher の dir) が無いので飛ばす"
else
  stdin_file=${in_bin}
  export FAKE_RC=7
  run encoded "$(payload desktop "${fake_op}" "${tricky[@]}")" encoded
  unset FAKE_RC
  stdin_file=""
  if expect_args 1 "${tricky[@]}" && cmp -s "${in_bin}" "${work}/encoded.out" \
    && [[ $(<"${work}/encoded.err") == "FAKE-ERR 日本語" && ${rc} == 7 ]]; then
    ok "起動の式でも引数・stdin・stderr・終了コードが同じに通る"
  else
    ng "起動の式でも引数・stdin・stderr・終了コードが同じに通る" \
      "rc=${rc} args=$(call_args 1 | tr '\0' '|') err=$(head -c 400 "${work}/encoded.err")"
  fi
  if grep -qx "script=absent" "${fake_dir}/env.1" && grep -qx "payload=absent" "${fake_dir}/env.1"; then
    ok "起動の式は PJP_OP_SCRIPT と PJP_OP_PAYLOAD を op に継がせない"
  else
    ng "起動の式は PJP_OP_SCRIPT と PJP_OP_PAYLOAD を op に継がせない" "$(cat "${fake_dir}/env.1" 2>&1)"
  fi
fi

echo "== 承認を閉じる"
export FAKE_WHOAMI_RC=0
run closes "$(payload desktop "${fake_op}" item get x)"
if [[ $(calls) == 3 ]] && expect_args 1 item get x && expect_args 2 whoami && expect_args 3 signout --all \
  && [[ $(status_field '.signout') == ok ]]; then
  ok "desktop は op の後に whoami を打ち、承認があれば signout --all を打つ"
else
  ng "desktop は op の後に whoami を打ち、承認があれば signout --all を打つ" "calls=$(calls) status=$(cat "${work}/status.json" 2>&1)"
fi
if ! grep -q SIGNOUT "${work}/closes.out" "${work}/closes.err"; then
  ok "whoami と signout の stdout・stderr は launcher の stdout・stderr に出さない"
else
  ng "whoami と signout の stdout・stderr は launcher の stdout・stderr に出さない" \
    "out=$(cat "${work}/closes.out") err=$(cat "${work}/closes.err")"
fi
export FAKE_WHOAMI_RC=1
run notsigned "$(payload desktop "${fake_op}" item get x)"
if [[ $(calls) == 2 ]] && expect_args 2 whoami && [[ $(status_field '.signout') == not-signed-in ]]; then
  ok "承認が無ければ signout を打たない (status は not-signed-in)"
else
  ng "承認が無ければ signout を打たない (status は not-signed-in)" "calls=$(calls) status=$(cat "${work}/status.json" 2>&1)"
fi
export FAKE_WHOAMI_RC=0
run help "$(payload help "${fake_op}" --version)"
if [[ $(calls) == 3 ]] && expect_args 1 --version && expect_args 2 whoami && expect_args 3 signout --all \
  && [[ $(status_field '.window') == skipped && $(status_field '.toast') == skipped ]]; then
  ok "help も whoami で確かめてから閉じ、窓と通知は出さない"
else
  ng "help も whoami で確かめてから閉じ、窓と通知は出さない" "calls=$(calls) status=$(cat "${work}/status.json" 2>&1)"
fi
export OP_SERVICE_ACCOUNT_TOKEN=tok-test
run service "$(payload service "${fake_op}" vault list)"
unset OP_SERVICE_ACCOUNT_TOKEN
if [[ $(calls) == 1 ]] && expect_args 1 vault list && [[ $(status_field '.signout') == skipped ]]; then
  ok "service は whoami も signout も打たない (status の signout は skipped)"
else
  ng "service は whoami も signout も打たない (status の signout は skipped)" "calls=$(calls) status=$(cat "${work}/status.json" 2>&1)"
fi
if grep -qx "sa=tok-test" "${fake_dir}/env.1"; then
  ok "service は OP_SERVICE_ACCOUNT_TOKEN を op にそのまま継がせる"
else
  ng "service は OP_SERVICE_ACCOUNT_TOKEN を op にそのまま継がせる" "$(cat "${fake_dir}/env.1" 2>&1)"
fi
unset FAKE_WHOAMI_RC

echo "== 起こせないとき・notify"
run missing "$(payload desktop "${work}/no-such-op" item get x)"
err=$(<"${work}/missing.err")
if [[ ${rc} == 127 && ${err} == pjp-op:* && ${err} != *$'\n'* && $(status_field '.started') == false && $(calls) == 0 ]]; then
  ok "op が無ければ 127 で終わり、stderr は pjp-op: の 1 行、started は false"
else
  ng "op が無ければ 127 で終わり、stderr は pjp-op: の 1 行、started は false" "rc=${rc} err=${err} status=$(cat "${work}/status.json" 2>&1)"
fi
run notify "$(jq -cn '{mode: "notify", ui: {title: "t", lines: [["a", "b"]], toast: ["t", "a", "b"]}}')"
if [[ ${rc} == 0 && $(calls) == 0 && ! -s ${work}/notify.err ]]; then
  ok "notify は 0 で終わり、op を起こさない"
else
  ng "notify は 0 で終わり、op を起こさない" "rc=${rc} calls=$(calls) err=$(cat "${work}/notify.err")"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
