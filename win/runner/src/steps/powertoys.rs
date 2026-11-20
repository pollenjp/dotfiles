//! powertoys (order 91): win/ から配った PowerToys の Keyboard Manager の割り当て (default.json) を効かせる。PowerToys が入っていなければ winget で
//! 入れ (Install-PowerToys.ps1 -IfMissing)、Keyboard Manager と自動起動をオンにし、Keyboard Manager に default.json を読み直させる。WSL の
//! `nix/scripts/bootstrap-windows-powertoys.sh` を写したもの (判定の順・PowerShell の本文・記録と印の名前と形・文言をそろえる。受け持ちを runner に
//! 切り替えた後に、WSL の setup が入れたもの・オンにしたものを同じものとして引き継ぐため)。
//!
//! Keyboard Manager のエンジンは、起動したときと名前付きイベント `PowerToys_KeyboardManager_Event_Settings` を受けたときにしか default.json を読まない
//! (dotfiles-private の docs/adr/015_win_google_ime_powertoys_*)。読むのは同じディレクトリの settings.json が指す有効なプロファイルで、settings.json は
//! PowerToys の設定画面が作る (ADR 017 の §1 の 7)。Keyboard Manager と自動起動は既定でオフ (ADR 041)。
//!
//! 1. clone の `win/powertoys/Install-PowerToys.ps1 -Check` を流し、3 (入っていない) なら `-IfMissing` で入れる (user スコープ。管理者は要らない)
//! 2. `%LOCALAPPDATA%\Microsoft\PowerToys\Keyboard Manager\default.json` が無ければ飛ばす
//! 3. 全体の設定 (`%LOCALAPPDATA%\Microsoft\PowerToys\settings.json`) の `enabled["Keyboard Manager"]` と `startup` がどちらも true なら何もしない。
//!    どちらかが true でなければ、PowerToys を止める → 両方を true にする (ほかの項目とキーの順と 1 行の形は変えない。無ければ 2 つだけで作る) →
//!    起動する → 確かめる。書いた後に起動や確認でつまずいたら印 (`powertoys-enable.pending`) を残し、次の回は両方 true でも起動と確認をやり直す
//! 4. Keyboard Manager の settings.json の有効なプロファイルが default でなければ、記録もイベントも触らずに案内する (入れた直後・起動した直後は、
//!    設定画面が作るのを 30 秒まで待つ。待つときは記録を消す)
//! 5. default.json の sha256 が記録 (`powertoys-keyboard-manager.reloaded`) と同じなら何もしない (`--force` なら比べない)。違えばイベントを送り、
//!    送れたか、PowerToys が動いていない (起動したときに読む) なら記録する
//!
//! - 記録と印は `%LOCALAPPDATA%\dotfiles\state\` に WSL と同じ名前と形で置く (記録は sha256 の 1 行)。WSL の記録は読まない: 切り替えた後の初めての
//!   apply は、一度読み直させて記録する
//! - PowerShell の本文 (止める・起動する・エンジンを待つ・イベントを送る) は WSL と同じ字で、Windows PowerShell の `-EncodedCommand` で渡す (WSL は
//!   `powershell.exe -Command`。複数行で `"` を含む本文を、コマンドラインの引用符の扱いに左右されずに渡すため)
//! - check と dry-run は何も書かず、PowerToys を止めない・起こさない・イベントを送らない・winget を打たない (`-Check` は読むだけ)

use super::ps1;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::jv::Jv;
use crate::process::{Exit, strip_ansi};
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// 読み直させた default.json の sha256 の記録 (WSL の `~/.local/state/dotfiles/` の記録と同じ名前)
pub const RECORD_FILE: &str = "powertoys-keyboard-manager.reloaded";
/// 全体の設定に書いた後、起動と確認がまだ済んでいない印 (WSL と同じ名前)
pub const PENDING_FILE: &str = "powertoys-enable.pending";
/// 入っているかを確かめ、入れる ps1 (repo からの相対)
const SCRIPT: &str = "win/powertoys/Install-PowerToys.ps1";
/// Keyboard Manager に読み直させる名前付きイベント
const EVENT: &str = "PowerToys_KeyboardManager_Event_Settings";
/// `-Check` を待つ上限 (WSL の `timeout 60`)
const CHECK_SECS: u64 = 60;
/// `-IfMissing` を待つ上限 (WSL の `timeout 600`)
const INSTALL_SECS: u64 = 600;
/// 止める・起動する・待つ・イベントを送るのを待つ上限 (WSL の `run_ps 60`)
const PS_SECS: u64 = 60;
/// `-Check` の出力の状態の表の見出し (入っていないときにも必ず入る)
const HEADER: &str = "Microsoft.PowerToys";
/// Keyboard Manager の置き場 (`%LOCALAPPDATA%` からの相対)
const KM_DIR: &str = "Microsoft/PowerToys/Keyboard Manager";
/// 全体の設定 (`%LOCALAPPDATA%` からの相対)
const GLOBAL_REL: &str = "Microsoft/PowerToys/settings.json";

/// 共通の関数と、PowerToys.exe を探すところ (WSL の `ps_common` と同じ字)
const PS_COMMON: &str = r#"$session = (Get-Process -Id $PID).SessionId
function Get-Mine($name) { Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } }
function Wait-Gone($name, $seconds) {
  $end = (Get-Date).AddSeconds($seconds)
  while ((Get-Mine $name) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 200 }
}
$exe = @((Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe'), (Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe')) |
  Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $exe) { 'no-exe'; exit 0 }"#;

/// PowerToys を止める (WSL の `ps_stop` の後半と同じ字。トレイのウィンドウに WM_CLOSE、だめなら強制で止める)
const PS_STOP: &str = r#"if (-not (Get-Mine 'PowerToys')) { 'not-running'; exit 0 }
Add-Type -Namespace Dotfiles -Name User32 -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wparam, IntPtr lparam);
'@
$w = [Dotfiles.User32]::FindWindow('PToyTrayIconWindow', [NullString]::Value)
if ($w -ne [IntPtr]::Zero -and [Dotfiles.User32]::PostMessage($w, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)) { Wait-Gone 'PowerToys' 20 }
if (Get-Mine 'PowerToys') {
  Get-Mine 'PowerToys' | Stop-Process -Force -ErrorAction SilentlyContinue
  Wait-Gone 'PowerToys' 10
}
if (Get-Mine 'PowerToys') { 'still-running'; exit 0 }
Wait-Gone 'PowerToys.*' 5
Get-Mine 'PowerToys.KeyboardManagerEngine' | Stop-Process -Force -ErrorAction SilentlyContinue
Wait-Gone 'PowerToys.KeyboardManagerEngine' 3
'stopped'"#;

/// PowerToys を起動する (WSL の `ps_start` の後半と同じ字。動いていれば何もしない)
const PS_START: &str = r#"if (Get-Mine 'PowerToys') { 'running'; exit 0 }
Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
'started'"#;

/// 起動した Keyboard Manager のエンジンがイベントを作るのを待ち、自動起動のタスクも見る (WSL の `ps_wait_km` と同じ字。`$name` は前に置く)
const PS_WAIT_KM: &str = r#"$end = (Get-Date).AddSeconds(30)
$state = 'absent'
while ($true) {
  $h = $null
  if ([System.Threading.EventWaitHandle]::TryOpenExisting($name, [ref]$h)) { $h.Dispose(); $state = 'ready'; break }
  if ((Get-Date) -ge $end) { break }
  Start-Sleep -Milliseconds 500
}
$task = if (Get-ScheduledTask -TaskPath '\PowerToys\' -ErrorAction SilentlyContinue) { 'task' } else { 'no-task' }
$state + ' ' + $task"#;

pub struct PowerToys;

impl Step for PowerToys {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "powertoys",
            order: 91,
            title: "PowerToys を入れ、Keyboard Manager と自動起動をオンにして割り当てを読み直させる",
            gate: Gate::Always,
            ported: true,
            windows_only: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        // SSH の会話 (Win32-OpenSSH はセッション 0) からは、デスクトップの会話の PowerToys のプロセスも名前付きイベントも見えない。止める・
        // 起こすと 2 つ目の PowerToys をセッション 0 に起こし、イベントは「無い」と読んで読み直させないまま記録してしまうので、確かめるだけにする
        // (WSL の setup はデスクトップの端末からしか流れないので、この分かれ道は runner にだけある)
        if mode.writes() && in_ssh(ctx) {
            ctx.say("SSH の会話の中なので、PowerToys に触ること (入れる・止める・起こす・読み直させる) はせず、確かめるだけにします (デスクトップの会話の PowerToys とイベントは、SSH の会話から見えないため)。");
            let mut rows = sync(ctx, Mode::Check);
            rows.push(
                Outcome::new(
                    Kind::Manual,
                    "SSH の会話の中なので PowerToys に触らなかった (上の行は確かめた結果)",
                )
                .note("PC のデスクトップの PowerShell (管理者でないもの) で dotfiles apply --steps powertoys を流す"),
            );
            return rows;
        }
        sync(ctx, mode)
    }
}

/// SSH の会話の中か (sshd が SSH_CONNECTION・SSH_CLIENT を渡す。win/openssh/Install-Sshd.ps1 と同じ見方)
fn in_ssh(ctx: &Ctx) -> bool {
    ["SSH_CONNECTION", "SSH_CLIENT"]
        .iter()
        .any(|k| ctx.sys.env(k).is_some_and(|v| !v.is_empty()))
}

/// 流している間の状態 (WSL の script の変数)。
struct St {
    mode: Mode,
    rows: Vec<Outcome>,
    /// 入れた (-IfMissing が通った)
    installed_now: bool,
    /// 起動し直した
    restarted: bool,
    /// Keyboard Manager がオンで、読み直しへ進んでよいか (オンにできなかったら false)
    km_usable: bool,
    /// オンにする前から Keyboard Manager がオンだったか
    km_before: bool,
    km: bool,
    startup: bool,
    elevated: bool,
    global: PathBuf,
    km_settings: PathBuf,
    record: PathBuf,
    pending: PathBuf,
}

/// 止める本文 (WSL の `ps_stop`)
fn ps_stop() -> String {
    format!("{PS_COMMON}\n{PS_STOP}")
}

/// 起動する本文 (WSL の `ps_start`)
fn ps_start() -> String {
    format!("{PS_COMMON}\n{PS_START}")
}

/// エンジンを待つ本文
fn ps_wait() -> String {
    format!("$name = '{EVENT}'; {PS_WAIT_KM}")
}

/// イベントを送る本文 (WSL の `ps`。イベントがあれば Set() して set、無ければ absent)
fn ps_event() -> String {
    format!(
        "$h = $null; if ([System.Threading.EventWaitHandle]::TryOpenExisting('{EVENT}', [ref]$h)) {{ [void]$h.Set(); $h.Dispose(); 'set' }} else {{ 'absent' }}"
    )
}

/// Windows PowerShell で本文を流す (WSL の `run_ps`。頭に `$ProgressPreference = 'SilentlyContinue'; ` を付ける)。終了コード (時間切れは 124、
/// PowerShell が無い・起こせないのは 127) と、出力 (CR を落として行を改行でつなぎ、末尾の改行を落とす) を返す。
fn run_ps(ctx: &mut Ctx, body: &str) -> (i32, String) {
    let Some(shell) = ps1::find_windows_powershell(ctx) else {
        return (127, String::new());
    };
    let spec = ps1::encoded_command(
        shell,
        &format!("$ProgressPreference = 'SilentlyContinue'; {body}"),
        Duration::from_secs(PS_SECS),
    );
    let r = ctx.sys.run(&spec, &mut |_| {});
    let rc = match r.exit {
        Exit::Code(c) => c,
        Exit::TimedOut => 124,
        Exit::NoCode => 1,
        Exit::SpawnFailed(_) => 127,
    };
    let out = r
        .output
        .iter()
        .map(|l| l.replace('\r', ""))
        .collect::<Vec<_>>()
        .join("\n");
    (rc, out.trim_end_matches('\n').to_string())
}

/// 止めない警告を出す (WSL の `warn`。1 行目は `!! `、続きは字下げ)
fn warn(ctx: &mut Ctx, lines: &[String]) {
    for (i, l) in lines.iter().enumerate() {
        for (j, part) in l.split('\n').enumerate() {
            if i == 0 && j == 0 {
                ctx.say(format!("!! {part}"));
            } else {
                ctx.say(format!("   {part}"));
            }
        }
    }
}

/// 流し直すコマンド (受け持ちで替える)
fn rerun(ctx: &Ctx) -> &'static str {
    if ctx.host.runner_enable {
        "dotfiles apply --steps powertoys"
    } else {
        "WSL の setup --update (か nix/scripts/bootstrap-windows-powertoys.sh)"
    }
}

/// 読み直させられないときに、手で読み直す方法 (WSL の `manual`)
const MANUAL: &str =
    "PowerToys の設定 → Keyboard Manager を一度オフにしてオンに戻すと、読み直します。";

