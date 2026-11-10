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
#   1. 自分の引数を読む。-- より前の最初の --reason X / --reason=X を外し、残りを op に渡す。op の引数が無ければ (--reason
#      だけのときも)、wrapper の使い方を stdout に出して 0 で終わる (powershell も op.exe も起こさず、記録にも書かない)
#   2. 呼び手を集める (proc の祖先の claude・herdr の workspace と pane・cwd と git の repo・branch)
#   3. mode を決める。理由があれば desktop で、OP_SERVICE_ACCOUNT_TOKEN か OP_CONNECT_HOST + OP_CONNECT_TOKEN があれば
#      service。理由が無くても --version・--help など (is_help) は help (窓なし)。ほかは 2 で断る
#   4. lock (flock。上限 PJP_OP_LOCK_WAIT 秒、既定 90) を取り、窓と 1Password の画面を 1 対 1 にする。op どうしのパイプでは、
#      lock の前か待つ間に stdin を読み切り、lock を持つ op がこの出力を待っていれば lock を待たずに打つ (下の「## stdin」)
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
#   op の終了コード・2 = 理由が無い・空・引数が長すぎる・75 = ほかの op の承認待ちが上限を超えた・127 = op.exe・
#   powershell.exe・wslpath・launcher が無い・129/130/143 = HUP/INT/TERM で止められた
#
# ## 止められたとき
#
# Claude の Bash の時間切れや端末の Ctrl+C は、wrapper と一緒に powershell.exe の relay も止め、Windows 側の powershell
# (launcher) も終わる。op が承認を待っていれば、窓は消えて 1Password の承認の画面だけが残る (窓の無い画面なので拒否する)。
# 許可してしまうと、その承認は終わった powershell に付いたまま閉じられず (WSL の op.exe signout では消えない)、1Password の
# 10 分の期限まで残るので、1Password をロックして消す。lock も離れるので、次の呼び出しの窓に「ほかにも op.exe が動いています」が
# 出る。止められる機会を減らすため、lock を待つ上限は Claude の Bash の既定の時間切れ (120 秒) より短い 90 秒にし、Claude の
# hook (files/claude/hooks/op-reason-guard.sh) は op を打つ Bash の timeout を長くするよう促す。止められた呼び出しは、start の
# 後なら end に interrupted、前 (lock を待つ間など) なら refused (interrupted) を書く (SIGKILL では書けない)。
#
# ## stdin
#
# 呼び手の stdin はそのまま op.exe に渡す。ただし op どうしのパイプ (op … | op …。間に jq などを挟んでもよい) では、受け手が
# lock を持ったまま送り手の出力を待ち、送り手は lock を待って止まる (送り手が先に lock を取っても、出力がパイプのバッファを超えると
# 送り手が書けずに止まり、lock を待つ受け手は読まない)。どちらが先に起き、先に lock を取っても止まらないよう、次の 2 つをする。
#
#   - 受け手: stdin のパイプを遡った先に op がいれば、lock を取る前に stdin を読み切って一時のファイルから渡す。lock を取る前に
#     見るほか、lock を待つ間も 1 秒ごとに見直す (送り手がまだ op.sh を exec していないうちに見ると見落とす)
#   - 送り手: lock を待つ間 1 秒ごとに、lock を持つ op (current.json の pid) が stdin のパイプを遡った先でこの op の出力を読んで
#     いないかを見る。読んでいれば、受け手は lock を持ったままこの出力を待っているので、lock を待たずに打つ。2 つの op.exe が同時に
#     動き、窓も 2 つ出るので、窓に「注意」の行を足し、記録の start の lock に skipped と書く。共有の承認の見張りは、lock を持つ受け手
#     が始まりと終わりに打つので、打たない (受け手の op.exe が動いている間に signout --all を打たない)
#
# パイプの書き手は、/proc の fd 1 が同じパイプのプロセス (-ef で比べる)。そのプロセスの bash が読む script (cmdline の 2 つ目) が
# この script と同じファイルなら op とみる。遡るのは pipe_depth 段まで。ほかのパイプ (ssh のように閉じないものもある) と
# socket (Claude の Bash の stdin) は読み切らない。
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
#   PJP_OP_LOCK_WAIT    lock を待つ秒 (既定 90)
#   PJP_OP_PROC         祖先をたどる proc の根 (既定 /proc)。PJP_OP_PROC_START はたどり始める pid (既定 $$)

