//! 引数。clap は使わず、5 つの option を手で読む。

use std::ffi::OsString;
use std::path::PathBuf;
use std::time::Duration;

pub const USAGE: &str = "\
pjp-ghq-pull: ghq の repo を選び、既定 branch を fetch と fast-forward で最新にする

使い方:
  pjp-ghq-pull [-j N] [--via-gh | --no-via-gh] [--timeout 秒] [--root DIR]

  -j, --jobs N       並列の本数 (既定 8)
      --via-gh       この回だけ fetch を git gh (gh の資格情報) で打つ
      --no-via-gh    この回だけ fetch を素の git で打つ
                     (どちらも無ければ ~/.local/state/dotfiles/git-via-gh.json の enable に従う)
      --timeout 秒   fetch の時間切れ (既定 120)
      --root DIR     ghq の root の代わりに DIR の下の repo を出す (GHQ_ROOT=DIR で ghq を呼ぶ)
  -h, --help         これを出す
  -V, --version      版を出す

選ぶ画面: Space で on/off、a で全選択、n で全解除、← → で org を畳む / 開く、/ で絞り込み、
Enter で始める、q でやめる。詳しくは dotfiles の nix/README.md の
「ghq の repo をまとめて最新にする (pjp-ghq-pull)」。
";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Opts {
    pub jobs: usize,
    pub via_gh: Option<bool>,
    pub timeout: Duration,
    pub root: Option<PathBuf>,
}

impl Default for Opts {
    fn default() -> Opts {
        Opts {
            jobs: 8,
            via_gh: None,
            timeout: Duration::from_secs(120),
            root: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cmd {
    Run(Opts),
    Help,
    Version,
}

/// 引数 (実行ファイルの名前を除いたもの) を読む
pub fn parse(args: impl IntoIterator<Item = OsString>) -> Result<Cmd, String> {
    let mut opts = Opts::default();
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let arg = arg
            .into_string()
            .map_err(|a| format!("読めない引数です: {}", a.to_string_lossy()))?;
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n.to_string(), Some(v.to_string())),
            _ => match arg.strip_prefix("-j") {
                Some(v) if !v.is_empty() && !arg.starts_with("--") => {
                    ("-j".to_string(), Some(v.to_string()))
                }
                _ => (arg.clone(), None),
            },
        };
        let mut value = |what: &str| -> Result<String, String> {
            match inline.clone() {
                Some(v) => Ok(v),
                None => args
                    .next()
                    .and_then(|v| v.into_string().ok())
                    .ok_or_else(|| format!("{what} に値が要ります")),
            }
        };
        match name.as_str() {
            "-h" | "--help" => return Ok(Cmd::Help),
            "-V" | "--version" => return Ok(Cmd::Version),
            "-j" | "--jobs" => opts.jobs = positive(&name, &value(&name)?)? as usize,
            "--timeout" => {
                opts.timeout = Duration::from_secs(positive(&name, &value(&name)?)?);
            }
            "--root" => opts.root = Some(PathBuf::from(value(&name)?)),
            "--via-gh" => opts.via_gh = Some(true),
            "--no-via-gh" => opts.via_gh = Some(false),
            _ => return Err(format!("知らない引数です: {arg}")),
        }
    }
    Ok(Cmd::Run(opts))
}

fn positive(name: &str, value: &str) -> Result<u64, String> {
    match value.parse::<u64>() {
        Ok(n) if n > 0 => Ok(n),
        _ => Err(format!("{name} には 1 以上の整数を渡してください: {value}")),
    }
}
