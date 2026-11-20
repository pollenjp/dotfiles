//! terminal (order 99): `win/windows-terminal/managed.json` のキーだけを、Windows Terminal の settings.json へ書き足す。WSL の
//! `nix/scripts/bootstrap-windows-terminal.sh` を写したもの (持つキー・書く中身・書く先・判定・記録・退避・`--force`・`--import` をそろえる。
//! 受け持ちを runner に切り替えた後に、WSL の setup が書いたものを同じものとして引き継ぐため)。
//!
//! Windows Terminal の settings.json は Windows Terminal 自身も書き換え、PC ごとに違う profile の一覧も入るので、ファイルごとは配らない。
//! dotfiles が持つキーだけを managed.json に書き、そのキーだけを書き足す (dotfiles-private の docs/adr/018_win_terminal_settings_keys_*)。
//!
//! - 持つキー: managed.json の object を辿った先の、object でない値 1 つが 1 つ (配列は中を見ない)。`profiles.list` (PC ごとの profile の一覧) は
//!   持てない
//! - 書く先: Store 版の `%LOCALAPPDATA%\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json` (Preview と zip 版は見ない)
//! - 判定 (キーごと。値は jq と同じく比べる (`jv::jq_eq`)):
//!
//!   | settings.json | すること |
//!   | --- | --- |
//!   | managed.json と同じ値 | 何もしない (記録が無ければ記録だけする) |
//!   | 前回書いた値 (記録) と同じ | managed.json が更新された。書き換える |
//!   | 値が無く、記録も無い | 書き足す |
//!   | 途中が object でない | 書けない (manual) |
//!   | それ以外 | 衝突。両方の値を出して触らない (`--force` なら書く) |
//!
//! - 書くときは settings.json を `%LOCALAPPDATA%\dotfiles\state\windows-terminal\backup\<UTC の時刻>-<pid>\` へ写してから (新しい方から 10 回分)、
//!   jq の `--indent 4` と同じ形で書く (`jv`。WSL が書くバイト列と同じ)。Windows Terminal は settings.json を見張っていて、その場で読み直す
//! - 記録は `%LOCALAPPDATA%\dotfiles\state\windows-terminal.applied.json` (`{"version":1,"keys":{"<キーのパスの JSON>":<値>}}`。WSL の
//!   `~/.local/state/dotfiles/` の記録と同じ名前・形・鍵。キーの順に並べて 2 字下げ)。WSL の記録は読まない: 切り替えた後の初めての apply は、
//!   WSL が書いた値を「同じ」と見て記録だけ作る
//! - managed.json から消したキーは settings.json から消さない (記録からだけ消す)
//! - settings.json が無い (Windows Terminal を一度も起動していない)・JSON として読めない (コメントや末尾のカンマ) ときは、書かずに manual
//! - 取り込み (`dotfiles import terminal`。WSL の `--import`): 衝突したキーの値を settings.json から managed.json へ取り込む (settings.json には
//!   書かない。値が無ければ managed.json からキーを消し、空になった object も消す)。managed.json に commit していない変更があると止まる

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::jv::{self, Jv};
use crate::process::CommandSpec;
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// 持つキー (repo からの相対)
pub const MANAGED_REL: &str = "win/windows-terminal/managed.json";
/// Store 版の Windows Terminal の settings.json (`%LOCALAPPDATA%` からの相対。WSL の `settings_rel` の `AppData/Local/` の後ろ)
pub const SETTINGS_REL: &str =
    "Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json";
/// 記録のファイル名 (WSL の `~/.local/state/dotfiles/` の記録と同じ名前)
pub const RECORD_FILE: &str = "windows-terminal.applied.json";
/// 退避の置き場 (記録の置き場からの相対。WSL の `~/.local/state/dotfiles/windows-terminal/backup` と同じ並び)
const BACKUP_REL: &str = "windows-terminal/backup";
/// 退避を残す回数 (WSL の `keep_backups`)
const KEEP_BACKUPS: usize = 10;

pub struct Terminal;

impl Step for Terminal {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "terminal",
            order: 99,
            title: "Windows Terminal の settings.json に持つキーを書き足す",
            gate: Gate::Always,
            ported: true,
            windows_only: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode)]
    }
}

/// キーごとの判定。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Same,
    Update,
    Add,
    Conflict,
    Blocked,
}

/// 持つキー 1 つの計画。
#[derive(Clone, Debug)]
struct Entry {
    path: Vec<String>,
    /// 記録の鍵 (パスの配列の JSON)
    key: String,
    /// 表示用の名前 (profiles.defaults.bellSound)
    name: String,
    want: Jv,
    cur: Option<Jv>,
    rec: Option<Jv>,
    /// 途中にある、object でない値の名前
    blocked: Option<String>,
    action: Action,
}

/// 表示用の名前 (WSL の `show_path`: 英数字と `_` `-` だけの名前はそのまま、ほかは JSON の文字列。. でつなぐ)。jq の `test("^[A-Za-z0-9_-]+$")` の
/// `$` は末尾の改行 1 つの前でも合う (Perl と同じ)。
fn show_path(path: &[String]) -> String {
    path.iter()
        .map(|k| {
            let core = k.strip_suffix('\n').unwrap_or(k);
            if !core.is_empty()
                && core
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
            {
                k.clone()
            } else {
                jv::jq_string(k)
            }
        })
        .collect::<Vec<_>>()
        .join(".")
}

/// managed.json を読んで確かめる (WSL の `validate_managed` と同じ決まりと文)。誤りなら出す行を返す。
fn load_managed(path: &Path) -> Result<Jv, Vec<String>> {
    if !path.is_file() {
        return Err(vec![format!(
            "!! {MANAGED_REL} がありません ({})。",
            path.display()
        )]);
    }
    let parsed = std::fs::read_to_string(path)
        .map_err(|e| e.to_string())
        .and_then(|t| Jv::parse(&t));
    let doc = match parsed {
        Ok(v @ Jv::Object(_)) => v,
        Ok(_) => {
            return Err(vec![format!(
                "!! {MANAGED_REL} が JSON の object ではありません。"
            )]);
        }
        Err(e) => {
            return Err(vec![
                format!("!! {MANAGED_REL} が JSON の object ではありません。"),
                format!("   {e}"),
            ]);
        }
    };
    let mut problems = Vec::new();
    match doc.get("profiles") {
        Some(Jv::Array(_)) => problems.push(
            "profiles が配列です (profile の一覧の形)。持てるのは profiles.defaults だけです。"
                .to_string(),
        ),
        Some(p @ Jv::Object(_)) => {
            if p.get("list").is_some() {
                problems.push("profiles.list があります。profile の一覧は PC ごとに違うので持てません (全 profile に効かせるなら profiles.defaults に書く)。".to_string());
            }
            if p.get("defaults").is_some_and(|d| !d.is_object()) {
                problems.push("profiles.defaults が object ではありません。".to_string());
            }
        }
        _ => {}
    }
    if problems.is_empty() {
        Ok(doc)
    } else {
        let mut lines = vec![format!("!! {MANAGED_REL} に誤りがあります:")];
        lines.extend(problems.into_iter().map(|p| format!("   {p}")));
        Err(lines)
    }
}

/// 書いた記録 (`{"version":1,"keys":{…}}`。知らないキーも残す)。
struct Record {
    path: PathBuf,
    doc: Jv,
}

impl Record {
    /// 読む。無ければ空。`keys` を持つ object でなければ、出す行を返す (WSL と同じ文)。
    fn load(path: &Path) -> Result<Record, Vec<String>> {
        let doc = match std::fs::read_to_string(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Jv::parse(r#"{"version":1,"keys":{}}"#).expect("空の記録")
            }
            r => match r.map_err(|e| e.to_string()).and_then(|t| Jv::parse(&t)) {
                Ok(v) if v.get("keys").is_some_and(Jv::is_object) => v,
                _ => {
                    return Err(vec![
                        format!(
                            "!! {} が壊れています (keys を持つ JSON の object ではありません)。",
                            path.display()
                        ),
                        "   消してから流し直すと、settings.json に既にあって managed.json と違う値は衝突として扱われます".to_string(),
                        "   (値を確かめて、取り込むか --force)。".to_string(),
                    ]);
                }
            },
        };
        Ok(Record {
            path: path.to_path_buf(),
            doc,
        })
    }

