# pjp-who-is-asking が journal の直近の要求も出す 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pjp-who-is-asking` が、いま動いている木の前に、exe-exec-trace の journal から直近 (既定 180 秒) に起動された agent に届く `.exe` を、Linux 側の祖先の木で出すようにする。

**Architecture:** `who_is_asking.py` に、journal の行から記録を選ぶ・記録を木の節にする・節の行を組み立てる純粋な関数と、`systemctl` / `journalctl` / `/proc` を呼ぶ薄い I/O の関数を足す。`main()` は記録の節を先に、今までの木を後に出す。木の書式は今の `render()` をそのまま使う。

**Tech Stack:** Python 3 (標準ライブラリだけ。`python3 -I`)、unittest、journald (`journalctl -o cat`)、systemd (`systemctl show`)、Nix (flake の `checks` の `pjp-who-is-asking-unittest`)

**Spec:** `docs/adr/020_who_is_asking_recent_journal_20261017T110906JST/README.md` (ADR 020、方針 (案 C) は 2026-10-17 にユーザーが承認。チケットは TKT-69)

## Global Constraints

- 標準ライブラリだけを使う。`nix/pkgs/pjp-who-is-asking/default.nix` の `runtimeInputs` (python3) は変えない。`journalctl` と `systemctl` は PATH の system のもの
- unit の名前は `UNIT = "dotfiles-exe-exec-trace"` (`nix/home/modules/exe-exec-trace.nix`・`scripts/setup.sh` と同じ)
- `--recent SEC` は 0 以上の整数、既定 180。0 なら `systemctl` も `journalctl` も呼ばず、記録の節を出さない
- `journalctl -u dotfiles-exe-exec-trace --since @<int(今 - recent - 5)> -o cat --no-pager` を呼ぶ (`-q` は付けない。権限の Hint を stderr で見るため)。timeout は 20 秒
- `systemctl show --property=LoadState,ActiveState dotfiles-exe-exec-trace` を呼ぶ。timeout は 10 秒
- 「動いている」の判定の幅は記録の時刻と代理プロセスの起動時刻の差が 3000 ms 以内
- 出力の文言は ADR 020 の 2. のとおり。ここに写す:
  - 記録の節の見出し `## 直近 {窓} に起動された要求 (exe-exec-trace の記録、古い順)` (窓は 180 → `3 分`、90 → `90 秒`)
  - 記録の見出し `== {exe 名}  Linux pid {pid}  起動 {HH:MM:SS.mmm} ({N} 秒前)  {状態}`。状態は `動いている (下の木にも出る)` か `終了済み`。他のディストロは `Linux pid` の代わりに `{distro} pid`、状態は `他のディストロ: 祖先は comm だけ`
  - セッションの `/init` の節のラベル `/init  (WSL のセッション)`
  - 末端の注記 `cwd {cwd}`・`env {K=V …}`・`親は /init: 親が先に終了したか、wsl.exe や cmd.exe を踏み台にした要求 (pjp-exe-exec-trace --pretty で直前の .exe を見る)`
  - 2 件以上 `ダイアログの要求は、たいてい一番新しいもの (一番下)`、0 件 `(none: 直近 {窓} に記録された要求は無い)`
  - 読めないとき: `(exe-exec-trace が入っていないので記録は読まない。入れるには dotfiles.wsl.exeExecTrace.enable を true にして setup --update)` / `(exe-exec-trace が動いていない (ActiveState={値})。止まっている間の要求は記録に無い)` / `(journalctl が無いので記録は読まない)` / `(他のユーザーの記録が見えない。adm か systemd-journal のグループに入ると読める)` / `(記録を読めなかった: {理由})`
  - いま動いている木の見出し `## いま動いている ssh.exe など (Windows と Linux の木)` (`--no-windows` では `## いま動いている .exe (Linux 側だけ)`)、該当なし `(none: いま動いている ssh.exe などは無い)` (`--no-windows` の `(none: 動いている .exe は無い)` は今のまま)
