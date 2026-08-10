#!/usr/bin/env bash
# shellcheck shell=bash
#
# README.md 「適用 > 新規マシンの手順」を対話的に実行する。
# 何をするかは --help を参照。
#
# ## 設計メモ
#
# - **Nix が入る前に実行される**ので、依存できるのは bash / coreutils / curl だけ。
#   jq も fzf も gum も使えない。メニューは ANSI エスケープで自前描画している。
# - macOS の /bin/bash は 3.2 なので bash 4 以降の機能 (連想配列 / mapfile /
#   ${var,,} / nameref) は使わない。手順表は添字配列を並べて持つ。
# - bootstrap-*.sh は glob で **自動列挙** する。スクリプトを増やしても
#   このファイルの編集は要らない (claude.nix が readDir で列挙しているのと
#   同じ方針)。説明文も各スクリプト冒頭のコメントから取るので二重管理しない。
# - `set -e` は関数を if の条件に置くと **その中で無効になる**。手順の関数は
#   失敗しうるコマンドを必ず `|| return 1` で受けること。

set -eu -o pipefail

# ~/dotfiles/setup は このファイルへの symlink なので、$0 の指す先を辿って
# 実体の位置を出す。辿らないと nix_dir が ~ になる。
# macOS の readlink には -f が無いので手で辿る。
resolve_dir() {
  local src=$1 dir
  while [[ -L ${src} ]]; do
    dir=$(
      cd -P -- "$(dirname -- "${src}")" &>/dev/null
      pwd
    )
    src=$(readlink -- "${src}")
    case ${src} in
      /*) ;;
      *) src="${dir}/${src}" ;;
    esac
  done
  cd -P -- "$(dirname -- "${src}")" &>/dev/null
  pwd
}

script_dir=$(resolve_dir "$0")
nix_dir=$(dirname "${script_dir}")
repo_dir=$(dirname "${nix_dir}")
hosts_file="${nix_dir}/hosts/default.nix"

# 実行に使う flake。ローカル flake (~/dotfiles) があればそちらを優先する。
# 本体の homeConfigurations をそのまま再輸出しているので、登録簿のホストは
# どちらからでも同じように引ける。
# 詳細は setup-local-flake.sh の冒頭を参照。
local_dir=${DOTFILES_LOCAL_DIR:-${HOME}/dotfiles}
if [[ -f ${local_dir}/flake.nix ]]; then
  flake_dir=${local_dir}
else
  flake_dir=${nix_dir}
fi

dry_run=0
host=""
mode=""
steps_arg=""
nix_installer_args=${NIX_INSTALLER_ARGS:-install}

# home-manager switch に付ける `-b <拡張子>`。空文字なら付けない。
#
# ~/.bashrc / ~/.profile などが **実ファイルとして先に在る**とき、
# home-manager は勝手に消さずに switch を中断する。`-b` はそれらを
# <名前>.<拡張子> へ退避してから置き換える。付けるかどうかは好みが分かれる
# (退避ファイルが増えるのを嫌う人もいる) ので、こちらで決め打ちにせず
# メニューの `b` / --backup / --no-backup / DOTFILES_BACKUP_EXT で選ばせる。
backup_ext=""
backup_ext_default="backup"
# 明示的に決めたか。決めていないまま switch を実行しようとしていて、かつ
# 中断しそうなファイルが見つかったときだけメニューで訊く (下の ask_backup)。
backup_chosen=0
if [[ -n ${DOTFILES_BACKUP_EXT+x} ]]; then
  backup_ext=${DOTFILES_BACKUP_EXT}
  backup_chosen=1
fi

usage() {
  cat <<'EOS'
README.md 「適用 > 新規マシンの手順」を対話的に実行する。

使い方 (~/dotfiles/setup は このスクリプトへの symlink):
  setup.sh                 メニューを出す (既定)
  setup.sh --new-machine   「新しいマシン適用」をそのまま実行
  setup.sh --update        「既存マシン更新」をそのまま実行
  setup.sh --steps a,b,c   指定した手順だけ実行 (id は --list で確認)
  setup.sh --list          手順の一覧を出す
  setup.sh --host <名前>   対象ホスト (既定は hosts/default.nix から自動判定)
  setup.sh --dry-run       実行せず、走るコマンドを表示するだけ
  setup.sh -h, --help      これ

既存ファイル (~/.bashrc / ~/.profile など) の扱い:
  setup.sh --backup          <名前>.backup へ退避してから置き換える (-b backup)
  setup.sh --backup=<拡張子> 退避先の拡張子を変える (既定: backup)
  setup.sh --no-backup       退避しない (既定。衝突すると switch が中断する)

  指定が無いときは、中断しそうなファイルが在ればメニューで訊く。

メニューの操作:
  ↑/↓ (j/k) 移動   Space 選択の切替   Enter 決定/実行   q 戻る/中止
  h 対象ホストの変更   b 既存ファイルの退避   a 全選択   n 全解除

環境変数:
  DOTFILES_HOST        --host と同じ
  DOTFILES_LOCAL_DIR   ローカル flake の場所 (既定: ~/dotfiles)
  DOTFILES_BACKUP_EXT  --backup=<拡張子> と同じ。空文字なら --no-backup と同じ
  NIX_INSTALLER_ARGS   Determinate Systems インストーラへの引数 (既定: install)
                       systemd の無いコンテナでは "install linux --init none"
  NO_COLOR             色を付けない
EOS
}

##############
# 表示の道具 #
##############

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  c_reset=$'\033[0m'
  c_bold=$'\033[1m'
  c_dim=$'\033[2m'
  c_cyan=$'\033[36m'
  c_green=$'\033[32m'
  c_yellow=$'\033[33m'
  c_red=$'\033[31m'
else
  c_reset=""
  c_bold=""
  c_dim=""
  c_cyan=""
  c_green=""
  c_yellow=""
  c_red=""
fi

hr() {
  printf '%s────────────────────────────────────────────────────────%s\n' "${c_dim}" "${c_reset}"
}

note() {
  printf '  %s%s%s\n' "${c_dim}" "$*" "${c_reset}"
}

warn() {
  printf '%s!! %s%s\n' "${c_yellow}" "$*" "${c_reset}" >&2
}

die() {
  printf '%sERROR: %s%s\n' "${c_red}" "$*" "${c_reset}" >&2
  exit 1
}

have() {
  command -v "$1" &>/dev/null
}

# 実行するコマンドを見せてから実行する。--dry-run では見せるだけ。
run() {
  local a shown=""
  for a in "$@"; do
    # 表示専用のクォート。sh -c に渡すパイプ入りの文字列が
    # 1 引数だと分かるようにするためだけのもの。
    case ${a} in
      *[[:space:]\|\&\;]*) shown="${shown} '${a}'" ;;
      *) shown="${shown} ${a}" ;;
    esac
  done
  printf '%s+%s%s\n' "${c_cyan}" "${shown}" "${c_reset}"
  if [[ ${dry_run} == 1 ]]; then
    return 0
  fi
  "$@"
}

##########
# 手順表 #
##########

step_ids=()
step_labels=()
step_notes=()
step_kinds=()  # step | group  (group は実行されない見出し行)
step_depths=() # 0 | 1

add_step() {
  step_ids+=("$1")
  step_labels+=("$2")
  step_notes+=("$3")
  step_kinds+=("$4")
  step_depths+=("$5")
}

# bootstrap-*.sh 冒頭のコメントから説明の 1 行目を取り出す。
# メニューの説明をスクリプト側と二重に持たないため。
script_summary() {
  awk '
    /^#!/           { next }
    /^# shellcheck/ { next }
    /^#[ \t]*$/     { next }
    /^#/            { sub(/^#[ \t]?/, ""); print; exit }
                    { exit }
  ' "$1"
}

add_step nix-install \
  'Nix をインストール' \
  '手順 1。Determinate Systems 版 (flakes が最初から有効)。既にあれば飛ばす。' \
  step 0

add_step preflight-unlink \
  './nix/scripts/preflight-unlink.sh' \
  '手順 2。main.bash setup が張った symlink を外す。忘れると switch が中断する。' \
  step 0

add_step local-flake \
  './nix/scripts/setup-local-flake.sh' \
  'ローカル flake (~/dotfiles) と setup の symlink を置く。以後の入口になる。' \
  step 0

add_step switch \
  'home-manager switch' \
  '手順 3。初回は home-manager コマンドがまだ無いので nix run 経由で実行する。' \
  step 0

add_step bootstrap \
  'bootstrap (マシンごとに一度だけ)' \
  '下のスクリプトをまとめて選ぶ。いずれも冪等。' \
  group 0

# 手順 4 / 6。増えても自動でメニューに載る。
for f in "${script_dir}"/bootstrap-*.sh; do
  [[ -f ${f} ]] || continue
  base=$(basename "${f}")
  add_step "${base%.sh}" "./nix/scripts/${base}" "$(script_summary "${f}")" step 1
done
unset f base

add_step chsh \
  'ログインシェルを fish に変更' \
  '手順 7。/etc/shells への追記に sudo が要る。必要なときだけ。' \
  step 0

step_count=${#step_ids[@]}

sel=()
for ((idx = 0; idx < step_count; idx++)); do
  sel+=(0)
done
unset idx

index_of() {
  local i
  for ((i = 0; i < step_count; i++)); do
    if [[ ${step_ids[i]} == "$1" ]]; then
      printf '%d' "${i}"
      return 0
    fi
  done
  return 1
}

# group の子 (= bootstrap-*.sh) の id を並べる
child_ids() {
  local i
  for ((i = 0; i < step_count; i++)); do
    if [[ ${step_depths[i]} == 1 ]]; then
      printf '%s\n' "${step_ids[i]}"
    fi
  done
}

select_only() {
  local id i
  for ((i = 0; i < step_count; i++)); do
    sel[i]=0
  done
  for id in "$@"; do
    if ! i=$(index_of "${id}"); then
      die "そんな手順は無い: ${id}  (一覧は --list)"
    fi
    sel[i]=1
  done
}

is_selected() {
  local i
  if ! i=$(index_of "$1"); then
    return 1
  fi
  [[ ${sel[i]} == 1 ]]
}

apply_preset() {
  local ids=() id
  case $1 in
    new-machine)
      # 手順 1 → 2 → 3 → 4/6。
      # 手順 7 (chsh) は README でも「必要なら」なので既定では入れない。
      ids=(nix-install preflight-unlink local-flake switch)
      while IFS= read -r id; do
        ids+=("${id}")
      done < <(child_ids)
      ;;
    update)
      # README 「2 回目以降」。bootstrap は済んでいる前提なので switch だけ。
      # 入れ直したくなったらカスタムか --steps で選ぶ。
      ids=(switch)
      ;;
    *) die "unknown preset: $1" ;;
  esac
  select_only "${ids[@]}"
}

# 選択されている手順の添字を **手順表の並び順** で返す。
# 手順には順序の依存があるので、選んだ順ではなく定義順に実行する。
selected_indexes() {
  local i
  for ((i = 0; i < step_count; i++)); do
    if [[ ${step_kinds[i]} == group ]]; then
      continue
    fi
    if [[ ${sel[i]} == 1 ]]; then
      printf '%d\n' "${i}"
    fi
  done
}

list_steps() {
  local i
  printf '%s手順の id (--steps に渡せる)%s\n' "${c_bold}" "${c_reset}"
  for ((i = 0; i < step_count; i++)); do
    if [[ ${step_kinds[i]} == group ]]; then
      continue
    fi
    printf '  %-24s %s\n' "${step_ids[i]}" "${step_labels[i]}"
  done
}

##########
# ホスト #
##########

# `<名前> = mkHome {` / `"<名前>" = dotfiles.lib.mkHome {` の左辺を取り出す。
# 修飾子 (dotfiles.lib.) が付くのはローカル flake 側の書き方。
# 行頭が # の行は拾わないので、雛形のコメント例は出てこない。
parse_hosts() {
  [[ -f $1 ]] || return 0
  sed -n \
    -e 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*=[[:space:]]*[A-Za-z0-9_.]*mkHome.*/\1/p' \
    -e 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_-]*\)[[:space:]]*=[[:space:]]*[A-Za-z0-9_.]*mkHome.*/\1/p' \
    "$1"
}

