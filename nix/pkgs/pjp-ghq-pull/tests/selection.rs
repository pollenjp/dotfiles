//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 選ぶ画面の model (selection)。画面なしで、キーを送って木の on/off を確かめる。
//!
//! - org の印は、下の repo が全部 on なら [x]、一部なら [-]、全部 off なら [ ] (絞り込みによらず org の全部で決める)
//! - Space: repo の行は on/off、org の行は対象の repo が全部 on なら全部 off、でなければ全部 on
//! - a / n は全選択 / 全解除。絞り込み中は絞り込んだ repo だけ
//! - / で絞り込み (相対パスに含むか。大文字小文字は区別しない)。入力中の文字は命令にならず、Enter で確定、Esc で消す
//! - ← → で org を畳む / 開く (repo の行の ← は org の行へ移って畳む)。行が減ってもカーソルは行の中に収まる
//! - Enter は 1 つも選んでいなければ始めずに知らせる。q・Esc・Ctrl-C はやめる
//! - 前回の選択 (外していた repo の組) を初期値にし、組に無い repo は on

use std::collections::HashSet;
use std::path::PathBuf;

use pjp_ghq_pull::repo::{Head, Info};
use pjp_ghq_pull::selection::{Action, Item, Mark, Row, Selection};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

fn item(rel: &str) -> Item {
    let (org, name) = pjp_ghq_pull::discover::split_rel(rel);
    Item {
        path: PathBuf::from(format!("/ghq/{rel}")),
        rel: rel.to_string(),
        org,
        name,
        info: Info {
            head: Head::Branch("main".into()),
            default_branch: Some("main".into()),
            dirty: false,
        },
        selected: true,
    }
}

fn sel(rels: &[&str]) -> Selection {
    Selection::new(rels.iter().map(|r| item(r)).collect())
}

fn key(sel: &mut Selection, code: KeyCode) -> Action {
    sel.on_key(KeyEvent::new(code, KeyModifiers::NONE))
}

fn typed(sel: &mut Selection, text: &str) {
    for c in text.chars() {
        key(sel, KeyCode::Char(c));
    }
}

fn names(sel: &Selection, paths: Vec<PathBuf>) -> Vec<String> {
    let _ = sel;
    paths
        .iter()
        .map(|p| p.to_string_lossy().trim_start_matches("/ghq/").to_string())
        .collect()
}

/// rows の中で、その行がどこにあるか
fn row_of(sel: &Selection, row: Row) -> usize {
    sel.rows().iter().position(|r| *r == row).unwrap()
}

/// カーソルを row の行へ動かす
fn go_row(sel: &mut Selection, row: Row) {
    let index = row_of(sel, row);
    go(sel, index);
}

/// カーソルを index の行へ動かす
fn go(sel: &mut Selection, index: usize) {
    key(sel, KeyCode::Home);
    for _ in 0..index {
        key(sel, KeyCode::Down);
    }
}

#[test]
fn orgs_and_repos_are_sorted_and_expanded() {
    let s = sel(&["github.com/b/z", "github.com/a/y", "github.com/a/x"]);
    assert_eq!(
        s.rows(),
        vec![
            Row::Org(0),
            Row::Repo(0),
            Row::Repo(1),
            Row::Org(1),
            Row::Repo(2)
        ]
    );
    assert_eq!(s.orgs()[0].name, "github.com/a");
    assert_eq!(s.items()[0].name, "x");
    assert_eq!(s.items()[2].rel, "github.com/b/z");
}

#[test]
fn marks_follow_repos() {
    let mut s = sel(&["github.com/a/x", "github.com/a/y"]);
    assert_eq!(s.mark(0), Mark::All);
    go_row(&mut s, Row::Repo(0));
    key(&mut s, KeyCode::Char(' '));
    assert_eq!(s.mark(0), Mark::Partial);
    go_row(&mut s, Row::Repo(1));
    key(&mut s, KeyCode::Char(' '));
    assert_eq!(s.mark(0), Mark::None);
}

#[test]
fn toggling_org_row_flips_all() {
    let mut s = sel(&["github.com/a/x", "github.com/a/y"]);
    go(&mut s, 0);
    key(&mut s, KeyCode::Char(' '));
    assert_eq!(s.mark(0), Mark::None);
    key(&mut s, KeyCode::Char(' '));
    assert_eq!(s.mark(0), Mark::All);
}

#[test]
fn toggling_partial_org_turns_all_on() {
    let mut s = sel(&["github.com/a/x", "github.com/a/y"]);
    go_row(&mut s, Row::Repo(1));
    key(&mut s, KeyCode::Char(' '));
    go(&mut s, 0);
    key(&mut s, KeyCode::Char(' '));
    assert_eq!(s.mark(0), Mark::All);
}

