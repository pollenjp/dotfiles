//! bootstrap (order 5): `win/bootstrap/Install-Bootstrap.ps1 -Check` を流し、runner の前提 (Git for Windows・PowerShell 7・clone・
//! Smart App Control と、`-Private` の形では gh とそのログイン・Build Tools・rustup) を runner の出力にも出す (dotfiles-private の
//! docs/adr/058_win_runner_bootstrap_* §2 H)。
//!
//! 確かめるだけ。apply でも bootstrap は流さない (UAC と gh のログインを runner の中で待たない。揃えるのは人が bootstrap を流す)。
//! どのホストでも on。道具の switch `privateRepos` (pollenjp の private な repo と gh のログインを使うホスト) が on なら `-Private` を付けて、
//! gh とそのログイン・dotfiles-private・claude-skills の clone と、Build Tools・rustup (claude-skills の道具を cargo で作る) も確かめる。
//! off なら gh を使わない既定の形 (public な dotfiles の clone と、手元のホストの値 `%USERPROFILE%\.config\dotfiles\host.toml`。Build Tools と
//! rustup は見ない: runner は配った exe で動けるので、`-Rust` は付けない) を確かめる (win/README.md の
//! 「bootstrap (新しい Windows で最初に流す)」・dotfiles-private の docs/adr/111_win_runner_without_gh_*・docs/adr/117_win_runner_exe_release_*。
//! 前は claudePrivateSkills のホストだけ on だった: ADR 094)。
//! SAC は bootstrap の行で見せ、runner で重ねて読まない (オンなら runner の exe はそもそも動かない)。

use super::ps1::{find_powershell, powershell_command, run_streaming};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::host::PRIVATE_REPOS;
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
            title: "bootstrap の道具と clone を確かめる (Install-Bootstrap.ps1 -Check。privateRepos のホストは -Private も。揃えるのは人)",
            gate: Gate::Always,
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
        // private な repo と gh を使うホストは -Private の形 (gh とそのログイン・3 つの clone) を確かめる
        let private = if ctx.host.tool(PRIVATE_REPOS) {
            " -Private"
        } else {
            ""
        };
        let rerun = format!(
            "揃えるには、普通の (管理者でない) PowerShell で: powershell -NoProfile -ExecutionPolicy Bypass -File '{}'{private}",
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
            &format!(" -Check{private}"),
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
    //! - どのホストでも on (ホストの値が無いときも)。privateRepos のホスト (all の既定と、[tools] に書いた minimum) は -Check -Private を打ち、
    //!   ※ の流し直しのコマンドにも -Private を付ける。ほかは -Check だけ

    use super::*;
    use crate::host::{Groups, HostValues, parse};
    use crate::manifest::Roots;
    use crate::process::RunResult;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    fn run(code: i32, lines: &[&str], mode: Mode) -> (Vec<Outcome>, Vec<String>) {
        run_on(
            HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
            code,
            lines,
            mode,
        )
    }

    fn run_on(
        host: HostValues,
        code: i32,
        lines: &[&str],
        mode: Mode,
    ) -> (Vec<Outcome>, Vec<String>) {
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
                host,
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

    /// どのホストでも on。privateRepos のホストは -Check -Private を打ち、流し直しのコマンドにも -Private を付ける
    #[test]
    fn always_on_and_passes_private_only_for_private_repos_hosts() {
        let g = Groups::embedded().unwrap();
        let host = |toml: &str| parse(toml, Path::new("h"), g.clone()).unwrap();
        assert_eq!(Bootstrap.info().gate, Gate::Always);
        for toml in ["", "group = \"minimum\"", "group = \"all\""] {
            assert_eq!(
                Bootstrap.info().gate.off_reason(&host(toml)),
                None,
                "{toml}"
            );
        }
        let missing = HostValues::missing(Path::new("h.toml"), g.clone());
        assert_eq!(Bootstrap.info().gate.off_reason(&missing), None);
        let gap = ["⚠ Git for Windows : 入っていない → 2.56.0.4 を入れる"];
        // privateRepos のホスト (all の既定・[tools] に書いた minimum) は -Private の形を確かめる
        for toml in ["group = \"all\"", "[tools]\nprivateRepos = true"] {
            let (o, calls) = run_on(host(toml), 3, &gap, Mode::Check);
            assert_eq!(calls.len(), 1);
            assert!(
                calls[0].contains("Install-Bootstrap.ps1' -Check -Private;"),
                "{toml}: {}",
                calls[0]
            );
            assert!(
                o[0].notes[0].ends_with("Install-Bootstrap.ps1' -Private"),
                "{:?}",
                o[0].notes
            );
        }
        // ほか (道具を足していない minimum・ホストの値が無い) は gh を使わない既定の形
        for h in [host("group = \"minimum\""), missing] {
            let (o, calls) = run_on(h, 3, &gap, Mode::Check);
            assert!(
                calls[0].contains("Install-Bootstrap.ps1' -Check;"),
                "{}",
                calls[0]
            );
            assert!(
                o[0].notes[0].ends_with("Install-Bootstrap.ps1'"),
                "{:?}",
                o[0].notes
            );
        }
    }
}
