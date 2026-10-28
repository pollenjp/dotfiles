// nix/files/claude/footer-links.json の正規表現が、出力のどの行からどのバッジを作るかを確かめる。
//
//   node nix/tests/claude-footer-links.test.mjs [<生成した claude-footer-links.json のパス> <cc-pages の port>]
//
// flake の checks (claude-footer-links-test) が Nix のサンドボックスで、home の設定から作った JSON を
// 既定の port (7777) と 7780 の 2 通りで流す。引数を省けば repo の footer-links.json を読み、cc-page の
// 規則の @ccPagesPort@ を 7777 で埋める (home/modules/claude.nix と同じ置き換え)。
//
// ## 確かめること
//
//   - 各項目の pattern が RegExp として通り、url が http か https の固定 origin で始まる (Claude Code は
//     合わない項目を黙って捨てるので、ここで落とす)
//   - チケット: ticket.sh の書き込み系・new の 1 行と、応答の markdown のリンクから「TKT-n」のバッジを作る。
//     work の WRK-TKT-n は WRK-TKT-n のまま拾う。間に別の ID を挟んだ URL とは組ませず、ID の無い URL・
//     TKT の無い Notion の URL・ID と URL が別の行のもの (ticket.sh show) は拾わない
//   - PR: gh pr create・ticket.sh pr・ticket.sh show の pr 行から「<repo>#<番号>」のバッジを作る。
//     /files などが続いても PR の URL に戻す。ticket.sh list の行に載る PR は拾わない
//   - cc-page: cc-pages new の出力の JSON・応答の「→ URL」の行・markdown のリンクにあるページの URL から
//     「📄<番号>」のバッジを作り、url は末尾に / を付けたそのページの URL にする。題 (日本語も) は JSON の "・
//     markdown の括弧・空白・和文の句読点や括弧の手前で止め、末尾の /・ページの中の場所 (#…)・assets は
//     落とす。題の無いページ・5 桁の番号・長いセッション名も拾う。セッションの top・ほかの port・%XX に
//     符号化された URL は拾わない
//   - 1 行にチケットと PR (と cc-page) があれば、出現順に全部
//
// ## なぜ JavaScript なのか
//
// Claude Code は footerLinksRegexes の pattern を JavaScript の RegExp (フラグ "g") で解釈する。
// PR の項目は可変長の後読み (?<!…[^\n]*) を使っていて、jq (Oniguruma) では書けない。
// 同じ解釈系で流さないと確かめたことにならない。
//
// ## 写しているもの (Claude Code 2.1.292 の本体から。scheme の許可は 2.1.310 で確かめた)
//
//   - url の {名前} は名前付きキャプチャを encodeURIComponent して差し込む。
//     差し込んだあとの origin がテンプレートと違えば捨てる
//   - url のテンプレートは {…} を x にして URL として読み、scheme が許可したもの (https・http など) で
//     なければ項目ごと捨てる
//   - label の {名前} はそのまま差し込み、制御文字を除いて trim し、28 文字で切る
//   - 1 項目あたり、末尾から 20 件までの一致を使う
//   - 全項目の一致を出現位置の順に並べる (footer には新しい順 = この逆順で入る)

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const [file, port] =
  process.argv[2] === undefined
    ? [path.join(here, "../files/claude/footer-links.json"), "7777"]
    : [process.argv[2], process.argv[3] ?? "7777"];
const source = fs.readFileSync(file, "utf8");
// 生成した JSON は埋め終わっているので、置き換えるのは repo の footer-links.json を読むときだけ
const entries = JSON.parse(process.argv[2] === undefined ? source.replaceAll("@ccPagesPort@", port) : source);

const PH = /\{([^{}]+)\}/g;
const DOTSEG = /^(?:\.|%2e){1,2}$/i;
const LABEL_MAX = 28;
const KEEP_PER_PATTERN = 20;

const origin = (u) => (u.origin !== "null" ? u.origin : `${u.protocol}//${u.host}`);

