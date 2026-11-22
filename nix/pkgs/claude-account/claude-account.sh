#!/usr/bin/env bash
# shellcheck shell=bash
#
# claude-account / claude-<名前>: Claude Code のアカウントを足す・消す・確かめる管理のコマンドと、そのアカウントで Claude Code を起こす
# launcher を兼ねる 1 本の script。nix/pkgs/claude-account が包み、呼ばれた名前 ($0) で振り分ける: claude-account なら管理のコマンド、
# claude-<名前> なら launcher。設計は dotfiles-private の docs/adr/082_claude_token_accounts_*、使い方は nix/README.md の
# 「Claude Code のアカウントを分ける」。
#
# ## アカウント
#
#   既定 (Nix が埋める defaults。今は personal・work)   subscription。dotfiles (package の link と bootstrap) が作る
#   登録 (claude-account add で足す)                   subscription か token。~/.config/claude-accounts/accounts.json に書く
#
#   subscription  ~/.claude-<名前>/.credentials.json (/login の資格情報) で動く
#   token         ~/.config/claude-accounts/<名前>.env の CLAUDE_CODE_OAUTH_TOKEN (claude setup-token の token) を渡して動く
#
# ~/.claude-<名前> の中身 (設定は ~/.claude と共有し、ログインだけを分ける) は nix/scripts/bootstrap-claude-accounts.sh が作る。add は
# package に写したそれを --account <名前> で流し、setup は既定と登録の全部を流す。
#
# ## token のファイル
#
#   # で始まる行と空行のほかは、CLAUDE_CODE_OAUTH_TOKEN=<値> の 1 行だけ (頭の export・値の '…'・"…"・頭の BOM・行末の \r は読む)
#   値が op://… なら 1Password から読み (pjp-op-env。WSL では op-reason の理由の窓が出る)、それ以外は token そのもの (ローカル。権限が
#   600 より緩い・持ち主が自分でないなら読まない)
#
# ほかの名前の行を止めるのは、op の道で pjp-op-env がファイルの全部の行を env に入れるため (ANTHROPIC_API_KEY などが紛れると token より
# 先に効く)。
#
# ## 値を外に出さない
#
#   token の値に触れるのは bash の組み込み (read・printf・export) だけで、外のコマンドの argv に載せない。失敗の文に書くのは行の番号・
#   名前・パス・権限だけ。最初に set +x +a (呼び手の SHELLOPTS が xtrace・allexport を付けていても外す)。
#
# ## 終了コード
#
#   launcher: claude の終了コード (起こした後) / 1 = 用意が無い・token が読めない・登録の一覧が読めない / 2 = 知らない名前 /
#             127 = claude が無い / op の道で op が 0 以外で終われば、その値 (claude は起こさない)
#   管理のコマンド: 0 = 済んだ・使える / 1 = できなかった・用意が無い / 2 = 使い方の誤り・知らない名前

set +x +a

defaults=(@defaults@)
profile_bin='@profileBin@'
pjp_op_env='@pjpOpEnv@/bin/pjp-op-env'
cu='@coreutils@/bin'
jq='@jq@/bin/jq'
bootstrap='@bootstrap@'

base="${HOME}/.claude"
conf_dir="${HOME}/.config/claude-accounts"
registry="${conf_dir}/accounts.json"
bin_dir="${HOME}/.local/bin"
launcher_target="${profile_bin}/claude-account"
name_re='^[a-z0-9][a-z0-9_-]*$'
reason_tail='を起こすのに Claude Code の token (claude setup-token で出したもの) を読む'

# --- 小さな道具

# 1 引数を 1 行として stderr に出す
err() {
  printf '%s\n' "$@" >&2
}

usage() {
  printf '%s\n' \
    '使い方: claude-account <サブコマンド>' \
    '  add <名前> --mode subscription|token   アカウントを足す (~/.claude-<名前>・launcher claude-<名前>・登録)' \
    '  set-token <名前>                       token のアカウントに token を入れる (見えない入力。パイプなら 1 行)' \
    '  list                                   既定と登録のアカウントと、その状態を並べる' \
    '  check <名前>                           使えるかを確かめる (0 = 使える / 1 = 用意が無い / 2 = 知らない名前)' \
    '  remove <名前> [--purge]                登録のアカウントを消す (--purge なら ~/.claude-<名前> と token のファイルも消す)' \
    '  help token [<名前>]                    token をこのマシンとほかのマシンに置く手順' \
    '' \
    "既定のアカウント: ${defaults[*]} (dotfiles が作る)。名前は英小文字・数字で始まり、英小文字・数字・- と _ だけ (account・selector は使えない)。" \
    '使い方の詳細は dotfiles の nix/README.md「Claude Code のアカウントを分ける」。'
}

