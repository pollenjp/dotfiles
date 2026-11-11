// nix/files/claude/hooks/footer-links-archive.mjs (Stop フックの本体) を、使い捨ての HOME・作った transcript・偽の cc-pages で
// 確かめる。入口の footer-links-archive.sh も、本物の node で 1 回通す。
//
//   node nix/tests/footer-links-archive.test.mjs [<hooks の dir> <生成した claude-footer-links.json のパス> <cc-pages の port>]
//
// flake の checks (footer-links-archive-test) が Nix のサンドボックスで、repo の hooks の dir と、home の設定から作った規則を
// 既定の port (7777) と 7780 の 2 通りで渡して流す。引数を省けば repo の hooks と footer-links.json を読み、cc-page の規則の
// @ccPagesPort@ を 7777 で埋める (home/modules/claude.nix と同じ置き換え)。偽の cc-pages は、この node (process.execPath) を
// shebang にした script で、受け取った引数と stdin を書き留める。
//
// ## 確かめること
//
//   - 拾う文: assistant の行の text block (source assistant) と、isMeta でない user の行の tool_result の中身 (文字列か
//     text block。source tool)。at はその行の timestamp。PR・チケット・cc-page を、footer と同じ url と label にし、組
//     (PR・チケット・cc-page) を付けて、cc-pages link --session <id> --stdin に 1 回で渡す
//   - 拾わない文: ユーザーが打った文 (文字列の content・tool_result でない text block)・isMeta の tool_result・isSidechain の行・
//     agentId のある行・thinking・tool_use の入力・ほかの type の行 (api-request-blob・attachment)・tool の出力の先頭にある
//     ticket.sh list の行 (片の頭も行の頭として PR の規則の後読みを当てる)
//   - 当て方: label の無い規則は一致した文字が label。型紙と origin の違う url・?・# より前に .. の段のある url・2048 字を
//     超える url は捨てる。label は ANSI と制御文字を除いて trim する。RegExp にならない規則・type が regex でない規則・
//     scheme が http(s) でない規則は使わない。組は URL の形で、どれでもなければ「その他」。1 片の 1 つの規則で前から 1000 件まで
//     見て、超えた片は footer が見る末尾 8192 字の一致も足す。label は 200 字までに切る
//   - 渡す JSON Lines は 1 回 1 MiB 以下に分けて順に打つ。途中の呼び出しが落ちたら残りを打たず offset を進めず、次の回に初めから
//     全部を渡し直す。全部の呼び出しが 0 で終わったときだけ offset を進める
//   - 同じ URL は (url, source) ごとに、最初と最後の時刻の 2 行にまとめる
//   - 読み方: 書きかけの最後の行 (改行が無い) は読まず、改行が来た次の回に拾う。控えより短くなった transcript・別の
//     ファイル (パスか inode が違う) は 0 から読み直す。4 MiB の読みの塊をまたぐ長い行と、塊の境目にかかる日本語も拾う。
//     transcript_path の頭の ~/ は HOME。JSON でない行・空の行は飛ばす
//   - 控え: cc-pages が 0 で終われば offset を進め、失敗したら進めない (次の回に同じリンクを渡す)。リンクが無ければ cc-pages を
//     呼ばずに offset を進める。link を知らない古い cc-pages では進めず (渡す量が多く、stdin を読まずに抜けた古い cc-pages への
//     書き込みが EPIPE になっても見分ける)、同じ binary の間は transcript を開かず (FIFO に替えて見る) cc-pages も呼ばない。
//     build し直して binary が替われば、溜まった分を渡す。30 日より古い会話の控えを消し、見るのは 1 日に 1 回
//   - Stop の入力の last_assistant_message のリンクも渡す (source assistant、at なし)
//   - hook の口は stdout にも stderr にも何も出さず、終了コード 0。規則が無い・session id の形が違う・transcript が無い・
//     stdin が JSON でないときは、cc-pages を呼ばない
//   - $CLAUDE_CONFIG_DIR が立っていれば、その settings.json の規則を読む
//   - 手で流す口 (--session と --transcript) は transcript を 0 から読み、拾った数と cc-pages の答えを stderr に出す (stdout は空)。
//     cc-pages が失敗すれば終了コード 1 で、その stderr も出す
//   - 入口の footer-links-archive.sh を本物の node で起こすと、PATH の cc-pages に渡し、stdout に何も出さず 0 で終わる

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const hooksDir = process.argv[2] ?? path.join(here, "../files/claude/hooks");
const [rulesFile, port] =
  process.argv[3] === undefined
    ? [path.join(here, "../files/claude/footer-links.json"), "7777"]
    : [process.argv[3], process.argv[4] ?? "7777"];
