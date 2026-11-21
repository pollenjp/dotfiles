//! 選べるアカウント: 既定と claude-account の登録。launcher (`claude-<名前>`) と素の `claude` は PATH で探す。
//!
//! | | Linux | Windows |
//! | --- | --- | --- |
//! | 既定 | `~/.local/state/dotfiles/claude-accounts.json` (nix/home/modules/claude.nix の accounts を home-manager が置く名前の配列) | [`WINDOWS_DEFAULT_ACCOUNTS`] (runner の `steps::claude_accounts::DEFAULT_ACCOUNTS` と同じ。runner の試験 tests/claude_parity.rs が突き合わせる) |
//! | 登録 | `~/.config/claude-accounts/accounts.json` | `%USERPROFILE%\.config\claude-accounts\accounts.json` |
//!
//! 登録の形は `{"version":1,"accounts":{"<名前>":{"mode":"subscription"|"token"}}}` (書くのは claude-account)。nix/pkgs/claude-account
//! と win/runner/src/accounts.rs と同じ決まりで読み、読めない形なら登録のアカウントは出さずに知らせる (既定は出す)。
//! `~/.claude*` の dir は走査しない (`~/.claude_credits` のように、アカウントでないものがある)。

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// Windows の既定のアカウント (runner の `steps::claude_accounts::DEFAULT_ACCOUNTS` と同じ並び。Windows には Linux の
/// claude-accounts.json が無い)
pub const WINDOWS_DEFAULT_ACCOUNTS: [&str; 2] = ["personal", "work"];

/// アカウントの名前に使えない名前 (`claude-account`・`claude-selector` のコマンドの名前。`claude-<名前>` の launcher と取り合う)
pub const RESERVED: [&str; 2] = ["account", "selector"];

/// アカウントの種類 (claude-account の mode)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// `/login` の資格情報で動く
    Subscription,
    /// `claude setup-token` の token で動く
    Token,
}

/// 選択肢に並べるアカウント。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Account {
    pub name: String,
    pub mode: Mode,
    /// dotfiles が作る既定のアカウントか (でなければ claude-account add で足した登録)
    pub default: bool,
    /// PATH で見つけた launcher (`claude-<名前>`)。無ければ選べない
    pub launcher: Option<PathBuf>,
}

/// 見つけたもの。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Found {
    /// PATH の `claude`
    pub claude: Option<PathBuf>,
    /// 既定の並びのあとに、登録を名前の順
    pub accounts: Vec<Account>,
    /// 一覧が読めなかったなどの知らせ (画面の上に出す)
    pub warnings: Vec<String>,
}

/// 既定のアカウントの名前の出どころ。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Defaults {
    /// 名前の配列の JSON (Linux の claude-accounts.json)。無ければ既定は無し
    File(PathBuf),
    /// 決まった名前 (Windows)
    Fixed(Vec<String>),
}

impl Defaults {
    /// この OS の出どころ
    pub fn for_this_os(home: &Path) -> Defaults {
        if cfg!(windows) {
            Defaults::Fixed(
                WINDOWS_DEFAULT_ACCOUNTS
                    .iter()
                    .map(|s| s.to_string())
                    .collect(),
            )
        } else {
            Defaults::File(state_file(home))
        }
    }
}

/// Linux の既定のアカウントの一覧 (home-manager が置く)
pub fn state_file(home: &Path) -> PathBuf {
    home.join(".local")
        .join("state")
        .join("dotfiles")
        .join("claude-accounts.json")
}

/// claude-account の登録の一覧 (Linux も Windows も家の下の同じ場所)
pub fn registry_file(home: &Path) -> PathBuf {
    home.join(".config")
        .join("claude-accounts")
        .join("accounts.json")
}

