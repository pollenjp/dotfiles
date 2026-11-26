//! 記録つきのコピーの判定 (files・ssh-config・port-forward で共通)。WSL の `bootstrap-windows-files.sh`・`bootstrap-windows-ssh-config.sh`・
//! `bootstrap-windows-port-forward.sh` が同じ形で持つ判定を写したもの (dotfiles-private の docs/adr/060_win_runner_core_* の §2 A「files の判定を、
//! 書く中身を渡せる形に広げる」)。
//!
//! 置き先の中身と「前回ここへ置いた中身の sha256」の記録を比べて決める (`judge`):
//!
//! | 置き先 | `Action` | すること |
//! | --- | --- | --- |
//! | 無い | `Copy` | 書く |
//! | 書く中身と同じ | `Same` | 何もしない (記録が無ければ記録だけする) |
//! | 記録と同じ中身 (書く中身とは違う) | `Update` | 正本 (repo) が更新された。上書きする |
//! | 記録が無くても置き換えてよい古い中身 (ssh-config の旧経路の `config`) | `Replace` | 置き換える |
//! | それ以外 | `Force` (`--force`) / `Conflict` | 衝突。触らない (`--force` なら上書き。手順によっては元を退避してから) |
//!
//! 記録にあって書くものから消えた鍵 (ssh-config) は `judge_gone` で決める: 置き先が無い → 記録から外すだけ・記録と同じ中身 → 消す・違う →
//! 衝突 (`--force` なら退避して消す)。
//!
//! 書く中身・記録の鍵・出力の文は手順が持ち、ここは判定・書き込み (退避・消す)・衝突の diff・受け持ちで替える `--force` の案内・締めの行の数を持つ。

use super::ps1::ps_quote;
use super::{Mode, Outcome};
use crate::context::Ctx;
use crate::fsutil;
use crate::process::CommandSpec;
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

static DIFF_COUNTER: AtomicU64 = AtomicU64::new(0);

/// 1 件の判定。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Copy,
    Same,
    Update,
    Replace,
    Force,
    Conflict,
}

/// 置き先を判定できなかったわけ。
#[derive(Debug)]
pub enum Problem {
    /// 置き先がディレクトリ
    Directory,
    /// 置き先が読めない
    Unreadable(std::io::Error),
}

/// 置き先 `dst` に、sha256 が `want` の中身を置くときの判定。`recorded` は前回ここへ置いた中身の sha256、`replaceable` は記録が無くても
/// 置き換えてよい古い中身か (WSL と同じ順に見る: 同じ → 記録どおり → 置き換えてよい → `--force` → 衝突)。
pub fn judge(
    dst: &Path,
    want: &str,
    recorded: Option<&str>,
    force: bool,
    replaceable: &dyn Fn(&[u8]) -> bool,
) -> Result<Action, Problem> {
    if dst.is_dir() {
        return Err(Problem::Directory);
    }
    let bytes = match std::fs::read(dst) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Action::Copy),
        Err(e) => return Err(Problem::Unreadable(e)),
    };
    let have = fsutil::sha256_bytes(&bytes);
    Ok(if have == want {
        Action::Same
    } else if recorded == Some(have.as_str()) {
        Action::Update
    } else if replaceable(&bytes) {
        Action::Replace
    } else if force {
        Action::Force
    } else {
        Action::Conflict
    })
}

/// 置き換えてよい古い中身が無い手順の `replaceable`。
pub fn never(_: &[u8]) -> bool {
    false
}

/// 記録にあって書くものから消えた鍵の判定。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gone {
    /// 置き先がもう無い (記録から外すだけ)
    Missing,
    /// 記録と同じ中身なので消す
    Remove,
    /// 記録と違うが `--force` なので、退避して消す
    Force,
    /// 記録と違う (Windows 側で変わった) ので消さない
    Conflict,
}

