//! files (order 90): `win/manifest.toml` のファイルを Windows に配る。WSL の `nix/scripts/bootstrap-windows-files.sh` を写したもの。
//!
//! 計画の 1 件ごとに、置き先の中身と「前回ここへ置いた中身の sha256」の記録 (`%LOCALAPPDATA%\dotfiles\state\windows-files.deployed.json`)
//! を比べて決める:
//!
//! | 置き先 | すること | 行の種類 (apply の前) |
//! | --- | --- | --- |
//! | 無い | コピーする | missing |
//! | 計画と同じ中身 | 何もしない (記録が無ければ記録だけする) | ok |
//! | 記録と同じ中身 (計画とは違う) | repo 側が更新された。上書きする | fix |
//! | それ以外 | 衝突。diff を出して触らない (`--force` なら上書き) | manual |
//!
//! 衝突は 2 通りあり、文を分ける: 記録があれば Windows 側で変わった (アプリの設定画面で変えた、など)。記録が無ければ、置く前から
//! Windows 側にあった。初めて流す Windows は記録が無いので、同じ commit から WSL が配った置き先は「同じ」(記録だけ作る) になる。
//! manifest から消したファイルは Windows 側から消さない (アプリが持つファイルなので)。

use super::ps1::ps_quote;
use super::{Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::manifest;
use crate::process::CommandSpec;
use crate::record::Records;
use crate::report::Kind;
use std::time::Duration;

pub const RECORD_FILE: &str = "windows-files.deployed.json";

pub struct Files;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Copy,
    Same,
    Update,
    Force,
    Conflict,
}

