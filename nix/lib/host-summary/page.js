// ホストの道具の図 (dotfiles の nix/lib/host-summary/page.js)。page.html の <script> に差し込む (生成物の HTML 版の JS)。
//
// #data の JSON ({ figures: [ … ] }) から、図ごとに段の入れ子の領域・道具の箱・ホストごとの囲みの線を SVG に描き、タブで
// 見せる線を替える。pjp-diagram-motion の選択モードの雛形 (タブ・← →・▶ の自動再生・変わった所だけ点滅・箱の詳細を押した箱の
// 近くに出すポップアップ・動きを減らす設定) を元にしている。
//
// 図の形:
//   - 段の領域を内から ① → ② → ③ と左から並べ、外の段ほど外に入れ子にする。列は ①・②・②③ (② と ③ の両方の段で入る道具)・③
//   - 列の中の箱の並びは、ホストのページ (order "host") なら「ホストで足した → どちらでも入る → ホストで外した → どちらでも
//     入らない」、入口 (order "count") なら入るホストの多い順 (同じなら groups.nix の順)。ホストの入る道具が列の上から並ぶので、
//     隣どうしの列の入る箱が一番上の行で接し、囲みの線が 1 つの形 (階段) になる
//   - 囲みの線は、入る箱を少し広げた矩形と、隣どうしの入る箱をつなぐ橋の矩形の組 (unionRects) を、mask で中を抜いた太い縁で
//     描く (多角形を計算しない)。入る箱の無い列を挟むときは、一番上の行の箱どうしを、空いた列の箱の上を通る細い橋でつなぐ
//     (囲みは 1 本の線のまま、空いた列の箱は囲まない)。重ねるタブでは、線ごとに箱からの間を変える (箱と箱の隙間に収まる幅まで)
//
// 並び・配置・囲みの矩形の組は DOM を使わない関数にし、node のテスト (nix/tests/host-summary-page.test.mjs) が読む
// (module.exports)。ブラウザでは読み込んだときに #data から描く。
"use strict";

