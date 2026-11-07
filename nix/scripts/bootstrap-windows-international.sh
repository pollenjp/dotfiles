#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/international/managed.json の値だけを、Windows の日付と時刻の形式 (HKCU\Control Panel\International) へ書く (冪等。更新時も毎回走る)。
#
# order: 99
#
# ^ setup.sh が読む実行順。ほかの bootstrap が置くものは使わない。衝突で exit 1 すると setup は
#   ここで止まるので、Windows の bootstrap の後ろに置く。bootstrap-windows-terminal.sh と同じ 99 で、同じ値は
#   辞書順なのでこちらが先に走る (止まると、後ろの bootstrap-windows-terminal.sh・wsl-mtu-guard・exe-exec-trace と
#   最後の「残りの手作業」は走らない)。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows の短い日付・長い時刻・短い時刻の形式 (yyyy-MM-dd・HH:mm:ss・HH:mm) を dotfiles で持ち、どの PC でも
# 同じ形にする。設定画面で手で変わったら気づけるよう、bootstrap-windows-terminal.sh と同じく持つ値だけを書き、
# 前に書いた値の記録と比べて、衝突なら止まる (設計は dotfiles-private の
# docs/superpowers/specs/2026-11-07-windows-international-format-design.md)。
#
# 形式はユーザーごとのレジストリ HKCU\Control Panel\International の文字列 (sShortDate など) だが、レジストリを
# 直には書かない。Microsoft の文書のとおり SetLocaleInfoW で user override を書き、WM_SETTINGCHANGE (lParam は
# "intl") を送って、開いているアプリ (タスクバーの時計など) に読み直させる。地域 (en-US など) そのものと、
# 持たない値 (長い日付・通貨・小数点・週の始まりなど) は変えない。
#
# ## 何を読むか
#
# - ~/.local/state/dotfiles/windows-files.json (home-manager が置く)。bootstrap-windows-files.sh
#   と同じく、無ければ飛ばし、enable が false なら何もしない
# - この script がいる checkout の win/international/managed.json。キーはレジストリの値の名前、値は形式の
#   文字列。持てる名前は下の表 (table) にあるものだけ
# - Windows の今の値・地域の既定 (GetLocaleInfoEx に LOCALE_NOUSEROVERRIDE を付けた値)・地域の名前。pwsh.exe で読む
# - ~/.local/state/dotfiles/windows-international.applied.json (前回書いた値)。
#   {"version":1,"values":{"sShortDate":"yyyy-MM-dd",…}} の形
#
# ## 何をするか
#
# managed.json の値を 1 つずつ、Windows の今の値と記録で判定する:
#
#   今の値が managed.json と同じ                   何もしない (記録が無ければ記録だけする)
#   今の値が前回書いた値と同じ                     managed.json が更新された。書く
#   記録が無く、今の値が地域の既定と同じ           初めて書く (手で変えていない)。書く
#   それ以外                                       衝突。値を出して触らない (--force なら書く)
#
# 書くときは、衝突でない値を全部、pwsh.exe で表の順に SetLocaleInfoW で書き (同じ値も書き直す。ある値を書くと
# Windows が別の値を書き直す作りでも、持つ値に揃えて終わるよう)、WM_SETTINGCHANGE を送り、読み戻して比べる。
# 書けない (SetLocaleInfoW が失敗する) か、読み戻した値が managed.json と違えば ⚠ の枠で出して exit 1。記録は
# 書けた値だけ。WM_SETTINGCHANGE を送れないときは warn で知らせて進む (値は書けている)。managed.json から消した
# 値は、Windows 側では戻さない (記録からだけ消す。bootstrap-windows-terminal.sh と同じ)。
#
# 書かずに exit 0 で飛ばすのは、pwsh.exe が無いときと、読めない (WSL の interop が落ちている・JSON が返らない)
# とき。どちらも warn で知らせる。衝突は、値ごとに Windows 側・managed.json・前回書いた値・地域の既定を出し、
# ⚠ の枠で解き方を出して exit 1。
#
# --import は、衝突した値を Windows から managed.json へ取り込む (Windows には書かない)。managed.json を
# 書き換えるので、managed.json に commit していない変更があると止まる。
#
# ## pwsh.exe の呼び方
#
# PowerShell のコード (下の ps_body) は ASCII だけで書き、UTF-16LE の base64 にして -EncodedCommand で渡す。
# C# の P/Invoke ("kernel32.dll" など) の二重引用符が、WSL の interop の付ける引用符と混ざらないようにするため。
# ASCII なら UTF-16LE は 1 byte ごとに 0 を足すだけなので、coreutils の od と base64 で作れる。値は jq -a で
# \uXXXX にした JSON で埋めるので、日本語の形式も渡せる。返りは 1 行の JSON。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/international/managed.json の値だけを、Windows の日付と時刻の形式 (HKCU\Control Panel\International) へ書く。

