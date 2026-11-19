//! ユーザーの PATH (`HKCU\Environment` の `Path`) を読み、末尾に dir を足す。herdr-app の installer (`win/herdr-app/Install-HerdrApp.ps1` の
//! Get-HerdrAppUserPathRaw・Set-HerdrAppUserPathRaw・Get-PathValueWithEntry) と同じ形: 生の値 (`%VAR%` を展開しない) を読み、値の型
//! (REG_EXPAND_SZ・REG_SZ。値が無ければ REG_EXPAND_SZ) とほかの要素の書き方を変えずに末尾へ足し、user 変数を書いて消して、動いている
//! プログラムに環境変数が変わったことを知らせる (WM_SETTINGCHANGE)。registry は PowerShell で触る (runner は OS の API を外のコマンドで
//! 呼ぶ)。値は env で渡し、script は ASCII だけにする (引用符と文字コードに頼らない)。

use crate::link::path_key;
use crate::process::{CommandSpec, Sys};
use std::path::Path;
use std::time::Duration;

/// ユーザーの PATH の生の値と、値の型 (`ExpandString`・`String`・値が無ければ `None`)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserPath {
    pub raw: String,
    pub kind: String,
}

/// 生の値と型を `kind=…`・`raw=…` の 2 行で出す。途中の誤りでは先へ進まずに 1 で終わる (`$ErrorActionPreference = 'Stop'` と catch。
/// 黙って空の値を返すと、書く側が PATH を書き潰しうるため)。
const READ_SCRIPT: &str = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ErrorActionPreference = 'Stop'; try { $raw = ''; $kind = 'None'; $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false); if ($null -ne $k) { try { if ($k.GetValueNames() -contains 'Path') { $raw = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); $kind = [string]$k.GetValueKind('Path') } } finally { $k.Close() } }; Write-Output ('kind=' + $kind); Write-Output ('raw=' + $raw) } catch { Write-Output ('error: ' + $_.Exception.Message); exit 1 }";

