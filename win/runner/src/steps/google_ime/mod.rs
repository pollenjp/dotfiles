//! google-ime (order 98): Google 日本語入力の設定 (`config1.db`) とユーザー辞書 (`user_dictionary.db`) を、repo のテキストから組み立てて
//! `%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input\` に置く。WSL の `nix/scripts/bootstrap-windows-google-ime.sh` と、それが呼ぶ
//! pjp-google-ime (`nix/pkgs/pjp-google-ime/`。Python と protobuf) を写したもの (組み立てるバイト列・digest・判定・記録の名前と形・退避・衝突・
//! `--force`・取り込み・変換サーバーの落とし方と落とし直しの印・文言をそろえる。受け持ちを runner に切り替えた後に、WSL の setup が置いたものを
//! 同じものとして引き継ぐため)。決めごとは dotfiles-private の docs/adr/015_win_google_ime_powertoys_*、移し方は docs/adr/060_win_runner_core_* の
//! spec §8 の 5 (protobuf は要るメッセージだけを手で読み書きする。`pb.rs`・`textpb.rs`・`ime.rs`)。
//!
//! - 読むテキスト: dotfiles の `win/google-japanese-input/` (`config.txtpb`・`keymap.tsv`・あれば `romaji.tsv`) と、dotfiles-private の clone の
//!   `google-japanese-input/dictionaries/` (無ければ辞書は飛ばして ⚠)。道具の switch `privateRepos` が off のホスト (gh にログインできない PC など) は
//!   辞書を扱わず (Windows の辞書にも触らない。⚠ にしない)、設定だけを置く。取り込みも辞書を書かない (dotfiles-private の
//!   docs/adr/111_win_runner_without_gh_*)
//! - ファイルごとに、時刻などを外した中身の digest で判定する (WSL と同じ):
//!
//!   | Windows 側 | すること |
//!   | --- | --- |
//!   | 無い | 置く |
//!   | 組み立てたものと同じ | 何もしない (記録だけ合わせる) |
//!   | 前回置いたときの記録と同じ (repo の側が進んだ) | 退避してから置く |
//!   | それ以外 (画面で変えた・記録が無い・読めない) | 衝突。設定はテキストの diff、辞書は辞書ごとの行の数だけを出して触らない (`--force` なら退避して置く) |
//!
//! - 置いたものがあれば `taskkill /F /IM GoogleIMEJaConverter.exe` で変換サーバーを落とす (次のキー入力で起き直し、置いた設定を読む)。落とせなければ
//!   印 (`restart-pending`) を残し、次の apply は置くものが無くても落とし直す。印は最初に置く直前に作る
//! - apply は、置く前に `tasklist` で設定画面・辞書ツール (`GoogleIMEJaTool.exe`) が開いていないかを見る (開いていれば止まる。確かめられなければ
//!   置かない)
//! - 記録 (`deployed.json`)・印・退避 (`backup\<UTC の時刻>-<pid>\`。10 回分) は `%LOCALAPPDATA%\dotfiles\state\google-japanese-input\` に、WSL の
//!   `~/.local/state/dotfiles/google-japanese-input/` と同じ名前と形で置く。WSL の記録は読まない
//! - check と dry-run は何も書かない (Google 日本語入力のファイル・記録・退避・印) し、tasklist も taskkill も打たない (WSL の --dry-run と同じ)
//! - 辞書の語は出さない: 辞書の衝突は辞書ごとの行の数だけを出す。語の diff は `--show-words` (自分の端末で `dotfiles check --steps google-ime
//!   --show-words`)
//! - 取り込み (`dotfiles import google-ime`。WSL の `--import`): Windows 側の 2 つのファイルをテキストに戻して repo と dotfiles-private へ書き、記録を
//!   取り込みで読んだときの digest に合わせる (読み直さない)。取り込みが書き換えるテキストに commit していない変更があれば止まる。確かめが全部
//!   通ってから書く (途中で書けなくなったら、そう出す)
//! - SSH の会話 (Windows のセッション 0) でも同じに流す: tasklist は全部のセッションのプロセスを数え、taskkill は同じユーザーの別のセッションの
//!   プロセスも止められる見込み (実機では確かめていない。止められなければ印を残して ⚠ になり、次の apply が落とし直す)

mod ime;
mod pb;
#[cfg(test)]
mod tests;
mod textpb;

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil::{self, RunBackup};
use crate::host::PRIVATE_REPOS;
use crate::process::{CommandSpec, Exit};
use crate::record::Records;
use crate::report::Kind;
use ime::Db;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// 設定のテキスト (repo からの相対)
pub const CONFIG_REL: &str = "win/google-japanese-input";
/// 辞書のテキスト (dotfiles-private の clone からの相対)
pub const DICT_REL: &str = "google-japanese-input/dictionaries";
/// 置き先 (`%USERPROFILE%` からの相対)
pub const IME_REL: &str = "AppData/LocalLow/Google/Google Japanese Input";
/// 記録・印・退避の置き場 (記録の置き場からの相対。WSL の `~/.local/state/dotfiles/google-japanese-input` と同じ並び)
pub const STATE_REL: &str = "google-japanese-input";
pub const RECORD_FILE: &str = "deployed.json";
/// 落とし直しの印 (置いたのに変換サーバーを落とせていない間だけある。中身は空)
pub const PENDING_FILE: &str = "restart-pending";
const BACKUP_DIR: &str = "backup";
/// 退避を残す回数 (WSL の `keep_backups`)
pub const KEEP_BACKUPS: usize = 10;
pub const CONVERTER: &str = "GoogleIMEJaConverter.exe";
pub const TOOL: &str = "GoogleIMEJaTool.exe";
/// tasklist・taskkill を待つ上限 (WSL の `timeout 30`)
pub const TASK_SECS: u64 = 30;
/// 取り込みが書き換える設定のテキスト (WSL の watched_of。同じディレクトリの Install-GoogleJapaneseInput.ps1 は見ない)
const WATCHED: [&str; 3] = [ime::TXTPB, ime::KEYMAP, ime::ROMAJI];

