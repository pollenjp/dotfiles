//! `pjp hub hello` (spec §7.3 の会話の始め・§8.1。T3 Code の形は `2026-11-22-t3-code-hub-design.md` の §4.3)。ハブの会話の
//! 始めに、次を 1 行ずつ出す。
//!
//! - ハブ: cwd がハブ (remote が無く `pjp.devtracker.repo` を持つ repo) の worktree か
//! - 雛形: ハブの main の checkout と、この worktree の決まりのファイルが今の雛形どおりか
//!
//! 続きは会話の形 ([`Form`]) で変わる。herdr-app と hc の中 (env に `HC_TERMINAL_ID` がある。T3 Code の env も無いときも
//! この形) では:
//!
//! - この端末: hc の端末か・OSC 7501 で状態を報告しているか (spec §13 の #1) と、付いている label (`pjp.*`)
//! - 見回り役: `pjp-hubd` (label `pjp.role=hubd`) が動いているか。動いていなければ立てる (`pjp-hubd` の bin がこの crate に
//!   あるときだけ。spec の W2-3 で入る)
//! - hc の machine: 子を立てるマシンにつながるか。手元の WSL の machine (`--via` のコマンドが wsl.exe。名前は見ない) には印を
//!   添え、Windows のハブに WSL の machine が無ければ足し方を出す
//!
//! T3 Code の中 (`HC_TERMINAL_ID` が無く `T3CODE_THREAD_ID` がある) では:
//!
//! - T3 のスレッド: スレッドの id (「この端末」と label の行の代わり)
//! - T3 のリンク: 子のスレッドを立てる先 (T3 につないだ別のマシン。spec §4.5) を、T3 の CLI (env `T3CODE_CLI_PATH`) の
//!   `environment list --json` で 1 つ 1 行に出す。届くか・期限が近くないか (T3 の画面と同じく 5 日)・access が full-access か
//! - T3 の設定: T3 だけの設定のファイル (`~/.claude/t3/` の `settings.json`・`CLAUDE.t3.md`。dotfiles の Windows の runner の
//!   手順 claude-t3 が置く) があるか・T3 の Launch arguments がその 2 つを渡しているか (T3 Code を dotfiles で入れた PC では
//!   手順 t3-code-settings が書き、入れていない PC ではユーザーが T3 の画面で書く)
//! - 見回り役: 立てない (T3 のスレッドには Notion のコメントを届けない)
//! - hc の machine: herdr-app の形と同じ (T3 のハブも、長い子の見張りと、Windows に無い `pjp ticket` の command を手元の
//!   WSL で流すのに hc を使う)
//!
//! 行の頭は ok (問題ない)・NG (直すもの)・!! (気にかけるもの)・-- (ここでは見ない)。NG が 1 つでもあれば終了コード 1。

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fmt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use pjp_core::process::{Cmd, Output};
use pjp_core::time::{self, Timestamp};
use pjp_core::{Result, paths};
use serde_json::Value;

use crate::git::Git;
use crate::init::{self, ROW_KEY, SKILL, SKILL_KEY};
use crate::pathx;
use crate::templates::{self, Context};

/// hc に聞くのを待つ長さ (machine につながらないと待たされる)。
const HC_TIMEOUT: Duration = Duration::from_secs(15);
/// 見回り役の名前と label。
pub const HUBD_NAME: &str = "pjp-hubd";
pub const HUBD_LABEL: &str = "pjp.role=hubd";
/// 見回り役の bin。この crate の Cargo.toml の `[[bin]]` にあるときだけ立てる。
const HUBD_BIN: &str = "pjp-hubd";
/// 旧 herdr のハブの worktree の branch の頭 (`herdr worktree create` が付ける `worktree/<名前>`)。
const OLD_HUB_BRANCH: &str = "worktree/";
/// T3 の CLI のパスの env (T3 が会話に渡す。Windows は `~/.t3/bin/t3.cmd`)。
const T3_CLI_ENV: &str = "T3CODE_CLI_PATH";
/// T3 の CLI に聞くのを待つ長さ。
const T3_TIMEOUT: Duration = Duration::from_secs(15);
/// リンクの期限までの日数 (日に切り上げる) がこれ以下なら知らせる。T3 v0.1.11 の画面が「Expires in N days. Link it again to
/// renew.」を出す日数と同じ。
const LINK_WARN_DAYS: i64 = 5;
/// 子のスレッドを立てるリンクの access。T3 はリンク先での操作に、リンクの access を上限としてかける (`full-access` だけが
/// `source-control:write` を持つ)。子のスレッドの手順 (spec §4.5) は full-access のリンクで確かめた。
const LINK_ACCESS: &str = "full-access";
/// リンクをつなぎ直す所。
const RELINK: &str = "T3 の Settings → Connections の Linked environments で、full-access の新しい pairing code でつなぎ直す。pairing code は会話に貼らない";
/// T3 だけの設定のファイル (Launch arguments の flag, `~/.claude/t3/` の中の名前)。dotfiles の Windows の runner の手順
/// claude-t3 が置き、T3 の Launch arguments で渡す。Launch arguments は、T3 Code を dotfiles で入れた PC では手順
/// t3-code-settings が書き、入れていない PC ではユーザーが T3 の Settings → Providers → Claude → Launch arguments に書く
/// (T3 Code の spec §4.1)。
const T3_FILES: [(&str, &str); 2] = [
    ("--settings", "settings.json"),
    ("--append-system-prompt-file", "CLAUDE.t3.md"),
];
/// T3 の Launch arguments で、次が `--` で始まっても値に取る flag (T3 v0.1.11 の `claudeLaunchArgParseOptions.valueFlags`)。
const LAUNCH_VALUE_FLAGS: [&str; 1] = ["append-system-prompt"];

/// 会話の形 (T3 Code の spec §4.3)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Form {
    /// herdr-app と hc の端末の中 (`HC_TERMINAL_ID` がある)。どちらの env も無いときもこの形にし、「この端末」を NG にする。
    Hc,
    /// T3 Code の中 (`HC_TERMINAL_ID` が無く `T3CODE_THREAD_ID` がある)。
    T3 {
        /// スレッドの id (`T3CODE_THREAD_ID`)。
        thread: String,
    },
}

impl Form {
    /// env から決める。両方あれば hc の形 (hc の端末の中の会話)。
    pub fn detect(r: &dyn Runner) -> Form {
        if r.env("HC_TERMINAL_ID").is_some() {
            return Form::Hc;
        }
        match r.env("T3CODE_THREAD_ID") {
            Some(thread) => Form::T3 { thread },
            None => Form::Hc,
        }
    }
}

/// 行の印。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mark {
    Ok,
    Ng,
    Warn,
    Skip,
}

/// 点検の 1 行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Line {
    pub mark: Mark,
    pub label: String,
    pub detail: String,
}

impl Line {
    pub fn new(mark: Mark, label: impl Into<String>, detail: impl Into<String>) -> Line {
        Line {
            mark,
            label: label.into(),
            detail: detail.into(),
        }
    }
}

impl fmt::Display for Line {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mark = match self.mark {
            Mark::Ok => "ok",
            Mark::Ng => "NG",
            Mark::Warn => "!!",
            Mark::Skip => "--",
        };
        write!(f, "{mark}  {}: {}", self.label, self.detail)
    }
}

/// hc とのやりとり (テストは偽物に差し替える)。
pub trait Runner {
    fn which(&self, name: &str) -> Option<PathBuf>;
    fn run(&self, cmd: &Cmd) -> Result<Output>;
    fn env(&self, key: &str) -> Option<String>;
    /// このマシンが Windows か (Windows のハブだけが、手元の WSL を hc の machine に足す)。
    fn windows(&self) -> bool;
}

/// 本物の Runner。
pub struct SystemRunner;

impl Runner for SystemRunner {
    fn which(&self, name: &str) -> Option<PathBuf> {
        pjp_core::process::find_in_path(name)
    }

    fn run(&self, cmd: &Cmd) -> Result<Output> {
        cmd.output()
    }

    fn env(&self, key: &str) -> Option<String> {
        std::env::var(key).ok().filter(|v| !v.is_empty())
    }

    fn windows(&self) -> bool {
        cfg!(windows)
    }
}

/// cwd のハブ。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hub {
    /// ハブの main の checkout (共通の `.git` の親)。
    pub root: PathBuf,
    /// 今の work tree の頭。
    pub top: PathBuf,
    /// linked worktree か (main の checkout でない)。
    pub worktree: bool,
    /// pjp-hc-hub のハブか (`pjp.hub.skill`)。旧 herdr のハブ (hub-init.sh が作った) なら false。
    pub hc: bool,
}

/// 点検して出す。終了コード (NG があれば 1)。
pub fn run() -> u8 {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let git = Git::find();
    let form = Form::detect(&SystemRunner);
    let mut lines = Vec::new();
    let (hub_lines, hub) = hub_lines(git.as_ref(), &cwd, &form);
    lines.extend(hub_lines);
    if let (Some(git), Some(hub)) = (&git, &hub) {
        lines.extend(template_lines(git, hub));
    }
    match &form {
        Form::Hc => lines.extend(hc_lines(&SystemRunner, hub.as_ref(), hubd_bin_here())),
        Form::T3 { thread } => {
            let home = paths::home_dir().unwrap_or_else(|_| PathBuf::from("/"));
            // リンクの期限と比べる今 (env PJP_NOW があればその時刻。試験用)
            let now =
                time::now().unwrap_or_else(|_| Timestamp::from_system_time(SystemTime::now()));
            lines.extend(t3_lines(&SystemRunner, thread, &home, &cwd, now));
        }
    }
    println!("pjp hub hello (ハブの会話の始めの点検)");
    for line in &lines {
        println!("  {line}");
    }
    let ng = lines.iter().filter(|l| l.mark == Mark::Ng).count();
    println!();
    if ng == 0 {
        println!("NG はありません。");
        0
    } else {
        println!("NG が {ng} 件あります。");
        1
    }
}

fn short(p: &Path) -> String {
    paths::contract_home_here(p)
}

