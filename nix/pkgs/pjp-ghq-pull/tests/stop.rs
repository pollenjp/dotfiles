//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! q・Ctrl-C で止めた後 (Git::stop が立った後) の 1 つの repo の流れ。動いている git は終わらせるが、次の git
//! (fetch・merge・rebase・switch の後の fast-forward) は起こさず、「スキップ」を返す。
//!
//! - 始める前に止まっていれば fetch もしない
//! - fetch の間に止まれば、fetch は終わらせ、fast-forward はしない
//! - 問いへの答え (m) を流す前に止まっていれば merge しない
//! - c の switch の間に止まれば、switch は終わらせ、fast-forward はしない

mod common;

use std::sync::Arc;
use std::sync::atomic::Ordering;

use common::{Repo, Sandbox};
use pjp_ghq_pull::flow::{self, Choice, Outcome, Phase, Question};

fn incoming(sb: &Sandbox, r: &Repo) {
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
}

fn origin_main(sb: &Sandbox, r: &Repo) -> String {
    sb.git(&r.work, &["rev-parse", "refs/remotes/origin/main"])
}

fn skipped(outcome: &Outcome) -> bool {
    matches!(outcome, Outcome::Skipped { .. })
}

fn question(outcome: Outcome) -> Question {
    match outcome {
        Outcome::Ask(q) => q,
        other => panic!("問いではない: {other:?}"),
    }
}

#[test]
fn stop_before_start_does_nothing() {
    let sb = Sandbox::new("x-before");
    let r = sb.repo("r");
    incoming(&sb, &r);
    let (head, fetched) = (sb.head(&r.work), origin_main(&sb, &r));
    let git = sb.plain();
    git.stop.store(true, Ordering::SeqCst);
    let outcome = flow::start(&git, &r.work, &|_| {});
    assert!(skipped(&outcome), "{outcome:?}");
    assert_eq!(sb.head(&r.work), head);
    assert_eq!(origin_main(&sb, &r), fetched);
}

#[test]
fn stop_during_fetch_skips_fast_forward() {
    let sb = Sandbox::new("x-fetch");
    let r = sb.repo("r");
    incoming(&sb, &r);
    let head = sb.head(&r.work);
    let git = sb.plain();
    let stop = Arc::clone(&git.stop);
    let outcome = flow::start(&git, &r.work, &|p| {
        if p == Phase::Fetching {
            stop.store(true, Ordering::SeqCst);
        }
    });
    assert!(skipped(&outcome), "{outcome:?}");
    assert_eq!(sb.head(&r.work), head);
    assert_eq!(origin_main(&sb, &r), sb.head(&r.seed));
}

#[test]
fn stop_before_answer_does_not_merge() {
    let sb = Sandbox::new("x-answer");
    let r = sb.repo("r");
    sb.commit(&r.work, "w.txt", "w\n", "w");
    incoming(&sb, &r);
    let git = sb.plain();
    let q = question(flow::start(&git, &r.work, &|_| {}));
    let head = sb.head(&r.work);
    git.stop.store(true, Ordering::SeqCst);
    let outcome = flow::answer(&git, &r.work, &q, Choice::Merge, &|_| {});
    assert!(skipped(&outcome), "{outcome:?}");
    assert_eq!(sb.head(&r.work), head);
}

#[test]
fn stop_during_checkout_skips_fast_forward() {
    let sb = Sandbox::new("x-checkout");
    let r = sb.repo("r");
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    incoming(&sb, &r);
    let git = sb.plain();
    let q = question(flow::start(&git, &r.work, &|_| {}));
    let main = sb.git(&r.work, &["rev-parse", "refs/heads/main"]);
    let stop = Arc::clone(&git.stop);
    let outcome = flow::answer(&git, &r.work, &q, Choice::Checkout, &|p| {
        if p == Phase::Updating {
            stop.store(true, Ordering::SeqCst);
        }
    });
    assert!(skipped(&outcome), "{outcome:?}");
    assert_eq!(
        sb.git(&r.work, &["symbolic-ref", "--short", "HEAD"]),
        "main"
    );
    assert_eq!(sb.git(&r.work, &["rev-parse", "refs/heads/main"]), main);
}
