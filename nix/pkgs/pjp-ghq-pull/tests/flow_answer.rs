//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 問いへの答え (flow::answer)。bare の remote と clone で状態を作り、start の問いに答える。
//!
//! - s は理由を添えて「スキップ」、t は fetch からやり直す
//! - u は checkout せずに既定 branch だけを fast-forward する (分岐していれば失敗にし、branch を動かさない)
//! - c は既定 branch に切り替えてから判定をやり直す (fast-forward なら「切り替えて」と分かる結果、分岐なら分岐の問い)
//! - f は変更を残したまま fast-forward を試す (重なるファイルがあれば git が止め、変更も HEAD も残る)
//! - m は merge commit を作り、r は手元の commit を upstream の上に載せ直す。衝突したら中断して元に戻す
//! - 安全のための決まり: autostash (merge.autoStash) で stash しない・rebase.updateRefs でほかの branch を動かさない
//! - 問いの後に repo が変わっていれば (変更を足したなど)、答えを流さずに判定をやり直した結果を返す
//! - 既定 branch が別の worktree で checkout されているときの u と c は、git が断って失敗になり、何も動かない

mod common;

use common::{Repo, Sandbox};
use pjp_ghq_pull::flow::{self, Choice, How, Outcome, Question, Reason};
use pjp_ghq_pull::git::Git;
use pjp_ghq_pull::repo;

fn question(outcome: Outcome) -> Question {
    match outcome {
        Outcome::Ask(q) => q,
        other => panic!("問いではない: {other:?}"),
    }
}

fn ask(git: &Git, r: &Repo) -> Question {
    question(flow::start(git, &r.work, &|_| {}))
}

fn answer(git: &Git, r: &Repo, q: &Question, choice: Choice) -> Outcome {
    flow::answer(git, &r.work, q, choice, &|_| {})
}

/// seed に 1 commit (b.txt) を push する
fn incoming(sb: &Sandbox, r: &Repo) {
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
}

/// work の main に 1 commit (w.txt) を足し、seed から 1 commit (b.txt) を push する (重ならない分岐)
fn diverged(sb: &Sandbox, name: &str) -> Repo {
    let r = sb.repo(name);
    sb.commit(&r.work, "w.txt", "w\n", "w");
    incoming(sb, &r);
    r
}

/// a.txt の同じ行を両方で変えた分岐
fn conflicting(sb: &Sandbox, name: &str) -> Repo {
    let r = sb.repo(name);
    sb.commit(&r.work, "a.txt", "work\n", "work");
    sb.commit(&r.seed, "a.txt", "seed\n", "seed");
    sb.push(&r.seed);
    r
}

fn current_branch(sb: &Sandbox, r: &Repo) -> String {
    sb.git(&r.work, &["symbolic-ref", "--short", "HEAD"])
}

fn rev(sb: &Sandbox, r: &Repo, name: &str) -> String {
    sb.git(&r.work, &["rev-parse", name])
}

#[test]
fn skip_returns_reason() {
    let sb = Sandbox::new("a-skip");
    let r = diverged(&sb, "r");
    let git = sb.plain();
    let q = ask(&git, &r);
    assert_eq!(
        answer(&git, &r, &q, Choice::Skip),
        Outcome::Skipped {
            reason: q.reason.label()
        }
    );
}

#[test]
fn retry_refetches() {
    let sb = Sandbox::new("a-retry");
    let r = sb.repo("r");
    let git = sb.plain();
    let gone = sb.path("remote/gone.git");
    sb.git(
        &r.work,
        &["remote", "set-url", "origin", gone.to_str().unwrap()],
    );
    let q = ask(&git, &r);
    assert!(matches!(q.reason, Reason::FetchFailed { .. }));
    sb.git(
        &r.work,
        &["remote", "set-url", "origin", r.remote.to_str().unwrap()],
    );
    incoming(&sb, &r);
    assert!(matches!(
        answer(&git, &r, &q, Choice::Retry),
        Outcome::Updated {
            how: How::FastForward,
            commits: 1,
            ..
        }
    ));
}

#[test]
fn branch_only_moves_default_branch() {
    let sb = Sandbox::new("a-branch-only");
    let r = sb.repo("r");
    let git = sb.plain();
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    incoming(&sb, &r);
    let q = ask(&git, &r);
    assert_eq!(
        answer(&git, &r, &q, Choice::BranchOnly),
        Outcome::Updated {
            how: How::BranchOnly,
            commits: 1,
            branch: "main".into()
        }
    );
    assert_eq!(current_branch(&sb, &r), "feat");
    assert_eq!(
        rev(&sb, &r, "refs/heads/main"),
        rev(&sb, &r, "refs/remotes/origin/main")
    );
}

