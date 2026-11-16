//! 手順を順に流し、締めの表と締めの行を出す (check・apply・list の中身)。

use crate::context::Ctx;
use crate::host::{HostValues, Source};
use crate::report::{self, Kind, Row};
use crate::steps::{Mode, Step};

/// ホストの値と受け持ちを 2 行で出す (表の前)。
pub fn describe_host(ctx: &mut Ctx) {
    let h = ctx.host.clone();
    match &h.source {
        Source::File(p) => ctx.say(format!(
            "ホストの値: {} (グループ {})",
            p.display(),
            h.group
        )),
        Source::Missing(p) => ctx.say(format!(
            "ホストの値: 無い ({})。グループ {} の既定で確かめる",
            p.display(),
            h.group
        )),
    }
    if h.runner_enable {
        ctx.say("受け持ち: runner (runner.enable = true。apply で揃える)");
    } else {
        ctx.say(
            "受け持ち: WSL の setup (runner.enable が true でない。apply は Windows にしか無い手順だけを流す)",
        );
    }
}

/// 受け持ちが WSL のホストの apply で流さない手順か (runner に移した、WSL の setup と同じ手順)。
fn deferred_to_wsl(host: &HostValues, info: &crate::steps::StepInfo) -> bool {
    !host.runner_enable && info.ported && !info.windows_only
}

/// その id の手順が、WSL の setup と同じ手順 (Windows にしか無い手順でない) か。手順でない行 (host) は false。
fn shared_with_wsl(id: &str) -> bool {
    crate::steps::all()
        .iter()
        .any(|s| s.info().id == id && !s.info().windows_only)
}

/// ホストの値が無いときの行。
pub fn host_rows(host: &HostValues) -> Vec<Row> {
    match &host.source {
        Source::File(_) => Vec::new(),
        Source::Missing(p) => vec![
            Row::new(
                None,
                "host",
                Kind::Manual,
                format!("ホストの値が無い ({}) → dotfiles-private の win/hosts/ に書く", p.display()),
            )
            .with_notes(vec![
                "書き方は win/README.md の「runner」。無い間は、グループの既定で確かめ、apply は止める".to_string(),
            ]),
        ],
    }
}

/// 手順を順に流して行を返す。off の手順は流さずに ↷ の行、まだ無い手順は見出しを出さずに行だけ。受け持ちが WSL のホストの apply は、
/// WSL の setup と同じ手順を流さずに · の行 (Windows にしか無い手順だけを流す)。
pub fn execute(ctx: &mut Ctx, mode: Mode, steps: &[Box<dyn Step>]) -> Vec<Row> {
    let mut rows = host_rows(&ctx.host);
    for step in steps {
        let info = step.info();
        if let Some(reason) = info.gate.off_reason(&ctx.host) {
            rows.push(Row::new(Some(info.order), info.id, Kind::Off, reason));
            continue;
        }
        if matches!(mode, Mode::Apply { .. }) && deferred_to_wsl(&ctx.host, &info) {
            rows.push(Row::new(
                Some(info.order),
                info.id,
                Kind::Info,
                format!(
                    "受け持ちは WSL の setup なので apply では流さない (WSL の bootstrap-windows-{}.sh が配る)",
                    info.id
                ),
            ));
            continue;
        }
        if info.ported {
            ctx.say("");
            ctx.say(format!(
                "━━ [{}] {}: {} ━━",
                info.order, info.id, info.title
            ));
        }
        for o in step.run(ctx, mode) {
            rows.push(Row::new(Some(info.order), info.id, o.kind, o.text).with_notes(o.notes));
        }
    }
    rows
}

