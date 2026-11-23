//! token のアカウント (`claude-account add <名前> --mode token`) の token。Linux の `nix/pkgs/claude-account` の token のファイルと同じ決まり
//! (dotfiles-private の docs/adr/082_claude_token_accounts_*)。
//!
//! token のファイルは `%USERPROFILE%\.config\claude-accounts\<名前>.env`。`#` で始まる行と空行のほかは `CLAUDE_CODE_OAUTH_TOKEN=<値>` の
//! 1 行だけ (頭の `export `・値の `'…'`・`"…"`・頭の BOM・行末の `\r` は読む)。値の形で読み方が決まる:
//!
//! | 値 | 読み方 |
//! | --- | --- |
//! | `op://…` | op-reason.exe (`--reason <理由> read <参照>`。1Password の承認と一緒に、理由と読む参照の窓が出る) |
//! | DPAPI の暗号文 (`ConvertFrom-SecureString` の出力。16 進で頭が [`DPAPI_HEADER`]) | System32 の powershell.exe で復号 (確認は出ない) |
//! | それ以外 | token そのもの (平文。`claude-account set-token` で入れ直すよう 1 行出す) |
//!
//! token を読む所は [`read`] だけ (使い心地で読み方を替えるときは、ここを直す)。値は env と stdin・stdout のパイプだけで渡し、引数・画面・
//! 文に出さない。`claude-account set-token` ([`set_token`]) は PowerShell が見えない入力で読み、DPAPI の暗号文だけを launcher に渡す
//! (平文は PowerShell の中だけにある)。

use crate::accounts;
use std::ffi::OsStr;
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Claude Code に token を渡す環境変数
pub const KEY: &str = "CLAUDE_CODE_OAUTH_TOKEN";
/// `ConvertFrom-SecureString` (DPAPI) の出力の頭 (DPAPI の blob の版 1 と provider の GUID)
pub const DPAPI_HEADER: &str = "01000000d08c9ddf0115d1118c7a00c04fc297eb";
/// PATH で探す op-reason (Windows は op-reason.exe。ほかの OS の名前は試験のため)
pub const OP_REASON_EXE: &str = if cfg!(windows) {
    "op-reason.exe"
} else {
    "op-reason"
};

/// DPAPI の暗号文 (env `DOTFILES_TOKEN_BLOB`) を復号して、改行を付けずに stdout へ出す。ASCII だけ
pub const DECRYPT_SCRIPT: &str = "$ErrorActionPreference = 'Stop'; try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $s = ConvertTo-SecureString -String $env:DOTFILES_TOKEN_BLOB; $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try { [Console]::Out.Write([Runtime.InteropServices.Marshal]::PtrToStringBSTR($p)) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }; exit 0 } catch { [Console]::Error.WriteLine('DPAPI: ' + $_.Exception.Message); exit 1 }";

/// token を見えない入力 (stdin がパイプなら 1 行) で読み、形を確かめて、DPAPI の暗号文だけを env `DOTFILES_TOKEN_OUT` のファイルに書く。
/// 終了コード: 3 = 空、4 = 端末なのに入力がリダイレクト扱い (Git Bash の mintty。読むと画面に出るので読まない。env `DOTFILES_SET_TOKEN_TTY`
/// が印)、5 = op:// の参照、6 = token の形でない。平文は PowerShell の中だけにあり、確かめたら消す。ASCII だけ
pub const SET_SCRIPT: &str = "$ErrorActionPreference = 'Stop'; try { if ([Console]::IsInputRedirected) { if ($env:DOTFILES_SET_TOKEN_TTY -eq '1') { exit 4 }; $line = [Console]::In.ReadLine(); if ($null -eq $line) { exit 3 }; $line = $line.Trim(); if ($line.Length -eq 0) { exit 3 }; $s = ConvertTo-SecureString -String $line -AsPlainText -Force; $line = $null } else { $s = Read-Host -AsSecureString -Prompt 'token' }; if ($s.Length -eq 0) { exit 3 }; $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); try { $t = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p).Trim(); if ($t.Length -eq 0) { $code = 3 } elseif ($t.StartsWith('op://')) { $code = 5 } elseif ($t -cnotmatch '^[!-~]+$' -or $t.Contains([string][char]34) -or $t.Contains([string][char]39) -or $t.Contains([string][char]92)) { $code = 6 } else { $code = 0; $s = ConvertTo-SecureString -String $t -AsPlainText -Force }; $t = $null } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }; if ($code -ne 0) { exit $code }; $blob = ConvertFrom-SecureString -SecureString $s; [IO.File]::WriteAllText($env:DOTFILES_TOKEN_OUT, $blob, (New-Object System.Text.UTF8Encoding($false))); exit 0 } catch { [Console]::Error.WriteLine('set-token: ' + $_.Exception.Message); exit 1 }";

/// token のファイル (`<家>\.config\claude-accounts\<名前>.env`)
pub fn file(home: &Path, name: &str) -> PathBuf {
    accounts::config_dir(home).join(format!("{name}.env"))
}

