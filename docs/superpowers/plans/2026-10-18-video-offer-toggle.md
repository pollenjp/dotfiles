# 解説動画を答えを待たずに作り始めるかの host option 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `dotfiles.claude.videoOffer.autoStart.enable` (既定 false) で、解説動画を「作る前に聞く」(既定) か「答えを待たずに作り始める」かを選べるようにする。CLAUDE.md の節・hook の文・skill の流れがその値に従う。

**Architecture:** dotfiles が値を `~/.local/state/dotfiles/claude-video-offer.json` (`{"autoStart": <bool>}`) に置き、hook (dotfiles) と skill `pjp-video-explainer-offer` (claude-skills) が読む。ファイルが無い・壊れているときは「聞く」。CLAUDE.md の節は値によらない 1 つの文にし、skill は隠さない。

**Tech Stack:** Nix (home-manager の module・flake の `checks`・評価時の assert)、bash (shfmt / shellcheck)、jq、Markdown の skill (claude-skills の `scripts/lint.sh`)

**Spec:** `docs/adr/023_claude_video_offer_host_option_20261018T121637JST/README.md` (ADR 023。方針は 2026-10-18 に承認し直した。チケットは TKT-211)

## Global Constraints

- option は `options.dotfiles.claude.videoOffer.autoStart.enable`、`lib.types.bool`、`default = false`、`example = true`。前の版の `videoOffer.enable` は消す
- 状態ファイルは `home.file.".local/state/dotfiles/claude-video-offer.json".text = builtins.toJSON { autoStart = <bool>; } + "\n"`。いつも書く
- 読む側は `${HOME}/.local/state/dotfiles/claude-video-offer.json` の `.autoStart` が真偽値の `true` のときだけ「作り始める」。ほか (false・無い・壊れている・別の型) は「聞く」
- CLAUDE.md の節は 1 つ。見出し `## 解説動画を作るか聞く`、文は ADR 023 §2 B の「条件に合えば解説動画を作るかを聞く。答えを待たずに短尺を作り始めるのは、dotfiles でそう設定したマシンだけ (どちらにするかは skill が決める)」を入れる
- `claude-skill-overrides.json` は main と同じ `{"pjp-dev-tracker": …}` だけ (skill を隠さない)。`CLAUDE.video-offer.md` の切り出しはやめ、main と同じ 1 ファイルに戻す
- hook の文: 聞く側は TKT-124 の 3 文の「聞く条件に合えば」を「作る条件に合えば」にしたもの、作り始める側は今の 3 文のまま。`skillOverrides` が `off` / `user-invocable-only` なら黙る処理は残す
- skill の聞く流れの選択肢は「短く作る (2〜3 分)」「詳しく作る (5〜8 分)」「今回は作らない」「このセッションでは聞かない」。印のファイルは今と同じ `${XDG_STATE_HOME:-$HOME/.local/state}/pjp-video-offer/off-${CLAUDE_CODE_SESSION_ID}`
- open の PR #136・#137・#138 と衝突しない位置に足す (前の版で選んだ位置を保つ。flake の check は `cc-pages-state` の前)
- shfmt (2 空白・`binary_next_line`・`case_indent`)・shellcheck・nixfmt。テストの先頭に check の名前と「## 確かめること」。判定の `grep -q` をパイプの先に置かない。`./nix` を読む前に新しいファイルを `git add`
- commit は日本語の `<種類>(<範囲>): … (TKT-211)` と末尾の 2 行 (Co-Authored-By・Claude-Session)。claude-skills は branch `feat/TKT-211-video-offer-ask-first` を origin/main から切る

## Review Focus