/// Google 日本語入力の設定と辞書を置く手順。`show_words` は辞書の衝突でも語の diff を出す (`--show-words`)。
#[derive(Default)]
pub struct GoogleIme {
    pub show_words: bool,
}

impl Step for GoogleIme {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "google-ime",
            order: 98,
            title: "Google 日本語入力の設定とユーザー辞書を組み立てて置く",
            gate: Gate::Always,
            ported: true,
            windows_only: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode, self.show_words)]
    }
}

/// 置き場所。
struct Paths {
    config_dir: PathBuf,
    private: PathBuf,
    dict_dir: PathBuf,
    ime_dir: PathBuf,
    state: PathBuf,
}

impl Paths {
    fn new(ctx: &Ctx) -> Paths {
        let private = ctx.sibling("dotfiles-private");
        Paths {
            config_dir: ctx.repo_path(CONFIG_REL),
            dict_dir: join_segments(&private, DICT_REL),
            private,
            ime_dir: join_segments(&ctx.roots.user_profile, IME_REL),
            state: join_segments(&ctx.state_dir, STATE_REL),
        }
    }

    fn record(&self) -> PathBuf {
        self.state.join(RECORD_FILE)
    }

    fn pending(&self) -> PathBuf {
        self.state.join(PENDING_FILE)
    }

    fn backup(&self) -> PathBuf {
        self.state.join(BACKUP_DIR)
    }
}

/// 手順の前半 (WSL と同じ順に確かめる: config.txtpb → 置き先 → 辞書のテキスト → 記録)。
struct Prepared {
    paths: Paths,
    /// 辞書のテキストのディレクトリ (無ければ辞書は飛ばす)
    dict: Option<PathBuf>,
    /// 辞書を扱わないホスト (privateRepos が off。辞書の正本は private な dotfiles-private)。飛ばしても ⚠ にしない
    dict_unused: bool,
    records: Records,
    /// 締めの行に添える ※ (辞書を飛ばした)
    notes: Vec<String>,
}

/// Program Files にある変換サーバーの exe (入っているが、まだ使っていないかを見分ける。Install-GoogleJapaneseInput.ps1 と同じく、ProgramW6432・
/// ProgramFiles・ProgramFiles(x86) を見る)
fn converter_exe(ctx: &Ctx) -> Option<PathBuf> {
    let mut seen: Vec<String> = Vec::new();
    for var in ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"] {
        let Some(root) = ctx.sys.env(var).filter(|v| !v.is_empty()) else {
            continue;
        };
        let key = root.trim_end_matches(['\\', '/']).to_lowercase();
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        let exe = join_segments(Path::new(&root), "Google/Google Japanese Input").join(CONVERTER);
        if exe.is_file() {
            return Some(exe);
        }
    }
    None
}

fn prepare(ctx: &mut Ctx, for_import: bool) -> Result<Prepared, Outcome> {
    let paths = Paths::new(ctx);
    let txtpb = paths.config_dir.join(ime::TXTPB);
    if !txtpb.is_file() {
        ctx.say(format!(
            "{} がありません (この checkout は Google 日本語入力の設定を持っていない)。この手順は飛ばします。",
            txtpb.display()
        ));
        return Err(Outcome::new(
            Kind::Info,
            "config.txtpb が無いので飛ばした (この checkout は Google 日本語入力の設定を持っていない)",
        ));
    }
    if !paths.ime_dir.is_dir() {
        // 置き先は Google 日本語入力が初めて起動したときに作る。入れただけでまだ使っていないマシンでは無いので、変換サーバーの exe で
        // 「入っている」を見分けて案内する。置き先を先に作って置くことはしない (Google 日本語入力が作るときの権限と揃わないおそれがある)
        if converter_exe(ctx).is_some() {
            ctx.say(format!(
                "!! Google 日本語入力は入っていますが、まだ使われていません ({} が無い)。この手順は飛ばします。",
                paths.ime_dir.display()
            ));
            ctx.say(
                "   Google 日本語入力で一度何か打ってから (置き先ができる)、流し直してください。",
            );
            return Err(Outcome::new(
                Kind::Manual,
                "Google 日本語入力は入っているが、まだ使われていない (置き先が無い)",
            )
            .note("Google 日本語入力で一度何か打ってから (置き先ができる)、流し直す"));
        }
        ctx.say(format!(
            "Google 日本語入力が入っていません ({} が無い)。この手順は飛ばします。",
            paths.ime_dir.display()
        ));
        return Err(Outcome::new(
            Kind::Info,
            format!(
                "Google 日本語入力が入っていないので飛ばした ({} が無い)",
                paths.ime_dir.display()
            ),
        ));
    }
    let mut dict = Some(paths.dict_dir.clone());
    let mut notes = Vec::new();
    let dict_unused = !ctx.host.tool(PRIVATE_REPOS);
    if dict_unused {
        // 辞書の正本は private な dotfiles-private。privateRepos が off のホスト (gh にログインできない PC など) では辞書を扱わず、Windows の
        // 辞書にも触らない (設定だけを置く。dotfiles-private の docs/adr/111_win_runner_without_gh_*)
        ctx.say(
            "辞書は扱いません (privateRepos が off。辞書の正本は dotfiles-private)。設定だけを置きます。",
        );
        dict = None;
    } else if !paths.dict_dir.is_dir() {
        if for_import && paths.private.join(".git").is_dir() {
            if let Err(e) = std::fs::create_dir_all(&paths.dict_dir) {
                ctx.say(format!(
                    "!! 辞書のテキストのディレクトリを作れません: {} ({e})",
                    paths.dict_dir.display()
                ));
                return Err(
                    Outcome::new(Kind::Failed, "辞書のテキストのディレクトリを作れない")
                        .note(format!("{} ({e})", paths.dict_dir.display())),
                );
            }
        } else {
            ctx.say(format!(
                "!! 辞書のテキスト ({}) が無いので、辞書は飛ばします (dotfiles-private を取れていないかも)。",
                paths.dict_dir.display()
            ));
            notes.push(format!(
                "辞書のテキスト ({}) が無いので、辞書は飛ばした。dotfiles-private の clone を用意する (bootstrap が clone する)",
                paths.dict_dir.display()
            ));
            dict = None;
        }
    }
    let records = Records::load_with(&paths.record(), "消してから流し直すと衝突として扱われます")
        .map_err(|e| {
        ctx.say(format!("!! {e}"));
        Outcome::new(Kind::Failed, "置いた記録が壊れている").note(e)
    })?;
    Ok(Prepared {
        paths,
        dict,
        dict_unused,
        records,
        notes,
    })
}

