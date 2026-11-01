//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 実行中の画面の描画 (ui::draw_run)。ratatui の TestBackend に描いて、画面の文字を読む。
//!
//! - 上の行に経路・完了 n/m・確認待ち k。一覧に repo ごとの状態 (更新 +N・fetch 中・確認待ち など)
//! - 確認待ちの欄に、今の問いの理由と選べること ([s] 何もしない など)。d で詳細 (git status -sb など) が出る
//! - 全部が終われば「完了」、q の後は「やめます」を出す
//! - 80 × 24 の端末でも、どの理由の問いも、理由の全文と選べること全部 ([d] 詳細も) と知らせが見える
//! - 今の問いの repo の名前を目立たせ、答えを受けなかったときは知らせを出す
//! - 狭い端末でも panic しない

mod common;

use common::shows;
use pjp_ghq_pull::flow::{Choice, How, Outcome, Phase, Question, Reason};
use pjp_ghq_pull::repo::{Busy, Head};
use pjp_ghq_pull::run::Run;
use pjp_ghq_pull::runner::Msg;
use pjp_ghq_pull::ui;
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

fn question() -> Question {
    Question {
        reason: Reason::Diverged {
            ahead: 1,
            behind: 2,
        },
        choices: vec![Choice::Skip, Choice::Merge, Choice::Rebase],
        default_branch: Some("main".into()),
        upstream: Some("refs/remotes/origin/main".into()),
        detail: "## main...origin/main [ahead 1, behind 2]".into(),
    }
}

fn sample() -> Run {
    let mut run = Run::new(vec![
        "github.com/a/x".into(),
        "github.com/a/y".into(),
        "github.com/b/z".into(),
    ]);
    run.on_msg(Msg::Done(
        0,
        Outcome::Updated {
            how: How::FastForward,
            commits: 2,
            branch: "main".into(),
        },
    ));
    run.on_msg(Msg::Done(1, Outcome::Ask(question())));
    run.on_msg(Msg::Phase(2, Phase::Fetching));
    run
}

fn draw(run: &Run, w: u16, h: u16) -> Buffer {
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    t.draw(|f| ui::draw_run(f, run, "git gh (gitViaGh)"))
        .unwrap();
    t.backend().buffer().clone()
}

#[test]
fn shows_counts_statuses_and_question() {
    let buf = draw(&sample(), 100, 30);
    assert!(shows(&buf, "経路: git gh (gitViaGh)"));
    assert!(shows(&buf, "完了 1/3"));
    assert!(shows(&buf, "確認待ち 1"));
    assert!(shows(&buf, "更新 +2"));
    assert!(shows(&buf, "fetch 中"));
    assert!(shows(&buf, "分岐している (ahead 1 / behind 2)"));
    assert!(shows(&buf, "[s] 何もしない"));
    assert!(shows(&buf, "[m] merge commit を作る"));
    assert!(shows(&buf, "[r] rebase する"));
    assert!(!shows(&buf, "[ahead 1, behind 2]"));
}

#[test]
fn detail_is_shown_after_d() {
    let mut run = sample();
    run.on_key(KeyEvent::new(KeyCode::Char('d'), KeyModifiers::NONE));
    let buf = draw(&run, 100, 30);
    assert!(shows(&buf, "## main...origin/main [ahead 1, behind 2]"));
}

#[test]
fn shows_done_when_finished() {
    let mut run = Run::new(vec!["github.com/a/x".into()]);
    run.on_msg(Msg::Done(0, Outcome::UpToDate { ahead: 0 }));
    let buf = draw(&run, 100, 20);
    assert!(shows(&buf, "完了 1/1"));
    assert!(shows(&buf, "最新"));
    assert!(shows(&buf, "Enter"));
}

#[test]
fn tiny_terminal_does_not_panic() {
    let run = sample();
    draw(&run, 20, 5);
    draw(&run, 1, 1);
    draw(&run, 100, 3);
}

fn ask_one(reason: Reason, choices: Vec<Choice>) -> Run {
    let mut run = Run::new(vec![
        "github.com/pollenjp/dotfiles-private".into(),
        "github.com/a/y".into(),
    ]);
    run.on_msg(Msg::Done(
        0,
        Outcome::Ask(Question {
            reason,
            choices,
            default_branch: Some("main".into()),
            upstream: Some("refs/remotes/origin/main".into()),
            detail: String::new(),
        }),
    ));
    run.on_msg(Msg::Phase(1, Phase::Fetching));
    run
}

#[test]
fn every_choice_is_visible_at_80x24() {
    use Choice::*;
    let cases = vec![
        (
            Reason::NotOnDefault {
                head: Head::Branch("feat/pjp-ghq-pull".into()),
                default_branch: "main".into(),
                behind: 3,
            },
            vec![Skip, BranchOnly, Checkout],
        ),
        (Reason::Dirty { behind: 1 }, vec![Skip, TryFf]),
        (
            Reason::Diverged {
                ahead: 2,
                behind: 5,
            },
            vec![Skip, Merge, Rebase],
        ),
        (
            Reason::FetchFailed {
                timed_out: true,
                stderr: "fatal: x".into(),
            },
            vec![Skip, Retry],
        ),
        (Reason::Busy(Busy::IndexLock), vec![Skip]),
        (
            Reason::UpstreamNotOrigin {
                upstream: "upstream/main".into(),
            },
            vec![Skip],
        ),
    ];
    for (reason, choices) in cases {
        let run = ask_one(reason.clone(), choices.clone());
        let buf = draw(&run, 80, 24);
        assert!(shows(&buf, &reason.label()), "{reason:?}");
        for c in &choices {
            let text = format!("[{}] {}", c.key(), c.label("main"));
            assert!(shows(&buf, &text), "{text} が見えない: {reason:?}");
        }
        assert!(shows(&buf, "[d] 詳細"), "{reason:?}");
    }
}

#[test]
fn notices_are_visible_at_80() {
    let mut run = ask_one(
        Reason::Dirty { behind: 1 },
        vec![Choice::Skip, Choice::TryFf],
    );
    run.on_key(KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE));
    assert!(shows(&draw(&run, 80, 24), "やめます"));

    let mut run = Run::new(vec!["github.com/a/x".into()]);
    run.on_msg(Msg::Done(0, Outcome::UpToDate { ahead: 0 }));
    assert!(shows(&draw(&run, 80, 24), "Enter か q で閉じる"));
}

#[test]
fn current_repo_is_marked_and_refusal_is_shown() {
    let t0 = std::time::Instant::now();
    let mut run = ask_one(
        Reason::Dirty { behind: 1 },
        vec![Choice::Skip, Choice::TryFf],
    );
    let buf = draw(&run, 80, 24);
    assert!(shows(&buf, "▶ github.com/pollenjp/dotfiles-private"));
    run.on_key_at(
        KeyEvent::new(KeyCode::Char('f'), KeyModifiers::NONE),
        t0 + std::time::Duration::from_millis(10),
    );
    let buf = draw(&run, 80, 24);
    assert!(shows(&buf, "受けなかった"));
}
