//! ホストの値 (dotfiles-private の `win/hosts/<Windows のユーザー名>@<PC の名前>.toml`) と、設定グループの写し (`groups.json`)。
//!
//! ホストの値は WSL の Nix のホスト (`nix/hosts/<user>@<hostname>.nix`) に当たる。書けるのは設定グループ (`group`)・道具の switch の上書き
//! (`[tools]`。`group.json` の `tools` と同じ名前)・受け持ちの印 (`[runner] enable`)・Notion へ書く skill の宛先 (`[claude.notion]`。Nix の
//! `dotfiles.claude.notion` と同じ名前と形) だけ。書いていない道具の既定は、Nix がグループごとの素のホストから書き出した `groups.json`
//! (`nix eval --raw ./nix#lib.windowsGroupsJson`) から引く (dotfiles-private の docs/adr/058_win_runner_bootstrap_* §2 H・
//! docs/adr/064_win_w02_claude_skills_hub_*)。
//!
//! ```toml
//! group = "personal"            # personal (既定)・company・client
//!
//! [tools]
//! windowsTypeClipboard = true
//!
//! [runner]
//! enable = false                # true で apply を許す (WSL の windowsFiles.enable = false と同じ PR で変える)
//!
//! [claude.notion]
//! profile = "personal"          # Notion へ書く skill がこのマシンで既定に使うプロファイル (書かなければ null)
//! routes = { "pollenjp/x" = "work" }   # このマシンだけの宛先の規則
//!
//! [claude.notion.override.personal]    # プロファイルの値を、このマシンだけ差し替える
//! scanData = "https://app.notion.com/p/…"
//! ```

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Notion へ書く skill の宛先 (ホストの値の `[claude.notion]`)。claude-skills の pjp-notion-profile が読む
/// `~/.local/state/dotfiles/claude-notion.json` の中身になる。綴り (プロファイルがあるか・知らないキー) は claude-skills の resolver が
/// 使うときに確かめる (Nix の option と同じ)。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct NotionValues {
    /// このマシンの既定のプロファイル (無ければ JSON の null)
    pub profile: Option<String>,
    /// このマシンだけの宛先の規則 (`owner/*`・`owner/repo` → プロファイル)
    pub routes: BTreeMap<String, String>,
    /// プロファイルごとの値の上書き (JSON に写したもの)
    pub overrides: serde_json::Map<String, serde_json::Value>,
}

impl NotionValues {
    /// claude-notion.json の中身。Linux の home/modules/claude.nix の `builtins.toJSON { inherit profile routes override; } + "\n"` と同じ
    /// バイト列 (キーの順・空白なしの 1 行と改行)。
    pub fn json(&self) -> String {
        let routes: serde_json::Map<String, serde_json::Value> = self
            .routes
            .iter()
            .map(|(k, v)| (k.clone(), serde_json::Value::String(v.clone())))
            .collect();
        let mut top = serde_json::Map::new();
        top.insert(
            "override".to_string(),
            serde_json::Value::Object(self.overrides.clone()),
        );
        top.insert(
            "profile".to_string(),
            match &self.profile {
                Some(p) => serde_json::Value::String(p.clone()),
                None => serde_json::Value::Null,
            },
        );
        top.insert("routes".to_string(), serde_json::Value::Object(routes));
        format!("{}\n", serde_json::Value::Object(top))
    }
}

