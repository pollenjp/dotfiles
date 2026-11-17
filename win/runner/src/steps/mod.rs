//! 手順の骨組みと一覧。
//!
//! 手順は trait `Step` を持つ型。`all()` が WSL の `# order:` と同じ順番に並べる (同じ数は WSL と同じく script の名前の辞書順)。
//! 手順を足すときは、この下に module を 1 つ書き、`all()` に 1 行足す (win/README.md の「runner の手順を足す」)。

pub mod bootstrap;
pub mod claude_env;
pub mod claude_files;
pub mod claude_footer_links;
pub mod claude_hook;
pub mod claude_notion;
pub mod claude_settings;
pub mod claude_skill_overrides;
pub mod claude_skills;
pub mod claude_statusline;
pub mod files;
pub mod generated;
pub mod git_config;
pub mod hc_hub;
pub mod herdr_app_mods;
pub mod linker;
pub mod pending;
pub mod pjp;
pub mod ps1;
pub mod tool_skill;

use crate::context::Ctx;
use crate::host::HostValues;
use crate::report::Kind;

/// その手順がこのホストで on かの決め方。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gate {
    /// いつも on
    Always,
    /// 道具の switch (`groups.json` の tools の名前) が true のとき
    Tool(&'static str),
    /// 設定グループがこのどれかのとき
    Groups(&'static [&'static str]),
}

impl Gate {
    /// on なら None、off ならわけ (締めの表に出す)。
    pub fn off_reason(&self, host: &HostValues) -> Option<String> {
        match self {
            Gate::Always => None,
            Gate::Tool(key) => {
                if host.tool(key) {
                    None
                } else {
                    Some(format!(
                        "このホストでは off ({key} = false。{})",
                        host.tool_origin(key)
                    ))
                }
            }
            Gate::Groups(groups) => {
                if groups.contains(&host.group.as_str()) {
                    None
                } else {
                    Some(format!(
                        "このホストでは off (グループ {}。この手順は {} だけ)",
                        host.group,
                        groups.join("・")
                    ))
                }
            }
        }
    }

    /// 一覧に出す on/off の決め方
    pub fn describe(&self) -> String {
        match self {
            Gate::Always => "いつも".to_string(),
            Gate::Tool(key) => key.to_string(),
            Gate::Groups(groups) => format!("グループ {}", groups.join("・")),
        }
    }
}

/// 手順の名札。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StepInfo {
    /// `--steps` に渡す名前
    pub id: &'static str,
    /// 順番 (WSL の `# order:` と同じ数)
    pub order: u16,
    pub title: &'static str,
    pub gate: Gate,
    /// runner に移したか (false は WSL にしか無い手順)
    pub ported: bool,
    /// Windows にしか無い手順か (WSL の setup に同じ手順が無い。bootstrap の確かめ・W0-2)。受け持ちによらず runner が受け持ち、
    /// 受け持ちが WSL のホストの apply でも流す。false は WSL の `bootstrap-windows-*.sh` を写した手順とまだ無い手順で、受け持ちを
    /// runner に切り替えたホストでだけ apply が書く (dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*)
    pub windows_only: bool,
}

/// 流し方。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// 確かめるだけ (何も書かない)
    Check,
    /// apply がすることを出すだけ (何も書かない)。`force` は apply の --force のときと同じ予告を出す
    DryRun { force: bool },
    /// 揃える。`force` は files の衝突も上書きする
    Apply { force: bool },
}

impl Mode {
    pub fn writes(self) -> bool {
        matches!(self, Mode::Apply { .. })
    }

    /// --force (files の衝突も上書きする・dry-run ならそう予告する)
    pub fn force(self) -> bool {
        matches!(
            self,
            Mode::DryRun { force: true } | Mode::Apply { force: true }
        )
    }
}

/// 手順の結果 (締めの表の 1 行の中身)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outcome {
    pub kind: Kind,
    pub text: String,
    pub notes: Vec<String>,
}

impl Outcome {
    pub fn new(kind: Kind, text: impl Into<String>) -> Self {
        Outcome {
            kind,
            text: text.into(),
            notes: Vec::new(),
        }
    }