#[test]
fn select_all_and_none() {
    let mut s = sel(&["github.com/a/x", "github.com/b/y"]);
    key(&mut s, KeyCode::Char('n'));
    assert!(s.selected().is_empty());
    key(&mut s, KeyCode::Char('a'));
    assert_eq!(s.selected().len(), 2);
}

#[test]
fn filter_limits_rows_and_bulk_ops() {
    let mut s = sel(&[
        "github.com/a/dotfiles",
        "github.com/a/foo",
        "github.com/b/bar",
    ]);
    key(&mut s, KeyCode::Char('/'));
    typed(&mut s, "DOT");
    key(&mut s, KeyCode::Enter);
    assert_eq!(s.filter(), "DOT");
    assert!(!s.editing_filter());
    assert_eq!(s.rows(), vec![Row::Org(0), Row::Repo(0)]);
    key(&mut s, KeyCode::Char('n'));
    assert_eq!(
        names(&s, s.selected()),
        vec!["github.com/a/foo", "github.com/b/bar"]
    );
    assert_eq!(s.mark(0), Mark::Partial);
}

#[test]
fn org_toggle_under_filter_only_affects_matching() {
    let mut s = sel(&["github.com/a/dotfiles", "github.com/a/foo"]);
    key(&mut s, KeyCode::Char('/'));
    typed(&mut s, "dot");
    key(&mut s, KeyCode::Enter);
    go(&mut s, 0);
    key(&mut s, KeyCode::Char(' '));
    assert_eq!(names(&s, s.deselected()), vec!["github.com/a/dotfiles"]);
}

#[test]
fn typing_in_filter_does_not_run_commands() {
    let mut s = sel(&["github.com/a/x"]);
    key(&mut s, KeyCode::Char('/'));
    assert!(s.editing_filter());
    assert_eq!(key(&mut s, KeyCode::Char('q')), Action::None);
    typed(&mut s, "an ");
    assert_eq!(s.filter(), "qan ");
    assert_eq!(s.selected().len(), 1);
    key(&mut s, KeyCode::Backspace);
    assert_eq!(s.filter(), "qan");
    assert_eq!(key(&mut s, KeyCode::Esc), Action::None);
    assert_eq!(s.filter(), "");
    assert!(!s.editing_filter());
}

#[test]
fn fold_and_unfold() {
    let mut s = sel(&["github.com/a/x", "github.com/b/y"]);
    go(&mut s, 0);
    key(&mut s, KeyCode::Left);
    assert_eq!(s.rows(), vec![Row::Org(0), Row::Org(1), Row::Repo(1)]);
    key(&mut s, KeyCode::Right);
    assert_eq!(s.rows().len(), 4);
}

#[test]
fn left_on_repo_moves_to_org() {
    let mut s = sel(&["github.com/a/x", "github.com/a/y", "github.com/b/z"]);
    go_row(&mut s, Row::Repo(1));
    key(&mut s, KeyCode::Left);
    assert_eq!(s.cursor(), 0);
    assert!(!s.orgs()[0].expanded);
}

#[test]
fn cursor_clamps_after_filter() {
    let mut s = sel(&["github.com/a/x", "github.com/a/y", "github.com/b/z"]);
    key(&mut s, KeyCode::End);
    assert_eq!(s.cursor(), 4);
    key(&mut s, KeyCode::Char('/'));
    typed(&mut s, "a/x");
    assert!(s.cursor() < s.rows().len());
    key(&mut s, KeyCode::Down);
    assert!(s.cursor() < s.rows().len());
}

#[test]
fn enter_without_selection_sets_notice() {
    let mut s = sel(&["github.com/a/x"]);
    key(&mut s, KeyCode::Char('n'));
    assert_eq!(key(&mut s, KeyCode::Enter), Action::None);
    assert!(s.notice().is_some());
    key(&mut s, KeyCode::Char('a'));
    assert!(s.notice().is_none());
    assert_eq!(key(&mut s, KeyCode::Enter), Action::Start);
}

#[test]
fn quit_keys() {
    for code in [KeyCode::Char('q'), KeyCode::Esc] {
        let mut s = sel(&["github.com/a/x"]);
        assert_eq!(key(&mut s, code), Action::Quit);
    }
    let mut s = sel(&["github.com/a/x"]);
    assert_eq!(
        s.on_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL)),
        Action::Quit
    );
}

#[test]
fn deselected_set_restores_choice_and_new_repos_are_on() {
    let items = vec![
        item("github.com/a/x"),
        item("github.com/a/y"),
        item("github.com/b/new"),
    ];
    let off = HashSet::from([PathBuf::from("/ghq/github.com/a/x")]);
    let s = Selection::with_deselected(items, &off);
    assert_eq!(names(&s, s.deselected()), vec!["github.com/a/x"]);
    assert_eq!(
        names(&s, s.selected()),
        vec!["github.com/a/y", "github.com/b/new"]
    );
}