/// ハブの中か。ハブなら、その様子も返す。`form` は、main の checkout で会話の worktree の作り方を言うのに使う。
pub fn hub_lines(git: Option<&Git>, cwd: &Path, form: &Form) -> (Vec<Line>, Option<Hub>) {
    const LABEL: &str = "ハブ";
    let Some(git) = git else {
        return (vec![Line::new(Mark::Ng, "git", "PATH にありません")], None);
    };
    let outside = |why: String| (vec![Line::new(Mark::Ng, LABEL, why)], None);
    let Some(top) = git.toplevel(cwd) else {
        return outside(format!(
            "ハブの外 ({} は git の work tree でない)。ハブの会話は ~/h の worktree で立てる",
            short(cwd)
        ));
    };
    if !git.remotes(cwd).is_empty() {
        return outside(format!(
            "ハブの外 ({} は remote を持つ repo。ハブの会話は ~/h の worktree で立てる)",
            short(&top)
        ));
    }
    let Some(row) = git.config(cwd, ROW_KEY) else {
        return outside(format!(
            "ハブの外 ({} に git config {ROW_KEY} が無い。ハブは pjp hub init が作る)",
            short(&top)
        ));
    };
    let common = git.common_dir(cwd);
    let worktree = match (git.git_dir(cwd), &common) {
        (Some(g), Some(c)) => !paths::same_path_here(&g, c),
        _ => false,
    };
    let root = common
        .as_deref()
        .and_then(Path::parent)
        .map_or_else(|| top.clone(), Path::to_path_buf);
    let hc = git.config(cwd, SKILL_KEY).as_deref() == Some(SKILL);
    let branch = git
        .text(cwd, &["branch", "--show-current"])
        .filter(|b| !b.is_empty());
    let line = if !hc {
        Line::new(
            Mark::Warn,
            LABEL,
            format!(
                "{} は旧 herdr のハブ (pjp-herdr-hub。git config {SKILL_KEY} が無い)。決まりのファイルと見回りは pjp-herdr-hub のもの",
                short(&root)
            ),
        )
    } else if worktree {
        Line::new(
            Mark::Ok,
            LABEL,
            format!(
                "{} (ハブ {} の worktree・branch {}・Repositories の行 {row})",
                short(&top),
                short(&root),
                branch.as_deref().unwrap_or("(detached)")
            ),
        )
    } else {
        let start = match form {
            Form::Hc => "会話は herdr-app の New worktree で切った worktree で始める",
            Form::T3 { .. } => "会話は T3 Code で worktree のスレッドを作って始める",
        };
        Line::new(
            Mark::Warn,
            LABEL,
            format!(
                "{} (ハブの main の checkout。{start}。main の checkout ではチケットの Branch が入らず、ほかの会話とも重なる)",
                short(&top)
            ),
        )
    };
    let mut lines = vec![line];
    // 旧 herdr のハブの worktree の branch (worktree/<名前>) と重なると、WSL の見回りもこのチケットを読む (spec §7.10)
    if hc
        && worktree
        && let Some(b) = branch.as_deref().filter(|b| b.starts_with(OLD_HUB_BRANCH))
    {
        lines.push(Line::new(
            Mark::Warn,
            LABEL,
            format!(
                "branch {b} は旧 herdr のハブの worktree の形 ({OLD_HUB_BRANCH}<名前>)。同じ branch のチケットを WSL の見回りも読みうる (次の worktree から、ほかの形の名前にする)"
            ),
        ));
    }
    let hub = Hub {
        root,
        top,
        worktree,
        hc,
    };
    (lines, Some(hub))
}

/// ハブの main の checkout とこの worktree が、今の雛形どおりか。
pub fn template_lines(git: &Git, hub: &Hub) -> Vec<Line> {
    const LABEL: &str = "雛形";
    if !hub.hc {
        return vec![Line::new(Mark::Skip, LABEL, "旧 herdr のハブなので見ない")];
    }
    let home = paths::home_dir().unwrap_or_else(|_| PathBuf::from("/"));
    let files = match Context::at(&home, cfg!(windows)) {
        Ok(ctx) => templates::files(&ctx),
        // 雛形の重ねのファイル (private な足し分) が壊れている
        Err(e) => return vec![Line::new(Mark::Ng, LABEL, e.to_string())],
    };
    let mut lines = Vec::new();
    match init::check_hub(git, &hub.root, &home, files.clone()) {
        Ok(d) if d.is_empty() => {}
        Ok(d) => lines.push(Line::new(
            Mark::Warn,
            LABEL,
            format!(
                "{} に雛形との差が {} 件 (pjp hub check で見る。直すのは pjp hub init。dotfiles の Windows の runner が打つ)",
                short(&hub.root),
                d.len()
            ),
        )),
        Err(e) => lines.push(Line::new(
            Mark::Warn,
            LABEL,
            format!("{} を見られません: {e}", short(&hub.root)),
        )),
    }
    if hub.worktree {
        let old: Vec<&str> = files
            .iter()
            .filter(|t| t.rel != ".gitignore")
            .filter(|t| !std::fs::read(t.path_in(&hub.top)).is_ok_and(|b| t.same_as(&b)))
            .map(|t| t.rel)
            .collect();
        if !old.is_empty() {
            lines.push(Line::new(
                Mark::Warn,
                LABEL,
                format!(
                    "この worktree の {} は今の雛形と違う (前の雛形から切った worktree。hook と skillOverrides は、この会話では切った時の中身で効く)",
                    old.join("・")
                ),
            ));
        }
    }
    if lines.is_empty() {
        let what = if hub.worktree {
            format!("{} もこの worktree も雛形どおり", short(&hub.root))
        } else {
            format!("{} は雛形どおり", short(&hub.root))
        };
        lines.push(Line::new(Mark::Ok, LABEL, what));
    }
    lines
}

/// hc の行: この端末・label・見回り役・hc の machine。
pub fn hc_lines(r: &dyn Runner, hub: Option<&Hub>, hubd_available: bool) -> Vec<Line> {
    let Some(hc) = r.which("hc") else {
        return vec![Line::new(
            Mark::Ng,
            "hc",
            "PATH にありません (dotfiles が入れる)。この端末・見回り役・hc の machine は見ない",
        )];
    };
    let mut lines = terminal_lines(r, &hc);
    lines.push(hubd_line(r, &hc, hub, hubd_available));
    lines.extend(machine_lines(r, &hc));
    lines
}

fn hc_cmd(hc: &Path, args: &[&str]) -> Cmd {
    Cmd::new(hc).args(args).timeout(HC_TIMEOUT)
}

fn first_line(s: &str) -> &str {
    s.lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("")
}

/// hc を打って JSON を読む。落ちたら、利用者に見せる 1 行。
fn hc_json(r: &dyn Runner, hc: &Path, args: &[&str]) -> std::result::Result<Value, String> {
    let shown = format!("hc {}", args.join(" "));
    let out = r
        .run(&hc_cmd(hc, args))
        .map_err(|e| format!("{shown} を打てません: {e}"))?;
    if out.timed_out {
        return Err(format!(
            "{shown} が {} 秒で返りません",
            HC_TIMEOUT.as_secs()
        ));
    }
    if !out.success() {
        return Err(format!("{shown} が落ちました: {}", first_line(&out.stderr)));
    }
    serde_json::from_str(&out.stdout).map_err(|_| format!("{shown} の出力を JSON として読めません"))
}

/// この端末 (OSC 7501 の報告) と label。
fn terminal_lines(r: &dyn Runner, hc: &Path) -> Vec<Line> {
    const LABEL: &str = "この端末";
    let Some(term) = r.env("HC_TERMINAL_ID") else {
        return vec![Line::new(
            Mark::Ng,
            LABEL,
            "hc の端末の外 (HC_TERMINAL_ID が無い)。ハブの会話は herdr-app の端末で立てる",
        )];
    };
    let v = match hc_json(r, hc, &["get", term.as_str(), "--json"]) {
        Ok(v) => v,
        Err(e) => return vec![Line::new(Mark::Warn, LABEL, e)],
    };
    let state = if v["reported"].as_bool() == Some(true) {
        Line::new(
            Mark::Ok,
            LABEL,
            format!(
                "{term} は状態を報告している ({}: {})",
                v["status"]["app"].as_str().unwrap_or("?"),
                v["status"]["state"].as_str().unwrap_or("?")
            ),
        )
    } else {
        Line::new(
            Mark::Warn,
            LABEL,
            format!(
                "{term} は状態を報告していない (OSC 7501)。見回り役は、状態を報告しない会話に Notion のコメントを届けない (spec §13 の #1)"
            ),
        )
    };
    let mut labels: Vec<String> = v["labels"]
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(k, _)| k.starts_with("pjp."))
        .map(|(k, val)| format!("{k}={}", val.as_str().unwrap_or("?")))
        .collect();
    labels.sort();
    let label = if labels.is_empty() {
        Line::new(
            Mark::Skip,
            "label",
            "pjp.* はまだ無い (チケットを決めたら pjp mark name 'TKT-n <主題>' で付く)",
        )
    } else {
        Line::new(Mark::Ok, "label", labels.join("・"))
    };
    vec![state, label]
}

/// `hc ls --json` の答えのうち、このマシンで動いている端末の address。hc ls はつながっている別のマシンの端末
/// (`machine/t7`) も出すので、`/` を含む address は数えない。
fn local_live(v: &Value) -> Vec<String> {
    v["terminals"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|t| t["state"].as_str().is_none_or(|s| s == "live"))
        .filter_map(|t| t["address"].as_str().map(str::to_owned))
        .filter(|address| !address.contains('/'))
        .collect()
}

/// 動いている見回り役の端末 (label `pjp.role=hubd`)。見回り役はハブのマシンごとに要る (自分のマシンのハブの worktree の
/// チケットだけを見る。spec §7.10) ので、このマシンの端末だけを数える。
fn hubd_terminals(r: &dyn Runner, hc: &Path) -> std::result::Result<Vec<String>, String> {
    let v = hc_json(r, hc, &["ls", "--json", "--label", HUBD_LABEL])?;
    Ok(local_live(&v))
}

