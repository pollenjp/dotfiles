//! `pjp hub guard`: Claude Code の PreToolUse の hook (spec §7.3。pjp-herdr-hub の `hub-guard.sh` の写し)。
//!
//! ハブの会話が Write / Edit / MultiEdit / NotebookEdit で、ハブの中と repo の中にファイルを書こうとしたら止める。
//!
//! ## 登録
//!
//! ハブの `.claude/settings.json` (雛形は `assets/hub/settings.json`。`pjp hub init` が写して commit する) が
//! `pjp hub guard` を登録する。shell の書き方 (`~`・`$`・引用符・`;`) を使わないので、Claude Code が hook を PowerShell で
//! 動かしても (Git Bash の無い Windows)、Git Bash や sh で動かしても同じに動く。道具は shim から打つので、claude-skills を
//! pull すれば、作り済みの worktree の hook も新しくなる。
//!
//! 同じ雛形の答え待ちの印の hook (`pjp mark hook prompt; exit 0`・`pjp mark hook stop; exit 0`。pjp-hc-child) だけは、
//! 落ちても発言を止めない・ターンの終わりで回り続けないために `;` を使う (spec `2026-11-19-hub-asking-hook-design.md` の
//! §5。`;` と `exit 0` は Git Bash でも PowerShell でも同じに効き、`pjp` が無くても `exit 0` が走る)。guard には付けない
//! (shim が設定の誤りの 2 で終わると書き込みを止める、今の形のまま)。
//!
//! ## 判定
//!
//! 書き先 (まだ無ければ最も近い既存の祖先) の symlink・junction を解き、そこが git の work tree か `.git` の中なら:
//!
//! - ハブの中: その git の共通ディレクトリが、ハブ (`CLAUDE_PROJECT_DIR`、無ければ入力の cwd) のと同じ。ハブの別の
//!   worktree と `.git` の中も含む (worktree の頭の `.claude/settings.local.json` は通す)
//! - repo の中: それ以外で、remote を 1 つでも持つ (ghq の checkout・`~/.claude/skills/pjp-*` の先)
//!
//! のどちらかなら止める。Windows の `\\wsl.localhost\<distro>\…` (と `\\wsl$\…`) は git を呼ばず (Windows の git は WSL の
//! repo を「持ち主が違う」で読まないことがある)、`.git` を持つ所の中なら止める (WSL の子の worktree・checkout)。remote の
//! 無い work tree と git の外 (scratchpad など) は通す。Windows では Git Bash の形 `/c/Users/…` を `C:\Users\…` と読む。
//!
//! Bash・PowerShell のコマンドは見ない (heredoc の本文や式を書き先と取り違えて、ハブの会話の作業を止める)。決まりは
//! ハブの CLAUDE.md と skill で禁じ、会話の終わりに git status でハブに残ったものを見る。
//!
//! ## 入出力
//!
//! - stdin: `{"tool_name": "...", "tool_input": {"file_path"|"notebook_path": ...}, "cwd": "..."}` (UTF-8。BOM があっても読む)
//! - stdout: 止めるときだけ hookSpecificOutput (permissionDecision: deny と理由)。日本語は `\uXXXX` に逃がし、ASCII だけで
//!   出す (shell や code page が間に入っても化けない)。通すときは何も出さない
//! - 終了コードはいつも 0 (止めるのは JSON で言う。2 で終わると Claude Code は書き込みを全部止める)
//!
//! git が無い・入力が読めないときは通す (stderr に 1 行)。安全網であって境界ではない。

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use pjp_core::paths;
use serde_json::{Value, json};

use crate::git::Git;
use crate::pathx;

/// 見る道具。
const WRITING_TOOLS: [&str; 4] = ["Write", "Edit", "MultiEdit", "NotebookEdit"];

/// hook の判定。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// 通す (何も出さない)。
    Allow,
    /// 通すが、stderr に 1 行出す。
    Note(String),
    /// 止める (理由)。
    Deny(String),
}

