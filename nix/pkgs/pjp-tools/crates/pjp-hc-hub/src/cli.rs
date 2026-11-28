//! `pjp hub` の引数と、command への振り分け。

use std::ffi::OsString;
use std::io::{IsTerminal, Read, Write};
use std::process::ExitCode;

use pjp_core::exit;

use crate::guard::{self, Decision};
use crate::{bake, hello, init};

const USAGE: &str = "\
pjp hub — herdr-app と hc のハブ (pjp-hc-hub) の道具

使い方:
  pjp hub init [--dir DIR] [--check]   DIR (既定は ~/h) をハブにする。打ち直すと雛形との差だけを直す
  pjp hub check [--dir DIR]            書かずに雛形との差を出す (差があれば終了コード 1)。init --check と同じ
  pjp hub guard                        Claude Code の PreToolUse の hook (stdin の JSON を読む。ハブの .claude/settings.json が登録する)
  pjp hub hello                        ハブの会話の始めの点検 (ハブの中か・雛形・この端末・見回り役・hc の machine)
  pjp hub bake PANEL ID... --out DIR [--home HOME]
                                       panel.json (PANEL) の image の節 ID の図に marks の動きを焼いた写しを DIR に書き、
                                       チケットの図のキャプションを出す (会話のチケットにも図を上げるため)。ID にミニ絵の
                                       図のパス (TKT-n/mini-x.svg) を渡すと、焼かずに写す

hello は、T3 Code の会話 (env に HC_TERMINAL_ID が無く T3CODE_THREAD_ID がある) では、この端末の代わりに T3 のスレッド・
T3 のリンク (子のスレッドを立てる先。T3CODE_CLI_PATH の t3 environment list)・T3 の設定 (~/.claude/t3/ のファイルと
T3 の Launch arguments) を見て、見回り役は立てない。

init は git init・決まりのファイル 3 つ (CLAUDE.md・.claude/settings.json・.gitignore)・git config pjp.devtracker.repo と
pjp.hub.skill・署名しない commit をする。別の repo の中・remote を持つ repo・ハブの worktree・ほかの skill のハブ・まだハブで
ないのに雛形の外のものがある場所では、何も書かずに止まる (終了コード 1)。

bake は節の src の図を HOME (既定は HERDR_APP_HOME → XDG_CONFIG_HOME/herdr-app → ~/.config/herdr-app) の
pjp-hub-panel-media から読み、flow・pulse・dot を CSS の動きに、label を字にして、図と同じ名前で DIR に書く (panel の図は
書き換えない)。DIR は scratchpad の、panel.json のフォルダと HOME の外にする (中なら終了コード 2)。写せないものがあれば
終了コード 1。!! の行は panel の図のずれ (直す)、note: の行は知らせ。
";

/// `pjp hub <args>…` を打ち、終了コードを返す。
pub fn main(args: Vec<OsString>) -> ExitCode {
    let mut args = args.into_iter();
    let Some(sub) = args.next() else {
        print!("{USAGE}");
        return ExitCode::SUCCESS;
    };
    let rest: Vec<OsString> = args.collect();
    match sub.to_str() {
        Some("-h" | "--help" | "help") => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        Some("init") => init_command("pjp hub init", &rest, false),
        Some("check") => init_command("pjp hub check", &rest, true),
        Some("guard") => guard_command(&rest),
        Some("hello") => hello_command(&rest),
        Some("bake") => bake_command(&rest),
        _ => usage_error(
            "pjp hub",
            &format!("知らない command: {}", sub.to_string_lossy()),
        ),
    }
}

fn usage_error(prog: &str, message: &str) -> ExitCode {
    eprintln!("{prog}: {message}");
    eprint!("{USAGE}");
    ExitCode::from(exit::CONFIG)
}

/// `init` / `check` の引数。None は --help を出したとき。
fn parse_init(args: &[OsString], check: bool) -> Result<Option<init::Options>, String> {
    let mut opts = init::Options { dir: None, check };
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        match a.to_str() {
            Some("--dir") => {
                let v = args.get(i + 1).ok_or("--dir に DIR を渡す")?;
                opts.dir = Some(v.clone());
                i += 2;
                continue;
            }
            Some(s) if s.starts_with("--dir=") => {
                opts.dir = Some(OsString::from(&s["--dir=".len()..]));
            }
            Some("--check") => opts.check = true,
            Some("-h" | "--help") => return Ok(None),
            _ => return Err(format!("知らない引数: {}", a.to_string_lossy())),
        }
        i += 1;
    }
    if opts.dir.as_ref().is_some_and(|d| d.is_empty()) {
        return Err("--dir に DIR を渡す".to_owned());
    }
    Ok(Some(opts))
}

fn init_command(prog: &str, args: &[OsString], check: bool) -> ExitCode {
    match parse_init(args, check) {
        Ok(Some(opts)) => exit::finish(prog, init::run(&opts)),
        Ok(None) => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        Err(message) => usage_error(prog, &message),
    }
}

