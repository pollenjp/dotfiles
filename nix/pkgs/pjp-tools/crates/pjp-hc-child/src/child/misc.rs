//! `pjp child ls`・`send`・`read`・`report` (spec §7.6・§7.7)。

use std::io::Write;

use pjp_core::{Error, Result, exit};
use serde_json::Value;

use super::agent::{Agent, agent_of};
use super::{
    ChildTerm, check_cmdline, child_terminal, find_child, help, open_ledger, read_text_file,
    status_word,
};
use crate::ledger::Row;

/// 控えの子の端末が、今も hc にいる控えの子か (住所が別の端末に振り直されていたら触らない)。控えの子なら `hc get` の答え。
fn ours(hc: &Hc<'_>, row: &Row) -> Result<Value> {
    match child_terminal(hc, row)? {
        ChildTerm::Ours(term) => Ok(term),
        ChildTerm::Missing => Err(Error::failure(format!(
            "子 {} の端末 {} は hc にいません (終わって消えた。立て直すなら pjp child restart {})",
            row.letter,
            if row.terminal.is_empty() {
                "-"
            } else {
                &row.terminal
            },
            row.letter
        ))),
        ChildTerm::Other(why) => Err(Error::failure(format!(
            "子 {} の端末は別の端末になっている ({why})。触らない",
            row.letter
        ))),
    }
}
use crate::args::{self, Spec};
use crate::hc::{Hc, Runner, label_of};

/// 送る前の守りを外す flag (相手で Claude が動いているかを確かめずに送る)。
const NO_AGENT_CHECK: &str = "--no-agent-check";

/// 子の端末で Claude が動いているかを確かめる。動いていない・見分けられないなら、送らずに失敗にする。
fn guard_child(term: &Value, row: &Row) -> Result<()> {
    let (l, t) = (&row.letter, &row.terminal);
    match agent_of(term) {
        Agent::Running => Ok(()),
        Agent::Finished(code) => Err(Error::failure(format!(
            "子 {l} ({t}) の端末は終わっている (終了コード {code}) ので送らない\n  \
             立て直すなら pjp child restart {l} (前の会話の続きから)"
        ))),
        Agent::Other(name) => Err(Error::failure(format!(
            "子 {l} ({t}) で Claude が動いていないので送らない: 前面のプロセスが {name} で、状態の報告 (OSC 7501) が無い。\
             送ると {name} に文が打たれる (shell なら 1 行ずつコマンドとして動く)\n  \
             立て直すなら pjp child restart {l} (前の会話の続きから。画面は pjp child read {l} --lines 0)。\
             わざと送るなら {NO_AGENT_CHECK}"
        ))),
        Agent::Unknown(why) => Err(Error::failure(format!(
            "子 {l} ({t}) で Claude が動いているか確かめられないので送らない: {why}\n  \
             pjp child read {l} --lines 0 で画面を読み、Claude が動いていれば {NO_AGENT_CHECK} を付けて送り直す \
             (shell なら pjp child restart {l})"
        ))),
    }
}

/// 親の端末で Claude が動いているかを確かめる。動いていない・見分けられないなら、知らせずに失敗にする。
fn guard_parent(term: &Value, parent: &str) -> Result<()> {
    match agent_of(term) {
        Agent::Running => Ok(()),
        Agent::Finished(code) => Err(Error::failure(format!(
            "親 ({parent}) の端末は終わっている (終了コード {code}) ので知らせない\n  \
             知らせることは最後の発言に書いて止まる"
        ))),
        Agent::Other(name) => Err(Error::failure(format!(
            "親 ({parent}) で Claude が動いていないので知らせない: 前面のプロセスが {name} で、状態の報告 (OSC 7501) が無い。\
             送ると {name} に文が打たれる (shell なら 1 行ずつコマンドとして動く)\n  \
             知らせることは最後の発言に書いて止まる (親の会話が戻れば画面で読める)。わざと送るなら {NO_AGENT_CHECK}"
        ))),
        Agent::Unknown(why) => Err(Error::failure(format!(
            "親 ({parent}) で Claude が動いているか確かめられないので知らせない: {why}\n  \
             hc read {parent} --lines 0 で画面を読み、Claude が動いていれば {NO_AGENT_CHECK} を付けて打ち直す"
        ))),
    }
}

