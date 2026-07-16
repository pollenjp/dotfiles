# shellcheck shell=bash

# ※asdf に移行
# bin_path="${HOME}/.local_go/go/bin"
# case ":${PATH}:" in
#   *:"${bin_path}":*) ;;
#   *)
#     # add path to the end
#     export PATH="$PATH:${bin_path}"
#     ;;
# esac

# insert path for GOPATH
if command -v go &>/dev/null; then
  case "$(uname)" in
    MINGW* | MSYS* | CYGWIN*)
      # windows
      bin_path="$(cygpath "$(go env GOPATH)/bin")"
      ;;
    "Darwin" | "Linux" | *)
      # other
      bin_path="$(go env GOPATH)/bin"
      ;;
  esac

  # unix
  # windows (cygwin / git bash)
  case ":${PATH}:" in
    *:"${bin_path}":*) ;;
    *)
      # add path to the head
      export PATH="${bin_path}:$PATH"
      ;;
  esac
fi
