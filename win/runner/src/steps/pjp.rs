//! pjp (order 55): claude-skills の Rust の道具の入口 (shim の `pjp`) を入れ、clone の道具を作る (`pjp --build`)。Linux の
//! `nix/scripts/bootstrap-pjp.sh` と同じ判断:
//!
//! - shim (`<CARGO_HOME か %USERPROFILE%\.cargo>\bin\pjp.exe`) が無い・起きない・`pjp --version` の版が clone の `crates/pjp-shim` の版と違う
//!   ときだけ、`cargo install --locked --root <CARGO_HOME> --target-dir <使い捨ての dir> --path <clone>\crates\pjp-shim` を打つ。cargo は clone の
//!   中で、clone の `rust-toolchain.toml` の channel を `RUSTUP_TOOLCHAIN` にして打つ (Windows の rustup は既定の toolchain を持たず、`cargo run`
//!   で起こした runner には runner の版の `RUSTUP_TOOLCHAIN` が付いているため)。入れた後に版を読み直す
//! - 続けて毎回 `pjp --build` (`PJP_SKILLS_DIR=<clone>`。runner の `RUSTUP_TOOLCHAIN` は外し、shim が clone の版を決める)
//!
//! check は shim だけを見る (build しない。check は何も書かない)。dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*。

use super::claude_skills::clone_dir;
use super::ps1::run_streaming;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::process::CommandSpec;
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// cargo install の待ちの上限 (shim と依存を使い捨ての target dir で作る)
const INSTALL_SECS: u64 = 1800;
/// pjp --build の待ちの上限 (初めては道具を全部作る)
const BUILD_SECS: u64 = 3600;

/// TOML のファイル `path` の `[table]` の `key` の文字列。読めない・無い・文字列でないなら None。
pub fn read_toml_string(path: &Path, table: &str, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let t: toml::Table = text.parse().ok()?;
    t.get(table)?.get(key)?.as_str().map(str::to_string)
}

/// cargo install の入れ先 (`CARGO_HOME`、無ければ `%USERPROFILE%\.cargo`)。shim と同じ。
pub fn cargo_root(ctx: &Ctx) -> PathBuf {
    match ctx.sys.env("CARGO_HOME").filter(|s| !s.is_empty()) {
        Some(h) => PathBuf::from(h),
        None => ctx.roots.user_profile.join(".cargo"),
    }
}

/// 入れる shim のパス (`<cargo_root>\bin\pjp.exe`)。
pub fn shim_path(ctx: &Ctx) -> PathBuf {
    cargo_root(ctx)
        .join("bin")
        .join(format!("pjp{}", std::env::consts::EXE_SUFFIX))
}

/// 使う cargo (`CARGO_HOME\bin` → `%USERPROFILE%\.cargo\bin` → PATH。shim の locate_cargo と同じ順)。
fn locate_cargo(ctx: &Ctx) -> Option<PathBuf> {
    let exe = format!("cargo{}", std::env::consts::EXE_SUFFIX);
    let homes = [
        ctx.sys
            .env("CARGO_HOME")
            .filter(|s| !s.is_empty())
            .map(PathBuf::from),
        Some(ctx.roots.user_profile.join(".cargo")),
    ];
    homes
        .into_iter()
        .flatten()
        .map(|h| h.join("bin").join(&exe))
        .find(|p| p.is_file())
        .or_else(|| ctx.sys.which("cargo"))
}

/// 入れてある shim の版 (`pjp --version` の「pjp <版>」)。無い・起きないなら None。
fn installed_version(ctx: &Ctx, shim: &Path) -> Option<String> {
    if !shim.is_file() {
        return None;
    }
    let r = ctx.sys.run(
        &CommandSpec::new(shim)
            .arg("--version")
            .timeout(Duration::from_secs(30)),
        &mut |_| {},
    );
    if r.code() != Some(0) {
        return None;
    }
    r.output
        .iter()
        .find_map(|l| l.trim().strip_prefix("pjp ").map(|v| v.trim().to_string()))
}

