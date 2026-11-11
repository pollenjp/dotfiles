// Claude Code の Stop フックの本体。会話に出たリンク (footer のバッジと同じ規則で拾う PR・チケット・cc-page) を、
// cc-pages の会話のトップページの「リンク」の節に全部残す (cc-pages link に渡す)。footer のバッジは今の branch の PR を
// 含めて 5 個までで (Claude Code の本体が決めていて設定では増やせない)、長い会話では前に出たリンクが押し出されるため。
//
//   node footer-links-archive.mjs --cc-pages <path>                                     hook の口 (stdin に Stop の入力の JSON)
//   node footer-links-archive.mjs --cc-pages <path> --session <id> --transcript <path>   手で流す口 (1 つの会話を 0 から)
//
// 入口の footer-links-archive.sh が、cc-pages と node の有無と CC_PAGES_DISABLE を見てから、cc-pages の path を付けて起こす
// (node は PATH の mise のもの。home の閉包には入れない)。設計は dotfiles-private の
// docs/superpowers/specs/2026-11-11-footer-links-archive-design.md、使い方は nix/README.md の「溢れたリンクを会話のトップページに
// 残す」。
//
// ## 動き (hook の口)
//
//   1. 入力の session_id・transcript_path・last_assistant_message を取る
//   2. 会話ごとの控え (${XDG_STATE_HOME:-~/.local/state}/pjp-footer-links-archive/sessions/<session_id>.json) から、前回どこ
//      まで読んだか (byte の offset) を取る。控えが無い・transcript が控えより短い・別のファイル (パスか inode が違う) なら 0 から
//   3. offset から、開いたときの大きさまでのうち、最後の改行までの行だけを読む (書きかけの最後の行は次に回す)
//   4. 行から照らす文を取り出し、footer の規則を当ててリンクを作る。last_assistant_message にも当てる (Stop の時点で
//      transcript に最後の応答が書かれているとは限らないため。次の回に transcript から同じものを渡しても cc-pages が 1 つにまとめる)
//   5. リンクがあれば cc-pages link --session <session_id> --stdin に JSON Lines で 1 回で渡し、0 で終わったら offset を進める。
//      失敗したら進めない (次の回に同じ所から読み直す)。リンクが無ければ呼ばずに進める
//
// 何が起きても終了コード 0 で、stdout にも stderr にも何も出さない (Stop の stdout の JSON は decision: "block" などとして
// 読まれうる)。link を知らない古い cc-pages (「不明なサブコマンド: link」で 1) では offset を進めず、その binary (realpath・dev・
// ino・size・mtime) を控え (cc-pages-without-link.json)、同じ binary の間は transcript を読まずに抜ける (build し直したら、
// 溜まった分をまとめて渡す)。30 日より古い会話の控えは、1 日に 1 回消す (.pruned の時刻で見る)。
//
// ## 拾う文と当て方 (footer と同じ)
//
// 照らす片は、type が assistant の行の message の text block (source assistant) と、type が user で isMeta でない行の tool_result の
// 中身 (文字列か text block。source tool)。isSidechain・agentId のある行 (subagent) は拾わない。at はその行の timestamp。
// 規則は ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json の footerLinksRegexes で、url と label の埋め方・捨てる url は本体を写した
// claude-skills の skills/pjp-question-footer/hooks/links.ts と同じ。footer と違い、片を末尾 8192 字に切らず、一致も 1 片の
// 1 つの規則で前から 1000 件まで見る (全部を残すのが役目なので。上限はおかしな入力に備えたもの)。上限に当たった片には、footer が
// 見る末尾 8192 字にも当て直して足す (footer に出たものは必ず残す)。片の頭には改行を 1 つ足して当てる (片の頭も行の頭として、
// PR の規則の後読み (ticket.sh list の行を外す) を効かせる)。
//
// 組 (group) は URL の形で決める: github.com の PR は PR、app.notion.com/p/ はチケット、cc-page の規則の型紙と同じ origin
// (http://localhost:<このマシンの cc-pages の port>。home-manager が規則に埋めている) の /p/ は cc-page、ほかは「その他」。
// 同じ URL は (url, source) ごとに、最初と最後の時刻の 2 行にまとめて渡す (cc-pages のまとめ方では結果が変わらない)。

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const MATCHES_PER_PIECE = 1000;
const FOOTER_PIECE = 8192; // footer が 1 片で見る末尾の字数
const URL_LENGTH = 2048;
const CHUNK = 4 * 1024 * 1024;
const CC_PAGES_TIMEOUT_MS = 30_000;
const DAY_MS = 24 * 60 * 60 * 1000;
const KEEP_MS = 30 * DAY_MS;

