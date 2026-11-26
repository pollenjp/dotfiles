// pjp-sidebar-tabs: 左のサイドパネルの上端に、Spaces と Agents を切り替えるアイコンのタブを描く、layout の stack の header の mod。
// 選んでいるタブはアイコン + 名前 (薄い地の角丸)、ほかはアイコンだけ (hover で名前)。Agents のタブには、確認の画面で止まっている (status が
// blocked の) agent の数を赤い丸の数の印で出す (0 なら出さない)。
//
// layout (dotfiles の runner の herdr-app-pjp-spaces が、同梱の main の column sidebar-lists をこの形にして layout pjp-main に書く):
//
//   { "id": "sidebar-lists", "type": "stack", "active": "spaces",
//     "header": { "content": { "mod": "pjp-sidebar-tabs", "props": { "stack": "sidebar-lists" } }, "height": 36 },
//     "children": [ { "id": "spaces", …, "content": { "mod": "pjp-spaces" } }, { "id": "agents", …, "content": { "mod": "agents" } } ] }
//
// herdr-app 0.1.16 の決まり (AGENTS.md と、本体 (herdrdev/herdr-app の v0.1.16) の src/window.rs・layout_sync.rs・mods.rs で確かめた):
// - stack の header の mod が受けるのは layout に書いた props だけで、どの stack の header かは渡らない。props の stack で受け、無ければ
//   sidebar-lists とみる
// - 出ている子は layout() の stack の node の active。active が無い・隠れた子を指すときは、隠れていない最初の子 (本体の active_child と同じ)
// - layout() を読んだ copy は layout が変わると描き直る。押した後も、ほかの手 (コマンドの layout.select・clicks の復元・layout のファイルの
//   書き直し) で替わっても、描き直しで追いつく。agents() も同じ (agent の状態が変わると描き直る)。なので timer は回さない
// - 押すと layout.select {stack, child}。選んだ子は herdr-app が clicks (layouts\.state\) に残し、再起動をまたぐ。layout のファイルの active
//   (runner が書く spaces) が前と変わらない限り、ファイルを書き直しても clicks の選んだ子が残る
// - キーでも替わる: dotfiles の keys.json の section layout:pjp-main が、Ctrl+Shift+← / → に同じ layout.select (child は spaces / agents) を
//   当てる (runner の herdr-app-keys が書き足す)。この mod は命令を受けず、layout の描き直しで追いつく
// - herdr-app は出ていない slot の copy を描かない (一度も出していなければ起こしもしない)。同梱の agents は描くときにだけ setAgentOrder を呼んで
//   agent.next・agent.prev が辿る順 (一覧の順) を渡すので、agents の子を隠している間は順が届かず、space・tab の順に落ちる (prefix の小窓の
//   Shift+O = agent.next が、確認待ちを先に辿らなくなる)。そこで stack に agents の子があって出ていない間は、この mod が同梱の agents の並べ方に
//   寄せた順を渡す (agentOrder。Agents を出している間は同梱の agents が渡すので渡さない)
//
// 見た目: 色は theme() の名前 (帯は chrome、選んだタブの地は selected、hover は hover、数の印の地は blocked)。数の印の数字は、blocked の地の
// 上で theme の foreground と background のうち明るさの差 (コントラスト比) が大きい方。sidebar が 160px 未満 (rail。同梱の spaces・agents と
// 同じ見分け方) では、タブを小さなアイコンだけにし、数の印は点にする (数は tooltip)。名前とアイコンを知らない子 (layout に足した 3 つ目の子
// など) は、layout の title (無ければ id) を字で出す。
//
// 配る: dotfiles の runner の herdr-app-mods (mod.json の place は none: herdr-app は初めて見た mod を place に従って表示中の layout へ
// 差し込むので)。layout に置くのは herdr-app-pjp-spaces。win/README.md の「サイドパネルのタブ (pjp-sidebar-tabs)」。経緯は dotfiles-private
// の ADR 106 (docs/adr/106_win_herdr_app_sidebar_tabs_*)。