# 選べる登録名を並べる。
#
# 本体の登録簿だけでなく **ローカル flake (~/dotfiles/flake.nix) の追加分も**
# 見る。見ないと ~/dotfiles にだけ足したホストがメニューに出ず、--host で
# 指定しても「登録されていません」で弾かれる。
#
# 手順 1 の前に呼ぶので nix には頼れず、sed で拾う。
# sandbox は検証専用なので外す。
list_hosts() {
  {
    parse_hosts "${hosts_file}"
    if [[ ${flake_dir} != "${nix_dir}" ]]; then
      parse_hosts "${flake_dir}/flake.nix"
    fi
  } | grep -vx 'sandbox' | awk '!seen[$0]++' || true
}

is_wsl() {
  if [[ -n ${WSL_DISTRO_NAME:-} ]]; then
    return 0
  fi
  grep -qi microsoft /proc/version 2>/dev/null
}

# $USER と uname から登録名を推測する。当たらなければ 1 を返して呼び元に選ばせる。
detect_host() {
  local user os arch system registered candidates=() cand
  user=${USER:-$(id -un)}
  os=$(uname -s)
  arch=$(uname -m)
  case ${arch} in
    x86_64 | amd64) arch=x86_64 ;;
    arm64 | aarch64) arch=aarch64 ;;
  esac
  case ${os} in
    Darwin) system="${arch}-darwin" ;;
    *) system="${arch}-linux" ;;
  esac

  if is_wsl; then
    candidates+=("${user}@wsl")
  fi
  candidates+=("${user}@${system}")

  registered=$(list_hosts)
  for cand in "${candidates[@]}"; do
    if printf '%s\n' "${registered}" | grep -qxF "${cand}"; then
      printf '%s' "${cand}"
      return 0
    fi
  done
  return 1
}

