# nix (home-manager)

dotfiles を Nix home-manager で宣言的に管理するためのディレクトリ。

既存の `main.bash setup` 経路とは**独立**しており、設定ファイルは `nix/files/` に複製されている。
どちらの経路を使うかはマシン単位で選ぶ。同一マシンで両方を走らせないこと。

## 対象範囲

| 対象 | 管理者 |
| --- | --- |
| dotfile 配置 | Nix home-manager |
| グローバルな CLI ツール | Nix home-manager |
| 言語ランタイム (node / go) | mise (プロジェクト毎の切替が必要なため) |
| プロジェクト毎のツール固定 | mise (`mise.toml`) |

対象 OS は **Linux / macOS / WSL**。Windows (MINGW/MSYS) は Nix が動かないため `main.bash setup` を使う。

対象シェルは **bash / fish**。zsh は Nix 管理の対象外。

## Nix のインストール

```sh
# 推奨: Determinate Systems 版 (flakes が最初から有効)
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# 公式版を使う場合は experimental-features を自分で有効化する
sh <(curl -L https://nixos.org/nix/install) --daemon
mkdir -p ~/.config/nix
printf 'experimental-features = nix-command flakes\n' >> ~/.config/nix/nix.conf
```

systemd の無いコンテナでは `--daemon` が失敗するので `--no-daemon` を使う。
root で single-user install する場合は `/etc/nix/nix.conf` に `build-users-group =` (空) が必要。

## 依存の更新

```sh
nix flake update --flake ~/dotfiles/nix
```

> **GitHub の tarball 取得が遮断された環境について**
>
> `github:` 形式の input は `codeload.github.com` からソースを取得する。
> ネットワークポリシーでこれが遮断されている環境 (git プロトコルのみ到達可能) では
> `flake.lock` の解決はできてもソース取得で 403 になる。
> その場合は `flake.nix` を変更せず input を差し替えて評価する:
>
> ```sh
> nix flake check \
>   --override-input nixpkgs "tarball+https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.xz" \
>   --override-input home-manager "git+https://github.com/nix-community/home-manager?shallow=1"
> ```

## 適用

### 新規マシンの手順

上から順に実行する。**2 と 5 は忘れやすいので注意。**

| # | やること | 備考 |
| --- | --- | --- |
| 0 | `hosts/default.nix` にマシンを 1 行追加 | WSL なら `windowsUserName` も |
| 1 | Nix を入れる（前節） | |
| 2 | `./nix/scripts/preflight-unlink.sh` | `main.bash setup` 済みのマシンのみ |
| 3 | `nix run ~/dotfiles/nix#home-manager -- switch --flake ~/dotfiles/nix#<host>` | 初回はこの形 |
| 4 | `./nix/scripts/bootstrap-mise.sh` | mise のグローバル設定と言語ランタイム |
| 5 | `~/.config/mise/config.toml` を手で整理 | 既存マシンのみ（後述） |
| 6 | `chsh` でログインシェルを変更 | 必要なら |

#### 1. 初回のブートストラップ (手順 3)

**`home-manager` コマンドはまだ存在しない。** `programs.home-manager.enable` が CLI を
profile へ入れるのは *初回の activate が成功した後* なので、1 回目は flake から直接実行する。

```sh
nix run ~/dotfiles/nix#home-manager -- switch --flake ~/dotfiles/nix#pollenjp@wsl
```

> ⚠️ `nix run home-manager -- ...` (レジストリ経由) は使わないこと。
> nixpkgs 同梱の別バージョンが実行され、`flake.lock` で固定した home-manager
> モジュールとバージョンがずれる。上の `~/dotfiles/nix#home-manager` なら
> lock と同じバージョンが使われる。

`#` の後ろは `nix/hosts/default.nix` の登録名。

#### 2. mise の初期化 (手順 4)

```sh
./nix/scripts/bootstrap-mise.sh
```

`~/.config/mise/config.toml` は **Nix 管理下に置いていない**（mise が実行時に書き換える
ファイルなので store に置けない）。そのため `home-manager switch` だけでは作られず、
**新規マシンでは go / node が入らないまま**になる。このスクリプトで初期化する。

冪等なので何度実行してもよい。詳細は後述の「mise との役割分担」を参照。

#### 3. ログインシェルの変更 (手順 6)

`programs.fish.enable` は fish を**インストールするだけ**で、ログインシェルには設定しない
（`/etc/passwd` の変更は home-manager の管轄外）。必要なら手で変更する。

```sh
command -v fish | sudo tee -a /etc/shells
chsh -s "$(command -v fish)"
```

### 2 回目以降

初回の activate が終われば `~/.nix-profile/bin/home-manager` が入るので、
以後は短く書ける。

```sh
home-manager switch --flake ~/dotfiles/nix#pollenjp@wsl
```

**`command not found` になる場合**は `~/.nix-profile/bin` が PATH に無い。
Nix インストーラが用意する profile スクリプトを読み込む (ログインし直すか、以下を実行):

