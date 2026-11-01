//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! repo の一覧 (discover)。本物の ghq を GHQ_ROOT で一時の root に向けて流す。
//!
//! - root の下の repo を、root からの相対パス・org (相対パスの最後を除いたもの)・名前に分けて、相対パスの順に返す
//!   (gitlab の subgroup のように深いパスも)
//! - git の repo だけを返す (hg などは出さない)
//! - repo が無ければ空、ghq が PATH に無ければ、そのわけを返す

mod common;

use std::ffi::OsString;

use common::Sandbox;
use pjp_ghq_pull::discover;

#[test]
fn lists_repos_under_root() {
    let sb = Sandbox::new("d-list");
    let root = sb.path("ghq");
    for rel in ["gitlab.com/g/sub/r", "github.com/a/b"] {
        let dir = root.join(rel);
        std::fs::create_dir_all(&dir).unwrap();
        sb.git(&dir, &["init", "-q"]);
    }
    let found = discover::ghq_repos(Some(&root), &sb.env()).unwrap();
    let rels: Vec<_> = found.iter().map(|f| f.rel.as_str()).collect();
    assert_eq!(rels, vec!["github.com/a/b", "gitlab.com/g/sub/r"]);
    assert_eq!(found[0].org, "github.com/a");
    assert_eq!(found[0].name, "b");
    assert_eq!(found[1].org, "gitlab.com/g/sub");
    assert_eq!(found[1].name, "r");
    assert!(found[0].path.is_absolute());
    assert!(found[0].path.ends_with("github.com/a/b"));
}

#[test]
fn empty_root_is_empty() {
    let sb = Sandbox::new("d-empty");
    let root = sb.path("ghq");
    std::fs::create_dir_all(&root).unwrap();
    assert_eq!(discover::ghq_repos(Some(&root), &sb.env()), Ok(vec![]));
}

#[test]
fn missing_ghq_is_error() {
    let sb = Sandbox::new("d-no-ghq");
    let root = sb.path("ghq");
    std::fs::create_dir_all(&root).unwrap();
    let mut env = sb.env();
    env.push((OsString::from("PATH"), sb.bin().into_os_string()));
    let err = discover::ghq_repos(Some(&root), &env).unwrap_err();
    assert!(err.contains("ghq"), "{err}");
}

#[test]
fn split_rel_takes_last_component_as_name() {
    assert_eq!(
        discover::split_rel("github.com/a/b"),
        ("github.com/a".to_string(), "b".to_string())
    );
    assert_eq!(discover::split_rel("b"), (String::new(), "b".to_string()));
}

#[test]
fn lists_only_git_repos() {
    let sb = Sandbox::new("d-vcs");
    let root = sb.path("ghq");
    let git_repo = root.join("github.com/a/b");
    std::fs::create_dir_all(&git_repo).unwrap();
    sb.git(&git_repo, &["init", "-q"]);
    std::fs::create_dir_all(root.join("hg.example/a/h/.hg")).unwrap();
    let found = discover::ghq_repos(Some(&root), &sb.env()).unwrap();
    let rels: Vec<_> = found.iter().map(|f| f.rel.as_str()).collect();
    assert_eq!(rels, vec!["github.com/a/b"]);
}
