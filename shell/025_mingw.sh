# shellcheck shell=bash

if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "mingw"* ]]; then
  PATH="/mingw64/bin:${PATH}"
fi