const rulesSource = fs.readFileSync(rulesFile, "utf8");
// 生成した JSON は埋め終わっているので、置き換えるのは repo の footer-links.json を読むときだけ
const rules = JSON.parse(process.argv[3] === undefined ? rulesSource.replaceAll("@ccPagesPort@", port) : rulesSource);
const body = path.join(hooksDir, "footer-links-archive.mjs");
const entry = path.join(hooksDir, "footer-links-archive.sh");

const work = fs.mkdtempSync(path.join(os.tmpdir(), "footer-links-archive-test."));
process.on("exit", () => fs.rmSync(work, { recursive: true, force: true }));

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

// 偽の cc-pages。FAKE_CC_PAGES_MODE が ok なら受け取った行の数を added にした 1 行の JSON を出して 0、fail なら stderr に
// 1 行出して 1、fail-second なら書き留めが 1 件だけあるとき (2 回目の呼び出し) に fail と同じく 1、old なら古い cc-pages と同じ文を
// 出して 1 (stdin を読まずに抜ける)。どれも引数 (と stdin) を書き留める
const FAKE_CC_PAGES = `#!${process.execPath}
const fs = require("node:fs");
const mode = process.env.FAKE_CC_PAGES_MODE || "ok";
const log = process.env.FAKE_CC_PAGES_LOG;
const before = fs.existsSync(log) ? fs.readFileSync(log, "utf8").split("\\n").filter(Boolean).length : 0;
const input = mode === "old" ? "" : fs.readFileSync(0, "utf8");
fs.appendFileSync(log, JSON.stringify({ argv: process.argv.slice(2), input }) + "\\n");
if (mode === "old") {
  process.stderr.write("cc-pages: 不明なサブコマンド: link\\n");
  process.exit(1);
}
if (mode === "fail" || (mode === "fail-second" && before === 1)) {
  process.stderr.write("cc-pages: 書けない\\n");
  process.exit(1);
}
const added = input.split("\\n").filter(Boolean).length;
process.stdout.write(JSON.stringify({ url: "http://localhost:${port}/p/20261111-5b3f99c8/", added, updated: 0, skipped: 0 }) + "\\n");
`;

const SID = "5b3f99c8-206d-4f10-a25c-404756fcc1ea";
const ts = (n) => `2026-11-11T07:${String(Math.floor(n / 60)).padStart(2, "0")}:${String(n % 60).padStart(2, "0")}.000Z`;
const pr = (n) => `https://github.com/o/r/pull/${n}`;
const prLink = (n, source, at) => ({ url: pr(n), label: `r#${n}`, group: "PR", source, ...(at === undefined ? {} : { at }) });
const ticketUrl = "https://app.notion.com/p/Foo-0123456789abcdef0123456789abcdef";
const ccRaw = (title) => `http://localhost:${port}/p/20261111-5b3f99c8/${title}`;
const ccUrl = (title) => `http://localhost:${port}/p/20261111-5b3f99c8/${encodeURIComponent(title)}/`;

