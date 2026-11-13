#!/usr/bin/env bash
# shellcheck shell=bash
#
# Claude Code の PreToolUse フック (matcher Bash)。project を作り始めるコマンドと依存を足すコマンドを打つときに、読む skill を
# 1 文で Claude の文脈へ差し込む。止めない。
#
# 言語・道具ごとの好み (これでなく、これ) と tips の正本は、claude-skills の pack lang の skill (pjp-rust・pjp-go・pjp-node・
# pjp-python・pjp-ansible。一覧では名前だけ) と、依存を足す前に読む pjp-dep-release-age (dotfiles の skill) の側。ここは
# その瞬間を知らせるだけ (pr-assignee-nudge.sh と同じ考え)。設計は claude-skills の
# docs/superpowers/specs/2026-11-13-lang-prefs-pack-design.md の §3.6、dotfiles の分で決めたことは dotfiles-private の
# docs/superpowers/plans/2026-11-13-lang-prefs-pack-dotfiles.md。
#
# ## 知らせる場面
#
#   作り始め   cargo new・cargo init → pjp-rust、uv init → pjp-python、go mod init → pjp-go、npm init・pnpm init・npm create・
#              pnpm create → pjp-node、ansible-galaxy init (role init・collection init も) → pjp-ansible。
#              「<言語> の作業は、Skill tool で `pjp-<lang>` を名前を指して呼んでから進める」
#   依存を足す cargo add・uv add・pnpm add・引数のある npm install (npm i・npm add も)・go get・yarn add・bun add。
#              「依存を足す前に `pjp-dep-release-age` を読む」
#
# 両方あれば 2 つの文を 1 つの additionalContext に並べる。PreToolUse の additionalContext は tool の結果と一緒に Claude に
# 届くので、PostToolUse と同じ時に読まれ、コマンドの成否によらない (登録も 1 件で済む)。
#
# ## 黙る場面
#
#   - 名指しする skill を Claude が呼べないマシン: ${CLAUDE_CONFIG_DIR:-~/.claude}/skills/<名前>/SKILL.md が無い
#     (claude-skills を取れない)・user の settings.json の skillOverrides でその skill を off か user-invocable-only にした。
#     その skill の文だけを出さず、どの文も出さないなら黙る。name-only (pack の skill) は名前で呼べるので知らせる
#   - 当たるコマンドが無い (コマンドに書いただけのものも。下の「コマンドの読み方」)・Bash でない tool・PreToolUse でない
#     event・想定外の入力。tool の流れを止めないよう、何があっても exit 0 で終える
#
# ## コマンドの読み方
#
# 近似で読む (pr-assignee-nudge.sh と同じ。止める hook ほど細かく読まない)。heredoc の本文を外し、'…'・"…" を中身ごと
# 外し、\ の行の継ぎをつなぎ、; & | 改行 ( ) で単純コマンドに分ける。単純コマンドの頭の代入 (VAR=値) と包み (env・sudo・
# time・nohup・command・exec・nice・timeout <時間>・nix develop … -c・mise exec … --) を外した語の並びで決めるので、commit の
# message・echo の引数・コメントに書いただけでは知らせない。32 KB を超える入力は読まない (jq の gsub が長さの二乗で遅くなる。
# 作り始め・依存を足すコマンドは短い)。引用符の中にだけあるコマンド (bash -c '…') と、オプションの値を前に置いたもの
# (npm --prefix <dir> install …) は読み落とす。読み違えても、余分な 1 文か、1 文が出ないだけ。
#
# ## 登録
#
# scripts/bootstrap-claude-hook.sh が settings.json の hooks の PreToolUse に 1 件 (matcher Bash) 足す。

set -u -o pipefail

# 黙って抜ける場合も、先に stdin を読み切る (書き手の Claude Code を待たせない)
input=$(cat) || exit 0

# 当たる語を含まない入力は読まない (この hook は Bash のたびに走る)。cwd や transcript_path に当たらないよう、語の後ろの空白
# まで見る (ubuntu の bun などに当てない)
case ${input} in
  *'cargo '* | *'npm '* | *'yarn add'* | *'bun add'* | *ansible-galaxy* | *'uv init'* | *'uv add'* | *'go mod'* | *'go get'*) ;;
  *) exit 0 ;;
