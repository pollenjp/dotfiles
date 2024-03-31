#!/usr/bin/env bash
# set -eu -o pipefail
set -eux -o pipefail

script_dir=$(
  cd -- "$(dirname "$0")" &>/dev/null
  pwd -P
)
# shellcheck source=script/utils.bash
. "${script_dir}/script/utils.bash"

cache_dir="${script_dir}/.cache"
mkdir -p "${cache_dir}"

shfmt_target_find_options=(-name "*.sh" -o -name "*.bash")

# lint / fmt / setup を引数にとる
# 例: ./main.sh lint
main() {
  case "${1:-}" in
    lint)
      # cd "${script_dir}"
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
    setup)
      pushd "${script_dir}" &>/dev/null

      append_load_rc_line "${HOME}"/.bashrc "${HOME}"/dotfiles/.bashrc
      append_load_rc_line "${HOME}"/.zshrc "${HOME}"/dotfiles/.zshrc

      src_files=(
        "${script_dir}/.config/starship.toml"
        "${script_dir}/.config/nvim"
        "${script_dir}/.config/pypoetry"
        "${script_dir}/.gitconfig"
        "${script_dir}/.gitignore_global"
        "${script_dir}/.tmux.conf"
        "${script_dir}/.screenrc"
        "${script_dir}/.config/zellij/config.kdl"
        "${script_dir}/.vimrc"
        "${script_dir}/.vim"
      )
      dst_files=(
        "${HOME}/.config/starship.toml"
        "${HOME}/.config/nvim"
        "${HOME}/.config/pypoetry"
        "${HOME}/.gitconfig"
        "${HOME}/.config/git/ignore"
        "${HOME}/.tmux.conf"
        "${HOME}/.screenrc"
        "${HOME}/.config/zellij/config.kdl"
        "${HOME}/.vimrc"
        "${HOME}/.vim"
      )
      [[ ${#src_files[@]} -eq ${#dst_files[@]} ]] || {
        echo "Invalid length of src_files and dst_files"
        exit 1
      }
      uname_result=$(uname)
      for ((i = 0; i < ${#src_files[@]}; i++)); do
        src_path="${src_files[i]}"
        dst_path="${dst_files[i]}"
        mkdir -p "$(dirname "${dst_path}")"
        case ${uname_result} in
          Darwin | Linux)
            # if symlink exists, remove it
            [[ -L ${dst_path} ]] && unlink "${dst_path}"
            [[ -a ${dst_path} ]] && echo "Already exists ${dst_path}" && exit 1
            ln -s "${src_path}" "${dst_path}"
            ;;
          MINGW* | MSYS* | CYGWIN*)
            # WindowsOS はシンボリックリンクが使えないのでコピーする
            # if file or directory exists, remove it
            [[ -f ${dst_path} ]] && rm "${dst_path}"
            [[ -d ${dst_path} ]] && rm -rf "${dst_path}"
            # TODO: rsync may be better
            cp -a "${src_path}" "${dst_path}"
            ;;
          *)
            echo "Not supported OS: $(uname)"
            exit 1
            ;;
        esac
      done

      # .ssh/config
      config_file="${HOME}"/.ssh/config
      match_string='Include ~/dotfiles/ssh_config'
      touch "${config_file}"
      chmod 600 "${config_file}"
      if grep "${match_string}" "${config_file}" &>/dev/null; then
        print_color "Already exists '${match_string}' in '${config_file}'"
      else
        # 先頭に追加
        tmp=$(cat "${config_file}")
        echo "${match_string}" >"${config_file}"
        echo "${tmp}" >>"${config_file}"
        print_color "Append '${match_string}' to '${config_file}'"
      fi

      # bash completion for win

      dst_path="${cache_dir}/bash-completion/bash_completion"
      dst_dirpath="$(dirname "${dst_path}")"
      if ! [[ -f "${dst_path}" ]]; then
        mkdir -p "${dst_dirpath}"
        target_name="bash-completion-2.11"
        curl -L --continue-at - --output "${dst_dirpath}/${target_name}.tar.xz" \
          https://github.com/scop/bash-completion/releases/download/2.11/"${target_name}".tar.xz
        tar -Jxvf "${dst_dirpath}/${target_name}.tar.xz" -C "${dst_dirpath}"
        # TODO: rsync may be better
        cp -a "${dst_dirpath}/${target_name}/bash_completion" "${dst_path}"
      fi
      load_cmd=". ${dst_path}"
      if ! grep "${load_cmd}" "${HOME}"/.bashrc &>/dev/null; then
        {
          echo '# use bash-completion, if available'
          # shellcheck disable=SC2016
          echo '[[ ${PS1} && -f '"${dst_path}"' ]] && '"${load_cmd}"
        } >>"${HOME}"/.bashrc
      fi

      popd &>/dev/null
      ;;
    *)
      echo "Invalid argument: ${1:-}"
      exit 1
      ;;
  esac
}

main "$@"
