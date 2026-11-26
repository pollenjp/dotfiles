//! international (order 99): `win/international/managed.json` の値だけを、Windows の日付と時刻の形式 (`HKCU\Control Panel\International`) へ
//! 書く。WSL の `nix/scripts/bootstrap-windows-international.sh` を写したもの (持つ値・PowerShell の本文・判定・記録の名前と形・`--force`・取り込み・
//! 文言をそろえる。受け持ちを runner に切り替えた後に、WSL の setup が書いた値を同じものとして引き継ぐため)。設計は dotfiles-private の
//! docs/superpowers/specs/2026-11-07-windows-international-format-design.md、移し方は docs/adr/060_win_runner_core_* の spec §8 の 4。
//!
//! - 持つ値: managed.json のキー (レジストリの値の名前) のうち `TABLE` にあるもの (短い日付・長い時刻・短い時刻)。地域そのものと持たない値
//!   (長い日付・通貨・小数点・週の始まりなど) は変えない
//! - 書き方: レジストリを直に書かず、WSL と同じ PowerShell の本文 (`PS_BODY`。C# の包みから SetLocaleInfoW で user override を書き、
//!   WM_SETTINGCHANGE ("intl") を送り、読み戻す) を pwsh (PowerShell 7) に `-EncodedCommand` で渡す (runner に unsafe を入れない)。Windows
//!   PowerShell 5.1 へは落とさない (本文の `ConvertTo-Json -EscapeHandling` は PowerShell 6.2 から。WSL も pwsh.exe だけを使う)
//! - 判定 (値ごと。今の値は GetLocaleInfoEx、地域の既定は同じ LCType に LOCALE_NOUSEROVERRIDE を付けて読む):
//!
//!   | Windows の今の値 | すること |
//!   | --- | --- |
//!   | managed.json と同じ | 何もしない (記録が無ければ記録だけする) |
//!   | 前回書いた値 (記録) と同じ | managed.json が更新された。書く |
//!   | 記録が無く、地域の既定と同じ | 初めて書く (手で変えていない)。書く |
//!   | それ以外 | 衝突。値を出して触らない (`--force` なら書く) |
//!
//! - 書くときは、衝突でない値を全部、表の順に書き直し (同じ値も。ある値を書くと Windows が別の値を書き直す作りでも、持つ値に揃えて終わるよう)、
//!   読み戻して比べる。書けない・読み戻すと違う値・書く途中で pwsh が落ちたときは failed (記録は書けて揃った値だけ。落ちたときは書いた値を
//!   記録しない)。グループポリシーで止められた値 (Win32 のエラー 1260) は、流し直しても書けず dotfiles では直せないので manual。
//!   WM_SETTINGCHANGE を送れなければ ※ で知らせる (値は書けている)
//! - 記録は `%LOCALAPPDATA%\dotfiles\state\windows-international.applied.json` (`{"version":1,"values":{…}}`。WSL の `~/.local/state/dotfiles/` の
//!   記録と同じ名前・形・鍵。キーの順に並べて 2 字下げ。値が無ければ作らない)。WSL の記録は読まない: 切り替えた後の初めての apply は、WSL が
//!   書いた値を「同じ」と見て記録だけ作る。managed.json から消した値は Windows では戻さず、記録からだけ消す
//! - pwsh が無いときは manual、読めない・決めた形の JSON を返さないときは failed で、何も書かない (WSL は警告して exit 0)。持つ値が無ければ
//!   pwsh を呼ばない
//! - 取り込み (`dotfiles import international`。WSL の `--import`): 衝突した値を Windows から managed.json へ写す (jq の `--indent 4` の形。
//!   Windows には書かない)。managed.json に commit していない変更があると止まる
//! - check と dry-run は読むだけで、何も書かない (レジストリも記録も。WM_SETTINGCHANGE も送らない)
//! - SSH の会話の apply は、書く値があれば書かずに manual (Win32-OpenSSH の会話はセッション 0 で、WM_SETTINGCHANGE がデスクトップの会話の
//!   アプリに届かない。WSL の setup はデスクトップの端末からしか流れないので、runner にだけある分かれ道。powertoys と同じ形)。dry-run は、SSH の
//!   会話の中なら本番の apply が書かないことを予告する

use super::ps1;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::jv::{self, Jv};
use crate::process::{Exit, strip_ansi};
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// 持つ値 (repo からの相対)
pub const MANAGED_REL: &str = "win/international/managed.json";
/// 記録のファイル名 (WSL の `~/.local/state/dotfiles/` の記録と同じ名前)
pub const RECORD_FILE: &str = "windows-international.applied.json";
/// 持てる値: レジストリの値の名前と、GetLocaleInfoEx・SetLocaleInfoW に渡す LCType (winnls.h の値)。書くのもこの順 (WSL の `table`。長い時刻を
/// 短い時刻より先に書く)。値を足すときは WSL の script の表と同じく 1 行足す (試験が突き合わせる)
pub const TABLE: &[(&str, u32)] = &[
    ("sShortDate", 31),
    ("sTimeFormat", 4099),
    ("sShortTime", 121),
];
/// 形式の文字列の長さの上限 (終わりの NUL を含めて 80 字。LOCALE_SSHORTDATE・LOCALE_STIMEFORMAT の文書。WSL の `max_len`)
const MAX_LEN: usize = 79;
/// pwsh を待つ上限 (WSL の `timeout 60`。書くときの WM_SETTINGCHANGE は、応答の遅い窓ごとに最大 5 秒待ちうる)
const PS_SECS: u64 = 60;
/// グループポリシーで止められている (ERROR_ACCESS_DISABLED_BY_POLICY)。WSL と同じく、エラーの番号を jq の `-r` で読んだ字で比べる
const POLICY_ERROR: &str = "1260";

/// pwsh に渡す本文 (WSL の `ps_body` と同じ字。末尾の改行も)。先頭に `$Mode` と `$InputJson` の 2 行を足して渡す (`ps_script`)。返りは 1 行の
/// JSON: `{"locale":"en-US","values":[{"name","current","default"}],"failed":[{"name","error"}],"broadcast":null か {"ok","error"}}`
pub const PS_BODY: &str = r##"$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -Namespace DotfilesIntl -Name Nls -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
static extern int GetLocaleInfoEx(string lpLocaleName, uint LCType, System.Text.StringBuilder lpLCData, int cchData);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
static extern bool SetLocaleInfoW(uint Locale, uint LCType, string lpLCData);
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
// Reads with LOCALE_NAME_USER_DEFAULT (NULL).
public static string Get(uint lctype) {
  System.Text.StringBuilder buf = new System.Text.StringBuilder(128);
  if (GetLocaleInfoEx(null, lctype, buf, buf.Capacity) == 0) {
    throw new Exception("GetLocaleInfoEx(0x" + lctype.ToString("X") + ") failed: Win32 error " + Marshal.GetLastWin32Error());
  }
  return buf.ToString();
}
// Locale = LOCALE_USER_DEFAULT (0x0400). The W version ignores it. Returns 0, or the Win32 error (-1 if unknown).
public static int Set(uint lctype, string value) {
  if (SetLocaleInfoW(0x0400, lctype, value)) { return 0; }
  int e = Marshal.GetLastWin32Error();
  return e != 0 ? e : -1;
}
// WM_SETTINGCHANGE (0x001A) to HWND_BROADCAST (0xFFFF), lParam "intl", SMTO_ABORTIFHUNG (0x0002), 5000 ms.
// Returns 0, or the Win32 error (-1 if unknown).
public static int Broadcast() {
  UIntPtr res;
  if (SendMessageTimeoutW(new IntPtr(0xFFFF), 0x001A, UIntPtr.Zero, "intl", 0x0002, 5000, out res) != IntPtr.Zero) { return 0; }
  int e = Marshal.GetLastWin32Error();
  return e != 0 ? e : -1;
}
'@
$entries = @(ConvertFrom-Json -InputObject $InputJson)
$failed = @()
$broadcast = $null
if ($Mode -eq 'write') {
  $wrote = 0
  foreach ($e in $entries) {
    if (-not $e.write) { continue }
    $err = [DotfilesIntl.Nls]::Set([uint32]$e.lctype, [string]$e.value)
    if ($err -eq 0) { $wrote++ } else { $failed += [ordered]@{ name = $e.name; error = $err } }
  }
  if ($wrote -gt 0) {
    $err = [DotfilesIntl.Nls]::Broadcast()
    $broadcast = [ordered]@{ ok = ($err -eq 0); error = $err }
  }
}
$values = @(foreach ($e in $entries) {
    [ordered]@{
      name = $e.name
      current = [DotfilesIntl.Nls]::Get([uint32]$e.lctype)
      default = [DotfilesIntl.Nls]::Get([uint32]$e.lctype + [uint32]2147483648)
    }
  })
# LOCALE_SNAME (0x5C) is the name of the locale (en-US).
[ordered]@{ locale = [DotfilesIntl.Nls]::Get(0x5C); values = $values; failed = $failed; broadcast = $broadcast } |
  ConvertTo-Json -Compress -Depth 4 -EscapeHandling EscapeNonAscii
"##;

pub struct International;

impl Step for International {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "international",
            order: 99,
            title: "日付と時刻の形式 (HKCU\\Control Panel\\International) の持つ値を書く",
            gate: Gate::Always,
            ported: true,
            windows_only: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode)]
    }
}

/// 値ごとの判定 (WSL の `action`)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Same,
    Update,
    Add,
    Conflict,
}

/// 持つ値 1 つの計画 (WSL の `plan` の 1 つ)。
#[derive(Clone, Debug)]
struct Entry {
    name: &'static str,
    lctype: u32,
    want: String,
    cur: String,
    def: String,
    /// 前回書いた値 (記録に鍵があれば。手で書き換えた記録の、文字列でない値も持つ)
    rec: Option<Jv>,
    action: Action,
}

impl Entry {
    /// 記録が持つ値と同じか (WSL の `.has_rec and .rec == .want`)
    fn recorded(&self) -> bool {
        self.rec
            .as_ref()
            .is_some_and(|r| jv::jq_eq(r, &Jv::String(self.want.clone())))
    }

    /// 書く行の頭 (`名前: "今の値" → "持つ値"`)
    fn change(&self) -> String {
        format!(
            "{}: {} → {}",
            self.name,
            jv::jq_string(&self.cur),
            jv::jq_string(&self.want)
        )
    }
}

/// managed.json を読んで確かめる (WSL の `validate_managed` と同じ決まりと文)。誤りなら出す行を返す。
fn load_managed(path: &Path) -> Result<Jv, Vec<String>> {
    if !path.is_file() {
        return Err(vec![format!(
            "!! {MANAGED_REL} がありません ({})。",
            path.display()
        )]);
    }
    let parsed = std::fs::read_to_string(path)
        .map_err(|e| e.to_string())
        .and_then(|t| Jv::parse(&t));
    let doc = match parsed {
        Ok(v @ Jv::Object(_)) => v,
        Ok(_) => {
            return Err(vec![format!(
                "!! {MANAGED_REL} が JSON の object ではありません。"
            )]);
        }
        Err(e) => {
            return Err(vec![
                format!("!! {MANAGED_REL} が JSON の object ではありません。"),
                format!("   {e}"),
            ]);
        }
    };
    let known: Vec<&str> = TABLE.iter().map(|(n, _)| *n).collect();
    let mut problems = Vec::new();
    for (k, v) in doc.as_object().into_iter().flatten() {
        // 長さと制御文字は字 (Unicode の符号位置) で数える (jq の length と explode)
        let problem = if !known.contains(&k.as_str()) {
            Some(format!(
                "知らない名前です: {k} (持てるのは {})",
                known.join("・")
            ))
        } else {
            match v {
                Jv::String(s) if s.is_empty() => Some(format!("{k} の値が空です。")),
                Jv::String(s) if s.chars().count() > MAX_LEN => Some(format!(
                    "{k} の値が長すぎます ({} 字。{MAX_LEN} 字まで)。",
                    s.chars().count()
                )),
                Jv::String(s) if s.chars().any(|c| (c as u32) < 32 || c == '\u{7f}') => Some(
                    format!("{k} の値に制御文字があります: {}", jv::jq_string(s)),
                ),
                Jv::String(_) => None,
                other => Some(format!(
                    "{k} の値が文字列ではありません: {}",
                    other.compact()
                )),
            }
        };
        problems.extend(problem);
    }
    if problems.is_empty() {
        Ok(doc)
    } else {
        let mut lines = vec![format!("!! {MANAGED_REL} に誤りがあります:")];
        lines.extend(problems.into_iter().map(|p| format!("   {p}")));
        Err(lines)
    }
}

/// 前回書いた値の記録 (`{"version":1,"values":{…}}`。知らないキーも残す)。
struct Record {
    path: PathBuf,
    doc: Jv,
}

impl Record {
    /// 読む。無ければ空。`values` を持つ object でなければ、出す行を返す (WSL と同じ文)。
    fn load(path: &Path) -> Result<Record, Vec<String>> {
        let doc = match std::fs::read_to_string(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Jv::parse(r#"{"version":1,"values":{}}"#).expect("空の記録")
            }
            r => match r.map_err(|e| e.to_string()).and_then(|t| Jv::parse(&t)) {
                Ok(v) if v.get("values").is_some_and(Jv::is_object) => v,
                _ => {
                    return Err(vec![
                        format!(
                            "!! {} が壊れています (values を持つ JSON の object ではありません)。",
                            path.display()
                        ),
                        "   消してから流し直すと、managed.json とも地域の既定とも違う値は衝突として扱われます".to_string(),
                        "   (値を確かめて、取り込むか --force)。".to_string(),
                    ]);
                }
            },
        };
        Ok(Record {
            path: path.to_path_buf(),
            doc,
        })
    }

    fn values_mut(&mut self) -> &mut Jv {
        match &mut self.doc {
            Jv::Object(entries) => {
                &mut entries
                    .iter_mut()
                    .find(|(k, _)| k == "values")
                    .expect("load が values を確かめた")
                    .1
            }
            _ => unreachable!("load が object を確かめた"),
        }
    }

    fn get(&self, name: &str) -> Option<&Jv> {
        self.doc.get("values").and_then(|v| v.get(name))
    }

    fn set(&mut self, name: &str, value: &str) {
        self.values_mut().set(name, Jv::String(value.to_string()));
    }

    /// managed.json に無い値を記録から外す (managed.json から消した値)
    fn retain(&mut self, managed: &Jv) {
        if let Jv::Object(entries) = self.values_mut() {
            entries.retain(|(k, _)| managed.get(k).is_some());
        }
    }

    /// `version` を 1 にして、キーの順に並べた 2 字下げの形 (WSL の `jq -S '.version = 1'`) が今のファイルと違えば書く。ファイルが無く、
    /// 値も無ければ作らない (WSL と同じ)。書いたら true。
    fn save_if_changed(&mut self) -> std::io::Result<bool> {
        self.doc.set("version", Jv::from(1));
        let exists = self.path.is_file();
        let empty = matches!(self.doc.get("values"), Some(Jv::Object(e)) if e.is_empty());
        if !exists && empty {
            return Ok(false);
        }
        let new = format!("{}\n", self.doc.sorted().indent(2));
        let old = exists
            .then(|| std::fs::read_to_string(&self.path).ok())
            .flatten()
            .and_then(|t| Jv::parse(&t).ok())
            .map(|v| format!("{}\n", v.sorted().indent(2)));
        if old.as_deref() == Some(new.as_str()) {
            return Ok(false);
        }
        fsutil::write_atomic(&self.path, new.as_bytes())?;
        Ok(true)
    }
}

