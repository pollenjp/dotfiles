# ホストの定義と値を dotfiles-private へ移す (段階 1) — 実装計画 (TKT-257)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 登録した PC が `--host` を付けなくても dotfiles-private の `nix/hosts/<user>@<hostname>.nix` のホストで switch
し、PC を登録する手順を skill `pjp-dotfiles-register-host` と script で教える (dotfiles 側。spec の 1〜5 と 7)。

**Architecture:** 本体の `lib.privateHosts` が dotfiles-private の `nix/` (ローカル flake の 2 つ目の `path:` 入力。
clone が無ければ本体の空の stub) の `hosts/*.nix` からホストを作り、雛形がそれを登録簿と手で足したホストの間に重ねる。
setup.sh は switch の前に clone を取得し、`<user>@<hostname>` のファイルがあってローカル flake がその clone を読んでいれば
そのホストを選ぶ。登録の決まった処理 (名前・調べる・下書き・評価して比べる) は `nix/scripts/private-host.sh` と
`nix/lib/host-draft.nix` が持ち、skill は判断と確認の取り方を受け持つ。

**Tech Stack:** bash (3.2 でも動く書き方。setup.sh と private-host.sh の `name`・`dir`・`input-dir`)・awk・sed・Nix
(module system の `options`・`highestPrio`、`builtins.readDir`・`builtins.toFile`)・nix CLI (`eval --impure`・`flake update`・`hash path`)

**Spec:** `docs/superpowers/specs/2026-10-20-dotfiles-private-hosts-design.md`

## Global Constraints

- script は `#!/usr/bin/env bash` + `# shellcheck shell=bash`、`set -eu -o pipefail`。shfmt (`.editorconfig`) と shellcheck を通す。
  pipefail の下でパイプの先に `grep -q`・`head` を置かない (変数に取ってから `<<<` で渡す。pjp-shell-traps)
- テストは `nix/tests/<名前>.test.sh` / `<名前>.nix`。先頭のコメントに `## 確かめること`。判定の `grep -q` をパイプで
  受けない。fixture は `nix/tests/fixtures/` の下 (check-test-headers.sh は tests 直下のファイルだけを見る)。
  `.nix` は nixfmt を通す
- 本体は public: script・テスト・skill・文書に実機の値 (ホスト名・Windows のユーザー名・option の値) を書かない。
  テストの値は作り物 (`alice@box` など)
- setup.sh のホストの判定は Nix より前でも動く (nix・jq を使わない。ファイルの有無と sed・grep・bash)
- dotfiles-private の clone の場所: `$DOTFILES_PRIVATE_DIR` → `$(ghq root)/github.com/pollenjp/dotfiles-private` →
  `~/ghq/github.com/pollenjp/dotfiles-private` (bootstrap-*.sh の `private_dir()` と同じ)
- この PC の名前: `<user>@<短い hostname>`。user は `${USER:-$(id -un)}`、hostname は macOS なら
  `scutil --get LocalHostName`、ほかは `uname -n` の最初の `.` まで。決め方は `private-host.sh name` だけが持つ
- ローカル flake の入力の名前は `dotfiles-private`。書き方は 2 行:
  `inputs.dotfiles-private.url = "path:<dir>";` と `inputs.dotfiles-private.flake = false;`
- 雛形の heredoc に足す展開は `${private_nix_dir}` だけ。stub は `<本体>/nix/private-stub` (README.md だけを置く)
- `homeConfigurations` の重ね順: `hostsWith [ local ]` → `privateHosts dotfiles-private` → このマシンだけのホスト (後ろが勝つ)。
  private のホストには `local` を当てない
- private-host.sh compare の終了コード: 0 = 同じ、1 = 違う、2 = 使い方の誤り、3 = 旧い形が評価できない、
  4 = 新しい形が評価できない (local-flake-migrate.sh compare と揃える)
- ユーザーの `~/dotfiles` と dotfiles-private の clone に書かない。実機で試すときは scratchpad の写し
- `warn()` は setup の手順の script だけが持つ (private-host.sh は setup の手順ではないので作らない。warn-helpers.test.sh)

