# 05. 日常運用

普段使うコマンドはこれだけ。

## 基本の 3 つ

```sh
# 設定を変えたら適用する
home-manager switch --flake ~/dotfiles#pollenjp@wsl

# 今どの世代にいるか / 過去の世代を見る
home-manager generations

# 依存 (nixpkgs / home-manager) を更新する
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/flake-lock-age.sh update
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
$EDITOR ~/ghq/github.com/pollenjp/dotfiles/nix/home/modules/packages.nix
home-manager switch --flake ~/dotfiles#pollenjp@wsl
```

パッケージ名は <https://search.nixos.org/packages> で調べる。

一度だけ試したいなら、入れずに実行できる。

```sh
nix run nixpkgs#hyperfine -- --help
nix shell nixpkgs#hyperfine     # このシェルの間だけ使える
```

## 更新する

「更新」には別の軸が 2 つある。

### 他のマシンでの変更を取り込む (本体の checkout)

```sh
~/dotfiles/setup --self-update --update
```

`~/dotfiles/setup` は本体の `setup.sh` への symlink なので、`git pull` すればスクリプトも設定も一度に新しくなる。未コミットの変更があるときや fast-forward できないときは警告だけ出して何もしない（本体は開発対象でもあるため）。詳細は [`nix/README.md`](../../../../nix/README.md#本体を最新にする---self-update)。

### 依存 (nixpkgs / home-manager) を更新する

```sh
~/ghq/github.com/pollenjp/dotfiles/nix/scripts/flake-lock-age.sh update
home-manager switch --flake ~/dotfiles#pollenjp@wsl
```

`flake.lock` が書き換わる。**変更をコミットして他のマシンで pull すれば、全マシンのバージョンが揃う。**

**素の `nix flake update` は使わない。** 上げ先は追跡先の先端ではなく、**公開から 7 日以上経った revision** に限っている（npm / pnpm の `minimumReleaseAge` に相当する遅延）。素の `nix flake update` は先端を取るのでこの遅延が黙って外れ、CI の `lock-age` ジョブが落ちる。

選ばれる revision を見るだけなら `resolve`、今の `flake.lock` を検査するなら `check`。

```sh
./nix/scripts/flake-lock-age.sh resolve
./nix/scripts/flake-lock-age.sh check
```

日数は `--min-age-days N` で変える（`0` で遅延なし）。`setup` 経由なら `DOTFILES_MIN_RELEASE_AGE_DAYS`。理由と外し方は [`nix/README.md`](../../../../nix/README.md#新しすぎる-revision-を-pin-しない-minimumreleaseage-相当)。

この遅延は**本体の `nix/` だけの話ではない**。リポジトリ内の flake（skill 側のものを含む）は全部同じ扱いで、CI の `lock-age` ジョブがまとめて検査している。

```sh
./nix/scripts/flake-lock-age.sh check \
  ./nix ./nix/files/claude/skills/pjp-drawio ./nix/files/claude/skills/pjp-plantuml
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
cd ~/ghq/github.com/pollenjp/dotfiles/nix

# 全 system で評価が通るか (ビルドはしない。速い)
nix flake check --all-systems --no-build

# 配置されるファイルを確認する
# home-files は store への symlink なので find に -L が必須。
# 付けないと 1 件も出ず「配置物なし」に見えてしまう。
nix build '.#homeConfigurations."pollenjp@wsl".activationPackage' -o /tmp/hm
find -L /tmp/hm/home-files -mindepth 1 -maxdepth 3

# 使い捨て HOME で実際に試す
mkdir -p /tmp/hm-sandbox/.local/state/nix/profiles
HOME=/tmp/hm-sandbox nix run .#home-manager -- switch --flake .#sandbox -b bak
```

## フォーマット

```sh
cd ~/ghq/github.com/pollenjp/dotfiles/nix && nix fmt
```

`.nix` ファイルを nixfmt で整形する。シェルスクリプトは従来どおり `./main.bash fmt` (shfmt)。

## よくあるエラー

| エラー | 原因と対処 |
| --- | --- |
| `home-manager: command not found` | **初回はまだ CLI が無い。** `nix run ~/dotfiles#home-manager -- switch ...` で 1 回目を実行する。2 回目以降も出るなら `~/.nix-profile/bin` が PATH に無い（`. ~/.nix-profile/etc/profile.d/nix.sh`） |
| `Existing file ... would be clobbered` | 管理外の実ファイルが既にある。外すか `-b bak` を付ける（`~/dotfiles/setup` なら `b` / `--backup`） |
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
