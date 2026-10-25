#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/windows-terminal/managed.json のキーだけを、Windows Terminal の settings.json へ書き足す (冪等。更新時も毎回走る)。
#
# order: 99
#
# ^ setup.sh が読む実行順。ほかの bootstrap が置くものは使わない。衝突で exit 1 すると setup は
#   ここで止まるので、Windows の bootstrap (90〜98) の後ろに置く (止まっても、走らずに残るのは
#   後ろの exe-exec-trace と最後の「残りの手作業」だけ)。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# Windows Terminal の settings.json は Windows Terminal 自身も書き換える (新しい WSL の distro などの
# profile を見つけたとき・設定画面で保存したとき)。PC ごとに違う profile の一覧 (WSL の profile の GUID
# は distro の登録 ID から作られる) も入るので、win/ からファイルごと配る (bootstrap-windows-files.sh) と
# 書き換わるたびに衝突し、PC の間でも共有できない。そこで dotfiles が持つキーだけを managed.json に書き、
# そのキーだけを settings.json へ書き足す (dotfiles-private の docs/adr/018_win_terminal_settings_keys_*)。
# profiles.defaults に書けば全 profile に効く。
#
# ## 何を読むか
#
# - ~/.local/state/dotfiles/windows-files.json (home-manager が置く)。bootstrap-windows-files.sh
#   と同じく、無ければ飛ばし、enable が false なら何もしない
# - この script がいる checkout の win/windows-terminal/managed.json。settings.json と同じ形で、持つ
#   キーだけを書く。object を辿った先の、object でない値 (文字列・数・真偽・null・配列) 1 つが、持つキー
#   1 つ (配列は中を見ず、丸ごと 1 つの値として扱う)。profiles.list (PC ごとの profile の一覧) は書けない
# - Store 版の Windows Terminal の settings.json
#   (<windowsHome>/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json)。
#   Preview と zip 版は見ない
# - ~/.local/state/dotfiles/windows-terminal.applied.json (前回書いた値)。
#   {"version":1,"keys":{"<キーのパスの JSON>":<値>}} の形。キーの名前には . を含むもの
#   (compatibility.allowHeadless など) があるので、パスは ["profiles","defaults","bellSound"] のような
#   配列を JSON の文字列にして持つ
#
# ## 何をするか
#
# managed.json のキーを 1 つずつ、settings.json の値と記録で判定する:
#
#   settings.json の値が managed.json と同じ      何もしない (記録が無ければ記録だけする)
#   settings.json の値が前回書いた値と同じ        managed.json が更新された。書く
#   settings.json に値が無く、記録も無い          書き足す
#   それ以外                                      衝突。両方の値を出して触らない (--force なら書く)
#
# 記録があるのに settings.json に値が無いのは、Windows 側で消した (設定画面で既定に戻した、など) ので
# 衝突にする。衝突のメッセージは、記録があれば「Windows 側で変わった」、無ければ「この script が書く前
# から Windows 側にあった」と分けて出す。managed.json から消したキーは、settings.json からは消さない
# (記録からだけ消す。bootstrap-windows-files.sh が manifest から消したファイルを消さないのと同じ)。
#
# 書くときは、settings.json を ~/.local/state/dotfiles/windows-terminal/backup/<UTC の時刻>-<pid>/ へ
# 写してから (新しい方から 10 回分を残す)、同じディレクトリの一時ファイルに jq で書いて mv する。
# 字下げなどの形は jq のものに変わるが、Windows Terminal は気にせず読む。Windows Terminal は
# settings.json を見張っていて、書いたらその場で読み直す。
#
# 書かずに exit 0 で飛ばすのは、settings.json が無い (Windows Terminal を一度も起動していない) ときと、
# JSON として読めない (コメントや末尾のカンマがある) とき。どちらも warn で知らせる。衝突と、
# settings.json の途中が object でなくて書けないキーがあれば、⚠ の枠で出して exit 1。
#
# --import は、衝突したキーの値を settings.json から managed.json へ取り込む (settings.json には
# 書かない)。settings.json に値が無ければ、managed.json からそのキーを消す。取り込みは managed.json を
# 書き換えるので、managed.json に commit していない変更があると止まる。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/windows-terminal/managed.json のキーだけを、Windows Terminal の settings.json へ書き足す。

