//! 配った記録 (置き先のパス → 前回そこへ置いた中身の sha256)。
//!
//! 置き場は `%LOCALAPPDATA%\dotfiles\state\` で、名前と形は WSL の `~/.local/state/dotfiles/*.deployed.json` と同じ (JSON の object。
//! キーの順に並べて 2 字下げ。WSL の `jq -S .` と同じ形)。鍵は Windows のパス (dotfiles-private の docs/adr/058_win_runner_bootstrap_*
//! §2 H)。W0-2 などで足す手順も、記録が要ればこれを使う。
//!
//! 版つき・入れ子の記録 (`{"version":1,"files":{…}}`。WSL の ssh-config・port-forward の形) は `FileRecords`。

use crate::fsutil;
use serde_json::{Map, Value};
use std::path::{Path, PathBuf};

pub struct Records {
    path: PathBuf,
    map: serde_json::Map<String, serde_json::Value>,
    original: serde_json::Map<String, serde_json::Value>,
}

impl Records {
    /// 読む。ファイルが無ければ空。JSON の object でなければ、消し方を添えた文を返す。
    pub fn load(path: &Path) -> Result<Self, String> {
        Self::load_with(
            path,
            "消してから流し直すと、Windows 側に既にあるファイルは衝突として扱われます (中身を確かめて、取り込むか --force)",
        )
    }