/// プロファイルの名前の形 (`[a-z0-9][a-z0-9_-]*`。Nix の option の strMatching と claude-skills の NAME_RE と同じ)
fn profile_name_ok(name: &str) -> bool {
    let mut chars = name.chars();
    let lead_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    lead_ok && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// TOML の値を JSON に写す (`where_` は誤りの文に出す場所)。日時は JSON に無いので誤り、小数は有限のものだけ。
fn toml_to_json(v: &toml::Value, where_: &str) -> Result<serde_json::Value, String> {
    Ok(match v {
        toml::Value::String(s) => serde_json::Value::String(s.clone()),
        toml::Value::Integer(i) => serde_json::Value::from(*i),
        toml::Value::Float(f) => serde_json::Number::from_f64(*f)
            .map(serde_json::Value::Number)
            .ok_or_else(|| format!("{where_} は有限の数で書いてください"))?,
        toml::Value::Boolean(b) => serde_json::Value::Bool(*b),
        toml::Value::Datetime(_) => {
            return Err(format!(
                "{where_} は日時で書けません (JSON に写せない。文字列にする)"
            ));
        }
        toml::Value::Array(items) => serde_json::Value::Array(
            items
                .iter()
                .enumerate()
                .map(|(i, item)| toml_to_json(item, &format!("{where_}[{i}]")))
                .collect::<Result<_, _>>()?,
        ),
        toml::Value::Table(t) => serde_json::Value::Object(
            t.iter()
                .map(|(k, item)| Ok((k.clone(), toml_to_json(item, &format!("{where_}.{k}"))?)))
                .collect::<Result<_, String>>()?,
        ),
    })
}

/// `[claude]` の表を読む (書けるのは `[claude.notion]` だけ)。
fn parse_claude(v: &toml::Value) -> Result<NotionValues, String> {
    let toml::Value::Table(claude) = v else {
        return Err("claude は [claude.notion] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = claude
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "notion")
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[claude] に知らないキーがあります: {} (書けるのは [claude.notion])",
            unknown.join(", ")
        ));
    }
    let Some(notion) = claude.get("notion") else {
        return Ok(NotionValues::default());
    };
    let toml::Value::Table(notion) = notion else {
        return Err("[claude] の notion は [claude.notion] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = notion
        .keys()
        .map(String::as_str)
        .filter(|k| !["profile", "routes", "override"].contains(k))
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[claude.notion] に知らないキーがあります: {} (書けるのは profile・routes・override)",
            unknown.join(", ")
        ));
    }
    let profile = match notion.get("profile") {
        None => None,
        Some(toml::Value::String(p)) if profile_name_ok(p) => Some(p.clone()),
        Some(other) => {
            let shown = match other {
                toml::Value::String(s) => format!("\"{s}\""),
                other => format!("{other:?}"),
            };
            return Err(format!(
                "[claude.notion] の profile は、英小文字・数字で始まり英小文字・数字・- と _ だけの名前 (profiles.toml のプロファイルの名前) で書いてください: {shown}"
            ));
        }
    };
    let mut routes = BTreeMap::new();
    match notion.get("routes") {
        None => {}
        Some(toml::Value::Table(t)) => {
            for (k, v) in t {
                let Some(s) = v.as_str() else {
                    return Err(format!(
                        "[claude.notion] の routes の {k} は文字列 (プロファイルの名前) で書いてください"
                    ));
                };
                routes.insert(k.clone(), s.to_string());
            }
        }
        Some(_) => {
            return Err(
                "[claude.notion] の routes は表で書いてください ({ \"owner/*\" = \"<プロファイル>\" })"
                    .to_string(),
            );
        }
    }
    let overrides = match notion.get("override") {
        None => serde_json::Map::new(),
        Some(v @ toml::Value::Table(_)) => match toml_to_json(v, "[claude.notion] の override")? {
            serde_json::Value::Object(m) => m,
            _ => unreachable!("表は object に写る"),
        },
        Some(_) => {
            return Err(
                "[claude.notion] の override は表で書いてください ([claude.notion.override.<プロファイル>])"
                    .to_string(),
            );
        }
    };
    Ok(NotionValues {
        profile,
        routes,
        overrides,
    })
}

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
    /// Notion へ書く skill の宛先 (`[claude.notion]`)
    pub notion: NotionValues,
    pub source: Source,
    groups: Groups,
}

