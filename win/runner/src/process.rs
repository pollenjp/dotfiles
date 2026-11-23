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
    /// 今のディレクトリ。無ければ runner のもの
    pub cwd: Option<PathBuf>,
    /// 足す env (`Some`) と外す env (`None`)。並べた順に効く
    pub envs: Vec<(OsString, Option<OsString>)>,
    /// stderr の行を写し (`RunResult::output`) に入れない。流す口 (`on_line`) には渡す
    pub stdout_only: bool,
    /// stdout の行を写しに入れない (`ssh -v -G` は読んだファイルを stderr に、設定を stdout に書く)。流す口には渡す
    pub stderr_only: bool,
}

impl CommandSpec {
    pub fn new(program: impl Into<PathBuf>) -> Self {
        CommandSpec {
            program: program.into(),
            args: Vec::new(),
            timeout: None,
            cwd: None,
            envs: Vec::new(),
            stdout_only: false,
            stderr_only: false,
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

    pub fn current_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.cwd = Some(dir.into());
        self
    }

    pub fn env(mut self, key: impl Into<OsString>, value: impl Into<OsString>) -> Self {
        self.envs.push((key.into(), Some(value.into())));
        self
    }

    pub fn env_remove(mut self, key: impl Into<OsString>) -> Self {
        self.envs.push((key.into(), None));
        self
    }

    pub fn stdout_only(mut self) -> Self {
        self.stdout_only = true;
        self
    }

    pub fn stderr_only(mut self) -> Self {
        self.stderr_only = true;
        self
    }

    /// その pipe の行を写しに入れるか
    fn keeps(&self, is_err: bool) -> bool {
        if is_err {
            !self.stdout_only
        } else {
            !self.stderr_only
        }
    }

    /// 足した env の値 (外したなら None。触っていなければ None)。試験で比べるため
    pub fn env_value(&self, key: &str) -> Option<String> {
        self.envs
            .iter()
            .rev()
            .find(|(k, _)| k == key)
            .and_then(|(_, v)| v.as_ref().map(|v| v.to_string_lossy().into_owned()))
    }

    /// その env を外すか (最後に触ったのが外すなら true)。試験で比べるため
    pub fn removes_env(&self, key: &str) -> bool {
        self.envs
            .iter()
            .rev()
            .find(|(k, _)| k == key)
            .is_some_and(|(_, v)| v.is_none())
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

/// runner が字を出す先 (色を付けるかを、出す先ごとに決める。`color::Paint::detect`)。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Stream {
    Stdout,
    Stderr,
}

pub trait Sys {
    /// コマンドを打つ。出力の行は届いたそばから `on_line` に渡す。
    fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult;
    /// PATH からコマンドを探す (Windows は拡張子の無い名前に .exe・.cmd・.bat も試す)。
    fn which(&self, name: &str) -> Option<PathBuf>;
    /// 環境変数
    fn env(&self, name: &str) -> Option<String>;
    /// この runner の exe のパス (claude-files が Claude Code の hook の口として写す)
    fn current_exe(&self) -> Option<PathBuf> {
        std::env::current_exe().ok()
    }
    /// 待つ (読みかけのファイルを読み直す前・PowerToys の設定画面がファイルを作るのを待つ間。試験の偽物は待たずに控える)
    fn sleep(&self, d: Duration) {
        std::thread::sleep(d);
    }
    /// 出す先が端末か (色を付けるかを決める。`color::Paint::detect`)。試験の偽物は端末でない (`FakeSys::with_terminal` で端末にする)
    fn is_terminal(&self, _stream: Stream) -> bool {
        false
    }
}

/// 本物の口。
pub struct RealSys;

/// プロセスが終わった後、孫が pipe を持ったままのときに、新しい行が来ないまま待つ長さ
const DRAIN_AFTER_EXIT: Duration = Duration::from_secs(2);
/// プロセスが終わった後に、孫の出力を待つ上限 (孫が書き続けても返る)
const DRAIN_LIMIT: Duration = Duration::from_secs(30);

impl Sys for RealSys {
    fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
        let mut command = Command::new(&spec.program);
        command
            .args(&spec.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(dir) = &spec.cwd {
            command.current_dir(dir);
        }
        for (key, value) in &spec.envs {
            match value {
                Some(v) => command.env(key, v),
                None => command.env_remove(key),
            };
        }
        let mut child = match command.spawn() {
            Ok(c) => c,
            Err(e) => {
                return RunResult {
                    exit: Exit::SpawnFailed(format!("{}: {e}", spec.program.display())),
                    output: Vec::new(),
                };
            }
        };
        let (tx, rx) = mpsc::channel::<Msg>();
        let mut readers = 0;
        if let Some(out) = child.stdout.take() {
            spawn_reader(out, false, tx.clone());
            readers += 1;
        }
        if let Some(err) = child.stderr.take() {
            spawn_reader(err, true, tx.clone());
            readers += 1;
        }
        drop(tx);

        let deadline = spec.timeout.map(|d| Instant::now() + d);
        let mut output = Vec::new();
        let mut open = readers;
        let mut exited: Option<(std::process::ExitStatus, Instant)> = None;
        // 終わった後、新しい行が来なくなってからの時間を数える起点。溜まった行を読み終える前に打ち切らず、孫が pipe を持った
        // ままでも返る
        let mut quiet_since = Instant::now();
        loop {
            let mut wait = Duration::from_millis(100);
            if exited.is_none()
                && let Some(d) = deadline
            {
                let now = Instant::now();
                if now >= d {
                    let _ = child.kill();
                    let _ = child.wait();
                    drain_ready(&rx, on_line, &mut output, &mut open, spec);
                    return RunResult {
                        exit: Exit::TimedOut,
                        output,
                    };
                }
                wait = wait.min(d - now);
            }
            if open == 0 {
                // pipe は両方閉じたが、プロセスがまだ終わっていない。終わるのを待つ (空回りしない。ふつうはすぐ終わるので、細かく見て
                // 待ちを延ばさない: Claude Code の hook と status line は打つたびに git を数回呼ぶ)
                std::thread::sleep(wait.min(Duration::from_millis(5)));
            } else {
                match rx.recv_timeout(wait) {
                    Ok(Some((is_err, line))) => {
                        accept(on_line, &mut output, spec, is_err, line);
                        quiet_since = Instant::now();
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
                quiet_since = Instant::now();
            }
            if let Some((status, at)) = exited {
                // 溜まっている行は待たずに全部受ける
                if drain_ready(&rx, on_line, &mut output, &mut open, spec) {
                    quiet_since = Instant::now();
                }
                if open == 0
                    || quiet_since.elapsed() >= DRAIN_AFTER_EXIT
                    || at.elapsed() >= DRAIN_LIMIT
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

    fn is_terminal(&self, stream: Stream) -> bool {
        use std::io::IsTerminal;
        match stream {
            Stream::Stdout => std::io::stdout().is_terminal(),
            Stream::Stderr => std::io::stderr().is_terminal(),
        }
    }
}

/// PATH で探す名前。Windows で拡張子の無い名前は .exe・.cmd・.bat だけを試す (拡張子の無い同名のファイル (npm の shim など) は
/// 起こせないので選ばない)。
fn candidate_names(name: &str) -> Vec<String> {
    if cfg!(windows) && Path::new(name).extension().is_none() {
        ["exe", "cmd", "bat"]
            .iter()
            .map(|ext| format!("{name}.{ext}"))
            .collect()
    } else {
        vec![name.to_string()]
    }
}

/// reader からの知らせ: 1 行 (stderr の行か・中身) か、その pipe が閉じた (`None`)。
type Msg = Option<(bool, String)>;

/// 受けた 1 行を流す口に渡し、写しに足す (`stdout_only` なら stderr の行、`stderr_only` なら stdout の行は写しに入れない)。
fn accept(
    on_line: &mut dyn FnMut(&str),
    output: &mut Vec<String>,
    spec: &CommandSpec,
    is_err: bool,
    line: String,
) {
    on_line(&line);
    if spec.keeps(is_err) {
        output.push(line);
    }
}

/// 溜まっている行を待たずに全部受ける。1 行でも受けたら true。
fn drain_ready(
    rx: &mpsc::Receiver<Msg>,
    on_line: &mut dyn FnMut(&str),
    output: &mut Vec<String>,
    open: &mut usize,
    spec: &CommandSpec,
) -> bool {
    let mut got = false;
    loop {
        match rx.try_recv() {
            Ok(Some((is_err, line))) => {
                accept(on_line, output, spec, is_err, line);
                got = true;
            }
            Ok(None) => *open = open.saturating_sub(1),
            Err(mpsc::TryRecvError::Empty) => return got,
            Err(mpsc::TryRecvError::Disconnected) => {
                *open = 0;
                return got;
            }
        }
    }
}

/// `stream` を行ごとに読んで `tx` へ送る (`is_err` は stderr の pipe か)。読み終えたら `None` を送る。
fn spawn_reader(stream: impl Read + Send + 'static, is_err: bool, tx: mpsc::Sender<Msg>) {
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stream);
        let mut buf = Vec::new();
        let mut first = true;
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    let line = String::from_utf8_lossy(&buf);
                    let mut line = line.trim_end_matches(['\n', '\r']);
                    if first {
                        // Windows PowerShell 5.1 は [Console]::OutputEncoding を UTF-8 (BOM 付きの Encoding) にすると、出力の頭に BOM を
                        // 書くことがある。見出しや締めの行の読みに混ざらないよう落とす
                        line = line.trim_start_matches('\u{feff}');
                        first = false;
                    }
                    if tx.send(Some((is_err, line.to_string()))).is_err() {
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

    #[cfg(windows)]
    fn powershell(script: &str) -> CommandSpec {
        CommandSpec::new("powershell")
            .arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-Command")
            .arg(script)
    }

    /// cwd と env を渡す (cargo install を claude-skills の clone の中で、clone の toolchain で打つため)
    #[test]
    fn runs_in_cwd_with_env() {
        let t = crate::testutil::TempDir::new("process-cwd");
        t.write("marker.txt", "here\n");
        #[cfg(unix)]
        let spec = shell("cat marker.txt; echo \"$DOTFILES_WIN_X\"");
        #[cfg(windows)]
        let spec = powershell("Get-Content marker.txt; Write-Output $env:DOTFILES_WIN_X");
        let r = RealSys.run(
            &spec.current_dir(t.path()).env("DOTFILES_WIN_X", "1"),
            &mut |_| {},
        );
        assert_eq!(r.exit, Exit::Code(0), "{:?}", r.output);
        let got: Vec<&str> = r.output.iter().map(|l| l.trim()).collect();
        assert_eq!(got, vec!["here", "1"]);
    }

    /// 親から受けた env を外す (cargo run で起こした runner に rustup が付ける RUSTUP_TOOLCHAIN を、pjp に渡さないため)
    #[test]
    fn env_remove_drops_an_inherited_variable() {
        // rustup の cargo から起こした試験の process には RUSTUP_TOOLCHAIN が付く。無ければ確かめられないので飛ばす
        if std::env::var_os("RUSTUP_TOOLCHAIN").is_none() {
            return;
        }
        #[cfg(unix)]
        let spec = shell("echo \"[${RUSTUP_TOOLCHAIN-}]\"");
        #[cfg(windows)]
        let spec = powershell("Write-Output \"[$env:RUSTUP_TOOLCHAIN]\"");
        let r = RealSys.run(&spec.env_remove("RUSTUP_TOOLCHAIN"), &mut |_| {});
        assert_eq!(r.exit, Exit::Code(0));
        let got: Vec<&str> = r.output.iter().map(|l| l.trim()).collect();
        assert_eq!(got, vec!["[]"]);
    }

    /// stdout だけを写しに入れる (`hc --skill` の出力を SKILL.md にする)。stderr の行も流す口には渡す (落ちたときに見える)
    #[test]
    fn stdout_only_keeps_stderr_out_of_output() {
        #[cfg(unix)]
        let spec = shell("echo out; echo err >&2");
        #[cfg(windows)]
        let spec = powershell("Write-Output out; [Console]::Error.WriteLine('err')");
        let mut seen = Vec::new();
        let r = RealSys.run(&spec.stdout_only(), &mut |l| {
            seen.push(l.trim().to_string())
        });
        assert_eq!(r.exit, Exit::Code(0));
        let got: Vec<&str> = r.output.iter().map(|l| l.trim()).collect();
        assert_eq!(got, vec!["out"]);
        seen.sort();
        assert_eq!(seen, vec!["err", "out"]);
    }

    /// stderr だけを写しに入れる (`ssh -v -G` の読んだファイル)。stdout の行も流す口には渡す
    #[test]
    fn stderr_only_keeps_stdout_out_of_output() {
        #[cfg(unix)]
        let spec = shell("echo out; echo err >&2");
        #[cfg(windows)]
        let spec = powershell("Write-Output out; [Console]::Error.WriteLine('err')");
        let mut seen = Vec::new();
        let r = RealSys.run(&spec.stderr_only(), &mut |l| {
            seen.push(l.trim().to_string())
        });
        assert_eq!(r.exit, Exit::Code(0));
        let got: Vec<&str> = r.output.iter().map(|l| l.trim()).collect();
        assert_eq!(got, vec!["err"]);
        seen.sort();
        assert_eq!(seen, vec!["err", "out"]);
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

    /// 終わった後に溜まっている行を、受ける側が遅くても全部受ける (締めの行は出力の最後にあるので、落とすと判定を誤る)
    #[test]
    fn keeps_every_line_even_when_the_receiver_is_slow() {
        #[cfg(unix)]
        let spec = shell("seq 1 3001");
        #[cfg(windows)]
        let spec = CommandSpec::new("powershell")
            .arg("-NoProfile")
            .arg("-NonInteractive")
            .arg("-Command")
            .arg("1..3001");
        let r = RealSys.run(&spec, &mut |_| {
            std::thread::sleep(Duration::from_millis(1));
        });
        assert_eq!(r.exit, Exit::Code(0));
        assert_eq!(r.output.len(), 3001);
        assert_eq!(r.output.last().map(|l| l.trim()), Some("3001"));
    }

    /// 孫が pipe を持ったままでも、終わってから新しい行が来なくなれば返る
    #[cfg(unix)]
    #[test]
    fn returns_while_a_grandchild_holds_the_pipe() {
        let start = Instant::now();
        let r = RealSys.run(&shell("sleep 8 & echo done"), &mut |_| {});
        assert_eq!(r.exit, Exit::Code(0));
        assert_eq!(r.output, vec!["done"]);
        assert!(
            start.elapsed() < Duration::from_secs(6),
            "{:?}",
            start.elapsed()
        );
    }

    #[test]
    fn candidate_names_per_os() {
        if cfg!(windows) {
            assert_eq!(
                candidate_names("git"),
                vec!["git.exe", "git.cmd", "git.bat"]
            );
            assert_eq!(candidate_names("pwsh.exe"), vec!["pwsh.exe"]);
        } else {
            assert_eq!(candidate_names("git"), vec!["git"]);
        }
    }
}
