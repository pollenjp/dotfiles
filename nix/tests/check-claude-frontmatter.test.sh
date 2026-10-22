#!/usr/bin/env bash
# shellcheck shell=bash
#
# nix/scripts/check-claude-frontmatter.sh の振る舞いを、使い捨ての nix ディレクトリ (files/claude/ の skills・agents・
# commands) で確かめる。
#
#   bash nix/tests/check-claude-frontmatter.test.sh [<script のパス>]
#
# flake の checks (check-claude-frontmatter-test) が Nix のサンドボックスで流す。使うのは bash・coreutils・grep と、
# script が使う yq (mikefarah/yq)。サンドボックスの外で流すときは yq を PATH に用意する (nix/ の devShell にある)。
#
# ## 確かめること
#
#   - 通る形: 素の複数行の description (今の skill の書き方。後ろの 0 桁目のコメントと、すぐ次の key より後ろの字下げした
#     コメントは値の外)・>- と | の block scalar (# で始まる行も値)・引用符で囲んだ値 (「: 」と「 #」を含んでよく、後ろの
#     コメントは見ない)・alias・ほかの key。skill・agent (サブディレクトリも)・command (サブディレクトリの名前空間も) を
#     数え、見た個数を出して exit 0。skills・agents・commands の直下の README.md・agents のサブディレクトリの README.md
#     (Claude Code は name の無いファイルを文書として扱う)・skill のディレクトリの SKILL.md でないファイルは見ない
#   - 全角スペースの後ろの # は値に入るので、素の値の続きの行の頭にあっても通る (UTF-8 の locale でも)
#   - 落とす形。どれも、ファイルのパスと理由を 1 行ずつ全部出して exit 1:
#     - YAML として読めない (素の値の途中の「: 」)。skill・agent・command のどれでも。エラーの行番号はファイルの行
#     - frontmatter の中の --- (値の途中でも。行番号はファイルの行)・key: value の並びでない・key の重複
#     - description と name が文字列でない (列・日付)
#     - 素の値の description の「 #」から先や # で始まる行がコメントとして消える (1 行の値・複数行の最後の行・# で始まる
#       続きの行 (後ろに key があっても・タブの後ろでも)・値を key の次の行から書いたときの、値の前の # の行)
#     - description が無い・空白だけ・frontmatter がコメントだけ (name も無い)
#     - name がディレクトリ名 (agent はファイル名。サブディレクトリでも) と違う・小文字ケバブケースでない。名前 (skill は
#       ディレクトリ名、agent はファイル名、command はパスの先頭の要素) が pjp- で始まらない
#     - frontmatter が無い・閉じていない (見た目では 1 行目が --- の、BOM・CRLF・--- の後ろの空白は、そう言う)・skills の
#       直下のファイル・SKILL.md の無いディレクトリ・command のサブディレクトリの README.md (配置されて command になると言う)
#   - description が 1024 文字を超えると、注意を出すが落とさない。数えるのは文字で、バイトではない (日本語の 1024 文字は
#     出さない)
#   - 引数を省けば、script の隣の nix/ を見る。ファイルは nix/ から書く
#   - <nix>/files/claude が無い・知らない引数・2 つ目の <nix のパス> は exit 2。--help は使い方を出して exit 0。見るものが
#     1 つも無ければ exit 1
#   - yq が PATH に無いか、mikefarah/yq でなければ (同じ名前の python の yq)、nix/ の devShell に入り直して
#     (nix develop <nix> --command) 同じ引数で流し直す。入り直しても無ければ (印の環境変数がある)、入り直さずに exit 2
#   - script に実行ビットがある (CI の lint ジョブが ./nix/scripts/check-claude-frontmatter.sh で直に呼ぶ)

set -u -o pipefail

here=$(
  cd -- "$(dirname "$0")" &>/dev/null || exit
  pwd -P
)
script=${1:-${here}/../scripts/check-claude-frontmatter.sh}
# script は yq (mikefarah/yq) が無いと devShell に入り直すので、それではこのテストの多くが確かめられない
if ! yq_version=$(yq --version 2>&1) || [[ ${yq_version} != *mikefarah/yq* ]]; then
  echo "見つからない: yq (mikefarah/yq) (nix/ の devShell で流す: nix develop ./nix --command bash nix/tests/check-claude-frontmatter.test.sh)" >&2
  exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/check-claude-frontmatter-test.XXXXXX")
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

