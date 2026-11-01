//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 引数 (cli::parse)。
//!
//! - 既定値: 並列 8 本・gitViaGh は状態ファイルに従う (指定なし)・時間切れ 120 秒・root は ghq の設定のまま
//! - -j N・-jN・--jobs N・--jobs=N、--via-gh・--no-via-gh、--timeout 秒 (= も)、--root DIR (= も)、-h・--help、-V・--version
//! - 0 や数でない値・値の無い -j・知らない引数は誤り

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

use pjp_ghq_pull::cli::{self, Cmd, Opts};

fn parse(args: &[&str]) -> Result<Cmd, String> {
    cli::parse(args.iter().map(OsString::from))
}

fn opts(args: &[&str]) -> Opts {
    match parse(args) {
        Ok(Cmd::Run(o)) => o,
        other => panic!("{args:?}: {other:?}"),
    }
}

#[test]
fn defaults() {
    assert_eq!(
        opts(&[]),
        Opts {
            jobs: 8,
            via_gh: None,
            timeout: Duration::from_secs(120),
            root: None,
        }
    );
}

#[test]
fn jobs_forms() {
    for args in [
        &["-j", "3"][..],
        &["-j3"][..],
        &["--jobs", "3"][..],
        &["--jobs=3"][..],
    ] {
        assert_eq!(opts(args).jobs, 3, "{args:?}");
    }
}

#[test]
fn via_gh_flags() {
    assert_eq!(opts(&["--via-gh"]).via_gh, Some(true));
    assert_eq!(opts(&["--no-via-gh"]).via_gh, Some(false));
}

#[test]
fn timeout_and_root() {
    assert_eq!(opts(&["--timeout", "5"]).timeout, Duration::from_secs(5));
    assert_eq!(opts(&["--timeout=5"]).timeout, Duration::from_secs(5));
    assert_eq!(
        opts(&["--root", "/tmp/x"]).root,
        Some(PathBuf::from("/tmp/x"))
    );
    assert_eq!(opts(&["--root=/tmp/x"]).root, Some(PathBuf::from("/tmp/x")));
}

#[test]
fn help_and_version() {
    assert_eq!(parse(&["-h"]), Ok(Cmd::Help));
    assert_eq!(parse(&["--help"]), Ok(Cmd::Help));
    assert_eq!(parse(&["-V"]), Ok(Cmd::Version));
    assert_eq!(parse(&["--version"]), Ok(Cmd::Version));
    assert!(cli::USAGE.contains("--no-via-gh"));
}

#[test]
fn errors() {
    for args in [
        &["-j", "0"][..],
        &["-j"][..],
        &["-j", "x"][..],
        &["--timeout", "0"][..],
        &["--root"][..],
        &["--bogus"][..],
        &["extra"][..],
    ] {
        assert!(parse(args).is_err(), "{args:?}");
    }
}