/// token のファイルに書いてあるもの。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Stored {
    /// token そのもの
    Plain(String),
    /// DPAPI の暗号文
    Dpapi(String),
    /// 1Password の参照
    Op(String),
}

/// token のファイルが読めないわけ (値を持たない)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Problem {
    Missing,
    Unreadable(String),
    NoLine,
    Empty,
    /// `KEY=値` の形でない行 (行の番号)
    BadLine(usize),
    /// ほかの名前の行 (行の番号と名前)
    OtherKey(usize, String),
    /// 2 つ目の行 (行の番号 2 つ)
    Duplicate(usize, usize),
    /// 引用符が閉じていない・後ろに余計な文字がある (行の番号)
    Unclosed(usize),
    /// token の形でない
    BadValue,
    /// 参照に使えない字がある
    BadRef,
    /// UTF-16 で保存されている (PowerShell 5.1 の `>` など)
    Utf16,
    /// ファイルがリンク (実体のファイルにする)
    Link,
}

impl Problem {
    /// 置き方の忠告を出す場合 (ファイル・行・値が無い)
    pub fn needs_guidance(&self) -> bool {
        matches!(self, Problem::Missing | Problem::NoLine | Problem::Empty)
    }

    /// わけ (値を含まない)。`file` はファイルの見せ方
    pub fn why(&self, file: &str) -> String {
        match self {
            Problem::Missing => format!("{file} が無い"),
            Problem::NoLine => format!("{file} に {KEY} の行が無い"),
            Problem::Empty => format!("{file} の {KEY} が空"),
            Problem::Unreadable(e) => format!("ファイルが読めません ({e})"),
            Problem::BadLine(n) => format!("{n} 行目が KEY=値 の形ではありません"),
            Problem::OtherKey(n, k) => {
                format!("{n} 行目に {k} があります (書けるのは {KEY} の行だけ)")
            }
            Problem::Duplicate(a, b) => format!("{KEY} の行が 2 つあります ({a} 行目と {b} 行目)"),
            Problem::Unclosed(n) => {
                format!("{n} 行目の引用符が閉じていないか、後ろに余計な文字があります")
            }
            Problem::BadValue => {
                "値が token の形ではありません (空白・引用符・制御文字など)".to_string()
            }
            Problem::BadRef => "参照 (op://…) に使えない字があります".to_string(),
            Problem::Utf16 => "ファイルが UTF-16 で保存されています (UTF-8 で保存し直すか、claude-account set-token で書き直す)".to_string(),
            Problem::Link => "ファイルがリンクです (実体のファイルにする。claude-account set-token で書き直せる)".to_string(),
        }
    }
}

fn is_ws(c: char) -> bool {
    c.is_ascii_whitespace()
}

/// token の形: 空白・制御文字・引用符・`\` の無い ASCII
pub fn token_ok(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| (0x21..=0x7e).contains(&b) && !matches!(b, b'"' | b'\'' | b'\\'))
}

/// op の参照の形 (制御文字・`{` `}`・引用符・`\` が無い。名前の空白は受ける)
pub fn ref_ok(s: &str) -> bool {
    !s.chars()
        .any(|c| c.is_control() || matches!(c, '{' | '}' | '"' | '\'' | '\\'))
}

/// DPAPI の暗号文の形 (16 進で、頭が [`DPAPI_HEADER`])
pub fn looks_dpapi(s: &str) -> bool {
    s.len() > DPAPI_HEADER.len()
        && s.len().is_multiple_of(2)
        && s.bytes().all(|b| b.is_ascii_hexdigit())
        && s.to_ascii_lowercase().starts_with(DPAPI_HEADER)
}

/// 値の引用符を解く (`'…'`・`"…"`・引用符なし (空白に続く `#` から後ろはコメント))。閉じていない・後ろに余計な文字があれば None
fn unquote(raw: &str) -> Option<String> {
    let rest = raw.trim_start_matches(is_ws);
    for q in ['\'', '"'] {
        if let Some(r) = rest.strip_prefix(q) {
            let end = r.find(q)?;
            let after = r[end + 1..].trim_start_matches(is_ws);
            if !(after.is_empty() || after.starts_with('#')) {
                return None;
            }
            return Some(r[..end].to_string());
        }
    }
    let bytes = rest.as_bytes();
    let cut = (1..bytes.len()).find(|&i| bytes[i] == b'#' && bytes[i - 1].is_ascii_whitespace());
    let v = match cut {
        Some(i) => &rest[..i],
        None => rest,
    };
    Some(v.trim_end_matches(is_ws).to_string())
}