/// 書くものから消えた鍵の置き先 `dst` の判定 (`recorded` は記録の sha256。文字列でない記録は None で、中身とは合わない)。
pub fn judge_gone(dst: &Path, recorded: Option<&str>, force: bool) -> Result<Gone, Problem> {
    if dst.is_dir() {
        return Err(Problem::Directory);
    }
    let have = match std::fs::read(dst) {
        Ok(b) => fsutil::sha256_bytes(&b),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Gone::Missing),
        Err(e) => return Err(Problem::Unreadable(e)),
    };
    Ok(if recorded == Some(have.as_str()) {
        Gone::Remove
    } else if force {
        Gone::Force
    } else {
        Gone::Conflict
    })
}

/// 置き先に書く (置き先と同じディレクトリの一時ファイルから rename。親が無ければ作る)。`backup` なら、先に元を `<名前>.dotfiles-bak-<日時>` に
/// 写す (写した先を返す)。
pub fn write(dst: &Path, bytes: &[u8], backup: bool) -> std::io::Result<Option<PathBuf>> {
    let bak = if backup {
        Some(backup_copy(dst)?)
    } else {
        None
    };
    fsutil::write_atomic(dst, bytes)?;
    Ok(bak)
}

/// 置き先を消す。`backup` なら、先に元を `<名前>.dotfiles-bak-<日時>` に写す (写した先を返す)。
pub fn remove(dst: &Path, backup: bool) -> std::io::Result<Option<PathBuf>> {
    let bak = if backup {
        Some(backup_copy(dst)?)
    } else {
        None
    };
    std::fs::remove_file(dst)?;
    Ok(bak)
}

/// 元を同じディレクトリの `<名前>.dotfiles-bak-<日時>` に写す (WSL の backup と同じ名前の形。`*.ssh_config` で終わらないので ssh は読まない)。
/// 日時は UTC の `YYYYMMDD-hhmmssZ` (runner は Windows の時刻帯を読まない。WSL はその時刻帯の時刻で、Z を付けない)。同じ名前があれば `-<n>` を
/// 足す (WSL の `cp -p` は同じ秒の退避を上書きする)。
pub fn backup_copy(dst: &Path) -> std::io::Result<PathBuf> {
    let name = dst
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let dir = dst.parent().unwrap_or(Path::new("."));
    let stamp = utc_stamp(SystemTime::now());
    let mut bak = dir.join(format!("{name}.dotfiles-bak-{stamp}"));
    let mut n = 0;
    while bak.exists() {
        n += 1;
        bak = dir.join(format!("{name}.dotfiles-bak-{stamp}-{n}"));
    }
    std::fs::copy(dst, &bak)?;
    Ok(bak)
}

/// UTC の `YYYYMMDD-hhmmssZ`。
fn utc_stamp(t: SystemTime) -> String {
    let [year, month, day, h, m, s] = fsutil::utc_fields(t);
    format!("{year:04}{month:02}{day:02}-{h:02}{m:02}{s:02}Z")
}

/// bash の一重引用符で囲む (`'` は `'\''` にする。jq の `@sh` と同じ形。WSL の script に渡す名前の案内)
pub fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// 衝突を上書きする (消した 1 行を足し直す) コマンド。受け持ちが WSL の間は、runner の apply はこの手順を流さないので、WSL の script の
/// `--force` を出す。
pub fn force_command(ctx: &Ctx, id: &str) -> String {
    if ctx.host.runner_enable {
        format!("dotfiles apply --steps {id} --force")
    } else {
        format!(
            "WSL で nix/scripts/bootstrap-windows-{id}.sh --force (受け持ちが WSL の setup の間。runner の apply は {id} を流さない)"
        )
    }
}