/// 外のコマンドの終わり方を文にする。
fn describe(exit: &Exit) -> String {
    match exit {
        Exit::Code(c) => format!("終了コード {c}"),
        Exit::NoCode => "終了コードが無い".to_string(),
        Exit::TimedOut => format!("{TASK_SECS} 秒たっても終わらなかった"),
        Exit::SpawnFailed(e) => format!("起こせなかった: {e}"),
    }
}

/// 設定画面・辞書ツール (GoogleIMEJaTool.exe) が開いているか (tasklist で見る)。確かめられなければ出す行を出して、締めの行を返す。
fn tool_open(ctx: &mut Ctx) -> Result<bool, Outcome> {
    let why = match ctx.sys.which("tasklist") {
        None => "tasklist が見つからない".to_string(),
        Some(tasklist) => {
            let spec = CommandSpec::new(tasklist)
                .arg("/FI")
                .arg(format!("IMAGENAME eq {TOOL}"))
                .arg("/FO")
                .arg("CSV")
                .arg("/NH")
                .timeout(Duration::from_secs(TASK_SECS));
            let r = ctx.sys.run(&spec, &mut |_| {});
            if r.exit == Exit::Code(0) {
                let needle = format!("\"{}\"", TOOL.to_ascii_lowercase());
                return Ok(r
                    .output
                    .iter()
                    .any(|l| l.to_ascii_lowercase().contains(&needle)));
            }
            ctx.say(format!(
                "!! tasklist を呼べませんでした ({})。Google 日本語入力の設定は置きません。",
                describe(&r.exit)
            ));
            for l in readable(&r.output) {
                ctx.say(format!("   {l}"));
            }
            describe(&r.exit)
        }
    };
    if why == "tasklist が見つからない" {
        ctx.say("!! tasklist が見つかりません。Google 日本語入力の設定は置きません。");
    }
    ctx.say(format!(
        "   設定画面か辞書ツール ({TOOL}) が開いているかを確かめられないと、閉じるときに古い中身で書き戻されうるためです。"
    ));
    Err(Outcome::new(
        Kind::Failed,
        format!("tasklist で設定画面が開いているかを確かめられない ({why})。何も置いていない"),
    ))
}

/// 人に見せる外のコマンドの行 (空の行を外す)。tasklist・taskkill は日本語の Windows ではコンソールの文字コード (CP932) で書き、UTF-8 として読むと
/// 化けるので、読めない字の混じる行は出さずに 1 行で知らせる
fn readable(lines: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut garbled = false;
    for l in lines {
        let l = l.trim_end_matches('\r');
        if l.trim().is_empty() {
            continue;
        }
        if l.contains('\u{fffd}') {
            garbled = true;
        } else {
            out.push(l.to_string());
        }
    }
    if garbled {
        out.push(
            "(UTF-8 で読めない行は出していない。PowerShell で同じコマンドを打つと読める)"
                .to_string(),
        );
    }
    out
}

/// 変換サーバーを落とした結果。
enum Killed {
    Done,
    /// 動いていなかった (taskkill の 128)
    NotRunning,
    /// 落とせなかった (わけと出力)
    Failed(String, Vec<String>),
}

/// `taskkill /F /IM GoogleIMEJaConverter.exe` (窓を持たないプロセスなので /F が要る)
fn kill_converter(ctx: &mut Ctx) -> Killed {
    let Some(taskkill) = ctx.sys.which("taskkill") else {
        return Killed::Failed("taskkill が見つからない".to_string(), Vec::new());
    };
    let spec = CommandSpec::new(taskkill)
        .arg("/F")
        .arg("/IM")
        .arg(CONVERTER)
        .timeout(Duration::from_secs(TASK_SECS));
    let r = ctx.sys.run(&spec, &mut |_| {});
    let why = match &r.exit {
        Exit::Code(0) => return Killed::Done,
        Exit::Code(128) => return Killed::NotRunning,
        Exit::Code(c) => format!("taskkill の終了コード {c}"),
        Exit::NoCode => "taskkill に終了コードが無い".to_string(),
        Exit::TimedOut => format!("taskkill が {TASK_SECS} 秒たっても終わらなかった"),
        Exit::SpawnFailed(e) => format!("taskkill を起こせなかった: {e}"),
    };
    Killed::Failed(why, readable(&r.output))
}

/// 取り込みのコマンド (受け持ちで替える)
fn import_command(ctx: &Ctx) -> String {
    if ctx.host.runner_enable {
        "dotfiles import google-ime".to_string()
    } else {
        "WSL で nix/scripts/bootstrap-windows-google-ime.sh --import (受け持ちが WSL の setup の間。runner の取り込みは止まる)".to_string()
    }
}

/// 辞書の語の diff を出すコマンド (check は受け持ちによらず流せる)
const SHOW_WORDS_COMMAND: &str = "dotfiles check --steps google-ime --show-words";

/// 1 ファイルの判定 (WSL の action)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Copy,
    Same,
    Update,
    Force,
    Conflict,
}

