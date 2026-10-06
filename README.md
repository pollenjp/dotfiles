# dotfiles

Nix home-manager で配置する。リポジトリ本体は `~/ghq/github.com/pollenjp/dotfiles` に置き、
日々の操作は `~/dotfiles/setup` から行う（`~/dotfiles` はローカル専用 flake の置き場所）。
手順は [`nix/README.md`](./nix/README.md)。

| パス | 中身 |
| --- | --- |
| [`nix/`](./nix/README.md) | home-manager の flake と `setup.sh`。対象は Linux / macOS / WSL |
| [`win/`](./win/README.md) | Windows 側のアプリの設定（Orca など）。WSL の `~/dotfiles/setup --update` が `/mnt/c` へコピーして配る |
| `.ssh` | ssh の接続先（private な submodule）。`setup` が `~/.ssh/config.d/` へ張る |
| [`docs/adr/`](./docs/adr/README.md) | 決めたことと、その理由の記録 |

> 以前は `~/dotfiles` に clone して `./main.bash setup` で symlink を張る旧経路もあった
> （Windows の Git Bash もこれを使っていた）。
> [ADR 013](./docs/adr/013_remove_legacy_tree_20261007T015646JST/README.md) で削除し、
> Git Bash の設定は管理しなくなった。旧経路のファイルは `4a54c96` までの履歴にある。
