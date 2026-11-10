#!/usr/bin/env bash
# shellcheck shell=bash
# .env に $(…)・`…`・$HOME を文字のまま書いて評価されないことを見る所が多いので、ファイル全体で SC2016 を止める
# shellcheck disable=SC2016
#
# nix/pkgs/pjp-op-env/pjp-op-env.sh (.env の op:// の参照を 1 回の op で解き、値を環境変数に入れて program を起こす) を、
# 偽の op・偽の vault・偽の program で確かめる。後半 (「pjp-op を通す」) は本物の op.sh (nix/pkgs/pjp-op/op.sh) を、
# pjp-op.test.sh と同じ形の偽の powershell.exe・op.exe・wslpath で通す。
#
#   bash nix/tests/pjp-op-env.test.sh [<pjp-op-env.sh のパス> [<op.sh のパス>]]
#
# flake の checks (pjp-op-env-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・jq・flock (util-linux)・strace。
# 本物の 1Password・op.exe・powershell.exe は使わない。偽の vault の値はどれも S3CR3T を含み (漏れを探す印)、.env に書く
# 参照でない値は PLAINVAL を含む。
#
# ## 確かめること
#
#   .env の読み方
#     - コメント・空行・export・'…' (そのまま)・"…" (\\ と \" だけ戻す)・引用符なしの値の後ろの「空白 #」のコメント・空の値・
#       前後の空白・行末の \r。同じ名前は後の行と後の --env-file が勝ち、呼び手の環境より .env が勝つ
#     - $(…)・`…`・;・$HOME は評価せず、文字のまま渡す (コマンドは走らない)
#     - 読めない行 (= の前の空白・数字で始まる名前・閉じない引用符・引用符の後ろの余計な文字・_poe_ で始まる名前・UID・
#       { を含む参照) は 2 で止め、ファイル名と行番号を出し、行の中身を出さない。program も op も起こさない。.env が無くても 2
#     - bash が特別に扱う名前 (整数の属性で代入が算術式になる OPTIND・RANDOM・SRANDOM・HISTCMD・LINENO・SECONDS、値が替わる
#       _・EPOCHSECONDS、配列の GROUPS・FUNCNAME、BASH で始まる名前、IFS) は読めない行で、値の $(…)・`…` も走らない
#     - 頭の UTF-8 の BOM を外して読む
#   解く
#     - 改行・$・`・'・"・;・空白・前後の空白・末尾の改行・日本語・不正な UTF-8 の byte と制御文字・空の値が、byte の単位で
#       そのまま届く
#     - 名前に空白のある参照は、そのままテンプレートに入って解ける。値の途中の op:// は解かない
#     - 小文字の名前 (i・reason・http_proxy) もそのまま届き、起きるのは渡した program
#     - 参照が 20 件でも op は 1 回
#     - op が stderr に警告を出して 0 で終われば、警告はそのまま出て program を起こす
#   理由: claude-op-reason.json の enable が true なら op に --reason "[pjp-op-env: <program> に参照 <N> 件] <理由> (読む参照: <参照>, …)"
#     を付け (同じ参照は 1 回、理由の改行とタブは空白)、false・無いなら付けない
#   引数の誤り: 理由が無い・空・空白だけ、program が無い、知らない option は 2 で、op を呼ばない
#   fail closed: op が 0 以外 (75)・解けない参照 (1)・印が欠けた出力 (70)・NUL を含む出力 (70)・値に印が混ざった出力 (70) で
#     program を起こさず、helper の stdout・stderr に値が無い
#   無いもの: program が PATH に無ければ 127 で op を呼ばない。op が無ければ 127 で program を起こさない。参照の無い .env なら
#     op が無くても op を呼ばずに起こす
#   漏らさない
#     - program が動いている間、テストから起きたどのプロセスの cmdline にも値が無い。program の argv[0] は打った名前
#     - helper から起きたどのプロセスの execve の argv にも値が無い (strace で見る。途中で消えたコマンドの argv も)
#     - 流した後、HOME・XDG_STATE_HOME・XDG_RUNTIME_DIR・TMPDIR・cwd のどのファイルにも値が無い
#     - SHELLOPTS=xtrace・BASH_ENV (set -x) を付けて流しても、stderr に値が無い
#     - SHELLOPTS=monitor・BASH_ENV (set -m) で job control が付いていても、値が届く
#     - op を呼ぶ時点の環境に、.env の参照でない値は入っていない
#     - op の認証 (OP_SERVICE_ACCOUNT_TOKEN・OP_CONNECT_HOST・OP_CONNECT_TOKEN・OP_SESSION_*) は op に届き、program の環境に無い。
#       .env に書いたものは program に入る
#     - 呼び手の環境の _poe_ で始まる名前は program に渡らない
#   --dry-run: 名前・種類・参照を出し、参照でない値は出さず、op を呼ばない (program が無くてよい)
#   出す 1 行: stderr に参照の件数と名前を出し、--quiet なら出さない。--help は 0
#   pjp-op を通す (本物の op.sh)
#     - 参照 3 件で、承認の出る呼び出し (desktop の mode の powershell) が 1 回、op.exe の inject が 1 回で、値がそのまま届く
#     - program が起きた時点で pjp-op の lock が空いている (flock -n が通る)
#     - program が動いている間に、別の op (PJP_OP_LOCK_WAIT=1) が待たされずに 0 で終わる
#     - log.jsonl に値が無く、start の args は ["inject"]、reason に件数と参照が入る
#     - 参照が 6 件で窓の理由 (op.sh が 200 字で切る) が切れても、頭に program と参照の件数が出る
#     - 流した後、HOME・XDG_STATE_HOME・XDG_RUNTIME_DIR・TMPDIR・cwd のどのファイルにも値が無い
#
# ## 作り
#
# 偽の op は、呼ばれるたびに引数を FAKE_DIR/op.<番号>.args (NUL 区切り)、op の認証の env を op.<番号>.env に書く。最後の引数が
# inject なら stdin を op.<番号>.stdin に写し、{{ <参照> }} を偽の vault (FAKE_VAULT/<参照の sha256 の先頭 16 桁>) の中身に
# 置き換えて stdout に出す。vault に無ければ [ERROR] を出して 1。FAKE_OP_RC (その終了コードで断る)・FAKE_OP_WARN (stderr に
# 出して続ける)・FAKE_OP_DROP_MARK (2 つ目の印の行を落とす)・FAKE_OP_NUL (出力に NUL を挟む) で形を変える。whoami・signout
# (pjp-op の見張り) は FAKE_DIR/op.direct に書いて 1・0 で終わる。同じものを op.exe としても置く。偽の program は、PROG_KEYS の
# 名前の値を NUL 区切りで PROG_DUMP/env に、テスト (PROG_ROOT) から起きたプロセスの cmdline を cmdline に書き、PROG_LOCK があれば flock -n を試して
# lock に free か held を書いてから started を作る。PROG_WAIT のファイルができるまで待つ。shebang は $BASH から作る。偽の op と偽の program は
# set +x で始める (本物の op.exe と program は bash ではなく、BASH_ENV の set -x を受けない。受けると偽のものが値を出す)。

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../pkgs/pjp-op-env/pjp-op-env.sh}
opsh=${2:-${here}/../pkgs/pjp-op/op.sh}
# cwd を移してから流すので、絶対パスにする
script=$(cd -- "$(dirname "${script}")" && pwd -P)/$(basename "${script}")
opsh=$(cd -- "$(dirname "${opsh}")" && pwd -P)/$(basename "${opsh}")
work=$(mktemp -d "${TMPDIR:-/tmp}/pjp-op-env-test.XXXXXX")
work=$(cd "${work}" && pwd -P)
trap 'rm -rf "${work}"' EXIT

