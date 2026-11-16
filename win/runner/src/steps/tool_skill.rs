//! hc-skill・herdr-app-skill (order 98): Windows の Claude Code の `~/.claude/skills/{hc,herdr-app}/SKILL.md` を、入っている道具の
//! `<道具> --skill` (手引きの Markdown) に頭 (frontmatter と、作った版を書くコメント) を足して作る。Linux の hc の skill
//! (`nix/pkgs/herdr-core/claude-skill.nix`。頭は同じ `nix/pkgs/herdr-core/claude-skill-head.md`) と同じ形。herdr-app は Windows だけなので、
//! 頭は `win/herdr-app/claude-skill-head.md`。
//!
//! 道具は PATH → 公式の置き場所 (`%LOCALAPPDATA%\Programs\herdr-core\hc.exe`・`%LOCALAPPDATA%\Programs\herdr-app\herdr-app.exe`) の順に探す
//! (同じ apply の herdr-app の手順が入れた直後は、runner の PATH に無い)。版は `<道具> --version` の `<名前> <版>`。SKILL.md は dotfiles が持つ
//! 生成物なので、違えば書き直す (指揮役が手で置いた一時の写しも。dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*)。道具を上げる
//! (releases.json) と、次の apply で作り直る。

use super::{Gate, Mode, Outcome, Step, StepInfo, generated};
use crate::context::{Ctx, join_segments};
use crate::link::is_link;
use crate::process::CommandSpec;
use crate::report::Kind;
use std::time::Duration;

/// 道具の skill の表の 1 行。
#[derive(Clone, Copy, Debug)]
pub struct ToolSkillSpec {
    pub id: &'static str,
    /// PATH で探す名前 (`--version` の頭の名前でもある)
    pub program: &'static str,
    /// 公式の置き場所 (`%LOCALAPPDATA%` からの相対。`/` 区切り)
    pub official: &'static str,
    /// 頭のファイル (repo の中。`/` 区切り)
    pub head: &'static str,
    /// `~/.claude/skills/` の下のディレクトリの名前 (frontmatter の name と同じ)
    pub dir: &'static str,
    pub title: &'static str,
}

pub const SPECS: &[ToolSkillSpec] = &[
    ToolSkillSpec {
        id: "hc-skill",
        program: "hc",
        official: "Programs/herdr-core/hc.exe",
        head: "nix/pkgs/herdr-core/claude-skill-head.md",
        dir: "hc",
        title: "hc の skill (~/.claude/skills/hc/SKILL.md) を hc --skill から作る",
    },
    ToolSkillSpec {
        id: "herdr-app-skill",
        program: "herdr-app",
        official: "Programs/herdr-app/herdr-app.exe",
        head: "win/herdr-app/claude-skill-head.md",
        dir: "herdr-app",
        title: "herdr-app の skill (~/.claude/skills/herdr-app/SKILL.md) を herdr-app --skill から作る",
    },
];

/// `<name> --version` の出力 (`hc 0.1.21`・`herdr-app v0.1.20 (abc)`) から版を拾う。Install-HerdrApp.ps1 の
/// Get-HerdrAppVersionFromOutput と同じ読み方 (`^\s*<名前>\s+v?(X.Y.Z)` の後ろに数字か `.` が続かない)。
pub fn version_from_output(lines: &[String], name: &str) -> Option<String> {
    lines.iter().find_map(|line| {
        let rest = line.trim().strip_prefix(name)?;
        if !rest.starts_with(char::is_whitespace) {
            return None;
        }
        let rest = rest.trim_start();
        let rest = rest.strip_prefix('v').unwrap_or(rest);
        let end = rest
            .find(|c: char| !(c.is_ascii_digit() || c == '.'))
            .unwrap_or(rest.len());
        let version = &rest[..end];
        let parts: Vec<&str> = version.split('.').collect();
        (parts.len() == 3
            && parts
                .iter()
                .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())))
        .then(|| version.to_string())
    })
}

