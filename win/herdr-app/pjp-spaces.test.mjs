// pjp-spaces (herdr-app の mod。隣の mods/pjp-spaces/) の印の計算と描き方を、herdr-app の外 (node) で確かめる。
//
//   node --test win/herdr-app/pjp-spaces.test.mjs
//
// CI の workflow pjp-spaces が流す。main.js は gpui-kit・gpui-base・herdr を import するので、一時ディレクトリの node_modules に
// 偽物を置き、main.js を写した main.mjs を読む。偽の要素は呼ばれた builder を控えるだけで、見た目 (並び・色・幅) は herdr-app で
// 確かめる (skill pjp-hc-hub の references/spaces.md の「確かめ方」)。

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const modDir = join(here, "mods", "pjp-spaces");

// 偽の要素: builder の呼び出しを控え、child・children を子として持つ。when は元と同じく、条件が真なら関数に自分を渡す
const FAKE_UI = `
const NODE = Symbol.for("pjp-spaces.fake-node");
export function el(kind, arg) {
  const node = { kind, arg, calls: [], kids: [], props: {} };
  const proxy = new Proxy(node, {
    get(target, prop) {
      if (prop === NODE) return target;
      if (typeof prop === "symbol" || prop === "then") return undefined;
      return (...args) => {
        target.calls.push([prop, ...args]);
        if (prop === "when") return args[0] ? args[1](proxy) : proxy;
        if (prop === "child") target.kids.push(args[0]);
        else if (prop === "children") target.kids.push(...(args[0] ?? []));
        else target.props[prop] = args.length <= 1 ? args[0] : args;
        return proxy;
      };
    },
  });
  return proxy;
}
`;

const FAKE_HERDR = `
const S = () => globalThis.__herdr;
export const spaces = () => S().spaces;
export const machines = () => S().machines ?? [];
export const panes = () => S().panes ?? [];
export const terminals = () => S().terminals ?? [];
export const run = (name, args) => { S().ran.push([name, args]); return null; };
export const openOverlay = () => "overlay";
export const exec = async () => ({ code: 1, stdout: "", stderr: "" });
export const hc = async () => ({ code: 1, stdout: "", stderr: "" });
export const theme = () => new Proxy({}, { get: (_t, k) => (typeof k === "string" ? "#" + k : undefined) });
export const shared = (k) => S().shared[k];
export const setShared = (k, v) => { S().shared[k] = v; return null; };
// 0.1.16 から watchFolder は cancel() を持つ Promise を返す
export const watchFolder = () => Object.assign(new Promise(() => {}), { cancel() {} });
export const window = () => ({ active: true });
export const layout = () => S().layout;
export const props = () => S().props ?? {};
`;

let work;
let mod;

before(async () => {
  work = mkdtempSync(join(tmpdir(), "pjp-spaces-test-"));
  const pkg = (name, body) => {
    const dir = join(work, "node_modules", name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "package.json"), JSON.stringify({ name, type: "module", main: "index.js" }));
    writeFileSync(join(dir, "index.js"), body);
  };
  pkg("fake-ui", FAKE_UI);
  pkg("gpui-kit", `import { el } from "fake-ui"; export class View {} export const div = () => el("div"); export const svg = (p) => el("svg", p); export const image = (p) => el("image", p);`);
  // ScrollHandle (herdr-app 0.1.16 の spaces が一覧のスクロールに使う) は、scroll_to_item に渡された位置を控える
  pkg(
    "gpui-base",
    `import { el } from "fake-ui"; export const v_flex = () => el("v_flex"); export const h_flex = () => el("h_flex");
export const ScrollHandle = { new: () => { const items = []; return { items, scroll_to_item: (i) => { items.push(i); } }; } };`,
  );
  pkg("herdr", FAKE_HERDR);
  copyFileSync(join(modDir, "main.js"), join(work, "main.mjs"));
  const store = new Map();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    writable: true,
    value: {
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => store.set(k, String(v)),
      removeItem: (k) => store.delete(k),
    },
  });
  mod = await import(pathToFileURL(join(work, "main.mjs")).href);
});

after(() => {
  if (work) rmSync(work, { recursive: true, force: true });
});

// ---- 場面の部品 ----------------------------------------------------------------------------------------------------

// space。remote なら id と tab の id の頭に <machine>/ が付く (herdr.d.ts の SpaceInfo)
function space(id, name, { machine = null, tabs = 1 } = {}) {
  const q = (s) => (machine ? `${machine}/${s}` : s);
  return {
    id: q(id),
    name,
    machine,
    index: 1,
    named: true,
    folder: "",
    branch: null,
    active: false,
    status: null,
    tabs: Array.from({ length: tabs }, (_, i) => ({ id: q(`${id}-tab${i + 1}`), index: i + 1 })),
  };
}

// terminals() の 1 件。space と tab は label に書く、そのマシンの中の id (頭に <machine>/ を付けない)
function term(address, { space: sp, tab = 1, parent = null, role, ticket, letter, finished, asking, videos, status = "idle", records, state = "live", name } = {}) {
  const labels = {};
  if (sp) {
    labels["herdr.space"] = sp;
    labels["herdr.tab"] = `${sp}-tab${tab}`;
  }
  if (role) labels["pjp.role"] = role;
  if (ticket) labels["pjp.ticket"] = ticket;
  if (letter) labels["pjp.letter"] = letter;
  if (finished) labels["pjp.finished"] = finished;
  if (asking !== undefined) labels["pjp.asking"] = asking;
  Object.assign(labels, videos ?? {});
  return { address, parent, state, status, name, records, labels };
}

// 解説動画の印の label の値 (pjp mark video と同じ 1 行の JSON)
function video(name, state, started, { ended, from } = {}) {
  const v = { name, state, started };
  if (ended) v.ended = ended;
  if (from) v.from = from;
  return JSON.stringify(v);
}

const SUBAGENT = { a1: { app: "claude-code", state: "working", title: "裏の調べもの" } };

// 11/17 の Windows に似せた場面: ハブの space h に会話 t1m と素の端末、wsl1 に子 K・L の space、ほかに素の space
function today({ kStatus = "working", lStatus = "done", lRecords } = {}) {
  return {
    spaces: [space("sph", "h", { tabs: 2 }), space("spk", "K dotfiles: panel の問い", { machine: "wsl1" }), space("spl", "L claude-skills: 手順", { machine: "wsl1" }), space("spx", "~")],
    terminals: [
      term("t1m", { space: "sph", role: "hub", ticket: "ABC-681", status: "working" }),
      term("t1n", { space: "sph", tab: 2, status: null }),
      term("wsl1/t31", { space: "spk", status: null }),
      term("wsl1/t32", { space: "spk", parent: "t1m", role: "child", letter: "K", ticket: "ABC-751", status: kStatus }),
      term("wsl1/t33", { space: "spl", status: null }),
      term("wsl1/t34", { space: "spl", parent: "t1m", role: "child", letter: "L", ticket: "ABC-750", status: lStatus, records: lRecords }),
      term("t9", { space: "spx", status: null }),
    ],
    panes: [],
  };
}

const marksOf = (w) => mod.spaceMarks(w.terminals, w.spaces, w.panes);
const textOf = (w, id) => marksOf(w).get(id)?.text;

// ---- 印の計算 (spaceMarks) ------------------------------------------------------------------------------------------

test("ハブの space に 🌳[子の数] と動いている子の 🔄、子の space に 🌱 と ↑ 親のチケットが出る", () => {
  const w = today();
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]🔄");
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱 ↑ ABC-681");
  assert.equal(textOf(w, "wsl1/spl"), "wsl1/t34 🌱 ↑ ABC-681");
});

