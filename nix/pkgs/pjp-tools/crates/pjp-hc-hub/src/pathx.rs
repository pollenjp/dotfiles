//! パスの組み立て (絶対パス・区切りをその OS の形に・最も近い既存の祖先)。OS で違う所 (`~` の展開・比べ方・`\\?\`・
//! Git Bash の `/c/…`) は pjp-core の paths。

use std::path::{Component, Path, PathBuf};

use pjp_core::paths;

/// 区切りをその OS の形にそろえる (Windows は `/` を `\` に)。途中の `.` は落とし、`..` は残す (symlink を解かないので、
/// `..` を字面で畳まない)。
pub fn native(p: &Path) -> PathBuf {
    p.components().collect()
}

/// `p` を絶対パスにし (相対なら `base` から)、`.` と `..` を字面で畳む (`cd` してから `pwd -L` と同じ。symlink は解かない)。
pub fn absolute_lexical(p: &Path, base: &Path) -> PathBuf {
    let joined = if p.is_absolute() {
        p.to_path_buf()
    } else {
        base.join(p)
    };
    let mut out = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                // root (`/`・`C:\`) より上へは行かない
                if matches!(out.components().next_back(), Some(Component::Normal(_))) {
                    out.pop();
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// git などが返したパス (Windows は `C:/…` の形) を、symlink を解いた形にする。解けなければ区切りだけそろえる。
pub fn from_tool(s: &str) -> PathBuf {
    let p = Path::new(s);
    paths::real_path(p).unwrap_or_else(|_| native(p))
}

/// `p` か、その最も近い既存の祖先 (symlink は切れていても、あるものとみる)。どれも無ければ None。
pub fn nearest_existing(p: &Path) -> Option<PathBuf> {
    p.ancestors()
        .filter(|a| !a.as_os_str().is_empty())
        .find(|a| a.symlink_metadata().is_ok())
        .map(Path::to_path_buf)
}

/// `p` か、その最も近い既存のディレクトリの祖先。
pub fn nearest_dir(p: &Path) -> Option<PathBuf> {
    p.ancestors()
        .filter(|a| !a.as_os_str().is_empty())
        .find(|a| a.is_dir())
        .map(Path::to_path_buf)
}

/// `p` (あるもの) の symlink・junction を解く (`readlink -f` と同じく、切れた symlink は link の先を 1 回辿り、その最も近い
/// 既存の祖先を解いた所に残りをつなぐ)。解けなければ None。
pub fn resolve(p: &Path) -> Option<PathBuf> {
    if let Ok(real) = paths::real_path(p) {
        return Some(real);
    }
    let target = std::fs::read_link(p).ok()?;
    let target = if target.is_absolute() {
        target
    } else {
        p.parent()?.join(target)
    };
    let anchor = nearest_existing(&target).filter(|a| a != p)?;
    let rest = target.strip_prefix(&anchor).ok()?.to_path_buf();
    Some(paths::real_path(&anchor).ok()?.join(rest))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absolute_lexical_folds_dots() {
        let base = std::env::temp_dir().join("base");
        assert_eq!(absolute_lexical(Path::new("./h/"), &base), base.join("h"));
        assert_eq!(
            absolute_lexical(Path::new("a/../b/./c"), &base),
            base.join("b").join("c")
        );
        let root = base.ancestors().last().unwrap().to_path_buf();
        let deep = Path::new("..").join("..").join("..").join("..").join("..");
        let up = absolute_lexical(&deep.join("..").join("x"), &root);
        assert_eq!(up, root.join("x"));
    }

    #[test]
    fn native_keeps_parent_dirs() {
        let p = std::env::temp_dir().join("a").join("..").join("b");
        assert_eq!(native(&p), p);
    }

    #[test]
    fn nearest_existing_walks_up() {
        let tmp = std::env::temp_dir();
        let missing = tmp.join("pjp-hc-hub-no-such-dir").join("x").join("y");
        assert_eq!(nearest_existing(&missing).as_deref(), Some(tmp.as_path()));
        assert_eq!(nearest_dir(&missing).as_deref(), Some(tmp.as_path()));
    }

    #[cfg(unix)]
    #[test]
    fn resolve_follows_a_broken_symlink_once() {
        let base = std::env::temp_dir().join(format!("pjp-hc-hub-resolve-{}", std::process::id()));
        let repo = base.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        let link = base.join("link");
        std::os::unix::fs::symlink(repo.join("not-yet").join("file.md"), &link).unwrap();
        let real_repo = paths::real_path(&repo).unwrap();
        assert_eq!(
            resolve(&link),
            Some(real_repo.join("not-yet").join("file.md"))
        );
        assert_eq!(resolve(&repo), Some(real_repo));
        let _ = std::fs::remove_dir_all(&base);
    }
}