/// 締めの行の数。
#[derive(Default)]
struct Tally {
    copied: usize,
    updated: usize,
    same: usize,
    conflicts: usize,
    /// 辞書が衝突した (語の diff の出し方を添える)
    dictionary_conflict: bool,
    /// 置けなかった・記録を書けなかった
    errors: Vec<String>,
    /// 同じだが runner の記録がまだ無い (check と dry-run)
    unrecorded: usize,
    /// 前回は変換サーバーを落とせていない (check と dry-run は落とし直す予定)
    pending: bool,
    killed: Option<Killed>,
}

/// 辞書を扱ったか (締めの行の書き方と、行の種類を決める)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DictUse {
    /// 辞書も組み立てて置いた
    Used,
    /// 辞書のテキストが無いので飛ばした (⚠)
    Skipped,
    /// 辞書を扱わないホスト (privateRepos が off)
    Unused,
}

impl Tally {
    fn summary(&self, mode: Mode, dict: DictUse) -> String {
        let mut s = format!(
            "置く {} / 上書き {} / 同じ {} / 衝突 {}",
            self.copied, self.updated, self.same, self.conflicts
        );
        if !self.errors.is_empty() {
            s.push_str(&format!(" / エラー {}", self.errors.len()));
        }
        match dict {
            DictUse::Used => {}
            DictUse::Skipped => s.push_str(" (辞書は飛ばした)"),
            DictUse::Unused => s.push_str(" (辞書は扱わない)"),
        }
        match &self.killed {
            Some(Killed::Done) => s.push_str("。変換サーバーを落とした"),
            Some(Killed::NotRunning) => s.push_str("。変換サーバーは動いていなかった"),
            Some(Killed::Failed(..)) => s.push_str("。変換サーバーを落とせなかった"),
            None if self.pending && !mode.writes() => {
                s.push_str("。前回落とせなかった変換サーバーを落とし直す")
            }
            None => {}
        }
        if matches!(mode, Mode::DryRun { .. }) {
            s = format!("[dry-run] {s}");
        }
        s
    }

    fn kind(&self, mode: Mode, skipped_dict: bool) -> Kind {
        if !self.errors.is_empty() || matches!(self.killed, Some(Killed::Failed(..))) {
            Kind::Failed
        } else if self.conflicts > 0 || skipped_dict {
            Kind::Manual
        } else if mode.writes() {
            Kind::Ok
        } else if self.updated > 0 || self.pending {
            Kind::Fix
        } else if self.copied > 0 {
            Kind::Missing
        } else {
            Kind::Ok
        }
    }
}

/// Windows 側のファイルの digest (読めなければ Err)
fn windows_digest(kind: Db, path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    ime::digest(kind, &bytes, &path.display().to_string()).map_err(|e| e.0)
}

/// 置いた記録を書く (変わったときと、まだ無いとき。WSL は毎回 `jq -S .` で書き、値が無くても `{}` を置く)
fn save_records(records: &Records, path: &Path) -> std::io::Result<()> {
    records.save_if_changed()?;
    if !path.exists() {
        fsutil::write_atomic(path, b"{}\n")?;
    }
    Ok(())
}

