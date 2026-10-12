# 対話ページ（cc-pages の standalone）

ズーム・ドラッグ・ブラシ・遷移のように、触って操作する図の作り方。cc-pages の fragment の
ページは script を書けないので、standalone（完全な HTML）で書く。静的な図で足りるなら
`d3js-export.sh` で SVG に焼き、fragment から `<img>` で貼る方が安い。

## 手順

1. ページを作る（`pjp-cc-page` skill の手順に `--mode standalone` を付ける）

   ```sh
   cc-pages new --session "$CLAUDE_CODE_SESSION_ID" --mode standalone \
     --title "…" --summary "…" --tag 調査 --prompt "…"
   ```

2. 返った `dir` の `assets/` に D3 を写す（Plot も使うなら `--plot`）

   ```sh
   ~/.claude/skills/pjp-d3js/scripts/d3js-vendor.sh "$dir/assets"
   ```

3. `$dir/index.html` を下の「骨組み」から書き、「部品」を足す
4. headless Chromium で確かめる（下の「確かめ方」）

## CSP で止まるもの

ページの CSP は `script-src 'self' 'unsafe-inline'`（`'unsafe-eval'` は無い）。

| やりたいこと | 結果 | 代わり |
| --- | --- | --- |
| `assets/d3.min.js` を `<script src>` で読む | 動く | |
| inline の `<script>` | 動く | |
| CDN（jsdelivr・unpkg など）から読む | 止まる | `d3js-vendor.sh` で写す |
| `d3.csvParse` / `d3.tsvParse` / `d3.dsvFormat(",").parse` | EvalError（中で `new Function` を使う） | JSON にするか `d3.csvParseRows` |
| `d3.json("assets/x.json")`（同じ origin） | 動く | |
| `getBBox` / `getComputedTextLength` | 動く（ブラウザにはレイアウトがある） | |

CSV は `csvParseRows` で配列にして、object は自分で組む:

```js
const [head, ...rows] = d3.csvParseRows(text);
const data = rows.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i]])));
```

## 骨組み

```html
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>…</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #ffffff; --fg: #1a1a1a; --muted: #6b6b6b; --line: #e2e2e2; --card: #fafafa; --accent: #2563eb;
  --s0: #2a78d6; --s1: #eb6834; --s2: #1baf7a;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #16181c; --fg: #e6e6e6; --muted: #9aa0a6; --line: #2c3036; --card: #1c1f24; --accent: #7aa2f7;
    --s0: #3987e5; --s1: #d95926; --s2: #199e70;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.7 system-ui, "Noto Sans JP", sans-serif; }
main { max-width: 56rem; margin: 0 auto; padding: 16px 16px 64px; }
a { color: var(--accent); }
button { font: inherit; padding: 4px 12px; border-radius: 6px; border: 1px solid var(--line); background: var(--card); color: var(--fg); }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 8px; }
/* 軸の線と文字は currentColor で描かれるので、color を当てればダークでも読める */
svg.chart { display: block; width: 100%; height: auto; color: var(--fg); }
svg.chart .tick line { stroke: var(--line); }
</style>
</head>
<body>
<main>
<p><a href="../">← このセッションのページ一覧</a></p>
<h1>…</h1>
<div class="card"><svg id="chart" class="chart" viewBox="0 0 800 300" role="img" aria-label="…"></svg></div>
</main>
<script src="assets/d3.min.js"></script>
<script>
const DATA = [/* 値をここに JSON で埋める */];
// … 図を描く (下の「部品」) …
document.body.dataset.ready = "1"; // 描き終えた印。「確かめ方」で使う
</script>
</body>
</html>
```

- 戻る導線 `<a href="../">` を先頭に置く（standalone にはナビが無い）
- 色は CSS 変数で持ち、`style("fill", "var(--s0)")` で当てる。`attr("fill", "var(--s0)")` では効かない
  （属性には `var()` が使えない）
- 色の選び方は `dataviz` skill（系列の色の順・ダークの色）

## 部品

### ズームとドラッグ（力学グラフ）

`DATA = { nodes: [{ id }], links: [{ source, target }] }` を描く。

```js
{
  const svg = d3.select("#chart").attr("viewBox", [-400, -150, 800, 300]); // 原点を中心にする
  const g = svg.append("g");
  svg.call(d3.zoom().scaleExtent([0.5, 4]).on("zoom", (e) => g.attr("transform", e.transform)));
  const nodes = DATA.nodes.map((d) => ({ ...d })); // simulation が x・y を書き込むので写す
  const links = DATA.links.map((d) => ({ ...d }));
  const sim = d3.forceSimulation(nodes)
    .force("link", d3.forceLink(links).id((d) => d.id).distance(50))
    .force("charge", d3.forceManyBody().strength(-120))
    .force("x", d3.forceX(0).strength(0.06))
    .force("y", d3.forceY(0).strength(0.09));
  const link = g.append("g").selectAll("line").data(links).join("line").style("stroke", "var(--muted)");
  const node = g.append("g").selectAll("circle").data(nodes).join("circle")
    .attr("r", 6).style("fill", "var(--s0)")
    .call(d3.drag()
      .on("start", (e, d) => { if (!e.active) sim.alphaTarget(0.3).restart(); d.fx = d.x; d.fy = d.y; })
      .on("drag", (e, d) => { d.fx = e.x; d.fy = e.y; })
      .on("end", (e, d) => { if (!e.active) sim.alphaTarget(0); d.fx = null; d.fy = null; }));
  node.append("title").text((d) => d.id);
  sim.on("tick", () => {
    link.attr("x1", (d) => d.source.x).attr("y1", (d) => d.source.y)
      .attr("x2", (d) => d.target.x).attr("y2", (d) => d.target.y);
    node.attr("cx", (d) => d.x).attr("cy", (d) => d.y);
  });
}
```

