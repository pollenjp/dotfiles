//! t3-code-settings (order 98): Windows の T3 Code (道具の switch `windowsT3Code`) の、テレメトリを切るユーザー環境変数
//! (`T3CODE_TELEMETRY_ENABLED=false`) と、`%USERPROFILE%\.t3\userdata\settings.json` の決めたキーを合わせる。Windows にしか無い手順
//! (dotfiles-private の docs/adr/091_t3_code_opt_in_*)。T3 Code を入れるのは手順 t3-code (`Install-T3Code.ps1`)。
//!
//! ## 環境変数
//!
//! `[Environment]::GetEnvironmentVariable(…, 'User')` で読み、違えば `SetEnvironmentVariable(…, 'User')` で書く (動いているプログラムに
//! 環境変数が変わったことを知らせる)。PowerShell で触る (runner は OS の API を外のコマンドで呼ぶ)。名前と値は env で渡し、script は ASCII
//! だけにする (`user_path` と同じ)。動いている T3 Code には効かないので、書いたら開き直すよう出す。
//!
//! ## settings.json
//!
//! T3 Code も書くファイルなので、決めたキーだけを合わせ、ほかのキーと順を残す (順を保つ JSON の型 `ojson`)。決まりは Linux の
//! `nix/scripts/bootstrap-t3-code.sh` と同じで、値は 1 か所 (`nix/files/t3-code/managed-settings.json`) から読む (`launchArgs` だけは Windows
//! だけの決まりで、値はこの PC の置き先で決まる):
//!
//! - `providerInstances.claudeAgent.driver` と `config.homePath` を上書きする (`config` のほかのキーは残す)
//! - `providerInstances.claudeAgent.config.launchArgs` (T3 の Launch arguments): 手順 claude-t3 が出す文 (`claude_t3::launch_args`。claude-t3 の
//!   置き先 `%USERPROFILE%\.claude\t3\` の 2 つのファイルを指す) に合わせる。値ごと合わせるので、T3 の画面で変えても次の apply で戻る。置き先に
//!   2 つのファイルがそろっていなければ書かず、今の値を残して締めの行の ※ で知らせる (T3 は読めないファイルを渡されると送信を失敗にする)。
//!   check と dry-run は、置き先にまだ無くても、同じ apply で claude-t3 (order 50) が置けるなら (道具の switch `windowsClaudeCode` が on で、repo の
//!   ファイルが読める) 置いた後の値で比べる (dotfiles-private の docs/adr/090_win_claude_t3_launch_args_*。Linux に claude-t3 は無いので、Linux の
//!   setup は書かない)
//! - `providerInstances.claudeAgent.environment`: ホストの値の `[t3Code] clearClaudeEntrypoint` が true なら、`entrypointEnvironment` と
//!   同じ名前の要素を、最初の位置で 1 つに置き換える (無ければ末尾に足す)。false なら同じ名前の要素を外す (配列が無ければ作らない)
//! - `defaultModelSelection` (丸ごと)・`defaultThreadEnvMode` を上書きする
//!
//! キーの順を見ずに同じなら書かない。書く前に前の中身を `%LOCALAPPDATA%\dotfiles\state\t3-code-settings\backup\` に写す (いちばん古いものと、
//! 新しい方から 10 個)。無ければ合わせるキーだけで作る。壊れている・object でない・合わせるキーの型が違うなら書かない。
//!
//! claude-t3 のログイン (`%USERPROFILE%\.claude-t3\.credentials.json`) が無ければ、手でログインする案内を添える (中身は読まない)。

use super::claude_t3;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::ojson::OValue;
use crate::process::{CommandSpec, Sys};
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// settings.json に合わせる値 (Linux の home/modules/t3-code.nix も読む 1 か所)
const MANAGED: &str = include_str!("../../../../nix/files/t3-code/managed-settings.json");

/// テレメトリを切るユーザー環境変数と値
pub const TELEMETRY_VAR: &str = "T3CODE_TELEMETRY_ENABLED";
pub const TELEMETRY_VALUE: &str = "false";

/// 書く前の settings.json を写す数
const BACKUPS: usize = 10;

/// ユーザー環境変数 `DOTFILES_ENV_NAME` を読み、無ければ `none`、あれば `value=<値>` の 1 行を出す。誤りなら 1 で終わる
const READ_SCRIPT: &str = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ErrorActionPreference = 'Stop'; try { $v = [Environment]::GetEnvironmentVariable([string]$env:DOTFILES_ENV_NAME, 'User'); if ($null -eq $v) { Write-Output 'none' } else { Write-Output ('value=' + $v) } } catch { Write-Output ('error: ' + $_.Exception.Message); exit 1 }";

/// ユーザー環境変数 `DOTFILES_ENV_NAME` を `DOTFILES_ENV_VALUE` にする (動いているプログラムに知らせる)。誤りなら 1 で終わる
const WRITE_SCRIPT: &str = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ErrorActionPreference = 'Stop'; try { [Environment]::SetEnvironmentVariable([string]$env:DOTFILES_ENV_NAME, [string]$env:DOTFILES_ENV_VALUE, 'User'); exit 0 } catch { Write-Output ('error: ' + $_.Exception.Message); exit 1 }";