test("会話の端末がいない space は印の表に入らない (行は元の 1 行のまま)", () => {
  const m = marksOf(today());
  assert.equal(m.has("spx"), false);
  assert.deepEqual([...m.keys()].sort(), ["sph", "wsl1/spk", "wsl1/spl"]);
});

test("ほかのマシンの端末は label の space に <machine>/ を足して space の id と比べる", () => {
  const w = today();
  w.terminals = w.terminals.map((x) => (x.address === "wsl1/t32" ? { ...x, labels: { ...x.labels, "herdr.space": "wsl1/spk", "herdr.tab": "wsl1/spk-tab1" } } : x));
  // 頭に付いていても二重にしない
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱 ↑ ABC-681");
});

test("子が誰も動いていなければ 🔄 は出ない", () => {
  assert.equal(textOf(today({ kStatus: "idle", lStatus: "done" }), "sph"), "t1m 🌳[2]");
});

test("blocked の子は 🔄 に数えない (旧 herdr と同じく working だけ)", () => {
  assert.equal(textOf(today({ kStatus: "blocked", lStatus: "idle" }), "sph"), "t1m 🌳[2]");
});

test("動いている subagent があれば 👀、子孫の 👀 は上の親にも出る", () => {
  const w = today({ kStatus: "idle", lStatus: "done", lRecords: SUBAGENT });
  assert.equal(textOf(w, "wsl1/spl"), "wsl1/t34 🌱👀 ↑ ABC-681");
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]👀");
});

test("会話の状態を問わず、subagent が動いていれば 👀 (subagent が動く間は、ターンを終えても status が working のまま)", () => {
  for (const s of ["working", "blocked", "error", "idle", "done", null]) {
    // blocked・error は ❓ も出る (印の先頭。下の ❓ の test)
    const ask = s === "blocked" || s === "error" ? mod.MARKS.ask : "";
    assert.equal(textOf(today({ kStatus: "idle", lStatus: s, lRecords: SUBAGENT }), "wsl1/spl"), `wsl1/t34 ${ask}🌱👀 ↑ ABC-681`, String(s));
  }
  // ハブにも伝わり、working の子の 🔄 と並ぶ
  assert.equal(textOf(today({ kStatus: "idle", lStatus: "working", lRecords: SUBAGENT }), "sph"), "t1m 🌳[2]🔄👀");
});

test("自分で立てた手伝いの端末 (pjp.role なし) が working なら 👀、ハブにも伝わる", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals.push(term("wsl1/t80", { parent: "wsl1/t32", status: "working", name: "helper" }));
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱👀 ↑ ABC-681");
  // 手伝いの端末は子ではないので、K に 🌳 は付かず、ハブの 🔄 にも数えない
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]👀");
  assert.match(marksOf(w).get("wsl1/spk").tip, /裏の作業が動いている \(手伝いの端末 1\)/);
  // 手伝いが止まれば消える
  w.terminals.at(-1).status = "idle";
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱 ↑ ABC-681");
});

test("ハブ自身の手伝いの端末も、ハブの状態を問わず 👀", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals.push(term("t60", { parent: "t1m", status: "working" }));
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]👀");
  w.terminals[0].status = "done";
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]👀");
});

test("pjp.role の無い親 (pjp mark name より先に子を立てた会話) の space にも印を出す", () => {
  const w = today();
  delete w.terminals[0].labels["pjp.role"];
  delete w.terminals[0].labels["pjp.ticket"];
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]🔄");
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱 ↑ h");
});

test("会話の並びは tab の順、同じ tab なら作った順 (hc の address は 36 進なので t9 < ta < t10)", () => {
  const two = (a, b, tabA, tabB) => ({
    spaces: [space("sph", "h", { tabs: 2 })],
    terminals: [
      term(a, { space: "sph", tab: tabA, role: "hub", ticket: "ABC-1", finished: "x" }),
      term(b, { space: "sph", tab: tabB, role: "hub", ticket: "ABC-2", finished: "x" }),
    ],
    panes: [],
  });
  assert.equal(textOf(two("t2a", "t1q", 1, 2), "sph"), "t2a ABC-1 🗑️ │ t1q ABC-2 🗑️");
  assert.equal(textOf(two("t2a", "t1q", 2, 1), "sph"), "t1q ABC-2 🗑️ │ t2a ABC-1 🗑️");
  assert.equal(textOf(two("t10", "t9", 1, 1), "sph"), "t9 ABC-2 🗑️ │ t10 ABC-1 🗑️");
  assert.equal(textOf(two("t10", "ta", 1, 1), "sph"), "ta ABC-2 🗑️ │ t10 ABC-1 🗑️");
});

test("records が配列でも、記録が working でなければ 👀 にしない", () => {
  assert.equal(textOf(today({ lStatus: "idle", lRecords: [{ state: "working" }] }), "wsl1/spl"), "wsl1/t34 🌱👀 ↑ ABC-681");
  assert.equal(textOf(today({ lStatus: "idle", lRecords: { a: { state: "idle" } } }), "wsl1/spl"), "wsl1/t34 🌱 ↑ ABC-681");
});

test("孫が動いていれば、子が止まっていてもハブに 🔄 が出る", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.spaces.push(space("spg", "A nixos-config: 孫", { machine: "wsl1" }));
  w.terminals.push(term("wsl1/t40", { space: "spg", parent: "wsl1/t32", role: "child", letter: "A", status: "working" }));
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]🔄");
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱🌳[1]🔄 ↑ ABC-681");
  assert.equal(textOf(w, "wsl1/spg"), "wsl1/t40 🌱 ↑ ABC-751");
});

test("済んだ会話は、子が 0 人で止まっていれば 🗑️", () => {
  const fin = (status, records) => ({
    spaces: [space("spw", "ABC-742 panel の直し")],
    terminals: [term("t2a", { space: "spw", role: "hub", ticket: "ABC-742", finished: "2026-11-17T23:10+09:00", status, records })],
    panes: [],
  });
  assert.equal(textOf(fin("idle"), "spw"), "t2a 🗑\uFE0F");
  assert.equal(textOf(fin("done"), "spw"), "t2a 🗑\uFE0F");
  assert.equal(textOf(fin(null), "spw"), "t2a 🗑\uFE0F"); // claude が終わって shell に戻った端末
  assert.equal(textOf(fin("working"), "spw"), "t2a");
  // 確認の画面・エラーで止まっている会話は ❓ だけ (🗑️ と同時に出さない)
  assert.equal(textOf(fin("blocked"), "spw"), "t2a ❓");
  assert.equal(textOf(fin("error"), "spw"), "t2a ❓");
  assert.equal(textOf(fin("idle", SUBAGENT), "spw"), "t2a 👀");
});

test("済んだ会話でも、文の問い (pjp.asking) を出している間は 🗑️ でなく ❓", () => {
  const w = {
    spaces: [space("spw", "ABC-742 panel の直し")],
    terminals: [term("t2a", { space: "spw", role: "hub", ticket: "ABC-742", finished: "2026-11-17T23:10+09:00", asking: "worktree を消してよいか", status: "done" })],
    panes: [],
  };
  assert.equal(textOf(w, "spw"), "t2a ❓");
  // 答えが届いて外すと 🗑️ に戻る
  delete w.terminals[0].labels["pjp.asking"];
  assert.equal(textOf(w, "spw"), "t2a 🗑️");
});

test("済んだ会話でも、生きている子がいれば 🗑️ を出さない", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[0].labels["pjp.finished"] = "2026-11-17T23:10+09:00";
  w.terminals[0].status = "idle";
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]");
});

test("終わった子 (state が finished) と pjp.role の無い sub-agent は 🌳[N] に数えない", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals.push(term("wsl1/t50", { parent: "t1m", role: "child", letter: "C", state: "finished" }));
  // 止まっている手伝いの端末 (working なら 👀 になる。上の手伝いの端末の test)
  w.terminals.push(term("t60", { parent: "t1m", status: "idle" }));
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]");
});

