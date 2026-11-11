#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/pjp-op-ref/pjp-op-ref.sh (1Password の名前の参照を ID の参照に直す) を、偽の op と偽の項目 (op item get
# --format json の形の JSON) で確かめる。後半 (「pjp-op を通す」) は本物の op.sh (nix/pkgs/pjp-op/op.sh) を、pjp-op.test.sh と
# 同じ形の偽の powershell.exe・op.exe・wslpath で通す。
#
#   bash nix/tests/pjp-op-ref.test.sh [<pjp-op-ref.sh のパス> [<op.sh のパス>]]
#
# flake の checks (pjp-op-ref-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・jq・flock (util-linux)・strace。
# 本物の 1Password・op.exe・powershell.exe は使わない。偽の項目の値 (value・totp・additional_information) はどれも S3CR3T を
# 含む (漏れを探す印)。vault・項目・セクション・欄の ID と名前はどれも作り物。
#
# ## 確かめること
#
#   直す
#     - 名前の参照 (vault・項目・セクション・欄が名前) を、どれも ID の参照に直す
#     - 一部が ID の参照 (vault・項目・セクション・欄のどれかが ID) も直し、ID の部分はその ID のまま
#     - セクションの無い欄は op://<vault>/<項目>/<欄> (作りつけの欄 password も)。参照にセクションが無くても、欄に
#       セクションがあればセクションの ID を入れる
#     - セクション・欄の名前は大文字小文字を問わずに当てる
#     - ?attribute=…・?attr=… は後ろにそのまま付ける
#     - セクションの ID に空白がある (add more) ときはそのまま出し、.env では引用符で囲むよう stderr に出す
#     - 出す順は渡した参照の順
#   op の回数と引数
#     - 同じ項目の参照は op を 1 回にまとめる。項目が 2 つなら 2 回で、項目は初めて出た順に読む。同じ名前の項目でも vault が
#       違えば別に読む。同じ項目でも書き方 (名前か ID か) が違えば別に読む
#     - op に渡すのは item get <項目> --vault <vault> --format json。claude-op-reason.json の enable が true なら、前に
#       --reason "[pjp-op-ref: 参照 <N> 件を ID の形に直す (項目 <k>/<M>)。ID だけを抜き出し、値は捨てる] <理由>" を付ける
#       (項目が 1 つなら (項目 …) は無い。理由の改行とタブは空白)。false・無いなら付けない
#   止まる
#     - 欄が無い・セクションが無い (件数 0)、同じ名前の欄・セクションが 2 つ以上 (件数) は 1 で、参照と件数を出す。
#       ほかの参照が直せても stdout には何も出さない
#     - op が 0 以外 (1・75) で終われば、その終了コードで止まり、残りの項目は読まない。stdout には何も出さない
#     - op の出力の形が合わない (空・JSON でない・2 項目・vault の ID が無い・sections や fields が配列でない・ID に / がある)
#       なら 70
#     - 引数の誤り (理由が無い・空・空白だけ、参照が無い、知らない option、op:// で始まらない、部分が 3 つか 4 つでない、空の
#       部分、制御文字、- で始まる vault・項目) は 2 で、op を呼ばない (正しい参照と並べても)
#     - op が無ければ 127
#   漏らさない
#     - どの場合も、stdout・stderr に値が無い (op の誤りの文も、jq が値を入れて出しうる型の誤りの文も)
#     - 流した後、HOME・XDG_STATE_HOME・XDG_RUNTIME_DIR・TMPDIR・cwd のどのファイルにも値が無い
#     - helper から起きたどのプロセスの execve の argv にも値が無い (strace)
#     - SHELLOPTS=xtrace・BASH_ENV (set -x) を付けて流しても、stderr に値が無い
#   出す 1 行: stderr に参照の件数と op の回数を出し、--quiet なら出さない。--help は 0
#   pjp-op を通す (本物の op.sh)
#     - 参照 2 件で、承認の出る呼び出し (desktop の mode の powershell) が 1 回、op.exe の item get が 1 回で、ID の参照が出る
#     - log.jsonl に値が無く、start の args は item get の引数、reason の頭は [pjp-op-ref: 参照 2 件
#     - 流した後、HOME・XDG_STATE_HOME・XDG_RUNTIME_DIR・TMPDIR・cwd のどのファイルにも値が無い
#
# ## 作り
#
# 偽の op は、呼ばれるたびに引数を FAKE_DIR/op.<番号>.args (NUL 区切り) に書き、item get <項目> --vault <vault> --format json
# なら、偽の項目 (FAKE_ITEMS/*.json) から vault の名前か ID と、項目の名前か ID が合うもの (大文字小文字は問わない) を
# stdout に出す。合うものが無い・2 つ以上なら [ERROR] を出して 1。FAKE_OP_RC (その終了コードで断る)・FAKE_OP_OUT (項目の
# 代わりにそのファイルを出す) で形を変える。whoami・signout (pjp-op の見張り) は FAKE_DIR/op.direct に書いて 1・0 で終わる。
# 同じものを op.exe としても置く。shebang は $BASH から作り、set +x で始める (本物の op.exe は bash ではなく、BASH_ENV の
# set -x を受けない)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../pkgs/pjp-op-ref/pjp-op-ref.sh}
opsh=${2:-${here}/../pkgs/pjp-op/op.sh}
# cwd を移してから流すので、絶対パスにする
script=$(cd -- "$(dirname "${script}")" && pwd -P)/$(basename "${script}")
opsh=$(cd -- "$(dirname "${opsh}")" && pwd -P)/$(basename "${opsh}")
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-op-ref-test.XXXXXX")
work=$(cd "${work}" && pwd -P)
trap 'rm -rf "${work}"' EXIT

