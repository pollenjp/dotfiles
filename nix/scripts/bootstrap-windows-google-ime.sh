#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の Google 日本語入力の設定とユーザー辞書を、repo のテキストから組み立てて配る。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 98
#
# ^ setup.sh が読む実行順。衝突や「設定画面が開いている」で exit 1 しても、ほかの bootstrap を
#   止めないよう最後に走らせる。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Google 日本語入力の設定 (config1.db) と辞書 (user_dictionary.db) は protobuf のバイナリで、
# 保存のたびに時刻が入る。repo にはテキストだけを置き、setup のたびに組み立てて配る
# (docs/adr/015_win_google_ime_powertoys_*)。
#
# ## 何を読むか
#
# - ~/.local/state/dotfiles/windows-files.json (home-manager が置く。ADR 010)。配り先と on / off
# - この script がいる checkout の win/google-japanese-input/ (config.txtpb・keymap.tsv・romaji.tsv)
# - pollenjp/dotfiles-private の clone の google-japanese-input/dictionaries/ (無ければ辞書は飛ばす)。
#   clone の場所は bootstrap-dotfiles-private.sh と同じ決め方 ($DOTFILES_PRIVATE_DIR →
#   $(ghq root)/github.com/pollenjp/dotfiles-private → ~/ghq/github.com/pollenjp/dotfiles-private)
#
# ## 何をするか
#
# 1. 前提を確かめる。配らないマシン・Google 日本語入力が入っていないマシンは exit 0 で飛ばす。
#    interop (tasklist.exe) が使えなければ置かずに exit 0 (変換サーバーを再起動できず、置いたものが
#    古い設定で上書きされうるため)。設定画面・辞書ツール (GoogleIMEJaTool.exe) が開いていれば exit 1
# 2. pjp-google-ime build で組み立てる。テキストが壊れていれば何も書かずに exit 1
# 3. ファイルごとに、時刻などを外した中身 (pjp-google-ime digest) を比べる:
#
#      Windows 側に無い                              置く
#      組み立てたものと同じ                          何もしない (記録だけ合わせる)
#      前回置いたときの記録と同じ (repo 側が進んだ)  退避してから置く
#      それ以外 (画面で変えた・記録が無い)           衝突。テキストの diff を出して触らない
#
# 4. 置いたものがあれば、taskkill.exe /F で変換サーバー (GoogleIMEJaConverter.exe) を落とす。
#    次のキー入力で Google 日本語入力が起動し直し、置いた設定を読む
#
# 衝突が 1 件でもあれば、全部を処理し終えてから exit 1 する。--import で Windows 側を
# テキストへ取り込むか、--force で repo の中身で置き直す。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の Google 日本語入力の設定とユーザー辞書を、repo のテキストから組み立てて配る。

使い方:
  bootstrap-windows-google-ime.sh            配る
  bootstrap-windows-google-ime.sh --dry-run  判定だけ出して何も書かない
  bootstrap-windows-google-ime.sh --force    衝突 (画面で変えていた) でも repo の中身で置き直す
  bootstrap-windows-google-ime.sh --import   Windows 側の今の中身を repo のテキストへ取り込む
  bootstrap-windows-google-ime.sh --check    テキストの検証だけ (CI 用。state も Windows も要らない)
EOS
}

force=0
dry_run=0
do_import=0
check_only=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    --import) do_import=1 ;;
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

if ((do_import && dry_run)); then
  echo "--import と --dry-run は一緒に使えません (--import は repo のテキストを書き直します)。" >&2
  usage >&2
  exit 2
fi

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")
config_dir="${repo_dir}/win/google-japanese-input"
state_file="${HOME}/.local/state/dotfiles/windows-files.json"
state_dir="${HOME}/.local/state/dotfiles/google-japanese-input"
record_file="${state_dir}/deployed.json"
tool=pjp-google-ime
keep_backups=10

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

need_tool() {
  if ! command -v "${tool}" &>/dev/null; then
    echo "${tool} が見つかりません。先に home-manager switch を実行してください。" >&2
    exit 1
  fi
}

if [[ ! -f ${config_dir}/config.txtpb ]]; then
  echo "${config_dir}/config.txtpb がありません (この checkout は Google 日本語入力の設定を持っていない)。この手順は飛ばします。"
  exit 0
fi

dict_dir="$(private_dir)/google-japanese-input/dictionaries"

if ((check_only)); then
  need_tool
  args=(check --config-dir "${config_dir}")
  if [[ -d ${dict_dir} ]]; then
    args+=(--dictionary-dir "${dict_dir}")
  fi
  "${tool}" "${args[@]}"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi
if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}") != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  echo "Windows 側のホームが見えません: ${windows_home:-(windowsHome が空)}" >&2
  exit 1
