//! 端末から字を出さずに 1 行読む (API キーのような値を、画面にも履歴にも残さずに受ける)。
//!
//! 読む間は端末の echo と行の編集を止め (Unix は termios の raw に近い形、Windows は console の mode)、行の編集
//! (Backspace・Ctrl+U) と Ctrl+C・Ctrl+D をここで受ける。Ctrl+C を signal にしないので、止めても端末の設定を戻してから
//! 終われる (echo を止めたままの端末を残さない)。OS の違いは `sys` の `RawTerm` に閉じる。

use std::io::{IsTerminal, Write};

/// 字を出さずに読んだ結果。
#[derive(Clone, PartialEq, Eq)]
pub enum Hidden {
    /// Enter (か、字を打った後の Ctrl+D・Ctrl+Z) までの字。
    Line(String),
    /// 何も打たずに Ctrl+D (Windows は Ctrl+Z も) で終えた・入力が尽きた。
    Eof,
    /// Ctrl+C で止めた。
    Interrupted,
}

impl std::fmt::Debug for Hidden {
    /// 読んだ字は出さない (値を debug の出力やテストの失敗の文に載せない)。
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Hidden::Line(s) => write!(f, "Line(<{} 字>)", s.chars().count()),
            Hidden::Eof => f.write_str("Eof"),
            Hidden::Interrupted => f.write_str("Interrupted"),
        }
    }
}

/// stdin が端末か。
pub fn stdin_is_terminal() -> bool {
    std::io::stdin().is_terminal()
}

/// stdin の端末から、字を出さずに 1 行読む。`prompt` は stderr に出す (stdout は結果の行のために空けておく)。
/// 戻る前に端末の設定を元に戻し、stderr に改行を出す。stdin が端末でなければ誤り。
pub fn read_hidden_line(prompt: &str) -> std::io::Result<Hidden> {
    let mut err = std::io::stderr();
    err.write_all(prompt.as_bytes())?;
    err.flush()?;
    let result = crate::sys::read_hidden();
    let _ = err.write_all(b"\n");
    let _ = err.flush();
    result
}

/// 1 単位 (Unix はバイト、Windows は UTF-16 の単位) を受けたときの行の様子。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// 続ける。
    More,
    /// 行が終わった (Enter。字を打った後の Ctrl+D・Ctrl+Z も)。
    Done,
    /// 何も打たずに Ctrl+D・Ctrl+Z で終えた。
    Eof,
    /// Ctrl+C。
    Interrupted,
}

/// 端末から来るバイトの行の編集 (Unix)。字はバイトのまま溜め、終わりに UTF-8 として読む。
#[derive(Default)]
pub struct ByteEditor {
    buf: Vec<u8>,
    esc: Esc,
}

/// 矢印キーなどの端末の制御の列 (ESC で始まる) を読み捨てる様子。
#[derive(Default, Clone, Copy, PartialEq, Eq)]
enum Esc {
    #[default]
    None,
    /// ESC を受けた。
    Start,
    /// `ESC [` (CSI): 0x40〜0x7E の字で終わる。
    Csi,
    /// `ESC O` (SS3): 次の 1 字で終わる。
    Ss3,
}

impl ByteEditor {
    pub fn new() -> Self {
        Self::default()
    }

    /// 1 バイト受ける。
    pub fn feed(&mut self, b: u8) -> Step {
        match self.esc {
            Esc::Start => {
                self.esc = match b {
                    b'[' => Esc::Csi,
                    b'O' => Esc::Ss3,
                    _ => Esc::None, // Alt と字の組 (ESC と 1 字)
                };
                return Step::More;
            }
            Esc::Csi => {
                if (0x40..=0x7e).contains(&b) {
                    self.esc = Esc::None;
                }
                return Step::More;
            }
            Esc::Ss3 => {
                self.esc = Esc::None;
                return Step::More;
            }
            Esc::None => {}
        }
        match b {
            b'\r' | b'\n' => Step::Done,
            0x03 => Step::Interrupted,
            0x04 if self.buf.is_empty() => Step::Eof,
            0x04 => Step::Done,
            0x7f | 0x08 => {
                // 1 字ぶん消す (UTF-8 の続きのバイトごと)
                while let Some(last) = self.buf.pop() {
                    if last & 0xc0 != 0x80 {
                        break;
                    }
                }
                Step::More
            }
            0x15 => {
                self.buf.clear();
                Step::More
            }
            0x1b => {
                self.esc = Esc::Start;
                Step::More
            }
            b if b < 0x20 => Step::More, // ほかの制御の字は捨てる
            b => {
                self.buf.push(b);
                Step::More
            }
        }
    }

    /// 溜めた字 (UTF-8 として読めないバイトは置き換える)。
    pub fn take(self) -> String {
        String::from_utf8_lossy(&self.buf).into_owned()
    }
}