impl HostValues {
    /// ファイルが無いときの値 (グループの既定・受け持ちは WSL・Notion の宛先は選んでいない)。
    pub fn missing(path: &Path, groups: Groups) -> Self {
        HostValues {
            group: groups.default.clone(),
            overrides: BTreeMap::new(),
            runner_enable: false,
            notion: NotionValues::default(),
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

/// ホストの値の既定の置き場所: dotfiles-private の clone の `win/hosts/<user>@<pc>.toml`。dotfiles-private は dotfiles の clone の隣、
/// 無ければ bootstrap の置き場 (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles-private`) で探す (`context::clone_dir`)。
pub fn default_path(repo: &Path, user_profile: Option<&Path>, user: &str, pc: &str) -> PathBuf {
    crate::context::clone_dir(repo, user_profile, "dotfiles-private")
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
        .filter(|k| !["group", "tools", "runner", "claude"].contains(k))
        .collect();
    if !unknown.is_empty() {
        return Err(fail(format!(
            "知らないキーがあります: {} (書けるのは group・[tools]・[runner]・[claude.notion])",
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
    let notion = match t.get("claude") {
        None => NotionValues::default(),
        Some(v) => parse_claude(v).map_err(fail)?,
    };
    Ok(HostValues {
        group,
        overrides,
        runner_enable,
        notion,
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

    /// [claude.notion] から ~/.local/state/dotfiles/claude-notion.json の中身 (Linux の home/modules/claude.nix と同じ 1 行の JSON) を作る
    #[test]
    fn notion_values() {
        assert_eq!(
            host("").unwrap().notion.json(),
            "{\"override\":{},\"profile\":null,\"routes\":{}}\n"
        );
        assert_eq!(
            HostValues::missing(Path::new("h.toml"), groups())
                .notion
                .json(),
            "{\"override\":{},\"profile\":null,\"routes\":{}}\n"
        );
        let h = host(
            "[claude.notion]\nprofile = \"personal\"\nroutes = { \"pollenjp/x\" = \"work\", \"a/*\" = \"personal\" }\n\n[claude.notion.override.personal]\nscanData = \"u\"\ndevTracker = { linkFromRepo = false }\nn = [1, 2.5, true]\n",
        )
        .unwrap();
        assert_eq!(h.notion.profile.as_deref(), Some("personal"));
        assert_eq!(
            h.notion.json(),
            "{\"override\":{\"personal\":{\"devTracker\":{\"linkFromRepo\":false},\"n\":[1,2.5,true],\"scanData\":\"u\"}},\"profile\":\"personal\",\"routes\":{\"a/*\":\"personal\",\"pollenjp/x\":\"work\"}}\n"
        );
    }

    #[test]
    fn rejects_notion_mistakes() {
        for (text, want) in [
            (
                "claude = 1",
                "claude は [claude.notion] の表で書いてください",
            ),
            ("[claude]\nx = 1", "[claude] に知らないキーがあります: x"),
            (
                "[claude.notion]\nprofil = \"a\"",
                "[claude.notion] に知らないキーがあります: profil",
            ),
            (
                "[claude.notion]\nprofile = \"Personal\"",
                "[claude.notion] の profile は",
            ),
            (
                "[claude.notion]\nprofile = 1",
                "[claude.notion] の profile は",
            ),
            (
                "[claude.notion]\nprofile = \"\"",
                "[claude.notion] の profile は",
            ),
            (
                "[claude.notion]\nroutes = { a = 1 }",
                "[claude.notion] の routes の a は文字列",
            ),
            (
                "[claude.notion]\nroutes = 1",
                "[claude.notion] の routes は表で書いてください",
            ),
            (
                "[claude.notion]\noverride = 1",
                "[claude.notion] の override は表で書いてください",
            ),
            (
                "[claude.notion.override.p]\nt = 1979-05-27T07:32:00Z",
                "[claude.notion] の override.p.t は日時で書けません",
            ),
        ] {
            let e = host(text).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(e.contains(want), "{text}: {e}");
        }
    }

    #[test]
    fn rejects_mistakes() {
        for (text, want) in [
            (
                "grop = \"x\"",
                "知らないキーがあります: grop (書けるのは group・[tools]・[runner]・[claude.notion])",
            ),
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
            default_path(repo, None, "polle", "pjp-raiden"),
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
