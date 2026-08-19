#!/usr/bin/env bash
# shellcheck shell=bash
#
# マシンローカルの環境変数ファイル (~/.config/pjp/env) を用意する。
# **マシンごとに一度だけ** 実行する。冪等 (既に在れば中身に触らない)。
#
# ## これは何か
#
# そのマシンでしか使わない API キーのように、tracked にできない環境変数の置き場。
# bash.nix / fish.nix のローダが「在れば読む / 無ければ何もしない」で参照する。
# 形式の詳細は nix/README.md の「マシンローカルの環境変数」を参照。
#
# ## なぜ Nix で配置しないのか
#
# 中身は秘密情報なので、リポジトリにも /nix/store にも置けない。home.file で
# 配置すると store 経由になり、誰でも読める場所に値が残る。
# home.sessionVariables も同じ理由で使えない。
#
# ## なぜ home.activation でやらないのか
#
# 一度作ったら以後は触らないファイルなので、switch のたびに走らせる意味が無い。
# activation に入れると store 管理でないファイルを switch が作ることになり、
# 「Nix の管理下か否か」の線が曖昧になる。
#
# ## 中身は絶対に上書きしない
#
# 実際の API キーが入っているファイルなので、既に在るときは何も書かない。
# 作るのは初回だけ。

set -eu -o pipefail

env_file="${XDG_CONFIG_HOME:-${HOME}/.config}/pjp/env"

# stat のオプションは GNU (Linux) と BSD (macOS) で違う。
file_mode() {
  local mode
  if mode=$(stat -c '%a' "$1" 2>/dev/null); then
    printf '%s' "${mode}"
  else
    stat -f '%Lp' "$1"
  fi
}

if [[ -e ${env_file} ]]; then
  echo "既に在るので中身には触りません: ${env_file}"
else
  mkdir -p "$(dirname "${env_file}")"
  # 値を足すときに README を見に行かなくて済むよう、形式を頭に書いておく。
  # コメントと空行はローダが無視するので、実質は空ファイルと同じ。
  cat >"${env_file}" <<'TEMPLATE'
# マシンローカルの環境変数。git にも /nix/store にも入らない。
# bash / fish の両方が起動時に読む (nix/README.md も参照)。
#
#   - 行頭から KEY=VALUE、1 行 1 個、改行は LF
#   - クォートしない。= の後ろは行末までそのまま値 (FOO='x' は 'x' になる)
#   - 展開もコマンド置換もしない ($X は文字列 "$X" のまま)
#   - 識別子で始まらない行は黙って無視される
#
# 例:
#   FOO_API_KEY=sk-xxxx
TEMPLATE
  echo "作りました: ${env_file}"
fi

# 秘密情報を置く前提のファイルなので、緩ければ締める。
mode=$(file_mode "${env_file}")
if [[ ${mode} != 600 ]]; then
  chmod 600 "${env_file}"
  echo "パーミッションを ${mode} -> 600 にしました。"
fi

echo
echo "値を足すには (新しいシェルから有効になる):"
echo "  \$EDITOR ${env_file}"
