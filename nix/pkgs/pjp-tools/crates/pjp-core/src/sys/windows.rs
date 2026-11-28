//! Windows の FFI。

#![expect(
    unsafe_code,
    reason = "Job Object・Ctrl+C の受け方・console の echo を止める mode・ファイルの DACL は Win32 の API でしか書けない"
)]

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::AsRawHandle;
use std::path::Path;
use std::process::{Child, Command, ExitStatus};

use windows_sys::Win32::Foundation::{
    CloseHandle, FALSE, HANDLE, HLOCAL, INVALID_HANDLE_VALUE, LocalFree, TRUE,
};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
    GetNamedSecurityInfoW, SDDL_REVISION_1, SE_FILE_OBJECT, SetNamedSecurityInfoW,
};
use windows_sys::Win32::Security::{
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, ACL_SIZE_INFORMATION, AclSizeInformation,
    DACL_SECURITY_INFORMATION, GetAce, GetAclInformation, GetSecurityDescriptorDacl,
    GetTokenInformation, LookupAccountSidW, OWNER_SECURITY_INFORMATION,
    PROTECTED_DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID, SID_NAME_USE, TOKEN_QUERY,
    TOKEN_USER, TokenUser,
};
use windows_sys::Win32::System::Console::{
    CONSOLE_MODE, CTRL_BREAK_EVENT, CTRL_C_EVENT, ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT,
    ENABLE_PROCESSED_INPUT, GetConsoleMode, GetStdHandle, ReadConsoleW, STD_INPUT_HANDLE,
    SetConsoleCtrlHandler, SetConsoleMode,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, TerminateJobObject,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows_sys::core::{BOOL, PWSTR};

use crate::fs::{ACCESS_ALLOWED_ACE_TYPE, ACCESS_ALLOWED_CALLBACK_ACE_TYPE, Access, Ace};

/// 時間切れで止める組 (子を入れた Job Object)。子が起こした孫も同じ job に入る。
pub(crate) struct Group {
    job: HANDLE,
}

/// Windows は起こした後に job へ入れるので、起こす前にすることは無い。
pub(crate) fn prepare_group(_cmd: &mut Command) {}

impl Group {
    /// 子を新しい job に入れる。作れない・入れられないときは None (時間切れでは子だけを止める)。
    /// 起こしてから入れるまでの間に子が孫を起こすと、その孫は job の外に残る。子が起動の直後に孫を起こさなければ先に
    /// 入るが、確かではない (止めた形 (CREATE_SUSPENDED) で起こして job に入れてから動かすには子の主 thread の handle が
    /// 要り、Rust 1.99 の std では unstable)。
    pub(crate) fn attach(child: &Child) -> Option<Group> {
        // SAFETY: 属性も名前も渡さない (null)。失敗は null で返る
        let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if job.is_null() {
            return None;
        }
        // SAFETY: job は今作った handle。子の handle は Child が生きている間は正しい
        let ok = unsafe { AssignProcessToJobObject(job, child.as_raw_handle()) };
        if ok == FALSE {
            // SAFETY: 今作った handle を一度だけ閉じる
            unsafe {
                CloseHandle(job);
            }
            return None;
        }
        Some(Group { job })
    }

    pub(crate) fn kill(&self) {
        // SAFETY: job は Drop まで開いている
        unsafe {
            TerminateJobObject(self.job, 1);
        }
    }
}

impl Drop for Group {
    fn drop(&mut self) {
        // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE は付けていないので、閉じても中の process は止まらない
        // (子が起こした常駐 (hc の core など) を、ふつうに終わったときに巻き込まない)
        // SAFETY: attach で開いた handle を一度だけ閉じる
        unsafe {
            CloseHandle(self.job);
        }
    }
}

pub(crate) fn signal_of(_status: &ExitStatus) -> Option<i32> {
    None
}

pub(crate) fn is_executable(path: &Path) -> bool {
    path.is_file()
}

/// Windows には Unix の権限が無い (何もせず false)。
pub(crate) fn set_mode(_path: &Path, _mode: u32) -> std::io::Result<bool> {
    Ok(false)
}

/// Windows には Unix の権限が無い。
pub(crate) fn mode_of(_meta: &std::fs::Metadata) -> Option<u32> {
    None
}

/// API が LocalAlloc で返したもの。Drop で LocalFree する。
struct Local(HLOCAL);

impl Drop for Local {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: API が LocalAlloc で返したものを一度だけ放す
            unsafe {
                LocalFree(self.0);
            }
        }
    }
}