# token をこのマシンとほかのマシン (子を立てる u24・lavie など) に置く手順 ($1: 名前。無ければ <名前>)。add --mode token の後と
# help token が出す。ほかのマシンの手は Linux の形 (Windows の claude-account.exe も同じ文を出す)
token_help() {
  local n=${1:-<名前>}
  printf '%s\n' \
    "token のアカウント claude-${n} に token を置く手順" \
    "" \
    "このマシン:" \
    "  claude-account set-token ${n}" \
    "    見えない入力で token を貼る (~/.config/claude-accounts/${n}.env に権限 600 で書く)" \
    "" \
    "ほかのマシン (子を立てる u24・lavie など。登録はマシンごと):" \
    "  そのマシンの端末 (ssh か herdr-app の端末。Claude Code の ! は使わない) で打つ:" \
    "    claude-account add ${n} --mode token" \
    "    claude-account set-token ${n}" \
    "  そのマシンに claude-account がまだ無い (dotfiles が古い) ときは、同じ形のファイルを手で置く (fish からも打てる):" \
    "    bash -c 'umask 077 && mkdir -p ~/.config/claude-accounts && read -rsp \"token: \" t && echo && printf \"CLAUDE_CODE_OAUTH_TOKEN=%s\\n\" \"\$t\" > ~/.config/claude-accounts/${n}.env && unset t && chmod 600 ~/.config/claude-accounts/${n}.env && echo 置いた'" \
    "    (dotfiles を新しくしたら claude-account add ${n} --mode token を打つ。置いたファイルはそのまま使う)" \
    "  置けたかは、そのマシンで claude-account check ${n} (0 なら使える。値は出さない)" \
    "" \
    "token の値:" \
    "  1Password のアプリで token の項目を開いて値をコピーし、set-token の入力に貼る。まだ無ければ、自分の端末で" \
    "  claude setup-token を打って出し (画面に出るだけで保存されない)、1Password に入れてから貼る" \
    "  1Password から毎回読むなら (起こすたびに承認が出る): 参照を ~/.config/claude-accounts/${n}.env に 1 行で書く:" \
    "    CLAUDE_CODE_OAUTH_TOKEN=op://…"
}

# 使い方の誤り: わけと使い方を stderr に出して 2 で終わる
usage_err() {
  err "claude-account: $1"
  usage >&2
  exit 2
}

