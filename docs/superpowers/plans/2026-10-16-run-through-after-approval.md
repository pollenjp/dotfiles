# 方針を承認したら PR まで走り切る 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** superpowers の流れで承認を求めるのを方針の 1 回だけにし、承認のあとは spec → 実装計画 → 実装 → PR まで確認を挟まずに進むよう、CLAUDE.md の節と、4 つの skill を読んだ直後に念を押す PostToolUse の hook を足す。

**Architecture:** `nix/files/claude/CLAUDE.md` に節を足す (常時読まれる正本)。`nix/files/claude/hooks/run-through-nudge.sh` は PostToolUse・matcher `Skill` で動き、`tool_input.skill` が superpowers の 4 つの skill のときだけ `additionalContext` に 1 文を返す。hook は `claude.nix` の `home.file` が配り、`bootstrap-claude-hook.sh` が settings.json に登録する (`video-offer-nudge.sh` と同じ形)。

**Tech Stack:** bash (shfmt / shellcheck)、jq、Nix (home-manager・flake の `checks` の `scriptTest`)

**Spec:** `docs/adr/019_claude_run_through_after_approval_20261016T150008JST/README.md` (ADR 019、方針は 2026-10-16 に承認。チケットは TKT-168)

## Global Constraints

- hook の置き場所は `nix/files/claude/hooks/run-through-nudge.sh`、配置先は `~/.claude/hooks/run-through-nudge.sh` (実行ビット付き)
- hook の登録は `hooks.PostToolUse` に matcher `Skill`・`if` なし・command `${HOME}/.claude/hooks/run-through-nudge.sh` の 1 件
- 知らせる skill は `superpowers:brainstorming`・`superpowers:writing-plans`・`superpowers:using-git-worktrees`・`superpowers:finishing-a-development-branch` の 4 つだけ (plugin の名前つきだけを見る)
- 差し込む文は ADR 019 §2 B の表の 4 文と 1 文字も違えない。出力は `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"<文>"}}`
- 黙る (何も出さず exit 0): 4 つ以外の skill・`Skill` 以外の tool・入力に `agent_id` がある・`tool_response.success` が `false`・壊れた入力・`jq` が無い
- CLAUDE.md の節は ADR 019 §2 A の文面のまま、「## 応答の言語」の節の直後 (「## 同梱 script の依存ツール」の前) に置く
- hook は `set -u -o pipefail` (`-e` なし。何があっても exit 0)。bootstrap は今の `set -eu -o pipefail` のまま
- shfmt (2 空白・`binary_next_line`・`case_indent`) と shellcheck を通す。テストの先頭のコメントに「## 確かめること」を書く (`check-test-headers.sh`)
- テストでは、コマンドの出力を `| grep -q` に流さない (pipefail の下で SIGPIPE を拾う)。ファイルに落として見る
- commit メッセージは日本語、`<種類>(<範囲>): … (TKT-168)`。末尾に Co-Authored-By と Claude-Session の 2 行

## Review Focus

- ユーザーが `/superpowers:brainstorming` のように自分で skill を呼んだときは Skill の tool を通らないので hook は動かない。CLAUDE.md の節だけで同じ振る舞いになること (CLAUDE.md の文面が単独で読めるか)
- 他の道具が matcher `Skill` の PostToolUse を登録していても、bootstrap はそれを残して自分の 1 件を足すこと (Task 2 のテストで押さえる)
- `tool_response` に `success` が無い入力 (Claude Code が形を変えたとき) でも知らせること (Task 1 のテストで押さえる)
- 同じ skill を 1 セッションで何度読んでも、毎回 1 文だけを返すこと (状態を持たないので満たす。Task 1 のテストは 1 回ずつ流す)
- hook を配った後・登録する前 (switch だけ済んだ状態) と、登録した後・配る前 (古い世代) の両方で、Claude Code の tool の流れが止まらないこと (hook が無ければ Claude Code は hook の失敗として流す。bootstrap は hook が無ければ登録しない)

---

### Task 1: hook (run-through-nudge.sh) とそのテストを足し、配る

**Files:**
- Create: `nix/files/claude/hooks/run-through-nudge.sh`
- Create: `nix/tests/run-through-nudge.test.sh`
- Modify: `nix/flake.nix` (checks に `run-through-nudge-test` を足す。`video-offer-nudge-test` の次の行)
- Modify: `nix/home/modules/claude.nix` (`video-offer-nudge.sh` の `home.file` の次に、同じ形で `.claude/hooks/run-through-nudge.sh` を足す。直前のコメントは「PostToolUse フック。superpowers の 4 つの skill を読んだ直後に…」)

