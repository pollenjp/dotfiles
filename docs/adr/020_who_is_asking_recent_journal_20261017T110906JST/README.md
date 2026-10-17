# ADR: pjp-who-is-asking は、要求元が先に終わっていても出せるよう、exe-exec-trace の journal から直近の要求も出す

| 項目 | 内容 |
| --- | --- |
| ステータス | 承認 (Accepted) — 方針 (下の 4. の案 C) は 2026-10-17 にユーザーが承認 |
| 日付 | 2026-10-17 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-69](https://app.notion.com/p/pjp-who-is-asking-1Password-SSH-4cb73f40bc434dd7b4d76d9191b3b6cd) |
| 前提 ADR | [012](../012_wsl_exe_exec_trace_service_20260930T153253JST/README.md)（`pjp-exe-exec-trace` と `pjp-who-is-asking`。本 ADR は後者の出し方を変える） |
| 運用手順 | [`nix/README.md`「WSL の .exe の起動を常時記録する」](../../../nix/README.md#wsl-の-exe-の起動を常時記録する) |

---

## 1. 背景 (Context)

### `pjp-who-is-asking` は「いま動いている」要求元しか見ない

ADR 012 の `pjp-who-is-asking` は、1Password の承認ダイアログが出ている間に打つ道具。
承認を待つ間は `ssh.exe` が agent の応答を待って止まっている、という前提で、
いま動いている `ssh.exe` などを探し、Windows と Linux をまたいだ 1 本の木で出す。

### 要求元が先に終わると、何も出ない

2026-10-17 に、1Password が「Allow 17239a09.rbf to use SSH key」を数分おきに出した。
`pjp-who-is-asking` は無関係の長い接続 (`ssh -A pollenjp@lavie.local`) しか出さず、
要求元が分からなかった。調べると次のとおりだった。

- 要求元は Claude Code 2.1.300 だった。plugin の marketplace を取りに行く前に
  `ssh -T -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=yes git@github.com`
  で GitHub に SSH で入れるかを確かめていた (10:26〜10:35 に 6 つの claude プロセスが 1 回ずつ)
- Claude Code はこの ssh に timeout 3000 ms を付けて kill する。WSL 側の代理プロセスを kill すると、
  Windows 側の `ssh.exe` も一緒に終わる (`timeout 3 powershell.exe …` で確かめた)
- 1Password のダイアログは要求元が消えても残り、約 60 秒で時間切れになる
- そのため、ダイアログに気付いてから打つと、要求元はもう居ない。
  TKT-69 (2026-10-02、`ntn login` の直後に「対象なし」) も同じ形だった見込み (journal が残っておらず未確認)
- 一方、`pjp-exe-exec-trace` の journal には、消えた要求元も argv・cwd・env・祖先付きで残っていた

```
0 秒        3 秒                                             約 60 秒
|-- ssh.exe --|  ← Claude Code が kill
|---------------- 1Password のダイアログ ----------------------|
                 ↑ ここから先に who-is-asking を打っても、ssh.exe はもう居ない
```

ダイアログに出た「17239a09.rbf」は、同じ朝に PowerShell 7 が MSI で更新されたとき、使用中の
`pwsh.exe` が `C:\Config.Msi\` へ退避された名前だった。1Password は要求元の祖先 (WSL を起動した
`pwsh.exe`) を「アプリ」として、その exe の今のファイル名を出す。要求元の手掛かりにはならない。

調査の全体は TKT-69 と、そこに貼った図を参照。

## 2. 決定 (Decision)

### A. journal の直近の記録を、いま動いている木より先に出す

`pjp-who-is-asking` は、`journalctl -u dotfiles-exe-exec-trace` から直近の記録を読み、agent に届く
`.exe` (記録の `agent` が true) の起動を古い順に出す。そのあとに、今までの「いま動いている木」を出す。

- 遡る長さは既定 180 秒。`--recent SEC` で変える。`--recent 0` なら journal を読まず、今までと同じ
  中身になる (見出しの行だけが増える)
- 記録の節を先に出すのは、要求元は短命なことが多く、答えはたいていこちらにあるため。いま動いている
  木は `powershell.exe` で 1〜2 秒かかるので、先に出せる方を先にする
- `--no-windows` でも記録の節は出す (Linux 側だけで完結するため)

出力の形:

```
## 直近 3 分に起動された要求 (exe-exec-trace の記録、古い順)
== ssh.exe  Linux pid 1037709  起動 10:35:37.246 (35 秒前)  終了済み
[Linux  ] 660 /init  (WSL のセッション)
[Linux  ] └─ 661 -fish
[Linux  ]   └─ 1255 herdr
[Linux  ]     └─ 1256 /nix/store/…-herdr-0.9.1/bin/herdr server
[Linux  ]       └─ 2305724 fish
[Linux  ]         └─ 980424 claude --remote-control …
[Linux  ]           └─ 1037709 ssh.exe -T -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=yes git@github.com
[Linux  ]                cwd /home/pollenjp
[Linux  ]                env HERDR_PANE_ID=w1T:pE WSL_INTEROP=/run/WSL/660_interop

## いま動いている ssh.exe など (Windows と Linux の木)
== ssh.exe  Windows pid 43356  起動 00:37:10.295 (36159 秒前)
[Windows] …
```

### B. 記録 1 件の出し方

| 部分 | 中身 |
| --- | --- |
| 見出し | `== <exe 名>  Linux pid <pid>  起動 <HH:MM:SS.mmm> (<N> 秒前)  <状態>`。状態は「動いている (下の木にも出る)」か「終了済み」。他のディストロの記録は `Linux pid` の代わりに記録の `distro` をそのまま出し、状態は「他のディストロ: 祖先は comm だけ」 |
| 木 | カーネルが exec の時点で集めた祖先 (`kernel_ancestry`) を、要求元に近い方からセッションの `/init` までたどり、根から順に出す。各節のラベルは、`/proc` で取れた祖先のコマンドライン (`ancestry`) を PID で引いて使い、無ければ comm を使う |
| セッションの `/init` | コマンドラインが `/init` の最初の祖先 (WSL では comm が `Relay(<pid>)`)。コマンドラインが無ければ comm が `Relay(<数字>)` のもの。ラベルは `/init  (WSL のセッション)`。見つからなければ祖先を最後まで出す |
| 末端 | 記録の PID と、`<exe 名> <argv[1:]>` (argv をシェルの引用でつなぐ。argv が無ければ exe 名だけ) |
| 末端の注記 | `cwd <cwd>`、`env <K=V …>` (記録にあるものだけ)。セッションの `/init` の直下が末端なら「親は /init: 親が先に終了したか、wsl.exe や cmd.exe を踏み台にした要求 (pjp-exe-exec-trace --pretty で直前の .exe を見る)」 |
| 書式 | 今の `render()` (`[Linux  ]` と `└─`) をそのまま使う。記録の中身は記録される側が決められるので、制御文字は `safe()` で `\xNN` にする |

- 2 件以上あれば、節の最後に「ダイアログの要求は、たいてい一番新しいもの (一番下)」を出す
- 1 件も無ければ `(none: 直近 3 分に記録された要求は無い)` を出す
- 節の見出しの長さは、180 秒なら「3 分」、60 で割り切れなければ「90 秒」のように秒で出す

### C. 動いているかどうか

記録の `distro` が `this` で、記録の PID の `/proc` が interop の代理プロセス (`argv[0]` が `/init`、
`argv[1]` の exe 名が記録の exe 名と同じ) で、その起動時刻が記録の時刻と 3 秒以内なら「動いている」。
それ以外は「終了済み」。PID が使い回されていても、起動時刻で見分ける。

### D. 記録を読めないとき

記録の節は 1 行で知らせて終わり、いま動いている木は今までどおり出す。

| 場面 | 見分け方 | 出す 1 行 |
| --- | --- | --- |
| unit が入っていない | `systemctl show --property=LoadState,ActiveState dotfiles-exe-exec-trace` の `LoadState` が `not-found` | `(exe-exec-trace が入っていないので記録は読まない。入れるには dotfiles.wsl.exeExecTrace.enable を true にして setup --update)` |
| unit が止まっている | 同じく `ActiveState` が `active` でない | 記録は読んで出し、節の最後に `(exe-exec-trace が動いていない (ActiveState=<値>)。止まっている間の要求は記録に無い)` |
| `journalctl` が無い | 起動できない | `(journalctl が無いので記録は読まない)` |
| 他のユーザーの記録が見えない | `journalctl` の stderr に `not seeing messages from other users` か `insufficient permissions` | `(他のユーザーの記録が見えない。adm か systemd-journal のグループに入ると読める)` |
| `journalctl` が失敗した | 終了コードが 0 でない・20 秒で返らない | `(記録を読めなかった: <理由>)` |

- `systemctl` が無い・失敗したときは、unit の状態は見ずに journal を読む
- `journalctl` と `systemctl` は system のもの (PATH) を使う。journal の形式は system の journald と
  揃っている方が確実で、flake の閉包に systemd を足さない
- `--since` には「今 − 遡る長さ − 5 秒」を `@<epoch 秒>` で渡し、記録の `time` で遡る長さに絞り直す
  (journald の時刻と記録の時刻は数 ms ずれる)
- 読めない行 (JSON でない・形が欠けている・`time` が読めない) は黙って飛ばす

### E. いま動いている木の見出し

今までの出力の前に `## いま動いている ssh.exe など (Windows と Linux の木)` を出す。
`--no-windows` では `## いま動いている .exe (Linux 側だけ)`。
該当が無いときの行は `(none: いま動いている ssh.exe などは無い)` にする
(「承認待ちの」を外す。承認待ちの要求元が既に終わっていることがあるため)。

### 流れ

```
pjp-who-is-asking
  ├─ systemctl show … dotfiles-exe-exec-trace   (入っているか・動いているか)
  ├─ journalctl -u dotfiles-exe-exec-trace --since @… -o cat
  │     └─ agent の記録を古い順に、kernel_ancestry と ancestry から木にして出す   ← 今回足す
  └─ powershell.exe (Get-CimInstance) と /proc
        └─ いま動いている ssh.exe などを、Windows と Linux をまたいだ木で出す   ← 今まで
```

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/pkgs/pjp-who-is-asking/who_is_asking.py` | 記録の節を足す (記録を読む・絞る・木にする・状態を見る)。`--recent`。いま動いている木の見出し |
| `nix/pkgs/pjp-who-is-asking/test_who_is_asking.py` | 記録の節のテストを足す。`journalctl`・`systemctl`・`/proc` には触らない |
| `nix/home/modules/exe-exec-trace.nix` | コメント: unit の名前を揃える相手に `pjp-who-is-asking` を足す。who-is-asking が記録も読むこと |
| `nix/README.md` | 道具の表と、ダイアログが出たときの使い方 |
| `docs/adr/README.md` | 一覧に 020 |
| `docs/adr/012_…/README.md` | 冒頭に追記 (本 ADR への導線)。本文はそのまま |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| A. その都度 Deny するだけにする | 誰が要求したかは分からないまま |
| B. Claude Code に `CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1` を渡し、確かめそのものを止める | 今回の要求は止まるが、ほかの短命な要求元 (裏で走る `git fetch` など) は同じ形で消える。別の話として扱う (今回はユーザーが選ばなかった) |
| D. WSL を起動した `pwsh.exe` を開き直し、表示名を `pwsh.exe` に戻す | 名前が戻るだけで要求元は分からない。herdr とその中の Claude Code も落ちる |
| 案内だけ足す (「`pjp-exe-exec-trace --pretty` を見る」) | 2 つのコマンドを行き来する。`--pretty` は祖先を 1 行に並べるので、木で見るより追いにくい |
| 次の要求を待ち構える `--wait` / 常駐モード | ダイアログに気付いた時点の要求は、もう起動し終わっている。待ち構えるなら記録 (常駐のトレーサ) が既にある |
| 1Password のログとダイアログを突き合わせる | ログには要求元の PID が無く、結末 (拒否・時間切れ) が時刻とともに残るだけ。ログの形式は 1Password の内部で、変わりうる |
| 記録の踏み台 (`wsl.exe` / `cmd.exe`) もたどって対にする | 今回の要求 (直接の呼び出し) には要らない。祖先が `/init` で途切れた記録には案内を付けるにとどめる |
| `pjp-exe-exec-trace` の `format_record` を import して使う | 別のパッケージ (bcc を持つ) に依存することになる。`pjp-who-is-asking` は `wsl.enable` だけのマシンにも入る |

## 5. 影響 (Consequences)

### 良くなること

- ダイアログに気付いてから打っても、直近 3 分の要求元が出る (Claude Code の確かめのような、3 秒で終わる要求元も)
- exe-exec-trace が入っていないマシンでも今までどおり動く (記録の節に 1 行の案内が出るだけ)

### 注意が必要なこと

- 記録は「起動された」ことしか分からない。どの記録がいまのダイアログの要求かは、時刻から推すしかない
  (1Password は要求元の PID を外に出さない)。承認済みのセッションから黙って通った要求も記録に並ぶ
- 記録を読むには `adm` か `systemd-journal` のグループが要る (`pollenjp@wsl` は `adm` に入っている)
- 記録の中身 (argv・cwd・env・祖先のコマンドライン) は記録される側が決められる。表示では制御文字を
  `\xNN` にする (ADR 012 と同じ)
- unit の名前 `dotfiles-exe-exec-trace` を持つ場所が 3 つになる (`exe-exec-trace.nix`・`scripts/setup.sh`・
  `who_is_asking.py`)

## 6. 検証 (Verification)

実装のあとに書く。

## 7. 移行・運用手順

```sh
pjp-who-is-asking                # 直近 3 分の記録と、いま動いている木 (Windows 側は powershell.exe で 1〜2 秒)
pjp-who-is-asking --recent 600   # 直近 10 分まで遡る
pjp-who-is-asking --recent 0     # 記録を読まない
pjp-who-is-asking --no-windows   # Windows 側を省く (記録の節は出す)
```

switch で入れ替わる。unit (トレーサ) は変えないので、`setup --update` の sudo の手順は要らない。