pub struct T3CodeSettings;

impl Step for T3CodeSettings {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "t3-code-settings",
            order: 98,
            title: "T3 Code のテレメトリを切る環境変数と、settings.json の Claude の home・Launch arguments・新しいスレッドの既定を合わせる",
            gate: Gate::Tool("windowsT3Code"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let mut settings = settings_row(ctx, mode);
        let creds = ctx
            .roots
            .user_profile
            .join(".claude-t3")
            .join(".credentials.json");
        if !creds.is_file() {
            settings = settings.note(format!(
                "※ T3 Code の Claude (CLAUDE_CONFIG_DIR = {}) にログインしていない。T3 の Settings → Providers → Claude からログインする (win/README.md の「T3 Code」)",
                ctx.roots.user_profile.join(".claude-t3").display()
            ));
        }
        vec![telemetry_row(ctx, mode), settings]
    }
}

fn powershell(shell: &Path, script: &str) -> CommandSpec {
    CommandSpec::new(shell)
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(script)
        .timeout(Duration::from_secs(60))
}

/// ユーザー環境変数を読む (無ければ None)。
pub fn read_user_env(sys: &dyn Sys, shell: &Path, name: &str) -> Result<Option<String>, String> {
    let r = sys.run(
        &powershell(shell, READ_SCRIPT).env("DOTFILES_ENV_NAME", name),
        &mut |_| {},
    );
    if r.code() != Some(0) {
        return Err(format!(
            "ユーザー環境変数 {name} を読めない ({:?}): {}",
            r.exit,
            r.output.join(" / ")
        ));
    }
    if r.output.iter().any(|l| l == "none") {
        return Ok(None);
    }
    r.output
        .iter()
        .find_map(|l| l.strip_prefix("value=").map(|v| Some(v.to_string())))
        .ok_or_else(|| {
            format!(
                "ユーザー環境変数 {name} を読めない (none か value= の行が無い): {}",
                r.output.join(" / ")
            )
        })
}

/// ユーザー環境変数を書く。
pub fn write_user_env(sys: &dyn Sys, shell: &Path, name: &str, value: &str) -> Result<(), String> {
    let spec = powershell(shell, WRITE_SCRIPT)
        .env("DOTFILES_ENV_NAME", name)
        .env("DOTFILES_ENV_VALUE", value);
    let r = sys.run(&spec, &mut |_| {});
    if r.code() == Some(0) {
        Ok(())
    } else {
        Err(format!(
            "ユーザー環境変数 {name} を書けない ({:?}): {}",
            r.exit,
            r.output.join(" / ")
        ))
    }
}

fn telemetry_row(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let want = format!("{TELEMETRY_VAR}={TELEMETRY_VALUE}");
    let Some(shell) = super::ps1::find_powershell(ctx) else {
        return Outcome::new(
            Kind::Failed,
            format!(
                "PowerShell が見つからない (pwsh・powershell) ので、ユーザー環境変数 {TELEMETRY_VAR} を確かめられない"
            ),
        );
    };
    let cur = match read_user_env(ctx.sys, &shell, TELEMETRY_VAR) {
        Ok(v) => v,
        Err(e) => return Outcome::new(Kind::Failed, e),
    };
    if cur.as_deref() == Some(TELEMETRY_VALUE) {
        ctx.say(format!("登録済みです: ユーザー環境変数 {want}"));
        return Outcome::new(
            Kind::Ok,
            format!("ユーザー環境変数 {want} (T3 Code のテレメトリを切る) は登録済み"),
        );
    }
    let shown = match &cur {
        Some(v) => format!("今は {v}"),
        None => "無い".to_string(),
    };
    let kind = if cur.is_some() {
        Kind::Fix
    } else {
        Kind::Missing
    };
    match mode {
        Mode::Check => {
            ctx.say(format!(
                "ユーザー環境変数 {want} を書く (apply で。{shown})"
            ));
            Outcome::new(
                kind,
                format!(
                    "ユーザー環境変数 {TELEMETRY_VAR} が {TELEMETRY_VALUE} でない ({shown}) → apply で書く"
                ),
            )
        }
        Mode::DryRun { .. } => {
            ctx.say(format!(
                "[dry-run] ユーザー環境変数 {want} を書く ({shown})"
            ));
            Outcome::new(kind, format!("[dry-run] ユーザー環境変数 {want} を書く"))
        }
        Mode::Apply { .. } => {
            match write_user_env(ctx.sys, &shell, TELEMETRY_VAR, TELEMETRY_VALUE) {
                Ok(()) => {
                    ctx.say(format!("登録しました: ユーザー環境変数 {want}"));
                    ctx.say("動いている T3 Code には効かない。T3 Code を開き直す (タスクトレイからも終える)");
                    Outcome::new(
                        Kind::Ok,
                        format!("ユーザー環境変数 {want} を書いた (T3 Code を開き直すと効く)"),
                    )
                }
                Err(e) => Outcome::new(Kind::Failed, e),
            }
        }
    }
}

/// settings.json の置き場
pub fn settings_path(ctx: &Ctx) -> PathBuf {
    ctx.roots
        .user_profile
        .join(".t3")
        .join("userdata")
        .join("settings.json")
}