/// アカウントの名前の形 (`[a-z0-9][a-z0-9_-]*` で 32 字まで、token の頭 `sk-ant-` で始まらない。claude-account と同じ)。
/// 使えない名前 ([`RESERVED`]) は別に見る
pub fn name_ok(name: &str) -> bool {
    let mut chars = name.chars();
    let lead_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    lead_ok
        && name.len() <= 32
        && !name.starts_with("sk-ant-")
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// 既定と登録のアカウントを集め、PATH で launcher と `claude` を探す。`path` は環境変数 PATH の値
pub fn find(home: &Path, defaults: &Defaults, path: Option<&OsStr>) -> Found {
    let mut warnings = Vec::new();
    let names = match defaults {
        Defaults::Fixed(names) => names.clone(),
        Defaults::File(file) => read_defaults(file).unwrap_or_else(|w| {
            warnings.push(w);
            Vec::new()
        }),
    };
    let mut accounts: Vec<Account> = Vec::new();
    let mut push = |name: String, mode: Mode, default: bool| {
        let usable = name_ok(&name) && !RESERVED.contains(&name.as_str());
        if usable && !accounts.iter().any(|a| a.name == name) {
            accounts.push(Account {
                name,
                mode,
                default,
                launcher: None,
            });
        }
    };
    for name in names {
        push(name, Mode::Subscription, true);
    }
    match read_registry(&registry_file(home)) {
        Ok(registry) => {
            for (name, mode) in registry {
                push(name, mode, false);
            }
        }
        Err(w) => warnings.push(w),
    }
    for a in &mut accounts {
        a.launcher = which(path, &format!("claude-{}", a.name));
    }
    Found {
        claude: which(path, "claude"),
        accounts,
        warnings,
    }
}

/// ファイルを読む。無ければ None
fn read_text(path: &Path) -> Result<Option<String>, std::io::Error> {
    match std::fs::read_to_string(path) {
        Ok(t) => Ok(Some(t)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// 頭の BOM を外す (PowerShell 5.1 の Set-Content -Encoding UTF8・メモ帳は付ける。claude-account も読む)
fn strip_bom(text: &str) -> &str {
    text.strip_prefix('\u{feff}').unwrap_or(text)
}

/// 既定のアカウントの名前 (名前の配列の JSON)。無ければ空。読めなければ知らせる文
fn read_defaults(path: &Path) -> Result<Vec<String>, String> {
    let bad = |why: String| {
        format!(
            "既定のアカウントの一覧 ({}) が読めないので、既定のアカウントは出していません ({why})",
            path.display()
        )
    };
    let Some(text) = read_text(path).map_err(|e| bad(e.to_string()))? else {
        return Ok(Vec::new());
    };
    let v: serde_json::Value =
        serde_json::from_str(strip_bom(&text)).map_err(|e| bad(format!("JSON でない: {e}")))?;
    let Some(items) = v.as_array() else {
        return Err(bad("名前の配列でない".to_string()));
    };
    items
        .iter()
        .map(|x| {
            x.as_str()
                .map(str::to_string)
                .ok_or_else(|| bad("名前の配列でない".to_string()))
        })
        .collect()
}

/// claude-account の登録 (名前の順)。無ければ空。読めない形なら知らせる文
fn read_registry(path: &Path) -> Result<BTreeMap<String, Mode>, String> {
    let bad = |why: String| {
        format!(
            "claude-account の登録の一覧 ({}) が読めない形なので、足したアカウントは出していません ({why})",
            path.display()
        )
    };
    match read_text(path) {
        Ok(None) => Ok(BTreeMap::new()),
        Ok(Some(text)) => parse_registry(&text).map_err(bad),
        Err(e) => Err(bad(e.to_string())),
    }
}

/// 登録の一覧の文字列を読む (win/runner/src/accounts.rs の parse と同じ決まり)。形が違えばわけ
pub fn parse_registry(text: &str) -> Result<BTreeMap<String, Mode>, String> {
    let v: serde_json::Value =
        serde_json::from_str(strip_bom(text)).map_err(|e| format!("JSON でない: {e}"))?;
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
        let mode = match entry.get("mode").and_then(serde_json::Value::as_str) {
            Some("subscription") => Mode::Subscription,
            Some("token") => Mode::Token,
            _ => return Err(format!("{name} の mode が subscription・token でない")),
        };
        out.insert(name.clone(), mode);
    }
    Ok(out)
}

/// PATH (`path`) から `command` を探す (Windows は `<command>.exe`)。空の要素・相対パスの要素は今の dir を探すことになるので見ない。
/// unix では実行の権限のあるファイルだけ
pub fn which(path: Option<&OsStr>, command: &str) -> Option<PathBuf> {
    let file = format!("{command}{}", std::env::consts::EXE_SUFFIX);
    std::env::split_paths(path?)
        .filter(|dir| dir.is_absolute())
        .map(|dir| dir.join(&file))
        .find(|candidate| runnable(candidate))
}

#[cfg(unix)]
fn runnable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn runnable(path: &Path) -> bool {
    path.is_file()
}
