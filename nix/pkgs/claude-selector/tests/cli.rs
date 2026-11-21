//! check: claude-selector-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 実行ファイル (claude-selector) を端末でない所から起こす。
//!
//! - 入力か出力が端末でなければ、選ぶ画面を出さず、何も起こさずに 2 で終わってわけを出す (cs の後ろの引数があっても同じ)

use std::process::{Command, Stdio};

#[test]
fn refuses_without_a_terminal() {
    let out = Command::new(env!("CARGO_BIN_EXE_claude-selector"))
        .args(["-c", "質問"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("端末で打ってください"), "{err}");
    assert!(out.stdout.is_empty());
}
