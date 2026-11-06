#!/usr/bin/env bash
# shellcheck shell=bash
#
# win/powertoys/fancyzones/managed.json のキーだけを、PowerToys の FancyZones の settings.json へ書く (冪等。更新時も毎回走る)。
#
# order: 92
#
# ^ setup.sh が読む実行順。bootstrap-windows-powertoys.sh (order: 91) が PowerToys を入れた後に走らせる。91 は
#   Keyboard Manager が使えないと早く抜けるので、FancyZones がその影響を受けないよう別の script にしてある。
#   仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# FancyZones の設定のうち、dotfiles で持ちたいキー (今は「Windows スナップのオーバーライド」) を全マシンで揃える
# (dotfiles-private の docs/adr/042_*)。settings.json は PowerToys が全部のキーを書き、設定画面でも書き換えるので、
# ファイルごとは配らない。managed.json に持つキーだけを書き、そのキーだけをここで書く。
# カスタムレイアウト (custom-layouts.json) はファイルごと manifest で配るので、この script は触らない。
#
# Windows Terminal (bootstrap-windows-terminal.sh) と違い、衝突にしない。値が違えば、手で変えていても dotfiles の値へ
# 戻し、戻したことを 1 行出す。PowerToys は全部のキーを書くので、Terminal の判定のままだと初回に既定の false と
# 衝突するため。記録・--import・退避は持たない。managed.json から消したキーは settings.json からは消さない
# (最後の値が残り、以後は戻さない)。
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
# 3. 隣に書いて mv した後に touch する。FancyZones は LastWriteTime の変更しか見ていないので、mv だけでは気づかない
#    (src/common/SettingsAPI/FileWatcher.cpp。実機で確かめた)。読みかけを見せないよう、その場には書かない。
#    PowerToys は起動し直さない
# 4. 全体の設定 <windowsHome>/AppData/Local/Microsoft/PowerToys/settings.json の enabled.FancyZones が false なら、
#    設定が効かないので警告する。自動でオンにはしない。キーやファイルが無ければオンとして扱う (FancyZones は既定でオン)。
#    読めないときは、確かめられないと警告する
#
# どの場合も exit 0 (後ろの手順を止めない)。引数の誤りだけ exit 2。--check は誤りがあれば exit 1。
# 知らせたことは、setup の最後の「警告のまとめ」にも残す (warn / summary_warn)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
win/powertoys/fancyzones/managed.json のキーだけを、PowerToys の FancyZones の settings.json へ書く。
設定画面で変えていても dotfiles の値へ戻す。FancyZones はその場で読み直す (PowerToys は起動し直さない)。

使い方:
  bootstrap-windows-fancyzones.sh            値が違えば書く
  bootstrap-windows-fancyzones.sh --dry-run  判定だけ出して何も書かない
  bootstrap-windows-fancyzones.sh --check    win/powertoys/fancyzones/ の検証だけ (state も settings.json も見ない)
EOS
}

dry_run=0
check=0
for arg in "$@"; do
  case ${arg} in
    --dry-run) dry_run=1 ;;
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
if ((check && dry_run)); then
  echo "--check と --dry-run は一緒に使えません。" >&2
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
state_file="${HOME}/.local/state/dotfiles/windows-files.json"

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
#   leaf_paths   持つキーのパスを並べる (object を辿った先の、object でない値 1 つが持つキー 1 つ)
#   apply($m)    $m の持つキーだけを書き込む
# shellcheck disable=SC2016 # jq の $ はシェルの展開ではない
jq_lib='
def leaf_paths:
  if type == "object" then to_entries[] | [.key] + (.value | leaf_paths) else [] end;
def apply($m):
  reduce ($m | leaf_paths) as $p (.; setpath($p; $m | getpath($p)));
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

if ! command -v jq &>/dev/null; then
  if ((check)); then
    echo "!! jq が見つかりません。" >&2
    exit 1
  fi
  warn "jq が見つかりません。先に home-manager switch を実行してください。この手順は飛ばします。"
  exit 0
fi

if ((check)); then
  problems=$(managed_problems)
  if [[ -n ${problems} ]]; then
    {
      echo "!! ${managed_rel} に誤りがあります:"
      printf '%s\n' "${problems}" | sed 's/^/   /'
    } >&2
    exit 1
  fi
  if ! jq -e '.["custom-layouts"] | type == "array"' "${repo_dir}/${layouts_rel}" >/dev/null 2>&1; then
    echo "!! ${layouts_rel} が、custom-layouts の配列を持つ JSON ではありません。" >&2
    exit 1
  fi
  n=$(jq "${jq_lib}"'[leaf_paths] | length' "${managed_file}")
  echo "win/powertoys/fancyzones/: OK (持つキー ${n} 件)"
  exit 0
fi

if [[ ! -r ${state_file} ]]; then
  echo "配り先の設定がありません (${state_file})。この手順は飛ばします。"
  exit 0
fi
if [[ $(jq -r '.enable' "${state_file}" 2>/dev/null) != true ]]; then
  echo "このマシンは Windows 側へ配りません (dotfiles.wsl.windowsFiles.enable = false)。"
  exit 0
fi
windows_home=$(jq -r '.windowsHome // ""' "${state_file}" 2>/dev/null) || windows_home=""
if [[ -z ${windows_home} || ! -d ${windows_home} ]]; then
  warn "Windows 側のホームが見えないので、FancyZones の設定を書きません: ${windows_home:-(windowsHome が空)}" \
    "/mnt/c が mount されているか、dotfiles.wsl.windowsUserName が合っているかを確かめてください。"
  exit 0
fi

problems=$(managed_problems)
if [[ -n ${problems} ]]; then
  warn "${managed_rel} に誤りがあるので、FancyZones の設定を書きません:" "${problems}"
  exit 0
fi

fz_dir="${windows_home}/AppData/Local/Microsoft/PowerToys/FancyZones"
settings_json="${fz_dir}/settings.json"
global_json="${windows_home}/AppData/Local/Microsoft/PowerToys/settings.json"
n=$(jq "${jq_lib}"'[leaf_paths] | length' "${managed_file}")

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

if [[ -e ${settings_json} ]]; then
  update_settings
else
  create_settings
fi
check_enabled
exit 0
