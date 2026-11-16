//! 外のコマンドを打つ口 (`Sys`)。手順は外のコマンド (pwsh・git・hostname) をここから打ち、試験では偽物に差し替える。
//!
//! 本物 (`RealSys`) は stdout と stderr を行ごとに、届いた順に `on_line` へ渡しながら写しも取る (長い winget の入れ替えでも進み具合が
//! 見えるように)。時間切れなら起こしたプロセスを止める (孫の winget までは止めない。WSL の `timeout` も同じ)。stdin は渡さない
//! (確認待ちで止まらないように)。

use std::ffi::OsString;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// 打つコマンド。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: PathBuf,
    pub args: Vec<OsString>,
    /// 待つ上限。無ければ終わるまで待つ
    pub timeout: Option<Duration>,
}

impl CommandSpec {
    pub fn new(program: impl Into<PathBuf>) -> Self {
        CommandSpec {
            program: program.into(),
            args: Vec::new(),
            timeout: None,
        }
    }

    pub fn arg(mut self, a: impl Into<OsString>) -> Self {
        self.args.push(a.into());
        self
    }

    pub fn timeout(mut self, d: Duration) -> Self {
        self.timeout = Some(d);
        self
    }

    /// 引数を文字列で (試験で比べるため)
    pub fn args_lossy(&self) -> Vec<String> {
        self.args
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    }
}

/// どう終わったか。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Exit {
    /// 終了コードで終わった
    Code(i32),
    /// 終了コードが無い (Unix のシグナルなど)
    NoCode,
    /// 待つ上限を過ぎたので止めた
    TimedOut,
    /// 起こせなかった
    SpawnFailed(String),
}

/// 打った結果。`output` は stdout と stderr を届いた順に行で並べたもの (行末の改行は落とす)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunResult {
    pub exit: Exit,
    pub output: Vec<String>,
}

impl RunResult {
    pub fn code(&self) -> Option<i32> {
        match self.exit {
            Exit::Code(c) => Some(c),
            _ => None,
        }
    }
}

pub trait Sys {
    /// コマンドを打つ。出力の行は届いたそばから `on_line` に渡す。
    fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult;
    /// PATH からコマンドを探す (Windows は拡張子の無い名前に .exe・.cmd・.bat も試す)。
    fn which(&self, name: &str) -> Option<PathBuf>;
    /// 環境変数
    fn env(&self, name: &str) -> Option<String>;
}

/// 本物の口。
pub struct RealSys;

/// プロセスが終わった後、孫が pipe を持ったままのときに出力を待つ長さ
const DRAIN_AFTER_EXIT: Duration = Duration::from_secs(2);

impl Sys for RealSys {
    fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
        let mut child = match Command::new(&spec.program)
            .args(&spec.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                return RunResult {
                    exit: Exit::SpawnFailed(format!("{}: {e}", spec.program.display())),
                    output: Vec::new(),
                };
            }
        };
        let (tx, rx) = mpsc::channel::<Option<String>>();
        let mut readers = 0;
        if let Some(out) = child.stdout.take() {
            spawn_reader(out, tx.clone());
            readers += 1;
        }
        if let Some(err) = child.stderr.take() {
            spawn_reader(err, tx.clone());
            readers += 1;
        }
        drop(tx);

        let deadline = spec.timeout.map(|d| Instant::now() + d);
        let mut output = Vec::new();
        let mut open = readers;
        let mut exited: Option<(std::process::ExitStatus, Instant)> = None;
        loop {
            let mut wait = Duration::from_millis(100);
            if let Some(d) = deadline {
                let now = Instant::now();
                if now >= d && exited.is_none() {
                    let _ = child.kill();
                    let _ = child.wait();
                    return RunResult {
                        exit: Exit::TimedOut,
                        output,
                    };
                }
                wait = wait.min(d.saturating_duration_since(now));
            }
            if open == 0 {
                // pipe は両方閉じたが、プロセスがまだ終わっていない。終わるのを待つ (空回りしない)
                std::thread::sleep(wait);
            } else {
                match rx.recv_timeout(wait) {
                    Ok(Some(line)) => {
                        on_line(&line);
                        output.push(line);
                    }
                    Ok(None) => open -= 1,
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => open = 0,
                }
            }
            if exited.is_none()
                && let Ok(Some(status)) = child.try_wait()
            {
                exited = Some((status, Instant::now()));
            }
            if let Some((status, at)) = exited
                && (open == 0 || at.elapsed() >= DRAIN_AFTER_EXIT)
            {
                return RunResult {
                    exit: match status.code() {
                        Some(c) => Exit::Code(c),
                        None => Exit::NoCode,
                    },
                    output,
                };
            }
        }
    }

    fn which(&self, name: &str) -> Option<PathBuf> {
        let path = std::env::var_os("PATH")?;
        let names = candidate_names(name);
        std::env::split_paths(&path)
            .flat_map(|dir| names.iter().map(move |n| dir.join(n)))
            .find(|p| p.is_file())
    }

    fn env(&self, name: &str) -> Option<String> {
        std::env::var(name).ok()
    }
}

