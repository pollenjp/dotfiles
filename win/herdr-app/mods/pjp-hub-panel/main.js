// pjp-hub-panel: ハブの Claude がユーザーに見せる板。質問 (選んで送る) と、今の状況の説明 (markdown)・
// 進み具合 (flow)・図 (SVG などの画像に、点滅や動く点を重ねる) を、端末の横のペインに出す。図はペインの幅に合わせて縮め・
// 大きくし、クリックすると大きく見る小窓で開く (下の「図の大きさと、大きく見る小窓」)。
// props: { file: "<panel.json の絶対パス>", terminal: "<答えを送る端末。例 t1m>", role: "summary" | "questions" (省いてよい) }
//   role で、1 つの panel.json を「まとめ」と「問い」の 2 つのペインに分けて出せる (ハブはまとめのペインをハブの端末の左に開いて
//   おき、問いを出すときだけ、ハブの端末を右に分けて問いのペインを開く。並べ方は win/README.md の「herdr-app の mod」)。
//   - 無い: 問いと状況の節を 1 つのペインに出す (role を足す前の形)
//   - "summary" (まとめ): title・updated・sections だけを出す。questions は出さない (送信の UI も、Enter で送ることもしない)
//   - "questions" (問い): questions だけを出す (見出し「問い (件数)」・問いと選択肢・送信。Enter でも送る)。title・updated・
//     sections は出さない。questions が空なら「問いはありません」と出す (問いのペインを閉じるのはハブ)
//   - ほかの値: わけを出し、無いときと同じに出す
//   どの role のペインも、開いたときに自分からキーボードを取らない (handle に focus するのは、pane.go で来た "focus" (nextCommand) と、
//   ユーザーが選択肢をクリックしたときだけ。図を大きく見る小窓は別で、開いたときに focus する)。
//   問いのペインは、「送信」(このペインで Enter も) で送れたら自分を閉じ、キーボードを terminal へ戻す。mod は自分のペインの ID を
//   知る手段が無い (props にも、panes() の mod のペインの行にも無い) ので、送信の頭で、この板の handle がキーボードを持つ
//   (is_focused) ときだけ focused() の pane (キーボードのあるペイン) を控え、その panes() の行が端末を持たず (terminal が null)、
//   mod がこの mod (pjp-hub-panel か、写しの pjp-hub-panel-<何か>) のときだけ、Enter まで済んだ後にその ID で pane.close を打つ
//   (同じ mod のまとめのペインがキーボードを持つときに、まとめを閉じない)。確かめられなければ閉じず「送った (閉じるのはハブ)」と
//   出す。pane.close を pane なしで打たない (キーボードのあるペインを閉じる。それが端末なら、その端末が終わる)。「入力欄に入れる」
//   では閉じない (端末で直に答えたときと同じく、閉じるのはハブ)。
// props.image (ハブは渡さない): 図の節 (panel.json の sections の type "image" の 1 つ) がオブジェクトで来たら、その図だけを出す
//   小窓になる (板の図のクリックで、この mod が自分を開くときに渡す。下の「図の大きさと、大きく見る小窓」)。
//
// 文字の大きさ: どの role のペインも、上の行 (題・更新の時刻の行) の「− <今の %> +」で、板 (この mod) の文字だけを上げ下げする。
//   1 回で 10% ずつ、70%〜200%。% を押すと既定 (100%) に戻す (既定のときは押せない)。100% は、ここに書いた字の大きさの値
//   (本文 13・題 15・問いの題 14・節の題 13・markdown の本文 12・段の札 11・札 10・ボタン 12 など。この mod を書いたときの px) の
//   1.2 倍。字 (図の説明 caption も) と、字を囲む札・段の札・ボタンの高さ・余白・角が同じ倍率で変わる。変えないもの: カードと一覧の
//   余白・間、図そのもの (image の節の絵と marks。ペインの幅に合わせ、marks の label の字も図の倍率のまま)、「− % +」の
//   組 (いつも 100% の大きさ。押しても組の幅が変わらず、ボタンがポインタの下から動かないように)。markdown の中の見出し (#) の大きさは
//   TextView が決める (倍率に従うかは試していない。本文と箇条書きは親の字の大きさに従う)。
//   値は shared の "pjp-hub-panel.textPercent" (整数の %。名前は MOD から作るので、MOD を書き換えずに写した写しは本物と同じ値を、
//   MOD を写しの名前に書き換えた pjp-hub-panel-try などは写しの値を使う) に置く。どの space の板も、後から開いた問いのペインも同じ
//   大きさで出て、herdr-app を上げ直しても残る (localStorage はペインの写しごとで、問いのペインは開くたびに新しい写しになるので
//   使わない)。数でない値は既定、範囲の外は端に寄せ、整数に丸めて出す。
//   アプリの zoom (settings.json の zoom・app.zoom_in) は端末もほかの mod も大きくするので使わない (板の px もアプリの zoom には従う)。
//   キーでは変えない (Ctrl+= などはアプリの zoom のキー)。上の行の組は折り返さずに右上に留まり、ペインが狭いときは、左の欄の中で
//   更新の時刻が次の行へ回り、題は縮んで折り返す。下の行の「入力欄に入れる」「送信」は、わけの字の横に入らなければ次の行へ回り、
//   2 つが並ばない幅では「送信」がさらに次の行へ回る (どちらも右寄せで、ボタンは縮めない)。
//
// 図の大きさと、大きく見る小窓:
//   板のペインの図は、ペインの幅から一覧と節のカードの余白 (50 px) を引いた幅に合わせて縮め・大きくする (0.1〜2 倍。width と height の
//   比は保ち、marks も同じ倍率で置く)。ペインの境を動かすと追う。root の on_size_change の幅は、アプリの zoom (settings.json の zoom) を
//   掛けた後の logical px で、w()・h() に渡す px は zoom を掛ける前の px (描くと zoom 倍になる) なので、幅を settings().zoom で割って
//   から合わせる (herdr-app の release notes の図も width / settings().zoom。割らないと、zoom 1.4 で図が 1.4 倍に描かれ、ペインの端で
//   切れる)。図は板の文字の % に従わない。2 倍で止めるのは、広いペイン (pane.zoom など) で図が縦に長くなり、ほかの節を押し出さないため。
//   図には pointer の形・hover・tooltip と、下の「クリックで拡大」の字を付ける。flow の marks の輪 (ring.svg) は、倍率を 2 の 1/4 乗の
//   刻みに丸めた大きさで描く (svg() は描く大きさごとに絵を作って持つので、ペインの境を動かしても作る絵の数を抑える。輪は矢印の中点を
//   通るように置くので、丸めても点は矢印に沿う)。
//   図をクリックすると、この mod を dialog の小窓 (窓の幅の 92%・高さの 90%) で開き、props.image に図の節を渡す。小窓は panel.json を
//   読まず見張らず、図の題・図 (marks も)・図の説明だけを出し、図を小窓の図の欄に縦横とも収める (0.1〜4 倍。欄の大きさも zoom で割る)。
//   地は theme の popover (herdr-app の dialog の mod と同じ)。閉じるのは Esc・「閉じる」・図の欄のクリック (ダブルクリックの 2 回目は
//   数えない。図をダブルクリックしても、開いた小窓がすぐ閉じない。外のクリックと Esc では herdr-app も閉じる)。開いたときに小窓の
//   handle に focus する (Esc を受けるため)。開く mod の名前は MOD から取るので、写しを試すときは MOD を写しの名前に書き換える (書き
//   換えないと写しの図から本物の pjp-hub-panel の小窓が開く。shared の名前と ring.svg のパスも写しのものになる)。SVG の図を大きく
//   したときの細かさは herdr-app の画像の読み込み次第 (GPUI 本家の img() は、SVG を SVG の width・height の 2 倍で 1 回だけ絵にして、
//   引き伸ばして描く。それより大きく描くとにじむ)。
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
//   marks の座標は画像の px (width・height と同じ空間) で、図と同じ倍率で置く。color は "#rrggbb" か
//   theme の名前 (accent・ok・warn・blocked・muted など)。width・height が数でない・0 以下なら 520×300 とみる。
//   図の置き場所: herdr-app の home の pjp-hub-panel-media/ (Windows は %USERPROFILE%\.config\herdr-app\pjp-hub-panel-media)。
//   会話ごとにフォルダを切る (例 TKT-n/)。image() は home の外 (scratchpad など) を読めない。mod のフォルダには置かない
//   (dotfiles が配るフォルダで、書き換えると mod も読み直す)。src が "mods/" で始まれば home からのパスとして読む。
//   同じ名前で書き換えた図は描き直らない (herdr-app がパスで覚えている)。図を変えるときは名前を変える (例 x-2.svg)。
//   SVG の font-family は名前を引用符で囲む ('Yu Gothic UI', 'Meiryo UI', Meiryo, sans-serif)。囲まないと日本語を
//   混ぜた行が BIZ UDGothic などに落ち、~ が ‾ に、\ が ¥ に化ける。色は暗い theme 向きに描く (SVG は theme に従わない)。
//
// 答えは問いの順に 1 つ 1 行にし、改行 (LF) でつないでクリップボードに入れてから、端末に 1 回で貼る (terminal.paste)。「送信」
// (このペインで Enter も) は、貼ったあと hc keys で Enter を 1 回押す。改行を含む文が Claude Code の入力欄に 1 つの入力として入るのは、
// terminal.paste が bracketed paste で渡すことを当てにしている (herdr-app の文書には書かれていない。渡らなければ、Claude Code は
// 1 行目で送ってしまう)。板の下の行にも、答えを 1 行ずつ出す。hc send は使わない (エージェントの端末への hc send は <hc from=…> の
// 札が付き、ユーザーの発言と見分けられなくなる)。ファイルのフォルダを見張り、書き換わったら読み直す (version が変わったら選んだものを消す)。

