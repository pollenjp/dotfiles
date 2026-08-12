#!/usr/bin/env bash
# shellcheck shell=bash
#
# ~/dotfiles にローカル専用の flake を用意する (git 管理外)。冪等。
#
# ## 置き場所の前提
#
#   リポジトリ本体  ~/ghq/github.com/pollenjp/dotfiles  git 管理
#   ローカル flake  ~/dotfiles                          git 管理外
#
# ~/ghq は ghq root の既定値。GHQ_ROOT や git config ghq.root で変えていれば
# そちらを使う (下の ghq_root() が判定する)。ghq 本体は Nix が入れるものなので、
# 初回はまだ PATH に無い前提で書いてある。
#
# リポジトリは ghq が決めるパスに置く。`cdrepo` など ghq 前提の仕組みと
# 置き場所が揃い、他のリポジトリと同じ規則で辿れるため。
# 一方で日々叩くパスは短く固定したいので、~/dotfiles を「常にここから
# 実行する入口」として別に用意する。
#
# ## ~/dotfiles に置くもの
#
#   flake.nix   本体を input として取り込み、homeConfigurations をそのまま
#               再輸出する。このマシンだけのホストをここに足せる。
#   flake.lock  nix が生成する。
#   setup       setup.sh への symlink。更新は `~/dotfiles/setup --update`。
#
# ## なぜ本体の git 管理下に置かないのか
#
# 一時的な検証マシンの定義を登録簿 (hosts/default.nix) に混ぜたくない。
# また flake の input は絶対パスでしか書けず、ghq root はマシンごとに
# 異なりうるので、このファイル自体がマシン固有になる。
#
# ## なぜ path: を使うのか
#
# `path:` は git を介さずディレクトリをそのまま複製するので、**commit して
# いない変更もそのまま試せる**。
#
# ただし いまの nix (Determinate 3.21.9 / 2.34 で実測) は path: 入力を
# **narHash で厳密に lock する**ので、本体を編集すると flake.lock が合わなくなり
# 評価が NAR hash mismatch で落ちる。張り直しは setup.sh が switch の前に行う
# (sync_local_flake_lock)。手で直すなら:
#
#   nix flake update dotfiles --flake ~/dotfiles
#
# `nix flake lock` では直らない (同じエラーになる)。
#
# 対して `--flake <repo>/nix` のように git リポジトリ内のパスを直接指すと
# git 解決になり、**追跡済みファイルしか見えない**。CI はこちらなので、
# 手元で通っても commit を忘れると CI で落ちる点だけ注意する。

set -eu -o pipefail

repo_path_suffix="github.com/pollenjp/dotfiles"
local_dir=${DOTFILES_LOCAL_DIR:-${HOME}/dotfiles}
force=0

usage() {
  cat <<'EOS'
~/dotfiles にローカル専用の flake を用意する (git 管理外)。

使い方:
  setup-local-flake.sh           用意する (既にあれば触らない)
  setup-local-flake.sh --force   flake.nix を作り直す
  setup-local-flake.sh -h        これ

環境変数:
  DOTFILES_LOCAL_DIR        ローカル flake の場所 (既定: ~/dotfiles)
  DOTFILES_ALLOW_ANY_PATH   1 なら ghq のパス確認を警告だけにする
EOS
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --force) force=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "知らないオプション: $1  (--help)" >&2
      exit 1
      ;;
  esac
  shift
done

warn() { printf '!! %s\n' "$*" >&2; }
die() {
  printf '!! %s\n' "$*" >&2
  exit 1
}

# $0 が symlink (~/dotfiles/setup など) 経由でも実体の場所を返す。
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

# ghq root は ghq 本体が無くても決める。この手順は Nix 導入直後、
# まだ ghq が PATH に無い状態でも走りうるため。
# 優先順位は ghq 自身の規則に合わせる。
ghq_root() {
  local root
  if command -v ghq &>/dev/null && root=$(ghq root 2>/dev/null | head -n 1) && [[ -n ${root} ]]; then
    printf '%s' "${root}"
    return 0
  fi
  if [[ -n ${GHQ_ROOT:-} ]]; then
    printf '%s' "${GHQ_ROOT}"
    return 0
  fi
  if command -v git &>/dev/null && root=$(git config --get ghq.root 2>/dev/null) && [[ -n ${root} ]]; then
    # git config の値は ~ が展開されないまま入りうるので手で開く。
    # shellcheck disable=SC2088  # 展開ではなく "~" で始まる文字列の照合
    case ${root} in
      "~") root=${HOME} ;;
      "~/"*) root="${HOME}/${root#\~/}" ;;
    esac
    printf '%s' "${root}"
    return 0
  fi
  printf '%s' "${HOME}/ghq"
}

expected_repo="$(ghq_root)/${repo_path_suffix}"

