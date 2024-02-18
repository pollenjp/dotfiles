# shellcheck shell=bash

print_color() {
  printf "\033[48;2;%d;%d;%dm\033[38;2;%d;%d;%dm%s\e[0m\n" 0 205 0 255 255 255 "$1"
}

generate_string_to_get_this_file() {
  case "${shell_rc_file##*/}" in
    ".bashrc")
      # shellcheck disable=SC2016
      this_file='$BASH_SOURCE'
      ;;
    ".zshrc")
      # shellcheck disable=SC2016
      this_file='${(%):-%N}'
      ;;
    *)
      echo "Not supported shellrc file: ${shell_rc_file}"
      exit 1
      ;;
  esac
  echo "${this_file}"
}

append_load_rc_line() {
  shell_rc_file="$1"
  load_file="$2"
  load_file=$(realpath "${load_file}")

  load_cmd=". ${load_file}"
  if [[ -f "${shell_rc_file}" ]] \
    && (grep "${load_cmd}" "${shell_rc_file}"); then
    print_color 'already exists'
  else
    print_color 'append'

    {
      echo '# check self or not'
      this_file=$(generate_string_to_get_this_file)
      # this_file はスクリプト内で算出する必要がある
      echo "this_file=${this_file}"
      # shellcheck disable=SC2016
      echo 'if [[ "$(realpath "${this_file}")" != '"${load_file}"' ]]; then'
      echo "  ${load_cmd}"
      echo "fi"
    } >>"${shell_rc_file}"

  fi
}