fi
ime_dir="${windows_home}/AppData/LocalLow/Google/Google Japanese Input"
if [[ ! -d ${ime_dir} ]]; then
  echo "Google 日本語入力が入っていません (${ime_dir} が無い)。この手順は飛ばします。"
  exit 0
fi
need_tool

if [[ ! -d ${dict_dir} ]]; then
  if [[ -d $(private_dir)/.git ]] && ((do_import)); then
    mkdir -p "${dict_dir}"
  else
    echo "!! 辞書のテキスト (${dict_dir}) が無いので、辞書は飛ばします (dotfiles-private を取れていないかも)。" >&2
    dict_dir=""
  fi
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-windows-google-ime.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

if [[ -e ${record_file} ]]; then
  if ! records=$(jq -c 'if type == "object" then . else error("not an object") end' "${record_file}" 2>/dev/null); then
    echo "!! ${record_file} が壊れています (JSON の object ではない)。消してから流し直すと衝突として扱われます。" >&2
    exit 1
  fi
else
  records='{}'
fi

remember() {
  records=$(jq -c --arg k "$1" --arg v "$2" '.[$k] = $v' <<<"${records}")
}

write_records() {
  mkdir -p "${state_dir}"
  local t
  t=$(mktemp "${record_file}.XXXXXX")
  jq -S . <<<"${records}" >"${t}"
  mv -f -- "${t}" "${record_file}"
}

# 1 ファイルの kind (pjp-google-ime の --kind) を返す
kind_of() {
  case $1 in
    config1.db) echo config ;;
    user_dictionary.db) echo dictionary ;;
  esac
}

files=(config1.db)
if [[ -n ${dict_dir} ]]; then
  files+=(user_dictionary.db)
fi

if ((do_import)); then
  args=(import --windows-dir "${ime_dir}" --config-dir "${config_dir}")
  if [[ -n ${dict_dir} ]]; then
    args+=(--dictionary-dir "${dict_dir}")
  fi
  "${tool}" "${args[@]}"
  for f in "${files[@]}"; do
    if [[ -f ${ime_dir}/${f} ]]; then
      remember "${f}" "$("${tool}" digest --kind "$(kind_of "${f}")" "${ime_dir}/${f}")"
    fi
  done
  write_records
  echo "取り込みました。git diff を見て、dotfiles と dotfiles-private の両方で commit してください。"
  exit 0
fi

# 設定画面・辞書ツールが開いていたら止まる。interop が使えなければ置かない (exit 0)
if ((! dry_run)); then
  if ! listing=$(timeout 30 tasklist.exe /FI "IMAGENAME eq GoogleIMEJaTool.exe" /FO CSV /NH </dev/null 2>&1); then
    echo "!! tasklist.exe を呼べませんでした (WSL の interop が落ちているかもしれません)。Google 日本語入力の設定は置きません。" >&2
    echo "   変換サーバーを再起動できないと、置いた設定が古い設定で上書きされうるためです。" >&2
    echo "   interop が戻ったら ${script_dir}/bootstrap-windows-google-ime.sh を流してください。" >&2
    exit 0
  fi
  if grep -qi '"GoogleIMEJaTool.exe"' <<<"${listing}"; then
    echo "!! Google 日本語入力の設定画面か辞書ツール (GoogleIMEJaTool.exe) が開いています。閉じてから流し直してください。" >&2
    echo "   開いたまま置くと、閉じるときに古い中身で書き戻されることがあります。" >&2
    exit 1
  fi
fi

build_args=(build --config-dir "${config_dir}" --out "${tmp}/built")
if [[ -n ${dict_dir} ]]; then
  build_args+=(--dictionary-dir "${dict_dir}")
fi
if ! "${tool}" "${build_args[@]}"; then
  echo "!! テキストを組み立てられませんでした (上のエラーの行を直してください)。何も置いていません。" >&2
  exit 1
fi

# 衝突の diff。両方をテキストに戻してから比べる (- が Windows 側、+ が repo 側)
show_diff() {
  local kind=$1 have=$2 want=$3 a="${tmp}/diff/windows" b="${tmp}/diff/repo"
  rm -rf "${tmp}/diff"
  mkdir -p "${a}" "${b}"
  if ! "${tool}" decode --kind "${kind}" "${have}" --out "${a}" >/dev/null 2>&1; then
    echo "   (Windows 側のファイルを読めないので diff は出せません)"
    return 0
  fi
  "${tool}" decode --kind "${kind}" "${want}" --out "${b}" >/dev/null
  (cd "${tmp}/diff" && diff -ru windows repo) | sed -e 's#^--- windows/#--- Windows 側/#' -e 's#^+++ repo/#+++ repo/#' || true
}

