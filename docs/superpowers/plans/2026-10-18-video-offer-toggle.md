# 解説動画を既定で作る仕組みの host option 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `dotfiles.claude.videoOffer.enable` (既定 false) 1 つで、CLAUDE.md の「解説動画を作る」の節・settings.json の `skillOverrides.pjp-video-explainer-offer`・hook `video-offer-nudge.sh` の知らせがそろって切り替わるようにする。

**Architecture:** ADR 007 の `devTracker.enable` と同じ経路に載せる。節は `CLAUDE.video-offer.md` に切り出して `claude.nix` が option で連結し、`claude-skill-overrides.json` に key を 1 つ足す (bootstrap は変えない)。hook は Claude Code と同じ `settings.json` の `skillOverrides` を読み、skill を Claude が呼べない値なら黙る。

**Tech Stack:** Nix (home-manager の module・flake の `checks`・評価時の assert)、bash (shfmt / shellcheck)、jq

**Spec:** `docs/adr/023_claude_video_offer_host_option_20261018T121637JST/README.md` (ADR 023、方針は 2026-10-18 に承認。チケットは TKT-211)

## Global Constraints

- option は `options.dotfiles.claude.videoOffer.enable`、`lib.types.bool`、`default = false`、`example = true`
- 断片ファイルは `nix/files/claude/CLAUDE.video-offer.md`。中身は今の `nix/files/claude/CLAUDE.md` の 75〜80 行目 (`## 解説動画を作る` から `…も知らせてくる。` まで) を 1 文字も変えずに移したもの
- CLAUDE.md の連結は `常時部分 + (videoOffer なら "\n" + CLAUDE.video-offer.md) + (devTracker なら "\n" + CLAUDE.dev-tracker.md)`。両方 true の出力は今の `~/.claude/CLAUDE.md` とバイト単位で同じ
- `claude-skill-overrides.json` は `{"pjp-dev-tracker":"on"|"off","pjp-video-explainer-offer":"on"|"off"}` + 改行 (`builtins.toJSON` が key を名前順に並べる)
- hook が読むのは `${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json` の `.skillOverrides["pjp-video-explainer-offer"]`。値が `off` か `user-invocable-only` なら黙る。それ以外 (無い・`on`・`name-only`・知らない値・settings.json が無い / 壊れている) は今どおり。何があっても exit 0
- `pjp-video-explainer-pictogram` / `dialogue`・claude-skills・このマシンの `~/dotfiles/flake.nix` には触らない
- open の PR #138 (TKT-207) と衝突しない位置に足す: `options.nix` の 9〜12 行目と `gitViaGh` の説明、`mk-home.nix` の 27 行目、`hosts/default.nix` の 17〜18 行目、`setup-local-flake.sh` の 270〜277 行目、README の 951〜961 行目、`flake.nix` の checks の `claude-env-state` の直後には書かない
- shfmt (2 空白・`binary_next_line`・`case_indent`)・shellcheck・nixfmt を通す。テストの先頭のコメントに check の名前と「## 確かめること」を書く。判定の `grep -q` をパイプの先に置かない
- `./nix` を指す nix コマンドは git flake として読むので、新しいファイルは流す前に `git add` する
- commit メッセージは日本語で `<種類>(<範囲>): … (TKT-211)`。末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` と `Claude-Session: https://claude.ai/code/session_01EZbr6F44MRQKpfXJ7e56iR` の 2 行

## Review Focus

- `switch` だけ流して bootstrap を流さないマシン: CLAUDE.md の節は消えるが、skill と hook の知らせは settings.json が書き換わるまで残る。README の「反映」にそう書いてあること (Task 3)
- claude-personal / claude-work (`CLAUDE_CONFIG_DIR=~/.claude-<名前>`): `settings.json` は `~/.claude/settings.json` への symlink。hook が symlink 越しに読んで黙ること (Task 2 のケース 28)
- 壊れた・形の違う settings.json (`skillOverrides` が object でない、JSON として途中で切れている): hook が落ちずに exit 0 で、今どおり知らせること (Task 2 のケース 27)
- `local` に videoOffer を書いていない既存のローカル flake: 既定の false が警告なしに効くこと (Task 1 のケース「既定は false」)
- 両方 true の CLAUDE.md が分割前と同じ並び・空行であること (Task 1 の性質のケースと、Task 3 の `git show main:` との diff)