/// 手順の中身。WSL の script と同じ順に確かめる (config.txtpb → 置き先 → 辞書のテキスト → 記録 → tasklist (apply) → 組み立て → ファイルごとの
/// 判定 → 置く → 記録 → 変換サーバー)。
fn sync(ctx: &mut Ctx, mode: Mode, show_words: bool) -> Outcome {
    let Prepared {
        paths,
        dict,
        dict_unused,
        mut records,
        notes,
    } = match prepare(ctx, false) {
        Ok(p) => p,
        Err(o) => return o,
    };
    let finish = |mut o: Outcome| {
        o.notes.extend(notes.iter().cloned());
        o
    };
    if mode.writes() {
        match tool_open(ctx) {
            Err(o) => return finish(o),
            Ok(true) => {
                ctx.say(format!(
                    "!! Google 日本語入力の設定画面か辞書ツール ({TOOL}) が開いています。閉じてから流し直してください。"
                ));
                ctx.say("   開いたまま置くと、閉じるときに古い中身で書き戻されることがあります。");
                return finish(
                    Outcome::new(
                        Kind::Manual,
                        format!(
                            "Google 日本語入力の設定画面か辞書ツール ({TOOL}) が開いているので、何も置いていない"
                        ),
                    )
                    .note("設定画面と辞書ツールを閉じてから流し直す"),
                );
            }
            Ok(false) => {}
        }
    }
    let built = match ime::build(&paths.config_dir, dict.as_deref()) {
        Ok(b) => b,
        Err(e) => {
            ctx.say(format!("!! {e}"));
            ctx.say("!! テキストを組み立てられませんでした (上のエラーの行を直してください)。何も置いていません。");
            return finish(
                Outcome::new(
                    Kind::Failed,
                    "テキストを組み立てられない (何も置いていない)",
                )
                .note(e.0),
            );
        }
    };
    let pre = if matches!(mode, Mode::DryRun { .. }) {
        "[dry-run] "
    } else {
        ""
    };
    // この回より前に置いて、まだ落とせていない (衝突の案内と、check・dry-run の予告に使う)
    let pending = paths.pending().exists();
    let mut tally = Tally {
        pending,
        ..Tally::default()
    };
    let mut backup = RunBackup::new(paths.backup(), KEEP_BACKUPS);
    let mut marked = false;
    let mut placed = 0;
    let mut kinds = vec![Db::Config];
    if dict.is_some() {
        kinds.push(Db::Dictionary);
    }
    for kind in kinds {
        let f = kind.file_name();
        let dst = paths.ime_dir.join(f);
        let bytes = match kind {
            Db::Config => &built.config,
            Db::Dictionary => built
                .dictionary
                .as_ref()
                .expect("辞書のディレクトリを渡した"),
        };
        let want = match ime::digest(kind, bytes, f) {
            Ok(d) => d,
            Err(e) => {
                ctx.say(format!("!! 組み立てた {f} を読み直せません: {e}"));
                tally.errors.push(format!("組み立てた {f} を読み直せない"));
                break;
            }
        };
        let recorded = records.get(f).unwrap_or_default().to_string();
        let action = if !dst.exists() {
            Action::Copy
        } else {
            match windows_digest(kind, &dst) {
                // 読めない (壊れている) ものは、記録と比べられないので衝突として扱う
                Err(_) if mode.force() => Action::Force,
                Err(_) => Action::Conflict,
                Ok(have) if have == want => Action::Same,
                Ok(have) if !recorded.is_empty() && have == recorded => Action::Update,
                Ok(_) if mode.force() => Action::Force,
                Ok(_) => Action::Conflict,
            }
        };
        match action {
            Action::Same => {
                ctx.say(format!("同じです: {}", dst.display()));
                tally.same += 1;
                if recorded != want {
                    if mode.writes() {
                        records.set(f, &want);
                    } else {
                        tally.unrecorded += 1;
                    }
                }
            }
            Action::Conflict => {
                tally.conflicts += 1;
                tally.dictionary_conflict |= kind == Db::Dictionary;
                report_conflict(ctx, kind, &dst, bytes, pending, show_words);
            }
            Action::Copy | Action::Update | Action::Force => {
                let label = match action {
                    Action::Copy => "置く",
                    Action::Update => "上書き (repo 側が進んだ)",
                    _ => "上書き (--force)",
                };
                if action == Action::Copy {
                    tally.copied += 1;
                } else {
                    tally.updated += 1;
                }
                match mode {
                    Mode::Check => ctx.say(format!("apply で{label}: {}", dst.display())),
                    Mode::DryRun { .. } => ctx.say(format!("{pre}{label}: {}", dst.display())),
                    Mode::Apply { .. } => {
                        if let Err(e) = place(&paths, &dst, bytes, &mut backup, &mut marked) {
                            ctx.say(format!("!! {} に置けませんでした ({e})。", dst.display()));
                            tally
                                .errors
                                .push(format!("{} に置けなかった ({e})", dst.display()));
                            break;
                        }
                        records.set(f, &want);
                        placed += 1;
                        ctx.say(format!("{label}: {}", dst.display()));
                    }
                }
            }
        }
    }

    if mode.writes()
        && let Err(e) = save_records(&records, &paths.record())
    {
        ctx.say(format!(
            "!! 置いた記録を書けません: {} ({e})",
            paths.record().display()
        ));
        tally.errors.push(format!(
            "置いた記録を書けない ({} ({e}))",
            paths.record().display()
        ));
    }
    if let Some(dir) = backup.dir() {
        ctx.say(format!(
            "置き換える前のファイルは {} に退避しました。",
            dir.display()
        ));
    }

    if !mode.writes() {
        if pending {
            match mode {
                Mode::Check => {
                    ctx.say("前回は変換サーバーを落とせていません (apply で落とし直します)。")
                }
                _ => ctx.say(format!(
                    "{pre}変換サーバーを落とし直します (前回落とせなかった)"
                )),
            }
        }
    } else if placed > 0 || pending {
        // 置いてから落とす。次のキー入力で Google 日本語入力が変換サーバーを起動し直し、置いた設定を読む。置くものが無くても印があれば落とし直す
        // (前回置いたものを、古い設定を持つサーバーが上書きしうる)
        if placed == 0 {
            ctx.say("前回は変換サーバーを落とせなかったので、落とし直します。");
        }
        let k = kill_converter(ctx);
        match &k {
            Killed::Done => {
                let _ = std::fs::remove_file(paths.pending());
                ctx.say(format!(
                    "変換サーバー ({CONVERTER}) を落としました。次のキー入力で起動し直し、置いた設定を読みます。"
                ));
                ctx.say("直接入力モードのキー (F13 → IMEOn など) を変えたときは、アプリを起動し直すと効きます。");
            }
            Killed::NotRunning => {
                let _ = std::fs::remove_file(paths.pending());
                ctx.say(
                    "変換サーバーは動いていませんでした。次に起動したときに置いた設定を読みます。",
                );
            }
            Killed::Failed(why, out) => {
                ctx.say(format!("!! 変換サーバーを落とせませんでした ({why}):"));
                for l in out {
                    ctx.say(format!("   {l}"));
                }
                ctx.say(format!(
                    "   設定画面を開く前に、タスクマネージャーで {CONVERTER} を終了するか、サインアウトしてください。"
                ));
                ctx.say("   次の apply でも落とし直します。");
            }
        }
        tally.killed = Some(k);
    } else if marked {
        // 印を作ったが 1 つも置けなかった (置く途中で落ちた): 落とし直すものは無いので印を外す
        let _ = std::fs::remove_file(paths.pending());
    }

    if tally.unrecorded > 0 {
        if ctx.host.runner_enable {
            ctx.say(format!(
                "置いた記録がまだ無いファイルが {} 件あります (apply で、今の中身を見て記録だけ作ります)。",
                tally.unrecorded
            ));
        } else {
            ctx.say(format!(
                "runner の記録はまだありません ({} 件。受け持ちを runner に切り替えた後の apply で、今の中身を見て記録だけ作ります。WSL の setup の記録は WSL の ~/.local/state/dotfiles/{STATE_REL}/{RECORD_FILE})。",
                tally.unrecorded
            ));
        }
    }

    let dict_use = match (&dict, dict_unused) {
        (Some(_), _) => DictUse::Used,
        (None, true) => DictUse::Unused,
        (None, false) => DictUse::Skipped,
    };
    let summary = tally.summary(mode, dict_use);
    ctx.say("");
    ctx.say(&summary);
    let mut outcome = Outcome::new(tally.kind(mode, dict_use == DictUse::Skipped), summary);
    if tally.conflicts > 0 {
        outcome = outcome.note(if ctx.host.runner_enable {
            format!(
                "衝突は上の出力の解き方で直す (Windows 側の中身をテキストへ取り込む ({}) か、{})",
                import_command(ctx),
                super::deploy::force_command(ctx, "google-ime")
            )
        } else {
            "受け持ちは WSL の setup (runner.enable が true でない)。runner の記録はまだ無いので、WSL が置いた中身とこの clone のテキストから組み立てた中身が違えば衝突と読む。clone (dotfiles と dotfiles-private) を同じ commit にそろえて見直す。衝突を解くのは WSL の側 (bootstrap-windows-google-ime.sh の --import か --force)".to_string()
        });
        if tally.dictionary_conflict && !show_words {
            outcome = outcome.note(format!(
                "辞書の衝突は、辞書ごとの行の数だけを出す。語の diff は自分の端末で {SHOW_WORDS_COMMAND} (Claude などのログに残る場所では流さない)"
            ));
        }
    }
    for e in &tally.errors {
        outcome = outcome.note(e.clone());
    }
    if let Some(Killed::Failed(..)) = &tally.killed {
        outcome = outcome.note(format!(
            "変換サーバー ({CONVERTER}) を落とせなかった。タスクマネージャーで終了するかサインアウトする (次の apply でも落とし直す)"
        ));
    }
    finish(outcome)
}

