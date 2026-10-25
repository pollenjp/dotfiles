#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code on the web (cloud) の VM の ~/.claude/ に、dotfiles と claude-skills の Claude の設定を組み立てる。
# 冪等。環境の setup script から流す (nix/README.md「Claude Code on the web (cloud) で使う」)。
#
# 手元のマシンでは使わない。setup.sh は nix/scripts/ の直下の bootstrap-*.sh だけを手順にするので、claude-cloud/ の
# 中のこの script は手順に載らない (この dir には cloud でしか読まないものだけを置く)。
#
# ## なぜ要るのか
#
# cloud の session は毎回新しい VM で動き、手元の ~/.claude/ (home-manager が配る CLAUDE.md・skill の symlink・
# settings.json に登録した hook) は届かない。repo の .claude/settings.json の hook も、repo が 1 つの session でしか
# 読まれない。VM の ~/.claude/ に置いたものは読まれるので、setup script がそこへ組み立てる。経緯は ADR 034。
#
# ## 何をするか
#
#   1. dotfiles の nix/files/claude/{skills,agents,commands}/ と claude-skills の {skills,agents,commands}/ の中身を、
#      1 つずつ ~/.claude/<種類>/ へ symlink する (手元と同じ単位)。repo から消えたものの symlink は外す
#   2. ~/.claude/CLAUDE.md を書く。共通の nix/files/claude/CLAUDE.md の最初の「## 」の行より前 (手元の Nix 管理の
#      冒頭) を、この dir の CLAUDE.cloud.md に差し替える。--dev-tracker なら「タスク管理」の節を末尾に足す
#   3. ~/.local/state/dotfiles/claude-notion.json を書く (Notion の宛先の resolver が読む。profile は --notion-profile)
#   4. cloud で意味のある hook を ~/.claude/hooks/ へ張り、~/.claude/settings.json に登録する (下の「hook」)
#
# git の設定と settings.json の env (GIT_CONFIG_*・CLAUDE_CODE_SHELL) には触らない。cloud の git は GitHub proxy への
# 書き換えと commit の署名を GIT_CONFIG_* と ~/.gitconfig で設定していて、上書きすると壊れる。
#
# ## 張らない skill
#
#   - mod を兼ねるもの (dir に .claude-plugin/plugin.json がある)。mod の画面の hook は cloud で確かめていない
#   - この dir の skip-skills.txt に書いたもの (cloud に無いものを前提にするもの)
#   - pjp-dev-tracker (--dev-tracker のときだけ張る。手元の dotfiles.claude.devTracker.enable の既定 false に合わせる)
#
# ## 張り方
#
# 無ければ張る。張る先が同じなら何もしない。dotfiles か claude-skills の中を指す symlink と、切れた symlink は張り
# 直す。それ以外 (実体・ほかを指す symlink) は上書きせず警告して飛ばす。dotfiles と claude-skills に同じ名前があれば
# dotfiles を張る (手元で Nix 管理のものが先に在るときの bootstrap-claude-skills.sh と同じ)。
#
# ## hook
#
# 登録の形 (event・matcher・if) は bootstrap-claude-hook.sh と同じ。同じ組が在れば足さない。
#
#   PreToolUse   Bash                            xref-guard.sh
#   PostToolUse  Skill                           run-through-nudge.sh
#   PostToolUse  Bash (if "Bash(gh pr create *)")  video-offer-nudge.sh
#   PostToolUse  Write                           video-offer-nudge.sh
#   PreToolUse   Write|Edit|MultiEdit|NotebookEdit  docs-guard.sh
#   SessionStart startup|resume                  この script (--quiet と、今回と同じ option)
#
# nix-managed-guard.sh (cloud には Nix 管理のパスが無い) と ssh-agent-notice.sh (1Password の SSH agent が無い) は入れない。
# コマンドは「bash <パス>」にする。手元は home-manager が実行権限を付けた store の写しを登録するが、cloud の symlink は
# checkout を指し、git の上で実行権限の無い hook (xref-guard.sh) もあるため。
#
# SessionStart の登録は、snapshot を取ったあとに claude-skills に足した skill を張り、CLAUDE.md を repo の今の中身で
# 書き直すため (setup script は環境の snapshot を作るときにしか走らない)。SessionStart の stdout は Claude の文脈に入るので
# --quiet で流す。コマンドが「bash <この script>」で始まる登録を自分のものとみなし、option が変われば置き換える。
#
# ## 止まるとき
#
# 次のときは何も書かずに exit 1。警告だけなら exit 0 (setup script を止めない)。
#
#   - jq が無い・読むファイル (共通の CLAUDE.md など) が無い・共通の CLAUDE.md に「## 」の行が無い・知らない引数
#   - ~/.claude/CLAUDE.md が /nix/store を指す symlink (home-manager のマシン。手元で誤って流したとき)

