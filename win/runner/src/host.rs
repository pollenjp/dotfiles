//! ホストの値 (dotfiles-private の `win/hosts/<Windows のユーザー名>@<PC の名前>.toml`) と、設定グループの写し (`groups.json`)。
//!
//! ホストの値は WSL の Nix のホスト (`nix/hosts/<user>@<hostname>.nix`) に当たる。書けるのは設定グループ (`group`)・道具の switch の上書き
//! (`[tools]`。`group.json` の `tools` と同じ名前)・受け持ちの印 (`[runner] enable`) だけ。書いていない道具の既定は、Nix がグループごとの
//! 素のホストから書き出した `groups.json` (`nix eval --raw ./nix#lib.windowsGroupsJson`) から引く (dotfiles-private の
//! docs/adr/058_win_runner_bootstrap_* §2 H)。
//!
//! ```toml
//! group = "personal"            # personal (既定)・company・client
//!
//! [tools]
//! windowsTypeClipboard = true
//!
//! [runner]
//! enable = false                # true で apply を許す (WSL の windowsFiles.enable = false と同じ PR で変える)
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// `groups.json` の中身 (グループごとの道具の switch の既定)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Groups {
    pub default: String,
    groups: BTreeMap<String, BTreeMap<String, bool>>,
}

impl Groups {
    /// build に埋めた `win/runner/groups.json`。
    pub fn embedded() -> Result<Self, String> {
        Self::parse(include_str!("../groups.json"))
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        let bad = |what: &str| {
            format!(
                "win/runner/groups.json が読めません ({what})。dotfiles の root で出し直す: nix eval --raw ./nix#lib.windowsGroupsJson > win/runner/groups.json"
            )
        };
        let v: serde_json::Value = serde_json::from_str(text).map_err(|e| bad(&e.to_string()))?;
        if v["version"] != 1 {
            return Err(bad("version が 1 でない"));
        }
        let default = v["default"]
            .as_str()
            .ok_or_else(|| bad("default が無い"))?
            .to_string();
        let mut groups = BTreeMap::new();
        for (name, g) in v["groups"]
            .as_object()
            .ok_or_else(|| bad("groups が無い"))?
        {
            let mut tools = BTreeMap::new();
            for (k, t) in g["tools"]
                .as_object()
                .ok_or_else(|| bad(&format!("{name} の tools が無い")))?
            {
                let b = t
                    .as_bool()
                    .ok_or_else(|| bad(&format!("{name} の tools.{k} が bool でない")))?;
                tools.insert(k.clone(), b);
            }
            groups.insert(name.clone(), tools);
        }
        if !groups.contains_key(&default) {
            return Err(bad("default のグループが groups に無い"));
        }
        Ok(Groups { default, groups })
    }

    pub fn names(&self) -> Vec<&str> {
        self.groups.keys().map(String::as_str).collect()
    }

    fn tools(&self, group: &str) -> Option<&BTreeMap<String, bool>> {
        self.groups.get(group)
    }

    fn knows_tool(&self, key: &str) -> bool {
        self.groups.values().any(|t| t.contains_key(key))
    }
}

/// ホストの値をどこから読んだか。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// このファイルを読んだ
    File(PathBuf),
    /// このファイルが無い (グループの既定で確かめる)
    Missing(PathBuf),
}

/// ホストの値 (グループの既定と上書きを合わせたもの)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostValues {
    pub group: String,
    pub overrides: BTreeMap<String, bool>,
    pub runner_enable: bool,
    pub source: Source,
    groups: Groups,
}

impl HostValues {
    /// ファイルが無いときの値 (グループの既定・受け持ちは WSL)。
    pub fn missing(path: &Path, groups: Groups) -> Self {
        HostValues {
            group: groups.default.clone(),
            overrides: BTreeMap::new(),
            runner_enable: false,
            source: Source::Missing(path.to_path_buf()),
            groups,
        }
    }

    /// 道具の switch の値 (上書き → グループの既定 → false)。
    pub fn tool(&self, key: &str) -> bool {
        if let Some(b) = self.overrides.get(key) {
            return *b;
        }
        self.groups
            .tools(&self.group)
            .and_then(|t| t.get(key))
            .copied()
            .unwrap_or(false)
    }

