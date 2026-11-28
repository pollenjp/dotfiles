#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/claude-account (アカウントを足す管理のコマンド claude-account と、launcher claude-<名前> を兼ねる 1 本の script) を、
# 一時の HOME・偽の claude・偽の op で確かめる。
#
#   bash nix/tests/claude-account.test.sh <claude-account の package> <package に埋めた profileBin> <bootstrap-claude-accounts.sh> \
#     [<既定に t3 を足した package>] [<素の claude を token で起こす package (bareToken)>]
#
# flake の checks (claude-account-test) が Nix のサンドボックスで流す。本物の claude・op・1Password は使わない。token の値はどれも
# ダミー (dummy- で始まる) で、launcher と管理のコマンドの stdout・stderr に出ないことを見る (値を受けた偽の claude だけが控えに書く)。
#
# ## 確かめること
#
#   管理のコマンド
#     - 引数なしは 2 で使い方を stderr に、--help は 0 で stdout に出す。知らないサブコマンドは 2
#     - add: 規則に合わない名前・account・既定の名前・知らない種類・種類なしは 2。token1 を token で足すと、登録 (accounts.json) に
#       書き、~/.local/bin/claude-token1 を profileBin の claude-account への link にし、~/.claude-token1 を bootstrap と同じ形にし
#       (settings.json が ~/.claude へのリンク)、次の手 (claude setup-token・set-token) を出す。同じ種類の打ち直しは 0、違う種類は 1。
#       subscription で足すと /login を出す。~/.local/bin/claude-<名前> にほかのファイルがあれば 1 で、登録しない
#     - check: 0 = stdout に 1 行 (token (ローカル)・token (1Password)・subscription (ログイン済み))、1 = stderr にユーザーの手
#       (set-token・chmod 600・/login・setup・add の打ち直し)、2 = 知らない名前。どれも値を出さない
#     - set-token: パイプの 1 行を、権限 600 の CLAUDE_CODE_OAUTH_TOKEN=<token> の行にする (前の op の参照を置き換える)。sk-ant-oat で
#       始まらなければ注意を出して書く。空・op:// は 1 で書かない。ほかの引数・subscription・知らない名前は 2
#     - list: 既定と登録のアカウントを種類と元と一緒に並べる
#     - remove: 既定と知らない名前は 2。登録から外して launcher を消し、dir と token のファイルを残す。--purge なら両方を消すが、
#       dir の中のリンクの先 (~/.claude の settings.json・projects・skills) は残る。登録から外したあとの --purge でも消せる
#     - 既定に足した名前 (前に add で登録してから dotfiles が既定に足した t3。4 つ目の引数の package): list は 1 度だけ既定として出し、
#       remove は登録と add の張った launcher の link だけを外して dir を残す (2 度目は既定なので 2)
#   launcher
#     - 既定 (claude-personal): 用意が無ければ 1 で setup を出す。用意されていれば env を外し CLAUDE_CONFIG_DIR を付け、引数と終了
#       コードを渡す
#     - 既定でも登録でもない名前は 2 で add を出す。登録の一覧が壊れていれば登録のアカウントは 1 で、既定はそのまま起きる
#     - token のローカル: 権限 600 なら token と CLAUDE_CONFIG_DIR を渡し、受け継いだ ANTHROPIC_API_KEY・ANTHROPIC_AUTH_TOKEN・
#       CLAUDE_CODE_OAUTH_TOKEN を外す。export・"…"・'…'・BOM・CRLF・コメント行でも読む。644 なら 1 (600 を出す)
#     - token が無い・行が無い・値が空なら 1 で忠告 (claude setup-token・claude-account set-token・op://)
#     - 止まる行: ほかの名前の行 (行の番号と名前)・2 つ目の行・KEY=値 でない行・空白のある値。どれも値を出さない
#     - op: op:// の参照 (権限は見ない) なら偽の op が 1 回呼ばれ、claude に値が届く。op が 5 で終われば 5 で、claude は起きない
#   直し (レビュー・子 B)
#     - check の 2 は add の手を出す。名前に token を渡しても (規則に合わない名前は) 文に出さない (add・set-token・check・remove)
#     - op の参照の check の 1 行は「起動のときに承認が要る」。1Password から読んだ値が空・空白入りなら claude を起こさず 70
#     - 引用符の中の前後の空白は値の一部 (" op://…" は op の参照でなく、token の形でもない) で、check も launcher も止まる
#     - add は用意が済まなければ (settings.json が実体) 1。token のファイルがリンクなら止まり、set-token を出す
#     - 登録の一覧の規則外の名前・account は読めない形。list は読めない形を 1 回だけ出す
#     - help token の 1 行は chmod 600 も打つ。add は ~/.config/claude-accounts を 700 で作る
#   claude-selector (cs)
#     - selector は claude-selector の名前なので、add・remove は 2 で断り、登録の一覧にあれば読めない形
#   bootstrap
#     - --account <名前> は、そのアカウントの dir だけを用意する
#     - 引数なしは、既定に加えて登録のアカウントの dir も用意し、launcher の link が無ければ警告する
#   入れた時刻の控えと棚卸し (dotfiles-private の ADR 123)
#     - set-token は入れた時刻 (日本時間・秒まで) を ~/.local/state/claude-accounts/tokens.json (600) に控え、ほかの名前の時刻は残す。
#       控えが読めない形なら値を読む前に 1 で止まり、何も書かない。remove --purge は控えからも外す
#     - 素の claude (default): 宣言の無い package では check default が ~/.claude/.credentials.json を見て 0・1、set-token default は 2、
#       list は default を素の claude として出す。add・remove の default は 2。help token default は素の claude の手順
#     - audit: 宣言が無ければ「宣言: なし」で、置き場が無ければ 0。宣言・登録・token のファイル・控えから、ok・回す (330 日を超えた・控えが
#       無い)・入れる (登録が無い・token が無い)・直す (権限)・宣言漏れ (宣言の無い token のアカウントと、宣言の無い default.env) を出し、
#       手を入れるものがあれば 1。宣言・控えが読めない形なら 2。どの出力にも値を出さない
#   素の claude の wrapper (5 つ目の引数の package。bareToken)
#     - CLAUDE_CONFIG_DIR を付けずに claude を起こすと、default.env の token を渡し、CLAUDE_CONFIG_DIR を付けず、受け継いだ API キー・
#       token を外して本物の claude (PATH の次の claude) を起こし、引数と終了コードを渡す。token が無ければ 1 で忠告 (ブラウザのある端末・
#       set-token default)、権限が 644 なら 1、op の参照なら op を 1 回呼ぶ
#     - CLAUDE_CONFIG_DIR を付けて起こすと、env に手を出さずに本物の claude を起こす。PATH に自分しか claude が無ければ 127
#     - check default は token のファイルと wrapper の link を見る。set-token default は default.env に書いて時刻を控える。list は token
#     - claude-<名前> の launcher は、PATH の先の wrapper を飛ばして本物の claude を起こす
#     - audit は宣言した default を「default (素の claude)」として並べ、token が無ければ入れる
#
# 偽の claude は受けた env (CLAUDE_CONFIG_DIR・CLAUDE_CODE_OAUTH_TOKEN・ANTHROPIC_API_KEY・ANTHROPIC_AUTH_TOKEN) と引数を
# $HOME/claude.log に書き、FAKE_CLAUDE_EXIT で終わる。偽の op は inject の stdin の {{ … }} を dummy-op-value に替え、呼ばれた
# 引数を $HOME/op.log に書く (FAKE_OP_EXIT があれば何も出さずにその値で終わる)。どちらの shebang も $BASH から作る。

set -u -o pipefail

pkg=${1:?claude-account の package を渡す}
profile_bin=${2:?package に埋めた profileBin を渡す}
bootstrap=${3:?bootstrap-claude-accounts.sh を渡す}
pkg_t3=${4:-}
pkg_bare=${5:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/claude-account-test.XXXXXX")
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

fakebin="${work}/fake-bin"
mkdir -p "${fakebin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
{
  printf 'dir=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}"
  printf 'oauth=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
  printf 'key=%s\n' "${ANTHROPIC_API_KEY-<unset>}"
  printf 'auth=%s\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}"
  for a in "$@"; do
    printf 'arg=%s\n' "${a}"
  done
} >"${HOME}/claude.log"
exit "${FAKE_CLAUDE_EXIT:-0}"
EOF
} >"${fakebin}/claude"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$*" >>"${HOME}/op.log"
if [[ -n ${FAKE_OP_EXIT-} ]]; then
  exit "${FAKE_OP_EXIT}"