使い方:
  bootstrap-windows-terminal.sh            書き足す (Windows 側で変わっていたら、衝突として止まる)
  bootstrap-windows-terminal.sh --dry-run  判定だけ出して何も書かない
  bootstrap-windows-terminal.sh --force    衝突も、settings.json を退避してから managed.json の値で書く
  bootstrap-windows-terminal.sh --import   衝突したキーの値を、settings.json から managed.json へ取り込む
  bootstrap-windows-terminal.sh --check    managed.json の検証だけ (state も settings.json も見ない)
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
managed_rel="win/windows-terminal/managed.json"
managed_file="${repo_dir}/${managed_rel}"
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-terminal.applied.json"
backup_root="${state_dir}/windows-terminal/backup"
keep_backups=10
# Store 版の Windows Terminal の settings.json (windowsHome からの相対)
settings_rel="AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json"

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

# jq で使う関数。
#   leaf_paths        持つキーのパスを並べる (object を辿った先の、object でない値。配列の中は見ない)
#   lookup($p)        [見つかったか, 値]。途中が object でなくても落ちない
#   blocked($p)       $p の途中にある、object でない値のパス (無ければ null)。そこから先へは書けない
#   prune_empty($p)   $p から上へ、空になった object を消す (--import でキーを消した後)
#   show_path         表示用の名前 (profiles.defaults.bellSound。英数字と _ - 以外を含む名前は "" で囲む)
# shellcheck disable=SC2016
jq_lib='
def leaf_paths:
  if type == "object" then to_entries[] | [.key] + (.value | leaf_paths) else [] end;
def lookup($p):
  reduce $p[] as $k ([true, .];
    if .[0] and (.[1] | type) == "object" and (.[1] | has($k)) then [true, .[1][$k]] else [false, null] end);
def blocked($p):
  [range(1; $p | length) as $i | $p[:$i] as $q | lookup($q) as $r
    | select($r[0] and ($r[1] | type) != "object") | $q] | first;
def prune_empty($p):
  if ($p | length) > 0 and getpath($p) == {} then delpaths([$p]) | prune_empty($p[:-1]) else . end;
def show_path:
  map(if test("^[A-Za-z0-9_-]+$") then . else tojson end) | join(".");
