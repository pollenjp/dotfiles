zsh_user_custom_zsh_dir="${HOME}/dotfiles/.zsh"

zsh_user_custom_fpath="${zsh_user_custom_zsh_dir}/zsh-completion"
[[ ! -d "${zsh_user_custom_fpath}" ]] && mkdir -p "${zsh_user_custom_fpath}"
fpath=($zsh_user_custom_fpath $fpath)
