#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/claude-cloud/bootstrap-claude-cloud.sh の振る舞いを、使い捨ての HOME で確かめる。
#
#   bash nix/tests/bootstrap-claude-cloud.test.sh [<nix/scripts/claude-cloud のパス> [<nix/files/claude のパス>]]
#
# flake の checks (bootstrap-claude-cloud-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils だけ。
# script は自分の在る checkout を dotfiles とみなすので、渡された 2 つを使い捨ての checkout (空白を含む「dot files」)
# の nix/ の下へ写し、そこの script を流す。共通の CLAUDE.md・hook・skill は本物を使い、claude-skills は偽物を作る。
#
# ## 確かめること
#
#   - dotfiles と claude-skills の skill・agent を ~/.claude/<種類>/<名前> へ張り (向き先も見る)、README.md は張らない
#   - mod を兼ねる skill (.claude-plugin/plugin.json がある) と skip-skills.txt の名前 (dotfiles の pjp-dotfiles-update・
#     claude-skills の pjp-cc-page) は張らない
#   - pjp-dev-tracker と CLAUDE.md の「## タスク管理」の節は --dev-tracker のときだけ。外して流し直すと symlink を外す
#   - dotfiles と claude-skills に同じ名前があれば dotfiles を張り、警告に名前を出す
#   - 実体とほかを指す symlink は上書きせず警告する。切れた symlink は張り直す
#   - 流し直すと、repo から消えた skill の symlink を外し、足した skill を張る。ほかを指す symlink と実体は残す
#   - CLAUDE.md は CLAUDE.cloud.md で始まり、本物の CLAUDE.md の最初の「## 」の行から末尾までが続く。cloud に無い
#     nix-managed-guard.sh には触れない
#   - claude-notion.json に --notion-profile の値を書く (無ければ profile は null)
#   - 同じ option で流し直すと CLAUDE.md・claude-notion.json を書き直さない (inode が変わらない)
#   - claude-skills が無ければ dotfiles の分だけ張り、警告して 0 で終わる
#   - claude-skills の場所は --claude-skills > CLAUDE_SKILLS_DIR > dotfiles の checkout の隣
#   - --quiet は stdout に何も出さない
#   - ~/.claude/CLAUDE.md が /nix/store を指す symlink (home-manager のマシン)・共通の CLAUDE.md に「## 」の行が無い・
#     知らない引数のときは、何も書かずに 1 で終わる。--help は 0
#   - xref-guard・run-through-nudge・video-offer-nudge・docs-guard を ~/.claude/hooks/ へ張り、settings.json に
#     「bash <パス>」で 5 件登録する。nix-managed-guard・ssh-agent-notice は張らない
#   - SessionStart に自分を --quiet と同じ option で 1 件だけ登録し、option を変えて流し直すと置き換える。手で足した hook と
#     ほかのキーは残し、同じ option なら settings.json を書き直さない
#   - settings.json が壊れていれば触らずに警告し、ほかは進めて 0 で終わる

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
cloud_src=${1:-${here}/../scripts/claude-cloud}
files_src=${2:-${here}/../files/claude}
work=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-claude-cloud-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "  ok   $1"
}
ng() {
  fail=$((fail + 1))
  echo "  FAIL $1"
  if [[ -n ${2:-} ]]; then
    echo "       ${2//$'\n'/$'\n'       }"
  fi
}

# new_dotfiles <dir>: 使い捨ての dotfiles の checkout を作る (store から写したものは読み取り専用なので書けるようにする)
new_dotfiles() {
  mkdir -p "$1/nix/scripts" "$1/nix/files"
  cp -R "${cloud_src}" "$1/nix/scripts/claude-cloud"
  cp -R "${files_src}" "$1/nix/files/claude"
  chmod -R u+w "$1"
}

# new_skills <dir> <skill の名前…>: 偽の claude-skills を作る。agents/ に pjp-fake-agent.md、各種類に README.md を置く
new_skills() {
  local d=$1 s
  shift
  mkdir -p "${d}/skills" "${d}/agents" "${d}/commands"
  for s in "$@"; do
    mkdir -p "${d}/skills/${s}"
    printf -- '---\nname: %s\ndescription: x\n---\n' "${s}" >"${d}/skills/${s}/SKILL.md"
  done
  printf '# skills\n' >"${d}/skills/README.md"
  printf '# agents\n' >"${d}/agents/README.md"
  printf -- '---\nname: pjp-fake-agent\ndescription: x\n---\n' >"${d}/agents/pjp-fake-agent.md"
  printf '# commands\n' >"${d}/commands/README.md"
}