ensure_host_registered() {
  if [[ -z ${host} ]]; then
    warn "対象ホストが決まっていません。--host <名前> で指定してください。"
  elif list_hosts | grep -qxF "${host}"; then
    return 0
  else
    warn "${host} は登録されていません (手順 0)。"
    warn "  登録簿:       ${hosts_file}"
    if [[ ${flake_dir} != "${nix_dir}" ]]; then
      warn "  ローカル追加: ${flake_dir}/flake.nix"
    fi
  fi
  printf '   登録済み:\n' >&2
  list_hosts | sed 's/^/     /' >&2
  return 1
}

###########################
# 既存ファイルの退避 (-b)  #
###########################

# home-manager が書くパスのうち、**先に実ファイルとして在りがち**なもの。
#
# ~/.bashrc / ~/.profile / ~/.bash_profile は programs.bash が書く。
# ディストリの初期ファイルや main.bash の追記がそのまま残っているのが普通で、
# symlink ではないので preflight-unlink.sh では外れない (外すべきものでもない。
# 中身を確認してから捨てたいファイルなので退避して残す)。
#
# この一覧は **注意書きを出すため**だけに使う。実際の判定は home-manager 自身が
# activate 時に行うので、漏れがあっても switch の挙動は変わらない。
hm_managed_paths=(
  # programs.bash
  ".bashrc"
  ".bash_profile"
  ".profile"
  # programs.fish
  ".config/fish/config.fish"
  # programs.git
  ".config/git/config"
  ".config/git/ignore"
  # modules/files.nix
  ".screenrc"
  ".tmux.conf"
  ".vimrc"
  ".vim/common.vim"
  ".vim/clipboard.vim"
  ".config/starship.toml"
  ".config/zellij/config.kdl"
  ".config/nvim/init.vim"
  ".config/tmux/interactive_shell.tmux.conf"
)

