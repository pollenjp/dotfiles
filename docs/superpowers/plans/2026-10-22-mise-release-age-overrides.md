# mise の遅延を期間付きで緩める 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mise の遅延 (`minimum_release_age`) を option で決め、期間付きの上書きを list で持ち、`setup --update` が今日の日付 (Asia/Tokyo) から上限の日時を決めて mise に書く。list は dotfiles-private の `nix/shared/*.nix` から登録した全ホストに足す。

**Architecture:** option (`dotfiles.mise.*`) を home-manager の module が `~/.local/state/dotfiles/mise-release-age.json` に落とし、`bootstrap-mise.sh` が jq で今日の日付と比べて `mise settings set minimum_release_age` と claude の env を決める。終わった項目は `warn` で setup の警告のまとめに出す。`privateHosts` は各ホストに渡す `mkHome` を包み、`nix/shared/*.nix` を `modules` の前に足す。

**Tech Stack:** Nix (home-manager の option・module・flake の `checks`・評価時の assert)、bash・jq (shfmt / shellcheck)

**Spec:** `docs/superpowers/specs/2026-10-22-mise-release-age-overrides-design.md` (方針は 2026-10-22 に承認。チケットは TKT-323、集約は TKT-320)

## Global Constraints

- option の名前と欄は spec のとおり: `dotfiles.mise.minimumReleaseAge` (既定 `"9d"`)、`dotfiles.mise.releaseAgeOverrides` の項目は `from` (必須)・`zeroDays` (既定 1、1 以上)・`reason` (既定 `""`)
- 状態ファイルは `~/.local/state/dotfiles/mise-release-age.json`、形は `{"minimumReleaseAge": …, "releaseAgeOverrides": [{"from", "zeroDays", "reason"}]}` で改行で終わる
- 上限 = (from + zeroDays − 1) の日の `T23:59:59+09:00`。今日は Asia/Tokyo (UNIX 秒 + 9 時間を日に割る)。今の時刻は `BOOTSTRAP_MISE_NOW` (UNIX 秒) で差し替えられる
- 「上書き中」 = from の日 ≤ 今日 ≤ 上限の日 + 既定の日数。いちばん新しい上限を書き、無ければ既定を書く。claude は 今日 ≤ 上限の日 + min(1, 既定の日数) のあいだ上限、ほかは `min(1, 既定の日数)d`
- 読めないとき (状態ファイルが無い・形が違う・jq が無い) は警告して `9d` を書き、claude は `1d`。setup は止めない
- bootstrap-mise.sh は setup が shebang で直に流すので bash 3.2 でも動く書き方 (mapfile・連想配列を使わない)
- `nix/shared/` のファイルの拾い方は `nix/hosts/` と同じ (`.nix` で終わる・`.` で始まらない・ディレクトリでない)。名前の順に、ホストの `modules` より前
- shfmt (2 空白・`binary_next_line`・`case_indent`)・shellcheck・nixfmt。テストの先頭に check の名前と「## 確かめること」。判定の `grep -q` をパイプの先に置かない。`./nix` を読む前に新しいファイルを `git add`
- commit は日本語の `<種類>(<範囲>): … (TKT-323)` と箇条書きの本文、末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- 並行の PR #154 (TKT-312。options.nix・flake.nix・home/default.nix・README を触る) とぶつからない位置に足す: options の一覧は `sshAgentNotice` の行の後、option は `cleanup.enable` の後、module の import は `cleanup.nix` の後、flake の state の check は `cc-pages-state` の後

## Review Focus

- 日付の境目が UTC と JST でずれる時刻 (UTC 15:00〜24:00): JST の日で判定する (Task 2 の 00:30 JST のケース)
- 暦に無い日 (`2026-02-30`)・閏年 (`2024-02-29` は通す、`2025-02-29` は止める): 評価で止まる (Task 1)
- 上書きの list が shared とホストの両方にある: 両方がつながり、shared が先 (Task 3)
- `nix/shared/` の無い clone・stub・`.` で始まるファイルと README: 評価が通り、拾わない (Task 3)
- 状態ファイルが無い・壊れている古い世代: 守りを緩めず `9d` を書き、setup を止めない (Task 2)

