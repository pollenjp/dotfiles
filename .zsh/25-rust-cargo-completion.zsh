if [[ $commands[rustup] ]]; then
	rustup completions zsh >"${zsh_user_custom_fpath}/_rustup"
	rustup completions zsh cargo >"${zsh_user_custom_fpath}/_cargo"
fi