# $1: ケースの名前。<work>/<ケース>/nix/files/claude に skills・agents・commands を作り、nix の場所を出す
new_nix() {
  local n="${work}/$1/nix"
  mkdir -p "${n}/files/claude/skills" "${n}/files/claude/agents" "${n}/files/claude/commands"
  echo "${n}"
}

# $1: 置き先。中身は標準入力
put() {
  mkdir -p "$(dirname "$1")"
  cat >"$1"
}

# $1: ケースの dir、残り: script の引数。<ケース>/out・err・rc に残す
run_in() {
  local c=$1
  shift
  "${BASH}" "${script}" "$@" >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
}
# $1: nix の場所 (<ケース>/nix)。それを渡して流す
run() {
  run_in "$(dirname "$1")" "$1"
}
rc() { cat "$1/rc"; }
out() { cat "$1/out"; }
err() { cat "$1/err"; }
seen_out() {
  local c=$1
  shift
  grep -q "$@" "${c}/out"
}
seen_err() {
  local c=$1
  shift
  grep -q "$@" "${c}/err"
}
# $1: ケースの dir。出したファイルごとの行 (「   nix/files/claude/<パス>: 」で始まる行) の数
lines_of() { grep -c '^   nix/files/claude/[^:]*: ' "$1/err"; }

echo "== check-claude-frontmatter.sh: ${script}"

# 1. 通る形。直下の README.md と、skill のディレクトリの SKILL.md でないファイルは見ない
n=$(new_nix t1)
cl=${n}/files/claude
c=$(dirname "${n}")
printf '%s\n' '# skill の README (frontmatter は無い)' >"${cl}/skills/README.md"
printf '%s\n' '# agent の README' >"${cl}/agents/README.md"
printf '%s\n' '# command の README' >"${cl}/commands/README.md"
# description の後ろに key が 2 つあっても、# で始まる行を見るのはすぐ次の key (metadata) の手前まで
put "${cl}/skills/pjp-plain/SKILL.md" <<'EOF'
---
name: pjp-plain
description: 素の複数行の description。今の skill はこの形で書いている。`d3js/` のような
  バッククォート・（全角の括弧）・(作り直すと値が消える)・**太字**・「かぎ括弧」・a/b を含んでよい。
  「〜と言われたとき」で始まる行や、https://example.com/a?b=c も通る
# 0 桁目のコメントは値の外にある (消える値ではない)
metadata:
  # 次の key より後ろの字下げしたコメントも、description の外
  owner: pjp
allowed-tools: Read
---

# pjp-plain
EOF
put "${cl}/skills/pjp-plain/references/notes.md" <<'EOF'
# frontmatter の無い補助ファイル (見ない)
EOF
put "${cl}/skills/pjp-folded/SKILL.md" <<'EOF'
---
name: pjp-folded
description: >-
  >- の block scalar なら「いつ使うか: 」のような「: 」も、
  PR #12 のような「 #」も値に入る。
  #dev のように # で始まる行も値に入る
---
EOF
put "${cl}/skills/pjp-quoted/SKILL.md" <<'EOF'
---
name: "pjp-quoted"
description: 'いつ使うか: 引用符で囲めば「: 」も PR #12 も書ける' # 引用符の後ろのコメントは値に入らない
---
EOF
put "${cl}/skills/pjp-literal/SKILL.md" <<'EOF'
---
name: pjp-literal
description: |
  literal の block scalar でもよい。
  改行もそのまま残る
allowed-tools:
  - Bash
  - Read
---
EOF
put "${cl}/skills/pjp-alias/SKILL.md" <<'EOF'
---
when: &when いつ使うかを alias で渡す
name: pjp-alias
description: *when
---
EOF
put "${cl}/agents/pjp-a.md" <<'EOF'
---
name: pjp-a
description: いつ委譲するかを書く
tools: Read, Grep, Glob      # 省略すると全ツール
model: sonnet
---