## Review Focus

- ローカル flake が private を読んでいない (入力が無い・stub を指す) のに clone にこの PC のファイルがある → 推測へ落ち、
  残りの手作業で直し方を出す。`--host <その名前>` なら「登録されていません」に dotfiles-private の案内を添える。Task 5 にテスト
- clone が無い PC (会社の PC・新しい PC) → `--update` の private-fetch は何もせず、switch のあとの
  bootstrap-dotfiles-private が今までどおり 1 回だけ取る (警告が 2 回出ない)。Task 5 にテスト
- `hosts/` が無い・空・`.nix` でないファイルがある private → ホストは `{ }` か `.nix` だけ。Task 1 にテスト
- `local` に dotfiles の外の行 (`programs.git…`) がある・旧名の option (`wsl.onePassword.enable`) を使う → 下書きは外の行を
  コメントで知らせ、旧名は新しい名前で書く (派生する既定値 `wsl.onePassword.windowsUserName` は書かない)。Task 2・Task 6 にテスト
- 雛形が今の版でも、private の入力が stub のまま clone に `nix/` ができた → status が 1、prepare が指し直す。Task 4 にテスト

---

### Task 1: 本体の `lib.privateHosts` と stub

**Files:**
- Create: `nix/lib/private-hosts.nix`、`nix/private-stub/README.md`
- Create: `nix/tests/private-hosts.nix`、`nix/tests/fixtures/private-hosts/hosts/{alice@one.nix,bob@two.nix,README.md}`
- Modify: `nix/flake.nix` (`privateHosts` を `lib` に足し、checks に `private-hosts-state`)

**Interfaces:**
- Produces: `import ./lib/private-hosts.nix { inherit lib mkHome; }` → `privateNix -> attrset`。`privateNix` は path か
  `outPath` を持つ attrset (flake = false の input)。`"${privateNix}/hosts"` の `*.nix` (directory でないもの) ごとに
  `import <file> { inherit mkHome; }`、名前はファイル名から `.nix` を除いたもの。`hosts/` が無ければ `{ }`
- Produces: flake の `lib = { inherit mkHome hostsWith privateHosts; }`

- [ ] **Step 1: テストを書く** — `nix/tests/private-hosts.nix` (`{ lib, pkgs, privateHosts }` を受け、flake.nix から
  `self` の `privateHosts` を渡す。one-password.nix と同じ assert + runCommand の形)。fixture は
  alice@one (`username = "alice"`・`claude.notion.profile = "work"`・`modules = [ { dotfiles.ccPages.port = 7801; } ]`) と
  bob@two (`wsl = { enable = true; windowsUserName = "bob"; }`)、system は x86_64-linux。cases:
  - `builtins.attrNames (privateHosts ./fixtures/private-hosts) == [ "alice@one" "bob@two" ]` (README.md は拾わない)
  - alice の `config.home.username == "alice"`・`config.dotfiles.ccPages.port == 7801`・`claude.notion.profile == "work"`
  - bob の `config.dotfiles.wsl.enable`
  - `privateHosts (builtins.path { name = "private-empty"; path = ./fixtures/private-hosts; filter = _: type: type == "directory"; }) == { }`
  - `privateHosts ../private-stub == { }`
- [ ] **Step 2: 落ちることを確かめる** — `nix eval ./nix#checks.x86_64-linux.private-hosts-state.drvPath` が
  `privateHosts` が無いことで落ちる
- [ ] **Step 3: 実装** — `nix/lib/private-hosts.nix`、stub の README.md (何の代わりか・指し直し方)、flake.nix の配線
- [ ] **Step 4: 通ることを確かめる** — `nix build --no-link ./nix#checks.x86_64-linux.private-hosts-state` と
  `nix develop ./nix --command nixfmt --check nix/lib/private-hosts.nix nix/tests/private-hosts.nix nix/tests/fixtures/private-hosts/hosts/*.nix`
- [ ] **Step 5: commit**