- 記録から来る文字列 (exe・argv・cwd・env・cmdline・comm・distro) は表示の前に `safe()` を通す (`render()` を通すか、見出しを `safe()` で包む)
- テストは `journalctl`・`systemctl`・`powershell.exe`・`/proc` に触らない。I/O の関数は `unittest.mock.patch.object(w, …)` で差し替える
- テストファイルの docstring「## 確かめること」を、足したテストに合わせて書き足す (flake の `check-test-headers` の決まり)
- commit メッセージは日本語、`feat(nix): … (TKT-69)` / `docs(…): … (TKT-69)`。末尾に Co-Authored-By と Claude-Session の 2 行

## Review Focus

- 他のディストロの記録 (`distro` が `other(pidns=…)`、argv・cwd・ancestry が無い) → comm だけの木と「他のディストロ」の見出しを出し、`/proc` は見ない (PID の名前空間が違う)。Task 1・2 のテストで押さえる
- 親が先に終わった記録 (`ancestry` の先頭の PID が `kernel_ancestry` の先頭と違う) → 木はカーネルの祖先でたどり、コマンドラインの無い節は comm で出す。Task 1 のテストで押さえる
- 記録の中の改行や ESC (argv・cwd・env・exe・cmdline) → どの行にも生のまま出ない。Task 2 のテストで押さえる
- journal の行の崩れ (JSON でない「Started …」・JSON の配列・キーの欠け・`agent` が false・`time` が読めない・窓より古い) → 黙って飛ばし、例外を出さない。Task 1 のテストで押さえる
- PID の使い回し (記録の PID に、今は別のプロセスや、起動時刻の離れた代理プロセスが居る) → 「終了済み」。Task 1 のテストで押さえる

---

### Task 1: 記録を選び、木の節にする (純粋な関数)

**Files:**
- Modify: `nix/pkgs/pjp-who-is-asking/who_is_asking.py` (「対と木 (純粋な関数)」の節の後ろに「journal の記録 (純粋な関数)」の節を足す)
- Test: `nix/pkgs/pjp-who-is-asking/test_who_is_asking.py`

**Interfaces:**
- Consumes: 今の `join_argv(argv) -> str`、`is_stub(argv) -> bool`
- Produces:
  - 定数 `UNIT = "dotfiles-exe-exec-trace"`、`RECENT_DEFAULT = 180`、`ALIVE_SKEW_MS = 3000`、`SINCE_SLACK_S = 5`、`SESSION_LABEL = "/init  (WSL のセッション)"`、`SESSION_COMM = re.compile(r"^Relay\(\d+\)$")`
  - `record_ms(rec: dict) -> int | None` — `rec["time"]` (例 `2026-10-17T10:35:37.246+09:00`) を epoch ms に。読めなければ None
  - `parse_records(lines: Iterable[str], now_ms: int, window_ms: int) -> list[dict]` — agent の記録のうち `record_ms >= now_ms - window_ms` のものを `record_ms` の昇順で返す。必須は dict で `exe` (str)・`pid` (int)・`kernel_ancestry` (list)・読める `time`・`agent` が true
  - `exe_name(rec: dict) -> str` — `rec["exe"]` の最後の `/` の後ろ
  - `record_nodes(rec: dict) -> list[tuple]` — 根から順の `("L", pid, label, note)` の列。末端が記録の `.exe` で、その note が注記の行の list (無ければ None)
  - `stub_matches(rec: dict, argv: list[str] | None, start: int | None) -> bool` — 記録の PID に今いるプロセスの argv と起動時刻 (epoch ms) が、記録の代理プロセスのものか