/// token のファイルの中身を読む
pub fn parse(text: &str) -> Result<Stored, Problem> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut found: Option<(usize, String)> = None;
    for (i, raw) in text.split('\n').enumerate() {
        let n = i + 1;
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let body = line.trim_start_matches(is_ws);
        if body.is_empty() || body.starts_with('#') {
            continue;
        }
        let body = match body.strip_prefix("export") {
            Some(r) if r.starts_with(is_ws) => r.trim_start_matches(is_ws),
            _ => body,
        };
        let Some((key, val)) = body.split_once('=') else {
            return Err(Problem::BadLine(n));
        };
        let key_ok = key
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
            && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !key_ok {
            return Err(Problem::BadLine(n));
        }
        if key != KEY {
            return Err(Problem::OtherKey(n, key.to_string()));
        }
        if let Some((first, _)) = &found {
            return Err(Problem::Duplicate(*first, n));
        }
        let v = unquote(val).ok_or(Problem::Unclosed(n))?;
        found = Some((n, v));
    }
    let Some((_, v)) = found else {
        return Err(Problem::NoLine);
    };
    // 引用符の中の前後の空白は値の一部 (Linux の pjp-op-env と同じ読み方。" op://…" は参照でも token の形でもない)
    if v.is_empty() {
        return Err(Problem::Empty);
    }
    if v.starts_with("op://") {
        return if ref_ok(&v) {
            Ok(Stored::Op(v))
        } else {
            Err(Problem::BadRef)
        };
    }
    if looks_dpapi(&v) {
        return Ok(Stored::Dpapi(v));
    }
    if token_ok(&v) {
        Ok(Stored::Plain(v))
    } else {
        Err(Problem::BadValue)
    }
}

/// token のファイルを読む
pub fn load(path: &Path) -> Result<Stored, Problem> {
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(Problem::Link);
    }
    match std::fs::read(path) {
        Ok(bytes) if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) => {
            Err(Problem::Utf16)
        }
        Ok(bytes) => parse(&String::from_utf8_lossy(&bytes)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(Problem::Missing),
        Err(e) => Err(Problem::Unreadable(e.to_string())),
    }
}

/// token が無いときの忠告 (ローカルの置き方を先に、op を添える)
pub fn guidance(cmd: &str, name: &str, file: &Path, why: &str) -> String {
    let f = file.display();
    [
        format!("{cmd}: token がありません ({why})。"),
        format!(
            "  {cmd} は claude setup-token で出した token (1 年有効) で Claude Code を起こします。初めに 1 回だけ:"
        ),
        "    1. 自分の端末で claude setup-token を打ち、ブラウザで承認して token を出す".to_string(),
        "       (Claude Code の会話の中では打たない。token は画面に出るだけで、どこにも保存されない)".to_string(),
        format!(
            "    2. claude-account set-token {name} を打ち、token を貼る (見えない入力。DPAPI で暗号化して {f} に書く。このユーザーとこの PC でだけ読める)"
        ),
        "    3. token は 1Password にも入れておく (この PC から消したときに入れ直せる)".to_string(),
        "  1Password から毎回読むなら (起こすたびに 1Password の承認と op-reason の理由の窓が出る): 1Password の項目に token を入れ、欄のメニュー"
            .to_string(),
        "  「Copy Secret Reference」で取った参照を、そのファイルに 1 行で書く:".to_string(),
        format!("    {KEY}=op://…"),
    ]
    .join("\n")
}

/// token のファイルが読めないときの文。置き方の忠告か、わけと直し方
pub fn problem_message(cmd: &str, name: &str, file: &Path, p: &Problem) -> String {
    let f = file.display().to_string();
    if p.needs_guidance() {
        return guidance(cmd, name, file, &p.why(&f));
    }
    format!(
        "{cmd}: token のファイル ({f}) の {}。\n  直すか、claude-account set-token {name} で入れ直してください (値は出しません)。",
        p.why(&f)
    )
}

/// `claude-account help token [<名前>]` と、`add --mode token` の後に出す、token をこの PC とほかのマシンに置く手順 (ほかのマシンの手は
/// Linux の形。Linux の claude-account と同じ文)
pub fn help_text(name: Option<&str>) -> String {
    let n = name.unwrap_or("<名前>");
    [
        format!("token のアカウント claude-{n} に token を置く手順"),
        String::new(),
        "この PC:".to_string(),
        format!("  claude-account set-token {n}"),
        format!(
            "    見えない入力で token を貼る (DPAPI で暗号化して %USERPROFILE%\\.config\\claude-accounts\\{n}.env に書く。このユーザーとこの PC でだけ読める)"
        ),
        String::new(),
        "ほかのマシン (子を立てる Linux のマシンなど。登録はマシンごと):".to_string(),
        "  そのマシンの端末 (ssh か herdr-app の端末。Claude Code の ! は使わない) で打つ:".to_string(),
        format!("    claude-account add {n} --mode token"),
        format!("    claude-account set-token {n}"),
        "  そのマシンに claude-account がまだ無い (dotfiles が古い) ときは、同じ形のファイルを手で置く (fish からも打てる):".to_string(),
        format!(
            "    bash -c 'umask 077 && mkdir -p ~/.config/claude-accounts && read -rsp \"token: \" t && echo && printf \"CLAUDE_CODE_OAUTH_TOKEN=%s\\n\" \"$t\" > ~/.config/claude-accounts/{n}.env && unset t && chmod 600 ~/.config/claude-accounts/{n}.env && echo 置いた'"
        ),
        format!(
            "    (dotfiles を新しくしたら claude-account add {n} --mode token を打つ。置いたファイルはそのまま使う)"
        ),
        format!("  置けたかは、そのマシンで claude-account check {n} (0 なら使える。値は出さない)"),
        String::new(),
        "token の値:".to_string(),
        "  1Password のアプリで token の項目を開いて値をコピーし、set-token の入力に貼る。まだ無ければ、自分の端末で".to_string(),
        "  claude setup-token を打って出し (画面に出るだけで保存されない)、1Password に入れてから貼る".to_string(),
        format!(
            "  1Password から毎回読むなら (起こすたびに承認が出る): 参照を token のファイル ({n}.env) に 1 行で書く:"
        ),
        format!("    {KEY}=op://…"),
    ]
    .join("\n")
}

