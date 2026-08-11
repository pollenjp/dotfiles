# ADR: WSL の ssh ラッパーを Nix 管理に載せる

| 項目 | 内容 |
| --- | --- |
| ステータス | 提案 (Proposed) — レビュー中 |
| 日付 | 2026-08-11 (JST) |
| 決定者 | pollenjp |
| 前提 ADR | [003_nix_ssh_config](../003_nix_ssh_config_20260810T210714JST/README.md)（`bin/` のうち Windows 用 2 本の扱いを決めた ADR。本 ADR はその決定を変えず、触れていなかった WSL 用 2 本を扱う） |
| 運用手順 | [`nix/README.md`](../../../nix/README.md)（日常運用はこちら） |

---

## 1. 背景 (Context)

`nix/` は移行の過程でリポジトリ直下の各ディレクトリを順に取り込んできたが、
**`bin/` だけがどの Stage でも扱われていなかった**。

`bin/` には 4 本のラッパーがある。いずれも 1Password の ssh クライアントを使うための
もので、レガシー経路では `main.bash:106-135` が `uname` と `ssh.exe` の有無を実行時に
見て `~/.local/bin/` へ symlink していた。

| スクリプト | 用途 |
| --- | --- |
| `bin/ssh-wsl.sh` / `bin/ssh-add-wsl.sh` | WSL から Windows の `ssh.exe` / `ssh-add.exe` を呼ぶ |
| `bin/ssh-*-git-for-win.sh` | Git for Windows 用 |

[ADR 003](../003_nix_ssh_config_20260810T210714JST/README.md) は Windows 用の 2 本に
ついて「Windows 経路が使うので残している」と決めているが、**WSL 用の 2 本については
何も決めていなかった**。WSL は Nix 経路の主対象なので、ここが空白のまま残っていた。

### 空白のままだと何が起きるか

Nix 経路では `~/.local/bin/` に何も置かれない一方、`home/modules/shell-common.nix` は
`home.sessionPath` で `$HOME/.local/bin` を PATH の前に入れている。つまり
**「置き場所は PATH に入るが、中身を置く主体がいない」**状態だった。

これは 2 つの形で表に出る。

1. **1Password の agent が見えなくなる。** この dotfiles は npiperelay や socat で
   `SSH_AUTH_SOCK` をホスト側へ橋渡ししていない (`shell/299_ssh_agent.sh` は Linux の
   ssh-agent を起こすだけ)。ラッパーが無いと WSL 側の Linux ssh が使われ、
   ホスト側 Windows の 1Password が持つ鍵に到達できない。
2. **git の署名が壊れる。** `home/modules/git.nix` の `gpg.ssh.defaultKeyCommand` は
   `ssh-add -L` の出力から `Signing` を含む鍵を選ぶ。この `ssh-add` が Linux 側だと
   鍵が並ばないので、署名鍵が見つからないまま `commit.gpgSign = true` だけが残る
   ——README が「1Password の無いマシンで署名設定だけ残すと `git commit` が失敗する」
   として避けていた状態そのものになる。`op-ssh-sign` のパス指定
   (`gpg.ssh.program`) だけでは足りない、というのがここでの発見。

### 移行時は無言で壊れる

さらに厄介なのは、`main.bash` 経路から移行するマシンの挙動。旧経路が張った
`~/.local/bin/ssh` → `~/dotfiles/bin/ssh-wsl.sh` の symlink は、README の手順で本体を
ghq 配下へ移した時点で参照先を失う。

**bash は dangling な symlink を読み飛ばして PATH 探索を続ける**ので、
`command not found` にもならずディストリの `ssh` にすり替わる (実測は
「6. 検証」)。エラーも警告も出ないため、`git commit` が署名で失敗して初めて気づく。

移行の途中に「ラッパーが効いていないが誰も何も言わない」区間ができる、というのが
この ADR を起こした直接の動機。

## 2. 決定 (Decision)

**WSL 用の 2 本を `nix/files/bin/` へ複製し、`wsl.onePassword.enable = true` の
マシンにだけ `~/.local/bin/` へ配置する。** 併せて旧経路の symlink を
`preflight-unlink.sh` の対象に加える。

判定を実行時 (`uname` + `ssh.exe` の有無) から**登録簿の指定**へ移すのは、
`git.nix` の署名設定と同じ考え方。同じ 1Password 連携なので同じ軸で切り替わる方が
読み手にとって一貫する。

Windows 用の 2 本は ADR 003 の決定どおりリポジトリ直下に残す。

## 3. 変更点の詳細

