//! claude-selector (order 99): claude-selector (略語 cs。claude のアカウントと option を矢印キーで選んで Claude Code を起こす) を、Linux と
//! 同じ crate (`nix/pkgs/claude-selector`) から cargo build で作り、`%LOCALAPPDATA%\dotfiles\bin\claude-selector.exe` に置いて、置き場を
//! ユーザーの PATH に足す (claude-accounts の launcher と同じ置き場。dotfiles-private の docs/adr/087_claude_selector_*)。
//!
//! claude-<名前>.exe・claude-account.exe と違って runner の exe の写しにしないのは、画面の crate (crossterm とその依存) を runner の
//! 依存に入れず、selector の Cargo.lock を Linux の Nix と同じ 1 つにするため (写しにすると、runner の Cargo.lock にも同じ crate が入り、
//! 2 つがずれると `cargo run --locked` の dotfiles 関数ごと起きなくなる)。作れなくても、落ちるのはこの手順だけ。
//!
//! - 作る: `cargo build --release --locked --manifest-path <crate>\Cargo.toml --target-dir <crate>\target` を crate の中で、runner の
//!   toolchain (`win/runner/rust-toolchain.toml` の channel を RUSTUP_TOOLCHAIN に付ける) で打つ。cargo は pjp の手順と同じ順に探す
//! - 作り直すか: crate の元 (Cargo.toml・Cargo.lock・src\ の下の全部) と channel の SHA-256 を、置いた exe の SHA-256 と組で
//!   `%LOCALAPPDATA%\dotfiles\state\claude-selector.built.json` に控え、元・置いた exe・控えのどれかが違えば作り直す。check と dry-run は
//!   作らずに比べるだけ (cargo を打たない)
//! - 置く: 置き場の exe が動いていても上書きできるよう、退けてから置く (claude-files と同じ `replace_file`)
//! - cargo が無いホスト (Build Tools と rustup を入れない minimum の PC。runner は Release の exe で動く) では、作り直しが要っても作らず
//!   · で知らせ、`Install-Bootstrap.ps1 -Rust` を案内する (PATH にも触らない)。cs の exe も Release で配るのは後続の PR
//!   (dotfiles-private の docs/adr/117_win_runner_exe_release_*)
//!
//! gate は windowsClaudeCode (Windows の Claude Code を入れるホスト)。claude-accounts (windowsClaudeAccounts も要る) の外に置くのは、
//! company のグループ (windowsClaudeAccounts が off) でも素の claude を選んで起こせるようにするため (Linux の cs も dotfiles.claude.enable
//! のホスト全部にある)。PATH は claude-accounts と同じく、もう動いている process (herdr-app とその中の端末) には効かない。

use super::claude_accounts::{BIN_DIR_REL, PathState, sync_user_path};
use super::claude_files::replace_file;
use super::pjp::{channel_ok, locate_cargo, read_toml_string};
use super::ps1::run_streaming;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::process::CommandSpec;
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// crate の置き場 (dotfiles の clone からの相対。`/` 区切り)
pub const CRATE_REL: &str = "nix/pkgs/claude-selector";
/// 作るのに使う toolchain の channel を読むファイル (runner と同じ版で作る)
pub const TOOLCHAIN_REL: &str = "win/runner/rust-toolchain.toml";
/// 控え (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "claude-selector.built.json";
/// cargo build の待ちの上限 (初めては crossterm などの依存も作る)
const BUILD_SECS: u64 = 1800;
/// PATH に足したときに添える文 (claude-accounts の文と違い、claude-<名前> を出さない。company のグループでは無いため)
const NEW_TERMINAL: &str = "PATH は新しい端末から効く。herdr-app とその中の端末・動いている Claude Code には効かないので、herdr-app を上げ直すか、新しい PowerShell で cs (claude-selector) を打つ";

/// 置く exe の名前 (Windows は claude-selector.exe。ほかの OS の名前は試験のため)
pub fn exe_name() -> String {
    format!("claude-selector{}", std::env::consts::EXE_SUFFIX)
}