使い方:
  bootstrap-windows-international.sh            書く (Windows 側で変わっていたら、衝突として止まる)
  bootstrap-windows-international.sh --dry-run  判定だけ出して何も書かない
  bootstrap-windows-international.sh --force    衝突も、managed.json の値で書く
  bootstrap-windows-international.sh --import   衝突した値を、Windows から managed.json へ取り込む
  bootstrap-windows-international.sh --check    managed.json の検証だけ (state も Windows も見ない)
EOS
}

force=0
dry_run=0
do_import=0
check=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    --import) do_import=1 ;;
    --check) check=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done
if ((check && (force || dry_run || do_import))); then
  echo "--check はほかの引数と一緒に使えません。" >&2
  exit 2
fi
if ((do_import && (force || dry_run))); then
  echo "--import は --force・--dry-run と一緒に使えません。" >&2
  exit 2
fi

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")
managed_rel="win/international/managed.json"
managed_file="${repo_dir}/${managed_rel}"
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-international.applied.json"

# 持てる値: レジストリの値の名前と、GetLocaleInfoEx・SetLocaleInfoW に渡す LCType (winnls.h の値)。
# 書くのもこの順にする (長い時刻を短い時刻より先に書く)。値を足すときは、ここに 1 行と managed.json に 1 行足す。
#   sShortDate   LOCALE_SSHORTDATE   0x0000001F  短い日付
#   sTimeFormat  LOCALE_STIMEFORMAT  0x00001003  長い時刻
#   sShortTime   LOCALE_SSHORTTIME   0x00000079  短い時刻
table='[
  {"name": "sShortDate", "lctype": 31},
  {"name": "sTimeFormat", "lctype": 4099},
  {"name": "sShortTime", "lctype": 121}
]'
# 形式の文字列の長さの上限 (終わりの NUL を含めて 80 字。LOCALE_SSHORTDATE・LOCALE_STIMEFORMAT の文書)
max_len=79

# ⚠ の枠を色付きで出すか。端末のときだけ (パイプや NO_COLOR では付けない)
if [[ -t 2 && -z ${NO_COLOR-} ]]; then
  c_warn=$'\e[1;33m'
  c_reset=$'\e[0m'
else
  c_warn=""
  c_reset=""
fi

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup.sh から走るときは、最後の「警告のまとめ」にも同じ行を残す (summary_warn)。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
  summary_warn "$@"
}

# setup.sh の最後の「警告のまとめ」にだけ警告を残す (その場には出さない。引数は warn と同じ)。
# setup.sh が手順ごとに DOTFILES_SETUP_WARNINGS でファイルを渡す。単体で流したときは何もしない。
summary_warn() {
  [[ -n ${DOTFILES_SETUP_WARNINGS-} ]] || return 0
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  { printf '%s\n' "${text//${nl}/${nl}   }" >>"${DOTFILES_SETUP_WARNINGS}"; } 2>/dev/null || true
}

