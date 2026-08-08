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

## flake.lock の生成

`flake.lock` は未コミット。**初回に一度だけ**生成してコミットする。

```sh
cd ~/dotfiles/nix
nix flake lock
git add flake.lock && git commit -m 'chore(nix): flake.lock を追加'
```

> このリポジトリを最初に作った環境は GitHub の tarball 取得 (`codeload.github.com`) が
> ネットワークポリシーで遮断されており、`github:` 形式の input を解決できなかったため
> lock を生成できなかった。git プロトコル経由なら到達できるので、その環境で検証する場合は
> 次のように input を差し替える (flake.nix は変更しない):
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

## 検証

```sh
cd ~/dotfiles/nix

# git flake では untracked ファイルが self から見えない。必ず先に git add する
git add .

nix flake check                            # 現在の system 向けに評価 + ビルド
nix flake check --all-systems --no-build   # 全 system を評価のみ (CI 向け)

# 使い捨て $HOME に対する実適用と冪等性確認
mkdir -p /tmp/hm-sandbox
HOME=/tmp/hm-sandbox nix run home-manager -- switch --flake .#sandbox -b bak
HOME=/tmp/hm-sandbox nix run home-manager -- switch --flake .#sandbox -b bak  # 差分なしを確認
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
└── files/                 既存設定の複製 (store 管理される素のファイル)
```
