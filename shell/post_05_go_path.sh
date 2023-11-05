# shellcheck shell=bash

append_path() {
	target_path="$1"
	if [ -d "$target_path" ] && [ -n "${PATH##*"${target_path}"}" ] && [ -n "${PATH##*"${target_path}":*}" ]; then
		export PATH="$PATH:$target_path"
		echo "Append $target_path to PATH"
	fi
}

insert_path() {
	target_path="$1"
	if [ -d "$target_path" ] && [ -n "${PATH##*"${target_path}"}" ] && [ -n "${PATH##*"${target_path}":*}" ]; then
		export PATH="$target_path:$PATH"
		echo "Insert $target_path to PATH"
	fi
}

append_path "${HOME}/.local_go/go/bin"
if command -v go &>/dev/null; then
	insert_path "$(go env GOPATH)/bin"
fi
