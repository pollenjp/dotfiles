//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 1 つの repo の判定 (flow::start)。bare の remote と clone で状態を作って流す。
//!
//! - 取り込む commit が無ければ問わずに「最新」(未 push の commit・変更・別の branch があっても)
//! - 既定 branch にいて、変更が無く、分岐していなければ問わずに fast-forward する (未追跡のファイルだけなら変更に数えない)
//! - 確認待ちの理由と選べること: 既定 branch でない (detached も。c は変更が無いときだけ)・変更あり・分岐・
//!   upstream が無い・upstream が origin でない (fetch していない remote と比べて「最新」と言わない)・origin が無い・作業途中 (rebase の途中・index.lock)・fetch の失敗。問う repo の HEAD は動かさない。
//!   detached HEAD の commit がどの branch にも無ければ c を出さない (切り替えると commit が置き去りになる)
//! - 作業途中と origin の無い repo は fetch しない
//! - git の work tree の直下でない entry (外側の repo の中の dir・bare の repo) は、外側の repo を触らずにスキップする
//! - origin/HEAD が無ければ origin/main を既定 branch にし、origin/HEAD は作らない
//! - 進み具合を 確認中 → fetch 中 → 更新中 の順に知らせる。問いの詳細に git status -sb の行が入り、fetch の失敗は
//!   fetch の stderr も入る

mod common;

use std::cell::RefCell;

use common::Sandbox;
use pjp_ghq_pull::flow::{self, Choice, How, Outcome, Phase, Question, Reason};
use pjp_ghq_pull::git::Git;
use pjp_ghq_pull::repo::{Busy, Head};

fn start(git: &Git, dir: &std::path::Path) -> Outcome {
    flow::start(git, dir, &|_| {})
}

fn question(outcome: Outcome) -> Question {
    match outcome {
        Outcome::Ask(q) => q,
        other => panic!("問いではない: {other:?}"),
    }
}

#[test]
fn up_to_date() {
    let sb = Sandbox::new("s-latest");
    let r = sb.repo("r");
    assert_eq!(start(&sb.plain(), &r.work), Outcome::UpToDate { ahead: 0 });
}

#[test]
fn up_to_date_with_unpushed_commits() {
    let sb = Sandbox::new("s-unpushed");
    let r = sb.repo("r");
    sb.commit(&r.work, "w.txt", "w\n", "w");
    assert_eq!(start(&sb.plain(), &r.work), Outcome::UpToDate { ahead: 1 });
}

#[test]
fn fast_forwards() {
    let sb = Sandbox::new("s-ff");
    let r = sb.repo("r");
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.commit(&r.seed, "c.txt", "c\n", "c");
    sb.push(&r.seed);
    assert_eq!(
        start(&sb.plain(), &r.work),
        Outcome::Updated {
            how: How::FastForward,
            commits: 2,
            branch: "main".into()
        }
    );
    assert_eq!(sb.head(&r.work), sb.head(&r.seed));
}

#[test]
fn untracked_only_fast_forwards() {
    let sb = Sandbox::new("s-untracked");
    let r = sb.repo("r");
    std::fs::write(r.work.join("note.txt"), "memo\n").unwrap();
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    assert!(matches!(
        start(&sb.plain(), &r.work),
        Outcome::Updated {
            how: How::FastForward,
            commits: 1,
            ..
        }
    ));
    assert!(r.work.join("note.txt").exists());
}

#[test]
fn dirty_asks() {
    let sb = Sandbox::new("s-dirty");
    let r = sb.repo("r");
    std::fs::write(r.work.join("a.txt"), "local\n").unwrap();
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let before = sb.head(&r.work);
    let q = question(start(&sb.plain(), &r.work));
    assert_eq!(q.reason, Reason::Dirty { behind: 1 });
    assert_eq!(q.choices, vec![Choice::Skip, Choice::TryFf]);
    assert_eq!(q.default_branch.as_deref(), Some("main"));
    assert_eq!(q.upstream.as_deref(), Some("refs/remotes/origin/main"));
    assert!(
        q.detail.lines().any(|l| l.starts_with("## ")),
        "{}",
        q.detail
    );
    assert_eq!(sb.head(&r.work), before);
}

#[test]
fn dirty_without_incoming_is_up_to_date() {
    let sb = Sandbox::new("s-dirty-latest");
    let r = sb.repo("r");
    std::fs::write(r.work.join("a.txt"), "local\n").unwrap();
    assert_eq!(start(&sb.plain(), &r.work), Outcome::UpToDate { ahead: 0 });
}