'

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
  # profile の一覧は PC ごとに違う (WSL の profile の GUID は distro の登録 ID から作られる) ので持たない
  problems=$(jq -r '
    if (.profiles | type) == "array" then
      "profiles が配列です (profile の一覧の形)。持てるのは profiles.defaults だけです。"
    elif (.profiles | type) == "object" then
      (if .profiles | has("list") then
        "profiles.list があります。profile の一覧は PC ごとに違うので持てません (全 profile に効かせるなら profiles.defaults に書く)。"
      else empty end),
      (if (.profiles | has("defaults")) and (.profiles.defaults | type) != "object" then
        "profiles.defaults が object ではありません。"
      else empty end)
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
  # --import は jq --indent 4 で書き直すので、手で書いた形も揃えておく (取り込みの差分にキー以外が混ざらない)
  if ! jq --indent 4 . "${managed_file}" | cmp -s - "${managed_file}"; then
    echo "!! ${managed_rel} の形が jq --indent 4 の出力と違います (--import が書き直したときの差分を、値の変更だけにするため)。" >&2
    echo "   整えるには: jq --indent 4 . ${managed_rel} >${managed_rel}.tmp && mv ${managed_rel}.tmp ${managed_rel}" >&2
    exit 1
  fi
  n=$(jq "${jq_lib}"'[leaf_paths] | length' "${managed_file}")
  echo "${managed_rel}: OK (持つキー ${n} 件)"
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
windows_home=$(jq -r '.windowsHome // ""' "${state_file}")
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  echo "Windows 側のホームが見えません: ${windows_home:-(windowsHome が空)}" >&2
  echo "  /mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。" >&2
  exit 1
fi

validate_managed || exit 1

settings_file="${windows_home}/${settings_rel}"
if [[ ! -f ${settings_file} ]]; then
  warn "Windows Terminal の settings.json がありません: ${settings_file}" \
    "Windows Terminal (Store 版) を一度起動すると作られます。起動してから流し直してください。" \
    "この手順は飛ばします。"
  exit 0
fi
if ! err=$(jq -e 'type == "object"' "${settings_file}" 2>&1 >/dev/null); then
  warn "Windows Terminal の settings.json を JSON として読めないので、書き足しません: ${settings_file}" \
    ${err:+"${err}"} \
    "コメントや末尾のカンマなど、JSON に無い書き方を消してから流し直してください (Windows Terminal は読めるが、jq は読めない)。"
  exit 0
fi

if [[ -e ${record_file} ]]; then
  if ! jq -e 'type == "object" and (.keys | type == "object")' "${record_file}" >/dev/null 2>&1; then
    echo "!! ${record_file} が壊れています (keys を持つ JSON の object ではありません)。" >&2
    echo "   消してから流し直すと、settings.json に既にあって managed.json と違う値は衝突として扱われます" >&2
    echo "   (値を確かめて、--import で取り込むか --force)。" >&2
    exit 1
  fi
  records=$(jq -c . "${record_file}")
else
  records='{"version":1,"keys":{}}'
fi

# 取り込みは managed.json を settings.json の値で書き換える。commit していない変更 (未追跡も) があると
# 痕跡なく消えるので、何も書かずに止まる。git が無い・checkout の外で確かめられないときも止まる側に倒す。
# --no-optional-locks は index を書かないため。--untracked-files=normal は、未追跡を見せない設定でも見るため。
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

# 計画: 持つキーごとに 1 行の JSON。action は same / update / add / conflict / blocked
plan=$(jq -c -n \
  --slurpfile managed "${managed_file}" \
  --slurpfile settings "${settings_file}" \
  --argjson records "${records}" \
  "${jq_lib}"'
  $managed[0] as $m | $settings[0] as $s
  | ($m | leaf_paths) as $p
  | ($s | lookup($p)) as $cur
  | ($p | tojson) as $k
  | {
      path: $p,
      name: ($p | show_path),
      want: ($m | getpath($p)),
      has_cur: $cur[0],
      cur: $cur[1],
      has_rec: ($records.keys | has($k)),
      rec: $records.keys[$k],
      blocked: ($s | blocked($p) | if . == null then null else show_path end)
    }
  | .action = (
      if .blocked != null then "blocked"
      elif .has_cur and .cur == .want then "same"
      elif .has_cur and .has_rec and .cur == .rec then "update"
      elif (.has_cur | not) and (.has_rec | not) then "add"
      else "conflict" end)')

# 記録の書き換え ($1 = 計画の 1 行)。書いた値 (か、もう同じだった値) を残す
remember() {
  records=$(jq -c --argjson e "$1" '.keys[$e.path | tojson] = $e.want' <<<"${records}")
}

# 衝突したキーの、両方の値を出す ($1 = 計画の 1 行)
report_conflict() {
  local e=$1 name
  name=$(jq -r '.name' <<<"${e}")
  {
    if jq -e '.has_rec | not' <<<"${e}" >/dev/null; then
      echo "!! 衝突: ${name} は、書いた記録が無く、managed.json と値が違います (この script が書く前から Windows 側にあった。設定画面で変えたもの、など)。"
    elif jq -e '.has_cur' <<<"${e}" >/dev/null; then
      echo "!! 衝突: ${name} は Windows 側で変わっています (前回書いた値と違う)。"
    else
      echo "!! 衝突: ${name} は Windows 側で消えています (設定画面で既定に戻した、など)。"
    fi
    printf '   Windows 側:   %s\n' "$(jq -r 'if .has_cur then .cur | tojson else "(無い)" end' <<<"${e}")"
    printf '   managed.json: %s\n' "$(jq -r '.want | tojson' <<<"${e}")"
  } >&2
}

log=()
conflicts=()
blocked=()
writes=()
imports=()
pending=()
pre=""
if ((dry_run)); then
  pre="[dry-run] "
fi

while IFS= read -r entry; do
  if [[ -z ${entry} ]]; then
    continue
  fi
  action=$(jq -r '.action' <<<"${entry}")
  name=$(jq -r '.name' <<<"${entry}")
  if [[ ${action} == conflict ]] && ((force)); then
    action=force
  fi
  case ${action} in
    same)
      if ((! dry_run)) && ! jq -e '.has_rec and .rec == .want' <<<"${entry}" >/dev/null; then
        remember "${entry}"
      fi
      ;;
    add | update | force)
      if ((do_import)); then
        pending+=("${name}")
        continue
      fi
      case ${action} in
        add) label="書き足す" ;;
        update) label="書き換える (managed.json が更新された)" ;;
        force) label="書き換える (--force)" ;;
      esac
      writes+=("${entry}")
      log+=("  ${pre}${name}: ${label}")
      ;;
    conflict)
      conflicts+=("${name}")
      if ((do_import)); then
        imports+=("${entry}")
      else
        report_conflict "${entry}"
      fi
      ;;
    blocked)
      blocked+=("${name} (途中の $(jq -r '.blocked' <<<"${entry}") が object ではない)")
      ;;
  esac
