#!/usr/bin/env bash
# shellcheck shell=bash
#
# dotfiles-private の ssh/port-forward.toml (ssh の Host 名ごとの port forwarding の組) を JSON にして、Windows の %USERPROFILE%\.config\port-forward\hosts.json に置く (冪等。更新時も毎回走る)。
#
# order: 99
#
# ^ setup.sh が読む実行順。ほかの bootstrap が置くものを使わない (コピー元を取る bootstrap-dotfiles-private.sh (50)
#   より後ならよい)。同じ 99 は辞書順で、bootstrap-windows-international.sh の後・bootstrap-windows-terminal.sh の前に
#   走る。正本の誤りや衝突で exit 1 すると setup はここで止まる (後ろの bootstrap-windows-terminal.sh と
#   wsl-mtu-guard・exe-exec-trace、最後の「残りの手作業」は、直して流し直すまで走らない)。仕組みは
#   nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows の PowerShell 7 のコマンド pf (win/port-forward/Start-PortForward.ps1) は、ssh の Host を選んだ次の画面に
# port forwarding の組を出す。組はホストごとにほぼ決まっていて、どの Windows の PC でも同じものを使うので、正本を
# private な dotfiles-private の 1 ファイルに置き、この手順が PowerShell の読める JSON にして Windows へ写す
# (設計は dotfiles-private の docs/superpowers/specs/2026-11-07-pf-port-forward-design.md)。その PC で足した組は
# pf が同じ場所の local.json に持ち、この手順は触らない。
#
# ## 何を読むか
#
# - ~/.local/state/dotfiles/windows-files.json (home-manager が置く)。bootstrap-windows-files.sh と同じく、無ければ
#   飛ばし、enable が false なら何もしない
# - dotfiles-private の ssh/port-forward.toml。場所の決め方は bootstrap-dotfiles-private.sh と同じ。無ければ何もせずに
#   exit 0 (dotfiles-private を取れていないだけのことがあるので、Windows の hosts.json も消さない)。
#   nix-instantiate の builtins.fromTOML で読む (win/manifest.toml を読む bootstrap-windows-files.sh と同じ道具)
# - ~/.local/state/dotfiles/windows-port-forward.deployed.json (前回置いた中身の sha256)。
#   {"version":1,"files":{"hosts.json":"<sha256>"}} の形
#
# ## 何を確かめるか (どれかに合わなければ、何も書かずに誤りを全部並べて exit 1)
#
#   [hosts] の表の下に、キー = ssh の Host 名、値 = 組の書き方の文字列の配列
#   - 最上位のキーは hosts だけ。Host 名は空でなく、空白・* ? ! を含まず、- で始まらない
#   - 書き方は <手元の port>[:[<つなぎ先>:]<向こうの port>][ <メモ>] (port は 1〜65535。pf の ConvertFrom-PortSpec と同じ)
#   - 同じ Host の中で手元の port が重ならない (ssh -L は同じ手元の port を 2 つ張れない。pf は行を手元の port で見分ける)
#
# ## 何をするか
#
# 書く中身 ({"version":1,"note":…,"hosts":{…}} を jq --indent 2 で。組は前後の空白だけ落とす) と、置き先と記録を
# 比べて決める (bootstrap-windows-ssh-config.sh と同じ):
#
#   置き先が無い                              書く
#   置き先が書く中身と同じ                    何もしない (記録が無ければ記録だけする)
#   置き先が記録と同じ中身 (書く中身とは違う) 正本が更新された。上書きする
#   それ以外                                  衝突。diff を出して触らない (--force なら元を退避して上書き)
#
# 衝突のメッセージは、記録があれば「Windows 側で変わった」、無ければ「置いた記録が無く」と分けて出す。
# 退避は hosts.json.dotfiles-bak-<日時>、一時ファイルは hosts.json.dotfiles-tmp.XXXXXX。

set -eu -o pipefail