#[test]
fn diverged_asks() {
    let sb = Sandbox::new("s-diverged");
    let r = sb.repo("r");
    sb.commit(&r.work, "w.txt", "w\n", "w");
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let before = sb.head(&r.work);
    let q = question(start(&sb.plain(), &r.work));
    assert_eq!(
        q.reason,
        Reason::Diverged {
            ahead: 1,
            behind: 1
        }
    );
    assert_eq!(q.choices, vec![Choice::Skip, Choice::Merge, Choice::Rebase]);
    assert_eq!(sb.head(&r.work), before);
}

#[test]
fn other_branch_asks() {
    let sb = Sandbox::new("s-other");
    let r = sb.repo("r");
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let q = question(start(&sb.plain(), &r.work));
    assert_eq!(
        q.reason,
        Reason::NotOnDefault {
            head: Head::Branch("feat".into()),
            default_branch: "main".into(),
            behind: 1
        }
    );
    assert_eq!(
        q.choices,
        vec![Choice::Skip, Choice::BranchOnly, Choice::Checkout]
    );
}

#[test]
fn other_branch_dirty_has_no_checkout() {
    let sb = Sandbox::new("s-other-dirty");
    let r = sb.repo("r");
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    std::fs::write(r.work.join("a.txt"), "local\n").unwrap();
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let q = question(start(&sb.plain(), &r.work));
    assert!(matches!(q.reason, Reason::NotOnDefault { .. }));
    assert_eq!(q.choices, vec![Choice::Skip, Choice::BranchOnly]);
}

#[test]
fn other_branch_up_to_date() {
    let sb = Sandbox::new("s-other-latest");
    let r = sb.repo("r");
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    sb.commit(&r.work, "f.txt", "f\n", "f");
    assert_eq!(start(&sb.plain(), &r.work), Outcome::UpToDate { ahead: 0 });
}

#[test]
fn detached_asks() {
    let sb = Sandbox::new("s-detached");
    let r = sb.repo("r");
    sb.git(&r.work, &["switch", "-q", "--detach", "HEAD"]);
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let q = question(start(&sb.plain(), &r.work));
    assert!(matches!(
        q.reason,
        Reason::NotOnDefault {
            head: Head::Detached,
            ..
        }
    ));
    assert_eq!(
        q.choices,
        vec![Choice::Skip, Choice::BranchOnly, Choice::Checkout]
    );
}

#[test]
fn detached_with_unreachable_commit_has_no_checkout() {
    let sb = Sandbox::new("s-detached-orphan");
    let r = sb.repo("r");
    sb.git(&r.work, &["switch", "-q", "--detach", "HEAD"]);
    sb.commit(&r.work, "o.txt", "o\n", "orphan");
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let q = question(start(&sb.plain(), &r.work));
    assert_eq!(q.choices, vec![Choice::Skip, Choice::BranchOnly]);
}

#[test]
fn no_upstream_asks() {
    let sb = Sandbox::new("s-no-upstream");
    let r = sb.repo("r");
    sb.git(&r.work, &["branch", "--unset-upstream"]);
    let q = question(start(&sb.plain(), &r.work));
    assert_eq!(q.reason, Reason::NoUpstream);
    assert_eq!(q.choices, vec![Choice::Skip]);
}

#[test]
fn no_origin_asks_without_fetch() {
    let sb = Sandbox::new("s-no-origin");
    let r = sb.repo("r");
    sb.git(&r.work, &["remote", "remove", "origin"]);
    let phases = RefCell::new(Vec::new());
    let q = question(flow::start(&sb.plain(), &r.work, &|p| {
        phases.borrow_mut().push(p)
    }));
    assert_eq!(q.reason, Reason::NoUpstream);
    assert_eq!(q.choices, vec![Choice::Skip]);
    assert!(!phases.borrow().contains(&Phase::Fetching));
}