/// 読み方 (起こす前に決める。確認が出るのは op だけ)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Plan {
    Plain(String),
    Dpapi {
        blob: String,
        powershell: PathBuf,
    },
    Op {
        reference: String,
        op_reason: PathBuf,
    },
}

/// System32 の Windows PowerShell (同じユーザーが差し替えられる PATH の pwsh・powershell は使わない)
pub fn system_powershell(env: &dyn Fn(&str) -> Option<String>) -> PathBuf {
    let root = env("SystemRoot")
        .or_else(|| env("windir"))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "C:\\Windows".to_string());
    crate::context::join_segments(
        Path::new(&root),
        "System32/WindowsPowerShell/v1.0/powershell.exe",
    )
}

/// op-reason を探す: PATH の絶対の要素 → `%LOCALAPPDATA%\Programs\op-reason` (dotfiles の Install-OpReason の置き場)
pub fn find_op_reason(
    env: &dyn Fn(&str) -> Option<String>,
    path: Option<&OsStr>,
) -> Option<PathBuf> {
    let on_path = path.and_then(|p| {
        std::env::split_paths(p)
            .filter(|d| d.is_absolute())
            .map(|d| d.join(OP_REASON_EXE))
            .find(|c| c.is_file())
    });
    on_path.or_else(|| {
        let local = env("LOCALAPPDATA").filter(|s| !s.is_empty())?;
        let p = crate::context::join_segments(Path::new(&local), "Programs/op-reason")
            .join(OP_REASON_EXE);
        p.is_file().then_some(p)
    })
}

/// 読み方を決める (起こすものを探す。まだ読まない)
pub fn plan(
    cmd: &str,
    name: &str,
    stored: Stored,
    env: &dyn Fn(&str) -> Option<String>,
    path: Option<&OsStr>,
) -> Result<Plan, (i32, String)> {
    match stored {
        Stored::Plain(v) => Ok(Plan::Plain(v)),
        Stored::Dpapi(blob) => {
            let powershell = system_powershell(env);
            if !powershell.is_file() {
                return Err((
                    127,
                    format!(
                        "{cmd}: token を復号する powershell.exe が見つかりません ({})。",
                        powershell.display()
                    ),
                ));
            }
            Ok(Plan::Dpapi { blob, powershell })
        }
        Stored::Op(reference) => match find_op_reason(env, path) {
            Some(op_reason) => Ok(Plan::Op {
                reference,
                op_reason,
            }),
            None => Err((
                127,
                format!(
                    "{cmd}: token のファイルは 1Password の参照ですが、{OP_REASON_EXE} が見つかりません (PATH と %LOCALAPPDATA%\\Programs\\op-reason)。\n  1Password の承認に理由の窓を出すために要ります (op.exe には落としません)。WSL の setup (bootstrap-windows-op-reason。\n  受け持ちを runner に切り替えたホストは、ホストの値の [tools] に onePassword = true を書いて dotfiles apply) か Install-OpReason で入れるか、claude-account set-token {name} でこの PC に token を置いてください。"
                ),
            )),
        },
    }
}

/// op の道で op-reason に渡す理由
pub fn reason(cmd: &str) -> String {
    format!("{cmd} を起こすのに Claude Code の token (claude setup-token で出したもの) を読む")
}

/// token を読む (確認が出るのは op だけ)。token を読む所はここだけ。値は返すだけで出さない
pub fn read(cmd: &str, name: &str, plan: &Plan) -> Result<String, (i32, String)> {
    match plan {
        Plan::Plain(v) => {
            eprintln!(
                "{cmd}: token のファイルは平文です。claude-account set-token {name} で入れ直すと DPAPI で暗号化します (このユーザーとこの PC でだけ読める)。"
            );
            Ok(v.clone())
        }
        Plan::Dpapi { blob, powershell } => {
            let out = Command::new(powershell)
                .args([
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    DECRYPT_SCRIPT,
                ])
                .env("DOTFILES_TOKEN_BLOB", blob)
                // pwsh 7 から受け継いだ PSModulePath だと、Windows PowerShell 5.1 が ConvertTo-SecureString の module を読めないことがある
                .env_remove("PSModulePath")
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .output()
                .map_err(|e| {
                    (
                        127,
                        format!("{cmd}: {} を起こせません ({e})", powershell.display()),
                    )
                })?;
            if !out.status.success() {
                let why = String::from_utf8_lossy(&out.stderr)
                    .lines()
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_string();
                return Err((
                    1,
                    format!(
                        "{cmd}: token のファイルの暗号文を復号できません ({why})。\n  別のユーザーか別の PC で暗号化した、など。claude-account set-token {name} で入れ直してください。"
                    ),
                ));
            }
            take_token(cmd, name, out.stdout)
        }
        Plan::Op {
            reference,
            op_reason,
        } => {
            let out = Command::new(op_reason)
                .arg("--reason")
                .arg(reason(cmd))
                .arg("read")
                .arg(reference)
                .stdin(Stdio::inherit())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit())
                .output()
                .map_err(|e| {
                    (
                        127,
                        format!(
                            "{cmd}: {} を起こせません ({e})。Smart App Control に止められたなら、claude-account set-token {name} でこの PC に token を置いてください。",
                            op_reason.display()
                        ),
                    )
                })?;
            match out.status.code() {
                Some(0) => take_token(cmd, name, out.stdout),
                code => {
                    let c = code.unwrap_or(1);
                    Err((
                        c,
                        format!(
                            "{cmd}: op-reason が終了コード {c} で終わったので、claude を起こしません (1Password の承認を断った・時間切れ・op の誤りなど。上の文を見る)。"
                        ),
                    ))
                }
            }
        }
    }
}

