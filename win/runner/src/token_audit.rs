//! claude の token を入れた時刻の控えと、棚卸し (`claude-account audit`)。Linux の nix/pkgs/claude-account/claude-account.sh の times_*・
//! cmd_audit と同じ形と文 (dotfiles-private の docs/adr/123_claude_token_watch_*)。
//!
//! | ファイル | 中身 | 書くもの |
//! | --- | --- | --- |
//! | `%USERPROFILE%\.local\state\claude-accounts\tokens.json` | set-token が入れた時刻 (`{"<名前>":{"set_at":"2026-11-28T21:00:00+09:00"}}`。値は置かない) | `claude-account set-token` (`put_time`) |
//! | `%USERPROFILE%\.local\state\dotfiles\claude-tokens.json` | 宣言 (`[claude.tokens]`。`host::claude_tokens_json`) | runner の手順 claude-tokens |
//!
//! 棚卸しは宣言・登録 (`accounts.json`) の token のアカウント・token のファイル (`<名前>.env`) を和にして、名前ごとに置き方・ACL・入れた時刻と
//! 経った日数を値を見ずに並べ、判定 (ok・回す・入れる・直す・宣言漏れ) を出す。Linux との違いは、頭の行のホスト (`<PC の名前> (Windows)`)・
//! 置き方 (DPAPI と平文を分け、平文は直す)・権限の列 (mode でなく ACL の要約。読み方と「広い」の数え方は手順 notion-tokens と同じ)・宣言の書き場所
//! (`[claude.tokens.<名前>]`)・素の claude (`default`。Windows の素の claude は token を読まない) だけ。
//!
//! 終了コード: 0 = 手を入れるものが無い / 1 = ある / 2 = 宣言・登録・控えを読めない (stderr に 1 行)。

use crate::accounts::{self, Mode, Registry};
use crate::host::{BARE_NAME, claude_token_label_ok, claude_token_name_ok, item_ref_ok};
use crate::process::Sys;
use crate::steps::claude_accounts::DEFAULT_ACCOUNTS;
use crate::steps::notion_tokens::{acl_summary, read_acl, wide_readers};
use crate::token::{self, Problem, Stored};
use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// 入れてからこの日数を超えた token は回す (setup-token の token は 1 年有効。月ごとの棚卸しで、期限の 1 か月より前に気付く)
pub const ROTATE_DAYS: i64 = 330;
/// setup-token の token の期限 (日)
pub const VALID_DAYS: i64 = 365;
/// 今の時刻を差し替える env (試験。2026-11-28T21:00:00+09:00 の形)
pub const NOW_ENV: &str = "CLAUDE_ACCOUNT_NOW";
/// 日本時間の UTC との差 (秒)
const JST: i64 = 9 * 3600;
/// 頭の行に出す宣言と控えの置き場 (Linux と同じ字。`~` は %USERPROFILE%)
const DECL_SHOWN: &str = "~/.local/state/dotfiles/claude-tokens.json";
const TIMES_SHOWN: &str = "~/.local/state/claude-accounts/tokens.json";

/// 宣言のファイル (`<家>\.local\state\dotfiles\claude-tokens.json`。runner の手順 claude-tokens が書く)
pub fn decl_path(home: &Path) -> PathBuf {
    home.join(".local")
        .join("state")
        .join("dotfiles")
        .join("claude-tokens.json")
}

/// 入れた時刻の控え (`<家>\.local\state\claude-accounts\tokens.json`)
pub fn times_path(home: &Path) -> PathBuf {
    home.join(".local")
        .join("state")
        .join("claude-accounts")
        .join("tokens.json")
}

// --- 時刻 (日本時間で書く)

/// 暦の年月日から 1970-01-01 からの日数 (Howard Hinnant の days_from_civil)
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// UNIX 秒を UTC の年・月・日・時・分・秒にする (0 より前は 0 に寄せる。fsutil の utc_fields)
fn fields(secs: i64) -> [i64; 6] {
    crate::fsutil::utc_fields(SystemTime::UNIX_EPOCH + Duration::from_secs(secs.max(0) as u64))
}