fn settings_row(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let path = settings_path(ctx);
    let shown = path.display().to_string();
    let (before, existed) = match std::fs::read_to_string(&path) {
        Ok(text) => match OValue::parse(&text) {
            Ok(v @ OValue::Object(_)) => (v, true),
            Ok(_) => {
                return Outcome::new(
                    Kind::Failed,
                    format!("{shown} が object でない (中身が {{…}} でない) → 手で直す"),
                );
            }
            Err(e) => {
                return Outcome::new(
                    Kind::Failed,
                    format!("{shown} が JSON として壊れている → 手で直す ({e})"),
                );
            }
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (OValue::Object(Vec::new()), false),
        Err(e) => return Outcome::new(Kind::Failed, format!("{shown} が読めない ({e})")),
    };
    let launch = launch_args_plan(ctx, mode);
    let after = match merged(&before, ctx.host.t3_clear_claude_entrypoint, launch.value()) {
        Ok(v) => v,
        Err(why) => return Outcome::new(Kind::Failed, format!("{shown}: {why} → 手で直す")),
    };
    let row = write_settings(ctx, mode, &path, &before, existed, &after);
    match launch.note() {
        Some(n) => row.note(n),
        None => row,
    }
}

/// `launchArgs` (T3 の Launch arguments) の合わせ方 (dotfiles-private の docs/adr/090_win_claude_t3_launch_args_*)
enum LaunchArgs {
    /// claude-t3 の置き先に 2 つのファイルがそろっている: この値に合わせる
    Set(String),
    /// check・dry-run で、置き先にはまだ無いが、同じ apply で claude-t3 (order 50) が先に置ける: 置いた後の値で比べる (知らせる文つき)
    AfterPlace(String, String),
    /// 置き先に 2 つのファイルがそろっていない: 書かない (今の値を残す)。知らせる文つき
    Keep(String),
}

impl LaunchArgs {
    /// 合わせる値 (None は今の値を残す)
    fn value(&self) -> Option<&str> {
        match self {
            LaunchArgs::Set(v) | LaunchArgs::AfterPlace(v, _) => Some(v),
            LaunchArgs::Keep(_) => None,
        }
    }

    /// 締めの行に添える文
    fn note(&self) -> Option<&str> {
        match self {
            LaunchArgs::Set(_) => None,
            LaunchArgs::AfterPlace(_, n) | LaunchArgs::Keep(n) => Some(n),
        }
    }
}

/// `launchArgs` をどう合わせるか。値は claude-t3 が出す文 (置き先の絶対パス)。置き先に 2 つのファイルがそろっていなければ書かない (T3 は読めない
/// ファイルを渡されると送信を失敗にする)。check と dry-run は、まだ無くても、同じ apply で claude-t3 が置けるなら (道具の switch
/// `windowsClaudeCode` が on で、repo のファイルが読める) 置いた後の値で比べる。
fn launch_args_plan(ctx: &Ctx, mode: Mode) -> LaunchArgs {
    let dir = claude_t3::t3_dir(ctx);
    let value = claude_t3::launch_args(&dir);
    let missing: Vec<&str> = claude_t3::FILES
        .into_iter()
        .filter(|f| !dir.join(f).is_file())
        .collect();
    if missing.is_empty() {
        return LaunchArgs::Set(value);
    }
    let missing = missing.join("・");
    let claude_code = ctx.host.tool("windowsClaudeCode");
    let root = ctx.repo_path(claude_t3::SOURCE);
    let placeable = claude_code
        && claude_t3::FILES
            .into_iter()
            .all(|f| claude_t3::read_source(&root, f).is_ok());
    if !mode.writes() && placeable {
        return LaunchArgs::AfterPlace(
            value,
            format!(
                "launchArgs (T3 の Launch arguments) は、claude-t3 が {} に {missing} を置いてから書く (apply では claude-t3 が先に流れる)",
                dir.display()
            ),
        );
    }
    let how = if claude_code {
        "dotfiles apply で claude-t3 が置いてから、もう一度 apply する"
    } else {
        "置くのは道具の switch windowsClaudeCode の手順 claude-t3"
    };
    LaunchArgs::Keep(format!(
        "{} に {missing} が無いので、launchArgs (T3 の Launch arguments) は書かない (今の値を残す)。{how}",
        dir.display()
    ))
}

/// 合わせた中身を書く (check と dry-run は書かない)。
fn write_settings(
    ctx: &mut Ctx,
    mode: Mode,
    path: &Path,
    before: &OValue,
    existed: bool,
    after: &OValue,
) -> Outcome {
    let shown = path.display().to_string();
    if existed && before.to_value() == after.to_value() {
        ctx.say(format!("登録済みです: {shown} の決めたキー"));
        return Outcome::new(
            Kind::Ok,
            "T3 Code の settings.json の決めたキー (Claude の home・Launch arguments・新しいスレッドの既定) は登録済み",
        );
    }
    let kind = if existed { Kind::Fix } else { Kind::Missing };
    match mode {
        Mode::Check => {
            ctx.say(format!("決めたキーを書く (apply で): {shown}"));
            Outcome::new(
                kind,
                "T3 Code の settings.json の決めたキーが無い・違う → apply で書く",
            )
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] 決めたキーを書く: {shown}"));
            Outcome::new(
                kind,
                "[dry-run] T3 Code の settings.json の決めたキーを書く",
            )
        }
        Mode::Apply { .. } => {
            if existed {
                let dir = ctx.state_dir.join("t3-code-settings").join("backup");
                match fsutil::backup_copy(path, &dir, "settings", BACKUPS) {
                    Ok(copied) => ctx.say(format!("前の中身を写しました: {}", copied.display())),
                    Err(e) => {
                        return Outcome::new(
                            Kind::Failed,
                            format!("{shown} を控えに写せないので書かない ({e})"),
                        );
                    }
                }
            }
            match fsutil::write_atomic(path, after.to_pretty().as_bytes()) {
                Ok(()) => {
                    ctx.say(format!("登録しました: {shown} の決めたキー"));
                    ctx.say("動いている T3 Code が読み直さないことがある。T3 Code を開き直す");
                    Outcome::new(
                        Kind::Ok,
                        "T3 Code の settings.json の決めたキーを書いた (T3 Code を開き直すと効く)",
                    )
                }
                Err(e) => Outcome::new(Kind::Failed, format!("{shown} を書けない ({e})")),
            }
        }
    }
}