set -u -o pipefail
umask 077

state_dir=${XDG_STATE_HOME:-${HOME}/.local/state}/pjp-op
log_file=${state_dir}/log.jsonl
current_file=${state_dir}/current.json
log_max=1048576
# lock を待つ上限 (秒。整数)。Claude の Bash の既定の時間切れ (120 秒) より短くし、止められる前に 75 で断る
lock_wait=${PJP_OP_LOCK_WAIT:-90}
[[ ${lock_wait} =~ ^[0-9]+$ ]] || lock_wait=90
ps_cmd=${PJP_OP_POWERSHELL:-powershell.exe}
# op の stderr の文言 (大文字小文字は問わない)。op は「[ERROR] <日時> <文>」の行で出す (op run の子のコマンドの
# 「Connection timed out」などに当てない)。どちらも当たらない 0 以外は failed
deny_pattern='^\[ERROR\] .*authorization prompt dismissed'
timeout_pattern='^\[ERROR\] .*authoriz.*(timeout|timed out)'

say() {
  local line
  for line in "$@"; do
    printf 'op (pjp-op): %s\n' "${line}" >&2
  done
}

# usage: 断るときに stderr へ出す短い使い方
usage() {
  cat >&2 <<'EOS'
使い方: op --reason "<なぜ op を呼ぶか>" <op の引数…>
  WSL の op は、呼ぶ理由を必須にした wrapper です (dotfiles の pjp-op)。理由は 1Password の承認の画面と一緒に出る窓と、
  記録 (pjp-op-log) に残ります。何のために何を読む・書くかを 1 文で書いてください。
  例: op --reason "infra-v2 の VM を作るのに Proxmox の API の token を読む" read "op://Private/proxmox/token"
  理由なしで通るのは --version と help (--help・-h・help) だけです。詳しい使い方は引数なしの op で出ます。
EOS
}