/// 見回り役が動いているか。動いていなければ立てる (spec §8.1)。
fn hubd_line(r: &dyn Runner, hc: &Path, hub: Option<&Hub>, hubd_available: bool) -> Line {
    const LABEL: &str = "見回り役";
    match hubd_terminals(r, hc) {
        Err(e) => return Line::new(Mark::Warn, LABEL, e),
        Ok(t) if !t.is_empty() => {
            return Line::new(
                Mark::Ok,
                LABEL,
                format!("{HUBD_NAME} が動いている ({})", t.join("・")),
            );
        }
        Ok(_) => {}
    }
    let hub = match hub {
        None => return Line::new(Mark::Skip, LABEL, "ハブの外なので立てない"),
        Some(h) if !h.hc => {
            return Line::new(
                Mark::Skip,
                LABEL,
                "旧 herdr のハブなので立てない (見回りは systemd の pjp-dev-tracker-inbox.service)",
            );
        }
        Some(_) if !hubd_available => {
            return Line::new(
                Mark::Skip,
                LABEL,
                format!(
                    "{HUBD_NAME} はまだ無い (spec §10 の W2-3 で入る)。それまで Notion のコメントはこの会話に届かない"
                ),
            );
        }
        Some(h) => h,
    };
    // ハブの main の checkout で立てる (Windows では、動いている process の cwd のディレクトリを消せない。会話の worktree で
    // 立てると、その worktree を片付けられなくなる)
    let root = hub.root.to_string_lossy();
    let start = [
        "run",
        "--bg",
        "--json",
        "--no-parent",
        "--name",
        HUBD_NAME,
        "--cwd",
        root.as_ref(),
        "--label",
        HUBD_LABEL,
        "--",
        "pjp",
        "--supervise",
        "hubd",
    ];
    let started = r.run(&hc_cmd(hc, &start));
    match hubd_terminals(r, hc) {
        Ok(t) if !t.is_empty() => Line::new(
            Mark::Ok,
            LABEL,
            format!("{HUBD_NAME} を立てた ({})", t.join("・")),
        ),
        _ => {
            let why = match started {
                Ok(o) if !o.success() => first_line(&o.stderr).to_owned(),
                Ok(_) => "立てた後の hc ls に出ない".to_owned(),
                Err(e) => e.to_string(),
            };
            Line::new(
                Mark::Ng,
                LABEL,
                format!("{HUBD_NAME} を立てられません: {why}"),
            )
        }
    }
}

/// 手元の WSL を hc の machine に足すコマンド (Windows のハブで打つ。名前は自由)。pjp-hc-child の `pjp child new --on wsl` が
/// WSL の machine の無いときに出すものと同じ形。
const WSL_ADD: &str =
    "hc machine add --via 'wsl.exe -d <ディストリビューション> --cd ~ -e bash -lc' --name <名前>";

/// `pjp child new` の `--on` (と hub.toml の `default_machine`) が machine の名前より先に読む語と、その意味。名前がこれと同じ
/// machine は `--on` で名指しできない (名前が wsl の手元の WSL の machine は、一時の machine でなければ語と同じ machine を指すので
/// 構わない)。
const ON_WORDS: [(&str, &str); 3] = [
    ("local", "このマシン"),
    ("wsl", "手元の WSL"),
    ("auto", "自動で選ぶ"),
];

/// hc の machine (`hc machine ls --json`) につながっているか。手元の WSL の machine には印を添え、Windows のハブに WSL の
/// machine (一時の machine を除く) が無ければ足し方を出す。
fn machine_lines(r: &dyn Runner, hc: &Path) -> Vec<Line> {
    const LABEL: &str = "hc の machine";
    let v = match hc_json(r, hc, &["machine", "ls", "--json"]) {
        Ok(v) => v,
        Err(e) => return vec![Line::new(Mark::Warn, LABEL, e)],
    };
    let machines = v["machines"].as_array().map(Vec::as_slice).unwrap_or(&[]);
    let mut lines = if machines.is_empty() {
        vec![Line::new(
            Mark::Warn,
            LABEL,
            "足していない (子を立てるマシンを hc machine add で足す)",
        )]
    } else {
        machines.iter().map(|m| machine_line(LABEL, m)).collect()
    };
    let has_wsl = machines
        .iter()
        .any(|m| is_wsl(m) && m["temporary"].as_bool() != Some(true));
    if r.windows() && !has_wsl {
        lines.push(Line::new(
            Mark::Warn,
            format!("{LABEL} (WSL)"),
            format!(
                "手元の WSL の machine が無い (WSL でしか動かない子 (pjp child new --on wsl・--chrome) と、WSL で流す \
                 pjp ticket の command に要る)。足すなら: {WSL_ADD} (ディストリビューションの名前は wsl.exe -l -v で見る。\
                 名前は自由で、pjp child new --on wsl は名前によらず WSL の machine を選ぶ)"
            ),
        ));
    }
    lines
}

/// hc の machine の 1 行 (`hc の machine <名前>`)。
fn machine_line(label: &str, m: &Value) -> Line {
    let name = m["name"].as_str().unwrap_or("?");
    let state = m["state"].as_str().unwrap_or("?");
    let wsl = is_wsl(m);
    let temporary = m["temporary"].as_bool() == Some(true);
    let mut notes: Vec<&str> = Vec::new();
    if wsl {
        notes.push("手元の WSL");
    }
    if temporary {
        notes.push("一時の machine");
    }
    let label = format!("{label} {name}");
    let mut line = if state == "connected" {
        let tag = if notes.is_empty() {
            String::new()
        } else {
            format!(" ({})", notes.join("・"))
        };
        Line::new(Mark::Ok, label, format!("connected{tag}"))
    } else {
        let why = m["why"]
            .as_str()
            .map(|w| format!("。{w}"))
            .unwrap_or_default();
        let mut paren = notes.join("・");
        if !paren.is_empty() {
            paren.push('。');
        }
        Line::new(
            Mark::Warn,
            label,
            format!("{state}{why} ({paren}このマシンには子を立てられない)"),
        )
    };
    // 名前が wsl の手元の WSL の machine は語と同じ machine を指すので構わない (一時の machine は --on wsl が選ばないので除く)
    if let Some((word, means)) = ON_WORDS.iter().find(|(w, _)| *w == name)
        && !(name == "wsl" && wsl && !temporary)
    {
        line.mark = Mark::Warn;
        line.detail.push_str(&format!(
            "。名前が pjp child new の --on の語 ({word} は{means}) と同じなので、--on {word} ではこの machine を名指しできない \
             (名指しするなら hc machine rename {word} <新しい名前> で替える。替えると、この machine の端末の住所も替わる)"
        ));
    }
    line
}

/// hc machine ls の 1 台が手元の WSL か: `--via` の machine で、そのコマンドの最初の語 (引用符で囲んでいれば囲みの中) のパスの
/// 名前が wsl.exe か wsl。名前は見ない。pjp-hc-child の `hc::is_wsl_machine` (`pjp child new --on wsl` が WSL の machine を
/// 選ぶ見分け) の写しで、テストが突き合わせる (pjp hub の exe を pjp-hc-child に結ばない。hook の guard と同じ exe なので、
/// pjp-hc-child を直すたびに作り直さない)。
fn is_wsl(m: &Value) -> bool {
    if m["via"].as_bool() != Some(true) {
        return false;
    }
    let t = m["target"].as_str().unwrap_or_default().trim_start();
    let first = match t.chars().next() {
        Some(q @ ('"' | '\'')) => t[1..].split(q).next().unwrap_or_default(),
        _ => t.split_whitespace().next().unwrap_or_default(),
    };
    let base = first.rsplit(['/', '\\']).next().unwrap_or(first);
    base.eq_ignore_ascii_case("wsl.exe") || base.eq_ignore_ascii_case("wsl")
}

/// T3 の行: T3 のスレッド・T3 のリンク・T3 の設定 (2 行)・見回り役・hc の machine (T3 Code の spec §4.3)。`home` はホーム
/// (T3 だけの設定のファイルと T3 の設定を読む)、`cwd` は Launch arguments の相対パスを解く所 (T3 はスレッドの cwd から読み、
/// hello はその会話の cwd で打たれる)、`now` はリンクの期限と比べる今。
pub fn t3_lines(
    r: &dyn Runner,
    thread: &str,
    home: &Path,
    cwd: &Path,
    now: Timestamp,
) -> Vec<Line> {
    let mut lines = vec![Line::new(Mark::Ok, "T3 のスレッド", thread)];
    lines.extend(link_lines(r, now));
    lines.extend(t3_settings_lines(r, home, cwd));
    lines.push(Line::new(
        Mark::Skip,
        "見回り役",
        "T3 Code の会話には立てない (T3 のスレッドには Notion のコメントを届けない)",
    ));
    match r.which("hc") {
        Some(hc) => lines.extend(machine_lines(r, &hc)),
        None => lines.push(Line::new(
            Mark::Ng,
            "hc",
            "PATH にありません (dotfiles が入れる)。長い子の見張り (hc exec --on <machine> -- t3 thread show) と、Windows に無い pjp ticket の command (手元の WSL で流す) に使う。hc の machine は見ない",
        )),
    }
    lines
}

/// T3 のリンク (子のスレッドを立てる先。T3 につないだ別のマシン) を、T3 の CLI の `environment list --json` で 1 つ 1 行に出す。
/// 答えのつなぐ先 (urls) は出さない。CLI が無い・落ちたときは 1 行。
fn link_lines(r: &dyn Runner, now: Timestamp) -> Vec<Line> {
    const LABEL: &str = "T3 のリンク";
    const SHOWN: &str = "t3 environment list --json";
    let Some(cli) = r.env(T3_CLI_ENV) else {
        return vec![Line::new(
            Mark::Skip,
            LABEL,
            format!(
                "env に {T3_CLI_ENV} が無いので見ない (子のスレッドを立てる前に t3_environment_links で見る)"
            ),
        )];
    };
    let warn = |why: String| {
        vec![Line::new(
            Mark::Warn,
            LABEL,
            format!("{why} (子のスレッドを立てる前に t3_environment_links で見る)"),
        )]
    };
    let cmd = Cmd::new(&cli)
        .args(["environment", "list", "--json"])
        .timeout(T3_TIMEOUT);
    let out = match r.run(&cmd) {
        Ok(out) => out,
        Err(e) => return warn(format!("{SHOWN} を打てません: {e}")),
    };
    if out.timed_out {
        return warn(format!(
            "{SHOWN} が {} 秒で返りません",
            T3_TIMEOUT.as_secs()
        ));
    }
    if !out.success() {
        return warn(format!("{SHOWN} が落ちました: {}", first_line(&out.stderr)));
    }
    let Ok(Value::Array(links)) = serde_json::from_str::<Value>(&out.stdout) else {
        return warn(format!("{SHOWN} の出力をリンクの並びとして読めません"));
    };
    if links.is_empty() {
        return vec![Line::new(
            Mark::Warn,
            LABEL,
            "リンク先が無い (子のスレッドを立てる先が無い。T3 の Settings → Connections の Linked environments で、子を立てるマシンを full-access でつなぐ)",
        )];
    }
    links.iter().map(|link| link_line(link, now)).collect()
}

