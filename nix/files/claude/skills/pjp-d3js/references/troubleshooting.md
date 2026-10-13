# pjp-d3js のハマりどころ

## 書き出し（d3js-export.sh）

### `Cannot find package 'xxx'`（ERR_MODULE_NOT_FOUND）

skill の node_modules にあるのは `d3`・`@observablehq/plot`・`linkedom` と、その依存だけ。
それ以外の npm パッケージ（topojson-client・lodash など）は import できない。

- 地図は、TopoJSON を GeoJSON に変換したものを `data/` に置いて読む
- どうしても要るパッケージは、この skill の `package.json` に足す（SKILL.md の「版」）

`node 01_xxx.mjs` のように直接動かしたときも同じエラーになる。chart module は
`d3js-export.sh` から呼ぶ（d3 を skill の node_modules から読む仕組みはそちらにある）。

### `default export が関数ではありません` / `何も返していません`

chart module は `export default function () { …; return svg.node(); }` の形にする。
`d3.select("body").append("svg")` で作ったときも、最後に `svg.node()` を返す。

### `SVG ではなく <figure> が返りました`

Plot は `title`・`subtitle`・`caption` か、`color: { legend: true }` などの凡例を付けると、SVG を
`<figure>`（HTML）で包んで返す。SVG のファイルにはできないので、script はここで止まる。

- 題・説明は図の外（Markdown の本文・Notion のキャプション）に書く
- 凡例は marks に関数を置いて描く。Plot はその関数を呼び、返った SVG 要素を図に入れる。
  2 系列以上なら凡例を置き、4 系列までは線の終わりに直接ラベルも足す（`dataviz` skill）

```js
const regions = ["東日本", "西日本"];
// 凡例 (線の見本と名前)。Plot は root に text-anchor="middle" を付けるので start に戻す
function legend(index, scales, values, dimensions) {
  const g = d3.create("svg:g").attr("transform", `translate(${dimensions.marginLeft},10)`);
  regions.forEach((name, i) => {
    const item = g.append("g").attr("transform", `translate(${i * 80},0)`);
    item.append("line").attr("x2", 16).attr("stroke", scales.color(name)).attr("stroke-width", 2);
    item.append("text").attr("x", 22).attr("dy", "0.32em").attr("text-anchor", "start")
      .attr("fill", "currentColor").text(name);
  });
  return g.node();
}
Plot.plot({
  marginTop: 36, // 凡例の場所
  color: { domain: regions, range: ["#2a78d6", "#eb6834"] },
  marks: [Plot.lineY(data, { x: "month", y: "sales", stroke: "region", strokeWidth: 2 }), legend],
});
```

### 文字の幅を測れない（`getBBox` / `getComputedTextLength`）

linkedom は DOM を持つが、レイアウトの計算をしない。文字の幅や要素の大きさは測れない。
軸の余白やラベルの置き場所は、文字数から見積もる:

```js
// 全角は 1em、半角は 0.6em とみなした幅 (px)
const textWidth = (s, size = 10) =>
  [...String(s)].reduce((w, c) => w + (c.codePointAt(0) > 0xff ? size : size * 0.6), 0);
// d3.axisLeft はラベルを軸から 9px (目盛り 6 + 間隔 3) 離して置く。8 は左端の余白
const left = 9 + 8 + d3.max(data, (d) => textWidth(d.name, 10));
```

### Plot の図の右上に ⚠️ が出る

Plot はデータに気になる点を見つけると、`Warning: …` を出したうえで、図の右上に ⚠️ を描き込む
（`<text>⚠️<title>1 warning. Please check the console.</title></text>`）。書き出しの出力の `Warning:` を読んで
原因を直す。

- `strings that appear to be numbers`: 数字の文字列（`"2023"`）を x に渡している。数値にするか
  （`+d.year`・`d3.autoType`）、順序の値として扱うなら `x: { type: "band" }` を付ける
- `strings that appear to be dates`: 日付の文字列を渡している。`new Date(d.date)` か `d3.autoType` で日付にする

### transition の値が入らない

書き出しは chart module が返った時点の SVG を書くので、`transition()` で付けた値は入らず、
最初の値のまま残る。chart module では最後の値を `attr` で直接入れる。transition は対話ページでだけ使う。

### 力学グラフが散らばらない・毎回形が違う・枠の外へ飛ぶ

`forceSimulation` は既定で timer で動くので、そのまま返すと動く前の位置で書き出される
（d3js-export.sh は `timer が動いたまま書き出しました` と知らせる）。`.stop()` して `tick()` を手で回す。
d3-force は固定の種の乱数を使うので、毎回同じ形になる。

```js
const sim = d3.forceSimulation(nodes)
    .force("link", d3.forceLink(links).id((d) => d.id).distance(40))
    .force("charge", d3.forceManyBody().strength(-80))
    .force("x", d3.forceX())
    .force("y", d3.forceY())
    .force("collide", d3.forceCollide(12))
    .stop();
for (let i = 0; i < 300; ++i) {
  sim.tick();
  for (const n of nodes) { // 枠 (viewBox) の中へ戻す
    n.x = Math.max(-w / 2 + pad, Math.min(w / 2 - pad, n.x));
    n.y = Math.max(-h / 2 + pad, Math.min(h / 2 - pad, n.y));
  }
}
```

- viewBox を原点が中心の `[-w / 2, -h / 2, w, h]` にすると、`forceX()` / `forceY()` の既定（0）と揃う
- ラベルが重なるときは、`forceCollide` の半径にラベルの長さを足す（`(d) => r + d.id.length * 2.5`）
- `Math.random` は毎回変わる。乱数が要るなら `d3.randomNormal.source(d3.randomLcg(42))()` のように種を固定する

### 地図の SVG が大きい

`d3.geoPath(projection).digits(1)` で座標の桁を落とす（TKT-144 では 348 KB → 257 KB）。
国の境界の GeoJSON は細かいほど重いので、縮尺に合った粗さのデータを使う。

### 日付の書式を日本語にする

```js
import ja from "d3-time-format/locale/ja-JP" with { type: "json" };
const locale = d3.timeFormatLocale(ja);
const fmt = locale.utcFormat("%-m月"); // 1月, 2月 …
svg.append("g").call(d3.axisBottom(x).tickFormat(fmt));
```

## PNG（resvg）

### PNG と SVG で見た目が少し違う

PNG は目で確かめる用で、正は SVG（ブラウザ・Notion は SVG を描く）。resvg は CSS の一部を読まない。
Plot の `<style>` にある `:where()` は読み飛ばす（d3js-export.sh がその警告を落としている）。

### `Rect '' has an invalid 'height' value. Skipped.`

値が 0 の棒（高さ 0 の rect）を resvg が飛ばしたという知らせで、見た目は変わらない。
高さが負になっているなら、y の scale の range の向き（`[height - bottom, top]`）を見直す。

### 文字の形が違う・豆腐になる

PNG は flake の Noto Sans CJK JP で描く。`font-family` に resvg が知らない名前（`system-ui` など）しか
無いと `sans-serif` に落ち、Noto Sans CJK JP になる。SVG を開く側では、その環境のフォントで描かれる。

## 依存

### 初回が遅い

初回は nix が node_modules（約 17 MB）と resvg・フォントを取ってくる。2 回目からは store にある。

### `nix develop ~/.claude/skills/pjp-d3js` が動かない

`~/.claude/skills/pjp-d3js` は store への symlink で、そのまま `path:` に渡すと
pure evaluation で落ちる。`readlink -f` で実体を渡す:

```sh
nix develop "path:$(readlink -f ~/.claude/skills/pjp-d3js)" --command node --version
```