/// `^[A-Za-z0-9][A-Za-z0-9._-]*$` (rust-toolchain.toml の channel。Linux の bootstrap-pjp.sh と同じ確かめ)
fn channel_ok(s: &str) -> bool {
    let mut c = s.chars();
    c.next().is_some_and(|x| x.is_ascii_alphanumeric())
        && c.all(|x| x.is_ascii_alphanumeric() || matches!(x, '.' | '_' | '-'))
}

/// `^[0-9][0-9A-Za-z.+-]*$` (crates/pjp-shim の version)
fn version_ok(s: &str) -> bool {
    let mut c = s.chars();
    c.next().is_some_and(|x| x.is_ascii_digit())
        && c.all(|x| x.is_ascii_alphanumeric() || matches!(x, '.' | '+' | '-'))
}

pub struct Pjp;

impl Step for Pjp {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "pjp",
            order: 55,
            title: "claude-skills の Rust の道具の入口 (shim の pjp) を入れ、道具を作る (pjp --build)",
            gate: Gate::Tool("claudePrivateSkills"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let clone = clone_dir(ctx);
        let shim_dir = clone.join("crates").join("pjp-shim");
        let shim_toml = shim_dir.join("Cargo.toml");
        if !shim_toml.is_file() {
            return vec![
                Outcome::new(
                    Kind::Manual,
                    format!(
                        "claude-skills の clone に Rust の道具 (crates/pjp-shim) がまだ無い ({}) → clone を pull する",
                        clone.display()
                    ),
                )
                .note(format!(
                    "pull の例 (gh の資格情報で HTTPS を通す): git -c url.https://github.com/.insteadOf=git@github.com: -c credential.helper= -c 'credential.helper=!gh auth git-credential' -C '{}' pull --ff-only",
                    super::ps1::ps_quote(&clone.to_string_lossy())
                )),
            ];
        }
        let toolchain = clone.join("rust-toolchain.toml");
        let channel = read_toml_string(&toolchain, "toolchain", "channel").unwrap_or_default();
        if !channel_ok(&channel) {
            return vec![Outcome::new(
                Kind::Failed,
                format!(
                    "claude-skills の rust-toolchain.toml の [toolchain] の channel を読めない ({})",
                    toolchain.display()
                ),
            )];
        }
        let want = read_toml_string(&shim_toml, "package", "version").unwrap_or_default();
        if !version_ok(&want) {
            return vec![Outcome::new(
                Kind::Failed,
                format!(
                    "claude-skills の crates/pjp-shim/Cargo.toml の [package] の version を読めない ({})",
                    shim_toml.display()
                ),
            )];
        }
        ctx.say(format!("clone: {}", clone.display()));
        ctx.say(format!("toolchain {channel}・shim {want}"));
        let root = cargo_root(ctx);
        let shim = shim_path(ctx);
        let need = match installed_version(ctx, &shim) {
            Some(v) if v == want => None,
            Some(v) => Some((
                Kind::Fix,
                format!("shim の pjp が {v} (clone の {want} と違う) → 入れ直す"),
            )),
            None if shim.exists() => Some((
                Kind::Fix,
                format!("shim の pjp が起きない ({}) → 入れ直す", shim.display()),
            )),
            None => Some((
                Kind::Missing,
                format!("shim の pjp が無い ({}) → 入れる", shim.display()),
            )),
        };
        let install_args = |target_dir: &str| {
            format!(
                "cargo install --locked --root {} --target-dir {target_dir} --path {} (cwd は clone、RUSTUP_TOOLCHAIN={channel})",
                root.display(),
                shim_dir.display()
            )
        };
        match mode {
            Mode::Check => vec![match need {
                None => Outcome::new(Kind::Ok, format!("shim の pjp は {want} のまま")),
                Some((kind, text)) => {
                    ctx.say(&text);
                    Outcome::new(kind, format!("{text} (apply で)"))
                }
            }],
            Mode::DryRun { .. } => {
                if need.is_some() {
                    ctx.say(format!("[dry-run] {}", install_args("<使い捨ての dir>")));
                }
                ctx.say(format!(
                    "[dry-run] pjp --build を流す (PJP_SKILLS_DIR={})",
                    clone.display()
                ));
                vec![match need {
                    None => Outcome::new(
                        Kind::Ok,
                        format!("[dry-run] shim の pjp は {want} のまま。pjp --build を流す"),
                    ),
                    Some((kind, text)) => {
                        Outcome::new(kind, format!("[dry-run] {text}。続けて pjp --build を流す"))
                    }
                }]
            }
            Mode::Apply { .. } => {
                if let Some((_, text)) = &need {
                    ctx.say(text);
                    let Some(cargo) = locate_cargo(ctx) else {
                        return vec![Outcome::new(
                            Kind::Failed,
                            "cargo が見つからない (rustup は bootstrap が入れる)",
                        )];
                    };
                    let nanos = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_nanos())
                        .unwrap_or(0);
                    let target_dir = std::env::temp_dir().join(format!(
                        "dotfiles-win-pjp-shim-{}-{nanos}",
                        std::process::id()
                    ));
                    ctx.say(format!("+ {}", install_args(&target_dir.to_string_lossy())));
                    let spec = CommandSpec::new(cargo)
                        .arg("install")
                        .arg("--locked")
                        .arg("--root")
                        .arg(root.as_os_str())
                        .arg("--target-dir")
                        .arg(target_dir.as_os_str())
                        .arg("--path")
                        .arg(shim_dir.as_os_str())
                        .current_dir(&clone)
                        .env("RUSTUP_TOOLCHAIN", &channel)
                        .timeout(Duration::from_secs(INSTALL_SECS));
                    let r = run_streaming(ctx, &spec);
                    let _ = std::fs::remove_dir_all(&target_dir);
                    if r.code() != Some(0) {
                        return vec![
                            Outcome::new(
                                Kind::Failed,
                                format!("shim の pjp を入れられなかった (上の cargo の出力。{:?})", r.exit),
                            )
                            .note("pjp を使っている会話・端末 (hook の pjp hub guard など) があると、入れ替えが「アクセスが拒否されました」で落ちることがある。止めてから流し直す"),
                        ];
                    }
                    match installed_version(ctx, &shim) {
                        Some(v) if v == want => ctx.say(format!(
                            "shim の pjp {want} を入れました: {}",
                            shim.display()
                        )),
                        other => {
                            return vec![Outcome::new(
                                Kind::Failed,
                                format!(
                                    "入れた shim が起きない・版が違う ({}: {other:?}。望んだのは {want})",
                                    shim.display()
                                ),
                            )];
                        }
                    }
                }
                ctx.say(format!(
                    "+ pjp --build (PJP_SKILLS_DIR={})",
                    clone.display()
                ));
                let spec = CommandSpec::new(&shim)
                    .arg("--build")
                    .env("PJP_SKILLS_DIR", clone.as_os_str())
                    .env_remove("RUSTUP_TOOLCHAIN")
                    .timeout(Duration::from_secs(BUILD_SECS));
                let r = run_streaming(ctx, &spec);
                if r.code() != Some(0) {
                    return vec![
                        Outcome::new(
                            Kind::Failed,
                            format!("claude-skills の道具を作れなかった (pjp --build。上の cargo の出力。{:?})", r.exit),
                        )
                        .note("道具は、初めて打ったときに shim が作り直す。直してから流し直す"),
                    ];
                }
                vec![Outcome::new(
                    Kind::Ok,
                    format!("shim の pjp {want}・道具を作った (pjp --build)"),
                )]
            }
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - clone に crates/pjp-shim が無い → manual。channel・version が読めない → failed
    //! - shim が無い: check は missing で何も打たない、dry-run は打つものを出す、apply は cargo install を clone の中で RUSTUP_TOOLCHAIN を付けて打ち、
    //!   使い捨ての target dir を消し、続けて pjp --build を PJP_SKILLS_DIR を付け RUSTUP_TOOLCHAIN を外して打つ
    //! - 版が同じ → install は打たず build だけ。版が違う・起きない → fix
    //! - cargo が落ちる・入れた shim の版が違う・build が落ちる → failed

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, Exit, RunResult};
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::cell::RefCell;
    use std::path::{Path, PathBuf};
    use std::rc::Rc;

