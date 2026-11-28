// pjp-spaces: herdr-app 0.1.16 の同梱の spaces mod (mods/spaces/main.js) を写し、会話の端末がいる space の行を 2 行にして、
// 2 行目に会話の端末の address と会話の印 (❓・🌱・🌳[N]・🔄・👀・🗑️・↑ TKT-n) を、3 行目から解説動画を 1 本 1 行 (🎬⏳:<名前>・
// 🎬✅:<名前>) で足したもの。写した元の版: herdr-app 0.1.16。元は dotfiles の
// win/herdr-app/upstream/spaces/ に元のまま残してある。足した・替えた所には「pjp-spaces:」の注を付けた。
// herdr-app を上げて元が変わったら、元との差を取り込む (skill pjp-hc-hub の references/spaces.md)。元は自分の mods/spaces/ の
// 資産も自分で開く overlay も使わないので、mod.clone がするような書き換えは要らない。
//
// Workspace spaces: stable colored avatars, worktrees under their checkout,
// grouped by machine when more than one is known. After a space's name, the repo
// its first terminal is in now, only where unusual: branch, ahead/behind. Agent state lives in the agents list, not here. Click to
// switch, right-click for its menu, drag to reorder.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex, ScrollHandle } from "gpui-base";
// pjp-spaces: terminals (会話の印) と props (debug) も読む
import { spaces, machines, panes, run, openOverlay, exec, hc, theme, shared, setShared, watchFolder, window, layout, terminals, props } from "herdr";

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// The sidebar's rail goes by its width, not a flag: dragging its edge narrows it too.
const narrow = () => (find(layout(), "sidebar")?.size?.px ?? Infinity) < 160;

// Where a space is now: its first terminal's live folder, else where it was made.
// `ps`: panes(), read once by the caller (each read copies every pane).
function place(s, ps) {
  const tabs = new Set((s.tabs ?? []).map((c) => c.id));
  return ps.find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder;
}
const rowHeight = ({ tree }) => (tree ? 28 : 30);
const RAIL_CELL = 32;
// A space's name and its git tail never shrink below this, so a short one ("api")
// stays readable instead of turning into an ellipsis next to a long branch.
const SIDE_MIN = 48;
const railCell = (el) => h_flex().flex_none().justify_center().child(el);
const where = (s, ps) => JSON.stringify([s.machine ?? null, place(s, ps)]);
const base = (path) => path.replace(/\/+$/, "").split("/").pop();
// Changes made outside Herdr (an editor's save, a commit in another app): looked
// for this often, in repos the list shows, while the window is in front.
const FALLBACK = 60000;
// Places looked at together (two git runs each). All at once, a few hundred spaces
// run out of the app's open files (256 when started from the Dock on macOS) or
// past a machine core's 16 running execs, and those spaces wait for FALLBACK.
const AT_ONCE = 6;

// Both runs, finished: a place isn't done while one of its runs still holds a slot.
async function both(a, b) {
  const done = await Promise.allSettled([a, b]);
  const failed = done.find((d) => d.status === "rejected");
  if (failed) throw failed.reason;
  return done.map((d) => d.value);
}

// What a stored color name looks like on an avatar (the same in every mod
// that draws space avatars): one strong color per hue, light and dark alike.
const MARK = { ansi6: "#22a99a", ansi3: "#e3814f", ansi4: "#5b8def", ansi5: "#8b7cf6", ansi2: "#3fae6a", ansi1: "#d9649a" };

// A space speaks up only when something in it needs you.
export function glyph(status) {
  return status === "blocked" || status === "done" ? "●" : "·";
}

export function tone(t, status) {
  return t[status] ?? t.unknown;
}

// pjp-spaces: ここから会話の印 (claude-skills の docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md の §7.5)。
//
// 会話は、label pjp.role が hub か child の生きている端末 (pjp mark name・pjp child new が付ける) と、生きている子のいる端末
// (pjp mark name より先に子を立てた会話も入れる) と、解説動画の印 (label pjp.video.<id>) のある生きている端末 (pjp mark name を
// 打っていない Linux の会話でも、作った動画の印が出る。会話の手伝いの端末は除き、印は親の行に出す)。子は、parent がその端末で
// pjp.role が child の生きている端末。会話の端末が
// いる space は行を 2 行にし、2 行目に会話ごとに、頭に会話の端末の hc の address (hc send の <hc from="…"> と同じ形。このマシンの
// 端末は素の ID、ほかのマシンの端末は <machine>/<ID>)、その後ろに印を旧 herdr の sidebar の stat・parent と同じ並び (頭に ❓) で出す。
// 例: 子の space に `<machine>/t10d 🌱 ↑ TKT-n`、ハブの space に `t53 🌳[1]🔄`、印の無い会話の space に `t53` (address は必ず出す)
//
//   ❓       ユーザーの答え・対応を待っている: その端末の status が blocked (確認の画面) か error (エラーで止まっている) か、
//            label pjp.asking がある (文で問いを出している間。pjp mark asking が付け、answered が外す。status は問わない)。
//            印の先頭 (🌱 より前) に出す (2 行目は右から切れるので、狭い sidebar でも見える)。親の行へは伝えない
//   🌱       その端末に親がいる (parent が空でない)
//   🌳[N]    生きている子が N 人
//   🔄       子か孫 (子をたどる) のどれかが working。🌳[N] の直後に出す
//   👀       裏の作業が動いている: 記録 (records) に working がある (subagent) か、自分が立てた手伝いの端末 (pjp.role の無い
//            生きている端末。hc run --bg) が working。会話の状態は問わない。子孫の 👀 も上の親へ伝える
//   🗑️       pjp.finished があり、子が 0 人で、working でもなく、❓ でも 👀 でもなく、作っている解説動画 (🎬⏳) も無い
//   ↑ TKT-n  親の端末の pjp.ticket (無ければ親の space の名前。チケットの ID で始まる名前なら ID だけ)
//
// 3 行目から、解説動画を 1 本 1 行で出す (claude-skills の docs/superpowers/specs/2026-11-21-spaces-video-mark-design.md の §11):
//
//   🎬⏳:<名前>  解説動画を 1 本作っている (作り始めから、書き出して Notion に載せ終えるまで)
//   🎬✅:<名前>  解説動画を 1 本作り終えて載せたが、ユーザーがまだ見ていない。見たら (pjp mark video watched) 消える
//
//   どちらも label pjp.video.<作り始めた日時> (値は JSON。pjp mark video が付け外しする) で、名前はその name。会話の端末・その
//   手伝いの端末・子をたどった子孫とその手伝いの端末の動画を集め (👀 と同じ範囲)、⏳ を先、✅ を後に、それぞれ作り始めた順に
//   並べる。行の高さは動画の本数だけ増やす (1 行の高さと間は 2 行目と同じ)。space に会話が 2 つ以上いれば、会話ごとに集めた
//   動画をまとめて同じ順に並べる (同じ動画は 1 本。どの会話のものかはホバーで見る)
//
// - ❓ は status の done だけでは出さない: 文で問いを書いてターンを終えた会話も、子の報告や merge を待つ会話も done で、
//   見分けられない。文の問いは、ハブが問いを出してターンを終える直前に pjp mark asking で知らせる。子の ❓ は親の行へ伝えない
//   (子の行に出るし、子の blocked・error は hc が親に知らせる)
// - 手伝いの端末は 🌳[N] にも 🔄 にも数えない (会話の子ではない)
// - 1 つの space に会話が 2 つ以上いれば、会話ごとに address の後ろへ名札 (pjp.ticket・英字・名前の順に、あるもの。どれも無ければ
//   address だけで、二重に出さない) を付け、「 │ 」で区切る (例 `t53 TKT-n 🌳[2] │ t5k TKT-m 🌳[1]🔄`)。印の無い会話も
//   address と名札を出す。会話の並びは tab の順、同じ tab なら作った順 (address の順)
// - Claude Code が records に載せるのは動いている subagent だけ (裏の Bash・Monitor は載せない)。subagent が動いている間は、
//   ターンを終えても会話の status は working のまま (2026-11-17・18 に Claude Code 2.1.325 と Windows の 2.1.318 で見た) なので、
//   旧 herdr のように「止まった会話」に絞ると 👀 が出ない。会話の状態を問わず、裏の作業が動いていれば出す
// - terminals() の parent と address は、このマシンの端末なら素の ID、ほかのマシンなら <machine>/<ID>。label の herdr.space・
//   herdr.tab はそのマシンの中の id なので、ほかのマシンの端末では頭に <machine>/ を足して spaces() の id と比べる。label の
//   無い端末は、映っているペイン (panes()) から space を引く
// making・made は動画の行の頭 (後ろに「:<名前>」)
export const MARKS = { ask: "❓", child: "🌱", parent: "🌳", busy: "🔄", watch: "👀", making: "🎬⏳", made: "🎬✅", trash: "🗑\uFE0F", up: "↑" };
const ROLES = new Set(["hub", "child"]);
const TICKET = /^([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)*-[0-9]+)(?: |$)/;
const SEPARATOR = " │ ";
// pjp-spaces: ホバーに出す問いの要旨 (pjp.asking) と解説動画の名前の字数。pjp mark asking・video も、これより長いものには note を出す
const ASK_MAX = 60;
// pjp-spaces: 解説動画の印の label の名前の頭 (後ろは作り始めた日時。pjp mark video の LABEL_PREFIX)
const VIDEO_PREFIX = "pjp.video.";
// pjp-spaces: 2 行の行 (会話の端末がいる space) の高さ。1 行の行は元の rowHeight のまま
const rowHeight2 = ({ tree }) => (tree ? 42 : 44);
// pjp-spaces: 3 行目からの動画の行 1 本ぶんの高さ (2 行目と同じ、行の高さ 16 と行の間 1)。2 行の行に本数ぶん足す
const VIDEO_LINE = 17;
// pjp-spaces: 名前の幅を測る物差し (props の debug のときだけ出す)。半角は 10 字ごとに A・B…、全角は 10 字ごとに十・廿・卅・卌
export const RULERS = [
  "123456789A123456789B123456789C123456789D123456789E123456789F123456789G",
  "一二三四五六七八九十一二三四五六七八九廿一二三四五六七八九卅一二三四五六七八九卌",
];