impl Step for Files {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "files",
            order: 90,
            title: "win/manifest.toml のファイルを配る",
            gate: super::Gate::Always,
            ported: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let plan = match manifest::load(&ctx.repo, &ctx.roots) {
            Ok(p) => p,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![Outcome::new(Kind::Failed, "win/manifest.toml に誤りがある").note(e)];
            }
        };
        if plan.files.is_empty() {
            ctx.say("配るファイルはありません (win/manifest.toml に [[files]] が無い)。");
            return vec![Outcome::new(Kind::Ok, "配るファイルは無い")];
        }
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let mut records = match Records::load(&record_path) {
            Ok(r) => r,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![Outcome::new(Kind::Failed, "配った記録が壊れている").note(e)];
            }
        };
        // clone の core.autocrlf が true だと、テキストが CRLF で取り出され、WSL が配った LF と中身が合わずに全部が衝突に見える
        let crlf = autocrlf_outcome(ctx);
        let force = mode.force();
        let (mut copied, mut updated, mut unchanged, mut conflicts, mut errors) = (0, 0, 0, 0, 0);
        let mut hints = Vec::new();

        for f in &plan.files {
            let dst_key = f.dst.to_string_lossy().into_owned();
            let want = match fsutil::sha256_file(&f.src) {
                Ok(h) => h,
                Err(e) => {
                    ctx.say(format!(
                        "!! コピー元が読めません: {} ({e})",
                        f.src.display()
                    ));
                    errors += 1;
                    continue;
                }
            };
            let recorded = records.get(&dst_key).map(str::to_string);
            if f.dst.is_dir() {
                ctx.say(format!("!! 置き先がディレクトリです: {dst_key}"));
                errors += 1;
                continue;
            }
            let action = if !f.dst.exists() {
                Action::Copy
            } else {
                match fsutil::sha256_file(&f.dst) {
                    Err(e) => {
                        ctx.say(format!("!! 置き先が読めません: {dst_key} ({e})"));
                        errors += 1;
                        continue;
                    }
                    Ok(have) if have == want => Action::Same,
                    Ok(have) if recorded.as_deref() == Some(have.as_str()) => Action::Update,
                    Ok(_) if force => Action::Force,
                    Ok(_) => Action::Conflict,
                }
            };
            match action {
                Action::Same => {
                    unchanged += 1;
                    ctx.say(format!("同じです: {dst_key}"));
                    if recorded.as_deref() != Some(want.as_str()) && mode.writes() {
                        records.set(&dst_key, &want);
                    }
                }
                Action::Conflict => {
                    conflicts += 1;
                    if recorded.is_some() {
                        ctx.say(format!(
                            "!! 衝突: {dst_key} は Windows 側で変わっています (前回ここへ置いた中身と違う)。"
                        ));
                    } else {
                        ctx.say(format!(
                            "!! 衝突: {dst_key} は、置いた記録が無く、repo と中身が違います (置く前から Windows 側にあった。アプリが作ったか、手で設定したもの。受け持ちを切り替える前なら、WSL が配った中身とこの clone の中身が違う)。"
                        ));
                    }
                    show_diff(ctx, f);
                    let repo_file = ctx.repo_path(&f.repo_path);
                    ctx.say(format!(
                        "   Windows 側の中身を残すなら: Copy-Item -LiteralPath '{}' -Destination '{}' (PowerShell。取り込んだら repo で commit する)",
                        ps_quote(&dst_key),
                        ps_quote(&repo_file.to_string_lossy())
                    ));
                    if ctx.host.runner_enable {
                        ctx.say(
                            "   repo 側で上書きするなら:   dotfiles apply --steps files --force",
                        );
                    } else {
                        // 受け持ちが WSL の間は runner の apply は止まるので、WSL の手順を出す
                        ctx.say("   repo 側で上書きするなら:   WSL で nix/scripts/bootstrap-windows-files.sh --force (受け持ちが WSL の setup の間。runner の apply は止まる)");
                    }
                }
                Action::Copy | Action::Update | Action::Force => {
                    let label = match action {
                        Action::Copy => "コピー",
                        Action::Update => "上書き (repo 側が更新された)",
                        _ => "上書き (--force)",
                    };
                    match mode {
                        Mode::Check => ctx.say(format!(
                            "{}: {dst_key}",
                            match action {
                                Action::Copy => "無い (apply でコピーする)",
                                _ => "repo 側が更新された (apply で上書きする)",
                            }
                        )),
                        Mode::DryRun { .. } => ctx.say(format!("[dry-run] {label}: {dst_key}")),
                        Mode::Apply { .. } => match fsutil::read_then_write(&f.src, &f.dst) {
                            Ok(()) => {
                                records.set(&dst_key, &want);
                                ctx.say(format!("{label}: {dst_key}"));
                                // 空の hint は出さない (WSL の [[ -n ${hint} ]] と同じ)
                                if let Some(h) = f.hint.as_deref().filter(|h| !h.is_empty()) {
                                    hints.push(format!("{dst_key}: {h}"));
                                }
                            }
                            Err(e) => {
                                ctx.say(format!("!! 書けません: {dst_key} ({e})"));
                                errors += 1;
                                continue;
                            }
                        },
                    }
                    if action == Action::Copy {
                        copied += 1;
                    } else {
                        updated += 1;
                    }
                }
            }
        }

        if mode.writes()
            && let Err(e) = records.save_if_changed()
        {
            ctx.say(format!(
                "!! 配った記録を書けません: {} ({e})",
                record_path.display()
            ));
            errors += 1;
        }
        if !hints.is_empty() {
            ctx.say("");
            ctx.say("置いたファイルを、アプリに読み直させてください:");
            for h in &hints {
                ctx.say(format!("  {h}"));
            }
        }

        let mut summary =
            format!("コピー {copied} / 上書き {updated} / 同じ {unchanged} / 衝突 {conflicts}");
        if errors > 0 {
            summary.push_str(&format!(" / エラー {errors}"));
        }
        if matches!(mode, Mode::DryRun { .. }) {
            summary = format!("[dry-run] {summary}");
        }
        ctx.say("");
        ctx.say(&summary);

        let kind = if errors > 0 {
            Kind::Failed
        } else if conflicts > 0 {
            Kind::Manual
        } else if mode.writes() {
            Kind::Ok
        } else if updated > 0 {
            Kind::Fix
        } else if copied > 0 {
            Kind::Missing
        } else {
            Kind::Ok
        };
        let mut outcome = Outcome::new(kind, summary);
        if conflicts > 0 {
            if ctx.host.runner_enable {
                outcome = outcome.note("衝突は上の出力の解き方で直す (Windows 側の中身を repo へ取り込むか、dotfiles apply --steps files --force)");
            } else {
                outcome = outcome.note("受け持ちは WSL の setup (runner.enable が true でない)。WSL が配った中身とこの clone の中身が違うなら、clone を同じ commit にそろえて見直す。衝突を解くのは WSL の側 (bootstrap-windows-files.sh)");
            }
        }
        crlf.into_iter().chain(std::iter::once(outcome)).collect()
    }
}