/// crate の元 (Cargo.toml・Cargo.lock・src の下の全部と、あれば build.rs・.cargo の下の全部。相対パスの順) と toolchain の channel の
/// SHA-256。読めなければわけ (tests の下は exe に入らないので数えない)
pub fn source_digest(crate_dir: &Path, channel: &str) -> Result<String, String> {
    let mut files = vec![
        ("Cargo.toml".to_string(), crate_dir.join("Cargo.toml")),
        ("Cargo.lock".to_string(), crate_dir.join("Cargo.lock")),
    ];
    collect(&crate_dir.join("src"), "src", &mut files)?;
    if crate_dir.join("build.rs").is_file() {
        files.push(("build.rs".to_string(), crate_dir.join("build.rs")));
    }
    if crate_dir.join(".cargo").is_dir() {
        collect(&crate_dir.join(".cargo"), ".cargo", &mut files)?;
    }
    files.sort();
    let mut buf = format!("channel={channel}\n").into_bytes();
    for (rel, path) in files {
        let bytes =
            std::fs::read(&path).map_err(|e| format!("{} が読めない ({e})", path.display()))?;
        buf.extend_from_slice(format!("{rel}\0{}\0", bytes.len()).as_bytes());
        buf.extend_from_slice(&bytes);
    }
    Ok(fsutil::sha256_bytes(&buf))
}

/// `dir` の下のファイルを全部 (`rel` は `/` 区切りの相対パス) `out` に足す
fn collect(dir: &Path, rel: &str, out: &mut Vec<(String, PathBuf)>) -> Result<(), String> {
    let entries =
        std::fs::read_dir(dir).map_err(|e| format!("{} が読めない ({e})", dir.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("{} が読めない ({e})", dir.display()))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        let child = format!("{rel}/{name}");
        if path.is_dir() {
            collect(&path, &child, out)?;
        } else {
            out.push((child, path));
        }
    }
    Ok(())
}

/// 控え: 置いた exe を作った元と、置いた exe の SHA-256。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub source: String,
    pub exe: String,
}

impl Record {
    /// 読む。無ければ None、形が違えばわけ (作り直せば書き直す)
    pub fn load(path: &Path) -> Result<Option<Record>, String> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("控えが読めない: {} ({e})", path.display())),
        };
        let v: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| format!("控えが読めない形: {} ({e})", path.display()))?;
        let field = |k: &str| {
            v.get(k)
                .and_then(serde_json::Value::as_str)
                .map(str::to_string)
        };
        match (
            v.get("version").and_then(serde_json::Value::as_u64),
            field("source"),
            field("exe"),
        ) {
            (Some(1), Some(source), Some(exe)) => Ok(Some(Record { source, exe })),
            _ => Err(format!(
                "控えが読めない形: {} (version・source・exe)",
                path.display()
            )),
        }
    }

    pub fn to_json(&self) -> String {
        let mut m = serde_json::Map::new();
        m.insert("version".into(), serde_json::Value::from(1));
        m.insert(
            "source".into(),
            serde_json::Value::from(self.source.as_str()),
        );
        m.insert("exe".into(), serde_json::Value::from(self.exe.as_str()));
        let mut s = serde_json::to_string_pretty(&serde_json::Value::Object(m))
            .unwrap_or_else(|_| String::from("{}"));
        s.push('\n');
        s
    }
}

/// 置いた exe が今の元のものか。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Need {
    /// 置いた exe は今の元から作ったもの
    Same,
    /// 置き場に無い
    Missing,
    /// 作り直す (わけ)
    Stale(&'static str),
}

/// 置いた exe の SHA-256 (`placed`)・控え・今の元から決める
pub fn decide(placed: Option<&str>, record: Option<&Record>, source: &str) -> Need {
    match (placed, record) {
        (None, _) => Need::Missing,
        (Some(_), None) => Need::Stale("作った控えが無い"),
        (Some(_), Some(r)) if r.source != source => Need::Stale("元が変わった"),
        (Some(p), Some(r)) if r.exe != p => Need::Stale("置いた exe が控えと違う"),
        _ => Need::Same,
    }
}

pub struct ClaudeSelector;

