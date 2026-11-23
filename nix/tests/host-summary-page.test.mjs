// ホストの要約の HTML 版の図を描く JS (nix/lib/host-summary/page.js) の、DOM を使わない部分 (箱の並び・配置・囲みの矩形の組) を、
// 作り物のホストから作ったページの #data で確かめる (ADR 093)。
//
//   node nix/tests/host-summary-page.test.mjs <page.js のパス> <ページの組の JSON のパス>
//
// flake の checks (host-summary-page-test) が Nix のサンドボックスで、page.js と、作り物のホスト (fixtures/host-summary) から
// lib.hostSummary.files で作ったページの組 (docs/hosts/ からの path → 中身。入れ子の JSON) を渡して流す。ブラウザでの見た目と
// 操作 (タブ・ポップアップ・暗い色) はここでは見ない (PR を出す前に headless の Chrome で撮って確かめる。pjp-diagram-motion)。
//
// ## 確かめること
//
//   - page.js は node で読める (構文の誤りが無い) と、DOM の無いところでは描かずに関数だけを出す
//   - どのページのどの図でも、箱は重ならず、それぞれの列の段の領域の中 (縁から pad の内) にある。段の領域は内の段ほど内に入れ子
//     (内の領域が外の領域の中に、inset 以上の間を空けて収まる)
//   - ホストのページ (order "host") の 1 つめのタブ (このホスト) は、列ごとに入る箱が上から並び (入らない箱より前)、入る箱は
//     1 つの島にまとまる (隣どうしの列の入る箱は一番上の行で接し、入る箱の無い列は一番上の行の水路で渡る)
//   - 2 つめのタブ (既定) の入る箱も、列ごとに 1 つの区間にまとまる (ホストで足した → どちらも → ホストで外した の並び)
//   - どのタブの囲みの矩形の組も、線の太さぶん広げても入らない箱に重ならない (線が入らない箱に触れない)。線 (箱からの間 d と太さ t) は、
//     箱と箱の隙間の中に収まる (重ねるタブでは、重ねる線の数ごとに全部の線が収まる)
//   - 入る箱の列が途中で空く (② の列に入る箱が無い) と、一番上の行の水路で空いた列の箱の上を渡り、その箱を囲まずに 1 つの島になる
//   - 重ねる線が 1〜30 本のどれでも、どの線 (箱からの間 d と太さ t) も箱と箱の隙間に収まり、水路の下の縁の線が空いた列の箱に
//     触れない (d > t + 1)。線は外ほど箱から離れる
//   - 入口 (order "count") の箱の並びは、入るホストの多い順 (同じなら表の順)
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import assert from "node:assert/strict";

const [jsPath, pagesPath] = process.argv.slice(2);
if (!jsPath || !pagesPath) {
  console.error("使い方: node host-summary-page.test.mjs <page.js> <pages.json>");
  process.exit(2);
}

let pass = 0, fail = 0;
const ok = (name, f) => {
  try {
    f();
    pass++;
    console.log(`  ok   ${name}`);
  } catch (e) {
    fail++;
    console.log(`  FAIL ${name}\n       ${String(e.message).replace(/\n/g, "\n       ")}`);
  }
};

const require = createRequire(import.meta.url);
let HostMap;
ok("page.js は node で読め、DOM の無いところでは関数だけを出す", () => {
  HostMap = require(jsPath);
  for (const k of ["orderColumns", "layout", "unionRects", "components", "outlineSpec", "L"]) assert.ok(HostMap[k], k);
});
if (!HostMap) process.exit(1);
const { L, orderColumns, layout, unionRects, components, outlineSpec } = HostMap;

