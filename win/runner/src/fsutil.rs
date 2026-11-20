//! ファイルの小さな道具 (sha256・置き先と同じディレクトリの一時ファイルから rename で書く・書く前の中身の写し)。

use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
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

/// 書く前のファイル `path` を `dir\<prefix>-<秒>-<ナノ秒>.json` に写し、写した先を返す (同じ時刻の写しは上書きせず `-<n>` を足す)。`dir` の
/// `<prefix>-*.json` のうち、残すのは、いちばん古いもの (dotfiles の手順が初めて書く前の中身) と、新しい方から `keep` 個。
pub fn backup_copy(path: &Path, dir: &Path, prefix: &str, keep: usize) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let stamp = format!("{:012}-{:09}", now.as_secs(), now.subsec_nanos());
    let mut name = format!("{prefix}-{stamp}.json");
    let mut n = 0;
    while dir.join(&name).exists() {
        n += 1;
        name = format!("{prefix}-{stamp}-{n}.json");
    }
    std::fs::copy(path, dir.join(&name))?;
    let head = format!("{prefix}-");
    let mut olds: Vec<String> = std::fs::read_dir(dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with(&head) && n.ends_with(".json"))
        .collect();
    olds.sort();
    if olds.len() > keep + 1 {
        for old in &olds[1..olds.len() - keep] {
            let _ = std::fs::remove_file(dir.join(old));
        }
    }
    Ok(dir.join(name))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - sha256 が sha256sum と同じ値 (空と "abc" の既知の値)
    //! - 親を作って書き、あるファイルは置き換え、一時ファイルを残さない
    //! - 書く前の写し: 中身を写し、いちばん古いものと新しい方から N 個を残す。ほかの prefix のファイルには触らない

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

    #[test]
    fn backup_copy_keeps_the_first_and_newest() {
        let t = TempDir::new("fsutil-backup");
        let src = t.path().join("a.json");
        let dir = t.path().join("backup");
        t.write("backup/other-1.json", "x");
        for i in 0..5 {
            std::fs::write(&src, format!("{i}")).unwrap();
            let copied = backup_copy(&src, &dir, "a", 2).unwrap();
            assert_eq!(std::fs::read_to_string(&copied).unwrap(), format!("{i}"));
        }
        let mut names: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        let kept: Vec<String> = names
            .iter()
            .filter(|n| n.starts_with("a-") && n.ends_with(".json"))
            .map(|n| std::fs::read_to_string(dir.join(n)).unwrap())
            .collect();
        assert_eq!(kept, vec!["0", "3", "4"], "{names:?}");
        assert!(names.contains(&"other-1.json".to_string()), "{names:?}");
    }
}