システムプロンプト
EOF
put "${cl}/agents/pjp-team/pjp-reviewer.md" <<'EOF'
---
name: pjp-reviewer
description: サブディレクトリに置いた agent (Claude Code は agents の下を再帰で読む)
---
EOF
printf '%s\n' '# agents のサブディレクトリの README (Claude Code は name の無いファイルを文書として扱う)' \
  >"${cl}/agents/pjp-team/README.md"
put "${cl}/commands/pjp-c.md" <<'EOF'
---
description: /help や補完に出る 1 行説明
argument-hint: <path>
---

本文 $ARGUMENTS
EOF
put "${cl}/commands/pjp-ns/sub.md" <<'EOF'
---
description: サブディレクトリで名前空間を切った command (/pjp-ns:sub)
---
EOF
run "${n}"
if [[ $(rc "${c}") == 0 && ! -s ${c}/err ]] && seen_out "${c}" -F '9 個'; then
  ok "通る形 (素の複数行・>-・|・引用符・alias・ほかの key) は、skill 5・agent 2 (サブディレクトリも)・command 2 の 9 個を数えて exit 0 (README.md と補助ファイルは見ない)"
else
  ng "通る形" "rc=$(rc "${c}") out=$(out "${c}") err=$(err "${c}")"
fi

# 2. YAML として読めない (素の値の途中の「: 」)。skill・agent・command のどれでも、エラーの行番号はファイルの行
n=$(new_nix t2)
cl=${n}/files/claude
c=$(dirname "${n}")
put "${cl}/skills/pjp-x/SKILL.md" <<'EOF'
---
name: pjp-x
description: shell の罠を書く前に読む。
  Bash tool で (eval):1: で始まるエラーが出たときも読む
---
EOF
put "${cl}/agents/pjp-a.md" <<'EOF'
---
name: pjp-a
description: 委譲するとき: 値の途中に「: 」がある
---
EOF
put "${cl}/commands/pjp-c.md" <<'EOF'
---
description: 呼ぶとき: 値の途中に「: 」がある
---
EOF
run "${n}"
if [[ $(rc "${c}") == 1 && $(lines_of "${c}") == 3 ]] \
  && seen_err "${c}" -E '^   nix/files/claude/skills/pjp-x/SKILL\.md: frontmatter を YAML として読めません \(.*line 4, ' \
  && seen_err "${c}" -E '^   nix/files/claude/agents/pjp-a\.md: frontmatter を YAML として読めません \(.*line 3, ' \
  && seen_err "${c}" -E '^   nix/files/claude/commands/pjp-c\.md: frontmatter を YAML として読めません \(.*line 2, '; then
  ok "YAML として読めない frontmatter は、skill・agent・command のどれでもファイルの行番号付きで出して exit 1"
else
  ng "YAML として読めない" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 3. frontmatter の中の --- (値の途中でも)。Claude Code はそこで frontmatter を閉じる
n=$(new_nix t3)
cl=${n}/files/claude
c=$(dirname "${n}")
put "${cl}/skills/pjp-x/SKILL.md" <<'EOF'
---
name: pjp-x
description: >-
  いつ使うか --- ここから先を Claude Code は本文として読む
---
EOF
run "${n}"
if [[ $(rc "${c}") == 1 && $(lines_of "${c}") == 1 ]] \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-x/SKILL.md: frontmatter の中に --- があります (4 行目)'; then
  ok "frontmatter の中の --- は、値の途中でもファイルの行番号付きで出して exit 1"
else
  ng "frontmatter の中の ---" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 4. key: value の並びでない・key の重複・description と name が文字列でない
n=$(new_nix t4)
cl=${n}/files/claude
c=$(dirname "${n}")
put "${cl}/skills/pjp-seq/SKILL.md" <<'EOF'
---
- pjp-seq
- いつ使うか
---
EOF
put "${cl}/skills/pjp-dup/SKILL.md" <<'EOF'
---
name: pjp-dup
description: 古い説明
description: 新しい説明
---
EOF
put "${cl}/skills/pjp-desc-list/SKILL.md" <<'EOF'
---
name: pjp-desc-list
description:
  - いつ使うか
  - 箇条書きにした