test("1 つの space に会話が 2 つあれば、会話ごとに address の後ろへ名札を付けて区切る", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  // ハブの space h の tab 2 に、別の会話 と、その子 (wsl1 の space) を足す
  w.terminals.push(term("t1q", { space: "sph", tab: 2, role: "hub", ticket: "ABC-742", status: "idle" }));
  w.spaces.push(space("spm", "A dotfiles: 別の子", { machine: "wsl1" }));
  w.terminals.push(term("wsl1/t70", { space: "spm", parent: "t1q", role: "child", letter: "A", status: "working" }));
  assert.equal(textOf(w, "sph"), "t1m ABC-681 🌳[2] │ t1q ABC-742 🌳[1]🔄");
  assert.equal(textOf(w, "wsl1/spm"), "wsl1/t70 🌱 ↑ ABC-742");
  assert.equal(marksOf(w).get("sph").count, 2);
});

test("印の無い会話も address と名札を出す (address は印の有無を問わず出す)", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals.push(term("t1q", { space: "sph", tab: 2, role: "hub", ticket: "ABC-742", status: "idle" }));
  assert.equal(textOf(w, "sph"), "t1m ABC-681 🌳[2] │ t1q ABC-742");
});

test("会話が 1 つなら名札は付けない (address と印だけ)。印の無い会話の space も address は出す", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]");
  const alone = { spaces: [space("spz", "ABC-872 2 行目")], terminals: [term("t53", { space: "spz", role: "hub", ticket: "ABC-872" })], panes: [] };
  assert.equal(textOf(alone, "spz"), "t53");
});

test("名札は pjp.ticket・英字・名前の順。どれも無ければ address だけで、二重に出さない", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals.push(term("t1q", { space: "sph", tab: 2, role: "hub", letter: "B", status: "blocked" }));
  assert.equal(textOf(w, "sph"), "t1m ABC-681 🌳[2] │ t1q B ❓");
  w.terminals.at(-1).labels["pjp.letter"] = "";
  w.terminals.at(-1).name = "hub-2";
  assert.equal(textOf(w, "sph"), "t1m ABC-681 🌳[2] │ t1q hub-2 ❓");
  w.terminals.at(-1).name = undefined;
  assert.equal(textOf(w, "sph"), "t1m ABC-681 🌳[2] │ t1q ❓");
  // 名前が address と同じでも二重にしない
  w.terminals.at(-1).name = "t1q";
  assert.equal(textOf(w, "sph"), "t1m ABC-681 🌳[2] │ t1q ❓");
});

test("ほかのマシンの会話の address は <machine>/<ID> (hc send の <hc from=\"…\"> と同じ形)、このマシンの会話は素の ID", () => {
  const w = today();
  assert.ok(textOf(w, "wsl1/spk").startsWith("wsl1/t32 "));
  assert.ok(textOf(w, "sph").startsWith("t1m "));
});

test("チケットの無い親は、親の space の名前 (チケットの ID で始まれば ID だけ) を ↑ に出す", () => {
  const w = today();
  delete w.terminals[0].labels["pjp.ticket"];
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱 ↑ h");
  w.spaces[0].name = "ABC-799 会話の印";
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱 ↑ ABC-799");
});

test("親が terminals() にいなければ 🌱 だけ (↑ は出さない)", () => {
  const w = today();
  w.terminals = w.terminals.filter((x) => x.address !== "t1m");
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 🌱");
});

test("status が報告そのもの ({ state }) でも読む", () => {
  const w = today({ kStatus: { app: "claude-code", state: "working" }, lStatus: { state: "idle" } });
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]🔄");
});

test("label の無い会話の端末は、映っているペインから space を引く", () => {
  const w = today();
  const hub = w.terminals[0];
  delete hub.labels["herdr.space"];
  delete hub.labels["herdr.tab"];
  assert.equal(marksOf(w).has("sph"), false);
  w.panes = [{ pane: "p1", terminal: "t1m", tab: "sph-tab1" }];
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]🔄");
});

test("親子が輪になっていても止まる", () => {
  const w = {
    spaces: [space("spa", "a"), space("spb", "b")],
    terminals: [
      term("ta", { space: "spa", parent: "tb", role: "child", letter: "A", status: "idle" }),
      term("tb", { space: "spb", parent: "ta", role: "child", letter: "B", status: "idle" }),
    ],
    panes: [],
  };
  assert.equal(textOf(w, "spa"), "ta 🌱🌳[1] ↑ b");
});

test("ホバーの説明に、会話ごとの親・子の英字・動き・済んだを書く", () => {
  const w = today({ kStatus: "working", lStatus: "done", lRecords: SUBAGENT });
  const hub = marksOf(w).get("sph").tip;
  assert.match(hub, /^ABC-681 · t1m: /);
  assert.match(hub, /子 2 人 \(K L\)/);
  assert.match(hub, /動いている子孫がいる/);
  assert.match(hub, /裏の作業が動いている子孫がいる/);
  const child = marksOf(w).get("wsl1/spl").tip;
  assert.match(child, /^ABC-750 · wsl1\/t34 · 子 L: 親 ABC-681、裏の作業が動いている \(subagent 1\)$/);
});

// ---- ❓ (ユーザーの答え・対応を待っている会話) ------------------------------------------------------------------------

test("❓ の印は U+2753 の 1 字 (異体字セレクタを付けない。もとから絵文字で出る字)", () => {
  assert.equal(mod.MARKS.ask, "❓");
});

test("確認の画面 (blocked) か、エラーで止まっている (error) 会話は、印の先頭 (🌱 より前) に ❓", () => {
  for (const s of ["blocked", "error"]) {
    assert.equal(textOf(today({ kStatus: "idle", lStatus: s }), "wsl1/spl"), "wsl1/t34 ❓🌱 ↑ ABC-681", s);
    // 報告そのもの ({ state }) の形でも読む
    assert.equal(textOf(today({ kStatus: "idle", lStatus: { app: "claude-code", state: s } }), "wsl1/spl"), "wsl1/t34 ❓🌱 ↑ ABC-681", s);
  }
  // ハブなら 🌳[N]・🔄 の前
  const w = today();
  w.terminals[0].status = "blocked";
  assert.equal(textOf(w, "sph"), "t1m ❓🌳[2]🔄");
});

test("文の問い (pjp.asking) を出している会話は、status を問わず ❓", () => {
  for (const s of ["working", "blocked", "error", "idle", "done", null]) {
    const w = today({ kStatus: "idle", lStatus: "idle" });
    w.terminals[0].status = s;
    w.terminals[0].labels["pjp.asking"] = "案 A と B のどちらで進めるか";
    assert.equal(textOf(w, "sph"), "t1m ❓🌳[2]", String(s));
  }
});

test("done・idle・working・報告なしだけでは ❓ を出さない (文の問いも子の報告待ちも done で見分けられない)", () => {
  for (const s of ["done", "idle", "working", null, "unknown"]) {
    assert.equal(textOf(today({ kStatus: "idle", lStatus: s }), "wsl1/spl"), "wsl1/t34 🌱 ↑ ABC-681", String(s));
  }
});

test("pjp.asking が空白だけなら、無いのと同じ", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[0].status = "idle";
  w.terminals[0].labels["pjp.asking"] = " ";
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]");
});

