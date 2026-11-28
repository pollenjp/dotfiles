//! hc-hub (order 60): herdr-app と hc のハブ `~/h` (`C:\Users\<名前>\h`) を、公開のハブの道具 `pjp-hub.exe init` で作る (作り済みなら雛形との
//! 差だけ直す)。Linux の `nix/scripts/bootstrap-herdr-hub.sh` (旧 herdr のハブを hub-init.sh で作る) に当たる。
//!
//! 道具は公開の dotfiles の `nix/pkgs/pjp-tools` の `pjp-hub` (入口 `pjp` が `pjp hub …` で起こすもの) で、手順 pjp-tools (order 54) が
//! `%LOCALAPPDATA%\dotfiles\bin\pjp-hub.exe` に置く。runner はそれを絶対パスで打ち (PATH に足すのは pjp-tools。今の端末の PATH に頼らない)、
//! claude-skills の clone も shim も使わない (privateRepos・claudePrivateSkills が off のハブのホストでも動く。dotfiles-private の ADR 124)。
//! 雛形の settings.json に重ねる skillOverrides (`~/.claude/skills/pjp-hc-hub-private/assets/hub/settings.overlay.json`。足し分の skill は
//! claude-skills の手順 (order 50) が張る) は `pjp-hub` が自分で読む (無ければ重ねない)。runner の決め方:
//!
//! - `pjp-hub.exe` が無い → 手順 pjp-tools が置いていない (apply は ⚠ で止まり、ほかの手順は進む。check と dry-run は「無い」)
//! - `pjp-hub.exe check` で差を見て、差があれば apply で `pjp-hub.exe init` を引数なしで打つ (既定の `~/h`)。既にあるものを壊さない決まりは
//!   `pjp-hub init` が持つ (まだハブでない場所に雛形の外のものがあれば、何も書かずに止まる。ほかの skill のハブ・別の repo の中も止まる)。
//!   runner は止まったわけを出し、init を打たない
//! - 終了コード 2 (雛形の重ねのファイルが壊れている・git が無いなど設定の誤り) は、道具の文を添えて止まる
//! - claudePrivateSkills のホストで雛形の重ねのファイルが無く (claude-skills の clone が足し分を持つ版に進んでいない)、作り済みのハブの
//!   `.claude\settings.json` に skillOverrides があれば、`pjp-hub.exe` を打たずに ※ で claude-skills を進めるよう知らせる (init すると重ねの
//!   無い雛形で書き直し、skillOverrides が消えて commit される。check・dry-run も同じ行)。claudePrivateSkills が off のホストは、重ねが無いのが
//!   正しいので見ない
//!
//! dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*・docs/adr/124_*。

use super::claude_accounts::BIN_DIR_REL;
use super::pjp_tools::exe_name;
use super::ps1::run_streaming;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::process::{CommandSpec, Exit};
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// pjp-hub.exe check・init の待ちの上限 (init は git init と commit をする)
const HUB_SECS: u64 = 300;
/// pjp hub init が止まる差の印 (pjp-hc-hub の init.rs の diffs が書く)
const STOPS: &str = "このままでは pjp hub init は止まる";
/// 足し分の skill の雛形の重ねのファイル (`%USERPROFILE%` からの相対。pjp-hc-hub の templates.rs の OVERLAY_REL と同じ)。claude-skills の手順
/// (order 50) が clone の skills/pjp-hc-hub-private を張る
const OVERLAY_REL: &str = ".claude/skills/pjp-hc-hub-private/assets/hub/settings.overlay.json";
/// 重ねの無い claude-skills では init を打たない行の文 (check・dry-run・apply とも)
const NO_OVERLAY: &str = "claude-skills が足し分 (pjp-hc-hub-private) を持つ版になっていない。dotfiles --self-update で claude-skills を進めてから apply する (このままだとハブの skillOverrides が消える)";

pub struct HcHub;

/// 打つ道具 (手順 pjp-tools が置く `%LOCALAPPDATA%\dotfiles\bin\pjp-hub.exe`)。
fn hub_exe(ctx: &Ctx) -> PathBuf {
    join_segments(&ctx.roots.local_app_data, BIN_DIR_REL).join(exe_name("pjp-hub"))
}

