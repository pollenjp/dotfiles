#!/usr/bin/env bash
# shellcheck shell=bash
#
# claude-account / claude-<名前> / claude: Claude Code のアカウントを足す・消す・確かめる・棚卸しする管理のコマンドと、そのアカウントで
# Claude Code を起こす launcher と、素の claude を token で起こす wrapper を兼ねる 1 本の script。nix/pkgs/claude-account が包み、呼ばれた
# 名前 ($0) で振り分ける: claude-account なら管理のコマンド、claude-<名前> なら launcher、claude なら素の claude の wrapper。設計は
# dotfiles-private の docs/adr/082_claude_token_accounts_* と docs/adr/123_claude_token_watch_*、使い方は nix/README.md の「Claude Code の
# アカウントを分ける」「claude の token の置き場を宣言する」。
#
# ## アカウント
#
#   既定 (Nix が埋める defaults。今は personal・work)   subscription。dotfiles (package の link と bootstrap) が作る
#   登録 (claude-account add で足す)                   subscription か token。~/.config/claude-accounts/accounts.json に書く
#   素の claude (名前 default)                         ~/.claude。宣言 (dotfiles.claude.tokens.default) のあるホストでは token、無ければ
#                                                     今のまま /login の資格情報 (~/.claude/.credentials.json)
#
#   subscription  ~/.claude-<名前>/.credentials.json (/login の資格情報) で動く
#   token         ~/.config/claude-accounts/<名前>.env の CLAUDE_CODE_OAUTH_TOKEN (claude setup-token の token) を渡して動く
#
# ~/.claude-<名前> の中身 (設定は ~/.claude と共有し、ログインだけを分ける) は nix/scripts/bootstrap-claude-accounts.sh が作る。add は
# package に写したそれを --account <名前> で流し、setup は既定と登録の全部を流す。
#
# ## 素の claude の wrapper (claude)
#
# 宣言のあるホスト (@bareToken@ が 1) では、home/modules/claude.nix が ~/<@bareBinRel@>/claude をこの script への link にし、login の環境と
# 対話のシェル (mise の後) の PATH の頭に足す。CLAUDE_CONFIG_DIR を付けずに起こされたら ~/.config/claude-accounts/default.env の token を
# 渡して本物の claude を起こし (CLAUDE_CONFIG_DIR は付けない)、CLAUDE_CONFIG_DIR を付けて起こされたら (claude-<名前> の launcher・T3 Code・
# bootstrap) 何もせずに本物の claude を起こす。本物の claude は、PATH の claude のうちこの script でない最初のもの (無ければ mise which)。
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
# ## 入れた時刻の控えと棚卸し
#
#   set-token は token を書いたあと、入れた時刻 (日本時間・秒まで) を ~/.local/state/claude-accounts/tokens.json に控える
#   ({"<名前>":{"set_at":"2026-11-28T21:00:00+09:00"}}。値は置かない)。audit は宣言 (~/.local/state/dotfiles/claude-tokens.json。
#   home/modules/claude.nix が書く) とこのホストの登録・token のファイル・控えを、値を見ずに並べる (入れてから 330 日を超えたら回す)
#
# ## 値を外に出さない
#
#   token の値に触れるのは bash の組み込み (read・printf・export) だけで、外のコマンドの argv に載せない。失敗の文に書くのは行の番号・
#   名前・パス・権限だけ。最初に set +x +a (呼び手の SHELLOPTS が xtrace・allexport を付けていても外す)。audit も token のファイルの
#   形 (ローカル・1Password・無い) と権限・時刻だけを出す
#
# ## 終了コード
#
#   launcher・wrapper: claude の終了コード (起こした後) / 1 = 用意が無い・token が読めない・登録の一覧が読めない / 2 = 知らない名前 /
#                      127 = claude が無い / op の道で op が 0 以外で終われば、その値 (claude は起こさない)
#   管理のコマンド: 0 = 済んだ・使える / 1 = できなかった・用意が無い / 2 = 使い方の誤り・知らない名前
#   audit: 0 = 手を入れるものが無い / 1 = ある (回す・入れる・直す・宣言漏れ) / 2 = 宣言・登録・控えを読めない

set +x +a

defaults=(@defaults@)
profile_bin='@profileBin@'
pjp_op_env='@pjpOpEnv@/bin/pjp-op-env'
cu='@coreutils@/bin'
jq='@jq@/bin/jq'
bootstrap='@bootstrap@'
# 1 = 素の claude を token で起こすホスト (dotfiles.claude.tokens.default の宣言がある)
bare_token='@bareToken@'

base="${HOME}/.claude"
conf_dir="${HOME}/.config/claude-accounts"
registry="${conf_dir}/accounts.json"
bin_dir="${HOME}/.local/bin"
launcher_target="${profile_bin}/claude-account"
name_re='^[a-z0-9][a-z0-9_-]*$'
reason_tail='を起こすのに Claude Code の token (claude setup-token で出したもの) を読む'
# 素の claude の名前と wrapper (home/modules/claude.nix が置く)
bare_name=default
bare_link="${HOME}/@bareBinRel@/claude"
# 宣言 (home/modules/claude.nix が書く) と、set-token が入れた時刻の控え
decl_file="${HOME}/.local/state/dotfiles/claude-tokens.json"
times_dir="${HOME}/.local/state/claude-accounts"
times_file="${times_dir}/tokens.json"
# 入れてからこの日数を超えた token は回す (setup-token の token は 1 年有効。月ごとの棚卸しで、期限の 1 か月より前に気付く)
rotate_days=330
valid_days=365