/// 読み直して `DOTFILES_USER_PATH_OLD` と違えば書かずに 3 で終わる (try の中の exit は catch に捕まらない)。同じなら型を保って
/// `DOTFILES_USER_PATH_NEW` を書き、知らせる。途中の誤りでは先へ進まずに 1 で終わる。
const WRITE_SCRIPT: &str = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ErrorActionPreference = 'Stop'; try { $old = [string]$env:DOTFILES_USER_PATH_OLD; $new = [string]$env:DOTFILES_USER_PATH_NEW; $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment'); if ($null -eq $k) { throw 'cannot open HKCU Environment' }; try { $has = $k.GetValueNames() -contains 'Path'; $raw = ''; if ($has) { $raw = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }; if ($raw -cne $old) { Write-Output 'changed since read'; exit 3 }; $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString; if ($has) { $kind = $k.GetValueKind('Path') }; $k.SetValue('Path', $new, $kind) } finally { $k.Close() }; [Environment]::SetEnvironmentVariable('DOTFILES_USER_PATH_REFRESH', '1', 'User'); [Environment]::SetEnvironmentVariable('DOTFILES_USER_PATH_REFRESH', $null, 'User'); exit 0 } catch { Write-Output ('error: ' + $_.Exception.Message); exit 1 }";

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

/// ユーザーの PATH の生の値と型を読む。
pub fn read(sys: &dyn Sys, shell: &Path) -> Result<UserPath, String> {
    let r = sys.run(&powershell(shell, READ_SCRIPT), &mut |_| {});
    if r.code() != Some(0) {
        return Err(format!(
            "ユーザーの PATH を読めない ({:?}): {}",
            r.exit,
            r.output.join(" / ")
        ));
    }
    let field = |key: &str| {
        r.output
            .iter()
            .find_map(|l| l.strip_prefix(key).map(str::to_string))
    };
    match (field("kind="), field("raw=")) {
        (Some(kind), Some(raw)) => Ok(UserPath { raw, kind }),
        _ => Err(format!(
            "ユーザーの PATH を読めない (kind= と raw= の行が無い): {}",
            r.output.join(" / ")
        )),
    }
}

/// ユーザーの PATH を `new` に書く (読んだ値 `old` から変わっていれば書かずに誤り)。
pub fn write(sys: &dyn Sys, shell: &Path, old: &str, new: &str) -> Result<(), String> {
    let spec = powershell(shell, WRITE_SCRIPT)
        .env("DOTFILES_USER_PATH_OLD", old)
        .env("DOTFILES_USER_PATH_NEW", new);
    let r = sys.run(&spec, &mut |_| {});
    match r.code() {
        Some(0) => Ok(()),
        Some(3) => Err(
            "ユーザーの PATH が読んだ後に変わった (ほかのプログラムが書いた)。書かずに止めた → dotfiles apply を流し直す".to_string(),
        ),
        _ => Err(format!(
            "ユーザーの PATH を書けない ({:?}): {}",
            r.exit,
            r.output.join(" / ")
        )),
    }
}

/// PATH の生の値 (`;` 区切り) に `dir` を指す要素があるか。要素は前後の空白と `"` を落とし、`%VAR%` を展開し、Windows の決まり (末尾の区切り・
/// 大文字小文字・`/` と `\`) で比べる (herdr-app の installer の Test-HerdrAppPathEntry と同じ)。
pub fn listed(raw: &str, dir: &Path, env: &dyn Fn(&str) -> Option<String>) -> bool {
    let want = path_key(&dir.to_string_lossy(), true);
    raw.split(';').any(|entry| {
        let v = expand_env_vars(entry.trim().trim_matches('"'), env);
        !v.is_empty() && path_key(&v, true) == want
    })
}

/// 生の値の末尾に `dir` を足した値 (末尾の `;` を落として `;<dir>`。空なら `<dir>`)。ほかの要素はそのまま。
pub fn with_entry(raw: &str, dir: &Path) -> String {
    let d = dir.to_string_lossy();
    let base = raw.trim_end_matches(';');
    if base.is_empty() {
        d.into_owned()
    } else {
        format!("{base};{d}")
    }
}

/// `%NAME%` を env の値に替える (無い変数は `%NAME%` のまま。Windows の ExpandEnvironmentStrings と同じ読み方)。
pub fn expand_env_vars(s: &str, env: &dyn Fn(&str) -> Option<String>) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('%') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        match after.find('%') {
            Some(j) if j > 0 => {
                let name = &after[..j];
                match env(name) {
                    Some(v) => out.push_str(&v),
                    None => {
                        out.push('%');
                        out.push_str(name);
                        out.push('%');
                    }
                }
                rest = &after[j + 1..];
            }
            _ => {
                out.push('%');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - PATH の要素の読み方: 前後の空白と `"` を落とし、`%VAR%` を展開し、末尾の区切りと大文字小文字の違いを同じに読む (herdr-app の
    //!   installer の Test-HerdrAppPathEntry と同じ)。区切りの境で見る (`…\binx` は違う)
    //! - 末尾に足す形 (末尾の `;` を落として `;<dir>`。空なら `<dir>`)。無い変数は `%NAME%` のまま残す
    //! - 読む: 偽の PowerShell の `kind=`・`raw=` の 2 行を読み、生の値を読む script (DoNotExpandEnvironmentNames) を打つ。落ちたら誤り
    //! - 書く: 読んだ値と書く値を env で渡し、3 は「読んだ後に変わった」

    use super::*;
    use crate::process::{Exit, RunResult};
    use crate::testutil::FakeSys;

    fn env(name: &str) -> Option<String> {
        match name {
            "LOCALAPPDATA" => Some("C:\\Users\\a\\AppData\\Local".to_string()),
            "A" => Some("C:\\a".to_string()),
            _ => None,
        }
    }

    const BIN: &str = "C:\\Users\\a\\AppData\\Local\\dotfiles\\bin";

    #[test]
    fn listed_reads_entries_like_windows() {
        let bin = Path::new(BIN);
        for raw in [
            "C:\\Windows;%LOCALAPPDATA%\\dotfiles\\bin",
            "%LOCALAPPDATA%\\dotfiles\\bin\\;C:\\Windows",
            " \"C:\\Users\\a\\AppData\\Local\\dotfiles\\bin\\\" ",
            "c:\\users\\A\\appdata\\local\\DOTFILES\\bin",
            "C:/Users/a/AppData/Local/dotfiles/bin",
        ] {
            assert!(listed(raw, bin, &env), "{raw}");
        }
        for raw in [
            "",
            "C:\\Windows",
            "C:\\Users\\a\\AppData\\Local\\dotfiles\\binx",
            "%NOPE%\\dotfiles\\bin",
            "C:\\Users\\a\\AppData\\Local\\dotfiles",
        ] {
            assert!(!listed(raw, bin, &env), "{raw}");
        }
    }

    #[test]
    fn with_entry_appends_after_trimming_semicolons() {
        let bin = Path::new(BIN);
        assert_eq!(with_entry("a;b;", bin), format!("a;b;{BIN}"));
        assert_eq!(with_entry("a", bin), format!("a;{BIN}"));
        assert_eq!(with_entry("", bin), BIN);
        assert_eq!(with_entry(";;", bin), BIN);
        assert_eq!(
            with_entry("%USERPROFILE%\\x;C:\\y", bin),
            format!("%USERPROFILE%\\x;C:\\y;{BIN}")
        );
    }

    #[test]
    fn expand_env_vars_keeps_unknown_names() {
        assert_eq!(
            expand_env_vars("%A%\\x;%NOPE%\\y;100%", &env),
            "C:\\a\\x;%NOPE%\\y;100%"
        );
        assert_eq!(expand_env_vars("%NOPE%A%", &env), "%NOPE%A%");
        assert_eq!(expand_env_vars("plain", &env), "plain");
        assert_eq!(expand_env_vars("%A%%A%", &env), "C:\\aC:\\a");
    }

    fn pwsh(lines: &'static [&'static str], code: i32) -> FakeSys {
        FakeSys::new(move |_| RunResult {
            exit: Exit::Code(code),
            output: lines.iter().map(|l| l.to_string()).collect(),
        })
    }

    #[test]
    fn read_parses_kind_and_raw() {
        let sys = pwsh(&["kind=ExpandString", "raw=C:\\x;%LOCALAPPDATA%\\y=z"], 0);
        assert_eq!(
            read(&sys, Path::new("pwsh")).unwrap(),
            UserPath {
                raw: "C:\\x;%LOCALAPPDATA%\\y=z".to_string(),
                kind: "ExpandString".to_string()
            }
        );
        let calls = sys.calls.borrow();
        let args = calls[0].args_lossy();
        assert_eq!(args[args.len() - 2], "-Command");
        assert!(
            args[args.len() - 1].contains("DoNotExpandEnvironmentNames"),
            "{args:?}"
        );
        // 途中の誤りで先へ進まない (誤りなら 1 で終わる)
        assert!(
            args[args.len() - 1].contains("$ErrorActionPreference = 'Stop'"),
            "{args:?}"
        );
        assert!(args[args.len() - 1].contains("exit 1 }"), "{args:?}");
        drop(calls);
        let sys = pwsh(&["kind=None", "raw="], 0);
        assert_eq!(read(&sys, Path::new("pwsh")).unwrap().raw, "");
        let sys = pwsh(&["kind=String"], 0);
        assert!(read(&sys, Path::new("pwsh")).is_err());
        let sys = pwsh(&["boom"], 1);
        let e = read(&sys, Path::new("pwsh")).unwrap_err();
        assert!(e.contains("ユーザーの PATH を読めない"), "{e}");
    }

    #[test]
    fn write_passes_values_by_env_and_reports_a_change() {
        let sys = pwsh(&[], 0);
        write(&sys, Path::new("pwsh"), "C:\\x", "C:\\x;C:\\bin").unwrap();
        let c = sys.calls.borrow()[0].clone();
        assert_eq!(c.env_value("DOTFILES_USER_PATH_OLD").unwrap(), "C:\\x");
        assert_eq!(
            c.env_value("DOTFILES_USER_PATH_NEW").unwrap(),
            "C:\\x;C:\\bin"
        );
        let script = c.args_lossy().pop().unwrap();
        assert!(script.contains("SetValue('Path', $new, $kind)"), "{script}");
        assert!(script.contains("DOTFILES_USER_PATH_REFRESH"), "{script}");
        assert!(
            script.contains("$ErrorActionPreference = 'Stop'"),
            "{script}"
        );
        assert!(script.contains("exit 1 }"), "{script}");
        let sys = pwsh(&["changed"], 3);
        let e = write(&sys, Path::new("pwsh"), "a", "a;b").unwrap_err();
        assert!(e.contains("読んだ後に変わった"), "{e}");
        let sys = pwsh(&["boom"], 1);
        let e = write(&sys, Path::new("pwsh"), "a", "a;b").unwrap_err();
        assert!(e.contains("ユーザーの PATH を書けない"), "{e}");
    }
}