/// hook の外の様子 (テストは偽物を渡す)。
#[derive(Debug, Clone, Default)]
pub struct Context {
    pub git: Option<Git>,
    pub home: Option<PathBuf>,
    /// `CLAUDE_PROJECT_DIR` (ハブの会話の worktree)。
    pub project_dir: Option<PathBuf>,
    /// 入力に cwd が無いときの、相対パスの基 (この process の cwd)。
    pub process_cwd: Option<PathBuf>,
    /// `\\wsl.localhost\…` を WSL の場所として見るか (Windows だけ)。
    pub windows: bool,
}

impl Context {
    /// この process の env と PATH から作る。
    pub fn from_env() -> Context {
        Context {
            git: Git::find(),
            home: pjp_core::paths::home_dir().ok(),
            project_dir: std::env::var_os("CLAUDE_PROJECT_DIR")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from),
            process_cwd: std::env::current_dir().ok(),
            windows: cfg!(windows),
        }
    }
}

/// hook の入力 (stdin のバイト) を判定する。
pub fn decide(input: &[u8], ctx: &Context) -> Decision {
    let Some(git) = &ctx.git else {
        return Decision::Note("git が無いので、書き先を見ずに通す".to_owned());
    };
    let Ok(v) = serde_json::from_str::<Value>(&pjp_core::text::decode_text(input)) else {
        return Decision::Allow;
    };
    let tool = v["tool_name"].as_str().unwrap_or("");
    if !WRITING_TOOLS.contains(&tool) {
        return Decision::Allow; // matcher でも絞るが、道具だけでも正しく振る舞う
    }
    // jq の `.file_path // .notebook_path` と同じく、file_path が文字列なら (空でも) それを使う
    let input_path = match (
        v["tool_input"].get("file_path"),
        v["tool_input"].get("notebook_path"),
    ) {
        (Some(Value::String(s)), _) | (_, Some(Value::String(s))) => s.as_str(),
        _ => "",
    };
    if input_path.is_empty() {
        return Decision::Allow;
    }
    let cwd = v["cwd"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from);
    let Some(file) = absolute(input_path, cwd.as_deref(), ctx) else {
        return Decision::Allow;
    };

    if ctx.windows
        && let Some(distro) = wsl_distro(&file.to_string_lossy())
    {
        return wsl_decision(&file, &distro);
    }

    // 書き先がまだ無ければ、最も近い既存の祖先で見る (新しいファイル・新しいディレクトリの中も捕まえる)
    let Some(probe) = pathx::nearest_existing(&file) else {
        return Decision::Allow;
    };
    let Some(real) = pathx::resolve(&probe) else {
        return Decision::Allow;
    };
    let dir = if real.is_dir() {
        real.clone()
    } else {
        real.parent()
            .map_or_else(|| real.clone(), Path::to_path_buf)
    };
    let Some(target_common) = git.common_dir(&dir) else {
        return Decision::Allow; // git の外
    };

    let hub_dir = ctx.project_dir.clone().or(cwd);
    let hub_common = hub_dir.as_deref().and_then(|d| git.common_dir(d));
    if hub_common.is_some_and(|h| paths::same_path_here(&h, &target_common)) {
        // worktree の頭の .claude/settings.local.json は通す。ハブの .gitignore が外す、Claude Code のこの場所の許可の置き場で
        // (ユーザーに頼まれた許可の設定を止めない)、ハブを散らかさない
        if let Some(top) = git.toplevel(&dir) {
            let rest = file.strip_prefix(&probe).unwrap_or(Path::new(""));
            let local = top.join(".claude").join("settings.local.json");
            if paths::same_path_here(&real.join(rest), &local) {
                return Decision::Allow;
            }
        }
        return Decision::Deny(format!(
            "{} はハブ (pjp-hc-hub) の中。ハブにはファイルを作らない。作業用のファイル (依頼文・図の下書きなど) は scratchpad に置く。Bash・PowerShell で書いても同じ決まり",
            file.display()
        ));
    }

    if !git.remotes(&dir).is_empty() {
        // .git の中では show-toplevel が引けないので、共通ディレクトリの親 (main の checkout) を出す
        let top = git.toplevel(&dir).unwrap_or_else(|| {
            target_common
                .parent()
                .map_or_else(|| target_common.clone(), Path::to_path_buf)
        });
        return Decision::Deny(format!(
            "{} は repo ({}) の中。ハブの会話は repo を自分で直さない。pjp-hc-hub の手順で、その repo の子を pjp child new で立てて子の Claude に任せる。Bash・PowerShell で書いても同じ決まり",
            file.display(),
            top.display()
        ));
    }
    Decision::Allow
}

