//! check: claude-selector-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 選べるアカウントを集める (accounts::find)。一時の家と PATH の偽のコマンドで流す。
//!
//! - 並び: 既定 (Linux は claude-accounts.json の並び、Windows は決まった名前) のあとに、登録を名前の順。既定と同じ名前の登録は 1 つ
//! - 種類 (登録の mode。既定は subscription) と、PATH の launcher (`claude-<名前>`) と claude。見つからなければ None (選べない)
//! - ファイルが無ければ空 (知らせない)。既定の一覧・登録が読めない形なら知らせ、読めた方は出す。登録の頭の BOM・version 1.0 は読む
//! - 登録の使えない名前 (規則外・account・selector) は、claude-account と同じく一覧ごと読めない形
//! - PATH: 相対パス・空の要素は見ない。unix では実行の権限の無いファイル・dir は飛ばす
//! - 名前の規則 (claude-account と同じ) と、Windows の既定の名前が規則に合うこと

mod common;

use claude_selector::accounts::{
    self, Account, Defaults, Mode, RESERVED, WINDOWS_DEFAULT_ACCOUNTS, find, name_ok, which,
};
use common::TempDir;
use std::ffi::OsStr;

fn linux_defaults(t: &TempDir) -> Defaults {
    Defaults::File(accounts::state_file(&t.path().join("home")))
}

fn names(accounts: &[Account]) -> Vec<&str> {
    accounts.iter().map(|a| a.name.as_str()).collect()
}

#[test]
fn defaults_then_registry_with_launchers() {
    let t = TempDir::new("accounts");
    t.write(
        "home/.local/state/dotfiles/claude-accounts.json",
        "[\"personal\",\"work\"]\n",
    );
    t.write(
        "home/.config/claude-accounts/accounts.json",
        "{\"version\":1,\"accounts\":{\"token1\":{\"mode\":\"token\"},\"sub2\":{\"mode\":\"subscription\"},\"work\":{\"mode\":\"token\"}}}\n",
    );
    let claude = t.command("bin", "claude");
    let personal = t.command("bin", "claude-personal");
    let token1 = t.command("bin2", "claude-token1");
    let path = t.path_var(&["bin", "bin2"]);
    let found = find(&t.path().join("home"), &linux_defaults(&t), Some(&path));
    assert!(found.warnings.is_empty(), "{:?}", found.warnings);
    assert_eq!(found.claude, Some(claude));
    assert_eq!(
        names(&found.accounts),
        ["personal", "work", "sub2", "token1"]
    );
    let a = &found.accounts;
    assert_eq!((a[0].mode, a[0].default), (Mode::Subscription, true));
    assert_eq!(a[0].launcher, Some(personal));
    // 既定と同じ名前の登録は既定のまま (種類も既定の subscription)
    assert_eq!((a[1].mode, a[1].default), (Mode::Subscription, true));
    assert_eq!(a[1].launcher, None);
    assert_eq!((a[2].mode, a[2].default), (Mode::Subscription, false));
    assert_eq!(a[2].launcher, None);
    assert_eq!((a[3].mode, a[3].default), (Mode::Token, false));
    assert_eq!(a[3].launcher, Some(token1));
}

#[test]
fn fixed_defaults_for_windows() {
    let t = TempDir::new("fixed");
    let path = t.path_var(&["bin"]);
    let d = Defaults::Fixed(
        WINDOWS_DEFAULT_ACCOUNTS
            .iter()
            .map(|s| s.to_string())
            .collect(),
    );
    let found = find(&t.path().join("home"), &d, Some(&path));
    assert_eq!(names(&found.accounts), ["personal", "work"]);
    assert!(found.warnings.is_empty());
    assert_eq!(found.claude, None);
    let this_os = Defaults::for_this_os(&t.path().join("home"));
    if cfg!(windows) {
        assert_eq!(this_os, d);
    } else {
        assert_eq!(this_os, linux_defaults(&t));
    }
}

#[test]
fn missing_files_are_empty() {
    let t = TempDir::new("missing");
    let found = find(&t.path().join("home"), &linux_defaults(&t), None);
    assert!(found.accounts.is_empty());
    assert!(found.warnings.is_empty());
    assert_eq!(found.claude, None);
}