// cc-pages の session id の検証 (文字・数字・-) の ASCII の部分。控えのファイル名にも使う
const SESSION_ID = /^[A-Za-z0-9-]+$/;
const RFC3339 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
const SCHEMES = new Set(["http:", "https:"]);
const PLACEHOLDER = /\{([^{}]+)\}/g;
const DOT_SEGMENT = /^(?:\.|%2e){1,2}$/i;
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g;
// CSI (SGR を含む)・OSC (OSC 8 のリンクを含む)・2 文字の ESC の並び・C1 の CSI
const ESCAPES = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[@-Z\\-_]|\x9b[0-?]*[ -/]*[@-~]/g;
const CONTROLS = /[\x00-\x1f\x7f-\x9f]/g;
const PR_URL = /^https:\/\/github\.com\/[^/?#]+\/[^/?#]+\/pull\/\d+$/;
const TICKET_PREFIX = "https://app.notion.com/p/";

const USAGE = `会話に出たリンク (footer と同じ規則で拾う PR・チケット・cc-page) を cc-pages の会話のトップページに残す。

使い方:
  footer-links-archive.mjs --cc-pages <path>                                    Stop フックとして (stdin に Stop の入力)
  footer-links-archive.mjs --cc-pages <path> --session <id> --transcript <path>  1 つの会話を 0 から流す (報告は stderr)
  footer-links-archive.mjs -h, --help                                           これ
`;

class UsageError extends Error {}

function parseArgs(argv) {
  const names = { "--cc-pages": "ccPages", "--session": "session", "--transcript": "transcript" };
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "-h" || arg === "--help") {
      opts.help = true;
    } else if (Object.hasOwn(names, arg)) {
      if (i + 1 >= argv.length) throw new UsageError(`${arg} に値がありません`);
      opts[names[arg]] = argv[++i];
    } else {
      throw new UsageError(`不明な引数です: ${arg}`);
    }
  }
  return opts;
}

const homeDir = () => os.homedir();
const expandHome = (p) => (p === "~" ? homeDir() : p.startsWith("~/") ? path.join(homeDir(), p.slice(2)) : p);
const stateDirectory = () =>
  path.join(process.env.XDG_STATE_HOME || path.join(homeDir(), ".local", "state"), "pjp-footer-links-archive");
const settingsPath = () => path.join(process.env.CLAUDE_CONFIG_DIR || path.join(homeDir(), ".claude"), "settings.json");

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

// 一時ファイルに書いてから rename する (同じ会話の Stop が重なっても、読みかけの控えを作らない)
function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value)}\n`);
  fs.renameSync(tmp, file);
}

function parseUrl(text) {
  try {
    return new URL(text);
  } catch {
    return null;
  }
}

const originOf = (url) => (url.origin !== "null" ? url.origin : `${url.protocol}//${url.host}`);

// url の型紙の origin。{…} を x にして読み、http(s) でなければ規則ごと使わない
function templateOrigin(template) {
  const url = parseUrl(template.replace(PLACEHOLDER, "x"));
  return url !== null && SCHEMES.has(url.protocol) ? originOf(url) : null;
}