/// 開いた handle。Drop で閉じる。
struct Owned(HANDLE);

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: 開いた handle を一度だけ閉じる
        unsafe {
            CloseHandle(self.0);
        }
    }
}

/// NUL で終わる UTF-16 (Win32 の API に渡す形)。
fn wide(s: &OsStr) -> Vec<u16> {
    s.encode_wide().chain(std::iter::once(0)).collect()
}

/// NUL で終わる UTF-16 を読む。
///
/// # Safety
///
/// `p` は NUL で終わる UTF-16 を指す。
unsafe fn from_wide(p: *const u16) -> String {
    let mut len = 0;
    // SAFETY: 呼び手が NUL で終わると約束している
    while unsafe { *p.add(len) } != 0 {
        len += 1;
    }
    // SAFETY: 上で数えた長さぶん読める
    String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(p, len) })
}

/// SID の文字列 (`S-1-5-18`)。
fn sid_string(sid: PSID) -> std::io::Result<String> {
    let mut p: PWSTR = std::ptr::null_mut();
    // SAFETY: sid は正しい SID を指す。p に LocalAlloc した NUL で終わる文字列が入る
    if unsafe { ConvertSidToStringSidW(sid, &mut p) } == FALSE {
        return Err(std::io::Error::last_os_error());
    }
    let _free = Local(p.cast());
    // SAFETY: ConvertSidToStringSidW が NUL で終わる文字列を返した
    Ok(unsafe { from_wide(p) })
}

/// SID の名前 (`BUILTIN\Users`・`NT AUTHORITY\SYSTEM`。domain の無い Everyone などは名前だけ)。引けなければ None。
fn sid_name(sid: PSID) -> Option<String> {
    let (mut name_len, mut domain_len): (u32, u32) = (0, 0);
    let mut kind: SID_NAME_USE = 0;
    // SAFETY: 1 回目は領域を渡さずに、要る長さ (NUL を含む字数) を聞く
    unsafe {
        LookupAccountSidW(
            std::ptr::null(),
            sid,
            std::ptr::null_mut(),
            &mut name_len,
            std::ptr::null_mut(),
            &mut domain_len,
            &mut kind,
        );
    }
    if name_len == 0 {
        return None;
    }
    let mut name = vec![0u16; name_len as usize];
    let mut domain = vec![0u16; domain_len.max(1) as usize];
    let mut domain_len = u32::try_from(domain.len()).ok()?;
    // SAFETY: name・domain はそれぞれ渡した長さぶん書ける。成功すると長さに NUL を除いた字数が入る
    let ok = unsafe {
        LookupAccountSidW(
            std::ptr::null(),
            sid,
            name.as_mut_ptr(),
            &mut name_len,
            domain.as_mut_ptr(),
            &mut domain_len,
            &mut kind,
        )
    };
    if ok == FALSE {
        return None;
    }
    let name = String::from_utf16_lossy(name.get(..name_len as usize)?);
    let domain = String::from_utf16_lossy(domain.get(..domain_len as usize)?);
    Some(if domain.is_empty() {
        name
    } else {
        format!("{domain}\\{name}")
    })
}

/// この process の user の SID の文字列 (`S-1-5-21-…`)。
fn current_user_sid() -> std::io::Result<String> {
    let mut token: HANDLE = std::ptr::null_mut();
    // SAFETY: GetCurrentProcess は閉じなくてよい疑似 handle を返す。token は書ける領域
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == FALSE {
        return Err(std::io::Error::last_os_error());
    }
    let token = Owned(token);
    let mut len: u32 = 0;
    // SAFETY: 1 回目は領域を渡さずに、要る大きさを聞く (失敗で返り、len に大きさが入る)
    unsafe {
        GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut len);
    }
    if len == 0 {
        return Err(std::io::Error::last_os_error());
    }
    // TOKEN_USER は pointer を持つので、8 バイトの並びの領域に受ける
    let mut buf = vec![0u64; (len as usize).div_ceil(8)];
    // SAFETY: buf は len バイト以上書ける
    if unsafe { GetTokenInformation(token.0, TokenUser, buf.as_mut_ptr().cast(), len, &mut len) }
        == FALSE
    {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: GetTokenInformation が buf の頭に TOKEN_USER を書いた。Sid は buf の中を指す (buf が生きている間だけ使う)
    let user = unsafe { &*buf.as_ptr().cast::<TOKEN_USER>() };
    sid_string(user.User.Sid)
}

