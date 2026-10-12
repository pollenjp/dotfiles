#!/usr/bin/env bash
# shellcheck shell=bash
#
# private な dotfiles-private (pollenjp/dotfiles-private) を取得する (冪等。更新時も毎回走る。取れなくても止めない)。
#
# order: 50
#
# ^ setup.sh が読む実行順 (既定と同じ)。中身を読む bootstrap-ssh-config.sh (order: 60)・
#   bootstrap-windows-ssh-config.sh (order: 91)・bootstrap-windows-google-ime.sh (order: 98) より
#   先に走ればよい。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# 公開したくない設定 (ssh の接続先と、Google 日本語入力のユーザー辞書) を、public なこの repo と分けて
# private repo に置く (docs/adr/015_win_google_ime_powertoys_*・docs/adr/016_ssh_config_from_dotfiles_private_*)。flake input や submodule に
# しないのは、public な repo に private repo の rev を残さず、辞書を変えるたびにこの repo で
# 指す先を進める commit を要らなくするため。
#
# ## 何をするか
#
# clone の場所は上から順に決める (bootstrap-windows-google-ime.sh も同じ決め方で読む):
#
#   1. $DOTFILES_PRIVATE_DIR
#   2. $(ghq root)/github.com/pollenjp/dotfiles-private
#   3. ~/ghq/github.com/pollenjp/dotfiles-private
#
# 無ければ clone し、あれば pull --ff-only する (未コミットの変更があるとき・upstream が無いときは
# pull を飛ばす)。取れない (SSH 鍵が無い・オフライン) ときは警告して exit 0 にする
# (bootstrap-claude-skills.sh と同じ扱い。setup は手順が 1 つ失敗すると残りを走らせないため)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
private な dotfiles-private (pollenjp/dotfiles-private) を取得する。

使い方:
  bootstrap-dotfiles-private.sh   無ければ clone し、あれば pull --ff-only する

clone の場所: $DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
              ~/ghq/github.com/pollenjp/dotfiles-private
取れなくてもエラーにはせず、警告を出して exit 0 する。
EOS
}

for arg in "$@"; do
  case ${arg} in
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

# 鍵が無い / known_hosts に github.com が無いマシンで、git や ssh が対話プロンプトで固まらないように
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes"

repo_url=${DOTFILES_PRIVATE_URL:-git@github.com:pollenjp/dotfiles-private.git}

resolve_dir() {
  local root
  if [[ -n ${DOTFILES_PRIVATE_DIR:-} ]]; then
    printf '%s' "${DOTFILES_PRIVATE_DIR%/}"
  elif root=$(ghq root 2>/dev/null) && [[ -n ${root} ]]; then
    printf '%s/github.com/pollenjp/dotfiles-private' "${root}"
  else
    printf '%s/ghq/github.com/pollenjp/dotfiles-private' "${HOME}"
  fi
}
dir=$(resolve_dir)

warn() {
  printf '!! %s\n' "$*" >&2
}

if ! command -v git &>/dev/null; then
  warn "git が見つかりません。dotfiles-private の取得を飛ばします。"
  exit 0
fi

if [[ -d ${dir}/.git ]]; then
  if [[ -n $(git -C "${dir}" status --porcelain) ]]; then
    warn "未コミットの変更があるので pull を飛ばします: ${dir}"
    exit 0
  fi
  if ! git -C "${dir}" rev-parse --abbrev-ref '@{upstream}' &>/dev/null; then
    warn "upstream が無いブランチなので pull を飛ばします: ${dir}"
    exit 0
  fi
  if ! git -C "${dir}" pull --ff-only --quiet; then
    warn "pull に失敗しました。手元の clone のまま続けます: ${dir}"
    exit 0
  fi
  echo "dotfiles-private を更新しました: ${dir}"
  exit 0
fi

if [[ -e ${dir} ]]; then
  warn "${dir} は git の repo ではありません。取得を飛ばします (退けてから流し直してください)。"
  exit 0
fi

if ! mkdir -p "$(dirname -- "${dir}")"; then
  warn "親ディレクトリを作れません。取得を飛ばします: ${dir}"
  exit 0
fi
if ! git clone --quiet "${repo_url}" "${dir}"; then
  warn "clone に失敗しました: ${repo_url}"
  printf '   private な repo なので SSH 鍵が要ります。ssh -T git@github.com で疎通を確かめてください。\n' >&2
  printf '   取れないあいだ、ssh の接続先と Google 日本語入力の辞書は配られません。\n' >&2
  exit 0
fi
echo "dotfiles-private を clone しました: ${dir}"
