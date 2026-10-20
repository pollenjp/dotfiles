# herdr --remote で attach し直しても ssh-agent を借りられるようにする Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** herdr の server と pane が session ごとの固定名を `SSH_AUTH_SOCK` に持ち、固定名の先を「開いた接続」か「同じマシンから来ている生きている接続」へ向け直すことで、`herdr.exe --remote` で detach → attach し直しても pane から ssh-agent が使えるようにする。

**Architecture:** 決め方はすべて 1 本の bash script (`pjp-agent-link`) に置き、herdr を包む実行ファイル (attach のとき)・`~/.ssh/rc` (接続の記録)・systemd の user の path unit (接続が増えた・減ったとき)・手で打つ `ssh-agent-link` がそのサブコマンドを呼ぶ。クライアントは `SetEnv PJP_SSH_CLIENT=%u@%L` で自分を名乗り、同じ値の接続だけを「同じマシン」として借りる。

**Tech Stack:** bash (writeShellApplication)・home-manager (home.file・systemd.user・programs.ssh.settings)・starship の custom module・OpenSSH (`~/.ssh/rc`・`SetEnv`)・flock・python3 (テストの unix socket)

**Spec:** `docs/superpowers/specs/2026-10-20-herdr-remote-agent-borrow-design.md`

## Global Constraints

- 固定名: default は `~/.ssh/agent.sock`、named session は `~/.ssh/agent.<session>.sock`
- 記録の場所: `$HOME/.local/state/pjp-agent-link/` (0700。`XDG_STATE_HOME` は見ない)。`conn/<socket の basename>` (`sock=`・`client=`・`opened=` の 3 行)・`owner/<session>` (1 行)・`log`・`lock`・`tmp/`
- 手元の 1Password: `$HOME/.1password/agent.sock`、持ち主の値は `local`
- `PJP_SSH_CLIENT` は、空・`%` を含む・制御文字を含む・`local` なら空 (届いていない) として扱う。大文字小文字は揃えない
- 生きている: `timeout -k 1 1 ssh-add -l` が 0 か 1。1Password の socket は生死を見ない
- 張り替えは一時名の symlink を `mv -fT` で入れ替える。入れ替える直前に `flock -w 5 <state>/lock` を取り、決めたときの先と持ち主のままかを見てから入れ替える (3 回まで決め直す)
- `~/.ssh/rc`・`pjp-agent-link open`・`watch`・`rc` は stdout に何も書かない (`open` は `SSH_AUTH_SOCK` に入れるパスの 1 行だけ)
- 包む実行ファイルは PATH を変えず、script を `</dev/null`・10 秒の timeout で呼ぶ。失敗しても元の env で herdr を exec する
- session の名前は herdr と同じ規則: `^[A-Za-z0-9._-]{1,64}$` で `.`・`..` を除く。`default` は default
- コメント・文書・commit は日本語 (この repo の慣習)。commit の末尾に `(TKT-224)`
- テストの判定で `grep -q` をパイプの先に置かない (check-test-grep-q.sh)。テストの先頭に check の名前・流し方・「## 確かめること」を書く (check-test-headers.sh)
- 偽のコマンドの shebang は `$BASH` から作る (サンドボックスに `/usr/bin/env` が無い)

## Review Focus

- bridge の stdin・stdout: 包む実行ファイルが stdin を 1 byte も読まず、stdout に herdr 以外のものを書かない (読む・書くと herdr の通信が壊れる) → Task 3 のテスト `wrapper: bridge の stdin と stdout はそのまま`
- 返事をしない socket: attach も watch も 1 回の確かめを 1 秒で打ち切り、固まらない → Task 1・2 のテスト `attach: 返事をしない先は 1 秒で見切る`・`watch: 返事をしない記録を飛ばす`
- 見張りと attach が同時に走る: 見張りが古い見立てで、別のマシンから開いた直後の固定名を前の持ち主の接続へ戻さない → Task 2 のテスト `watch: 決めている間に attach が張り替えたら上書きしない`
- 展開されていない値・おかしな値: 古い ssh の `%u@%L`・改行入り・`local` は「届いていない」 → Task 1 のテスト `attach: 展開されていない値は届いていない扱い`
- 初めて動くマシン: `~/.ssh` も記録の場所も無い HOME で attach・rc・watch が通り、作るディレクトリは 0700 → Task 1・2 のテスト `attach: 何も無い HOME`・`rc: 何も無い HOME`

