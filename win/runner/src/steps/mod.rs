//! 手順の骨組みと一覧。
//!
//! 手順は trait `Step` を持つ型。`all()` が WSL の `# order:` と同じ順番に並べる (同じ数は WSL と同じく script の名前の辞書順)。
//! 手順を足すときは、この下に module を 1 つ書き、`all()` に 1 行足す (win/README.md の「runner の手順を足す」)。

pub mod bootstrap;
pub mod claude_accounts;
pub mod claude_env;
pub mod claude_files;
pub mod claude_footer_links;
pub mod claude_hook;
pub mod claude_notion;
pub mod claude_selector;
pub mod claude_settings;
pub mod claude_skill_overrides;
pub mod claude_skills;
pub mod claude_statusline;
pub mod claude_t3;
pub mod deploy;
pub mod fancyzones;
pub mod files;
pub mod generated;
pub mod git_config;
pub mod google_ime;
pub mod hc_hub;
pub mod herdr_app_keys;
pub mod herdr_app_mods;
pub mod herdr_app_pjp_spaces;
pub mod international;
pub mod linker;
pub mod local_env;
pub mod notion_tokens;
#[cfg(test)]
mod op_reason_parity;
pub mod pending;
pub mod pin_updates;
pub mod pjp;
pub mod port_forward;
pub mod powershell_profile;
pub mod powertoys;
pub mod ps1;
pub mod ssh_config;
pub mod sshd_allow;
pub mod sshd_keys;
pub mod starship_init;
pub mod t3_code_settings;
pub mod terminal;
pub mod tool_skill;
pub mod user_path;

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
    /// 道具の switch がどれも true のとき (Nix の表で効く条件 (requires) のある道具。先頭がその道具、後ろが Windows でも効く条件)
    AllTools(&'static [&'static str]),
}

/// 道具の switch が off ならそのわけ。
fn tool_off_reason(host: &HostValues, key: &str) -> Option<String> {
    if host.tool(key) {
        None
    } else {
        Some(format!(
            "このホストでは off ({key} = false。{})",
            host.tool_origin(key)
        ))
    }
}

impl Gate {
    /// on なら None、off ならわけ (締めの表に出す)。
    pub fn off_reason(&self, host: &HostValues) -> Option<String> {
        match self {
            Gate::Always => None,
            Gate::Tool(key) => tool_off_reason(host, key),
            Gate::AllTools(keys) => keys.iter().find_map(|key| tool_off_reason(host, key)),
        }
    }