/// ハブ (`pjp-hub.exe init` の既定の `%USERPROFILE%\h`)。
fn hub_dir(ctx: &Ctx) -> PathBuf {
    ctx.roots.user_profile.join("h")
}

/// settings.json の中身 `text` に、空でない skillOverrides (object) があるか。JSON として読めなければ無いとみる (Claude Code も読めないので、
/// init で消えるものが無い)
fn has_skill_overrides(text: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(text.trim_start_matches('\u{feff}'))
        .ok()
        .and_then(|v| {
            v.get("skillOverrides")
                .and_then(serde_json::Value::as_object)
                .map(|m| !m.is_empty())
        })
        .unwrap_or(false)
}

/// claudePrivateSkills のホストで雛形の重ねのファイルが無いのに、作り済みのハブの `.claude\settings.json` に skillOverrides があるとき、init を
/// 打たない行 (init すると重ねの無い雛形で settings.json を書き直し、skillOverrides が消えて commit される)。ほかは None (claudePrivateSkills が
/// off のホストは、重ねが無いのが正しい)
fn overrides_at_risk(ctx: &Ctx) -> Option<Outcome> {
    if !ctx.host.tool("claudePrivateSkills") {
        return None;
    }
    let overlay = join_segments(&ctx.roots.user_profile, OVERLAY_REL);
    if overlay.exists() {
        return None;
    }
    let settings = hub_dir(ctx).join(".claude").join("settings.json");
    let text = std::fs::read_to_string(&settings).ok()?;
    has_skill_overrides(&text).then(|| {
        Outcome::new(Kind::Manual, NO_OVERLAY)
            .note(format!(
                "雛形の重ねのファイルが無い: {} (足し分の skill pjp-hc-hub-private にあり、手順 claude-skills が clone から張る)",
                overlay.display()
            ))
            .note(format!(
                "ハブの {} に skillOverrides がある。runner は pjp-hub.exe init を打たない (足し分を使わないなら、その skillOverrides を消してから apply する)",
                settings.display()
            ))
    })
}

/// `pjp-hub.exe check` の答えの読み方。
enum State {
    Same,
    /// ハブが無い・git repo でない (apply で作る)
    Missing,
    /// 雛形との差 (apply で直す)
    Differs,
    /// init が止まる (人が直す)。添える行
    Stops(Vec<String>),
    /// 確かめられなかった。わけと添える行
    Failed(String, Vec<String>),
}

/// `pjp-hub.exe <sub>` を打つコマンド (claude-skills の clone を指す PJP_SKILLS_DIR は渡さない)
fn pjp_hub(exe: &Path, sub: &str) -> CommandSpec {
    CommandSpec::new(exe)
        .arg(sub)
        .timeout(Duration::from_secs(HUB_SECS))
}

/// pjp-hc-hub の道具自身が出した行か (`pjp hub check: …`・`pjp hub init: …`)
fn from_hub(line: &str) -> bool {
    let l = line.trim();
    l.starts_with("pjp hub check:") || l.starts_with("pjp hub init:")
}

/// 添える行 (空でない行の最後の 5 行)
fn tail(lines: &[String]) -> Vec<String> {
    let kept: Vec<String> = lines
        .iter()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();
    kept[kept.len().saturating_sub(5)..].to_vec()
}

/// 道具の行 (`pjp hub …:` で始まる行)。無ければ、最後の 5 行
fn reason(lines: &[String]) -> Vec<String> {
    let own: Vec<String> = lines
        .iter()
        .filter(|l| from_hub(l))
        .map(|l| l.trim().to_string())
        .collect();
    if own.is_empty() { tail(lines) } else { own }
}

/// 差の行 (`差: ` の後ろ) が、ハブそのものが無い・git repo でないことか (`<絶対パス> が無い`・`<絶対パス> は git repo でない`)。雛形の
/// ファイルが無い (`CLAUDE.md が無い`) は違う。
fn hub_absent(diff: &str) -> bool {
    let absolute = diff.contains(":\\") || diff.starts_with('/') || diff.starts_with('\\');
    absolute && (diff.ends_with(" が無い") || diff.ends_with(" は git repo でない"))
}