/// 本人だけの DACL を付ける (`fs::set_owner_only`)。
pub(crate) fn set_owner_only(path: &Path, inherit: bool) -> std::io::Result<bool> {
    set_dacl(path, &owner_only_sddl(&current_user_sid()?, inherit))?;
    Ok(true)
}

/// 本人 (`me`) だけの DACL の SDDL。D:P は保護した DACL (親から継がない)、A は許可、OICI は中のファイルとディレクトリへ継ぐ、
/// FA は FILE_ALL_ACCESS。
fn owner_only_sddl(me: &str, inherit: bool) -> String {
    let flags = if inherit { "OICI" } else { "" };
    format!("D:P(A;{flags};FA;;;{me})")
}

/// SDDL を security descriptor にし、その DACL を返す (DACL は返した Local の中を指すので、Local を放すまで使う)。
fn parse_sddl(sddl: &str) -> std::io::Result<(Local, *mut ACL)> {
    let text = wide(OsStr::new(sddl));
    let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    // SAFETY: text は NUL で終わる。sd に LocalAlloc した security descriptor が入る (大きさは聞かない)
    let ok = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text.as_ptr(),
            SDDL_REVISION_1,
            &mut sd,
            std::ptr::null_mut(),
        )
    };
    if ok == FALSE {
        return Err(std::io::Error::last_os_error());
    }
    let sd = Local(sd);
    let (mut present, mut defaulted): (BOOL, BOOL) = (FALSE, FALSE);
    let mut dacl: *mut ACL = std::ptr::null_mut();
    // SAFETY: sd は今作った security descriptor。dacl は sd の中を指す
    if unsafe { GetSecurityDescriptorDacl(sd.0, &mut present, &mut dacl, &mut defaulted) } == FALSE
    {
        return Err(std::io::Error::last_os_error());
    }
    if present == FALSE || dacl.is_null() {
        return Err(std::io::Error::other(format!(
            "SDDL に DACL が無い: {sddl}"
        )));
    }
    Ok((sd, dacl))
}

/// SDDL で書いた DACL を、保護した DACL として付ける (所有者・group・SACL は変えない)。
fn set_dacl(path: &Path, sddl: &str) -> std::io::Result<()> {
    let (_sd, dacl) = parse_sddl(sddl)?;
    let name = wide(path.as_os_str());
    // SAFETY: name は NUL で終わる。dacl は _sd の中の ACL。DACL だけを替えて保護する (所有者・group・SACL は null で変えない)
    let rc = unsafe {
        SetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            dacl,
            std::ptr::null(),
        )
    };
    if rc != 0 {
        return Err(std::io::Error::from_raw_os_error(rc.cast_signed()));
    }
    Ok(())
}

/// ファイルの DACL の許可の相手 (`fs::access_of`)。
pub(crate) fn access_of(path: &Path) -> Option<std::io::Result<Access>> {
    Some(read_access(path))
}

fn read_access(path: &Path) -> std::io::Result<Access> {
    let me = current_user_sid()?;
    let name = wide(path.as_os_str());
    let mut owner: PSID = std::ptr::null_mut();
    let mut dacl: *mut ACL = std::ptr::null_mut();
    let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    // SAFETY: name は NUL で終わる。持ち主と DACL を聞く。sd に LocalAlloc した security descriptor が入り、owner・dacl はその中を
    // 指す
    let rc = unsafe {
        GetNamedSecurityInfoW(
            name.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
            &mut owner,
            std::ptr::null_mut(),
            &mut dacl,
            std::ptr::null_mut(),
            &mut sd,
        )
    };
    if rc != 0 {
        return Err(std::io::Error::from_raw_os_error(rc.cast_signed()));
    }
    let _sd = Local(sd);
    // OWNER RIGHTS の ACE を持ち主として見るため (読めなければ OWNER RIGHTS のまま)
    let owner = if owner.is_null() {
        None
    } else {
        sid_string(owner).ok().map(|sid| (sid, sid_name(owner)))
    };
    let owner = owner.as_ref().map(|(s, n)| (s.as_str(), n.as_deref()));
    if dacl.is_null() {
        return Ok(Access::from_aces(&me, owner, None));
    }
    // SAFETY: dacl は _sd の中の ACL (_sd はこの関数の終わりまで放さない)
    let aces = unsafe { allow_aces(dacl) }?;
    Ok(Access::from_aces(&me, owner, Some(aces)))
}