### Task 2: 下書きを描く `nix/lib/host-draft.nix`

**Files:**
- Create: `nix/lib/host-draft.nix`、`nix/tests/host-draft.nix`
- Modify: `nix/flake.nix` (checks に `host-draft-state`)

**Interfaces:**
- Produces: `import ./lib/host-draft.nix { inherit lib; }` → `{ collect; render; }`
  - `collect = options: [ { path = [ "claude" "devTracker" "enable" ]; value = true; } … ]` — `options` は
    `<host>.options.dotfiles`。`_type == "option"` の葉のうち `visible != false` (改名の旧名を除く)・`isDefined`・
    `highestPrio < 1500` (option の既定だけでなく定義がある。既定と同じ値を書いたものも入る) を path の辞書順で
  - `render = { name, username, system, homeDirectory ? null, base ? null, values, notes ? [ ] }: string` — 下書きの本文。
    頭のコメント (何のファイルか・`base` があれば元にしたホスト・`notes` の各行)、`{ mkHome, ... }:` と `mkHome { … }`。
    `path` の頭が `wsl`・`onePassword`・`claude` の値は mkHome の引数の組 (組の値が 1 つなら `onePassword.enable = true;`、
    2 つ以上なら `claude = { devTracker.enable = true; … };`)、ほかは `modules = [ { dotfiles.<path> = <値>; … } ];`
    (いつも複数行)。値は Nix の字句 (文字列は `lib.strings.escapeNixString`、名前は `escapeNixIdentifier`)。
    字句にできない値 (関数・derivation・path) は `# TODO: dotfiles.<path> は値を書き出せない (…)` の行。nixfmt で変わらない形

- [ ] **Step 1: テストを書く** — `nix/tests/host-draft.nix` (`{ lib, pkgs, mkHome, system }`)。cases:
  - 元のホスト = `mkHome { username = "carol"; inherit system; onePassword.enable = true; modules = [ local ]; }`、
    `local` は `dotfiles.claude.devTracker.enable = true`・`dotfiles.claude.notion.profile = "work"`・`dotfiles.ccPages.port = 7801`。
    `collect` の path が `[claude.devTracker.enable claude.notion.profile ccPages.port onePassword.enable]` (辞書順で)
  - `render { name = "carol@box"; username = "carol"; inherit system; base = "carol@generic"; values = …; }` が期待の文字列と
    1 字も違わない (期待はテストに書く)
  - その文字列を `import (builtins.toFile "draft.nix" text) { inherit mkHome; }` で評価した `activationPackage.drvPath` が
    元のホストと同じ。port を 7802 に置き換えた文字列では違う
  - WSL のホスト (`wsl = { enable = true; windowsUserName = "dave"; windowsFiles.enable = true; }; onePassword.enable = true;`) は
    `wsl.onePassword.windowsUserName` (派生する既定値) を集めず、描いて戻した drvPath が同じ
  - 旧名 `dotfiles.wsl.onePassword.enable = true` を local に書いたホストは、`onePassword.enable` として集め
    `wsl.onePassword.enable` を集めない
  - `values` に関数の値があれば `# TODO: dotfiles.` の行になる
- [ ] **Step 2: 落ちることを確かめる** (host-draft.nix が無い)
- [ ] **Step 3: 実装**
- [ ] **Step 4: 通ることを確かめる** — `nix build --no-link ./nix#checks.x86_64-linux.host-draft-state` と nixfmt --check
- [ ] **Step 5: commit**

### Task 3: `private-host.sh` の軽いコマンド (`name`・`dir`・`input-dir`)

**Files:**
- Create: `nix/scripts/private-host.sh`、`nix/tests/private-host.test.sh`
- Modify: `nix/flake.nix` (checks に `private-host-test = scriptTest "private-host" ./scripts;`)

**Interfaces:**
- Produces (CLI): `private-host.sh name` (stdout `<user>@<短い hostname>`。決められない・`[A-Za-z0-9._-]` 以外を含むなら 1)、
  `dir` (clone の場所。いつも 0)、`input-dir [--nix-dir <本体の nix>]` (`<clone>/nix` が directory ならそれ、無ければ
  `<nix-dir>/private-stub`。`--nix-dir` の既定は script の repo の `nix/`)