```sh
. ~/.nix-profile/etc/profile.d/nix.sh    # single-user install
. /etc/profile.d/nix.sh                  # multi-user install
```

シェル設定を home-manager が持つ Stage 5 以降は、この PATH 設定も宣言的に入る。

## 日常運用

```sh
# 何が配置されるかを $HOME に触れず確認する
nix build ~/dotfiles/nix#homeConfigurations.'"pollenjp@wsl"'.activationPackage -o /tmp/hm
find -L /tmp/hm/home-files -mindepth 1 -maxdepth 3   # home-files は symlink なので -L 必須

# 適用 (既存ファイルは .bak へ退避)
home-manager switch --flake ~/dotfiles/nix#pollenjp@wsl -b bak

# 世代一覧とロールバック
home-manager generations
/nix/store/<older>-home-manager-generation/activate

# 依存の更新
nix flake update --flake ~/dotfiles/nix
```

> ⚠️ `-b bak` は `<file>.bak` が既に存在すると失敗する。リトライ時は古い `.bak` を先に消すこと。

## 管理対象のファイル

| 配置先 | 実体 |
| --- | --- |
| `~/.config/starship.toml` | `nix/files/starship.toml` |
| `~/.config/zellij/config.kdl` | `nix/files/zellij/config.kdl` |
| `~/.config/nvim/init.vim` | `nix/files/nvim/init.vim` |
| `~/.config/tmux/interactive_shell.tmux.conf` | `nix/files/tmux/interactive_shell.tmux.conf` |
| `~/.tmux.conf` | `nix/files/tmux/home.tmux.conf` |
| `~/.screenrc` | `nix/files/screenrc` |
| `~/.vimrc` | `nix/files/vim/vimrc` |
| `~/.vim/{common,clipboard}.vim` | `nix/files/vim/` |
| `~/.config/git/config` | `nix/home/modules/git.nix` (生成) |
| `~/.config/git/ignore` | 同上 (`programs.git.ignores`) |

複製時に `~/dotfiles/...` への参照を書き換えている（store 管理では解決できないため）。

| 元の記述 | 書き換え後 |
| --- | --- |
| `source ~/dotfiles/vim_common/common.vim` | `source ~/.vim/common.vim` |
| `source-file ~/dotfiles/tmux/home.tmux.conf` | `source-file ~/.tmux.conf` |

## git について

`programs.git` で `~/.config/git/config` を **生成** している（素のファイル配置ではない）。
目的は 1Password `op-ssh-sign` のパスで、従来は WSL 用と Windows 用がコメントアウトで
並んでおり手で切り替える運用だった。これを `dotfiles.isWSL` による自動分岐に置き換えている。

> ⚠️ **`~/.gitconfig` の symlink は必ず外すこと。**
> git は `~/.config/git/config` を読んだ **後に** `~/.gitconfig` を読むため、
> `main.bash` が張った symlink が残っていると home-manager の設定を黙って上書きする。
> `preflight-unlink.sh` が対象に含めている。

**`git config --global` は使えなくなる。** 書込先の `~/.config/git/config` が store 上の
read-only ファイルになるため。マシン固有の設定を足したい場合は `~/.gitconfig` を作れば
よい（git の読み込み順により home-manager の設定を上書きできる）。

## fish

`.fish/*.fish` (17 ファイル / 610 行) は `nix/home/modules/fish.nix` へ**全面移植**した。
レガシー側の数字プレフィックスによる読み込み順制御はやめ、役割別に整理してある。
順序が本質的に効くもの (PATH の前置、mise activate、starship init) だけを
`interactiveShellInit` の並び順で表現している。

内訳: abbr 88 個 / function 24 個 / `interactiveShellInit`。

**fisher は不要になった。** `programs.fish.plugins` が `fishPlugins.autopair` と
`fishPlugins.fzf-fish` を宣言的に入れるため、curl でのインストーラ取得と日次
`fisher update` が消える。`~/.config/fish/fish_plugins` も不要。

平坦化で判明した重複 (レガシーでは読み込み順で後勝ちだった):

| 名前 | 先に定義 | 後に定義 (採用) |
| --- | --- | --- |
| `f` | `201_git` の `git fetch` | `250_alias` の `cd ..` |
| `ls` | `060_mise` の `eza` | `250_alias` の `eza --group-directories-first -F` |

## bash

`.bashrc` / `.bash/*.sh` / `shell/*.sh` を `nix/home/modules/bash.nix` へ全面移植した。
内訳: alias 88 個 / 関数 24 個 / `initExtra`。

**`main.bash:199-219` の bash-completion 取得が不要になった。**
curl + tar で bash-completion 2.11 を落として `~/.bashrc` にローダ行を追記していたが、
`programs.bash.enableCompletion` が置き換える。

`~/.common_shellrc.sh` の source は維持している（マシンローカルの逃げ道）。

### bash で壊れていたものを移植時に修正