import { View, div, image, svg } from "gpui-kit";
import { v_flex, h_flex, TextView } from "gpui-base";
import { exec, hc, run, props, theme, readTextFile, watchFolder, nextCommand, focused, panes, shared, setShared, settings, openOverlay, closeOverlay } from "herdr";

const MOD = "mods/pjp-hub-panel";
const NAME = MOD.slice(MOD.lastIndexOf("/") + 1); // この mod の名前
// この mod のペインか。写し (試しに置く pjp-hub-panel-try・mod.clone の pjp-hub-panel-copy など) は名前の後ろに -<何か> が付く
const isOwnMod = (name) => typeof name === "string" && (name === NAME || name.startsWith(`${NAME}-`));
const ROLES = ["summary", "questions"];
const MEDIA = "pjp-hub-panel-media"; // 図の置き場所。herdr-app の home の下で、mod のフォルダの外
const dirOf = (p) => p.replace(/[\\/][^\\/]*$/, "");
// #rrggbb に不透明度 (16 進の 2 桁) を足す。ほかの形 (#rgb・#rrggbbaa) は足すと色にならないので null (塗らない)
const withAlpha = (color, aa) => (/^#[0-9a-fA-F]{6}$/.test(color ?? "") ? `${color}${aa}` : null);
// 板の文字の大きさ (上の行の -・%・+)。shared に整数の % で置き、どの写しも同じ大きさで出す
const ZOOM_KEY = `${NAME}.textPercent`;
const ZOOM = { def: 100, min: 70, max: 200, step: 10 };
const TEXT_BASE = 1.2; // 100% の倍率。字の大きさの値 (本文 13 など。この mod を書いたときの px) の 1.2 倍で出す
// shared の値を % にする。数でない (無い・文字・NaN・Infinity) は既定、範囲の外は端へ寄せ、整数に丸める
const zoomOf = (v) => (typeof v === "number" && Number.isFinite(v) ? Math.min(ZOOM.max, Math.max(ZOOM.min, Math.round(v))) : ZOOM.def);
// 1 刻み上げた (dir が 1)・下げた (-1) %。刻みの途中の値 (105 など) からは次の刻み (110・100) へ
const zoomStep = (z, dir) =>
  dir > 0 ? Math.min(ZOOM.max, (Math.floor(z / ZOOM.step) + 1) * ZOOM.step) : Math.max(ZOOM.min, (Math.ceil(z / ZOOM.step) - 1) * ZOOM.step);
// 既定の倍率だけを掛けた大きさ (板の % に従わない)。「− % +」の組に使い、押しても組の幅と高さが変わらず、ボタンがポインタの下から動かない
const atBase = (n) => Math.round(n * TEXT_BASE * 10) / 10;
const BAR_H = atBase(22) + 4; // 「− % +」の組の高さ (区切りの高さに、内の余白と枠の上下 1 px ずつを足したもの)
// 図の倍率。板のペインの図は、ペインの幅から pad (一覧の p(12) の左右と、節のカードの p(12) の左右・枠 1 px の左右) を引いた幅に
// 合わせる。大きくするのは max 倍まで (広いペインで図が縦に長くなり、ほかの節を押し出さないように。もっと大きく見るのは小窓)。
// min は、とても狭いペインでも 0 や負の大きさを渡さないための下限
const PIC = { min: 0.1, max: 2, pad: 24 + 26 };
// 図を大きく見る小窓。窓に対する割合の dialog で開き、図は小窓の図の欄に縦横とも収める (max 倍まで)
const BIG = { kind: "dialog", width: 0.92, height: 0.9, max: 4 };
const BIG_FAIL = "図を大きく見られない"; // 小窓を開けなかったときのわけの頭
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
// 図の幅・高さ。数でない・0 以下は既定 (520×300)
const sizeOr = (v, d) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : d);
// アプリの zoom (settings.json の zoom)。読めない・数でない・0 以下は 1。on_size_change の大きさは zoom を掛けた後の logical px で、
// w()・h() に渡す px は zoom を掛ける前の px (描くと zoom 倍になる) なので、大きさを zoom で割ってから図の倍率を決める
const appZoom = () => {
  let z;
  try {
    z = settings()?.zoom;
  } catch {
    z = undefined;
  }
  return typeof z === "number" && Number.isFinite(z) && z > 0 ? z : 1;
};
// 大きく見る小窓に渡された図 (props.image)。オブジェクトでなければ null (ふつうの板)
const bigOf = (p) => (p?.image && typeof p.image === "object" && !Array.isArray(p.image) ? p.image : null);