**Interfaces:**
- Consumes: なし
- Produces: stdin に PostToolUse の JSON を受け、知らせるときだけ stdout に 1 行の JSON を出す実行ファイル `run-through-nudge.sh`。いつも exit 0

- [ ] **Step 1: テストを書く** — `nix/tests/run-through-nudge.test.sh`。形は `nix/tests/video-offer-nudge.test.sh` に合わせる (`ok` / `ng` / `run` / `context` / `silent`、最後に `== N passed, M failed` を出し、失敗があれば exit 1)。入力は `skill_input <skill> [<success>]` が作る `{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":<skill>},"tool_response":{"success":<success>,"commandName":<skill>}}`。

  確かめること (1 項目 1 つの `ok`):
  1. `superpowers:brainstorming` → rc 0・`hookEventName` が `PostToolUse`・文が ADR §2 B の表の brainstorming の文と完全に一致
  2. `superpowers:writing-plans` → 同じく writing-plans の文と完全に一致
  3. `superpowers:using-git-worktrees` → 同じく完全に一致
  4. `superpowers:finishing-a-development-branch` → 同じく完全に一致
  5. `tool_response` に `success` が無い (`{"commandName":…}` だけ) `superpowers:writing-plans` → 知らせる (1 と同じ判定で、文が `[走り切り] superpowers:writing-plans を読んだ。` で始まる)
  6. 他の superpowers の skill (`superpowers:test-driven-development`) → 黙る
  7. plugin の名前の無い `writing-plans` と、別の plugin の `other:writing-plans` → どちらも黙る
  8. 自作の skill (`pjp-cc-page`) → 黙る
  9. `Skill` 以外の tool (`tool_name` が `Bash`、`tool_input.command` が `echo superpowers:writing-plans`) → 黙る
  10. subagent の中 (`superpowers:writing-plans` の入力に `agent_id: "agent-1"`) → 黙る
  11. 読み込みに失敗 (`superpowers:writing-plans`、`success` が `false`) → 黙る
  12. 壊れた入力 (`{"tool_name": "Skill", `) と空の入力 → どちらも黙って exit 0
  13. `jq` が無い (PATH を `cat` だけを置いた dir にし、bash は絶対パスで起動) → 黙って exit 0

  期待する 4 文はテストの中に ADR §2 B の表から写した文字列で持つ (hook の中の組み立て方に依らずに比べる)。

- [ ] **Step 2: 失敗を確かめる**

  Run: `bash nix/tests/run-through-nudge.test.sh`
  Expected: hook がまだ無いので 1〜5 と 13 が FAIL (6〜12 は「黙る」なので、無い script でも exit 127 のため FAIL になるものがある)。最後の行が `== … failed` で exit 1

- [ ] **Step 3: hook を書く** — `nix/files/claude/hooks/run-through-nudge.sh` (実行ビット付き)。冒頭のコメントは `video-offer-nudge.sh` と同じ並び (何をするか → 知らせる場面 → 黙る場面 → 登録)。流れ:
  1. `input=$(cat) || exit 0` で stdin を先に読み切る
  2. `jq` が無ければ exit 0
  3. `field()` (`jq -r "$1 // empty"`) で `.tool_name` が `Skill` でなければ exit 0、`.agent_id` があれば exit 0
  4. `success` は `field()` で読まない (`//` は `false` も空にする)。`jq -r '.tool_response.success | tostring'` が `false` なら exit 0
  5. `case` で 4 つの skill ごとに文を組む。節の名前は `section='方針を承認したら PR まで走り切る'`、締めの 1 文は `follow='ユーザーがこの会話で別の進め方を言っていれば、そちらに従う。'` の変数にする (`~` は文の途中に置く。文頭の `~` は shellcheck の SC2088 に当たる)。それ以外は exit 0
  6. `jq -cn --arg msg "${msg}" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $msg}}' || true`、exit 0

- [ ] **Step 4: テストが通ることを確かめる**

  Run: `bash nix/tests/run-through-nudge.test.sh`
  Expected: すべて `ok`、最後の行が `== 13 passed, 0 failed`、exit 0

