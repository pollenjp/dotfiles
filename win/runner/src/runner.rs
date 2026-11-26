//! 手順を順に流し、締めの表と締めの行を出す (check・apply・list の中身)。

use crate::context::Ctx;
use crate::host::{HostValues, Source};
use crate::report::{self, Kind, Row};
use crate::steps::{Mode, Outcome, Step};

/// 見た場所を「・」でつなぐ (ホストの値が無いときの文)
fn joined(paths: &[std::path::PathBuf]) -> String {
    paths
        .iter()
        .map(|p| p.display().to_string())
        .collect::<Vec<_>>()
        .join("・")
}

/// ホストの値と受け持ちを 2 行で出す (表の前)。
pub fn describe_host(ctx: &mut Ctx) {
    let h = ctx.host.clone();
    match &h.source {
        Source::File(p) => ctx.say(format!(
            "ホストの値: {} (グループ {})",
            p.display(),
            h.group
        )),
        Source::Both { used, other } => ctx.say(format!(
            "ホストの値: {} (グループ {})。dotfiles-private の {} もある (どちらを使うか決まらないので、apply は止める)",
            used.display(),
            h.group,
            other.display()
        )),
        Source::Missing(paths) => ctx.say(format!(
            "ホストの値: 無い ({})。グループ {} の既定で確かめる",
            joined(paths),
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

/// ホストの値が無い・2 つあるときの行。
pub fn host_rows(host: &HostValues) -> Vec<Row> {
    match &host.source {
        Source::File(_) => Vec::new(),
        Source::Both { used, other } => vec![
            Row::new(
                None,
                "host",
                Kind::Manual,
                format!(
                    "ホストの値が 2 つある ({} と {}) → 使わない方を退ける (check は手元の {} の値で確かめた)",
                    used.display(),
                    other.display(),
                    used.display()
                ),
            )
            .with_notes(vec![
                "どちらを使うか決まらないので、apply は止める。--host-file でどちらかを渡せば、その 1 つだけを読む (win/README.md の「ホストの値」)".to_string(),
            ]),
        ],
        Source::Missing(paths) => vec![
            Row::new(
                None,
                "host",
                Kind::Manual,
                format!(
                    "ホストの値が無い ({}) → 手元の host.toml に雛形 (win/templates/host.minimum.toml) を写すか、dotfiles-private の win/hosts/ に書く",
                    joined(paths)
                ),
            )
            .with_notes(vec![
                "書き方は win/README.md の「ホストの値」。無い間は、グループの既定で確かめ、apply は止める".to_string(),
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
                    "受け持ちは WSL の setup なので apply では流さない (WSL の setup の bootstrap-windows-{}.sh が流す)",
                    info.id
                ),
            ));
            continue;
        }
        if info.ported {
            ctx.say("");
            ctx.heading(format!(
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

/// 締めの表と締めの行を出し、終了コードを返す。出力が端末なら、表と締めの行に行の種類の色を付ける (`report::paint_table`)。
pub fn finish(ctx: &mut Ctx, title: &str, rows: &[Row]) -> i32 {
    let paint = ctx.paint();
    ctx.say("");
    ctx.heading(format!("==> 結果 ({title})"));
    for l in report::paint_table(rows, paint) {
        ctx.say(l);
    }
    for l in report::paint_verdict(rows, paint) {
        ctx.say(l);
    }
    // 受け持ちが WSL のホストでは、WSL の setup と同じ手順は apply で流さないので、締めの行の「dotfiles apply で揃える・直す」の代わりの
    // 道を添える (Windows にしか無い手順は apply で揃う)
    let fixable = rows
        .iter()
        .any(|r| matches!(r.kind, Kind::Missing | Kind::Fix) && shared_with_wsl(&r.id));
    if fixable && !ctx.host.runner_enable {
        ctx.say("※ このホストの受け持ちは WSL の setup なので、WSL の setup と同じ手順 (files・ps1・powershell-profile など。dotfiles list で「(Windows だけ)」の付かない手順) は dotfiles apply では流さない。揃えるのは WSL の ~/dotfiles/setup --update (受け持ちを runner に切り替えるまで)");
    }
    report::exit_code(rows)
}

/// apply を止めるわけ (無ければ流してよい)。ホストの値が無い・2 つある (手元と dotfiles-private) とき・受け持ちが WSL のホストで Windows に
/// しか無い手順を選んでいないとき (`apply --steps files` が黙って何もせずに 0 で終わらないように)。
pub fn apply_blocker(host: &HostValues, steps: &[Box<dyn Step>]) -> Option<Row> {
    match &host.source {
        Source::Missing(_) => Some(Row::new(
            None,
            "host",
            Kind::Blocker,
            "ホストの値が無いので apply は止めた (check と apply --dry-run は流せる)",
        )),
        Source::Both { .. } => Some(Row::new(
            None,
            "host",
            Kind::Blocker,
            "ホストの値が 2 つある (手元の host.toml と dotfiles-private) ので apply は止めた (check と apply --dry-run は流せる)",
        )),
        Source::File(p)
            if !host.runner_enable
                && !steps.iter().any(|s| {
                    let info = s.info();
                    info.windows_only && info.gate.off_reason(host).is_none()
                }) =>
        {
            Some(
                Row::new(
                    None,
                    "host",
                    Kind::Blocker,
                    "受け持ちは WSL の setup (runner.enable が true でない) なので apply は止めた (選んだ手順に、このホストで on の Windows にしか無い手順が無い)",
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

/// 取り込み (`dotfiles import <id> [<名前>…]`。WSL の script の `--import`): Windows 側の値を repo のファイルへ写す。受け持ちが runner のホスト
/// でだけ流す (受け持ちが WSL の間は WSL の script で取り込む。runner の記録を書かない)。
pub fn import(ctx: &mut Ctx, id: &str, names: &[String]) -> Vec<Row> {
    let mut rows = host_rows(&ctx.host);
    let order = crate::steps::all()
        .iter()
        .map(|s| s.info())
        .find(|i| i.id == id)
        .map(|i| i.order);
    if !ctx.host.runner_enable {
        // WSL の script の --import は名前を 1 つずつ取る (fancyzones は --import <名前> を繰り返す。terminal・international・google-ime は名前を
        // 取らない)
        let args: String = if names.is_empty() {
            " --import".to_string()
        } else {
            names
                .iter()
                .map(|n| format!(" --import {}", crate::steps::deploy::sh_quote(n)))
                .collect()
        };
        rows.push(
            Row::new(
                order,
                id,
                Kind::Blocker,
                "受け持ちは WSL の setup (runner.enable が true でない) なので取り込みは止めた",
            )
            .with_notes(vec![format!(
                "受け持ちが WSL の間は、WSL で nix/scripts/bootstrap-windows-{id}.sh{args} を打つ"
            )]),
        );
        return rows;
    }
    ctx.say("");
    let o = match id {
        "terminal" => crate::steps::terminal::import(ctx),
        "fancyzones" => crate::steps::fancyzones::import(ctx, names),
        "international" => crate::steps::international::import(ctx),
        "google-ime" => crate::steps::google_ime::import(ctx),
        other => Outcome::new(Kind::Failed, format!("{other} は取り込めない")),
    };
    rows.push(Row::new(order, id, o.kind, o.text).with_notes(o.notes));
    rows
}

/// 手順の一覧 (list)。
pub fn list(ctx: &mut Ctx, steps: &[Box<dyn Step>]) {
    ctx.heading("==> 手順");
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
    //! - 出力が端末なら、見出しは太字、締めの表と締めの行は行の種類の色。色を落とすと端末でないときと同じ字

    use super::*;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::Stream;
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
            "受け持ちは WSL の setup なので apply では流さない (WSL の setup の bootstrap-windows-s.sh が流す)"
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

    /// `f` に受け持ちが runner のホストの文脈を渡し、出した字を返す
    fn output_of(sys: &FakeSys, f: impl FnOnce(&mut Ctx)) -> String {
        let mut out = Vec::new();
        {
            let mut ctx = Ctx {
                repo: "/r".into(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: "/s".into(),
                host: host_of(Some("[runner]\nenable = true\n")),
                sys,
                out: &mut out,
            };
            f(&mut ctx);
        }
        String::from_utf8(out).unwrap()
    }

    /// 出力が端末なら、手順と結果の見出しは太字、締めの表と締めの行は行の種類の色 (✔ は印だけ緑・直すことがある行は太い黄)。
    /// 端末でなければ色の字を出さず、色を落とすと同じ字
    #[test]
    fn terminal_output_is_colored() {
        let steps: Vec<Box<dyn Step>> = vec![
            Box::new(Fixed(info("a", Gate::Always, true), Kind::Ok)),
            Box::new(Fixed(info("m", Gate::Always, true), Kind::Missing)),
        ];
        let check = |ctx: &mut Ctx| {
            let rows = execute(ctx, Mode::Check, &steps);
            assert_eq!(finish(ctx, "check", &rows), 3);
            list(ctx, &steps);
        };
        let sys = || FakeSys::new(|_| unreachable!());
        let out = output_of(&sys().with_terminal(Stream::Stdout), check);
        for want in [
            "\n\u{1b}[1m━━ [97] a: x ━━\u{1b}[0m\n",
            "\n\u{1b}[1m==> 結果 (check)\u{1b}[0m\n",
            "\n  \u{1b}[32m✔\u{1b}[0m [97] a               t\n",
            "\n  \u{1b}[1;33m⚠ [97] m               t\u{1b}[0m\n",
            "\n\u{1b}[1;33m⚠️ 入っていない・無いものがある → dotfiles apply で揃える ⚠️\u{1b}[0m\n",
            "\n\u{1b}[1m==> 手順\u{1b}[0m\n",
        ] {
            assert!(out.contains(want), "{want:?} が無い: {out:?}");
        }
        let plain = output_of(&sys(), check);
        assert!(!plain.contains('\u{1b}'), "{plain:?}");
        assert_eq!(crate::process::strip_ansi(&out), plain);
    }

    #[test]
    fn list_marks_windows_only_steps() {
        let steps: Vec<Box<dyn Step>> = vec![
            Box::new(Fixed(windows_only("w"), Kind::Ok)),
            Box::new(Fixed(info("s", Gate::Always, true), Kind::Ok)),
            Box::new(crate::steps::pending::Pending(always_pending())),
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
        // まだ無い手順は on/off の代わりに — と、受け持つ WSL の script を出す (今の PENDING は空なので、作り物で見る)
        assert!(
            line("x-pending")
                .ends_with("  —    x (runner にまだ無い。WSL の bootstrap-windows-x-pending.sh)"),
            "{out}"
        );
        assert!(out.contains("受け持ち: WSL の setup (runner.enable が true でない。apply は Windows にしか無い手順だけを流す)"));
    }

    /// いつも on の、runner にまだ無い手順 (試験のための作り物。今の PENDING に、いつも on のものが残っているとは限らない)
    static ALWAYS_PENDING: crate::steps::pending::PendingSpec =
        crate::steps::pending::PendingSpec {
            id: "x-pending",
            order: 97,
            title: "x",
            gate: Gate::Always,
        };

    fn always_pending() -> &'static crate::steps::pending::PendingSpec {
        &ALWAYS_PENDING
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
            Box::new(crate::steps::pending::Pending(always_pending())),
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
        let pending = always_pending().id;
        assert_eq!(
            kinds,
            vec![("a", Kind::Ok), ("b", Kind::Off), (pending, Kind::Info)]
        );
        assert_eq!(out.matches("ran").count(), 1);
        assert!(out.contains("━━ [97] a: x ━━"));
        assert!(!out.contains(&format!("{pending}:")));
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
        assert!(
            rows[0].text.contains("→ 手元の host.toml に雛形 (win/templates/host.minimum.toml) を写すか、dotfiles-private の win/hosts/ に書く"),
            "{}",
            rows[0].text
        );
    }

    /// 手元の host.toml と dotfiles-private の両方があれば、行は manual (使わない方を退ける) で、apply は止める
    #[test]
    fn both_host_files_add_a_row_and_block_apply() {
        let mut h = host_of(Some("[runner]\nenable = true\n"));
        h.source = Source::Both {
            used: "/h/.config/dotfiles/host.toml".into(),
            other: "/p/win/hosts/alice@example-host.toml".into(),
        };
        let rows = host_rows(&h);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].kind, Kind::Manual);
        assert!(
            rows[0].text.starts_with("ホストの値が 2 つある ("),
            "{}",
            rows[0].text
        );
        assert!(
            rows[0].notes[0].contains("--host-file"),
            "{:?}",
            rows[0].notes
        );
        let steps: Vec<Box<dyn Step>> = vec![Box::new(Fixed(windows_only("w"), Kind::Ok))];
        let b = apply_blocker(&h, &steps).unwrap();
        assert_eq!(b.kind, Kind::Blocker);
        assert!(b.text.contains("ホストの値が 2 つある"), "{}", b.text);
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
        // Windows にしか無い手順が、このホストでは off (グループ minimum の道具の既定) なら、流すものが無いので止める
        let off: Vec<Box<dyn Step>> = vec![
            Box::new(Fixed(info("s", Gate::Always, true), Kind::Ok)),
            Box::new(Fixed(
                StepInfo {
                    gate: Gate::Tool("windowsClaudeCode"),
                    ..windows_only("w")
                },
                Kind::Ok,
            )),
        ];
        assert!(apply_blocker(&host_of(Some("group = \"minimum\"")), &off).is_some());
        assert!(apply_blocker(&host_of(Some("group = \"all\"")), &off).is_none());
    }
}
