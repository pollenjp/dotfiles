//! Unix (Linux・macOS) の FFI。

#![expect(
    unsafe_code,
    reason = "process group への signal・SIGINT の受け方・端末の echo を止める termios は libc でしか書けない"
)]

use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Child, Command, ExitStatus};

/// 時間切れで止める組 (子を頭にした process group)。
pub(crate) struct Group {
    pgid: libc::pid_t,
}

/// 起こす前に、子を新しい process group (pgid = 子の pid) に入れる。
pub(crate) fn prepare_group(cmd: &mut Command) {
    cmd.process_group(0);
}

impl Group {
    pub(crate) fn attach(child: &Child) -> Option<Group> {
        libc::pid_t::try_from(child.id())
            .ok()
            .map(|pgid| Group { pgid })
    }

    /// 組の全員に SIGKILL を送る (子は待つまで zombie で残るので、pgid は他に使われていない)。
    pub(crate) fn kill(&self) {
        // SAFETY: kill(2) は値だけを読む。負の pid は process group を指す
        unsafe {
            libc::kill(-self.pgid, libc::SIGKILL);
        }
    }
}

pub(crate) fn signal_of(status: &ExitStatus) -> Option<i32> {
    status.signal()
}

pub(crate) fn is_executable(path: &Path) -> bool {
    path.metadata()
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

/// Unix の権限を変える (変えたら true)。
pub(crate) fn set_mode(path: &Path, mode: u32) -> std::io::Result<bool> {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).map(|()| true)
}

/// Unix の権限 (`0o7777` の範囲)。
pub(crate) fn mode_of(meta: &std::fs::Metadata) -> Option<u32> {
    Some(meta.permissions().mode() & 0o7777)
}

/// Unix には Windows の DACL が無い (何もせず false。権限は set_mode)。
pub(crate) fn set_owner_only(_path: &Path, _inherit: bool) -> std::io::Result<bool> {
    Ok(false)
}

/// Unix には Windows の DACL が無い。
pub(crate) fn access_of(_path: &Path) -> Option<std::io::Result<crate::fs::Access>> {
    None
}

/// stdin の端末を、echo・行の編集・signal の字 (Ctrl+C など) を止めた形にしておく間の印。Drop で元に戻す。
struct RawTerm {
    old: libc::termios,
}

impl RawTerm {
    fn enter() -> std::io::Result<RawTerm> {
        // SAFETY: termios は C の構造体で、0 で埋めた値を tcgetattr が全部書き直す
        let mut old: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: old は書ける領域。失敗は -1 で返る
        if unsafe { libc::tcgetattr(libc::STDIN_FILENO, &mut old) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        let mut raw = old;
        // 打った字を出さず、行の編集と Ctrl+C の signal を止めて 1 字ずつ受ける (編集と Ctrl+C は term がする)。
        // 入力の CR→LF などの変換 (c_iflag) と出力 (c_oflag) はそのまま
        raw.c_lflag &= !(libc::ECHO | libc::ICANON | libc::ISIG | libc::IEXTEN);
        raw.c_cc[libc::VMIN] = 1;
        raw.c_cc[libc::VTIME] = 0;
        // SAFETY: raw は tcgetattr が埋めた値を直したもの。TCSAFLUSH は問いの前に打たれた字を捨てる
        if unsafe { libc::tcsetattr(libc::STDIN_FILENO, libc::TCSAFLUSH, &raw) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(RawTerm { old })
    }

    /// 来た分のバイトを読む (0 は入力が尽きた)。
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        loop {
            // SAFETY: buf は書ける領域で、長さを渡す
            let n = unsafe { libc::read(libc::STDIN_FILENO, buf.as_mut_ptr().cast(), buf.len()) };
            if let Ok(n) = usize::try_from(n) {
                return Ok(n);
            }
            let e = std::io::Error::last_os_error();
            if e.kind() != std::io::ErrorKind::Interrupted {
                return Err(e);
            }
        }
    }
}

impl Drop for RawTerm {
    fn drop(&mut self) {
        // SAFETY: enter で受け取った元の設定をそのまま戻す
        unsafe {
            libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &self.old);
        }
    }
}

/// stdin の端末から、字を出さずに 1 行読む (編集は term の ByteEditor)。
pub(crate) fn read_hidden() -> std::io::Result<crate::term::Hidden> {
    use crate::term::{ByteEditor, Hidden, Step};
    let mut term = RawTerm::enter()?;
    let mut editor = ByteEditor::new();
    let mut buf = [0u8; 64];
    loop {
        let n = term.read(&mut buf)?;
        if n == 0 {
            return Ok(Hidden::Eof);
        }
        for &b in &buf[..n] {
            match editor.feed(b) {
                Step::More => {}
                Step::Done => return Ok(Hidden::Line(editor.take())),
                Step::Eof => return Ok(Hidden::Eof),
                Step::Interrupted => return Ok(Hidden::Interrupted),
            }
        }
    }
}