/// 締めの表と締めの行を出し、終了コードを返す。
pub fn finish(ctx: &mut Ctx, title: &str, rows: &[Row]) -> i32 {
    ctx.say("");
    ctx.say(format!("==> 結果 ({title})"));
    for l in report::format_table(rows) {
        ctx.say(l);
    }
    for l in report::verdict_lines(rows) {
        ctx.say(l);
    }
    // 受け持ちが WSL のホストでは、WSL の setup と同じ手順は apply で流さないので、締めの行の「dotfiles apply で揃える・直す」の代わりの
    // 道を添える (Windows にしか無い手順は apply で揃う)
    let fixable = rows
        .iter()
        .any(|r| matches!(r.kind, Kind::Missing | Kind::Fix) && shared_with_wsl(&r.id));
    if fixable && !ctx.host.runner_enable {
        ctx.say("※ このホストの受け持ちは WSL の setup なので、files と ps1 の手順は dotfiles apply では流さない。揃えるのは WSL の ~/dotfiles/setup --update (受け持ちを runner に切り替えるまで)");
    }
    report::exit_code(rows)
}

/// apply を止めるわけ (無ければ流してよい)。ホストの値が無いとき・受け持ちが WSL のホストで Windows にしか無い手順を選んでいないとき
/// (`apply --steps files` が黙って何もせずに 0 で終わらないように)。
pub fn apply_blocker(host: &HostValues, steps: &[Box<dyn Step>]) -> Option<Row> {
    match &host.source {
        Source::Missing(_) => Some(Row::new(
            None,
            "host",
            Kind::Blocker,
            "ホストの値が無いので apply は止めた (check と apply --dry-run は流せる)",
        )),
        Source::File(p)
            if !host.runner_enable && !steps.iter().any(|s| s.info().windows_only) =>
        {
            Some(
                Row::new(
                    None,
                    "host",
                    Kind::Blocker,
                    "受け持ちは WSL の setup (runner.enable が true でない) なので apply は止めた (選んだ手順に、Windows にしか無い手順が無い)",
                )
                .with_notes(vec![
                    "check と apply --dry-run は流せる".to_string(),
                    format!(
                        "受け持ちを runner に切り替えるのは dotfiles-private の同じ PR で: このホストの Nix の値の wsl.windowsFiles.enable = false と、{} の [runner] enable = true (win/README.md の「runner」)",
                        p.display()
                    ),
                ]),
            )
        }
        Source::File(_) => None,
    }
}