---

### Task 1: `pjp-agent-link` の固定名・attach・link

**Files:**
- Create: `nix/pkgs/pjp-agent-link/pjp-agent-link.sh`
- Create: `nix/pkgs/pjp-agent-link/default.nix`
- Create: `nix/tests/pjp-agent-link.test.sh`
- Modify: `nix/flake.nix` (checks に `pjp-agent-link-test`)

**Interfaces:**
- Produces (CLI):
  - `pjp-agent-link open attach|start <session>` — 呼んだ env (`SSH_CONNECTION`・`SSH_AUTH_SOCK`・`SSH_AGENT_PID`・`PJP_SSH_CLIENT`) から開いた接続を決め (spec の「開いた接続」の表)、attach なら決め直す。stdout に `SSH_AUTH_SOCK` に入れるパスを 1 行 (WSL の手元などは何も出さない)。session の名前が規則に外れたら何も出さず exit 0。引数が足りなければ exit 2
  - `pjp-agent-link link [<session>]` — session は引数・`HERDR_SESSION`・`default` の順。今の接続へ強制で向け、`<固定名> -> <先> (持ち主 <値>)` を stdout に出して exit 0。pane の中・forward の無い shell では stderr に理由を出して exit 1
  - `bin/ssh-agent-link` — `pjp-agent-link link "$@"`
- Produces (bash 関数。Task 2 が使う): `fixed_path <session>`・`session_of_fixed <path>` (固定名でなければ 1)・`normalize_client <value>`・`probe <sock>` (`keys`・`empty`・`missing`・`refused`・`timeout` を出す)・`alive <sock>`・`read_target <fixed>`・`read_owner <session>`・`swap <session> <exp_target> <exp_owner> <new_target> <new_owner>` (0 入れ替えた / 1 状態が変わっていた / 2 lock を取れない)・`log_line <text>`
- Package: `pkgs.callPackage ./pkgs/pjp-agent-link { }` は `bin/pjp-agent-link` と `bin/ssh-agent-link` を持ち、`meta.mainProgram = "pjp-agent-link"`。runtimeInputs は coreutils・openssh・flock

- [ ] **Step 1: テストの骨組みと attach の表のテストを書く**

`nix/tests/pjp-agent-link.test.sh <pkgs/pjp-agent-link のディレクトリ> <starship.toml>`。偽の HOME・偽の `ssh-add` (`SSH_AUTH_SOCK` の basename で `${FAKE_AGENT_MODES}/<basename>` の `keys`・`empty`・`hang`・`refuse` を引く。socket が無ければ exit 2)・python3 で bind した socket を作る `mksock <path>`。ケース (どれも `readlink`・`owner/<session>`・stdout を見る):

```text
attach: 何も無い HOME           -> ~/.ssh と記録の場所ができ (0700)、agent.sock -> A、owner/default = pc、stdout = ~/.ssh/agent.sock
attach: 生きていて同じマシン      -> 先は変わらない (A のまま。B から開いても)
attach: 死んでいる               -> 開いた接続へ移る
attach: 別のマシン               -> 生きていても移り、持ち主が移る
attach: 持ち主が分からない        -> 生きていても移る (この変更の前の固定名)
attach: 値が届いていない          -> 移り、持ち主は空。次に同じ値の無い接続から開いても移る
attach: 展開されていない値は届いていない扱い  -> PJP_SSH_CLIENT='%u@%L' / 改行入り / local は持ち主が空
attach: 返事をしない先は 1 秒で見切る        -> 先が hang・持ち主が同じでも 5 秒以内に開いた接続へ移る
attach: session ごと             -> --session s2 は agent.s2.sock だけを動かし、agent.sock は触らない
open: ssh -a・SSH_AGENT_PID      -> 張り替えないが stdout は固定名
open: pane の中 (同じ session)    -> 張り替えない。stdout は同じ固定名
open: pane の中 (別の session)    -> 呼んだ pane の固定名の先と持ち主で、別の session の固定名を張る
open: 手元の 1Password           -> agent.sock -> ~/.1password/agent.sock (socket が無くても)、持ち主 local
open: WSL の手元                 -> 何も出さず、固定名も記録も作らない
open: start                     -> 固定名を張り替えずに stdout は固定名
open: session の名前が規則外       -> 何も出さず exit 0
link: 強制で向ける / pane の中は exit 1
```