pub struct ToolSkill(pub &'static ToolSkillSpec);

impl Step for ToolSkill {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: self.0.id,
            // herdr-app と herdr-core を入れる手順 (97) の後
            order: 98,
            title: self.0.title,
            // Linux の hc の skill は herdr-core を入れるホスト (dotfiles.herdrCore.enable) に張る
            gate: Gate::Tool("windowsHerdr"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let s = self.0;
        let official = join_segments(&ctx.roots.local_app_data, s.official);
        let exe = ctx
            .sys
            .which(s.program)
            .or_else(|| official.is_file().then(|| official.clone()));
        let Some(exe) = exe else {
            return vec![Outcome::new(
                Kind::Manual,
                format!(
                    "{} が見つからない (PATH と {}) → herdr-app の手順 (Install-HerdrApp.ps1) で入れる",
                    s.program,
                    official.display()
                ),
            )];
        };
        let head_path = ctx.repo_path(s.head);
        let head = match std::fs::read_to_string(&head_path) {
            Ok(t) => t.replace("\r\n", "\n"),
            Err(e) => {
                return vec![Outcome::new(
                    Kind::Failed,
                    format!("skill の頭が読めない ({}: {e})", head_path.display()),
                )];
            }
        };
        let r = ctx.sys.run(
            &CommandSpec::new(&exe)
                .arg("--version")
                .timeout(Duration::from_secs(30)),
            &mut |_| {},
        );
        let version = if r.code() == Some(0) {
            version_from_output(&r.output, s.program)
        } else {
            None
        };
        let Some(version) = version else {
            return vec![Outcome::new(
                Kind::Failed,
                format!(
                    "{} --version から版を読めない ({:?}: {})",
                    s.program,
                    r.exit,
                    r.output.join(" / ")
                ),
            )];
        };
        ctx.say(format!("{} {version} ({})", s.program, exe.display()));
        let mut seen = Vec::new();
        let r = ctx.sys.run(
            &CommandSpec::new(&exe)
                .arg("--skill")
                .stdout_only()
                .timeout(Duration::from_secs(60)),
            &mut |l| seen.push(l.to_string()),
        );
        if r.code() != Some(0) || r.output.iter().all(|l| l.trim().is_empty()) {
            let mut o = Outcome::new(
                Kind::Failed,
                format!(
                    "{} --skill が手引きを出さなかった ({:?})",
                    s.program, r.exit
                ),
            );
            for l in seen.iter().rev().take(5).rev() {
                o = o.note(l.clone());
            }
            return vec![o];
        }
        let dir = ctx
            .roots
            .user_profile
            .join(".claude")
            .join("skills")
            .join(s.dir);
        if is_link(&dir) {
            return vec![Outcome::new(
                Kind::Manual,
                format!(
                    "{} はリンク (claude-skills の skill と同じ名前?)。触らない",
                    dir.display()
                ),
            )];
        }
        let desired = format!(
            "{}{}\n",
            head.replace("@version@", &version),
            r.output.join("\n")
        );
        vec![generated::sync(
            ctx,
            mode,
            &dir.join("SKILL.md"),
            desired.as_bytes(),
            &format!("~/.claude/skills/{}/SKILL.md", s.dir),
        )]
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 版の読み方 (`hc 0.1.21`・`herdr-app v0.1.20 (abc)`。名前違い・版の形でないものは読まない)
    //! - 中身 = 頭の @version@ を版に替えたもの + `--skill` の stdout の行を LF でつないで末尾に改行 (stdout だけを取る口で打つ。頭の CRLF は LF に)
    //! - 無い → missing・手で置いた写し (違う) → fix で apply が書き直す・同じ → ok。置き先のディレクトリがリンク → manual
    //! - PATH に無ければ公式の置き場所を使う。どちらにも無い → manual。版が読めない・--skill が空 → failed
    //! - 本物の頭のファイル 2 つに name・description・@version@ がある

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, Exit, RunResult};
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    #[test]
    fn reads_versions() {
        let v = |lines: &[&str], name| {
            version_from_output(
                &lines.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
                name,
            )
        };
        assert_eq!(v(&["hc 0.1.21"], "hc").as_deref(), Some("0.1.21"));
        assert_eq!(
            v(&["  herdr-app v0.1.20 (abc123)"], "herdr-app").as_deref(),
            Some("0.1.20")
        );
        assert_eq!(
            v(&["warning", "hc 1.2.3\r"], "hc").as_deref(),
            Some("1.2.3")
        );
        assert_eq!(v(&["hcx 0.1.2"], "hc"), None);
        assert_eq!(v(&["hc 0.1"], "hc"), None);
        assert_eq!(v(&["hc 0.1.2.3"], "hc"), None);
        assert_eq!(v(&["herdr-core 0.1.21"], "hc"), None);
    }

    struct World {
        t: TempDir,
    }

    impl World {
        fn new() -> Self {
            let t = TempDir::new("tool-skill");
            t.write(
                "dotfiles/nix/pkgs/herdr-core/claude-skill-head.md",
                "---\r\nname: hc\r\n---\r\n\r\n<!-- hc @version@ -->\r\n",
            );
            World { t }
        }

        fn skill(&self) -> PathBuf {
            self.t
                .path()
                .join("home")
                .join(".claude")
                .join("skills")
                .join("hc")
                .join("SKILL.md")
        }

        fn official(&self) -> PathBuf {
            self.t
                .path()
                .join("home")
                .join("AppData")
                .join("Local")
                .join("Programs")
                .join("herdr-core")
                .join("hc.exe")
        }

        /// `--version` と `--skill` に答える偽物。`on_path` なら PATH に hc がある
        fn sys(&self, on_path: bool, version: &'static str, skill: Vec<&'static str>) -> FakeSys {
            let sys = FakeSys::new(move |c: &CommandSpec| match c.args_lossy().as_slice() {
                [a] if a == "--version" => RunResult {
                    exit: Exit::Code(0),
                    output: vec![version.to_string()],
                },
                [a] if a == "--skill" => {
                    assert!(c.stdout_only, "--skill は stdout だけを取る");
                    RunResult {
                        exit: Exit::Code(0),
                        output: skill.iter().map(|s| s.to_string()).collect(),
                    }
                }
                other => panic!("思わぬコマンド: {other:?}"),
            });
            if on_path {
                sys.with_program("hc", "hc-on-path")
            } else {
                sys
            }
        }

        fn run(&self, sys: &FakeSys, mode: Mode) -> Outcome {
            let mut out = Vec::new();
            let mut ctx = Ctx {
                repo: self.t.path().join("dotfiles"),
                roots: Roots::from_home(&self.t.path().join("home")),
                state_dir: self.t.path().join("state"),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys,
                out: &mut out,
            };
            ToolSkill(&SPECS[0]).run(&mut ctx, mode).remove(0)
        }
    }

    const WANT: &str = "---\nname: hc\n---\n\n<!-- hc 0.1.21 -->\n# hc manual\n\nbody\n";

    #[test]
    fn writes_head_and_skill_output() {
        let w = World::new();
        let sys = w.sys(true, "hc 0.1.21", vec!["# hc manual", "", "body"]);
        let o = w.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(!w.skill().exists());
        let o = w.run(&sys, Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert_eq!(std::fs::read_to_string(w.skill()).unwrap(), WANT);
        assert_eq!(sys.calls.borrow()[0].program, Path::new("hc-on-path"));
        assert_eq!(w.run(&sys, Mode::Check).kind, Kind::Ok);
    }

    #[test]
    fn rewrites_the_hand_placed_copy() {
        let w = World::new();
        w.t.write(
            "home/.claude/skills/hc/SKILL.md",
            "---\r\nname: hc\r\n---\r\n\r\n<!-- Temporary copy -->\n# hc manual\n\nbody\n",
        );
        let sys = w.sys(true, "hc 0.1.21", vec!["# hc manual", "", "body"]);
        assert_eq!(w.run(&sys, Mode::Check).kind, Kind::Fix);
        assert_eq!(w.run(&sys, Mode::Apply { force: false }).kind, Kind::Ok);
        assert_eq!(std::fs::read_to_string(w.skill()).unwrap(), WANT);
    }

    #[test]
    fn falls_back_to_the_official_place() {
        let w = World::new();
        std::fs::create_dir_all(w.official().parent().unwrap()).unwrap();
        std::fs::write(w.official(), "").unwrap();
        let sys = w.sys(false, "hc 0.1.21", vec!["# hc manual", "", "body"]);
        assert_eq!(w.run(&sys, Mode::Apply { force: false }).kind, Kind::Ok);
        assert_eq!(sys.calls.borrow()[0].program, w.official());

        let w = World::new();
        let sys = w.sys(false, "hc 0.1.21", vec![]);
        let o = w.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(sys.calls.borrow().is_empty());
    }

    #[test]
    fn failures_and_links() {
        let w = World::new();
        let o = w.run(&w.sys(true, "herdr-core ?", vec!["x"]), Mode::Check);
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        let o = w.run(&w.sys(true, "hc 0.1.21", vec![]), Mode::Check);
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("--skill"), "{o:?}");

        // 置き先のディレクトリがリンク (claude-skills の skill と同じ名前) なら触らない
        let w = World::new();
        let elsewhere = w.t.path().join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::fs::create_dir_all(w.skill().parent().unwrap().parent().unwrap()).unwrap();
        let mk = FakeSys::new(|c| crate::testutil::fake_mklink(c).unwrap());
        crate::link::create_junction(&mk, w.skill().parent().unwrap(), &elsewhere).unwrap();
        let o = w.run(
            &w.sys(true, "hc 0.1.21", vec!["x"]),
            Mode::Apply { force: false },
        );
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(!elsewhere.join("SKILL.md").exists());
    }

    #[test]
    fn real_heads_have_frontmatter() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        for spec in SPECS {
            let head =
                std::fs::read_to_string(crate::context::join_segments(&repo, spec.head)).unwrap();
            assert!(
                head.starts_with(&format!("---\nname: {}\ndescription: \"", spec.dir)),
                "{}",
                spec.head
            );
            assert!(head.contains("@version@"), "{}", spec.head);
            assert_eq!(head.matches("---\n").count(), 2, "{}", spec.head);
        }
    }
}