#[test]
fn branch_only_fails_when_diverged() {
    let sb = Sandbox::new("a-branch-only-diverged");
    let r = diverged(&sb, "r");
    let git = sb.plain();
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    let q = ask(&git, &r);
    let main = rev(&sb, &r, "refs/heads/main");
    assert!(matches!(
        answer(&git, &r, &q, Choice::BranchOnly),
        Outcome::Failed {
            conflict: false,
            ..
        }
    ));
    assert_eq!(rev(&sb, &r, "refs/heads/main"), main);
    assert_eq!(current_branch(&sb, &r), "feat");
}

#[test]
fn checkout_switches_and_fast_forwards() {
    let sb = Sandbox::new("a-checkout");
    let r = sb.repo("r");
    let git = sb.plain();
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    incoming(&sb, &r);
    let q = ask(&git, &r);
    assert_eq!(
        answer(&git, &r, &q, Choice::Checkout),
        Outcome::Updated {
            how: How::Switched,
            commits: 1,
            branch: "main".into()
        }
    );
    assert_eq!(current_branch(&sb, &r), "main");
    assert_eq!(sb.head(&r.work), sb.head(&r.seed));
}

#[test]
fn checkout_then_asks_diverged() {
    let sb = Sandbox::new("a-checkout-diverged");
    let r = diverged(&sb, "r");
    let git = sb.plain();
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    let q = ask(&git, &r);
    let next = question(answer(&git, &r, &q, Choice::Checkout));
    assert_eq!(
        next.reason,
        Reason::Diverged {
            ahead: 1,
            behind: 1
        }
    );
    assert_eq!(current_branch(&sb, &r), "main");
}

#[test]
fn try_ff_keeps_non_overlapping_change() {
    let sb = Sandbox::new("a-try-ff");
    let r = sb.repo("r");
    let git = sb.plain();
    std::fs::write(r.work.join("a.txt"), "local\n").unwrap();
    incoming(&sb, &r);
    let q = ask(&git, &r);
    assert!(matches!(q.reason, Reason::Dirty { .. }));
    assert!(matches!(
        answer(&git, &r, &q, Choice::TryFf),
        Outcome::Updated {
            how: How::FastForward,
            commits: 1,
            ..
        }
    ));
    assert_eq!(
        std::fs::read_to_string(r.work.join("a.txt")).unwrap(),
        "local\n"
    );
    assert_eq!(sb.head(&r.work), sb.head(&r.seed));
}

#[test]
fn try_ff_fails_on_overlap() {
    let sb = Sandbox::new("a-try-ff-overlap");
    let r = sb.repo("r");
    let git = sb.plain();
    std::fs::write(r.work.join("a.txt"), "local\n").unwrap();
    sb.commit(&r.seed, "a.txt", "seed\n", "seed");
    sb.push(&r.seed);
    let before = sb.head(&r.work);
    let q = ask(&git, &r);
    assert!(matches!(
        answer(&git, &r, &q, Choice::TryFf),
        Outcome::Failed {
            conflict: false,
            ..
        }
    ));
    assert_eq!(
        std::fs::read_to_string(r.work.join("a.txt")).unwrap(),
        "local\n"
    );
    assert_eq!(sb.head(&r.work), before);
}

#[test]
fn try_ff_does_not_autostash() {
    let sb = Sandbox::new("a-no-autostash");
    let r = sb.repo("r");
    let git = sb.plain();
    sb.git(&r.work, &["config", "merge.autoStash", "true"]);
    std::fs::write(r.work.join("a.txt"), "local\n").unwrap();
    sb.commit(&r.seed, "a.txt", "seed\n", "seed");
    sb.push(&r.seed);
    let q = ask(&git, &r);
    assert!(matches!(
        answer(&git, &r, &q, Choice::TryFf),
        Outcome::Failed { .. }
    ));
    assert_eq!(sb.git(&r.work, &["stash", "list"]), "");
    assert_eq!(
        std::fs::read_to_string(r.work.join("a.txt")).unwrap(),
        "local\n"
    );
}

#[test]
fn merge_creates_merge_commit() {
    let sb = Sandbox::new("a-merge");
    let r = diverged(&sb, "r");
    let git = sb.plain();
    let q = ask(&git, &r);
    assert_eq!(
        answer(&git, &r, &q, Choice::Merge),
        Outcome::Updated {
            how: How::Merged,
            commits: 1,
            branch: "main".into()
        }
    );
    let parents = sb.git(&r.work, &["rev-list", "--parents", "-n", "1", "HEAD"]);
    assert_eq!(parents.split_whitespace().count(), 3);
}