    fn keys_mut(&mut self) -> &mut Jv {
        match &mut self.doc {
            Jv::Object(entries) => {
                &mut entries
                    .iter_mut()
                    .find(|(k, _)| k == "keys")
                    .expect("load が keys を確かめた")
                    .1
            }
            _ => unreachable!("load が object を確かめた"),
        }
    }

    fn get(&self, key: &str) -> Option<&Jv> {
        self.doc.get("keys").and_then(|k| k.get(key))
    }

    fn set(&mut self, key: &str, value: Jv) {
        self.keys_mut().set(key, value);
    }

    fn remove(&mut self, key: &str) {
        self.keys_mut().remove(key);
    }

    /// 持つキー (`keep` の鍵) のほかを記録から外す (managed.json から消したキー)
    fn retain(&mut self, keep: &[String]) {
        if let Jv::Object(entries) = self.keys_mut() {
            entries.retain(|(k, _)| keep.contains(k));
        }
    }

    /// `version` を 1 にして、キーの順に並べた 2 字下げの形 (WSL の `jq -S '.version = 1'`) が今のファイルと違えば書く (無ければ書く)。
    fn save_if_changed(&mut self) -> std::io::Result<bool> {
        self.doc.set("version", Jv::from(1));
        let new = format!("{}\n", self.doc.sorted().indent(2));
        let old = std::fs::read_to_string(&self.path)
            .ok()
            .and_then(|t| Jv::parse(&t).ok())
            .map(|v| format!("{}\n", v.sorted().indent(2)));
        if old.as_deref() == Some(new.as_str()) {
            return Ok(false);
        }
        fsutil::write_atomic(&self.path, new.as_bytes())?;
        Ok(true)
    }
}

/// settings.json を読んだ結果。
enum Settings {
    Missing,
    Unreadable(String),
    Doc(Jv),
}

fn read_settings(path: &Path) -> Settings {
    if !path.is_file() {
        return Settings::Missing;
    }
    match std::fs::read_to_string(path)
        .map_err(|e| e.to_string())
        .and_then(|t| Jv::parse(&t))
    {
        Ok(v @ Jv::Object(_)) => Settings::Doc(v),
        Ok(_) => Settings::Unreadable("JSON の object ではありません".to_string()),
        Err(e) => Settings::Unreadable(e),
    }
}

/// 持つキーごとの計画 (WSL の `plan` と同じ判定の順: 書けない → 同じ → 記録どおり → 無くて記録も無い → 衝突)。
fn plan(managed: &Jv, settings: &Jv, record: &Record) -> Vec<Entry> {
    managed
        .leaf_paths()
        .into_iter()
        .map(|path| {
            let want = managed.lookup(&path).cloned().unwrap_or(Jv::Null);
            let cur = settings.lookup(&path).cloned();
            let key = jv::tojson_path(&path);
            let rec = record.get(&key).cloned();
            let blocked = settings.blocked(&path).map(|i| show_path(&path[..i]));
            let action = if blocked.is_some() {
                Action::Blocked
            } else if cur.as_ref().is_some_and(|c| jv::jq_eq(c, &want)) {
                Action::Same
            } else if let (Some(c), Some(r)) = (&cur, &rec)
                && jv::jq_eq(c, r)
            {
                Action::Update
            } else if cur.is_none() && rec.is_none() {
                Action::Add
            } else {
                Action::Conflict
            };
            Entry {
                name: show_path(&path),
                path,
                key,
                want,
                cur,
                rec,
                blocked,
                action,
            }
        })
        .collect()
}

/// 取り込みのコマンド (受け持ちで替える。受け持ちが WSL の間は WSL の script の `--import`)
fn import_command(ctx: &Ctx) -> String {
    if ctx.host.runner_enable {
        "dotfiles import terminal".to_string()
    } else {
        "WSL で nix/scripts/bootstrap-windows-terminal.sh --import (受け持ちが WSL の setup の間。runner の取り込みは止まる)".to_string()
    }
}

/// --force のコマンド (受け持ちで替える)
fn force_command(ctx: &Ctx) -> String {
    super::deploy::force_command(ctx, "terminal")
}

/// 衝突したキーの、両方の値を出す (WSL の `report_conflict`)
fn report_conflict(ctx: &mut Ctx, e: &Entry) {
    if e.rec.is_none() {
        let before = if ctx.host.runner_enable {
            ""
        } else {
            "。受け持ちを切り替える前なら、WSL が書いた値とこの dotfiles の clone の managed.json が違う"
        };
        ctx.say(format!(
            "!! 衝突: {} は、書いた記録が無く、managed.json と値が違います (dotfiles が書く前から Windows 側にあった。設定画面で変えたもの、など{before})。",
            e.name
        ));
    } else if e.cur.is_some() {
        ctx.say(format!(
            "!! 衝突: {} は Windows 側で変わっています (前回書いた値と違う)。",
            e.name
        ));
    } else {
        ctx.say(format!(
            "!! 衝突: {} は Windows 側で消えています (設定画面で既定に戻した、など)。",
            e.name
        ));
    }
    let cur = e
        .cur
        .as_ref()
        .map(Jv::compact)
        .unwrap_or_else(|| "(無い)".to_string());
    ctx.say(format!("   Windows 側:   {cur}"));
    ctx.say(format!("   managed.json: {}", e.want.compact()));
}

/// 締めの行の数。
#[derive(Default)]
struct Tally {
    same: usize,
    add: usize,
    update: usize,
    conflicts: usize,
    blocked: usize,
    errors: usize,
}

impl Tally {
    fn summary(&self, mode: Mode, n: usize) -> String {
        let mut s = format!(
            "持つキー {n} 件: 同じ {} / 書き足す {} / 書き換える {} / 衝突 {}",
            self.same, self.add, self.update, self.conflicts
        );
        if self.blocked > 0 {
            s.push_str(&format!(" / 書けない {}", self.blocked));
        }
        if self.errors > 0 {
            s.push_str(&format!(" / エラー {}", self.errors));
        }
        if matches!(mode, Mode::DryRun { .. }) {
            s = format!("[dry-run] {s}");
        }
        s
    }

    fn kind(&self, mode: Mode) -> Kind {
        if self.errors > 0 {
            Kind::Failed
        } else if self.conflicts > 0 || self.blocked > 0 {
            Kind::Manual
        } else if mode.writes() {
            Kind::Ok
        } else if self.update > 0 {
            Kind::Fix
        } else if self.add > 0 {
            Kind::Missing
        } else {
            Kind::Ok
        }
    }
}

/// 手順の前半 (managed.json → settings.json → 記録)。止まるときは締めの行を返す。
fn prepare(ctx: &mut Ctx) -> Result<(Jv, PathBuf, Jv, Record), Outcome> {
    let managed_path = ctx.repo_path(MANAGED_REL);
    let managed = match load_managed(&managed_path) {
        Ok(m) => m,
        Err(lines) => {
            for l in &lines {
                ctx.say(l);
            }
            let mut o = Outcome::new(Kind::Failed, format!("{MANAGED_REL} に誤りがある"));
            o.notes = lines.iter().skip(1).map(|l| l.trim().to_string()).collect();
            return Err(o);
        }
    };
    let settings_path = join_segments(&ctx.roots.local_app_data, SETTINGS_REL);
    let settings = match read_settings(&settings_path) {
        Settings::Doc(d) => d,
        Settings::Missing => {
            ctx.say(format!(
                "!! Windows Terminal の settings.json がありません: {}",
                settings_path.display()
            ));
            ctx.say("   Windows Terminal (Store 版) を一度起動すると作られます。起動してから流し直してください。");
            ctx.say("   この手順は飛ばします。");
            return Err(Outcome::new(
                Kind::Manual,
                "Windows Terminal の settings.json が無い (一度も起動していない)",
            )
            .note("Windows Terminal (Store 版) を一度起動すると作られる。起動してから流し直す"));
        }
        Settings::Unreadable(e) => {
            ctx.say(format!(
                "!! Windows Terminal の settings.json を JSON として読めないので、書き足しません: {}",
                settings_path.display()
            ));
            ctx.say(format!("   {e}"));
            ctx.say("   コメントや末尾のカンマなど、JSON に無い書き方を消してから流し直してください (Windows Terminal は読めるが、dotfiles は読めない)。");
            return Err(Outcome::new(
                Kind::Manual,
                "Windows Terminal の settings.json を JSON として読めない (コメントや末尾のカンマ)",
            )
            .note(format!(
                "{} のコメントや末尾のカンマなど、JSON に無い書き方を消してから流し直す ({e})",
                settings_path.display()
            )));
        }
    };
    let record = match Record::load(&ctx.state_dir.join(RECORD_FILE)) {
        Ok(r) => r,
        Err(lines) => {
            for l in &lines {
                ctx.say(l);
            }
            let mut o = Outcome::new(Kind::Failed, "書いた記録が壊れている");
            o.notes = vec![lines.join(" ").trim_start_matches("!! ").to_string()];
            return Err(o);
        }
    };
    Ok((managed, settings_path, settings, record))
}

