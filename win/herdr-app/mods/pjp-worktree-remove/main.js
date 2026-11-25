// pjp-worktree-remove: 今の space の端末を全部止め、終わるのを待ってから space を閉じて worktree を消す小窓。prefix の小窓 (pjp-prefix) の Shift+D が、
// 開く前の space を props の space に入れて開く (mod.open:pjp-worktree-remove や palette から開くと、focus のある space)。
//
// なぜ: herdr-app 0.1.16 の同梱の mod worktree の Remove worktree は、space.close を打ってすぐ git worktree remove を打つ。space.close (run) は端末が
// 終わるのを待たないので、Windows では shell や agent がまだ worktree のフォルダを今のフォルダにしている間に git が消しに行き、
// 「failed to delete '…': Permission denied」で落ちる (git は中身と登録を消してから落ちるので、空のフォルダだけが残る)。ここでは端末が終わった
// (hc の state が finished) のを確かめてから消す。
//
// 流れ (1〜4 は小窓の進み具合の行):
//   確かめ  space の名前・消す worktree (space の最初の端末の今のフォルダの git の top。同梱の mod と同じ引き方)・branch・止める端末の一覧・警告を出す。
//           警告は、未 commit の変更と、どこにも push していない submodule の commit (同梱の mod と同じ判定)・作業中か答え待ちのエージェント・ほかの
//           space の端末も止めること。linked worktree でない (main の checkout・git の外)・git worktree lock がある・端末の住所の machine が space と
//           合わないときは、わけを出して進めない。Enter (か「止めて消す」) で進む。開いてから未 commit の変更などが増えていたら、もう一度 Enter を
//           求める (同梱の mod と同じ)
//   1. 端末を止める  (a) space の全タブのペインの端末と、label herdr.space がその space の生きた端末 (ペインの無いもの)。(b) 同じ machine の生きた
//           端末のうち、フォルダが worktree の中のもの (ほかの space のペインは今のフォルダ、ペインの無い端末 (hc run の手伝いなど) は起こしたフォルダか
//           今のフォルダで見る。Windows では消すのを止めるので止める。一覧では分け、ほかの space のものは警告にも出す)。全部に hc kill を打ち、hc get で
//           全部が finished か消えた (not_found) になるまで待つ。STOP_LIMIT_MS を超えたら、space と worktree に触らずに止まり、残った端末を出す
//   2. space を閉じる  space.close (confirmed)。端末が全部終わると herdr-app が space を閉じていることがあるので、残っているときだけ打つ
//   3. worktree を消す  git worktree remove (--force は同梱の mod と同じく、未 commit の変更か submodule があるときだけ)。git の登録が残ったまま落ちる
//           うちは、REMOVE_WAITS の間を置いてやり直す (git の文は locale で訳されるので、やり直しても変わらないと分かる英語の文のときだけ止める)
//   4. 残ったフォルダを消す  git は消せなくても登録を消すので、フォルダだけが残ったら、中身が空のフォルダだけを消す (空のサブフォルダは下から消す)。
//           ファイルか symlink・junction が残っていれば消さずに知らせる。消せないうちは RMDIR_WAITS の間を置いてやり直す。git worktree prune は打たない
//           (登録はもう消えている。prune は repo の全部の worktree に効き、外付けの drive などで見えない別の worktree の登録まで消す)
//   済んだ・止まったは notify で出す。branch は消さない (同梱の Remove と同じ)
//
// 小窓は window (kind: "window") で開く。仕事 (hc・exec・sleep) はこの小窓の copy の task で流れ、copy を閉じると owner: null の task も一緒に
// 打ち切られる (gpui-kit の scheduler は task を copy の寿命 (application generation) に結び、閉じると全部を止める)。dialog は Esc を herdr-app が
// 先に取って閉じるが、window は Esc が mod に届き、外を押しても閉じないので、流している間は Esc を受けずに最後まで流す。それでも閉じたら (layout の
// 切り替え・mod.open の 2 回目・herdr-app を閉じる)、close() が「途中で止まった」を通知する。済めば小窓は自分で閉じる。
// 同じ space の仕事は 1 つだけ (JOBS)。開き直した小窓は流れている仕事の進み具合を出し (Esc で閉じても仕事は止まらない)、止まった仕事は小窓の
// Enter でやり直せる。machine の space (WSL・SSH の先) でも同じに動く: git とフォルダの片付けはその machine で (exec の on)、端末は machine/t7 の
// 住所で止める。
//
// 配る: dotfiles の runner の herdr-app-mods。win/README.md の「herdr-app のキー」。経緯は dotfiles-private の ADR 100
// (docs/adr/100_win_herdr_app_prefix_worktree_remove_*)。

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { run, props, closeOverlay, notify, theme, spaces, panes, terminals, focused, exec, hc, home, checking } from "herdr";

