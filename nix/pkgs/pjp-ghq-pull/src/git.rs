//! ユーザーの git を子プロセスで呼ぶ。
//!
//! 子は端末から切り離す (新しい session・stdin は null・GIT_TERMINAL_PROMPT=0)。制御端末が無いので、ssh や git が
//! /dev/tty を開いてパスワードや host key の確認を待てず、入力待ちは失敗として返る。画面 (raw mode の端末) を
//! 子に奪われることもない。GIT_SSH_COMMAND などは触らない (ユーザーの core.sshCommand をそのまま効かせる)。
//!
//! 時間切れを付けるのは通信 (fetch) だけ。切れたら子の process group に SIGTERM を送り (git は lock を消して
//! 終わる)、2 秒で終わらなければ SIGKILL を送る。

use std::ffi::OsString;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// git が -C より先に使う、repo を指す env
const REPO_ENV: [&str; 7] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
];

/// SIGTERM の後、SIGKILL を送るまで待つ時間
const TERM_GRACE: Duration = Duration::from_secs(2);
/// 子が終わったかを見る間隔
const POLL: Duration = Duration::from_millis(20);
/// 子が終わった後、stdout・stderr を読み切るのを待つ時間 (子の下に pipe を握ったままのプロセスが残ったときに止まらない)
const READ_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone, Debug)]
pub struct Git {
    /// fetch を git gh で打つ (gitViaGh)
    pub via_gh: bool,
    /// fetch の時間切れ
    pub fetch_timeout: Duration,
    /// 子に足す env (テストが HOME・git の設定・PATH を差し替える。ふだんは空)
    pub env: Vec<(OsString, OsString)>,
    /// q・Ctrl-C で立てる。立った後、flow は次の git (fetch・merge など) を起こさない
    pub stop: Arc<AtomicBool>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Output {
    pub success: bool,
    pub timed_out: bool,
    pub stdout: String,
    pub stderr: String,
}

impl Git {
    pub fn new(via_gh: bool, fetch_timeout: Duration, env: Vec<(OsString, OsString)>) -> Git {
        Git {
            via_gh,
            fetch_timeout,
            env,
            stop: Arc::new(AtomicBool::new(false)),
        }
    }

    /// q・Ctrl-C で止めた後か
    pub fn stopped(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }

    /// 時間切れなしで流す (ローカルだけの git と、問いで選んだ merge・rebase)
    pub fn run(&self, dir: &Path, args: &[&str]) -> Output {
        self.run_timeout(dir, args, None)
    }

    pub fn run_timeout(&self, dir: &Path, args: &[&str], timeout: Option<Duration>) -> Output {
        let mut cmd = Command::new("git");
        cmd.arg("-C").arg(dir).args(args);
        for (k, v) in &self.env {
            cmd.env(k, v);
        }
        run_detached(cmd, timeout)
    }

    /// origin を fetch --prune する。gitViaGh なら git gh で打つ。時間切れは fetch_timeout
    pub fn fetch(&self, dir: &Path) -> Output {
        let args: &[&str] = if self.via_gh {
            &["gh", "fetch", "--prune", "origin"]
        } else {
            &["fetch", "--prune", "origin"]
        };
        self.run_timeout(dir, args, Some(self.fetch_timeout))
    }
}

/// cmd を端末から切り離して流し、終わるのを待つ (git のほか、gitViaGh の事前確認の gh も)
pub(crate) fn run_detached(mut cmd: Command, timeout: Option<Duration>) -> Output {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("GIT_TERMINAL_PROMPT", "0");
    // 呼んだ側 (git の hook や alias の中など) の repo を指す env を外し、git -C の dir の repo を見させる
    for var in REPO_ENV {
        cmd.env_remove(var);
    }
    // SAFETY: fork の後・exec の前に呼ぶのは async-signal-safe な setsid だけ
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(e) => {
            let program = cmd.get_program().to_string_lossy().into_owned();
            return Output {
                stderr: format!("{program} を起こせません: {e}"),
                ..Output::default()
            };
        }
    };
    let stdout = read_in_background(child.stdout.take());
    let stderr = read_in_background(child.stderr.take());
    let (status, timed_out) = wait(&mut child, timeout);
    Output {
        success: !timed_out && status.is_some_and(|s| s.success()),
        timed_out,
        stdout: stdout.finish(),
        stderr: stderr.finish(),
    }
}

/// 子が終わるのを待つ。時間切れなら process group を止めて (status, true) を返す
fn wait(child: &mut Child, timeout: Option<Duration>) -> (Option<ExitStatus>, bool) {
    let deadline = timeout.map(|t| Instant::now() + t);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return (Some(status), false),
            Ok(None) => {}
            Err(_) => return (None, false),
        }
        if deadline.is_some_and(|d| Instant::now() >= d) {
            return (stop(child), true);
        }
        thread::sleep(POLL);
    }
}

/// process group に SIGTERM、終わらなければ SIGKILL。子が終わった後も group に残ったもの (ssh など) へ SIGKILL を送る
fn stop(child: &mut Child) -> Option<ExitStatus> {
    signal_group(child, libc::SIGTERM);
    let deadline = Instant::now() + TERM_GRACE;
    let mut status = None;
    while Instant::now() < deadline {
        if let Ok(Some(s)) = child.try_wait() {
            status = Some(s);
            break;
        }
        thread::sleep(POLL);
    }
    signal_group(child, libc::SIGKILL);
    status.or_else(|| child.wait().ok())
}

/// setsid で子は自分の process group の頭なので、-pid で孫 (ssh・git-remote-https など) にも届く
fn signal_group(child: &Child, sig: libc::c_int) {
    let pgid = child.id() as libc::pid_t;
    // SAFETY: kill は引数の数値だけを使う。group が空なら ESRCH で何もしない
    unsafe {
        libc::kill(-pgid, sig);
    }
}

/// pipe を別の thread で読み切る (読まないと pipe が詰まって子が止まる)
struct Reader {
    buf: Arc<Mutex<Vec<u8>>>,
    done: mpsc::Receiver<()>,
}

impl Reader {
    /// 読み終わるのを READ_GRACE まで待ち、そこまでに読めた分を返す
    fn finish(self) -> String {
        let _ = self.done.recv_timeout(READ_GRACE);
        let buf = self.buf.lock().map(|b| b.clone()).unwrap_or_default();
        String::from_utf8_lossy(&buf).into_owned()
    }
}

fn read_in_background<R: Read + Send + 'static>(pipe: Option<R>) -> Reader {
    let buf = Arc::new(Mutex::new(Vec::new()));
    let (tx, done) = mpsc::channel();
    let shared = Arc::clone(&buf);
    thread::spawn(move || {
        if let Some(mut pipe) = pipe {
            let mut chunk = [0u8; 8192];
            loop {
                match pipe.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if let Ok(mut b) = shared.lock() {
                            b.extend_from_slice(&chunk[..n]);
                        }
                    }
                }
            }
        }
        let _ = tx.send(());
    });
    Reader { buf, done }
}
