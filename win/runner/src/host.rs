//! ホストの値 (dotfiles-private の `win/hosts/<Windows のユーザー名>@<PC の名前>.toml`) と、設定グループの写し (`groups.json`)。
//!
//! ホストの値は WSL の Nix のホスト (`nix/hosts/<user>@<hostname>.nix`) に当たる。書けるのは設定グループ (`group`)・道具の switch の上書き
//! (`[tools]`。`group.json` の `tools` と同じ名前)・受け持ちの印 (`[runner] enable`)・op-reason の SSH の中継のモード (`[opReason]`)・
//! sshd に入れる公開鍵 (`[sshd] authorizedKeys`。Nix の `wsl.windowsFiles.sshd.authorizedKeys` と同じ意味)・
//! Notion へ書く skill の宛先 (`[claude.notion]`。Nix の `dotfiles.claude.notion` と同じ名前と形) だけ。書いていない道具の既定は、Nix がグループごとの素のホストから書き出した `groups.json`
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
//! [opReason]
//! sshRelayMode = "per-call"     # SSH の中継のモード (per-call・show-only。書かなければ per-call)。効くのは [tools] opReasonSshRelay = true のとき
//!
//! [sshd]
//! authorizedKeys = ["from=\"100.64.0.1\" ssh-ed25519 AAAA… iphone"]   # sshd に入れる公開鍵 (1 つが authorized_keys の 1 行)。書かなければ null
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
    /// op-reason の SSH の中継のモード (`[opReason] sshRelayMode`。`SSH_RELAY_MODES` のどれか。書かなければ per-call)。
    /// 効くかは `ssh_relay` で引く
    ssh_relay_mode: String,
    /// sshd に入れる公開鍵 (`[sshd] authorizedKeys`。1 つが authorized_keys の 1 行)。None は書いていない (dotfiles は鍵を置かない。Nix の
    /// null と同じ)、空の Vec は鍵 0 本。使うのは受け持ちが runner のホストの手順 sshd だけ (`steps::sshd_keys`)
    pub sshd_keys: Option<Vec<String>>,
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
            ssh_relay_mode: SSH_RELAY_MODES[0].to_string(),
            sshd_keys: None,
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

    /// op-reason の SSH の中継 (道具の switch `opReasonSshRelay` と `[opReason] sshRelayMode`)。on ならモード (`per-call`・`show-only`)、
    /// off なら None。1Password (`onePassword`) が off なら効かない (Nix の groups.nix の requires と同じ。op-reason の手順も走らない)
    pub fn ssh_relay(&self) -> Option<&str> {
        (self.tool("onePassword") && self.tool("opReasonSshRelay"))
            .then_some(self.ssh_relay_mode.as_str())
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

/// op-reason の SSH の中継のモード (`op-reason.exe --ssh-agent --mode` の値。先頭が書かなかったときの既定)
pub const SSH_RELAY_MODES: [&str; 2] = ["per-call", "show-only"];

/// `[opReason]` を読む (中継のモード)。書けるのは sshRelayMode だけ
fn parse_op_reason(v: &toml::Value) -> Result<String, String> {
    let toml::Value::Table(t) = v else {
        return Err("opReason は [opReason] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = t
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "sshRelayMode")
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[opReason] に知らないキーがあります: {} (書けるのは sshRelayMode だけ)",
            unknown.join(", ")
        ));
    }
    match t.get("sshRelayMode") {
        None => Ok(SSH_RELAY_MODES[0].to_string()),
        Some(toml::Value::String(m)) if SSH_RELAY_MODES.contains(&m.as_str()) => Ok(m.clone()),
        Some(other) => {
            let shown = match other {
                toml::Value::String(s) => s.clone(),
                other => format!("{other:?}"),
            };
            Err(format!(
                "[opReason] の sshRelayMode は {} で書いてください: {shown}",
                SSH_RELAY_MODES.join(" か ")
            ))
        }
    }
}

/// authorized_keys の鍵の種類 (win/openssh/Install-Sshd.ps1 の `$script:KeyTypePattern` と同じ)
pub const SSH_KEY_TYPES: [&str; 7] = [
    "ssh-ed25519",
    "ssh-rsa",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
];