/// `YYYY-MM-DDTHH:MM:SS` に `+HH:MM`・`-HH:MM`・`Z` が続く字を UNIX 秒にする。読めない・暦に無い日なら None
pub fn parse_iso(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    if b.len() < 20
        || b[4] != b'-'
        || b[7] != b'-'
        || b[10] != b'T'
        || b[13] != b':'
        || b[16] != b':'
    {
        return None;
    }
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let t = s.get(r)?;
        (!t.is_empty() && t.bytes().all(|c| c.is_ascii_digit())).then(|| t.parse().ok())?
    };
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, se) = (num(11..13)?, num(14..16)?, num(17..19)?);
    let offset = match &s[19..] {
        "Z" => 0,
        rest if rest.len() == 6
            && (rest.starts_with('+') || rest.starts_with('-'))
            && rest.as_bytes()[3] == b':' =>
        {
            let oh = num(20..22)?;
            let om = num(23..25)?;
            if oh > 23 || om > 59 {
                return None;
            }
            let o = oh * 3600 + om * 60;
            if rest.starts_with('-') { -o } else { o }
        }
        _ => return None,
    };
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 59 {
        return None;
    }
    let days = days_from_civil(y, mo, d);
    let secs = days * 86_400 + h * 3600 + mi * 60 + se - offset;
    // 暦に無い日 (2 月 30 日など) は、日数から暦に戻すと別の日になる
    let back = fields(days * 86_400);
    if back[0] != y || back[1] != mo || back[2] != d {
        return None;
    }
    Some(secs)
}

/// UNIX 秒を日本時間の ISO 8601 (秒まで。`2026-11-28T21:00:00+09:00`) にする
pub fn iso_jst(secs: i64) -> String {
    let f = fields(secs + JST);
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}+09:00",
        f[0], f[1], f[2], f[3], f[4], f[5]
    )
}

/// UNIX 秒を日本時間の「YYYY-MM-DD HH:MM」にする
pub fn short_jst(secs: i64) -> String {
    let f = fields(secs + JST);
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}",
        f[0], f[1], f[2], f[3], f[4]
    )
}

/// 今の UNIX 秒。env の CLAUDE_ACCOUNT_NOW があればその時刻 (試験)。読めなければ Err (文)
pub fn now_epoch(env: &dyn Fn(&str) -> Option<String>) -> Result<i64, String> {
    match env(NOW_ENV).filter(|v| !v.is_empty()) {
        Some(v) => parse_iso(&v).ok_or_else(|| {
            format!("claude-account: 今の時刻を読めません ({NOW_ENV} は 2026-11-28T21:00:00+09:00 の形)。")
        }),
        None => Ok(SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)),
    }
}

// --- 入れた時刻の控え

/// 控えを読む (無ければ空)。名前ごとの値が set_at (文字列) を持つ object でなければ Err (文)
pub fn load_times(path: &Path) -> Result<serde_json::Map<String, serde_json::Value>, String> {
    let bad = || {
        format!(
            "claude-account: 入れた時刻の控え ({}) が読めない形です。消せば次の set-token が作り直します (消した token は棚卸しで「回す」と出る)。",
            path.display()
        )
    };
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(serde_json::Map::new()),
        Err(_) => return Err(bad()),
    };
    let Ok(serde_json::Value::Object(m)) = serde_json::from_str::<serde_json::Value>(&text) else {
        return Err(bad());
    };
    let ok = m.values().all(|v| {
        v.as_object()
            .is_some_and(|o| o.get("set_at").is_some_and(serde_json::Value::is_string))
    });
    if !ok {
        return Err(bad());
    }
    Ok(m)
}

