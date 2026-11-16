//! 引数を読み、コマンドを流す。
//!
//! 引数は手で読む (clap を足さない)。誤りは使い方と一緒に stderr へ出し、終了コード 2。

use crate::context::Ctx;
use crate::host::{self, Groups};
use crate::manifest::{self, Roots};
use crate::process::{CommandSpec, RealSys, Sys};
use crate::runner;
use crate::steps::{self, Mode, Step};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const USAGE: &str = "\
dotfiles の Windows 側の runner (win/README.md の「runner」)。

使い方:
  dotfiles check   [--steps <id>,…] [--host-file <path>]   手順を順に確かめる (何も書かない)
  dotfiles apply   [--dry-run] [--force] [--steps <id>,…] [--host-file <path>]
                                                          手順を順に揃える (ホストの値の runner.enable = true のときだけ)
  dotfiles list    [--host-file <path>]                   手順と、このホストでの on/off・受け持ちを出す
  dotfiles manifest [--json] [--windows-home <path>]      win/manifest.toml を検証する (--json は置き先を解いた計画)

  --dry-run         apply がすることを出すだけ (何も書かない。runner.enable によらない)
  --force           files の衝突 (Windows 側で変わっていた) も上書きする
  --steps <id>,…    流す手順を id で絞る (id は dotfiles list で見る)
  --host-file <path> ホストの値のファイル (既定は dotfiles-private の win/hosts/<ユーザー>@<PC>.toml)
  --windows-home <path> manifest の置き先を、この Windows のホストの下として解く (既定は環境変数)
  --repo <path>     dotfiles の clone (既定は runner を build した clone。試すとき)

終了コード: 0 直すことが無い・3 入っていない・無いものだけ (apply で揃う)・1 ほかに直すことがある・2 runner が動けない";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Check,
    Apply,
    List,
    Manifest,
    Help,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Args {
    pub command: Command,
    pub dry_run: bool,
    pub force: bool,
    pub steps: Option<Vec<String>>,
    pub host_file: Option<PathBuf>,
    pub json: bool,
    pub windows_home: Option<PathBuf>,
    pub repo: Option<PathBuf>,
}

impl Args {
    fn new(command: Command) -> Self {
        Args {
            command,
            dry_run: false,
            force: false,
            steps: None,
            host_file: None,
            json: false,
            windows_home: None,
            repo: None,
        }
    }
}

/// 引数を読む。誤りは文で返す (呼ぶ側が使い方と一緒に出す)。
pub fn parse(args: &[String]) -> Result<Args, String> {
    let mut iter = args.iter();
    let Some(first) = iter.next() else {
        return Err("コマンドがありません".to_string());
    };
    let command = match first.as_str() {
        "check" => Command::Check,
        "apply" => Command::Apply,
        "list" => Command::List,
        "manifest" => Command::Manifest,
        "help" | "-h" | "--help" => return Ok(Args::new(Command::Help)),
        other => return Err(format!("知らないコマンドです: {other}")),
    };
    let mut a = Args::new(command);
    while let Some(arg) = iter.next() {
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (arg.as_str(), None),
        };
        let mut value = |name: &str| -> Result<String, String> {
            match &inline {
                Some(v) => Ok(v.clone()),
                None => iter
                    .next()
                    .cloned()
                    .ok_or_else(|| format!("{name} の値がありません")),
            }
        };
        let allowed = |commands: &[Command]| -> Result<(), String> {
            if commands.contains(&command) {
                Ok(())
            } else {
                Err(format!(
                    "{name} は {} には付けられません",
                    command_name(command)
                ))
            }
        };
        match name {
            "-h" | "--help" => return Ok(Args::new(Command::Help)),
            "--dry-run" => {
                allowed(&[Command::Apply])?;
                a.dry_run = true;
            }
            "--force" => {
                allowed(&[Command::Apply])?;
                a.force = true;
            }
            "--json" => {
                allowed(&[Command::Manifest])?;
                a.json = true;
            }
            "--steps" => {
                allowed(&[Command::Check, Command::Apply])?;
                let v = value(name)?;
                let ids: Vec<String> = v
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect();
                if ids.is_empty() {
                    return Err("--steps に手順の id がありません".to_string());
                }
                a.steps = Some(ids);
            }
            "--host-file" => {
                allowed(&[Command::Check, Command::Apply, Command::List])?;
                a.host_file = Some(PathBuf::from(value(name)?));
            }
            "--windows-home" => {
                allowed(&[Command::Manifest])?;
                a.windows_home = Some(PathBuf::from(value(name)?));
            }
            "--repo" => a.repo = Some(PathBuf::from(value(name)?)),
            other => return Err(format!("知らない引数です: {other}")),
        }
        if inline.is_some() && matches!(name, "--dry-run" | "--force" | "--json") {
            return Err(format!("{name} は値を取りません"));
        }
    }
    Ok(a)
}