/// DACL の ACE のうち、SID を読める許可の ACE (ACCESS_ALLOWED_ACE と同じ並びのもの) を DACL の順に読む。ほかの種類 (拒否・
/// object の ACE) は読まない。
///
/// # Safety
///
/// `dacl` は正しい ACL を指し、読む間は放さない。
unsafe fn allow_aces(dacl: *const ACL) -> std::io::Result<Vec<Ace>> {
    let mut info = ACL_SIZE_INFORMATION::default();
    // SAFETY: 呼び手が dacl を正しい ACL と約束している。info は渡した大きさぶん書ける
    let ok = unsafe {
        GetAclInformation(
            dacl,
            (&raw mut info).cast(),
            size_of::<ACL_SIZE_INFORMATION>() as u32,
            AclSizeInformation,
        )
    };
    if ok == FALSE {
        return Err(std::io::Error::last_os_error());
    }
    let mut aces = Vec::new();
    for i in 0..info.AceCount {
        let mut ace: *mut core::ffi::c_void = std::ptr::null_mut();
        // SAFETY: i は ACE の数より小さい。ace は dacl の中の ACE を指す
        if unsafe { GetAce(dacl, i, &mut ace) } == FALSE {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: どの ACE も頭は ACE_HEADER
        let header = unsafe { *ace.cast::<ACE_HEADER>() };
        if !matches!(
            header.AceType,
            ACCESS_ALLOWED_ACE_TYPE | ACCESS_ALLOWED_CALLBACK_ACE_TYPE
        ) {
            continue;
        }
        // SAFETY: 許可の ACE は ACCESS_ALLOWED_ACE の並びで、SID は SidStart から続く (ACE の大きさの中)
        let allowed = unsafe { &*ace.cast::<ACCESS_ALLOWED_ACE>() };
        let sid: PSID = (&raw const allowed.SidStart).cast_mut().cast();
        aces.push(Ace {
            ace_type: header.AceType,
            flags: header.AceFlags,
            mask: allowed.Mask,
            sid: sid_string(sid)?,
            name: sid_name(sid),
        });
    }
    Ok(aces)
}

/// stdin の console を、echo・行の編集・Ctrl+C の処理を止めた形にしておく間の印。Drop で元に戻す。
struct RawTerm {
    handle: HANDLE,
    old: CONSOLE_MODE,
}

impl RawTerm {
    fn enter() -> std::io::Result<RawTerm> {
        // SAFETY: 値だけを渡す。失敗は INVALID_HANDLE_VALUE (console の無い process は null)
        let handle = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return Err(std::io::Error::last_os_error());
        }
        let mut old: CONSOLE_MODE = 0;
        // SAFETY: handle は stdin の handle (閉じない)。old は書ける領域
        if unsafe { GetConsoleMode(handle, &mut old) } == FALSE {
            return Err(std::io::Error::last_os_error());
        }
        // 打った字を出さず、行の編集と Ctrl+C の処理を止めて 1 字ずつ受ける (編集と Ctrl+C は term がする)
        let raw = old & !(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT);
        // SAFETY: 同じ handle に値を渡す
        if unsafe { SetConsoleMode(handle, raw) } == FALSE {
            return Err(std::io::Error::last_os_error());
        }
        Ok(RawTerm { handle, old })
    }

    /// 来た分の UTF-16 の単位を読む (0 は入力が尽きた)。
    fn read(&mut self, buf: &mut [u16]) -> std::io::Result<usize> {
        let len = u32::try_from(buf.len()).unwrap_or(u32::MAX);
        let mut n: u32 = 0;
        // SAFETY: buf は len 単位ぶん書ける領域。n は書ける領域。読み方の指定 (最後の引数) は渡さない
        let ok = unsafe {
            ReadConsoleW(
                self.handle,
                buf.as_mut_ptr().cast(),
                len,
                &mut n,
                std::ptr::null(),
            )
        };
        if ok == FALSE {
            return Err(std::io::Error::last_os_error());
        }
        Ok(usize::try_from(n).unwrap_or(0))
    }
}

impl Drop for RawTerm {
    fn drop(&mut self) {
        // SAFETY: enter で受け取った元の mode をそのまま戻す
        unsafe {
            SetConsoleMode(self.handle, self.old);
        }
    }
}

