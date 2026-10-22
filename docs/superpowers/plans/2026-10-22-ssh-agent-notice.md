# 1Password の SSH 承認を知らせる hook 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code が SSH agent (1Password) を使うコマンドを打つ前に herdr と会話の画面で知らせ、断られたら打ち直さずに選択肢の問いを出させる hook (`ssh-agent-notice.sh`) を dotfiles に足す。

**Architecture:** 1 本の bash script を PreToolUse・PostToolUse・PostToolUseFailure (matcher Bash) に登録する。PreToolUse ではコマンドの文字を awk で単純コマンドに分け、bash で一覧に当てて `systemMessage` と herdr の通知を出す。Post の 2 つでは出力の断りの文言を見て `additionalContext` で Claude に指示を足す。一覧に足す道具は host option から `~/.local/state/dotfiles/claude-ssh-agent-notice.json` に落とす。

**Tech Stack:** bash・awk・jq (shfmt / shellcheck)、Nix (home-manager の module・flake の `checks`・評価時の assert)

**Spec:** `docs/superpowers/specs/2026-10-22-ssh-agent-notice-design.md` (方針は 2026-10-22 に承認。チケットは TKT-317)

## Global Constraints

- script は `nix/files/claude/hooks/ssh-agent-notice.sh` の 1 本。依存は bash・jq・awk・coreutils と、あれば `herdr`・`git`・`timeout`
- 何があっても exit 0。`permissionDecision` は出さない。先に stdin を読み切る。jq が無い・入力が壊れている・Bash でない → 黙る
- hook 1 の `systemMessage`: `🔑 1Password の承認が出るかも (<種類>): <頭> — 承認の画面は <接続>`。<種類> は `ssh の接続`・`署名`・`設定の一覧`
- <接続>: `<月/日 時:分> に <値> から入った接続の端末に出る` (値が無ければ `<月/日 時:分> に入った接続の端末に出る`)、新しい接続があれば後ろに ` (より新しい接続: <月/日 時:分> <値>)`。ほかは `このマシンの agent (<~ で書いた path>) が出す`・`出ない (agent の口 <~ で書いた path> の先が無い)`・`出ない (SSH_AUTH_SOCK が無い)`。時刻は `date '+%m/%d %H:%M'`
- <どこから>: `workspace「<label>」`・`pane <id>`・`agent <name>`・`subagent <agent_type>` のうちあるものを `・` でつなぐ。どれも無ければ `herdr の外の会話`
- herdr の通知: hook 1 は title `🔑 1Password の承認が出るかも`、body `<どこから>\n<頭>\n承認の画面は <接続>`、`--sound request`、同じ pane (`${HERDR_SESSION:-default}-${HERDR_PANE_ID}`) から 600 秒に 1 回 (印は `${XDG_STATE_HOME:-$HOME/.local/state}/pjp-ssh-agent-notice/notified-<組>` の時刻)。hook 2 は title が理由ごと (`🔑 1Password に断られた`・`🔑 SSH agent との通信が切れた`・`🔑 SSH agent に届かない`)、body は同じ形 (3 行目は `承認の画面は <接続>`)、間引かない。herdr は `timeout 2` を付けて呼ぶ
- <頭>: 当たった単純コマンドの語 (包むコマンドを外したもの) を空白でつなぎ、jq で 80 文字に切る (超えたら 79 文字 + `…`)
- hook 2 の `additionalContext` は spec §10 の文 (下の Task 3 に全文)。`systemMessage` は `<title>: <頭> — 承認の画面は <接続>`
- shfmt (2 空白・`binary_next_line`・`case_indent`)・shellcheck・nixfmt。テストの先頭に check の名前と「## 確かめること」。判定の `grep -q` をパイプの先に置かない。`./nix` を読む前に新しいファイルを `git add`
- commit は日本語の `<種類>(<範囲>): … (TKT-317)` と箇条書きの本文、末尾に `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。git の commit・tag は `SSH_AUTH_SOCK=/home/pollenjp/.ssh/agent/s.0NdPnuXkIu.sshd.f4PP30f0CU` を付けて打つ
- 並行の PR (#153・TKT-312) とぶつからない位置に足す: flake の scriptTest は `run-through-nudge-test` の後、state の check は `claude-video-offer-state` の後、options の一覧と option は `videoOffer` の後

## Review Focus

- commit メッセージ・heredoc の本文・`grep ssh`・`echo ssh` に ssh と書いただけのコマンド: 当てない (Task 1 の外れの表)
- Claude の会話の素の `git commit` (env で `commit.gpgsign=false`): 当てない。`git -c commit.gpgsign=true commit` は当てる (Task 1)
- 断りの文言を含むファイルを `cat`・`grep` して成功した Bash: hook 2 は黙る (Task 3 の「成功した Bash は行の形で見る」)
- herdr の外 (`HERDR_ENV` が無い)・herdr が落ちる・返事をしない: 会話の画面の 1 行は出し、exit 0 (Task 2)
- 同じ pane で commit を続けて打つ: 通知は 10 分に 1 回、画面の 1 行は毎回 (Task 2)

---

### Task 1: コマンドを読んで一覧に当てる (hook 1 の本体と systemMessage)

**Files:**
- Create: `nix/files/claude/hooks/ssh-agent-notice.sh`
- Create: `nix/tests/ssh-agent-notice.test.sh`

**Interfaces:**
- Produces (script の中の関数。Task 2・3 が使う):
  - `split_commands <文字列>`: 単純コマンドを 1 行に 1 つ、語を `\037` で区切って出す (awk)
  - `match_command <dir> <depth> <文字列>`: 最初に当たった単純コマンドで、グローバル `hit_kind`・`hit_head`・`hit_sock` を埋めて 0 を返す。当たらなければ 1
  - `conn_desc <sock>`: <接続> の文を出す
- Produces (テストの助け): `pre <コマンド> [<cwd>]` が PreToolUse の入力を作って流し、`notice` が `systemMessage` を出す

- [ ] **Step 1: テストを書く** — 当たり (`ssh h true`・`scp a h:b`・`timeout 5 ssh h`・`sudo -u x ssh h`・`env A=1 ssh h`・`bash -c 'ssh h'`・`nix develop -c ssh h`・`x=$(ssh h cat f)`・`diff <(ssh h cat a) b`・`for h in a b; do ssh $h true; done`・`rsync -a d/ h:d/`・`nixos-rebuild switch --target-host root@h`・`nix copy --to ssh://h .#x`・`ssh-keygen -Y sign -f k -n git f`・`ssh-add -T k.pub`) と外れ (`git commit -m "fix ssh"`・`cat <<'EOF'\nssh h\nEOF`・`grep ssh f`・`echo ssh`・`ls ~/.ssh`・`ssh -G h`・`command -v ssh`・`rsync -a a/ b/`・`rsync rsync://h/m d`・`# ssh h`・`man ssh`) の表。git: 素の `git commit` は env の `commit.gpgsign=false` で外れ・HOME の `.gitconfig` の true で当たり (`署名`)・`git -c commit.gpgsign=true commit` で当たり・`-S` で当たり・`--no-gpg-sign` で外れ・`rebase --abort` で外れ・`tag -s`/`tag v1` (tag.gpgsign=true) で当たり・`tag -l`/`tag -d v1` で外れ。ssh の remote: `git@example.invalid:x/y.git` の origin への `git push`・`cd <repo> && git push`・`git -C <repo> fetch`・`git clone ssh://h/x` で当たり (`ssh の接続`)、insteadOf で https に読み替えたら外れ、`git clone https://h/x` で外れ。<頭> の 80 文字の切り方。<接続> の 6 つの形 (記録あり・記録なしで時刻だけ・より新しい接続・手元の agent・先が無い・空) と、`SSH_AUTH_SOCK=<path> ssh h` の上書き。時刻は `TZ=UTC0`
- [ ] **Step 2: 流して落ちることを見る** — `bash nix/tests/ssh-agent-notice.test.sh` が script の無さで FAIL
- [ ] **Step 3: 実装する** — spec §4・§5・§6 のとおり。awk の lexer は `LC_ALL=C`。包むコマンドの値を取るオプションは spec の「実装に任せること」。安く抜ける前段 (`ssh|scp|sftp|mosh|rsync|nixos-rebuild|nix-copy-closure|git` と一覧の 1 語目) を入れる
- [ ] **Step 4: 流して通ることを見る** — 同じコマンドで `0 failed`。`shfmt -d`・`shellcheck` も通す
- [ ] **Step 5: commit** — `feat(nix): …打つ前に知らせる hook の本体… (TKT-317)`

