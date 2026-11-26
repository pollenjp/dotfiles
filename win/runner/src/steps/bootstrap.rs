//! bootstrap (order 5): `win/bootstrap/Install-Bootstrap.ps1 -Check` を流し、runner の前提 (Git for Windows・gh・Build Tools・rustup・
//! gh のログイン・3 つの clone・Smart App Control) を runner の出力にも出す (dotfiles-private の docs/adr/058_win_runner_bootstrap_* §2 H)。
//!
//! 確かめるだけ。apply でも bootstrap は流さない (UAC と gh のログインを runner の中で待たない。揃えるのは人が bootstrap を流す)。
//! on は claudePrivateSkills のホストだけ。bootstrap の対象と同じで、個人の gh のアカウントでログインして private な repo
//! (dotfiles-private・claude-skills) を取ってよいホスト = グループ all の既定と、claude-skills を `[tools]` に書いた minimum のホスト
//! (win/README.md の「bootstrap (新しい Windows で最初に流す)」・dotfiles-private の docs/adr/094_win_bootstrap_private_skills_hosts_*)。
//! SAC は bootstrap の行で見せ、runner で重ねて読まない (オンなら runner の exe はそもそも動かない)。

use super::ps1::{find_powershell, powershell_command, run_streaming};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::process::Exit;
use crate::report::Kind;
use std::time::Duration;

pub const SCRIPT: &str = "win/bootstrap/Install-Bootstrap.ps1";
/// 状態の表の見出し (bootstrap の行の形は「<題> : <文>」)
const HEADER: &str = "Git for Windows : ";
const CHECK_SECS: u64 = 120;

pub struct Bootstrap;

impl Step for Bootstrap {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "bootstrap",
            order: 5,
            title: "bootstrap の道具と clone を確かめる (Install-Bootstrap.ps1 -Check。揃えるのは人)",
            gate: Gate::Tool("claudePrivateSkills"),
            ported: true,
            // 確かめるだけで書かない。WSL の setup に同じ手順は無い
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, _mode: Mode) -> Vec<Outcome> {
        let script = ctx.repo_path(SCRIPT);
        if !script.is_file() {
            return vec![Outcome::new(
                Kind::Failed,
                format!("{SCRIPT} が clone に無い"),
            )];
        }
        let rerun = format!(
            "揃えるには、普通の (管理者でない) PowerShell で: powershell -NoProfile -ExecutionPolicy Bypass -File '{}'",
            super::ps1::ps_quote(&script.to_string_lossy())
        );
        let Some(shell) = find_powershell(ctx) else {
            return vec![Outcome::new(
                Kind::Failed,
                "PowerShell が見つからない (pwsh・powershell)",
            )];
        };
        let spec = powershell_command(
            shell,
            &script.to_string_lossy(),
            " -Check",
            Duration::from_secs(CHECK_SECS),
        );
        let r = run_streaming(ctx, &spec);
        let header = r.output.iter().any(|l| l.contains(HEADER));
        match (&r.exit, header) {
            (Exit::Code(0), _) => vec![Outcome::new(Kind::Ok, "揃っている")],
            (Exit::Code(1 | 3), true) => vec![
                Outcome::new(Kind::Manual, "bootstrap の差がある → Install-Bootstrap.ps1 を引数なしで流す (runner は流さない)")
                    .note(rerun),
            ],
            (Exit::TimedOut, _) => vec![Outcome::new(
                Kind::Failed,
                format!("Install-Bootstrap.ps1 -Check が {CHECK_SECS} 秒たっても終わらなかった"),
            )],
            (exit, _) => vec![Outcome::new(
                Kind::Failed,
                format!("Install-Bootstrap.ps1 -Check で確かめられなかった ({exit:?})"),
            )],
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - -Check だけを打ち (apply でも)、0 は揃っている、1・3 は人が bootstrap を流す差、見出しが無い・2 は確かめられなかった
    //! - claudePrivateSkills のホストだけ on (all の既定と、[tools] に書いた minimum。ホストの値が無いときは minimum の既定で off)

    use super::*;
    use crate::host::{Groups, HostValues, parse};
    use crate::manifest::Roots;
    use crate::process::RunResult;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    fn run(code: i32, lines: &[&str], mode: Mode) -> (Vec<Outcome>, Vec<String>) {
        let t = TempDir::new("bootstrap");
        t.write(SCRIPT, "# ps1\n");
        let lines: Vec<String> = lines.iter().map(|s| s.to_string()).collect();
        let sys = FakeSys::new(move |_| RunResult {
            exit: Exit::Code(code),
            output: lines.clone(),
        })
        .with_program("pwsh", "pwsh");
        let mut out = Vec::new();
        let o = {
            let mut ctx = Ctx {
                repo: t.path().to_path_buf(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: t.path().join("s"),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys: &sys,
                out: &mut out,
            };
            Bootstrap.run(&mut ctx, mode)
        };
        (o, sys.call_args())
    }

    #[test]
    fn only_checks() {
        let (o, calls) = run(
            0,
            &["  Git for Windows : 2.56.0.4"],
            Mode::Apply { force: false },
        );
        assert_eq!(o[0].kind, Kind::Ok);
        assert_eq!(calls.len(), 1);
        assert!(calls[0].contains("Install-Bootstrap.ps1' -Check;"));
    }

    #[test]
    fn differences_are_manual() {
        for code in [1, 3] {
            let (o, _) = run(
                code,
                &["⚠ Git for Windows : 入っていない → 2.56.0.4 を入れる"],
                Mode::Check,
            );
            assert_eq!(o[0].kind, Kind::Manual);
            assert!(o[0].notes[0].contains("Install-Bootstrap.ps1"));
        }
    }

    #[test]
    fn failures() {
        let (o, _) = run(1, &["何か"], Mode::Check);
        assert_eq!(o[0].kind, Kind::Failed);
        let (o, _) = run(2, &["  Git for Windows : x"], Mode::Check);
        assert_eq!(o[0].kind, Kind::Failed);
    }

    #[test]
    fn on_where_claude_skills_are_used() {
        let g = Groups::embedded().unwrap();
        let off_reason = |toml: &str| {
            let host = parse(toml, Path::new("h"), g.clone()).unwrap();
            Bootstrap.info().gate.off_reason(&host)
        };
        assert_eq!(Bootstrap.info().gate, Gate::Tool("claudePrivateSkills"));
        // all は既定で on (グループ all の既定の claudePrivateSkills が true)
        assert_eq!(off_reason("group = \"all\""), None);
        // 道具を足していない minimum (書かないホストも) は off
        assert_eq!(
            off_reason("group = \"minimum\"").unwrap(),
            "このホストでは off (claudePrivateSkills = false。グループ minimum の既定)"
        );
        assert!(off_reason("").is_some());
        // claude-skills を足して使う minimum のホストは on
        assert_eq!(
            off_reason(
                "group = \"minimum\"\n[tools]\nclaudePrivateSkills = true\nprivateRepos = true"
            ),
            None
        );
        // all でも claude-skills を外したホストは off
        assert!(off_reason("group = \"all\"\n[tools]\nclaudePrivateSkills = false").is_some());
    }

    /// ホストの値が無いとき (check はグループ minimum の既定で確かめる) は off
    #[test]
    fn off_without_host_values() {
        let host = HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap());
        assert!(Bootstrap.info().gate.off_reason(&host).is_some());
    }
}