/// 記録から、managed.json から消したキーを外して書く (変わったときだけ)。
fn save_record(ctx: &mut Ctx, record: &mut Record, managed: &Jv) -> Result<(), Outcome> {
    let keep: Vec<String> = managed
        .leaf_paths()
        .iter()
        .map(|p| jv::tojson_path(p))
        .collect();
    record.retain(&keep);
    if let Err(e) = record.save_if_changed() {
        ctx.say(format!(
            "!! 書いた記録を書けません: {} ({e})",
            record.path.display()
        ));
        return Err(Outcome::new(Kind::Failed, "書いた記録を書けない")
            .note(format!("{} ({e})", record.path.display())));
    }
    Ok(())
}

/// 手順の中身。WSL の script と同じ順に確かめる (managed.json → settings.json → 記録 → キーごとの判定 → 書く → 記録)。
fn sync(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let (managed, settings_path, settings, mut record) = match prepare(ctx) {
        Ok(p) => p,
        Err(o) => return o,
    };
    let entries = plan(&managed, &settings, &record);
    let n = entries.len();
    let pre = if matches!(mode, Mode::DryRun { .. }) {
        "[dry-run] "
    } else {
        ""
    };
    let mut tally = Tally::default();
    let mut log = Vec::new();
    let mut writes: Vec<&Entry> = Vec::new();
    let mut conflicts = Vec::new();
    let mut blocked = Vec::new();
    let mut unrecorded = 0;
    for e in &entries {
        match e.action {
            Action::Same => {
                tally.same += 1;
                let recorded = e.rec.as_ref().is_some_and(|r| jv::jq_eq(r, &e.want));
                if !recorded {
                    if mode.writes() {
                        record.set(&e.key, e.want.clone());
                    } else {
                        unrecorded += 1;
                    }
                }
            }
            Action::Add | Action::Update => {
                let label = match (mode, e.action) {
                    (Mode::Check, Action::Add) => "無い (apply で書き足す)",
                    (Mode::Check, _) => "managed.json が更新された (apply で書き換える)",
                    (_, Action::Add) => "書き足す",
                    _ => "書き換える (managed.json が更新された)",
                };
                if e.action == Action::Add {
                    tally.add += 1;
                } else {
                    tally.update += 1;
                }
                writes.push(e);
                log.push(format!("  {pre}{}: {label}", e.name));
            }
            Action::Conflict if mode.force() => {
                tally.update += 1;
                writes.push(e);
                log.push(format!("  {pre}{}: 書き換える (--force)", e.name));
            }
            Action::Conflict => {
                tally.conflicts += 1;
                conflicts.push(e.name.clone());
                report_conflict(ctx, e);
            }
            Action::Blocked => {
                tally.blocked += 1;
                blocked.push(format!(
                    "{} (途中の {} が object ではない)",
                    e.name,
                    e.blocked.as_deref().unwrap_or("")
                ));
            }
        }
    }

    let mut backup_dir = None;
    if !writes.is_empty() && mode.writes() {
        match write_settings(ctx, &settings_path, &settings, &writes) {
            Ok(dir) => {
                backup_dir = Some(dir);
                for e in &writes {
                    record.set(&e.key, e.want.clone());
                }
            }
            Err(o) => return o,
        }
    }
    if mode.writes()
        && let Err(o) = save_record(ctx, &mut record, &managed)
    {
        return o;
    }

    if log.is_empty() && conflicts.is_empty() && blocked.is_empty() {
        ctx.say(format!(
            "Windows Terminal の設定は揃っています (持つキー {n} 件)。"
        ));
    }
    if !log.is_empty() {
        ctx.say(format!(
            "==> {pre}Windows Terminal の設定 ({})",
            settings_path.display()
        ));
        for l in &log {
            ctx.say(l);
        }
        if let Some(dir) = &backup_dir {
            ctx.say(format!(
                "  書き換える前の settings.json は {} に退避しました。",
                dir.display()
            ));
        }
        if mode.writes() {
            ctx.say("  Windows Terminal は settings.json を見張っていて、その場で読み直します。");
        }
    }
    if unrecorded > 0 {
        if ctx.host.runner_enable {
            ctx.say(format!(
                "書いた記録がまだ無いキーが {unrecorded} 件あります (apply で、今の値を見て記録だけ作ります)。"
            ));
        } else {
            ctx.say(format!(
                "runner の記録はまだありません ({unrecorded} 件。受け持ちを runner に切り替えた後の apply で、今の値を見て記録だけ作ります。WSL の setup の記録は WSL の ~/.local/state/dotfiles/{RECORD_FILE})。"
            ));
        }
    }
    let backup_root = ctx.state_dir.join(BACKUP_REL);
    if !conflicts.is_empty() {
        ctx.say(format!(
            "!! Windows 側で変わっていた (か、書く前からあった) ので、次のキーには触っていません (値は上): {}",
            conflicts.join("、")
        ));
        ctx.say(format!(
            "   Windows 側の値を残すなら (managed.json へ取り込み、commit して push する): {}",
            import_command(ctx)
        ));
        ctx.say(format!(
            "   managed.json の値で書くなら (元の settings.json は {} に退避する): {}",
            backup_root.display(),
            force_command(ctx)
        ));
    }
    if !blocked.is_empty() {
        ctx.say("!! settings.json の途中が object でないので、次のキーは書けません:");
        for b in &blocked {
            ctx.say(format!("   {b}"));
        }
        ctx.say("   Windows Terminal の設定画面で何か 1 つ変えて保存すると、profiles を object の形 (defaults と list) で書き直します。");
    }

    let summary = tally.summary(mode, n);
    ctx.say("");
    ctx.say(&summary);
    let mut outcome = Outcome::new(tally.kind(mode), summary);
    if !conflicts.is_empty() {
        outcome = outcome.note(if ctx.host.runner_enable {
            format!(
                "衝突は上の出力の解き方で直す (Windows 側の値を managed.json へ取り込む ({}) か、{})",
                import_command(ctx),
                force_command(ctx)
            )
        } else {
            "受け持ちは WSL の setup (runner.enable が true でない)。runner の記録はまだ無いので、WSL が書いた値とこの clone の managed.json が違うキーは衝突と読む。clone を同じ commit にそろえて見直す。衝突を解くのは WSL の側 (bootstrap-windows-terminal.sh の --import か --force)".to_string()
        });
    }
    if !blocked.is_empty() {
        outcome = outcome.note("Windows Terminal の設定画面で何か 1 つ変えて保存すると、profiles を object の形 (defaults と list) で書き直す");
    }
    outcome
}

/// settings.json を退避してから、書くキーを書いて jq の `--indent 4` の形で置く。退避したディレクトリを返す。
fn write_settings(
    ctx: &mut Ctx,
    settings_path: &Path,
    settings: &Jv,
    writes: &[&Entry],
) -> Result<PathBuf, Outcome> {
    let shown = settings_path.display().to_string();
    let backup_root = ctx.state_dir.join(BACKUP_REL);
    let dir = match fsutil::backup_run_dir(&backup_root, KEEP_BACKUPS)
        .and_then(|d| fsutil::copy_into(settings_path, &d).map(|_| d))
    {
        Ok(d) => d,
        Err(e) => {
            ctx.say(format!(
                "!! settings.json を退避できないので書きません: {} ({e})",
                backup_root.display()
            ));
            return Err(
                Outcome::new(Kind::Failed, "settings.json を退避できないので書いていない")
                    .note(format!("{} ({e})", backup_root.display())),
            );
        }
    };
    let mut doc = settings.clone();
    for e in writes {
        if let Err(why) = doc.set_path(&e.path, e.want.clone()) {
            ctx.say(format!("!! {} に書けません: {shown} ({why})", e.name));
            return Err(Outcome::new(Kind::Failed, format!("{} に書けない", e.name)).note(why));
        }
    }
    if let Err(e) = fsutil::write_atomic(settings_path, format!("{}\n", doc.indent(4)).as_bytes()) {
        ctx.say(format!("!! 書けません: {shown} ({e})"));
        return Err(Outcome::new(
            Kind::Failed,
            format!("Windows Terminal の settings.json を書けない ({e})"),
        ));
    }
    Ok(dir)
}

