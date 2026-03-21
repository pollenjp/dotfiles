# shellcheck shell=bash

tty_tmp=""
tty_tmp=$(tty)
export GPG_TTY="$tty_tmp"
