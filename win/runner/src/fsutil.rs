//! ファイルの小さな道具 (sha256・置き先と同じディレクトリの一時ファイルから rename で書く)。

use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

static TMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// ファイルの中身の sha256 (16 進の小文字)。
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    let bytes = std::fs::read(path)?;
    Ok(sha256_bytes(&bytes))
}

pub fn sha256_bytes(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// `path` に書く。置き先と同じディレクトリの一時ファイル (`<名前>.dotfiles-tmp.<pid>.<n>`) に書いてから rename する (途中で落ちても
/// 壊れたファイルを残さない。WSL の `bootstrap-windows-files.sh` の place と同じ)。親のディレクトリが無ければ作る。
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "親のディレクトリが無い")
    })?;
    std::fs::create_dir_all(dir)?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = dir.join(format!(
        "{name}.dotfiles-tmp.{}.{}",
        std::process::id(),
        TMP_COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let result = (|| {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// `src` の中身を `dst` に書く (`write_atomic`)。
pub fn read_then_write(src: &Path, dst: &Path) -> std::io::Result<()> {
    let bytes = std::fs::read(src)?;
    write_atomic(dst, &bytes)
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - sha256 が sha256sum と同じ値 (空と "abc" の既知の値)
    //! - 親を作って書き、あるファイルは置き換え、一時ファイルを残さない

    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn sha256_known_values() {
        assert_eq!(
            sha256_bytes(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_bytes(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn writes_atomically() {
        let t = TempDir::new("fsutil");
        let p = t.path().join("a").join("b.json");
        write_atomic(&p, b"one").unwrap();
        write_atomic(&p, b"two").unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"two");
        let names: Vec<String> = std::fs::read_dir(p.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["b.json"]);
        assert_eq!(sha256_file(&p).unwrap(), sha256_bytes(b"two"));
    }
}
