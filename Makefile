SHELL := /bin/bash
export

.DEFAULT_GOAL := help

.PHONY: clean
clean:  ## remove generated symbolic links
	-unlink "$${HOME}"/.tmux.conf
	-unlink "$${HOME}"/.config/git/ignore
	-unlink "$${HOME}"/.config/nvim
	-unlink "$${HOME}"/.vim

####################
# Set Config files #
####################

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
