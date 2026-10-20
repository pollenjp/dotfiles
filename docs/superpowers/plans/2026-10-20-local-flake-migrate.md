# ローカル flake を値を引き継いで今の雛形へ移す — 実装計画 (TKT-228)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 旧い `~/dotfiles/flake.nix` を、値を引き継いで今の setup-local-flake.sh の雛形の形へ移す script と skill を足し、
setup が旧い雛形を見つけたら移し方を案内する。

**Architecture:** 本体の `nix/scripts/local-flake-migrate.sh` が、雛形の各版を git の履歴から描き (実行しない)、
元の雛形を印か差分の最小で決めて `git merge-file --diff3` で 3-way merge し、旧い flake と移した flake を同じ lock で
評価して全ホストの drvPath を比べ、退避してから書く。setup-local-flake.sh は雛形に印を書き、setup-local-flake.sh と
setup.sh は `check` で旧い雛形を見つけて知らせる。skill は手順と判断 (衝突・評価の違い・確認) を教える。

**Tech Stack:** bash・awk・sed・cksum・git (`merge-file`・`show`・`log`)・nix (`eval`・`flake update`・`hash path`)

**Spec:** `docs/superpowers/specs/2026-10-20-local-flake-migrate-design.md`

## Global Constraints

- script は `#!/usr/bin/env bash` + `# shellcheck shell=bash`、`set -eu -o pipefail`。shfmt (`.editorconfig`: 2 字下げ・
  `binary_next_line`・`switch_case_indent`) と shellcheck を通す
- テストは `nix/tests/<名前>.test.sh`。先頭のコメントに `## 確かめること` を置く (check-test-headers.sh)。判定の
  `grep -q` をパイプの先に置かない (check-test-grep-q.sh。`grep -q … <<<"$(…)"` か、ファイルを直に渡す)。
  flake の checks は `scriptTest "<名前>" ./scripts` (サンドボックスの道具は bash・jq・git と stdenv のもの)
- `id`・`check` と、setup-local-flake.sh・setup.sh の追加分は、bash・awk・sed・cksum だけを使う (jq・git・nix を使わない)
- 古い版の setup-local-flake.sh を実行しない。版は awk で抜いて描く
- 印の行は `# 雛形の版: <8 桁の 16 進>`。開きの行は `  cat >"${flake_file}" <<EOS` (完全一致)。閉じは `EOS`
- 退避の名前は `flake.nix.bak-<YYYYmmddTHHMMSS>` と `flake.lock.bak-<同じ日時>`
- compare の終了コード: 0 = 同じ、1 = 違う、2 = 使い方の誤りなど、3 = 基準が評価できない、4 = 移した flake が評価できない
- skill の名前は `pjp-dotfiles-local-flake-migrate`。文言・コメント・文書は日本語で、この repo の書きぶりに合わせる
- `warn()` という名前の関数を local-flake-migrate.sh に作らない (warn-helpers.test.sh が warn() を持つ script を全部、
  setup のまとめの形で確かめる。この script は setup の手順ではない)

## Review Focus

- 利用者が印の行を消した・書き換えた flake.nix → 印が無いものとして差分の最小で元の版を決める (落ちない)。Task 3 にテスト
- `inputs.dotfiles.url` が script の repo と別の checkout を指す (worktree から流した) → 描き出しは url のパスで行い、
  そのことを出す。Task 3 にテスト
- `~/dotfiles/flake.lock` が無い → prepare は lock の写しを作らず、compare は `nix flake lock` で作り、apply は lock の
  退避を飛ばす。Task 4・Task 5 にテスト
- 作業場所を使い回した・衝突を解く前に compare / apply した → 分かる言葉で止まる。Task 3・Task 4・Task 5 にテスト
- 印は今の版と同じだが、中身を利用者が書き換えた flake.nix → `status`・`check` は「同じ版」、prepare は「移すものは無い」。
  Task 2・Task 3 にテスト

---

### Task 1: 雛形の描き出しと印 (`render`・`id`)

**Files:**
- Create: `nix/scripts/local-flake-migrate.sh`
- Create: `nix/tests/local-flake-migrate.test.sh`
- Modify: `nix/flake.nix` (checks に `local-flake-migrate-test = scriptTest "local-flake-migrate" ./scripts;`)

