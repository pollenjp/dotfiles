# Mise abbreviations

abbr m 'mise'
abbr mr 'mise run'

# 現在 (mise ls --current) で有効なツールのバージョンを mise に固定する。
# 引数なしでカレントの設定 (mise.toml 等) に、`-g` を渡すとグローバル設定に固定する。
# $argv: `mise use` に渡す追加オプション (例: "-g")
function _mise_lock_to_current
    mise use $argv --pin (mise ls --current --json | jq -r 'to_entries[] | "\(.key)@\(.value[0].version)"')
end

# グローバル設定 (mise use -g) に現在のバージョンを固定する
function mise_lock_to_current_global --description 'Pin current tool versions to global mise config'
    _mise_lock_to_current -g
end
