//! git を呼ぶ口。どの呼び出しも `git -C <dir>` で打ち、env の GIT_DIR などを外す (dir から repo を探させる。hook や
//! git の hook の中から打たれても、ほかの repo を指さない)。

use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::Duration;

use pjp_core::Result;
use pjp_core::process::{self, Cmd, Output};

use crate::pathx;

/// 1 回の git を待つ長さ (ハブの repo は小さい。止まった git で hook を止め続けない)。
const TIMEOUT: Duration = Duration::from_secs(60);

/// repo の場所を決める env。残っていると `git -C` が dir から repo を探さない。
const REPO_ENV: [&str; 7] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
];

/// PATH で見つけた git。
#[derive(Debug, Clone)]
pub struct Git {
    program: PathBuf,
}

impl Git {
    /// PATH から git を探す (Windows は git.exe)。
    pub fn find() -> Option<Git> {
        process::find_in_path("git").map(|program| Git { program })
    }

    /// `git -C <dir>` の Cmd (args はこの後に足す)。
    pub fn cmd(&self, dir: &Path) -> Cmd {
        REPO_ENV
            .iter()
            .fold(Cmd::new(&self.program).arg("-C").arg(dir), |c, k| {
                c.env_remove(k)
            })
            .timeout(TIMEOUT)
    }

    /// `git -C <dir> <args>…` を打つ。起こせなければ Err。
    pub fn output<S: AsRef<OsStr>>(&self, dir: &Path, args: &[S]) -> Result<Output> {
        self.cmd(dir).args(args).output()
    }

    /// 成功したら stdout (末尾の改行を落としたもの)。落ちた・起こせなければ None。
    pub fn text<S: AsRef<OsStr>>(&self, dir: &Path, args: &[S]) -> Option<String> {
        let out = self.output(dir, args).ok()?;
        out.success()
            .then(|| out.stdout.trim_end_matches(['\r', '\n']).to_owned())
    }

    /// 空でない行。落ちたら空。
    pub fn lines<S: AsRef<OsStr>>(&self, dir: &Path, args: &[S]) -> Vec<String> {
        self.text(dir, args)
            .map(|s| {
                s.lines()
                    .map(str::trim)
                    .filter(|l| !l.is_empty())
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    }

    /// 作業ツリーの頭 (symlink を解いた形)。git の外・`.git` の中なら None。
    pub fn toplevel(&self, dir: &Path) -> Option<PathBuf> {
        self.path_of(dir, "--show-toplevel")
    }

    /// git の共通ディレクトリ (worktree でも main の checkout の `.git`。symlink を解いた形)。git の外なら None。
    pub fn common_dir(&self, dir: &Path) -> Option<PathBuf> {
        self.path_of(dir, "--git-common-dir")
    }

    /// この作業ツリーの git のディレクトリ (worktree なら `.git/worktrees/<名前>`。symlink を解いた形)。
    pub fn git_dir(&self, dir: &Path) -> Option<PathBuf> {
        self.path_of(dir, "--git-dir")
    }

    fn path_of(&self, dir: &Path, flag: &str) -> Option<PathBuf> {
        self.text(dir, &["rev-parse", "--path-format=absolute", flag])
            .filter(|s| !s.is_empty())
            .map(|s| pathx::from_tool(&s))
    }

    /// remote の名前。
    pub fn remotes(&self, dir: &Path) -> Vec<String> {
        self.lines(dir, &["remote"])
    }

    /// repo の設定 (`git config --local --get`)。無い・空なら None。worktree からも main の checkout の設定を読む。
    pub fn config(&self, dir: &Path, key: &str) -> Option<String> {
        self.text(dir, &["config", "--local", "--get", key])
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
    }
}
