#!/usr/bin/env bash
# shellcheck shell=bash
#
# dotfiles-private の ssh/*.ssh_config を ~/.ssh/config.d/ へ張る (冪等。更新時も毎回走る。取れていなければ何もしない)。
#
# order: 60
#
# ^ setup.sh が読む実行順。張る元を取る bootstrap-dotfiles-private.sh (order: 50) より後に
#   走ればよい。仕組みは nix/README.md「bootstrap の実行順」。
#
# ## 何のために
#
# ssh の接続先 (ホスト名・ユーザー名・踏み台の構成) は公開したくないので、public なこの
# repo にも /nix/store にも置かず、private な dotfiles-private の ssh/ に置く
# (docs/adr/016_ssh_config_from_dotfiles_private_*)。Nix (home/modules/ssh.nix) が生成する
# ~/.ssh/config は Include の骨組みだけなので、ここで config.d/ へ張れば効く:
#
#     Include config.d/*.ssh_config
#
# Windows 側 (%USERPROFILE%\.ssh) へは bootstrap-windows-ssh-config.sh (order: 91) がコピーする。
#
# ## 何をするか
#
# 1. 張り直す前に、dotfiles-private の ssh/ を指す symlink と、旧 .ssh submodule
#    (<dotfiles の checkout>/.ssh/) を指す symlink を外す。消えたファイルを指す symlink が
#    残って Include され続けるのを防ぐ。手で置いたファイルと、ほかを指す symlink には触らない
# 2. ssh/ 直下の *.ssh_config (通常のファイルだけ) を同じ名前で張る。同じ名前の通常の
#    ファイルや、ほかを指す symlink があれば上書きせずに警告する
#
# ssh/ が無い・空なら 1 もしない (取り損ねで接続先を全部外さない)。警告して exit 0。
# ~/.ssh/config には触らない (Nix が置く)。状態だけ報告する。
#
# dotfiles-private の場所は bootstrap-dotfiles-private.sh と同じ決め方
# ($DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
# ~/ghq/github.com/pollenjp/dotfiles-private)。

set -eu -o pipefail

usage() {
  cat <<'EOS'
dotfiles-private の ssh/*.ssh_config を ~/.ssh/config.d/ へ symlink で張る (冪等)。

使い方:
  bootstrap-ssh-config.sh

dotfiles-private の場所: $DOTFILES_PRIVATE_DIR → $(ghq root)/github.com/pollenjp/dotfiles-private →
                         ~/ghq/github.com/pollenjp/dotfiles-private
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

warn() {
  printf '!! %s\n' "$*" >&2
}

# $0 が symlink 経由でも実体の場所を返す。
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

# dotfiles-private の clone の場所 (bootstrap-dotfiles-private.sh と同じ決め方)
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

script_dir=$(resolve_dir "$0")
repo_dir=$(dirname "$(dirname "${script_dir}")")
ssh_dir="${HOME}/.ssh"
conf="${ssh_dir}/config"
conf_d="${ssh_dir}/config.d"
src_dir="$(private_dir)/ssh"

# 張り直す対象 (正本か旧 submodule を指す symlink) か。$1 = symlink の張り先。
# 旧 submodule は、この checkout の .ssh/ と、ghq の決める場所の .ssh/ の両方を見る
# (worktree から流しても、本体の checkout を指す古い symlink を拾うため)。
ours() {
  case $1 in
    "${src_dir}"/* | "${repo_dir}"/.ssh/* | */pollenjp/dotfiles/.ssh/*) return 0 ;;
  esac
  return 1
}

echo "==> ${conf_d}"
mkdir -p "${conf_d}"
# ssh は自分と親ディレクトリのパーミッションを見る。緩いと黙って設定を無視する。
chmod 700 "${ssh_dir}" "${conf_d}"

# ~/.ssh/config には触らない (Nix が置く)。状態だけ報告する。
if [[ -L ${conf} ]]; then
  if [[ $(readlink -f "${conf}" 2>/dev/null || true) == /nix/store/* ]]; then
    echo "  config: Nix 管理済み"
  else
    echo "  config: Nix 管理外の symlink です。preflight-unlink.sh が外します" >&2
  fi
elif [[ -f ${conf} ]]; then
  echo "  config: 実ファイルがあります。switch は退避が要ります (setup.sh の --backup)" >&2
  echo "          退避後、残したい Host は config.d/ へ手で移してください" >&2
else
  echo "  config: まだありません (switch が作ります)"
fi

echo "==> ${src_dir}"
srcs=()
if [[ -d ${src_dir} ]]; then
  for src in "${src_dir}"/*.ssh_config; do
    if [[ -f ${src} && ! -L ${src} ]]; then
      srcs+=("${src}")
    fi
  done
fi
if ((${#srcs[@]} == 0)); then
  warn "張る *.ssh_config がありません: ${src_dir}"
  echo "   dotfiles-private を取れていないか、ssh/ が空です。今ある symlink はそのまま残します。" >&2
  echo "   取るには: ${script_dir}/bootstrap-dotfiles-private.sh" >&2
  exit 0
fi

# 1. 正本と旧 submodule を指す symlink を外す
gone=0
for link in "${conf_d}"/*; do
  [[ -L ${link} ]] || continue
  ours "$(readlink -- "${link}")" || continue
  unlink "${link}"
  if [[ ! -f ${src_dir}/$(basename "${link}") ]]; then
    gone=$((gone + 1))
  fi
done
if ((gone > 0)); then
  echo "  正本に無い symlink を ${gone} 個外しました"
fi

# 2. 張る
linked=0
skipped=0
for src in "${srcs[@]}"; do
  dst="${conf_d}/$(basename "${src}")"
  if [[ -e ${dst} || -L ${dst} ]]; then
    # 1 で外した後に残っているのは、手で置いたファイルか、ほかを指す symlink
    warn "同じ名前のものがあるので張りません: ${dst}"
    skipped=$((skipped + 1))
    continue
  fi
  ln -s "${src}" "${dst}"
  linked=$((linked + 1))
done
echo "  ${linked} 個を張りました"
if ((skipped > 0)); then
  echo "   中身を見て、要らなければ消してから流し直してください (正本は ${src_dir})。" >&2
fi

# 旧 .ssh submodule の作業ツリーが残っていれば知らせる (自分では消さない)
if [[ -e ${repo_dir}/.ssh/.git ]]; then
  echo
  echo "旧 .ssh submodule の作業ツリーが残っています (もう使っていません)。消すなら:"
  if [[ -d ${repo_dir}/.git/modules/.ssh ]]; then
    echo "  rm -rf '${repo_dir}/.ssh' '${repo_dir}/.git/modules/.ssh'"
  else
    echo "  rm -rf '${repo_dir}/.ssh'"
  fi
fi

echo
echo "--- ${conf_d} ---"
ls -la "${conf_d}"
echo
echo "実際に読まれる設定の確認:"
echo "  ssh -G <ホスト名>"
