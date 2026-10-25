# public な repo への push・PR の前に、ほかの repo への参照で止める hook 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code が Bash で打つ `git push` と `gh pr create` などを、public な repo (と公開範囲を確かめられない repo) に
ほかの repo への参照を書こうとしているときに、打つ前に止め、どこか・どう直すかを Claude に返す PreToolUse hook を足す。

**Architecture:** 1 本の bash script `nix/files/claude/hooks/xref-guard.sh`。awk の lexer (`ssh-agent-notice.sh` のものを元に、
heredoc の本文・stdin・パイプを残し、`$( )` を値に置き換える) で単純コマンドに分け、bash で包むコマンドを外して
`git push` と `gh pr|issue …` を拾い、jq (Oniguruma) で参照を探す。参照が見つかったときだけ gh で公開範囲を引き、
`permissionDecision: deny` で止める。

**Tech Stack:** bash 4 以上・awk (gawk・mawk・onetrue awk)・jq 1.7 以上・git・gh、Nix (home-manager の `home.file`・flake の checks)

**Spec:** `docs/superpowers/specs/2026-10-24-xref-guard-design.md` (方針は承認済み。「実装で決めた細部」がこの計画の前提)

## Global Constraints

- 参照の形は `ticket.py` の `XREF_RES` と同じ。jq では `\w` を `[A-Za-z0-9_]`、`\b` を `(?![A-Za-z0-9_])` に書く (Oniguruma の `\w`・`\b` は日本語も語の文字に数える)
- 通す口は単純コマンドの頭の `PJP_ALLOW_XREF=1` (`env` の引数も)。値は `1` だけ
- 公開範囲は `gh repo view … --json nameWithOwner,visibility` を 10 秒で切って引く。`PRIVATE`・`INTERNAL` は通し、それ以外は止める。控えは持たない
- 止める JSON は `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":…}}` の 1 行だけ。通すときは何も出さない。いつも exit 0
- 読むコマンドの長さは 64 KB (gawk・mawk が無ければ 16 KB) まで。push する commit は新しい方から 1000 個まで
- shfmt (2 空白・`binary_next_line`・`case_indent`)・shellcheck・nixfmt。テストの先頭に check の名前と「## 確かめること」。判定の `grep -q` をパイプの先に置かない。`./nix` を評価する前に新しいファイルを `git add` する
- commit は日本語の `<種類>(<範囲>): …` と箇条書きの本文。public な repo なので、チケットの ID と URL も、ほかの repo の参照 (backquote で囲んでも) も書かない。末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- 確かめは flake の checks まで。この PC の環境は switch しない

## Review Focus

- PR の本文の heredoc に対にならない `)` (`1) …` の箇条書き) がある `--body "$(cat <<'EOF' … EOF)"`: 本文の最後まで読み、`)` の後ろの参照も拾う (Task 1)
- `git commit -m "… owner/repo#1 …" && git push`: hook が走る時点で commit はまだ無いが、同じコマンドの commit の message として止める (Task 2)
- fork の clone (origin = fork・upstream = 本家) で、upstream の remote-tracking ref にある commit を fork へ押す: その commit は数えない (Task 2)
- 日本語の直後の参照 (`これはNixOS/nixpkgs#1`) と、`[`文`](URL)` のリンク: どちらも拾う (Task 1)
- 参照の無い push・PR では gh を呼ばない (ネットワークに出ない) (Task 1・2)

---

### Task 1: hook の骨組み・lexer・gh のタイトルと本文

**Files:**
- Create: `nix/files/claude/hooks/xref-guard.sh`
- Create: `nix/tests/xref-guard.test.sh`

**Interfaces:**
- Produces: lexer の出力は 1 単純コマンド 1 レコード (`<P|-> US <stdin> US <語> US <語>… RS`。US = `\037`、RS = `\036`。stdin は `H<本文>`・`F<path>`・空)。bash 側の `scan_command <dir> <段> <コマンド>` が単純コマンドを順に見て、止める理由を `findings` (配列) に足す。`find_refs` (jq) は `{texts: [{label, mode: "plain"|"md", text}], own: [<小文字の owner/repo>…]}` を受けて `[{label, line, ref, ctx}]` を返す