echo "==> 置き場所の確認"
printf '  リポジトリ本体: %s\n' "${repo_dir}"
printf '  ghq が決める先: %s\n' "${expected_repo}"

if [[ ${repo_dir} != "${expected_repo}" ]]; then
  if [[ ${DOTFILES_ALLOW_ANY_PATH:-0} == 1 ]]; then
    warn "ghq のパスと違いますが DOTFILES_ALLOW_ANY_PATH=1 なので続けます。"
  else
    cat >&2 <<EOS
!! リポジトリが ghq の決めるパスにありません。

   いま:     ${repo_dir}
   あるべき: ${expected_repo}

   ghq 配下へ置き直してください。

     # 既存の作業を持ち越すなら移動が早い
     mkdir -p "$(dirname "${expected_repo}")"
     mv "${repo_dir}" "${expected_repo}"

     # 取り直すなら (ghq がまだ無ければ git clone。https / SSH はどちらでも)
     git clone https://github.com/pollenjp/dotfiles.git "${expected_repo}"
     ghq get https://github.com/pollenjp/dotfiles.git

   このパスのまま進めるなら DOTFILES_ALLOW_ANY_PATH=1 を付けてください。
EOS
    exit 1
  fi
fi

echo "==> ${local_dir}"

# 旧レイアウト (リポジトリそのものが ~/dotfiles) を壊さない。
if [[ ${repo_dir} == "${local_dir}" ]]; then
  die "${local_dir} はリポジトリ本体そのものです。先に ghq 配下へ移動してください。"
fi
if [[ -e ${local_dir} && ! -d ${local_dir} ]]; then
  die "${local_dir} がディレクトリではありません。"
fi
if git -C "${local_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
  die "${local_dir} は git の作業ツリーです。ローカル flake は git 管理外に置きます。"
fi

mkdir -p "${local_dir}"

flake_file="${local_dir}/flake.nix"
write_flake=1
if [[ -f ${flake_file} && ${force} == 0 ]]; then
  write_flake=0
  if grep -qF "\"path:${nix_dir}\"" "${flake_file}"; then
    echo "  flake.nix: 既にあります (そのまま)"
  else
    warn "既存の ${flake_file} が別のパスを指しています:"
    grep -n 'inputs.dotfiles.url' "${flake_file}" >&2 || true
    warn "本体は ${nix_dir} です。作り直すなら --force を付けてください。"
  fi
fi

if [[ ${write_flake} == 1 ]]; then
  cat >"${flake_file}" <<EOS
# ローカル専用の flake。setup-local-flake.sh が生成した。
# **git 管理外**なので、ここに書いたことはこのマシンにしか無い。
#
#   home-manager switch --flake ~/dotfiles#pollenjp@wsl
#   ~/dotfiles/setup --update
{
  # path: は git を介さずそのまま複製するので commit していない変更も試せる。
  #
  # ただし path: 入力は flake.lock の narHash で厳密に pin されるので、本体を
  # 編集したらこの lock を張り直さないと NAR hash mismatch で落ちる。
  # setup.sh は switch の前に自動で張り直す。手で直すなら:
  #   nix flake update dotfiles --flake ~/dotfiles
  inputs.dotfiles.url = "path:${nix_dir}";

  outputs =
    { dotfiles, ... }:
    {
      # 本体の出力をそのまま引き継ぐ。日々の操作は ~/dotfiles だけ見ればよい。
      inherit (dotfiles)
        packages
        devShells
        formatter
        lib
        ;

      homeConfigurations = dotfiles.homeConfigurations // {
        # このマシンだけのホストはここに足す (登録簿 hosts/default.nix は触らない)。
        #
        # tmp = dotfiles.lib.mkHome {
        #   username = "pollenjp";
        #   system = "x86_64-linux";
        #   wsl.enable = true;
        #
        #   # 本体が既に定義している値を差し替えるには mkForce が要る。
        #   modules = [
        #     (
        #       { lib, ... }:
        #       {
        #         programs.git.settings.user.email = lib.mkForce "tmp@example.com";
        #       }
        #     )
        #   ];
        # };
      };
    };
}
EOS
  echo "  flake.nix: 書きました"
fi

link="${local_dir}/setup"
target="${script_dir}/setup.sh"
if [[ -L ${link} ]]; then
  if [[ $(readlink -- "${link}") == "${target}" ]]; then
    echo "  setup: 既に張られています"
  else
    ln -sfn "${target}" "${link}"
    echo "  setup: 張り直しました"
  fi
elif [[ -e ${link} ]]; then
  die "${link} が symlink ではありません。手で退けてください。"
else
  ln -s "${target}" "${link}"
  echo "  setup: 張りました -> ${target}"
fi

echo
echo "完了しました。以後はここから実行できます:"
echo "  ~/dotfiles/setup            メニュー"
echo "  ~/dotfiles/setup --update   既存マシンの更新"
echo "  home-manager switch --flake ~/dotfiles#<ホスト>"