fi
if [[ ${1-} != inject ]]; then
  echo "op (偽物): inject だけを受ける: $*" >&2
  exit 9
fi
while IFS= read -r line; do
  if [[ ${line} == '{{ '*' }}' ]]; then
    printf '%s\n' "${FAKE_OP_VALUE-dummy-op-value}"
  else
    printf '%s\n' "${line}"
  fi
done
EOF
} >"${fakebin}/op"
chmod +x "${fakebin}/claude" "${fakebin}/op"

# 名前ごとの launcher (package の claude-account への link。$0 の名前で振り分ける)
linkbin="${work}/link-bin"
mkdir -p "${linkbin}"
for n in claude-account claude-personal claude-token1 claude-sub2 claude-nosuch; do
  ln -s "${pkg}/bin/claude-account" "${linkbin}/${n}"
done
coreutils_bin=$(dirname "$(command -v mkdir)")
jq_bin=$(dirname "$(command -v jq)")

home="${work}/home"
reset_home() {
  rm -rf "${home}"
  mkdir -p "${home}/.claude/projects" "${home}/.claude/skills/pjp-a" "${home}/.local/state/dotfiles"
  printf '{}\n' >"${home}/.claude/settings.json"
  printf '# 指示\n' >"${home}/.claude/CLAUDE.md"
  printf '["personal","work"]\n' >"${home}/.local/state/dotfiles/claude-accounts.json"
}

# $1: 呼ぶ名前 (link-bin の中)、残り: 引数。stdin は STDIN_TEXT (無ければ /dev/null)。out・err・rc を $work に残す
run() {
  local cmd=$1
  shift
  local input=/dev/null
  if [[ -n ${STDIN_TEXT+set} ]]; then
    printf '%s' "${STDIN_TEXT}" >"${work}/stdin"
    input="${work}/stdin"
  fi
  rm -f "${home}/claude.log" "${home}/op.log"
  # RUN_NO_CONFIG_DIR: CLAUDE_CONFIG_DIR を渡さない (素の claude の wrapper)。RUN_NO_FAKE_CLAUDE: PATH に偽の claude・op を置かない。
  # CLAUDE_ACCOUNT_NOW: 今の時刻 (控えと棚卸し)
  local path="${linkbin}:${fakebin}:${coreutils_bin}:${jq_bin}:${home}/.local/bin"
  local -a extra=()
  if [[ -n ${RUN_NO_FAKE_CLAUDE-} ]]; then
    path="${linkbin}:${coreutils_bin}:${jq_bin}:${home}/.local/bin"
  fi
  if [[ -z ${RUN_NO_CONFIG_DIR-} ]]; then
    extra+=(CLAUDE_CONFIG_DIR=/somewhere/else)
  fi
  if [[ -n ${CLAUDE_ACCOUNT_NOW-} ]]; then
    extra+=("CLAUDE_ACCOUNT_NOW=${CLAUDE_ACCOUNT_NOW}")
  fi
  env -i HOME="${home}" PATH="${path}" \
    ANTHROPIC_API_KEY=dummy-inherited-key ANTHROPIC_AUTH_TOKEN=dummy-inherited-auth CLAUDE_CODE_OAUTH_TOKEN=dummy-inherited-oauth \
    FAKE_CLAUDE_EXIT="${FAKE_CLAUDE_EXIT:-0}" ${FAKE_OP_EXIT:+FAKE_OP_EXIT="${FAKE_OP_EXIT}"} \
    ${FAKE_OP_VALUE+FAKE_OP_VALUE="${FAKE_OP_VALUE}"} "${extra[@]}" \
    "${linkbin}/${cmd}" "$@" <"${input}" >"${work}/out" 2>"${work}/err"
  echo $? >"${work}/rc"
}
rc() { cat "${work}/rc"; }
detail() {
  printf 'rc=%s\n--- out\n%s\n--- err\n%s\n--- claude.log\n%s' "$(rc)" "$(cat "${work}/out")" "$(cat "${work}/err")" \
    "$(cat "${home}/claude.log" 2>/dev/null)"
}
# 出力 (out・err) にダミーの値が無い
no_values() {
  ! grep -Fq dummy- "${work}/out" && ! grep -Fq dummy- "${work}/err"
}
token_file="${home}/.config/claude-accounts/token1.env"
put_token() { # $1: 中身、$2: 権限
  mkdir -p "${home}/.config/claude-accounts"
  printf '%s' "$1" >"${token_file}"
  chmod "$2" "${token_file}"
}
mode_of() { jq -r --arg n "$1" '.accounts[$n].mode // "<none>"' "${home}/.config/claude-accounts/accounts.json"; }

echo "== claude-account: ${pkg}"

# --- 管理のコマンド: 使い方
reset_home
run claude-account
if [[ $(rc) == 2 ]] && grep -Fq '使い方: claude-account' "${work}/err"; then
  ok "引数なしは 2 で使い方を stderr に出す"
else
  ng "引数なし" "$(detail)"
fi
run claude-account --help
if [[ $(rc) == 0 ]] && grep -Fq 'add <名前> --mode subscription|token' "${work}/out"; then
  ok "--help は 0 で使い方を stdout に出す"
else
  ng "--help" "$(detail)"
fi
run claude-account frobnicate
if [[ $(rc) == 2 ]]; then ok "知らないサブコマンドは 2"; else ng "知らないサブコマンド" "$(detail)"; fi
run claude-account help token
if [[ $(rc) == 0 ]] && grep -Fq 'claude-account set-token <名前>' "${work}/out" \
  && grep -Fq 'claude-account check <名前>' "${work}/out" && grep -Fq 'Claude Code の ! は使わない' "${work}/out" \
  && grep -Fq "umask 077 && mkdir -p ~/.config/claude-accounts && read -rsp" "${work}/out" \
  && grep -Fq '&& chmod 600 ~/.config/claude-accounts/<名前>.env' "${work}/out" \
  && grep -Fq 'CLAUDE_CODE_OAUTH_TOKEN=op://' "${work}/out"; then
  ok "help token: このマシン・ほかのマシン (claude-account が無いときの 1 行も)・check・値の取り方・op の形を出す"
else
  ng "help token" "$(detail)"
fi
run claude-account help token token1
if [[ $(rc) == 0 ]] && grep -Fq 'claude-account add token1 --mode token' "${work}/out" \
  && grep -Fq '/.config/claude-accounts/token1.env && unset t' "${work}/out"; then
  ok "help token <名前> は名前を埋めて出す"
else
  ng "help token token1" "$(detail)"
fi
run claude-account help nosuch
if [[ $(rc) == 2 ]]; then ok "知らない help は 2"; else ng "知らない help" "$(detail)"; fi

# --- add の断り
bad=0
for args in "add Bad --mode token" "add account --mode token" "add selector --mode subscription" "add personal --mode subscription" "add x --mode foo" "add x" "add"; do
  # shellcheck disable=SC2086 # 引数を空白で分ける
  run claude-account ${args}
  [[ $(rc) == 2 ]] || {
    bad=1
    ng "${args} は 2" "$(detail)"
  }
done
if [[ ! -e ${home}/.config/claude-accounts/accounts.json ]] && ((bad == 0)); then
  ok "add は規則外の名前・account・selector・既定の名前・知らない種類・種類なしを 2 で断り、登録しない"
fi