    struct World {
        t: TempDir,
    }

    impl World {
        fn new() -> Self {
            let t = TempDir::new("pjp");
            std::fs::create_dir_all(t.path().join("g").join("dotfiles")).unwrap();
            t.write(
                "g/claude-skills/rust-toolchain.toml",
                "[toolchain]\nchannel = \"1.99.1\"\n",
            );
            t.write(
                "g/claude-skills/crates/pjp-shim/Cargo.toml",
                "[package]\nname = \"pjp-shim\"\n# 版\nversion = \"0.1.0\"\n",
            );
            World { t }
        }

        fn clone(&self) -> PathBuf {
            self.t.path().join("g").join("claude-skills")
        }

        fn cargo_home(&self) -> PathBuf {
            self.t.path().join("cargo")
        }

        fn shim(&self) -> PathBuf {
            self.cargo_home()
                .join("bin")
                .join(format!("pjp{}", std::env::consts::EXE_SUFFIX))
        }

        /// `--version` の答え (`installed`: 入れた shim の版。None なら起きない) と cargo・build の終了コード
        fn sys(
            &self,
            installed: Rc<RefCell<Option<String>>>,
            cargo_code: i32,
            build_code: i32,
        ) -> FakeSys {
            let shim = self.shim();
            std::fs::create_dir_all(self.cargo_home().join("bin")).unwrap();
            let cargo = self
                .cargo_home()
                .join("bin")
                .join(format!("cargo{}", std::env::consts::EXE_SUFFIX));
            std::fs::write(&cargo, "").unwrap();
            FakeSys::new(move |c: &CommandSpec| {
                let args = c.args_lossy();
                let code = |n| RunResult {
                    exit: Exit::Code(n),
                    output: vec![],
                };
                if c.program == shim && args == ["--version"] {
                    return match installed.borrow().as_ref() {
                        Some(v) => RunResult {
                            exit: Exit::Code(0),
                            output: vec![format!("pjp {v}")],
                        },
                        None => code(1),
                    };
                }
                if c.program == shim && args == ["--build"] {
                    return code(build_code);
                }
                if c.program == cargo && args.first().map(String::as_str) == Some("install") {
                    if cargo_code == 0 {
                        std::fs::write(&shim, "shim").unwrap();
                        *installed.borrow_mut() = Some("0.1.0".to_string());
                    }
                    return code(cargo_code);
                }
                panic!("思わぬコマンド: {} {args:?}", c.program.display());
            })
            .with_env("CARGO_HOME", &self.cargo_home().to_string_lossy())
        }

