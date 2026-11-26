//! starship-init (order 94): PowerShell 7 の `$PROFILE` に、starship のプロンプトを起こす 1 行 (`LINE`) を足す (Windows にしか無い手順。WSL の
//! setup には無い)。starship 本体は ps1 の手順 `starship` (`win/starship/Install-Starship.ps1`) が入れる (dotfiles-private の
//! docs/superpowers/specs/2026-11-25-win-starship-install-design.md)。
//!
//! starship の init は、先に置かれた PSReadLine の ViModeChangeHandler を包む (starship 1.27 の `src/init/starship.ps1`)。`dotfiles.ps1` は init の
//! 後に読まれる前提で、その handler を包まずに置き換える (win/README.md の「Vi モード」。後ろで init すると handler を包み、モードが替わるたびに
//! プロンプトを 2 回描き直す)。そこで 1 行は、`dotfiles.ps1` を読む行 (powershell-profile の手順が足す。`MARKER` を含む行) より前に置く:
//!
//! | `$PROFILE` | すること | 行の種類 (apply の前) |
//! | --- | --- | --- |
//! | starship の init の行がある (`starship` と `init powershell` を含む行。大文字小文字を問わず、頭に `#` を付けた行も) | 何もしない (記録が無ければ記録だけする) | ok |
//! | その行が `dotfiles.ps1` を読む行より後ろにある (どちらも頭に `#` の無い行のとき) | 動かさずに、前へ移すよう知らせる (記録が無ければ記録だけする) | manual |
//! | 行が無く、足した記録も無い | `dotfiles.ps1` を読む行があればそのすぐ前に差し込み、無ければ末尾に足して記録する (`$PROFILE` が無ければ親ごと作る) | missing |
//! | 行が無いが、足した記録がある | Windows 側で外したものとして足し直さない (`--force` なら足す) | manual |
//! | 差し込む所の前の行が行末の ` (次の行へ続く) で終わる | 書かない (差し込むと文が切れ、起動のたびにエラーになる) | manual |
//! | UTF-16 | 書かない (ASCII を足すと壊れる。init の行があるかは字に直して読む) | manual |
//!
//! - 1 行は `Get-Command starship -CommandType Application` で囲む。starship の無い PC (入れる前・OneDrive の同期で `$PROFILE` だけが届いた PC) でも、
//!   起動のたびにエラーを出さない (powershell-profile の `Test-Path` と同じ考え)。`-CommandType Application` は PATH の exe だけを引き、モジュールを
//!   探さない (起動を遅くしない)
//! - 新しい PC (`$PROFILE` が無い・どちらの行も無い) では、この手順が先に流れて末尾に足し、続く powershell-profile (95) が `dotfiles.ps1` を読む行を
//!   その後ろに足す。差し込むのは、`dotfiles.ps1` を読む行が先にある PC だけ
//! - 改行はファイルに合わせる (CR があれば CRLF)。頭の UTF-8 の BOM は頭に残す。末尾に足すときは、末尾に改行が無ければ先に補い、ファイルの末尾への
//!   追記で書く (powershell-profile と同じ)。差し込むときは、書き直す前の中身を `%LOCALAPPDATA%\dotfiles\state\starship-init\backup\<UTC の時刻>-<pid>\`
//!   へ写してから (10 回分)、同じファイルに上書きする (OneDrive が同期するファイルを rename で置き換えない)
//! - 記録は `%LOCALAPPDATA%\dotfiles\state\starship-init.added.json` (`$PROFILE` の Windows のパス → `"added"`)。手で書いた init の行を見つけたときも
//!   記録する (人が書いた行も、外したら足し直さない)
//! - pwsh に `$PROFILE` の場所を聞く式・拾い方・書かない場所 (読めない文字・ディレクトリ) は powershell-profile と同じ (`powershell_profile::locate`)。
//!   自動で足せないときは、`dotfiles.ps1` を読む行より前に同じ 1 行を手で足す道を添える
//! - Windows にしか無い手順なので、受け持ちによらず runner が流す (受け持ちが WSL のホストの apply でも書く。足し直す `--force` も runner のもの)

use super::powershell_profile::{self, MARKER, Manual, contains, is_utf16, warn};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil::RunBackup;
use crate::record::Records;
use crate::report::Kind;
use std::borrow::Cow;
use std::io::Write;
use std::path::Path;

/// 記録のファイル名 (`$PROFILE` の Windows のパス → `"added"`)
pub const RECORD_FILE: &str = "starship-init.added.json";
/// `$PROFILE` に足す 1 行。starship が PATH に無ければ何もしない (`Get-Command` の `-CommandType Application` は PATH の exe だけを引く)。中は
/// starship の README の形 (`starship init powershell` が出す 2 段目の init を読む)
pub const LINE: &str = r#"if (Get-Command starship -CommandType Application -ErrorAction SilentlyContinue) { Invoke-Expression (&starship init powershell) }"#;
/// 書き直す前の `$PROFILE` の退避の置き場 (記録の置き場からの相対) と、残す回数
const BACKUP_REL: &str = "starship-init/backup";
const KEEP_BACKUPS: usize = 10;
/// 記録の値 (足した・既にあった)
const ADDED: &str = "added";
/// 記録が壊れていたときの直し方 (powershell-profile と同じ)
const BROKEN_HINT: &str = "消してから流し直してください (足した記録が無いものとして扱います)";
/// 足し直すコマンド (Windows にしか無い手順なので、受け持ちによらず runner の apply)
const AGAIN: &str = "dotfiles apply --steps starship-init --force";
/// 頭の UTF-8 の BOM
const BOM: &[u8] = b"\xef\xbb\xbf";

pub struct StarshipInit;