- dotfiles の古いマシン・dotfiles の無いマシン (状態ファイルが無い): hook も skill も「聞く」になること (Task 2 のケース、Task 4 の文)
- 状態ファイルが壊れている・`autoStart` が文字列の `"true"`: 「作り始める」にならないこと (Task 2 のケース)
- 動いているセッション: CLAUDE.md は起動時のまま、hook と skill は今の値を読む。どちらの値でも食い違いが害にならない文であること (Task 1 の CLAUDE.md の文)
- 2 本の PR の片方だけ merge された間: PR の本文に、続けて merge することを書く (Task 5)
- worker (herdr の pane) の聞く流れ: AskUserQuestion を使わず報告に書き、答えが届くまで作らないこと (Task 4)

---

### Task 1: option・状態ファイル・CLAUDE.md の節 (dotfiles)

**Files:**
- Rename/Modify: `nix/tests/claude-skill-toggles.nix` → `nix/tests/claude-video-offer.nix` (check の名前 `claude-video-offer-state`)
- Modify: `nix/flake.nix` (checks の名前と import 先、テストの一覧のコメント)
- Modify: `nix/home/options.nix` (一覧の行と option)
- Modify: `nix/home/modules/claude.nix` (CLAUDE.md の連結と skill-overrides を main に戻し、状態ファイルを足す)
- Modify: `nix/files/claude/CLAUDE.md` / Delete: `nix/files/claude/CLAUDE.video-offer.md`

- [ ] **Step 1: テストを書き直す** — `configWith` は今のまま。組み合わせは `byDefault = configWith { }`、`auto = configWith { videoOffer.autoStart.enable = true; }`、`noTracker = configWith { devTracker.enable = false; }`。ケース:
  - `!byDefault.dotfiles.claude.videoOffer.autoStart.enable` / `auto.dotfiles.claude.videoOffer.autoStart.enable`
  - `fromJSON (state byDefault) == { autoStart = false; }` / `fromJSON (state auto) == { autoStart = true; }` / `hasSuffix "\n" (state byDefault)`
  - `md byDefault == md auto` (CLAUDE.md は値によらない)
  - 3 つとも `heading "## 解説動画を作るか聞く"` と `hasInfix "解説動画を作るかを聞く"`
  - `fromJSON (overrides byDefault) == { "pjp-dev-tracker" = "on"; }` (skill を隠さない)
  - `heading "## タスク管理" (md byDefault)` と `!hasInfix "## タスク管理" (md noTracker)` (devTracker の連結は main と同じ)
- [ ] **Step 2: 落ちることを確かめる** — `git add` して `nix build --no-link -L './nix#checks.x86_64-linux.claude-video-offer-state'` → 評価で落ちる (`autoStart` が無い)
- [ ] **Step 3: 実装する** — 上の Files のとおり。option の description は ADR 023 §2 A・B の要点
- [ ] **Step 4: 通ることを確かめる** — 同じ build が成功し、`ok   …` が全ケースぶん出る
- [ ] **Step 5: commit** — `feat(claude): 解説動画の option を「答えを待たずに作り始めるか」(videoOffer.autoStart.enable、既定 false) に変え、値を claude-video-offer.json に置く (TKT-211)`

### Task 2: hook の文を値で切り替える (dotfiles)

**Files:**
- Modify: `nix/tests/video-offer-nudge.test.sh` (`run` に `HOME` を渡し、状態ファイルを置く helper。既存のケースの期待を「聞く」文に。値ごとのケース)
- Modify: `nix/files/claude/hooks/video-offer-nudge.sh` (先頭のコメントと文の切り替え)

- [ ] **Step 1: テストを書く** — 既定 (ファイル無し) の 1・6・12 の期待を「PR の URL を返すときに解説動画を作るかを聞く」「承認を聞く前に解説動画を作るかを聞く」「レビューや承認を頼む前に解説動画を作るかを聞く」に変える。足すケース: `{"autoStart":true}` で 3 つの場面が「…解説動画の短尺を裏で作り始める」、`{"autoStart":false}` で「聞く」、壊れたファイル・`{"autoStart":"true"}` で「聞く」
- [ ] **Step 2: 落ちることを確かめる** — `bash nix/tests/video-offer-nudge.test.sh` で、変えた・足したケースのうち「聞く」側が FAIL
- [ ] **Step 3: 実装する** — `auto=$(jq -r '.autoStart == true' "${HOME}/.local/state/dotfiles/claude-video-offer.json" 2>/dev/null)` が `true` のときだけ作り始める文、ほかは聞く文
- [ ] **Step 4: 通ることを確かめる** — テストが全部通り、`nix build --no-link -L './nix#checks.x86_64-linux.video-offer-nudge-test'` が成功
- [ ] **Step 5: commit** — `feat(claude): video-offer-nudge.sh の文を claude-video-offer.json の autoStart で切り替え、既定は作るかを聞く (TKT-211)`

