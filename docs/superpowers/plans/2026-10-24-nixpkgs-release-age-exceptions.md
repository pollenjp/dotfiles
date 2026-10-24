# nixpkgs の猶予と例外 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** nixpkgs (と flake の github input) の猶予の日数を `nix/release-age.nix` の設定値にし、期間付きの例外 (全体・一部 nixpkgs・一部 upstream) を書けるようにして、最初の例外として mise 2026.10.17 (release の musl 版) を入れる。

**Architecture:** 設定は `nix/release-age.nix` (Nix の attrset) 1 か所。`nix/scripts/flake-lock-age.sh` が日数と日付の例外を読んで pin を選び・検査し、一部 (nixpkgs から) の pin は flake の input `nixpkgs-exceptions` に置く。`nix/lib/release-age.nix` が設定を検証して system ごとの overlay と消し時の警告 (pure) を作り、`nix/lib/mk-home.nix` が home の pkgs に当てて警告を home-manager の `warnings` に出す。

**Tech Stack:** Nix (flake・home-manager・`lib.evalModules`・overlay・評価時の assert)、bash 3.2 (shfmt / shellcheck)、GitHub Actions

**Spec:** `docs/superpowers/specs/2026-10-24-nixpkgs-release-age-exceptions-design.md` (方針は承認済み。最後の「実装で決めた細部」がこの計画の前提)

## Global Constraints

- 設定のファイルは `nix/release-age.nix`。欄は `minimumReleaseAgeDays` (既定 7)・`exceptions.all` (項目 `date`・`reason`)・`exceptions.fromNixpkgs` (`packages`・`date`・`reason`)・`exceptions.fromUpstream` (`package`・`version`・`reason`)。upstream の中身は `nix/pkgs/upstream/<package>.nix`
- 一部 (nixpkgs から) の pin は flake の input `nixpkgs-exceptions` (`github:NixOS/nixpkgs/nixpkgs-unstable`)
- 日付は Asia/Tokyo の日の終わり = その日の 14:59:59 UTC。Nix は `lastModifiedDate` (UTC の `YYYYMMDDHHMMSS`) と `"<YYYYMMDD>145959"` を文字列で比べ、bash は UNIX 秒 (`day_end_epoch`) で比べる。「越えた」は厳密に大きいとき
- 警告の文は `nixpkgs の例外` で始める (CI がこの文だけを落とさずに annotation にする)
- flake-lock-age.sh は bash 3.2 で動く書き方 (連想配列・mapfile なし。空の配列を `set -u` で展開しない)。JSON と設定は nix に読ませる (jq を使わない)。`read` の区切りのタブは空の欄で詰まるので、空になりうる欄は `-` で埋める
- 日数の優先: `--min-age-days` > `FLAKE_MIN_RELEASE_AGE_DAYS` (空でなければ) > 設定の `minimumReleaseAgeDays` > 7。設定は `--config FILE` か、script の隣の `../release-age.nix`
- shfmt (2 空白・`binary_next_line`・`case_indent`)・shellcheck・nixfmt。テストの先頭に check の名前と「## 確かめること」。判定の `grep -q` をパイプの先に置かない。偽のコマンドの shebang は `$BASH` から作る。`./nix` を評価する前に新しいファイルを `git add` する
- commit は日本語の `<種類>(<範囲>): …` と箇条書きの本文。public な repo なのでチケットの ID と URL は書かない。末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- 普段の nixpkgs の pin (`nixpkgs`・`home-manager`) は動かさない。lock に足すのは `nixpkgs-exceptions` だけ (`flake-lock-age.sh update --input nixpkgs-exceptions ./nix`)。素の `nix flake lock` / `update` は打たない
- 確かめは build まで。この PC の環境は switch しない。`verify.sh` も流さない (手元の user systemd に触る)

## Review Focus

