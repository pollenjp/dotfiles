//! 入口 `pjp` を外から打つ結合のテスト。一時ディレクトリに `pjp` の写しと偽の道具を置いて打つ。
//!
//! ## 確かめること
//!
//! - `pjp hub|child|mark|pack <引数…>` は、同じディレクトリの `pjp-<道具>` に引数と stdin をそのまま渡し、その終了コードで終わる
//! - ほかの `pjp <引数…>` (`--build`・`--supervise` も) は `pjp-skills` (PATH → CARGO_HOME の bin → ~/.cargo/bin) に引数をそのまま渡し、
//!   その終了コードで終わる
//! - `pjp-skills` が無ければ、道具の名前と「private な claude-skills の道具で、このホストには入っていません」を出して終了コード 127
//! - 同じディレクトリに `pjp-<道具>` が無ければ、そのパスを出して終了コード 127
//! - `pjp-skills` が入口そのもの (入口の写しを置いた) なら、渡し合いを止めて終了コード 1
//! - 入口が自分で終えるときは 2 を使わない (Claude Code の hook は 2 を「止める」と読む。ハブの雛形の guard の hook は入口から打つ)
//! - `pjp --version` は `pjp <版>`・`key=<key>`・`pjp-skills=<場所か 無い>` の 3 行。`pjp --help` と引数なしは使い方 (公開の道具と
//!   終了コード 127) を出して 0
//!
//! 偽の道具は、このテストが rustc で作る小さな exe (引数と stdin を FAKE_LOG のファイルに書き、FAKE_EXIT の終了コードで終わる)。
//! Windows でも同じに作れるよう、shell の script にはしない

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};

const PJP: &str = env!("CARGO_BIN_EXE_pjp");
const EXE: &str = std::env::consts::EXE_SUFFIX;

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// exe を書く (写す) 間と、process を起こす (fork から exec まで) 間をそろえる鍵。テストは並んで走るので、あるテストが exe を
/// 書いている間にほかのテストが fork すると、子が exec するまで書き込みの fd を持ち、書き終えた exe を起こすと Linux は
/// ETXTBSY (Text file busy) で断る。書く間と起こす間を同じ鍵で包めば重ならない
static EXE_LOCK: Mutex<()> = Mutex::new(());

fn exe_lock() -> MutexGuard<'static, ()> {
    EXE_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// `src` の exe を `dest` に写す (鍵を持って)。
fn copy_exe(src: &Path, dest: &Path) {
    let _lock = exe_lock();
    std::fs::copy(src, dest).unwrap();
}

const FAKE_MAIN: &str = r#"
use std::io::Read;
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut input = String::new();
    let _ = std::io::stdin().read_to_string(&mut input);
    if let Ok(log) = std::env::var("FAKE_LOG") {
        std::fs::write(log, format!("{}\nstdin={input}", args.join("\n"))).unwrap();
    }
    let code: i32 = std::env::var("FAKE_EXIT").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
    std::process::exit(code);
}
"#;

/// rustc の場所: RUSTC → cargo の隣 (rustup の toolchain) → PATH の rustc。
fn rustc() -> PathBuf {
    if let Some(r) = std::env::var_os("RUSTC").filter(|v| !v.is_empty()) {
        return r.into();
    }
    if let Some(cargo) = std::env::var_os("CARGO") {
        let sibling = Path::new(&cargo).with_file_name(format!("rustc{EXE}"));
        if sibling.is_file() {
            return sibling;
        }
    }
    PathBuf::from("rustc")
}

/// 偽の道具の exe (テストの process で 1 回だけ作る)。
fn fake_exe() -> &'static Path {
    static FAKE: OnceLock<PathBuf> = OnceLock::new();
    FAKE.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("pjp-entry-fake-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("fake.rs");
        std::fs::write(&src, FAKE_MAIN).unwrap();
        let exe = dir.join(format!("fake{EXE}"));
        let child = {
            let _lock = exe_lock();
            Command::new(rustc())
                .args(["--edition", "2021", "-o"])
                .arg(&exe)
                .arg(&src)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .expect("rustc を起こせない")
        };
        let out = child.wait_with_output().expect("rustc を待てない");
        assert!(
            out.status.success(),
            "偽の道具を作れない: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        exe
    })
}

