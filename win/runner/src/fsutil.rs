//! ファイルの小さな道具 (sha256・置き先と同じディレクトリの一時ファイルから rename で書く・書く前の中身の写し)。

use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

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

/// UTC の年・月・日・時・分・秒 (1970-01-01 からの日数を暦の年月日にする。Howard Hinnant の civil_from_days)。
pub fn utc_fields(t: SystemTime) -> [i64; 6] {
    let secs = t
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let (days, rem) = ((secs / 86_400) as i64, (secs % 86_400) as i64);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    [year, month, day, rem / 3_600, rem % 3_600 / 60, rem % 60]
}

/// 1 回の apply で書き換えるファイルの退避 (WSL の terminal・fancyzones の退避と同じ形: `<root>\<UTC の YYYYMMDDThhmmssZ>-<pid>\<ファイル名>`。
/// 新しい方から `keep` 回分)。初めて写すときにディレクトリを作り、写せたら古いものを消す。写せなければ作ったディレクトリを消し、古いものは残す。
pub struct RunBackup {
    root: PathBuf,
    keep: usize,
    dir: Option<PathBuf>,
}

impl RunBackup {
    pub fn new(root: PathBuf, keep: usize) -> RunBackup {
        RunBackup {
            root,
            keep,
            dir: None,
        }
    }

    /// 退避の置き場 (`<root>`)
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// この回に写したディレクトリ (まだ写していなければ None)
    pub fn dir(&self) -> Option<&Path> {
        self.dir.as_deref()
    }

    /// 書き換える前の `path` を写す (無ければ何もしない)。同じ回に写すファイルは同じディレクトリに入る
    pub fn copy(&mut self, path: &Path) -> std::io::Result<()> {
        if !path.exists() {
            return Ok(());
        }
        let fresh = self.dir.is_none();
        let dir = match &self.dir {
            Some(d) => d.clone(),
            None => create_run_dir(&self.root)?,
        };
        if let Err(e) = copy_into(path, &dir) {
            if fresh {
                let _ = std::fs::remove_dir_all(&dir);
            }
            return Err(e);
        }
        if fresh {
            prune_runs(&self.root, self.keep, &dir);
            self.dir = Some(dir);
        }
        Ok(())
    }
}

/// 1 回ぶんの退避のディレクトリを作る (同じ名前があれば `-<nnn>` を足す。名前の順が作った順になるよう 0 で埋める)
fn create_run_dir(root: &Path) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(root)?;
    let [y, mo, d, h, mi, s] = utc_fields(SystemTime::now());
    let base = format!(
        "{y:04}{mo:02}{d:02}T{h:02}{mi:02}{s:02}Z-{}",
        std::process::id()
    );
    let mut name = base.clone();
    let mut n = 0;
    loop {
        let dir = root.join(&name);
        match std::fs::create_dir(&dir) {
            Ok(()) => return Ok(dir),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                n += 1;
                name = format!("{base}-{n:03}");
            }
            Err(e) => return Err(e),
        }
    }
}

/// `root` の下のディレクトリを、名前の順 (時刻の順) で古いものから消して、`made` を含めて `keep` 個を残す (`made` は消さない)
fn prune_runs(root: &Path, keep: usize, made: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    let made_name = made.file_name().map(|n| n.to_os_string());
    let mut olds: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter(|e| Some(e.file_name()) != made_name)
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    olds.sort();
    let keep_old = keep.saturating_sub(1);
    if olds.len() > keep_old {
        for old in &olds[..olds.len() - keep_old] {
            let _ = std::fs::remove_dir_all(root.join(old));
        }
    }
}

