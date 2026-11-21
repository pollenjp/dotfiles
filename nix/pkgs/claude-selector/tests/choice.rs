//! check: claude-selector-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 選んだものから claude に渡す引数を組み立てる (choice::Selection::args)。
//!
//! - 既定 (Enter だけ) は c から `--remote-control=` を外したもの (`--dangerously-skip-permissions --effort max --model claude-opus-5-5`)
//! - 権限の 5 つ (付けないときは何も足さない)・effort・モデル・Remote Control の 3 つ (名前なしは `--remote-control=`、名前は `=` でつなぐ)
//! - 並びは 権限 → --effort → --model → --remote-control → cs の後ろの引数 (そのまま最後に。`-c`・質問の文・非 UTF-8 も)
//! - 起こすもののコマンドの名前 (claude・claude-<名前>)
//! - 手で打つモデルの名前の確かめ (空・- で始まる・空白はだめ)、Remote Control の名前 (前後の空白を外し、空なら名前なし)

use claude_selector::choice::{
    self, DEFAULT_EFFORT, DEFAULT_MODEL, EFFORTS, MODELS, Permission, RemoteControl, Selection,
    Target,
};
use std::ffi::OsString;

fn strs(args: &[OsString]) -> Vec<String> {
    args.iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

fn os(v: &[&str]) -> Vec<OsString> {
    v.iter().map(OsString::from).collect()
}

#[test]
fn defaults_are_c_without_remote_control() {
    let s = Selection::default();
    assert_eq!(s.target, Target::Plain);
    assert_eq!(
        strs(&s.args(&[])),
        [
            "--dangerously-skip-permissions",
            "--effort",
            "max",
            "--model",
            "claude-opus-5-5"
        ]
    );
    assert_eq!(DEFAULT_EFFORT, "max");
    assert_eq!(DEFAULT_MODEL, "claude-opus-5-5");
    assert!(EFFORTS.contains(&DEFAULT_EFFORT));
    assert!(MODELS.contains(&DEFAULT_MODEL));
}

#[test]
fn permissions() {
    let args = |p: Permission| {
        strs(
            &Selection {
                permission: p,
                ..Selection::default()
            }
            .args(&[]),
        )
    };
    assert_eq!(args(Permission::Skip)[0], "--dangerously-skip-permissions");
    assert_eq!(args(Permission::Auto)[..2], ["--permission-mode", "auto"]);
    assert_eq!(
        args(Permission::AcceptEdits)[..2],
        ["--permission-mode", "acceptEdits"]
    );
    assert_eq!(args(Permission::Plan)[..2], ["--permission-mode", "plan"]);
    // 付けない: --effort から始まる
    assert_eq!(args(Permission::Ask)[0], "--effort");
    assert_eq!(Permission::Ask.label(), "付けない");
    assert_eq!(Permission::Auto.label(), "--permission-mode auto");
    assert_eq!(Permission::ALL.len(), 5);
    assert_eq!(Permission::ALL[0], Permission::DEFAULT);
    assert_eq!(Permission::DEFAULT, Permission::Skip);
}

#[test]
fn order_and_extra_args() {
    let s = Selection {
        target: Target::Account("work".into()),
        permission: Permission::Plan,
        effort: "high",
        model: "opus".into(),
        remote_control: RemoteControl::Named("作業 1".into()),
    };
    assert_eq!(s.target.command(), "claude-work");
    assert_eq!(
        strs(&s.args(&os(&["-c", "質問 です"]))),
        [
            "--permission-mode",
            "plan",
            "--effort",
            "high",
            "--model",
            "opus",
            "--remote-control=作業 1",
            "-c",
            "質問 です"
        ]
    );
}

#[test]
fn remote_control() {
    assert_eq!(RemoteControl::Off.arg(), None);
    assert_eq!(
        RemoteControl::Unnamed.arg().as_deref(),
        Some("--remote-control=")
    );
    assert_eq!(
        RemoteControl::Named("x".into()).arg().as_deref(),
        Some("--remote-control=x")
    );
    assert_eq!(RemoteControl::from_name("  "), RemoteControl::Unnamed);
    assert_eq!(
        RemoteControl::from_name(" a b "),
        RemoteControl::Named("a b".into())
    );
    // 名前なしの後ろの引数は名前に取られない (= で値を閉じる)
    let s = Selection {
        remote_control: RemoteControl::Unnamed,
        ..Selection::default()
    };
    let a = strs(&s.args(&os(&["質問"])));
    assert_eq!(a[a.len() - 2..], ["--remote-control=", "質問"]);
}

#[cfg(unix)]
#[test]
fn non_utf8_extra_args_pass_through() {
    use std::os::unix::ffi::OsStringExt;
    let raw = OsString::from_vec(vec![0x66, 0xff, 0x6f]);
    let a = Selection::default().args(std::slice::from_ref(&raw));
    assert_eq!(a.last(), Some(&raw));
}

#[test]
fn typed_model_names() {
    assert!(choice::model_ok("opus").is_ok());
    assert!(choice::model_ok("claude-fable-5-2").is_ok());
    assert!(choice::model_ok("claude-opus-5-5[1m]").is_ok());
    for bad in ["", "-x", "--model", "a b", "a\tb", "a\u{7}"] {
        assert!(choice::model_ok(bad).is_err(), "{bad:?}");
    }
}
