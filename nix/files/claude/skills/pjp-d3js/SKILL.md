---
name: pjp-d3js
description: D3.js / Observable Plot でデータのグラフや独自の可視化を描く・直す・書き出すときに使う。
  計測値・推移・分布・内訳を SVG / PNG の図にするとき、力学グラフ・treemap・地図・等高線のように
  定番の形に収まらない図を作るとき、`d3js/` ディレクトリを用意するとき、cc-pages の standalone
  ページでズーム・ドラッグ・ブラシできる図を作るときに読む。Nix flake での実行環境（Node・d3・Plot・
  linkedom・resvg・日本語フォント）、chart module の書き方、ファイル構成と出力先、白背景などの規約、
  DOM の無い Node で踏む罠を含む
---

# pjp-d3js

実行環境は **Nix flake**（この skill 自身が抱えている）。node_modules も resvg も日本語フォントも
system へ入れない（`npm install -g` もしない）。`scripts/d3js-export.sh` は devShell の外で呼ばれると
自動で入り直すので、呼ぶ側は `nix develop` を意識しなくてよい。

**グラフの形と配色の決め方は `dataviz` skill を先に読む。** この skill が持つのは D3 / Plot での
書き方と書き出しだけ。
dataviz の手順のうち、ホバー（手順 5）とダークモード・表（手順 6）は SVG・PNG の書き出しには当てはまらない
（対話ページでは当てはまる）。配色の validator は、script が敷く白に合わせて `--surface "#ffffff"` で流す。

## D3 か Plot か

| 描きたいもの | 書くもの |
| --- | --- |
| 棒・折れ線・面・散布・ヒートマップ・箱ひげなど、定番の形 | Observable Plot（数行で済む） |
| 力学グラフ・treemap・sunburst・地図・等高線・独自の形 | D3 |
| ズーム・ドラッグ・ブラシ・遷移で触って操作したい | D3 の対話ページ（下の「対話ページ」） |
| 関係・流れ・構成（箱と線） | `pjp-plantuml` / `pjp-drawio` |

Plot は D3 と同じチームの上位の層で、中で D3 を使っている。迷ったら Plot で書き始め、
Plot の mark で表せないところだけ D3 に降りる。

## ファイル構成

chart module（`.mjs`）は `d3js/` 直下に置き、出力は `d3js/out/` へ。

```
d3js/
├── 01_downloads.mjs     1 ファイル = 1 枚
├── 02_releases.mjs
├── _palette.mjs         _ で始まるものは書き出さない（色・軸などの部品）
├── data/
│   └── downloads.json
└── out/
    ├── 01_downloads.svg
    └── 01_downloads.png
```

## 生成

`d3js/`（`.mjs` があるディレクトリ）の中で実行する。

```sh
~/.claude/skills/pjp-d3js/scripts/d3js-export.sh              # *.mjs -> out/*.svg
~/.claude/skills/pjp-d3js/scripts/d3js-export.sh -f svg,png   # 目視確認用の PNG も
~/.claude/skills/pjp-d3js/scripts/d3js-export.sh 01_downloads.mjs
```

| オプション | |
| --- | --- |
| `-f svg\|png` | 形式（既定 `svg`）。カンマ区切りで両方指定できる |
| `-o DIR` | 出力先（既定 `out`） |
| `-s N` | PNG の拡大率（既定 `1`） |
| `--transparent` | 白背景を敷かない |
| `-h`, `--help` | 使い方 |

`.mjs` が 1 つも無ければエラーで止まる（黙って成功しない）。失敗した chart module が
あっても残りは書き出し、最後に失敗を返す。

**図を作ったら PNG でも書き出して目で確認する。** コードを読んだだけでは
ラベルの衝突やはみ出しに気付けない。

## chart module の書き方

default export の関数が **SVG 要素を返す**（async でもよい）。D3 の公式の例と同じく
`import * as d3 from "d3"` と書ける（skill の node_modules から読まれる）。使える npm パッケージは
`d3`・`@observablehq/plot`・`linkedom` と、その依存（`d3-time-format` など）だけ。

### D3

```js
// d3js/01_downloads.mjs
// data/downloads.json: [{ "month": "2026-01", "count": 120 }, …]
import * as d3 from "d3";
import data from "./data/downloads.json" with { type: "json" };

export default function () {
  const width = 640;
  const height = 320;
  const m = { top: 16, right: 16, bottom: 28, left: 52 };
  const x = d3.scaleUtc(d3.extent(data, (d) => new Date(d.month)), [m.left, width - m.right]);
  const y = d3.scaleLinear([0, d3.max(data, (d) => d.count)], [height - m.bottom, m.top]).nice();

  const svg = d3.create("svg").attr("width", width).attr("height", height).attr("viewBox", [0, 0, width, height]);
  svg.append("g").attr("transform", `translate(0,${height - m.bottom})`).call(d3.axisBottom(x));
  svg.append("g").attr("transform", `translate(${m.left},0)`).call(d3.axisLeft(y));
  svg
    .append("path")
    .datum(data)
    .attr("fill", "none")
    .attr("stroke", "#2a78d6")
    .attr("stroke-width", 2)
    .attr("d", d3.line((d) => x(new Date(d.month)), (d) => y(d.count)));
  return svg.node();
}
```

### Plot

```js
// d3js/02_releases.mjs
// data/releases.json: [{ "year": 2023, "count": 4 }, …] (年は数値で持つ。文字列だと Plot が警告する)
import * as Plot from "@observablehq/plot";
import data from "./data/releases.json" with { type: "json" };

export default function () {
  return Plot.plot({
    width: 640,
    height: 280,
    style: { fontSize: "12px" }, // 既定の 10px は日本語には小さい
    x: { tickFormat: "d" }, // 年を 2,023 ではなく 2023 と出す
    y: { grid: true, label: "リリース数" },
    marks: [Plot.barY(data, { x: "year", y: "count", fill: "#2a78d6", ry1: 4 }), Plot.ruleY([0])],
  });
}
```

