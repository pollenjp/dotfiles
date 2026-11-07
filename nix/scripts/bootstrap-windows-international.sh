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

echo "まだ書けません (--check だけ)。" >&2
exit 1