/// clone (`name` は出力に出す呼び名。`dotfiles`・`dotfiles-private`) の core.autocrlf が true なら、そう出して `manual` の行を返す (bootstrap の
/// clone は false)。git が無い・clone が git の作業ツリーでない (試すときの一時ディレクトリ)・読めないときは何もしない。
pub fn autocrlf_outcome(ctx: &mut Ctx, clone: &Path, name: &str) -> Option<Outcome> {
    let git = ctx.sys.which("git")?;
    let git_in_repo = |args: &[&str]| {
        let mut spec = CommandSpec::new(&git)
            .arg("-C")
            .arg(clone.as_os_str())
            .timeout(Duration::from_secs(10));
        for a in args {
            spec = spec.arg(*a);
        }
        ctx.sys.run(&spec, &mut |_| {})
    };
    // 作業ツリーの外では、system・global の値を読んでしまう (Git for Windows の system は true)
    if git_in_repo(&["rev-parse", "--is-inside-work-tree"]).code() != Some(0) {
        return None;
    }
    let r = git_in_repo(&["config", "--get", "core.autocrlf"]);
    let value = r.output.first().map(|l| l.trim().to_ascii_lowercase());
    if r.code() != Some(0) || value.as_deref() != Some("true") {
        return None;
    }
    let quoted = ps_quote(&clone.to_string_lossy());
    ctx.say(format!(
        "!! {name} の clone の core.autocrlf が true です ({})。テキストのファイルが CRLF で取り出され、WSL が配った LF と中身が合わずに衝突になります。",
        clone.display()
    ));
    Some(
        Outcome::new(
            Kind::Manual,
            format!(
                "{name} の clone の core.autocrlf が true (テキストが CRLF で取り出され、WSL が配った LF と合わずに衝突になる)"
            ),
        )
        .note("bootstrap の clone は core.autocrlf=false (git clone -c core.autocrlf=false)。core.autocrlf=false で clone し直すのが確か")
        .note(format!(
            "この clone を直すなら、変更が無いことを確かめてから: git -C '{quoted}' config core.autocrlf false → git -C '{quoted}' rm --cached -r -q . → git -C '{quoted}' reset --hard"
        )),
    )
}

/// 衝突の行に添える ※ (受け持ちで替える)。`keep` は Windows 側の中身を残す道 (「Windows 側の中身を repo へ取り込む」)、`clone` は WSL が配った
/// 中身と比べた clone の呼び名 (「この clone」)。
pub fn conflict_note(ctx: &Ctx, id: &str, keep: &str, clone: &str) -> String {
    if ctx.host.runner_enable {
        format!("衝突は上の出力の解き方で直す ({keep}か、dotfiles apply --steps {id} --force)")
    } else {
        format!(
            "受け持ちは WSL の setup (runner.enable が true でない)。WSL が配った中身と{clone}の中身が違うなら、clone を同じ commit にそろえて見直す。衝突を解くのは WSL の側 (bootstrap-windows-{id}.sh)"
        )
    }
}

/// 衝突の diff を `git diff --no-index` で出す (左は Windows 側、右は書く中身。git が無ければ、そう出して進む)。
pub fn show_diff(ctx: &mut Ctx, windows: &Path, ours: &Path) {
    let Some(git) = ctx.sys.which("git") else {
        ctx.say("   (git が無いので diff は出さない)");
        return;
    };
    let spec = CommandSpec::new(git)
        .arg("diff")
        .arg("--no-index")
        .arg("--no-color")
        .arg("--")
        .arg(windows.as_os_str())
        .arg(ours.as_os_str())
        .timeout(Duration::from_secs(30));
    let sys = ctx.sys;
    let mut lines = Vec::new();
    sys.run(&spec, &mut |l| lines.push(format!("   {l}")));
    for l in lines {
        ctx.say(l);
    }
}

/// 書く中身がファイルに無いとき (組み立てた中身) の diff。一時ディレクトリに `name` で書いてから `show_diff` し、消す。
pub fn show_diff_bytes(ctx: &mut Ctx, windows: &Path, ours: &[u8], name: &str) {
    let written = fresh_temp_dir().and_then(|dir| {
        let file = dir.join(name);
        match std::fs::write(&file, ours) {
            Ok(()) => Ok((dir, file)),
            Err(e) => {
                let _ = std::fs::remove_dir_all(&dir);
                Err(e)
            }
        }
    });
    match written {
        Ok((dir, file)) => {
            show_diff(ctx, windows, &file);
            let _ = std::fs::remove_dir_all(&dir);
        }
        Err(e) => ctx.say(format!(
            "   (書く中身を一時ファイルに書けないので diff は出さない: {e})"
        )),
    }
}

