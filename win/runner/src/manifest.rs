//! `win/manifest.toml` を読み、置き先を解いた計画にする。
//!
//! 検証の決まりと文言は `nix/lib/windows-files.nix` (WSL の `bootstrap-windows-files.sh` が使う) と同じにする。CI の Linux の job は
//! `tests/manifest_parity.rs` で、同じ manifest を両方に通して突き合わせる (dotfiles-private の docs/adr/058_win_runner_bootstrap_* §2 H)。
//! 加えて、Windows のパスの要素として読めないもの (`:` を含む要素。ドライブや代替データストリームに読まれる) も止める (Nix の側には無い)。
//!
//! Nix との違いで、残しているもの (どちらも本物の manifest は CI の `bootstrap-windows-files.sh --check` が守るので、困らない):
//!
//! - 置き先の重複を比べる小文字化は Unicode 全体 (Nix は ASCII だけ)。NTFS は `Ä.json` と `ä.json` も同じファイルとして扱うので、
//!   runner は止める
//! - TOML は 1.1 として読む (toml の crate の版)。`"\e"` や改行を含む inline table など、Nix の fromTOML (TOML 1.0) が止める書き方を
//!   runner は通す
//!
//! パスは要素ごとに `push` する。`Path::join` に `C:/…` のような要素を渡すと、Windows では前のパスが捨てられるため。

use std::path::{Path, PathBuf};

/// 置き先の根 (`%USERPROFILE%`・`%APPDATA%`・`%LOCALAPPDATA%`)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Roots {
    pub user_profile: PathBuf,
    pub app_data: PathBuf,
    pub local_app_data: PathBuf,
}

impl Roots {
    /// Windows のホームから、Nix と同じく `<home>/AppData/Roaming`・`<home>/AppData/Local` を作る (`manifest --windows-home`・試すとき)。
    pub fn from_home(home: &Path) -> Self {
        let mut app_data = home.to_path_buf();
        app_data.push("AppData");
        let mut local = app_data.clone();
        app_data.push("Roaming");
        local.push("Local");
        Roots {
            user_profile: home.to_path_buf(),
            app_data,
            local_app_data: local,
        }
    }

    /// Windows の環境変数から作る。無ければ、どれが無いかを返す。
    pub fn from_env(get: &dyn Fn(&str) -> Option<String>) -> Result<Self, String> {
        let var = |name: &str| -> Result<PathBuf, String> {
            match get(name) {
                Some(v) if !v.is_empty() => Ok(PathBuf::from(v)),
                _ => Err(format!(
                    "環境変数 {name} がありません (runner は Windows で流す。試すときは --windows-home か環境変数を渡す)"
                )),
            }
        };
        Ok(Roots {
            user_profile: var("USERPROFILE")?,
            app_data: var("APPDATA")?,
            local_app_data: var("LOCALAPPDATA")?,
        })
    }

    fn get(&self, root: &str) -> Option<&Path> {
        match root {
            "%USERPROFILE%" => Some(&self.user_profile),
            "%APPDATA%" => Some(&self.app_data),
            "%LOCALAPPDATA%" => Some(&self.local_app_data),
            _ => None,
        }
    }
}

/// 計画の 1 件。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlanFile {
    /// コピー元 (絶対パス)
    pub src: PathBuf,
    /// repo からの相対パス (案内用。区切りは `/`)
    pub repo_path: String,
    /// 置き先 (Windows のパス)
    pub dst: PathBuf,
    /// 置き先を書き換えたときに出す文
    pub hint: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub files: Vec<PlanFile>,
}

/// repo の `win/manifest.toml` を読んで計画にする。誤りは `win/manifest.toml: …` の文で返す。
pub fn load(repo: &Path, roots: &Roots) -> Result<Plan, String> {
    let path = repo.join("win").join("manifest.toml");
    let text = std::fs::read_to_string(&path)
        .map_err(|e| fail(&format!("見つかりません: {} ({e})", path.display())))?;
    parse(&text, repo, roots)
}

fn fail(msg: &str) -> String {
    format!("win/manifest.toml: {msg}")
}

/// `/` で分けた要素。空の要素・`.`・`..` があれば false (Nix の cleanSegments)。
fn clean_segments(s: &str) -> bool {
    s.split('/').all(|x| !x.is_empty() && x != "." && x != "..")
}

