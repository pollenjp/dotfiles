//! 配った記録 (置き先のパス → 前回そこへ置いた中身の sha256)。
//!
//! 置き場は `%LOCALAPPDATA%\dotfiles\state\` で、名前と形は WSL の `~/.local/state/dotfiles/*.deployed.json` と同じ (JSON の object。
//! キーの順に並べて 2 字下げ。WSL の `jq -S .` と同じ形)。鍵は Windows のパス (dotfiles-private の docs/adr/058_win_runner_bootstrap_*
//! §2 H)。W0-2 などで足す手順も、記録が要ればこれを使う。

use crate::fsutil;
use std::path::{Path, PathBuf};

pub struct Records {
    path: PathBuf,
    map: serde_json::Map<String, serde_json::Value>,
    original: serde_json::Map<String, serde_json::Value>,
}

impl Records {
    /// 読む。ファイルが無ければ空。JSON の object でなければ、消し方を添えた文を返す。
    pub fn load(path: &Path) -> Result<Self, String> {
        let map = match std::fs::read_to_string(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => serde_json::Map::new(),
            Err(e) => return Err(format!("{} が読めません ({e})", path.display())),
            Ok(text) => match serde_json::from_str::<serde_json::Value>(&text) {
                Ok(serde_json::Value::Object(m)) => m,
                _ => {
                    return Err(format!(
                        "{} が壊れています (JSON の object ではありません)。消してから流し直すと、Windows 側に既にあるファイルは衝突として扱われます (中身を確かめて、取り込むか --force)",
                        path.display()
                    ));
                }
            },
        };
        Ok(Records {
            path: path.to_path_buf(),
            original: map.clone(),
            map,
        })
    }

    /// 記録した sha256 (文字列でない値は記録が無いものとして読む)。
    pub fn get(&self, key: &str) -> Option<&str> {
        self.map.get(key).and_then(|v| v.as_str())
    }

    pub fn set(&mut self, key: &str, value: &str) {
        self.map.insert(
            key.to_string(),
            serde_json::Value::String(value.to_string()),
        );
    }

    /// 変わっていれば書く。書いたら true。
    pub fn save_if_changed(&self) -> std::io::Result<bool> {
        if self.map == self.original && self.path.exists() {
            return Ok(false);
        }
        if self.map.is_empty() && !self.path.exists() {
            return Ok(false);
        }
        let text = serde_json::to_string_pretty(&self.map).map_err(std::io::Error::other)?;
        fsutil::write_atomic(&self.path, format!("{text}\n").as_bytes())?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 無ければ空、object でなければ消し方を添えて止める
    //! - キーの順に並べ 2 字下げで書く (jq -S . と同じ形)。変わらなければ書かない

    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn missing_is_empty_and_broken_is_an_error() {
        let t = TempDir::new("record");
        let p = t.path().join("state").join("windows-files.deployed.json");
        let r = Records::load(&p).unwrap();
        assert_eq!(r.get("x"), None);
        assert!(!r.save_if_changed().unwrap());
        assert!(!p.exists());
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, "[1]").unwrap();
        let e = Records::load(&p).err().unwrap();
        assert!(e.contains("壊れています"), "{e}");
    }

    #[test]
    fn writes_sorted_pretty_json_only_when_changed() {
        let t = TempDir::new("record");
        let p = t.path().join("state").join("r.json");
        let mut r = Records::load(&p).unwrap();
        r.set("b", "2");
        r.set("a", "1");
        assert!(r.save_if_changed().unwrap());
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "{\n  \"a\": \"1\",\n  \"b\": \"2\"\n}\n"
        );
        let mut r = Records::load(&p).unwrap();
        assert_eq!(r.get("a"), Some("1"));
        assert!(!r.save_if_changed().unwrap());
        r.set("a", "1");
        assert!(!r.save_if_changed().unwrap());
        r.set("a", "3");
        assert!(r.save_if_changed().unwrap());
    }
}