/// 入力のパスを絶対パスにする (Windows の Git Bash の形 `/c/…` を `C:\…` に読み替え、頭の `~` を展開し、相対なら入力の
/// cwd、無ければこの process の cwd から)。
fn absolute(input: &str, cwd: Option<&Path>, ctx: &Context) -> Option<PathBuf> {
    let msys = ctx.windows.then(|| paths::from_msys(input)).flatten();
    let input = msys.as_deref().unwrap_or(input);
    let expanded = match &ctx.home {
        Some(home) => paths::expand_tilde(OsStr::new(input), home, ctx.windows),
        None => PathBuf::from(input),
    };
    if expanded.is_absolute() {
        return Some(pathx::native(&expanded));
    }
    let base = cwd.map(Path::to_path_buf).or(ctx.process_cwd.clone())?;
    Some(pathx::native(&base.join(expanded)))
}

/// `\\wsl.localhost\<distro>\…`・`\\wsl$\<distro>\…` (区切りは `\` と `/` のどちらでも、名前の大文字小文字は問わない。
/// `\\?\UNC\` の付いた形も) なら distro の名前。
pub fn wsl_distro(path: &str) -> Option<String> {
    let s = path.replace('/', "\\");
    let s = match s.strip_prefix(r"\\?\UNC\") {
        Some(rest) => format!(r"\\{rest}"),
        None => s,
    };
    let mut parts = s.strip_prefix(r"\\")?.split('\\');
    let host = parts.next()?;
    let distro = parts.next()?;
    let wsl = host.eq_ignore_ascii_case("wsl.localhost") || host.eq_ignore_ascii_case("wsl$");
    (wsl && !distro.is_empty()).then(|| distro.to_owned())
}

/// WSL の場所への書き込み: 書き先から上へ `.git` を持つ所を探し、あれば止める (git は呼ばない)。symlink (WSL の
/// `~/.claude/skills/pjp-*` など) は、Windows から解ければ解いた先から探す。
fn wsl_decision(file: &Path, distro: &str) -> Decision {
    let Some(probe) = pathx::nearest_existing(file) else {
        return Decision::Allow;
    };
    let resolved = pathx::resolve(&probe);
    let found = resolved
        .as_deref()
        .and_then(work_tree_by_walk)
        .or_else(|| work_tree_by_walk(&probe));
    match found {
        Some(top) => Decision::Deny(format!(
            "{} は WSL ({distro}) の git の work tree ({}) の中。ハブの会話は子のマシンの repo を自分で直さない。pjp-hc-hub の手順で、子を pjp child new で立てて任せる。Bash・PowerShell で書いても同じ決まり",
            file.display(),
            top.display()
        )),
        None => Decision::Allow,
    }
}

/// `start` から上へ辿り、git の work tree の頭 (`.git` を持つディレクトリ) を返す。`.git` の中なら、その `.git` の親。
pub fn work_tree_by_walk(start: &Path) -> Option<PathBuf> {
    for a in start.ancestors().filter(|a| !a.as_os_str().is_empty()) {
        if a.file_name()
            .is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case(".git"))
        {
            return a.parent().map(Path::to_path_buf);
        }
        if a.join(".git").symlink_metadata().is_ok() {
            return Some(a.to_path_buf());
        }
    }
    None
}

