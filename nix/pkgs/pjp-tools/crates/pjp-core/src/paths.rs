//! 置き場所とパスの比べ方 (spec §6.6 の「置き場所」「パスの比べ方」)。
//!
//! どの OS も、ホームからの XDG の形 (`~/.config`・`~/.local/state`・`~/.local/share`。`XDG_*` があればそれ) に置く。
//! dotfiles が書くファイル (`~/.local/state/dotfiles/…`) は、dotfiles の bootstrap が `XDG_STATE_HOME` を見ずに書くので、
//! ホームからの固定の場所で読む (pjp-notion-profile の notion_profile.py と同じ)。

use std::borrow::Cow;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use crate::{Error, Result};

/// ホーム (`std::env::home_dir`。Unix は `HOME`、Windows は `USERPROFILE`)。
pub fn home_dir() -> Result<PathBuf> {
    match std::env::home_dir() {
        Some(p) if !p.as_os_str().is_empty() => Ok(p),
        _ => Err(Error::config(
            "ホームディレクトリが分かりません (HOME・USERPROFILE が空)",
        )),
    }
}

/// XDG の置き場所を決める。`var` が絶対パスならそれ、無い・空・相対なら `home` の下の `rel` (`/` 区切り)。
/// 相対の値を使わないのは XDG Base Directory の決まり。
pub fn resolve_xdg(home: &Path, var: Option<&OsStr>, rel: &str) -> PathBuf {
    if let Some(v) = var.map(Path::new).filter(|p| p.is_absolute()) {
        return v.to_path_buf();
    }
    // `/` のまま join すると、Windows では `C:\Users\x\.local/state` と区切りが混ざる
    rel.split('/')
        .filter(|c| !c.is_empty())
        .fold(home.to_path_buf(), |p, c| p.join(c))
}

/// `$XDG_CONFIG_HOME` か `~/.config`。
pub fn xdg_config_home() -> Result<PathBuf> {
    Ok(resolve_xdg(
        &home_dir()?,
        std::env::var_os("XDG_CONFIG_HOME").as_deref(),
        ".config",
    ))
}

/// `$XDG_STATE_HOME` か `~/.local/state`。
pub fn xdg_state_home() -> Result<PathBuf> {
    Ok(resolve_xdg(
        &home_dir()?,
        std::env::var_os("XDG_STATE_HOME").as_deref(),
        ".local/state",
    ))
}

/// `$XDG_DATA_HOME` か `~/.local/share`。
pub fn xdg_data_home() -> Result<PathBuf> {
    Ok(resolve_xdg(
        &home_dir()?,
        std::env::var_os("XDG_DATA_HOME").as_deref(),
        ".local/share",
    ))
}

/// pjp の道具の控えの置き場 (`<XDG_STATE_HOME>/pjp`)。
pub fn pjp_state_dir() -> Result<PathBuf> {
    Ok(xdg_state_home()?.join("pjp"))
}

/// dotfiles が書くファイルの置き場 (`~/.local/state/dotfiles`。`XDG_STATE_HOME` は見ない)。
pub fn dotfiles_state_dir() -> Result<PathBuf> {
    Ok(resolve_xdg(&home_dir()?, None, ".local/state/dotfiles"))
}

/// 比べるための形: `\` を `/` に、末尾の `/` を落とす。`windows` なら、`\\?\` (Windows の canonicalize が返す形) を外し、
/// ASCII を小文字にする (Windows は大文字小文字を区別しない)。
pub fn normalize_for_compare(path: &str, windows: bool) -> String {
    fold(&strip_verbatim(path, windows), windows)
}

