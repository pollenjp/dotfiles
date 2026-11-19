//! runner の exe を `claude-<名前>` の名前で写すと launcher として動く (claude-accounts の手順が置く `claude-<名前>.exe`。Linux と Windows の両方)。
//!
//! ## 確かめること
//!
//! - 用意されていない (`~/.claude-<名前>\settings.json` が無い) と、Claude Code を起こさずに 1 と「まだ用意されていません」・dotfiles apply
//! - settings.json が実体なら 1 と「リンクではありません」(片付け方)
//! - (Unix) settings.json がリンクでも、projects が ~/.claude/projects へのリンクでなければ 1
//! - (Unix) 用意されていれば、PATH の claude に引数をそのまま渡し、CLAUDE_CONFIG_DIR を薄い dir にし、ANTHROPIC_API_KEY などを外し、
//!   子の終了コードで終わる。PATH に claude が無ければ 127

mod common;

use common::TempDir;
use std::path::PathBuf;
use std::process::Command;

struct World {
    t: TempDir,
}

impl World {
    fn new() -> Self {
        let t = TempDir::new("launcher");
        t.write("home/.claude/settings.json", "{}\n");
        std::fs::create_dir_all(t.join("bin")).unwrap();
        std::fs::create_dir_all(t.join("fakebin")).unwrap();
        let exe = t
            .join("bin")
            .join(format!("claude-tester{}", std::env::consts::EXE_SUFFIX));
        std::fs::copy(env!("CARGO_BIN_EXE_dotfiles-win"), &exe).unwrap();
        World { t }
    }

    fn home(&self) -> PathBuf {
        self.t.join("home")
    }

    fn run(&self, args: &[&str]) -> (i32, String, String) {
        let exe = self
            .t
            .join("bin")
            .join(format!("claude-tester{}", std::env::consts::EXE_SUFFIX));
        let o = Command::new(exe)
            .args(args)
            .env("USERPROFILE", self.home())
            .env("PATH", self.t.join("fakebin"))
            .env("ANTHROPIC_API_KEY", "secret")
            .env("CLAUDE_CODE_OAUTH_TOKEN", "secret")
            .env("CLAUDE_CONFIG_DIR", "/somewhere/else")
            .output()
            .unwrap();
        (
            o.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&o.stdout).into_owned(),
            String::from_utf8_lossy(&o.stderr).into_owned(),
        )
    }
}

#[test]
fn refuses_until_prepared() {
    let w = World::new();
    let (code, out, err) = w.run(&["-p", "hi"]);
    assert_eq!(code, 1, "{out}\n{err}");
    assert!(err.contains("claude-tester: "), "{err}");
    assert!(err.contains("まだ用意されていません"), "{err}");
    assert!(err.contains("dotfiles apply"), "{err}");
    // Claude Code が先に作った実体
    w.t.write("home/.claude-tester/settings.json", "{}\n");
    let (code, _, err) = w.run(&[]);
    assert_eq!(code, 1, "{err}");
    assert!(err.contains("リンクではありません"), "{err}");
}

#[cfg(unix)]
#[test]
fn passes_arguments_and_exit_code_to_claude() {
    use std::os::unix::fs::PermissionsExt;
    let w = World::new();
    std::fs::create_dir_all(w.home().join(".claude-tester")).unwrap();
    std::os::unix::fs::symlink(
        w.home().join(".claude").join("settings.json"),
        w.home().join(".claude-tester").join("settings.json"),
    )
    .unwrap();
    // projects の junction が無ければ起こさない
    let (code, _, err) = w.run(&[]);
    assert_eq!(code, 1, "{err}");
    assert!(err.contains("projects"), "{err}");
    std::fs::create_dir_all(w.home().join(".claude").join("projects")).unwrap();
    std::os::unix::fs::symlink(
        w.home().join(".claude").join("projects"),
        w.home().join(".claude-tester").join("projects"),
    )
    .unwrap();
    // PATH に claude が無い
    let (code, _, err) = w.run(&[]);
    assert_eq!(code, 127, "{err}");
    assert!(err.contains("PATH に見つかりません"), "{err}");
    let claude = w.t.write(
        "fakebin/claude",
        "#!/bin/sh\necho \"dir=$CLAUDE_CONFIG_DIR\"\necho \"key=${ANTHROPIC_API_KEY-unset}\"\necho \"oauth=${CLAUDE_CODE_OAUTH_TOKEN-unset}\"\nfor a in \"$@\"; do echo \"arg=$a\"; done\nexit 7\n",
    );
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
    let (code, out, err) = w.run(&["-p", "日本語 の 引数", "--model", "x"]);
    assert_eq!(code, 7, "{out}\n{err}");
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(
        lines,
        vec![
            format!("dir={}", w.home().join(".claude-tester").display()).as_str(),
            "key=unset",
            "oauth=unset",
            "arg=-p",
            "arg=日本語 の 引数",
            "arg=--model",
            "arg=x",
        ]
    );
}