/// 控えの `name` に時刻 `at` を書く (None なら外す)。ほかの名前・ほかのキーは残す。1 行の JSON (キーの順) と改行を、一時ファイルから置き換える
pub fn put_time(path: &Path, name: &str, at: Option<&str>) -> Result<(), String> {
    if at.is_none() && !path.exists() {
        return Ok(());
    }
    let mut m = load_times(path)?;
    match at {
        Some(t) => {
            let mut e = m
                .get(name)
                .and_then(serde_json::Value::as_object)
                .cloned()
                .unwrap_or_default();
            e.insert(
                "set_at".to_string(),
                serde_json::Value::String(t.to_string()),
            );
            m.insert(name.to_string(), serde_json::Value::Object(e));
        }
        None => {
            m.remove(name);
        }
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("claude-account: {} を作れません ({e})", dir.display()))?;
    }
    let text = format!("{}\n", serde_json::Value::Object(m));
    crate::fsutil::write_atomic(path, text.as_bytes())
        .map_err(|e| format!("claude-account: {} に書けません ({e})", path.display()))
}

/// 控えの `name` の入れた時刻 (控えの字のまま)。無ければ None
fn time_of(times: &serde_json::Map<String, serde_json::Value>, name: &str) -> Option<String> {
    times
        .get(name)
        .and_then(|v| v.get("set_at"))
        .and_then(serde_json::Value::as_str)
        .map(str::to_string)
}

// --- 宣言

/// 宣言 1 つ (呼び名と 1Password の参照)
struct Decl {
    label: String,
    item: Option<String>,
}

/// 宣言のファイルを読む。無ければ None、形が違えば Err (文)。形は Linux の decl_shape と同じ (名前・label・item は値を書けない形に限る)
fn load_decl(path: &Path) -> Result<Option<BTreeMap<String, Decl>>, String> {
    let bad = || {
        format!(
            "claude-account: 宣言 ({}) が読めない形です (dotfiles の runner の手順 claude-tokens が書く形でない)。dotfiles apply --steps claude-tokens で書き直してください。",
            path.display()
        )
    };
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(bad()),
    };
    let v: serde_json::Value = serde_json::from_str(&text).map_err(|_| bad())?;
    let Some(accounts) = v.get("accounts").and_then(serde_json::Value::as_object) else {
        return Err(bad());
    };
    let mut out = BTreeMap::new();
    for (name, e) in accounts {
        if !claude_token_name_ok(name) {
            return Err(bad());
        }
        let Some(label) = e.get("label").and_then(serde_json::Value::as_str) else {
            return Err(bad());
        };
        if !claude_token_label_ok(label) {
            return Err(bad());
        }
        let item = match e.get("item") {
            Some(serde_json::Value::Null) => None,
            Some(serde_json::Value::String(i)) if item_ref_ok(i) => Some(i.clone()),
            _ => return Err(bad()),
        };
        out.insert(
            name.clone(),
            Decl {
                label: label.to_string(),
                item,
            },
        );
    }
    Ok(Some(out))
}

// --- 棚卸し

/// 判定 (表の字と、数える順)
#[derive(Clone, Copy, PartialEq, Eq)]
enum Verdict {
    Ok,
    Rotate,
    Insert,
    Fix,
    Undeclared,
}

impl Verdict {
    fn as_str(self) -> &'static str {
        match self {
            Verdict::Ok => "ok",
            Verdict::Rotate => "回す",
            Verdict::Insert => "入れる",
            Verdict::Fix => "直す",
            Verdict::Undeclared => "宣言漏れ",
        }
    }
}

/// 外とのつなぎ (環境変数・外のコマンド・出力)
pub struct AuditIo<'a> {
    pub env: &'a dyn Fn(&str) -> Option<String>,
    pub sys: &'a dyn Sys,
    pub out: &'a mut dyn Write,
    pub err: &'a mut dyn Write,
}