const assistantText = (text, n, extra = {}) => ({
  parentUuid: null,
  isSidechain: false,
  type: "assistant",
  uuid: `a${n}`,
  timestamp: ts(n),
  sessionId: SID,
  message: { role: "assistant", content: [{ type: "text", text }] },
  ...extra,
});
const toolResult = (content, n, extra = {}) => ({
  parentUuid: null,
  isSidechain: false,
  type: "user",
  uuid: `u${n}`,
  timestamp: ts(n),
  sessionId: SID,
  message: { role: "user", content: [{ type: "tool_result", tool_use_id: `toolu_${n}`, content }] },
  ...extra,
});
const userPrompt = (content, n) => ({ isSidechain: false, type: "user", uuid: `p${n}`, timestamp: ts(n), message: { role: "user", content } });
const jsonl = (rows) => rows.map((row) => `${JSON.stringify(row)}\n`).join("");

let caseNo = 0;
// newCase: 使い捨ての HOME (settings.json に規則)・XDG_STATE_HOME・偽の cc-pages・transcript の置き場所
function newCase({ settings = { footerLinksRegexes: rules } } = {}) {
  const dir = path.join(work, `case${++caseNo}`);
  const home = path.join(dir, "home");
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  if (settings !== null) fs.writeFileSync(path.join(home, ".claude/settings.json"), JSON.stringify(settings));
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin);
  const ccPages = path.join(bin, "cc-pages");
  fs.writeFileSync(ccPages, FAKE_CC_PAGES, { mode: 0o755 });
  return {
    dir,
    home,
    bin,
    ccPages,
    mode: "ok",
    log: path.join(dir, "cc-pages.log"),
    stateDir: path.join(dir, "state/pjp-footer-links-archive"),
    transcript: path.join(dir, "session.jsonl"),
    env: {},
  };
}
function envOf(c) {
  return {
    PATH: process.env.PATH,
    HOME: c.home,
    XDG_STATE_HOME: path.join(c.dir, "state"),
    FAKE_CC_PAGES_LOG: c.log,
    FAKE_CC_PAGES_MODE: c.mode,
    ...c.env,
  };
}
const hookInput = (c, extra = {}) => ({
  session_id: SID,
  transcript_path: c.transcript,
  cwd: c.dir,
  hook_event_name: "Stop",
  stop_hook_active: false,
  ...extra,
});
// runHook: hook の口で本体を起こす。input が文字列ならそのまま stdin に流す。opts は spawnSync に足す (timeout など)
function runHook(c, input = hookInput(c), opts = {}) {
  return spawnSync(process.execPath, [body, "--cc-pages", c.ccPages], {
    input: typeof input === "string" ? input : JSON.stringify(input),
    env: envOf(c),
    encoding: "utf8",
    ...opts,
  });
}
function runManual(c, transcript = c.transcript) {
  return spawnSync(process.execPath, [body, "--cc-pages", c.ccPages, "--session", SID, "--transcript", transcript], {
    input: "",
    env: envOf(c),
    encoding: "utf8",
  });
}
const quiet = (r) => ({ status: r.status, stdout: r.stdout, stderr: r.stderr });
const QUIET = { status: 0, stdout: "", stderr: "" };
function calls(c) {
  return fs.existsSync(c.log)
    ? fs
        .readFileSync(c.log, "utf8")
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line))
    : [];
}
const sent = (call) =>
  call.input
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
const lastSent = (c) => {
  const all = calls(c);
  return all.length === 0 ? null : sent(all[all.length - 1]);
};
// k 回目 (0 から) より後の呼び出しで渡した行を、呼んだ順につないだもの
const sentFrom = (c, k) => calls(c).slice(k).flatMap(sent);
const saved = (c) => {
  try {
    return JSON.parse(fs.readFileSync(path.join(c.stateDir, "sessions", `${SID}.json`), "utf8"));
  } catch {
    return null;
  }
};

console.log(`== footer-links-archive.mjs: ${body} (規則: ${rulesFile}、cc-pages の port: ${port})`);

