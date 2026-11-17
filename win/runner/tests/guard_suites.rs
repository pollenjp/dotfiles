//! Rust に写した 3 つの guard (xref-guard・gist-guard・install-iac-guard) を、Linux の bash の版の試験 (`nix/tests/<名前>.test.sh`) にそのまま
//! 流す。試験の script は hook のパスを引数で受けるので、この crate の exe の `claude-hook <名前>` を呼ぶ包みを渡す。例の正本は bash の版の試験の
//! 1 つだけで、bash の版を直したときに Rust の写しがずれると、ここが落ちる (dotfiles-private の docs/adr/067_win_hook_guards_*)。
//!
//! ## 確かめること
//!
//! - 3 つの試験が、どれも Rust の口で全部通る (止めるもの・通すもの・返す文の中身・黙るとき)
//!
//! bash・jq・git が PATH に無ければ飛ばす (Windows の CI など)。`DOTFILES_WIN_BASH_PARITY=1` なら飛ばさずに落ちる (CI の Linux の job)。

mod common;

use common::{TempDir, which};
use std::path::Path;
use std::process::Command;

fn available() -> bool {
    let must = std::env::var("DOTFILES_WIN_BASH_PARITY").is_ok_and(|v| v == "1");
    let found = cfg!(unix) && ["bash", "jq", "git"].iter().all(|n| which(n).is_some());
    if must && !found {
        panic!("DOTFILES_WIN_BASH_PARITY=1 なのに bash・jq・git のどれかが無い");
    }
    found
}

/// `nix/tests/<name>.test.sh` を、exe の `claude-hook <name>` を呼ぶ包みに流す
fn suite(name: &str) {
    if !available() {
        return;
    }
    let t = TempDir::new(&format!("suite-{name}"));
    let exe = env!("CARGO_BIN_EXE_dotfiles-win");
    let wrapper = t.write(
        "hook.sh",
        &format!("#!/usr/bin/env bash\nexec '{exe}' claude-hook {name}\n"),
    );
    let test = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../nix/tests")
        .join(format!("{name}.test.sh"));
    let out = Command::new("bash")
        .arg(&test)
        .arg(&wrapper)
        .env("TMPDIR", t.path())
        .output()
        .expect("bash を起こせない");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let failed: Vec<&str> = stdout
        .lines()
        .filter(|l| l.starts_with("  FAIL") || l.starts_with("       "))
        .collect();
    assert!(
        out.status.success(),
        "{name}.test.sh が Rust の口で落ちた:\n{}\n(最後の行: {})\nstderr: {}",
        failed.join("\n"),
        stdout.lines().last().unwrap_or(""),
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn xref_guard_suite() {
    suite("xref-guard");
}

#[test]
fn gist_guard_suite() {
    suite("gist-guard");
}

#[test]
fn install_iac_guard_suite() {
    suite("install-iac-guard");
}