- [ ] **Step 2: テストを流して落ちることを確かめる**

Run: `bash nix/tests/pjp-agent-link.test.sh nix/pkgs/pjp-agent-link nix/files/starship.toml`
Expected: script が無いので FAIL

- [ ] **Step 3: `pjp-agent-link.sh` の open・link と上の関数、`default.nix` を書く**

attach の決め方 (spec の「向け先の決め方」の 1・2 行目):

```text
3 回まで:
  t = read_target(F); o = read_owner(s)
  t == open_sock:  o == open_client なら終わり、違えば swap(…, open_sock, open_client)
  t != "" && o != "" && o == open_client && alive(t): 終わり (変えない)
  swap(s, t, o, open_sock, open_client) が 0 なら終わり (1 なら決め直す)
```

swap は flock の中で今の先と持ち主を読み直し、期待どおりのときだけ `owner/<s>` を書き (tmp から mv)、`~/.ssh/.pjp-agent-link.<s>.<$$>` に `ln -s` して `mv -fT` で固定名へ入れ替える。入れ替えたら `log_line` で 1 行残す (log が 256 KiB を超えたら後ろの 1000 行にする)。

- [ ] **Step 4: テストを流して通ることを確かめる**

Run: `bash nix/tests/pjp-agent-link.test.sh nix/pkgs/pjp-agent-link nix/files/starship.toml`
Expected: Task 1 のケースがすべて `ok`

- [ ] **Step 5: flake の checks に足して Nix のサンドボックスで流す**

`pjp-agent-link-test = pkgs.runCommand "pjp-agent-link-test" { nativeBuildInputs = [ pkgs.python3 pkgs.flock pkgs.starship ]; } "bash ${./tests/pjp-agent-link.test.sh} ${./pkgs/pjp-agent-link} ${./files/starship.toml}; touch $out"`

Run: `nix build --no-link -L './nix#checks.x86_64-linux.pjp-agent-link-test'`
Expected: 成功

- [ ] **Step 6: Commit** (`feat(nix): herdr の session ごとの固定名の向け先を決める pjp-agent-link を足す (TKT-224)`)

### Task 2: rc・watch・status

**Files:**
- Modify: `nix/pkgs/pjp-agent-link/pjp-agent-link.sh`
- Modify: `nix/tests/pjp-agent-link.test.sh`

**Interfaces:**
- Consumes: Task 1 の関数
- Produces (CLI):
  - `pjp-agent-link rc` — stdout を捨てる。`DISPLAY` があれば stdin の `proto cookie` を sshd(8) の例どおり `xauth -q -` へ渡す (`localhost:N` は `unix:N`)。`SSH_CONNECTION` があり `SSH_AUTH_SOCK` が socket で `SSH_AGENT_PID` が空なら、`tmp/` に書いてから `conn/<basename>` へ rename する
  - `pjp-agent-link watch` — 死んだ socket の記録を消し、全部の固定名 (`~/.ssh/agent.sock`・`~/.ssh/agent.*.sock` の symlink) を見直す。先が 1Password・生きている・持ち主が空なら何もしない。死んでいたら、持ち主と同じ値の記録を `opened` の古い順に見て、生きている最初のものへ swap。`~/.ssh/agent` と `conn/` の名前の一覧が始めと終わりで同じになるまで繰り返す (5 回まで)
  - `pjp-agent-link status` — 固定名ごとの session・先・`probe` の結果・持ち主と、記録ごとの開いた時刻・値・socket・`probe` の結果

- [ ] **Step 1: テストを足す**

