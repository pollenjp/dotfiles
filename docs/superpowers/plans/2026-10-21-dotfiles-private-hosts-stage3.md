# 段階 3: setup の推測をやめ、公開の登録簿から実機を外す — 実装計画 (TKT-267)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** setup が推測で公開の登録簿のホストを選ぶのをやめ (決まらなければ止めて 3 つの道を案内する)、公開の登録簿から実機 3 つを
外し、PC の値を dotfiles-private の登録かローカル flake の `tmp` の 1 か所にだけ書く形にする (dotfiles 側。spec の 1〜6)。

**Architecture:** `setup.sh` の `detect_host` から推測の段を消し、決まらないときは「この実行の手順のあとの決め直しで決まりうるか」
(`host_may_resolve`) で止める時機を分ける (決まりようがなければ execute の前、決まりうれば switch の頭)。雛形は `local` を持たず
`dotfiles.homeConfigurations // privateHosts // { … }` を重ねるだけにし、tmp の例は値を `mkHome` の引数に直に書く。
Dev Tracker は本体の既定を false にし、使う所 (sandbox・登録したファイル・tmp) で true を書く。

**Tech Stack:** bash (3.2 でも動く書き方。setup.sh のホストの判定は Nix より前に走る)・awk・sed・Nix (module system・flake の checks)

**Spec:** `docs/superpowers/specs/2026-10-21-dotfiles-private-hosts-stage3-design.md`

## Global Constraints

- script は `#!/usr/bin/env bash` + `# shellcheck shell=bash`、`set -eu -o pipefail`。shfmt (`.editorconfig`) と shellcheck を通す。
  パイプの先に `grep -q`・`head` を置かない (変数に取ってから `<<<`)。Bash tool で `bash -c '…'` を使わない (script にして `bash <file>`)
- テストは `nix/tests/<名前>.test.sh` / `<名前>.nix`。先頭のコメントに `## 確かめること`。判定の `grep -q` をパイプで受けない。
  fixture は `nix/tests/fixtures/` の下。`.nix` は nixfmt を通す (fixture も)
- **公開の repo に private の値を書かない**: PC の hostname・Windows のユーザー名・登録した PC の名前を、新しく書くもの (spec・ADR・
  commit・PR の本文・テスト・fixture) と今回触るファイルに入れない (触るファイルに既にある値は作り物か `<ホスト>` などにする)。
  Notion の URL は `https://app.notion.com/p/<id>` の形。テストの値は作り物 (`alice@box` など)
- ADR の本文・過去の plans / specs・出力済みの図 (`plantuml/` の `.puml` と `out/`) は書き換えない (注記を足すのは可)
- setup.sh のホストの判定は nix・jq を使わない (ファイルの有無・sed・grep・bash)
- 決める順: `--host` (`DOTFILES_HOST`・メニューの `h`) → ローカル flake のホスト (`local`) → dotfiles-private のこの PC のホスト
  (`private`)。どれも無ければ止める (終了コード 1)。`host_source` の値から `guess` が無くなる
- 雛形の `homeConfigurations` は `dotfiles.homeConfigurations // privateHosts // { … }`。`lib.hostsWith` は本体に残す (前の雛形が呼ぶ)
- `dotfiles.claude.devTracker.enable` の既定は false。`sandbox` は `claude.devTracker.enable = true;` と `claude.notion.profile = "personal";`
- ユーザーの環境を動かさない: `~/dotfiles/setup` を本物の HOME で流さない。`~/dotfiles/flake.{nix,lock}`・main の checkout・
  dotfiles-private の clone に書かない。テストは偽の HOME・一時ディレクトリで流す

## Review Focus

- 登録してあるのにローカル flake が clone を読んでいない (前の雛形・stub) PC で `--update` → 取得も switch もせずに execute の前で
  止まり、先に移す案内 (`local-flake-migrate.sh prepare`・skill) を出す。Task 5 にテスト
- Nix の無い新しいマシン・clone の無いマシン・決め直しの手順を選んでいない実行で、ホストが決まらない → execute の前に止まる
  (Nix を入れてから・preflight-unlink のあとに止めない)。Task 5 にテスト
- WSL の上 (`/proc/version` に microsoft・`WSL_DISTRO_NAME`) で、登録簿に `<user>@wsl` があっても選ばない。Task 5 にテスト
- `local` に値を書いた前の雛形 (ADR 026 の版) を今の雛形へ移す → 値は黙って消えず、衝突として残る。Task 4 にテスト
- 前の雛形のローカル flake (`hostsWith [ local ]`) が新しい本体で評価できる (`hostsWith` は残し、登録簿は型と sandbox だけ)。
  Task 2 で `lib.hostsWith` が評価できることを nix eval で確かめる