- Produces (関数): `short_hostname`・`this_host_name`・`private_dir` (bootstrap-*.sh の `private_dir()` と同じ本文)

- [ ] **Step 1: テストを書く** — 偽の `uname` (`-n` は `FAKE_UNAME_N`、`-s` は `FAKE_UNAME_S` (既定 Linux)、`-m` は x86_64)・
  偽の `scutil`・偽の `ghq` を PATH に置く。cases:
  - `USER=alice`・`uname -n` が `box.example.test` → `alice@box`
  - Darwin で scutil が `Alices-Mac` → `alice@Alices-Mac`。scutil が無い・空なら `uname -n` の `.` まで
  - hostname に空白や `/` があれば 1 で、理由を stderr に出す
  - `dir`: `DOTFILES_PRIVATE_DIR=/x/` → `/x`、ghq root `/g` → `/g/github.com/pollenjp/dotfiles-private`、どちらも無い → `$HOME/ghq/…`
  - `input-dir`: clone に `nix/` があればそれ、無ければ `<repo>/nix/private-stub`、`--nix-dir /n` なら `/n/private-stub`
  - `private_dir()` の本文が bootstrap-ssh-config.sh・bootstrap-windows-ssh-config.sh・bootstrap-windows-google-ime.sh の
    `private_dir()` と 1 字も違わない (bootstrap-dotfiles-private.sh の `resolve_dir()` は `private_dir()` に改名して並べる)
- [ ] **Step 2: 落ちることを確かめる** — `bash nix/tests/private-host.test.sh`
- [ ] **Step 3: 実装** (usage は `-h`。サブコマンドの無い呼び出しは usage を stderr に出して 2)。
  bootstrap-dotfiles-private.sh の `resolve_dir` → `private_dir` の改名もここで
- [ ] **Step 4: 通ることを確かめる** — `bash nix/tests/private-host.test.sh` と bootstrap-dotfiles-private.test.sh、shfmt・shellcheck
- [ ] **Step 5: commit**

### Task 4: 雛形の private の入力 (setup-local-flake.sh・local-flake-migrate.sh)

**Files:**
- Modify: `nix/scripts/setup-local-flake.sh`、`nix/scripts/local-flake-migrate.sh`
- Modify: `nix/tests/setup-local-flake.test.sh`、`nix/tests/local-flake-migrate.test.sh`

**Interfaces:**
- Consumes: `private-host.sh input-dir --nix-dir <nix_dir>` (Task 3)、`dotfiles.lib.privateHosts` (Task 1)
- Produces (雛形): `inputs.dotfiles-private.url = "path:${private_nix_dir}";`・`inputs.dotfiles-private.flake = false;`・
  `outputs = { dotfiles, dotfiles-private, ... }:`・`homeConfigurations = dotfiles.lib.hostsWith [ local ] // dotfiles.lib.privateHosts dotfiles-private // { … };`。
  `local` の説明に「dotfiles-private にこの PC のホストがあるときは、そのホストには当たらない」
- Produces (local-flake-migrate.sh): `template_render <file> <nix_dir> <private_nix_dir>`、`render … [--private-dir <dir>]`
  (既定は `private-host.sh input-dir --nix-dir <nix-dir>`。private-host.sh が無ければ `<nix-dir>/private-stub`)、
  `local_private_dir <flake.nix>` (`inputs.dotfiles-private.url` の path。無ければ空)。
  `status` は印が同じでも private の入力が `input-dir` と違えば (無いときも) 1 で「指し直すには prepare」。
  `prepare` は元の雛形を旧いファイルの private の入力 (無ければ `input-dir`) で、今の雛形を `input-dir` で描き、印が同じでも
  入力が違えば移す。`compare` の lock の張り直しは `path:` 入力ぜんぶ (hash が lock に無い入力をまとめて
  `nix flake update <名前>… --flake path:<写し>`、lock が無ければ `nix flake lock`)。移した flake だけにあるホストのうち、
  移した flake の private の入力の `hosts/<名前>.nix` があるものは「dotfiles-private のホスト」と出して違いに数えない。
  移した flake が `<この PC の名前>.nix` を読み、基準が読まないなら「移したあと setup は --host なしで <名前> を選ぶ」と出す

