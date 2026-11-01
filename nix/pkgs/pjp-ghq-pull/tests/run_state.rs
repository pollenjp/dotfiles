//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 実行中の画面の model (run)。画面なしで、作業の列からの知らせとキーを送る。
//!
//! - 問いは来た順に確認待ちに並び、答えると、その repo の続き (Job::Answer) を作業の列に積んで次の問いへ移る。
//!   s はその場でスキップにする。答えのキーは確認待ちの欄に focus があるときだけ、今の問いで選べるものだけ効く
//! - d で詳細を出し入れし、Tab で一覧と確認待ちを行き来する
//! - q (と Ctrl-C) は、確認待ちとまだ始めていない repo をスキップにし、動いている作業が終わってから閉じる。
//!   やめた後に届いた問いもスキップにする
//! - 全部が終わり確認待ちも空なら「完了」で、Enter・q・Esc で閉じる

use pjp_ghq_pull::flow::{Choice, How, Outcome, Phase, Question, Reason};
use pjp_ghq_pull::run::{Effect, Focus, Run, Status};
use pjp_ghq_pull::runner::{Job, Msg};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

fn q(reason: Reason, choices: Vec<Choice>) -> Question {
    Question {
        reason,
        choices,
        default_branch: Some("main".into()),
        upstream: Some("refs/remotes/origin/main".into()),
        detail: "## main...origin/main".into(),
    }
}

fn diverged() -> Question {
    q(
        Reason::Diverged {
            ahead: 1,
            behind: 2,
        },
        vec![Choice::Skip, Choice::Merge, Choice::Rebase],
    )
}

fn dirty() -> Question {
    q(
        Reason::Dirty { behind: 1 },
        vec![Choice::Skip, Choice::TryFf],
    )
}

fn press(run: &mut Run, code: KeyCode) -> Vec<Effect> {
    run.on_key(KeyEvent::new(code, KeyModifiers::NONE))
}

fn run_of(n: usize) -> Run {
    Run::new((0..n).map(|i| format!("github.com/a/r{i}")).collect())
}

#[test]
fn ask_enters_waiting_queue() {
    let mut run = run_of(2);
    assert!(
        run.on_msg(Msg::Done(0, Outcome::Ask(diverged())))
            .is_empty()
    );
    assert_eq!(run.waiting(), 1);
    assert_eq!(run.status(0), &Status::Waiting(diverged()));
    assert_eq!(run.current_question().map(|(id, _)| id), Some(0));
}

#[test]
fn answer_key_enqueues_and_moves_to_next() {
    let mut run = run_of(2);
    run.on_msg(Msg::Done(0, Outcome::Ask(diverged())));
    run.on_msg(Msg::Done(1, Outcome::Ask(dirty())));
    assert_eq!(run.focus(), Focus::Questions);
    let effects = press(&mut run, KeyCode::Char('m'));
    assert_eq!(
        effects,
        vec![Effect::Enqueue(Job::Answer(0, diverged(), Choice::Merge))]
    );
    assert_eq!(run.status(0), &Status::Queued);
    assert_eq!(run.waiting(), 1);
    assert_eq!(run.current_question().map(|(id, _)| id), Some(1));
}

#[test]
fn skip_key_finalizes_immediately() {
    let mut run = run_of(1);
    run.on_msg(Msg::Done(0, Outcome::Ask(diverged())));
    let effects = press(&mut run, KeyCode::Char('s'));
    assert!(!effects.contains(&Effect::Exit) || run.finished());
    assert_eq!(
        run.status(0),
        &Status::Final(Outcome::Skipped {
            reason: diverged().reason.label()
        })
    );
    assert_eq!(run.waiting(), 0);
}

#[test]
fn keys_ignored_when_list_focused() {
    let mut run = run_of(1);
    run.on_msg(Msg::Done(0, Outcome::Ask(diverged())));
    press(&mut run, KeyCode::Tab);
    assert_eq!(run.focus(), Focus::List);
    assert!(press(&mut run, KeyCode::Char('m')).is_empty());
    assert_eq!(run.waiting(), 1);
    press(&mut run, KeyCode::Tab);
    assert_eq!(run.focus(), Focus::Questions);
}

#[test]
fn unknown_choice_key_is_ignored() {
    let mut run = run_of(1);
    run.on_msg(Msg::Done(0, Outcome::Ask(dirty())));
    assert!(press(&mut run, KeyCode::Char('m')).is_empty());
    assert_eq!(run.waiting(), 1);
}

#[test]
fn detail_toggles() {
    let mut run = run_of(1);
    run.on_msg(Msg::Done(0, Outcome::Ask(dirty())));
    assert!(!run.show_detail());
    press(&mut run, KeyCode::Char('d'));
    assert!(run.show_detail());
    press(&mut run, KeyCode::Char('d'));
    assert!(!run.show_detail());
}

#[test]
fn phases_show_as_working() {
    let mut run = run_of(1);
    run.on_msg(Msg::Phase(0, Phase::Fetching));
    assert_eq!(run.status(0), &Status::Working(Phase::Fetching));
}

#[test]
fn quit_skips_waiting_and_drained_then_exits_after_running_finish() {
    let mut run = run_of(3);
    run.on_msg(Msg::Done(0, Outcome::Ask(diverged())));
    run.on_msg(Msg::Phase(1, Phase::Fetching));
    assert_eq!(press(&mut run, KeyCode::Char('q')), vec![Effect::Drain]);
    assert!(matches!(
        run.status(0),
        Status::Final(Outcome::Skipped { .. })
    ));
    assert!(run.on_drained(&[2]).is_empty());
    assert!(matches!(
        run.status(2),
        Status::Final(Outcome::Skipped { .. })
    ));
    assert!(!run.finished());
    assert_eq!(
        run.on_msg(Msg::Done(1, Outcome::UpToDate { ahead: 0 })),
        vec![Effect::Exit]
    );
}

#[test]
fn ctrl_c_also_quits() {
    let mut run = run_of(1);
    run.on_msg(Msg::Phase(0, Phase::Fetching));
    let effects = run.on_key(KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL));
    assert_eq!(effects, vec![Effect::Drain]);
    assert!(run.quitting());
}

#[test]
fn ask_after_quit_is_skipped() {
    let mut run = run_of(1);
    run.on_msg(Msg::Phase(0, Phase::Fetching));
    press(&mut run, KeyCode::Char('q'));
    run.on_drained(&[]);
    let effects = run.on_msg(Msg::Done(0, Outcome::Ask(dirty())));
    assert_eq!(effects, vec![Effect::Exit]);
    assert_eq!(run.waiting(), 0);
    assert!(matches!(
        run.status(0),
        Status::Final(Outcome::Skipped { .. })
    ));
}

#[test]
fn finished_shows_done_and_enter_exits() {
    let mut run = run_of(2);
    run.on_msg(Msg::Done(
        0,
        Outcome::Updated {
            how: How::FastForward,
            commits: 1,
            branch: "main".into(),
        },
    ));
    assert!(!run.finished());
    run.on_msg(Msg::Done(1, Outcome::UpToDate { ahead: 0 }));
    assert!(run.finished());
    assert_eq!(run.done(), 2);
    assert_eq!(press(&mut run, KeyCode::Enter), vec![Effect::Exit]);
    let outcomes = run.outcomes();
    assert_eq!(outcomes.len(), 2);
    assert_eq!(outcomes[1].0, "github.com/a/r1");
}
