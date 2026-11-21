//! check: claude-selector-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 見せるコマンド行の引用 (quote)。起こすのは argv のままで、ここは画面と最後に残す 1 行のため。
//!
//! - POSIX: 囲まなくてよい字 (英数字と `_@%+=:,./-`) だけならそのまま。空・空白・日本語・`'`・`$`・`~` は '…' で囲み、`'` は `'\''`
//! - PowerShell: `,` (配列)・`@` (splat)・`$`・空白は '…' で囲み、`'` は `''`。`\` はそのまま
//! - command_line は OS の書き方で 1 行にする

use claude_selector::quote::{command_line, posix, powershell};
use std::ffi::OsString;

#[test]
fn posix_words() {
    for plain in [
        "claude",
        "--remote-control=",
        "--model",
        "claude-opus-5-5",
        "-c",
        "a,b",
        "x@y",
        "/usr/bin/x",
    ] {
        assert_eq!(posix(plain), plain);
    }
    assert_eq!(posix(""), "''");
    assert_eq!(posix("a b"), "'a b'");
    assert_eq!(posix("質問"), "'質問'");
    assert_eq!(posix("it's"), "'it'\\''s'");
    assert_eq!(posix("$HOME"), "'$HOME'");
    assert_eq!(posix("~"), "'~'");
    assert_eq!(
        posix("--remote-control=作業 1"),
        "'--remote-control=作業 1'"
    );
}

#[test]
fn powershell_words() {
    for plain in ["claude", "--remote-control=", "-c", "C:\\x\\y.exe"] {
        assert_eq!(powershell(plain), plain);
    }
    assert_eq!(powershell(""), "''");
    assert_eq!(powershell("a,b"), "'a,b'");
    assert_eq!(powershell("@x"), "'@x'");
    assert_eq!(powershell("$env:X"), "'$env:X'");
    assert_eq!(powershell("it's"), "'it''s'");
    assert_eq!(powershell("a b"), "'a b'");
}

#[test]
fn command_line_uses_the_os_quoting() {
    let args: Vec<OsString> = ["--effort", "max", "質問 です"]
        .iter()
        .map(OsString::from)
        .collect();
    assert_eq!(
        command_line("claude-work", &args),
        "claude-work --effort max '質問 です'"
    );
    let quote_args: Vec<OsString> = vec!["it's".into()];
    let expected = if cfg!(windows) {
        "claude 'it''s'"
    } else {
        "claude 'it'\\''s'"
    };
    assert_eq!(command_line("claude", &quote_args), expected);
}