### データ

- JSON: `import data from "./data/x.json" with { type: "json" };`
- CSV: `node:fs` で読んで `d3.csvParse`（書き出しでは動く。対話ページでは動かない）

```js
import { readFileSync } from "node:fs";
const rows = d3.csvParse(readFileSync(new URL("./data/x.csv", import.meta.url), "utf8"), d3.autoType);
```

## 規約

- **白背景。** script が viewBox に合わせて白い矩形を敷く。図の中に背景の矩形を置かない。
  透過が要るときだけ `--transparent`
- **毎回同じ SVG にする。** 乱数は `Math.random` ではなく `d3.randomLcg(42)` を種にする。
  力学グラフは `.stop()` して `tick()` を手で回す（`references/troubleshooting.md`）
- **width・height と viewBox を両方付ける。** width・height が PNG の大きさになり、viewBox が中身の座標になる
- **文字の幅は測れない。** `getBBox` も `getComputedTextLength` も使えない（DOM はあるがレイアウトの
  計算が無い）。余白は文字数から見積もる（troubleshooting）
- **Plot に title・subtitle・caption・legend を付けない。** 付けると SVG ではなく `<figure>`（HTML）が
  返り、script が止まる。題は図の外（Markdown・Notion のキャプション）に書く
- **transition を使わない。** 書き出しは最初の値のまま止まる。最後の値を `attr` で直接入れる
- **Plot の警告を残さない。** 書き出しの出力に `Warning:` が出たら直す。直さないと図の右上に ⚠️ が
  描き込まれる。よくあるのは数字の文字列（`"2023"`）を x に渡したもの（troubleshooting）
- **凡例は SVG のマークで描く。** 2 系列以上なら凡例を置き、4 系列までは線の終わりに直接ラベルも足す
  （dataviz）。Plot の凡例（`legend: true`）は使えないので、marks に関数を置いて描く（troubleshooting）
- 色は `dataviz` skill の手順で決める。複数の図に同じもの（地域など）が出るなら同じ色にする。
  文字は系列の色で塗らない
- 見た目の細部（棒の角の丸め・線の太さ 2px など）は dataviz の marks-and-anatomy に従う。Plot では
  `ry1: 4`（縦棒の上の角）・`rx2: 4`（横棒の右の角）・`strokeWidth: 2`（線）で付ける
- `out/` は生成物。リポジトリに含めるかはプロジェクトの方針に従う
- ファイル名は連番プレフィックス（`01_`, `02_`）で並び順を固定する

## 日本語

SVG の文字は `<text>` のまま残り、見る側（ブラウザ・Notion）のフォントで描かれる。
`font-family` は D3 の軸の既定（`sans-serif`）や Plot の既定（`system-ui, sans-serif`）のままでよい。
文字の大きさは、どちらも既定の 10px が日本語には小さい。Plot は `style: { fontSize: "12px" }`、
D3 の軸は `.call(d3.axisBottom(x)).attr("font-size", 12)` で上げる。

PNG は flake の Noto Sans CJK で描く（**system 側にフォントを入れる必要はない**）。
`sans-serif` と、`font-family` が無いときの既定を Noto Sans CJK JP にしてある。

## 対話ページ（cc-pages の standalone）

ズーム・ドラッグ・ブラシ・遷移のように触って操作する図は、cc-pages の **standalone** ページ
（`cc-pages new --mode standalone`）に書く。fragment のページは script を書けない。

```sh
~/.claude/skills/pjp-d3js/scripts/d3js-vendor.sh "$dir/assets"          # d3.min.js
~/.claude/skills/pjp-d3js/scripts/d3js-vendor.sh --plot "$dir/assets"   # plot.umd.min.js も
```

ページの CSP では **CDN が止まり、`d3.csvParse` も EvalError で止まる**。骨組み・制約・
確かめ方は `references/interactive.md`（書く前に読む）。

## 版

d3・Plot・linkedom の版は `package.json` と `package-lock.json` が、node・resvg・フォントの版は
`flake.lock` が固定する。どちらも **公開から 7 日以上経ったものだけ**を使う
（`pjp-dep-release-age` / `pjp-nix-flake` skill）。上げるときは dotfiles の repo の root で:

```sh
# package.json の版を、公開から 7 日以上経った版に書き換えてから
( cd nix/files/claude/skills/pjp-d3js && nix develop path:. --command npm install --package-lock-only )
./nix/scripts/flake-lock-age.sh update ./nix/files/claude/skills/pjp-d3js  # flake.lock (パスは ./ から書く)
nix/files/claude/skills/pjp-d3js/tests/run.sh                              # 書き出しを一通り確かめる
```

`.npmrc` の `min-release-age=7` が lock を作り直すときに効く。上げたら `package.json`・
`package-lock.json`・`flake.lock` を commit する（store は read-only なので lock が無いと動かない）。

## その他

- DOM の無い Node で踏む罠・エラーの読み方 → `references/troubleshooting.md`
- 対話ページの骨組み・CSP・確かめ方 → `references/interactive.md`
- `tests/run.sh` は scripts/ を直したとき・版を上げたときに流す（dotfiles の repo の
  `nix/files/claude/skills/pjp-d3js/tests/run.sh`。配置後の `~/.claude/skills/pjp-d3js/tests/run.sh` でも動く）