#[test]
fn rebase_puts_local_on_top() {
    let sb = Sandbox::new("a-rebase");
    let r = diverged(&sb, "r");
    let git = sb.plain();
    let q = ask(&git, &r);
    assert_eq!(
        answer(&git, &r, &q, Choice::Rebase),
        Outcome::Updated {
            how: How::Rebased,
            commits: 1,
            branch: "main".into()
        }
    );
    assert!(sb.git_ok(
        &r.work,
        &[
            "merge-base",
            "--is-ancestor",
            "refs/remotes/origin/main",
            "HEAD"
        ]
    ));
    assert_eq!(
        sb.git(
            &r.work,
            &["rev-list", "--merges", "refs/remotes/origin/main..HEAD"]
        ),
        ""
    );
}

#[test]
fn rebase_does_not_move_other_branches() {
    let sb = Sandbox::new("a-update-refs");
    let r = diverged(&sb, "r");
    let git = sb.plain();
    sb.git(&r.work, &["config", "rebase.updateRefs", "true"]);
    sb.git(&r.work, &["branch", "stack", "HEAD"]);
    let stack = rev(&sb, &r, "refs/heads/stack");
    let q = ask(&git, &r);
    assert!(matches!(
        answer(&git, &r, &q, Choice::Rebase),
        Outcome::Updated {
            how: How::Rebased,
            ..
        }
    ));
    assert_eq!(rev(&sb, &r, "refs/heads/stack"), stack);
}

#[test]
fn merge_conflict_is_aborted() {
    let sb = Sandbox::new("a-merge-conflict");
    let r = conflicting(&sb, "r");
    let git = sb.plain();
    let before = sb.head(&r.work);
    let q = ask(&git, &r);
    assert!(matches!(
        answer(&git, &r, &q, Choice::Merge),
        Outcome::Failed { conflict: true, .. }
    ));
    assert_eq!(repo::busy(&git, &r.work), None);
    assert_eq!(sb.head(&r.work), before);
    assert_eq!(sb.git(&r.work, &["status", "--porcelain"]), "");
}

#[test]
fn rebase_conflict_is_aborted() {
    let sb = Sandbox::new("a-rebase-conflict");
    let r = conflicting(&sb, "r");
    let git = sb.plain();
    let before = sb.head(&r.work);
    let q = ask(&git, &r);
    assert!(matches!(
        answer(&git, &r, &q, Choice::Rebase),
        Outcome::Failed { conflict: true, .. }
    ));
    assert_eq!(repo::busy(&git, &r.work), None);
    assert_eq!(sb.head(&r.work), before);
    assert_eq!(current_branch(&sb, &r), "main");
    assert_eq!(sb.git(&r.work, &["status", "--porcelain"]), "");
}

#[test]
fn merge_rechecks_dirty() {
    let sb = Sandbox::new("a-recheck");
    let r = diverged(&sb, "r");
    let git = sb.plain();
    let q = ask(&git, &r);
    std::fs::write(r.work.join("a.txt"), "local\n").unwrap();
    let before = sb.head(&r.work);
    let next = question(answer(&git, &r, &q, Choice::Merge));
    assert!(matches!(next.reason, Reason::Dirty { .. }));
    assert_eq!(sb.head(&r.work), before);
}

/// work を feat にし、main を別の worktree に出してから、seed から 1 commit を push する
fn main_in_other_worktree(sb: &Sandbox, name: &str) -> Repo {
    let r = sb.repo(name);
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    let wt = sb.path(&format!("wt-{name}"));
    sb.git(
        &r.work,
        &["worktree", "add", "-q", wt.to_str().unwrap(), "main"],
    );
    incoming(sb, &r);
    r
}

#[test]
fn checkout_fails_when_default_branch_in_other_worktree() {
    let sb = Sandbox::new("a-wt-checkout");
    let r = main_in_other_worktree(&sb, "r");
    let git = sb.plain();
    let main = rev(&sb, &r, "refs/heads/main");
    let q = ask(&git, &r);
    assert!(q.choices.contains(&Choice::Checkout));
    assert!(matches!(
        answer(&git, &r, &q, Choice::Checkout),
        Outcome::Failed { .. }
    ));
    assert_eq!(current_branch(&sb, &r), "feat");
    assert_eq!(rev(&sb, &r, "refs/heads/main"), main);
}

#[test]
fn branch_only_fails_when_default_branch_in_other_worktree() {
    let sb = Sandbox::new("a-wt-branch-only");
    let r = main_in_other_worktree(&sb, "r");
    let git = sb.plain();
    let main = rev(&sb, &r, "refs/heads/main");
    let q = ask(&git, &r);
    assert!(matches!(
        answer(&git, &r, &q, Choice::BranchOnly),
        Outcome::Failed { .. }
    ));
    assert_eq!(rev(&sb, &r, "refs/heads/main"), main);
}
