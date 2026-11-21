//! 手順に渡す文脈 (置き場所・ホストの値・外のコマンドの口・出力)。
//!
//! 手順は置き場所をここから引き、外のコマンドは `sys` で打ち、出力は `say` で出す。W0-2 などで手順を足すときも同じ。

use crate::host::HostValues;
use crate::manifest::Roots;
use crate::process::Sys;
use std::io::Write;
use std::path::{Path, PathBuf};

pub struct Ctx<'a> {
    /// dotfiles の clone の root
    pub repo: PathBuf,
    /// Windows の置き先の根 (`%USERPROFILE%`・`%APPDATA%`・`%LOCALAPPDATA%`)
    pub roots: Roots,
    /// 配った記録の置き場 (`%LOCALAPPDATA%\dotfiles\state`)
    pub state_dir: PathBuf,
    pub host: HostValues,
    pub sys: &'a dyn Sys,
    pub out: &'a mut dyn Write,
}

impl Ctx<'_> {
    /// 1 行出す (書けなくても止めない)。
    pub fn say(&mut self, line: impl AsRef<str>) {
        let _ = writeln!(self.out, "{}", line.as_ref());
    }

    /// dotfiles の clone の中のパス (`rel` は `/` 区切り)。
    pub fn repo_path(&self, rel: &str) -> PathBuf {
        join_segments(&self.repo, rel)
    }

    /// dotfiles の clone の隣の clone (`dotfiles-private`・`claude-skills`)。隣に無ければ bootstrap の置き場 (`clone_dir`)。
    pub fn sibling(&self, name: &str) -> PathBuf {
        clone_dir(&self.repo, Some(&self.roots.user_profile), name)
    }

    /// SSH の会話の中か (sshd が SSH_CONNECTION・SSH_CLIENT を渡す。win/openssh/Install-Sshd.ps1 と同じ見方)。Win32-OpenSSH の会話は
    /// セッション 0 で、デスクトップの会話の窓・プロセス・名前付きイベントが見えない (powertoys・international が書くのを止める)
    pub fn in_ssh(&self) -> bool {
        ["SSH_CONNECTION", "SSH_CLIENT"]
            .iter()
            .any(|k| self.sys.env(k).is_some_and(|v| !v.is_empty()))
    }
}

/// bootstrap が 3 つの repo を clone する ghq の owner のディレクトリ (`%USERPROFILE%\ghq\github.com\pollenjp`)。
pub fn ghq_owner_dir(user_profile: &Path) -> PathBuf {
    join_segments(user_profile, "ghq/github.com/pollenjp")
}

/// 隣の clone の置き場: dotfiles の clone の隣にあればそれ、無ければ bootstrap の置き場 (`%USERPROFILE%\ghq\github.com\pollenjp\<name>`)、
/// どちらにも無ければ隣 (無いと知らせる場所)。runner を一時の場所の clone から流しても、ホストの値と隣の clone を見つけるため。
pub fn clone_dir(repo: &Path, user_profile: Option<&Path>, name: &str) -> PathBuf {
    let sibling = repo.parent().unwrap_or(repo).join(name);
    if sibling.is_dir() {
        return sibling;
    }
    if let Some(up) = user_profile {
        let ghq = ghq_owner_dir(up).join(name);
        if ghq.is_dir() {
            return ghq;
        }
    }
    sibling
}

/// `base` に `/` 区切りの `rel` を要素ごとに足す (`Path::join` に `C:/…` を渡すと前を捨てるので、要素ごとに push する)。
pub fn join_segments(base: &Path, rel: &str) -> PathBuf {
    let mut p = base.to_path_buf();
    for seg in rel.split('/').filter(|s| !s.is_empty()) {
        p.push(seg);
    }
    p
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 隣の clone は、dotfiles の clone の隣 → bootstrap の置き場 (%USERPROFILE%\ghq\github.com\pollenjp) の順に探し、どちらにも無ければ隣

    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn clone_dir_prefers_sibling_then_bootstrap_place() {
        let t = TempDir::new("clone-dir");
        let repo = join_segments(t.path(), "tmp/dotfiles");
        let home = t.path().join("home");
        std::fs::create_dir_all(&repo).unwrap();
        let sibling = join_segments(t.path(), "tmp/dotfiles-private");
        let ghq = join_segments(&home, "ghq/github.com/pollenjp/dotfiles-private");
        // どちらにも無い: 隣
        assert_eq!(clone_dir(&repo, Some(&home), "dotfiles-private"), sibling);
        // bootstrap の置き場にだけある
        std::fs::create_dir_all(&ghq).unwrap();
        assert_eq!(clone_dir(&repo, Some(&home), "dotfiles-private"), ghq);
        assert_eq!(clone_dir(&repo, None, "dotfiles-private"), sibling);
        // 隣にもある: 隣
        std::fs::create_dir_all(&sibling).unwrap();
        assert_eq!(clone_dir(&repo, Some(&home), "dotfiles-private"), sibling);
    }
}
