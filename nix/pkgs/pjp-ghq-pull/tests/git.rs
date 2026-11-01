//! check: pjp-ghq-pull-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! - git を流して、成否と stdout・stderr を返すこと (落ちたときも stderr が取れる)
//! - fetch が origin の remote-tracking branch を進めること
//! - 子の git が端末から切り離されていること: GIT_TERMINAL_PROMPT=0 で、stdin は読んでもすぐ EOF、Linux では
//!   pjp-ghq-pull と別の session にいる (制御端末が無いので、ssh や git が /dev/tty で入力を待てない)
//! - 呼んだ側から GIT_DIR などを受け継いでも、git -C の dir の repo を見る
//! - 時間切れになると、子の process group ごと止め (git の下で動く孫も残さない)、timed_out を返すこと

mod common;

use std::time::{Duration, Instant};

use common::Sandbox;

#[test]
fn run_reports_success_and_output() {
    let sb = Sandbox::new("run-ok");
    let repo = sb.repo("r");
    let out = sb
        .plain()
        .run(&repo.work, &["rev-parse", "--is-inside-work-tree"]);
    assert!(out.success);
    assert!(!out.timed_out);
    assert_eq!(out.stdout.trim(), "true");
}

#[test]
fn run_reports_failure() {
    let sb = Sandbox::new("run-fail");
    let repo = sb.repo("r");
    let out = sb
        .plain()
        .run(&repo.work, &["rev-parse", "--verify", "refs/heads/nope"]);
    assert!(!out.success);
    assert!(!out.timed_out);
    assert!(!out.stderr.trim().is_empty());
}

#[test]
fn fetch_updates_remote_tracking_branch() {
    let sb = Sandbox::new("fetch");
    let repo = sb.repo("r");
    sb.commit(&repo.seed, "b.txt", "b\n", "b");
    sb.push(&repo.seed);
    let out = sb.plain().fetch(&repo.work);
    assert!(out.success, "{}", out.stderr);
    assert_eq!(
        sb.git(&repo.work, &["rev-parse", "refs/remotes/origin/main"]),
        sb.head(&repo.seed)
    );
}

#[test]
fn child_has_no_terminal_input_and_prompt_off() {
    let sb = Sandbox::new("detached");
    let repo = sb.repo("r");
    sb.fake_bin(
        "git-hello",
        r#"echo "prompt=${GIT_TERMINAL_PROMPT-unset}"
if read -r line; then echo "stdin=data"; else echo "stdin-eof"; fi"#,
    );
    let out = sb.plain().run(&repo.work, &["hello"]);
    assert!(out.success, "{}", out.stderr);
    assert!(out.stdout.contains("prompt=0"), "{}", out.stdout);
    assert!(out.stdout.contains("stdin-eof"), "{}", out.stdout);
}

#[cfg(target_os = "linux")]
#[test]
fn child_runs_in_new_session() {
    // /proc/<pid>/stat の ")" より後ろの 4 番目が session id
    fn sid_of(stat: &str) -> String {
        let rest = &stat[stat.rfind(')').unwrap() + 2..];
        rest.split_whitespace().nth(3).unwrap().to_string()
    }
    let sb = Sandbox::new("session");
    let repo = sb.repo("r");
    sb.fake_bin("git-sid", "cat /proc/$$/stat");
    let out = sb.plain().run(&repo.work, &["sid"]);
    assert!(out.success, "{}", out.stderr);
    let child = sid_of(&out.stdout);
    let me = sid_of(&std::fs::read_to_string("/proc/self/stat").unwrap());
    assert_ne!(child, me);
}

#[test]
fn timeout_kills_process_group() {
    let sb = Sandbox::new("timeout");
    let repo = sb.repo("r");
    let ticks = sb.path("ticks");
    sb.fake_bin(
        "git-slow",
        &format!(
            "( while :; do echo tick >>'{}'; sleep 0.2; done ) &\nwait",
            ticks.display()
        ),
    );
    let started = Instant::now();
    let out = sb
        .plain()
        .run_timeout(&repo.work, &["slow"], Some(Duration::from_secs(1)));
    let took = started.elapsed();
    assert!(out.timed_out);
    assert!(!out.success);
    assert!(took < Duration::from_secs(4), "took {took:?}");
    // 孫 (サブシェルの loop) も止まっていれば、ticks は伸びない
    let before = std::fs::read_to_string(&ticks).unwrap_or_default().len();
    std::thread::sleep(Duration::from_millis(800));
    let after = std::fs::read_to_string(&ticks).unwrap_or_default().len();
    assert_eq!(before, after);
}

#[test]
fn inherited_git_dir_does_not_redirect() {
    let sb = Sandbox::new("git-dir");
    let a = sb.repo("a");
    let b = sb.repo("b");
    let mut git = sb.plain();
    git.env.push((
        std::ffi::OsString::from("GIT_DIR"),
        b.work.join(".git").into_os_string(),
    ));
    let out = git.run(&a.work, &["rev-parse", "--absolute-git-dir"]);
    assert!(out.success, "{}", out.stderr);
    assert_eq!(
        std::path::PathBuf::from(out.stdout.trim())
            .canonicalize()
            .unwrap(),
        a.work.join(".git").canonicalize().unwrap()
    );
}
