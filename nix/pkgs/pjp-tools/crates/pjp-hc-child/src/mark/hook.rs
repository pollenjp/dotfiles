//! `pjp mark hook prompt|stop`: Claude Code の UserPromptSubmit と Stop の hook (spec
//! `docs/superpowers/specs/2026-11-19-hub-asking-hook-design.md`)。ハブの雛形 (`skills/pjp-hc-hub/assets/hub/settings.json`) が
//! `pjp mark hook prompt; exit 0`・`pjp mark hook stop; exit 0` の形で登録する。
//!
//! - prompt (UserPromptSubmit): ユーザーの発言が届き、この端末に pjp.asking があれば、1 回の hc label で要旨を pjp.asked に
//!   移して pjp.asking を外し (`❓` が消える)、そのことを Claude への文脈 (`additionalContext`) で知らせる
//! - stop (Stop): pjp.asked が残っていれば、1 回目 (`stop_hook_active` が false) は文脈を返してターンを続けさせ、後始末
//!   (`answered` か `asking`) を打たせる。2 回目は pjp.asked を外して終える (回り続けない)。続けさせるのに `decision: "block"`
//!   を使わないのは、Claude Code が block を hook のエラーとして出すため (spec §4.3・§14)
//!
//! どんな失敗でも終了コード 0 で終え、失敗は stderr に 1 行出す (UserPromptSubmit の hook が 2 で終わると発言が止まり、Stop の
//! hook が 2 で終わると Claude が続けて回り続ける)。stdout は 1 行の ASCII だけの JSON か空。

use std::io::Write;
use std::time::Duration;

use pjp_core::exit;
use pjp_core::text::{decode_text, json_ascii};
use serde_json::{Value, json};

use super::{LABEL_ASKED, LABEL_ASKING, USAGE};
use crate::hc::{Hc, Runner, label_of};

/// hook の hc の待ち (1 回ごと)。UserPromptSubmit の hook の既定の打ち切り (30 秒) より前に終える。
const HOOK_HC_TIMEOUT: Duration = Duration::from_secs(10);

/// Notion のコメントの頭。見回り役が `<hc from="… pjp-hubd">` の札で包んで届けるが、ユーザーの指示として扱う
/// (pjp-hc-hub の SKILL.md)。
const NOTION_COMMENT: &str = "[Notion のコメント]";

/// `pjp mark hook <名前> …` (args は `hook` を除いたもの)。いつも 0 を返す。
pub(super) fn run(r: &dyn Runner, args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> u8 {
    let Some((event, rest)) = args.split_first() else {
        let _ = writeln!(
            err,
            "pjp mark hook: hook の名前を渡す (prompt・stop)。何もしない"
        );
        return exit::OK;
    };
    match event.as_str() {
        "-h" | "--help" => {
            let _ = write!(out, "{USAGE}");
            return exit::OK;
        }
        "prompt" | "stop" => {}
        other => {
            let _ = writeln!(
                err,
                "pjp mark hook: 知らない hook です: {other} (prompt・stop)。何もしない"
            );
            return exit::OK;
        }
    }
    let mut note = |msg: &str| {
        let _ = writeln!(err, "pjp mark hook {event}: {msg}");
    };
    if !rest.is_empty() {
        note(&format!("引数 {} は見ない", rest.join(" ")));
    }
    let Some(input) = read_input(r, &mut note) else {
        return exit::OK;
    };
    if event == "prompt" {
        prompt(r, &input, out, &mut note);
    } else {
        stop(r, &input, out, &mut note);
    }
    exit::OK
}

/// 発言 (UserPromptSubmit の入力の `prompt`) がユーザーのものか (spec §4.4)。頭の貼り付けの包み (`<pasted_content …>`) を
/// 剥がしてから、子の報告・`hc send` の札 (`<hc …>`。中身が Notion のコメントのものは除く) と、裏の作業の知らせ
/// (`<task-notification>`) をユーザーの発言でないとみる。ほか (端末で打った文・panel の答え・ユーザーの貼り付け・
/// `<bash-input>`・slash command) はユーザーの発言。
pub fn from_user(prompt: &str) -> bool {
    let mut head = prompt.trim_start();
    if let Some(inner) = after_open_tag(head, "pasted_content") {
        head = inner.trim_start();
    }
    if let Some(inner) = after_open_tag(head, "hc") {
        return inner.trim_start().starts_with(NOTION_COMMENT);
    }
    after_open_tag(head, "task-notification").is_none()
}

/// `text` が札 `<name` (後ろが `>` か空白) で始まれば、開きの札の `>` より後ろを返す (札が閉じていなければ空)。
fn after_open_tag<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let rest = text.strip_prefix('<')?.strip_prefix(name)?;
    if !rest.starts_with(|c: char| c == '>' || c.is_ascii_whitespace()) {
        return None;
    }
    Some(rest.split_once('>').map_or("", |(_, after)| after))
}

