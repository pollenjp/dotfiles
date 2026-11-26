//! `dotfiles-win` の exe をコマンドとして流す (本物の外のコマンドの口・hostname・git を使う。Linux と Windows の両方)。
//!
//! ## 確かめること
//!
//! - manifest: 本物の win/manifest.toml を通し、件数を出す
//! - files の手順の一通り: check は書かずに 3、runner.enable = true の apply は置いて記録して 0、もう一度の check は 0、Windows 側で
//!   変えると衝突 (diff と解き方) で 1 で書き戻さない、--force で上書き
//! - ホストの値の既定の場所 (USERNAME と hostname の小文字)。runner.enable でないホストの apply は止まり、何も書かない
//! - 知らない引数は 2

mod common;

use common::TempDir;
use std::path::{Path, PathBuf};
use std::process::Command;

fn exe() -> Command {
    Command::new(env!("CARGO_BIN_EXE_dotfiles-win"))
}

struct World {
    t: TempDir,
}

impl World {
    fn new(host: &str) -> Self {
        let t = TempDir::new("cli");
        t.write(
            "g/dotfiles/win/manifest.toml",
            "[[files]]\nsrc = \"app/a.json\"\ndst = \"%APPDATA%/app/a.json\"\nhint = \"読み直す\"\n",
        );
        t.write("g/dotfiles/win/app/a.json", "{\"a\": 1}\n");
        t.write("host.toml", host);
        World { t }
    }

    fn home(&self) -> PathBuf {
        self.t.join("home")
    }

    fn dst(&self) -> PathBuf {
        self.home()
            .join("AppData")
            .join("Roaming")
            .join("app")
            .join("a.json")
    }

    fn record(&self) -> PathBuf {
        self.home()
            .join("AppData")
            .join("Local")
            .join("dotfiles")
            .join("state")
            .join("windows-files.deployed.json")
    }

    fn run(&self, args: &[&str], host_file: bool) -> (i32, String, String) {
        let mut c = exe();
        c.args(args)
            .arg("--repo")
            .arg(self.t.join("g/dotfiles"))
            .env("USERPROFILE", self.home())
            .env("APPDATA", self.home().join("AppData").join("Roaming"))
            .env("LOCALAPPDATA", self.home().join("AppData").join("Local"))
            .env("USERNAME", "tester");
        if host_file {
            c.arg("--host-file").arg(self.t.join("host.toml"));
        }
        let o = c.output().unwrap();
        (
            o.status.code().unwrap_or(-1),
            String::from_utf8_lossy(&o.stdout).into_owned(),
            String::from_utf8_lossy(&o.stderr).into_owned(),
        )
    }
}

#[test]
fn manifest_of_the_repo_is_valid() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
    let o = exe()
        .arg("manifest")
        .arg("--repo")
        .arg(&repo)
        .output()
        .unwrap();
    let out = String::from_utf8_lossy(&o.stdout);
    assert_eq!(
        o.status.code(),
        Some(0),
        "{out}{}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert!(out.starts_with("win/manifest.toml: OK ("), "{out}");
}

#[test]
fn files_flow() {
    let w = World::new("[runner]\nenable = true\n");
    let (code, out, err) = w.run(&["check", "--steps", "files"], true);
    assert_eq!(code, 3, "{out}{err}");
    assert!(!w.dst().exists());

    let (code, out, err) = w.run(&["apply", "--steps", "files"], true);
    assert_eq!(code, 0, "{out}{err}");
    assert_eq!(std::fs::read_to_string(w.dst()).unwrap(), "{\"a\": 1}\n");
    assert!(w.record().exists());
    assert!(out.contains("読み直す"));

    let (code, out, _) = w.run(&["check", "--steps", "files"], true);
    assert_eq!(code, 0, "{out}");

    std::fs::write(w.dst(), "{\"a\": 2}\n").unwrap();
    let (code, out, _) = w.run(&["apply", "--steps", "files"], true);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("は Windows 側で変わっています"));
    assert!(out.contains("dotfiles apply --steps files --force"));
    assert_eq!(std::fs::read_to_string(w.dst()).unwrap(), "{\"a\": 2}\n");
    if common::which(if cfg!(windows) { "git.exe" } else { "git" }).is_some() {
        assert!(
            out.contains("-{\"a\": 2}") || out.contains("+{\"a\": 2}"),
            "{out}"
        );
    }

    let (code, out, _) = w.run(&["apply", "--steps", "files", "--force"], true);
    assert_eq!(code, 0, "{out}");
    assert_eq!(std::fs::read_to_string(w.dst()).unwrap(), "{\"a\": 1}\n");
}

#[test]
fn apply_is_blocked_while_wsl_owns_the_host() {
    let w = World::new("group = \"minimum\"\n");
    let (code, out, _) = w.run(&["apply", "--steps", "files"], true);
    assert_eq!(code, 1, "{out}");
    assert!(out.contains("apply は止めた"));
    assert!(!w.dst().exists());
    assert!(!w.record().exists());
}

#[test]
fn default_host_path_uses_username_and_hostname() {
    let Ok(o) = Command::new("hostname").output() else {
        eprintln!("hostname が無いので飛ばす");
        return;
    };
    let pc = String::from_utf8_lossy(&o.stdout).trim().to_lowercase();
    if pc.is_empty() {
        eprintln!("hostname が名前を返さないので飛ばす");
        return;
    }
    let w = World::new("");
    w.t.write(
        &format!("g/dotfiles-private/win/hosts/tester@{pc}.toml"),
        "group = \"minimum\"\n",
    );
    let (code, out, err) = w.run(&["list"], false);
    assert_eq!(code, 0, "{out}{err}");
    assert!(
        out.contains(&format!("tester@{pc}.toml (グループ minimum)")),
        "{out}"
    );
    // minimum では Windows の ntn が off
    assert!(out.contains("windowsNtn = false"), "{out}");
}

#[test]
fn bad_arguments_exit_2() {
    let o = exe().arg("check").arg("--nope").output().unwrap();
    assert_eq!(o.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&o.stderr).contains("知らない引数です: --nope"));
    let o = exe().output().unwrap();
    assert_eq!(o.status.code(), Some(2));
}