**Interfaces:**
- Produces (script の中の関数。後の Task が使う):
  - `template_raw <file|->` — 原文 (開きの行の次から `EOS` の前まで) を stdout。開きの行が 1 つでなければ 1
  - `template_id <file|->` — 原文の `cksum` の CRC を `printf '%08x'` した 8 桁
  - `template_render <file|-> <nix_dir>` — 展開を真似て描いたものを stdout。描けない展開があれば 1 (理由を stderr)
  - `repo_dir` — script の 2 つ上 (`resolve` で symlink を解いた実体から)
- Produces (CLI): `id [<file>|-]`、`render (--rev <rev> | --file <path>) --nix-dir <path>`

- [ ] **Step 1: テストを書く** — 使い捨ての `work` に偽の setup-local-flake.sh を作るヘルパ `fake_slf <path> <heredoc の中身>`
  (開きの行・中身・`EOS` を、ほかの行に挟んで書く) を置き、次のケースを書く
  - `render --file`: 中身 `path:${nix_dir}` / `id ${template_id}` / `\$env` / `\`x\`` / `a\\b` が
    `path:/N` / `id <その版の id>` / `$env` / `` `x` `` / `a\b` になる (`--nix-dir /N`)
  - `render` は `$HOME`・`${other}`・`$(date)`・`` `date` ``・`$1`・行末の `\` で 1 を返し、stderr に「描けない」
  - `id`: 8 桁の 16 進。heredoc の中の 1 文字を変えると変わり、heredoc の外の行を変えても変わらない。`id -` (stdin) も同じ値
  - 開きの行が無い・2 つあるファイルは `id` も `render` も 1
  - `render --rev <commit>`: 偽の repo (`<work>/repo`、`tgit` で commit) に写した script で、過去の commit の版を描ける
- [ ] **Step 2: 落ちるのを見る** — `bash nix/tests/local-flake-migrate.test.sh nix/scripts` → script が無いので FAIL
- [ ] **Step 3: 実装する** — 引数の解析 (`-h`・`--help` に使い方)、`template_raw` は awk の完全一致、`template_render` は
  1 行ずつ awk で 1 文字ずつ読む (`\` の次が `$`・`` ` ``・`\` ならその文字、行末の `\` は描けない、`$` の次が
  `{nix_dir}` / `{template_id}` なら置き換え、`$` の次が英字・数字・`_`・`{`・`(`・`@*#?$!-` なら描けない、
  `` ` `` は描けない)。`--rev` は `git -C "${repo_dir}" show "<rev>:nix/scripts/setup-local-flake.sh"`
- [ ] **Step 4: 通るのを見る** — 同じコマンドで全部 ok
- [ ] **Step 5: flake の checks に足し、`nix build ./nix#checks.x86_64-linux.local-flake-migrate-test` が通る**
- [ ] **Step 6: commit** — `feat(nix): 雛形の各版を描き、版の印を出す local-flake-migrate.sh を足す (TKT-228)`

### Task 2: 印の照合 (`status`・`check`)

**Files:** Modify `nix/scripts/local-flake-migrate.sh`・`nix/tests/local-flake-migrate.test.sh`

**Interfaces:**
- Consumes: `template_id`、`repo_dir`
- Produces:
  - `local_marker <flake.nix>` — `^# 雛形の版: ([0-9a-f]{8})` の最初の 1 つを stdout (無ければ空)
  - `local_nix_dir <flake.nix>` — `inputs.dotfiles.url = "path:<…>"` の `<…>` (setup.sh の `sync_local_flake_lock` と同じ sed)
  - CLI: `check [--flake <dir>]` (0 / 1 で「<旧い印か "印なし"> → <今の印>」の 1 行 / 2)、`status [--flake <dir>]`
    (0 / 1 / 2。1 のとき、印の版 (`git log` で印が合う commit と日付) か、印が無ければ最も近い版と差分の行数を出す)
  - `--flake` の既定は `${DOTFILES_LOCAL_DIR:-${HOME}/dotfiles}`

- [ ] **Step 1: テストを書く**
  - 印が今の版と同じ → `check` は 0 で何も出さない。`status` は 0 で「同じ版」
  - 印が過去の版 → `check` は 1 で旧い印と今の印を 1 行。`status` は 1 でその版の commit を出す
  - 印が無い → `check` は 1 で「印なし」。`status` は 1 で最も近い版と差分の行数
  - 印は今の版と同じで、中身を書き換えた → どちらも 0 (Review Focus)
  - `inputs.dotfiles.url` の `path:` が無い・flake.nix が無い → どちらも 2
  - `check` は PATH に git と nix が無くても動く (PATH を bash・awk・sed・cksum などの symlink だけにして流す)
- [ ] **Step 2: 落ちるのを見る**
- [ ] **Step 3: 実装する** (履歴の版の列挙は Task 3 の `history_revs` を先に作ってよい)
- [ ] **Step 4: 通るのを見る**
- [ ] **Step 5: commit** — `feat(nix): local-flake-migrate.sh に雛形の版を照合する status・check を足す (TKT-228)`

### Task 3: 移した flake を作る (`prepare`)

**Files:** Modify `nix/scripts/local-flake-migrate.sh`・`nix/tests/local-flake-migrate.test.sh`

**Interfaces:**
- Consumes: `template_*`、`local_marker`、`local_nix_dir`
- Produces:
  - `history_revs` — `git -C "${repo_dir}" log --format='%H' -- nix/scripts/setup-local-flake.sh` (新しい順)
  - `resolve_conflicts <diff3 の出力のファイル>` — spec 4 節の規則で解き、解いた結果を stdout、解いた数と残った数を
    stderr ではなく 3 番目の出力 (呼び出し側が渡すファイル) に `resolved=<n>` `remaining=<n>` で書く
  - 作業場所の形 (spec 3 節): `old/flake.nix`・`old/flake.lock`・`template.nix`・`base.nix`・`candidates.tsv`・
    `new/flake.nix`・`new/flake.lock`・`prepare.env` (`flake_dir=`・`old_sum=` (cksum の 1 列目と 2 列目)・`nix_dir=`・
    `base_rev=`・`base_how=marker|nearest`・`base_lines=`・`remaining=`)。値は `printf '%q'` で書き、読むときは `source`
  - CLI: `prepare [--flake <dir>] [--out <dir>]`。`--out` が在って空でなければ 2

- [ ] **Step 1: テストを書く** — 偽の repo に版 v1 (古い説明)・v2 (説明を 1 行直した)・v3 (今。印の行あり、`port` の例の
  直後に節を足し、例を 1 行移す) を commit し、v1 から作った flake.nix に利用者の直し (値を 2 つ、コメントを外す 1 つ) を当てる
  - 印が無い → 元は v1 (`base_how=nearest`)。`candidates.tsv` に 3 版。`new/flake.nix` に利用者の値と v3 の節・移した例・印の行
  - `port` のコメントを外した行の直後に v3 が節を足した衝突は自動で解く (`resolved=1`)。結果は「外した行 + 節」
  - 前に足した形・片側が消した形も解く。両側が同じ所に足した・同じ行を両側が直した衝突は印のまま残り (`remaining`)、
    prepare の出力に `new/flake.nix` の行番号が出る
  - 印あり (v2 から作った flake.nix) → 元は v2 (`base_how=marker`)。v2 の印が履歴に無い値なら nearest に落ちて理由を出す
  - 印の行を消した・書き換えた → nearest (Review Focus)
  - 元と今が同じ版 → 「移すものは無い」で 0、作業場所を作らない
  - url が script の repo と別のパス → 描き出しは url のパスで、出力にその旨 (Review Focus)
  - `--out` に空でないディレクトリ → 2 (Review Focus)。`flake.lock` が無い → `old/flake.lock` を作らずに進む
  - `old/flake.nix` は元のファイルとバイト単位で同じ
- [ ] **Step 2: 落ちるのを見る**
- [ ] **Step 3: 実装する** — 差分の行数は `diff <old> <rendered> | grep -c '^[<>]'` (diff の rc 1 は正常)。merge は
  `git merge-file -p --diff3 -L 手元 -L 元の雛形 -L 今の雛形 old base template`。rc が負 (255) なら 2 で止まる。
  `resolve_conflicts` は awk で印 4 種を読み、O・B・T を配列に集めて spec 4 節の規則で出す
- [ ] **Step 4: 通るのを見る**
- [ ] **Step 5: commit** — `feat(nix): local-flake-migrate.sh prepare で、元の雛形を決めて 3-way merge する (TKT-228)`

### Task 4: 評価して比べる (`compare`)

**Files:** Modify `nix/scripts/local-flake-migrate.sh`・`nix/tests/local-flake-migrate.test.sh`

**Interfaces:**
- Consumes: 作業場所と `prepare.env`
- Produces:
  - `compare.result` (`new_sum=`・`baseline_dir=`・`baseline_sum=`・`baseline_is_old=0|1`・`result=same|differ`)
  - nix の呼び方 (テストの偽の nix がこの形を前提にする):
    - `nix hash path --sri --type sha256 <nix_dir>`
    - `nix flake update dotfiles --flake <dir>` / `nix flake lock --flake <dir>`
    - `nix eval --raw "path:<dir>#homeConfigurations" --apply <要約の式>` → 行ごとに `drv<TAB><host><TAB><drvPath>` と
      `warn<TAB><host><TAB><警告 (改行は \n)>`
    - `nix eval --raw "path:<dir>#homeConfigurations" --apply <dotfiles の式>` → `<パス><TAB><値の JSON>` の行。式は
      `builtins.getAttr "<host>" hs` で選ぶ
  - CLI: `compare <作業場所> [--baseline <dir>]`。`<dir>` は flake.nix を持つ (flake.lock が無ければ `old/flake.lock` を写す)

- [ ] **Step 1: テストを書く** — 偽の nix (`fake-bin/nix`): 呼び出しを `nix-calls` に書く。`eval` の要約は、`<dir>/flake.nix` の
  コメントでない行の cksum を drvPath にし、ホストは `# FAKE_HOSTS: a b` (既定 `h1 h2`)、警告は `# FAKE_WARN: <文>`、
  評価の失敗は `# FAKE_EVAL_ERROR: <文>` (stderr に `error: <文>`、rc 1)。dotfiles の式は `dotfiles.<パス> = <値>;` の行を返す
  - コメントだけ違う → 0、「同じ」、`compare.result` の `result=same`・`new_sum` が今の cksum
  - 値が違う → 1、そのホストと `<パス>  <旧> → <新>`
  - ホストの集合が違う → 1、足された・消えたホストの名前
  - 基準の評価が落ちる → 3、「旧い flake (基準) は今の本体 … で評価できない」と `error:` の行
  - 移した flake の評価が落ちる → 4
  - `new/flake.nix` に印が残っている → 2 で止まり、nix を呼ばない (Review Focus)
  - `--baseline` を渡すと、その flake.nix と比べ、`baseline_is_old=0`
  - 警告: 基準だけにある警告は「移して消えた」、移した側の警告は「移した flake にある」
  - lock: 本体の hash が lock に無いときだけ `flake update dotfiles` を呼ぶ。lock が無いと `flake lock` (Review Focus)
- [ ] **Step 2: 落ちるのを見る**
- [ ] **Step 3: 実装する** — 要約の式と dotfiles の式は spec 5 節。dotfiles の式は、属性の集合 (`outPath` を持つものは除く) を
  たどって `パス<TAB>builtins.toJSON 値` を並べ、関数は `"<function>"`。TSV の比べは `sort` と `awk`
- [ ] **Step 4: 通るのを見る**
- [ ] **Step 5: 実物で 1 度流す** — この PC の `~/dotfiles/flake.nix` の写しで prepare → compare (Task 9 で記録する)
- [ ] **Step 6: commit** — `feat(nix): local-flake-migrate.sh compare で、旧い flake と移した flake の全ホストの drvPath を比べる (TKT-228)`

### Task 5: 退避して書く (`apply`)

**Files:** Modify `nix/scripts/local-flake-migrate.sh`・`nix/tests/local-flake-migrate.test.sh`

**Interfaces:**
- Consumes: `prepare.env`・`compare.result`
- Produces: CLI `apply <作業場所> [--accept-changes]`。書くのは `prepare.env` の `flake_dir`

- [ ] **Step 1: テストを書く**
  - prepare のあとに flake.nix を書き換えた → 止まり、ファイルは変わらない
  - `new/flake.nix` に印が残る → 止まる
  - compare をしていない・compare のあとに `new/flake.nix` を直した → 止まる
  - compare が違う (or `--baseline`) → `--accept-changes` が無ければ止まり、あれば書く
  - 書けたとき: `flake.nix.bak-<日時>`・`flake.lock.bak-<日時>` が元と同じ中身、flake.nix が `new/flake.nix` と同じ、
    flake.lock は変わらない、出力に `cp -p` の戻すコマンド 2 つ。flake.lock が無いときは lock の退避を飛ばす (Review Focus)
- [ ] **Step 2: 落ちるのを見る**
- [ ] **Step 3: 実装する** — 日時は `date +%Y%m%dT%H%M%S`。置き換えは同じディレクトリの `mktemp` から `mv`
- [ ] **Step 4: 通るのを見る**
- [ ] **Step 5: commit** — `feat(nix): local-flake-migrate.sh apply で、退避してからローカル flake を書き換える (TKT-228)`

### Task 6: 雛形に印を書き、setup-local-flake.sh が旧い雛形を知らせる

**Files:**
- Modify: `nix/scripts/setup-local-flake.sh` (先頭のコメント・heredoc の先頭・既にあるときの警告)
- Create: `nix/tests/setup-local-flake.test.sh`
- Modify: `nix/flake.nix` (checks に `setup-local-flake-test = scriptTest "setup-local-flake" ./scripts;`)

**Interfaces:**
- Consumes: `local-flake-migrate.sh id <file>`・`check --flake <dir>`
- Produces: 雛形の先頭のコメントの印の行と案内 (spec 1 節の 4 行)。`template_id` は heredoc の前で計算する

- [ ] **Step 1: テストを書く** (写した `<work>/repo/nix/scripts/` に 2 つの script を置き、`DOTFILES_LOCAL_DIR`・
  `DOTFILES_ALLOW_ANY_PATH=1`・使い捨ての HOME で流す)
  - 新しく作った flake.nix に `# 雛形の版: <id>` があり、`<id>` は `local-flake-migrate.sh id` と同じ
  - 作った flake.nix は `local-flake-migrate.sh render --file <setup-local-flake.sh> --nix-dir <repo>/nix` と同じ
  - もう一度流す (印が同じ) → 「flake.nix: 既にあります」で、印の警告は出ない
  - 印を別の値にした・印の行を消した → `!! flake.nix は前の雛形から作られています` と移し方 (`local-flake-migrate.sh prepare`
    と `pjp-dotfiles-local-flake-migrate`) の警告。ファイルは変わらない。`DOTFILES_SETUP_WARNINGS` にも同じ行
  - `--force` で作り直すと印が今の値になる
  - `hostsWith` の無いファイル → 今の警告 (直し方に移し方を含む)
- [ ] **Step 2: 落ちるのを見る**
- [ ] **Step 3: 実装する** — heredoc に印の 4 行を足す。`id` を計算できなければ `die`。既にあるときは `check` の rc で分ける
- [ ] **Step 4: 通るのを見る** (local-flake-migrate.test.sh も、今の雛形の描き出しが変わっても通る)
- [ ] **Step 5: commit** — `feat(nix): ローカル flake の雛形に版の印を入れ、旧い雛形なら移し方を知らせる (TKT-228)`

### Task 7: setup.sh が旧い雛形を知らせる (通ったとき・switch が落ちたとき)

**Files:**
- Modify: `nix/scripts/setup.sh` (`post_notes`・`execute` の失敗の案内・新しい関数 `local_flake_stale`)
- Modify: `nix/tests/setup-post-notes.test.sh` (引数を `nix/scripts` のディレクトリにする。`cksum` を `sys_bin` に足す)
- Modify: `nix/flake.nix` (`setup-post-notes-test = scriptTest "setup-post-notes" ./scripts;`)

**Interfaces:**
- Consumes: `local-flake-migrate.sh check --flake <dir>` (0 / 1 / 2)
- Produces: `local_flake_stale` — ローカル flake があり (`flake_dir != nix_dir`)、`${script_dir}/local-flake-migrate.sh` が
  実行でき、`check` が 1 なら 0。案内の文は「前の雛形から作られています」(今の案内の「古い雛形」と別の言葉にする。
  既存のテスト 10 が「古い雛形」の有無を見ている)

- [ ] **Step 1: テストを書く** (ケースの checkout に local-flake-migrate.sh と setup-local-flake.sh も写すヘルパを足す)
  - `--steps bootstrap-a` が通り、ローカル flake の印が旧い → 残りの手作業に「前の雛形から作られています」と
    `local-flake-migrate.sh prepare`
  - 印が今と同じ → 出ない
  - `--steps local-flake` を選んだ → 残りの手作業には出さない (setup-local-flake.sh の警告がまとめに載る)
  - 偽の home-manager が 1 を返す switch → 失敗の案内のあとに stderr で「前の雛形から作られています」と option の
    削除・改名の言葉と移し方。印が今と同じなら出ない
  - 既存のケース (1〜19) が今どおり通る
- [ ] **Step 2: 落ちるのを見る**
- [ ] **Step 3: 実装する**
- [ ] **Step 4: 通るのを見る**
- [ ] **Step 5: commit** — `feat(nix): setup がローカル flake の旧い雛形を、通ったときと switch が落ちたときに知らせる (TKT-228)`

### Task 8: skill `pjp-dotfiles-local-flake-migrate`

**Files:** Create `nix/files/claude/skills/pjp-dotfiles-local-flake-migrate/SKILL.md`

**Interfaces:**
- Consumes: Task 1〜5 の CLI。RED の結果 (この会話の subagent の報告。TKT-228 のメモにも残す)

- [ ] **Step 1: RED を読む** — skill なしの subagent が何をしたか (確認・退避・確かめ方・値の扱い) をメモにする
- [ ] **Step 2: SKILL.md を書く** — spec 9 節の構成。RED で見えた失敗に当てる (確認を取らずに書く・退避しない・
  評価で確かめない・`--force` で作り直す、など見えたもの)
- [ ] **Step 3: GREEN** — 同じ場面 (使い捨ての本体の clone とこの PC の flake の写し) を、skill を読ませた subagent に流す。
  apply の前で確認の問いを出して止まること、compare で同じと確かめたことを見る。もう 1 つ、本体の clone で
  `ccPages.port` の option を消した場面 (旧い flake が評価できない) を流し、基準を作って `--baseline` で比べ直すことを見る
- [ ] **Step 4: REFACTOR** — 抜けた所を足して、外れたケースを流し直す
- [ ] **Step 5: commit** — `feat(claude): ローカル flake を今の雛形へ移す pjp-dotfiles-local-flake-migrate skill を足す (TKT-228)`

### Task 9: 文書と、実物での確かめ

**Files:**
- Modify: `nix/README.md` (「このマシンだけの設定 (`local`)」の箇条と、新しい小節「雛形が新しくなったら」)
- Create: `docs/adr/024_local_flake_template_migrate_<JST の日時>/README.md`、Modify: `docs/adr/README.md` (一覧)

- [ ] **Step 1: README と ADR を書く** (ADR の節は README.md の表のとおり。検証の節に実物の結果を書く)
- [ ] **Step 2: 実物で確かめる** — この PC の `~/dotfiles/flake.nix`・`flake.lock` を scratchpad に写し、`--flake <写し>` で
  `status` → `prepare` → `compare` → `apply` (写しに対して) を流す。元の版 (87922f9 か 870b317)・自動で解いた衝突 1・
  残り 0・7 ホストの drvPath が同じ、を記録する。~/dotfiles には書かない
- [ ] **Step 3: lint とテストを全部流す** — `nix develop ./nix --command shfmt -d <変えた sh>`・`shellcheck`・`nixfmt --check`・
  `./nix/scripts/check-test-headers.sh`・`nix develop ./nix --command ./nix/scripts/check-test-grep-q.sh`・
  `nix flake check --no-eval-cache ./nix` (このマシンの system)
- [ ] **Step 4: commit** — `docs(nix): ローカル flake の雛形の版の印と移し方を README と ADR 024 に書く (TKT-228)`
