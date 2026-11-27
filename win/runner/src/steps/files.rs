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
//! manifest から消したファイルは Windows 側から消さない (アプリが持つファイルなので)。`--force` の上書きは退避しない (WSL と同じ)。
//!
//! 判定は ssh-config・port-forward と共通の `deploy::judge` (書く中身を渡す形)。

use super::deploy::{self, Action, Problem, Tally};
use super::ps1::ps_quote;
use super::{Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::manifest;
use crate::record::Records;
use crate::report::Kind;

pub const RECORD_FILE: &str = "windows-files.deployed.json";

pub struct Files;

impl Step for Files {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "files",
            order: 90,
            title: "win/manifest.toml のファイルを配る",
            gate: super::Gate::Always,
            ported: true,
            windows_only: false,
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
        let repo = ctx.repo.clone();
        let crlf = deploy::autocrlf_outcome(ctx, &repo, "dotfiles");
        let force = mode.force();
        let mut tally = Tally::default();
        let mut hints = Vec::new();

        for f in &plan.files {
            let dst_key = f.dst.to_string_lossy().into_owned();
            let bytes = match std::fs::read(&f.src) {
                Ok(b) => b,
                Err(e) => {
                    ctx.say(format!(
                        "!! コピー元が読めません: {} ({e})",
                        f.src.display()
                    ));
                    tally.errors += 1;
                    continue;
                }
            };
            let want = fsutil::sha256_bytes(&bytes);
            let recorded = records.get(&dst_key).map(str::to_string);
            let action =
                match deploy::judge(&f.dst, &want, recorded.as_deref(), force, &deploy::never) {
                    Ok(a) => a,
                    Err(Problem::Directory) => {
                        ctx.say(format!("!! 置き先がディレクトリです: {dst_key}"));
                        tally.errors += 1;
                        continue;
                    }
                    Err(Problem::Unreadable(e)) => {
                        ctx.say(format!("!! 置き先が読めません: {dst_key} ({e})"));
                        tally.errors += 1;
                        continue;
                    }
                };
            match action {
                Action::Same => {
                    tally.count(action);
                    ctx.say(format!("同じです: {dst_key}"));
                    if recorded.as_deref() != Some(want.as_str()) && mode.writes() {
                        records.set(&dst_key, &want);
                    }
                }
                Action::Conflict => {
                    tally.count(action);
                    if recorded.is_some() {
                        ctx.say(format!(
                            "!! 衝突: {dst_key} は Windows 側で変わっています (前回ここへ置いた中身と違う)。"
                        ));
                    } else {
                        ctx.say(format!(
                            "!! 衝突: {dst_key} は、置いた記録が無く、repo と中身が違います (置く前から Windows 側にあった。アプリが作ったか、手で設定したもの。受け持ちを切り替える前なら、WSL が配った中身とこの clone の中身が違う)。"
                        ));
                    }
                    deploy::show_diff(ctx, &f.dst, &f.src);
                    let repo_file = ctx.repo_path(&f.repo_path);
                    ctx.say(format!(
                        "   Windows 側の中身を残すなら: Copy-Item -LiteralPath '{}' -Destination '{}' (PowerShell。取り込んだら repo で commit する)",
                        ps_quote(&dst_key),
                        ps_quote(&repo_file.to_string_lossy())
                    ));
                    // 受け持ちが WSL の間は runner の apply は files を流さないので、WSL の手順を出す
                    let again = deploy::force_command(ctx, "files");
                    ctx.say(format!("   repo 側で上書きするなら:   {again}"));
                }
                Action::Copy | Action::Update | Action::Replace | Action::Force => {
                    let label = match action {
                        Action::Copy => "コピー",
                        Action::Update | Action::Replace => "上書き (repo 側が更新された)",
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
                        Mode::Apply { .. } => match deploy::write(&f.dst, &bytes, false) {
                            Ok(_) => {
                                records.set(&dst_key, &want);
                                ctx.say(format!("{label}: {dst_key}"));
                                // runner の案内 (runnerHint) があれば、hint (WSL の setup と共有。setup --update などを指す) の代わりに出す
                                // (runner が files を置くのは受け持ちが runner のホストだけ)。空の案内は出さない (WSL の [[ -n ${hint} ]] と同じ)
                                if let Some(h) = f
                                    .runner_hint
                                    .as_deref()
                                    .or(f.hint.as_deref())
                                    .filter(|h| !h.is_empty())
                                {
                                    hints.push(format!("{dst_key}: {h}"));
                                }
                            }
                            Err(e) => {
                                ctx.say(format!("!! 書けません: {dst_key} ({e})"));
                                tally.errors += 1;
                                continue;
                            }
                        },
                    }
                    tally.count(action);
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
            tally.errors += 1;
        }
        if !hints.is_empty() {
            ctx.say("");
            ctx.say("置いたファイルを、アプリに読み直させてください:");
            for h in &hints {
                ctx.say(format!("  {h}"));
            }
        }

        let summary = tally.summary(mode, false);
        ctx.say("");
        ctx.say(&summary);

        let mut outcome = Outcome::new(tally.kind(mode), summary);
        if tally.conflicts > 0 {
            outcome = outcome.note(deploy::conflict_note(
                ctx,
                "files",
                "Windows 側の中身を repo へ取り込む",
                "この clone",
            ));
        }
        crlf.into_iter().chain(std::iter::once(outcome)).collect()
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
    //!
    //! runner だけで確かめること (本物の repo):
    //!
    //! - starship.toml (Linux の home-manager と同じ `nix/files/starship.toml`) を、starship が読む `%USERPROFILE%\.config\starship.toml` に
    //!   置く。Unix の shell で判定・出力する custom module は `os` で Windows では出さない

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

    /// runner の案内 (runnerHint) があれば hint (WSL の setup と共有) の代わりに出し、無ければ hint を出す。runner が files を置くのは受け持ちが
    /// runner のホストだけなので、WSL の setup の手 (setup --update・bootstrap-windows-*.sh) を案内しない
    #[test]
    fn runner_hint_replaces_the_shared_hint() {
        let e = Env::new();
        e.t.write(
            "repo/win/manifest.toml",
            "[[files]]\nsrc = \"app/a.json\"\ndst = \"%USERPROFILE%/.app/a.json\"\nhint = \"setup --update でも確かめる\"\nrunnerHint = \"dotfiles check の手順 a でも確かめる\"\n\n[[files]]\nsrc = \"app/b.toml\"\ndst = \"%APPDATA%/app/b.toml\"\nhint = \"読み直す\"\n",
        );
        let (_, out) = e.run_as(APPLY, true);
        assert!(
            out.contains("a.json: dotfiles check の手順 a でも確かめる"),
            "{out}"
        );
        assert!(!out.contains("setup --update"), "{out}");
        assert!(out.contains("b.toml: 読み直す"), "{out}");
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

    /// custom module の `shell` に書くと、Windows の starship が PATH から引いてしまう Unix の shell (拡張子を除いた名前を小文字で比べる)
    const UNIX_SHELLS: [&str; 8] = ["sh", "bash", "dash", "zsh", "ksh", "mksh", "ash", "fish"];

    /// 本物の manifest で runner が出す案内 (runnerHint、無ければ hint) は、WSL の setup の手を指さない (runner が files を置くのは受け持ちが
    /// runner のホストだけで、WSL の無いホストもある)
    #[test]
    fn real_repo_runner_hints_do_not_point_to_wsl() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let plan = manifest::load(&repo, &Roots::from_home(Path::new("/mnt/c/Users/u"))).unwrap();
        let wsl_only = [
            "setup --update",
            "setup で流した",
            "bootstrap-windows-",
            "dotfiles.wsl.",
            "WSL の setup",
        ];
        let mut bad = Vec::new();
        for f in &plan.files {
            let Some(h) = f.runner_hint.as_deref().or(f.hint.as_deref()) else {
                continue;
            };
            if let Some(w) = wsl_only.iter().find(|w| h.contains(*w)) {
                bad.push(format!("{} ({w}): {h}", f.repo_path));
            }
        }
        assert!(
            bad.is_empty(),
            "WSL の手を指す runner の案内:\n{}",
            bad.join("\n")
        );
    }

    /// 本物の manifest の starship.toml: Linux の home-manager (`nix/home/modules/files.nix`) と同じ `nix/files/starship.toml` を、
    /// STARSHIP_CONFIG の無い starship が読む `<home>\.config\starship.toml` (starship 1.27 の `dirs::home_dir()` の下) に置く。
    /// 同じファイルを Windows の starship も読むので、Unix の shell で判定・出力する custom module は `os` で Windows を外す。Windows の
    /// starship は `shell` を PATH から引くので、sh を PATH に足した PC ではプロンプトのたびに起こし、bash は WSL の `bash.exe`
    /// (WindowsApps) に当たって WSL を起こす。`os = 'unix'` なら Windows では shell を探さずに飛ばし、Linux と macOS ではこれまでどおり判定する
    #[test]
    fn real_repo_starship_toml() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let home = Path::new("/mnt/c/Users/u");
        let plan = manifest::load(&repo, &Roots::from_home(home)).unwrap();
        let f = plan
            .files
            .iter()
            .find(|f| f.repo_path == "nix/files/starship.toml")
            .expect("manifest に nix/files/starship.toml がある");
        assert_eq!(f.dst, home.join(".config").join("starship.toml"));

        let config: toml::Table = std::fs::read_to_string(&f.src)
            .unwrap()
            .parse()
            .expect("starship.toml が TOML として読める");
        let custom = config
            .get("custom")
            .and_then(toml::Value::as_table)
            .expect("[custom.*] がある");
        let mut unix_only = Vec::new();
        for (name, m) in custom {
            let m = m
                .as_table()
                .unwrap_or_else(|| panic!("custom.{name} が表でない"));
            if m.get("disabled").and_then(toml::Value::as_bool) == Some(true) {
                continue;
            }
            // shell は文字列 1 つか、文字列の並び (頭が shell の実行ファイル)
            let shell = match m.get("shell") {
                Some(toml::Value::String(s)) => Some(s.as_str()),
                Some(toml::Value::Array(a)) => a.first().and_then(toml::Value::as_str),
                _ => None,
            };
            let Some(stem) = shell
                .and_then(|s| Path::new(s).file_stem())
                .map(|s| s.to_string_lossy().to_lowercase())
            else {
                continue;
            };
            if !UNIX_SHELLS.contains(&stem.as_str()) {
                continue;
            }
            let os = m.get("os").and_then(toml::Value::as_str);
            assert!(
                os.is_some_and(|os| !os.is_empty() && os != "windows"),
                "custom.{name} は {stem} で判定するので、os で Windows を外す (os = 'unix')。今は {os:?}"
            );
            unix_only.push(name.as_str());
        }
        // 今の custom module は、ssh と herdr の pane で PJP_SSH_CLIENT が届いていないことを出す 1 つ (sh で判定する)
        assert_eq!(unix_only, ["pjp_ssh_client"]);
    }
}