fn command_name(c: Command) -> &'static str {
    match c {
        Command::Check => "check",
        Command::Apply => "apply",
        Command::List => "list",
        Command::Manifest => "manifest",
        Command::Help => "help",
    }
}

/// `dotfiles-win` の本体。終了コードを返す。
pub fn main(args: Vec<String>) -> i32 {
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    run(&args, &RealSys, &mut stdout.lock(), &mut stderr.lock())
}

/// runner を build した clone (`win/runner` の 2 つ上)。
fn default_repo() -> PathBuf {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    dir.parent()
        .and_then(Path::parent)
        .unwrap_or(dir)
        .to_path_buf()
}

/// PC の名前 (`hostname` の出力を小文字に。読めなければ `%COMPUTERNAME%` を小文字に)。
fn pc_name(sys: &dyn Sys) -> Option<String> {
    let r = sys.run(
        &CommandSpec::new("hostname").timeout(Duration::from_secs(10)),
        &mut |_| {},
    );
    if r.code() == Some(0)
        && let Some(name) = r.output.iter().map(|l| l.trim()).find(|l| !l.is_empty())
    {
        return Some(name.to_lowercase());
    }
    sys.env("COMPUTERNAME")
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
}

/// 引数・環境・出力を受けて流す (試験はここを呼ぶ)。
pub fn run(args: &[String], sys: &dyn Sys, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let a = match parse(args) {
        Ok(a) => a,
        Err(e) => {
            let _ = writeln!(err, "!! {e}\n\n{USAGE}");
            return 2;
        }
    };
    let repo = a.repo.clone().unwrap_or_else(default_repo);
    match a.command {
        Command::Help => {
            let _ = writeln!(out, "{USAGE}");
            0
        }
        Command::Manifest => manifest_command(&a, &repo, sys, out, err),
        Command::Check | Command::Apply | Command::List => {
            match steps_command(&a, repo, sys, out) {
                Ok(code) => code,
                Err(e) => {
                    let _ = writeln!(err, "!! {e}");
                    2
                }
            }
        }
    }
}

