#!/bin/bash -eux
shell_rc_file="$1"
load_file="$2"

(
match_string=". ${load_file}"

print_color() {
    printf "\033[48;2;%d;%d;%dm\033[38;2;%d;%d;%dm%s\e[0m\n" 0 205 0 255 255 255 "$1"
}

if [[ -f "${shell_rc_file}" ]] && (grep "${match_string}" "${shell_rc_file}"); then
    print_color 'already exists'
else
    print_color 'append'

case "${shell_rc_file##*/}" in
    ".bashrc")
        this_file='$BASH_SOURCE'
        ;;
    ".zshrc")
        this_file='${(%):-%N}'
        ;;
    *)
        echo "Not supported shellrc file: ${shell_rc_file}"
        exit 1
        ;;
esac

cat << 'EOF' | tee -a ${shell_rc_file}
# check self or not
# $0 is the path of this script
EOF

printf "this_file=%s\n" "${this_file}" | tee -a ${shell_rc_file}

cat << EOF | tee -a ${shell_rc_file}
rc_file="${load_file}"
EOF

cat << 'EOF' | tee -a ${shell_rc_file}
if [[ "$(realpath $rc_file)" != "$(realpath $this_file)" ]]; then
    . "${rc_file}"
fi
EOF

fi
)
