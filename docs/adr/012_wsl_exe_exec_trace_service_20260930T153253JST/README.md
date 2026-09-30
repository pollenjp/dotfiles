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

### B. option が true のとき、home-manager が unit を生成する

`dotfiles.wsl.exeExecTrace.enable` (既定 false、`wsl.enable` のときだけ意味を持つ) を足す。
true のとき、home-manager は次の 2 つを置く。

- unit ファイル `~/.local/share/dotfiles/systemd/dotfiles-exe-exec-trace.service`。
  `ExecStart` は `/nix/store/…-exe-exec-trace/bin/exe-exec-trace --json` の固定パスにする
- ユーザーの PATH の `exe-exec-trace`。記録を読むときの `--pretty` に使う (root で記録するのは unit の側)

登録簿の `pollenjp@wsl` で true にする。

### C. /etc へ入れるのは setup の手順 `exe-exec-trace` (sudo が要る)

`~/dotfiles/setup --steps exe-exec-trace` が次をする。`chsh` と同じく、既定の手順
(新規マシン・既存マシンの更新) には入れない。

- option が true: 生成された unit を `/etc/systemd/system/` へ複製し、unit の store パスへ
  GC root (`/nix/var/nix/gcroots/dotfiles-exe-exec-trace`) を張って、`daemon-reload` →
  `enable` → `restart` する。中身が同じなら、有効になっていて動いていることだけ確かめる
  (止まっていれば起こす)
- option が false: unit が入っていれば `disable --now` して、unit と GC root を消す

setup の最後に、生成された unit と入っている unit がずれていれば知らせる (手順を打ち直す合図)。

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
  └─ systemctl daemon-reload / enable / restart

systemd (root) ── exe-exec-trace --json ──> journald
journalctl -u dotfiles-exe-exec-trace -o cat | exe-exec-trace --pretty
```

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/pkgs/exe-exec-trace/exe-exec-trace.py` | 新規。TKT-54 の試作に、journald の記録を読む `--pretty` を足したもの |
| `nix/pkgs/exe-exec-trace/default.nix` | 新規。`writeShellApplication` で包む |
| `nix/pkgs/who-is-asking/who-is-asking.sh` | 新規。TKT-54 の試作 |
| `nix/pkgs/who-is-asking/default.nix` | 新規。`writeShellApplication` で包む (runtimeInputs は python3) |
| `nix/home/modules/exe-exec-trace.nix` | 新規。unit の生成と PATH への配置 |
| `nix/home/options.nix` | `dotfiles.wsl.exeExecTrace.enable` を足す |
| `nix/home/default.nix` | 上のモジュールを読み込む |
| `nix/hosts/default.nix` / `nix/lib/mk-home.nix` | `pollenjp@wsl` で true にし、説明を足す |
| `nix/flake.nix` | Linux の `packages` に 2 つを足す |
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

## 5. 影響 (Consequences)

### 良くなること

- ダイアログの出ない利用も含め、WSL からの `.exe` の起動が祖先付きで journald に残る
- ダイアログが出たら、その場で `who-is-asking` で要求元を木で見られる

### 注意が必要なこと

- option を true にした WSL のマシンは、閉包が 170 MiB ほど増える (bcc と python)
- トレーサを更新したら `--steps exe-exec-trace` を打ち直す。打つまでは古い版が動き続ける
  (setup の最後に知らせる)
- root で python と bcc が動く。実行するのは store の固定パスだけにしている
- CI の閉包スキャンは `sandbox` (WSL ではない) だけが対象なので、bcc は照合されない
- 起動のたびに bcc が BPF のプログラムを clang でコンパイルするので、数秒 CPU を使う
- 他ディストロの起動は、祖先が comm と PID だけになる (その `/proc` は見えない)
- 親が先に終了した要求は、祖先がセッションの `/init` で途切れる (fork 時点の親は追っていない)

## 6. 検証 (Verification)

(実装後に書く。予定は次のとおり)

- `nix flake check` (全 system の評価と、x86_64-linux の build)・nixfmt・shfmt・shellcheck
- worktree の版をこの PC に当て、`--steps exe-exec-trace` で unit を入れて、agent を使わない
  `ssh.exe` の起動が journald に祖先付きで残ることを見る
- `--pretty` の表示、再度打ったときに何もしないこと、option を false にしたときに外れること

## 7. 移行・運用手順

```sh
# 有効にする (登録簿の pollenjp@wsl は true。それ以外は local で true にする)
~/dotfiles/setup --update
~/dotfiles/setup --steps exe-exec-trace   # sudo が要る。更新のたびに打ち直す

# 読む
journalctl -u dotfiles-exe-exec-trace -o cat | exe-exec-trace --pretty

# 外す: option を false にして
~/dotfiles/setup --update
~/dotfiles/setup --steps exe-exec-trace
```