/// dotfiles の clone の core.autocrlf が true なら、そう出して `manual` の行を返す (bootstrap の clone は false)。git が無い・clone が
/// git の作業ツリーでない (試すときの一時ディレクトリ)・読めないときは何もしない。
fn autocrlf_outcome(ctx: &mut Ctx) -> Option<Outcome> {
    let git = ctx.sys.which("git")?;
    let git_in_repo = |args: &[&str]| {
        let mut spec = CommandSpec::new(&git)
            .arg("-C")
            .arg(ctx.repo.as_os_str())
            .timeout(Duration::from_secs(10));
        for a in args {
            spec = spec.arg(*a);
        }
        ctx.sys.run(&spec, &mut |_| {})
    };
    // 作業ツリーの外では、system・global の値を読んでしまう (Git for Windows の system は true)
    if git_in_repo(&["rev-parse", "--is-inside-work-tree"]).code() != Some(0) {
        return None;
    }
    let r = git_in_repo(&["config", "--get", "core.autocrlf"]);
    let value = r.output.first().map(|l| l.trim().to_ascii_lowercase());
    if r.code() != Some(0) || value.as_deref() != Some("true") {
        return None;
    }
    let repo = ps_quote(&ctx.repo.to_string_lossy());
    ctx.say(format!(
        "!! dotfiles の clone の core.autocrlf が true です ({})。テキストのファイルが CRLF で取り出され、WSL が配った LF と中身が合わずに衝突になります。",
        ctx.repo.display()
    ));
    Some(
        Outcome::new(
            Kind::Manual,
            "dotfiles の clone の core.autocrlf が true (テキストが CRLF で取り出され、WSL が配った LF と合わずに衝突になる)",
        )
        .note("bootstrap の clone は core.autocrlf=false (git clone -c core.autocrlf=false)。core.autocrlf=false で clone し直すのが確か")
        .note(format!(
            "この clone を直すなら、変更が無いことを確かめてから: git -C '{repo}' config core.autocrlf false → git -C '{repo}' rm --cached -r -q . → git -C '{repo}' reset --hard"
        )),
    )
}

