# shellcheck shell=bash

bin_paths=(
  "${HOME}/bin"
  "${HOME}/.local/bin"
)

for _p in "${bin_paths[@]}"; do
  case ":${PATH}:" in
    *:${_p}:*) ;;
    *)
      export PATH="${_p}:${PATH}"
      ;;
  esac
done

if command -v bindkey &>/dev/null; then
  bindkey -v
fi