# managed.json を確かめる。誤りがあれば理由を出して 1 を返す
validate_managed() {
  local err problems
  if [[ ! -f ${managed_file} ]]; then
    echo "!! ${managed_rel} がありません (${managed_file})。" >&2
    return 1
  fi
  if ! err=$(jq -e 'type == "object"' "${managed_file}" 2>&1 >/dev/null); then
    {
      echo "!! ${managed_rel} が JSON の object ではありません。"
      if [[ -n ${err} ]]; then
        printf '%s\n' "${err}" | sed 's/^/   /'
      fi
    } >&2
    return 1
  fi
  problems=$(jq -r --argjson table "${table}" --argjson max "${max_len}" '
    [$table[].name] as $known
    | to_entries[]
    | .key as $k
    | .value as $v
    | if ($k | IN($known[]) | not) then
        "知らない名前です: \($k) (持てるのは \($known | join("・")))"
      elif ($v | type) != "string" then
        "\($k) の値が文字列ではありません: \($v | tojson)"
      elif $v == "" then
        "\($k) の値が空です。"
      elif ($v | length) > $max then
        "\($k) の値が長すぎます (\($v | length) 字。\($max) 字まで)。"
      elif ($v | explode | any(. < 32 or . == 127)) then
        "\($k) の値に制御文字があります: \($v | tojson)"
      else empty end' "${managed_file}")
  if [[ -n ${problems} ]]; then
    {
      echo "!! ${managed_rel} に誤りがあります:"
      printf '%s\n' "${problems}" | sed 's/^/   /'
    } >&2
    return 1
  fi
}

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

if ((check)); then
  validate_managed || exit 1
  # --import は jq --indent 4 で書き直すので、手で書いた形も揃えておく (取り込みの差分に値以外が混ざらない)
  if ! jq --indent 4 . "${managed_file}" | cmp -s - "${managed_file}"; then
    echo "!! ${managed_rel} の形が jq --indent 4 の出力と違います (--import が書き直したときの差分を、値の変更だけにするため)。" >&2
    echo "   整えるには: jq --indent 4 . ${managed_rel} >${managed_rel}.tmp && mv ${managed_rel}.tmp ${managed_rel}" >&2
    exit 1
  fi
  echo "${managed_rel}: OK (持つ値 $(jq 'length' "${managed_file}") 件)"
  exit 0
fi

if [[ ! -r ${state_file} ]]; then
  warn "配り先の設定がありません: ${state_file}" \
    "dotfiles.wsl.windowsFiles を持つ世代へ先に home-manager switch してください。" \
    "この手順は飛ばします。"
  exit 0
fi
if ! jq -e 'type == "object"' "${state_file}" >/dev/null 2>&1; then
  echo "${state_file} が JSON の object ではありません。" >&2
  exit 1
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi

validate_managed || exit 1
count=$(jq 'length' "${managed_file}")

if [[ -e ${record_file} ]]; then
  if ! jq -e 'type == "object" and (.values | type == "object")' "${record_file}" >/dev/null 2>&1; then
    echo "!! ${record_file} が壊れています (values を持つ JSON の object ではありません)。" >&2
    echo "   消してから流し直すと、managed.json とも地域の既定とも違う値は衝突として扱われます" >&2
    echo "   (値を確かめて、--import で取り込むか --force)。" >&2
    exit 1
  fi
  records=$(jq -c . "${record_file}")
else
  records='{"version":1,"values":{}}'
fi

if ((count > 0)) && ! command -v pwsh.exe &>/dev/null; then
  warn "pwsh.exe が見つかりません (PowerShell 7 が無いか、WSL の PATH に Windows の PATH が入っていない)。" \
    "Windows の日付と時刻の形式を確かめられないので、この手順は飛ばします。"
  exit 0
fi

# 取り込みは managed.json を Windows の値で書き換える。commit していない変更 (未追跡も) があると痕跡なく
# 消えるので、何も書かずに止まる。git が無い・checkout の外で確かめられないときも止まる側に倒す
# (bootstrap-windows-terminal.sh と同じ)。
if ((do_import)); then
  if ! changes=$(git --no-optional-locks -C "${repo_dir}" status --porcelain --untracked-files=normal -- "${managed_rel}" 2>&1); then
    {
      echo "!! ${managed_rel} に commit していない変更が無いかを確かめられません (git が無いか、git の checkout ではない):"
      printf '%s\n' "${changes}" | sed 's/^/   /'
      echo "   --import は managed.json を書き換え、commit していない変更を消しうるので、止めます。"
    } >&2
    exit 1
  fi
  if [[ -n ${changes} ]]; then
    {
      echo "!! ${managed_rel} に commit していない変更があります。--import は managed.json を書き換えるので、先に commit するか、変更を戻してから流し直してください。"
      printf '%s\n' "${changes}" | sed 's/^/   /'
    } >&2
    exit 1
  fi
fi

tmp_file=""
ps_err_file=$(mktemp "${TMPDIR:-/tmp}/bootstrap-windows-international.XXXXXX")
trap 'rm -f "${ps_err_file}"; if [[ -n ${tmp_file} ]]; then rm -f "${tmp_file}"; fi' EXIT

# PowerShell のコードを、pwsh.exe の -EncodedCommand に渡す形 (UTF-16LE の base64) にする。ASCII だけを受け、
# ASCII の外の文字があれば 1 を返す (ASCII なら UTF-16LE は 1 byte ごとに 0 を足すだけになる)
encode_ps() {
  local LC_ALL=C hex bytes
  if [[ $1 == *[![:ascii:]]* ]]; then
    return 1
  fi
  hex=$(printf '%s' "$1" | od -An -v -tx1)
  read -r -d '' -a bytes <<<"${hex}" || true
  # 書式は \xHH の並びだけで、% を含まない
  # shellcheck disable=SC2059
  printf "$(printf '\\x%s\\x00' "${bytes[@]}")" | base64 -w0
}

# pwsh.exe で流す PowerShell のコード (ASCII だけで書く)。run_ps が先頭に $Mode ('read' か 'write') と
# $InputJson ([{"name","lctype"}]。write なら各要素に "value" と "write" も) の 2 行を足して渡す。返りは 1 行の JSON:
#   {"locale":"en-US","values":[{"name","current","default"}],"failed":[{"name","error"}],"broadcast":null か {"ok","error"}}
# write は、"write" が真の値を並びの順に SetLocaleInfoW で書き (失敗は Win32 のエラーを failed へ)、1 つでも書けたら
# WM_SETTINGCHANGE を送る (broadcast)。どちらの mode も最後に全部の値を読み直して返す。今の値は GetLocaleInfoEx に
# LOCALE_NAME_USER_DEFAULT (NULL) を渡して読む。pwsh は string の引数に渡した $null を空文字列 (invariant の地域) に
# するので、[NullString]::Value で渡す。地域の既定は LCType に LOCALE_NOUSEROVERRIDE (0x80000000) を足して読む。
IFS= read -r -d '' ps_body <<'EOS' || true
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -Namespace DotfilesIntl -Name Nls -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int GetLocaleInfoEx(string lpLocaleName, uint LCType, System.Text.StringBuilder lpLCData, int cchData);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SetLocaleInfoW(uint Locale, uint LCType, string lpLCData);
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
function Get-Nls([uint32]$LCType) {
  $buf = [System.Text.StringBuilder]::new(128)
  if ([DotfilesIntl.Nls]::GetLocaleInfoEx([NullString]::Value, $LCType, $buf, $buf.Capacity) -eq 0) {
    throw ('GetLocaleInfoEx(0x{0:X}) failed: Win32 error {1}' -f $LCType, [Runtime.InteropServices.Marshal]::GetLastWin32Error())
  }
  $buf.ToString()
}
$entries = @(ConvertFrom-Json -InputObject $InputJson)
$failed = @()
$broadcast = $null
if ($Mode -eq 'write') {
  $wrote = 0
  foreach ($e in $entries) {
    if (-not $e.write) { continue }
    # Locale = LOCALE_USER_DEFAULT (0x0400). The W version ignores it.
    if ([DotfilesIntl.Nls]::SetLocaleInfoW(0x0400, [uint32]$e.lctype, [string]$e.value)) {
      $wrote++
    } else {
      $failed += [ordered]@{ name = $e.name; error = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
    }
  }
  if ($wrote -gt 0) {
    # WM_SETTINGCHANGE (0x001A) to HWND_BROADCAST (0xFFFF), lParam "intl", SMTO_ABORTIFHUNG (0x0002), 5000 ms
    $res = [UIntPtr]::Zero
    $ok = [DotfilesIntl.Nls]::SendMessageTimeoutW([IntPtr]0xFFFF, 0x001A, [UIntPtr]::Zero, 'intl', 0x0002, 5000, [ref]$res) -ne [IntPtr]::Zero
    $code = 0
    if (-not $ok) { $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
    $broadcast = [ordered]@{ ok = $ok; error = $code }
  }
}
$values = @(foreach ($e in $entries) {
    [ordered]@{
      name = $e.name
      current = Get-Nls ([uint32]$e.lctype)
      default = Get-Nls ([uint32]$e.lctype + [uint32]2147483648)
    }
  })
# LOCALE_SNAME (0x5C) is the name of the locale (en-US).
[ordered]@{ locale = Get-Nls 0x5C; values = $values; failed = $failed; broadcast = $broadcast } |
  ConvertTo-Json -Compress -Depth 4 -EscapeHandling EscapeNonAscii
EOS

# pwsh.exe で PowerShell のコードを流す。$1: read か write、$2: 入力の JSON。
# stdout (CR を落とす) を ps_out に、stderr (CR を落とす) を ps_err に、終了コード (時間切れは 124) を ps_rc に入れる。
# 値は jq -a で ASCII にし (日本語は \uXXXX)、PowerShell の '' の文字列に入れる (中の ' は '' に)。
run_ps() {
  local input quoted enc
  input=$(jq -c -a . <<<"$2")
  quoted=${input//\'/\'\'}
  if ! enc=$(encode_ps "\$Mode = '$1'"$'\n'"\$InputJson = '${quoted}'"$'\n'"${ps_body}"); then
    echo "!! pwsh.exe に渡すコードに ASCII の外の文字があります (script の誤り)。" >&2
    exit 1
  fi
  ps_rc=0
  ps_out=$(timeout 60 pwsh.exe -NoProfile -NonInteractive -EncodedCommand "${enc}" </dev/null 2>"${ps_err_file}") || ps_rc=$?
  ps_out=${ps_out//$'\r'/}
  ps_err=$(tr -d '\r' <"${ps_err_file}")
}

# 記録に値を書く (書いた値か、もう同じだった値)。$1: 名前、$2: 値
remember() {
  records=$(jq -c --arg n "$1" --arg v "$2" '.values[$n] = $v' <<<"${records}")
}

# 置き先と同じディレクトリの一時ファイルに書いてから mv する。$1 = 置き先、残り = 中身を出すコマンド
# (bootstrap-windows-terminal.sh と同じ。落ちたら set -e で止まり、一時ファイルは trap が消す)
place() {
  local dst=$1
  shift
  tmp_file=$(mktemp "${dst}.dotfiles-tmp.XXXXXX")
  "$@" >"${tmp_file}"
  mv -f -- "${tmp_file}" "${dst}"
  tmp_file=""
}

locale=""
plan='[]'
if ((count > 0)); then
  read_input=$(jq -c --slurpfile managed "${managed_file}" \
    'map(select(.name as $n | $managed[0] | has($n)) | {name, lctype})' <<<"${table}")
  run_ps read "${read_input}"
  if ((ps_rc != 0)); then
    if ((ps_rc == 124)); then
      headline="pwsh.exe が 60 秒たっても終わりませんでした (時間切れ。WSL の interop が止まっているかもしれません)。"
    else
      headline="pwsh.exe で Windows の日付と時刻の形式を読めませんでした (終了コード ${ps_rc}。WSL の interop が落ちているかもしれません):"
    fi
    warn "${headline}" ${ps_err:+"${ps_err}"} "この手順は飛ばします。"
    exit 0
  fi
  # 返りは、頼んだ名前の全部に今の値と地域の既定 (文字列) があり、地域の名前を持つ JSON
  if ! jq -e --argjson input "${read_input}" '
      (.locale | type) == "string"
      and ([.values[]? | select((.name | type) == "string" and (.current | type) == "string" and (.default | type) == "string")
        | .name] | sort) == ([$input[].name] | sort)' <<<"${ps_out}" >/dev/null 2>&1; then
    warn "pwsh.exe の返りが、決めた形の JSON ではありません:" ${ps_out:+"${ps_out}"} ${ps_err:+"${ps_err}"} "この手順は飛ばします。"
    exit 0
  fi
  locale=$(jq -r '.locale' <<<"${ps_out}")

  # 計画: 持つ値ごとに 1 つ (表の順)。action は same / update / add / conflict
  plan=$(jq -c -n \
    --argjson table "${table}" \
    --slurpfile managed "${managed_file}" \
    --argjson win "${ps_out}" \
    --argjson records "${records}" '
    $managed[0] as $m
    | [$table[]
      | select(.name as $n | $m | has($n))
      | .name as $n
      | ($win.values[] | select(.name == $n)) as $w
      | {
          name: $n,
          lctype,
          want: $m[$n],
          cur: $w.current,
          def: $w.default,
          has_rec: ($records.values | has($n)),
          rec: $records.values[$n]
        }
      | .action = (
          if .cur == .want then "same"
          elif .has_rec and .cur == .rec then "update"
          elif (.has_rec | not) and .cur == .def then "add"
          else "conflict" end)]')
fi

# 衝突した値の、Windows 側・managed.json・前回書いた値・地域の既定を出す ($1 = 計画の 1 つ)
report_conflict() {
  local e=$1 key
  key=$(jq -r '.name' <<<"${e}")
  {
    if jq -e '.has_rec | not' <<<"${e}" >/dev/null; then
      echo "!! 衝突: ${key} は、書いた記録が無く、地域 (${locale}) の既定とも違います (この script が書く前に、設定画面で変えた・手で設定してあった)。"
    elif jq -e '.cur == .def' <<<"${e}" >/dev/null; then
      echo "!! 衝突: ${key} は、前回書いた値から地域 (${locale}) の既定に戻っています (地域を変えた・設定画面で既定に戻した、など)。"
    else
      echo "!! 衝突: ${key} は Windows 側で変わっています (前回書いた値と違う。設定画面で変えた、など)。"
    fi
    jq -r '
      "   Windows 側:    \(.cur | tojson)",
      "   managed.json:  \(.want | tojson)",
      (if .has_rec then "   前回書いた値:  \(.rec | tojson)" else empty end),
      "   地域の既定:    \(.def | tojson)"' <<<"${e}"
  } >&2
}

log=()
conflicts=()
imports=()
pending=()
write_names=()
need_write=0
pre=""
if ((dry_run)); then
  pre="[dry-run] "
fi

while IFS= read -r entry; do
  if [[ -z ${entry} ]]; then
    continue
  fi
  action=$(jq -r '.action' <<<"${entry}")
  key=$(jq -r '.name' <<<"${entry}")
  if [[ ${action} == conflict ]] && ((force)); then
    action=force
  fi
  case ${action} in
    same)
      write_names+=("${key}")
      if ((! dry_run)) && ! jq -e '.has_rec and .rec == .want' <<<"${entry}" >/dev/null; then
        remember "${key}" "$(jq -r '.want' <<<"${entry}")"
      fi
      ;;
    add | update | force)
      if ((do_import)); then
        pending+=("${key}")
        continue
      fi
      case ${action} in
        add) label="初めて書く。今の値は地域の既定" ;;
        update) label="managed.json が更新された" ;;
        force) label="--force" ;;
      esac
      write_names+=("${key}")
      need_write=1
      log+=("  ${pre}${key}: $(jq -r '"\(.cur | tojson) → \(.want | tojson)"' <<<"${entry}") (${label})")
      ;;
    conflict)
      conflicts+=("${key}")
      if ((do_import)); then
        imports+=("${entry}")
      else
        report_conflict "${entry}"
      fi
      ;;
  esac