/// リンク 1 つの行。T3 の画面 (Settings → Connections の Linked environments) と同じ順に見る: 期限切れ (status か期限) →
/// 届かない → エラーがある → 期限まで [`LINK_WARN_DAYS`] 日以下。続けて access が [`LINK_ACCESS`] かも見る。
fn link_line(link: &Value, now: Timestamp) -> Line {
    let name = ["label", "environmentId"]
        .iter()
        .find_map(|k| link[*k].as_str().map(str::trim).filter(|s| !s.is_empty()))
        .unwrap_or("?");
    let label = format!("T3 のリンク {name}");
    let status = link["status"].as_str().unwrap_or("?");
    let expires = link["expiresAt"]
        .as_str()
        .and_then(|s| time::parse_time(s).ok());
    let error = link["lastError"]
        .as_str()
        .map(first_line)
        .filter(|e| !e.is_empty());
    if status == "expired" || expires.is_some_and(|e| e <= now) {
        return Line::new(Mark::Warn, label, format!("期限切れ ({RELINK})"));
    }
    if status == "unreachable" {
        let why = error.map(|e| format!("。{e}")).unwrap_or_default();
        return Line::new(
            Mark::Warn,
            label,
            format!(
                "unreachable{why} (相手のマシンで T3 が動いているか・つながるかを見る。届くまで、そこには子のスレッドを立てない)"
            ),
        );
    }
    if let Some(e) = error {
        return Line::new(
            Mark::Warn,
            label,
            format!("{status} だが、エラーが出ている: {e} (続くなら、相手のマシンの T3 を見る)"),
        );
    }
    if status != "reachable" {
        return Line::new(
            Mark::Warn,
            label,
            format!(
                "{status} (reachable でない。子のスレッドを立てる前に t3_environment_links で見る)"
            ),
        );
    }
    let access = link["access"].as_str().unwrap_or("?");
    let left = expires.map(|e| {
        let days = days_until(now, e);
        (days, format!("期限 {} まであと {days} 日", jst_date(e)))
    });
    let mut concerns = Vec::new();
    if let Some((days, text)) = &left
        && *days <= LINK_WARN_DAYS
    {
        concerns.push(text.clone());
    }
    if access != LINK_ACCESS {
        concerns.push(format!("access が {access}"));
    }
    if concerns.is_empty() {
        let left = left
            .map(|(_, text)| format!("・{text}"))
            .unwrap_or_default();
        Line::new(
            Mark::Ok,
            label,
            format!("reachable (access {access}{left})"),
        )
    } else {
        Line::new(
            Mark::Warn,
            label,
            format!(
                "reachable だが、{} (子のスレッドは full-access のリンクに立てる。{RELINK})",
                concerns.join("・")
            ),
        )
    }
}

/// `now` から `until` (`now` より後) までの日数を、T3 の画面と同じくミリ秒から日に切り上げる。
fn days_until(now: Timestamp, until: Timestamp) -> i64 {
    const DAY_MS: i64 = 86_400_000;
    let ms = (until.secs - now.secs) * 1000
        + (i64::from(until.nanos) - i64::from(now.nanos)) / 1_000_000;
    (ms + DAY_MS - 1).div_euclid(DAY_MS)
}

/// 日本時間の日付 (`2026-12-22`)。
fn jst_date(t: Timestamp) -> String {
    let d = t.to_jst();
    format!("{:04}-{:02}-{:02}", d.year, d.month, d.day)
}

/// T3 だけの設定のファイルを置くディレクトリ (`~/.claude/t3`。T3 の `CLAUDE_CONFIG_DIR` によらず `~/.claude` の下)。
fn t3_files_dir(home: &Path) -> PathBuf {
    home.join(".claude").join("t3")
}

/// T3 の設定のファイル (`$T3CODE_HOME` か `~/.t3` の下の `userdata/settings.json`。T3 と同じく、`T3CODE_HOME` の頭の `~` は
/// ホームに展開する)。
fn t3_app_settings(r: &dyn Runner, home: &Path) -> PathBuf {
    let base = match r.env("T3CODE_HOME").as_deref().map(str::trim) {
        Some(raw) if !raw.is_empty() => paths::expand_tilde_here(OsStr::new(raw), home),
        _ => home.join(".t3"),
    };
    base.join("userdata").join("settings.json")
}

/// T3 の設定の 2 行: T3 だけの設定のファイルがあるか・T3 の Launch arguments がそれを渡しているか。
fn t3_settings_lines(r: &dyn Runner, home: &Path, cwd: &Path) -> Vec<Line> {
    const LABEL: &str = "T3 の設定";
    let dir = t3_files_dir(home);
    let missing: Vec<&str> = T3_FILES
        .iter()
        .map(|(_, name)| *name)
        .filter(|name| !dir.join(name).is_file())
        .collect();
    let files = if missing.is_empty() {
        Line::new(
            Mark::Ok,
            LABEL,
            format!(
                "{} に {} がある",
                short(&dir),
                T3_FILES.map(|(_, name)| name).join("・")
            ),
        )
    } else {
        Line::new(
            Mark::Warn,
            LABEL,
            format!(
                "{} に {} が無い (dotfiles の Windows の runner が置く: dotfiles apply --steps claude-t3)",
                short(&dir),
                missing.join("・")
            ),
        )
    };
    vec![files, launch_args_line(r, home, cwd, &dir)]
}

/// T3 の Launch arguments (`providerInstances.claudeAgent.config.launchArgs`) が、T3 だけの設定のファイルを 2 つとも渡して
/// いるか。T3 の設定のファイルから読むのはこの値だけで、ほかの値 (env の秘密を含みうる) は出さない。
///
/// 書くのは、T3 Code を dotfiles で入れた PC (switch `windowsT3Code`) なら `dotfiles apply` の手順 `t3-code-settings`
/// (手順 claude-t3 が 2 つのファイルを置いた後。そろっていなければ書かない)、入れていない PC ならユーザー (T3 の画面)。
/// `!!` の直し方には両方を書く (T3 Code の spec §4.1・D9)。apply が書いたら T3 Code を開き直し、画面で書いたら会話を開き直す。
/// 開き直して効くのは `--settings` (claude の起動の flag) だけ。`--append-system-prompt-file` は T3 がターンごとに読み直すが、
/// Claude Code が会話の system prompt を最初の要求で記録して compaction まで同じものを送る (`systemPromptSnapshot`) ので、
/// 今ある会話には開き直しても入らず、新しい会話から入る。
fn launch_args_line(r: &dyn Runner, home: &Path, cwd: &Path, dir: &Path) -> Line {
    const LABEL: &str = "T3 の設定";
    let file = t3_app_settings(r, home);
    let skip = |why: &str| {
        Line::new(
            Mark::Skip,
            LABEL,
            format!(
                "{} {why}ので、T3 の Launch arguments は見ない",
                short(&file)
            ),
        )
    };
    let Ok(text) = std::fs::read_to_string(&file) else {
        return skip("を読めない");
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else {
        return skip("を JSON として読めない");
    };
    let Some(config) = v
        .pointer("/providerInstances/claudeAgent/config")
        .and_then(Value::as_object)
    else {
        return skip("に providerInstances.claudeAgent.config が無い");
    };
    // T3 で一度も書いていなければ launchArgs が無い (空と同じ)
    let args = match config.get("launchArgs") {
        None | Some(Value::Null) => "",
        Some(Value::String(s)) => s.as_str(),
        Some(_) => return skip("の launchArgs が文字列でない"),
    };
    let flags = launch_arg_flags(args);
    let missing: Vec<String> = T3_FILES
        .iter()
        .filter(|&&(flag, name)| {
            !flags
                .get(flag.trim_start_matches('-'))
                .and_then(Option::as_deref)
                .is_some_and(|value| names_file(value, &dir.join(name), home, cwd))
        })
        .map(|&(flag, name)| format!("{flag} {}", arg_text(&dir.join(name))))
        .collect();
    if missing.is_empty() {
        Line::new(
            Mark::Ok,
            LABEL,
            "T3 の Launch arguments が 2 つのファイルを渡している (settings.json を変えたら、会話を開き直すと効く。CLAUDE.t3.md を変えたら、新しい会話から効き、今ある会話には次の compaction まで入らない)",
        )
    } else {
        Line::new(
            Mark::Warn,
            LABEL,
            format!(
                "T3 の Launch arguments に {} が無い (T3 Code を dotfiles で入れた PC は、dotfiles apply --steps claude-t3,t3-code-settings で書き、T3 Code を開き直す。入れていない PC は、ファイルを置いてから T3 の Settings → Providers → Claude → Launch arguments に書き、会話を開き直す。CLAUDE.t3.md は新しい会話から効き、今ある会話には次の compaction まで入らない)",
                missing.join(" ")
            ),
        )
    }
}

/// Launch arguments に書く形のパス (空白を含めば `"` で囲む)。
fn arg_text(p: &Path) -> String {
    let s = p.display().to_string();
    if s.chars().any(char::is_whitespace) {
        format!("\"{s}\"")
    } else {
        s
    }
}

/// Launch arguments のファイルの値 `value` が `want` を指すか。T3 と同じく頭の `~` (`~`・`~/`。Windows は `~\` も) をホームに
/// 展開し、相対ならスレッドの cwd から字面で解く。比べ方はこのマシンの決まり (Windows は大文字小文字と `/`・`\` を見ない)。
fn names_file(value: &str, want: &Path, home: &Path, cwd: &Path) -> bool {
    let value = value.trim();
    if value.is_empty() {
        return false;
    }
    let expanded = paths::expand_tilde_here(OsStr::new(value), home);
    paths::same_path_here(
        &pathx::absolute_lexical(&expanded, cwd),
        &pathx::absolute_lexical(want, cwd),
    )
}

/// T3 の Launch arguments を flag ごとに分ける (T3 v0.1.11 の `parseCliArgs`)。key は頭の `--` を除いた名前。`--x v` と
/// `--x=v` を読み、値の無い flag (次が `--` で始まる・最後) は None。同じ flag は後の値が勝ち、`--` から後ろは見ない。
fn launch_arg_flags(args: &str) -> HashMap<String, Option<String>> {
    let tokens = launch_arg_tokens(args);
    let mut flags = HashMap::new();
    let mut i = 0;
    while i < tokens.len() {
        let token = &tokens[i];
        if token == "--" {
            break;
        }
        if let Some(rest) = token.strip_prefix("--") {
            if let Some((key, value)) = rest.split_once('=') {
                flags.insert(key.to_owned(), Some(value.to_owned()));
            } else {
                match tokens.get(i + 1) {
                    Some(next) if LAUNCH_VALUE_FLAGS.contains(&rest) || !next.starts_with("--") => {
                        flags.insert(rest.to_owned(), Some(next.clone()));
                        i += 1;
                    }
                    _ => {
                        flags.insert(rest.to_owned(), None);
                    }
                }
            }
        }
        i += 1;
    }
    flags
}

/// T3 の Launch arguments の区切り (T3 v0.1.11 の `tokenizeCliArgs`)。空白で区切り、`'…'`・`"…"` で囲めば空白も入る。`"…"` の
/// 中の `\` は `"`・`\`・`$`・`` ` `` の前でだけ次の字を写す。囲みの外の `\` は空白と引用符の前でだけ次の字を写し、ほかの `\` は
/// そのまま残す (Windows のパスは囲まずに書ける)。
fn launch_arg_tokens(input: &str) -> Vec<String> {
    let chars: Vec<char> = input.chars().collect();
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut quoted = false;
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        if let Some(q) = quote {
            if c == q {
                quote = None;
            } else if let Some(n) =
                next.filter(|n| c == '\\' && q == '"' && matches!(*n, '"' | '\\' | '$' | '`'))
            {
                current.push(n);
                i += 1;
            } else {
                current.push(c);
            }
        } else if c == '\'' || c == '"' {
            quote = Some(c);
            quoted = true;
        } else if matches!(c, ' ' | '\t' | '\n' | '\r' | '\u{0b}' | '\u{0c}') {
            if !current.is_empty() || quoted {
                tokens.push(std::mem::take(&mut current));
                quoted = false;
            }
        } else if let Some(n) =
            next.filter(|n| c == '\\' && (n.is_whitespace() || *n == '\'' || *n == '"'))
        {
            current.push(n);
            i += 1;
        } else {
            current.push(c);
        }
        i += 1;
    }
    if !current.is_empty() || quoted {
        tokens.push(current);
    }
    tokens
}

