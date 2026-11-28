//! 外のコマンドの起こし方 (spec §6.6 の「プロセス」「止める合図」)。
//!
//! - argv で渡す (shell を通さない)。stdin は既定で閉じる (`ntn api` は stdin を読むので、開けたままだと止まる)
//! - 出力は UTF-8 として読む (壊れたバイトは置き換える)
//! - 時間切れは孫ごと止める (Unix は process group、Windows は Job Object)。子が終わった後に出力のパイプを待つのは
//!   [`DRAIN_GRACE`] まで (孫がパイプを握ったまま残っても返る)
//! - [`run_passthrough`]・[`exec_replace`] は stdio を全部渡し、Ctrl+C (SIGINT) を子に任せる (親は子が終わるのを待つ)

use std::convert::Infallible;
use std::ffi::{OsStr, OsString};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex, PoisonError, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use crate::exit::{Launch, os_message};
use crate::{Error, Result, sys};

/// 子が終わった後に、出力のパイプの終わりを待つ長さ。
pub const DRAIN_GRACE: Duration = Duration::from_secs(2);

/// 起こすコマンド。
#[derive(Debug, Clone)]
pub struct Cmd {
    program: OsString,
    args: Vec<OsString>,
    cwd: Option<PathBuf>,
    /// 順に当てる env の操作 (`None` は消す)。
    env: Vec<(OsString, Option<OsString>)>,
    /// 親の env を継がず、`env` の操作だけで子の env を作る。
    clear_env: bool,
    stdin: Option<Vec<u8>>,
    timeout: Option<Duration>,
}

/// [`Cmd::output`] の結果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    /// 終了コード。signal で終わった・時間切れで止めたときは None。
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

impl Output {
    /// 時間切れでなく、終了コード 0 で終わった。
    pub fn success(&self) -> bool {
        !self.timed_out && self.code == Some(0)
    }
}

impl Cmd {
    pub fn new(program: impl AsRef<OsStr>) -> Self {
        Self {
            program: program.as_ref().to_owned(),
            args: Vec::new(),
            cwd: None,
            env: Vec::new(),
            clear_env: false,
            stdin: None,
            timeout: None,
        }
    }

    /// 親の env を継がない (子の env は、この後に当てる `env` だけになる。Python の `subprocess.run(env=…)` と同じ)。
    pub fn env_clear(mut self) -> Self {
        self.clear_env = true;
        self.env.clear();
        self
    }

    pub fn arg(mut self, arg: impl AsRef<OsStr>) -> Self {
        self.args.push(arg.as_ref().to_owned());
        self
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.args
            .extend(args.into_iter().map(|a| a.as_ref().to_owned()));
        self
    }

    pub fn cwd(mut self, dir: impl AsRef<Path>) -> Self {
        self.cwd = Some(dir.as_ref().to_owned());
        self
    }

