# dotfiles

配置方法は 2 経路ある。**マシン単位でどちらかを選ぶ。同一マシンで両方を走らせないこと。**

| 経路 | リポジトリの置き場所 | 手順 |
| --- | --- | --- |
| Nix home-manager（推奨） | `~/ghq/github.com/pollenjp/dotfiles` | [`nix/README.md`](./nix/README.md) |
| `main.bash setup`（従来） | `~/dotfiles` | 下記 |

> ⚠️ `~/dotfiles` の意味が経路によって違う。従来経路では**リポジトリ本体**だが、
> Nix 経路では**ローカル専用 flake の置き場所**（リポジトリ本体は ghq 配下）になる。
> 従来経路が配置する設定ファイルは `~/dotfiles/...` を直接参照するため、
> この置き場所を変えられない。

Windows (MINGW/MSYS) は Nix が動かないので従来経路を使う。

## Setup（従来経路）

`~/dotfiles` に clone してから実行する。

```sh
./main.bash setup
./main.bash fmt
./main.bash lint
```
