//! 引数を読み、コマンドを流す。
//!
//! 引数は手で読む (clap を足さない)。誤りは使い方と一緒に stderr へ出し、終了コード 2。

use std::path::PathBuf;

pub const USAGE: &str = "\
dotfiles の Windows 側の runner (win/README.md の「runner」)。

使い方:
  dotfiles check   [--steps <id>,…] [--host-file <path>]   手順を順に確かめる (何も書かない)
  dotfiles apply   [--dry-run] [--force] [--steps <id>,…] [--host-file <path>]
                                                          手順を順に揃える (ホストの値の runner.enable = true のときだけ)
  dotfiles list    [--host-file <path>]                   手順と、このホストでの on/off・受け持ちを出す
  dotfiles manifest [--json] [--windows-home <path>]      win/manifest.toml を検証する (--json は置き先を解いた計画)

  --dry-run         apply がすることを出すだけ (何も書かない。runner.enable によらない)
  --force           files の衝突 (Windows 側で変わっていた) も上書きする
  --steps <id>,…    流す手順を id で絞る (id は dotfiles list で見る)
  --host-file <path> ホストの値のファイル (既定は dotfiles-private の win/hosts/<ユーザー>@<PC>.toml)
  --windows-home <path> manifest の置き先を、この Windows のホストの下として解く (既定は環境変数)
  --repo <path>     dotfiles の clone (既定は runner を build した clone。試すとき)

終了コード: 0 直すことが無い・3 入っていない・無いものだけ (apply で揃う)・1 ほかに直すことがある・2 runner が動けない";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Check,
    Apply,
    List,
    Manifest,
    Help,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Args {
    pub command: Command,
    pub dry_run: bool,
    pub force: bool,
    pub steps: Option<Vec<String>>,
    pub host_file: Option<PathBuf>,
    pub json: bool,
    pub windows_home: Option<PathBuf>,
    pub repo: Option<PathBuf>,
}

impl Args {
    fn new(command: Command) -> Self {
        Args {
            command,
            dry_run: false,
            force: false,
            steps: None,
            host_file: None,
            json: false,
            windows_home: None,
            repo: None,
        }
    }
}

/// 引数を読む。誤りは文で返す (呼ぶ側が使い方と一緒に出す)。
pub fn parse(args: &[String]) -> Result<Args, String> {
    let mut iter = args.iter();
    let Some(first) = iter.next() else {
        return Err("コマンドがありません".to_string());
    };
    let command = match first.as_str() {
        "check" => Command::Check,
        "apply" => Command::Apply,
        "list" => Command::List,
        "manifest" => Command::Manifest,
        "help" | "-h" | "--help" => return Ok(Args::new(Command::Help)),
        other => return Err(format!("知らないコマンドです: {other}")),
    };
    let mut a = Args::new(command);
    while let Some(arg) = iter.next() {
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (arg.as_str(), None),
        };
        let mut value = |name: &str| -> Result<String, String> {
            match &inline {
                Some(v) => Ok(v.clone()),
                None => iter
                    .next()
                    .cloned()
                    .ok_or_else(|| format!("{name} の値がありません")),
            }
        };
        let allowed = |commands: &[Command]| -> Result<(), String> {
            if commands.contains(&command) {
                Ok(())
            } else {
                Err(format!(
                    "{name} は {} には付けられません",
                    command_name(command)
                ))
            }
        };
        match name {
            "-h" | "--help" => return Ok(Args::new(Command::Help)),
            "--dry-run" => {
                allowed(&[Command::Apply])?;
                a.dry_run = true;
            }
            "--force" => {
                allowed(&[Command::Apply])?;
                a.force = true;
            }
            "--json" => {
                allowed(&[Command::Manifest])?;
                a.json = true;
            }
            "--steps" => {
                allowed(&[Command::Check, Command::Apply])?;
                let v = value(name)?;
                let ids: Vec<String> = v
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect();
                if ids.is_empty() {
                    return Err("--steps に手順の id がありません".to_string());
                }
                a.steps = Some(ids);
            }
            "--host-file" => {
                allowed(&[Command::Check, Command::Apply, Command::List])?;
                a.host_file = Some(PathBuf::from(value(name)?));
            }
            "--windows-home" => {
                allowed(&[Command::Manifest])?;
                a.windows_home = Some(PathBuf::from(value(name)?));
            }
            "--repo" => a.repo = Some(PathBuf::from(value(name)?)),
            other => return Err(format!("知らない引数です: {other}")),
        }
        if inline.is_some() && matches!(name, "--dry-run" | "--force" | "--json") {
            return Err(format!("{name} は値を取りません"));
        }
    }
    Ok(a)
}

fn command_name(c: Command) -> &'static str {
    match c {
        Command::Check => "check",
        Command::Apply => "apply",
        Command::List => "list",
        Command::Manifest => "manifest",
        Command::Help => "help",
    }
}

/// `dotfiles-win` の本体。終了コードを返す。
pub fn main(args: Vec<String>) -> i32 {
    match parse(&args) {
        Ok(a) if a.command == Command::Help => {
            println!("{USAGE}");
            0
        }
        Ok(_) => {
            eprintln!("このコマンドはまだありません");
            2
        }
        Err(e) => {
            eprintln!("!! {e}\n\n{USAGE}");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - コマンドと引数の読み方 (`--opt value` と `--opt=value`・`--steps` の分け方)
    //! - コマンドが無い・知らない・付けられない引数・値が無いのは誤り (呼ぶ側が終了コード 2 にする)

    use super::*;

    fn p(args: &[&str]) -> Result<Args, String> {
        parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn reads_commands() {
        assert_eq!(p(&["check"]).unwrap().command, Command::Check);
        assert_eq!(p(&["apply"]).unwrap().command, Command::Apply);
        assert_eq!(p(&["list"]).unwrap().command, Command::List);
        assert_eq!(p(&["manifest"]).unwrap().command, Command::Manifest);
        assert_eq!(p(&["--help"]).unwrap().command, Command::Help);
        assert_eq!(p(&["check", "-h"]).unwrap().command, Command::Help);
    }

    #[test]
    fn reads_options() {
        let a = p(&[
            "apply",
            "--dry-run",
            "--force",
            "--steps",
            "files, ntn",
            "--host-file=h.toml",
            "--repo",
            "/r",
        ])
        .unwrap();
        assert!(a.dry_run && a.force);
        assert_eq!(a.steps, Some(vec!["files".to_string(), "ntn".to_string()]));
        assert_eq!(a.host_file, Some(PathBuf::from("h.toml")));
        assert_eq!(a.repo, Some(PathBuf::from("/r")));
        let m = p(&["manifest", "--json", "--windows-home", "/mnt/c/Users/x"]).unwrap();
        assert!(m.json);
        assert_eq!(m.windows_home, Some(PathBuf::from("/mnt/c/Users/x")));
    }

    #[test]
    fn rejects_bad_arguments() {
        for args in [
            &[][..],
            &["frobnicate"][..],
            &["check", "--dry-run"][..],
            &["list", "--force"][..],
            &["check", "--json"][..],
            &["apply", "--steps"][..],
            &["apply", "--steps", ","][..],
            &["check", "--what"][..],
            &["apply", "--dry-run=yes"][..],
            &["manifest", "--host-file", "x"][..],
        ] {
            assert!(p(args).is_err(), "{args:?}");
        }
    }
}