/// 止めるときの stdout (1 行の JSON。ASCII だけ)。
pub fn deny_json(reason: &str) -> String {
    ascii_json(&json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
}

/// JSON にし、ASCII でない文字を `\uXXXX` (BMP の外はサロゲートの組) に逃がす (`pjp_core::text::json_ascii`)。
pub fn ascii_json(v: &Value) -> String {
    pjp_core::text::json_ascii(&v.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wsl_paths_are_recognized() {
        for p in [
            r"\\wsl.localhost\Ubuntu\home\u\x",
            r"\\WSL.LOCALHOST\Ubuntu-24.04\home",
            r"\\wsl$\Ubuntu\home\u",
            "//wsl.localhost/Ubuntu/home/u",
            r"\\?\UNC\wsl.localhost\Ubuntu\home\u",
        ] {
            assert!(wsl_distro(p).is_some(), "{p}");
        }
        assert_eq!(
            wsl_distro(r"\\wsl.localhost\Ubuntu-24.04\x").as_deref(),
            Some("Ubuntu-24.04")
        );
        for p in [
            r"C:\Users\user\h",
            r"\\server\share\x",
            r"\\wsl.localhost\",
            r"\\wsl.localhost",
            "/home/u/x",
            r"\\?\C:\x",
        ] {
            assert_eq!(wsl_distro(p), None, "{p}");
        }
    }

    #[test]
    fn ascii_json_escapes_non_ascii() {
        let s = deny_json("ハブ 🗑️ の中");
        assert!(s.is_ascii(), "{s}");
        let back: Value = serde_json::from_str(&s).unwrap();
        assert_eq!(
            back["hookSpecificOutput"]["permissionDecisionReason"],
            "ハブ 🗑️ の中"
        );
        assert_eq!(back["hookSpecificOutput"]["permissionDecision"], "deny");
        assert!(s.contains("\\ud83d\\uddd1"), "{s}"); // 🗑 (U+1F5D1) はサロゲートの組
    }

    #[test]
    fn work_tree_by_walk_finds_dot_git() {
        let base = std::env::temp_dir().join(format!("pjp-hc-hub-walk-{}", std::process::id()));
        let repo = base.join("repo");
        std::fs::create_dir_all(repo.join(".git").join("objects")).unwrap();
        std::fs::create_dir_all(repo.join("src")).unwrap();
        let wt = base.join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join(".git"), "gitdir: /x/.git/worktrees/wt\n").unwrap();
        assert_eq!(work_tree_by_walk(&repo.join("src")), Some(repo.clone()));
        assert_eq!(
            work_tree_by_walk(&repo.join(".git").join("objects")),
            Some(repo.clone())
        );
        assert_eq!(work_tree_by_walk(&wt), Some(wt.clone()));
        let outside = base.join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        // base の上に .git があるマシン (ホームを git で管理しているなど) では見つかるので、base の中だけを見る
        assert!(work_tree_by_walk(&outside).is_none_or(|t| !t.starts_with(&base)));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn non_writing_tools_and_empty_paths_pass() {
        let ctx = Context {
            git: Git::find(),
            ..Context::default()
        };
        if ctx.git.is_none() {
            return;
        }
        for input in [
            r#"{"tool_name":"Bash","tool_input":{"command":"echo x > /tmp/x"}}"#,
            r#"{"tool_name":"Write","tool_input":{"file_path":""}}"#,
            r#"{"tool_name":"Write","tool_input":{}}"#,
            "not json",
            "",
        ] {
            assert_eq!(decide(input.as_bytes(), &ctx), Decision::Allow, "{input}");
        }
    }

    #[test]
    fn missing_git_is_a_note() {
        let d = decide(
            br#"{"tool_name":"Write","tool_input":{"file_path":"/x"}}"#,
            &Context::default(),
        );
        assert!(
            matches!(d, Decision::Note(ref n) if n.contains("git")),
            "{d:?}"
        );
    }
}
