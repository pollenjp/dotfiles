# ADR: WSL から起動された Windows の .exe を eBPF で常時記録する system の unit を、setup の手順で入れる

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-09-30 (JST) |
| 決定者 | pollenjp |
| チケット | [TKT-63](https://app.notion.com/p/WSL-exe-eBPF-system-systemd-unit-dotfiles-TKT-54-3eb79149a66f8145aaa0cafd4a428763)（前段の調査は [TKT-54](https://app.notion.com/p/WSL-1Password-SSH-e0aab9b7d18e4b95ab423a8b1d17ec0d)） |
| 前提 ADR | [004](../004_nix_wsl_ssh_wrapper_20260811T124616JST/README.md)（WSL の ssh を Windows の `ssh.exe` へ回すラッパー。本 ADR はその経路を通る要求を記録する） |
| 運用手順 | [`nix/README.md`「WSL の .exe の起動を常時記録する」](../../../nix/README.md#wsl-の-exe-の起動を常時記録する) |

---

## 1. 背景 (Context)

### 1Password のダイアログでは、要求元の Linux プロセスが分からない

ADR 004 のラッパーにより、WSL の `ssh` は Windows の `ssh.exe` として 1Password の
agent (`\\.\pipe\openssh-ssh-agent`) に届く。TKT-54 で実機を調べると、次のことが分かった。

- ダイアログが示す要求元は「Windows Terminal」だけで、Linux 側のどのプロセスかは出ない
- 1Password のログにも要求元は残らない。承認のときに `invoked auth prompt unlock` が 1 行出る程度
- 承認は WSL のセッション (タブの `wsl.exe`) 単位で効く。承認した後は、同じタブのどのプロセス
  (herdr の別ペインや Claude Code など) もダイアログ無しで鍵を使える
- `sshSessionDuration = infinite` の設定では、この状態が 1Password を終了するまで続く

つまりダイアログで分かるのは最初の 1 回の要求元だけで、その後の利用は何も残らない。

### 要求元が分かるのは Linux 側だけ

interop で起動した `.exe` は、Linux 側に `comm=<名前>.exe` の代理プロセス (実体は `/init`) を
残す。その祖先が要求元になる。調査では次の 2 つを試作し、実機で確かめた。

| 道具 | 使いどころ | 仕組み |
| --- | --- | --- |
| `exe-exec-trace` | 常時記録 | bcc で `sched_process_exec` を見て、`.exe` の起動ごとに祖先を記録する。黙って通った要求も残る |
| `who-is-asking` | ダイアログが出ている間 | Linux 側の代理プロセスと Windows 側のプロセスを対にして、`explorer.exe` から `ssh.exe` までを 1 本の木で出す |

### root の unit を入れる仕組みが無い

eBPF には root が要るので、`exe-exec-trace` は systemd の system の unit として動かすことになる。
一方この dotfiles が管理するのは home-manager (ユーザーの環境) で、system の unit を置く経路は無い。
sudo を使うのは setup の手順 7 (`chsh` のための `/etc/shells`) だけで、それも既定の手順には入れていない。

## 2. 決定 (Decision)

### A. トレーサは nixpkgs の bcc で包んだパッケージにする

`nix/pkgs/exe-exec-trace/` に script を置き、`writeShellApplication` で
`python3.withPackages [ bcc ]` と `kmod` を PATH に入れて動かす。`kmod` は、bcc がカーネル
ヘッダ (WSL のカーネルは `CONFIG_IKHEADERS=m`) を読むための `modprobe kheaders` に使う。
Linux の system だけ、flake の `packages` にも出す。

BPF とカーネルに触らない純粋な部分 (記録の組み立て・整形・`who-is-asking` の対の取り方と木) は
unittest にし、flake の `checks` に載せる (Linux だけ)。CI の `nix flake check` で毎回流れる。

### B. option が true のとき、home-manager が unit を生成する

`dotfiles.wsl.exeExecTrace.enable` (既定 false、`wsl.enable` のときだけ意味を持つ) を足す。
true のとき、home-manager は次の 2 つを置く。

- unit ファイル `~/.local/share/dotfiles/systemd/dotfiles-exe-exec-trace.service`。
  `ExecStart` は `/nix/store/…-exe-exec-trace/bin/exe-exec-trace --json` の固定パスにする
- ユーザーの PATH の `exe-exec-trace`。記録を読むときの `--pretty` に使う (root で記録するのは unit の側)

登録簿の `pollenjp@wsl` で true にする。

### C. /etc へ入れるのは setup の手順 `exe-exec-trace` (中で sudo を呼ぶ)

`~/dotfiles/setup --steps exe-exec-trace` が次をする。`chsh` と同じく、既定の手順
(新規マシン・既存マシンの更新) には入れない。`sudo` を付けて打つと `HOME` が root のものに
なって生成された unit を見失う (option が無効と取り違えて消してしまう) ので、root では断る。

- option が true: 生成された unit を `/etc/systemd/system/` へ複製し、unit の store パスへ
  GC root (`/nix/var/nix/gcroots/dotfiles-exe-exec-trace`) を張って、`daemon-reload` →
  `enable` → `restart` する。中身が同じなら、有効になっていて動いていることだけ確かめる
  (止まっていれば起こす)
- option が false: unit が入っていれば `disable --now` して、unit と GC root を消す

unit は `Type=notify` にする。トレーサは BPF を読み込み終えてから `READY=1` を送るので、
手順の `restart` はそれまで待ち (bcc のコンパイルに数秒かかる)、読み込みに失敗すれば `restart`
自体が失敗する。起動に失敗し続けたら (WSL のカーネルの更新で BPF が読み込めなくなったときなど)
10 分に 5 回で諦めて `failed` にする (`StartLimit*`。既定の 10 秒に 5 回は `RestartSec=10` では
超えないので、付けないと clang のコンパイルを無限に繰り返す)。

setup の最後に、生成された unit と入っている unit がずれていれば知らせる (手順を打ち直す合図)。
unit が同じでも、GC root が無い・動いていないときは知らせる。

### D. 記録は journald に 1 行 1 イベントの JSON で残す

```sh
journalctl -u dotfiles-exe-exec-trace -o cat | exe-exec-trace --pretty
```

保存と削除は journald に任せる (`/var/log/journal` があれば WSL を再起動しても残る)。

### E. `who-is-asking` を WSL のマシンの PATH に置く

`wsl.enable` のマシンに入れる。root は要らないので option は設けない。

### 流れ

```
home-manager switch ──生成──> ~/.local/share/dotfiles/systemd/dotfiles-exe-exec-trace.service
                                (ExecStart=/nix/store/…-exe-exec-trace/bin/exe-exec-trace --json)

~/dotfiles/setup --steps exe-exec-trace   (sudo)
  ├─ 複製    → /etc/systemd/system/dotfiles-exe-exec-trace.service
  ├─ GC root → /nix/var/nix/gcroots/dotfiles-exe-exec-trace
  └─ systemctl daemon-reload / enable / restart (Type=notify なので BPF を読み込み終えるまで待つ)

systemd (root) ── exe-exec-trace --json ──> journald
journalctl -u dotfiles-exe-exec-trace -o cat | exe-exec-trace --pretty
```

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/pkgs/exe-exec-trace/exe_exec_trace.py` | 新規。TKT-54 の試作に、journald の記録を読む `--pretty` を足したもの。bcc はトレースするときだけ読み込む |
| `nix/pkgs/exe-exec-trace/test_exe_exec_trace.py` | 新規。記録の組み立て・整形・`--pretty`・表示の無害化の unittest (21 件) |
| `nix/pkgs/exe-exec-trace/default.nix` | 新規。`writeShellApplication` で包む |
| `nix/pkgs/who-is-asking/who_is_asking.py` | 新規。TKT-54 の試作 (bash に埋め込んでいた Python) を、テストできる関数に分けたもの |
| `nix/pkgs/who-is-asking/test_who_is_asking.py` | 新規。対の取り方と木・PowerShell の出力の読み取りの unittest (24 件)。データは TKT-54 の実機のプロセス表を縮めたもの |
| `nix/pkgs/who-is-asking/default.nix` | 新規。`writeShellApplication` で包む (runtimeInputs は python3) |
| `nix/home/modules/exe-exec-trace.nix` | 新規。unit の生成と PATH への配置 |
| `nix/home/options.nix` | `dotfiles.wsl.exeExecTrace.enable` を足す |
| `nix/home/default.nix` | 上のモジュールを読み込む |
| `nix/hosts/default.nix` / `nix/lib/mk-home.nix` | `pollenjp@wsl` で true にし、説明を足す |
| `nix/flake.nix` | Linux の `packages` に 2 つを、`checks` に 2 つの unittest を足す |
| `nix/scripts/setup.sh` | 手順 `exe-exec-trace` と、最後のずれの知らせを足す |
| `nix/README.md` | 運用手順 (有効にする・入れる・読む・外す) を足す |

## 4. 検討した代替案

| 案 | 採らなかった理由 |
| --- | --- |
| `ExecStart` をホームのプロファイル (`~/.nix-profile/bin`) に向ける | 更新に sudo が要らないが、root がユーザーの書き換えられるパスを実行する。同じユーザーの他のプロセスがトレーサを差し替えられる |
| system-manager (numtide) で `/etc` を宣言的に管理する | 筋は良いが、system 側の設定はまだこの 1 つだけで、flake input と運用手順が増える分に見合わない |
| Ubuntu の `python3-bpfcc` (apt) を使う | この PC には入っているが宣言的でない。他のマシンでは手で入れることになる |
| `bootstrap-*.sh` にする | `--update` で毎回走るが、`--update` は対話無しで sudo も要らない前提になっている |
| user の unit にしてケーパビリティを渡す | user の unit は capability を得られない。python に file capability を付けるのは影響が広すぎる |
| JSONL ファイルに書く | ローテーションを自前で持つことになる |
| npiperelay + ログ付き agent プロキシ | agent への要求ごとに PID (`SO_PEERCRED`) が取れるが、1Password の表示が `npiperelay.exe` になり、ADR 004 の経路を作り直すことになる |
| 名前ではなく、interop の実体 (`/init`) で絞る | 今は `bprm->filename` が `.exe` で終わるものを拾うので、`.exe` でない名前にした Windows の実行ファイルは抜ける (binfmt_misc はファイル名ではなく先頭の `MZ` で interop に回す)。exec の後の `mm->exe_file` が `/init` かで見れば名前によらず拾えるが、他ディストロの `/init` の見分けも要り、今回の対象 (隠れる気の無い呼び出し元) には要らない。隠れようとする相手まで記録したくなったら検討する |
| BPF を build 時にコンパイルする (libbpf の CO-RE) | 実行時に clang と LLVM が要らなくなり閉包が小さくなるが、ローダーを C などで書き直すことになり、試作 (bcc) から離れる。閉包の 1.5 GiB が問題になったら検討する |

## 5. 影響 (Consequences)

### 良くなること

- ダイアログの出ない利用も含め、WSL からの `.exe` の起動が祖先付きで journald に残る
- ダイアログが出たら、その場で `who-is-asking` で要求元を木で見られる

### 注意が必要なこと

- option を true にした WSL のマシンは、閉包が約 1.5 GiB 増える (bcc 158 MiB・clang 813 MiB・
  LLVM 540 MiB)。bcc は実行時に BPF を clang でコンパイルするので、clang と LLVM を丸ごと持つ。
  CI の `nix flake check` も `pollenjp@wsl` を build するので、これを binary cache から取る
- トレーサを更新したら `--steps exe-exec-trace` を打ち直す。打つまでは古い版が動き続ける
  (setup の最後に知らせる)
- root で python と bcc が動く。実行するのは store の固定パスだけにしている
- CI の閉包スキャンは `sandbox` (WSL ではない) だけが対象なので、bcc は照合されない
- 起動のたびに bcc が BPF のプログラムを clang でコンパイルするので、数秒 CPU を使う (実測 3.9 秒)。
  常駐中のメモリは約 160 MB (LLVM を読み込んだまま)
- 他ディストロの起動は、祖先が comm と PID だけになる (その `/proc` は見えない)
- 親が先に終了した要求は、祖先がセッションの `/init` で途切れる (fork 時点の親は追っていない)
- **隠れようとする相手の記録には使えない。** `.exe` でない名前にした Windows の実行ファイル、
  `$WSL_INTEROP` のソケットを直接叩く interop、journald の流量制限を超える大量の起動では
  抜けられる。パスワード無しで `sudo` できるマシンなら、同じユーザーのプロセスは unit ごと
  止められる (store の固定パスにしたのは、ユーザーの書き換えられるパスを root に実行させない
  ためで、記録を止められないようにするためではない)。記録できるのは隠れる気の無い呼び出し元
  (普通のツールやエージェント) まで
- 記録には argv と祖先のコマンドライン (それぞれ 1 KiB まで) が残る。`/var/log/journal` は
  `adm` のグループで読め、`wsl --export` にも入る。表示 (`--pretty` と `who-is-asking`) では
  制御文字を `\xNN` にして、記録される側が偽の行を差し込めないようにしている
- コンテナや sandbox (`unshare --pid`) の中のプロセスも、トレーサの pid namespace から見える
  番号で記録し、祖先を入れ子の外までたどる。他ディストロだけが `distro=other(…)` になる

## 6. 検証 (Verification)

2026-09-30〜10-01 に、この PC (Windows 11 + WSL 2.7.14 の Ubuntu-24.04、カーネル
6.18.33.2-microsoft-standard-WSL2) で確かめた。

### テストと CI 相当の検査

| 検査 | 結果 |
| --- | --- |
| unittest (flake の `checks`、Nix のサンドボックスの python 3.14) | `exe-exec-trace` 21 件・`who-is-asking` 24 件が通る |
| home module (`nix eval` / `nix build`) | `pollenjp@wsl` に unit と 2 つのコマンド、`pollenjp@wsl-no-1password` に `who-is-asking` だけ、`sandbox` にはどちらも入らない。`wsl.enable` が false のまま option だけ true にすると assertion で止まる。unit の `ExecStart` は store の固定パス |
| setup の手順 (`--dry-run`) | `--list` に出る。`--update` では走らない。入れるときの sudo のコマンドが並ぶ。option が無効で unit も無ければ何もしない。root で打つと断る |
| `nix flake check --all-systems --no-build` / `nix flake check` (x86_64-linux の build) | 通る |
| nixfmt / shfmt / shellcheck / `sandbox` の warnings が空 | 通る |

unittest と home module と setup の手順は、実装より先に確かめ方を書き、落ちるのを見てから実装した。

### 実機

1. ローカル flake の `dotfiles` 入力を worktree に差し替えて (`--override-input dotfiles path:<worktree>/nix`)
   home を build し、`activate` した。閉包の差分は bcc・clang・LLVM・python の依存と、今回の
   2 つのコマンドと unit だけだった
2. `setup --steps exe-exec-trace` で unit を入れると、保護設定 (`NoNewPrivileges` / `PrivateTmp` /
   `ProtectHome=read-only` / `ProtectSystem=full`) の下でも bcc が動き、数秒で記録を始めた
3. agent を使わない `ssh.exe` (`-o IdentityAgent=none` で `192.0.2.1` へ) を 3 通り起動すると、
   どれも journald に祖先付きで残った

   | 起動の仕方 | 記録 |
   | --- | --- |
   | git から | `ssh.exe` ← git ← zsh ← claude ← herdr |
   | `cmd.exe /c ssh.exe …` | `cmd.exe` (踏み台かもしれない .exe) ← zsh ← claude。Linux 側に `ssh.exe` は現れない |
   | `wsl.exe -e ssh.exe …` | `wsl.exe` (踏み台かもしれない .exe) ← zsh ← claude の 0.13 秒後に、新しいセッションの `ssh.exe` (祖先は `/init` まで) |

4. もう一度打つと何もしない。option が無効な状態 (`HOME` を空のディレクトリにして再現) で打つと
   `disable --now` して unit と GC root を消す。入れ直せる。GC root からトレーサ本体まで辿れる
5. 生成された unit と入っている unit がずれていると「残りの手作業」に出る (unit が古い /
   option が無効なのに残っている)。揃っていれば出ない

### レビューを受けて足したものの検証

コードレビュー (subagent) の指摘を受けて直し、同じくこの PC で確かめた。

| 直したこと | 確かめたこと |
| --- | --- |
| `Type=notify` と `StartLimit*` | 手順の `restart` がトレーサの `READY=1` まで待って返る。同じ `StartLimit*` の一時的な unit に `/bin/false` を 1 秒おきに起こさせると、5 回起こし直したところで諦めて `failed` になった |
| 入れ子の pid namespace | `sudo unshare --pid --fork ping.exe` が、直す前は `pid=1 distro=other(…)` だったのが、`distro=this` で `/proc` から `unshare ← sudo ← zsh ← claude` までたどれた |
| 動いていないときの知らせ | unit を止めると「入っているが動いていない」と出て、手順で起こし直せた |
| root では断る | `sudo ~/dotfiles/setup --steps exe-exec-trace` が断り、動いている unit には触らない |
| 表示の制御文字・欠けた記録・`--pretty \| head` | unittest (改行で偽の行を差し込めない・ESC が端末に届かない・欠けた記録はそのまま出す)。`head` で閉じても終了時にエラーを出さない |
| root 無しで記録しようとしたとき | bcc を読み込む前に案内を出して終わる |

### 確かめていないこと

- WSL を再起動したときに unit が起動時に上がること (`WantedBy=multi-user.target` で enable 済み。
  WSL を止めると作業中のセッションも落ちるため)
- `wslhost.exe` がセッションを持つ場合の `who-is-asking` の対 (タブの `wsl.exe` が先に終わったとき)
- 他ディストロからの起動が `distro=other(…)` で残ること (他ディストロが止まっていた)
- 1Password の承認ダイアログを伴う要求 (経路は TKT-54 で、ダイアログを出して確かめている)

## 7. 移行・運用手順

```sh
# 有効にする (登録簿の pollenjp@wsl は true。それ以外は local で true にする)
~/dotfiles/setup --update
~/dotfiles/setup --steps exe-exec-trace   # 中で sudo を呼ぶ (sudo を付けない)。更新のたびに打ち直す

# 読む
journalctl -u dotfiles-exe-exec-trace -o cat | exe-exec-trace --pretty

# 外す: option を false にして
~/dotfiles/setup --update
~/dotfiles/setup --steps exe-exec-trace
```