/// jq の `-a`: ASCII の外の字を `\uXXXX` (UTF-16 の単位。16 進は小文字) にする。
fn ascii_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_ascii() {
            out.push(c);
        } else {
            let mut buf = [0u16; 2];
            for u in c.encode_utf16(&mut buf) {
                out.push_str(&format!("\\u{u:04x}"));
            }
        }
    }
    out
}

/// pwsh に渡す PowerShell (WSL の `run_ps` が組み立てるのと同じ字: `$Mode` と `$InputJson` の 2 行の後ろに本文)。入力の JSON は jq の `-c -a` の
/// 形にして `'` を重ねる (日本語の形式も、ASCII だけの本文で渡せる)。
fn ps_script(mode: &str, input: &Jv) -> String {
    let json = ascii_json(&input.compact());
    format!(
        "$Mode = '{mode}'\n$InputJson = '{}'\n{PS_BODY}",
        json.replace('\'', "''")
    )
}

/// pwsh を流した結果。
struct PsRun {
    exit: Exit,
    /// stdout (返りの JSON。CR を落として行をつなげたもの。stderr は混ぜない)
    out: String,
    /// 人に見せる出力 (stdout と stderr を届いた順に。CLIXML は平文の行に直し、色を落とし、空の行は出さない)
    shown: Vec<String>,
}

/// pwsh で本文を流す (`-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand`。WSL と同じ引数と待つ上限)。
fn run_ps(ctx: &Ctx, shell: &Path, mode: &str, input: &Jv) -> PsRun {
    let spec = ps1::encoded_command(
        shell.to_path_buf(),
        &ps_script(mode, input),
        Duration::from_secs(PS_SECS),
    )
    .stdout_only();
    let mut all = Vec::new();
    let r = ctx.sys.run(&spec, &mut |l| all.push(l.to_string()));
    let out = r
        .output
        .iter()
        .map(|l| l.replace('\r', ""))
        .collect::<Vec<_>>()
        .join("\n");
    let shown = ps1::plain_lines(&all)
        .iter()
        .map(|l| strip_ansi(l).replace('\r', ""))
        .filter(|l| !l.trim().is_empty())
        .collect();
    PsRun {
        exit: r.exit,
        out,
        shown,
    }
}

/// pwsh の終わり方を文にする。
fn describe(exit: &Exit) -> String {
    match exit {
        Exit::Code(c) => format!("終了コード {c}"),
        Exit::NoCode => "終了コードが無い".to_string(),
        Exit::TimedOut => format!("{PS_SECS} 秒たっても終わらなかった"),
        Exit::SpawnFailed(e) => format!("起こせなかった: {e}"),
    }
}

/// pwsh で読んだ Windows の値。
struct Windows {
    locale: String,
    /// (名前, 今の値, 地域の既定)
    values: Vec<(String, String, String)>,
}

/// 持つ値の名前 (表のうち managed.json にあるもの。表の順)
fn held_names(managed: &Jv) -> Vec<&'static str> {
    TABLE
        .iter()
        .map(|(n, _)| *n)
        .filter(|n| managed.get(n).is_some())
        .collect()
}

/// 返りの JSON を読む。形は WSL の jq の式と同じく確かめる: 地域の名前が文字列で、頼んだ名前の全部 (と、それだけ) に、文字列の今の値と地域の
/// 既定がある (null の要素は飛ばし、object でない要素があれば読めない。jq の `.name` が落ちるため)。
fn parse_reply(out: &str, names: &[&str]) -> Option<Windows> {
    let v = Jv::parse(out).ok()?;
    let locale = match v.get("locale") {
        Some(Jv::String(s)) => s.clone(),
        _ => return None,
    };
    let items: Vec<&Jv> = match v.get("values") {
        Some(Jv::Array(a)) => a.iter().collect(),
        Some(Jv::Object(e)) => e.iter().map(|(_, x)| x).collect(),
        _ => Vec::new(),
    };
    let mut values = Vec::new();
    for it in items {
        match it {
            Jv::Null => {}
            Jv::Object(_) => {
                if let (Some(Jv::String(n)), Some(Jv::String(c)), Some(Jv::String(d))) =
                    (it.get("name"), it.get("current"), it.get("default"))
                {
                    values.push((n.clone(), c.clone(), d.clone()));
                }
            }
            _ => return None,
        }
    }
    let mut got: Vec<&str> = values.iter().map(|v| v.0.as_str()).collect();
    got.sort_unstable();
    let mut want = names.to_vec();
    want.sort_unstable();
    (got == want).then_some(Windows { locale, values })
}

/// pwsh で今の値・地域の既定・地域の名前を読む (WSL の 1 回目の `run_ps read`)。読めなければ出す行を出して、締めの行を返す。
fn read_windows(ctx: &mut Ctx, shell: &Path, managed: &Jv) -> Result<Windows, Outcome> {
    let names = held_names(managed);
    let input = Jv::Array(
        TABLE
            .iter()
            .filter(|(n, _)| names.contains(n))
            .map(|(n, t)| {
                Jv::Object(vec![
                    ("name".into(), Jv::from(*n)),
                    ("lctype".into(), Jv::from(i64::from(*t))),
                ])
            })
            .collect(),
    );
    let r = run_ps(ctx, shell, "read", &input);
    if r.exit != Exit::Code(0) {
        let why = describe(&r.exit);
        ctx.say(if r.exit == Exit::TimedOut {
            format!("!! pwsh が {PS_SECS} 秒たっても終わりませんでした (時間切れ)。")
        } else {
            format!("!! pwsh で Windows の日付と時刻の形式を読めませんでした ({why}):")
        });
        for l in &r.shown {
            ctx.say(format!("   {l}"));
        }
        ctx.say("   この手順は飛ばします。");
        return Err(Outcome::new(
            Kind::Failed,
            format!("pwsh で日付と時刻の形式を読めなかった ({why})"),
        ));
    }
    parse_reply(&r.out, &names).ok_or_else(|| {
        ctx.say("!! pwsh の返りが、決めた形の JSON ではありません:");
        for l in &r.shown {
            ctx.say(format!("   {l}"));
        }
        ctx.say("   この手順は飛ばします。");
        Outcome::new(Kind::Failed, "pwsh の返りが、決めた形の JSON でない")
    })
}

/// 持つ値ごとの計画 (WSL の `plan` と同じ判定の順: 同じ → 記録どおり → 記録が無くて地域の既定 → 衝突)。表の順。
fn plan(managed: &Jv, win: &Windows, record: &Record) -> Vec<Entry> {
    TABLE
        .iter()
        .filter_map(|&(name, lctype)| {
            let want = managed.get(name)?.as_str()?.to_string();
            let (_, cur, def) = win.values.iter().find(|v| v.0 == name)?;
            let rec = record.get(name).cloned();
            let action = if *cur == want {
                Action::Same
            } else if rec
                .as_ref()
                .is_some_and(|r| jv::jq_eq(r, &Jv::String(cur.clone())))
            {
                Action::Update
            } else if rec.is_none() && cur == def {
                Action::Add
            } else {
                Action::Conflict
            };
            Some(Entry {
                name,
                lctype,
                want,
                cur: cur.clone(),
                def: def.clone(),
                rec,
                action,
            })
        })
        .collect()
}

/// 手順の前半 (managed.json → 記録 → pwsh。WSL と同じ順に確かめる)。止まるときは締めの行を返す。持つ値が無ければ pwsh は呼ばない (None)。
fn prepare(ctx: &mut Ctx) -> Result<(Jv, Record, Option<PathBuf>), Outcome> {
    let managed = match load_managed(&ctx.repo_path(MANAGED_REL)) {
        Ok(m) => m,
        Err(lines) => {
            for l in &lines {
                ctx.say(l);
            }
            let mut o = Outcome::new(Kind::Failed, format!("{MANAGED_REL} に誤りがある"));
            o.notes = lines.iter().skip(1).map(|l| l.trim().to_string()).collect();
            return Err(o);
        }
    };
    let record = match Record::load(&ctx.state_dir.join(RECORD_FILE)) {
        Ok(r) => r,
        Err(lines) => {
            for l in &lines {
                ctx.say(l);
            }
            let mut o = Outcome::new(Kind::Failed, "書いた記録が壊れている");
            o.notes = vec![lines.join(" ").trim_start_matches("!! ").to_string()];
            return Err(o);
        }
    };
    if held_names(&managed).is_empty() {
        return Ok((managed, record, None));
    }
    let Some(shell) = ctx.sys.which("pwsh") else {
        ctx.say("!! pwsh が見つかりません (PowerShell 7 が無いか、PATH に入っていない)。");
        ctx.say("   Windows の日付と時刻の形式を確かめられないので、この手順は飛ばします。");
        return Err(Outcome::new(
            Kind::Manual,
            "PowerShell 7 (pwsh) が見つからないので、日付と時刻の形式を確かめられない",
        )
        .note("PowerShell 7 を入れてから流し直す (bootstrap の win/bootstrap/Install-Bootstrap.ps1 が入れる。普段のアカウントが管理者の PC は MSIX、管理者でない PC は MSI)"));
    };
    Ok((managed, record, Some(shell)))
}

/// 取り込みのコマンド (受け持ちで替える。受け持ちが WSL の間は WSL の script の `--import`)
fn import_command(ctx: &Ctx) -> String {
    if ctx.host.runner_enable {
        "dotfiles import international".to_string()
    } else {
        "WSL で nix/scripts/bootstrap-windows-international.sh --import (受け持ちが WSL の setup の間。runner の取り込みは止まる)".to_string()
    }
}

/// --force のコマンド (受け持ちで替える)
fn force_command(ctx: &Ctx) -> String {
    super::deploy::force_command(ctx, "international")
}

/// 衝突した値の、Windows 側・managed.json・前回書いた値・地域の既定を出す (WSL の `report_conflict`)。
fn report_conflict(ctx: &mut Ctx, e: &Entry, locale: &str) {
    if e.rec.is_none() {
        // runner は WSL の記録を読まないので、受け持ちが WSL の間は、WSL が書いた後で設定画面で変えた値もここに来る
        let before = if ctx.host.runner_enable {
            ""
        } else {
            "。受け持ちを切り替える前なら、WSL が書いた値とこの dotfiles の clone の managed.json が違うか、WSL が書いた後に設定画面で変えた"
        };
        ctx.say(format!(
            "!! 衝突: {} は、書いた記録が無く、地域 ({locale}) の既定とも違います (設定画面で変えた・手で設定してあった、など{before})。",
            e.name
        ));
    } else if e.cur == e.def {
        ctx.say(format!(
            "!! 衝突: {} は、前回書いた値から地域 ({locale}) の既定に戻っています (地域を変えた・設定画面で既定に戻した、など)。",
            e.name
        ));
    } else {
        ctx.say(format!(
            "!! 衝突: {} は Windows 側で変わっています (前回書いた値と違う。設定画面で変えた、など)。",
            e.name
        ));
    }
    ctx.say(format!("   Windows 側:    {}", jv::jq_string(&e.cur)));
    ctx.say(format!("   managed.json:  {}", jv::jq_string(&e.want)));
    if let Some(r) = &e.rec {
        ctx.say(format!("   前回書いた値:  {}", r.compact()));
    }
    ctx.say(format!("   地域の既定:    {}", jv::jq_string(&e.def)));
}

/// 書いた結果 (WSL の `failures`・`crash`・`policy_keys`・`mark` と WM_SETTINGCHANGE)。
#[derive(Default)]
struct Written {
    /// 書けて、読み戻しても持つ値だった値 (記録する)
    ok: Vec<&'static str>,
    /// 書けなかった値の行
    failures: Vec<String>,
    /// 書く途中で pwsh が落ちたときの行 (どの値が書けたか分からないので記録しない)
    crash: Vec<String>,
    /// グループポリシーで止められていて書けない値
    policy: Vec<&'static str>,
    /// 書く行に添える印 (値の名前と印)
    marks: Vec<(&'static str, &'static str)>,
    /// WM_SETTINGCHANGE: None は送っていない (1 つも書けなかった)、Some(None) は送れた、Some(Some(エラー)) は送れなかった
    broadcast: Option<Option<String>>,
}