done <<<"$(jq -c '.[]' <<<"${plan}")"

# 書く。衝突でない値を全部、表の順に書き直す (同じ値も。ある値を書くと Windows が別の値を書き直す作りでも、
# 持つ値に揃えて終わるよう)。書いた値は読み戻して比べ、揃った値だけを記録する
failures=()
broadcast_note=""
if ((need_write && ! dry_run)); then
  names_json=$(printf '%s\n' "${write_names[@]}" | jq -R . | jq -c -s .)
  write_input=$(jq -c --argjson w "${names_json}" \
    'map({name, lctype, value: .want, write: (.name | IN($w[]))})' <<<"${plan}")
  run_ps write "${write_input}"
  if ((ps_rc != 0)) || ! jq -e '(.values | type) == "array" and (.failed | type) == "array"' <<<"${ps_out}" >/dev/null 2>&1; then
    failures+=("書く途中で pwsh.exe が失敗しました (終了コード ${ps_rc})。どの値が書けたかは分からないので、記録していません。")
    if [[ -n ${ps_err} ]]; then
      failures+=("${ps_err}")
    fi
    failures+=("もう一度流すと、読み直して判定します。")
  else
    for key in "${write_names[@]}"; do
      want=$(jq -r --arg n "${key}" '.[] | select(.name == $n) | .want' <<<"${plan}")
      err=$(jq -r --arg n "${key}" '.failed[] | select(.name == $n) | .error' <<<"${ps_out}")
      if [[ -n ${err} ]]; then
        hint=""
        if [[ ${err} == 1260 ]]; then
          hint="。グループポリシーで止められています"
        fi
        failures+=("${key}: 書けませんでした (Win32 のエラー ${err}${hint})")
        continue
      fi
      got=$(jq -r --arg n "${key}" '.values[] | select(.name == $n) | .current' <<<"${ps_out}")
      if [[ ${got} != "${want}" ]]; then
        failures+=("${key}: 書いた後に読み戻すと $(jq -rn --arg v "${got}" '$v | tojson') で、managed.json の $(jq -rn --arg v "${want}" '$v | tojson') と違います")
        continue
      fi
      remember "${key}" "${want}"
    done
    if jq -e '.broadcast.ok == true' <<<"${ps_out}" >/dev/null; then
      broadcast_note="  WM_SETTINGCHANGE (intl) を送りました。開いているアプリ (タスクバーの時計など) は、その場で読み直します。"
    elif jq -e '.broadcast != null' <<<"${ps_out}" >/dev/null; then
      warn "WM_SETTINGCHANGE を送れませんでした (Win32 のエラー $(jq -r '.broadcast.error' <<<"${ps_out}"))。値は書けています。" \
        "開いているアプリ (タスクバーの時計など) には、サインアウトしてサインインし直すと効きます。"
    fi
  fi