backup_dir=""
backup() {
  if [[ -z ${backup_dir} ]]; then
    backup_dir="${state_dir}/backup/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "${backup_dir}"
  fi
  cp -p -- "$1" "${backup_dir}/"
}

# 退避は新しい方から ${keep_backups} 回分だけ残す (ディレクトリ名が時刻で始まるので名前の順)
prune_backups() {
  local dirs=()
  if [[ -d ${state_dir}/backup ]]; then
    mapfile -t dirs < <(find "${state_dir}/backup" -mindepth 1 -maxdepth 1 -type d | sort)
  fi
  local n=${#dirs[@]}
  local i
  for ((i = 0; i < n - keep_backups; i++)); do
    rm -rf -- "${dirs[i]}"
  done
}

place() {
  local t
  t=$(mktemp "$2.dotfiles-tmp.XXXXXX")
  cp -- "$1" "${t}"
  chmod 644 "${t}"
  mv -f -- "${t}" "$2"
}

placed=0
conflicts=0
for f in "${files[@]}"; do
  kind=$(kind_of "${f}")
  dst="${ime_dir}/${f}"
  want=$("${tool}" digest --kind "${kind}" "${tmp}/built/${f}")
  recorded=$(jq -r --arg k "${f}" '.[$k] // ""' <<<"${records}")
  if [[ ! -e ${dst} ]]; then
    action=copy
  elif ! have=$("${tool}" digest --kind "${kind}" "${dst}" 2>/dev/null); then
    # 読めない (壊れている) ものは、記録と比べられないので衝突として扱う
    if ((force)); then
      action=force
    else
      action=conflict
    fi
  elif [[ ${have} == "${want}" ]]; then
    action=same
  elif [[ -n ${recorded} && ${have} == "${recorded}" ]]; then
    action=update
  elif ((force)); then
    action=force
  else
    action=conflict
  fi

  case ${action} in
    same)
      echo "同じです: ${dst}"
      if [[ ${recorded} != "${want}" ]] && ((! dry_run)); then
        remember "${f}" "${want}"
      fi
      ;;
    conflict)
      conflicts=$((conflicts + 1))
      {
        echo "!! 衝突: ${dst} は Windows 側で変わっています (画面で変えたか、前回置いた記録が無い)。"
        show_diff "${kind}" "${dst}" "${tmp}/built/${f}"
        echo "   Windows 側の変更を残すなら: ${script_dir}/bootstrap-windows-google-ime.sh --import"
        echo "   repo 側で上書きするなら:   ${script_dir}/bootstrap-windows-google-ime.sh --force"
      } >&2
      ;;
    copy | update | force)
      case ${action} in
        copy) label="置く" ;;
        update) label="上書き (repo 側が進んだ)" ;;
        force) label="上書き (--force)" ;;
      esac
      if ((dry_run)); then
        echo "[dry-run] ${label}: ${dst}"
      else
        if [[ -e ${dst} ]]; then
          backup "${dst}"
        fi
        place "${tmp}/built/${f}" "${dst}"
        remember "${f}" "${want}"
        placed=$((placed + 1))
        echo "${label}: ${dst}"
      fi
      ;;
  esac
done

if ((! dry_run)); then
  write_records
  prune_backups
fi
if [[ -n ${backup_dir} ]]; then
  echo "置き換える前のファイルは ${backup_dir} に退避しました。"
fi

if ((placed > 0)); then
  # 置いてから落とす。次のキー入力で Google 日本語入力が変換サーバーを起動し直し、置いた設定を読む。
  # 128 は「動いていない」(誰も古い設定を持っていないので、そのままでよい)
  rc=0
  out=$(timeout 30 taskkill.exe /F /IM GoogleIMEJaConverter.exe </dev/null 2>&1) || rc=$?
  if ((rc == 0)); then
    echo "変換サーバー (GoogleIMEJaConverter.exe) を落としました。次のキー入力で起動し直し、置いた設定を読みます。"
    echo "直接入力モードのキー (F13 → IMEOn など) を変えたときは、アプリを起動し直すと効きます。"
  elif ((rc == 128)); then
    echo "変換サーバーは動いていませんでした。次に起動したときに置いた設定を読みます。"
  else
    {
      echo "!! 変換サーバーを落とせませんでした (taskkill.exe の終了コード ${rc}):"
      printf '%s\n' "${out}" | tr -d '\r' | sed 's/^/   /'
      echo "   設定画面を開く前に、タスクマネージャーで GoogleIMEJaConverter.exe を終了するか、サインアウトしてください。"
    } >&2
    exit 1
  fi
fi

if ((conflicts > 0)); then
  exit 1
fi