/// 入っているかを自動で確かめられないときに、手で確かめて入れるコマンド (WSL の `install_manual`)
fn install_manual() -> String {
    "Windows の PowerShell で次を打つと、確かめて、入っていなければ入れられます:\n  Install-PowerToys"
        .to_string()
}

/// Keyboard Manager と自動起動を手でオンにする手順 (WSL の `enable_manual`。文言は日本語の設定画面に合わせている)
fn enable_manual(ctx: &Ctx) -> String {
    format!(
        "PowerToys の設定画面で 2 つをオンにしてください: 「入出力」→「Keyboard Manager」、「全般」→「起動時に実行」(Run at startup)。\nオンにしたら、{} を流し直してください。配った割り当てを読み直させます。",
        rerun(ctx)
    )
}

/// オフのものの名前 (WSL の `off_names`。文の頭か「、」の後ろに置く)
fn off_names(km: bool, startup: bool) -> &'static str {
    if !km && !startup {
        "Keyboard Manager と自動起動"
    } else if !km {
        "Keyboard Manager "
    } else {
        "自動起動"
    }
}

/// 手順の中身。WSL の script と同じ順に進む (入れる → default.json → オンにする → settings.json のプロファイル → 読み直させる)。
fn sync(ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
    let local = ctx.roots.local_app_data.clone();
    let km_dir = join_segments(&local, KM_DIR);
    let mut st = St {
        mode,
        rows: Vec::new(),
        installed_now: false,
        restarted: false,
        km_usable: true,
        km_before: false,
        km: false,
        startup: false,
        elevated: false,
        global: join_segments(&local, GLOBAL_REL),
        km_settings: km_dir.join("settings.json"),
        record: ctx.state_dir.join(RECORD_FILE),
        pending: ctx.state_dir.join(PENDING_FILE),
    };
    install(ctx, &mut st);

    let default_json = km_dir.join("default.json");
    if !default_json.is_file() {
        ctx.say(format!(
            "Keyboard Manager の default.json がまだありません ({})。この手順は飛ばします。",
            default_json.display()
        ));
        st.rows.push(Outcome::new(
            Kind::Info,
            "Keyboard Manager の default.json がまだ無いので飛ばした (files の手順が置いてから読み直させる)",
        ));
        return st.rows;
    }
    if st.installed_now {
        wait_km_settings(ctx, &mut st);
    }
    ensure_enabled(ctx, &mut st);
    if !st.km_usable {
        return st.rows;
    }
    if st.restarted {
        wait_km_settings(ctx, &mut st);
    }

    // エンジンは settings.json の有効なプロファイルの名前を読み、その名前の JSON を読む (settings.json が無ければ何も読まない)。default でなければ、
    // 送っても配った default.json は読まれないので、記録もイベントも触らずに案内する
    let active = km_active(&st.km_settings);
    let shown = st.km_settings.display().to_string();
    if active.is_empty() {
        warn(
            ctx,
            &[
                format!(
                    "Keyboard Manager の設定 (settings.json) がまだ無いので、配った default.json は読まれません ({shown} が無いか、読めない)。"
                ),
                format!(
                    "PowerToys の設定画面を一度開いてから、{} を流し直してください。",
                    rerun(ctx)
                ),
            ],
        );
        st.rows.push(
            Outcome::new(
                Kind::Manual,
                "Keyboard Manager の settings.json がまだ無いので、配った default.json は読まれない",
            )
            .note(format!(
                "PowerToys の設定画面を一度開いてから、{} を流し直す ({shown} を作る)",
                rerun(ctx)
            )),
        );
        return st.rows;
    }
    if active != "default" {
        warn(
            ctx,
            &[format!(
                "Keyboard Manager の有効なプロファイルが default ではありません ({active})。配った default.json は読まれません。PowerToys の設定で、プロファイルを default に戻してください ({shown} の activeConfiguration)。"
            )],
        );
        st.rows.push(
            Outcome::new(
                Kind::Manual,
                format!("Keyboard Manager の有効なプロファイルが default でない ({active}) ので、配った default.json は読まれない"),
            )
            .note("PowerToys の設定で、Keyboard Manager のプロファイルを default に戻す"),
        );
        return st.rows;
    }

    let sum = match fsutil::sha256_file(&default_json) {
        Ok(s) => s,
        Err(e) => {
            ctx.say(format!(
                "!! default.json を読めません: {} ({e})",
                default_json.display()
            ));
            st.rows.push(Outcome::new(
                Kind::Failed,
                format!("Keyboard Manager の default.json を読めない ({e})"),
            ));
            return st.rows;
        }
    };
    let recorded = std::fs::read_to_string(&st.record)
        .ok()
        .and_then(|t| t.lines().next().map(str::to_string));
    if !mode.force() && recorded.as_deref() == Some(sum.as_str()) {
        ctx.say("Keyboard Manager は、今の default.json を読み直し済みです。");
        st.rows.push(Outcome::new(
            Kind::Ok,
            "Keyboard Manager は今の default.json を読み直し済み",
        ));
        return st.rows;
    }
    match mode {
        Mode::Check => {
            if !ctx.host.runner_enable && recorded.is_none() {
                ctx.say(format!(
                    "runner の記録はまだありません (受け持ちを runner に切り替えた後の初めての apply で、一度読み直させて記録します。WSL の setup の記録は WSL の ~/.local/state/dotfiles/{RECORD_FILE})。"
                ));
                st.rows.push(Outcome::new(
                    Kind::Ok,
                    "Keyboard Manager の設定は揃っている (読み直させた runner の記録はまだ無い。切り替えた後の apply で一度読み直させる)",
                ));
            } else {
                ctx.say(
                    "今の default.json を読み直させた記録がありません (apply で読み直させる)。",
                );
                // オンにする (起動し直す) 行があるときは、止めないとは言わない
                let text = if st.rows.iter().any(|r| r.kind == Kind::Fix) {
                    "今の default.json を Keyboard Manager に読み直させていない → apply で読み直させる"
                } else {
                    "今の default.json を Keyboard Manager に読み直させていない → apply で読み直させる (PowerToys は止めない)"
                };
                st.rows.push(Outcome::new(Kind::Fix, text));
            }
        }
        Mode::DryRun { .. } => {
            ctx.say(
                "[dry-run] Keyboard Manager に default.json を読み直させます (イベントを送る)。",
            );
            st.rows.push(Outcome::new(
                Kind::Fix,
                "[dry-run] Keyboard Manager に default.json を読み直させる (イベントを送る)",
            ));
        }
        Mode::Apply { .. } => reload(ctx, &mut st, &sum),
    }
    st.rows
}

/// イベントを送り、送れたか PowerToys が動いていなければ記録する。
fn reload(ctx: &mut Ctx, st: &mut St, sum: &str) {
    let (rc, out) = run_ps(ctx, &ps_event());
    let remember = |st: &St| fsutil::write_atomic(&st.record, format!("{sum}\n").as_bytes());
    let done = match (rc, out.as_str()) {
        (0, "set") => Some((
            "Keyboard Manager に default.json を読み直させました。",
            "Keyboard Manager に default.json を読み直させた",
        )),
        (0, "absent") => Some((
            "PowerToys (Keyboard Manager) が動いていません。起動したときに今の default.json を読みます。",
            "PowerToys が動いていないので、起動したときに今の default.json を読む",
        )),
        _ => None,
    };
    match done {
        Some((said, row)) => {
            if let Err(e) = remember(st) {
                ctx.say(format!(
                    "!! 読み直させた記録を書けません: {} ({e})",
                    st.record.display()
                ));
                st.rows.push(Outcome::new(
                    Kind::Failed,
                    format!("読み直させた記録を書けない ({e})"),
                ));
                return;
            }
            ctx.say(said);
            st.rows.push(Outcome::new(Kind::Ok, row));
        }
        None => {
            let mut lines = vec![format!(
                "PowerShell で Keyboard Manager に読み直させられませんでした (終了コード {rc}):"
            )];
            if !out.is_empty() {
                lines.push(out);
            }
            lines.push(MANUAL.to_string());
            warn(ctx, &lines);
            st.rows.push(
                Outcome::new(
                    Kind::Failed,
                    format!("Keyboard Manager に読み直させられなかった (終了コード {rc})"),
                )
                .note(
                    MANUAL
                        .trim_end_matches('。')
                        .replace("読み直します", "読み直す"),
                ),
            );
        }
    }
}

/// PowerToys が入っていなければ、Install-PowerToys.ps1 -IfMissing で入れる (WSL の `install_powertoys`)。入っているかは -Check で見る。何が
/// あっても続きへ進む。
fn install(ctx: &mut Ctx, st: &mut St) {
    let Some(shell) = ps1::find_powershell(ctx) else {
        warn(
            ctx,
            &[
                "PowerShell (pwsh も powershell も) が見つかりません。PowerToys が入っているかを確かめられません。".to_string(),
                install_manual(),
            ],
        );
        st.rows.push(
            Outcome::new(
                Kind::Failed,
                "PowerShell が見つからないので、PowerToys が入っているかを確かめられない",
            )
            .note("PowerShell で Install-PowerToys を打つと、確かめて、入っていなければ入れられる"),
        );
        return;
    };
    let script = ctx.repo_path(SCRIPT).to_string_lossy().into_owned();
    let r = ctx.sys.run(
        &ps1::powershell_command(
            shell.clone(),
            &script,
            " -Check",
            Duration::from_secs(CHECK_SECS),
        ),
        &mut |_| {},
    );
    let out: Vec<String> = r.output.iter().map(|l| strip_ansi(l)).collect();
    // 入っていないときの出力には、状態の表の見出し (パッケージ名) が必ず入る。3 でも見出しが無ければ、スクリプトが動いていない
    let header = out.iter().any(|l| l.contains(HEADER));
    match (&r.exit, header) {
        (Exit::Code(0), _) => ctx.say("PowerToys は入っています。"),
        (Exit::Code(3), true) => match st.mode {
            Mode::Check => {
                ctx.say("Windows に PowerToys が入っていません (apply で、winget で入れる。Install-PowerToys.ps1 -IfMissing。user スコープ)。");
                st.rows.push(Outcome::new(
                    Kind::Missing,
                    "PowerToys が入っていない → apply で入れる (winget の Microsoft.PowerToys。user スコープ。管理者は要らない)",
                ));
            }
            Mode::DryRun { .. } => {
                ctx.say("[dry-run] Windows に PowerToys が入っていないので、winget で入れます (Install-PowerToys.ps1 -IfMissing。user スコープ)。");
                st.rows.push(Outcome::new(
                    Kind::Missing,
                    "[dry-run] PowerToys を winget で入れる (user スコープ)",
                ));
            }
            Mode::Apply { .. } => {
                ctx.say(format!(
                    "Windows に PowerToys が入っていないので、winget で入れます (Install-PowerToys.ps1 -IfMissing。user スコープ。{INSTALL_SECS} 秒まで待ちます)。"
                ));
                let r2 = ps1::run_streaming(
                    ctx,
                    &ps1::powershell_command(
                        shell,
                        &script,
                        " -IfMissing",
                        Duration::from_secs(INSTALL_SECS),
                    ),
                );
                let why = match r2.exit {
                    Exit::Code(0) => {
                        ctx.say("Windows に PowerToys を入れました。");
                        st.installed_now = true;
                        return;
                    }
                    Exit::TimedOut => format!(
                        "{INSTALL_SECS} 秒待っても終わらない。Windows 側でまだ入れている途中かもしれません"
                    ),
                    Exit::Code(c) => format!("終了コード {c}"),
                    Exit::NoCode => "終了コードが無い".to_string(),
                    Exit::SpawnFailed(e) => format!("起こせなかった: {e}"),
                };
                let fix = format!(
                    "入れるには PowerShell で Install-PowerToys を打つか、{} を流し直す (もう一度入れにいく。管理者は要らない)",
                    rerun(ctx)
                );
                warn(
                    ctx,
                    &[
                        format!("Windows に PowerToys を入れられませんでした ({why})"),
                        fix.clone(),
                    ],
                );
                st.rows.push(
                    Outcome::new(
                        Kind::Failed,
                        format!("Windows に PowerToys を入れられなかった ({why})"),
                    )
                    .note(fix),
                );
            }
        },
        (exit, _) => {
            let why = match exit {
                Exit::TimedOut => format!("{CHECK_SECS} 秒たっても終わらない。時間切れ"),
                Exit::Code(c) => format!("終了コード {c}"),
                Exit::NoCode => "終了コードが無い".to_string(),
                Exit::SpawnFailed(e) => format!("起こせなかった: {e}"),
            };
            let headline =
                format!("PowerShell で PowerToys が入っているかを確かめられませんでした ({why}):");
            let mut lines = vec![headline.clone()];
            if !out.is_empty() {
                lines.push(out.join("\n"));
            }
            lines.push(install_manual());
            warn(ctx, &lines);
            st.rows.push(
                Outcome::new(
                    Kind::Failed,
                    format!("PowerShell で PowerToys が入っているかを確かめられなかった ({why})"),
                )
                .note("PowerShell で Install-PowerToys を打つと、確かめて、入っていなければ入れられる"),
            );
        }
    }
}

