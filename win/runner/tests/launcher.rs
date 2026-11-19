//! runner の exe を `claude-<名前>` の名前で写すと launcher として動く (claude-accounts の手順が置く `claude-<名前>.exe`。Linux と Windows の両方)。
//!
//! ## 確かめること
//!
//! - 用意されていない (`~/.claude-<名前>\settings.json` が無い) と、Claude Code を起こさずに 1 と「まだ用意されていません」・add の打ち直し
//! - settings.json が実体なら 1 と「リンクではありません」(片付け方)
//! - (Unix) settings.json がリンクでも、projects が ~/.claude/projects へのリンクでなければ 1
//! - (Unix) 用意されていれば、PATH の claude に引数をそのまま渡し、CLAUDE_CONFIG_DIR を薄い dir にし、ANTHROPIC_API_KEY などを外し、
//!   子の終了コードで終わる。PATH に claude が無ければ 127
//! - 既定でも登録 (claude-account add) でもない名前は 2 (tester は試験の家の登録に subscription で書く)
//! - (Unix) token のアカウント token1: token のファイルが無ければ 1 と忠告。平文なら claude に CLAUDE_CODE_OAUTH_TOKEN が届く。op の参照なら
//!   PATH の op-reason に理由・read・参照を渡して読んだ値が届き、op-reason が 75 なら 75 で claude は起きない
//! - exe の名前が claude-account なら管理のコマンド (help token を出す・知らない名前の check は 2)

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
        t.write(
            "home/.config/claude-accounts/accounts.json",
            "{\"version\":1,\"accounts\":{\"tester\":{\"mode\":\"subscription\"},\"token1\":{\"mode\":\"token\"}}}\n",
        );
        std::fs::create_dir_all(t.join("bin")).unwrap();
        std::fs::create_dir_all(t.join("fakebin")).unwrap();
        for name in ["tester", "token1", "nosuch", "account"] {
            let exe = t
                .join("bin")
                .join(format!("claude-{name}{}", std::env::consts::EXE_SUFFIX));
            std::fs::copy(env!("CARGO_BIN_EXE_dotfiles-win"), &exe).unwrap();
        }
        World { t }
    }

    fn home(&self) -> PathBuf {
        self.t.join("home")
    }

    fn run(&self, args: &[&str]) -> (i32, String, String) {
        self.run_as("tester", args)
    }

    /// exe を claude-<name> の名前で起こす
    fn run_as(&self, name: &str, args: &[&str]) -> (i32, String, String) {
        let exe = self
            .t
            .join("bin")
            .join(format!("claude-{name}{}", std::env::consts::EXE_SUFFIX));
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
    // 登録のアカウントの用意は add の打ち直し (既定なら dotfiles apply)
    assert!(
        err.contains("claude-account add tester --mode subscription"),
        "{err}"
    );
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

#[test]
fn refuses_names_that_are_not_accounts() {
    let w = World::new();
    let (code, _, err) = w.run_as("nosuch", &[]);
    assert_eq!(code, 2, "{err}");
    assert!(err.contains("claude-account add nosuch"), "{err}");
}

#[test]
fn manager_runs_under_its_name() {
    let w = World::new();
    let (code, out, err) = w.run_as("account", &["help", "token", "token1"]);
    assert_eq!(code, 0, "{err}");
    assert!(
        out.contains("claude-account add token1 --mode token"),
        "{out}"
    );
    let (code, _, _) = w.run_as("account", &["check", "nosuch"]);
    assert_eq!(code, 2);
}

/// token1 (登録の token のアカウント) の用意 (settings.json と projects のリンク) と偽の claude
#[cfg(unix)]
fn prepare_token1(w: &World) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(w.home().join(".claude-token1")).unwrap();
    std::fs::create_dir_all(w.home().join(".claude").join("projects")).unwrap();
    for rel in ["settings.json", "projects"] {
        std::os::unix::fs::symlink(
            w.home().join(".claude").join(rel),
            w.home().join(".claude-token1").join(rel),
        )
        .unwrap();
    }
    let claude = w.t.write(
        "fakebin/claude",
        "#!/bin/sh\necho \"dir=$CLAUDE_CONFIG_DIR\"\necho \"key=${ANTHROPIC_API_KEY-unset}\"\necho \"oauth=${CLAUDE_CODE_OAUTH_TOKEN-unset}\"\nexit 5\n",
    );
    std::fs::set_permissions(&claude, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[cfg(unix)]
#[test]
fn token_account_passes_the_token() {
    use std::os::unix::fs::PermissionsExt;
    let w = World::new();
    prepare_token1(&w);
    let (code, out, err) = w.run_as("token1", &["-p", "hi"]);
    assert_eq!((code, out.as_str()), (1, ""), "{err}");
    assert!(err.contains("token がありません"), "{err}");
    assert!(err.contains("claude-account set-token token1"), "{err}");
    w.t.write(
        "home/.config/claude-accounts/token1.env",
        "CLAUDE_CODE_OAUTH_TOKEN=dummy-plain-7\n",
    );
    let (code, out, err) = w.run_as("token1", &["-p", "hi"]);
    assert_eq!(code, 5, "{out}\n{err}");
    assert_eq!(
        out.lines().collect::<Vec<_>>(),
        vec![
            format!("dir={}", w.home().join(".claude-token1").display()).as_str(),
            "key=unset",
            "oauth=dummy-plain-7",
        ]
    );
    assert!(!err.contains("dummy"), "{err}");
    // op の参照: PATH の op-reason が理由・read・参照を受け、読んだ値が届く
    w.t.write(
        "home/.config/claude-accounts/token1.env",
        "CLAUDE_CODE_OAUTH_TOKEN=op://vault/item/field\n",
    );
    let log = w.t.join("op-reason.args");
    let op = w.t.write(
        "fakebin/op-reason",
        &format!(
            "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done >\"{}\"\nprintf 'dummy-op-7\\n'\n",
            log.display()
        ),
    );
    std::fs::set_permissions(&op, std::fs::Permissions::from_mode(0o755)).unwrap();
    let (code, out, err) = w.run_as("token1", &[]);
    assert_eq!(code, 5, "{out}\n{err}");
    assert!(out.lines().any(|l| l == "oauth=dummy-op-7"), "{out}");
    let args = std::fs::read_to_string(&log).unwrap();
    assert_eq!(
        args.lines().collect::<Vec<_>>(),
        vec![
            "--reason",
            "claude-token1 を起こすのに Claude Code の token (claude setup-token で出したもの) を読む",
            "read",
            "op://vault/item/field"
        ]
    );
    // op-reason が断られた (75): claude を起こさず 75
    std::fs::write(&op, "#!/bin/sh\nexit 75\n").unwrap();
    let (code, out, err) = w.run_as("token1", &[]);
    assert_eq!((code, out.as_str()), (75, ""), "{err}");
}