export LC_ALL=C.UTF-8
export HOME=${work}/home XDG_STATE_HOME=${work}/state XDG_RUNTIME_DIR=${work}/runtime TMPDIR=${work}/tmp
export FAKE_DIR=${work}/fake FAKE_ITEMS=${work}/items
fake_bin=${work}/bin
proj=${work}/proj
mkdir -p "${HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${FAKE_DIR}" "${FAKE_ITEMS}" "${fake_bin}" "${proj}" \
  "${work}/win" "${work}/launcher"
export PATH=${fake_bin}:${PATH}
unset WSLENV HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID CLAUDE_CODE_SESSION_ID OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST \
  OP_CONNECT_TOKEN OP_BIOMETRIC_UNLOCK_ENABLED PJP_OP_REF_OP BASH_ENV FAKE_OP_RC FAKE_OP_OUT

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

# fake <名前かパス> <<'EOF' … EOF: 偽のコマンドを fake_bin (かそのパス) に置く。本文は stdin から読む
fake() {
  local path=$1
  [[ ${path} == /* ]] || path=${fake_bin}/${path}
  {
    printf '#!%s\n' "${BASH}"
    cat
  } >"${path}"
  chmod +x "${path}"
}

fake op <<'EOF'
set +x
d=${FAKE_DIR}
case ${1-} in
  whoami)
    echo "$*" >>"${d}/op.direct"
    exit 1
    ;;
  signout)
    echo "$*" >>"${d}/op.direct"
    exit 0
    ;;
esac
n=$(($(cat "${d}/op.n" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${d}/op.n"
printf '%s\0' "$@" >"${d}/op.${n}.args"
if [[ -n ${FAKE_OP_RC:-} ]]; then
  printf '[ERROR] 2026/11/11 00:00:00 fake failure\n' >&2
  exit "${FAKE_OP_RC}"
fi
sub=()
vault=""
format=""
while (($# > 0)); do
  case $1 in
    --reason) shift 2 ;;
    --vault)
      vault=$2
      shift 2
      ;;
    --format)
      format=$2
      shift 2
      ;;
    *)
      sub+=("$1")
      shift
      ;;
  esac
done
if [[ ${sub[0]-} != item || ${sub[1]-} != get || ${#sub[@]} != 3 || -z ${vault} || ${format} != json ]]; then
  printf '[ERROR] 2026/11/11 00:00:00 fake op: unexpected arguments\n' >&2
  exit 64
fi
if [[ -n ${FAKE_OP_OUT:-} ]]; then
  cat "${FAKE_OP_OUT}"
  exit 0
fi
item=${sub[2]}
hits=()
for f in "${FAKE_ITEMS}"/*.json; do
  if jq -e --arg v "${vault,,}" --arg i "${item,,}" \
    '((.vault.id | ascii_downcase) == $v or (.vault.name | ascii_downcase) == $v)
      and ((.id | ascii_downcase) == $i or (.title | ascii_downcase) == $i)' "${f}" >/dev/null; then
    hits+=("${f}")
  fi
done
case ${#hits[@]} in
  1) cat "${hits[0]}" ;;
  0)
    printf '[ERROR] 2026/11/11 00:00:00 "%s" isn'"'"'t an item in the "%s" vault. Specify the item with its UUID, name, or domain.\n' \
      "${item}" "${vault}" >&2
    exit 1
    ;;
  *)
    printf '[ERROR] 2026/11/11 00:00:00 More than one item matches "%s". Try again and specify the item by its ID.\n' "${item}" >&2
    exit 1
    ;;
esac
EOF
cp "${fake_bin}/op" "${work}/win/op.exe"

# 偽の項目。ID と名前は作り物。値の入る鍵 (value・totp・additional_information) には S3CR3T を入れる
v1=vaultid0000000000000000001
v2=vaultid0000000000000000002
i1=itemid00000000000000000001
i2=itemid00000000000000000002
i3=itemid00000000000000000003
s1=sectionid00000000000000001
s2=sectionid00000000000000002
f1=fieldid0000000000000000001
f2=fieldid0000000000000000002
f3=fieldid0000000000000000003
f4=fieldid0000000000000000004
f5=fieldid0000000000000000005
f8=fieldid0000000000000000008
cat >"${FAKE_ITEMS}/example.json" <<'EOF'
{
  "id": "itemid00000000000000000001",
  "title": "Example Service",
  "version": 3,
  "vault": {
    "id": "vaultid0000000000000000001",
    "name": "Dev"
  },
  "category": "LOGIN",
  "additional_information": "S3CR3T-username",
  "sections": [
    { "id": "add more" },
    { "id": "sectionid00000000000000001", "label": "prod" },
    { "id": "sectionid00000000000000002", "label": "stg" },
    { "id": "sectionid00000000000000003", "label": "dup" },
    { "id": "sectionid00000000000000004", "label": "dup" }
  ],
  "fields": [
    { "id": "username", "type": "STRING", "purpose": "USERNAME", "label": "username", "value": "S3CR3T-username",
      "reference": "op://Dev/Example Service/username" },
    { "id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": "S3CR3T-password",
      "reference": "op://Dev/Example Service/password" },
    { "id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain", "value": "S3CR3T-notes" },
    { "id": "fieldid0000000000000000001", "section": { "id": "sectionid00000000000000001", "label": "prod" },
      "type": "CONCEALED", "label": "API_TOKEN", "value": "S3CR3T-prod-token",
      "reference": "op://Dev/Example Service/prod/API_TOKEN" },
    { "id": "fieldid0000000000000000002", "section": { "id": "sectionid00000000000000002", "label": "stg" },
      "type": "CONCEALED", "label": "API_TOKEN", "value": "S3CR3T-stg-token",
      "reference": "op://Dev/Example Service/stg/API_TOKEN" },
    { "id": "fieldid0000000000000000003", "section": { "id": "sectionid00000000000000001", "label": "prod" },
      "type": "STRING", "label": "Api Url", "value": "S3CR3T-url" },
    { "id": "fieldid0000000000000000004", "type": "CONCEALED", "label": "legacy key", "value": "S3CR3T-legacy" },
    { "id": "fieldid0000000000000000005", "section": { "id": "add more" }, "type": "STRING", "label": "note",
      "value": "S3CR3T-note" },
    { "id": "fieldid0000000000000000006", "section": { "id": "sectionid00000000000000003", "label": "dup" },
      "type": "STRING", "label": "x", "value": "S3CR3T-x1" },
    { "id": "fieldid0000000000000000007", "section": { "id": "sectionid00000000000000004", "label": "dup" },
      "type": "STRING", "label": "x", "value": "S3CR3T-x2" },
    { "id": "fieldid0000000000000000008", "type": "OTP", "label": "one-time password",
      "value": "otpauth://totp/S3CR3T-otp", "totp": "S3CR3T-123456" }
  ]
}
EOF
cat >"${FAKE_ITEMS}/other.json" <<'EOF'
{
  "id": "itemid00000000000000000002",
  "title": "Other Service",
  "vault": { "id": "vaultid0000000000000000001", "name": "Dev" },
  "category": "PASSWORD",
  "fields": [
    { "id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": "S3CR3T-other" }
  ]
}
EOF
cat >"${FAKE_ITEMS}/ops.json" <<'EOF'
{
  "id": "itemid00000000000000000003",
  "title": "Example Service",
  "vault": { "id": "vaultid0000000000000000002", "name": "Ops" },
  "category": "PASSWORD",
  "fields": [
    { "id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": "S3CR3T-ops" }
  ]
}
EOF

state_file=${HOME}/.local/state/dotfiles/claude-op-reason.json
# set_state <true|false|none>: pjp-op があるかの印 (home/modules/op-reason.nix が書くもの)
set_state() {
  rm -f "${state_file}"
  if [[ $1 != none ]]; then
    mkdir -p "${state_file%/*}"
    printf '{"enable":%s}\n' "$1" >"${state_file}"
  fi
}

reset() {
  rm -rf "${FAKE_DIR:?}"/* "${XDG_STATE_HOME}/pjp-op" "${XDG_RUNTIME_DIR:?}"/*
}

# run_ref <名前> <引数>…: proj の中で pjp-op-ref を流す。<名前>.stdout・<名前>.stderr と rc に入れる
run_ref() {
  local tag=$1
  shift
  rc=0
  (cd "${proj}" && "${BASH}" "${script}" "$@" </dev/null >"${work}/${tag}.stdout" 2>"${work}/${tag}.stderr") || rc=$?
}

op_count() {
  cat "${FAKE_DIR}/op.n" 2>/dev/null || echo 0
}
# op_args <番号>: その呼び出しの引数を | で区切って出す
op_args() {
  tr '\0' '|' <"${FAKE_DIR}/op.${1:-1}.args" 2>/dev/null
}
# args_is <番号> <期待>: その呼び出しの引数 (| 区切り) が期待どおりか
args_is() {
  [[ $(op_args "$1") == "$2" ]]
}
# out_is <名前> <行>…: <名前>.stdout がちょうどその行 (改行で終わる) か
out_is() {
  local tag=$1
  shift
  local want=""
  if (($# > 0)); then
    want=$(printf '%s\n' "$@")$'\n'
  fi
  local got
  got=$(
    cat "${work}/${tag}.stdout"
    printf x
  )
  [[ ${got%x} == "${want}" ]]
}
# show <名前>: 失敗のときに出す rc・stdout・stderr
show() {
  printf 'rc=%s\nstdout:\n%s\nstderr:\n%s\nop=%s args1=%s' "${rc}" "$(cat "${work}/$1.stdout")" "$(cat "${work}/$1.stderr")" \
    "$(op_count)" "$(op_args 1)"
}
# no_leak <ファイル>…: どのファイルにも S3CR3T が無い
no_leak() {
  ! grep -qaF S3CR3T -- "$@" 2>/dev/null
}
# quiet_leak <名前>: <名前>.stdout・<名前>.stderr に S3CR3T が無い
quiet_leak() {
  no_leak "${work}/$1.stdout" "${work}/$1.stderr"
}
# disk_clean: 置き場のどのファイルにも値 (S3CR3T) が無い
disk_clean() {
  ! grep -rqaF S3CR3T -- "${HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${proj}" 2>/dev/null
}
# check <説明> <条件の終了コード> <名前>: 条件が 0 で、出力に値が無ければ ok
check() {
  if [[ $2 == 0 ]] && quiet_leak "$3"; then
    ok "$1"
  else
    ng "$1" "$(show "$3")"
  fi
}

echo "== 直す"
reset
set_state false
run_ref name --reason "参照を ID の形にする" "op://Dev/Example Service/prod/API_TOKEN"
[[ ${rc} == 0 ]] && out_is name "op://${v1}/${i1}/${s1}/${f1}"
check "名前の参照を、vault・項目・セクション・欄の ID の参照に直す" $? name

reset
run_ref partial --reason "一部が ID" "op://${v1}/Example Service/${s2}/API_TOKEN" "op://Dev/${i1}/prod/${f3}" \
  "op://${v1}/${i1}/${s1}/${f1}"
[[ ${rc} == 0 ]] && out_is partial "op://${v1}/${i1}/${s2}/${f2}" "op://${v1}/${i1}/${s1}/${f3}" "op://${v1}/${i1}/${s1}/${f1}"
check "一部が ID の参照も直し、ID の部分はその ID のまま (書き方の違う同じ項目は別に読む)" $? partial
if [[ $(op_count) == 3 ]] && args_is 1 "item|get|Example Service|--vault|${v1}|--format|json|" \
  && args_is 2 "item|get|${i1}|--vault|Dev|--format|json|"; then
  ok "書き方 (名前か ID か) が違えば、同じ項目でも別に読む (op 3 回)"
else
  ng "書き方 (名前か ID か) が違えば、同じ項目でも別に読む (op 3 回)" "op=$(op_count) 1=$(op_args 1) 2=$(op_args 2)"
fi

reset
run_ref nosec --reason "セクションの無い欄" "op://Dev/Example Service/legacy key" "op://Dev/Example Service/password" \
  "op://Dev/Example Service/Api Url"
[[ ${rc} == 0 ]] && out_is nosec "op://${v1}/${i1}/${f4}" "op://${v1}/${i1}/password" "op://${v1}/${i1}/${s1}/${f3}"
check "セクションの無い欄は op://<vault>/<項目>/<欄>。参照に無くても欄にセクションがあれば入れる" $? nosec

reset
run_ref case --reason "大文字小文字" "op://dev/EXAMPLE SERVICE/PROD/api_token" "op://Dev/Example Service/api url"
[[ ${rc} == 0 ]] && out_is case "op://${v1}/${i1}/${s1}/${f1}" "op://${v1}/${i1}/${s1}/${f3}"
check "セクション・欄の名前は大文字小文字を問わずに当てる" $? case

reset
run_ref attr --reason "attribute" "op://Dev/Example Service/prod/API_TOKEN?attribute=type" \
  "op://Dev/Example Service/one-time password?attr=otp"
[[ ${rc} == 0 ]] && out_is attr "op://${v1}/${i1}/${s1}/${f1}?attribute=type" "op://${v1}/${i1}/${f8}?attr=otp"
check "?attribute=…・?attr=… は後ろにそのまま付ける" $? attr

reset
run_ref space --reason "空白のある ID" "op://Dev/Example Service/note"
[[ ${rc} == 0 ]] && out_is space "op://${v1}/${i1}/add more/${f5}" && grep -qF '引用符' "${work}/space.stderr"
check "セクションの ID に空白があればそのまま出し、.env では引用符で囲むよう stderr に出す" $? space

echo "== op の回数と引数"
reset
run_ref one --reason "同じ項目" "op://Dev/Example Service/prod/API_TOKEN" "op://Dev/Example Service/stg/API_TOKEN" \
  "op://dev/example service/password"
[[ ${rc} == 0 && $(op_count) == 1 && $(op_args 1) == 'item|get|Example Service|--vault|Dev|--format|json|' ]] \
  && out_is one "op://${v1}/${i1}/${s1}/${f1}" "op://${v1}/${i1}/${s2}/${f2}" "op://${v1}/${i1}/password"
check "同じ項目の参照 3 件は op 1 回 (item get <項目> --vault <vault> --format json)。出す順は渡した順" $? one

reset
run_ref two --reason "2 項目" "op://Dev/Example Service/prod/API_TOKEN" "op://Dev/Other Service/password" \
  "op://Dev/Example Service/stg/API_TOKEN" "op://Ops/Example Service/password"
[[ ${rc} == 0 && $(op_count) == 3 ]] && args_is 1 'item|get|Example Service|--vault|Dev|--format|json|' \
  && args_is 2 'item|get|Other Service|--vault|Dev|--format|json|' \
  && args_is 3 'item|get|Example Service|--vault|Ops|--format|json|' \
  && out_is two "op://${v1}/${i1}/${s1}/${f1}" "op://${v1}/${i2}/password" "op://${v1}/${i1}/${s2}/${f2}" \
    "op://${v2}/${i3}/password"
check "項目ごとに op を 1 回 (初めて出た順)。同じ名前の項目でも vault が違えば別に読む" $? two

reset
set_state true
run_ref reason1 --reason $'参照を\nID に\t直す' "op://Dev/Example Service/prod/API_TOKEN" "op://Dev/Example Service/password"
want='--reason|[pjp-op-ref: 参照 2 件を ID の形に直す。ID だけを抜き出し、値は捨てる] 参照を ID に 直す|item|get|Example Service|--vault|Dev|--format|json|'
[[ ${rc} == 0 ]] && args_is 1 "${want}" && out_is reason1 "op://${v1}/${i1}/${s1}/${f1}" "op://${v1}/${i1}/password"
check "enable が true なら --reason に件数と理由を付ける (改行とタブは空白)" $? reason1

reset
run_ref reason2 --reason "2 項目" "op://Dev/Example Service/password" "op://Dev/Other Service/password"
[[ ${rc} == 0 ]] \
  && args_is 1 '--reason|[pjp-op-ref: 参照 1 件を ID の形に直す (項目 1/2)。ID だけを抜き出し、値は捨てる] 2 項目|item|get|Example Service|--vault|Dev|--format|json|' \
  && args_is 2 '--reason|[pjp-op-ref: 参照 1 件を ID の形に直す (項目 2/2)。ID だけを抜き出し、値は捨てる] 2 項目|item|get|Other Service|--vault|Dev|--format|json|' \
  && out_is reason2 "op://${v1}/${i1}/password" "op://${v1}/${i2}/password"
check "項目が 2 つ以上なら、理由に何件目かを付ける" $? reason2

reset
set_state none
run_ref nostate --reason "印が無い" "op://Dev/Example Service/password"
[[ ${rc} == 0 ]] && args_is 1 'item|get|Example Service|--vault|Dev|--format|json|' && out_is nostate "op://${v1}/${i1}/password"
check "claude-op-reason.json が無ければ --reason を付けない" $? nostate
set_state false

echo "== 止まる"
reset
run_ref nofield --reason "無い欄" "op://Dev/Example Service/password" "op://Dev/Example Service/prod/NOPE"
[[ ${rc} == 1 ]] && out_is nofield && grep -qF 'NOPE' "${work}/nofield.stderr" && grep -qF '0 件' "${work}/nofield.stderr"
check "欄が無ければ 1 で、参照と件数 0 を出し、ほかの参照が直せても stdout に出さない" $? nofield

reset
run_ref manyfield --reason "2 つある欄" "op://Dev/Example Service/API_TOKEN"
[[ ${rc} == 1 ]] && out_is manyfield && grep -qF '2 件' "${work}/manyfield.stderr"
check "同じ名前の欄が 2 つあれば 1 で、件数 2 を出す" $? manyfield

reset
run_ref nosection --reason "無いセクション" "op://Dev/Example Service/nosuch/API_TOKEN"
[[ ${rc} == 1 ]] && out_is nosection && grep -qF 'nosuch' "${work}/nosection.stderr" && grep -qF '0 件' "${work}/nosection.stderr"
check "セクションが無ければ 1 で、件数 0 を出す" $? nosection

reset
run_ref manysection --reason "2 つあるセクション" "op://Dev/Example Service/dup/x"
[[ ${rc} == 1 ]] && out_is manysection && grep -qF '2 件' "${work}/manysection.stderr"
check "同じ名前のセクションが 2 つあれば 1 で、件数 2 を出す" $? manysection

reset
FAKE_OP_RC=1 run_ref oprc --reason "断られる" "op://Dev/Example Service/password" "op://Dev/Other Service/password"
[[ ${rc} == 1 && $(op_count) == 1 ]] && out_is oprc
check "op が 1 で終われば 1 で止まり、残りの項目は読まない。stdout に出さない" $? oprc

reset
FAKE_OP_RC=75 run_ref oprc75 --reason "待たされる" "op://Dev/Example Service/password"
[[ ${rc} == 75 ]] && out_is oprc75
check "op が 75 で終われば 75 で止まる" $? oprc75

reset
run_ref noitem --reason "無い項目" "op://Dev/No Such Item/password"
[[ ${rc} == 1 ]] && out_is noitem && grep -qF "isn't an item" "${work}/noitem.stderr"
check "op が項目を見つけられなければ op の誤りの文と終了コード 1 で止まる" $? noitem

shape_ok=1
shape_detail=""
printf '' >"${work}/out.empty"
printf 'S3CR3T-not-json {' >"${work}/out.notjson"
cat "${FAKE_ITEMS}/example.json" "${FAKE_ITEMS}/example.json" >"${work}/out.two"
printf '%s\n' '{"id":"itemid00000000000000000001","title":"t","vault":{"name":"Dev"},"fields":[{"id":"password","label":"password","value":"S3CR3T-p"}]}' \
  >"${work}/out.novault"
printf '%s\n' '{"id":"itemid00000000000000000001","vault":{"id":"v","name":"Dev"},"sections":"S3CR3T-sections","fields":[]}' \
  >"${work}/out.sections"
printf '%s\n' '{"id":"itemid00000000000000000001","vault":{"id":"v","name":"Dev"},"fields":"S3CR3T-fields"}' >"${work}/out.fields"
printf '%s\n' '{"id":"itemid00000000000000000001","vault":{"id":"v","name":"Dev"},"fields":[{"id":"a/b","label":"password","value":"S3CR3T-p"}]}' \
  >"${work}/out.slash"
for kind in empty notjson two novault sections fields slash; do
  reset
  FAKE_OP_OUT=${work}/out.${kind} run_ref shape --reason "形が違う" "op://Dev/Example Service/password"
  if [[ ${rc} != 70 ]] || ! out_is shape || ! quiet_leak shape; then
    shape_ok=0
    shape_detail+="${kind}: $(show shape)"$'\n'
  fi
done
if ((shape_ok)); then
  ok "op の出力の形が合わなければ 70 で、stdout に出さず、誤りの文に値が無い (7 通り)"
else
  ng "op の出力の形が合わなければ 70 で、stdout に出さず、誤りの文に値が無い (7 通り)" "${shape_detail}"
fi

args_ok=1
args_detail=""
good="op://Dev/Example Service/password"
for c in noreason emptyreason blankreason norefs unknown noscheme two five emptypart trailing cntrl dashvault dashitem mixed; do
  reset
  case ${c} in
    noreason) run_ref args "${good}" ;;
    emptyreason) run_ref args --reason "" "${good}" ;;
    blankreason) run_ref args --reason $' \t ' "${good}" ;;
    norefs) run_ref args --reason "参照が無い" ;;
    unknown) run_ref args --reason "知らない" --bogus "${good}" ;;
    noscheme) run_ref args --reason "形" "Dev/Example Service/password" ;;
    two) run_ref args --reason "形" "op://Dev/Example Service" ;;
    five) run_ref args --reason "形" "op://Dev/Example Service/a/b/c" ;;
    emptypart) run_ref args --reason "形" "op://Dev//password" ;;
    trailing) run_ref args --reason "形" "op://Dev/Example Service/password/" ;;
    cntrl) run_ref args --reason "形" $'op://Dev/Example\tService/password' ;;
    dashvault) run_ref args --reason "形" "op://-Dev/Example Service/password" ;;
    dashitem) run_ref args --reason "形" "op://Dev/-Example/password" ;;
    mixed) run_ref args --reason "形" "${good}" "op://Dev/Example Service" ;;
  esac
  if [[ ${rc} != 2 || $(op_count) != 0 ]] || ! out_is args; then
    args_ok=0
    args_detail+="${c}: $(show args)"$'\n'
  fi
done
if ((args_ok)); then
  ok "引数の誤り (理由・参照の有無、知らない option、参照の形) は 2 で、op を呼ばない (14 通り)"
else
  ng "引数の誤り (理由・参照の有無、知らない option、参照の形) は 2 で、op を呼ばない (14 通り)" "${args_detail}"
fi

reset
PJP_OP_REF_OP=no-such-op run_ref noop --reason "op が無い" "op://Dev/Example Service/password"
[[ ${rc} == 127 ]] && out_is noop && grep -qF 'op (1Password CLI) が見つかりません' "${work}/noop.stderr"
check "op が無ければ 127" $? noop

echo "== 漏らさない"
if disk_clean; then
  ok "流した後、HOME・XDG_STATE_HOME・XDG_RUNTIME_DIR・TMPDIR・cwd に値が無い"
else
  ng "流した後、HOME・XDG_STATE_HOME・XDG_RUNTIME_DIR・TMPDIR・cwd に値が無い" \
    "$(grep -rlaF S3CR3T -- "${HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${proj}")"
fi
reset
if command -v strace &>/dev/null; then
  rc=0
  (cd "${proj}" && strace -f -qq -e trace=execve -s 65536 -o "${work}/strace.log" "${BASH}" "${script}" --reason "argv" \
    "op://Dev/Example Service/prod/API_TOKEN" </dev/null >"${work}/strace.stdout" 2>"${work}/strace.stderr") || rc=$?
  if [[ ${rc} == 0 ]] && grep -qF 'execve(' "${work}/strace.log" && no_leak "${work}/strace.log"; then
    ok "helper から起きたどのプロセスの execve の argv にも値が無い (strace)"
  else
    ng "helper から起きたどのプロセスの execve の argv にも値が無い (strace)" \
      "rc=${rc} err=$(cat "${work}/strace.stderr") $(grep -aF S3CR3T "${work}/strace.log" | head -n 3)"
  fi
else
  ng "helper から起きたどのプロセスの execve の argv にも値が無い (strace)" "strace がありません (flake の checks は入れている)"
fi
reset
printf 'set -x\n' >"${work}/bash_env"
rc=0
(cd "${proj}" && env SHELLOPTS=xtrace "${BASH}" "${script}" --reason "xtrace" "op://Dev/Example Service/prod/API_TOKEN" \
  </dev/null >/dev/null 2>"${work}/xtrace.stderr") || rc=$?
rc2=0
(cd "${proj}" && env BASH_ENV="${work}/bash_env" "${BASH}" "${script}" --reason "BASH_ENV" "op://Dev/Example Service/prod/API_TOKEN" \
  </dev/null >/dev/null 2>"${work}/bashenv.stderr") || rc2=$?
if [[ ${rc} == 0 && ${rc2} == 0 ]] && grep -qF '+ ' "${work}/xtrace.stderr" && grep -qF '+ ' "${work}/bashenv.stderr" \
  && no_leak "${work}/xtrace.stderr" "${work}/bashenv.stderr"; then
  ok "SHELLOPTS=xtrace・BASH_ENV (set -x) を付けても stderr に値が無い"
else
  ng "SHELLOPTS=xtrace・BASH_ENV (set -x) を付けても stderr に値が無い" \
    "rc=${rc} rc2=${rc2} $(grep -aF S3CR3T "${work}/xtrace.stderr" "${work}/bashenv.stderr" | head -n 3)"
fi

echo "== 出す 1 行・--help"
reset
run_ref summary --reason "1 行" "op://Dev/Example Service/prod/API_TOKEN" "op://Dev/Example Service/password"
[[ ${rc} == 0 ]] && grep -qF '参照 2 件' "${work}/summary.stderr" && grep -qF 'op を 1 回' "${work}/summary.stderr"
check "stderr に参照の件数と op の回数を 1 行出す" $? summary
reset
run_ref quiet --reason "黙る" --quiet "op://Dev/Example Service/prod/API_TOKEN"
[[ ${rc} == 0 && ! -s ${work}/quiet.stderr ]] && out_is quiet "op://${v1}/${i1}/${s1}/${f1}"
check "--quiet なら stderr に何も出さない" $? quiet
run_ref help --help
[[ ${rc} == 0 ]] && grep -qF -- '--reason' "${work}/help.stdout"
check "--help は使い方を出して 0" $? help

echo "== pjp-op を通す"
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
  exit 0
fi
echo "${mode}" >>"${d}/ps.modes"
mapfile -d "" args < <(jq -j ".args64[] | (@base64d) + \"\u0000\"" <<<"${PJP_OP_PAYLOAD}")
op=$(wslpath -u "$(jq -r .op <<<"${PJP_OP_PAYLOAD}")")
status=$(wslpath -u "$(jq -r .status <<<"${PJP_OP_PAYLOAD}")")
rc=0
"${op}" "${args[@]}" || rc=$?
jq -cn --argjson rc "${rc}" "{started: true, exit: \$rc, error: \"\", window: \"shown\", toast: \"shown\", others: 0, signout: \"ok\"}" >"${status}"
exit "${rc}"
EOF
pjp_bin=${work}/bin-pjp
mkdir -p "${pjp_bin}"
fake "${pjp_bin}/op" <<EOF
exec "${BASH}" "${opsh}" "\$@"
EOF
printf 'TEST-COMMAND-B64' >"${work}/launcher/command.b64"
printf 'TEST-SCRIPT-B64' >"${work}/launcher/script.b64"
export PJP_OP_EXE=${work}/win/op.exe PJP_OP_LAUNCHER=${work}/launcher
reset
set_state true
PATH=${pjp_bin}:${PATH} run_ref pjp --reason "bot の .env に書く参照を ID の形にする" "op://Dev/Example Service/prod/API_TOKEN" \
  "op://Dev/Example Service/stg/API_TOKEN"
[[ ${rc} == 0 && $(cat "${FAKE_DIR}/ps.modes" 2>/dev/null) == desktop && $(op_count) == 1 ]] \
  && args_is 1 'item|get|Example Service|--vault|Dev|--format|json|' \
  && out_is pjp "op://${v1}/${i1}/${s1}/${f1}" "op://${v1}/${i1}/${s2}/${f2}"
check "本物の op.sh を通しても、承認の出る呼び出し (desktop) と op.exe の item get は 1 回で、ID の参照が出る" $? pjp
log=${XDG_STATE_HOME}/pjp-op/log.jsonl
start_rec=$(jq -c 'select(.event == "start")' "${log}" 2>/dev/null | tail -n 1)
if [[ $(jq -c '.args' <<<"${start_rec}") == '["item","get","Example Service","--vault","Dev","--format","json"]' ]] \
  && [[ $(jq -r '.reason' <<<"${start_rec}") == '[pjp-op-ref: 参照 2 件'* ]] && no_leak "${log}"; then
  ok "pjp-op の記録に値は無く、start の args は item get の引数、reason の頭は [pjp-op-ref: 参照 2 件"
else
  ng "pjp-op の記録に値は無く、start の args は item get の引数、reason の頭は [pjp-op-ref: 参照 2 件" "$(cat "${log}" 2>&1)"
fi
if disk_clean; then
  ok "本物の op.sh を通しても、流した後の置き場に値が無い"
else
  ng "本物の op.sh を通しても、流した後の置き場に値が無い" \
    "$(grep -rlaF S3CR3T -- "${HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${proj}")"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