/// `pjp child ls` の状態の欄。Claude が終わって shell に替わった端末は、そうと出す (「報告なし」では気づきにくい)。
fn ls_status(term: &Value) -> String {
    match agent_of(term) {
        Agent::Other(name) => format!("Claude が動いていない (前面 {name})"),
        _ => status_word(term),
    }
}

pub fn ls(r: &dyn Runner, args: &[String], out: &mut dyn Write) -> Result<u8> {
    let p = args::parse(
        args,
        &Spec {
            flags: &["--all"],
            values: &["--ticket"],
        },
    )?;
    if help(&p, out) {
        return Ok(exit::OK);
    }
    if !p.positionals.is_empty() {
        return Err(Error::config(format!(
            "余分な引数です: {}",
            p.positionals.join(" ")
        )));
    }
    let hc = Hc::new(r);
    hc.require()?;
    let (ledger, key) = open_ledger(r, &hc, p.value("--ticket")?)?;
    let rows = ledger.rows()?;
    let _ = writeln!(
        out,
        "子 (親のチケット {key}。控え: {})",
        ledger.path().display()
    );
    let mut shown = 0;
    for row in &rows {
        if row.cleaned() && !p.flag("--all") {
            continue;
        }
        shown += 1;
        let (status, ticket) = if row.cleaned() {
            ("片付けた".to_owned(), "-".to_owned())
        } else if row.terminal.is_empty() {
            (format!("立っていない ({})", row.state), "-".to_owned())
        } else {
            match hc.get(&row.terminal)? {
                Some(t) => (
                    ls_status(&t),
                    label_of(&t, "pjp.ticket").unwrap_or("-").to_owned(),
                ),
                None => ("見つからない (終わって消えた)".to_owned(), "-".to_owned()),
            }
        };
        let what = if row.repo.is_empty() {
            &row.worktree
        } else {
            &row.repo
        };
        let account = super::account::ls_suffix(&row.account);
        let _ = writeln!(
            out,
            "  {}  {}  {}  {}  チケット {}  {}{account}",
            row.letter,
            row.name,
            if row.terminal.is_empty() {
                "-"
            } else {
                &row.terminal
            },
            status,
            ticket,
            what
        );
    }
    if shown == 0 {
        let _ = writeln!(out, "  (なし)");
    }
    Ok(exit::OK)
}

/// `<英字> --file <f>` か `<英字> <文>` から (英字, 文)。
fn letter_and_text(p: &args::Parsed) -> Result<(String, String)> {
    match (p.positionals.as_slice(), p.value("--file")?) {
        ([letter], Some(file)) => Ok((letter.clone(), read_text_file(file)?)),
        ([letter, text], None) => Ok((letter.clone(), text.clone())),
        _ => Err(Error::config(
            "子の英字と、送る文 (か --file <ファイル>) を渡す",
        )),
    }
}

pub fn send(r: &dyn Runner, args: &[String], out: &mut dyn Write) -> Result<u8> {
    let p = args::parse(
        args,
        &Spec {
            flags: &[NO_AGENT_CHECK],
            values: &["--file", "--ticket"],
        },
    )?;
    if help(&p, out) {
        return Ok(exit::OK);
    }
    let (letter, text) = letter_and_text(&p)?;
    if text.trim().is_empty() {
        return Err(Error::config("送る文が空です"));
    }
    let hc = Hc::new(r);
    hc.require()?;
    let (ledger, _) = open_ledger(r, &hc, p.value("--ticket")?)?;
    let row = find_child(&ledger, &letter)?;
    if row.cleaned() {
        return Err(Error::failure(format!("子 {} は片付けてある", row.letter)));
    }
    let term = ours(&hc, &row)?;
    // Claude が終わって shell に替わった端末に送ると、shell が文を 1 行ずつコマンドとして打つ
    if !p.flag(NO_AGENT_CHECK) {
        guard_child(&term, &row)?;
    }
    check_cmdline(&[row.terminal.clone(), text.clone()], "送る文")?;
    match hc.send(&row.terminal, &text)? {
        Ok(v) => {
            let started = v["started"].as_bool().map_or(
                "不明 (相手が状態を報告していない)".to_owned(),
                |b| b.to_string(),
            );
            let _ = writeln!(
                out,
                "子 {} ({}) に送った (started: {started})",
                row.letter, row.terminal
            );
            Ok(exit::OK)
        }
        Err(f) if f.blocked() => Err(Error::failure(format!(
            "子 {} は確認の画面で止まっています。pjp child read {} --lines 0 で読み、答えてよい範囲なら hc keys {} <キー>… で答える (ほかはユーザーに聞く)",
            row.letter, row.letter, row.terminal
        ))),
        Err(f) => Err(f.into_error("send")),
    }
}

