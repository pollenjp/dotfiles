#!/usr/bin/env bash
# shellcheck shell=bash
#
# private な cc-pages を取得してビルドし、常駐 daemon を起こす。
#
# ## 何をするか
#
#   1. cc-pages を ghq root 配下へ clone する (既にあれば ff-only で pull)
#   2. go build して ~/bin/cc-pages へ symlink を張る
#   3. systemd user service (cc-pages.service) を有効化して起動 / 再起動する
#
# 冪等。更新を取り込みたいときに何度でも実行してよい。
#
# ## cc-pages へアクセスできないマシンでも止まらない
#
# dotfiles は **public** なので、cc-pages を取れないマシン (SSH 鍵がまだ無い、
# オフライン、そもそも使わない) でも setup を通したい。そこで **取得やビルドに
# 失敗してもエラーにしない**。警告を出して exit 0 する。
#
#   - clone できない -> ビューア無しで続行 (~/bin にも systemd にも触らない)
#   - pull できない   -> 手元のクローンの内容でビルドする
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
unit="cc-pages.service"
bin_link="${HOME}/bin/cc-pages"

state_dir="${HOME}/.local/state/dotfiles"
state_file="${state_dir}/cc-pages-dir"

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

cc-pages は private なので、アクセスできないマシンでは取得に失敗する。
その場合はエラーにせず、警告を出して正常終了する (~/bin にも systemd にも触らない)。
EOS
}

note() {
  printf '  %s\n' "$*"
}

warn() {
  printf '!! %s\n' "$*" >&2
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
  exit 0
fi

echo "==> cc-pages を取得"
if [ -d "${dir}/.git" ]; then
  note "既にある: ${dir}"
  if [[ ${do_pull} == 1 ]]; then
    if ! run git -C "${dir}" pull --ff-only; then
      warn "pull できませんでした。手元のクローンのまま続けます。"
      stale=1
    fi
  else
    note "--no-pull なので更新しません"
  fi
else
  run mkdir -p "$(dirname "${dir}")"
  if ! run git clone "${repo_url}" "${dir}"; then
    warn "clone できませんでした: ${repo_url}"
    unreachable=1
  fi
fi

if [[ ${unreachable} == 0 ]]; then
  echo
  echo "==> ビルド"
  if ! command -v go >/dev/null 2>&1; then
    warn "go が見つかりません。ビルドを飛ばします。"
    note "mise が go を入れた後に、この手順だけ実行し直せば済みます。"
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
    warn "systemd の user session がありません。daemon は起こしません。"
    note "手で動かすなら: ${bin_link} serve"
    no_daemon=1
  else
    run systemctl --user daemon-reload
    # enable は unit が配置済みのときだけ成功する (home-manager switch 済みが前提)。
    if systemctl --user list-unit-files "${unit}" >/dev/null 2>&1 &&
      systemctl --user cat "${unit}" >/dev/null 2>&1; then
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
  warn "cc-pages を取得できていません。ビューア無しで続けます。"
  note "このリポジトリを使わないマシンなら、これで問題ありません。"
  note "鍵やネットワークを整えたら、この手順だけ実行し直せばよい:"
  note "  $0"
  exit 0
fi

if [[ ${no_go} == 1 ]]; then
  warn "バイナリを作れていません (上の !! を参照)。daemon は起こしていません。"
  note "直したら、この手順だけ実行し直せばよい: $0"
  exit 0
fi

if [[ ${no_daemon} == 1 ]]; then
  warn "バイナリは置きましたが、daemon は起こせていません (上の !! を参照)。"
  note "いまの状態: $0 --status"
  exit 0
fi

echo "完了しました。http://localhost:7777 で開けます。"
note "いまの状態: $0 --status"
if [[ ${stale} == 1 ]]; then
  echo
  warn "cc-pages を更新できていません (上の !! を参照)。手元のクローンのままです。"
fi