const isLive = (x) => (x?.state ?? "live") === "live";
// 平らな語 (working・blocked・done・idle・error)。報告そのもの ({ state, … }) の形で来ても読む
const wordOf = (x) => (typeof x?.status === "string" ? x.status : (x?.status?.state ?? x?.report?.state ?? null));
const labelsOf = (x) => x?.labels ?? {};
const machineOf = (address) => {
  const at = String(address ?? "").lastIndexOf("/");
  return at < 0 ? null : String(address).slice(0, at);
};
// 報告のほかの記録 (hc の records は id → 記録)
const recordsOf = (x) => {
  const r = x?.records ?? x?.report?.records ?? null;
  return Array.isArray(r) ? r : Object.values(r ?? {});
};
// pjp-spaces: 解説動画の並び。作っているもの (⏳) を先、済んだもの (✅) を後に、それぞれ作り始めた順 (pjp mark video と同じ)
const byVideo = (a, b) =>
  (a.state === b.state ? 0 : a.state === "making" ? -1 : 1) ||
  (a.started < b.started ? -1 : a.started > b.started ? 1 : 0) ||
  (a.key < b.key ? -1 : a.key > b.key ? 1 : 0);

/**
 * pjp-spaces: 端末の解説動画の印 (label pjp.video.<id> の JSON の値)。読めない値 (JSON の object でない・state が making・done で
 * ない) は除く。名前・日時の改行と続く空白は 1 つの空白にする (ホバーは 1 本 1 行)。
 * @param {any} x terminals() の 1 件
 * @returns {{ key: string, name: string, state: "making" | "done", started: string, ended: string | null, from: string | null }[]}
 */