### Task 2: herdr の通知と、どこから・10 分の間引き

**Files:**
- Modify: `nix/files/claude/hooks/ssh-agent-notice.sh`
- Modify: `nix/tests/ssh-agent-notice.test.sh`

**Interfaces:**
- Consumes: Task 1 の `match_command`・`conn_desc`
- Produces: `where_desc` (<どこから> を出す)、`herdr_notify <title> <body>` (HERDR_ENV=1 で herdr があるときだけ呼ぶ。失敗は黙る)

- [ ] **Step 1: テストを書く** — 偽の `herdr` (引数を log に足し、`workspace get` に `{"result":{"workspace":{"label":"🌱 dotfiles: x"}}}`、`agent get` に `{"result":{"agent":{"name":"dot-x"}}}` を返す) を PATH の先に置く。当たり → `notification show 🔑 1Password の承認が出るかも --body <どこから>\n<頭>\n承認の画面は <接続> --sound request` が 1 回。続けてもう 1 回 → 通知は増えず `systemMessage` は出る。印を 601 秒前にすると通知が出る。別の pane → 出る。`HERDR_ENV` が無い → 呼ばない。herdr が exit 1 → `systemMessage` は出て rc 0。agent の名前が null → <どこから> は pane の ID まで。外れたコマンド → herdr を呼ばない
- [ ] **Step 2: 流して落ちることを見る**
- [ ] **Step 3: 実装する** — spec §8。`timeout` が無ければ付けずに呼ぶ
- [ ] **Step 4: 流して通ることを見る**
- [ ] **Step 5: commit**

