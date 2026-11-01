//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 前回の選択 (state)。Enter で始めたときに外していた repo を覚え、次に開いたときの初期値にする。
//!
//! - 置き場所は $XDG_STATE_HOME/pjp-ghq-pull/deselected、無ければ ~/.local/state/pjp-ghq-pull/deselected
//!   (空や相対パスの XDG_STATE_HOME は使わない)
//! - 書いたものを読み戻せる。親のディレクトリが無ければ作る
//! - 無い・UTF-8 でない (壊れた) ファイルは空 (全部 on) として読む。# の行・空行・相対パスの行は飛ばす

mod common;

use std::collections::HashSet;
use std::ffi::OsString;
use std::path::PathBuf;

use common::Sandbox;
use pjp_ghq_pull::state;

#[test]
fn path_prefers_xdg_state_home() {
    assert_eq!(
        state::path_from(
            Some(OsString::from("/x/state")),
            Some(OsString::from("/home/u"))
        ),
        Some(PathBuf::from("/x/state/pjp-ghq-pull/deselected"))
    );
}

#[test]
fn path_falls_back_to_home() {
    let expected = Some(PathBuf::from(
        "/home/u/.local/state/pjp-ghq-pull/deselected",
    ));
    assert_eq!(
        state::path_from(None, Some(OsString::from("/home/u"))),
        expected
    );
    assert_eq!(
        state::path_from(Some(OsString::from("")), Some(OsString::from("/home/u"))),
        expected
    );
    assert_eq!(
        state::path_from(Some(OsString::from("rel")), Some(OsString::from("/home/u"))),
        expected
    );
    assert_eq!(state::path_from(None, None), None);
}

#[test]
fn round_trip() {
    let sb = Sandbox::new("st-round");
    let path = sb.path("state/deselected");
    let a = PathBuf::from("/ghq/github.com/a/x");
    let b = PathBuf::from("/ghq/github.com/b/y");
    state::save(&path, &[a.clone(), b.clone()]).unwrap();
    assert_eq!(state::load(&path), HashSet::from([a, b]));
}

#[test]
fn missing_file_is_empty() {
    let sb = Sandbox::new("st-missing");
    assert!(state::load(&sb.path("nope")).is_empty());
}

#[test]
fn garbage_file_is_empty() {
    let sb = Sandbox::new("st-garbage");
    let path = sb.path("deselected");
    std::fs::write(&path, [0xff, 0xfe, 0x00, b'/', b'x']).unwrap();
    assert!(state::load(&path).is_empty());
}

#[test]
fn comments_blank_and_relative_lines_are_ignored() {
    let sb = Sandbox::new("st-comments");
    let path = sb.path("deselected");
    std::fs::write(&path, "# comment\n/abs/x\n\nrelative/y\n").unwrap();
    assert_eq!(state::load(&path), HashSet::from([PathBuf::from("/abs/x")]));
}

#[test]
fn save_creates_parent_dirs() {
    let sb = Sandbox::new("st-mkdir");
    let path = sb.path("a/b/c/deselected");
    state::save(&path, &[]).unwrap();
    assert!(path.is_file());
    assert!(state::load(&path).is_empty());
}