/// 読んだ出力から token を取る (前後の空白と改行を外す)。token の形でなければ 70 (出力は出さない)
fn take_token(cmd: &str, name: &str, bytes: Vec<u8>) -> Result<String, (i32, String)> {
    let bad = || {
        (
            70,
            format!(
                "{cmd}: 読んだ値が token の形ではありません (出力は表示しません)。claude-account set-token {name} で入れ直すか、1Password の項目を確かめてください。"
            ),
        )
    };
    let s = String::from_utf8(bytes).map_err(|_| bad())?;
    let t = s.trim_matches(is_ws);
    if t.starts_with("op://") || !token_ok(t) {
        return Err(bad());
    }
    Ok(t.to_string())
}

/// `set-token` が書く token のファイルの中身
pub fn compose(name: &str, blob: &str) -> String {
    format!(
        "# claude-{name} の token (claude setup-token で出したもの)。claude-account set-token が DPAPI で暗号化して書いた (このユーザーとこの PC でだけ読める)\n{KEY}={blob}\n"
    )
}

/// SET_SCRIPT を流し、暗号文を `out` に書かせる。`input` があれば stdin に流す (試験)、無ければ端末の stdin のまま。PowerShell の終了コード
fn run_set_script(
    powershell: &Path,
    out: &Path,
    input: Option<&str>,
    tty: bool,
) -> Result<i32, String> {
    let mut cmd = Command::new(powershell);
    cmd.args([
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-Command",
        SET_SCRIPT,
    ])
    .env("DOTFILES_TOKEN_OUT", out)
    .env_remove("PSModulePath");
    // Git Bash の mintty は Rust には端末、PowerShell にはリダイレクトに見える。印を渡して、画面に出る読み方をさせない
    if tty {
        cmd.env("DOTFILES_SET_TOKEN_TTY", "1");
    }
    let status = match input {
        None => cmd.status(),
        Some(text) => {
            let mut child = cmd
                .stdin(Stdio::piped())
                .spawn()
                .map_err(|e| format!("{} を起こせません ({e})", powershell.display()))?;
            if let Some(mut w) = child.stdin.take() {
                let _ = w.write_all(text.as_bytes());
            }
            child.wait()
        }
    }
    .map_err(|e| format!("{} を起こせません ({e})", powershell.display()))?;
    Ok(status.code().unwrap_or(1))
}