// 端末が終わるのを待つ上限 (hc kill を打ってから)。hc kill は hangup から始めて段を上げる (hc 0.1.21 の Linux の試しでは、hangup も TERM も無視する
// program も約 1 秒で SIGKILL まで上げて終わらせ、kill は終わるまで返らなかった)。Claude Code の後始末と machine の遅れのぶんを見込む
const STOP_LIMIT_MS = 60_000;
// 端末が終わったか・仕事の進み具合を見る間
const POLL_MS = 500;
// hc の 1 回の呼び出しを待つ上限 (hc() には時間切れの引数が無い。超えたら答えを待たずに次へ進む)
const HC_LIMIT_MS = 10_000;
// space を閉じてから git を打つまでの間 (herdr-app が space のペインの mod と、フォルダの見張りを放すのを待つ)
const SETTLE_MS = 1000;
// git worktree remove が git の登録を残したまま落ちたときに、やり直す前に待つ長さ。この数 + 1 回まで打つ
const REMOVE_WAITS = [1000, 2000, 3000, 5000];
// git の登録が消えて残ったフォルダを消すのを、やり直す前に待つ長さ。この数 + 1 回まで打つ
const RMDIR_WAITS = [1000, 2000, 3000];
// やり直しても変わらない git の失敗 (英語の文のときだけ分かる。訳された文はやり直す)
const LASTING = /locked working tree|contains modified or untracked files|is a main working tree|is not a working tree|validation failed/i;
const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
// 進み具合の行の順 (job.phase)
const PHASES = ["stop", "close", "remove", "cleanup", "done"];
const PHASE_NAMES = { stop: "端末を止める", close: "space を閉じる", remove: "worktree を消す", cleanup: "残ったフォルダを消す", done: "済んだ" };

// 流れている仕事 (space の id → 仕事)。module の値は、同じ版のこの mod の写しのあいだで共有される (同じ space を 2 回流さず、開き直した小窓が
// 進み具合を出す)。herdr-app を上げ直す・mod を読み直すと、仕事ごと消える (通知も出ない)
const JOBS = new Map();

