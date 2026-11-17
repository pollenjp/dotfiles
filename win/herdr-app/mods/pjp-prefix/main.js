// pjp-prefix: 旧 herdr の prefix キー (Ctrl+K) を herdr-app で使う小窓。keys.json の global の Ctrl+K が mod.open:pjp-prefix で開き、
// 次の 1 キーで命令を流して閉じる (herdr-app の keys.json には、2 回に分けて打つキーの仕組みが無いので、mod の小窓で次のキーを待つ)。
//
// prefix の後のキー (旧 herdr の win/herdr/config.toml の [keys] と同じ):
//   Shift+C      worktree を作る。名前は worktree/<形容詞>-<名詞>-<16 進 4 桁> (旧 herdr と同じ形) を自動で付け、同じ名前の branch が
//                あれば作り直す。herdr-app の worktree の小窓に branch を渡すと、Enter を待たずに今の space の checkout の HEAD から切り、
//                新しい space を開く
//   Shift+G      同じく worktree を作り、新しい space の最初のタブで Claude Code を起動する (下の CLAUDE)
//   v |          右に分割 (pane.split right)          - Shift+S   下に分割 (pane.split down)
//   n p          次・前のタブ                          Shift+T ,   タブの名前を変える (名前を訊く)
//   Tab o        今のタブの次のペイン                  g "         端末の picker (mod.open:picker)
//   Shift+O      次のエージェント (agent.next。旧 herdr の open_notification_target の代わり)
//   Esc          取り消す。割り当てに無いキーは、何もせずに閉じる
//   Ctrl+K       (prefix のキーをもう 1 回) 開く前に focus があった端末へ Ctrl+K を送る (hc keys)。keys.json の section mod:pjp-prefix が、
//                小窓に focus がある間の Ctrl+K を pjp-prefix.literal (nextCommand の "literal") にする。無いと、global の Ctrl+K
//                (mod.open の 2 回目) が小窓を閉じるだけになる
//
// キーは打った文字 (key_char) で見る。日本語の配列でも " (Shift+2) と | (Shift+¥) はそのまま届く。一覧の行を押しても同じ命令を流す。
// 配る: dotfiles の runner の herdr-app-mods (この mod) と herdr-app-keys (keys.json に書き足す)。win/README.md の「herdr-app のキー」。

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { run, props, closeOverlay, openOverlay, notify, theme, spaces, panes, focused, exec, hc, keys, nextCommand } from "herdr";

// worktree の名前に使う語 (worktree/brave-cloud-7d08 の形)
const ADJECTIVES = [
  "amber", "bold", "brave", "bright", "brisk", "calm", "clear", "cool", "crisp", "deep", "eager", "fair",
  "fresh", "gentle", "glad", "golden", "grand", "green", "happy", "keen", "kind", "light", "lively", "lucky",
  "mellow", "mild", "misty", "neat", "noble", "proud", "quick", "quiet", "rapid", "sharp", "shiny", "silent",
  "silver", "smooth", "snowy", "soft", "solid", "steady", "sunny", "swift", "tidy", "warm", "wild", "wise",
];
const NOUNS = [
  "bay", "birch", "breeze", "brook", "canyon", "cedar", "cliff", "cloud", "coast", "creek", "dawn", "delta",
  "dune", "ember", "fern", "field", "forest", "frost", "glade", "grove", "harbor", "hill", "island", "lake",
  "leaf", "maple", "meadow", "mesa", "moon", "moss", "ocean", "peak", "pine", "pond", "rain", "reef",
  "ridge", "river", "shore", "sky", "snow", "spring", "star", "stone", "stream", "tide", "valley", "willow",
];
// 同じ名前の branch があったときに作り直す回数
const TRIES = 8;

// Shift+G で起動する Claude Code。c (nix/home/modules/fish.nix の abbr・bash.nix の alias・win/powershell/dotfiles.ps1 の function) と
// 同じ引数。argv が shell の abbr・alias・function を通るとは限らない (fish の abbr は打ったときだけ広がる) ので、c と書かずに中身を
// 並べる。claude が PATH に無い machine では、herdr-app が端末のエラーを出し、shell が残る
const CLAUDE = ["claude", "--dangerously-skip-permissions", "--effort", "max", "--model", "claude-opus-5-5", "--remote-control="];

const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
// 押しても次のキーとして読まないもの (修飾キーだけ)
const MODIFIERS = new Set(["shift", "control", "ctrl", "alt", "platform", "cmd", "super", "function", "fn", "capslock"]);