/// この process を `candidates` の順に execve で置き換える (Python の `os.execvpe` と同じ)。戻るのは全部が失敗したとき。
///
/// glibc の execvp (std の `CommandExt::exec` が使う) は、ELF でも `#!` でもないファイル (ENOEXEC) を `/bin/sh` で
/// 動かしてしまう。Python は Exec format error で止まるので、execve を自分で回す。見つからない (ENOENT・ENOTDIR) より
/// ほかの失敗 (権限・Exec format error) を返す。起こす前に、std と同じく signal の mask を空にし、SIGPIPE を既定に戻す。
pub(crate) fn execve_first(
    candidates: &[std::path::PathBuf],
    argv: &[std::ffi::OsString],
    envp: &[(std::ffi::OsString, std::ffi::OsString)],
) -> std::io::Error {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let invalid =
        || std::io::Error::new(std::io::ErrorKind::InvalidInput, "引数か env に NUL がある");
    let to_c = |b: &[u8]| CString::new(b).map_err(|_| invalid());
    let argv_c: Vec<CString> = match argv.iter().map(|a| to_c(a.as_bytes())).collect() {
        Ok(v) => v,
        Err(e) => return e,
    };
    let envp_c: Vec<CString> = match envp
        .iter()
        .map(|(k, v)| {
            let mut kv = k.as_bytes().to_vec();
            kv.push(b'=');
            kv.extend_from_slice(v.as_bytes());
            to_c(&kv)
        })
        .collect()
    {
        Ok(v) => v,
        Err(e) => return e,
    };
    let mut argv_p: Vec<*const libc::c_char> = argv_c.iter().map(|c| c.as_ptr()).collect();
    argv_p.push(std::ptr::null());
    let mut envp_p: Vec<*const libc::c_char> = envp_c.iter().map(|c| c.as_ptr()).collect();
    envp_p.push(std::ptr::null());
    // SAFETY: set は sigemptyset で埋めてから渡す。SIGPIPE を既定に戻すのは std の exec と同じ (Rust は起動時に無視にする)
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::pthread_sigmask(libc::SIG_SETMASK, &set, std::ptr::null_mut());
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let mut saved: Option<std::io::Error> = None;
    let mut last = std::io::Error::from(std::io::ErrorKind::NotFound);
    for path in candidates {
        let Ok(path_c) = to_c(path.as_os_str().as_bytes()) else {
            continue;
        };
        // SAFETY: どの配列も NUL で終わる CString の pointer の列で、末尾に null を置いてある。成功すれば戻らない
        unsafe {
            libc::execve(path_c.as_ptr(), argv_p.as_ptr(), envp_p.as_ptr());
        }
        let err = std::io::Error::last_os_error();
        let missing = matches!(err.raw_os_error(), Some(libc::ENOENT | libc::ENOTDIR));
        if !missing && saved.is_none() {
            saved = Some(std::io::Error::from_raw_os_error(
                err.raw_os_error().unwrap_or(0),
            ));
        }
        last = err;
    }
    saved.unwrap_or(last)
}

extern "C" fn swallow(_: libc::c_int) {}

/// `f` の間、SIGINT・SIGQUIT を受け流す (端末の Ctrl+C は同じ process group の子にも届き、子が決める)。
/// 無視 (SIG_IGN) は exec の先に継がれるので使わず、何もしない handler にする (exec で既定に戻る)。
pub(crate) fn interrupts_to_child<T>(f: impl FnOnce() -> T) -> T {
    let signals = [libc::SIGINT, libc::SIGQUIT];
    // SAFETY: sigaction は C の構造体で、0 で埋めた値は「handler なし・mask なし」として正しい
    let mut old: [libc::sigaction; 2] = unsafe { std::mem::zeroed() };
    // SAFETY: act は全部を埋めてから渡す。old は呼び出しの間生きている
    unsafe {
        let mut act: libc::sigaction = std::mem::zeroed();
        act.sa_sigaction = swallow as extern "C" fn(libc::c_int) as libc::sighandler_t;
        act.sa_flags = libc::SA_RESTART;
        libc::sigemptyset(&mut act.sa_mask);
        for (sig, slot) in signals.iter().zip(old.iter_mut()) {
            libc::sigaction(*sig, &act, slot);
        }
    }
    let result = f();
    // SAFETY: 前に受け取った値をそのまま戻す
    unsafe {
        for (sig, prev) in signals.iter().zip(old.iter()) {
            libc::sigaction(*sig, prev, std::ptr::null_mut());
        }
    }
    result
}
