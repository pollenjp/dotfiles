#!/usr/bin/env bash
# wrapper for using 1password ssh client on WSL
set -eu -o pipefail

use_linux_ssh="${USE_LINUX_SSH:-"0"}"
if [[ "${use_linux_ssh}" == "0" ]]; then
  exec ssh-add.exe "$@"
else
  exec /usr/bin/ssh-add "$@"
fi