const groupValue = (groups, name) => (Object.hasOwn(groups, name) ? (groups[name] ?? "") : "");

// url の {名前} を encodeURIComponent した値で埋める。?・# より前に .・.. の段があれば null
function fillUrl(template, groups) {
  const url = template.replace(PLACEHOLDER, (_, name) => encodeURIComponent(groupValue(groups, name).replace(LONE_SURROGATE, "�")));
  const cut = url.search(/[?#]/);
  const head = cut === -1 ? url : url.slice(0, cut);
  return head.split(/[/\\]/).some((segment) => DOT_SEGMENT.test(segment)) ? null : url;
}

const fillLabel = (template, groups) => template.replace(PLACEHOLDER, (_, name) => groupValue(groups, name));

// settings.json の footerLinksRegexes のうち、footer が使うもの (type が regex で pattern・url が文字列、label は無いか文字列、
// pattern が RegExp になり、url の型紙が http(s)) だけ
function loadRules() {
  const list = readJson(settingsPath())?.footerLinksRegexes;
  if (!Array.isArray(list)) return [];
  const rules = [];
  for (const entry of list) {
    if (typeof entry !== "object" || entry === null) continue;
    const { type, pattern, url, label } = entry;
    if (type !== "regex" || typeof pattern !== "string" || typeof url !== "string") continue;
    if (label !== undefined && typeof label !== "string") continue;
    let re;
    try {
      re = new RegExp(pattern, "g");
    } catch {
      continue;
    }
    const origin = templateOrigin(url);
    if (origin !== null) rules.push({ re, url, label, origin });
  }
  return rules;
}

// cc-page の規則 (型紙が http://localhost:<port>/p/…) の origin。home-manager がこのマシンの cc-pages の port で埋めている
function ccPagesOrigin(rules) {
  for (const rule of rules) {
    const url = parseUrl(rule.url.replace(PLACEHOLDER, "x"));
    if (url !== null && url.protocol === "http:" && url.hostname === "localhost" && url.pathname.startsWith("/p/")) {
      return originOf(url);
    }
  }
  return null;
}

function groupOf(url, ccOrigin) {
  if (PR_URL.test(url)) return "PR";
  if (url.startsWith(TICKET_PREFIX)) return "チケット";
  if (ccOrigin !== null && url.startsWith(`${ccOrigin}/p/`)) return "cc-page";
  return "その他";
}

// 1 つの一致をリンクにする (使えなければ null)。base は text の中での一致の位置の足し分
function linkOf(rule, match, base) {
  const groups = match.groups ?? {};
  const url = fillUrl(rule.url, groups);
  if (url === null || url.length > URL_LENGTH) return null;
  const parsed = parseUrl(url);
  if (parsed === null || originOf(parsed) !== rule.origin) return null;
  const raw = rule.label === undefined ? match[0] : fillLabel(rule.label, groups);
  const label = raw.replace(ESCAPES, "").replace(CONTROLS, "").trim();
  return label === "" ? null : { index: base + match.index, url, label };
}

// text に規則を当てたリンク (出現位置の順)。1 つの規則で見る一致は前から MATCHES_PER_PIECE まで。上限に当たったら、footer が
// 見る末尾 FOOTER_PIECE 字にも当て直して足す (重なったものは後でまとめる)
function findLinks(rules, text) {
  const found = [];
  for (const rule of rules) {
    try {
      let seen = 0;
      let capped = false;
      for (const match of text.matchAll(rule.re)) {
        if (++seen > MATCHES_PER_PIECE) {
          capped = true;
          break;
        }
        const link = linkOf(rule, match, 0);
        if (link !== null) found.push(link);
      }
      if (capped && text.length > FOOTER_PIECE) {
        const base = text.length - FOOTER_PIECE;
        for (const match of text.slice(base).matchAll(rule.re)) {
          const link = linkOf(rule, match, base);
          if (link !== null) found.push(link);
        }
      }
    } catch {
      continue;
    }
  }
  return found.sort((a, b) => a.index - b.index);
}

// 拾ったリンクを (url, source) ごとにまとめ、渡す JSON Lines の行にする
class Links {
  constructor(rules) {
    this.rules = rules;
    this.ccOrigin = ccPagesOrigin(rules);
    this.entries = new Map();
    this.found = 0;
  }

  // at は RFC 3339 の文字列か undefined (cc-pages が今の時刻にする)。at の無いものは、あるものと別にまとめる
  add(text, source, at) {
    const when = typeof at === "string" && RFC3339.test(at) && !Number.isNaN(Date.parse(at)) ? at : undefined;
    for (const { url, label } of findLinks(this.rules, `\n${text}`)) {
      this.found++;
      const key = `${url}\u0000${source}\u0000${when === undefined ? "now" : "at"}`;
      const entry = this.entries.get(key);
      if (entry === undefined) {
        this.entries.set(key, { url, label, group: groupOf(url, this.ccOrigin), source, first: when, last: when });
      } else if (when !== undefined) {
        if (Date.parse(when) < Date.parse(entry.first)) entry.first = when;
        if (Date.parse(when) > Date.parse(entry.last)) entry.last = when;
      }
    }
  }

  get urls() {
    return new Set([...this.entries.values()].map((entry) => entry.url)).size;
  }

  lines() {
    const out = [];
    const timed = [...this.entries.values()].filter((entry) => entry.first !== undefined);
    const untimed = [...this.entries.values()].filter((entry) => entry.first === undefined);
    for (const { url, label, group, source, first, last } of timed) {
      out.push({ url, label, group, source, at: first });
      if (last !== first) out.push({ url, label, group, source, at: last });
    }
    for (const { url, label, group, source } of untimed) out.push({ url, label, group, source });
    return out;
  }
}

function resultText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n");
}

// transcript の 1 行から照らす片 (text block か tool_result ごと)。拾わない行は null
function piecesOf(row) {
  if (typeof row !== "object" || row === null || row.isSidechain === true) return null;
  if (row.agentId !== undefined && row.agentId !== null) return null;
  const content = row.message?.content;
  if (!Array.isArray(content)) return null;
  let texts;
  let source;
  if (row.type === "assistant") {
    texts = content.filter((block) => block?.type === "text" && typeof block.text === "string").map((block) => block.text);
    source = "assistant";
  } else if (row.type === "user" && row.isMeta !== true) {
    texts = content.filter((block) => block?.type === "tool_result").map((block) => resultText(block.content));
    source = "tool";
  } else {
    return null;
  }
  texts = texts.filter((text) => text !== "");
  return texts.length === 0 ? null : { texts, source, at: row.timestamp };
}

// transcript を saved の offset (使えなければ 0) から、開いたときの大きさまでの完全な行だけ読み、行ごとに onLine を呼ぶ。
// 読めなければ null。返す end は最後に読んだ改行の後ろ
function readTranscript(file, saved, onLine) {
  let fd;
  try {
    fd = fs.openSync(file, "r");
  } catch {
    return null;
  }
  try {
    const st = fs.fstatSync(fd, { bigint: true });
    const dev = String(st.dev);
    const ino = String(st.ino);
    const size = Number(st.size);
    const resume =
      saved !== null &&
      typeof saved === "object" &&
      saved.transcript === file &&
      saved.dev === dev &&
      saved.ino === ino &&
      Number.isSafeInteger(saved.offset) &&
      saved.offset >= 0 &&
      saved.offset <= size;
    const start = resume ? saved.offset : 0;
    let end = start;
    let pos = start;
    let carry = Buffer.alloc(0);
    const buffer = Buffer.allocUnsafe(Math.min(CHUNK, Math.max(size - start, 1)));
    while (pos < size) {
      const n = fs.readSync(fd, buffer, 0, Math.min(buffer.length, size - pos), pos);
      if (n <= 0) break;
      const data = carry.length === 0 ? buffer.subarray(0, n) : Buffer.concat([carry, buffer.subarray(0, n)]);
      const base = pos - carry.length;
      pos += n;
      let from = 0;
      let newline;
      while ((newline = data.indexOf(0x0a, from)) !== -1) {
        onLine(data.toString("utf8", from, newline));
        end = base + newline + 1;
        from = newline + 1;
      }
      carry = Buffer.from(data.subarray(from));
    }
    return { dev, ino, start, end };
  } finally {
    fs.closeSync(fd);
  }
}

function collect(rules, file, saved) {
  const links = new Links(rules);
  const stats = { lines: 0, broken: 0 };
  const read = readTranscript(file, saved, (line) => {
    if (line.trim() === "") return;
    stats.lines++;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      stats.broken++;
      return;
    }
    const pieces = piecesOf(row);
    if (pieces !== null) for (const text of pieces.texts) links.add(text, pieces.source, pieces.at);
  });
  return read === null ? null : { ...read, links, stats };
}

