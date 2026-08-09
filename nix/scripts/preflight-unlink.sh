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
# 警告して残す (手で退避するか -b bak を使うこと)。

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
)

# Stage 5 以降で管理対象になったら、ここへ移す:
#   "${HOME}/.config/fish/config.fish"
#   "${HOME}/.config/fish/fish_plugins"

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
  printf '手で退避するか、switch に -b bak を付けてください。\n' >&2
else
  printf '\n'
fi