/// stdin の hook の入力 (JSON の object) を読む。読めなければ note を出して None。
fn read_input(r: &dyn Runner, note: &mut dyn FnMut(&str)) -> Option<Value> {
    let bytes = match r.read_stdin() {
        Ok(Some(bytes)) => bytes,
        Ok(None) => {
            note(
                "Claude Code の hook から打つ (stdin に hook の JSON を渡す)。端末からは読まずに何もしない",
            );
            return None;
        }
        Err(e) => {
            note(&format!("{e}。何もしない"));
            return None;
        }
    };
    // PowerShell が BOM を付けて (UTF-16 で) 流しても読む
    let text = decode_text(&bytes);
    if text.trim().is_empty() {
        note("stdin が空なので何もしない");
        return None;
    }
    match serde_json::from_str::<Value>(&text) {
        Ok(v) if v.is_object() => Some(v),
        _ => {
            note("stdin を hook の JSON (object) として読めないので何もしない");
            None
        }
    }
}

/// この端末 (`HC_TERMINAL_ID`) を hc で読む。読めなければ note を出して None。
fn this_terminal<'a>(
    r: &'a dyn Runner,
    note: &mut dyn FnMut(&str),
) -> Option<(Hc<'a>, String, Value)> {
    let Some(id) = r.env("HC_TERMINAL_ID") else {
        note("hc の端末の外 (HC_TERMINAL_ID が無い) なので何もしない");
        return None;
    };
    let hc = Hc::with_timeout(r, HOOK_HC_TIMEOUT);
    if let Err(e) = hc.require() {
        note(&format!("{e}。何もしない"));
        return None;
    }
    match hc.get(&id) {
        Ok(Some(term)) => Some((hc, id, term)),
        Ok(None) => {
            note(&format!("hc にこの端末 ({id}) が無いので何もしない"));
            None
        }
        Err(e) => {
            note(&format!("{e}。何もしない"));
            None
        }
    }
}

/// label の値 (前後の空白を除く。空なら無いとみる。pjp-spaces も空白だけの pjp.asking に ❓ を出さない)。
fn value_of<'v>(term: &'v Value, key: &str) -> Option<&'v str> {
    label_of(term, key).map(str::trim).filter(|s| !s.is_empty())
}

/// 答えが届いたとき: pjp.asking を外して要旨を pjp.asked に移し、文脈を返す。
fn prompt(r: &dyn Runner, input: &Value, out: &mut dyn Write, note: &mut dyn FnMut(&str)) {
    let Some(text) = input["prompt"].as_str() else {
        note("入力に prompt が無いので何もしない");
        return;
    };
    if !from_user(text) {
        return;
    }
    let Some((hc, id, term)) = this_terminal(r, note) else {
        return;
    };
    let Some(summary) = value_of(&term, LABEL_ASKING) else {
        return;
    };
    let pairs = [
        format!("{LABEL_ASKED}={summary}"),
        format!("{LABEL_ASKING}="),
    ];
    if let Err(e) = hc.label(&id, &pairs) {
        note(&format!("{e}。答え待ちの印は今のまま"));
        return;
    }
    emit(out, "UserPromptSubmit", &prompt_context(summary));
}

/// ターンの終わり: pjp.asked が残っていれば、1 回目は文脈を返して続けさせ、2 回目は外して終える。
fn stop(r: &dyn Runner, input: &Value, out: &mut dyn Write, note: &mut dyn FnMut(&str)) {
    let again = input["stop_hook_active"].as_bool().unwrap_or(false);
    let Some((hc, id, term)) = this_terminal(r, note) else {
        return;
    };
    let Some(summary) = value_of(&term, LABEL_ASKED) else {
        return;
    };
    if again {
        if let Err(e) = hc.label(&id, &[format!("{LABEL_ASKED}=")]) {
            note(&format!("{e}。{LABEL_ASKED} は今のまま"));
        }
        return;
    }
    emit(out, "Stop", &stop_context(summary));
}

fn prompt_context(summary: &str) -> String {
    format!(
        "pjp mark hook prompt: ユーザーの発言が届いたので、答え待ちの印 (❓。label {LABEL_ASKING}) を外し、問いの要旨を label \
         {LABEL_ASKED} に移した。問い: {summary}。この問いが済んだら pjp mark answered を、まだ答えを待つ問い (答えていない問い・\
         新しい問い) を出してターンを終えるなら pjp mark asking '<その要旨>' を打つ (どちらも {LABEL_ASKED} を外す。チケットに \
         👤 回答 を出していれば pjp ticket wait TKT-n --done も)。どちらも打たずにターンを終えると、Stop の hook \
         (pjp mark hook stop) が 1 回だけターンを続けさせて確かめさせる。"
    )
}

fn stop_context(summary: &str) -> String {
    format!(
        "pjp mark hook stop: ユーザーの発言が届いたときに答え待ちの印 (❓) を外し、問いの要旨を label {LABEL_ASKED} に残して\
         いる。問い: {summary}。ターンを終える前に、問いが済んだなら pjp mark answered を、まだ答えを待つ問い (答えていない問い・\
         新しい問い) があるなら pjp mark asking '<その要旨>' を打つ (チケットに 👤 回答 を出していれば pjp ticket wait TKT-n \
         --done も)。どちらも打たずに終えれば、この hook は {LABEL_ASKED} を外し、もう続けさせない。"
    )
}

/// hook の出力 (1 行の ASCII だけの JSON) を書く。
fn emit(out: &mut dyn Write, event: &str, context: &str) {
    let v = json!({
        "hookSpecificOutput": {
            "hookEventName": event,
            "additionalContext": context,
        }
    });
    let _ = writeln!(out, "{}", json_ascii(&v.to_string()));
    let _ = out.flush();
}

#[cfg(test)]
mod tests;
