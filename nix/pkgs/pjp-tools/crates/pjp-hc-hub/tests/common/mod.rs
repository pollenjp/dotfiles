//! 結合のテストの道具: 偽のホームの一時ディレクトリ (手元の ~/h・~/.gitconfig に触らない) と、本物の pjp-hub・git の
//! 打ち方。Linux と Windows の両方で流れる (Windows のディレクトリの link は junction)。

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

pub const HUB: &str = env!("CARGO_BIN_EXE_pjp-hub");

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// テストごとの一時ディレクトリ。`root` は symlink を解いた形 (Windows は 8.3 の短い名前も長い名前にした形)。Drop で消す。
pub struct Sandbox {
    pub root: PathBuf,
    pub home: PathBuf,
    pub gitconfig: PathBuf,
}

impl Sandbox {
    pub fn new(name: &str) -> Sandbox {
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir =
            std::env::temp_dir().join(format!("pjp-hc-hub-it-{}-{n}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let root = pjp_core::paths::real_path(&dir).unwrap();
        let home = root.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let gitconfig = root.join("gitconfig");
        std::fs::write(&gitconfig, "").unwrap();
        Sandbox {
            root,
            home,
            gitconfig,
        }
    }

    /// 偽のホームと、手元の git の設定・Claude Code が env で足す設定 (GIT_CONFIG_COUNT など) に左右されない env。
    /// 会話の形を決める env (hc の `HC_TERMINAL_ID`、T3 Code の `T3CODE_THREAD_ID`・`T3CODE_HOME`・`T3CODE_CLI_PATH`) も消す
    /// (T3 Code や herdr-app の会話の中で cargo test を流すと漏れ、本物の T3 の CLI を打つ)。その形を見るテストは、自分で足す。
    pub fn apply_env(&self, c: &mut Command) {
        for k in [
            "GIT_CONFIG_PARAMETERS",
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_COMMON_DIR",
            "CLAUDE_PROJECT_DIR",
            "HC_TERMINAL_ID",
            "T3CODE_THREAD_ID",
            "T3CODE_HOME",
            "T3CODE_CLI_PATH",
        ] {
            c.env_remove(k);
        }
        c.env("HOME", &self.home)
            .env("USERPROFILE", &self.home)
            .env("XDG_CONFIG_HOME", self.home.join(".config"))
            .env("GIT_CONFIG_GLOBAL", &self.gitconfig)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_COUNT", "0")
            .env("GIT_AUTHOR_NAME", "test")
            .env("GIT_AUTHOR_EMAIL", "test@example.com")
            .env("GIT_COMMITTER_NAME", "test")
            .env("GIT_COMMITTER_EMAIL", "test@example.com");
    }

    /// この偽のホームで描いた雛形の中身 ([`template_at`])。
    pub fn template(&self, source: &str) -> Vec<u8> {
        template_at(&self.home, source)
    }

    /// pjp-hub を打つ Command (cwd は root)。
    pub fn hub(&self, args: &[&str]) -> Command {
        let mut c = Command::new(HUB);
        c.args(args).current_dir(&self.root);
        self.apply_env(&mut c);
        c
    }

    /// git を打ち、成功を確かめて stdout を返す。
    pub fn git(&self, dir: &Path, args: &[&str]) -> String {
        let mut c = Command::new("git");
        c.arg("-C").arg(dir).args(args);
        self.apply_env(&mut c);
        let out = c.output().unwrap();
        assert!(
            out.status.success(),
            "git {args:?} in {}: {}",
            dir.display(),
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_owned()
    }

    /// `path` に書く (親のディレクトリも作る)。
    pub fn write(&self, path: &Path, contents: impl AsRef<[u8]>) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, contents).unwrap();
    }

    /// remote の無い repo を作る (`commit` なら CLAUDE.md を 1 つ commit する)。`origin` を付けると remote を足す。
    pub fn init_repo(&self, path: &Path, commit: bool, origin: Option<&str>) {
        std::fs::create_dir_all(path).unwrap();
        self.git(path, &["init", "-q", "-b", "main"]);
        if let Some(url) = origin {
            self.git(path, &["remote", "add", "origin", url]);
        }
        if commit {
            self.write(&path.join("CLAUDE.md"), "x\n");
            self.git(path, &["add", "CLAUDE.md"]);
            self.git(path, &["commit", "-q", "-m", "init"]);
        }
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// ディレクトリの link (Unix は symlink、Windows は junction。dotfiles が Windows で skill を張るのも junction)。
pub fn link_dir(link: &Path, target: &Path) {
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, link).unwrap();
    #[cfg(windows)]
    {
        let out = Command::new("cmd")
            .arg("/C")
            .arg("mklink")
            .arg("/J")
            .arg(link)
            .arg(target)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "mklink /J: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

pub fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

pub fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

/// 偽のホーム `home` で描いた雛形 (`assets/hub/<source>`) の中身 (改行は LF。重ねのファイルがあれば重ねる)。
pub fn template_at(home: &Path, source: &str) -> Vec<u8> {
    let ctx = pjp_hc_hub::templates::Context::at(home, cfg!(windows)).unwrap();
    pjp_hc_hub::templates::files(&ctx)
        .into_iter()
        .find(|t| t.source == source)
        .unwrap()
        .content()
        .as_bytes()
        .to_vec()
}

/// ハブの中のパス (`/` 区切り) → 雛形の名前。
pub const TEMPLATES: [(&str, &str); 3] = [
    ("CLAUDE.md", "CLAUDE.md"),
    (".claude/settings.json", "settings.json"),
    (".gitignore", "gitignore"),
];

/// `dir` の中の `rel` (`/` 区切り) のパス。
pub fn rel_path(dir: &Path, rel: &str) -> PathBuf {
    rel.split('/').fold(dir.to_path_buf(), |p, c| p.join(c))
}