---

### Task 1: Dev Tracker の既定を false にする

**Files:**
- Modify: `nix/home/options.nix` (`devTracker.enable` の既定・説明・`example`。`windowsUserName` の `example` 2 つを作り物に。
  `local` に触れる説明 (notion.profile・videoOffer・cleanup・ccPages.port・wsl.enable・windowsUserName) を今の置き場所に)
- Modify: `nix/home/modules/claude.nix` (notion.profile の warning の直し方の文)
- Modify: `nix/hosts/default.nix` (sandbox に `claude.devTracker.enable = true;`)
- Test: `nix/tests/claude-notion.nix`・`nix/tests/claude-video-offer.nix`・`nix/tests/host-draft.nix`

**Interfaces:**
- Produces: `config.dotfiles.claude.devTracker.enable` の既定 false。sandbox の値は true (CI の「warnings が空」が Dev Tracker の経路を通る)

- [ ] **Step 1: テストを直す** — claude-notion.nix: warnings を見るケースは `devTracker.enable = true` を明示した config で
  (`tracker = configWith { devTracker.enable = true; }`・`onlyRoutes`/`onlyOverride` にも true を足す)、新しいケース
  「既定 (devTracker.enable = false) では、profile が null でも warnings は出ない」= `!(warnsAboutProfile byDefault)`。
  claude-video-offer.nix: `claude-skill-overrides.json` は既定で `{ "pjp-dev-tracker" = "off"; }`、`devTracker.enable = true` で `"on"`。
  「タスク管理」の節は true の config にあり、既定と false には無い。host-draft.nix: 「既定と同じ値も集める」の確かめを dave
  (`devTracker.enable = false`) の `claude.devTracker.enable` が集まることで見る (carol の true は既定と違う値になる)
- [ ] **Step 2: 落ちることを確かめる** — `nix build ./nix#checks.x86_64-linux.claude-notion-state` が「合わない項目」で落ちる
- [ ] **Step 3: 実装** — options.nix の既定 false。claude.nix の warning は「dotfiles-private に登録したホストのファイルか
  ~/dotfiles/flake.nix の tmp に claude.notion.profile = "personal"; (か "work") を書く」形 (1 行目の `dotfiles.claude.notion.profile` は残す)
- [ ] **Step 4: 通ることを確かめる** — claude-notion-state・claude-video-offer-state・host-draft-state を build。
  `nix eval --json './nix#homeConfigurations.sandbox.config.warnings'` が `[]`
- [ ] **Step 5: commit**

### Task 2: 公開の登録簿から実機を外す

**Files:**
- Modify: `nix/hosts/default.nix` (`pollenjp@wsl`・`pollenjp@wsl-no-1password`・`pollenjp@laptop` を消し、先頭のコメントを今の形に)
- Modify: `nix/lib/mk-home.nix` (例の `windowsUserName` を作り物に。claude の既定と local の段落を今の形に)
- Modify: `nix/flake.nix` (x86_64-linux の checks に `home-wsl-example`。hostsWith・lib・packages のコメントを今の形に)
- Test: `nix/tests/one-password.nix`
- Modify: `nix/tests/pjp-agent-link.test.sh` (実機の名前の値 (Windows のユーザー名@hostname・NixOS の実機の hostname) を作り物に。
  spec の「4.」の「ほかに実機の名前を使っているテスト」。振る舞いは変えない)

**Interfaces:**
- Produces: `checks.x86_64-linux.home-wsl-example` = 作り物の `mkHome { username = "user"; system = "x86_64-linux";
  wsl = { enable = true; windowsUserName = "user"; windowsFiles.enable = true; exeExecTrace.enable = true; };
  onePassword.enable = true; }` の activationPackage。`homeConfigurations` には出さない

- [ ] **Step 1: テストを直す** — one-password.nix の登録簿の 2 ケースを消し、作り物の 4 通りにする: 既存の none・native・wsl に
  `wslNone = configWith { wsl.enable = true; }` を足し、「WSL で 1Password を使わないなら署名もラッパーも書き出さない」
  (`hasNoSigning wslNone && !(hasWrappers wslNone)`) と「4 通りの onePassword.enable は none・wslNone で false、native・wsl で true」。
  op-ssh-sign のパスと windowsUserName は作り物 (`alice`)