// 押すキー (打った文字。Shift+C は "C"。文字を打たないキーはその名前) → 命令。label は小窓の一覧に出す
const BINDINGS = [
  { keys: ["C"], label: "worktree (名前は自動)", act: (p, cx) => p.worktree(cx, false) },
  { keys: ["G"], label: "worktree + Claude 起動", act: (p, cx) => p.worktree(cx, true) },
  { keys: ["v", "|"], label: "右に分割", act: (p) => p.runClosed("pane.split", { direction: "right", ...p.paneArg() }) },
  { keys: ["-", "S"], label: "下に分割", act: (p) => p.runClosed("pane.split", { direction: "down", ...p.paneArg() }) },
  { keys: ["n"], label: "次のタブ", act: (p) => p.runClosed("tab.next") },
  { keys: ["p"], label: "前のタブ", act: (p) => p.runClosed("tab.prev") },
  { keys: ["T", ","], label: "タブの名前を変える", act: (p) => p.runClosed("tab.rename", p.origin.tab ? { id: p.origin.tab } : {}) },
  { keys: ["tab", "o"], label: "次のペイン", act: (p) => p.nextPane() },
  { keys: ["g", "\""], label: "端末を選ぶ (picker)", act: (p) => p.runClosed("mod.open", { name: "picker" }) },
  { keys: ["O"], label: "次のエージェント", act: (p) => p.runClosed("agent.next") },
];

const pick = (list) => list[Math.floor(Math.random() * list.length)];
const hex4 = () => Math.floor(Math.random() * 0x10000).toString(16).padStart(4, "0");
const worktreeName = () => `worktree/${pick(ADJECTIVES)}-${pick(NOUNS)}-${hex4()}`;

// 一覧に出すキーの名前 ("C" → "Shift+C"、"tab" → "Tab")
const keyLabel = (k) => (k === "tab" ? "Tab" : /^[A-Z]$/.test(k) ? `Shift+${k}` : k);
// keys.json の書き方のキー ("ctrl-k") を、人が読む形 ("Ctrl+K") と hc keys の形 ("ctrl+k") にする
const showKey = (k) => k.split("-").map((s) => (s.length === 1 ? s.toUpperCase() : s.charAt(0).toUpperCase() + s.slice(1))).join("+");
const hcKey = (k) => k.split("-").join("+");

// 押したキーを BINDINGS の名前にする: 打った文字か、文字を打たないキーの名前 ("tab"。Shift を足していれば "shift-tab")。
// Ctrl・Alt・Win を押していれば null (prefix の後のキーの組には無い)
function pressed(e) {
  const m = e.modifiers ?? {};
  if (m.control || m.alt || m.platform) return null;
  const ch = e.key_char;
  if (typeof ch === "string" && [...ch].length === 1 && ch.trim() !== "") return ch;
  const k = e.key ?? "";
  if ([...k].length === 1) return m.shift ? k.toUpperCase() : k;
  return m.shift ? `shift-${k}` : k;
}