    /// 読む (`load` と同じ)。壊れていたときの文の後半 (消した後にどうなるか) を `broken_hint` にする (記録の意味は手順ごとに違う)。
    pub fn load_with(path: &Path, broken_hint: &str) -> Result<Self, String> {
        let map = match std::fs::read_to_string(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => serde_json::Map::new(),
            Err(e) => return Err(format!("{} が読めません ({e})", path.display())),
            Ok(text) => match serde_json::from_str::<serde_json::Value>(&text) {
                Ok(serde_json::Value::Object(m)) => m,
                _ => {
                    return Err(format!(
                        "{} が壊れています (JSON の object ではありません)。{broken_hint}",
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

    /// 鍵を外す。在ったら true。
    pub fn remove(&mut self, key: &str) -> bool {
        self.map.remove(key).is_some()
    }

    /// 鍵の一覧 (キーの順)。
    pub fn keys(&self) -> Vec<String> {
        self.map.keys().cloned().collect()
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

/// 版つき・入れ子の配った記録 (`{"version":1,"files":{"<鍵>":"<sha256>"}}`)。WSL の `bootstrap-windows-ssh-config.sh`・
/// `bootstrap-windows-port-forward.sh` の記録 (`~/.local/state/dotfiles/windows-{ssh-config,port-forward}.deployed.json`) と同じ名前と形。
///
/// 鍵は置き先の基準の場所からの相対パス (`/` 区切り。ssh-config は `.ssh` からの `config`・`config.d/<名前>.ssh_config`、port-forward は
/// `hosts.json`)。どのマシンのパスでもないので、WSL と同じ鍵のまま持つ (ADR 058 §2 H の「Windows のパスを鍵に」は、鍵が WSL のパスだった
/// files・powershell-profile の記録の話)。書くときは `version` を 1 にし、キーの順に並べて 2 字下げにする (WSL の `jq -S '.version = 1'` と同じ
/// 形。知らないキーも残す)。
pub struct FileRecords {
    path: PathBuf,
    doc: Map<String, Value>,
    /// 読んだときの中身 (ファイルが無ければ None。WSL と同じく、無ければ中身によらず書く)
    original: Option<Map<String, Value>>,
}

impl FileRecords {
    /// 読む。ファイルが無ければ空。`files` を持つ JSON の object でなければ、`broken_hint` (消した後にどうなるか) を添えた文を返す。
    pub fn load(path: &Path, broken_hint: &str) -> Result<Self, String> {
        let (doc, original) = match std::fs::read_to_string(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let mut doc = Map::new();
                doc.insert("files".to_string(), Value::Object(Map::new()));
                doc.insert("version".to_string(), Value::from(1));
                (doc, None)
            }
            Err(e) => return Err(format!("{} が読めません ({e})", path.display())),
            Ok(text) => match serde_json::from_str::<Value>(&text) {
                Ok(Value::Object(m)) if m.get("files").is_some_and(Value::is_object) => {
                    (m.clone(), Some(m))
                }
                _ => {
                    return Err(format!(
                        "{} が壊れています (files を持つ JSON の object ではありません)。{broken_hint}",
                        path.display()
                    ));
                }
            },
        };
        Ok(FileRecords {
            path: path.to_path_buf(),
            doc,
            original,
        })
    }

    fn files(&self) -> &Map<String, Value> {
        self.doc
            .get("files")
            .and_then(Value::as_object)
            .expect("load が files の object を確かめた")
    }

    fn files_mut(&mut self) -> &mut Map<String, Value> {
        self.doc
            .get_mut("files")
            .and_then(Value::as_object_mut)
            .expect("load が files の object を確かめた")
    }

    /// 記録した sha256 (文字列でない値は記録が無いものとして読む)。
    pub fn get(&self, key: &str) -> Option<&str> {
        self.files().get(key).and_then(Value::as_str)
    }

    pub fn set(&mut self, key: &str, value: &str) {
        self.files_mut()
            .insert(key.to_string(), Value::String(value.to_string()));
    }

    /// 鍵を外す。在ったら true。
    pub fn remove(&mut self, key: &str) -> bool {
        self.files_mut().remove(key).is_some()
    }

    /// 鍵の一覧 (キーの順)。
    pub fn keys(&self) -> Vec<String> {
        self.files().keys().cloned().collect()
    }

    /// `version` を 1 にして、読んだときと違えば (ファイルが無かったときも) 書く。書いたら true。
    pub fn save_if_changed(&mut self) -> std::io::Result<bool> {
        self.doc.insert("version".to_string(), Value::from(1));
        if self.original.as_ref() == Some(&self.doc) {
            return Ok(false);
        }
        let text = serde_json::to_string_pretty(&self.doc).map_err(std::io::Error::other)?;
        fsutil::write_atomic(&self.path, format!("{text}\n").as_bytes())?;
        self.original = Some(self.doc.clone());
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 無ければ空、object でなければ消し方を添えて止める
    //! - キーの順に並べ 2 字下げで書く (jq -S . と同じ形)。変わらなければ書かない
    //! - 版つき・入れ子の記録: 無ければ空 (書けば version 1)、files の object が無ければ止める、知らないキーを残す、変わらなければ書かない

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

    /// 壊れていたときの文の後半は、手順ごとに替えられる (powershell-profile は「足した記録が無いものとして扱う」)
    #[test]
    fn broken_hint_can_be_replaced() {
        let t = TempDir::new("record");
        let p = t.write("state/r.json", "not json\n");
        let e = Records::load_with(&p, "消してから流し直してください")
            .err()
            .unwrap();
        assert_eq!(
            e,
            format!(
                "{} が壊れています (JSON の object ではありません)。消してから流し直してください",
                p.display()
            )
        );
    }

    /// 片付け (clone から消えたコピーを消す) で使う: 鍵を並べ、外す
    #[test]
    fn keys_and_remove() {
        let t = TempDir::new("record");
        let p = t.path().join("r.json");
        let mut r = Records::load(&p).unwrap();
        r.set("b", "2");
        r.set("a", "1");
        assert_eq!(r.keys(), vec!["a".to_string(), "b".to_string()]);
        assert!(r.remove("a"));
        assert!(!r.remove("a"));
        assert_eq!(r.keys(), vec!["b".to_string()]);
        assert!(r.save_if_changed().unwrap());
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "{\n  \"b\": \"2\"\n}\n"
        );
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

    /// 版つき・入れ子の記録は、無ければ空で、書けば version 1 の形 (WSL の jq -S と同じ並び)。WSL と同じく、無かったファイルは中身が空でも書く
    #[test]
    fn file_records_write_the_wsl_shape() {
        let t = TempDir::new("record");
        let p = t
            .path()
            .join("state")
            .join("windows-ssh-config.deployed.json");
        let mut r = FileRecords::load(&p, "x").unwrap();
        assert_eq!(r.get("config"), None);
        assert!(r.keys().is_empty());
        r.set("config.d/b.ssh_config", "2");
        r.set("config", "1");
        assert!(r.save_if_changed().unwrap());
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "{\n  \"files\": {\n    \"config\": \"1\",\n    \"config.d/b.ssh_config\": \"2\"\n  },\n  \"version\": 1\n}\n"
        );
        assert!(!r.save_if_changed().unwrap());
        let mut r = FileRecords::load(&p, "x").unwrap();
        assert_eq!(r.get("config"), Some("1"));
        assert_eq!(r.keys(), vec!["config", "config.d/b.ssh_config"]);
        assert!(!r.save_if_changed().unwrap());
        assert!(r.remove("config"));
        assert!(!r.remove("config"));
        assert!(r.save_if_changed().unwrap());
        assert_eq!(
            FileRecords::load(&p, "x").unwrap().keys(),
            vec!["config.d/b.ssh_config"]
        );

        let empty = t.path().join("state").join("empty.json");
        let mut r = FileRecords::load(&empty, "x").unwrap();
        assert!(r.save_if_changed().unwrap());
        assert_eq!(
            std::fs::read_to_string(&empty).unwrap(),
            "{\n  \"files\": {},\n  \"version\": 1\n}\n"
        );
    }

    /// 知らないキーは残し、version を 1 にそろえる。files の object が無い記録は、手順ごとの直し方を添えて止める
    #[test]
    fn file_records_keep_other_keys_and_reject_broken_ones() {
        let t = TempDir::new("record");
        let p = t.write(
            "state/r.json",
            "{\"version\":0,\"note\":\"x\",\"files\":{\"hosts.json\":\"a\",\"n\":1}}\n",
        );
        let mut r = FileRecords::load(&p, "x").unwrap();
        // 文字列でない値は記録が無いものとして読む
        assert_eq!(r.get("n"), None);
        assert_eq!(r.get("hosts.json"), Some("a"));
        assert!(r.save_if_changed().unwrap());
        let v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(
            v,
            serde_json::json!({"files": {"hosts.json": "a", "n": 1}, "note": "x", "version": 1})
        );

        for broken in ["not json\n", "[1]\n", "{}\n", "{\"files\":[]}\n"] {
            let p = t.write("state/broken.json", broken);
            let e = FileRecords::load(&p, "消してから流し直してください")
                .err()
                .unwrap_or_else(|| panic!("{broken}"));
            assert_eq!(
                e,
                format!(
                    "{} が壊れています (files を持つ JSON の object ではありません)。消してから流し直してください",
                    p.display()
                )
            );
        }
    }
}