- [ ] **Step 2: 実装** — 登録簿・mk-home.nix・flake.nix
- [ ] **Step 3: 確かめる** — one-password-state を build。`bash nix/tests/pjp-agent-link.test.sh` が通る。
  `nix eval ./nix#checks.x86_64-linux.home-wsl-example.drvPath` が出る。
  `nix eval --json ./nix#homeConfigurations --apply builtins.attrNames` が型 3 つと sandbox。
  `nix eval ./nix#lib.hostsWith --apply 'f: builtins.attrNames (f [ { dotfiles.claude.devTracker.enable = false; } ])'` が同じ 4 つ
- [ ] **Step 4: commit**

### Task 3: ローカル flake の雛形から local を外す

**Files:**
- Modify: `nix/scripts/setup-local-flake.sh` (雛形・既存ファイルへの `hostsWith`/`notion.profile` の警告を外す・先頭のコメント)
- Create: `nix/tests/fixtures/local-flake-tmp/tmp.nix` (雛形の tmp の例のコメントを 1 段外したものを `{ dotfiles }: { … }` で包む)
- Create: `nix/tests/local-flake-tmp.nix` (checks の `local-flake-tmp-state`)
- Modify: `nix/flake.nix` (`local-flake-tmp-state` を足し、`setup-local-flake-test` に fixture も渡す)
- Test: `nix/tests/setup-local-flake.test.sh`

**Interfaces:**
- Produces: 雛形の tmp の例は `        # tmp = dotfiles.lib.mkHome {` から次の `        # };` まで。1 段外す = 行頭の `        #` と、
  その後ろの空白 1 つを外す。fixture はその行を 2 字下げして `{ dotfiles }:\n{\n` と `}` で包む (nixfmt の形)
- Produces: setup-local-flake.test.sh の第 2 引数 = fixture のパス (省けば `<here>/fixtures/local-flake-tmp/tmp.nix`)

- [ ] **Step 1: テストを書く** — setup-local-flake.test.sh に: 新しい flake.nix に `local =`・`hostsWith` が無く、
  `homeConfigurations = dotfiles.homeConfigurations // privateHosts // {` がある。先頭のコメントに `~/dotfiles#<ホスト>`。tmp の例を
  1 段外したものが fixture の中身と同じ。既にある flake.nix に `hostsWith`・`notion.profile` が無くても、それの警告を出さない
  (ケース 6 を置き換える)。local-flake-tmp.nix に: fixture の `tmp` を `mkHome` で組むと評価でき (drvPath が出る)、
  `wsl.{enable,windowsFiles.enable,exeExecTrace.enable}`・`onePassword.enable`・`claude.devTracker.enable` が true、
  `claude.notion.profile == "personal"`、`config.warnings == [ ]`
- [ ] **Step 2: 落ちることを確かめる** — `bash nix/tests/setup-local-flake.test.sh` が新しいケースで落ちる
- [ ] **Step 3: 実装** — 雛形 (spec の「2.」の例に並べるもの。gitViaGh・routes・override・videoOffer・ccPages.port は例の中の
  コメント。tmp の例の説明は今の `local` の説明を写す)。fixture は nixfmt を通した形に雛形を合わせる
- [ ] **Step 4: 通ることを確かめる** — setup-local-flake.test.sh・local-flake-tmp-state・setup-local-flake-test (check)
- [ ] **Step 5: commit**

### Task 4: 前の雛形 (ADR 026 の版) から今の雛形へ移す

**Files:**
- Create: `nix/tests/fixtures/local-flake-migrate/template-adr026.txt` (ADR 026 の版の heredoc の原文。tmp の例の Windows の
  ユーザー名だけ作り物に替える)
- Modify: `nix/flake.nix` (`local-flake-migrate-test` に fixture のディレクトリも渡す)
- Modify: `nix/scripts/local-flake-migrate.sh` (sandbox を比べない理由のコメントを今の形に。比べ方は変えない)
- Test: `nix/tests/local-flake-migrate.test.sh`

**Interfaces:**
- Consumes: Task 3 の今の `setup-local-flake.sh` (`${dir}/setup-local-flake.sh`)
- Produces: local-flake-migrate.test.sh の第 2 引数 = fixture のディレクトリ (省けば `<here>/fixtures/local-flake-migrate`)

- [ ] **Step 1: テストを書く** — 使い捨ての repo に fixture の heredoc の偽の setup-local-flake.sh を commit し、作業ツリーに今の
  setup-local-flake.sh を置く。(A) その版を描いた flake (local は既定のまま) を prepare → 衝突 0、new/flake.nix は今の雛形を同じ
  `--nix-dir`・`--private-dir` で描いたものと同じ。(B) local の `notion.profile = null` を `"work"` にした flake → 残りの衝突が 1 件以上で、
  new/flake.nix の衝突の中に `"work"` の行がある