- [ ] **Step 1: テストを足す** — setup-local-flake.test.sh: `new_case` に private-host.sh も写す。clone が無ければ
  `inputs.dotfiles-private.url = "path:<repo>/nix/private-stub";`、`DOTFILES_PRIVATE_DIR` の clone に `nix/` があれば
  `path:<clone>/nix` で、どちらも render --file (同じ `DOTFILES_PRIVATE_DIR`) と 1 バイトも違わない。
  local-flake-migrate.test.sh: render が `${private_nix_dir}` を `--private-dir` で描く・status が「印は同じで入力が stub、
  clone に nix/ がある」で 1・prepare がその入力だけを指し直す (ほかの行は変えない)・compare の偽の nix で、private の入力の
  hash が lock に無ければ `flake update dotfiles-private --flake path:`、両方なら `flake update dotfiles dotfiles-private`・
  移した flake だけの private のホストは違いに数えない (0) が、private に無い片側だけのホストは今までどおり 1
- [ ] **Step 2: 落ちることを確かめる**
- [ ] **Step 3: 実装** (setup-local-flake.sh の先頭のコメント・書いたときの 1 行 (指した先と stub の意味) も)
- [ ] **Step 4: 通ることを確かめる** — 2 つのテスト、shfmt・shellcheck。描いた雛形を写した flake.nix が nixfmt で変わらないこと
- [ ] **Step 5: commit**

### Task 5: setup.sh — switch の前の取得とホストの決め方

**Files:**
- Modify: `nix/scripts/setup.sh`、`nix/scripts/bootstrap-dotfiles-private.sh` (先頭のコメントだけ)
- Create: `nix/tests/setup-host.test.sh`
- Modify: `nix/flake.nix` (checks に `setup-host-test = scriptTest "setup-host" ./scripts;`)

**Interfaces:**
- Consumes: `private-host.sh name`・`dir` (Task 3)、雛形の入力の書き方 (Task 4)
- Produces (CLI): 手順 `private-fetch` (表では preflight-unlink の後・local-flake の前。プリセットの new-machine と update に入る。
  clone (`<dir>/.git`) があれば bootstrap-dotfiles-private.sh を流し、そのあとの手順 bootstrap-dotfiles-private は
  「switch の前に取得した」と出して飛ばす。clone が無ければ何もしない)。
  `--which-host` (`<ホスト>\t<決め方>` を出して 0、決まらなければ 1。決め方は `--host`・`DOTFILES_HOST`・`local`・`private`・`guess`・`menu`)
- Produces (関数): `private_init` (起動時に名前と clone の場所を取る)・`local_flake_private_input`・`local_flake_reads_private`
  (入力が `<clone>/nix` を指し、そこが directory)・`private_clone_hosts`・`private_hosts` (読んでいるときだけ)・
  `this_pc_in_private`・`host_origin` (`local`・`private`・空)・`host_source`
- 決め方: `--host` → `DOTFILES_HOST` → ローカル flake のホスト → private のこの PC のホスト (`this_pc_in_private` かつ
  `local_flake_reads_private`) → 推測。`build_rebuild_args` は `--host` を `host_source` が `option`・`menu` のときだけ渡す
- 一覧: `list_hosts` = 登録簿 + `private_hosts` + ローカル flake のホスト (重複と sandbox を除く)。メニューの `h` の下にも
  dotfiles-private の場所を出す。`ensure_host_registered` は、clone にそのファイルがあるのに読んでいないときに直し方を添える
