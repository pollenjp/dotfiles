//! claude-account のアカウント (Linux の `nix/pkgs/claude-account` と同じ決まり。dotfiles-private の docs/adr/082_claude_token_accounts_*)。
//!
//! | | 既定 | 登録 (`claude-account add` で足す) |
//! | --- | --- | --- |
//! | 名前 | `personal`・`work` (`steps::claude_accounts::DEFAULT_ACCOUNTS`) | 名前の規則に合い、[`RESERVED`] (`account`・`selector`) と既定の名前でないもの |
//! | 種類 | subscription | subscription か token |
//! | 置き場 | runner の手順 `claude-accounts` が作る | `%USERPROFILE%\.config\claude-accounts\accounts.json` (マシンごと) |
//!
//! 登録の形は `{"version":1,"accounts":{"<名前>":{"mode":"subscription"|"token"}}}` (Linux の claude-account と同じ。書くのは
//! `claude-account` だけ)。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// 管理のコマンドの名前 (`claude-account`)。アカウントの名前には使えない
pub const MANAGER: &str = "account";

/// claude-selector (cs) の名前 (`claude-selector`。runner の手順 claude-selector が launcher と同じ置き場に置く別の exe)。アカウントの
/// 名前には使えない (`claude-<名前>.exe` の launcher が claude-selector.exe を上書きする)
pub const SELECTOR: &str = "selector";

/// アカウントの名前に使えない名前 (claude-selector の crate の `accounts::RESERVED` と同じ。tests/claude_parity.rs が突き合わせる)
pub const RESERVED: [&str; 2] = [MANAGER, SELECTOR];

/// アカウントの種類。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// `/login` の資格情報 (`~/.claude-<名前>/.credentials.json`) で動く
    Subscription,
    /// token のファイルの token (`claude setup-token`) を `CLAUDE_CODE_OAUTH_TOKEN` で渡して動く
    Token,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Subscription => "subscription",
            Mode::Token => "token",
        }
    }

    pub fn parse(s: &str) -> Option<Mode> {
        match s {
            "subscription" => Some(Mode::Subscription),
            "token" => Some(Mode::Token),
            _ => None,
        }
    }
}

/// どこで決まったアカウントか。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    /// dotfiles が作る既定
    Default,
    /// `claude-account add` で足した
    Registered,
}

impl Origin {
    pub fn label(self) -> &'static str {
        match self {
            Origin::Default => "既定",
            Origin::Registered => "登録",
        }
    }
}

/// アカウントの名前の形 (`[a-z0-9][a-z0-9_-]*`。Linux の claude.nix・bootstrap-claude-accounts.sh・claude-account と同じ)。dir の名前
/// (`~/.claude-<名前>`) とコマンドの名前に使うので、パスを壊す字を入れない。
pub fn name_ok(name: &str) -> bool {
    let mut chars = name.chars();
    let lead_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    // token を名前の所に渡したときに、登録したり文に出したりしないよう、長いものと token の頭 (sk-ant-) のものは断る
    lead_ok
        && name.len() <= 32
        && !name.starts_with("sk-ant-")
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// 登録と token のファイルを置く dir (`<家>\.config\claude-accounts`)
pub fn config_dir(home: &Path) -> PathBuf {
    home.join(".config").join("claude-accounts")
}

/// 登録の一覧のファイル
pub fn registry_path(home: &Path) -> PathBuf {
    config_dir(home).join("accounts.json")
}

/// 登録の一覧 (名前の順)。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Registry {
    pub accounts: BTreeMap<String, Mode>,
}

impl Registry {
    /// 読む。無ければ空の一覧。形が違えば、パスと直し方を入れた文で Err
    pub fn load(path: &Path) -> Result<Registry, String> {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Registry::default()),
            Err(e) => {
                return Err(format!(
                    "登録の一覧 ({}) が読めません ({e})。",
                    path.display()
                ));
            }
        };
        parse(&text).map_err(|why| {
            format!(
                "登録の一覧 ({}) が読めない形です ({why})。直すか、消してから claude-account add で足し直してください。",
                path.display()
            )
        })
    }

    /// 書く形 (`{"version":1,"accounts":{…}}`。名前の順、2 つの空白で字下げ、末尾に改行)
    pub fn to_json(&self) -> String {
        let mut accounts = serde_json::Map::new();
        for (name, mode) in &self.accounts {
            let mut m = serde_json::Map::new();
            m.insert("mode".into(), serde_json::Value::from(mode.as_str()));
            accounts.insert(name.clone(), serde_json::Value::Object(m));
        }
        let mut top = serde_json::Map::new();
        top.insert("accounts".into(), serde_json::Value::Object(accounts));
        top.insert("version".into(), serde_json::Value::from(1));
        let mut s = serde_json::to_string_pretty(&serde_json::Value::Object(top))
            .unwrap_or_else(|_| String::from("{}"));
        s.push('\n');
        s
    }

    /// 書く (dir を作り、一時ファイルに書いて置き換える)
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)
                .map_err(|e| format!("{} を作れません ({e})", dir.display()))?;
        }
        crate::fsutil::write_atomic(path, self.to_json().as_bytes())
            .map_err(|e| format!("登録の一覧 ({}) に書けません ({e})", path.display()))
    }
}

