//! リンク (Windows の junction と、Unix の symlink) の小さな道具。
//!
//! junction は `cmd /c mklink /J` で張る (stable の Rust に junction を作る API が無く、unsafe を入れない。dotfiles-private の
//! docs/adr/060_win_runner_core_*・docs/adr/064_win_w02_claude_skills_hub_*)。読むのは std の `read_link` (Windows の junction も読め、先は
//! `\\?\C:\…` の形で返る)。外すのは Windows が `remove_dir` (junction だけが消え、先は残る)、Unix が `remove_file`。

use crate::process::{CommandSpec, Sys};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// cmd が引用符の中でも読む・引用符の外で読む文字と、cmd の区切り文字 (`,` `;` `=`。空白の無い引数は引用符で囲まれないので、mklink の
/// 引数が割れる)。パスに含まれていれば junction を張らない (cmd に別のコマンドとして読ませない)。
const CMD_SPECIALS: &[char] = &['%', '!', '^', '&', '|', '<', '>', '"', ',', ';', '='];

/// パスを比べる鍵 (`windows` は Windows の決まりで比べるか)。Windows は `/` を `\` にし、`\\?\UNC\` を `\\` に、`\\?\`・`\??\` を落とし、
/// 末尾の区切りを落として小文字にする (大文字小文字を区別しない)。Unix は末尾の `/` を落とすだけ。
pub fn path_key(s: &str, windows: bool) -> String {
    if !windows {
        let t = s.trim_end_matches('/');
        return if t.is_empty() && s.starts_with('/') {
            "/".to_string()
        } else {
            t.to_string()
        };
    }
    let mut t = s.replace('/', "\\");
    if let Some(rest) = t.strip_prefix(r"\\?\UNC\") {
        t = format!(r"\\{rest}");
    } else if let Some(rest) = t.strip_prefix(r"\\?\").or_else(|| t.strip_prefix(r"\??\")) {
        t = rest.to_string();
    }
    t.trim_end_matches('\\').to_lowercase()
}

fn key(p: &Path) -> String {
    path_key(&p.to_string_lossy(), cfg!(windows))
}

fn sep() -> char {
    if cfg!(windows) { '\\' } else { '/' }
}

/// 2 つのパスが同じ場所か。書いた形で比べ、違えば両方を解いた形 (`canonicalize`。どちらも在るとき) で比べる (Windows の 8.3 の短い名前と
/// 長い名前など)。
pub fn same_path(a: &Path, b: &Path) -> bool {
    if key(a) == key(b) {
        return true;
    }
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => key(&x) == key(&y),
        _ => false,
    }
}

/// `p` が `dir` の下か (`dir` そのものは含めない)。書いた形で比べ、違えば両方を解いた形で比べる (どちらも在るとき)。
pub fn is_under(p: &Path, dir: &Path) -> bool {
    let under = |p: &str, d: &str| p.starts_with(&format!("{d}{}", sep()));
    if under(&key(p), &key(dir)) {
        return true;
    }
    match (std::fs::canonicalize(p), std::fs::canonicalize(dir)) {
        (Ok(x), Ok(y)) => under(&key(&x), &key(&y)),
        _ => false,
    }
}

/// `p` がリンク (Windows の junction・symlink、Unix の symlink) なら、その先。リンクでない・無いなら None。
pub fn link_target(p: &Path) -> Option<PathBuf> {
    let meta = std::fs::symlink_metadata(p).ok()?;
    if !meta.file_type().is_symlink() {
        return None;
    }
    std::fs::read_link(p).ok()
}

/// `p` がリンクか (先が無くても)。
pub fn is_link(p: &Path) -> bool {
    std::fs::symlink_metadata(p).is_ok_and(|m| m.file_type().is_symlink())
}

/// リンクを外す (先は消さない)。Windows は junction とディレクトリの symlink を `remove_dir`、ファイルの symlink を `remove_file` で外す。
pub fn remove_link(p: &Path) -> std::io::Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::FileTypeExt;
        if std::fs::symlink_metadata(p)?.file_type().is_symlink_file() {
            return std::fs::remove_file(p);
        }
        std::fs::remove_dir(p)
    }
    #[cfg(not(windows))]
    std::fs::remove_file(p)
}