set -eu -o pipefail

usage() {
  cat <<'EOS'
Claude Code on the web (cloud) の VM の ~/.claude/ に、dotfiles と claude-skills の Claude の設定を組み立てる。

使い方:
  bootstrap-claude-cloud.sh [--notion-profile <名前>] [--dev-tracker] [--claude-skills <dir>] [--dotfiles <dir>] [--quiet]
  bootstrap-claude-cloud.sh -h, --help   これ

  --notion-profile <名前>  claude-notion.json の profile (repo の外と、規則に当たらない repo の宛先)。無ければ null
  --dev-tracker            pjp-dev-tracker を張り、CLAUDE.md に「タスク管理」の節を足す
  --claude-skills <dir>    claude-skills の checkout (無ければ $CLAUDE_SKILLS_DIR、それも無ければ dotfiles の checkout の隣)
  --dotfiles <dir>         dotfiles の checkout (無ければ、この script の在る checkout)
  --quiet                  stdout に何も出さない (警告は stderr に出す)

環境の setup script から流す (repo の 1 つ上の dir から走る):
  bash dotfiles/nix/scripts/claude-cloud/bootstrap-claude-cloud.sh --notion-profile personal || true
EOS
}

quiet=0
note() {
  if [[ ${quiet} == 0 ]]; then
    printf '%s\n' "$*"
  fi
}

# 手順を止めない警告を出す。引数は 1 つが 1 行で、2 つ目からは字下げした続きの行になる。
# setup の外で流す script なので、まとめに残す summary_warn は持たない。
warn() {
  local IFS=$'\n' nl=$'\n' text
  text="$*"
  printf '!! %s\n' "${text//${nl}/${nl}   }" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

notion_profile=""
dev_tracker=0
claude_skills_arg=""
dotfiles_arg=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --notion-profile | --claude-skills | --dotfiles)
      [[ $# -ge 2 ]] || die "$1 に値を渡してください"
      case $1 in
        --notion-profile) notion_profile=$2 ;;
        --claude-skills) claude_skills_arg=$2 ;;
        --dotfiles) dotfiles_arg=$2 ;;
      esac
      shift 2
      ;;
    --dev-tracker)
      dev_tracker=1
      shift
      ;;
    --quiet)
      quiet=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "知らない引数です: $1"
      ;;
  esac
done

# ---- 場所 ----

self_dir=$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null
  pwd -P
)
self="${self_dir}/$(basename -- "${BASH_SOURCE[0]}")"
if [[ -n ${dotfiles_arg} ]]; then
  dotfiles_dir=$(cd -- "${dotfiles_arg}" &>/dev/null && pwd -P) || die "dotfiles の checkout がありません: ${dotfiles_arg}"
else
  # nix/scripts/claude-cloud/ -> checkout の root
  dotfiles_dir=$(cd -- "${self_dir}/../../.." && pwd -P)
fi
files="${dotfiles_dir}/nix/files/claude"
cloud="${dotfiles_dir}/nix/scripts/claude-cloud"