/// 置く: 置き先にあれば退避し、最初に置く前に落とし直しの印を作り、置き先と同じディレクトリの一時ファイルから置き換える (WSL の backup・
/// mark_restart_pending・place の順)。
fn place(
    paths: &Paths,
    dst: &Path,
    bytes: &[u8],
    backup: &mut RunBackup,
    marked: &mut bool,
) -> std::io::Result<()> {
    if dst.exists() {
        backup.copy(dst)?;
    }
    // 印は最初に置く直前に作る (置き終わってから書くと、その間に止まったときに印が残らず、次の回は「同じです」で落とさないまま終わる)
    if !*marked {
        std::fs::create_dir_all(&paths.state)?;
        std::fs::write(paths.pending(), b"")?;
        *marked = true;
    }
    fsutil::write_atomic(dst, bytes)
}

/// 衝突を出す (Windows 側と、組み立てたものをテキストに戻して比べる。辞書は `show_words` が無ければ辞書ごとの行の数だけ)。
fn report_conflict(
    ctx: &mut Ctx,
    kind: Db,
    dst: &Path,
    built: &[u8],
    pending: bool,
    show_words: bool,
) {
    ctx.say(format!(
        "!! 衝突: {} は Windows 側で変わっています (画面で変えたか、前回置いた記録が無い)。",
        dst.display()
    ));
    if pending {
        ctx.say("   前回は変換サーバーを落とせていません。この差は、古い設定が書き戻されたものかもしれません (repo 側を残すなら --force)。");
    }
    let have = std::fs::read(dst)
        .ok()
        .and_then(|b| ime::decode(kind, &b, &dst.display().to_string()).ok());
    let want = ime::decode(kind, built, kind.file_name()).ok();
    match (have, want) {
        (Some(ime::Decoded::Config(a)), Some(ime::Decoded::Config(b))) => {
            let side = |t: &ime::ConfigTexts| -> Vec<(String, String)> {
                [
                    (ime::TXTPB, Some(t.txtpb.clone())),
                    (ime::KEYMAP, t.keymap.clone()),
                    (ime::ROMAJI, t.romaji.clone()),
                ]
                .into_iter()
                .filter_map(|(n, s)| s.map(|s| (n.to_string(), s)))
                .collect()
            };
            show_text_diff(ctx, &side(&a), &side(&b));
        }
        (Some(ime::Decoded::Dictionaries(a)), Some(ime::Decoded::Dictionaries(b))) => {
            if show_words {
                let side = |m: &BTreeMap<String, String>| -> Vec<(String, String)> {
                    m.iter()
                        .map(|(n, s)| (format!("dictionaries/{n}.tsv"), s.clone()))
                        .collect()
                };
                show_text_diff(ctx, &side(&a), &side(&b));
            } else {
                show_dictionary_counts(ctx, &a, &b);
            }
        }
        _ => ctx.say("   (Windows 側のファイルを読めないので diff は出せません)"),
    }
    ctx.say(format!(
        "   Windows 側の変更を残すなら: {}",
        import_command(ctx)
    ));
    ctx.say(format!(
        "   repo 側で上書きするなら:   {}",
        super::deploy::force_command(ctx, "google-ime")
    ));
    ctx.say("   取り込みは repo のテキストを Windows 側の中身で置き換えます (diff の + の行は消えます)。両方を残すなら、テキストを手で直してから --force。");
}