    pub fn env(mut self, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> Self {
        self.env
            .push((key.as_ref().to_owned(), Some(value.as_ref().to_owned())));
        self
    }

    pub fn env_remove(mut self, key: impl AsRef<OsStr>) -> Self {
        self.env.push((key.as_ref().to_owned(), None));
        self
    }

    /// stdin に流すバイト ([`Cmd::output`] だけ。渡さなければ stdin は閉じる)。
    pub fn stdin_bytes(mut self, data: impl Into<Vec<u8>>) -> Self {
        self.stdin = Some(data.into());
        self
    }

    /// 時間切れ ([`Cmd::output`] だけ)。過ぎたら孫ごと止めて `timed_out` を立てる。
    ///
    /// 時間切れを付けると、子を組に入れる (Unix は新しい process group、Windows は Job Object)。Unix では子が端末の
    /// process group の外に出るので、端末の Ctrl+C が子に届かない (道具を Ctrl+C で止めても、走っている子は終わりまで
    /// 動く)。子が端末 (`/dev/tty`) を読むと SIGTTIN で止まる。時間切れで止めるときは、子が起こした常駐 (同じ組・同じ
    /// job にいるもの) も一緒に止める。
    pub fn timeout(mut self, d: Duration) -> Self {
        self.timeout = Some(d);
        self
    }

    pub fn program(&self) -> &OsStr {
        &self.program
    }

    pub fn get_args(&self) -> &[OsString] {
        &self.args
    }

    /// 当てる env の操作を、当てる順に (値が `None` は消す)。偽の Runner で打ち方を確かめるテスト用。
    pub fn get_envs(&self) -> impl Iterator<Item = (&OsStr, Option<&OsStr>)> {
        self.env.iter().map(|(k, v)| (k.as_os_str(), v.as_deref()))
    }

    /// 親の env を継がないか ([`Cmd::env_clear`])。偽の Runner で打ち方を確かめるテスト用。
    pub fn env_cleared(&self) -> bool {
        self.clear_env
    }

    pub fn get_cwd(&self) -> Option<&Path> {
        self.cwd.as_deref()
    }

    /// 時間切れ ([`Cmd::timeout`])。偽の Runner で打ち方を確かめるテスト用。
    pub fn get_timeout(&self) -> Option<Duration> {
        self.timeout
    }

    /// stdin に流すバイト ([`Cmd::stdin_bytes`]。渡していなければ None)。偽の Runner で打ち方を確かめるテスト用。
    pub fn get_stdin(&self) -> Option<&[u8]> {
        self.stdin.as_deref()
    }

    /// 子に渡す PATH (最後に当てた PATH の操作。当てていなければ親の PATH)。
    fn child_path(&self) -> Option<OsString> {
        let is_path = |k: &OsStr| {
            if cfg!(windows) {
                k.eq_ignore_ascii_case("PATH")
            } else {
                k == "PATH"
            }
        };
        match self.env.iter().rev().find(|(k, _)| is_path(k)) {
            Some((_, v)) => v.clone(),
            None if self.clear_env => None,
            None => std::env::var_os("PATH"),
        }
    }

    /// 子に渡す env の全部 (親の env に操作を当てたもの。`env_clear` なら操作だけ)。
    #[cfg_attr(windows, allow(dead_code))]
    fn child_env(&self) -> Vec<(OsString, OsString)> {
        let same = |a: &OsStr, b: &OsStr| {
            if cfg!(windows) {
                a.eq_ignore_ascii_case(b)
            } else {
                a == b
            }
        };
        let mut out: Vec<(OsString, OsString)> = if self.clear_env {
            Vec::new()
        } else {
            std::env::vars_os().collect()
        };
        for (k, v) in &self.env {
            out.retain(|(name, _)| !same(name, k));
            if let Some(v) = v {
                out.push((k.clone(), v.clone()));
            }
        }
        out
    }

    /// 起こして終わりを待ち、stdout・stderr を受ける。起こせなければ Err (見つからないときは終了コード 2)。
    pub fn output(&self) -> Result<Output> {
        let mut c = self.command();
        c.stdin(if self.stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
        if self.timeout.is_some() {
            sys::prepare_group(&mut c);
        }
        let mut child = c.spawn().map_err(|e| self.spawn_error(&e))?;
        let group = self.timeout.and_then(|_| sys::Group::attach(&child));

        if let (Some(data), Some(mut pipe)) = (self.stdin.clone(), child.stdin.take()) {
            // 書き終わりは待たない (子が読まずに終わると書き込みは失敗して終わる。孫が握っていても、ここで止まらない)
            thread::spawn(move || {
                let _ = pipe.write_all(&data);
            });
        }
        let (done_tx, done_rx) = mpsc::channel();
        let stdout = drain(child.stdout.take(), done_tx.clone());
        let stderr = drain(child.stderr.take(), done_tx);

        let (status, timed_out) = wait(&mut child, self.timeout, group.as_ref()).map_err(|e| {
            Error::failure(format!(
                "{} を待てません: {e}",
                self.program.to_string_lossy()
            ))
        })?;

        let deadline = Instant::now() + DRAIN_GRACE;
        for _ in 0..2 {
            let left = deadline.saturating_duration_since(Instant::now());
            if done_rx.recv_timeout(left).is_err() {
                break;
            }
        }
        Ok(Output {
            code: if timed_out { None } else { status.code() },
            stdout: take_text(&stdout),
            stderr: take_text(&stderr),
            timed_out,
        })
    }

    fn command(&self) -> Command {
        // Windows の std は、素の名前を PATH より先に「この exe のディレクトリ」(target/release など) から探す。clone の
        // workspace に同じ名前の bin (テストの偽の ntn など) があると、本物の代わりにそれを起こすので、PATH から引いて渡す
        let program = if cfg!(windows) {
            resolve_bare(&self.program, self.child_path().as_deref())
        } else {
            self.program.clone()
        };
        let mut c = Command::new(program);
        c.args(&self.args);
        if let Some(dir) = &self.cwd {
            c.current_dir(dir);
        }
        if self.clear_env {
            c.env_clear();
        }
        for (key, value) in &self.env {
            match value {
                Some(v) => c.env(key, v),
                None => c.env_remove(key),
            };
        }
        c
    }

    fn spawn_error(&self, err: &std::io::Error) -> Error {
        let name = self.program.to_string_lossy();
        if let Some(dir) = self.cwd.as_ref().filter(|d| !d.is_dir()) {
            return Error::failure(format!(
                "{name} を起こせません: 作業ディレクトリ {} がありません",
                dir.display()
            ));
        }
        // PATH の途中にファイルがあると ENOTDIR になるが、PATH のどこにも無いのと同じ (Python の NotADirectoryError と同じ扱い)
        if matches!(
            err.kind(),
            std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
        ) {
            Error::config(format!("{name} が見つかりません (PATH を確かめてください)"))
                .with_launch(Launch::NotFound)
        } else {
            Error::failure(format!("{name} を起こせません: {err}"))
                .with_launch(Launch::Failed(os_message(err)))
        }
    }
}

type Buffer = Arc<Mutex<Vec<u8>>>;

/// パイプを裏で読み切って `Buffer` に溜める。読み終えたら `done` に知らせる。
fn drain(pipe: Option<impl Read + Send + 'static>, done: mpsc::Sender<()>) -> Buffer {
    let buf = Buffer::default();
    let sink = Arc::clone(&buf);
    thread::spawn(move || {
        if let Some(mut pipe) = pipe {
            let mut chunk = [0u8; 8192];
            loop {
                match pipe.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => sink
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .extend_from_slice(&chunk[..n]),
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => break,
                }
            }
        }
        let _ = done.send(());
    });
    buf
}

fn take_text(buf: &Buffer) -> String {
    let bytes = std::mem::take(&mut *buf.lock().unwrap_or_else(PoisonError::into_inner));
    String::from_utf8(bytes).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

/// 子の終わりを待つ。時間切れなら組ごと止めてから待ち、(終了の状態, 時間切れか) を返す。
fn wait(
    child: &mut Child,
    timeout: Option<Duration>,
    group: Option<&sys::Group>,
) -> std::io::Result<(ExitStatus, bool)> {
    let Some(limit) = timeout else {
        return Ok((child.wait()?, false));
    };
    let deadline = Instant::now() + limit;
    let mut nap = Duration::from_millis(1);
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok((status, false));
        }
        let now = Instant::now();
        if now >= deadline {
            if let Some(g) = group {
                g.kill();
            }
            // 組を作れなかったときの代わり (もう止まっていれば Err が返るが、気にしない)
            let _ = child.kill();
            return Ok((child.wait()?, true));
        }
        thread::sleep(nap.min(deadline - now));
        nap = (nap * 2).min(Duration::from_millis(50));
    }
}

