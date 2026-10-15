#!/usr/bin/env bash
# shellcheck shell=bash
#
# Windows の Google 日本語入力の設定とユーザー辞書を、repo のテキストから組み立てて配る。
# 冪等。`setup.sh --update` でも毎回走る。
#
# order: 98
#
# ^ setup.sh が読む実行順。衝突や「設定画面が開いている」で exit 1 しても、ほかの bootstrap が
#   済んでいるよう、bootstrap の最後に走らせる。setup は失敗した手順で止まるので、後ろの
#   exe-exec-trace と最後の「残りの手作業」は、直して流し直すまで走らない。仕組みは
#   nix/README.md「bootstrap の実行順」。
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
# - この script がいる checkout の win/google-japanese-input/ (config.txtpb・keymap.tsv・あれば romaji.tsv)
# - pollenjp/dotfiles-private の clone の google-japanese-input/dictionaries/ (無ければ辞書は飛ばす)。
#   clone の場所は bootstrap-dotfiles-private.sh と同じ決め方 ($DOTFILES_PRIVATE_DIR →
#   $(ghq root)/github.com/pollenjp/dotfiles-private → ~/ghq/github.com/pollenjp/dotfiles-private)
#
# ## 何をするか
#
# 1. 前提を確かめる。配らないマシン・Google 日本語入力が入っていないマシンは exit 0 で飛ばす。
#    入っているがまだ使っていない (置き先が無い) マシンは、一度使ってから流し直すよう出して exit 0。
#    interop (tasklist.exe) が使えなければ置かずに exit 0 (変換サーバーを再起動できず、置いたものが
#    古い設定で上書きされうるため)。設定画面・辞書ツール (GoogleIMEJaTool.exe) が開いていれば exit 1
# 2. pjp-google-ime build で組み立てる。テキストが壊れていれば何も書かずに exit 1
# 3. ファイルごとに、時刻などを外した中身 (pjp-google-ime digest) を比べる:
#
#      Windows 側に無い                              置く
#      組み立てたものと同じ                          何もしない (記録だけ合わせる)
#      前回置いたときの記録と同じ (repo 側が進んだ)  退避してから置く
#      それ以外 (画面で変えた・記録が無い)           衝突。設定はテキストの diff を、辞書は辞書ごとの
#                                                    行の数を出して触らない
#
#    辞書の衝突で語を出さないのは、setup の出力が Claude などのログにも残り、そこから
#    Dev Tracker や PR へ写りうるため。語の diff は --show-words で出す (自分の端末で打つ)
# 4. 置いたものがあれば、taskkill.exe /F で変換サーバー (GoogleIMEJaConverter.exe) を落とす。
#    次のキー入力で Google 日本語入力が起動し直し、置いた設定を読む。落とせなければ印
#    (restart-pending) を残し、次の回は置くものが無くても落とし直す
#
# 衝突が 1 件でもあれば、全部を処理し終えてから exit 1 する。--import で Windows 側を
# テキストへ取り込むか、--force で repo の中身で置き直す。--import は、取り込みが書き換える
# テキスト (config.txtpb・keymap.tsv・romaji.tsv と、dotfiles-private の辞書のディレクトリ (dictionaries/) の中身) に commit して
# いない変更があると何も書かずに止まる (取り込むと、その変更が痕跡なく消えるため)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
Windows の Google 日本語入力の設定とユーザー辞書を、repo のテキストから組み立てて配る。

使い方:
  bootstrap-windows-google-ime.sh               配る
  bootstrap-windows-google-ime.sh --dry-run     判定だけ出して何も書かない
  bootstrap-windows-google-ime.sh --force       衝突 (画面で変えていた) でも repo の中身で置き直す
  bootstrap-windows-google-ime.sh --import      Windows 側の今の中身を repo のテキストへ取り込む
  bootstrap-windows-google-ime.sh --check       テキストの検証だけ (CI 用。state も Windows も要らない)
  bootstrap-windows-google-ime.sh --show-words  辞書の衝突で語の diff も出す。自分の端末で --dry-run と一緒に打つ
EOS
}

force=0
dry_run=0
do_import=0
check_only=0
show_words=0
for arg in "$@"; do
  case ${arg} in
    --force) force=1 ;;
    --dry-run) dry_run=1 ;;
    --import) do_import=1 ;;
    --check) check_only=1 ;;
    --show-words) show_words=1 ;;
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
# 落とし直しの印。置いたのに変換サーバーを落とせていない間だけある (中身は空)
pending_file="${state_dir}/restart-pending"
tool=pjp-google-ime
keep_backups=10

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

need_tool() {
  if ! command -v "${tool}" &>/dev/null; then
    echo "${tool} が見つかりません。先に home-manager switch を実行してください。" >&2
    exit 1
  fi
}