const HostMap = (() => {
  // 箱の幅と高さ・隙間 (列の間 gx・行の間 gy)・段の領域の入れ子の幅 (inset)・領域の縁から箱までの間 (pad)・外の余白
  // (margin)・一番内の領域の上の縁から 1 行目の箱まで (top。段の名前を置く)・箱の角の丸み
  const L = { bw: 144, bh: 42, gx: 24, gy: 20, inset: 14, pad: 28, margin: 8, top: 52, rx: 7 };

  // ---- 並び・配置・囲み (DOM を使わない) ----

  const onIn = (view, key) => !!(view && view.tools && view.tools[key] && view.tools[key].e);

  // 列ごとの箱の並び。空の列は外す
  function orderColumns(fig) {
    const hostViews = fig.views.filter((v) => v.kind !== "overlay");
    let rank;
    if (fig.order === "host" && hostViews.length >= 2) {
      const [h, d] = hostViews;
      rank = (k) => (onIn(h, k) ? (onIn(d, k) ? 1 : 0) : onIn(d, k) ? 2 : 3);
    } else {
      rank = (k) => -hostViews.filter((v) => onIn(v, k)).length;
    }
    return fig.columns
      .map((c) => ({
        ...c,
        tools: c.tools
          .map((k, i) => [rank(k), i, k])
          .sort((a, b) => a[0] - b[0] || a[1] - b[1])
          .map((x) => x[2]),
      }))
      .filter((c) => c.tools.length > 0);
  }

  // 箱と段の領域の位置。regions は内 → 外の順 (fig.regions と同じ)
  function layout(fig, cols) {
    const R = fig.regions.length;
    const left = [], top = [], right = [], bottom = [];
    for (let k = 0; k < R; k++) {
      left[k] = L.margin + L.inset * (R - 1 - k);
      top[k] = left[k];
    }
    const colX = new Map();
    const labelX = [];
    let prevRight = null;
    for (let k = 0; k < R; k++) {
      const own = cols.filter((c) => c.region === fig.regions[k].id);
      if (own.length === 0) {
        right[k] = (prevRight === null ? left[k] + 2 * L.pad : prevRight) + L.inset;
        labelX[k] = (prevRight === null ? left[k] : prevRight) + 12;
        prevRight = right[k];
        continue;
      }
      let x = k === 0 ? left[0] + L.pad : prevRight + L.pad;
      labelX[k] = x;
      own.forEach((c, i) => {
        colX.set(c.id, x);
        x += L.bw + (i < own.length - 1 ? L.gx : 0);
      });
      right[k] = x + L.pad;
      prevRight = right[k];
    }
    const nRows = Math.max(1, ...cols.map((c) => c.tools.length));
    const y0 = top[0] + L.top;
    const rowY = (i) => y0 + i * (L.bh + L.gy);
    const contentBottom = rowY(nRows - 1) + L.bh;
    for (let k = 0; k < R; k++) bottom[k] = contentBottom + L.pad + L.inset * k;
    const boxes = [];
    cols.forEach((c, ci) =>
      c.tools.forEach((key, row) => boxes.push({ key, ci, row, x: colX.get(c.id), y: rowY(row), w: L.bw, h: L.bh })),
    );
    const regions = fig.regions.map((r, k) => ({
      ...r,
      level: k,
      x: left[k],
      y: top[k],
      w: right[k] - left[k],
      h: bottom[k] - top[k],
      labelX: labelX[k],
      labelY: top[k] + 19,
    }));
    // 2 列以上を持つ領域だけ、列の見出しを出す (③ の領域の「②③」と「③」)
    const heads = [];
    fig.regions.forEach((r) => {
      const own = cols.filter((c) => c.region === r.id);
      if (own.length > 1) own.forEach((c) => heads.push({ id: c.id, text: c.head, x: colX.get(c.id), y: top[0] + 19 }));
    });
    return {
      W: right[R - 1] + L.margin,
      H: bottom[R - 1] + L.margin,
      boxes,
      regions,
      heads,
      cols: cols.map((c) => ({ ...c, x: colX.get(c.id) })),
      y0,
      nRows,
    };
  }

  // 入る箱 (isOn) を、隣どうしの橋でつないだ矩形の組にする。囲みの線は、この組の外側の縁。d は箱から線までの間、t は線の太さ
  //   - 入る箱を d だけ広げた矩形 (角は丸める)
  //   - 右隣・下隣の箱も入るなら、2 つの箱の真ん中どうしをつなぐ橋 (高さ・幅は広げた箱と同じ)。丸めた角の窪みも埋まる
  //   - 2×2 の 4 つとも入るなら、真ん中の隙間を埋める矩形
  //   - 一番上の行が入る列どうしの間に、一番上の行が入らない列があれば、その上を通る細い水路 (高さ t + 3)。下の縁の線は
  //     空いた列の箱の上の縁より上に収まる (d > t + 1)
  function unionRects(lay, isOn, d, t = 2.6) {
    const at = new Map(lay.boxes.map((b) => [`${b.ci},${b.row}`, b]));
    const on = (ci, row) => {
      const b = at.get(`${ci},${row}`);
      return b && isOn(b.key) ? b : null;
    };
    const cx = (b) => b.x + b.w / 2;
    const cy = (b) => b.y + b.h / 2;
    const rects = [];
    for (const b of lay.boxes) {
      if (!isOn(b.key)) continue;
      rects.push({ x: b.x - d, y: b.y - d, w: b.w + 2 * d, h: b.h + 2 * d, r: L.rx + d });
      const right = on(b.ci + 1, b.row);
      const down = on(b.ci, b.row + 1);
      if (right) rects.push({ x: cx(b), y: b.y - d, w: cx(right) - cx(b), h: b.h + 2 * d, r: 0 });
      if (down) rects.push({ x: b.x - d, y: cy(b), w: b.w + 2 * d, h: cy(down) - cy(b), r: 0 });
      if (right && down && on(b.ci + 1, b.row + 1)) {
        rects.push({ x: cx(b), y: cy(b), w: cx(right) - cx(b), h: cy(down) - cy(b), r: 0 });
      }
    }
    const tops = topsOf(lay, isOn);
    for (let i = 0; i + 1 < tops.length; i++) {
      const a = tops[i], b = tops[i + 1];
      if (b.ci - a.ci < 2) continue;   // 隣の列なら、上の橋でつながっている
      const w = t + 3;
      rects.push({ x: cx(a), y: a.y - d - w, w: cx(b) - cx(a), h: w + 1, r: 0 });
    }
    return rects;
  }

  // 一番上の行が入る箱 (列の順)
  function topsOf(lay, isOn) {
    return lay.boxes.filter((b) => b.row === 0 && isOn(b.key)).sort((a, b) => a.ci - b.ci);
  }

  // 入る箱が、隣どうし (右・下) と一番上の行の水路のつながりで、いくつの島に分かれるか (テストが読む)
  function components(lay, isOn) {
    const on = lay.boxes.filter((b) => isOn(b.key));
    const id = new Map(on.map((b, i) => [`${b.ci},${b.row}`, i]));
    const parent = on.map((_, i) => i);
    const find = (i) => (parent[i] === i ? i : (parent[i] = find(parent[i])));
    const join = (a, b) => { parent[find(a)] = find(b); };
    for (const b of on) {
      for (const [dc, dr] of [[1, 0], [0, 1]]) {
        const j = id.get(`${b.ci + dc},${b.row + dr}`);
        if (j !== undefined) join(id.get(`${b.ci},${b.row}`), j);
      }
    }
    const tops = topsOf(lay, isOn);
    for (let i = 0; i + 1 < tops.length; i++) join(id.get(`${tops[i].ci},0`), id.get(`${tops[i + 1].ci},0`));
    return new Set(on.map((_, i) => find(i))).size;
  }

  // 囲みの線の、箱からの間 (d) と太さ (t)。n は同じタブに重ねる線の数、k はその中の何本目。どの本数でも、いちばん外の線
  // (d + t) が箱と箱の隙間に収まるように間を割る (多いほど線どうしが詰まる。線を見分けるのはタブの色とタブにのせたときの強調)
  function outlineSpec(n, k) {
    if (n <= 1) return { d: 8, t: 2.6 };
    if (n <= 3) return { d: 5 + 5 * k, t: 2.2 };
    const t = 1.6;
    const maxD = Math.min(L.gx, L.gy) - t - 2;
    const step = Math.min(2.2, (maxD - 4) / (n - 1));
    return { d: 4 + step * k, t };
  }

  // ---- ここから DOM ----

  const SVGNS = "http://www.w3.org/2000/svg";
  const FONT = 'system-ui, -apple-system, "Segoe UI", "Hiragino Sans", "Noto Sans JP", "Yu Gothic UI", Meiryo, sans-serif';

  function boot() {
    const $ = (s, root = document) => root.querySelector(s);
    const $$ = (s, root = document) => [...root.querySelectorAll(s)];
    const el = (tag, cls, text) => {
      const e = document.createElement(tag);
      if (cls) e.className = cls;
      if (text != null) e.textContent = text;
      return e;
    };
    const sv = (tag, attrs = {}) => {
      const e = document.createElementNS(SVGNS, tag);
      for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
      return e;
    };
    const nextFrame = (fn) => requestAnimationFrame(() => requestAnimationFrame(fn));
    const dataEl = $("#data");
    if (!dataEl) return;
    const { figures } = JSON.parse(dataEl.textContent);

    // 文字の幅 (箱に収まらなければ字を小さくし、それでも収まらなければ … で切る)
    const ctx = document.createElement("canvas").getContext("2d");
    const textWidth = (s, size, weight = 700) => {
      if (!ctx) return s.length * size;
      ctx.font = `${weight} ${size}px ${FONT}`;
      return ctx.measureText(s).width;
    };
    function fitText(node, s, maxW, size = 12.5, min = 9.5) {
      let z = size;
      while (z > min && textWidth(s, z) > maxW) z -= 0.5;
      let t = s;
      if (textWidth(t, z) > maxW) {
        while (t.length > 1 && textWidth(`${t}…`, z) > maxW) t = t.slice(0, -1);
        t += "…";
      }
      node.setAttribute("font-size", z);
      node.textContent = t;
    }

    const colorOf = (v) => (v.color >= 1 && v.color <= 8 ? `var(--s${v.color})` : v.color === 0 ? "var(--def)" : "var(--muted)");

    // ---- 箱の詳細のポップアップ (雛形と同じ。どの図の箱からも開く) ----
    const popup = $("#popup"), popupIn = $(".popup-in", popup), popupTitle = $("#popup-title"), popupBody = $("#popup-body");
    const veil = $("#popup-veil"), main = $("main");
    const narrow = matchMedia("(max-width: 600px)");
    const clamp = (v, lo, hi) => Math.max(lo, Math.min(v, hi));
    let popupAt = null, seen = null, raf = 0;
    const isOpen = () => !popup.hidden;
    const clickables = [];   // { el, box (図の枠), open () }

    new IntersectionObserver((es) => { seen = es[es.length - 1].intersectionRect; if (isOpen()) place(); },
      { threshold: Array.from({ length: 21 }, (_, k) => k / 20) }).observe($("#vp"));
    function region() {
      const W = document.documentElement.clientWidth, H = document.documentElement.clientHeight;
      const r = { left: 0, top: 0, right: W, bottom: H };
      if (seen && seen.width >= 240 && seen.height >= 240) {
        r.left = clamp(seen.left, 0, W); r.top = clamp(seen.top, 0, H);
        r.right = clamp(seen.right, 0, W); r.bottom = clamp(seen.bottom, 0, H);
      }
      return r;
    }
    function place() {
      const R = region(), m = 8, gap = 10, W = R.right - R.left, H = R.bottom - R.top, s = popup.style;
      const a = popupAt && popupAt.isConnected ? popupAt.getBoundingClientRect() : null;
      popup.classList.remove("sheet");
      if (!narrow.matches && a && W >= 360) {
        let w = Math.min(440, W - 2 * m);
        const natural = () => { s.width = `${w}px`; s.setProperty("--popup-max", "none"); return popupIn.offsetHeight; };
        let h = natural();
        const below = R.bottom - m - a.bottom - gap, above = a.top - gap - R.top - m, need = Math.min(h, 260);
        let side = null, top = 0, left = 0, max = 0, want = 0;
        if (below >= need && (below >= h || below >= above || above < need)) { side = "bottom"; max = Math.min(below, 520); want = a.bottom + gap; }
        else if (above >= need) { side = "top"; max = Math.min(above, 520); want = a.top - gap - Math.min(h, max); }
        if (side) { left = clamp(a.left, R.left + m, R.right - m - w); top = want; }
        else {
          const rightSp = R.right - m - a.right - gap, leftSp = a.left - gap - R.left - m;
          if (Math.max(rightSp, leftSp) >= 320) {
            side = rightSp >= leftSp ? "right" : "left";
            w = Math.min(440, Math.max(rightSp, leftSp)); h = natural();
            max = Math.min(H - 2 * m, 520);
            left = side === "right" ? a.right + gap : a.left - gap - w;
            want = top = a.top - 12;
          }
        }
        if (side) {
          const hh = Math.min(h, max);
          top = clamp(top, R.top + m, R.bottom - m - hh);
          s.left = `${left}px`; s.top = `${top}px`; s.bottom = "auto"; s.setProperty("--popup-max", `${max}px`);
          const ax = a.left + a.width / 2 - left, ay = a.top + a.height / 2 - top;
          const ok = side === "bottom" || side === "top" ? Math.abs(top - want) < 1 && ax >= 14 && ax <= w - 14 : ay >= 14 && ay <= hh - 14;
          if (ok) { popup.dataset.side = side; s.setProperty("--ax", `${ax}px`); s.setProperty("--ay", `${ay}px`); }
          else delete popup.dataset.side;
          return;
        }
      }
      popup.classList.add("sheet"); delete popup.dataset.side;
      s.width = `${W}px`; s.left = `${R.left}px`; s.top = "auto";
      s.bottom = `${document.documentElement.clientHeight - R.bottom}px`;
      const room = a && a.bottom > R.top && a.bottom < R.bottom ? R.bottom - a.bottom - gap : H * 0.6;
      s.setProperty("--popup-max", `${Math.round(clamp(room, H * 0.45, H * 0.85))}px`);
    }
    function bump(cls) { popup.classList.remove("go", "swap"); void popup.offsetWidth; popup.classList.add(cls); }
    function cardsOf(card) {
      const list = el("div", "cards");
      card.rows.forEach((r, k) => {
        const c = el("div", "card");
        c.style.setProperty("--k", Math.min(k, 10));
        const v = el("span");
        if (r.code) v.append(el("code", null, r.v)); else v.textContent = r.v;
        c.append(el("b", null, r.k), v);
        list.append(c);
      });
      const frag = document.createDocumentFragment();
      frag.append(list);
      if (card.note) frag.append(el("p", "popup-note", card.note));
      return frag;
    }
    let selNode = null;
    function openPopup(card, from) {
      const first = !isOpen();
      popupAt = from;
      if (first) { veil.hidden = popup.hidden = false; main.inert = true; }
      if (selNode) selNode.classList.remove("sel");
      selNode = from; from.classList.add("sel");
      popupTitle.textContent = card.title;
      popupBody.replaceChildren(cardsOf(card));
      popupBody.scrollTop = 0;
      place();
      bump(first ? "go" : "swap");
      popupTitle.focus({ preventScroll: true });
    }
    function closePopup() {
      if (!isOpen()) return;
      veil.hidden = popup.hidden = true;
      popup.classList.remove("go", "swap");
      main.inert = false;
      if (selNode) { selNode.classList.remove("sel"); selNode = null; }
      const back = popupAt;
      popupAt = null;
      if (back && back.isConnected) back.focus({ preventScroll: true });
    }
    function clickableAt(x, y) {
      return clickables.find((c) => {
        if (c.el.closest(".hide")) return false;
        const f = c.box.getBoundingClientRect();
        if (x < f.left || x > f.right || y < f.top || y > f.bottom) return false;
        const r = c.el.getBoundingClientRect();
        return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
      }) || null;
    }
    function keepIn(t) {
      if (!popupBody.contains(t)) return;
      const b = popupBody.getBoundingClientRect(), r = t.getBoundingClientRect();
      if (r.top < b.top) popupBody.scrollTop -= b.top - r.top + 8;
      else if (r.bottom > b.bottom) popupBody.scrollTop += r.bottom - b.bottom + 8;
    }
    $("#popup-x").addEventListener("click", closePopup);
    veil.addEventListener("click", (e) => {
      const c = clickableAt(e.clientX, e.clientY);
      if (c) c.open();   // 外の別の箱を押した: 閉じずに、その箱の中身に替える
      else closePopup();
    });
    document.addEventListener("keydown", (e) => {
      if (!isOpen() || e.defaultPrevented) return;
      if (e.key === "Escape") { e.preventDefault(); closePopup(); return; }
      const at = document.activeElement;
      if (e.key === "Tab") {
        const f = $$("button, a[href]", popup), first = f[0], last = f[f.length - 1], out = !popup.contains(at);
        const to = e.shiftKey ? (out || at === first || at === popupTitle ? last : null) : (out || at === last ? first : null);
        if (!to) return;
        e.preventDefault();
        to.focus({ preventScroll: true });
        keepIn(to);
        return;
      }
      const pageH = popupBody.clientHeight * 0.9;
      const dy = { ArrowDown: 40, ArrowUp: -40, PageDown: pageH, PageUp: -pageH, End: 1e9, Home: -1e9, " ": e.shiftKey ? -pageH : pageH }[e.key];
      if (dy === undefined || popupBody.contains(at) || (e.key === " " && at.matches("button, a[href]"))) return;
      e.preventDefault();
      popupBody.scrollTop += dy;
    });
    const replace = () => { if (isOpen() && !raf) raf = requestAnimationFrame(() => { raf = 0; if (isOpen()) place(); }); };
    addEventListener("resize", replace);
    addEventListener("scroll", (e) => { if (!popup.contains(e.target)) replace(); }, true);
    narrow.addEventListener("change", replace);

    // ---- 図 ----
    const mounted = [];
    figures.forEach((fig, i) => {
      const root = document.querySelector(`.figure[data-fig="${i}"]`);
      if (root) mounted.push(mount(fig, root));
    });

    function mount(fig, root) {
      const cols = orderColumns(fig);
      const lay = layout(fig, cols);
      const views = fig.views;
      const byId = new Map(views.map((v) => [v.id, v]));
      const hostViews = views.filter((v) => v.kind === "host");
      const withDots = fig.order === "count" && hostViews.length >= 2;
      const regionOf = new Map(fig.regions.map((r) => [r.id, r]));
      const markText = (marks) => {
        const r = fig.regions.find((x) => x.mark === marks);
        if (r) return `${r.mark} ${r.label}`;
        return `${marks} (${[...marks].map((m) => (fig.regions.find((x) => x.mark === m) || {}).label).filter(Boolean).join(" と ")} の両方の段が on のとき既定で入る)`;
      };
      const onoff = (b) => (b ? "on" : "off");
      const stateOf = (v, key) => {
        const s = v.tools[key];
        if (!s) return "off";
        return s.e ? "on" : s.v ? "na" : "off";
      };
      const valueText = (v, key) => {
        const s = v.tools[key];
        if (!s) return "—";
        if (s.e) return "on (入る)";
        if (s.v) return `on だが効かない (${(s.off && s.off.length ? s.off : ["効く条件"]).join("・")} が off)`;
        return "off";
      };
      const srcShort = (s) => (s === "host" ? "ホスト" : s === "shared" ? "shared/" : "");
      let cur = -1, timer = null;

      // 操作の部品: タブと ▶
      const controls = el("div", "controls");
      const tablist = el("div", "tabs");
      tablist.setAttribute("role", "tablist");
      tablist.setAttribute("aria-label", fig.title ? `${fig.title}の図で見せるもの` : "図で見せるもの");
      const swatch = (v) => {
        const s = el("span", v.kind === "overlay" ? "sw multi" : "sw");
        if (v.kind !== "overlay") s.style.setProperty("--c", colorOf(v));
        s.setAttribute("aria-hidden", "true");
        return s;
      };
      const tabs = views.map((v) => {
        const b = el("button");
        b.type = "button";
        b.id = `${fig.id}-tab-${v.id}`;
        b.setAttribute("role", "tab");
        b.setAttribute("aria-controls", `${fig.id}-view`);
        b.setAttribute("aria-selected", "false");
        b.tabIndex = -1;
        b.append(swatch(v), el("span", null, v.label));
        tablist.append(b);
        return b;
      });
      const play = el("button", "play", "▶ 順に見る");
      play.type = "button";
      controls.append(tablist);
      if (views.length > 1) controls.append(play);   // タブが 1 つなら順に見るものが無い
      const legend = el("div", "legend");
      const view = el("div", "view");
      view.id = `${fig.id}-view`;
      view.setAttribute("role", "tabpanel");
      const figbox = el("div", "figbox");
      figbox.setAttribute("role", "region");
      figbox.setAttribute("aria-label", "道具の図 (横に送れる)");
      figbox.tabIndex = 0;
      const panel = el("div", "panel");
      panel.setAttribute("aria-live", "polite");

      // SVG
      const svg = sv("svg", {
        class: "map",
        viewBox: `0 0 ${lay.W} ${lay.H}`,
        role: "group",
        "aria-label": "道具の図: 灰色の入れ子の領域が段、箱が道具、色の線の中がそのホストで入る道具 (箱や段の名前を押すと詳細が出る)",
      });
      svg.style.maxWidth = `${Math.round(lay.W * 1.25)}px`;
      const defs = sv("defs");
      svg.append(defs);
      const regionEls = new Map(), regionLabels = new Map();
      [...lay.regions].reverse().forEach((r) => {
        const g = sv("g", { class: `rg rg-l${r.level}` });
        g.append(sv("rect", { x: r.x, y: r.y, width: r.w, height: r.h, rx: 16 }));
        svg.append(g);
        regionEls.set(r.id, g);
      });
      for (const h of lay.heads) {
        const t = sv("text", { class: "col-head", x: h.x, y: h.y });
        t.textContent = h.text;
        svg.append(t);
      }
      const olLayer = sv("g", { class: "outlines" });
      svg.append(olLayer);
      lay.regions.forEach((r) => {
        const g = sv("g", { class: "rg-btn", role: "button", tabindex: 0, "aria-haspopup": "dialog" });
        const text = `${r.mark} ${r.label}`;
        const w = textWidth(`${text} · off`, 13) + 12;
        g.append(sv("rect", { class: "rg-hit", x: r.labelX - 6, y: r.labelY - 15, width: w, height: 21, rx: 5 }));
        const t = sv("text", { class: "rg-label", x: r.labelX, y: r.labelY });
        t.textContent = text;
        g.append(t);
        svg.append(g);
        regionLabels.set(r.id, { g, t, text });
        const open = () => { stopAuto(); openPopup(regionCard(r.id), g); };
        g.addEventListener("click", open);
        g.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(); } });
        clickables.push({ el: g, box: figbox, open });
      });
      const boxEls = new Map();
      const boxLayer = sv("g", { class: "boxes" });
      for (const b of lay.boxes) {
        const meta = fig.tools[b.key];
        const outer = sv("g", { transform: `translate(${b.x} ${b.y})` });
        const g = sv("g", { class: "part node", role: "button", tabindex: 0, "aria-haspopup": "dialog", "data-key": b.key });
        g.append(sv("rect", { width: L.bw, height: L.bh, rx: L.rx }));
        const name = sv("text", { class: "name", x: 10, y: 18 });
        fitText(name, meta.short, L.bw - 30);
        const v = sv("text", { class: "v", x: 10, y: 34 });
        g.append(name, v, sv("circle", { class: "flag", cx: L.bw - 10, cy: 10, r: 3.6 }));
        const dots = [];
        if (withDots) {
          hostViews.forEach((hv, j) => {
            const c = sv("circle", { class: "dot", cx: L.bw - 10 - (hostViews.length - 1 - j) * 8, cy: 30.5, r: 3 });
            c.style.setProperty("--c", colorOf(hv));
            g.append(c);
            dots.push({ c, id: hv.id });
          });
        }
        outer.append(g);
        boxLayer.append(outer);
        boxEls.set(b.key, { g, v, dots, meta });
        const open = () => { stopAuto(); openPopup(boxCard(b.key), g); };
        g.addEventListener("click", open);
        g.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(); } });
        clickables.push({ el: g, box: figbox, open });
      }
      svg.append(boxLayer);

      // タブごとの囲みの線 (タブを替えると、そのタブの線の組だけを見せる)
      const olSets = views.map((tab) => {
        const members = tab.kind === "overlay" ? tab.members.map((id) => byId.get(id)) : [tab];
        const set = sv("g", { class: "part hide olset" });
        members.forEach((m, k) => {
          const { d, t } = outlineSpec(members.length, k);
          const rects = unionRects(lay, (key) => onIn(m, key), d, t);
          const id = `${fig.id}-m-${tab.id}-${k}`;
          const mask = sv("mask", { id, maskUnits: "userSpaceOnUse", x: 0, y: 0, width: lay.W, height: lay.H });
          mask.append(sv("rect", { x: 0, y: 0, width: lay.W, height: lay.H, fill: "#fff" }));
          const g = sv("g", { mask: `url(#${id})`, class: "olg", "data-view": m.id });
          g.style.setProperty("--c", colorOf(m));
          for (const r of rects) {
            mask.append(sv("rect", { x: r.x, y: r.y, width: r.w, height: r.h, rx: r.r, fill: "#000" }));
            g.append(sv("rect", { class: "ol-r", x: r.x, y: r.y, width: r.w, height: r.h, rx: r.r, "stroke-width": 2 * t }));
          }
          defs.append(mask);
          set.append(g);
        });
        olLayer.append(set);
        return set;
      });

      figbox.append(svg);
      view.append(figbox, panel);
      root.append(controls, legend, view);

      // ---- 箱・段の詳細 ----
      function boxCard(key) {
        const meta = fig.tools[key], tab = views[cur], rows = [];
        rows.push({ k: "段", v: markText(meta.marks) });
        if (tab.kind === "overlay") {
          for (const id of tab.members) {
            const m = byId.get(id), s = m.tools[key];
            rows.push({ k: m.label, v: m.kind === "host" && s ? `${valueText(m, key)} · ${s.t}` : valueText(m, key) });
          }
        } else {
          const s = tab.tools[key];
          rows.push({ k: "値", v: valueText(tab, key) });
          rows.push({ k: "どこで決まったか", v: s.t });
          if (tab.kind === "host") {
            rows.push({ k: "書かなかったら", v: `${onoff(s.d)} (${fig.kind === "win" ? "グループの既定" : "option の既定"})` });
          }
        }
        rows.push({ k: fig.kind === "win" ? "ホストの値のキー" : "option", v: meta.option, code: true });
        if (meta.requires.length) rows.push({ k: "効く条件", v: `${meta.requires.join("・")} が on` });
        return { title: meta.label, rows };
      }
      function tierRow(v, rid) {
        const s = v.tiers && v.tiers[rid];
        return s ? `${onoff(s.value)} (${s.text})` : "—";
      }
      function regionCard(rid) {
        const r = regionOf.get(rid), tab = views[cur], rows = [];
        if (tab.kind === "overlay") {
          for (const id of tab.members) { const m = byId.get(id); rows.push({ k: m.label, v: tierRow(m, rid) }); }
        } else {
          rows.push({ k: "値", v: tierRow(tab, rid) });
          rows.push({ k: "グループ", v: `${tab.group.value} (${tab.group.text})` });
        }
        const opt = (views.find((v) => v.tiers && v.tiers[rid]) || { tiers: {} }).tiers[rid];
        if (opt && opt.option) rows.push({ k: "option", v: `dotfiles.${opt.option}`, code: true });
        const note = rid === fig.regions[0].id
          ? "どのグループでも入る段 (段の switch は無い)。道具はホストで 1 つずつ入れる"
          : fig.kind === "win"
            ? "段はグループで決まる (Windows のホストの値には段の switch が無い)。道具の既定はグループの既定 (groups.json)"
            : "段の switch は、この段の道具の switch の既定になる (道具はホストで 1 つずつ足し引きできる)";
        return { title: `${r.mark} ${r.label}`, rows, note };
      }

      // ---- タブを替える ----
      function look(tab, key) {
        if (tab.kind === "overlay") return null;
        const s = tab.tools[key];
        return `${stateOf(tab, key)}|${s && (s.s === "host" || s.s === "shared") ? s.s : ""}`;
      }
      function restartPulse(g) { g.classList.remove("changed"); void g.getBoundingClientRect(); g.classList.add("changed"); }
      function paintBox(key, tab) {
        const { g, v, dots, meta } = boxEls.get(key);
        let st, flag = "", text;
        if (tab.kind === "overlay") {
          const ms = tab.members.map((id) => byId.get(id));
          if (fig.order === "host") {
            const [h, d] = ms;
            st = stateOf(h, key);
            const s = h.tools[key];
            flag = s && (s.s === "host" || s.s === "shared") ? s.s : "";
            const hOn = onIn(h, key), dOn = onIn(d, key);
            text = { on: "on", off: "off", na: "– 効かない" }[st] + (hOn && !dOn ? " · 足した" : !hOn && dOn ? " · 外した" : "");
          } else {
            const n = ms.filter((m) => onIn(m, key)).length;
            st = "mix";
            text = `${n}/${ms.length} 台`;
          }
        } else {
          st = stateOf(tab, key);
          const s = tab.tools[key];
          flag = s && (s.s === "host" || s.s === "shared") ? s.s : "";
          // 入口の図 (箱の右下に点の列がある) では字を短くし、ホストで決めた値は右上の ● だけで見せる
          const tag = tab.kind === "host" && !withDots ? srcShort(s && s.s) : "";
          text = { on: "on", off: "off", na: "– 効かない" }[st] + (tag ? ` · ${tag}` : "");
        }
        g.classList.remove("st-on", "st-off", "st-na", "st-mix", "set", "sh");
        g.classList.add(`st-${st}`);
        if (flag === "host") g.classList.add("set");
        if (flag === "shared") g.classList.add("sh");
        v.textContent = text;
        for (const { c, id } of dots) {
          const m = byId.get(id);
          c.classList.remove("on", "na", "cur");
          const s2 = stateOf(m, key);
          if (s2 === "on") c.classList.add("on");
          if (s2 === "na") c.classList.add("na");
          if (tab.id === id) c.classList.add("cur");
        }
        const label = tab.kind === "overlay" && fig.order !== "host" ? text : valueText(tab.kind === "overlay" ? byId.get(tab.members[0]) : tab, key);
        g.setAttribute("aria-label", `${meta.label}: ${label}`);
      }
      function paintRegions(tab) {
        const src = tab.kind === "overlay" ? (fig.order === "host" ? byId.get(tab.members[0]) : null) : tab;
        for (const r of fig.regions) {
          const s = src && src.tiers ? src.tiers[r.id] : null;
          const off = !!(s && !s.value);
          regionEls.get(r.id).classList.toggle("rg-off", off);
          const { t, text, g } = regionLabels.get(r.id);
          t.textContent = off ? `${text} · off` : text;
          g.setAttribute("aria-label", `${text}${s ? `: ${s.value ? "on" : "off"}` : ""}`);
        }
      }
      function paintLegend(tab) {
        const items = [];
        const lineItem = (v) => {
          const s = el("span");
          s.append(swatch(v), document.createTextNode(`${v.label}`));
          return s;
        };
        // 重ねるタブで線が多いときは、ホストの名前をタブ (色つき) に任せて並べ直さない
        if (tab.kind === "overlay" && tab.members.length > 3) {
          items.push(el("span", null, "タブの色の線の中が、そのホストで入る道具 (タブにのせると、そのホストの線だけが濃くなる)"));
        } else {
          if (tab.kind === "overlay") tab.members.forEach((id) => items.push(lineItem(byId.get(id))));
          else items.push(lineItem(tab));
          items.push(el("span", null, tab.kind === "overlay" ? "(線の中が入る道具)" : "の線の中が入る道具"));
        }
        const box = (cls, t) => { const s = el("span"); s.append(el("i", `lg-box ${cls}`), document.createTextNode(t)); return s; };
        items.push(box("", "on"), box("off", "off"), box("na", "効かない (–)"));
        const flagItem = (cls, t) => { const s = el("span"); s.append(el("i", `lg-flag ${cls}`), document.createTextNode(t)); return s; };
        items.push(flagItem("", fig.kind === "win" ? "ホストの値で決めた" : "ホストで決めた"));
        if (fig.kind !== "win") items.push(flagItem("sh", "nix/shared/ で決めた"));
        legend.replaceChildren(...items);
      }
      function show(i) {
        const tab = views[i], prev = views[cur];
        for (const key of boxEls.keys()) {
          const now = look(tab, key), was = prev ? look(prev, key) : now;
          paintBox(key, tab);
          const { g } = boxEls.get(key);
          g.classList.remove("changed");
          if (prev && now !== null && was !== null && now !== was) restartPulse(g);
        }
        paintRegions(tab);
        olSets.forEach((g, j) => {
          g.classList.toggle("hide", j !== i);
          g.setAttribute("aria-hidden", String(j !== i));
          g.classList.remove("dim");   // 前のタブでのせた強調を残さない
          g.querySelectorAll(".olg.hi").forEach((x) => x.classList.remove("hi"));
        });
        tabs.forEach((b, j) => { b.setAttribute("aria-selected", String(j === i)); b.tabIndex = j === i ? 0 : -1; });
        view.setAttribute("aria-labelledby", tabs[i].id);
        const box = el("div", "fade");
        const ul = el("ul");
        (tab.note || []).forEach((s) => ul.append(el("li", null, s)));
        box.append(el("h3", null, tab.label), ul);
        panel.replaceChildren(box);
        paintLegend(tab);
        if (cur !== -1) { try { history.replaceState(null, "", `#view-${fig.id}-${tab.id}`); } catch (e) { /* 埋め込み先では使えないことがある */ } }
        cur = i;
        if (isOpen() && popupAt && root.contains(popupAt)) {
          // 開いたまま替えたら、同じ箱の中身を今のタブで出し直す
          const key = popupAt.getAttribute("data-key");
          if (key) openPopup(boxCard(key), popupAt);
        }
      }
      function stopAuto() {
        if (!timer) return;
        clearInterval(timer); timer = null;
        play.classList.remove("on"); play.textContent = "▶ 順に見る";
      }
      play.addEventListener("click", () => {
        if (timer) return stopAuto();
        play.classList.add("on"); play.textContent = "■ 止める";
        const next = () => show((cur + 1) % views.length);
        next(); timer = setInterval(next, 4500);
      });
      document.addEventListener("visibilitychange", () => { if (document.hidden) stopAuto(); });
      // 重ねるタブを見ている間、ホストのタブにのせる (フォーカスする) と、そのホストの線だけを濃くする
      // 強調は今のタブの線の組にだけ付け、ほかのタブの組からは外す (タブを移ったあとに強調が残らないように)
      const hilite = (id) => {
        olSets.forEach((set, j) => {
          const has = !!id && j === cur && views[j].kind === "overlay" && views[j].members.includes(id);
          set.classList.toggle("dim", has);
          set.querySelectorAll(".olg").forEach((g) => g.classList.toggle("hi", has && g.getAttribute("data-view") === id));
        });
      };
      tabs.forEach((b, i) => {
        b.addEventListener("mouseenter", () => hilite(views[i].id));
        b.addEventListener("mouseleave", () => hilite(null));
        b.addEventListener("focus", () => hilite(views[i].id));
        b.addEventListener("blur", () => hilite(null));
        b.addEventListener("click", () => { stopAuto(); hilite(null); show(i); });
        b.addEventListener("keydown", (e) => {
          const to = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
          if (to === undefined) return;
          e.preventDefault(); stopAuto();
          const j = (to + tabs.length) % tabs.length;
          show(j); tabs[j].focus();
        });
      });

      // 開いた時点の状態: #view-<図>-<タブ> ならそのタブ、ほかは 1 つめのタブ
      const want = views.findIndex((v) => location.hash === `#view-${fig.id}-${v.id}`);
      show(want >= 0 ? want : 0);
      return { fig, boxEls, regionLabels, boxCard, regionCard, root };
    }

    // #pop-<図>-<道具の key> (段は #pop-<図>-r-<段>) なら、その箱のポップアップを開いた状態から始める (撮って確かめる口)
    const pop = location.hash.match(/^#pop-([^-]+)-(.+)$/);
    nextFrame(() => {
      document.body.classList.add("ready");
      if (!pop) return;
      const m = mounted.find((x) => x.fig.id === pop[1]);
      if (!m) return;
      if (pop[2].startsWith("r-")) {
        const r = m.regionLabels.get(pop[2].slice(2));
        if (r) openPopup(m.regionCard(pop[2].slice(2)), r.g);
      } else {
        const b = m.boxEls.get(pop[2]);
        if (b) openPopup(m.boxCard(pop[2]), b.g);
      }
    });
  }

  return { L, orderColumns, layout, unionRects, components, outlineSpec, boot };
})();

if (typeof module !== "undefined" && module.exports) module.exports = HostMap;
else HostMap.boot();