usage() {
  cat <<'EOS'
dotfiles-private の ssh/port-forward.toml を JSON にして、Windows の %USERPROFILE%\.config\port-forward\hosts.json に置く。

使い方:
  bootstrap-windows-port-forward.sh            置く
  bootstrap-windows-port-forward.sh --dry-run  判定だけ出して何も書かない
  bootstrap-windows-port-forward.sh --force    衝突でも、元を hosts.json.dotfiles-bak-<日時> に退避して上書きする
  bootstrap-windows-port-forward.sh --check    正本を読んで確かめるだけ (Windows の側も記録も見ない)
EOS
}

force=0
dry_run=0
check_only=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    --check) check_only=1 ;;
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
if ((check_only && (force || dry_run))); then
  echo "--check はほかの引数と一緒に使えません。" >&2
  usage >&2
  exit 2
fi

script_dir=$(
  cd -- "$(dirname -- "$0")" &>/dev/null
  pwd -P
)
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-port-forward.deployed.json"
note='dotfiles の nix/scripts/bootstrap-windows-port-forward.sh が dotfiles-private の ssh/port-forward.toml から書く。手で直すと次の setup で衝突になる。この PC だけの組は pf の画面で足す (local.json に残る)'

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

# dotfiles-private の clone の場所 (bootstrap-dotfiles-private.sh と同じ決め方)
private_dir() {
  local root
  if [[ -n ${DOTFILES_PRIVATE_DIR:-} ]]; then
    printf '%s' "${DOTFILES_PRIVATE_DIR%/}"
  elif root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/github.com/pollenjp/dotfiles-private' "${root}"
  else
    printf '%s/ghq/github.com/pollenjp/dotfiles-private' "${HOME}"
  fi
}

need() {
  if ! command -v "$1" &>/dev/null; then
    echo "$1 が見つかりません。$2" >&2
    exit 1
  fi
}

# 組の書き方 (pf の ConvertFrom-PortSpec と同じ正規表現。名前付きの組で手元 l・つなぎ先 h・向こう r・メモ m)。
# 数字は [0-9] で書く (jq の \d は全角などの Unicode の数字にも合い、tonumber で落ちる)
# shellcheck disable=SC2016 # jq のプログラム ($h などは jq の変数)
jq_defs='
def spec_re: "^\\s*(?<l>[0-9]{1,5})(?::(?:(?<h>\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9._-]+):)?(?<r>[0-9]{1,5}))?(?:\\s+(?<m>.*?))?\\s*$";
def in_range: (tonumber) as $p | $p >= 1 and $p <= 65535;
'

