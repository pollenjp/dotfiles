// pjp-hub-panel: ハブの Claude がユーザーに見せる板。質問 (選んで送る) と、今の状況の説明 (markdown)・
// 進み具合 (flow)・図 (SVG などの画像に、点滅や動く点を重ねる) を、端末の横のペインに出す。
// props: { file: "<panel.json の絶対パス>", terminal: "<答えを送る端末。例 t1m>", role: "summary" | "questions" (省いてよい) }
//   role で、1 つの panel.json を「まとめ」と「問い」の 2 つのペインに分けて出せる (ハブはまとめのペインを開いておき、問いを
//   出すときだけ、まとめのペインを下に分けて問いのペインを開く)。
//   - 無い: 問いと状況の節を 1 つのペインに出す (role を足す前の形)
//   - "summary" (まとめ): title・updated・sections だけを出す。questions は出さない (送信の UI も、Enter で送ることもしない)
//   - "questions" (問い): questions だけを出す (見出し「問い (件数)」・問いと選択肢・送信。Enter でも送る)。title・updated・
//     sections は出さない。questions が空なら「問いはありません」と出す (問いのペインを閉じるのはハブ)
//   - ほかの値: わけを出し、無いときと同じに出す
//   どの role も、開いたときに自分からキーボードを取らない (handle に focus するのは、pane.go で来た "focus" (nextCommand) と、
//   ユーザーが選択肢をクリックしたときだけ)。
//   問いのペインは、「送信」(このペインで Enter も) で送れたら自分を閉じ、キーボードを terminal へ戻す。mod は自分のペインの ID を
//   知る手段が無い (props にも、panes() の mod のペインの行にも無い) ので、送信の頭で、この板の handle がキーボードを持つ
//   (is_focused) ときだけ focused() の pane (キーボードのあるペイン) を控え、その panes() の行が端末を持たず (terminal が null)、
//   mod がこの mod (pjp-hub-panel か、写しの pjp-hub-panel-<何か>) のときだけ、Enter まで済んだ後にその ID で pane.close を打つ
//   (同じ mod のまとめのペインがキーボードを持つときに、まとめを閉じない)。確かめられなければ閉じず「送った (閉じるのはハブ)」と
//   出す。pane.close を pane なしで打たない (キーボードのあるペインを閉じる。それが端末なら、その端末が終わる)。「入力欄に入れる」
//   では閉じない (端末で直に答えたときと同じく、閉じるのはハブ)。
//
// panel.json の形:
//   { version, title, updated,
//     questions: [{ id, short, title, body (markdown), options: [{ label, desc, recommended, answer }] }],
//     sections: [
//       { type: "markdown", id, title, text, collapsed },
//       { type: "flow", id, title, rows: [{ label, sub, steps: [{ label, state: "done"|"active"|"todo"|"blocked" }] }] },
//       { type: "image", id, title, src (下の「図の置き場所」の下のパス。例 "TKT-n/x.svg"), width, height, caption,
//         marks: [{ kind: "flow", x1, y1, x2, y2, speed, color }      (x1,y1 から x2,y2 へ一方向に流れる点。speed は px/s)
//                 | { kind: "pulse", x, y, w, h, radius, period, color } (点滅する枠)
//                 | { kind: "dot", x1, y1, x2, y2, period, size, color }  (行って戻る点)
//                 | { kind: "label", x, y, text, size, color }] } ] }
//   marks の座標は画像の px (width・height と同じ空間)。ペインが狭いときは画像ごと縮める。color は "#rrggbb" か
//   theme の名前 (accent・ok・warn・blocked・muted など)。
//   図の置き場所: herdr-app の home の pjp-hub-panel-media/ (Windows は %USERPROFILE%\.config\herdr-app\pjp-hub-panel-media)。
//   会話ごとにフォルダを切る (例 TKT-n/)。image() は home の外 (scratchpad など) を読めない。mod のフォルダには置かない
//   (dotfiles が配るフォルダで、書き換えると mod も読み直す)。src が "mods/" で始まれば home からのパスとして読む。
//   同じ名前で書き換えた図は描き直らない (herdr-app がパスで覚えている)。図を変えるときは名前を変える (例 x-2.svg)。
//   SVG の font-family は名前を引用符で囲む ('Yu Gothic UI', 'Meiryo UI', Meiryo, sans-serif)。囲まないと日本語を
//   混ぜた行が BIZ UDGothic などに落ち、~ が ‾ に、\ が ¥ に化ける。色は暗い theme 向きに描く (SVG は theme に従わない)。
//
// 答えは 1 行にまとめ、クリップボードに入れてから端末に貼る (terminal.paste)。「送信」(このペインで Enter も) は、
// 貼ったあと hc keys で Enter を押す。hc send は使わない (エージェントの端末への hc send は <hc from=…> の札が付き、
// ユーザーの発言と見分けられなくなる)。ファイルのフォルダを見張り、書き換わったら読み直す (version が変わったら選んだものを消す)。

