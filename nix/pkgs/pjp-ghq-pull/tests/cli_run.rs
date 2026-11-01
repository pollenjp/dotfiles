//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 実行ファイル (pjp-ghq-pull) を起こす。
//!
//! - 端末でない (stdin・stdout が pipe) ところで起こされたら、何もせずにわけを出して終了コード 2 で止まる
//!   (remote が進んでいても repo は動かない)
//! - --help・--version は 0 で終わる。知らない引数は終了コード 2

mod common;

use std::process::{Command, Output};

use common::Sandbox;

fn bin(sb: &Sandbox, args: &[&str]) -> Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_pjp-ghq-pull"));
    cmd.args(args);
    for (k, v) in sb.env() {
        cmd.env(k, v);
    }
    cmd.env("XDG_STATE_HOME", sb.path("state"));
    cmd.output().unwrap()
}

#[test]
fn refuses_without_terminal() {
    let sb = Sandbox::new("c-no-tty");
    let r = sb.repo("r");
    let root = sb.path("ghq");
    let work = root.join("github.com/t/r");
    sb.clone_to(&r.remote, &work);
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let before = sb.head(&work);
    let out = bin(&sb, &["--root", root.to_str().unwrap(), "--no-via-gh"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("端末"));
    assert_eq!(sb.head(&work), before);
    assert!(!sb.path("state").exists());
}

#[test]
fn help_and_version() {
    let sb = Sandbox::new("c-help");
    let help = bin(&sb, &["--help"]);
    assert_eq!(help.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&help.stdout).contains("使い方"));
    let version = bin(&sb, &["--version"]);
    assert_eq!(version.status.code(), Some(0));
    assert!(String::from_utf8_lossy(&version.stdout).contains("0.1.0"));
}

#[test]
fn bad_argument_exits_2() {
    let sb = Sandbox::new("c-bad");
    let out = bin(&sb, &["--bogus"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("知らない引数"));
}