function binaryIdentity(file) {
  try {
    const real = fs.realpathSync(file);
    const st = fs.statSync(real, { bigint: true });
    return { path: real, dev: String(st.dev), ino: String(st.ino), size: String(st.size), mtimeNs: String(st.mtimeNs) };
  } catch {
    return null;
  }
}

const sameIdentity = (a, b) =>
  a !== null && b !== null && typeof a === "object" && ["path", "dev", "ino", "size", "mtimeNs"].every((key) => a[key] === b[key]);

function callCcPages(ccPages, sessionId, lines) {
  const r = spawnSync(ccPages, ["link", "--session", sessionId, "--stdin"], {
    input: lines.map((line) => `${JSON.stringify(line)}\n`).join(""),
    encoding: "utf8",
    timeout: CC_PAGES_TIMEOUT_MS,
    maxBuffer: 16 * 1024 * 1024,
  });
  const stderr = r.stderr ?? "";
  return {
    ok: r.error === undefined && r.status === 0,
    old: r.status === 1 && stderr.includes("不明なサブコマンド"),
    status: r.status,
    error: r.error,
    stdout: r.stdout ?? "",
    stderr,
  };
}

// cc-pages が受け取ったら控えを書き、古い cc-pages の控えを合わせる
function settle(stateDir, ccPages, sessionId, file, read, result) {
  const oldFile = path.join(stateDir, "cc-pages-without-link.json");
  if (result !== null && !result.ok) {
    if (result.old) {
      const binary = binaryIdentity(ccPages);
      if (binary !== null) writeJson(oldFile, binary);
    }
    return false;
  }
  if (result !== null && fs.existsSync(oldFile)) fs.rmSync(oldFile, { force: true });
  writeJson(path.join(stateDir, "sessions", `${sessionId}.json`), { transcript: file, dev: read.dev, ino: read.ino, offset: read.end });
  return true;
}