/// authorized_keys の 1 行として読めるか (Install-Sshd.ps1 の `Test-AuthorizedKeyLine` と、コメントの行として読み飛ばされない
/// こと)。改行を含まず、`#` で始まらず、鍵の種類と base64 (16 字以上と `=` 3 つまで) が空白を挟んで並ぶ。前にオプション (`from="…"`
/// など) が付いてよい
pub fn authorized_key_line_ok(line: &str) -> bool {
    if line.contains(['\r', '\n']) || line.trim_start().starts_with('#') {
        return false;
    }
    let base64_ok = |t: &str| {
        let body = t.trim_end_matches('=');
        t.len() - body.len() <= 3
            && body.len() >= 16
            && body
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
    };
    let tokens: Vec<&str> = line.split_whitespace().collect();
    tokens
        .windows(2)
        .any(|w| SSH_KEY_TYPES.contains(&w[0]) && base64_ok(w[1]))
}

/// `[sshd]` を読む (公開鍵)。書けるのは authorizedKeys だけ。書かなければ None
fn parse_sshd(v: &toml::Value) -> Result<Option<Vec<String>>, String> {
    let toml::Value::Table(t) = v else {
        return Err("sshd は [sshd] の表で書いてください".to_string());
    };
    let unknown: Vec<&str> = t
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "authorizedKeys")
        .collect();
    if !unknown.is_empty() {
        return Err(format!(
            "[sshd] に知らないキーがあります: {} (書けるのは authorizedKeys だけ)",
            unknown.join(", ")
        ));
    }
    let Some(keys) = t.get("authorizedKeys") else {
        return Ok(None);
    };
    let toml::Value::Array(items) = keys else {
        return Err(
            "[sshd] の authorizedKeys は文字列の配列で書いてください (鍵 0 本なら [])".to_string(),
        );
    };
    let mut out = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let toml::Value::String(line) = item else {
            return Err(format!(
                "[sshd] の authorizedKeys の {} 番目が文字列ではありません",
                i + 1
            ));
        };
        if line.contains(['\r', '\n']) {
            return Err(format!(
                "[sshd] の authorizedKeys の {} 番目が改行を含みます (1 つの文字列が authorized_keys の 1 行。鍵ごとに分けて書く)",
                i + 1
            ));
        }
        if !authorized_key_line_ok(line) {
            return Err(format!(
                "[sshd] の authorizedKeys の {} 番目を authorized_keys の行として読めません (鍵の種類と base64 が要る。# で始めない): {}",
                i + 1,
                shorten(line)
            ));
        }
        out.push(line.clone());
    }
    Ok(Some(out))
}