- 表示: ヘッダは `(dotfiles-private / h で変更)`、実行の前は `対象ホスト: X  (dotfiles-private の <clone>/nix/hosts/X.nix で定義)`
- 知らせ: (A) 残りの手作業 — この PC のファイルが clone にあり、ローカル flake があり、読んでいない → 入力の状態・推測に
  落ちたこと (推測のときだけ)・直し方 (`local-flake-migrate.sh prepare`、pjp-dotfiles-register-host の最後の手順)。
  (B) 警告 (まとめの `[対象ホスト]` にも) — `host_source` が `option`・`env`・`menu`、この PC のファイルが clone にあり、
  選んだホストがその名前と違う → 登録した名前・当てるホスト・値の出どころ・`--host` を外せば登録したホストになること
- `sync_local_flake_lock`: `path:` 入力ぜんぶを見て、hash が lock に無い入力をまとめて `nix flake update <名前>… --flake <dir>`。
  `dotfiles-private` の入力の指す先が無ければ警告 (clone し直すか local-flake-migrate.sh で指し直す)

- [ ] **Step 1: テストを書く** — `nix/tests/setup-host.test.sh` (setup-post-notes.test.sh と同じ作り: 使い捨ての checkout に
  setup.sh・private-host.sh・偽の bootstrap-*.sh、登録簿は `alice@x86_64-linux`・`alice@wsl`、偽の uname で `box`、USER=alice、
  clone は `DOTFILES_PRIVATE_DIR`)。cases:
  - `--which-host`: 読んでいる → `alice@box	private`、ローカル flake にホスト → `tmp	local`、`DOTFILES_HOST` → env、`--host` → `--host`
    (env に勝つ)、入力が stub・入力が無い・clone にこの PC のファイルが無い → `alice@x86_64-linux	guess`
  - (A): 入力が stub で `--steps bootstrap-a` → 残りの手作業に `alice@box` と `local-flake-migrate.sh prepare` と
    `pjp-dotfiles-register-host`。読んでいれば出ない
  - (B): `--host alice@x86_64-linux --steps bootstrap-a` → stderr とまとめ (`[対象ホスト]`) に `alice@box`。`--host alice@box`・
    登録していない PC では出ない
  - `--host alice@box --steps switch --dry-run`: 読んでいれば通り `switch --flake <local>#alice@box` を出す。読んでいなければ 1 で、
    stderr に dotfiles-private の案内
  - `--update --dry-run`: 「実行する手順」で `dotfiles-private を取得 (switch の前)` が `home-manager switch` より前、
    `+ …/bootstrap-dotfiles-private.sh` が switch のコマンドより前、後ろの bootstrap-dotfiles-private は「switch の前に取得した」。
    clone が無ければ private-fetch は何もせず、後ろの bootstrap-dotfiles-private のコマンドが出る
  - `--update` (dry-run でない。偽の home-manager・nix、偽の bootstrap-dotfiles-private.sh は warn して 0): 0 で終わり、
    その警告はまとめに 1 回だけ
  - lock: 偽の nix (`hash path <p>` は `sha256-<p/.fakehash の中身>`、ほかは呼び出しを書く)。private の入力だけずれる →
    `flake update dotfiles-private --flake`、両方 → `flake update dotfiles dotfiles-private --flake`、合っている → update なし
- [ ] **Step 2: 落ちることを確かめる** — `bash nix/tests/setup-host.test.sh`
- [ ] **Step 3: 実装** (usage の「対象ホストの決め方」・`--which-host`・環境変数 `DOTFILES_PRIVATE_DIR` も)
- [ ] **Step 4: 通ることを確かめる** — setup-host・setup-post-notes・bootstrap-herdr-hub・git-github-helpers・warn-helpers の
  テスト、shfmt・shellcheck
- [ ] **Step 5: commit**

### Task 6: `private-host.sh` の登録のコマンド (`inspect`・`draft`・`compare`)

**Files:**
- Modify: `nix/scripts/private-host.sh`、`nix/tests/private-host.test.sh`