- [ ] **Step 1: 失敗するテストを書く** — 記録は実機の 10:35:37 の記録を縮めた `probe_record()` (exe `/mnt/c/Program Files/OpenSSH/ssh.exe`、pid 1037709、time `2026-10-17T10:35:37.246+09:00`、argv `["ssh.exe", "-T", "-o", "BatchMode=yes", "git@github.com"]`、cwd `/home/pollenjp`、env `{"HERDR_PANE_ID": "w1T:pE"}`、kernel_ancestry claude(980424) ← fish(2305724) ← herdr(1256) ← Relay(661)(660) ← SessionLeader(659) ← systemd(1)、ancestry 980424 `claude --remote-control` / 2305724 `fish` / 1256 `herdr server` / 660 `/init` / 659 `/init`) を作る関数で用意する。

  確かめること (1 項目 1 つのテスト):
  1. `TestRecordMs`: `record_ms(probe_record())` が `int(datetime.fromisoformat("2026-10-17T10:35:37.246+09:00").timestamp() * 1000)`。`time` が `"x"`・欠け・数値なら None
  2. `TestParseRecords.test_keeps_agent_records_in_window_oldest_first`: 新しい順に並べた agent の記録 2 件 (窓の中) を JSON の行で渡すと、古い順の 2 件が返る
  3. `test_skips_lines_that_are_not_records`: `"Started dotfiles-exe-exec-trace.service"`・`"[1, 2]"`・`{"exe": …}` だけ (kernel_ancestry 無し)・`time` が `"x"`・`pid` が文字列 の行はどれも飛ばし、例外を出さない
  4. `test_skips_non_agent_and_old_records`: `agent` が false の記録と、`now_ms - window_ms` より 1 ms 古い記録は返らず、ちょうど `now_ms - window_ms` の記録は返る
  5. `TestRecordNodes.test_stops_at_the_session_init_and_uses_command_lines`: `[(pid, label) …]` が `[(660, "/init  (WSL のセッション)"), (1256, "herdr server"), (2305724, "fish"), (980424, "claude --remote-control"), (1037709, "ssh.exe -T -o BatchMode=yes git@github.com")]`。末端の note が `["cwd /home/pollenjp", "env HERDR_PANE_ID=w1T:pE"]`
  6. `test_falls_back_to_comm_when_the_parent_had_exited`: ancestry を `[{"pid": 660, "cmdline": "/init"}]` だけにすると (付け替え後)、ラベルが `/init  (WSL のセッション)`・`herdr`・`fish`・`claude` (comm)
  7. `test_other_distro_record_uses_comm_and_relay`: distro `other(pidns=4026532000)`、argv・cwd・env・ancestry 無し、kernel_ancestry `bash(30)` ← `Relay(29)(28)` → ラベルが `/init  (WSL のセッション)`・`bash`・`ssh.exe` で、末端の note が None
  8. `test_parent_is_session_init_adds_a_hint`: kernel_ancestry が `Relay(5)(4)` だけ → 末端の note に `親は /init: 親が先に終了したか、wsl.exe や cmd.exe を踏み台にした要求 (pjp-exe-exec-trace --pretty で直前の .exe を見る)`
  9. `test_without_session_init_shows_the_whole_chain`: `/init` も `Relay(…)` も無い kernel_ancestry 3 件 → 3 件とも節になる
  10. `TestStubMatches`: argv `["/init", "/mnt/c/Program Files/OpenSSH/ssh.exe", "ssh.exe", "-T"]` で起動時刻が記録 + 2000 ms → True。+ 4000 ms → False。argv が `["bash"]` → False。argv の exe 名が `ssh-add.exe` → False。argv が None → False。distro が other → False

- [ ] **Step 2: 失敗を確かめる**

Run: `cd nix/pkgs/pjp-who-is-asking && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_who_is_asking 2>&1 | tail -5`
Expected: FAIL (`AttributeError: module 'who_is_asking' has no attribute 'record_ms'` など)

- [ ] **Step 3: Interfaces の関数と定数を実装する** — `record_ms` は `datetime.datetime.fromisoformat` (`ValueError`・`TypeError` で None)。`record_nodes` は ancestry から `{pid: cmdline}` を作り、kernel_ancestry を近い方から見て、cmdline が `/init` か (cmdline が無く) comm が `SESSION_COMM` に当たったら `SESSION_LABEL` の節を足して止める。ラベルは cmdline、無ければ comm。末端のラベルは `join_argv([exe_name(rec)] + [str(a) for a in argv[1:]])` (argv が空でない list でなければ `exe_name(rec)`)

- [ ] **Step 4: 通ることを確かめる**

Run: `cd nix/pkgs/pjp-who-is-asking && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_who_is_asking 2>&1 | tail -3`
Expected: `OK` (今の 26 件 + 足した分)

