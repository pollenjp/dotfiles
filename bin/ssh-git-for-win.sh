#!/usr/bin/env bash
# wrapper for using 1password ssh client on WSL
set -eu -o pipefail

/c/Windows/System32/OpenSSH/ssh.exe "$@"
