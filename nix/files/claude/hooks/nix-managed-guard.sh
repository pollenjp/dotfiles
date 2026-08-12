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

# コマンド文字列から **書き込み先になっているトークン** だけを取り出す。
#
# ## なぜ「書き込み先」に限るのか
#
# 以前は「行のどこかに書き込み系の演算子がある」かつ「行のどこかに store を
# 指す .claude パスがある」で判定していた。この 2 つは互いに無関係なので、
# **読み取りや実行まで巻き込んで拒否していた**。
#
#   ~/.claude/skills/plantuml/scripts/plantuml-export.sh -f png 2>&1 | tail
#     -> 2>&1 の "2>" が演算子に一致し、script のパスが store なので deny
#
#   printf '@startuml' > 01.puml && ~/.claude/skills/drawio/scripts/...
#     -> 書き込み先はカレントの 01.puml なのに deny
#
# skill の script を叩く形は SKILL.md が案内している通常の使い方なので、
# これでは skill 自体が使えない。演算子の **対象** だけを見れば両方とも通る。
# 2>&1 のような fd 複製は対象が "&1" でパスではないため自然に外れる。
#
# ## 限界
#
# 正規表現による近似で、bash を解釈しているわけではない。eval、変数に入った
# パス、xargs 経由などは判定できない。**安全網であって境界ではない。**
write_targets() {
  local cmd="${1}"

  # リダイレクト先 (> file, >> file)。
  # 直前の [^0-9<>&] は 2> や >& を除くためのもの。
  grep -oE '(^|[^0-9<>&])>>?[[:space:]]*[^[:space:]"'"'"';|&()<>]+' <<<"${cmd}" \
    | sed -E 's/.*>>?[[:space:]]*//' || true

  # 引数がすべて書き込み先になるもの。
  grep -oE '\b(sed[[:space:]]+-i|tee|truncate|rm[[:space:]])[^;|&]*' <<<"${cmd}" \
    | grep -oE '[^[:space:]"'"'"';|&()]*\.claude[^[:space:]"'"'"';|&()]*' || true

  # cp / mv / install は **最後の引数だけ** が書き込み先。
  # `cp ~/.claude/skills/<名前>/flake.nix ./` のように store から読み出す形を
  # 巻き込まないため (skill の flake をプロジェクトへ複製する手順で実際に使う)。
  while read -r segment; do
    [[ -z ${segment} ]] && continue
    awk '{ print $NF }' <<<"${segment}"
  done < <(grep -oE '\b(cp|mv|install)[[:space:]][^;|&]*' <<<"${cmd}" || true)
}

hit=""

file_path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"${input}")
if [[ -n ${file_path} ]] && is_nix_managed "${file_path}"; then
  hit="${file_path}"
fi

# Bash 経由の書き換え (sed -i / リダイレクト / mv など) も見る。
# 書き込み先になっているトークンだけを取り出して個別に判定する (write_targets)。
if [[ -z ${hit} ]]; then
  command_str=$(jq -r '.tool_input.command // empty' <<<"${input}")
  if [[ -n ${command_str} ]]; then
    while read -r token; do
      [[ -z ${token} ]] && continue
      if is_nix_managed "${token}"; then
        hit="${token}"
        break
      fi
    done < <(write_targets "${command_str}")
  fi
fi

[[ -z ${hit} ]] && exit 0

reason=$(
  cat <<EOF
'${hit}' は Nix (home-manager) 管理です。/nix/store への symlink なので直接編集できません。
一般ユーザーでは Permission denied になり、root では黙って成功して store が破損します。

正しい手順 (リポジトリ本体は ghq 配下。以下 REPO="\$(ghq root)/github.com/pollenjp/dotfiles"):
  1. \${REPO}/nix/files/claude/ 配下の対応するファイルを編集する
       ~/.claude/skills/<名前>/     -> \${REPO}/nix/files/claude/skills/<名前>/
       ~/.claude/agents/<名前>.md   -> \${REPO}/nix/files/claude/agents/<名前>.md
       ~/.claude/commands/<名前>.md -> \${REPO}/nix/files/claude/commands/<名前>.md
       ~/.claude/CLAUDE.md          -> \${REPO}/nix/files/claude/CLAUDE.md
  2. 新規ファイルなら git add する
       git -C "\${REPO}" add nix/files/claude
     (~/dotfiles 経由の switch は path: なので untracked でも入るが、
      CI は git 管理下しか見ないので commit 忘れはそこで出る)
  3. 適用する
       home-manager switch --flake ~/dotfiles#<ホスト名>
     ホスト名は \${REPO}/nix/hosts/default.nix と ~/dotfiles/flake.nix に登録されている

新しい skill / agent / command を足すだけなら .nix の編集は不要です
(nix/home/modules/claude.nix が readDir で自動列挙します)。

まだ試行錯誤の段階なら、~/.claude/skills/<仮名>/ に実ディレクトリとして置けば
このガードは働きません。固まってから上記の手順でリポジトリへ移してください。

公開できない内容 (業務固有の手順や社内の名前など) は dotfiles ではなく
claude-skills (private) 側へ置きます。そちらは作業クローンへの symlink なので
このガードは働かず、編集はそのまま反映されます (ただし commit は必要)。
場所は次で判ります:
  \${REPO}/nix/scripts/bootstrap-claude-skills.sh --status
EOF
)

jq -n --arg reason "${reason}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