- 日の境目: 14:59:59 UTC (= その日の 23:59:59 JST) の pin・公開は「その日まで」に入り、15:00:00 UTC は入らない (Task 1・2 のテスト)
- 例外が無い普段の評価で `nixpkgs-exceptions` を読まない (読むと取ってくるものが増える): 偽の input を `throw` にして評価が通る (Task 1)
- lock に無い input (この PR で足す `nixpkgs-exceptions`、古い lock): update が先端を掴まず、flake.nix から読んで選ぶ (Task 2)
- CI の「warnings が空」: `nixpkgs の例外` の文だけでは落ちず annotation になり、ほかの warning では今までどおり落ちる (Task 3 で jq の式を手元の JSON で確かめる)
- 一部の例外をライブラリ (ほかの package が使うもの) に当てた: flake check が使っている package の名前を出して落ちる (Task 3 の usedBy のテスト)

---

### Task 1: 設定と、検証・状態・overlay・警告を作る lib

**Files:**
- Create: `nix/lib/calendar-date.nix` (options.nix の `calendarDate` をそのまま移す)
- Modify: `nix/home/options.nix` (`calendarDate = import ../lib/calendar-date.nix { inherit lib; };`。コメントに release-age も使うと 1 行)
- Create: `nix/release-age.nix` (例外は 3 つとも空。各欄の書き方と例をコメントに)
- Create: `nix/lib/release-age.nix`
- Create: `nix/tests/release-age.nix`、`nix/tests/fixtures/release-age/upstream/{hello,jq,tree}.nix`
- Modify: `nix/flake.nix` (checks の `os-ca-bundle-state` の後に `release-age-state`)

**Interfaces:**
- Produces: `import ./lib/release-age.nix { lib; inputs; settings ? import ../release-age.nix; upstreamDir ? ../pkgs/upstream; } : system -> { settings; replaced; overlays; warnings; }`
  - `inputs.nixpkgs.{lastModifiedDate, legacyPackages.<system>}` と `inputs.nixpkgs-exceptions.{lastModifiedDate, legacyPackages.<system>}` だけを読む。`nixpkgs-exceptions` は、消し時を過ぎていない一部 (nixpkgs から) の項目があるときだけ読む
  - `settings`: `lib.evalModules` で検証した値 (`minimumReleaseAgeDays :: int ≥ 0`、`exceptions.{all,fromNixpkgs,fromUpstream} :: [item]`)
  - `replaced :: [str]` (overlay で差し替える top-level の名前)、`overlays :: [overlay]` (`replaced == [ ]` なら `[ ]`)、`warnings :: [str]` (どれも `nixpkgs の例外` で始まる)
  - 検証で止める (`throw`): 知らない欄・暦に無い日付・空の reason・負の日数・`.` を含む名前・pkgs に無い名前・同じ package が一部の例外に 2 回・`<upstreamDir>/<package>.nix` が無い・その版と `version` が違う

- [ ] **Step 1: テストを書く** — `nix/tests/release-age.nix` (`{ lib, pkgs, system }`。形は `nix/tests/mise-release-age.nix`)。偽の inputs は `fake = { main, x ? main }: { nixpkgs = { lastModifiedDate = main; legacyPackages.${system} = pkgs; }; nixpkgs-exceptions = { lastModifiedDate = x; legacyPackages.${system} = pkgsX; }; }`、`pkgsX = { hello = pkgs.writeText "hello-from-exceptions" ""; }`、`upstreamDir = ./fixtures/release-age/upstream` (hello は version "99.0"・jq は "1.0"・tree は `meta.platforms = [ ]`。どれも build しない `stdenvNoCC.mkDerivation`)。ケース:
  - 例外なし (`settings = { }`): `replaced == [ ]`・`overlays == [ ]`・`warnings == [ ]`・`settings.minimumReleaseAgeDays == 7`。`nixpkgs-exceptions = throw …` でも通る
  - 全体 `date = "2026-10-23"`: pin `"20261023145959"` は警告なし、`"20261023150000"` は `exceptions.all` を含む警告 1 つ
  - 一部 nixpkgs (`packages = [ "hello" ]; date = "2026-10-23"`): main `"20261020000000"`・x `"20261022000000"` で `replaced == [ "hello" ]`、`(pkgs.appendOverlays r.overlays).hello.name == "hello-from-exceptions"`、警告なし。x == main で「まだ何もしていない」の警告・`replaced == [ ]`。main `"20261024000000"` で「もう何もしていない」の警告・`replaced == [ ]`・`nixpkgs-exceptions = throw …` でも通る
  - 一部 upstream: hello 99.0 は `replaced == [ "hello" ]` で overlay 後の `hello.version == "99.0"`。jq 1.0 は nixpkgs の jq の版を含む「もう何もしていない」の警告。tree は system の名前を含む「配布物が無い」の警告。どれも `replaced` に入らないものは overlay されない
  - 止まる (`!(builtins.tryEval (builtins.deepSeq (r.replaced ++ r.warnings) true)).success`): 知らない欄 (`foo = 1;`・項目の `until`)、`date = "2026-02-30"`、`reason = ""`、`minimumReleaseAgeDays = -1`、`packages = [ "python3Packages.certifi" ]`、`packages = [ "no-such-package-xyz" ]`、hello が fromNixpkgs と fromUpstream の両方、upstream の `package = "jo"` (fixture が無い)、hello の `version = "98.0"` (fixture は 99.0)