# --- 小さな道具

# 1 引数を 1 行として stderr に出す
err() {
  printf '%s\n' "$@" >&2
}

usage() {
  printf '%s\n' \
    '使い方: claude-account <サブコマンド>' \
    '  add <名前> --mode subscription|token   アカウントを足す (~/.claude-<名前>・launcher claude-<名前>・登録)' \
    '  set-token <名前>                       token のアカウントに token を入れる (見えない入力。パイプなら 1 行)。入れた時刻を控える' \
    '  list                                   既定と登録のアカウント (と素の claude) と、その状態を並べる' \
    '  check <名前>                           使えるかを確かめる (0 = 使える / 1 = 用意が無い / 2 = 知らない名前)' \
    '  remove <名前> [--purge]                登録のアカウントを消す (--purge なら ~/.claude-<名前> と token のファイルも消す)' \
    '  audit                                  token の置き場の宣言と、このホストの token・入れた時刻を値を見ずに並べ、判定を出す' \
    '  help token [<名前>]                    token をこのマシンとほかのマシンに置く手順' \
    '' \
    "既定のアカウント: ${defaults[*]} (dotfiles が作る)。名前は英小文字・数字で始まり、英小文字・数字・- と _ だけ (account・selector・default は使えない)。" \
    '素の claude (~/.claude) は名前 default で扱う (check default。token は宣言 dotfiles.claude.tokens.default のあるホストだけ)。' \
    '使い方の詳細は dotfiles の nix/README.md「Claude Code のアカウントを分ける」「claude の token の置き場を宣言する」。'
}

# token をこのマシンとほかのマシン (子を立てる Linux のマシンなど) に置く手順 ($1: 名前。無ければ <名前>)。add --mode token の後と
# help token が出す。ほかのマシンの手は Linux の形 (Windows の claude-account.exe も同じ文を出す)
token_help() {
  local n=${1:-<名前>}
  if [[ ${n} == "${bare_name}" ]]; then
    bare_token_help
    return 0
  fi
  printf '%s\n' \
    "token のアカウント claude-${n} に token を置く手順" \
    "" \
    "このマシン:" \
    "  claude-account set-token ${n}" \
    "    見えない入力で token を貼る (~/.config/claude-accounts/${n}.env に権限 600 で書き、入れた時刻を控える)" \
    "" \
    "ほかのマシン (子を立てる Linux のマシンなど。登録はマシンごと):" \
    "  そのマシンの端末 (ssh か herdr-app の端末。Claude Code の ! は使わない) で打つ:" \
    "    claude-account add ${n} --mode token" \
    "    claude-account set-token ${n}" \
    "  そのマシンに claude-account がまだ無い (dotfiles が古い) ときは、同じ形のファイルを手で置く (fish からも打てる):" \
    "    bash -c 'umask 077 && mkdir -p ~/.config/claude-accounts && read -rsp \"token: \" t && echo && printf \"CLAUDE_CODE_OAUTH_TOKEN=%s\\n\" \"\$t\" > ~/.config/claude-accounts/${n}.env && unset t && chmod 600 ~/.config/claude-accounts/${n}.env && echo 置いた'" \
    "    (dotfiles を新しくしたら claude-account add ${n} --mode token を打つ。置いたファイルはそのまま使う)" \
    "  置けたかは、そのマシンで claude-account check ${n} (0 なら使える。値は出さない)" \
    "  置いたホストは、そのホストの宣言 (dotfiles.claude.tokens.${n}。同じ token なら同じ呼び名) にも書く (claude-account audit が並べる)" \
    "" \
    "token の値:" \
    "  1Password のアプリで token の項目を開いて値をコピーし、set-token の入力に貼る。まだ無ければ、自分の端末で" \
    "  claude setup-token を打って出し (画面に出るだけで保存されない)、1Password に入れてから貼る" \
    "  1Password から毎回読むなら (起こすたびに承認が出る): 参照を ~/.config/claude-accounts/${n}.env に 1 行で書く:" \
    "    CLAUDE_CODE_OAUTH_TOKEN=op://…"
}