/// 全体の設定の 3 つ (Keyboard Manager・自動起動・管理者として実行)。ファイルが無ければ全部 false。読めない (JSON でない・空・`enabled` が
/// object でない) なら Err (jq の `.enabled["Keyboard Manager"] == true` などが落ちる形と同じ)
fn read_global(path: &Path) -> Result<(bool, bool, bool), ()> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((false, false, false)),
        Err(_) => return Err(()),
    };
    let v = Jv::parse(&text).map_err(|_| ())?;
    let is_true = |x: Option<&Jv>| -> Result<bool, ()> { Ok(x.ok_or(())? == &Jv::Bool(true)) };
    let km = is_true(v.field("enabled").ok_or(())?.field("Keyboard Manager"))?;
    let startup = is_true(v.field("startup"))?;
    let elevated = is_true(v.field("run_elevated"))?;
    Ok((km, startup, elevated))
}

/// `read_global` を 5 回まで試す (設定画面が同じファイルを書いている途中に当たっても読めるように。読めないたびに 1 秒待つ)。読めなければ 3 つとも
/// false にして false を返す。
fn read_global_retry(ctx: &mut Ctx, st: &mut St) -> bool {
    for _ in 0..5 {
        if let Ok((km, startup, elevated)) = read_global(&st.global) {
            (st.km, st.startup, st.elevated) = (km, startup, elevated);
            return true;
        }
        ctx.sys.sleep(Duration::from_secs(1));
    }
    (st.km, st.startup, st.elevated) = (false, false, false);
    false
}

/// 全体の設定の 2 つを true にする。ほかの項目はそのまま (PowerToys が書く形に合わせて、1 行で末尾に改行なし。jq の `-cj`)。ファイルが無ければ
/// 2 つだけで作る。隣に書いてから置き換える
fn write_global(path: &Path) -> Result<(), String> {
    let mut doc = match std::fs::read_to_string(path) {
        Ok(t) => Jv::parse(&t)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Jv::Object(Vec::new()),
        Err(e) => return Err(e.to_string()),
    };
    doc.set_path(&["startup".to_string()], Jv::Bool(true))?;
    doc.set_path(
        &["enabled".to_string(), "Keyboard Manager".to_string()],
        Jv::Bool(true),
    )?;
    fsutil::write_atomic(path, doc.compact().as_bytes()).map_err(|e| e.to_string())
}

/// オンにできなかったときに知らせる (WSL の `give_up`)。Keyboard Manager がオフのままなら、読み直しへ進まない (進むと、読まれないのに「読み直し済み」
/// 「起動したときに読みます」と出し、記録してしまう)
fn give_up(ctx: &mut Ctx, st: &mut St, kind: Kind, row: String, lines: &[String]) {
    warn(ctx, lines);
    let notes: Vec<String> = lines
        .iter()
        .skip(1)
        .flat_map(|l| l.split('\n').map(str::to_string).collect::<Vec<_>>())
        .filter(|l| !l.trim().is_empty())
        .collect();
    let mut o = Outcome::new(kind, row);
    o.notes = notes;
    st.rows.push(o);
    if !st.km_before {
        st.km_usable = false;
    }
}

/// Keyboard Manager と自動起動がオンかを見て、オフならオンにして PowerToys を起動し直す (WSL の `ensure_enabled`)。止めた後は、どの枝でも起動する。
/// check と dry-run は何もせず、することを出す。
fn ensure_enabled(ctx: &mut Ctx, st: &mut St) {
    st.km_before = false;
    let global = st.global.display().to_string();
    if !read_global_retry(ctx, st) {
        let lines = [
            format!(
                "PowerToys の全体の設定を読めないので、Keyboard Manager と自動起動がオンかを確かめられません ({global})。"
            ),
            enable_manual(ctx),
        ];
        give_up(
            ctx,
            st,
            Kind::Failed,
            "PowerToys の全体の設定を読めないので、Keyboard Manager と自動起動がオンかを確かめられない".to_string(),
            &lines,
        );
        return;
    }
    if st.km && st.startup {
        // 前の回が書いた後に起動や確認でつまずいていれば、確かめ直す。確かめるまでは、読み直しへ進まない (km_before は false のまま)
        if st.pending.exists() && !st.elevated {
            match st.mode {
                Mode::Apply { .. } => {
                    ctx.say("前の回は PowerToys の起動を確かめられなかったので、確かめ直します。");
                    start_and_confirm(
                        ctx,
                        st,
                        "Keyboard Manager と自動起動",
                        "Keyboard Manager と自動起動がオンで、PowerToys が動いていることを確かめました。",
                    );
                }
                Mode::Check => {
                    ctx.say("前の回は PowerToys の起動を確かめられていません (apply で、起動と確認をやり直す)。");
                    st.rows.push(Outcome::new(
                        Kind::Fix,
                        "前の回は PowerToys の起動を確かめられていない → apply で起動と確認をやり直す",
                    ));
                }
                Mode::DryRun { .. } => {
                    ctx.say("[dry-run] 前の回は PowerToys の起動を確かめられなかったので、確かめ直します (起動する → 確かめる)。");
                    st.rows.push(Outcome::new(
                        Kind::Fix,
                        "[dry-run] PowerToys の起動と確認をやり直す (前の回は確かめられなかった)",
                    ));
                }
            }
        }
        return;
    }
    st.km_before = st.km;
    let offs = off_names(st.km, st.startup);
    if st.elevated {
        let lines = [
            format!(
                "PowerToys が管理者として実行する設定 (run_elevated) なので、{offs}をオンにしません (起動すると UAC の確認が出るため)。"
            ),
            enable_manual(ctx),
        ];
        give_up(
            ctx,
            st,
            Kind::Manual,
            format!(
                "PowerToys が管理者として実行する設定 (run_elevated) なので、{offs}をオンにしない (起動すると UAC の確認が出る)"
            ),
            &lines,
        );
        return;
    }
    match st.mode {
        Mode::Check => {
            ctx.say(format!(
                "{offs}がオフです (apply でオンにして、PowerToys を起動し直す。数秒止まる)。"
            ));
            st.rows.push(Outcome::new(
                Kind::Fix,
                format!("{offs}がオフ → apply でオンにして PowerToys を起動し直す (数秒止まる。設定画面を開いていれば閉じる)"),
            ));
            if !st.km {
                st.km_usable = false;
            }
            return;
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] {offs}がオフです。オンにして、PowerToys を起動し直します (止める → 2 つを true に書く → 起動する → 確かめる。数秒止まる)。"));
            st.rows.push(Outcome::new(
                Kind::Fix,
                format!("[dry-run] {offs}をオンにして PowerToys を起動し直す"),
            ));
            if !st.km {
                st.km_usable = false;
            }
            return;
        }
        Mode::Apply { .. } => {}
    }

    ctx.say(format!(
        "{offs}がオフです。オンにして、PowerToys を起動し直します (数秒止まります。設定画面を開いていれば閉じます)。"
    ));
    let (stop_rc, stop_out) = run_ps(ctx, &ps_stop());
    match (stop_rc, stop_out.as_str()) {
        (0, "stopped" | "not-running") => {}
        (0, "no-exe") => {
            let lines = [
                format!("PowerToys が見つからないので、{offs}をオンにできませんでした。"),
                install_manual(),
            ];
            give_up(
                ctx,
                st,
                Kind::Manual,
                format!("PowerToys が見つからないので、{offs}をオンにできない"),
                &lines,
            );
            return;
        }
        (0, "still-running") => {
            run_ps(ctx, &ps_start());
            let lines = [
                format!(
                    "PowerToys を止められないので、{offs}をオンにできませんでした (管理者として動いているかもしれません)。"
                ),
                enable_manual(ctx),
            ];
            give_up(
                ctx,
                st,
                Kind::Manual,
                format!(
                    "PowerToys を止められないので、{offs}をオンにできない (管理者として動いているかもしれない)"
                ),
                &lines,
            );
            return;
        }
        _ => {
            // 止める途中で時間切れになったかもしれないので、起動しておく
            run_ps(ctx, &ps_start());
            let mut lines = vec![format!(
                "PowerShell で PowerToys を止められないので、{offs}をオンにできませんでした (終了コード {stop_rc}):"
            )];
            if !stop_out.is_empty() {
                lines.push(stop_out);
            }
            lines.push(enable_manual(ctx));
            give_up(
                ctx,
                st,
                Kind::Failed,
                format!(
                    "PowerShell で PowerToys を止められないので、{offs}をオンにできない (終了コード {stop_rc})"
                ),
                &lines,
            );
            return;
        }
    }

    let _ = fsutil::write_atomic(&st.pending, b"");
    if let Err(e) = write_global(&st.global) {
        let _ = std::fs::remove_file(&st.pending);
        run_ps(ctx, &ps_start());
        let lines = [
            format!("全体の設定に書けないので、{offs}をオンにできませんでした ({global})。"),
            enable_manual(ctx),
        ];
        give_up(
            ctx,
            st,
            Kind::Failed,
            format!("全体の設定に書けないので、{offs}をオンにできない ({e})"),
            &lines,
        );
        return;
    }
    start_and_confirm(
        ctx,
        st,
        offs,
        &format!("{offs}をオンにして、PowerToys を起動しました。"),
    );
}

/// PowerToys を起動して確かめる (WSL の `start_and_confirm`)。確かめられたら印を消す。つまずいたら印を残すので、次の回がやり直す。
fn start_and_confirm(ctx: &mut Ctx, st: &mut St, offs: &str, done: &str) {
    let (rc, out) = run_ps(ctx, &ps_start());
    if !(rc == 0 && (out == "started" || out == "running")) {
        let mut lines = vec![format!(
            "PowerToys を起動できませんでした (終了コード {rc})。設定には書いたので、スタートメニューから起動すると、{offs}がオンになります:"
        )];
        if !out.is_empty() {
            lines.push(out);
        }
        give_up(
            ctx,
            st,
            Kind::Failed,
            format!(
                "PowerToys を起動できなかった (終了コード {rc}。設定には書いたので、スタートメニューから起動すると、{offs}がオンになる)"
            ),
            &lines,
        );
        return;
    }
    st.restarted = true;

    let (rc, out) = run_ps(ctx, &ps_wait());
    if !(rc == 0 && (out == "ready task" || out == "ready no-task")) {
        if rc == 0 && out.starts_with("absent ") {
            let lines = [
                "PowerToys を起動しましたが、Keyboard Manager のエンジンが 30 秒たっても動いていません。".to_string(),
                enable_manual(ctx),
            ];
            give_up(
                ctx,
                st,
                Kind::Manual,
                "PowerToys を起動したが、Keyboard Manager のエンジンが 30 秒たっても動いていない"
                    .to_string(),
                &lines,
            );
        } else {
            let mut lines = vec![format!(
                "PowerToys を起動しましたが、Keyboard Manager のエンジンが動いたかを確かめられませんでした (終了コード {rc}):"
            )];
            if !out.is_empty() {
                lines.push(out);
            }
            lines.push(enable_manual(ctx));
            give_up(
                ctx,
                st,
                Kind::Failed,
                format!(
                    "PowerToys を起動したが、Keyboard Manager のエンジンが動いたかを確かめられない (終了コード {rc})"
                ),
                &lines,
            );
        }
        return;
    }
    let wait_out = out;

    // 読み直して確かめる。読めなければ 2 つとも false のまま
    read_global_retry(ctx, st);
    if !st.km || !st.startup {
        st.km_before = st.km;
        let offs_now = off_names(st.km, st.startup);
        let lines = [
            format!(
                "PowerToys を起動しましたが、{offs_now}が全体の設定でオンになっていません ({})。",
                st.global.display()
            ),
            enable_manual(ctx),
        ];
        give_up(
            ctx,
            st,
            Kind::Manual,
            format!("PowerToys を起動したが、{offs_now}が全体の設定でオンになっていない"),
            &lines,
        );
        return;
    }
    if wait_out == "ready no-task" {
        st.km_before = true;
        let lines = [
            "PowerToys を起動しましたが、自動起動のタスクがありません (タスク スケジューラの \\PowerToys)。サインインしても PowerToys が動かないかもしれません。".to_string(),
            enable_manual(ctx),
        ];
        warn(ctx, &lines);
        let mut o = Outcome::new(
            Kind::Manual,
            "PowerToys を起動したが、自動起動のタスクが無い (サインインしても動かないかもしれない)",
        );
        o.notes = enable_manual(ctx).split('\n').map(str::to_string).collect();
        st.rows.push(o);
        return;
    }
    let _ = std::fs::remove_file(&st.pending);
    ctx.say(done);
}