fi

if ((do_import && ${#imports[@]} > 0)); then
  imp=$(printf '%s\n' "${imports[@]}" | jq -c -s '.')
  # jq の $imp は jq の変数 (place 越しなので、shellcheck には jq の引数と分からない)
  # shellcheck disable=SC2016
  place "${managed_file}" jq --indent 4 --argjson imp "${imp}" 'reduce $imp[] as $e (.; .[$e.name] = $e.cur)' "${managed_file}"
  records=$(jq -c --argjson imp "${imp}" 'reduce $imp[] as $e (.; .values[$e.name] = $e.cur)' <<<"${records}")
fi

# 記録を書く (変わったときだけ。--dry-run では書かない)。managed.json から消した値は記録からも消す。
# 記録が無く、書くものも無いときは作らない
if ((! dry_run)); then
  records=$(jq -c --slurpfile managed "${managed_file}" \
    '.values |= with_entries(select(.key as $k | $managed[0] | has($k)))' <<<"${records}")
  new_records=$(jq -S '.version = 1' <<<"${records}")
  old_records=""
  if [[ -f ${record_file} ]]; then
    old_records=$(jq -S . "${record_file}")
  fi
  if [[ ${new_records} != "${old_records}" ]] && { [[ -f ${record_file} ]] || jq -e '.values != {}' <<<"${records}" >/dev/null; }; then
    mkdir -p "${state_dir}"
    place "${record_file}" printf '%s\n' "${new_records}"
  fi
fi

if ((do_import)); then
  if ((${#imports[@]} == 0)); then
    echo "取り込むものはありません (衝突している値がありません)。"
  else
    echo "==> Windows の値を ${managed_rel} へ取り込みました"
    printf '  %s\n' "${conflicts[@]}"
    echo "git -C ${repo_dir} diff -- ${managed_rel} で見て commit してください。"
  fi
  if ((${#pending[@]} > 0)); then
    echo "managed.json の値で Windows へ書く値が ${#pending[@]} 件あります (取り込みでは書きません):"
    printf '  %s\n' "${pending[@]}"
    echo "引数なしで流し直すと書きます: ${script_dir}/bootstrap-windows-international.sh"
  fi
  exit 0
fi

if ((${#log[@]} == 0 && ${#conflicts[@]} == 0 && ${#failures[@]} == 0)); then
  echo "Windows の日付と時刻の形式は揃っています (持つ値 ${count} 件${locale:+。地域 ${locale}})。"
  exit 0
fi

if ((${#log[@]} > 0)); then
  echo "==> ${pre}Windows の日付と時刻の形式 (地域 ${locale})"
  printf '%s\n' "${log[@]}"
  if [[ -n ${broadcast_note} ]]; then
    echo "${broadcast_note}"
  fi
fi

if ((${#conflicts[@]} == 0 && ${#failures[@]} == 0)); then
  exit 0
fi

rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
{
  printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  printf '%s⚠️  Windows の日付と時刻の形式に、手で直すことがあります%s\n' "${c_warn}" "${c_reset}"
  if ((${#conflicts[@]} > 0)); then
    printf '%s⚠️  Windows 側で変わっていた (か、書く前から手で設定してあった) ので、次の値には触っていません (値は上):%s\n' "${c_warn}" "${c_reset}"
    for key in "${conflicts[@]}"; do
      printf '%s⚠️    %s%s\n' "${c_warn}" "${key}" "${c_reset}"
    done
    printf '%s⚠️  解き方 (どちらか):%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️    1. Windows 側の値を残す: managed.json へ取り込み、commit して push する%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️       %s/bootstrap-windows-international.sh --import%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
    printf '%s⚠️    2. managed.json の値で書く:%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️       %s/bootstrap-windows-international.sh --force%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
  fi
  if ((${#failures[@]} > 0)); then
    printf '%s⚠️  次の値は書けませんでした (書けた値は記録してあります):%s\n' "${c_warn}" "${c_reset}"
    for line in "${failures[@]}"; do
      while IFS= read -r l; do
        printf '%s⚠️    %s%s\n' "${c_warn}" "${l}" "${c_reset}"
      done <<<"${line}"
    done
  fi
  printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
} >&2
exit 1
