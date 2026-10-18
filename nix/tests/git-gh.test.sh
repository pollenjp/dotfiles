#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/pkgs/git-gh (git gh <コマンド>) の振る舞いを、使い捨ての HOME・repo と偽の gh で確かめる。
#
#   bash nix/tests/git-gh.test.sh <bin/git-gh のパス>
#
# flake の checks (git-gh-test) が Nix のサンドボックスで流す。使うのは bash・git・coreutils・grep だけ。
# GitHub には出ない (ls-remote --get-url と remote get-url は URL を組み立てるだけで通信しない。資格情報は
# credential fill で偽の gh から取る)。渡すのは包んだ後の package (3 組は Nix が書き込む)。
# サンドボックスの外では:
#
#   bash nix/tests/git-gh.test.sh "$(nix build --no-link --print-out-paths ./nix#git-gh)/bin/git-gh"
#
# ## 確かめること
#
#   - GitHub の ssh の URL (git@github.com: と ssh://git@github.com/) を https に読み替える。GitHub 以外と
#     ssh のホスト別名は読み替えない。git-gh を通さない git は読み替えない
#   - origin の URL (設定ファイルの値) は書き換えない
#   - github.com の資格情報は gh (gh auth git-credential get) から取る。github.com 以外には gh を使わない
#   - git gh <コマンド> (git の subcommand) で呼べる。引数・cwd・終了コードはそのまま git へ渡る
#   - gh が github.com にログインしていない・gh が無いときは、git を呼ばずに止まり、gh auth login と
#     gh を通さない打ち方 (gfp なら gfp-base) を案内する
#
# ## 「gh が無い」の作り方
#
# 要るコマンドだけを symlink で並べた PATH で流す (bootstrap-claude-env.test.sh と同じ)。PATH から gh の
# あるディレクトリを抜く形にしないのは、GitHub の runner の /usr/bin や Nix の profile では gh が git と
# 同じディレクトリにあって抜けないため。偽の gh の shebang は $BASH から作る。Nix のサンドボックスには
# /usr/bin/env が無い。

set -u -o pipefail

if [[ -z ${1:-} ]]; then
  echo "使い方: bash $0 <bin/git-gh のパス>" >&2
  exit 2
fi
gitgh=$(realpath -- "$1")
work=$(mktemp -d "${TMPDIR:-/tmp}/git-gh-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT
work=$(realpath -- "${work}")

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

# git の global / system の設定と、流す人の env の git の設定 (Claude のセッションの GIT_CONFIG_* など) を
# 持ち込まない。端末に Username を聞かせない
export HOME="${work}/home" XDG_CONFIG_HOME="${work}/home/.config"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
mkdir -p "${HOME}"

# 偽の gh。呼ばれた引数を FAKE_GH_LOG に 1 行ずつ書き留める。FAKE_GH_LOGGED_IN=0 なら auth token が失敗する
export FAKE_GH_LOG="${work}/gh-log"
bin="${work}/bin"
mkdir -p "${bin}"
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$*" >>"${FAKE_GH_LOG}"
if [[ ${1:-} == auth && ${2:-} == token ]]; then
  if [[ ${FAKE_GH_LOGGED_IN:-1} == 1 ]]; then
    echo gho_fake
    exit 0
  fi
  echo "no oauth token found for github.com" >&2
  exit 1
fi
if [[ ${1:-} == auth && ${2:-} == git-credential ]]; then
  cat >/dev/null
  if [[ ${3:-} == get ]]; then
    printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=gho_fake\n'
  fi
  exit 0
fi
echo "fake gh: 想定していない呼び出し: $*" >&2
exit 2
EOF
} >"${bin}/gh"
chmod +x "${bin}/gh"
# git gh <コマンド> で呼べるよう、git-gh も PATH に置く
ln -s "${gitgh}" "${bin}/git-gh"
export PATH="${bin}:${PATH}"