/// Keyboard Manager の settings.json の有効なプロファイルの名前 (WSL の `km_active`: `.properties.activeConfiguration.value // empty`)。無い・読めない・
/// 書きかけ・null・false なら空。
fn km_active(path: &Path) -> String {
    let Ok(text) = std::fs::read_to_string(path) else {
        return String::new();
    };
    let Ok(v) = Jv::parse(&text) else {
        return String::new();
    };
    let keys = ["properties", "activeConfiguration", "value"].map(String::from);
    match v.getpath(&keys) {
        None | Some(Jv::Null) | Some(Jv::Bool(false)) => String::new(),
        Some(Jv::String(s)) => s.clone(),
        Some(other) => other.compact(),
    }
}

/// Keyboard Manager の settings.json を作るのは設定画面で、最初の起動で開く。入れた直後・起動した直後なら、できるのを 30 秒まで待つ (WSL の
/// `wait_km_settings`)。エンジンはこのファイルが無い間に起動すると何も読まず、できても読み直さないので、記録を消して、できた後に必ず送る
fn wait_km_settings(ctx: &mut Ctx, st: &mut St) {
    if !km_active(&st.km_settings).is_empty() {
        return;
    }
    let _ = std::fs::remove_file(&st.record);
    ctx.say("PowerToys の最初の起動が Keyboard Manager の settings.json を作るのを待ちます (30 秒まで)。");
    for _ in 0..30 {
        ctx.sys.sleep(Duration::from_secs(1));
        if !km_active(&st.km_settings).is_empty() {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (WSL の nix/tests/bootstrap-windows-powertoys.test.sh のケースを、runner だけの試験と WSL の script との突き合わせに分けたもの)
    //!
    //! runner だけの試験 (偽の Sys。Windows の CI でも流れる):
    //! - 送れたら記録し、同じ default.json では送らない。変われば送る。--force なら変わらなくても送る。送る本文は WSL と同じ字
    //! - PowerToys が動いていない (absent) ときも記録する。PowerShell が無い・失敗する・知らない出力なら、手で読み直す方法を出して記録しない
    //! - Keyboard Manager の settings.json が無い・有効なプロファイルが default でないときは、送らず記録もしない (できた後の回で送る)
    //! - 入っていない (-Check が 3) なら -IfMissing で入れる。入れられない・時間切れ・-Check が失敗する・見出しが無い・時間切れ・起こせないときも
    //!   知らせて続きへ進む。default.json が無くても入っているかは確かめる
    //! - Keyboard Manager か自動起動がオフなら、止める → 両方を true に書く (ほかの項目とキーの順と 1 行の形は変えない) → 起動する → 確かめる。
    //!   全体の設定が無ければ 2 つだけで作る。オンにできないとき (run_elevated・止められない・失敗する・起動できない・エンジンが動かない) は
    //!   手順を出し、止めた後は起動する。書いた後につまずいたら印を残し、次の回が起動と確認をやり直す。自動起動のタスクが無いと知らせる
    //! - 入れた直後と起動した直後は、Keyboard Manager の settings.json ができるのを 30 秒まで待つ (待つときは記録を消す)
    //! - check と dry-run は、印・記録・settings.json の有無や全体の設定の形によらず何も書かず、-Check のほかの本文を流さない。受け持ちが WSL の
    //!   間の check は、runner の記録が無いことを ✔ で知らせる。起動し直す行があるときは「止めない」と言わない
    //! - SSH の会話の中の apply は、PowerToys に触らずに確かめるだけにして manual を足す
    //! - PowerShell の本文・記録と印の名前・待つ秒数・判定の語が WSL の script の字と同じ
    //! - 本物の Windows PowerShell が、PowerToys の入っていないマシンで本文を -EncodedCommand で流す (Windows の CI)
    //!
    //! WSL の script との突き合わせ (偽の powershell.exe・pwsh.exe・sleep と本物の bash・jq。要るコマンドだけの PATH):
    //! - 40 を超える場面 (送れた・動いていない・送れない・オンにする・止められない・PowerToys が無い・書けない・起動できない・エンジンが動かない・
    //!   タスクが無い・起動の後もオフ・印・run_elevated・入れる・入れられない・確かめられない・全体の設定と settings.json の形 (null・配列・空・
    //!   BOM・CRLF・同じキー・数と逃がした字)・読みかけが書き終わる・--force) を同じ状態から 2 回ずつ流し、受けた本文の種類と本文 (バイト単位)・
    //!   待った回数・全体の設定・記録・印が同じ。JSON の値が 2 つ並ぶ全体の設定は、runner は読めないものとする (WSL は 2 つをつないで書き戻す)
    //!   ので比べない

    use super::*;
    use crate::hooks::parity;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::{CommandSpec, RunResult};
    use crate::testutil::{FakeSys, TempDir};
    use std::cell::RefCell;
    use std::rc::Rc;

    const RUNNER_HOST: &str = "[runner]\nenable = true\n";
    const WSL_HOST: &str = "group = \"personal\"\n";
    const APPLY: Mode = Mode::Apply { force: false };
    /// Install-PowerToys.ps1 -Check の出力 (入っている / 入っていない)
    const INSTALLED_OUT: &str = "PowerToys (winget の Microsoft.PowerToys。版は固定しない)\n  入っている場所 : C:\\Users\\u\\AppData\\Local\\PowerToys\\PowerToys.exe\n  入っている版   : 0.100.2.0\n入っている";
    const MISSING_OUT: &str = "PowerToys (winget の Microsoft.PowerToys。版は固定しない)\n⚠ 入っている場所 : 入っていない → user スコープで入れる\n⚠️ PowerToys が入っていない → Install-PowerToys で入れる ⚠️";
    const KM_SETTINGS: &str = r#"{"properties":{"activeConfiguration":{"value":"default"},"keyboardConfigurations":{"value":["default"]}},"name":"Keyboard Manager","version":"1"}"#;
    const DEFAULT_JSON: &str =
        r#"{"remapKeys":{"inProcess":[{"originalKeys":"20","newRemapKeys":"124"}]}}"#;

    /// PowerToys の runner が書く全体の settings.json (1 行で末尾に改行なし。WSL の試験の global_settings と同じ)
    fn global_settings(km: bool, startup: bool, elevated: bool) -> String {
        format!(
            r#"{{"startup":{startup},"enabled":{{"AdvancedPaste":false,"AlwaysOnTop":true,"Keyboard Manager":{km},"ZoomIt":false}},"show_tray_icon":true,"is_elevated":false,"run_elevated":{elevated},"quick_access_shortcut":{{"win":false,"code":0,"key":""}},"theme":"system","powertoys_version":"v0.102.3001","ignored_conflict_properties":{{"ignored_shortcuts":[]}}}}"#
        )
    }

    /// 偽の PowerShell の答え方 (WSL の試験の FAKE_* と同じ並び)。
    #[derive(Clone)]
    struct Fake {
        check: (i32, String),
        install: (i32, String),
        stop: (i32, String),
        start: (i32, String),
        /// 起動のときに全体の設定をこれで置き換える (起動した runner や設定画面が書く)
        start_writes: Option<String>,
        wait: (i32, String),
        event: (i32, String),
        /// n 回目に待ったときに、Keyboard Manager の settings.json (`sleep_global` なら全体の設定) をこの中身で書く (書きかけが書き終わる)
        sleep_write: Option<(usize, String)>,
        sleep_global: bool,
        /// PowerShell (powershell・pwsh) を置くか
        shells: bool,
        /// SSH の会話の中 (SSH_CONNECTION がある) か
        ssh: bool,
    }

    impl Default for Fake {
        fn default() -> Self {
            Fake {
                check: (0, INSTALLED_OUT.into()),
                install: (0, String::new()),
                stop: (0, "stopped".into()),
                start: (0, "started".into()),
                start_writes: None,
                wait: (0, "ready task".into()),
                event: (0, "set".into()),
                sleep_write: None,
                sleep_global: false,
                shells: true,
                ssh: false,
            }
        }
    }

    /// 偽の PowerShell が受けた本文の種類 (WSL の試験の ps-steps と同じ名前)
    fn classify(c: &CommandSpec) -> String {
        if let Some(body) = ps1::decode_command(c) {
            if body.contains("PToyTrayIconWindow") {
                "stop".into()
            } else if body.contains("Start-Process") {
                "start".into()
            } else if body.contains("AddSeconds") {
                "wait".into()
            } else {
                "event".into()
            }
        } else {
            let a = c.args_lossy().join(" ");
            if a.contains("-IfMissing") {
                "ifmissing".into()
            } else {
                "check".into()
            }
        }
    }

    struct Env {
        t: TempDir,
    }

    impl Env {
        /// default.json・Keyboard Manager の settings.json・全体の settings.json (両方オン) を置く
        fn new() -> Self {
            let e = Env {
                t: TempDir::new("powertoys"),
            };
            e.put(&e.default_json(), DEFAULT_JSON);
            e.put(&e.km_settings(), KM_SETTINGS);
            e.put(&e.global(), &global_settings(true, true, false));
            e
        }

        fn local(&self) -> PathBuf {
            Roots::from_home(&self.t.path().join("win")).local_app_data
        }

        fn default_json(&self) -> PathBuf {
            join_segments(&self.local(), KM_DIR).join("default.json")
        }

        fn km_settings(&self) -> PathBuf {
            join_segments(&self.local(), KM_DIR).join("settings.json")
        }

        fn global(&self) -> PathBuf {
            join_segments(&self.local(), GLOBAL_REL)
        }

        fn state(&self) -> PathBuf {
            self.t.path().join("state")
        }

        fn record(&self) -> PathBuf {
            self.state().join(RECORD_FILE)
        }

        fn pending(&self) -> PathBuf {
            self.state().join(PENDING_FILE)
        }

        fn put(&self, p: &Path, s: &str) {
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, s).unwrap();
        }

        fn read(&self, p: &Path) -> Option<String> {
            std::fs::read_to_string(p).ok()
        }

        /// 偽の PowerShell で流す。行・出力・受けた本文の種類 (順)・待った回数を返す
        fn run(
            &self,
            fake: &Fake,
            host: &str,
            mode: Mode,
        ) -> (Vec<Outcome>, String, Vec<String>, usize) {
            let (rows, out, steps, sleeps, _) = self.run_full(fake, host, mode);
            (rows, out, steps, sleeps)
        }

        /// `run` と同じに流し、Windows PowerShell に渡した本文 (-EncodedCommand を戻したもの) も順に返す
        fn run_full(
            &self,
            fake: &Fake,
            host: &str,
            mode: Mode,
        ) -> (Vec<Outcome>, String, Vec<String>, usize, Vec<String>) {
            let steps = Rc::new(RefCell::new(Vec::<String>::new()));
            let bodies = Rc::new(RefCell::new(Vec::<String>::new()));
            let (s, b, f, global, km) = (
                steps.clone(),
                bodies.clone(),
                fake.clone(),
                self.global(),
                if fake.sleep_global {
                    self.global()
                } else {
                    self.km_settings()
                },
            );
            let mut sys = FakeSys::new(move |c| {
                let kind = classify(c);
                s.borrow_mut().push(kind.clone());
                if let Some(body) = ps1::decode_command(c) {
                    b.borrow_mut().push(body);
                }
                let (rc, out) = match kind.as_str() {
                    "check" => f.check.clone(),
                    "ifmissing" => f.install.clone(),
                    "stop" => f.stop.clone(),
                    "start" => {
                        if let Some(w) = &f.start_writes {
                            std::fs::write(&global, w).unwrap();
                        }
                        f.start.clone()
                    }
                    "wait" => f.wait.clone(),
                    _ => f.event.clone(),
                };
                RunResult {
                    exit: Exit::Code(rc),
                    output: out.lines().map(str::to_string).collect(),
                }
            });
            if fake.shells {
                sys = sys
                    .with_program("pwsh", "/fake/pwsh")
                    .with_program("powershell", "/fake/powershell");
            }
            if fake.ssh {
                sys = sys.with_env("SSH_CONNECTION", "100.64.0.2 50000 100.64.0.1 22");
            }
            if let Some((at, content)) = fake.sleep_write.clone() {
                sys = sys.with_on_sleep(move |n| {
                    if n == at {
                        std::fs::write(&km, &content).unwrap();
                    }
                });
            }
            let mut out = Vec::new();
            let rows = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("win")),
                    state_dir: self.state(),
                    host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                PowerToys.run(&mut ctx, mode)
            };
            let sleeps = sys.sleeps.borrow().len();
            let steps = steps.borrow().clone();
            let bodies = bodies.borrow().clone();
            (rows, String::from_utf8(out).unwrap(), steps, sleeps, bodies)
        }

        fn apply(&self, fake: &Fake) -> (Vec<Outcome>, String, Vec<String>, usize) {
            self.run(fake, RUNNER_HOST, APPLY)
        }
    }

    fn ps_steps(steps: &[String]) -> Vec<&str> {
        steps
            .iter()
            .map(String::as_str)
            .filter(|s| !matches!(*s, "check" | "ifmissing"))
            .collect()
    }

    fn last_kind(rows: &[Outcome]) -> Kind {
        rows.last().unwrap().kind
    }

    #[test]
    fn reloads_once_per_default_json() {
        let e = Env::new();
        let f = Fake::default();
        let (rows, out, steps, _) = e.apply(&f);
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0].kind, Kind::Ok, "{out}");
        assert!(out.contains("PowerToys は入っています。"), "{out}");
        assert!(out.contains("読み直させました"), "{out}");
        assert_eq!(steps, vec!["check", "event"]);
        let sum = fsutil::sha256_bytes(DEFAULT_JSON.as_bytes());
        assert_eq!(e.read(&e.record()).unwrap(), format!("{sum}\n"));
        // 同じ default.json: 送らない (入っているかは毎回確かめる)
        let (rows, out, steps, _) = e.apply(&f);
        assert_eq!(rows[0].kind, Kind::Ok);
        assert!(out.contains("読み直し済み"), "{out}");
        assert_eq!(steps, vec!["check"]);
        // --force: 同じでも送る
        let (_, _, steps, _) = e.run(&f, RUNNER_HOST, Mode::Apply { force: true });
        assert_eq!(ps_steps(&steps), vec!["event"]);
        // default.json が変わった: 送って記録を更新する
        e.put(&e.default_json(), r#"{"remapKeys":{"inProcess":[]}}"#);
        let (_, _, steps, _) = e.apply(&f);
        assert_eq!(ps_steps(&steps), vec!["event"]);
        assert_ne!(e.read(&e.record()).unwrap(), format!("{sum}\n"));
        // 送ったイベントの名前と、Windows PowerShell の本文 ($ProgressPreference を頭に)
        let sys = FakeSys::new(|_| RunResult {
            exit: Exit::Code(0),
            output: vec!["set".into()],
        })
        .with_program("powershell", "C:/ps.exe");
        let mut o = Vec::new();
        let mut ctx = Ctx {
            repo: "/r".into(),
            roots: Roots::from_home(Path::new("/h")),
            state_dir: "/s".into(),
            host: parse(
                RUNNER_HOST,
                Path::new("h.toml"),
                Groups::embedded().unwrap(),
            )
            .unwrap(),
            sys: &sys,
            out: &mut o,
        };
        run_ps(&mut ctx, &ps_event());
        let body = ps1::decode_command(&sys.calls.borrow()[0]).unwrap();
        assert_eq!(
            body,
            format!("$ProgressPreference = 'SilentlyContinue'; {}", ps_event())
        );
        assert!(body.contains("TryOpenExisting('PowerToys_KeyboardManager_Event_Settings'"));
        assert_eq!(sys.calls.borrow()[0].program, PathBuf::from("C:/ps.exe"));
    }

    #[test]
    fn absent_or_failed_events() {
        let e = Env::new();
        let f = Fake {
            event: (0, "absent".into()),
            ..Fake::default()
        };
        let (rows, out, _, _) = e.apply(&f);
        assert_eq!(last_kind(&rows), Kind::Ok, "{out}");
        assert!(
            out.contains("動いていません。起動したときに今の default.json を読みます"),
            "{out}"
        );
        assert!(e.record().exists());

        for (rc, text) in [(126, ""), (0, "Exec format error")] {
            let e = Env::new();
            let f = Fake {
                event: (rc, text.into()),
                ..Fake::default()
            };
            let (rows, out, _, _) = e.apply(&f);
            assert_eq!(last_kind(&rows), Kind::Failed, "{out}");
            assert!(out.contains("オフにしてオンに戻す"), "{out}");
            assert!(!e.record().exists());
        }
        // PowerShell が無い: 入っているかも確かめられず、読み直させられない
        let e = Env::new();
        let f = Fake {
            shells: false,
            ..Fake::default()
        };
        let (rows, out, steps, _) = e.apply(&f);
        assert!(steps.is_empty());
        assert_eq!(rows[0].kind, Kind::Failed, "{out}");
        assert!(out.contains("Install-PowerToys"), "{out}");
        assert_eq!(last_kind(&rows), Kind::Failed);
        assert!(out.contains("オフにしてオンに戻す"), "{out}");
        assert!(!e.record().exists());
    }

    #[test]
    fn km_settings_must_point_at_default() {
        let e = Env::new();
        std::fs::remove_file(e.km_settings()).unwrap();
        let (rows, out, steps, _) = e.apply(&Fake::default());
        assert_eq!(last_kind(&rows), Kind::Manual, "{out}");
        assert!(out.contains("設定画面を一度開いてから"), "{out}");
        assert_eq!(ps_steps(&steps), Vec::<&str>::new());
        assert!(!e.record().exists());
        e.put(&e.km_settings(), KM_SETTINGS);
        let (rows, _, steps, _) = e.apply(&Fake::default());
        assert_eq!(last_kind(&rows), Kind::Ok);
        assert_eq!(ps_steps(&steps), vec!["event"]);

        e.put(
            &e.km_settings(),
            r#"{"properties":{"activeConfiguration":{"value":"work"}}}"#,
        );
        let before = e.read(&e.record());
        let (rows, out, steps, _) = e.apply(&Fake::default());
        assert_eq!(last_kind(&rows), Kind::Manual, "{out}");
        assert!(out.contains("default ではありません (work)"), "{out}");
        assert_eq!(ps_steps(&steps), Vec::<&str>::new());
        assert_eq!(e.read(&e.record()), before);
        assert!(!out.contains("読み直し済み"));
    }

    #[test]
    fn installs_when_missing() {
        // 入っていない (-Check が 3): -IfMissing で入れてから読み直させる
        let e = Env::new();
        let f = Fake {
            check: (3, MISSING_OUT.into()),
            install: (0, "  Successfully installed".into()),
            ..Fake::default()
        };
        let (rows, out, steps, _) = e.apply(&f);
        assert_eq!(steps, vec!["check", "ifmissing", "event"], "{out}");
        assert!(out.contains("winget で入れます"), "{out}");
        assert!(out.contains("600 秒まで待ちます"), "{out}");
        assert!(out.contains("Windows に PowerToys を入れました。"), "{out}");
        assert_eq!(last_kind(&rows), Kind::Ok);
        // check と dry-run は -IfMissing を打たない
        let e = Env::new();
        let (rows, out, steps, _) = e.run(&f, RUNNER_HOST, Mode::Check);
        assert_eq!(steps, vec!["check"], "{out}");
        assert_eq!(rows[0].kind, Kind::Missing);
        let (rows, out, steps, _) = e.run(&f, RUNNER_HOST, Mode::DryRun { force: false });
        assert_eq!(steps, vec!["check"], "{out}");
        assert_eq!(rows[0].kind, Kind::Missing);
        assert!(
            out.contains("[dry-run] Windows に PowerToys が入っていないので"),
            "{out}"
        );
        assert!(!e.record().exists());
        // 入れられない・時間切れ: 知らせて読み直しへ進む
        let e = Env::new();
        let f = Fake {
            check: (3, MISSING_OUT.into()),
            install: (1, "winget failed".into()),
            ..Fake::default()
        };
        let (rows, out, steps, _) = e.apply(&f);
        assert_eq!(steps, vec!["check", "ifmissing", "event"], "{out}");
        assert_eq!(rows[0].kind, Kind::Failed);
        assert!(rows[0].text.contains("終了コード 1"), "{:?}", rows[0]);
        assert_eq!(last_kind(&rows), Kind::Ok);
        // -Check が 3 でも見出しが無い・失敗: 入れには行かず、手で打つコマンドを出す
        for (rc, text) in [(3, "something else"), (1, ""), (124, "")] {
            let e = Env::new();
            let f = Fake {
                check: (rc, text.into()),
                ..Fake::default()
            };
            let (rows, out, steps, _) = e.apply(&f);
            assert_eq!(steps, vec!["check", "event"], "{rc}: {out}");
            assert_eq!(rows[0].kind, Kind::Failed, "{rc}");
            assert!(out.contains("Install-PowerToys"), "{out}");
        }
        // default.json がまだ無くても、入っているかは確かめる
        let e = Env::new();
        std::fs::remove_file(e.default_json()).unwrap();
        let (rows, out, steps, _) = e.apply(&Fake::default());
        assert_eq!(steps, vec!["check"], "{out}");
        assert_eq!(rows[0].kind, Kind::Info);
        assert!(out.contains("default.json がまだありません"), "{out}");
    }

    #[test]
    fn turns_on_km_and_startup() {
        // 両方オフ: 止める → 書く → 起動する → 確かめる → 読み直させる。ほかの項目は変えない
        let e = Env::new();
        e.put(&e.global(), &global_settings(false, false, false));
        let f = Fake {
            start_writes: Some(global_settings(true, true, false)),
            ..Fake::default()
        };
        let (rows, out, steps, _) = e.apply(&f);
        assert_eq!(
            ps_steps(&steps),
            vec!["stop", "start", "wait", "event"],
            "{out}"
        );
        assert!(
            out.contains("Keyboard Manager と自動起動がオフです"),
            "{out}"
        );
        assert!(
            out.contains("Keyboard Manager と自動起動をオンにして、PowerToys を起動しました。"),
            "{out}"
        );
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0].kind, Kind::Ok);
        assert!(!e.pending().exists());
        // 次の回: 両方オン。止めない・書かない・起動しない
        let (_, _, steps, _) = e.apply(&Fake::default());
        assert_eq!(ps_steps(&steps), Vec::<&str>::new());

        // 書く中身: 1 行で末尾に改行なし、ほかの項目と順はそのまま (起動で書き換えない偽物で見る)
        let e = Env::new();
        e.put(&e.global(), &global_settings(false, true, false));
        let (_, out, steps, _) = e.apply(&Fake::default());
        assert!(out.contains("Keyboard Manager がオフです"), "{out}");
        assert_eq!(ps_steps(&steps), vec!["stop", "start", "wait", "event"]);
        assert_eq!(
            e.read(&e.global()).unwrap(),
            global_settings(true, true, false)
        );

        // 全体の設定が無い: 2 つだけで作る
        let e = Env::new();
        std::fs::remove_file(e.global()).unwrap();
        let f = Fake {
            stop: (0, "not-running".into()),
            ..Fake::default()
        };
        let (_, out, _, _) = e.apply(&f);
        assert_eq!(
            e.read(&e.global()).unwrap(),
            r#"{"startup":true,"enabled":{"Keyboard Manager":true}}"#,
            "{out}"
        );
    }

    #[test]
    fn cannot_turn_on() {
        // run_elevated: 止めない・書かない
        let e = Env::new();
        let g = global_settings(false, false, true);
        e.put(&e.global(), &g);
        let (rows, out, steps, _) = e.apply(&Fake::default());
        assert_eq!(ps_steps(&steps), Vec::<&str>::new(), "{out}");
        assert_eq!(rows.last().unwrap().kind, Kind::Manual);
        assert!(out.contains("run_elevated"), "{out}");
        assert!(
            out.contains("「入出力」→「Keyboard Manager」")
                && out.contains("「全般」→「起動時に実行」"),
            "{out}"
        );
        assert_eq!(e.read(&e.global()).unwrap(), g);
        assert!(!e.record().exists());

        // 止められない: 書かず、起動のコマンドは打つ。記録しない
        for (stop, kind) in [
            ((0, "still-running"), Kind::Manual),
            ((1, ""), Kind::Failed),
            ((0, "weird"), Kind::Failed),
        ] {
            let e = Env::new();
            let g = global_settings(false, false, false);
            e.put(&e.global(), &g);
            let f = Fake {
                stop: (stop.0, stop.1.into()),
                ..Fake::default()
            };
            let (rows, out, steps, _) = e.apply(&f);
            assert_eq!(ps_steps(&steps), vec!["stop", "start"], "{out}");
            assert_eq!(rows.last().unwrap().kind, kind, "{out}");
            assert_eq!(e.read(&e.global()).unwrap(), g);
            assert!(!e.record().exists() && !e.pending().exists());
            assert!(
                !out.contains("読み直し済み")
                    && !out.contains("起動したときに")
                    && !out.contains("読み直させました"),
                "{out}"
            );
        }

        // 起動できない: 設定には書いてあるので、スタートメニューから起動するよう出す。印を残す
        let e = Env::new();
        e.put(&e.global(), &global_settings(false, false, false));
        let f = Fake {
            start: (1, "".into()),
            ..Fake::default()
        };
        let (rows, out, steps, _) = e.apply(&f);
        assert_eq!(ps_steps(&steps), vec!["stop", "start"], "{out}");
        assert!(out.contains("スタートメニューから起動すると"), "{out}");
        assert_eq!(rows.last().unwrap().kind, Kind::Failed);
        assert!(e.pending().exists());
        assert!(!e.record().exists());
        // 次の回: 両方オンでも起動と確認をやり直し、確かめられたら印を消して読み直させる
        let (rows, out, steps, _) = e.apply(&Fake::default());
        assert_eq!(ps_steps(&steps), vec!["start", "wait", "event"], "{out}");
        assert!(
            out.contains("前の回は PowerToys の起動を確かめられなかったので"),
            "{out}"
        );
        assert!(!e.pending().exists());
        assert_eq!(last_kind(&rows), Kind::Ok);

        // エンジンが動かない・タスクが無い
        let e = Env::new();
        e.put(&e.global(), &global_settings(false, false, false));
        let f = Fake {
            wait: (0, "absent task".into()),
            ..Fake::default()
        };
        let (rows, out, steps, _) = e.apply(&f);
        assert_eq!(ps_steps(&steps), vec!["stop", "start", "wait"], "{out}");
        assert_eq!(rows.last().unwrap().kind, Kind::Manual);
        assert!(e.pending().exists());
        let e = Env::new();
        e.put(&e.global(), &global_settings(false, false, false));
        let f = Fake {
            wait: (0, "ready no-task".into()),
            ..Fake::default()
        };
        let (rows, out, steps, _) = e.apply(&f);
        // Keyboard Manager はオンなので読み直しへ進む
        assert_eq!(
            ps_steps(&steps),
            vec!["stop", "start", "wait", "event"],
            "{out}"
        );
        assert!(out.contains("自動起動のタスクがありません"), "{out}");
        assert_eq!(rows[0].kind, Kind::Manual);
        assert_eq!(last_kind(&rows), Kind::Ok);
        assert!(e.pending().exists());

        // 全体の設定が読めない: 触らずに手順を出す (5 回読む)
        let e = Env::new();
        e.put(&e.global(), "{\"startup\":tr");
        let (rows, out, steps, sleeps) = e.apply(&Fake::default());
        assert_eq!(ps_steps(&steps), Vec::<&str>::new(), "{out}");
        assert_eq!(sleeps, 5);
        assert_eq!(last_kind(&rows), Kind::Failed);
        assert!(out.contains("全体の設定を読めない"), "{out}");
    }

    #[test]
    fn waits_for_km_settings_after_restart() {
        // 起動した直後は、Keyboard Manager の settings.json ができるのを待ってから送る (待つときは記録を消す)
        let e = Env::new();
        e.apply(&Fake::default());
        assert!(e.record().exists());
        e.put(&e.global(), &global_settings(false, false, false));
        std::fs::remove_file(e.km_settings()).unwrap();
        let f = Fake {
            start_writes: Some(global_settings(true, true, false)),
            sleep_write: Some((3, KM_SETTINGS.into())),
            ..Fake::default()
        };
        let (rows, out, steps, sleeps) = e.apply(&f);
        assert!(out.contains("settings.json を作るのを待ちます"), "{out}");
        assert_eq!(sleeps, 3);
        // 前の記録が同じ sha でも送る
        assert_eq!(
            ps_steps(&steps),
            vec!["stop", "start", "wait", "event"],
            "{out}"
        );
        assert_eq!(last_kind(&rows), Kind::Ok);
        // 30 秒待っても無ければ案内する
        let e = Env::new();
        e.put(&e.global(), &global_settings(false, false, false));
        std::fs::remove_file(e.km_settings()).unwrap();
        let f = Fake {
            start_writes: Some(global_settings(true, true, false)),
            ..Fake::default()
        };
        let (rows, out, _, sleeps) = e.apply(&f);
        assert_eq!(sleeps, 30);
        assert_eq!(last_kind(&rows), Kind::Manual, "{out}");
        // 入れていなければ止める前には待たない
        let e = Env::new();
        std::fs::remove_file(e.km_settings()).unwrap();
        let (_, _, _, sleeps) = e.apply(&Fake::default());
        assert_eq!(sleeps, 0);
    }

    #[test]
    fn check_and_dry_run_touch_nothing() {
        for (global, f) in [
            (global_settings(false, false, false), Fake::default()),
            (global_settings(true, true, false), Fake::default()),
        ] {
            let e = Env::new();
            e.put(&e.global(), &global);
            for mode in [
                Mode::Check,
                Mode::DryRun { force: false },
                Mode::DryRun { force: true },
            ] {
                let (rows, out, steps, _) = e.run(&f, RUNNER_HOST, mode);
                assert_eq!(steps, vec!["check"], "{mode:?}: {out}");
                assert!(
                    rows.iter().any(|r| r.kind == Kind::Fix),
                    "{mode:?}: {rows:?}"
                );
                assert_eq!(e.read(&e.global()).unwrap(), global);
                assert!(!e.record().exists() && !e.pending().exists());
            }
        }
        // 受け持ちが WSL の間の check: runner の記録が無いのは、切り替えた後に読み直させると出す (✔)
        let e = Env::new();
        let (rows, out, steps, _) = e.run(&Fake::default(), WSL_HOST, Mode::Check);
        assert_eq!(steps, vec!["check"]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].kind, Kind::Ok, "{out}");
        assert!(out.contains("runner の記録はまだありません"), "{out}");
        // 流し直すコマンドは受け持ちで替える
        std::fs::remove_file(e.km_settings()).unwrap();
        let (rows, out, _, _) = e.run(&Fake::default(), WSL_HOST, Mode::Check);
        assert_eq!(rows[0].kind, Kind::Manual, "{out}");
        assert!(
            out.contains(
                "WSL の setup --update (か nix/scripts/bootstrap-windows-powertoys.sh) を流し直して"
            ),
            "{out}"
        );
        let (_, out, _, _) = e.run(&Fake::default(), RUNNER_HOST, Mode::Check);
        assert!(
            out.contains("dotfiles apply --steps powertoys を流し直して"),
            "{out}"
        );
    }

    /// SSH の会話の中の apply は、PowerToys に触らない (入れない・止めない・起こさない・送らない) で確かめるだけにし、manual を足す
    #[test]
    fn ssh_session_only_checks() {
        let e = Env::new();
        let g = global_settings(false, false, false);
        e.put(&e.global(), &g);
        let f = Fake {
            ssh: true,
            check: (3, MISSING_OUT.into()),
            ..Fake::default()
        };
        let (rows, out, steps, sleeps) = e.apply(&f);
        assert_eq!(steps, vec!["check"], "{out}");
        assert_eq!(sleeps, 0);
        assert!(out.contains("SSH の会話の中なので"), "{out}");
        let last = rows.last().unwrap();
        assert_eq!(last.kind, Kind::Manual, "{rows:?}");
        assert!(
            last.notes[0].contains("デスクトップの PowerShell"),
            "{:?}",
            last.notes
        );
        assert_eq!(e.read(&e.global()).unwrap(), g);
        assert!(!e.record().exists() && !e.pending().exists());
        // 揃っていても、読み直させた記録が無ければ送らずに知らせる (SSH からはイベントが見えない)
        let e = Env::new();
        let f = Fake {
            ssh: true,
            ..Fake::default()
        };
        let (rows, out, steps, _) = e.apply(&f);
        assert_eq!(steps, vec!["check"], "{out}");
        assert_eq!(rows.last().unwrap().kind, Kind::Manual);
        assert!(!e.record().exists());
        // check は SSH の会話でも同じ (manual を足さない)
        let (rows, _, _, _) = e.run(&f, RUNNER_HOST, Mode::Check);
        assert!(rows.iter().all(|r| r.kind != Kind::Manual), "{rows:?}");
    }

    /// check と dry-run は、印・記録・Keyboard Manager の settings.json の有無や全体の設定の形によらず何も書かず、-Check のほかの本文を流さない
    #[test]
    fn check_and_dry_run_matrix() {
        let sum = fsutil::sha256_bytes(DEFAULT_JSON.as_bytes());
        type Prep = Box<dyn Fn(&Env)>;
        let preps: Vec<(&str, Prep, Fake)> = vec![
            (
                "印 + 両方オン + 記録は同じ",
                Box::new(move |e: &Env| {
                    e.put(&e.pending(), "");
                    e.put(&e.record(), &format!("{sum}\n"));
                }),
                Fake::default(),
            ),
            (
                "印 + run_elevated",
                Box::new(|e: &Env| {
                    e.put(&e.pending(), "");
                    e.put(&e.global(), &global_settings(true, true, true));
                }),
                Fake::default(),
            ),
            (
                "印 + Keyboard Manager の settings.json が無い",
                Box::new(|e: &Env| {
                    e.put(&e.pending(), "");
                    std::fs::remove_file(e.km_settings()).unwrap();
                }),
                Fake::default(),
            ),
            (
                "入っていない + 全体の設定が無い",
                Box::new(|e: &Env| std::fs::remove_file(e.global()).unwrap()),
                Fake {
                    check: (3, MISSING_OUT.into()),
                    ..Fake::default()
                },
            ),
            (
                "自動起動だけオフ + 記録が違う",
                Box::new(|e: &Env| {
                    e.put(&e.global(), &global_settings(true, false, false));
                    e.put(&e.record(), "x\n");
                }),
                Fake::default(),
            ),
            (
                "run_elevated + オフ",
                Box::new(|e: &Env| e.put(&e.global(), &global_settings(false, true, true))),
                Fake::default(),
            ),
            (
                "全体の設定が読めない",
                Box::new(|e: &Env| e.put(&e.global(), "{")),
                Fake::default(),
            ),
        ];
        for (name, prep, fake) in &preps {
            for host in [RUNNER_HOST, WSL_HOST] {
                for mode in [
                    Mode::Check,
                    Mode::DryRun { force: false },
                    Mode::DryRun { force: true },
                ] {
                    let e = Env::new();
                    prep(&e);
                    let snap = |e: &Env| {
                        (
                            e.read(&e.global()),
                            e.read(&e.km_settings()),
                            e.read(&e.record()),
                            e.pending().exists(),
                        )
                    };
                    let before = snap(&e);
                    let (rows, out, steps, _) = e.run(fake, host, mode);
                    assert_eq!(snap(&e), before, "{name} {mode:?}\n{out}");
                    assert_eq!(steps, vec!["check"], "{name} {mode:?}\n{out}");
                    assert!(!rows.is_empty(), "{name} {mode:?}");
                }
            }
        }
        // 自動起動だけオフで記録も違うときは、起動し直す行があるので「止めない」とは言わない
        let e = Env::new();
        e.put(&e.global(), &global_settings(true, false, false));
        let (rows, _, _, _) = e.run(&Fake::default(), RUNNER_HOST, Mode::Check);
        assert_eq!(rows.len(), 2, "{rows:?}");
        assert!(!rows[1].text.contains("止めない"), "{rows:?}");
        let e = Env::new();
        let (rows, _, _, _) = e.run(&Fake::default(), RUNNER_HOST, Mode::Check);
        assert!(rows[0].text.contains("(PowerToys は止めない)"), "{rows:?}");
    }

    /// 時間切れ・起こせない PowerShell: -Check は確かめられなかったと出して進み、イベントは送れなかったとして記録しない
    #[test]
    fn timeouts_and_spawn_failures() {
        let run_with = |e: &Env, sys: &FakeSys| {
            let mut out = Vec::new();
            let rows = {
                let mut ctx = Ctx {
                    repo: e.t.path().join("dotfiles"),
                    roots: Roots::from_home(&e.t.path().join("win")),
                    state_dir: e.state(),
                    host: parse(
                        RUNNER_HOST,
                        Path::new("h.toml"),
                        Groups::embedded().unwrap(),
                    )
                    .unwrap(),
                    sys,
                    out: &mut out,
                };
                PowerToys.run(&mut ctx, APPLY)
            };
            (rows, String::from_utf8(out).unwrap())
        };
        let e = Env::new();
        let sys = FakeSys::new(|c| RunResult {
            exit: if ps1::decode_command(c).is_some() {
                Exit::SpawnFailed("見つからない".into())
            } else {
                Exit::TimedOut
            },
            output: vec![],
        })
        .with_program("pwsh", "/fake/pwsh")
        .with_program("powershell", "/fake/powershell");
        let (rows, out) = run_with(&e, &sys);
        assert_eq!(rows[0].kind, Kind::Failed, "{rows:?}");
        assert_eq!(
            rows[0].text,
            format!(
                "PowerShell で PowerToys が入っているかを確かめられなかった ({CHECK_SECS} 秒たっても終わらない。時間切れ)"
            )
        );
        assert_eq!(rows.last().unwrap().kind, Kind::Failed);
        assert!(
            rows.last().unwrap().text.contains("終了コード 127"),
            "{rows:?}"
        );
        assert!(out.contains("オフにしてオンに戻す"), "{out}");
        assert!(!e.record().exists());
        // -IfMissing が時間切れ: 知らせて読み直しへ進む
        let e = Env::new();
        let sys = FakeSys::new(|c| {
            let a = c.args_lossy().join(" ");
            RunResult {
                exit: if a.contains("-IfMissing") {
                    Exit::TimedOut
                } else if a.contains("-Check") {
                    Exit::Code(3)
                } else {
                    Exit::Code(0)
                },
                output: if a.contains("-Check") {
                    MISSING_OUT.lines().map(str::to_string).collect()
                } else {
                    vec!["set".into()]
                },
            }
        })
        .with_program("pwsh", "/fake/pwsh")
        .with_program("powershell", "/fake/powershell");
        let (rows, _) = run_with(&e, &sys);
        assert_eq!(rows[0].kind, Kind::Failed, "{rows:?}");
        assert!(
            rows[0]
                .text
                .contains(&format!("{INSTALL_SECS} 秒待っても終わらない")),
            "{rows:?}"
        );
        assert_eq!(rows.last().unwrap().kind, Kind::Ok, "{rows:?}");
    }

    /// PowerShell の本文・記録と印の名前・待つ秒数・判定の語が WSL の script と同じ (bash の版が流れない Windows の CI でも比べる)
    #[test]
    fn matches_the_wsl_script_text() {
        let text = std::fs::read_to_string(parity::repo_file(
            "nix/scripts/bootstrap-windows-powertoys.sh",
        ))
        .unwrap()
        .replace("\r\n", "\n");
        let info = PowerToys.info();
        assert!(
            text.lines()
                .any(|l| l == format!("# order: {}", info.order))
        );
        assert!(!text.lines().any(|l| l.starts_with("# tool: ")));
        for body in [PS_COMMON, PS_STOP, PS_START, PS_WAIT_KM] {
            assert!(
                text.contains(&format!("\n{body}\nEOS\n")),
                "WSL の script の本文と違う:\n{body}"
            );
        }
        assert!(text.contains(&format!("event={EVENT}\n")));
        assert!(text.contains(&format!(
            "record_file=\"${{HOME}}/.local/state/dotfiles/{RECORD_FILE}\""
        )));
        assert!(text.contains(&format!(
            "pending_file=\"${{HOME}}/.local/state/dotfiles/{PENDING_FILE}\""
        )));
        assert!(text.contains("ps=\"\\$h = \\$null; if ([System.Threading.EventWaitHandle]::TryOpenExisting('${event}', [ref]\\$h)) { [void]\\$h.Set(); \\$h.Dispose(); 'set' } else { 'absent' }\""));
        assert!(text.contains(&format!("timeout {CHECK_SECS} pwsh.exe")));
        assert!(text.contains(&format!("timeout {INSTALL_SECS} pwsh.exe")));
        assert!(text.contains("ps_out=$(timeout \"$1\" powershell.exe -NoProfile -NonInteractive -Command \"\\$ProgressPreference = 'SilentlyContinue'; $2\""));
        assert!(text.contains(&format!("run_ps {PS_SECS} \"${{ps}}\"")));
        assert!(text.contains(&format!("grep -qF '{HEADER}'")));
        assert!(text.contains(
            "km_dir=\"${windows_home}/AppData/Local/Microsoft/PowerToys/Keyboard Manager\""
        ));
        assert!(text.contains(&format!(
            "global_json=\"${{windows_home}}/AppData/Local/{GLOBAL_REL}\""
        )));
        assert!(text.contains("local tmp=\"${global_json}.dotfiles-tmp\" filter='.startup = true | .enabled[\"Keyboard Manager\"] = true'"));
        assert!(text.contains("jq -r '.properties.activeConfiguration.value // empty'"));
        assert!(text.contains("for ((i = 0; i < 30; i++)); do"));
        assert!(text.contains("for ((i = 0; i < 5; i++)); do"));
    }

    /// 本物の Windows PowerShell が、止める・起動する・イベントを送る本文を -EncodedCommand で流す (CI の windows-latest だけ。PowerToys が入って
    /// いるマシンでは流さない (止めてしまうため)。入っていなければ、本文は PowerToys.exe を探した所で no-exe で終わり、イベントも無い)
    #[cfg(windows)]
    #[test]
    fn real_powershell_runs_the_bodies_without_powertoys() {
        use crate::process::RealSys;
        let exe_at = |var: &str| {
            std::env::var(var)
                .map(|v| {
                    Path::new(&v)
                        .join("PowerToys")
                        .join("PowerToys.exe")
                        .exists()
                })
                .unwrap_or(false)
        };
        if std::env::var("CI").is_err() || exe_at("LOCALAPPDATA") || exe_at("ProgramFiles") {
            return;
        }
        let mut out = Vec::new();
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
            sys: &RealSys,
            out: &mut out,
        };
        assert_eq!(run_ps(&mut ctx, &ps_stop()), (0, "no-exe".to_string()));
        assert_eq!(run_ps(&mut ctx, &ps_start()), (0, "no-exe".to_string()));
        assert_eq!(run_ps(&mut ctx, &ps_event()), (0, "absent".to_string()));
    }

    /// 突き合わせに使う、要るコマンドだけを並べた PATH (本物の powershell.exe と pwsh.exe を見せない)
    #[cfg(unix)]
    fn sys_bin(dir: &Path) -> PathBuf {
        let bin = dir.join("sys-bin");
        std::fs::create_dir_all(&bin).unwrap();
        let path = std::env::var_os("PATH").unwrap_or_default();
        for c in [
            "env",
            "jq",
            "grep",
            "sed",
            "tr",
            "cat",
            "head",
            "tail",
            "cut",
            "mkdir",
            "dirname",
            "sha256sum",
            "timeout",
            "od",
            "mv",
            "rm",
            "touch",
            "bash",
        ] {
            let found = std::env::split_paths(&path)
                .filter(|d| !d.starts_with("/mnt"))
                .map(|d| d.join(c))
                .find(|p| p.is_file())
                .unwrap_or_else(|| panic!("{c} が無い"));
            std::os::unix::fs::symlink(found, bin.join(c)).unwrap();
        }
        bin
    }

    /// 偽の powershell.exe・pwsh.exe・wslpath・sleep を置く (WSL の試験と同じ分け方。受けた本文の種類を steps に、待った回数を sleeps に残す)
    #[cfg(unix)]
    fn fake_bin(root: &Path, bash: &Path) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let bin = root.join("fake-bin");
        std::fs::create_dir_all(&bin).unwrap();
        let shebang = format!("#!{}\n", bash.display());
        let scripts = [
            (
                "powershell.exe",
                r#"mkdir -p "${FAKE_LOG}/bodies"; printf '%s' "$4" >"${FAKE_LOG}/bodies/$(grep -c '' "${FAKE_LOG}/steps" 2>/dev/null || echo 0)"
case "$*" in
  *PToyTrayIconWindow*) step=stop; out=${FAKE_PS_STOP-stopped}; rc=${FAKE_PS_STOP_RC:-0} ;;
  *Start-Process*)
    step=start
    if [[ -n ${FAKE_START_WRITES-} ]]; then printf '%s' "${FAKE_START_WRITES}" >"${FAKE_GLOBAL}"; fi
    out=${FAKE_PS_START-started}; rc=${FAKE_PS_START_RC:-0} ;;
  *AddSeconds*) step=wait; out=${FAKE_PS_WAIT-ready task}; rc=${FAKE_PS_WAIT_RC:-0} ;;
  *) step=event; out=${FAKE_PS_OUT-set}; rc=${FAKE_PS_RC:-0} ;;