/// managed.json に commit していない変更 (未追跡も) が無いかを確かめる (取り込みは managed.json を書き換えるので、痕跡なく消さないよう止まる)。
/// git が無い・checkout の外で確かめられないときも止まる側に倒す。止まるときは出す行を返す。
pub fn uncommitted(ctx: &Ctx, rel: &str) -> Result<(), Vec<String>> {
    let Some(git) = ctx.sys.which("git") else {
        return Err(vec![
            format!("!! {rel} に commit していない変更が無いかを確かめられません (git が無い)。"),
            format!(
                "   取り込みは {rel} を書き換え、commit していない変更を消しうるので、止めます。"
            ),
        ]);
    };
    // --no-optional-locks は index を書かないため。--untracked-files=normal は、未追跡を見せない設定でも見るため
    let spec = CommandSpec::new(git)
        .arg("--no-optional-locks")
        .arg("-C")
        .arg(ctx.repo.as_os_str())
        .arg("status")
        .arg("--porcelain")
        .arg("--untracked-files=normal")
        .arg("--")
        .arg(rel)
        .timeout(Duration::from_secs(30));
    let r = ctx.sys.run(&spec, &mut |_| {});
    let lines: Vec<String> = r.output.iter().filter(|l| !l.is_empty()).cloned().collect();
    if r.code() != Some(0) {
        let mut out = vec![format!(
            "!! {rel} に commit していない変更が無いかを確かめられません (git が無いか、git の checkout ではない):"
        )];
        out.extend(lines.iter().map(|l| format!("   {l}")));
        out.push(format!(
            "   取り込みは {rel} を書き換え、commit していない変更を消しうるので、止めます。"
        ));
        return Err(out);
    }
    if !lines.is_empty() {
        let mut out = vec![format!(
            "!! {rel} に commit していない変更があります。取り込みは書き換えるので、先に commit するか、変更を戻してから流し直してください。"
        )];
        out.extend(lines.iter().map(|l| format!("   {l}")));
        return Err(out);
    }
    Ok(())
}