        fn run(&self, sys: &FakeSys, mode: Mode) -> (Outcome, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("g").join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys,
                    out: &mut out,
                };
                Pjp.run(&mut ctx, mode).remove(0)
            };
            (o, String::from_utf8(out).unwrap())
        }
    }

    #[test]
    fn installs_the_shim_then_builds() {
        let w = World::new();
        let installed = Rc::new(RefCell::new(None));
        let sys = w.sys(installed.clone(), 0, 0);
        let (o, _) = w.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(
            sys.calls.borrow().is_empty(),
            "check は何も打たない (shim が無い)"
        );
        let (o, out) = w.run(&sys, Mode::DryRun { force: false });
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(
            out.contains("[dry-run] cargo install --locked --root "),
            "{out}"
        );
        assert!(out.contains("[dry-run] pjp --build"), "{out}");
        assert!(sys.calls.borrow().is_empty());

        let (o, out) = w.run(&sys, Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        let calls = sys.calls.borrow();
        let install = calls
            .iter()
            .find(|c| c.args_lossy().first().map(String::as_str) == Some("install"))
            .unwrap();
        let args = install.args_lossy();
        assert_eq!(
            args[..4],
            [
                "install",
                "--locked",
                "--root",
                &w.cargo_home().to_string_lossy()
            ]
        );
        assert_eq!(args[4], "--target-dir");
        let target_dir = PathBuf::from(&args[5]);
        assert!(
            target_dir.starts_with(std::env::temp_dir()),
            "{target_dir:?}"
        );
        assert!(!target_dir.exists());
        assert_eq!(
            args[6..],
            [
                "--path",
                &w.clone().join("crates").join("pjp-shim").to_string_lossy()
            ]
        );
        assert_eq!(install.cwd.as_deref(), Some(w.clone().as_path()));
        assert_eq!(
            install.env_value("RUSTUP_TOOLCHAIN").as_deref(),
            Some("1.99.1")
        );
        let build = calls
            .iter()
            .find(|c| c.args_lossy() == ["--build"])
            .unwrap();
        assert_eq!(
            build.env_value("PJP_SKILLS_DIR").as_deref(),
            Some(&*w.clone().to_string_lossy())
        );
        assert!(build.removes_env("RUSTUP_TOOLCHAIN"));
    }

    #[test]
    fn same_version_only_builds() {
        let w = World::new();
        std::fs::create_dir_all(w.shim().parent().unwrap()).unwrap();
        std::fs::write(w.shim(), "shim").unwrap();
        let sys = w.sys(Rc::new(RefCell::new(Some("0.1.0".into()))), 9, 0);
        let (o, _) = w.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        let (o, _) = w.run(&sys, Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(!sys.call_args().iter().any(|a| a.starts_with("install")));
        assert!(sys.call_args().iter().any(|a| a == "--build"));
    }

    #[test]
    fn other_version_or_broken_shim_is_fix() {
        let w = World::new();
        std::fs::create_dir_all(w.shim().parent().unwrap()).unwrap();
        std::fs::write(w.shim(), "shim").unwrap();
        let (o, _) = w.run(
            &w.sys(Rc::new(RefCell::new(Some("0.0.9".into()))), 0, 0),
            Mode::Check,
        );
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        assert!(o.text.contains("0.0.9"), "{o:?}");
        let (o, _) = w.run(&w.sys(Rc::new(RefCell::new(None)), 0, 0), Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        assert!(o.text.contains("起きない"), "{o:?}");
    }

    #[test]
    fn failures() {
        let w = World::new();
        let (o, _) = w.run(
            &w.sys(Rc::new(RefCell::new(None)), 101, 0),
            Mode::Apply { force: false },
        );
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("shim の pjp を入れられなかった"), "{o:?}");

        let w = World::new();
        let (o, _) = w.run(
            &w.sys(Rc::new(RefCell::new(None)), 0, 101),
            Mode::Apply { force: false },
        );
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("pjp --build"), "{o:?}");

        let w = World::new();
        std::fs::remove_file(w.clone().join("crates").join("pjp-shim").join("Cargo.toml")).unwrap();
        let (o, _) = w.run(&w.sys(Rc::new(RefCell::new(None)), 0, 0), Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{o:?}");
        assert!(o.text.contains("crates/pjp-shim"), "{o:?}");

        let w = World::new();
        w.t.write(
            "g/claude-skills/rust-toolchain.toml",
            "[toolchain]\nchannel = \"1.99 1\"\n",
        );
        let (o, _) = w.run(&w.sys(Rc::new(RefCell::new(None)), 0, 0), Mode::Check);
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("channel"), "{o:?}");
    }

    #[test]
    fn reads_toml_strings() {
        let t = TempDir::new("pjp-toml");
        let p = t.write(
            "a.toml",
            "[package]\nname = \"x\"\nversion = \"0.2.0\"\n[t]\nk = 1\n",
        );
        assert_eq!(
            read_toml_string(&p, "package", "version").as_deref(),
            Some("0.2.0")
        );
        assert_eq!(read_toml_string(&p, "t", "k"), None);
        assert_eq!(read_toml_string(&p, "nope", "k"), None);
        assert_eq!(
            read_toml_string(&t.path().join("none.toml"), "a", "b"),
            None
        );
    }
}
