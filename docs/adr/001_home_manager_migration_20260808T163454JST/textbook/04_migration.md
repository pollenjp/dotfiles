# 04. 既存マシンを切り替える

ここは実際に手を動かす章。**焦らず、順番どおりに。**

![切り替え手順](./plantuml/out/04_cutover.svg)

## 大原則

> **同じマシンで `main.bash setup` と home-manager の両方を走らせない。**

どちらも同じパスを管理しようとするため。マシン単位でどちらか一方を選ぶ。

そして、**いつでも `./main.bash setup` に戻れる**。これが移行を安全にしている土台なので、Stage 6 まで `main.bash` には手を触れない。

## 手順

### 1. Nix を入れる

```sh
curl -fsSL https://install.determinate.systems/nix | sh -s -- install
```

<details><summary>公式インストーラとの違い</summary>

Determinate Systems 版は flakes が最初から有効で、アンインストーラも付属する。公式版を使う場合は experimental features を自分で有効にする必要がある。

```sh
sh <(curl -L https://nixos.org/nix/install) --daemon
mkdir -p ~/.config/nix
printf 'experimental-features = nix-command flakes\n' >> ~/.config/nix/nix.conf
```

systemd のないコンテナでは `--daemon` が失敗するので `--no-daemon` を使う。root で single-user install する場合は `/etc/nix/nix.conf` に `build-users-group =` (空) の指定も要る。

</details>

### 2. 何が配置されるか先に見る

**ここが最も重要。** `$HOME` に一切触れずに、配置される全ファイルを確認できる。

```sh
cd ~/ghq/github.com/pollenjp/dotfiles/nix
nix build '.#homeConfigurations."pollenjp@wsl".activationPackage' -o /tmp/hm
find /tmp/hm/home-files -mindepth 1 -maxdepth 3
```

ここに出たパスが、これから home-manager が管理するもの。**次のステップで外すべき symlink の一覧そのもの**でもある。

### 3. 既存の symlink を外す

`main.bash setup` を実行済みのマシンでは、先に外す。

```sh
./nix/scripts/preflight-unlink.sh
```

外さないとこうなる。

```
Existing file '/home/user/.tmux.conf' would be clobbered by home-manager
```

<details><summary>なぜ home-manager が作った symlink でなくても駄目なのか</summary>

home-manager は「自分が作ったもの以外は勝手に消さない」設計になっている。これは安全策であって不便ではない。

`main.bash` が作った symlink も「自分が作ったものではない」ので、この検査に引っかかる。

</details>

### 4. dry-run してから適用する

**ここで `home-manager: command not found` になるのが正常。** まだ入っていないので、
1 回目は flake から直接実行する。

```sh
nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#pollenjp@wsl -b bak --dry-run
nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#pollenjp@wsl -b bak
```

<details><summary>なぜ 1 回目だけ書き方が違うのか</summary>

`programs.home-manager.enable = true` は「home-manager CLI を profile に入れる」設定だが、
**それが効くのは初回の activate が成功した後**。つまり鶏と卵になっている。

そこで `flake.nix` は `packages.<system>.home-manager` を公開しており、
`nix run ~/dotfiles#home-manager` で **`flake.lock` に固定されたのと同じバージョン**の
CLI を直接実行できるようにしてある。

`nix run home-manager -- ...`（`#` なし＝レジストリ経由）は使わないこと。nixpkgs 同梱の
別バージョンが動き、lock で固定した home-manager モジュールとバージョンがずれる。

</details>

2 回目以降は `~/.nix-profile/bin/home-manager` が入るので短く書ける。

```sh
home-manager switch --flake ~/dotfiles#pollenjp@wsl -b bak
```

`-b bak` は既存ファイルを `<名前>.bak` に退避してから進める。

> ⚠️ **`.bak` が既に存在すると失敗する。** 途中で失敗して再挑戦するときは、古い `.bak` を先に消すこと。

### 5. 確認する

```sh
readlink ~/.config/starship.toml   # /nix/store/... を指していれば成功
home-manager generations
```

### 6. mise を初期化する