claude_skills_want=${claude_skills_arg:-${CLAUDE_SKILLS_DIR:-$(dirname -- "${dotfiles_dir}")/claude-skills}}
claude_skills_dir=""
if [[ -d ${claude_skills_want} ]]; then
  claude_skills_dir=$(cd -- "${claude_skills_want}" && pwd -P)
fi

# ---- 書く前に全部確かめる ----

command -v jq &>/dev/null || die "jq が見つかりません"
# cloud で意味のある hook (上の「hook」)
hooks=(xref-guard run-through-nudge video-offer-nudge docs-guard)
inputs=("${files}/CLAUDE.md" "${files}/CLAUDE.dev-tracker.md" "${cloud}/CLAUDE.cloud.md" "${cloud}/skip-skills.txt")
for hook in "${hooks[@]}"; do
  inputs+=("${files}/hooks/${hook}.sh")
done
for f in "${inputs[@]}"; do
  [[ -f ${f} ]] || die "読むファイルがありません: ${f}"
done
grep -q '^## ' "${files}/CLAUDE.md" \
  || die "${files}/CLAUDE.md に「## 」で始まる行がありません (その行より前を cloud の冒頭に差し替えるので、本文の頭に要ります)"
claude_md_link=$(readlink -- "${HOME}/.claude/CLAUDE.md" 2>/dev/null || true)
if [[ ${claude_md_link} == /nix/store/* ]]; then
  die "${HOME}/.claude/CLAUDE.md は home-manager が配ったもの (${claude_md_link}) です。cloud の VM 用の script なので、手元のマシンでは流しません"
fi

if [[ -z ${claude_skills_dir} ]]; then
  warn "claude-skills の checkout がありません: ${claude_skills_want}" \
    "dotfiles の分だけ張ります。環境の Repositories に claude-skills を足すか、--claude-skills で場所を渡してください。"
fi

# ---- skill・agent・command を張る ----

declare -A skip=()
while IFS= read -r line || [[ -n ${line} ]]; do
  line=${line%%#*}
  line=${line//[[:space:]]/}
  if [[ -n ${line} ]]; then
    skip["${line}"]=1
  fi
done <"${cloud}/skip-skills.txt"
if [[ ${dev_tracker} == 0 ]]; then
  skip["pjp-dev-tracker"]=1
fi

# managed_target <symlink の向き先>: dotfiles の nix/files/claude/ か claude-skills の中を指すか
managed_target() {
  [[ $1 == "${files}/"* ]] && return 0
  [[ -n ${claude_skills_dir} && $1 == "${claude_skills_dir}/"* ]]
}

# link_one <張る元> <置き場所>: 置き場所を張る元への symlink にする。張れた (同じだった) なら 0、飛ばしたら 1
link_one() {
  local src=$1 dest=$2 cur
  if [[ -L ${dest} ]]; then
    cur=$(readlink -- "${dest}")
    if [[ ${cur} == "${src}" ]]; then
      return 0
    fi
    if [[ -e ${dest} ]] && ! managed_target "${cur}"; then
      warn "${dest} は別の場所を指す symlink なので張りません (向き先: ${cur})"
      return 1
    fi
    ln -sfn -- "${src}" "${dest}"
    note "張り直しました: ${dest} -> ${src}"
    return 0
  fi
  if [[ -e ${dest} ]]; then
    warn "${dest} に実体があるので張りません (張る元: ${src})"
    return 1
  fi
  ln -s -- "${src}" "${dest}"
  note "張りました: ${dest} -> ${src}"
}

# link_entries <種類>: dotfiles と claude-skills の <種類>/ の中身を ~/.claude/<種類>/ へ張り、張った名前を wanted に控える
declare -A wanted=()
link_entries() {
  local kind=$1 root src name
  local -A seen=()
  mkdir -p -- "${HOME}/.claude/${kind}"
  for root in "${files}" ${claude_skills_dir:+"${claude_skills_dir}"}; do
    for src in "${root}/${kind}"/*; do
      [[ -e ${src} ]] || continue
      name=$(basename -- "${src}")
      [[ ${name} != README.md ]] || continue
      if [[ ${kind} == skills ]]; then
        [[ -z ${skip["${name}"]+x} ]] || continue
        [[ ! -f ${src}/.claude-plugin/plugin.json ]] || continue
      fi
      if [[ -n ${seen["${name}"]+x} ]]; then
        warn "${kind}/${name} は dotfiles にもあるので、${root} の方は張りません"
        continue
      fi
      seen["${name}"]=1
      if link_one "${src}" "${HOME}/.claude/${kind}/${name}"; then
        wanted["${kind}/${name}"]=1
      fi
    done
  done
}

# prune_links <種類>: ~/.claude/<種類>/ の symlink のうち、dotfiles か claude-skills の中を指し、今回張らなかったものを外す
prune_links() {
  local kind=$1 dest cur
  for dest in "${HOME}/.claude/${kind}"/*; do
    [[ -L ${dest} ]] || continue
    [[ -z ${wanted["${kind}/$(basename -- "${dest}")"]+x} ]] || continue
    cur=$(readlink -- "${dest}")
    managed_target "${cur}" || continue
    rm -f -- "${dest}"
    note "外しました: ${dest} (向き先: ${cur})"
  done
}

for kind in skills agents commands; do
  link_entries "${kind}"
  prune_links "${kind}"
done

# ---- ファイルを書く ----

# write_if_changed <パス>: stdin の中身が今のファイルと違えば (無ければ)、同じ dir の一時ファイルから置き換える。
# 書いたら 0、同じだったので書かなかったら 1
write_if_changed() {
  local path=$1 tmp
  mkdir -p -- "$(dirname -- "${path}")"
  tmp=$(mktemp "${path}.XXXXXX")
  cat >"${tmp}"
  if [[ -f ${path} && ! -L ${path} ]] && cmp -s -- "${tmp}" "${path}"; then
    rm -f -- "${tmp}"
    return 1
  fi
  if [[ -f ${path} && ! -L ${path} ]]; then
    chmod --reference="${path}" -- "${tmp}"
  else
    chmod 644 -- "${tmp}"
  fi
  mv -f -- "${tmp}" "${path}"
}

# cloud_claude_md: cloud の CLAUDE.md の中身を出す。cloud の冒頭 + 空行 + 共通の CLAUDE.md の最初の「## 」の行から末尾
# (+ --dev-tracker なら、手元と同じく空行と「タスク管理」の節)
cloud_claude_md() {
  cat -- "${cloud}/CLAUDE.cloud.md"
  printf '\n'
  awk 'found || /^## / { found = 1; print }' "${files}/CLAUDE.md"
  if [[ ${dev_tracker} == 1 ]]; then
    printf '\n'
    cat -- "${files}/CLAUDE.dev-tracker.md"
  fi
}
if cloud_claude_md | write_if_changed "${HOME}/.claude/CLAUDE.md"; then
  note "書きました: ${HOME}/.claude/CLAUDE.md"
fi

# home-manager (claude.nix) が書くものと同じ形 (キーの順に並べた 1 行)。profile が無ければ null
notion_json=$(jq -c -n --arg p "${notion_profile}" '{override: {}, profile: (if $p == "" then null else $p end), routes: {}}')
if printf '%s\n' "${notion_json}" | write_if_changed "${HOME}/.local/state/dotfiles/claude-notion.json"; then
  note "書きました: ${HOME}/.local/state/dotfiles/claude-notion.json"
fi

# ---- hook ----

mkdir -p -- "${HOME}/.claude/hooks"
for hook in "${hooks[@]}"; do
  link_one "${files}/hooks/${hook}.sh" "${HOME}/.claude/hooks/${hook}.sh" || true
done

# hook_cmd <名前>: 登録するコマンド (上の「hook」の通り「bash <パス>」)
hook_cmd() {
  printf 'bash %q' "${HOME}/.claude/hooks/$1.sh"
}

# SessionStart で流し直すコマンド。今回と同じ option を渡す。claude-skills と dotfiles の場所は、既定から決まったとき
# 以外だけ渡す (CLAUDE_SKILLS_DIR は SessionStart の環境に無いかもしれないので、決まった場所を渡す)
self_cmd="bash $(printf %q "${self}")"
session_cmd="${self_cmd} --quiet"
if [[ -n ${notion_profile} ]]; then
  session_cmd+=" --notion-profile $(printf %q "${notion_profile}")"
fi
if [[ ${dev_tracker} == 1 ]]; then
  session_cmd+=" --dev-tracker"
fi
if [[ -n ${claude_skills_arg} || -n ${CLAUDE_SKILLS_DIR:-} ]]; then
  if [[ -n ${claude_skills_dir} ]]; then
    session_cmd+=" --claude-skills $(printf %q "${claude_skills_dir}")"
  elif [[ ${claude_skills_want} == /* ]]; then
    session_cmd+=" --claude-skills $(printf %q "${claude_skills_want}")"
  else
    session_cmd+=" --claude-skills $(printf %q "${PWD}/${claude_skills_want}")"
  fi
fi
if [[ -n ${dotfiles_arg} ]]; then
  session_cmd+=" --dotfiles $(printf %q "${dotfiles_dir}")"
fi

# settings.json に足す。4 件は同じ組 (event・matcher・if・command) が在れば足さない。SessionStart は自分の登録
# (コマンドが $self で始まるもの) を外してから今の 1 件を末尾に足す
# shellcheck disable=SC2016 # jq の式の $ は jq の変数
hooks_filter='
  def add_hook($ev; $m; $cond; $c):
    .hooks[$ev] //= []
    | if any(.hooks[$ev][]; .matcher == $m and any((.hooks // [])[]; .command == $c and ((.["if"] // "") == $cond)))
      then .
      else .hooks[$ev] += [{matcher: $m, hooks: [{type: "command", command: $c} + (if $cond == "" then {} else {"if": $cond} end)]}]
      end;
  def mine: . == $self or startswith($self + " ");
  .hooks //= {}
  | add_hook("PreToolUse"; "Bash"; ""; $xref)
  | add_hook("PostToolUse"; "Skill"; ""; $run_through)
  | add_hook("PostToolUse"; "Bash"; "Bash(gh pr create *)"; $nudge)
  | add_hook("PostToolUse"; "Write"; ""; $nudge)
  | add_hook("PreToolUse"; "Write|Edit|MultiEdit|NotebookEdit"; ""; $docs_guard)
  | .hooks.SessionStart = (
      [(.hooks.SessionStart // [])[]
        | .hooks = [(.hooks // [])[] | select((.command // "") | mine | not)]
        | select(.hooks | length > 0)]
      + [{matcher: "startup|resume", hooks: [{type: "command", command: $session}]}]
    )
'
settings="${HOME}/.claude/settings.json"
current='{}'
if [[ -e ${settings} ]]; then
  current=$(cat -- "${settings}")
fi
if ! jq -e 'type == "object"' <<<"${current}" &>/dev/null \
  || ! new_settings=$(
    jq --arg xref "$(hook_cmd xref-guard)" --arg run_through "$(hook_cmd run-through-nudge)" \
      --arg nudge "$(hook_cmd video-offer-nudge)" --arg docs_guard "$(hook_cmd docs-guard)" \
      --arg self "${self_cmd}" --arg session "${session_cmd}" \
      "${hooks_filter}" <<<"${current}" 2>/dev/null
  ); then
  warn "${settings} が JSON のオブジェクトとして読めない (か hooks の形が違う) ので、hook を登録しません" \
    "直してから流し直してください。"
elif jq -e --argjson new "${new_settings}" '. == $new' <<<"${current}" &>/dev/null; then
  : # 登録済み
elif printf '%s\n' "${new_settings}" | write_if_changed "${settings}"; then
  note "登録しました: ${settings} の hooks"
fi