# 素の claude (default) に token を置く手順
bare_token_help() {
  printf '%s\n' \
    "素の claude (~/.claude。名前 ${bare_name}) に token を置く手順" \
    "" \
    "素の claude が token で起きるのは、ホストの宣言に dotfiles.claude.tokens.${bare_name} を書いて switch したホストだけ" \
    "(宣言の無いホストの素の claude は /login で使う)。" \
    "" \
    "token を出す (ブラウザのある端末で。素の claude と同じ Claude のアカウントで承認する):" \
    "  claude setup-token" \
    "    出た token は画面に出るだけで保存されないので、1Password にも入れておく" \
    "" \
    "宣言したホストの端末 (ssh か herdr-app の端末。Claude Code の ! は使わない) で:" \
    "  claude-account set-token ${bare_name}" \
    "    見えない入力で token を貼る (~/.config/claude-accounts/${bare_name}.env に権限 600 で書き、入れた時刻を控える)" \
    "  1Password から移すなら: op read '<参照>' | claude-account set-token ${bare_name}" \
    "  置けたかは claude-account check ${bare_name} (0 なら使える。値は出さない)"
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

# この script の実体 (素の claude の wrapper と本物の claude を見分ける)
self_path() {
  "${cu}/readlink" -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true
}

# 素の claude の wrapper (~/<bareBinRel>/claude) が、この script への link として置かれているか
bare_link_ok() {
  local self real
  [[ -e ${bare_link} ]] || return 1
  self=$(self_path)
  real=$("${cu}/readlink" -f -- "${bare_link}" 2>/dev/null) || return 1
  [[ -n ${self} && ${real} == "${self}" ]]
}

# --- 時刻 (日本時間で書く。tzdata の無い環境でも同じ字になるよう、UNIX 秒に 9 時間を足して UTC として整える)

# 今の UNIX 秒。env の CLAUDE_ACCOUNT_NOW (2026-11-28T21:00:00+09:00 の形) があればその時刻 (試験)
now_epoch() {
  if [[ -n ${CLAUDE_ACCOUNT_NOW-} ]]; then
    "${cu}/date" -d "${CLAUDE_ACCOUNT_NOW}" +%s
  else
    "${cu}/date" +%s
  fi
}

# UNIX 秒 $1 を日本時間の ISO 8601 (秒まで) にする
iso_jst() {
  "${cu}/date" -u -d "@$(($1 + 32400))" '+%Y-%m-%dT%H:%M:%S+09:00'
}

# UNIX 秒 $1 を日本時間の「YYYY-MM-DD HH:MM」にする
short_jst() {
  "${cu}/date" -u -d "@$(($1 + 32400))" '+%Y-%m-%d %H:%M'
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

# --- 入れた時刻の控え (~/.local/state/claude-accounts/tokens.json)

# 読める形か (無いのは空と同じ)。読めなければ stderr にわけを出して 1
times_ok() {
  [[ -e ${times_file} ]] || return 0
  if "${jq}" -e 'type == "object" and all(.[]; type == "object" and (.set_at | type) == "string")' "${times_file}" >/dev/null 2>&1; then
    return 0
  fi
  err "claude-account: 入れた時刻の控え ($(shown "${times_file}")) が読めない形です。消せば次の set-token が作り直します (消した token は棚卸しで「回す」と出る)。"
  return 1
}

# $1 の入れた時刻 (控えの字のまま) を出す。無ければ何も出さない
times_get() {
  [[ -e ${times_file} ]] || return 0
  # shellcheck disable=SC2016 # $n は jq の変数
  "${jq}" -r --arg n "$1" '.[$n].set_at // empty' "${times_file}" 2>/dev/null
}

# 控えの $1 に時刻 $2 を書く ($2 が空なら外す)。一時ファイルに書いて置き換える
times_put() {
  local tmp
  if [[ -z $2 && ! -e ${times_file} ]]; then
    return 0
  fi
  (umask 077 && "${cu}/mkdir" -p -- "${times_dir}") || return 1
  tmp=$("${cu}/mktemp" "${times_dir}/.tokens.json.XXXXXX") || return 1
  # shellcheck disable=SC2016 # $n・$t は jq の変数
  if [[ -e ${times_file} && -n $2 ]]; then
    "${jq}" -c -S --arg n "$1" --arg t "$2" '.[$n] = ((.[$n] // {}) + {set_at: $t})' "${times_file}" >"${tmp}"
  elif [[ -e ${times_file} ]]; then
    "${jq}" -c -S --arg n "$1" 'del(.[$n])' "${times_file}" >"${tmp}"
  else
    "${jq}" -c -S -n --arg n "$1" --arg t "$2" '{($n): {set_at: $t}}' >"${tmp}"
  fi || {
    "${cu}/rm" -f -- "${tmp}"
    return 1
  }
  "${cu}/mv" -fT -- "${tmp}" "${times_file}"
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
  if [[ ! -e ${file} && ! -L ${file} ]]; then
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

# token が無いときの忠告 ($1 起こすコマンド・$2 名前・$3 ファイル・$4 わけ)。ローカルの置き方を先に、op を添える
guidance() {
  local cmd=$1 name=$2 f
  f=$(shown "$3")
  if [[ ${name} == "${bare_name}" ]]; then
    err "${cmd}: token がありません ($4)。" \
      "  このホストの素の claude は、宣言 (dotfiles.claude.tokens.${bare_name}) により claude setup-token で出した token (1 年有効) で起きます。初めに 1 回だけ:" \
      "    1. ブラウザのある端末で claude setup-token を打ち、素の claude と同じ Claude のアカウントで承認して token を出す" \
      "       (Claude Code の会話の中では打たない。token は画面に出るだけで、どこにも保存されない)" \
      "    2. このマシンの端末で claude-account set-token ${bare_name} を打ち、token を貼る (見えない入力。${f} に権限 600 で書く)" \
      "    3. token は 1Password にも入れておく (このマシンから消したときに入れ直せる)" \
      "  token を使わずに本物の claude を起こすなら (/login の資格情報): mise which claude が出すパスを直に打つ。"
    return 0
  fi
  err "${cmd}: token がありません ($4)。" \
    "  ${cmd} は claude setup-token で出した token (1 年有効) で Claude Code を起こします。初めに 1 回だけ:" \
    "    1. 自分の端末で claude setup-token を打ち、ブラウザで承認して token を出す" \
    "       (Claude Code の会話の中では打たない。token は画面に出るだけで、どこにも保存されない)" \
    "    2. claude-account set-token ${name} を打ち、token を貼る (見えない入力。${f} に権限 600 で書く)" \
    "    3. token は 1Password にも入れておく (このマシンから消したときに入れ直せる)" \
    "  1Password から毎回読むなら (起こすたびに 1Password の承認が出る): 1Password の項目に token を入れ、欄のメニュー" \
    "  「Copy Secret Reference」で取った参照を、そのファイルに 1 行で書く:" \
    "    CLAUDE_CODE_OAUTH_TOKEN=op://…"
}

# --- アカウントの状態 (check・list)

# token のファイル ($1 起こすコマンド・$2 名前) の状態を st_* に入れる (state と state_bare の後半)。値を出さず、op を呼ばない
token_state() {
  local cmd=$1 name=$2 w file
  file="${conf_dir}/${name}.env"
  w=$(where)
  read_token_file "${file}"
  tok_value=""
  case ${tok_state} in
    missing | noline | empty)
      st_short="token が無い"
      if [[ ${name} == "${bare_name}" ]]; then
        st_fix="${cmd}: token がありません。ブラウザのある端末で claude setup-token を打って token を出し、${w} の端末で claude-account set-token ${name} で入れる。"
      else
        st_fix="${cmd}: token がありません。${w} の端末で claude setup-token を打って token を出し、claude-account set-token ${name} で入れる。"
      fi
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
}

# lookup の後のアカウント $1 が使えるかを見る: st_code (0・1)・st_short (list の状態)・st_line (0 のときの 1 行)・st_fix (1 のときの手)。
# 値を出さず、op を呼ばない
state() {
  local name=$1 cmd="claude-$1" w dir
  dir="${HOME}/.claude-$1"
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
  token_state "${cmd}" "${name}"
  return 0
}

# 素の claude (default) の種類を mode に入れ、使えるかを st_* に入れる (state と同じ形)。宣言のあるホストは token のファイル、無ければ
# ~/.claude/.credentials.json (/login の資格情報) を見る
state_bare() {
  local w
  w=$(where)
  st_code=1 st_short="" st_line="" st_fix=""
  if [[ ${bare_token} != 1 ]]; then
    mode=subscription
    if [[ ${OSTYPE-} == darwin* ]]; then
      st_code=0 st_short="subscription (ログインは確かめない)" st_line="claude: subscription (ログインは Keychain にあり、確かめない)"
    elif [[ -e ${base}/.credentials.json ]]; then
      st_code=0 st_short="ログイン済み" st_line="claude: subscription (ログイン済み)"
    else
      st_short="ログインしていない"
      st_fix="claude: まだログインしていません。${w} の端末で claude を起こし、/login する。"
    fi
    return 0
  fi
  mode=token
  if ! bare_link_ok; then
    st_short="wrapper が無い"
    st_fix="claude: 素の claude の wrapper ($(shown "${bare_link}")) がありません。${w} の端末で dotfiles の setup (~/dotfiles/setup --update) を打つ。"
    return 0
  fi
  token_state claude "${bare_name}"
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
  if [[ ${name} == "${bare_name}" ]]; then
    err "claude-account: ${bare_name} は素の claude (~/.claude) の名前なので、アカウントには使えません (素の claude の token は、ホストの宣言 dotfiles.claude.tokens.${bare_name} を書いてから claude-account set-token ${bare_name} で入れる)。"
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
  local name tok="" file tmp label now
  (($# == 1)) || usage_err "set-token に渡すのは名前 1 つだけです (token は引数でなく、見えない入力かパイプで渡す)。"
  name=$1
  if ! name_ok "${name}"; then
    bad_name
    return 2
  fi
  if [[ ${name} == "${bare_name}" ]]; then
    if [[ ${bare_token} != 1 ]]; then
      err "claude-account: このホストの素の claude (${bare_name}) は token を読みません (ホストの宣言 dotfiles.claude.tokens.${bare_name} が無い)。" \
        "  素の claude は /login で使う。token で起こすなら、ホストの宣言に dotfiles.claude.tokens.${bare_name} を書いて switch してから打ち直す。"
      return 2
    fi
    label="claude (素の claude)"
  else
    lookup "${name}" || return 1
    if [[ -z ${mode} ]]; then
      err "claude-account: ${name} は既定のアカウントでも、登録したアカウントでもありません (足すなら claude-account add ${name} --mode token)。"
      return 2
    fi
    if [[ ${mode} != token ]]; then
      err "claude-account: claude-${name} は subscription のアカウントで、token は使いません (claude-${name} を起こして /login する)。"
      return 2
    fi
    label="claude-${name}"
  fi
  file="${conf_dir}/${name}.env"
  # 値を聞く前に、控えが読めない形なら止まる (token を書いたのに時刻を控えられない、を避ける)
  times_ok || return 1
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
  if ! printf '# %s の token (claude setup-token で出したもの)。claude-account set-token が書いた。値を画面・会話に出さない\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' \
    "${label}" "${tok}" >"${tmp}" || ! "${cu}/chmod" 600 -- "${tmp}" || ! "${cu}/mv" -fT -- "${tmp}" "${file}"; then
    tok=""
    "${cu}/rm" -f -- "${tmp}"
    err "claude-account: $(shown "${file}") に書けません。"
    return 1
  fi
  tok=""
  if [[ ${name} == "${bare_name}" ]]; then
    echo "書きました: $(shown "${file}") (権限 600)。claude (素の claude) で起こせます。"
  else
    echo "書きました: $(shown "${file}") (権限 600)。claude-${name} で起こせます。"
  fi
  if ! now=$(now_epoch) || ! now=$(iso_jst "${now}") || ! times_put "${name}" "${now}"; then
    err "claude-account: token は書きましたが、入れた時刻を $(shown "${times_file}") に控えられません (棚卸しは「回す」と出す)。直してから set-token を打ち直してください。"
    return 1
  fi
  echo "入れた時刻: ${now} ($(shown "${times_file}"))"
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
  # 既定になった名前 (前に add で登録してから、dotfiles が既定に足したもの。t3) は 2 度出さない。default は素の claude の名前 (下で出す)
  while IFS= read -r n; do
    if [[ -n ${n} && ${n} != "${bare_name}" ]] && ! is_default "${n}"; then
      names+=("${n}")
    fi
  done <<<"${reg}"
  state_bare
  printf '%-14s %-13s %s  %s\n' "${bare_name}" "${mode}" "素の claude" "${st_short}"
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
  if [[ ${name} == "${bare_name}" ]]; then
    state_bare
  else
    lookup "${name}" || return 1
    if [[ -z ${mode} ]]; then
      err "claude-account: claude-${name} は既定のアカウントでも、登録したアカウントでもありません (一覧は claude-account list)。" \
        "  足すなら $(where) の端末で claude-account add ${name} --mode subscription (か --mode token) を打つ。"
      return 2
    fi
    state "${name}"
  fi
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
  if [[ ${name} == "${bare_name}" ]]; then
    err "claude-account: ${bare_name} は素の claude (~/.claude) の名前で、消せるアカウントではありません (素の claude の token をやめるなら、ホストの宣言 dotfiles.claude.tokens.${bare_name} を外して switch し、$(shown "${conf_dir}/${bare_name}.env") を消す)。"
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
  # 消した token の入れた時刻も控えから外す (残すと、同じ名前で足し直した token が古い時刻で並ぶ)。控えが読めない形なら外せないと出す
  # (Windows の claude-account.exe と同じ。終了コードは 0)
  if [[ -e ${times_file} ]]; then
    if ! times_ok 2>/dev/null; then
      err "claude-account: 入れた時刻の控え ($(shown "${times_file}")) から ${name} を外せません。"
    elif [[ -n $(times_get "${name}") ]]; then
      if times_put "${name}" ""; then
        echo "控えから外しました: ${name} の入れた時刻"
      else
        err "claude-account: 入れた時刻の控え ($(shown "${times_file}")) から ${name} を外せません。"
      fi
    fi
  fi
  return 0
}

# --- 棚卸し (audit)

# 宣言の形 (home/modules/claude.nix が lib/claude-tokens.nix の stateText で書く形)。名前・label・item は値を書けない形に限る
decl_shape='
  type == "object" and (.accounts | type) == "object"
  and all(.accounts | to_entries[];
    (.key | test("\\A[a-z0-9][a-z0-9_-]{0,31}\\z")) and (.key | startswith("sk-ant-") | not)
    and .key != "account" and .key != "selector"
    and (.value | type) == "object" and (.value | has("label")) and (.value | has("item"))
    and ((.value.label | type) == "string" and (.value.label | test("\\A[a-z0-9][a-z0-9._-]{0,63}\\z"))
      and (.value.label | startswith("sk-ant-") | not))
    and (.value.item == null
      or ((.value.item | type) == "string"
        and (.value.item | test("\\Aop://[^/[:cntrl:]]+/[^/[:cntrl:]]+/[^/[:cntrl:]]+(/[^/[:cntrl:]]+)?\\z")))))'

# 棚卸しのホストの名前 (頭の行。WSL は distro の名前を添える)
audit_host() {
  if [[ -n ${WSL_DISTRO_NAME-} ]]; then
    printf '%s (WSL の %s)' "${HOSTNAME:-?}" "${WSL_DISTRO_NAME}"
  elif [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -n ${WSL_INTEROP-} ]]; then
    printf '%s (WSL)' "${HOSTNAME:-?}"
  else
    printf '%s' "${HOSTNAME:-?}"
  fi
}

cmd_audit() {
  local now decl_state=missing decl_count=0 reg="" times_count=0 n name label item src perm setat set_epoch days left
  local verdict key mtime shown_name declared reg_mode total=0 i
  local missing_setup fix_reason token_reason rotate_reason
  local -a names=() bullets=() reasons=() sorted=()
  local -A seen=() decl_label=() decl_item=() label_names=()
  # 判定の数 (ASCII のキーで数え、出すときに名前を当てる)
  local -A count=([ok]=0 [rotate]=0 [insert]=0 [fix]=0 [undeclared]=0)
  local -A verdict_key=([ok]=ok [回す]=rotate [入れる]=insert [直す]=fix [宣言漏れ]=undeclared)
  (($# == 0)) || usage_err "audit は引数を取りません。"
  now=$(now_epoch) || {
    err "claude-account: 今の時刻を読めません (CLAUDE_ACCOUNT_NOW は 2026-11-28T21:00:00+09:00 の形)。"
    return 2
  }
  # 宣言
  if [[ -e ${decl_file} ]]; then
    if ! "${jq}" -e "${decl_shape}" "${decl_file}" >/dev/null 2>&1; then
      err "claude-account: 宣言 ($(shown "${decl_file}")) が読めない形です (dotfiles の home/modules/claude.nix が書く形でない)。~/dotfiles/setup --update で書き直してください。"
      return 2
    fi
    decl_state=present
    while IFS=$'\t' read -r name label item; do
      [[ -n ${name} ]] || continue
      decl_label[${name}]=${label}
      decl_item[${name}]=${item}
      decl_count=$((decl_count + 1))
      if [[ -z ${seen[${name}]-} ]]; then
        seen[${name}]=1
        names+=("${name}")
      fi
    done < <("${jq}" -r '.accounts | to_entries[] | [.key, .value.label, (.value.item // "")] | join("\t")' "${decl_file}")
  fi
  # 登録の token のアカウント
  registry_ok || return 2
  if [[ -e ${registry} ]]; then
    reg=$("${jq}" -r '.accounts | to_entries[] | select(.value.mode == "token") | .key' "${registry}") || return 2
  fi
  while IFS= read -r name; do
    if [[ -n ${name} && -z ${seen[${name}]-} ]]; then
      seen[${name}]=1
      names+=("${name}")
    fi
  done <<<"${reg}"
  # token のファイル (名前の形のものだけ。set-token の一時ファイル (頭が .) は見ない)
  if [[ -d ${conf_dir} ]]; then
    for n in "${conf_dir}"/*.env; do
      [[ -e ${n} || -L ${n} ]] || continue
      name=${n##*/}
      name=${name%.env}
      if name_ok "${name}" && [[ -z ${seen[${name}]-} ]]; then
        seen[${name}]=1
        names+=("${name}")
      fi
    done
  fi
  # 素の claude は、宣言のあるホストなら token が無くても並べる
  if [[ ${bare_token} == 1 && -z ${seen[${bare_name}]-} ]]; then
    seen[${bare_name}]=1
    names+=("${bare_name}")
  fi
  times_ok || return 2
  if [[ -e ${times_file} ]]; then
    times_count=$("${jq}" -r 'length' "${times_file}") || times_count=0
  fi

  echo "claude-account audit: $(audit_host) ($(short_jst "${now}") JST・入れてから ${rotate_days} 日を超えたら回す)"
  if [[ ${decl_state} == present ]]; then
    echo "宣言: $(shown "${decl_file}") (${decl_count} 件)"
  else
    echo "宣言: なし ($(shown "${decl_file}") が無い。dotfiles が古いか、Claude Code を入れないホスト)"
  fi
  if [[ -e ${times_file} ]]; then
    echo "控え: $(shown "${times_file}") (${times_count} 件)"
  else
    echo "控え: なし (まだ set-token で入れていない)"
  fi
  echo
  if ((${#names[@]} == 0)); then
    echo "token の置き場はありません (宣言も、token のアカウントも、token のファイルも無い)。"
    return 0
  fi
  # 素の claude を先に、ほかは名前の順
  if [[ -n ${seen[${bare_name}]-} ]]; then
    sorted+=("${bare_name}")
  fi
  while IFS= read -r n; do
    if [[ -n ${n} && ${n} != "${bare_name}" ]]; then
      sorted+=("${n}")
    fi
  done < <(printf '%s\n' "${names[@]}" | LC_ALL=C "${cu}/sort")

  echo "| アカウント | 呼び名 | 1Password の参照 | 置き方 | 権限 | 入れた時刻 | 日数 | 判定 |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
  for name in "${sorted[@]}"; do
    reasons=() src="-" perm="-" setat="-" days="-"
    missing_setup="" fix_reason="" token_reason="" rotate_reason=""
    declared=0
    if [[ -n ${decl_label[${name}]+set} ]]; then
      declared=1
    fi
    label=${decl_label[${name}]:--}
    item=${decl_item[${name}]:--}
    if [[ ${name} == "${bare_name}" ]]; then
      shown_name="${bare_name} (素の claude)"
    else
      shown_name=${name}
    fi
    if ((declared)); then
      label_names[${label}]+="${label_names[${label}]:+・}${name}"
    fi
    # 登録 (素の claude は宣言と wrapper)
    if [[ ${name} == "${bare_name}" ]]; then
      if ((declared)) && [[ ${bare_token} != 1 ]]; then
        fix_reason="素の claude の wrapper が入っていない (宣言の後に switch していない。~/dotfiles/setup --update)"
      elif ((declared)) && ! bare_link_ok; then
        fix_reason="素の claude の wrapper ($(shown "${bare_link}")) が無い (~/dotfiles/setup --update)"
      fi
    else
      reg_mode=$(registry_mode "${name}" 2>/dev/null) || reg_mode=""
      if is_default "${name}"; then
        fix_reason="既定のアカウント (subscription。dotfiles が作る) で、token を置かない (宣言から外すか、別の名前で claude-account add <名前> --mode token を打って宣言し直す)"
      elif [[ -z ${reg_mode} ]]; then
        missing_setup="登録が無い (claude-account add ${name} --mode token を打ってから claude-account set-token ${name})"
      elif [[ ${reg_mode} == subscription ]]; then
        fix_reason="subscription のアカウントとして登録している (token のアカウントなら claude-account remove ${name} と claude-account add ${name} --mode token)"
      fi
    fi
    # token のファイル (形と権限だけを見る。値は出さない)
    read_token_file "${conf_dir}/${name}.env"
    tok_value=""
    case ${tok_state} in
      missing) src="無い" ;;
      noline | empty) src="空" ;;
      bad) src="形が違う" ;;
      local) src="ローカル" ;;
      op) src="1Password" ;;
    esac
    if [[ ${tok_state} != missing && ! -L ${conf_dir}/${name}.env ]]; then
      perm=$("${cu}/stat" -c '%a' -- "${conf_dir}/${name}.env" 2>/dev/null) || perm="?"
    fi
    case ${tok_state} in
      missing | noline | empty)
        if [[ ${name} == "${bare_name}" ]]; then
          token_reason="token が無い (ブラウザのある端末で claude setup-token を打ち、このホストで claude-account set-token ${name} で入れる)"
        else
          token_reason="token が無い (claude setup-token で出し、このホストで claude-account set-token ${name} で入れる)"
        fi
        ;;
      bad) fix_reason="${fix_reason:+${fix_reason}。}token のファイルの ${tok_why}" ;;
      local)
        if ! local_file_ok "${conf_dir}/${name}.env"; then
          fix_reason="${fix_reason:+${fix_reason}。}token のファイルの${perm_why}"
        fi
        ;;
    esac
    # 入れた時刻 (set-token の控え)
    setat=$(times_get "${name}")
    # 控えの時刻は ISO 8601 の秒まで (set-token が書く形。Z か ±hh:mm) だけを読む。date -d は「last year」や時差の無い日付も読むので、先に形を見る
    if [[ ${setat} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]] \
      && set_epoch=$("${cu}/date" -d "${setat}" +%s 2>/dev/null); then
      days=$(((now - set_epoch) / 86400))
      setat=$(short_jst "${set_epoch}")
      if ((days > rotate_days)); then
        left=$((valid_days - days))
        if ((left > 0)); then
          rotate_reason="入れてから ${days} 日 (${rotate_days} 日を超えた。期限の 1 年まで残り ${left} 日)"
        else
          rotate_reason="入れてから ${days} 日 (${rotate_days} 日を超えた。期限の 1 年を過ぎている見込み)"
        fi
      fi
    elif [[ ${tok_state} == local || ${tok_state} == op ]]; then
      if [[ -n ${setat} ]]; then
        rotate_reason="入れた時刻の控えが読めない (同じ token を set-token で入れ直せば控えができる)"
      else
        mtime=$("${cu}/stat" -c '%Y' -- "${conf_dir}/${name}.env" 2>/dev/null) || mtime=""
        rotate_reason="入れた時刻の控えが無い (set-token で入れていない"
        if [[ ${tok_state} == op ]]; then
          rotate_reason+="。1Password から読む token は、1Password の項目の値を替えた日で見る"
        fi
        if [[ -n ${mtime} ]]; then
          rotate_reason+="。ファイルの時刻は $(short_jst "${mtime}")"
        fi
        rotate_reason+="。同じ token を set-token で入れ直せば控えができる)"
      fi
      setat="-"
    else
      setat="-"
    fi
    # 判定 (入れる > 直す > 回す > ok。宣言の無いものは宣言漏れ)
    if ((declared == 0)); then
      verdict=宣言漏れ
      if [[ ${name} == "${bare_name}" ]]; then
        reasons+=("宣言 (dotfiles.claude.tokens.${bare_name}) が無いのに、素の claude の token のファイルがある (素の claude は読まない。使うなら宣言に足し、要らなければ消す)")
      else
        reasons+=("宣言 (dotfiles.claude.tokens.${name}) が無い token の置き場 (回す対象から漏れている。宣言に足すか、要らなければ claude-account remove ${name} --purge)")
      fi
      [[ -z ${token_reason} ]] || reasons+=("${token_reason}")
      [[ -z ${fix_reason} ]] || reasons+=("${fix_reason}")
      [[ -z ${rotate_reason} ]] || reasons+=("${rotate_reason}")
    elif [[ -n ${missing_setup} || -n ${token_reason} ]]; then
      verdict=入れる
      if [[ -n ${missing_setup} ]]; then
        reasons+=("${missing_setup}")
      else
        reasons+=("${token_reason}")
      fi
      [[ -z ${fix_reason} ]] || reasons+=("${fix_reason}")
    elif [[ -n ${fix_reason} ]]; then
      verdict=直す
      reasons+=("${fix_reason}")
      [[ -z ${rotate_reason} ]] || reasons+=("${rotate_reason}")
    elif [[ -n ${rotate_reason} ]]; then
      verdict=回す
      reasons+=("${rotate_reason}")
    else
      verdict=ok
    fi
    key=${verdict_key[${verdict}]}
    count[${key}]=$((count[${key}] + 1))
    total=$((total + 1))
    echo "| ${shown_name} | ${label} | ${item} | ${src} | ${perm} | ${setat} | ${days} | ${verdict} |"
    for ((i = 0; i < ${#reasons[@]}; i++)); do
      if ((i == 0)); then
        bullets+=("- ${name}: ${verdict} — ${reasons[i]}")
      else
        bullets+=("  - ${reasons[i]}")
      fi
    done
  done
  echo
  if ((${#bullets[@]} > 0)); then
    printf '%s\n' "${bullets[@]}"
    echo
  fi
  if ((${#label_names[@]} > 0)); then
    while IFS= read -r label; do
      if [[ -n ${label} && ${label_names[${label}]} == *・* ]]; then
        echo "同じ token (呼び名 ${label}) を置いたアカウント: ${label_names[${label}]} (回すときは、どれも貼り直す)"
      fi
    done < <(printf '%s\n' "${!label_names[@]}" | LC_ALL=C "${cu}/sort")
  fi
  if ((decl_count > 0)); then
    echo "呼び名が同じ行は、ほかのホストの同じ呼び名の行とも同じ token。回すときは、その全部のホストで貼り直す。"
  fi
  echo "判定: ok ${count[ok]}・回す ${count[rotate]}・入れる ${count[insert]}・直す ${count[fix]}・宣言漏れ ${count[undeclared]}"
  if ((count[ok] == total)); then
    return 0
  fi
  return 1
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
    audit)
      shift
      cmd_audit "$@"
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

# 本物の claude を探して claude に入れる (mise 管理)。PATH の claude のうち、この script (素の claude の wrapper) でない最初のもの。
# シェルを通さずに起こされた (PATH に無い) ときは mise に実体を聞く。無ければ 1
find_claude() {
  local self c real
  claude=""
  self=$(self_path)
  while IFS= read -r c; do
    [[ -n ${c} ]] || continue
    real=$("${cu}/readlink" -f -- "${c}" 2>/dev/null) || real=${c}
    if [[ -n ${self} && ${real} == "${self}" ]]; then
      continue
    fi
    claude=${c}
    break
  done < <(type -ap claude 2>/dev/null)
  if [[ -z ${claude} ]] && command -v mise >/dev/null; then
    claude=$(mise which claude 2>/dev/null || true)
  fi
  if [[ -z ${claude} ]]; then
    err "$1: claude が見つかりません (mise で入れる: ~/dotfiles/setup --steps bootstrap-mise)。"
    return 1
  fi
}

# token を渡して claude を起こす。token を読む所はここだけ (使い心地で読み方を替えるときは、ここを直す)。$1 起こすコマンドの名前
# (claude-<名前> か claude)・$2 token のファイル。local: 読んだ値を export して exec。op: pjp-op-env が 1Password から読み、env に入れて exec
start_with_token() {
  local cmd=$1 file=$2
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
      export CLAUDE_ACCOUNT_STAGE="${cmd}"
      exec "${pjp_op_env}" --reason "${cmd} ${reason_tail}" --env-file "${file}" -- "${0}" __exec-with-token "${claude}" "$@"
      ;;
  esac
  err "${cmd}: token の読み方が決まりません (${tok_state})。"
  exit 1
}

# token のファイル $3 を読み、起こせないなら忠告を出して 1 で終わる ($1 起こすコマンド・$2 名前)。起こせるなら tok_state・tok_value が入る
load_token_or_exit() {
  local cmd=$1 name=$2 file=$3
  read_token_file "${file}"
  case ${tok_state} in
    missing)
      guidance "${cmd}" "${name}" "${file}" "$(shown "${file}") が無い"
      exit 1
      ;;
    noline)
      guidance "${cmd}" "${name}" "${file}" "$(shown "${file}") に CLAUDE_CODE_OAUTH_TOKEN の行が無い"
      exit 1
      ;;
    empty)
      guidance "${cmd}" "${name}" "${file}" "$(shown "${file}") の CLAUDE_CODE_OAUTH_TOKEN が空"
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
    load_token_or_exit "${cmd}" "${name}" "${file}"
  fi

  # このアカウントで動かす。/login の資格情報より優先される env (API キー・OAuth トークン) は外す
  unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
  export CLAUDE_CONFIG_DIR="${dir}"
  if [[ ${mode} == subscription ]]; then
    exec "${claude}" "$@"
  fi
  start_with_token "${cmd}" "${file}" "$@"
}

# 素の claude の wrapper (claude)。宣言のあるホストで、CLAUDE_CONFIG_DIR を付けずに起こされたら default の token を渡して本物の claude を
# 起こす (CLAUDE_CONFIG_DIR は付けない)。宣言の無いホスト・CLAUDE_CONFIG_DIR を付けて起こされたとき (claude-<名前> の launcher・T3 Code・
# bootstrap) は、何もせずに本物の claude を起こす
bare_launcher() {
  local file
  find_claude claude || exit 127
  if [[ ${bare_token} != 1 || -n ${CLAUDE_CONFIG_DIR-} ]]; then
    exec "${claude}" "$@"
  fi
  file="${conf_dir}/${bare_name}.env"
  load_token_or_exit claude "${bare_name}" "${file}"
  unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR
  start_with_token claude "${file}" "$@"
}

# --- 振り分け

me=${0##*/}

# op の道の次の段 (start_with_token が pjp-op-env 越しに起こす)。印 (CLAUDE_ACCOUNT_STAGE) が自分の名前のときだけ受ける
if [[ ${1-} == __exec-with-token && ${CLAUDE_ACCOUNT_STAGE-} == "${me}" && $# -ge 2 ]]; then
  unset CLAUDE_ACCOUNT_STAGE
  if ! token_ok "${CLAUDE_CODE_OAUTH_TOKEN-}" || [[ ${CLAUDE_CODE_OAUTH_TOKEN} == op://* ]]; then
    unset CLAUDE_CODE_OAUTH_TOKEN
    if [[ ${me} == claude ]]; then
      stage_name=${bare_name}
    else
      stage_name=${me#claude-}
    fi
    err "${me}: 1Password から読んだ値が token の形ではありません (空・空白・引用符など。値は出しません)。" \
      "  1Password の項目と欄を確かめるか、claude-account set-token ${stage_name} でこのマシンに token を置いてください。"
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
  claude)
    bare_launcher "$@"
    ;;
  claude-*)
    launcher "${me#claude-}" "$@"
    ;;
  *)
    err "claude-account: 呼ばれた名前 (${me}) が claude-account でも claude-<名前> でも claude でもありません。"
    exit 2
    ;;
esac