# --- add token1 --mode token
run claude-account add token1 --mode token
if [[ $(rc) == 0 && $(mode_of token1) == token ]] \
  && [[ $(readlink "${home}/.local/bin/claude-token1") == "${profile_bin}/claude-account" ]] \
  && [[ $(readlink "${home}/.claude-token1/settings.json") == "${home}/.claude/settings.json" ]] \
  && [[ $(readlink "${home}/.claude-token1/projects") == "${home}/.claude/projects" ]] \
  && [[ -L ${home}/.claude-token1/skills/pjp-a ]] \
  && grep -Fq 'claude setup-token' "${work}/out" && grep -Fq 'claude-account set-token token1' "${work}/out" \
  && grep -Fq 'ほかのマシン' "${work}/out" && grep -Fq 'claude-account check token1' "${work}/out" \
  && [[ $(stat -c %a "${home}/.config/claude-accounts") == 700 ]]; then
  ok "add token1 --mode token: 登録に書き、launcher を profileBin の claude-account への link にし、dir を用意し、置き方 (help token) を出す"
else
  ng "add token1 --mode token" "$(detail)
--- accounts.json
$(cat "${home}/.config/claude-accounts/accounts.json" 2>/dev/null)
--- ls
$(ls -la "${home}/.local/bin" "${home}/.claude-token1" 2>&1)"
fi
run claude-account add token1 --mode token
if [[ $(rc) == 0 ]]; then ok "同じ種類の add の打ち直しは 0"; else ng "add の打ち直し" "$(detail)"; fi
run claude-account add token1 --mode subscription
if [[ $(rc) == 1 && $(mode_of token1) == token ]] && grep -Fq 'remove' "${work}/err"; then
  ok "違う種類の add は 1 で、remove してから足すよう出す"
else
  ng "違う種類の add" "$(detail)"
fi
run claude-account add sub2 --mode subscription
if [[ $(rc) == 0 && $(mode_of sub2) == subscription ]] && grep -Fq '/login' "${work}/out" \
  && [[ -L ${home}/.claude-sub2/settings.json ]]; then
  ok "add sub2 --mode subscription は登録して dir を用意し、/login を出す"
else
  ng "add sub2" "$(detail)"
fi
mkdir -p "${home}/.claude-real1"
printf '{}\n' >"${home}/.claude-real1/settings.json"
run claude-account add real1 --mode subscription
if [[ $(rc) == 1 ]] && grep -Fq '既に ~/.claude-<名前> があるとき' "${work}/err"; then
  ok "add は用意が済まなければ (settings.json が実体) 1 で、片付け方を出す"
else
  ng "add (実体)" "$(detail)"
fi
printf 'mine\n' >"${home}/.local/bin/claude-other"
run claude-account add other --mode token
if [[ $(rc) == 1 && $(mode_of other) == '<none>' ]] && grep -Fq 'claude-other' "${work}/err"; then
  ok "launcher の置き場 (~/.local/bin) に claude-<名前> のほかのファイルがあれば 1 で、登録しない"
else
  ng "ほかのファイルがある add" "$(detail)"
fi

# --- check
run claude-account check token1
if [[ $(rc) == 1 && ! -s ${work}/out ]] && grep -Fq 'claude-account set-token token1' "${work}/err" \
  && grep -Fq 'claude setup-token' "${work}/err"; then
  ok "check: token が無ければ 1 で、stderr に set-token の手を出す"
else
  ng "check (token なし)" "$(detail)"
fi
run claude-account check nosuch
if [[ $(rc) == 2 ]] && grep -Fq 'claude-account add nosuch --mode' "${work}/err"; then
  ok "check: 知らない名前は 2 で、足す手 (claude-account add <名前> --mode …) を出す"
else
  ng "check (知らない名前)" "$(detail)"
fi
bad=0
for sub in "check" "set-token" "remove" "add"; do
  if [[ ${sub} == add ]]; then
    run claude-account add sk-ant-oat01-dummy-leak-1 --mode token
  else
    STDIN_TEXT=$'dummy-x\n' run claude-account "${sub}" sk-ant-oat01-dummy-leak-1
  fi
  if [[ $(rc) != 2 ]] || ! no_values; then
    bad=1
    ng "名前に token を渡した ${sub}" "$(detail)"
  fi
done
if ((bad == 0)); then ok "名前に token を渡しても (規則に合わない名前は) 2 で、文に出さない"; fi
run claude-account check personal
if [[ $(rc) == 1 ]] && grep -Fq 'setup' "${work}/err"; then
  ok "check: 既定の dir が用意されていなければ 1 で setup を出す"
else
  ng "check (既定の用意なし)" "$(detail)"
fi
run claude-account check sub2
if [[ $(rc) == 1 ]] && grep -Fq 'claude-sub2 を起こし、/login' "${work}/err"; then
  ok "check: subscription でログインしていなければ 1 で /login を出す"
else
  ng "check (ログインなし)" "$(detail)"
fi
printf '{}\n' >"${home}/.claude-sub2/.credentials.json"
run claude-account check sub2
if [[ $(rc) == 0 && $(cat "${work}/out") == 'claude-sub2: subscription (ログイン済み)' ]]; then
  ok "check: ログイン済みの subscription は 0 で 1 行"
else
  ng "check (ログイン済み)" "$(detail)"
fi
put_token 'CLAUDE_CODE_OAUTH_TOKEN=dummy-plain-1
' 600
run claude-account check token1
if [[ $(rc) == 0 && $(cat "${work}/out") == 'claude-token1: token (ローカル)' ]] && no_values; then
  ok "check: 権限 600 のローカルの token は 0 で「token (ローカル)」"
else
  ng "check (ローカル)" "$(detail)"
fi
chmod 644 "${token_file}"
run claude-account check token1
if [[ $(rc) == 1 ]] && grep -Fq 'chmod 600' "${work}/err" && no_values; then
  ok "check: 権限 644 のローカルの token は 1 で chmod 600 を出す"
else
  ng "check (644)" "$(detail)"
fi
put_token 'CLAUDE_CODE_OAUTH_TOKEN=op://vault/item/field
' 644
run claude-account check token1
if [[ $(rc) == 0 && $(cat "${work}/out") == 'claude-token1: token (1Password・起動のときに承認が要る)' && ! -e ${home}/op.log ]]; then
  ok "check: op の参照は権限を見ずに 0 で「token (1Password・起動のときに承認が要る)」。op は呼ばない"
else
  ng "check (op)" "$(detail)"
fi
put_token 'ANTHROPIC_API_KEY=dummy-other
' 600
run claude-account check token1
if [[ $(rc) == 1 ]] && grep -Fq '1 行目' "${work}/err" && no_values; then
  ok "check: ほかの名前の行は 1 で行の番号を出し、値を出さない"
else
  ng "check (ほかの名前)" "$(detail)"
fi
mv "${home}/.local/bin/claude-sub2" "${work}/claude-sub2.bak"
run claude-account check sub2
if [[ $(rc) == 1 ]] && grep -Fq 'claude-account add sub2 --mode subscription' "${work}/err"; then
  ok "check: 登録のアカウントの launcher が無ければ 1 で add の打ち直しを出す"
else
  ng "check (launcher なし)" "$(detail)"
fi
mv "${work}/claude-sub2.bak" "${home}/.local/bin/claude-sub2"

# --- set-token
put_token 'CLAUDE_CODE_OAUTH_TOKEN=op://vault/item/field
' 644
STDIN_TEXT=$'dummy-set-1\n' run claude-account set-token token1
if [[ $(rc) == 0 && $(stat -c %a "${token_file}") == 600 ]] && grep -Fxq 'CLAUDE_CODE_OAUTH_TOKEN=dummy-set-1' "${token_file}" \
  && ! grep -Fq 'op://' "${token_file}" && no_values && grep -Fq 'sk-ant-oat' "${work}/err"; then
  ok "set-token: パイプの 1 行を権限 600 の行にし (op の参照を置き換え)、sk-ant-oat でなければ注意を出し、値を出さない"
else
  ng "set-token" "$(detail)
--- file ($(stat -c %a "${token_file}" 2>&1))
$(sed 's/dummy-[^ ]*/<dummy>/' "${token_file}" 2>&1)"
fi
STDIN_TEXT=$'sk-ant-oat01-dummy-set-2\n' run claude-account set-token token1
if [[ $(rc) == 0 ]] && grep -Fxq 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-dummy-set-2' "${token_file}" && no_values \
  && ! grep -Fq 'sk-ant-oat で始まり' "${work}/err"; then
  ok "set-token: sk-ant-oat で始まる token は注意なしで書く"