- [ ] **Step 2: 確かめる** — `bash nix/tests/local-flake-migrate.test.sh nix/scripts nix/tests/fixtures/local-flake-migrate` が通る
  (移す仕組みは変えないので、テストを足すだけで通る見込み。落ちたら systematic-debugging)
- [ ] **Step 3: commit**

### Task 5: setup の推測をやめ、止めて案内する

**Files:**
- Modify: `nix/scripts/setup.sh`
- Test: `nix/tests/setup-host.test.sh`・`nix/tests/setup-post-notes.test.sh`

**Interfaces:**
- Produces (setup.sh): `detect_host` は local → private だけ (無ければ 1)。`is_wsl` を消す。
  `host_may_resolve` — Nix があり、手順のあとに「この PC のファイルがある」(今ある、か private-fetch を選び clone の `.git` がある) と
  「ローカル flake が clone を読む」(今読む、か local-flake を選びローカル flake がまだ無く clone がある) がそろいうれば 0。
  `host_undecided` — 止める文を stderr に出す (clone にこの PC のファイルがあるのに読んでいなければ、それと移す案内を先に。
  続けて 3 つの道: 1. 登録 (pjp-dotfiles-register-host。登録の前の 1 回は 3)・2. `~/dotfiles/flake.nix` に tmp
  (ローカル flake が無ければ先に `--steps local-flake`)・3. `--host <型>` と型の名前 (登録簿から sandbox を除く))。
  `ensure_host_registered` は host が空なら `host_undecided` で 1。main: switch を選び host が空なら `host_may_resolve` でなければ
  execute の前に `host_undecided` で exit 1。`--which-host` も決まらなければ `host_undecided` で 1
- Produces: post_notes から `hostsWith`/`notion.profile` の grep と `hm_warnings_read` を外す。推測の行・`guess`・usage・
  見出しの「未判定」・execute の「対象ホスト」の未定の文を今の形に

- [ ] **Step 1: テストを書く** — setup-host.test.sh: ケース 2 は「決まらず 1 で、3 つの道 (`pjp-dotfiles-register-host`・tmp・
  `--host <型>` と `alice@x86_64-linux`) を出す」(入力が stub・入力が無い・別の clone・未登録・ローカル flake が無い、と
  `WSL_DISTRO_NAME` を渡した場合)。ケース 4 から「推測」を外す。新しいケース: (a) clone にこの PC のファイルがあり stub を指す
  ローカル flake で `--update` → execute の前に 1、stderr に `local-flake-migrate.sh prepare` と 3 つの道、`==> 実行する手順` が出ない。
  (b) nix が無い PATH で `--update` → execute の前に 1。(c) clone が無い (`DOTFILES_PRIVATE_DIR` が無い場所) → execute の前に 1。
  (d) `--steps switch` (決め直しの手順なし) → execute の前に 1。ケース 10・11 は最初が未定 (`<未定> → alice@box`)。ケース 12 は
  登録が消えると switch で止まり (1。home-manager を呼ばない)、`--host` は決め直さない。setup-post-notes.test.sh: ケース 7・8 を
  「hostsWith・notion.profile の語が無いローカル flake でも、残りの手作業に古い雛形の案内を出さない」1 つに置き換える
- [ ] **Step 2: 落ちることを確かめる** — `bash nix/tests/setup-host.test.sh` (WSL の上で) が新しいケースで落ちる
- [ ] **Step 3: 実装**
- [ ] **Step 4: 通ることを確かめる** — setup-host.test.sh・setup-post-notes.test.sh を WSL の上と checks (サンドボックス) で
- [ ] **Step 5: commit**

### Task 6: private-host.sh と下書きを local の無い形に

**Files:**
- Modify: `nix/scripts/private-host.sh` (inspect: setup が決まらないときは「決まらない (setup は止まる)」、`guess` を消す、local が無い
  flake は「local: 無い (今の雛形)」。draft・compare の「+ local」の文を前の雛形のときだけの書き方に)
- Modify: `nix/lib/host-draft.nix` (下書きの頭のコメントの 2・3 行目から local を外す) と `nix/tests/fixtures/host-draft/*.nix`
- Test: `nix/tests/private-host.test.sh`・`nix/tests/host-draft.nix`

