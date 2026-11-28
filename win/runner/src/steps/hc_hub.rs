//! hc-hub (order 60): herdr-app と hc のハブ `~/h` (`C:\Users\<名前>\h`) を、claude-skills の pjp-hc-hub の `pjp hub init` で作る (作り済みなら
//! 雛形との差だけ直す)。Linux の `nix/scripts/bootstrap-herdr-hub.sh` (旧 herdr のハブを hub-init.sh で作る) に当たる。
//!
//! `pjp hub check` で差を見て、差があれば apply で `pjp hub init` を引数なしで打つ (既定の `~/h`)。既にあるものを壊さない決まりは
//! `pjp hub init` が持つ (まだハブでない場所に雛形の外のものがあれば、何も書かずに止まる。ほかの skill のハブ・別の repo の中も止まる)。runner は
//! 止まったわけを出し、init を打たない。`pjp hub check` は、shim が pjp-hub を作り直すことがある (clone の target/ は build の置き場で、置き先・
//! 記録・設定ではないので、check でも打つ)。dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*。

use super::claude_skills::clone_dir;
use super::pjp::shim_path;
use super::ps1::run_streaming;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::process::{CommandSpec, Exit};
use crate::report::Kind;
use std::path::Path;
use std::time::Duration;

/// pjp hub check・init の待ちの上限 (初めては shim が pjp-hub を作る)
const HUB_SECS: u64 = 900;
/// pjp hub init が止まる差の印 (pjp-hc-hub の init.rs の diffs が書く)
const STOPS: &str = "このままでは pjp hub init は止まる";

pub struct HcHub;

/// `pjp hub check` の答えの読み方。
enum State {
    Same,
    /// ハブが無い・git repo でない (apply で作る)
    Missing,
    /// 雛形との差 (apply で直す)
    Differs,
    /// init が止まる (人が直す)。添える行
    Stops(Vec<String>),
    /// pjp hub check まで届かなかった (shim が pjp-hub を作れない。check ではオフラインで作るので、取得が要る作り直しもここ)。添える行
    Unreachable(Vec<String>),
    Failed(String),
}

/// `pjp hub <sub>` を打つコマンド。`offline` (check と dry-run) なら、shim の作り直しで crate も toolchain も取りに行かない (check は
/// `~/.cargo` と `~/.rustup` を書かない。clone の `target/` は build の置き場なので書いてよい)。
fn pjp(shim: &Path, clone: &Path, sub: &str, offline: bool) -> CommandSpec {
    let spec = CommandSpec::new(shim)
        .arg("hub")
        .arg(sub)
        .env("PJP_SKILLS_DIR", clone.as_os_str())
        .env_remove("RUSTUP_TOOLCHAIN")
        .timeout(Duration::from_secs(HUB_SECS));
    if offline {
        spec.env("CARGO_NET_OFFLINE", "true")
            .env("RUSTUP_AUTO_INSTALL", "0")
    } else {
        spec
    }
}

/// pjp-hc-hub の道具自身が出した行か (`pjp hub check: …`・`pjp hub init: …`。shim の `pjp: …` と分ける)
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
        // 差の行も道具の行も無い: shim が pjp-hub を作れなかった (`pjp: …`)
        Exit::Code(1) if diffs.is_empty() => State::Unreachable(tail(lines)),
        Exit::Code(1) if diffs.iter().any(|d| hub_absent(d)) => State::Missing,
        Exit::Code(1) => State::Differs,
        Exit::Code(2) if !hub_said => State::Unreachable(tail(lines)),
        Exit::Code(2) => {
            State::Failed("pjp hub check が動けない (設定の誤り。上の出力)".to_string())
        }
        Exit::TimedOut => State::Failed(format!(
            "pjp hub check が {HUB_SECS} 秒たっても終わらなかった"
        )),
        other => State::Failed(format!("pjp hub check で確かめられなかった ({other:?})")),
    }
}