/// `link` に `target` を指す junction を張る (`%ComSpec%` か `cmd` の `/c mklink /J`)。張った後に先を読み直して確かめる。cmd が特別に
/// 読む文字を含むパスは、cmd を打たずに断る。
pub fn create_junction(sys: &dyn Sys, link: &Path, target: &Path) -> Result<(), String> {
    for p in [link, target] {
        let s = p.to_string_lossy();
        if let Some(c) = s.chars().find(|c| CMD_SPECIALS.contains(c)) {
            return Err(format!(
                "パスに cmd が特別に読む文字 ({c}) があるので junction を張らない: {s}"
            ));
        }
    }
    let cmd = sys
        .env("ComSpec")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "cmd".to_string());
    let spec = CommandSpec::new(cmd)
        .arg("/c")
        .arg("mklink")
        .arg("/J")
        .arg(link.as_os_str())
        .arg(target.as_os_str())
        .timeout(Duration::from_secs(30));
    let r = sys.run(&spec, &mut |_| {});
    if r.code() != Some(0) {
        return Err(format!(
            "mklink /J が落ちた ({:?}): {}",
            r.exit,
            r.output.join(" / ")
        ));
    }
    match link_target(link) {
        Some(t) if same_path(&t, target) => Ok(()),
        Some(t) => Err(format!(
            "張った junction の先が違う: {} (望んだのは {})",
            t.display(),
            target.display()
        )),
        None => Err(format!(
            "mklink /J は通ったが、{} がリンクになっていない",
            link.display()
        )),
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - パスの鍵: Windows は `\\?\`・`\??\`・`/`・末尾の区切り・大文字小文字の違いを同じに読み、`\\?\UNC\` を `\\` にする。Unix は末尾の `/` だけ
    //! - `is_under` は区切りの境で見る (`C:\ab` は `C:\a` の下でない)
    //! - cmd が特別に読む文字を含むパスは、cmd を打たずに断る
    //! - junction を張って (試験の偽物は Unix の symlink・Windows の本物の junction)、先を読み、外すと先は残る

    use super::*;
    use crate::testutil::{FakeSys, TempDir, fake_mklink};

    #[test]
    fn path_key_windows() {
        let want = r"c:\users\a\x";
        for s in [
            r"\\?\C:\Users\A\x\",
            r"\??\c:/users/a/x",
            r"C:\Users\a\x",
            "C:/Users/A/x/",
        ] {
            assert_eq!(path_key(s, true), want, "{s}");
        }
        assert_eq!(path_key(r"\\?\UNC\srv\s\x", true), r"\\srv\s\x");
        assert_eq!(path_key("/a/b/", false), "/a/b");
        assert_eq!(path_key("/", false), "/");
        assert_eq!(path_key("/A/b", false), "/A/b");
    }

    #[test]
    fn is_under_respects_separator_boundaries() {
        let t = TempDir::new("link-under");
        let a = t.path().join("a");
        assert!(is_under(&a.join("b"), &a));
        assert!(!is_under(&t.path().join("ab"), &a));
        assert!(!is_under(&a, &a));
    }

    #[test]
    fn create_junction_rejects_cmd_specials() {
        let sys = FakeSys::new(|_| unreachable!("cmd を打たない"));
        for bad in [
            "C:\\Users\\a%b\\x",
            "C:\\Users\\a&b\\x",
            "C:\\Users\\a\"b\\x",
            // cmd の区切り文字 (空白の無い引数は引用符で囲まれないので、mklink の引数が割れる)
            "C:\\Users\\a,b\\x",
            "C:\\Users\\a;b\\x",
            "C:\\Users\\a=b\\x",
        ] {
            let e = create_junction(&sys, Path::new(bad), Path::new("C:\\t")).unwrap_err();
            assert!(e.contains("cmd が特別に読む文字"), "{e}");
            let e = create_junction(&sys, Path::new("C:\\l"), Path::new(bad)).unwrap_err();
            assert!(e.contains("cmd が特別に読む文字"), "{e}");
        }
        assert!(sys.calls.borrow().is_empty());
    }

    #[test]
    fn junction_round_trip() {
        let t = TempDir::new("link-junction");
        let target = t.path().join("clone").join("skills").join("pjp-a");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("SKILL.md"), "x\n").unwrap();
        let link = t.path().join("home").join("pjp-a");
        std::fs::create_dir_all(link.parent().unwrap()).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).expect("mklink だけを打つ"));
        create_junction(&sys, &link, &target).unwrap();
        let args = sys.call_args();
        assert_eq!(args.len(), 1);
        assert!(args[0].starts_with("/c mklink /J "), "{}", args[0]);
        assert!(is_link(&link));
        assert!(same_path(&link_target(&link).unwrap(), &target));
        assert_eq!(
            std::fs::read_to_string(link.join("SKILL.md")).unwrap(),
            "x\n"
        );
        remove_link(&link).unwrap();
        assert!(!link.exists() && !is_link(&link));
        assert!(target.join("SKILL.md").is_file());
        assert_eq!(link_target(&target), None);
    }

    /// ファイルの symlink (Windows では開発者モードか管理者で作れる) も外せ、先は残る
    #[test]
    fn removes_a_file_symlink() {
        let t = TempDir::new("link-file");
        let target = t.path().join("rule.md");
        std::fs::write(&target, "r\n").unwrap();
        let link = t.path().join("link.md");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &link).unwrap();
        #[cfg(windows)]
        if std::os::windows::fs::symlink_file(&target, &link).is_err() {
            eprintln!("ファイルの symlink を作る権限が無いので飛ばす");
            return;
        }
        assert!(is_link(&link));
        remove_link(&link).unwrap();
        assert!(!is_link(&link));
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "r\n");
    }

    /// 空白と日本語を含むパスでも junction を張れる (Rust が引数を引用符で囲み、cmd がそのまま mklink に渡す)
    #[test]
    fn junction_with_spaces_and_japanese() {
        let t = TempDir::new("link-space");
        let base = t.path().join("a b").join("日本");
        let target = base.join("clone dir").join("pjp-a");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("SKILL.md"), "x\n").unwrap();
        let link = base.join("home dir").join("pjp-a");
        std::fs::create_dir_all(link.parent().unwrap()).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).expect("mklink だけを打つ"));
        create_junction(&sys, &link, &target).unwrap();
        assert_eq!(
            std::fs::read_to_string(link.join("SKILL.md")).unwrap(),
            "x\n"
        );
        remove_link(&link).unwrap();
        assert!(target.join("SKILL.md").is_file());
    }
}