// 拾う文: PR (assistant)・チケット (tool の文字列)・cc-page (tool の text block、題に日本語)
{
  const c = newCase();
  const title = "0001-設計の比較";
  fs.writeFileSync(
    c.transcript,
    jsonl([
      userPrompt("前の PR https://github.com/o/r/pull/99 を見て", 1),
      assistantText(`PR は ${pr(12)} です`, 2),
      toolResult(`TKT-12: メモに追記した  ${ticketUrl}`, 3),
      toolResult([{ type: "text", text: `{"id":"0001","url":"${ccRaw(title)}"}` }], 4),
    ]),
  );
  const r = runHook(c);
  check("hook の口は stdout・stderr に何も出さず 0 で終わる", quiet(r), QUIET);
  check("cc-pages link --session <id> --stdin を 1 回呼ぶ", calls(c).map((x) => x.argv), [["link", "--session", SID, "--stdin"]]);
  check("PR・チケット・cc-page を、url・label・組・出どころ・時刻を付けて渡す", lastSent(c), [
    prLink(12, "assistant", ts(2)),
    { url: ticketUrl, label: "TKT-12", group: "チケット", source: "tool", at: ts(3) },
    { url: ccUrl(title), label: "📄0001", group: "cc-page", source: "tool", at: ts(4) },
  ]);
}

// 拾わない文
{
  const c = newCase();
  fs.writeFileSync(
    c.transcript,
    jsonl([
      userPrompt(`これを見て ${pr(1)}`, 1),
      { type: "user", timestamp: ts(2), message: { role: "user", content: [{ type: "text", text: `画像と ${pr(2)}` }] } },
      toolResult(`${pr(3)}`, 3, { isMeta: true }),
      assistantText(`${pr(4)}`, 4, { isSidechain: true }),
      assistantText(`${pr(5)}`, 5, { agentId: "a1b2c3" }),
      { type: "assistant", timestamp: ts(6), message: { role: "assistant", content: [{ type: "thinking", thinking: pr(6) }] } },
      {
        type: "assistant",
        timestamp: ts(7),
        message: { role: "assistant", content: [{ type: "tool_use", id: "toolu_7", name: "Bash", input: { command: `gh pr view ${pr(7)}` } }] },
      },
      { type: "api-request-blob", timestamp: ts(8), message: { role: "assistant", content: [{ type: "text", text: pr(8) }] } },
      { type: "attachment", timestamp: ts(9), attachment: { type: "text", content: pr(9) } },
      toolResult(`  TKT-1    In Review    P2  nix                  題  [99.Nix]  ${pr(10)}`, 10),
      assistantText(`拾う ${pr(11)}`, 11),
    ]),
  );
  runHook(c);
  check(
    "ユーザーの文・isMeta・isSidechain・agentId・thinking・tool_use・ほかの type・ticket.sh list の行は拾わない",
    lastSent(c),
    [prLink(11, "assistant", ts(11))],
  );
}

// 当て方 (作り物の規則)
{
  const c = newCase({
    settings: {
      footerLinksRegexes: [
        { type: "regex", pattern: "\\bISSUE-(?<n>\\d+)\\b", url: "https://example.com/issues/{n}" },
        { type: "regex", pattern: "HOST:(?<h>[a-z.]+)", url: "https://{h}/x", label: "{h}" },
        { type: "regex", pattern: "DOT:(?<d>[.]+)", url: "https://example.com/d/{d}/x", label: "dot" },
        { type: "regex", pattern: "LONG:(?<l>[a-z]+)", url: "https://example.com/l/{l}", label: "long" },
        { type: "regex", pattern: "(", url: "https://example.com/broken" },
        { type: "glob", pattern: "ISSUE", url: "https://example.com/glob" },
        { type: "regex", pattern: "MAIL:(?<m>\\w+)", url: "mailto:{m}@example.com" },
        { type: "regex", pattern: "LBL:(?<v>\\w+)", url: "https://example.com/v/{v}", label: "\u001b[1m {v}\u0007 \u001b[0m" },
        { type: "regex", pattern: "NOLABEL", url: "https://example.com/n", label: 3 },
      ],
    },
  });
  fs.writeFileSync(c.transcript, jsonl([assistantText(`ISSUE-7 HOST:evil.example DOT:.. LONG:${"a".repeat(2100)} MAIL:x NOLABEL LBL:abc`, 1)]));
  runHook(c);
  check(
    "label の無い規則は一致した文字・origin 違い・.. の段・2048 字超・壊れた規則は捨て、label の制御文字を除く・組は「その他」",
    lastSent(c),
    [
      { url: "https://example.com/issues/7", label: "ISSUE-7", group: "その他", source: "assistant", at: ts(1) },
      { url: "https://example.com/v/abc", label: "abc", group: "その他", source: "assistant", at: ts(1) },
    ],
  );
}

