//! check: claude-selector-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 端末の側のうち、端末を開かずに確かめられるもの (term::clip・term::map_key)。描くこと自体は試験しない
//! (nix/README.md の「claude-selector (cs)」に、手で確かめる手順がある)。
//!
//! - 行を端末の幅に収める: 収まる行はそのまま。はみ出す行は収まる所まで残して「…」を付け、幅を超えない (日本語の字は 2 桁で数え、
//!   字の途中で切らない)。見せ方は塊ごとに残す。制御文字は `\n`・`\u{1b}` の形にしてから数える
//! - キーの写し方: Ctrl+C → やめる、Ctrl+U → 字を消す、Ctrl+P・Ctrl+N・Tab・Shift+Tab → 上下、Ctrl+H → Backspace、Ctrl+Alt+字
//!   (Windows の AltGr) → 字。ほかの Ctrl+字・F キーは使わない

use claude_selector::term::{clip, map_key};
use claude_selector::ui::{Key, Line, Span, Style};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use unicode_width::UnicodeWidthStr;

fn line(parts: &[(&str, Style)]) -> Line {
    Line {
        spans: parts
            .iter()
            .map(|(t, s)| Span {
                text: t.to_string(),
                style: *s,
            })
            .collect(),
    }
}

fn width(l: &Line) -> usize {
    UnicodeWidthStr::width(l.text().as_str())
}

#[test]
fn clip_keeps_short_lines() {
    let l = line(&[("$ ", Style::Dim), ("claude -c", Style::Command)]);
    assert_eq!(clip(&l, 11), l);
    assert_eq!(clip(&l, 80), l);
}

#[test]
fn clip_cuts_with_an_ellipsis() {
    let l = line(&[("$ ", Style::Dim), ("claude --effort max", Style::Command)]);
    let c = clip(&l, 10);
    assert_eq!(c.text(), "$ claude …");
    assert_eq!(width(&c), 10);
    assert_eq!(c.spans[0].style, Style::Dim);
    assert_eq!(c.spans[1].style, Style::Command);
    // 日本語の字は 2 桁。字の途中で切らない
    let l = line(&[("質問です", Style::Plain)]);
    for w in 1..8 {
        let c = clip(&l, w);
        assert!(width(&c) <= w, "{w}: {:?}", c.text());
        assert!(c.text().ends_with('…'), "{w}: {:?}", c.text());
    }
    assert_eq!(clip(&l, 6).text(), "質問…");
    assert_eq!(clip(&l, 5).text(), "質問…");
    // 1 つ目の塊で切れたら、後ろの塊は出さない
    let l = line(&[("abcdef", Style::Plain), ("ghi", Style::Dim)]);
    let c = clip(&l, 4);
    assert_eq!(c.text(), "abc…");
    assert_eq!(c.spans.len(), 1);
}

fn key(code: KeyCode, m: KeyModifiers) -> Option<Key> {
    map_key(KeyEvent::new(code, m))
}

#[test]
fn keys() {
    let ctrl = KeyModifiers::CONTROL;
    let none = KeyModifiers::NONE;
    assert_eq!(key(KeyCode::Char('c'), ctrl), Some(Key::Interrupt));
    assert_eq!(key(KeyCode::Char('u'), ctrl), Some(Key::ClearLine));
    assert_eq!(key(KeyCode::Char('p'), ctrl), Some(Key::Up));
    assert_eq!(key(KeyCode::Char('n'), ctrl), Some(Key::Down));
    assert_eq!(key(KeyCode::Char('x'), ctrl), None);
    assert_eq!(key(KeyCode::Char('c'), none), Some(Key::Char('c')));
    assert_eq!(key(KeyCode::Char('作'), none), Some(Key::Char('作')));
    assert_eq!(key(KeyCode::Tab, none), Some(Key::Down));
    assert_eq!(key(KeyCode::BackTab, KeyModifiers::SHIFT), Some(Key::Up));
    assert_eq!(key(KeyCode::Esc, none), Some(Key::Esc));
    assert_eq!(key(KeyCode::Enter, none), Some(Key::Enter));
    assert_eq!(key(KeyCode::Backspace, none), Some(Key::Backspace));
    assert_eq!(key(KeyCode::Left, none), Some(Key::Left));
    assert_eq!(key(KeyCode::F(1), none), None);
}

#[test]
fn clip_shows_control_characters() {
    let l = line(&[("a\nb", Style::Plain), ("\u{1b}[31m", Style::Command)]);
    let c = clip(&l, 80);
    assert_eq!(c.text(), "a\\nb\\u{1b}[31m");
    assert!(!c.text().chars().any(char::is_control));
    // 見える形にしてから幅を数える
    let c = clip(&l, 6);
    assert_eq!(c.text(), "a\\nb\\…");
    assert!(width(&c) <= 6);
}

#[test]
fn keys_ctrl_h_and_altgr() {
    let ctrl = KeyModifiers::CONTROL;
    assert_eq!(key(KeyCode::Char('h'), ctrl), Some(Key::Backspace));
    // Windows は AltGr で打った字を Ctrl+Alt で届ける
    assert_eq!(
        key(KeyCode::Char('@'), ctrl | KeyModifiers::ALT),
        Some(Key::Char('@'))
    );
    assert_eq!(
        key(KeyCode::Char('c'), ctrl | KeyModifiers::ALT),
        Some(Key::Char('c'))
    );
}