/// Windows のパスの要素として読めないもの (`:` を含む要素) が無いか。
fn windows_safe(s: &str) -> bool {
    !s.contains(':')
}

fn push_segments(base: &Path, rel: &str) -> PathBuf {
    let mut p = base.to_path_buf();
    for seg in rel.split('/') {
        p.push(seg);
    }
    p
}

/// manifest の文から計画を作る (`load` の中身。試験はここを呼ぶ)。
pub fn parse(text: &str, repo: &Path, roots: &Roots) -> Result<Plan, String> {
    let manifest: toml::Table = text
        .parse()
        .map_err(|e| fail(&format!("TOML として読めません: {e}")))?;

    let unknown_top: Vec<&str> = manifest
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "files")
        .collect();
    if !unknown_top.is_empty() {
        return Err(fail(&format!(
            "知らないキーがあります: {} (書けるのは [[files]] だけ)",
            unknown_top.join(", ")
        )));
    }
    let entries: &[toml::Value] = match manifest.get("files") {
        None => &[],
        Some(toml::Value::Array(a)) => a,
        Some(_) => return Err(fail("files は [[files]] の表の並びで書いてください")),
    };

    let mut files = Vec::new();
    for (i, entry) in entries.iter().enumerate() {
        files.push(to_file(i + 1, entry, repo, roots)?);
    }

    // Windows (NTFS) は大文字小文字を区別しないので、置き先の重複は小文字にして比べる
    let lowered: Vec<String> = files
        .iter()
        .map(|f| f.dst.to_string_lossy().to_lowercase())
        .collect();
    let mut dupes: Vec<String> = lowered
        .iter()
        .filter(|d| lowered.iter().filter(|x| x == d).count() > 1)
        .cloned()
        .collect();
    dupes.sort();
    dupes.dedup();
    if !dupes.is_empty() {
        return Err(fail(&format!(
            "dst が重複しています (Windows は大文字小文字を区別しない): {}",
            dupes.join(", ")
        )));
    }
    Ok(Plan { files })
}

fn to_file(i: usize, entry: &toml::Value, repo: &Path, roots: &Roots) -> Result<PlanFile, String> {
    let at = format!("files[{i}]");
    let Some(f) = entry.as_table() else {
        return Err(fail(&format!("{at}: [[files]] の表で書いてください")));
    };
    let unknown: Vec<&str> = f
        .keys()
        .map(String::as_str)
        .filter(|k| !["src", "dst", "hint", "base"].contains(k))
        .collect();
    if !unknown.is_empty() {
        return Err(fail(&format!(
            "{at}: 知らないキーがあります: {} (書けるのは src / dst / hint / base)",
            unknown.join(", ")
        )));
    }
    if !(f.contains_key("src") && f.contains_key("dst")) {
        return Err(fail(&format!("{at}: src と dst は必須です")));
    }
    let string = |k: &str| f.get(k).map(|v| v.as_str());
    let (Some(Some(src)), Some(Some(dst))) = (string("src"), string("dst")) else {
        return Err(fail(&format!(
            "{at}: src / dst / hint / base は文字列で書いてください"
        )));
    };
    let hint = match string("hint") {
        None => None,
        Some(Some(h)) => Some(h.to_string()),
        Some(None) => {
            return Err(fail(&format!(
                "{at}: src / dst / hint / base は文字列で書いてください"
            )));
        }
    };
    let base = match string("base") {
        None => "win",
        Some(Some(b)) => b,
        Some(None) => {
            return Err(fail(&format!(
                "{at}: src / dst / hint / base は文字列で書いてください"
            )));
        }
    };
    if base != "win" && base != "nix" {
        return Err(fail(&format!(
            "{at}: base は \"win\" (既定) か \"nix\" で書いてください: {base}"
        )));
    }
    if src.contains('\\') {
        return Err(fail(&format!(
            "{at}: src に \\ は書けません (区切りは /): {src}"
        )));
    }
    if src.starts_with('/') {
        return Err(fail(&format!(
            "{at}: src は {base}/ からの相対パスで書いてください: {src}"
        )));
    }
    if !clean_segments(src) {
        return Err(fail(&format!(
            "{at}: src に空の要素・.・.. は書けません: {src}"
        )));
    }
    if !windows_safe(src) {
        return Err(fail(&format!(
            "{at}: src の要素に : は書けません (Windows ではドライブや代替データストリームに読まれる): {src}"
        )));
    }
    let src_path = push_segments(&repo.join(base), src);
    let regular = std::fs::symlink_metadata(&src_path)
        .map(|m| m.file_type().is_file())
        .unwrap_or(false);
    if !regular {
        return Err(fail(&format!(
            "{at}: src が見つからないか、通常のファイルではありません: {base}/{src}"
        )));
    }
    if dst.contains('\\') {
        return Err(fail(&format!(
            "{at}: dst に \\ は書けません (区切りは /): {dst}"
        )));
    }
    let root_error = || {
        fail(&format!(
            "{at}: dst は %USERPROFILE% / %APPDATA% / %LOCALAPPDATA% のどれかで始めてください: {dst}"
        ))
    };
    // Nix の builtins.match "(%[A-Z]+%)/(.*)"
    let Some((root, rest)) = dst.split_once('/') else {
        return Err(root_error());
    };
    let root_ok = root.len() > 2
        && root.starts_with('%')
        && root.ends_with('%')
        && root[1..root.len() - 1]
            .chars()
            .all(|c| c.is_ascii_uppercase());
    let Some(root_path) = roots.get(root).filter(|_| root_ok) else {
        return Err(root_error());
    };
    if !clean_segments(rest) {
        return Err(fail(&format!(
            "{at}: dst に空の要素・.・.. は書けません: {dst}"
        )));
    }
    if !windows_safe(rest) {
        return Err(fail(&format!(
            "{at}: dst の要素に : は書けません (Windows ではドライブや代替データストリームに読まれる): {dst}"
        )));
    }
    Ok(PlanFile {
        src: src_path,
        repo_path: format!("{base}/{src}"),
        dst: push_segments(root_path, rest),
        hint,
    })
}