/// `claude-account set-token <名前>` の中身: PowerShell が token を読んで暗号化し、その暗号文で token のファイルを書く。成功の文を返す。
/// `input` は試験のときだけ (stdin に流す)
pub fn set_token(
    name: &str,
    file: &Path,
    powershell: &Path,
    input: Option<&str>,
) -> Result<String, (i32, String)> {
    let dir = file
        .parent()
        .ok_or_else(|| (1, format!("{} の親が無い", file.display())))?;
    std::fs::create_dir_all(dir)
        .map_err(|e| (1, format!("{} を作れません ({e})", dir.display())))?;
    let tmp = dir.join(format!(".{name}.env.blob-{}", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let tty = input.is_none() && std::io::stdin().is_terminal();
    if tty {
        eprintln!(
            "claude-account: claude setup-token で出した token を貼って Enter を押してください (画面には * だけが出ます)"
        );
    }
    let code = run_set_script(powershell, &tmp, input, tty);
    let blob = std::fs::read_to_string(&tmp);
    let _ = std::fs::remove_file(&tmp);
    match code {
        Ok(0) => {}
        Ok(3) => {
            return Err((
                1,
                "claude-account: token が空です。何も書いていません。".to_string(),
            ));
        }
        Ok(4) => {
            return Err((
                1,
                "claude-account: この端末 (Git Bash の mintty など) では見えない入力にできないので、読みませんでした。PowerShell か Windows Terminal で打つか、winpty claude-account set-token <名前> で打ってください。何も書いていません。".to_string(),
            ));
        }
        Ok(5) => {
            return Err((
                1,
                "claude-account: op の参照は set-token でなく、token のファイルに 1 行で書きます (CLAUDE_CODE_OAUTH_TOKEN=op://…)。何も書いていません。".to_string(),
            ));
        }
        Ok(6) => {
            return Err((
                1,
                "claude-account: 入れた値が token の形ではありません (空白・引用符・制御文字など)。何も書いていません (値は出しません)。".to_string(),
            ));
        }
        Ok(c) => {
            return Err((
                1,
                format!(
                    "claude-account: PowerShell が終了コード {c} で終わりました。何も書いていません。"
                ),
            ));
        }
        Err(e) => return Err((1, format!("claude-account: {e}。何も書いていません。"))),
    }
    let blob = blob.map_err(|e| {
        (
            1,
            format!("claude-account: 暗号文が読めません ({e})。何も書いていません。"),
        )
    })?;
    let blob = blob.trim_matches(is_ws);
    if !looks_dpapi(blob) {
        return Err((
            70,
            "claude-account: PowerShell の出力が DPAPI の暗号文の形ではありません。何も書いていません。".to_string(),
        ));
    }
    crate::fsutil::write_atomic(file, compose(name, blob).as_bytes()).map_err(|e| {
        (
            1,
            format!("claude-account: {} に書けません ({e})", file.display()),
        )
    })?;
    Ok(format!(
        "書きました: {} (DPAPI で暗号化。このユーザーとこの PC でだけ読める)。claude-{name} で起こせます。",
        file.display()
    ))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 読み方: 平文・DPAPI の暗号文・op の参照を値の形で分ける。export・"…"・'…'・BOM・CRLF・空行・コメント・後ろのコメントを読む。
    //!   止まるもの: ファイルが無い・行が無い・値が空 (忠告を出す)・KEY=値 でない行・ほかの名前の行 (行の番号と名前)・2 つ目の行・閉じない
    //!   引用符・空白のある値・使えない字のある参照。どの文にも値が無い
    //! - 忠告: claude setup-token・claude-account set-token <名前>・DPAPI・op の参照の形を出す。help token はこの PC とほかのマシン (claude-account
    //!   の無いマシンの 1 行も)・check・値の取り方を、名前を埋めて出す
    //! - op-reason の探し方: PATH の絶対の要素 → %LOCALAPPDATA%\Programs\op-reason。無ければ 127 (op.exe に落とさない)
    //! - (unix) 偽の op-reason で read が理由・read・参照を渡し、値を返す。75 なら 75 で値を返さない。token の形でない出力は 70。偽の
    //!   PowerShell で DPAPI の道が暗号文を env で渡して値を返し、落ちれば 1
    //! - (windows) 本物の PowerShell で SET_SCRIPT (パイプの入力) → 暗号文 → token のファイル → read で元の値が戻る

    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn parse_picks_the_way_by_value() {
        assert_eq!(
            parse("CLAUDE_CODE_OAUTH_TOKEN=dummy-plain-1\n"),
            Ok(Stored::Plain("dummy-plain-1".into()))
        );
        assert_eq!(
            parse(
                "\u{feff}# token1\r\n\r\nexport CLAUDE_CODE_OAUTH_TOKEN=\"dummy-plain-2\"  # 入れた\r\n"
            ),
            Ok(Stored::Plain("dummy-plain-2".into()))
        );
        assert_eq!(
            parse("CLAUDE_CODE_OAUTH_TOKEN='dummy-plain-3'"),
            Ok(Stored::Plain("dummy-plain-3".into()))
        );
        assert_eq!(
            parse("CLAUDE_CODE_OAUTH_TOKEN=  dummy-plain-4  # c\n"),
            Ok(Stored::Plain("dummy-plain-4".into()))
        );
        assert_eq!(
            parse("CLAUDE_CODE_OAUTH_TOKEN=op://af4p/khuz/credential\n"),
            Ok(Stored::Op("op://af4p/khuz/credential".into()))
        );
        assert_eq!(
            parse("CLAUDE_CODE_OAUTH_TOKEN=\"op://Private/My Item/credential\"\n"),
            Ok(Stored::Op("op://Private/My Item/credential".into()))
        );
        let blob = format!("{DPAPI_HEADER}0000000abcdef");
        let blob = if blob.len() % 2 == 1 {
            format!("{blob}0")
        } else {
            blob
        };
        assert_eq!(
            parse(&format!("CLAUDE_CODE_OAUTH_TOKEN={blob}\n")),
            Ok(Stored::Dpapi(blob.clone()))
        );
    }

    #[test]
    fn parse_stops_without_showing_values() {
        let cases: [(&str, Problem); 11] = [
            // 引用符の中の前後の空白は値の一部 (Linux の pjp-op-env と同じ)
            (
                "CLAUDE_CODE_OAUTH_TOKEN=\" op://v/i/f\"\n",
                Problem::BadValue,
            ),
            ("CLAUDE_CODE_OAUTH_TOKEN=\"dummy-q \"\n", Problem::BadValue),
            ("# だけ\n", Problem::NoLine),
            ("", Problem::NoLine),
            ("CLAUDE_CODE_OAUTH_TOKEN=\n", Problem::Empty),
            ("dummy-raw\n", Problem::BadLine(1)),
            (
                "CLAUDE_CODE_OAUTH_TOKEN=dummy-a\nANTHROPIC_API_KEY=dummy-b\n",
                Problem::OtherKey(2, "ANTHROPIC_API_KEY".into()),
            ),
            (
                "CLAUDE_CODE_OAUTH_TOKEN=dummy-a\nCLAUDE_CODE_OAUTH_TOKEN=dummy-b\n",
                Problem::Duplicate(1, 2),
            ),
            ("CLAUDE_CODE_OAUTH_TOKEN=\"dummy-a\n", Problem::Unclosed(1)),
            ("CLAUDE_CODE_OAUTH_TOKEN=dummy a b\n", Problem::BadValue),
            ("CLAUDE_CODE_OAUTH_TOKEN=op://v/{i}/f\n", Problem::BadRef),
        ];
        let f = Path::new("C:\\Users\\u\\.config\\claude-accounts\\token1.env");
        for (text, want) in cases {
            let got = parse(text).unwrap_err();
            assert_eq!(got, want, "{text:?}");
            let msg = problem_message("claude-token1", "token1", f, &got);
            assert!(!msg.contains("dummy"), "{msg}");
            assert!(msg.contains("claude-account set-token token1"), "{msg}");
        }
        assert_eq!(load(&f.join("nosuch")), Err(Problem::Missing));
    }

    /// PowerShell 5.1 の > で書いた UTF-16 と、リンクの token のファイルは、わけと直し方を出して止まる
    #[test]
    fn load_refuses_utf16_and_links() {
        let t = TempDir::new("token-load");
        let p = t.path().join("token1.env");
        let mut bytes = vec![0xff, 0xfe];
        for u in "CLAUDE_CODE_OAUTH_TOKEN=dummy-u16\r\n".encode_utf16() {
            bytes.extend_from_slice(&u.to_le_bytes());
        }
        std::fs::write(&p, bytes).unwrap();
        let e = load(&p).unwrap_err();
        assert_eq!(e, Problem::Utf16);
        let msg = problem_message("claude-token1", "token1", &p, &e);
        assert!(msg.contains("UTF-8"), "{msg}");
        assert!(!msg.contains("dummy"), "{msg}");
        #[cfg(unix)]
        {
            let real = t.write("elsewhere/t.env", "CLAUDE_CODE_OAUTH_TOKEN=dummy-l\n");
            let link = t.path().join("token2.env");
            std::os::unix::fs::symlink(&real, &link).unwrap();
            assert_eq!(load(&link), Err(Problem::Link));
        }
    }

    #[test]
    fn guidance_says_where_and_how() {
        let f = Path::new("C:\\Users\\u\\.config\\claude-accounts\\token1.env");
        let g = problem_message("claude-token1", "token1", f, &Problem::Missing);
        for want in [
            "claude-token1: token がありません",
            "token1.env が無い",
            "claude setup-token",
            "claude-account set-token token1",
            "DPAPI",
            "Copy Secret Reference",
            "CLAUDE_CODE_OAUTH_TOKEN=op://",
        ] {
            assert!(g.contains(want), "{want}: {g}");
        }
        let h = help_text(Some("token1"));
        for want in [
            "claude-account set-token token1",
            "claude-account add token1 --mode token",
            "claude-account check token1",
            "Claude Code の ! は使わない",
            "umask 077 && mkdir -p ~/.config/claude-accounts && read -rsp",
            "~/.config/claude-accounts/token1.env && unset t",
            "1Password のアプリで token の項目",
            "CLAUDE_CODE_OAUTH_TOKEN=op://",
        ] {
            assert!(h.contains(want), "{want}: {h}");
        }
        assert!(help_text(None).contains("claude-account set-token <名前>"));
    }

    #[test]
    fn finds_op_reason_on_path_then_local_app_data() {
        let t = TempDir::new("op-reason");
        let on_path = t.write(&format!("bin/{OP_REASON_EXE}"), "x");
        let local = t.write(&format!("local/Programs/op-reason/{OP_REASON_EXE}"), "x");
        let env_local = |n: &str| {
            (n == "LOCALAPPDATA").then(|| t.path().join("local").to_string_lossy().into_owned())
        };
        let path = std::env::join_paths([t.path().join("empty"), t.path().join("bin")]).unwrap();
        assert_eq!(find_op_reason(&env_local, Some(&path)), Some(on_path));
        let empty = std::env::join_paths([t.path().join("empty")]).unwrap();
        assert_eq!(find_op_reason(&env_local, Some(&empty)), Some(local));
        assert_eq!(find_op_reason(&|_| None, Some(&empty)), None);
        let (code, msg) = plan(
            "claude-token1",
            "token1",
            Stored::Op("op://v/i/f".into()),
            &|_| None,
            Some(&empty),
        )
        .unwrap_err();
        assert_eq!(code, 127, "{msg}");
        assert!(msg.contains("op.exe には落としません"), "{msg}");
        assert!(msg.contains("claude-account set-token token1"), "{msg}");
        assert_eq!(
            plan("c", "n", Stored::Plain("dummy-p".into()), &|_| None, None),
            Ok(Plan::Plain("dummy-p".into()))
        );
    }

    #[cfg(unix)]
    fn script(t: &TempDir, rel: &str, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let p = t.write(rel, &format!("#!/bin/sh\n{body}"));
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    #[cfg(unix)]
    #[test]
    fn reads_through_op_reason() {
        let t = TempDir::new("op-reason-read");
        let log = t.path().join("args");
        let op = script(
            &t,
            "bin/op-reason",
            &format!(
                "for a in \"$@\"; do printf '%s\\n' \"$a\"; done >\"{}\"\nprintf 'dummy-op-value\\r\\n'\n",
                log.display()
            ),
        );
        let p = Plan::Op {
            reference: "op://v/i/f".into(),
            op_reason: op,
        };
        assert_eq!(
            read("claude-token1", "token1", &p),
            Ok("dummy-op-value".to_string())
        );
        let args = std::fs::read_to_string(&log).unwrap();
        assert_eq!(
            args.lines().collect::<Vec<_>>(),
            vec![
                "--reason",
                "claude-token1 を起こすのに Claude Code の token (claude setup-token で出したもの) を読む",
                "read",
                "op://v/i/f"
            ]
        );
        let declined = script(&t, "bin2/op-reason", "printf 'dummy-leak'\nexit 75\n");
        let (code, msg) = read(
            "claude-token1",
            "token1",
            &Plan::Op {
                reference: "op://v/i/f".into(),
                op_reason: declined,
            },
        )
        .unwrap_err();
        assert_eq!(code, 75, "{msg}");
        assert!(!msg.contains("dummy"), "{msg}");
        let junk = script(&t, "bin3/op-reason", "printf 'two words'\n");
        let (code, msg) = read(
            "claude-token1",
            "token1",
            &Plan::Op {
                reference: "op://v/i/f".into(),
                op_reason: junk,
            },
        )
        .unwrap_err();
        assert_eq!(code, 70, "{msg}");
        assert!(!msg.contains("two words"), "{msg}");
    }

    #[cfg(unix)]
    #[test]
    fn decrypts_through_powershell() {
        let t = TempDir::new("dpapi-read");
        let ps = script(
            &t,
            "ps/powershell.exe",
            "if [ \"$DOTFILES_TOKEN_BLOB\" = \"0100abcd\" ]; then printf 'dummy-dec-1'; else echo 'Key not valid' >&2; exit 1; fi\n",
        );
        let ok = Plan::Dpapi {
            blob: "0100abcd".into(),
            powershell: ps.clone(),
        };
        assert_eq!(
            read("claude-token1", "token1", &ok),
            Ok("dummy-dec-1".to_string())
        );
        let ng = Plan::Dpapi {
            blob: "0100ffff".into(),
            powershell: ps,
        };
        let (code, msg) = read("claude-token1", "token1", &ng).unwrap_err();
        assert_eq!(code, 1, "{msg}");
        assert!(msg.contains("Key not valid"), "{msg}");
        assert!(msg.contains("claude-account set-token token1"), "{msg}");
    }

    /// 本物の Windows PowerShell で、set-token の script (パイプの入力) → 暗号文 → token のファイル → 復号が元の値に戻る
    #[cfg(windows)]
    #[test]
    fn dpapi_round_trip_with_real_powershell() {
        let t = TempDir::new("dpapi");
        let ps = system_powershell(&|n| std::env::var(n).ok());
        let f = file(&t.path().join("home"), "token1");
        let msg = set_token("token1", &f, &ps, Some("dummy-dpapi-1\n")).unwrap();
        assert!(msg.contains("DPAPI"), "{msg}");
        let stored = load(&f).unwrap();
        let Stored::Dpapi(blob) = stored else {
            panic!("DPAPI の暗号文でない: {stored:?}");
        };
        assert!(!std::fs::read_to_string(&f).unwrap().contains("dummy"));
        let p = Plan::Dpapi {
            blob,
            powershell: ps.clone(),
        };
        assert_eq!(
            read("claude-token1", "token1", &p),
            Ok("dummy-dpapi-1".to_string())
        );
        // 空・op の参照・token の形でない入力は書かない
        for (input, want) in [
            ("\n", "空"),
            ("op://v/i/f\n", "op の参照"),
            ("two words\n", "token の形"),
        ] {
            let (code, msg) =
                set_token("token1", &t.path().join("x.env"), &ps, Some(input)).unwrap_err();
            assert_eq!(code, 1, "{input:?}: {msg}");
            assert!(msg.contains(want), "{input:?}: {msg}");
            assert!(!msg.contains("two words"), "{msg}");
            assert!(!t.path().join("x.env").exists());
        }
        // 端末の印があるのに入力がリダイレクト扱い (Git Bash の mintty) なら読まない
        let out = t.path().join("tty.blob");
        assert_eq!(
            run_set_script(&ps, &out, Some("dummy-dpapi-2\n"), true),
            Ok(4)
        );
        assert!(!out.exists());
    }
}
