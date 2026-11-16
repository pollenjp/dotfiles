//! claude-notion (order 50): Notion へ書く skill の宛先を、ホストの値の `[claude.notion]` から `~/.local/state/dotfiles/claude-notion.json` に
//! 書く (Linux の home/modules/claude.nix が `dotfiles.claude.notion` から書くのと同じ中身)。読むのは claude-skills の pjp-notion-profile
//! (Python の notion_profile.py と、Rust の `pjp notion-profile`)。どちらもホームからの固定の場所で読み、`XDG_STATE_HOME` を見ない。
//!
//! dotfiles が持つ生成物なので、違えば書き直す (`generated::sync`。dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*)。

use super::{Gate, Mode, Outcome, Step, StepInfo, generated};
use crate::context::{Ctx, join_segments};

/// 置き先 (ホームからの相対)
pub const REL: &str = ".local/state/dotfiles/claude-notion.json";

pub struct ClaudeNotion;

impl Step for ClaudeNotion {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-notion",
            order: 50,
            title: "Notion へ書く skill の宛先 (~/.local/state/dotfiles/claude-notion.json) をホストの値の [claude.notion] から書く",
            // Linux は Claude Code を入れるホスト (dotfiles.claude.enable) に置く
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let path = join_segments(&ctx.roots.user_profile, REL);
        let desired = ctx.host.notion.json();
        let mut o = generated::sync(ctx, mode, &path, desired.as_bytes(), "claude-notion.json");
        if ctx.host.notion.profile.is_none() {
            o = o.note("このマシンの既定のプロファイルが無い (ホストの値の [claude.notion] profile)。宛先の規則に当たらない repo と repo の外 (ハブ ~/h など) では、Notion へ書く skill が止まる");
        }
        vec![o]
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - ホストの値の profile が入った JSON を書き、同じなら揃っている
    //! - profile が無ければ、Notion へ書く skill が止まりうることを添える

    use super::*;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    fn run(t: &TempDir, host: &str, mode: Mode) -> Outcome {
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let mut ctx = Ctx {
            repo: t.path().join("dotfiles"),
            roots: Roots::from_home(&t.path().join("home")),
            state_dir: t.path().join("state"),
            host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
            sys: &sys,
            out: &mut out,
        };
        ClaudeNotion.run(&mut ctx, mode).remove(0)
    }

    #[test]
    fn writes_the_host_values() {
        let t = TempDir::new("claude-notion");
        let host = "[claude.notion]\nprofile = \"personal\"\n";
        let p = t
            .path()
            .join("home")
            .join(".local")
            .join("state")
            .join("dotfiles")
            .join("claude-notion.json");
        assert_eq!(run(&t, host, Mode::Check).kind, Kind::Missing);
        assert!(!p.exists());
        let o = run(&t, host, Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(o.notes.is_empty());
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "{\"override\":{},\"profile\":\"personal\",\"routes\":{}}\n"
        );
        assert_eq!(run(&t, host, Mode::Check).kind, Kind::Ok);
        assert_eq!(ClaudeNotion.info().gate, Gate::Tool("windowsClaudeCode"));
        assert!(ClaudeNotion.info().windows_only);
    }

    #[test]
    fn notes_when_no_profile() {
        let t = TempDir::new("claude-notion-null");
        let o = run(&t, "", Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok);
        assert!(o.notes[0].contains("[claude.notion] profile"), "{o:?}");
    }
}
