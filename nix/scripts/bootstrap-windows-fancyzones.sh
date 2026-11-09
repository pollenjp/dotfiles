#!/usr/bin/env bash
# shellcheck shell=bash
#
# PowerToys の FancyZones へ、win/powertoys/fancyzones/ の持つキー (settings.json) とカスタムレイアウト (uuid ごとに足す) を書く (冪等。更新時も毎回走る)。
#
# order: 92
#
# ^ setup.sh が読む実行順。bootstrap-windows-powertoys.sh (order: 91) が PowerToys を入れた後に走らせる。91 は
#   Keyboard Manager が使えないと早く抜けるので、FancyZones がその影響を受けないよう別の script にしてある。
#   仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# FancyZones の設定のうち、dotfiles で持ちたいもの (「Windows スナップのオーバーライド」のキーと、エディターの「カスタム」に
# 登録したレイアウト) を全マシンで揃える (dotfiles-private の docs/adr/042_*・046_*)。
#
# - settings.json は PowerToys が全部のキーを書き、設定画面でも書き換えるので、ファイルごとは配らない。managed.json に
#   持つキーだけを書き、そのキーだけをここで書く。Windows Terminal (bootstrap-windows-terminal.sh) と違い、衝突にしない。
#   値が違えば、手で変えていても dotfiles の値へ戻し、戻したことを 1 行出す。PowerToys は全部のキーを書くので、
#   Terminal の判定のままだと初回に既定の false と衝突するため。記録・--import・退避は持たない。managed.json から消した
#   キーは settings.json からは消さない (最後の値が残り、以後は戻さない)
# - custom-layouts.json は、PC のエディターで作ったレイアウトも入る (PC ごとに違う)。ファイルごと配ると、PC でレイアウトを
#   1 つ作るだけで衝突して setup が止まるので、repo のレイアウトを uuid で突き合わせ、レイアウトごとに足す。PC にだけある
#   レイアウトと、どのモニターにどれをあてるか (applied-layouts.json。モニターのシリアルが入る) には触らない
#
# ## 何をするか
#
# 1. ~/.local/state/dotfiles/windows-files.json を読み、配らないマシンなら飛ばす
# 2. <windowsHome>/AppData/Local/Microsoft/PowerToys/FancyZones/settings.json の、持つキーの値を比べる
#    - 同じなら何もしない (書かない。LastWriteTime も変えない)
#    - 違えば、jq でそのキーだけを書き換える。ほかのキーの値・キーの順・1 行で末尾に改行なしの形は変えない
#    - ファイルが無ければ、持つキーと name・version だけで作る。FancyZones は name が無いとエラーのダイアログを出し、
#      無いキーは今の値のまま読むので、この 3 つで足りる (設定画面は、無いキーを既定値で読む)
#    - 読めない (JSON の object でない) ときは、書かずに警告する。設定画面が書いている途中に当たっても読めるよう、5 回まで読む。
#      書いている途中の空のファイルを読んでも、空で置き換えない・揃っていると言わない
# 3. 同じディレクトリの custom-layouts.json に、win/powertoys/fancyzones/custom-layouts.json のレイアウトを uuid ごとに足す。
#    前に足した中身は ~/.local/state/dotfiles/windows-fancyzones.applied.json に uuid ごとに持つ
#    ({"version":1,"layouts":{"<uuid>":<レイアウト>}})。中身は jq で読んだ値で比べる (キーの順・字下げ・改行・エスケープに
#    左右されない。配列の順は比べる)。レイアウトごとに:
#
#      PC に無く、記録も無い                     末尾に足す
#      PC が repo と同じ                         何もしない (記録が無ければ記録だけする)
#      PC が記録と同じ (前に足したまま)          repo が更新された。同じ位置で書き換える
#      PC が repo とも記録とも違う・記録が無い   PC のエディターで直した (足す前からあった)。書き換えずに警告する
#      PC に無いが、記録がある                   PC で消した (エディターを開いたまま流して閉じても消える)。足し直さずに警告する
#
#    - --force は、警告する 2 つも repo の中身にする (書き換える・足し直す)。--import <名前> は逆に、PC のレイアウトを名前で
#      選んで repo のファイルへ写す (commit は人がする。PC のファイルと記録には書かない)
#    - PC にファイルが無ければ、記録によらず repo のレイアウトだけで作る (エディターはファイルを消さないので、PowerToys の
#      設定を消したときで、PC で消したのではない)
#    - repo から消したレイアウトは PC から消さず、記録からだけ消す (manifest から外したファイルと同じ扱い)
#    - 書く形は PowerToys の形 (字下げ 2・CRLF・末尾に改行なし。エディターが書くバイト列と同じ形)。書き換える前のファイルを
#      ~/.local/state/dotfiles/windows-fancyzones/backup/<UTC の時刻>-<pid>/ へ写す (新しい方から 10 回分を残す)
#    - PC のファイルを読めない (5 回読む)・記録が壊れている・repo のファイルに誤りがあるときは、書かずに警告する
# 4. 2 と 3 は、隣に書いて mv した後に touch する。FancyZones は LastWriteTime の変更しか見ていないので、mv だけでは気づかない
#    (src/common/SettingsAPI/FileWatcher.cpp。実機で確かめた)。読みかけを見せないよう、その場には書かない。
#    PowerToys は起動し直さない
# 5. 全体の設定 <windowsHome>/AppData/Local/Microsoft/PowerToys/settings.json の enabled.FancyZones が false なら、
#    設定が効かないので警告する。自動でオンにはしない。キーやファイルが無ければオンとして扱う (FancyZones は既定でオン)。
#    読めないときは、確かめられないと警告する
#
# どの場合も exit 0 (後ろの手順を止めない)。引数の誤りだけ exit 2。--check と --import は誤りがあれば exit 1。
# 知らせたことは、setup の最後の「警告のまとめ」にも残す (warn / summary_warn)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
PowerToys の FancyZones へ、win/powertoys/fancyzones/ の持つキー (settings.json) とカスタムレイアウトを書く。
持つキーは、設定画面で変えていても dotfiles の値へ戻す。カスタムレイアウトは uuid ごとに足し、PC にだけあるものには触らない。
PC のエディターで直したレイアウトは書き換えずに知らせる。FancyZones はその場で読み直す (PowerToys は起動し直さない)。

