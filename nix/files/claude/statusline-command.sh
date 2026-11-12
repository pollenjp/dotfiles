#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の statusLine。1 行を stdout へ出す。
#
#   📄top · <model> · <dir basename> · <git branch>[*] · <context% left>
#
# shell prompt (starship) が既に出しているもの (時刻・user@host・フルパス) は
# 意図的に繰り返さない。Claude Code 側で薄く描画されるので色も控えめにする。
#
# 📄top は cc-pages の会話のトップページへのリンク (OSC 8)。押すと http://localhost:<port>/s/<session_id>/ が開き、
# cc-pages がその会話のトップページへ送る。footer のバッジ (5 個まで) から溢れたリンクも、Stop フック
# (hooks/footer-links-archive.sh) がそのページの「リンク」の節に残している。狭い pane でも切れないよう先頭に置く。
# 出すのは session_id が英数字と - だけで、cc-pages が PATH にあり、CC_PAGES_DISABLE が空のときだけ (フックと同じ見方)。
# port は home-manager が @ccPagesPort@ を dotfiles.ccPages.port (null なら cc-pages の既定の 7777) で埋める
# (home/modules/claude.nix)。
#
# 入力は stdin の JSON。数百 ms ごとに呼ばれるので jq は 1 回にまとめて起動する。
#
# **登録** は ~/.claude/settings.json に書く必要があるが、そのファイルは Claude Code
# 自身が書き換えるため Nix 管理下に置けない。スクリプト本体だけを Nix が配置し、
# 登録は nix/scripts/bootstrap-claude-statusline.sh が行う。フックと同じ切り分け。
#
# 途中で失敗しても statusLine が消えるだけで済むよう set -e は付けない。
set -uo pipefail

RESET=$'\033[0m'
C_MODEL=$'\033[2m'     # dim
C_DIR=$'\033[2;36m'    # dim cyan
C_BRANCH=$'\033[2;33m' # dim yellow
C_CTX=$'\033[2;32m'    # dim green
C_SEP=$'\033[2;90m'    # dim gray
C_LINK=$'\033[2;4;34m' # dim underline blue (📄top)

# process substitution の中の jq がこのスクリプトの stdin をそのまま読む。
# 値の中の制御文字を空白にしてから US (\x1f) でつなぐ。区切りが空白類 (タブ) だと、read は空の値の
# 並びを 1 つの区切りにまとめ、後ろの値が前の欄にずれる (会話の始めの remaining_percentage は空)。
model=""
cwd=""
remaining=""
session_id=""
IFS=$'\x1f' read -r model cwd remaining session_id < <(
  jq -r '[
    .model.display_name // "",
    .workspace.current_dir // .cwd // "",
    (.context_window.remaining_percentage // "" | tostring),
    .session_id // ""
  ] | map(tostring | gsub("[[:cntrl:]]"; " ")) | join("\u001f")' 2>/dev/null
)

dir_name=""
[[ -n ${cwd} ]] && dir_name="$(basename "${cwd}")"

branch=""
if [[ -n ${cwd} ]] && git -C "${cwd}" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "${cwd}" --no-optional-locks branch --show-current 2>/dev/null)"
  [[ -z ${branch} ]] && branch="$(git -C "${cwd}" --no-optional-locks rev-parse --short HEAD 2>/dev/null)"
  if [[ -n ${branch} ]] && [[ -n "$(git -C "${cwd}" --no-optional-locks status --porcelain 2>/dev/null)" ]]; then
    branch="${branch}*"
  fi
fi

# 数値でないときに printf がエラーを吐かないよう、確かめてから整形する
ctx=""
if [[ ${remaining} =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  ctx="$(printf '%.0f%% left' "${remaining}")"
fi

# cc-pages の会話のトップページへの入口。OSC 8 は ESC ]8;;<URL> BEL <文字> ESC ]8;; BEL
top=""
if [[ ${session_id} =~ ^[A-Za-z0-9-]+$ && -z ${CC_PAGES_DISABLE:-} ]] && type -P cc-pages &>/dev/null; then
  top=$'\033]8;;'"http://localhost:@ccPagesPort@/s/${session_id}/"$'\a'"${C_LINK}📄top${RESET}"$'\033]8;;\a'
fi

segments=()
[[ -n ${top} ]] && segments+=("${top}")
[[ -n ${model} ]] && segments+=("${C_MODEL}${model}${RESET}")
[[ -n ${dir_name} ]] && segments+=("${C_DIR}${dir_name}${RESET}")
[[ -n ${branch} ]] && segments+=("${C_BRANCH}${branch}${RESET}")
[[ -n ${ctx} ]] && segments+=("${C_CTX}${ctx}${RESET}")

sep="${C_SEP} · ${RESET}"

out=""
for i in "${!segments[@]}"; do
  if [[ ${i} -eq 0 ]]; then
    out="${segments[i]}"
  else
    out="${out}${sep}${segments[i]}"
  fi
done

printf '%s' "${out}"