/// 誤りの文に添える値 (長ければ 40 字で切る)
fn shorten(s: &str) -> String {
    let mut it = s.chars();
    let head: String = it.by_ref().take(40).collect();
    if it.next().is_some() {
        format!("{head}…")
    } else {
        head
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
        .filter(|k| !["group", "tools", "runner", "opReason", "sshd", "claude"].contains(k))
        .collect();
    if !unknown.is_empty() {
        return Err(fail(format!(
            "知らないキーがあります: {} (書けるのは group・[tools]・[runner]・[opReason]・[sshd]・[claude.notion])",
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
    let ssh_relay_mode = match t.get("opReason") {
        None => SSH_RELAY_MODES[0].to_string(),
        Some(v) => parse_op_reason(v).map_err(fail)?,
    };
    let sshd_keys = match t.get("sshd") {
        None => None,
        Some(v) => parse_sshd(v).map_err(fail)?,
    };
    let notion = match t.get("claude") {
        None => NotionValues::default(),
        Some(v) => parse_claude(v).map_err(fail)?,
    };
    Ok(HostValues {
        group,
        overrides,
        runner_enable,
        ssh_relay_mode,
        sshd_keys,
        notion,
        source: Source::File(path.to_path_buf()),
        groups,
    })
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 埋めた groups.json が読め、グループごとの Windows の道具の既定が Nix の段の決まりどおり (personal は全部・company は ③ の ntn と
    //!   ② ③ の両方の claude-personal・claude-work が off・client は全部 off。type-clipboard はどれも off)
    //! - group を書かなければ personal、上書きはグループの既定より先に効く、runner.enable の既定は false
    //! - 知らないキー・グループ・道具と、bool でない値は誤り。ファイルが無いのは誤りでなく「無い」
    //! - op-reason の SSH の中継 (道具の switch opReasonSshRelay。どのグループでも既定は off) は、on なら [opReason] sshRelayMode のモード
    //!   (書かなければ per-call)、off か 1Password (onePassword) が off なら無し。sshRelayMode の知らない値・[opReason] の知らないキーは誤り
    //! - sshd の公開鍵 ([sshd] authorizedKeys) は、書かなければ None (null)、[] は鍵 0 本、list はその行のまま。改行を含む値・
    //!   authorized_keys の行として読めない値 (鍵の種類か base64 が無い・# で始まる)・文字列でない値・[sshd] の知らないキーは誤り

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
        // claude-personal・claude-work は ② と ③ の両方 (初回の apply で UAC の確認が出るので、company・client では既定で走らせない)
        assert!(tool("personal", "windowsClaudeAccounts"));
        assert!(!tool("company", "windowsClaudeAccounts"));
        assert!(!tool("client", "windowsClaudeAccounts"));
        for group in ["personal", "company", "client"] {
            assert!(!tool(group, "windowsTypeClipboard"), "{group}");
            // Tailscale は VPN の道具で、どのグループでも既定は off (入れるホストが [tools] に書く)
            assert!(!tool(group, "windowsTailscale"), "{group}");
            // sshd は PC に外から入る口で、どのグループでも既定は off (入れるホストが [tools] に書く)
            assert!(!tool(group, "windowsSshd"), "{group}");
            // op-reason の SSH の中継は鍵を使う ssh の通り道を替えるので、どのグループでも既定は off (入れるホストが [tools] に書く)
            assert!(!tool(group, "opReasonSshRelay"), "{group}");
        }
    }

    #[test]
    fn ssh_relay_follows_the_switch_and_the_mode() {
        // 書かなければ off (モードを書いても、switch が off なら無し)
        assert_eq!(host("").unwrap().ssh_relay(), None);
        assert_eq!(
            host("[opReason]\nsshRelayMode = \"show-only\"\n")
                .unwrap()
                .ssh_relay(),
            None
        );
        // on ならモード。書かなければ per-call (1Password の switch は、どのグループでも既定が off なので、入れるホストが一緒に書く)
        let h = host("[tools]\nonePassword = true\nopReasonSshRelay = true\n").unwrap();
        assert_eq!(h.ssh_relay(), Some("per-call"));
        assert_eq!(h.tool_origin("opReasonSshRelay"), "ホストの値");
        assert_eq!(
            host("[tools]\nonePassword = true\nopReasonSshRelay = true\n[opReason]\nsshRelayMode = \"show-only\"\n")
                .unwrap()
                .ssh_relay(),
            Some("show-only")
        );
        assert_eq!(
            host("[tools]\nonePassword = true\nopReasonSshRelay = true\n[opReason]\nsshRelayMode = \"per-call\"\n")
                .unwrap()
                .ssh_relay(),
            Some("per-call")
        );
        // 1Password が off なら効かない (groups.nix の requires。op-reason の手順も走らない)
        assert_eq!(
            host("[tools]\nopReasonSshRelay = true\nonePassword = false\n")
                .unwrap()
                .ssh_relay(),
            None
        );
        // ファイルが無いときも off
        assert_eq!(
            HostValues::missing(Path::new("h.toml"), groups()).ssh_relay(),
            None
        );
    }

    #[test]
    fn windows_sshd_is_a_known_tool_that_hosts_turn_on() {
        let h = host("[tools]\nwindowsSshd = true\n").unwrap();
        assert!(h.tool("windowsSshd"));
        assert_eq!(h.tool_origin("windowsSshd"), "ホストの値");
        let h = host("").unwrap();
        assert!(!h.tool("windowsSshd"));
        assert_eq!(h.tool_origin("windowsSshd"), "グループ personal の既定");
    }

    #[test]
    fn windows_tailscale_is_a_known_tool_that_hosts_turn_on() {
        let h = host("[tools]\nwindowsTailscale = true\n").unwrap();
        assert!(h.tool("windowsTailscale"));
        assert_eq!(h.tool_origin("windowsTailscale"), "ホストの値");
        let h = host("").unwrap();
        assert!(!h.tool("windowsTailscale"));
        assert_eq!(
            h.tool_origin("windowsTailscale"),
            "グループ personal の既定"
        );
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
                "知らないキーがあります: grop (書けるのは group・[tools]・[runner]・[opReason]・[sshd]・[claude.notion])",
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
            (
                "[opReason]\nsshRelayMode = \"always\"",
                "[opReason] の sshRelayMode は per-call か show-only で書いてください: always",
            ),
            (
                "[opReason]\nsshRelayMode = 1",
                "[opReason] の sshRelayMode は per-call か show-only で書いてください",
            ),
            (
                "[opReason]\nmode = \"per-call\"",
                "[opReason] に知らないキーがあります: mode (書けるのは sshRelayMode だけ)",
            ),
            (
                "opReason = \"per-call\"",
                "opReason は [opReason] の表で書いてください",
            ),
            ("sshd = 1", "sshd は [sshd] の表で書いてください"),
            (
                "[sshd]\nkeys = []",
                "[sshd] に知らないキーがあります: keys (書けるのは authorizedKeys だけ)",
            ),
            (
                "[sshd]\nauthorizedKeys = \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE\"",
                "[sshd] の authorizedKeys は文字列の配列で書いてください",
            ),
            (
                "[sshd]\nauthorizedKeys = [1]",
                "[sshd] の authorizedKeys の 1 番目が文字列ではありません",
            ),
            (
                "[sshd]\nauthorizedKeys = [\"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE a\", \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE b\\nssh-rsa AAAAB3NzaC1yc2EAAAADFAKEFAKE c\"]",
                "[sshd] の authorizedKeys の 2 番目が改行を含みます",
            ),
            (
                "[sshd]\nauthorizedKeys = [\"from=\\\"100.64.0.1\\\" AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE herdr\"]",
                "[sshd] の authorizedKeys の 1 番目を authorized_keys の行として読めません",
            ),
            ("= broken", "TOML として読めません"),
        ] {
            let e = host(text).unwrap_err();
            assert!(e.starts_with("h.toml: "), "{e}");
            assert!(e.contains(want), "{text}: {e}");
        }
    }

    /// [sshd] authorizedKeys: 書かなければ None、[] は鍵 0 本、list はその行のまま (from= のオプションが付いてよい)
    #[test]
    fn sshd_keys_follow_the_null_and_list_meanings() {
        assert_eq!(host("").unwrap().sshd_keys, None);
        assert_eq!(host("[sshd]\n").unwrap().sshd_keys, None);
        assert_eq!(
            HostValues::missing(Path::new("h.toml"), groups()).sshd_keys,
            None
        );
        assert_eq!(
            host("[sshd]\nauthorizedKeys = []\n").unwrap().sshd_keys,
            Some(vec![])
        );
        let a = r#"from="100.64.0.1,fd7a:115c:a1e0::1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKE herdr@phone"#;
        let b = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABFAKE==";
        let text = format!("[sshd]\nauthorizedKeys = [\n  '{a}',\n  '{b}',\n]\n");
        assert_eq!(
            host(&text).unwrap().sshd_keys,
            Some(vec![a.to_string(), b.to_string()])
        );
    }

    /// authorized_keys の 1 行として読めるか (Install-Sshd.ps1 の Test-AuthorizedKeyLine と同じ見方に、# の行を足したもの)
    #[test]
    fn authorized_key_lines() {
        for ok in [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE herdr@phone",
            r#"from="100.64.0.1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE"#,
            "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAy= x",
            "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9w x",
        ] {
            assert!(authorized_key_line_ok(ok), "{ok}");
        }
        for bad in [
            "",
            "   ",
            "AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "ssh-ed25519",
            "ssh-ed25519 short",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE====",
            "ssh-dss AAAAB3NzaC1kc3MAAACBAFAKE",
            "# ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "  # ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE",
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKE\r",
        ] {
            assert!(!authorized_key_line_ok(bad), "{bad:?}");
        }
    }

    /// Windows のエディタ (Windows PowerShell 5.1 の Set-Content -Encoding UTF8 など) が付ける頭の BOM は読み飛ばす
    #[test]
    fn leading_bom_is_ignored() {
        let h = host("\u{feff}group = \"company\"\n").unwrap();
        assert_eq!(h.group, "company");
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