impl Step for ClaudeSelector {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-selector",
            // claude-accounts と同じ置き場 (dotfiles\bin) に置く。同じ order の中では名前の順で claude-accounts の後
            order: 99,
            title: "claude-selector (cs。claude のアカウントと option を矢印キーで選んで Claude Code を起こす) を nix/pkgs/claude-selector から cargo build で作り、%LOCALAPPDATA%\\dotfiles\\bin\\claude-selector.exe に置いてユーザーの PATH に足す",
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode)]
    }
}

/// 落ちたときの行
fn failed(ctx: &mut Ctx, why: String) -> Outcome {
    ctx.say(format!("!! {why}"));
    Outcome::new(Kind::Failed, format!("claude-selector: {why}"))
}

fn sync(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let crate_dir = ctx.repo_path(CRATE_REL);
    let bin = join_segments(&ctx.roots.local_app_data, BIN_DIR_REL);
    let dest = bin.join(exe_name());
    ctx.say(format!("==> {}", dest.display()));
    if !crate_dir.join("Cargo.toml").is_file() {
        return failed(
            ctx,
            format!(
                "crate が無い ({}。dotfiles の clone を進める: dotfiles --self-update apply)",
                crate_dir.display()
            ),
        );
    }
    let toolchain = ctx.repo_path(TOOLCHAIN_REL);
    let channel = read_toml_string(&toolchain, "toolchain", "channel").unwrap_or_default();
    if !channel_ok(&channel) {
        return failed(
            ctx,
            format!(
                "runner の rust-toolchain.toml の [toolchain] の channel を読めない ({})",
                toolchain.display()
            ),
        );
    }
    let source = match source_digest(&crate_dir, &channel) {
        Ok(s) => s,
        Err(e) => return failed(ctx, e),
    };
    let record_path = ctx.state_dir.join(RECORD_FILE);
    let mut notes = Vec::new();
    let record = Record::load(&record_path).unwrap_or_else(|e| {
        ctx.say(format!("!! {e}"));
        notes.push(e);
        None
    });
    let placed = std::fs::read(&dest).ok().map(|b| fsutil::sha256_bytes(&b));
    let need = decide(placed.as_deref(), record.as_ref(), &source);
    // cargo の無いホスト (Build Tools と rustup を入れない minimum の PC。runner は Release の exe で動く) では作らず、知らせるだけにする
    // (check・dry-run・apply とも。PATH にも触らない)。cs の exe も Release で配るのは後続の PR (dotfiles-private の
    // docs/adr/117_win_runner_exe_release_*)
    if need != Need::Same && locate_cargo(ctx).is_none() {
        let why = format!(
            "cargo が無いので作らない ({}) → cs を使うなら、Install-Bootstrap.ps1 -Rust で Build Tools と rustup を入れてから dotfiles apply",
            reason(need)
        );
        ctx.say(format!("· {why}"));
        let mut o = Outcome::new(Kind::Info, format!("{}: {why}", exe_name()));
        for n in notes {
            o = o.note(n);
        }
        return o;
    }
    let cargo_line = format!(
        "cargo build --release --locked --manifest-path {} (RUSTUP_TOOLCHAIN={channel})",
        crate_dir.join("Cargo.toml").display()
    );
    // exe の様子 (行の文の頭) と、apply で落ちたか
    let (exe_text, exe_kind) = match (need, mode) {
        (Need::Same, _) => {
            ctx.say(format!("今の元から作ったもの: {}", dest.display()));
            ("そのまま".to_string(), Kind::Ok)
        }
        (need, Mode::Check) => {
            let todo = todo_text(need);
            ctx.say(format!("{todo} (apply で): {}", dest.display()));
            (todo, kind_of(need))
        }
        (need, Mode::DryRun { .. }) => {
            ctx.say(format!("[dry-run] {cargo_line}"));
            ctx.say(format!("[dry-run] 置く: {}", dest.display()));
            (todo_text(need), kind_of(need))
        }
        (need, Mode::Apply { .. }) => {
            match build_and_place(ctx, &crate_dir, &channel, &cargo_line, &dest, &source) {
                Ok(()) => {
                    let done = match need {
                        Need::Missing => "作って置いた".to_string(),
                        _ => format!("作り直して置いた ({})", reason(need)),
                    };
                    (done, Kind::Ok)
                }
                Err((why, extra)) => {
                    ctx.say(format!("!! {why}"));
                    notes.extend(extra);
                    (why, Kind::Failed)
                }
            }
        }
    };
    let path = sync_user_path(ctx, mode, &bin);
    let path_text = match &path {
        Ok(PathState::Listed) => "入っている",
        Ok(PathState::ToAdd) => {
            notes.push(format!(
                "置き場 {} をユーザーの PATH の末尾に足す (値の型と、ほかの要素の %VAR% の書き方は変えない)",
                bin.display()
            ));
            "足す"
        }
        Ok(PathState::Added) => {
            notes.push(NEW_TERMINAL.to_string());
            "足した"
        }
        Err(e) => {
            ctx.say(format!("!! {e}"));
            notes.push(e.clone());
            "確かめられない"
        }
    };
    let to_add = matches!(path, Ok(PathState::ToAdd));
    let mut text = format!("{}: {exe_text} / PATH: {path_text}", exe_name());
    if !mode.writes() && (exe_kind != Kind::Ok || to_add) {
        text.push_str(" → dotfiles apply で揃える");
    }
    if matches!(mode, Mode::DryRun { .. }) {
        text = format!("[dry-run] {text}");
    }
    let kind = if exe_kind == Kind::Failed || path.is_err() {
        Kind::Failed
    } else if exe_kind != Kind::Ok {
        exe_kind
    } else if to_add {
        Kind::Missing
    } else {
        Kind::Ok
    };
    let mut o = Outcome::new(kind, text);
    for n in notes {
        o = o.note(n);
    }
    o
}