/// 登録の一覧の文字列を読む。形が違えばわけ
fn parse(text: &str) -> Result<Registry, String> {
    // PowerShell 5.1 の Set-Content -Encoding UTF8・メモ帳は頭に BOM を付ける (jq は読むので、Linux とそろえる)
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let v: serde_json::Value =
        serde_json::from_str(text).map_err(|e| format!("JSON でない: {e}"))?;
    if v.get("version").and_then(serde_json::Value::as_f64) != Some(1.0) {
        return Err("version が 1 でない".to_string());
    }
    let Some(accounts) = v.get("accounts").and_then(serde_json::Value::as_object) else {
        return Err("accounts が object でない".to_string());
    };
    let mut out = BTreeMap::new();
    for (name, entry) in accounts {
        if !name_ok(name) || RESERVED.contains(&name.as_str()) {
            return Err(format!("{name} はアカウントの名前に使えない"));
        }
        let mode = entry
            .get("mode")
            .and_then(serde_json::Value::as_str)
            .and_then(Mode::parse)
            .ok_or_else(|| format!("{name} の mode が subscription・token でない"))?;
        out.insert(name.clone(), mode);
    }
    Ok(Registry { accounts: out })
}

/// 名前の種類と元。既定でも登録でもなければ None
pub fn lookup(name: &str, defaults: &[&str], registry: &Registry) -> Option<(Mode, Origin)> {
    if defaults.contains(&name) {
        return Some((Mode::Subscription, Origin::Default));
    }
    registry
        .accounts
        .get(name)
        .map(|m| (*m, Origin::Registered))
}

/// 既定と登録の名前 (既定の順のあと、登録を名前の順。既定と同じ名前は 1 つ)
pub fn all_names(defaults: &[&str], registry: &Registry) -> Vec<String> {
    let mut names: Vec<String> = defaults.iter().map(|s| s.to_string()).collect();
    for n in registry.accounts.keys() {
        if !names.contains(n) {
            names.push(n.clone());
        }
    }
    names
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 名前の形 (英小文字・数字で始まり、英小文字・数字・- と _ だけ)
    //! - 登録: 無ければ空・書いて読み直すと同じ・version・accounts・mode が違う形と、使えない名前 (account・selector も) は Err (パスを出す)
    //! - 種類と元: 既定は subscription、登録はその種類、どちらでもなければ None。名前の並び (既定のあとに登録)

    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn names() {
        for ok in ["personal", "work", "token1", "a-b_c", "0x"] {
            assert!(name_ok(ok), "{ok}");
        }
        for ng in ["", "Work", "-a", "_a", "a.b", "a b", "a/b", "a\\b", "ａ"] {
            assert!(!name_ok(ng), "{ng}");
        }
        // token の頭と長すぎる名前 (token を名前に渡した) は断る
        assert!(!name_ok("sk-ant-oat01-dummy"));
        assert!(name_ok(&"a".repeat(32)));
        assert!(!name_ok(&"a".repeat(33)));
    }

    #[test]
    fn registry_round_trip() {
        let t = TempDir::new("accounts");
        let path = registry_path(&t.path().join("home"));
        assert_eq!(Registry::load(&path).unwrap(), Registry::default());
        let mut r = Registry::default();
        r.accounts.insert("token1".into(), Mode::Token);
        r.accounts.insert("sub2".into(), Mode::Subscription);
        r.save(&path).unwrap();
        assert_eq!(Registry::load(&path).unwrap(), r);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.ends_with("}\n"), "{text}");
        assert!(text.contains("\"version\": 1"), "{text}");
        // Linux の claude-account (jq) が書く形も、BOM 付き (PowerShell 5.1・メモ帳) と 1.0 の version も読める
        std::fs::write(
            &path,
            "\u{feff}{\"version\":1.0,\"accounts\":{\"t\":{\"mode\":\"token\"}}}\n",
        )
        .unwrap();
        assert_eq!(
            Registry::load(&path).unwrap().accounts.get("t"),
            Some(&Mode::Token)
        );
    }

    #[test]
    fn registry_refuses_bad_shapes() {
        let t = TempDir::new("accounts-bad");
        let path = registry_path(&t.path().join("home"));
        for bad in [
            "{\"version\":1,\"accounts\":[",
            "{\"version\":2,\"accounts\":{}}",
            "{\"version\":1,\"accounts\":[]}",
            "{\"version\":1,\"accounts\":{\"t\":{\"mode\":\"x\"}}}",
            "{\"version\":1,\"accounts\":{\"t\":\"token\"}}",
            "{\"version\":1,\"accounts\":{\"Bad\":{\"mode\":\"token\"}}}",
            "{\"version\":1,\"accounts\":{\"account\":{\"mode\":\"token\"}}}",
            "{\"version\":1,\"accounts\":{\"selector\":{\"mode\":\"subscription\"}}}",
        ] {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, bad).unwrap();
            let e = Registry::load(&path).unwrap_err();
            assert!(e.contains("accounts.json"), "{bad}: {e}");
            assert!(e.contains("claude-account add"), "{bad}: {e}");
        }
    }

    #[test]
    fn lookup_and_names() {
        let mut r = Registry::default();
        r.accounts.insert("token1".into(), Mode::Token);
        r.accounts.insert("a2".into(), Mode::Subscription);
        let d = ["personal", "work"];
        assert_eq!(
            lookup("work", &d, &r),
            Some((Mode::Subscription, Origin::Default))
        );
        assert_eq!(
            lookup("token1", &d, &r),
            Some((Mode::Token, Origin::Registered))
        );
        assert_eq!(lookup("nosuch", &d, &r), None);
        assert_eq!(all_names(&d, &r), ["personal", "work", "a2", "token1"]);
        assert_eq!(Mode::parse("token"), Some(Mode::Token));
        assert_eq!(Mode::parse("x"), None);
        assert_eq!(Mode::Subscription.as_str(), "subscription");
    }
}