- [ ] **Step 5: Commit**

```bash
git add nix/pkgs/pjp-who-is-asking/who_is_asking.py nix/pkgs/pjp-who-is-asking/test_who_is_asking.py
git commit -m "feat(nix): pjp-who-is-asking に exe-exec-trace の記録を選んで木にする関数を足す (TKT-69)"
```

### Task 2: 記録の節を出し、main に組み込む (I/O と CLI) と文書

**Files:**
- Modify: `nix/pkgs/pjp-who-is-asking/who_is_asking.py` (I/O の関数・節を組む関数・`main()`・module docstring)
- Test: `nix/pkgs/pjp-who-is-asking/test_who_is_asking.py`
- Modify: `nix/home/modules/exe-exec-trace.nix` (先頭のコメント: 1. に「記録が入っていれば直近の要求も出す」、unit の名前を揃える相手に `nix/pkgs/pjp-who-is-asking/who_is_asking.py` の `UNIT`)
- Modify: `nix/README.md` (道具の表の `pjp-who-is-asking` の行と、「ダイアログが出ている間なら、その場で木を出す方が早い。」の段落とコマンド例を、ADR 020 の 7. に合わせる)
- Modify: `docs/adr/README.md` (一覧に `| [020](./020_who_is_asking_recent_journal_20261017T110906JST/README.md) | pjp-who-is-asking は、要求元が先に終わっていても出せるよう、exe-exec-trace の journal から直近の要求も出す | 2026-10-17 |`)
- Modify: `docs/adr/012_wsl_exe_exec_trace_service_20260930T153253JST/README.md` (TKT-72 の追記の後ろ、`---` の前に「追記 (2026-10-17、TKT-69)」: who-is-asking が journal の直近の要求も出すようにしたこと・理由 1 文・ADR 020 へのリンク・本文はそのまま)

**Interfaces:**
- Consumes: Task 1 の `UNIT`・`RECENT_DEFAULT`・`SINCE_SLACK_S`・`record_ms`・`parse_records`・`exe_name`・`record_nodes`・`stub_matches`、今の `render`・`safe`・`hhmmss`・`ago`・`argv_of`・`start_ms`・`boot_time`・`NOW`
- Produces:
  - `fmt_window(sec: int) -> str`
  - `parse_unit_state(text: str) -> tuple[str | None, str | None]` — `systemctl show` の `LoadState=…` / `ActiveState=…` の行から (LoadState, ActiveState)
  - `journalctl_message(returncode: int, stderr: str) -> str | None` — 読めなかったときの 1 行 (権限の Hint なら権限の行、0 でない終了コードなら `(記録を読めなかった: {stderr の最初の行 か "終了コード {n}"})`)、読めたら None
  - `unit_state() -> tuple[str | None, str | None]` (I/O。`systemctl` が無い・失敗・timeout なら `(None, None)`)
  - `read_journal(since_s: int) -> tuple[list[str], str | None]` (I/O。`journalctl` が無ければ `([], "(journalctl が無いので記録は読まない)")`、timeout なら `([], "(記録を読めなかった: 20 秒で返らなかった)")`)
  - `is_alive(rec: dict, boot: float) -> bool` (I/O。`stub_matches(rec, argv_of(pid), start_ms(pid, boot))`。distro が `this` でなければ /proc を見ずに False)
  - `journal_body(recs: list[dict], alive: Callable[[dict], bool], recent_s: int) -> list[str]` — 見出しを除く節の中身 (0 件の行、または記録ごとの見出しと `render(record_nodes(rec))` の行と空行、2 件以上なら最後の 1 行)
  - `journal_lines(recent_s: int, boot: float) -> list[str]` — 節の見出し + 状態を見て読んで `journal_body` + (止まっていれば) 動いていない行 + 空行
  - `main(argv=None)` に `--recent` (type は 0 以上の int。負なら argparse のエラー)