/// `windows` なら `\\?\C:\…` を `C:\…` に、`\\?\UNC\host\…` を `\\host\…` にする。
fn strip_verbatim(path: &str, windows: bool) -> Cow<'_, str> {
    if !windows {
        return Cow::Borrowed(path);
    }
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        return Cow::Owned(format!(r"\\{rest}"));
    }
    Cow::Borrowed(path.strip_prefix(r"\\?\").unwrap_or(path))
}

/// `\` を `/` に、末尾の `/` を落とし、`windows` なら ASCII を小文字にする。バイトの長さは末尾のほかで変えないので、
/// 元の文字列を同じ位置で切れる。
fn fold(path: &str, windows: bool) -> String {
    let mut s: String = path
        .chars()
        .map(|c| match c {
            '\\' => '/',
            c if windows => c.to_ascii_lowercase(),
            c => c,
        })
        .collect();
    // 末尾の `/` を落とす。ただし root (`/`・`c:/`) は残す
    while s.ends_with('/') && s.len() > 1 && !s.ends_with(":/") {
        s.pop();
    }
    s
}

/// 2 つのパスが同じか (`/` と `\`、git が返す `C:/…` の形、Windows の大文字小文字の違いを同じとみる)。
pub fn same_path(a: &str, b: &str, windows: bool) -> bool {
    normalize_for_compare(a, windows) == normalize_for_compare(b, windows)
}

/// `home` の下なら `~/…` (区切りは `/`) に縮める。下でなければそのまま返す。
pub fn contract_home(path: &str, home: &str, windows: bool) -> String {
    let path = strip_verbatim(path, windows);
    let home = strip_verbatim(home, windows);
    let p = fold(&path, windows);
    let h = fold(&home, windows);
    if h.is_empty() || h == "/" {
        return path.into_owned();
    }
    if p == h {
        return "~".to_owned();
    }
    // fold は末尾のほかでバイトの長さを変えないので、元の文字列を同じ位置で切れる (表示は元の大文字小文字のまま)
    match p.strip_prefix(&h) {
        Some(rest) if rest.starts_with('/') => {
            let rest = path[h.len()..].replace('\\', "/");
            format!("~{}", rest.trim_end_matches('/'))
        }
        _ => path.into_owned(),
    }
}

/// このマシンのホームで `~` に縮める (表示用)。ホームが分からなければそのまま。
pub fn contract_home_here(path: &Path) -> String {
    let shown = path.to_string_lossy();
    match home_dir() {
        Ok(home) => contract_home(&shown, &home.to_string_lossy(), cfg!(windows)),
        Err(_) => shown.into_owned(),
    }
}

/// symlink・junction を辿った絶対パス (`std::fs::canonicalize`)。Windows の canonicalize が付ける `\\?\` は外す (git などの
/// 外のコマンドに渡せ、表示も読める形。8.3 の短い名前も長い名前になる)。
pub fn real_path(path: &Path) -> std::io::Result<PathBuf> {
    let p = std::fs::canonicalize(path)?;
    Ok(match p.to_str() {
        Some(s) => PathBuf::from(strip_verbatim(s, cfg!(windows)).as_ref()),
        None => p,
    })
}

/// 2 つのパスが同じか ([`same_path`] をこのマシンの決まりで。Windows は大文字小文字と `/`・`\`・`\\?\` を見ない)。
/// symlink は解かない (解くなら先に [`real_path`])。
pub fn same_path_here(a: &Path, b: &Path) -> bool {
    same_path(&a.to_string_lossy(), &b.to_string_lossy(), cfg!(windows))
}

/// 頭の `~` (文字そのもの) を `home` に展開する。`~` と `~/…`、`windows` なら `~\…` も。shell が展開しない所
/// (`--dir=~/h`・hook の JSON の中・PowerShell の `'~/h'`) のため。`~user` や途中の `~` は展開しない。
pub fn expand_tilde(path: &OsStr, home: &Path, windows: bool) -> PathBuf {
    let Some(text) = path.to_str() else {
        return PathBuf::from(path);
    };
    if text == "~" {
        return home.to_path_buf();
    }
    let rest = text.strip_prefix("~/").or_else(|| {
        windows
            .then(|| text.strip_prefix('~').and_then(|r| r.strip_prefix('\\')))
            .flatten()
    });
    match rest {
        // 区切りをその OS の形にそろえる (途中の . は落とし、.. は残す)
        Some(r) => home.join(r).components().collect(),
        None => PathBuf::from(path),
    }
}

/// [`expand_tilde`] をこのマシンの決まりで。
pub fn expand_tilde_here(path: &OsStr, home: &Path) -> PathBuf {
    expand_tilde(path, home, cfg!(windows))
}

/// Git Bash (MSYS) の形の絶対パス `/c/Users/…` を、Windows の形 `C:\Users\…` にする。その形でなければ None。
/// Windows で Git Bash の `pwd` などから来たパスを、ドライブの root からの相対 (`C:\c\Users\…`) と読み違えないため。
pub fn from_msys(path: &str) -> Option<String> {
    let rest = path.strip_prefix('/')?;
    let mut chars = rest.chars();
    let drive = chars.next().filter(char::is_ascii_alphabetic)?;
    let after = chars.as_str();
    if !(after.is_empty() || after.starts_with('/')) {
        return None;
    }
    let tail = after.trim_start_matches('/').replace('/', "\\");
    Some(format!("{}:\\{tail}", drive.to_ascii_uppercase()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    #[test]
    fn resolve_xdg_uses_absolute_var_only() {
        let home = Path::new("/home/u");
        assert_eq!(
            resolve_xdg(home, None, ".local/state"),
            Path::new("/home/u").join(".local").join("state")
        );
        assert_eq!(
            resolve_xdg(home, Some(OsStr::new("")), ".config"),
            home.join(".config")
        );
        assert_eq!(
            resolve_xdg(home, Some(OsStr::new("relative/dir")), ".config"),
            home.join(".config")
        );
        let abs: OsString = std::env::temp_dir().join("xdg-state").into();
        assert_eq!(
            resolve_xdg(home, Some(&abs), ".local/state"),
            PathBuf::from(&abs)
        );
    }

    #[test]
    fn home_dir_is_known() {
        assert!(home_dir().unwrap().is_absolute());
    }

    #[test]
    fn same_path_windows_ignores_case_and_slashes() {
        assert!(same_path(r"C:\Users\user\h", "c:/users/user/h/", true));
        assert!(same_path("C:/Users/user/h", r"C:\Users\user\h", true));
        assert!(!same_path(r"C:\Users\user\h", r"C:\Users\user\hh", true));
    }

    #[test]
    fn verbatim_prefix_is_the_same_path_on_windows() {
        // Windows の canonicalize は \\?\ の付いた形を返す
        assert!(same_path(r"\\?\C:\Users\user\h", r"C:\Users\user\h", true));
        assert!(same_path(
            r"\\?\UNC\wsl.localhost\Ubuntu\home\u",
            r"\\wsl.localhost\Ubuntu\home\u",
            true
        ));
        assert_eq!(
            contract_home(r"\\?\C:\Users\user\h", r"C:\Users\user", true),
            "~/h"
        );
        assert_eq!(
            contract_home(r"C:\Users\user\Docs", r"\\?\C:\Users\user", true),
            "~/Docs"
        );
        // Unix では素のまま
        assert!(!same_path(r"\\?\x", "x", false));
    }

    #[test]
    fn tilde_expansion() {
        let home = std::env::temp_dir().join("home-u");
        for windows in [false, true] {
            assert_eq!(expand_tilde(OsStr::new("~"), &home, windows), home);
            assert_eq!(
                expand_tilde(OsStr::new("~/h/x.md"), &home, windows),
                home.join("h").join("x.md")
            );
            // ~user や途中の ~ は展開しない
            assert_eq!(
                expand_tilde(OsStr::new("~other/h"), &home, windows),
                PathBuf::from("~other/h")
            );
            assert_eq!(
                expand_tilde(OsStr::new("a/~"), &home, windows),
                PathBuf::from("a/~")
            );
        }
        assert_eq!(
            expand_tilde(OsStr::new(r"~\h"), &home, true),
            home.join("h")
        );
        assert_eq!(
            expand_tilde(OsStr::new(r"~\h"), &home, false),
            PathBuf::from(r"~\h")
        );
    }

    #[test]
    fn msys_paths_become_windows_paths() {
        assert_eq!(
            from_msys("/c/Users/user/h/x.md").as_deref(),
            Some(r"C:\Users\user\h\x.md")
        );
        assert_eq!(from_msys("/d").as_deref(), Some(r"D:\"));
        assert_eq!(from_msys("/D/").as_deref(), Some(r"D:\"));
        for no in ["/home/u", "/cc/x", "c/Users", r"C:\Users", "/1/x", "", "/"] {
            assert_eq!(from_msys(no), None, "{no}");
        }
    }

    #[test]
    fn real_path_resolves_and_has_no_verbatim_prefix() {
        let t = crate::testutil::TempDir::new("real-path");
        let file = t.write("a/b.txt", "x");
        let real = real_path(&t.path().join("a").join(".").join("b.txt")).unwrap();
        assert!(real.is_absolute(), "{}", real.display());
        assert!(
            !real.to_string_lossy().starts_with(r"\\?\"),
            "{}",
            real.display()
        );
        assert!(same_path(
            &real.to_string_lossy(),
            &std::fs::canonicalize(&file).unwrap().to_string_lossy(),
            cfg!(windows)
        ));
        assert!(real_path(&t.path().join("nope")).is_err());
    }

    #[test]
    fn same_path_unix_is_case_sensitive() {
        assert!(same_path("/home/u/h", "/home/u/h/", false));
        assert!(!same_path("/home/u/H", "/home/u/h", false));
    }

    #[test]
    fn contract_home_unix() {
        assert_eq!(contract_home("/home/u", "/home/u", false), "~");
        assert_eq!(contract_home("/home/u/", "/home/u", false), "~");
        assert_eq!(contract_home("/home/u/ghq/x", "/home/u/", false), "~/ghq/x");
        assert_eq!(contract_home("/home/uu/x", "/home/u", false), "/home/uu/x");
        assert_eq!(contract_home("/home/U/x", "/home/u", false), "/home/U/x");
        assert_eq!(contract_home("/tmp/x", "/home/u", false), "/tmp/x");
    }

    #[test]
    fn contract_home_windows_style() {
        let home = r"C:\Users\user";
        assert_eq!(contract_home(r"C:\Users\user\h", home, true), "~/h");
        assert_eq!(contract_home("c:/users/user/h", home, true), "~/h");
        assert_eq!(
            contract_home(r"C:\Users\user\.herdr\worktrees\h\x", home, true),
            "~/.herdr/worktrees/h/x"
        );
        assert_eq!(contract_home(r"C:\Users\user", home, true), "~");
        // 表示は元の大文字小文字のまま
        assert_eq!(
            contract_home(r"c:\users\user\Documents\X", home, true),
            "~/Documents/X"
        );
        assert_eq!(
            contract_home(r"D:\Users\user\h", home, true),
            r"D:\Users\user\h"
        );
    }
}