# 正本を読んだ JSON の誤りを 1 行ずつ出す (無ければ何も出さない)
# shellcheck disable=SC2016 # jq のプログラム
jq_errors="${jq_defs}"'
if type != "object" then "最上位が表ではありません"
else
  (keys_unsorted - ["hosts"] | .[] | "知らないキーがあります: \(.) (書けるのは [hosts] の表だけ)"),
  if has("hosts") | not then "[hosts] の表がありません"
  elif (.hosts | type) != "object" then "hosts は表にする ([hosts] の下に Host 名 = [\"3000\", …])"
  else
    .hosts | to_entries[] | .key as $h | .value as $v |
    (if ($h | length) == 0 then "Host 名が空です"
     elif ($h | test("[\\s*?!]")) then "Host 名に空白・* ? ! は使えません: \($h)"
     elif ($h | startswith("-")) then "Host 名は - で始められません: \($h)"
     else empty end),
    (if ($v | type) == "object" then
       "\($h): 値が配列ではありません (Host 名に . を含むなら \"…\" で囲む。囲まないと TOML の入れ子の表になる)"
     elif ($v | type) != "array" then "\($h): 値は文字列の配列にする"
     else
       ($v | to_entries[] | .key as $i | .value as $s |
         if ($s | type) != "string" then "\($h): \($i + 1) 番目が文字列ではありません: \($s | tojson)"
         elif ($s | test(spec_re) | not) then "\($h): 書き方が違います: \($s)"
         elif ($s | capture(spec_re) | (.l | in_range) and ((.r // .l) | in_range) | not) then
           "\($h): port は 1〜65535 で書いてください: \($s)"
         else empty end),
       ([$v[] | strings | select(test(spec_re)) | capture(spec_re)
         | select((.l | in_range) and ((.r // .l) | in_range)) | .l | tonumber]
         | group_by(.) | map(select(length > 1) | .[0]) | .[]
         | "\($h): 手元の port が重なっています: \(.)")
     end)
  end
end
'

# 書く中身 (hosts.json)。組は前後の空白だけ落とす
# shellcheck disable=SC2016 # jq のプログラム
jq_render='{version: 1, note: $note, hosts: (.hosts | map_values(map(gsub("^\\s+"; "") | gsub("\\s+$"; ""))))}'

src="$(private_dir)/ssh/port-forward.toml"
if [[ ${src} != /* ]]; then
  src="${PWD}/${src}"
fi

# 正本を読んで確かめ、書く中身を $1 に書く。誤りは stderr に並べて 1 を返す
build() {
  local out=$1 json errors
  if ! json=$(nix-instantiate --eval --strict --json --argstr file "${src}" \
    --expr '{ file }: builtins.fromTOML (builtins.readFile (/. + file))'); then
    echo "!! ${src} を TOML として読めませんでした (上の nix-instantiate のエラーを見てください)。何も書いていません。" >&2
    return 1
  fi
  # 確かめの jq が落ちたら、誤りが無いのと区別がつかないので止まる (set -e は if の中の関数では効かない)
  if ! errors=$(jq -r "${jq_errors}" <<<"${json}"); then
    echo "!! ${src} を確かめられませんでした (上の jq のエラーを見てください)。何も書いていません。" >&2
    return 1
  fi
  if [[ -n ${errors} ]]; then
    {
      echo "!! ${src} に誤りがあります。何も書いていません:"
      while IFS= read -r line; do
        echo "   ${line}"
      done <<<"${errors}"
    } >&2
    return 1
  fi
  jq --indent 2 --arg note "${note}" "${jq_render}" <<<"${json}" >"${out}"
}

# Host と組の数 ($1 = 書く中身)
counts() {
  jq -r '"Host \(.hosts | length) 件・組 \([.hosts[] | length] | add // 0) 件"' "$1"
}

work=$(mktemp -d)
tmp_file=""
trap 'rm -rf "${work}"; if [[ -n ${tmp_file} ]]; then rm -f "${tmp_file}"; fi' EXIT

if ((check_only)); then
  need jq "jq を入れてから打ち直してください。"
  need nix-instantiate "Nix が入っていないか、PATH に無い。"
  if [[ ! -f ${src} ]]; then
    echo "!! 正本がありません: ${src}" >&2
    exit 1
  fi
  if ! build "${work}/hosts.json"; then
    exit 1
  fi
  echo "ssh/port-forward.toml: OK ($(counts "${work}/hosts.json"))"
  exit 0
fi

need jq "先に home-manager switch を実行してください。"

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
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  echo "Windows 側のホームが見えません: ${windows_home:-(windowsHome が空)}" >&2
  echo "  /mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。" >&2
  exit 1
fi

if [[ ! -f ${src} ]]; then
  echo "port forwarding の組の正本がないので、Windows へは写しません (${src})。"
  exit 0
fi

need nix-instantiate "Nix が入っていないか、PATH に無い。"
need sha256sum "置き先の中身を比べられないので写せません (coreutils)。"

if [[ -e ${record_file} ]]; then
  if ! jq -e 'type == "object" and (.files | type == "object")' "${record_file}" >/dev/null 2>&1; then
    echo "!! ${record_file} が壊れています (files を持つ JSON の object ではありません)。" >&2
    echo "   消してから流し直すと、Windows 側に既にある hosts.json は衝突として扱われます" >&2
    echo "   (中身を確かめて、dotfiles-private へ取り込むか --force)。" >&2
    exit 1
  fi
  records=$(jq -c . "${record_file}")
else
  records='{"version":1,"files":{}}'
fi

if ! build "${work}/hosts.json"; then
  exit 1
fi

sha() {
  sha256sum <"$1" | cut -d' ' -f1
}

dst="${windows_home}/.config/port-forward/hosts.json"
want=$(sha "${work}/hosts.json")
rec=$(jq -r '.files["hosts.json"] // ""' <<<"${records}")
pre=""
if ((dry_run)); then
  pre="[dry-run] "
fi

if [[ -d ${dst} ]]; then
  echo "!! 置き先がディレクトリです: ${dst}" >&2
  exit 1
fi
if [[ ! -e ${dst} ]]; then
  action=copy
else
  have=$(sha "${dst}")
  if [[ ${have} == "${want}" ]]; then
    action=same
  elif [[ -n ${rec} && ${have} == "${rec}" ]]; then
    action=update
  elif ((force)); then
    action=force
  else
    action=conflict
  fi
fi

# 記録を書く (変わったときだけ。--dry-run では書かない)
save_record() {
  local new_records old_records=""
  ((dry_run)) && return 0
  new_records=$(jq -S --arg v "${want}" '.version = 1 | .files["hosts.json"] = $v' <<<"${records}")
  if [[ -f ${record_file} ]]; then
    old_records=$(jq -S . "${record_file}")
  fi
  if [[ ${new_records} != "${old_records}" ]]; then
    mkdir -p "${state_dir}"
    tmp_file=$(mktemp "${record_file}.XXXXXX")
    printf '%s\n' "${new_records}" >"${tmp_file}"
    mv -f -- "${tmp_file}" "${record_file}"
    tmp_file=""
  fi
}

case ${action} in
  same)
    save_record
    echo "Windows の port forwarding の組は揃っています ($(counts "${work}/hosts.json"))。"
    exit 0
    ;;
  conflict)
    {
      if [[ -n ${rec} ]]; then
        echo "!! 衝突: ${dst} は Windows 側で変わっています (前回ここへ置いた中身と違う)。"
      else
        echo "!! 衝突: ${dst} は、置いた記録が無く、正本と中身が違います (この script が置く前から Windows 側にあった。手で書いたものなど)。"
      fi
      diff -u --label "hosts.json (Windows 側)" --label "hosts.json (dotfiles-private の ssh/port-forward.toml から)" -- "${dst}" "${work}/hosts.json" || true
      rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
      printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
      printf '%s⚠️  Windows の port forwarding の組 (hosts.json) に触っていません (diff は上):%s\n' "${c_warn}" "${c_reset}"
      printf '%s⚠️    %s%s\n' "${c_warn}" "${dst}" "${c_reset}"
      printf '%s⚠️  解き方 (どちらか):%s\n' "${c_warn}" "${c_reset}"
      printf '%s⚠️    1. Windows 側の中身を dotfiles-private の ssh/port-forward.toml へ取り込み、commit して push する%s\n' "${c_warn}" "${c_reset}"
      printf '%s⚠️       (その PC だけの組は、pf の画面で足すと local.json に残る)%s\n' "${c_warn}" "${c_reset}"
      printf '%s⚠️    2. 上書きする (元は hosts.json.dotfiles-bak-<日時> に残る):%s\n' "${c_warn}" "${c_reset}"
      printf '%s⚠️       %s/bootstrap-windows-port-forward.sh --force%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
      printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
    } >&2
    exit 1
    ;;
esac

case ${action} in
  copy) label="新しく置く ($(counts "${work}/hosts.json"))" ;;
  update) label="上書き (正本が更新された)" ;;
  force) label="上書き (--force)" ;;
esac
log=()
if ((! dry_run)); then
  mkdir -p "$(dirname -- "${dst}")"
  if [[ ${action} == force ]]; then
    bak="${dst}.dotfiles-bak-$(date +%Y%m%d-%H%M%S)"
    cp -p -- "${dst}" "${bak}"
    log+=("  退避した: ${bak}")
  fi
  tmp_file=$(mktemp "${dst}.dotfiles-tmp.XXXXXX")
  cp -- "${work}/hosts.json" "${tmp_file}"
  mv -f -- "${tmp_file}" "${dst}"
  tmp_file=""
fi
save_record
echo "==> ${pre}Windows の port forwarding の組 (${dst})"
echo "  ${pre}hosts.json: ${label}"
if ((${#log[@]} > 0)); then
  printf '%s\n' "${log[@]}"
fi