- [ ] **Step 1: 失敗するテストを書く** — 確かめること (1 項目 1 つのテスト):
  1. `TestFmtWindow`: 180 → `"3 分"`、60 → `"1 分"`、90 → `"90 秒"`
  2. `TestParseUnitState`: `"LoadState=loaded\nActiveState=active\n"` → `("loaded", "active")`、`"LoadState=not-found\nActiveState=inactive\n"` → `("not-found", "inactive")`、`""` → `(None, None)`
  3. `TestJournalctlMessage`: rc 0・stderr 空 → None。rc 0・stderr に `Hint: You are currently not seeing messages from other users and the system.` → 権限の行。rc 1・stderr `Failed to open journal\nmore` → `(記録を読めなかった: Failed to open journal)`。rc 1・stderr 空 → `(記録を読めなかった: 終了コード 1)`
  4. `TestJournalBody.test_shows_each_record_as_a_tree_with_state`: `probe_record()` 1 件、alive が False、`NOW` を patch して記録の 35 秒後にする → 出力が次の行の列と完全に一致する (期待値は手で書いた文字列。`render` や `record_nodes` で作らない)。alive が True なら 1 行目の状態だけが `動いている (下の木にも出る)` に変わる

     ```
     == ssh.exe  Linux pid 1037709  起動 10:35:37.246 (35 秒前)  終了済み
     [Linux  ] 660 /init  (WSL のセッション)
     [Linux  ] └─ 1256 herdr server
     [Linux  ]   └─ 2305724 fish
     [Linux  ]     └─ 980424 claude --remote-control
     [Linux  ]       └─ 1037709 ssh.exe -T -o BatchMode=yes git@github.com
     [Linux  ]            cwd /home/pollenjp
     [Linux  ]            env HERDR_PANE_ID=w1T:pE
     (空行)
     ```

     `hhmmss` はローカル時刻で出すので、テストのモジュールの最初に `os.environ["TZ"] = "JST-9"; time.tzset()` を置き、最後に戻す (`JST-9` は zoneinfo の無い Nix のサンドボックスでも効く POSIX の書き方)
  5. `test_other_distro_heading`: 他のディストロの記録 → 見出しが `== ssh.exe  other(pidns=4026532000) pid 31  起動 … 他のディストロ: 祖先は comm だけ` の形 (alive を呼ばない)
  6. `test_none_and_newest_hint`: 0 件 → `["(none: 直近 3 分に記録された要求は無い)", ""]`。2 件 → 最後の行が `ダイアログの要求は、たいてい一番新しいもの (一番下)`
  7. `test_control_characters_in_records_are_escaped`: exe を `/mnt/c/x\x1b[2J.exe`、argv に `"a\nb"`、cwd に `"/tmp/\x1b]0;x\x07"` → どの行にも `\x1b`・`\n`・`\x07` が生で入らない
  8. `TestJournalLines.test_not_installed_skips_reading`: `unit_state` を `("not-found", "inactive")` に patch、`read_journal` を呼ばれたら失敗する Mock にする → `[見出し, 入っていない行, ""]`
  9. `test_inactive_unit_still_reads_and_warns`: `("loaded", "failed")`・`read_journal` は記録 1 件の行 → 記録の見出しが出て、最後から 2 行目が `(exe-exec-trace が動いていない (ActiveState=failed)。止まっている間の要求は記録に無い)`
  10. `test_read_failure_is_one_line`: `read_journal` が `([], "(journalctl が無いので記録は読まない)")` → `[見出し, その行, ""]`
  10b. `test_unknown_unit_state_still_reads`: `unit_state` が `(None, None)` (systemctl が無い) → `read_journal` を呼び、記録を出し、動いていない行は出さない
  11. `TestMain.test_recent_zero_skips_the_journal`: `linux_stubs` を `{}` に、`journal_lines` を呼ばれたら失敗する Mock に patch し、`main(["--no-windows", "--recent", "0"])` の stdout が `## いま動いている .exe (Linux 側だけ)` と `(none: 動いている .exe は無い)` を含み、`## 直近` を含まない
  12. `test_journal_section_comes_first`: `journal_lines` を `["## 直近 3 分に起動された要求 (exe-exec-trace の記録、古い順)", "x", ""]` に patch → `main(["--no-windows"])` の stdout で `## 直近` が `## いま動いている` より前
  13. `test_negative_recent_is_rejected`: `main(["--recent", "-1"])` が `SystemExit` (argparse の終了コード 2)
  14. `test_windows_mode_heading_and_none_line`: `windows_procs` を `{}`・`linux_stubs` を `{}`・`journal_lines` を `[]` に patch → `main([])` の stdout が `## いま動いている ssh.exe など (Windows と Linux の木)` と `(none: いま動いている ssh.exe などは無い)` を含む