import { View, div, svg } from "gpui-kit";
import { h_flex } from "gpui-base";
import { agents, layout, props, run, setAgentOrder, shared, theme } from "herdr";

// props の stack が無いときの stack の id (runner の herdr_app_pjp_spaces.rs の LISTS と同じ)
const STACK = "sidebar-lists";
// 子の id ごとの名前とアイコン (この mod のフォルダの svg。字の色で塗る)
const TABS = {
  spaces: { label: "Spaces", icon: "mods/pjp-sidebar-tabs/spaces.svg" },
  agents: { label: "Agents", icon: "mods/pjp-sidebar-tabs/agents.svg" },
};
// 数の印を出すタブ (blocked の agent の数)
const COUNTED = "agents";
// layout に stack が見つからないとき (herdr-app check・props の stack の書き違い) に並べる子
const FALLBACK = [{ id: "spaces" }, { id: "agents" }];
// 数の印に出す上限 (超えたら 99+)
const MAX_COUNT = 99;
// rail (sidebar の幅が 160px 未満) のときのタブの一辺 (px)。折りたたんだ sidebar (44px) に 2 つと間が収まる大きさ
const RAIL_CELL = 20;
// 同梱の agents の急ぎ順 (大きいほど先)
const RANK = { blocked: 4, done: 3, working: 2, idle: 1 };

function find(node, id) {
  if (node?.id === id) return node;
  for (const child of node?.children ?? []) {
    const found = find(child, id);
    if (found) return found;
  }
  return null;
}

// 同梱の spaces・agents と同じ: sidebar の幅が 160px 未満なら rail
const narrow = (root) => (find(root, "sidebar")?.size?.px ?? Infinity) < 160;

// 並べる子 (隠れていない子) と、出ている子の id。herdr-app の active_child と同じく、active が隠れていない子を指せばそれ、ほかは最初の子
function tabsOf(node) {
  const kids = node ? (node.children ?? []).filter((c) => !c.hidden) : FALLBACK;
  const active = kids.some((c) => c.id === node?.active) ? node.active : (kids[0]?.id ?? null);
  return { kids, active };
}

// agents の一覧 (同梱の mod agents) の並べ方に寄せた、agent の address の順 (agent.next・agent.prev が辿る順)。shared の agents.sort が grouped
// なら agents() の順、ほか (同梱の既定の priority) は急ぎ順で、同じなら新しく変わった順 (seq の大きい順)。どちらもピン留めが先。同梱との違い:
// sub-agent の急ぎを親に寄せない・変わった時刻 (同梱が自分の localStorage に持つ) の代わりに seq を使う
function agentOrder(list, sort) {
  const sorted = sort === "grouped" ? list : [...list].sort((x, y) => (RANK[y.status] ?? 0) - (RANK[x.status] ?? 0) || (y.seq ?? 0) - (x.seq ?? 0));
  return [...sorted.filter((a) => a.pinned), ...sorted.filter((a) => !a.pinned)].map((a) => a.address);
}