test("❓ は親の行へ伝えない (子の行に出て、子の blocked・error は hc が親に知らせる)", () => {
  const w = today({ kStatus: "blocked", lStatus: "error" });
  w.terminals[0].status = "idle";
  assert.equal(textOf(w, "wsl1/spk"), "wsl1/t32 ❓🌱 ↑ ABC-681");
  assert.equal(textOf(w, "wsl1/spl"), "wsl1/t34 ❓🌱 ↑ ABC-681");
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]");
  // 子の文の問いも、孫の確認の画面も伝えない
  const v = today({ kStatus: "idle", lStatus: "idle" });
  v.terminals[0].status = "idle";
  v.terminals[3].labels["pjp.asking"] = "どちらにするか";
  v.spaces.push(space("spg", "A nixos-config: 孫", { machine: "wsl1" }));
  v.terminals.push(term("wsl1/t40", { space: "spg", parent: "wsl1/t34", role: "child", letter: "A", status: "blocked" }));
  assert.equal(textOf(v, "wsl1/spg"), "wsl1/t40 ❓🌱 ↑ ABC-750");
  assert.equal(textOf(v, "wsl1/spl"), "wsl1/t34 🌱🌳[1] ↑ ABC-681");
  assert.equal(textOf(v, "wsl1/spk"), "wsl1/t32 ❓🌱 ↑ ABC-681");
  assert.equal(textOf(v, "sph"), "t1m 🌳[2]");
});

test("❓ と 👀 が並ぶときも ❓ が先頭", () => {
  assert.equal(textOf(today({ kStatus: "idle", lStatus: "blocked", lRecords: SUBAGENT }), "wsl1/spl"), "wsl1/t34 ❓🌱👀 ↑ ABC-681");
});

test("会話が 2 つの space では、その会話の名札の後ろの印の先頭に ❓ (❓ だけの会話にも名札を付ける)", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[0].labels["pjp.asking"] = "PR #195 を merge してよいか";
  w.terminals.push(term("t1q", { space: "sph", tab: 2, role: "hub", ticket: "ABC-742", status: "blocked" }));
  assert.equal(textOf(w, "sph"), "t1m ABC-681 ❓🌳[2] │ t1q ABC-742 ❓");
  // ホバーは会話ごとの行に、それぞれ待っているもの
  assert.deepEqual(marksOf(w).get("sph").tip.split("\n"), [
    "ABC-681 · t1m: 待っている (問い: PR #195 を merge してよいか)、子 2 人 (K L)",
    "ABC-742 · t1q: 待っている (確認の画面)",
  ]);
});

test("pjp.asking だけでは会話にならない (pjp.role も子も無い端末の space は 1 行のまま)", () => {
  const w = today();
  w.terminals.push(term("t9q", { space: "spx", asking: "どちらにするか", status: "blocked" }));
  assert.equal(marksOf(w).has("spx"), false);
});

test("ホバーの問いの要旨は 60 字で切る (長い要旨で説明の行が伸びないように。印は ❓ のまま)", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[0].labels["pjp.asking"] = "あ".repeat(59) + "いうえ";
  assert.equal(textOf(w, "sph"), "t1m ❓🌳[2]");
  assert.match(marksOf(w).get("sph").tip, new RegExp(`待っている \\(問い: ${"あ".repeat(59)}い…\\)、`));
  // 60 字ちょうどは切らない
  w.terminals[0].labels["pjp.asking"] = "あ".repeat(60);
  assert.match(marksOf(w).get("sph").tip, new RegExp(`待っている \\(問い: ${"あ".repeat(60)}\\)、`));
});

test("ホバーの説明の先頭に、何を待っているか (確認の画面・エラーで止まっている・問い: <要旨>) を書く", () => {
  const blocked = marksOf(today({ kStatus: "idle", lStatus: "blocked" })).get("wsl1/spl").tip;
  assert.equal(blocked, "ABC-750 · wsl1/t34 · 子 L: 待っている (確認の画面)、親 ABC-681");
  const error = marksOf(today({ kStatus: "idle", lStatus: "error" })).get("wsl1/spl").tip;
  assert.equal(error, "ABC-750 · wsl1/t34 · 子 L: 待っている (エラーで止まっている)、親 ABC-681");
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[0].labels["pjp.asking"] = "案 A と B のどちらで進めるか";
  assert.match(marksOf(w).get("sph").tip, /^ABC-681 · t1m: 待っている \(問い: 案 A と B のどちらで進めるか\)、子 2 人 \(K L\)$/);
  // 確認の画面と文の問いが重なれば両方。問いの改行・続く空白は 1 つの空白にする (説明は 1 会話 1 行)
  w.terminals[0].status = "blocked";
  w.terminals[0].labels["pjp.asking"] = " 案 A と\nB の  どちらか ";
  assert.match(marksOf(w).get("sph").tip, /^ABC-681 · t1m: 待っている \(確認の画面・問い: 案 A と B の どちらか\)、/);
});

// ---- 解説動画の行 (3 行目から 1 本 1 行。spec 2026-11-21-spaces-video-mark-design.md の §11) ---------------------------------

const T1305 = "2026-11-21T13:05:12+09:00";
const making = (name, started = T1305) => video(name, "making", started);
const made = (name, started, ended) => video(name, "done", started, { ended });
// 3 行目からの動画の行の文字
const linesOf = (w, id) => marksOf(w).get(id)?.videos.map((v) => v.text);

test("動画の行の頭 🎬⏳・🎬✅ は異体字セレクタを付けない (⏳ U+23F3・✅ U+2705 はもとから絵文字で出る字)", () => {
  assert.equal(mod.MARKS.making, "\u{1F3AC}⏳");
  assert.equal(mod.MARKS.made, "\u{1F3AC}✅");
});

test("子が動画を作っていれば、子の行とハブの行に動画の行 🎬⏳:<名前> が出て、2 行目には出ない (子孫の動画も上の親に出る)", () => {
  const w = today({ kStatus: "idle", lStatus: "working" });
  assert.deepEqual(linesOf(w, "sph"), []);
  w.terminals[5].labels["pjp.video.20261121130512"] = making("ABC-750 短尺 x");
  assert.deepEqual(linesOf(w, "wsl1/spl"), ["🎬⏳:ABC-750 短尺 x"]);
  assert.deepEqual(linesOf(w, "sph"), ["🎬⏳:ABC-750 短尺 x"]);
  // 2 行目は動画の無いときのまま
  assert.equal(textOf(w, "wsl1/spl"), "wsl1/t34 🌱 ↑ ABC-681");
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]🔄");
  // 作り終えたら 🎬✅ に替わる (行の数は替わらない)
  w.terminals[5].labels["pjp.video.20261121130512"] = made("ABC-750 短尺 x", T1305, "2026-11-21T13:41:30+09:00");
  assert.deepEqual(linesOf(w, "wsl1/spl"), ["🎬✅:ABC-750 短尺 x"]);
  assert.deepEqual(linesOf(w, "sph"), ["🎬✅:ABC-750 短尺 x"]);
  // 見たと外せば消える
  delete w.terminals[5].labels["pjp.video.20261121130512"];
  assert.deepEqual(linesOf(w, "sph"), []);
});

test("動画 1 本に 1 行。⏳ を先、✅ を後に、それぞれ作り始めた順 (ホバーの動画の行も同じ並び)", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  Object.assign(w.terminals[5].labels, {
    "pjp.video.b": making("B", "2026-11-21T13:10:00+09:00"),
    "pjp.video.a": made("A", "2026-11-21T12:00:00+09:00", "2026-11-21T12:40:00+09:00"),
    "pjp.video.c": made("C", "2026-11-21T11:00:00+09:00", "2026-11-21T11:30:00+09:00"),
  });
  w.terminals[3].labels["pjp.video.d"] = making("D", "2026-11-21T13:00:00+09:00");
  assert.deepEqual(linesOf(w, "sph"), ["🎬⏳:D", "🎬⏳:B", "🎬✅:C", "🎬✅:A"]);
  assert.deepEqual(linesOf(w, "wsl1/spl"), ["🎬⏳:B", "🎬✅:C", "🎬✅:A"]);
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]");
  const lines = marksOf(w).get("sph").tip.split("\n").slice(1);
  assert.deepEqual(lines.map((l) => l.trim().split(" ")[0]), ["🎬⏳:D", "🎬⏳:B", "🎬✅:C", "🎬✅:A"]);
});

