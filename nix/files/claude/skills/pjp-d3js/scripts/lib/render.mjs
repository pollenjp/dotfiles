// chart module (*.mjs) を読み込み、返った SVG 要素を <out-dir>/<名前>.svg に書く。
//
// d3js-export.sh から呼ぶ。PJP_D3JS_NODE_MODULES は devShell (flake.nix) が渡す。
//
//   node render.mjs --out-dir <dir> [--transparent] -- <file.mjs>...
//
// ## なぜ要るか
//
// Node には DOM が無いので、D3 も Plot もそのままでは要素を作れない。ファイルごとに
// linkedom の window と document を作って global に置き、ブラウザ向けの書き方
// (d3.create("svg")・Plot.plot({...})) のまま動かす。
//
// chart module はプロジェクトの d3js/ に置くので、そこから "d3" を import しても
// node_modules が見つからない。skill の node_modules は store にあり、skill の中に
// 置くこともできない (skill 自体が store へコピーされ読み取り専用になる)。そこで
// resolve hook を足し、ふつうの解決で見つからないパッケージ名だけを skill の
// node_modules から探し直す。プロジェクトが自前の d3 を持っていればそちらが先に使われる。

import { mkdirSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { basename, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

const SVG_NS = "http://www.w3.org/2000/svg";

function die(message) {
  console.error(message);
  process.exit(1);
}

const nodeModules = process.env.PJP_D3JS_NODE_MODULES;
if (!nodeModules) die("PJP_D3JS_NODE_MODULES がありません。d3js-export.sh から呼んでください");

// 探し直すときの呼び出し元。node_modules の親ディレクトリにあるファイルに見立てると、
// Node はそこから node_modules/<パッケージ名> を探す。
const fallbackParent = pathToFileURL(`${resolve(nodeModules, "..")}/`).href;

// "./x" "../x" "/x" や "node:fs" "file:///x" のような URL ではないもの = パッケージ名
const isPackageName = (specifier) => !/^(\.{0,2}\/|[a-zA-Z][a-zA-Z0-9+.-]*:)/.test(specifier);

registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (err) {
      if (err?.code !== "ERR_MODULE_NOT_FOUND" || !isPackageName(specifier)) throw err;
      try {
        return nextResolve(specifier, { ...context, parentURL: fallbackParent });
      } catch (err2) {
        if (err2?.code === "ERR_MODULE_NOT_FOUND") {
          err2.message += "\n(skill の node_modules にあるのは d3・@observablehq/plot・linkedom とその依存だけ)";
        }
        throw err2;
      }
    }
  },
});

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    "out-dir": { type: "string", default: "out" },
    transparent: { type: "boolean", default: false },
  },
});
if (positionals.length === 0) die("chart module (*.mjs) を渡してください");

// hook を足したあとで読む (linkedom も skill の node_modules にある)。
const { parseHTML } = await import("linkedom");

function toSvgElement(node) {
  if (node == null) {
    throw new Error("default export の関数が何も返していません (最後に return svg.node(); と書く)");
  }
  // d3 の selection を返したときは中の要素を取り出す
  if (typeof node.node === "function") node = node.node();
  const tag = String(node.tagName ?? "").toLowerCase();
  if (tag === "figure") {
    throw new Error(
      "SVG ではなく <figure> が返りました。Plot は title・subtitle・caption や legend を付けると " +
        "figure (HTML) を返します。題は図の外に書き、凡例はマークで描いてください (references/troubleshooting.md)",
    );
  }
  if (tag !== "svg") throw new Error(`SVG 要素ではなく ${tag ? `<${tag}>` : typeof node} が返りました`);
  if (!node.getAttribute("xmlns")) node.setAttribute("xmlns", SVG_NS);
  return node;
}

// 白背景を先頭に敷く。viewBox が 0,0 から始まるとは限らない (力学グラフは原点を
// 中心にしがち) ので、viewBox があればその範囲、無ければ width / height を覆う。
function addWhiteBackground(svg, document) {
  const rect = document.createElementNS(SVG_NS, "rect");
  const box = (svg.getAttribute("viewBox") ?? "").trim().split(/[\s,]+/).map(Number);
  if (box.length === 4 && box.every(Number.isFinite)) {
    const [x, y, width, height] = box;
    rect.setAttribute("x", String(x));
    rect.setAttribute("y", String(y));
    rect.setAttribute("width", String(width));
    rect.setAttribute("height", String(height));
  } else {
    rect.setAttribute("width", svg.getAttribute("width") ?? "100%");
    rect.setAttribute("height", svg.getAttribute("height") ?? "100%");
  }
  rect.setAttribute("fill", "#ffffff");
  svg.insertBefore(rect, svg.firstChild);
}

async function renderOne(file) {
  // ファイルごとに document を作り直す。前の図が body に足した要素を持ち越さない。
  const { window, document } = parseHTML("<!doctype html><html><head></head><body></body></html>");
  globalThis.window = window;
  globalThis.document = document;

  const mod = await import(pathToFileURL(resolve(file)).href);
  if (typeof mod.default !== "function") {
    throw new Error("default export が関数ではありません (export default function () { …; return svg.node(); })");
  }
  const svg = toSvgElement(await mod.default({ document }));
  if (!values.transparent) addWhiteBackground(svg, document);

  writeFileSync(resolve(values["out-dir"], `${basename(file, ".mjs")}.svg`), `${svg.outerHTML}\n`);
}

mkdirSync(values["out-dir"], { recursive: true });

// 1 つ失敗しても残りは書き出し、最後にまとめて失敗を返す (直す箇所を 1 回で全部見せる)。
let failed = 0;
for (const file of positionals) {
  try {
    await renderOne(file);
  } catch (err) {
    failed += 1;
    console.error(`✗ ${file}`);
    console.error(err?.stack ?? String(err));
  }
}
if (failed > 0) die(`${failed} 件の chart module が失敗しました`);