pub fn read(r: &dyn Runner, args: &[String], out: &mut dyn Write) -> Result<u8> {
    let p = args::parse(
        args,
        &Spec {
            flags: &[],
            values: &["--lines", "--ticket"],
        },
    )?;
    if help(&p, out) {
        return Ok(exit::OK);
    }
    let [letter] = p.positionals.as_slice() else {
        return Err(Error::config("読む子の英字を 1 つ渡す (pjp child read A)"));
    };
    let lines: u32 = match p.value("--lines")? {
        Some(v) => v
            .parse()
            .map_err(|_| Error::config(format!("--lines は 0 以上の整数にする ({v})")))?,
        None => 120,
    };
    let hc = Hc::new(r);
    hc.require()?;
    let (ledger, _) = open_ledger(r, &hc, p.value("--ticket")?)?;
    let row = find_child(&ledger, letter)?;
    ours(&hc, &row)?;
    let text = hc.read(&row.terminal, lines)?;
    let _ = write!(out, "{text}");
    if !text.ends_with('\n') {
        let _ = writeln!(out);
    }
    Ok(exit::OK)
}

pub fn report(r: &dyn Runner, args: &[String], out: &mut dyn Write) -> Result<u8> {
    let p = args::parse(
        args,
        &Spec {
            flags: &[NO_AGENT_CHECK],
            values: &["--file"],
        },
    )?;
    if help(&p, out) {
        return Ok(exit::OK);
    }
    let text = match (p.positionals.as_slice(), p.value("--file")?) {
        ([text], None) => text.clone(),
        ([], Some(file)) => read_text_file(file)?,
        _ => {
            return Err(Error::config(
                "知らせる文を 1 つ (か --file <ファイル>) 渡す",
            ));
        }
    };
    if text.trim().is_empty() {
        return Err(Error::config("知らせる文が空です"));
    }
    let hc = Hc::new(r);
    hc.require()?;
    let id = r
        .env("HC_TERMINAL_ID")
        .ok_or_else(|| Error::config("hc の端末の中で打つ (親はこの端末の hc の親)"))?;
    let me = hc
        .get(&id)?
        .ok_or_else(|| Error::failure(format!("hc にこの端末 ({id}) がありません")))?;
    let parent = me["parent"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::failure(format!("この端末 ({id}) に hc の親がいません")))?
        .to_owned();
    // 親 (指揮役) の Claude が終わって shell に替わっていたら、知らせの文が shell に打たれる
    if !p.flag(NO_AGENT_CHECK) {
        let term = hc
            .get(&parent)?
            .ok_or_else(|| Error::failure(format!("親の端末 ({parent}) が hc にいません")))?;
        guard_parent(&term, &parent)?;
    }
    check_cmdline(&[parent.clone(), text.clone()], "知らせる文")?;
    match hc.send(&parent, &text)? {
        Ok(v) => {
            let started = v["started"].as_bool().map_or(
                "不明 (相手が状態を報告していない)".to_owned(),
                |b| b.to_string(),
            );
            let _ = writeln!(out, "親 ({parent}) に知らせた (started: {started})");
            Ok(exit::OK)
        }
        Err(f) => Err(f.into_error("send")),
    }
}