test("動画があっても 2 行目の ❓・👀 の並びは替わらない", () => {
  const w = today({ kStatus: "idle", lStatus: "blocked", lRecords: SUBAGENT });
  w.terminals[5].labels["pjp.video.1"] = making("x");
  assert.equal(textOf(w, "wsl1/spl"), "wsl1/t34 ❓🌱👀 ↑ ABC-681");
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]👀");
  assert.deepEqual(linesOf(w, "sph"), ["🎬⏳:x"]);
});

test("見ていない動画 (🎬✅) だけなら 🗑️ を出し、作っている動画 (🎬⏳) があれば 🗑️ を出さない", () => {
  const fin = (videos) => ({
    spaces: [space("spw", "ABC-742 panel の直し")],
    terminals: [term("t2a", { space: "spw", role: "hub", ticket: "ABC-742", finished: "2026-11-17T23:10+09:00", status: "idle", videos })],
    panes: [],
  });
  const done = fin({ "pjp.video.1": made("x", T1305, T1305) });
  assert.equal(textOf(done, "spw"), "t2a 🗑️");
  assert.deepEqual(linesOf(done, "spw"), ["🎬✅:x"]);
  const doing = fin({ "pjp.video.1": making("x") });
  assert.equal(textOf(doing, "spw"), "t2a");
  assert.deepEqual(linesOf(doing, "spw"), ["🎬⏳:x"]);
  const both = fin({ "pjp.video.1": making("x"), "pjp.video.2": made("y", T1305, T1305) });
  assert.equal(textOf(both, "spw"), "t2a");
  assert.deepEqual(linesOf(both, "spw"), ["🎬⏳:x", "🎬✅:y"]);
  // 子の会話 (pjp.finished を付けた子 A) でも同じ: ✅ だけなら 🌱🗑️、⏳ があれば 🗑️ を出さない
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[5].labels["pjp.finished"] = "2026-11-21T16:00+09:00";
  w.terminals[5].labels["pjp.video.1"] = made("ABC-750 短尺 x", T1305, T1305);
  assert.equal(textOf(w, "wsl1/spl"), "wsl1/t34 🌱🗑️ ↑ ABC-681");
  w.terminals[5].labels["pjp.video.2"] = making("ABC-750 詳細版 x");
  assert.equal(textOf(w, "wsl1/spl"), "wsl1/t34 🌱 ↑ ABC-681");
  assert.deepEqual(linesOf(w, "wsl1/spl"), ["🎬⏳:ABC-750 詳細版 x", "🎬✅:ABC-750 短尺 x"]);
});

test("手伝いの端末 (pjp.role なし) の動画も、立てた会話の行に出る", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals.push(term("t60", { parent: "t1m", status: "idle", videos: { "pjp.video.1": making("ABC-681 短尺 hub") } }));
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]");
  assert.deepEqual(marksOf(w).get("sph").videos, [
    { state: "making", text: "🎬⏳:ABC-681 短尺 hub", tip: "🎬⏳:ABC-681 短尺 hub (手伝いの端末 t60・11/21 13:05 から作っている)" },
  ]);
  assert.match(marksOf(w).get("sph").tip, /\n {2}🎬⏳:ABC-681 短尺 hub \(手伝いの端末 t60・11\/21 13:05 から作っている\)/);
});

test("動画の label のある端末は、pjp.role が無くても会話になる (2 行の行の下に動画の行が付く)", () => {
  const w = today();
  w.terminals.push(term("t9q", { space: "spx", status: "idle", videos: { "pjp.video.1": made("x", T1305, T1305) } }));
  assert.equal(textOf(w, "spx"), "t9q");
  assert.deepEqual(linesOf(w, "spx"), ["🎬✅:x"]);
  assert.equal(findId(draw(w), "space-spx").props.h, 44 + 17);
});

test("終わった端末・読めない値の動画は数えない", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals.push(term("wsl1/t50", { parent: "t1m", role: "child", letter: "C", state: "finished", videos: { "pjp.video.1": making("x") } }));
  Object.assign(w.terminals[5].labels, {
    "pjp.video.a": "not json",
    "pjp.video.b": JSON.stringify({ name: "x", state: "weird" }),
    "pjp.video.c": JSON.stringify(["done"]),
    "pjp.video.": made("no id", T1305, T1305),
    "pjp.videox": made("not ours", T1305, T1305),
  });
  assert.deepEqual(linesOf(w, "sph"), []);
  assert.deepEqual(linesOf(w, "wsl1/spl"), []);
  assert.equal(marksOf(w).get("sph").tip.includes("解説動画"), false);
  // 名前が無ければキーの後ろを名前にする
  assert.deepEqual(mod.videosOf({ labels: { "pjp.video.20261121": JSON.stringify({ state: "making", started: T1305 }) } }).map((v) => v.name), ["20261121"]);
});

test("ホバーに、解説動画の数と、動画ごとの状態・名前・時刻・どの端末かを書く (動画の行のホバーはその 1 本)", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[5].labels["pjp.video.20261121130512"] = making("ABC-750 短尺 x");
  w.terminals[3].labels["pjp.video.20261121120000"] = made("ABC-751 詳細版 y", "2026-11-21T12:00:00+09:00", "2026-11-21T12:40:00+09:00");
  assert.deepEqual(marksOf(w).get("sph").tip.split("\n"), [
    "ABC-681 · t1m: 子 2 人 (K L)、解説動画 (作っている 1・見ていない 1)",
    "  🎬⏳:ABC-750 短尺 x (子 L wsl1/t34・11/21 13:05 から作っている)",
    "  🎬✅:ABC-751 詳細版 y (子 K wsl1/t32・11/21 12:40 に載せた・見ていない)",
  ]);
  assert.deepEqual(marksOf(w).get("sph").videos.map((v) => v.tip), [
    "🎬⏳:ABC-750 短尺 x (子 L wsl1/t34・11/21 13:05 から作っている)",
    "🎬✅:ABC-751 詳細版 y (子 K wsl1/t32・11/21 12:40 に載せた・見ていない)",
  ]);
  assert.deepEqual(marksOf(w).get("wsl1/spl").tip.split("\n"), [
    "ABC-750 · wsl1/t34 · 子 L: 親 ABC-681、解説動画 (作っている 1)",
    "  🎬⏳:ABC-750 短尺 x (この会話・11/21 13:05 から作っている)",
  ]);
});

test("片付けた子から親へ移した動画は、どの子から移したかをホバーに書く。ホバーの名前は 60 字で切り、動画の行は切らない (行の幅で切る)", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[0].labels["pjp.video.1"] = video("あ".repeat(61), "done", "2026-11-21T12:00:00+09:00", { ended: "2026-11-21T12:40:00+09:00", from: "子 C (wsl1/t50)" });
  const lines = marksOf(w).get("sph").tip.split("\n");
  assert.equal(lines[1], `  🎬✅:${"あ".repeat(60)}… (この会話・11/21 12:40 に載せた・見ていない・片付けた子 C (wsl1/t50) から移した)`);
  const [line] = marksOf(w).get("sph").videos;
  assert.equal(line.text, `🎬✅:${"あ".repeat(61)}`);
  assert.equal(line.tip, lines[1].trim());
});

