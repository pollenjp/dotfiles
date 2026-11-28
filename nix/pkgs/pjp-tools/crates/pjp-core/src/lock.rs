//! ファイルのロック (spec §6.6 の「ロック」。fcntl の代わりに std の `File::lock`)。

use std::fs::{File, OpenOptions, TryLockError};
use std::path::Path;

use crate::{Error, Result};

/// 持っている間だけ効く排他のロック。Drop で外す。
#[derive(Debug)]
pub struct FileLock {
    file: File,
}

/// `path` のロックを取る (取れるまで待つ)。ファイルと親のディレクトリが無ければ作る。
pub fn lock_exclusive(path: &Path) -> Result<FileLock> {
    let file = open(path)?;
    file.lock()
        .map_err(|e| Error::io(format!("{} のロックを取れません", path.display()), &e))?;
    Ok(FileLock { file })
}

/// `path` のロックを試す。ほかが持っていれば None。
pub fn try_lock_exclusive(path: &Path) -> Result<Option<FileLock>> {
    let file = open(path)?;
    match file.try_lock() {
        Ok(()) => Ok(Some(FileLock { file })),
        Err(TryLockError::WouldBlock) => Ok(None),
        Err(TryLockError::Error(e)) => Err(Error::io(
            format!("{} のロックを取れません", path.display()),
            &e,
        )),
    }
}

fn open(path: &Path) -> Result<File> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)
            .map_err(|e| Error::io(format!("{} を作れません", dir.display()), &e))?;
    }
    OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(path)
        .map_err(|e| Error::io(format!("{} を開けません", path.display()), &e))
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn lock_blocks_second_try() {
        let t = TempDir::new("lock");
        let path = t.path().join("state").join("inbox.lock");
        let held = lock_exclusive(&path).unwrap();
        assert!(path.is_file());
        assert!(try_lock_exclusive(&path).unwrap().is_none());
        drop(held);
        assert!(try_lock_exclusive(&path).unwrap().is_some());
    }
}