else
  ng "set-token (sk-ant-oat)" "$(detail)"
fi
before=$(cat "${token_file}")
STDIN_TEXT=$'\n' run claude-account set-token token1
r1=$(rc)
STDIN_TEXT=$'op://vault/item/field\n' run claude-account set-token token1
r2=$(rc)
STDIN_TEXT=$'dummy-x\n' run claude-account set-token token1 extra
r3=$(rc)
STDIN_TEXT=$'dummy-x\n' run claude-account set-token sub2
r4=$(rc)
STDIN_TEXT=$'dummy-x\n' run claude-account set-token nosuch
r5=$(rc)
if [[ ${r1}/${r2}/${r3}/${r4}/${r5} == 1/1/2/2/2 && $(cat "${token_file}") == "${before}" ]]; then
  ok "set-token: 空と op:// は 1、ほかの引数・subscription・知らない名前は 2 で、どれも書かない"
else
  ng "set-token の断り (${r1}/${r2}/${r3}/${r4}/${r5})" "$(detail)"
fi

# --- list
run claude-account list
if [[ $(rc) == 0 ]] && grep -Eq '^personal +subscription +既定' "${work}/out" && grep -Eq '^work +subscription +既定' "${work}/out" \
  && grep -Eq '^token1 +token +登録' "${work}/out" && grep -Eq '^sub2 +subscription +登録' "${work}/out" && no_values; then
  ok "list: 既定と登録のアカウントを種類と元と一緒に並べる"
else
  ng "list" "$(detail)"
fi

# --- launcher: 既定
run claude-personal -p hi
if [[ $(rc) == 1 ]] && grep -Fq 'まだ用意されていません' "${work}/err" && [[ ! -e ${home}/claude.log ]]; then
  ok "既定の launcher は用意が無ければ 1 で、claude を起こさない"
else
  ng "既定の launcher (用意なし)" "$(detail)"
fi
env -i HOME="${home}" PATH="${fakebin}:${coreutils_bin}:${jq_bin}" "${BASH}" "${bootstrap}" >"${work}/bs.out" 2>&1
FAKE_CLAUDE_EXIT=7 run claude-personal -p '日本語 の 引数'
want="dir=${home}/.claude-personal
oauth=<unset>
key=<unset>
auth=<unset>
arg=-p
arg=日本語 の 引数"
if [[ $(rc) == 7 && $(cat "${home}/claude.log") == "${want}" ]]; then
  ok "既定の launcher は env を外し CLAUDE_CONFIG_DIR を付け、引数と終了コードを渡す"
else
  ng "既定の launcher" "$(detail)"
fi
run claude-nosuch
if [[ $(rc) == 2 ]] && grep -Fq 'claude-account add nosuch' "${work}/err" && [[ ! -e ${home}/claude.log ]]; then
  ok "既定でも登録でもない名前の launcher は 2 で add を出す"
else
  ng "知らない名前の launcher" "$(detail)"
fi

# --- bootstrap: 登録のアカウントも用意し、launcher の link が無ければ警告する
if [[ -L ${home}/.claude-token1/settings.json && -L ${home}/.claude-work/settings.json ]] \
  && ! grep -Fq 'claude-token1 の launcher' "${work}/bs.out"; then
  ok "bootstrap (引数なし) は既定と登録のアカウントの dir を用意する"
else
  ng "bootstrap (引数なし)" "$(cat "${work}/bs.out")"
fi
rm "${home}/.local/bin/claude-token1"
rm -rf "${home}/.claude-token1"
env -i HOME="${home}" PATH="${fakebin}:${coreutils_bin}:${jq_bin}" "${BASH}" "${bootstrap}" >"${work}/bs.out" 2>&1
if [[ -L ${home}/.claude-token1/settings.json ]] && grep -Fq 'claude-account add token1 --mode token' "${work}/bs.out"; then
  ok "bootstrap は消えた登録のアカウントの dir を作り直し、launcher の link が無ければ add の打ち直しを出す"
else
  ng "bootstrap (launcher なし)" "$(cat "${work}/bs.out")"
fi
ln -s "${profile_bin}/claude-account" "${home}/.local/bin/claude-token1"
rm -rf "${home}/.claude-sub2"
env -i HOME="${home}" PATH="${fakebin}:${coreutils_bin}:${jq_bin}" "${BASH}" "${bootstrap}" --account sub2 >"${work}/bs.out" 2>&1
if [[ -L ${home}/.claude-sub2/settings.json ]] && ! grep -Fq '.claude-personal' "${work}/bs.out"; then
  ok "bootstrap --account は、そのアカウントの dir だけを用意する"
else
  ng "bootstrap --account" "$(cat "${work}/bs.out")"
fi

# --- launcher: token
rm -f "${token_file}"
run claude-token1 -p hi
if [[ $(rc) == 1 && ! -e ${home}/claude.log ]] && grep -Fq 'token がありません' "${work}/err" \
  && grep -Fq 'claude setup-token' "${work}/err" && grep -Fq 'claude-account set-token token1' "${work}/err" \
  && grep -Fq 'CLAUDE_CODE_OAUTH_TOKEN=op://' "${work}/err" && grep -Fq '600' "${work}/err"; then
  ok "token が無ければ 1 で忠告 (setup-token・set-token・op の参照) を出し、claude を起こさない"
else
  ng "token なし" "$(detail)"
fi
bad=0
for body in '# コメント
' 'CLAUDE_CODE_OAUTH_TOKEN=
'; do
  put_token "${body}" 600
  run claude-token1
  if [[ $(rc) != 1 || -e ${home}/claude.log ]] || ! grep -Fq 'claude-account set-token token1' "${work}/err"; then
    bad=1
    ng "行が無い・値が空 (${body%%$'\n'*})" "$(detail)"
  fi
done
if ((bad == 0)); then
  ok "行が無い・値が空も 1 で忠告を出す"
fi
put_token 'CLAUDE_CODE_OAUTH_TOKEN=dummy-plain-1
' 600
FAKE_CLAUDE_EXIT=3 run claude-token1 -p 'a b'
want="dir=${home}/.claude-token1
oauth=dummy-plain-1
key=<unset>
auth=<unset>
arg=-p
arg=a b"
if [[ $(rc) == 3 && $(cat "${home}/claude.log") == "${want}" ]] && no_values; then
  ok "ローカルの token を渡し、受け継いだ認証の env を外し、引数と終了コードを渡す"
else
  ng "ローカルの token" "$(detail)"
fi
put_token $'\xef\xbb\xbf# token1\r\n\r\nexport CLAUDE_CODE_OAUTH_TOKEN="dummy-plain-2"  # 入れた\r\n' 600
run claude-token1
if [[ $(rc) == 0 ]] && grep -Fxq 'oauth=dummy-plain-2' "${home}/claude.log"; then
  ok "BOM・CRLF・空行・コメント・export・\"…\"・後ろのコメントでも読む"
else
  ng "BOM・CRLF" "$(detail)"
fi
put_token "CLAUDE_CODE_OAUTH_TOKEN='dummy-plain-3'
" 600
run claude-token1
if [[ $(rc) == 0 ]] && grep -Fxq 'oauth=dummy-plain-3' "${home}/claude.log"; then
  ok "'…' でも読む"
else
  ng "'…'" "$(detail)"
fi
chmod 644 "${token_file}"
run claude-token1
if [[ $(rc) == 1 && ! -e ${home}/claude.log ]] && grep -Fq '600' "${work}/err" && no_values; then
  ok "権限 644 のローカルの token は 1 で、claude を起こさない"
else
  ng "644" "$(detail)"
