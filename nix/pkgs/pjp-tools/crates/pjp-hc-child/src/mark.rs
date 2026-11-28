//! `pjp mark` (spec §7.3・§7.5・§8.4): 会話の端末に label の印を付け、会話の space の名前を替える (旧 herdr の `ws-mark.sh` の
//! hc 版)。印を絵にするのは herdr-app の mod pjp-spaces (`skills/pjp-hc-hub/herdr-app/mods/pjp-spaces/`。space の行の 2 行目と、
//! 解説動画は 3 行目から 1 本 1 行)。
//! pjp-spaces の入っていない herdr-app では、Agents 欄と space の名前で見る。
//!
//! ```text
//! pjp mark name '<名前>'                                   この会話の space の名前を替え、pjp.ticket・pjp.role=hub を付ける
//! pjp mark asking '<問いの要旨>' [--terminal <t>]          pjp.asking=<要旨> を付け、pjp.asked を外す (ハブが文で問いを出して
//!                                                          ターンを終える直前)
//! pjp mark answered [--terminal <t>]                       pjp.asking と pjp.asked を外す (問いが済んだら)
//! pjp mark finished [--terminal <t> | --checkout <パス>]   pjp.finished=<日時> を付ける (pjp ticket が Done・Canceled で打つ)
//! pjp mark unfinished [--terminal <t> | --checkout <パス>] pjp.finished を外す
//! pjp mark show [<t>]                                      端末の印 (と、その端末と子孫の解説動画の印) を出す
//! pjp mark video start|done|stop|watched …                 解説動画を作っている間・見ていない間の印 (mark/video.rs)
//! pjp mark hook prompt|stop                                Claude Code の UserPromptSubmit・Stop の hook (mark/hook.rs)
//! ```
//!
//! pjp-spaces は、pjp.asking のある会話と、status が blocked (確認の画面)・error の会話の印の先頭に ❓ を出す。status の done
//! だけでは出さない (文で問いを書いてターンを終えた会話も、子の報告を待つ会話も done で、見分けられない。spec §7.5)。
//! 答えが届くと、ハブの雛形の hook (`pjp mark hook prompt`) が pjp.asking を外して要旨を pjp.asked に移し、ターンの終わりに
//! `pjp mark hook stop` が後始末 (answered か asking) を確かめさせる (spec `2026-11-19-hub-asking-hook-design.md`)。
//!
//! space の名前は、herdr-app があれば `herdr-app do space.rename` で替える (Windows のハブ)。herdr-app の無いマシン (SSH 先や WSL の
//! Linux のハブ) では、このマシンの hc の core の doc `herdr-app` (herdr-app がマシンごとの space を置く) の space の name を
//! `doc.get`・`doc.set` (`hc connect`) で書き替え、herdr-app が doc の event を読んで描き直す ([`appdoc::rename`])。

use std::io::Write;
use std::path::Path;

use pjp_core::process::Cmd;
use pjp_core::{Error, Result, exit, paths};
use serde_json::{Value, json};

use crate::appdoc::{self, APP_DOC, Rename};
use crate::args::{self, Spec};
use crate::hc::{Hc, HerdrApp, Runner, label_of, split_addr};

const USAGE: &str = "\
pjp mark — 会話の端末の label の印と、会話の space の名前 (旧 herdr の ws-mark.sh の hc 版)