    pub fn note(mut self, n: impl Into<String>) -> Self {
        self.notes.push(n.into());
        self
    }
}

pub trait Step {
    fn info(&self) -> StepInfo;
    /// 手順を流す。出力は `ctx.say`、結果は締めの表の行 (ふつうは 1 つ)。
    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome>;
}

/// 手順の一覧 (順番どおり)。
pub fn all() -> Vec<Box<dyn Step>> {
    let mut steps: Vec<Box<dyn Step>> = vec![
        Box::new(bootstrap::Bootstrap),
        // W0-2 の Windows の側 (Windows にしか無い手順。dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*)
        Box::new(claude_env::ClaudeEnv),
        Box::new(claude_notion::ClaudeNotion),
        Box::new(claude_skills::ClaudeSkills),
        Box::new(pjp::Pjp),
        Box::new(hc_hub::HcHub),
        // Windows の Claude Code に dotfiles の設定を配る (Windows にしか無い手順。dotfiles-private の docs/adr/065_win_claude_config_*)
        Box::new(claude_files::ClaudeFiles),
        Box::new(claude_hook::ClaudeHook),
        Box::new(claude_statusline::ClaudeStatusline),
        Box::new(claude_footer_links::ClaudeFooterLinks),
        Box::new(claude_skill_overrides::ClaudeSkillOverrides),
        // git の設定を WSL の home-manager と同じ git.toml から置く (Windows にしか無い手順。dotfiles-private の docs/adr/066_win_git_config_*)
        Box::new(git_config::GitConfig),
        // dotfiles の herdr-app の mod を herdr-app の home の mods\ へ置く (Windows にしか無い手順。dotfiles-private の
        // docs/adr/068_win_herdr_app_mods_*)
        Box::new(herdr_app_mods::HerdrAppMods),
        Box::new(files::Files),
    ];
    for spec in tool_skill::SPECS {
        steps.push(Box::new(tool_skill::ToolSkill(spec)));
    }
    for spec in ps1::SPECS {
        steps.push(Box::new(ps1::Ps1Step(spec)));
    }
    for p in pending::PENDING {
        steps.push(Box::new(pending::Pending(p)));
    }
    // 同じ order は WSL と同じく script の名前 (bootstrap-windows-<id>.sh) の辞書順。id だけで比べると herdr が herdr-app より先に
    // なるが、script の名前では herdr-app.sh が先 ('-' が '.' より前)
    steps.sort_by_key(|s| (s.info().order, format!("{}.sh", s.info().id)));
    steps
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 一覧の順番が WSL の setup と同じ (order・同じ order は script の名前の辞書順)・id が重ならない
    //! - 移した手順と、まだ無い手順の id が WSL の bootstrap-windows-*.sh の名前と同じ
    //! - まだ無い手順の on/off が、WSL の script の `# tool:` と同じ道具の switch (行が無ければいつも)
    //! - on/off の決め方 (道具の switch・グループ)

    use super::*;
    use crate::host::{Groups, parse};
    use std::path::Path;

    #[test]
    fn order_matches_wsl_setup() {
        let ids: Vec<(u16, &str)> = all()
            .iter()
            .map(|s| (s.info().order, s.info().id))
            .collect();
        assert_eq!(
            ids,
            vec![
                (5, "bootstrap"),
                (50, "claude-env"),
                (50, "claude-files"),
                (50, "claude-footer-links"),
                (50, "claude-hook"),
                (50, "claude-notion"),
                (50, "claude-skills"),
                (50, "claude-statusline"),
                (50, "git-config"),
                (55, "pjp"),
                (60, "claude-skill-overrides"),
                (60, "hc-hub"),
                (90, "files"),
                (91, "powertoys"),
                (91, "ssh-config"),
                (92, "fancyzones"),
                (95, "google-ime-install"),
                (95, "powershell-profile"),
                (96, "openssh"),
                (97, "claude-code"),
                (97, "herdr-app"),
                (97, "herdr"),
                (97, "ntn"),
                (97, "op-reason"),
                (97, "pin-updates"),
                (97, "type-clipboard"),
                (98, "google-ime"),
                (98, "hc-skill"),
                (98, "herdr-app-mods"),
                (98, "herdr-app-skill"),
                (99, "international"),
                (99, "port-forward"),
                (99, "terminal"),
            ]
        );
    }

    #[test]
    fn wsl_scripts_exist_for_every_windows_step() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        // WSL から写した手順 (files・ps1) と、まだ無い手順には、同じ名前の WSL の script がある。bootstrap と、W0-2 などで足す
        // Windows にしか無い手順は WSL の script を持たないので見ない
        let ported_from_wsl = std::iter::once("files")
            .chain(ps1::SPECS.iter().map(|s| s.id))
            .chain(pending::PENDING.iter().map(|p| p.id));
        for id in ported_from_wsl {
            let script = repo
                .join("nix")
                .join("scripts")
                .join(format!("bootstrap-windows-{id}.sh"));
            assert!(script.is_file(), "{} が無い", script.display());
        }
        // WSL の Windows の手順は全部、一覧にある (移したか、まだ無いかのどちらか)
        let ids: Vec<&str> = all().iter().map(|s| s.info().id).collect();
        for entry in std::fs::read_dir(repo.join("nix").join("scripts")).unwrap() {
            let name = entry.unwrap().file_name().to_string_lossy().into_owned();
            if let Some(id) = name
                .strip_prefix("bootstrap-windows-")
                .and_then(|n| n.strip_suffix(".sh"))
            {
                assert!(ids.contains(&id), "{name} が一覧に無い");
            }
        }
    }

    /// Windows にしか無い手順は bootstrap と W0-2 の手順と Claude Code の設定の手順と git の設定と herdr-app の mod だけ (WSL から写した手順・まだ無い
    /// 手順は受け持ちに従う)
    #[test]
    fn windows_only_steps() {
        let only: Vec<&str> = all()
            .iter()
            .filter(|s| s.info().windows_only)
            .map(|s| s.info().id)
            .collect();
        assert_eq!(
            only,
            vec![
                "bootstrap",
                "claude-env",
                "claude-files",
                "claude-footer-links",
                "claude-hook",
                "claude-notion",
                "claude-skills",
                "claude-statusline",
                "git-config",
                "pjp",
                "claude-skill-overrides",
                "hc-hub",
                "hc-skill",
                "herdr-app-mods",
                "herdr-app-skill",
            ]
        );
        for s in all() {
            assert!(s.info().ported || !s.info().windows_only, "{}", s.info().id);
        }
    }

    #[test]
    fn pending_gates_follow_wsl_tool_lines() {
        let scripts = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("nix")
            .join("scripts");
        for p in pending::PENDING {
            let path = scripts.join(format!("bootstrap-windows-{}.sh", p.id));
            let text = std::fs::read_to_string(&path).unwrap();
            // 「# tool: onePassword (dotfiles.onePassword.enable)」の道具の名前 (setup.sh が読む行)
            let tool = text
                .lines()
                .find_map(|l| l.strip_prefix("# tool: "))
                .and_then(|t| t.split_whitespace().next());
            match p.gate {
                Gate::Always => {
                    assert_eq!(tool, None, "{} の # tool: が gate に無い", path.display())
                }
                Gate::Tool(key) => assert_eq!(
                    tool,
                    Some(key),
                    "{} の # tool: と gate が違う",
                    path.display()
                ),
                Gate::Groups(_) => panic!("{}: まだ無い手順は WSL の # tool: で決める", p.id),
            }
        }
    }

    #[test]
    fn gates() {
        let h = parse(
            "group = \"company\"",
            Path::new("h.toml"),
            Groups::embedded().unwrap(),
        )
        .unwrap();
        assert_eq!(Gate::Always.off_reason(&h), None);
        assert_eq!(Gate::Tool("windowsHerdr").off_reason(&h), None);
        assert_eq!(
            Gate::Tool("windowsNtn").off_reason(&h).unwrap(),
            "このホストでは off (windowsNtn = false。グループ company の既定)"
        );
        assert_eq!(
            Gate::Groups(&["personal"]).off_reason(&h).unwrap(),
            "このホストでは off (グループ company。この手順は personal だけ)"
        );
    }
}