impl Step for StarshipInit {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "starship-init",
            order: 94,
            title: "$PROFILE に starship の init の 1 行を足す (dotfiles.ps1 を読む行より前)",
            gate: Gate::Always,
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode)]
    }
}

/// 1 行を足す所。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Place {
    /// `dotfiles.ps1` を読む行のすぐ前 (書き直す)
    Before,
    /// 末尾 (追記する)
    End,
}

impl Place {
    fn label(self) -> &'static str {
        match self {
            Place::Before => "dotfiles.ps1 を読む行の前",
            Place::End => "末尾",
        }
    }
}

/// 手順の中身 (記録 → pwsh → init の行 → 順番 → 足した記録 → UTF-16 → 足す)。
fn sync(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let record_path = ctx.state_dir.join(RECORD_FILE);
    let mut records = match Records::load_with(&record_path, BROKEN_HINT) {
        Ok(r) => r,
        Err(e) => {
            ctx.say(format!("!! {e}"));
            return Outcome::new(Kind::Failed, "足した記録が壊れている").note(e);
        }
    };
    let manual = manual();
    let (win_profile, profile) = match powershell_profile::locate(ctx, &manual) {
        Ok(found) => found,
        Err(outcome) => return outcome,
    };
    let current = match std::fs::read(&profile) {
        Ok(b) => Some(b),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            ctx.say(format!("!! $PROFILE が読めません: {win_profile} ({e})"));
            return Outcome::new(Kind::Failed, format!("$PROFILE が読めない ({e})"));
        }
    };
    let recorded = records.get(&win_profile) == Some(ADDED);
    // init の行と順番は字で探す (UTF-16 の $PROFILE は UTF-8 に直して読む。書くのは元のバイト列のまま)
    let text = current.as_deref().map(searchable);

    if let Some(bytes) = text.as_deref().filter(|b| init_line_at(b).is_some()) {
        ctx.say(format!("starship の init の行があります: {win_profile}"));
        if !recorded {
            if mode.writes() {
                records.set(&win_profile, ADDED);
                if let Err(e) = records.save_if_changed() {
                    return record_failed(ctx, &record_path, e);
                }
            } else {
                ctx.say("足した記録はまだありません (apply で、この行を見て記録だけ作ります)。");
            }
        }
        if init_after_marker(bytes) {
            warn(
                ctx,
                &[
                    format!(
                        "starship の init の行が、dotfiles.ps1 を読む行より後ろにあります: {win_profile}"
                    ),
                    "dotfiles.ps1 より後ろで init すると、Vi モードのモードが替わるたびにプロンプトを 2 回描き直します。notepad $PROFILE で、この行を dotfiles.ps1 を読む行より前へ移してください (runner は動かしません)。".to_string(),
                ],
            );
            return Outcome::new(
                Kind::Manual,
                "starship の init の行が dotfiles.ps1 を読む行より後ろにある → 前へ移す (runner は動かさない)",
            )
            .note("notepad $PROFILE で、starship の init の行を dotfiles.ps1 を読む行より前へ移す (後ろで init すると、Vi モードのモードが替わるたびにプロンプトを 2 回描き直す。win/README.md の「starship」)");
        }
        return Outcome::new(Kind::Ok, "init の行がある");
    }

    if recorded && !mode.force() {
        warn(
            ctx,
            &[
                format!(
                    "以前 $PROFILE に足した starship の init の 1 行が見当たりません: {win_profile}"
                ),
                format!(
                    "Windows 側で外したのなら、そのままにします。足し直すなら --force を付けて流してください: {AGAIN}"
                ),
            ],
        );
        return Outcome::new(
            Kind::Manual,
            "以前 $PROFILE に足した init の 1 行が無い (Windows 側で外したのなら、そのままでよい)",
        )
        .note(format!("足し直すなら {AGAIN}"));
    }

    if let Some(bytes) = &current
        && is_utf16(bytes)
    {
        warn(
            ctx,
            &manual.after(vec![format!(
                "$PROFILE が UTF-16 なので書き足しません: {win_profile}"
            )]),
        );
        return Outcome::new(Kind::Manual, "$PROFILE が UTF-16 なので書き足さない")
            .note(manual.note);
    }

    if let Some(cur) = current.as_deref()
        && let Some(at) = insert_at(cur)
        && continues_into(cur, at)
    {
        warn(
            ctx,
            &manual.after(vec![format!(
                "dotfiles.ps1 を読む行が前の行の続き (行末の `) なので、差し込みません: {win_profile}"
            )]),
        );
        return Outcome::new(
            Kind::Manual,
            "dotfiles.ps1 を読む行が前の行の続き (行末の `) なので差し込まない",
        )
        .note(manual.note);
    }

    let (bytes, place) = with_line(current.as_deref());
    let where_ = place.label();
    // 助詞の後ろに続けるときは、英字で始まる所の前に空白を置く (「の dotfiles.ps1 を読む行の前」・「の末尾」)
    let after_particle = if where_.starts_with(|c: char| c.is_ascii()) {
        format!(" {where_}")
    } else {
        where_.to_string()
    };
    let pending = Outcome::new(
        Kind::Missing,
        format!("init の 1 行が無い → apply で $PROFILE の{after_particle}に足す"),
    );
    match mode {
        Mode::Check => {
            ctx.say(format!(
                "starship の init の 1 行がありません (apply で{after_particle}に足す): {win_profile}"
            ));
            pending
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] 1 行を足す ({where_}): {win_profile}"));
            pending
        }
        Mode::Apply { .. } => {
            if place == Place::Before {
                // 書き直すので、前の中身を写してから (写せなければ書かない)
                let mut backup =
                    RunBackup::new(join_segments(&ctx.state_dir, BACKUP_REL), KEEP_BACKUPS);
                if let Err(e) = backup.copy(&profile) {
                    ctx.say(format!(
                        "!! 書き直す前の $PROFILE を写せないので書きません: {win_profile} ({e})"
                    ));
                    return Outcome::new(
                        Kind::Failed,
                        format!("書き直す前の $PROFILE を写せない ({e})"),
                    )
                    .note(manual.note);
                }
                if let Some(dir) = backup.dir() {
                    ctx.say(format!(
                        "書き直す前の $PROFILE を写しました: {}",
                        dir.display()
                    ));
                }
            }
            if let Err(e) = write_profile(&profile, current.as_deref(), place, &bytes) {
                ctx.say(format!("!! $PROFILE に書けません: {win_profile} ({e})"));
                return Outcome::new(Kind::Failed, format!("$PROFILE に書けない ({e})"))
                    .note(manual.note);
            }
            ctx.say(format!("足しました ({where_}): {win_profile}"));
            records.set(&win_profile, ADDED);
            if let Err(e) = records.save_if_changed() {
                return record_failed(ctx, &record_path, e);
            }
            ctx.say("開いている PowerShell では . $PROFILE で読み直してください (starship が入るまで、この行は何もしません。入れるのは手順 starship)。");
            Outcome::new(
                Kind::Ok,
                format!("$PROFILE に init の 1 行を足した ({where_})"),
            )
        }
    }
}

