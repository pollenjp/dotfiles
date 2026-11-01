//! repo の手元の状態を読む (通信しない)。
//!
//! 既定 branch は origin/HEAD の指す branch、無ければ origin/main、origin/master の順に探す。git remote set-head は
//! 打たない (repo の設定を変えない)。status は --no-optional-locks で読み、index.lock を作らない (ほかの git と
//! ぶつからない)。

use std::path::{Path, PathBuf};

use crate::git::Git;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Head {
    Branch(String),
    Detached,
}

/// 作業途中。index.lock はほかの git が動いている印
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Busy {
    IndexLock,
    Rebase,
    Merge,
    CherryPick,
    Revert,
}

/// 選ぶ画面に出す、手元だけで分かる状態
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Info {
    pub head: Head,
    pub default_branch: Option<String>,
    pub dirty: bool,
}

/// dir が git の work tree の直下か (外側の repo の中の dir・bare の repo・git でない dir は違う)
pub fn is_work_tree_root(git: &Git, dir: &Path) -> bool {
    let out = git.run(dir, &["rev-parse", "--show-toplevel"]);
    if !out.success {
        return false;
    }
    let top = PathBuf::from(out.stdout.trim());
    match (top.canonicalize(), dir.canonicalize()) {
        (Ok(top), Ok(dir)) => top == dir,
        _ => false,
    }
}

fn git_dir(git: &Git, dir: &Path) -> Option<PathBuf> {
    let out = git.run(dir, &["rev-parse", "--absolute-git-dir"]);
    out.success.then(|| PathBuf::from(out.stdout.trim()))
}

pub fn busy(git: &Git, dir: &Path) -> Option<Busy> {
    let gd = git_dir(git, dir)?;
    if gd.join("index.lock").exists() {
        Some(Busy::IndexLock)
    } else if gd.join("rebase-merge").exists() || gd.join("rebase-apply").exists() {
        Some(Busy::Rebase)
    } else if gd.join("MERGE_HEAD").exists() {
        Some(Busy::Merge)
    } else if gd.join("CHERRY_PICK_HEAD").exists() {
        Some(Busy::CherryPick)
    } else if gd.join("REVERT_HEAD").exists() {
        Some(Busy::Revert)
    } else {
        None
    }
}

pub fn head(git: &Git, dir: &Path) -> Head {
    let out = git.run(dir, &["symbolic-ref", "-q", "--short", "HEAD"]);
    if out.success {
        Head::Branch(out.stdout.trim().to_string())
    } else {
        Head::Detached
    }
}

/// HEAD の commit が、どれかの branch (手元か remote-tracking) に含まれるか
pub fn head_on_some_branch(git: &Git, dir: &Path) -> bool {
    let out = git.run(
        dir,
        &[
            "for-each-ref",
            "--contains",
            "HEAD",
            "--count=1",
            "--format=%(refname)",
            "refs/heads",
            "refs/remotes",
        ],
    );
    out.success && !out.stdout.trim().is_empty()
}

/// 未解決 (衝突) のファイルがあるか
pub fn has_unmerged(git: &Git, dir: &Path) -> bool {
    let out = git.run(dir, &["ls-files", "--unmerged"]);
    out.success && !out.stdout.trim().is_empty()
}

pub fn has_origin(git: &Git, dir: &Path) -> bool {
    git.run(dir, &["remote", "get-url", "origin"]).success
}

fn remote_branch_exists(git: &Git, dir: &Path, branch: &str) -> bool {
    let r = format!("refs/remotes/origin/{branch}");
    git.run(dir, &["rev-parse", "--verify", "-q", &r]).success
}

/// 既定 branch の名前 (origin/ を除いた "main" など)
pub fn default_branch(git: &Git, dir: &Path) -> Option<String> {
    let out = git.run(dir, &["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]);
    if out.success
        && let Some(b) = out.stdout.trim().strip_prefix("refs/remotes/origin/")
        && remote_branch_exists(git, dir, b)
    {
        return Some(b.to_string());
    }
    ["main", "master"]
        .into_iter()
        .find(|b| remote_branch_exists(git, dir, b))
        .map(str::to_string)
}

/// branch の upstream の完全な名前 ("refs/remotes/origin/main" など)。設定が無い・指す先が無ければ無い
pub fn upstream(git: &Git, dir: &Path, branch: &str) -> Option<String> {
    let spec = format!("{branch}@{{upstream}}");
    let out = git.run(dir, &["rev-parse", "--symbolic-full-name", &spec]);
    let name = out.stdout.trim();
    (out.success && !name.is_empty()).then(|| name.to_string())
}

/// 追跡中のファイルに変更 (index に足したものも) があるか。未追跡のファイルは数えない。読めなければ変更ありとみなす
pub fn dirty(git: &Git, dir: &Path) -> bool {
    let out = git.run(
        dir,
        &[
            "--no-optional-locks",
            "status",
            "--porcelain=v2",
            "--untracked-files=no",
        ],
    );
    !out.success || !out.stdout.trim().is_empty()
}

/// branch が upstream より何 commit 進んでいて (ahead)、何 commit 遅れているか (behind)
pub fn ahead_behind(git: &Git, dir: &Path, branch: &str, upstream: &str) -> Option<(u32, u32)> {
    let range = format!("{branch}...{upstream}");
    let out = git.run(dir, &["rev-list", "--left-right", "--count", &range]);
    if !out.success {
        return None;
    }
    let mut it = out.stdout.split_whitespace().map(str::parse::<u32>);
    match (it.next(), it.next()) {
        (Some(Ok(ahead)), Some(Ok(behind))) => Some((ahead, behind)),
        _ => None,
    }
}

pub fn info(git: &Git, dir: &Path) -> Info {
    Info {
        head: head(git, dir),
        default_branch: default_branch(git, dir),
        dirty: dirty(git, dir),
    }
}

/// refs/remotes/・refs/heads/ を外した短い名前
pub fn short_ref(full: &str) -> &str {
    full.strip_prefix("refs/remotes/")
        .or_else(|| full.strip_prefix("refs/heads/"))
        .unwrap_or(full)
}
