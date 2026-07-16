#!/usr/bin/env bash
# set -eu -o pipefail
set -eux -o pipefail

script_dir=$(
  cd -- "$(dirname "$0")" &>/dev/null
  pwd -P
)

shfmt_target_find_options=(-name "*.sh" -o -name "*.bash")

# lint / fmt を引数にとる
# 例: ./main.bash lint
#
# NOTE: dotfiles の配置 (旧 `./main.bash setup`) は chezmoi が担当します。
#       手順は README.md を参照してください。
#       このスクリプトはリポジトリ内シェルスクリプトの lint / fmt 用途のみです。
main() {
  case "${1:-}" in
    lint)
      pushd "${script_dir}" &>/dev/null
      find "${script_dir}"/* -type f "${shfmt_target_find_options[@]}" -print0 | xargs -0 -t -I{} shfmt -d {}
      popd &>/dev/null
      ;;
    fmt)
      pushd "${script_dir}" &>/dev/null
      while IFS= read -r filepath; do
        # bash は逐次読み込み実行なので安全にファイル内容を変更するためには inode を変更する必要がある (mv で inode を変更する)
        # 実行中のファイルを変更すると次の行を読み込む際に中断される
        dirname=$(dirname "${filepath}")
        filename=$(basename "${filepath}")
        tmpfile=$(mktemp "${dirname}/.tmp.${filename}.XXXXXX")
        echo "${filepath} =shfmt=> ${tmpfile}"
        shfmt "${filepath}" >"${tmpfile}"
        mv "${tmpfile}" "${filepath}"
      done < <(find "${script_dir}"/* -type f "${shfmt_target_find_options[@]}")
      popd &>/dev/null
      ;;
    *)
      echo "Invalid argument: ${1:-}"
      echo "Usage: ${0##*/} {lint|fmt}"
      exit 1
      ;;
  esac
}

main "$@"