dot="${work}/dot files"
new_dotfiles "${dot}"
dot_p=$(cd -- "${dot}" && pwd -P)
script="${dot}/nix/scripts/claude-cloud/bootstrap-claude-cloud.sh"
claude_md="${dot}/nix/files/claude/CLAUDE.md"
cloud_md="${dot}/nix/scripts/claude-cloud/CLAUDE.cloud.md"
tracker_md="${dot}/nix/files/claude/CLAUDE.dev-tracker.md"

# dotfiles の checkout の隣 (既定の場所) に、偽の claude-skills を置く
sk="${work}/claude-skills"
new_skills "${sk}" pjp-fake-one pjp-fake-mod pjp-cc-page pjp-dev-tracker pjp-nix-flake
mkdir -p "${sk}/skills/pjp-fake-mod/.claude-plugin"
printf '{"name":"pjp-fake-mod"}\n' >"${sk}/skills/pjp-fake-mod/.claude-plugin/plugin.json"
sk_p=$(cd -- "${sk}" && pwd -P)

# case_home <名前>: そのケースの HOME を作って出す
case_home() {
  mkdir -p "${work}/$1/home"
  printf '%s' "${work}/$1/home"
}
# run_case <名前> <script の引数…>: HOME を <work>/<名前>/home にして流し、out・err・rc を <work>/<名前>/ に残す。
# 手元の CLAUDE_SKILLS_DIR は外す。足すときは case_env (VAR=値 の配列) に入れる。流す script は run_script で替えられる
case_env=()
run_script=${script}
run_case() {
  local c="${work}/$1"
  shift
  mkdir -p "${c}/home"
  env -u CLAUDE_SKILLS_DIR "${case_env[@]}" HOME="${c}/home" bash "${run_script}" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}
rc_of() { cat "${work}/$1/rc"; }
err_of() { cat "${work}/$1/err"; }
# link_to <symlink> <向き先>: symlink で、向き先がそれか
link_to() {
  [[ -L $1 && $(readlink -- "$1") == "$2" ]]
}
# untouched <HOME>: 何も書いていないか (HOME の下に何も無いか)
untouched() {
  [[ -z $(find "$1" -mindepth 1 -print -quit) ]]
}

echo "== bootstrap-claude-cloud.sh"

# 1. 初回: dotfiles と claude-skills の中身を張る
h=$(case_home t1)
run_case t1 --notion-profile personal --claude-skills "${sk}"
if [[ $(rc_of t1) == 0 ]] \
  && link_to "${h}/.claude/skills/pjp-d3js" "${dot_p}/nix/files/claude/skills/pjp-d3js" \
  && link_to "${h}/.claude/skills/pjp-fake-one" "${sk_p}/skills/pjp-fake-one" \
  && link_to "${h}/.claude/agents/pjp-fake-agent.md" "${sk_p}/agents/pjp-fake-agent.md" \
  && [[ ! -e ${h}/.claude/skills/README.md && ! -e ${h}/.claude/agents/README.md && ! -e ${h}/.claude/commands/README.md ]]; then
  ok "dotfiles と claude-skills の skill・agent を張り、README.md は張らない"
else
  ng "dotfiles と claude-skills の skill・agent を張り、README.md は張らない" "rc=$(rc_of t1) $(ls -la "${h}/.claude/skills" 2>&1) $(err_of t1)"
fi

if [[ $(rc_of t1) == 0 && -L ${h}/.claude/skills/pjp-fake-one ]] \
  && [[ ! -e ${h}/.claude/skills/pjp-fake-mod && ! -L ${h}/.claude/skills/pjp-fake-mod ]] \
  && [[ ! -e ${h}/.claude/skills/pjp-cc-page && ! -L ${h}/.claude/skills/pjp-cc-page ]] \
  && [[ ! -e ${h}/.claude/skills/pjp-dotfiles-update && ! -L ${h}/.claude/skills/pjp-dotfiles-update ]]; then
  ok "mod と skip-skills.txt の skill は張らない"
else
  ng "mod と skip-skills.txt の skill は張らない" "$(ls -la "${h}/.claude/skills" 2>&1)"