// 1 片の 1 つの規則で前から 1000 件。超えたら footer が見る末尾 8192 字の一致も足す (footer に出たものは残す)
{
  const c = newCase();
  const many = Array.from({ length: 1500 }, (_, i) => pr(i + 1)).join("\n");
  fs.writeFileSync(c.transcript, jsonl([toolResult(many, 1)]));
  runHook(c);
  const urls = new Set((lastSent(c) ?? []).map((link) => link.url));
  check(
    "1 片に別々の PR が 1500 個あれば、前から 1000 個と、footer が見る末尾 8192 字の分を渡す",
    [urls.has(pr(1)), urls.has(pr(1000)), urls.has(pr(1001)), urls.has(pr(1253)), urls.has(pr(1500)), urls.size],
    [true, true, false, true, true, 1248],
  );
}

// 同じ URL は (url, source) ごとに最初と最後の時刻の 2 行
{
  const c = newCase();
  fs.writeFileSync(
    c.transcript,
    jsonl([
      assistantText(`${pr(12)} と ${pr(12)}`, 1),
      assistantText(pr(12), 2),
      toolResult(pr(12), 3),
      assistantText(pr(12), 4),
      assistantText(`${pr(12)} ${pr(13)}`, 5),
    ]),
  );
  runHook(c);
  check("同じ URL は (url, source) ごとに最初と最後の時刻の 2 行にまとめる", lastSent(c), [
    prLink(12, "assistant", ts(1)),
    prLink(12, "assistant", ts(5)),
    prLink(12, "tool", ts(3)),
    prLink(13, "assistant", ts(5)),
  ]);
}

// 書きかけの最後の行は次の回に
{
  const c = newCase();
  const done = jsonl([assistantText(pr(21), 1)]);
  const writing = JSON.stringify(assistantText(pr(22), 2));
  fs.writeFileSync(c.transcript, done + writing);
  runHook(c);
  check("書きかけの最後の行 (改行が無い) は読まない", lastSent(c), [prLink(21, "assistant", ts(1))]);
  check("控えの offset は最後の改行の後ろ", saved(c)?.offset, Buffer.byteLength(done));
  fs.appendFileSync(c.transcript, "\n");
  runHook(c);
  check("改行が来た次の回に、その行だけを渡す", [calls(c).length, lastSent(c)], [2, [prLink(22, "assistant", ts(2))]]);
  runHook(c);
  check("新しい行が無ければ呼ばない", calls(c).length, 2);
}

// 控えより短くなった transcript と、別のファイルは 0 から
{
  const c = newCase();
  fs.writeFileSync(c.transcript, jsonl([assistantText(`${"長い文 ".repeat(50)}${pr(30)}`, 1), assistantText(pr(31), 2)]));
  runHook(c);
  fs.writeFileSync(c.transcript, jsonl([assistantText(pr(32), 3)]));
  runHook(c);
  check("控えより短くなった transcript は 0 から読み直す", lastSent(c), [prLink(32, "assistant", ts(3))]);

  const other = path.join(c.dir, "other.jsonl");
  fs.writeFileSync(other, jsonl([assistantText(pr(33), 4), assistantText(`${"長い文 ".repeat(80)}${pr(34)}`, 5)]));
  runHook(c, hookInput(c, { transcript_path: other }));
  check("transcript_path が変われば 0 から読む", lastSent(c), [prLink(33, "assistant", ts(4)), prLink(34, "assistant", ts(5))]);

  const swapped = path.join(c.dir, "swapped.jsonl");
  fs.writeFileSync(
    swapped,
    jsonl([assistantText(pr(35), 6), assistantText(`${"長い文 ".repeat(80)}${pr(36)}`, 7), assistantText(`${"長い文 ".repeat(80)}${pr(37)}`, 8)]),
  );
  fs.renameSync(swapped, other);
  runHook(c, hookInput(c, { transcript_path: other }));
  check("同じパスでも inode が替われば 0 から読む", lastSent(c), [
    prLink(35, "assistant", ts(6)),
    prLink(36, "assistant", ts(7)),
    prLink(37, "assistant", ts(8)),
  ]);
}

