#!/usr/bin/env bash
# shellcheck shell=bash
#
# WSL の op (1Password CLI)。呼ぶ理由 (--reason) を必須にし、呼び出しごとに新しい powershell.exe (Windows PowerShell 5.1) を
# 挟んで op.exe を起こす。nix/pkgs/pjp-op が bin/op として包み、dotfiles.wsl.enable と dotfiles.onePassword.enable が両方
# true のマシンの PATH に入る (home/modules/op-reason.nix)。使い方は nix/README.md「WSL の op を理由つきで呼ぶ」。
#
#   op --reason "<なぜ op を呼ぶか>" <op の引数…>
#
# ## なぜ挟むのか
#
# 1Password のデスクトップアプリの CLI の承認は、op.exe を起こしたプロセスの PID に付く。WSL から直に op.exe を起こすと、
# 親はどの pane でも同じ wsl.exe (herdr の server の WSL_INTEROP) なので、1 回の許可が後の呼び出しにも、ほかの pane にも
# 効く。呼び出しごとの powershell.exe の子にすると承認はその powershell に付き、終われば launcher (launcher.ps1) が閉じる。
# 承認の画面はどの呼び出しでも「Allow wslhost」としか出ないので、launcher は呼び手・理由・コマンドの窓を同時に出す。
#
# ## 流れ
#
#   1. 自分の引数を読む。-- より前の最初の --reason X / --reason=X を外し、残りを op に渡す
#   2. 呼び手を集める (proc の祖先の claude・herdr の workspace と pane・cwd と git の repo・branch)
#   3. mode を決める。理由があれば desktop で、OP_SERVICE_ACCOUNT_TOKEN か OP_CONNECT_HOST + OP_CONNECT_TOKEN があれば
#      service。理由が無くても --version・--help など (is_help) は help (窓なし)。ほかは 2 で断る
#   4. lock (flock。上限 PJP_OP_LOCK_WAIT 秒、既定 180) を取り、窓と 1Password の画面を 1 対 1 にする
#   5. 共有の承認の見張り: WSL から直に op.exe whoami を打ち、通れば (どの pane からも使える承認がある) op.exe signout で
#      消して知らせる。承認が無いときの whoami は画面を出さない
#   6. ログに start を書き、payload を組んで powershell.exe -EncodedCommand <起動の式> を起こす (launcher の本体は env の
#      PJP_OP_SCRIPT で渡す。本体を -EncodedCommand にすると Windows の command line の上限 32767 字を超える)。stdin・stdout は
#      継ぎ、stderr は op のものをそのまま流しながら写しを取る (結果の見分けにだけ使い、ログには書かない)
#   7. launcher の status と op の終了コード・stderr の写しから結果を決め、もう一度見張り、ログに end を書く
#   8. op の終了コードで終わる
#
# 設計は dotfiles-private の docs/superpowers/specs/2026-11-07-op-wrapper-reason-design.md。payload と status の形は
# launcher.ps1 の頭のコメント。
#
# ## 終了コード
#
#   op の終了コード・2 = 理由が無い・空・75 = ほかの op の承認待ちが上限を超えた・127 = op.exe・powershell.exe・wslpath・
#   launcher が無い・129/130/143 = HUP/INT/TERM で止めた (launcher は止めない。承認はそちらが閉じる)
#
# ## ログ
#
# ${XDG_STATE_HOME:-~/.local/state}/pjp-op/log.jsonl に 1 行 1 record (start・end・refused・shared-approval)。op の出力と
# token は書かず、引数の秘密の値は伏せる (mask_args)。1 MiB を超えたら log.1.jsonl へ回す。見るのは pjp-op-log。
#
# ## テストのための口 (nix/tests/pjp-op.test.sh)
#
#   PJP_OP_LAUNCHER     launcher の dir。script.b64 (本体の UTF-8 の base64) と command.b64 (起動の式の UTF-16LE の base64)。
#                       Nix の包みが入れる (pkgs/pjp-op/default.nix)
#   PJP_OP_EXE          op.exe (既定は PATH の op.exe)
#   PJP_OP_POWERSHELL   powershell.exe
#   PJP_OP_LOCK_WAIT    lock を待つ秒 (既定 180)
#   PJP_OP_PROC         祖先をたどる proc の根 (既定 /proc)。PJP_OP_PROC_START はたどり始める pid (既定 $$)