/// console から来る UTF-16 の単位の行の編集 (Windows)。
#[derive(Default)]
pub struct WideEditor {
    buf: Vec<u16>,
}

impl WideEditor {
    pub fn new() -> Self {
        Self::default()
    }

    /// 1 単位受ける。
    pub fn feed(&mut self, u: u16) -> Step {
        match u {
            0x0d | 0x0a => Step::Done,
            0x03 => Step::Interrupted,
            0x04 | 0x1a if self.buf.is_empty() => Step::Eof,
            0x04 | 0x1a => Step::Done,
            0x08 | 0x7f => {
                // 1 字ぶん消す (サロゲートの組は 2 単位)
                if let Some(last) = self.buf.pop()
                    && (0xdc00..=0xdfff).contains(&last)
                    && self
                        .buf
                        .last()
                        .is_some_and(|h| (0xd800..=0xdbff).contains(h))
                {
                    self.buf.pop();
                }
                Step::More
            }
            0x15 => {
                self.buf.clear();
                Step::More
            }
            u if u < 0x20 => Step::More,
            u => {
                self.buf.push(u);
                Step::More
            }
        }
    }

    pub fn take(self) -> String {
        String::from_utf16_lossy(&self.buf)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(input: &[u8]) -> (Step, String) {
        let mut e = ByteEditor::new();
        for &b in input {
            let s = e.feed(b);
            if s != Step::More {
                return (s, e.take());
            }
        }
        (Step::More, e.take())
    }

    fn wide(input: &str) -> (Step, String) {
        let mut e = WideEditor::new();
        for u in input.encode_utf16() {
            let s = e.feed(u);
            if s != Step::More {
                return (s, e.take());
            }
        }
        (Step::More, e.take())
    }

    #[test]
    fn bytes_end_at_enter_and_edit() {
        assert_eq!(bytes(b"ntn_ab\r"), (Step::Done, "ntn_ab".into()));
        assert_eq!(bytes(b"ntn_ab\nrest"), (Step::Done, "ntn_ab".into()));
        assert_eq!(bytes(b"ntn_abX\x7f\r"), (Step::Done, "ntn_ab".into()));
        assert_eq!(bytes(b"ntn_abX\x08\r"), (Step::Done, "ntn_ab".into()));
        assert_eq!(bytes(b"junk\x15ntn_ab\r"), (Step::Done, "ntn_ab".into()));
        // 全角の字を Backspace で消すと、UTF-8 の 3 バイトをまとめて消す
        assert_eq!(bytes("ab全\x7f\r".as_bytes()), (Step::Done, "ab".into()));
        // 空の行で Backspace を押しても何も起きない
        assert_eq!(bytes(b"\x7f\x7fab\r"), (Step::Done, "ab".into()));
    }

    #[test]
    fn bytes_ctrl_keys() {
        assert_eq!(bytes(b"ntn\x03more\r").0, Step::Interrupted);
        assert_eq!(bytes(b"\x04"), (Step::Eof, String::new()));
        assert_eq!(bytes(b"ab\x04"), (Step::Done, "ab".into()));
        // ほかの制御の字 (Tab・Ctrl+Z など) は捨てる
        assert_eq!(bytes(b"a\tb\x1ac\r"), (Step::Done, "abc".into()));
    }

    #[test]
    fn bytes_skip_terminal_sequences() {
        // 矢印キー (CSI・SS3)、bracketed paste の印、Alt と字の組は値に入れない
        assert_eq!(bytes(b"a\x1b[Db\r"), (Step::Done, "ab".into()));
        assert_eq!(bytes(b"a\x1bOAb\r"), (Step::Done, "ab".into()));
        assert_eq!(
            bytes(b"\x1b[200~ntn_ab\x1b[201~\r"),
            (Step::Done, "ntn_ab".into())
        );
        assert_eq!(bytes(b"a\x1bxb\r"), (Step::Done, "ab".into()));
    }

    #[test]
    fn wide_units() {
        assert_eq!(wide("ntn_ab\r"), (Step::Done, "ntn_ab".into()));
        assert_eq!(wide("abX\u{8}\r"), (Step::Done, "ab".into()));
        assert_eq!(wide("ab😀\u{8}\r"), (Step::Done, "ab".into()));
        assert_eq!(wide("junk\u{15}ab\r"), (Step::Done, "ab".into()));
        assert_eq!(wide("a\u{3}").0, Step::Interrupted);
        assert_eq!(wide("\u{1a}"), (Step::Eof, String::new()));
        assert_eq!(wide("ab\u{1a}"), (Step::Done, "ab".into()));
        assert_eq!(wide("a\tb\r"), (Step::Done, "ab".into()));
    }

    #[test]
    fn debug_does_not_show_the_line() {
        let shown = format!("{:?}", Hidden::Line("ntn_SECRET".into()));
        assert!(!shown.contains("SECRET"), "{shown}");
    }
}
