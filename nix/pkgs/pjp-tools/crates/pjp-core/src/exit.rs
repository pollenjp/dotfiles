//! エラーと終了コード (spec §8.5 の 0・1・2・75)。

use std::fmt;
use std::io::{self, Write};
use std::process::ExitCode;

/// ふつうに終わった。
pub const OK: u8 = 0;
/// 失敗した (外のコマンドが落ちた・API が断ったなど)。
pub const FAILURE: u8 = 1;
/// 設定の誤り (道具が無い・clone が見つからない・プロファイルが決まらない)。常駐を起こし直しても直らない。
pub const CONFIG: u8 = 2;
/// clone が変わった。`pjp --supervise` が作り直して起こし直す (sysexits の EX_TEMPFAIL)。
pub const RESTART: u8 = 75;

/// 外のコマンドを起こせなかったわけ。道具が自分の文で知らせたいとき ([`Error::launch`]) に使う
/// (Python の FileNotFoundError と、ほかの OSError の `strerror` にあたる)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Launch {
    /// PATH のどこにも無い (Unix の ENOENT・ENOTDIR、Windows のファイルが無い)。
    NotFound,
    /// 在るのに起こせない (実行の権限が無い・Exec format error など)。中身は OS の文 ([`os_message`])。
    Failed(String),
}

/// 道具のエラー。終了コードと、利用者に見せる 1 行 (日本語) を持つ。外のコマンドを起こせなかったエラーは、そのわけも持つ。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    code: u8,
    message: String,
    launch: Option<Launch>,
}

impl Error {
    pub fn new(code: u8, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            launch: None,
        }
    }

    /// 外のコマンドを起こせなかったわけを添える。
    pub fn with_launch(mut self, launch: Launch) -> Self {
        self.launch = Some(launch);
        self
    }

    /// 外のコマンドを起こせなかったエラーなら、そのわけ ([`crate::process`] が付ける)。
    pub fn launch(&self) -> Option<&Launch> {
        self.launch.as_ref()
    }

    /// 設定の誤り (終了コード 2)。
    pub fn config(message: impl Into<String>) -> Self {
        Self::new(CONFIG, message)
    }

    /// 失敗 (終了コード 1)。
    pub fn failure(message: impl Into<String>) -> Self {
        Self::new(FAILURE, message)
    }

    /// 入出力のエラーに、何をしていたかを添える (終了コード 1)。
    pub fn io(context: impl fmt::Display, err: &io::Error) -> Self {
        Self::failure(format!("{context}: {err}"))
    }

    pub fn code(&self) -> u8 {
        self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// OS の文 (Python の `OSError.strerror` にあたる)。`io::Error` の表示から末尾の ` (os error N)` を除く
/// (`Permission denied (os error 13)` → `Permission denied`)。OS のエラー番号を持たないものは表示のまま。
pub fn os_message(err: &io::Error) -> String {
    let shown = err.to_string();
    if err.raw_os_error().is_some()
        && let Some(i) = shown.rfind(" (os error ")
        && shown.ends_with(')')
    {
        return shown[..i].to_owned();
    }
    shown
}

/// main の終わりの形。`Ok(code)` はその終了コード、`Err` は `<prog>: <文>` を `err_out` に書いて、エラーの終了コードを返す。
pub fn report(prog: &str, result: Result<u8>, err_out: &mut dyn Write) -> u8 {
    match result {
        Ok(code) => code,
        Err(e) => {
            // stderr に書けなくても終了コードは返す (書けないことを、さらに書く先は無い)
            let _ = writeln!(err_out, "{prog}: {e}");
            e.code()
        }
    }
}

/// `report` を stderr に向けたもの。道具の `main` は `pjp_core::exit::finish("pjp-doctor", run())` で終える。
pub fn finish(prog: &str, result: Result<u8>) -> ExitCode {
    ExitCode::from(report(prog, result, &mut io::stderr()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_codes() {
        assert_eq!(Error::config("x").code(), CONFIG);
        assert_eq!(Error::failure("x").code(), FAILURE);
        assert_eq!(Error::new(RESTART, "x").code(), RESTART);
        assert_eq!(
            Error::config("clone が見つかりません").message(),
            "clone が見つかりません"
        );
        assert_eq!(
            Error::config("clone が見つかりません").to_string(),
            "clone が見つかりません"
        );
    }

    #[test]
    fn launch_is_carried_and_absent_by_default() {
        assert_eq!(Error::failure("x").launch(), None);
        let e = Error::config("ntn が見つかりません").with_launch(Launch::NotFound);
        assert_eq!(e.launch(), Some(&Launch::NotFound));
        assert_eq!(e.code(), CONFIG);
        let e = Error::failure("x").with_launch(Launch::Failed("Permission denied".into()));
        assert_eq!(
            e.launch(),
            Some(&Launch::Failed("Permission denied".to_owned()))
        );
    }

    #[test]
    fn os_message_strips_os_error_suffix() {
        let e = io::Error::from_raw_os_error(2);
        let shown = e.to_string();
        assert!(shown.contains("(os error 2)"), "{shown}");
        let msg = os_message(&e);
        assert!(!msg.contains("os error"), "{msg}");
        assert!(!msg.is_empty());
        // OS のエラー番号の無いものは表示のまま
        assert_eq!(os_message(&io::Error::other("boom")), "boom");
    }

    #[test]
    fn io_error_keeps_context() {
        let e = Error::io(
            "rust-toolchain.toml を読めません",
            &io::Error::other("boom"),
        );
        assert_eq!(e.code(), FAILURE);
        assert_eq!(e.message(), "rust-toolchain.toml を読めません: boom");
    }

    #[test]
    fn report_maps_ok_and_err() {
        let mut out = Vec::new();
        assert_eq!(report("pjp", Ok(OK), &mut out), OK);
        assert_eq!(report("pjp", Ok(RESTART), &mut out), RESTART);
        assert!(out.is_empty());

        assert_eq!(
            report(
                "pjp",
                Err(Error::config("clone が見つかりません")),
                &mut out
            ),
            CONFIG
        );
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "pjp: clone が見つかりません\n"
        );
    }
}