```sh
./nix/scripts/bootstrap-mise.sh
```

**`~/.config/mise/config.toml` は Nix 管理下に置いていない。** mise が実行時に自分で
書き換えるファイルなので、read-only な store には置けないから（[02 章の「store に置けない
ファイル」](./02_home_manager.md)を参照）。

そのため `home-manager switch` だけではこのファイルは作られない。**新規マシンでこれを
飛ばすと go / node が入らないまま**になる。

<details><summary>なぜ Nix で seed せず mise のコマンドで入れるのか</summary>

`config.toml` は mise のスキーマなので、Nix 側にスナップショットを持たせると
mise が形式を変えたときに追随が必要になる。`mise settings set` なら該当キーだけを
触るので冪等で、既存の `[tools]` も壊さない。store からコピーする方式だと
read-only なので `chmod u+w` も要る。

`home.activation` に入れていないのは、`mise use -g` がネットワークアクセスと
インストールを伴うため。`home-manager switch` は hermetic に保ちたい。

</details>

### 7. 既存マシンのみ: mise の設定を削る

**ここを忘れやすい。** 手順 6 までで「これから注入されること」は止まるが、**既に
`~/.config/mise/config.toml` に書き込まれた 16 エントリは残ったまま**。

```sh
$EDITOR ~/.config/mise/config.toml
```

`go` / `node` / `usage` だけ残し、Nix に移したツール (`bat` `eza` `fd-find` `procs` `ripgrep` `fzf` `ghq` `jq` `starship` `watchexec` `zellij` `fish` `cargo-binstall`) を消す。

消さないと **mise の shim が PATH の先頭にいるため、Nix で入れたツールが使われない**。

<details><summary>shim が PATH の先頭に来る理由</summary>

`mise activate` は起動時に mise の shim ディレクトリを PATH の**先頭**へ差し込む。
そのため mise のリストに残っているツールは、Nix の `~/.nix-profile/bin` にある同名の
ものより先に見つかる。「Nix に移したはずなのに古いバージョンが動く」の原因はほぼこれ。

</details>

### 8. ログインシェルを変える (必要なら)

`programs.fish.enable` は fish を**インストールするだけ**で、ログインシェルには設定しない。
`/etc/passwd` の変更は home-manager の管轄外だから。

```sh
command -v fish | sudo tee -a /etc/shells
chsh -s "$(command -v fish)"
```

## 困ったときの戻し方

軽い順に 3 段階。

### ① 前の世代に戻す

```sh
home-manager generations
# 2026-08-08 07:18 : id 1 -> /nix/store/wj3f4...-home-manager-generation
/nix/store/wj3f4...-home-manager-generation/activate
```

### ② home-manager を丸ごと外す

```sh
home-manager uninstall
```

home-manager が管理していた symlink がすべて外れる。

### ③ 元の仕組みに戻す

```sh
cd ~/dotfiles && ./main.bash setup
```

**これは必ず動く。** Stage 6 まで `main.bash` を触らないのはこのため。

## シェルが壊れたときの保険

Stage 5 で `programs.bash` が `~/.bashrc` を所有するようになると、失敗したときにシェルが起動しなくなる可能性がある。

保険は 2 つ。

1. **`-b bak` で退避された `~/.bashrc.bak` を戻す**

   ```sh
   sh -c 'cp ~/.bashrc.bak ~/.bashrc'
   ```

2. **`~/.common_shellrc.sh` は絶対に home-manager 管理下に置かない**

   このファイルはマシンローカルの逃げ道として意図的に管理外にしてある。緊急時にここへ直接 PATH を書けば作業を継続できる。

## Stage 5 の事前作業

`programs.bash` を有効にする前に、`~/.bashrc` から次の 2 つを手で消しておく。

1. `main.bash` が追記したガード付き stanza（`this_file=` と `realpath` を含むブロック）
2. bash-completion のローダ行（`main.bash:213-219` が追記したもの）

消さないと `Existing file ... would be clobbered` で止まる。

---

前: [03_this_repo.md](./03_this_repo.md) / 次: [05_daily_usage.md](./05_daily_usage.md)
