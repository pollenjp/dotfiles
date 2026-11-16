//! コマンドとしての試験と突き合わせの試験で使う一時ディレクトリ (crate を足さない)。drop で消す。

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(0);

pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(tag: &str) -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "dotfiles-win-it-{tag}-{}-{n}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("一時ディレクトリを作れない");
        TempDir(dir)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }

    /// `rel` (`/` 区切り) にファイルを書く。親のディレクトリも作る。
    pub fn write(&self, rel: &str, content: &str) -> PathBuf {
        let p = self.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, content).unwrap();
        p
    }

    /// `rel` (`/` 区切り) のパス
    pub fn join(&self, rel: &str) -> PathBuf {
        let mut p = self.0.clone();
        for seg in rel.split('/') {
            p.push(seg);
        }
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// PATH からコマンドを探す
pub fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join(name))
        .find(|p| p.is_file())
}