fi

if link_to "${h}/.claude/skills/pjp-nix-flake" "${dot_p}/nix/files/claude/skills/pjp-nix-flake" \
  && grep -q -F 'pjp-nix-flake' "${work}/t1/err"; then
  ok "dotfiles と claude-skills の同じ名前は dotfiles を張り、警告に名前を出す"
else
  ng "dotfiles と claude-skills の同じ名前は dotfiles を張り、警告に名前を出す" "$(readlink "${h}/.claude/skills/pjp-nix-flake") $(err_of t1)"
fi

if [[ -f ${h}/.claude/CLAUDE.md ]] \
  && [[ ! -e ${h}/.claude/skills/pjp-dev-tracker && ! -L ${h}/.claude/skills/pjp-dev-tracker ]] \
  && ! grep -q '^## タスク管理' "${h}/.claude/CLAUDE.md"; then
  ok "--dev-tracker が無ければ pjp-dev-tracker も「タスク管理」の節も入れない"
else
  ng "--dev-tracker が無ければ pjp-dev-tracker も「タスク管理」の節も入れない"
fi

# CLAUDE.md は cloud の冒頭 + 空行 + 共通の CLAUDE.md の最初の「## 」から末尾
{
  cat "${cloud_md}"
  printf '\n'
  sed -n '/^## /,$p' "${claude_md}"
} >"${work}/t1-want.md"
if cmp -s "${h}/.claude/CLAUDE.md" "${work}/t1-want.md" \
  && grep -q '^## 応答の言語' "${h}/.claude/CLAUDE.md" \
  && ! grep -q -F 'nix-managed-guard.sh' "${h}/.claude/CLAUDE.md"; then
  ok "CLAUDE.md は cloud の冒頭のあとに共通の本文を続け、nix-managed-guard.sh に触れない"
else
  ng "CLAUDE.md は cloud の冒頭のあとに共通の本文を続け、nix-managed-guard.sh に触れない" "$(diff "${work}/t1-want.md" "${h}/.claude/CLAUDE.md" 2>&1 | head -20)"
fi

if [[ $(jq -c -S . "${h}/.local/state/dotfiles/claude-notion.json" 2>&1) == '{"override":{},"profile":"personal","routes":{}}' ]]; then
  ok "claude-notion.json に --notion-profile の値を書く"
else
  ng "claude-notion.json に --notion-profile の値を書く" "$(cat "${h}/.local/state/dotfiles/claude-notion.json" 2>&1)"
fi

# 2. 同じ option で流し直す → CLAUDE.md・claude-notion.json を書き直さない
ino_md=$(stat -c %i "${h}/.claude/CLAUDE.md")
ino_notion=$(stat -c %i "${h}/.local/state/dotfiles/claude-notion.json")
run_case t1 --notion-profile personal --claude-skills "${sk}"
if [[ $(rc_of t1) == 0 ]] \
  && [[ $(stat -c %i "${h}/.claude/CLAUDE.md") == "${ino_md}" ]] \
  && [[ $(stat -c %i "${h}/.local/state/dotfiles/claude-notion.json") == "${ino_notion}" ]]; then
  ok "同じ option で流し直すと CLAUDE.md・claude-notion.json を書き直さない"
else
  ng "同じ option で流し直すと CLAUDE.md・claude-notion.json を書き直さない" "rc=$(rc_of t1) $(err_of t1)"
fi

# 3. --dev-tracker のときだけ入れ、外して流し直すと外す
h=$(case_home t3)
run_case t3 --dev-tracker --claude-skills "${sk}"
{
  cat "${work}/t1-want.md"
  printf '\n'
  cat "${tracker_md}"
} >"${work}/t3-want.md"
if [[ $(rc_of t3) == 0 ]] \
  && link_to "${h}/.claude/skills/pjp-dev-tracker" "${sk_p}/skills/pjp-dev-tracker" \
  && cmp -s "${h}/.claude/CLAUDE.md" "${work}/t3-want.md"; then
  ok "--dev-tracker なら pjp-dev-tracker を張り、CLAUDE.md の末尾に「タスク管理」の節を足す"
else
  ng "--dev-tracker なら pjp-dev-tracker を張り、CLAUDE.md の末尾に「タスク管理」の節を足す" "rc=$(rc_of t3) $(diff "${work}/t3-want.md" "${h}/.claude/CLAUDE.md" 2>&1 | head -10)"