/// `src` を `dir` に同じ名前で写し、写した先を返す (更新時刻も写す。WSL の `cp -p`)。
pub fn copy_into(src: &Path, dir: &Path) -> std::io::Result<PathBuf> {
    let name = src.file_name().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "ファイルの名前が無い")
    })?;
    let dst = dir.join(name);
    std::fs::copy(src, &dst)?;
    if let Ok(modified) = std::fs::metadata(src).and_then(|m| m.modified()) {
        let _ = std::fs::File::options()
            .write(true)
            .open(&dst)
            .and_then(|f| f.set_modified(modified));
    }
    Ok(dst)
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
    //! - 1 回ぶんの退避: UTC の時刻と pid の名前・名前の順が作った順・同じ回は同じディレクトリ・新しい方から N 回分 (ファイルは数えず消さない)・
    //!   更新時刻も写る・無いファイルは写さない・写せなければ作ったディレクトリを消して古いものを残す
    //! - UTC の年月日 (うるう年)

    use super::*;
    use crate::testutil::TempDir;
    use std::time::Duration;

    #[test]
    fn utc_fields_are_civil() {
        let at = |secs: u64| utc_fields(SystemTime::UNIX_EPOCH + Duration::from_secs(secs));
        assert_eq!(at(0), [1970, 1, 1, 0, 0, 0]);
        // 2026-11-20 08:35:28 JST = 2026-11-19 23:35:28 UTC
        assert_eq!(at(1_795_131_328), [2026, 11, 19, 23, 35, 28]);
        assert_eq!(at(1_709_164_800), [2024, 2, 29, 0, 0, 0]);
        assert_eq!(at(951_782_400), [2000, 2, 29, 0, 0, 0]);
    }

    #[test]
    fn run_backups_keep_the_newest() {
        let t = TempDir::new("fsutil-run-dir");
        let root = t.path().join("backup");
        t.write("backup/note.txt", "x");
        // 古い名前のディレクトリ (前の回の退避)
        for i in 0..3 {
            std::fs::create_dir_all(root.join(format!("2000010{i}T000000Z-1"))).unwrap();
        }
        let src = t.write("settings.json", "{}\n");
        let other = t.write("other.json", "[]\n");
        let old = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000_000);
        std::fs::File::options()
            .write(true)
            .open(&src)
            .unwrap()
            .set_modified(old)
            .unwrap();
        // 無いファイルは写さず、ディレクトリも作らない
        let mut b0 = RunBackup::new(root.clone(), 3);
        b0.copy(&t.path().join("missing.json")).unwrap();
        assert!(b0.dir().is_none());
        // 1 回目: 同じ回のファイルは同じディレクトリに入る。更新時刻も写る
        let mut b1 = RunBackup::new(root.clone(), 3);
        b1.copy(&src).unwrap();
        b1.copy(&other).unwrap();
        let a = b1.dir().unwrap().to_path_buf();
        assert_eq!(
            std::fs::read_to_string(a.join("settings.json")).unwrap(),
            "{}\n"
        );
        assert_eq!(
            std::fs::read_to_string(a.join("other.json")).unwrap(),
            "[]\n"
        );
        assert_eq!(
            std::fs::metadata(a.join("settings.json"))
                .unwrap()
                .modified()
                .unwrap(),
            old
        );
        let name = a.file_name().unwrap().to_string_lossy().into_owned();
        let pid = std::process::id().to_string();
        assert!(name.len() >= 17 + pid.len(), "{name}");
        assert!(
            name[..8].bytes().all(|c| c.is_ascii_digit()) && &name[8..9] == "T",
            "{name}"
        );
        assert!(
            name[9..15].bytes().all(|c| c.is_ascii_digit()) && &name[15..17] == "Z-",
            "{name}"
        );
        assert!(name[17..].starts_with(&pid), "{name}");
        // 2 回目: 別のディレクトリで、名前の順は作った順 (同じ秒なら -001)
        let mut b2 = RunBackup::new(root.clone(), 3);
        b2.copy(&src).unwrap();
        let b = b2.dir().unwrap().to_path_buf();
        assert_ne!(a, b);
        assert!(
            b.file_name().unwrap() > a.file_name().unwrap(),
            "{a:?} {b:?}"
        );
        let mut dirs: Vec<String> = std::fs::read_dir(&root)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        dirs.sort();
        // 新しい方から 3 つ (作ったものを含む)。ファイルは数えず消さない
        assert_eq!(dirs.len(), 4, "{dirs:?}");
        assert_eq!(dirs[0], "20000102T000000Z-1");
        assert!(dirs.contains(&"note.txt".to_string()), "{dirs:?}");
        // 写せなければ (ディレクトリを写そうとした)、作ったディレクトリを消し、古いものは残す
        let mut b3 = RunBackup::new(root.clone(), 1);
        assert!(b3.copy(&root.join("20000102T000000Z-1")).is_err());
        assert!(b3.dir().is_none());
        let mut after: Vec<String> = std::fs::read_dir(&root)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        after.sort();
        assert_eq!(after, dirs);
    }

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