/// 書く (WSL の 2 回目の `run_ps write`)。衝突でない値 (`write_names`) を表の順に書き、全部を読み戻す。`log` は出力に出す変わる値。
fn write_values(
    ctx: &mut Ctx,
    shell: &Path,
    entries: &[Entry],
    write_names: &[&'static str],
    log: &[(&'static str, String)],
) -> Written {
    let input = Jv::Array(
        entries
            .iter()
            .map(|e| {
                Jv::Object(vec![
                    ("name".into(), Jv::from(e.name)),
                    ("lctype".into(), Jv::from(i64::from(e.lctype))),
                    ("value".into(), Jv::String(e.want.clone())),
                    ("write".into(), Jv::Bool(write_names.contains(&e.name))),
                ])
            })
            .collect(),
    );
    let r = run_ps(ctx, shell, "write", &input);
    let mut w = Written::default();
    let reply = Jv::parse(&r.out).ok().filter(|v| {
        r.exit == Exit::Code(0)
            && matches!(v.get("values"), Some(Jv::Array(_)))
            && matches!(v.get("failed"), Some(Jv::Array(_)))
    });
    let Some(reply) = reply else {
        w.crash.push(format!(
            "書く途中で pwsh が失敗しました ({})。どの値が書けたかは分からないので、記録していません:",
            describe(&r.exit)
        ));
        w.crash.extend(r.shown.iter().cloned());
        w.crash
            .push("もう一度流すと、読み直して判定します。".to_string());
        w.marks = log
            .iter()
            .map(|(n, _)| (*n, "書けたか分かりません"))
            .collect();
        return w;
    };
    // `.<key>[] | select(.name == $n) | .<field>` を jq の -r で読んだ字 (当たりが無ければ空、複数なら改行でつなぐ。WSL と同じ)
    let pick = |key: &str, name: &str, field: &str| -> String {
        reply
            .get(key)
            .and_then(Jv::as_array)
            .into_iter()
            .flatten()
            .filter(|it| it.get("name").and_then(Jv::as_str) == Some(name))
            .map(|it| it.get(field).unwrap_or(&Jv::Null).tostring())
            .collect::<Vec<_>>()
            .join("\n")
    };
    for &name in write_names {
        let want = &entries
            .iter()
            .find(|e| e.name == name)
            .expect("書く値は計画にある")
            .want;
        let err = pick("failed", name, "error");
        if err == POLICY_ERROR {
            w.policy.push(name);
            w.marks
                .push((name, "グループポリシーで止められていて書けません"));
        } else if !err.is_empty() {
            w.failures
                .push(format!("{name}: 書けませんでした (Win32 のエラー {err})"));
            w.marks.push((name, "書けませんでした"));
        } else {
            let got = pick("values", name, "current");
            if got == *want {
                w.ok.push(name);
            } else {
                w.failures.push(format!(
                    "{name}: 書いた後に読み戻すと {} で、managed.json の {} と違います",
                    jv::jq_string(&got),
                    jv::jq_string(want)
                ));
                w.marks.push((name, "書けませんでした"));
            }
        }
    }
    w.broadcast = match reply.get("broadcast") {
        None | Some(Jv::Null) => None,
        Some(b) if b.get("ok") == Some(&Jv::Bool(true)) => Some(None),
        Some(b) => Some(Some(b.get("error").unwrap_or(&Jv::Null).tostring())),
    };
    w
}

/// 締めの行の数。
#[derive(Default)]
struct Tally {
    same: usize,
    add: usize,
    update: usize,
    conflicts: usize,
    /// 書けなかった値 (書く途中で pwsh が落ちたら、書くはずだった変わる値の全部)
    failed: usize,
    policy: usize,
    /// SSH の会話の中なので書かなかった
    held: bool,
}

impl Tally {
    fn summary(&self, mode: Mode, n: usize, locale: Option<&str>) -> String {
        let mut s = format!(
            "持つ値 {n} 件: 同じ {} / 初めて書く {} / 書き換える {} / 衝突 {}",
            self.same, self.add, self.update, self.conflicts
        );
        if self.failed > 0 {
            s.push_str(&format!(" / 書けない {}", self.failed));
        }
        if self.policy > 0 {
            s.push_str(&format!(" / グループポリシーで書けない {}", self.policy));
        }
        if let Some(l) = locale {
            s.push_str(&format!(" (地域 {l})"));
        }
        if self.held {
            s.push_str(" (SSH の会話の中なので書いていない)");
        }
        if matches!(mode, Mode::DryRun { .. }) {
            s = format!("[dry-run] {s}");
        }
        s
    }

    fn kind(&self, mode: Mode) -> Kind {
        if self.failed > 0 {
            Kind::Failed
        } else if self.conflicts > 0 || self.policy > 0 || self.held {
            Kind::Manual
        } else if mode.writes() {
            Kind::Ok
        } else if self.update > 0 {
            Kind::Fix
        } else if self.add > 0 {
            Kind::Missing
        } else {
            Kind::Ok
        }
    }
}

/// 手順の中身。WSL の script と同じ順に確かめる (managed.json → 記録 → pwsh で読む → 値ごとの判定 → 書く → 記録)。
fn sync(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let (managed, mut record, shell) = match prepare(ctx) {
        Ok(p) => p,
        Err(o) => return o,
    };
    let n = managed.as_object().map_or(0, Vec::len);
    let (locale, entries) = match &shell {
        None => (None, Vec::new()),
        Some(shell) => match read_windows(ctx, shell, &managed) {
            Ok(w) => (Some(w.locale.clone()), plan(&managed, &w, &record)),
            Err(o) => return o,
        },
    };
    let at = locale.as_deref().unwrap_or("");
    let pre = if matches!(mode, Mode::DryRun { .. }) {
        "[dry-run] "
    } else {
        ""
    };
    let mut tally = Tally::default();
    // 書く値 (衝突でない値の全部。同じ値も書き直す) と、出力に出す変わる値の行
    let mut write_names: Vec<&'static str> = Vec::new();
    let mut log: Vec<(&'static str, String)> = Vec::new();
    let mut conflicts: Vec<&'static str> = Vec::new();
    let mut unrecorded = 0;
    for e in &entries {
        match e.action {
            Action::Same => {
                tally.same += 1;
                write_names.push(e.name);
                if !e.recorded() {
                    if mode.writes() {
                        record.set(e.name, &e.want);
                    } else {
                        unrecorded += 1;
                    }
                }
            }
            Action::Add | Action::Update => {
                let label = match (mode, e.action) {
                    (Mode::Check, Action::Add) => "初めて書く。今の値は地域の既定。apply で書く",
                    (Mode::Check, _) => "managed.json が更新された。apply で書き換える",
                    (_, Action::Add) => "初めて書く。今の値は地域の既定",
                    _ => "managed.json が更新された",
                };
                if e.action == Action::Add {
                    tally.add += 1;
                } else {
                    tally.update += 1;
                }
                write_names.push(e.name);
                log.push((e.name, format!("  {pre}{} ({label})", e.change())));
            }
            Action::Conflict if mode.force() => {
                tally.update += 1;
                write_names.push(e.name);
                log.push((e.name, format!("  {pre}{} (--force)", e.change())));
            }
            Action::Conflict => {
                tally.conflicts += 1;
                conflicts.push(e.name);
                report_conflict(ctx, e, at);
            }
        }
    }

    // SSH の会話 (Win32-OpenSSH はセッション 0) からは、WM_SETTINGCHANGE がデスクトップの会話のアプリに届かない。書いた値がデスクトップの
    // 会話にいつ効くかも確かめていないので、書く値があれば書かない (記録だけの更新はする)
    let held = !log.is_empty() && mode.writes() && ctx.in_ssh();
    // dry-run は、SSH の会話の中なら本番の apply が書かないことを予告する (行の種類は、apply で書く値の種類のまま)
    let held_ahead = !log.is_empty() && matches!(mode, Mode::DryRun { .. }) && ctx.in_ssh();
    let mut written = Written::default();
    if let Some(shell) = shell.as_deref()
        && !log.is_empty()
        && mode.writes()
        && !held
    {
        written = write_values(ctx, shell, &entries, &write_names, &log);
        for name in &written.ok {
            if let Some(e) = entries.iter().find(|e| e.name == *name) {
                record.set(name, &e.want);
            }
        }
    }

    if log.is_empty() && conflicts.is_empty() {
        let at = locale
            .as_deref()
            .map(|l| format!("。地域 {l}"))
            .unwrap_or_default();
        ctx.say(format!(
            "Windows の日付と時刻の形式は揃っています (持つ値 {n} 件{at})。"
        ));
    }
    if !log.is_empty() {
        ctx.say(format!("==> {pre}Windows の日付と時刻の形式 (地域 {at})"));
        for (name, line) in &log {
            let mark = written
                .marks
                .iter()
                .find(|(m, _)| m == name)
                .map(|(_, m)| *m)
                .or(held.then_some("SSH の会話の中なので書いていません"));
            match mark {
                Some(m) => ctx.say(format!("{line} … {m}")),
                None => ctx.say(line),
            }
        }
        if written.broadcast == Some(None) {
            ctx.say("  WM_SETTINGCHANGE (intl) を送りました。開いているアプリ (タスクバーの時計など) は、その場で読み直します。");
        }
    }
    if let Some(Some(err)) = &written.broadcast {
        ctx.say(format!(
            "!! WM_SETTINGCHANGE を送れませんでした (Win32 のエラー {err})。値は書けています。"
        ));
        ctx.say("   開いているアプリ (タスクバーの時計など) には、サインアウトしてサインインし直すと効きます。");
    }
    if held {
        ctx.say("SSH の会話の中なので、日付と時刻の形式は書きません (Win32-OpenSSH の会話はセッション 0 で、WM_SETTINGCHANGE がデスクトップの会話のアプリに届かないため)。");
        ctx.say("   PC のデスクトップの PowerShell で dotfiles apply --steps international を流してください。");
    }
    if held_ahead {
        ctx.say("※ SSH の会話の中なので、本番の apply は日付と時刻の形式を書きません (WM_SETTINGCHANGE がデスクトップの会話のアプリに届かないため)。PC のデスクトップの PowerShell で dotfiles apply --steps international を流してください。");
    }
    if !written.policy.is_empty() {
        ctx.say(format!(
            "!! 次の値は、この PC ではグループポリシーで止められていて書けません (Win32 のエラー 1260): {}",
            written.policy.join("、")
        ));
        ctx.say("   変えられるのは組織の管理者だけなので、この値は飛ばします (ほかの値は書きます。次の apply でも同じ ⚠ が出ます)。");
        ctx.say("   この PC で持たないなら、managed.json からその値を消す (ほかの PC にも効く) しかありません。");
    }
    if unrecorded > 0 {
        if ctx.host.runner_enable {
            ctx.say(format!(
                "書いた記録がまだ無い値が {unrecorded} 件あります (apply で、今の値を見て記録だけ作ります)。"
            ));
        } else {
            ctx.say(format!(
                "runner の記録はまだありません ({unrecorded} 件。受け持ちを runner に切り替えた後の apply で、今の値を見て記録だけ作ります。WSL の setup の記録は WSL の ~/.local/state/dotfiles/{RECORD_FILE})。"
            ));
        }
    }
    if !conflicts.is_empty() {
        ctx.say(format!(
            "!! Windows 側で変わっていた (か、書く前から手で設定してあった) ので、次の値には触っていません (値は上): {}",
            conflicts.join("、")
        ));
        ctx.say(format!(
            "   Windows 側の値を残すなら (managed.json へ取り込み、commit して push する): {}",
            import_command(ctx)
        ));
        ctx.say(format!(
            "   managed.json の値で書くなら: {}",
            force_command(ctx)
        ));
    }
    if !written.failures.is_empty() {
        ctx.say("!! 次の値は書けませんでした (書けた値は記録してあります):");
        for f in &written.failures {
            ctx.say(format!("   {f}"));
        }
    }
    if let Some((first, rest)) = written.crash.split_first() {
        ctx.say(format!("!! {first}"));
        for l in rest {
            ctx.say(format!("   {l}"));
        }
    }

    // 記録 (apply だけ。managed.json から消した値は記録からも消す)
    if mode.writes() {
        record.retain(&managed);
        if let Err(e) = record.save_if_changed() {
            ctx.say(format!(
                "!! 書いた記録を書けません: {} ({e})",
                record.path.display()
            ));
            return Outcome::new(Kind::Failed, "書いた記録を書けない")
                .note(format!("{} ({e})", record.path.display()));
        }
    }

    tally.failed = written.failures.len()
        + if written.crash.is_empty() {
            0
        } else {
            log.len()
        };
    tally.policy = written.policy.len();
    tally.held = held;
    let summary = tally.summary(mode, n, locale.as_deref());
    ctx.say("");
    ctx.say(&summary);
    let mut outcome = Outcome::new(tally.kind(mode), summary);
    if !conflicts.is_empty() {
        outcome = outcome.note(if ctx.host.runner_enable {
            format!(
                "衝突は上の出力の解き方で直す (Windows 側の値を managed.json へ取り込む ({}) か、{})",
                import_command(ctx),
                force_command(ctx)
            )
        } else {
            "受け持ちは WSL の setup (runner.enable が true でない)。runner の記録はまだ無いので、WSL が書いた値とこの clone の managed.json が違う値・WSL が書いた後に設定画面で変えた値は衝突と読む。clone を同じ commit にそろえて見直す。衝突を解くのは WSL の側 (bootstrap-windows-international.sh の --import か --force)".to_string()
        });
    }
    if !written.failures.is_empty() {
        outcome = outcome.note("書けなかった値は上の出力を見る (流し直すと、読み直して判定する)");
    }
    if !written.crash.is_empty() {
        outcome = outcome.note(
            "書く途中で pwsh が落ちたので、書いた値を記録していない (流し直すと、読み直して判定する)",
        );
    }
    if !written.policy.is_empty() {
        outcome = outcome.note(format!(
            "グループポリシーで止められていて書けない値がある ({})。変えられるのは組織の管理者だけ。この PC で持たないなら managed.json からその値を消す (ほかの PC にも効く)",
            written.policy.join("、")
        ));
    }
    if let Some(Some(err)) = &written.broadcast {
        outcome = outcome.note(format!(
            "WM_SETTINGCHANGE を送れなかった (Win32 のエラー {err})。開いているアプリ (タスクバーの時計など) には、サインアウトしてサインインし直すと効く"
        ));
    }
    if held_ahead {
        outcome = outcome.note("SSH の会話の中なので、本番の apply は書かない。PC のデスクトップの PowerShell で dotfiles apply --steps international を流す");
    }
    if held {
        outcome = outcome.note("SSH の会話の中なので書いていない。PC のデスクトップの PowerShell で dotfiles apply --steps international を流す (WM_SETTINGCHANGE は、SSH の会話からデスクトップの会話のアプリに届かない)");
    }
    outcome
}

/// 取り込み (`dotfiles import international`。WSL の `--import`): 衝突した値を Windows から managed.json へ写す。Windows には書かない。
pub fn import(ctx: &mut Ctx) -> Outcome {
    let (mut managed, mut record, shell) = match prepare(ctx) {
        Ok(p) => p,
        Err(o) => return o,
    };
    if let Err(lines) = super::terminal::uncommitted(ctx, MANAGED_REL) {
        for l in &lines {
            ctx.say(l);
        }
        let mut o = Outcome::new(
            Kind::Failed,
            format!(
                "{MANAGED_REL} に commit していない変更があるか、確かめられないので取り込まない"
            ),
        );
        o.notes = vec![lines[0].trim_start_matches("!! ").to_string()];
        return o;
    }
    let entries = match &shell {
        None => Vec::new(),
        Some(shell) => match read_windows(ctx, shell, &managed) {
            Ok(w) => plan(&managed, &w, &record),
            Err(o) => return o,
        },
    };
    let mut imports: Vec<&Entry> = Vec::new();
    let mut pending: Vec<&'static str> = Vec::new();
    for e in &entries {
        match e.action {
            Action::Same => {
                if !e.recorded() {
                    record.set(e.name, &e.want);
                }
            }
            Action::Add | Action::Update => pending.push(e.name),
            Action::Conflict => imports.push(e),
        }
    }
    let managed_path = ctx.repo_path(MANAGED_REL);
    if !imports.is_empty() {
        for e in &imports {
            managed.set(e.name, Jv::String(e.cur.clone()));
        }
        if let Err(err) =
            fsutil::write_atomic(&managed_path, format!("{}\n", managed.indent(4)).as_bytes())
        {
            ctx.say(format!(
                "!! {MANAGED_REL} に書けませんでした: {} ({err})",
                managed_path.display()
            ));
            return Outcome::new(Kind::Failed, format!("{MANAGED_REL} に書けない ({err})"));
        }
        for e in &imports {
            record.set(e.name, &e.cur);
        }
    }
    record.retain(&managed);
    if let Err(e) = record.save_if_changed() {
        ctx.say(format!(
            "!! 書いた記録を書けません: {} ({e})",
            record.path.display()
        ));
        return Outcome::new(Kind::Failed, "書いた記録を書けない")
            .note(format!("{} ({e})", record.path.display()));
    }
    let mut outcome = if imports.is_empty() {
        ctx.say("取り込むものはありません (衝突している値がありません)。");
        Outcome::new(Kind::Ok, "取り込むものは無い (衝突している値が無い)")
    } else {
        ctx.say(format!("==> Windows の値を {MANAGED_REL} へ取り込みました"));
        for e in &imports {
            ctx.say(format!("  {}", e.name));
        }
        ctx.say(format!(
            "git -C {} diff -- {MANAGED_REL} で見て commit してください。",
            ctx.repo.display()
        ));
        Outcome::new(
            Kind::Ok,
            format!("{} 件を {MANAGED_REL} へ取り込んだ", imports.len()),
        )
        .note(format!(
            "git -C {} diff -- {MANAGED_REL} で見て commit して push する",
            ctx.repo.display()
        ))
    };
    if !pending.is_empty() {
        ctx.say(format!(
            "managed.json の値で Windows へ書く値が {} 件あります (取り込みでは書きません):",
            pending.len()
        ));
        for p in &pending {
            ctx.say(format!("  {p}"));
        }
        ctx.say("dotfiles apply --steps international で書きます。");
        outcome = outcome.note(format!(
            "managed.json の値で Windows へ書く値が {} 件ある → dotfiles apply --steps international で書く",
            pending.len()
        ));
    }
    outcome
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (WSL の nix/tests/bootstrap-windows-international.test.sh と同じケースに、受け持ち・SSH の会話・runner の行の種類を足したもの)
    //!
    //! - managed.json の誤り (知らない名前・文字列でない値・空・長すぎる値・制御文字・object でない・ファイルが無い) では pwsh を呼ばずに止まる
    //! - pwsh が無い・失敗する・時間切れ・決めた形の JSON を返さないときは何も書かない。pwsh のエラーは平文で出す (CLIXML でも色付きでもない)
    //! - 初めて書くマシン (記録が無く、今の値が地域の既定) では 3 つとも表の順に書き、WM_SETTINGCHANGE を送り、記録する。pwsh には
    //!   -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand で、ASCII だけの本文を渡す
    //! - 揃っていれば読むだけで書かない (記録も変えない)。Windows がもう持つ値なら、書かずに記録だけする
    //! - managed.json を変えたら、衝突でない値を全部表の順に書き直し、変わった値だけを出す
    //! - 記録が無く地域の既定とも違う値・前回書いた値から変わった値・地域の既定に戻った値は衝突として触らず、値と解き方を出す。衝突しない
    //!   値は書く。--force なら書く
    //! - check と dry-run は読むだけで、Windows も記録も変えない
    //! - 取り込みは衝突した値を managed.json へ写し (jq --indent 4 の形)、Windows には書かない。managed.json に commit していない変更があると
    //!   き・git の checkout でないときは止まる
    //! - 書けない値・読み戻すと違う値・書く途中の pwsh の失敗は failed (記録は書けた値だけ)。グループポリシーで止められた値は manual。
    //!   WM_SETTINGCHANGE を送れないときは ※ で知らせる
    //! - 日本語や ' を含む形式も、そのまま届いて読み戻せる
    //! - managed.json から消した値は Windows では戻さず、記録からだけ消す。壊れた記録では止まる。持つ値が無ければ pwsh を呼ばない
    //! - 受け持ちが WSL のホストでは、記録が無いことと衝突の解き方を WSL の側で出す
    //! - SSH の会話の apply は、書く値があれば書かずに manual (同じ値の記録だけする)。dry-run はそう予告する
    //! - WSL の script (bash と jq) を同じ状態から同じ偽の pwsh.exe で流し、同じ本文を渡して同じ値を書き、同じ記録と managed.json を書く。WSL が
    //!   書いた値を、記録の無い runner が書き直さずに引き継ぐ。引き継げない場面 (既定に戻した値・WSL の後に変えた値・WSL に届く前の managed.json の
    //!   更新) も確かめる (bash・jq がある Linux)

    use super::*;
    use crate::context::join_segments;
    use crate::hooks::parity;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, Exit, RunResult};
    use crate::steps::ps1;
    use crate::testutil::{FakeSys, TempDir};
    use std::cell::RefCell;
    use std::path::{Path, PathBuf};
    use std::rc::Rc;

    const RUNNER_HOST: &str = "[runner]\nenable = true\n";
    const WSL_HOST: &str = "group = \"minimum\"\n";
    const APPLY: Mode = Mode::Apply { force: false };
    const FORCE: Mode = Mode::Apply { force: true };
    const DRY: Mode = Mode::DryRun { force: false };

    /// repo の managed.json と同じ 3 つの値 (jq --indent 4 の形)
    const MANAGED3: &str = "{\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"HH:mm\"\n}\n";
    /// 3 つとも書いた後の記録 (jq -S の形)
    const RECORD3: &str = "{\n  \"values\": {\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sShortTime\": \"HH:mm\",\n    \"sTimeFormat\": \"HH:mm:ss\"\n  },\n  \"version\": 1\n}\n";
    /// 読むときに pwsh へ渡す 2 行 (3 つの値を持つとき)
    const READ_HEAD: &str = "$Mode = 'read'\n$InputJson = '[{\"name\":\"sShortDate\",\"lctype\":31},{\"name\":\"sTimeFormat\",\"lctype\":4099},{\"name\":\"sShortTime\",\"lctype\":121}]'\n";

    /// 偽の Windows (WSL の試験の fake_windows と同じ en-US の既定)。値は (名前, 今の値, 地域の既定)
    #[derive(Clone, Debug)]
    struct Win {
        locale: String,
        values: Vec<(String, String, String)>,
        /// 書くと Win32 のエラーで失敗する値
        deny: Vec<(String, i64)>,
        /// 書くと成功を返すが変わらない値
        stuck: Vec<String>,
        broadcast_error: i64,
    }

    impl Win {
        fn en_us() -> Win {
            let v = |n: &str, d: &str| (n.to_string(), d.to_string(), d.to_string());
            Win {
                locale: "en-US".into(),
                values: vec![
                    v("sShortDate", "M/d/yyyy"),
                    v("sTimeFormat", "h:mm:ss tt"),
                    v("sShortTime", "h:mm tt"),
                ],
                deny: Vec::new(),
                stuck: Vec::new(),
                broadcast_error: 0,
            }
        }

        fn current(&self, name: &str) -> String {
            self.values.iter().find(|v| v.0 == name).unwrap().1.clone()
        }

        fn set(&mut self, name: &str, value: &str) {
            self.values.iter_mut().find(|v| v.0 == name).unwrap().1 = value.to_string();
        }
    }

    /// 偽の pwsh (WSL の試験の偽の pwsh.exe と同じ振る舞い: 受けた本文の $Mode と $InputJson を読み、状態から本物と同じ形の JSON を返し、
    /// write なら状態を書き換える)
    struct Pwsh {
        win: Win,
        /// どの呼び出しもこの終わり方と出力で落ちる
        fail: Option<(Exit, Vec<String>)>,
        /// write だけこの終了コードで落ちる
        write_fail: Option<i32>,
        /// 返す行をこれにする
        raw: Option<String>,
        /// 呼ばれた mode・書いた値の名前 (順)・受けた本文
        modes: Vec<String>,
        writes: Vec<String>,
        scripts: Vec<String>,
    }

    impl Pwsh {
        fn respond(&mut self, c: &CommandSpec) -> RunResult {
            let script = ps1::decode_command(c).expect("-EncodedCommand で渡す");
            self.scripts.push(script.clone());
            if let Some((exit, lines)) = &self.fail {
                return RunResult {
                    exit: exit.clone(),
                    output: lines.clone(),
                };
            }
            let field = |prefix: &str| -> String {
                script
                    .lines()
                    .find_map(|l| l.strip_prefix(prefix).and_then(|r| r.strip_suffix('\'')))
                    .unwrap_or_default()
                    .replace("''", "'")
            };
            let mode = field("$Mode = '");
            let input = Jv::parse(&field("$InputJson = '")).expect("$InputJson は JSON");
            self.modes.push(mode.clone());
            if mode == "write"
                && let Some(rc) = self.write_fail
            {
                return RunResult {
                    exit: Exit::Code(rc),
                    output: vec!["write failed".into()],
                };
            }
            if let Some(raw) = &self.raw {
                return RunResult {
                    exit: Exit::Code(0),
                    output: vec![raw.clone()],
                };
            }
            let items = input.as_array().expect("$InputJson は配列").clone();
            let mut failed = Vec::new();
            let mut wrote = 0;
            if mode == "write" {
                for it in &items {
                    if it.get("write") != Some(&Jv::Bool(true)) {
                        continue;
                    }
                    let name = it.get("name").and_then(Jv::as_str).unwrap().to_string();
                    let value = it.get("value").and_then(Jv::as_str).unwrap().to_string();
                    self.writes.push(name.clone());
                    if let Some((_, e)) = self.win.deny.iter().find(|d| d.0 == name) {
                        failed.push(Jv::Object(vec![
                            ("name".into(), Jv::String(name.clone())),
                            ("error".into(), Jv::from(*e)),
                        ]));
                    } else {
                        wrote += 1;
                        if !self.win.stuck.contains(&name) {
                            self.win.set(&name, &value);
                        }
                    }
                }
            }
            let values = items
                .iter()
                .map(|it| {
                    let name = it.get("name").and_then(Jv::as_str).unwrap();
                    let v = self.win.values.iter().find(|v| v.0 == name).unwrap();
                    Jv::Object(vec![
                        ("name".into(), Jv::from(name)),
                        ("current".into(), Jv::String(v.1.clone())),
                        ("default".into(), Jv::String(v.2.clone())),
                    ])
                })
                .collect();
            let broadcast = if mode == "write" && wrote > 0 {
                Jv::Object(vec![
                    ("ok".into(), Jv::Bool(self.win.broadcast_error == 0)),
                    ("error".into(), Jv::from(self.win.broadcast_error)),
                ])
            } else {
                Jv::Null
            };
            let reply = Jv::Object(vec![
                ("locale".into(), Jv::String(self.win.locale.clone())),
                ("values".into(), Jv::Array(values)),
                ("failed".into(), Jv::Array(failed)),
                ("broadcast".into(), broadcast),
            ]);
            RunResult {
                exit: Exit::Code(0),
                output: vec![format!("{}\r", reply.compact())],
            }
        }
    }

    struct Env {
        t: TempDir,
        pwsh: Rc<RefCell<Pwsh>>,
        /// pwsh が PATH にあるか
        has_pwsh: bool,
        /// SSH の会話の中か
        ssh: bool,
        /// git status --porcelain の答え (終了コードと行)
        git: (i32, Vec<String>),
        /// 打たれた git の引数
        git_calls: Rc<RefCell<Vec<String>>>,
    }

    impl Env {
        fn new() -> Env {
            let e = Env {
                t: TempDir::new("international"),
                pwsh: Rc::new(RefCell::new(Pwsh {
                    win: Win::en_us(),
                    fail: None,
                    write_fail: None,
                    raw: None,
                    modes: Vec::new(),
                    writes: Vec::new(),
                    scripts: Vec::new(),
                })),
                has_pwsh: true,
                ssh: false,
                git: (0, Vec::new()),
                git_calls: Rc::new(RefCell::new(Vec::new())),
            };
            e.set_managed(MANAGED3);
            e
        }

        fn repo(&self) -> PathBuf {
            self.t.path().join("repo")
        }

        fn managed(&self) -> PathBuf {
            join_segments(&self.repo(), MANAGED_REL)
        }

        fn set_managed(&self, s: &str) {
            std::fs::create_dir_all(self.managed().parent().unwrap()).unwrap();
            std::fs::write(self.managed(), s).unwrap();
        }

        fn read_managed(&self) -> String {
            std::fs::read_to_string(self.managed()).unwrap()
        }

        fn record(&self) -> PathBuf {
            self.t.path().join("state").join(RECORD_FILE)
        }

        fn read_record(&self) -> Option<String> {
            std::fs::read_to_string(self.record()).ok()
        }

        fn set_record(&self, s: &str) {
            std::fs::create_dir_all(self.record().parent().unwrap()).unwrap();
            std::fs::write(self.record(), s).unwrap();
        }

        fn win(&self, name: &str) -> String {
            self.pwsh.borrow().win.current(name)
        }

        fn set_win(&self, name: &str, value: &str) {
            self.pwsh.borrow_mut().win.set(name, value);
        }

        fn modes(&self) -> Vec<String> {
            self.pwsh.borrow().modes.clone()
        }

        fn writes(&self) -> Vec<String> {
            self.pwsh.borrow().writes.clone()
        }

        fn sys(&self) -> FakeSys {
            let pwsh = Rc::clone(&self.pwsh);
            let git = self.git.clone();
            let git_calls = Rc::clone(&self.git_calls);
            let mut sys = FakeSys::new(move |c| {
                if c.program == Path::new("/fake/pwsh") {
                    pwsh.borrow_mut().respond(c)
                } else if c.program == Path::new("/fake/git") {
                    git_calls.borrow_mut().push(c.args_lossy().join(" "));
                    RunResult {
                        exit: Exit::Code(git.0),
                        output: git.1.clone(),
                    }
                } else {
                    panic!("知らないコマンド: {}", c.program.display())
                }
            })
            .with_program("git", "/fake/git");
            if self.has_pwsh {
                sys = sys.with_program("pwsh", "/fake/pwsh");
            }
            if self.ssh {
                sys = sys.with_env("SSH_CONNECTION", "100.64.0.2 50000 100.64.0.1 22");
            }
            sys
        }

        fn with_ctx<T>(&self, host: &str, f: impl FnOnce(&mut Ctx) -> T) -> (T, String) {
            let sys = self.sys();
            let mut out = Vec::new();
            let r = {
                let mut ctx = Ctx {
                    repo: self.repo(),
                    roots: Roots::from_home(&self.t.path().join("win")),
                    state_dir: self.t.path().join("state"),
                    host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                f(&mut ctx)
            };
            (r, String::from_utf8(out).unwrap())
        }

        /// 手順を流す (行は 1 つ)
        fn run(&self, host: &str, mode: Mode) -> (Outcome, String) {
            let (mut rows, out) = self.with_ctx(host, |ctx| International.run(ctx, mode));
            assert_eq!(rows.len(), 1, "{rows:?}\n{out}");
            (rows.remove(0), out)
        }

        fn import(&self, host: &str) -> (Outcome, String) {
            self.with_ctx(host, import)
        }
    }

    /// 3 つとも managed.json の値か
    fn all_want(e: &Env) -> bool {
        e.win("sShortDate") == "yyyy-MM-dd"
            && e.win("sTimeFormat") == "HH:mm:ss"
            && e.win("sShortTime") == "HH:mm"
    }

    #[test]
    fn first_apply_writes_all_in_table_order_and_records() {
        let e = Env::new();
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(all_want(&e), "{out}");
        assert_eq!(e.modes(), vec!["read", "write"]);
        assert_eq!(e.writes(), vec!["sShortDate", "sTimeFormat", "sShortTime"]);
        assert_eq!(e.read_record().as_deref(), Some(RECORD3));
        assert!(
            out.contains("==> Windows の日付と時刻の形式 (地域 en-US)\n"),
            "{out}"
        );
        assert!(
            out.contains(
                "  sShortDate: \"M/d/yyyy\" → \"yyyy-MM-dd\" (初めて書く。今の値は地域の既定)\n"
            ),
            "{out}"
        );
        assert!(
            out.contains(
                "  sShortTime: \"h:mm tt\" → \"HH:mm\" (初めて書く。今の値は地域の既定)\n"
            ),
            "{out}"
        );
        assert!(out.contains("  WM_SETTINGCHANGE (intl) を送りました。開いているアプリ (タスクバーの時計など) は、その場で読み直します。"), "{out}");
        assert_eq!(
            o.text,
            "持つ値 3 件: 同じ 0 / 初めて書く 3 / 書き換える 0 / 衝突 0 (地域 en-US)"
        );
    }

    /// pwsh には WSL と同じ引数と、ASCII だけの本文 (`$Mode` と `$InputJson` の 2 行 + WSL と同じ本文) を渡す
    #[test]
    fn passes_the_wsl_body_to_pwsh() {
        let e = Env::new();
        e.run(RUNNER_HOST, APPLY);
        let sys_calls = e.pwsh.borrow().scripts.clone();
        assert_eq!(sys_calls.len(), 2);
        assert_eq!(sys_calls[0], format!("{READ_HEAD}{PS_BODY}"));
        assert_eq!(
            sys_calls[1],
            format!(
                "$Mode = 'write'\n$InputJson = '[{{\"name\":\"sShortDate\",\"lctype\":31,\"value\":\"yyyy-MM-dd\",\"write\":true}},{{\"name\":\"sTimeFormat\",\"lctype\":4099,\"value\":\"HH:mm:ss\",\"write\":true}},{{\"name\":\"sShortTime\",\"lctype\":121,\"value\":\"HH:mm\",\"write\":true}}]'\n{PS_BODY}"
            )
        );
        // 引数は WSL と同じ (pwsh に聞く前に、どの呼び出しも同じ形)
        let sys = e.sys();
        let mut out = Vec::new();
        let mut ctx = Ctx {
            repo: e.repo(),
            roots: Roots::from_home(&e.t.path().join("win")),
            state_dir: e.t.path().join("state"),
            host: parse(
                RUNNER_HOST,
                Path::new("h.toml"),
                Groups::embedded().unwrap(),
            )
            .unwrap(),
            sys: &sys,
            out: &mut out,
        };
        International.run(&mut ctx, Mode::Check);
        let calls = sys.calls.borrow();
        let args = calls[0].args_lossy();
        assert_eq!(
            args[..5],
            [
                "-NoProfile",
                "-NonInteractive",
                "-OutputFormat",
                "Text",
                "-EncodedCommand"
            ]
        );
        assert_eq!(args.len(), 6);
        assert!(calls[0].stdout_only, "stderr は返りの JSON に混ぜない");
        assert_eq!(calls[0].timeout, Some(std::time::Duration::from_secs(60)));
    }

    #[test]
    fn second_apply_reads_only_and_keeps_the_record() {
        let e = Env::new();
        e.run(RUNNER_HOST, APPLY);
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.modes(), vec!["read", "write", "read"]);
        assert_eq!(e.read_record().as_deref(), Some(RECORD3));
        assert!(
            out.contains("Windows の日付と時刻の形式は揃っています (持つ値 3 件。地域 en-US)。"),
            "{out}"
        );
    }

    /// 記録が無く、Windows がもう持つ値 (WSL の setup が書いた PC を、受け持ちを切り替えた後に初めて流す形): 書かずに記録だけ
    #[test]
    fn values_already_set_are_recorded_without_writing() {
        let e = Env::new();
        for (n, v) in [
            ("sShortDate", "yyyy-MM-dd"),
            ("sTimeFormat", "HH:mm:ss"),
            ("sShortTime", "HH:mm"),
        ] {
            e.set_win(n, v);
        }
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.modes(), vec!["read"]);
        assert_eq!(e.read_record().as_deref(), Some(RECORD3));
        assert!(out.contains("揃っています"), "{out}");
    }

    #[test]
    fn managed_update_rewrites_all_and_shows_only_the_changed_value() {
        let e = Env::new();
        e.run(RUNNER_HOST, APPLY);
        e.set_managed("{\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"H:mm\"\n}\n");
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.win("sShortTime"), "H:mm");
        assert_eq!(
            e.writes(),
            [
                "sShortDate",
                "sTimeFormat",
                "sShortTime",
                "sShortDate",
                "sTimeFormat",
                "sShortTime"
            ]
        );
        assert!(
            out.contains("  sShortTime: \"HH:mm\" → \"H:mm\" (managed.json が更新された)\n"),
            "{out}"
        );
        assert!(!out.contains("  sShortDate:"), "{out}");
        assert!(
            e.read_record()
                .unwrap()
                .contains("\"sShortTime\": \"H:mm\"")
        );
        assert_eq!(
            o.text,
            "持つ値 3 件: 同じ 2 / 初めて書く 0 / 書き換える 1 / 衝突 0 (地域 en-US)"
        );
    }

    /// 記録が無く、地域の既定とも違う値は衝突。ほかの値は書く。--force なら書く
    #[test]
    fn unrecorded_value_off_the_default_is_a_conflict() {
        let e = Env::new();
        e.set_win("sShortDate", "yyyy/MM/dd");
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert_eq!(e.win("sShortDate"), "yyyy/MM/dd");
        assert_eq!(e.win("sTimeFormat"), "HH:mm:ss");
        assert_eq!(e.writes(), ["sTimeFormat", "sShortTime"]);
        let rec = e.read_record().unwrap();
        assert!(!rec.contains("sShortDate"), "{rec}");
        assert!(rec.contains("\"sShortTime\": \"HH:mm\""), "{rec}");
        assert!(out.contains("!! 衝突: sShortDate は、書いた記録が無く、地域 (en-US) の既定とも違います (設定画面で変えた・手で設定してあった、など)。\n"), "{out}");
        assert!(out.contains("   Windows 側:    \"yyyy/MM/dd\"\n"), "{out}");
        assert!(out.contains("   managed.json:  \"yyyy-MM-dd\"\n"), "{out}");
        assert!(out.contains("   地域の既定:    \"M/d/yyyy\"\n"), "{out}");
        assert!(!out.contains("前回書いた値:"), "{out}");
        assert!(out.contains("!! Windows 側で変わっていた (か、書く前から手で設定してあった) ので、次の値には触っていません (値は上): sShortDate\n"), "{out}");
        assert!(
            out.contains(
                "(managed.json へ取り込み、commit して push する): dotfiles import international\n"
            ),
            "{out}"
        );
        assert!(
            out.contains(
                "managed.json の値で書くなら: dotfiles apply --steps international --force\n"
            ),
            "{out}"
        );
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("dotfiles import international")),
            "{o:?}"
        );

        let (o, out) = e.run(RUNNER_HOST, FORCE);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(all_want(&e));
        assert!(
            out.contains("  sShortDate: \"yyyy/MM/dd\" → \"yyyy-MM-dd\" (--force)\n"),
            "{out}"
        );
        assert_eq!(e.read_record().as_deref(), Some(RECORD3));
    }

    #[test]
    fn changed_after_writing_is_a_conflict() {
        let e = Env::new();
        e.run(RUNNER_HOST, APPLY);
        e.set_win("sShortDate", "yyyy/MM/dd");
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert_eq!(e.win("sShortDate"), "yyyy/MM/dd");
        assert!(out.contains("!! 衝突: sShortDate は Windows 側で変わっています (前回書いた値と違う。設定画面で変えた、など)。\n"), "{out}");
        assert!(out.contains("   前回書いた値:  \"yyyy-MM-dd\"\n"), "{out}");
        // 衝突しない 2 つは同じ値なので、書き直さない (書く値が無ければ pwsh の write は呼ばない)
        assert_eq!(e.modes(), vec!["read", "write", "read"]);
    }

    /// 地域を変えた (今の値が新しい地域の既定に戻った): 黙って書かずに衝突
    #[test]
    fn back_to_the_region_default_is_a_conflict() {
        let e = Env::new();
        e.run(RUNNER_HOST, APPLY);
        {
            let mut p = e.pwsh.borrow_mut();
            p.win.locale = "ja-JP".into();
            p.win.values = vec![
                (
                    "sShortDate".into(),
                    "yyyy/MM/dd".into(),
                    "yyyy/MM/dd".into(),
                ),
                ("sTimeFormat".into(), "H:mm:ss".into(), "H:mm:ss".into()),
                ("sShortTime".into(), "H:mm".into(), "H:mm".into()),
            ];
        }
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert_eq!(e.win("sShortDate"), "yyyy/MM/dd");
        assert_eq!(e.modes(), vec!["read", "write", "read"]);
        assert!(out.contains("!! 衝突: sShortDate は、前回書いた値から地域 (ja-JP) の既定に戻っています (地域を変えた・設定画面で既定に戻した、など)。\n"), "{out}");
        assert_eq!(
            o.text,
            "持つ値 3 件: 同じ 0 / 初めて書く 0 / 書き換える 0 / 衝突 3 (地域 ja-JP)"
        );
    }

    /// check と dry-run は読むだけ (Windows も記録も変えない。WM_SETTINGCHANGE も送らない)。行の種類は apply ですること
    #[test]
    fn check_and_dry_run_write_nothing() {
        let e = Env::new();
        let (o, out) = e.run(RUNNER_HOST, DRY);
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(
            out.contains("==> [dry-run] Windows の日付と時刻の形式 (地域 en-US)\n"),
            "{out}"
        );
        assert!(out.contains("  [dry-run] sShortDate: \"M/d/yyyy\" → \"yyyy-MM-dd\" (初めて書く。今の値は地域の既定)\n"), "{out}");
        assert!(!out.contains("WM_SETTINGCHANGE"), "{out}");
        assert!(!out.contains("SSH の会話"), "{out}");
        assert!(o.text.starts_with("[dry-run] 持つ値 3 件: "), "{}", o.text);
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(out.contains("  sShortDate: \"M/d/yyyy\" → \"yyyy-MM-dd\" (初めて書く。今の値は地域の既定。apply で書く)\n"), "{out}");
        assert_eq!(e.modes(), vec!["read", "read"]);
        assert_eq!(e.win("sShortDate"), "M/d/yyyy");
        assert!(e.read_record().is_none());

        // managed.json の更新は fix、衝突は manual (dry-run の --force は書き換えると予告する)
        e.run(RUNNER_HOST, APPLY);
        e.set_managed("{\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"H:mm\"\n}\n");
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(out.contains("  sShortTime: \"HH:mm\" → \"H:mm\" (managed.json が更新された。apply で書き換える)\n"), "{out}");
        e.set_win("sShortDate", "yyyy/MM/dd");
        let (o, _) = e.run(RUNNER_HOST, DRY);
        assert_eq!(o.kind, Kind::Manual);
        let (o, out) = e.run(RUNNER_HOST, Mode::DryRun { force: true });
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(
            out.contains("  [dry-run] sShortDate: \"yyyy/MM/dd\" → \"yyyy-MM-dd\" (--force)\n"),
            "{out}"
        );
        assert_eq!(e.win("sShortDate"), "yyyy/MM/dd");
        assert_eq!(e.win("sShortTime"), "HH:mm");
        assert_eq!(e.read_record().as_deref(), Some(RECORD3));
    }

    /// 受け持ちが WSL のホストの check: runner の記録が無いことと、衝突を解くのは WSL の側だと出す
    #[test]
    fn wsl_host_check_points_to_the_wsl_side() {
        let e = Env::new();
        for (n, v) in [
            ("sShortDate", "yyyy-MM-dd"),
            ("sTimeFormat", "HH:mm:ss"),
            ("sShortTime", "HH:mm"),
        ] {
            e.set_win(n, v);
        }
        let (o, out) = e.run(WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(out.contains("runner の記録はまだありません (3 件。受け持ちを runner に切り替えた後の apply で、今の値を見て記録だけ作ります。WSL の setup の記録は WSL の ~/.local/state/dotfiles/windows-international.applied.json)。"), "{out}");
        let (_, out) = e.run(RUNNER_HOST, Mode::Check);
        assert!(
            out.contains(
                "書いた記録がまだ無い値が 3 件あります (apply で、今の値を見て記録だけ作ります)。"
            ),
            "{out}"
        );

        e.set_win("sShortDate", "yyyy/MM/dd");
        let (o, out) = e.run(WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(out.contains("受け持ちを切り替える前なら、WSL が書いた値とこの dotfiles の clone の managed.json が違うか、WSL が書いた後に設定画面で変えた"), "{out}");
        assert!(out.contains("WSL で nix/scripts/bootstrap-windows-international.sh --import (受け持ちが WSL の setup の間。runner の取り込みは止まる)"), "{out}");
        assert!(out.contains("WSL で nix/scripts/bootstrap-windows-international.sh --force (受け持ちが WSL の setup の間。runner の apply は international を流さない)"), "{out}");
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("bootstrap-windows-international.sh の --import か --force")),
            "{o:?}"
        );
        assert!(e.read_record().is_none());
    }

    #[test]
    fn import_copies_conflicting_values_into_managed() {
        let e = Env::new();
        e.set_win("sShortDate", "yyyy/MM/dd");
        let (o, out) = e.import(RUNNER_HOST);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(
            e.read_managed(),
            "{\n    \"sShortDate\": \"yyyy/MM/dd\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"HH:mm\"\n}\n"
        );
        assert_eq!(
            e.read_record().as_deref(),
            Some(
                "{\n  \"values\": {\n    \"sShortDate\": \"yyyy/MM/dd\"\n  },\n  \"version\": 1\n}\n"
            )
        );
        assert_eq!(e.modes(), vec!["read"]);
        assert_eq!(e.win("sShortTime"), "h:mm tt");
        assert!(
            out.contains(
                "==> Windows の値を win/international/managed.json へ取り込みました\n  sShortDate\n"
            ),
            "{out}"
        );
        assert!(out.contains("managed.json の値で Windows へ書く値が 2 件あります (取り込みでは書きません):\n  sTimeFormat\n  sShortTime\n"), "{out}");
        assert!(
            out.contains("dotfiles apply --steps international で書きます。"),
            "{out}"
        );
        assert_eq!(
            e.git_calls.borrow()[0],
            format!(
                "--no-optional-locks -C {} status --porcelain --untracked-files=normal -- win/international/managed.json",
                e.repo().display()
            )
        );
    }

    #[test]
    fn import_without_conflicts_takes_nothing() {
        let e = Env::new();
        let (o, out) = e.import(RUNNER_HOST);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.read_managed(), MANAGED3);
        assert!(
            out.contains("取り込むものはありません (衝突している値がありません)。"),
            "{out}"
        );
        assert!(
            out.contains("managed.json の値で Windows へ書く値が 3 件あります"),
            "{out}"
        );
        assert!(e.read_record().is_none());
    }

    /// managed.json に commit していない変更があるとき・git の checkout でないときは、pwsh に聞かずに止まる
    #[test]
    fn import_stops_on_uncommitted_managed() {
        let mut e = Env::new();
        e.set_win("sShortDate", "yyyy/MM/dd");
        e.git = (0, vec![" M win/international/managed.json".into()]);
        let (o, out) = e.import(RUNNER_HOST);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("commit していない変更があります"), "{out}");
        assert_eq!(e.read_managed(), MANAGED3);
        assert!(e.modes().is_empty());
        assert!(e.read_record().is_none());
        e.git = (128, vec!["fatal: not a git repository".into()]);
        let (o, out) = e.import(RUNNER_HOST);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("commit していない変更が無いかを確かめられません"),
            "{out}"
        );
        assert_eq!(e.read_managed(), MANAGED3);
    }

    #[test]
    fn crash_while_writing_records_nothing_written() {
        let e = Env::new();
        e.pwsh.borrow_mut().write_fail = Some(1);
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("!! 書く途中で pwsh が失敗しました (終了コード 1)。どの値が書けたかは分からないので、記録していません:\n   write failed\n   もう一度流すと、読み直して判定します。\n"), "{out}");
        assert!(out.contains("  sShortDate: \"M/d/yyyy\" → \"yyyy-MM-dd\" (初めて書く。今の値は地域の既定) … 書けたか分かりません\n"), "{out}");
        assert!(!out.contains("次の値は書けませんでした"), "{out}");
        assert!(e.read_record().is_none());
    }

    #[test]
    fn unwritable_value_fails_and_the_rest_is_recorded() {
        let e = Env::new();
        e.pwsh.borrow_mut().win.deny = vec![("sShortTime".into(), 87)];
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert_eq!(e.win("sShortTime"), "h:mm tt");
        let rec = e.read_record().unwrap();
        assert!(!rec.contains("sShortTime"), "{rec}");
        assert!(rec.contains("\"sShortDate\": \"yyyy-MM-dd\""), "{rec}");
        assert!(out.contains("!! 次の値は書けませんでした (書けた値は記録してあります):\n   sShortTime: 書けませんでした (Win32 のエラー 87)\n"), "{out}");
        assert!(out.contains("  sShortTime: \"h:mm tt\" → \"HH:mm\" (初めて書く。今の値は地域の既定) … 書けませんでした\n"), "{out}");
        assert!(
            out.contains(
                "  sShortDate: \"M/d/yyyy\" → \"yyyy-MM-dd\" (初めて書く。今の値は地域の既定)\n"
            ),
            "{out}"
        );
        assert!(o.text.contains(" / 書けない 1"), "{}", o.text);
    }

    /// グループポリシーで止められた値 (1260) は、流し直しても書けないので manual (ほかの値は書いて記録する)
    #[test]
    fn group_policy_value_is_manual() {
        let e = Env::new();
        e.pwsh.borrow_mut().win.deny = vec![("sShortTime".into(), 1260)];
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(out.contains("!! 次の値は、この PC ではグループポリシーで止められていて書けません (Win32 のエラー 1260): sShortTime\n"), "{out}");
        assert!(out.contains("  sShortTime: \"h:mm tt\" → \"HH:mm\" (初めて書く。今の値は地域の既定) … グループポリシーで止められていて書けません\n"), "{out}");
        assert!(!out.contains("次の値は書けませんでした"), "{out}");
        let rec = e.read_record().unwrap();
        assert!(
            !rec.contains("sShortTime") && rec.contains("sTimeFormat"),
            "{rec}"
        );
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("managed.json からその値を消す")),
            "{o:?}"
        );
    }

    #[test]
    fn value_that_does_not_stick_fails() {
        let e = Env::new();
        e.pwsh.borrow_mut().win.stuck = vec!["sShortDate".into()];
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("   sShortDate: 書いた後に読み戻すと \"M/d/yyyy\" で、managed.json の \"yyyy-MM-dd\" と違います\n"), "{out}");
        assert!(out.contains("  sShortDate: \"M/d/yyyy\" → \"yyyy-MM-dd\" (初めて書く。今の値は地域の既定) … 書けませんでした\n"), "{out}");
        let rec = e.read_record().unwrap();
        assert!(
            !rec.contains("sShortDate") && rec.contains("sShortTime"),
            "{rec}"
        );
    }

    /// WM_SETTINGCHANGE を送れなくても値は書けている: ✔ のまま ※ で知らせる
    #[test]
    fn broadcast_failure_is_noted() {
        let e = Env::new();
        e.pwsh.borrow_mut().win.broadcast_error = 1460;
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(all_want(&e));
        assert_eq!(e.read_record().as_deref(), Some(RECORD3));
        assert!(out.contains("!! WM_SETTINGCHANGE を送れませんでした (Win32 のエラー 1460)。値は書けています。\n   開いているアプリ (タスクバーの時計など) には、サインアウトしてサインインし直すと効きます。\n"), "{out}");
        assert!(!out.contains("を送りました"), "{out}");
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("サインアウトしてサインインし直す")),
            "{o:?}"
        );
    }

    /// 日本語や ' を含む形式も、ASCII だけの本文で届いて読み戻せる (jq の -a と同じ \uXXXX、' は '' に)
    #[test]
    fn non_ascii_and_quotes_reach_pwsh_as_ascii() {
        let e = Env::new();
        e.set_managed("{\n    \"sShortDate\": \"yyyy'年'M'月'd'日'\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"HH'h'mm 😀\"\n}\n");
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.win("sShortDate"), "yyyy'年'M'月'd'日'");
        assert_eq!(e.win("sShortTime"), "HH'h'mm 😀");
        let scripts = e.pwsh.borrow().scripts.clone();
        assert!(scripts.iter().all(|s| s.is_ascii()));
        assert!(scripts[1].starts_with("$Mode = 'write'\n$InputJson = '[{\"name\":\"sShortDate\",\"lctype\":31,\"value\":\"yyyy''\\u5e74''M''\\u6708''d''\\u65e5''\",\"write\":true},{\"name\":\"sTimeFormat\",\"lctype\":4099,\"value\":\"HH:mm:ss\",\"write\":true},{\"name\":\"sShortTime\",\"lctype\":121,\"value\":\"HH''h''mm \\ud83d\\ude00\",\"write\":true}]'\n"), "{}", scripts[1]);
        assert!(
            e.read_record()
                .unwrap()
                .contains("\"sShortDate\": \"yyyy'年'M'月'd'日'\"")
        );
    }

    #[test]
    fn removed_value_is_dropped_from_the_record_only() {
        let e = Env::new();
        e.run(RUNNER_HOST, APPLY);
        e.set_managed("{\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sShortTime\": \"HH:mm\"\n}\n");
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.win("sTimeFormat"), "HH:mm:ss");
        assert_eq!(
            e.read_record().as_deref(),
            Some(
                "{\n  \"values\": {\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sShortTime\": \"HH:mm\"\n  },\n  \"version\": 1\n}\n"
            )
        );
        // 読む値も持つ値だけ
        let scripts = e.pwsh.borrow().scripts.clone();
        assert!(scripts.last().unwrap().starts_with("$Mode = 'read'\n$InputJson = '[{\"name\":\"sShortDate\",\"lctype\":31},{\"name\":\"sShortTime\",\"lctype\":121}]'\n"));
    }

    /// 書く値も同じ値も無く記録が空のままなら、記録のファイルを作らない (WSL と同じ)。知らないキーは記録に残す
    #[test]
    fn record_is_not_created_empty_and_keeps_unknown_keys() {
        let e = Env::new();
        for n in ["sShortDate", "sTimeFormat", "sShortTime"] {
            e.set_win(n, "x");
        }
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(e.read_record().is_none());
        assert_eq!(e.modes(), vec!["read"]);

        let e = Env::new();
        e.set_record("{\"note\":\"x\",\"values\":{},\"version\":7}");
        e.run(RUNNER_HOST, APPLY);
        assert_eq!(
            e.read_record().as_deref(),
            Some(
                "{\n  \"note\": \"x\",\n  \"values\": {\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sShortTime\": \"HH:mm\",\n    \"sTimeFormat\": \"HH:mm:ss\"\n  },\n  \"version\": 1\n}\n"
            )
        );
    }

    #[test]
    fn broken_record_stops_before_pwsh() {
        let e = Env::new();
        e.set_record("[]");
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("が壊れています (values を持つ JSON の object ではありません)。"),
            "{out}"
        );
        assert!(e.modes().is_empty());
        assert_eq!(e.win("sShortDate"), "M/d/yyyy");
        assert_eq!(e.read_record().as_deref(), Some("[]"));
    }

    /// 持つ値が無ければ pwsh を呼ばない (pwsh が無くても止まらない)
    #[test]
    fn no_values_skip_pwsh() {
        let mut e = Env::new();
        e.has_pwsh = false;
        e.set_managed("{}\n");
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains("Windows の日付と時刻の形式は揃っています (持つ値 0 件)。"),
            "{out}"
        );
        assert!(e.modes().is_empty());
        assert!(e.read_record().is_none());
    }

    /// managed.json の誤りでは pwsh を呼ばずに止まる (WSL の validate_managed と同じ決まりと文)
    #[test]
    fn bad_managed_stops_before_pwsh() {
        let long = format!("{{\"sShortDate\": \"{}\"}}", "y".repeat(80));
        let cases: &[(&str, Option<&str>, &str)] = &[
            (
                "unknown",
                Some("{\"sShortDate\": \"yyyy-MM-dd\", \"sLongDate\": \"dddd, MMMM d, yyyy\"}"),
                "   知らない名前です: sLongDate (持てるのは sShortDate・sTimeFormat・sShortTime)",
            ),
            (
                "number",
                Some("{\"sShortDate\": 1}"),
                "   sShortDate の値が文字列ではありません: 1",
            ),
            (
                "empty",
                Some("{\"sShortDate\": \"\"}"),
                "   sShortDate の値が空です。",
            ),
            (
                "long",
                Some(&long),
                "   sShortDate の値が長すぎます (80 字。79 字まで)。",
            ),
            (
                "control",
                Some("{\"sShortTime\": \"HH:\\tmm\"}"),
                "   sShortTime の値に制御文字があります: \"HH:\\tmm\"",
            ),
            (
                "del",
                Some("{\"sShortTime\": \"HH:\u{7f}mm\"}"),
                "   sShortTime の値に制御文字があります: \"HH:\\u007fmm\"",
            ),
            (
                "array",
                Some("[]"),
                "!! win/international/managed.json が JSON の object ではありません。",
            ),
            (
                "missing",
                None,
                "!! win/international/managed.json がありません (",
            ),
        ];
        for (label, text, want) in cases {
            let e = Env::new();
            match text {
                Some(t) => e.set_managed(t),
                None => std::fs::remove_file(e.managed()).unwrap(),
            }
            let (o, out) = e.run(RUNNER_HOST, APPLY);
            assert_eq!(o.kind, Kind::Failed, "{label}: {out}");
            assert!(out.contains(want), "{label}: {out}");
            assert!(e.modes().is_empty(), "{label}");
        }
        // 長さは字の数で数える (79 字の日本語は通る)
        let e = Env::new();
        e.set_managed(&format!("{{\"sShortDate\": \"{}\"}}", "年".repeat(79)));
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{out}");
    }

    #[test]
    fn missing_pwsh_is_manual() {
        let mut e = Env::new();
        e.has_pwsh = false;
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains(
                "!! pwsh が見つかりません (PowerShell 7 が無いか、PATH に入っていない)。\n"
            ),
            "{out}"
        );
        // 入れ方は bootstrap に任せる (普段のアカウントが管理者でない PC は MSI。素の winget install は 7.7 の MSIX を入れる)
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("win/bootstrap/Install-Bootstrap.ps1")
                    && n.contains("管理者でない PC は MSI")),
            "{o:?}"
        );
        assert!(e.read_record().is_none());
    }

    /// pwsh が落ちる・時間切れ・決めた形の JSON を返さないときは failed で、何も書かない。エラーは平文 (CLIXML も色も落とす) で出す
    #[test]
    fn pwsh_failures_are_failed_in_plain_text() {
        let e = Env::new();
        e.pwsh.borrow_mut().fail = Some((
            Exit::Code(1),
            vec![
                "#< CLIXML".into(),
                "<Objs Version=\"1.1.0.1\" xmlns=\"http://schemas.microsoft.com/powershell/2004/04\"><S S=\"Error\">Add-Type: boom_x000D__x000A_</S></Objs>".into(),
                "\u{1b}[31;1mColored: bang\u{1b}[0m".into(),
            ],
        ));
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("!! pwsh で Windows の日付と時刻の形式を読めませんでした (終了コード 1):\n   Add-Type: boom\n   Colored: bang\n   この手順は飛ばします。\n"), "{out}");
        assert!(!out.contains("CLIXML") && !out.contains('\u{1b}'), "{out}");
        assert!(e.read_record().is_none());

        e.pwsh.borrow_mut().fail = Some((Exit::TimedOut, Vec::new()));
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("!! pwsh が 60 秒たっても終わりませんでした (時間切れ)。"),
            "{out}"
        );

        e.pwsh.borrow_mut().fail = None;
        e.pwsh.borrow_mut().raw = Some("oops".into());
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("!! pwsh の返りが、決めた形の JSON ではありません:\n   oops\n"),
            "{out}"
        );
        assert_eq!(e.win("sShortDate"), "M/d/yyyy");
        assert!(e.read_record().is_none());
    }

    /// 返りの JSON の形の確かめ (WSL の jq の式と同じ): 頼んだ名前の全部に、文字列の今の値と地域の既定があり、地域の名前を持つ
    #[test]
    fn reply_shape_is_checked() {
        let good = "{\"locale\":\"en-US\",\"values\":[{\"name\":\"sShortDate\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sTimeFormat\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sShortTime\",\"current\":\"a\",\"default\":\"b\"}],\"failed\":[],\"broadcast\":null}";
        let bad = [
            // 1 つ足りない
            "{\"locale\":\"en-US\",\"values\":[{\"name\":\"sShortDate\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sTimeFormat\",\"current\":\"a\",\"default\":\"b\"}]}",
            // 地域の名前が無い
            "{\"values\":[{\"name\":\"sShortDate\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sTimeFormat\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sShortTime\",\"current\":\"a\",\"default\":\"b\"}]}",
            // 今の値が文字列でない
            "{\"locale\":\"en-US\",\"values\":[{\"name\":\"sShortDate\",\"current\":1,\"default\":\"b\"},{\"name\":\"sTimeFormat\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sShortTime\",\"current\":\"a\",\"default\":\"b\"}]}",
            // object でない要素 (jq の .name が落ちる)
            "{\"locale\":\"en-US\",\"values\":[1,{\"name\":\"sShortDate\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sTimeFormat\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sShortTime\",\"current\":\"a\",\"default\":\"b\"}]}",
            // 同じ名前が 2 つ
            "{\"locale\":\"en-US\",\"values\":[{\"name\":\"sShortDate\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sShortDate\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sTimeFormat\",\"current\":\"a\",\"default\":\"b\"},{\"name\":\"sShortTime\",\"current\":\"a\",\"default\":\"b\"}]}",
            "[]",
        ];
        let e = Env::new();
        e.pwsh.borrow_mut().raw = Some(good.into());
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "形は通り、3 つとも衝突と読む: {out}");
        for b in bad {
            e.pwsh.borrow_mut().raw = Some(b.into());
            let (o, out) = e.run(RUNNER_HOST, Mode::Check);
            assert_eq!(o.kind, Kind::Failed, "{b}: {out}");
        }
        // null の要素は jq と同じく飛ばす
        e.pwsh.borrow_mut().raw = Some(good.replacen("[{", "[null,{", 1));
        let (o, _) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual);
    }

    /// SSH の会話の apply は、書く値があれば書かずに manual (WM_SETTINGCHANGE がデスクトップの会話のアプリに届かない)。書く値が無ければ記録だけする
    #[test]
    fn ssh_session_does_not_write() {
        let mut e = Env::new();
        e.ssh = true;
        // 同じ値 (sShortDate) と書く値 (ほかの 2 つ) が混ざる。dry-run は本番の apply が書かないことを予告する
        e.set_win("sShortDate", "yyyy-MM-dd");
        let (o, out) = e.run(RUNNER_HOST, DRY);
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(
            out.contains("※ SSH の会話の中なので、本番の apply は日付と時刻の形式を書きません"),
            "{out}"
        );
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("本番の apply は書かない")),
            "{o:?}"
        );
        // apply は書かず (pwsh は読むだけ)、同じ値の記録だけを作る
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert_eq!(e.modes(), vec!["read", "read"]);
        assert_eq!(e.win("sTimeFormat"), "h:mm:ss tt");
        assert!(
            out.contains("SSH の会話の中なので、日付と時刻の形式は書きません"),
            "{out}"
        );
        assert!(out.contains("  sTimeFormat: \"h:mm:ss tt\" → \"HH:mm:ss\" (初めて書く。今の値は地域の既定) … SSH の会話の中なので書いていません\n"), "{out}");
        assert!(
            o.notes.iter().any(|n| n.contains(
                "PC のデスクトップの PowerShell で dotfiles apply --steps international を流す"
            )),
            "{o:?}"
        );
        assert_eq!(
            e.read_record().as_deref(),
            Some(
                "{\n  \"values\": {\n    \"sShortDate\": \"yyyy-MM-dd\"\n  },\n  \"version\": 1\n}\n"
            )
        );

        // 書く値が無ければ、いつもの apply と同じ (記録だけ作る)。check は SSH の会話でも読むだけ
        for (n, v) in [("sTimeFormat", "HH:mm:ss"), ("sShortTime", "HH:mm")] {
            e.set_win(n, v);
        }
        let (o, out) = e.run(RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.read_record().as_deref(), Some(RECORD3));
        let (o, _) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok);
    }

    /// PowerShell の本文・表・記録と持つ値の名前・長さの上限・pwsh の引数と秒数が WSL の script と同じ (bash の版が流れない Windows の CI でも比べる)
    #[test]
    fn matches_the_wsl_script_text() {
        let text = std::fs::read_to_string(parity::repo_file(
            "nix/scripts/bootstrap-windows-international.sh",
        ))
        .unwrap()
        .replace("\r\n", "\n");
        let info = International.info();
        assert!(
            text.lines()
                .any(|l| l == format!("# order: {}", info.order))
        );
        assert!(!text.lines().any(|l| l.starts_with("# tool: ")));
        assert!(
            text.contains(&format!(
                "IFS= read -r -d '' ps_body <<'EOS' || true\n{PS_BODY}EOS\n"
            )),
            "WSL の script の本文と違う"
        );
        let rows: Vec<String> = TABLE
            .iter()
            .map(|(n, t)| format!("  {{\"name\": \"{n}\", \"lctype\": {t}}}"))
            .collect();
        assert!(
            text.contains(&format!("table='[\n{}\n]'\n", rows.join(",\n"))),
            "WSL の script の table と違う"
        );
        assert!(text.contains(&format!("managed_rel=\"{MANAGED_REL}\"\n")));
        assert!(text.contains(&format!("record_file=\"${{state_dir}}/{RECORD_FILE}\"\n")));
        assert!(text.contains(&format!("max_len={MAX_LEN}\n")));
        assert!(text.contains(&format!("ps_out=$(timeout {PS_SECS} pwsh.exe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand \"${{enc}}\" </dev/null 2>\"${{ps_err_file}}\")")));
        assert!(text.contains("input=$(jq -c -a . <<<\"$2\")\n"));
        assert!(text.contains("quoted=${input//\\'/\\'\\'}\n"));
        assert!(text.contains("if ! enc=$(encode_ps \"\\$Mode = '$1'\"$'\\n'\"\\$InputJson = '${quoted}'\"$'\\n'\"${ps_body}\"); then\n"));
        assert!(text.contains("if [[ ${err} == 1260 ]]; then\n"));
        // repo の managed.json は WSL の --check を通る形 (表の名前だけ)
        let managed = std::fs::read_to_string(parity::repo_file(MANAGED_REL))
            .unwrap()
            .replace("\r\n", "\n");
        let doc = Jv::parse(&managed).unwrap();
        for (k, _) in doc.as_object().unwrap() {
            assert!(TABLE.iter().any(|(n, _)| n == k), "{k}");
        }
    }

    /// 本物の pwsh が、本文を -EncodedCommand で受けて今の値・地域の既定・地域の名前を返す (Windows だけ。読むだけで、日付と時刻の形式は
    /// 書かない)。読めない LCType のエラーは、人に見せる行で平文になる。pwsh が PATH に無ければ飛ばす
    #[cfg(windows)]
    #[test]
    fn real_pwsh_reads_the_formats() {
        use crate::process::{RealSys, Sys};
        let Some(pwsh) = RealSys.which("pwsh") else {
            return;
        };
        let mut out = Vec::new();
        let (read, bad) = {
            let mut ctx = Ctx {
                repo: "C:/r".into(),
                roots: Roots::from_home(Path::new("C:/h")),
                state_dir: "C:/s".into(),
                host: parse(
                    RUNNER_HOST,
                    Path::new("h.toml"),
                    Groups::embedded().unwrap(),
                )
                .unwrap(),
                sys: &crate::testutil::RealSysPlain,
                out: &mut out,
            };
            let read = read_windows(&mut ctx, &pwsh, &Jv::parse(MANAGED3).unwrap());
            let bad = run_ps(
                &ctx,
                &pwsh,
                "read",
                &Jv::parse(r#"[{"name":"sShortDate","lctype":32767}]"#).unwrap(),
            );
            (read, bad)
        };
        let out = String::from_utf8_lossy(&out).into_owned();
        let Ok(w) = read else {
            panic!("読めなかった:\n{out}");
        };
        assert!(!w.locale.is_empty());
        let mut names: Vec<&str> = w.values.iter().map(|v| v.0.as_str()).collect();
        names.sort_unstable();
        assert_eq!(names, ["sShortDate", "sShortTime", "sTimeFormat"]);
        assert!(
            w.values.iter().all(|v| !v.1.is_empty() && !v.2.is_empty()),
            "{:?}",
            w.values
        );

        assert_ne!(bad.exit, Exit::Code(0));
        let text = bad.shown.join("\n");
        // PowerShell 7 のエラーの表示 (ConciseView) は、窓の幅で折り返して頭に `|` を付けうるので、空白と `|` を除いて探す
        let flat: String = text
            .chars()
            .filter(|c| !c.is_whitespace() && *c != '|')
            .collect();
        assert!(
            flat.contains("GetLocaleInfoEx(0x7FFF)failed:Win32error"),
            "{text}"
        );
        assert!(
            !text.contains("CLIXML") && !text.contains("<Objs"),
            "{text}"
        );
    }

    // ---- WSL の script との突き合わせ (bash と jq がある Linux。CI の Linux の job は飛ばさない) ----

    /// 偽の pwsh.exe: WSL の試験 (nix/tests/bootstrap-windows-international.test.sh) の make_fake_pwsh の本体に、受けた本文を pwsh-codes に残す
    /// 1 行を足したもの。写しを持たず毎回抜き出すので、WSL の試験の偽物とずれない。WSL の script と runner の両方がこれを呼ぶ
    #[cfg(unix)]
    fn fake_pwsh() -> String {
        let text = std::fs::read_to_string(parity::repo_file(
            "nix/tests/bootstrap-windows-international.test.sh",
        ))
        .unwrap()
        .replace("\r\n", "\n");
        let func = text
            .find("\nmake_fake_pwsh() {\n")
            .expect("WSL の試験に make_fake_pwsh が無い");
        let open = "    cat <<'EOF'\n";
        let start = func
            + text[func..]
                .find(open)
                .expect("make_fake_pwsh の heredoc が無い")
            + open.len();
        let end = start
            + text[start..]
                .find("\nEOF\n")
                .expect("heredoc の終わりが無い")
            + 1;
        let body = &text[start..end];
        let read = "code=$(base64 -d <<<\"${enc}\" | tr -d '\\0')\n";
        assert_eq!(
            body.matches(read).count(),
            1,
            "偽の pwsh.exe が本文を読む行が無い"
        );
        body.replace(
            read,
            &format!("{read}printf '%s\\n----\\n' \"${{code}}\" >>\"${{HOME}}/pwsh-codes\"\n"),
        )
    }

    /// 偽の Windows の初めの状態 (WSL の試験の fake_windows と同じ en-US の既定のまま)
    #[cfg(unix)]
    const FAKE_WINDOWS: &str = r#"{"locale":"en-US","values":{"sShortDate":{"current":"M/d/yyyy","default":"M/d/yyyy"},"sTimeFormat":{"current":"h:mm:ss tt","default":"h:mm:ss tt"},"sShortTime":{"current":"h:mm tt","default":"h:mm tt"}},"deny":{},"stuck":[],"broadcast_error":0}"#;

    /// runner の側の外のコマンドの口: 本物の口で打つ (偽の pwsh.exe は bash の script)。HOME と PATH は WSL の側と同じ形にする
    #[cfg(unix)]
    struct ParitySys {
        home: PathBuf,
        path: String,
        pwsh: PathBuf,
        git: PathBuf,
        envs: Vec<(String, String)>,
    }

    #[cfg(unix)]
    impl crate::process::Sys for ParitySys {
        fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
            let mut s = spec.clone().env("HOME", &self.home).env("PATH", &self.path);
            for (k, v) in &self.envs {
                s = s.env(k, v);
            }
            crate::process::RealSys.run(&s, on_line)
        }

        fn which(&self, name: &str) -> Option<PathBuf> {
            match name {
                "pwsh" => Some(self.pwsh.clone()),
                "git" => Some(self.git.clone()),
                _ => None,
            }
        }

        fn env(&self, _name: &str) -> Option<String> {
            None
        }
    }

    /// 流し方 (WSL の script の引数と、runner の流し方の組)
    #[cfg(unix)]
    #[derive(Clone, Copy, Debug)]
    enum Run {
        Apply,
        Force,
        Dry,
        Import,
    }

    /// WSL の script と runner を、別々の (同じ中身の) 偽の Windows・checkout・記録で流す組。`wsl/` と `rn/` に分ける
    #[cfg(unix)]
    struct Pair {
        t: TempDir,
        sys_bin: PathBuf,
        /// 両側の偽の pwsh.exe に渡す env (FAKE_PWSH_RC など)
        envs: Vec<(String, String)>,
    }

    #[cfg(unix)]
    impl Pair {
        fn new() -> Pair {
            use std::os::unix::fs::PermissionsExt;
            let t = TempDir::new("international-parity");
            // 要るコマンドだけを並べた PATH (本物の pwsh.exe を見せない。WSL の /mnt の下も見ない)
            let sys_bin = t.path().join("sys-bin");
            std::fs::create_dir_all(&sys_bin).unwrap();
            let path = std::env::var_os("PATH").unwrap_or_default();
            for c in [
                "bash", "env", "jq", "git", "cat", "mkdir", "mktemp", "mv", "cp", "rm", "date",
                "sort", "sed", "cmp", "dirname", "od", "base64", "tr", "timeout", "awk", "touch",
            ] {
                let found = std::env::split_paths(&path)
                    .filter(|d| !d.starts_with("/mnt"))
                    .map(|d| d.join(c))
                    .find(|p| p.is_file())
                    .unwrap_or_else(|| panic!("{c} が無い"));
                std::os::unix::fs::symlink(found, sys_bin.join(c)).unwrap();
            }
            let bash = sys_bin.join("bash");
            for side in ["wsl", "rn"] {
                let home = t.path().join(side).join("home");
                std::fs::create_dir_all(home.join("bin")).unwrap();
                let fake = home.join("bin").join("pwsh.exe");
                std::fs::write(&fake, format!("#!{}\n{}", bash.display(), fake_pwsh())).unwrap();
                std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
                std::fs::write(home.join("fake-windows.json"), FAKE_WINDOWS).unwrap();
            }
            let wsl_state = t.path().join("wsl/home/.local/state/dotfiles");
            std::fs::create_dir_all(&wsl_state).unwrap();
            std::fs::write(
                wsl_state.join("windows-files.json"),
                "{\"enable\":true,\"version\":1,\"windowsHome\":null}\n",
            )
            .unwrap();
            let scripts = t.path().join("wsl/repo/nix/scripts");
            std::fs::create_dir_all(&scripts).unwrap();
            std::fs::copy(
                parity::repo_file("nix/scripts/bootstrap-windows-international.sh"),
                scripts.join("bootstrap-windows-international.sh"),
            )
            .unwrap();
            let p = Pair {
                t,
                sys_bin,
                envs: Vec::new(),
            };
            p.set_managed(MANAGED3);
            p
        }

        fn side(&self, s: &str) -> PathBuf {
            self.t.path().join(s)
        }

        fn managed(&self, s: &str) -> PathBuf {
            join_segments(&self.side(s).join("repo"), MANAGED_REL)
        }

        fn record(&self, s: &str) -> PathBuf {
            if s == "wsl" {
                self.side(s)
                    .join("home/.local/state/dotfiles")
                    .join(RECORD_FILE)
            } else {
                self.side(s).join("state").join(RECORD_FILE)
            }
        }

        fn read(p: &Path) -> Option<String> {
            std::fs::read_to_string(p).ok()
        }

        fn set_managed(&self, text: &str) {
            for s in ["wsl", "rn"] {
                let m = self.managed(s);
                std::fs::create_dir_all(m.parent().unwrap()).unwrap();
                std::fs::write(m, text).unwrap();
            }
        }

        fn set_record(&self, text: &str) {
            for s in ["wsl", "rn"] {
                let r = self.record(s);
                std::fs::create_dir_all(r.parent().unwrap()).unwrap();
                std::fs::write(r, text).unwrap();
            }
        }

        /// 片側の偽の Windows を書き換える
        fn edit_win_of(&self, s: &str, f: &dyn Fn(&mut serde_json::Value)) {
            let p = self.side(s).join("home/fake-windows.json");
            let mut v: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
            f(&mut v);
            std::fs::write(&p, v.to_string()).unwrap();
        }

        /// 両側の偽の Windows を同じく書き換える
        fn edit_win(&self, f: &dyn Fn(&mut serde_json::Value)) {
            self.edit_win_of("wsl", f);
            self.edit_win_of("rn", f);
        }

        /// WSL の側の偽の Windows を、runner の側へ写す (同じ PC を、WSL の setup の後に runner が見る)
        fn copy_win_to_runner(&self) {
            std::fs::copy(
                self.side("wsl").join("home/fake-windows.json"),
                self.side("rn").join("home/fake-windows.json"),
            )
            .unwrap();
        }

        /// 両側の repo を、managed.json を commit した git の checkout にする
        fn git_init(&self) {
            for s in ["wsl", "rn"] {
                let repo = self.side(s).join("repo");
                for args in [
                    &["init", "-q"][..],
                    &["add", "win"][..],
                    &[
                        "-c",
                        "user.name=test",
                        "-c",
                        "user.email=test@example.com",
                        "commit",
                        "-qm",
                        "init",
                    ][..],
                ] {
                    let o = std::process::Command::new(self.sys_bin.join("git"))
                        .arg("-C")
                        .arg(&repo)
                        .args(args)
                        .env_clear()
                        .env("HOME", self.side(s))
                        .env("PATH", &self.sys_bin)
                        .output()
                        .unwrap();
                    assert!(o.status.success(), "{o:?}");
                }
            }
        }

        fn wsl(&self, run: Run) -> (i32, String) {
            let args: &[&str] = match run {
                Run::Apply => &[],
                Run::Force => &["--force"],
                Run::Dry => &["--dry-run"],
                Run::Import => &["--import"],
            };
            let home = self.side("wsl").join("home");
            let mut c = std::process::Command::new(self.sys_bin.join("bash"));
            c.arg(
                self.side("wsl")
                    .join("repo/nix/scripts/bootstrap-windows-international.sh"),
            )
            .args(args)
            .env_clear()
            .env("HOME", &home)
            .env(
                "PATH",
                format!("{}:{}", home.join("bin").display(), self.sys_bin.display()),
            )
            .stdin(std::process::Stdio::null());
            for (k, v) in &self.envs {
                c.env(k, v);
            }
            let o = c.output().unwrap();
            (
                o.status.code().unwrap_or(-1),
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr)
                ),
            )
        }

        fn runner(&self, run: Run) -> (Outcome, String) {
            let home = self.side("rn").join("home");
            let sys = ParitySys {
                path: format!("{}:{}", home.join("bin").display(), self.sys_bin.display()),
                pwsh: home.join("bin").join("pwsh.exe"),
                git: self.sys_bin.join("git"),
                envs: self.envs.clone(),
                home,
            };
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.side("rn").join("repo"),
                    roots: Roots::from_home(&self.side("rn").join("win")),
                    state_dir: self.side("rn").join("state"),
                    host: parse(
                        RUNNER_HOST,
                        Path::new("h.toml"),
                        Groups::embedded().unwrap(),
                    )
                    .unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                match run {
                    Run::Apply => International.run(&mut ctx, APPLY).remove(0),
                    Run::Force => International.run(&mut ctx, FORCE).remove(0),
                    Run::Dry => International.run(&mut ctx, DRY).remove(0),
                    Run::Import => import(&mut ctx),
                }
            };
            (o, String::from_utf8(out).unwrap())
        }

        /// 両側を同じ流し方で流し、WSL の終了コードと runner の行の種類を確かめ、書いたもの・pwsh に渡したものが同じかを比べる
        fn step(&self, label: &str, run: Run, rc: i32, kind: Kind) {
            let (wrc, wout) = self.wsl(run);
            let (o, rout) = self.runner(run);
            assert_eq!(wrc, rc, "{label}: WSL の終了コード\n{wout}");
            assert_eq!(o.kind, kind, "{label}: runner の行\n{rout}");
            let w = self.side("wsl").join("home");
            let r = self.side("rn").join("home");
            for f in [
                "fake-windows.json",
                "pwsh-modes",
                "writes",
                "pwsh-args",
                "pwsh-codes",
            ] {
                assert_eq!(
                    Self::read(&w.join(f)),
                    Self::read(&r.join(f)),
                    "{label}: {f} が違う\n--- WSL\n{wout}\n--- runner\n{rout}"
                );
            }
            assert!(
                !w.join("bad-encoding").exists() && !r.join("bad-encoding").exists(),
                "{label}: ASCII の UTF-16LE でない本文を渡した"
            );
            assert_eq!(
                Self::read(&self.record("wsl")),
                Self::read(&self.record("rn")),
                "{label}: 記録が違う\n--- WSL\n{wout}\n--- runner\n{rout}"
            );
            assert_eq!(
                Self::read(&self.managed("wsl")),
                Self::read(&self.managed("rn")),
                "{label}: managed.json が違う"
            );
        }
    }

    /// WSL の script と同じ状態から流し、同じ本文を pwsh に渡し、同じ値を書き、同じ記録と managed.json を書く (一続きの流れ)
    #[cfg(unix)]
    #[test]
    fn does_what_the_wsl_script_does() {
        if !parity::available() {
            return;
        }
        let p = Pair::new();
        p.step("初めて書く", Run::Apply, 0, Kind::Ok);
        p.step("揃っている", Run::Apply, 0, Kind::Ok);
        p.set_managed("{\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"H:mm\"\n}\n");
        p.step("managed.json を変えた", Run::Apply, 0, Kind::Ok);
        p.edit_win(&|v| v["values"]["sShortDate"]["current"] = "yyyy/MM/dd".into());
        p.step("Windows で変えた", Run::Apply, 1, Kind::Manual);
        p.step("--force", Run::Force, 0, Kind::Ok);
        p.edit_win(&|v| {
            v["locale"] = "ja-JP".into();
            for (n, d) in [
                ("sShortDate", "yyyy/MM/dd"),
                ("sTimeFormat", "H:mm:ss"),
                ("sShortTime", "H:mm"),
            ] {
                v["values"][n] = serde_json::json!({"current": d, "default": d});
            }
        });
        p.step("地域を変えた", Run::Apply, 1, Kind::Manual);
        p.step("dry-run の衝突", Run::Dry, 1, Kind::Manual);
        p.git_init();
        p.step("取り込む", Run::Import, 0, Kind::Ok);
        p.step("取り込んだ後", Run::Apply, 0, Kind::Ok);
    }

    /// WSL の試験のほかのケースも、同じ状態から流して突き合わせる
    #[cfg(unix)]
    #[test]
    fn matches_the_wsl_script_in_each_case() {
        if !parity::available() {
            return;
        }
        type Prep = Box<dyn Fn(&Pair)>;
        /// 名前・用意・流し方 (WSL の終了コードと runner の行の種類) の組
        type Case = (&'static str, Prep, Vec<(Run, i32, Kind)>);
        let want_all: Prep = Box::new(|p| {
            p.edit_win(&|v| {
                for (n, w) in [
                    ("sShortDate", "yyyy-MM-dd"),
                    ("sTimeFormat", "HH:mm:ss"),
                    ("sShortTime", "HH:mm"),
                ] {
                    v["values"][n]["current"] = w.into();
                }
            })
        });
        let deny = |e: i64| -> Prep {
            Box::new(move |p| p.edit_win(&|v| v["deny"] = serde_json::json!({"sShortTime": e})))
        };
        let cases: Vec<Case> = vec![
            ("もう持つ値", want_all, vec![(Run::Apply, 0, Kind::Ok)]),
            (
                "記録の無い衝突",
                Box::new(|p| {
                    p.edit_win(&|v| v["values"]["sShortDate"]["current"] = "yyyy/MM/dd".into())
                }),
                vec![(Run::Apply, 1, Kind::Manual), (Run::Force, 0, Kind::Ok)],
            ),
            (
                "dry-run",
                Box::new(|_| {}),
                vec![(Run::Dry, 0, Kind::Missing), (Run::Apply, 0, Kind::Ok)],
            ),
            ("書けない値", deny(87), vec![(Run::Apply, 1, Kind::Failed)]),
            (
                "グループポリシー",
                deny(1260),
                vec![(Run::Apply, 0, Kind::Manual), (Run::Apply, 0, Kind::Manual)],
            ),
            (
                "読み戻すと違う値",
                Box::new(|p| p.edit_win(&|v| v["stuck"] = serde_json::json!(["sShortDate"]))),
                vec![(Run::Apply, 1, Kind::Failed)],
            ),
            (
                "WM_SETTINGCHANGE を送れない",
                Box::new(|p| p.edit_win(&|v| v["broadcast_error"] = 1460.into())),
                vec![(Run::Apply, 0, Kind::Ok)],
            ),
            (
                "日本語や ' を含む形式",
                Box::new(|p| {
                    p.set_managed("{\n    \"sShortDate\": \"yyyy'年'M'月'd'日'\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"HH'h'mm 😀\"\n}\n")
                }),
                vec![(Run::Apply, 0, Kind::Ok), (Run::Apply, 0, Kind::Ok)],
            ),
            (
                "壊れた記録",
                Box::new(|p| p.set_record("[]\n")),
                vec![(Run::Apply, 1, Kind::Failed)],
            ),
            (
                "持つ値が無い",
                Box::new(|p| p.set_managed("{}\n")),
                vec![(Run::Apply, 0, Kind::Ok)],
            ),
        ];
        for (label, prep, runs) in cases {
            let p = Pair::new();
            prep(&p);
            for (i, (run, rc, kind)) in runs.into_iter().enumerate() {
                p.step(&format!("{label} ({}: {run:?})", i + 1), run, rc, kind);
            }
        }

        // managed.json から消した値: Windows では戻さず、記録からだけ消す
        let p = Pair::new();
        p.step("消す前", Run::Apply, 0, Kind::Ok);
        p.set_managed("{\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sShortTime\": \"HH:mm\"\n}\n");
        p.step("managed.json から消した値", Run::Apply, 0, Kind::Ok);

        // 取り込み: 衝突が無い (何も取り込まない)・managed.json に commit していない変更がある (止まる)
        let p = Pair::new();
        p.git_init();
        p.step("取り込むものが無い", Run::Import, 0, Kind::Ok);
        p.edit_win(&|v| v["values"]["sShortDate"]["current"] = "yyyy/MM/dd".into());
        p.set_managed("{\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"H:mm\"\n}\n");
        p.step("commit していない変更", Run::Import, 1, Kind::Failed);

        // 書く途中で pwsh が落ちる: どの値が書けたか分からないので記録しない
        let mut p = Pair::new();
        p.envs = vec![("FAKE_PWSH_WRITE_RC".into(), "1".into())];
        p.step("書く途中で落ちる", Run::Apply, 1, Kind::Failed);

        // pwsh が落ちる・決めた形の JSON を返さない: どちらも書かない (WSL は警告して 0、runner は failed)
        let mut p = Pair::new();
        p.envs = vec![
            ("FAKE_PWSH_RC".into(), "1".into()),
            ("FAKE_PWSH_ERR".into(), "Add-Type: boom".into()),
        ];
        p.step("pwsh が落ちる", Run::Apply, 0, Kind::Failed);
        let mut p = Pair::new();
        p.envs = vec![("FAKE_PWSH_RAW".into(), "oops".into())];
        p.step("JSON でない返り", Run::Apply, 0, Kind::Failed);
    }

    /// WSL の setup が書いた PC を、記録の無い runner が引き継ぐ (受け持ちを切り替えた後の初めての apply)
    #[cfg(unix)]
    #[test]
    fn takes_over_what_the_wsl_script_wrote() {
        if !parity::available() {
            return;
        }
        let rn_home = |p: &Pair, f: &str| Pair::read(&p.side("rn").join("home").join(f));
        // 書き直さず、WSL と同じバイト列の記録を作る
        let p = Pair::new();
        let (rc, out) = p.wsl(Run::Apply);
        assert_eq!(rc, 0, "{out}");
        p.copy_win_to_runner();
        let (o, out) = p.runner(Run::Apply);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(rn_home(&p, "pwsh-modes").as_deref(), Some("read\n"));
        assert_eq!(rn_home(&p, "writes"), None);
        assert_eq!(Pair::read(&p.record("rn")), Pair::read(&p.record("wsl")));
        assert_eq!(Pair::read(&p.record("rn")).as_deref(), Some(RECORD3));

        // WSL が書いた後に設定画面で変えた値: どちらも衝突として触らない (WSL は前回書いた値と比べ、runner は記録が無いので地域の既定と比べる)
        let p = Pair::new();
        p.wsl(Run::Apply);
        p.edit_win_of("wsl", &|v| {
            v["values"]["sShortDate"]["current"] = "yyyy/MM/dd".into()
        });
        p.copy_win_to_runner();
        let (rc, wout) = p.wsl(Run::Apply);
        assert_eq!(rc, 1, "{wout}");
        assert!(
            wout.contains("!! 衝突: sShortDate は Windows 側で変わっています"),
            "{wout}"
        );
        let (o, rout) = p.runner(Run::Apply);
        assert_eq!(o.kind, Kind::Manual, "{rout}");
        assert!(
            rout.contains(
                "!! 衝突: sShortDate は、書いた記録が無く、地域 (en-US) の既定とも違います"
            ),
            "{rout}"
        );
        assert_eq!(rn_home(&p, "writes"), None, "{rout}");

        // managed.json の更新が WSL に届く前に切り替えた: WSL なら記録どおりに書き換えるが、記録の無い runner は「書いた記録が無く」の衝突にする
        let p = Pair::new();
        p.wsl(Run::Apply);
        p.set_managed("{\n    \"sShortDate\": \"yyyy-MM-dd\",\n    \"sTimeFormat\": \"HH:mm:ss\",\n    \"sShortTime\": \"H:mm\"\n}\n");
        p.copy_win_to_runner();
        let (o, rout) = p.runner(Run::Apply);
        assert_eq!(o.kind, Kind::Manual, "{rout}");
        assert!(
            rout.contains(
                "!! 衝突: sShortTime は、書いた記録が無く、地域 (en-US) の既定とも違います"
            ),
            "{rout}"
        );
        assert!(
            rout.contains(
                "managed.json の値で書くなら: dotfiles apply --steps international --force"
            ),
            "{rout}"
        );
        assert_eq!(rn_home(&p, "writes"), None, "{rout}");
        let (rc, wout) = p.wsl(Run::Apply);
        assert_eq!(rc, 0, "{wout}");
        assert!(
            wout.contains("sShortTime: \"HH:mm\" → \"H:mm\" (managed.json が更新された)"),
            "{wout}"
        );

        // WSL が書いた後に地域の既定に戻した値: WSL は衝突、記録の無い runner は初めて書く (WSL の記録だけが知っている「前に書いた」は
        // 引き継げない。切り替える直前に WSL の setup を流して解いておく。win/README.md の「受け持ちを runner に切り替える」)
        let p = Pair::new();
        p.wsl(Run::Apply);
        p.edit_win_of("wsl", &|v| {
            v["values"]["sShortDate"]["current"] = "M/d/yyyy".into()
        });
        p.copy_win_to_runner();
        let (rc, wout) = p.wsl(Run::Apply);
        assert_eq!(rc, 1, "{wout}");
        assert!(
            wout.contains(
                "!! 衝突: sShortDate は、前回書いた値から地域 (en-US) の既定に戻っています"
            ),
            "{wout}"
        );
        let (o, rout) = p.runner(Run::Apply);
        assert_eq!(o.kind, Kind::Ok, "{rout}");
        assert!(
            rout.contains(
                "  sShortDate: \"M/d/yyyy\" → \"yyyy-MM-dd\" (初めて書く。今の値は地域の既定)"
            ),
            "{rout}"
        );
    }
}