/// 自動で足せないときに、同じ 1 行を手で足す道。
fn manual() -> Manual {
    Manual {
        lines: vec![
            "PowerShell 7 で notepad $PROFILE を開き、dotfiles.ps1 を読む行より前 (無ければ末尾) に次の 1 行を足すと、同じになります:".to_string(),
            format!("  {LINE}"),
        ],
        note: format!(
            "PowerShell 7 で notepad $PROFILE を開き、dotfiles.ps1 を読む行より前 (無ければ末尾) に {LINE} を足すと、同じになる"
        ),
    }
}

/// starship の init の行か: `starship` と `init powershell` を含む (ASCII の大文字小文字を問わない。頭に `#` を付けた行も、人が外した印として読む)。
fn is_init_line(line: &[u8]) -> bool {
    let lower = line.to_ascii_lowercase();
    contains(&lower, b"starship") && contains(&lower, b"init powershell")
}

/// 行ごとに (頭のバイトの位置, 行) を並べる (`\n` で区切る。行の末尾の `\r` は行に残る)。
fn lines(bytes: &[u8]) -> impl Iterator<Item = (usize, &[u8])> {
    let mut start = 0;
    bytes.split(|b| *b == b'\n').map(move |l| {
        let at = start;
        start += l.len() + 1;
        (at, l)
    })
}

/// 最初の starship の init の行 (頭に `#` を付けた行も) の頭のバイトの位置。
fn init_line_at(bytes: &[u8]) -> Option<usize> {
    lines(bytes)
        .find(|(_, l)| is_init_line(l))
        .map(|(at, _)| at)
}

/// 頭に `#` を付けた行か (行頭の空白と UTF-8 の BOM を飛ばして見る)。外した行で、流れない
fn is_commented(line: &[u8]) -> bool {
    let line = line.strip_prefix(BOM).unwrap_or(line);
    line.iter()
        .find(|b| !b.is_ascii_whitespace())
        .is_some_and(|b| *b == b'#')
}

/// 流れる (頭に `#` の無い) starship の init の行が、流れる `dotfiles.ps1` を読む行より後ろにしか無いか。外した行は順番に数えない
fn init_after_marker(bytes: &[u8]) -> bool {
    let active = |pick: &dyn Fn(&[u8]) -> bool| {
        lines(bytes)
            .find(|(_, l)| pick(l) && !is_commented(l))
            .map(|(at, _)| at)
    };
    match (
        active(&is_init_line),
        active(&|l| contains(l, MARKER.as_bytes())),
    ) {
        (Some(init), Some(marker)) => marker < init,
        _ => false,
    }
}

/// 最初の `dotfiles.ps1` を読む行 (powershell-profile の `MARKER` を含む行) の頭のバイトの位置。
fn marker_line_at(bytes: &[u8]) -> Option<usize> {
    lines(bytes)
        .find(|(_, l)| contains(l, MARKER.as_bytes()))
        .map(|(at, _)| at)
}

/// `dotfiles.ps1` を読む行の前に差し込むなら、差し込む所のバイトの位置 (その行の頭。頭の行なら UTF-8 の BOM の後ろ)。
fn insert_at(cur: &[u8]) -> Option<usize> {
    marker_line_at(cur).map(|at| {
        if at == 0 && cur.starts_with(BOM) {
            BOM.len()
        } else {
            at
        }
    })
}

/// 差し込む所の前の行が、行末の ` (PowerShell で次の行へ続く印) で終わるか。そこに差し込むと文が切れる
fn continues_into(cur: &[u8], at: usize) -> bool {
    let Some(before) = cur[..at].strip_suffix(b"\n") else {
        return false;
    };
    let before = before.strip_suffix(b"\r").unwrap_or(before);
    before.iter().rev().find(|b| !matches!(b, b' ' | b'\t')) == Some(&b'`')
}