done <<<"${plan}"

tmp_file=""
trap 'if [[ -n ${tmp_file} ]]; then rm -f "${tmp_file}"; fi' EXIT

backup_dir=""
backup() {
  if [[ -z ${backup_dir} ]]; then
    backup_dir="${backup_root}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "${backup_dir}"
  fi
  cp -p -- "$1" "${backup_dir}/"
}

# 退避は新しい方から ${keep_backups} 回分だけ残す (ディレクトリ名が時刻で始まるので名前の順)
prune_backups() {
  local dirs=()
  if [[ -d ${backup_root} ]]; then
    mapfile -t dirs < <(find "${backup_root}" -mindepth 1 -maxdepth 1 -type d | sort)
  fi
  local n=${#dirs[@]}
  local i
  for ((i = 0; i < n - keep_backups; i++)); do
    rm -rf -- "${dirs[i]}"
  done
}

# 置き先と同じディレクトリの一時ファイルに書いてから mv する。$1 = 置き先、残り = 中身を出すコマンド。
# パイプでつなぐと、コマンドが途中で落ちても空の中身で置き換えてしまうので、一時ファイルへ書き終えて
# から置き換える (落ちたら set -e で止まり、一時ファイルは trap が消す)
place() {
  local dst=$1
  shift
  tmp_file=$(mktemp "${dst}.dotfiles-tmp.XXXXXX")
  "$@" >"${tmp_file}"
  mv -f -- "${tmp_file}" "${dst}"
  tmp_file=""
}

if ((${#writes[@]} > 0 && ! dry_run)); then
  backup "${settings_file}"
  prune_backups
  w=$(printf '%s\n' "${writes[@]}" | jq -c -s 'map({path, value: .want})')
  # jq の $w は jq の変数 (place 越しなので、shellcheck には jq の引数と分からない)
  # shellcheck disable=SC2016
  place "${settings_file}" \
    jq --indent 4 --argjson w "${w}" 'reduce $w[] as $x (.; setpath($x.path; $x.value))' "${settings_file}"
  for entry in "${writes[@]}"; do
    remember "${entry}"
  done
fi

if ((do_import && ${#imports[@]} > 0)); then
  imp=$(printf '%s\n' "${imports[@]}" | jq -c -s '.')
  # shellcheck disable=SC2016
  place "${managed_file}" \
    jq --indent 4 --argjson imp "${imp}" "${jq_lib}"'
      reduce $imp[] as $e (.;
        if $e.has_cur then setpath($e.path; $e.cur) else delpaths([$e.path]) | prune_empty($e.path[:-1]) end)' \
    "${managed_file}"
  records=$(jq -c --argjson imp "${imp}" '
    reduce $imp[] as $e (.;
      if $e.has_cur then .keys[$e.path | tojson] = $e.cur else del(.keys[$e.path | tojson]) end)' <<<"${records}")
fi

# 記録を書く (変わったときだけ。--dry-run では書かない)。managed.json から消したキーは記録からも消す
if ((! dry_run)); then
  records=$(jq -c --slurpfile managed "${managed_file}" "${jq_lib}"'
    [$managed[0] | leaf_paths | tojson] as $keep
    | .keys |= with_entries(select(.key | IN($keep[])))' <<<"${records}")
  new_records=$(jq -S '.version = 1' <<<"${records}")
  old_records=""
  if [[ -f ${record_file} ]]; then
    old_records=$(jq -S . "${record_file}")
  fi
  if [[ ${new_records} != "${old_records}" ]]; then
    mkdir -p "${state_dir}"
    place "${record_file}" printf '%s\n' "${new_records}"
  fi
fi

if ((do_import)); then
  if ((${#imports[@]} == 0)); then
    echo "取り込むものはありません (衝突しているキーがありません)。"
  else
    echo "==> settings.json の値を ${managed_rel} へ取り込みました"
    printf '  %s\n' "${conflicts[@]}"
    echo "git -C ${repo_dir} diff -- ${managed_rel} で見て commit してください。"
  fi
  if ((${#pending[@]} > 0)); then
    echo "managed.json の値で settings.json へ書くキーが ${#pending[@]} 件あります (取り込みでは書きません):"
    printf '  %s\n' "${pending[@]}"
    echo "引数なしで流し直すと書きます: ${script_dir}/bootstrap-windows-terminal.sh"
  fi
  if ((${#blocked[@]} == 0)); then
    exit 0
  fi
fi

n=$(jq "${jq_lib}"'[leaf_paths] | length' "${managed_file}")
if ((${#log[@]} == 0 && ${#conflicts[@]} == 0 && ${#blocked[@]} == 0)); then
  echo "Windows Terminal の設定は揃っています (持つキー ${n} 件)。"
  exit 0
fi

if ((${#log[@]} > 0)); then
  echo "==> ${pre}Windows Terminal の設定 (${settings_file})"
  printf '%s\n' "${log[@]}"
  if [[ -n ${backup_dir} ]]; then
    echo "  書き換える前の settings.json は ${backup_dir} に退避しました。"
  fi
  if ((! dry_run)); then
    echo "  Windows Terminal は settings.json を見張っていて、その場で読み直します。"
  fi
fi

if ((${#conflicts[@]} == 0 && ${#blocked[@]} == 0)); then
  exit 0
fi
if ((do_import)); then
  conflicts=()
fi

rule="⚠️ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ⚠️"
{
  printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
  printf '%s⚠️  Windows Terminal の設定に、手で直すことがあります%s\n' "${c_warn}" "${c_reset}"
  if ((${#conflicts[@]} > 0)); then
    printf '%s⚠️  Windows 側で変わっていた (か、書く前からあった) ので、次のキーには触っていません (値は上):%s\n' "${c_warn}" "${c_reset}"
    for name in "${conflicts[@]}"; do
      printf '%s⚠️    %s%s\n' "${c_warn}" "${name}" "${c_reset}"
    done
    printf '%s⚠️  解き方 (どちらか):%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️    1. Windows 側の値を残す: managed.json へ取り込み、commit して push する%s\n' "${c_warn}" "${c_reset}"
    printf '%s⚠️       %s/bootstrap-windows-terminal.sh --import%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
    printf '%s⚠️    2. managed.json の値で書く (元の settings.json は %s/ に退避する):%s\n' "${c_warn}" "${backup_root}" "${c_reset}"
    printf '%s⚠️       %s/bootstrap-windows-terminal.sh --force%s\n' "${c_warn}" "${script_dir}" "${c_reset}"
  fi
  if ((${#blocked[@]} > 0)); then
    printf '%s⚠️  settings.json の途中が object でないので、次のキーは書けません:%s\n' "${c_warn}" "${c_reset}"
    for name in "${blocked[@]}"; do
      printf '%s⚠️    %s%s\n' "${c_warn}" "${name}" "${c_reset}"
    done
    printf '%s⚠️  Windows Terminal の設定画面で何か 1 つ変えて保存すると、profiles を object の形 (defaults と list) で書き直します。%s\n' "${c_warn}" "${c_reset}"
  fi
  printf '%s%s%s\n' "${c_warn}" "${rule}" "${c_reset}"
} >&2
exit 1