// パスを比べる形: \ を / に、末尾の / を外す。ドライブ文字のある Windows のパスは大文字小文字を見ない (git は C:/Users/x、herdr-app は C:\Users\x と書く)
const norm = (p) => String(p ?? "").replace(/\\/g, "/").replace(/\/+$/, "");
const isWin = (p) => /^[A-Za-z]:(\/|$)/.test(norm(p));
const pathKey = (p) => (isWin(p) ? norm(p).toLowerCase() : norm(p));
// p が dir か、その中か。dir が根 (/・C:/) なら、根そのものだけ (何でも中に入れない)
const inside = (p, dir) => {
  if (!p || !dir) return false;
  const [a, d] = [pathKey(p), pathKey(dir)];
  if (d === "" || /^[a-z]:$/.test(d)) return a === d;
  return a === d || a.startsWith(`${d}/`);
};
// home を ~ に (出すだけ)
const tilde = (p, h) => {
  const n = norm(p);
  if (!h || !n) return n;
  return inside(n, h) ? `~${n.slice(norm(h).length)}` : n;
};
// 端末の住所の machine (machine/t7 → machine、t7 → null)
const machineOf = (addr) => {
  const s = String(addr ?? "");
  return s.includes("/") ? s.slice(0, s.indexOf("/")) : null;
};
// machine の中での id (machine/sp… → sp…)。label herdr.space はこの形 (herdr-app の AGENTS.md)
const localId = (id) => String(id).slice(String(id).indexOf("/") + 1);
// 出力の末尾の n 行を 1 行に (git は最後の行に fatal を書く)
const lines = (s, n = 2) =>
  String(s ?? "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean)
    .slice(-n)
    .join(" / ");
const errText = (e) => String(e?.message ?? e);
const json = (text) => {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
};
const stateOf = (stdout) => json(stdout)?.state ?? null;
// hc の失敗の文 (hc は {error: {kind, message, hint}} を stderr に書く)
const hcError = (r) => json(r.stderr)?.error?.message ?? (lines(r.stderr || r.stdout, 1) || `終了コード ${r.code}`);

async function git(cwd, args, on, timeout) {
  const r = await exec("git", args, { cwd, on, ...(timeout === undefined ? {} : { timeout }) });
  return { ok: r.code === 0, out: (r.stdout ?? "").trim(), err: (r.stderr || r.stdout || "").trim() };
}

// git worktree list --porcelain の塊 ({ path, branch, locked })。先頭が main の checkout
function parseWorktrees(out) {
  return out
    .split(/\r?\n\r?\n+/)
    .map((block) => {
      const ls = block.split(/\r?\n/);
      const path = ls.find((l) => l.startsWith("worktree "))?.slice(9);
      if (!path) return null;
      const branch = ls.find((l) => l.startsWith("branch "))?.slice(7).replace(/^refs\/heads\//, "") ?? null;
      return { path, branch, locked: ls.some((l) => l === "locked" || l.startsWith("locked ")) };
    })
    .filter(Boolean);
}

// checkout の submodule の repo (入れ子も、取り出していないものも): { name, dir, pinned }。同梱の mod worktree の modules と同じ判定
async function modules(gitDir, config, on, out = [], parent = "") {
  const keys = await git(gitDir, ["--git-dir", gitDir, "config", ...config, "-z", "--get-regexp", "^submodule\\..*\\.path$"], on);
  if (!keys.ok) return out; // .gitmodules が無いか、submodule が無い
  for (const record of keys.out.split("\0").filter(Boolean)) {
    const at = record.indexOf("\n");
    const name = record.slice("submodule.".length, at - ".path".length);
    const dir = `${gitDir}/modules/${name}`;
    if (!(await git(gitDir, ["--git-dir", dir, "rev-parse", "--git-dir"], on)).ok) continue; // 取り出したことが無い
    const pinned = await git(gitDir, ["--git-dir", gitDir, "rev-parse", `HEAD:${record.slice(at + 1)}`], on);
    out.push({ name: parent + name, dir, pinned: pinned.ok ? pinned.out : "" });
    if ((await git(gitDir, ["--git-dir", dir, "cat-file", "-e", "HEAD:.gitmodules"], on)).ok) await modules(dir, ["--blob", "HEAD:.gitmodules"], on, out, `${parent + name}/`);
  }
  return out;
}

// worktree の submodule と、そのうちどこにも無い commit (remote にも、親が指す commit にも無い) を持つものの名前。同梱の mod worktree と同じ判定
async function submodules(top, on) {
  const gitDir = await git(top, ["rev-parse", "--absolute-git-dir"], on);
  if (!gitDir.ok) throw new Error(gitDir.err || "git rev-parse が落ちた");
  const mods = await modules(gitDir.out, ["--file", `${top}/.gitmodules`], on);
  const unpushed = [];
  for (const m of mods) {
    const local = await git(gitDir.out, ["--git-dir", m.dir, "rev-list", "-n1", "--all", "--not", "--remotes", ...(m.pinned ? [m.pinned] : [])], on);
    if (!local.ok) throw new Error(local.err || `submodule ${m.name} を確かめられない`);
    if (local.out) unpushed.push(m.name);
  }
  return { mods, unpushed };
}

// 未 commit の変更があるか (fsmonitor の daemon を起こさない。同梱の mod と同じ)
async function dirtyOf(top, on) {
  const st = await git(top, ["--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain"], on);
  if (!st.ok) throw new Error(st.err || "git status が落ちた");
  return st.out !== "";
}

// 開いてから増えた危うさ (未 commit の変更・push していない submodule の commit) を見て info に足す。増えていれば true (もう一度 Enter を求める)
async function recheck(info, on) {
  const dirty = await dirtyOf(info.top, on);
  const subs = await submodules(info.top, on);
  const changed = (dirty && !info.dirty) || subs.unpushed.some((n) => !info.unpushed.includes(n));
  info.dirty ||= dirty;
  info.unpushed = [...new Set([...info.unpushed, ...subs.unpushed])];
  info.mods = Math.max(info.mods, subs.mods.length);
  return changed;
}

// machine の home (出すだけ。分からなければ null)。同梱の mod と同じく sh、だめなら PowerShell で引く
async function remoteHome(on) {
  for (const [cmd, args] of [
    ["sh", ["-c", 'printf %s "$HOME"']],
    ["powershell.exe", ["-NoProfile", "-Command", "[Console]::Write($HOME)"]],
  ]) {
    try {
      const r = await exec(cmd, args, { on });
      if (r.code === 0 && r.stdout.trim()) return norm(r.stdout.trim());
    } catch {}
  }
  return null;
}

// 開いたときの space の控え (space を閉じた後も、どの space のどのタブだったかを引けるように)
function snapshot(id) {
  const s = spaces().find((x) => x.id === id);
  if (!s) return null;
  const tabs = (s.tabs ?? []).map((c) => ({ id: c.id, index: c.index, name: c.name, named: c.named }));
  return { id: s.id, name: s.name, machine: s.machine ?? null, folder: s.folder ?? "", tabs };
}

// space の今の場所: 最初の端末の今のフォルダ (同梱の mod worktree の place と同じ)
function place(snap) {
  const tabs = new Set(snap.tabs.map((c) => c.id));
  return panes().find((p) => tabs.has(p.tab) && p.cwd)?.cwd || null;
}

// space の worktree を調べる。git の外なら top が null。linked は main の checkout でなく git worktree list にある checkout (submodule の checkout
// なども、main と top が違うだけでは linked にしない)
async function inspect(snap, on) {
  const userHome = on ? await remoteHome(on) : norm(home());
  const folder = place(snap) || snap.folder || userHome;
  const out = { folder, home: userHome, top: null, main: null, branch: null, linked: false, locked: false, dirty: false, mods: 0, unpushed: [] };
  if (!folder) return out;
  const top = await git(folder, ["rev-parse", "--show-toplevel"], on);
  const common = await git(folder, ["rev-parse", "--path-format=absolute", "--git-common-dir"], on);
  if (!top.ok || !common.ok) return out;
  out.top = top.out;
  out.main = common.out.endsWith("/.git") ? common.out.slice(0, -5) : common.out;
  const list = await git(out.main, ["worktree", "list", "--porcelain"], on);
  const me = (list.ok ? parseWorktrees(list.out) : []).slice(1).find((w) => pathKey(w.path) === pathKey(out.top));
  if (!me) return out;
  out.linked = true;
  out.branch = me.branch;
  out.locked = me.locked;
  out.dirty = await dirtyOf(out.top, on);
  const subs = await submodules(out.top, on);
  out.mods = subs.mods.length;
  out.unpushed = subs.unpushed;
  return out;
}

// 止める端末: space の端末 (why "space") と、フォルダが worktree の中にある同じ machine の生きた端末 (why "folder")。space の順 (タブ・ペイン) の後に
// ほかを並べる。mismatch: space のペインの端末なのに住所の machine が space と違う (この端末は止めない。小窓が進めない)。kids: 止める端末を親に持つ
// 生きた端末のうち、止める端末に入らないものの数 (hc は --outlive-parent で起こしたものでなければ親と一緒に止める)
function targets(snap, top) {
  const all = terminals();
  const byAddr = new Map(all.map((t) => [t.address, t]));
  const paneList = panes();
  const paneOf = new Map(paneList.filter((p) => p.terminal).map((p) => [p.terminal, p]));
  const tabOf = new Map(snap.tabs.map((c) => [c.id, c]));
  const spaceOfTab = new Map(spaces().flatMap((s) => (s.tabs ?? []).map((c) => [c.id, s])));
  const sameMachine = (addr) => machineOf(addr) === snap.machine;
  const out = new Map();
  const add = (addr, why) => {
    if (!addr || out.has(addr)) return;
    const t = byAddr.get(addr);
    if (t && t.state !== "live") return; // もう終わっている
    const p = paneOf.get(addr);
    out.set(addr, {
      address: addr,
      why,
      mismatch: why === "space" && !sameMachine(addr),
      program: p?.program?.name || t?.program?.name || "",
      title: p?.title || t?.title || t?.name || "",
      status: p?.status ?? t?.status ?? null,
      cwd: p?.cwd || t?.foreground?.cwd || t?.cwd || null,
      tab: p ? (tabOf.get(p.tab) ?? null) : null,
      space: p ? (spaceOfTab.get(p.tab)?.name ?? null) : null,
    });
  };
  for (const p of paneList) if (p.terminal && tabOf.has(p.tab)) add(p.terminal, "space");
  const sid = localId(snap.id);
  for (const t of all) if (t.state === "live" && sameMachine(t.address) && t.labels?.["herdr.space"] === sid) add(t.address, "space");
  if (top) {
    for (const p of paneList) if (p.terminal && sameMachine(p.terminal) && inside(p.cwd, top)) add(p.terminal, "folder");
    for (const t of all) {
      if (t.state !== "live" || !sameMachine(t.address) || paneOf.has(t.address)) continue;
      if (inside(t.cwd, top) || inside(t.foreground?.cwd, top)) add(t.address, "folder");
    }
  }
  const list = [...out.values()];
  const kids = all.filter((t) => t.state === "live" && out.has(t.parent) && !out.has(t.address)).length;
  return { list, kids };
}

// ---- 仕事 (この小窓の copy の task で流す) ----

// 待つ上限つきの hc。時間切れ・投げたら null
async function hcWithin(args, cx) {
  return Promise.race([hc(args).catch(() => null), cx.sleep(HC_LIMIT_MS).then(() => null)]);
}

// 端末が終わったか (finished か、もう無い)。分からなければ false
async function ended(addr, cx) {
  const r = await hcWithin(["get", addr, "--json"], cx);
  if (!r) return false;
  if (r.code === 3) return true; // not_found: もう消えた
  const state = r.code === 0 ? stateOf(r.stdout) : null;
  return state !== null && state !== "live";
}

// 1. 全部に hc kill を打ち、全部が終わるか上限まで待つ。kill は終わるまで返らないことがあるので、待たずに並べて打ち、hc get で見る
async function stopAll(job, cx) {
  job.started = Date.now();
  const stopped = (x) => {
    x.state = "stopped";
    x.error = "";
  };
  for (const x of job.terms) {
    x.killing = true;
    hc(["kill", x.address, "--json"]).then(
      (r) => {
        x.killing = false;
        if (r.code === 3 || (r.code === 0 && ![null, "live"].includes(stateOf(r.stdout)))) stopped(x);
        else if (r.code !== 0) x.error = hcError(r);
      },
      (e) => {
        x.killing = false;
        x.error = errText(e);
      },
    );
  }
  for (;;) {
    if (job.terms.every((x) => x.state === "stopped")) return;
    if (Date.now() - job.started >= STOP_LIMIT_MS) return;
    await cx.sleep(POLL_MS);
    const state = new Map(terminals().map((t) => [t.address, t.state]));
    await Promise.all(
      job.terms
        .filter((x) => x.state !== "stopped")
        // kill が返る前で、herdr-app の一覧でもまだ生きているなら hc get は打たない
        .filter((x) => !(x.killing && state.get(x.address) === "live"))
        .map(async (x) => {
          if (await ended(x.address, cx)) stopped(x);
        }),
    );
  }
}

// 2. space を閉じる (端末が全部終わって、herdr-app がもう閉じていれば打たない)
function closeSpace(job) {
  const id = job.snap.id;
  if (!spaces().some((s) => s.id === id)) {
    job.closed = "gone";
    return;
  }
  try {
    run("space.close", { id, confirmed: true });
    job.closed = "closed";
  } catch (e) {
    job.closed = `閉じられない (${errText(e)})`;
  }
}

// git の登録に worktree が残っているか (分からなければ null)
async function registered(info, on) {
  let r;
  try {
    r = await git(info.main, ["worktree", "list", "--porcelain"], on);
  } catch {
    return null;
  }
  if (!r.ok) return null;
  return parseWorktrees(r.out).some((w) => pathKey(w.path) === pathKey(info.top));
}

// 3. git worktree remove。git の登録が残ったまま落ちるうちはやり直す (やり直しても変わらないと分かる失敗を除く)。登録が消えたら gone (4. へ)
async function removeWorktree(job, cx) {
  const { info, on, force } = job;
  for (let n = 0; ; n++) {
    job.attempt = n + 1;
    const r = await git(info.main, ["worktree", "remove", ...(force ? ["--force"] : []), info.top], on, 600_000);
    if (r.ok) return { ok: true };
    const err = lines(r.err) || "git worktree remove が落ちた";
    const reg = await registered(info, on);
    if (reg === false) return { ok: false, gone: true, err };
    if (LASTING.test(r.err) || n >= REMOVE_WAITS.length) return { ok: false, err };
    await cx.sleep(REMOVE_WAITS[n]);
  }
}

// フォルダを消す。消すのは中身が空のフォルダだけ (空のサブフォルダは下から消す)。ファイルか symlink・junction (reparse point) が 1 つでもあれば
// 消さない (リンクの先に触らない。Windows PowerShell 5.1 の -Recurse は junction の先へも入るが、リンク自身が先に出るのでそこで止まる)。返すのは
// { result: "gone" (もう無い) | "removed" | "notempty" | "error", err }。Windows のパスは PowerShell (パスは code point の並びで渡し、引用の外に
// 置く)、ほかは sh で、そのパスの machine で打つ
async function removeDir(path, on) {
  let r;
  if (isWin(path)) {
    const codes = Array.from(norm(path)).map((c) => c.codePointAt(0)).join(",");
    const ps = [
      `$p = -join (@(${codes}) | ForEach-Object { [char]::ConvertFromUtf32($_) })`,
      "if (-not (Test-Path -LiteralPath $p)) { 'gone'; exit 0 }",
      "if (Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction Stop | Where-Object { -not $_.PSIsContainer -or ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } | Select-Object -First 1) { 'notempty'; exit 0 }",
      "try { Get-ChildItem -LiteralPath $p -Recurse -Force -Directory -ErrorAction Stop | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { [System.IO.Directory]::Delete($_.FullName) }; [System.IO.Directory]::Delete($p); 'removed' } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }",
    ].join("; ");
    r = await exec("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps], { on, timeout: 30_000 });
  } else {
    const sh = [
      'if [ ! -e "$1" ]; then echo gone; exit 0; fi',
      'if [ -n "$(find "$1" ! -type d 2>/dev/null | head -n 1)" ]; then echo notempty; exit 0; fi',
      'find "$1" -depth -type d -exec rmdir -- {} + && echo removed',
    ].join("\n");
    r = await exec("sh", ["-c", sh, "sh", path], { on, timeout: 30_000 });
  }
  const last = (r.stdout ?? "").trim().split(/\r?\n/).pop();
  return { result: ["gone", "removed", "notempty"].includes(last) ? last : "error", err: lines(r.stderr || r.stdout) };
}

// 4. git の登録が消えて残ったフォルダを片付ける (中身が空のフォルダだけを消す)
async function cleanup(job, cx) {
  const { info, on } = job;
  for (let n = 0; ; n++) {
    job.attempt = n + 1;
    let d;
    try {
      d = await removeDir(info.top, on);
    } catch (e) {
      d = { result: "error", err: errText(e) };
    }
    if (d.result === "gone" || d.result === "removed") return { ok: true };
    if (d.result === "notempty") return { ok: false, err: "git の登録は消えたが、フォルダにファイルかリンクが残った。使っているプログラムを閉じてから手で消す" };
    if (n >= RMDIR_WAITS.length) return { ok: false, err: `git の登録は消えたが、残ったフォルダを消せない: ${d.err || "わけが出ていない"}` };
    await cx.sleep(RMDIR_WAITS[n]);
  }
}

function finish(job, ok, message) {
  if (job.done) return;
  job.done = true;
  job.ok = ok;
  job.message = message;
  if (ok) job.phase = "done";
  if (JOBS.get(job.key) === job) JOBS.delete(job.key);
  try {
    notify({ title: ok ? "worktree を消した" : "worktree を消せなかった", body: message, level: ok ? "success" : "error" });
  } catch {}
}

async function work(job, cx) {
  try {
    await stopAll(job, cx);
    const left = job.terms.filter((x) => x.state !== "stopped");
    if (left.length) {
      const names = left.map((x) => x.address).join("・");
      return finish(job, false, `${STOP_LIMIT_MS / 1000} 秒待っても止まらない端末がある (${names})。space と worktree には触っていない`);
    }
    job.phase = "close";
    closeSpace(job);
    await cx.sleep(SETTLE_MS);
    job.phase = "remove";
    let r = await removeWorktree(job, cx);
    if (!r.ok && r.gone) {
      job.phase = "cleanup";
      job.cleanup = true;
      r = await cleanup(job, cx);
    }
    const at = tilde(job.info.top, job.info.home);
    if (!r.ok) return finish(job, false, `${at} を消せない: ${r.err}`);
    finish(job, true, `${at} を消した${job.info.branch ? ` (branch ${job.info.branch} は残した)` : ""}`);
  } catch (e) {
    finish(job, false, `止まった: ${errText(e)}`);
  }
}

// ---- 小窓 ----

export default class WorktreeRemove extends View {
  init(_props, cx) {
    this.overlay = props()?.overlay ?? null;
    const id = props()?.space ?? focused()?.space ?? null;
    this.snap = id ? snapshot(id) : null;
    this.on = this.snap?.machine ?? null;
    this.info = undefined; // 調べている間は undefined、調べ終えたら inspect の結果、調べられなければ null
    this.error = "";
    this.notice = ""; // Enter をもう一度求めるわけなど
    this.busy = false; // Enter の後に確かめ直している間
    this.closed = false;
    this.ticker = null;
    this.drawn = false;
    this.job = this.snap ? (JOBS.get(this.snap.id) ?? null) : null;
    this.handle = cx.focus_handle();
    this.handle.focus();
    // window は開いてもキーボードを取らないので、自分で取る。開いた直後に focus が端末へ戻ることがあるので、少し後にもう一度取る
    cx.timer.after(50, () => {
      if (!this.closed) this.handle.focus();
    });
    if (this.job) this.tick(cx);
    if (!this.snap || this.job || checking()) return;
    cx.spawn(async (cx) => {
      try {
        this.info = await inspect(this.snap, this.on);
      } catch (e) {
        this.info = null;
        this.error = `調べられない: ${errText(e)}`;
      }
      if (this.closed) return;
      cx.notify();
      this.handle.focus();
    });
  }

  dismiss() {
    if (this.closed) return;
    this.closed = true;
    if (this.overlay) closeOverlay(this.overlay);
  }

  // 小窓が閉じたとき (自分で閉じた・layout の切り替え・mod.open の 2 回目・herdr-app を閉じる)。この小窓が流している仕事は、copy と一緒に
  // 打ち切られるので、止まったことを通知する (ほかの小窓が出している仕事は止まらない)
  async close() {
    this.closed = true;
    const j = this.job;
    if (j && !j.done && j.runner === this) {
      finish(j, false, `小窓が閉じたので「${PHASE_NAMES[j.phase] ?? j.phase}」の途中で止まった。残っていれば Shift+D でやり直す`);
    }
  }

  // 流している仕事か (この小窓が起こし、まだ済んでいない)
  running() {
    return Boolean(this.job && !this.job.done && this.job.runner === this);
  }

  list() {
    return this.snap && this.info?.top ? targets(this.snap, this.info.top) : { list: [], kids: 0 };
  }

  // 進めない理由 (無ければ "")
  blocker() {
    if (!this.snap) return "space が見つからない (閉じたか、開く前に focus のあった space が無い)";
    const i = this.info;
    if (i === undefined) return "調べています…";
    if (i === null) return this.error || "調べられない";
    if (!i.top) return `${tilde(i.folder, i.home) || "このフォルダ"} は git の repo の中でない`;
    if (!i.linked) return `${tilde(i.top, i.home)} は worktree でない (repo の main の checkout)`;
    if (i.locked) return "この worktree には git worktree lock がかかっている (git が消すのを断る)。git worktree unlock してから";
    const odd = this.list().list.filter((x) => x.mismatch);
    if (odd.length) return `端末の住所の machine が space と合わない (${odd.map((x) => x.address).join("・")})。止めずに閉じる`;
    return "";
  }

  // Enter・「止めて消す」・「やり直す」
  go(cx) {
    if (this.closed || this.busy || !this.snap) return;
    const j = this.job;
    if (j && !j.done) return;
    if (j && j.ok) return this.dismiss();
    // ほかの小窓がこの space の仕事を始めていたら、その進み具合を出す (済んだ仕事は JOBS に残らない)
    if (this.attach(cx)) return;
    if (!j && this.blocker()) return;
    const i = j ? j.info : this.info;
    this.busy = true;
    this.notice = "";
    cx.notify();
    cx.spawn(async (cx) => {
      try {
        // 開いてから増えた危うさがあれば、もう一度 Enter を求める (同梱の mod と同じ)。やり直しで worktree がもう git の外 (登録が消えて残った
        // フォルダの片付けだけが残った) なら、確かめずに進める
        let changed = false;
        try {
          changed = await recheck(i, this.on);
        } catch (e) {
          if (!j) throw e;
        }
        if (changed) this.notice = "開いてから変わった (上の警告)。もう一度 Enter で止めて消す";
        else if (!this.closed && !this.attach(cx)) this.launch(cx, i);
      } catch (e) {
        this.notice = `確かめ直せない: ${errText(e)}`;
      } finally {
        this.busy = false;
        if (!this.closed) cx.notify();
      }
    });
  }

  // この space の仕事がほかの小窓で流れていれば、それを出す (2 つ目を起こさない)。出したら true
  attach(cx) {
    const running = JOBS.get(this.snap.id);
    if (!running || running === this.job) return false;
    this.job = running;
    this.drawn = false;
    this.tick(cx);
    cx.notify();
    return true;
  }

  // 仕事を起こす (この小窓の copy の task。閉じると打ち切られるので、流している間は Esc で閉じない)
  launch(cx, info) {
    this.snap = snapshot(this.snap.id) ?? this.snap; // 開いてから足されたタブも拾う
    const job = {
      key: this.snap.id,
      runner: this,
      snap: this.snap,
      on: this.on,
      info,
      force: info.dirty || info.mods > 0,
      terms: targets(this.snap, info.top).list.map((x) => ({ ...x, state: "stopping", killing: false, error: "" })),
      phase: "stop",
      started: Date.now(),
      attempt: 0,
      closed: "",
      cleanup: false,
      done: false,
      ok: false,
      message: "",
    };
    JOBS.set(job.key, job);
    this.job = job;
    this.drawn = false;
    cx.spawn(async (cx) => work(job, cx));
    this.tick(cx);
    cx.notify();
  }

  // 仕事の進み具合を描き直す (ほかの小窓が流している仕事も出すので、仕事の側からは描き直さない)。済んだら小窓を閉じる (結果は notify で出ている)
  tick(cx) {
    if (this.ticker) return;
    this.ticker = cx.timer.every(POLL_MS, (cx) => {
      const j = this.job;
      if (!j || this.closed) return;
      if (j.done && j.ok) return this.dismiss();
      if (j.done && this.drawn) return; // 止まった仕事は 1 回描けば足りる
      this.drawn = j.done;
      cx.notify();
    });
  }

  key(e, cx) {
    const k = e.key ?? "";
    if (k !== "enter" && k !== "escape") return;
    cx.stop_propagation();
    if (e.is_held) return;
    if (k === "escape") {
      // 流している間は閉じない (閉じると仕事が打ち切られる)
      if (this.running()) {
        this.notice = "止めている間は閉じない。済めば自分で閉じる";
        return cx.notify();
      }
      return this.dismiss();
    }
    this.go(cx);
  }

  render(cx) {
    const t = theme();
    const j = this.job;
    const i = j ? j.info : this.info;
    const s = this.snap;
    const name = s ? (spaces().find((x) => x.id === s.id)?.name ?? s.name) : "";
    const loading = !j && Boolean(s) && this.info === undefined;
    const block = j || loading ? "" : this.blocker();
    // 進めないときは一覧を出さない (わけだけを出す)
    const found = j ? { list: j.terms, kids: 0 } : block || loading ? { list: [], kids: 0 } : this.list();
    const list = found.list;
    const ours = list.filter((x) => x.why === "space");
    const others = list.filter((x) => x.why === "folder");
    const ink = (c, fallback) => c ?? fallback ?? t.foreground;
    const stop = (_e, cx) => cx.stop_propagation(); // window は押して引くと動くので、ボタンの押下は止める

    const field = (label, value, color) =>
      h_flex()
        .gap(8)
        .items_center()
        .min_w(0)
        .child(div().w(64).flex_none().text_size(12).text_color(t.dim).child(label))
        .child(div().flex_1().min_w(0).truncate().text_color(color ?? t.foreground).child(value));
    const heading = (text) => div().pt(2).text_size(12).text_color(t.dim).child(text);
    const mark = (x) => {
      if (!j) return div().size(8).mx(1).rounded(4).flex_none().bg(x.status === "working" ? ink(t.working) : x.status === "blocked" ? ink(t.blocked) : t.dim);
      if (x.state === "stopped") return div().w(10).flex_none().text_color(ink(t.done, t.accent)).child("✓");
      if (j.done) return div().w(10).flex_none().text_color(ink(t.blocked)).child("✗");
      return div().w(10).flex_none().text_color(ink(t.working, t.accent)).frames(SPINNER, 90);
    };
    const where = (x) =>
      x.why === "space" ? (x.tab ? `タブ ${x.tab.index}` : "ペインなし") : x.space ? `space ${x.space}` : "ペインなし";
    const termRow = (x, k) =>
      h_flex()
        .id(`pwr-t-${k}`)
        .h(22)
        .gap(8)
        .items_center()
        .min_w(0)
        .tooltip(x.cwd ? tilde(x.cwd, i?.home) : x.address)
        .child(mark(x))
        .child(div().w(84).flex_none().truncate().text_color(t.foreground).child(x.address))
        .child(
          div()
            .flex_1()
            .min_w(0)
            .truncate()
            .text_color(x.error ? ink(t.blocked) : t.muted)
            .child([x.program, x.title].filter(Boolean).join(" · ") + (x.error ? ` (${x.error})` : "") || "端末"),
        )
        .child(div().flex_none().text_size(11.5).text_color(t.dim).child(where(x)));

    // 進み具合の行 (仕事を始めた後)
    const stepRow = ([key, label]) => {
      const at = PHASES.indexOf(j.phase);
      const k = PHASES.indexOf(key);
      const warned = key === "close" && j.closed && j.closed !== "closed" && j.closed !== "gone";
      const state = j.ok || k < at ? (warned ? "warned" : "done") : k === at ? (j.done ? "failed" : "now") : "todo";
      const icon =
        state === "done"
          ? div().w(12).flex_none().text_color(ink(t.done, t.accent)).child("✓")
          : state === "warned"
            ? div().w(12).flex_none().text_color(ink(t.working, t.accent)).child("!")
            : state === "failed"
              ? div().w(12).flex_none().text_color(ink(t.blocked)).child("✗")
              : state === "now"
                ? div().w(12).flex_none().text_color(ink(t.working, t.accent)).frames(SPINNER, 90)
                : div().w(12).flex_none().text_color(t.dim).child("·");
      return h_flex()
        .gap(8)
        .items_center()
        .child(icon)
        .child(div().flex_1().min_w(0).truncate().text_color(state === "todo" ? t.dim : t.foreground).child(label));
    };
    const steps = () => {
      const stopped = j.terms.filter((x) => x.state === "stopped").length;
      const sec = Math.min(STOP_LIMIT_MS, Date.now() - j.started) / 1000;
      const waiting = j.phase === "stop" && !j.done ? ` · ${Math.floor(sec)} 秒 (上限 ${STOP_LIMIT_MS / 1000} 秒)` : "";
      const again = (phase) => (j.phase === phase && j.attempt > 1 ? ` (${j.attempt} 回目)` : "");
      const closed = j.closed === "gone" ? " (端末が終わって herdr-app が閉じた)" : j.closed && j.closed !== "closed" ? ` (${j.closed})` : "";
      return [
        ["stop", `${PHASE_NAMES.stop} (${stopped}/${j.terms.length})${waiting}`],
        ["close", `${PHASE_NAMES.close}${closed}`],
        ["remove", `${PHASE_NAMES.remove}${again("remove")}`],
        ...(j.cleanup ? [["cleanup", `git の登録が消えて${PHASE_NAMES.cleanup}${again("cleanup")}`]] : []),
      ];
    };

    const warns = [];
    if (i?.dirty) warns.push("未 commit の変更がある。消すと無くなる");
    if (i?.unpushed?.length) warns.push(`submodule ${i.unpushed.join(", ")} に、どこにも push していない commit がある。消すと無くなる`);
    if (!j) {
      const busyAgents = list.filter((x) => x.status === "working" || x.status === "blocked").length;
      if (busyAgents) warns.push(`作業中か答え待ちのエージェントが ${busyAgents} つある。止めると、その作業も止まる`);
      const elsewhere = others.filter((x) => x.space);
      if (elsewhere.length) {
        const names = [...new Set(elsewhere.map((x) => x.space))].join("・");
        warns.push(`ほかの space (${names}) の端末も ${elsewhere.length} つ止める (フォルダがこの worktree の中にある)`);
      }
      if (i?.top && s?.folder && !inside(s.folder, i.top)) {
        warns.push(`space を作ったフォルダ (${tilde(s.folder, i.home)}) はこの worktree の外。最初の端末の今のフォルダの worktree を消す`);
      }
    }

    const button = (id, label, primary, onClick) =>
      h_flex()
        .id(id)
        .h(30)
        .px(12)
        .items_center()
        .rounded(7)
        .border_1()
        .border_color(primary ? t.solid : t.input)
        .bg(primary ? t.solid : t.raised)
        .text_color(primary ? t.solid_foreground : t.foreground)
        .cursor_pointer()
        .hover((st) => st.opacity(0.88))
        .on_mouse_down("left", stop)
        .on_click((_e, cx) => onClick(cx))
        .child(label);
    const spin = (text) =>
      h_flex().gap(6).items_center().text_size(11.5).text_color(t.dim).child(div().frames(SPINNER, 90)).child(text);
    const footer = () => {
      if (j && !j.done) return spin(this.running() ? "止めている間は閉じない。済めば自分で閉じて知らせる" : "別の小窓が流している。esc で閉じても止まらない");
      if (j && !j.ok) {
        return h_flex()
          .gap(8)
          .items_center()
          .child(div().flex_1().text_size(11.5).text_color(t.dim).child("↵ やり直す · esc 閉じる"))
          .child(button("pwr-close", "閉じる", false, () => this.dismiss()))
          .child(button("pwr-retry", "やり直す", true, (cx) => this.go(cx)));
      }
      if (this.busy) return spin("確かめ直しています…");
      if (block || loading) return div().text_size(11.5).text_color(t.dim).child("esc 閉じる");
      return h_flex()
        .gap(8)
        .items_center()
        .child(div().flex_1().text_size(11.5).text_color(t.dim).child("↵ 止めて消す · esc 取り消す"))
        .child(button("pwr-cancel", "取り消す", false, () => this.dismiss()))
        .child(button("pwr-go", "止めて消す", true, (cx) => this.go(cx)));
    };

    const body = v_flex()
      .id("pwr-list")
      .flex_1()
      .min_h(0)
      .gap(2)
      .overflow_y_scrollbar()
      .when(Boolean(j), (el) => el.children(steps().map(stepRow)).child(heading(`止める端末 (${list.length})`)))
      .when(!j && !loading && !block, (el) => el.child(heading(ours.length ? `止める端末 (${ours.length})` : "止める space の端末は無い")))
      .children((j ? list : ours).map((x, k) => termRow(x, k)))
      .when(!j && others.length > 0, (el) =>
        el.child(heading(`worktree の中にいるほかの端末も止める (${others.length})`)).children(others.map((x, k) => termRow(x, ours.length + k))),
      )
      .when(!j && found.kids > 0, (el) =>
        el.child(div().pt(2).text_size(11.5).text_color(t.dim).child(`ほかに、止める端末が hc run で起こした端末が ${found.kids} つある (--outlive-parent でなければ一緒に終わる)`)),
      );

    return v_flex()
      .id("pjp-worktree-remove")
      .track_focus(this.handle)
      .on_key_down((e, cx) => this.key(e, cx))
      .size_full()
      .min_h(0)
      .p(18)
      .gap(10)
      .rounded(8)
      .bg(t.popover)
      .text_size(13)
      .child(
        h_flex()
          .items_center()
          .child(div().flex_1().text_size(15).font_semibold().text_color(t.foreground).child("space の端末を閉じて worktree を消す"))
          .child(div().text_size(11).text_color(t.dim).child(this.running() ? "" : "Esc")),
      )
      .child(
        v_flex()
          .gap(3)
          .child(field("space", s ? `${name}${this.on ? ` (machine ${this.on})` : ""}` : "-"))
          .child(field("worktree", i?.top ? tilde(i.top, i.home) : i === undefined && s ? "…" : "-"))
          .child(field("branch", i?.linked ? `${i.branch ?? "(detached HEAD)"} (消さずに残す)` : "-", t.muted)),
      )
      .when(loading, (el) => el.child(spin("調べています…")))
      .when(Boolean(block), (el) => el.child(div().text_color(ink(t.blocked)).child(block)))
      .child(body)
      .children(warns.map((w) => div().text_size(12).text_color(ink(t.blocked)).child(w)))
      .when(Boolean(j?.done && !j.ok), (el) => el.child(div().text_color(ink(t.blocked)).child(j.message)))
      .when(Boolean(this.notice), (el) => el.child(div().text_color(ink(t.working, t.accent)).child(this.notice)))
      .child(footer());
  }
}