- [ ] **Step 2: 落ちるのを見る** — `git add -A nix` してから `nix build --no-link -L './nix#checks.x86_64-linux.release-age-state'`。lib が無いので評価で落ちる
- [ ] **Step 3: 実装** — `nix/lib/release-age.nix`。検証は `lib.evalModules { modules = [ <options> { _file = "nix/release-age.nix"; config = settings; } ]; }` (項目は `types.submodule`、`reason` は `types.nonEmptyStr`、`packages` は `types.nonEmptyListOf types.nonEmptyStr`、日数は `types.ints.unsigned`)。状態: `passed = date: main > endOfDay date` (`endOfDay = d: lib.replaceStrings [ "-" ] [ "" ] d + "145959"`)、一部 nixpkgs は `!passed` かつ `x > main` で効く、upstream は `lib.versionOlder (lib.getVersion pkgs.<p>) version` かつ `lib.meta.availableOn pkgs.stdenv.hostPlatform drv` で効く。警告は「nixpkgs の例外 (<全体|一部・nixpkgs から|一部・upstream から>) <何> は、<もう何もしていない|まだ何もしていない|…> (<わけ>)。<どこから消すか>。理由: <reason>」。日時は `YYYY-MM-DD hh:mm UTC` で出す
- [ ] **Step 4: 通るのを見る** — 同じ build が `ok   …` を並べて通る。`nix build --no-link -L './nix#checks.x86_64-linux.mise-release-age-state'` も通る (calendarDate を移したため)
- [ ] **Step 5: commit** — `feat(nix): nixpkgs の猶予と例外の設定 (release-age.nix) と、検証・overlay・消し時の警告を作る lib を足す`

### Task 2: flake-lock-age.sh が設定の日数と例外で選び・検査する

**Files:**
- Modify: `nix/scripts/flake-lock-age.sh`
- Create: `nix/tests/flake-lock-age.test.sh`
- Modify: `nix/flake.nix` (checks に `flake-lock-age-test`。`nativeBuildInputs = [ pkgs.nix pkgs.jq ]` の `runCommand` で `bash ${./tests/flake-lock-age.test.sh} ${./scripts/flake-lock-age.sh}`。nix が要るわけを上に 1 行)

**Interfaces:**
- Consumes: `nix/release-age.nix` の欄 (Task 1。script は検証せず `or` で読む)
- Produces (script の口):
  - `--config FILE` (無いファイルは止まる)・`--input NAME` (resolve / update。くり返せる。無い名前は止まる)・環境変数 `FLAKE_LOCK_AGE_NOW` (UNIX 秒。今の時刻の差し替え)
  - update は `nix flake update <名前>... --flake <dir> --override-input <名前> github:<owner>/<repo>/<rev>...` (選んだ input だけ)
  - check の行: `  <名前> <日付> (<n> 日前)  OK|NG[ (<わけ>)]`。わけは `例外 (全体) <date>`・`例外 (一部・nixpkgs から) <date>`・`nixpkgs と同じ rev`