    /// 道具の switch の値がどこで決まったか (一覧と off の行に添える)。
    pub fn tool_origin(&self, key: &str) -> String {
        if self.overrides.contains_key(key) {
            "ホストの値".to_string()
        } else {
            format!("グループ {} の既定", self.group)
        }
    }
}

/// ホストの値の既定の置き場所: dotfiles の clone の隣の dotfiles-private の `win/hosts/<user>@<pc>.toml`。
pub fn default_path(repo: &Path, user: &str, pc: &str) -> PathBuf {
    let owner = repo.parent().unwrap_or(repo);
    owner
        .join("dotfiles-private")
        .join("win")
        .join("hosts")
        .join(format!("{user}@{pc}.toml"))
}

/// ホストの値を読む。ファイルが無ければ `Source::Missing` の値 (誤りではない)。読めない・誤りがあれば文を返す。
pub fn load(path: &Path, groups: Groups) -> Result<HostValues, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => parse(&text, path, groups),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(HostValues::missing(path, groups)),
        Err(e) => Err(format!("{}: 読めません ({e})", path.display())),
    }
}

/// ホストの値の文を読む (`load` の中身)。
pub fn parse(text: &str, path: &Path, groups: Groups) -> Result<HostValues, String> {
    let fail = |msg: String| format!("{}: {msg}", path.display());
    let t: toml::Table = text
        .parse()
        .map_err(|e| fail(format!("TOML として読めません: {e}")))?;
    let unknown: Vec<&str> = t
        .keys()
        .map(String::as_str)
        .filter(|k| !["group", "tools", "runner"].contains(k))
        .collect();
    if !unknown.is_empty() {
        return Err(fail(format!(
            "知らないキーがあります: {} (書けるのは group・[tools]・[runner])",
            unknown.join(", ")
        )));
    }
    let group = match t.get("group") {
        None => groups.default.clone(),
        Some(toml::Value::String(g)) if groups.tools(g).is_some() => g.clone(),
        Some(v) => {
            // toml の Value は display の feature が無いと Display を持たない
            let shown = match v {
                toml::Value::String(s) => s.clone(),
                other => format!("{other:?}"),
            };
            return Err(fail(format!(
                "group は {} のどれかで書いてください: {shown}",
                groups.names().join("・")
            )));
        }
    };
    let mut overrides = BTreeMap::new();
    match t.get("tools") {
        None => {}
        Some(toml::Value::Table(tools)) => {
            for (k, v) in tools {
                if !groups.knows_tool(k) {
                    return Err(fail(format!(
                        "[tools] に知らない道具があります: {k} (書けるのは win/runner/groups.json の tools の名前)"
                    )));
                }
                let Some(b) = v.as_bool() else {
                    return Err(fail(format!(
                        "[tools] の {k} は true か false で書いてください"
                    )));
                };
                overrides.insert(k.clone(), b);
            }
        }
        Some(_) => return Err(fail("tools は [tools] の表で書いてください".to_string())),
    }
    let runner_enable = match t.get("runner") {
        None => false,
        Some(toml::Value::Table(r)) => {
            let unknown: Vec<&str> = r
                .keys()
                .map(String::as_str)
                .filter(|k| *k != "enable")
                .collect();
            if !unknown.is_empty() {
                return Err(fail(format!(
                    "[runner] に知らないキーがあります: {} (書けるのは enable だけ)",
                    unknown.join(", ")
                )));
            }
            match r.get("enable") {
                None => false,
                Some(v) => v.as_bool().ok_or_else(|| {
                    fail("[runner] の enable は true か false で書いてください".to_string())
                })?,
            }
        }
        Some(_) => return Err(fail("runner は [runner] の表で書いてください".to_string())),
    };
    Ok(HostValues {
        group,
        overrides,
        runner_enable,
        source: Source::File(path.to_path_buf()),
        groups,
    })
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 埋めた groups.json が読め、グループごとの Windows の道具の既定が Nix の段の決まりどおり (personal は全部・company は ③ の ntn が
    //!   off・client は全部 off。type-clipboard はどれも off)
    //! - group を書かなければ personal、上書きはグループの既定より先に効く、runner.enable の既定は false
    //! - 知らないキー・グループ・道具と、bool でない値は誤り。ファイルが無いのは誤りでなく「無い」

    use super::*;
    use crate::testutil::TempDir;

    fn groups() -> Groups {
        Groups::embedded().unwrap()
    }

    fn host(text: &str) -> Result<HostValues, String> {
        parse(text, Path::new("h.toml"), groups())
    }

    #[test]
    fn embedded_groups_follow_tiers() {
        let g = groups();
        assert_eq!(g.default, "personal");
        assert_eq!(g.names(), vec!["client", "company", "personal"]);
        let tool =
            |group: &str, key: &str| host(&format!("group = \"{group}\"")).unwrap().tool(key);
        for key in ["windowsClaudeCode", "windowsHerdr", "windowsNtn"] {
            assert!(tool("personal", key), "{key}");
            assert!(!tool("client", key), "{key}");
        }
        assert!(tool("company", "windowsClaudeCode"));
        assert!(tool("company", "windowsHerdr"));
        assert!(!tool("company", "windowsNtn"));
        for group in ["personal", "company", "client"] {
            assert!(!tool(group, "windowsTypeClipboard"), "{group}");
        }
    }

    #[test]
    fn defaults_and_overrides() {
        let h = host("").unwrap();
        assert_eq!(h.group, "personal");
        assert!(!h.runner_enable);
        assert_eq!(h.source, Source::File(PathBuf::from("h.toml")));
        assert_eq!(h.tool_origin("windowsNtn"), "グループ personal の既定");

        let h = host("group = \"client\"\n[tools]\nwindowsNtn = true\nwindowsTypeClipboard = true\n[runner]\nenable = true\n").unwrap();
        assert!(h.tool("windowsNtn"));
        assert!(h.tool("windowsTypeClipboard"));
        assert!(!h.tool("windowsClaudeCode"));
        assert!(h.runner_enable);
        assert_eq!(h.tool_origin("windowsNtn"), "ホストの値");
        assert!(!h.tool("no-such-tool"));
    }

    #[test]
    fn rejects_mistakes() {
        for (text, want) in [
            ("grop = \"x\"", "知らないキーがあります: grop"),
            (
                "group = \"home\"",
                "group は client・company・personal のどれかで書いてください",
            ),
            ("group = 1", "group は"),
            (
                "[tools]\nwindowsNtnn = true",
                "[tools] に知らない道具があります: windowsNtnn",
            ),
            (
                "[tools]\nwindowsNtn = \"yes\"",
                "[tools] の windowsNtn は true か false で書いてください",
            ),
            ("tools = 1", "tools は [tools] の表で書いてください"),
            (
                "[runner]\nenabled = true",
                "[runner] に知らないキーがあります: enabled",
            ),
            (
                "[runner]\nenable = 1",
                "[runner] の enable は true か false で書いてください",
            ),
            ("runner = true", "runner は [runner] の表で書いてください"),
            ("= broken", "TOML として読めません"),
        ] {
            let e = host(text).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(e.contains(want), "{text}: {e}");
        }
    }

    #[test]
    fn missing_file_is_not_an_error() {
        let t = TempDir::new("host");
        let path = t.path().join("polle@pjp-raiden.toml");
        let h = load(&path, groups()).unwrap();
        assert_eq!(h.source, Source::Missing(path.clone()));
        assert_eq!(h.group, "personal");
        assert!(!h.runner_enable);
        std::fs::write(&path, "[runner]\nenable = true\n").unwrap();
        assert!(load(&path, groups()).unwrap().runner_enable);
    }

    #[test]
    fn default_path_is_next_to_the_clone() {
        let repo = Path::new("/g/github.com/pollenjp/dotfiles");
        assert_eq!(
            default_path(repo, "polle", "pjp-raiden"),
            Path::new("/g/github.com/pollenjp/dotfiles-private")
                .join("win")
                .join("hosts")
                .join("polle@pjp-raiden.toml")
        );
    }

    #[test]
    fn rejects_broken_groups_json() {
        assert!(Groups::parse("{}").is_err());
        assert!(Groups::parse("not json").is_err());
        assert!(
            Groups::parse(r#"{"version":1,"default":"x","groups":{"personal":{"tools":{}}}}"#)
                .is_err()
        );
        assert!(
            Groups::parse(
                r#"{"version":1,"default":"personal","groups":{"personal":{"tools":{"a":1}}}}"#
            )
            .is_err()
        );
    }
}
