#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016 # 文の中の inline code (`pjp-rust` など) を、引用符の中で文字のまま探す
#
# nix/files/claude/hooks/lang-nudge.sh の振る舞いを、合成した PreToolUse の入力で確かめる。
#
#   bash nix/tests/lang-nudge.test.sh [<lang-nudge.sh のパス>]
#
# flake の checks (lang-nudge-test) が Nix のサンドボックスで流す。使うのは bash・jq・coreutils だけ。skill の有無は
# CLAUDE_CONFIG_DIR を使い捨ての dir に向けて作り、skillOverrides を書いた settings.json も同じ dir に置く。
#
# ## 確かめること
#
#   - project を作り始めるコマンドで、その言語の skill を名前を指して呼ぶよう知らせる: cargo new・cargo init (cargo +nightly
#     new も) → pjp-rust、uv init → pjp-python、go mod init → pjp-go、npm init・pnpm init・npm create・pnpm create →
#     pjp-node、ansible-galaxy init (role init・collection init も) → pjp-ansible
#   - 依存を足すコマンド (cargo add・uv add・pnpm add・引数のある npm install・npm i・go get・yarn add・bun add) で、
#     pjp-dep-release-age を読むよう知らせる。引数の無い npm install・npm ci では知らせない
#   - cd・&& でつないだもの・頭の代入・env・timeout・nix develop -c・mise exec -- の後ろも読み、作り始めと依存の両方が
#     あれば両方の文を 1 つに並べる。
#     hookEventName は PreToolUse
#   - commit の message・heredoc の本文 (終わりの印に - を含むものも)・echo の引数・コメントに書いただけでは知らせない
#   - 32 KB を超える入力は読まずに黙る (作り始め・依存を足すコマンドは短い。長いコマンドで jq の時間がかさむのを避ける)
#   - 名指しする skill が無い・settings.json の skillOverrides で off・user-invocable-only なら、その skill の文を出さない
#     (全部出さないなら黙る)。name-only (pack の skill) と壊れた settings.json では知らせる
#   - PreToolUse でない event・Bash でない tool・当たらないコマンド・壊れた入力では黙って exit 0

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../files/claude/hooks/lang-nudge.sh}
work=$(mktemp -d "${TMPDIR:-/tmp}/lang-nudge-test.XXXXXX")
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

all_skills=(pjp-rust pjp-go pjp-node pjp-python pjp-ansible pjp-dep-release-age)

# config_dir <dir 名> <settings.json の中身 (空なら作らない)> <置く skill…>: 設定 dir を作り、パスを返す
config_dir() {
  local dir="${work}/$1" settings=$2 s
  shift 2
  mkdir -p "${dir}/skills"
  for s in "$@"; do
    mkdir -p "${dir}/skills/${s}"
    printf -- '---\nname: %s\ndescription: x\n---\n' "${s}" >"${dir}/skills/${s}/SKILL.md"
  done
  if [[ -n ${settings} ]]; then
    printf '%s' "${settings}" >"${dir}/settings.json"
  fi
  printf '%s' "${dir}"
}
cfg=$(config_dir all '' "${all_skills[@]}")