/// stdin の console から、字を出さずに 1 行読む (編集は term の WideEditor)。
pub(crate) fn read_hidden() -> std::io::Result<crate::term::Hidden> {
    use crate::term::{Hidden, Step, WideEditor};
    let mut term = RawTerm::enter()?;
    let mut editor = WideEditor::new();
    let mut buf = [0u16; 64];
    loop {
        let n = term.read(&mut buf)?;
        if n == 0 {
            return Ok(Hidden::Eof);
        }
        for &u in &buf[..n] {
            match editor.feed(u) {
                Step::More => {}
                Step::Done => return Ok(Hidden::Line(editor.take())),
                Step::Eof => return Ok(Hidden::Eof),
                Step::Interrupted => return Ok(Hidden::Interrupted),
            }
        }
    }
}

unsafe extern "system" fn swallow(ctrl_type: u32) -> BOOL {
    if ctrl_type == CTRL_C_EVENT || ctrl_type == CTRL_BREAK_EVENT {
        TRUE
    } else {
        FALSE
    }
}

/// `f` の間、Ctrl+C・Ctrl+Break を受け流す (console の全員に届くので、子が決める)。
/// NULL を渡す「無視」は子に継がれるので使わず、受けて何もしない handler を足す (handler は継がれない)。
pub(crate) fn interrupts_to_child<T>(f: impl FnOnce() -> T) -> T {
    // SAFETY: swallow は 'static な関数で、外すまで登録したままでよい
    unsafe {
        SetConsoleCtrlHandler(Some(swallow), TRUE);
    }
    let result = f();
    // SAFETY: 足したものを外す
    unsafe {
        SetConsoleCtrlHandler(Some(swallow), FALSE);
    }
    result
}