| ファイル | 変更 |
| --- | --- |
| `nix/files/bin/ssh-wsl.sh` | 新規。`bin/` から verbatim 複製 (`~/dotfiles` 参照が無いので書き換え不要) |
| `nix/files/bin/ssh-add-wsl.sh` | 同上 |
| `nix/home/modules/ssh.nix` | `home.file` で `~/.local/bin/{ssh,ssh-add}` を配置。`lib.mkIf useOnePassword` で分岐 |
| `nix/scripts/preflight-unlink.sh` | `~/.local/bin/{ssh,ssh-add}` を targets に追加 |
| `nix/README.md` | 「WSL では ssh 自体を Windows 側に差し替える」節を追加。管理対象ファイルの表とディレクトリツリーを更新 |
| `.github/workflows/nix.yml` | lint の対象に `nix/files/bin/*.sh` を追加 |

`useOnePassword = wsl.enable && wsl.onePassword.enable` は `git.nix` と同じ式にした。
入れ子の親も見るのは、`wsl.enable = false` のまま子だけ true になった登録を有効と
誤認しないため (その組み合わせ自体は `git.nix` の assertion が評価時に止める)。

`executable = true` を明示しているのは、複製元の mode 100755 が何かの拍子に落ちても
壊れないようにするため。exec できない `ssh` が PATH の先頭に居ると ssh が丸ごと
使えなくなる。

### 置き場所を `ssh.nix` にした理由

`files.nix` は「Nix 側で書き換えず、そのまま置くだけ」の**静的な設定ファイル**を
集めた場所で、無条件配置が前提。今回置くものは実行ファイルでマシン条件も付くので
性質が違う。

ssh の設定 (`~/.ssh/config`) と ssh の実体差し替えは、ssh の挙動を追う人が同じ場所を
見たいはずなので `ssh.nix` に同居させた。1Password 連携をツール別 (git / ssh) に
分ける既存の軸にも合う。

## 4. 検討した代替案

### 案 A: ラッパーを捨てる (Linux の ssh を使う)

`preflight-unlink.sh` で旧 symlink を外すだけにして、WSL でも Linux の ssh を使うと
決める案。変更は最小になる。

**採らなかった理由**: 1Password の鍵に到達する別の手段 (npiperelay / socat による
`SSH_AUTH_SOCK` の橋渡し) をこの dotfiles は持っていない。捨てるなら橋渡しを新しく
作る必要があり、しかも `git.nix` の `defaultKeyCommand` も書き換えることになる。
「移行で挙動を変えない」方針から外れる。

### 案 B: 現状維持 + ドキュメントだけ書く

「WSL 用ラッパーは Nix 経路では引き継がない」と README / ADR に明記して終わる案。

**採らなかった理由**: 署名が壊れる経路が残る。しかも壊れ方が
「dangling symlink を bash が読み飛ばす」という無言のもので、ドキュメントを読んでいても
現物を見ないと気づけない。ドキュメントで塞ぐ種類の穴ではない。

### 案 C: `home.activation` で symlink を張る

`bootstrap-*.sh` のように activation script で作業ツリーへ symlink する案。

**採らなかった理由**: ラッパーは試行錯誤するものではなく内容が固定なので、
`claude-skills` のような「編集をそのまま反映したい」動機が無い。store に置けば
read-only になり、誤編集も防げる。ネットワークアクセスも要らないので
`home.activation` を使う理由 (hermetic を崩さざるを得ない事情) がそもそも無い。

## 5. 影響 (Consequences)

### 良くなること

- WSL + 1Password のマシンで、ssh と git の署名が Nix 経路だけで完結する
- 判定が実行時の環境依存 (`uname` / `ssh.exe` の有無) から登録簿の宣言に移る
- `~/.local/bin/ssh` が store の read-only になるので、誤編集で壊れない
- 移行時の無言の劣化 (dangling symlink) が `preflight-unlink.sh` で塞がる

### 注意が必要なこと

- **`~/.local/bin/ssh` はそのマシンの `ssh` を丸ごと差し替える。** git を含め、
  PATH から `ssh` を引く全てがラッパー経由になる (レガシーと同じ挙動)。
  Linux 側を使いたいときは `USE_LINUX_SSH=1`。
- **`wsl.onePassword.enable = false` のマシンには置かれない。** WSL でも 1Password が
  無ければ Linux の ssh を使う。署名設定も出ないので整合している。
- ラッパーは `ssh.exe` を PATH から引く。WSL の interop が切れている環境
  (`/etc/wsl.conf` の `appendWindowsPath = false` など) では機能しない。
- 複製が 2 箇所 (`bin/` と `nix/files/bin/`) になる。Windows 経路を畳むまでは
  両方残る (ADR 003 と同じ状態)。

## 6. 検証 (Verification)

環境の制約で `codeload.github.com` が 403 になるため、README 記載の
`--override-input` で実行している。

