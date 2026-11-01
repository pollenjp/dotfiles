//! ghq の repo の一覧。ghq list -p の絶対パスを、ghq root --all の root からの相対パス (github.com/<owner>/<repo>) と
//! org (相対パスの最後を除いたもの)・名前に分ける。root を差し替えるときは ghq を GHQ_ROOT=<root> で呼ぶ。

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    pub path: PathBuf,
    /// root からの相対パス ("github.com/owner/repo")
    pub rel: String,
    /// "github.com/owner"
    pub org: String,
    /// "repo"
    pub name: String,
}

/// root を Some にすると、ghq の設定の root の代わりにその下を見る (env は子に足す。テストが PATH などを替える)
pub fn ghq_repos(root: Option<&Path>, env: &[(OsString, OsString)]) -> Result<Vec<Found>, String> {
    let roots: Vec<PathBuf> = ghq(&["root", "--all"], root, env)?
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(PathBuf::from)
        .collect();
    // git の repo だけ (hg などに git -C を打つと、外側の git の repo を指しうる)
    let mut found: Vec<Found> = ghq(&["list", "-p", "--vcs", "git"], root, env)?
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|line| {
            let path = PathBuf::from(line);
            let rel = rel_of(&path, &roots);
            let (org, name) = split_rel(&rel);
            Found {
                path,
                rel,
                org,
                name,
            }
        })
        .collect();
    found.sort_by(|a, b| a.rel.cmp(&b.rel).then_with(|| a.path.cmp(&b.path)));
    found.dedup_by(|a, b| a.path == b.path);
    Ok(found)
}

/// "github.com/a/b" → ("github.com/a", "b")
pub fn split_rel(rel: &str) -> (String, String) {
    match rel.rsplit_once('/') {
        Some((org, name)) => (org.to_string(), name.to_string()),
        None => (String::new(), rel.to_string()),
    }
}

fn ghq(args: &[&str], root: Option<&Path>, env: &[(OsString, OsString)]) -> Result<String, String> {
    let mut cmd = Command::new("ghq");
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in env {
        cmd.env(k, v);
    }
    if let Some(root) = root {
        cmd.env("GHQ_ROOT", root);
    }
    let out = cmd
        .output()
        .map_err(|e| format!("ghq を起こせません (PATH に ghq が要ります): {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "ghq {} が失敗しました: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// root からの相対パス ("/" 区切り)。root が symlink を含む (macOS の /var など) ときは実体どうしで比べる
fn rel_of(path: &Path, roots: &[PathBuf]) -> String {
    let strip = |p: &Path, roots: &[PathBuf]| {
        roots
            .iter()
            .filter_map(|root| p.strip_prefix(root).ok())
            .min_by_key(|rest| rest.components().count())
            .map(slash)
    };
    if let Some(rel) = strip(path, roots) {
        return rel;
    }
    let real: Vec<PathBuf> = roots.iter().filter_map(|r| r.canonicalize().ok()).collect();
    path.canonicalize()
        .ok()
        .and_then(|p| strip(&p, &real))
        .unwrap_or_else(|| path.display().to_string())
}

fn slash(rest: &Path) -> String {
    rest.components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}