使い方:
  pjp mark name '<名前>'                                    この会話の space の名前を替え、この端末に pjp.ticket (名前の頭の
                                                            チケットの ID) と pjp.role=hub (ハブの中のとき) を付ける
  pjp mark asking '<問いの要旨>' [--terminal <t>]           ユーザーの答えを待つ印 pjp.asking=<要旨> を付ける (打ち直すと要旨
                                                            を替える。pjp.asked は外す)。pjp-spaces が会話の印の先頭に ❓ を出す
  pjp mark answered [--terminal <t>]                        答えを待つ印 pjp.asking と、答えが届いた問いの控え pjp.asked を
                                                            外す (無ければ何もしない)
  pjp mark finished [--terminal <t> | --checkout <パス>]    済んだ印 pjp.finished=<日時> を付ける (打ち直しても日時は替えない)
  pjp mark unfinished [--terminal <t> | --checkout <パス>]  済んだ印を外す
  pjp mark show [<t>]                                       端末の印 (pjp.*・herdr.*)・親・状態と、その端末と子孫の
                                                            解説動画の印を出す
  pjp mark video start '<名前>' [--terminal <t>]            解説動画を作っている印 pjp.video.<id> を付ける (pjp-spaces が
                                                            🎬⏳:<名前> の行を出す。動画の skill が作り始めに打つ)
  pjp mark video done ['<名前>'] [--terminal <t>]           作っている印を済んだ印 (🎬✅。まだ見ていない) にする
  pjp mark video stop ['<名前>'] [--all] [--terminal <t>]   作りかけの印を外す (止めた・止まった)
  pjp mark video watched ['<名前>'] [--all] [--terminal <t>]
                                                            見た動画の印を、この端末と子孫から探して外す (細部は
                                                            pjp mark video --help)
  pjp mark hook prompt                                      Claude Code の UserPromptSubmit の hook。ユーザーの発言が届いたら
                                                            pjp.asking を外して要旨を pjp.asked に移し、文脈で知らせる
  pjp mark hook stop                                        Claude Code の Stop の hook。pjp.asked が残っていれば 1 回だけ
                                                            ターンを続けさせ、answered か asking を打たせる (2 回目は外す)

端末を省くとこの端末 ($HC_TERMINAL_ID)。--checkout はこのマシンの端末のうち、cwd がそのパスの下のもの全部。
名前は '<主題>' (ハブ。チケットがあれば 'TKT-n <主題>' と ID を頭に) の形。印 (❓・🌱・🌳・🔄・👀・🗑️・🎬) で始めない。
子の端末・repo の checkout・repo の外の space の名前は替えない (子の名前は親が付け、checkout の space はほかの会話も使う)。
済んだ印は worktree の会話にだけ付ける。
space の名前は、herdr-app があれば herdr-app do space.rename で替える。herdr-app の無いマシン (Linux のハブ) では、このマシンの
hc の doc herdr-app (herdr-app が space を置く) の、この端末の herdr.space の space の name だけを書き替え (hc connect の doc.get・
doc.set。版が合わなければ読み直して打ち直す)、herdr-app がそれを読んで描き直す。doc か space が無い・hc が答えないときは note を
出して名前は替えない (label は付ける。終了コード 0)。
asking は、ユーザーに直に問いを出す会話 (ハブ) が、文で問いを出してターンを終える直前に打つ。答えが届くと (panel からでも
端末でも。足し分があれば Notion のコメントでも)、ハブの雛形の hook (hook prompt) が外して要旨を pjp.asked に移す。答えを読み、問いが済んだら
answered、まだ答えを待つ問いを出してターンを終えるなら asking を打つ (打たずに終えると hook stop が 1 回確かめさせる。hook の
無い worktree では、答えが届いたら answered を打つ)。要旨は 1 行で短く (pjp-spaces のホバーでは 60 字で切れる)。- で始まる
要旨は pjp mark asking -- '<要旨>' と渡す。子は親 (指揮役) に聞くので打たない。確認の画面 (blocked)・エラー (error) の ❓ は
pjp-spaces が status から出すので打たない。
hook は stdin の JSON を読み、どんな失敗でも終了コード 0 で終える (失敗は stderr。ハブの .claude/settings.json が
'pjp mark hook prompt; exit 0' の形で登録する)。子の報告 (<hc from=…>)・裏の作業の知らせ (<task-notification>) では外さない。
";

/// 名前の頭に置かない印 (pjp-spaces と旧 herdr の印。名前と見分けがつかなくなる)。
const MARKS: [char; 7] = ['❓', '🌱', '🌳', '🔄', '👀', '🗑', '🎬'];

