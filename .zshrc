# shellcheck shell=bash

function debug_rc_file() {
    local rc="${1}"
    if [ -z "${rc}" ]; then
        printf "arguments are not set."
        exit 1
    fi

    if [[ -o login ]]; then
        printf "%s\n" "${rc}"
    fi
}

# load pre-common settings
for rc in ~/dotfiles/shell/pre_*.sh; do
    debug_rc_file "${rc}"
    # shellcheck disable=SC1090
    . "${rc}"
done

# load shell-specific settings
for rc in ~/dotfiles/.zsh/*.zsh; do
    debug_rc_file "${rc}"
    # shellcheck disable=SC1090
    . "${rc}"
done

# load post-common settings
for rc in ~/dotfiles/shell/post_*.sh; do
    debug_rc_file "${rc}"
    # shellcheck disable=SC1090
    . "${rc}"
done

common_shellrc="${HOME}"/.common_shellrc.sh
if ! [ -f "${common_shellrc}" ]; then
    touch "${common_shellrc}"
fi

# shellcheck disable=SC1090
. "${common_shellrc}"
