//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 実行中の画面の model (run)。画面なしで、作業の列からの知らせとキーを送る。
//!
//! - 問いは来た順に確認待ちに並び、答えると、その repo の続き (Job::Answer) を作業の列に積んで次の問いへ移る。
//!   s はその場でスキップにする。答えのキーは確認待ちの欄に focus があるときだけ、今の問いで選べるものだけ効く
//! - 問いが替わってから 1 秒は、repo の形を変える答え (u・c・f・m・r) を受けず、知らせを出す (二度押し・押しっぱなしで
//!   次の問い = 別の repo に入らないように)。受けなかったキーが続く間は待ちが延びる。s・t・d はすぐ効く
//! - d で詳細を出し入れし、Tab で一覧と確認待ちを行き来する
//! - q (と Ctrl-C) は、確認待ちとまだ始めていない repo をスキップにし、動いている作業が終わってから閉じる。
//!   やめた後に届いた問いもスキップにする
//! - 全部が終わり確認待ちも空なら「完了」で、Enter・q・Esc で閉じる

use pjp_ghq_pull::flow::{Choice, How, Outcome, Phase, Question, Reason};
use pjp_ghq_pull::run::{Effect, Focus, Run, Status};
use pjp_ghq_pull::runner::{Job, Msg};
use std::time::{Duration, Instant};

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

fn at(run: &mut Run, code: KeyCode, t: Instant) -> Vec<Effect> {
    run.on_key_at(KeyEvent::new(code, KeyModifiers::NONE), t)
}

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[test]
fn answer_key_enqueues_and_moves_to_next() {
    let t0 = Instant::now();
    let mut run = run_of(2);
    run.on_msg_at(Msg::Done(0, Outcome::Ask(diverged())), t0);
    run.on_msg_at(Msg::Done(1, Outcome::Ask(dirty())), t0);
    assert_eq!(run.focus(), Focus::Questions);
    let effects = at(&mut run, KeyCode::Char('m'), t0 + ms(3000));
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

fn fetch_failed() -> Question {
    q(
        Reason::FetchFailed {
            timed_out: false,
            stderr: "fatal: x".into(),
        },
        vec![Choice::Skip, Choice::Retry],
    )
}

#[test]
fn double_press_does_not_answer_next_question() {
    let t0 = Instant::now();
    let mut run = run_of(2);
    run.on_msg_at(Msg::Done(0, Outcome::Ask(diverged())), t0);
    run.on_msg_at(Msg::Done(1, Outcome::Ask(diverged())), t0);
    let t1 = t0 + ms(3000);
    assert_eq!(
        at(&mut run, KeyCode::Char('m'), t1),
        vec![Effect::Enqueue(Job::Answer(0, diverged(), Choice::Merge))]
    );
    assert!(at(&mut run, KeyCode::Char('m'), t1 + ms(150)).is_empty());
    assert_eq!(run.waiting(), 1);
    assert_eq!(run.status(1), &Status::Waiting(diverged()));
    assert!(run.notice().unwrap().contains("m を受けなかった"));
    assert_eq!(run.current_question().map(|(id, _)| id), Some(1));
    assert_eq!(
        at(&mut run, KeyCode::Char('m'), t1 + ms(1300)),
        vec![Effect::Enqueue(Job::Answer(1, diverged(), Choice::Merge))]
    );
    assert!(run.notice().is_none());
}

#[test]
fn holding_a_key_never_reaches_the_next_question() {
    let t0 = Instant::now();
    let mut run = run_of(2);
    run.on_msg_at(Msg::Done(0, Outcome::Ask(diverged())), t0);
    run.on_msg_at(Msg::Done(1, Outcome::Ask(diverged())), t0);
    let t1 = t0 + ms(3000);
    at(&mut run, KeyCode::Char('r'), t1);
    for i in 1..=100 {
        assert!(at(&mut run, KeyCode::Char('r'), t1 + ms(30 * i)).is_empty());
    }
    assert_eq!(run.waiting(), 1);
}

#[test]
fn new_question_needs_a_moment_before_changing_answers() {
    let t0 = Instant::now();
    let mut run = run_of(1);
    run.on_msg_at(Msg::Done(0, Outcome::Ask(dirty())), t0);
    assert!(at(&mut run, KeyCode::Char('f'), t0 + ms(200)).is_empty());
    assert!(run.notice().is_some());
    assert_eq!(
        at(&mut run, KeyCode::Char('f'), t0 + ms(1300)),
        vec![Effect::Enqueue(Job::Answer(0, dirty(), Choice::TryFf))]
    );
}

#[test]
fn skip_retry_and_detail_are_immediate() {
    let t0 = Instant::now();
    let mut run = run_of(3);
    run.on_msg_at(Msg::Done(0, Outcome::Ask(diverged())), t0);
    run.on_msg_at(Msg::Done(1, Outcome::Ask(fetch_failed())), t0);
    run.on_msg_at(Msg::Done(2, Outcome::Ask(dirty())), t0);
    let t1 = t0 + ms(3000);
    at(&mut run, KeyCode::Char('m'), t1);
    at(&mut run, KeyCode::Char('d'), t1 + ms(20));
    assert!(run.show_detail());
    assert_eq!(
        at(&mut run, KeyCode::Char('t'), t1 + ms(40)),
        vec![Effect::Enqueue(Job::Answer(
            1,
            fetch_failed(),
            Choice::Retry
        ))]
    );
    assert!(at(&mut run, KeyCode::Char('s'), t1 + ms(60)).is_empty());
    assert!(matches!(
        run.status(2),
        Status::Final(Outcome::Skipped { .. })
    ));
}
