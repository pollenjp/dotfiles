//! テストの土台 (これ自体はテストではない)。一時ディレクトリに、ユーザーの git の設定 (署名・hook) から切り離した
//! HOME と、bare の remote・push する seed・試す work の clone を作る。Drop で一時ディレクトリを消す。

#![allow(dead_code)]

use std::ffi::OsString;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use pjp_ghq_pull::git::Git;

static SEQ: AtomicUsize = AtomicUsize::new(0);

pub struct Sandbox {
    pub root: PathBuf,
    env: Vec<(OsString, OsString)>,
}

/// bare の remote と、そこへ push する seed と、pjp-ghq-pull で試す work の clone
pub struct Repo {
    pub remote: PathBuf,
    pub seed: PathBuf,
    pub work: PathBuf,
}

impl Sandbox {
    pub fn new(name: &str) -> Sandbox {
        let n = SEQ.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!(
            "pjp-ghq-pull-test-{}-{n}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("home")).unwrap();
        std::fs::create_dir_all(root.join("bin")).unwrap();
        let gitconfig = root.join("gitconfig");
        std::fs::write(
            &gitconfig,
            "[user]\n\tname = tester\n\temail = tester@example.com\n\
             [init]\n\tdefaultBranch = main\n\
             [commit]\n\tgpgSign = false\n\
             [tag]\n\tgpgSign = false\n\
             [advice]\n\tdetachedHead = false\n",
        )
        .unwrap();
        let env = vec![
            (OsString::from("HOME"), root.join("home").into_os_string()),
            (
                OsString::from("XDG_CONFIG_HOME"),
                root.join("home/.config").into_os_string(),
            ),
            (
                OsString::from("GIT_CONFIG_GLOBAL"),
                gitconfig.into_os_string(),
            ),
            (OsString::from("GIT_CONFIG_NOSYSTEM"), OsString::from("1")),
            // 呼んだ側の env の設定 (Claude のセッションの commit.gpgsign=false など) も効かせない
            (OsString::from("GIT_CONFIG_COUNT"), OsString::from("0")),
            (OsString::from("GIT_CONFIG_PARAMETERS"), OsString::new()),
        ];
        Sandbox { root, env }
    }

    /// 子の git に渡す env (一時の HOME と git の設定)
    pub fn env(&self) -> Vec<(OsString, OsString)> {
        self.env.clone()
    }

    /// env に、偽のコマンドを置く bin を先頭にした PATH を足したもの
    pub fn env_with_bin(&self) -> Vec<(OsString, OsString)> {
        let mut env = self.env();
        env.push((OsString::from("PATH"), self.path_with_bin()));
        env
    }

    /// 偽のコマンドを置く bin を先頭にした PATH
    pub fn path_with_bin(&self) -> OsString {
        let mut path = self.root.join("bin").into_os_string();
        if let Some(rest) = std::env::var_os("PATH") {
            path.push(":");
            path.push(rest);
        }
        path
    }

    pub fn bin(&self) -> PathBuf {
        self.root.join("bin")
    }

    pub fn path(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }

    fn command(&self, dir: &Path, args: &[&str]) -> Command {
        let mut cmd = Command::new("git");
        cmd.arg("-C").arg(dir).args(args);
        for (k, v) in &self.env {
            cmd.env(k, v);
        }
        cmd
    }

    /// git を流し、stdout (前後の空白を除く) を返す。落ちたら panic
    pub fn git(&self, dir: &Path, args: &[&str]) -> String {
        let out = self.command(dir, args).output().unwrap();
        assert!(
            out.status.success(),
            "git {args:?} in {}: {}",
            dir.display(),
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    /// git を流し、成否を返す (落ちることを確かめるとき)
    pub fn git_ok(&self, dir: &Path, args: &[&str]) -> bool {
        self.command(dir, args).output().unwrap().status.success()
    }

    /// bare の remote と seed・work の clone を作る。seed から 1 commit (a.txt) を push してから work を clone する
    pub fn repo(&self, name: &str) -> Repo {
        let remote = self.root.join(format!("remote/{name}.git"));
        let seed = self.root.join(format!("seed/{name}"));
        let work = self.root.join(format!("work/{name}"));
        std::fs::create_dir_all(&remote).unwrap();
        self.git(&remote, &["init", "-q", "--bare"]);
        self.clone_to(&remote, &seed);
        self.commit(&seed, "a.txt", "a\n", "a");
        self.push(&seed);
        self.clone_to(&remote, &work);
        Repo { remote, seed, work }
    }

    pub fn clone_to(&self, remote: &Path, dir: &Path) {
        std::fs::create_dir_all(dir.parent().unwrap()).unwrap();
        let mut cmd = Command::new("git");
        cmd.arg("clone").arg("-q").arg(remote).arg(dir);
        for (k, v) in &self.env {
            cmd.env(k, v);
        }
        let out = cmd.output().unwrap();
        assert!(
            out.status.success(),
            "git clone: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    /// file に content を書いて commit する
    pub fn commit(&self, dir: &Path, file: &str, content: &str, msg: &str) {
        std::fs::write(dir.join(file), content).unwrap();
        self.git(dir, &["add", file]);
        self.git(dir, &["commit", "-q", "-m", msg]);
    }

    /// 今の branch を origin へ push する
    pub fn push(&self, dir: &Path) {
        self.git(dir, &["push", "-q", "origin", "HEAD"]);
    }

    pub fn head(&self, dir: &Path) -> String {
        self.git(dir, &["rev-parse", "HEAD"])
    }

    pub fn runner(&self, via_gh: bool, timeout: Duration) -> Git {
        Git::new(via_gh, timeout, self.env_with_bin())
    }

    /// 既定の runner (gitViaGh は off・時間切れ 30 秒)
    pub fn plain(&self) -> Git {
        self.runner(false, Duration::from_secs(30))
    }

    /// bin に偽のコマンドを置く。shebang は PATH の sh (Nix のサンドボックスには /usr/bin/env が無い)
    pub fn fake_bin(&self, name: &str, body: &str) -> PathBuf {
        let path = self.bin().join(name);
        std::fs::write(&path, format!("#!{}\n{body}\n", sh().display())).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// PATH の sh (見つからなければ /bin/sh)
pub fn sh() -> PathBuf {
    std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|dir| dir.join("sh"))
                .find(|p| p.is_file())
        })
        .unwrap_or_else(|| PathBuf::from("/bin/sh"))
}

/// ratatui の Buffer を行ごとの文字列にする (全角の文字の続きのセルは飛ばす)
pub fn screen(buf: &ratatui::buffer::Buffer) -> Vec<String> {
    let area = buf.area;
    (area.y..area.y + area.height)
        .map(|y| {
            let mut line = String::new();
            let mut skip = 0;
            for x in area.x..area.x + area.width {
                let sym = buf[(x, y)].symbol();
                if skip > 0 {
                    skip -= 1;
                    continue;
                }
                line.push_str(sym);
                skip = ratatui::text::Span::raw(sym).width().saturating_sub(1);
            }
            line
        })
        .collect()
}

/// 画面に text を含む行があるか
pub fn shows(buf: &ratatui::buffer::Buffer, text: &str) -> bool {
    screen(buf).iter().any(|l| l.contains(text))
}

/// text の最初の 1 字のセルの前景色
pub fn fg_of(buf: &ratatui::buffer::Buffer, text: &str) -> Option<ratatui::style::Color> {
    let first = text.chars().next()?.to_string();
    let area = buf.area;
    for y in area.y..area.y + area.height {
        let line = screen(buf)[(y - area.y) as usize].clone();
        if !line.contains(text) {
            continue;
        }
        for x in area.x..area.x + area.width {
            if buf[(x, y)].symbol() == first {
                return buf[(x, y)].fg.into();
            }
        }
    }
    None
}

/// PATH の本物の git (bin に偽の git を置くテストが、そこから本物へ渡すため)
pub fn real_git() -> PathBuf {
    std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|dir| dir.join("git"))
                .find(|p| p.is_file())
        })
        .expect("PATH に git が無い")
}