export function videosOf(x) {
  const out = [];
  for (const [key, raw] of Object.entries(labelsOf(x))) {
    if (!key.startsWith(VIDEO_PREFIX) || key.length === VIDEO_PREFIX.length || typeof raw !== "string") continue;
    let v;
    try {
      v = JSON.parse(raw);
    } catch {
      continue;
    }
    if (!v || typeof v !== "object" || Array.isArray(v) || (v.state !== "making" && v.state !== "done")) continue;
    const text = (k) => (typeof v[k] === "string" ? v[k].replace(/\s+/g, " ").trim() : "");
    out.push({ key, name: text("name") || key.slice(VIDEO_PREFIX.length), state: v.state, started: text("started"), ended: text("ended") || null, from: text("from") || null });
  }
  return out.sort(byVideo);
}
const hasVideoLabel = (x) => Object.keys(labelsOf(x)).some((k) => k.startsWith(VIDEO_PREFIX));
// 3 行目からの動画の行の文字 (🎬⏳:<名前>・🎬✅:<名前>。ユーザーが書いた形のまま、「:」の後ろに空白を置かない)
const videoText = (v) => `${v.state === "making" ? MARKS.making : MARKS.made}:${v.name}`;
// 同じ動画 (名前・作り始めた日時・状態が同じ) を 1 本にする。先に来たものを残す (videoOf で items の 1 件から動画を引く)
const once = (items, videoOf) => {
  const seen = new Set();
  return items.filter((item) => {
    const v = videoOf(item);
    const k = JSON.stringify([v.name, v.started, v.state]);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
};
// 2026-11-21T13:05:12+09:00 → 11/21 13:05 (読めなければそのまま。pjp mark video の short_time と同じ)
const shortTime = (iso) => {
  const m = /^\d{4}-(\d{2})-(\d{2})T(\d{2}:\d{2})/.exec(iso ?? "");
  return m ? `${Number(m[1])}/${Number(m[2])} ${m[3]}` : String(iso ?? "");
};

// 作った順。hc の address は t の後ろが 36 進の数 (t9・ta・t10) なので、桁の数、次に字の順で比べる
const byAddress = (a, b) => {
  const id = (x) => x.address.slice(x.address.lastIndexOf("/") + 1);
  const [p, q] = [id(a), id(b)];
  if (p.length !== q.length) return p.length - q.length;
  return p < q ? -1 : p > q ? 1 : a.address < b.address ? -1 : a.address > b.address ? 1 : 0;
};

/**
 * pjp-spaces: 会話の端末がいる space ごとの印。
 * @param {any[]} ts terminals()
 * @param {any[]} sp spaces()
 * @param {any[]} ps panes()
 * @returns {Map<string, { text: string, tip: string, count: number, videos: { state: "making" | "done", text: string, tip: string }[] }>}
 *   会話の端末がいる space だけ (印が 1 つも無くても入る)。text は 2 行目の文字 (会話ごとに頭へ端末の address)、tip は 2 行目の
 *   ホバーで出す会話ごとの説明 (1 会話 1 行。解説動画があれば、その下に字下げして 1 本 1 行)、count は会話の数、videos は 3 行目からの
 *   動画の行 (1 本 1 行。text はその行の文字 `🎬⏳:<名前>`、tip はその行のホバーで出すその動画の説明)
 */
export function spaceMarks(ts, sp, ps) {
  const all = (Array.isArray(ts) ? ts : []).filter((x) => x && typeof x.address === "string");
  const terminal = new Map(all.map((x) => [x.address, x]));
  const spaceById = new Map();
  const tabSpace = new Map();
  const tabIndex = new Map();
  for (const s of Array.isArray(sp) ? sp : []) {
    spaceById.set(s.id, s);
    for (const tab of s.tabs ?? []) {
      tabSpace.set(tab.id, s.id);
      tabIndex.set(tab.id, tab.index ?? 0);
    }
  }
  const paneAt = new Map();
  for (const p of Array.isArray(ps) ? ps : []) {
    if (p?.terminal && tabSpace.has(p.tab)) paneAt.set(p.terminal, { space: tabSpace.get(p.tab), tab: p.tab });
  }
  const placeOf = (x) => {
    const l = labelsOf(x);
    const m = machineOf(x.address);
    const qualify = (id) => (id && m && !String(id).startsWith(`${m}/`) ? `${m}/${id}` : id || null);
    if (l["herdr.space"]) return { space: qualify(l["herdr.space"]), tab: qualify(l["herdr.tab"]) };
    return paneAt.get(x.address) ?? null;
  };

  // 親ごとの、生きている子 (pjp.role が child) と、手伝いの端末 (pjp.role の無い生きている端末。hc run --bg で立てたもの)
  const kidsOf = new Map();
  const helpersOf = new Map();
  const push = (m, k, v) => (m.has(k) ? m.get(k).push(v) : m.set(k, [v]));
  for (const x of all) {
    if (!isLive(x) || !x.parent) continue;
    const role = labelsOf(x)["pjp.role"];
    if (role === "child") push(kidsOf, x.parent, x);
    else if (!ROLES.has(role)) push(helpersOf, x.parent, x);
  }
  const kids = (x) => kidsOf.get(x.address) ?? [];
  // 子孫 (子をたどる) のどれかが test に合うか。同じ端末は 2 度たどらない (親子が輪になっていても止まる)
  const someBelow = (x, test) => {
    const seen = new Set([x.address]);
    const todo = [...kids(x)];
    while (todo.length) {
      const k = todo.shift();
      if (seen.has(k.address)) continue;
      seen.add(k.address);
      if (test(k)) return true;
      todo.push(...kids(k));
    }
    return false;
  };
  // 裏の作業: 動いている subagent (records) と、working の手伝いの端末
  const working = (x) => recordsOf(x).filter((r) => r?.state === "working").length;
  const helping = (x) => (helpersOf.get(x.address) ?? []).filter((h) => wordOf(h) === "working").length;
  const backstage = (x) => working(x) + helping(x) > 0;
  // 端末ごとの解説動画の印 (label の JSON は描くたびに 1 端末 1 回だけ読む)
  const videoMemo = new Map();
  const videosAt = (x) => {
    if (!videoMemo.has(x.address)) videoMemo.set(x.address, videosOf(x));
    return videoMemo.get(x.address);
  };
  // 解説動画: 会話の端末・その手伝いの端末・子をたどった子孫とその手伝いの端末の印 (👀 と同じ範囲。同じ端末は 2 度数えない)
  const videosBelow = (x) => {
    const out = [];
    const seen = new Set();
    const take = (n) => {
      if (seen.has(n.address)) return;
      seen.add(n.address);
      for (const v of videosAt(n)) out.push({ ...v, holder: n });
    };
    const todo = [x];
    while (todo.length) {
      const n = todo.shift();
      if (seen.has(n.address)) continue;
      take(n);
      for (const h of helpersOf.get(n.address) ?? []) take(h);
      todo.push(...kids(n));
    }
    // 同じ動画の写し (名前・作り始めた日時・状態が同じ。片付けで親へ移した後に子を終えられなかったとき) は 1 本に数える
    return once(out.sort(byVideo), (v) => v);
  };
  const ticketOf = (x) => labelsOf(x)["pjp.ticket"] || null;
  const letterOf = (x) => labelsOf(x)["pjp.letter"] || null;
  // 文の問いの要旨 (pjp.asking)。説明は 1 会話 1 行なので、改行と続く空白は 1 つの空白にし、空白だけなら無いとみなす
  const askingOf = (x) => String(labelsOf(x)["pjp.asking"] ?? "").replace(/\s+/g, " ").trim();
  // ホバーに出す要旨は ASK_MAX 字まで (長い要旨で説明の行が伸びないように)
  const clip = (s) => ([...s].length > ASK_MAX ? `${[...s].slice(0, ASK_MAX).join("")}…` : s);
  // 動画の印がどの端末のものか (この会話・子 A <machine>/t92・TKT-n <machine>/t40・手伝いの端末 t60)
  const holderOf = (v, x) => {
    if (v.holder === x) return "この会話";
    const h = v.holder;
    const tag = letterOf(h) ? `子 ${letterOf(h)}` : (ticketOf(h) ?? (ROLES.has(labelsOf(h)["pjp.role"]) ? null : "手伝いの端末"));
    return [tag, h.address].filter(Boolean).join(" ");
  };
  // 1 本 1 行の説明 (pjp mark video の describe と同じ形。頭は動画の行と同じ 🎬⏳:<名前>)
  const videoLine = (v, x) => {
    const parts = [holderOf(v, x), v.state === "making" ? `${shortTime(v.started)} から作っている` : `${shortTime(v.ended || v.started)} に載せた・見ていない`];
    if (v.from) parts.push(`片付けた${v.from} から移した`);
    return `${videoText({ ...v, name: clip(v.name) })} (${parts.join("・")})`;
  };
  // 会話の名札と端末 (ホバーの会話の行の頭。TKT-n · t1m · 子 A)
  const whoOf = (x) => [ticketOf(x) ?? "チケットなし", x.address, letterOf(x) ? `子 ${letterOf(x)}` : null].filter(Boolean).join(" · ");
  const parentOf = (x) => (x.parent ? (terminal.get(x.parent) ?? null) : null);
  const upOf = (x) => {
    const p = parentOf(x);
    if (!p) return "";
    if (ticketOf(p)) return `${MARKS.up} ${ticketOf(p)}`;
    const name = String(spaceById.get(placeOf(p)?.space)?.name ?? "").trim();
    return name ? `${MARKS.up} ${name.match(TICKET)?.[1] ?? name}` : "";
  };

  // 会話のもと: pjp.role が hub か child、か生きている子がいる。会話の手伝いの端末 (pjp.role の無い、そういう端末を親に持つ端末) は、
  // 動画の印を持っていても自分の会話にしない (印は親の行に出る。同じ space に映っても二重に数えない)
  const convoBase = (x) => ROLES.has(labelsOf(x)["pjp.role"]) || kids(x).length > 0;
  const helperOfConvo = (x) => {
    if (ROLES.has(labelsOf(x)["pjp.role"]) || !x.parent) return false;
    const p = terminal.get(x.parent);
    return Boolean(p && isLive(p) && convoBase(p));
  };
  const convos = new Map();
  for (const x of all) {
    if (!isLive(x) || !(convoBase(x) || (videosAt(x).length > 0 && !helperOfConvo(x)))) continue;
    const at = placeOf(x);
    if (!at?.space || !spaceById.has(at.space)) continue;
    if (!convos.has(at.space)) convos.set(at.space, []);
    convos.get(at.space).push({ x, tab: at.tab });
  }

  const out = new Map();
  for (const [id, list] of convos) {
    list.sort((a, b) => (tabIndex.get(a.tab) ?? 0) - (tabIndex.get(b.tab) ?? 0) || byAddress(a.x, b.x));
    const many = list.length > 1;
    const texts = [];
    const tips = [];
    const found = []; // 動画の行のもと: 会話ごとに集めた動画と、集めた会話
    for (const { x } of list) {
      const n = kids(x).length;
      const word = wordOf(x);
      // ❓ で待っているもの (この端末だけを見る。子孫の分は親へ伝えない)
      const asking = askingOf(x);
      const waits = [word === "blocked" && "確認の画面", word === "error" && "エラーで止まっている", asking && `問い: ${clip(asking)}`].filter(Boolean);
      const busy = n > 0 && someBelow(x, (k) => wordOf(k) === "working");
      const self = backstage(x);
      const watched = self || someBelow(x, backstage);
      // 解説動画 (3 行目からの行に出す。2 行目には出さない)。作っているもの (⏳) が 1 つでもあれば 🗑️ を出さない (作っている
      // 間に閉じると止まる)
      const videos = videosBelow(x);
      const makingN = videos.filter((v) => v.state === "making").length;
      const madeN = videos.length - makingN;
      const finished = Boolean(labelsOf(x)["pjp.finished"]) && n === 0 && word !== "working" && waits.length === 0 && !watched && makingN === 0;
      const stat =
        (waits.length > 0 ? MARKS.ask : "") +
        (x.parent ? MARKS.child : "") +
        (n > 0 ? `${MARKS.parent}[${n}]${busy ? MARKS.busy : ""}` : "") +
        (watched ? MARKS.watch : "") +
        (finished ? MARKS.trash : "");
      const own = [stat, upOf(x)].filter(Boolean).join(" ");
      // 頭に会話の端末の address (印の有無を問わない)。会話が 2 つ以上なら、その後ろに名札 (address しか無ければ二重に出さない)
      const tag = many ? ticketOf(x) || letterOf(x) || x.name || null : null;
      texts.push([x.address, tag !== x.address && tag, own].filter(Boolean).join(" "));

      const p = parentOf(x);
      const facts = [];
      if (waits.length > 0) facts.push(`待っている (${waits.join("・")})`);
      if (x.parent) facts.push(`親 ${p ? (ticketOf(p) ?? p.address) : x.parent}`);
      if (n > 0) facts.push(`子 ${n} 人 (${kids(x).map((k) => letterOf(k) || k.address).join(" ")})`);
      if (busy) facts.push("動いている子孫がいる");
      if (self) {
        const parts = [working(x) ? `subagent ${working(x)}` : null, helping(x) ? `手伝いの端末 ${helping(x)}` : null];
        facts.push(`裏の作業が動いている (${parts.filter(Boolean).join("・")})`);
      } else if (watched) facts.push("裏の作業が動いている子孫がいる");
      if (videos.length > 0) facts.push(`解説動画 (${[makingN ? `作っている ${makingN}` : null, madeN ? `見ていない ${madeN}` : null].filter(Boolean).join("・")})`);
      if (finished) facts.push(`済んだ (${labelsOf(x)["pjp.finished"]})`);
      tips.push(`${whoOf(x)}: ${facts.length ? facts.join("、") : "印なし"}`);
      // 動画ごとの行 (状態・名前・どの端末か・時刻)。会話の行の下に字下げして 1 本 1 行
      for (const v of videos) {
        tips.push(`  ${videoLine(v, x)}`);
        found.push({ v, x });
      }
    }
    // 3 行目からの動画の行: space の会話の動画をまとめて、⏳ を先、✅ を後に、それぞれ作り始めた順 (会話が 2 つ以上でも 1 つの
    // 並び。同じ順なら会話の順)。同じ space の親子の会話から 2 度集まった動画と写しは 1 本。会話が 2 つ以上なら、行のホバーの
    // 頭にどの会話のものかを書く
    const videos = once(found.sort((a, b) => byVideo(a.v, b.v)), (f) => f.v).map(({ v, x }) => ({
      state: v.state,
      text: videoText(v),
      tip: many ? `${whoOf(x)}: ${videoLine(v, x)}` : videoLine(v, x),
    }));
    out.set(id, { text: texts.join(SEPARATOR), tip: tips.join("\n"), count: list.length, videos });
  }
  return out;
}

/**
 * pjp-spaces: 確かめ用 (props の debug): terminals() と spaces() のうち、印に使う値を 1 つ 1 行で。
 * @param {any[]} ts terminals()
 * @param {any[]} sp spaces()
 * @returns {string[]}
 */
export function debugLines(ts, sp) {
  const all = Array.isArray(ts) ? ts : [];
  const lines = [`terminals: ${all.length} (live ${all.filter(isLive).length}) keys: ${Object.keys(all[0] ?? {}).join(", ")}`];
  for (const s of Array.isArray(sp) ? sp : []) {
    lines.push(`space ${s.id} machine=${s.machine ?? "-"} name=${s.name} tabs=${(s.tabs ?? []).map((tab) => tab.id).join(",")}`);
  }
  // 会話 (pjp.role が hub か child の端末と、pjp.role が child の端末の親) と、解説動画の印 (pjp.video.<id>) のある端末
  const parents = new Set(all.filter((x) => labelsOf(x)["pjp.role"] === "child" && x.parent).map((x) => x.parent));
  for (const x of all) {
    const l = labelsOf(x);
    if (!ROLES.has(l["pjp.role"]) && !parents.has(x.address) && !hasVideoLabel(x)) continue;
    lines.push(JSON.stringify({ address: x.address, state: x.state, parent: x.parent ?? null, status: x.status ?? null, report: x.report ?? null, records: x.records ?? null, labels: l }));
    // 読んだ動画 (読めない値の label は上の labels にだけ出る)
    for (const v of videosOf(x)) lines.push(`video ${x.address} ${v.key}: ${v.state} ${v.started}${v.ended ? `〜${v.ended}` : ""}${v.from ? ` from ${v.from}` : ""} ${v.name}`);
  }
  return lines;
}

export default class Spaces extends View {
  init(_props, cx) {
    this.git = {}; // where() -> { name, branch, ahead, behind, repo, linked }, null: not a repo
    this.checked = {}; // where() -> when it was last looked at
    this.unsure = new Set(); // where()s git couldn't answer for (a machine away)
    this.pending = new Set(); // where()s to look at next
    this.busy = {}; // pane -> an agent working or a program in front of its shell
    this.ready = {}; // machine -> its layout was readable at the last look
    this.at = {}; // space -> its where() at the last look
    this.watching = new Map(); // local repos' pending folder watches
    // Spaces made while this runs wait (at most a moment) for their git, so a
    // worktree appears under its repo instead of jumping there.
    this.shown = new Set(spaces().map((s) => s.id));
    this.born = {};
    this.pressed = null;
    this.over = null;
    this.scroll = ScrollHandle.new(); // the list's position: the active space is brought into view through it
    this.activeAt = -1; // the active space's place among the list's children (headers and rows), -1 when not drawn
    this.machines = [];
    try {
      this.reconnecting = JSON.parse(localStorage.getItem("machines.reconnecting") ?? "{}");
      if (!this.reconnecting || typeof this.reconnecting !== "object" || Array.isArray(this.reconnecting)) this.reconnecting = {};
      for (const state of Object.values(this.reconnecting)) state.busy = false;
    } catch { this.reconnecting = {}; }
    try { this.folded = new Set(JSON.parse(localStorage.getItem("machines.folded") ?? "[]")); } catch { this.folded = new Set(); }
    this.refreshMachines(cx);
    cx.timer.every(15000, cx => this.refreshMachines(cx));
    // Refresh only when the refs could have changed (see `due`).
    cx.timer.every(250, (cx) => this.checkNew(cx));
  }

  checkNew(cx) {
    const now = Date.now();
    const sp = spaces();
    for (const s of sp) if (!this.shown.has(s.id)) this.born[s.id] ??= now;
    const due = this.due(now, sp, panes());
    if (due.size) this.refreshGit(due, cx);
    if (sp.some((s) => !this.shown.has(s.id)) || this.orderingDue(now)) cx.notify();
  }

  // Places whose git could have changed: new ones (a new space, a cd), where a
  // command or an agent's turn just ended (a checkout, a commit, edits), those on
  // a machine that is back, and repos in view whose fallback is due.
  due(now, sp, ps) {
    // Moved there: what it knew of that place may be old.
    const at = {};
    for (const s of sp) at[s.id] = where(s, ps);
    const keys = new Set(Object.values(at).filter((k) => JSON.parse(k)[1]));
    for (const k of Object.keys(this.git)) if (!keys.has(k)) {
      delete this.git[k];
      delete this.checked[k];
      this.unsure.delete(k);
    }
    const repos = new Set(Object.values(this.git).filter(Boolean).map((g) => g.repo));
    for (const [repo, pending] of this.watching) if (!repos.has(JSON.stringify([null, repo]))) {
      this.watching.delete(repo);
      pending.cancel();
    }
    const due = new Set([...keys].filter((k) => !(k in this.git)));
    for (const [id, k] of Object.entries(at)) if (this.at[id] && this.at[id] !== k && keys.has(k)) due.add(k);
    this.at = at;
    const spaceOf = {};
    for (const s of sp) for (const t of s.tabs ?? []) spaceOf[t.id] = s;
    const busy = {};
    for (const p of ps) {
      if (!p.terminal || !spaceOf[p.tab]) continue;
      busy[p.pane] = p.status === "working" || !(p.program?.shell || p.program?.agent);
      if (this.busy[p.pane] && !busy[p.pane]) this.sameRepo(at[spaceOf[p.tab].id], keys).forEach((k) => due.add(k));
    }
    this.busy = busy;
    for (const m of machines()) {
      const ready = m.layout === "ready";
      if (ready && this.ready[m.name] === false) for (const k of keys) if (JSON.parse(k)[0] === m.name) due.add(k);
      this.ready[m.name] = ready;
    }
    if (window().active) {
      for (const k of keys) {
        const asks = this.git[k] || this.unsure.has(k);
        if (asks && !this.folded.has(JSON.parse(k)[0]) && now - (this.checked[k] ?? 0) > FALLBACK) due.add(k);
      }
    }
    return due;
  }

  // `key` and the other places in its repo (a commit there moves their ahead/behind).
  sameRepo(key, keys) {
    const repo = this.git[key]?.repo;
    return [key, ...(repo ? [...keys].filter((k) => this.git[k]?.repo === repo) : [])];
  }

  refreshMachines(cx) {
    cx.spawn(async cx => {
      try { const r = await hc(["machine", "ls", "--json"]); if (r.code === 0) this.machines = (JSON.parse(r.stdout).machines ?? []).filter((m) => !m.temporary); } catch {}
      cx.notify();
    });
  }

  rebuilt(machine) {
    return machine?.state === "unreachable" && /^a different core answers there \("[^"]+"\)$/.test(machine.why ?? "");
  }

  reconnect(machine, cx) {
    const name = machine.name;
    if (this.reconnecting[name]?.busy) return;
    const state = this.reconnecting[name] ??= { machine, removed: false };
    state.busy = true;
    state.error = null;
    localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
    cx.notify();
    cx.spawn(async cx => {
      try {
        const ask = async args => {
          const r = await hc([...args, "--json"]);
          if (r.code !== 0) {
            let error;
            try { error = JSON.parse(r.stdout || r.stderr).error?.message; } catch {}
            throw new Error(error || r.stderr || r.stdout || "Couldn't connect.");
          }
        };
        if (!state.removed) {
          await ask(["machine", "rm", name]);
          state.removed = true;
          localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
        }
        const args = ["machine", "add"];
        if (machine.via) args.push("--via", machine.target);
        else args.push(machine.target);
        args.push("--name", name);
        if (machine.session) args.push("--session", machine.session);
        if (machine.temporary) args.push("--temp");
        await ask(args);
        this.folded.delete(name);
        localStorage.setItem("machines.folded", JSON.stringify([...this.folded]));
        delete this.reconnecting[name];
      } catch (e) {
        state.error = String(e.message ?? e);
        state.busy = false;
      }
      localStorage.setItem("machines.reconnecting", JSON.stringify(this.reconnecting));
      this.refreshMachines(cx);
      cx.notify();
    });
  }

  // One look at a time, each place once however often it was asked for meanwhile.
  refreshGit(keys, cx) {
    for (const k of keys) this.pending.add(k);
    if (this.refreshing) return;
    this.refreshing = true;
    cx.spawn(async (cx) => {
      while (this.pending.size) {
        const keys = [...this.pending];
        this.pending.clear();
        let next = 0;
        await Promise.all(Array.from({ length: Math.min(AT_ONCE, keys.length) }, async () => {
          while (next < keys.length) await this.check(keys[next++], cx);
        }));
      }
      this.refreshing = false;
      cx.notify();
    });
  }

  // One place's git: branch, ahead/behind, its repo.
  async check(key, cx) {
    const [on, cwd] = JSON.parse(key);
    this.checked[key] = Date.now();
    this.unsure.delete(key);
    try {
      // Ref-only reads avoid scanning the worktree or waking its index watch.
      // Two reads: a folder name may itself contain a newline.
      const [r, common] = await both(
        exec("git", ["rev-parse", "--path-format=absolute", "--show-toplevel"], { cwd, on }),
        exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, on }),
      );
      if (r.code !== 0 || common.code !== 0) {
        // Only git's own "no" is remembered as no repo; anything else is asked again.
        if (!/not a git repository/i.test(r.code !== 0 ? r.stderr : common.stderr)) {
          this.unsure.add(key);
          this.git[key] ??= null;
        } else this.git[key] = null;
        return;
      }
      // The repo's own .git folder names it; a worktree's top differs from it.
      const top = r.stdout.replace(/\n$/, ""), repo = common.stdout.replace(/\n$/, "");
      const [branch, counts] = await both(
        exec("git", ["symbolic-ref", "-q", "HEAD"], { cwd, on }),
        exec("git", ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], { cwd, on }),
      );
      const name = repo.endsWith("/.git") ? base(repo.slice(0, -5)) : base(repo).replace(/\.git$/, "");
      const [ahead, behind] = counts.code === 0 ? counts.stdout.trim().split(/\s+/).map(Number) : [0, 0];
      const info = { name, branch: branch.code === 0 ? branch.stdout.trim().replace(/^refs\/heads\//, "") : "(detached)", ahead, behind, repo: JSON.stringify([on, repo]), linked: repo !== `${top}/.git` };
      this.git[key] = info;
      if (!on) this.watch(repo, cx);
    } catch {
      // Couldn't ask (the machine is away): keep what it showed, look again later.
      this.git[key] ??= null;
      this.unsure.add(key);
    }
  }

  watch(repo, cx) {
    if (this.watching.has(repo)) return;
    const pending = watchFolder(repo);
    this.watching.set(repo, pending);
    cx.spawn(async (cx) => {
      let current = pending;
      try {
        for (;;) {
          await current;
          if (this.watching.get(repo) !== current) return;
          const mine = JSON.stringify([null, repo]);
          const keys = Object.keys(this.git).filter((k) => this.git[k]?.repo === mine);
          if (!keys.length) break;
          this.refreshGit(keys, cx);
          current = watchFolder(repo);
          this.watching.set(repo, current);
        }
      } catch {}
      if (this.watching.get(repo) === current) this.watching.delete(repo);
    });
  }

  menu(w) {
    // A popup is as tall as its items; height is only the most.
    openOverlay({ mod: "menu", kind: "popup", width: 200, height: 260, props: { tab: "space", target: { id: w.id } } });
  }

  orderingDue(now) {
    return this.ordering && now - this.ordering.at >= 1000
      && this.ordering.machines.every(name => machines().some(m => m.name === name && m.layout === "ready"));
  }

  // Spaces in order, each worktree space moved under its main checkout's.
  ordered() {
    const sp = spaces(), ps = panes();
    const ready = (w) => this.shown.has(w.id) || where(w, ps) in this.git || Date.now() - (this.born[w.id] ??= Date.now()) > 1500;
    for (const w of sp) if (!this.shown.has(w.id) && ready(w)) this.shown.add(w.id);
    const list = sp.map((w, i) => ({ w, i, g: this.git[where(w, ps)] ?? null }));
    const mains = new Set(list.filter((r) => r.g && !r.g.linked).map((r) => r.g.repo));
    const nested = (r) => r.g?.linked && mains.has(r.g.repo);
    const out = [];
    const placed = new Set(); // repos whose worktrees are listed (under the first of its spaces)
    for (const r of list) {
      if (nested(r)) continue;
      out.push({ ...r, tree: null });
      if (!r.g || r.g.linked || placed.has(r.g.repo)) continue;
      placed.add(r.g.repo);
      const kids = list.filter((k) => nested(k) && k.g.repo === r.g.repo);
      kids.forEach((k, n) => out.push({ ...k, tree: n === kids.length - 1 ? "└─" : "├─" }));
    }
    // Simulate the batch so later indexes include earlier moves. An attempted
    // write can lose a sync conflict: allow the echo to settle before retrying.
    const order = sp.map(w => w.id);
    const target = out.map(r => r.w.id);
    const key = JSON.stringify([order, target, machines()]);
    if (order.every((id, i) => id === target[i])) {
      this.ordering = null;
    } else if (this.ordering?.key !== key || this.orderingDue(Date.now())) {
      const moved = new Set();
      this.ordering = { key, at: Date.now(), machines: [] };
      for (let i = 0; i < out.length; i++) {
        const from = order.indexOf(out[i].w.id);
        if (from === i) continue;
        run("space.move", { id: out[i].w.id, index: i + 1 });
        moved.add(out[i].w.machine ?? null);
        order.splice(i, 0, order.splice(from, 1)[0]);
      }
      this.ordering.machines = [...moved];
    }
    return out.filter(r => this.shown.has(r.w.id));
  }

  // The rows, under a header per machine once one isn't this computer.
  grouped(t, collapsed) {
    const rows = this.ordered();
    const draw = (r) => (collapsed ? this.compact(r, t) : this.row(r, t));
    // Where the active space's row lands among the children this returns: the list scrolls by its direct
    // children, and machine headers, login notes and loading rows count too.
    this.activeAt = -1;
    let before = 0;
    const remote = [...new Set([...rows.map(r => r.w.machine).filter(Boolean), ...this.machines.map(m => m.name), ...Object.keys(this.reconnecting)])].sort();
    const loading = m => {
      const layout = machines().find(k => k.name === m)?.layout;
      return layout === "loading" || (!layout && this.machines.some(k => k.name === m && k.state === "connected"))
        || spaces().some(s => (s.machine ?? null) === m && !this.shown.has(s.id));
    };
    const loadingRow = m => h_flex().id(`machine-loading-${m ?? "local"}`).h(28).flex_none().px(collapsed ? 0 : 8).items_center().when(collapsed, el => el.justify_center()).text_size(12).text_color(t.dim).child(collapsed ? "…" : "Loading…");
    if (!remote.length) {
      if (loading(null) && !rows.length) return [loadingRow(null)];
      this.activeAt = rows.findIndex(r => r.w.active);
      return rows.map(draw);
    }
    const machineNames = [null, ...remote];
    return machineNames.flatMap((m) => {
      const mine = rows.filter((r) => (r.w.machine ?? null) === m);
      const repair = this.reconnecting[m];
      const machine = this.machines.find(k => k.name === m) ?? repair?.machine;
      const connected = !m || machine?.state === "connected";
      const rebuilt = this.rebuilt(machine) || !!repair;
      const login = machine?.state === "needs_login" ? `hc machine login ${m}` : null;
      const folded = this.folded.has(m);
      const icon = svg(`mods/workspace-chrome/${m ? "server" : "monitor"}.svg`).size(13).flex_none();
      const badge = div().absolute().right(-3).bottom(-2).size(6).rounded(3).border_1().border_color(t.chrome).bg(connected ? t.ansi2 : t.dim);
      const head = h_flex().id(`machine-${m ?? "local"}`).h(26).flex_none().px(collapsed ? 0 : 8).gap(7).items_center().text_size(11).text_color(t.dim)
        .when(collapsed, el => el.mt(4).w(RAIL_CELL).justify_center().rounded(6).tooltip(login ? `${m} needs a login: run ${login}. Click for Copy.` : m ? `${m} · ${connected ? "connected" : (machine?.state ?? "asleep").replace(/_/g, " ")}` : "This computer"))
        .cursor_pointer().hover(s => s.bg(t.hover))
        .on_click((_e, cx) => {
          if (collapsed && login) { run("app.settings", { section: "machines" }); return; }
          folded ? this.folded.delete(m) : this.folded.add(m);
          localStorage.setItem("machines.folded", JSON.stringify([...this.folded]));
          cx.notify();
        })
        .when(machine?.keeps_running_after_logout === false, el => el.child(div().id(`machine-logout-${m}`)
          .flex_none().text_color(t.blocked).tooltip("Agents stop when you disconnect. Click for the fix.")
          .on_click((_e, cx) => { cx.stop_propagation(); openOverlay({ mod: "machine-add", kind: "dialog", width: 560 }); }).child("⚠")))
        .when(!collapsed, el => el.child(icon))
        .when(collapsed, el => el.child(div().relative().flex_none().child(icon).when(Boolean(m), el => el.child(badge))))
        .when(!collapsed, el => el.child(div().flex_1().truncate().child(m ?? "This computer"))
          .when(!connected && !rebuilt && !login, el => el.child(div().flex_none().child((machine?.state ?? "asleep").replace(/_/g, " "))))
          .when(rebuilt, el => el.child(h_flex().flex_none().gap(3).items_center()
            .child(div().max_w(140).truncate().child(repair?.error || "rebuilt ·"))
            .child(div().id(`machine-connect-${m}`).text_color(repair?.error ? t.blocked : t.muted)
              .hover(s => s.text_color(t.foreground))
              .tooltip(repair?.error || "This machine was rebuilt or replaced. Click to connect to the new one.")
              .on_click((_e, cx) => { cx.stop_propagation(); this.reconnect(machine, cx); })
              .child(repair?.busy ? "Connecting…" : "Connect"))))
          .when(connected, el => el.child(div().id(`machine-add-${m ?? "local"}`).flex_none().px(4).rounded(4).hover(s => s.bg(t.hover).text_color(t.foreground))
            .on_click((_e, cx) => { cx.stop_propagation(); run("space.new", { machine: m ?? "" }); }).child("+")))
          .child(div().size(6).rounded(3).flex_none().bg(connected ? t.ansi2 : t.dim))
          .child(svg(`mods/workspace-chrome/chevron-${folded ? "right" : "down"}.svg`).size(11).flex_none()));
      const empty = h_flex().id(`machine-new-${m ?? "local"}`).h(28).flex_none().px(collapsed ? 0 : 8).gap(7).items_center().rounded(7)
        .text_size(12).text_color(t.dim).hover(s => s.bg(t.hover).text_color(t.foreground))
        .on_click(() => run("space.new", { machine: m ?? "" }))
        .when(collapsed, el => el.w(RAIL_CELL).rounded(6).justify_center().tooltip(`New space on ${m ?? "this computer"}`)
          .child(h_flex().size(18).rounded(5).border_1().border_color(t.dim).items_center().justify_center()
            .child(svg("mods/workspace-chrome/plus.svg").size(10))))
        .when(!collapsed, el => el.child(svg("mods/workspace-chrome/plus.svg").size(12)).child("New space there"));
      if (!collapsed && rebuilt) { before += 1; return [head]; }
      const cell = collapsed ? railCell : (el) => el;
      const guidance = !collapsed && login ? [v_flex().px(8).pb(6).gap(3).flex_none()
        .child(div().text_size(11).text_color(t.blocked).child("needs a login: run"))
        .child(h_flex().gap(5).items_center()
          .child(div().flex_1().min_w(0).truncate().tooltip(login).text_size(11).text_color(t.muted).child(login))
          .child(div().id(`machine-login-copy-${m}`).flex_none().px(5).py(2).rounded(4)
            .text_size(11).text_color(t.foreground).bg(t.raised).cursor_pointer().hover(s => s.bg(t.hover))
            .on_click((_e, cx) => { cx.stop_propagation(); cx.write_to_clipboard(login); this.copiedLogin = login; cx.notify(); })
            .child(this.copiedLogin === login ? "Copied" : "Copy")))] : [];
      const items = [cell(head), ...guidance, ...(folded ? [] : mine.length ? mine.map(draw) : [loading(m) ? loadingRow(m) : cell(empty)])];
      const first = folded ? -1 : mine.findIndex(r => r.w.active);
      if (first >= 0) this.activeAt = before + 1 + guidance.length + first;
      before += items.length;
      return items;
    });
  }

  // Only what's unusual, after the name: "herdr \u00b7 spike \u21912 \u21931". The repo or
  // branch goes when the name already says it (a worktree is named after its branch),
  // and master/main go: nearly every space is on one. When the row is full, it
  // and the name both start from their text's width and give way in proportion.
  gitTail(g, tree, name, t) {
    const raw = g.branch ?? "detached";
    const same = (a) => a.toLowerCase() === name.toLowerCase();
    const branch = same(raw) || raw === "master" || raw === "main" ? "" : raw;
    const repo = tree || same(g.name) ? "" : g.name;
    const where = [repo, branch].filter(Boolean).join(" \u00b7 ");
    return h_flex()
      .flex_auto()
      .min_w(where ? SIDE_MIN : 0)
      .gap(5)
      .justify_end()
      .items_center()
      .text_size(11.5)
      .text_color(t.dim)
      .when(Boolean(where), (el) => el.child(div().min_w(0).truncate().child(where)))
      .when(g.ahead > 0, (el) => el.child(div().flex_none().text_color(t.ansi2).child(`\u2191${g.ahead}`)))
      .when(g.behind > 0, (el) => el.child(div().flex_none().text_color(t.ansi1).child(`\u2193${g.behind}`)));
  }

  row({ w, i, g, tree }, t) {
    const on = w.active;
    const fromIndex = this.pressed === null ? -1 : spaces().findIndex(s => s.id === this.pressed);
    const colors = shared("space.colors") ?? {};
    const color = colors[w.id] ?? "ansi6";
    const fill = color.startsWith("#") ? color : (MARK[color] ?? t[color]);
    // pjp-spaces: 会話の端末がいる space の印 (無ければ元の 1 行の行) と、3 行目からの動画の行
    const marks = this.marks?.get(w.id) ?? null;
    const videos = marks?.videos ?? [];
    return v_flex()
      .relative()
      .id(`space-${w.id}`)
      .px(8)
      .h(marks ? rowHeight2({ tree }) + VIDEO_LINE * videos.length : rowHeight({ tree })) // pjp-spaces: 2 行の行は高くし、動画の行の分も足す
      .flex_none()
      .justify_center()
      .rounded(8)
      .when(on, (el) => el.bg(t.selected))
      .when(!on, (el) => el.hover((s) => s.bg(t.hover)))
      .when(this.pressed === w.id && this.over !== w.id, (el) => el.opacity(0.5))
      .when(this.pressed !== null && this.over === w.id && this.pressed !== w.id, (el) => el.child(
        div().absolute().left(0).right(0).h(2).bg(t.accent)
          .when(fromIndex < i, line => line.bottom(0))
          .when(fromIndex > i, line => line.top(0)),
      ))
      .on_mouse_down("left", () => {
        this.pressed = w.id;
        this.over = w.id;
      })
      .on_mouse_move((_e, cx) => {
        const source = spaces().find(s => s.id === this.pressed);
        const over = source && (source.machine ?? null) === (w.machine ?? null) ? w.id : null;
        if (this.pressed !== null && this.over !== over) {
          this.over = over;
          cx.notify();
        }
      })
      .on_mouse_up("left", (_e, cx) => {
        const from = this.pressed;
        const over = this.over;
        this.pressed = null;
        this.over = null;
        if (from !== null && over === w.id && from !== w.id) {
          const index = spaces().findIndex(s => s.id === w.id);
          if (index !== -1) run("space.move", { id: from, index: index + 1 });
        } else if (from === w.id) run("space.select", { id: w.id });
        cx.notify();
      })
      .on_mouse_down("right", () => this.menu(w))
      // pjp-spaces: 2 行の行。1 行目に名前を幅いっぱいまで、2 行目に会話の印と、元は 1 行目にあった git を出す。3 行目から動画を 1 本 1 行
      .when(Boolean(marks), (el) => el.gap(1).child(this.nameLine(w, tree, fill, t)).child(this.markLine(marks, g, tree, w.name, t))
        .children(videos.map((v) => this.videoRow(v, tree, t))))
      .when(!marks, (el) => el.child(
        h_flex()
          .gap(9)
          .items_center()
          .when(Boolean(tree), el => el.pl(22).child(svg("mods/workspace-chrome/branch.svg").size(13).flex_none().text_color(t.dim)))
          .when(!tree, el => el.child(h_flex().size(18).flex_none().rounded(5).bg(fill).items_center().justify_center().text_size(10.5).font_bold().text_color("#ffffff").child([...w.name][0]?.toUpperCase() ?? "?")))
          .child(div().flex_initial().min_w(SIDE_MIN).truncate().text_color(t.foreground).child(w.name))
          .child(g ? this.gitTail(g, tree, w.name, t) : div().flex_1()),
      ));
  }

  // pjp-spaces: 2 行の行の 1 行目。印 (avatar か worktree の枝) と名前。名前は元の 1 行の行のように git と幅を分け合わず、行の幅いっぱいまで出す。
  // 行の高さは字の大きさから決めずに px で決める (既定は字の大きさの約 1.6 倍で、2 行が高さ 42・44 の行に収まりきらない)
  nameLine(w, tree, fill, t) {
    return h_flex()
      .h(18)
      .line_height("18px")
      .gap(9)
      .items_center()
      .when(Boolean(tree), el => el.pl(22).child(svg("mods/workspace-chrome/branch.svg").size(13).flex_none().text_color(t.dim)))
      .when(!tree, el => el.child(h_flex().size(18).flex_none().rounded(5).bg(fill).items_center().justify_center().text_size(10.5).font_bold().text_color("#ffffff").child([...w.name][0]?.toUpperCase() ?? "?")))
      .child(div().flex_1().min_w(0).truncate().text_color(t.foreground).child(w.name));
  }

  // pjp-spaces: 2 行の行の 2 行目。左に会話の端末の address と印 (ホバーで会話ごとの説明)、右に元の 1 行目の git (repo・branch・ahead/behind)。
  // 字下げは 1 行目の名前の頭に合わせる (avatar 18 + gap 9、worktree の行は pl 22 + 枝 13 + gap 9)。
  // git は元 (0.1.16) の gitTail の flex_auto・min_w(48) を flex_1・min_w(0) に戻し、印が字の幅を取った残りに出す。元の
  // flex_auto は 1 行の行で名前と git が字の幅の比で譲り合う形で、そのままでは長い branch に印が削られる
  markLine(marks, g, tree, name, t) {
    return h_flex()
      .h(16)
      .line_height("16px")
      .pl(tree ? 44 : 27)
      .gap(8)
      .items_center()
      .text_size(11.5)
      .child(div().flex_shrink(1).min_w(0).truncate().text_color(t.muted).when(Boolean(marks.text), (el) => el.tooltip(marks.tip)).child(marks.text))
      .child(g ? this.gitTail(g, tree, name, t).flex_1().min_w(0) : div().flex_1());
  }

  // pjp-spaces: 3 行目からの動画の行 (1 本 1 行。🎬⏳:<名前>・🎬✅:<名前>)。字下げ・字の大きさ・行の高さは 2 行目に合わせ、長い名前は
  // 行の幅で … にする。字の色は、作っている間 (⏳) がテーマの ansi3 (黄)、見ていない間 (✅) が ansi2 (緑)。ホバーでその動画の説明
  // (どの端末か・時刻)
  videoRow(v, tree, t) {
    return h_flex()
      .h(16)
      .line_height("16px")
      .pl(tree ? 44 : 27)
      .items_center()
      .text_size(11.5)
      .child(div().flex_1().min_w(0).truncate().text_color(v.state === "making" ? t.ansi3 : t.ansi2).tooltip(v.tip).child(v.text));
  }

  compact({ w, i }, t) {
    // pjp-spaces: 細い表示 (rail) には 2 行目と動画の行が無いので、ホバーで名前の下に会話の印と動画の行を出す
    const marks = this.marks?.get(w.id);
    const tip = marks ? [marks.text, ...marks.videos.map((v) => v.text)].filter(Boolean) : [];
    return railCell(h_flex()
      .id(`space-${w.id}`)
      .relative()
      .w(RAIL_CELL)
      .h(26)
      .rounded(6)
      .justify_center()
      .items_center()
      .when(w.active, (el) => el.bg(t.selected))
      .when(!w.active, (el) => el.hover((s) => s.bg(t.hover)))
      .on_click(() => run("space.select", { id: w.id }))
      .when(tip.length > 0, (el) => el.tooltip([w.name, ...tip].join("\n"))) // pjp-spaces
      .child(div().text_color(w.active ? t.foreground : t.muted).child(String(i + 1)))
      .child(div().absolute().right(5).text_color(tone(t, w.status)).child(glyph(w.status))));
  }

  render() {
    const t = theme();
    const collapsed = narrow();
    const palette = ["ansi6", "ansi3", "ansi4", "ansi5", "ansi2", "ansi1"];
    const sp = spaces();
    const ids = new Set(sp.map(p => p.id));
    const kept = Object.fromEntries(Object.entries(shared("space.colors") ?? {}).filter(([id]) => ids.has(id)));
    let changed = Object.keys(kept).length !== Object.keys(shared("space.colors") ?? {}).length;
    for (const p of sp) {
      if (kept[p.id] || p.name === "~") continue;
      const uses = c => Object.values(kept).filter(v => v === c).length;
      kept[p.id] = palette.reduce((best, c) => uses(c) < uses(best) ? c : best);
      changed = true;
    }
    if (changed) setShared("space.colors", kept);
    // pjp-spaces: 会話の印は描くたびに terminals() から作り直す (生きたデータなので、端末が変わると描き直る)。row・compact が読む
    // ので、一覧 (grouped) を作るより前に作る
    this.marks = spaceMarks(terminals(), sp, panes());
    // pjp-spaces: 確かめ用の props。debug は物差しと生の値を出し、width (px) はその幅で並べる (ペインで sidebar の幅を写す)
    const debug = Boolean(props()?.debug);
    const width = Number(props()?.width) || 0;
    const list = this.grouped(t, collapsed);
    // pjp-spaces: debug の物差しは一覧の子の先頭に 1 つ入るので、スクロールで見せる表示中の space の位置をその分ずらす
    if (debug && !collapsed && this.activeAt >= 0) this.activeAt += 1;
    // Bring the active space into view when it, or its place in the list, changes; a row already in view stays put.
    const active = sp.find(p => p.active)?.id;
    if (active !== this.revealed || this.activeAt !== this.revealedAt) {
      this.revealed = active;
      this.revealedAt = this.activeAt;
      if (this.activeAt >= 0) this.scroll.scroll_to_item(this.activeAt);
    }
    return v_flex().id("pjp-spaces").size_full().min_h(0).bg(t.chrome).text_size(13)
      .when(width > 0, (el) => el.w(width).flex_none()) // pjp-spaces
      // A block above (another mod's) growing, or the window resizing, shrinks this list and can push the active space out.
      // pjp-spaces: 元 (0.1.16) は、この on_size_change を下の一覧 (overflow_y_scrollbar の要素) に付けていた。一覧の要素の大きさは
      // 中身の高さでも替わり、解説動画の行が増減して行の高さが替わるたびに、ユーザーがスクロールした一覧が表示中の space の行へ戻った
      // (2026-11-22 に Windows の herdr-app 0.1.16 で見た)。mod の大きさは root の on_size_change で取る (gpui-kit.d.ts の
      // props の注) ので root に移した。root の大きさは、上のほかの mod の領域が伸びたときと窓の大きさが替わったときに替わる
      .on_size_change((_size, cx) => { if (this.activeAt >= 0) { this.scroll.scroll_to_item(this.activeAt); cx.notify(); } })
      .child(h_flex().h(31).pl(16).pr(10).items_center().justify_between().text_size(11.5).text_color(t.dim)
        .when(collapsed, el => el.pl(0).pr(0).justify_center())
        .when(!collapsed, el => el.child("Spaces"))
        .child(div().id("space-new").size(26).flex_none().flex().items_center().justify_center().rounded(6).hover(s => s.bg(t.hover).text_color(t.foreground))
          .on_click(() => run("space.new")).child(svg("mods/workspace-chrome/plus.svg").size(14))))
      .child(v_flex().flex_1().min_h(0).px(collapsed ? 0 : 8).pb(14).overflow_y_scrollbar().mode("always").track_scroll(this.scroll)
        .on_mouse_up("left", (_e, cx) => { this.pressed = null; cx.notify(); })
        .when(debug && !collapsed, (el) => el.child(this.rulerView(t))) // pjp-spaces
        .children(list)
        .when(debug, (el) => el.child(this.debugView(t)))); // pjp-spaces
  }

  // pjp-spaces: props の debug のとき、一覧の上に名前と動画の行の幅を測る物差しの行を出す。動画が 1 本ある行と同じ形 (1 行目に
  // 名前、2 行目に物差しの説明、3 行目に動画の行) で、上の 2 本は字下げの無い行、下の 2 本は worktree の行 (枝の分だけ字下げ)
  rulerView(t) {
    const row = (name, tree) => v_flex()
      .px(8)
      .h(rowHeight2({ tree }) + VIDEO_LINE)
      .flex_none()
      .justify_center()
      .gap(1)
      .child(this.nameLine({ name }, tree, MARK.ansi4, t))
      .child(this.markLine({ text: `物差し (${tree ? "worktree の行" : "字下げの無い行"}・${[...name].length} 字。3 行目は動画の行)`, tip: "名前と動画の行の幅を測る物差し" }, null, tree, name, t))
      .child(this.videoRow({ state: "making", text: videoText({ state: "making", name }), tip: "動画の行の幅を測る物差し (🎬⏳: の後ろが名前の字)" }, tree, t));
    return v_flex().pb(6).children([row(RULERS[0], null), row(RULERS[1], null), row(RULERS[0], "└─"), row(RULERS[1], "└─")]);
  }

  // pjp-spaces: props の debug が true のときだけ、一覧の下に印に使う生の値を出す (Windows での確かめ用。layout の sidebar には
  // props を付けないので出ない)
  debugView(t) {
    return v_flex()
      .mt(12)
      .px(8)
      .gap(4)
      .text_size(10.5)
      .text_color(t.dim)
      .children(debugLines(terminals(), spaces()).map((line) => div().child(line)));
  }
}
