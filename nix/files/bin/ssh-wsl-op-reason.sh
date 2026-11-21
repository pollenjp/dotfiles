#!/usr/bin/env bash
# wrapper for using 1password ssh client on WSL through the op-reason SSH relay
#
# op-reason の SSH の中継を使うマシン (dotfiles.opReason.sshRelay.enable) の ~/.local/bin/ssh (home/modules/ssh.nix)。
# op-reason-ssh は呼び出しの事実 (Linux の側の根のプロセス・呼び手・理由の OPREASON_SSH_REASON) を中継へ渡し、引数と
# stdin・stdout・stderr をそのままに ssh.exe を起こす。ssh.exe は Windows の ~/.ssh/config.d の IdentityAgent で中継へつなぐ。
# 中継を使わないマシンは ssh-wsl.sh (ssh.exe を直に起こす) のまま。
set -eu -o pipefail

use_linux_ssh="${USE_LINUX_SSH:-"0"}"
if [[ "${use_linux_ssh}" == "0" ]]; then
  exec op-reason-ssh "$@"
else
  exec /usr/bin/ssh "$@"
fi
