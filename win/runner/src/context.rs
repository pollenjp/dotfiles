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

    /// dotfiles の clone の隣の clone (`dotfiles-private`・`claude-skills`)。bootstrap が同じ ghq の owner の下に clone する。
    pub fn sibling(&self, name: &str) -> PathBuf {
        self.repo.parent().unwrap_or(&self.repo).join(name)
    }
}

/// `base` に `/` 区切りの `rel` を要素ごとに足す (`Path::join` に `C:/…` を渡すと前を捨てるので、要素ごとに push する)。
pub fn join_segments(base: &Path, rel: &str) -> PathBuf {
    let mut p = base.to_path_buf();
    for seg in rel.split('/').filter(|s| !s.is_empty()) {
        p.push(seg);
    }
    p
}