/// 衝突の diff を `git diff --no-index` で出す (git が無ければ、そう出して進む)。
fn show_diff(ctx: &mut Ctx, f: &manifest::PlanFile) {
    let Some(git) = ctx.sys.which("git") else {
        ctx.say("   (git が無いので diff は出さない)");
        return;
    };
    let spec = CommandSpec::new(git)
        .arg("diff")
        .arg("--no-index")
        .arg("--no-color")
        .arg("--")
        .arg(f.dst.as_os_str())
        .arg(f.src.as_os_str())
        .timeout(Duration::from_secs(30));
    let sys = ctx.sys;
    let mut lines = Vec::new();
    sys.run(&spec, &mut |l| lines.push(format!("   {l}")));
    for l in lines {
        ctx.say(l);
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (WSL の nix/tests/bootstrap-windows-files.test.sh と同じケース)
    //!
    //! - 置き先が無ければコピーして記録する。同じ中身なら書かずに記録だけする
    //! - 置き先が記録どおりなら (repo 側が更新された) 上書きして記録を更新する
    //! - 置き先が記録と違えば (Windows 側で変わった) 衝突。触らずに diff と解き方を出す
    //! - 記録が無く、置き先が repo と違えば衝突。「前回ここへ置いた中身と違う」とは出さず、置いた記録が無いことを出す
    //! - --force は衝突でも上書きして記録する。--dry-run と check は置き先も記録も書かない
    //! - 置き先がディレクトリならエラー、記録が壊れていれば止める、manifest の誤りは止める
    //! - hint は書いたときだけ出す。締めの行の数と行の種類

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    struct Env {
        t: TempDir,
        sys: FakeSys,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("files");
            t.write(
                "repo/win/manifest.toml",
                "[[files]]\nsrc = \"app/a.json\"\ndst = \"%USERPROFILE%/.app/a.json\"\nhint = \"読み直す\"\n\n[[files]]\nsrc = \"app/b.toml\"\ndst = \"%APPDATA%/app/b.toml\"\n",
            );
            t.write("repo/win/app/a.json", "A1\n");
            t.write("repo/win/app/b.toml", "B1\n");
            let sys = FakeSys::new(|spec| crate::process::RunResult {
                exit: crate::process::Exit::Code(1),
                output: vec![format!("diff {}", spec.args_lossy().join(" "))],
            })
            .with_program("git", "/usr/bin/git");
            Env { t, sys }
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn dst_a(&self) -> PathBuf {
            self.home().join(".app").join("a.json")
        }

        fn dst_b(&self) -> PathBuf {
            self.home()
                .join("AppData")
                .join("Roaming")
                .join("app")
                .join("b.toml")
        }

        fn record_path(&self) -> PathBuf {
            self.home()
                .join("AppData")
                .join("Local")
                .join("dotfiles")
                .join("state")
                .join(RECORD_FILE)
        }

        fn records(&self) -> serde_json::Value {
            match std::fs::read_to_string(self.record_path()) {
                Ok(t) => serde_json::from_str(&t).unwrap(),
                Err(_) => serde_json::Value::Null,
            }
        }

        fn run(&self, mode: Mode) -> (Vec<Outcome>, String) {
            self.run_as(mode, false)
        }

        /// `runner_enable` はホストの値の [runner] enable (false は受け持ちが WSL)
        fn run_as(&self, mode: Mode, runner_enable: bool) -> (Vec<Outcome>, String) {
            let groups = Groups::embedded().unwrap();
            let host = if runner_enable {
                crate::host::parse("[runner]\nenable = true\n", Path::new("h.toml"), groups)
                    .unwrap()
            } else {
                HostValues::missing(Path::new("h.toml"), groups)
            };
            let mut out = Vec::new();
            let outcomes = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("repo"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.record_path().parent().unwrap().to_path_buf(),
                    host,
                    sys: &self.sys,
                    out: &mut out,
                };
                Files.run(&mut ctx, mode)
            };
            (outcomes, String::from_utf8(out).unwrap())
        }
    }

    fn write(p: &Path, s: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    const APPLY: Mode = Mode::Apply { force: false };

    #[test]
    fn copies_and_records() {
        let e = Env::new();
        let (o, out) = e.run(APPLY);
        assert_eq!(std::fs::read_to_string(e.dst_a()).unwrap(), "A1\n");
        assert_eq!(std::fs::read_to_string(e.dst_b()).unwrap(), "B1\n");
        let rec = e.records();
        assert_eq!(
            rec[e.dst_a().to_string_lossy().as_ref()],
            fsutil::sha256_bytes(b"A1\n")
        );
        assert_eq!(o[0].kind, Kind::Ok);
        assert_eq!(o[0].text, "コピー 2 / 上書き 0 / 同じ 0 / 衝突 0");
        assert!(out.contains("置いたファイルを、アプリに読み直させてください:"));
        assert!(out.contains("a.json: 読み直す"));
        // 2 回目は同じ。書かず、hint も出さない
        let (o, out) = e.run(APPLY);
        assert_eq!(o[0].text, "コピー 0 / 上書き 0 / 同じ 2 / 衝突 0");
        assert!(!out.contains("読み直させてください"));
    }

    /// clone の core.autocrlf が true なら、files の行の前に manual の行を出す (作業ツリーでなければ見ない)
    #[test]
    fn warns_when_clone_converts_line_endings() {
        let mut e = Env::new();
        e.sys = FakeSys::new(|spec| {
            let args = spec.args_lossy();
            let answer = |code: i32, line: &str| crate::process::RunResult {
                exit: crate::process::Exit::Code(code),
                output: vec![line.to_string()],
            };
            // 作業ツリーの中 (rev-parse) で、core.autocrlf が true (config)
            if args.iter().any(|a| a == "rev-parse" || a == "config") {
                answer(0, "true")
            } else {
                answer(1, "")
            }
        })
        .with_program("git", "/usr/bin/git");
        let (o, out) = e.run(Mode::Check);
        assert_eq!(o.len(), 2);
        assert_eq!(o[0].kind, Kind::Manual);
        assert!(o[0].text.contains("core.autocrlf が true"), "{:?}", o[0]);
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("config core.autocrlf false"))
        );
        assert!(o[1].text.starts_with("コピー "));
        assert!(out.contains("!! dotfiles の clone の core.autocrlf が true です"));
        // 作業ツリーでなければ (rev-parse が落ちる) 見ない
        let e = Env::new();
        let (o, _) = e.run(Mode::Check);
        assert_eq!(o.len(), 1);
    }

    #[test]
    fn empty_hint_is_not_shown() {
        let e = Env::new();
        e.t.write(
            "repo/win/manifest.toml",
            "[[files]]\nsrc = \"app/a.json\"\ndst = \"%USERPROFILE%/.app/a.json\"\nhint = \"\"\n",
        );
        let (_, out) = e.run(APPLY);
        assert!(!out.contains("読み直させてください"), "{out}");
    }

    #[test]
    fn same_content_only_records() {
        let e = Env::new();
        write(&e.dst_a(), "A1\n");
        write(&e.dst_b(), "B1\n");
        let (o, out) = e.run(APPLY);
        assert_eq!(o[0].text, "コピー 0 / 上書き 0 / 同じ 2 / 衝突 0");
        assert!(out.contains("同じです: "));
        assert_eq!(e.records().as_object().unwrap().len(), 2);
        assert!(!out.contains("読み直させてください"));
    }

    #[test]
    fn updates_when_destination_matches_record() {
        let e = Env::new();
        e.run(APPLY);
        e.t.write("repo/win/app/a.json", "A2\n");
        let (o, out) = e.run(Mode::Check);
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(out.contains("repo 側が更新された (apply で上書きする)"));
        let (o, out) = e.run(APPLY);
        assert_eq!(std::fs::read_to_string(e.dst_a()).unwrap(), "A2\n");
        assert_eq!(o[0].text, "コピー 0 / 上書き 1 / 同じ 1 / 衝突 0");
        assert!(out.contains("上書き (repo 側が更新された): "));
        assert_eq!(
            e.records()[e.dst_a().to_string_lossy().as_ref()],
            fsutil::sha256_bytes(b"A2\n")
        );
    }

    #[test]
    fn conflict_when_windows_side_changed() {
        let e = Env::new();
        e.run(APPLY);
        write(&e.dst_a(), "changed on windows\n");
        let (o, out) = e.run_as(APPLY, true);
        assert_eq!(
            std::fs::read_to_string(e.dst_a()).unwrap(),
            "changed on windows\n"
        );
        assert_eq!(o[0].kind, Kind::Manual);
        assert_eq!(o[0].text, "コピー 0 / 上書き 0 / 同じ 1 / 衝突 1");
        assert!(out.contains("は Windows 側で変わっています (前回ここへ置いた中身と違う)"));
        assert!(out.contains("   diff diff --no-index --no-color -- "));
        assert!(out.contains("dotfiles apply --steps files --force"));
        assert!(out.contains("Copy-Item -LiteralPath"));
        // 受け持ちが WSL のホストでは、止まる apply ではなく WSL の手順を出す
        let (o, out) = e.run_as(Mode::Check, false);
        assert!(out.contains("WSL で nix/scripts/bootstrap-windows-files.sh --force"));
        assert!(!out.contains("dotfiles apply --steps files --force"));
        assert!(o[0].notes[0].contains("受け持ちは WSL の setup"));
        assert_eq!(
            e.records()[e.dst_a().to_string_lossy().as_ref()],
            fsutil::sha256_bytes(b"A1\n")
        );
    }

    #[test]
    fn conflict_without_record_says_so() {
        let e = Env::new();
        write(&e.dst_a(), "made by the app\n");
        let (o, out) = e.run(Mode::Check);
        assert_eq!(o[0].kind, Kind::Manual);
        assert!(out.contains("置いた記録が無く"));
        assert!(!out.contains("前回ここへ置いた中身と違う"));
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("受け持ちは WSL の setup"))
        );
    }

    #[test]
    fn check_and_dry_run_never_write_on_conflict() {
        let e = Env::new();
        e.run(APPLY);
        write(&e.dst_a(), "changed on windows\n");
        let before = std::fs::read_to_string(e.record_path()).unwrap();
        for mode in [
            Mode::Check,
            Mode::DryRun { force: false },
            Mode::DryRun { force: true },
        ] {
            let _ = e.run(mode);
            assert_eq!(
                std::fs::read_to_string(e.dst_a()).unwrap(),
                "changed on windows\n",
                "{mode:?}"
            );
            assert_eq!(
                std::fs::read_to_string(e.record_path()).unwrap(),
                before,
                "{mode:?}"
            );
        }
    }

    /// apply --dry-run --force は、衝突を「上書き (--force)」として予告する (WSL の --dry-run --force と同じ)
    #[test]
    fn dry_run_with_force_previews_overwrite() {
        let e = Env::new();
        write(&e.dst_a(), "made by the app\n");
        let (o, out) = e.run(Mode::DryRun { force: true });
        assert!(out.contains("[dry-run] 上書き (--force): "), "{out}");
        assert!(!out.contains("衝突:"));
        assert_eq!(o[0].kind, Kind::Fix);
        assert_eq!(o[0].text, "[dry-run] コピー 1 / 上書き 1 / 同じ 0 / 衝突 0");
        assert_eq!(
            std::fs::read_to_string(e.dst_a()).unwrap(),
            "made by the app\n"
        );
    }

    #[test]
    fn force_overwrites_conflicts() {
        let e = Env::new();
        write(&e.dst_a(), "made by the app\n");
        let (o, out) = e.run(Mode::Apply { force: true });
        assert_eq!(std::fs::read_to_string(e.dst_a()).unwrap(), "A1\n");
        assert_eq!(o[0].kind, Kind::Ok);
        assert!(out.contains("上書き (--force): "));
        assert_eq!(
            e.records()[e.dst_a().to_string_lossy().as_ref()],
            fsutil::sha256_bytes(b"A1\n")
        );
    }

    #[test]
    fn dry_run_and_check_write_nothing() {
        let e = Env::new();
        write(&e.dst_b(), "B1\n");
        let (o, out) = e.run(Mode::DryRun { force: false });
        assert!(out.contains("[dry-run] コピー: "));
        assert_eq!(o[0].text, "[dry-run] コピー 1 / 上書き 0 / 同じ 1 / 衝突 0");
        assert_eq!(o[0].kind, Kind::Missing);
        let (o, out) = e.run(Mode::Check);
        assert!(out.contains("無い (apply でコピーする): "));
        assert_eq!(o[0].kind, Kind::Missing);
        assert!(!e.dst_a().exists());
        assert!(!e.record_path().exists());
    }

    #[test]
    fn destination_directory_is_an_error() {
        let e = Env::new();
        std::fs::create_dir_all(e.dst_a()).unwrap();
        let (o, out) = e.run(APPLY);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(out.contains("!! 置き先がディレクトリです: "));
        assert!(o[0].text.ends_with(" / エラー 1"));
    }

    #[test]
    fn broken_record_stops() {
        let e = Env::new();
        write(&e.record_path(), "not json");
        let (o, out) = e.run(APPLY);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(out.contains("壊れています"));
        assert!(!e.dst_a().exists());
    }

    #[test]
    fn manifest_error_stops() {
        let e = Env::new();
        e.t.write("repo/win/manifest.toml", "x = 1\n");
        let (o, _) = e.run(Mode::Check);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(o[0].notes[0].contains("知らないキーがあります"));
    }

    #[test]
    fn no_files_is_ok() {
        let e = Env::new();
        e.t.write("repo/win/manifest.toml", "");
        let (o, out) = e.run(APPLY);
        assert_eq!(o[0].kind, Kind::Ok);
        assert!(out.contains("配るファイルはありません"));
    }
}
