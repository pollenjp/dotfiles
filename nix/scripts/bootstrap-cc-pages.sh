#!/usr/bin/env bash
# shellcheck shell=bash
#
# private な cc-pages を取得してビルドし、常駐 daemon を起こす。
#
# ## 何をするか
#
#   1. cc-pages を ghq root 配下へ clone する (既にあれば取得 (fetch) して fast-forward する)
#   2. go build して ~/bin/cc-pages へ symlink を張る
#   3. systemd user service (cc-pages.service) を有効化して起動 / 再起動する
#
# 冪等。更新を取り込みたいときに何度でも実行してよい。
#
# GitHub から取るとき (clone と取得) は git_github を通す。dotfiles.claude.gitViaGh.enable のマシンでは
# gh の資格情報 (git gh。HTTPS) で先に試し、gh が使えない・取れないときだけ ssh (ssh-agent) で取る
# (TKT-221。ssh を張り直したあとの herdr の中のように、SSH_AUTH_SOCK が切れていても取れる)。
#
# ## cc-pages へアクセスできないマシンでも止まらない
#
# dotfiles は **public** なので、cc-pages を取れないマシン (SSH 鍵がまだ無い、
# オフライン、そもそも使わない) でも setup を通したい。そこで **取得やビルドに
# 失敗してもエラーにしない**。警告を出して exit 0 する。
#
#   - clone できない -> ビューア無しで続行 (~/bin にも systemd にも触らない)
#   - 取得できない・fast-forward できない -> 手元のクローンの内容でビルドする
#   - go が無い       -> ビルドを飛ばす (mise が go を入れる前かもしれない)
#
# unit 側も ConditionPathIsExecutable でバイナリの有無を見ているので、
# バイナリが無いマシンでは service が failed で残らず、静かにスキップされる。
#
# ## なぜ Nix (flake input) でやらないのか
#
# cc-pages は private で dotfiles は public。flake input にすると public な
# flake.lock に private repo の URL と rev が載り、GitHub Actions の
# `nix flake check` が fetch できずに落ちる。bootstrap-claude-skills.sh と同じ理由。

set -eu -o pipefail

# 鍵が無い / known_hosts に github.com が無いマシンでは、git や ssh が対話プロンプトを
# 出して入力を待つ。setup.sh ごと固まるより即座に失敗した方がよいので封じる。
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

repo_url="git@github.com:pollenjp/cc-pages.git"
repo_path="github.com/pollenjp/cc-pages"
# git_github が取れなかったときの案内 (警告の続きの行に添える)
git_github_hint=""
unit="cc-pages.service"
bin_link="${HOME}/bin/cc-pages"

state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/cc-pages-dir"

# daemon が読む設定。cc-pages は XDG_CONFIG_HOME を見ず、常にここを読む。
# addr を書くのは home-manager (dotfiles.ccPages.port。home/modules/cc-pages.nix)。
config_file="${HOME}/.config/cc-pages/config.toml"

dir_arg=""
do_pull=1
dry_run=0
status_only=0

# クローンが手元に無い (= ビルドのしようが無い) 状態。最後に警告を出して exit 0 する。
unreachable=0
# クローンはあるが更新できなかった状態。手元の内容でビルドする。
stale=0
# go が無くてビルドを飛ばした状態。
no_go=0
# unit が未配置 / systemd が無くて daemon を起こせなかった状態。
no_daemon=0

usage() {
  cat <<'EOS'
private な cc-pages を取得してビルドし、常駐 daemon を起こす。

使い方:
  bootstrap-cc-pages.sh              取得 (or 更新) してビルドし、daemon を再起動する
  bootstrap-cc-pages.sh --no-pull    pull せず、手元のクローンでビルドし直す
  bootstrap-cc-pages.sh --status     いまの状態を見る
  bootstrap-cc-pages.sh --dir <path> クローン先を指定する
  bootstrap-cc-pages.sh --dry-run    実行せず、走るコマンドを表示するだけ
  bootstrap-cc-pages.sh -h, --help   これ

クローン先の決まり方 (上から順に):
  1. --dir
  2. $CC_PAGES_DIR
  3. $(ghq root)/github.com/pollenjp/cc-pages
  4. ~/ghq/github.com/pollenjp/cc-pages

dotfiles.claude.gitViaGh.enable のマシンでは gh の資格情報 (git gh) で先に取り、だめなら ssh で取る。
cc-pages は private なので、アクセスできないマシンでは取得に失敗する。
その場合はエラーにせず、警告を出して正常終了する (~/bin にも systemd にも触らない)。
EOS
}

note() {
  printf '  %s\n' "$*"
}

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

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  if [[ ${dry_run} == 1 ]]; then
    printf '  + %s\n' "$*"
  else
    "$@"
  fi
}