---

### Task 1: option と状態ファイル

**Files:**
- Modify: `nix/home/options.nix` (頭の一覧に 2 行、`options.dotfiles.cleanup.enable` の後に `options.dotfiles.mise`)
- Create: `nix/home/modules/mise-release-age.nix`
- Modify: `nix/home/default.nix` (imports の `./modules/cleanup.nix` の後)
- Create: `nix/tests/mise-release-age.nix`
- Modify: `nix/flake.nix` (checks の `cc-pages-state` の後に `mise-release-age-state`)

**Interfaces:**
- Produces: `config.dotfiles.mise.minimumReleaseAge :: str` (`[0-9]+d`)、`config.dotfiles.mise.releaseAgeOverrides :: [ { from :: str (暦にある YYYY-MM-DD); zeroDays :: int ≥ 1; reason :: str; } ]`、`home.file.".local/state/dotfiles/mise-release-age.json".text`

- [ ] **Step 1: テストを書く** — `nix/tests/mise-release-age.nix` (形は `nix/tests/claude-video-offer.nix`。`configWith = modules: (mkHome { username = "tester"; inherit system modules; }).config`)。ケース:
  - 既定: `minimumReleaseAge == "9d"`・`releaseAgeOverrides == [ ]`・JSON が `{ minimumReleaseAge = "9d"; releaseAgeOverrides = [ ]; }` で改行で終わる
  - `{ from = "2026-10-22"; }` だけの項目は JSON で `{ from = "2026-10-22"; zeroDays = 1; reason = ""; }`
  - 2 つの module の list がつながる (書いた順)、`minimumReleaseAge = "14d"` が JSON に入る
  - 止まる (`!(builtins.tryEval (builtins.deepSeq v true)).success`): from `"2026-1-2"`・`"2026-02-30"`・`"2025-02-29"`・`"2026-13-01"`、zeroDays `0`、minimumReleaseAge `"1w"`・`"9"`、知らない欄 `until`。`"2024-02-29"` は通る
- [ ] **Step 2: 落ちるのを見る** — `git add -N nix/tests/mise-release-age.nix` してから `nix build --no-link -L './nix#checks.x86_64-linux.mise-release-age-state'` (flake に載せる行も先に足す)。option が無いので評価で落ちる
- [ ] **Step 3: 実装** — options.nix の `let` に `isCalendarDate` (`builtins.match` と `lib.toIntBase10`、閏年は 4・100・400) と `lib.mkOptionType { name = "calendarDate"; description = "暦にある日付 (YYYY-MM-DD)"; check = …; merge = lib.mergeEqualOption; }`。`zeroDays` は `lib.types.ints.positive`。module は項目を `{ inherit (x) from zeroDays reason; }` に写して `builtins.toJSON … + "\n"`
- [ ] **Step 4: 通るのを見る** — 同じ build が `ok   …` を並べて通る。`nix flake check ./nix --no-build` も通る
- [ ] **Step 5: commit** — `feat(nix): mise の遅延と期間付きの上書きを option にし、状態ファイルに置く (TKT-323)`

### Task 2: bootstrap-mise.sh が上限を決めて書く

**Files:**
- Modify: `nix/scripts/bootstrap-mise.sh` (settings と claude の行、warn / summary_warn を足す)
- Create: `nix/tests/bootstrap-mise.test.sh`
- Modify: `nix/flake.nix` (`bootstrap-mise-test = scriptTest "bootstrap-mise" ./scripts/bootstrap-mise.sh;` を `bootstrap-claude-skills-test` の後)