/// stdio を全部渡して起こし、終わりを待って終了コードを返す。待つ間、Ctrl+C (SIGINT・SIGQUIT・Ctrl+Break) は子に任せる。
/// `stdin_bytes`・`timeout` は使わない。
pub fn run_passthrough(cmd: &Cmd) -> Result<i32> {
    let mut c = cmd.command();
    c.stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    sys::interrupts_to_child(|| {
        let mut child = c.spawn().map_err(|e| cmd.spawn_error(&e))?;
        let status = child.wait().map_err(|e| {
            Error::failure(format!(
                "{} を待てません: {e}",
                cmd.program.to_string_lossy()
            ))
        })?;
        Ok(exit_code_of(status))
    })
}

/// この process を `cmd` に置き換える。Unix は exec (戻るのは失敗のときだけ)。Windows は [`run_passthrough`] で待ち、
/// 子の終了コードで終わる。
pub fn exec_replace(cmd: &Cmd) -> Result<Infallible> {
    #[cfg(unix)]
    {
        // std の exec (glibc の execvp) は ENOEXEC のファイルを /bin/sh で動かすので、execve を PATH の順に自分で回す
        // (Python の os.execvpe と同じ。Exec format error で止まる)
        if let Some(dir) = &cmd.cwd {
            std::env::set_current_dir(dir).map_err(|e| cmd.spawn_error(&e))?;
        }
        let program = Path::new(&cmd.program);
        let candidates: Vec<PathBuf> = if program.components().count() > 1 || cmd.program.is_empty()
        {
            vec![program.to_path_buf()]
        } else {
            cmd.child_path()
                .map(|p| {
                    std::env::split_paths(&p)
                        .filter(|d| !d.as_os_str().is_empty())
                        .map(|d| d.join(program))
                        .collect()
                })
                .unwrap_or_default()
        };
        let mut argv = vec![cmd.program.clone()];
        argv.extend(cmd.args.iter().cloned());
        let err = sys::execve_first(&candidates, &argv, &cmd.child_env());
        Err(cmd.spawn_error(&err))
    }
    #[cfg(windows)]
    {
        let code = run_passthrough(cmd)?;
        std::process::exit(code)
    }
}