test("会話が 2 つの space では、2 つの会話の動画をまとめて 1 つの並びにし、動画の行のホバーの頭にどの会話のものかを書く", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[5].labels["pjp.video.1"] = made("x", T1305, T1305);
  w.terminals.push(term("t1q", { space: "sph", tab: 2, role: "hub", ticket: "ABC-742", status: "idle", videos: { "pjp.video.2": making("y") } }));
  // 2 行目は会話ごとに address と名札 (印の無い ABC-742 も address と名札だけ出る)
  assert.equal(textOf(w, "sph"), "t1m ABC-681 🌳[2] │ t1q ABC-742");
  // ⏳ が先 (後ろの会話の動画でも)
  assert.deepEqual(marksOf(w).get("sph").videos.map((v) => v.tip), [
    "ABC-742 · t1q: 🎬⏳:y (この会話・11/21 13:05 から作っている)",
    "ABC-681 · t1m: 🎬✅:x (子 L wsl1/t34・11/21 13:05 に載せた・見ていない)",
  ]);
  // 2 行目のホバーは会話ごとの行の下に、その会話の動画の行
  const lines = marksOf(w).get("sph").tip.split("\n");
  assert.equal(lines.length, 4, lines.join("\n"));
  assert.match(lines[0], /^ABC-681 · t1m: /);
  assert.match(lines[1], /^ {2}🎬✅:x \(子 L wsl1\/t34・/);
  assert.match(lines[2], /^ABC-742 · t1q: 解説動画 \(作っている 1\)$/);
  assert.match(lines[3], /^ {2}🎬⏳:y \(この会話・/);
});

test("同じ space の親子の会話から 2 度集まった動画は、動画の行に 1 本だけ出す (先の会話のもの)", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  // ハブの space の tab 2 に、ハブの子 Z (同じ space の会話) がいて、動画を作っている
  w.terminals.push(term("t1q", { space: "sph", tab: 2, parent: "t1m", role: "child", letter: "Z", status: "idle", videos: { "pjp.video.1": making("z") } }));
  assert.equal(textOf(w, "sph"), "t1m ABC-681 🌳[3] │ t1q Z 🌱 ↑ ABC-681");
  assert.deepEqual(marksOf(w).get("sph").videos.map((v) => v.tip), ["ABC-681 · t1m: 🎬⏳:z (子 Z t1q・11/21 13:05 から作っている)"]);
});

test("debug の生の値に、動画の label のある端末と、読んだ動画の行を出す", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals[5].labels["pjp.video.20261121130512"] = making("ABC-750 短尺 x");
  w.terminals.push(term("t60", { parent: "t1m", videos: { "pjp.video.9": made("z", T1305, "2026-11-21T13:41:30+09:00") } }));
  const raw = mod.debugLines(w.terminals, w.spaces).join("\n");
  assert.match(raw, /^video wsl1\/t34 pjp\.video\.20261121130512: making 2026-11-21T13:05:12\+09:00 ABC-750 短尺 x$/m);
  assert.match(raw, /^video t60 pjp\.video\.9: done 2026-11-21T13:05:12\+09:00〜2026-11-21T13:41:30\+09:00 z$/m);
  assert.match(raw, /"address":"t60"/);
});

test("会話の手伝いの端末は、動画を持っていても自分の会話にならない (同じ space に映っても二重に数えない)", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  w.terminals.push(term("t60", { space: "sph", tab: 2, parent: "t1m", status: "idle", videos: { "pjp.video.1": making("x") } }));
  assert.equal(textOf(w, "sph"), "t1m 🌳[2]");
  assert.deepEqual(linesOf(w, "sph"), ["🎬⏳:x"]);
  assert.equal(marksOf(w).get("sph").count, 1);
  // 親が会話でない (ただの shell の) 手伝いの端末は、自分の行に出す
  const v = today({ kStatus: "idle", lStatus: "idle" });
  v.terminals.push(term("t61", { space: "spx", parent: "t9", status: "idle", videos: { "pjp.video.1": making("y") } }));
  assert.equal(textOf(v, "spx"), "t61 🌱 ↑ ~");
  assert.deepEqual(linesOf(v, "spx"), ["🎬⏳:y"]);
});

test("同じ動画の写し (名前・作り始めた日時・状態が同じ。片付けで親へ移した後に子を終えられなかった) は 1 本に数える", () => {
  const w = today({ kStatus: "idle", lStatus: "idle" });
  const value = made("ABC-750 短尺 x", T1305, "2026-11-21T13:41:30+09:00");
  w.terminals[5].labels["pjp.video.1"] = value;
  w.terminals[0].labels["pjp.video.1"] = video("ABC-750 短尺 x", "done", T1305, { ended: "2026-11-21T13:41:30+09:00", from: "子 L (wsl1/t34)" });
  assert.deepEqual(linesOf(w, "sph"), ["🎬✅:ABC-750 短尺 x"]);
  assert.equal(marksOf(w).get("sph").tip.split("\n").length, 2);
});

test("terminals() が空・壊れた値でも落ちない", () => {
  assert.equal(mod.spaceMarks(undefined, undefined, undefined).size, 0);
  assert.equal(mod.spaceMarks([null, {}, { address: 3 }], [], null).size, 0);
});

// ---- 描き方 (偽の要素で render を通す) ------------------------------------------------------------------------------

const NODE = Symbol.for("pjp-spaces.fake-node");
const nodeOf = (el) => (el && typeof el === "object" ? el[NODE] : undefined);

// 要素の木を深さ優先でたどる (要素か、控えた node を渡す)
function* walk(el) {
  const n = nodeOf(el) ?? (el && Array.isArray(el.kids) ? el : undefined);
  if (!n) return;
  yield n;
  for (const k of n.kids) yield* walk(k);
}
const findId = (root, id) => [...walk(root)].find((n) => n.props.id === id);
// 要素の中の文字 (child に渡された文字列) を、出てくる順に
function texts(n) {
  const out = [];
  for (const k of n.kids) {
    if (typeof k === "string") out.push(k);
    else if (nodeOf(k)) out.push(...texts(nodeOf(k)));
  }
  return out;
}

const CX = { timer: { every() {} }, spawn() {}, notify() {}, stop_propagation() {} };
const setWorld = (world, { sidebar = 480, props = {} } = {}) => {
  globalThis.__herdr = { ...world, machines: [], shared: {}, ran: [], props, layout: { id: "root", children: [{ id: "sidebar", size: { px: sidebar } }] } };
};

// prepare は init の後・render の前に view を触る (git の控えを置くなど。偽の exec は git に答えない)
function draw(world, { sidebar = 480, props = {}, prepare } = {}) {
  setWorld(world, { sidebar, props });
  const view = new mod.default();
  view.init({}, CX);
  prepare?.(view);
  return view.render(CX);
}

// 同じ view で描き直す (init はせずに render だけ。world の値を替えてから呼ぶ)
function redraw(view, world, opts) {
  setWorld(world, opts);
  return view.render(CX);
}

test("会話の space の行は 2 行 (高さ 44) で、2 行目に会話の端末の address と印、素の space は元の 1 行 (高さ 30)", () => {
  const root = draw(today());
  // 文字は avatar の頭の字・名前・2 行目の address と印の順
  const hub = findId(root, "space-sph");
  assert.equal(hub.props.h, 44);
  assert.deepEqual(texts(hub), ["H", "h", "t1m 🌳[2]🔄"]);
  const child = findId(root, "space-wsl1/spk");
  assert.equal(child.props.h, 44);
  assert.deepEqual(texts(child), ["K", "K dotfiles: panel の問い", "wsl1/t32 🌱 ↑ ABC-681"]);
  const plain = findId(root, "space-spx");
  assert.equal(plain.props.h, 30);
  assert.deepEqual(texts(plain), ["~", "~"]);
});

