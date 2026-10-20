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
# 登録した PC のホストの定義と値 (nix/hosts/<user>@<hostname>.nix) も置く (ADR 026)。ローカル flake がその nix/ を
# path: の入力で読むので、setup の「既存マシン更新」「新しいマシン適用」は、clone があればこの script を switch の
# **前** にも流す (setup.sh の手順 private-fetch)。そのときは、同じ実行のこの手順 (order 50) を setup が飛ばす。
# clone が無ければ、今までどおりこの手順 (switch のあと) が clone する。
#
# ## 何をするか
#
# clone の場所は上から順に決める (bootstrap-windows-google-ime.sh も同じ決め方で読む):
#
#   1. $DOTFILES_PRIVATE_DIR
#   2. $(ghq root)/github.com/pollenjp/dotfiles-private
#   3. ~/ghq/github.com/pollenjp/dotfiles-private
#
# 無ければ clone し、あれば取得 (fetch) して fast-forward する (未コミットの変更があるとき・upstream が
# 無いときは飛ばす)。取れない (SSH 鍵が無い・オフライン) ときと、履歴が分岐して fast-forward できない
# ときは警告して exit 0 にする (bootstrap-claude-skills.sh と同じ扱い。setup は手順が 1 つ失敗すると
# 残りを走らせないため)。
#
# GitHub から取るとき (clone と取得) は git_github を通す。dotfiles.claude.gitViaGh.enable のマシンでは
# gh の資格情報 (git gh。HTTPS) で先に試し、gh が使えない・取れないときだけ ssh (ssh-agent) で取る
# (TKT-221。ssh を張り直したあとの herdr の中のように、SSH_AUTH_SOCK が切れていても取れる)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
private な dotfiles-private (pollenjp/dotfiles-private) を取得する。

使い方:
  bootstrap-dotfiles-private.sh   無ければ clone し、あれば取得して fast-forward する

clone の場所: $DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
              ~/ghq/github.com/pollenjp/dotfiles-private
dotfiles.claude.gitViaGh.enable のマシンでは gh の資格情報 (git gh) で先に取り、だめなら ssh で取る。
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
# git_github が取れなかったときの案内 (警告の続きの行に添える)
git_github_hint=""

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
dir=$(private_dir)

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
  # 取得と merge を分ける。履歴の分岐で落ちたときに、ssh で取り直して同じ失敗を 2 回出さないため
  if ! git_github -C "${dir}" fetch --quiet; then
    warn "取得 (fetch) に失敗しました。手元の clone のまま続けます: ${dir}" "${git_github_hint}"
    exit 0
  fi
  if ! git -C "${dir}" merge --ff-only --quiet '@{u}'; then
    warn "fast-forward できません。手元の clone のまま続けます: ${dir}" \
      "履歴が分岐していないか確かめてください: git -C ${dir} status"
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
if ! git_github clone --quiet "${repo_url}" "${dir}"; then
  warn "clone に失敗しました: ${repo_url}" \
    "${git_github_hint}" \
    "取れないあいだ、ssh の接続先と Google 日本語入力の辞書は配られません。"
  exit 0
fi
echo "dotfiles-private を clone しました: ${dir}"