使い方:
  bootstrap-windows-fancyzones.sh                   値が違えば書き、無いレイアウトを足す
  bootstrap-windows-fancyzones.sh --dry-run         判定だけ出して何も書かない
  bootstrap-windows-fancyzones.sh --force           PC で直した・消したレイアウトも repo の中身にする (退避する)
  bootstrap-windows-fancyzones.sh --import <名前>   PC のレイアウトを名前で選び、repo の custom-layouts.json へ写す
                                                    (繰り返せる。commit は自分で)
  bootstrap-windows-fancyzones.sh --check           win/powertoys/fancyzones/ の検証だけ (state も PC のファイルも見ない)
EOS
}

dry_run=0
check=0
force=0
import_mode=0
import_names=()
while (($# > 0)); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --check) check=1 ;;
    --force) force=1 ;;
    --import | --import=*)
      if [[ $1 == --import=* ]]; then
        import_name=${1#--import=}
      elif (($# >= 2)); then
        import_name=$2
        shift
      else
        import_name=""
      fi
      if [[ -z ${import_name} ]]; then
        echo "--import には、取り込むレイアウトの名前 (PC のエディターに出る名前) を付けてください。" >&2
        usage >&2
        exit 2
      fi
      import_mode=1
      import_names+=("${import_name}")
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "不明な引数です: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done
if ((check && (dry_run || force || import_mode))); then
  echo "--check はほかの引数と一緒に使えません。" >&2
  exit 2
fi
if ((import_mode && (dry_run || force))); then
  echo "--import は --force・--dry-run と一緒に使えません。" >&2
  exit 2
fi

script_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null || exit
  pwd -P
)
repo_dir=$(dirname "$(dirname "${script_dir}")")
managed_rel="win/powertoys/fancyzones/managed.json"
managed_file="${repo_dir}/${managed_rel}"
layouts_rel="win/powertoys/fancyzones/custom-layouts.json"
layouts_file="${repo_dir}/${layouts_rel}"
state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/windows-files.json"
record_file="${state_dir}/windows-fancyzones.applied.json"
backup_root="${state_dir}/windows-fancyzones/backup"
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

# --check と --import の誤りを出す (setup の警告のまとめには残さない。引数は warn と同じ)
fail() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
}

# jq で使う関数 (settings.json)。
#   leaf_paths   持つキーのパスを並べる (object を辿った先の、object でない値 1 つが持つキー 1 つ)
#   apply($m)    $m の持つキーだけを書き込む
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
jq_lib='
def leaf_paths:
  if type == "object" then to_entries[] | [.key] + (.value | leaf_paths) else [] end;
def apply($m):
  reduce ($m | leaf_paths) as $p (.; setpath($p; $m | getpath($p)));
'

# jq で使う関数 (custom-layouts.json)。
#   layouts            custom-layouts の配列 (無い・object でなければ空)
#   uuid_index($u)     配列の中で uuid が $u のレイアウトの位置 (無ければ null)
#   layout_problems    repo に置くファイルの誤りを 1 行ずつ出す。uuid は PowerToys の書く形 (大文字の {…}) で、突き合わせは
#                      文字列の一致なので形を揃える。name は --import で引くので重ねない
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
layouts_lib='
def layouts:
  if type == "object" and (.["custom-layouts"] | type) == "array" then .["custom-layouts"] else [] end;
def uuid_index($u):
  first(range(0; length) as $i | select((.[$i] | type) == "object" and .[$i].uuid == $u) | $i) // null;
def name_note:
  if (.name | type) == "string" then "「\(.name)」" else "" end;
def layout_problems:
  if type != "object" then
    "JSON の object ではありません。"
  elif (.["custom-layouts"] | type) != "array" then
    "custom-layouts の配列がありません。"
  else
    (.["custom-layouts"] | to_entries[] | (.key + 1) as $n | .value
      | if type != "object" then
          "\($n) 番目が object ではありません。"
        else
          (if (.uuid | type) == "string" and (.uuid | test("^\\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\\}$"))
           then empty
           else "\($n) 番目\(name_note) の uuid が、大文字の {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX} の形ではありません: \(.uuid | tojson)" end),
          (if (.name | type) == "string" and .name != "" then empty else "\($n) 番目の name が空か、文字列ではありません。" end),
          (if (.type | type) == "string" then empty else "\($n) 番目\(name_note) に type (文字列) がありません。" end),
          (if (.info | type) == "object" then empty else "\($n) 番目\(name_note) に info (object) がありません。" end)
        end),
    ([.["custom-layouts"][] | objects | .uuid | strings] | group_by(.)[] | select(length > 1) | "uuid が重なっています: \(.[0])"),
    ([.["custom-layouts"][] | objects | .name | strings] | group_by(.)[] | select(length > 1) | "name が重なっています: \(.[0])")
  end;
'

# managed.json の誤りを 1 行ずつ出す。誤りが無ければ何も出さない
managed_problems() {
  if [[ ! -s ${managed_file} ]]; then
    echo "ファイルが無いか、空です (${managed_file})。"
    return 0
  fi
  jq -r "${jq_lib}"'
    if type != "object" then
      "JSON の object ではありません。"
    else
      ((keys - ["properties"]) | select(length > 0) | "properties のほかにキーがあります: \(join(", "))"),
      (if (.properties | type) != "object" or (.properties | length) == 0 then
        "properties に持つキーがありません。"
      else
        .properties | to_entries[]
        | select((.value | type) != "object" or (.value | keys) != ["value"] or ([.value | .. | select(. == null or . == {})] | length) > 0)
        | "properties.\(.key) の形が {\"value\": 値} ではありません。"
      end)
    end' "${managed_file}" 2>&1 || true
}

# repo の custom-layouts.json の誤りを 1 行ずつ出す。誤りが無ければ何も出さない
layouts_problems() {
  if [[ ! -s ${layouts_file} ]]; then
    echo "ファイルが無いか、空です (${layouts_file})。"
    return 0
  fi
  jq -r "${layouts_lib}"'layout_problems' "${layouts_file}" 2>&1 || true
}

# 標準入力の JSON を、PowerToys の書く形 (字下げ 2・CRLF・末尾に改行なし) で出す。読めない・空なら失敗する
to_pt_form() {
  local body
  body=$(jq --indent 2 .) || return 1
  [[ -n ${body} ]] || return 1
  printf '%s' "${body//$'\n'/$'\r\n'}"
}

# ファイルが PowerToys の書く形か
pt_form_ok() {
  local want have
  want=$(to_pt_form <"$1" 2>/dev/null) || return 1
  have=$(
    cat -- "$1"
    printf x
  )
  [[ ${have%x} == "${want}" ]]
}

if ! command -v jq &>/dev/null; then
  if ((check || import_mode)); then
    echo "!! jq が見つかりません。" >&2
    exit 1
  fi
  warn "jq が見つかりません。先に home-manager switch を実行してください。この手順は飛ばします。"
  exit 0
fi

if ((check)); then
  failed=0
  problems=$(managed_problems)
  if [[ -n ${problems} ]]; then
    fail "${managed_rel} に誤りがあります:" "${problems}"
    failed=1
  fi
  problems=$(layouts_problems)
  if [[ -n ${problems} ]]; then
    fail "${layouts_rel} に誤りがあります:" "${problems}"
    failed=1
  elif ! pt_form_ok "${layouts_file}"; then
    # --import は PowerToys の書く形で書き直すので、置いてあるファイルも揃えておく (取り込みの差分を中身の変更だけにする)
    fail "${layouts_rel} が、PowerToys の書く形と違います (字下げ 2・CRLF・末尾に改行なし)。--import が書き直したときの差分を、中身の変更だけにするためです。" \
      "エディターの書いたファイルを --import で取り込むか、次で整えてください:" \
      "f=${layouts_rel}; b=\$(jq --indent 2 . \"\$f\") && printf '%s' \"\${b//\$'\\n'/\$'\\r\\n'}\" >\"\$f\""
    failed=1
  fi
  if ((failed)); then
    exit 1
  fi
  n=$(jq "${jq_lib}"'[leaf_paths] | length' "${managed_file}")
  m=$(jq '.["custom-layouts"] | length' "${layouts_file}")
  echo "win/powertoys/fancyzones/: OK (持つキー ${n} 件・カスタムレイアウト ${m} 件)"
  exit 0
fi

# 配らないマシン・配り先が見えないときは、setup では飛ばす。--import は取り込めないので exit 1
if [[ ! -r ${state_file} ]]; then
  if ((import_mode)); then
    fail "配り先の設定がありません (${state_file})。PC のレイアウトを読めないので、取り込めません。"
    exit 1
  fi
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}" 2>/dev/null) != true ]]; then
  if ((import_mode)); then
    fail "このマシンは Windows 側へ配らないので (dotfiles.wsl.windowsFiles.enable = false)、取り込めません。"
    exit 1
  fi
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}" 2>/dev/null) || windows_home=""
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  if ((import_mode)); then
    fail "Windows 側のホームが見えないので、取り込めません: ${windows_home:-(windowsHome が空)}" \
      "/mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。"
    exit 1
  fi
  warn "Windows 側のホームが見えないので、FancyZones の設定とカスタムレイアウトを書きません: ${windows_home:-(windowsHome が空)}" \
    "/mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。"
  exit 0
