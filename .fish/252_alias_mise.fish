# Mise abbreviations

abbr m 'mise'
abbr mr 'mise run'

# 現在 (mise ls --current) で有効なツールのバージョンを mise の設定に固定する。
# $argv: `mise use` に渡す追加オプション (例: グローバル設定なら "-g")
function _mise_lock_to_current
    mise ls --current --json | jq -r --arg opts "$argv" '
        to_entries[]
        | "mise use \($opts) --pin \(.key)@\(.value[0].version)"
    ' | sh
end

# カレントの設定 (mise.toml 等) に現在のバージョンを固定する
function mise_lock_to_current --description 'Pin current tool versions to local mise config'
    _mise_lock_to_current
end

# グローバル設定 (mise use -g) に現在のバージョンを固定する
function mise_lock_to_current_global --description 'Pin current tool versions to global mise config'
    _mise_lock_to_current -g
end