impl Step for HcHub {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "hc-hub",
            order: 60,
            title: "herdr-app と hc のハブ ~/h を pjp hub init で作る (作り済みなら雛形との差だけ直す)",
            gate: Gate::Tool("herdrHub"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let shim = shim_path(ctx);
        let clone = clone_dir(ctx);
        if !shim.is_file() {
            return vec![match mode {
                Mode::Apply { .. } => Outcome::new(
                    Kind::Failed,
                    format!(
                        "shim の pjp-skills が無い ({}) → 上の pjp の手順を見る",
                        shim.display()
                    ),
                ),
                Mode::Check => Outcome::new(
                    Kind::Missing,
                    format!(
                        "shim の pjp-skills が無いので確かめられない ({}) → apply で手順 pjp が pjp-skills を入れてから pjp hub init を流す",
                        shim.display()
                    ),
                ),
                Mode::DryRun { .. } => {
                    // 同じ apply の pjp の手順 (order 55) が shim を入れてから、この手順が流れる
                    ctx.say("[dry-run] (pjp の手順が shim の pjp-skills を入れた後に) pjp hub check で差を見て、差があれば pjp hub init を流す");
                    Outcome::new(
                        Kind::Missing,
                        "[dry-run] shim の pjp-skills が無い → 手順 pjp が入れた後に pjp hub check で差を見て、差があれば pjp hub init を流す",
                    )
                }
            }];
        }
        let tool = clone
            .join("skills")
            .join("pjp-hc-hub")
            .join("rust")
            .join("Cargo.toml");
        if !tool.is_file() {
            return vec![Outcome::new(
                Kind::Manual,
                format!(
                    "claude-skills の clone に pjp-hc-hub の道具がまだ無い ({}) → clone を進める (dotfiles --self-update apply)",
                    clone.display()
                ),
            )];
        }
        ctx.say(format!(
            "ハブ: {} (pjp hub init の既定)",
            ctx.roots.user_profile.join("h").display()
        ));
        ctx.say("+ pjp hub check");
        let r = run_streaming(ctx, &pjp(&shim, &clone, "check", !mode.writes()));
        let (kind, text) = match classify(&r.exit, &r.output) {
            State::Same => return vec![Outcome::new(Kind::Ok, "ハブは雛形どおり")],
            State::Failed(why) => return vec![Outcome::new(Kind::Failed, why)],
            State::Unreachable(notes) => {
                let mut o = if mode.writes() {
                    Outcome::new(
                        Kind::Failed,
                        "pjp hub check まで届かなかった (shim が pjp-hub を作れない。上の出力)",
                    )
                } else {
                    Outcome::new(
                        Kind::Fix,
                        "ハブを確かめられない (shim が pjp-hub を作れない。check は crate と toolchain を取らずに作るので、取得が要る作り直しもここ) → apply で pjp --build の後に確かめる",
                    )
                };
                for n in notes {
                    o = o.note(n);
                }
                return vec![o];
            }
            State::Stops(notes) => {
                let mut o = Outcome::new(
                    Kind::Manual,
                    "pjp hub init は止まる (※ のわけを直す。runner は init を打たない)",
                );
                for n in notes {
                    o = o.note(n);
                }
                return vec![o];
            }
            State::Missing => (Kind::Missing, "ハブが無い"),
            State::Differs => (Kind::Fix, "ハブに雛形との差がある"),
        };
        match mode {
            Mode::Check => vec![Outcome::new(
                kind,
                format!("{text} → apply で pjp hub init"),
            )],
            Mode::DryRun { .. } => {
                ctx.say("[dry-run] pjp hub init を流す");
                vec![Outcome::new(
                    kind,
                    format!("[dry-run] {text} → pjp hub init"),
                )]
            }
            Mode::Apply { .. } => {
                ctx.say("+ pjp hub init");
                let r = run_streaming(ctx, &pjp(&shim, &clone, "init", false));
                vec![match r.exit {
                    Exit::Code(0) => {
                        Outcome::new(Kind::Ok, format!("{text}ので pjp hub init で揃えた"))
                    }
                    Exit::Code(1) => Outcome::new(
                        Kind::Manual,
                        "pjp hub init が止まった・落ちた (上の出力のわけを直す。止まる場所なら何も書いていない。commit で落ちたなら書いた後)",
                    ),
                    other => Outcome::new(
                        Kind::Failed,
                        format!("pjp hub init が落ちた ({other:?}。上の出力)"),
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
    //! - shim が無い → check と dry-run は missing (apply で pjp を入れてから)、apply は failed
    //! - clone に pjp-hc-hub の道具が無い → manual
    //! - pjp hub check が 0 → ok。ハブが無い・git repo でない → missing、ほかの差 → fix (apply で pjp hub init)。init が止まる差・差の行の無い 1 →
    //!   manual で init を打たない。2 → failed。init が 1 → manual
    //! - pjp は PJP_SKILLS_DIR を付け、RUSTUP_TOOLCHAIN を外して打つ

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, Exit, RunResult};
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    struct World {
        t: TempDir,
    }

    impl World {
        fn new() -> Self {
            let t = TempDir::new("hc-hub");
            std::fs::create_dir_all(t.path().join("g").join("dotfiles")).unwrap();
            t.write(
                "g/claude-skills/skills/pjp-hc-hub/rust/Cargo.toml",
                "[package]\nname = \"pjp-hc-hub\"\n",
            );
            let shim = t
                .path()
                .join("home")
                .join(".cargo")
                .join("bin")
                .join(format!("pjp-skills{}", std::env::consts::EXE_SUFFIX));
            std::fs::create_dir_all(shim.parent().unwrap()).unwrap();
            std::fs::write(&shim, "shim").unwrap();
            World { t }
        }

        fn shim(&self) -> PathBuf {
            self.t
                .path()
                .join("home")
                .join(".cargo")
                .join("bin")
                .join(format!("pjp-skills{}", std::env::consts::EXE_SUFFIX))
        }

        /// `pjp hub check` と `pjp hub init` の答え
        fn sys(&self, check: (i32, Vec<&str>), init: i32) -> FakeSys {
            let check_lines: Vec<String> = check.1.iter().map(|s| s.to_string()).collect();
            let check_code = check.0;
            FakeSys::new(move |c: &CommandSpec| match c.args_lossy().as_slice() {
                [hub, sub] if hub == "hub" && sub == "check" => RunResult {
                    exit: Exit::Code(check_code),
                    output: check_lines.clone(),
                },
                [hub, sub] if hub == "hub" && sub == "init" => RunResult {
                    exit: Exit::Code(init),
                    output: vec![],
                },
                other => panic!("思わぬコマンド: {other:?}"),
            })
        }

        fn run(&self, sys: &FakeSys, mode: Mode) -> Outcome {
            let mut out = Vec::new();
            let mut ctx = Ctx {
                repo: self.t.path().join("g").join("dotfiles"),
                roots: Roots::from_home(&self.t.path().join("home")),
                state_dir: self.t.path().join("state"),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys,
                out: &mut out,
            };
            HcHub.run(&mut ctx, mode).remove(0)
        }
    }

    fn inits(sys: &FakeSys) -> usize {
        sys.call_args().iter().filter(|a| *a == "hub init").count()
    }

    #[test]
    fn ok_when_the_hub_matches() {
        let w = World::new();
        let sys = w.sys((0, vec!["C:\\Users\\alice\\h: 差は無い"]), 0);
        let o = w.run(&sys, Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert_eq!(inits(&sys), 0);
        let calls = sys.calls.borrow();
        assert_eq!(calls[0].program, w.shim());
        assert!(
            calls[0]
                .env_value("PJP_SKILLS_DIR")
                .unwrap()
                .ends_with("claude-skills")
        );
        assert!(calls[0].removes_env("RUSTUP_TOOLCHAIN"));
    }

    #[test]
    fn creates_a_missing_hub() {
        let w = World::new();
        for diff in [
            "差: C:\\Users\\alice\\h は git repo でない",
            "差: C:\\Users\\alice\\h が無い",
        ] {
            let sys = w.sys((1, vec![diff]), 0);
            let o = w.run(&sys, Mode::Check);
            assert_eq!(o.kind, Kind::Missing, "{diff}: {o:?}");
            let o = w.run(&sys, Mode::DryRun { force: false });
            assert_eq!(o.kind, Kind::Missing, "{diff}: {o:?}");
            assert_eq!(inits(&sys), 0);
            let o = w.run(&sys, Mode::Apply { force: false });
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
            0,
        );
        assert_eq!(w.run(&sys, Mode::Check).kind, Kind::Fix);
        assert_eq!(w.run(&sys, Mode::Apply { force: false }).kind, Kind::Ok);
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
                "pjp hub check: C:\\Users\\alice\\h は repo C:\\Users\\alice の中。ハブは repo の外に作る",
            ],
        ] {
            let sys = w.sys((1, lines.clone()), 0);
            let o = w.run(&sys, Mode::Apply { force: false });
            assert_eq!(o.kind, Kind::Manual, "{lines:?}: {o:?}");
            assert_eq!(inits(&sys), 0);
        }
        let sys = w.sys((2, vec!["pjp hub check: git が見つかりません (PATH)"]), 0);
        assert_eq!(w.run(&sys, Mode::Check).kind, Kind::Failed);
        let sys = w.sys((1, vec!["差: CLAUDE.md が無い"]), 1);
        let o = w.run(&sys, Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(o.text.contains("pjp hub init が止まった・落ちた"), "{o:?}");
    }

    /// check と dry-run の pjp hub check は、shim の作り直しで crate と toolchain を取りに行かない (CARGO_NET_OFFLINE・RUSTUP_AUTO_INSTALL)。
    /// apply は取りに行ってよい
    #[test]
    fn check_does_not_fetch() {
        let w = World::new();
        let sys = w.sys((0, vec![]), 0);
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            w.run(&sys, mode);
            let calls = sys.calls.borrow();
            let last = calls.last().unwrap();
            assert_eq!(
                last.env_value("CARGO_NET_OFFLINE").as_deref(),
                Some("true"),
                "{mode:?}"
            );
            assert_eq!(
                last.env_value("RUSTUP_AUTO_INSTALL").as_deref(),
                Some("0"),
                "{mode:?}"
            );
        }
        w.run(&sys, Mode::Apply { force: false });
        let calls = sys.calls.borrow();
        let last = calls.last().unwrap();
        assert_eq!(last.env_value("CARGO_NET_OFFLINE"), None);
        assert_eq!(last.env_value("RUSTUP_AUTO_INSTALL"), None);
    }

    /// shim が道具を作れずに落ちた (pjp: …) のは、init が止まる差ではない。check は「確かめられない」、apply は落ちた
    #[test]
    fn shim_failure_is_not_a_stop() {
        let w = World::new();
        let lines = vec![
            "error: no matching package named `foo` found",
            "pjp: 道具 pjp-hub を作れませんでした (cargo build)",
        ];
        let sys = w.sys((1, lines.clone()), 0);
        let o = w.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        assert!(o.text.contains("確かめられない"), "{o:?}");
        assert!(
            o.notes.iter().any(|n| n.contains("pjp: 道具 pjp-hub")),
            "{o:?}"
        );
        let o = w.run(&sys, Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert_eq!(inits(&sys), 0);
    }

    #[test]
    fn needs_the_shim_and_the_tool() {
        let w = World::new();
        std::fs::remove_file(w.shim()).unwrap();
        let sys = w.sys((0, vec![]), 0);
        assert_eq!(w.run(&sys, Mode::Check).kind, Kind::Missing);
        // dry-run は、同じ apply の pjp の手順が shim を入れた後にすることを [dry-run] の形で出す
        let o = w.run(&sys, Mode::DryRun { force: false });
        assert_eq!(o.kind, Kind::Missing);
        assert!(o.text.starts_with("[dry-run] "), "{o:?}");
        assert!(
            o.text
                .contains("pjp hub check で差を見て、差があれば pjp hub init を流す"),
            "{o:?}"
        );
        assert_eq!(w.run(&sys, Mode::Apply { force: false }).kind, Kind::Failed);
        assert!(sys.calls.borrow().is_empty());

        let w = World::new();
        std::fs::remove_dir_all(w.t.path().join("g").join("claude-skills").join("skills")).unwrap();
        let sys = w.sys((0, vec![]), 0);
        let o = w.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(sys.calls.borrow().is_empty());
    }
}