test("2 行目の印にホバーの説明を付け、1 行目の名前は行の幅いっぱいまで出す (max_w で切らない)", () => {
  const hub = findId(draw(today()), "space-sph");
  const marks = [...walk(hub)].find((n) => n.kids.includes("t1m 🌳[2]🔄"));
  assert.match(marks.props.tooltip, /子 2 人 \(K L\)/);
  const name = [...walk(hub)].find((n) => n.kids.includes("h"));
  assert.equal(name.props.max_w, undefined);
  assert.ok(name.calls.some(([m]) => m === "flex_1"));
});

// 一覧 (track_scroll を付けた要素) の直下の子のうち、id が space-<id> の行を含む子の位置
function listIndexOf(root, id) {
  const list = [...walk(root)].find((n) => n.props.track_scroll !== undefined);
  return list.kids.findIndex((k) => [...walk(k)].some((n) => n.props.id === `space-${id}`));
}

test("表示中の space の行をスクロールで見せる (0.1.16)。debug の物差しの分も位置をずらす", () => {
  for (const props of [{}, { debug: true }]) {
    const w = today();
    w.spaces = w.spaces.map((s) => (s.id === "wsl1/spl" ? { ...s, active: true } : s));
    let view;
    const root = draw(w, { props, prepare: (v) => (view = v) });
    const at = listIndexOf(root, "wsl1/spl");
    assert.ok(at > 0);
    assert.deepEqual(view.scroll.items, [at]);
    assert.equal(view.activeAt, at);
  }
});

test("動画の行が増えても減っても (行の高さが替わっても)、ユーザーがスクロールした一覧を表示中の space の行へ戻さない", () => {
  const w = today();
  w.spaces = w.spaces.map((s) => (s.id === "sph" ? { ...s, active: true } : s));
  let view;
  const first = draw(w, { props: { debug: true, width: 406 }, prepare: (v) => (view = v) });
  const at = listIndexOf(first, "sph");
  assert.deepEqual(view.scroll.items, [at]);
  // 子 L の動画を付けて外す: 子 L の行とハブの行 (子孫の分を並べる) の高さが替わる
  w.terminals[5].labels["pjp.video.1"] = making("ABC-750 短尺 x");
  const grown = redraw(view, w, { props: { debug: true, width: 406 } });
  assert.equal(findId(grown, "space-sph").props.h, 44 + 17);
  assert.equal(findId(grown, "space-wsl1/spl").props.h, 44 + 17);
  delete w.terminals[5].labels["pjp.video.1"];
  const shrunk = redraw(view, w, { props: { debug: true, width: 406 } });
  assert.equal(findId(shrunk, "space-sph").props.h, 44);
  assert.deepEqual(view.scroll.items, [at]);
  // 中身の高さで大きさが替わる一覧の要素には、on_size_change を付けない (付けると、行の高さが替わるたびに表示中の space へ戻る)
  const list = [...walk(shrunk)].find((n) => n.props.track_scroll !== undefined);
  assert.equal(list.props.on_size_change, undefined);
});

test("mod の大きさが替わったら (上のほかの mod の領域が伸びた・窓の大きさが替わった)、表示中の space の行を見せる", () => {
  const w = today();
  w.spaces = w.spaces.map((s) => (s.id === "wsl1/spl" ? { ...s, active: true } : s));
  let view;
  const root = draw(w, { prepare: (v) => (view = v) });
  const at = listIndexOf(root, "wsl1/spl");
  assert.deepEqual(view.scroll.items, [at]);
  // root (mod の大きさ) の on_size_change が、表示中の space の行をもう一度見せる
  const handler = nodeOf(root).props.on_size_change;
  assert.equal(typeof handler, "function");
  handler({ width: 406, height: 300 }, CX);
  assert.deepEqual(view.scroll.items, [at, at]);
  // 表示中の space が一覧に無ければ (描いていなければ) 何もしない
  view.activeAt = -1;
  handler({ width: 406, height: 200 }, CX);
  assert.deepEqual(view.scroll.items, [at, at]);
});

test("本体の下に字下げした worktree の会話の行は高さ 42 で、2 行目に印と git (branch・ahead) を出す", () => {
  const w = {
    spaces: [{ ...space("sph", "h"), folder: "/h" }, { ...space("spw", "ABC-742 印"), folder: "/wt/x" }, space("spc", "A dotfiles: 子", { machine: "wsl1" })],
    terminals: [
      term("t1m", { space: "sph", role: "hub", ticket: "ABC-681" }),
      term("t2a", { space: "spw", role: "hub", ticket: "ABC-742" }),
      term("wsl1/t90", { space: "spc", parent: "t2a", role: "child", letter: "A", status: "working" }),
    ],
    panes: [],
  };
  const repo = JSON.stringify([null, "/h/.git"]);
  const root = draw(w, {
    prepare: (view) => {
      view.git[JSON.stringify([null, "/h"])] = { name: "h", branch: "main", ahead: 0, behind: 0, repo, linked: false };
      view.git[JSON.stringify([null, "/wt/x"])] = { name: "h", branch: "hub/x", ahead: 2, behind: 0, repo, linked: true };
    },
  });
  const tree = findId(root, "space-spw");
  assert.equal(tree.props.h, 42);
  assert.deepEqual(texts(tree), ["ABC-742 印", "t2a 🌳[1]🔄", "hub/x", "↑2"]);
  const second = [...walk(tree)].find((n) => n.kids.some((k) => nodeOf(k)?.kids.includes("t2a 🌳[1]🔄")));
  assert.equal(second.props.pl, 44);
  // 2 行目の git は、元 (0.1.16) の gitTail の flex_auto・min_w(48) を flex_1・min_w(0) に戻す (印を git に削らせない)
  const tail = nodeOf(second.kids[1]);
  const flexes = tail.calls.map(([m]) => m).filter((m) => m === "flex_auto" || m === "flex_1");
  assert.deepEqual(flexes, ["flex_auto", "flex_1"]);
  assert.equal(tail.props.min_w, 0);
  // 本体の行は字下げなしで、main の branch は出さない (同梱の gitTail のまま)。h の会話に子はいないので印は無いが、2 行のままで
  // address は出す
  const main = findId(root, "space-sph");
  assert.equal(main.props.h, 44);
  assert.deepEqual(texts(main), ["H", "h", "t1m"]);
  const mainSecond = [...walk(main)].find((n) => n.props.pl !== undefined);
  assert.equal(mainSecond.props.pl, 27);
});

test("細い表示 (sidebar が 160px 未満) では、会話の印をホバーで出す", () => {
  const root = draw(today(), { sidebar: 100 });
  const hub = findId(root, "space-sph");
  assert.equal(hub.props.tooltip, "h\nt1m 🌳[2]🔄");
  assert.equal(findId(root, "space-spx").props.tooltip, undefined);
});