### dangling symlink を bash がどう扱うか

背景の主張 (エラーにならず PATH 探索が続く) を実測した。

```console
$ ln -sf /nonexistent/bin/ls-wrapper.sh fakebin/ls
$ PATH="$PWD/fakebin:$PATH" bash -c 'command -v ls; ls -d /'
/usr/bin/ls
/
```

dangling を読み飛ばして実体に到達している (bash 5.2.21)。**失敗しないことが問題**で、
旧 symlink が残ったまま本体を移動しても何も起きないまま挙動だけ変わる。

### 配置がマシン条件で切り替わるか

```console
$ nix eval './nix#homeConfigurations."<host>".config.home.file' --apply '<local/bin だけ抽出>'
pollenjp@wsl                 .local/bin/ssh, .local/bin/ssh-add
pollenjp@wsl-no-1password    (なし)
pollenjp@x86_64-linux        (なし)
pollenjp@aarch64-darwin      (なし)
sandbox                      (なし)
```

### 実体とパーミッション

```console
$ nix build './nix#homeConfigurations."pollenjp@wsl".config.home-files' -o /tmp/hm-files
$ ls -lL /tmp/hm-files/.local/bin/
-r-xr-xr-x 1 root root 221 Jan  1  1970 ssh
-r-xr-xr-x 1 root root 229 Jan  1  1970 ssh-add
```

実行ビットが立ち、store なので書き込み不可になっている。中身は複製元と一致。

### 旧 symlink を外し忘れたらどうなるか

`preflight-unlink.sh` を足す根拠を確かめるため、home-manager の
`modules/files/check-link-targets.sh` を読み、sandbox ホストの管理下パスで実測した。
分岐が「symlink かどうか」と「中身が一致するか」で変わる。

| 邪魔をする側 | 実測結果 |
| --- | --- |
| 生きた symlink / 中身が同じ | `... will be skipped since they are the same` の警告のみ。**リンクは store へ置き換わり switch は成功** |
| 生きた symlink / 中身が違う | `would be clobbered` で exit 1。`HOME_MANAGER_BACKUP_EXT` を付けても**退避されず同じく失敗** (backup の分岐に `! -L` の条件がある) |
| dangling symlink | 警告も出ず置き換わる (`-L && -e` も `-e` も偽なので照合をすり抜ける) |

つまり**「外し忘れると必ず止まる」わけではない**。複製が verbatim である以上、
通常は 1 行目のケースになる。`preflight-unlink.sh` に足す価値は次の 2 点。

- 警告を出さない
- どちらかを編集していた場合の手詰まり (2 行目。`-b` が効かない) を先に潰す

なお 3 行目は「switch すれば直る」ことを意味するが、直る前の区間
(本体を移動してから switch するまで) は無言でラッパーが外れている。

### flake check / lint

```console
$ nix flake check --all-systems --no-build ./nix
✅ checks.x86_64-linux.home-pollenjp@wsl  (他 5 件も ✅)

$ nix develop ./nix --command bash -c 'find nix -name "*.nix" -print0 | xargs -0 nixfmt --check'
OK
$ shfmt -d nix/scripts/*.sh nix/files/bin/*.sh && shellcheck nix/scripts/*.sh nix/files/bin/*.sh
OK
```

### 検証していないこと

**実機の WSL での動作は確認していない** (この環境に WSL も Windows の `ssh.exe` も
無いため)。確認済みなのは「Nix が何をどこへ置くか」まで。実機では移行後に次を見る。

```sh
command -v ssh          # ~/.local/bin/ssh を指すこと
ssh-add -L | grep Signing   # 1Password の署名鍵が並ぶこと
git commit --allow-empty -m test && git log --show-signature -1
```

## 7. 移行・運用手順

既存の WSL マシンでは、旧経路の symlink を外してから switch する。

```sh
~/dotfiles/setup --steps preflight-unlink
~/dotfiles/setup --update
```

「新しいマシン適用」には `preflight-unlink` が入っているので、プリセットを使うなら
個別指定は要らない (「既存マシン更新」には入っていない。移行時に 1 回だけ走らせる
手順という位置づけのため)。

外し忘れても通常は通る (「6. 検証」の 1 行目)。次が出たときだけ手で外して再実行する。

```
Existing file '/home/pollenjp/.local/bin/ssh' would be clobbered
```

```sh
unlink ~/.local/bin/ssh ~/.local/bin/ssh-add
```

適用後は実機で次を確認する。

```sh
command -v ssh                # ~/.local/bin/ssh を指すこと
ssh-add -L | grep Signing     # 1Password の署名鍵が並ぶこと
git commit --allow-empty -m test && git log --show-signature -1
```
