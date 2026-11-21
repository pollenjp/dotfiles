//! 見せるコマンド行の引用。起こすのは argv のまま (shell を通さない) なので、ここは画面と最後に残す 1 行のためだけにある。
//! unix は POSIX の shell (bash・fish で貼っても同じ引数になる形)、Windows は PowerShell の書き方で囲む。

use std::ffi::OsString;

/// `program` と `args` を、この OS の shell の書き方で 1 行にする
pub fn command_line(program: &str, args: &[OsString]) -> String {
    let quote = if cfg!(windows) { powershell } else { posix };
    let mut words = vec![quote(program)];
    words.extend(args.iter().map(|a| quote(&a.to_string_lossy())));
    words.join(" ")
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