export default class Prefix extends View {
  init(_props, cx) {
    // 開く前に focus があった所 (小窓を閉じた後の命令と、prefix のキーを送る先)
    const f = focused() ?? {};
    const pane = panes().find((p) => (f.pane ? p.pane === f.pane : p.focused));
    this.origin = {
      space: f.space ?? null,
      tab: f.tab ?? pane?.tab ?? null,
      pane: f.pane ?? pane?.pane ?? null,
      terminal: f.terminal ?? pane?.terminal ?? null,
      cwd: f.cwd ?? pane?.cwd ?? null,
    };
    // prefix のキーは keys.json で、この小窓を開くキー (無ければ ctrl-k)
    this.prefix = keys().find((b) => b.section === "global" && b.action === "mod.open:pjp-prefix")?.keys ?? "ctrl-k";
    this.literal = keys().some((b) => b.section === "mod:pjp-prefix" && b.action === "pjp-prefix.literal");
    this.busy = false;
    this.closed = false;
    this.handle = cx.focus_handle();
    this.handle.focus();
    // 開いた直後に focus が端末へ戻ることがあるので、少し後にもう一度取る (herdr-app の picker・worktree の小窓と同じ)
    cx.timer.after(50, () => {
      if (!this.closed) this.handle.focus();
    });
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        if (c === "literal" && !this.busy) this.sendPrefix(cx);
      }
    });
  }

  // この小窓を閉じる (閉じた後に命令を流す)
  dismiss() {
    if (this.closed) return;
    this.closed = true;
    closeOverlay(props().overlay);
  }

  // herdr-app が小窓を閉じたとき (Esc・外のクリック・mod.open の 2 回目) にも呼ばれる。名前を選んでいる途中なら、後から worktree の
  // 小窓を開かない
  async close() {
    this.closed = true;
  }

  // 小窓を閉じてから命令を流す (名前を訊く画面や picker を、この小窓の後ろでなく前に出す)
  runClosed(name, args) {
    this.dismiss();
    run(name, args ?? {});
  }

  paneArg() {
    return this.origin.pane ? { pane: this.origin.pane } : {};
  }

  // 今のタブの端末のペインを順に回す (最後の次は最初)
  nextPane() {
    this.dismiss();
    const list = panes().filter((p) => p.tab === this.origin.tab && p.terminal);
    if (list.length < 2) return;
    const at = list.findIndex((p) => p.pane === this.origin.pane);
    run("pane.focus", { pane: list[(at + 1) % list.length].pane });
  }

  // prefix のキーをもう 1 回: 開く前の端末へ prefix のキーを送る。hc は呼んだ時点で走り出し、小窓を閉じても止まらない
  sendPrefix(cx) {
    const term = this.origin.terminal;
    const sent = term ? hc(["keys", term, hcKey(this.prefix)]) : null;
    this.dismiss();
    if (!sent) return;
    cx.spawn(async () => {
      const fail = (body) => notify({ title: `${showKey(this.prefix)} を ${term} へ送れなかった`, body, level: "warning" });
      try {
        const r = await sent;
        if (r.code !== 0) fail((r.stderr || r.stdout).trim());
      } catch (e) {
        fail(String(e));
      }
    });
  }

  // 名前を自動で付けた worktree。今の space の machine で、開く前のペインのフォルダの repo に同じ名前の branch が無いかを見てから、
  // herdr-app の worktree の小窓に渡す (git の repo でない・machine に届かないときは確かめずに渡し、小窓にわけを出させる)
  worktree(cx, withClaude) {
    if (this.busy) return;
    this.busy = true;
    cx.notify();
    cx.spawn(async (cx) => {
      const on = spaces().find((s) => s.id === this.origin.space)?.machine ?? null;
      const folder = this.origin.cwd;
      let branch = null;
      for (let i = 0; i < TRIES && !branch; i++) {
        const name = worktreeName();
        let r = null;
        try {
          r = await exec("git", ["show-ref", "--verify", "--quiet", `refs/heads/${name}`], { ...(folder ? { cwd: folder } : {}), on, timeout: 15000 });
        } catch {}
        // 0: その名前の branch がある (作り直す)。1: 無い。ほか: 確かめられない
        if (!r || r.code !== 0) branch = name;
      }
      if (this.closed) return;
      this.dismiss();
      openOverlay({
        mod: "worktree",
        kind: "dialog",
        width: 460,
        height: 280,
        props: {
          space: this.origin.space,
          ...(folder ? { folder } : {}),
          action: "new",
          branch: branch ?? worktreeName(),
          ...(withClaude ? { argv: CLAUDE } : {}),
        },
      });
      cx.notify();
    });
  }

  key(e, cx) {
    const k = e.key ?? "";
    if (MODIFIERS.has(k)) return;
    cx.stop_propagation();
    // 押しっぱなしの繰り返しと、名前を選んでいる間のキーは読まない (Esc は herdr-app が閉じる)
    if (e.is_held || this.busy) return;
    if (k === "escape") return this.dismiss();
    // prefix のキーをもう 1 回 (keys.json の mod:pjp-prefix が無いときの受け口。ふつうは nextCommand の literal で届く)
    if (e.keystroke === this.prefix) return this.sendPrefix(cx);
    const name = pressed(e);
    const b = name && BINDINGS.find((x) => x.keys.includes(name));
    if (!b) return this.dismiss();
    b.act(this, cx);
  }

  render(cx) {
    const t = theme();
    const chip = (k) =>
      div().px(5).py(1).rounded(4).border_1().border_color(t.border).bg(t.raised).text_size(11.5).text_color(t.foreground).child(keyLabel(k));
    const row = (b, i) =>
      h_flex()
        .id(`pp-${i}`)
        .h(24)
        .px(4)
        .gap(8)
        .items_center()
        .rounded(5)
        .cursor_pointer()
        .hover((s) => s.bg(t.hover))
        .on_click((_e, cx) => {
          if (!this.busy) b.act(this, cx);
        })
        .child(h_flex().w(104).flex_none().gap(4).children(b.keys.map(chip)))
        .child(div().flex_1().min_w(0).truncate().text_color(t.muted).child(b.label));
    const half = Math.ceil(BINDINGS.length / 2);
    const col = (from, to) => v_flex().flex_1().min_w(0).gap(2).children(BINDINGS.slice(from, to).map((b, i) => row(b, from + i)));
    const prefix = showKey(this.prefix);
    return v_flex()
      .id("pjp-prefix")
      .track_focus(this.handle)
      .on_key_down((e, cx) => this.key(e, cx))
      .size_full()
      .p(14)
      .gap(10)
      .bg(t.popover)
      .text_size(13)
      .child(
        h_flex()
          .items_center()
          .gap(8)
          .child(div().px(6).py(1).rounded(5).bg(t.accent).text_color(t.accent_foreground).font_semibold().child(prefix))
          .child(div().flex_1().font_semibold().text_color(t.foreground).child(this.busy ? "worktree の名前を選んでいます…" : "次のキーを押す"))
          .child(div().text_size(11).text_color(t.dim).child("Esc で取り消す")),
      )
      .child(
        this.busy
          ? h_flex().gap(8).items_center().text_color(t.muted).child(div().frames(SPINNER, 90)).child("同じ名前の branch が無いかを見ています")
          : h_flex().gap(16).child(col(0, half)).child(col(half, BINDINGS.length)),
      )
      .when(this.literal && !this.busy, (el) => el.child(div().text_size(11).text_color(t.dim).child(`${prefix} をもう一度: 開く前の端末へ ${prefix} を送る`)));
  }
}