fi
if [[ $(jq -r '.profile' "${h}/.local/state/dotfiles/claude-notion.json" 2>&1) == null ]]; then
  ok "--notion-profile が無ければ claude-notion.json の profile は null"
else
  ng "--notion-profile が無ければ claude-notion.json の profile は null" "$(cat "${h}/.local/state/dotfiles/claude-notion.json" 2>&1)"
fi
run_case t3 --claude-skills "${sk}"
if [[ $(rc_of t3) == 0 ]] \
  && [[ ! -e ${h}/.claude/skills/pjp-dev-tracker && ! -L ${h}/.claude/skills/pjp-dev-tracker ]] \
  && cmp -s "${h}/.claude/CLAUDE.md" "${work}/t1-want.md"; then
  ok "--dev-tracker を外して流し直すと pjp-dev-tracker の symlink と「タスク管理」の節を外す"
else
  ng "--dev-tracker を外して流し直すと pjp-dev-tracker の symlink と「タスク管理」の節を外す" "rc=$(rc_of t3) $(ls -la "${h}/.claude/skills" 2>&1)"
fi

# 4. 実体・ほかを指す symlink は残して警告し、切れた symlink は張り直す
h=$(case_home t4)
mkdir -p "${h}/.claude/skills/pjp-fake-one" "${work}/elsewhere/pjp-d3js"
printf 'mine\n' >"${h}/.claude/skills/pjp-fake-one/SKILL.md"
ln -s "${work}/elsewhere/pjp-d3js" "${h}/.claude/skills/pjp-d3js"
ln -s "${work}/gone/pjp-plantuml" "${h}/.claude/skills/pjp-plantuml"
run_case t4 --claude-skills "${sk}"
if [[ $(rc_of t4) == 0 ]] \
  && [[ ! -L ${h}/.claude/skills/pjp-fake-one && $(cat "${h}/.claude/skills/pjp-fake-one/SKILL.md") == mine ]] \
  && link_to "${h}/.claude/skills/pjp-d3js" "${work}/elsewhere/pjp-d3js" \
  && grep -q -F 'pjp-fake-one' "${work}/t4/err" && grep -q -F 'pjp-d3js' "${work}/t4/err"; then
  ok "実体とほかを指す symlink は上書きせず警告する"
else
  ng "実体とほかを指す symlink は上書きせず警告する" "rc=$(rc_of t4) $(err_of t4)"
fi
if link_to "${h}/.claude/skills/pjp-plantuml" "${dot_p}/nix/files/claude/skills/pjp-plantuml"; then
  ok "切れた symlink は張り直す"
else
  ng "切れた symlink は張り直す" "$(readlink "${h}/.claude/skills/pjp-plantuml")"
fi

# 5. 流し直すと、消えた skill の symlink を外し、足した skill を張る。ほかを指す symlink と実体は残す
sk5="${work}/skills-t5"
new_skills "${sk5}" pjp-fake-one pjp-fake-two
sk5_p=$(cd -- "${sk5}" && pwd -P)
h=$(case_home t5)
run_case t5 --claude-skills "${sk5}"
mkdir -p "${h}/.claude/skills/real-dir" "${work}/elsewhere/other-tool"
ln -s "${work}/elsewhere/other-tool" "${h}/.claude/skills/other-tool"
rm -rf "${sk5}/skills/pjp-fake-two"
mkdir -p "${sk5}/skills/pjp-fake-three"
printf -- '---\nname: pjp-fake-three\ndescription: x\n---\n' >"${sk5}/skills/pjp-fake-three/SKILL.md"
run_case t5 --claude-skills "${sk5}"
if [[ $(rc_of t5) == 0 ]] \
  && [[ ! -e ${h}/.claude/skills/pjp-fake-two && ! -L ${h}/.claude/skills/pjp-fake-two ]] \
  && link_to "${h}/.claude/skills/pjp-fake-three" "${sk5_p}/skills/pjp-fake-three" \
  && link_to "${h}/.claude/skills/pjp-fake-one" "${sk5_p}/skills/pjp-fake-one" \
  && link_to "${h}/.claude/skills/other-tool" "${work}/elsewhere/other-tool" \
  && [[ -d ${h}/.claude/skills/real-dir && ! -L ${h}/.claude/skills/real-dir ]]; then
  ok "流し直すと消えた skill の symlink を外して足した skill を張り、ほかの symlink と実体は残す"
