//! runner の manifest の読み方を、WSL が使う `nix/lib/windows-files.nix` (nix-instantiate) と突き合わせる。
//!
//! ## 確かめること
//!
//! - 本物の `win/manifest.toml` の計画 (置き先を解いた JSON) が、nix-instantiate の計画と同じ
//! - 誤りのある manifest を両方が止め、誤りの無い manifest は両方が通して計画も同じ
//!
//! nix-instantiate が PATH に無ければ飛ばす (Windows の CI など)。`DOTFILES_WIN_NIX_PARITY=1` なら飛ばさずに落ちる (CI の Linux の job)。

mod common;

use common::{TempDir, which};
use dotfiles_win::manifest::{Roots, load, plan_json};
use std::path::{Path, PathBuf};
use std::process::Command;

const HOME: &str = "/mnt/c/Users/CHECK";

fn nix_available() -> bool {
    let found = which("nix-instantiate").is_some();
    if !found && std::env::var("DOTFILES_WIN_NIX_PARITY").as_deref() == Ok("1") {
        panic!("DOTFILES_WIN_NIX_PARITY=1 なのに nix-instantiate が PATH にありません");
    }
    found
}

fn lib_file() -> PathBuf {
    repo_root()
        .join("nix")
        .join("lib")
        .join("windows-files.nix")
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .canonicalize()
        .unwrap()
}

fn nix_plan(repo: &Path) -> Result<serde_json::Value, String> {
    let out = Command::new("nix-instantiate")
        .args(["--eval", "--strict", "--json"])
        .arg(lib_file())
        .args(["--argstr", "winDir"])
        .arg(repo.join("win"))
        .args(["--argstr", "windowsHome", HOME])
        .output()
        .expect("nix-instantiate を起こせない");
    if out.status.success() {
        Ok(serde_json::from_slice(&out.stdout).expect("nix-instantiate の出力が JSON でない"))
    } else {
        Err(String::from_utf8_lossy(&out.stderr).into_owned())
    }
}

fn rust_plan(repo: &Path) -> Result<serde_json::Value, String> {
    load(repo, &Roots::from_home(Path::new(HOME))).map(|p| plan_json(&p))
}

#[test]
fn real_manifest_matches_nix() {
    if !nix_available() {
        eprintln!("nix-instantiate が無いので飛ばす");
        return;
    }
    let repo = repo_root();
    let nix = nix_plan(&repo).expect("nix-instantiate が本物の manifest を通さない");
    let rust = rust_plan(&repo).expect("runner が本物の manifest を通さない");
    assert_eq!(rust, nix);
    assert!(!rust["files"].as_array().unwrap().is_empty());
}

#[test]
fn fixtures_are_judged_the_same() {
    if !nix_available() {
        eprintln!("nix-instantiate が無いので飛ばす");
        return;
    }
    let t = TempDir::new("parity");
    t.write("win/orca/keybindings.json", "{}\n");
    t.write("win/herdr/config.toml", "x = 1\n");
    t.write("nix/pkgs/herdr-core/releases.json", "{}\n");
    std::fs::create_dir_all(t.join("win/adir")).unwrap();
    let repo = t.path().canonicalize().unwrap();

    let file = |src: &str, dst: &str| format!("[[files]]\nsrc = \"{src}\"\ndst = \"{dst}\"\n");
    let good = [
        String::new(),
        format!(
            "{}hint = \"h\"\n",
            file(
                "orca/keybindings.json",
                "%USERPROFILE%/.orca/keybindings.json"
            )
        ),
        format!(
            "{}{}base = \"nix\"\nsrc = \"pkgs/herdr-core/releases.json\"\ndst = \"%LOCALAPPDATA%/r.json\"\n",
            file("herdr/config.toml", "%APPDATA%/herdr/config.toml"),
            "[[files]]\n"
        ),
    ];
    let bad = [
        "x = 1\n".to_string(),
        "files = \"a\"\n".to_string(),
        "files = [1]\n".to_string(),
        format!(
            "{}other = 1\n",
            file("orca/keybindings.json", "%USERPROFILE%/a")
        ),
        "[[files]]\nsrc = \"orca/keybindings.json\"\n".to_string(),
        "[[files]]\nsrc = 1\ndst = \"%USERPROFILE%/a\"\n".to_string(),
        format!(
            "{}base = \"etc\"\n",
            file("orca/keybindings.json", "%USERPROFILE%/a")
        ),
        "[[files]]\nsrc = 'orca\\keybindings.json'\ndst = \"%USERPROFILE%/a\"\n".to_string(),
        file("/etc/hostname", "%USERPROFILE%/a"),
        file("orca//keybindings.json", "%USERPROFILE%/a"),
        file("../nix/pkgs/herdr-core/releases.json", "%USERPROFILE%/a"),
        file("orca/missing.json", "%USERPROFILE%/a"),
        file("adir", "%USERPROFILE%/a"),
        "[[files]]\nsrc = \"orca/keybindings.json\"\ndst = '%USERPROFILE%\\a'\n".to_string(),
        file("orca/keybindings.json", "%TEMP%/a"),
        file("orca/keybindings.json", "%USERPROFILE%"),
        file("orca/keybindings.json", "%USERPROFILE%/"),
        file("orca/keybindings.json", "%APPDATA%/../a"),
        format!(
            "{}{}",
            file("orca/keybindings.json", "%USERPROFILE%/A.json"),
            file("herdr/config.toml", "%USERPROFILE%/a.json")
        ),
    ];
    for text in good.iter().chain(bad.iter()) {
        std::fs::write(repo.join("win").join("manifest.toml"), text).unwrap();
        let nix = nix_plan(&repo);
        let rust = rust_plan(&repo);
        match (&nix, &rust) {
            (Ok(n), Ok(r)) => assert_eq!(r, n, "manifest:\n{text}"),
            (Err(_), Err(_)) => {}
            _ => panic!("判定が違う manifest:\n{text}\nnix: {nix:?}\nrunner: {rust:?}"),
        }
        assert_eq!(rust.is_ok(), good.contains(text), "manifest:\n{text}");
    }
}