---
EOF
put "${cl}/skills/pjp-desc-date/SKILL.md" <<'EOF'
---
name: pjp-desc-date
description: 2026-10-21
---
EOF
put "${cl}/skills/pjp-name-list/SKILL.md" <<'EOF'
---
name: [pjp-name-list]
description: いつ使うか
---
EOF
run "${n}"
if [[ $(rc "${c}") == 1 && $(lines_of "${c}") == 5 ]] \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-seq/SKILL.md: frontmatter が key: value の並びになっていません (!!seq)' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-dup/SKILL.md: frontmatter の key が重複しています (description)' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-desc-list/SKILL.md: description が文字列ではありません (!!seq)' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-desc-date/SKILL.md: description が文字列ではありません (!!timestamp)' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-name-list/SKILL.md: name が文字列ではありません (!!seq)'; then
  ok "key: value の並びでない・key の重複・description と name が文字列でない (列・日付) を、それぞれ出して exit 1"
else
  ng "形と型" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 5. 素の値の description の「 #」から先は YAML のコメントになり、値から黙って消える (読めてしまう)
n=$(new_nix t5)
cl=${n}/files/claude
c=$(dirname "${n}")
put "${cl}/skills/pjp-x/SKILL.md" <<'EOF'
---
name: pjp-x
description: PR #12 で壊れた形を直すとき
---
EOF
put "${cl}/agents/pjp-a.md" <<'EOF'
---
name: pjp-a
description: 委譲するときに読む。
  最後の行の Slack の #dev から先も消える
---
EOF
# 続きの行の頭の # (字下げの後) もコメントの始まりで、行ごと消える。yq はこのコメントを、位置で変わる node
# (description の key・次の key・値) に字下げを落として付けるので、0 桁目のコメントと見分けられない
put "${cl}/skills/pjp-y/SKILL.md" <<'EOF'
---
name: pjp-y
description: Slack に投稿するときに使う。投稿先は
  #dev チャンネルなど
---
EOF
put "${cl}/commands/pjp-c.md" <<'EOF'
---
description: 呼ぶときに読む。
  #12 で足した続きの行も消える
argument-hint: <path>
---
EOF
# 字下げの後のタブも YAML の空白なので、その後ろの # からコメントになる
tab=$'\t'
put "${cl}/skills/pjp-tab/SKILL.md" <<EOF
---
name: pjp-tab
description: 委譲するときに読む。
  ${tab}#dev タブの後ろの行も消える
---
EOF
# 値を key の次の行から書くと、値の前の # の行も消える (値は後ろの行だけになる)
put "${cl}/commands/pjp-d.md" <<'EOF'
---
description:
  #dev で始めた最初の行も消える
  続きの行だけが値になる
argument-hint: <path>
---
EOF
run "${n}"
if [[ $(rc "${c}") == 1 && $(lines_of "${c}") == 6 ]] \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-x/SKILL.md: description の「 #」から先 (#12 で壊れた形を直すとき) がコメントとして捨てられています' \
  && seen_err "${c}" -F '   nix/files/claude/agents/pjp-a.md: description の「 #」から先 (#dev から先も消える) がコメントとして捨てられています' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-y/SKILL.md: description の # で始まる行 (4 行目: #dev チャンネルなど) がコメントとして捨てられています' \
  && seen_err "${c}" -F '   nix/files/claude/commands/pjp-c.md: description の # で始まる行 (3 行目: #12 で足した続きの行も消える) がコメントとして捨てられています' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-tab/SKILL.md: description の # で始まる行 (4 行目: #dev タブの後ろの行も消える) がコメントとして捨てられています' \
  && seen_err "${c}" -F '   nix/files/claude/commands/pjp-d.md: description の # で始まる行 (3 行目: #dev で始めた最初の行も消える) がコメントとして捨てられています。値に含めるなら >- の block scalar にするか引用符で囲み、コメントなら 0 桁目から書いてください'; then
  ok "素の値の description の「 #」から先や # で始まる行が消える形は、1 行の値・複数行の最後の行・# で始まる続きの行 (後ろに key があっても・タブの後ろでも)・値を key の次の行から書いたときの値の前の # の行のどれでも、消える部分を添えて exit 1"