**Interfaces:**
- Consumes: `nix/lib/host-draft.nix` (Task 2。描くときは script の repo のものを `--impure` で import)、`setup.sh --which-host` (Task 5)
- Produces (CLI):
  - `inspect [--flake <dir>]` — この PC (名前・system・WSL なら Windows のユーザー名)、clone (場所・この PC のファイル・
    登録してあるホスト)、ローカル flake (雛形の版・本体・private の入力の状態・手で足したホスト・`local` のコメントでない行)、
    setup が今選ぶホスト (`setup.sh --which-host`)、今の世代 (`${XDG_STATE_HOME:-~/.local/state}/nix/profiles/home-manager`
    → 無ければ `/nix/var/nix/profiles/per-user/$USER/home-manager`) と `activationPackage.outPath` が一致するホスト
    (ローカル flake の写しで評価。lock が本体と合わなければ張り直して評価し、そう出す)。0
  - `draft --base <ホスト> [--flake <dir>] [--name <名前>] [--nix-dir <本体の nix>] [--out <ファイル>] [--force]` —
    写しを評価して `collect` → `render` (notes に `local` の dotfiles の外の行)。`--out` は在れば `--force` が無いと 2。
    評価できなければ原因の行を出して 3
  - `compare --base <ホスト> --private <dotfiles-private の作業ツリーか nix/> [--name <名前>] [--flake <dir>] [--nix-dir <本体の nix>] [--out <作業場所>]` —
    旧い形 = ローカル flake の写し (`inputs.dotfiles.url` を `--nix-dir` (既定は script の repo の nix/) へ書き換え) の `<base>`、
    新しい形 = `dotfiles.lib.privateHosts` だけを出す flake (同じ本体・旧い形の lock を写して張り直す) の `<名前>`。
    drvPath を比べ、違えば `config.dotfiles` の違いを「旧い → 新しい」で出す。参考に今の世代との一致を出す。
    終了コードは Global Constraints

- [ ] **Step 1: テストを足す** (偽の nix。local-flake-migrate.test.sh と同じく、写しの flake.nix に書いた印で評価の答えを変える):
  - inspect: 名前・clone の状態・`local` の行 (`dotfiles.claude.devTracker.enable = true;`)・手で足したホスト・private の入力の状態
    (stub / clone / 無い)・setup の選ぶホスト・偽の profile の世代と一致するホストを出す。ユーザーの flake.nix と lock を変えない
  - draft: `--out` に書く・在れば `--force` なしで 2・`local` の `programs.git…` の行を notes に渡す (nix に渡した式に入る)・
    評価が落ちれば 3
  - compare: 同じ → 0 と「中身は変わらない」、違う → 1 と `config.dotfiles` の違い、旧い形が落ちる → 3、新しい形が落ちる → 4、
    `--private` に `nix/hosts/<名前>.nix` が無ければ 2。新しい形の flake.nix が `--nix-dir` と `<private>/nix` を指す・旧い形の写しの
    `inputs.dotfiles.url` が `--nix-dir` を指す・ユーザーの flake を変えない・ずれた入力だけ `flake update` する
- [ ] **Step 2: 落ちることを確かめる**
- [ ] **Step 3: 実装**
- [ ] **Step 4: 通ることを確かめる** — テスト、shfmt・shellcheck
- [ ] **Step 5: 実機で確かめる (書き込まない)** — scratchpad に `~/dotfiles` の flake.nix・lock を写し、`inspect --flake <写し>` が
  今の世代と一致するホストを出す。`draft` を scratchpad の偽の private (`<s>/private/nix/hosts/<名前>.nix`) に書き、
  `compare --base <一致したホスト> --private <s>/private --flake <写し>` が 0。setup-local-flake.sh を `DOTFILES_LOCAL_DIR=<s>/local`
  `DOTFILES_PRIVATE_DIR=<s>/private` で流した雛形で `setup.sh --which-host` が `<名前>	private`、`nix eval` の drvPath が compare と同じ
- [ ] **Step 6: commit**

### Task 7: skill `pjp-dotfiles-register-host`