if [[ ! -f ${config_dir}/config.txtpb ]]; then
  if ((check_only)); then
    echo "!! ${config_dir}/config.txtpb がありません。--check で確かめるテキストが無いので、失敗にします。" >&2
    exit 1
  fi
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
  # 置き先は、Google 日本語入力が初めて起動したときに作る。入れただけでまだ使っていないマシン
  # (新しいマシンの 1 回目の setup) では無いので、変換サーバーの exe で「入っている」を見分けて案内する
  # (docs/adr/017_win_apps_winget_*)。置き先を先に作って置くことはしない (Google 日本語入力が作るときの
  # 権限と揃わないおそれがある)。Program Files は Windows のホーム (/mnt/c/Users/<名前>) と同じドライブにある
  windows_root=${windows_home%/Users/*}
  for d in "${windows_root}/Program Files" "${windows_root}/Program Files (x86)"; do
    if [[ -f "${d}/Google/Google Japanese Input/GoogleIMEJaConverter.exe" ]]; then
      warn "Google 日本語入力は入っていますが、まだ使われていません (${ime_dir} が無い)。この手順は飛ばします。" \
        "Google 日本語入力で一度何か打ってから (置き先ができる)、setup --update を流し直してください。"
      exit 0
    fi
  done
  echo "Google 日本語入力が入っていません (${ime_dir} が無い)。この手順は飛ばします。"
  exit 0
fi
need_tool

if [[ ! -d ${dict_dir} ]]; then
  if [[ -d $(private_dir)/.git ]] && ((do_import)); then
    mkdir -p "${dict_dir}"
  else
    warn "辞書のテキスト (${dict_dir}) が無いので、辞書は飛ばします (dotfiles-private を取れていないかも)。"
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
  # 取り込みは repo のテキストを Windows 側の中身で置き換える。commit していない変更 (未追跡の
  # ファイルも) があると痕跡なく消えるので、何も書かずに止まる。git が無い・checkout の外で
  # 確かめられないときも、消えた変更は戻せないので止まる側に倒す。
  # 出すのはファイル名だけ (辞書の中身は出ない)。--no-optional-locks は index を書かないため。
  # --untracked-files=normal は、未追跡を見せない設定 (status.showUntrackedFiles=no) でも見るため。
  # 設定の側で見るのは取り込みが書き換える 3 つだけ。同じディレクトリの Install-GoogleJapaneseInput.ps1
  # (ADR 017) は取り込みで変わらないので、版を上げる途中 (-Version を変えて commit する前) でも取り込める
  for d in "${config_dir}" ${dict_dir:+"${dict_dir}"}; do
    if [[ ${d} == "${config_dir}" ]]; then
      # pjp-google-ime の import (google_ime.py の write_config_texts) が書き換える・消すファイルと同じにする
      watched=(config.txtpb keymap.tsv romaji.tsv)
    else
      watched=(.)
    fi
    if ! changes=$(git --no-optional-locks -C "${d}" status --porcelain --untracked-files=normal -- "${watched[@]}" 2>"${tmp}/git-status.err"); then
      {
        echo "!! ${d} に commit していない変更が無いかを確かめられません (git が無いか、git の checkout ではない):"
        sed 's/^/   /' "${tmp}/git-status.err"
        echo "   --import はテキストを Windows 側の中身で置き換え、commit していない変更を消しうるので、止めます。"
      } >&2
      exit 1
    fi
    if [[ -n ${changes} ]]; then
      {
        echo "!! ${d} に commit していない変更があります。--import はテキストを Windows 側の中身で置き換えるので、先に commit するか、変更を戻してから流し直してください。"
        git --no-optional-locks -c core.quotePath=false -C "${d}" status --short --untracked-files=normal -- "${watched[@]}" | sed 's/^/   /'
      } >&2
      exit 1
    fi
  done
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
  echo "取り込みました。git diff を見て、dotfiles と dotfiles-private の両方で commit してください (dotfiles-private の diff には辞書の語が出るので、自分の端末で見てください)。"
  exit 0
fi

# 設定画面・辞書ツールが開いていたら止まる。interop が使えなければ置かない (exit 0)
if ((! dry_run)); then
  if ! listing=$(timeout 30 tasklist.exe /FI "IMAGENAME eq GoogleIMEJaTool.exe" /FO CSV /NH </dev/null 2>&1); then
    warn "tasklist.exe を呼べませんでした (WSL の interop が落ちているかもしれません)。Google 日本語入力の設定は置きません。" \
      "変換サーバーを再起動できないと、置いた設定が古い設定で上書きされうるためです。" \
      "interop が戻ったら ${script_dir}/bootstrap-windows-google-ime.sh を流してください。"
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

# $1 の行のうち $2 に無いものの数。行の多重集合として比べる (並びは見ない)
count_only_in() {
  LC_ALL=C comm -23 <(LC_ALL=C sort -- "$1") <(LC_ALL=C sort -- "$2") | wc -l | tr -d ' '
}

# 辞書の衝突の中身を、語を出さずに辞書ごとの行の数で出す。setup の出力は Claude などのログにも
# 残り、そこから Dev Tracker や PR へ写りうるため。辞書の名前は TSV のファイル名で、語ではない。
# $1: Windows 側を戻した TSV のディレクトリ、$2: repo 側の
show_dictionary_counts() {
  local a=$1 b=$2 f name shown=0 only_windows only_repo
  while IFS= read -r f; do
    name=${f%.tsv}
    if [[ ! -f ${b}/${f} ]]; then
      echo "   辞書「${name}」: Windows 側にだけある ($(wc -l <"${a}/${f}" | tr -d ' ') 語)"
    elif [[ ! -f ${a}/${f} ]]; then
      echo "   辞書「${name}」: repo 側にだけある ($(wc -l <"${b}/${f}" | tr -d ' ') 語)"
    elif cmp -s -- "${a}/${f}" "${b}/${f}"; then
      continue
    else
      only_windows=$(count_only_in "${a}/${f}" "${b}/${f}")
      only_repo=$(count_only_in "${b}/${f}" "${a}/${f}")
      if ((only_windows == 0 && only_repo == 0)); then
        echo "   辞書「${name}」: 行は同じで、並びだけが違う"
      else
        echo "   辞書「${name}」: Windows 側にだけある行 ${only_windows}・repo 側にだけある行 ${only_repo}"
      fi
    fi
    shown=1
  done < <(find "${a}" "${b}" -mindepth 1 -maxdepth 1 -type f -name '*.tsv' -printf '%f\n' | LC_ALL=C sort -u)
  if ((! shown)); then
    echo "   どの辞書も TSV に出る中身は同じです (TSV に出ない項目だけが違う)"
  fi
  echo "   語の diff は、自分の端末で ${script_dir}/bootstrap-windows-google-ime.sh --dry-run --show-words を打って見てください (Claude などのログに残る場所では流さない)。"
}

# 衝突の中身。両方をテキストに戻してから比べる (- が Windows 側、+ が repo 側)。
# 辞書は、--show-words が無ければ diff ではなく辞書ごとの行の数を出す
show_diff() {
  local kind=$1 have=$2 want=$3 a="${tmp}/diff/windows" b="${tmp}/diff/repo"
  rm -rf "${tmp}/diff"
  mkdir -p "${a}" "${b}"
  if ! "${tool}" decode --kind "${kind}" "${have}" --out "${a}" >/dev/null 2>&1; then
    echo "   (Windows 側のファイルを読めないので diff は出せません)"
    return 0
  fi
  "${tool}" decode --kind "${kind}" "${want}" --out "${b}" >/dev/null
  if [[ ${kind} == dictionary ]] && ((! show_words)); then
    # 辞書が 1 つも無い側は、decode が dictionaries/ を作らない
    mkdir -p "${a}/dictionaries" "${b}/dictionaries"
    show_dictionary_counts "${a}/dictionaries" "${b}/dictionaries"
    return 0
  fi
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

# 落とし直しの印は、最初に置く直前に置き、変換サーバーを落とせたら消す。置き終わってから
# 書くと、その間に止まったとき (set -e) に印が残らず、次の回は「同じです」で落とさないまま
# 終わってしまう (変換サーバーは古い設定を持ったまま)
marked=0
mark_restart_pending() {
  if ((! marked)); then
    mkdir -p "${state_dir}"
    : >"${pending_file}"
    marked=1
  fi
}

# この回より前に置いて、まだ落とせていない (衝突の案内と --dry-run に使う)
pending=0
if [[ -e ${pending_file} ]]; then
  pending=1
fi

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
        if ((pending)); then
          echo "   前回は変換サーバーを落とせていません。この差は、古い設定が書き戻されたものかもしれません (repo 側を残すなら --force)。"
        fi
        show_diff "${kind}" "${dst}" "${tmp}/built/${f}"
        echo "   Windows 側の変更を残すなら: ${script_dir}/bootstrap-windows-google-ime.sh --import"
        echo "   repo 側で上書きするなら:   ${script_dir}/bootstrap-windows-google-ime.sh --force"
        echo "   --import は repo のテキストを Windows 側の中身で置き換えます (diff の + の行は消えます)。両方を残すなら、テキストを手で直してから --force。"
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
        mark_restart_pending
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

if ((dry_run)); then
  if ((pending)); then
    echo "[dry-run] 変換サーバーを落とし直します (前回落とせなかった)"
  fi
elif ((placed > 0)) || [[ -e ${pending_file} ]]; then
  # 置いてから落とす。次のキー入力で Google 日本語入力が変換サーバーを起動し直し、置いた設定を読む。
  # 置くものが無くても印があれば落とし直す (前回置いたものを、古い設定を持つサーバーが上書きしうる)。
  # 128 は「動いていない」(誰も古い設定を持っていないので、そのままでよい)
  if ((placed == 0)); then
    echo "前回は変換サーバーを落とせなかったので、落とし直します。"
  fi
  rc=0
  out=$(timeout 30 taskkill.exe /F /IM GoogleIMEJaConverter.exe </dev/null 2>&1) || rc=$?
  if ((rc == 0 || rc == 128)); then
    rm -f -- "${pending_file}"
  fi
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
      echo "   次の setup でも落とし直します。"
    } >&2
    exit 1
  fi
fi

if ((conflicts > 0)); then
  exit 1
fi
