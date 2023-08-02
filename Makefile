SHELL := /bin/bash
export

.DEFAULT_GOAL := help

.PHONY: setup
setup:  ## run all setup
# shell
	${MAKE} setup-sshconfig
	${MAKE} setup-bashrc
	${MAKE} setup-zshrc
#  terminal multiplexer
	${MAKE} setup-tmuxconf
	-${MAKE} setup-screenrc
	${MAKE} setup-zellij
# app
	${MAKE} setup-gitconfig
	${MAKE} setup-vimrc
	${MAKE} setup-poetry-config

.PHONY: setup-win
setup-win:  ## WindowsOS
	${MAKE} clean-win
	${MAKE} setup-sshconfig
	${MAKE} setup-symlink-for-win
	${MAKE} setup-bashrc
	${MAKE} setup-zshrc
	${MAKE} setup-gitconfig
	${MAKE} setup-vimrc
	${MAKE} setup-tmuxconf
	${MAKE} setup-pacman-for-win
	if ! command -v make &> /dev/null; then pacman -Sy --noconfirm make; fi
	if ! command -v wget &> /dev/null; then pacman -Sy --noconfirm wget; fi
	${MAKE} setup-bash-completion-for-win

.PHONY: setup-win-light
setup-win-light:  ## WindowsOS
	${MAKE} clean-win
	${MAKE} setup-sshconfig
	${MAKE} setup-symlink-for-win
	${MAKE} setup-bashrc
	${MAKE} setup-gitconfig
	${MAKE} setup-vimrc

.PHONY: setup-win-no-symlink
setup-win-no-symlink:
	${MAKE} clean-win
	${MAKE} setup-sshconfig
	${MAKE} setup-bashrc
	${MAKE} setup-gitconfig-for-win-no-symlink

.PHONY: clean
clean:  ## remove generated symbolic links
	-unlink "$${HOME}"/.tmux.conf
	-unlink "$${HOME}"/.screenrc
	-unlink "$${HOME}"/.gitconfig
	-unlink "$${HOME}"/.config/git/ignore
	-unlink "$${HOME}"/.vimrc
	-unlink "$${HOME}"/.config/nvim
	-unlink "$${HOME}"/.vim

.PHONY: clean-win
clean-win:
# windows os can't create symbolic link
#	-unlink "$${HOME}"/.bashrc "$${HOME}"/.zshrc
	-unlink "$${HOME}"/.tmux.conf
	-unlink "$${HOME}"/.screenrc
	-unlink "$${HOME}"/.gitconfig
	-unlink "$${HOME}"/.config/git/ignore
	-unlink "$${HOME}"/.vimrc
	-unlink "$${HOME}"/.config/nvim
	-unlink "$${HOME}"/.vim

####################
# Set Config files #
####################

.PHONY: setup-bashrc
setup-bashrc:  ## .bashrc
	./script/append-load-rc-line.sh \
		"$${HOME}"/.bashrc \
		"$${HOME}"/dotfiles/.bashrc


.PHONY: setup-symlink-for-win
setup-symlink-for-win:
	touch "$${HOME}/.bashrc"
#	if [[ -z "$(echo "$${MSYS}" | grep --quiet 'winsymlinks:nativestrict')" ]]; then
	if ! echo "$${MSYS}" | grep --quiet 'winsymlinks:nativestrict'; then \
		echo '##########################################################################' ;\
		echo '  You should add the following line into' ;\
		echo '  your ~/.bashrc and ~/.zshrc manually.' ;\
		echo '' ;\
		echo '  export MSYS="$${MSYS} winsymlinks:nativestrict" ' ;\
		echo '' ;\
		echo '  Ex)' ;\
		echo echo "'"export MSYS=\"'$${MSYS}' winsymlinks:nativestrict\""'" ">> ~/.bashrc " ;\
		echo echo "'"export MSYS=\"'$${MSYS}' winsymlinks:nativestrict\""'" ">> ~/.zshrc  " ;\
		echo '' ;\
		echo '  Exit and re-run';\
		echo '' ;\
		echo '##########################################################################' ;\
		exit 1;\
	fi