/// hook。何があっても終了コード 0 (2 で終わると Claude Code は書き込みを全部止める)。
fn guard_command(args: &[OsString]) -> ExitCode {
    if args.iter().any(|a| a == "-h" || a == "--help") {
        print!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    if let Some(a) = args.first() {
        eprintln!(
            "pjp hub guard: 引数は取りません ({} は見ずに、hook として動きます)",
            a.to_string_lossy()
        );
    }
    let mut stdin = std::io::stdin();
    if stdin.is_terminal() {
        eprintln!(
            "pjp hub guard: Claude Code の hook から打つ (stdin に hook の JSON を渡す)。端末からは読まずに通す"
        );
        return ExitCode::SUCCESS;
    }
    let mut input = Vec::new();
    if let Err(e) = stdin.read_to_end(&mut input) {
        eprintln!("pjp hub guard: stdin を読めないので通す ({e})");
        return ExitCode::SUCCESS;
    }
    match guard::decide(&input, &guard::Context::from_env()) {
        Decision::Allow => {}
        Decision::Note(note) => eprintln!("pjp hub guard: {note}"),
        Decision::Deny(reason) => {
            let mut out = std::io::stdout();
            let _ = writeln!(out, "{}", guard::deny_json(&reason));
            let _ = out.flush();
        }
    }
    ExitCode::SUCCESS
}

/// `bake` の引数。None は --help を出したとき。
fn parse_bake(args: &[OsString]) -> Result<Option<bake::Options>, String> {
    let mut positional: Vec<OsString> = Vec::new();
    let mut out: Option<OsString> = None;
    let mut home: Option<OsString> = None;
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        match a.to_str() {
            Some(flag @ ("--out" | "--home")) => {
                let v = args
                    .get(i + 1)
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| format!("{flag} に DIR を渡す"))?;
                if flag == "--out" {
                    out = Some(v.clone());
                } else {
                    home = Some(v.clone());
                }
                i += 2;
                continue;
            }
            Some(s) if s.starts_with("--out=") => out = Some(OsString::from(&s["--out=".len()..])),
            Some(s) if s.starts_with("--home=") => {
                home = Some(OsString::from(&s["--home=".len()..]));
            }
            Some("-h" | "--help") => return Ok(None),
            Some(s) if s.starts_with('-') => return Err(format!("知らない引数: {s}")),
            _ => positional.push(a.clone()),
        }
        i += 1;
    }
    let mut positional = positional.into_iter();
    let panel = positional
        .next()
        .ok_or("panel.json のパスと、焼く image の節の id を渡す")?;
    let ids: Vec<String> = positional
        .map(|id| id.to_string_lossy().into_owned())
        .collect();
    if ids.is_empty() {
        return Err("焼く image の節の id を 1 つ以上渡す".to_owned());
    }
    let out = out
        .filter(|o| !o.is_empty())
        .ok_or("--out に写しを書くディレクトリ (scratchpad) を渡す")?;
    if home.as_ref().is_some_and(|h| h.is_empty()) {
        return Err("--home に herdr-app の home を渡す".to_owned());
    }
    Ok(Some(bake::Options {
        panel: panel.into(),
        ids,
        out: out.into(),
        home: home.map(Into::into),
        // 足し分があるかは bake_command で決める (引数の読みは env によらない)
        wsl: false,
    }))
}

fn bake_command(args: &[OsString]) -> ExitCode {
    match parse_bake(args) {
        Ok(Some(opts)) => {
            let opts = bake::Options {
                wsl: pjp_core::extras::shim().is_some(),
                ..opts
            };
            exit::finish("pjp hub bake", bake::run(&opts))
        }
        Ok(None) => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        Err(message) => usage_error("pjp hub bake", &message),
    }
}

fn hello_command(args: &[OsString]) -> ExitCode {
    match args.first().and_then(|a| a.to_str()) {
        None => ExitCode::from(hello::run()),
        Some("-h" | "--help") => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        Some(_) => usage_error("pjp hub hello", "引数は取りません"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(items: &[&str]) -> Vec<OsString> {
        items.iter().map(OsString::from).collect()
    }

    #[test]
    fn parse_init_args() {
        assert_eq!(
            parse_init(&argv(&[]), false).unwrap(),
            Some(init::Options {
                dir: None,
                check: false
            })
        );
        assert_eq!(
            parse_init(&argv(&["--dir", "x", "--check"]), false).unwrap(),
            Some(init::Options {
                dir: Some("x".into()),
                check: true
            })
        );
        assert_eq!(
            parse_init(&argv(&["--dir=~/h"]), true).unwrap(),
            Some(init::Options {
                dir: Some("~/h".into()),
                check: true
            })
        );
        assert_eq!(parse_init(&argv(&["-h"]), false).unwrap(), None);
        for bad in [
            &["--dir"][..],
            &["--dir="],
            &["--dir", ""],
            &["--bogus"],
            &["x"],
        ] {
            assert!(parse_init(&argv(bad), false).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn parse_bake_args() {
        assert_eq!(
            parse_bake(&argv(&["p.json", "r1", "r2", "--out", "o"])).unwrap(),
            Some(bake::Options {
                panel: "p.json".into(),
                ids: vec!["r1".to_owned(), "r2".to_owned()],
                out: "o".into(),
                home: None,
                wsl: false,
            })
        );
        assert_eq!(
            parse_bake(&argv(&["--out=o", "--home=h", "p.json", "r1"])).unwrap(),
            Some(bake::Options {
                panel: "p.json".into(),
                ids: vec!["r1".to_owned()],
                out: "o".into(),
                home: Some("h".into()),
                wsl: false,
            })
        );
        assert_eq!(parse_bake(&argv(&["--help"])).unwrap(), None);
        for bad in [
            &["p.json", "r1"][..],
            &["p.json", "--out", "o"],
            &["--out", "o"],
            &["p.json", "r1", "--out"],
            &["p.json", "r1", "--out="],
            &["p.json", "r1", "--out", "o", "--home", ""],
            &["p.json", "r1", "--out", "o", "--bogus"],
        ] {
            assert!(parse_bake(&argv(bad)).is_err(), "{bad:?}");
        }
    }
}