/// 合わせる値 (`managed-settings.json`)。
fn managed() -> OValue {
    OValue::parse(MANAGED).expect("nix/files/t3-code/managed-settings.json は JSON")
}

fn managed_at<'a>(m: &'a OValue, path: &[&str]) -> &'a OValue {
    path.iter()
        .try_fold(m, |v, k| v.get(k))
        .unwrap_or_else(|| panic!("managed-settings.json に {} が無い", path.join(".")))
}

/// object の子 `key` の object を、無ければ (null も) 作って返す。object でない値なら誤り。
fn child_object<'a>(v: &'a mut OValue, key: &str, shown: &str) -> Result<&'a mut OValue, String> {
    let OValue::Object(entries) = v else {
        unreachable!("呼ぶ側が object を渡す")
    };
    let i = match entries.iter().position(|(k, _)| k == key) {
        Some(i) => i,
        None => {
            entries.push((key.to_string(), OValue::Object(Vec::new())));
            entries.len() - 1
        }
    };
    let child = &mut entries[i].1;
    match child {
        OValue::Object(_) => {}
        OValue::Null => *child = OValue::Object(Vec::new()),
        _ => return Err(format!("{shown} が object でない")),
    }
    Ok(child)
}

/// 要素の name
fn name_of(v: &OValue) -> Option<&str> {
    match v.get("name") {
        Some(OValue::String(s)) => Some(s),
        _ => None,
    }
}