```text
rc: stdout は空 (DISPLAY あり・なし)
rc: DISPLAY=localhost:10.0 と cookie で xauth に "add unix:10.0 MIT-MAGIC-COOKIE-1 c0ffee" が渡る / DISPLAY=host:3.0 はそのまま
rc: 記録 (sock・client・opened) を書く。値が無い・%u@%L なら client は空。forward が無い・SSH_AGENT_PID があれば書かない
rc: 何も無い HOME                    -> 記録の場所を 0700 で作って書く
rc: /tmp/ssh-XXXX/agent.123 の形も記録する
watch: 場面 1 (cc-page 0003 の 1〜11 を順に)  -> 各時点の readlink が表のとおり
watch: 覗くだけの接続                 -> 先が生きていれば、増えても減っても変わらない
watch: 別のマシンの接続しか無い        -> 借りない (dangling)
watch: 値が届いていない接続は借りない / 持ち主が空の固定名は借りない
watch: 返事をしない記録を飛ばす         -> hang の記録を 1 秒で見切って次の古いものを借りる
watch: 死んだ socket の記録を消す
watch: 決めている間に attach が張り替えたら上書きしない  -> 偽の ssh-add が死んだ先を確かめられた瞬間に固定名を E (別の値) へ張り替える。watch のあと固定名は E のまま
watch: 1Password の先は触らない
status: 固定名と記録を出す (exit 0)
```

- [ ] **Step 2: 落ちることを確かめる** (Run は Task 1 と同じ。rc・watch・status が無いので FAIL)

- [ ] **Step 3: rc・watch・status を書く**

- [ ] **Step 4: 通ることを確かめる** (Run は Task 1 と同じ。Expected: すべて `ok`)

- [ ] **Step 5: Commit** (`feat(nix): pjp-agent-link に rc・watch・status を足し、接続を記録して死んだ固定名に同じマシンの接続を借りる (TKT-224)`)

### Task 3: herdr を包む実行ファイル

**Files:**
- Create: `nix/pkgs/pjp-agent-link/herdr.sh`
- Create: `nix/pkgs/pjp-agent-link/herdr.nix`
- Modify: `nix/tests/pjp-agent-link.test.sh`

**Interfaces:**
- Consumes: `pjp-agent-link open attach|start <session>` (Task 1)
- Produces: `pkgs.callPackage ./pkgs/pjp-agent-link/herdr.nix { agentLink = <Task 1 の package>; }` — `name = "herdr-${herdr.version}"`、`bin/herdr` が包む script、残り (`share/` の補完と skill) は `pkgs.herdr` の symlink、`passthru.unwrapped = herdr`、`meta.mainProgram = "herdr"`
- `herdr.sh` の置き換え: `@herdr@` (本物の bin/herdr)・`@agentLink@` (bin/pjp-agent-link)・`@timeout@` (coreutils の timeout)。shebang `#!/usr/bin/env bash` は build で store の bash に替える

- [ ] **Step 1: テストを足す** (テストは `herdr.sh` を写して、置き換えを偽の herdr・Task 1 の script・timeout にする。偽の herdr は argv・`SSH_AUTH_SOCK`・読んだ stdin を書き留めて `HERDR-OUT` を出す)

```text
wrapper: 引数はそのまま渡る (空白入りの引数・-- の後ろも)
wrapper: attach とみなす呼び出し   -> herdr / herdr --session s2 / herdr --session=s2 / herdr session attach s2 / herdr remote-client-bridge [--idle-timeout-v1] / --session s2 remote-client-bridge で決め直し、SSH_AUTH_SOCK はその session の固定名
wrapper: 起動だけ                -> herdr server は張り替えず SSH_AUTH_SOCK は固定名
wrapper: 何もしない呼び出し        -> status client --json・server stop・pane list・--remote x・--version・session attach help では SSH_AUTH_SOCK も固定名も変わらない
wrapper: HERDR_SESSION           -> 引数が無ければ HERDR_SESSION の session
wrapper: bridge の stdin と stdout はそのまま  -> stdin の "PING" を偽の herdr が読み、stdout は "HERDR-OUT" だけ
wrapper: WSL の手元               -> env を変えない
wrapper: script が失敗しても herdr は起動する (script を exit 1 する偽物にして)
```

- [ ] **Step 2: 落ちることを確かめる**

- [ ] **Step 3: `herdr.sh` と `herdr.nix` を書く**

`--` より前を見て `--session <v>`・`--session=<v>` を抜く。`-h`・`--help`・`-V`・`--version`・`--default-config`・`--skill`・`--remote*`・`--machine*` があれば何もしない。残りの位置引数が 0 個・先頭が `remote-client-bridge`・`session attach <名前>` (名前が `help` でない 3 個ちょうど) なら attach、`server` 1 個なら start。

- [ ] **Step 4: 通ることを確かめる**

- [ ] **Step 5: Commit** (`feat(nix): herdr を包み、server を起こしうる呼び出しで SSH_AUTH_SOCK を session の固定名にする (TKT-224)`)

