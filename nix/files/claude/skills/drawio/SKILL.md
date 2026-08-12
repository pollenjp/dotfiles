---
name: drawio
description: draw.io / diagrams.net で図を描く・直す・書き出すときに使う。`.drawio` を
  新規に書くとき、ネットワーク構成図・アーキテクチャ図・構成図などを drawio で作るよう
  頼まれたとき、`drawio/` ディレクトリを用意するとき、図を SVG / PNG へ出力するときに読む。
  Nix flake での実行環境（drawio 本体・仮想ディスプレイ・日本語フォント）、ファイル構成と
  出力先、白背景などの規約、headless 特有のハマりどころを含む
---

# drawio

実行環境は **Nix flake**（この skill 自身が抱えている）。`drawio-desktop` の `.deb` も
`xvfb` も `fonts-noto-cjk` も system へ入れない。`scripts/drawio-export.sh` は PATH に
`drawio` が無ければ自動で devShell へ入り直すので、呼ぶ側は `nix develop` を意識しなくてよい。

## ファイル構成

`.drawio` は `drawio/` 直下に置き、出力は `drawio/out/` へ。

```
drawio/
├── 01_network_topology.drawio
├── 02_sequence.drawio
└── out/
    ├── 01_network_topology.svg
    └── 02_sequence.svg
```

## 生成

`drawio/`（`.drawio` があるディレクトリ）の中で実行する。

```sh
~/.claude/skills/drawio/scripts/drawio-export.sh                # *.drawio -> out/*.svg
~/.claude/skills/drawio/scripts/drawio-export.sh -f png -s 1.4  # 目視確認用
~/.claude/skills/drawio/scripts/drawio-export.sh 01_network_topology.drawio
```

| オプション | |
| --- | --- |
| `-f svg\|png\|pdf\|jpg` | 形式（既定 `svg`）|
| `-o DIR` | 出力先（既定 `out`）|
| `-s N` | 拡大率（png / jpg 向け）|
| `--no-white-bg` | SVG に白背景を差し込まない（透過のまま出す）|
| `--keep-noise` | Electron の無害なエラー出力を隠さない |

`.drawio` が 1 つも無ければエラーで止まる（黙って成功しない）。

**図を作ったら PNG でも書き出して目で確認する。** XML を読んだだけでは重なりや
はみ出しに気付けない。

## 規約

- **白背景。** SVG は書き出したあとルート直下へ白い矩形を差し込んでいる
  （`mxGraphModel` の `background` 属性は SVG 出力に反映されないため）。
  **図の中に背景用の白い矩形セルを置く必要はない**
- `out/` は生成物。リポジトリに含めるかはプロジェクトの方針に従う
- 色は `fillColor` / `strokeColor` を明示する（既定色はビューアのテーマで揺れる）

## .drawio の骨組み

```xml
<mxfile host="app.diagrams.net">
  <diagram name="ページ名" id="d1">
    <mxGraphModel dx="800" dy="600" grid="0" page="1" pageWidth="1480" pageHeight="1010">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
        <mxCell id="n1" value="ノード" vertex="1" parent="1"
          style="rounded=0;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;">
          <mxGeometry x="60" y="80" width="200" height="60" as="geometry" />
        </mxCell>
        <mxCell id="e1" edge="1" parent="1" source="n1" target="n2"
          style="edgeStyle=orthogonalEdgeStyle;html=1;">
          <mxGeometry relative="1" as="geometry" />
        </mxCell>
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
```

style の語彙は多いので、凝った図を作るときは MCP サーバの `search_shapes` を使うか、
`references/mcp.md` にあるリファレンスの場所を見る。

## 日本語

フォントは flake が抱えているので **system 側に入れる必要はない**
（`sudo apt install fonts-noto-cjk` は不要）。

ただし **「手元で日本語が出る」ことは他の環境で出る根拠にならない。** 手元では
ホストのフォントが拾われている可能性がある。CI や素のコンテナで豆腐（□□□）に
なるかどうかは `references/troubleshooting.md` の「フォント」を見る。

## 版

drawio の版は nixpkgs が決め、`flake.lock` が固定する。上げるときは
`nix flake update` してから **`flake.lock` を commit する**（store は read-only なので
lock が無いと動かない）。

プロジェクト側で版を固定したい・CI で図を生成したい場合は、この skill の `flake.nix`
をプロジェクトへコピーして `nix flake lock` すればよい（`nix run .#drawio` が使える）。

## その他

- headless 特有のハマりどころ、無視してよいエラー出力 → `references/troubleshooting.md`
- 公式 MCP サーバ（図をエディタで開く）の登録 → `references/mcp.md`
- 旧 `mise.toml` 構成からの移行 → `references/from-mise.md`
