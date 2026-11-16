//! dotfiles が持つ生成物 (claude-notion.json・hc と herdr-app の SKILL.md・claude-skills-dir) を、望む中身に揃える。
//!
//! Linux では home-manager の read-only のファイル (`home.file`) か、毎回書き直す控えに当たる。dotfiles のほかが書く中身ではないので、
//! 記録を持たず、違えば書き直す (手で置いた写しも)。書くのは置き先と同じディレクトリの一時ファイルから rename (dotfiles-private の
//! docs/adr/064_win_w02_claude_skills_hub_*)。

use super::{Mode, Outcome};
use crate::context::Ctx;
use crate::fsutil;
use crate::report::Kind;
use std::path::Path;

/// `path` を中身 `desired` に揃える (`what` は締めの行に出す名前)。無い → missing・違う → fix (apply で書く)・同じ → ok。置き先が
/// ディレクトリ・読めない・書けない → failed。
pub fn sync(ctx: &mut Ctx, mode: Mode, path: &Path, desired: &[u8], what: &str) -> Outcome {
    let shown = path.display().to_string();
    if path.is_dir() {
        ctx.say(format!("!! 置き先がディレクトリです: {shown}"));
        return Outcome::new(
            Kind::Failed,
            format!("{what} の置き先がディレクトリ ({shown})"),
        );
    }
    let exists = path.exists();
    if exists {
        match std::fs::read(path) {
            Ok(have) if have == desired => {
                ctx.say(format!("同じです: {shown}"));
                return Outcome::new(Kind::Ok, format!("{what} は揃っている"));
            }
            Ok(_) => {}
            Err(e) => {
                ctx.say(format!("!! 読めません: {shown} ({e})"));
                return Outcome::new(Kind::Failed, format!("{what} が読めない ({e})"));
            }
        }
    }
    let (kind, todo, past, done) = if exists {
        (Kind::Fix, "書き直す", "書き直した", "書き直しました")
    } else {
        (Kind::Missing, "作る", "作った", "作りました")
    };
    let state = if exists { "違う" } else { "無い" };
    match mode {
        Mode::Check => {
            ctx.say(format!("{state} (apply で{todo}): {shown}"));
            Outcome::new(kind, format!("{what} が{state} → apply で{todo}"))
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] {todo}: {shown}"));
            Outcome::new(kind, format!("[dry-run] {what} が{state} → {todo}"))
        }
        Mode::Apply { .. } => match fsutil::write_atomic(path, desired) {
            Ok(()) => {
                ctx.say(format!("{done}: {shown}"));
                Outcome::new(Kind::Ok, format!("{what} を{past}"))
            }
            Err(e) => {
                ctx.say(format!("!! 書けません: {shown} ({e})"));
                Outcome::new(Kind::Failed, format!("{what} を書けない ({e})"))
            }
        },
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 無い → missing (check と dry-run は書かない)・apply で作る → ok・同じ → ok・違う → fix (apply で書き直す)
    //! - 置き先がディレクトリ → failed (書かない)

    use super::*;
    use crate::context::Ctx;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::report::Kind;
    use crate::steps::Mode;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    fn run(path: &Path, desired: &str, mode: Mode) -> (Kind, String, String) {
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let o = {
            let mut ctx = Ctx {
                repo: "/r".into(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: "/s".into(),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys: &sys,
                out: &mut out,
            };
            sync(
                &mut ctx,
                mode,
                path,
                desired.as_bytes(),
                "claude-notion.json",
            )
        };
        (o.kind, o.text, String::from_utf8(out).unwrap())
    }

    #[test]
    fn generated_states() {
        let t = TempDir::new("generated");
        let p = t
            .path()
            .join("state")
            .join("dotfiles")
            .join("claude-notion.json");
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (kind, text, _) = run(&p, "A\n", mode);
            assert_eq!(kind, Kind::Missing, "{mode:?}");
            assert!(text.contains("claude-notion.json が無い"), "{text}");
            assert!(!p.exists());
        }
        let (kind, text, out) = run(&p, "A\n", Mode::Apply { force: false });
        assert_eq!(kind, Kind::Ok, "{text}");
        assert_eq!(text, "claude-notion.json を作った");
        assert!(out.contains("作りました: "), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "A\n");
        let (kind, _, out) = run(&p, "A\n", Mode::Check);
        assert_eq!(kind, Kind::Ok);
        assert!(out.contains("同じです: "), "{out}");
        let (kind, text, _) = run(&p, "B\n", Mode::Check);
        assert_eq!(kind, Kind::Fix);
        assert!(text.contains("claude-notion.json が違う"), "{text}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "A\n");
        let (kind, text, out) = run(&p, "B\n", Mode::Apply { force: false });
        assert_eq!(kind, Kind::Ok);
        assert_eq!(text, "claude-notion.json を書き直した");
        assert!(out.contains("書き直しました: "), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "B\n");
    }

    #[test]
    fn directory_in_the_way_fails() {
        let t = TempDir::new("generated-dir");
        let p = t.path().join("SKILL.md");
        std::fs::create_dir_all(&p).unwrap();
        let (kind, text, _) = run(&p, "A\n", Mode::Apply { force: false });
        assert_eq!(kind, Kind::Failed);
        assert!(text.contains("ディレクトリ"), "{text}");
        assert!(p.is_dir());
    }
}