/// init の行と順番を探すための字。UTF-16 (頭の BOM で見る) なら UTF-8 に直し、ほかはそのまま
fn searchable(bytes: &[u8]) -> Cow<'_, [u8]> {
    let decode = |unit: fn([u8; 2]) -> u16| {
        let (pairs, _) = bytes[2..].as_chunks::<2>();
        let units: Vec<u16> = pairs.iter().map(|c| unit(*c)).collect();
        Cow::Owned(String::from_utf16_lossy(&units).into_bytes())
    };
    if bytes.starts_with(&[0xff, 0xfe]) {
        decode(u16::from_le_bytes)
    } else if bytes.starts_with(&[0xfe, 0xff]) {
        decode(u16::from_be_bytes)
    } else {
        Cow::Borrowed(bytes)
    }
}

/// `LINE` を入れた後の `$PROFILE` の中身と、入れた所。`dotfiles.ps1` を読む行があれば、そのすぐ前 (頭の行なら BOM の後ろ) に入れ、無ければ末尾に
/// 足す (末尾に改行が無ければ先に補う。BOM だけのファイルには補わない)。改行はファイルに合わせる (CR があれば CRLF)。
fn with_line(current: Option<&[u8]>) -> (Vec<u8>, Place) {
    let cur = current.unwrap_or_default();
    let nl: &[u8] = if cur.contains(&b'\r') { b"\r\n" } else { b"\n" };
    if let Some(at) = insert_at(cur) {
        return (
            [&cur[..at], LINE.as_bytes(), nl, &cur[at..]].concat(),
            Place::Before,
        );
    }
    let prefix: &[u8] = if !cur.is_empty() && cur != BOM && !cur.ends_with(b"\n") {
        nl
    } else {
        b""
    };
    ([cur, prefix, LINE.as_bytes(), nl].concat(), Place::End)
}

/// `$PROFILE` に書く。末尾に足すときは、増えた所だけをファイルの末尾へ追記する (無ければ親ごと作る)。差し込むときは、同じファイルに上書きする
/// (rename で置き換えない)。
fn write_profile(
    profile: &Path,
    current: Option<&[u8]>,
    place: Place,
    bytes: &[u8],
) -> std::io::Result<()> {
    match place {
        Place::End => {
            if current.is_none()
                && let Some(dir) = profile.parent()
            {
                std::fs::create_dir_all(dir)?;
            }
            let old = current.map_or(0, <[u8]>::len);
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(profile)?;
            f.write_all(&bytes[old..])
        }
        Place::Before => {
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .truncate(true)
                .open(profile)?;
            f.write_all(bytes)
        }
    }
}