/// 今の process の env (UTF-8 でない値は置き換えて読む)。Windows は名前を大文字にそろえる (Windows の env の名前は
/// 大文字小文字を区別しない。Python の `os.environ` と同じ)。
pub fn environment() -> Vec<(String, String)> {
    std::env::vars_os()
        .map(|(k, v)| {
            let k = k.to_string_lossy();
            let k = if cfg!(windows) {
                k.to_uppercase()
            } else {
                k.into_owned()
            };
            (k, v.to_string_lossy().into_owned())
        })
        .collect()
}

/// 終了の状態を終了コードにする。Unix で signal で終わったものは 128+n (shell と同じ)。
pub fn exit_code_of(status: ExitStatus) -> i32 {
    status
        .code()
        .or_else(|| sys::signal_of(&status).map(|s| 128 + s))
        .unwrap_or(1)
}

/// 素の名前 (区切りを含まない) なら `path_var` から引いた絶対パス、見つからない・素の名前でなければそのまま。
pub fn resolve_bare(program: &OsStr, path_var: Option<&OsStr>) -> OsString {
    let mut parts = Path::new(program).components();
    let bare = matches!(
        (parts.next(), parts.next()),
        (Some(std::path::Component::Normal(_)), None)
    );
    if !bare {
        return program.to_owned();
    }
    path_var
        .and_then(|pv| find_in(pv, &program.to_string_lossy()))
        .map_or_else(|| program.to_owned(), PathBuf::into_os_string)
}

/// PATH から `name` を探す (Windows は PATHEXT の拡張子も試す)。
pub fn find_in_path(name: &str) -> Option<PathBuf> {
    find_in(&std::env::var_os("PATH")?, name)
}