/// `claude-account audit` の中身。`home` は %USERPROFILE%。終了コードを返す
pub fn audit(home: &Path, io: &mut AuditIo) -> i32 {
    let now = match now_epoch(io.env) {
        Ok(n) => n,
        Err(e) => {
            let _ = writeln!(io.err, "{e}");
            return 2;
        }
    };
    let decl = match load_decl(&decl_path(home)) {
        Ok(d) => d,
        Err(e) => {
            let _ = writeln!(io.err, "{e}");
            return 2;
        }
    };
    let registry = match Registry::load(&accounts::registry_path(home)) {
        Ok(r) => r,
        Err(e) => {
            let _ = writeln!(io.err, "claude-account: {e}");
            return 2;
        }
    };
    let times_file = times_path(home);
    let times = match load_times(&times_file) {
        Ok(t) => t,
        Err(e) => {
            let _ = writeln!(io.err, "{e}");
            return 2;
        }
    };
    let conf = accounts::config_dir(home);
    // 並べる名前: 宣言・登録の token のアカウント・token のファイル (名前の形のものだけ。set-token の一時ファイル (頭が .) は見ない)
    let mut names: BTreeSet<String> = BTreeSet::new();
    if let Some(d) = &decl {
        names.extend(d.keys().cloned());
    }
    names.extend(
        registry
            .accounts
            .iter()
            .filter(|(_, m)| **m == Mode::Token)
            .map(|(n, _)| n.clone()),
    );
    if let Ok(entries) = std::fs::read_dir(&conf) {
        for e in entries.flatten() {
            let file_name = e.file_name().to_string_lossy().into_owned();
            if let Some(n) = file_name.strip_suffix(".env")
                && accounts::name_ok(n)
            {
                names.insert(n.to_string());
            }
        }
    }

    let host = format!(
        "{} (Windows)",
        (io.env)("COMPUTERNAME").unwrap_or_else(|| "?".to_string())
    );
    let decl_count = decl.as_ref().map_or(0, BTreeMap::len);
    let out = &mut *io.out;
    let _ = writeln!(
        out,
        "claude-account audit: {host} ({} JST・入れてから {ROTATE_DAYS} 日を超えたら回す)",
        short_jst(now)
    );
    match &decl {
        Some(_) => {
            let _ = writeln!(out, "宣言: {DECL_SHOWN} ({decl_count} 件)");
        }
        None => {
            let _ = writeln!(
                out,
                "宣言: なし ({DECL_SHOWN} が無い。dotfiles が古いか、Claude Code を入れないホスト)"
            );
        }
    }
    if times_file.exists() {
        let _ = writeln!(out, "控え: {TIMES_SHOWN} ({} 件)", times.len());
    } else {
        let _ = writeln!(out, "控え: なし (まだ set-token で入れていない)");
    }
    let _ = writeln!(out);
    if names.is_empty() {
        let _ = writeln!(
            out,
            "token の置き場はありません (宣言も、token のアカウントも、token のファイルも無い)。"
        );
        return 0;
    }
    // 素の claude を先に、ほかは名前の順
    let mut sorted: Vec<String> = Vec::new();
    if names.contains(BARE_NAME) {
        sorted.push(BARE_NAME.to_string());
    }
    sorted.extend(names.iter().filter(|n| *n != BARE_NAME).cloned());

    let shell = io.sys.which("pwsh").or_else(|| io.sys.which("powershell"));
    let mut counts = [0usize; 5];
    let mut bullets: Vec<String> = Vec::new();
    let mut label_names: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let _ = writeln!(
        out,
        "| アカウント | 呼び名 | 1Password の参照 | 置き方 | 権限 | 入れた時刻 | 日数 | 判定 |"
    );
    let _ = writeln!(out, "| --- | --- | --- | --- | --- | --- | --- | --- |");
    for name in &sorted {
        let d = decl.as_ref().and_then(|d| d.get(name));
        let label = d.map_or("-".to_string(), |d| d.label.clone());
        let item = d
            .and_then(|d| d.item.clone())
            .unwrap_or_else(|| "-".to_string());
        let shown_name = if name == BARE_NAME {
            format!("{BARE_NAME} (素の claude)")
        } else {
            name.clone()
        };
        if let Some(d) = d {
            label_names
                .entry(d.label.clone())
                .or_default()
                .push(name.clone());
        }
        let mut missing_setup = String::new();
        let mut fix: Vec<String> = Vec::new();
        let mut token_reason = String::new();
        let mut rotate_reason = String::new();
        // 登録 (素の claude は宣言できない)
        if name == BARE_NAME {
            if d.is_some() {
                fix.push("Windows の素の claude は token を読まない (宣言から外す。Windows の素の claude は /login で使う)".to_string());
            }
        } else {
            let reg_mode = if DEFAULT_ACCOUNTS.contains(&name.as_str()) {
                Some(Mode::Subscription)
            } else {
                registry.accounts.get(name).copied()
            };
            match reg_mode {
                None => {
                    missing_setup = format!(
                        "登録が無い (claude-account add {name} --mode token を打ってから claude-account set-token {name})"
                    );
                }
                Some(Mode::Subscription) => fix.push(format!(
                    "subscription のアカウントとして登録している (token のアカウントなら claude-account remove {name} と claude-account add {name} --mode token)"
                )),
                Some(Mode::Token) => {}
            }
        }
        // token のファイル (形と ACL だけを見る。値は出さない)
        let file = token::file(home, name);
        let stored = token::load(&file);
        let src = match &stored {
            Ok(Stored::Plain(_)) => "ローカル (平文)",
            Ok(Stored::Dpapi(_)) => "ローカル (DPAPI)",
            Ok(Stored::Op(_)) => "1Password",
            Err(Problem::Missing) => "無い",
            Err(Problem::NoLine | Problem::Empty) => "空",
            Err(_) => "形が違う",
        };
        match &stored {
            Err(Problem::Missing | Problem::NoLine | Problem::Empty) => {
                token_reason = format!(
                    "token が無い (claude setup-token で出し、このホストで claude-account set-token {name} で入れる)"
                );
            }
            Err(p) => fix.push(format!("token のファイルの {}", p.why(&file.display().to_string()))),
            Ok(Stored::Plain(_)) => fix.push(format!(
                "token が平文で置かれている (claude-account set-token {name} で入れ直すと DPAPI の暗号文になる)"
            )),
            Ok(_) => {}
        }
        let present = !matches!(stored, Err(Problem::Missing | Problem::Link));
        let mut perm = "-".to_string();
        if present {
            let judged = matches!(stored, Ok(Stored::Plain(_) | Stored::Dpapi(_)));
            match &shell {
                None => {
                    perm = "?".to_string();
                    if judged {
                        fix.push("token のファイルの ACL を確かめられない (PowerShell が見つからない (pwsh・powershell))".to_string());
                    }
                }
                Some(sh) => match read_acl(io.sys, sh, &file) {
                    Ok(acl) => {
                        perm = acl_summary(&acl);
                        let wide = wide_readers(&acl);
                        if judged && !wide.is_empty() {
                            let dir = file
                                .parent()
                                .map(|p| p.display().to_string())
                                .unwrap_or_default();
                            fix.push(format!(
                                "token のファイルを本人・SYSTEM・Administrators のほかも読める ({}。置き場所のディレクトリ ({dir}) の ACL を icacls で見て直す)",
                                wide.join("・")
                            ));
                        }
                    }
                    Err(e) => {
                        perm = "?".to_string();
                        if judged {
                            fix.push(format!("token のファイルの ACL を確かめられない ({e})"));
                        }
                    }
                },
            }
        }
        // 入れた時刻 (set-token の控え)
        let mut setat = "-".to_string();
        let mut days = "-".to_string();
        let raw = time_of(&times, name);
        let parsed = raw.as_deref().and_then(parse_iso);
        if let Some(set) = parsed {
            let n = (now - set) / 86_400;
            days = n.to_string();
            setat = short_jst(set);
            if n > ROTATE_DAYS {
                let left = VALID_DAYS - n;
                rotate_reason = if left > 0 {
                    format!(
                        "入れてから {n} 日 ({ROTATE_DAYS} 日を超えた。期限の 1 年まで残り {left} 日)"
                    )
                } else {
                    format!(
                        "入れてから {n} 日 ({ROTATE_DAYS} 日を超えた。期限の 1 年を過ぎている見込み)"
                    )
                };
            }
        } else if stored.is_ok() {
            if raw.is_some() {
                rotate_reason =
                    "入れた時刻の控えが読めない (同じ token を set-token で入れ直せば控えができる)"
                        .to_string();
            } else {
                let mut r = "入れた時刻の控えが無い (set-token で入れていない".to_string();
                if matches!(stored, Ok(Stored::Op(_))) {
                    r.push_str(
                        "。1Password から読む token は、1Password の項目の値を替えた日で見る",
                    );
                }
                if let Some(m) = std::fs::metadata(&file)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                {
                    r.push_str(&format!(
                        "。ファイルの時刻は {}",
                        short_jst(m.as_secs() as i64)
                    ));
                }
                r.push_str("。同じ token を set-token で入れ直せば控えができる)");
                rotate_reason = r;
            }
        }
        let fix_reason = fix.join("。");
        // 判定 (入れる > 直す > 回す > ok。宣言の無いものは宣言漏れ)
        let mut reasons: Vec<String> = Vec::new();
        let verdict = if d.is_none() {
            if name == BARE_NAME {
                reasons.push(format!(
                    "素の claude ({BARE_NAME}) の token のファイルがある (Windows の素の claude は token を読まず、/login で使う。要らなければ消す)"
                ));
            } else {
                reasons.push(format!(
                    "宣言 ([claude.tokens.{name}]) が無い token の置き場 (回す対象から漏れている。宣言に足すか、要らなければ claude-account remove {name} --purge)"
                ));
            }
            for r in [&token_reason, &fix_reason, &rotate_reason] {
                if !r.is_empty() {
                    reasons.push(r.clone());
                }
            }
            Verdict::Undeclared
        } else if !missing_setup.is_empty() || !token_reason.is_empty() {
            reasons.push(if missing_setup.is_empty() {
                token_reason.clone()
            } else {
                missing_setup.clone()
            });
            if !fix_reason.is_empty() {
                reasons.push(fix_reason.clone());
            }
            Verdict::Insert
        } else if !fix_reason.is_empty() {
            reasons.push(fix_reason.clone());
            if !rotate_reason.is_empty() {
                reasons.push(rotate_reason.clone());
            }
            Verdict::Fix
        } else if !rotate_reason.is_empty() {
            reasons.push(rotate_reason.clone());
            Verdict::Rotate
        } else {
            Verdict::Ok
        };
        counts[verdict as usize] += 1;
        let _ = writeln!(
            out,
            "| {shown_name} | {label} | {item} | {src} | {perm} | {setat} | {days} | {} |",
            verdict.as_str()
        );
        for (i, r) in reasons.iter().enumerate() {
            if i == 0 {
                bullets.push(format!("- {name}: {} — {r}", verdict.as_str()));
            } else {
                bullets.push(format!("  - {r}"));
            }
        }
    }
    let _ = writeln!(out);
    if !bullets.is_empty() {
        for b in &bullets {
            let _ = writeln!(out, "{b}");
        }
        let _ = writeln!(out);
    }
    for (label, ns) in &label_names {
        if ns.len() > 1 {
            let _ = writeln!(
                out,
                "同じ token (呼び名 {label}) を置いたアカウント: {} (回すときは、どれも貼り直す)",
                ns.join("・")
            );
        }
    }
    if decl_count > 0 {
        let _ = writeln!(
            out,
            "呼び名が同じ行は、ほかのホストの同じ呼び名の行とも同じ token。回すときは、その全部のホストで貼り直す。"
        );
    }
    let _ = writeln!(
        out,
        "判定: ok {}・回す {}・入れる {}・直す {}・宣言漏れ {}",
        counts[Verdict::Ok as usize],
        counts[Verdict::Rotate as usize],
        counts[Verdict::Insert as usize],
        counts[Verdict::Fix as usize],
        counts[Verdict::Undeclared as usize]
    );
    if counts[Verdict::Ok as usize] == sorted.len() {
        0
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 時刻: `YYYY-MM-DDTHH:MM:SS` に +HH:MM・-HH:MM・Z が続く字を読み (日本時間・UTC・ほかの時差で同じ時刻)、日本時間の ISO 8601 と
    //!   「YYYY-MM-DD HH:MM」に書く。読めない字 (時差が無い・暦に無い 2 月 30 日・25 時・数字でない) は None。CLAUDE_ACCOUNT_NOW が読めなければ Err
    //! - 控え: 無ければ空。名前ごとの値が set_at (文字列) の object でなければ読めない形。書くと 1 行の JSON (キーの順) と改行で、ほかの名前と
    //!   ほかのキーは残し、外すとその名前だけが消える。無い控えから外すのは何もしない
    //! - 置き場: 宣言は ~/.local/state/dotfiles/claude-tokens.json、控えは ~/.local/state/claude-accounts/tokens.json

    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn reads_and_writes_times() {
        let jst = parse_iso("2026-11-28T21:00:00+09:00").unwrap();
        assert_eq!(parse_iso("2026-11-28T12:00:00Z"), Some(jst));
        assert_eq!(parse_iso("2026-11-28T07:00:00-05:00"), Some(jst));
        assert_eq!(iso_jst(jst), "2026-11-28T21:00:00+09:00");
        assert_eq!(short_jst(jst), "2026-11-28 21:00");
        // 日をまたぐ (UTC では前の日)
        let early = parse_iso("2026-01-01T08:59:59+09:00").unwrap();
        assert_eq!(iso_jst(early), "2026-01-01T08:59:59+09:00");
        assert_eq!(
            parse_iso("2024-02-29T00:00:00+09:00")
                .map(iso_jst)
                .as_deref(),
            Some("2024-02-29T00:00:00+09:00")
        );
        for bad in [
            "2026-11-28T21:00:00",
            "2026-02-30T00:00:00+09:00",
            "2026-11-28T25:00:00+09:00",
            "2026-11-28 21:00:00+09:00",
            "2026-1x-28T21:00:00+09:00",
            "2026-11-28T21:00:00+0900",
            "yesterday",
            "",
        ] {
            assert_eq!(parse_iso(bad), None, "{bad}");
        }
        let env_ok = |k: &str| (k == NOW_ENV).then(|| "2026-11-28T21:00:00+09:00".to_string());
        assert_eq!(now_epoch(&env_ok), Ok(jst));
        let env_bad = |k: &str| (k == NOW_ENV).then(|| "now".to_string());
        assert!(now_epoch(&env_bad).unwrap_err().contains(NOW_ENV));
    }

    #[test]
    fn keeps_the_record() {
        let t = TempDir::new("token-times");
        let home = t.path().join("home");
        let p = times_path(&home);
        assert!(
            p.ends_with(
                Path::new(".local")
                    .join("state")
                    .join("claude-accounts")
                    .join("tokens.json")
            )
        );
        assert!(
            decl_path(&home).ends_with(
                Path::new(".local")
                    .join("state")
                    .join("dotfiles")
                    .join("claude-tokens.json")
            )
        );
        assert!(load_times(&p).unwrap().is_empty());
        put_time(&p, "b", None).unwrap();
        assert!(!p.exists());
        put_time(&p, "b", Some("2026-11-28T21:00:00+09:00")).unwrap();
        put_time(&p, "a", Some("2026-11-27T21:00:00+09:00")).unwrap();
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "{\"a\":{\"set_at\":\"2026-11-27T21:00:00+09:00\"},\"b\":{\"set_at\":\"2026-11-28T21:00:00+09:00\"}}\n"
        );
        // ほかのキーは残す
        std::fs::write(&p, "{\"a\":{\"note\":1,\"set_at\":\"x\"}}\n").unwrap();
        put_time(&p, "a", Some("2026-11-29T00:00:00+09:00")).unwrap();
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "{\"a\":{\"note\":1,\"set_at\":\"2026-11-29T00:00:00+09:00\"}}\n"
        );
        put_time(&p, "a", None).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "{}\n");
        for bad in [
            "not json",
            "[]",
            "{\"a\":1}",
            "{\"a\":{}}",
            "{\"a\":{\"set_at\":1}}",
        ] {
            std::fs::write(&p, bad).unwrap();
            assert!(load_times(&p).unwrap_err().contains("読めない形"), "{bad}");
            assert!(put_time(&p, "a", Some("x")).is_err(), "{bad}");
        }
    }
}
