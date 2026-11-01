//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 選ぶ画面の描画 (ui::draw_select)。ratatui の TestBackend に描いて、画面の文字と色を読む。
//!
//! - 上の行に経路と選んだ数、絞り込み中は絞り込みの文字
//! - org の行に [x] / [-] / [ ] と org の名前、repo の行に今の branch。既定 branch でない branch は黄、
//!   変更ありは赤
//! - 1 つも選んでいないときの知らせ
//! - 80 桁の端末でキーの説明が最後 (q でやめる) まで見える
//! - 狭い端末 (20 × 5・1 × 1) でも panic しない

mod common;

use std::path::PathBuf;

use common::{fg_of, shows};
use pjp_ghq_pull::repo::{Head, Info};
use pjp_ghq_pull::selection::{Item, Selection};
use pjp_ghq_pull::ui;
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::style::Color;

fn item(rel: &str, branch: &str, dirty: bool, selected: bool) -> Item {
    let (org, name) = pjp_ghq_pull::discover::split_rel(rel);
    Item {
        path: PathBuf::from(format!("/ghq/{rel}")),
        rel: rel.to_string(),
        org,
        name,
        info: Info {
            head: Head::Branch(branch.into()),
            default_branch: Some("main".into()),
            dirty,
        },
        selected,
    }
}

fn sample() -> Selection {
    Selection::new(vec![
        item("github.com/a/x", "main", false, true),
        item("github.com/a/y", "feature-zz", true, false),
        item("github.com/b/z", "main", false, true),
    ])
}

fn draw(sel: &Selection, w: u16, h: u16, route: &str) -> Buffer {
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    t.draw(|f| ui::draw_select(f, sel, route)).unwrap();
    t.backend().buffer().clone()
}

#[test]
fn shows_route_count_marks_branch_and_changes() {
    let buf = draw(&sample(), 80, 20, "git gh (gitViaGh)");
    assert!(shows(&buf, "経路: git gh (gitViaGh)"));
    assert!(shows(&buf, "選択 2/3"));
    assert!(shows(&buf, "[-] github.com/a"));
    assert!(shows(&buf, "[x] github.com/b"));
    assert!(shows(&buf, "[ ] y"));
    assert!(shows(&buf, "feature-zz"));
    assert!(shows(&buf, "変更あり"));
    assert_eq!(fg_of(&buf, "feature-zz"), Some(Color::Yellow));
    assert_eq!(fg_of(&buf, "変更あり"), Some(Color::Red));
}

#[test]
fn shows_filter_while_editing() {
    let mut sel = sample();
    sel.on_key(KeyEvent::new(KeyCode::Char('/'), KeyModifiers::NONE));
    sel.on_key(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::NONE));
    let buf = draw(&sel, 80, 20, "git");
    assert!(shows(&buf, "絞り込み: z"));
    assert!(shows(&buf, "github.com/b"));
    assert!(!shows(&buf, "github.com/a"));
}

#[test]
fn shows_notice_without_selection() {
    let mut sel = sample();
    sel.on_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::NONE));
    sel.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
    let buf = draw(&sel, 80, 20, "git");
    assert!(shows(&buf, "1 つも選んでいません"));
}

#[test]
fn tiny_terminal_does_not_panic() {
    let sel = sample();
    draw(&sel, 20, 5, "git");
    draw(&sel, 1, 1, "git");
    draw(&sel, 80, 2, "git");
}

#[test]
fn help_fits_80_columns() {
    let buf = draw(&sample(), 80, 20, "git gh (gitViaGh)");
    assert!(shows(&buf, "Enter:始める"));
    assert!(shows(&buf, "q:やめる"));
}