# run <設定 dir> <入力>: stdout を ${work}/out に、exit code を ${work}/rc に残す
run() {
  printf '%s' "$2" | HOME="${work}/home" CLAUDE_CONFIG_DIR="$1" bash "${script}" >"${work}/out" 2>"${work}/err"
  echo $? >"${work}/rc"
}
# pre <コマンド> [<event>] [<tool>]: PreToolUse の入力
pre() {
  jq -cn --arg c "$1" --arg ev "${2:-PreToolUse}" --arg t "${3:-Bash}" \
    '{session_id: "s", hook_event_name: $ev, tool_name: $t, tool_input: {command: $c, description: "d"}, cwd: "/tmp"}'
}
context() {
  jq -r '.hookSpecificOutput.additionalContext // empty' "${work}/out" 2>/dev/null
}
event_of() {
  jq -r '.hookSpecificOutput.hookEventName // empty' "${work}/out" 2>/dev/null
}
silent() {
  [[ ! -s ${work}/out && $(cat "${work}/rc") == 0 ]]
}
detail() {
  echo "rc=$(cat "${work}/rc") out=$(cat "${work}/out") err=$(cat "${work}/err")"
}
show() {
  local s=${1//$'\n'/⏎}
  printf '%s' "${s:0:80}"
}
# expect_skill <コマンド> <skill>: その skill を名前を指して呼ぶよう知らせる
expect_skill() {
  local c
  run "${cfg}" "$(pre "$1")"
  c=$(context)
  if [[ $(cat "${work}/rc") == 0 && $(event_of) == PreToolUse && ${c} == *"\`$2\`"* && ${c} == *'Skill tool'* ]]; then
    ok "知らせる ($2): $(show "$1")"
  else
    ng "知らせる ($2): $(show "$1")" "$(detail)"
  fi
}
# expect_dep <コマンド>: 依存を足す前に pjp-dep-release-age を読むよう知らせる
expect_dep() {
  local c
  run "${cfg}" "$(pre "$1")"
  c=$(context)
  if [[ $(cat "${work}/rc") == 0 && ${c} == *'`pjp-dep-release-age`'* && ${c} == *'依存を足す前に'* ]]; then
    ok "知らせる (依存): $(show "$1")"
  else
    ng "知らせる (依存): $(show "$1")" "$(detail)"
  fi
}
# expect_silent <コマンド>: 黙る
expect_silent() {
  run "${cfg}" "$(pre "$1")"
  if silent; then
    ok "黙る: $(show "$1")"
  else
    ng "黙る: $(show "$1")" "$(detail)"
  fi
}

echo "== lang-nudge.sh"

echo "-- 作り始め"
expect_skill 'cargo new foo' pjp-rust
expect_skill 'cargo init' pjp-rust
expect_skill 'cargo +nightly new foo --lib' pjp-rust
expect_skill 'uv init --package app' pjp-python
expect_skill 'go mod init example.com/x' pjp-go
expect_skill 'npm init -y' pjp-node
expect_skill 'pnpm init' pjp-node
expect_skill 'npm create vite@latest my-app -- --template react-ts' pjp-node
expect_skill 'pnpm create vite' pjp-node
expect_skill 'ansible-galaxy init myrole' pjp-ansible
expect_skill 'ansible-galaxy role init myrole' pjp-ansible
expect_skill 'ansible-galaxy collection init ns.coll' pjp-ansible
expect_skill 'cd ~/src && cargo new foo' pjp-rust
expect_skill 'env RUSTFLAGS=-Dwarnings cargo new foo' pjp-rust
expect_skill 'CARGO_HOME=/tmp/c cargo init .' pjp-rust
expect_skill 'mise exec -- cargo new foo' pjp-rust
expect_skill 'nix develop .#rust --command cargo init' pjp-rust

# 言語の名前も文に入れる
run "${cfg}" "$(pre 'go mod init example.com/x')"
if [[ $(context) == *'Go の作業は'* ]]; then
  ok "作り始めの文に言語の名前を入れる"
else
  ng "作り始めの文に言語の名前を入れる" "$(detail)"
fi

echo "-- 依存を足す"
expect_dep 'cargo add serde --features derive'
expect_dep 'uv add requests'
expect_dep 'pnpm add react'
expect_dep 'npm install lodash'
expect_dep 'npm i -D typescript'
expect_dep 'go get example.com/x@v1.2.3'
expect_dep 'yarn add left-pad'
expect_dep 'bun add zod'
expect_dep 'timeout 60 cargo add anyhow'
expect_dep 'nix develop -c cargo add serde'

echo "-- 両方"
run "${cfg}" "$(pre 'cargo new foo && cd foo && cargo add serde')"
c=$(context)
if [[ ${c} == *'`pjp-rust`'* && ${c} == *'`pjp-dep-release-age`'* && $(wc -l <"${work}/out") == 1 ]]; then
  ok "作り始めと依存の両方があれば、両方の文を 1 つの出力に並べる"
else
  ng "作り始めと依存の両方" "$(detail)"
fi

echo "-- 黙る"
expect_silent 'npm install'
expect_silent 'npm ci'
expect_silent 'pnpm install --frozen-lockfile'
expect_silent 'cargo build --release'
expect_silent 'go test ./...'
expect_silent 'uv sync'
expect_silent 'git commit -m "cargo add serde"'
expect_silent "git commit -m 'npm init でなく pnpm init'"
expect_silent 'echo cargo new foo'
expect_silent "cat <<'EOF' >notes.md
cargo new foo
uv add requests
EOF"
expect_silent "cat <<'END-DOC' >notes.md
cargo new foo
END-DOC"
expect_silent '# cargo add serde'
expect_silent 'ls -la'

# 32 KB を超える入力は読まない
big=$(printf '%040000d' 0)
run "${cfg}" "$(pre "cat <<'EOF' >big.txt
${big}
EOF
cargo add serde")"
if silent; then ok "32 KB を超える入力は読まずに黙る"; else ng "32 KB を超える入力は読まずに黙る" "$(detail)"; fi

echo "-- skill の有無と skillOverrides"
none=$(config_dir none '')
run "${none}" "$(pre 'cargo new foo && cargo add serde')"
if silent; then ok "名指しする skill が 1 つも無ければ黙る"; else ng "skill が無ければ黙る" "$(detail)"; fi

only_dep=$(config_dir only-dep '' pjp-dep-release-age)
run "${only_dep}" "$(pre 'cargo new foo && cargo add serde')"
c=$(context)
if [[ ${c} == *'`pjp-dep-release-age`'* && ${c} != *'`pjp-rust`'* ]]; then
  ok "ある skill の文だけを出す (pjp-rust が無ければ、依存の文だけ)"
else
  ng "ある skill の文だけを出す" "$(detail)"
fi

s=""
for v in off user-invocable-only; do
  d=$(config_dir "ov-${v}" "{\"skillOverrides\":{\"pjp-rust\":\"${v}\"}}" "${all_skills[@]}")
  run "${d}" "$(pre 'cargo new foo')"
  silent || s+="[${v}] $(detail) "
done
if [[ -z ${s} ]]; then
  ok "skillOverrides で off・user-invocable-only にした skill の文は出さない"
else
  ng "skillOverrides で off・user-invocable-only" "${s}"
fi

s=""
k=0
for v in '{"skillOverrides":{"pjp-rust":"name-only"}}' '{"skillOverrides":' '{"skillOverrides":{"pjp-rust":"on"}}'; do
  k=$((k + 1))
  d=$(config_dir "ov-shown-${k}" "${v}" "${all_skills[@]}")
  run "${d}" "$(pre 'cargo new foo')"
  [[ $(context) == *'`pjp-rust`'* ]] || s+="[${v}] $(detail) "
done
if [[ -z ${s} ]]; then
  ok "name-only・on・壊れた settings.json では知らせる"
else
  ng "name-only・on・壊れた settings.json では知らせる" "${s}"
fi

echo "-- そのほか"
run "${cfg}" "$(pre 'cargo new foo' PostToolUse)"
if silent; then ok "PreToolUse でない event では黙る"; else ng "PreToolUse でない event では黙る" "$(detail)"; fi
run "${cfg}" "$(pre 'cargo new foo' PreToolUse Write)"
if silent; then ok "Bash でない tool では黙る"; else ng "Bash でない tool では黙る" "$(detail)"; fi
run "${cfg}" '{"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "cargo new'
if silent; then ok "壊れた入力では黙る"; else ng "壊れた入力では黙る" "$(detail)"; fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