// 4 MiB の読みの塊をまたぐ長い行と、塊の境目にかかる日本語
{
  const c = newCase();
  const longText = `${"あ".repeat(1_500_000)} ${pr(50)} ${"い".repeat(10)}`;
  fs.writeFileSync(c.transcript, jsonl([toolResult(longText, 1), assistantText(pr(51), 2)]));
  runHook(c);
  check("4 MiB を超える 1 行と、その後ろの行も拾う", lastSent(c), [prLink(50, "tool", ts(1)), prLink(51, "assistant", ts(2))]);
}

// transcript_path の頭の ~/ と、壊れた行
{
  const c = newCase();
  fs.writeFileSync(
    path.join(c.home, "t.jsonl"),
    ["{壊れた行", "", '"文字列"', "null", "[1,2]", JSON.stringify(assistantText(pr(60), 1)), ""].join("\n"),
  );
  const r = runHook(c, hookInput(c, { transcript_path: "~/t.jsonl" }));
  check("transcript_path の頭の ~/ を HOME にし、JSON でない行・空の行は飛ばす", [quiet(r), lastSent(c)], [QUIET, [prLink(60, "assistant", ts(1))]]);
}

// cc-pages が失敗したら offset を進めない
{
  const c = newCase();
  fs.writeFileSync(c.transcript, jsonl([assistantText(pr(70), 1)]));
  c.mode = "fail";
  const r = runHook(c);
  check("cc-pages が失敗しても stdout・stderr に何も出さず 0", quiet(r), QUIET);
  check("cc-pages が失敗したら offset を進めない", saved(c)?.offset ?? 0, 0);
  c.mode = "ok";
  runHook(c);
  check("次の回に同じリンクを渡し、成功したら進める", [calls(c).length, lastSent(c), saved(c)?.offset], [
    2,
    [prLink(70, "assistant", ts(1))],
    fs.statSync(c.transcript).size,
  ]);
}

// リンクが無ければ cc-pages を呼ばずに進める
{
  const c = newCase();
  fs.writeFileSync(c.transcript, jsonl([assistantText("リンクは無い", 1), toolResult("ok", 2)]));
  const r = runHook(c);
  check("リンクが無ければ cc-pages を呼ばずに offset を進める", [quiet(r), calls(c).length, saved(c)?.offset], [
    QUIET,
    0,
    fs.statSync(c.transcript).size,
  ]);
}

// link を知らない古い cc-pages。古い cc-pages は stdin を読まずに抜けるので、渡す行を子との間の受け口に収まらない大きさ (1 MB 超。
// 9000 件) にして、書き込みが EPIPE で失敗しても古い cc-pages と見分けることも見る
{
  const c = newCase();
  const rows = Array.from({ length: 10 }, (_, k) =>
    assistantText(Array.from({ length: 900 }, (_, i) => pr(k * 900 + i + 1)).join(" "), k + 1),
  );
  fs.writeFileSync(c.transcript, jsonl(rows));
  c.mode = "old";
  const r = runHook(c);
  check("古い cc-pages でも stdout・stderr に何も出さず 0 で、offset を進めない", [quiet(r), saved(c)?.offset ?? 0], [QUIET, 0]);
  // 2 回目は transcript を FIFO に替える。開けば書き手が来るまで止まるので、時間内に 0 で返れば開いていない
  fs.rmSync(c.transcript);
  spawnSync("mkfifo", [c.transcript]);
  const second = runHook(c, hookInput(c), { timeout: 10_000 });
  check("同じ binary の間は transcript を開かず、cc-pages も呼ばない", [second.error?.code ?? null, second.status, calls(c).length], [
    null,
    0,
    1,
  ]);
  fs.rmSync(c.transcript);
  fs.writeFileSync(c.transcript, jsonl(rows));
  fs.appendFileSync(c.ccPages, "// build し直した\n");
  c.mode = "ok";
  runHook(c);
  check("binary が替われば、溜まった分を渡す", [sentFrom(c, 1).length, sentFrom(c, 1)[0]], [9000, prLink(1, "assistant", ts(1))]);
}