- [ ] **Step 1: テストを書く** — `nix/tests/flake-lock-age.test.sh` (`bash nix/tests/flake-lock-age.test.sh [<flake-lock-age.sh のパス>]`)。偽の `curl` は表のファイル (公開: `<名前>\t<公開の UNIX 秒>\t<rev>`、commit: `<owner>/<repo>\t<UNIX 秒>\t<sha>`) から、チャンネルの Location・S3 の一覧の XML・`git-revision` の Last-Modified と本文・GitHub の commits の JSON を返す。偽の `nix` は `eval` を本物の nix に `--store dummy://` を付けて渡し、`flake update` は引数を `nix.log` に 1 行で残す。ケース (どれも `--no-scan`):
  - 設定の `minimumReleaseAgeDays = 10` で下限 10 日の公開を選ぶ。`--min-age-days 3` と `FLAKE_MIN_RELEASE_AGE_DAYS=5` が設定に勝ち、`--min-age-days` が環境変数に勝つ。設定が無ければ 7。script の隣の `../release-age.nix` も読む
  - 全体の例外: date の日の終わりが猶予より新しければ、その日の終わりまでの最新の公開を選ぶ (14:59:59 UTC の公開は入り、15:00:00 UTC は入らない)。猶予より古い date は何もしない (その旨の行)
  - `nixpkgs-exceptions`: 一部の例外が無ければ nixpkgs と同じ rev。date の日の終わりまでの公開が nixpkgs より新しければそれ、そうでなければ nixpkgs と同じ rev
  - `--input nixpkgs-exceptions` だけ: `nix flake update` の名前と override は `nixpkgs-exceptions` だけで、例外が無ければ lock の nixpkgs の rev、あれば lock の nixpkgs (公開の名前の末尾 12 桁で見つける) より新しい公開
  - lock に無い input (flake.nix にだけある `nixpkgs-exceptions`) も選ぶ。`--input no-such` は止まる
  - check: 猶予を満たさない nixpkgs は NG (rc 1)、全体の例外の date の日の終わりまでなら OK とわけ。`nixpkgs-exceptions` は nixpkgs と同じ rev なら OK、一部の例外の date までなら OK、どちらでもなく新しければ NG
  - 設定の date が `YYYY-MM-DD` でなければ止まる
- [ ] **Step 2: 落ちるのを見る** — `bash nix/tests/flake-lock-age.test.sh` (サンドボックスの外。nix は PATH のもの)。`--config` を知らないので落ちる
- [ ] **Step 3: 実装** — 設定は `settings_rows <file>` (nix eval で `days`・`all`・`nixpkgs`・`upstream` の行。空の欄は `-`)。`day_end_epoch YYYY-MM-DD` は日付から UNIX 秒を bash の算術で出す (days from civil。終わりは `days * 86400 + 86400 - 1 - 9 * 3600`)。input の行は lock と flake.nix をまとめて読む (lock に無い名前は flake.nix から。lock の行に rev を足し、空になりうる ref・rev は `-`)。公開の一覧は今の系列と 1 つ前の系列を 1 度だけ読み、公開時刻と rev を添字の配列に貯めて使い回す (2 回選んでも HEAD を投げ直さない)。公開の新旧は一覧の添字で比べる。上限は nixpkgs (と、ほかの nixpkgs-unstable の input。`nixpkgs-exceptions` を除く) が `max(now − N 日, min(全体の date の日の終わり, now))`、`nixpkgs-exceptions` は Spec の決まり
- [ ] **Step 4: 通るのを見る** — `bash nix/tests/flake-lock-age.test.sh` と `nix build --no-link -L './nix#checks.x86_64-linux.flake-lock-age-test'` が通る。`./nix/scripts/flake-lock-age.sh check ./nix ./nix/files/claude/skills/pjp-d3js ./nix/files/claude/skills/pjp-drawio ./nix/files/claude/skills/pjp-plantuml` が今の lock で OK (設定の 7 日)
- [ ] **Step 5: commit** — `feat(nix): flake-lock-age.sh が release-age.nix の日数と例外で pin を選び・検査する`

### Task 3: input `nixpkgs-exceptions` を足し、home の pkgs に例外を当て、CI を合わせる