fn candidate_names(name: &str) -> Vec<String> {
    let mut names = vec![name.to_string()];
    if cfg!(windows) && Path::new(name).extension().is_none() {
        for ext in ["exe", "cmd", "bat"] {
            names.push(format!("{name}.{ext}"));
        }
    }
    names
}

fn spawn_reader(stream: impl Read + Send + 'static, tx: mpsc::Sender<Option<String>>) {
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stream);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    let line = String::from_utf8_lossy(&buf);
                    let line = line.trim_end_matches(['\n', '\r']).to_string();
                    if tx.send(Some(line)).is_err() {
                        return;
                    }
                }
            }
        }
        let _ = tx.send(None);
    });
}

/// ANSI の色のエスケープ (`ESC [ … 文字`) を落とす (PowerShell が付けうる。WSL の wrapper の clean と同じ)。
pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for d in chars.by_ref() {
                if d.is_ascii_alphabetic() {
                    break;
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 本物の口で、stdout と stderr の行を流しながら写しを取り、終了コードを返す
    //! - 待つ上限を過ぎたら止めて「時間切れ」にする。起こせなければ「起こせなかった」
    //! - ANSI の色を落とす

    use super::*;

    #[cfg(unix)]
    fn shell(script: &str) -> CommandSpec {
        CommandSpec::new("sh").arg("-c").arg(script)
    }

    #[test]
    fn streams_lines_and_returns_code() {
        let mut seen = Vec::new();
        #[cfg(unix)]
        let spec = shell("echo one; echo two >&2; exit 3");
        // Windows は runner が ps1 を呼ぶのと同じく PowerShell の -Command で (cmd の引用符の読み方に頼らない)
        #[cfg(windows)]
        let spec = CommandSpec::new("powershell")
            .arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-Command")
            .arg("Write-Output one; [Console]::Error.WriteLine('two'); exit 3");
        let r = RealSys.run(&spec, &mut |l| seen.push(l.trim().to_string()));
        assert_eq!(r.exit, Exit::Code(3));
        let mut got: Vec<String> = r.output.iter().map(|l| l.trim().to_string()).collect();
        got.sort();
        assert_eq!(got, vec!["one", "two"]);
        assert_eq!(seen.len(), 2);
    }

    #[test]
    fn times_out() {
        #[cfg(unix)]
        let spec = shell("sleep 5").timeout(Duration::from_millis(300));
        #[cfg(windows)]
        let spec = CommandSpec::new("ping")
            .arg("-n")
            .arg("6")
            .arg("127.0.0.1")
            .timeout(Duration::from_millis(300));
        let start = Instant::now();
        let r = RealSys.run(&spec, &mut |_| {});
        assert_eq!(r.exit, Exit::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(4));
    }

    #[test]
    fn reports_spawn_failure() {
        let r = RealSys.run(
            &CommandSpec::new("no-such-command-dotfiles-win"),
            &mut |_| {},
        );
        assert!(matches!(r.exit, Exit::SpawnFailed(_)));
    }

    #[test]
    fn strips_ansi_colors() {
        assert_eq!(strip_ansi("\u{1b}[33m⚠ x\u{1b}[0m"), "⚠ x");
        assert_eq!(strip_ansi("plain"), "plain");
    }
}