else
  ng "「 #」から先と # で始まる行" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 5b. 全角スペース (U+3000) は YAML の空白ではないので、その後ろの # はコメントにならず値に入る。[[:space:]] は UTF-8 の
#     locale で全角スペースにも当たるので、C.UTF-8 で流す (Nix のサンドボックスは C ロケールで、そのままでは当たらない)
n=$(new_nix t5b)
cl=${n}/files/claude
c=$(dirname "${n}")
zenkaku=$'\xe3\x80\x80'
put "${cl}/skills/pjp-zenkaku/SKILL.md" <<EOF
---
name: pjp-zenkaku
description: Slack に投稿するときに使う。
  ${zenkaku}#dev チャンネルも、全角スペースの後ろなら値に入る
---
EOF
LC_ALL=C.UTF-8 run "${n}"
if [[ $(rc "${c}") == 0 && ! -s ${c}/err ]] && seen_out "${c}" -F '1 個'; then
  ok "素の値の続きの行の頭でも、全角スペースの後ろの # は値に入るので、UTF-8 の locale でも通る"
else
  ng "全角スペースの後ろの #" "rc=$(rc "${c}") out=$(out "${c}") err=$(err "${c}")"
fi

# 6. description が無い・空白だけ・frontmatter がコメントだけ (name も無い)
n=$(new_nix t6)
cl=${n}/files/claude
c=$(dirname "${n}")
put "${cl}/skills/pjp-missing/SKILL.md" <<'EOF'
---
name: pjp-missing
---
EOF
put "${cl}/skills/pjp-blank/SKILL.md" <<'EOF'
---
name: pjp-blank
description: "   "
---
EOF
put "${cl}/skills/pjp-comment/SKILL.md" <<'EOF'
---
# コメントだけで、key が 1 つも無い
---
EOF
run "${n}"
if [[ $(rc "${c}") == 1 && $(lines_of "${c}") == 4 ]] \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-missing/SKILL.md: description がありません' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-blank/SKILL.md: description がありません' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-comment/SKILL.md: description がありません' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-comment/SKILL.md: name がありません'; then
  ok "description が無い・空白だけ・コメントだけの frontmatter (name も無い) を出して exit 1"
else
  ng "無い description と name" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 7. name がディレクトリ名 (agent はファイル名) と違う・小文字ケバブケースでない・名前が pjp- で始まらない
n=$(new_nix t7)
cl=${n}/files/claude
c=$(dirname "${n}")
put "${cl}/skills/pjp-x/SKILL.md" <<'EOF'
---
name: pjp-y
description: いつ使うか
---
EOF
put "${cl}/skills/pjp-Up/SKILL.md" <<'EOF'
---
name: pjp-Up
description: いつ使うか
---
EOF
put "${cl}/skills/foo/SKILL.md" <<'EOF'
---
name: foo
description: いつ使うか
---
EOF
put "${cl}/agents/pjp-a.md" <<'EOF'
---
name: pjp-b
description: いつ委譲するか
---
EOF
put "${cl}/agents/bar.md" <<'EOF'
---
name: bar
description: いつ委譲するか
---
EOF
# サブディレクトリの agent も、name はファイル名と同じで、ファイル名は pjp- で始める
put "${cl}/agents/pjp-team/pjp-c.md" <<'EOF'
---
name: pjp-d
description: いつ委譲するか
---
EOF
put "${cl}/agents/pjp-team/helper.md" <<'EOF'
---
name: helper
description: いつ委譲するか
---
EOF
put "${cl}/commands/baz.md" <<'EOF'
---
description: いつ呼ぶか
---
EOF
put "${cl}/commands/ns/pjp-sub.md" <<'EOF'
---
description: 呼び出し名は /ns:pjp-sub で、頭が ns になる
---
EOF
put "${cl}/commands/pjp-ns/sub.md" <<'EOF'
---
description: 呼び出し名は /pjp-ns:sub (通る)
---
EOF
run "${n}"
if [[ $(rc "${c}") == 1 && $(lines_of "${c}") == 9 ]] \
  && seen_err "${c}" -F "   nix/files/claude/skills/pjp-x/SKILL.md: name が 'pjp-y' ですが、ディレクトリ名 'pjp-x' と同じにしてください" \
  && seen_err "${c}" -F "   nix/files/claude/skills/pjp-Up/SKILL.md: name 'pjp-Up' は小文字ケバブケースにしてください" \
  && seen_err "${c}" -F "   nix/files/claude/skills/foo: 名前 'foo' は 'pjp-' で始めてください" \
  && seen_err "${c}" -F "   nix/files/claude/agents/pjp-a.md: name が 'pjp-b' ですが、ファイル名 'pjp-a' と同じにしてください" \
  && seen_err "${c}" -F "   nix/files/claude/agents/bar.md: 名前 'bar' は 'pjp-' で始めてください" \
  && seen_err "${c}" -F "   nix/files/claude/agents/pjp-team/pjp-c.md: name が 'pjp-d' ですが、ファイル名 'pjp-c' と同じにしてください" \
  && seen_err "${c}" -F "   nix/files/claude/agents/pjp-team/helper.md: 名前 'helper' は 'pjp-' で始めてください" \
  && seen_err "${c}" -F "   nix/files/claude/commands/baz.md: 名前 'baz' は 'pjp-' で始めてください" \
  && seen_err "${c}" -F "   nix/files/claude/commands/ns/pjp-sub.md: 名前 'ns' は 'pjp-' で始めてください"; then
  ok "name の食い違い (ディレクトリ名・ファイル名。agent はサブディレクトリでも)・ケバブケースでない name・pjp- で始まらない名前 (command はパスの先頭) を出して exit 1"