/// 取り込み (`dotfiles import terminal`。WSL の `--import`): 衝突したキーの値を settings.json から managed.json へ写す。settings.json には書かない。
pub fn import(ctx: &mut Ctx) -> Outcome {
    let (mut managed, _settings_path, settings, mut record) = match prepare(ctx) {
        Ok(p) => p,
        Err(o) => return o,
    };
    if let Err(lines) = uncommitted(ctx, MANAGED_REL) {
        for l in &lines {
            ctx.say(l);
        }
        let mut o = Outcome::new(
            Kind::Failed,
            format!(
                "{MANAGED_REL} に commit していない変更があるか、確かめられないので取り込まない"
            ),
        );
        o.notes = vec![lines[0].trim_start_matches("!! ").to_string()];
        return o;
    }
    let entries = plan(&managed, &settings, &record);
    let mut imports: Vec<&Entry> = Vec::new();
    let mut pending = Vec::new();
    let mut blocked = Vec::new();
    for e in &entries {
        match e.action {
            Action::Same => {
                if !e.rec.as_ref().is_some_and(|r| jv::jq_eq(r, &e.want)) {
                    record.set(&e.key, e.want.clone());
                }
            }
            Action::Add | Action::Update => pending.push(e.name.clone()),
            Action::Conflict => imports.push(e),
            Action::Blocked => blocked.push(format!(
                "{} (途中の {} が object ではない)",
                e.name,
                e.blocked.as_deref().unwrap_or("")
            )),
        }
    }
    let managed_path = ctx.repo_path(MANAGED_REL);
    if !imports.is_empty() {
        for e in &imports {
            match &e.cur {
                Some(c) => {
                    let _ = managed.set_path(&e.path, c.clone());
                }
                None => {
                    managed.del_path(&e.path);
                    managed.prune_empty(&e.path[..e.path.len() - 1]);
                }
            }
        }
        if let Err(err) =
            fsutil::write_atomic(&managed_path, format!("{}\n", managed.indent(4)).as_bytes())
        {
            ctx.say(format!(
                "!! {MANAGED_REL} に書けませんでした: {} ({err})",
                managed_path.display()
            ));
            return Outcome::new(Kind::Failed, format!("{MANAGED_REL} に書けない ({err})"));
        }
        for e in &imports {
            match &e.cur {
                Some(c) => record.set(&e.key, c.clone()),
                None => record.remove(&e.key),
            }
        }
    }
    if let Err(o) = save_record(ctx, &mut record, &managed) {
        return o;
    }
    let mut outcome = if imports.is_empty() {
        ctx.say("取り込むものはありません (衝突しているキーがありません)。");
        Outcome::new(Kind::Ok, "取り込むものは無い (衝突しているキーが無い)")
    } else {
        ctx.say(format!(
            "==> settings.json の値を {MANAGED_REL} へ取り込みました"
        ));
        for e in &imports {
            ctx.say(format!("  {}", e.name));
        }
        ctx.say(format!(
            "git -C {} diff -- {MANAGED_REL} で見て commit してください。",
            ctx.repo.display()
        ));
        Outcome::new(
            Kind::Ok,
            format!("{} 件を {MANAGED_REL} へ取り込んだ", imports.len()),
        )
        .note(format!(
            "git -C {} diff -- {MANAGED_REL} で見て commit して push する",
            ctx.repo.display()
        ))
    };
    if !pending.is_empty() {
        ctx.say(format!(
            "managed.json の値で settings.json へ書くキーが {} 件あります (取り込みでは書きません):",
            pending.len()
        ));
        for p in &pending {
            ctx.say(format!("  {p}"));
        }
        ctx.say("dotfiles apply --steps terminal で書きます。");
        outcome = outcome.note(format!(
            "managed.json の値で settings.json へ書くキーが {} 件ある → dotfiles apply --steps terminal で書く",
            pending.len()
        ));
    }
    if !blocked.is_empty() {
        ctx.say("!! settings.json の途中が object でないので、次のキーは書けません:");
        for b in &blocked {
            ctx.say(format!("   {b}"));
        }
        ctx.say("   Windows Terminal の設定画面で何か 1 つ変えて保存すると、profiles を object の形 (defaults と list) で書き直します。");
        outcome.kind = Kind::Manual;
        outcome = outcome.note("Windows Terminal の設定画面で何か 1 つ変えて保存すると、profiles を object の形 (defaults と list) で書き直す");
    }
    outcome
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (WSL の nix/tests/bootstrap-windows-terminal.test.sh と同じケースに、受け持ちで替える案内を足したもの)
    //!
    //! - settings.json が無い・JSON として読めないときは、書かずに manual
    //! - 値が無ければ書き足し (ほかのキーは値も順も変えない。jq の --indent 4 の形)、記録と退避を残す。同じ値なら settings.json に触らず記録だけする
    //! - managed.json を変えたら (settings.json が前回書いた値のまま) 書き換える
    //! - Windows 側で変わった・消えた・書く前から違う値があったときは衝突として触らず、両方の値と解き方を出す。衝突しないキーは書く。--force なら
    //!   退避してから書く
    //! - 取り込みは、衝突したキーの値を managed.json へ写し (値が無ければキーと空になった object を消す)、settings.json は変えない。managed.json に
    //!   commit していない変更があるとき・git の checkout でないときは止まる
    //! - check と dry-run は何も書かない (settings.json・記録・退避)
    //! - 名前に . を含むキー・配列・null を、それぞれ 1 つの値として扱う。数は十進の値で比べる (1 と 1.0 は同じ)
    //! - managed.json から消したキーは、settings.json からは消さず、記録からだけ消す
    //! - profiles.list を持とうとする managed.json は止まる。settings.json の途中が object でなくて書けないキーは manual
    //! - 退避は新しい方から 10 回分だけ残す。壊れた記録では止まる
    //! - Windows Terminal が文字列を 1 要素の配列へ書き直した PC と、配列にした managed.json
    //! - 受け持ちが WSL のホストでは、記録が無いことと衝突の解き方を WSL の側で出す
    //! - WSL の script (bash と jq) と同じ状態から流し、同じバイト列の settings.json・記録・取り込んだ managed.json を書く。WSL の script が書いた
    //!   settings.json を、記録の無い runner が変えずに引き継ぐ (bash・jq がある Linux)

    use super::*;
    use crate::hooks::parity;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::{Exit, RunResult};
    use crate::testutil::{FakeSys, TempDir};

    const RUNNER_HOST: &str = "[runner]\nenable = true\n";
    const WSL_HOST: &str = "group = \"personal\"\n";
    const APPLY: Mode = Mode::Apply { force: false };
    const SOUND: &str = r"C:\Windows\Media\Windows Information Bar.wav";
    const OTHER: &str = r"C:\Windows\Media\ding.wav";

    /// Windows Terminal が書く形の settings.json (bellSound は無い。WSL の試験の base_settings と同じ)
    const BASE: &str = r#"{
    "$help": "https://aka.ms/terminal-documentation",
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "actions":
    [
        {
            "command": "paste",
            "id": "User.paste"
        }
    ],
    "copyOnSelect": false,
    "keybindings":
    [
        {
            "id": null,
            "keys": "ctrl+v"
        }
    ],
    "profiles":
    {
        "defaults": {},
        "list":
        [
            {
                "guid": "{574e775e-4f2a-5b96-ac1e-a2962a402336}",
                "hidden": false,
                "name": "PowerShell",
                "source": "Windows.Terminal.PowershellCore"
            }
        ]
    },
    "schemes": []
}
"#;

    /// managed.json (jq --indent 4 の形)
    fn managed_of(v: &Jv) -> String {
        format!("{}\n", v.indent(4))
    }

    fn bell(v: Jv) -> String {
        let mut m = Jv::Object(Vec::new());
        m.set_path(
            &["profiles".into(), "defaults".into(), "bellSound".into()],
            v,
        )
        .unwrap();
        managed_of(&m)
    }

    struct Env {
        t: TempDir,
    }

    impl Env {
        /// managed.json は bellSound = SOUND、settings.json は BASE
        fn new() -> Self {
            let t = TempDir::new("terminal");
            let e = Env { t };
            e.set_managed(&bell(Jv::from(SOUND)));
            e.set_settings(BASE);
            e
        }

        fn repo(&self) -> PathBuf {
            self.t.path().join("repo")
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("win")
        }

        fn managed(&self) -> PathBuf {
            join_segments(&self.repo(), MANAGED_REL)
        }

        fn set_managed(&self, s: &str) {
            std::fs::create_dir_all(self.managed().parent().unwrap()).unwrap();
            std::fs::write(self.managed(), s).unwrap();
        }

        fn settings(&self) -> PathBuf {
            join_segments(&Roots::from_home(&self.home()).local_app_data, SETTINGS_REL)
        }

        fn set_settings(&self, s: &str) {
            std::fs::create_dir_all(self.settings().parent().unwrap()).unwrap();
            std::fs::write(self.settings(), s).unwrap();
        }

        fn read_settings(&self) -> String {
            std::fs::read_to_string(self.settings()).unwrap()
        }

        fn value(&self, path: &[&str]) -> Option<Jv> {
            let doc = Jv::parse(&self.read_settings()).unwrap();
            let p: Vec<String> = path.iter().map(|s| s.to_string()).collect();
            doc.lookup(&p).cloned()
        }

        fn bell(&self) -> Option<Jv> {
            self.value(&["profiles", "defaults", "bellSound"])
        }

        fn state(&self) -> PathBuf {
            self.t.path().join("state")
        }

        fn record(&self) -> PathBuf {
            self.state().join(RECORD_FILE)
        }

        fn recorded(&self) -> Option<Jv> {
            let text = std::fs::read_to_string(self.record()).ok()?;
            Jv::parse(&text)
                .unwrap()
                .get("keys")
                .unwrap()
                .get(r#"["profiles","defaults","bellSound"]"#)
                .cloned()
        }

        fn backups(&self) -> Vec<PathBuf> {
            let mut found: Vec<PathBuf> = std::fs::read_dir(self.state().join(BACKUP_REL))
                .map(|es| es.flatten().map(|e| e.path()).collect())
                .unwrap_or_default();
            found.sort();
            found
        }

        fn ctx_run<T>(
            &self,
            sys: &dyn crate::process::Sys,
            host: &str,
            f: impl FnOnce(&mut Ctx) -> T,
        ) -> (T, String) {
            let mut out = Vec::new();
            let r = {
                let mut ctx = Ctx {
                    repo: self.repo(),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.state(),
                    host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys,
                    out: &mut out,
                };
                f(&mut ctx)
            };
            (r, String::from_utf8(out).unwrap())
        }

        fn run(&self, host: &str, mode: Mode) -> (Outcome, String) {
            let sys = FakeSys::new(|_| unreachable!("terminal は外のコマンドを打たない"));
            let (mut outcomes, out) = self.ctx_run(&sys, host, |ctx| Terminal.run(ctx, mode));
            assert_eq!(outcomes.len(), 1, "{outcomes:?}\n{out}");
            (outcomes.remove(0), out)
        }

        fn apply(&self) -> (Outcome, String) {
            self.run(RUNNER_HOST, APPLY)
        }

        /// 取り込む。git status の答えは `status` (終了コードと出力の行)
        fn import(&self, status: (i32, Vec<&str>)) -> (Outcome, String) {
            let lines: Vec<String> = status.1.iter().map(|s| s.to_string()).collect();
            let sys = FakeSys::new(move |_| RunResult {
                exit: Exit::Code(status.0),
                output: lines.clone(),
            })
            .with_program("git", "/fake/git");
            self.ctx_run(&sys, RUNNER_HOST, import)
        }
    }

    #[test]
    fn missing_or_unreadable_settings_are_left_alone() {
        let e = Env::new();
        std::fs::remove_file(e.settings()).unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(out.contains("settings.json がありません"), "{out}");
        assert!(!e.settings().exists() && !e.record().exists());

        let commented = BASE.replace(
            "\"copyOnSelect\": false,",
            "// c\n    \"copyOnSelect\": false,",
        );
        e.set_settings(&commented);
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(out.contains("JSON として読めない"), "{out}");
        assert_eq!(e.read_settings(), commented);
        assert!(!e.record().exists() && e.backups().is_empty());
    }

    #[test]
    fn adds_then_stays_same() {
        let e = Env::new();
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(
            out.contains("profiles.defaults.bellSound: 無い (apply で書き足す)"),
            "{out}"
        );
        assert_eq!(e.read_settings(), BASE);

        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(
            o.text,
            "持つキー 1 件: 同じ 0 / 書き足す 1 / 書き換える 0 / 衝突 0"
        );
        assert!(
            out.contains("profiles.defaults.bellSound: 書き足す"),
            "{out}"
        );
        assert_eq!(e.bell(), Some(Jv::from(SOUND)));
        // ほかのキーは値も順も変えない (jq の --indent 4 の形に書き直す)
        let mut want = Jv::parse(BASE).unwrap();
        want.set_path(
            &["profiles".into(), "defaults".into(), "bellSound".into()],
            Jv::from(SOUND),
        )
        .unwrap();
        assert_eq!(e.read_settings(), format!("{}\n", want.indent(4)));
        assert_eq!(e.recorded(), Some(Jv::from(SOUND)));
        let backups = e.backups();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            std::fs::read_to_string(backups[0].join("settings.json")).unwrap(),
            BASE
        );
        assert_eq!(
            std::fs::read_to_string(e.record()).unwrap(),
            format!(
                "{{\n  \"keys\": {{\n    \"[\\\"profiles\\\",\\\"defaults\\\",\\\"bellSound\\\"]\": {}\n  }},\n  \"version\": 1\n}}\n",
                jv::jq_string(SOUND)
            )
        );

        let before = e.read_settings();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok);
        assert!(
            out.contains("Windows Terminal の設定は揃っています (持つキー 1 件)。"),
            "{out}"
        );
        assert_eq!(e.read_settings(), before);
        assert_eq!(e.backups().len(), 1);
    }

    #[test]
    fn same_value_only_records() {
        let e = Env::new();
        let mut doc = Jv::parse(BASE).unwrap();
        doc.set_path(
            &["profiles".into(), "defaults".into(), "bellSound".into()],
            Jv::from(SOUND),
        )
        .unwrap();
        let text = format!("{}\n", doc.indent(4));
        e.set_settings(&text);
        // 受け持ちが WSL の間の check は、記録がまだ無いことと、いつ作るかを出す
        let (o, out) = e.run(WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(out.contains("runner の記録はまだありません"), "{out}");
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains("書いた記録がまだ無いキーが 1 件あります"),
            "{out}"
        );
        assert!(!e.record().exists());
        let (o, _) = e.apply();
        assert_eq!(o.kind, Kind::Ok);
        assert_eq!(e.read_settings(), text);
        assert_eq!(e.recorded(), Some(Jv::from(SOUND)));
        assert!(e.backups().is_empty());
    }

    #[test]
    fn managed_update_rewrites() {
        let e = Env::new();
        e.apply();
        e.set_managed(&bell(Jv::from(OTHER)));
        let (o, out) = e.run(RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{out}");
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains("書き換える (managed.json が更新された)"),
            "{out}"
        );
        assert_eq!(e.bell(), Some(Jv::from(OTHER)));
        assert_eq!(e.recorded(), Some(Jv::from(OTHER)));
    }

    #[test]
    fn conflicts_are_left_alone_and_force_writes() {
        // Windows 側で変わった (記録はある)
        let e = Env::new();
        e.apply();
        let changed = e
            .read_settings()
            .replace(&jv::jq_string(SOUND), &jv::jq_string(OTHER));
        e.set_settings(&changed);
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("!! 衝突: profiles.defaults.bellSound は Windows 側で変わっています"),
            "{out}"
        );
        assert!(
            out.contains(&format!("   Windows 側:   {}", jv::jq_string(OTHER))),
            "{out}"
        );
        assert!(
            out.contains(&format!("   managed.json: {}", jv::jq_string(SOUND))),
            "{out}"
        );
        assert!(out.contains("dotfiles import terminal"), "{out}");
        assert!(
            out.contains("dotfiles apply --steps terminal --force"),
            "{out}"
        );
        assert_eq!(e.read_settings(), changed);
        assert_eq!(e.backups().len(), 1);
        // dry-run の --force は書き換えると出すが、書かない
        let (o, out) = e.run(RUNNER_HOST, Mode::DryRun { force: true });
        assert_eq!(o.kind, Kind::Fix, "{out}");
        assert!(
            out.contains("[dry-run] profiles.defaults.bellSound: 書き換える (--force)"),
            "{out}"
        );
        assert_eq!(e.read_settings(), changed);
        // --force は退避してから書く
        let (o, out) = e.run(RUNNER_HOST, Mode::Apply { force: true });
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.bell(), Some(Jv::from(SOUND)));
        let backups = e.backups();
        assert_eq!(backups.len(), 2);
        assert_eq!(
            std::fs::read_to_string(backups[1].join("settings.json")).unwrap(),
            changed
        );

        // 書く前から違う値がある (記録が無い)
        let e = Env::new();
        let mut doc = Jv::parse(BASE).unwrap();
        doc.set_path(
            &["profiles".into(), "defaults".into(), "bellSound".into()],
            Jv::from(OTHER),
        )
        .unwrap();
        e.set_settings(&doc.indent(4));
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("書いた記録が無く、managed.json と値が違います"),
            "{out}"
        );
        assert!(!out.contains("受け持ちを切り替える前なら"), "{out}");
        // 受け持ちが WSL の間は、WSL の側で解くと出す
        let (o, out) = e.run(WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual);
        assert!(
            out.contains("受け持ちを切り替える前なら、WSL が書いた値と"),
            "{out}"
        );
        assert!(
            out.contains("bootstrap-windows-terminal.sh --import"),
            "{out}"
        );
        assert!(
            out.contains("bootstrap-windows-terminal.sh --force"),
            "{out}"
        );
        assert!(
            o.notes[0].contains("衝突を解くのは WSL の側"),
            "{:?}",
            o.notes
        );

        // Windows 側で消えた (記録はある)
        let e = Env::new();
        e.apply();
        e.set_settings(BASE);
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(out.contains("Windows 側で消えています"), "{out}");
        assert!(out.contains("   Windows 側:   (無い)"), "{out}");
        assert_eq!(e.read_settings(), BASE);
    }

    #[test]
    fn check_and_dry_run_write_nothing() {
        let e = Env::new();
        for mode in [
            Mode::Check,
            Mode::DryRun { force: false },
            Mode::DryRun { force: true },
        ] {
            let (o, out) = e.run(RUNNER_HOST, mode);
            assert_eq!(o.kind, Kind::Missing, "{mode:?}: {out}");
            assert_eq!(e.read_settings(), BASE);
            assert!(!e.record().exists() && e.backups().is_empty());
        }
        let (o, out) = e.run(RUNNER_HOST, Mode::DryRun { force: false });
        assert!(o.text.starts_with("[dry-run] "), "{}", o.text);
        assert!(
            out.contains("==> [dry-run] Windows Terminal の設定"),
            "{out}"
        );
        assert!(
            out.contains("  [dry-run] profiles.defaults.bellSound: 書き足す"),
            "{out}"
        );
    }

    #[test]
    fn import_takes_windows_values() {
        // 衝突したキーの値を managed.json へ取り込み、settings.json は変えない
        let e = Env::new();
        e.apply();
        let changed = e
            .read_settings()
            .replace(&jv::jq_string(SOUND), &jv::jq_string(OTHER));
        e.set_settings(&changed);
        let (o, out) = e.import((0, vec![]));
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains(
                "==> settings.json の値を win/windows-terminal/managed.json へ取り込みました"
            ),
            "{out}"
        );
        assert_eq!(
            std::fs::read_to_string(e.managed()).unwrap(),
            bell(Jv::from(OTHER))
        );
        assert_eq!(e.read_settings(), changed);
        assert_eq!(e.recorded(), Some(Jv::from(OTHER)));
        let (o, _) = e.apply();
        assert_eq!(o.kind, Kind::Ok);
        assert_eq!(e.read_settings(), changed);

        // Windows 側で消えていたら、managed.json からキーと空になった object を消す
        let e = Env::new();
        e.set_managed(
            "{\n    \"copyOnSelect\": true,\n    \"profiles\": {\n        \"defaults\": {\n            \"bellSound\": \"x\"\n        }\n    }\n}\n",
        );
        let mut doc = Jv::parse(BASE).unwrap();
        doc.set_path(
            &["profiles".into(), "defaults".into(), "bellSound".into()],
            Jv::from("x"),
        )
        .unwrap();
        doc.set("copyOnSelect", Jv::from(true));
        e.set_settings(&doc.indent(4));
        e.apply();
        e.set_settings(
            BASE.replace("\"copyOnSelect\": false", "\"copyOnSelect\": true")
                .as_str(),
        );
        let (o, out) = e.import((0, vec![]));
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(
            std::fs::read_to_string(e.managed()).unwrap(),
            "{\n    \"copyOnSelect\": true\n}\n"
        );
        let rec = Jv::parse(&std::fs::read_to_string(e.record()).unwrap()).unwrap();
        assert_eq!(
            rec.get("keys").unwrap().compact(),
            r#"{"[\"copyOnSelect\"]":true}"#
        );

        // 衝突が無ければ取り込むものは無く、書くものがあれば apply を案内する
        let e = Env::new();
        let (o, out) = e.import((0, vec![]));
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(out.contains("取り込むものはありません"), "{out}");
        assert!(
            out.contains("settings.json へ書くキーが 1 件あります"),
            "{out}"
        );
        assert_eq!(e.read_settings(), BASE);
    }

    #[test]
    fn import_stops_on_uncommitted_or_no_git() {
        let e = Env::new();
        e.apply();
        e.set_settings(
            &e.read_settings()
                .replace(&jv::jq_string(SOUND), &jv::jq_string(OTHER)),
        );
        let managed = std::fs::read_to_string(e.managed()).unwrap();
        let (o, out) = e.import((0, vec![" M win/windows-terminal/managed.json"]));
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("commit していない変更があります"), "{out}");
        assert!(
            out.contains(" M win/windows-terminal/managed.json"),
            "{out}"
        );
        assert_eq!(std::fs::read_to_string(e.managed()).unwrap(), managed);
        let (o, out) = e.import((128, vec!["fatal: not a git repository"]));
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("git の checkout ではない"), "{out}");
        assert_eq!(std::fs::read_to_string(e.managed()).unwrap(), managed);
        // git が無い
        let sys = FakeSys::new(|_| unreachable!());
        let (o, out) = e.ctx_run(&sys, RUNNER_HOST, import);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(out.contains("(git が無い)"), "{out}");
    }

    #[test]
    fn dotted_keys_arrays_null_and_numbers() {
        let e = Env::new();
        e.set_managed(
            "{\n    \"compatibility.allowHeadless\": true,\n    \"newTabMenu\": [\n        {\n            \"type\": \"remainingProfiles\"\n        }\n    ],\n    \"initialCols\": 120,\n    \"profiles\": {\n        \"defaults\": {\n            \"tabColor\": null,\n            \"opacity\": 1.0\n        }\n    }\n}\n",
        );
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains("\"compatibility.allowHeadless\": 書き足す"),
            "{out}"
        );
        assert_eq!(
            e.value(&["compatibility.allowHeadless"]),
            Some(Jv::from(true))
        );
        assert!(e.value(&["compatibility"]).is_none());
        assert_eq!(
            e.value(&["newTabMenu"]).unwrap().compact(),
            r#"[{"type":"remainingProfiles"}]"#
        );
        assert_eq!(
            e.value(&["profiles", "defaults", "tabColor"]),
            Some(Jv::Null)
        );
        assert!(e.read_settings().contains("\"opacity\": 1.0\n"));
        // settings.json の 1 は 1.0 と同じ値 (jq と同じ)
        e.set_settings(
            &e.read_settings()
                .replace("\"opacity\": 1.0", "\"opacity\": 1"),
        );
        let before = e.read_settings();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(out.contains("揃っています (持つキー 5 件)"), "{out}");
        assert_eq!(e.read_settings(), before);
    }

    #[test]
    fn removed_managed_keys_stay_in_settings() {
        let e = Env::new();
        e.apply();
        let written = e.read_settings();
        e.set_managed("{}\n");
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.read_settings(), written);
        let rec = Jv::parse(&std::fs::read_to_string(e.record()).unwrap()).unwrap();
        assert_eq!(rec.compact(), r#"{"keys":{},"version":1}"#);
    }

    #[test]
    fn writes_unconflicted_keys_and_keeps_conflicted_ones() {
        let e = Env::new();
        e.set_managed(&format!(
            "{{\n    \"copyOnSelect\": true,\n    \"profiles\": {{\n        \"defaults\": {{\n            \"bellSound\": {}\n        }}\n    }}\n}}\n",
            jv::jq_string(SOUND)
        ));
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("!! 衝突: copyOnSelect は、書いた記録が無く"),
            "{out}"
        );
        assert_eq!(e.value(&["copyOnSelect"]), Some(Jv::from(false)));
        assert_eq!(e.bell(), Some(Jv::from(SOUND)));
        assert_eq!(
            o.text,
            "持つキー 2 件: 同じ 0 / 書き足す 1 / 書き換える 0 / 衝突 1"
        );
    }

    #[test]
    fn invalid_managed_stops() {
        let e = Env::new();
        for (managed, want) in [
            (
                "{\"profiles\": {\"list\": []}}\n",
                "profiles.list があります",
            ),
            ("{\"profiles\": []}\n", "profiles が配列です"),
            (
                "{\"profiles\": {\"defaults\": 1}}\n",
                "profiles.defaults が object ではありません",
            ),
            ("[1]\n", "JSON の object ではありません"),
            ("{\n", "JSON の object ではありません"),
        ] {
            e.set_managed(managed);
            let (o, out) = e.apply();
            assert_eq!(o.kind, Kind::Failed, "{managed}: {out}");
            assert!(out.contains(want), "{managed}: {out}");
            assert_eq!(e.read_settings(), BASE);
        }
        std::fs::remove_file(e.managed()).unwrap();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed);
        assert!(
            out.contains("win/windows-terminal/managed.json がありません"),
            "{out}"
        );
    }

    #[test]
    fn blocked_keys_are_manual() {
        let e = Env::new();
        e.set_settings(
            "{\n    \"profiles\": [\n        {\n            \"name\": \"x\"\n        }\n    ]\n}\n",
        );
        let before = e.read_settings();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains("profiles.defaults.bellSound (途中の profiles が object ではない)"),
            "{out}"
        );
        assert_eq!(e.read_settings(), before);
        assert!(o.text.ends_with(" / 書けない 1"), "{}", o.text);
    }

    #[test]
    fn keeps_ten_backups_and_stops_on_broken_record() {
        let e = Env::new();
        for i in 0..12 {
            e.set_managed(&bell(Jv::from(format!("C:\\s{i}.wav").as_str())));
            let (o, out) = e.run(RUNNER_HOST, Mode::Apply { force: true });
            assert_eq!(o.kind, Kind::Ok, "{out}");
        }
        assert_eq!(e.backups().len(), 10);
        std::fs::write(e.record(), "[]").unwrap();
        let before = e.read_settings();
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("が壊れています (keys を持つ JSON の object ではありません)"),
            "{out}"
        );
        assert_eq!(e.read_settings(), before);
    }

    /// Windows Terminal が保存で文字列を 1 要素の配列へ書き直すと、文字列の managed.json とは衝突する。managed.json を配列にすると、settings.json が
    /// 配列の PC は書かずに記録だけ配列に直し、settings.json が文字列のままの PC は配列で書き換える
    #[test]
    fn terminal_rewrites_strings_as_arrays() {
        let e = Env::new();
        e.apply();
        let saved = e.read_settings().replace(
            &format!(": {}", jv::jq_string(SOUND)),
            &format!(": [{}]", jv::jq_string(SOUND)),
        );
        e.set_settings(&saved);
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Manual, "{out}");
        e.set_managed(&bell(Jv::Array(vec![Jv::from(SOUND)])));
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.read_settings(), saved);
        assert_eq!(e.recorded(), Some(Jv::Array(vec![Jv::from(SOUND)])));

        let e = Env::new();
        e.apply();
        e.set_managed(&bell(Jv::Array(vec![Jv::from(SOUND)])));
        let (o, out) = e.apply();
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains("書き換える (managed.json が更新された)"),
            "{out}"
        );
        assert_eq!(e.bell(), Some(Jv::Array(vec![Jv::from(SOUND)])));
    }

    #[test]
    fn show_path_quotes_like_jq() {
        let p = |keys: &[&str]| keys.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            show_path(&p(&["profiles", "defaults", "bellSound"])),
            "profiles.defaults.bellSound"
        );
        assert_eq!(
            show_path(&p(&["compatibility.allowHeadless"])),
            "\"compatibility.allowHeadless\""
        );
        assert_eq!(show_path(&p(&["a b", "日"])), "\"a b\".\"日\"");
        assert_eq!(show_path(&p(&["", "x"])), "\"\".x");
        assert_eq!(show_path(&p(&["abc\n"])), "abc\n");
        assert_eq!(show_path(&p(&["x\ny"])), "\"x\\ny\"");
    }

    /// 順番・on/off・記録と退避の名前・書く先・持つキーの決まりが WSL の script と同じ (bash の版が流れない Windows の CI でも比べる)
    #[test]
    fn matches_the_wsl_script_text() {
        let text = std::fs::read_to_string(parity::repo_file(
            "nix/scripts/bootstrap-windows-terminal.sh",
        ))
        .unwrap()
        .replace("\r\n", "\n");
        let info = Terminal.info();
        assert!(
            text.lines()
                .any(|l| l == format!("# order: {}", info.order))
        );
        assert!(!text.lines().any(|l| l.starts_with("# tool: ")));
        assert_eq!(info.gate, Gate::Always);
        assert!(text.contains(&format!("managed_rel=\"{MANAGED_REL}\"")));
        assert!(text.contains(&format!("record_file=\"${{state_dir}}/{RECORD_FILE}\"")));
        assert!(text.contains(&format!("backup_root=\"${{state_dir}}/{BACKUP_REL}\"")));
        assert!(text.contains(&format!("keep_backups={KEEP_BACKUPS}\n")));
        assert!(text.contains(&format!("settings_rel=\"AppData/Local/{SETTINGS_REL}\"")));
        assert!(text.contains("jq --indent 4 --argjson w"));
        assert!(text.contains("new_records=$(jq -S '.version = 1' <<<\"${records}\")"));
        assert!(
            text.contains(
                r#"map(if test("^[A-Za-z0-9_-]+$") then . else tojson end) | join(".");"#
            )
        );
    }

    /// WSL の script を、使い捨ての HOME (`<root>/home`)・Windows のホーム (`<root>/win`)・checkout (`<root>/repo`) で流す (bash と jq と git)
    #[cfg(unix)]
    fn wsl_run(root: &Path, args: &[&str]) -> (i32, String) {
        let state = root.join("home/.local/state/dotfiles/windows-files.json");
        if !state.exists() {
            std::fs::create_dir_all(state.parent().unwrap()).unwrap();
            std::fs::write(
                &state,
                serde_json::json!({"enable": true, "version": 1, "windowsHome": root.join("win")})
                    .to_string(),
            )
            .unwrap();
        }
        let script = root.join("repo/nix/scripts/bootstrap-windows-terminal.sh");
        if !script.exists() {
            std::fs::create_dir_all(script.parent().unwrap()).unwrap();
            std::fs::copy(
                parity::repo_file("nix/scripts/bootstrap-windows-terminal.sh"),
                &script,
            )
            .unwrap();
        }
        let o = std::process::Command::new("bash")
            .arg(&script)
            .args(args)
            .env("HOME", root.join("home"))
            .env_remove("DOTFILES_SETUP_WARNINGS")
            .env("NO_COLOR", "1")
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        (
            o.status.code().unwrap_or(-1),
            format!(
                "{}{}",
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            ),
        )
    }

    #[cfg(unix)]
    fn wsl_record(root: &Path) -> PathBuf {
        root.join("home/.local/state/dotfiles").join(RECORD_FILE)
    }

    #[cfg(unix)]
    fn read(p: &Path) -> String {
        std::fs::read_to_string(p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
    }

    /// WSL の script (bash と jq) と同じ状態から流し、同じバイト列の settings.json と記録を書く (書き足す・同じ・managed.json の更新・衝突と --force・
    /// 消したキー・数の字と . を含むキー)。bash・jq が無ければ飛ばし、CI の Linux の job は飛ばさない
    #[cfg(unix)]
    #[test]
    fn writes_the_same_bytes_as_the_wsl_script() {
        if !parity::available() {
            return;
        }
        let wsl = Env::new();
        let ours = Env::new();
        let managed2 = "{\n    \"compatibility.allowHeadless\": true,\n    \"initialCols\": 120,\n    \"newTabMenu\": [\n        {\n            \"type\": \"remainingProfiles\"\n        }\n    ],\n    \"profiles\": {\n        \"defaults\": {\n            \"bellSound\": \"C:\\\\Windows\\\\Media\\\\ding.wav\",\n            \"opacity\": 85,\n            \"padding\": \"8, 8, 8, 8\",\n            \"tabColor\": null\n        }\n    }\n}\n";
        type Change = Box<dyn Fn(&Env)>;
        let steps: Vec<(&str, Change, Mode, i32)> = vec![
            ("書き足す", Box::new(|_| {}), APPLY, 0),
            ("同じ", Box::new(|_| {}), APPLY, 0),
            (
                "managed.json の更新",
                Box::new(|e: &Env| e.set_managed(&bell(Jv::from(OTHER)))),
                APPLY,
                0,
            ),
            (
                "いくつかのキー",
                Box::new(move |e: &Env| e.set_managed(managed2)),
                APPLY,
                0,
            ),
            (
                "Windows で変えた",
                Box::new(|e: &Env| {
                    e.set_settings(
                        &e.read_settings()
                            .replace("\"opacity\": 85", "\"opacity\": 1.50"),
                    )
                }),
                APPLY,
                1,
            ),
            ("--force", Box::new(|_| {}), Mode::Apply { force: true }, 0),
            (
                "キーを消した",
                Box::new(|e: &Env| e.set_managed("{\n    \"initialCols\": 120\n}\n")),
                APPLY,
                0,
            ),
        ];
        for (name, change, mode, code) in steps {
            change(&wsl);
            change(&ours);
            let args: &[&str] = if mode.force() { &["--force"] } else { &[] };
            let (c, out) = wsl_run(wsl.t.path(), args);
            assert_eq!(c, code, "{name}: {out}");
            let (o, out2) = ours.run(RUNNER_HOST, mode);
            assert_eq!(o.kind == Kind::Ok, code == 0, "{name}: {out2}");
            assert_eq!(ours.read_settings(), wsl.read_settings(), "{name}");
            assert_eq!(
                read(&ours.record()),
                read(&wsl_record(wsl.t.path())),
                "{name}"
            );
            assert_eq!(
                ours.backups().len(),
                std::fs::read_dir(
                    wsl.t
                        .path()
                        .join("home/.local/state/dotfiles")
                        .join(BACKUP_REL)
                )
                .map(|d| d.count())
                .unwrap_or(0),
                "{name}"
            );
        }
    }

    /// 取り込みも WSL の --import と同じバイト列の managed.json と記録を書く (git の checkout にした repo で、本物の git)
    #[cfg(unix)]
    #[test]
    fn imports_the_same_bytes_as_the_wsl_script() {
        if !parity::available() {
            return;
        }
        let git = |dir: &Path, args: &[&str]| {
            let o = std::process::Command::new("git")
                .arg("-C")
                .arg(dir)
                .args(args)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .output()
                .unwrap();
            assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
        };
        let managed = "{\n    \"copyOnSelect\": true,\n    \"profiles\": {\n        \"defaults\": {\n            \"bellSound\": \"x\"\n        }\n    }\n}\n";
        let mut envs = Vec::new();
        for _ in 0..2 {
            let e = Env::new();
            e.set_managed(managed);
            let mut doc = Jv::parse(BASE).unwrap();
            doc.set("copyOnSelect", Jv::from(true));
            doc.set_path(
                &["profiles".into(), "defaults".into(), "bellSound".into()],
                Jv::from("x"),
            )
            .unwrap();
            e.set_settings(&format!("{}\n", doc.indent(4)));
            envs.push(e);
        }
        let (wsl, ours) = (&envs[0], &envs[1]);
        let (c, out) = wsl_run(wsl.t.path(), &[]);
        assert_eq!(c, 0, "{out}");
        ours.apply();
        for e in [wsl, ours] {
            // Windows で値を変え、bellSound を消す
            let mut doc = Jv::parse(BASE).unwrap();
            doc.set("copyOnSelect", Jv::from(false));
            doc.set("newKey", Jv::from(1));
            e.set_settings(&format!("{}\n", doc.indent(4)));
            git(&e.repo(), &["init", "-q"]);
            git(&e.repo(), &["add", "win"]);
            git(
                &e.repo(),
                &[
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@example.invalid",
                    "commit",
                    "-q",
                    "-m",
                    "m",
                ],
            );
        }
        let (c, out) = wsl_run(wsl.t.path(), &["--import"]);
        assert_eq!(c, 0, "{out}");
        let (o, out) = ours.ctx_run(&crate::process::RealSys, RUNNER_HOST, import);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(read(&ours.managed()), read(&wsl.managed()));
        assert_eq!(read(&ours.managed()), "{\n    \"copyOnSelect\": false\n}\n");
        assert_eq!(read(&ours.record()), read(&wsl_record(wsl.t.path())));
        assert_eq!(ours.read_settings(), wsl.read_settings());
    }

    /// 受け持ちを切り替えた後の引き継ぎ: WSL の script が書いた settings.json を、記録の無い runner が自分のものとして読む (受け持ちが WSL の間の check
    /// は ✔、切り替えた後の apply は変えずに記録だけ作り、記録は WSL の記録と同じ)
    #[cfg(unix)]
    #[test]
    fn takes_over_what_the_wsl_script_wrote() {
        if !parity::available() {
            return;
        }
        let e = Env::new();
        let (c, out) = wsl_run(e.t.path(), &[]);
        assert_eq!(c, 0, "{out}");
        let written = e.read_settings();
        let (o, out) = e.run(WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(!e.record().exists());
        for _ in 0..2 {
            let (o, out) = e.apply();
            assert_eq!(o.kind, Kind::Ok, "{out}");
            assert_eq!(e.read_settings(), written);
        }
        assert!(e.backups().is_empty());
        assert_eq!(read(&e.record()), read(&wsl_record(e.t.path())));
    }
}
