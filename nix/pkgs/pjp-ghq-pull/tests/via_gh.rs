//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! gitViaGh (dotfiles.claude.gitViaGh.enable) の読み方と、git gh の経路。git-gh と gh は偽物を PATH に置く。
//!
//! - ~/.local/state/dotfiles/git-via-gh.json の "enable" が true のときだけ on (false・空・壊れた JSON・文字列の
//!   "true"・ファイルが無いときは off)。--via-gh / --no-via-gh はファイルより先に効く
//! - on なら fetch を git gh で打ち、merge は素の git で打つ。off なら git gh を呼ばない
//! - 事前確認: git-gh と gh が PATH にあり、gh auth token --hostname github.com が通れば通る。
//!   どれかが欠けていれば、gh auth login (か --no-via-gh) を案内して止まる
//! - git gh の fetch が返らなければ時間切れにし、「もう一度」を選べる問いを返す
//! - 画面に出す経路の名前

mod common;

use std::time::{Duration, Instant};

use common::Sandbox;
use pjp_ghq_pull::flow::{self, Choice, Outcome, Reason};
use pjp_ghq_pull::via_gh;

#[test]
fn enabled_in_reads_true_only() {
    assert!(via_gh::enabled_in(r#"{"enable":true}"#));
    assert!(via_gh::enabled_in("{ \"enable\" :\n true }"));
    assert!(!via_gh::enabled_in(r#"{"enable":false}"#));
    assert!(!via_gh::enabled_in(r#"{"enable":"true"}"#));
    assert!(!via_gh::enabled_in(""));
    assert!(!via_gh::enabled_in("{\"enable\":"));
    assert!(!via_gh::enabled_in("not json"));
}

#[test]
fn state_file_is_under_home() {
    let home = std::path::Path::new("/home/someone");
    assert_eq!(
        via_gh::state_file(home),
        home.join(".local/state/dotfiles/git-via-gh.json")
    );
}

#[test]
fn resolve_reads_state_file_and_flag_wins() {
    let sb = Sandbox::new("v-resolve");
    let on = sb.path("on");
    let off = sb.path("off");
    for (home, value) in [(&on, "true"), (&off, "false")] {
        let file = via_gh::state_file(home);
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(file, format!("{{\"enable\":{value}}}")).unwrap();
    }
    let missing = sb.path("missing");
    assert!(via_gh::resolve(None, Some(&on)));
    assert!(!via_gh::resolve(None, Some(&off)));
    assert!(!via_gh::resolve(None, Some(&missing)));
    assert!(!via_gh::resolve(None, None));
    assert!(!via_gh::resolve(Some(false), Some(&on)));
    assert!(via_gh::resolve(Some(true), Some(&missing)));
}

/// 引数を log に書いてから本物の git に渡す偽の git-gh
fn logging_git_gh(sb: &Sandbox) -> std::path::PathBuf {
    let log = sb.path("git-gh.log");
    sb.fake_bin(
        "git-gh",
        &format!("echo \"$*\" >>'{}'\nexec git \"$@\"", log.display()),
    );
    log
}

#[test]
fn fetch_goes_through_git_gh_when_on() {
    let sb = Sandbox::new("v-on");
    let r = sb.repo("r");
    let log = logging_git_gh(&sb);
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let git = sb.runner(true, Duration::from_secs(30));
    let outcome = flow::start(&git, &r.work, &|_| {});
    assert!(matches!(outcome, Outcome::Updated { .. }), "{outcome:?}");
    let lines = std::fs::read_to_string(&log).unwrap();
    assert_eq!(lines.trim(), "fetch --prune origin");
    assert_eq!(sb.head(&r.work), sb.head(&r.seed));
}

#[test]
fn fetch_uses_plain_git_when_off() {
    let sb = Sandbox::new("v-off");
    let r = sb.repo("r");
    let log = logging_git_gh(&sb);
    sb.commit(&r.seed, "b.txt", "b\n", "b");
    sb.push(&r.seed);
    let git = sb.runner(false, Duration::from_secs(30));
    assert!(matches!(
        flow::start(&git, &r.work, &|_| {}),
        Outcome::Updated { .. }
    ));
    assert!(!log.exists());
}

/// gh auth token が login (空でなければ通る) で答える偽の gh
fn fake_gh(sb: &Sandbox, logged_in: bool) {
    let body = if logged_in {
        "if [ \"$1 $2\" = \"auth token\" ]; then echo gho_fake; exit 0; fi\nexit 2"
    } else {
        "echo 'You are not logged into any GitHub hosts.' >&2\nexit 1"
    };
    sb.fake_bin("gh", body);
}

#[test]
fn preflight_passes_when_logged_in() {
    let sb = Sandbox::new("v-pre-ok");
    sb.fake_bin("git-gh", "exit 0");
    fake_gh(&sb, true);
    assert_eq!(via_gh::preflight(sb.bin().as_os_str()), Ok(()));
}

#[test]
fn preflight_fails_without_login() {
    let sb = Sandbox::new("v-pre-login");
    sb.fake_bin("git-gh", "exit 0");
    fake_gh(&sb, false);
    let err = via_gh::preflight(sb.bin().as_os_str()).unwrap_err();
    assert!(err.contains("gh auth login"), "{err}");
    assert!(err.contains("not logged into"), "{err}");
}

#[test]
fn preflight_fails_without_git_gh() {
    let sb = Sandbox::new("v-pre-git-gh");
    fake_gh(&sb, true);
    let err = via_gh::preflight(sb.bin().as_os_str()).unwrap_err();
    assert!(err.contains("git-gh"), "{err}");
    assert!(err.contains("--no-via-gh"), "{err}");
}

#[test]
fn preflight_fails_without_gh() {
    let sb = Sandbox::new("v-pre-gh");
    sb.fake_bin("git-gh", "exit 0");
    let err = via_gh::preflight(sb.bin().as_os_str()).unwrap_err();
    assert!(err.contains("gh"), "{err}");
    assert!(err.contains("--no-via-gh"), "{err}");
}

#[test]
fn fetch_timeout_asks_retry() {
    let sb = Sandbox::new("v-timeout");
    let r = sb.repo("r");
    sb.fake_bin("git-gh", "sleep 30");
    let git = sb.runner(true, Duration::from_secs(1));
    let started = Instant::now();
    let outcome = flow::start(&git, &r.work, &|_| {});
    assert!(started.elapsed() < Duration::from_secs(5));
    match outcome {
        Outcome::Ask(q) => {
            assert!(matches!(
                q.reason,
                Reason::FetchFailed {
                    timed_out: true,
                    ..
                }
            ));
            assert_eq!(q.choices, vec![Choice::Skip, Choice::Retry]);
        }
        other => panic!("問いではない: {other:?}"),
    }
}

#[test]
fn route_label_names_the_path() {
    assert_eq!(via_gh::route_label(true), "git gh (gitViaGh)");
    assert_eq!(via_gh::route_label(false), "git");
}