.PHONY: setup-bash-completion-for-win
setup-bash-completion-for-win:
	if ! [[ -f /usr/local/share/bash-completion/bash_completion ]]; then\
		target_parent_dir=$${HOME}/tmp;\
		target_name="bash-completion-2.11";\
		target_dir="$${target_parent_dir}/$${target_name}";\
		mkdir -p "$${target_parent_dir}";\
		cd "$${target_parent_dir}";\
		wget https://github.com/scop/bash-completion/releases/download/2.11/$${target_name}.tar.xz;\
		tar -xvf "$${target_name}.tar.xz";\
		cd "$${target_dir}";\
		./configure ;\
		make ;\
		if ! touch /c/tmp.txt; then\
			echo "##############################################################";\
			echo "# You should run the following command as administrator mode";\
			echo "#";\
			echo "# cd $${target_dir} && make install";\
			echo "#";\
			echo "##############################################################";\
			exit 1;\
		fi;\
		make install ;\
	fi
	if ! grep 'bash_completion' "$${HOME}"/.bashrc &> /dev/null; then\
		echo '# Use bash-completion, if available' >> "$${HOME}"/.bashrc;\
		echo '[[ $${PS1} && -f /usr/share/bash-completion/bash_completion ]] \'\
			>> "$${HOME}"/.bashrc;\
		echo '&& . /usr/share/bash-completion/bash_completion'\
			>> "$${HOME}"/.bashrc;\
	fi

.PHONY: setup-pacman-for-win
setup-pacman-for-win:
# detect you're in administrator mode
	if ! command -v pacman &>/dev/null; then\
		if ! touch /c/tmp.txt; then\
			echo "########################################";\
			echo "# You should run in administrator mode #";\
			echo "########################################";\
			exit 1;\
		fi;\
		./script/install-pacman-for-git-bash.sh ;\
	fi
	if ! command -v zsh &>/dev/null; then\
		if ! touch /c/tmp.txt; then\
			echo "########################################";\
			echo "# You should run in administrator mode #";\
			echo "########################################";\
			exit 1;\
		fi;\
		pacman -S --noconfirm zsh ;\
	fi

.PHONY: setup-gitconfig
setup-gitconfig:  ## .gitconfig, .gitignore_global, ~/.config/git/ignore
# .gitconfig
	file_src="$$(realpath .gitconfig)" ;\
	file_dst="$${HOME}/.gitconfig" ;\
	if [[ -h $${file_dst} ]]; then\
		unlink $${file_dst} ;\
	elif [[ -f $${file_dst} ]]; then\
		rm $${file_dst} ;\
	fi ;\
	ln -s "$${file_src}" $${file_dst}
# .gitignore_global, ~/.config/git/ignore
	mkdir -p "$${HOME}"/.config/git
	file_src="$$(realpath .gitignore_global)" ;\
	file_dst="$${HOME}/.config/git/ignore" ;\
	if [[ -h $${file_dst} ]]; then\
		unlink "$${file_dst}" ;\
	elif [[ -f $${file_dst} ]]; then\
		rm "$${file_dst}" ;\
	fi ;\
	ln -s "$${file_src}" "$${file_dst}"

.PHONY: setup-gitconfig-for-win-no-symlink
setup-gitconfig-for-win-no-symlink:
# .gitconfig
	file_src="$$(realpath .gitconfig)" ;\
	file_dst="$${HOME}/.gitconfig" ;\
	if [[ -h $${file_dst} ]]; then\
		unlink $${file_dst} ;\
	elif [[ -f $${file_dst} ]]; then\
		rm $${file_dst} ;\
	fi ;\
	cp "$${file_src}" $${file_dst}
# .gitignore_global, ~/.config/git/ignore
	mkdir -p "$${HOME}"/.config/git
	file_src="$$(realpath .gitignore_global)" ;\
	file_dst="$${HOME}/.config/git/ignore" ;\
	if [[ -h $${file_dst} ]]; then\
		unlink "$${file_dst}" ;\
	elif [[ -f $${file_dst} ]]; then\
		rm "$${file_dst}" ;\
	fi ;\
	cp "$${file_src}" "$${file_dst}"