**Files:**
- Modify: `nix/flake.nix` (input `nixpkgs-exceptions` とコメント、`releaseAge = import ./lib/release-age.nix { inherit lib inputs; };`、`mkHome = import ./lib/mk-home.nix { inherit inputs releaseAge; };`、`release-age-state` に `inputs`・`mkHome`・`releaseAge` を渡す)
- Modify: `nix/flake.lock` (`./nix/scripts/flake-lock-age.sh update --input nixpkgs-exceptions ./nix` で足す。`nixpkgs`・`home-manager` の node は変わらない)
- Modify: `nix/lib/mk-home.nix` (`{ inputs, releaseAge }:`。`replaced == [ ]` なら `legacyPackages`、でなければ `.appendOverlays overlays`。inline の module に `warnings = exceptions.warnings;`)
- Modify: `nix/tests/release-age.nix` (実の設定と home のケース)
- Modify: `.github/workflows/nix.yml` (「warnings が空」・`min_release_age_days` の説明)

**Interfaces:**
- Consumes: Task 1 の `releaseAge`、Task 2 の `--input`
- Produces: `mkHome` の pkgs に overlay が当たり、`config.warnings` に例外の警告が入る

- [ ] **Step 1: テストを足す** — `nix/tests/release-age.nix` に `usedBy = replaced: withList: withoutList: [名前]` (同じ添字どうしで、差し替えた名前でないのに drvPath が違う package の名前) とケース:
  - usedBy: `p: [ p.hello (p.writeShellScriptBin "uses-hello" "${p.hello}/bin/hello") p.jq ]` を hello を差し替えた pkgs と素の pkgs で組むと `[ "uses-hello" ]`
  - 実の設定 (`releaseAge system`) が評価でき、`settings.minimumReleaseAgeDays` が int
  - `replaced` の名前は、`(mkHome { username = "tester"; inherit system; }).pkgs` で overlay の package になっている (`mkHomeWithout` = `import ../lib/mk-home.nix { inherit inputs; releaseAge = _: { replaced = [ ]; overlays = [ ]; warnings = [ ]; settings = { }; }; }` の pkgs の同じ名前と drvPath が違う)
  - ほかの package から使われていない: `usedBy replaced cfg.home.packages cfgWithout.home.packages == [ ]`。落ちたら名前を出す
  - `config.warnings` の `nixpkgs の例外` で始まる文は `(releaseAge system).warnings` と同じ
- [ ] **Step 2: 落ちるのを見る** — `git add -A nix` してから `nix build --no-link -L './nix#checks.x86_64-linux.release-age-state'`
- [ ] **Step 3: 実装** — flake.nix の input・mk-home.nix・flake.nix の `let` を直し、`./nix/scripts/flake-lock-age.sh update --input nixpkgs-exceptions ./nix` で lock に足す (閉包のスキャンも通す)。CI の「warnings が空」は `jq -r '.[] | select(startswith("nixpkgs の例外"))'` を `::warning title=nixpkgs の例外::` の行にし (改行は `%0A`)、残り (`map(select(startswith("nixpkgs の例外") | not))`) が `[]` かを見る
- [ ] **Step 4: 通るのを見る** — `release-age-state` が通る。`git diff nix/flake.lock` で `nixpkgs-exceptions` の node (rev は nixpkgs と同じ) と root の inputs だけが増えている。`nix flake check --all-systems --no-build ./nix` が通る。jq の式を `["nixpkgs の例外 (全体) …", "other"]`・`["nixpkgs の例外 …"]`・`[]` の JSON で流し、1 つ目だけ落ちることを見る
- [ ] **Step 5: commit** — `feat(nix): input nixpkgs-exceptions を足し、home の pkgs に nixpkgs の例外を当てて消し時を warnings に出す`

### Task 4: 最初の例外 mise 2026.10.17