/// 端末の印の label の名前 (spec §7.5)。
pub const LABEL_ROLE: &str = "pjp.role";
pub const LABEL_TICKET: &str = "pjp.ticket";
pub const LABEL_LETTER: &str = "pjp.letter";
pub const LABEL_FINISHED: &str = "pjp.finished";
pub const LABEL_ASKING: &str = "pjp.asking";
/// 答えが届いた問いの要旨 (spec `2026-11-19-hub-asking-hook-design.md` の §4.1)。答えが届くと hook (`pjp mark hook prompt`) が
/// pjp.asking から移し、asking・answered と、ターンの終わりの hook (`pjp mark hook stop`) が外す。pjp-spaces は読まない。
pub const LABEL_ASKED: &str = "pjp.asked";

/// pjp-spaces がホバーに出す問いの要旨の字数 (main.js の ASK_MAX と同じ)。これより長い要旨には note を出す。
const ASKING_TIP_MAX: usize = 60;

/// `pjp mark …` (args は道具の名前を除いたもの)。終了コードを返す。
pub fn main(r: &dyn Runner, args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> u8 {
    let result = run(r, args, out, err);
    exit::report("pjp mark", result, err)
}

fn run(r: &dyn Runner, args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> Result<u8> {
    let Some((sub, rest)) = args.split_first() else {
        let _ = write!(err, "{USAGE}");
        return Ok(exit::CONFIG);
    };
    if sub == "-h" || sub == "--help" {
        let _ = write!(out, "{USAGE}");
        return Ok(exit::OK);
    }
    if sub == "hook" {
        // Claude Code の hook。どんな失敗でも 0 で終える (hc が無いのも、hook の中で stderr に出して 0)
        return Ok(hook::run(r, rest, out, err));
    }
    if sub == "video" {
        // 解説動画の印。hc の端末の外では何もせず 0 で終える (動画の skill の手順を落とさない)
        return video::run(r, rest, out, err);
    }
    let spec = match sub.as_str() {
        "name" | "show" => Spec::default(),
        // 問いを出すのは 1 つの会話なので、--checkout (その下の端末全部) は受けない
        "asking" | "answered" => Spec {
            flags: &[],
            values: &["--terminal"],
        },
        "finished" | "unfinished" => Spec {
            flags: &[],
            values: &["--terminal", "--checkout"],
        },
        _ => {
            return Err(Error::config(format!(
                "知らないサブコマンドです: {sub} (name・asking・answered・finished・unfinished・show・video・hook)"
            )));
        }
    };
    let p = args::parse(rest, &spec)?;
    if p.help() {
        let _ = write!(out, "{USAGE}");
        return Ok(exit::OK);
    }
    let hc = Hc::new(r);
    hc.require()?;
    match sub.as_str() {
        "name" => {
            let [name] = p.positionals.as_slice() else {
                return Err(Error::config(
                    "名前を 1 つ渡す (pjp mark name '<主題>'。チケットがあれば 'TKT-n <主題>')",
                ));
            };
            name_cmd(r, &hc, name, out, err)
        }
        "show" => {
            let target = match p.positionals.as_slice() {
                [] => this_id(r)?,
                [t] => t.clone(),
                _ => return Err(Error::config("端末は 1 つだけ渡す")),
            };
            show(&hc, &target, out)
        }
        "asking" => {
            let [summary] = p.positionals.as_slice() else {
                return Err(Error::config(
                    "問いの要旨を 1 つ渡す (pjp mark asking '<問いの要旨>')",
                ));
            };
            let summary = check_summary(summary)?;
            let target = match p.value("--terminal")? {
                Some(t) => t.to_owned(),
                None => this_id(r)?,
            };
            set_asking(&hc, &target, summary, out, err)
        }
        "answered" => {
            if !p.positionals.is_empty() {
                return Err(Error::config(format!(
                    "余分な引数です: {}",
                    p.positionals.join(" ")
                )));
            }
            let target = match p.value("--terminal")? {
                Some(t) => t.to_owned(),
                None => this_id(r)?,
            };
            unset_asking(&hc, &target, out)
        }
        _ => {
            if !p.positionals.is_empty() {
                return Err(Error::config(format!(
                    "余分な引数です: {}",
                    p.positionals.join(" ")
                )));
            }
            let targets = targets(r, &hc, p.value("--terminal")?, p.value("--checkout")?)?;
            let finished = sub == "finished";
            for t in targets {
                if finished {
                    set_finished(r, &hc, &t, out)?;
                } else {
                    unset_finished(&hc, &t, out)?;
                }
            }
            Ok(exit::OK)
        }
    }
}

fn this_id(r: &dyn Runner) -> Result<String> {
    r.env("HC_TERMINAL_ID").ok_or_else(|| {
        Error::config("hc の端末の外です (HC_TERMINAL_ID が無い。--terminal で渡す)")
    })
}

/// 名前の頭のチケットの ID (`TKT-n`・`WRK-TKT-n` の形。英大文字と数字の組を `-` でつなぎ、`-` と数字で終わる)。
pub fn ticket_of(name: &str) -> Option<&str> {
    let head = name.split(char::is_whitespace).next()?;
    let (prefix, num) = head.rsplit_once('-')?;
    let prefix_ok = !prefix.is_empty()
        && prefix.split('-').all(|part| {
            part.chars().next().is_some_and(|c| c.is_ascii_uppercase())
                && part
                    .chars()
                    .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        });
    (prefix_ok && !num.is_empty() && num.chars().all(|c| c.is_ascii_digit())).then_some(head)
}

/// 名前を確かめる (空・制御文字・印で始まる名前を断る)。
fn check_name(name: &str) -> Result<()> {
    if name.trim().is_empty() {
        return Err(Error::config("名前が空です"));
    }
    if name.chars().any(char::is_control) {
        return Err(Error::config("名前に改行などの制御文字を入れない"));
    }
    if name.trim_start().starts_with(MARKS) {
        return Err(Error::config(format!(
            "名前を印 ({}) で始めない (印は label で付ける)",
            MARKS
                .iter()
                .map(char::to_string)
                .collect::<Vec<_>>()
                .join("・")
        )));
    }
    Ok(())
}

/// git を打って stdout を返す (落ちたら None)。
fn git_out(r: &dyn Runner, dir: &Path, args: &[&str]) -> Option<String> {
    let cmd = Cmd::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .timeout(std::time::Duration::from_secs(30));
    r.run(&cmd).ok().filter(|o| o.success()).map(|o| o.stdout)
}

/// `dir` が repo の linked worktree か (`--git-dir` と `--git-common-dir` が違う)。repo の外・main の checkout は false。
fn is_linked_worktree(r: &dyn Runner, dir: &Path) -> bool {
    let Some(text) = git_out(
        r,
        dir,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-dir",
            "--git-common-dir",
        ],
    ) else {
        return false;
    };
    let lines: Vec<&str> = text.lines().map(str::trim).collect();
    matches!(lines.as_slice(), [a, b] if !paths::same_path(a, b, cfg!(windows)))
}

/// `dir` が集約ハブ (origin が無く、`pjp.devtracker.repo` を持つ local の repo。`~/h` とその worktree) の中か。
fn is_hub(r: &dyn Runner, dir: &Path) -> bool {
    let has_repo_name = git_out(r, dir, &["config", "--get", "pjp.devtracker.repo"])
        .is_some_and(|v| !v.trim().is_empty());
    let has_origin =
        git_out(r, dir, &["remote"]).is_some_and(|v| v.lines().any(|l| l.trim() == "origin"));
    has_repo_name && !has_origin
}

fn name_cmd(
    r: &dyn Runner,
    hc: &Hc<'_>,
    name: &str,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    check_name(name)?;
    let id = this_id(r)?;
    let term = hc
        .get(&id)?
        .ok_or_else(|| Error::failure(format!("hc にこの端末 ({id}) がありません")))?;
    let cwd = r.cwd()?;
    let child = label_of(&term, LABEL_ROLE) == Some("child");
    let hub = !child && is_hub(r, &cwd);

    // label (この会話のチケット・ハブの印)
    let mut pairs = Vec::new();
    if let Some(ticket) = ticket_of(name)
        && label_of(&term, LABEL_TICKET) != Some(ticket)
    {
        pairs.push(format!("{LABEL_TICKET}={ticket}"));
    }
    if hub && label_of(&term, LABEL_ROLE) != Some("hub") {
        pairs.push(format!("{LABEL_ROLE}=hub"));
    }
    if !pairs.is_empty() {
        hc.label(&id, &pairs)?;
        let _ = writeln!(out, "{id}: label {} を付けた", pairs.join(" "));
    }
    // チケットが決まる前に、この端末の住所で控えた子がいれば、チケットの控えへ移す (英字を使い回さない)
    if let Some(ticket) = ticket_of(name)
        && let Some(msg) = crate::ledger::adopt(
            &r.state_dir()?.join("children"),
            &crate::ledger::terminal_key(&id),
            ticket,
        )?
    {
        let _ = writeln!(out, "{id}: {msg}");
    }

    // space の名前
    let skip = if child {
        Some("子の space の名前は親が付けたもの")
    } else if label_of(&term, "herdr.space").is_none() {
        Some("この端末は herdr-app の space に入っていない")
    } else if !is_linked_worktree(r, &cwd) {
        Some("repo の checkout・repo の外の space は、ほかの会話も使うので名前を替えない")
    } else {
        None
    };
    if let Some(why) = skip {
        let _ = writeln!(out, "{id}: space の名前は替えない ({why})");
        return Ok(exit::OK);
    }
    let space = label_of(&term, "herdr.space").unwrap_or_default();
    let app = HerdrApp::new(r);
    if !app.available() {
        // herdr-app の無いマシン (Linux のハブ): このマシンの hc の doc を書き替え、herdr-app (Windows) が付いてくる
        match appdoc::rename(r, hc, None, space, name) {
            Rename::Renamed { from, to } => {
                let _ = writeln!(
                    out,
                    "{id}: space {space} の名前を {name} にした (hc の doc {APP_DOC} を書いた。版 {from} → {to})"
                );
            }
            Rename::Same => {
                let _ = writeln!(
                    out,
                    "{id}: space {space} の名前はもう {name} (hc の doc {APP_DOC} は書き替えない)"
                );
            }
            Rename::Skip(line) => {
                let _ = writeln!(err, "note: {line}");
            }
            Rename::Failed(why) => {
                let _ = writeln!(
                    err,
                    "!! space {space} の名前を替えられない (hc の doc {APP_DOC}: {why})"
                );
            }
        }
        return Ok(exit::OK);
    }
    match app.run("space.rename", &json!({"id": space, "name": name})) {
        Ok(_) => {
            let _ = writeln!(out, "{id}: space {space} の名前を {name} にした");
        }
        Err(e) => {
            let _ = writeln!(err, "!! space {space} の名前を替えられない ({e})");
        }
    }
    Ok(exit::OK)
}

/// 印を付ける端末: `--terminal` → `--checkout` (このマシンの端末で cwd がその下) → この端末。
fn targets(
    r: &dyn Runner,
    hc: &Hc<'_>,
    terminal: Option<&str>,
    checkout: Option<&str>,
) -> Result<Vec<String>> {
    match (terminal, checkout) {
        (Some(t), None) => Ok(vec![t.to_owned()]),
        (None, Some(dir)) => {
            let win = cfg!(windows);
            let want = paths::normalize_for_compare(dir, win);
            // 当たる端末が無いのは、会話を閉じた後なら当たり前 (何もしない)
            Ok(hc
                .ls(false)?
                .iter()
                .filter(|t| {
                    t["address"]
                        .as_str()
                        .is_some_and(|a| split_addr(a).0.is_none())
                })
                .filter(|t| {
                    t["cwd"].as_str().is_some_and(|c| {
                        let c = paths::normalize_for_compare(c, win);
                        c == want || c.starts_with(&format!("{want}/"))
                    })
                })
                .filter_map(|t| t["address"].as_str().map(str::to_owned))
                .collect())
        }
        (None, None) => Ok(vec![this_id(r)?]),
        (Some(_), Some(_)) => Err(Error::config("--terminal と --checkout はどちらか 1 つ")),
    }
}

/// 端末の今の cwd (`foreground.cwd`、無ければ立てたときの cwd)。
fn cwd_of(term: &Value) -> Option<&str> {
    term["foreground"]["cwd"]
        .as_str()
        .or_else(|| term["cwd"].as_str())
        .filter(|s| !s.is_empty())
}

fn set_finished(r: &dyn Runner, hc: &Hc<'_>, target: &str, out: &mut dyn Write) -> Result<()> {
    let Some(term) = hc.get(target)? else {
        let _ = writeln!(out, "{target}: hc に端末が無い (何もしない)");
        return Ok(());
    };
    if let Some(at) = label_of(&term, LABEL_FINISHED) {
        let _ = writeln!(
            out,
            "{target}: もう済んだと控えてある ({LABEL_FINISHED}={at})"
        );
        return Ok(());
    }
    // このマシンの端末なら、worktree の会話かを確かめる (checkout の会話に 🗑️ を出さない)
    if split_addr(target).0.is_none()
        && let Some(cwd) = cwd_of(&term)
        && !is_linked_worktree(r, Path::new(cwd))
    {
        let _ = writeln!(
            out,
            "{target}: worktree の会話ではない ({cwd}) ので、済んだ印は付けない (repo の checkout はほかの会話も使う)"
        );
        return Ok(());
    }
    let at = r.now()?.to_jst().iso_minutes();
    hc.label(target, &[format!("{LABEL_FINISHED}={at}")])?;
    let _ = writeln!(out, "{target}: 済んだと控えた ({LABEL_FINISHED}={at})");
    Ok(())
}

/// hc の端末 `target` の済んだ印を合わせる (spec §8.4)。`finished` なら `pjp mark finished --terminal <target>`、でなければ
/// `unfinished` と同じ (日時の形・worktree の会話にだけ付ける・打ち直しても日時を替えない)。hc が無い・答えないときは Err (呼ぶ側が
/// 注意を 1 行にする)。足し分の `pjp ticket` は、この関数でなく `pjp mark finished|unfinished --terminal` を子の process で打つ
/// (dotfiles-private の ADR 124)。
pub fn tell(r: &dyn Runner, target: &str, finished: bool, out: &mut dyn Write) -> Result<()> {
    let hc = Hc::new(r);
    hc.require()?;
    if finished {
        set_finished(r, &hc, target, out)
    } else {
        unset_finished(&hc, target, out)
    }
}

fn unset_finished(hc: &Hc<'_>, target: &str, out: &mut dyn Write) -> Result<()> {
    let Some(term) = hc.get(target)? else {
        return Ok(());
    };
    if label_of(&term, LABEL_FINISHED).is_some() {
        hc.label(target, &[format!("{LABEL_FINISHED}=")])?;
        let _ = writeln!(out, "{target}: 済んだの控えを消した");
    }
    Ok(())
}

/// 問いの要旨を確かめる (空・空白だけ・改行やタブなどの制御文字を断る)。前後の空白を除いて返す。
/// hc の label は改行も空白だけの値もそのまま持つが、pjp-spaces のホバーの説明は 1 会話 1 行にする。
fn check_summary(summary: &str) -> Result<&str> {
    let s = summary.trim();
    if s.is_empty() {
        return Err(Error::config("問いの要旨が空です"));
    }
    if s.chars().any(char::is_control) {
        return Err(Error::config(
            "問いの要旨は 1 行で書く (改行やタブなどの制御文字を入れない)",
        ));
    }
    Ok(s)
}

/// 答えを待つ印 (pjp.asking) を付ける。同じ要旨なら打たず、違えば替える。答えが届いた問いの控え (pjp.asked) があれば、同じ
/// 1 回の hc label で外す (新しい問いを出したなら、前の答えの後始末は済んでいる)。端末が無ければ失敗 (問いの印が付かないまま
/// ターンを終えないように)。
fn set_asking(
    hc: &Hc<'_>,
    target: &str,
    summary: &str,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let term = hc
        .get(target)?
        .ok_or_else(|| Error::failure(format!("hc に端末 {target} がありません")))?;
    let old = label_of(&term, LABEL_ASKING)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let asked = label_of(&term, LABEL_ASKED);
    let mut pairs = Vec::new();
    if old != Some(summary) {
        pairs.push(format!("{LABEL_ASKING}={summary}"));
    }
    if asked.is_some() {
        pairs.push(format!("{LABEL_ASKED}="));
    }
    if !pairs.is_empty() {
        hc.label(target, &pairs)?;
    }
    if old == Some(summary) {
        let _ = writeln!(
            out,
            "{target}: もう同じ問いで控えてある ({LABEL_ASKING}={summary})"
        );
    } else {
        let _ = match old {
            Some(old) => writeln!(
                out,
                "{target}: 答えを待つ印の要旨を替えた ({LABEL_ASKING}={summary}。前は {old})"
            ),
            None => writeln!(
                out,
                "{target}: 答えを待つ印を付けた ({LABEL_ASKING}={summary})"
            ),
        };
    }
    if let Some(asked) = asked {
        let _ = writeln!(
            out,
            "{target}: 答えが届いた問いの控えを外した ({LABEL_ASKED}={asked})"
        );
    }
    match label_of(&term, LABEL_ROLE) {
        // pjp-spaces が 2 行目を出すのは会話の端末 (pjp.role が hub・child か、子のいる端末) だけ
        None => {
            let _ = writeln!(
                err,
                "note: {target} には {LABEL_ROLE} が無い。子のいない端末には pjp-spaces が ❓ を出さない (ハブの会話なら pjp mark name で付く)"
            );
        }
        Some("child") => {
            let _ = writeln!(
                err,
                "note: {target} は子の会話 ({LABEL_ROLE}=child)。子は親 (指揮役) に聞くので、ふつうは打たない"
            );
        }
        Some(_) => {}
    }
    let n = summary.chars().count();
    if n > ASKING_TIP_MAX {
        let _ = writeln!(
            err,
            "note: 要旨が長い ({n} 字)。pjp-spaces のホバーでは {ASKING_TIP_MAX} 字で切れる (1 行で短く書く)"
        );
    }
    Ok(exit::OK)
}

/// 答えを待つ印 (pjp.asking) と、答えが届いた問いの控え (pjp.asked) を、ある方だけ 1 回の hc label で外す。どちらも端末も
/// 無ければ何もしない (問いを出さずに答えを受けたときも打ってよい)。
fn unset_asking(hc: &Hc<'_>, target: &str, out: &mut dyn Write) -> Result<u8> {
    let Some(term) = hc.get(target)? else {
        return Ok(exit::OK);
    };
    let asking = label_of(&term, LABEL_ASKING);
    let asked = label_of(&term, LABEL_ASKED);
    let pairs: Vec<String> = [(LABEL_ASKING, asking), (LABEL_ASKED, asked)]
        .iter()
        .filter(|(_, v)| v.is_some())
        .map(|(k, _)| format!("{k}="))
        .collect();
    if pairs.is_empty() {
        return Ok(exit::OK);
    }
    hc.label(target, &pairs)?;
    if let Some(old) = asking {
        let _ = writeln!(out, "{target}: 答えを待つ印を外した ({LABEL_ASKING}={old})");
    }
    if let Some(old) = asked {
        let _ = writeln!(
            out,
            "{target}: 答えが届いた問いの控えを外した ({LABEL_ASKED}={old})"
        );
    }
    Ok(exit::OK)
}

fn show(hc: &Hc<'_>, target: &str, out: &mut dyn Write) -> Result<u8> {
    let term = hc
        .get(target)?
        .ok_or_else(|| Error::failure(format!("hc に端末 {target} がありません")))?;
    let name = term["name"].as_str().unwrap_or("-");
    let _ = writeln!(out, "{target} (名前 {name})");
    for key in [
        LABEL_ROLE,
        LABEL_TICKET,
        LABEL_LETTER,
        LABEL_FINISHED,
        LABEL_ASKING,
        LABEL_ASKED,
        "herdr.space",
        "herdr.tab",
    ] {
        let _ = writeln!(out, "  {key}: {}", label_of(&term, key).unwrap_or("-"));
    }
    let _ = writeln!(out, "  親: {}", term["parent"].as_str().unwrap_or("-"));
    let state = crate::hc::state_of(&term).unwrap_or("報告なし");
    let _ = writeln!(out, "  状態: {state}");
    if let Some(cwd) = cwd_of(&term) {
        let _ = writeln!(out, "  cwd: {cwd}");
    }
    for line in video::show_lines(hc, target) {
        let _ = writeln!(out, "{line}");
    }
    Ok(exit::OK)
}

mod hook;
pub mod video;

#[cfg(test)]
mod tests;