# gh だけを持たない PATH。要るコマンド (git-gh が gh の次に呼ぶ git だけ) を symlink で並べる
nogh_bin="${work}/nogh-bin"
mkdir -p "${nogh_bin}"
if ! real_git=$(command -v git); then
  echo "見つからない: git" >&2
  exit 1
fi
ln -s "${real_git}" "${nogh_bin}/git"

# 空白を含む名前の repo。origin は GitHub の ssh の URL
repo="${work}/repo dir"
mkdir -p "${repo}/sub"
git init -q "${repo}"
git -C "${repo}" remote add origin ssh://git@github.com/o/r.git

# 1 ケースを流す。$1: ケースの名前 (出力の置き場所)。残りは env に渡す (VAR=値… の後にコマンドと引数)。
# stdout・stderr・終了コードを <置き場所>/{out,err,rc} に書き、置き場所を返す
run() {
  local d="${work}/out/$1"
  shift
  mkdir -p "${d}"
  env "$@" >"${d}/out" 2>"${d}/err"
  echo $? >"${d}/rc"
  printf '%s' "${d}"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }

echo "== GitHub の ssh の URL の読み替え"

# 1. scp 形式
d=$(run t1 "${gitgh}" ls-remote --get-url git@github.com:o/r.git)
if [[ $(rc "${d}") == 0 && $(out "${d}") == https://github.com/o/r.git ]]; then
  ok "git@github.com: を https://github.com/ に読み替える"
else
  ng "git@github.com: を読み替える" "rc=$(rc "${d}") out=$(out "${d}") err=$(err "${d}")"
fi

# 2. ssh:// 形式
d=$(run t2 "${gitgh}" ls-remote --get-url ssh://git@github.com/o/r.git)
if [[ $(rc "${d}") == 0 && $(out "${d}") == https://github.com/o/r.git ]]; then
  ok "ssh://git@github.com/ を https://github.com/ に読み替える"
else
  ng "ssh://git@github.com/ を読み替える" "rc=$(rc "${d}") out=$(out "${d}") err=$(err "${d}")"
fi

# 3. GitHub 以外と ssh のホスト別名
d=$(run t3a "${gitgh}" ls-remote --get-url git@gitlab.com:o/r.git)
e=$(run t3b "${gitgh}" ls-remote --get-url git@github-sub:o/r.git)
if [[ $(out "${d}") == git@gitlab.com:o/r.git && $(out "${e}") == git@github-sub:o/r.git ]]; then
  ok "GitHub 以外と ssh のホスト別名は読み替えない"
else
  ng "GitHub 以外と ssh のホスト別名は読み替えない" "gitlab=$(out "${d}") 別名=$(out "${e}")"
fi

# 4. git-gh を通さない git (このテストの環境が読み替えを持ち込んでいないことも確かめる)
d=$(run t4 git ls-remote --get-url git@github.com:o/r.git)
if [[ $(out "${d}") == git@github.com:o/r.git ]]; then
  ok "git-gh を通さない git は読み替えない"
else
  ng "git-gh を通さない git は読み替えない" "out=$(out "${d}")"
fi

# 5. origin の URL は、使うときだけ読み替わり、設定ファイルの値は変わらない
d=$(run t5 "${gitgh}" -C "${repo}" remote get-url origin)
stored=$(git -C "${repo}" config --get remote.origin.url)
if [[ $(rc "${d}") == 0 && $(out "${d}") == https://github.com/o/r.git && ${stored} == ssh://git@github.com/o/r.git ]]; then
  ok "origin は https で使い、設定ファイルの URL は ssh のまま"
else
  ng "origin は https で使い、設定ファイルの URL は ssh のまま" "rc=$(rc "${d}") out=$(out "${d}") stored=${stored}"
fi

echo "== 資格情報"

# 6. github.com は gh から取る。ログインの確かめも github.com に対して行う
: >"${FAKE_GH_LOG}"
d=$(run t6 "${gitgh}" credential fill <<<$'protocol=https\nhost=github.com\n')
if [[ $(rc "${d}") == 0 ]] && grep -qx 'password=gho_fake' "${d}/out" \
  && grep -qx 'auth git-credential get' "${FAKE_GH_LOG}" \
  && grep -qx 'auth token --hostname github.com' "${FAKE_GH_LOG}"; then
  ok "github.com の資格情報は gh auth git-credential から取る"
else
  ng "github.com の資格情報は gh から取る" "rc=$(rc "${d}") out=$(out "${d}") err=$(err "${d}") gh=$(cat "${FAKE_GH_LOG}")"
fi

# 7. github.com 以外には gh を使わない (helper が無いので、端末に聞けずに止まる)
: >"${FAKE_GH_LOG}"
d=$(run t7 "${gitgh}" credential fill <<<$'protocol=https\nhost=gitlab.com\n')
if [[ $(rc "${d}") != 0 ]] && ! grep -q 'git-credential' "${FAKE_GH_LOG}"; then
  ok "github.com 以外の資格情報には gh を使わない"
else
  ng "github.com 以外の資格情報には gh を使わない" "rc=$(rc "${d}") out=$(out "${d}") gh=$(cat "${FAKE_GH_LOG}")"
fi

echo "== 呼び方と、git へ渡すもの"

# 8. git の subcommand として
d=$(run t8 git gh ls-remote --get-url git@github.com:o/r.git)
if [[ $(rc "${d}") == 0 && $(out "${d}") == https://github.com/o/r.git ]]; then
  ok "git gh <コマンド> で呼べる"
else
  ng "git gh <コマンド> で呼べる" "rc=$(rc "${d}") out=$(out "${d}") err=$(err "${d}")"
fi

# 9. cwd (サブディレクトリから)・空白を含む引数 (-C)・終了コード
d=$(cd "${repo}/sub" && run t9a "${gitgh}" rev-parse --show-prefix)
e=$(run t9b "${gitgh}" -C "${repo}" rev-parse --show-toplevel)
f=$(run t9c "${gitgh}" -C "${repo}" rev-parse --verify --quiet refs/heads/nope)
if [[ $(out "${d}") == sub/ && $(out "${e}") == "${repo}" && $(rc "${f}") == 1 ]]; then
  ok "cwd・空白を含む引数・終了コードをそのまま git へ渡す"
else
  ng "cwd・引数・終了コードをそのまま渡す" "prefix=$(out "${d}") toplevel=$(out "${e}") rc=$(rc "${f}")"
fi

echo "== gh が使えないとき"

# 10. 未ログイン: git を呼ばない (init の dir ができない)
d=$(run t10 FAKE_GH_LOGGED_IN=0 "${gitgh}" init -q "${work}/t10-repo")
if [[ $(rc "${d}") == 1 && ! -e "${work}/t10-repo" && ! -s "${d}/out" ]] \
  && grep -q 'gh auth login' "${d}/err" && grep -q 'gfp-base' "${d}/err"; then
  ok "未ログインなら git を呼ばずに exit 1 で止まり、gh auth login と gfp-base を案内する"
else
  ng "未ログインなら git を呼ばずに止まる" "rc=$(rc "${d}") out=$(out "${d}") err=$(err "${d}") dir=$([[ -e "${work}/t10-repo" ]] && echo できた)"
fi

# 11. gh が無い: git を呼ばない
d=$(run t11 PATH="${nogh_bin}" "${gitgh}" init -q "${work}/t11-repo")
if [[ $(rc "${d}") == 127 && ! -e "${work}/t11-repo" ]] \
  && grep -q 'gh が見つかりません' "${d}/err" && grep -q 'gfp-base' "${d}/err"; then
  ok "gh が無ければ git を呼ばずに exit 127 で止まり、gfp-base を案内する"
else
  ng "gh が無ければ git を呼ばずに止まる" "rc=$(rc "${d}") err=$(err "${d}") dir=$([[ -e "${work}/t11-repo" ]] && echo できた)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