fi
check_stop() { # $1: 中身、$2: 出す文の一部、$3: 名前
  put_token "$1" 600
  run claude-token1
  if [[ $(rc) == 1 && ! -e ${home}/claude.log ]] && grep -Fq "$2" "${work}/err" && no_values; then
    ok "$3"
  else
    ng "$3" "$(detail)"
  fi
}
check_stop 'CLAUDE_CODE_OAUTH_TOKEN=dummy-a
ANTHROPIC_API_KEY=dummy-b
' '2 行目に ANTHROPIC_API_KEY' "ほかの名前の行は 1 で、行の番号と名前を出し、値を出さない"
check_stop 'CLAUDE_CODE_OAUTH_TOKEN=dummy-a
CLAUDE_CODE_OAUTH_TOKEN=dummy-b
' '2 つあります' "CLAUDE_CODE_OAUTH_TOKEN の 2 つ目の行は 1"
check_stop 'dummy-raw-token
' '1 行目が KEY=値' "KEY=値 でない行は 1 で、行の番号だけを出す"
check_stop 'CLAUDE_CODE_OAUTH_TOKEN=dummy a b
' 'token の形ではありません' "空白のある値は 1 で、値を出さない"

# --- launcher: op
put_token 'CLAUDE_CODE_OAUTH_TOKEN=op://vault/item/field
' 644
run claude-token1 -p hi
if [[ $(rc) == 0 && $(grep -c . "${home}/op.log") == 1 ]] && grep -Fxq 'oauth=dummy-op-value' "${home}/claude.log" \
  && grep -Fxq "dir=${home}/.claude-token1" "${home}/claude.log" && grep -Fxq 'key=<unset>' "${home}/claude.log" && no_values; then
  ok "op の参照なら op を 1 回呼び、claude に値が届く"
else
  ng "op" "$(detail)
--- op.log
$(cat "${home}/op.log" 2>/dev/null)"
fi
FAKE_OP_EXIT=5 run claude-token1
if [[ $(rc) == 5 && ! -e ${home}/claude.log ]]; then
  ok "op が 5 で終われば 5 で、claude を起こさない"
else
  ng "op の失敗" "$(detail)"
fi
bad=0
for v in '' 'dummy op value'; do
  FAKE_OP_VALUE=${v} run claude-token1
  if [[ $(rc) != 70 || -e ${home}/claude.log ]] || ! no_values; then
    bad=1
    ng "1Password から読んだ値「${v}」" "$(detail)"
  fi
done
if ((bad == 0)); then ok "1Password から読んだ値が空・空白入りなら claude を起こさず 70 (値は出さない)"; fi
put_token 'CLAUDE_CODE_OAUTH_TOKEN=" op://vault/item/field"
' 600
run claude-account check token1
r1=$(rc)
run claude-token1
if [[ ${r1} == 1 && $(rc) == 1 && ! -e ${home}/claude.log && ! -e ${home}/op.log ]]; then
  ok "引用符の中の前後の空白は値の一部で、check も launcher も止まる"
else
  ng "引用符の中の空白 (${r1})" "$(detail)"
fi
mkdir -p "${work}/elsewhere"
printf 'CLAUDE_CODE_OAUTH_TOKEN=dummy-plain-8\n' >"${work}/elsewhere/t.env"
chmod 600 "${work}/elsewhere/t.env"
rm -f "${token_file}"
ln -s "${work}/elsewhere/t.env" "${token_file}"
run claude-account check token1
r1=$(rc)
grep -Fq 'set-token' "${work}/err"
g1=$?
run claude-token1
if [[ ${r1} == 1 && ${g1} == 0 && $(rc) == 1 && ! -e ${home}/claude.log ]] && no_values; then
  ok "token のファイルがリンクなら check も launcher も止まり、set-token を出す"
else
  ng "token のファイルがリンク (${r1}/${g1})" "$(detail)"
fi
rm -f "${token_file}"

# --- 登録の一覧が壊れている
cp "${home}/.config/claude-accounts/accounts.json" "${work}/accounts.bak"
printf '{"version":1,"accounts":[' >"${home}/.config/claude-accounts/accounts.json"
run claude-token1
r1=$(rc)
run claude-personal
r2=$(rc)
if [[ ${r1} == 1 && ${r2} == 0 ]]; then
  ok "登録の一覧が壊れていれば登録のアカウントは 1 で、既定はそのまま起きる"
else
  ng "壊れた登録 (${r1}/${r2})" "$(detail)"
fi
printf '{"version":1,"accounts":{"Bad Name":{"mode":"token"}}}\n' >"${home}/.config/claude-accounts/accounts.json"
run claude-account list
if [[ $(rc) == 1 && $(grep -c 'accounts.json' "${work}/err") == 1 ]] && grep -Eq '^personal ' "${work}/out"; then
  ok "登録の規則外の名前は読めない形。list は既定を並べ、読めない形を 1 回だけ出して 1"
else
  ng "規則外の名前の登録" "$(detail)"
fi
printf '{"version":1,"accounts":{"selector":{"mode":"subscription"}}}\n' >"${home}/.config/claude-accounts/accounts.json"
run claude-account list
if [[ $(rc) == 1 && $(grep -c 'accounts.json' "${work}/err") == 1 ]] && grep -Eq '^personal ' "${work}/out"; then
  ok "登録の selector (claude-selector の名前) は読めない形"
else
  ng "selector の登録" "$(detail)"
fi
cp "${work}/accounts.bak" "${home}/.config/claude-accounts/accounts.json"

# --- remove
run claude-account remove personal
r1=$(rc)
run claude-account remove nosuch
r2=$(rc)
run claude-account remove selector
r3=$(rc)
if [[ ${r1}/${r2}/${r3} == 2/2/2 ]]; then
  ok "remove: 既定・知らない名前・selector は 2"
else
  ng "remove の断り (${r1}/${r2}/${r3})" "$(detail)"
fi
run claude-account remove sub2
if [[ $(rc) == 0 && $(mode_of sub2) == '<none>' && ! -e ${home}/.local/bin/claude-sub2 && ! -L ${home}/.local/bin/claude-sub2 ]] \
  && [[ -d ${home}/.claude-sub2 ]] && grep -Fq -- '--purge' "${work}/out"; then
  ok "remove: 登録から外して launcher を消し、dir を残して --purge を出す"
else
  ng "remove" "$(detail)"
fi
run claude-account remove sub2 --purge
if [[ $(rc) == 0 && ! -e ${home}/.claude-sub2 ]] && [[ -f ${home}/.claude/settings.json && -d ${home}/.claude/projects ]] \
  && [[ -d ${home}/.claude/skills/pjp-a ]]; then
  ok "remove --purge: 登録から外したあとでも dir を消し、中のリンクの先 (~/.claude) は残す"
else
  ng "remove --purge (登録の外)" "$(detail)"
fi
put_token 'CLAUDE_CODE_OAUTH_TOKEN=dummy-plain-1
' 600
run claude-account remove token1 --purge
if [[ $(rc) == 0 && $(mode_of token1) == '<none>' && ! -e ${token_file} && ! -e ${home}/.claude-token1 ]] \
  && [[ ! -L ${home}/.local/bin/claude-token1 && -f ${home}/.claude/settings.json ]] && no_values; then
  ok "remove --purge: 登録・launcher・dir・token のファイルを消す"
else
  ng "remove --purge" "$(detail)"
fi

# --- 既定に足した名前 (前に add で登録してから、dotfiles が既定に足した t3)
if [[ -n ${pkg_t3} ]]; then
  reset_home
  ln -s "${pkg}/bin/claude-account" "${linkbin}/claude-t3"
  run claude-account add t3 --mode subscription
  r1=$(rc)
  ln -sfn "${pkg_t3}/bin/claude-account" "${linkbin}/claude-account"
  run claude-account list
  if [[ ${r1} == 0 && $(rc) == 0 && $(grep -Ec '^t3 ' "${work}/out") == 1 ]] && grep -Eq '^t3 +subscription +既定' "${work}/out"; then
    ok "既定に足した名前は、登録にあっても list に 1 度だけ既定として出る"
  else
    ng "既定と登録の重なりの list (${r1})" "$(detail)"
  fi
  run claude-account remove t3 --purge
  if [[ $(rc) == 0 && $(mode_of t3) == '<none>' && ! -e ${home}/.local/bin/claude-t3 && ! -L ${home}/.local/bin/claude-t3 ]] \
    && [[ -d ${home}/.claude-t3 ]] && grep -Fq '登録から外しました: t3' "${work}/out"; then
    ok "既定に足した名前の remove は、登録と launcher の link だけを外し、--purge でも dir を残す"
  else
    ng "既定と登録の重なりの remove" "$(detail)"
  fi
  run claude-account remove t3
  if [[ $(rc) == 2 ]] && grep -Fq '既定のアカウントなので消せません' "${work}/err"; then
    ok "登録から外した後の既定の名前の remove は 2"
  else
    ng "既定の名前の remove の打ち直し" "$(detail)"
  fi
  ln -sfn "${pkg}/bin/claude-account" "${linkbin}/claude-account"
  rm -f "${linkbin}/claude-t3"