fn manifest_command(
    a: &Args,
    repo: &Path,
    sys: &dyn Sys,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> i32 {
    let roots = match &a.windows_home {
        Some(h) => Roots::from_home(h),
        None => Roots::from_env(&|n| sys.env(n))
            .unwrap_or_else(|_| Roots::from_home(Path::new("C:/Users/CHECK"))),
    };
    match manifest::load(repo, &roots) {
        Ok(plan) => {
            if a.json {
                let _ = writeln!(out, "{}", manifest::plan_json(&plan));
            } else {
                let _ = writeln!(out, "win/manifest.toml: OK ({} 件)", plan.files.len());
            }
            0
        }
        Err(e) => {
            let _ = writeln!(err, "!! {e}");
            1
        }
    }
}

fn steps_command(
    a: &Args,
    repo: PathBuf,
    sys: &dyn Sys,
    out: &mut dyn Write,
) -> Result<i32, String> {
    let all = steps::all();
    let selected: Vec<Box<dyn Step>> = match &a.steps {
        None => all,
        Some(ids) => {
            for id in ids {
                if !all.iter().any(|s| s.info().id == id) {
                    return Err(format!("知らない手順です: {id} (dotfiles list で見る)"));
                }
            }
            all.into_iter()
                .filter(|s| ids.iter().any(|id| id == s.info().id))
                .collect()
        }
    };
    let groups = Groups::embedded()?;
    let host_path = match &a.host_file {
        Some(p) => p.clone(),
        None => {
            let user = sys
                .env("USERNAME")
                .filter(|s| !s.is_empty())
                .ok_or("環境変数 USERNAME がありません (ホストの値の名前を決められない。--host-file で渡す)")?;
            let pc = pc_name(sys).ok_or(
                "PC の名前が分かりません (hostname も COMPUTERNAME も読めない。--host-file で渡す)",
            )?;
            host::default_path(&repo, &user, &pc)
        }
    };
    let host = host::load(&host_path, groups)?;
    // list は置き先を使わないので、環境変数が無くても流せる (試すとき)
    let roots = match Roots::from_env(&|n| sys.env(n)) {
        Ok(r) => r,
        Err(_) if a.command == Command::List => Roots::from_home(Path::new("C:/Users/CHECK")),
        Err(e) => return Err(e),
    };
    let state_dir = roots.local_app_data.join("dotfiles").join("state");
    let mut ctx = Ctx {
        repo,
        roots,
        state_dir,
        host,
        sys,
        out,
    };
    match a.command {
        Command::List => {
            runner::list(&mut ctx, &selected);
            Ok(0)
        }
        Command::Check => {
            ctx.say("==> dotfiles check (確かめるだけ。何も書かない)");
            runner::describe_host(&mut ctx);
            let rows = runner::execute(&mut ctx, Mode::Check, &selected);
            Ok(runner::finish(&mut ctx, "check", &rows))
        }
        _ if a.dry_run => {
            ctx.say("==> dotfiles apply --dry-run (することを出すだけ。何も書かない)");
            runner::describe_host(&mut ctx);
            if let Some(b) = runner::apply_blocker(&ctx.host) {
                ctx.say(format!("※ 本番の apply は止まる: {}", b.text));
            }
            let rows = runner::execute(&mut ctx, Mode::DryRun, &selected);
            Ok(runner::finish(&mut ctx, "apply --dry-run", &rows))
        }
        _ => {
            ctx.say("==> dotfiles apply");
            runner::describe_host(&mut ctx);
            if let Some(b) = runner::apply_blocker(&ctx.host) {
                let mut rows = runner::host_rows(&ctx.host);
                rows.push(b);
                return Ok(runner::finish(&mut ctx, "apply", &rows));
            }
            let rows = runner::execute(&mut ctx, Mode::Apply { force: a.force }, &selected);
            Ok(runner::finish(&mut ctx, "apply", &rows))
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - コマンドと引数の読み方 (`--opt value` と `--opt=value`・`--steps` の分け方)
    //! - コマンドが無い・知らない・付けられない引数・値が無いのは誤り (呼ぶ側が終了コード 2 にする)

    use super::*;

    fn p(args: &[&str]) -> Result<Args, String> {
        parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn reads_commands() {
        assert_eq!(p(&["check"]).unwrap().command, Command::Check);
        assert_eq!(p(&["apply"]).unwrap().command, Command::Apply);
        assert_eq!(p(&["list"]).unwrap().command, Command::List);
        assert_eq!(p(&["manifest"]).unwrap().command, Command::Manifest);
        assert_eq!(p(&["--help"]).unwrap().command, Command::Help);
        assert_eq!(p(&["check", "-h"]).unwrap().command, Command::Help);
    }

    #[test]
    fn reads_options() {
        let a = p(&[
            "apply",
            "--dry-run",
            "--force",
            "--steps",
            "files, ntn",
            "--host-file=h.toml",
            "--repo",
            "/r",
        ])
        .unwrap();
        assert!(a.dry_run && a.force);
        assert_eq!(a.steps, Some(vec!["files".to_string(), "ntn".to_string()]));
        assert_eq!(a.host_file, Some(PathBuf::from("h.toml")));
        assert_eq!(a.repo, Some(PathBuf::from("/r")));
        let m = p(&["manifest", "--json", "--windows-home", "/mnt/c/Users/x"]).unwrap();
        assert!(m.json);
        assert_eq!(m.windows_home, Some(PathBuf::from("/mnt/c/Users/x")));
    }

    #[test]
    fn rejects_bad_arguments() {
        for args in [
            &[][..],
            &["frobnicate"][..],
            &["check", "--dry-run"][..],
            &["list", "--force"][..],
            &["check", "--json"][..],
            &["apply", "--steps"][..],
            &["apply", "--steps", ","][..],
            &["check", "--what"][..],
            &["apply", "--dry-run=yes"][..],
            &["manifest", "--host-file", "x"][..],
        ] {
            assert!(p(args).is_err(), "{args:?}");
        }
    }

    mod flow {
        //! ## 確かめること (コマンドの流れ。偽の Sys と一時ディレクトリで)
        //!
        //! - check は何も書かず、入っていないものだけなら 3。apply は runner.enable = true のホストだけ揃え、でなければ止めて 1
        //! - apply --dry-run は何も書かず、本番が止まることを知らせる
        //! - ホストの値の既定の場所は、USERNAME と hostname (小文字) から。list は環境変数が無くても流せる
        //! - 知らない手順・ホストの値の誤り・環境変数が無いのは 2。manifest の誤りは 1

        use super::super::*;
        use crate::process::{Exit, RunResult};
        use crate::testutil::{FakeSys, TempDir};

        struct World {
            t: TempDir,
        }

        impl World {
            fn new(host: Option<&str>) -> Self {
                let t = TempDir::new("cli");
                t.write(
                    "g/dotfiles/win/manifest.toml",
                    "[[files]]\nsrc = \"app/a.json\"\ndst = \"%USERPROFILE%/.app/a.json\"\n",
                );
                t.write("g/dotfiles/win/app/a.json", "A\n");
                if let Some(h) = host {
                    t.write("g/dotfiles-private/win/hosts/polle@pjp-raiden.toml", h);
                }
                World { t }
            }

            fn sys(&self) -> FakeSys {
                let home = self.t.path().join("home");
                FakeSys::new(|c| {
                    if c.program == Path::new("hostname") {
                        RunResult {
                            exit: Exit::Code(0),
                            output: vec!["PJP-Raiden".into()],
                        }
                    } else {
                        RunResult {
                            exit: Exit::Code(0),
                            output: vec![],
                        }
                    }
                })
                .with_env("USERNAME", "polle")
                .with_env("USERPROFILE", &home.to_string_lossy())
                .with_env(
                    "APPDATA",
                    &home.join("AppData").join("Roaming").to_string_lossy(),
                )
                .with_env(
                    "LOCALAPPDATA",
                    &home.join("AppData").join("Local").to_string_lossy(),
                )
            }

            fn run(&self, args: &[&str]) -> (i32, String, String) {
                self.run_with(&self.sys(), args)
            }

            fn run_with(&self, sys: &FakeSys, args: &[&str]) -> (i32, String, String) {
                let mut full: Vec<String> = args.iter().map(|s| s.to_string()).collect();
                full.push("--repo".into());
                full.push(
                    self.t
                        .path()
                        .join("g")
                        .join("dotfiles")
                        .to_string_lossy()
                        .into_owned(),
                );
                let (mut out, mut err) = (Vec::new(), Vec::new());
                let code = run(&full, sys, &mut out, &mut err);
                (
                    code,
                    String::from_utf8(out).unwrap(),
                    String::from_utf8(err).unwrap(),
                )
            }

            fn dst(&self) -> PathBuf {
                self.t.path().join("home").join(".app").join("a.json")
            }

            fn record(&self) -> PathBuf {
                self.t
                    .path()
                    .join("home")
                    .join("AppData")
                    .join("Local")
                    .join("dotfiles")
                    .join("state")
                    .join("windows-files.deployed.json")
            }
        }

        #[test]
        fn check_writes_nothing() {
            let w = World::new(Some("group = \"personal\"\n"));
            let (code, out, _) = w.run(&["check", "--steps", "files"]);
            assert_eq!(code, 3, "{out}");
            assert!(out.contains("==> dotfiles check"));
            assert!(out.contains("polle@pjp-raiden.toml (グループ personal)"));
            assert!(out.contains("受け持ち: WSL の setup"));
            assert!(out.contains("⚠️ 入っていない・無いものがある → dotfiles apply で揃える ⚠️"));
            assert!(!w.dst().exists());
            assert!(!w.record().exists());
        }

        #[test]
        fn apply_stops_unless_runner_enabled() {
            let w = World::new(Some(""));
            let (code, out, _) = w.run(&["apply", "--steps", "files"]);
            assert_eq!(code, 1);
            assert!(out.contains(
                "受け持ちは WSL の setup (runner.enable が true でない) なので apply は止めた"
            ));
            assert!(out.contains("止めたので何も変えていない"));
            assert!(!w.dst().exists());

            let (code, out, _) = w.run(&["apply", "--dry-run", "--steps", "files"]);
            assert_eq!(code, 3);
            assert!(out.contains("※ 本番の apply は止まる"));
            assert!(out.contains("[dry-run] コピー: "));
            assert!(!w.dst().exists());
        }

        #[test]
        fn apply_copies_when_runner_enabled() {
            let w = World::new(Some("[runner]\nenable = true\n"));
            let (code, out, _) = w.run(&["apply", "--steps", "files"]);
            assert_eq!(code, 0, "{out}");
            assert_eq!(std::fs::read_to_string(w.dst()).unwrap(), "A\n");
            assert!(w.record().exists());
            assert!(out.contains("✔ 直すことはありません"));
            let (code, _, _) = w.run(&["check", "--steps", "files"]);
            assert_eq!(code, 0);
        }

        #[test]
        fn missing_host_file_checks_with_defaults_but_blocks_apply() {
            let w = World::new(None);
            let (code, out, _) = w.run(&["check", "--steps", "files"]);
            assert_eq!(code, 1);
            assert!(out.contains("ホストの値が無い ("));
            let (code, out, _) = w.run(&["apply", "--steps", "files"]);
            assert_eq!(code, 1);
            assert!(out.contains("ホストの値が無いので apply は止めた"));
            assert!(!w.dst().exists());
        }

        #[test]
        fn list_shows_steps_without_windows_env() {
            let w = World::new(Some("[tools]\nwindowsTypeClipboard = true\n"));
            let sys = FakeSys::new(|_| RunResult {
                exit: Exit::Code(0),
                output: vec!["pjp-raiden".into()],
            })
            .with_env("USERNAME", "polle");
            let (code, out, _) = w.run_with(&sys, &["list"]);
            assert_eq!(code, 0, "{out}");
            assert!(out.contains("[90] files"));
            assert!(out.contains("runner にまだ無い。WSL の bootstrap-windows-powertoys.sh"));
            assert!(out.contains("[97] type-clipboard"));
            assert!(!out.contains("type-clipboard を固定した版で入れる (ずれていても入れ替えない) (windowsTypeClipboard"));
        }

        #[test]
        fn errors_exit_2() {
            let w = World::new(Some(""));
            let (code, _, err) = w.run(&["check", "--steps", "nope"]);
            assert_eq!(code, 2);
            assert!(err.contains("知らない手順です: nope"));

            let bad = World::new(Some("grop = 1\n"));
            let (code, _, err) = bad.run(&["check"]);
            assert_eq!(code, 2);
            assert!(err.contains("知らないキーがあります"));

            let no_env = FakeSys::new(|_| RunResult {
                exit: Exit::Code(1),
                output: vec![],
            });
            let (code, _, err) = w.run_with(&no_env, &["check"]);
            assert_eq!(code, 2);
            assert!(err.contains("USERNAME"));
        }

        #[test]
        fn manifest_command() {
            let w = World::new(None);
            let (code, out, _) = w.run(&["manifest"]);
            assert_eq!(code, 0);
            assert_eq!(out, "win/manifest.toml: OK (1 件)\n");
            let (code, out, _) = w.run(&["manifest", "--json", "--windows-home", "/mnt/c/Users/x"]);
            assert_eq!(code, 0);
            let v: serde_json::Value = serde_json::from_str(&out).unwrap();
            assert_eq!(v["files"][0]["repoPath"], "win/app/a.json");
            w.t.write("g/dotfiles/win/manifest.toml", "x = 1\n");
            let (code, _, err) = w.run(&["manifest"]);
            assert_eq!(code, 1);
            assert!(err.contains("知らないキーがあります"));
        }

        #[test]
        fn hostname_falls_back_to_computername() {
            let w = World::new(Some(""));
            let sys = FakeSys::new(|_| RunResult {
                exit: Exit::SpawnFailed("x".into()),
                output: vec![],
            })
            .with_env("USERNAME", "polle")
            .with_env("COMPUTERNAME", "PJP-RAIDEN");
            let (code, out, _) = w.run_with(&sys, &["list"]);
            assert_eq!(code, 0);
            assert!(
                out.contains("polle@pjp-raiden.toml (グループ personal)"),
                "{out}"
            );
        }
    }
}