### Task 3: 断られたあとの指示 (hook 2)

**Files:**
- Modify: `nix/files/claude/hooks/ssh-agent-notice.sh`
- Modify: `nix/tests/ssh-agent-notice.test.sh`

**Interfaces:**
- Consumes: `match_command` (<頭> を取る。当たらなければコマンドの 1 行目)・`conn_desc`・`where_desc`・`herdr_notify`

`additionalContext` の全文 (`<説明>`・`<1 つ目>` は理由ごと、`<子の決まり>` は workspace が 🌱 で始まるかで変わる):

```
[ssh-agent] 直前の Bash は SSH agent (1Password) を使えずに失敗した: <説明>。
同じコマンドを打ち直さない (承認されないまま同じ失敗を繰り返す)。
1. 何を (<頭> の接続先や署名する対象) と、どこから (<どこから>) を書く。承認の画面は <接続>。
2. 選択肢の問いを出す: ① <1 つ目> (推奨) ② この手順を飛ばして進める ③ ここで止める。① が選ばれたら、同じコマンドを 1 回だけ打ち直す。
<子の決まり>
```

| 理由 | <説明> | <1 つ目> |
| --- | --- | --- |
| 断られた | `1Password に断られた (承認の画面で断られたか、応えないまま時間切れになったか、1Password がロック中だった)` | `1Password を開いて承認するので、打ち直す` |
| 通信が切れた | `agent との通信が切れた (agent を貸している SSH の接続が閉じたか、途切れた)` | `手元の PC からこのマシンへ接続し直す (agent の口を張り替える) ので、打ち直す` |
| 届かない | `agent に届かない (SSH_AUTH_SOCK の先が無い。agent を貸す SSH の接続が無い)` | 同上 |

- <子の決まり> (既定): `herdr の指揮役から依頼を受けて動いている子は、AskUserQuestion を使わず、問いと選択肢を書いてターンを終える (指揮役がユーザーに聞く)。それ以外は AskUserQuestion で聞く。`
- <子の決まり> (workspace の label が 🌱 で始まる): `この pane は herdr の指揮役の子 (workspace の名前が 🌱 で始まる) なので、AskUserQuestion を使わず、問いと選択肢を書いてターンを終える (指揮役がユーザーに聞く)。`
- subagent の中 (入力に `agent_id`) は 3 行目から後を `subagent の中なので、ユーザーには聞かない。ここまでの結果と、失敗したこと (何を: <頭> の接続先や署名する対象。どこから: <どこから>。承認の画面は <接続>) を報告に書いて作業を終える。問いは呼び出した会話が出す。` に替える

- [ ] **Step 1: テストを書く** — PostToolUseFailure の `error` に ssh の断り (理由: 断られた)・git の署名の断り・通信が切れた・`Couldn't get agent socket`・`Couldn't load public key …/.git_signing_key_tmp…`、`Permission denied (publickey).` は `SSH_AUTH_SOCK` の先が無いときだけ (届かない)。PostToolUse の stdout に行の頭から断りがある (`2>&1 | tail`) → 当たり。成功した Bash の `grep -n` の結果 (`f:1: sign_and_send_pubkey: … agent refused operation`)・行の途中の文言 → 黙る。全文の比較 (表の 3 つ・🌱・subagent)。`hookEventName` が入力の event と同じ。herdr の title が理由ごとで、2 回続けても 2 回呼ぶ。断りの無い失敗・Bash 以外 → 黙る。テストの名前と FAIL の出力に断りの英語の文言をそのまま書かない (この hook が入った会話でテストを流すと当たるため)
- [ ] **Step 2: 流して落ちることを見る**
- [ ] **Step 3: 実装する** — spec §9。失敗 (PostToolUseFailure) は部分一致、成功 (PostToolUse) は行の頭に固定した形で見る
- [ ] **Step 4: 流して通ることを見る**
- [ ] **Step 5: commit**

