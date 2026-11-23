//! 出力の色。nix の setup.sh (`nix/scripts/setup.sh` の「表示の道具」) と同じ決まりで、出す先が端末で `NO_COLOR` が無い (空なら
//! 無いと読む) ときだけ、ANSI の色の字 (SGR) で包む。色の割り当ても setup.sh にそろえる (見出しは太字・`!!` の行は黄・⚠ は太い黄・
//! 落ちた・止めたは赤・✔ は緑・↷ と · は薄く)。
//!
//! 包むのは出すときだけで、字そのもの (締めの表・締めの行) は変えない。付けるかの判定はここ (`enabled`) だけで決める。

use crate::process::{Stream, Sys};

/// 色を付けるか: 出す先が端末で、`NO_COLOR` が無いか空 (setup.sh の `[[ -t 1 && -z ${NO_COLOR:-} ]]` と同じ。値は見ない。
/// <https://no-color.org/>)。
pub fn enabled(is_terminal: bool, no_color: Option<&str>) -> bool {
    is_terminal && no_color.is_none_or(str::is_empty)
}

/// 色を付けるかを決めた筆。`OFF` なら字をそのまま返す。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Paint {
    on: bool,
}

impl Paint {
    pub const OFF: Paint = Paint { on: false };
    pub const ON: Paint = Paint { on: true };

    /// `stream` に出す字の筆 (端末かと `NO_COLOR` は `sys` から読む)。
    pub fn detect(sys: &dyn Sys, stream: Stream) -> Paint {
        Paint {
            on: enabled(sys.is_terminal(stream), sys.env("NO_COLOR").as_deref()),
        }
    }

    fn wrap(self, sgr: &str, text: &str) -> String {
        if self.on && !text.is_empty() {
            format!("\u{1b}[{sgr}m{text}\u{1b}[0m")
        } else {
            text.to_string()
        }
    }

    /// 太字 (見出し。setup.sh の `c_bold`)
    pub fn bold(self, text: &str) -> String {
        self.wrap("1", text)
    }

    /// 薄く (↷・· の行。`c_dim`)
    pub fn dim(self, text: &str) -> String {
        self.wrap("2", text)
    }

    /// 緑 (✔。`c_green`)
    pub fn green(self, text: &str) -> String {
        self.wrap("32", text)
    }

    /// 黄 (手順を止めない警告の `!!` の行。setup.sh の `warn` の `c_yellow`)
    pub fn yellow(self, text: &str) -> String {
        self.wrap("33", text)
    }

    /// 赤 (落ちた・止めた行と、runner が動けないときの `!!` の行。setup.sh の `ERROR`・✖ の `c_red`)
    pub fn red(self, text: &str) -> String {
        self.wrap("31", text)
    }

    /// 太い黄 (直すことがある ⚠ の行と ⚠️ の締めの行。setup.sh の警告のまとめの `c_warn`)
    pub fn warn(self, text: &str) -> String {
        self.wrap("1;33", text)
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 色を付けるのは、出す先が端末で NO_COLOR が無いときだけ。空の NO_COLOR は無いと読み、値は見ない
    //! - 端末かは出す先 (stdout・stderr) ごとに見る
    //! - 包んだ字は SGR で始めて reset (`ESC[0m`) で閉じる。`OFF` なら字のまま、空の字は包まない

    use super::*;
    use crate::testutil::FakeSys;

    #[test]
    fn colors_only_on_a_terminal_without_no_color() {
        assert!(enabled(true, None));
        assert!(enabled(true, Some("")), "空の NO_COLOR は無いと読む");
        assert!(!enabled(true, Some("1")));
        assert!(!enabled(true, Some("0")), "NO_COLOR の値は見ない");
        assert!(!enabled(false, None), "端末でなければ付けない");
        assert!(!enabled(false, Some("1")));
    }

    #[test]
    fn detect_reads_each_stream_and_no_color() {
        let sys = || FakeSys::new(|_| unreachable!());
        assert_eq!(Paint::detect(&sys(), Stream::Stdout), Paint::OFF);
        let tty = sys().with_terminal(Stream::Stdout);
        assert_eq!(Paint::detect(&tty, Stream::Stdout), Paint::ON);
        assert_eq!(Paint::detect(&tty, Stream::Stderr), Paint::OFF);
        let err_tty = sys().with_terminal(Stream::Stderr);
        assert_eq!(Paint::detect(&err_tty, Stream::Stderr), Paint::ON);
        assert_eq!(Paint::detect(&err_tty, Stream::Stdout), Paint::OFF);
        let no_color = sys()
            .with_terminal(Stream::Stdout)
            .with_env("NO_COLOR", "1");
        assert_eq!(Paint::detect(&no_color, Stream::Stdout), Paint::OFF);
        let empty = sys().with_terminal(Stream::Stdout).with_env("NO_COLOR", "");
        assert_eq!(Paint::detect(&empty, Stream::Stdout), Paint::ON);
    }

    #[test]
    fn wraps_with_sgr_and_reset() {
        let p = Paint::ON;
        for (got, want) in [
            (p.bold("x"), "\u{1b}[1mx\u{1b}[0m"),
            (p.dim("x"), "\u{1b}[2mx\u{1b}[0m"),
            (p.green("x"), "\u{1b}[32mx\u{1b}[0m"),
            (p.yellow("x"), "\u{1b}[33mx\u{1b}[0m"),
            (p.red("x"), "\u{1b}[31mx\u{1b}[0m"),
            (p.warn("⚠ x"), "\u{1b}[1;33m⚠ x\u{1b}[0m"),
        ] {
            assert_eq!(got, want);
        }
        assert_eq!(p.bold(""), "", "空の字は包まない");
        assert_eq!(Paint::OFF.warn("⚠ x"), "⚠ x");
        assert_eq!(Paint::OFF.red(""), "");
    }
}