/// この crate の Cargo.toml の `[[bin]]` に見回り役 (`pjp-hubd`) があるか (spec の W2-3 で足す)。
pub fn hubd_bin_here() -> bool {
    // 作るときに埋め込む (Cargo.toml を直すと cargo が作り直すので、bin を足した版の exe だけが立てる)
    manifest_has_bin(include_str!("../Cargo.toml"), HUBD_BIN)
}

/// Cargo.toml の `[[bin]]` に `name` があるか。
pub fn manifest_has_bin(text: &str, name: &str) -> bool {
    let Ok(table) = text.parse::<toml::Table>() else {
        return false;
    };
    table
        .get("bin")
        .and_then(|b| b.as_array())
        .into_iter()
        .flatten()
        .any(|b| b.get("name").and_then(|n| n.as_str()) == Some(name))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// 偽の hc (と T3 の CLI)。打った program と引数の列を覚え、決めた答えを返す。
    #[derive(Default)]
    struct Fake {
        hc: bool,
        /// Windows のハブか (既定は Linux)。
        windows: bool,
        env: HashMap<String, String>,
        /// 引数 (空白でつないだもの) の頭 → 答え。
        answers: Vec<(String, Output)>,
        /// 立てた後の hc ls の答え。
        after_run: Option<Output>,
        seen: RefCell<Vec<String>>,
        /// 打った program (打った順)。
        programs: RefCell<Vec<String>>,
    }

    fn ok(stdout: &str) -> Output {
        Output {
            code: Some(0),
            stdout: stdout.to_owned(),
            stderr: String::new(),
            timed_out: false,
        }
    }

    fn failed(stderr: &str) -> Output {
        Output {
            code: Some(1),
            stdout: String::new(),
            stderr: stderr.to_owned(),
            timed_out: false,
        }
    }

    impl Fake {
        fn with(mut self, prefix: &str, out: Output) -> Fake {
            self.answers.push((prefix.to_owned(), out));
            self
        }

        fn ran(&self, prefix: &str) -> bool {
            self.seen.borrow().iter().any(|s| s.starts_with(prefix))
        }
    }

    impl Runner for Fake {
        fn which(&self, name: &str) -> Option<PathBuf> {
            (name == "hc" && self.hc).then(|| PathBuf::from("hc"))
        }

        fn run(&self, cmd: &Cmd) -> Result<Output> {
            let args: Vec<String> = cmd
                .get_args()
                .iter()
                .map(|a| a.to_string_lossy().into_owned())
                .collect();
            let line = args.join(" ");
            let ran_before = self.ran("run ");
            self.seen.borrow_mut().push(line.clone());
            self.programs
                .borrow_mut()
                .push(cmd.program().to_string_lossy().into_owned());
            if line.starts_with("ls ")
                && ran_before
                && let Some(after) = &self.after_run
            {
                return Ok(after.clone());
            }
            Ok(self
                .answers
                .iter()
                .find(|(p, _)| line.starts_with(p.as_str()))
                .map_or_else(|| failed("no answer"), |(_, o)| o.clone()))
        }

        fn env(&self, key: &str) -> Option<String> {
            self.env.get(key).cloned()
        }

        fn windows(&self) -> bool {
            self.windows
        }
    }

    fn hub(hc: bool) -> Hub {
        Hub {
            root: PathBuf::from("hub-root"),
            top: PathBuf::from("hub-root"),
            worktree: true,
            hc,
        }
    }

    /// hc の端末の中で、状態を報告している会話 (machine の答えはまだ無い)。
    fn in_terminal() -> Fake {
        Fake {
            hc: true,
            env: HashMap::from([("HC_TERMINAL_ID".to_owned(), "t9".to_owned())]),
            ..Fake::default()
        }
        .with(
            "get t9",
            ok(r#"{"reported":true,"status":{"app":"claude-code","state":"working"},"labels":{"herdr.space":"sp1","pjp.role":"hub","pjp.ticket":"ABC-1"}}"#),
        )
    }

    fn base() -> Fake {
        in_terminal().with(
            "machine ls",
            ok(r#"{"machines":[{"name":"wsl1","state":"connected"}]}"#),
        )
    }

    fn by_label<'a>(lines: &'a [Line], label: &str) -> &'a Line {
        lines
            .iter()
            .find(|l| l.label == label)
            .unwrap_or_else(|| panic!("{label} が無い: {lines:?}"))
    }

    #[test]
    fn without_hc_is_one_ng_line() {
        let lines = hc_lines(&Fake::default(), Some(&hub(true)), true);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].mark, Mark::Ng);
        assert_eq!(lines[0].label, "hc");
    }

    #[test]
    fn terminal_reports_state_and_labels() {
        let f = base().with(
            "ls ",
            ok(r#"{"terminals":[{"address":"t5","state":"live"}]}"#),
        );
        let lines = hc_lines(&f, Some(&hub(true)), true);
        let term = by_label(&lines, "この端末");
        assert_eq!(term.mark, Mark::Ok);
        assert!(term.detail.contains("claude-code: working"), "{term}");
        let label = by_label(&lines, "label");
        assert_eq!(label.detail, "pjp.role=hub・pjp.ticket=ABC-1");
        let hubd = by_label(&lines, "見回り役");
        assert_eq!(hubd.mark, Mark::Ok);
        assert!(hubd.detail.contains("t5"), "{hubd}");
        assert!(!f.ran("run "), "動いているのに立てた");
        assert_eq!(by_label(&lines, "hc の machine wsl1").mark, Mark::Ok);
    }

    #[test]
    fn terminal_not_reporting_is_a_warning() {
        let f = Fake {
            hc: true,
            env: HashMap::from([("HC_TERMINAL_ID".to_owned(), "t9".to_owned())]),
            ..Fake::default()
        }
        .with("get t9", ok(r#"{"reported":false,"labels":{}}"#))
        .with("ls ", ok(r#"{"terminals":[]}"#))
        .with("machine ls", ok(r#"{"machines":[]}"#));
        let lines = hc_lines(&f, Some(&hub(true)), false);
        let term = by_label(&lines, "この端末");
        assert_eq!(term.mark, Mark::Warn);
        assert!(term.detail.contains("#1"), "{term}");
        assert_eq!(by_label(&lines, "label").mark, Mark::Skip);
        assert_eq!(by_label(&lines, "hc の machine").mark, Mark::Warn);
    }

    #[test]
    fn outside_an_hc_terminal_is_ng() {
        let f = Fake {
            hc: true,
            ..Fake::default()
        }
        .with("ls ", ok(r#"{"terminals":[]}"#))
        .with("machine ls", ok(r#"{"machines":[]}"#));
        let lines = hc_lines(&f, None, true);
        assert_eq!(by_label(&lines, "この端末").mark, Mark::Ng);
        assert_eq!(by_label(&lines, "見回り役").mark, Mark::Skip);
    }

    #[test]
    fn hubd_is_not_started_before_w2_3_or_for_the_old_hub() {
        for (h, available, want) in [
            (Some(hub(true)), false, "まだ無い"),
            (Some(hub(false)), true, "旧 herdr"),
            (None, true, "ハブの外"),
        ] {
            let f = base().with("ls ", ok(r#"{"terminals":[]}"#));
            let lines = hc_lines(&f, h.as_ref(), available);
            let hubd = by_label(&lines, "見回り役");
            assert_eq!(hubd.mark, Mark::Skip, "{hubd}");
            assert!(hubd.detail.contains(want), "{hubd}");
            assert!(!f.ran("run "), "立てた: {want}");
        }
    }

    #[test]
    fn hubd_is_started_in_the_hub_root() {
        let mut f = base()
            .with("ls ", ok(r#"{"terminals":[]}"#))
            .with("run ", ok(r#"{"address":"t7"}"#));
        f.after_run = Some(ok(r#"{"terminals":[{"address":"t7","state":"live"}]}"#));
        let lines = hc_lines(&f, Some(&hub(true)), true);
        let hubd = by_label(&lines, "見回り役");
        assert_eq!(hubd.mark, Mark::Ok, "{hubd}");
        assert!(hubd.detail.contains("立てた (t7)"), "{hubd}");
        let seen = f.seen.borrow();
        let run = seen.iter().find(|s| s.starts_with("run ")).unwrap();
        assert_eq!(
            run,
            "run --bg --json --no-parent --name pjp-hubd --cwd hub-root --label pjp.role=hubd -- pjp --supervise hubd"
        );
    }

    #[test]
    fn hubd_of_another_machine_does_not_count() {
        // hc ls は別のマシンの端末 (wsl1/t5) も出す。WSL のハブの見回り役があっても、このマシンには立てる
        let mut f = base()
            .with(
                "ls ",
                ok(r#"{"terminals":[{"address":"wsl1/t5","state":"live"}]}"#),
            )
            .with("run ", ok(r#"{"address":"t7"}"#));
        f.after_run = Some(ok(
            r#"{"terminals":[{"address":"wsl1/t5","state":"live"},{"address":"t7","state":"live"}]}"#,
        ));
        let lines = hc_lines(&f, Some(&hub(true)), true);
        let hubd = by_label(&lines, "見回り役");
        assert_eq!(hubd.mark, Mark::Ok, "{hubd}");
        assert_eq!(hubd.detail, "pjp-hubd を立てた (t7)");
        assert!(f.ran("run "));
    }

    #[test]
    fn hubd_start_failure_is_ng() {
        let f = base()
            .with("ls ", ok(r#"{"terminals":[]}"#))
            .with("run ", failed("{\"error\":{\"kind\":\"usage\"}}"));
        let lines = hc_lines(&f, Some(&hub(true)), true);
        let hubd = by_label(&lines, "見回り役");
        assert_eq!(hubd.mark, Mark::Ng, "{hubd}");
        assert!(hubd.detail.contains("usage"), "{hubd}");
    }

    #[test]
    fn hc_failures_are_warnings() {
        let f = Fake {
            hc: true,
            env: HashMap::from([("HC_TERMINAL_ID".to_owned(), "t9".to_owned())]),
            ..Fake::default()
        };
        let lines = hc_lines(&f, Some(&hub(true)), true);
        for label in ["この端末", "見回り役", "hc の machine"] {
            assert_eq!(by_label(&lines, label).mark, Mark::Warn, "{label}");
        }
    }

    #[test]
    fn disconnected_machine_is_a_warning() {
        let f = in_terminal().with("ls ", ok(r#"{"terminals":[]}"#)).with(
            "machine ls",
            ok(r#"{"machines":[{"name":"host-a","state":"needs_login","why":"ssh"}]}"#),
        );
        let lines = hc_lines(&f, Some(&hub(true)), false);
        let m = by_label(&lines, "hc の machine host-a");
        assert_eq!(m.mark, Mark::Warn);
        assert!(m.detail.contains("needs_login。ssh"), "{m}");
    }

    // ---- 手元の WSL の machine ----

    /// WSL を Ubuntu-24.04 のまま足した machine の target (名前は PC ごとに違う)。
    const WSL_TARGET: &str = "wsl.exe -d Ubuntu-24.04 --cd ~ -e bash -lc";

    /// hc machine ls の 1 台 (target が wsl.exe で始まれば --via の machine)。
    fn machine(name: &str, target: &str) -> Value {
        serde_json::json!({
            "name": name,
            "target": target,
            "via": target.starts_with("wsl.exe"),
            "state": "connected",
        })
    }

    /// Windows か Linux のハブで、hc machine ls が `machines` を答える。
    fn hub_with_machines(windows: bool, machines: &[Value]) -> Vec<Line> {
        let list = serde_json::json!({ "machines": machines }).to_string();
        let f = Fake {
            windows,
            ..in_terminal()
        }
        .with("ls ", ok(r#"{"terminals":[]}"#))
        .with("machine ls", ok(&list));
        hc_lines(&f, Some(&hub(true)), false)
    }

    fn wsl_line(lines: &[Line]) -> Option<&Line> {
        lines.iter().find(|l| l.label == "hc の machine (WSL)")
    }

    #[test]
    fn windows_hub_without_a_wsl_machine_says_how_to_add_one() {
        let lines = hub_with_machines(true, &[machine("host-a", "host-a.local")]);
        assert_eq!(by_label(&lines, "hc の machine host-a").mark, Mark::Ok);
        let wsl = wsl_line(&lines).expect("WSL の行が無い");
        assert_eq!(wsl.mark, Mark::Warn);
        for want in [
            "手元の WSL の machine が無い",
            "hc machine add --via 'wsl.exe -d <ディストリビューション> --cd ~ -e bash -lc' --name <名前>",
            "wsl.exe -l -v",
            "名前は自由",
        ] {
            assert!(wsl.detail.contains(want), "{want}\n{wsl}");
        }
        // machine が 1 台も無いときも出す
        let lines = hub_with_machines(true, &[]);
        assert_eq!(by_label(&lines, "hc の machine").mark, Mark::Warn);
        assert!(wsl_line(&lines).is_some(), "{lines:?}");
        // 一時の machine の WSL は数えない
        let mut temp = machine("try", WSL_TARGET);
        temp["temporary"] = serde_json::json!(true);
        let lines = hub_with_machines(true, &[temp]);
        assert_eq!(
            by_label(&lines, "hc の machine try").detail,
            "connected (手元の WSL・一時の machine)"
        );
        assert!(wsl_line(&lines).is_some(), "{lines:?}");
    }

    #[test]
    fn wsl_machine_is_marked_whatever_its_name() {
        for name in ["ubuntu", "wsl", "wsl1"] {
            let lines = hub_with_machines(
                true,
                &[machine("host-a", "host-a.local"), machine(name, WSL_TARGET)],
            );
            let m = by_label(&lines, &format!("hc の machine {name}"));
            assert_eq!(
                (m.mark, m.detail.as_str()),
                (Mark::Ok, "connected (手元の WSL)"),
                "{name}"
            );
            assert_eq!(by_label(&lines, "hc の machine host-a").detail, "connected");
            assert!(wsl_line(&lines).is_none(), "{name}: {lines:?}");
        }
        // つながっていない WSL の machine
        let mut off = machine("ubuntu", WSL_TARGET);
        off["state"] = serde_json::json!("unreachable");
        off["why"] = serde_json::json!("wsl.exe exited");
        let lines = hub_with_machines(true, &[off]);
        let m = by_label(&lines, "hc の machine ubuntu");
        assert_eq!(m.mark, Mark::Warn);
        assert_eq!(
            m.detail,
            "unreachable。wsl.exe exited (手元の WSL。このマシンには子を立てられない)"
        );
    }

    #[test]
    fn linux_hub_does_not_ask_for_a_wsl_machine() {
        // Linux のハブ (SSH 先・WSL の中) は手元の WSL を足さない
        let lines = hub_with_machines(false, &[machine("host-a", "host-a.local")]);
        assert!(wsl_line(&lines).is_none(), "{lines:?}");
        let lines = hub_with_machines(false, &[]);
        assert!(wsl_line(&lines).is_none(), "{lines:?}");
    }

    #[test]
    fn machine_named_like_an_on_word_cannot_be_named_by_on() {
        // 名前が wsl の SSH 先・名前が local の machine は、pjp child new --on では名指しできない (語が先)
        let lines = hub_with_machines(
            true,
            &[
                machine("wsl", "box.local"),
                machine("local", "pc2.local"),
                machine("ubuntu", WSL_TARGET),
            ],
        );
        for (name, word) in [("wsl", "wsl は手元の WSL"), ("local", "local はこのマシン")]
        {
            let m = by_label(&lines, &format!("hc の machine {name}"));
            assert_eq!(m.mark, Mark::Warn, "{m}");
            for want in [
                "connected。名前が pjp child new の --on の語 (",
                word,
                &format!("--on {name} ではこの machine を名指しできない"),
                &format!("hc machine rename {name} <新しい名前>"),
            ] {
                assert!(m.detail.contains(want), "{want}\n{m}");
            }
        }
        // 名前が wsl の手元の WSL の machine は、語と同じ machine を指すので構わない
        let lines = hub_with_machines(true, &[machine("wsl", WSL_TARGET)]);
        let m = by_label(&lines, "hc の machine wsl");
        assert_eq!(
            (m.mark, m.detail.as_str()),
            (Mark::Ok, "connected (手元の WSL)")
        );
        // ただし一時の machine は --on wsl が選ばないので、名前が wsl なら名指しできないと出す
        let mut temp = machine("wsl", WSL_TARGET);
        temp["temporary"] = serde_json::json!(true);
        let lines = hub_with_machines(true, &[temp]);
        let m = by_label(&lines, "hc の machine wsl");
        assert_eq!(m.mark, Mark::Warn, "{m}");
        assert!(
            m.detail.starts_with(
                "connected (手元の WSL・一時の machine)。名前が pjp child new の --on の語 (wsl は手元の WSL) と同じ"
            ),
            "{m}"
        );
    }

    #[test]
    fn wsl_check_matches_pjp_child() {
        // pjp child new --on wsl (pjp-hc-child の hc::is_wsl_machine) と同じ見分け。片方だけ直すとここで落ちる
        for (target, via) in [
            (WSL_TARGET, true),
            ("WSL.EXE -d wsl1 -e sh -c", true),
            ("wsl -d Ubuntu -e sh -c", true),
            (r"C:\Windows\System32\wsl.exe -d wsl1 -e sh -c", true),
            (r#""C:\Program Files\WSL\wsl.exe" -d wsl1 -e sh -c"#, true),
            ("'/mnt/c/Windows/System32/wsl.exe' -d wsl1", true),
            ("  wsl.exe -d wsl1", true),
            ("wsl.exe -d wsl1", false),
            ("wsl", false),
            ("ssh -p 2222 host-a.local", true),
            ("wsl.example.com", true),
            ("my-wsl.exe-host", true),
            (r#""C:\Program Files\OpenSSH\ssh.exe" box"#, true),
            ("", true),
        ] {
            let m = serde_json::json!({"name": "m", "target": target, "via": via});
            assert_eq!(
                is_wsl(&m),
                pjp_hc_child::hc::is_wsl_machine(&m),
                "{target} (via {via})"
            );
        }
        // target・via の無い答え
        let bare = serde_json::json!({"name": "m"});
        assert_eq!(is_wsl(&bare), pjp_hc_child::hc::is_wsl_machine(&bare));
        // 足し方の文も同じ形
        assert_eq!(WSL_ADD, pjp_hc_child::child::WSL_ADD);
    }

    // ---- T3 Code の形 (T3 Code の spec §4.3) ----

    /// スレッドの id。T3 の MCP で立てたスレッドの id は `mcp:launch:<hex>` の形 (`:` を含む)。
    const THREAD: &str = "mcp:launch:27a4e44d";
    /// T3 の設定の env と、リンクのつなぐ先 (urls) に置く秘密の値。hello の出力に出さないことを見る。
    const SECRET: &str = "s3cr3t-value";
    /// T3 の CLI (env `T3CODE_CLI_PATH`) の偽のパス。
    const CLI: &str = "C:/Users/u/.t3/bin/t3.cmd";

    /// 試験の今 (2026-11-23T00:00:00Z)。
    fn now() -> Timestamp {
        time::parse_time("2026-11-23T00:00:00Z").unwrap()
    }

    /// `t3 environment list --json` の 1 件 (T3 v0.1.11 の形)。
    fn link(label: &str, status: &str, expires: &str, access: &str, error: Option<&str>) -> Value {
        serde_json::json!({
            "environmentId": format!("env-{label}"),
            "label": label,
            "urls": [format!("https://{label}.example:3773/?token={SECRET}")],
            "access": access,
            "linkedAt": "2026-11-22T06:06:54.611Z",
            "expiresAt": expires,
            "lastReachedAt": "2026-11-23T00:27:40.235Z",
            "lastError": error,
            "status": status
        })
    }

    /// 届く host-a (full-access。期限は今から 29 日と 6 時間ほど先)。
    fn host_a() -> Value {
        link(
            "host-a",
            "reachable",
            "2026-12-22T06:06:54.611Z",
            "full-access",
            None,
        )
    }

    fn links(items: &[Value]) -> Output {
        ok(&Value::Array(items.to_vec()).to_string())
    }

    /// T3 Code の会話 (HC_TERMINAL_ID が無く T3CODE_THREAD_ID と T3CODE_CLI_PATH がある)。T3 の CLI は `list` を答える。
    /// hc の machine の答えも置く。
    fn in_t3_with(list: Output) -> Fake {
        Fake {
            hc: true,
            env: HashMap::from([
                ("T3CODE_THREAD_ID".to_owned(), THREAD.to_owned()),
                ("T3CODE_CLI_PATH".to_owned(), CLI.to_owned()),
            ]),
            ..Fake::default()
        }
        .with("environment list --json", list)
        .with(
            "machine ls",
            ok(r#"{"machines":[{"name":"wsl1","state":"connected"}]}"#),
        )
    }

    /// T3 Code の会話で、リンク先は届く host-a だけ。
    fn in_t3() -> Fake {
        in_t3_with(links(&[host_a()]))
    }

    /// テストごとの偽のホーム (T3 だけの設定のファイルと、T3 の設定を置く)。Drop で消す。
    struct TempHome(PathBuf);

    impl TempHome {
        fn new(name: &str) -> TempHome {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let n = NEXT.fetch_add(1, Ordering::SeqCst);
            let dir = std::env::temp_dir().join(format!(
                "pjp-hc-hub-hello-{}-{n}-{name}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            TempHome(dir)
        }

        fn path(&self) -> &Path {
            &self.0
        }

        /// `rel` (`/` 区切り) に書く (親のディレクトリも作る)。
        fn write(&self, rel: &str, contents: &str) {
            let p = rel.split('/').fold(self.0.clone(), |p, c| p.join(c));
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, contents).unwrap();
        }

        /// T3 だけの設定のファイルを 2 つとも置く。
        fn t3_files(&self) {
            self.write(".claude/t3/settings.json", "{}\n");
            self.write(".claude/t3/CLAUDE.t3.md", "# T3\n");
        }

        /// T3 の設定に Launch arguments を書く。秘密の値の入った env も並べる (出さないことを見る)。
        fn launch_args(&self, args: &str) {
            let v = serde_json::json!({
                "providerInstances": {
                    "claudeAgent": {
                        "driver": "claudeAgent",
                        "environment": {"PJP_TEST_TOKEN": SECRET},
                        "config": {"homePath": "~/.claude-t3", "launchArgs": args}
                    }
                }
            });
            self.write(".t3/userdata/settings.json", &v.to_string());
        }
    }

    impl Drop for TempHome {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// T3 の行を、偽のホーム `home` で出す (Launch arguments の相対パスを解く cwd もそこ。今は [`now`])。どの行にも秘密の値を
    /// 出していないことを見る。
    fn t3(f: &Fake, home: &TempHome) -> Vec<Line> {
        let lines = t3_lines(f, THREAD, home.path(), home.path(), now());
        for l in &lines {
            assert!(!l.detail.contains(SECRET), "秘密の値を出した: {l}");
        }
        lines
    }

    /// T3 の設定の 2 行目 (Launch arguments)。
    fn args_line(f: &Fake, home: &TempHome) -> Line {
        let mut settings = t3(f, home).into_iter().filter(|l| l.label == "T3 の設定");
        settings.nth(1).expect("T3 の設定の 2 行目が無い")
    }

    #[test]
    fn form_follows_the_env() {
        let env = |pairs: &[(&str, &str)]| Fake {
            env: pairs
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
                .collect(),
            ..Fake::default()
        };
        assert_eq!(
            Form::detect(&env(&[("T3CODE_THREAD_ID", "th1")])),
            Form::T3 {
                thread: "th1".to_owned()
            }
        );
        // 両方あれば hc の形 (hc の端末の中の会話)。どちらも無ければ hc の形で、この端末が NG になる
        assert_eq!(
            Form::detect(&env(&[
                ("T3CODE_THREAD_ID", "th1"),
                ("HC_TERMINAL_ID", "t9")
            ])),
            Form::Hc
        );
        assert_eq!(Form::detect(&env(&[("HC_TERMINAL_ID", "t9")])), Form::Hc);
        assert_eq!(Form::detect(&env(&[])), Form::Hc);
    }

    #[test]
    fn t3_thread_replaces_the_terminal_lines() {
        let home = TempHome::new("thread");
        let f = in_t3();
        let lines = t3(&f, &home);
        let thread = by_label(&lines, "T3 のスレッド");
        assert_eq!(thread.mark, Mark::Ok);
        assert_eq!(thread.detail, THREAD);
        assert!(!f.ran("get "), "この端末を見た: {:?}", f.seen.borrow());
        let order: Vec<&str> = lines.iter().map(|l| l.label.as_str()).collect();
        assert_eq!(
            order,
            [
                "T3 のスレッド",
                "T3 のリンク host-a",
                "T3 の設定",
                "T3 の設定",
                "見回り役",
                "hc の machine wsl1"
            ]
        );
        assert_eq!(by_label(&lines, "hc の machine wsl1").mark, Mark::Ok);
    }

    #[test]
    fn hubd_is_not_started_in_t3() {
        let home = TempHome::new("hubd");
        let f = in_t3().with("run ", ok(r#"{"address":"t7"}"#));
        let lines = t3(&f, &home);
        let hubd = by_label(&lines, "見回り役");
        assert_eq!(hubd.mark, Mark::Skip, "{hubd}");
        assert!(hubd.detail.contains("Notion のコメント"), "{hubd}");
        assert!(!f.ran("run "), "立てた");
        assert!(
            !f.ran(&format!("ls --json --label {HUBD_LABEL}")),
            "見回り役を探した"
        );
    }

    #[test]
    fn links_come_from_the_t3_cli() {
        let home = TempHome::new("links");
        let wsl1 = link(
            "wsl1",
            "reachable",
            "2027-01-10T00:00:00Z",
            "full-access",
            None,
        );
        let f = in_t3_with(links(&[host_a(), wsl1]));
        let lines = t3(&f, &home);
        let l = by_label(&lines, "T3 のリンク host-a");
        assert_eq!(l.mark, Mark::Ok, "{l}");
        // 期限は日本時間の日付。残りは日に切り上げる (T3 の画面と同じ)
        assert_eq!(
            l.detail,
            "reachable (access full-access・期限 2026-12-22 まであと 30 日)"
        );
        assert_eq!(by_label(&lines, "T3 のリンク wsl1").mark, Mark::Ok);
        // env T3CODE_CLI_PATH の CLI を、引数 environment list --json で打つ
        assert_eq!(f.programs.borrow().first().map(String::as_str), Some(CLI));
        assert!(f.ran("environment list --json"), "{:?}", f.seen.borrow());
    }

    #[test]
    fn link_problems_are_warnings() {
        let later = "2026-12-22T06:06:54.611Z";
        for (l, want, relink) in [
            (
                link(
                    "host-a",
                    "unreachable",
                    later,
                    "full-access",
                    Some("connect ECONNREFUSED"),
                ),
                "unreachable。connect ECONNREFUSED",
                false,
            ),
            (
                link("host-a", "expired", later, "full-access", None),
                "期限切れ",
                true,
            ),
            // 期限を過ぎていれば、status が reachable でも期限切れ (T3 の画面と同じ)
            (
                link(
                    "host-a",
                    "reachable",
                    "2026-11-22T23:59:59Z",
                    "full-access",
                    None,
                ),
                "期限切れ",
                true,
            ),
            (
                link(
                    "host-a",
                    "reachable",
                    later,
                    "full-access",
                    Some("401 Unauthorized"),
                ),
                "エラーが出ている: 401 Unauthorized",
                false,
            ),
            // 残りが 5 日以下 (T3 の画面が「Expires in N days」を出す日数)
            (
                link(
                    "host-a",
                    "reachable",
                    "2026-11-28T00:00:00Z",
                    "full-access",
                    None,
                ),
                "期限 2026-11-28 まであと 5 日",
                true,
            ),
            // 子のスレッドは full-access のリンクに立てる
            (
                link("host-a", "reachable", later, "approval-required", None),
                "access が approval-required",
                true,
            ),
            (
                link("host-a", "checking", later, "full-access", None),
                "checking",
                false,
            ),
        ] {
            let home = TempHome::new("link-warn");
            let lines = t3(&in_t3_with(links(&[l])), &home);
            let line = by_label(&lines, "T3 のリンク host-a");
            assert_eq!(line.mark, Mark::Warn, "{line}");
            assert!(line.detail.contains(want), "{want}: {line}");
            assert_eq!(
                line.detail.contains("full-access の新しい pairing code"),
                relink,
                "{line}"
            );
        }
        // 5 日を 1 秒でも越えれば、6 日に切り上がって ok
        let home = TempHome::new("link-6days");
        let six = link(
            "host-a",
            "reachable",
            "2026-11-28T00:00:01Z",
            "full-access",
            None,
        );
        let lines = t3(&in_t3_with(links(&[six])), &home);
        let line = by_label(&lines, "T3 のリンク host-a");
        assert_eq!(line.mark, Mark::Ok, "{line}");
        assert!(line.detail.contains("あと 6 日"), "{line}");
    }

    #[test]
    fn links_missing_or_unreadable() {
        let home = TempHome::new("links-none");
        let lines = t3(&in_t3_with(links(&[])), &home);
        let line = by_label(&lines, "T3 のリンク");
        assert_eq!(line.mark, Mark::Warn, "{line}");
        assert!(line.detail.contains("リンク先が無い"), "{line}");
        // CLI が落ちた・読めない・返らない
        let timed_out = Output {
            code: None,
            stdout: String::new(),
            stderr: String::new(),
            timed_out: true,
        };
        for (out, want) in [
            (failed("server not running"), "server not running"),
            (ok(r#"{"environments":[]}"#), "読めません"),
            (ok("not json"), "読めません"),
            (timed_out, "返りません"),
        ] {
            let lines = t3(&in_t3_with(out), &home);
            let line = by_label(&lines, "T3 のリンク");
            assert_eq!(line.mark, Mark::Warn, "{line}");
            assert!(line.detail.contains(want), "{want}: {line}");
            assert!(line.detail.contains("t3_environment_links"), "{line}");
        }
        // env に T3CODE_CLI_PATH が無ければ見ない (CLI を打たない)
        let mut f = in_t3();
        f.env.remove("T3CODE_CLI_PATH");
        let lines = t3(&f, &home);
        let line = by_label(&lines, "T3 のリンク");
        assert_eq!(line.mark, Mark::Skip, "{line}");
        assert!(line.detail.contains("T3CODE_CLI_PATH"), "{line}");
        assert!(!f.ran("environment "), "{:?}", f.seen.borrow());
        assert!(lines.iter().all(|l| l.mark != Mark::Ng), "{lines:?}");
    }

    #[test]
    fn t3_without_hc_is_one_ng_line() {
        let home = TempHome::new("no-hc");
        let mut f = in_t3();
        f.hc = false;
        let lines = t3(&f, &home);
        assert_eq!(by_label(&lines, "T3 のスレッド").mark, Mark::Ok);
        // T3 のリンクは T3 の CLI で見るので、hc が無くても見る
        assert_eq!(by_label(&lines, "T3 のリンク host-a").mark, Mark::Ok);
        assert_eq!(by_label(&lines, "見回り役").mark, Mark::Skip);
        let hc = by_label(&lines, "hc");
        assert_eq!(hc.mark, Mark::Ng);
        assert!(hc.detail.contains("見張り"), "{hc}");
        assert!(hc.detail.contains("pjp ticket"), "{hc}");
        assert_eq!(
            lines.iter().filter(|l| l.mark == Mark::Ng).count(),
            1,
            "{lines:?}"
        );
        assert!(
            lines.iter().all(|l| !l.label.starts_with("hc の machine")),
            "{lines:?}"
        );
    }

    #[test]
    fn t3_hc_failures_are_warnings() {
        let home = TempHome::new("hc-fail");
        let f = Fake {
            hc: true,
            env: HashMap::from([("T3CODE_THREAD_ID".to_owned(), THREAD.to_owned())]),
            ..Fake::default()
        };
        let lines = t3(&f, &home);
        assert_eq!(by_label(&lines, "hc の machine").mark, Mark::Warn);
        assert!(lines.iter().all(|l| l.mark != Mark::Ng), "{lines:?}");
    }

    #[test]
    fn t3_files_missing_is_a_warning() {
        let home = TempHome::new("files");
        home.write(".claude/t3/settings.json", "{}\n");
        let f = in_t3();
        let lines = t3(&f, &home);
        let files = by_label(&lines, "T3 の設定");
        assert_eq!(files.mark, Mark::Warn, "{files}");
        assert!(files.detail.contains("CLAUDE.t3.md が無い"), "{files}");
        assert!(!files.detail.contains("settings.json"), "{files}");
        assert!(
            files.detail.contains("dotfiles apply --steps claude-t3"),
            "{files}"
        );
        home.t3_files();
        let lines = t3(&f, &home);
        assert_eq!(by_label(&lines, "T3 の設定").mark, Mark::Ok);
    }

    #[test]
    fn launch_args_must_name_both_files() {
        let home = TempHome::new("args");
        home.t3_files();
        let f = in_t3();
        let dir = home.path().join(".claude").join("t3");
        let settings = dir.join("settings.json").display().to_string();
        let prompt = dir.join("CLAUDE.t3.md").display().to_string();
        for (args, want) in [
            // ~ はホーム、= の形、引用符、ほかの引数があってもよい
            (
                "--settings ~/.claude/t3/settings.json --append-system-prompt-file ~/.claude/t3/CLAUDE.t3.md".to_owned(),
                Mark::Ok,
            ),
            (
                format!("--model opus --settings={settings} --append-system-prompt-file \"{prompt}\""),
                Mark::Ok,
            ),
            // 相対はスレッドの cwd から
            (
                "--settings .claude/t3/settings.json --append-system-prompt-file ./.claude/t3/x/../CLAUDE.t3.md".to_owned(),
                Mark::Ok,
            ),
            // 書いていない・片方だけ・別のファイル
            (String::new(), Mark::Warn),
            (format!("--settings {settings}"), Mark::Warn),
            (
                format!("--settings {settings} --append-system-prompt-file ~/other.md"),
                Mark::Warn,
            ),
        ] {
            home.launch_args(&args);
            let line = args_line(&f, &home);
            assert_eq!(line.mark, want, "{args}: {line}");
            if want == Mark::Ok {
                // 開き直して効くのは settings.json だけ。CLAUDE.t3.md は新しい会話から
                for part in ["会話を開き直すと効く", "新しい会話から効き", "次の compaction まで入らない"] {
                    assert!(line.detail.contains(part), "{part}: {line}");
                }
            }
            if want == Mark::Warn {
                // T3 Code を dotfiles で入れた PC は apply が書き (手順 t3-code-settings)、T3 Code を開き直す
                for part in [
                    "dotfiles apply --steps claude-t3,t3-code-settings",
                    "T3 Code を開き直す",
                ] {
                    assert!(line.detail.contains(part), "{part}: {line}");
                }
                // 入れていない PC は、今までどおり T3 の画面で書き、会話を開き直す
                for part in [
                    "Settings → Providers → Claude → Launch arguments",
                    "会話を開き直す",
                ] {
                    assert!(line.detail.contains(part), "{part}: {line}");
                }
                // CLAUDE.t3.md は開き直しても今ある会話には入らない (system prompt の記録)
                assert!(line.detail.contains("次の compaction まで入らない"), "{line}");
            }
        }
        // 片方だけなら、無い方だけを書く
        home.launch_args(&format!("--settings {settings}"));
        let line = args_line(&f, &home);
        assert!(
            line.detail.contains("--append-system-prompt-file"),
            "{line}"
        );
        assert!(!line.detail.contains("--settings"), "{line}");
        // config に launchArgs が無い (T3 で一度も書いていない) のも !!
        home.write(
            ".t3/userdata/settings.json",
            r#"{"providerInstances":{"claudeAgent":{"config":{"homePath":"x"}}}}"#,
        );
        assert_eq!(args_line(&f, &home).mark, Mark::Warn);
    }

    #[test]
    fn unreadable_t3_settings_are_skipped() {
        let home = TempHome::new("unreadable");
        home.t3_files();
        let f = in_t3();
        // ファイルが無い
        assert_eq!(args_line(&f, &home).mark, Mark::Skip);
        for text in [
            "not json",
            r#"{"providerInstances":{"codex":{}}}"#,
            r#"{"providerInstances":{"claudeAgent":{"config":{"launchArgs":3}}}}"#,
        ] {
            home.write(".t3/userdata/settings.json", text);
            let line = args_line(&f, &home);
            assert_eq!(line.mark, Mark::Skip, "{text}: {line}");
        }
    }

    #[test]
    fn launch_args_are_split_like_t3() {
        let some = |s: &str| Some(s.to_owned());
        let f = launch_arg_flags(
            r#"--model opus --settings "C:\Users\a b\s.json" --append-system-prompt-file=~/p.md"#,
        );
        assert_eq!(f.get("settings"), Some(&some(r"C:\Users\a b\s.json")));
        assert_eq!(f.get("append-system-prompt-file"), Some(&some("~/p.md")));
        assert_eq!(f.get("model"), Some(&some("opus")));
        // 引用符の外の \ は、空白と引用符の前でだけ次の字を写す (Windows のパスはそのまま)
        let f = launch_arg_flags(r"--settings C:\Users\a\ b\s.json");
        assert_eq!(f.get("settings"), Some(&some(r"C:\Users\a b\s.json")));
        // --append-system-prompt は、次が -- で始まっても値に取る (T3 の valueFlags)
        let f = launch_arg_flags("--append-system-prompt --settings x");
        assert_eq!(f.get("append-system-prompt"), Some(&some("--settings")));
        assert!(!f.contains_key("settings"), "{f:?}");
        // 値の無い flag・後の値が勝つ・-- から後ろは見ない
        let f = launch_arg_flags(
            "--verbose --settings a --settings b -- --append-system-prompt-file c",
        );
        assert_eq!(f.get("verbose"), Some(&None));
        assert_eq!(f.get("settings"), Some(&some("b")));
        assert!(!f.contains_key("append-system-prompt-file"), "{f:?}");
        // 一重引用符の中の \ と "、空の値
        let f = launch_arg_flags(r#"--settings 'C:\x\"y' --append-system-prompt-file """#);
        assert_eq!(f.get("settings"), Some(&some(r#"C:\x\"y"#)));
        assert_eq!(f.get("append-system-prompt-file"), Some(&some("")));
    }

    #[test]
    fn manifest_bins() {
        let text = "[package]\nname = \"x\"\n[[bin]]\nname = \"pjp-hub\"\npath = \"src/main.rs\"\n";
        assert!(manifest_has_bin(text, "pjp-hub"));
        assert!(!manifest_has_bin(text, "pjp-hubd"));
        assert!(!manifest_has_bin("not toml = =", "pjp-hub"));
        // この crate には、まだ見回り役の bin が無い (W2-3 で足すと true になる)
        assert!(!hubd_bin_here());
    }

    #[test]
    fn line_format() {
        assert_eq!(
            Line::new(Mark::Warn, "雛形", "差がある").to_string(),
            "!!  雛形: 差がある"
        );
    }
}