/// settings.json に決めたキーを合わせた値 (`before` は object)。`launch_args` が Some なら `config.launchArgs` もその値にする (None なら今の値を
/// 残す)。合わせるキーの型が違えば誤り。
pub fn merged(
    before: &OValue,
    clear_entrypoint: bool,
    launch_args: Option<&str>,
) -> Result<OValue, String> {
    let m = managed();
    let mut after = before.clone();
    {
        let providers = child_object(&mut after, "providerInstances", "providerInstances")?;
        let claude = child_object(providers, "claudeAgent", "providerInstances.claudeAgent")?;
        claude.set("driver", managed_at(&m, &["claudeAgent", "driver"]).clone());
        let config = child_object(claude, "config", "providerInstances.claudeAgent.config")?;
        config.set(
            "homePath",
            managed_at(&m, &["claudeAgent", "homePath"]).clone(),
        );
        if let Some(args) = launch_args {
            config.set("launchArgs", OValue::String(args.to_string()));
        }
        let entry = managed_at(&m, &["entrypointEnvironment"]).clone();
        let entry_name = name_of(&entry)
            .expect("entrypointEnvironment の name")
            .to_string();
        let env = match claude.get("environment") {
            None | Some(OValue::Null) => None,
            Some(OValue::Array(items)) if items.iter().all(|i| matches!(i, OValue::Object(_))) => {
                Some(items.clone())
            }
            Some(_) => {
                return Err(
                    "providerInstances.claudeAgent.environment が object の配列でない".to_string(),
                );
            }
        };
        let is_entry = |i: &OValue| name_of(i) == Some(entry_name.as_str());
        if clear_entrypoint {
            let items = env.unwrap_or_default();
            let new: Vec<OValue> = match items.iter().position(is_entry) {
                None => items.into_iter().chain([entry]).collect(),
                Some(i) => items[..i]
                    .iter()
                    .cloned()
                    .chain([entry])
                    .chain(items[i + 1..].iter().filter(|x| !is_entry(x)).cloned())
                    .collect(),
            };
            claude.set("environment", OValue::Array(new));
        } else if let Some(items) = env {
            claude.set(
                "environment",
                OValue::Array(items.into_iter().filter(|x| !is_entry(x)).collect()),
            );
        }
    }
    after.set(
        "defaultModelSelection",
        managed_at(&m, &["defaultModelSelection"]).clone(),
    );
    after.set(
        "defaultThreadEnvMode",
        managed_at(&m, &["defaultThreadEnvMode"]).clone(),
    );
    Ok(after)
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 合わせ方 (Linux の bootstrap-t3-code.sh と同じ決まり): 無ければ合わせるキーだけ。ほかのキーと順、config と environment のほかの
    //!   要素を残す。ENTRYPOINT が on なら同じ名前の要素を最初の位置で 1 つに置き換え (無ければ末尾に足す)、off なら外し、配列が無ければ
    //!   作らない。手で書いた settings.json (example-host のもの) には defaultModelSelection・defaultThreadEnvMode を足すだけ。型が違えば誤り
    //! - launchArgs: 値を渡せばその値にし (今の値も上書き)、config のほかのキーと順を残す。渡さなければ今の値を残す (無ければ作らない)
    //! - managed-settings.json の値 (Claude の home・Opus 5.5 の effort high・新しい worktree)
    //! - 手順: そろっていれば書かない。check と dry-run は書かない。apply は前の中身を写してから書く (無かったら写さない)。壊れた JSON は書かない。
    //!   claude-t3 のログインが無ければ ※ を添える
    //! - 手順の launchArgs: claude-t3 の置き先に 2 つのファイルがそろっていれば claude-t3 の出す文に合わせ、T3 の画面で変えても apply で戻す。
    //!   そろっていなければ書かず (今の値を残す) ※ を添える。check と dry-run は、同じ apply で claude-t3 が置けるなら置いた後の値で比べる
    //!   (windowsClaudeCode が off・repo にファイルが無いなら比べない)
    //! - 環境変数: 偽の PowerShell の none・value= を読み、違えば apply で名前と値を env で渡して書く。check は書かない。落ちたら誤り

    use super::*;
    use crate::host::Groups;
    use crate::manifest::Roots;
    use crate::process::{Exit, RunResult};
    use crate::testutil::{FakeSys, TempDir};

    fn j(text: &str) -> OValue {
        OValue::parse(text).unwrap()
    }

    fn compact(v: &OValue) -> String {
        serde_json::to_string(v).unwrap()
    }

    const ENTRY: &str = r#"{"name":"CLAUDE_CODE_ENTRYPOINT","value":"","sensitive":false}"#;
    const DMS: &str = r#"{"instanceId":"claudeAgent","model":"claude-opus-5-5","options":[{"id":"effort","value":"high"}]}"#;

    #[test]
    fn managed_values_are_the_agreed_ones() {
        let m = managed();
        assert_eq!(compact(managed_at(&m, &["defaultModelSelection"])), DMS);
        assert_eq!(compact(managed_at(&m, &["entrypointEnvironment"])), ENTRY);
        assert_eq!(
            compact(managed_at(&m, &["defaultThreadEnvMode"])),
            "\"worktree\""
        );
        assert_eq!(
            compact(managed_at(&m, &["claudeAgent", "homePath"])),
            "\"~/.claude-t3\""
        );
    }

    #[test]
    fn merge_creates_only_the_managed_keys() {
        let got = merged(&j("{}"), true, None).unwrap();
        assert_eq!(
            compact(&got),
            format!(
                r#"{{"providerInstances":{{"claudeAgent":{{"driver":"claudeAgent","config":{{"homePath":"~/.claude-t3"}},"environment":[{ENTRY}]}}}},"defaultModelSelection":{DMS},"defaultThreadEnvMode":"worktree"}}"#
            )
        );
        let got = merged(&j("{}"), false, None).unwrap();
        assert!(
            got.get("providerInstances")
                .and_then(|p| p.get("claudeAgent"))
                .and_then(|c| c.get("environment"))
                .is_none()
        );
    }

    #[test]
    fn merge_keeps_other_keys_and_order() {
        let before = j(
            r#"{"idleCompaction":"onReturn","providerInstances":{"codex":{"driver":"codex"},"claudeAgent":{"driver":"old","config":{"launchArgs":"--x","homePath":"~/.claude"},"environment":[{"name":"A","value":"1","sensitive":false},{"name":"CLAUDE_CODE_ENTRYPOINT","value":"","sensitive":true,"secret":{"provider":"p","reference":"r"}},{"name":"B","value":"2","sensitive":false},{"name":"CLAUDE_CODE_ENTRYPOINT","value":"x","sensitive":false}]}},"defaultThreadEnvMode":"local","linkedEnvironmentsEnabled":true}"#,
        );
        let got = merged(&before, true, None).unwrap();
        assert_eq!(
            compact(&got),
            format!(
                r#"{{"idleCompaction":"onReturn","providerInstances":{{"codex":{{"driver":"codex"}},"claudeAgent":{{"driver":"claudeAgent","config":{{"launchArgs":"--x","homePath":"~/.claude-t3"}},"environment":[{{"name":"A","value":"1","sensitive":false}},{ENTRY},{{"name":"B","value":"2","sensitive":false}}]}}}},"defaultThreadEnvMode":"worktree","linkedEnvironmentsEnabled":true,"defaultModelSelection":{DMS}}}"#
            )
        );
        // off なら同じ名前の要素を全部外す
        let got = merged(&before, false, None).unwrap();
        assert_eq!(
            compact(
                got.get("providerInstances")
                    .unwrap()
                    .get("claudeAgent")
                    .unwrap()
                    .get("environment")
                    .unwrap()
            ),
            r#"[{"name":"A","value":"1","sensitive":false},{"name":"B","value":"2","sensitive":false}]"#
        );
    }

    #[test]
    fn merge_on_the_hand_written_settings() {
        let hand_written = r#"{"idleCompaction":"onReturn","linkedEnvironmentsEnabled":true,"providerInstances":{"claudeAgent":{"driver":"claudeAgent","config":{"homePath":"~/.claude-t3"},"environment":[{"name":"CLAUDE_CODE_ENTRYPOINT","value":""}]}}}"#;
        let got = merged(&j(hand_written), true, None).unwrap();
        assert_eq!(
            compact(&got),
            format!(
                r#"{{"idleCompaction":"onReturn","linkedEnvironmentsEnabled":true,"providerInstances":{{"claudeAgent":{{"driver":"claudeAgent","config":{{"homePath":"~/.claude-t3"}},"environment":[{ENTRY}]}}}},"defaultModelSelection":{DMS},"defaultThreadEnvMode":"worktree"}}"#
            )
        );
    }

    #[test]
    fn merge_rejects_wrong_types() {
        for bad in [
            r#"{"providerInstances":[]}"#,
            r#"{"providerInstances":{"claudeAgent":"x"}}"#,
            r#"{"providerInstances":{"claudeAgent":{"config":1}}}"#,
            r#"{"providerInstances":{"claudeAgent":{"environment":{"name":"x"}}}}"#,
            r#"{"providerInstances":{"claudeAgent":{"environment":["x"]}}}"#,
        ] {
            assert!(merged(&j(bad), true, None).is_err(), "{bad}");
        }
        // null は無いのと同じ
        assert!(merged(&j(r#"{"providerInstances":null}"#), true, None).is_ok());
    }

    /// claudeAgent の config を compact に
    fn config_of(v: &OValue) -> String {
        compact(
            v.get("providerInstances")
                .and_then(|p| p.get("claudeAgent"))
                .and_then(|c| c.get("config"))
                .unwrap(),
        )
    }

    const ARGS: &str = r"--settings C:\h\.claude\t3\settings.json --append-system-prompt-file C:\h\.claude\t3\CLAUDE.t3.md";

    #[test]
    fn merge_sets_launch_args_and_keeps_other_config_keys() {
        // 今の値を上書きし、config のほかのキーと順を残す
        let before = j(
            r#"{"providerInstances":{"claudeAgent":{"config":{"launchArgs":"--x","homePath":"~/.claude","binaryPath":"claude"}}}}"#,
        );
        let got = merged(&before, false, Some(ARGS)).unwrap();
        let want_args = serde_json::to_string(ARGS).unwrap();
        assert_eq!(
            config_of(&got),
            format!(
                r#"{{"launchArgs":{want_args},"homePath":"~/.claude-t3","binaryPath":"claude"}}"#
            )
        );
        // 無ければ homePath の後ろに足す
        let got = merged(&j("{}"), false, Some(ARGS)).unwrap();
        assert_eq!(
            config_of(&got),
            format!(r#"{{"homePath":"~/.claude-t3","launchArgs":{want_args}}}"#)
        );
        // 渡さなければ今の値を残し、無ければ作らない
        let got = merged(&before, false, None).unwrap();
        assert_eq!(
            config_of(&got),
            r#"{"launchArgs":"--x","homePath":"~/.claude-t3","binaryPath":"claude"}"#
        );
        let got = merged(&j("{}"), false, None).unwrap();
        assert_eq!(config_of(&got), r#"{"homePath":"~/.claude-t3"}"#);
    }

    /// 偽の PowerShell: 読む script には `read` の行を、書く script には 0 を返す
    fn pwsh(read: &'static [&'static str]) -> FakeSys {
        FakeSys::new(move |c| {
            let script = c.args_lossy().last().cloned().unwrap_or_default();
            if script.contains("GetEnvironmentVariable") {
                RunResult {
                    exit: Exit::Code(0),
                    output: read.iter().map(|l| l.to_string()).collect(),
                }
            } else {
                RunResult {
                    exit: Exit::Code(0),
                    output: vec![],
                }
            }
        })
        .with_program("pwsh", "C:/pwsh/pwsh.exe")
    }

    fn run_step(t: &TempDir, sys: &FakeSys, mode: Mode, host: &str) -> (Vec<Outcome>, String) {
        let mut out = Vec::new();
        let host =
            crate::host::parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap();
        let outcomes = {
            let mut ctx = Ctx {
                repo: t.path().join("dotfiles"),
                roots: Roots::from_home(&t.path().join("home")),
                state_dir: t.path().join("state"),
                host,
                sys,
                out: &mut out,
            };
            T3CodeSettings.run(&mut ctx, mode)
        };
        (outcomes, String::from_utf8(out).unwrap())
    }

    fn settings_file(t: &TempDir) -> PathBuf {
        t.path()
            .join("home")
            .join(".t3")
            .join("userdata")
            .join("settings.json")
    }

    const ON: &str = "[tools]\nwindowsT3Code = true\n[t3Code]\nclearClaudeEntrypoint = true\n";

    #[test]
    fn step_writes_settings_only_in_apply_and_only_when_changed() {
        let t = TempDir::new("t3-code-settings");
        let sys = pwsh(&["value=false"]);
        let p = settings_file(&t);
        // 無いときの check は missing・書かない。ログインの ※ を添える
        let (o, _) = run_step(&t, &sys, Mode::Check, ON);
        assert_eq!(o.len(), 2);
        assert_eq!(o[0].kind, Kind::Ok, "環境変数はそろっている");
        assert_eq!(o[1].kind, Kind::Missing);
        assert!(o[1].notes.iter().any(|n| n.contains("ログインしていない")));
        assert!(!p.exists());
        let (o, _) = run_step(&t, &sys, Mode::DryRun { force: false }, ON);
        assert_eq!(o[1].kind, Kind::Missing);
        assert!(!p.exists());
        // apply は作る (無かったものは写さない)
        let (o, _) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
        assert_eq!(o[1].kind, Kind::Ok);
        let written = j(&std::fs::read_to_string(&p).unwrap());
        assert_eq!(
            compact(&written),
            compact(&merged(&j("{}"), true, None).unwrap())
        );
        assert!(!t.path().join("state").join("t3-code-settings").exists());
        // そろっていれば書かない
        let (o, out) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
        assert_eq!(o[1].kind, Kind::Ok);
        assert!(out.contains("登録済みです"));
        // ENTRYPOINT を off にすると外す (前の中身を写してから)
        let (o, _) = run_step(
            &t,
            &sys,
            Mode::Apply { force: false },
            "[tools]\nwindowsT3Code = true\n",
        );
        assert_eq!(o[1].kind, Kind::Ok);
        let written = j(&std::fs::read_to_string(&p).unwrap());
        assert_eq!(
            compact(
                written
                    .get("providerInstances")
                    .unwrap()
                    .get("claudeAgent")
                    .unwrap()
                    .get("environment")
                    .unwrap()
            ),
            "[]"
        );
        let backups = std::fs::read_dir(
            t.path()
                .join("state")
                .join("t3-code-settings")
                .join("backup"),
        )
        .unwrap()
        .count();
        assert_eq!(backups, 1);
        // ログインしていれば ※ を添えない
        let creds = t.path().join("home").join(".claude-t3");
        std::fs::create_dir_all(&creds).unwrap();
        std::fs::write(creds.join(".credentials.json"), "{}").unwrap();
        let (o, _) = run_step(&t, &sys, Mode::Check, "[tools]\nwindowsT3Code = true\n");
        assert!(
            !o[1].notes.iter().any(|n| n.contains("ログインしていない")),
            "{:?}",
            o[1].notes
        );
    }

    /// claude-t3 の置き先 (`<home>/.claude/t3`)
    fn t3_dir(t: &TempDir) -> PathBuf {
        t.path().join("home").join(".claude").join("t3")
    }

    fn launch_args_in(p: &Path) -> Option<String> {
        let v = j(&std::fs::read_to_string(p).unwrap());
        match v
            .get("providerInstances")
            .and_then(|x| x.get("claudeAgent"))
            .and_then(|x| x.get("config"))
            .and_then(|x| x.get("launchArgs"))
        {
            Some(OValue::String(s)) => Some(s.clone()),
            None => None,
            Some(other) => panic!("{other:?}"),
        }
    }

    fn set_launch_args(p: &Path, args: &str) {
        let mut v = j(&std::fs::read_to_string(p).unwrap());
        child_object(
            child_object(
                child_object(&mut v, "providerInstances", "p").unwrap(),
                "claudeAgent",
                "c",
            )
            .unwrap(),
            "config",
            "config",
        )
        .unwrap()
        .set("launchArgs", OValue::String(args.to_string()));
        std::fs::write(p, v.to_pretty()).unwrap();
    }

    #[test]
    fn step_writes_launch_args_only_when_the_files_are_placed() {
        let t = TempDir::new("t3-code-settings-launch-args");
        let sys = pwsh(&["value=false"]);
        let p = settings_file(&t);
        let want = claude_t3::launch_args(&t3_dir(&t));
        // 置き先にも repo にも無い: check も apply も書かず (今の値を残す)、※ で知らせる
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, "{}").unwrap();
        run_step(&t, &sys, Mode::Apply { force: false }, ON);
        set_launch_args(&p, "--old");
        let (o, _) = run_step(&t, &sys, Mode::Check, ON);
        assert_eq!(o[1].kind, Kind::Ok, "{:?}", o[1]);
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.contains("launchArgs") && n.contains("書かない")),
            "{:?}",
            o[1].notes
        );
        let (o, _) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
        assert_eq!(o[1].kind, Kind::Ok);
        assert_eq!(launch_args_in(&p).as_deref(), Some("--old"));
        // repo にあり置き先に無い: check と dry-run は claude-t3 が置いた後の値で比べる (書かない)。apply では置き先に無ければ書かない
        t.write("dotfiles/win/claude-code/t3/settings.json", "{}\n");
        t.write("dotfiles/win/claude-code/t3/CLAUDE.t3.md", "# T3\n");
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (o, _) = run_step(&t, &sys, mode, ON);
            assert_eq!(o[1].kind, Kind::Fix, "{mode:?} {:?}", o[1]);
            assert!(
                o[1].notes
                    .iter()
                    .any(|n| n.contains("claude-t3 が") && n.contains("置いてから書く")),
                "{mode:?} {:?}",
                o[1].notes
            );
            assert_eq!(launch_args_in(&p).as_deref(), Some("--old"), "{mode:?}");
        }
        let (o, _) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
        assert_eq!(o[1].kind, Kind::Ok);
        assert!(
            o[1].notes.iter().any(|n| n.contains("もう一度 apply")),
            "{:?}",
            o[1].notes
        );
        assert_eq!(launch_args_in(&p).as_deref(), Some("--old"));
        // windowsClaudeCode が off なら claude-t3 は置かないので、check も比べない
        let (o, _) = run_step(
            &t,
            &sys,
            Mode::Check,
            "[tools]\nwindowsT3Code = true\nwindowsClaudeCode = false\n",
        );
        assert_eq!(o[1].kind, Kind::Fix, "ENTRYPOINT を外すので fix");
        assert!(
            o[1].notes.iter().any(|n| n.contains("windowsClaudeCode")),
            "{:?}",
            o[1].notes
        );
        // 置き先にそろえば、claude-t3 の出す文に合わせる (知らせる文は添えない)
        std::fs::create_dir_all(t3_dir(&t)).unwrap();
        for name in claude_t3::FILES {
            std::fs::write(t3_dir(&t).join(name), "{}").unwrap();
        }
        let (o, _) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
        assert_eq!(o[1].kind, Kind::Ok);
        assert!(
            !o[1].notes.iter().any(|n| n.contains("launchArgs")),
            "{:?}",
            o[1].notes
        );
        assert_eq!(launch_args_in(&p), Some(want.clone()));
        // T3 の画面で変えても、次の apply で戻す
        set_launch_args(&p, "--settings other.json");
        let (o, _) = run_step(&t, &sys, Mode::Check, ON);
        assert_eq!(o[1].kind, Kind::Fix);
        let (o, _) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
        assert_eq!(o[1].kind, Kind::Ok);
        assert_eq!(launch_args_in(&p), Some(want));
        let (o, out) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
        assert_eq!(o[1].kind, Kind::Ok);
        assert!(out.contains("登録済みです"), "{out}");
    }

    #[test]
    fn step_does_not_touch_broken_settings() {
        let t = TempDir::new("t3-code-settings-broken");
        let sys = pwsh(&["value=false"]);
        let p = settings_file(&t);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        for text in [
            "{",
            "[1]",
            r#"{"providerInstances":{"claudeAgent":{"environment":{}}}}"#,
        ] {
            std::fs::write(&p, text).unwrap();
            let (o, _) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
            assert_eq!(o[1].kind, Kind::Failed, "{text}");
            assert_eq!(std::fs::read_to_string(&p).unwrap(), text);
        }
    }

    #[test]
    fn telemetry_env_is_read_and_written_with_env_values() {
        // 無ければ check は missing で書かない
        let t = TempDir::new("t3-code-env");
        let sys = pwsh(&["none"]);
        let (o, _) = run_step(&t, &sys, Mode::Check, ON);
        assert_eq!(o[0].kind, Kind::Missing);
        assert!(sys.calls.borrow().iter().all(|c| {
            !c.args_lossy()
                .last()
                .unwrap()
                .contains("SetEnvironmentVariable")
        }));
        // 違う値なら fix。apply は名前と値を env で渡して書く
        let sys = pwsh(&["value=true"]);
        let (o, _) = run_step(&t, &sys, Mode::Check, ON);
        assert_eq!(o[0].kind, Kind::Fix);
        let (o, out) = run_step(&t, &sys, Mode::Apply { force: false }, ON);
        assert_eq!(o[0].kind, Kind::Ok);
        assert!(out.contains("T3 Code を開き直す"));
        let calls = sys.calls.borrow();
        let w = calls
            .iter()
            .find(|c| {
                c.args_lossy()
                    .last()
                    .unwrap()
                    .contains("SetEnvironmentVariable")
            })
            .unwrap();
        assert_eq!(w.env_value("DOTFILES_ENV_NAME").unwrap(), TELEMETRY_VAR);
        assert_eq!(w.env_value("DOTFILES_ENV_VALUE").unwrap(), TELEMETRY_VALUE);
        assert!(w.args_lossy().last().unwrap().contains("'User'"));
        drop(calls);
        // 読めなければ誤り
        let sys = FakeSys::new(|_| RunResult {
            exit: Exit::Code(1),
            output: vec!["error: boom".into()],
        })
        .with_program("pwsh", "C:/pwsh/pwsh.exe");
        let (o, _) = run_step(&t, &sys, Mode::Check, ON);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(o[0].text.contains("読めない"), "{}", o[0].text);
        // PowerShell が無ければ確かめられない
        let sys = FakeSys::new(|_| unreachable!());
        let (o, _) = run_step(&t, &sys, Mode::Check, ON);
        assert_eq!(o[0].kind, Kind::Failed);
    }
}