esac
printf '%s\n' "${step}" >>"${FAKE_LOG}/steps"
printf '%s\r\n' "${out}"
exit "${rc}"
"#,
            ),
            (
                "pwsh.exe",
                r#"case "$*" in
  *-IfMissing*) step=ifmissing; out=${FAKE_PWSH_OUT2-}; rc=${FAKE_PWSH_RC2:-0} ;;
  *) step=check; out=${FAKE_PWSH_OUT-}; rc=${FAKE_PWSH_RC:-0} ;;
esac
printf '%s\n' "${step}" >>"${FAKE_LOG}/steps"
if [[ -n ${out} ]]; then while IFS= read -r l; do printf '%s\r\n' "${l}"; done <<<"${out}"; fi
exit "${rc}"
"#,
            ),
            (
                "sleep",
                r#"printf '%s\n' "$*" >>"${FAKE_LOG}/sleeps"
if [[ -n ${FAKE_SLEEP_WRITE-} && $(grep -c '' "${FAKE_LOG}/sleeps") == "${FAKE_SLEEP_AT:-1}" ]]; then
  printf '%s' "${FAKE_SLEEP_WRITE}" >"${FAKE_KM}"
fi
exit 0
"#,
            ),
            (
                "wslpath",
                r#"[[ $1 == -w ]] || exit 1
printf 'C:\\fake\\%s\n' "${2##*/}"
"#,
            ),
        ];
        for (name, body) in scripts {
            let p = bin.join(name);
            std::fs::write(&p, format!("{shebang}{body}")).unwrap();
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        bin
    }

    /// WSL の script を、使い捨ての HOME (`<root>/wsl`)・Windows のホーム (`<root>/win`) で流す (偽の Windows のコマンドと、本物の bash・jq)。
    /// 受けた本文の種類 (順) と待った回数を返す
    #[cfg(unix)]
    fn wsl_run(e: &Env, fake: &Fake, args: &[&str]) -> (i32, String, Vec<String>, usize) {
        let root = e.t.path();
        let state = root.join("wsl/.local/state/dotfiles/windows-files.json");
        if !state.exists() {
            std::fs::create_dir_all(state.parent().unwrap()).unwrap();
            std::fs::write(
                &state,
                serde_json::json!({"enable": true, "version": 1, "windowsHome": root.join("win")})
                    .to_string(),
            )
            .unwrap();
            // WSL は配った Install-PowerToys.ps1 があるときだけ入っているかを確かめる
            e.put(
                &root.join("win/.config/powershell/Install-PowerToys.ps1"),
                "# Install-PowerToys.ps1\n",
            );
        }
        let sys = sys_bin(&root.join(format!("bin-{}", std::process::id())));
        let bash = sys.join("bash");
        let fakes = fake_bin(root, &bash);
        let log = root.join("log");
        let _ = std::fs::remove_dir_all(&log);
        std::fs::create_dir_all(&log).unwrap();
        let mut c = std::process::Command::new(&bash);
        c.arg(parity::repo_file(
            "nix/scripts/bootstrap-windows-powertoys.sh",
        ))
        .args(args)
        .env_clear()
        .env("HOME", root.join("wsl"))
        .env("PATH", format!("{}:{}", fakes.display(), sys.display()))
        .env("FAKE_LOG", &log)
        .env("FAKE_GLOBAL", e.global())
        .env(
            "FAKE_KM",
            if fake.sleep_global {
                e.global()
            } else {
                e.km_settings()
            },
        )
        .env("FAKE_PWSH_OUT", &fake.check.1)
        .env("FAKE_PWSH_RC", fake.check.0.to_string())
        .env("FAKE_PWSH_OUT2", &fake.install.1)
        .env("FAKE_PWSH_RC2", fake.install.0.to_string())
        .env("FAKE_PS_STOP", &fake.stop.1)
        .env("FAKE_PS_STOP_RC", fake.stop.0.to_string())
        .env("FAKE_PS_START", &fake.start.1)
        .env("FAKE_PS_START_RC", fake.start.0.to_string())
        .env("FAKE_PS_WAIT", &fake.wait.1)
        .env("FAKE_PS_WAIT_RC", fake.wait.0.to_string())
        .env("FAKE_PS_OUT", &fake.event.1)
        .env("FAKE_PS_RC", fake.event.0.to_string())
        .stdin(std::process::Stdio::null());
        if let Some(w) = &fake.start_writes {
            c.env("FAKE_START_WRITES", w);
        }
        if let Some((at, content)) = &fake.sleep_write {
            c.env("FAKE_SLEEP_AT", at.to_string())
                .env("FAKE_SLEEP_WRITE", content);
        }
        let o = c.output().unwrap();
        let _ = std::fs::remove_dir_all(root.join(format!("bin-{}", std::process::id())));
        let lines = |name: &str| -> Vec<String> {
            std::fs::read_to_string(log.join(name))
                .map(|t| t.lines().map(str::to_string).collect())
                .unwrap_or_default()
        };
        (
            o.status.code().unwrap_or(-1),
            format!(
                "{}{}",
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            ),
            lines("steps"),
            lines("sleeps").len(),
        )
    }

    /// WSL の script (偽の powershell.exe・pwsh.exe・sleep と本物の bash・jq) と同じ状態から流し、同じ順に止める・起こす・待つ・送る・入れる。
    /// 全体の設定・記録・印も同じ。bash・jq が無ければ飛ばし、CI の Linux の job は飛ばさない
    #[cfg(unix)]
    #[test]
    fn does_what_the_wsl_script_does() {
        if !parity::available() {
            return;
        }
        type Prep = Box<dyn Fn(&Env)>;
        let off = |km: bool, startup: bool, elevated: bool| -> Prep {
            Box::new(move |e: &Env| e.put(&e.global(), &global_settings(km, startup, elevated)))
        };
        let on_after_start = Some(global_settings(true, true, false));
        // 前の回が書いた後に起動や確認でつまずいた (印がある。WSL の印も置く)
        let pending = |km: bool, startup: bool, elevated: bool| -> Prep {
            Box::new(move |e: &Env| {
                e.put(&e.global(), &global_settings(km, startup, elevated));
                e.put(&e.pending(), "");
                e.put(
                    &e.t.path()
                        .join("wsl/.local/state/dotfiles")
                        .join(PENDING_FILE),
                    "",
                );
            })
        };
        let cases: Vec<(&str, Prep, Fake)> = vec![
            ("送れた", Box::new(|_| {}), Fake::default()),
            (
                "動いていない",
                Box::new(|_| {}),
                Fake {
                    event: (0, "absent".into()),
                    ..Fake::default()
                },
            ),
            (
                "送れない",
                Box::new(|_| {}),
                Fake {
                    event: (126, "".into()),
                    ..Fake::default()
                },
            ),
            (
                "両方オフ",
                off(false, false, false),
                Fake {
                    start_writes: on_after_start.clone(),
                    ..Fake::default()
                },
            ),
            ("自動起動だけオフ", off(true, false, false), Fake::default()),
            (
                "全体の設定が無い",
                Box::new(|e: &Env| std::fs::remove_file(e.global()).unwrap()),
                Fake {
                    stop: (0, "not-running".into()),
                    ..Fake::default()
                },
            ),
            ("run_elevated", off(false, false, true), Fake::default()),
            (
                "止められない",
                off(false, false, false),
                Fake {
                    stop: (0, "still-running".into()),
                    ..Fake::default()
                },
            ),
            (
                "止める途中で落ちる",
                off(false, true, false),
                Fake {
                    stop: (1, "".into()),
                    ..Fake::default()
                },
            ),
            (
                "起動できない",
                off(false, false, false),
                Fake {
                    start: (1, "".into()),
                    ..Fake::default()
                },
            ),
            (
                "エンジンが動かない",
                off(false, false, false),
                Fake {
                    wait: (0, "absent task".into()),
                    ..Fake::default()
                },
            ),
            (
                "タスクが無い",
                off(false, false, false),
                Fake {
                    wait: (0, "ready no-task".into()),
                    ..Fake::default()
                },
            ),
            (
                "起動の後もオフ",
                off(false, false, false),
                Fake {
                    start_writes: Some(global_settings(true, false, false)),
                    ..Fake::default()
                },
            ),
            (
                "全体の設定が読めない",
                Box::new(|e: &Env| e.put(&e.global(), "{")),
                Fake::default(),
            ),
            (
                "settings.json が無い",
                Box::new(|e: &Env| std::fs::remove_file(e.km_settings()).unwrap()),
                Fake::default(),
            ),
            (
                "プロファイルが work",
                Box::new(|e: &Env| {
                    e.put(
                        &e.km_settings(),
                        r#"{"properties":{"activeConfiguration":{"value":"work"}}}"#,
                    )
                }),
                Fake::default(),
            ),
            (
                "入っていない",
                Box::new(|_| {}),
                Fake {
                    check: (3, MISSING_OUT.into()),
                    install: (0, "ok".into()),
                    ..Fake::default()
                },
            ),
            (
                "入れた直後に settings.json を待つ",
                Box::new(|e: &Env| std::fs::remove_file(e.km_settings()).unwrap()),
                Fake {
                    check: (3, MISSING_OUT.into()),
                    sleep_write: Some((4, KM_SETTINGS.into())),
                    ..Fake::default()
                },
            ),
            (
                "起動した直後に settings.json を待つ",
                Box::new(|e: &Env| {
                    std::fs::remove_file(e.km_settings()).unwrap();
                    e.put(&e.global(), &global_settings(false, false, false));
                }),
                Fake {
                    start_writes: on_after_start.clone(),
                    sleep_write: Some((2, KM_SETTINGS.into())),
                    ..Fake::default()
                },
            ),
            (
                "入れられない",
                Box::new(|_| {}),
                Fake {
                    check: (3, MISSING_OUT.into()),
                    install: (1, "x".into()),
                    ..Fake::default()
                },
            ),
            (
                "確かめられない",
                Box::new(|_| {}),
                Fake {
                    check: (2, "".into()),
                    ..Fake::default()
                },
            ),
            (
                "Keyboard Manager はオンで止められない",
                off(true, false, false),
                Fake {
                    stop: (0, "still-running".into()),
                    ..Fake::default()
                },
            ),
            (
                "Keyboard Manager はオンで止める途中で落ちる",
                off(true, false, false),
                Fake {
                    stop: (1, "boom".into()),
                    ..Fake::default()
                },
            ),
            (
                "PowerToys が見つからない",
                off(false, false, false),
                Fake {
                    stop: (0, "no-exe".into()),
                    ..Fake::default()
                },
            ),
            (
                "PowerToys が見つからない (Keyboard Manager はオン)",
                off(true, false, false),
                Fake {
                    stop: (0, "no-exe".into()),
                    ..Fake::default()
                },
            ),
            (
                "エンジンを確かめられない",
                off(false, false, false),
                Fake {
                    wait: (1, "err".into()),
                    ..Fake::default()
                },
            ),
            (
                "起動の後に Keyboard Manager がオフ",
                off(false, false, false),
                Fake {
                    start_writes: Some(global_settings(false, true, false)),
                    ..Fake::default()
                },
            ),
            (
                "印と run_elevated",
                pending(true, true, true),
                Fake::default(),
            ),
            (
                "印があって起動できない",
                pending(true, true, false),
                Fake {
                    start: (1, "x".into()),
                    ..Fake::default()
                },
            ),
            (
                "止める出力に余計な行",
                off(false, false, false),
                Fake {
                    stop: (0, "WARNING: x\nstopped".into()),
                    ..Fake::default()
                },
            ),
            (
                "全体の設定が null",
                Box::new(|e: &Env| e.put(&e.global(), "null")),
                Fake::default(),
            ),
            (
                "全体の設定が配列",
                Box::new(|e: &Env| e.put(&e.global(), "[]")),
                Fake::default(),
            ),
            (
                "enabled が文字列",
                Box::new(|e: &Env| e.put(&e.global(), r#"{"enabled":"x","startup":true}"#)),
                Fake::default(),
            ),
            (
                "enabled が null",
                Box::new(|e: &Env| e.put(&e.global(), r#"{"enabled":null,"startup":true}"#)),
                Fake::default(),
            ),
            (
                "全体の設定が空",
                Box::new(|e: &Env| e.put(&e.global(), "")),
                Fake::default(),
            ),
            (
                "全体の設定が BOM つき",
                Box::new(|e: &Env| {
                    e.put(
                        &e.global(),
                        &format!("\u{feff}{}", global_settings(false, true, false)),
                    )
                }),
                Fake::default(),
            ),
            (
                "全体の設定に同じキー",
                Box::new(|e: &Env| {
                    e.put(
                        &e.global(),
                        r#"{"startup":true,"enabled":{"Keyboard Manager":true},"startup":false}"#,
                    )
                }),
                Fake::default(),
            ),
            (
                "全体の設定が CRLF つき",
                Box::new(|e: &Env| {
                    e.put(
                        &e.global(),
                        &format!("{}\r\n", global_settings(false, true, false)),
                    )
                }),
                Fake::default(),
            ),
            (
                "全体の設定に数や逃がした字がある",
                Box::new(|e: &Env| {
                    e.put(
                        &e.global(),
                        r#"{"startup":false,"enabled":{"AdvancedPaste":true,"Keyboard Manager":false},"run_elevated":false,"theme":"system","ratio":1.50,"big":12345678901234567890,"neg":-0,"exp":1e2,"small":0.0000001,"esc":"a\u002Bb&c\/d\u00e9日","ctl":"\u0001\t","empty_obj":{},"empty_arr":[]}"#,
                    )
                }),
                Fake::default(),
            ),
            (
                "KM の value が配列",
                Box::new(|e: &Env| {
                    e.put(
                        &e.km_settings(),
                        r#"{"properties":{"activeConfiguration":{"value":["default"]}}}"#,
                    )
                }),
                Fake::default(),
            ),
            (
                "KM の properties が文字列",
                Box::new(|e: &Env| e.put(&e.km_settings(), r#"{"properties":"x"}"#)),
                Fake::default(),
            ),
            (
                "KM の settings が BOM つき",
                Box::new(|e: &Env| e.put(&e.km_settings(), &format!("\u{feff}{KM_SETTINGS}"))),
                Fake::default(),
            ),
            (
                "KM の value が空の文字列",
                Box::new(|e: &Env| {
                    e.put(
                        &e.km_settings(),
                        r#"{"properties":{"activeConfiguration":{"value":""}}}"#,
                    )
                }),
                Fake::default(),
            ),
            (
                "KM の value が true",
                Box::new(|e: &Env| {
                    e.put(
                        &e.km_settings(),
                        r#"{"properties":{"activeConfiguration":{"value":true}}}"#,
                    )
                }),
                Fake::default(),
            ),
            (
                "入口で全体の設定を読みかけ",
                Box::new(|e: &Env| e.put(&e.global(), "{\"startup\":tr")),
                Fake {
                    sleep_write: Some((1, global_settings(true, true, false))),
                    sleep_global: true,
                    ..Fake::default()
                },
            ),
            (
                "起動の後に全体の設定を読みかけ",
                off(false, false, false),
                Fake {
                    start_writes: Some("{\"startup\":tr".into()),
                    sleep_write: Some((1, global_settings(true, true, false))),
                    sleep_global: true,
                    ..Fake::default()
                },
            ),
            (
                "Keyboard Manager の settings.json が書きかけ",
                Box::new(|e: &Env| {
                    e.put(&e.km_settings(), "{\"properties\":");
                    e.put(&e.global(), &global_settings(false, false, false));
                }),
                Fake {
                    start_writes: Some(global_settings(true, true, false)),
                    sleep_write: Some((5, KM_SETTINGS.into())),
                    ..Fake::default()
                },
            ),
        ];
        for (name, prep, fake) in &cases {
            let wsl = Env::new();
            let ours = Env::new();
            prep(&wsl);
            prep(&ours);
            same_as_wsl(name, &wsl, &ours, fake, &[]);
            // 2 回目 (印が残った回のやり直し・読み直し済み) も同じ
            same_as_wsl(
                &format!("{name} (2 回目)"),
                &wsl,
                &ours,
                &Fake::default(),
                &[],
            );
        }
        // --force も同じ
        let wsl = Env::new();
        let ours = Env::new();
        same_as_wsl("1 回目", &wsl, &ours, &Fake::default(), &[]);
        same_as_wsl("--force", &wsl, &ours, &Fake::default(), &["--force"]);
        // 書けない: 全体の設定の置き場を書けなくする
        {
            use std::os::unix::fs::PermissionsExt;
            let wsl = Env::new();
            let ours = Env::new();
            for e in [&wsl, &ours] {
                e.put(&e.global(), &global_settings(false, false, false));
                let dir = e.global().parent().unwrap().to_path_buf();
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o555)).unwrap();
            }
            same_as_wsl("書けない", &wsl, &ours, &Fake::default(), &[]);
            for e in [&wsl, &ours] {
                let dir = e.global().parent().unwrap().to_path_buf();
                std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
        }
    }

    /// WSL の script と runner を同じ答えで 1 回ずつ流し、受けた本文の種類と本文 (バイト単位)・待った回数・全体の設定・記録・印が同じかを見る
    #[cfg(unix)]
    fn same_as_wsl(name: &str, wsl: &Env, ours: &Env, fake: &Fake, args: &[&str]) {
        let (code, wsl_out, wsl_steps, wsl_sleeps) = wsl_run(wsl, fake, args);
        assert!(code == 0, "{name}: {wsl_out}");
        let mode = Mode::Apply {
            force: args.contains(&"--force"),
        };
        let (_, out, steps, sleeps, bodies) = ours.run_full(fake, RUNNER_HOST, mode);
        let ctx = format!("{name}:\n--- WSL\n{wsl_out}\n--- runner\n{out}");
        assert_eq!(steps, wsl_steps, "{ctx}");
        assert_eq!(sleeps, wsl_sleeps, "{ctx}");
        // WSL が powershell.exe -Command に渡した本文と、runner が -EncodedCommand に渡した本文が同じ
        let log = wsl.t.path().join("log").join("bodies");
        let mut idx: Vec<usize> = std::fs::read_dir(&log)
            .map(|d| {
                d.map(|e| e.unwrap().file_name().to_string_lossy().parse().unwrap())
                    .collect()
            })
            .unwrap_or_default();
        idx.sort();
        let wsl_bodies: Vec<String> = idx
            .iter()
            .map(|i| std::fs::read_to_string(log.join(i.to_string())).unwrap())
            .collect();
        assert_eq!(bodies, wsl_bodies, "{ctx}");
        let wsl_state = wsl.t.path().join("wsl/.local/state/dotfiles");
        assert_eq!(ours.read(&ours.global()), wsl.read(&wsl.global()), "{ctx}");
        assert_eq!(
            ours.read(&ours.record()),
            wsl.read(&wsl_state.join(RECORD_FILE)),
            "{ctx}"
        );
        assert_eq!(
            ours.pending().exists(),
            wsl_state.join(PENDING_FILE).exists(),
            "{ctx}"
        );
    }
}
