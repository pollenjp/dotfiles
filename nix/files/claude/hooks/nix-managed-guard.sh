#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の PreToolUse フック。
#
# ~/.claude/ 配下の **Nix 管理パス** を直接編集しようとしたときだけ介入し、
# 正しい手順を Claude に伝えて拒否する。
#
# ## なぜ必要か
#
# Nix 管理下のものは /nix/store への symlink で、store は read-only。
#   - 一般ユーザー -> Permission denied (失敗するので気付ける)
#   - root         -> 黙って成功し store が破損する
#                     (nix store verify が hash 不一致を検出する状態になる。
#                      変更は次の GC やリビルドで失われ、エラーも出ない)
#
# root のケースが特に危険なので、編集させる前に止める。
#
# ## 判定方法
#
# パス名のパターンではなく、**実際に /nix/store を指す symlink かどうか**で判定する。
# パターン照合だと次を誤って止めてしまう:
#   - ~/.claude/skills/manifest.json      (Claude Code 管理の実ファイル)
#   - ~/.claude/skills/pdf/               (Anthropic 配信 skill の実ディレクトリ)
#   - ~/.claude/skills/<試作>/            (直接置いて試行錯誤している最中のもの)
#
# 対象が存在しない場合 (新規作成) は親をたどる。管理下ディレクトリの中に
# ファイルを作ろうとした場合も捕まえられる。
#
# ## 登録方法 (マシンごとに一度だけ)
#
# ~/.claude/settings.json は Claude Code 自身が書き換える (権限の「常に許可」など)
# ため Nix 管理下に置けない。スクリプトだけを Nix が配置し、登録は手で行う。
#
#   {
#     "hooks": {
#       "PreToolUse": [
#         {
#           "matcher": "Edit|Write|NotebookEdit|Bash",
#           "hooks": [
#             { "type": "command", "command": "~/.claude/hooks/nix-managed-guard.sh" }
#           ]
#         }
#       ]
#     }
#   }
#
# ## 入出力
#
# stdin  : {"tool_name": "...", "tool_input": {"file_path"|"notebook_path"|"command": ...}}
# stdout : 介入するときのみ hookSpecificOutput を返す。何もしないときは無出力
# exit   : 常に 0 (拒否は JSON の permissionDecision で表現する)
#
# 依存: jq (Nix の home.packages に入っている)

set -eu -o pipefail

input=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"${input}")

# 書き込み系のツール以外は素通しする。
# (matcher でも絞るが、スクリプト単体でも正しく振る舞うようにしておく)
case "${tool}" in
  Edit | Write | NotebookEdit | Bash) ;;
  *) exit 0 ;;
esac

# 与えられたパスが Nix 管理 (= 解決先が /nix/store 配下) かどうか。
#
# symlink を辿った最終的な実体で判定する。symlink されているのは
# skill ディレクトリ自体なので、その中のファイル
# (~/.claude/skills/<管理下>/SKILL.md) も解決先は store になる。
#
# まだ存在しないパス (新規作成) は、最も近い既存の祖先まで遡って判定する。
# これで「管理下ディレクトリの中に新しいファイルを作る」も捕まえられる。
is_nix_managed() {
  local p="${1}"
  p="${p/#\~/${HOME}}"
  [[ ${p} != /* ]] && return 1

  local probe="${p}"
  while [[ ! -e ${probe} && ${probe} != "/" && ${probe} != "." ]]; do
    probe=$(dirname "${probe}")
  done

  local real
  real=$(readlink -f "${probe}" 2>/dev/null || true)
  [[ ${real} == /nix/store/* ]]
}

hit=""

file_path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"${input}")
if [[ -n ${file_path} ]] && is_nix_managed "${file_path}"; then
  hit="${file_path}"
fi

# Bash 経由の書き換え (sed -i / リダイレクト / mv など) も見る。
# コマンド文字列から .claude 配下らしきトークンを拾って個別に判定する。
if [[ -z ${hit} ]]; then
  command_str=$(jq -r '.tool_input.command // empty' <<<"${input}")
  if [[ -n ${command_str} ]] \
    && [[ ${command_str} =~ (sed[[:space:]]+-i|tee|[^|]>|>>|mv[[:space:]]|cp[[:space:]]|rm[[:space:]]|truncate|install[[:space:]]) ]]; then
    while read -r token; do
      [[ -z ${token} ]] && continue
      if is_nix_managed "${token}"; then
        hit="${token}"
        break
      fi
    done < <(grep -oE '[^[:space:]"'"'"';|&()]*\.claude[^[:space:]"'"'"';|&()]*' <<<"${command_str}" || true)
  fi
fi

[[ -z ${hit} ]] && exit 0

reason=$(
  cat <<EOF
'${hit}' は Nix (home-manager) 管理です。/nix/store への symlink なので直接編集できません。
一般ユーザーでは Permission denied になり、root では黙って成功して store が破損します。

正しい手順:
  1. ~/dotfiles/nix/files/claude/ 配下の対応するファイルを編集する
       ~/.claude/skills/<名前>/     -> ~/dotfiles/nix/files/claude/skills/<名前>/
       ~/.claude/agents/<名前>.md   -> ~/dotfiles/nix/files/claude/agents/<名前>.md
       ~/.claude/commands/<名前>.md -> ~/dotfiles/nix/files/claude/commands/<名前>.md
       ~/.claude/CLAUDE.md          -> ~/dotfiles/nix/files/claude/CLAUDE.md
  2. 新規ファイルなら git add する (flake は untracked ファイルを見ない)
       git -C ~/dotfiles add nix/files/claude
  3. 適用する
       home-manager switch --flake ~/dotfiles/nix#<ホスト名>
     ホスト名は ~/dotfiles/nix/hosts/default.nix に登録されている

新しい skill / agent / command を足すだけなら .nix の編集は不要です
(nix/home/modules/claude.nix が readDir で自動列挙します)。

まだ試行錯誤の段階なら、~/.claude/skills/<仮名>/ に実ディレクトリとして置けば
このガードは働きません。固まってから上記の手順でリポジトリへ移してください。
EOF
)

jq -n --arg reason "${reason}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
