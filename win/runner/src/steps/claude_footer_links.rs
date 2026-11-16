//! claude-footer-links (order 50): Windows の Claude Code の settings.json の `footerLinksRegexes` (会話に出た Dev Tracker のチケット・PR・cc-page を
//! footer のバッジにする正規表現) を、dotfiles の `nix/files/claude/footer-links.json` で丸ごと置き換える。Linux の
//! `nix/scripts/bootstrap-claude-footer-links.sh` に当たる (このキーは dotfiles が持つ。手で足した項目も次の apply で消える)。
//!
//! cc-page の規則の `@ccPagesPort@` は、Linux で `dotfiles.ccPages.port` が null のときと同じ cc-pages の既定の 7777 で埋める (Windows に今
//! cc-pages は無いが、WSL の cc-pages の localhost のページは Windows のブラウザでも開ける)。

use super::claude_settings;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::hooks::statusline::CC_PAGES_PORT;
use crate::ojson::OValue;
use crate::report::Kind;

/// footerLinksRegexes の元 (dotfiles の clone の中)
pub const SOURCE: &str = "nix/files/claude/footer-links.json";

pub struct ClaudeFooterLinks;

impl Step for ClaudeFooterLinks {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-footer-links",
            order: 50,
            title: "Claude Code の settings.json の footerLinksRegexes (チケット・PR・cc-page のバッジ) を nix/files/claude/footer-links.json にする",
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let src = ctx.repo_path(SOURCE);
        let desired = match std::fs::read_to_string(&src)
            .map_err(|e| e.to_string())
            .and_then(|t| OValue::parse(&t.replace("@ccPagesPort@", &CC_PAGES_PORT.to_string())))
        {
            Ok(v) => v,
            Err(e) => {
                let why = format!("{} が読めない ({e})", src.display());
                ctx.say(format!("!! {why}"));
                return vec![Outcome::new(Kind::Failed, why)];
            }
        };
        if !shape_ok(&desired) {
            let why = format!(
                "{} が footerLinksRegexes の配列 ({{type: \"regex\", pattern, url, label?}} の並び) ではない",
                src.display()
            );
            ctx.say(format!("!! {why}"));
            return vec![Outcome::new(Kind::Failed, why)];
        }
        let path = claude_settings::path(ctx);
        let (before, existed) = match claude_settings::load(&path) {
            Ok(v) => v,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![Outcome::new(Kind::Failed, e)];
            }
        };
        let current = before
            .get("footerLinksRegexes")
            .filter(|v| !matches!(v, OValue::Null | OValue::Bool(false)));
        let after = if current.map(OValue::to_value) == Some(desired.to_value()) {
            before.clone()
        } else {
            if let Some(c) = current {
                ctx.say("既存の footerLinksRegexes を置き換えます:");
                ctx.say(c.to_pretty().trim_end());
            }
            let mut a = before.clone();
            a.set("footerLinksRegexes", desired);
            a
        };
        vec![claude_settings::apply_change(
            ctx,
            mode,
            &path,
            (&before, existed),
            &after,
            "footerLinksRegexes",
            "実行中の会話にも、次の turn の終わりから効く",
        )]
    }
}

/// Claude Code が黙って捨てる形でないか (bash の版の jq の確かめと同じ)。
fn shape_ok(v: &OValue) -> bool {
    let OValue::Array(items) = v else {
        return false;
    };
    items.iter().all(|i| {
        matches!(i, OValue::Object(_))
            && matches!(i.get("type"), Some(OValue::String(t)) if t == "regex")
            && matches!(i.get("pattern"), Some(OValue::String(_)))
            && matches!(i.get("url"), Some(OValue::String(_)))
            && matches!(
                i.get("label"),
                None | Some(OValue::Null) | Some(OValue::Bool(false)) | Some(OValue::String(_))
            )
    })
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - repo の footer-links.json の @ccPagesPort@ を 7777 にした配列を書き、2 回目は登録済み (キーの順の違いは同じと見る)
    //! - 手で足した項目は置き換える。形の合わない元は failed
    //! - repo の footer-links.json は形が合う (Claude Code が捨てない)

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    fn run(t: &TempDir, repo: &Path, mode: Mode) -> Outcome {
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let mut ctx = Ctx {
            repo: repo.to_path_buf(),
            roots: Roots::from_home(&t.path().join("home")),
            state_dir: t.path().join("state"),
            host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
            sys: &sys,
            out: &mut out,
        };
        ClaudeFooterLinks.run(&mut ctx, mode).remove(0)
    }

    #[test]
    fn writes_the_repo_rules() {
        let t = TempDir::new("claude-footer-links");
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let p = t.write("home/.claude/settings.json", "{\"footerLinksRegexes\": [{\"type\": \"regex\", \"pattern\": \"x\", \"url\": \"y\"}]}\n");
        assert_eq!(run(&t, &repo, Mode::Check).kind, Kind::Fix);
        assert_eq!(run(&t, &repo, Mode::Apply { force: false }).kind, Kind::Ok);
        let v = OValue::parse(&std::fs::read_to_string(&p).unwrap())
            .unwrap()
            .to_value();
        let rules = v["footerLinksRegexes"].as_array().unwrap();
        assert!(rules.len() > 1);
        assert!(!v.to_string().contains("@ccPagesPort@"));
        assert!(v.to_string().contains("localhost:7777"), "{v}");
        assert_eq!(run(&t, &repo, Mode::Check).kind, Kind::Ok);
    }

    #[test]
    fn rejects_a_bad_source() {
        let t = TempDir::new("claude-footer-links-bad");
        let repo = t.path().join("repo");
        t.write(
            "repo/nix/files/claude/footer-links.json",
            "[{\"type\": \"glob\", \"pattern\": \"x\", \"url\": \"y\"}]",
        );
        assert_eq!(
            run(&t, &repo, Mode::Apply { force: false }).kind,
            Kind::Failed
        );
        assert!(
            !t.path()
                .join("home")
                .join(".claude")
                .join("settings.json")
                .exists()
        );
        assert!(shape_ok(
            &OValue::parse(
                "[{\"type\": \"regex\", \"pattern\": \"a\", \"url\": \"b\", \"label\": \"c\"}]"
            )
            .unwrap()
        ));
        assert!(!shape_ok(&OValue::parse("{}").unwrap()));
        assert!(!shape_ok(
            &OValue::parse("[{\"type\": \"regex\", \"pattern\": \"a\", \"url\": 1}]").unwrap()
        ));
    }
}