- [ ] **Step 5: flake の checks と claude.nix に足す**

  `nix/flake.nix` の `video-offer-nudge-test = …;` の次に `run-through-nudge-test = scriptTest "run-through-nudge" ./files/claude/hooks/run-through-nudge.sh;`。`claude.nix` に `home.file` を足す (上の Files のとおり)。新しい 2 ファイルは先に `git add` する (flake は git に載ったファイルしか見ない)。

  Run: `nix build ./nix#checks.x86_64-linux.run-through-nudge-test --no-link -L 2>&1 | tail -3`
  Expected: `== 13 passed, 0 failed` を含み、build が成功する

  Run: `nix eval --json ./nix#homeConfigurations.sandbox.config.home.file --apply 'f: builtins.hasAttr ".claude/hooks/run-through-nudge.sh" f'`
  Expected: `true`

- [ ] **Step 6: 静的解析と commit**

  Run: `nix develop ./nix --command bash -c 'shfmt -d nix/files/claude/hooks/run-through-nudge.sh nix/tests/run-through-nudge.test.sh; shellcheck nix/files/claude/hooks/run-through-nudge.sh nix/tests/run-through-nudge.test.sh; nixfmt --check nix/flake.nix nix/home/modules/claude.nix'`
  Expected: 何も出ない

  commit: `feat(claude): superpowers の 4 つの skill を読んだ直後に、PR まで走り切るよう念を押す hook を足す (TKT-168)`

### Task 2: bootstrap-claude-hook.sh で hook を登録する

**Files:**
- Modify: `nix/scripts/bootstrap-claude-hook.sh`
- Modify: `nix/tests/bootstrap-claude-hook.test.sh`

**Interfaces:**
- Consumes: Task 1 の `~/.claude/hooks/run-through-nudge.sh` (配置済みで実行できること)
- Produces: settings.json の `hooks.PostToolUse` に `{matcher: "Skill", hooks: [{type: "command", command: "<HOME>/.claude/hooks/run-through-nudge.sh"}]}` が 1 件

- [ ] **Step 1: テストを直す** — `nix/tests/bootstrap-claude-hook.test.sh`
  - 先頭の「## 確かめること」: 「PostToolUse の 3 件 (Bash + if / Write / Skill)」に直し、「1 つ前の形 (ガードと解説動画の 2 件が登録済み) には Skill の 1 件だけを足す」「Skill の hook だけが配置されていないときも止まる」を足す
  - `new_home` の第 3 引数に `old` を足す (`nix-managed-guard.sh` と `video-offer-nudge.sh` だけを置き、`run-through-nudge.sh` は置かない)。`yes` は 3 つとも置く
  - 1: 空の settings.json → 既存の 3 条件に加え、matcher `Skill`・`if` なし・command が `run-through-nudge.sh` の hook が 1 件。ok の文は「空の settings.json にガードと PostToolUse の 3 件を登録する」
  - 3: 他の道具の hook に matcher `Skill` の PostToolUse (`orca-skill`) も足し、それが残ること・`.hooks.PostToolUse | length` が 5 (orca の 2 件 + 3 件) であること
  - 4: ガードだけ登録済み → `.hooks.PostToolUse | length` が 3
  - 4b (新): ガードと解説動画の 2 件が登録済み → `.hooks.PostToolUse | length` が 3、足されたのは matcher `Skill` の 1 件だけ (Bash と Write の件数はそれぞれ 1 のまま)
  - 5b (新): `old` (run-through-nudge.sh だけ無い) → rc が 0 でない・settings.json が `{}` のまま・err に `run-through-nudge.sh` と `home-manager switch` がある (err はファイルに落としてあるので `grep -q … "${h}/err"`)

- [ ] **Step 2: 失敗を確かめる**

  Run: `bash nix/tests/bootstrap-claude-hook.test.sh`
  Expected: 1・3・4・4b・5b が FAIL、exit 1

- [ ] **Step 3: bootstrap を直す** — `nix/scripts/bootstrap-claude-hook.sh`
  - 冒頭の「何を登録するか」に `PostToolUse  Skill  run-through-nudge.sh` と、その説明「superpowers の 4 つの skill を読んだ直後に、確認を挟まずに PR まで走り切るよう念を押す (ADR 019)」を足す
  - `run_through="${hooks_dir}/run-through-nudge.sh"` を足し、配置の確認の `for` に加える
  - `register PostToolUse "Skill" "" "${run_through}"` を `register PostToolUse "Write" "" "${nudge}"` の次に足す