else
  ng "流し直すと消えた skill の symlink を外して足した skill を張り、ほかの symlink と実体は残す" "rc=$(rc_of t5) $(ls -la "${h}/.claude/skills" 2>&1)"
fi

# 6. claude-skills が無い → dotfiles の分だけ張り、警告して 0
h=$(case_home t6)
run_case t6 --claude-skills "${work}/no-such-skills"
if [[ $(rc_of t6) == 0 ]] \
  && link_to "${h}/.claude/skills/pjp-d3js" "${dot_p}/nix/files/claude/skills/pjp-d3js" \
  && [[ ! -e ${h}/.claude/skills/pjp-fake-one ]] \
  && grep -q -F "${work}/no-such-skills" "${work}/t6/err"; then
  ok "claude-skills が無ければ dotfiles の分だけ張り、警告して 0 で終わる"
else
  ng "claude-skills が無ければ dotfiles の分だけ張り、警告して 0 で終わる" "rc=$(rc_of t6) $(err_of t6)"
fi

# 7. claude-skills の場所の決まり方
new_skills "${work}/env-skills" pjp-fake-env
new_skills "${work}/arg-skills" pjp-fake-arg
h=$(case_home t7a)
run_case t7a
if [[ $(rc_of t7a) == 0 ]] && link_to "${h}/.claude/skills/pjp-fake-one" "${sk_p}/skills/pjp-fake-one"; then
  ok "--claude-skills も CLAUDE_SKILLS_DIR も無ければ、dotfiles の checkout の隣の claude-skills を使う"
else
  ng "--claude-skills も CLAUDE_SKILLS_DIR も無ければ、dotfiles の checkout の隣の claude-skills を使う" "rc=$(rc_of t7a) $(err_of t7a)"
fi
h=$(case_home t7b)
case_env=(CLAUDE_SKILLS_DIR="${work}/env-skills")
run_case t7b
if [[ $(rc_of t7b) == 0 ]] && [[ -L ${h}/.claude/skills/pjp-fake-env && ! -e ${h}/.claude/skills/pjp-fake-one ]]; then
  ok "--claude-skills が無ければ CLAUDE_SKILLS_DIR を使う"
else
  ng "--claude-skills が無ければ CLAUDE_SKILLS_DIR を使う" "rc=$(rc_of t7b) $(ls "${h}/.claude/skills" 2>&1)"
fi
h=$(case_home t7c)
run_case t7c --claude-skills "${work}/arg-skills"
case_env=()
if [[ $(rc_of t7c) == 0 ]] && [[ -L ${h}/.claude/skills/pjp-fake-arg && ! -e ${h}/.claude/skills/pjp-fake-env ]]; then
  ok "--claude-skills は CLAUDE_SKILLS_DIR より先に効く"
else
  ng "--claude-skills は CLAUDE_SKILLS_DIR より先に効く" "rc=$(rc_of t7c) $(ls "${h}/.claude/skills" 2>&1)"
fi

# 8. --quiet は stdout に何も出さない
case_home t8 >/dev/null
run_case t8 --quiet --claude-skills "${sk}"
if [[ $(rc_of t8) == 0 && ! -s ${work}/t8/out ]]; then
  ok "--quiet は stdout に何も出さない"
else
  ng "--quiet は stdout に何も出さない" "rc=$(rc_of t8) out=$(cat "${work}/t8/out")"
fi

