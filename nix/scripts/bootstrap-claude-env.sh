#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の commit を無署名にする env を ~/.claude/settings.json へ登録する。
# **マシンごとに一度だけ** 実行する。
#
# ## 何のために
#
# このマシンの git は 1Password の op-ssh-sign で署名する設定
# (git.nix の signing / commit.gpgSign)。署名のたびにホスト側 Windows の
# 1Password が承認ダイアログを出すので、Claude に commit させるとそこで止まる。
# Claude のセッションからの commit だけ署名を外す。
#
# ## なぜ env なのか
#
# git は GIT_CONFIG_COUNT / GIT_CONFIG_KEY_<n> / GIT_CONFIG_VALUE_<n> で渡した
# config を **config ファイルより優先**する。これを settings.json の env に置くと、
#
#   - Claude のセッション (Bash tool) にだけ効く。自分の手元のターミナルからの
#     commit は今どおり 1Password で署名される
#   - git commit 直打ちでも --amend でも rebase --continue でも git tag でも効く。
#     「--no-gpg-sign を付ける」という指示と違い、忘れる余地が無い
#
# 他の案を採らなかった理由:
#
#   CLAUDE.md に指示を書く    soft な指示なので忘れうる。常時トークンも食う
#   repo local の gpgsign     自分の commit も無署名になる。repo ごとに要る
#   includeIf gitdir:         worktree の外で Claude が commit すると効かず、
#                             逆に worktree で自分が commit すると無署名になる
#   PreToolUse で deny        効くが bash 文字列の解析 (複合コマンド・クォート)
#                             が要る。env で足りる
#
# Claude Code 自身も同じ仕組みで credential.interactive=false を注入するが、
# **既存の GIT_CONFIG_COUNT を読んでその先に足す**実装なので競合しない。
#
# ## 何をするか
#
# ~/.claude/settings.json の .env へ GIT_CONFIG_* を書く。他のキーは保持する。
# 冪等 (既に同じなら何もしない)。GIT_CONFIG_* が既にあるときは、下の desired 以外の
# ペアを順序を保って残し、番号だけ 0 から振り直す。
#
# ## 注意
#
#   - GitHub の branch protection "Require signed commits" が有効な repo では、
#     Claude が作った commit は push で弾かれる
#   - Claude が rebase / amend した既存 commit の署名も落ちる
#
# ## なぜ Nix でやらないのか
#
# env の定義は settings.json にしか書けない。そして settings.json は Claude Code
# 自身が書き換える (権限の「常に許可」を選んだときなど) ため、store 上の read-only
# ファイルにできない。bootstrap-claude-hook.sh とまったく同じ切り分け。

set -eu -o pipefail

settings="${HOME}/.claude/settings.json"

# 無署名にする config。tag も併せて落とす (tag.gpgsign true なので、
# git tag を打たせると commit と同じダイアログで止まる)。
desired='[
  { "k": "commit.gpgsign", "v": "false" },
  { "k": "tag.gpgsign", "v": "false" }
]'

if ! command -v jq &>/dev/null; then
  echo "jq が見つかりません。先に home-manager switch を実行してください。" >&2
  exit 1
fi

mkdir -p "$(dirname "${settings}")"
[[ -f ${settings} ]] || echo '{}' >"${settings}"

if ! jq -e . "${settings}" >/dev/null 2>&1; then
  echo "${settings} が JSON として壊れています。手で直してください。" >&2
  exit 1
fi

tmp=$(mktemp "${settings}.XXXXXX")
# jq が落ちたときに settings.json の隣へ中間ファイルを残さない。
trap 'rm -f "${tmp}"' EXIT

# .env の GIT_CONFIG_* を desired で置き換える。
#   - desired と同じ config を指す既存ペアは落とす (値が違っても desired が勝つ)
#   - 無関係なペアは順序を保って残す
#   - 残したものと desired を連結し、0 から番号を振り直す
#     (番号に穴があると git はその手前までしか読まないため、通し番号にする)
jq --argjson desired "${desired}" '
  (.env // {}) as $env
  | (($env.GIT_CONFIG_COUNT // "0") | tonumber) as $n
  | [ range(0; $n)
      | tostring as $i
      | { k: $env["GIT_CONFIG_KEY_" + $i], v: $env["GIT_CONFIG_VALUE_" + $i] }
      | select(.k != null) ] as $existing
  | ($desired | map(.k)) as $ours
  | [ $existing[] | .k as $k | select(($ours | index($k)) == null) ] as $kept
  | ($kept + $desired) as $all
  | .env = (
      ($env | with_entries(select(.key | test("^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)$") | not)))
      + { GIT_CONFIG_COUNT: ($all | length | tostring) }
      + ([ $all | to_entries[]
           | { ("GIT_CONFIG_KEY_" + (.key | tostring)): .value.k,
               ("GIT_CONFIG_VALUE_" + (.key | tostring)): .value.v } ] | add // {})
    )
' "${settings}" >"${tmp}"

if [[ $(jq -S . "${settings}") == "$(jq -S . "${tmp}")" ]]; then
  echo "登録済みです: ${settings} の .env"
  exit 0
fi

mv "${tmp}" "${settings}"

echo "登録しました: commit / tag を無署名にする env"
echo
echo "--- ${settings} の env ---"
jq '.env' "${settings}"
echo
echo "確認:  env | grep GIT_CONFIG  /  git config --get commit.gpgsign  (false になる)"
echo "実行中のセッションにも入る。入らなければ Claude Code を再起動する。"
echo
echo '注意: "Require signed commits" が有効な repo では、Claude の commit は push で弾かれます。'