export default class HubPanel extends View {
  init(_props, cx) {
    this.data = null;
    this.error = null;
    this.picked = {};
    this.collapsed = {};
    this.status = "";
    this.busy = false;
    this.width = null;
    this.k = TEXT_BASE; // 字の倍率。render の頭で shared の % から決め直す
    this.handle = cx.focus_handle();
    // 図を大きく見る小窓 (板の図のクリックで、この mod が自分を開いたもの)。panel.json は読まず見張らず、渡された図だけを出す
    this.big = bigOf(props());
    if (this.big) {
      this.bigBox = null; // 図の欄の大きさ (on_size_change の logical px)
      this.bigClosed = false;
      // キーボードを取り、Esc を on_key_down でも受ける (dialog は herdr-app も Esc で閉じる)。開いた直後に focus が元のペインへ戻る
      // ことがあるので、少し後にもう一度取る (pjp-prefix の小窓・herdr-app の picker と同じ。端末に残ると Esc がその端末へ行く)
      this.handle.focus();
      cx.timer.after(50, () => {
        if (!this.bigClosed) this.handle.focus();
      });
      return;
    }
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

  // 板の文字の大きさ (%)。render のたびに shared から読む (どの写しが書いても、herdr-app がすべての mod を描き直す)
  zoom() {
    return zoomOf(shared(ZOOM_KEY));
  }

  // 字の大きさと、字を囲む札・ボタンの高さ・余白・角を、板の倍率で引く。n はこの mod を書いたときの px (100% の 1/1.2)
  fs(n) {
    return Math.round(n * this.k * 10) / 10;
  }

  setZoom(z, cx) {
    setShared(ZOOM_KEY, z);
    cx.notify();
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

  // 選んだ答え。問いの順に 1 つ 1 行で、改行でつなぐ (貼ると、Claude Code の入力欄に複数行の 1 つの入力として入る)
  answerText() {
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
    return parts.join("\n");
  }

  // 改行で区切った字を、1 行ずつの要素にする (答えは 1 つ 1 行。送った後のわけの字も。stderr の CRLF も 1 つの改行とみる)
  lines(text) {
    return v_flex()
      .min_w(0)
      .children(String(text).split(/\r?\n/).map((t) => div().min_w(0).child(t)));
  }

  deliver(cx, submit) {
    const text = this.answerText();
    if (!text || this.busy) return;
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
        // 字を code point の並びで渡す (改行・引用符・日本語を PowerShell の引用の外に置く)。改行は LF のまま入れる
        const codes = Array.from(text).map((ch) => ch.codePointAt(0));
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
        this.status = `${term} に送った:\n${text}`;
        this.picked = {};
        if (closing) {
          const pane = this.ownPane(self);
          if (!pane) {
            this.status = `${term} に送った (閉じるのはハブ):\n${text}`;
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
            .child(div().flex_none().text_color(on ? c.accent : c.dim).child(on ? "●" : "○"))
            // min_w(0): 長い選択肢は縮んで折り返す (付けないと字が 1 行ぶんの幅より縮まず、カードからはみ出す)
            .child(div().min_w(0).font_semibold().text_color(c.fg).child(o.label ?? ""))
            .when(!!o.recommended, (el) => el.child(this.badge("推奨", c.solid, c.solidFg))),
        )
        .when(!!o.desc, (el) => el.child(div().text_size(this.fs(12)).text_color(c.muted).child(o.desc)));
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
          .child(div().flex_1().min_w(0).text_size(this.fs(14)).font_semibold().text_color(c.fg).child(q.title ?? "")),
      )
      .when(!!q.body, (el) => el.child(div().text_color(c.fg).child(TextView.markdown(`hp-qb-${q.id}`, q.body).selectable(true))))
      .children(opts);
  }

  badge(text, bg, fg) {
    return div()
      .flex_none()
      .px(this.fs(6))
      .py(this.fs(1))
      .rounded(this.fs(4))
      .bg(bg)
      .text_color(fg)
      .text_size(this.fs(10))
      .font_semibold()
      .child(text);
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
      .child(div().flex_none().w(this.fs(12)).text_color(c.dim).child(closed ? "▸" : "▾"))
      .child(div().flex_1().min_w(0).text_size(this.fs(13)).font_semibold().text_color(c.fg).child(s.title ?? ""));
    let body = null;
    if (!closed) {
      if (s.type === "markdown")
        body = div().text_size(this.fs(12)).text_color(c.fg).child(TextView.markdown(`hp-md-${id}`, s.text ?? "").selectable(true));
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
        if (si > 0) steps.push(div().text_color(c.dim).text_size(this.fs(11)).child("›"));
        steps.push(this.step(st, `${id}-${ri}-${si}`, c));
      });
      return v_flex()
        .id(`hp-fr-${id}-${ri}`)
        .gap(4)
        .child(
          // 狭いときは sub が次の行へ回り、長い label は縮んで折り返す
          h_flex()
            .flex_wrap()
            .gap(6)
            .items_center()
            .child(div().min_w(0).font_semibold().text_size(this.fs(12)).text_color(c.fg).child(r.label ?? ""))
            .when(!!r.sub, (el) => el.child(div().min_w(0).text_size(this.fs(11)).text_color(c.muted).child(r.sub))),
        )
        .child(h_flex().flex_wrap().gap(4).items_center().children(steps));
    });
    return v_flex().gap(10).children(rows);
  }

  step(st, key, c) {
    const state = st.state ?? "todo";
    const label = st.label ?? ""; // label の無い段は印だけにする (undefined・null を字にしない)
    const tail = label === "" ? "" : ` ${label}`; // 印の後ろに付ける字
    const base = h_flex()
      .id(`hp-st-${key}`)
      .px(this.fs(7))
      .py(this.fs(2))
      .rounded(this.fs(6))
      .border_1()
      .text_size(this.fs(11))
      .gap(this.fs(4))
      .items_center();
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

  // 図 (絵と、その上に重ねる marks) を k 倍で描く。板のペインと大きく見る小窓で同じものを使う。decorate は、子を足す前の箱に
  // id やクリックを付ける関数。縮めない (flex_none。小窓の図の欄で縦に縮められると、marks が絵からずれる)
  figure(s, id, W, H, k, c, decorate = (el) => el) {
    const src = this.imagePath(s.src ?? "");
    const marks = (s.marks ?? []).map((m, mi) => this.mark(m, `${id}-${mi}`, k, c)).filter(Boolean);
    return decorate(div())
      .relative()
      .flex_none()
      .w(W * k)
      .h(H * k)
      .child(image(src).w(W * k).h(H * k))
      .children(marks);
  }

  // 板のペインの図。ペインの幅に合わせて縮め・大きくし (PIC)、クリックで大きく見る小窓を開く
  picture(s, id, c) {
    const W = sizeOr(s.width, 520);
    const H = sizeOr(s.height, 300);
    // on_size_change の幅はアプリの zoom を掛けた後の logical px、w()・h() の px は zoom を掛ける前の px なので、zoom で割ってから
    // 比べる (herdr-app の release notes の図も width / settings().zoom)。幅を知るまで (最初の描画) は等倍
    const avail = this.width == null ? null : this.width / appZoom() - PIC.pad;
    const k = avail == null ? 1 : clamp(avail / W, PIC.min, PIC.max);
    return v_flex()
      .gap(6)
      .child(
        this.figure(s, id, W, H, k, c, (el) =>
          el
            .id(`hp-pic-${id}`)
            .cursor_pointer()
            .hover((st) => st.opacity(0.9))
            .tooltip("クリックで大きく見る (Esc で閉じる)")
            .on_click((_, cx) => this.openBig(s, cx)),
        ),
      )
      .child(
        // 図の説明と、押すと大きく見られるというヒント。狭いときは説明が縮んで折り返し、ヒントは右に残る
        h_flex()
          .gap(8)
          .items_start()
          .when(!!s.caption, (el) =>
            el.child(div().flex_1().min_w(0).text_size(this.fs(11)).text_color(c.muted).child(TextView.markdown(`hp-cap-${id}`, s.caption))),
          )
          .child(div().flex_none().ml_auto().text_size(this.fs(10)).text_color(c.dim).child("クリックで拡大")),
      );
  }

  // 図を大きく見る小窓を開く。開くのはこの mod (MOD の名前) で、props.image に図の節を渡す。写しを試すときは MOD を写しの名前に
  // 書き換える (書き換えないと、写しの図から本物の pjp-hub-panel の小窓が開く)
  openBig(s, cx) {
    try {
      openOverlay({ mod: NAME, kind: BIG.kind, width: BIG.width, height: BIG.height, props: { image: s } });
      // 前に開けなかったわけが残っていれば消す (ほかのわけは残す)
      if (this.status.startsWith(BIG_FAIL)) {
        this.status = "";
        cx.notify();
      }
    } catch (e) {
      this.status = `${BIG_FAIL}: ${e}`;
      cx.notify();
    }
  }

  // 大きく見る小窓を閉じる (1 回だけ)。herdr-app が閉じた後 (close が呼ばれた後) は何もしない
  closeBig() {
    if (this.bigClosed) return;
    this.bigClosed = true;
    const id = props()?.overlay;
    if (id != null) closeOverlay(id);
  }

  // herdr-app がこの写しを閉じるとき (ペインや小窓が閉じた。Esc や外のクリックで閉じた小窓も) に 1 回呼ばれる
  async close() {
    this.bigClosed = true;
  }

  // 大きく見る小窓。上の行に図の題・閉じ方・「閉じる」、まん中の欄に図 (欄に縦横とも収める)、下に図の説明
  renderBig(c) {
    const s = this.big;
    const W = sizeOr(s.width, 520);
    const H = sizeOr(s.height, 300);
    const z = appZoom();
    const box = this.bigBox;
    // 図の欄の大きさ (zoom で割った px) に縦横とも収める。欄の大きさを知るまで (最初の描画) は等倍
    const k = box ? clamp(Math.min(box.width / z / W, box.height / z / H), PIC.min, BIG.max) : 1;
    return v_flex()
      .id("hp-big")
      .track_focus(this.handle)
      .on_key_down((e, cx) => {
        if (e.key !== "escape") return;
        this.closeBig();
        cx.stop_propagation();
      })
      .size_full()
      .min_h(0)
      .p(12)
      .gap(8)
      .bg(c.t.popover ?? c.surface) // herdr-app の dialog の mod (confirm・worktree) と同じく、地を塗る
      .text_size(this.fs(13))
      .text_color(c.fg)
      .child(
        h_flex()
          .gap(8)
          .items_center()
          .child(div().flex_1().min_w(0).text_size(this.fs(15)).font_semibold().child(s.title ?? ""))
          .child(div().flex_none().text_size(this.fs(11)).text_color(c.dim).child("Esc・図のクリックで閉じる"))
          .child(this.button("hp-big-close", "閉じる", false, true, c, () => this.closeBig())),
      )
      .child(
        // 図の欄: 残りの高さを取り (flex_1・min_h(0))、図に押し広げられない (overflow_hidden)。図はまん中に置く
        v_flex()
          .id("hp-big-body")
          .flex_1()
          .min_h(0)
          .min_w(0)
          .overflow_hidden()
          .items_center()
          .justify_center()
          .cursor_pointer()
          // ダブルクリックの 2 回目は数えない (板の図をダブルクリックすると、2 回目が開いたばかりの小窓に落ちる)
          .on_click((e) => {
            if ((e?.click_count ?? 1) > 1) return;
            this.closeBig();
          })
          .on_size_change((size, cx) => {
            const b = this.bigBox;
            if (!b || Math.abs(b.width - size.width) > 1 || Math.abs(b.height - size.height) > 1) {
              this.bigBox = { width: size.width, height: size.height };
              cx.notify();
            }
          })
          .child(this.figure(s, s.id ?? "big", W, H, k, c)),
      )
      .when(!!s.caption, (el) =>
        el.child(div().text_size(this.fs(12)).text_color(c.muted).child(TextView.markdown("hp-big-cap", s.caption).selectable(true))),
      );
  }

  mark(m, key, k, c) {
    const color = this.paint(c, m.color, c.accent);
    if (m.kind === "flow") {
      // 一方向に流れる点。loop は行って戻るので向きを出せない。点を並べた輪 (ring.svg) を spin で回し、矢印の外接矩形で
      // 切り抜く。輪の点の通り道が矢印の中点で矢印に接し、時計回りの向きが矢印の向きになるように輪の中心を置く。
      // 輪の倍率は 2 の 1/4 乗の刻みに丸める (svg() は描く大きさごとに絵を作って持つ。ペインの境を動かしても作る絵の数を抑える)
      const s = Math.max(2 ** (Math.round(Math.log2(Math.max(k, 0.6)) * 4) / 4), 0.6);
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
      .flex_none()
      .h(this.fs(30))
      .px(this.fs(12))
      .items_center()
      .rounded(this.fs(8))
      .border_1()
      .border_color(primary && enabled ? c.solid : c.border)
      .bg(primary && enabled ? c.solid : c.raised)
      .text_color(enabled ? (primary ? c.solidFg : c.fg) : c.dim)
      .text_size(this.fs(12))
      .when(enabled, (el) => el.cursor_pointer().hover((s) => s.opacity(0.88)).on_click(onClick))
      .child(label);
  }

  // 上の行の「− <今の %> +」。押すと板の文字だけを 1 刻みずつ上げ下げし、% で既定に戻す (アプリの zoom は替えない)。
  // 組の大きさは板の % に従わない (atBase)。% の札は「200%」が入る幅を初めから取る。どちらも、押しても組の幅が変わらず、
  // 右に寄せた組の「−」と「%」がポインタの下から動かないため
  zoomControls(z, c) {
    const seg = (id, label, tip, enabled, onClick, color, offColor = c.dim) =>
      h_flex()
        .id(id)
        .flex_none()
        .h(atBase(22))
        .min_w(atBase(22))
        .px(atBase(5))
        .justify_center()
        .items_center()
        .rounded(atBase(5))
        .text_size(atBase(12))
        .text_color(enabled ? color : offColor)
        .tooltip(tip)
        .when(enabled, (el) => el.cursor_pointer().hover((s) => s.bg(c.raised)).on_click(onClick))
        .child(label);
    const changed = z !== ZOOM.def;
    // 押したときの % は、描いたときの z でなく shared から読み直す (描き直す前に 2 回押しても 2 刻み進む)
    const step = (dir) => (_, cx) => this.setZoom(zoomStep(this.zoom(), dir), cx);
    return h_flex()
      .id("hp-zoom")
      .flex_none()
      .gap(atBase(2))
      .p(1)
      .items_center()
      .rounded(atBase(6))
      .border_1()
      .border_color(c.border)
      .child(seg("hp-zoom-out", "−", `板の文字を小さく (${ZOOM.min}% まで)`, z > ZOOM.min, step(-1), c.fg))
      .child(
        seg(
          "hp-zoom-reset",
          `${z}%`,
          changed ? `既定 (${ZOOM.def}%) に戻す` : `板の文字の大きさ (既定 ${ZOOM.def}%)`,
          changed,
          (_, cx) => this.setZoom(ZOOM.def, cx),
          c.accent, // 既定から変えているときは accent で出し、押すと戻せると分かるようにする
          c.muted,
        ).min_w(atBase(46)),
      )
      .child(seg("hp-zoom-in", "+", `板の文字を大きく (${ZOOM.max}% まで)`, z < ZOOM.max, step(1), c.fg));
  }

  render(cx) {
    const c = this.colors();
    const z = this.zoom();
    this.k = (TEXT_BASE * z) / 100; // この描画の fs() の倍率
    if (this.big) return this.renderBig(c);
    const d = this.data;
    const role = this.role();
    const known = role === null || ROLES.includes(role);
    const r = known ? role : null; // 知らない値は、無いときと同じに出す
    const qs = r === "summary" ? [] : (d?.questions ?? []);
    const secs = r === "questions" ? [] : (d?.sections ?? []);
    const text = r === "summary" ? "" : this.answerText();
    const ready = !!text && !this.busy;

    const body = [];
    if (!known) body.push(div().text_color(c.blocked).child(`props.role が分からない: ${JSON.stringify(role)} (summary か questions。無ければ両方を出す)`));
    if (this.error) body.push(div().text_color(c.blocked).child(this.error));
    if (r === "questions") {
      qs.forEach((q, qi) => body.push(this.questionCard(q, qi, c)));
      if (!this.error && d && qs.length === 0) body.push(div().text_color(c.muted).child("問いはありません"));
    } else {
      if (qs.length > 0) {
        body.push(div().text_size(this.fs(12)).font_semibold().text_color(c.accent).child(`質問 (${qs.length})`));
        qs.forEach((q, qi) => body.push(this.questionCard(q, qi, c)));
      }
      if (secs.length > 0) {
        if (qs.length > 0) body.push(div().h(4), div().text_size(this.fs(12)).font_semibold().text_color(c.muted).child("いまの状況"));
        secs.forEach((s, i) => body.push(this.section(s, i, c)));
      }
      if (!this.error && d && qs.length === 0 && secs.length === 0) body.push(div().text_color(c.muted).child("出すものはありません"));
    }
    // 上の帯の題。問いのペインは見出しと件数 (updated も出さない)、ほかは panel.json の title
    const heading = r === "questions" ? (qs.length > 0 ? `問い (${qs.length})` : "問い") : (d?.title ?? "ハブ");

    const hint = this.status || (text ? "Enter (このペインで) か「送信」で送る" : "");
    const footer =
      qs.length === 0
        ? null
        : v_flex()
            .px(14)
            .py(10)
            .gap(8)
            .border_t_1()
            .border_color(c.border)
            // 答えは問いごとに 1 行 (貼る文と同じく改行で区切る)
            .child(div().text_size(this.fs(12)).text_color(text ? c.fg : c.dim).child(text ? this.lines(text) : "選択肢を選ぶと、ここに答えの文が出ます"))
            .child(
              // 狭いときはボタンの組がわけの字の次の行へ回り、組も入らなければ「送信」が次の行へ回る (どちらも右寄せ。ボタンは
              // 縮めない。わけの字は縮んで折り返す)
              h_flex()
                .flex_wrap()
                .gap(8)
                .items_center()
                .when(hint !== "", (el) => el.child(div().flex_auto().min_w(0).text_size(this.fs(11)).text_color(c.dim).child(this.lines(hint))))
                .child(
                  h_flex()
                    .min_w(0)
                    .ml_auto()
                    .flex_wrap()
                    .justify_end()
                    .gap(8)
                    .items_center()
                    .child(this.button("hp-paste", "入力欄に入れる", false, ready, c, (_, cx) => this.deliver(cx, false)))
                    .child(this.button("hp-send", "送信", true, ready, c, (_, cx) => this.deliver(cx, true))),
                ),
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
      .text_size(this.fs(13))
      .text_color(c.fg)
      .child(
        // 上の行: 題と更新の時刻の欄 | 文字の大きさの組。組は折り返さずに右上に留め (items_start)、押しても動かない。
        // 狭いときは欄の中で、更新の時刻が次の行へ回り、題は縮んで折り返す
        h_flex()
          .px(14)
          .py(10)
          .gap(8)
          .items_start()
          .border_b_1()
          .border_color(c.border)
          .child(
            h_flex()
              .flex_1()
              .min_w(0)
              .min_h(BAR_H) // 1 行の題を組と上下の中ほどにそろえる (題が組より高くなれば欄が伸び、組は上に留まる)
              .flex_wrap()
              .content_center()
              .gap_x(8)
              .gap_y(2)
              .items_center()
              .child(div().flex_auto().min_w(0).text_size(this.fs(15)).font_semibold().child(heading))
              .when(r !== "questions" && !!d?.updated, (el) =>
                el.child(div().flex_none().ml_auto().text_size(this.fs(11)).text_color(c.dim).child(d.updated)),
              ),
          )
          .child(this.zoomControls(z, c)),
      )
      .child(v_flex().id("hp-list").flex_1().min_h(0).overflow_y_scrollbar().p(12).gap(10).children(body))
      .when(!!footer, (el) => el.child(footer))
      .when(!footer && !!this.status, (el) =>
        el.child(div().px(14).py(6).border_t_1().border_color(c.border).text_size(this.fs(11)).text_color(c.dim).child(this.lines(this.status))),
      );
  }
}
