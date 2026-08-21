#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の statusLine。1 行を stdout へ出す。
#
#   <model> · <dir basename> · <git branch>[*] · <context% left>
#
# shell prompt (starship) が既に出しているもの (時刻・user@host・フルパス) は
# 意図的に繰り返さない。Claude Code 側で薄く描画されるので色も控えめにする。
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

# process substitution の中の jq がこのスクリプトの stdin をそのまま読む。
# @tsv は値の中のタブ・改行をエスケープするので、read の分割は壊れない。
model=""
cwd=""
remaining=""
IFS=$'\t' read -r model cwd remaining < <(
  jq -r '[
    .model.display_name // "",
    .workspace.current_dir // .cwd // "",
    (.context_window.remaining_percentage // "" | tostring)
  ] | @tsv' 2>/dev/null
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

segments=()
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