# home-manager は <名前>.<拡張子> を作るので、拡張子に . や / は入れない。
# 空文字は「退避しない」の意味なので、ここには渡さない。
validate_backup_ext() {
  case ${1:?} in
    .*) die "拡張子の先頭に . は要りません (~/.bashrc.$1 になります)" ;;
    */* | *[[:space:]]*) die "退避先の拡張子に / と空白は使えません: $1" ;;
  esac
}

# 退避しないと switch が中断するパスを並べる。
#
# 数えるのは **実ファイル/実ディレクトリ**だけ。旧経路が張った symlink も
# 同じく switch を止めるが、そちらは preflight-unlink.sh が外す担当で
# 直し方が違うため、-b の判断材料には混ぜない。
clobber_paths() {
  local p full
  for p in "${hm_managed_paths[@]}"; do
    full="${HOME}/${p}"
    if [[ -e ${full} && ! -L ${full} ]]; then
      printf '%s\n' "${full}"
    fi
  done
}

# -b を付けても失敗するパス (退避先が既に在るもの) を並べる。
# home-manager は退避先を上書きしないので、残骸があると switch が止まる。
# 拡張子は引数で受ける (まだ確定していない候補についても見たいため)。
backup_collision_paths() {
  local ext=${1:?} p full
  for p in "${hm_managed_paths[@]}"; do
    full="${HOME}/${p}.${ext}"
    if [[ -e ${full} || -L ${full} ]]; then
      printf '%s\n' "${full}"
    fi
  done
}

backup_summary() {
  if [[ -n ${backup_ext} ]]; then
    printf -- '-b %s で退避する' "${backup_ext}"
  else
    printf '退避しない'
  fi
}

##########
# TUI    #
##########

tui_active=0

tui_begin() {
  tui_active=1
  # 代替スクリーンへ退避してカーソルを隠す。抜けると元の画面がそのまま戻る。
  printf '\033[?1049h\033[?25l'
}

tui_end() {
  if [[ ${tui_active} == 1 ]]; then
    tui_active=0
    printf '\033[?25h\033[?1049l'
  fi
}

trap tui_end EXIT

clear_screen() {
  printf '\033[H\033[2J'
}

# read -t の小数指定は bash 4 以降。3.2 では 1 秒待ちに落とす
# (ESC 単独は使わないので実害は無い)。
esc_wait=1
if ((BASH_VERSINFO[0] >= 4)); then
  esc_wait=0.05
fi

key=""

# 押されたキーを $key に入れる。矢印キーは 3 バイトのエスケープシーケンス。
read_key() {
  local k rest
  key=""
  IFS= read -rsn1 k || return 1
  if [[ ${k} == $'\033' ]]; then
    read -rsn2 -t "${esc_wait}" rest || rest=""
    case ${rest} in
      '[A') key=up ;;
      '[B') key=down ;;
      *) key=esc ;;
    esac
    return 0
  fi
  case ${k} in
    # Enter は tty が CR を LF に変換し、それが read の区切りとして
    # 食われるので空文字になる。$'\r' は ICRNL が無い環境向けの保険。
    '' | $'\r') key=enter ;;
    ' ') key=space ;;
    *) key=${k} ;;
  esac
}

header() {
  printf '%sdotfiles / nix セットアップ%s\n' "${c_bold}" "${c_reset}"
  note 'README.md 「適用 > 新規マシンの手順」を実行する'
  printf '\n'
  if [[ -n ${host} ]]; then
    printf '  対象ホスト: %s%s%s  %s(h で変更)%s\n' \
      "${c_green}" "${host}" "${c_reset}" "${c_dim}" "${c_reset}"
  else
    printf '  対象ホスト: %s未判定%s  %s(h で選ぶ / 手順 0 が未了かも)%s\n' \
      "${c_red}" "${c_reset}" "${c_dim}" "${c_reset}"
  fi
  if [[ -n ${backup_ext} ]]; then
    printf '  既存ファイル: %s%s%s  %s(b で変更)%s\n' \
      "${c_green}" "$(backup_summary)" "${c_reset}" "${c_dim}" "${c_reset}"
  else
    printf '  既存ファイル: %s  %s(b で変更)%s\n' \
      "$(backup_summary)" "${c_dim}" "${c_reset}"
  fi
  note "flake:      ${flake_dir}"
  if [[ ${flake_dir} != "${nix_dir}" ]]; then
    note "本体:       ${repo_dir}"
  fi
  if [[ ${dry_run} == 1 ]]; then
    printf '  %s--dry-run: 実際には実行しません%s\n' "${c_yellow}" "${c_reset}"
  fi
  printf '\n'
}

# プリセットで実行される手順を並べる (メニュー下部のプレビュー用)
preview_preset() {
  local saved=() i n=0
  for ((i = 0; i < step_count; i++)); do
    saved+=("${sel[i]}")
  done
  apply_preset "$1"
  while IFS= read -r i; do
    n=$((n + 1))
    printf '    %d. %s\n' "${n}" "${step_labels[i]}"
  done < <(selected_indexes)
  for ((i = 0; i < step_count; i++)); do
    sel[i]=${saved[i]}
  done
}

menu_main() {
  local cursor=0 count=4 i labels=()
  labels=(
    '新しいマシン適用'
    '既存マシン更新'
    'カスタム'
    '終了'
  )
  while :; do
    clear_screen
    header
    note '↑/↓ 移動   Enter 決定   h ホスト変更   b 既存ファイルの退避   q 中止'
    printf '\n'
    for ((i = 0; i < count; i++)); do
      if [[ ${i} == "${cursor}" ]]; then
        printf '  %s❯ %s%s\n' "${c_green}" "${labels[i]}" "${c_reset}"
      else
        printf '    %s\n' "${labels[i]}"
      fi
    done
    printf '\n'
    hr
    case ${cursor} in
      0)
        printf '  %s実行される手順:%s\n' "${c_dim}" "${c_reset}"
        preview_preset new-machine
        ;;
      1)
        printf '  %s実行される手順:%s\n' "${c_dim}" "${c_reset}"
        preview_preset update
        note '(bootstrap を入れ直したいときは「カスタム」で選ぶ)'
        ;;
      2) note '次の画面で手順を 1 つずつ選ぶ。' ;;
      3) note '何もせずに終了する。' ;;
    esac

    read_key || return 1
    case ${key} in
      up | k) cursor=$(((cursor + count - 1) % count)) ;;
      down | j) cursor=$(((cursor + 1) % count)) ;;
      h) menu_host ;;
      b) menu_backup ;;
      q) return 1 ;;
      enter)
        case ${cursor} in
          0)
            apply_preset new-machine
            ask_backup
            return 0
            ;;
          1)
            apply_preset update
            ask_backup
            return 0
            ;;
          2)
            if menu_steps; then
              ask_backup
              return 0
            fi
            ;;
          3) return 1 ;;
        esac
        ;;
    esac
  done
}

# チェックボックスの表示。group は子の状態から [x] / [-] / [ ] を決める。
checkbox_of() {
  local i=$1 on=0 off=0 j
  if [[ ${step_kinds[i]} != group ]]; then
    if [[ ${sel[i]} == 1 ]]; then
      printf '[x]'
    else
      printf '[ ]'
    fi
    return 0
  fi
  for ((j = 0; j < step_count; j++)); do
    if [[ ${step_depths[j]} != 1 ]]; then
      continue
    fi
    if [[ ${sel[j]} == 1 ]]; then
      on=$((on + 1))
    else
      off=$((off + 1))
    fi
  done
  if [[ ${on} -gt 0 && ${off} -eq 0 ]]; then
    printf '[x]'
  elif [[ ${on} -gt 0 ]]; then
    printf '[-]'
  else
    printf '[ ]'
  fi
}

toggle_at() {
  local i=$1 j all_on=1
  if [[ ${step_kinds[i]} != group ]]; then
    if [[ ${sel[i]} == 1 ]]; then
      sel[i]=0
    else
      sel[i]=1
    fi
    return 0
  fi
  # group は子をまとめて切り替える
  for ((j = 0; j < step_count; j++)); do
    if [[ ${step_depths[j]} == 1 && ${sel[j]} == 0 ]]; then
      all_on=0
    fi
  done
  for ((j = 0; j < step_count; j++)); do
    if [[ ${step_depths[j]} == 1 ]]; then
      if [[ ${all_on} == 1 ]]; then
        sel[j]=0
      else
        sel[j]=1
      fi
    fi
  done
}

set_all() {
  local i
  for ((i = 0; i < step_count; i++)); do
    sel[i]=$1
  done
}

# 手順によっては実行時に決まる値 (ホストなど) を説明に足す
note_of() {
  local i=$1 extra=""
  case ${step_ids[i]} in
    switch)
      if [[ -n ${backup_ext} ]]; then
        extra=" -b ${backup_ext}"
      fi
      printf '%s (--flake %s#%s%s)' \
        "${step_notes[i]}" "${flake_dir}" "${host:-<ホスト未定>}" "${extra}"
      ;;
    *) printf '%s' "${step_notes[i]}" ;;
  esac
}

menu_steps() {
  local cursor=0 i indent
  while :; do
    clear_screen
    header
    note '↑/↓ 移動   Space 選択   a 全選択   n 全解除   b 退避   Enter 実行   q 戻る'
    printf '\n'
    for ((i = 0; i < step_count; i++)); do
      indent=""
      if [[ ${step_depths[i]} == 1 ]]; then
        indent="  "
      fi
      if [[ ${i} == "${cursor}" ]]; then
        printf '  %s❯ %s %s%s%s\n' \
          "${c_green}" "$(checkbox_of "${i}")" "${indent}" "${step_labels[i]}" "${c_reset}"
      else
        printf '    %s %s%s\n' "$(checkbox_of "${i}")" "${indent}" "${step_labels[i]}"
      fi
    done
    printf '\n'
    hr
    printf '  %s%s%s\n' "${c_dim}" "$(note_of "${cursor}")" "${c_reset}"

    read_key || return 1
    case ${key} in
      up | k) cursor=$(((cursor + step_count - 1) % step_count)) ;;
      down | j) cursor=$(((cursor + 1) % step_count)) ;;
      space) toggle_at "${cursor}" ;;
      a) set_all 1 ;;
      n) set_all 0 ;;
      h) menu_host ;;
      b) menu_backup ;;
      q | esc) return 1 ;;
      enter)
        if [[ -z $(selected_indexes) ]]; then
          continue
        fi
        return 0
        ;;
    esac
  done
}

menu_host() {
  local hosts=() cursor=0 i h
  while IFS= read -r h; do
    hosts+=("${h}")
  done < <(list_hosts)
  if [[ ${#hosts[@]} -eq 0 ]]; then
    return 1
  fi
  for ((i = 0; i < ${#hosts[@]}; i++)); do
    if [[ ${hosts[i]} == "${host}" ]]; then
      cursor=${i}
    fi
  done
  while :; do
    clear_screen
    header
    note '対象ホストを選ぶ   ↑/↓ 移動   Enter 決定   q 戻る'
    printf '\n'
    for ((i = 0; i < ${#hosts[@]}; i++)); do
      if [[ ${i} == "${cursor}" ]]; then
        printf '  %s❯ %s%s\n' "${c_green}" "${hosts[i]}" "${c_reset}"
      else
        printf '    %s\n' "${hosts[i]}"
      fi
    done
    printf '\n'
    hr
    note "登録簿: ${hosts_file}"
    if [[ ${flake_dir} != "${nix_dir}" ]]; then
      note "ローカル: ${flake_dir}/flake.nix (このマシンだけのホスト)"
    fi
    note '無いマシンは hosts/default.nix か ~/dotfiles/flake.nix に足す'

    read_key || return 1
    case ${key} in
      up | k) cursor=$(((cursor + ${#hosts[@]} - 1) % ${#hosts[@]})) ;;
      down | j) cursor=$(((cursor + 1) % ${#hosts[@]})) ;;
      q | esc) return 1 ;;
      enter)
        host=${hosts[cursor]}
        return 0
        ;;
    esac
  done
}

# 既存ファイルを退避するか (`-b <拡張子>`) を選ぶ。
#
# ~/.bashrc / ~/.profile はディストリの初期ファイルがまず在るので、新しい
# マシンではほぼ必ずここに当たる。switch が中断してから調べ直すのは手戻りなので、
# 当たりそうなときは実行前にこの画面を出す (ask_backup)。
menu_backup() {
  local cursor=0 ext i n labels=() conflicts=() collisions line
  ext=${backup_ext:-${backup_ext_default}}
  labels=(
    '退避しない'
    "-b ${ext} で退避してから置き換える"
  )
  while IFS= read -r line; do
    conflicts+=("${line}")
  done < <(clobber_paths)
  if [[ -n ${backup_ext} ]]; then
    cursor=1
  elif [[ ${backup_chosen} == 0 && ${#conflicts[@]} -gt 0 ]]; then
    # まだ決めていなくて中断しそうなら、退避する側から見せる
    cursor=1
  fi

  while :; do
    clear_screen
    header
    note '既存ファイルの扱いを選ぶ   ↑/↓ 移動   Enter 決定   q 戻る'
    printf '\n'
    for ((i = 0; i < 2; i++)); do
      if [[ ${i} == "${cursor}" ]]; then
        printf '  %s❯ %s%s\n' "${c_green}" "${labels[i]}" "${c_reset}"
      else
        printf '    %s\n' "${labels[i]}"
      fi
    done
    printf '\n'
    hr
    case ${cursor} in
      0)
        note 'home-manager は自分が作ったのではないファイルを消さないので、'
        note '下のファイルが残っていると switch はそこで中断する。'
        note '中身を確認して手で退けたい場合はこちら。'
        ;;
      1)
        note "下のファイルを <名前>.${ext} へ改名してから置き換える。"
        note '中身 (main.bash の追記など) は残るので後から見比べられる。'
        collisions=$(backup_collision_paths "${ext}")
        if [[ -n ${collisions} ]]; then
          printf '  %s!! 退避先が既にあります。上書きされないので switch は失敗します:%s\n' \
            "${c_yellow}" "${c_reset}"
          printf '%s\n' "${collisions}" | sed 's/^/       /'
          note '  先に消すか、--backup=<別の拡張子> を使う。'
        fi
        ;;
    esac
    printf '\n'
    n=${#conflicts[@]}
    if [[ ${n} -gt 0 ]]; then
      printf '  %s中断させる実ファイル (%d 件):%s\n' "${c_yellow}" "${n}" "${c_reset}"
      for ((i = 0; i < n && i < 8; i++)); do
        note "  ${conflicts[i]}"
      done
      if [[ ${n} -gt 8 ]]; then
        note "  ... 他 $((n - 8)) 件"
      fi
    else
      note '中断させる実ファイルは見つかりません (どちらでも同じ結果になる)。'
    fi

    read_key || return 1
    case ${key} in
      up | k | down | j) cursor=$(((cursor + 1) % 2)) ;;
      q | esc) return 1 ;;
      enter)
        if [[ ${cursor} == 1 ]]; then
          backup_ext=${ext}
        else
          backup_ext=""
        fi
        backup_chosen=1
        return 0
        ;;
    esac
  done
}

# switch を実行する前に、まだ決めていなければ退避の有無を訊く。
# 中断しそうなファイルが無いときは訊かない (選んでも結果が変わらない)。
ask_backup() {
  if [[ ${backup_chosen} == 1 ]] || ! is_selected switch; then
    return 0
  fi
  if [[ -z $(clobber_paths) ]]; then
    return 0
  fi
  menu_backup || true
}

##############
# 手順の中身 #
##############

# Nix インストーラは **これから起動するシェル** に PATH を通す。
# 続きの手順を同じプロセスで走らせるため profile をここで読み込む。
load_nix_profile() {
  local f
  for f in \
    /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
    /nix/var/nix/profiles/default/etc/profile.d/nix.sh \
    "${HOME}/.nix-profile/etc/profile.d/nix.sh"; do
    if [[ -r ${f} ]]; then
      note ". ${f}"
      # profile スクリプトは set -eu を前提に書かれていない
      set +eu
      # shellcheck source=/dev/null
      . "${f}"
      set -eu
      return 0
    fi
  done
  return 1
}

step_nix_install() {
  if have nix; then
    note "nix は既にあります ($(command -v nix))。飛ばします。"
    return 0
  fi
  if ! have curl; then
    warn "curl がありません。先に curl を入れてください。"
    return 1
  fi
  # README 「Nix のインストール」と同じ Determinate Systems 版。
  # flakes が最初から有効なので nix.conf を自分で書かなくてよい。
  run sh -c "curl -fsSL https://install.determinate.systems/nix | sh -s -- ${nix_installer_args}" || return 1
  if [[ ${dry_run} == 1 ]]; then
    return 0
  fi
  if ! load_nix_profile; then
    warn "nix の profile スクリプトが見つかりませんでした。"
  fi
  if ! have nix; then
    warn "nix がまだ PATH にありません。ログインし直してから続きを実行してください。"
    return 1
  fi
}

step_script() {
  local path="${script_dir}/$1"
  if [[ ! -x ${path} ]]; then
    warn "実行できません: ${path}"
    return 1
  fi
  run "${path}" || return 1
}

step_local_flake() {
  step_script setup-local-flake.sh || return 1
  # 今この実行で作られたばかりのこともあるので選び直す。
  if [[ -f ${local_dir}/flake.nix ]]; then
    flake_dir=${local_dir}
  fi
}

# untracked ファイルが評価に入るかは flake の指し方で変わる。
#
#   --flake <repo>/nix   git リポジトリ内のパス -> git 解決。追跡済みしか見えない。
#   --flake ~/dotfiles   path: でのディレクトリ複製 -> untracked も入る。
#
# 前者では追加したモジュールが untracked のままだと評価に入らず、
# 「そんなオプションは無い」という分かりにくいエラーになる。
# 後者では手元で通ってしまうので、逆に commit 忘れが CI で出る。
warn_untracked() {
  local untracked
  if ! have git; then
    return 0
  fi
  if ! git -C "${nix_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    return 0
  fi
  untracked=$(git -C "${nix_dir}" ls-files --others --exclude-standard -- "${nix_dir}")
  if [[ -z ${untracked} ]]; then
    return 0
  fi
  if [[ ${flake_dir} == "${nix_dir}" ]]; then
    warn "git 未追跡のファイルがあります。flake からは見えません:"
    printf '%s\n' "${untracked}" | sed 's/^/     /' >&2
    warn "必要なら git add してから実行してください。"
  else
    warn "git 未追跡のファイルがあります (path: 経由なので今回の switch には入ります):"
    printf '%s\n' "${untracked}" | sed 's/^/     /' >&2
    warn "CI は git 管理下しか見ないので、残すなら git add してください。"
  fi
}

# 退避の有無が実際に効くファイルを実行直前に出す。
# --new-machine のようにメニューを通らない経路では、ここが唯一の知らせになる。
warn_clobber() {
  local paths
  if [[ -n ${backup_ext} ]]; then
    note "既存ファイルは <名前>.${backup_ext} へ退避してから置き換えます (-b ${backup_ext})。"
    paths=$(backup_collision_paths "${backup_ext}")
    if [[ -n ${paths} ]]; then
      warn "退避先が既にあります。上書きされないので switch は失敗します:"
      printf '%s\n' "${paths}" | sed 's/^/     /' >&2
      warn "先に消すか、--backup=<別の拡張子> を使ってください。"
    fi
    return 0
  fi
  paths=$(clobber_paths)
  if [[ -n ${paths} ]]; then
    warn "home-manager 管理下ではない実ファイルがあります:"
    printf '%s\n' "${paths}" | sed 's/^/     /' >&2
    warn "退避しない設定なので、switch はこれらで中断します。"
    warn "退避するなら --backup を付けて実行してください (メニューでは b)。"
  fi
}

step_switch() {
  local hm_args=()
  ensure_host_registered || return 1
  warn_untracked
  warn_clobber
  hm_args=(switch --flake "${flake_dir}#${host}")
  if [[ -n ${backup_ext} ]]; then
    hm_args+=(-b "${backup_ext}")
  fi
  if have home-manager; then
    # 2 回目以降。profile に入った CLI をそのまま使う。
    run home-manager "${hm_args[@]}" || return 1
    return 0
  fi
  # 初回。programs.home-manager.enable が CLI を profile へ入れるのは
  # activate が成功した後なので、まだ home-manager コマンドが無い。
  # レジストリ経由の `nix run home-manager` は flake.lock で固定したものと
  # 別バージョンになるため使わない (README の警告)。
  if ! have nix && [[ ${dry_run} == 0 ]]; then
    warn "nix がありません。手順「Nix をインストール」を先に実行してください。"
    return 1
  fi
  run nix run "${flake_dir}#home-manager" -- "${hm_args[@]}" || return 1
}

step_chsh() {
  local fish_path
  fish_path=$(command -v fish 2>/dev/null || true)
  if [[ -z ${fish_path} ]]; then
    if [[ ${dry_run} == 1 ]]; then
      # まだ switch していないので fish が無いのは当たり前。
      # --dry-run では実行予定を見せるだけにする。
      note '(fish は switch 後に入る。パスは実行時に解決する)'
      fish_path='<fish のパス>'
    else
      warn "fish が見つかりません。先に home-manager switch を実行してください。"
      return 1
    fi
  fi
  if [[ ${SHELL:-} == "${fish_path}" ]]; then
    note "既にログインシェルは ${fish_path} です。飛ばします。"
    return 0
  fi
  # /etc/shells に無いシェルは chsh が受け付けない
  if ! grep -qxF "${fish_path}" /etc/shells 2>/dev/null; then
    run sh -c "printf '%s\n' '${fish_path}' | sudo tee -a /etc/shells >/dev/null" || return 1
  fi
  run chsh -s "${fish_path}" || return 1
}

run_step() {
  case $1 in
    nix-install) step_nix_install ;;
    preflight-unlink) step_script preflight-unlink.sh ;;
    local-flake) step_local_flake ;;
    switch) step_switch ;;
    chsh) step_chsh ;;
    bootstrap-*) step_script "$1.sh" ;;
    *)
      warn "未実装の手順: $1"
      return 1
      ;;
  esac
}

##########
# 実行   #
##########

# 自動化できない手順 (0 / 5 / 7) と、次にやることを出す
post_notes() {
  printf '\n%s==> 残りの手作業%s\n' "${c_bold}" "${c_reset}"
  if is_selected bootstrap-mise; then
    note '手順 5: 既存マシンは ~/.config/mise/config.toml を手で整理する。'
    note '        go / node / usage だけ残す。消さないと mise の shim が'
    note '        PATH の先頭に居座り Nix 側のツールが使われない。'
  fi
  if ! is_selected chsh; then
    note '手順 7: ログインシェルを変えるなら --steps chsh (sudo が要る)。'
  fi
  if is_selected switch && [[ -n ${backup_ext} ]]; then
    note "退避したファイルは <名前>.${backup_ext} に残っている。中身 (main.bash の"
    note "        追記など) を確認して、要らなければ消す。次に -b ${backup_ext} で"
    note '        switch するとき、残っていると失敗する。'
  fi
  if is_selected switch && ! have home-manager; then
    note 'home-manager コマンドは新しいシェルから使える。今のシェルで使うなら:'
    note '  . ~/.nix-profile/etc/profile.d/nix.sh'
  fi
  if [[ ${flake_dir} == "${nix_dir}" ]]; then
    note 'ローカル flake が未設置です。一度だけ --steps local-flake を実行すると'
    note '        以後 ~/dotfiles/setup と ~/dotfiles#<ホスト> から扱えます。'
  fi
  note "設定の検証: ${script_dir}/verify.sh"
}

execute() {
  local idxs=() states=() i n total failed=0

  while IFS= read -r i; do
    idxs+=("${i}")
  done < <(selected_indexes)
  total=${#idxs[@]}
  if [[ ${total} -eq 0 ]]; then
    warn "手順が選ばれていません。"
    return 1
  fi

  printf '\n%s==> 実行する手順%s\n' "${c_bold}" "${c_reset}"
  for ((n = 0; n < total; n++)); do
    i=${idxs[n]}
    printf '  %d. %s\n' "$((n + 1))" "${step_labels[i]}"
    states+=("pending")
  done
  note "対象ホスト: ${host:-<未定>}"
  if is_selected switch; then
    note "既存ファイル: $(backup_summary)"
  fi

  for ((n = 0; n < total; n++)); do
    i=${idxs[n]}
    printf '\n'
    hr
    printf '%s[%d/%d] %s%s\n' "${c_bold}" "$((n + 1))" "${total}" "${step_labels[i]}" "${c_reset}"
    hr
    if run_step "${step_ids[i]}"; then
      states[n]="ok"
    else
      states[n]="fail"
      failed=1
      # 手順には順序の依存がある。途中で失敗したら残りは走らせない。
      break
    fi
  done

  printf '\n%s==> 結果%s\n' "${c_bold}" "${c_reset}"
  for ((n = 0; n < total; n++)); do
    i=${idxs[n]}
    case ${states[n]} in
      ok) printf '  %s✔%s %s\n' "${c_green}" "${c_reset}" "${step_labels[i]}" ;;
      fail) printf '  %s✖%s %s\n' "${c_red}" "${c_reset}" "${step_labels[i]}" ;;
      *) printf '  %s· %s (未実行)%s\n' "${c_dim}" "${step_labels[i]}" "${c_reset}" ;;
    esac
  done

  if [[ ${failed} == 1 ]]; then
    printf '\n%s失敗した手順があります。直してから同じ手順を選び直してください。%s\n' \
      "${c_red}" "${c_reset}" >&2
    return 1
  fi

  post_notes
  return 0
}

##########
# main   #
##########

while [[ $# -gt 0 ]]; do
  case $1 in
    --new-machine) mode=new-machine ;;
    --update) mode=update ;;
    --steps)
      shift
      [[ $# -gt 0 ]] || die "--steps に手順 id を渡してください (一覧は --list)"
      steps_arg=$1
      mode=steps
      ;;
    --steps=*)
      steps_arg=${1#*=}
      mode=steps
      ;;
    --host)
      shift
      [[ $# -gt 0 ]] || die "--host にホスト名を渡してください"
      host=$1
      ;;
    --host=*) host=${1#*=} ;;
    --backup)
      backup_ext=${backup_ext_default}
      backup_chosen=1
      ;;
    --backup=*)
      backup_ext=${1#*=}
      # `--backup=` は意図が読めないので弾く (退避しないなら --no-backup)
      [[ -n ${backup_ext} ]] || die "--backup=<拡張子> が空です (退避しないなら --no-backup)"
      backup_chosen=1
      ;;
    --no-backup)
      backup_ext=""
      backup_chosen=1
      ;;
    --dry-run) dry_run=1 ;;
    --list) mode=list ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "知らないオプション: $1  (--help)" ;;
  esac
  shift
done

if [[ ! -f ${hosts_file} ]]; then
  die "${hosts_file} がありません。リポジトリの中から実行してください。"
fi

# --backup / DOTFILES_BACKUP_EXT のどちらから来た値もここで検査する。
# 空文字は「退避しない」なのでそのまま通す。
if [[ -n ${backup_ext} ]]; then
  validate_backup_ext "${backup_ext}"
fi

if [[ -z ${host} ]]; then
  host=${DOTFILES_HOST:-}
fi
if [[ -z ${host} ]]; then
  host=$(detect_host || true)
fi

case ${mode} in
  list)
    list_steps
    exit 0
    ;;
  new-machine | update)
    apply_preset "${mode}"
    ;;
  steps)
    step_list=()
    IFS=', ' read -r -a step_list <<<"${steps_arg}"
    [[ ${#step_list[@]} -gt 0 ]] || die "--steps が空です"
    select_only "${step_list[@]}"
    ;;
  *)
    if [[ ! -t 0 || ! -t 1 ]]; then
      die "端末ではないのでメニューを出せません。--new-machine / --update / --steps を使ってください。"
    fi
    tui_begin
    if ! menu_main; then
      tui_end
      printf '中止しました。\n'
      exit 0
    fi
    tui_end
    ;;
esac

# switch を含むなら、何かを実行する前にホストを確定させる。
# Nix を入れ終わってから「そんなホストは無い」と言われるのは無駄が大きい。
if is_selected switch && ! ensure_host_registered; then
  exit 1
fi

if ! execute; then
  exit 1
fi
