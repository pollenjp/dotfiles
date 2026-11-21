//! 見せるコマンド行の引用。起こすのは argv のまま (shell を通さない) なので、ここは画面と最後に残す 1 行のためだけにある。
//! unix は POSIX の shell (bash・fish で貼っても同じ引数になる形)、Windows は PowerShell の書き方で囲む。
//!
//! 引数・パスの制御文字 (改行・ESC など) は、そのまま端末に書くと画面が崩れる (戻る行の数がずれる・色や位置の命令になる) ので、
//! 見せる前に [`visible`] で `\n`・`\u{1b}` の形にする。

use std::ffi::OsString;

/// `program` と `args` を、この OS の shell の書き方で 1 行にする (制御文字はそのまま。見せる前に [`visible`] を通す)
pub fn command_line(program: &str, args: &[OsString]) -> String {
    let mut words = vec![word(program)];
    words.extend(args.iter().map(|a| word(&a.to_string_lossy())));
    words.join(" ")
}

/// この OS の shell の 1 語
pub fn word(s: &str) -> String {
    if cfg!(windows) {
        powershell(s)
    } else {
        posix(s)
    }
}

/// POSIX の shell の 1 語 (囲まなくてよい字だけなら、そのまま。ほかは '…' で囲み、中の ' は '\'' にする)
pub fn posix(word: &str) -> String {
    let plain = |c: char| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c);
    if !word.is_empty() && word.chars().all(plain) {
        return word.to_string();
    }
    format!("'{}'", word.replace('\'', "'\\''"))
}

/// PowerShell の 1 語 (囲まなくてよい字だけなら、そのまま。ほかは '…' で囲み、中の ' は '' にする)。`,` (配列)・`@` (splat) は囲む
pub fn powershell(word: &str) -> String {
    let plain = |c: char| c.is_ascii_alphanumeric() || "_+=:./\\-".contains(c);
    if !word.is_empty() && word.chars().all(plain) {
        return word.to_string();
    }
    format!("'{}'", word.replace('\'', "''"))
}

/// 制御文字 (C0・DEL・C1) を `\n`・`\t`・`\u{1b}` の形にする (端末に書いても画面が崩れない)。ほかの字はそのまま
pub fn visible(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_control() {
            out.extend(c.escape_default());
        } else {
            out.push(c);
        }
    }
    out
}