// #rrggbb (後ろの aa は見ない) の相対輝度 (WCAG 2)。読めない色なら null
function luminance(color) {
  const m = /^#([0-9a-f]{6})/i.exec(color ?? "");
  if (!m) return null;
  const n = parseInt(m[1], 16);
  const lin = (v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(n >> 16) + 0.7152 * lin((n >> 8) & 255) + 0.0722 * lin(n & 255);
}

// 地の色 bg の上で読める字の色: theme の foreground と background のうち、bg とのコントラスト比が大きい方 (読めない色なら foreground)
function readableOn(bg, t) {
  const [b, f, k] = [luminance(bg), luminance(t.foreground), luminance(t.background)];
  if (b === null || f === null || k === null) return t.foreground;
  const ratio = (x, y) => (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  return ratio(b, f) >= ratio(b, k) ? t.foreground : t.background;
}

export default class SidebarTabs extends View {
  render() {
    const t = theme();
    const root = layout();
    const stack = props()?.stack ?? STACK;
    const node = find(root, stack);
    const { kids, active } = tabsOf(node);
    const list = agents();
    const blocked = list.filter((a) => a.status === "blocked").length;
    // agents の子を隠している間は、同梱の agents の代わりに一覧の順を渡す (頭のコメント)
    if (node && active !== COUNTED && (node.children ?? []).some((c) => c.id === COUNTED)) setAgentOrder(agentOrder(list, shared("agents.sort")));
    const rail = narrow(root);
    return h_flex()
      .id("pjp-sidebar-tabs")
      .size_full()
      .min_w(0)
      .items_center()
      .gap(rail ? 2 : 4)
      .px(rail ? 0 : 6)
      .bg(t.chrome)
      .when(rail, (el) => el.justify_center())
      .children(kids.map((c) => this.tab(t, stack, c, c.id === active, c.id === COUNTED ? blocked : 0, rail)));
  }

  // タブ 1 つ。on: 出ている子。blocked: 数の印に出す数 (0 なら出さない)。rail: 小さなアイコンだけにする
  tab(t, stack, c, on, blocked, rail) {
    const def = TABS[c.id] ?? { label: c.title || c.id, icon: null };
    const tip = blocked > 0 ? `${def.label} · 確認待ち ${blocked}` : def.label;
    const id = `tab-${c.id}`;
    // タブの地・字の色・押したとき (選んでいるタブは押しても何もしない)
    const look = (el) =>
      el
        .flex_none()
        .items_center()
        .when(on, (e) => e.bg(t.selected).text_color(t.foreground))
        .when(!on, (e) =>
          e
            .text_color(t.muted)
            .cursor_pointer()
            .hover((s) => s.bg(t.hover).text_color(t.foreground))
            .on_click(() => run("layout.select", { stack, child: c.id })),
        );
    // アイコン (字の色で塗る)。overlay: アイコンの右上に重ねる数の印 ("count") か点 ("dot")。同梱の spaces の machine の印と同じく、
    // relative の中の absolute
    const icon = (size, overlay) =>
      div()
        .relative()
        .flex_none()
        .size(size)
        .child(svg(def.icon).size(size).flex_none())
        .when(overlay === "dot", (el) => el.child(div().absolute().right(-3).top(-2).size(7).rounded(4).border_1().border_color(t.chrome).bg(t.blocked)))
        .when(overlay === "count", (el) => el.child(this.count(t, blocked, true)));
    if (rail) {
      return look(div().id(id).flex().justify_center().size(RAIL_CELL).rounded(5))
        .tooltip(tip)
        .when(Boolean(def.icon), (el) => el.child(icon(14, blocked > 0 ? "dot" : null)))
        .when(!def.icon, (el) => el.text_size(11).child(Array.from(def.label)[0] ?? "?"));
    }
    if (on) {
      return look(h_flex().id(id).h(28).px(10).gap(7).rounded(7).text_size(12.5).font_medium())
        .when(Boolean(def.icon), (el) => el.child(icon(15, null)))
        .child(div().whitespace_nowrap().child(def.label))
        .when(blocked > 0, (el) => el.child(this.count(t, blocked, false)));
    }
    if (!def.icon) {
      return look(h_flex().id(id).h(28).px(10).rounded(7).text_size(12.5))
        .tooltip(tip)
        .child(div().whitespace_nowrap().child(def.label));
    }
    return look(div().id(id).flex().justify_center().size(28).rounded(7))
      .tooltip(tip)
      .child(icon(15, blocked > 0 ? "count" : null));
  }

  // 数の印: blocked の地の丸に数 (2 桁からは横に伸びる)。overlay: アイコンの右上に重ね、帯の色の縁で下のアイコンと分ける。ほかは名前の
  // 後ろに並べる
  count(t, n, overlay) {
    return div()
      .when(overlay, (el) => el.absolute().right(-9).top(-7).border_1().border_color(t.chrome))
      .flex_none()
      .h(15)
      .min_w(15)
      .px(4)
      .rounded(8)
      .bg(t.blocked)
      .text_color(readableOn(t.blocked, t))
      .text_size(9.5)
      .font_bold()
      .flex()
      .items_center()
      .justify_center()
      .child(n > MAX_COUNT ? `${MAX_COUNT}+` : String(n));
  }
}