function fillUrl(tpl, g) {
  const s = tpl.replace(PH, (_, n) => encodeURIComponent(Object.hasOwn(g, n) ? g[n] ?? "" : ""));
  const q = s.search(/[?#]/);
  return (q === -1 ? s : s.slice(0, q)).split(/[/\\]/).some((x) => DOTSEG.test(x)) ? null : s;
}

function badges(text) {
  const out = [];
  for (const e of entries) {
    const pin = origin(new URL(e.url.replace(PH, "x")));
    const kept = [...text.matchAll(new RegExp(e.pattern, "g"))].slice(-KEEP_PER_PATTERN);
    for (const m of kept) {
      const g = m.groups ?? {};
      const url = fillUrl(e.url, g);
      if (url === null || origin(new URL(url)) !== pin) continue;
      const raw = e.label ? e.label.replace(PH, (_, k) => (Object.hasOwn(g, k) ? g[k] ?? "" : "")) : m[0];
      const label = [...raw.replace(/[\x00-\x1f\x7f]/g, "").trim()].slice(0, LABEL_MAX).join("");
      if (label !== "") out.push({ index: m.index, label, url });
    }
  }
  return out.sort((a, b) => a.index - b.index).map(({ label, url }) => [label, url]);
}

let pass = 0;
let fail = 0;
function check(name, got, want) {
  if (JSON.stringify(got) === JSON.stringify(want)) {
    pass++;
    console.log(`  ok   ${name}`);
  } else {
    fail++;
    console.log(`  FAIL ${name}\n       got:  ${JSON.stringify(got)}\n       want: ${JSON.stringify(want)}`);
  }
}

console.log(`== footer-links.json: ${file} (cc-pages の port: ${port})`);

// 項目の形。Claude Code は合わない項目を黙って捨てるので、ここで落とす
for (const [i, e] of entries.entries()) {
  let compiled = true;
  try {
    new RegExp(e.pattern, "g");
  } catch {
    compiled = false;
  }
  let scheme = null;
  try {
    scheme = new URL(e.url.replace(PH, "x")).protocol;
  } catch {
    scheme = null;
  }
  check(`項目 ${i + 1}: pattern が RegExp として通る`, compiled, true);
  check(`項目 ${i + 1}: url が http か https の固定 origin で始まる`, ["http:", "https:"].includes(scheme), true);
}

const page127 = "https://app.notion.com/p/Dev-Tracker-PR-Claude-Code-footer-3f579149a66f81029fa3f704c2f81b58";
const page125 = "https://app.notion.com/p/herdr-pane-Dev-Tracker-0492724891bc49e3a73d5726d35e3be1";
const pageWrk = "https://app.notion.com/p/Bar-111111111111111111111111cccccccc";
const pr106 = "https://github.com/pollenjp/dotfiles/pull/106";

// チケット
check("ticket.sh の書き込み系の 1 行 (TKT-n: …  URL)", badges(`TKT-127: メモに追記した  ${page127}`), [["TKT-127", page127]]);
check("ticket.sh new の 1 行 (TKT-n  URL)", badges(`TKT-127  ${page127}\n  タイトル  [Todo / P2 / Feature]`), [["TKT-127", page127]]);
check("応答の markdown のリンク", badges(`関連: [TKT-125](${page125})`), [["TKT-125", page125]]);
check("間に別の ID を挟んだ URL とは組ませない", badges(`TKT-125 の後続で TKT-127: ${page127}`), [["TKT-127", page127]]);
check("work の WRK-TKT-n (TKT-n だけを拾わない)", badges(`WRK-TKT-13  ${pageWrk}`), [["WRK-TKT-13", pageWrk]]);
check("ID の無いチケットの URL は拾わない (show --url)", badges(page125), []);
check("TKT の無い Notion の URL は拾わない (ticket.sh repo)", badges("pollenjp/dotfiles  https://app.notion.com/p/pollenjp-dotfiles-3e479149a66f8165a565d712b1a9e0f8"), []);
check("ID と URL が別の行なら拾わない (show の id / url 行)", badges(`id        TKT-125\nurl       ${page125}`), []);

// PR
check("gh pr create の出力", badges(pr106), [["dotfiles#106", pr106]]);
check("ticket.sh pr の出力", badges(`TKT-127: PR ${pr106} (OPEN)`), [["dotfiles#106", pr106]]);
check("ticket.sh show の pr 行", badges("pr        https://github.com/pollenjp/dotfiles/pull/88"), [["dotfiles#88", "https://github.com/pollenjp/dotfiles/pull/88"]]);
check("/files などが続いても PR の URL に戻す", badges("https://github.com/pollenjp/claude-skills/pull/40/files"), [["claude-skills#40", "https://github.com/pollenjp/claude-skills/pull/40"]]);
check(
  "ticket.sh list の行に載る PR は拾わない (タグの有無とも)",
  badges(
    [
      "pollenjp/dotfiles: 2 件 (未完了)",
      "  TKT-67   In Review    P2  nix                  週 1 回 nix の GC  [home-manager, Nix]  https://github.com/pollenjp/dotfiles/pull/88",
      "  TKT-41   Todo         P2  -                    PR 全体の差分  https://github.com/pollenjp/dotfiles/pull/77",
    ].join("\n"),
  ),
  [],
);

// cc-page。url は末尾に / を付けた正規の形 (cc-pages は / の無い形を 301 で送る) で、題は encodeURIComponent される
const session = "20261028-bd1be6e0";
const otherPort = port === "7777" ? "7780" : "7777";
const ccPage = (page, s = session, p = port) => `http://localhost:${p}/p/${s}/${page}`;
const ccBadge = (num, page, s = session) => [`📄${num}`, `${ccPage(encodeURIComponent(page), s)}/`];
const titled = "0001-workspace-の名前を会話の始めに付ける";

check(
  "cc-pages new の出力の JSON",
  badges(`{"id":"0001","dir":"/home/u/.local/share/cc-pages/sessions/${session}/${titled}","url":"${ccPage(titled)}"}`),
  [ccBadge("0001", titled)],
);
check("応答の「→ URL」の行", badges(`- 案 A で進める\n→ ${ccPage(titled)}`), [ccBadge("0001", titled)]);
check(
  "markdown のリンク (ticket.sh show の関連ページも)",
  badges(`[cc-page: Notion callout の調査](${ccPage("0002-notion-callout-の調査")})`),
  [ccBadge("0002", "0002-notion-callout-の調査")],
);
check(
  "末尾の /・ページの中の場所 (#…)・assets は落とす",
  badges([`${ccPage("0003-foo")}/`, `${ccPage("0003-foo")}/#toc`, `${ccPage("0003-foo")}/assets/fig.svg`].join("\n")),
  [ccBadge("0003", "0003-foo"), ccBadge("0003", "0003-foo"), ccBadge("0003", "0003-foo")],
);
check(
  "題は和文の句読点・括弧・空白・inline code・強調の手前で止める",
  badges(
    `「${ccPage("0005-設計の比較")}」を見て、${ccPage("0006-案-a")}。（${ccPage("0007-x")}） \`${ccPage("0008-y")}\` **${ccPage("0009-z")}**`,
  ),
  [
    ccBadge("0005", "0005-設計の比較"),
    ccBadge("0006", "0006-案-a"),
    ccBadge("0007", "0007-x"),
    ccBadge("0008", "0008-y"),
    ccBadge("0009", "0009-z"),
  ],
);
check(
  "々・全角の英数字・丸数字は題のうち",
  badges(`${ccPage("0010-様々な案①とｐｒ２")} を見て`),
  [ccBadge("0010", "0010-様々な案①とｐｒ２")],
);
check("題の無いページ (番号だけ)", badges(ccPage("0004")), [ccBadge("0004", "0004")]);
check(
  "5 桁の番号と、重なって長くなったセッション名",
  badges(ccPage("10000-foo", "20261028-bd1be6e0-a1b")),
  [ccBadge("10000", "10000-foo", "20261028-bd1be6e0-a1b")],
);
check("セッションの top は拾わない (cc-pages status の出力)", badges(`{"url":"${ccPage("")}"}`), []);
check("ほかの port のページは拾わない", badges(ccPage(titled, session, otherPort)), []);
check(
  "%XX に符号化された URL は拾わない (拾うと二重に符号化されて開けない)",
  badges(ccPage(`0001-workspace-${encodeURIComponent("の名前")}`)),
  [],
);

// 混在
check(
  "1 行にチケットと PR と cc-page があれば出現順に全部",
  badges(`TKT-127: ${page127} と ${pr106} → ${ccPage(titled)}`),
  [["TKT-127", page127], ["dotfiles#106", pr106], ccBadge("0001", titled)],
);

console.log(`== ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
