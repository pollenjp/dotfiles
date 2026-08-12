---
name: plantuml
description: PlantUML で図を描く・直す・書き出すときに使う。`.puml` を新規に書くとき、
  シーケンス図・クラス図・ER 図・コンポーネント図・状態遷移図などを PlantUML で作るよう
  頼まれたとき、`plantuml/` ディレクトリを用意するとき、図を SVG / PNG へ出力するときに読む。
  Nix flake での実行環境（PlantUML 本体・java・graphviz・日本語フォント）、ファイル構成と
  出力先、白背景などの規約を含む
---

# plantuml

実行環境は **Nix flake**（この skill 自身が抱えている）。`plantuml.jar` も `java` も
`graphviz` も `fonts-noto-cjk` も system へ入れない。`scripts/plantuml-export.sh` は
PATH に `plantuml` が無ければ自動で devShell へ入り直すので、呼ぶ側は `nix develop` を
意識しなくてよい。

## ファイル構成

`.puml` は `plantuml/` 直下に置き、出力は `plantuml/out/` へ。

```
plantuml/
├── 01_order_flow.puml
├── 02_class.puml
└── out/
    ├── 01_order_flow.svg
    └── 02_class.svg
```

## 生成

`plantuml/`（`.puml` があるディレクトリ）の中で実行する。

```sh
~/.claude/skills/plantuml/scripts/plantuml-export.sh              # *.puml -> out/*.svg
~/.claude/skills/plantuml/scripts/plantuml-export.sh -f png       # 目視確認用
~/.claude/skills/plantuml/scripts/plantuml-export.sh -f svg,png   # 両方まとめて
~/.claude/skills/plantuml/scripts/plantuml-export.sh 01_order_flow.puml
```

| オプション | |
| --- | --- |
| `-f svg\|png\|pdf\|txt` | 形式（既定 `svg`）。カンマ区切りで複数指定できる |
| `-o DIR` | 出力先（既定 `out`）|
| `--transparent` | 背景を透過にする（既定は白背景）|
| `-h`, `--help` | 使い方 |

`.puml` が 1 つも無ければエラーで止まる（黙って成功しない）。

**図を作ったら PNG でも書き出して目で確認する。** テキストを読んだだけでは
ラベルのはみ出しや線の交差に気付けない。

## 規約

- **白背景。** PlantUML は既定で白背景なので、`skinparam backgroundColor #FFFFFF` を
  書く必要は無い（SVG は `style="background:#FFFFFF"`、PNG はアルファ無しで出る）。
  透過が要るときだけ `--transparent` を使う
- `out/` は生成物。リポジトリに含めるかはプロジェクトの方針に従う
- ファイル名は連番プレフィックス（`01_`, `02_`）で並び順を固定する

## .puml の骨組み

```
@startuml
title 受注フロー
actor 顧客 as C
participant "注文サービス" as O
database "在庫DB" as D

C -> O : 注文を送信
O -> D : 在庫を確認
D --> O : 残り 3 個
O --> C : 受付完了
@enduml
```

`skinparam` を並べるより `!theme` を使うほうが揃う（`!theme plain` など）。
テーマによっては背景色が変わるので、その場合は出力を目で確認する。

## 日本語

フォントは flake が抱えているので **system 側に入れる必要はない**
（`sudo apt install fonts-noto-cjk` は不要）。

ただし **「手元で日本語が出る」ことは他の環境で出る根拠にならない。** 手元では
ホストのフォントが拾われている可能性がある。CI や素のコンテナで豆腐（□□□）に
なるかどうかは `references/troubleshooting.md` の「フォント」を見る。

**`noto-fonts-cjk-sans-static` を `-static` 無しに変えてはいけない。** OpenJDK は
可変フォントを描画できず、黙って豆腐になる。理由は同じく troubleshooting を見る。

## 版

PlantUML の版は nixpkgs が決め、`flake.lock` が固定する。上げるときは
`nix flake update` してから **`flake.lock` を commit する**（store は read-only なので
lock が無いと動かない）。

nixpkgs より新しい版を使いたい場合や、プロジェクト側で版を固定したい場合は
`references/from-mise.md` の「版の固定」を見る。

## その他

- 豆腐・レイアウト崩れ・graphviz 関連のエラー → `references/troubleshooting.md`
- 旧 `mise.toml` 構成からの移行 → `references/from-mise.md`

ref: https://github.com/pollenjp/plantuml-template
