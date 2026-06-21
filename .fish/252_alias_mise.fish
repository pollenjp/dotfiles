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

# mise install (060_mise.fish) の後、現在のツールバージョンをグローバル設定へ
# 1 日 1 回だけ pin する。読み込み順 (060_mise.fish → 252_alias_mise.fish) により
# mise install の完了後に実行される。
# フラグ (mtime) で 1 日 1 回、flock で多重起動時の競合を制御する。
begin
    set -l _lock_flag ~/.config/mise/.mise_last_lock
    flock -x 9
    if not test -f $_lock_flag; or test (math (date +%s) - (stat -c %Y $_lock_flag 2>/dev/null; or echo 0)) -gt 86400
        echo "== Pinning current mise tool versions to global config =="
        mise_lock_to_current_global
        touch $_lock_flag
    end
end 9>/tmp/mise_lock_to_current_lock