---

### Task 1: option・CLAUDE.md の節・skill-overrides の生成

**Files:**
- Create: `nix/tests/claude-skill-toggles.nix`
- Modify: `nix/flake.nix` (checks の `claude-notion-state = import ./tests/claude-notion.nix { … };` の直後、`cc-pages-state` の前に `claude-skill-toggles`。#137 が `cc-pages-state` の後に足すため)
- Create: `nix/files/claude/CLAUDE.video-offer.md`
- Modify: `nix/files/claude/CLAUDE.md:74-80` (末尾の空行と「解説動画を作る」の節を抜く。73 行目の改行で終わる)
- Modify: `nix/home/options.nix` (15 行目の後に一覧の 1 行、165 行目の `notion = { … };` の後に option)
- Modify: `nix/home/modules/claude.nix:1-16,241-277` (先頭の配置一覧のコメント、CLAUDE.md の連結、skill-overrides の JSON)

**Interfaces:**
- Produces: `config.dotfiles.claude.videoOffer.enable` (bool)。`home.file.".claude/CLAUDE.md".text` と `home.file.".local/state/dotfiles/claude-skill-overrides.json".text` が option で変わる。Task 3 の README と雛形はこの名前を書く

- [ ] **Step 1: 評価時のテストを書く** — `nix/tests/claude-skill-toggles.nix`。形は `nix/tests/claude-env.nix` に合わせる (先頭のコメントに `flake.nix の checks (claude-skill-toggles) から呼ぶ` と「## 確かめること」、`cases` のリスト、`failed` を `lib.assertMsg`、`pkgs.runCommand "claude-skill-toggles"`)。組み合わせは 4 つ:

```nix
configWith = claude: (mkHome { username = "tester"; inherit system claude; }).config;
byDefault = configWith { };                                              # devTracker true / videoOffer false
both      = configWith { videoOffer.enable = true; };
videoOnly = configWith { devTracker.enable = false; videoOffer.enable = true; };
neither   = configWith { devTracker.enable = false; };
md = cfg: cfg.home.file.".claude/CLAUDE.md".text;
overrides = cfg: cfg.home.file.".local/state/dotfiles/claude-skill-overrides.json".text;
heading = h: text: lib.hasInfix "\n\n${h}\n" text;   # 見出しの行があり、前が空行
```

ケース (name → ok):

```nix
"videoOffer.enable の既定は false"                                   = !byDefault.dotfiles.claude.videoOffer.enable;
"mkHome の claude 引数で videoOffer.enable = true を渡せる"            = both.dotfiles.claude.videoOffer.enable;
"既定の CLAUDE.md は「タスク管理」だけを持つ"                          = heading "## タスク管理" (md byDefault) && !lib.hasInfix "## 解説動画を作る" (md byDefault);
"両方 true の CLAUDE.md は両方を持ち、「解説動画を作る」が先"           = heading "## 解説動画を作る" (md both) && heading "## タスク管理" (md both)
                                                                       && !lib.hasInfix "## タスク管理" (builtins.head (lib.splitString "## 解説動画を作る" (md both)));
"videoOffer だけ true の CLAUDE.md は「解説動画を作る」だけを持つ"      = heading "## 解説動画を作る" (md videoOnly) && !lib.hasInfix "## タスク管理" (md videoOnly);
"両方 false の CLAUDE.md はどちらも持たない"                           = !lib.hasInfix "## 解説動画を作る" (md neither) && !lib.hasInfix "## タスク管理" (md neither);
"どの組み合わせでも「命名」と「方針を承認したら PR まで走り切る」がある" = builtins.all (c: heading "## 命名" (md c) && heading "## 方針を承認したら PR まで走り切る" (md c)) [ byDefault both videoOnly neither ];
"どの組み合わせでも改行が 3 つ続かず、改行 1 つで終わる"                = builtins.all (c: !lib.hasInfix "\n\n\n" (md c) && lib.hasSuffix "\n" (md c) && !lib.hasSuffix "\n\n" (md c)) [ byDefault both videoOnly neither ];
"既定の skill-overrides は dev-tracker が on・video-explainer-offer が off" = builtins.fromJSON (overrides byDefault) == { "pjp-dev-tracker" = "on"; "pjp-video-explainer-offer" = "off"; };
"両方 true の skill-overrides は両方 on"                               = builtins.fromJSON (overrides both) == { "pjp-dev-tracker" = "on"; "pjp-video-explainer-offer" = "on"; };
"両方 false の skill-overrides は両方 off"                             = builtins.fromJSON (overrides neither) == { "pjp-dev-tracker" = "off"; "pjp-video-explainer-offer" = "off"; };
"skill-overrides は改行で終わる"                                       = lib.hasSuffix "\n" (overrides byDefault);
```

- [ ] **Step 2: checks に載せ、落ちることを確かめる** — `nix/flake.nix` の `claude-notion-state = import ./tests/claude-notion.nix { … };` の直後 (`cc-pages-state` の前) に `claude-skill-toggles = import ./tests/claude-skill-toggles.nix { inherit lib pkgs mkHome system; };` (同じ形の `inherit` の並び)

Run: `git add nix/tests/claude-skill-toggles.nix && nix build --no-link -L './nix#checks.x86_64-linux.claude-skill-toggles'`
Expected: 評価で落ちる (`The option `dotfiles.claude.videoOffer' does not exist` か、assert の「合わない項目」)

- [ ] **Step 3: option を足す** — `nix/home/options.nix`。一覧の行は `#   dotfiles.claude.videoOffer.enable            設計・PR のときに解説動画の短尺を既定で作り始めるか (既定 false)`。description は ADR 023 §2 A・B の要点 (何を作り始めるか・token を大きく使うので既定 false・1 つの値から決まる 3 つ・名指しで頼んだ動画は止めない・反映は 2 段で `~/dotfiles/setup --update`・使うマシンはローカル flake の local で true)

- [ ] **Step 4: 節を切り出し、連結と JSON を直す** — `CLAUDE.md` の 74〜80 行目を抜いて 75〜80 行目を `CLAUDE.video-offer.md` に移す。`claude.nix` の `".claude/CLAUDE.md".text` に `lib.optionalString cfg.videoOffer.enable ("\n" + builtins.readFile (claudeRoot + "/CLAUDE.video-offer.md"))` を devTracker の連結の**前**に足し、`claude-skill-overrides.json` に `"pjp-video-explainer-offer" = if cfg.videoOffer.enable then "on" else "off";` を足す。直前のコメント (節を分ける理由・連結の形・バイト単位で同じ) と、ファイル先頭の配置一覧 (`files/claude/CLAUDE.video-offer.md` の行) を合わせて直す

- [ ] **Step 5: テストが通ることを確かめる**

Run: `git add nix/files/claude/CLAUDE.video-offer.md && nix build --no-link -L './nix#checks.x86_64-linux.claude-skill-toggles'`
Expected: 成功し、ログに `ok   …` が 12 行

- [ ] **Step 6: commit**

```bash
git add nix/tests/claude-skill-toggles.nix nix/flake.nix nix/files/claude/CLAUDE.md nix/files/claude/CLAUDE.video-offer.md nix/home/options.nix nix/home/modules/claude.nix
git commit  # feat(claude): 解説動画を既定で作るかを dotfiles.claude.videoOffer.enable (既定 false) で決め、CLAUDE.md の節と skillOverrides に流す (TKT-211)
```

### Task 2: hook は skillOverrides で skill が呼べないとき黙る

**Files:**
- Modify: `nix/tests/video-offer-nudge.test.sh` (先頭の「## 確かめること」、設定 dir を作る helper、ケース 23〜28)
- Modify: `nix/files/claude/hooks/video-offer-nudge.sh:17-28,40-42` (「## 黙る場面」と、jq の確認の直後に settings.json の確認)

**Interfaces:**
- Consumes: Task 1 の skill の名前 `pjp-video-explainer-offer` と、bootstrap が settings.json に書く値 `"on"` / `"off"`

- [ ] **Step 1: テストを書く** — helper と 6 ケースを、今のケース 22 の後に足す。「## 確かめること」の 3 つ目の項目に「settings.json の skillOverrides で skill が off か user-invocable-only (symlink の先でも) なら黙り、on・name-only・ほかの skill だけの off・壊れた settings.json では知らせる」を足す

```bash
# config_with_settings <dir 名> <settings.json の中身> : skill と settings.json を持つ設定 dir を作り、パスを返す
config_with_settings() { … mkdir -p "${dir}/skills/pjp-video-explainer-offer"; echo '---' >…/SKILL.md; printf '%s' "$2" >"${dir}/settings.json"; printf '%s' "${dir}"; }

# 23. off → PR の作成でも設計の文書でも黙る
# 24. user-invocable-only → 黙る
# 25. on と name-only → 知らせる (文は "[解説動画] PR を作った (…)。" で始まる)
# 26. ほかの skill だけ off ({"skillOverrides":{"pjp-dev-tracker":"off"}}) → 知らせる
# 27. 壊れた settings.json ('{"skillOverrides": ') と object でない skillOverrides ('{"skillOverrides":"off"}') → 知らせ、exit 0
# 28. settings.json が off の settings.json への symlink (claude-<名前> の dir) → 黙る
```

- [ ] **Step 2: 落ちることを確かめる**

Run: `bash nix/tests/video-offer-nudge.test.sh`
Expected: 23・24・28 が FAIL、ほかは ok。最後の行が `== … passed, 3 failed`

- [ ] **Step 3: hook を直す** — `command -v jq &>/dev/null || exit 0` の直後に、`settings="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"` と `case $(jq -r '.skillOverrides["pjp-video-explainer-offer"] // empty' "${settings}" 2>/dev/null) in off | user-invocable-only) exit 0 ;; esac`。直前に 2〜3 行のコメント (知らせても skill を呼べず SKILL.md を直接読ませることになるため・Claude Code が使う値を見るので `/skills` で切っても黙る)。「## 黙る場面」に 1 項目足す

- [ ] **Step 4: 通ることを確かめる**

Run: `bash nix/tests/video-offer-nudge.test.sh && nix build --no-link -L './nix#checks.x86_64-linux.video-offer-nudge-test'`
Expected: `== … passed, 0 failed` と、build の成功

- [ ] **Step 5: commit**

```bash
git add nix/tests/video-offer-nudge.test.sh nix/files/claude/hooks/video-offer-nudge.sh
git commit  # feat(claude): video-offer-nudge.sh は settings.json の skillOverrides で skill が呼べないとき黙る (TKT-211)
```

### Task 3: 雛形・案内・README・ADR

**Files:**
- Modify: `nix/scripts/setup-local-flake.sh:20-31` (先頭のコメントの「~/dotfiles に置くもの」に 2 行)・`:292-296` (雛形の `local` の最後、`# dotfiles.ccPages.port = 7778;` の後にコメントアウトした `# dotfiles.claude.videoOffer.enable = true;` と説明)
- Modify: `nix/lib/mk-home.nix:29-31` (例の行を 29 行目の後に足し、31 行目の「どちらも true」を直す)
- Modify: `nix/hosts/default.nix:20` (`claude.notion.routes` の行の後に `claude.videoOffer.enable = true` の説明)
- Modify: `nix/files/claude/hooks/nix-managed-guard.sh:176-177` (断片ファイルに `CLAUDE.video-offer.md` を足す)
- Modify: `nix/scripts/bootstrap-claude-skill-overrides.sh:10-19,117` (コメントの option と JSON の例、最後の確認の案内に `pjp-video-explainer-offer`。処理は変えない)
- Modify: `nix/README.md` (1670 行目の表に `CLAUDE.video-offer.md` の行、1752 行目からの解説動画のフックの節に黙る条件、965 行目付近の `local` の節の cc-pages の段落の後に videoOffer の段落、2094 行目からの「Claude Code の skill を host ごとに止める」を 2 つの option の表と 3 層の表にし、値の置き場・反映・確認・採らなかった案に解説動画を足す)
- Modify: `docs/adr/README.md` (一覧に 023 の行)
- Modify: `docs/adr/023_…/README.md` (§6 に検証の結果)

- [ ] **Step 1: 雛形と案内を直す** — 上の 5 ファイル。雛形の説明は 6 行以内で、何を作り始めるか・既定は false で使うマシンだけ true・決まる 3 つ・名指しで頼んだ動画は作れる・反映は `~/dotfiles/setup --update`。heredoc は `<<EOS` (展開あり) なので `$` と backtick を書かない

- [ ] **Step 2: 雛形を確かめる**

Run: `d=$(mktemp -d) && DOTFILES_LOCAL_DIR="$d/local" ./nix/scripts/setup-local-flake.sh && grep -n 'videoOffer' "$d/local/flake.nix"`
Expected: `# dotfiles.claude.videoOffer.enable = true;` の行が出る。続けてその行のコメントを外し、`nix eval --raw "path:$d/local#homeConfigurations.\"pollenjp@x86_64-linux\".config.dotfiles.claude.videoOffer.enable" --apply 'b: if b then "true" else "false"'` が `true`

- [ ] **Step 3: README と ADR を書く** — README は上の 4 か所。ADR 023 §6 に Task 1〜3 と下の Step 4 の結果を表で書く。`docs/adr/README.md` の行は `| [023](./023_claude_video_offer_host_option_20261018T121637JST/README.md) | 解説動画を既定で作る仕組み (pjp-video-explainer-offer) を host option で切り替え、既定を off にする (CLAUDE.md の節・skillOverrides・hook の 3 層) | 2026-10-18 |`

- [ ] **Step 4: まとめて確かめる**

Run (どれも成功すること):

```bash
# 両方 true の CLAUDE.md が分割前と同じ (差分なし)
diff <(nix eval --raw --impure --expr 'let f = builtins.getFlake (toString ./nix); in ((f.lib.hostsWith [ { dotfiles.claude.videoOffer.enable = true; } ])."pollenjp@x86_64-linux").config.home.file.".claude/CLAUDE.md".text') \
     <(git show main:nix/files/claude/CLAUDE.md; printf '\n'; cat nix/files/claude/CLAUDE.dev-tracker.md)
nix flake check --all-systems --no-build ./nix
nix build --no-link -L './nix#checks.x86_64-linux.claude-skill-toggles' './nix#checks.x86_64-linux.video-offer-nudge-test'
nix develop ./nix --command bash -c 'nixfmt --check $(git diff --name-only main -- "*.nix"); shfmt -d $(git diff --name-only main -- "*.sh"); shellcheck $(git diff --name-only main -- "*.sh")'
./nix/scripts/check-test-headers.sh
nix develop ./nix --command ./nix/scripts/check-test-grep-q.sh
./nix/scripts/verify.sh
```

- [ ] **Step 5: commit**

```bash
git add nix/scripts/setup-local-flake.sh nix/lib/mk-home.nix nix/hosts/default.nix nix/files/claude/hooks/nix-managed-guard.sh nix/scripts/bootstrap-claude-skill-overrides.sh nix/README.md docs/adr/README.md docs/adr/023_claude_video_offer_host_option_20261018T121637JST docs/superpowers/plans/2026-10-18-video-offer-toggle.md
git commit  # docs(nix): 解説動画の host option を README・雛形・ADR 023 に書く (TKT-211)
```