test("文の問いを出している会話の行は、2 行目の印の先頭に ❓、ホバーに問いの要旨 (細い表示のホバーにも ❓)", () => {
  const w = today();
  w.terminals[0].labels["pjp.asking"] = "PR #195 を merge してよいか";
  const hub = findId(draw(w), "space-sph");
  assert.equal(hub.props.h, 44);
  assert.deepEqual(texts(hub), ["H", "h", "t1m ❓🌳[2]🔄"]);
  const marks = [...walk(hub)].find((n) => n.kids.includes("t1m ❓🌳[2]🔄"));
  assert.match(marks.props.tooltip, /^ABC-681 · t1m: 待っている \(問い: PR #195 を merge してよいか\)、/);
  assert.equal(findId(draw(w, { sidebar: 100 }), "space-sph").props.tooltip, "h\nt1m ❓🌳[2]🔄");
});

test("動画のある space の行は、3 行目から動画を 1 本 1 行で出し、行の高さを本数ぶん増やす (2 行目には出さない)", () => {
  const w = today();
  w.terminals[5].labels["pjp.video.1"] = making("ABC-750 短尺 x");
  w.terminals[3].labels["pjp.video.2"] = made("ABC-751 詳細版 y", T1305, T1305);
  const root = draw(w);
  const hub = findId(root, "space-sph");
  assert.equal(hub.props.h, 44 + 17 * 2);
  assert.deepEqual(texts(hub), ["H", "h", "t1m 🌳[2]🔄", "🎬⏳:ABC-750 短尺 x", "🎬✅:ABC-751 詳細版 y"]);
  const child = findId(root, "space-wsl1/spl");
  assert.equal(child.props.h, 44 + 17);
  assert.deepEqual(texts(child), ["L", "L claude-skills: 手順", "wsl1/t34 🌱 ↑ ABC-681", "🎬⏳:ABC-750 短尺 x"]);
  // 動画の行の字: 長い名前は行の幅で … (truncate・min_w 0)。色は ⏳ がテーマの ansi3、✅ が ansi2。ホバーはその 1 本の説明
  const textNode = (n, s) => [...walk(n)].find((k) => k.kids.includes(s));
  const doing = textNode(hub, "🎬⏳:ABC-750 短尺 x");
  assert.ok(doing.calls.some(([m]) => m === "truncate"));
  assert.ok(doing.calls.some(([m]) => m === "flex_1"));
  assert.equal(doing.props.min_w, 0);
  assert.equal(doing.props.text_color, "#ansi3");
  assert.equal(doing.props.tooltip, "🎬⏳:ABC-750 短尺 x (子 L wsl1/t34・11/21 13:05 から作っている)");
  assert.equal(textNode(hub, "🎬✅:ABC-751 詳細版 y").props.text_color, "#ansi2");
  // 動画の行の外側: 字下げ・字の大きさ・行の高さは 2 行目と同じ
  const lineOf = (n, inner) => [...walk(n)].find((k) => k.kids.some((c) => nodeOf(c) === inner));
  const second = lineOf(hub, textNode(hub, "t1m 🌳[2]🔄"));
  const third = lineOf(hub, doing);
  for (const p of ["h", "line_height", "pl", "text_size"]) assert.equal(third.props[p], second.props[p], p);
  assert.equal(third.props.h, 16);
  // 動画が無くなれば元の 2 行の行
  delete w.terminals[5].labels["pjp.video.1"];
  delete w.terminals[3].labels["pjp.video.2"];
  assert.equal(findId(draw(w), "space-sph").props.h, 44);
});

test("本体の下に字下げした worktree の会話の行も、動画の行の分だけ高く (42 + 17 × 本数)、字下げは 2 行目と同じ", () => {
  const w = {
    spaces: [{ ...space("sph", "h"), folder: "/h" }, { ...space("spw", "ABC-742 印"), folder: "/wt/x" }],
    terminals: [
      term("t1m", { space: "sph", role: "hub", ticket: "ABC-681" }),
      term("t2a", { space: "spw", role: "hub", ticket: "ABC-742", videos: { "pjp.video.1": making("ABC-742 短尺 印") } }),
    ],
    panes: [],
  };
  const repo = JSON.stringify([null, "/h/.git"]);
  const root = draw(w, {
    prepare: (view) => {
      view.git[JSON.stringify([null, "/h"])] = { name: "h", branch: "main", ahead: 0, behind: 0, repo, linked: false };
      view.git[JSON.stringify([null, "/wt/x"])] = { name: "h", branch: "hub/x", ahead: 0, behind: 0, repo, linked: true };
    },
  });
  const tree = findId(root, "space-spw");
  assert.equal(tree.props.h, 42 + 17);
  assert.deepEqual(texts(tree), ["ABC-742 印", "t2a", "hub/x", "🎬⏳:ABC-742 短尺 印"]);
  const third = [...walk(tree)].find((k) => k.kids.some((c) => nodeOf(c)?.kids.includes("🎬⏳:ABC-742 短尺 印")));
  assert.equal(third.props.pl, 44);
});

test("細い表示 (rail) のホバーに、名前・2 行目の文字 (address と印)・動画の行を出す", () => {
  const w = today();
  w.terminals[5].labels["pjp.video.1"] = making("ABC-750 短尺 x");
  assert.equal(findId(draw(w, { sidebar: 100 }), "space-sph").props.tooltip, "h\nt1m 🌳[2]🔄\n🎬⏳:ABC-750 短尺 x");
  assert.equal(findId(draw(w, { sidebar: 100 }), "space-wsl1/spl").props.tooltip, "L claude-skills: 手順\nwsl1/t34 🌱 ↑ ABC-681\n🎬⏳:ABC-750 短尺 x");
  // 2 行目に印の無い会話 (動画の label だけの端末。2 行目は address だけ)
  w.terminals.push(term("t9q", { space: "spx", status: "idle", videos: { "pjp.video.1": made("x", T1305, T1305) } }));
  assert.equal(findId(draw(w, { sidebar: 100 }), "space-spx").props.tooltip, "~\nt9q\n🎬✅:x");
});

test("props の debug が true のときだけ、一覧の上に物差し、下に生の値を出す", () => {
  const plain = texts(nodeOf(draw(today())));
  assert.equal(plain.some((s) => /^terminals: /.test(s)), false);
  assert.equal(plain.includes(mod.RULERS[0]), false);
  const shown = texts(nodeOf(draw(today(), { props: { debug: true } })));
  // 物差しは字下げの無い行と worktree の行に 1 本ずつ (半角・全角)、一覧の行より前。物差しの行は動画が 1 本ある行の高さ
  assert.equal(shown.filter((s) => s === mod.RULERS[0]).length, 2);
  assert.equal(shown.filter((s) => s === mod.RULERS[1]).length, 2);
  assert.ok(shown.indexOf(mod.RULERS[1]) < shown.indexOf("h"));
  assert.ok(shown.includes("物差し (字下げの無い行・70 字。3 行目は動画の行)"));
  assert.ok(shown.includes("物差し (worktree の行・40 字。3 行目は動画の行)"));
  // 3 行目は動画の行の物差し (🎬⏳: の後ろに半角 70 字・全角 40 字。字下げの無い行と worktree の行に 1 本ずつ)
  assert.equal(shown.filter((s) => s === `🎬⏳:${mod.RULERS[0]}`).length, 2);
  assert.equal(shown.filter((s) => s === `🎬⏳:${mod.RULERS[1]}`).length, 2);
  const raw = shown.join("\n");
  assert.match(raw, /^terminals: 7 \(live 7\) keys: /m);
  assert.match(raw, /"address":"wsl1\/t32"/);
  assert.match(raw, /^space wsl1\/spk machine=wsl1 /m);
});

test("物差しは 10 字ごとに目盛りの字を置く", () => {
  assert.equal(mod.RULERS[0].length, 70);
  assert.deepEqual([...mod.RULERS[0]].filter((_, i) => i % 10 === 9), ["A", "B", "C", "D", "E", "F", "G"]);
  assert.deepEqual([...mod.RULERS[1]].filter((_, i) => i % 10 === 9), ["十", "廿", "卅", "卌"]);
});

test("props の width があれば、その幅で並べる (ペインで sidebar の幅を写す)", () => {
  assert.equal(nodeOf(draw(today(), { props: { width: 268 } })).props.w, 268);
  assert.equal(nodeOf(draw(today())).props.w, undefined);
});

test("同梱の spaces と同じ名前で glyph・tone を出す", () => {
  assert.equal(mod.glyph("blocked"), "●");
  assert.equal(mod.glyph("working"), "·");
  assert.equal(mod.tone({ unknown: "#u" }, "idle"), "#u");
});