### 遷移（ボタンで並べ替える）

`DATA = [{ name, value }]` を描く。ボタンは `<button id="sort" type="button">並べ替える</button>`。

```js
{
  const W = 800, H = 300, m = { top: 16, right: 12, bottom: 28, left: 40 };
  const svg = d3.select("#chart");
  const x = d3.scaleBand(DATA.map((d) => d.name), [m.left, W - m.right]).padding(0.2);
  const y = d3.scaleLinear([0, d3.max(DATA, (d) => d.value)], [H - m.bottom, m.top]).nice();
  const rect = svg.append("g").selectAll("rect").data(DATA, (d) => d.name).join("rect")
    .attr("x", (d) => x(d.name)).attr("y", (d) => y(d.value))
    .attr("width", x.bandwidth()).attr("height", (d) => y(0) - y(d.value))
    .style("fill", "var(--s0)");
  const gx = svg.append("g").attr("transform", `translate(0,${H - m.bottom})`).call(d3.axisBottom(x));
  let sorted = false;
  d3.select("#sort").on("click", () => {
    sorted = !sorted;
    x.domain((sorted ? d3.sort(DATA, (d) => -d.value) : DATA).map((d) => d.name));
    const t = svg.transition().duration(750);
    rect.transition(t).attr("x", (d) => x(d.name));
    gx.transition(t).call(d3.axisBottom(x));
  });
}
```

### ブラシ（範囲を選ぶ）

`DATA = [{ date: "2026-01-01", value }]` を描く。結果は `<p id="range"></p>` に出す。

```js
{
  const W = 800, H = 300, m = { top: 16, right: 16, bottom: 28, left: 48 };
  const data = DATA.map((d) => ({ date: new Date(d.date), value: d.value }));
  const svg = d3.select("#chart");
  const x = d3.scaleUtc(d3.extent(data, (d) => d.date), [m.left, W - m.right]);
  const y = d3.scaleLinear([0, d3.max(data, (d) => d.value)], [H - m.bottom, m.top]).nice();
  svg.append("path").datum(data).attr("fill", "none").style("stroke", "var(--s0)").attr("stroke-width", 2)
    .attr("d", d3.line((d) => x(d.date), (d) => y(d.value)));
  svg.append("g").attr("transform", `translate(0,${H - m.bottom})`).call(d3.axisBottom(x));
  const label = d3.select("#range");
  svg.append("g").call(d3.brushX().extent([[m.left, m.top], [W - m.right, H - m.bottom]])
    .on("brush end", ({ selection }) => {
      if (!selection) return label.text("横にドラッグして範囲を選ぶ");
      const [a, b] = selection.map(x.invert);
      const sel = data.filter((d) => d.date >= a && d.date <= b);
      label.text(`${sel.length} 件、合計 ${d3.format(",")(d3.sum(sel, (d) => d.value))}`);
    }));
}
```

### Observable Plot

`d3js-vendor.sh --plot` で写し、`d3.min.js` の後に読む（Plot の UMD は global の `d3` を使う）。
ページの中では、Plot が title や凡例付きの `<figure>` を返してもそのまま置ける
（書き出しでは止まるが、ページは HTML なので）。

```html
<script src="assets/d3.min.js"></script>
<script src="assets/plot.umd.min.js"></script>
<script>
document.querySelector("#plot").append(
  Plot.plot({ color: { legend: true }, marks: [Plot.barY(DATA, { x: "name", y: "value", fill: "group" })] })
);
document.body.dataset.ready = "1";
</script>
```

## 確かめ方

書いたら headless Chromium で開き、描き終えた印・エラー・見た目を確かめる。script は 1 か所でも
例外になると後ろが全部動かないので、印が出ないときはまずエラーを見る。chromium が PATH に
無ければ `nix shell nixpkgs#chromium --command …` で借りる（system に入れない）。

```sh
url=…   # cc-pages new が返した url
chromium --headless --disable-gpu --virtual-time-budget=5000 --dump-dom "$url" | grep -c 'data-ready="1"'
chromium --headless --disable-gpu --enable-logging=stderr --v=0 --virtual-time-budget=5000 \
  --dump-dom "$url" 2>&1 >/dev/null | grep -i 'CONSOLE'
chromium --headless --disable-gpu --hide-scrollbars --window-size=1000,1400 --screenshot=check.png "$url"
```

- 1 行目が `1` なら描き終えている
- 2 行目はページのコンソールの出力。何も出なければよい
  - `violates the following Content Security Policy directive` は CSP で止まった印（CDN を読んでいないか）
  - `EvalError` は eval を使う関数を呼んだ印（`d3.csvParse` など）
  - `Uncaught …` は例外。その行より後ろの script は動いていない
- 3 行目の `check.png` を Read で開き、ラベルの重なりやはみ出しを見る