set -u -o pipefail
umask 077

state_dir=${XDG_STATE_HOME:-${HOME}/.local/state}/pjp-op
log_file=${state_dir}/log.jsonl
current_file=${state_dir}/current.json
log_max=1048576
lock_wait=${PJP_OP_LOCK_WAIT:-180}
ps_cmd=${PJP_OP_POWERSHELL:-powershell.exe}
# op の stderr の文言 (大文字小文字は問わない)。どちらも当たらない 0 以外は failed
deny_pattern='authorization prompt dismissed'
timeout_pattern='authorization timeout|timed out'

say() {
  local line
  for line in "$@"; do
    printf 'op (pjp-op): %s\n' "${line}" >&2
  done
}

usage() {
  cat >&2 <<'EOS'
使い方: op --reason "<なぜ op を呼ぶか>" <op の引数…>
  WSL の op は、呼ぶ理由を必須にした wrapper です (dotfiles の pjp-op)。理由は 1Password の承認の画面と一緒に出る窓と、
  記録 (pjp-op-log) に残ります。何のために何を読む・書くかを 1 文で書いてください。
  例: op --reason "infra-v2 の VM を作るのに Proxmox の API の token を読む" read "op://Private/proxmox/token"
  理由なしで通るのは --version と help (--help・-h・help) だけです。
EOS
}

