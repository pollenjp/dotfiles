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

```sh
home-manager switch --flake ~/dotfiles/nix#pollenjp@wsl
```

`#` の後ろは `nix/hosts/default.nix` の登録名。新しいマシンは同ファイルに 1 行足す。

## 日常運用

```sh
# 何が配置されるかを $HOME に触れず確認する
nix build ~/dotfiles/nix#homeConfigurations.'"pollenjp@wsl"'.activationPackage -o /tmp/hm
find /tmp/hm/home-files -mindepth 1 -maxdepth 3

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

複製時に `~/dotfiles/...` への参照を書き換えている（store 管理では解決できないため）。

| 元の記述 | 書き換え後 |
| --- | --- |
| `source ~/dotfiles/vim_common/common.vim` | `source ~/.vim/common.vim` |
| `source-file ~/dotfiles/tmux/home.tmux.conf` | `source-file ~/.tmux.conf` |

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
    ├── verify.sh          検証を一括実行する
    └── preflight-unlink.sh  main.bash が張った symlink を外す
```
