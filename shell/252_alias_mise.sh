# shellcheck shell=sh

alias m='mise'
alias mr='mise run'

# 現在 (mise ls --current) で有効なツールのバージョンを mise の設定に固定する。
# $1: `mise use` に渡す追加オプション (例: グローバル設定なら "-g")
_mise_lock_to_current() {
  mise ls --current --json |
    jq -r --arg opts "$1" '
      to_entries[]
      | "mise use \($opts) --pin \(.key)@\(.value[0].version)"
    ' | sh
}

# カレントの設定 (mise.toml 等) に現在のバージョンを固定する
mise_lock_to_current() {
  _mise_lock_to_current ""
}

# グローバル設定 (mise use -g) に現在のバージョンを固定する
mise_lock_to_current_global() {
  _mise_lock_to_current "-g"
}