# clip <文> <字数>: 字数 (文字) を超えたら切って … を付ける
clip() {
  local LC_ALL=C.UTF-8 s=$1 n=$2
  if ((${#s} > n)); then
    printf '%s…' "${s:0:n}"
  else
    printf '%s' "${s}"
  fi
}

# normalize <文>: 制御文字 (改行・タブも) を空白にし、続く空白を 1 つに畳んで前後を外す
normalize() {
  printf '%s' "$1" | tr '\000-\037\177' ' ' | sed -E 's/ +/ /g; s/^ //; s/ $//'
}

tilde() {
  if [[ $1 == "${HOME}" || $1 == "${HOME}"/* ]]; then
    printf '~%s' "${1#"${HOME}"}"
  else
    printf '%s' "$1"
  fi
}

now() {
  read -r now_epoch now_iso < <(date '+%s %Y-%m-%dT%H:%M:%S%:z')
}

# --- 引数

reason=""
have_reason=0
args=()
seen_dashdash=0
while (($# > 0)); do
  if ((seen_dashdash == 0 && have_reason == 0)); then
    case $1 in
      --reason)
        have_reason=1
        reason=${2-}
        shift
        (($# == 0)) || shift
        continue
        ;;
      --reason=*)
        have_reason=1
        reason=${1#--reason=}
        shift
        continue
        ;;
    esac
  fi
  [[ $1 != -- ]] || seen_dashdash=1
  args+=("$1")
  shift
done
if ((have_reason)); then
  reason=$(normalize "${reason}")
fi

# is_help: 理由なしで通す呼び出し (承認の要らない --version・help)。値の --help (--title --help) にも当たるが、help の mode も
# 呼び出しごとの powershell を通り、窓を出さないので、出た承認の画面は「窓の無い承認は拒否」で断れる
is_help() {
  local a
  ((${#args[@]} > 0)) || return 0
  case ${args[0]} in
    --version | -v | --help | -h | help) return 0 ;;
  esac
  for a in "${args[@]}"; do
    case ${a} in
      --) return 1 ;;
      --help | -h) return 0 ;;
    esac
  done
  return 1
}

# mask_args <引数>…: ログ・窓・通知に出す形を masked に入れる。--session と --secret-key の値、- で始まらない name=value の
# 値 (op item create の password=… など) を *** にする。op:// の参照はそのまま
mask_args() {
  local a next=0
  masked=()
  for a in "$@"; do
    if ((next)); then
      masked+=('***')
      next=0
      continue
    fi
    case ${a} in
      --session | --secret-key)
        masked+=("${a}")
        next=1
        ;;
      --session=* | --secret-key=*) masked+=("${a%%=*}=***") ;;
      -* | op://*) masked+=("${a}") ;;
      *=*) masked+=("${a%%=*}=***") ;;
      *) masked+=("${a}") ;;
    esac
  done
}

# show_cmd <引数>…: 見せるためのコマンドの形 (op から始める)。記号の無い語はそのまま、ほかは " で囲む
show_cmd() {
  local out=op a
  for a in "$@"; do
    a=${a//[$'\n\r\t']/ }
    if [[ ${a} =~ ^[A-Za-z0-9_./:=@%+,*?-]+$ ]]; then
      out+=" ${a}"
    else
      a=${a//\\/\\\\}
      a=${a//\"/\\\"}
      out+=" \"${a}\""
    fi
  done
  printf '%s' "${out}"
}

mask_args "${args[@]}"
cmd_display=$(show_cmd "${masked[@]}")

# --- 呼び手

# find_claude: proc の祖先に comm が claude のプロセスがあれば、その pid を出す
find_claude() {
  local root=${PJP_OP_PROC:-/proc} pid=${PJP_OP_PROC_START:-$$} stat ppid i
  for ((i = 0; i < 64; i++)); do
    [[ -r ${root}/${pid}/stat ]] || return 1
    stat=$(<"${root}/${pid}/stat")
    # comm は括弧の中に空白や括弧を含みうるので、最後の ") " の後ろから読む (状態・親の pid の順)
    ppid=${stat##*) }
    ppid=${ppid#* }
    ppid=${ppid%% *}
    [[ ${ppid} =~ ^[0-9]+$ ]] || return 1
    ((ppid > 1)) || return 1
    [[ -r ${root}/${ppid}/comm ]] || return 1
    if [[ $(<"${root}/${ppid}/comm") == claude ]]; then
      printf '%s' "${ppid}"
      return 0
    fi
    pid=${ppid}
  done
  return 1
}

claude_pid=$(find_claude) || claude_pid=""
if [[ -n ${claude_pid} ]]; then
  caller_type=claude
  caller_desc="Claude Code (pid ${claude_pid})"
  caller_short="Claude Code"
else
  caller_type=human
  caller_desc="人 (端末)"
  caller_short="人"
fi

in_herdr=false
herdr_label=""
if [[ ${HERDR_ENV:-} == 1 ]]; then
  in_herdr=true
  if [[ -n ${HERDR_WORKSPACE_ID:-} ]] && command -v herdr &>/dev/null; then
    if got=$(timeout 2 herdr workspace get "${HERDR_WORKSPACE_ID}" </dev/null 2>/dev/null); then
      herdr_label=$(jq -r '.result.workspace.label // empty' <<<"${got}" 2>/dev/null) || herdr_label=""
    fi
  fi
  [[ -z ${herdr_label} ]] || caller_short+=" · ${herdr_label}"
fi

repo=""
branch=""
if command -v git &>/dev/null && top=$(timeout 2 git -C "${PWD}" rev-parse --show-toplevel 2>/dev/null); then
  url=$(timeout 2 git -C "${PWD}" remote get-url origin 2>/dev/null) || url=""
  if [[ -n ${url} ]]; then
    url=${url%/}
    url=${url%.git}
    owner=${url%/*}
    owner=${owner##*[:/]}
    repo=${owner:+${owner}/}${url##*/}
  else
    repo=${top##*/}
  fi
  branch=$(timeout 2 git -C "${PWD}" branch --show-current 2>/dev/null) || branch=""
  if [[ -z ${branch} ]]; then
    branch="(detached $(timeout 2 git -C "${PWD}" rev-parse --short HEAD 2>/dev/null))"
  fi
fi
if [[ -n ${repo} ]]; then
  place_desc="${repo} (${branch}) · $(tilde "${PWD}")"
else
  place_desc=$(tilde "${PWD}")
fi

caller_json=$(jq -cn --arg type "${caller_type}" --arg pid "${claude_pid}" --argjson in_herdr "${in_herdr}" \
  --arg ws "${HERDR_WORKSPACE_ID:-}" --arg label "${herdr_label}" --arg pane "${HERDR_PANE_ID:-}" \
  --arg cwd "${PWD}" --arg repo "${repo}" --arg branch "${branch}" \
  '{type: $type, claude_pid: (if $pid == "" then null else ($pid | tonumber) end),
    herdr: (if $in_herdr then {workspace: $ws, label: $label, pane: $pane} else null end),
    cwd: $cwd, repo: (if $repo == "" then null else $repo end), branch: (if $branch == "" then null else $branch end)}')
session_json=$(jq -cn --arg s "${CLAUDE_CODE_SESSION_ID:-}" 'if $s == "" then null else $s end')
# --args の後ろでも - で始まる語は jq の option と読まれるので、-- で区切る (jq 1.8.2 で確かめた)
masked_json=$(jq -cn '$ARGS.positional' --args -- "${masked[@]}")
id="$(date '+%Y%m%dT%H%M%S')-$$-${RANDOM}"

# --- ログ

log_append() {
  mkdir -p "${state_dir}" 2>/dev/null || return 0
  if [[ -f ${log_file} ]] && (($(stat -c %s "${log_file}" 2>/dev/null || echo 0) >= log_max)); then
    mv -f "${log_file}" "${state_dir}/log.1.jsonl" 2>/dev/null
  fi
  printf '%s\n' "$1" >>"${log_file}" 2>/dev/null || true
}

# refuse <why> <終了コード> <stderr の行>…: 断りをログに書き、stderr に出して終わる
refuse() {
  local why=$1 code=$2
  shift 2
  now
  log_append "$(jq -cn --arg id "${id}" --arg time "${now_iso}" --argjson epoch "${now_epoch}" --argjson session "${session_json}" \
    --arg why "${why}" --argjson caller "${caller_json}" --arg reason "$(clip "${reason}" 500)" --argjson args "${masked_json}" \
    '{v: 1, id: $id, event: "refused", time: $time, epoch: $epoch, session: $session, why: $why, caller: $caller,
      reason: $reason, args: $args}')"
  say "$@"
  exit "${code}"
}

# --- mode

kind=desktop
mode=desktop
if ((have_reason)); then
  if [[ -z ${reason} ]]; then
    usage
    refuse no-reason 2 "理由 (--reason) が空です。なぜ op を呼ぶかを 1 文で書いてください。"
  fi
  if [[ -n ${OP_SERVICE_ACCOUNT_TOKEN:-} ]]; then
    mode=service
    kind=service-account
  elif [[ -n ${OP_CONNECT_HOST:-} && -n ${OP_CONNECT_TOKEN:-} ]]; then
    mode=service
    kind=connect
  fi
elif is_help; then
  mode=help
  kind=help
else
  usage
  refuse no-reason 2 "理由 (--reason) がありません。人が打つときも要ります。"
fi

# --- 道具

op_exe=${PJP_OP_EXE:-$(command -v op.exe || true)}
if [[ -z ${op_exe} || ! -f ${op_exe} ]]; then
  refuse no-op-exe 127 "op.exe が見つかりません${op_exe:+ (${op_exe})}。Windows に 1Password CLI を入れ、WSL の PATH に Windows の PATH が入っているかを確かめてください。"
fi
if ! command -v "${ps_cmd}" &>/dev/null; then
  refuse no-powershell 127 "${ps_cmd} が見つかりません (WSL の PATH に Windows の PATH が入っていないかもしれません)。"
fi
if ! command -v wslpath &>/dev/null; then
  refuse no-wslpath 127 "wslpath が見つかりません (WSL の外では使えません)。"
fi
if [[ ! -s ${PJP_OP_LAUNCHER:-}/command.b64 || ! -s ${PJP_OP_LAUNCHER:-}/script.b64 ]]; then
  refuse no-launcher 127 "launcher (PJP_OP_LAUNCHER) が見つかりません (dotfiles の pjp-op の包みの誤り)。"
fi
launcher_script=$(<"${PJP_OP_LAUNCHER}/script.b64")
ps_args=(-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand "$(<"${PJP_OP_LAUNCHER}/command.b64")")

# wslenv_plus <項目>…: 呼び手の WSLENV の後ろに項目を足した値 (末尾の : は外す)
wslenv_plus() {
  local value=${WSLENV:-} item
  value=${value%:}
  for item in "$@"; do
    value+=${value:+:}${item}
  done
  printf '%s' "${value}"
}

# --- lock

mkdir -p "${state_dir}" && chmod 700 "${state_dir}" 2>/dev/null
exec {lock_fd}>>"${state_dir}/lock"
if ! flock -n "${lock_fd}"; then
  if [[ -t 2 ]]; then
    say "ほかの op の承認待ちが終わるのを待っています (最大 ${lock_wait} 秒)。"
  fi
  if ! flock -w "${lock_wait}" "${lock_fd}"; then
    holder=$(jq -r '"\(.time) \(.caller) 理由「\(.reason)」 \(.command)"' "${current_file}" 2>/dev/null) || holder=""
    refuse lock-timeout 75 "ほかの op の承認待ちが ${lock_wait} 秒たっても終わらないので、打たずに終えます。" \
      "待たせている呼び出し: ${holder:-(分からない)}" \
      "その承認の画面に応えてから (窓の出ていない画面なら拒否してから)、打ち直してください。"
  fi
fi

run_dir=${state_dir}/run/${id}
wrote_current=0
started=""
# shellcheck disable=SC2329 # trap から呼ぶ
cleanup() {
  rm -rf "${run_dir}" 2>/dev/null
  if ((wrote_current)); then
    rm -f "${current_file}" 2>/dev/null
  fi
}
trap cleanup EXIT

if [[ ${mode} == help ]]; then
  current_reason="(理由なし: help)"
else
  current_reason=$(clip "${reason}" 100)
fi
jq -cn --arg time "$(date '+%H:%M:%S')" --arg caller "${caller_short}" --arg reason "${current_reason}" \
  --arg command "$(clip "${cmd_display}" 100)" '{time: $time, caller: $caller, reason: $reason, command: $command}' \
  >"${current_file}" 2>/dev/null && wrote_current=1

# --- 共有の承認の見張り

# watch_run <op.exe の引数>…: 見張りの op.exe を起こす。token・Connect の env と、WSLENV の OP_ の項目を外す
watch_run() {
  local value="" item
  local -a items=()
  IFS=: read -r -a items <<<"${WSLENV:-}"
  for item in "${items[@]}"; do
    if [[ -n ${item} && ${item} != OP_* ]]; then
      value+=${value:+:}${item}
    fi
  done
  env -u OP_SERVICE_ACCOUNT_TOKEN -u OP_CONNECT_HOST -u OP_CONNECT_TOKEN WSLENV="${value}" \
    timeout 30 "${op_exe}" "$@" </dev/null >/dev/null 2>&1 {lock_fd}>&-
}

# notify_shared <start|end> <true|false>: 共有の承認を消した (消せなかった) ことを、Windows の通知と herdr の通知で知らせる。
# Windows の通知は launcher の notify を裏で起こし、待たない
notify_shared() {
  local when_desc="op を打つ前" title body payload
  [[ $1 == start ]] || when_desc="op を打った後"
  if [[ $2 == true ]]; then
    title="共有の 1Password CLI の承認を消しました"
    body="WSL のどの pane からも使える承認が残っていたので、op signout で消しました (${when_desc})。窓の出ていない承認の画面を許可したか、道具が op.exe を直に打ったのかもしれません。"
  else
    title="共有の 1Password CLI の承認を消せませんでした"
    body="WSL のどの pane からも使える承認が残っています (${when_desc})。WSL で op.exe signout を打つか、1Password をロックしてください。"
  fi
  payload=$(jq -cn -a --arg t "${title}" --arg b "${body}" --arg time "$(date '+%H:%M:%S')" \
    '{mode: "notify", ui: {title: $t, lines: [["時刻", $time], ["内容", $b]], toast: [$t, $b]}}')
  (
    WSLENV=$(wslenv_plus PJP_OP_SCRIPT PJP_OP_PAYLOAD) PJP_OP_SCRIPT=${launcher_script} PJP_OP_PAYLOAD=${payload} \
      "${ps_cmd}" "${ps_args[@]}" </dev/null >/dev/null 2>&1 {lock_fd}>&- &
  )
  if [[ ${HERDR_ENV:-} == 1 ]] && command -v herdr &>/dev/null; then
    timeout 2 herdr notification show "🔑 ${title}" --body "${body}" --sound request </dev/null >/dev/null 2>&1 || true
  fi
}

# watch_shared <start|end>: WSL から直の whoami が通れば (共有の承認がある) signout で消す。watch_result に none・cleared・error
watch_shared() {
  local cleared=false
  if ! watch_run whoami; then
    watch_result=none
    return
  fi
  if watch_run signout && ! watch_run whoami; then
    cleared=true
  fi
  now
  log_append "$(jq -cn --arg id "${id}" --arg time "${now_iso}" --argjson epoch "${now_epoch}" --arg when "$1" \
    --argjson cleared "${cleared}" '{v: 1, id: $id, event: "shared-approval", time: $time, epoch: $epoch, when: $when, cleared: $cleared}')"
  notify_shared "$1" "${cleared}"
  if [[ ${cleared} == true ]]; then
    watch_result=cleared
  else
    watch_result=error
  fi
}

watch_shared start
watch_start=${watch_result}

# --- start

now
start_epoch=${now_epoch}
log_append "$(jq -cn --arg id "${id}" --arg time "${now_iso}" --argjson epoch "${now_epoch}" --argjson session "${session_json}" \
  --arg mode "${mode}" --arg kind "${kind}" --argjson caller "${caller_json}" --arg reason "$(clip "${reason}" 500)" \
  --argjson args "${masked_json}" \
  '{v: 1, id: $id, event: "start", time: $time, epoch: $epoch, session: $session, mode: $mode, kind: $kind, caller: $caller,
    reason: $reason, args: $args}')"
started=1

st_json=null
watch_end=""
result=""
op_rc=1

# write_end <result> <終了コード>
write_end() {
  local secs
  now
  secs=$((now_epoch - start_epoch))
  ((secs >= 0)) || secs=0
  log_append "$(jq -cn --arg id "${id}" --arg time "${now_iso}" --argjson epoch "${now_epoch}" --argjson session "${session_json}" \
    --arg result "$1" --argjson exit "$2" --argjson secs "${secs}" --argjson st "${st_json}" \
    --arg ws "${watch_start}" --arg we "${watch_end}" \
    '{v: 1, id: $id, event: "end", time: $time, epoch: $epoch, session: $session, result: $result, exit: $exit,
      seconds: $secs, window: ($st.window // null), toast: ($st.toast // null), others: ($st.others // null),
      signout: ($st.signout // null),
      watch: {start: (if $ws == "" then null else $ws end), end: (if $we == "" then null else $we end)}}')"
}

# 止められたら end に interrupted を書いて終わる。launcher は止めない (op が承認を待っていれば、終わった後に launcher が
# 承認を閉じる。lock の fd を継いでいるので、それまで次の呼び出しは待つ)
# shellcheck disable=SC2329 # trap から呼ぶ
on_signal() {
  trap - INT TERM HUP
  if [[ -n ${started} ]]; then
    write_end interrupted "$1"
  fi
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# --- launcher

mkdir -p "${run_dir}"
status_file=${run_dir}/status.json
err_copy=${run_dir}/stderr
err_fifo=${run_dir}/stderr.fifo
mkfifo "${err_fifo}"
status_win=$(wslpath -w "${status_file}")
op_win=$(wslpath -w "${op_exe}")

ui_json=null
if [[ ${mode} == desktop ]]; then
  herdr_desc=""
  if [[ ${in_herdr} == true ]]; then
    herdr_desc="workspace「${herdr_label:-?}」 · pane ${HERDR_PANE_ID:-?}"
  fi
  note=""
  if [[ ${watch_start} == cleared ]]; then
    note="打つ前に、WSL のどの pane からも使える承認が残っていたので消しました"
  fi
  ui_json=$(jq -cn --arg time "$(date -d "@${start_epoch}" '+%Y-%m-%d %H:%M:%S')" --arg caller "${caller_desc}" \
    --arg herdr "${herdr_desc}" --arg place "${place_desc}" --arg reason "$(clip "${reason}" 200)" \
    --arg cmd "$(clip "${cmd_display}" 300)" --arg note "${note}" \
    --arg toast1 "理由: $(clip "${reason}" 100)" --arg toast2 "${caller_short} · $(clip "${cmd_display}" 80)" \
    '{title: "1Password CLI の承認の依頼",
      lines: ([["時刻", $time], ["呼び手", $caller]]
        + (if $herdr == "" then [] else [["herdr", $herdr]] end)
        + [["場所", $place], ["理由", $reason], ["コマンド", $cmd]]
        + (if $note == "" then [] else [["注意", $note]] end)),
      footer: "この窓が出ていない 1Password の承認は拒否してください",
      others: "ほかにも op.exe が動いています (この窓の無いもの)。どれの承認か分からなければ拒否してください",
      toast: ["1Password CLI の承認の依頼", $toast1, $toast2]}')
fi

args64=()
for a in "${args[@]}"; do
  args64+=("$(printf '%s' "${a}" | base64 -w0)")
done
payload=$(jq -cn -a --arg mode "${mode}" --arg op "${op_win}" --arg status "${status_win}" --argjson ui "${ui_json}" \
  '{mode: $mode, op: $op, status: $status, args64: $ARGS.positional} + (if $ui == null then {} else {ui: $ui} end)' \
  --args -- "${args64[@]}")

# 裏で起こすコマンドの stdin は /dev/null になるので、呼び手の stdin を別の fd に写して渡す (exec に 2>/dev/null を付けると、
# それもシェル全体に効いて以後の stderr が消える)
exec {in_fd}<&0 || exec {in_fd}</dev/null
tee -a "${err_copy}" <"${err_fifo}" >&2 {lock_fd}>&- &
tee_pid=$!
case ${kind} in
  service-account)
    env OP_BIOMETRIC_UNLOCK_ENABLED=false PJP_OP_SCRIPT="${launcher_script}" PJP_OP_PAYLOAD="${payload}" \
      WSLENV="$(wslenv_plus PJP_OP_SCRIPT PJP_OP_PAYLOAD OP_SERVICE_ACCOUNT_TOKEN/w OP_BIOMETRIC_UNLOCK_ENABLED/w)" \
      "${ps_cmd}" "${ps_args[@]}" <&"${in_fd}" 2>"${err_fifo}" &
    ;;
  connect)
    env -u OP_SERVICE_ACCOUNT_TOKEN OP_BIOMETRIC_UNLOCK_ENABLED=false PJP_OP_SCRIPT="${launcher_script}" PJP_OP_PAYLOAD="${payload}" \
      WSLENV="$(wslenv_plus PJP_OP_SCRIPT PJP_OP_PAYLOAD OP_CONNECT_HOST/w OP_CONNECT_TOKEN/w OP_BIOMETRIC_UNLOCK_ENABLED/w)" \
      "${ps_cmd}" "${ps_args[@]}" <&"${in_fd}" 2>"${err_fifo}" &
    ;;
  *)
    env -u OP_SERVICE_ACCOUNT_TOKEN -u OP_CONNECT_HOST -u OP_CONNECT_TOKEN PJP_OP_SCRIPT="${launcher_script}" PJP_OP_PAYLOAD="${payload}" \
      WSLENV="$(wslenv_plus PJP_OP_SCRIPT PJP_OP_PAYLOAD)" \
      "${ps_cmd}" "${ps_args[@]}" <&"${in_fd}" 2>"${err_fifo}" &
    ;;
esac
ps_pid=$!
op_rc=0
wait "${ps_pid}" || op_rc=$?
wait "${tee_pid}" 2>/dev/null

# --- 結果

if [[ -s ${status_file} ]] && st=$(jq -c 'if type == "object" then . else error("not an object") end' "${status_file}" 2>/dev/null); then
  st_json=${st}
fi
if [[ $(jq -r '.started // false' <<<"${st_json}") != true ]]; then
  result=launcher-failed
elif ((op_rc == 0)); then
  if [[ ${mode} == desktop ]]; then
    result=approved
  else
    result=ok
  fi
elif grep -qiE "${deny_pattern}" "${err_copy}" 2>/dev/null; then
  result=denied
elif grep -qiE "${timeout_pattern}" "${err_copy}" 2>/dev/null; then
  result=timeout
else
  result=failed
fi

watch_shared end
watch_end=${watch_result}
write_end "${result}" "${op_rc}"
exit "${op_rc}"