#[test]
fn origin_head_missing_uses_main() {
    let sb = Sandbox::new("s-no-origin-head");
    let r = sb.repo("r");
    sb.git(
        &r.work,
        &["config", "remote.origin.followRemoteHEAD", "never"],
    );
    sb.git(&r.work, &["remote", "set-head", "origin", "-d"]);
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    assert!(matches!(
        start(&sb.plain(), &r.work),
        Outcome::Updated { ref branch, .. } if branch == "main"
    ));
    assert!(!sb.git_ok(&r.work, &["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]));
}

#[test]
fn busy_rebase_asks_without_fetch() {
    let sb = Sandbox::new("s-busy-rebase");
    let r = sb.repo("r");
    sb.commit(&r.seed, "a.txt", "seed\n", "seed");
    sb.push(&r.seed);
    sb.commit(&r.work, "a.txt", "work\n", "work");
    sb.git(&r.work, &["fetch", "-q", "origin"]);
    assert!(!sb.git_ok(&r.work, &["rebase", "origin/main"]));
    let fetched = sb.git(&r.work, &["rev-parse", "refs/remotes/origin/main"]);
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let q = question(start(&sb.plain(), &r.work));
    assert_eq!(q.reason, Reason::Busy(Busy::Rebase));
    assert_eq!(q.choices, vec![Choice::Skip]);
    assert_eq!(
        sb.git(&r.work, &["rev-parse", "refs/remotes/origin/main"]),
        fetched
    );
}

#[test]
fn index_lock_asks() {
    let sb = Sandbox::new("s-index-lock");
    let r = sb.repo("r");
    std::fs::write(r.work.join(".git/index.lock"), "").unwrap();
    let q = question(start(&sb.plain(), &r.work));
    assert_eq!(q.reason, Reason::Busy(Busy::IndexLock));
    assert_eq!(q.choices, vec![Choice::Skip]);
}

#[test]
fn fetch_failure_asks() {
    let sb = Sandbox::new("s-fetch-fail");
    let r = sb.repo("r");
    let gone = sb.path("remote/gone.git");
    sb.git(
        &r.work,
        &["remote", "set-url", "origin", gone.to_str().unwrap()],
    );
    let q = question(start(&sb.plain(), &r.work));
    match &q.reason {
        Reason::FetchFailed { timed_out, stderr } => {
            assert!(!timed_out);
            assert!(!stderr.trim().is_empty());
        }
        other => panic!("fetch の失敗ではない: {other:?}"),
    }
    assert_eq!(q.choices, vec![Choice::Skip, Choice::Retry]);
    assert!(q.detail.contains("gone.git"), "{}", q.detail);
}

#[test]
fn phases_are_reported() {
    let sb = Sandbox::new("s-phases");
    let r = sb.repo("r");
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let phases = RefCell::new(Vec::new());
    flow::start(&sb.plain(), &r.work, &|p| phases.borrow_mut().push(p));
    assert_eq!(
        *phases.borrow(),
        vec![Phase::Checking, Phase::Fetching, Phase::Updating]
    );
}

#[test]
fn dir_inside_another_repo_is_skipped_without_touching_it() {
    let sb = Sandbox::new("s-inner");
    let r = sb.repo("r");
    let inner = r.work.join("inner");
    std::fs::create_dir_all(&inner).unwrap();
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let head = sb.head(&r.work);
    let fetched = sb.git(&r.work, &["rev-parse", "refs/remotes/origin/main"]);
    let outcome = start(&sb.plain(), &inner);
    assert!(matches!(outcome, Outcome::Skipped { .. }), "{outcome:?}");
    assert_eq!(sb.head(&r.work), head);
    assert_eq!(
        sb.git(&r.work, &["rev-parse", "refs/remotes/origin/main"]),
        fetched
    );
}

#[test]
fn bare_repo_is_skipped() {
    let sb = Sandbox::new("s-bare");
    let r = sb.repo("r");
    let bare = sb.path("bare/r.git");
    std::fs::create_dir_all(bare.parent().unwrap()).unwrap();
    sb.git(
        &sb.root,
        &[
            "clone",
            "-q",
            "--bare",
            r.remote.to_str().unwrap(),
            bare.to_str().unwrap(),
        ],
    );
    let outcome = start(&sb.plain(), &bare);
    assert!(matches!(outcome, Outcome::Skipped { .. }), "{outcome:?}");
}

#[test]
fn upstream_not_origin_asks() {
    let sb = Sandbox::new("s-upstream-remote");
    let r = sb.repo("r");
    sb.git(
        &r.work,
        &["remote", "add", "upstream", r.remote.to_str().unwrap()],
    );
    sb.git(&r.work, &["fetch", "-q", "upstream"]);
    sb.git(
        &r.work,
        &["branch", "-q", "--set-upstream-to=upstream/main", "main"],
    );
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let head = sb.head(&r.work);
    let q = question(start(&sb.plain(), &r.work));
    assert_eq!(
        q.reason,
        Reason::UpstreamNotOrigin {
            upstream: "upstream/main".into()
        }
    );
    assert_eq!(q.choices, vec![Choice::Skip]);
    assert_eq!(sb.head(&r.work), head);
}