/// テストごとの一時ディレクトリ: `bin/` に pjp の写し、`skills/` に偽の pjp-skills を置く場所、偽のホームと CARGO_HOME。
struct Sandbox {
    root: PathBuf,
}

impl Sandbox {
    fn new(name: &str) -> Sandbox {
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let root =
            std::env::temp_dir().join(format!("pjp-entry-it-{}-{n}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for d in ["bin", "skills", "home", "cargo/bin"] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        copy_exe(Path::new(PJP), &root.join("bin").join(format!("pjp{EXE}")));
        Sandbox { root }
    }

    fn dir(&self, rel: &str) -> PathBuf {
        rel.split('/').fold(self.root.clone(), |p, c| p.join(c))
    }

    /// 偽の道具を `dir` に `name` (拡張子は OS の形) で置く。
    fn put(&self, dir: &str, name: &str) -> PathBuf {
        let p = self.dir(dir).join(format!("{name}{EXE}"));
        copy_exe(fake_exe(), &p);
        p
    }

    fn log(&self) -> PathBuf {
        self.root.join("log")
    }

    /// 偽の道具が書いた引数 (1 行 1 つ) と stdin。
    fn logged(&self) -> (Vec<String>, String) {
        let text = std::fs::read_to_string(self.log()).unwrap();
        let (args, stdin) = text.rsplit_once("\nstdin=").unwrap();
        let args = if args.is_empty() {
            Vec::new()
        } else {
            args.split('\n').map(str::to_owned).collect()
        };
        (args, stdin.to_owned())
    }

    /// `bin/pjp <args>` を打つ。PATH は `skills/` だけ (pjp-skills を置けば見える)、ホームと CARGO_HOME は砂場の中。
    fn run(&self, args: &[&str], exit: i32, stdin: &str) -> Output {
        let mut c = Command::new(self.dir("bin").join(format!("pjp{EXE}")));
        c.args(args)
            .env("PATH", self.dir("skills"))
            .env("HOME", self.dir("home"))
            .env("USERPROFILE", self.dir("home"))
            .env("CARGO_HOME", self.dir("cargo"))
            .env("FAKE_LOG", self.log())
            .env("FAKE_EXIT", exit.to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = {
            let _lock = exe_lock();
            c.spawn().unwrap()
        };
        // 入口が stdin を読まずに終わる (道具が無い) と、書く前にパイプが閉じる。それは咎めない (渡せたかは偽の道具の控えで見る)
        if let Err(e) = child.stdin.take().unwrap().write_all(stdin.as_bytes()) {
            assert_eq!(e.kind(), std::io::ErrorKind::BrokenPipe, "{e}");
        }
        child.wait_with_output().unwrap()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[test]
fn public_tool_gets_the_args_and_stdin_and_its_exit_code_is_kept() {
    for tool in ["hub", "child", "mark", "pack"] {
        let sb = Sandbox::new(tool);
        sb.put("bin", &format!("pjp-{tool}"));
        let out = sb.run(&[tool, "guard", "x y"], 7, "{\"a\":1}");
        assert_eq!(out.status.code(), Some(7), "{tool}: {}", text(&out.stderr));
        assert_eq!(
            sb.logged(),
            (
                vec!["guard".to_owned(), "x y".to_owned()],
                "{\"a\":1}".to_owned()
            ),
            "{tool}"
        );
    }
}

#[test]
fn other_args_go_to_pjp_skills_as_they_are() {
    let sb = Sandbox::new("skills");
    sb.put("skills", "pjp-skills");
    for (args, exit) in [
        (&["ticket", "show", "ABC-1", "--url"][..], 3),
        (&["--build"][..], 0),
        (&["--supervise", "hubd", "--once"][..], 75),
        (&["hubd"][..], 1),
    ] {
        let out = sb.run(args, exit, "");
        assert_eq!(
            out.status.code(),
            Some(exit),
            "{args:?}: {}",
            text(&out.stderr)
        );
        assert_eq!(sb.logged().0, args, "{args:?}");
    }
}

#[test]
fn pjp_skills_is_also_found_in_cargo_home() {
    let sb = Sandbox::new("cargo-home");
    sb.put("cargo/bin", "pjp-skills");
    let out = sb.run(&["notion-profile", "show"], 0, "");
    assert_eq!(out.status.code(), Some(0), "{}", text(&out.stderr));
    assert_eq!(sb.logged().0, ["notion-profile", "show"]);
}

#[test]
fn without_pjp_skills_a_private_tool_exits_127() {
    let sb = Sandbox::new("no-skills");
    let out = sb.run(&["ticket", "list"], 0, "");
    assert_eq!(out.status.code(), Some(127));
    let err = text(&out.stderr);
    assert!(
        err.contains("pjp ticket は private な claude-skills の道具で、このホストには入っていません (pjp-skills が無い)"),
        "{err}"
    );
    assert!(!sb.log().exists());
}

#[test]
fn missing_public_tool_names_its_path_and_exits_127() {
    let sb = Sandbox::new("no-hub");
    // hook の guard と同じ打ち方 (2 で終わると、ハブの会話の Write / Edit が全部止まる)
    let out = sb.run(&["hub", "guard"], 0, "{}");
    assert_eq!(out.status.code(), Some(127), "{}", text(&out.stderr));
    let err = text(&out.stderr);
    let want = sb.dir("bin").join(format!("pjp-hub{EXE}"));
    assert!(err.contains(&want.display().to_string()), "{err}");
}

#[test]
fn pjp_skills_that_is_this_entry_stops_with_1() {
    let sb = Sandbox::new("skills-is-entry");
    copy_exe(
        Path::new(PJP),
        &sb.dir("skills").join(format!("pjp-skills{EXE}")),
    );
    let out = sb.run(&["ticket", "list"], 0, "");
    assert_eq!(out.status.code(), Some(1), "{}", text(&out.stderr));
    let err = text(&out.stderr);
    assert!(err.contains("は公開の入口 pjp そのものです"), "{err}");
}

#[test]
fn version_has_three_lines() {
    let sb = Sandbox::new("version");
    let out = sb.run(&["--version"], 0, "");
    assert_eq!(out.status.code(), Some(0));
    let so = text(&out.stdout);
    let lines: Vec<&str> = so.lines().collect();
    assert_eq!(lines.len(), 3, "{so}");
    assert_eq!(lines[0], format!("pjp {}", env!("CARGO_PKG_VERSION")));
    assert!(lines[1].starts_with("key="), "{so}");
    assert_eq!(lines[2], "pjp-skills=無い");
    let skills = sb.put("skills", "pjp-skills");
    let so = text(&sb.run(&["--version"], 0, "").stdout);
    assert_eq!(
        so.lines().nth(2),
        Some(format!("pjp-skills={}", skills.display()).as_str())
    );
}

#[test]
fn help_names_the_public_tools_and_the_exit_code() {
    let sb = Sandbox::new("help");
    for args in [&["--help"][..], &[][..]] {
        let out = sb.run(args, 0, "");
        assert_eq!(out.status.code(), Some(0), "{args:?}");
        let so = text(&out.stdout);
        for want in [
            "pjp hub",
            "pjp child",
            "pjp mark",
            "pjp pack",
            "pjp-skills",
            "127",
        ] {
            assert!(so.contains(want), "{want}: {so}");
        }
    }
}