fi

# --- set-token が入れた時刻の控え (ADR 123)
times="${home}/.local/state/claude-accounts/tokens.json"
reset_home
run claude-account add token1 --mode token
run claude-account add token2 --mode token
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' STDIN_TEXT=$'sk-ant-oat01-dummy-rec-1\n' run claude-account set-token token1
r1=$(rc)
cp "${work}/out" "${work}/out1"
CLAUDE_ACCOUNT_NOW='2026-11-29T08:30:15+09:00' STDIN_TEXT=$'sk-ant-oat01-dummy-rec-2\n' run claude-account set-token token2
if [[ ${r1} == 0 && $(rc) == 0 ]] && [[ $(jq -r '.token1.set_at' "${times}") == '2026-11-28T21:00:00+09:00' ]] \
  && [[ $(jq -r '.token2.set_at' "${times}") == '2026-11-29T08:30:15+09:00' ]] \
  && grep -Fq '入れた時刻: 2026-11-28T21:00:00+09:00' "${work}/out1" && [[ $(stat -c %a "${times}") == 600 ]] \
  && ! grep -Fq dummy "${times}" && no_values; then
  ok "set-token は入れた時刻 (日本時間・秒まで) を控え (600)、ほかの名前の時刻は残す。控えに値は無い"
else
  ng "set-token の控え" "$(detail)
--- tokens.json
$(cat "${times}" 2>/dev/null)"
fi
cp "${times}" "${work}/times.bak"
printf 'not json\n' >"${times}"
put_token 'CLAUDE_CODE_OAUTH_TOKEN=dummy-keep-1
' 600
STDIN_TEXT=$'sk-ant-oat01-dummy-rec-3\n' run claude-account set-token token1
if [[ $(rc) == 1 ]] && grep -Fq '入れた時刻の控え' "${work}/err" && grep -Fq 'dummy-keep-1' "${token_file}" && no_values; then
  ok "控えが読めない形なら、値を読む前に 1 で止まり、token のファイルを書かない"
else
  ng "読めない控えの set-token" "$(detail)"
fi
cp "${work}/times.bak" "${times}"
run claude-account remove token2 --purge
if [[ $(rc) == 0 && $(jq -r '.token2 // "none"' "${times}") == none && $(jq -r '.token1.set_at' "${times}") == '2026-11-28T21:00:00+09:00' ]] \
  && grep -Fq '控えから外しました: token2' "${work}/out"; then
  ok "remove --purge は控えからもその名前の時刻を外し、ほかは残す"
else
  ng "remove --purge の控え" "$(detail)
--- tokens.json
$(cat "${times}" 2>/dev/null)"
fi

# --- 素の claude (default): 宣言の無いホストの package
reset_home
run claude-account check default
r1=$(rc)
cp "${work}/err" "${work}/err1"
printf '{}\n' >"${home}/.claude/.credentials.json"
run claude-account check default
if [[ ${r1} == 1 ]] && grep -Fq 'claude: まだログインしていません' "${work}/err1" && grep -Fq '/login' "${work}/err1" \
  && [[ $(rc) == 0 ]] && grep -Fxq 'claude: subscription (ログイン済み)' "${work}/out"; then
  ok "宣言の無いホストの check default は ~/.claude/.credentials.json を見て 1・0"
else
  ng "check default (宣言なし)" "$(detail)"
fi
run claude-account list
if [[ $(rc) == 0 ]] && grep -Eq '^default +subscription +素の claude +ログイン済み' "${work}/out"; then
  ok "list は default を素の claude として出す"
else
  ng "list の default" "$(detail)"
fi
STDIN_TEXT=$'sk-ant-oat01-dummy-bare-0\n' run claude-account set-token default
r1=$(rc)
run claude-account add default --mode token
r2=$(rc)
run claude-account remove default
r3=$(rc)
if [[ ${r1} == 2 && ${r2} == 2 && ${r3} == 2 && ! -e ${home}/.config/claude-accounts/default.env ]] \
  && [[ ! -e ${home}/.config/claude-accounts/accounts.json ]] && no_values; then
  ok "宣言の無いホストの set-token default と、add・remove の default は 2 で、何も書かない"
else
  ng "default の断り (${r1}/${r2}/${r3})" "$(detail)"
fi
run claude-account help token default
if [[ $(rc) == 0 ]] && grep -Fq 'claude-account set-token default' "${work}/out" && grep -Fq 'dotfiles.claude.tokens.default' "${work}/out" \
  && ! grep -Fq 'claude-account add default' "${work}/out"; then
  ok "help token default は素の claude の手順 (宣言と set-token default) を出す"
else
  ng "help token default" "$(detail)"
fi

# --- 棚卸し (audit)
decl="${home}/.local/state/dotfiles/claude-tokens.json"
reset_home
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ $(rc) == 0 ]] && grep -Fq '宣言: なし' "${work}/out" && grep -Fq 'token の置き場はありません' "${work}/out" \
  && grep -Fq '入れてから 330 日を超えたら回す' "${work}/out"; then
  ok "audit: 宣言も token も無ければ「宣言: なし」と置き場なしで 0"
else
  ng "audit (空)" "$(detail)"
fi
# 宣言: alt (ok にする)・x (登録が無い)。登録: alt・token1 (宣言なし)。token: alt・token1 (600)
audit_setup() {
  reset_home
  mkdir -p "${home}/.config/claude-accounts" "${home}/.local/state/claude-accounts"
  printf '{"accounts":{"alt":{"item":null,"label":"alt"},"x":{"item":"op://v/i/f","label":"shared"}}}\n' >"${decl}"
  printf '{"version":1,"accounts":{"alt":{"mode":"token"},"token1":{"mode":"token"},"sub2":{"mode":"subscription"}}}\n' \
    >"${home}/.config/claude-accounts/accounts.json"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=dummy-alt-1\n' >"${home}/.config/claude-accounts/alt.env"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=dummy-t1-1\n' >"${home}/.config/claude-accounts/token1.env"
  chmod 600 "${home}/.config/claude-accounts/"*.env
  printf '{"alt":{"set_at":"%s"}}\n' "${1:-2026-11-18T21:00:00+09:00}" >"${times}"
}
row() { grep -F "| $1 |" "${work}/out"; }
audit_setup
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ $(rc) == 1 ]] && row alt >/dev/null && [[ $(row alt) == '| alt | alt | - | ローカル | 600 | 2026-11-18 21:00 | 10 | ok |' ]] \
  && [[ $(row x) == '| x | shared | op://v/i/f | 無い | - | - | - | 入れる |' ]] \
  && [[ $(row token1) == '| token1 | - | - | ローカル | 600 | - | - | 宣言漏れ |' ]] \
  && grep -Fq -- '- x: 入れる — 登録が無い (claude-account add x --mode token を打ってから claude-account set-token x)' "${work}/out" \
  && grep -Fq -- '- token1: 宣言漏れ — 宣言 (dotfiles.claude.tokens.token1) が無い token の置き場' "${work}/out" \
  && grep -Fxq '判定: ok 1・回す 0・入れる 1・直す 0・宣言漏れ 1' "${work}/out" \
  && grep -Fq '宣言: ~/.local/state/dotfiles/claude-tokens.json (2 件)' "${work}/out" \
  && grep -Fq '控え: ~/.local/state/claude-accounts/tokens.json (1 件)' "${work}/out" && ! grep -Fq '| sub2 |' "${work}/out" && no_values; then
  ok "audit: 宣言・登録・token のファイル・控えから ok・入れる (登録が無い)・宣言漏れを出して 1 (subscription は並べない。値は出さない)"
else
  ng "audit" "$(detail)"