#[test]
fn unreadable_lists_are_reported() {
    let t = TempDir::new("broken");
    t.write(
        "home/.local/state/dotfiles/claude-accounts.json",
        "{\"personal\":1}",
    );
    t.write(
        "home/.config/claude-accounts/accounts.json",
        "{\"version\":1,\"accounts\":{\"t\":{\"mode\":\"token\"}}}",
    );
    let found = find(&t.path().join("home"), &linux_defaults(&t), None);
    assert_eq!(names(&found.accounts), ["t"]);
    assert_eq!(found.warnings.len(), 1, "{:?}", found.warnings);
    assert!(
        found.warnings[0].contains("claude-accounts.json"),
        "{:?}",
        found.warnings
    );
    // 登録が読めない形: 既定は出す
    t.write(
        "home/.local/state/dotfiles/claude-accounts.json",
        "[\"personal\"]",
    );
    for bad in [
        "{\"version\":1,\"accounts\":[",
        "{\"version\":2,\"accounts\":{}}",
        "{\"version\":1,\"accounts\":[]}",
        "{\"version\":1,\"accounts\":{\"t\":{\"mode\":\"x\"}}}",
        "{\"version\":1,\"accounts\":{\"t\":\"token\"}}",
        "{\"version\":1,\"accounts\":{\"Bad\":{\"mode\":\"token\"}}}",
        "{\"version\":1,\"accounts\":{\"account\":{\"mode\":\"token\"}}}",
        "{\"version\":1,\"accounts\":{\"selector\":{\"mode\":\"subscription\"}}}",
    ] {
        t.write("home/.config/claude-accounts/accounts.json", bad);
        let found = find(&t.path().join("home"), &linux_defaults(&t), None);
        assert_eq!(names(&found.accounts), ["personal"], "{bad}");
        assert_eq!(found.warnings.len(), 1, "{bad}: {:?}", found.warnings);
        assert!(
            found.warnings[0].contains("accounts.json"),
            "{bad}: {:?}",
            found.warnings
        );
    }
}

#[test]
fn registry_reads_bom_and_float_version() {
    let r = accounts::parse_registry(
        "\u{feff}{\"version\":1.0,\"accounts\":{\"t\":{\"mode\":\"token\"}}}\n",
    )
    .unwrap();
    assert_eq!(r.get("t"), Some(&Mode::Token));
    assert!(
        accounts::parse_registry("{\"version\":1,\"accounts\":{}}")
            .unwrap()
            .is_empty()
    );
}

#[test]
fn which_skips_relative_entries_and_non_commands() {
    let t = TempDir::new("which");
    t.command("abs", "claude-x");
    assert_eq!(which(None, "claude-x"), None);
    assert_eq!(which(Some(OsStr::new("")), "claude-x"), None);
    let rel = std::env::join_paths(["abs", "."]).unwrap();
    assert_eq!(which(Some(&rel), "claude-x"), None);
    let abs = t.path_var(&["abs"]);
    assert!(which(Some(&abs), "claude-x").is_some());
    // dir は飛ばす
    std::fs::create_dir_all(
        t.path()
            .join("d")
            .join(format!("claude{}", std::env::consts::EXE_SUFFIX)),
    )
    .unwrap();
    assert_eq!(which(Some(&t.path_var(&["d"])), "claude"), None);
}

#[cfg(unix)]
#[test]
fn which_needs_the_exec_bit() {
    let t = TempDir::new("exec");
    t.write("bin/claude", "not executable\n");
    assert_eq!(which(Some(&t.path_var(&["bin"])), "claude"), None);
    let p = t.command("bin", "claude");
    assert_eq!(which(Some(&t.path_var(&["bin"])), "claude"), Some(p));
}

#[test]
fn name_rule() {
    for ok in ["personal", "work", "token1", "a-b_c", "0x"] {
        assert!(name_ok(ok), "{ok}");
    }
    for ng in ["", "Work", "-a", "_a", "a.b", "a b", "a/b", "a\\b", "ａ"] {
        assert!(!name_ok(ng), "{ng}");
    }
    assert!(!name_ok("sk-ant-oat01-dummy"));
    assert!(name_ok(&"a".repeat(32)));
    assert!(!name_ok(&"a".repeat(33)));
    for name in WINDOWS_DEFAULT_ACCOUNTS {
        assert!(name_ok(name) && !RESERVED.contains(&name), "{name}");
    }
    assert_eq!(RESERVED, ["account", "selector"]);
}
