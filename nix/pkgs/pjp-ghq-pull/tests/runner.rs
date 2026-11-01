//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 作業の列 (runner)。偽の作業 (git を呼ばない closure) を流す。
//!
//! - 同時に動く作業は workers の本数まで
//! - 進み具合 (Phase) と結果 (Done) を、作業の repo の番号つきで送る
//! - drain は、まだ始めていない作業を列から外して、その repo の番号を返す (動いている作業は止めない)
//! - 作業が panic しても、その repo は panic の文を添えた「失敗」として返り、ほかの作業は続く

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use pjp_ghq_pull::flow::{Outcome, Phase};
use pjp_ghq_pull::runner::{Job, Msg, Runner, Work};

fn done_count(rx: &mpsc::Receiver<Msg>, n: usize) -> Vec<Msg> {
    let mut msgs = Vec::new();
    let mut done = 0;
    while done < n {
        let msg = rx
            .recv_timeout(Duration::from_secs(10))
            .expect("Done が来ない");
        if matches!(msg, Msg::Done(..)) {
            done += 1;
        }
        msgs.push(msg);
    }
    msgs
}

#[test]
fn runs_jobs_in_parallel_up_to_workers() {
    let running = Arc::new(AtomicUsize::new(0));
    let max = Arc::new(AtomicUsize::new(0));
    let (r, m) = (Arc::clone(&running), Arc::clone(&max));
    let work: Work = Arc::new(move |_job, _phase| {
        let now = r.fetch_add(1, Ordering::SeqCst) + 1;
        m.fetch_max(now, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(100));
        r.fetch_sub(1, Ordering::SeqCst);
        Outcome::UpToDate { ahead: 0 }
    });
    let (tx, rx) = mpsc::channel();
    let runner = Runner::spawn(2, work, tx);
    for id in 0..6 {
        runner.push(Job::Start(id));
    }
    done_count(&rx, 6);
    runner.shutdown();
    assert_eq!(max.load(Ordering::SeqCst), 2);
}

#[test]
fn phases_and_results_carry_the_repo_id() {
    let work: Work = Arc::new(|_job, phase| {
        phase(Phase::Fetching);
        Outcome::UpToDate { ahead: 3 }
    });
    let (tx, rx) = mpsc::channel();
    let runner = Runner::spawn(1, work, tx);
    runner.push(Job::Start(7));
    let msgs = done_count(&rx, 1);
    runner.shutdown();
    assert_eq!(
        msgs,
        vec![
            Msg::Phase(7, Phase::Fetching),
            Msg::Done(7, Outcome::UpToDate { ahead: 3 })
        ]
    );
}

#[test]
fn drain_returns_unstarted() {
    let (started_tx, started_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let started_tx = Mutex::new(started_tx);
    let release_rx = Mutex::new(release_rx);
    let work: Work = Arc::new(move |job: &Job, _phase: &dyn Fn(Phase)| {
        started_tx.lock().unwrap().send(job.id()).unwrap();
        release_rx.lock().unwrap().recv().unwrap();
        Outcome::UpToDate { ahead: 0 }
    });
    let (tx, rx) = mpsc::channel();
    let runner = Runner::spawn(1, work, tx);
    for id in 0..3 {
        runner.push(Job::Start(id));
    }
    assert_eq!(started_rx.recv_timeout(Duration::from_secs(10)), Ok(0));
    assert_eq!(runner.drain(), vec![1, 2]);
    release_tx.send(()).unwrap();
    let msgs = done_count(&rx, 1);
    assert_eq!(msgs, vec![Msg::Done(0, Outcome::UpToDate { ahead: 0 })]);
    runner.shutdown();
}

#[test]
fn panicking_work_becomes_failed() {
    let work: Work = Arc::new(|job, _phase| {
        if job.id() == 0 {
            panic!("boom");
        }
        Outcome::UpToDate { ahead: 0 }
    });
    let (tx, rx) = mpsc::channel();
    let runner = Runner::spawn(1, work, tx);
    runner.push(Job::Start(0));
    runner.push(Job::Start(1));
    let msgs = done_count(&rx, 2);
    runner.shutdown();
    assert!(msgs.iter().any(
        |m| matches!(m, Msg::Done(0, Outcome::Failed { stderr, .. }) if stderr.contains("boom"))
    ));
    assert!(msgs.contains(&Msg::Done(1, Outcome::UpToDate { ahead: 0 })));
}