// 30 日より古い会話の控え (と書きかけの一時ファイル) を消す。見るのは 1 日に 1 回
function prune(stateDir) {
  try {
    const marker = path.join(stateDir, ".pruned");
    const now = Date.now();
    try {
      if (now - fs.statSync(marker).mtimeMs < DAY_MS) return;
    } catch {
      // 印が無ければ見る
    }
    fs.mkdirSync(stateDir, { recursive: true });
    fs.writeFileSync(marker, "");
    const dir = path.join(stateDir, "sessions");
    for (const name of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
      const file = path.join(dir, name);
      try {
        if (now - fs.statSync(file).mtimeMs > KEEP_MS) fs.rmSync(file, { force: true });
      } catch {
        // 消えていればよい
      }
    }
  } catch {
    // 掃除できなくても本題は続ける
  }
}

function hookMode(ccPages) {
  if (ccPages === undefined) return;
  let input;
  try {
    input = JSON.parse(fs.readFileSync(0, "utf8"));
  } catch {
    return;
  }
  if (typeof input !== "object" || input === null) return;
  const sessionId = input.session_id;
  if (typeof sessionId !== "string" || !SESSION_ID.test(sessionId)) return;
  if (typeof input.transcript_path !== "string" || input.transcript_path === "") return;
  const stateDir = stateDirectory();
  prune(stateDir);
  const rules = loadRules();
  if (rules.length === 0) return;
  // link を知らない古い cc-pages のうちは、transcript を読まない (build し直して binary が替われば、また渡す)
  if (sameIdentity(readJson(path.join(stateDir, "cc-pages-without-link.json")), binaryIdentity(ccPages))) return;
  const file = path.resolve(expandHome(input.transcript_path));
  const read = collect(rules, file, readJson(path.join(stateDir, "sessions", `${sessionId}.json`)));
  if (read === null) return;
  if (typeof input.last_assistant_message === "string") read.links.add(input.last_assistant_message, "assistant", undefined);
  const lines = read.links.lines();
  const result = lines.length === 0 ? null : callCcPages(ccPages, sessionId, lines);
  if (result === null && read.end === read.start) return;
  settle(stateDir, ccPages, sessionId, file, read, result);
}