- [ ] **Step 4: テストが通ることを確かめる**

  Run: `bash nix/tests/bootstrap-claude-hook.test.sh`
  Expected: すべて `ok`、`== 8 passed, 0 failed`、exit 0

  Run: `nix build ./nix#checks.x86_64-linux.bootstrap-claude-hook-test --no-link -L 2>&1 | tail -3`
  Expected: `== 8 passed, 0 failed` を含み、build が成功する

- [ ] **Step 5: 静的解析と commit**

  Run: `nix develop ./nix --command bash -c 'shfmt -d nix/scripts/bootstrap-claude-hook.sh nix/tests/bootstrap-claude-hook.test.sh; shellcheck nix/scripts/bootstrap-claude-hook.sh nix/tests/bootstrap-claude-hook.test.sh'`
  Expected: 何も出ない

  commit: `feat(nix): bootstrap-claude-hook.sh で run-through-nudge.sh を PostToolUse の Skill に登録する (TKT-168)`

### Task 3: CLAUDE.md の節と README

**Files:**
- Modify: `nix/files/claude/CLAUDE.md` (「## 応答の言語」の節の直後、「## 同梱 script の依存ツール」の前)
- Modify: `nix/README.md`

**Interfaces:**
- Consumes: Task 1 の hook の文が指す節の名前「方針を承認したら PR まで走り切る」(見出しは `## 方針を承認したら PR まで走り切る`)
- Produces: なし

- [ ] **Step 1: CLAUDE.md に節を足す** — ADR 019 §2 A の文面のまま (見出しから最後の「skill を読んだ直後には hook (…) も念を押してくる。」まで)。前後に空行を 1 つずつ。

- [ ] **Step 2: 生成物に節が入ることを確かめる**

  Run: `nix eval --raw ./nix#homeConfigurations.sandbox.config.home.file.'".claude/CLAUDE.md"'.text | grep -c '^## 方針を承認したら PR まで走り切る$'`
  Expected: `1`

  Run: 同じ eval の出力で、見出しの並びが「## 応答の言語」→「## 方針を承認したら PR まで走り切る」→「## 同梱 script の依存ツール」になっていること (`grep '^## '` で並びを出して目で見る)

- [ ] **Step 3: README を直す** — `nix/README.md`
  - bootstrap の表 (「Claude Code のフック登録（ガード・解説動画の知らせ）」の行) を「（ガード・解説動画の知らせ・走り切りの念押し）」にする
  - 「#### 解説動画を作るか聞くフック」の節の後ろ (「### statusLine」の前) に「#### 方針を承認したら PR まで走り切らせるフック」の節を足す。中身: `PostToolUse` フック (`nix/files/claude/hooks/run-through-nudge.sh`) が何をするか 1〜2 文、知らせる skill と差し込む文の要旨の表 (4 行)、黙る場面、正本は `~/.claude/CLAUDE.md` の節で hook は念押しであること、登録は `./nix/scripts/bootstrap-claude-hook.sh` が `hooks.PostToolUse` に 1 件 (`Skill`) 足すこと、経緯は ADR 019 へのリンク
  - ADR 019 の「運用手順」のリンク先 (`#方針を承認したら-pr-まで走り切らせるフック`) がこの見出しと合うこと

- [ ] **Step 4: commit**

  commit: `docs(claude): CLAUDE.md に「方針を承認したら PR まで走り切る」節を足し、README に hook を書く (TKT-168)`

### 仕上げの確認 (全タスクの後)

- [ ] `nix develop ./nix --command bash -c 'set -uo pipefail; mapfile -t files < <(find nix -type f -name "*.sh" | sort); shfmt -d "${files[@]}"; shellcheck "${files[@]}"'` と `nix develop ./nix --command bash -c 'find nix -name "*.nix" -print0 | xargs -0 nixfmt --check'` と `./nix/scripts/check-test-headers.sh` が何も指摘しない (CI の lint と同じ)
- [ ] 実機: `claude -p` に `--settings` で `run-through-nudge.sh` (この branch のファイル) を matcher `Skill` で登録し、4 つの skill を順に読ませて、`[走り切り]` で始まる文が 4 つとも届くことを見る (モデルに文を引用させる)。使える tool は `Skill` だけに絞る (finishing の文に従って本物の push や PR を作らせない)。結果を ADR 019 §6 の表に書く