/// 作り直すわけ
fn reason(need: Need) -> &'static str {
    match need {
        Need::Stale(why) => why,
        Need::Missing => "置き場に無い",
        Need::Same => "",
    }
}

/// check・dry-run の行の文
fn todo_text(need: Need) -> String {
    match need {
        Need::Missing => "作って置く".to_string(),
        _ => format!("作り直して置く ({})", reason(need)),
    }
}

/// check・dry-run の行の種類 (無い → Missing、作り直す → Fix)
fn kind_of(need: Need) -> Kind {
    match need {
        Need::Same => Kind::Ok,
        Need::Missing => Kind::Missing,
        Need::Stale(_) => Kind::Fix,
    }
}

/// cargo build で作り、置き場に置いて控えを書く。落ちたら (わけ, 添える行)
fn build_and_place(
    ctx: &mut Ctx,
    crate_dir: &Path,
    channel: &str,
    cargo_line: &str,
    dest: &Path,
    source: &str,
) -> Result<(), (String, Vec<String>)> {
    let Some(cargo) = locate_cargo(ctx) else {
        return Err((
            "cargo が見つからない (rustup は bootstrap が入れる)".to_string(),
            Vec::new(),
        ));
    };
    let target_dir = crate_dir.join("target");
    ctx.say(format!("+ {cargo_line}"));
    let spec = CommandSpec::new(cargo)
        .arg("build")
        .arg("--release")
        .arg("--locked")
        .arg("--manifest-path")
        .arg(crate_dir.join("Cargo.toml").as_os_str())
        .arg("--target-dir")
        .arg(target_dir.as_os_str())
        .current_dir(crate_dir)
        .env("RUSTUP_TOOLCHAIN", channel)
        .timeout(Duration::from_secs(BUILD_SECS));
    let r = run_streaming(ctx, &spec);
    if r.code() != Some(0) {
        return Err((
            format!("cargo build が落ちた (上の cargo の出力。{:?})", r.exit),
            vec!["直してから dotfiles apply --steps claude-selector を流し直す (置いてある exe はそのまま)".to_string()],
        ));
    }
    let built = target_dir.join("release").join(exe_name());
    let bytes = std::fs::read(&built).map_err(|e| {
        (
            format!("作った exe が読めない: {} ({e})", built.display()),
            Vec::new(),
        )
    })?;
    replace_file(&bytes, dest).map_err(|e| {
        (
            format!("{} を書けない ({e})", dest.display()),
            vec!["claude-selector を使っている端末があれば閉じてから流し直す".to_string()],
        )
    })?;
    ctx.say(format!("置きました: {}", dest.display()));
    let record = Record {
        source: source.to_string(),
        exe: fsutil::sha256_bytes(&bytes),
    };
    let record_path = ctx.state_dir.join(RECORD_FILE);
    fsutil::write_atomic(&record_path, record.to_json().as_bytes()).map_err(|e| {
        (
            format!("控えを書けない: {} ({e})", record_path.display()),
            vec!["次の apply で作り直す".to_string()],
        )
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 置き場に無い: check は missing で cargo を打たず何も書かない、dry-run は打つものを出す、apply は crate の中で
    //!   RUSTUP_TOOLCHAIN を runner の channel にして cargo build --release --locked --manifest-path … --target-dir <crate>\target を打ち、
    //!   作った exe を置いて控えを書き、置き場を PATH に足す。2 回目の check は ✔ (cargo を打たない)
    //! - 元 (src の下・Cargo.lock)・toolchain の channel が変わる・置いた exe が控えと違う・控えが無い → fix。apply で作り直す
    //! - cargo が落ちる → failed で、置いた exe と控えはそのまま。cargo が無い → failed
    //! - crate が無い・channel が読めない → failed。控えが壊れていれば、作り直す (知らせる)
    //! - 元の SHA-256 は src の下のファイルの並び (読む順) に依らない。build.rs・.cargo の下を足すと変わり、tests の下では変わらない
    //! - PATH に足したときの知らせは cs を出し、claude-<名前> を出さない (company のグループには無い)

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::{Exit, RunResult};
    use crate::testutil::{FakeSys, TempDir};
    use std::cell::RefCell;
    use std::rc::Rc;

    struct World {
        t: TempDir,
        /// registry のユーザーの PATH の生の値 (偽物が読み書きする)
        reg: Rc<RefCell<String>>,
    }

    impl World {
        fn new() -> Self {
            let t = TempDir::new("claude-selector");
            t.write(
                "g/dotfiles/nix/pkgs/claude-selector/Cargo.toml",
                "[package]\nname = \"claude-selector\"\n",
            );
            t.write("g/dotfiles/nix/pkgs/claude-selector/Cargo.lock", "# lock\n");
            t.write(
                "g/dotfiles/nix/pkgs/claude-selector/src/main.rs",
                "fn main() {}\n",
            );
            t.write("g/dotfiles/nix/pkgs/claude-selector/src/ui.rs", "// ui\n");
            t.write(
                "g/dotfiles/win/runner/rust-toolchain.toml",
                "[toolchain]\nchannel = \"1.99.1\"\n",
            );
            t.write(
                &format!("home/.cargo/bin/cargo{}", std::env::consts::EXE_SUFFIX),
                "cargo",
            );
            World {
                t,
                reg: Rc::new(RefCell::new("C:\\Windows".to_string())),
            }
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn crate_dir(&self) -> PathBuf {
            join_segments(self.t.path(), "g/dotfiles/nix/pkgs/claude-selector")
        }

        fn dest(&self) -> PathBuf {
            join_segments(&self.home(), "AppData/Local/dotfiles/bin").join(exe_name())
        }

        fn record(&self) -> Option<Record> {
            Record::load(&self.t.path().join("state").join(RECORD_FILE)).unwrap()
        }

        /// 偽の cargo (`exit` で終わり、0 なら target\release に `built` を書く) とユーザーの PATH の読み書き
        fn sys(&self, exit: i32, built: &'static str) -> FakeSys {
            let reg = self.reg.clone();
            FakeSys::new(move |c| {
                let args = c.args_lossy();
                if args.first().is_some_and(|a| a == "build") {
                    if exit == 0 {
                        let i = args.iter().position(|a| a == "--target-dir").unwrap();
                        let out = PathBuf::from(&args[i + 1]).join("release");
                        std::fs::create_dir_all(&out).unwrap();
                        std::fs::write(out.join(exe_name()), built).unwrap();
                    }
                    return RunResult {
                        exit: Exit::Code(exit),
                        output: vec!["   Compiling claude-selector v0.1.0".to_string()],
                    };
                }
                if let Some(new) = c.env_value("DOTFILES_USER_PATH_NEW") {
                    *reg.borrow_mut() = new;
                    return RunResult {
                        exit: Exit::Code(0),
                        output: Vec::new(),
                    };
                }
                if args
                    .last()
                    .is_some_and(|a| a.contains("DoNotExpandEnvironmentNames"))
                {
                    return RunResult {
                        exit: Exit::Code(0),
                        output: vec![
                            "kind=ExpandString".to_string(),
                            format!("raw={}", reg.borrow()),
                        ],
                    };
                }
                panic!("知らないコマンド: {:?} {args:?}", c.program);
            })
            .with_program("pwsh", "pwsh")
        }

        fn run(&self, mode: Mode, sys: &FakeSys) -> (Outcome, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("g").join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys,
                    out: &mut out,
                };
                ClaudeSelector.run(&mut ctx, mode)
            };
            assert_eq!(o.len(), 1, "{o:?}");
            (
                o.into_iter().next().unwrap(),
                String::from_utf8(out).unwrap(),
            )
        }
    }

    fn builds(sys: &FakeSys) -> Vec<CommandSpec> {
        sys.calls
            .borrow()
            .iter()
            .filter(|c| c.args_lossy().first().is_some_and(|a| a == "build"))
            .cloned()
            .collect()
    }

    const APPLY: Mode = Mode::Apply { force: false };

    #[test]
    fn info() {
        let i = ClaudeSelector.info();
        assert_eq!((i.id, i.order), ("claude-selector", 99));
        assert_eq!(i.gate, Gate::Tool("windowsClaudeCode"));
        assert!(i.ported && i.windows_only);
    }

    #[test]
    fn builds_and_places_when_missing() {
        let w = World::new();
        let sys = w.sys(0, "selector-v1");
        let (o, out) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Missing, "{o:?}\n{out}");
        assert!(o.text.contains("作って置く"), "{o:?}");
        assert!(o.text.contains("PATH: 足す"), "{o:?}");
        let (o, out) = w.run(Mode::DryRun { force: false }, &sys);
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(o.text.starts_with("[dry-run] "), "{o:?}");
        assert!(
            out.contains("[dry-run] cargo build --release --locked"),
            "{out}"
        );
        assert!(builds(&sys).is_empty());
        assert!(!w.dest().exists());
        assert!(!w.t.path().join("state").exists());
        assert_eq!(*w.reg.borrow(), "C:\\Windows");

        let (o, out) = w.run(APPLY, &sys);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        assert!(o.text.contains("作って置いた"), "{o:?}");
        assert!(o.text.contains("PATH: 足した"), "{o:?}");
        let b = builds(&sys);
        assert_eq!(b.len(), 1);
        let args = b[0].args_lossy();
        assert_eq!(args[..3], ["build", "--release", "--locked"]);
        let manifest = w.crate_dir().join("Cargo.toml");
        let target = w.crate_dir().join("target");
        assert_eq!(
            args[3..],
            [
                "--manifest-path".to_string(),
                manifest.to_string_lossy().into_owned(),
                "--target-dir".to_string(),
                target.to_string_lossy().into_owned(),
            ]
        );
        assert_eq!(b[0].cwd.as_deref(), Some(w.crate_dir().as_path()));
        assert_eq!(
            b[0].env_value("RUSTUP_TOOLCHAIN").as_deref(),
            Some("1.99.1")
        );
        assert_eq!(std::fs::read(w.dest()).unwrap(), b"selector-v1");
        let rec = w.record().unwrap();
        assert_eq!(rec.exe, fsutil::sha256_bytes(b"selector-v1"));
        assert_eq!(rec.source, source_digest(&w.crate_dir(), "1.99.1").unwrap());
        let bin = join_segments(&w.home(), "AppData/Local/dotfiles/bin");
        assert_eq!(*w.reg.borrow(), format!("C:\\Windows;{}", bin.display()));
        let note = o
            .notes
            .iter()
            .find(|n| n.contains("新しい端末から効く"))
            .unwrap();
        assert!(note.contains("cs"), "{note}");
        assert!(!note.contains("claude-<名前>"), "{note}");

        // 2 回目は作らない
        let sys = w.sys(0, "selector-v2");
        for mode in [Mode::Check, APPLY] {
            let (o, _) = w.run(mode, &sys);
            assert_eq!(o.kind, Kind::Ok, "{mode:?} {o:?}");
            assert!(o.text.contains("そのまま / PATH: 入っている"), "{o:?}");
        }
        assert!(builds(&sys).is_empty());
        assert_eq!(std::fs::read(w.dest()).unwrap(), b"selector-v1");
    }

    /// 作り直すわけと、そのわけを作る手
    type Change = (&'static str, fn(&World));

    #[test]
    fn rebuilds_when_something_changed() {
        let w = World::new();
        w.run(APPLY, &w.sys(0, "selector-v1"));
        let cases: [Change; 4] = [
            ("元が変わった", |w| {
                w.t.write("g/dotfiles/nix/pkgs/claude-selector/src/ui.rs", "// ui 2\n");
            }),
            ("元が変わった", |w| {
                w.t.write(
                    "g/dotfiles/win/runner/rust-toolchain.toml",
                    "[toolchain]\nchannel = \"1.100.0\"\n",
                );
            }),
            ("置いた exe が控えと違う", |w| {
                std::fs::write(w.dest(), "hand-placed").unwrap();
            }),
            ("作った控えが無い", |w| {
                std::fs::remove_file(w.t.path().join("state").join(RECORD_FILE)).unwrap();
            }),
        ];
        for (i, (why, change)) in cases.iter().enumerate() {
            change(&w);
            let sys = w.sys(
                0,
                if i % 2 == 0 {
                    "selector-v2"
                } else {
                    "selector-v3"
                },
            );
            let (o, _) = w.run(Mode::Check, &sys);
            assert_eq!(o.kind, Kind::Fix, "{why}: {o:?}");
            assert!(o.text.contains(why), "{why}: {o:?}");
            assert!(builds(&sys).is_empty());
            let (o, out) = w.run(APPLY, &sys);
            assert_eq!(o.kind, Kind::Ok, "{why}: {o:?}\n{out}");
            assert!(o.text.contains("作り直して置いた"), "{why}: {o:?}");
            assert_eq!(builds(&sys).len(), 1, "{why}");
            let (o, _) = w.run(Mode::Check, &sys);
            assert_eq!(o.kind, Kind::Ok, "{why}: {o:?}");
        }
    }

    #[test]
    fn failed_build_keeps_the_placed_exe() {
        let w = World::new();
        w.run(APPLY, &w.sys(0, "selector-v1"));
        let before = w.record();
        w.t.write(
            "g/dotfiles/nix/pkgs/claude-selector/src/main.rs",
            "fn main() { x }\n",
        );
        let (o, out) = w.run(APPLY, &w.sys(101, ""));
        assert_eq!(o.kind, Kind::Failed, "{o:?}\n{out}");
        assert!(o.text.contains("cargo build が落ちた"), "{o:?}");
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("--steps claude-selector")),
            "{o:?}"
        );
        assert!(out.contains("Compiling claude-selector"), "{out}");
        assert_eq!(std::fs::read(w.dest()).unwrap(), b"selector-v1");
        assert_eq!(w.record(), before);
    }

    /// cargo の無いホストでは作らず · (Info) で知らせ、-Rust を案内する。PATH を書く PowerShell も打たない。置いた exe が今の元のものなら ✔
    #[test]
    fn without_cargo_only_tells() {
        let remove_cargo = |w: &World| {
            std::fs::remove_file(
                w.home()
                    .join(".cargo")
                    .join("bin")
                    .join(format!("cargo{}", std::env::consts::EXE_SUFFIX)),
            )
            .unwrap();
        };
        for mode in [Mode::Check, Mode::DryRun { force: false }, APPLY] {
            let w = World::new();
            remove_cargo(&w);
            let sys = w.sys(0, "x");
            let (o, _) = w.run(mode, &sys);
            assert_eq!(o.kind, Kind::Info, "{mode:?} {o:?}");
            assert!(
                o.text.contains("cargo が無いので作らない") && o.text.contains("-Rust"),
                "{o:?}"
            );
            assert!(
                sys.calls.borrow().is_empty(),
                "{mode:?}: {:?}",
                sys.call_args()
            );
            assert!(!w.dest().exists());
        }

        // 前に作った exe が今の元のものなら、cargo が無くても ✔
        let w = World::new();
        w.run(APPLY, &w.sys(0, "selector-v1"));
        remove_cargo(&w);
        let (o, _) = w.run(Mode::Check, &w.sys(0, "selector-v1"));
        assert_eq!(o.kind, Kind::Ok, "{o:?}");

        // 元が変わって作り直しが要るのに cargo が無ければ ·
        w.t.write(
            &format!("g/dotfiles/{CRATE_REL}/src/main.rs"),
            "fn main() { /* v2 */ }\n",
        );
        let (o, _) = w.run(APPLY, &w.sys(0, "selector-v2"));
        assert_eq!(o.kind, Kind::Info, "{o:?}");
        assert!(o.text.contains("元が変わった"), "{o:?}");
        assert_eq!(std::fs::read(w.dest()).unwrap(), b"selector-v1");
    }

    #[test]
    fn refuses_without_crate_or_channel() {
        let w = World::new();
        w.t.write("g/dotfiles/win/runner/rust-toolchain.toml", "[toolchain]\n");
        let (o, _) = w.run(Mode::Check, &w.sys(0, "x"));
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("channel を読めない"), "{o:?}");

        let w = World::new();
        std::fs::remove_dir_all(w.crate_dir()).unwrap();
        let (o, _) = w.run(Mode::Check, &w.sys(0, "x"));
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("crate が無い"), "{o:?}");
    }

    #[test]
    fn broken_record_rebuilds() {
        let w = World::new();
        w.run(APPLY, &w.sys(0, "selector-v1"));
        w.t.write(&format!("state/{RECORD_FILE}"), "[1]");
        let sys = w.sys(0, "selector-v1");
        let (o, _) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        assert!(
            o.notes.iter().any(|n| n.contains("控えが読めない形")),
            "{o:?}"
        );
        let (o, _) = w.run(APPLY, &sys);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(w.record().is_some());
    }

    #[test]
    fn digest_ignores_listing_order_but_not_names() {
        let a = TempDir::new("digest-a");
        let b = TempDir::new("digest-b");
        for t in [&a, &b] {
            t.write("c/Cargo.toml", "x");
            t.write("c/Cargo.lock", "y");
        }
        a.write("c/src/a.rs", "1");
        a.write("c/src/m/b.rs", "2");
        b.write("c/src/m/b.rs", "2");
        b.write("c/src/a.rs", "1");
        let da = source_digest(&a.path().join("c"), "1.99.1").unwrap();
        assert_eq!(da, source_digest(&b.path().join("c"), "1.99.1").unwrap());
        assert_ne!(da, source_digest(&a.path().join("c"), "1.99.2").unwrap());
        // 中身が同じでも名前が違えば違う
        b.write("c/src/a2.rs", "1");
        std::fs::remove_file(b.path().join("c").join("src").join("a.rs")).unwrap();
        assert_ne!(da, source_digest(&b.path().join("c"), "1.99.1").unwrap());
        // build.rs・.cargo の下を足すと変わり、tests の下では変わらない
        a.write("c/tests/t.rs", "#[test] fn t() {}");
        assert_eq!(da, source_digest(&a.path().join("c"), "1.99.1").unwrap());
        a.write("c/build.rs", "fn main() {}");
        let with_build = source_digest(&a.path().join("c"), "1.99.1").unwrap();
        assert_ne!(da, with_build);
        a.write("c/.cargo/config.toml", "[build]\n");
        assert_ne!(
            with_build,
            source_digest(&a.path().join("c"), "1.99.1").unwrap()
        );
        // src が無ければわけ
        std::fs::remove_dir_all(b.path().join("c").join("src")).unwrap();
        assert!(source_digest(&b.path().join("c"), "1.99.1").is_err());
    }

    #[test]
    fn decide_table() {
        let r = Record {
            source: "s".into(),
            exe: "e".into(),
        };
        assert_eq!(decide(None, Some(&r), "s"), Need::Missing);
        assert_eq!(
            decide(Some("e"), None, "s"),
            Need::Stale("作った控えが無い")
        );
        assert_eq!(
            decide(Some("e"), Some(&r), "t"),
            Need::Stale("元が変わった")
        );
        assert_eq!(
            decide(Some("f"), Some(&r), "s"),
            Need::Stale("置いた exe が控えと違う")
        );
        assert_eq!(decide(Some("e"), Some(&r), "s"), Need::Same);
    }
}