function manualMode(opts) {
  const say = (text) => process.stderr.write(`footer-links-archive: ${text}\n`);
  if (opts.ccPages === undefined) throw new UsageError("--cc-pages がありません");
  if (opts.session === undefined || opts.transcript === undefined) throw new UsageError("--session と --transcript は組で渡します");
  if (!SESSION_ID.test(opts.session)) throw new UsageError(`session id は英数字と - だけです: ${opts.session}`);
  const rules = loadRules();
  if (rules.length === 0) {
    say(`footer の規則がありません (${settingsPath()} の footerLinksRegexes)`);
    return 1;
  }
  const file = path.resolve(expandHome(opts.transcript));
  const read = collect(rules, file, null);
  if (read === null) {
    say(`transcript を読めません: ${file}`);
    return 1;
  }
  const broken = read.stats.broken === 0 ? "" : `、JSON でない行 ${read.stats.broken}`;
  say(`${file} の ${read.end} byte (${read.stats.lines} 行${broken}) から、リンクを ${read.links.found} 件 (URL ${read.links.urls} 個) 拾いました`);
  const lines = read.links.lines();
  const stateDir = stateDirectory();
  if (lines.length === 0) {
    settle(stateDir, opts.ccPages, opts.session, file, read, null);
    return 0;
  }
  const result = callCcPages(opts.ccPages, opts.session, lines);
  if (result.stdout.trim() !== "") say(`cc-pages: ${result.stdout.trim()}`);
  if (result.stderr.trim() !== "") process.stderr.write(`${result.stderr.trimEnd()}\n`);
  if (!settle(stateDir, opts.ccPages, opts.session, file, read, result)) {
    if (result.old) say("cc-pages が link を知りません (古い cc-pages)。cc-pages を build し直してください");
    else say(`cc-pages link が失敗しました (${result.error?.message ?? `終了コード ${result.status}`})`);
    return 1;
  }
  return 0;
}

function main() {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`footer-links-archive: ${error.message}\n\n${USAGE}`);
    return 2;
  }
  if (opts.help) {
    process.stdout.write(USAGE);
    return 0;
  }
  if (opts.session === undefined && opts.transcript === undefined) {
    try {
      hookMode(opts.ccPages);
    } catch {
      // hook の口は何が起きても黙って 0 で終わる
    }
    return 0;
  }
  try {
    return manualMode(opts);
  } catch (error) {
    if (error instanceof UsageError) {
      process.stderr.write(`footer-links-archive: ${error.message}\n\n${USAGE}`);
      return 2;
    }
    process.stderr.write(`footer-links-archive: ${error.stack ?? error}\n`);
    return 1;
  }
}

process.exitCode = main();
