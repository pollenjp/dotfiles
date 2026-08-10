#!/usr/bin/env bash
# shellcheck shell=bash
#
# main.bash setup が作ったシンボリックリンクのうち、
# home-manager が管理するパスだけを外す。
#
# home-manager は自分が作ったのではないファイルを勝手に消さないため、
# 外さないまま switch すると次で中断する:
#   Existing file '...' would be clobbered by home-manager
#
# 安全のため **シンボリックリンクのみ** を外す。実ファイル/実ディレクトリは
# 警告して残す (中身を確認してから捨てたいので、消す判断はしない)。
# それらは手で退けるか、switch に -b <拡張子> を付けて退避する
# (setup.sh の --backup / メニューの b で選べる)。

set -eu -o pipefail

# home-manager が管理するパス (Stage 4 時点)
targets=(
  "${HOME}/.config/starship.toml"
  "${HOME}/.config/zellij/config.kdl"
  "${HOME}/.config/nvim"
  "${HOME}/.screenrc"
  "${HOME}/.tmux.conf"
  "${HOME}/.vimrc"
  "${HOME}/.vim"
  # Stage 4 で追加。
  # home-manager は ~/.config/git/config を書くが、git は ~/.gitconfig を
  # **後に**読むため、main.bash が張った ~/.gitconfig の symlink が残っていると
  # home-manager の設定を黙って上書きしてしまう。必ず外すこと。
  "${HOME}/.gitconfig"
  "${HOME}/.config/git/ignore"
  # Stage 5 (fish) で追加。
  # fish_plugins は fisher 用の一覧で、programs.fish.plugins に置き換わったため
  # 配置自体が不要になった。残っていても害はないが外しておく。
  "${HOME}/.config/fish/config.fish"
  "${HOME}/.config/fish/fish_plugins"
  # ssh (home/modules/ssh.nix で追加)。
  # main.bash は ~/.ssh/config へ Include 行を **追記** していたので、
  # 実ファイルとして残っていることが多い。その場合ここでは外さず警告になる。
  # bootstrap-ssh-config.sh が ~/.ssh/config.d/00-local.ssh_config へ退避する。
  "${HOME}/.ssh/config"
)

# bash は Stage 5 で管理対象になったが、ここには入れない。
#
# programs.bash が書くのは ~/.bashrc / ~/.bash_profile / ~/.profile の 3 つで、
# いずれも symlink ではない実ファイル (ディストリの初期ファイル、または
# main.bash が **追記** したもの)。unlink できないし、追記された stanza を
# 消すには中身を読む必要がある。
#
# よって扱いは switch 側に任せる。`-b <拡張子>` を付ければ <名前>.<拡張子> へ
# 退避してから置き換わるので、中身は後から見比べられる。
# 付けるかどうかは setup.sh が訊く (--backup / --no-backup / メニューの b)。

unlinked=0
skipped=0

for target in "${targets[@]}"; do
  if [[ -L ${target} ]]; then
    printf 'unlink  %s\n' "${target}"
    unlink "${target}"
    unlinked=$((unlinked + 1))
  elif [[ -e ${target} ]]; then
    printf 'SKIP    %s  (シンボリックリンクではないので残します)\n' "${target}" >&2
    skipped=$((skipped + 1))
  else
    printf 'none    %s\n' "${target}"
  fi
done

printf '\n%d 個を外しました。' "${unlinked}"
if [[ ${skipped} -gt 0 ]]; then
  printf '%d 個は実ファイル/実ディレクトリのため残しています。\n' "${skipped}"
  printf 'これらは home-manager が中断する原因になります。\n' >&2
  printf '手で退けるか、switch に -b <拡張子> を付けて退避してください\n' >&2
  printf '(setup.sh なら --backup / メニューの b で選べます)。\n' >&2
else
  printf '\n'
fi