/// DACL のテスト。付けてから読み直すもの (set_owner_only・set_dacl の後に read_access) は実機の Windows で流す。Wine の
/// SetNamedSecurityInfoW は成功を返すが DACL を写さず (Unix の権限から作った DACL が読み直される)、Wine で通るのは SDDL から
/// 作った DACL を見るものと、無いファイルの誤りだけ。
#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    /// FILE_ALL_ACCESS。
    const FA: u32 = 0x001F_01FF;

    #[test]
    fn the_owner_only_sddl_is_one_full_control_ace_for_me() {
        let me = current_user_sid().unwrap();
        assert!(me.starts_with("S-1-"), "{me}");
        // 継がない (ファイル) は flag なし、継ぐ (ディレクトリ) は OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE
        for (inherit, flags) in [(false, 0u8), (true, 0x03)] {
            let (_sd, dacl) = parse_sddl(&owner_only_sddl(&me, inherit)).unwrap();
            // SAFETY: dacl は _sd の中の ACL
            let aces = unsafe { allow_aces(dacl) }.unwrap();
            assert_eq!(aces.len(), 1, "{aces:?}");
            assert_eq!(
                (
                    aces[0].ace_type,
                    aces[0].flags,
                    aces[0].mask,
                    aces[0].sid.as_str()
                ),
                (ACCESS_ALLOWED_ACE_TYPE, flags, FA, me.as_str())
            );
            assert!(Access::from_aces(&me, None, Some(aces)).owner_only());
        }
    }

    #[test]
    fn owner_rights_creator_owner_and_write_only_aces_in_a_real_dacl() {
        let me = current_user_sid().unwrap();
        // OWNER RIGHTS (OW) の読み・CREATOR OWNER (CO) のフルコントロール・BUILTIN\Users (BU) の書くだけ
        let (_sd, dacl) = parse_sddl(&format!(
            "D:(A;;FA;;;{me})(A;;FR;;;OW)(A;;FA;;;CO)(A;;FW;;;BU)"
        ))
        .unwrap();
        // SAFETY: dacl は _sd の中の ACL
        let aces = unsafe { allow_aces(dacl) }.unwrap();
        assert_eq!(aces.len(), 4, "{aces:?}");
        // 持ち主が本人なら、本人だけと同じ
        let a = Access::from_aces(&me, Some((me.as_str(), None)), Some(aces));
        assert!(a.owner_only(), "{a:?}");
        assert!(!a.wide());
    }

    #[test]
    fn well_known_sids_have_names() {
        let me = current_user_sid().unwrap();
        let (_sd, dacl) = parse_sddl(&format!(
            "D:(A;;FA;;;{me})(A;;FR;;;WD)(A;;FA;;;SY)(A;;FA;;;BA)"
        ))
        .unwrap();
        // SAFETY: dacl は _sd の中の ACL
        let a = Access::from_aces(&me, None, Some(unsafe { allow_aces(dacl) }.unwrap()));
        let got: Vec<(&str, crate::fs::Who, bool)> = a
            .allowed
            .iter()
            .flatten()
            .map(|t| (t.sid.as_str(), t.who, t.name.is_some()))
            .collect();
        assert_eq!(
            got,
            vec![
                (me.as_str(), crate::fs::Who::Me, true),
                ("S-1-1-0", crate::fs::Who::Other, true),
                ("S-1-5-18", crate::fs::Who::System, true),
                ("S-1-5-32-544", crate::fs::Who::Administrators, true),
            ]
        );
        assert!(a.wide());
    }

    #[test]
    fn owner_only_drops_the_inherited_aces() {
        let t = TempDir::new("acl-file");
        let p = t.write("f", "x");
        assert!(set_owner_only(&p, false).unwrap());
        let a = read_access(&p).unwrap();
        assert!(a.owner_only(), "{a:?}");
        let me = current_user_sid().unwrap();
        assert!(me.starts_with("S-1-"), "{me}");
        assert_eq!(a.allowed.as_deref().unwrap()[0].sid, me);
        // 本人のまま読み書き・消しができる
        std::fs::write(&p, "y").unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "y");
    }

    #[test]
    fn an_owner_only_directory_passes_it_on_to_new_files() {
        let t = TempDir::new("acl-dir");
        let d = t.path().join("d");
        std::fs::create_dir(&d).unwrap();
        assert!(set_owner_only(&d, true).unwrap());
        assert!(read_access(&d).unwrap().owner_only());
        let f = d.join("f");
        std::fs::write(&f, "x").unwrap();
        let a = read_access(&f).unwrap();
        assert!(a.owner_only(), "{a:?}");
    }

    #[test]
    fn everyone_and_users_are_others_with_names() {
        let t = TempDir::new("acl-wide");
        let p = t.write("f", "x");
        let me = current_user_sid().unwrap();
        // 本人のフルコントロール・Everyone (WD) と BUILTIN\Users (BU) の読み・SYSTEM (SY) のフルコントロール
        set_dacl(
            &p,
            &format!("D:P(A;;FA;;;{me})(A;;FR;;;WD)(A;;FR;;;BU)(A;;FA;;;SY)"),
        )
        .unwrap();
        let a = read_access(&p).unwrap();
        assert!(a.wide(), "{a:?}");
        let others: Vec<&str> = a.others().iter().map(|t| t.sid.as_str()).collect();
        assert_eq!(others, vec!["S-1-1-0", "S-1-5-32-545"]);
        // 名前は OS の言葉で引く (言語で字が変わりうるので、引けたことだけを見る)
        assert!(a.others().iter().all(|t| t.name.is_some()), "{a:?}");
        // 本人だけに戻せる
        assert!(set_owner_only(&p, false).unwrap());
        assert!(read_access(&p).unwrap().owner_only());
    }

    #[test]
    fn owner_rights_on_a_real_file_is_the_owner() {
        let t = TempDir::new("acl-owner-rights");
        let p = t.write("f", "x");
        let me = current_user_sid().unwrap();
        // OWNER RIGHTS (OW) の読みは、ファイルの持ち主として見る。持ち主はふつう作った本人 (本人の ACE と重なって本人だけになる) だが、
        // 管理者のアカウント (GitHub の windows-latest など) では、作ったファイルの既定の持ち主が BUILTIN\Administrators になるので、
        // OW は Administrators として見える
        set_dacl(&p, &format!("D:P(A;;FA;;;{me})(A;;FR;;;OW)")).unwrap();
        let a = read_access(&p).unwrap();
        let sids: Vec<&str> = a.allowed.iter().flatten().map(|t| t.sid.as_str()).collect();
        if sids == [me.as_str()] {
            assert!(a.owner_only(), "{a:?}");
        } else {
            assert_eq!(sids, [me.as_str(), "S-1-5-32-544"], "{a:?}");
            assert!(!a.owner_only(), "{a:?}");
        }
    }

    #[test]
    fn a_missing_file_is_an_error() {
        let t = TempDir::new("acl-missing");
        assert!(read_access(&t.path().join("nope")).is_err());
    }
}