fi
audit_setup '2025-12-31T21:00:00+09:00'
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ $(rc) == 1 ]] && [[ $(row alt) == '| alt | alt | - | ローカル | 600 | 2025-12-31 21:00 | 332 | 回す |' ]] \
  && grep -Fq -- '- alt: 回す — 入れてから 332 日 (330 日を超えた。期限の 1 年まで残り 33 日)' "${work}/out"; then
  ok "audit: 入れてから 330 日を超えた token は回す (期限までの残りの日数も出す)"
else
  ng "audit (330 日)" "$(detail)"
fi
audit_setup '2025-12-31T21:00:00+09:00'
CLAUDE_ACCOUNT_NOW='2026-11-26T21:00:00+09:00' run claude-account audit
if [[ $(row alt) == '| alt | alt | - | ローカル | 600 | 2025-12-31 21:00 | 330 | ok |' ]]; then
  ok "audit: ちょうど 330 日は ok"
else
  ng "audit (ちょうど 330 日)" "$(detail)"
fi
audit_setup
rm -f "${times}"
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ $(rc) == 1 ]] && [[ $(row alt) == '| alt | alt | - | ローカル | 600 | - | - | 回す |' ]] \
  && grep -Fq -- '- alt: 回す — 入れた時刻の控えが無い (set-token で入れていない。ファイルの時刻は ' "${work}/out" \
  && grep -Fq '同じ token を set-token で入れ直せば控えができる' "${work}/out" && grep -Fq '控え: なし' "${work}/out"; then
  ok "audit: 入れた時刻の控えが無い token は回す (ファイルの時刻と、入れ直せば控えができることを添える)"
else
  ng "audit (控えなし)" "$(detail)"
fi
audit_setup
chmod 644 "${home}/.config/claude-accounts/alt.env"
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ $(row alt) == '| alt | alt | - | ローカル | 644 | 2026-11-18 21:00 | 10 | 直す |' ]] \
  && grep -Fq -- '- alt: 直す — token のファイルの権限が 644 です' "${work}/out"; then
  ok "audit: token のファイルの権限が 600 より緩ければ直す"
else
  ng "audit (権限)" "$(detail)"
fi
audit_setup
rm -f "${home}/.config/claude-accounts/alt.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=dummy-bare-x\n' >"${home}/.config/claude-accounts/default.env"
chmod 600 "${home}/.config/claude-accounts/default.env"
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ $(row alt) == '| alt | alt | - | 無い | - | 2026-11-18 21:00 | 10 | 入れる |' ]] \
  && grep -Fq -- '- alt: 入れる — token が無い (claude setup-token で出し、このホストで claude-account set-token alt で入れる)' "${work}/out" \
  && [[ $(row 'default (素の claude)') == '| default (素の claude) | - | - | ローカル | 600 | - | - | 宣言漏れ |' ]] \
  && grep -Fq -- '- default: 宣言漏れ — 宣言 (dotfiles.claude.tokens.default) が無いのに、素の claude の token のファイルがある' "${work}/out" \
  && no_values; then
  ok "audit: 宣言した token のファイルが無ければ入れる、宣言の無い default.env は宣言漏れ (素の claude を先に並べる)"
else
  ng "audit (入れる・default.env)" "$(detail)"
fi
audit_setup
printf '{"accounts":{"sk-ant-oat01-dummy":{"item":null,"label":"x"}}}\n' >"${decl}"
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
r1=$(rc)
cp "${work}/err" "${work}/err1"
audit_setup
printf '[1]\n' >"${times}"
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ ${r1} == 2 && $(rc) == 2 ]] && grep -Fq '宣言' "${work}/err1" && ! grep -Fq dummy "${work}/err1" \
  && grep -Fq '入れた時刻の控え' "${work}/err"; then
  ok "audit: 宣言・控えが読めない形なら 2 (宣言の字は出さない)"
else
  ng "audit (読めない形)" "$(detail)"
fi
run claude-account audit extra
if [[ $(rc) == 2 ]]; then ok "audit は引数を取らない (2)"; else ng "audit の引数" "$(detail)"; fi
audit_setup 'last year'
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
r1=$(row alt)
audit_setup '2026-01-01'
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ ${r1} == '| alt | alt | - | ローカル | 600 | - | - | 回す |' && $(row alt) == '| alt | alt | - | ローカル | 600 | - | - | 回す |' ]] \
  && grep -Fq -- '- alt: 回す — 入れた時刻の控えが読めない' "${work}/out"; then
  ok "audit: 控えの時刻は ISO 8601 の秒まで (Z か ±hh:mm) だけを読み、ほかの形 (last year・時差の無い日付) は読めないとして回す"
else
  ng "audit (控えの時刻の形)" "$(detail)"
fi
audit_setup
printf '{"accounts":{"alt":{"label":"alt"}}}\n' >"${decl}"
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if [[ $(rc) == 2 ]] && grep -Fq '宣言' "${work}/err"; then
  ok "audit: 宣言の item のキーが無ければ読めない形で 2 (Windows と同じ)"
else
  ng "audit (item のキーなし)" "$(detail)"
fi
audit_setup
printf '{"accounts":{"personal":{"item":null,"label":"personal"}}}\n' >"${decl}"
printf 'CLAUDE_CODE_OAUTH_TOKEN=dummy-pe-1\n' >"${home}/.config/claude-accounts/personal.env"
chmod 600 "${home}/.config/claude-accounts/personal.env"
CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
if grep -Fq -- '- personal: 直す — 既定のアカウント (subscription。dotfiles が作る) で、token を置かない' "${work}/out" \
  && ! grep -Fq 'claude-account remove personal' "${work}/out"; then
  ok "audit: 既定のアカウントを宣言したら直す (宣言から外すか別の名前で add。打っても通らない remove を出さない)"
else
  ng "audit (既定のアカウントの宣言)" "$(detail)"
fi
reset_home
mkdir -p "${home}/.local/state/claude-accounts"
printf 'not json\n' >"${times}"
run claude-account add token2 --mode token
run claude-account remove token2 --purge
if [[ $(rc) == 0 ]] && grep -Fq '入れた時刻の控え' "${work}/err" && grep -Fq 'token2 を外せません' "${work}/err"; then
  ok "remove --purge は控えが読めない形なら外せないと出し、0 で終わる (Windows と同じ)"
else
  ng "remove --purge (読めない控え)" "$(detail)"
fi

# --- 素の claude の wrapper (bareToken の package)
if [[ -n ${pkg_bare} ]]; then
  ln -sfn "${pkg_bare}/bin/claude-account" "${linkbin}/claude-account"
  ln -sfn "${pkg_bare}/bin/claude-account" "${linkbin}/claude-personal"
  ln -sfn "${pkg_bare}/bin/claude-account" "${linkbin}/claude"
  bare_file="${home}/.config/claude-accounts/default.env"
  reset_bare() {
    reset_home
    mkdir -p "${home}/.local/share/claude-account/bin"
    ln -s "${pkg_bare}/bin/claude-account" "${home}/.local/share/claude-account/bin/claude"
  }
  put_bare() { # $1: 中身、$2: 権限
    mkdir -p "${home}/.config/claude-accounts"
    printf '%s' "$1" >"${bare_file}"
    chmod "$2" "${bare_file}"
  }
  reset_bare
  RUN_NO_CONFIG_DIR=1 run claude -p hi
  if [[ $(rc) == 1 && ! -e ${home}/claude.log ]] && grep -Fq 'claude-account set-token default' "${work}/err" \
    && grep -Fq 'ブラウザのある端末で claude setup-token' "${work}/err" && no_values; then
    ok "wrapper: token が無ければ claude を起こさず 1 で、置き方 (ブラウザのある端末・set-token default) を出す"
  else
    ng "wrapper (token なし)" "$(detail)"
  fi
  put_bare 'CLAUDE_CODE_OAUTH_TOKEN=dummy-bare-1