/// 一時の場所に新しいディレクトリを作る (`create_dir` なので、既にある名前 (先に置かれた symlink も) は使わずに名前を替える)。
pub(crate) fn fresh_temp_dir() -> std::io::Result<PathBuf> {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let mut last = None;
    for _ in 0..16 {
        let dir = std::env::temp_dir().join(format!(
            "dotfiles-win-diff-{}-{}-{nanos}",
            std::process::id(),
            DIFF_COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        match std::fs::create_dir(&dir) {
            Ok(()) => return Ok(dir),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => last = Some(e),
            Err(e) => return Err(e),
        }
    }
    Err(last.unwrap_or_else(|| std::io::Error::other("一時ディレクトリを作れない")))
}

/// 締めの行の数 (コピー・上書き・同じ・削除・衝突・エラー)。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Tally {
    pub copied: usize,
    pub updated: usize,
    pub unchanged: usize,
    pub removed: usize,
    pub conflicts: usize,
    pub errors: usize,
}

impl Tally {
    /// 判定した 1 件を数える (書く・書く予定の件。衝突は数えない)。`Copy` はコピー、`Update`・`Replace`・`Force` は上書き、`Same` は同じ。
    pub fn count(&mut self, action: Action) {
        match action {
            Action::Copy => self.copied += 1,
            Action::Update | Action::Replace | Action::Force => self.updated += 1,
            Action::Same => self.unchanged += 1,
            Action::Conflict => self.conflicts += 1,
        }
    }

    /// 締めの行の文 (「コピー n / 上書き n / 同じ n / 衝突 n」。`with_removed` なら「同じ」の後ろに「削除 n」、エラーがあれば末尾に「エラー n」。
    /// dry-run なら頭に `[dry-run] `)。
    pub fn summary(&self, mode: Mode, with_removed: bool) -> String {
        let mut s = format!(
            "コピー {} / 上書き {} / 同じ {}",
            self.copied, self.updated, self.unchanged
        );
        if with_removed {
            s.push_str(&format!(" / 削除 {}", self.removed));
        }
        s.push_str(&format!(" / 衝突 {}", self.conflicts));
        if self.errors > 0 {
            s.push_str(&format!(" / エラー {}", self.errors));
        }
        if matches!(mode, Mode::DryRun { .. }) {
            s = format!("[dry-run] {s}");
        }
        s
    }

    /// 締めの表の行の種類: エラー → failed・衝突 → manual・apply なら ok・上書きか削除の予定 → fix・コピーの予定 → missing・ほかは ok。
    pub fn kind(&self, mode: Mode) -> Kind {
        if self.errors > 0 {
            Kind::Failed
        } else if self.conflicts > 0 {
            Kind::Manual
        } else if mode.writes() {
            Kind::Ok
        } else if self.updated > 0 || self.removed > 0 {
            Kind::Fix
        } else if self.copied > 0 {
            Kind::Missing
        } else {
            Kind::Ok
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 判定の順 (無い → 同じ → 記録どおり → 置き換えてよい → --force → 衝突)・ディレクトリと読めない置き先
    //! - 消えた鍵の判定 (無い・記録どおり・--force・衝突)
    //! - 書く・消すときの退避 (`<名前>.dotfiles-bak-<日時>`。同じ名前なら -n を足す)・UTC の日時
    //! - `--force` の案内を受け持ちで替える・締めの行の文と種類

    use super::*;
    use crate::host::{Groups, HostValues, parse};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};

    fn sha(b: &[u8]) -> String {
        fsutil::sha256_bytes(b)
    }

    #[test]
    fn judges_in_the_wsl_order() {
        let t = TempDir::new("deploy");
        let dst = t.path().join("a").join("config");
        let want = sha(b"new\n");
        let old = sha(b"old\n");
        let j = |rec: Option<&str>, force: bool, replace: bool| {
            judge(&dst, &want, rec, force, &|_| replace).unwrap()
        };
        assert_eq!(j(None, false, false), Action::Copy);
        t.write("a/config", "new\n");
        assert_eq!(j(None, false, false), Action::Same);
        assert_eq!(j(Some(&old), true, true), Action::Same);
        t.write("a/config", "old\n");
        assert_eq!(j(Some(&old), false, false), Action::Update);
        // 記録どおりなら、置き換えてよい中身でも上書き (正本が更新された) と読む
        assert_eq!(j(Some(&old), true, true), Action::Update);
        assert_eq!(j(None, true, true), Action::Replace);
        assert_eq!(j(None, true, false), Action::Force);
        assert_eq!(j(Some("x"), false, false), Action::Conflict);
        // 置き換えてよいかは、置き先の中身を見て決める
        let seen = std::cell::RefCell::new(Vec::new());
        judge(&dst, &want, None, false, &|b| {
            seen.borrow_mut().push(b.to_vec());
            false
        })
        .unwrap();
        assert_eq!(seen.into_inner(), vec![b"old\n".to_vec()]);

        std::fs::remove_file(&dst).unwrap();
        std::fs::create_dir_all(&dst).unwrap();
        assert!(matches!(
            judge(&dst, &want, None, true, &never),
            Err(Problem::Directory)
        ));
        assert!(matches!(
            judge_gone(&dst, None, true),
            Err(Problem::Directory)
        ));
    }

    #[test]
    fn judges_gone_keys() {
        let t = TempDir::new("deploy");
        let dst = t.path().join("config.d").join("x.ssh_config");
        assert_eq!(judge_gone(&dst, Some("x"), false).unwrap(), Gone::Missing);
        t.write("config.d/x.ssh_config", "x\n");
        let rec = sha(b"x\n");
        assert_eq!(judge_gone(&dst, Some(&rec), false).unwrap(), Gone::Remove);
        assert_eq!(judge_gone(&dst, Some("y"), false).unwrap(), Gone::Conflict);
        assert_eq!(judge_gone(&dst, None, false).unwrap(), Gone::Conflict);
        assert_eq!(judge_gone(&dst, Some("y"), true).unwrap(), Gone::Force);
    }

    #[test]
    fn writes_and_removes_with_backups() {
        let t = TempDir::new("deploy");
        let dst = t.path().join("d").join("hosts.json");
        assert_eq!(write(&dst, b"one\n", false).unwrap(), None);
        assert_eq!(std::fs::read(&dst).unwrap(), b"one\n");
        let bak = write(&dst, b"two\n", true).unwrap().unwrap();
        assert_eq!(std::fs::read(&dst).unwrap(), b"two\n");
        assert_eq!(std::fs::read(&bak).unwrap(), b"one\n");
        let name = bak.file_name().unwrap().to_string_lossy().into_owned();
        assert!(name.starts_with("hosts.json.dotfiles-bak-"), "{name}");
        assert!(name.ends_with('Z'), "{name}");
        // 同じ秒の退避は上書きせず -n を足す
        let bak2 = remove(&dst, true).unwrap().unwrap();
        assert_ne!(bak, bak2);
        assert_eq!(std::fs::read(&bak2).unwrap(), b"two\n");
        assert_eq!(std::fs::read(&bak).unwrap(), b"one\n");
        assert!(!dst.exists());
        t.write("d/hosts.json", "three\n");
        assert_eq!(remove(&dst, false).unwrap(), None);
        assert!(!dst.exists());
        // 一時ファイルを残さない
        let mut names: Vec<String> = std::fs::read_dir(dst.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names.len(), 2, "{names:?}");
        assert!(
            names.iter().all(|n| n.contains(".dotfiles-bak-")),
            "{names:?}"
        );
    }

    #[test]
    fn utc_stamps() {
        let at = |secs: u64| utc_stamp(SystemTime::UNIX_EPOCH + Duration::from_secs(secs));
        assert_eq!(at(0), "19700101-000000Z");
        // 2026-11-20 08:35:28 JST = 2026-11-19 23:35:28 UTC
        assert_eq!(at(1_795_131_328), "20261119-233528Z");
        // うるう年の 2 月 29 日
        assert_eq!(at(1_709_164_800), "20240229-000000Z");
        assert_eq!(at(951_782_400), "20000229-000000Z");
    }

    fn ctx_for<'a>(host: &str, sys: &'a FakeSys, out: &'a mut Vec<u8>) -> Ctx<'a> {
        let groups = Groups::embedded().unwrap();
        Ctx {
            repo: "/r".into(),
            roots: Roots::from_home(Path::new("/h")),
            state_dir: "/s".into(),
            host: if host.is_empty() {
                HostValues::missing(Path::new("h.toml"), groups)
            } else {
                parse(host, Path::new("h.toml"), groups).unwrap()
            },
            sys,
            out,
        }
    }

    /// 受け持ちが runner なら runner の apply、WSL なら WSL の script の --force (runner の apply はその手順を流さない)
    #[test]
    fn force_command_follows_the_owner() {
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let ctx = ctx_for("[runner]\nenable = true\n", &sys, &mut out);
        assert_eq!(
            force_command(&ctx, "ssh-config"),
            "dotfiles apply --steps ssh-config --force"
        );
        let mut out = Vec::new();
        let ctx = ctx_for("group = \"minimum\"\n", &sys, &mut out);
        assert_eq!(
            force_command(&ctx, "files"),
            "WSL で nix/scripts/bootstrap-windows-files.sh --force (受け持ちが WSL の setup の間。runner の apply は files を流さない)"
        );
    }

    /// 組み立てた中身の diff は、一時ファイルに書いて git diff --no-index に渡し、後で消す
    #[test]
    fn diff_of_built_content_uses_a_temporary_file() {
        let t = TempDir::new("deploy");
        let windows = t.write("w/hosts.json", "w\n");
        let seen = std::rc::Rc::new(std::cell::RefCell::new(None::<(PathBuf, Vec<u8>)>));
        let s = seen.clone();
        let sys = FakeSys::new(move |c| {
            let right = PathBuf::from(c.args.last().unwrap());
            *s.borrow_mut() = Some((right.clone(), std::fs::read(&right).unwrap()));
            crate::process::RunResult {
                exit: crate::process::Exit::Code(1),
                output: vec!["-w".to_string(), "+ours".to_string()],
            }
        })
        .with_program("git", "/usr/bin/git");
        let mut out = Vec::new();
        {
            let mut ctx = ctx_for("", &sys, &mut out);
            show_diff_bytes(&mut ctx, &windows, b"ours\n", "hosts.json");
        }
        let (right, bytes) = seen.borrow().clone().unwrap();
        assert_eq!(bytes, b"ours\n");
        assert_eq!(right.file_name().unwrap(), "hosts.json");
        assert!(!right.exists(), "一時ファイルを消す");
        assert_eq!(
            sys.call_args()[0],
            format!(
                "diff --no-index --no-color -- {} {}",
                windows.display(),
                right.display()
            )
        );
        assert_eq!(String::from_utf8(out).unwrap(), "   -w\n   +ours\n");
    }

    #[test]
    fn tally_summary_and_kind() {
        let apply = Mode::Apply { force: false };
        let mut t = Tally::default();
        assert_eq!(
            t.summary(Mode::Check, false),
            "コピー 0 / 上書き 0 / 同じ 0 / 衝突 0"
        );
        assert_eq!(t.kind(Mode::Check), Kind::Ok);
        t.count(Action::Same);
        t.count(Action::Copy);
        assert_eq!(t.kind(Mode::Check), Kind::Missing);
        assert_eq!(t.kind(apply), Kind::Ok);
        t.count(Action::Replace);
        assert_eq!(t.kind(Mode::Check), Kind::Fix);
        t.removed += 1;
        assert_eq!(
            t.summary(Mode::DryRun { force: false }, true),
            "[dry-run] コピー 1 / 上書き 1 / 同じ 1 / 削除 1 / 衝突 0"
        );
        let gone_only = Tally {
            removed: 1,
            ..Default::default()
        };
        assert_eq!(gone_only.kind(Mode::Check), Kind::Fix);
        t.count(Action::Conflict);
        assert_eq!(t.kind(apply), Kind::Manual);
        t.errors = 2;
        assert_eq!(t.kind(apply), Kind::Failed);
        assert_eq!(
            t.summary(Mode::Check, false),
            "コピー 1 / 上書き 1 / 同じ 1 / 衝突 1 / エラー 2"
        );
    }
}