/// 計画を `nix/lib/windows-files.nix` と同じ形の JSON にする (`manifest --json`)。
pub fn plan_json(plan: &Plan) -> serde_json::Value {
    let files: Vec<serde_json::Value> = plan
        .files
        .iter()
        .map(|f| {
            serde_json::json!({
                "src": f.src.to_string_lossy(),
                "repoPath": f.repo_path,
                "dst": f.dst.to_string_lossy(),
                "hint": f.hint,
            })
        })
        .collect();
    serde_json::json!({ "version": 1, "files": files })
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - `nix/lib/windows-files.nix` の誤りを、同じ文で全部止める (知らない top のキー・files が表の並びでない・表でない・知らないキー・
    //!   src/dst なし・文字列でない・base の値・src の `\`・絶対・空の要素/./..・無い/通常でない・dst の `\`・根が違う・dst の要素・
    //!   大文字小文字だけ違う重複)
    //! - `:` を含む要素も止める (Nix には無い決まり)
    //! - 置き先の根 (`%APPDATA%` → `<home>/AppData/Roaming`)・`base = "nix"`・hint の有無・files が無い manifest
    //! - Nix と同じ形の JSON

    use super::*;
    use crate::testutil::TempDir;

    fn repo() -> TempDir {
        let t = TempDir::new("manifest");
        t.write("win/orca/keybindings.json", "{}\n");
        t.write("win/herdr/config.toml", "x = 1\n");
        t.write("nix/pkgs/herdr-core/releases.json", "{}\n");
        std::fs::create_dir_all(t.path().join("win").join("adir")).unwrap();
        t
    }

    fn roots() -> Roots {
        Roots::from_home(Path::new("/mnt/c/Users/u"))
    }

    fn err(text: &str) -> String {
        let r = repo();
        parse(text, r.path(), &roots()).unwrap_err()
    }

    fn file(src: &str, dst: &str) -> String {
        format!("[[files]]\nsrc = \"{src}\"\ndst = \"{dst}\"\n")
    }

    #[test]
    fn resolves_roots_and_bases() {
        let r = repo();
        let text = "\
[[files]]
src = \"orca/keybindings.json\"
dst = \"%USERPROFILE%/.orca/keybindings.json\"
hint = \"読み直す\"

[[files]]
src = \"herdr/config.toml\"
dst = \"%APPDATA%/herdr/config.toml\"

[[files]]
base = \"nix\"
src = \"pkgs/herdr-core/releases.json\"
dst = \"%LOCALAPPDATA%/x/releases.json\"
";
        let plan = parse(text, r.path(), &roots()).unwrap();
        assert_eq!(plan.files.len(), 3);
        let f0 = &plan.files[0];
        assert_eq!(f0.src, push_segments(r.path(), "win/orca/keybindings.json"));
        assert_eq!(f0.repo_path, "win/orca/keybindings.json");
        assert_eq!(
            f0.dst,
            push_segments(Path::new("/mnt/c/Users/u"), ".orca/keybindings.json")
        );
        assert_eq!(f0.hint.as_deref(), Some("読み直す"));
        assert_eq!(
            plan.files[1].dst,
            push_segments(
                Path::new("/mnt/c/Users/u"),
                "AppData/Roaming/herdr/config.toml"
            )
        );
        assert_eq!(plan.files[1].hint, None);
        assert_eq!(plan.files[2].repo_path, "nix/pkgs/herdr-core/releases.json");
        assert_eq!(
            plan.files[2].src,
            push_segments(r.path(), "nix/pkgs/herdr-core/releases.json")
        );
        assert_eq!(
            plan.files[2].dst,
            push_segments(Path::new("/mnt/c/Users/u"), "AppData/Local/x/releases.json")
        );
    }

    #[test]
    fn empty_manifest_has_no_files() {
        let r = repo();
        assert!(parse("", r.path(), &roots()).unwrap().files.is_empty());
        assert!(
            parse("files = []\n", r.path(), &roots())
                .unwrap()
                .files
                .is_empty()
        );
    }

    #[test]
    fn rejects_like_nix() {
        let cases: Vec<(String, &str)> = vec![
            (
                "x = 1\n".into(),
                "win/manifest.toml: 知らないキーがあります: x (書けるのは [[files]] だけ)",
            ),
            (
                "files = \"a\"\n".into(),
                "win/manifest.toml: files は [[files]] の表の並びで書いてください",
            ),
            (
                "files = [1]\n".into(),
                "win/manifest.toml: files[1]: [[files]] の表で書いてください",
            ),
            (
                format!(
                    "{}other = 1\n",
                    file("orca/keybindings.json", "%USERPROFILE%/a")
                ),
                "win/manifest.toml: files[1]: 知らないキーがあります: other (書けるのは src / dst / hint / base)",
            ),
            (
                "[[files]]\nsrc = \"orca/keybindings.json\"\n".into(),
                "win/manifest.toml: files[1]: src と dst は必須です",
            ),
            (
                "[[files]]\nsrc = 1\ndst = \"%USERPROFILE%/a\"\n".into(),
                "win/manifest.toml: files[1]: src / dst / hint / base は文字列で書いてください",
            ),
            (
                format!(
                    "{}hint = 1\n",
                    file("orca/keybindings.json", "%USERPROFILE%/a")
                ),
                "win/manifest.toml: files[1]: src / dst / hint / base は文字列で書いてください",
            ),
            (
                format!(
                    "{}base = \"etc\"\n",
                    file("orca/keybindings.json", "%USERPROFILE%/a")
                ),
                "win/manifest.toml: files[1]: base は \"win\" (既定) か \"nix\" で書いてください: etc",
            ),
            (
                "[[files]]\nsrc = 'orca\\keybindings.json'\ndst = \"%USERPROFILE%/a\"\n".into(),
                "win/manifest.toml: files[1]: src に \\ は書けません (区切りは /): orca\\keybindings.json",
            ),
            (
                file("/etc/passwd", "%USERPROFILE%/a"),
                "win/manifest.toml: files[1]: src は win/ からの相対パスで書いてください: /etc/passwd",
            ),
            (
                file("orca//keybindings.json", "%USERPROFILE%/a"),
                "win/manifest.toml: files[1]: src に空の要素・.・.. は書けません: orca//keybindings.json",
            ),
            (
                file("../nix/x", "%USERPROFILE%/a"),
                "win/manifest.toml: files[1]: src に空の要素・.・.. は書けません: ../nix/x",
            ),
            (
                file("orca/./keybindings.json", "%USERPROFILE%/a"),
                "win/manifest.toml: files[1]: src に空の要素・.・.. は書けません: orca/./keybindings.json",
            ),
            (
                file("orca/missing.json", "%USERPROFILE%/a"),
                "win/manifest.toml: files[1]: src が見つからないか、通常のファイルではありません: win/orca/missing.json",
            ),
            (
                file("adir", "%USERPROFILE%/a"),
                "win/manifest.toml: files[1]: src が見つからないか、通常のファイルではありません: win/adir",
            ),
            (
                "[[files]]\nsrc = \"orca/keybindings.json\"\ndst = '%USERPROFILE%\\a'\n".into(),
                "win/manifest.toml: files[1]: dst に \\ は書けません (区切りは /): %USERPROFILE%\\a",
            ),
            (
                file("orca/keybindings.json", "%TEMP%/a"),
                "win/manifest.toml: files[1]: dst は %USERPROFILE% / %APPDATA% / %LOCALAPPDATA% のどれかで始めてください: %TEMP%/a",
            ),
            (
                file("orca/keybindings.json", "%USERPROFILE%"),
                "win/manifest.toml: files[1]: dst は %USERPROFILE% / %APPDATA% / %LOCALAPPDATA% のどれかで始めてください: %USERPROFILE%",
            ),
            (
                file("orca/keybindings.json", "%userprofile%/a"),
                "win/manifest.toml: files[1]: dst は %USERPROFILE% / %APPDATA% / %LOCALAPPDATA% のどれかで始めてください: %userprofile%/a",
            ),
            (
                file("orca/keybindings.json", "C:/Users/a"),
                "win/manifest.toml: files[1]: dst は %USERPROFILE% / %APPDATA% / %LOCALAPPDATA% のどれかで始めてください: C:/Users/a",
            ),
            (
                file("orca/keybindings.json", "%USERPROFILE%/"),
                "win/manifest.toml: files[1]: dst に空の要素・.・.. は書けません: %USERPROFILE%/",
            ),
            (
                file("orca/keybindings.json", "%APPDATA%/../a"),
                "win/manifest.toml: files[1]: dst に空の要素・.・.. は書けません: %APPDATA%/../a",
            ),
            (
                format!(
                    "{}{}",
                    file("orca/keybindings.json", "%USERPROFILE%/A.json"),
                    file("herdr/config.toml", "%USERPROFILE%/a.json")
                ),
                "win/manifest.toml: dst が重複しています (Windows は大文字小文字を区別しない): /mnt/c/users/u/a.json",
            ),
        ];
        for (text, want) in cases {
            let got = err(&text);
            let want = want.replace(
                "/mnt/c/users/u/a.json",
                &push_segments(Path::new("/mnt/c/users/u"), "a.json").to_string_lossy(),
            );
            assert_eq!(got, want, "manifest:\n{text}");
        }
    }

    #[test]
    fn rejects_colon_segments() {
        assert!(err(&file("C:/x", "%USERPROFILE%/a")).contains("src の要素に : は書けません"));
        assert!(
            err(&file("orca/keybindings.json", "%USERPROFILE%/a:stream"))
                .contains("dst の要素に : は書けません")
        );
    }

    #[test]
    fn later_entries_are_numbered() {
        let text = format!(
            "{}{}",
            file("orca/keybindings.json", "%USERPROFILE%/a"),
            file("orca/keybindings.json", "%TEMP%/b")
        );
        assert!(err(&text).starts_with("win/manifest.toml: files[2]: dst は"));
    }

    #[test]
    fn plan_json_has_nix_shape() {
        let r = repo();
        let plan = parse(
            &file(
                "orca/keybindings.json",
                "%USERPROFILE%/.orca/keybindings.json",
            ),
            r.path(),
            &roots(),
        )
        .unwrap();
        let v = plan_json(&plan);
        assert_eq!(v["version"], 1);
        let f = &v["files"][0];
        assert_eq!(f["repoPath"], "win/orca/keybindings.json");
        assert!(f["hint"].is_null());
        assert!(f["src"].as_str().unwrap().ends_with("keybindings.json"));
        assert!(f["dst"].as_str().unwrap().ends_with("keybindings.json"));
    }
}