**Interfaces:**
- Consumes: Task 1 の状態ファイルの形
- Produces: `mise settings set minimum_release_age <既定 | 上限の日時>`、`MISE_MINIMUM_RELEASE_AGE=<上限の日時 | Nd> mise use -g claude@latest`、`warn` (終わった項目・読めない状態ファイル)

- [ ] **Step 1: テストを書く** — 偽の mise (shebang は `$BASH`) が `"${MISE_MINIMUM_RELEASE_AGE-}|$*"` を `$HOME/mise.log` に足す。HOME・XDG_CONFIG_HOME は使い捨て、`config.toml` は空で置く。時刻は `jq -n '"…" | fromdateiso8601'` で UNIX 秒にして `BOOTSTRAP_MISE_NOW` に渡す。判定は `grep -Fxq <行> "${h}/mise.log"` (ファイルを直に読む)。項目 A = `{from: "2026-10-22", zeroDays: 3, reason: "修正版を入れる"}` (上限 10/24、終わり 11/02)。ケース:

  | 今 (UTC) | 状態ファイル | settings の値 | claude の env | ほか |
  | --- | --- | --- | --- | --- |
  | 2026-10-22T03:00:00Z | 項目なし・9d | `9d` | `1d` | 上書きの行なし、警告なし |
  | 同上 | 項目なし・14d | `14d` | `1d` | |
  | 同上 | 項目なし・0d | `0d` | `0d` | |
  | 2026-10-22T03:00:00Z | A | `2026-10-24T23:59:59+09:00` | 同じ | stdout に「上書き中」・理由・`2026-11-02` |
  | 2026-10-21T15:30:00Z (JST 10/22 00:30) | A | 上限 | 上限 | JST で始まっている |
  | 2026-10-21T14:30:00Z (JST 10/21 23:30) | A | `9d` | `1d` | 「まだ始まっていない」の行、警告なし |
  | 2026-10-25T03:00:00Z | A | 上限 | 上限 | |
  | 2026-10-26T03:00:00Z | A | 上限 | `1d` | |
  | 2026-11-02T03:00:00Z | A | 上限 | `1d` | 警告なし |
  | 2026-11-02T15:30:00Z (JST 11/03 00:30) | A | `9d` | `1d` | 警告 (stderr と DOTFILES_SETUP_WARNINGS のファイル) に from・zeroDays・理由・`2026-11-02`、消す場所 `nix/shared/` |
  | 2026-10-23T03:00:00Z | `{from 10/22, z 1}` と `{from 10/20, z 5}` | `2026-10-24T23:59:59+09:00` | 同じ | いちばん新しい上限 |
  | 2026-10-23T03:00:00Z | A と `{from 2026-09-01, z 1}` (終わった) | 上限 | 上限 | 終わった方だけ警告 |
  | 2026-10-22T03:00:00Z | ファイルなし | `9d` | `1d` | 警告 (switch を促す)、exit 0 |
  | 同上 | from `2026-02-30` | `9d` | `1d` | 警告 (形が違う)、exit 0 |

  どのケースも `lockfile true`・`fetch_remote_versions_timeout 14d`・`use -g go`・`use -g node@24`・`use -g aqua:jdx/usage` は今までどおり env なしで打つ
- [ ] **Step 2: 落ちるのを見る** — `bash nix/tests/bootstrap-mise.test.sh` (今の script は 9d 直書きで、上書きのケースが FAIL)
- [ ] **Step 3: 実装** — `warn` / `summary_warn` は `bootstrap-claude-env.sh` と同じ本文。jq の program 1 つで `{setting, claude, use, ended, pending}` を作る (`def day: strptime("%Y-%m-%d") | mktime / 86400 | floor;`・`$today = (($now + 32400) / 86400 | floor)`)。形の検査は別の `jq -e` (from は往復して同じ日付か)。上書き中の 1 行は `==> 上書き中: …`、終わった項目は 1 つの `warn` (見出し・項目ごとの行・消す場所の行)
- [ ] **Step 4: 通るのを見る** — テストが全部 ok。`shfmt -d`・`shellcheck` が通り、`bash nix/tests/warn-helpers.test.sh` が bootstrap-mise.sh も見て通る
- [ ] **Step 5: commit** — `feat(nix): bootstrap-mise.sh が上書きの上限を今日の日付 (Asia/Tokyo) から決めて mise に書く (TKT-323)`