fi

fz_dir="${windows_home}/AppData/Local/Microsoft/PowerToys/FancyZones"
settings_json="${fz_dir}/settings.json"
pc_layouts="${fz_dir}/custom-layouts.json"
global_json="${windows_home}/AppData/Local/Microsoft/PowerToys/settings.json"

# 一時ファイルの置き場 (PC のファイルの写し・計画・記録)。終わったら消す。作れなければ失敗する
work_dir=""
trap '[[ -z ${work_dir} ]] || rm -rf -- "${work_dir}"' EXIT
make_work_dir() {
  if [[ -z ${work_dir} ]]; then
    work_dir=$(mktemp -d 2>/dev/null) || work_dir=""
  fi
  [[ -n ${work_dir} ]]
}

# ---- settings.json の持つキー ----

# JSON の object か。設定画面が書いている途中に当たっても読めるよう、5 回まで読む
readable_object() {
  local i
  for ((i = 0; i < 5; i++)); do
    if jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

unreadable() {
  warn "FancyZones の settings.json を読めないので、書きません: ${settings_json}" \
    "中身を確かめて直すか、ファイルを消してから流し直してください (無ければ、持つキーだけで作ります)。"
}

# 書く中身を出す。ファイルが無ければ、持つキーと name・version だけで作る。キーの順と 1 行で末尾に改行なしの形は変えない
# (PowerToys が書く形)。-e は、書いている途中の空のファイルを読んで何も出さなかったときに失敗にするため
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
render_settings() {
  if [[ -e ${settings_json} ]]; then
    jq -ecj --slurpfile m "${managed_file}" "${jq_lib}"'apply($m[0])' "${settings_json}"
  else
    jq -ncj --slurpfile m "${managed_file}" "${jq_lib}"'{properties: {}, name: "FancyZones", version: "1.0"} | apply($m[0])'
  fi
}

# 隣に書いてから置き換える (読みかけを見せない)
write_settings() {
  local tmp="${settings_json}.dotfiles-tmp"
  if render_settings 2>/dev/null >"${tmp}" && mv -f -- "${tmp}" "${settings_json}" 2>/dev/null; then
    return 0
  fi
  rm -f -- "${tmp}" 2>/dev/null || true
  return 1
}

# 動いている FancyZones に読み直させる。LastWriteTime の変更しか見ていないので、mv の後に touch する
reload_fancyzones() {
  touch -- "${settings_json}" 2>/dev/null \
    || warn "FancyZones の settings.json に書きましたが、FancyZones に読み直させられませんでした: ${settings_json}" \
      "PowerToys を起動し直すと読みます。"
}

create_settings() {
  if ((dry_run)); then
    echo "[dry-run] FancyZones の settings.json が無いので、持つキーだけで作ります (持つキー ${n} 件): ${settings_json}"
    return 0
  fi
  if ! mkdir -p -- "${fz_dir}" 2>/dev/null || ! write_settings; then
    warn "FancyZones の settings.json を作れませんでした: ${settings_json}" \
      "Windows 側のディレクトリを確かめてから、流し直してください。"
    return 0
  fi
  reload_fancyzones
  echo "FancyZones の settings.json が無いので、持つキーだけで作りました (持つキー ${n} 件): ${settings_json}"
}

update_settings() {
  local changes line
  if ! readable_object "${settings_json}"; then
    unreadable
    return 0
  fi
  # 値が違うキーを 1 行ずつ出す。途中が object でなくても落ちない (書くときに落ちて、書けないと知らせる)。
  # input は、書いている途中の空のファイルでエラーになる (差が無いことにしない)
  # shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
  if ! changes=$(jq -rn --slurpfile m "${managed_file}" "${jq_lib}"'
    input as $s | $m[0] | leaf_paths as $p
    | ($m[0] | getpath($p)) as $want
    | ($s | try getpath($p) catch null) as $cur
    | select($cur != $want)
    | "\($p | join(".")) \(if $cur == null then "(無い)" else ($cur | tojson) end) → \($want | tojson)"
    ' "${settings_json}" 2>/dev/null); then
    unreadable
    return 0
  fi
  if [[ -z ${changes} ]]; then
    echo "FancyZones の設定は揃っています (持つキー ${n} 件)。"
    return 0
  fi
  if ((dry_run)); then
    if render_settings &>/dev/null; then
      while IFS= read -r line; do
        echo "[dry-run] FancyZones の設定を dotfiles の値へ戻します: ${line}"
      done <<<"${changes}"
    else
      echo "[dry-run] FancyZones の settings.json に書けません: ${settings_json}"
      printf '%s\n' "${changes}"
    fi
    return 0
  fi
  if ! write_settings; then
    warn "FancyZones の settings.json に書けないので、dotfiles の値にできませんでした: ${settings_json}" "${changes}"
    return 0
  fi
  reload_fancyzones
  while IFS= read -r line; do
    echo "FancyZones の設定を dotfiles の値へ戻しました: ${line}"
  done <<<"${changes}"
}

sync_settings() {
  local problems
  problems=$(managed_problems)
  if [[ -n ${problems} ]]; then
    warn "${managed_rel} に誤りがあるので、FancyZones の設定を書きません:" "${problems}"
    return 0
  fi
  n=$(jq "${jq_lib}"'[leaf_paths] | length' "${managed_file}")
  if [[ -e ${settings_json} ]]; then
    update_settings
  else
    create_settings
  fi
}

# ---- カスタムレイアウト (custom-layouts.json) ----

# PC の custom-layouts.json を作業場所へ写す (読みかけを見せないよう、写しで比べて写しから書く)。custom-layouts が配列の
# JSON の object (custom-layouts が無いのはよい) になるまで、5 回まで写す。エディターが書いている途中に当たっても読めるように
snapshot_pc_layouts() {
  local i
  for ((i = 0; i < 5; i++)); do
    if cp -- "${pc_layouts}" "${work_dir}/pc.json" 2>/dev/null \
      && jq -e 'type == "object" and ((has("custom-layouts") | not) or (.["custom-layouts"] | type) == "array")' \
        "${work_dir}/pc.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 記録を作業場所へ写す。無ければ空の記録。壊れていれば失敗する
load_record() {
  if [[ ! -e ${record_file} ]]; then
    printf '%s\n' '{"version":1,"layouts":{}}' >"${work_dir}/rec.json"
    return 0
  fi
  jq -e 'type == "object" and (.layouts | type) == "object"' "${record_file}" >/dev/null 2>&1 || return 1
  cp -- "${record_file}" "${work_dir}/rec.json"
}

# 記録を書く (変わったときだけ。--dry-run では書かない)。repo から消したレイアウトは記録から消し、揃っているものと、
# 書けたときは書いたものを、repo の中身で記録する。$1: 書けたか (true / false)
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
save_record() {
  local new old
  if ((dry_run)); then
    return 0
  fi
  new=$(jq -S -n --slurpfile repo "${layouts_file}" --slurpfile rec "${work_dir}/rec.json" --slurpfile plan "${work_dir}/plan.json" \
    --argjson wrote "$1" '
    [$repo[0]["custom-layouts"][].uuid] as $ids
    | ($rec[0].layouts | with_entries(select(.key as $k | any($ids[]; . == $k))))
    | reduce ($plan[0].entries[] | select(.action == "same" or ($wrote and .write))) as $x (.; .[$x.uuid] = $x.want)
    | {version: 1, layouts: .}')
  # 記録が無いのは、空の記録と同じ (足したものが無ければ作らない)
  if [[ -f ${record_file} ]]; then
    old=$(jq -S . "${record_file}" 2>/dev/null) || old=""
  else
    old=$(jq -S -n '{version: 1, layouts: {}}')
  fi
  if [[ ${new} == "${old}" ]]; then
    return 0
  fi
  if ! { mkdir -p -- "${state_dir}" && printf '%s\n' "${new}" >"${record_file}.dotfiles-tmp" && mv -f -- "${record_file}.dotfiles-tmp" "${record_file}"; } 2>/dev/null; then
    rm -f -- "${record_file}.dotfiles-tmp" 2>/dev/null || true
    warn "FancyZones のカスタムレイアウトの記録を書けませんでした: ${record_file}" \
      "次の回は、前に足したレイアウトを見分けられないことがあります (PC で直したものとして知らせます)。"
  fi
}

# 書き換える前の PC のファイルを退避する (新しい方から ${keep_backups} 回分を残す)。退避の場所は backup_dir に入れる
backup_dir=""
backup_pc_layouts() {
  local dirs=() i
  [[ -e ${pc_layouts} ]] || return 0
  backup_dir="${backup_root}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if ! { mkdir -p -- "${backup_dir}" && cp -p -- "${pc_layouts}" "${backup_dir}/"; } 2>/dev/null; then
    backup_dir=""
    return 1
  fi
  # ディレクトリの名前が時刻で始まるので、名前の順が古い順
  shopt -s nullglob
  dirs=("${backup_root}"/*/)
  shopt -u nullglob
  for ((i = 0; i < ${#dirs[@]} - keep_backups; i++)); do
    rm -rf -- "${dirs[i]}" 2>/dev/null || true
  done
}

# 書く中身 (PC のファイルの写しに、計画の書くものを当てたもの) を、PowerToys の書く形で出す
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
render_pc_layouts() {
  jq -n --slurpfile pc "${work_dir}/pc.json" --slurpfile plan "${work_dir}/plan.json" "${layouts_lib}"'
    ($pc[0] | if type == "object" then . else {} end) as $doc
    | reduce ($plan[0].entries[] | select(.write)) as $x ($doc | layouts;
        uuid_index($x.uuid) as $i | if $i == null then . + [$x.want] else .[$i] = $x.want end) as $list
    | $doc | .["custom-layouts"] = $list' | to_pt_form
}

# 隣に書いてから置き換える (読みかけを見せない)
write_pc_layouts() {
  local tmp="${pc_layouts}.dotfiles-tmp" body
  if body=$(render_pc_layouts 2>/dev/null) && printf '%s' "${body}" 2>/dev/null >"${tmp}" && mv -f -- "${tmp}" "${pc_layouts}" 2>/dev/null; then
    return 0
  fi
  rm -f -- "${tmp}" 2>/dev/null || true
  return 1
}

# 書き換えずに残したもの (PC で直した・足す前からあった・消えた) を警告し、直されたものの違いをその場にだけ出す
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
report_kept() {
  local kept hint i count label
  kept=$(jq -r '.entries[] | select(.action == "edited" or .action == "differs" or .action == "deleted")
    | "\(.name): \(
        if .action == "edited" then "PC のエディターで直されています (前に足した中身と違う)"
        elif .action == "differs" then "dotfiles が足す前から PC にあり、repo と中身が違います"
        else "PC から消えています (前に足したもの。エディターで消したか、エディターを開いたまま流して閉じると消えます)" end)\(
        if .has_cur and (.cur.name != .name) then " (PC での名前は「\(.cur.name | tostring)」)" else "" end)"' "${work_dir}/plan.json")
  [[ -n ${kept} ]] || return 0
  # PC にあるもの (直した・足す前からあった) は取り込める。--import は PC の名前で引く
  jq '[.entries[] | select(.action == "edited" or .action == "differs")]' "${work_dir}/plan.json" >"${work_dir}/kept.json"
  hint=$(jq -r 'map("--import \(.cur.name | tostring | @sh)") | join(" ")' "${work_dir}/kept.json")
  warn "FancyZones のカスタムレイアウトのうち、次のものは PC の中身を残しました (書き換えていません。${pc_layouts}):" \
    "${kept}" \
    "repo の中身にするなら (PC のファイルは退避します): ${script_dir}/bootstrap-windows-fancyzones.sh --force" \
    ${hint:+"PC の中身を repo へ取り込むなら (commit は自分で): ${script_dir}/bootstrap-windows-fancyzones.sh ${hint}"}
  # 直されたものの違い (PC → repo)。長くなるので、警告のまとめには入れない
  command -v diff &>/dev/null || return 0
  count=$(jq 'length' "${work_dir}/kept.json")
  for ((i = 0; i < count; i++)); do
    jq -S --indent 2 --argjson i "${i}" '.[$i].cur' "${work_dir}/kept.json" >"${work_dir}/diff-pc.json"
    jq -S --indent 2 --argjson i "${i}" '.[$i].want' "${work_dir}/kept.json" >"${work_dir}/diff-repo.json"
    label=$(jq -r --argjson i "${i}" '.[$i].name' "${work_dir}/kept.json")
    diff -u --label "${label} (PC)" --label "${label} (repo)" -- "${work_dir}/diff-pc.json" "${work_dir}/diff-repo.json" >&2 || true
  done
}

# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
sync_layouts() {
  local problems fresh=false force_json=false pre="" lines pc_only nwrite nsame
  problems=$(layouts_problems)
  if [[ -n ${problems} ]]; then
    warn "${layouts_rel} に誤りがあるので、FancyZones のカスタムレイアウトを書きません:" "${problems}"
    return 0
  fi
  # repo にレイアウトが無ければ、PC のファイルは読まない (前に足した記録があれば消す)
  if [[ $(jq '.["custom-layouts"] | length' "${layouts_file}") == 0 ]]; then
    if [[ -e ${record_file} ]] && make_work_dir && load_record; then
      printf '%s\n' '{"entries":[]}' >"${work_dir}/plan.json"
      save_record false
    fi
    return 0
  fi
  if ((force)); then
    force_json=true
  fi
  if ! make_work_dir; then
    warn "一時ディレクトリを作れないので、FancyZones のカスタムレイアウトを書きません (TMPDIR=${TMPDIR:-/tmp})。"
    return 0
  fi
  if ! load_record; then
    warn "FancyZones のカスタムレイアウトの記録が壊れているので、カスタムレイアウトを書きません: ${record_file}" \
      "消してから流し直すと、PC にあって repo と中身が違うレイアウトは、PC の中身を残して知らせます (--force か --import で解く)。"
    return 0
  fi
  if [[ -e ${pc_layouts} ]]; then
    if ! snapshot_pc_layouts; then
      warn "FancyZones の custom-layouts.json を読めないので、カスタムレイアウトを書きません: ${pc_layouts}" \
        "中身を確かめて直してから、流し直してください。"
      return 0
    fi
  else
    # 無いのは PowerToys の設定を消したとき (エディターは消さない)。記録によらず repo のレイアウトだけで作る
    fresh=true
    printf '%s\n' '{}' >"${work_dir}/pc.json"
  fi

  # 計画: repo のレイアウトごとの判定 (entries) と、PC にだけあるレイアウトの名前 (pc_only)
  jq -n --slurpfile repo "${layouts_file}" --slurpfile pc "${work_dir}/pc.json" --slurpfile rec "${work_dir}/rec.json" \
    --argjson fresh "${fresh}" --argjson force "${force_json}" "${layouts_lib}"'
    ($repo[0]["custom-layouts"]) as $want
    | ($pc[0] | layouts) as $cur
    | ($rec[0].layouts) as $recs
    | {
        entries: [
          $want[] as $w
          | ($cur | uuid_index($w.uuid)) as $i
          | {
              uuid: $w.uuid,
              name: $w.name,
              want: $w,
              has_cur: ($i != null),
              cur: (if $i == null then null else $cur[$i] end),
              has_rec: ($recs | has($w.uuid)),
              rec: $recs[$w.uuid]
            }
          | .action = (
              if .has_cur and .cur == .want then "same"
              elif .has_cur and .has_rec and .cur == .rec then "update"
              elif (.has_cur | not) and ($fresh or (.has_rec | not)) then "add"
              elif $force then (if .has_cur then "force" else "readd" end)
              elif .has_cur then (if .has_rec then "edited" else "differs" end)
              else "deleted" end)
          | .write = (.action == "add" or .action == "update" or .action == "force" or .action == "readd")
        ],
        pc_only: [$cur[] | objects | select(.uuid as $u | all($want[]; .uuid != $u)) | (.name // "(名前なし)" | tostring)]
      }' >"${work_dir}/plan.json"

  if ((dry_run)); then
    pre="[dry-run] "
  fi
  lines=$(jq -r --arg pre "${pre}" '.entries[] | select(.write)
    | "  \($pre)\(.name): \(
        if .action == "add" then "足す"
        elif .action == "update" then "書き換える (repo が更新された)"
        elif .action == "force" then "書き換える (--force)"
        else "足し直す (--force。PC に無かった)" end)"' "${work_dir}/plan.json")
  pc_only=$(jq -r '.pc_only | join("、")' "${work_dir}/plan.json")
  nwrite=$(jq '[.entries[] | select(.write)] | length' "${work_dir}/plan.json")
  nsame=$(jq '[.entries[] | select(.action == "same")] | length' "${work_dir}/plan.json")

  if ((nwrite == 0)); then
    save_record false
    if [[ $(jq '[.entries[] | select(.action != "same")] | length' "${work_dir}/plan.json") == 0 ]]; then
      if [[ -n ${pc_only} ]]; then
        echo "FancyZones のカスタムレイアウトは揃っています (dotfiles のもの ${nsame} 件。PC にだけあるもの $(jq '.pc_only | length' "${work_dir}/plan.json") 件には触りません)。"
      else
        echo "FancyZones のカスタムレイアウトは揃っています (dotfiles のもの ${nsame} 件)。"
      fi
    fi
    report_kept
    return 0
  fi

  if ((! dry_run)); then
    if [[ ${fresh} == true ]] && ! mkdir -p -- "${fz_dir}" 2>/dev/null; then
      warn "FancyZones の custom-layouts.json を作れませんでした: ${pc_layouts}" \
        "Windows 側のディレクトリを確かめてから、流し直してください。"
      save_record false
      report_kept
      return 0
    fi
    if ! backup_pc_layouts; then
      warn "FancyZones の custom-layouts.json を退避できないので、カスタムレイアウトを書きません: ${backup_root}" "${lines}"
      save_record false
      report_kept
      return 0
    fi
    if ! write_pc_layouts; then
      warn "FancyZones の custom-layouts.json に書けないので、カスタムレイアウトを足せませんでした: ${pc_layouts}" "${lines}"
      save_record false
      report_kept
      return 0
    fi
    touch -- "${pc_layouts}" 2>/dev/null \
      || warn "FancyZones の custom-layouts.json に書きましたが、FancyZones に読み直させられませんでした: ${pc_layouts}" \
        "PowerToys を起動し直すか、エディターを開いて閉じると読みます。"
    save_record true
  fi

  echo "==> ${pre}FancyZones のカスタムレイアウト (${pc_layouts})"
  if [[ ${fresh} == true ]]; then
    echo "  ${pre}custom-layouts.json が無いので作る"
  fi
  printf '%s\n' "${lines}"
  if [[ -n ${pc_only} ]]; then
    echo "  PC にだけあるレイアウトには触りません: ${pc_only}"
  fi
  if [[ -n ${backup_dir} ]]; then
    echo "  書き換える前のファイルは ${backup_dir} に退避しました。"
  fi
  report_kept
}

# ---- --import ----

# PC のレイアウトを名前で選び、repo の custom-layouts.json へ写す。同じ uuid は同じ位置で置き換え、無ければ末尾に足す。
# PC のファイル・settings.json・記録には書かない (次の setup が、PC と repo が同じと見て記録する)
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
import_layouts() {
  local problems changes errors line log changed tmp body names name_arg
  problems=$(layouts_problems)
  if [[ -n ${problems} ]]; then
    fail "${layouts_rel} に誤りがあるので、取り込めません。先に直してください:" "${problems}"
    return 1
  fi
  # 取り込みは repo のファイルを書き換える。commit していない変更 (未追跡も) があると痕跡なく消えるので、何も書かずに止まる。
  # git が無い・checkout の外で確かめられないときも止まる側に倒す。--no-optional-locks は index を書かないため
  if ! changes=$(git --no-optional-locks -C "${repo_dir}" status --porcelain --untracked-files=normal -- "${layouts_rel}" 2>&1); then
    fail "${layouts_rel} に commit していない変更が無いかを確かめられません (git が無いか、git の checkout ではない):" \
      "${changes}" \
      "--import は ${layouts_rel} を書き換え、commit していない変更を消しうるので、止めます。"
    return 1
  fi
  if [[ -n ${changes} ]]; then
    fail "${layouts_rel} に commit していない変更があります。--import は書き換えるので、先に commit するか、変更を戻してから流し直してください。" \
      "${changes}"
    return 1
  fi
  if [[ ! -e ${pc_layouts} ]]; then
    fail "PC に custom-layouts.json がありません: ${pc_layouts}"
    return 1
  fi
  if ! make_work_dir; then
    fail "一時ディレクトリを作れないので、取り込めません (TMPDIR=${TMPDIR:-/tmp})。"
    return 1
  fi
  if ! snapshot_pc_layouts; then
    fail "PC の custom-layouts.json を読めません: ${pc_layouts}"
    return 1
  fi
  # 名前は --arg で 1 つずつ JSON の配列にする (- で始まる名前も、jq の引数と取り違えない)
  names='[]'
  for name_arg in "${import_names[@]}"; do
    names=$(jq -c --arg n "${name_arg}" '. + [$n]' <<<"${names}")
  done
  printf '%s\n' "${names}" >"${work_dir}/names.json"
  jq -n --slurpfile repo "${layouts_file}" --slurpfile pc "${work_dir}/pc.json" --slurpfile names "${work_dir}/names.json" "${layouts_lib}"'
    ($pc[0] | layouts) as $cur
    | reduce $names[0][] as $n ({doc: $repo[0], log: [], errors: [], changed: false};
        [$cur[] | objects | select(.name == $n)] as $m
        | if ($m | length) == 0 then
            .errors += ["PC に「\($n)」というカスタムレイアウトがありません (PC にあるもの: \([$cur[] | objects | (.name // "(名前なし)" | tostring)] | join("、")))。"]
          elif ($m | length) > 1 then
            .errors += ["PC に「\($n)」というカスタムレイアウトが \($m | length) つあります (uuid: \([$m[] | (.uuid // "(無い)" | tostring)] | join("、")))。エディターで名前を変えてから取り込んでください。"]
          else
            $m[0] as $l
            | [{"custom-layouts": [$l]} | layout_problems] as $bad
            | if ($bad | length) > 0 then
                .errors += ["「\($n)」は repo に置けない形です: \($bad | join(" "))"]
              else
                (.doc["custom-layouts"] | uuid_index($l.uuid)) as $i
                | if $i != null then
                    if .doc["custom-layouts"][$i] == $l then
                      .log += ["  \($n): repo と同じです"]
                    else
                      .doc["custom-layouts"][$i] = $l | .changed = true | .log += ["  \($n): repo の同じ uuid のレイアウトを置き換えた"]
                    end
                  else
                    [.doc["custom-layouts"][] | select(.name == $n) | .uuid] as $same
                    | if ($same | length) > 0 then
                        .errors += ["repo に、同じ名前「\($n)」の別のレイアウトがあります (uuid: \($same | join("、")))。エディターで名前を変えてから取り込んでください。"]
                      else
                        .doc["custom-layouts"] += [$l] | .changed = true | .log += ["  \($n): 足した"]
                      end
                  end
              end
          end)' >"${work_dir}/import.json"
  errors=$(jq -r '.errors[]' "${work_dir}/import.json")
  if [[ -n ${errors} ]]; then
    while IFS= read -r line; do
      fail "${line}"
    done <<<"${errors}"
    echo "   何も取り込んでいません。" >&2
    return 1
  fi
  log=$(jq -r '.log[]' "${work_dir}/import.json")
  changed=$(jq -r '.changed' "${work_dir}/import.json")
  if [[ ${changed} != true ]]; then
    echo "取り込むものはありません (repo と同じです)。"
    printf '%s\n' "${log}"
    return 0
  fi
  # 名前を変えて取り込んだときなど、全体で誤りが無いか (name の重なり) を確かめてから書く
  problems=$(jq -r "${layouts_lib}"'.doc | layout_problems' "${work_dir}/import.json")
  if [[ -n ${problems} ]]; then
    fail "取り込むと ${layouts_rel} に誤りができるので、取り込めません:" "${problems}"
    return 1
  fi
  tmp="${layouts_file}.dotfiles-tmp"
  if ! body=$(jq '.doc' "${work_dir}/import.json" | to_pt_form) \
    || ! printf '%s' "${body}" 2>/dev/null >"${tmp}" || ! mv -f -- "${tmp}" "${layouts_file}" 2>/dev/null; then
    rm -f -- "${tmp}" 2>/dev/null || true
    fail "${layouts_rel} に書けませんでした: ${layouts_file}"
    return 1
  fi
  echo "==> PC のレイアウトを ${layouts_rel} へ取り込みました"
  printf '%s\n' "${log}"
  echo "git -C ${repo_dir} diff -- ${layouts_rel} で見て commit してください。"
  echo "push すると、ほかの PC には次の setup --update で足されます (その PC で直していたものは、書き換えずに知らせます)。"
}

# ---- 全体の設定 ----

# 全体の設定で FancyZones がオフなら、効かないことを知らせる。読みかけに当たっても読めるよう、5 回まで見る。
# キーやファイルが無ければオン (FancyZones は既定でオン)
check_enabled() {
  local i state
  [[ -e ${global_json} ]] || return 0
  for ((i = 0; i < 5; i++)); do
    if state=$(jq -r '.enabled.FancyZones' "${global_json}" 2>/dev/null) && [[ -n ${state} ]]; then
      if [[ ${state} == false ]]; then
        warn "FancyZones がオフなので、FancyZones の設定は効きません (全体の設定の enabled.FancyZones が false。${global_json})。" \
          "自動ではオンにしません。使うなら、PowerToys の設定画面で「ウィンドウとレイアウト」→「FancyZones」をオンにしてください。オンにすると、書いてある設定を読みます。"
      fi
      return 0
    fi
    sleep 1
  done
  warn "PowerToys の全体の設定を読めないので、FancyZones がオンかを確かめられません: ${global_json}"
}

if ((import_mode)); then
  import_layouts || exit 1
  exit 0
fi

sync_settings
sync_layouts
check_enabled
exit 0