**Files:**
- Create: `nix/files/claude/skills/pjp-dotfiles-register-host/SKILL.md`
- Modify: `nix/files/claude/skills/pjp-dotfiles-local-flake-migrate/SKILL.md` (private の入力の指し直しと、compare の
  「dotfiles-private のホスト」の読み方)

**Interfaces:**
- Consumes: `private-host.sh` の全コマンド (Task 3・6)、`local-flake-migrate.sh` (Task 4)、`setup.sh --which-host`・`--steps private-fetch` (Task 5)

- [ ] **Step 1: RED** — skill なしの subagent に、scratchpad の写しの PC (ローカル flake・偽の private の作業ツリー) で
  「この PC を dotfiles-private に登録して」をさせ、確認を取らずに書く・比べ方を外す、などの振る舞いを記録する
- [ ] **Step 2: 書く** — 手順 1〜6 (spec の 5) と、どの会話がどこまでするか (spec のこちらの判断 8: 1・2・6 は PC の会話、
  3〜5 は dotfiles-private の worktree。集約ハブや別の repo からは pjp-herdr-other-repo で子に下書きを渡す)、
  書く前の確認 (下書き・ローカル flake の書き換え)、既にある PC の直し方、秘密と private の値を public に書かない決まり、
  merge 後の `local` の外し方と `setup --update` の確かめ方。RED で出た抜けを禁止の形で書く
- [ ] **Step 3: GREEN** — 同じ場面を skill を読ませた subagent で流し、確認の前で止まる・script で比べることを確かめ、
  出た抜けを足す
- [ ] **Step 4: commit**

### Task 8: 文書 (ADR 025・README など)

**Files:**
- Create: `docs/adr/025_dotfiles_private_hosts_<JST の日時>/README.md`
- Modify: `docs/adr/README.md`・`docs/adr/002_*/README.md` (後続 ADR)・`nix/README.md`・`README.md`・`nix/hosts/default.nix`
  (先頭のコメント)・`nix/lib/mk-home.nix` (claude の説明の local の行)

- [ ] **Step 1: ADR 025** — 背景・決定 (private に置く・ローカル flake の 2 つ目の path: 入力と stub・private に local を当てない・
  hostname で選ぶ・switch の前に取る・知らせ)・変更点・採らなかった案 (spec の A〜C と、入力を条件で消す・`mkDefault` の雛形・
  名前を env で持つ)・段階 1〜3・影響 (`/nix/store` に入ること・雛形の版が変わること)・検証
- [ ] **Step 2: nix/README.md** — 置き場所・まとめて実行する (プリセットの表・決め方・`--which-host`)・新規マシンの手順 (0 と 2.4)・
  2 回目以降・マシン登録簿 (実機は private へ向かう)・新しい節「dotfiles-private に登録したホスト」・登録簿に載せずにマシンを足す
  (重ね順)・ローカル flake の lock も張り直す (入力 2 つ)・bootstrap の実行順の表・git について (lavie の `--host` の記述を直す)・
  Claude Code の skill の一覧があれば足す
- [ ] **Step 3: 残りの文書** — README.md・ADR 002・ADR の一覧・hosts/default.nix・mk-home.nix
- [ ] **Step 4: 文書のリンクを確かめる** (相対リンクの先があるか) — commit

### Task 9: 全体の確かめと PR

- [ ] **Step 1:** `nix flake check --no-build ./nix` (全 system の評価) と、足した・変えた checks を x86_64-linux でビルド
  (`private-hosts-state`・`host-draft-state`・`private-host-test`・`setup-host-test`・`setup-local-flake-test`・
  `local-flake-migrate-test`・`setup-post-notes-test`・`bootstrap-dotfiles-private-test`・`bootstrap-herdr-hub-test`・
  `warn-helpers-test`・`git-github-helpers-test`)。lint (nixfmt --check・shfmt -d・shellcheck・check-test-headers・check-test-grep-q)
- [ ] **Step 2:** branch 全体のレビュー (superpowers:requesting-code-review) を受けて直す
- [ ] **Step 3:** push して PR (タイトルは `TKT-257 …`、本文の 1 行目はチケットの URL)。`ticket.sh pr TKT-257`
