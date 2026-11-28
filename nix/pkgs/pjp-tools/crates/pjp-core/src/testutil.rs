//! pjp-core のテストの小さな道具 (一時ディレクトリ)。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// テストごとの一時ディレクトリ。Drop で消す。
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(name: &str) -> Self {
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let path =
            std::env::temp_dir().join(format!("pjp-core-test-{}-{n}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("一時ディレクトリを作れない");
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// `rel` (`/` 区切り) にファイルを書く。親のディレクトリも作る。
    pub fn write(&self, rel: &str, contents: impl AsRef<[u8]>) -> PathBuf {
        let p = self.path.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, contents).unwrap();
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