else
  ng "名前" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 8. frontmatter が無い・閉じていない・skills の直下のファイル・SKILL.md の無いディレクトリ・command のサブディレクトリの
#    README.md (直下の README.md と違って配置され、command になる)。見た目では 1 行目が --- なのに取り出せない形
#    (BOM・CRLF・--- の後ろの空白。Claude Code は読める) は、そう言う
n=$(new_nix t8)
cl=${n}/files/claude
c=$(dirname "${n}")
put "${cl}/skills/pjp-nofm/SKILL.md" <<'EOF'
# 見出しだけで frontmatter が無い
EOF
put "${cl}/skills/pjp-open/SKILL.md" <<'EOF'
---
name: pjp-open
description: 閉じていない

# 本文
EOF
mkdir -p "${cl}/skills/pjp-bom" "${cl}/skills/pjp-crlf" "${cl}/skills/pjp-space"
printf '\xef\xbb\xbf---\nname: pjp-bom\ndescription: 先頭に BOM がある\n---\n' >"${cl}/skills/pjp-bom/SKILL.md"
printf -- '---\r\nname: pjp-crlf\r\ndescription: 改行が CRLF\r\n---\r\n' >"${cl}/skills/pjp-crlf/SKILL.md"
printf -- '--- \nname: pjp-space\ndescription: 1 行目の --- の後ろに空白がある\n---\n' >"${cl}/skills/pjp-space/SKILL.md"
put "${cl}/skills/pjp-file.md" <<'EOF'
---
name: pjp-file
description: skills の直下に置いたファイル
---
EOF
put "${cl}/skills/pjp-empty/references/notes.md" <<'EOF'
# SKILL.md が無い
EOF
put "${cl}/commands/pjp-ns/README.md" <<'EOF'
# 名前空間の説明のつもり
EOF
run "${n}"
if [[ $(rc "${c}") == 1 && $(lines_of "${c}") == 8 ]] \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-nofm/SKILL.md: YAML frontmatter がありません (1 行目を --- にし、次の --- の行で閉じてください)' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-open/SKILL.md: YAML frontmatter がありません (1 行目の --- を閉じる --- の行がありません)' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-bom/SKILL.md: YAML frontmatter がありません (先頭に BOM があります' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-crlf/SKILL.md: YAML frontmatter がありません (改行が CRLF です' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-space/SKILL.md: YAML frontmatter がありません (1 行目の --- の後ろに空白があります' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-file.md: skills の直下にはディレクトリだけを置いてください' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-empty: SKILL.md がありません' \
  && seen_err "${c}" -F '   nix/files/claude/commands/pjp-ns/README.md: 配置されて command /pjp-ns:README になります'; then
  ok "frontmatter が無い・閉じていない・BOM・CRLF・--- の後ろの空白 (理由を添える)・skills の直下のファイル・SKILL.md の無いディレクトリ・command のサブディレクトリの README.md (command になると言う) を出して exit 1"
else
  ng "置き方" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 9. description が 1024 文字を超えると注意を出すが、落とさない。数えるのは文字 (日本語の 1024 文字は 3072 バイト)
n=$(new_nix t9)
cl=${n}/files/claude
c=$(dirname "${n}")
long_ascii=$(printf 'a%.0s' {1..1025})
long_ja=$(printf 'あ%.0s' {1..1024})
printf -- '---\nname: pjp-long\ndescription: %s\n---\n' "${long_ascii}" | put "${cl}/skills/pjp-long/SKILL.md"
printf -- '---\nname: pjp-ja\ndescription: %s\n---\n' "${long_ja}" | put "${cl}/skills/pjp-ja/SKILL.md"
run "${n}"
if [[ $(rc "${c}") == 0 && $(lines_of "${c}") == 1 ]] && seen_out "${c}" -F '2 個' \
  && seen_err "${c}" -F '   nix/files/claude/skills/pjp-long/SKILL.md: description が長すぎます (1025 文字)'; then
  ok "description が 1024 文字を超えると注意を出すが exit 0 (日本語の 1024 文字 = 3072 バイトは出さない)"
else
  ng "長い description" "rc=$(rc "${c}") out=$(out "${c}") err=$(err "${c}")"
fi

# 10. 引数を省けば、script の隣の nix/ を見る。ファイルは nix/ から書く
c="${work}/t10"
mkdir -p "${c}/nix/scripts"
cp "${script}" "${c}/nix/scripts/check-claude-frontmatter.sh"
put "${c}/nix/files/claude/skills/pjp-x/SKILL.md" <<'EOF'
---
name: pjp-x
description: いつ使うか
---
EOF
# 写した方の script を引数なしで流す (run_in は本物の script を流す)
"${BASH}" "${c}/nix/scripts/check-claude-frontmatter.sh" >"${c}/out" 2>"${c}/err"
echo $? >"${c}/rc"
rc_good=$(rc "${c}")
put "${c}/nix/files/claude/skills/pjp-y/SKILL.md" <<'EOF'
---
name: pjp-y
---
EOF
"${BASH}" "${c}/nix/scripts/check-claude-frontmatter.sh" >"${c}/out" 2>"${c}/err"
echo $? >"${c}/rc"
if [[ ${rc_good} == 0 && $(rc "${c}") == 1 ]] && seen_err "${c}" -F '   nix/files/claude/skills/pjp-y/SKILL.md: description がありません'; then
  ok "引数を省けば、script の隣の nix/ を見る (ファイルは nix/ から書く)"
else
  ng "引数を省く" "good だけのとき rc=${rc_good} / rc=$(rc "${c}") err=$(err "${c}")"
fi

# 11. <nix>/files/claude が無い・知らない引数・2 つ目の <nix のパス> は exit 2、--help は exit 0。見るものが無ければ exit 1
c="${work}/t11"
mkdir -p "${c}/no-claude/nix"
run_in "${c}" "${c}/no-claude/nix"
rc_missing=$(rc "${c}")
run_in "${c}" --no-such-option
rc_opt=$(rc "${c}")
run_in "${c}" "${c}/no-claude/nix" "${c}/no-claude/nix"
rc_two=$(rc "${c}")
n=$(new_nix t11/empty)
printf '%s\n' '# README だけ' >"${n}/files/claude/skills/README.md"
run_in "${c}" "${n}"
rc_empty=$(rc "${c}")
empty_said=0
if seen_err "${c}" -F '1 つも見つかりません'; then
  empty_said=1
fi
run_in "${c}" --help
if [[ ${rc_missing} == 2 && ${rc_opt} == 2 && ${rc_two} == 2 && ${rc_empty} == 1 && ${empty_said} == 1 ]] \
  && [[ $(rc "${c}") == 0 ]] && seen_out "${c}" -F '使い方'; then
  ok "files/claude が無い・知らない引数・2 つ目のパスは exit 2、見るものが無ければ exit 1、--help は使い方を出して exit 0"
else
  ng "exit 2 と --help" "files/claude が無い rc=${rc_missing} / 知らない引数 rc=${rc_opt} / 2 つ目のパス rc=${rc_two} / 見るものが無い rc=${rc_empty} (言ったか ${empty_said}) / --help rc=$(rc "${c}") out=$(out "${c}")"
fi

# 12. yq が無いか mikefarah/yq でなければ、nix/ の devShell に入り直して同じ引数で流し直す。入り直しても無ければ exit 2
c="${work}/t12"
mkdir -p "${c}/nix/scripts" "${c}/bin" "${c}/bin-pyyq"
cp "${script}" "${c}/nix/scripts/check-claude-frontmatter.sh"
ln -s "$(command -v dirname)" "${c}/bin/dirname"
# 偽の nix。引数を 1 行に 1 つずつ書き留めて終わる
{
  printf '#!%s\n' "${BASH}"
  cat <<'EOF'
printf '%s\n' "$@" >"${NIX_CALLS}"
EOF
} >"${c}/bin/nix"
chmod +x "${c}/bin/nix"
# 同じ yq という名前の python の yq (kislyuk/yq。jq の wrapper) と同じ版の出し方をする偽物
ln -s "${c}"/bin/* "${c}/bin-pyyq/"
{
  printf '#!%s\n' "${BASH}"
  echo 'echo "yq 3.4.3"'
} >"${c}/bin-pyyq/yq"
chmod +x "${c}/bin-pyyq/yq"
want_calls=$(printf '%s\n' develop "$(cd "${c}/nix" && pwd -P)" --command "${c}/nix/scripts/check-claude-frontmatter.sh" some/nix)
# $1: PATH にするディレクトリ。入り直したら (偽の nix を同じ引数で呼んだら) 0 を返す
reexecs() {
  rm -f "${c}/nix-calls"
  NIX_CALLS="${c}/nix-calls" PATH="$1" "${BASH}" "${c}/nix/scripts/check-claude-frontmatter.sh" some/nix >"${c}/out" 2>"${c}/err"
  echo $? >"${c}/rc"
  [[ $(rc "${c}") == 0 && $(cat "${c}/nix-calls" 2>/dev/null) == "${want_calls}" ]]
}
reexec_none=0
reexec_pyyq=0
if reexecs "${c}/bin"; then
  reexec_none=1
fi
if reexecs "${c}/bin-pyyq"; then
  reexec_pyyq=1
fi
if [[ ${reexec_none} == 1 && ${reexec_pyyq} == 1 ]]; then
  ok "yq が無くても、python の yq しか無くても、nix develop <nix> --command で同じ引数のまま入り直す"
else
  ng "devShell に入り直す" "yq が無いとき ${reexec_none} / python の yq のとき ${reexec_pyyq} / calls=$(cat "${c}/nix-calls" 2>/dev/null) err=$(err "${c}")"
fi
rm -f "${c}/nix-calls"
CHECK_CLAUDE_FRONTMATTER_REEXEC=1 NIX_CALLS="${c}/nix-calls" PATH="${c}/bin" "${BASH}" "${c}/nix/scripts/check-claude-frontmatter.sh" some/nix \
  >"${c}/out" 2>"${c}/err"
echo $? >"${c}/rc"
if [[ $(rc "${c}") == 2 && ! -e ${c}/nix-calls ]] && seen_err "${c}" -F 'yq'; then
  ok "入り直しても yq (mikefarah/yq) が無ければ、入り直さずに exit 2"
else
  ng "入り直しても無い" "rc=$(rc "${c}") err=$(err "${c}")"
fi

# 13. 実行ビット
if [[ -x ${script} ]]; then
  ok "script に実行ビットがある"
else
  ng "script に実行ビットが無い (CI の lint ジョブが直に呼べない)" "${script}"
fi

echo "== ${pass} passed, ${fail} failed"
[[ ${fail} == 0 ]]