export LC_ALL=C.UTF-8
export HOME=${work}/home XDG_STATE_HOME=${work}/state XDG_RUNTIME_DIR=${work}/runtime TMPDIR=${work}/tmp
export FAKE_DIR=${work}/fake FAKE_VAULT=${work}/vault PROG_DUMP=${work}/dump PROG_ROOT=$$
fake_bin=${work}/bin
proj=${work}/proj
mkdir -p "${HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${FAKE_DIR}" "${FAKE_VAULT}" "${fake_bin}" "${proj}" \
  "${work}/win" "${work}/launcher"
export PATH=${fake_bin}:${PATH}
unset WSLENV HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID CLAUDE_CODE_SESSION_ID OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST \
  OP_CONNECT_TOKEN OP_BIOMETRIC_UNLOCK_ENABLED PJP_OP_ENV_OP BASH_ENV PROG_KEYS PROG_LOCK PROG_WAIT

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
for v in OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN OP_SESSION_abc; do
  printf '%s=%s\n' "${v}" "${!v-<unset>}"
done >"${d}/op.${n}.env"
env >"${d}/op.${n}.fullenv"
[[ ${!#} == inject ]] || exit 0
tmpl=$(
  cat
  printf x
)
tmpl=${tmpl%x}
printf '%s' "${tmpl}" >"${d}/op.${n}.stdin"
if [[ -n ${FAKE_OP_WARN:-} ]]; then
  printf '%s\n' "${FAKE_OP_WARN}" >&2
fi
if [[ -n ${FAKE_OP_RC:-} ]]; then
  printf '[ERROR] 2026/11/10 00:00:00 fake failure\n' >&2
  exit "${FAKE_OP_RC}"
fi
result=""
rest=${tmpl}
while [[ ${rest} == *'{{ '*' }}'* ]]; do
  result+=${rest%%'{{ '*}
  rest=${rest#*'{{ '}
  ref=${rest%%' }}'*}
  rest=${rest#*' }}'}
  key=$(printf '%s' "${ref}" | sha256sum)
  key=${key:0:16}
  if [[ ! -f ${FAKE_VAULT}/${key} ]]; then
    printf '[ERROR] 2026/11/10 00:00:00 could not read secret %s: no item found\n' "${ref}" >&2
    exit 1
  fi
  val=$(
    cat "${FAKE_VAULT}/${key}"
    printf x
  )
  result+=${val%x}
done
result+=${rest}
if [[ -n ${FAKE_OP_DROP_MARK:-} ]]; then
  mark=${tmpl%%:0$'\n'*}
  result=${result/$'\n'"${mark}":1$'\n'/$'\n'}
fi
if [[ -n ${FAKE_OP_MARK_IN_VALUE:-} ]]; then
  mark=${tmpl%%:0$'\n'*}
  result=${result/"${mark}":0$'\n'/"${mark}":0$'\n'"x ${mark}:9 "}
fi
if [[ -n ${FAKE_OP_NUL:-} ]]; then
  printf '%s\n' "${result%%$'\n'*}"
  printf 'NUL\0S3CR3T-after-nul'
  printf '%s' "${result#*$'\n'}"
  exit 0
fi
printf '%s' "${result}"
EOF
cp "${fake_bin}/op" "${work}/win/op.exe"

fake prog <<'EOF'
set +x
d=${PROG_DUMP}
mkdir -p "${d}"
for _pk in ${PROG_KEYS-}; do
  if [[ -v ${_pk} ]]; then
    printf '%s=%s\0' "${_pk}" "${!_pk}"
  else
    printf '%s<unset>\0' "${_pk}"
  fi
done >"${d}/env"
# テスト (PROG_ROOT) から起きたプロセスの cmdline だけを見る (同じ時に動いているほかのプロセスは拾わない)
for _pf in /proc/[0-9]*/cmdline; do
  _pq=${_pf#/proc/}
  _pq=${_pq%/cmdline}
  _pin=0
  for ((_pk = 0; _pk < 64; _pk++)); do
    if [[ ${_pq} == "${PROG_ROOT:-1}" ]]; then
      _pin=1
      break
    fi
    read -r _pst <"/proc/${_pq}/stat" 2>/dev/null || break
    _pq=${_pst##*) }
    _pq=${_pq#* }
    _pq=${_pq%% *}
    [[ ${_pq} =~ ^[0-9]+$ ]] && ((_pq > 1)) || break
  done
  ((_pin)) || continue
  tr '\0' ' ' <"${_pf}" 2>/dev/null
  echo
done >"${d}/cmdline"
if [[ -n ${PROG_LOCK:-} ]]; then
  if flock -n "${PROG_LOCK}" true; then
    echo free >"${d}/lock"
  else
    echo held >"${d}/lock"
  fi
fi
: >"${d}/started"
if [[ -n ${PROG_WAIT:-} ]]; then
  for _pw in $(seq 600); do
    [[ ! -e ${PROG_WAIT} ]] || break
    sleep 0.1
  done
fi
exit "${PROG_RC:-0}"
EOF
ln -s "${BASH}" "${fake_bin}/mybash"

state_file=${HOME}/.local/state/dotfiles/claude-op-reason.json
# set_state <true|false|none>: pjp-op があるかの印 (home/modules/op-reason.nix が書くもの)
set_state() {
  rm -f "${state_file}"
  if [[ $1 != none ]]; then
    mkdir -p "${state_file%/*}"
    printf '{"enable":%s}\n' "$1" >"${state_file}"
  fi
}

# vault <参照> <値>: 偽の vault に値を置く
vault() {
  local key
  key=$(printf '%s' "$1" | sha256sum)
  printf '%s' "$2" >"${FAKE_VAULT}/${key:0:16}"
}

reset() {
  rm -rf "${FAKE_DIR:?}"/* "${PROG_DUMP}" "${XDG_STATE_HOME}/pjp-op" "${XDG_RUNTIME_DIR:?}"/* "${proj:?}"/.env*
}

# run_env <名前> <引数>…: proj の中で pjp-op-env を流す。<名前>.stdout・<名前>.stderr と rc に入れる
run_env() {
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
started() {
  [[ -e ${PROG_DUMP}/started ]]
}
# expect_env <名前=値>…: 偽の program が書く env と同じ形 (NUL 区切り) で期待を書く
expect_env() {
  local kv
  for kv in "$@"; do
    printf '%s\0' "${kv}"
  done >"${work}/expect.env"
}
same_env() {
  cmp -s "${work}/expect.env" "${PROG_DUMP}/env"
}
show_env() {
  tr '\0' '\n' <"${PROG_DUMP}/env" 2>&1 | cat -A | head -n 20
}
# no_leak <ファイル>…: どのファイルにも S3CR3T・PLAINVAL が無い
no_leak() {
  ! grep -qaF -e S3CR3T -e PLAINVAL -- "$@" 2>/dev/null
}
# disk_clean: 置き場のどのファイルにも、解いた値 (S3CR3T) が無い
disk_clean() {
  ! grep -rqaF S3CR3T -- "${HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${proj}" 2>/dev/null
}

echo "== .env の読み方"
reset
set_state false
{
  printf '%s\n' '# コメント' '   # 字下げしたコメント' '' \
    'export EXPORTED=ex-PLAINVAL' \
    "SINGLE='a \$HOME \`x\` \\n \"q\" PLAINVAL'" \
    'DOUBLE="d \\ \" \n $HOME PLAINVAL"' \
    'INLINE=plain-PLAINVAL   # 後ろのコメント' \
    'HASHVAL=a#b' \
    'EMPTY=' \
    'SPACED=  padded value PLAINVAL  ' \
    'DUP=first' \
    'DUP=second' \
    'CALLER=from-file' \
    'INJ1=$(touch pwned1)' \
    'INJ2=`touch pwned2`' \
    'INJ3=a; touch pwned3' \
    'INJ4="$(touch pwned4) ${HOME}"'
  printf 'CRLF=crlf-PLAINVAL\r\n'
} >"${proj}/.env"
printf 'DUP=third\n' >"${proj}/.env.local"
export PROG_KEYS="EXPORTED SINGLE DOUBLE INLINE HASHVAL EMPTY SPACED DUP CALLER INJ1 INJ2 INJ3 INJ4 CRLF"
CALLER=from-env run_env read --reason "読み方を見る" --env-file .env --env-file .env.local -- prog
expect_env 'EXPORTED=ex-PLAINVAL' "SINGLE=a \$HOME \`x\` \\n \"q\" PLAINVAL" 'DOUBLE=d \ " \n $HOME PLAINVAL' \
  'INLINE=plain-PLAINVAL' 'HASHVAL=a#b' 'EMPTY=' 'SPACED=padded value PLAINVAL' 'DUP=third' 'CALLER=from-file' \
  'INJ1=$(touch pwned1)' 'INJ2=`touch pwned2`' 'INJ3=a; touch pwned3' 'INJ4=$(touch pwned4) ${HOME}' 'CRLF=crlf-PLAINVAL'
if [[ ${rc} == 0 ]] && started && same_env; then
  ok "コメント・空行・export・引用符・後ろのコメント・空の値・前後の空白・\\r・後の行とファイルと .env が勝つ"
else
  ng "コメント・空行・export・引用符・後ろのコメント・空の値・前後の空白・\\r・後の行とファイルと .env が勝つ" \
    "rc=${rc} err=$(cat "${work}/read.stderr")"$'\n'"$(show_env)"
fi
if [[ ! -e ${proj}/pwned1 && ! -e ${proj}/pwned2 && ! -e ${proj}/pwned3 && ! -e ${proj}/pwned4 ]] && [[ $(op_count) == 0 ]]; then
  ok "\$(…)・\`…\`・; を評価しない (コマンドは走らない)。参照が無ければ op を呼ばない"
else
  ng "\$(…)・\`…\`・; を評価しない (コマンドは走らない)。参照が無ければ op を呼ばない" "$(ls "${proj}") op=$(op_count)"
fi

bad_ok=1
bad_detail=""
for bad in 'KEY = v-PLAINVAL' '1KEY=v-PLAINVAL' "KEY='unclosed-PLAINVAL" 'KEY="unclosed-PLAINVAL' \
  "KEY='a' trailing-PLAINVAL" '_poe_x=v-PLAINVAL' 'UID=v-PLAINVAL' 'KEY=op://v/i/{PLAINVAL}'; do
  reset
  printf '%s\n' 'GOOD=1' "${bad}" >"${proj}/.env"
  run_env bad --reason "読めない行" -- prog
  if [[ ${rc} != 2 ]] || started || [[ $(op_count) != 0 ]] || ! grep -qF '.env:2:' "${work}/bad.stderr" \
    || ! no_leak "${work}/bad.stdout" "${work}/bad.stderr"; then
    bad_ok=0
    bad_detail+="${bad}: rc=${rc} err=$(cat "${work}/bad.stderr")"$'\n'
  fi
done
if ((bad_ok)); then
  ok "読めない行は 2 で止め、.env:<行>: を出し、行の中身を出さない。program も op も起こさない (8 通り)"
else
  ng "読めない行は 2 で止め、.env:<行>: を出し、行の中身を出さない。program も op も起こさない (8 通り)" "${bad_detail}"
fi
special_ok=1
special_detail=""
for bad in 'OPTIND=PATH[$(touch pwned-o)]' 'RANDOM=BASH_VERSINFO[$(touch pwned-r)]' 'HISTCMD=HOME[`touch pwned-h`]' \
  'SRANDOM=1-PLAINVAL' 'SECONDS=1-PLAINVAL' 'LINENO=1-PLAINVAL' '_=x-PLAINVAL' 'EPOCHSECONDS=1-PLAINVAL' 'GROUPS=x-PLAINVAL' \
  'FUNCNAME=x-PLAINVAL' 'BASH_ENV=x-PLAINVAL' 'BASH_XTRACEFD=x-PLAINVAL' 'IFS=x-PLAINVAL' 'OPTIND=op://Test/a/password'; do
  reset
  printf '%s\n' 'GOOD=1' "${bad}" >"${proj}/.env"
  run_env special --reason "特別な名前" -- prog
  pwned=""
  for f in "${proj}"/pwned*; do
    [[ ! -e ${f} ]] || pwned+=" ${f##*/}"
  done
  if [[ ${rc} != 2 || -n ${pwned} ]] || started || [[ $(op_count) != 0 ]] || ! grep -qF '.env:2:' "${work}/special.stderr" \
    || ! no_leak "${work}/special.stdout" "${work}/special.stderr"; then
    special_ok=0
    special_detail+="${bad}: rc=${rc} pwned=${pwned} op=$(op_count) err=$(cat "${work}/special.stderr")"$'\n'
  fi
done
if ((special_ok)); then
  ok "bash が特別に扱う名前は 2 で止め、値の \$(…)・\`…\` を走らせず、op も program も起こさない (14 通り)"
else
  ng "bash が特別に扱う名前は 2 で止め、値の \$(…)・\`…\` を走らせず、op も program も起こさない (14 通り)" "${special_detail}"
fi
reset
printf '\xef\xbb\xbfBOMKEY=bom-PLAINVAL\nNEXT=1\n' >"${proj}/.env"
export PROG_KEYS="BOMKEY NEXT"
run_env bom --reason "BOM" -- prog
expect_env 'BOMKEY=bom-PLAINVAL' 'NEXT=1'
if [[ ${rc} == 0 ]] && same_env; then
  ok "頭の UTF-8 の BOM を外して読む"
else
  ng "頭の UTF-8 の BOM を外して読む" "rc=${rc} err=$(cat "${work}/bom.stderr")"
fi
reset
run_env noenv --reason "無い" -- prog
if [[ ${rc} == 2 ]] && ! started; then
  ok ".env が無ければ 2"
else
  ng ".env が無ければ 2" "rc=${rc} err=$(cat "${work}/noenv.stderr")"
fi

echo "== 解く"
reset
set_state false
vault op://Test/nl/password $'S3CR3T-nl-1\nS3CR3T-nl-2'
vault op://Test/special/password "S3CR3T \$HOME \`id\` 'sq' \"dq\" ; \$(touch pwned-v)"
vault op://Test/spaces/password '  S3CR3T padded  '
vault op://Test/trail/password $'S3CR3T-trail\n'
vault op://Test/ja/password 'S3CR3T-日本語のパスワード'
vault op://Test/bytes/password $'S3CR3T-\xff\xfe\x01\x7f'
vault op://Test/empty/password ''
vault 'op://Private/kabu station/password' 'S3CR3T-itemspace'
printf '%s\n' 'V_NL=op://Test/nl/password' 'V_SPECIAL=op://Test/special/password' 'V_SPACES="op://Test/spaces/password"' \
  "V_TRAIL='op://Test/trail/password'" 'V_JA=op://Test/ja/password' 'V_BYTES=op://Test/bytes/password' \
  'V_EMPTY=op://Test/empty/password' 'V_ITEMSP="op://Private/kabu station/password"' \
  'V_MID=prefix-op://Test/nl/password' 'i=1' 'reason=r-PLAINVAL' 'http_proxy=http://proxy.example:8080' >"${proj}/.env"
export PROG_KEYS="V_NL V_SPECIAL V_SPACES V_TRAIL V_JA V_BYTES V_EMPTY V_ITEMSP V_MID i reason http_proxy"
run_env resolve --reason "値を解く" -- prog
expect_env $'V_NL=S3CR3T-nl-1\nS3CR3T-nl-2' "V_SPECIAL=S3CR3T \$HOME \`id\` 'sq' \"dq\" ; \$(touch pwned-v)" \
  'V_SPACES=  S3CR3T padded  ' $'V_TRAIL=S3CR3T-trail\n' 'V_JA=S3CR3T-日本語のパスワード' $'V_BYTES=S3CR3T-\xff\xfe\x01\x7f' \
  'V_EMPTY=' 'V_ITEMSP=S3CR3T-itemspace' 'V_MID=prefix-op://Test/nl/password' 'i=1' 'reason=r-PLAINVAL' \
  'http_proxy=http://proxy.example:8080'
if [[ ${rc} == 0 ]] && started && same_env && [[ ! -e ${proj}/pwned-v ]]; then
  ok "改行・\$・\`・引用符・;・空白・末尾の改行・日本語・不正な byte・空の値が byte の単位で届き、値の途中の op:// は解かない"
else
  ng "改行・\$・\`・引用符・;・空白・末尾の改行・日本語・不正な byte・空の値が byte の単位で届き、値の途中の op:// は解かない" \
    "rc=${rc} err=$(cat "${work}/resolve.stderr")"$'\n'"$(show_env)"
fi
if [[ $(op_count) == 1 ]] && grep -qF '{{ op://Private/kabu station/password }}' "${FAKE_DIR}/op.1.stdin"; then
  ok "op は 1 回で、名前に空白のある参照はそのままテンプレートに入る"
else
  ng "op は 1 回で、名前に空白のある参照はそのままテンプレートに入る" "op=$(op_count) $(cat "${FAKE_DIR}/op.1.stdin" 2>&1)"
fi
if [[ $(op_args 1) == 'inject|' ]] && ! grep -qaF -e S3CR3T -e PLAINVAL -- "${FAKE_DIR}/op.1.stdin" "${FAKE_DIR}/op.1.args" \
  && ! grep -qaF PLAINVAL "${FAKE_DIR}/op.1.fullenv"; then
  ok "claude-op-reason.json が false なら --reason を付けない。op の引数・stdin・環境に .env の値は無い"
else
  ng "claude-op-reason.json が false なら --reason を付けない。op の引数・stdin・環境に .env の値は無い" \
    "args=$(op_args 1) $(grep -aF PLAINVAL "${FAKE_DIR}/op.1.fullenv")"
fi
if no_leak "${work}/resolve.stdout" "${work}/resolve.stderr" && ! grep -qaF S3CR3T "${PROG_DUMP}/cmdline"; then
  ok "helper の出力と、program が動いている間のテストから起きたどのプロセスの cmdline にも値が無い"
else
  ng "helper の出力と、program が動いている間のテストから起きたどのプロセスの cmdline にも値が無い" \
    "$(cat "${work}/resolve.stderr") $(grep -aF S3CR3T "${PROG_DUMP}/cmdline")"
fi
if disk_clean; then
  ok "流した後、HOME・XDG_STATE_HOME・XDG_RUNTIME_DIR・TMPDIR・cwd に値が無い"
else
  ng "流した後、HOME・XDG_STATE_HOME・XDG_RUNTIME_DIR・TMPDIR・cwd に値が無い" \
    "$(grep -rlaF S3CR3T -- "${HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${proj}")"
fi
if grep -qF '参照 8 件' "${work}/resolve.stderr" && grep -qF 'V_NL' "${work}/resolve.stderr"; then
  ok "stderr に参照の件数と名前を 1 行出す"
else
  ng "stderr に参照の件数と名前を 1 行出す" "$(cat "${work}/resolve.stderr")"
fi
reset
printf '%s\n' 'A=op://Test/nl/password' >"${proj}/.env"
export PROG_KEYS=A
run_env quiet --reason "黙る" --quiet -- prog
if [[ ${rc} == 0 && ! -s ${work}/quiet.stderr ]] && started; then
  ok "--quiet なら 1 行も出さない"
else
  ng "--quiet なら 1 行も出さない" "rc=${rc} err=$(cat "${work}/quiet.stderr")"
fi
reset
: >"${proj}/.env"
names=""
for i in $(seq 1 20); do
  vault "op://Test/many/f${i}" "S3CR3T-many-${i}"
  printf 'M%s=op://Test/many/f%s\n' "${i}" "${i}" >>"${proj}/.env"
  names+=" M${i}"
done
export PROG_KEYS=${names# }
run_env many --reason "20 件" -- prog
for i in $(seq 1 20); do
  printf 'M%s=S3CR3T-many-%s\0' "${i}" "${i}"
done >"${work}/expect.env"
if [[ ${rc} == 0 && $(op_count) == 1 ]] && same_env; then
  ok "参照が 20 件でも op は 1 回で、どれもそのまま届く"
else
  ng "参照が 20 件でも op は 1 回で、どれもそのまま届く" "rc=${rc} op=$(op_count) err=$(cat "${work}/many.stderr")"
fi
reset
printf '%s\n' 'A=op://Test/nl/password' >"${proj}/.env"
export PROG_KEYS=A
FAKE_OP_WARN="[WARN] fake warning" run_env warn --reason "警告" -- prog
if [[ ${rc} == 0 ]] && started && grep -qF '[WARN] fake warning' "${work}/warn.stderr"; then
  ok "op の stderr の警告はそのまま出て、0 なら program を起こす"
else
  ng "op の stderr の警告はそのまま出て、0 なら program を起こす" "rc=${rc} err=$(cat "${work}/warn.stderr")"
fi

echo "== 理由"
reset
set_state true
vault op://Test/a/password S3CR3T-a
vault op://Test/b/password S3CR3T-b
printf '%s\n' 'A=op://Test/a/password' 'B=op://Test/b/password' 'C=op://Test/a/password' >"${proj}/.env"
export PROG_KEYS="A B C"
run_env reason --reason $'bot を\n起こす\tため' -- prog
want='--reason|[pjp-op-env: prog に参照 2 件] bot を 起こす ため (読む参照: op://Test/a/password, op://Test/b/password)|inject|'
if [[ ${rc} == 0 && $(op_args 1) == "${want}" ]]; then
  ok "enable が true なら --reason に program・参照の件数・理由・読む参照 (同じものは 1 回) を付ける。改行とタブは空白"
else
  ng "enable が true なら --reason に program・参照の件数・理由・読む参照 (同じものは 1 回) を付ける。改行とタブは空白" "rc=${rc} args=$(op_args 1)"
fi
reset
set_state none
printf '%s\n' 'A=op://Test/a/password' >"${proj}/.env"
export PROG_KEYS=A
run_env nostate --reason "印が無い" -- prog
if [[ ${rc} == 0 && $(op_args 1) == 'inject|' ]]; then
  ok "claude-op-reason.json が無ければ --reason を付けない"
else
  ng "claude-op-reason.json が無ければ --reason を付けない" "rc=${rc} args=$(op_args 1)"
fi

echo "== 引数の誤り"
args_ok=1
args_detail=""
for c in noreason emptyreason blankreason noprog unknown; do
  reset
  printf '%s\n' 'A=op://Test/a/password' >"${proj}/.env"
  case ${c} in
    noreason) run_env args -- prog ;;
    emptyreason) run_env args --reason "" -- prog ;;
    blankreason) run_env args --reason $' \t ' -- prog ;;
    noprog) run_env args --reason "program が無い" ;;
    unknown) run_env args --reason "知らない" --bogus -- prog ;;
  esac
  if [[ ${rc} != 2 || $(op_count) != 0 ]] || started; then
    args_ok=0
    args_detail+="${c}: rc=${rc} op=$(op_count) err=$(cat "${work}/args.stderr")"$'\n'
  fi
done
if ((args_ok)); then
  ok "理由が無い・空・空白だけ、program が無い、知らない option は 2 で、op を呼ばない"
else
  ng "理由が無い・空・空白だけ、program が無い、知らない option は 2 で、op を呼ばない" "${args_detail}"
fi

echo "== fail closed"
set_state false
reset
printf '%s\n' 'A=op://Test/a/password' 'B=op://Test/b/password' >"${proj}/.env"
export PROG_KEYS="A B"
FAKE_OP_RC=75 run_env rc75 --reason "断られる" -- prog
if [[ ${rc} == 75 ]] && ! started && no_leak "${work}/rc75.stdout" "${work}/rc75.stderr"; then
  ok "op が 75 で終われば program を起こさず 75 で終わる"
else
  ng "op が 75 で終われば program を起こさず 75 で終わる" "rc=${rc} err=$(cat "${work}/rc75.stderr")"
fi
reset
printf '%s\n' 'A=op://Test/a/password' 'X=op://Test/missing/password' >"${proj}/.env"
run_env missing --reason "無い参照" -- prog
if [[ ${rc} == 1 ]] && ! started && no_leak "${work}/missing.stdout" "${work}/missing.stderr"; then
  ok "解けない参照が 1 つでもあれば program を起こさない (op の終了コード 1)"
else
  ng "解けない参照が 1 つでもあれば program を起こさない (op の終了コード 1)" "rc=${rc} err=$(cat "${work}/missing.stderr")"
fi
reset
printf '%s\n' 'A=op://Test/a/password' 'B=op://Test/b/password' >"${proj}/.env"
FAKE_OP_DROP_MARK=1 run_env drop --reason "印が欠ける" -- prog
if [[ ${rc} == 70 ]] && ! started && no_leak "${work}/drop.stdout" "${work}/drop.stderr"; then
  ok "境界の印が欠けた出力なら program を起こさず 70。誤りの文に値が無い"
else
  ng "境界の印が欠けた出力なら program を起こさず 70。誤りの文に値が無い" "rc=${rc} err=$(cat "${work}/drop.stderr")"
fi
reset
printf '%s\n' 'A=op://Test/a/password' 'B=op://Test/b/password' >"${proj}/.env"
FAKE_OP_NUL=1 run_env nul --reason "NUL" -- prog
if [[ ${rc} == 70 ]] && ! started && no_leak "${work}/nul.stdout" "${work}/nul.stderr"; then
  ok "NUL を含む出力なら program を起こさず 70。誤りの文に値が無い"
else
  ng "NUL を含む出力なら program を起こさず 70。誤りの文に値が無い" "rc=${rc} err=$(cat "${work}/nul.stderr")"
fi

reset
printf '%s\n' 'A=op://Test/a/password' 'B=op://Test/b/password' >"${proj}/.env"
FAKE_OP_MARK_IN_VALUE=1 run_env markin --reason "値に印" -- prog
if [[ ${rc} == 70 ]] && ! started && no_leak "${work}/markin.stdout" "${work}/markin.stderr"; then
  ok "値に境界の印が混ざった出力なら program を起こさず 70"
else
  ng "値に境界の印が混ざった出力なら program を起こさず 70" "rc=${rc} err=$(cat "${work}/markin.stderr")"
fi

echo "== 無いもの"
reset
printf '%s\n' 'A=op://Test/a/password' >"${proj}/.env"
run_env noprogfile --reason "無い program" -- no-such-prog
if [[ ${rc} == 127 && $(op_count) == 0 ]]; then
  ok "program が PATH に無ければ 127 で、op を呼ばない"
else
  ng "program が PATH に無ければ 127 で、op を呼ばない" "rc=${rc} op=$(op_count) err=$(cat "${work}/noprogfile.stderr")"
fi
reset
printf '%s\n' 'A=op://Test/a/password' >"${proj}/.env"
PJP_OP_ENV_OP=no-such-op run_env noop --reason "op が無い" -- prog
if [[ ${rc} == 127 ]] && ! started; then
  ok "op が無ければ 127 で、program を起こさない"
else
  ng "op が無ければ 127 で、program を起こさない" "rc=${rc} err=$(cat "${work}/noop.stderr")"
fi
reset
printf '%s\n' 'A=plain' >"${proj}/.env"
export PROG_KEYS=A
PJP_OP_ENV_OP=no-such-op run_env noref --reason "参照が無い" -- prog
if [[ ${rc} == 0 ]] && started && [[ $(op_count) == 0 ]]; then
  ok "参照の無い .env なら、op が無くても op を呼ばずに起こす"
else
  ng "参照の無い .env なら、op が無くても op を呼ばずに起こす" "rc=${rc} err=$(cat "${work}/noref.stderr")"
fi

echo "== 漏らさない"
reset
printf '%s\n' 'A=op://Test/a/password' >"${proj}/.env"
run_env argv0 --reason "argv0" -- mybash -c 'printf %s "$0" >"${PROG_DUMP}.argv0"'
if [[ ${rc} == 0 && $(cat "${PROG_DUMP}.argv0" 2>/dev/null) == mybash ]]; then
  ok "program の argv[0] は打った名前"
else
  ng "program の argv[0] は打った名前" "rc=${rc} argv0=$(cat "${PROG_DUMP}.argv0" 2>&1) err=$(cat "${work}/argv0.stderr")"
fi
rm -f "${PROG_DUMP}.argv0"
# exec で置き換わった後の cmdline では、途中で起きて消えたコマンド (env KEY=値 program の env など) の argv は見えないので、
# helper から起きたすべての execve の argv を strace で見る (-v を付けないので envp は件数だけが出る)
reset
printf '%s\n' 'A=op://Test/a/password' 'B=op://Test/nl/password' >"${proj}/.env"
export PROG_KEYS="A B"
if command -v strace &>/dev/null; then
  rc=0
  (cd "${proj}" && strace -f -qq -e trace=execve -s 65536 -o "${work}/strace.log" "${BASH}" "${script}" --reason "argv" -- prog \
    </dev/null >/dev/null 2>"${work}/strace.stderr") || rc=$?
  if [[ ${rc} == 0 ]] && started && grep -qF 'execve(' "${work}/strace.log" && ! grep -qaF S3CR3T "${work}/strace.log"; then
    ok "helper から起きたどのプロセスの execve の argv にも値が無い (strace)"
  else
    ng "helper から起きたどのプロセスの execve の argv にも値が無い (strace)" \
      "rc=${rc} err=$(cat "${work}/strace.stderr") $(grep -aF S3CR3T "${work}/strace.log" | head -n 3)"
  fi
else
  ng "helper から起きたどのプロセスの execve の argv にも値が無い (strace)" "strace がありません (flake の checks は入れている)"
fi
reset
printf '%s\n' 'A=op://Test/a/password' 'B=op://Test/b/password' >"${proj}/.env"
printf 'set -x\n' >"${work}/bash_env"
export PROG_KEYS="A B"
rc=0
(cd "${proj}" && env SHELLOPTS=xtrace "${BASH}" "${script}" --reason "xtrace" -- prog </dev/null >/dev/null 2>"${work}/xtrace.stderr") || rc=$?
rc2=0
(cd "${proj}" && env BASH_ENV="${work}/bash_env" "${BASH}" "${script}" --reason "BASH_ENV" -- prog </dev/null >/dev/null 2>"${work}/bashenv.stderr") || rc2=$?
if [[ ${rc} == 0 && ${rc2} == 0 ]] && grep -qF '+ ' "${work}/xtrace.stderr" && grep -qF '+ ' "${work}/bashenv.stderr" \
  && ! grep -qaF S3CR3T -- "${work}/xtrace.stderr" "${work}/bashenv.stderr"; then
  ok "SHELLOPTS=xtrace・BASH_ENV (set -x) を付けても stderr に値が無い"
else
  ng "SHELLOPTS=xtrace・BASH_ENV (set -x) を付けても stderr に値が無い" \
    "rc=${rc} rc2=${rc2} $(grep -aF S3CR3T "${work}/xtrace.stderr" "${work}/bashenv.stderr" | head -n 3)"
fi
reset
printf '%s\n' 'A=op://Test/a/password' >"${proj}/.env"
printf 'set -m\n' >"${work}/bash_env_m"
export PROG_KEYS=A
expect_env 'A=S3CR3T-a'
rc=0
(cd "${proj}" && env SHELLOPTS=monitor "${BASH}" "${script}" --reason "monitor" -- prog </dev/null >/dev/null 2>"${work}/monitor.stderr") || rc=$?
mon_env=$(tr '\0' '|' <"${PROG_DUMP}/env" 2>/dev/null)
rm -rf "${PROG_DUMP}"
rc2=0
(cd "${proj}" && env BASH_ENV="${work}/bash_env_m" "${BASH}" "${script}" --reason "set -m" -- prog </dev/null >/dev/null \
  2>"${work}/setm.stderr") || rc2=$?
if [[ ${rc} == 0 && ${rc2} == 0 && ${mon_env} == 'A=S3CR3T-a|' ]] && same_env; then
  ok "SHELLOPTS=monitor・BASH_ENV (set -m) で job control が付いていても値が届く"
else
  ng "SHELLOPTS=monitor・BASH_ENV (set -m) で job control が付いていても値が届く" \
    "rc=${rc} rc2=${rc2} mon=${mon_env} err=$(cat "${work}/monitor.stderr" "${work}/setm.stderr")"
fi
reset
printf '%s\n' 'A=op://Test/a/password' >"${proj}/.env"
export PROG_KEYS="A OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN OP_SESSION_abc _poe_leak"
OP_SERVICE_ACCOUNT_TOKEN=tok-S3CR3T-sa OP_CONNECT_HOST=https://connect.example OP_CONNECT_TOKEN=ctok-S3CR3T \
  OP_SESSION_abc=sess-S3CR3T _poe_leak=leak-PLAINVAL run_env auth --reason "token" -- prog
expect_env 'A=S3CR3T-a' 'OP_SERVICE_ACCOUNT_TOKEN<unset>' 'OP_CONNECT_HOST<unset>' 'OP_CONNECT_TOKEN<unset>' \
  'OP_SESSION_abc<unset>' '_poe_leak<unset>'
if [[ ${rc} == 0 ]] && same_env && grep -qx 'OP_SERVICE_ACCOUNT_TOKEN=tok-S3CR3T-sa' "${FAKE_DIR}/op.1.env" \
  && grep -qx 'OP_SESSION_abc=sess-S3CR3T' "${FAKE_DIR}/op.1.env" && grep -qx 'OP_CONNECT_TOKEN=ctok-S3CR3T' "${FAKE_DIR}/op.1.env"; then
  ok "op の認証は op に届き、program の環境に無い。呼び手の _poe_ の名前も渡らない"
else
  ng "op の認証は op に届き、program の環境に無い。呼び手の _poe_ の名前も渡らない" \
    "rc=${rc} op-env=$(cat "${FAKE_DIR}/op.1.env" 2>&1)"$'\n'"$(show_env)"
fi

reset
printf '%s\n' 'A=op://Test/a/password' 'OP_CONNECT_HOST=https://from-env-file' >"${proj}/.env"
export PROG_KEYS="A OP_CONNECT_HOST"
OP_CONNECT_HOST=https://caller run_env authfile --reason "token" -- prog
expect_env 'A=S3CR3T-a' 'OP_CONNECT_HOST=https://from-env-file'
if [[ ${rc} == 0 ]] && same_env; then
  ok ".env に書いた op の認証の名前は program に入る"
else
  ng ".env に書いた op の認証の名前は program に入る" "rc=${rc}"$'\n'"$(show_env)"
fi

echo "== --dry-run・--help"
reset
printf '%s\n' 'A=op://Test/a/password' 'PLAIN_KEY=plain-PLAINVAL' 'EMPTY_KEY=' >"${proj}/.env"
run_env dry --dry-run
dry=$(<"${work}/dry.stdout")
if [[ ${rc} == 0 && $(op_count) == 0 && ${dry} == *op://Test/a/password* && ${dry} == *PLAIN_KEY* && ${dry} == *EMPTY_KEY* ]] \
  && no_leak "${work}/dry.stdout" "${work}/dry.stderr"; then
  ok "--dry-run は名前・種類・参照を出し、参照でない値は出さず、op を呼ばない"
else
  ng "--dry-run は名前・種類・参照を出し、参照でない値は出さず、op を呼ばない" "rc=${rc} op=$(op_count) out=${dry}"
fi
run_env help --help
if [[ ${rc} == 0 ]] && grep -qF -- '--reason' "${work}/help.stdout"; then
  ok "--help は使い方を出して 0"
else
  ng "--help は使い方を出して 0" "rc=${rc}"
fi

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
printf '%s' "${PJP_OP_PAYLOAD}" >"${d}/ps.payload"
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
lock_file=${XDG_STATE_HOME}/pjp-op/lock
reset
set_state true
vault op://Test/c/password $'S3CR3T-c\nline2'
printf '%s\n' 'A=op://Test/a/password' 'B=op://Test/b/password' 'C=op://Test/c/password' >"${proj}/.env"
export PROG_KEYS="A B C"
PATH=${pjp_bin}:${PATH} PROG_LOCK=${lock_file} run_env pjp --reason "kabu の bot を起こす" -- prog
expect_env 'A=S3CR3T-a' 'B=S3CR3T-b' $'C=S3CR3T-c\nline2'
if [[ ${rc} == 0 ]] && same_env && [[ $(<"${FAKE_DIR}/ps.modes") == desktop && $(op_count) == 1 && $(op_args 1) == 'inject|' ]]; then
  ok "本物の op.sh を通しても、承認の出る呼び出し (desktop) と op.exe の inject は 1 回で、値がそのまま届く"
else
  ng "本物の op.sh を通しても、承認の出る呼び出し (desktop) と op.exe の inject は 1 回で、値がそのまま届く" \
    "rc=${rc} modes=$(cat "${FAKE_DIR}/ps.modes" 2>&1) op=$(op_count) args=$(op_args 1) err=$(cat "${work}/pjp.stderr")"$'\n'"$(show_env)"
fi
if [[ $(cat "${PROG_DUMP}/lock" 2>/dev/null) == free ]]; then
  ok "program が起きた時点で pjp-op の lock は空いている"
else
  ng "program が起きた時点で pjp-op の lock は空いている" "lock=$(cat "${PROG_DUMP}/lock" 2>&1)"
fi
log=${XDG_STATE_HOME}/pjp-op/log.jsonl
start_rec=$(jq -c 'select(.event == "start")' "${log}" 2>/dev/null | tail -n 1)
want_reason='[pjp-op-env: prog に参照 3 件] kabu の bot を起こす (読む参照: op://Test/a/password, op://Test/b/password, op://Test/c/password)'
if [[ $(jq -c '.args' <<<"${start_rec}") == '["inject"]' && $(jq -r '.reason' <<<"${start_rec}") == "${want_reason}" ]] \
  && ! grep -qaF S3CR3T "${log}"; then
  ok "pjp-op の記録に値は無く、start の args は [\"inject\"]、reason に件数と参照が入る"
else
  ng "pjp-op の記録に値は無く、start の args は [\"inject\"]、reason に件数と参照が入る" "$(cat "${log}" 2>&1)"
fi
if disk_clean; then
  ok "本物の op.sh を通しても、流した後の置き場に値が無い"
else
  ng "本物の op.sh を通しても、流した後の置き場に値が無い" \
    "$(grep -rlaF S3CR3T -- "${HOME}" "${XDG_STATE_HOME}" "${XDG_RUNTIME_DIR}" "${TMPDIR}" "${proj}")"
fi
reset
: >"${proj}/.env"
for i in $(seq 1 6); do
  vault "op://Private/service-${i}/credential" "S3CR3T-svc-${i}"
  printf 'SVC%s=op://Private/service-%s/credential\n' "${i}" "${i}" >>"${proj}/.env"
done
export PROG_KEYS=SVC6
PATH=${pjp_bin}:${PATH} run_env six --reason "6 つのサービスに入る bot を起こすのにそれぞれの credential を読む" -- prog
window_reason=$(jq -r '.ui.lines[] | select(.[0] == "理由") | .[1]' "${FAKE_DIR}/ps.payload" 2>/dev/null)
log_reason=$(jq -r 'select(.event == "start") | .reason' "${XDG_STATE_HOME}/pjp-op/log.jsonl" 2>/dev/null | tail -n 1)
if [[ ${rc} == 0 && ${window_reason} == '[pjp-op-env: prog に参照 6 件] '* && ${window_reason} == *… &&
  ${log_reason} == *op://Private/service-6/credential* ]]; then
  ok "参照が 6 件で窓の理由が切れても、頭に program と参照の件数が出る (記録には全部が入る)"
else
  ng "参照が 6 件で窓の理由が切れても、頭に program と参照の件数が出る (記録には全部が入る)" \
    "rc=${rc} window=${window_reason} log=${log_reason}"
fi
reset
printf '%s\n' 'A=op://Test/a/password' >"${proj}/.env"
export PROG_KEYS=A
release=${work}/release
rm -f "${release}"
(cd "${proj}" && PATH=${pjp_bin}:${PATH} PROG_WAIT=${release} "${BASH}" "${script}" --reason "長く動く bot" -- prog </dev/null \
  >/dev/null 2>"${work}/long.stderr") &
long_pid=$!
for _ in $(seq 100); do
  started && break
  sleep 0.1
done
other_rc=0
PATH=${pjp_bin}:${PATH} PJP_OP_LOCK_WAIT=1 "${BASH}" "${opsh}" --reason "ほかの pane" item get x </dev/null >/dev/null \
  2>"${work}/other.stderr" || other_rc=$?
still=0
kill -0 "${long_pid}" 2>/dev/null && still=1
touch "${release}"
long_rc=0
wait "${long_pid}" || long_rc=$?
if started && [[ ${other_rc} == 0 && ${still} == 1 && ${long_rc} == 0 ]]; then
  ok "program が動いている間に、別の op は lock で待たされずに 0 で終わる"
else
  ng "program が動いている間に、別の op は lock で待たされずに 0 で終わる" \
    "other=${other_rc} still=${still} long=${long_rc} err=$(cat "${work}/other.stderr") $(cat "${work}/long.stderr")"
fi

echo
echo "pass=${pass} fail=${fail}"
[[ ${fail} == 0 ]]
