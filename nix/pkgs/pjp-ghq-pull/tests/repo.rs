//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! - 既定 branch は origin/HEAD の指す branch、無ければ origin/main、origin/master の順 (どれも無ければ無い)。
//!   origin/HEAD が消えた branch を指していれば、それは使わない
//! - 追跡中のファイルの変更 (index に足したものも) は「変更あり」、未追跡のファイルだけなら「変更なし」
//! - 作業途中を見分けること: index.lock・rebase・merge・cherry-pick・revert の途中
//! - 今の branch と detached HEAD、branch の upstream (無ければ無い)、upstream との ahead / behind
//! - origin の remote の有無

mod common;

use common::Sandbox;
use pjp_ghq_pull::repo::{self, Busy, Head};

#[test]
fn default_branch_follows_origin_head() {
    let sb = Sandbox::new("default-head");
    let r = sb.repo("r");
    sb.git(&r.seed, &["push", "-q", "origin", "HEAD:develop"]);
    sb.git(&r.work, &["fetch", "-q", "origin"]);
    sb.git(&r.work, &["remote", "set-head", "origin", "develop"]);
    assert_eq!(
        repo::default_branch(&sb.plain(), &r.work),
        Some("develop".into())
    );
}

#[test]
fn default_branch_falls_back_to_main_then_master() {
    let sb = Sandbox::new("default-fallback");
    let r = sb.repo("r");
    let git = sb.plain();
    sb.git(&r.work, &["remote", "set-head", "origin", "-d"]);
    assert_eq!(repo::default_branch(&git, &r.work), Some("main".into()));

    sb.git(
        &r.work,
        &["update-ref", "refs/remotes/origin/master", "HEAD"],
    );
    sb.git(&r.work, &["update-ref", "-d", "refs/remotes/origin/main"]);
    assert_eq!(repo::default_branch(&git, &r.work), Some("master".into()));

    sb.git(&r.work, &["update-ref", "-d", "refs/remotes/origin/master"]);
    assert_eq!(repo::default_branch(&git, &r.work), None);
}

#[test]
fn dangling_origin_head_falls_back() {
    let sb = Sandbox::new("default-dangling");
    let r = sb.repo("r");
    sb.git(
        &r.work,
        &[
            "symbolic-ref",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/gone",
        ],
    );
    assert_eq!(
        repo::default_branch(&sb.plain(), &r.work),
        Some("main".into())
    );
}

#[test]
fn untracked_files_are_not_dirty() {
    let sb = Sandbox::new("untracked");
    let r = sb.repo("r");
    std::fs::write(r.work.join("new.txt"), "x\n").unwrap();
    assert!(!repo::dirty(&sb.plain(), &r.work));
}

#[test]
fn tracked_change_is_dirty() {
    let sb = Sandbox::new("tracked");
    let r = sb.repo("r");
    std::fs::write(r.work.join("a.txt"), "changed\n").unwrap();
    assert!(repo::dirty(&sb.plain(), &r.work));
}

#[test]
fn staged_change_is_dirty() {
    let sb = Sandbox::new("staged");
    let r = sb.repo("r");
    std::fs::write(r.work.join("new.txt"), "x\n").unwrap();
    sb.git(&r.work, &["add", "new.txt"]);
    assert!(repo::dirty(&sb.plain(), &r.work));
}

/// seed と work が a.txt の同じ行を変えた状態を作り、work で origin/main を fetch する
fn conflicting(sb: &Sandbox, name: &str) -> common::Repo {
    let r = sb.repo(name);
    sb.commit(&r.seed, "a.txt", "seed\n", "seed");
    sb.push(&r.seed);
    sb.commit(&r.work, "a.txt", "work\n", "work");
    sb.git(&r.work, &["fetch", "-q", "origin"]);
    r
}

#[test]
fn not_busy_when_clean() {
    let sb = Sandbox::new("busy-none");
    let r = sb.repo("r");
    assert_eq!(repo::busy(&sb.plain(), &r.work), None);
}

#[test]
fn busy_index_lock() {
    let sb = Sandbox::new("busy-lock");
    let r = sb.repo("r");
    std::fs::write(r.work.join(".git/index.lock"), "").unwrap();
    assert_eq!(repo::busy(&sb.plain(), &r.work), Some(Busy::IndexLock));
}