/// 2 組のテキストの diff を `git diff --no-index` で出す (左が Windows 側、右が repo 側。一時ディレクトリの `Windows 側/`・`repo/` に書いて比べる)
fn show_text_diff(ctx: &mut Ctx, windows: &[(String, String)], repo: &[(String, String)]) {
    let Some(git) = ctx.sys.which("git") else {
        ctx.say("   (git が無いので diff は出さない)");
        return;
    };
    let root = match super::deploy::fresh_temp_dir() {
        Ok(r) => r,
        Err(e) => {
            ctx.say(format!(
                "   (一時ディレクトリを作れないので diff は出さない: {e})"
            ));
            return;
        }
    };
    let written = (|| -> std::io::Result<()> {
        for (side, files) in [("Windows 側", windows), ("repo", repo)] {
            let dir = root.join(side);
            std::fs::create_dir_all(&dir)?;
            for (name, text) in files {
                let p = join_segments(&dir, name);
                if let Some(parent) = p.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                std::fs::write(p, text)?;
            }
        }
        Ok(())
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_dir_all(&root);
        ctx.say(format!(
            "   (一時ファイルに書けないので diff は出さない: {e})"
        ));
        return;
    }
    let spec = CommandSpec::new(git)
        .arg("-c")
        .arg("core.quotePath=false")
        .arg("diff")
        .arg("--no-index")
        .arg("--no-color")
        .arg("--no-prefix")
        .arg("--")
        .arg("Windows 側")
        .arg("repo")
        .current_dir(&root)
        .timeout(Duration::from_secs(30));
    let sys = ctx.sys;
    let mut lines = Vec::new();
    sys.run(&spec, &mut |l| lines.push(format!("   {l}")));
    let _ = std::fs::remove_dir_all(&root);
    for l in lines {
        ctx.say(l);
    }
}

/// 行の多重集合として、`a` にあって `b` に無い行の数 (WSL の `comm -23` と同じ。並びは見ない)
fn count_only_in(a: &str, b: &str) -> usize {
    let mut counts: BTreeMap<&str, i64> = BTreeMap::new();
    for l in a.lines() {
        *counts.entry(l).or_default() += 1;
    }
    for l in b.lines() {
        *counts.entry(l).or_default() -= 1;
    }
    counts
        .values()
        .filter(|n| **n > 0)
        .map(|n| *n as usize)
        .sum()
}

/// 辞書の衝突の中身を、語を出さずに辞書ごとの行の数で出す (WSL の show_dictionary_counts。辞書の名前は TSV のファイル名で、語ではない)
fn show_dictionary_counts(
    ctx: &mut Ctx,
    windows: &BTreeMap<String, String>,
    repo: &BTreeMap<String, String>,
) {
    // ファイル名 (<名前>.tsv) のバイト列の順 (WSL の LC_ALL=C sort -u)
    let names: BTreeSet<String> = windows
        .keys()
        .chain(repo.keys())
        .map(|n| format!("{n}.tsv"))
        .collect();
    let mut shown = false;
    for file in names {
        let name = file.strip_suffix(".tsv").unwrap_or(&file);
        let lines = |t: &str| t.matches('\n').count();
        match (windows.get(name), repo.get(name)) {
            (Some(a), None) => ctx.say(format!(
                "   辞書「{name}」: Windows 側にだけある ({} 語)",
                lines(a)
            )),
            (None, Some(b)) => ctx.say(format!(
                "   辞書「{name}」: repo 側にだけある ({} 語)",
                lines(b)
            )),
            (Some(a), Some(b)) if a == b => continue,
            (Some(a), Some(b)) => {
                let only_windows = count_only_in(a, b);
                let only_repo = count_only_in(b, a);
                if only_windows == 0 && only_repo == 0 {
                    ctx.say(format!("   辞書「{name}」: 行は同じで、並びだけが違う"));
                } else {
                    ctx.say(format!(
                        "   辞書「{name}」: Windows 側にだけある行 {only_windows}・repo 側にだけある行 {only_repo}"
                    ));
                }
            }
            (None, None) => continue,
        }
        shown = true;
    }
    if !shown {
        ctx.say("   どの辞書も TSV に出る中身は同じです (TSV に出ない項目だけが違う)");
    }
    ctx.say(format!(
        "   語の diff は、自分の端末で {SHOW_WORDS_COMMAND} を打って見てください (Claude などのログに残る場所では流さない)。"
    ));
}

/// `dir` の `paths` (dir からの相対) に commit していない変更 (未追跡も) が無いかを確かめる (WSL の --import の前の確かめ)。止まるときは出す行を返す。
fn uncommitted(ctx: &Ctx, dir: &Path, paths: &[&str]) -> Result<(), Vec<String>> {
    let stop = "   取り込みはテキストを Windows 側の中身で置き換え、commit していない変更を消しうるので、止めます。";
    let Some(git) = ctx.sys.which("git") else {
        return Err(vec![
            format!(
                "!! {} に commit していない変更が無いかを確かめられません (git が無い)。",
                dir.display()
            ),
            stop.to_string(),
        ]);
    };
    let status = |extra: &[&str]| {
        let mut spec = CommandSpec::new(&git).arg("--no-optional-locks");
        for a in extra {
            spec = spec.arg(*a);
        }
        spec = spec.arg("-C").arg(dir.as_os_str()).arg("status");
        spec
    };
    let mut spec = status(&[])
        .arg("--porcelain")
        .arg("--untracked-files=normal")
        .arg("--");
    for p in paths {
        spec = spec.arg(*p);
    }
    // 変更の行は stdout だけから読む (stderr の warning を数えない)。確かめられないときの文には stderr も出す
    let mut all = Vec::new();
    let r = ctx.sys.run(
        &spec.timeout(Duration::from_secs(30)).stdout_only(),
        &mut |l| all.push(l.to_string()),
    );
    let lines: Vec<String> = r.output.iter().filter(|l| !l.is_empty()).cloned().collect();
    if r.code() != Some(0) {
        let mut out = vec![format!(
            "!! {} に commit していない変更が無いかを確かめられません (git が無いか、git の checkout ではない):",
            dir.display()
        )];
        out.extend(
            all.iter()
                .filter(|l| !l.is_empty())
                .map(|l| format!("   {l}")),
        );
        out.push(stop.to_string());
        return Err(out);
    }
    if lines.is_empty() {
        return Ok(());
    }
    let mut out = vec![format!(
        "!! {} に commit していない変更があります。取り込みはテキストを Windows 側の中身で置き換えるので、先に commit するか、変更を戻してから流し直してください。",
        dir.display()
    )];
    // 出すのはファイル名だけ (辞書の中身は出ない)
    let mut spec = status(&["-c", "core.quotePath=false"])
        .arg("--short")
        .arg("--untracked-files=normal")
        .arg("--");
    for p in paths {
        spec = spec.arg(*p);
    }
    let short = ctx.sys.run(
        &spec.timeout(Duration::from_secs(30)).stdout_only(),
        &mut |_| {},
    );
    out.extend(
        short
            .output
            .iter()
            .filter(|l| !l.is_empty())
            .map(|l| format!("   {l}")),
    );
    Err(out)
}

/// 取り込みで `dir` のテキストが変わったか (取り込む前に変更が無いことを確かめてあるので、今ある変更は取り込みが書いたもの)。git を呼べなければ
/// 変わった側に倒す (WSL の import_changed)
fn import_changed(ctx: &Ctx, dir: &Path, paths: &[&str]) -> bool {
    let Some(git) = ctx.sys.which("git") else {
        return true;
    };
    let mut spec = CommandSpec::new(git)
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(dir.as_os_str())
        .arg("status")
        .arg("--porcelain")
        .arg("--untracked-files=normal")
        .arg("--");
    for p in paths {
        spec = spec.arg(*p);
    }
    let r = ctx.sys.run(
        &spec.timeout(Duration::from_secs(30)).stdout_only(),
        &mut |_| {},
    );
    r.code() != Some(0) || r.output.iter().any(|l| !l.is_empty())
}

/// 取り込み (`dotfiles import google-ime`。WSL の `--import`): Windows 側の設定と辞書をテキストに戻して repo と dotfiles-private へ書き、記録を
/// 合わせる。Google 日本語入力のファイルには書かない (変換サーバーも落とさない)。
pub fn import(ctx: &mut Ctx) -> Outcome {
    let Prepared {
        paths,
        dict,
        mut records,
        notes,
        ..
    } = match prepare(ctx, true) {
        Ok(p) => p,
        Err(o) => return o,
    };
    let finish = |mut o: Outcome| {
        o.notes.extend(notes.iter().cloned());
        o
    };
    // 取り込みは repo のテキストを Windows 側の中身で置き換える。commit していない変更 (未追跡も) は痕跡なく消えるので、何も書かずに止まる
    let mut checks: Vec<(&Path, &[&str])> = vec![(&paths.config_dir, &WATCHED)];
    if let Some(d) = &dict {
        checks.push((d, &["."]));
    }
    for (dir, watched) in checks {
        if let Err(lines) = uncommitted(ctx, dir, watched) {
            for l in &lines {
                ctx.say(l);
            }
            return finish(
                Outcome::new(
                    Kind::Failed,
                    "取り込むテキストに commit していない変更があるか、確かめられないので取り込まない",
                )
                .note(lines[0].trim_start_matches("!! ").to_string()),
            );
        }
    }
    let plan = match ime::plan_import(&paths.ime_dir, &paths.config_dir, dict.as_deref()) {
        Ok(p) => p,
        Err(e) => {
            ctx.say(format!("!! {e}"));
            return finish(Outcome::new(Kind::Failed, "取り込めない (何も書いていない)").note(e.0));
        }
    };
    if let Some(n) = &plan.notice {
        ctx.say(n);
    }
    match ime::apply_ops(&plan.ops) {
        Ok(lines) if lines.is_empty() => ctx.say("テキストは今のままで同じです。"),
        Ok(lines) => {
            for l in &lines {
                ctx.say(l);
            }
        }
        Err((lines, e)) => {
            for l in &lines {
                ctx.say(l);
            }
            ctx.say(format!("!! {e}"));
            ctx.say("   途中まで書きました。git status で見て、戻すか、直してから流し直してください (記録は変えていません)。");
            return finish(
                Outcome::new(Kind::Failed, "取り込みの途中で書けなくなった (途中まで書いた)")
                    .note(e.0)
                    .note("書いたテキストを git status で見て、戻すか直してから流し直す (記録は変えていない)"),
            );
        }
    }
    // 記録は、取り込みで読んだときの digest (読み直さない。WSL は書いた後に読み直す)
    records.set(Db::Config.file_name(), &plan.config_digest);
    if let Some(d) = &plan.dictionary_digest {
        records.set(Db::Dictionary.file_name(), d);
    }
    if let Err(e) = save_records(&records, &paths.record()) {
        ctx.say(format!(
            "!! 置いた記録を書けません: {} ({e})",
            paths.record().display()
        ));
        return finish(
            Outcome::new(Kind::Failed, "置いた記録を書けない")
                .note(format!("{} ({e})", paths.record().display())),
        );
    }
    // commit を促すのは、取り込みでテキストが変わった repo だけ
    let dotfiles_changed = import_changed(ctx, &paths.config_dir, &WATCHED);
    let private_changed = dict
        .as_deref()
        .is_some_and(|d| import_changed(ctx, d, &["."]));
    let (line, note) = match (dotfiles_changed, private_changed) {
        (true, true) => (
            "取り込みました。git diff を見て、dotfiles と dotfiles-private の両方で commit してください (dotfiles-private の diff には辞書の語が出るので、自分の端末で見てください)。",
            Some(
                "dotfiles と dotfiles-private の git diff を見て commit して push する (dotfiles-private の diff は辞書の語が出るので自分の端末で見る)",
            ),
        ),
        (true, false) => (
            "取り込みました。git diff を見て、dotfiles で commit してください。",
            Some("dotfiles の git diff を見て commit して push する"),
        ),
        (false, true) => (
            "取り込みました。git diff を見て、dotfiles-private で commit してください (diff には辞書の語が出るので、自分の端末で見てください)。",
            Some(
                "dotfiles-private の git diff を見て commit して push する (diff は辞書の語が出るので自分の端末で見る)",
            ),
        ),
        (false, false) => (
            "取り込んでもテキストは変わらなかったので、取り込みの分で commit するものはありません。",
            None,
        ),
    };
    ctx.say(line);
    let mut o = Outcome::new(
        if notes.is_empty() {
            Kind::Ok
        } else {
            Kind::Manual
        },
        if note.is_some() {
            "Windows 側の設定と辞書をテキストへ取り込んだ"
        } else {
            "取り込んでもテキストは変わらなかった"
        },
    );
    if let Some(n) = note {
        o = o.note(n);
    }
    finish(o)
}