- [ ] **Step 1: テストを書く** — 偽の gh (`FAKE_GH_VIS` の `owner/repo=PUBLIC` などで答え、引数を `FAKE_GH_LOG` に書く) と使い捨ての repo を作る土台。gh の場合: `--title`・`-t`・`--title=`・`-tx` のタイトルの参照 (backquote の中も) で止める、`--body "$(cat <<'EOF' … EOF)"` の本文の backquote の外の参照で止め、backquote・``` ・~~~ の中では通す、リンク `[`x`](URL)` は止める、日本語の直後も拾う、本文に `1)` があっても後ろを拾う、`-R`・PR の URL の引数・`GH_REPO=` の repo の公開範囲を引く、PRIVATE・INTERNAL は通す、gh が落ちたら止める、同じ repo の参照と `#番号` は通す、参照が無ければ gh を呼ばない、`PJP_ALLOW_XREF=1` で通す、`--body-file`・`-F -` の heredoc・パイプの前の `cat <<EOF`・`$(cat file)`・`BODY=…; … "$BODY"` を本文として読む、`gh pr comment`・`gh issue create`・`gh issue comment`・`gh issue edit`・`gh pr review`・`gh pr merge` (backquote の中も数える)、`echo gh pr create …` と引用符の中は見ない、Bash 以外・壊れた入力は黙る
- [ ] **Step 2: 流して落ちることを見る** — `bash nix/tests/xref-guard.test.sh` が script の無さで FAIL
- [ ] **Step 3: 実装する** — lexer (spec の 7)・包むコマンド (`ssh-agent-notice.sh` の `match_simple` と同じ並び)・gh の引数の読み方 (spec の 5)・`find_refs`・公開範囲 (spec の 6)・返す文 (spec の 9)
- [ ] **Step 4: 流して通ることを見る** — 同じコマンドで全部 ok
- [ ] **Step 5: commit**

### Task 2: git push

**Files:**
- Modify: `nix/files/claude/hooks/xref-guard.sh`
- Modify: `nix/tests/xref-guard.test.sh`

**Interfaces:**
- Consumes: Task 1 の `scan_command`・`find_refs`・公開範囲・返す文
- Produces: `push_job <dir> <git の前のオプション>… -- <push の引数>…`

- [ ] **Step 1: テストを書く** — 押す commit の message の参照 (backquote の中も・URL の 4 形・`owner/repo@sha`) で止め、commit・行・参照を返す。remote-tracking ref にある commit は数えない (upstream の ref も)。`git -C`・`cd … &&`・`timeout`・`env`・`bash -c` の中も見る。refspec (`HEAD:refs/heads/x`・`+feat:feat`・SHA・`tag v1`)・`--all`・`--tags`・`-u`・`--force-with-lease`・`-fu`。削除・`--dry-run` は見ない。remote を URL で渡す・`remote.pushDefault`・`pushurl`。手元の path の remote は見ない。PRIVATE は通す。同じコマンドの `git commit -m`・`-F -` の heredoc の message も数える。`git stash push`・`git log --grep push` は見ない
- [ ] **Step 2: 落ちることを見る**
- [ ] **Step 3: 実装する** (spec の 4)
- [ ] **Step 4: 通ることを見る**
- [ ] **Step 5: commit**

### Task 3: 長いコマンド・配置・登録・checks・文書

**Files:**
- Modify: `nix/files/claude/hooks/xref-guard.sh`・`nix/tests/xref-guard.test.sh` (64 KB を超えるコマンド)
- Modify: `nix/home/modules/claude.nix` (`.claude/hooks/xref-guard.sh`)
- Create: `nix/tests/claude-xref-guard.nix`
- Modify: `nix/flake.nix` (`xref-guard-test`・`claude-xref-guard-state`)
- Modify: `nix/scripts/bootstrap-claude-hook.sh`・`nix/tests/bootstrap-claude-hook.test.sh`
- Create: `docs/adr/033_claude_xref_guard_20261024T223152JST/README.md`
- Modify: `docs/adr/README.md`・`nix/README.md`

- [ ] **Step 1: テストを書く** — 長いコマンドに参照か `git … push` があれば止めてファイルにするよう返し、無ければ通す。bootstrap は PreToolUse の 3 件目を足す (前の形にも)・`xref-guard.sh` が無ければ止まる。nix は hook が repo の script から実行できるファイルとして置かれる
- [ ] **Step 2: 落ちることを見る** — `bash nix/tests/bootstrap-claude-hook.test.sh`・`nix build --no-link -L './nix#checks.x86_64-linux.claude-xref-guard-state'`
- [ ] **Step 3: 実装する**
- [ ] **Step 4: 通ることを見る** — 上の 2 つと `nix build --no-link -L './nix#checks.x86_64-linux.xref-guard-test'`・`nix flake check ./nix`・shfmt・shellcheck・nixfmt・`check-test-headers.sh`・`check-test-grep-q.sh`
- [ ] **Step 5: 使い捨ての `--settings` で hook を付けた `claude -p` (bypassPermissions) に、参照のある commit の push と PR を打たせ、止まって理由が届くことを確かめる**
- [ ] **Step 6: commit**