' 600
  RUN_NO_CONFIG_DIR=1 FAKE_CLAUDE_EXIT=3 run claude -p hi
  if [[ $(rc) == 3 ]] && grep -Fxq 'oauth=dummy-bare-1' "${home}/claude.log" && grep -Fxq 'dir=<unset>' "${home}/claude.log" \
    && grep -Fxq 'key=<unset>' "${home}/claude.log" && grep -Fxq 'auth=<unset>' "${home}/claude.log" \
    && grep -Fxq 'arg=-p' "${home}/claude.log" && grep -Fxq 'arg=hi' "${home}/claude.log" && no_values; then
    ok "wrapper: CLAUDE_CONFIG_DIR を付けずに起こすと、default.env の token を渡し (CLAUDE_CONFIG_DIR は付けない。API キーは外す)、引数と終了コードを渡す"
  else
    ng "wrapper (token)" "$(detail)"
  fi
  run claude -p hi
  if [[ $(rc) == 0 ]] && grep -Fxq 'dir=/somewhere/else' "${home}/claude.log" && grep -Fxq 'oauth=dummy-inherited-oauth' "${home}/claude.log" \
    && grep -Fxq 'key=dummy-inherited-key' "${home}/claude.log"; then
    ok "wrapper: CLAUDE_CONFIG_DIR を付けて起こすと、env に手を出さずに本物の claude を起こす"
  else
    ng "wrapper (CLAUDE_CONFIG_DIR あり)" "$(detail)"
  fi
  RUN_NO_CONFIG_DIR=1 RUN_NO_FAKE_CLAUDE=1 run claude -p hi
  if [[ $(rc) == 127 ]] && grep -Fq 'claude: claude が見つかりません' "${work}/err"; then
    ok "wrapper: PATH に自分しか claude が無ければ 127 (自分を起こし直さない)"
  else
    ng "wrapper (本物の claude なし)" "$(detail)"
  fi
  put_bare 'CLAUDE_CODE_OAUTH_TOKEN=dummy-bare-1
' 644
  RUN_NO_CONFIG_DIR=1 run claude
  if [[ $(rc) == 1 && ! -e ${home}/claude.log ]] && grep -Fq 'chmod 600' "${work}/err" && no_values; then
    ok "wrapper: default.env の権限が 644 なら 1 (chmod 600 を出す)"
  else
    ng "wrapper (644)" "$(detail)"
  fi
  put_bare 'CLAUDE_CODE_OAUTH_TOKEN=op://vault/item/field
' 644
  RUN_NO_CONFIG_DIR=1 run claude -p hi
  if [[ $(rc) == 0 && $(grep -c . "${home}/op.log") == 1 ]] && grep -Fxq 'oauth=dummy-op-value' "${home}/claude.log" \
    && grep -Fxq 'dir=<unset>' "${home}/claude.log" && no_values; then
    ok "wrapper: default.env が op の参照なら op を 1 回呼び、claude に値が届く"
  else
    ng "wrapper (op)" "$(detail)
--- op.log
$(cat "${home}/op.log" 2>/dev/null)"
  fi
  FAKE_OP_VALUE='' RUN_NO_CONFIG_DIR=1 run claude
  if [[ $(rc) == 70 && ! -e ${home}/claude.log ]] && grep -Fq 'claude-account set-token default' "${work}/err"; then
    ok "wrapper: 1Password から読んだ値が空なら 70 で、set-token default を出す"
  else
    ng "wrapper (op の空)" "$(detail)"
  fi
  # check・set-token・list・launcher
  reset_bare
  run claude-account check default
  r1=$(rc)
  cp "${work}/err" "${work}/err1"
  put_bare 'CLAUDE_CODE_OAUTH_TOKEN=dummy-bare-1
' 600
  run claude-account check default
  r2=$(rc)
  cp "${work}/out" "${work}/out2"
  rm -f "${home}/.local/share/claude-account/bin/claude"
  run claude-account check default
  if [[ ${r1} == 1 && ${r2} == 0 && $(rc) == 1 ]] && grep -Fq 'claude-account set-token default' "${work}/err1" \
    && grep -Fxq 'claude: token (ローカル)' "${work}/out2" && grep -Fq 'wrapper' "${work}/err" && no_values; then
    ok "check default は token のファイル (無い 1・ある 0) と wrapper の link (無い 1) を見る"
  else
    ng "check default (宣言あり ${r1}/${r2})" "$(detail)"
  fi
  reset_bare
  CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' STDIN_TEXT=$'sk-ant-oat01-dummy-bare-2\n' run claude-account set-token default
  if [[ $(rc) == 0 && $(stat -c %a "${bare_file}") == 600 ]] && grep -Fxq 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-dummy-bare-2' "${bare_file}" \
    && grep -Fq '# claude (素の claude) の token' "${bare_file}" && [[ $(jq -r '.default.set_at' "${times}") == '2026-11-28T21:00:00+09:00' ]] \
    && grep -Fq 'claude (素の claude) で起こせます' "${work}/out" && no_values; then
    ok "set-token default は default.env に権限 600 で書き、入れた時刻を控える"
  else
    ng "set-token default" "$(detail)"
  fi
  run claude-account list
  if [[ $(rc) == 0 ]] && grep -Eq '^default +token +素の claude +token \(ローカル\)' "${work}/out"; then
    ok "list は宣言のあるホストの default を token として出す"
  else
    ng "list の default (宣言あり)" "$(detail)"
  fi
  mkdir -p "${home}/.claude-personal"
  ln -s "${home}/.claude/settings.json" "${home}/.claude-personal/settings.json"
  run claude-personal -p hi
  if [[ $(rc) == 0 ]] && grep -Fxq "dir=${home}/.claude-personal" "${home}/claude.log" && grep -Fxq 'oauth=<unset>' "${home}/claude.log"; then
    ok "claude-<名前> の launcher は、PATH の先の wrapper を飛ばして本物の claude を起こす"
  else
    ng "launcher と wrapper" "$(detail)"
  fi
  # audit: 宣言した default
  reset_bare
  printf '{"accounts":{"default":{"item":null,"label":"main"}}}\n' >"${decl}"
  CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
  r1=$(rc)
  cp "${work}/out" "${work}/out1"
  put_bare 'CLAUDE_CODE_OAUTH_TOKEN=dummy-bare-1
' 600
  mkdir -p "${home}/.local/state/claude-accounts"
  printf '{"default":{"set_at":"2026-11-27T21:00:00+09:00"}}\n' >"${times}"
  CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
  if [[ ${r1} == 1 ]] && grep -Fxq '| default (素の claude) | main | - | 無い | - | - | - | 入れる |' "${work}/out1" \
    && grep -Fq -- '- default: 入れる — token が無い (ブラウザのある端末で claude setup-token を打ち、このホストで claude-account set-token default で入れる)' "${work}/out1" \
    && [[ $(rc) == 0 ]] && grep -Fxq '| default (素の claude) | main | - | ローカル | 600 | 2026-11-27 21:00 | 1 | ok |' "${work}/out" \
    && grep -Fxq '判定: ok 1・回す 0・入れる 0・直す 0・宣言漏れ 0' "${work}/out" && no_values; then
    ok "audit は宣言した default を素の claude として並べる (token が無ければ入れる、入れて控えがあれば ok で 0)"
  else
    ng "audit (default)" "$(detail)
--- 1 回目
$(cat "${work}/out1")"
  fi
  printf '{"accounts":{"default":{"item":null,"label":"shared"},"alt":{"item":null,"label":"shared"}}}\n' >"${decl}"
  printf '{"version":1,"accounts":{"alt":{"mode":"token"}}}\n' >"${home}/.config/claude-accounts/accounts.json"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=dummy-alt-1\n' >"${home}/.config/claude-accounts/alt.env"
  chmod 600 "${home}/.config/claude-accounts/alt.env"
  CLAUDE_ACCOUNT_NOW='2026-11-28T21:00:00+09:00' run claude-account audit
  if grep -Fxq '同じ token (呼び名 shared) を置いたアカウント: default・alt (回すときは、どれも貼り直す)' "${work}/out"; then
    ok "audit は同じ呼び名のアカウントを並べる"
  else
    ng "audit (同じ呼び名)" "$(detail)"
  fi
  ln -sfn "${pkg}/bin/claude-account" "${linkbin}/claude-account"
  ln -sfn "${pkg}/bin/claude-account" "${linkbin}/claude-personal"
  rm -f "${linkbin}/claude"
fi

echo
echo "pass=${pass} fail=${fail}"
((fail == 0))