#[test]
fn busy_rebase() {
    let sb = Sandbox::new("busy-rebase");
    let r = conflicting(&sb, "r");
    assert!(!sb.git_ok(&r.work, &["rebase", "origin/main"]));
    assert_eq!(repo::busy(&sb.plain(), &r.work), Some(Busy::Rebase));
}

#[test]
fn busy_merge() {
    let sb = Sandbox::new("busy-merge");
    let r = conflicting(&sb, "r");
    assert!(!sb.git_ok(&r.work, &["merge", "--no-edit", "origin/main"]));
    assert_eq!(repo::busy(&sb.plain(), &r.work), Some(Busy::Merge));
}

#[test]
fn busy_cherry_pick() {
    let sb = Sandbox::new("busy-pick");
    let r = conflicting(&sb, "r");
    assert!(!sb.git_ok(&r.work, &["cherry-pick", "origin/main"]));
    assert_eq!(repo::busy(&sb.plain(), &r.work), Some(Busy::CherryPick));
}

#[test]
fn busy_revert() {
    let sb = Sandbox::new("busy-revert");
    let r = sb.repo("r");
    sb.commit(&r.work, "a.txt", "one\n", "one");
    let one = sb.head(&r.work);
    sb.commit(&r.work, "a.txt", "two\n", "two");
    assert!(!sb.git_ok(&r.work, &["revert", "--no-edit", &one]));
    assert_eq!(repo::busy(&sb.plain(), &r.work), Some(Busy::Revert));
}

#[test]
fn head_reports_branch_and_detached() {
    let sb = Sandbox::new("head");
    let r = sb.repo("r");
    let git = sb.plain();
    assert_eq!(repo::head(&git, &r.work), Head::Branch("main".into()));
    sb.git(&r.work, &["switch", "-q", "--detach", "HEAD"]);
    assert_eq!(repo::head(&git, &r.work), Head::Detached);
}

#[test]
fn upstream_and_ahead_behind() {
    let sb = Sandbox::new("ahead-behind");
    let r = sb.repo("r");
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.commit(&r.seed, "c.txt", "c\n", "c");
    sb.push(&r.seed);
    sb.commit(&r.work, "d.txt", "d\n", "d");
    sb.git(&r.work, &["fetch", "-q", "origin"]);
    let git = sb.plain();
    let up = repo::upstream(&git, &r.work, "main");
    assert_eq!(up.as_deref(), Some("refs/remotes/origin/main"));
    assert_eq!(
        repo::ahead_behind(&git, &r.work, "main", up.as_deref().unwrap()),
        Some((1, 2))
    );
}

#[test]
fn no_upstream_is_none() {
    let sb = Sandbox::new("no-upstream");
    let r = sb.repo("r");
    sb.git(&r.work, &["branch", "--unset-upstream"]);
    assert_eq!(repo::upstream(&sb.plain(), &r.work, "main"), None);
}

#[test]
fn has_origin_only_with_remote() {
    let sb = Sandbox::new("origin");
    let r = sb.repo("r");
    let git = sb.plain();
    assert!(repo::has_origin(&git, &r.work));
    sb.git(&r.work, &["remote", "remove", "origin"]);
    assert!(!repo::has_origin(&git, &r.work));
}

#[test]
fn info_collects_head_default_and_dirty() {
    let sb = Sandbox::new("info");
    let r = sb.repo("r");
    sb.git(&r.work, &["switch", "-q", "-c", "feat"]);
    std::fs::write(r.work.join("a.txt"), "changed\n").unwrap();
    let info = repo::info(&sb.plain(), &r.work);
    assert_eq!(info.head, Head::Branch("feat".into()));
    assert_eq!(info.default_branch.as_deref(), Some("main"));
    assert!(info.dirty);
}

#[test]
fn short_ref_strips_prefixes() {
    assert_eq!(repo::short_ref("refs/remotes/origin/main"), "origin/main");
    assert_eq!(repo::short_ref("refs/heads/main"), "main");
    assert_eq!(repo::short_ref("HEAD"), "HEAD");
}