- [ ] **Step 1: テストを書く** — private-host.test.sh: register_case の登録簿・flake はそのまま (前の雛形の形) で、新しいケース
  「今の雛形 (local なし・tmp なし) の flake で inspect は local が無いと出し、setup の選ぶホストは『決まらない (setup は止まる)』、
  draft は notes なしで描く」
- [ ] **Step 2: 落ちることを確かめる**
- [ ] **Step 3: 実装** — fixture は render の新しい頭のコメントに合わせる
- [ ] **Step 4: 通ることを確かめる** — private-host.test.sh・host-draft-state
- [ ] **Step 5: commit**

### Task 7: 文書

**Files:**
- Create: `docs/adr/027_stop_guessing_host_<JST の作成時刻>/README.md`。Modify: `docs/adr/README.md` (一覧)
- Modify: ADR 002・007・026 の冒頭の表 (後続 ADR)、ADR 022 の §5 の注意と §7 の手順の直前に注記
- Modify: `README.md`・`nix/README.md`・`win/README.md`・`docs/adr/001_*/textbook/0{2,3,4,5}_*.md`・`nix/pjp-env/dotfiles.txt`

- [ ] **Step 1: ADR 027** — 背景 (推測・実機が public・local の重ね方)・決定 (spec の 1〜5 と「こちらの判断」)・変更点・代替案
  (Dev Tracker の案 B など)・影響・検証 (Task 9 の結果)・移行 (merge の前に登録した PC を移す・merge の後に各 PC で移す)
- [ ] **Step 2: 注記** — ADR README の「後続 ADR」の書き方 (何が変わり、本文は当時の記録として残した) に揃える
- [ ] **Step 3: README 類** — 推測・登録簿の実機・`local` の記述を今の形に。消えたホストを打つ例は `<ホスト>` か型に。
  `nix/README.md` の herdr の節の実機の値 (hostname・Windows のユーザー名) を一般の書き方に。新しい PC の初回の流れ
  (読める PC: `--host <型>` で 1 回 → 登録 → merge → 移す → `--update`。読めない PC: tmp を書いてから setup)
- [ ] **Step 4: 確かめる** — 触ったファイルに実機の値が無い (`git grep` で hostname・Windows のユーザー名・`pollenjp@wsl` など)
- [ ] **Step 5: commit**

### Task 8: skill 2 つ

**Files:**
- Modify: `nix/files/claude/skills/pjp-dotfiles-register-host/SKILL.md`・`nix/files/claude/skills/pjp-dotfiles-local-flake-migrate/SKILL.md`

- [ ] **Step 1: register-host** — 型を元にする新しい PC の登録 (WSL なら `wsl` の値を足し、windowsFiles・exeExecTrace・onePassword は
  ユーザーに聞く。Dev Tracker を使うなら `claude.devTracker.enable = true`。compare は足した分だけ 1)。元にするホストが段階 3 で
  消えた PC は段階 3 の前の本体を `git archive <rev> nix` で写して draft・compare (rev は `git log --format=%h -1 <ADR 027 の merge>^`
  のように引く)。手順 6 の 4 は新しい雛形では tmp の値を外す。推測の記述を直す
- [ ] **Step 2: local-flake-migrate** — 段階 3 の雛形へ移すときの local の塊 (登録した PC は雛形どおり消える・値が残る PC は
  衝突になり、tmp か登録へ移す) と compare の読み方 (local の値が型のホストから消える分)
- [ ] **Step 3: commit**

### Task 9: 確かめて PR

- [ ] **Step 1** — lint (devShell の nixfmt --check・shfmt -d・shellcheck を script ファイルで)・`check-test-headers.sh`・
  `check-test-grep-q.sh`・`bootstrap-windows-files.sh --check`
- [ ] **Step 2** — `nix flake check --all-systems --no-build ./nix`。x86_64-linux の checks を build (`nix flake check --no-eval-cache ./nix`)。
  sandbox の warnings が `[]`
- [ ] **Step 3** — 手元の script のテストを WSL の上で全部流す (`bash nix/tests/<名前>.test.sh`)
- [ ] **Step 4** — 写しで評価する確かめ (読むだけ): 本物の `~/dotfiles` の写しで `private-host.sh inspect`・
  `local-flake-migrate.sh compare` (この branch の本体で)
- [ ] **Step 5** — 別の reviewer (subagent) に branch 全体を見てもらい、指摘を直す
- [ ] **Step 6** — push (gh の資格情報)・PR (本文に「merge の前に」の節)・`ticket.sh pr`・CI を待つ