/// `path_var` (PATH と同じ形) から `name` を探す。
pub fn find_in(path_var: &OsStr, name: &str) -> Option<PathBuf> {
    // Windows は拡張子の無い名前に PATHEXT を足して探す (拡張子は小文字にそろえて返す)
    let exts: Vec<String> = if cfg!(windows) && Path::new(name).extension().is_none() {
        std::env::var("PATHEXT")
            .unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".to_owned())
            .split(';')
            .filter(|e| !e.is_empty())
            .map(str::to_ascii_lowercase)
            .collect()
    } else {
        vec![String::new()]
    };
    std::env::split_paths(path_var)
        .filter(|dir| !dir.as_os_str().is_empty())
        .flat_map(|dir| exts.iter().map(move |ext| dir.join(format!("{name}{ext}"))))
        .find(|p| sys::is_executable(p))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::exit::CONFIG;
    use crate::testutil::TempDir;
    use std::time::Instant;

    /// OS の shell で 1 行を流す Cmd (Unix は `sh -c`、Windows は `cmd /C`)。
    fn shell(line: &str) -> Cmd {
        if cfg!(windows) {
            Cmd::new("cmd").args(["/C", line])
        } else {
            Cmd::new("sh").args(["-c", line])
        }
    }

    #[test]
    fn output_captures_stdout_stderr_and_code() {
        let out = if cfg!(windows) {
            shell("echo out& echo err 1>&2& exit /b 3")
        } else {
            shell("echo out; echo err 1>&2; exit 3")
        }
        .output()
        .unwrap();
        assert_eq!(out.stdout.trim(), "out");
        assert_eq!(out.stderr.trim(), "err");
        assert_eq!(out.code, Some(3));
        assert!(!out.timed_out);
        assert!(!out.success());
    }

    #[test]
    fn stdin_is_closed_by_default() {
        // sort は stdin の終わりまで読む。閉じていなければ時間切れになる
        let out = Cmd::new("sort")
            .timeout(Duration::from_secs(10))
            .output()
            .unwrap();
        assert!(!out.timed_out, "{out:?}");
        assert!(out.success(), "{out:?}");
        assert_eq!(out.stdout.trim(), "");
    }

    #[test]
    fn stdin_bytes_are_fed_while_output_is_read() {
        // パイプの容量より大きく流しても、書くのと読むのが詰まらない
        let input: String = (0..200_000).rev().map(|i| format!("{i:07}\n")).collect();
        let out = Cmd::new("sort")
            .stdin_bytes(input)
            .timeout(Duration::from_secs(60))
            .output()
            .unwrap();
        assert!(out.success(), "{:?}", out.stderr);
        let lines: Vec<&str> = out.stdout.lines().collect();
        assert_eq!(lines.len(), 200_000);
        assert_eq!(lines[0], "0000000");
        assert_eq!(lines[199_999], "0199999");
    }

    #[test]
    fn missing_program_is_config_error() {
        let e = Cmd::new("pjp-no-such-program-xyz").output().unwrap_err();
        assert_eq!(e.code(), CONFIG);
        assert!(e.message().contains("pjp-no-such-program-xyz"), "{e}");
    }

    #[test]
    fn launch_kind_missing_program() {
        let e = Cmd::new("pjp-no-such-program-xyz").output().unwrap_err();
        assert_eq!(e.launch(), Some(&Launch::NotFound));
        let e = run_passthrough(&Cmd::new("pjp-no-such-program-xyz")).unwrap_err();
        assert_eq!(e.launch(), Some(&Launch::NotFound));
        // 作業ディレクトリが無いのは、起こすものが無いのとは別 (わけを付けない)
        let e = shell("echo x")
            .cwd("/pjp/no/such/dir")
            .output()
            .unwrap_err();
        assert_eq!(e.launch(), None);
    }

    #[cfg(unix)]
    #[test]
    fn launch_kind_not_executable() {
        let t = TempDir::new("not-executable");
        let script = t.write("tool", "#!/bin/sh\necho x\n");
        // 書いたファイルは実行の権限を持たない (umask の既定)。起こすと EACCES
        let e = Cmd::new(&script).output().unwrap_err();
        assert_eq!(
            e.launch(),
            Some(&Launch::Failed("Permission denied".to_owned()))
        );
        assert_eq!(e.code(), crate::exit::FAILURE);
    }

    #[test]
    fn exec_replace_missing_program_returns_not_found() {
        let e = exec_replace(&Cmd::new("pjp-no-such-program-xyz")).unwrap_err();
        assert_eq!(e.launch(), Some(&Launch::NotFound));
    }

    /// ELF でも `#!` でもない実行できるファイルは、/bin/sh に回さず Exec format error で止まる (Python の os.execvpe と同じ)。
    /// exec に成功すると test の process が置き換わるので、子の test の process で exec して、出力で見分ける。
    #[cfg(unix)]
    #[test]
    fn exec_replace_reports_exec_format_error() {
        const CHILD: &str = "PJP_CORE_EXEC_CHILD";
        if let Some(path) = std::env::var_os(CHILD) {
            let e = exec_replace(&Cmd::new(&path)).unwrap_err();
            println!("launch={:?}", e.launch());
            return;
        }
        let t = TempDir::new("enoexec");
        let script = t.write("noshebang", "echo ran-by-sh\n");
        crate::fs::set_mode(&script, 0o755).unwrap();
        let out = Cmd::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "process::tests::exec_replace_reports_exec_format_error",
                "--nocapture",
                "--test-threads=1",
            ])
            .env(CHILD, &script)
            .output()
            .unwrap();
        assert!(!out.stdout.contains("ran-by-sh"), "{}", out.stdout);
        assert!(
            out.stdout
                .contains("launch=Some(Failed(\"Exec format error\"))"),
            "{}{}",
            out.stdout,
            out.stderr
        );
    }

    #[cfg(unix)]
    #[test]
    fn env_clear_passes_only_the_given_env() {
        let out = Cmd::new("/bin/sh")
            .args(["-c", "echo \"[$HOME][$PJP_X]\""])
            .env_clear()
            .env("PJP_X", "1")
            .output()
            .unwrap();
        assert_eq!(out.stdout.trim(), "[][1]");
        assert_eq!(Cmd::new("x").env_clear().child_path(), None);
    }

    #[test]
    fn environment_has_path() {
        // Windows は名前を大文字にそろえるので、どちらの OS も PATH で引ける
        let names: Vec<String> = environment().into_iter().map(|(k, _)| k).collect();
        assert!(names.iter().any(|k| k == "PATH"), "{names:?}");
    }

    #[test]
    fn missing_cwd_is_reported_as_cwd() {
        let e = shell("echo x")
            .cwd("/pjp/no/such/dir")
            .output()
            .unwrap_err();
        assert!(e.message().contains("/pjp/no/such/dir"), "{e}");
    }

    #[test]
    fn timeout_kills_grandchildren() {
        // 孫 (sleep・ping) がパイプを握る。孫ごと止めれば、すぐに返る。子だけ止めると DRAIN_GRACE (2 秒) まで待つ
        let cmd = if cfg!(windows) {
            Cmd::new("cmd").args(["/C", "ping", "-n", "30", "127.0.0.1"])
        } else {
            shell("sleep 30 & sleep 30")
        };
        let start = Instant::now();
        let out = cmd.timeout(Duration::from_millis(200)).output().unwrap();
        let took = start.elapsed();
        assert!(out.timed_out, "{out:?}");
        assert!(!out.success());
        assert!(took < Duration::from_millis(1800), "{took:?}");
    }

    #[test]
    fn env_and_cwd_are_applied() {
        let t = TempDir::new("env-cwd");
        let line = if cfg!(windows) {
            "echo %PJP_T%& echo [%PJP_GONE%]& cd"
        } else {
            "echo \"$PJP_T\"; echo \"[${PJP_GONE-unset}]\"; pwd"
        };
        let out = shell(line)
            .env("PJP_T", "hello")
            .env("PJP_GONE", "x")
            .env_remove("PJP_GONE")
            .cwd(t.path())
            .output()
            .unwrap();
        let lines: Vec<&str> = out.stdout.lines().map(str::trim).collect();
        assert_eq!(lines[0], "hello");
        let gone = if cfg!(windows) {
            "[%PJP_GONE%]"
        } else {
            "[unset]"
        };
        assert_eq!(lines[1], gone);
        assert!(
            crate::paths::same_path(lines[2], &t.path().to_string_lossy(), cfg!(windows)),
            "{lines:?}"
        );
    }

    #[test]
    fn cmd_exposes_what_it_will_run() {
        let c = Cmd::new("ntn")
            .args(["api", "-d", "@-"])
            .env("A", "1")
            .env_remove("B");
        assert_eq!(c.program(), "ntn");
        assert_eq!(c.get_args(), ["api", "-d", "@-"]);
        let envs: Vec<_> = c.get_envs().collect();
        assert_eq!(
            envs,
            [
                (OsStr::new("A"), Some(OsStr::new("1"))),
                (OsStr::new("B"), None)
            ]
        );
    }

    #[test]
    fn resolve_bare_uses_path_for_bare_names_only() {
        let t = TempDir::new("resolve-bare");
        let name = if cfg!(windows) { "tool.exe" } else { "tool" };
        let tool = t.write(name, "x");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let pv = std::env::join_paths([t.path()]).unwrap();
        assert_eq!(
            resolve_bare(OsStr::new("tool"), Some(&pv)),
            tool.as_os_str()
        );
        assert_eq!(resolve_bare(OsStr::new("nosuch"), Some(&pv)), "nosuch");
        assert_eq!(resolve_bare(tool.as_os_str(), Some(&pv)), tool.as_os_str());
        assert_eq!(resolve_bare(OsStr::new("sub/tool"), Some(&pv)), "sub/tool");
        assert_eq!(resolve_bare(OsStr::new("tool"), None), "tool");
    }

    #[test]
    fn child_path_follows_env_overrides() {
        assert_eq!(
            Cmd::new("x").env("PATH", "/a").child_path().as_deref(),
            Some(OsStr::new("/a"))
        );
        assert_eq!(
            Cmd::new("x")
                .env("PATH", "/a")
                .env_remove("PATH")
                .child_path(),
            None
        );
        assert_eq!(Cmd::new("x").child_path(), std::env::var_os("PATH"));
        assert_eq!(Cmd::new("x").cwd("/w").get_cwd(), Some(Path::new("/w")));
    }

    #[test]
    fn find_in_path_finds_and_misses() {
        let t = TempDir::new("find-in");
        let name = if cfg!(windows) { "tool.exe" } else { "tool" };
        let tool = t.write(name, "x");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tool, std::fs::Permissions::from_mode(0o755)).unwrap();
            t.write("noexec", "x");
        }
        let path_var =
            std::env::join_paths([t.path().join("missing"), t.path().to_path_buf()]).unwrap();
        assert_eq!(find_in(&path_var, "tool"), Some(tool));
        assert_eq!(find_in(&path_var, "nosuch"), None);
        #[cfg(unix)]
        assert_eq!(find_in(&path_var, "noexec"), None);
    }

    #[test]
    fn run_passthrough_returns_child_code() {
        assert_eq!(run_passthrough(&shell("exit 7")).unwrap(), 7);
        assert_eq!(
            run_passthrough(&Cmd::new("pjp-no-such-program-xyz"))
                .unwrap_err()
                .code(),
            CONFIG
        );
    }

    #[cfg(unix)]
    #[test]
    fn exit_code_of_signal_is_128_plus() {
        let out = shell("kill -9 $$").output().unwrap();
        assert_eq!(out.code, None);
        assert_eq!(run_passthrough(&shell("kill -9 $$")).unwrap(), 128 + 9);
    }
}