**Files:**
- Create: `nix/pkgs/upstream/mise.nix`
- Modify: `nix/release-age.nix` (`exceptions.fromUpstream` に `{ package = "mise"; version = "2026.10.17"; reason = …; }`。理由は CVE-2026-111943 の修正版であることと、NixOS/nixpkgs#577218 を待つ間の一時しのぎであること)

**Interfaces:**
- Consumes: Task 1 の upstream の決まり (`<upstreamDir>/mise.nix` を `callPackage … { }`、`version` が同じ、`meta.platforms` で配布物の有無)
- Produces: `pkgs.mise` (home の) = `mise-2026.10.17`。`bin/mise`・`share/man/man1/mise.1.gz`・`share/bash-completion/completions/mise.bash`・`share/fish/vendor_completions.d/mise.fish`・`share/zsh/site-functions/_mise`・`lib/mise/.disable-self-update`

- [ ] **Step 1: 落ちる形を見る** — 設定に項目だけ足して `release-age-state` を build すると「`nix/pkgs/upstream/mise.nix` が無い」で止まる
- [ ] **Step 2: 実装** — `stdenvNoCC.mkDerivation`。tar.xz は system ごとの asset (`x86_64-linux` → `linux-x64-musl`・`aarch64-linux` → `linux-arm64-musl`・`aarch64-darwin` → `macos-arm64`) を `fetchurl { url = "https://github.com/jdx/mise/releases/download/v${version}/mise-v${version}-<asset>.tar.xz"; sha256 = "<GitHub の digest (16 進)>"; }`、補完は `mise.bash`・`mise.fish`・`mise.zsh` を同じく。digest は `gh api repos/jdx/mise/releases/tags/v2026.10.17` の値をそのまま写す (x64-musl `da0d9ace…`・arm64-musl `566e0404…`・macos-arm64 `8eb476e5…`・bash `b2ef33de…`・fish `b25af38d…`・zsh `ad713c3e…`)。`installShellCompletion --cmd mise`・`installManPage`・`.disable-self-update`、`dontStrip`・`dontPatchELF`、`doInstallCheck` で `mise --version` に版が出るかを見る。`meta.platforms = builtins.attrNames assets`・`sourceProvenance = [ lib.sourceTypes.binaryNativeCode ]`・`mainProgram = "mise"`
- [ ] **Step 3: 通るのを見る** — `release-age-state` が通る (x86_64-linux で `replaced == [ "mise" ]`)。`nix build --no-link --print-out-paths './nix#homeConfigurations.sandbox.activationPackage'` の `home-path/bin/mise --version` が `2026.10.17`、補完と man が並ぶ。`./nix/scripts/closure-scan.sh scan` が通る (落ちたら findings を切り分けて止まる)
- [ ] **Step 4: commit** — `feat(nix): 最初の nixpkgs の例外として mise 2026.10.17 を jdx/mise の release の musl 版で入れる`

### Task 5: 文書

**Files:**
- Modify: `nix/README.md` (「新しすぎる revision を pin しない」に日数の設定と「猶予の例外」の節。「遅延を外す」は例外を先に勧める。CI の表の `check`・`lock-age`。「mise との役割分担」の遅延の節から、mise 本体の例外への 1 行)
- Create: `docs/adr/032_nixpkgs_release_age_exceptions_20261024T140555JST/README.md`
- Modify: `docs/adr/README.md` (一覧に 032)、`docs/adr/005_…/README.md` (後続 ADR に 032)
- Modify: `nix/scripts/setup.sh` (help の「7 日」と手順のラベル)、`nix/files/claude/skills/pjp-dotfiles-update/SKILL.md` (日数の置き場所と、修正が猶予より新しい側にしか無いときの例外)、`docs/adr/001_…/textbook/05_daily_usage.md` (日数の置き場所)

- [ ] **Step 1: 書く** — README の例は 3 種類の項目を 1 つずつ。消し時の表 (Spec の「消し時の判定」) と、一部の例外はほかの package から使われないアプリだけ (flake check が落とす) を書く。ADR は既存の形 (背景・決定・変更点・代替案・影響・検証・運用手順)。チケットの行は書かない
- [ ] **Step 2: 確かめる** — `nix develop ./nix --command ./nix/scripts/check-claude-frontmatter.sh`・`./nix/scripts/check-test-headers.sh`・`nix develop ./nix --command ./nix/scripts/check-test-grep-q.sh`・shfmt / shellcheck / nixfmt (CI の lint と同じ形)。README のリンク先の見出しがあること
- [ ] **Step 3: commit** — `docs: nixpkgs の猶予と例外の書き方を README・ADR 032・skill に書く`

### 最後に

- [ ] `nix flake check ./nix` (x86_64-linux の build)・`nix flake check --all-systems --no-build ./nix`・lint 一式・`flake-lock-age.sh check` (4 つの flake)・`closure-scan.sh scan` を流して全部通ることを見る
- [ ] superpowers:requesting-code-review で branch 全体を見てもらい、直す
