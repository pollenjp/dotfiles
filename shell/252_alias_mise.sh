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

# mise install (060_mise.sh) の後、現在のツールバージョンをグローバル設定へ
# 1 日 1 回だけ pin する。読み込み順 (060_mise.sh → 252_alias_mise.sh) により
# mise install の完了後に実行される。
# フラグ (mtime) で 1 日 1 回、flock で多重起動時の競合を制御する。
_mise_lock_flag=~/.config/mise/.mise_last_lock
{
  flock -x 9
  if [ ! -f "${_mise_lock_flag}" ] || \
     [ "$(( $(date +%s) - $(stat -c %Y "${_mise_lock_flag}" 2>/dev/null || echo 0) ))" -gt 86400 ]; then
    echo "== Pinning current mise tool versions to global config =="
    mise_lock_to_current_global
    touch "${_mise_lock_flag}"
  fi
} 9>/tmp/mise_lock_to_current_lock
unset _mise_lock_flag
