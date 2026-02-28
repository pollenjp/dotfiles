#!/usr/bin/env bash
# wrapper for using 1password ssh client on WSL
set -eu -o pipefail

candidates=(
  "/c/Program Files/OpenSSH/ssh-add.exe"
  "/c/Windows/System32/OpenSSH/ssh-add.exe"
)

for _ssh_path in "${candidates[@]}"; do
  if command -v "${_ssh_path}" &>/dev/null; then
    exec "${_ssh_path}" "$@"
  fi
done

echo "ERROR: ssu not found" >&2
exit 1
