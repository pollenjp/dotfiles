//! 起こす。unix は exec で選んだコマンドに置き換わる (終了コードもシグナルもそのコマンドのもの)。Windows には exec が無いので、
//! 子 process で起こして待ち、その終了コードで終わる (runner の launcher の win/runner/src/launcher.rs と同じ考え)。
//!
//! `claude-<名前>` は PATH で見つけた launcher をそのまま起こす (CLAUDE_CONFIG_DIR・token などの env は launcher が決める)。unix の
//! launcher (nix/pkgs/claude-account) は呼ばれた名前 ($0) でアカウントを決めるので、symlink を辿らずに PATH の名前のパスで起こす。

use std::ffi::OsString;
use std::path::PathBuf;

/// 起こすもの。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    /// PATH で見つけた `claude` か `claude-<名前>`
    pub program: PathBuf,
    pub args: Vec<OsString>,
    /// 見せる形のコマンド行 (コマンドの名前と引数。`quote::command_line`)
    pub shown: String,
}

/// 起こす。unix は戻らない (起こせなければ 126・127)。Windows は子の終了コード (起こせなければ 1)
pub fn run(plan: &Plan) -> i32 {
    run_os(plan)
}

#[cfg(unix)]
fn run_os(plan: &Plan) -> i32 {
    use std::os::unix::process::CommandExt;
    let err = std::process::Command::new(&plan.program)
        .args(&plan.args)
        .exec();
    eprintln!(
        "claude-selector: {} を起こせません ({err})",
        plan.program.display()
    );
    if err.kind() == std::io::ErrorKind::NotFound {
        127
    } else {
        126
    }
}

#[cfg(not(unix))]
fn run_os(plan: &Plan) -> i32 {
    #[cfg(windows)]
    let _ = console_ctrl::pass_to_children();
    match std::process::Command::new(&plan.program)
        .args(&plan.args)
        .status()
    {
        Ok(status) => status.code().unwrap_or(1),
        Err(e) => {
            eprintln!(
                "claude-selector: {} を起こせません ({e})",
                plan.program.display()
            );
            1
        }
    }
}

/// Ctrl+C・Ctrl+Break を claude-selector の中では受け流す (console の Ctrl+C は同じ console の process に全部届く。子の Claude Code が
/// 受けて扱い、claude-selector だけが先に落ちないように)。win/runner/src/launcher.rs の `console_ctrl` と同じ形 (TRUE を返す handler の
/// 登録は子に引き継がれない。`SetConsoleCtrlHandler(NULL, TRUE)` は「Ctrl+C を無視する」印を子に引き継がせ、Claude Code が Ctrl+C を
/// 受けなくなるので使わない)。この crate で unsafe を書くのはこの module だけ (Cargo.toml の `unsafe_code = "deny"` の例外)。
#[cfg(windows)]
#[allow(unsafe_code)]
mod console_ctrl {
    const CTRL_C_EVENT: u32 = 0;
    const CTRL_BREAK_EVENT: u32 = 1;

    // BOOL WINAPI SetConsoleCtrlHandler(PHANDLER_ROUTINE HandlerRoutine, BOOL Add)
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn SetConsoleCtrlHandler(handler: Option<extern "system" fn(u32) -> i32>, add: i32) -> i32;
    }

    /// HandlerRoutine (BOOL WINAPI HandlerRoutine(DWORD dwCtrlType))。受け流すときは TRUE (1)。閉じる・ログオフ・シャットダウンは
    /// FALSE を返して既定の扱い (終わる) に任せる
    extern "system" fn handler(ctrl_type: u32) -> i32 {
        i32::from(matches!(ctrl_type, CTRL_C_EVENT | CTRL_BREAK_EVENT))
    }

    /// handler を登録する。登録できたら true
    pub fn pass_to_children() -> bool {
        // SAFETY: handler は 'static な extern "system" の関数で、形は HandlerRoutine と同じ (DWORD を受けて BOOL を返し、panic しない)。
        // 登録は process が終わるまで外さない
        unsafe { SetConsoleCtrlHandler(Some(handler), 1) != 0 }
    }
}
