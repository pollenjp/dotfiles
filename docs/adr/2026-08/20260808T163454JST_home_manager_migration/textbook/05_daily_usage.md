# 05. 日常運用

普段使うコマンドはこれだけ。

## 基本の 3 つ

```sh
# 設定を変えたら適用する
home-manager switch --flake ~/dotfiles/nix#pollenjp@wsl

# 今どの世代にいるか / 過去の世代を見る
home-manager generations

# 依存 (nixpkgs / home-manager) を更新する
nix flake update --flake ~/dotfiles/nix
```

`--flake ...` を毎回打つのが面倒なら alias を作るとよい。

## 設定を変える

1. 対象を編集する
   - 素のファイル (starship / zellij / nvim / tmux) → `nix/files/` を編集
   - 生成しているもの (git など) → `nix/home/modules/*.nix` を編集
2. `home-manager switch` を実行する

**store 管理なので、編集しただけでは反映されない。** ここだけ従来の symlink 運用と違う。

<details><summary>switch を忘れがちな問題への対処</summary>

「編集したのに反映されない」は必ず一度は踏む。

`nix/` に入ったら自動で教えてくれるようにしたい場合は direnv が使えるが、注意点がある。このリポジトリの `.gitignore_global` (= `~/.config/git/ignore`) は **`.envrc` を無視する設定**になっているため、リポジトリの `.gitignore` に `!.envrc` を書かないと Git から見えず、**flake からも見えない**。

</details>

## ツールを増やす

```sh
$EDITOR ~/dotfiles/nix/home/modules/packages.nix
home-manager switch --flake ~/dotfiles/nix#pollenjp@wsl
```

パッケージ名は <https://search.nixos.org/packages> で調べる。

一度だけ試したいなら、入れずに実行できる。

```sh
nix run nixpkgs#hyperfine -- --help
nix shell nixpkgs#hyperfine     # このシェルの間だけ使える
```

## 更新する

```sh
nix flake update --flake ~/dotfiles/nix
home-manager switch --flake ~/dotfiles/nix#pollenjp@wsl
```

`nix flake update` は `flake.lock` を書き換える。**変更をコミットして他のマシンで pull すれば、全マシンのバージョンが揃う。**

特定の input だけ更新することもできる。

```sh
nix flake update nixpkgs --flake ~/dotfiles/nix
```

## 壊れたら戻す

```sh
home-manager generations
/nix/store/<古いハッシュ>-home-manager-generation/activate
```

## ディスクを掃除する

古い世代の store path は残り続けるので、たまに掃除する。

```sh
# 30 日より古い世代を削除
home-manager expire-generations '-30 days'

# どこからも参照されなくなった store path を削除
nix store gc
```

<details><summary>garbage collection (GC) とは</summary>

Nix は「どこかの世代から参照されている store path」を消さない。逆に言えば、世代を消すまでは何も減らない。

だから掃除は 2 段階になる。まず `expire-generations` で古い世代を消し、次に `nix store gc` で参照されなくなった実体を消す。

</details>

## 検証する

設定を大きく変えたときは、実マシンに適用する前に確認する。

```sh
cd ~/dotfiles/nix

# 全 system で評価が通るか (ビルドはしない。速い)
nix flake check --all-systems --no-build

# 配置されるファイルを確認する
nix build '.#homeConfigurations."pollenjp@wsl".activationPackage' -o /tmp/hm
find /tmp/hm/home-files -mindepth 1 -maxdepth 3

# 使い捨て HOME で実際に試す
mkdir -p /tmp/hm-sandbox/.local/state/nix/profiles
HOME=/tmp/hm-sandbox nix run home-manager -- switch --flake .#sandbox -b bak
```

## フォーマット

```sh
cd ~/dotfiles/nix && nix fmt
```

`.nix` ファイルを nixfmt で整形する。シェルスクリプトは従来どおり `./main.bash fmt` (shfmt)。

## よくあるエラー

| エラー | 原因と対処 |
| --- | --- |
| `Existing file ... would be clobbered` | 管理外の実ファイルが既にある。外すか `-b bak` を付ける |
| `Existing file ... .bak already exists` | 前回の退避が残っている。古い `.bak` を消す |
| `path does not exist` (新規 `.nix` を足した直後) | **git flake は untracked ファイルを見ない。`git add` する** |
| 入れたはずのツールが古いまま | mise のリストに残っている。`~/.config/mise/config.toml` から消す |
| `$USER` と `home.username` の不一致で中断 | `hosts/default.nix` の username を実際のログイン名に合わせる |

<details><summary>なぜ git add しないと見えないのか</summary>

flake が Git リポジトリの中にある場合、Nix は **Git が追跡しているファイルだけ**を対象にする。これは「コミットすれば他のマシンで再現できる」を保証するための仕様。

新しく `.nix` ファイルを作ったときは、コミット前でも `git add` だけはしておく必要がある。

</details>

---

前: [04_migration.md](./04_migration.md) / 目次: [README.md](./README.md)
