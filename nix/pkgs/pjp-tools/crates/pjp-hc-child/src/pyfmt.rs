//! Python の文字の扱いの写し。pjp pack が SKILL.md を pack.py と同じに読むために使う (spec §6.7。Python 版が正解)。

/// Python の `str.splitlines()` の行の区切り (`\r\n` は 1 つの区切り)。
fn is_line_break(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r'
            | '\u{0b}'
            | '\u{0c}'
            | '\u{1c}'
            | '\u{1d}'
            | '\u{1e}'
            | '\u{85}'
            | '\u{2028}'
            | '\u{2029}'
    )
}

/// Python の `str.splitlines()`。最後の区切りの後ろが空なら、その空の行は出さない。
pub fn splitlines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        if !is_line_break(c) {
            continue;
        }
        lines.push(&text[start..i]);
        let mut end = i + c.len_utf8();
        if c == '\r'
            && let Some(&(j, '\n')) = chars.peek()
        {
            chars.next();
            end = j + 1;
        }
        start = end;
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// Python の `str.isspace()` の 1 字。Rust の `char::is_whitespace` に、Python が空白に数える `\x1c`〜`\x1f` を足したもの。
pub fn is_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// Python の `str.strip()`。
pub fn strip(s: &str) -> &str {
    s.trim_matches(is_space)
}

/// Python の `str.rstrip()`。
pub fn rstrip(s: &str) -> &str {
    s.trim_end_matches(is_space)
}

/// Python の正規表現 (str の pattern) の `\w` の 1 字: Unicode の英字・数字と `_`。
pub fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splitlines_like_python() {
        assert_eq!(splitlines("a\nb\r\nc\rd"), ["a", "b", "c", "d"]);
        assert_eq!(splitlines("a\n"), ["a"]);
        assert_eq!(splitlines("a\n\n"), ["a", ""]);
        assert_eq!(splitlines(""), Vec::<&str>::new());
        assert_eq!(splitlines("\n"), [""]);
        assert_eq!(splitlines("a\u{2028}b\u{85}c\u{0c}d"), ["a", "b", "c", "d"]);
        // \x1f は区切りでない
        assert_eq!(splitlines("a\u{1f}b"), ["a\u{1f}b"]);
    }

    #[test]
    fn strip_like_python() {
        assert_eq!(strip(" \t a b \u{3000}\u{1f}"), "a b");
        assert_eq!(rstrip("--- \t"), "---");
        assert!(is_space('\u{1c}'));
        assert!(!is_space('a'));
    }

    #[test]
    fn word_chars() {
        assert!(is_word('a'));
        assert!(is_word('_'));
        assert!(is_word('の'));
        assert!(is_word('9'));
        assert!(!is_word('-'));
        assert!(!is_word(' '));
        assert!(!is_word('`'));
    }
}
