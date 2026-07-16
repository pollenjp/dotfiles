# dotfiles

[chezmoi](https://www.chezmoi.io/) で管理する dotfiles。

## セットアップ

chezmoi を導入し、このリポジトリを取り込んで適用する。

```sh
# chezmoi が未インストールなら (いずれか)
mise use -g chezmoi
# または
sh -c "$(curl -fsLS get.chezmoi.io)"

# clone して適用まで一気に行う
chezmoi init --apply pollenjp
```

`chezmoi init --apply pollenjp` は `https://github.com/pollenjp/dotfiles.git`
を `~/.local/share/chezmoi` に clone し、`chezmoi apply` まで実行する。

適用前に差分を確認したい場合は分けて実行する。

```sh
chezmoi init pollenjp   # clone のみ
chezmoi diff            # 適用される差分を確認
chezmoi apply -v        # 適用
```

> [!NOTE]
> `~/.ssh` は chezmoi が管理する。既存の `~/.ssh/config` は置き換わるため、
> 初回は必ず `chezmoi diff` で差分を確認すること。SSH 鍵が未設定で
> `dotfiles-ssh` の clone に失敗する場合は `chezmoi apply --exclude=externals`
> で外部リソースを飛ばして適用できる。

## 日常運用

```sh
chezmoi edit ~/.zshrc   # ソースを編集
chezmoi apply -v        # 反映
chezmoi diff            # 差分確認
chezmoi managed         # 管理対象の一覧
chezmoi cd              # ソースディレクトリへ移動 (git 操作はここで行う)
```

外部リソース (bash-completion / dotfiles-ssh) の更新:

```sh
chezmoi apply --refresh-externals
```

## リポジトリ構成

- `.chezmoiroot` … ソースルートを `home/` に指定する
- `home/` … chezmoi のソースディレクトリ (この配下が `~` に展開される)
  - `dot_bashrc` / `dot_zshrc` / `dot_vimrc` / `dot_screenrc` / `dot_tmux.conf`
  - `dot_gitconfig.tmpl` … OS 別に 1Password op-ssh-sign のパスを自動選択
  - `dot_gitconfig.pollenjp-sub.github.com` … sub アカウント用 (includeIf で読込)
  - `dot_config/` … `~/.config/` 配下
    - `shell/` (bash/zsh 共通) · `bash/` · `zsh/` · `fish/`(分割設定は `fragments/`)
    - `nvim/` · `starship.toml` · `zellij/` · `pypoetry/` · `tmux/` · `vim_common/`
    - `git/ignore` … グローバル gitignore
    - `mise/create_config.toml` … 初回のみ配置 (以後はマシンごとに自由に変更可)
  - `create_dot_common_shellrc.sh` … マシンローカル設定 (初回のみ生成し以後上書きしない)
  - `private_dot_ssh/` … `~/.ssh/` (`config` と `config.d/`)
  - `dot_local/bin/` … WSL / Windows 用 ssh ラッパ (該当 OS でのみ配置)
  - `.chezmoiexternal.toml` … bash-completion / dotfiles-ssh を取得
  - `.chezmoiignore` … OS 条件による配置除外
- `main.bash` … リポジトリ内シェルスクリプトの lint / fmt 専用
- `p10k/` · `dev-tools/` · `script/` · `_*_for_*` … 補助・参考ファイル (chezmoi 管理外)

## メンテナンス (lint / fmt)

`*.sh` / `*.bash` に対して [shfmt](https://github.com/mvdan/sh) を実行する。

```sh
./main.bash lint
./main.bash fmt
```
