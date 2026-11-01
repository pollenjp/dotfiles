//! gitViaGh (dotfiles.claude.gitViaGh.enable)。on のマシンでは fetch を git gh (gh の資格情報で HTTPS) で打つ。
//!
//! 値は home-manager が ~/.local/state/dotfiles/git-via-gh.json に {"enable":true} の形で置く。setup の git_github と
//! 同じく "enable" の値が true のときだけ on と読み、ファイルが無い・読めない・ほかの値なら off。
//! on なのに git-gh か gh が無い・gh が github.com にログインしていないときは、ssh へ黙って倒さずに止める
//! (WSL では ssh が repo の数だけ 1Password の承認を出しかねない)。

use std::ffi::OsStr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::git::run_detached;

/// gh auth token が返らないとき (keyring の待ちなど) に諦めるまでの時間
const GH_TIMEOUT: Duration = Duration::from_secs(20);

pub fn state_file(home: &Path) -> PathBuf {
    home.join(".local/state/dotfiles/git-via-gh.json")
}

/// JSON の "enable" の値が true か (空白は許す。文字列の "true" は数えない)
pub fn enabled_in(json: &str) -> bool {
    const KEY: &str = "\"enable\"";
    let mut rest = json;
    while let Some(i) = rest.find(KEY) {
        rest = &rest[i + KEY.len()..];
        if let Some(value) = rest.trim_start().strip_prefix(':')
            && let Some(tail) = value.trim_start().strip_prefix("true")
            && !tail.starts_with(|c: char| c.is_alphanumeric() || c == '_')
        {
            return true;
        }
    }
    false
}

/// --via-gh / --no-via-gh (flag) があればそれ、無ければ home の状態ファイル
pub fn resolve(flag: Option<bool>, home: Option<&Path>) -> bool {
    flag.unwrap_or_else(|| {
        home.and_then(|h| std::fs::read_to_string(state_file(h)).ok())
            .is_some_and(|json| enabled_in(&json))
    })
}

/// git-gh と gh が path にあり、gh が github.com にログインしているか
pub fn preflight(path: &OsStr) -> Result<(), String> {
    const SKIP: &str = "この回だけ ssh (素の git) で通すなら --no-via-gh を付けてください。";
    if find_in(path, "git-gh").is_none() {
        return Err(format!(
            "gitViaGh が on ですが、git-gh が PATH にありません (dotfiles の home-manager が入れます)。{SKIP}"
        ));
    }
    let Some(gh) = find_in(path, "gh") else {
        return Err(format!(
            "gitViaGh が on ですが、gh が PATH にありません。gh を入れて gh auth login を実行してください。{SKIP}"
        ));
    };
    let mut cmd = Command::new(gh);
    cmd.args(["auth", "token", "--hostname", "github.com"])
        .env("PATH", path);
    let out = run_detached(cmd, Some(GH_TIMEOUT));
    if out.success {
        return Ok(());
    }
    let mut msg = format!(
        "gitViaGh が on ですが、gh が github.com にログインしていません。gh auth login を実行してください。{SKIP}"
    );
    let reason = out.stderr.trim();
    if !reason.is_empty() {
        msg.push_str(&format!("\n  gh: {reason}"));
    }
    Err(msg)
}

/// 画面の上に出す経路の名前
pub fn route_label(via_gh: bool) -> &'static str {
    if via_gh { "git gh (gitViaGh)" } else { "git" }
}

fn find_in(path: &OsStr, name: &str) -> Option<PathBuf> {
    std::env::split_paths(path)
        .map(|dir| dir.join(name))
        .find(|p| {
            std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}