### Task 3: privateHosts が `nix/shared/*.nix` を全ホストに足す

**Files:**
- Modify: `nix/lib/private-hosts.nix`
- Create: `nix/tests/fixtures/private-hosts/shared/release-age.nix`・`shared/README.md`・`shared/.hidden.nix` (読めば throw)
- Modify: `nix/tests/fixtures/private-hosts/hosts/alice@one.nix` (modules に自分だけの項目を 1 つ)
- Create: `nix/tests/fixtures/private-hosts-no-shared/hosts/carol@three.nix`
- Modify: `nix/tests/private-hosts.nix`

**Interfaces:**
- Consumes: Task 1 の option
- Produces: `privateHosts privateNix` の形は今のまま (ホストの名前 → homeConfiguration)。各ホストの `modules` は `<shared の module の path (名前の順)> ++ <ホストのファイルの modules>`

- [ ] **Step 1: テストを書く** — 足すケース: alice@one と bob@two の両方に shared の項目が入る / alice@one の list は `[ shared の項目, alice の項目 ]` の順 / shared の README.md と `.hidden.nix` は拾わない (拾えば throw) / `nix/shared/` の無い clone (`private-hosts-no-shared`) のホストは評価が通り list は `[ ]` / outPath の形でも shared が当たる
- [ ] **Step 2: 落ちるのを見る** — `nix build --no-link -L './nix#checks.x86_64-linux.private-hosts-state'`
- [ ] **Step 3: 実装** — `nixFilesIn = dir: …` (今の hosts の filter を関数にし、ファイル名 → path を返す)。`sharedModules = builtins.attrValues (nixFilesIn (sub "shared"))`。`mkHomeShared = args: mkHome (args // { modules = sharedModules ++ (args.modules or [ ]); })` を各ホストへ渡す
- [ ] **Step 4: 通るのを見る** — 同じ build と `nix flake check ./nix --no-build`
- [ ] **Step 5: commit** — `feat(nix): privateHosts が dotfiles-private の nix/shared/*.nix を登録した全ホストに足す (TKT-323)`

### Task 4: 説明

**Files:**
- Modify: `nix/README.md` (「mise との役割分担」に遅延と上書きの節、「dotfiles-private に登録したホスト」の木と読み方に `nix/shared/`、「登録する」に compare の違いの注意、「2. mise の初期化」に 1 行)
- Modify: `README.md` (dotfiles-private の段落に `nix/shared/` を 1 文)
- Modify: `nix/private-stub/README.md`・`nix/lib/mk-home.nix` の頭・`nix/flake.nix` の privateHosts のコメント・`nix/home/modules/fish.nix` と `bash.nix` の mise0 / mise1 のコメント (abbr の中身は変えない)
- ADR: 書くなら番号を指揮役に聞いてから (書く前に止まる)

- [ ] **Step 1: 書く** — 節の中身は spec の「振る舞い」の表と、書き方の例 (`nix/shared/mise-release-age.nix` の形)・setup の出力の例・終わった項目の消し方
- [ ] **Step 2: 確かめる** — `./nix/scripts/verify.sh` (flake check・sandbox・activate)、`./nix/scripts/check-test-headers.sh`・`./nix/scripts/check-test-grep-q.sh`、`nixfmt --check`・`shfmt -d`・`shellcheck`
- [ ] **Step 3: commit** — `docs: mise の遅延の上書きの書き方と、nix/shared/ の読み方を書く (TKT-323)`