fn classify(exit: &Exit, lines: &[String]) -> State {
    let diffs: Vec<String> = lines
        .iter()
        .filter_map(|l| l.trim().strip_prefix("差: ").map(str::to_string))
        .collect();
    let hub_said = lines.iter().any(|l| from_hub(l));
    match exit {
        Exit::Code(0) => State::Same,
        Exit::Code(1) if diffs.iter().any(|d| d.contains(STOPS)) => State::Stops(diffs),
        // 差の行が無く、道具が自分で断った (別の repo の中など)
        Exit::Code(1) if diffs.is_empty() && hub_said => State::Stops(tail(lines)),
        // 差の行も道具の行も無い: 道具が自分の文を出さずに落ちた
        Exit::Code(1) if diffs.is_empty() => State::Failed(
            "pjp-hub.exe check が差も止まるわけも出さずに 1 で終わった (上の出力)".to_string(),
            tail(lines),
        ),
        Exit::Code(1) if diffs.iter().any(|d| hub_absent(d)) => State::Missing,
        Exit::Code(1) => State::Differs,
        Exit::Code(2) => State::Failed(
            "pjp-hub.exe check が動けない (設定の誤り。雛形の重ねのファイルが壊れている・git が無いなど。※ の文を直す)".to_string(),
            reason(lines),
        ),
        Exit::TimedOut => State::Failed(
            format!("pjp-hub.exe check が {HUB_SECS} 秒たっても終わらなかった"),
            Vec::new(),
        ),
        Exit::SpawnFailed(e) => State::Failed(
            format!(
                "pjp-hub.exe を起こせない ({e}) → dotfiles apply --steps pjp-tools で置き直す (起こせない exe はわけを出して止まる)"
            ),
            Vec::new(),
        ),
        other => State::Failed(
            format!("pjp-hub.exe check で確かめられなかった ({other:?})"),
            tail(lines),
        ),
    }
}

/// 行に添える文を足す
fn with_notes(mut o: Outcome, notes: Vec<String>) -> Outcome {
    for n in notes {
        o = o.note(n);
    }
    o
}