// ページの組から HTML 版を集め、#data を読む
const pages = JSON.parse(readFileSync(pagesPath, "utf8"));
const htmls = [];
const walk = (node, path) => {
  for (const [k, v] of Object.entries(node)) {
    if (typeof v === "string") { if (k.endsWith(".html")) htmls.push([`${path}${k}`, v]); }
    else walk(v, `${path}${k}/`);
  }
};
walk(pages, "");
const dataOf = (html) => JSON.parse(html.split('<script type="application/json" id="data">')[1].split("</script>")[0]);
const figures = htmls.flatMap(([path, html]) => dataOf(html).figures.map((fig) => ({ path, fig })));
ok("作り物のホストのページから図を読めた (ホストのページと入口)", () => {
  assert.ok(htmls.some(([p]) => p === "html/hosts.html"), "html/hosts.html が無い");
  assert.ok(figures.some(({ fig }) => fig.order === "host"), "ホストのページの図が無い");
  assert.ok(figures.some(({ fig }) => fig.order === "count"), "入口の図が無い");
});

const onIn = (v, key) => !!(v && v.tools[key] && v.tools[key].e);
const overlap = (a, b, eps = 0.5) =>
  Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) > eps && Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y) > eps;
const inside = (inner, outer, gap) =>
  inner.x >= outer.x + gap - 1e-6 && inner.y >= outer.y + gap - 1e-6 &&
  inner.x + inner.w <= outer.x + outer.w - gap + 1e-6 && inner.y + inner.h <= outer.y + outer.h - gap + 1e-6;
const grow = (r, t) => ({ x: r.x - t, y: r.y - t, w: r.w + 2 * t, h: r.h + 2 * t });
const gapMin = Math.min(L.gx, L.gy);

for (const { path, fig } of figures) {
  const tag = `${path} (${fig.id})`;
  const cols = orderColumns(fig);
  const lay = layout(fig, cols);
  const regionOfCol = new Map(cols.map((c) => [c.id, lay.regions.find((r) => r.id === c.region)]));

  ok(`${tag}: 箱は重ならず、列の段の領域の中にあり、段の領域は入れ子`, () => {
    for (let i = 0; i < lay.boxes.length; i++) {
      for (let j = i + 1; j < lay.boxes.length; j++) assert.ok(!overlap(lay.boxes[i], lay.boxes[j]), `${lay.boxes[i].key} と ${lay.boxes[j].key} が重なる`);
      const b = lay.boxes[i];
      assert.ok(inside(b, regionOfCol.get(cols[b.ci].id), L.pad), `${b.key} が段の領域の外`);
    }
    for (let k = 0; k + 1 < lay.regions.length; k++) assert.ok(inside(lay.regions[k], lay.regions[k + 1], L.inset), `段 ${lay.regions[k].id} が外の段に収まらない`);
  });

  const singles = fig.views.filter((v) => v.kind !== "overlay");
  if (fig.order === "host") {
    const [h, d] = singles;
    ok(`${tag}: このホストの入る箱は列の上から並び、1 つの島にまとまる`, () => {
      for (const c of cols) {
        const first = c.tools.findIndex((k) => !onIn(h, k));
        if (first >= 0) assert.ok(c.tools.slice(first).every((k) => !onIn(h, k)), `${c.id} で入る箱が入らない箱の後ろにある`);
      }
      const isOn = (k) => onIn(h, k);
      if (lay.boxes.some((b) => isOn(b.key))) assert.equal(components(lay, isOn), 1);
    });
    ok(`${tag}: 既定の入る箱は列ごとに 1 つの区間にまとまる`, () => {
      for (const c of cols) {
        const idx = c.tools.map((k, i) => (onIn(d, k) ? i : -1)).filter((i) => i >= 0);
        if (idx.length) assert.equal(idx[idx.length - 1] - idx[0] + 1, idx.length, `${c.id} の既定の入る箱が離れている`);
      }
    });
  } else {
    ok(`${tag}: 入口の箱の並びは入るホストの多い順 (同じなら表の順)`, () => {
      const hosts = fig.views.filter((v) => v.kind === "host");
      for (const c of cols) {
        const counts = c.tools.map((k) => hosts.filter((v) => onIn(v, k)).length);
        for (let i = 1; i < counts.length; i++) assert.ok(counts[i - 1] >= counts[i], `${c.id} の並びが多い順でない`);
        const orig = fig.columns.find((x) => x.id === c.id).tools;
        for (let i = 1; i < counts.length; i++) {
          if (counts[i - 1] === counts[i]) assert.ok(orig.indexOf(c.tools[i - 1]) < orig.indexOf(c.tools[i]), `${c.id} の同じ数の並びが表の順でない`);
        }
      }
    });
  }

  ok(`${tag}: どのタブの囲みも入らない箱に重ならず、線は箱と箱の隙間に収まる`, () => {
    const byId = new Map(fig.views.map((v) => [v.id, v]));
    for (const tab of fig.views) {
      const members = tab.kind === "overlay" ? tab.members.map((id) => byId.get(id)) : [tab];
      members.forEach((m, k) => {
        const { d, t } = outlineSpec(members.length, k);
        assert.ok(d + t < gapMin - 1, `${tab.id} の ${k} 本目の線 (d ${d}・t ${t}) が隙間 ${gapMin} に収まらない`);
        const rects = unionRects(lay, (key) => onIn(m, key), d, t);
        for (const b of lay.boxes) {
          if (onIn(m, b.key)) continue;
          for (const r of rects) assert.ok(!overlap(grow(r, t), b), `${tab.id} の ${m.id} の囲みの線が入らない ${b.key} に触れる`);
        }
      });
    }
  });
}