import { View, div, image, svg } from "gpui-kit";
import { v_flex, h_flex, TextView } from "gpui-base";
import { exec, hc, run, props, theme, readTextFile, watchFolder, nextCommand, focused, panes } from "herdr";

const MOD = "mods/pjp-hub-panel";
const NAME = MOD.slice(MOD.lastIndexOf("/") + 1); // この mod の名前
// この mod のペインか。写し (試しに置く pjp-hub-panel-try・mod.clone の pjp-hub-panel-copy など) は名前の後ろに -<何か> が付く
const isOwnMod = (name) => typeof name === "string" && (name === NAME || name.startsWith(`${NAME}-`));
const ROLES = ["summary", "questions"];
const MEDIA = "pjp-hub-panel-media"; // 図の置き場所。herdr-app の home の下で、mod のフォルダの外
const dirOf = (p) => p.replace(/[\\/][^\\/]*$/, "");
// #rrggbb に不透明度 (16 進の 2 桁) を足す。ほかの形 (#rgb・#rrggbbaa) は足すと色にならないので null (塗らない)
const withAlpha = (color, aa) => (/^#[0-9a-fA-F]{6}$/.test(color ?? "") ? `${color}${aa}` : null);

export default class HubPanel extends View {
  init(_props, cx) {
    this.data = null;
    this.error = null;
    this.picked = {};
    this.collapsed = {};
    this.status = "";
    this.busy = false;
    this.width = null;
    this.handle = cx.focus_handle();
    const file = props()?.file;
    cx.spawn(async (cx) => {
      await this.reload(cx);
      if (!file) return;
      for (;;) {
        try {
          await watchFolder(dirOf(file));
        } catch (e) {
          this.error = `見張れない: ${e}`;
          cx.notify();
          return;
        }
        await this.reload(cx);
      }
    });
    cx.spawn(async () => {
      for (;;) {
        const cmd = await nextCommand();
        if (cmd === "focus") this.handle.focus();
      }
    });
  }

  async reload(cx) {
    const file = props()?.file;
    if (!file) {
      this.error = "props.file がありません";
      cx.notify();
      return;
    }
    try {
      const text = await readTextFile(file);
      if (text == null) {
        this.data = null;
        this.error = `ファイルが無い: ${file}`;
      } else {
        const data = JSON.parse(text);
        if (this.data?.version !== data.version) {
          this.picked = {};
          this.status = "";
          this.collapsed = {};
          for (const s of data.sections ?? []) if (s.collapsed) this.collapsed[s.id] = true;
        }
        this.data = data;
        this.error = null;
      }
    } catch (e) {
      this.error = `読めない: ${e}`;
    }
    cx.notify();
  }

  // props.role。無い・空は null (1 つのペインに両方を出す)。知らない値はそのまま返す (render がわけを出す)
  role() {
    const r = props()?.role;
    return r == null || r === "" ? null : r;
  }

  // この板 (root に track_focus した handle) が今キーボードを持つか。確かめられなければ false (送信は止めない)
  holdsKeyboard() {
    try {
      return this.handle.is_focused() === true;
    } catch {
      return false;
    }
  }

  // id のペインが、端末を持たない (terminal が null) この mod のペインなら、その id。確かめられなければ null
  ownPane(id) {
    if (!id) return null;
    const p = panes().find((x) => x.pane === id);
    return p && p.terminal == null && isOwnMod(p.mod) ? id : null;
  }

  answerLine() {
    const parts = [];
    for (const [qi, q] of (this.data?.questions ?? []).entries()) {
      const oi = this.picked[q.id];
      if (oi === undefined) continue;
      const o = (q.options ?? [])[oi];
      if (!o) continue;
      // short・title・label が無くても undefined を字にしない。問いはカードの札 (Q1…)、選択肢は何番目かで呼ぶ
      const name = q.short ?? q.title ?? `Q${qi + 1}`;
      const label = o.label ?? `${oi + 1} 番目`;
      parts.push(o.answer ?? `${name} -> ${label}`);
    }
    return parts.join(" / ");
  }

  deliver(cx, submit) {
    const line = this.answerLine();
    if (!line || this.busy) return;
    // 問いのペインは、送ったら自分を閉じる。閉じるのは、送信の頭でこの板の handle がキーボードを持つときの、キーボードのある
    // ペイン (この後の pane.focus で端末へ移る前に控える)。この板のペインかは、Enter まで済んだ後に ownPane で確かめる
    const closing = submit && this.role() === "questions";
    const self = closing && this.holdsKeyboard() ? (focused()?.pane ?? null) : null;
    this.busy = true;
    this.status = submit ? "送っています…" : "入れています…";
    // await をまたぐ仕事は cx.spawn の cx でする (クリックやキーの cx は、await の後には使えない)
    cx.spawn(async (cx) => {
      let closed = false;
      try {
        const codes = Array.from(line).map((ch) => ch.codePointAt(0));
        const ps = `Set-Clipboard -Value (-join (@(${codes.join(",")}) | ForEach-Object { [char]::ConvertFromUtf32($_) }))`;
        const r = await exec("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps], { timeout: 15000 });
        if (r.code !== 0) {
          this.status = `クリップボードに入れられない: ${r.stderr.trim()}`;
          return;
        }
        const term = props()?.terminal;
        if (!term) {
          this.status = "クリップボードに入れた (props.terminal が無い)";
          return;
        }
        run("pane.focus", { terminal: term });
        run("terminal.paste");
        if (!submit) {
          this.status = `${term} の入力欄に入れた。Enter で送る`;
          return;
        }
        // 貼った文が届いてから Enter を押す。端末がいるかの確かめを兼ねて hc get を 1 回挟んで間を置く
        const g = await hc(["get", term, "--json"]);
        if (g.code !== 0) {
          this.status = `端末 ${term} が見つからない。入力欄に入れたところで止めた`;
          return;
        }
        const k = await hc(["keys", term, "enter"]);
        if (k.code !== 0) {
          this.status = `Enter を押せなかった: ${k.stderr.trim()}。入力欄で Enter を押して送る`;
          return;
        }
        this.status = `${term} に送った: ${line}`;
        this.picked = {};
        if (closing) {
          const pane = this.ownPane(self);
          if (!pane) {
            this.status = `${term} に送った (閉じるのはハブ): ${line}`;
            return;
          }
          run("pane.close", { pane });
          closed = true;
          run("pane.focus", { terminal: term });
        }
      } catch (e) {
        this.status = `止まった: ${e}`;
      } finally {
        this.busy = false;
        // 自分のペインを閉じた後は cx を使わない (このコピーはもう無い)
        if (!closed) cx.notify();
      }
    });
    cx.notify();
  }

  colors() {
    const t = theme();
    const col = (k, d) => t[k] ?? d;
    // いまの段 (active) の色。herdr-app の Agents 欄が動いているエージェントの印に使う色。無い theme では ansi3 (黄)
    const working = col("working", col("ansi3", "#e5c07b"));
    return {
      t,
      fg: col("foreground", "#dddddd"),
      muted: col("muted", "#aaaaaa"),
      dim: col("dim", "#888888"),
      border: col("border", "#444444"),
      accent: col("accent", "#6aa0ff"),
      surface: col("surface", col("background", "#1e1e1e")),
      raised: col("raised", "#2a2a2a"),
      solid: col("solid", col("accent", "#6aa0ff")),
      solidFg: col("solid_foreground", "#ffffff"),
      blocked: col("blocked", col("ansi1", "#e06c75")),
      working,
      workingBg: withAlpha(working, "26"), // working を薄く (Agents 欄の「Needs you」の札と同じ 0x26)。#rrggbb でなければ null
      ok: col("ansi2", "#98c379"),
      warn: col("ansi3", "#e5c07b"),
    };
  }

  paint(c, name, fallback) {
    if (!name) return fallback;
    if (name.startsWith("#")) return name;
    return c[name] ?? c.t[name] ?? fallback;
  }

  // ---- 質問 ----
  questionCard(q, qi, c) {
    const picked = this.picked[q.id];
    const opts = (q.options ?? []).map((o, oi) => {
      const on = picked === oi;
      return v_flex()
        .id(`hp-${q.id}-${oi}`)
        .p(10)
        .gap(4)
        .rounded(8)
        .border_1()
        .border_color(on ? c.accent : c.border)
        .bg(on ? c.raised : c.surface)
        .cursor_pointer()
        .hover((s) => s.opacity(0.88))
        .on_click((_, cx) => {
          this.picked[q.id] = on ? undefined : oi;
          this.status = "";
          this.handle.focus();
          cx.notify();
        })
        .child(
          h_flex()
            .gap(6)
            .items_center()
            .child(div().text_color(on ? c.accent : c.dim).child(on ? "●" : "○"))
            .child(div().font_semibold().text_color(c.fg).child(o.label ?? ""))
            .when(!!o.recommended, (el) => el.child(this.badge("推奨", c.solid, c.solidFg))),
        )
        .when(!!o.desc, (el) => el.child(div().text_size(12).text_color(c.muted).child(o.desc)));
    });
    return v_flex()
      .id(`hp-q-${q.id}`)
      .p(12)
      .gap(10)
      .rounded(10)
      .border_1()
      .border_color(c.accent)
      .child(
        h_flex()
          .gap(8)
          .items_center()
          .child(this.badge(`Q${qi + 1}`, c.solid, c.solidFg))
          .child(div().flex_1().text_size(14).font_semibold().text_color(c.fg).child(q.title ?? "")),
      )
      .when(!!q.body, (el) => el.child(div().text_color(c.fg).child(TextView.markdown(`hp-qb-${q.id}`, q.body).selectable(true))))
      .children(opts);
  }

  badge(text, bg, fg) {
    return div().px(6).py(1).rounded(4).bg(bg).text_color(fg).text_size(10).font_semibold().child(text);
  }

  // ---- 状況の節 ----
  section(s, i, c) {
    const id = s.id ?? `s${i}`;
    const closed = !!this.collapsed[id];
    const head = h_flex()
      .id(`hp-sh-${id}`)
      .gap(6)
      .items_center()
      .cursor_pointer()
      .on_click((_, cx) => {
        this.collapsed[id] = !closed;
        cx.notify();
      })
      .child(div().w(12).text_color(c.dim).child(closed ? "▸" : "▾"))
      .child(div().flex_1().text_size(13).font_semibold().text_color(c.fg).child(s.title ?? ""));
    let body = null;
    if (!closed) {
      if (s.type === "markdown") body = div().text_size(12).text_color(c.fg).child(TextView.markdown(`hp-md-${id}`, s.text ?? "").selectable(true));
      else if (s.type === "flow") body = this.flow(s, id, c);
      else if (s.type === "image") body = this.picture(s, id, c);
      else body = div().text_color(c.dim).child(`知らない節: ${s.type ?? "(type が無い)"}`);
    }
    return v_flex()
      .id(`hp-s-${id}`)
      .p(12)
      .gap(8)
      .rounded(10)
      .border_1()
      .border_color(c.border)
      .bg(c.surface)
      .child(head)
      .when(!!body, (el) => el.child(body));
  }

  flow(s, id, c) {
    const rows = (s.rows ?? []).map((r, ri) => {
      const steps = [];
      (r.steps ?? []).forEach((st, si) => {
        if (si > 0) steps.push(div().text_color(c.dim).text_size(11).child("›"));
        steps.push(this.step(st, `${id}-${ri}-${si}`, c));
      });
      return v_flex()
        .id(`hp-fr-${id}-${ri}`)
        .gap(4)
        .child(
          h_flex()
            .gap(6)
            .items_center()
            .child(div().font_semibold().text_size(12).text_color(c.fg).child(r.label ?? ""))
            .when(!!r.sub, (el) => el.child(div().text_size(11).text_color(c.muted).child(r.sub))),
        )
        .child(h_flex().flex_wrap().gap(4).items_center().children(steps));
    });
    return v_flex().gap(10).children(rows);
  }

  step(st, key, c) {
    const state = st.state ?? "todo";
    const label = st.label ?? ""; // label の無い段は印だけにする (undefined・null を字にしない)
    const tail = label === "" ? "" : ` ${label}`; // 印の後ろに付ける字
    const base = h_flex().id(`hp-st-${key}`).px(7).py(2).rounded(6).border_1().text_size(11).gap(4).items_center();
    if (state === "done") return base.border_color(c.ok).text_color(c.ok).child(`✓${tail}`);
    // いまの段: working の枠と字に、同じ色を薄く敷いて点滅させる
    if (state === "active")
      return base
        .border_color(c.working)
        .when(!!c.workingBg, (el) => el.bg(c.workingBg))
        .text_color(c.working)
        .loop("opacity", { from: 0.55, to: 1, period: 1400 })
        .child(`●${tail}`);
    if (state === "blocked") return base.border_color(c.blocked).text_color(c.blocked).child(`■${tail}`);
    return base.border_color(c.border).text_color(c.dim).child(label);
  }

  // 図の場所: "mods/" で始まるものはそのまま (herdr-app の home から)、ほかは MEDIA の下から。
  // image() は herdr-app の home の外 (scratchpad など) を読めない (絶対パスを渡すと何も出ない)
  imagePath(src) {
    return src.startsWith("mods/") ? src : `${MEDIA}/${src}`;
  }

  picture(s, id, c) {
    const W = s.width ?? 520;
    const H = s.height ?? 300;
    const avail = this.width ? this.width - 24 - 26 : W;
    const k = Math.max(0.3, Math.min(1, avail / W));
    const src = this.imagePath(s.src ?? "");
    const marks = (s.marks ?? []).map((m, mi) => this.mark(m, `${id}-${mi}`, k, c)).filter(Boolean);
    return v_flex()
      .gap(6)
      .child(div().relative().w(W * k).h(H * k).child(image(src).w(W * k).h(H * k)).children(marks))
      .when(!!s.caption, (el) => el.child(div().text_size(11).text_color(c.muted).child(TextView.markdown(`hp-cap-${id}`, s.caption))));
  }

  mark(m, key, k, c) {
    const color = this.paint(c, m.color, c.accent);
    if (m.kind === "flow") {
      // 一方向に流れる点。loop は行って戻るので向きを出せない。点を並べた輪 (ring.svg) を spin で回し、矢印の外接矩形で
      // 切り抜く。輪の点の通り道が矢印の中点で矢印に接し、時計回りの向きが矢印の向きになるように輪の中心を置く
      const s = Math.max(k, 0.6);
      const D = 600 * s; // ring.svg の大きさ
      const R0 = 292 * s; // 点の通り道の半径
      const pad = 4 * s + 1; // 点の半径 + 1
      const x1 = m.x1 * k, y1 = m.y1 * k, x2 = m.x2 * k, y2 = m.y2 * k;
      const len = Math.hypot(x2 - x1, y2 - y1) || 1;
      const ux = (x2 - x1) / len, uy = (y2 - y1) / len;
      const phi = Math.atan2(-ux, uy); // 時計回りの接線が (ux, uy) になる輪の上の角
      const cx = (x1 + x2) / 2 - R0 * Math.cos(phi);
      const cy = (y1 + y2) / 2 - R0 * Math.sin(phi);
      // 切り抜きは矢印の向きと直角の側にだけ広げる (縦の矢印なら左右だけ)。点は矢印の端で切れ、箱から出て箱へ入って見える
      const padX = pad * Math.abs(uy);
      const padY = pad * Math.abs(ux);
      const left = Math.min(x1, x2) - padX;
      const top = Math.min(y1, y2) - padY;
      const period = Math.max(100, Math.round(((2 * Math.PI * R0) / (m.speed ?? 40)) * 1000));
      return div()
        .id(`hp-mk-${key}`)
        .absolute()
        .left(left)
        .top(top)
        .w(Math.abs(x2 - x1) + 2 * padX)
        .h(Math.abs(y2 - y1) + 2 * padY)
        .overflow_hidden()
        .child(svg(`${MOD}/ring.svg`).absolute().left(cx - D / 2 - left).top(cy - D / 2 - top).size(D).text_color(color).spin(period));
    }
    if (m.kind === "pulse") {
      return div()
        .id(`hp-mk-${key}`)
        .absolute()
        .left(m.x * k)
        .top(m.y * k)
        .w(m.w * k)
        .h(m.h * k)
        .rounded((m.radius ?? 8) * k)
        .border_2()
        .border_color(color)
        .loop("opacity", { from: 0.15, to: 1, period: m.period ?? 1600 });
    }
    if (m.kind === "dot") {
      const size = (m.size ?? 9) * Math.max(k, 0.6);
      const half = size / 2;
      let el = div()
        .id(`hp-mk-${key}`)
        .absolute()
        .left(m.x1 * k - half)
        .top(m.y1 * k - half)
        .w(size)
        .h(size)
        .rounded(size)
        .bg(color);
      const period = m.period ?? 2200;
      if (m.x1 !== m.x2) el = el.loop("left", { from: m.x1 * k - half, to: m.x2 * k - half, period, easing: "linear" });
      if (m.y1 !== m.y2) el = el.loop("top", { from: m.y1 * k - half, to: m.y2 * k - half, period, easing: "linear" });
      return el;
    }
    if (m.kind === "label") {
      return div()
        .absolute()
        .left(m.x * k)
        .top(m.y * k)
        .text_size(Math.max(9, (m.size ?? 12) * k))
        .text_color(this.paint(c, m.color, c.fg))
        .child(m.text ?? "");
    }
    return null;
  }

  button(id, label, primary, enabled, c, onClick) {
    return h_flex()
      .id(id)
      .h(30)
      .px(12)
      .items_center()
      .rounded(8)
      .border_1()
      .border_color(primary && enabled ? c.solid : c.border)
      .bg(primary && enabled ? c.solid : c.raised)
      .text_color(enabled ? (primary ? c.solidFg : c.fg) : c.dim)
      .text_size(12)
      .when(enabled, (el) => el.cursor_pointer().hover((s) => s.opacity(0.88)).on_click(onClick))
      .child(label);
  }

  render(cx) {
    const c = this.colors();
    const d = this.data;
    const role = this.role();
    const known = role === null || ROLES.includes(role);
    const r = known ? role : null; // 知らない値は、無いときと同じに出す
    const qs = r === "summary" ? [] : (d?.questions ?? []);
    const secs = r === "questions" ? [] : (d?.sections ?? []);
    const line = r === "summary" ? "" : this.answerLine();
    const ready = !!line && !this.busy;

    const body = [];
    if (!known) body.push(div().text_color(c.blocked).child(`props.role が分からない: ${JSON.stringify(role)} (summary か questions。無ければ両方を出す)`));
    if (this.error) body.push(div().text_color(c.blocked).child(this.error));
    if (r === "questions") {
      qs.forEach((q, qi) => body.push(this.questionCard(q, qi, c)));
      if (!this.error && d && qs.length === 0) body.push(div().text_color(c.muted).child("問いはありません"));
    } else {
      if (qs.length > 0) {
        body.push(div().text_size(12).font_semibold().text_color(c.accent).child(`質問 (${qs.length})`));
        qs.forEach((q, qi) => body.push(this.questionCard(q, qi, c)));
      }
      if (secs.length > 0) {
        if (qs.length > 0) body.push(div().h(4), div().text_size(12).font_semibold().text_color(c.muted).child("いまの状況"));
        secs.forEach((s, i) => body.push(this.section(s, i, c)));
      }
      if (!this.error && d && qs.length === 0 && secs.length === 0) body.push(div().text_color(c.muted).child("出すものはありません"));
    }
    // 上の帯の題。問いのペインは見出しと件数 (updated も出さない)、ほかは panel.json の title
    const heading = r === "questions" ? (qs.length > 0 ? `問い (${qs.length})` : "問い") : (d?.title ?? "ハブ");

    const footer =
      qs.length === 0
        ? null
        : v_flex()
            .px(14)
            .py(10)
            .gap(8)
            .border_t_1()
            .border_color(c.border)
            .child(div().text_size(12).text_color(line ? c.fg : c.dim).child(line || "選択肢を選ぶと、ここに答えの文が出ます"))
            .child(
              h_flex()
                .gap(8)
                .items_center()
                .child(div().flex_1().text_size(11).text_color(c.dim).child(this.status || (line ? "Enter (このペインで) か「送信」で送る" : "")))
                .child(this.button("hp-paste", "入力欄に入れる", false, ready, c, (_, cx) => this.deliver(cx, false)))
                .child(this.button("hp-send", "送信", true, ready, c, (_, cx) => this.deliver(cx, true))),
            );

    return v_flex()
      .id("hp")
      .track_focus(this.handle)
      .on_key_down((e, cx) => {
        // まとめのペインは送らない (Enter も素通し)
        if (e.key !== "enter" || r === "summary") return;
        if (ready) this.deliver(cx, true);
        cx.stop_propagation();
      })
      .on_size_change((size, cx) => {
        if (this.width === null || Math.abs(this.width - size.width) > 1) {
          this.width = size.width;
          cx.notify();
        }
      })
      .size_full()
      .min_h(0)
      .text_size(13)
      .text_color(c.fg)
      .child(
        h_flex()
          .px(14)
          .py(10)
          .gap(8)
          .items_center()
          .border_b_1()
          .border_color(c.border)
          .child(div().flex_1().text_size(15).font_semibold().child(heading))
          .when(r !== "questions", (el) => el.child(div().text_size(11).text_color(c.dim).child(d?.updated ?? ""))),
      )
      .child(v_flex().id("hp-list").flex_1().min_h(0).overflow_y_scrollbar().p(12).gap(10).children(body))
      .when(!!footer, (el) => el.child(footer))
      .when(!footer && !!this.status, (el) => el.child(div().px(14).py(6).border_t_1().border_color(c.border).text_size(11).text_color(c.dim).child(this.status)));
  }
}