// 渡す JSON Lines は 1 回 1 MiB までに分けて打ち (cc-pages は 1 回の入力の 16 MiB を超えた分を読まない)、全部の呼び出しが 0 で
// 終わったときだけ offset を進める
{
  const c = newCase();
  const rows = Array.from({ length: 24 }, (_, k) =>
    assistantText(Array.from({ length: 900 }, (_, i) => pr(k * 900 + i + 1)).join(" "), k + 1),
  );
  fs.writeFileSync(c.transcript, jsonl(rows));
  const all = Array.from({ length: 21600 }, (_, i) => prLink(i + 1, "assistant", ts(Math.floor(i / 900) + 1)));
  c.mode = "fail-second";
  const r = runHook(c);
  check("途中の呼び出しが落ちたら、残りを打たず、offset を進めない", [quiet(r), calls(c).length, saved(c)?.offset ?? 0], [QUIET, 2, 0]);
  c.mode = "ok";
  runHook(c);
  const batches = calls(c).slice(2);
  check(
    "次の回は初めから、1 回 1 MiB 以下に分けて全部を順に渡し、全部 0 なら offset を進める",
    [
      batches.length > 1,
      batches.every((call) => Buffer.byteLength(call.input) <= 1024 * 1024),
      batches.every((call) => JSON.stringify(call.argv) === JSON.stringify(["link", "--session", SID, "--stdin"])),
      JSON.stringify(sentFrom(c, 2)) === JSON.stringify(all),
      saved(c)?.offset,
    ],
    [true, true, true, true, fs.statSync(c.transcript).size],
  );
}

// label は 200 字までに切る (cc-pages と同じ。1 行を cc-pages の上限の 64 KiB に収める)
{
  const c = newCase({
    settings: { footerLinksRegexes: [{ type: "regex", pattern: "LONG:[a-z]+", url: "https://example.com/long" }] },
  });
  fs.writeFileSync(c.transcript, jsonl([assistantText(`LONG:${"a".repeat(70_000)}`, 1)]));
  runHook(c);
  const got = lastSent(c) ?? [];
  check("label の無い規則の長い一致は、label を前から 200 字に切る", [got.length, got[0]?.label], [1, `LONG:${"a".repeat(195)}`]);
}

// 30 日より古い会話の控えを消す (見るのは 1 日に 1 回)
{
  const c = newCase();
  fs.writeFileSync(c.transcript, jsonl([assistantText("リンクは無い", 1)]));
  const sessions = path.join(c.stateDir, "sessions");
  fs.mkdirSync(sessions, { recursive: true });
  const at = (days) => new Date(Date.now() - days * 24 * 60 * 60 * 1000);
  const put = (name, days) => {
    const p = path.join(sessions, name);
    fs.writeFileSync(p, "{}\n");
    fs.utimesSync(p, at(days), at(days));
    return p;
  };
  const old = put("old-session.json", 31);
  const recent = put("recent-session.json", 1);
  runHook(c);
  check("30 日より古い控えを消し、新しいものは残す", [fs.existsSync(old), fs.existsSync(recent)], [false, true]);
  const old2 = put("old-session-2.json", 31);
  runHook(c);
  check("1 日のうちに 2 回目は見ない", fs.existsSync(old2), true);
  const marker = path.join(c.stateDir, ".pruned");
  if (fs.existsSync(marker)) fs.utimesSync(marker, at(2), at(2));
  runHook(c);
  check("前に見てから 1 日たてば、また消す", fs.existsSync(old2), false);
}