# 9. ~/.claude/CLAUDE.md が /nix/store を指す symlink (home-manager のマシン) → 何も書かずに 1
h=$(case_home t9)
mkdir -p "${h}/.claude"
ln -s /nix/store/00000000000000000000000000000000-home-manager-files/.claude/CLAUDE.md "${h}/.claude/CLAUDE.md"
run_case t9 --claude-skills "${sk}"
if [[ $(rc_of t9) == 1 ]] \
  && [[ -z $(find "${h}" -mindepth 1 ! -path "${h}/.claude" ! -path "${h}/.claude/CLAUDE.md" -print -quit) ]] \
  && [[ $(readlink "${h}/.claude/CLAUDE.md") == /nix/store/* ]]; then
  ok "HOME の .claude/CLAUDE.md が /nix/store を指す symlink なら、何も書かずに 1 で終わる"
else
  ng "HOME の .claude/CLAUDE.md が /nix/store を指す symlink なら、何も書かずに 1 で終わる" "rc=$(rc_of t9) $(find "${h}" 2>&1)"
fi

# 10. 共通の CLAUDE.md に「## 」の行が無い → 何も書かずに 1
broken="${work}/broken dot"
new_dotfiles "${broken}"
printf '# ユーザーレベルの指示\n\n見出しの無い本文\n' >"${broken}/nix/files/claude/CLAUDE.md"
h=$(case_home t10)
run_script="${broken}/nix/scripts/claude-cloud/bootstrap-claude-cloud.sh"
run_case t10 --claude-skills "${sk}"
run_script=${script}
if [[ $(rc_of t10) == 1 ]] && untouched "${h}"; then
  ok "共通の CLAUDE.md に「## 」の行が無ければ、何も書かずに 1 で終わる"
else
  ng "共通の CLAUDE.md に「## 」の行が無ければ、何も書かずに 1 で終わる" "rc=$(rc_of t10) $(find "${h}" 2>&1)"
fi

# 11. 知らない引数 → 何も書かずに 1。--help は 0
h=$(case_home t11)
run_case t11 --bogus
if [[ $(rc_of t11) == 1 ]] && untouched "${h}"; then
  ok "知らない引数は、何も書かずに 1 で終わる"
else
  ng "知らない引数は、何も書かずに 1 で終わる" "rc=$(rc_of t11) $(err_of t11)"
fi
h=$(case_home t12)
run_case t12 --help
if [[ $(rc_of t12) == 0 ]] && grep -q -F 'bootstrap-claude-cloud.sh' "${work}/t12/out" && untouched "${h}"; then
  ok "--help は使い方を出して 0 で終わる"
else
  ng "--help は使い方を出して 0 で終わる" "rc=$(rc_of t12) $(cat "${work}/t12/out")"
fi

# ---- hook ----

self_cmd="bash $(printf %q "${dot_p}/nix/scripts/claude-cloud/bootstrap-claude-cloud.sh")"
# hook_count <settings.json> <event> <matcher> <if (空なら無し)> <command>: その組の登録の数
hook_count() {
  jq --arg ev "$2" --arg m "$3" --arg cond "$4" --arg c "$5" \
    '[.hooks[$ev] // [] | .[] | select(.matcher == $m) | .hooks // [] | .[] | select(.command == $c and ((.["if"] // "") == $cond))] | length' "$1"
}
# hook_cmd <HOME> <名前>: 登録する hook のコマンド
hook_cmd() {
  printf 'bash %q' "$1/.claude/hooks/$2.sh"
}

# 13. 4 つの hook を張って登録し、SessionStart に自分を --quiet で登録する
h=$(case_home t13)
run_case t13 --notion-profile personal
settings="${h}/.claude/settings.json"
if [[ $(rc_of t13) == 0 ]] \
  && link_to "${h}/.claude/hooks/xref-guard.sh" "${dot_p}/nix/files/claude/hooks/xref-guard.sh" \
  && link_to "${h}/.claude/hooks/run-through-nudge.sh" "${dot_p}/nix/files/claude/hooks/run-through-nudge.sh" \
  && link_to "${h}/.claude/hooks/video-offer-nudge.sh" "${dot_p}/nix/files/claude/hooks/video-offer-nudge.sh" \
  && link_to "${h}/.claude/hooks/docs-guard.sh" "${dot_p}/nix/files/claude/hooks/docs-guard.sh" \
  && [[ ! -e ${h}/.claude/hooks/nix-managed-guard.sh && ! -e ${h}/.claude/hooks/ssh-agent-notice.sh ]]; then
  ok "xref-guard・run-through-nudge・video-offer-nudge・docs-guard を張り、nix-managed-guard・ssh-agent-notice は張らない"
else
  ng "xref-guard・run-through-nudge・video-offer-nudge・docs-guard を張り、nix-managed-guard・ssh-agent-notice は張らない" "rc=$(rc_of t13) $(ls -la "${h}/.claude/hooks" 2>&1) $(err_of t13)"
fi
if [[ $(hook_count "${settings}" PreToolUse Bash '' "$(hook_cmd "${h}" xref-guard)") == 1 ]] \
  && [[ $(hook_count "${settings}" PostToolUse Skill '' "$(hook_cmd "${h}" run-through-nudge)") == 1 ]] \
  && [[ $(hook_count "${settings}" PostToolUse Bash 'Bash(gh pr create *)' "$(hook_cmd "${h}" video-offer-nudge)") == 1 ]] \
  && [[ $(hook_count "${settings}" PostToolUse Write '' "$(hook_cmd "${h}" video-offer-nudge)") == 1 ]] \
  && [[ $(hook_count "${settings}" PreToolUse 'Write|Edit|MultiEdit|NotebookEdit' '' "$(hook_cmd "${h}" docs-guard)") == 1 ]] \
  && [[ $(hook_count "${settings}" SessionStart 'startup|resume' '' "${self_cmd} --quiet --notion-profile personal") == 1 ]] \
  && [[ $(jq '[.hooks[] | .[] | .hooks[]] | length' "${settings}") == 6 ]]; then
  ok "settings.json に 5 件の hook と、SessionStart の自分の 1 件を登録する"
else
  ng "settings.json に 5 件の hook と、SessionStart の自分の 1 件を登録する" "$(cat "${settings}" 2>&1)"
fi

# 14. 同じ option で流し直す → settings.json を書き直さない
ino_settings=$(stat -c %i "${settings}" 2>/dev/null)
run_case t13 --notion-profile personal
if [[ $(rc_of t13) == 0 && -n ${ino_settings} && $(stat -c %i "${settings}") == "${ino_settings}" ]]; then
  ok "同じ option で流し直すと settings.json を書き直さない"
else
  ng "同じ option で流し直すと settings.json を書き直さない" "rc=$(rc_of t13) $(err_of t13)"
fi

# 15. option を変えて流し直す → SessionStart の自分の登録は新しい 1 件だけ。手で足した hook とほかのキーは残す
jq '.model = "opus"
  | .hooks.SessionStart += [{matcher: "startup", hooks: [{type: "command", command: "other-start"}]}]
  | .hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: "other-pre"}]}]' \
  "${settings}" >"${work}/t13-settings.json"
cp "${work}/t13-settings.json" "${settings}"
run_case t13 --notion-profile work --dev-tracker
if [[ $(rc_of t13) == 0 ]] \
  && [[ $(hook_count "${settings}" SessionStart 'startup|resume' '' "${self_cmd} --quiet --notion-profile work --dev-tracker") == 1 ]] \
  && [[ $(jq --arg s "${self_cmd}" '[.hooks.SessionStart[] | .hooks[] | select(.command | startswith($s))] | length' "${settings}") == 1 ]] \
  && [[ $(hook_count "${settings}" SessionStart startup '' other-start) == 1 ]] \
  && [[ $(hook_count "${settings}" PreToolUse Bash '' other-pre) == 1 ]] \
  && [[ $(hook_count "${settings}" PreToolUse Bash '' "$(hook_cmd "${h}" xref-guard)") == 1 ]] \
  && [[ $(jq -r '.model' "${settings}") == opus ]]; then
  ok "option を変えて流し直すと SessionStart の自分の登録を置き換え、手で足した hook とほかのキーは残す"
else
  ng "option を変えて流し直すと SessionStart の自分の登録を置き換え、手で足した hook とほかのキーは残す" "$(cat "${settings}" 2>&1)"
fi

# 16. settings.json が壊れている → そのファイルは変えずに警告し、ほかは進めて 0
h=$(case_home t16)
mkdir -p "${h}/.claude"
printf '{"hooks": ' >"${h}/.claude/settings.json"
run_case t16 --claude-skills "${sk}"
if [[ $(rc_of t16) == 0 ]] \
  && [[ $(cat "${h}/.claude/settings.json") == '{"hooks": ' ]] \
  && grep -q -F 'settings.json' "${work}/t16/err" \
  && [[ -f ${h}/.claude/CLAUDE.md && -L ${h}/.claude/skills/pjp-fake-one ]]; then
  ok "settings.json が壊れていれば触らずに警告し、skill と CLAUDE.md は書いて 0 で終わる"
else
  ng "settings.json が壊れていれば触らずに警告し、skill と CLAUDE.md は書いて 0 で終わる" "rc=$(rc_of t16) $(err_of t16)"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
