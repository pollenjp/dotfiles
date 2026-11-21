//! 入口の流れ: 端末か確かめる → アカウントを集める → 選ぶ画面 → 起こす。
//!
//! 引数は読まない (cs の後ろに打ったものは全部、組み立てた引数の後ろに付けて claude に渡す)。終了コード: 起こしたコマンドのもの /
//! 130 = やめた (Esc・Ctrl+C) / 2 = 端末でない / 1 = 端末を扱えない・家が分からない / 126・127 = 起こせない (unix)。

use crate::accounts::{self, Defaults};
use crate::launch;
use crate::term::{self, Term};
use crate::ui::{Outcome, Ui};
use std::ffi::OsString;
use std::io::IsTerminal;
use std::path::PathBuf;

/// やめたときの終了コード (Ctrl+C と同じ。fzf も同じ)
pub const CANCELED: i32 = 130;

pub fn main() -> i32 {
    let extra: Vec<OsString> = std::env::args_os().skip(1).collect();
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        eprintln!(
            "claude-selector: 端末で打ってください (矢印キーで選ぶ画面を出すので、入力と出力が端末のときだけ動きます)。選ばずに起こすなら c を打ちます。"
        );
        return 2;
    }
    let Some(home) = home_dir() else {
        eprintln!(
            "claude-selector: 家のディレクトリが分かりません (環境変数 {} が無い)",
            home_var()
        );
        return 1;
    };
    let path = std::env::var_os("PATH");
    let found = accounts::find(&home, &Defaults::for_this_os(&home), path.as_deref());
    let note = claude_note(std::env::var_os("CLAUDE_CONFIG_DIR"));
    let mut ui = Ui::new(&found, &note, extra);
    let color = std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty());
    term::install_panic_hook();
    let mut term = match Term::start(color) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("claude-selector: 端末を raw mode にできません ({e})");
            return 1;
        }
    };
    loop {
        let (cols, rows) = term.size();
        let key = term
            .draw(&ui.frame(cols, rows))
            .and_then(|()| term.read_key());
        let key = match key {
            Ok(Some(k)) => k,
            Ok(None) => continue,
            Err(e) => {
                let _ = term.finish(None);
                eprintln!("claude-selector: 端末を読み書きできません ({e})");
                return 1;
            }
        };
        match ui.handle(key) {
            Outcome::Continue => {}
            Outcome::Cancel => {
                let _ = term.finish(None);
                eprintln!("claude-selector: やめました (claude は起こしていません)");
                return CANCELED;
            }
            Outcome::Launch(plan) => {
                let _ = term.finish(Some(&format!("$ {}", plan.shown)));
                return launch::run(&plan);
            }
        }
    }
}

/// 家を指す環境変数 (Windows は runner と同じく USERPROFILE)
fn home_var() -> &'static str {
    if cfg!(windows) { "USERPROFILE" } else { "HOME" }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os(home_var())
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// 素の claude に添える説明 (CLAUDE_CONFIG_DIR が付いていれば、それが効く)
pub fn claude_note(config_dir: Option<OsString>) -> String {
    match config_dir.filter(|v| !v.is_empty()) {
        Some(dir) => format!("CLAUDE_CONFIG_DIR={}", dir.to_string_lossy()),
        None => "~/.claude".to_string(),
    }
}