// last_assistant_message
{
  const c = newCase();
  fs.writeFileSync(c.transcript, jsonl([assistantText(pr(100), 1)]));
  runHook(c, hookInput(c, { last_assistant_message: `最後に ${pr(101)} と ${pr(101)} を出した` }));
  check("last_assistant_message のリンクも渡す (source assistant、at なし)", lastSent(c), [
    prLink(100, "assistant", ts(1)),
    prLink(101, "assistant"),
  ]);
}

// 何もしない場面
{
  const noSettings = newCase({ settings: null });
  fs.writeFileSync(noSettings.transcript, jsonl([assistantText(pr(110), 1)]));
  const noRules = newCase({ settings: { model: "opus" } });
  fs.writeFileSync(noRules.transcript, jsonl([assistantText(pr(110), 1)]));
  const badSession = newCase();
  fs.writeFileSync(badSession.transcript, jsonl([assistantText(pr(110), 1)]));
  const noTranscript = newCase();
  const notJson = newCase();
  fs.writeFileSync(notJson.transcript, jsonl([assistantText(pr(110), 1)]));
  const results = [
    runHook(noSettings),
    runHook(noRules),
    runHook(badSession, hookInput(badSession, { session_id: "../x" })),
    runHook(noTranscript),
    runHook(notJson, "{壊れた入力"),
  ];
  check(
    "規則が無い・settings.json が無い・session id の形が違う・transcript が無い・stdin が JSON でないときは呼ばずに 0",
    [results.map(quiet), [noSettings, noRules, badSession, noTranscript, notJson].map((x) => calls(x).length)],
    [Array(5).fill(QUIET), [0, 0, 0, 0, 0]],
  );
}

// $CLAUDE_CONFIG_DIR の settings.json
{
  const c = newCase({ settings: { model: "opus" } });
  const configDir = path.join(c.dir, "claude-personal");
  fs.mkdirSync(configDir);
  fs.writeFileSync(path.join(configDir, "settings.json"), JSON.stringify({ footerLinksRegexes: rules }));
  c.env = { CLAUDE_CONFIG_DIR: configDir };
  fs.writeFileSync(c.transcript, jsonl([assistantText(pr(120), 1)]));
  runHook(c);
  check("$CLAUDE_CONFIG_DIR が立っていれば、その settings.json の規則を読む", lastSent(c), [prLink(120, "assistant", ts(1))]);
}

// 手で流す口
{
  const c = newCase();
  fs.writeFileSync(c.transcript, jsonl([assistantText(pr(130), 1), toolResult(`TKT-12: 追記した  ${ticketUrl}`, 2)]));
  const first = runManual(c);
  const second = runManual(c);
  check(
    "手で流す口は 0 から読み (控えが末尾でも)、stdout は空で 0",
    [first.status, first.stdout, second.status, calls(c).map((x) => sent(x).length)],
    [0, "", 0, [2, 2]],
  );
  check("拾った数と cc-pages の答えを stderr に出す", [/2 件/.test(first.stderr), first.stderr.includes('"added":2')], [true, true]);
  c.mode = "fail";
  const failed = runManual(c);
  check("cc-pages が失敗すれば終了コード 1 で、その stderr も出す", [failed.status, failed.stderr.includes("書けない")], [1, true]);
}

// 入口 (footer-links-archive.sh) を本物の node で通す
{
  const c = newCase();
  fs.writeFileSync(c.transcript, jsonl([assistantText(pr(140), 1)]));
  const r = spawnSync("bash", [entry], {
    input: JSON.stringify(hookInput(c)),
    env: { ...envOf(c), PATH: `${c.bin}:${path.dirname(process.execPath)}:${process.env.PATH}` },
    encoding: "utf8",
  });
  check("入口は PATH の cc-pages に渡し、stdout に何も出さず 0 で終わる", [r.status, r.stdout, lastSent(c)], [
    0,
    "",
    [prLink(140, "assistant", ts(1))],
  ]);
}

console.log(`== ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