# GitHub と通信する git (clone / fetch) を流す。引数は git の引数そのまま (git_github -C <dir> fetch など)。
#
# dotfiles.claude.gitViaGh.enable のマシン (~/.local/state/dotfiles/git-via-gh.json の enable が true) では、
# gh の資格情報 (git gh。HTTPS) で先に試し、gh か git-gh が無い・gh が github.com にログインしていない・
# git gh で取れないときだけ git (ssh。ssh-agent) で流す (TKT-221)。どの経路で取ったかを 1 行出し、gh で
# 取れず ssh で取れたときは警告する (gh の token が切れていると Claude の git も通らないため)。
# 取れなければ git の終了コードを返し、呼び元の警告に添える案内を git_github_hint に入れる。
#
# setup.sh と bootstrap-*.sh に同じ形で持つ (nix/tests/git-github-helpers.test.sh が本文の一致を見る)。
# setup.sh は Nix より前にも走るので、状態ファイルは jq を使わずに読む。
git_github() {
  local state="${HOME}/.local/state/dotfiles/git-via-gh.json" json="" rc=0
  git_github_hint=""
  if [[ -r ${state} ]]; then
    json=$(<"${state}") || json=""
  fi
  if ! [[ ${json} =~ \"enable\"[[:space:]]*:[[:space:]]*true ]]; then
    git "$@" || rc=$?
    if ((rc != 0)); then
      git_github_hint="SSH 鍵 (ssh-agent) で取れませんでした。疎通は ssh -T git@github.com で確かめられます。"
    fi
    return "${rc}"
  fi
  if ! command -v gh &>/dev/null || ! command -v git-gh &>/dev/null; then
    printf '  %s\n' "gh (git gh) が見つからないので、ssh (ssh-agent) で取ります。"
  elif ! gh auth token --hostname github.com &>/dev/null; then
    printf '  %s\n' "gh が github.com にログインしていないので、ssh (ssh-agent) で取ります。"
  else
    git gh "$@" || rc=$?
    if ((rc == 0)); then
      printf '  %s\n' "gh の資格情報 (HTTPS) で取りました。"
      return 0
    fi
    printf '  %s\n' "gh の資格情報では取れませんでした。ssh (ssh-agent) で取り直します。"
    rc=0
    git "$@" || rc=$?
    if ((rc == 0)); then
      warn "gh の資格情報では取れず、ssh (ssh-agent) で取りました。" \
        "gh の token が切れていると Claude の git (gitViaGh) も通りません。gh auth status で確かめてください。"
      return 0
    fi
    git_github_hint="gh の資格情報でも SSH 鍵 (ssh-agent) でも取れませんでした。gh auth status と ssh -T git@github.com で確かめてください。"
    return "${rc}"
  fi
  git "$@" || rc=$?
  if ((rc != 0)); then
    git_github_hint="gh が使えず、SSH 鍵 (ssh-agent) でも取れませんでした。gh auth login すれば ssh-agent なしで取れます。"
  fi
  return "${rc}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      [ $# -ge 2 ] || die "--dir にはパスが要る"
      dir_arg="$2"
      shift 2
      ;;
    --no-pull)
      do_pull=0
      shift
      ;;
    --status)
      status_only=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "不明な引数: $1"
      ;;
  esac
done

resolve_dir() {
  if [ -n "${dir_arg}" ]; then
    printf '%s\n' "${dir_arg}"
    return
  fi
  if [ -n "${CC_PAGES_DIR:-}" ]; then
    printf '%s\n' "${CC_PAGES_DIR}"
    return
  fi
  if command -v ghq >/dev/null 2>&1; then
    local root
    if root="$(ghq root 2>/dev/null)" && [ -n "${root}" ]; then
      printf '%s/%s\n' "${root}" "${repo_path}"
      return
    fi
  fi
  printf '%s/ghq/%s\n' "${HOME}" "${repo_path}"
}

dir="$(resolve_dir)"

# daemon を開く URL。daemon と同じく config.toml の addr から組み、無ければ cc-pages の既定。
# host は cc-pages の BaseURL と同じく最初の ":" で切り、127.0.0.1 などは localhost にする。
# 環境変数 CC_PAGES_ADDR は見ない。systemd の user service の daemon には届かないため。
viewer_url() {
  local addr="" line host
  if [[ -f ${config_file} ]]; then
    while IFS= read -r line || [[ -n ${line} ]]; do
      if [[ ${line} =~ ^[[:space:]]*addr[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
        addr=${BASH_REMATCH[1]}
        break
      fi
    done <"${config_file}"
  fi
  addr=${addr:-127.0.0.1:7777}
  if [[ ${addr} != *:* ]]; then
    printf 'http://%s\n' "${addr}"
    return
  fi
  host=${addr%%:*}
  case ${host} in
    "" | 127.0.0.1 | 0.0.0.0) host=localhost ;;
  esac
  printf 'http://%s:%s\n' "${host}" "${addr#*:}"
}

if [[ ${status_only} == 1 ]]; then
  echo "クローン: ${dir}"
  if [ -d "${dir}/.git" ]; then
    note "HEAD: $(git -C "${dir}" log -1 --format='%h %s' 2>/dev/null || echo '(読めない)')"
  else
    note "(まだ無い)"
  fi
  echo "バイナリ: ${bin_link}"
  if [ -x "${bin_link}" ]; then
    note "-> $(readlink -f "${bin_link}" 2>/dev/null || echo '?')"
  else
    note "(まだ無い)"
  fi
  echo "サービス: ${unit}"
  systemctl --user status "${unit}" --no-pager 2>&1 | sed -n '1,4p' | sed 's/^/  /' || true
  echo "ビューア: $(viewer_url)"
  exit 0
fi

echo "==> cc-pages を取得"
if [ -d "${dir}/.git" ]; then
  note "既にある: ${dir}"
  if [[ ${do_pull} == 1 ]]; then
    # 取得と merge を分ける。履歴の分岐で落ちたときに、ssh で取り直して同じ失敗を 2 回出さないため
    if ! run git_github -C "${dir}" fetch; then
      warn "取得できませんでした。手元のクローンのまま続けます。" "${git_github_hint}"
      stale=1
    elif ! run git -C "${dir}" merge --ff-only '@{u}'; then
      warn "fast-forward できませんでした。手元のクローンのまま続けます。" \
        "履歴が分岐していないか確かめてください: git -C ${dir} status"
      stale=1
    fi
  else
    note "--no-pull なので更新しません"
  fi
else
  run mkdir -p "$(dirname "${dir}")"
  if ! run git_github clone "${repo_url}" "${dir}"; then
    warn "clone できませんでした: ${repo_url}" "${git_github_hint}"
    unreachable=1
  fi
fi

if [[ ${unreachable} == 0 ]]; then
  echo
  echo "==> ビルド"
  if ! command -v go >/dev/null 2>&1; then
    warn "go が見つかりません。ビルドを飛ばします。" \
      "mise が go を入れた後に、この手順だけ実行し直せば済みます。"
    no_go=1
  else
    note "go: $(go version 2>/dev/null)"
    if run env -C "${dir}" go build -o "${dir}/cc-pages" .; then
      run mkdir -p "$(dirname "${bin_link}")"
      run ln -sfn "${dir}/cc-pages" "${bin_link}"
      note "${bin_link} -> ${dir}/cc-pages"
    else
      warn "ビルドに失敗しました。"
      no_go=1
    fi
  fi
fi

if [[ ${unreachable} == 0 && ${no_go} == 0 ]]; then
  echo
  echo "==> daemon"
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    warn "systemd の user session がありません。daemon は起こしません。" \
      "手で動かすなら: ${bin_link} serve"
    no_daemon=1
  else
    run systemctl --user daemon-reload
    # enable は unit が配置済みのときだけ成功する (home-manager switch 済みが前提)。
    if systemctl --user list-unit-files "${unit}" >/dev/null 2>&1 \
      && systemctl --user cat "${unit}" >/dev/null 2>&1; then
      run systemctl --user enable --now "${unit}"
      run systemctl --user restart "${unit}"
      note "$(systemctl --user is-active "${unit}" 2>/dev/null || true): ${unit}"
    else
      warn "${unit} がまだ配置されていません。home-manager switch の後に実行し直してください。"
      no_daemon=1
    fi
  fi

  if [[ ${dry_run} == 0 ]]; then
    mkdir -p "${state_dir}"
    printf '%s\n' "${dir}" >"${state_file}"
  fi
fi

echo
if [[ ${unreachable} == 1 ]]; then
  warn "cc-pages を取得できていません。ビューア無しで続けます。" \
    "このリポジトリを使わないマシンなら、これで問題ありません。" \
    "鍵やネットワークを整えたら、この手順だけ実行し直せばよい:" \
    "  $0"
  exit 0
fi

if [[ ${no_go} == 1 ]]; then
  warn "バイナリを作れていません (上の !! を参照)。daemon は起こしていません。" \
    "直したら、この手順だけ実行し直せばよい: $0"
  exit 0
fi

if [[ ${no_daemon} == 1 ]]; then
  warn "バイナリは置きましたが、daemon は起こせていません (上の !! を参照)。" \
    "いまの状態: $0 --status"
  exit 0
fi

echo "完了しました。$(viewer_url) で開けます。"
note "いまの状態: $0 --status"
if [[ ${stale} == 1 ]]; then
  echo
  warn "cc-pages を更新できていません (上の !! を参照)。手元のクローンのままです。"
fi