### Task 4: home への組み込み (module・shell・ssh・starship)

**Files:**
- Create: `nix/home/modules/agent-link.nix`
- Create: `nix/tests/agent-link.nix`
- Modify: `nix/home/default.nix` (import)
- Modify: `nix/home/modules/packages.nix` (`herdr` を外し、agent-link.nix を指すコメント)
- Modify: `nix/home/modules/fish.nix`・`nix/home/modules/bash.nix` (`herdr`・`ssh-agent-link` の関数を消し、299_ssh_agent の固定名の判定に `~/.ssh/agent.*.sock` を足す)
- Modify: `nix/home/modules/ssh.nix` (`programs.ssh.settings."*".SetEnv.PJP_SSH_CLIENT = "%u@%L"`)
- Modify: `nix/home/modules/claude.nix` (skill は `pkgs.herdr` から張るままで、コメントを直す)
- Modify: `nix/tests/claude-herdr-skill.nix` (home.packages の herdr の `unwrapped or self` の中にあること)
- Modify: `nix/files/starship.toml` (`[custom.pjp_ssh_client]`)
- Modify: `nix/tests/pjp-agent-link.test.sh` (starship のケース)
- Modify: `nix/flake.nix` (checks に `agent-link-state`)

**Interfaces:**
- Consumes: Task 1 の package、Task 3 の herdr.nix
- Produces: `~/.ssh/rc` (text: `exec <store>/bin/pjp-agent-link rc >/dev/null`)、`systemd.user.paths.pjp-agent-link-watch` (`PathChanged = [ "%h/.ssh/agent" "%h/.local/state/pjp-agent-link/conn" ]`、`WantedBy = default.target`)・`systemd.user.services.pjp-agent-link-watch` (oneshot、`pjp-agent-link watch`)。unit は Linux だけ

- [ ] **Step 1: テストを書く**

`nix/tests/agent-link.nix` (評価時の assert と、build で包んだ herdr を見る):

```text
home.packages の herdr は 1 つで、unwrapped が pkgs.herdr / bin/ssh-agent-link と bin/pjp-agent-link がある
.ssh/rc は pjp-agent-link rc を exec し、stdout を /dev/null へ
Linux: path unit の PathChanged が 2 つ、service の ExecStart が pjp-agent-link watch / darwin: unit を置かない
fish の functions に herdr・ssh-agent-link が無い / bash の initExtra に herdr()・ssh-agent-link() が無い
299_ssh_agent が agent.*.sock の shell でフォールバックしない (bash は "${HOME}"/.ssh/agent.*.sock、fish は string match)
~/.ssh/config は Include の後ろに Host * と SetEnv PJP_SSH_CLIENT="%u@%L"
build: bin/herdr は本物の herdr と pjp-agent-link の store のパスを持ち、@ の置き換えが残っていない / bin/herdr --version が herdr の版を出す
```

`pjp-agent-link.test.sh` の starship のケース (starship.toml の `when` を python3 の tomllib で取り出して `sh` で流し、本物の `starship module custom.pjp_ssh_client` でも見る):

```text
starship: ssh の shell で値が空・%u@%L        -> 出す
starship: ssh の shell で値がある              -> 出さない
starship: pane で持ち主が空・無い              -> 出す / 持ち主がある・local -> 出さない
starship: 手元の shell                         -> 出さない
starship: ssh-add を呼ばない (偽の ssh-add の書き留めが空)
```

- [ ] **Step 2: 落ちることを確かめる**

Run: `nix build --no-link -L './nix#checks.x86_64-linux.agent-link-state' './nix#checks.x86_64-linux.pjp-agent-link-test'`
Expected: FAIL

- [ ] **Step 3: module・shell・ssh・starship を直す**

- [ ] **Step 4: 通ることを確かめる**

Run: `nix build --no-link -L './nix#checks.x86_64-linux.agent-link-state' './nix#checks.x86_64-linux.pjp-agent-link-test' './nix#checks.x86_64-linux.claude-herdr-skill' './nix#checks.x86_64-linux.one-password-state'`
Expected: 成功

- [ ] **Step 5: Commit** (`feat(nix): 包んだ herdr・~/.ssh/rc・見張りの unit・SetEnv・starship の警告を home に入れ、shell の herdr 関数を消す (TKT-224)`)