### Task 4: 一覧に足す option・配置・登録・flake の checks

**Files:**
- Modify: `nix/home/options.nix` (先頭の一覧と、`videoOffer.autoStart.enable` の後に `sshAgentNotice.extraCommands`)
- Modify: `nix/home/modules/claude.nix` (`claude-ssh-agent-notice.json` と `.claude/hooks/ssh-agent-notice.sh`)
- Modify: `nix/lib/mk-home.nix` (例の 1 行)
- Modify: `nix/scripts/bootstrap-claude-hook.sh`・`nix/tests/bootstrap-claude-hook.test.sh`
- Create: `nix/tests/claude-ssh-agent-notice.nix`
- Modify: `nix/flake.nix` (`ssh-agent-notice-test`・`claude-ssh-agent-notice-state`)
- Modify: `nix/tests/ssh-agent-notice.test.sh` (一覧の項目のケース)

**Interfaces:**
- Produces: option `dotfiles.claude.sshAgentNotice.extraCommands` (`lib.types.listOf lib.types.str`、`default = [ ]`、`example = [ "nix run .#vm" ]`)。状態ファイル `.local/state/dotfiles/claude-ssh-agent-notice.json` = `builtins.toJSON { extraCommands = …; } + "\n"`
- hook は `${HOME}/.local/state/dotfiles/claude-ssh-agent-notice.json` の `.extraCommands[]` (文字列だけ) を読む。無い・壊れている → 組み込みだけ

- [ ] **Step 1: テストを書く** — ssh-agent-notice.test.sh に一覧の項目のケース (`"nix run .#vm"` が `nix run .#vm -- create a`・`nix run -L .#vm -- ip` に当たり `設定の一覧`、`nix run .#vm-test` と `nix build` に外れ、`"*/deploy.sh"` が `./scripts/deploy.sh x` に当たる、ファイルが壊れていても組み込みは当たる)。claude-ssh-agent-notice.nix (既定は `[ ]`・JSON は `{"extraCommands":[]}` + 改行・値を渡せる・hook が実行できるファイルとして置かれる)。bootstrap-claude-hook.test.sh (3 件の登録・hook が無ければ止まる・前の形には 3 件だけ足す)
- [ ] **Step 2: 流して落ちることを見る** — `bash nix/tests/bootstrap-claude-hook.test.sh`・`nix build --no-link -L './nix#checks.x86_64-linux.claude-ssh-agent-notice-state'`
- [ ] **Step 3: 実装する**
- [ ] **Step 4: 流して通ることを見る** — 上の 2 つと `nix build --no-link -L './nix#checks.x86_64-linux.ssh-agent-notice-test'`
- [ ] **Step 5: commit**

### Task 5: 文書・全体の確かめ・PR

**Files:**
- Modify: `nix/README.md` (Claude Code の表に状態ファイル、フックの節に「1Password の SSH 承認を知らせるフック」、「commit を無署名にする」から参照)
- Create: `docs/adr/029_claude_ssh_agent_notice_<JST>/README.md`、Modify: `docs/adr/README.md`

- [ ] **Step 1: 文書を書く** — ADR 029 は spec の決定・捨てた案 (skill にする・git の commit をいつも当てる・hook 2 を素の部分一致にする・script を 2 本に分ける)・確かめたこと
- [ ] **Step 2: 全体を確かめる** — `nix develop ./nix --command` の中で `shfmt -d`・`shellcheck`・`nixfmt --check`、`./nix/scripts/check-test-headers.sh`・`./nix/scripts/check-test-grep-q.sh`・`./nix/scripts/check-claude-frontmatter.sh`、`nix flake check ./nix`
- [ ] **Step 3: 実機で 1 回** — この worktree の script を合成した入力で流し、lavie の herdr に通知が出ること・hook 2 の文を目で見る
- [ ] **Step 4: commit・push・PR** — PR のタイトルは `TKT-317 …`、本文の 1 行目にチケットの URL。`ticket.sh pr TKT-317`