### Task 3: 雛形・案内・README・ADR (dotfiles)

**Files:** `nix/scripts/setup-local-flake.sh`・`nix/lib/mk-home.nix`・`nix/hosts/default.nix` (例と説明を `autoStart` に)、`nix/files/claude/hooks/nix-managed-guard.sh` (main に戻す)、`nix/scripts/bootstrap-claude-skill-overrides.sh` (解説動画の記述を外し、`/skills` の直しは残す)、`nix/README.md` (配置の表に状態ファイルの行・解説動画のフックの節に値ごとの文・`local` の段落・「skill を host ごとに止める」は devTracker だけに戻して `/skills` の直しは残す・上書きするキーの一覧とディレクトリ構成を main に戻す)、`docs/adr/007_…/README.md` (ポインタの文)、`docs/adr/README.md` (023 の行の文)、ADR 023 §6

- [ ] **Step 1: 直す** — 上のとおり
- [ ] **Step 2: 雛形を確かめる** — 使い捨ての dir に生成し、例の行のコメントを外して eval すると `autoStart.enable` が `true`
- [ ] **Step 3: まとめて確かめる** — `nix flake check --all-systems --no-build ./nix`、2 つの check の build、lint 一式 (nixfmt・shfmt・shellcheck・check-test-headers・check-test-grep-q)、このマシンのローカル flake を lock を書き換えずに eval (状態ファイルが `{"autoStart":false}`、CLAUDE.md に「解説動画を作るか聞く」、skill-overrides は dev-tracker だけ)
- [ ] **Step 4: commit** — `docs(nix): 解説動画の option を README・雛形・ADR 023 に合わせる (TKT-211)`

### Task 4: skill に「作る前に聞く」流れを戻す (claude-skills)

**Files:** `skills/pjp-video-explainer-offer/SKILL.md`・`skills/pjp-video-explainer-offer/references/brief.md`

- [ ] **Step 1: 振る舞いを確かめる問いを用意する** — superpowers:writing-skills に従い、「状態ファイルが無い・PR を作った直後」と「`{"autoStart":true}`・設計を出した直後」の 2 場面で、今の SKILL.md を読んだ subagent が何をするかを聞く (前者で作り始めてしまうことを確かめる)
- [ ] **Step 2: SKILL.md を直す** — §1 の前に「流れを決める」(状態ファイルを読む 1 行のコマンドと、true なら作り始める流れ、ほかは聞く流れ)。聞く流れは ADR 023 §2 D。worker (§5) の聞く場合。description に「作るかを聞く」を足す。brief.md の (A) / (B) の選び方
- [ ] **Step 3: 同じ 2 場面で確かめ直す** — 前者で聞き、後者で作り始めること
- [ ] **Step 4: lint** — `./scripts/lint.sh` が 0 error
- [ ] **Step 5: commit** — `feat(pjp-video-explainer-offer): 既定は解説動画を作る前に聞き、dotfiles で autoStart を入れたマシンだけ答えを待たずに作り始める (TKT-211)`

### Task 5: レビューと PR

- [ ] 2 repo の差分をまとめて最終レビューに出し、指摘を直す
- [ ] dotfiles は PR #139 に push してタイトルと本文を直す。claude-skills は push して PR を作る。どちらの本文にも、もう 1 本と続けて merge することを書く
- [ ] `ticket.sh pr TKT-211` (両方の repo で) と `link`