.PHONY: setup-screenrc
setup-screenrc:  ## .screenrc
	-file_src="$$(realpath .screenrc)"; ln -s "$${file_src}" "$${HOME}/.screenrc"

.PHONY: setup-sshconfig
setup-sshconfig:  ## .screenrc
	(\
		set -eux ;\
		config_file="$${HOME}"/.ssh/config ;\
		match_string='Include ~/dotfiles/ssh_config' ;\
		touch "$${config_file}" ;\
		chmod 600 "$${config_file}" ;\
		if _=$$(grep "$${match_string}" "$${config_file}"); then\
			echo "Already exists \"$${match_string}\" in $${config_file}";\
		else\
			echo "Append: $${match_string} to $${config_file}" ;\
			tmp="$$(cat "$${config_file}")" ;\
			echo "$${match_string}" | tee "$${config_file}" ;\
			echo "$${tmp}" | tee -a "$${config_file}" ;\
		fi ;\
	)

.PHONY: setup-tmuxconf
setup-tmuxconf:  ## .tmux.conf
	mkdir -p "$${HOME}"/.tmux/log
	-file_src="$$(realpath .tmux.conf)"; ln -s "$${file_src}" "$${HOME}"/.tmux.conf

.PHONY: setup-vimrc
setup-vimrc:  ## .vimrc, .vim/
# vim
	-file_src="$$(realpath .vimrc)"; ln -s "$${file_src}" "$${HOME}"/.vimrc
	-dir_src="$$(realpath .vim)"; ln -s "$${dir_src}" "$${HOME}"/.vim
# neovim
	dir_src="$$(realpath .config/nvim)";\
		dir_tgt="$${HOME}/.config/nvim";\
		mkdir -p "$${dir_tgt%/*}";\
		if [[ -h "$${dir_tgt}" ]]; then\
			unlink "$${dir_tgt}";\
		elif [[ -d "$${dir_tgt}" ]]; then\
			echo "Remove manually: \"rm -rf $${dir_tgt}\"";\
			exit 1;\
		fi;\
		ln -s "$${dir_src}" "$${dir_tgt}"

.PHONY: setup-zshrc
setup-zshrc:  ## .zshrc, .zsh/
# create .p10k.zsh symlink
	ln -s "$${HOME}"/dotfiles/p10k/.p10k.zsh "$${HOME}"/.p10k.zsh
	./script/append-load-rc-line.sh \
		"$${HOME}"/.zshrc \
		"$${HOME}"/dotfiles/.zshrc

.PHONY: setup-poetry-config
setup-poetry-config:
	mkdir -p "${HOME}/.config"
	-unlink "$${HOME}/.config/pypoetry"
	-rm -rf "$${HOME}/.config/pypoetry"
	ln -s "$${HOME}/dotfiles/.config/pypoetry" "$${HOME}/.config/pypoetry"

.PHONY: setup-zellij
setup-zellij:
	mkdir -p "$${HOME}/.config/zellij"
	-ln -s \
		"$${HOME}/dotfiles/.config/zellij/config.kdl" \
		"$${HOME}/.config/zellij/config.kdl"

#########
# Utils #
#########

.PHONY: error
error:  ## errors処理を外部に記述することで好きなエラーメッセージをprintfで記述可能.
	$(error "${ERROR_MESSAGE}")

.PHONY: help
help:  ## show help
	@cat $(MAKEFILE_LIST) \
		| grep -E '^[.a-zA-Z0-9_-]+ *:.*##.*' \
		| xargs -I'<>' \
			bash -c "\
				printf '<>' | awk -F'[:]' '{ printf \"\033[36m%-15s\033[0m\", \$$1 }'; \
				printf '<>' | awk -F'[##]' '{ printf \"%s\n\", \$$3 }'; \
			"
