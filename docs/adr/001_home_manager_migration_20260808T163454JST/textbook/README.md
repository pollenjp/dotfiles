# textbook: Nix home-manager による dotfiles 管理

このリポジトリの dotfiles 管理を Nix home-manager へ移行するにあたり、**Nix をまったく触ったことがない人**が一から順に理解できるようにまとめたドキュメント。

親 ADR: [../README.md](../README.md)

## 読む順番

| 章 | 内容 | 想定読者 |
| --- | --- | --- |
| [00_introduction.md](./00_introduction.md) | なぜ移行するのか。今の何が困っているのか | 全員 |
| [01_nix_basics.md](./01_nix_basics.md) | Nix そのものの基礎。store / derivation / flake | Nix 未経験者 |
| [02_home_manager.md](./02_home_manager.md) | home-manager とは何か。世代とロールバック | Nix 未経験者 |
| [03_this_repo.md](./03_this_repo.md) | このリポジトリの `nix/` の読み方・触り方 | 全員 |
| [04_migration.md](./04_migration.md) | 既存マシンを切り替える手順と落とし穴 | 移行する人 |
| [05_daily_usage.md](./05_daily_usage.md) | 日常運用のコマンド集 | 全員 |

急いでいる場合は **00 → 03 → 05** だけでも実用になる。「なぜそう動くのか」を知りたくなったら 01 と 02 に戻ってくればよい。

## 表記について

専門用語が出てきた箇所には、その直下に折りたたみで解説を置いている。既に知っている用語は開かずに読み飛ばしてよい。

<details><summary>こういう形式で用語解説が入る</summary>

クリックすると開く。用語の意味と、「なぜそれがここで出てくるのか」を書いてある。

</details>

## 図の再生成

```sh
cd plantuml
mise run plantuml:generate
```

`plantuml/*.puml` を編集したら実行する。`plantuml/out/*.svg` が更新される。

> PlantUML では `~` がエスケープ文字として消費されるため、図中では `~/dotfiles` ではなく
> `$HOME/dotfiles` と表記している。同様に `=>` は見出し記法と解釈されるので `→` を使う。
