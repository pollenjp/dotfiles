// nix/files/claude/footer-links.json の正規表現が、出力のどの行からどのバッジを作るかを確かめる。
//
//   node nix/tests/claude-footer-links.test.mjs [<footer-links.json のパス>]
//
// flake の checks (claude-footer-links-test) が Nix のサンドボックスで流す。
//
// ## なぜ JavaScript なのか
//
// Claude Code は footerLinksRegexes の pattern を JavaScript の RegExp (フラグ "g") で解釈する。
// PR の項目は可変長の後読み (?<!…[^\n]*) を使っていて、jq (Oniguruma) では書けない。
// 同じ解釈系で流さないと確かめたことにならない。
//
// ## 写しているもの (Claude Code 2.1.292 の本体から)
//
//   - url の {名前} は名前付きキャプチャを encodeURIComponent して差し込む。
//     差し込んだあとの origin がテンプレートと違えば捨てる
//   - label の {名前} はそのまま差し込み、制御文字を除いて trim し、28 文字で切る
//   - 1 項目あたり、末尾から 20 件までの一致を使う
//   - 全項目の一致を出現位置の順に並べる (footer には新しい順 = この逆順で入る)

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const file = process.argv[2] ?? path.join(here, "../files/claude/footer-links.json");
const entries = JSON.parse(fs.readFileSync(file, "utf8"));

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

console.log(`== footer-links.json: ${file}`);

// 項目の形。Claude Code は合わない項目を黙って捨てるので、ここで落とす
for (const [i, e] of entries.entries()) {
  let compiled = true;
  try {
    new RegExp(e.pattern, "g");
  } catch {
    compiled = false;
  }
  check(`項目 ${i + 1}: pattern が RegExp として通る`, compiled, true);
  check(`項目 ${i + 1}: url が https の固定 origin で始まる`, new URL(e.url.replace(PH, "x")).protocol, "https:");
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

// 混在
check(
  "1 行にチケットと PR があれば出現順に両方",
  badges(`TKT-127: ${page127} と ${pr106}`),
  [
    ["TKT-127", page127],
    ["dotfiles#106", pr106],
  ],
);

console.log(`== ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