| 対象 | 症状 |
| --- | --- |
| `c` | `alias c='noglob c-func'` の `noglob` は zsh 専用。bash では `noglob: command not found` で失敗していた |
| `cdrepo` | ガードが fish 構文の `if not command -v ghq` で書かれており、bash では `not` が見つからず終了ステータス 127 = 常に偽。一度も発火しない死んだコードだった |
| ssh-agent | `ssh-add` の存在確認が無く、未インストール環境では起動のたびにエラーが出ていた |

### 挙動が変わる点

- **bash でも starship プロンプトになる。** レガシーでは starship を初期化しているのは
  fish だけで、bash は素のプロンプトだった。両シェルで揃えている。
  戻したい場合は `starship.nix` の `enableBashIntegration` を `false` にする。
- `glog` などの alias 連鎖（`glog='glo --graph'`）は完全形に展開した（fish 側と同じ形）。
- `echo-PATH` / `echo-PATH-tr` / `echo-PATH-grep` / `git_get_default_branch` は
  alias から関数に変えた（動作は同じ）。

### 移植しなかったもの

`025_mingw` と `205_go_path` の cygpath 分岐（Windows は対象外）、`.bash/02_asdf.sh`
（asdf は使われていない）、`050_common` の `bindkey -v`（zsh 専用のガード付きで
bash では元々発火していなかった）。

## mise との役割分担

| 対象 | 管理者 |
| --- | --- |
| グローバルな CLI ツール | Nix (`home/modules/packages.nix`) |
| 言語ランタイム (go / node) | mise |
| プロジェクト毎のツール固定 | mise (`mise.toml`) |

Nix が CLI ツールを持つ環境では、レガシー経路の起動時パッケージ注入を止める必要がある。
その合図に `~/.local/state/dotfiles/package-manager` というマーカーファイルを使っている
（内容は `nix`）。配置するのは `nix/home/modules/mise.nix`。

このマーカーがあると次が停止する。**マーカーが無い環境の挙動は従来どおり。**

- `shell/060_mise.sh` / `.fish/060_mise.fish` の `sed -i` によるパッケージ注入と `mise install`
- `shell/252_alias_mise.sh` / `.fish/252_alias_mise.fish` の日次バージョン pin

### `~/.config/mise/config.toml` は Nix 管理下に置かない

mise が実行時に書き換えるファイルなので store には置けない。設定の投入も
mise 自身のコマンドで行う（config.toml は mise のスキーマであり、Nix 側に
スナップショットを持たせると形式変更への追随が必要になるため）。

**新規マシンではマシンごとに一度だけ実行する:**

```sh
./nix/scripts/bootstrap-mise.sh
```

`[settings]`（`install_before` / `lockfile` / `fetch_remote_versions_timeout`）と
言語ランタイム（`go` / `node` / `usage`）を入れる。`mise settings set` は該当キーだけを
触るので冪等で、既存の `[tools]` も壊さない。

> ネットワークアクセスとインストールを伴うため `home.activation` には入れていない。
> `home-manager switch` は hermetic に保つ方針。

> ⚠️ **既存マシンでは、既に書き込まれた 16 エントリが自動では消えない。**
> マシン毎に一度だけ `~/.config/mise/config.toml` を手で編集し、`go` / `node` / `usage`
> だけ残すこと。消さないと mise の shim が PATH 先頭にいるため Nix 側のツールが使われない。

## 検証

```sh
./nix/scripts/verify.sh
```

`nix flake check` → sandbox ビルド → 配置ファイル一覧 → 使い捨て `$HOME` への activate →
冪等性確認 → `~/dotfiles` 参照の残留チェック、までを一括で行う。実際の `$HOME` には触れない。

個別に実行する場合:

```sh
cd ~/dotfiles/nix
git add .                                  # flake は untracked ファイルを見ない

nix flake check                            # 現在の system 向けに評価 + ビルド
nix flake check --all-systems --no-build   # 全 system を評価のみ (CI 向け)

# 配置されるファイルを事前に確認する
nix build '.#homeConfigurations."pollenjp@wsl".activationPackage' -o /tmp/hm
find -L /tmp/hm/home-files -mindepth 1     # ★ home-files は symlink なので -L が必須
```

## ディレクトリ

```
nix/
├── flake.nix              inputs / homeConfigurations / checks / formatter / devShells
├── lib/mk-home.nix        homeConfiguration 組み立てヘルパ
├── hosts/default.nix      マシン登録簿
├── home/
│   ├── default.nix        import 一覧 + stateVersion
│   ├── options.nix        dotfiles.* 独自オプション
│   └── modules/           機能単位のモジュール
├── files/                 既存設定の複製 (store 管理される素のファイル)
└── scripts/
    ├── verify.sh            検証を一括実行する
    ├── preflight-unlink.sh  main.bash が張った symlink を外す (移行時に 1 回)
    └── bootstrap-mise.sh    mise のグローバル設定を初期化する (マシンごとに 1 回)
```