esac
# 長い入力は読まない。作り始め・依存を足すコマンドは短く、jq の gsub は長いコマンドで二乗の時間がかかる
((${#input} <= 32768)) || exit 0
command -v jq &>/dev/null || exit 0

config="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

# 名指しする skill が 1 つも無いマシン (claude-skills を取れず、dotfiles の pjp-dep-release-age も無い) では読まない
have_any=0
for s in pjp-rust pjp-go pjp-node pjp-python pjp-ansible pjp-dep-release-age; do
  if [[ -f ${config}/skills/${s}/SKILL.md ]]; then
    have_any=1
    break
  fi
done
((have_any)) || exit 0

# コマンドから、当たったものを 1 行ずつ出す (start:<言語>・dep)。上の「コマンドの読み方」
read -r -d '' parse <<'JQ' || true
# heredoc の本文 (<<EOF・<<'EOF'・<<"EOF"・<<-EOF の次の行から、終わりの印の行まで) を外す。<<< は heredoc と読まない
def strip_heredocs:
  reduce (split("\n")[]) as $line ({out: [], end: null, tabs: false};
    if .end != null then
      if (if .tabs then ($line | sub("^\t+"; "")) else $line end) == .end then .end = null else . end
    else
      .out += [$line]
      | (first($line | match("(?:^|[^<])<<(-?)[ \t]*(['\"]?)([^ \t;&|<>()'\"]+)\\2")) // null) as $m
      | if $m == null then . else .end = $m.captures[2].string | .tabs = ($m.captures[0].string == "-") end
    end)
  | .out | join("\n");
# '…'・"…" を中身ごと 1 語 (Q) にする
def strip_quotes: gsub("'[^']*'|\"(?:[^\"\\\\]|\\\\[\\s\\S])*\""; "Q");
def simple_commands: gsub("\\\\\n"; " ") | [splits("[;&|\n()]")];
def drop_flags: if length > 0 and (.[0] | startswith("-")) then .[1:] | drop_flags else . end;
# 頭の代入と包み (nix develop … -c <コマンド>・mise exec … -- <コマンド> も) を外す
def after($marks): (first(range(length) as $i | select(.[$i] | IN($marks[])) | $i) // null) as $i
  | if $i == null then [] else .[$i + 1:] end;
def lead:
  if length == 0 then .
  elif (.[0] | test("^[A-Za-z_][A-Za-z0-9_]*=")) then .[1:] | lead
  elif (.[0] | IN("env", "sudo", "doas", "time", "nohup", "command", "exec", "nice")) then .[1:] | drop_flags | lead
  elif .[0] == "timeout" then .[1:] | drop_flags | .[1:] | lead
  elif .[0] == "nix" and (.[1] | IN("develop", "shell")) then after(["-c", "--command"]) | lead
  elif .[0] == "mise" and (.[1] | IN("exec", "x")) then after(["--"]) | lead
  else . end;
def args: map(select((startswith("-") or startswith("+")) | not));
def hits:
  (.[0] | sub(".*/"; "")) as $c
  | (.[1:] | args) as $a
  | ($a[0] // "") as $s
  | if $c == "cargo" then
      if $s | IN("new", "init") then "start:rust" elif $s == "add" then "dep" else empty end
    elif $c == "uv" then
      if $s == "init" then "start:python" elif $s == "add" then "dep" else empty end
    elif $c == "go" then
      if $s == "mod" and $a[1] == "init" then "start:go" elif $s == "get" then "dep" else empty end
    elif $c == "npm" then
      if $s | IN("init", "create") then "start:node"
      elif ($s | IN("install", "i", "add", "in", "ins", "inst", "insta", "instal", "isnt", "isnta", "isntal", "isntall"))
        and ($a | length) > 1 then "dep"
      else empty end
    elif $c == "pnpm" then
      if $s | IN("init", "create") then "start:node" elif $s == "add" then "dep" else empty end
    elif $c | IN("yarn", "bun") then
      if $s == "add" then "dep" else empty end
    elif $c == "ansible-galaxy" then
      if $s == "init" or ($s | IN("role", "collection")) and $a[1] == "init" then "start:ansible" else empty end
    else empty end;
if .hook_event_name == "PreToolUse" and .tool_name == "Bash" and (.tool_input.command | type) == "string" then
  [.tool_input.command | strip_heredocs | strip_quotes | simple_commands[]
    | [splits("[ \t]+") | select(length > 0)] | lead | select(length > 0) | hits]
  | unique[]
else empty end
JQ
# コマンドは入力の JSON から読む (--arg で渡すと、128 KB を超える 1 つの引数で exec が落ちる)
found=$(jq -r "${parse}" <<<"${input}" 2>/dev/null) || exit 0
[[ -n ${found} ]] || exit 0

# usable <skill の名前>: Claude がその skill を呼べるか (上の「黙る場面」)。settings.json は当たったときだけ読む
off_skills=""
if [[ -f ${config}/settings.json ]]; then
  off_skills=$(jq -r '.skillOverrides | objects | to_entries[]
    | select(.value == "off" or .value == "user-invocable-only") | .key' "${config}/settings.json" 2>/dev/null) || off_skills=""
fi
usable() {
  [[ -f ${config}/skills/$1/SKILL.md ]] || return 1
  [[ $'\n'${off_skills}$'\n' != *$'\n'"$1"$'\n'* ]]
}

msgs=()
while IFS= read -r hit; do
  case ${hit} in
    start:*)
      lang=${hit#start:}
      case ${lang} in
        rust) label=Rust ;;
        python) label=Python ;;
        go) label=Go ;;
        node) label=Node.js ;;
        ansible) label=Ansible ;;
        *) continue ;;
      esac
      usable "pjp-${lang}" || continue
      msgs+=("[言語の skill] ${label} の作業は、Skill tool で \`pjp-${lang}\` を名前を指して呼んでから進める (一覧では名前だけ。repo に道具・設定の決まり (lockfile・CLAUDE.md・.claude/rules) があれば、そちらが先)。")
      ;;
    dep)
      usable pjp-dep-release-age || continue
      msgs+=("[依存を足す] 依存を足す前に \`pjp-dep-release-age\` を読む (公開から日の浅い版を入れない決まりと、パッケージマネージャごとの設定)。")
      ;;
  esac
done <<<"${found}"
((${#msgs[@]} > 0)) || exit 0

msg=$(printf '%s\n' "${msgs[@]}")
jq -cn --arg msg "${msg}" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $msg}}' || true
exit 0
