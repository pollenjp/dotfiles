//! runner の exe に埋めるファイルは win/runner の中だけにする (dotfiles-private の docs/adr/117_win_runner_exe_release_*)。
//!
//! Release の exe は、clone の HEAD の `win/runner` の git の tree の hash (key) で選ぶ (`.github/workflows/win-runner-release.yml`・
//! `win/powershell/Invoke-DotfilesRunner.ps1`)。exe が win/runner の外のファイルを `include_str!`・`include_bytes!` で埋めると、そのファイルが
//! 変わっても key が変わらず、古い中身の exe が選ばれる。外のファイルは、動くときに clone から読む (`steps::t3_code_settings` の
//! managed-settings.json と同じ形)。
//!
//! ## 確かめること
//!
//! - `src` の下の `include_str!("…")`・`include_bytes!("…")`・`include!("…")`・`#[path = "…"]` の字を拾い、その .rs の場所から解いたパスが
//!   win/runner の下にある
//! - build script (`build.rs`) を置かない (置くなら、それが読むファイルも key に入るかを確かめ直す)
//! - `Cargo.toml` の依存に `path =` (win/runner の外の crate を読みうる) を書かない

use std::path::{Component, Path, PathBuf};

/// `dir` の下の .rs を全部 (相対パスの順)
fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().path())
        .collect();
    entries.sort();
    for p in entries {
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|e| e == "rs") {
            out.push(p);
        }
    }
}

/// `include_str!("…")`・`include_bytes!("…")`・`include!("…")`・`#[path = "…"]` の中の字 (文字列の literal で書いたものだけ。concat! などは
/// 使っていない)
fn embedded(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    for mac in [
        "include_str!(\"",
        "include_bytes!(\"",
        "include!(\"",
        "#[path = \"",
    ] {
        let mut rest = text;
        while let Some(i) = rest.find(mac) {
            let after = &rest[i + mac.len()..];
            if let Some(end) = after.find('"') {
                found.push(after[..end].to_string());
            }
            rest = after;
        }
    }
    found
}

/// `..` と `.` を畳んだパス (ファイルが無くても解く)
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

#[test]
fn embeds_only_files_under_win_runner() {
    let root = normalize(Path::new(env!("CARGO_MANIFEST_DIR")));
    let mut files = Vec::new();
    rust_files(&root.join("src"), &mut files);
    assert!(!files.is_empty());
    let mut outside = Vec::new();
    for f in &files {
        let text = std::fs::read_to_string(f).unwrap();
        for rel in embedded(&text) {
            let target = normalize(&f.parent().unwrap().join(&rel));
            if !target.starts_with(&root) {
                outside.push(format!(
                    "{}: {rel}",
                    f.strip_prefix(&root).unwrap().display()
                ));
            }
        }
    }
    assert!(
        outside.is_empty(),
        "win/runner の外を exe に埋めている (動くときに clone から読む): {outside:?}"
    );
}

#[test]
fn finds_embedded_paths() {
    let text = "const A: &str = include_str!(\"../a.json\");\nlet b = include_bytes!(\"b.bin\");\ninclude!(\"c.rs\");\n#[path = \"d.rs\"]";
    assert_eq!(embedded(text), vec!["../a.json", "b.bin", "c.rs", "d.rs"]);
}

/// build script は無い (置くなら、読むファイルが key (win/runner の tree) に入るかを確かめ直す)
#[test]
fn has_no_build_script() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    assert!(
        !root.join("build.rs").exists(),
        "build.rs を置くなら、それが読むファイルが win/runner の中にあるかを確かめ、この試験を直す"
    );
}

/// 依存に path = を書かない (win/runner の外の crate の中身は key に入らない)
#[test]
fn has_no_path_dependencies() {
    let text =
        std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml")).unwrap();
    let bad: Vec<&str> = text
        .lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .filter(|l| l.contains("path =") || l.contains("path="))
        .collect();
    assert!(
        bad.is_empty(),
        "Cargo.toml の path の依存は key に入らない: {bad:?}"
    );
}
