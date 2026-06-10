# shellcheck shell=sh

alias m='mise'
alias mr='mise run'

# 現在 (mise ls --current) で有効なツールのバージョンを mise に固定する。
# 引数なしでカレントの設定 (mise.toml 等) に、`-g` を渡すとグローバル設定に固定する。
# $@: `mise use` に渡す追加オプション (例: "-g")
_mise_lock_to_current() {
  # shellcheck disable=SC2046  # tool@version を複数引数として単語分割で展開したい
  mise use "$@" --pin $(mise ls --current --json | jq -r 'to_entries[] | "\(.key)@\(.value[0].version)"')
}

# グローバル設定 (mise use -g) に現在のバージョンを固定する
mise_lock_to_current_global() {
  _mise_lock_to_current -g
}
