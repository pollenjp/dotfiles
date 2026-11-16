//! claude-statusline (order 50): Windows の Claude Code の settings.json の `statusLine` を、runner が写した hook の口の status line
//! (`~/.claude/hooks/dotfiles-claude.exe claude-statusline`。中身は Linux の statusline-command.sh の写し) へ向ける。Linux の
//! `nix/scripts/bootstrap-claude-statusline.sh` に当たる (`statusLine.command` が同じなら何もしない・違えば元の値を出してから置き換える)。
//!
//! status line の command は Git Bash (無ければ PowerShell) が読む shell の文。Claude Code の docs のとおり `~` と `/` で書く (`\` は Git Bash で
//! 読めず、ホームのパスに空白があっても `~` なら割れない)。

use super::claude_settings::{self, hook_exe};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::ojson::OValue;
use crate::report::Kind;

/// settings.json の `statusLine.command`
pub const COMMAND: &str = "~/.claude/hooks/dotfiles-claude.exe claude-statusline";

pub struct ClaudeStatusline;

impl Step for ClaudeStatusline {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-statusline",
            order: 50,
            title: "Claude Code の settings.json の statusLine を、runner が写した hook の口 (dotfiles-claude.exe claude-statusline) へ向ける",
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let path = claude_settings::path(ctx);
        let (before, existed) = match claude_settings::load(&path) {
            Ok(v) => v,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![Outcome::new(Kind::Failed, e)];
            }
        };
        let current = match before.get("statusLine").and_then(|s| s.get("command")) {
            Some(OValue::String(c)) => c.clone(),
            _ => String::new(),
        };
        let after = if current == COMMAND {
            before.clone()
        } else {
            if !current.is_empty() {
                ctx.say(format!("既存の statusLine を置き換えます: {current}"));
            }
            let mut a = before.clone();
            a.set(
                "statusLine",
                OValue::Object(vec![
                    ("type".to_string(), OValue::String("command".to_string())),
                    ("command".to_string(), OValue::String(COMMAND.to_string())),
                ]),
            );
            a
        };
        let mut o = claude_settings::apply_change(
            ctx,
            mode,
            &path,
            (&before, existed),
            &after,
            "statusLine",
            "Claude Code を起動し直すと効く",
        );
        let exe = hook_exe(ctx);
        if !exe.is_file() {
            o = o.note(format!(
                "hook の口 {} が無い。claude-files の手順が写す (dotfiles apply)",
                exe.display()
            ));
        }
        vec![o]
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 無ければ statusLine を足し、2 回目は登録済み。ほかのキーと statusLine の後ろの順は残す
    //! - 別の statusLine は置き換える (padding などほかの項目を持っていても、command が同じなら触らない)

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    fn run(t: &TempDir, mode: Mode) -> Outcome {
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let mut ctx = Ctx {
            repo: t.path().join("dotfiles"),
            roots: Roots::from_home(&t.path().join("home")),
            state_dir: t.path().join("state"),
            host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
            sys: &sys,
            out: &mut out,
        };
        ClaudeStatusline.run(&mut ctx, mode).remove(0)
    }

    #[test]
    fn points_status_line_at_the_hook_exe() {
        let t = TempDir::new("claude-statusline");
        let p = t.write(
            "home/.claude/settings.json",
            "{\"statusLine\": {\"type\": \"command\", \"command\": \"bash ~/.claude/old.sh\"}, \"theme\": \"dark\"}\n",
        );
        assert_eq!(run(&t, Mode::Check).kind, Kind::Fix);
        assert_eq!(run(&t, Mode::Apply { force: false }).kind, Kind::Ok);
        let text = std::fs::read_to_string(&p).unwrap();
        assert!(text.contains(COMMAND), "{text}");
        assert!(
            text.find("statusLine").unwrap() < text.find("theme").unwrap(),
            "{text}"
        );
        assert_eq!(run(&t, Mode::Check).kind, Kind::Ok);
        // command が同じなら、ほかの項目は触らない
        std::fs::write(&p, format!("{{\"statusLine\": {{\"type\": \"command\", \"command\": \"{COMMAND}\", \"padding\": 0}}}}")).unwrap();
        assert_eq!(run(&t, Mode::Check).kind, Kind::Ok);
    }
}