- [ ] **Step 2: 失敗を確かめる**

Run: `cd nix/pkgs/pjp-who-is-asking && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_who_is_asking 2>&1 | tail -5`
Expected: FAIL (`fmt_window` などが無い)

- [ ] **Step 3: Interfaces の関数を実装し、main を組み直す** — `main()` は `--no-windows` の有無にかかわらず、`opts.recent > 0` なら最初に `journal_lines(opts.recent, boot)` を出す (Windows 側を取る前に `print(..., flush=True)` で先に出す)。そのあと今までの木の前に Global Constraints の見出しを出し、Windows の該当なしの行を `(none: いま動いている ssh.exe などは無い)` にする。module docstring に「ダイアログに気付いた時点で要求元が終わっていることがある (Claude Code の確かめは 3 秒) ので、exe-exec-trace の記録から直近の要求も出す。経緯は ADR 020」を足す。`journal_body` の見出しは `safe()` で包む

- [ ] **Step 4: 通ることを確かめる**

Run: `cd nix/pkgs/pjp-who-is-asking && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_who_is_asking 2>&1 | tail -3`
Expected: `OK`

- [ ] **Step 5: テストの docstring と文書を直す** — `test_who_is_asking.py` の「## 確かめること」に、記録の選び方・木・状態・読めないとき・main の順と `--recent` を 1 行ずつ足す。Files の 5 つの文書を直す

- [ ] **Step 6: flake の check を通す**

Run: `nix build ./nix#checks.x86_64-linux.pjp-who-is-asking-unittest -L 2>&1 | tail -5` と `nix build ./nix#checks.x86_64-linux.check-test-headers-test -L 2>&1 | tail -3`
Expected: どちらも成功 (Nix の python3 で unittest が `OK`)

- [ ] **Step 7: Commit**

```bash
git add nix/pkgs/pjp-who-is-asking nix/home/modules/exe-exec-trace.nix nix/README.md docs/adr
git commit -m "feat(nix): pjp-who-is-asking が exe-exec-trace の journal から直近の要求も出す (TKT-69)"
```

### Task 3: 実機で確かめ、ADR 020 の検証の節を書く

**Files:**
- Modify: `docs/adr/020_who_is_asking_recent_journal_20261017T110906JST/README.md` (6. 検証)

**Interfaces:**
- Consumes: Task 2 までの `pjp-who-is-asking` (`nix run ./nix#pjp-who-is-asking -- …` で、switch せずに動かす)

- [ ] **Step 1: 実機で動かす** — agent に触れずに記録を作るため、`ssh -V` (ラッパー経由で `ssh.exe -V`。版を出して終わるだけで、1Password に届かない) を 1 回打つ → 直後に `nix run ./nix#pjp-who-is-asking -- --no-windows` と `nix run ./nix#pjp-who-is-asking --` を打つ。
  Expected: 記録の節に `ssh.exe -V` の記録が `終了済み` で出て、木がこのセッションの claude まで届く。`--recent 0` で節が出ない。`--recent 7200` で 10:26〜10:35 の Claude Code の確かめ 6 件が、それぞれの claude まで届く木で出る (本番の記録で木が組めること)

- [ ] **Step 2: ADR 020 の 6. を書く** — unittest の件数 (手元の python 3.12 と flake の check)、実機で見た出力 (抜粋)、確かめていないこと (権限の無いユーザーでの Hint・他のディストロの記録・止まった unit) を書く

- [ ] **Step 3: Commit**

```bash
git add docs/adr/020_who_is_asking_recent_journal_20261017T110906JST/README.md
git commit -m "docs(adr): ADR 020 の検証の節に、テストと実機の結果を書く (TKT-69)"
```