ok("入る箱の列が途中で空くと、一番上の行の水路で空いた列の箱の上を渡り、その箱を囲まずに 1 つの島になる", () => {
  const fig = {
    order: "host",
    regions: [{ id: "a", mark: "①", label: "A" }, { id: "b", mark: "②", label: "B" }, { id: "c", mark: "③", label: "C" }],
    columns: [
      { id: "c1", region: "a", head: "①", tools: ["x1", "x2"] },
      { id: "c2", region: "b", head: "②", tools: ["y1"] },
      { id: "c3", region: "c", head: "③", tools: ["z1", "z2"] },
    ],
    views: [
      { id: "host", kind: "host", tools: { x1: { e: true }, x2: { e: true }, y1: { e: false }, z1: { e: true }, z2: { e: false } } },
      { id: "default", kind: "default", tools: {} },
    ],
  };
  const cols = orderColumns(fig);
  const lay = layout(fig, cols);
  const isOn = (k) => onIn(fig.views[0], k);
  assert.equal(components(lay, isOn), 1);
  const y1 = lay.boxes.find((b) => b.key === "y1");
  for (const [n, k] of [[1, 0], [2, 1], [8, 7]]) {
    const { d, t } = outlineSpec(n, k);
    const rects = unionRects(lay, isOn, d, t);
    assert.ok(rects.some((r) => r.y + r.h < y1.y && r.x < y1.x && r.x + r.w > y1.x + y1.w), `水路が無い (d ${d})`);
    for (const r of rects) assert.ok(!overlap(grow(r, t), y1), `空いた列の箱に線が触れる (d ${d})`);
  }
});

ok("重ねる線が 1〜30 本のどれでも、どの線も隙間に収まり、水路の線が空いた列の箱に触れず、外の線ほど箱から離れる", () => {
  for (let n = 1; n <= 30; n++) {
    let prev = -1;
    for (let k = 0; k < n; k++) {
      const { d, t } = outlineSpec(n, k);
      assert.ok(d + t < gapMin - 1, `${n} 本の ${k} 本目 (d ${d}・t ${t}) が隙間 ${gapMin} に収まらない`);
      assert.ok(d > t + 1, `${n} 本の ${k} 本目 (d ${d}・t ${t}) の水路の線が箱に触れる`);
      assert.ok(d > prev, `${n} 本の ${k} 本目が内の線より外にない`);
      prev = d;
    }
  }
});

console.log(`== ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