### Task 5: Windows の ssh の設定に `SetEnv`

**Files:**
- Modify: `nix/scripts/bootstrap-windows-ssh-config.sh` (`config_body` の Include の後ろに `Host *` と `  SetEnv PJP_SSH_CLIENT=%u@%L`、何のためかのコメント)
- Modify: `nix/tests/bootstrap-windows-ssh-config.test.sh`

- [ ] **Step 1: テストを直す** (置いた config に `Host *` と `SetEnv PJP_SSH_CLIENT=%u@%L` が Include の後ろにある。前回の中身のまま (記録と同じ) なら正本の更新として上書きされる)
- [ ] **Step 2: 落ちることを確かめる** (`nix build --no-link -L './nix#checks.x86_64-linux.bootstrap-windows-ssh-config-test'`)
- [ ] **Step 3: `config_body` を直す**
- [ ] **Step 4: 通ることを確かめる**
- [ ] **Step 5: Commit** (`feat(nix): Windows の ssh の config に SetEnv PJP_SSH_CLIENT=%u@%L を足す (TKT-224)`)

### Task 6: 文書

**Files:**
- Create: `docs/adr/025_herdr_agent_borrow_20261020T203055JST/README.md`
- Modify: `docs/adr/README.md` (一覧に 025)
- Modify: `docs/adr/008_ssh_agent_stable_sock_20260909T144947JST/README.md`・`docs/adr/022_one_password_outside_wsl_20261018T105655JST/README.md` (冒頭の表に後続 ADR の行)
- Modify: `nix/README.md` (「forward された agent を固定名で見せる」を書き直す)
- Modify: `win/README.md` (ssh の設定の節に `SetEnv` を一言)

- [ ] **Step 1: ADR 025 を書く** (背景・決定・変更点・検討した代替案 (ADR 008 の案 C をそのまま入れる・接続元のアドレス・LC_*・固定名を 1 つ・常駐の inotifywait・lock なし)・影響・検証・移行・運用手順)
- [ ] **Step 2: README の節を直す** (部品・session ごとの固定名・借り方・`AcceptEnv` の要るサーバー・starship の警告・ssh.exe と WSL の ssh の値の違い・`SetEnv` が先に当たる接続先・今動いている server を 1 回作り直す手順・確認と `pjp-agent-link status`・log)
- [ ] **Step 3: 古い ADR の表と一覧を直す**
- [ ] **Step 4: Commit** (`docs: ADR 025 と README に、herdr の session ごとの固定名と同じマシンの接続を借りる仕組みを書く (TKT-224)`)

### Task 7: 全体の確かめと lavie の実機

- [ ] **Step 1: CI と同じ確かめを流す**

```bash
nix develop ./nix --command bash -c 'find nix -name "*.nix" -print0 | xargs -0 nixfmt --check'
nix develop ./nix --command bash -c 'mapfile -t f < <(find nix -type f -name "*.sh" | sort); shfmt -d "${f[@]}"; shellcheck "${f[@]}"'
./nix/scripts/check-test-headers.sh
nix develop ./nix --command ./nix/scripts/check-test-grep-q.sh
nix flake check --all-systems --no-build ./nix
nix flake check --no-eval-cache ./nix
nix eval --json './nix#homeConfigurations.sandbox.config.warnings'   # []
```

(Bash tool では `bash -c` で包まずに script ファイルにして流す)

- [ ] **Step 2: push して lavie で branch の home を当てる** (clone を一時の場所に置き、`--override-input dotfiles` で `pollenjp@laptop` を当てる。lock は書き換えない)
- [ ] **Step 3: 値が届かない場面 (port 22) を試す** (hr を herdr.exe で attach → pane で `ssh-add -l` → detach → attach → `ssh-add -l`、覗くだけの ssh、プロンプトの警告)
- [ ] **Step 4: 値が届く場面 (ユーザー権限の一時の sshd) を試す** (2 つの session の片方ずつを閉じる、素の ssh の端末だけ残す、返事をしない socket は回線断の代わりに `kill -STOP`)
- [ ] **Step 5: 片付ける** (試験用の session を止めて消す・一時の sshd を止める・Windows の試験用の Host のファイルを消す・main の home に戻す・一時の clone を消す)
- [ ] **Step 6: 結果を PR の本文とチケットに書く**