    /// 一覧に出す on/off の決め方
    pub fn describe(&self) -> String {
        match self {
            Gate::Always => "いつも".to_string(),
            Gate::Tool(key) => key.to_string(),
            Gate::AllTools(keys) => keys.join("・"),
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
    /// 揃える。`force` は files などのコピーの衝突も上書きし (ssh-config・port-forward は元を退避してから。ssh-config は正本から消えたファイルも)、
    /// 足した後で消した `$PROFILE` の 1 行も足し直す (powershell-profile・starship-init)
    Apply { force: bool },
}

impl Mode {
    pub fn writes(self) -> bool {
        matches!(self, Mode::Apply { .. })
    }

    /// --force (files などのコピーの衝突も上書きする・消した `$PROFILE` の 1 行も足し直す・dry-run ならそう予告する)
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
    /// apply で、後ろの手順 `after` (id) が流れた直後に、この手順をもう一度流すか (`runner::execute` が、apply で流した手順に聞く)。
    /// 後ろの手順が、この手順の書いた中身の前提を変えたときに true を返す (git-config は、openssh が OpenSSH を入れて core.sshCommand に
    /// 書く ssh.exe が変わったとき)。既定は流し直さない
    fn rerun_after(&self, _ctx: &Ctx, _after: &str) -> bool {
        false
    }
}

/// 手順に渡す引数 (手順が 1 つだけで使うもの)。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Options {
    /// google-ime の辞書の衝突で、語の diff も出す (`--show-words`)
    pub show_words: bool,
}

/// 手順の一覧 (順番どおり)。
pub fn all() -> Vec<Box<dyn Step>> {
    all_with(Options::default())
}

/// 手順の一覧 (順番どおり。`options` を手順に渡す)。
pub fn all_with(options: Options) -> Vec<Box<dyn Step>> {
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
        // T3 Code の会話だけの Claude の設定 (T3 の Launch arguments が読むファイル) を ~/.claude/t3/ へ置く (Windows にしか無い手順。
        // dotfiles-private の docs/adr/090_win_claude_t3_launch_args_*)
        Box::new(claude_t3::ClaudeT3),
        // git の設定を WSL の home-manager と同じ git.toml から置く (Windows にしか無い手順。dotfiles-private の docs/adr/066_win_git_config_*)
        Box::new(git_config::GitConfig),
        // マシンローカルの環境変数のファイル (~/.config/pjp/env) の頭の欄を、Linux の bootstrap-local-env と同じ印と規則で書き直す (Windows に
        // しか無い手順。dotfiles-private の docs/adr/105_win_local_env_*)
        Box::new(local_env::LocalEnv),
        // Notion の API キーの宣言 ([claude.notion.tokens]) を notion-tokens.json に書き、~/.config/pjp/env の行と ACL を値を出さずに確かめる (Linux の
        // home/modules/claude.nix と bootstrap-notion-tokens.sh を写した、Windows にしか無い手順。dotfiles-private の docs/adr/114_win_notion_api_token_*)
        Box::new(notion_tokens::NotionTokens),
        // dotfiles の herdr-app の mod を herdr-app の home の mods\ へ置く (Windows にしか無い手順。dotfiles-private の
        // docs/adr/068_win_herdr_app_mods_*)
        Box::new(herdr_app_mods::HerdrAppMods),
        // claude-skills の herdr-app の mod pjp-spaces を置き、main を写した layout pjp-main の spaces を pjp-spaces に替え、sidebar の
        // Spaces と Agents を dotfiles の mod pjp-sidebar-tabs のタブで切り替える形にする (Windows にしか無い手順。dotfiles-private の
        // docs/adr/072_win_herdr_app_pjp_spaces_*・106_win_herdr_app_sidebar_tabs_*)
        Box::new(herdr_app_pjp_spaces::HerdrAppPjpSpaces),
        // dotfiles の herdr-app のキーを herdr-app の home の keys.json に書き足す (Windows にしか無い手順。dotfiles-private の
        // docs/adr/070_win_herdr_app_keys_*)
        Box::new(herdr_app_keys::HerdrAppKeys),
        // Windows の claude-personal・claude-work の ~/.claude-<名前> と launcher (Windows にしか無い手順。dotfiles-private の
        // docs/adr/081_win_claude_accounts_*)
        Box::new(claude_accounts::ClaudeAccounts),
        // claude-selector (cs) を Linux と同じ crate から作って claude-<名前> と同じ置き場に置く (Windows にしか無い手順。
        // dotfiles-private の docs/adr/087_claude_selector_*)
        Box::new(claude_selector::ClaudeSelector),
        Box::new(files::Files),
        // $PROFILE に starship の init の 1 行を、dotfiles.ps1 を読む行より前に足す (Windows にしか無い手順。starship を入れるのは ps1 の手順
        // starship。dotfiles-private の docs/superpowers/specs/2026-11-25-win-starship-install-design.md)
        Box::new(starship_init::StarshipInit),
        // WSL の setup の手順を写したもの (受け持ちを runner に切り替えたホストでだけ apply が書く。移す順と移し方は dotfiles-private の
        // docs/adr/060_win_runner_core_* の §2 A)
        Box::new(powershell_profile::PowershellProfile),
        Box::new(powertoys::PowerToys),
        Box::new(fancyzones::FancyZones),
        Box::new(ssh_config::SshConfig),
        Box::new(port_forward::PortForward),
        Box::new(terminal::Terminal),
        Box::new(international::International),
        Box::new(google_ime::GoogleIme {
            show_words: options.show_words,
        }),
        Box::new(pin_updates::PinUpdates),
        // T3 Code のテレメトリの環境変数と settings.json (Windows にしか無い手順。T3 Code を入れるのは ps1 の手順 t3-code。dotfiles-private の
        // docs/adr/091_t3_code_opt_in_*)
        Box::new(t3_code_settings::T3CodeSettings),
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
    //! - WSL の script に `# tool:` があれば、写した手順もまだ無い手順も gate がその道具の switch (まだ無い手順は、行が無ければいつも)
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
                (50, "claude-t3"),
                (50, "git-config"),
                (50, "local-env"),
                (55, "notion-tokens"),
                (55, "pjp"),
                (60, "claude-skill-overrides"),
                (60, "hc-hub"),
                (90, "files"),
                (90, "op-reason"),
                (91, "powertoys"),
                (91, "ssh-config"),
                (92, "fancyzones"),
                (94, "starship-init"),
                (95, "google-ime-install"),
                (95, "powershell-profile"),
                (96, "openssh"),
                (96, "sshd"),
                (96, "tailscale"),
                (97, "claude-code"),
                (97, "claude-desktop"),
                (97, "fzf"),
                (97, "ghq"),
                (97, "herdr-app"),
                (97, "herdr"),
                (97, "ntn"),
                (97, "pin-updates"),
                (97, "starship"),
                (97, "t3-code"),
                (97, "type-clipboard"),
                (98, "google-ime"),
                (98, "hc-skill"),
                (98, "herdr-app-mods"),
                (98, "herdr-app-pjp-spaces"),
                (98, "herdr-app-skill"),
                (98, "t3-code-settings"),
                (99, "claude-accounts"),
                (99, "claude-selector"),
                (99, "herdr-app-keys"),
                (99, "international"),
                (99, "port-forward"),
                (99, "terminal"),
            ]
        );
    }

    #[test]
    fn wsl_scripts_exist_for_every_windows_step() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        // WSL から写した手順 (files・ps1・powershell-profile など) と、まだ無い手順には、同じ名前の WSL の script がある。bootstrap と、
        // W0-2 などで足す Windows にしか無い手順は WSL の script を持たないので見ない
        let from_wsl: Vec<&str> = all()
            .iter()
            .map(|s| s.info())
            .filter(|i| !i.windows_only)
            .map(|i| i.id)
            .collect();
        assert!(from_wsl.contains(&"files") && from_wsl.contains(&"powershell-profile"));
        assert!(from_wsl.contains(&"ssh-config") && from_wsl.contains(&"port-forward"));
        assert!(from_wsl.contains(&"terminal") && from_wsl.contains(&"powertoys"));
        assert!(from_wsl.contains(&"fancyzones") && from_wsl.contains(&"international"));
        assert!(from_wsl.contains(&"google-ime") && from_wsl.contains(&"pin-updates"));
        for id in from_wsl {
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

    /// Windows にしか無い手順は bootstrap と W0-2 の手順と Claude Code の設定の手順 (T3 Code の会話だけの設定も) と git の設定とマシンローカルの
    /// 環境変数のファイル (local-env) と Notion の API キーの宣言と知らせ (notion-tokens) と herdr-app の mod
    /// (pjp-spaces と layout も) とキーと claude-personal・claude-work と claude-selector と T3 Code (入れる ps1 の手順と設定) と ghq・fzf (cdrepo が
    /// 使う。入れる ps1 の手順) と Claude Desktop (入れる ps1 の手順) と starship (入れる ps1 の手順と、$PROFILE の init の 1 行の starship-init) だけ
    /// (WSL から写した手順・まだ無い手順は受け持ちに従う)
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
                "claude-t3",
                "git-config",
                "local-env",
                "notion-tokens",
                "pjp",
                "claude-skill-overrides",
                "hc-hub",
                "starship-init",
                "claude-desktop",
                "fzf",
                "ghq",
                "starship",
                "t3-code",
                "hc-skill",
                "herdr-app-mods",
                "herdr-app-pjp-spaces",
                "herdr-app-skill",
                "t3-code-settings",
                "claude-accounts",
                "claude-selector",
                "herdr-app-keys",
            ]
        );
        for s in all() {
            assert!(s.info().ported || !s.info().windows_only, "{}", s.info().id);
        }
    }

    /// WSL の script に `# tool:` (setup.sh が読む道具の switch) があれば、写した手順もまだ無い手順も、gate の頭がその道具 (op-reason の
    /// onePassword・herdr の windowsHerdr など)。行が無いまだ無い手順はいつも on (移した手順は windows-files.json の欄に当たる switch でもよい)
    #[test]
    fn gates_follow_wsl_tool_lines() {
        let scripts = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("nix")
            .join("scripts");
        let mut tooled = Vec::new();
        for info in all().iter().map(|s| s.info()).filter(|i| !i.windows_only) {
            let path = scripts.join(format!("bootstrap-windows-{}.sh", info.id));
            let text = std::fs::read_to_string(&path).unwrap();
            // 「# tool: onePassword (dotfiles.onePassword.enable)」の道具の名前
            let tool = text
                .lines()
                .find_map(|l| l.strip_prefix("# tool: "))
                .and_then(|t| t.split_whitespace().next());
            match (tool, info.gate) {
                (Some(t), Gate::Tool(key)) => {
                    assert_eq!(key, t, "{} の # tool: と gate が違う", path.display());
                    tooled.push(info.id);
                }
                (Some(t), Gate::AllTools(keys)) => {
                    assert_eq!(keys[0], t, "{} の # tool: と gate が違う", path.display());
                    tooled.push(info.id);
                }
                (Some(_), gate) => {
                    panic!("{}: # tool: があるのに gate が {gate:?}", path.display())
                }
                (None, gate) if !info.ported => assert_eq!(
                    gate,
                    Gate::Always,
                    "{}: まだ無い手順は WSL の # tool: で決める",
                    info.id
                ),
                (None, _) => {}
            }
        }
        assert_eq!(
            tooled,
            vec!["op-reason", "sshd", "tailscale", "herdr-app", "herdr"]
        );
    }

    #[test]
    fn gates() {
        let h = parse(
            "group = \"minimum\"\n[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\n",
            Path::new("h.toml"),
            Groups::embedded().unwrap(),
        )
        .unwrap();
        assert_eq!(Gate::Always.off_reason(&h), None);
        assert_eq!(Gate::Tool("windowsHerdr").off_reason(&h), None);
        assert_eq!(
            Gate::Tool("windowsNtn").off_reason(&h).unwrap(),
            "このホストでは off (windowsNtn = false。グループ minimum の既定)"
        );
        // 効く条件のある道具: どれも true のときだけ on。off のわけは最初の false の道具
        assert_eq!(
            Gate::AllTools(&["windowsHerdr", "windowsNtn"])
                .off_reason(&h)
                .unwrap(),
            "このホストでは off (windowsNtn = false。グループ minimum の既定)"
        );
        assert_eq!(
            Gate::AllTools(&["windowsClaudeCode", "windowsHerdr"]).off_reason(&h),
            None
        );
        assert_eq!(
            Gate::AllTools(&["windowsClaudeAccounts", "windowsClaudeCode"]).describe(),
            "windowsClaudeAccounts・windowsClaudeCode"
        );
    }

    /// private な repo (dotfiles-private) か gh のログインを読む手順 (ssh-config・port-forward・pin-updates) は privateRepos で on/off。bootstrap は
    /// いつも on (privateRepos のホストは -Private で確かめる)。google-ime はいつも on (辞書だけを privateRepos で扱う)
    #[test]
    fn private_repos_gates() {
        let parse_host =
            |text: &str| parse(text, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap();
        let minimum = parse_host("group = \"minimum\"\n");
        let private = parse_host("[tools]\nprivateRepos = true\n");
        let gate_of = |id: &str| {
            all()
                .into_iter()
                .find(|s| s.info().id == id)
                .unwrap()
                .info()
                .gate
        };
        for id in ["ssh-config", "port-forward", "pin-updates"] {
            assert_eq!(gate_of(id), Gate::Tool("privateRepos"), "{id}");
            assert_eq!(
                gate_of(id).off_reason(&minimum).unwrap(),
                "このホストでは off (privateRepos = false。グループ minimum の既定)",
                "{id}"
            );
            assert_eq!(gate_of(id).off_reason(&private), None, "{id}");
        }
        for id in ["bootstrap", "google-ime"] {
            assert_eq!(gate_of(id), Gate::Always, "{id}");
        }
    }
}
