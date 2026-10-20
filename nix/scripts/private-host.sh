#!/usr/bin/env bash
# shellcheck shell=bash
#
# この PC を dotfiles-private に登録するときの名前と、dotfiles-private の clone の場所を決める (ADR 025)。
#
# ## 何のために
#
# 実機のホストの定義と値は、private な dotfiles-private の nix/hosts/<user>@<hostname>.nix に 1 PC 1 ファイルで置く。
# ローカル flake (~/dotfiles/flake.nix) の雛形がその nix/ を path: の入力に取り、setup.sh は --host が無ければ
# この PC の名前のファイルのホストを選ぶ。名前と clone の場所の決め方は、この script だけが持つ
# (setup.sh・setup-local-flake.sh・local-flake-migrate.sh はこれを呼ぶ。登録の skill pjp-dotfiles-register-host も)。
#
#   名前        <user>@<短い hostname>。user は $USER (無ければ id -un)。hostname は macOS ならネットワークで変わらない
#               LocalHostName (scutil)、ほかは uname -n の最初の . まで (hostname -s と同じ)。英数字と . _ - だけ
#   clone       $DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
#               ~/ghq/github.com/pollenjp/dotfiles-private (bootstrap-dotfiles-private.sh などの private_dir() と同じ)
#   入力の先    clone の nix/ が directory ならそれ、無ければ本体の空の stub (nix/private-stub)。雛形は clone の無い
#               マシンでも入力の行の形を変えずに書く
#
# name・dir・input-dir は bash と uname だけで動く (setup.sh は Nix を入れる前にも呼ぶ。macOS の bash 3.2 でも動く書き方)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
この PC を dotfiles-private に登録するときの名前と、dotfiles-private の clone の場所を決める。

使い方:
  private-host.sh name
      この PC のホストの名前 (<user>@<短い hostname>) を出す。決められない・使えない文字を含むなら 1
  private-host.sh dir
      dotfiles-private の clone の場所を出す ($DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
      ~/ghq/github.com/pollenjp/dotfiles-private)
  private-host.sh input-dir [--nix-dir <本体の nix>]
      ローカル flake の雛形が dotfiles-private の入力に書く場所を出す (clone の nix/ が無ければ <本体の nix>/private-stub。
      --nix-dir の既定はこの script の repo の nix/)
  private-host.sh -h, --help
      これ
EOS
}

die() {
  printf '!! %s\n' "$*" >&2
  exit 2
}

# $0 が symlink 経由でも実体の場所を返す (setup-local-flake.sh と同じ。macOS の readlink には -f が無い)。
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

# dotfiles-private の clone の場所。bootstrap-dotfiles-private.sh などと同じ本文 (nix/tests/private-host.test.sh が見る)
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

# この PC の短い hostname。macOS は LocalHostName (scutil。ネットワークで変わらない)、ほかと scutil が使えないときは
# uname -n の最初の . まで
short_hostname() {
  local h=""
  if [[ $(uname -s) == Darwin ]] && command -v scutil &>/dev/null; then
    h=$(scutil --get LocalHostName 2>/dev/null) || h=""
  fi
  if [[ -z ${h} ]]; then
    h=$(uname -n 2>/dev/null) || h=""
  fi
  printf '%s' "${h%%.*}"
}

# この PC のホストの名前 (<user>@<短い hostname>)。決められない・英数字と . _ - の外の文字を含むなら 1
this_host_name() {
  local user h
  user=${USER:-$(id -un 2>/dev/null || true)}
  h=$(short_hostname)
  if [[ -z ${user} || -z ${h} ]]; then
    printf '!! この PC のホストの名前を決められません (user: %s / hostname: %s)。\n' "${user:-不明}" "${h:-不明}" >&2
    return 1
  fi
  if [[ ! ${user}@${h} =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]]; then
    printf '!! この PC のホストの名前 (%s) に、ファイル名に使えない文字があります (英数字と . _ - だけにする)。\n' "${user}@${h}" >&2
    return 1
  fi
  printf '%s\n' "${user}@${h}"
}

cmd_input_dir() {
  local nd=${nix_dir} clone
  while [[ $# -gt 0 ]]; do
    case $1 in
      --nix-dir)
        [[ $# -ge 2 ]] || die "--nix-dir にディレクトリを渡してください"
        nd=${2%/}
        shift
        ;;
      *) die "input-dir の知らない引数です: $1 (--help)" ;;
    esac
    shift
  done
  clone=$(private_dir)
  if [[ -d ${clone}/nix ]]; then
    printf '%s\n' "${clone}/nix"
  else
    printf '%s\n' "${nd}/private-stub"
  fi
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi
cmd=$1
shift
case ${cmd} in
  name)
    [[ $# -eq 0 ]] || die "name は引数を取りません"
    this_host_name
    ;;
  dir)
    [[ $# -eq 0 ]] || die "dir は引数を取りません"
    private_dir
    echo
    ;;
  input-dir) cmd_input_dir "$@" ;;
  -h | --help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
