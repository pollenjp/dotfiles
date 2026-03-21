# shellcheck shell=bash

bin_path="${HOME}/.local/bin"
case ":${PATH}:" in
  *:"${bin_path}":*) ;;
  *)
    export PATH="${bin_path}:$PATH"
    ;;
esac

if command -v bindkey &>/dev/null; then
  bindkey -v
fi