fn record_failed(ctx: &mut Ctx, path: &Path, e: std::io::Error) -> Outcome {
    ctx.say(format!(
        "!! 足した記録を書けません: {} ({e})",
        path.display()
    ));
    Outcome::new(Kind::Failed, format!("足した記録を書けない ({e})"))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - `$PROFILE` が無ければ親ごと作って 1 行を書き (LF)、記録する。2 回流しても変わらない
    //! - dotfiles.ps1 を読む行があれば、そのすぐ前に差し込む (改行はファイルに合わせ、頭の UTF-8 の BOM は頭に残す)。書き直す前の中身を退避する
    //! - dotfiles.ps1 を読む行が無ければ末尾に足す (改行は $PROFILE に合わせ、末尾に改行が無ければ先に補う)
    //! - 新しい PC では powershell-profile より先に流れ、starship の init の行の後ろに dotfiles.ps1 を読む行が並ぶ
    //! - starship の init の行 (starship と init powershell を含む行。大文字小文字を問わず、頭に # を付けた行も。この PC の手で書いた
    //!   `Invoke-Expression (&starship init powershell)` も) があれば変えない。記録が無ければ apply で記録だけ付け、check は書かずにいつ作るかを出す
    //! - その行が dotfiles.ps1 を読む行より後ろにあれば、動かさずに前へ移すよう知らせる (manual)
    //! - 足した記録があって消えていたら足し直さず、--force を案内する。--force なら足し直す
    //! - check と --dry-run は $PROFILE も記録も書かない。UTF-16 の $PROFILE には書かない (init の行があるかは字に直して読む)。差し込む所の前の
    //!   行が行末の ` で終わるなら書かない。壊れた記録・ディレクトリの置き先では止まる。pwsh が無ければ何も書かずに、手で足す道を添える
    //! - 足す 1 行は自分を starship の init の行と読み、dotfiles.ps1 を読む行とは読まない
    //! - 本物の pwsh: starship が PATH に無ければ 1 行は何も出さずに通り、あれば `starship init powershell` の出力を読む (pwsh が PATH にあるとき)

    use super::*;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::{Exit, RunResult};
    use crate::steps::powershell_profile::{self, PowershellProfile};
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    /// powershell-profile が足す、dotfiles.ps1 を読む 1 行 (WSL の script の line と同じ字を手で書いたもの)
    const DOTFILES_LINE: &str = r#"if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }"#;
    /// この PC の $PROFILE にユーザーが手で書いた starship の init の行 (starship の README の形)
    const HAND_LINE: &str = "Invoke-Expression (&starship init powershell)";
    const RUNNER_HOST: &str = "[runner]\nenable = true\n";
    const WSL_HOST: &str = "group = \"minimum\"\n";
    const APPLY: Mode = Mode::Apply { force: false };

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            Env {
                t: TempDir::new("starship-init"),
            }
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        /// pwsh が返す $PROFILE の場所 (ドキュメントが OneDrive の下にある PC の形)
        fn profile(&self) -> PathBuf {
            self.home()
                .join("OneDrive")
                .join("ドキュメント")
                .join("PowerShell")
                .join("Microsoft.PowerShell_profile.ps1")
        }

        fn record(&self) -> PathBuf {
            self.t.path().join("state").join(RECORD_FILE)
        }

        fn backup_root(&self) -> PathBuf {
            self.t
                .path()
                .join("state")
                .join("starship-init")
                .join("backup")
        }

        fn write_profile(&self, bytes: &[u8]) {
            std::fs::create_dir_all(self.profile().parent().unwrap()).unwrap();
            std::fs::write(self.profile(), bytes).unwrap();
        }

        fn read_profile(&self) -> Vec<u8> {
            std::fs::read(self.profile()).unwrap()
        }

        fn profile_text(&self) -> String {
            String::from_utf8(self.read_profile()).unwrap()
        }

        /// 記録に、この $PROFILE を足した印 (added) があるか
        fn recorded(&self) -> bool {
            self.record().exists()
                && serde_json::from_str::<serde_json::Value>(
                    &std::fs::read_to_string(self.record()).unwrap(),
                )
                .unwrap()[self.profile().to_string_lossy().as_ref()]
                    == "added"
        }

        /// pwsh が PATH にあり、$PROFILE の場所を答える偽の口
        fn sys(&self) -> FakeSys {
            let p = self.profile().to_string_lossy().into_owned();
            FakeSys::new(move |_| RunResult {
                exit: Exit::Code(0),
                output: vec![p.clone()],
            })
            .with_program("pwsh", "/fake/pwsh")
        }

        fn ctx_run(
            &self,
            sys: &FakeSys,
            host: &str,
            mode: Mode,
            step: &dyn Step,
        ) -> (Outcome, String) {
            // powershell-profile は dotfiles.ps1 が配られてから足すので、配った形にしておく
            self.t
                .write("home/.config/powershell/dotfiles.ps1", "# dotfiles.ps1\n");
            let mut out = Vec::new();
            let mut outcomes = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys,
                    out: &mut out,
                };
                step.run(&mut ctx, mode)
            };
            let out = String::from_utf8(out).unwrap();
            assert_eq!(outcomes.len(), 1, "{outcomes:?}\n{out}");
            (outcomes.remove(0), out)
        }

        /// starship-init を流し、行 (1 つ) と出力を返す
        fn run(&self, sys: &FakeSys, mode: Mode) -> (Outcome, String) {
            self.ctx_run(sys, RUNNER_HOST, mode, &StarshipInit)
        }
    }

    fn has_note(o: &Outcome, part: &str) -> bool {
        o.notes.iter().any(|n| n.contains(part))
    }

    #[test]
    fn info_is_a_windows_only_step_before_powershell_profile() {
        let i = StarshipInit.info();
        assert_eq!(i.id, "starship-init");
        assert_eq!(i.gate, Gate::Always);
        assert!(i.windows_only && i.ported);
        // 新しい PC で init の行を dotfiles.ps1 を読む行より先に足すため、powershell-profile より前に流れる
        assert!(i.order < PowershellProfile.info().order);
    }

    #[test]
    fn new_profile_gets_the_line_and_is_recorded() {
        let e = Env::new();
        let sys = e.sys();
        let shown = e.profile().to_string_lossy().into_owned();
        let (o, out) = e.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(
            out.contains(&format!(
                "starship の init の 1 行がありません (apply で末尾に足す): {shown}"
            )),
            "{out}"
        );
        let (o, out) = e.run(&sys, Mode::DryRun { force: false });
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(
            out.contains(&format!("[dry-run] 1 行を足す (末尾): {shown}")),
            "{out}"
        );
        assert!(!e.profile().exists());
        assert!(!e.record().exists());

        let (o, out) = e.run(&sys, APPLY);
        assert_eq!(
            o,
            Outcome::new(Kind::Ok, "$PROFILE に init の 1 行を足した (末尾)"),
            "{out}"
        );
        assert_eq!(e.profile_text(), format!("{LINE}\n"));
        assert!(e.recorded());
        assert!(
            out.contains(&format!("足しました (末尾): {shown}")),
            "{out}"
        );
        assert!(
            out.contains("開いている PowerShell では . $PROFILE で読み直してください"),
            "{out}"
        );
        // 末尾に足すときは書き直さないので、退避しない
        assert!(!e.backup_root().exists());

        // 2 回流しても変わらない
        let (o, out) = e.run(&sys, APPLY);
        assert_eq!(o, Outcome::new(Kind::Ok, "init の行がある"), "{out}");
        assert!(
            out.contains(&format!("starship の init の行があります: {shown}")),
            "{out}"
        );
        assert_eq!(e.profile_text(), format!("{LINE}\n"));
    }

    #[test]
    fn inserts_before_the_dotfiles_line_and_backs_up() {
        let e = Env::new();
        let before = format!(
            "Set-PSReadLineOption -PredictionSource History\r\n{DOTFILES_LINE}\r\n# dotfiles.ps1 の後ろに置く割り当て\r\nSet-PSReadLineKeyHandler -Chord Ctrl+t -Function x\r\n"
        );
        e.write_profile(before.as_bytes());
        let sys = e.sys();
        let shown = e.profile().to_string_lossy().into_owned();
        let (o, out) = e.run(&sys, Mode::DryRun { force: false });
        assert_eq!(
            o,
            Outcome::new(
                Kind::Missing,
                "init の 1 行が無い → apply で $PROFILE の dotfiles.ps1 を読む行の前に足す"
            ),
            "{out}"
        );
        assert!(
            out.contains(&format!(
                "[dry-run] 1 行を足す (dotfiles.ps1 を読む行の前): {shown}"
            )),
            "{out}"
        );
        assert_eq!(e.profile_text(), before);

        let (o, out) = e.run(&sys, APPLY);
        assert_eq!(
            o,
            Outcome::new(
                Kind::Ok,
                "$PROFILE に init の 1 行を足した (dotfiles.ps1 を読む行の前)"
            ),
            "{out}"
        );
        assert_eq!(
            e.profile_text(),
            format!(
                "Set-PSReadLineOption -PredictionSource History\r\n{LINE}\r\n{DOTFILES_LINE}\r\n# dotfiles.ps1 の後ろに置く割り当て\r\nSet-PSReadLineKeyHandler -Chord Ctrl+t -Function x\r\n"
            )
        );
        assert!(e.recorded());
        // 書き直す前の中身を 1 回ぶんの退避のディレクトリへ写す
        let runs: Vec<PathBuf> = std::fs::read_dir(e.backup_root())
            .unwrap()
            .map(|d| d.unwrap().path())
            .collect();
        assert_eq!(runs.len(), 1, "{runs:?}");
        let copied = runs[0].join("Microsoft.PowerShell_profile.ps1");
        assert_eq!(std::fs::read_to_string(&copied).unwrap(), before);
        assert!(
            out.contains(&format!(
                "書き直す前の $PROFILE を写しました: {}",
                runs[0].display()
            )),
            "{out}"
        );
        assert!(
            out.contains(&format!("足しました (dotfiles.ps1 を読む行の前): {shown}")),
            "{out}"
        );
    }

    #[test]
    fn inserts_after_the_bom_when_the_dotfiles_line_comes_first() {
        let e = Env::new();
        e.write_profile(format!("\u{feff}{DOTFILES_LINE}\n").as_bytes());
        let (o, out) = e.run(&e.sys(), APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(
            e.profile_text(),
            format!("\u{feff}{LINE}\n{DOTFILES_LINE}\n")
        );
    }

    #[test]
    fn appends_following_the_newlines_when_there_is_no_dotfiles_line() {
        for (name, before, after) in [
            (
                "CRLF・末尾の改行なし",
                "Set-Alias g git\r\n# 末尾に改行なし".to_string(),
                format!("Set-Alias g git\r\n# 末尾に改行なし\r\n{LINE}\r\n"),
            ),
            (
                "LF・末尾の改行あり",
                "Set-Alias g git\n".to_string(),
                format!("Set-Alias g git\n{LINE}\n"),
            ),
            (
                "LF・末尾の改行なし",
                "Set-Alias g git".to_string(),
                format!("Set-Alias g git\n{LINE}\n"),
            ),
            ("空", String::new(), format!("{LINE}\n")),
            (
                "BOM だけ",
                "\u{feff}".to_string(),
                format!("\u{feff}{LINE}\n"),
            ),
        ] {
            let e = Env::new();
            e.write_profile(before.as_bytes());
            let (o, out) = e.run(&e.sys(), APPLY);
            assert_eq!(
                o,
                Outcome::new(Kind::Ok, "$PROFILE に init の 1 行を足した (末尾)"),
                "{name}: {out}"
            );
            assert_eq!(e.profile_text(), after, "{name}");
            assert!(e.recorded(), "{name}");
        }
    }

    /// 新しい PC (`$PROFILE` が無い): starship-init (94) が init の行を足し、続く powershell-profile (95) がその後ろに dotfiles.ps1 を読む行を足す
    #[test]
    fn new_pc_gets_the_init_line_before_the_dotfiles_line() {
        let e = Env::new();
        let sys = e.sys();
        let (o, out) = e.run(&sys, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        let (o, out) = e.ctx_run(&sys, RUNNER_HOST, APPLY, &PowershellProfile);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.profile_text(), format!("{LINE}\n{DOTFILES_LINE}\n"));
        // どちらも 2 回目は変えない
        let (o, _) = e.run(&sys, APPLY);
        assert_eq!(o, Outcome::new(Kind::Ok, "init の行がある"));
        let (o, _) = e.ctx_run(&sys, RUNNER_HOST, APPLY, &PowershellProfile);
        assert_eq!(o.kind, Kind::Ok);
        assert_eq!(e.profile_text(), format!("{LINE}\n{DOTFILES_LINE}\n"));
    }

    /// 手で書いた starship の init の行 (この PC の形・頭に # を付けた行・大文字小文字の違う行・exe のパスで呼ぶ行・2 段の init を自分で書いた行) は
    /// 変えずに、記録だけ付ける (二重に init しない)
    #[test]
    fn hand_written_init_lines_are_kept_and_only_recorded() {
        for line in [
            HAND_LINE,
            "# Invoke-Expression (&starship init powershell)",
            "Invoke-Expression (& Starship Init PowerShell)",
            "Invoke-Expression (& 'C:\\Program Files\\starship\\bin\\starship.exe' init powershell)",
            "Invoke-Expression (&starship init powershell --print-full-init | Out-String)",
        ] {
            let e = Env::new();
            let before = format!("{line}\r\n{DOTFILES_LINE}\r\n");
            e.write_profile(before.as_bytes());
            let sys = e.sys();
            // check は書かず、記録がまだ無いことと、いつ作るかを出す
            let (o, out) = e.run(&sys, Mode::Check);
            assert_eq!(
                o,
                Outcome::new(Kind::Ok, "init の行がある"),
                "{line}: {out}"
            );
            assert!(
                out.contains(
                    "足した記録はまだありません (apply で、この行を見て記録だけ作ります)。"
                ),
                "{line}: {out}"
            );
            assert!(!e.record().exists(), "{line}");
            // apply は変えずに記録だけ付ける。付けた後の check は記録のことを言わない
            let (o, out) = e.run(&sys, APPLY);
            assert_eq!(
                o,
                Outcome::new(Kind::Ok, "init の行がある"),
                "{line}: {out}"
            );
            assert_eq!(e.profile_text(), before, "{line}");
            assert!(e.recorded(), "{line}");
            let (_, out) = e.run(&sys, Mode::Check);
            assert!(!out.contains("記録"), "{line}: {out}");
        }
    }

    /// 手で書いた init の行が dotfiles.ps1 を読む行より後ろにあれば、動かさずに前へ移すよう知らせる (dotfiles.ps1 は init が先に置いた
    /// handler を置き換える前提で、後ろで init すると handler を包み、モードが替わるたびに 2 回描き直す)
    #[test]
    fn init_line_after_the_dotfiles_line_is_manual() {
        let e = Env::new();
        let before = format!("{DOTFILES_LINE}\n{HAND_LINE}\n");
        e.write_profile(before.as_bytes());
        let sys = e.sys();
        for mode in [Mode::Check, APPLY] {
            let (o, out) = e.run(&sys, mode);
            assert_eq!(o.kind, Kind::Manual, "{mode:?}: {out}");
            assert_eq!(
                o.text,
                "starship の init の行が dotfiles.ps1 を読む行より後ろにある → 前へ移す (runner は動かさない)"
            );
            assert!(has_note(&o, "dotfiles.ps1 を読む行より前へ移す"), "{o:?}");
            assert!(
                out.contains(
                    "!! starship の init の行が、dotfiles.ps1 を読む行より後ろにあります: "
                ),
                "{out}"
            );
            assert_eq!(e.profile_text(), before);
        }
        // apply は行を動かさないが、行があるので記録は付ける (この後で消しても足し直さない)
        assert!(e.recorded());
    }

    /// 順番を見るのは、どちらの行も頭に # の無い (流れる) 行のときだけ。頭に # を付けて外した init の行が後ろにあっても、外した dotfiles.ps1 の行の
    /// 後ろに init の行があっても、知らせない (足しもしない)
    #[test]
    fn commented_lines_do_not_count_for_the_order() {
        for before in [
            format!("{DOTFILES_LINE}\n  # {HAND_LINE}\n"),
            format!("# {DOTFILES_LINE}\n{HAND_LINE}\n"),
            format!("{HAND_LINE}\n{DOTFILES_LINE}\n# {HAND_LINE}\n"),
        ] {
            let e = Env::new();
            e.write_profile(before.as_bytes());
            let (o, out) = e.run(&e.sys(), APPLY);
            assert_eq!(
                o,
                Outcome::new(Kind::Ok, "init の行がある"),
                "{before}: {out}"
            );
            assert_eq!(e.profile_text(), before);
            assert!(e.recorded(), "{before}");
        }
    }

    #[test]
    fn removed_line_is_not_added_back_without_force() {
        let e = Env::new();
        let sys = e.sys();
        let shown = e.profile().to_string_lossy().into_owned();
        e.write_profile(format!("{DOTFILES_LINE}\n").as_bytes());
        e.run(&sys, APPLY);
        assert!(e.recorded());
        let removed = format!("{DOTFILES_LINE}\n");
        e.write_profile(removed.as_bytes());

        let (o, out) = e.run(&sys, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert_eq!(
            o.text,
            "以前 $PROFILE に足した init の 1 行が無い (Windows 側で外したのなら、そのままでよい)"
        );
        assert!(
            out.contains(&format!(
                "!! 以前 $PROFILE に足した starship の init の 1 行が見当たりません: {shown}"
            )),
            "{out}"
        );
        assert!(
            has_note(&o, "dotfiles apply --steps starship-init --force"),
            "{o:?}"
        );
        let (o, _) = e.run(&sys, APPLY);
        assert_eq!(o.kind, Kind::Manual);
        assert_eq!(e.profile_text(), removed);
        // 受け持ちが WSL のホストでも、Windows にしか無い手順なので runner の --force を案内する
        let (o, _) = e.ctx_run(&sys, WSL_HOST, Mode::Check, &StarshipInit);
        assert!(
            has_note(&o, "dotfiles apply --steps starship-init --force"),
            "{o:?}"
        );

        let (o, out) = e.run(&sys, Mode::DryRun { force: true });
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert_eq!(e.profile_text(), removed);
        let (o, out) = e.run(&sys, Mode::Apply { force: true });
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.profile_text(), format!("{LINE}\n{DOTFILES_LINE}\n"));
    }

    /// UTF-16 の $PROFILE も、starship の init の行があるかは字に直して読む (書かないが、手で書いた行を見落として「手で足す」と案内しない)
    #[test]
    fn utf16_profile_with_an_init_line_is_found() {
        let text = format!("{HAND_LINE}\r\n{DOTFILES_LINE}\r\n");
        let le: Vec<u8> = [0xff, 0xfe]
            .into_iter()
            .chain(text.encode_utf16().flat_map(u16::to_le_bytes))
            .collect();
        let be: Vec<u8> = [0xfe, 0xff]
            .into_iter()
            .chain(text.encode_utf16().flat_map(u16::to_be_bytes))
            .collect();
        for before in [le, be] {
            let e = Env::new();
            e.write_profile(&before);
            let (o, out) = e.run(&e.sys(), APPLY);
            assert_eq!(o, Outcome::new(Kind::Ok, "init の行がある"), "{out}");
            assert_eq!(e.read_profile(), before);
            assert!(e.recorded());
        }
    }

    /// 差し込む所の前の行が行末の ` (次の行へ続く) で終わるなら、差し込むと文が切れて PowerShell の起動のたびにエラーになるので、書かずに
    /// 手で足す道を添える
    #[test]
    fn does_not_insert_into_a_backtick_continuation() {
        let e = Env::new();
        let before =
            format!("Set-PSReadLineOption -PredictionSource History `\r\n  {DOTFILES_LINE}\r\n");
        e.write_profile(before.as_bytes());
        for mode in [Mode::Check, APPLY] {
            let (o, out) = e.run(&e.sys(), mode);
            assert_eq!(o.kind, Kind::Manual, "{mode:?}: {out}");
            assert_eq!(
                o.text,
                "dotfiles.ps1 を読む行が前の行の続き (行末の `) なので差し込まない"
            );
            assert!(has_note(&o, LINE), "{o:?}");
            assert_eq!(e.profile_text(), before);
        }
        assert!(!e.record().exists());
        assert!(!e.backup_root().exists());
    }

    #[test]
    fn utf16_profile_is_left_alone() {
        for before in [&b"\xff\xfe#\x00\n\x00"[..], &b"\xfe\xff\x00#\x00\n"[..]] {
            let e = Env::new();
            e.write_profile(before);
            let (o, out) = e.run(&e.sys(), APPLY);
            assert_eq!(o.kind, Kind::Manual, "{out}");
            assert!(
                out.contains("!! $PROFILE が UTF-16 なので書き足しません: "),
                "{out}"
            );
            assert!(has_note(&o, LINE), "{o:?}");
            assert_eq!(e.read_profile(), before);
            assert!(!e.record().exists());
        }
    }

    #[test]
    fn broken_record_and_directory_stop() {
        let e = Env::new();
        e.t.write(&format!("state/{RECORD_FILE}"), "not json\n");
        let sys = e.sys();
        let (o, out) = e.run(&sys, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("が壊れています (JSON の object ではありません)。"),
            "{out}"
        );
        assert!(!e.profile().exists());
        // 記録を確かめてから pwsh に聞く
        assert!(sys.calls.borrow().is_empty());

        let e = Env::new();
        std::fs::create_dir_all(e.profile()).unwrap();
        let (o, out) = e.run(&e.sys(), APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("!! $PROFILE の場所がディレクトリです: "),
            "{out}"
        );
    }

    /// pwsh が無ければ何も書かず、dotfiles.ps1 を読む行より前に同じ 1 行を手で足す道を添える (場所を聞く口は powershell-profile と同じ)
    #[test]
    fn without_pwsh_shows_how_to_add_by_hand() {
        let e = Env::new();
        let sys = FakeSys::new(|_| unreachable!());
        let (o, out) = e.run(&sys, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(out.starts_with("!! pwsh が見つかりません"), "{out}");
        assert!(has_note(&o, "dotfiles.ps1 を読む行より前"), "{o:?}");
        assert!(has_note(&o, LINE), "{o:?}");
        assert!(out.contains(&format!("\n     {LINE}\n")), "{out}");
        assert!(!e.profile().exists());
        assert!(!e.record().exists());
    }

    /// 足す 1 行は、次に流したときに自分を starship の init の行と読み (二重に足さない)、dotfiles.ps1 を読む行とは読まない (powershell-profile が
    /// 自分の行を足し忘れない)
    #[test]
    fn line_reads_as_an_init_line_and_not_as_the_dotfiles_line() {
        assert!(is_init_line(LINE.as_bytes()));
        assert!(!powershell_profile::contains(
            LINE.as_bytes(),
            powershell_profile::MARKER.as_bytes()
        ));
        assert!(!is_init_line(DOTFILES_LINE.as_bytes()));
        assert!(!is_init_line(b"Set-Alias s starship"));
    }

    /// 本物の pwsh で 1 行を流す: starship が PATH に無ければ、何も出さずにエラー無しで通る (starship の無い PC の起動を止めない)。PATH に
    /// starship があれば `starship init powershell` を呼び、出た式を読む。pwsh が PATH に無ければ飛ばす (GitHub Actions の ubuntu と windows の
    /// image にはある)
    #[test]
    fn real_pwsh_runs_the_line_quietly_without_starship_and_inits_with_it() {
        use crate::process::{CommandSpec, RealSys, Sys};
        let Some(pwsh) = RealSys.which("pwsh") else {
            return;
        };
        let t = TempDir::new("starship-init-pwsh");
        let empty = t.path().join("empty");
        std::fs::create_dir_all(&empty).unwrap();
        // 偽の starship: init powershell と呼ばれたら、印を出す式を出す
        let fake = t.path().join("fake");
        std::fs::create_dir_all(&fake).unwrap();
        if cfg!(windows) {
            t.write(
                "fake/starship.cmd",
                "@if \"%1 %2\"==\"init powershell\" echo Write-Output starship-init-ran\r\n",
            );
        } else {
            let p = t.write(
                "fake/starship",
                "#!/bin/sh\n[ \"$1 $2\" = 'init powershell' ] && echo 'Write-Output starship-init-ran'\n",
            );
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            let _ = p;
        }
        let run_with_path = |dir: &Path| {
            let body = format!(
                "$ErrorActionPreference = 'Stop'; $env:PATH = '{}'; {LINE}; exit 0",
                dir.display().to_string().replace('\'', "''")
            );
            RealSys.run(
                &CommandSpec::new(&pwsh)
                    .arg("-NoProfile")
                    .arg("-NonInteractive")
                    .arg("-Command")
                    .arg(&body)
                    .timeout(std::time::Duration::from_secs(60)),
                &mut |_| {},
            )
        };
        let r = run_with_path(&empty);
        assert_eq!(r.exit, Exit::Code(0), "{:?}", r.output);
        assert!(
            r.output.iter().all(|l| l.trim().is_empty()),
            "starship が無いときは何も出さない: {:?}",
            r.output
        );
        let r = run_with_path(&fake);
        assert_eq!(r.exit, Exit::Code(0), "{:?}", r.output);
        assert!(
            r.output.iter().any(|l| l.trim() == "starship-init-ran"),
            "{:?}",
            r.output
        );
    }
}
