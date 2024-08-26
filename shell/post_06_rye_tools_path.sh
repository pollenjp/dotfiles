# shellcheck shell=bash

# https://rye.astral.sh/guide/tools/

# この中に Python パスも入っているの注意
bin_path="${HOME}/.rye/shims"
if [ -d "${bin_path}" ]; then
  case ":${PATH}:" in
    *:"${bin_path}":*) ;;
    *)
      # add path to the head
      export PATH="${bin_path}:$PATH"
      ;;
  esac
fi