impl Step for HcHub {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "hc-hub",
            order: 60,
            title: "herdr-app と hc のハブ ~/h を公開の pjp-hub.exe init で作る (作り済みなら雛形との差だけ直す)",
            // pjp-hub.exe を置く pjp-tools (54) と、雛形の重ねのファイルのある足し分の skill を張る claude-skills (50) の後
            gate: Gate::Tool("herdrHub"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let exe = hub_exe(ctx);
        // 重ねの無い claude-skills のまま init すると、ハブの skillOverrides が消える。pjp-hub.exe を打たず、check・dry-run・apply とも同じ行
        if let Some(o) = overrides_at_risk(ctx) {
            ctx.say(format!("!! {NO_OVERLAY}"));
            let o = if exe.is_file() {
                o
            } else {
                o.note(format!(
                    "pjp-hub.exe が無い ({}。手順 pjp-tools が置く: dotfiles apply --steps pjp-tools)",
                    exe.display()
                ))
            };
            return vec![o];
        }
        if !exe.is_file() {
            return vec![match mode {
                Mode::Apply { .. } => Outcome::new(
                    Kind::Failed,
                    format!(
                        "pjp-hub.exe が無い ({}) → 手順 pjp-tools が置いていない (dotfiles apply --steps pjp-tools)。上の pjp-tools の行を見る",
                        exe.display()
                    ),
                ),
                Mode::Check => Outcome::new(
                    Kind::Missing,
                    format!(
                        "pjp-hub.exe が無いので確かめられない ({}。手順 pjp-tools が置く) → apply で pjp-tools が置いた後に pjp-hub.exe init を流す",
                        exe.display()
                    ),
                ),
                Mode::DryRun { .. } => {
                    // 同じ apply の pjp-tools の手順 (order 54) が pjp-hub.exe を置いてから、この手順が流れる
                    ctx.say("[dry-run] (pjp-tools の手順が pjp-hub.exe を置いた後に) pjp-hub.exe check で差を見て、差があれば pjp-hub.exe init を流す");
                    Outcome::new(
                        Kind::Missing,
                        "[dry-run] pjp-hub.exe が無い → 手順 pjp-tools が置いた後に pjp-hub.exe check で差を見て、差があれば pjp-hub.exe init を流す",
                    )
                }
            }];
        }
        ctx.say(format!(
            "ハブ: {} (pjp-hub.exe init の既定)",
            hub_dir(ctx).display()
        ));
        ctx.say(format!("+ {} check", exe.display()));
        let r = run_streaming(ctx, &pjp_hub(&exe, "check"));
        let (kind, text) = match classify(&r.exit, &r.output) {
            State::Same => return vec![Outcome::new(Kind::Ok, "ハブは雛形どおり")],
            State::Failed(why, notes) => {
                return vec![with_notes(Outcome::new(Kind::Failed, why), notes)];
            }
            State::Stops(notes) => {
                return vec![with_notes(
                    Outcome::new(
                        Kind::Manual,
                        "pjp hub init は止まる (※ のわけを直す。runner は init を打たない)",
                    ),
                    notes,
                )];
            }
            State::Missing => (Kind::Missing, "ハブが無い"),
            State::Differs => (Kind::Fix, "ハブに雛形との差がある"),
        };
        match mode {
            Mode::Check => vec![Outcome::new(
                kind,
                format!("{text} → apply で pjp-hub.exe init"),
            )],
            Mode::DryRun { .. } => {
                ctx.say("[dry-run] pjp-hub.exe init を流す");
                vec![Outcome::new(
                    kind,
                    format!("[dry-run] {text} → pjp-hub.exe init"),
                )]
            }
            Mode::Apply { .. } => {
                ctx.say(format!("+ {} init", exe.display()));
                let r = run_streaming(ctx, &pjp_hub(&exe, "init"));
                vec![match r.exit {
                    Exit::Code(0) => {
                        Outcome::new(Kind::Ok, format!("{text}ので pjp-hub.exe init で揃えた"))
                    }
                    Exit::Code(1) => Outcome::new(
                        Kind::Manual,
                        "pjp-hub.exe init が止まった・落ちた (上の出力のわけを直す。止まる場所なら何も書いていない。commit で落ちたなら書いた後)",
                    ),
                    Exit::Code(2) => with_notes(
                        Outcome::new(
                            Kind::Failed,
                            "pjp-hub.exe init が動けない (設定の誤り。雛形の重ねのファイルが壊れている・git が無いなど。※ の文を直す)",
                        ),
                        reason(&r.output),
                    ),
                    other => Outcome::new(
                        Kind::Failed,
                        format!("pjp-hub.exe init が落ちた ({other:?}。上の出力)"),
                    ),
                }]
            }
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 打つのは手順 pjp-tools が置いた公開の `%LOCALAPPDATA%\dotfiles\bin\pjp-hub.exe` (絶対パス) の `check`・`init`。env に PJP_SKILLS_DIR を
    //!   渡さない。privateRepos・claudePrivateSkills が off で claude-skills の clone が無いハブのホストでも打つ
    //! - pjp-hub.exe が無い → check と dry-run は missing (手順 pjp-tools が置いた後に)、apply は failed (「手順 pjp-tools が置いていない」)
    //! - pjp-hub.exe check が 0 → ok。ハブが無い・git repo でない → missing、ほかの差 → fix (apply で pjp-hub.exe init)。init が止まる差・差の
    //!   行の無い 1 で道具の行がある → manual で init を打たない。終了コード 2 (雛形の重ねのファイルが壊れているなど) → failed で道具の文を添え、
    //!   init を打たない。道具の行も差の行も無い 1 → failed。init が 1 → manual、2 → failed で道具の文を添える
    //! - claudePrivateSkills のホストで雛形の重ねのファイルが無く、作り済みのハブの settings.json に空でない skillOverrides がある → pjp-hub.exe
    //!   check も init も打たずに manual (claude-skills を進めてから。check・dry-run・apply とも同じ行。pjp-hub.exe が無ければ、それも添える)。
    //!   重ねが張られたら init する。ハブが無い・skillOverrides が無い・空・JSON として読めない・claudePrivateSkills が off なら今までどおり
    //! - 手順の並び: claude-skills (足し分の skill の雛形の重ねを張る)・pjp-tools (pjp-hub.exe を置く) の後に流れる

    use super::*;
    use crate::host::{Groups, HostValues, parse};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, Exit, RunResult};
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    const APPLY: Mode = Mode::Apply { force: false };

    struct World {
        t: TempDir,
    }

    impl World {
        /// pjp-tools が pjp-hub.exe を置いた後 (claude-skills の clone は無い)
        fn new() -> Self {
            let t = TempDir::new("hc-hub");
            std::fs::create_dir_all(t.path().join("g").join("dotfiles")).unwrap();
            let w = World { t };
            std::fs::create_dir_all(w.hub_exe().parent().unwrap()).unwrap();
            std::fs::write(w.hub_exe(), "pjp-hub").unwrap();
            w
        }

        fn hub_exe(&self) -> PathBuf {
            self.t
                .path()
                .join("home")
                .join("AppData")
                .join("Local")
                .join("dotfiles")
                .join("bin")
                .join(format!("pjp-hub{}", std::env::consts::EXE_SUFFIX))
        }

        /// 作り済みのハブ (`%USERPROFILE%\h`) の `.claude\settings.json` を書く
        fn hub_settings(&self, text: &str) {
            self.t.write("home/h/.claude/settings.json", text);
        }

        /// 足し分の skill の雛形の重ね (`%USERPROFILE%\.claude\skills\pjp-hc-hub-private\assets\hub\settings.overlay.json`) を書く
        fn overlay(&self, text: &str) {
            self.t.write(
                "home/.claude/skills/pjp-hc-hub-private/assets/hub/settings.overlay.json",
                text,
            );
        }

        /// `pjp-hub.exe check` と `pjp-hub.exe init` の答え (`check`・`init` の終了コードと行)
        fn sys(&self, check: (i32, Vec<&str>), init: (i32, Vec<&str>)) -> FakeSys {
            let lines = |v: Vec<&str>| -> Vec<String> { v.iter().map(|s| s.to_string()).collect() };
            let (check_code, check_lines) = (check.0, lines(check.1));
            let (init_code, init_lines) = (init.0, lines(init.1));
            let exe = self.hub_exe();
            FakeSys::new(move |c: &CommandSpec| {
                assert_eq!(c.program, exe, "公開の pjp-hub.exe を絶対パスで打つ");
                match c.args_lossy().as_slice() {
                    [sub] if sub == "check" => RunResult {
                        exit: Exit::Code(check_code),
                        output: check_lines.clone(),
                    },
                    [sub] if sub == "init" => RunResult {
                        exit: Exit::Code(init_code),
                        output: init_lines.clone(),
                    },
                    other => panic!("思わぬコマンド: {other:?}"),
                }
            })
        }

        fn run_on(&self, sys: &FakeSys, mode: Mode, host: HostValues) -> Outcome {
            let mut out = Vec::new();
            let mut ctx = Ctx {
                repo: self.t.path().join("g").join("dotfiles"),
                roots: Roots::from_home(&self.t.path().join("home")),
                state_dir: self.t.path().join("state"),
                host,
                sys,
                out: &mut out,
            };
            HcHub.run(&mut ctx, mode).remove(0)
        }

        fn run(&self, sys: &FakeSys, mode: Mode) -> Outcome {
            self.run_on(
                sys,
                mode,
                HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
            )
        }
    }

    fn inits(sys: &FakeSys) -> usize {
        sys.call_args().iter().filter(|a| *a == "init").count()
    }

    /// herdrHub だけのホスト (privateRepos・claudePrivateSkills が off。claude-skills を使わないので、雛形の重ねは無いのが正しい)
    fn hub_only_host() -> HostValues {
        parse(
            "[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nherdrHub = true\n",
            Path::new("h.toml"),
            Groups::embedded().unwrap(),
        )
        .unwrap()
    }

    /// claudePrivateSkills も on のハブのホスト (足し分の skill が雛形の重ねを持つはず)
    fn private_skills_host() -> HostValues {
        parse(
            "[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nherdrHub = true\nprivateRepos = true\nclaudePrivateSkills = true\n",
            Path::new("h.toml"),
            Groups::embedded().unwrap(),
        )
        .unwrap()
    }

    /// 前に重ねて作ったハブの settings.json (skillOverrides がある)
    const WITH_OVERRIDES: &str =
        "{\n  \"hooks\": {},\n  \"skillOverrides\": {\n    \"pjp-x\": \"on\"\n  }\n}\n";

    /// 止める行の文 (指揮する側の決めた字)
    const NO_OVERLAY: &str = "claude-skills が足し分 (pjp-hc-hub-private) を持つ版になっていない。dotfiles --self-update で claude-skills を進めてから apply する (このままだとハブの skillOverrides が消える)";

    #[test]
    fn ok_when_the_hub_matches() {
        let w = World::new();
        let sys = w.sys((0, vec!["C:\\Users\\user\\h: 差は無い"]), (0, vec![]));
        let o = w.run(&sys, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert_eq!(inits(&sys), 0);
        let calls = sys.calls.borrow();
        assert_eq!(calls[0].program, w.hub_exe());
        assert_eq!(calls[0].args_lossy(), ["check"]);
        assert!(
            calls[0].envs.iter().all(|(k, _)| k != "PJP_SKILLS_DIR"),
            "PJP_SKILLS_DIR を渡さない: {:?}",
            calls[0].envs
        );
    }

    /// privateRepos・claudePrivateSkills が off で claude-skills の clone も無いハブのホストでも、公開の pjp-hub.exe でハブを作る
    #[test]
    fn works_without_the_private_repos() {
        let w = World::new();
        let host = hub_only_host;
        assert!(!host().tool("privateRepos") && !host().tool("claudePrivateSkills"));
        assert_eq!(HcHub.info().gate.off_reason(&host()), None);
        assert!(!w.t.path().join("g").join("claude-skills").exists());
        let sys = w.sys((1, vec!["差: C:\\Users\\user\\h が無い"]), (0, vec![]));
        let o = w.run_on(&sys, APPLY, host());
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert_eq!(sys.call_args(), ["check", "init"]);
        for c in sys.calls.borrow().iter() {
            assert!(c.envs.iter().all(|(k, _)| k != "PJP_SKILLS_DIR"), "{c:?}");
        }
    }

    #[test]
    fn creates_a_missing_hub() {
        let w = World::new();
        for diff in [
            "差: C:\\Users\\user\\h は git repo でない",
            "差: C:\\Users\\user\\h が無い",
        ] {
            let sys = w.sys((1, vec![diff]), (0, vec![]));
            let o = w.run(&sys, Mode::Check);
            assert_eq!(o.kind, Kind::Missing, "{diff}: {o:?}");
            assert!(o.text.contains("pjp-hub.exe init"), "{o:?}");
            let o = w.run(&sys, Mode::DryRun { force: false });
            assert_eq!(o.kind, Kind::Missing, "{diff}: {o:?}");
            assert_eq!(inits(&sys), 0);
            let o = w.run(&sys, APPLY);
            assert_eq!(o.kind, Kind::Ok, "{diff}: {o:?}");
            assert_eq!(inits(&sys), 1);
        }
    }

    #[test]
    fn template_differences_are_fix() {
        let w = World::new();
        let sys = w.sys(
            (
                1,
                vec!["差: CLAUDE.md が雛形と違う", "差: .gitignore が無い"],
            ),
            (0, vec![]),
        );
        assert_eq!(w.run(&sys, Mode::Check).kind, Kind::Fix);
        assert_eq!(w.run(&sys, APPLY).kind, Kind::Ok);
        assert_eq!(inits(&sys), 1);
    }

    #[test]
    fn stops_where_init_would_stop() {
        let w = World::new();
        for lines in [
            vec![
                "差: まだハブでない。雛形の外のものがある: notes.txt。このままでは pjp hub init は止まる",
            ],
            vec![
                "pjp hub check: C:\\Users\\user\\h は repo C:\\Users\\user の中。ハブは repo の外に作る",
            ],
        ] {
            let sys = w.sys((1, lines.clone()), (0, vec![]));
            let o = w.run(&sys, APPLY);
            assert_eq!(o.kind, Kind::Manual, "{lines:?}: {o:?}");
            assert_eq!(inits(&sys), 0);
        }
        let sys = w.sys((1, vec!["差: CLAUDE.md が無い"]), (1, vec![]));
        let o = w.run(&sys, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(
            o.text.contains("pjp-hub.exe init が止まった・落ちた"),
            "{o:?}"
        );
    }

    /// 終了コード 2 (雛形の重ねのファイルが壊れている・git が無いなど) は、道具の文を添えて止まる (init を打たない)
    #[test]
    fn exit_2_shows_the_reason() {
        let w = World::new();
        let why = "pjp hub check: C:\\Users\\user\\.claude\\skills\\pjp-hc-hub-private\\assets\\hub\\settings.overlay.json が JSON として読めません (expected value at line 1 column 1)";
        let sys = w.sys((2, vec![why]), (0, vec![]));
        for mode in [Mode::Check, Mode::DryRun { force: false }, APPLY] {
            let o = w.run(&sys, mode);
            assert_eq!(o.kind, Kind::Failed, "{mode:?} {o:?}");
            assert!(o.notes.iter().any(|n| n == why), "{mode:?} {o:?}");
        }
        assert_eq!(inits(&sys), 0);
        let init_why = "pjp hub init: git が見つかりません (PATH)";
        let sys = w.sys((1, vec!["差: CLAUDE.md が無い"]), (2, vec![init_why]));
        let o = w.run(&sys, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.notes.iter().any(|n| n == init_why), "{o:?}");
    }

    /// 道具の行も差の行も無い 1 (pjp-hub.exe が自分の文を出さずに落ちた) は failed (init を打たない)
    #[test]
    fn a_silent_failure_is_failed() {
        let w = World::new();
        let sys = w.sys(
            (1, vec!["thread 'main' panicked at src/x.rs:1:1"]),
            (0, vec![]),
        );
        for mode in [Mode::Check, APPLY] {
            let o = w.run(&sys, mode);
            assert_eq!(o.kind, Kind::Failed, "{mode:?} {o:?}");
            assert!(o.notes.iter().any(|n| n.contains("panicked")), "{o:?}");
        }
        assert_eq!(inits(&sys), 0);
    }

    /// pjp-hub.exe が無い: 手順 pjp-tools が置いていない (check・dry-run は missing、apply は failed)。何も打たない
    #[test]
    fn needs_pjp_hub_from_pjp_tools() {
        let w = World::new();
        std::fs::remove_file(w.hub_exe()).unwrap();
        let sys = w.sys((0, vec![]), (0, vec![]));
        let o = w.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(o.text.contains("pjp-tools"), "{o:?}");
        // dry-run は、同じ apply の pjp-tools の手順が置いた後にすることを [dry-run] の形で出す
        let o = w.run(&sys, Mode::DryRun { force: false });
        assert_eq!(o.kind, Kind::Missing);
        assert!(o.text.starts_with("[dry-run] "), "{o:?}");
        assert!(
            o.text
                .contains("pjp-hub.exe check で差を見て、差があれば pjp-hub.exe init を流す"),
            "{o:?}"
        );
        let o = w.run(&sys, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(
            o.text
                .contains("手順 pjp-tools が置いていない (dotfiles apply --steps pjp-tools)"),
            "{o:?}"
        );
        assert!(sys.calls.borrow().is_empty());
    }

    /// claudePrivateSkills のホストで雛形の重ねのファイルが無く、作り済みのハブの settings.json に skillOverrides があれば、pjp-hub.exe init を
    /// 打たずに manual で claude-skills を進めるよう知らせる (init すると重ねの無い雛形で書き直し、skillOverrides が消えて commit される)。check・
    /// dry-run も同じ行。pjp-hub.exe がまだ無い (手順 pjp-tools の前) ときも同じ行で、無いことを添える。重ねが張られたら init する
    #[test]
    fn keeps_the_hubs_skill_overrides_without_the_overlay() {
        for settings in [
            WITH_OVERRIDES.to_string(),
            format!("\u{feff}{WITH_OVERRIDES}"),
        ] {
            let w = World::new();
            w.hub_settings(&settings);
            let sys = w.sys(
                (1, vec!["差: .claude/settings.json が雛形と違う"]),
                (0, vec![]),
            );
            for mode in [Mode::Check, Mode::DryRun { force: false }, APPLY] {
                let o = w.run_on(&sys, mode, private_skills_host());
                assert_eq!(o.kind, Kind::Manual, "{mode:?} {o:?}");
                assert_eq!(o.text, NO_OVERLAY, "{mode:?}");
                assert!(
                    o.notes
                        .iter()
                        .any(|n| n.contains("pjp-hc-hub-private")
                            && n.contains("settings.overlay.json")),
                    "{mode:?} {o:?}"
                );
                assert!(
                    o.notes.iter().any(|n| n.contains("skillOverrides")
                        && n.contains(&*w.t.path().join("home").join("h").to_string_lossy())),
                    "{mode:?} {o:?}"
                );
            }
            assert_eq!(inits(&sys), 0, "{:?}", sys.call_args());

            // pjp-hub.exe がまだ無い: 同じ行で、無いことも添える
            let exe = std::fs::read(w.hub_exe()).unwrap();
            std::fs::remove_file(w.hub_exe()).unwrap();
            for mode in [Mode::Check, Mode::DryRun { force: false }, APPLY] {
                let o = w.run_on(&sys, mode, private_skills_host());
                assert_eq!(o.kind, Kind::Manual, "{mode:?} {o:?}");
                assert_eq!(o.text, NO_OVERLAY, "{mode:?}");
                assert!(
                    o.notes
                        .iter()
                        .any(|n| n.contains("pjp-hub.exe が無い") && n.contains("pjp-tools")),
                    "{mode:?} {o:?}"
                );
            }
            assert!(sys.calls.borrow().is_empty(), "{:?}", sys.call_args());
            std::fs::write(w.hub_exe(), exe).unwrap();

            // 重ねのファイルが張られたら (claude-skills を進めた後)、差を見て init する
            w.overlay("{\"skillOverrides\": {\"pjp-x\": \"on\"}}\n");
            let o = w.run_on(&sys, APPLY, private_skills_host());
            assert_eq!(o.kind, Kind::Ok, "{o:?}");
            assert_eq!(sys.call_args(), ["check", "init"]);
        }
    }

    /// 重ねが無くても、消える skillOverrides が無い (ハブが無い・settings.json に skillOverrides が無い・空・JSON として読めない) なら、今までどおり
    /// 差を見て init する。claudePrivateSkills が off のホスト (重ねは無いのが正しい) も、skillOverrides の有無によらず今までどおり
    #[test]
    fn inits_when_no_skill_overrides_are_at_risk() {
        for settings in [
            None,
            Some("{\n  \"hooks\": {}\n}\n"),
            Some("{\n  \"hooks\": {},\n  \"skillOverrides\": {}\n}\n"),
            Some("not json"),
        ] {
            let w = World::new();
            if let Some(s) = settings {
                w.hub_settings(s);
            }
            let sys = w.sys((1, vec!["差: CLAUDE.md が雛形と違う"]), (0, vec![]));
            let o = w.run_on(&sys, APPLY, private_skills_host());
            assert_eq!(o.kind, Kind::Ok, "{settings:?} {o:?}");
            assert_eq!(sys.call_args(), ["check", "init"], "{settings:?}");
        }
        let w = World::new();
        w.hub_settings(WITH_OVERRIDES);
        for host in [
            hub_only_host(),
            HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
        ] {
            assert!(!host.tool("claudePrivateSkills"));
            let sys = w.sys(
                (1, vec!["差: .claude/settings.json が雛形と違う"]),
                (0, vec![]),
            );
            assert_eq!(w.run_on(&sys, Mode::Check, host.clone()).kind, Kind::Fix);
            let o = w.run_on(&sys, APPLY, host);
            assert_eq!(o.kind, Kind::Ok, "{o:?}");
            assert_eq!(inits(&sys), 1);
        }
    }

    /// pjp-hub.exe は手順 pjp-tools (54) が置き、雛形の重ねのファイルは claude-skills の手順 (50) が張る足し分の skill にあるので、その後に流れる
    #[test]
    fn runs_after_pjp_tools_and_claude_skills() {
        let ids: Vec<&str> = crate::steps::all().iter().map(|s| s.info().id).collect();
        let at = |id: &str| ids.iter().position(|x| *x == id).unwrap();
        assert!(at("claude-skills") < at("hc-hub"), "{ids:?}");
        assert!(at("pjp-tools") < at("hc-hub"), "{ids:?}");
    }

    #[test]
    fn step_info() {
        let i = HcHub.info();
        assert_eq!(
            (i.id, i.order, i.gate),
            ("hc-hub", 60, Gate::Tool("herdrHub"))
        );
        assert!(i.ported && i.windows_only);
    }
}