# usage_full: 引数なしの op が stdout へ出す使い方
usage_full() {
  cat <<'EOS'
使い方: op --reason "<なぜ op を呼ぶか>" <op の引数…>

WSL の op は、呼ぶ理由を必須にした 1Password CLI の wrapper です (dotfiles の pjp-op)。
呼び出しごとに新しい powershell.exe を挟んで op.exe を起こし、1Password の承認をその 1 回に
閉じます。理由は、承認の画面と一緒に出る窓と、記録 (pjp-op-log) に残ります。

理由 (--reason)
  何のために何を読む・書くかを 1 文で書きます。人が打つときも要り、無ければ 2 で断ります。
  --reason "<理由>" でも --reason=<理由> でもよく、op の引数のどこに置いてもかまいません
  (-- より後ろは op の引数です)。
  例: op --reason "infra-v2 の VM を作るのに Proxmox の API の token を読む" read "op://Private/proxmox/token"

理由なしで通るもの (承認の画面は出ません)
  op               この使い方 (op.exe は起こしません)
  op --version     op の版
  op --help        op 本体の使い方。コマンドごとは op <コマンド> --help

記録を見る
  pjp-op-log       直近 1 時間に、誰が何の理由で op を呼んだか (--since 1d・--all・--json)

呼び手と理由の窓が出ていない 1Password CLI の承認の画面は、拒否してください。
詳しくは dotfiles の nix/README.md「WSL の op を理由つきで呼ぶ」。
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

# op の引数が無ければ (--reason だけのときも)、wrapper の使い方を出して終わる。op.exe に渡すものが無いので、powershell も
# op.exe (見張りの whoami も) も起こさず、承認とかかわりが無いので記録にも書かない。op 本体の使い方は op --help で出る
if ((${#args[@]} == 0)); then
  usage_full
  exit 0
fi

# is_help: 理由なしで通す呼び出し (承認の要らない --version・help)。値の --help (--title --help) にも当たるが、help の mode も
# 呼び出しごとの powershell を通り、窓を出さないので、出た承認の画面は「窓の無い承認は拒否」で断れる
is_help() {
  local a
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
# 値 (op item create の password=… など) を *** にする。op:// の参照はそのまま。-- の後ろ (op run の子のコマンド) は、
# コマンドの名前と値の無い flag だけを見せる (-H "Authorization: Bearer …" のような値を出さない)
mask_args() {
  local a next=0 after=0 first=1
  masked=()
  for a in "$@"; do
    if ((after)); then
      if ((first)) || [[ ${a} =~ ^-[A-Za-z0-9-]+$ ]]; then
        masked+=("${a}")
      else
        masked+=('***')
      fi
      first=0
      continue
    fi
    if ((next)); then
      masked+=('***')
      next=0
      continue
    fi
    case ${a} in
      --)
        masked+=("${a}")
        after=1
        ;;
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

# log_append <JSON の 1 行>: 記録に足す。回すのと足すのを log.lock で 1 つずつにする (lock の外で書く refused と重なっても、
# 回した直後の行を失わない)
log_append() {
  mkdir -p "${state_dir}" 2>/dev/null || return 0
  {
    flock -w 5 9 || true
    if [[ -f ${log_file} ]] && (($(stat -c %s "${log_file}" 2>/dev/null || echo 0) >= log_max)); then
      mv -f "${log_file}" "${state_dir}/log.1.jsonl" 2>/dev/null
    fi
    printf '%s\n' "$1" >>"${log_file}" 2>/dev/null || true
  } 9>>"${state_dir}/log.lock"
}

# log_refused <why>: 断りを記録に書く
log_refused() {
  now
  log_append "$(jq -cn --arg id "${id}" --arg time "${now_iso}" --argjson epoch "${now_epoch}" --argjson session "${session_json}" \
    --arg why "$1" --argjson caller "${caller_json}" --arg reason "$(clip "${reason}" 500)" --argjson args "${masked_json}" \
    '{v: 1, id: $id, event: "refused", time: $time, epoch: $epoch, session: $session, why: $why, caller: $caller,
      reason: $reason, args: $args}')"
}

# refuse <why> <終了コード> <stderr の行>…: 断りを記録に書き、stderr に出して終わる
refuse() {
  local why=$1 code=$2
  shift 2
  log_refused "${why}"
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

# 引数は payload (env の PJP_OP_PAYLOAD) に 1 つずつ UTF-8 の base64 で載る。Windows の env の値は 32767 字までなので、
# 載らない長さは先に断る (launcher-failed にしない)
b64_len() {
  local LC_ALL=C
  printf '%s' $((4 * ((${#1} + 2) / 3)))
}
args_b64_len=0
for a in "${args[@]}"; do
  args_b64_len=$((args_b64_len + $(b64_len "${a}")))
done
if ((args_b64_len > 28000)); then
  refuse too-long 2 "op の引数が長すぎます (base64 で ${args_b64_len} 字。Windows の環境変数に載るのは 32767 字まで)。" \
    "長い値は op の --template やファイル (op document create <パス> など) で渡してください。"
fi

# --- 一時の置き場と、止められたとき

# 呼び出しの間だけ置くもの。status は Windows から書くので state の dir (\\wsl.localhost から届く) に、op の stderr の写し・
# stdin の写し・FIFO は、あれば tmpfs の XDG_RUNTIME_DIR に置く (秘密を disk に残さない)
run_dir=${state_dir}/run/${id}
if [[ -n ${XDG_RUNTIME_DIR:-} && -d ${XDG_RUNTIME_DIR} && -w ${XDG_RUNTIME_DIR} ]]; then
  tmp_root=${XDG_RUNTIME_DIR}/pjp-op
else
  tmp_root=${state_dir}/tmp
fi
tmp_dir=${tmp_root}/${id}
wrote_current=0
started=""
# shellcheck disable=SC2329 # trap から呼ぶ
cleanup() {
  rm -rf "${run_dir}" "${tmp_dir}" 2>/dev/null
  if ((wrote_current)); then
    rm -f "${current_file}" 2>/dev/null
  fi
}
trap cleanup EXIT

# 止められたら記録に書いて終わる (上の「止められたとき」)。start の後は end に interrupted、前は refused (interrupted)
# shellcheck disable=SC2329 # trap から呼ぶ
on_signal() {
  trap - INT TERM HUP
  if [[ -n ${started} ]]; then
    write_end interrupted "$1"
  else
    log_refused interrupted
  fi
  exit "$1"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

mkdir -p "${state_dir}" "${run_dir}" "${tmp_dir}" && chmod 700 "${state_dir}" "${tmp_root}" 2>/dev/null

# --- op どうしのパイプ (上の「## stdin」)

pipe_depth=4
me=${BASH_SOURCE[0]}
[[ ${me} == /* ]] || me=${PWD}/${me}

# 下の関数は subshell (process substitution・$(…)) を使わず、結果を配列で返す。while … done < <(…) は、ループの間この shell の
# fd 0 を process substitution のパイプに差し替えるので、その中から /proc/$$/fd/0 を見ると、stdin でなく自分の subshell (この
# script と同じ cmdline) が書くパイプを見てしまう

# writers_of <パス>…: どれかと同じパイプを fd 1 に持つプロセスの pid を writers に入れる。/proc/<pid>/fd/1 を -ef で比べる (stat は
# 同じパイプに同じ inode を返す)。リンク先の文字列 pipe:[<inode>] を find -lname に渡すと、[…] が glob の文字クラスになって当たらない
writers_of() {
  local fd t
  writers=()
  for fd in /proc/[0-9]*/fd/1; do
    for t in "$@"; do
      if [[ ${fd} -ef ${t} ]]; then
        fd=${fd#/proc/}
        writers+=("${fd%%/*}")
        break
      fi
    done
  done
}

# upstream_of <pid>: pid の stdin のパイプの書き手と、その書き手の stdin のパイプの書き手…を pipe_depth 段まで遡り、upstream に入れる
upstream_of() {
  local -a frontier=("$1") pipes=()
  local -A seen=()
  local i p w
  upstream=()
  for ((i = 0; i < pipe_depth; i++)); do
    pipes=()
    for p in "${frontier[@]}"; do
      [[ ! -p /proc/${p}/fd/0 ]] || pipes+=("/proc/${p}/fd/0")
    done
    ((${#pipes[@]} > 0)) || return 0
    writers_of "${pipes[@]}"
    frontier=()
    for w in "${writers[@]}"; do
      [[ -z ${seen[${w}]:-} ]] || continue
      seen[${w}]=1
      frontier+=("${w}")
      upstream+=("${w}")
    done
    ((${#frontier[@]} > 0)) || return 0
  done
}

# is_op <pid>: そのプロセスの bash が読む script (cmdline の 2 つ目。相対ならそのプロセスの cwd から) がこの script と同じファイルなら
# 0。cmdline は別の fd で読む (mapfile … <file でも fd 0 が差し替わり、ほかの op から stdin がパイプでなく見える)
is_op() {
  local -a argv=()
  local s cfd
  { exec {cfd}<"/proc/$1/cmdline"; } 2>/dev/null || return 1
  mapfile -d '' -t -u "${cfd}" argv
  exec {cfd}<&-
  ((${#argv[@]} >= 2)) || return 1
  s=${argv[1]}
  [[ ${s} == /* ]] || s=/proc/$1/cwd/${s}
  [[ ${s} -ef ${me} ]]
}

# op_upstream: stdin のパイプを遡った先に、ほかの op がいれば 0
op_upstream() {
  local pid
  [[ -p /proc/$$/fd/0 ]] || return 1
  upstream_of "$$"
  for pid in "${upstream[@]}"; do
    if [[ ${pid} != "$$" ]] && is_op "${pid}"; then
      return 0
    fi
  done
  return 1
}

# feeds_holder: lock を持つ op (current.json の pid) が、stdin のパイプを遡った先でこの op の出力を読んでいれば 0。holder_reason に
# その op の理由を入れる
holder_reason=""
feeds_holder() {
  local holder pid
  [[ -p /proc/$$/fd/1 ]] || return 1
  holder=$(jq -r '.pid // empty' "${current_file}" 2>/dev/null) || return 1
  [[ ${holder} =~ ^[0-9]+$ && ${holder} != "$$" ]] || return 1
  is_op "${holder}" || return 1
  upstream_of "${holder}"
  for pid in "${upstream[@]}"; do
    if [[ ${pid} == "$$" ]]; then
      holder_reason=$(jq -r '.reason // ""' "${current_file}" 2>/dev/null) || holder_reason=""
      return 0
    fi
  done
  return 1
}

# drain_stdin: stdin を閉じるまで読み、一時のファイルに写す (op.exe にはそこから渡す)
in_file=""
drain_stdin() {
  in_file=${tmp_dir}/stdin
  cat >"${in_file}"
}
if op_upstream; then
  drain_stdin
fi

# --- lock

# lock_mode: held = lock を持って打つ・skipped = lock を持つ op がこの出力を待っているので、lock を待たずに打つ
lock_mode=held
exec {lock_fd}>>"${state_dir}/lock"
if ! flock -n "${lock_fd}"; then
  if [[ -t 2 ]]; then
    say "ほかの op の承認待ちが終わるのを待っています (最大 ${lock_wait} 秒)。"
  fi
  # 1 秒ずつ待ち、その間にパイプの前と後ろを見直す。stdin を読み切ったら、そこから上限を数え直す (読み切る間は lock を待たない)
  deadline=$((SECONDS + lock_wait))
  while :; do
    if [[ -z ${in_file} ]] && op_upstream; then
      drain_stdin
      deadline=$((SECONDS + lock_wait))
    fi
    if feeds_holder; then
      lock_mode=skipped
      break
    fi
    if ((SECONDS >= deadline)); then
      holder=$(jq -r '"\(.time) \(.caller) 理由「\(.reason)」 \(.command)"' "${current_file}" 2>/dev/null) || holder=""
      refuse lock-timeout 75 "ほかの op の承認待ちが ${lock_wait} 秒たっても終わらないので、打たずに終えます。" \
        "待たせている呼び出し: ${holder:-(分からない)}" \
        "その承認の画面に応えてから (窓の出ていない画面なら拒否してから)、打ち直してください。"
    fi
    if flock -w 1 "${lock_fd}"; then
      break
    fi
  done
fi

# 前に SIGKILL などで止められた呼び出しの置き場を片付ける (1 時間より古いもの。lock を待つ呼び出しのものは新しい)
find "${state_dir}/run" "${tmp_root}" -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null

# lock を持つ呼び出しを current.json に書く (待たせている呼び出しの呼び手と理由・パイプの前の op が見る pid)。lock を待たずに
# 打つときは、lock を持つ op のものを残す
if [[ ${mode} == help ]]; then
  current_reason="(理由なし: help)"
else
  current_reason=$(clip "${reason}" 100)
fi
if [[ ${lock_mode} == held ]]; then
  jq -cn --arg time "$(date '+%H:%M:%S')" --arg caller "${caller_short}" --arg reason "${current_reason}" \
    --arg command "$(clip "${cmd_display}" 100)" --argjson pid "$$" \
    '{time: $time, caller: $caller, reason: $reason, command: $command, pid: $pid}' \
    >"${current_file}" 2>/dev/null && wrote_current=1
fi

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
    body="WSL のどの pane からも使える承認が残っていたので、op.exe signout --all で消しました (${when_desc})。窓の出ていない承認の画面を許可したか、道具が op.exe を直に打ったのかもしれません。"
  else
    title="共有の 1Password CLI の承認を消せませんでした"
    body="WSL のどの pane からも使える承認が残っています (${when_desc})。WSL で op.exe signout --all を打つか、1Password をロックしてください。"
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
  if watch_run signout --all && ! watch_run whoami; then
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

# lock を待たずに打つときは見張らない (lock を持つ op が始まりと終わりに見張る。上の「## stdin」)
watch_start=""
if [[ ${lock_mode} == held ]]; then
  watch_shared start
  watch_start=${watch_result}
fi

# --- start

now
start_epoch=${now_epoch}
log_append "$(jq -cn --arg id "${id}" --arg time "${now_iso}" --argjson epoch "${now_epoch}" --argjson session "${session_json}" \
  --arg mode "${mode}" --arg kind "${kind}" --arg lock "${lock_mode}" --argjson caller "${caller_json}" \
  --arg reason "$(clip "${reason}" 500)" --argjson args "${masked_json}" \
  '{v: 1, id: $id, event: "start", time: $time, epoch: $epoch, session: $session, mode: $mode, kind: $kind, lock: $lock,
    caller: $caller, reason: $reason, args: $args}')"
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

# --- launcher

status_file=${run_dir}/status.json
err_copy=${tmp_dir}/stderr
err_fifo=${tmp_dir}/stderr.fifo
mkfifo "${err_fifo}"
status_win=$(wslpath -w "${status_file}")
op_win=$(wslpath -w "${op_exe}")

ui_json=null
if [[ ${mode} == desktop ]]; then
  herdr_desc=""
  if [[ ${in_herdr} == true ]]; then
    herdr_desc="workspace「${herdr_label:-?}」 · pane ${HERDR_PANE_ID:-?}"
  fi
  notes=()
  if [[ ${watch_start} == cleared ]]; then
    notes+=("打つ前に、WSL のどの pane からも使える承認が残っていたので消しました")
  fi
  if [[ ${lock_mode} == skipped ]]; then
    notes+=("パイプの先の op (理由「$(clip "${holder_reason}" 60)」) が lock を持ったまま、この op の出力を待っています。lock を待たずに打つので、その op の窓も同時に出ています")
  fi
  notes_json=$(jq -cn '$ARGS.positional' --args -- "${notes[@]}")
  ui_json=$(jq -cn --arg time "$(date -d "@${start_epoch}" '+%Y-%m-%d %H:%M:%S')" --arg caller "${caller_desc}" \
    --arg herdr "${herdr_desc}" --arg place "${place_desc}" --arg reason "$(clip "${reason}" 200)" \
    --arg cmd "$(clip "${cmd_display}" 300)" --argjson notes "${notes_json}" \
    --arg toast1 "理由: $(clip "${reason}" 100)" --arg toast2 "${caller_short} · $(clip "${cmd_display}" 80)" \
    '{title: "1Password CLI の承認の依頼",
      lines: ([["時刻", $time], ["呼び手", $caller]]
        + (if $herdr == "" then [] else [["herdr", $herdr]] end)
        + [["場所", $place], ["理由", $reason], ["コマンド", $cmd]]
        + ($notes | map(["注意", .]))),
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

# 裏で起こすコマンドの stdin は /dev/null になるので、呼び手の stdin (か、読み切った写し) を別の fd に写して渡す。stdin が
# 閉じていると exec が stderr に出すので、{ } の中で捨てる (exec に直に 2>/dev/null を付けると、シェル全体の stderr が消える)
if [[ -n ${in_file} ]]; then
  exec {in_fd}<"${in_file}"
else
  { exec {in_fd}<&0; } 2>/dev/null || exec {in_fd}</dev/null
fi
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

if [[ ${lock_mode} == held ]]; then
  watch_shared end
  watch_end=${watch_result}
fi
write_end "${result}" "${op_rc}"
exit "${op_rc}"
