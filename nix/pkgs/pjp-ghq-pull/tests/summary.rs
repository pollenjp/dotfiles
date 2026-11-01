//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 終えたときに端末に残すまとめ (summary)。
//!
//! - 先頭の行に repo の数と内訳、続けて 更新・最新・スキップ・失敗 の順に repo を並べる (無い見出しは出さない)
//! - 更新は取り込んだ commit の数とやり方、最新は未 push の commit の数、スキップはわけ
//! - 失敗は、何が失敗したかと、git の stderr の最後の 3 行 (空行を除く)
//! - 終了コードは失敗があれば 1、無ければ 0

use pjp_ghq_pull::flow::{How, Outcome};
use pjp_ghq_pull::summary;

fn sample() -> Vec<(String, Outcome)> {
    vec![
        (
            "github.com/c/w".into(),
            Outcome::Failed {
                what: "fetch に失敗した".into(),
                stderr: "one\ntwo\n\nthree\nfour\nfive\n".into(),
                conflict: false,
            },
        ),
        (
            "github.com/a/x".into(),
            Outcome::Updated {
                how: How::FastForward,
                commits: 2,
                branch: "main".into(),
            },
        ),
        (
            "github.com/b/z".into(),
            Outcome::Skipped {
                reason: "分岐している (ahead 1 / behind 1)".into(),
            },
        ),
        ("github.com/a/y".into(), Outcome::UpToDate { ahead: 2 }),
    ]
}

#[test]
fn sections_in_order_with_counts() {
    let text = summary::render(&sample());
    let first = text.lines().next().unwrap();
    assert_eq!(
        first,
        "pjp-ghq-pull: 4 repo (更新 1・最新 1・スキップ 1・失敗 1)"
    );
    let pos = |s: &str| text.find(s).unwrap_or_else(|| panic!("{s} が無い: {text}"));
    assert!(pos("\n更新") < pos("\n最新"));
    assert!(pos("\n最新") < pos("\nスキップ"));
    assert!(pos("\nスキップ") < pos("\n失敗"));
    assert!(text.contains("+2 (fast-forward)"));
    assert!(text.contains("未 push の commit 2"));
    assert!(text.contains("分岐している (ahead 1 / behind 1)"));
    assert!(text.contains("fetch に失敗した"));
}

#[test]
fn failure_shows_last_three_stderr_lines() {
    let text = summary::render(&sample());
    assert!(text.contains("three"));
    assert!(text.contains("four"));
    assert!(text.contains("five"));
    assert!(!text.contains("two"));
}

#[test]
fn empty_sections_are_omitted() {
    let text = summary::render(&[("github.com/a/x".into(), Outcome::UpToDate { ahead: 0 })]);
    assert!(!text.contains("\n更新"));
    assert!(!text.contains("\n失敗"));
    assert!(text.contains("\n最新"));
}

#[test]
fn exit_code_reflects_failures() {
    assert_eq!(summary::exit_code(&sample()), 1);
    assert_eq!(
        summary::exit_code(&[("x".into(), Outcome::UpToDate { ahead: 0 })]),
        0
    );
}

#[test]
fn how_text_names_each_way() {
    use pjp_ghq_pull::summary::how_text;
    assert_eq!(how_text(How::FastForward, "main"), "fast-forward");
    assert_eq!(
        how_text(How::Switched, "main"),
        "main に切り替えて fast-forward"
    );
    assert_eq!(
        how_text(How::BranchOnly, "main"),
        "checkout せずに main を進めた"
    );
}