# 家の下のパスを ~/… で出す
shown() {
  local p=$1
  if [[ ${p} == "${HOME}"/* ]]; then
    p=\~/${p#"${HOME}"/}
  fi
  printf '%s' "${p}"
}

# どのマシンか (check の手に添える)
where() {
  if [[ -n ${WSL_DISTRO_NAME-} ]]; then
    printf 'WSL (%s)' "${WSL_DISTRO_NAME}"
  elif [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -n ${WSL_INTEROP-} ]]; then
    # hc exec などで WSL_DISTRO_NAME が無いとき。ホスト名は Windows の PC と同じなので、WSL と添える
    printf 'WSL (%s)' "${HOSTNAME:-?}"
  else
    printf 'このマシン (%s)' "${HOSTNAME:-?}"
  fi
}

# アカウントの名前の形: 英小文字・数字で始まり、英小文字・数字・- と _ だけで 32 字まで。token の頭 (sk-ant-) で始まるものは断る
# (token を名前の所に渡したときに、登録したり文に出したりしないため)
name_ok() {
  [[ $1 =~ ${name_re} && ${#1} -le 32 && $1 != sk-ant-* ]]
}

# 名前に使えない文字列は文に出さない (token を名前に渡したときに、token を画面に出さないため)
bad_name() {
  err "claude-account: アカウントの名前に使えません (英小文字・数字で始まり、英小文字・数字・- と _ だけで 32 字まで。sk-ant- で始まらない)。" \
    "  token を名前の所に渡していないか確かめてください (渡した文字は出しません。token は set-token の見えない入力で渡す)。"
}

is_default() {
  local d
  for d in "${defaults[@]}"; do
    if [[ ${d} == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

# --- 登録の一覧 (~/.config/claude-accounts/accounts.json)

# 読める形か (無いのは空の一覧と同じ)。読めなければ stderr にわけを出して 1
registry_ok() {
  [[ -e ${registry} ]] || return 0
  if "${jq}" -e '(.version == 1) and (.accounts | type == "object")
      and (.accounts | to_entries | all(.value | type == "object" and (.mode == "subscription" or .mode == "token")))
      and (.accounts | keys | all(test("^[a-z0-9][a-z0-9_-]{0,31}$") and . != "account" and . != "selector" and (startswith("sk-ant-") | not)))' \
    "${registry}" >/dev/null 2>&1; then
    return 0
  fi
  err "claude-account: 登録の一覧 ($(shown "${registry}")) が読めない形です。直すか、消してから claude-account add で足し直してください。"
  return 1
}

# $1 の種類 (subscription・token) を出す。登録に無ければ何も出さない。一覧が読めなければ 1
registry_mode() {
  registry_ok || return 1
  [[ -e ${registry} ]] || return 0
  # shellcheck disable=SC2016 # $n は jq の変数
  "${jq}" -r --arg n "$1" '.accounts[$n].mode // empty' "${registry}"
}

# 登録の名前を名前の順に 1 行ずつ出す。一覧が読めなければ 1
registry_names() {
  registry_ok || return 1
  [[ -e ${registry} ]] || return 0
  "${jq}" -r '.accounts | keys[]' "${registry}"
}

# 登録に $1 を種類 $2 で書く ($2 が空なら外す)。一時ファイルに書いて置き換える
registry_put() {
  local tmp filter
  (umask 077 && "${cu}/mkdir" -p -- "${conf_dir}") || return 1
  tmp=$("${cu}/mktemp" "${conf_dir}/.accounts.json.XXXXXX") || return 1
  if [[ -n $2 ]]; then
    # shellcheck disable=SC2016 # $n・$m は jq の変数
    filter='.accounts[$n] = {mode: $m}'
  else
    # shellcheck disable=SC2016 # $n は jq の変数
    filter='del(.accounts[$n])'
  fi
  filter="${filter} | .version = 1 | .accounts |= (to_entries | sort_by(.key) | from_entries)"
  if [[ -e ${registry} ]]; then
    "${jq}" --arg n "$1" --arg m "$2" "${filter}" "${registry}" >"${tmp}"
  else
    "${jq}" -n --arg n "$1" --arg m "$2" "{version: 1, accounts: {}} | ${filter}" >"${tmp}"
  fi || {
    "${cu}/rm" -f -- "${tmp}"
    return 1
  }
  "${cu}/mv" -fT -- "${tmp}" "${registry}"
}

# $1 の種類を mode に、元 (既定・登録) を origin に入れる。知らない名前なら mode は空。登録の一覧が読めなければ 1
lookup() {
  local m
  mode="" origin=""
  if is_default "$1"; then
    mode=subscription origin=既定
    return 0
  fi
  m=$(registry_mode "$1") || return 1
  if [[ -n ${m} ]]; then
    mode=${m} origin=登録
  fi
  return 0
}

# --- ~/.claude-<名前> の用意

# 用意されているか (settings.json が ~/.claude へのリンク。bootstrap が張る)。違えば why (real・missing) を入れて 1
prepared() {
  local dir="${HOME}/.claude-$1"
  why=""
  if [[ -L ${dir}/settings.json ]]; then
    return 0
  fi
  if [[ -e ${dir}/settings.json ]]; then
    why=real
  else
    why=missing
  fi
  return 1
}

# 用意の直し方 (既定は setup、登録は add の打ち直し)。$1 名前・$2 種類・$3 元
prepare_fix() {
  if [[ $3 == 既定 ]]; then
    printf '%s' 'dotfiles の setup (~/dotfiles/setup --steps bootstrap-claude-accounts) を打つ'
  else
    printf '%s' "claude-account add $1 --mode $2 を打つ"
  fi
}

# --- token のファイル

# token の形: 空白・制御文字・引用符・\ の無い ASCII
token_ok() {
  local LC_ALL=C
  [[ $1 =~ ^[!-~]+$ ]] || return 1
  [[ $1 != *[\"\'\\]* ]]
}

# op の参照の形 (制御文字・{ }・引用符・\ が無い。名前の空白は受ける)
ref_ok() {
  local LC_ALL=C
  [[ $1 != *[[:cntrl:]]* && $1 != *[{}]* && $1 != *[\"\'\\]* ]]
}

# 値の引用符を解いて unq に入れる ('…'・"…"・引用符なし (空白に続く # から後ろはコメント))。閉じていない・後ろに余計な文字があれば 1
unquote() {
  local rest
  rest=${1#"${1%%[![:space:]]*}"}
  case ${rest} in
    "'"*)
      rest=${rest:1}
      [[ ${rest} == *"'"* ]] || return 1
      unq=${rest%%"'"*}
      rest=${rest#*"'"}
      ;;
    '"'*)
      rest=${rest:1}
      [[ ${rest} == *'"'* ]] || return 1
      unq=${rest%%'"'*}
      rest=${rest#*'"'}
      ;;
    *)
      if [[ ${rest} == *[[:space:]]'#'* ]]; then
        rest=${rest%%[[:space:]]#*}
      fi
      unq=${rest%"${rest##*[![:space:]]}"}
      return 0
      ;;
  esac
  [[ ${rest} =~ ^[[:space:]]*(#.*)?$ ]]
}

# token のファイル $1 を読み、tok_state (missing・noline・empty・bad・local・op) と tok_value・tok_why に入れる。値は出さない
read_token_file() {
  local LC_ALL=C file=$1 n=0 line body key found=0 first=0
  tok_state="" tok_value="" tok_why=""
  if [[ ! -e ${file} ]]; then
    tok_state=missing
    return 0
  fi
  if [[ -L ${file} ]]; then
    tok_state=bad tok_why="ファイルがリンクです (実体のファイルにする。claude-account set-token で書き直せる)"
    return 0
  fi
  if [[ -d ${file} || ! -r ${file} ]]; then
    tok_state=bad tok_why="ファイルが読めません"
    return 0
  fi
  while IFS= read -r line || [[ -n ${line} ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    if ((n == 1)); then
      line=${line#$'\xef\xbb\xbf'}
    fi
    body=${line#"${line%%[![:space:]]*}"}
    if [[ -z ${body} || ${body} == '#'* ]]; then
      continue
    fi
    if [[ ${body} =~ ^export[[:space:]]+(.*)$ ]]; then
      body=${BASH_REMATCH[1]}
    fi
    if [[ ! ${body} =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      tok_state=bad tok_why="${n} 行目が KEY=値 の形ではありません" tok_value=""
      return 0
    fi
    key=${BASH_REMATCH[1]}
    if [[ ${key} != CLAUDE_CODE_OAUTH_TOKEN ]]; then
      tok_state=bad tok_why="${n} 行目に ${key} があります (書けるのは CLAUDE_CODE_OAUTH_TOKEN の行だけ)" tok_value=""
      return 0
    fi
    if ((found)); then
      tok_state=bad tok_why="CLAUDE_CODE_OAUTH_TOKEN の行が 2 つあります (${first} 行目と ${n} 行目)" tok_value=""
      return 0
    fi
    found=1 first=${n}
    if ! unquote "${BASH_REMATCH[2]}"; then
      tok_state=bad tok_why="${n} 行目の引用符が閉じていないか、後ろに余計な文字があります" tok_value=""
      return 0
    fi
    tok_value=${unq}
    unq=""
  done <"${file}"
  if ((found == 0)); then
    tok_state=noline
    return 0
  fi
  # 引用符の中の前後の空白は値の一部 (pjp-op-env と同じ読み方。" op://…" は参照でも token の形でもない)
  if [[ -z ${tok_value} ]]; then
    tok_state=empty
  elif [[ ${tok_value} == op://* ]]; then
    if ref_ok "${tok_value}"; then
      tok_state=op
    else
      tok_state=bad tok_why="参照 (op://…) に使えない字があります" tok_value=""
    fi
  elif token_ok "${tok_value}"; then
    tok_state=local
  else
    tok_state=bad tok_why="値が token の形ではありません (空白・引用符・制御文字など)" tok_value=""
  fi
  return 0
}

# ローカルの token のファイル $1 を読んでよいか (持ち主が自分で、権限が 600 より緩くない)。違えば perm_why を入れて 1
local_file_ok() {
  local perm
  perm_why=""
  if [[ ! -O $1 ]]; then
    perm_why="持ち主が自分ではありません (claude-account set-token で書き直す)"
    return 1
  fi
  perm=$("${cu}/stat" -c '%a' -- "$1") || {
    perm_why="権限が読めません"
    return 1
  }
  if ((8#${perm} & 8#077)); then
    perm_why="権限が ${perm} です (ほかのユーザーが読める。chmod 600 $(shown "$1") を打つ)"
    return 1
  fi
  return 0
}

# token が無いときの忠告 ($1 名前・$2 ファイル・$3 わけ)。ローカルの置き方を先に、op を添える
guidance() {
  local cmd="claude-$1" f
  f=$(shown "$2")
  err "${cmd}: token がありません ($3)。" \
    "  ${cmd} は claude setup-token で出した token (1 年有効) で Claude Code を起こします。初めに 1 回だけ:" \
    "    1. 自分の端末で claude setup-token を打ち、ブラウザで承認して token を出す" \
    "       (Claude Code の会話の中では打たない。token は画面に出るだけで、どこにも保存されない)" \
    "    2. claude-account set-token $1 を打ち、token を貼る (見えない入力。${f} に権限 600 で書く)" \
    "    3. token は 1Password にも入れておく (このマシンから消したときに入れ直せる)" \
    "  1Password から毎回読むなら (起こすたびに 1Password の承認が出る): 1Password の項目に token を入れ、欄のメニュー" \
    "  「Copy Secret Reference」で取った参照を、そのファイルに 1 行で書く:" \
    "    CLAUDE_CODE_OAUTH_TOKEN=op://…"
}

# --- アカウントの状態 (check・list)

# lookup の後のアカウント $1 が使えるかを見る: st_code (0・1)・st_short (list の状態)・st_line (0 のときの 1 行)・st_fix (1 のときの手)。
# 値を出さず、op を呼ばない
state() {
  local name=$1 cmd="claude-$1" w dir file
  dir="${HOME}/.claude-$1"
  file="${conf_dir}/$1.env"
  w=$(where)
  st_code=1 st_short="" st_line="" st_fix=""
  if ! prepared "${name}"; then
    st_short="dir が用意されていない"
    if [[ ${why} == real ]]; then
      st_fix="${cmd}: $(shown "${dir}/settings.json") が実体です (先に Claude Code を起こした、など)。${w} の端末で、nix/README.md の「既に ~/.claude-<名前> があるとき」の手順で片付けてから $(prepare_fix "${name}" "${mode}" "${origin}")。"
    else
      st_fix="${cmd}: $(shown "${dir}") がまだ用意されていません。${w} の端末で $(prepare_fix "${name}" "${mode}" "${origin}")。"
    fi
    return 0
  fi
  if [[ ${origin} == 登録 && $("${cu}/readlink" -- "${bin_dir}/${cmd}" 2>/dev/null) != "${launcher_target}" ]]; then
    st_short="launcher が無い"
    st_fix="${cmd}: launcher ($(shown "${bin_dir}/${cmd}")) がありません。${w} の端末で claude-account add ${name} --mode ${mode} を打つ。"
    return 0
  fi
  if [[ ${mode} == subscription ]]; then
    if [[ ${OSTYPE-} == darwin* ]]; then
      # macOS のログインは Keychain にあり、.credentials.json ができない
      st_code=0 st_short="subscription (ログインは確かめない)" st_line="${cmd}: subscription (ログインは Keychain にあり、確かめない)"
    elif [[ -e ${dir}/.credentials.json ]]; then
      st_code=0 st_short="ログイン済み" st_line="${cmd}: subscription (ログイン済み)"
    else
      st_short="ログインしていない"
      st_fix="${cmd}: まだログインしていません。${w} の端末で ${cmd} を起こし、/login する。"
    fi
    return 0
  fi
  read_token_file "${file}"
  tok_value=""
  case ${tok_state} in
    missing | noline | empty)
      st_short="token が無い"
      st_fix="${cmd}: token がありません。${w} の端末で claude setup-token を打って token を出し、claude-account set-token ${name} で入れる。"
      ;;
    bad)
      st_short="token のファイルの形が違う"
      st_fix="${cmd}: token のファイル ($(shown "${file}")) の ${tok_why}。${w} の端末で直すか、claude-account set-token ${name} で入れ直す。"
      ;;
    local)
      if local_file_ok "${file}"; then
        st_code=0 st_short="token (ローカル)" st_line="${cmd}: token (ローカル)"
      else
        st_short="token のファイルの権限・持ち主が違う"
        st_fix="${cmd}: token のファイル ($(shown "${file}")) の${perm_why}。${w} の端末で直す。"
      fi
      ;;
    op)
      # 起こすたびに 1Password の承認が要る (子を立てる側からは、起動の直後に止まって見えうる)
      st_code=0 st_short="token (1Password・起動のときに承認が要る)" st_line="${cmd}: token (1Password・起動のときに承認が要る)"
      ;;
  esac
  return 0
}

# --- 管理のコマンド

cmd_add() {
  local name="" new_mode="" cur link
  while (($# > 0)); do
    case $1 in
      --mode)
        (($# >= 2)) || usage_err "--mode の後ろに種類 (subscription・token) がありません。"
        new_mode=$2
        shift 2
        ;;
      --mode=*)
        new_mode=${1#--mode=}
        shift
        ;;
      -*) usage_err "知らない option です: $1" ;;
      *)
        [[ -z ${name} ]] || usage_err "名前は 1 つだけ渡します。"
        name=$1
        shift
        ;;
    esac
  done
  [[ -n ${name} && -n ${new_mode} ]] || usage_err "add には名前と --mode が要ります。"
  [[ ${new_mode} == subscription || ${new_mode} == token ]] || usage_err "種類は subscription か token です: ${new_mode}"
  if ! name_ok "${name}"; then
    bad_name
    return 2
  fi
  if [[ ${name} == account ]]; then
    err "claude-account: account は管理のコマンド (claude-account) の名前なので、アカウントには使えません。"
    return 2
  fi
  if [[ ${name} == selector ]]; then
    err "claude-account: selector は claude-selector (cs) の名前なので、アカウントには使えません。"
    return 2
  fi
  if is_default "${name}"; then
    err "claude-account: ${name} は既定のアカウントです (dotfiles が作るので、足さなくてよい)。"
    return 2
  fi
  cur=$(registry_mode "${name}") || return 1
  if [[ -n ${cur} && ${cur} != "${new_mode}" ]]; then
    err "claude-account: ${name} はもう ${cur} で登録しています。種類を替えるなら claude-account remove ${name} を打ってから足し直してください。"
    return 1
  fi
  link="${bin_dir}/claude-${name}"
  if [[ -e ${link} || -L ${link} ]] && [[ $("${cu}/readlink" -- "${link}") != "${launcher_target}" ]]; then
    err "claude-account: $(shown "${link}") がもうあります (claude-account の link ではありません)。消すか、別の名前で足してください。"
    return 1
  fi
  if [[ -z ${cur} ]]; then
    if ! registry_put "${name}" "${new_mode}"; then
      err "claude-account: 登録の一覧 ($(shown "${registry}")) に書けません。"
      return 1
    fi
    echo "登録しました: ${name} (${new_mode})"
  fi
  if [[ ! -L ${link} ]]; then
    if ! "${cu}/mkdir" -p -- "${bin_dir}" || ! "${cu}/ln" -s -- "${launcher_target}" "${link}"; then
      err "claude-account: launcher ($(shown "${link}")) を張れません。"
      return 1
    fi
    echo "張りました: $(shown "${link}") -> ${launcher_target}"
  fi
  if ! PATH="${jq%/jq}:${cu}:${PATH}" "${BASH}" "${bootstrap}" --account "${name}" || ! prepared "${name}"; then
    if [[ ${why} == real ]]; then
      err "claude-account: $(shown "${HOME}/.claude-${name}/settings.json") が実体なので用意できません (先に Claude Code を起こした、など)。" \
        "  nix/README.md の「既に ~/.claude-<名前> があるとき」の手順で片付けてから、claude-account add ${name} --mode ${new_mode} を打ち直してください。"
    else
      err "claude-account: $(shown "${HOME}/.claude-${name}") の用意が途中で止まりました (上の !! を見る)。直してから claude-account add ${name} --mode ${new_mode} を打ち直してください。"
    fi
    return 1
  fi
  if [[ :${PATH}: != *":${bin_dir}:"* ]]; then
    err "claude-account: $(shown "${bin_dir}") が PATH にありません。claude-${name} を名前で打つには PATH に足してください (dotfiles の home-manager は足す)。"
  fi
  echo
  if [[ ${new_mode} == subscription ]]; then
    echo "claude-${name} で起こし、初回は /login でそのアカウントにログインしてください。"
    return 0
  fi
  read_token_file "${conf_dir}/${name}.env"
  tok_value=""
  case ${tok_state} in
    local | op)
      echo "このマシンの token のファイル ($(shown "${conf_dir}/${name}.env")) はもうあります。claude-${name} で起こせます (確かめるなら claude-account check ${name})。"
      ;;
    *)
      echo "次に token を置いてください (この手順は claude-account help token ${name} でいつでも見られます)。"
      ;;
  esac
  echo
  token_help "${name}"
  return 0
}

cmd_set_token() {
  local name tok="" file tmp
  (($# == 1)) || usage_err "set-token に渡すのは名前 1 つだけです (token は引数でなく、見えない入力かパイプで渡す)。"
  name=$1
  if ! name_ok "${name}"; then
    bad_name
    return 2
  fi
  lookup "${name}" || return 1
  if [[ -z ${mode} ]]; then
    err "claude-account: ${name} は既定のアカウントでも、登録したアカウントでもありません (足すなら claude-account add ${name} --mode token)。"
    return 2
  fi
  if [[ ${mode} != token ]]; then
    err "claude-account: claude-${name} は subscription のアカウントで、token は使いません (claude-${name} を起こして /login する)。"
    return 2
  fi
  file="${conf_dir}/${name}.env"
  if [[ -t 0 ]]; then
    printf '%s' "claude-account: claude setup-token で出した token を貼って Enter を押してください (画面に出しません): " >&2
    IFS= read -rs tok || true
    printf '\n' >&2
  else
    IFS= read -r tok || true
  fi
  tok=${tok%$'\r'}
  tok=${tok#"${tok%%[![:space:]]*}"}
  tok=${tok%"${tok##*[![:space:]]}"}
  if [[ -z ${tok} ]]; then
    err "claude-account: token が空です。何も書いていません。"
    return 1
  fi
  if [[ ${tok} == op://* ]]; then
    tok=""
    err "claude-account: op の参照は set-token でなく、$(shown "${file}") に 1 行で書きます (CLAUDE_CODE_OAUTH_TOKEN=op://…)。何も書いていません。"
    return 1
  fi
  if ! token_ok "${tok}"; then
    tok=""
    err "claude-account: 入れた値が token の形ではありません (空白・引用符・制御文字など)。何も書いていません (値は出しません)。"
    return 1
  fi
  if [[ ${tok} != sk-ant-oat* ]]; then
    err "claude-account: 入れた値が sk-ant-oat で始まりません (claude setup-token の token でないかもしれません)。そのまま書きます。"
  fi
  if ! (umask 077 && "${cu}/mkdir" -p -- "${conf_dir}"); then
    tok=""
    err "claude-account: $(shown "${conf_dir}") を作れません。何も書いていません。"
    return 1
  fi
  tmp=$("${cu}/mktemp" "${conf_dir}/.${name}.env.XXXXXX") || {
    tok=""
    err "claude-account: $(shown "${conf_dir}") に一時ファイルを作れません。何も書いていません。"
    return 1
  }
  if ! printf '# claude-%s の token (claude setup-token で出したもの)。claude-account set-token が書いた。値を画面・会話に出さない\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' \
    "${name}" "${tok}" >"${tmp}" || ! "${cu}/chmod" 600 -- "${tmp}" || ! "${cu}/mv" -fT -- "${tmp}" "${file}"; then
    tok=""
    "${cu}/rm" -f -- "${tmp}"
    err "claude-account: $(shown "${file}") に書けません。"
    return 1
  fi
  tok=""
  echo "書きました: $(shown "${file}") (権限 600)。claude-${name} で起こせます。"
  return 0
}

cmd_list() {
  local names reg n
  (($# == 0)) || usage_err "list は引数を取りません。"
  names=("${defaults[@]}")
  bad_registry=0
  if ! reg=$(registry_names); then
    reg="" bad_registry=1
  fi
  # 既定になった名前 (前に add で登録してから、dotfiles が既定に足したもの。t3) は 2 度出さない
  while IFS= read -r n; do
    if [[ -n ${n} ]] && ! is_default "${n}"; then
      names+=("${n}")
    fi
  done <<<"${reg}"
  for n in "${names[@]}"; do
    lookup "${n}" 2>/dev/null || continue
    state "${n}"
    printf '%-14s %-13s %s  %s\n' "${n}" "${mode}" "${origin}" "${st_short}"
  done
  return "${bad_registry}"
}

cmd_check() {
  local name
  (($# == 1)) || usage_err "check に渡すのは名前 1 つだけです。"
  name=$1
  if ! name_ok "${name}"; then
    bad_name
    return 2
  fi
  lookup "${name}" || return 1
  if [[ -z ${mode} ]]; then
    err "claude-account: claude-${name} は既定のアカウントでも、登録したアカウントでもありません (一覧は claude-account list)。" \
      "  足すなら $(where) の端末で claude-account add ${name} --mode subscription (か --mode token) を打つ。"
    return 2
  fi
  state "${name}"
  if ((st_code == 0)); then
    printf '%s\n' "${st_line}"
  else
    err "${st_fix}"
  fi
  return "${st_code}"
}

# dir $1 を消す (中のリンクは辿らずにリンクだけを外す。dir がリンク・~/.claude と同じ場所なら消さない)
purge_dir() {
  local dir=$1 here there
  [[ -e ${dir} || -L ${dir} ]] || return 0
  if [[ -L ${dir} ]]; then
    err "claude-account: $(shown "${dir}") がリンクなので消しません (先を確かめてから手で外してください)。"
    return 1
  fi
  here=$(cd -- "${dir}" && pwd -P) || return 1
  there=$(cd -- "${base}" 2>/dev/null && pwd -P) || there=""
  if [[ ${here} == "${there}" ]]; then
    err "claude-account: $(shown "${dir}") は ~/.claude と同じ場所なので消しません。"
    return 1
  fi
  "${cu}/rm" -rf -- "${dir}" || return 1
  echo "消しました: $(shown "${dir}")"
}

cmd_remove() {
  local name="" purge=0 cur dir file link kept=0
  while (($# > 0)); do
    case $1 in
      --purge)
        purge=1
        shift
        ;;
      -*) usage_err "知らない option です: $1" ;;
      *)
        [[ -z ${name} ]] || usage_err "名前は 1 つだけ渡します。"
        name=$1
        shift
        ;;
    esac
  done
  [[ -n ${name} ]] || usage_err "remove には名前が要ります。"
  if ! name_ok "${name}"; then
    bad_name
    return 2
  fi
  if [[ ${name} == account || ${name} == selector ]]; then
    err "claude-account: ${name} は管理のコマンド・claude-selector の名前で、アカウントではありません。"
    return 2
  fi
  cur=$(registry_mode "${name}") || return 1
  if is_default "${name}"; then
    # 前に add で登録してから dotfiles が既定に足した名前 (t3) は、登録と add の張った link だけを外す (~/.claude-<名前> は既定の
    # アカウントのものなので、--purge でも消さない)
    if [[ -z ${cur} ]]; then
      err "claude-account: ${name} は既定のアカウントなので消せません (dotfiles が作る)。"
      return 2
    fi
    link="${bin_dir}/claude-${name}"
    if [[ $("${cu}/readlink" -- "${link}" 2>/dev/null) == "${launcher_target}" ]]; then
      "${cu}/rm" -f -- "${link}" || return 1
      echo "消しました: $(shown "${link}")"
    fi
    if ! registry_put "${name}" ""; then
      err "claude-account: 登録の一覧 ($(shown "${registry}")) に書けません。"
      return 1
    fi
    echo "登録から外しました: ${name} (既定のアカウントになったので。$(shown "${HOME}/.claude-${name}") は既定のアカウントのものとして残します)"
    return 0
  fi
  dir="${HOME}/.claude-${name}"
  file="${conf_dir}/${name}.env"
  link="${bin_dir}/claude-${name}"
  if [[ -z ${cur} ]] && ! ((purge == 1)) || [[ -z ${cur} && ! -e ${dir} && ! -L ${dir} && ! -e ${file} ]]; then
    err "claude-account: ${name} は登録したアカウントではありません (claude-account list で見る)。"
    return 2
  fi
  if [[ $("${cu}/readlink" -- "${link}" 2>/dev/null) == "${launcher_target}" ]]; then
    "${cu}/rm" -f -- "${link}" || return 1
    echo "消しました: $(shown "${link}")"
  elif [[ -e ${link} || -L ${link} ]]; then
    err "claude-account: $(shown "${link}") は claude-account の link でないので、残しました。"
  fi
  if [[ -n ${cur} ]]; then
    if ! registry_put "${name}" ""; then
      err "claude-account: 登録の一覧 ($(shown "${registry}")) に書けません。"
      return 1
    fi
    echo "登録から外しました: ${name}"
  fi
  if ((purge == 0)); then
    if [[ -e ${dir} ]]; then
      echo "残しました: $(shown "${dir}") (ログイン・履歴など)"
      kept=1
    fi
    if [[ -e ${file} ]]; then
      echo "残しました: $(shown "${file}") (token)"
      kept=1
    fi
    if ((kept)); then
      echo "消すなら claude-account remove ${name} --purge を打ってください。"
    fi
    return 0
  fi
  purge_dir "${dir}" || return 1
  if [[ -e ${file} ]]; then
    "${cu}/rm" -f -- "${file}" || return 1
    echo "消しました: $(shown "${file}")"
  fi
  return 0
}

manager() {
  local sub=${1-}
  case ${sub} in
    add)
      shift
      cmd_add "$@"
      ;;
    set-token)
      shift
      cmd_set_token "$@"
      ;;
    list)
      shift
      cmd_list "$@"
      ;;
    check)
      shift
      cmd_check "$@"
      ;;
    remove)
      shift
      cmd_remove "$@"
      ;;
    -h | --help)
      usage
      ;;
    help)
      shift
      case ${1-} in
        "") usage ;;
        token)
          (($# <= 2)) || usage_err "help token に渡すのは名前 1 つまでです。"
          if [[ -n ${2-} ]] && ! name_ok "$2"; then
            bad_name
            exit 2
          fi
          token_help "${2-}"
          ;;
        *) usage_err "知らない help です: $1 (help token がある)" ;;
      esac
      ;;
    "")
      usage >&2
      return 2
      ;;
    *) usage_err "知らないサブコマンドです: ${sub}" ;;
  esac
}

# --- launcher

# claude を探して claude に入れる (mise 管理。シェルを通さずに起こされたときは mise に実体を聞く)。無ければ 1
find_claude() {
  claude=$(command -v claude || true)
  if [[ -z ${claude} ]] && command -v mise >/dev/null; then
    claude=$(mise which claude 2>/dev/null || true)
  fi
  if [[ -z ${claude} ]]; then
    err "$1: claude が見つかりません (mise で入れる: ~/dotfiles/setup --steps bootstrap-mise)。"
    return 1
  fi
}

# token を渡して claude を起こす。token を読む所はここだけ (使い心地で読み方を替えるときは、ここを直す)。
# local: 読んだ値を export して exec。op: pjp-op-env が 1Password から読み、env に入れて exec
start_with_token() {
  local name=$1 file=$2
  shift 2
  case ${tok_state} in
    local)
      export CLAUDE_CODE_OAUTH_TOKEN="${tok_value}"
      tok_value=""
      exec "${claude}" "$@"
      ;;
    op)
      # pjp-op-env が 1Password から読んで env に入れたあと、この script の次の段 (末尾の __exec-with-token) が値の形を確かめてから
      # claude を起こす (空・空白入りの値で起こさない。値は env だけを通る)
      tok_value=""
      export CLAUDE_ACCOUNT_STAGE="claude-${name}"
      exec "${pjp_op_env}" --reason "claude-${name} ${reason_tail}" --env-file "${file}" -- "${0}" __exec-with-token "${claude}" "$@"
      ;;
  esac
  err "claude-${name}: token の読み方が決まりません (${tok_state})。"
  exit 1
}

launcher() {
  local name=$1 cmd dir file
  shift
  cmd="claude-${name}"
  if ! name_ok "${name}"; then
    err "${cmd}: アカウントの名前に使えません (英小文字・数字で始まり、英小文字・数字・- と _ だけで 32 字まで)。"
    exit 2
  fi
  lookup "${name}" || exit 1
  if [[ -z ${mode} ]]; then
    err "${cmd}: ${name} は既定のアカウントでも、claude-account で登録したアカウントでもありません。" \
      "  足すなら claude-account add ${name} --mode subscription (か --mode token) を打ってください (一覧は claude-account list)。"
    exit 2
  fi
  dir="${HOME}/.claude-${name}"

  # 用意が済んでいなければ起動しない。起動すると Claude Code が空の dir を作り、CLAUDE.md も skill も無いまま動いてしまう
  # (そうしてできた実体は bootstrap が触らない)
  if ! prepared "${name}"; then
    if [[ ${why} == real ]]; then
      err "${cmd}: ${dir}/settings.json が実ファイルです (bootstrap より先に" \
        "  この dir で Claude Code を起動した、など)。nix/README.md「Claude Code の" \
        "  アカウントを分ける」の「既に ~/.claude-<名前> があるとき」の手順で片付けてから、" \
        "  $(prepare_fix "${name}" "${mode}" "${origin}") を実行してください。"
    else
      err "${cmd}: ${dir} がまだ用意されていません。" \
        "  $(prepare_fix "${name}" "${mode}" "${origin}") を実行してください。"
    fi
    exit 1
  fi
  find_claude "${cmd}" || exit 127

  if [[ ${mode} == token ]]; then
    file="${conf_dir}/${name}.env"
    read_token_file "${file}"
    case ${tok_state} in
      missing)
        guidance "${name}" "${file}" "$(shown "${file}") が無い"
        exit 1
        ;;
      noline)
        guidance "${name}" "${file}" "$(shown "${file}") に CLAUDE_CODE_OAUTH_TOKEN の行が無い"
        exit 1
        ;;
      empty)
        guidance "${name}" "${file}" "$(shown "${file}") の CLAUDE_CODE_OAUTH_TOKEN が空"
        exit 1
        ;;
      bad)
        err "${cmd}: token のファイル ($(shown "${file}")) の ${tok_why}。" \
          "  直すか、claude-account set-token ${name} で入れ直してください (値は出しません)。"
        exit 1
        ;;
      local)
        if ! local_file_ok "${file}"; then
          tok_value=""
          err "${cmd}: token のファイル ($(shown "${file}")) の${perm_why}。" \
            "  chmod 600 $(shown "${file}") を打ってから起こし直してください。"
          exit 1
        fi
        ;;
    esac
  fi

  # このアカウントで動かす。/login の資格情報より優先される env (API キー・OAuth トークン) は外す
  unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
  export CLAUDE_CONFIG_DIR="${dir}"
  if [[ ${mode} == subscription ]]; then
    exec "${claude}" "$@"
  fi
  start_with_token "${name}" "${file}" "$@"
}

# --- 振り分け

me=${0##*/}

# op の道の次の段 (start_with_token が pjp-op-env 越しに起こす)。印 (CLAUDE_ACCOUNT_STAGE) が自分の名前のときだけ受ける
if [[ ${1-} == __exec-with-token && ${CLAUDE_ACCOUNT_STAGE-} == "${me}" && $# -ge 2 ]]; then
  unset CLAUDE_ACCOUNT_STAGE
  if ! token_ok "${CLAUDE_CODE_OAUTH_TOKEN-}" || [[ ${CLAUDE_CODE_OAUTH_TOKEN} == op://* ]]; then
    unset CLAUDE_CODE_OAUTH_TOKEN
    err "${me}: 1Password から読んだ値が token の形ではありません (空・空白・引用符など。値は出しません)。" \
      "  1Password の項目と欄を確かめるか、claude-account set-token ${me#claude-} でこのマシンに token を置いてください。"
    exit 70
  fi
  shift
  exec "$@"
fi
case ${me} in
  claude-account)
    manager "$@"
    exit $?
    ;;
  claude-*)
    launcher "${me#claude-}" "$@"
    ;;
  *)
    err "claude-account: 呼ばれた名前 (${me}) が claude-account でも claude-<名前> でもありません。"
    exit 2
    ;;
esac
