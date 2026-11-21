//! 試験の道具: 消える一時ディレクトリと、PATH に置く偽のコマンド。

#![allow(dead_code)]

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// drop で消える一時ディレクトリ
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> TempDir {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "claude-selector-{tag}-{}-{}-{nanos}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }

    /// `rel` (`/` 区切り) に書く (dir も作る)
    pub fn write(&self, rel: &str, content: &str) -> PathBuf {
        let p = rel.split('/').fold(self.0.clone(), |p, s| p.join(s));
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, content).unwrap();
        p
    }

    /// `dir` (`/` 区切り) に、実行できる偽のコマンド `name` を置く (Windows は `<name>.exe`)
    pub fn command(&self, dir: &str, name: &str) -> PathBuf {
        let p = self.write(
            &format!("{dir}/{name}{}", std::env::consts::EXE_SUFFIX),
            "#!/bin/sh\nexit 0\n",
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        p
    }

    /// PATH の値 (この下の dir を並べる)
    pub fn path_var(&self, dirs: &[&str]) -> OsString {
        std::env::join_paths(
            dirs.iter()
                .map(|d| d.split('/').fold(self.0.clone(), |p, s| p.join(s))),
        )
        .unwrap()
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