/// 手順の一覧 (list)。
pub fn list(ctx: &mut Ctx, steps: &[Box<dyn Step>]) {
    ctx.say("==> 手順");
    describe_host(ctx);
    ctx.say("");
    let width = steps.iter().map(|s| s.info().id.len()).max().unwrap_or(0);
    for step in steps {
        let info = step.info();
        let (state, extra) = if !info.ported {
            (
                "—  ",
                format!(
                    " (runner にまだ無い。WSL の bootstrap-windows-{}.sh)",
                    info.id
                ),
            )
        } else if let Some(reason) = info.gate.off_reason(&ctx.host) {
            (
                "off",
                format!(
                    " ({})",
                    reason
                        .trim_start_matches("このホストでは off (")
                        .trim_end_matches(')')
                ),
            )
        } else {
            ("on ", String::new())
        };
        let only = if info.ported && info.windows_only {
            " (Windows だけ)"
        } else {
            ""
        };
        ctx.say(format!(
            "  [{:>2}] {:<width$}  {state}  {}{extra}{only}",
            info.order, info.id, info.title
        ));
    }
    ctx.say("");
    ctx.say("on/off の決め方: いつも・設定グループ・道具の switch (ホストの値の [tools] か、win/runner/groups.json のグループの既定)");
    ctx.say("Windows だけ: WSL の setup に同じ手順が無いので、受け持ちによらず runner の apply が流す (ほかの手順は、受け持ちを runner に切り替えたホストでだけ apply が書く)");
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - off の手順は流さずに ↷、まだ無い手順は受け持ちで info と manual、ホストの値が無ければ host の行
    //! - apply は、ホストの値が無い・runner.enable が true でないなら止める

    use super::*;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::steps::{Gate, Outcome, StepInfo};
    use crate::testutil::FakeSys;
    use std::path::Path;

    struct Fixed(StepInfo, Kind);

    impl Step for Fixed {
        fn info(&self) -> StepInfo {
            self.0
        }
        fn run(&self, ctx: &mut Ctx, _mode: Mode) -> Vec<Outcome> {
            ctx.say("ran");
            vec![Outcome::new(self.1, "t")]
        }
    }

    fn info(id: &'static str, gate: Gate, ported: bool) -> StepInfo {
        StepInfo {
            id,
            order: 97,
            title: "x",
            gate,
            ported,
            windows_only: false,
        }
    }

    fn windows_only(id: &'static str) -> StepInfo {
        StepInfo {
            windows_only: true,
            ..info(id, Gate::Always, true)
        }
    }

    fn host_of(text: Option<&str>) -> HostValues {
        let g = Groups::embedded().unwrap();
        match text {
            Some(t) => parse(t, Path::new("h.toml"), g).unwrap(),
            None => HostValues::missing(Path::new("h.toml"), g),
        }
    }

    /// 偽の手順を、ホストの値 `host_text` のもとで `mode` で流す。行と出力を返す
    fn run_steps(
        host_text: Option<&str>,
        mode: Mode,
        steps: &[Box<dyn Step>],
    ) -> (Vec<Row>, String) {
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let rows = {
            let mut ctx = Ctx {
                repo: "/r".into(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: "/s".into(),
                host: host_of(host_text),
                sys: &sys,
                out: &mut out,
            };
            execute(&mut ctx, mode, steps)
        };
        (rows, String::from_utf8(out).unwrap())
    }

    /// 受け持ちが WSL のホストの apply は、Windows にしか無い手順だけを流し、WSL と同じ手順は流さずに · の行を出す (ADR 064)
    #[test]
    fn wsl_host_apply_runs_windows_only_steps() {
        let steps: Vec<Box<dyn Step>> = vec![
            Box::new(Fixed(windows_only("w"), Kind::Ok)),
            Box::new(Fixed(info("s", Gate::Always, true), Kind::Ok)),
        ];
        let (rows, out) = run_steps(Some(""), Mode::Apply { force: false }, &steps);
        assert_eq!(out.matches("ran").count(), 1, "{out}");
        assert!(out.contains("━━ [97] w: x ━━"));
        assert!(!out.contains("━━ [97] s: x ━━"));
        assert_eq!(rows[0].kind, Kind::Ok);
        assert_eq!(rows[1].kind, Kind::Info);
        assert_eq!(
            rows[1].text,
            "受け持ちは WSL の setup なので apply では流さない (WSL の bootstrap-windows-s.sh が配る)"
        );
        assert_eq!(report::exit_code(&rows), 0);

        // check と dry-run は受け持ちによらず全部を流す。受け持ちを切り替えたホストの apply も全部を流す
        for (host, mode) in [
            (Some(""), Mode::Check),
            (Some(""), Mode::DryRun { force: false }),
            (
                Some("[runner]\nenable = true\n"),
                Mode::Apply { force: false },
            ),
        ] {
            let (rows, out) = run_steps(host, mode, &steps);
            assert_eq!(out.matches("ran").count(), 2, "{mode:?}: {out}");
            assert!(rows.iter().all(|r| r.kind == Kind::Ok), "{mode:?}");
        }
    }

    #[test]
    fn list_marks_windows_only_steps() {
        let steps: Vec<Box<dyn Step>> = vec![
            Box::new(Fixed(windows_only("w"), Kind::Ok)),
            Box::new(Fixed(info("s", Gate::Always, true), Kind::Ok)),
        ];
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        {
            let mut ctx = Ctx {
                repo: "/r".into(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: "/s".into(),
                host: host_of(Some("")),
                sys: &sys,
                out: &mut out,
            };
            list(&mut ctx, &steps);
        }
        let out = String::from_utf8(out).unwrap();
        let line = |id: &str| {
            out.lines()
                .find(|l| l.contains(&format!("] {id} ")))
                .unwrap()
                .to_string()
        };
        assert!(line("w").ends_with("x (Windows だけ)"), "{out}");
        assert!(line("s").ends_with(" x"), "{out}");
        assert!(out.contains("受け持ち: WSL の setup (runner.enable が true でない。apply は Windows にしか無い手順だけを流す)"));
    }

    fn rows_for(host_text: Option<&str>) -> (Vec<Row>, String) {
        let g = Groups::embedded().unwrap();
        let host = match host_text {
            Some(t) => parse(t, Path::new("h.toml"), g).unwrap(),
            None => HostValues::missing(Path::new("h.toml"), g),
        };
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let steps: Vec<Box<dyn Step>> = vec![
            Box::new(Fixed(info("a", Gate::Always, true), Kind::Ok)),
            Box::new(Fixed(
                info("b", Gate::Tool("windowsTypeClipboard"), true),
                Kind::Ok,
            )),
            Box::new(crate::steps::pending::Pending(
                &crate::steps::pending::PENDING[0],
            )),
        ];
        let rows = {
            let mut ctx = Ctx {
                repo: "/r".into(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: "/s".into(),
                host,
                sys: &sys,
                out: &mut out,
            };
            execute(&mut ctx, Mode::Check, &steps)
        };
        (rows, String::from_utf8(out).unwrap())
    }

    #[test]
    fn off_and_pending_rows() {
        let (rows, out) = rows_for(Some(""));
        let kinds: Vec<(&str, Kind)> = rows.iter().map(|r| (r.id.as_str(), r.kind)).collect();
        assert_eq!(
            kinds,
            vec![("a", Kind::Ok), ("b", Kind::Off), ("powertoys", Kind::Info)]
        );
        assert_eq!(out.matches("ran").count(), 1);
        assert!(out.contains("━━ [97] a: x ━━"));
        assert!(!out.contains("powertoys:"));
        assert_eq!(report::exit_code(&rows), 0);
    }

    #[test]
    fn pending_counts_once_switched() {
        let (rows, _) = rows_for(Some("[runner]\nenable = true\n"));
        assert_eq!(rows[2].kind, Kind::Manual);
        assert_eq!(report::exit_code(&rows), 1);
    }

    #[test]
    fn missing_host_adds_a_row() {
        let (rows, _) = rows_for(None);
        assert_eq!(rows[0].id, "host");
        assert_eq!(rows[0].kind, Kind::Manual);
    }

    /// apply を止めるのは、ホストの値が無いときと、受け持ちが WSL のホストで Windows にしか無い手順を選んでいないとき
    #[test]
    fn apply_blockers() {
        let shared: Vec<Box<dyn Step>> =
            vec![Box::new(Fixed(info("s", Gate::Always, true), Kind::Ok))];
        let mixed: Vec<Box<dyn Step>> = vec![
            Box::new(Fixed(info("s", Gate::Always, true), Kind::Ok)),
            Box::new(Fixed(windows_only("w"), Kind::Ok)),
        ];
        let missing = apply_blocker(&host_of(None), &mixed).unwrap();
        assert_eq!(missing.kind, Kind::Blocker);
        assert!(missing.text.contains("ホストの値が無い"));
        let wsl = apply_blocker(&host_of(Some("")), &shared).unwrap();
        assert_eq!(wsl.kind, Kind::Blocker);
        assert!(wsl.text.contains("受け持ちは WSL の setup"), "{}", wsl.text);
        assert!(apply_blocker(&host_of(Some("")), &mixed).is_none());
        let runner = host_of(Some("[runner]\nenable = true"));
        assert!(apply_blocker(&runner, &shared).is_none());
    }
}
