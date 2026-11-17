//! herdr-app-keys (order 99): dotfiles の herdr-app のキー (`win/herdr-app/keys.json`) を、herdr-app の home の `keys.json` に書き足す。
//! herdr-app は Windows だけなので、WSL の setup に同じ手順は無い (Windows にしか無い手順)。
//!
//! - herdr-app の home は herdr-app-mods と同じ決め方 (`HERDR_APP_HOME` → `%XDG_CONFIG_HOME%\herdr-app` → `%USERPROFILE%\.config\herdr-app`)
//! - repo の keys.json は herdr-app の keys.json と同じ形 (section → { キー: action })。dotfiles が持つキーだけを書く
//! - herdr-app の keys.json のほかのキー・section と順は残し、dotfiles のキーだけを直す (順を保つ JSON の型 `ojson`)。無いキーは section の
//!   末尾に足し (section が無ければ末尾に作る)、同じ値なら記録だけ (手で書いた同じ値も引き取る)。違う値は、前に書いた値 (記録) のままなら
//!   書き換え、そうでなければ衝突として残して ⚠ で知らせる (`--force` で上書き)。repo から消えたキーは、今の値が記録どおりなら外す (空に
//!   なった section も外す)。書き換えてあれば残して知らせる。キーの順を見ずに同じなら書かない。改行の形 (herdr-app は Windows で CRLF) は前の
//!   中身に合わせる
//! - herdr-app の既定のキーを替えるときは、repo の `keys.defaults.json` (keys.json と同じ形) にその既定の値を書く。今の値がその値と同じキーは、
//!   衝突にせずに書き換えて記録する (逃げ道のキーで既定に戻されたときも)。repo から消したキーは、今の値が記録どおりなら、ここに値があれば外さずに
//!   その値へ戻す (外すと herdr-app のそのキーが無くなる)。既定でも dotfiles の値でもない値 (手で変えた値) は、今までどおり衝突
//! - keys.json が無ければ作らない。herdr-app は keys.json をキーの全部として読み、無ければ起きたときに既定を書く (dotfiles のキーだけの
//!   ファイルを作ると、既定のキーが無くなる)
//! - herdr-app は、手を入れていない keys.json だけを、版上げのときに新しい既定のキーへ替える。この手順が一度書くと、ファイルは丸ごとユーザーの
//!   ものになり、新しい既定のキーは手で足す (win/README.md の「herdr-app のキー」)
//! - 書く前の中身を `%LOCALAPPDATA%\dotfiles\state\herdr-app-keys\backup\` に写す (いちばん古いものと、新しい方から 10 個)。herdr-app は
//!   keys.json を見張っていて、保存するとすぐ読み直す (読めなければ前のキーのまま動き、隣の keys.error にわけを書く)。この手順は、書かなかった
//!   ときに keys.error を ※ で知らせる (書いたときの keys.error は前の中身のものなので、後の check で見るよう出す)
//!
//! 記録は `%LOCALAPPDATA%\dotfiles\state\herdr-app-keys.applied.json` (keys.json のパスごとに、書いたキーと値)。dotfiles-private の
//! docs/adr/070_win_herdr_app_keys_*。

use super::herdr_app_mods::app_home;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::ojson::OValue;
use crate::report::Kind;
use std::collections::BTreeMap;
use std::path::Path;

/// repo のキーの置き場 (`/` 区切り)。herdr-app の keys.json と同じ形 (section → { キー: action }) で、dotfiles が持つキーだけを書く
pub const KEYS: &str = "win/herdr-app/keys.json";
/// herdr-app の既定の値のうち、dotfiles が上書きしてよいもの (`/` 区切り。keys.json と同じ形)
pub const DEFAULTS: &str = "win/herdr-app/keys.defaults.json";
/// 書いたキーの記録 (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "herdr-app-keys.applied.json";
/// 書く前の keys.json を写す数 (いちばん古いものとは別に)
const BACKUPS: usize = 10;

/// dotfiles のキー: section ごとの (キー, action) の並び (repo の順)
pub type Wanted = Vec<(String, Vec<(String, OValue)>)>;
/// 記録の keys.json 1 つ分: section → キー → dotfiles が書いた action
type Written = BTreeMap<String, BTreeMap<String, serde_json::Value>>;

pub struct HerdrAppKeys;

impl Step for HerdrAppKeys {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "herdr-app-keys",
            // mod を置く herdr-app-mods (98) の後 (keys.json の Ctrl+K が mod の pjp-prefix を開く)
            order: 99,
            title: "dotfiles の herdr-app のキー (win/herdr-app/keys.json) を herdr-app の home の keys.json に書き足す",
            // herdr-app を入れる手順・herdr-app の mod と同じ switch
            gate: Gate::Tool("windowsHerdr"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let src = ctx.repo_path(KEYS);
        let (home, why) = app_home(ctx);
        let target = home.join("keys.json");
        let shown = target.display().to_string();
        ctx.say(format!("dotfiles: {}", src.display()));
        ctx.say(format!("herdr-app の home: {} ({why})", home.display()));
        let wanted = match load_wanted(&src) {
            Ok(w) => w,
            Err(e) => return failed(ctx, e),
        };
        let defaults = match load_defaults(&ctx.repo_path(DEFAULTS)) {
            Ok(d) => d,
            Err(e) => return failed(ctx, e),
        };
        let text = match std::fs::read_to_string(&target) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let why = format!(
                    "{shown} が無い (herdr-app をまだ起こしていない) → herdr-app を一度起こしてから dotfiles apply --steps herdr-app-keys (keys.json はキーの全部で、無ければ herdr-app が既定を書く。dotfiles のキーだけのファイルは作らない)"
                );
                ctx.say(format!("!! {why}"));
                return vec![Outcome::new(Kind::Manual, why)];
            }
            Err(e) => return failed(ctx, format!("{shown} が読めない ({e})")),
        };
        let doc = match OValue::parse(&text) {
            Ok(v @ OValue::Object(_)) => v,
            Ok(_) => {
                return failed(
                    ctx,
                    format!("{shown} が object でない (中身が {{…}} でない) → 手で直す"),
                );
            }
            Err(e) => {
                return failed(
                    ctx,
                    format!(
                        "{shown} が JSON として壊れている → 手で直す (herdr-app は前に読めたキーで動き、keys.error にわけを書く) ({e})"
                    ),
                );
            }
        };
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let mut notes = Vec::new();
        let (mut record, unreadable) = load_record(&record_path);
        if let Some(n) = unreadable.clone() {
            ctx.say(format!("!! {n}"));
            notes.push(n);
        }
        let original = record.clone();
        // 同じ keys.json を別の綴りで書いた記録も引く (HERDR_APP_HOME を / で書いた Windows など)
        let recorded_as = record
            .keys()
            .find(|k| path_key(Path::new(k)) == path_key(&target))
            .cloned();
        let written = recorded_as
            .as_ref()
            .and_then(|k| record.get(k))
            .cloned()
            .unwrap_or_default();
        let plan = match merge(&doc, &wanted, &defaults, &written, mode.force()) {
            Ok(p) => p,
            Err(e) => return failed(ctx, format!("{shown} の {e} → 手で直す")),
        };
        let writes = mode.writes() && plan.doc.to_value() != doc.to_value();
        if writes {
            let dir = ctx.state_dir.join("herdr-app-keys").join("backup");
            match fsutil::backup_copy(&target, &dir, "keys", BACKUPS) {
                Ok(copied) => ctx.say(format!("前の中身を写しました: {}", copied.display())),
                Err(e) => {
                    return failed(ctx, format!("{shown} を控えに写せないので書かない ({e})"));
                }
            }
            // 改行の形は前の中身に合わせる (herdr-app は Windows で CRLF で書く。JSON の文字列の中の改行は \n と書かれるので、
            // 置き換わるのは行の区切りだけ)
            let mut body = plan.doc.to_pretty();
            if text.contains("\r\n") {
                body = body.replace('\n', "\r\n");
            }
            if let Err(e) = fsutil::write_atomic(&target, body.as_bytes()) {
                return failed(ctx, format!("{shown} を書けない ({e})"));
            }
            ctx.say(format!(
                "書きました: {shown} (herdr-app はすぐ読み直す。読めたかは、少し後に dotfiles check --steps herdr-app-keys で見る (読めなければ keys.error を ※ で出す)。手を入れた keys.json は、herdr-app を上げても新しい既定のキーに替わらない。新しい既定のキーは手で足す)"
            ));
        }
        let mut tally = Tally::default();
        for c in &plan.changes {
            tally.count(ctx, c, mode);
        }
        if mode.writes() {
            if let Some(k) = recorded_as {
                record.remove(&k);
            }
            if !plan.written.is_empty() {
                record.insert(target.to_string_lossy().into_owned(), plan.written);
            }
            // 読めなかった記録は、書くキーが無くても直す (毎回は知らせない)
            if record != original || unreadable.is_some() {
                let body = serde_json::json!({ "version": 1, "files": record });
                let text = serde_json::to_string_pretty(&body).expect("記録はいつも JSON に書ける");
                if let Err(e) = fsutil::write_atomic(&record_path, format!("{text}\n").as_bytes()) {
                    tally.errors += 1;
                    ctx.say(format!(
                        "!! 記録を書けない: {} ({e})",
                        record_path.display()
                    ));
                }
            }
        }
        // 今書いたときの keys.error は前の中身のもの (herdr-app はこれから読み直す) なので、知らせない (上の「書きました」で check を勧める)
        if !writes && let Some(n) = keys_error(&home) {
            ctx.say(format!("!! {n}"));
            notes.push(n);
        }
        tally.finish(ctx, mode, notes)
    }
}

fn failed(ctx: &mut Ctx, why: String) -> Vec<Outcome> {
    ctx.say(format!("!! {why}"));
    vec![Outcome::new(Kind::Failed, why)]
}

/// dotfiles のキーを読む。中身は object の object で、action は文字列 (`name`・`name:値`・`send:<文字>`・`<mod>.<命令>`・`terminal`) か
/// object (`{ command, args }`)。
pub fn load_wanted(path: &Path) -> Result<Wanted, String> {
    let shown = path.display();
    let text = std::fs::read_to_string(path).map_err(|e| format!("{shown} が読めない ({e})"))?;
    let OValue::Object(sections) =
        OValue::parse(&text).map_err(|e| format!("{shown} が JSON として壊れている ({e})"))?
    else {
        return Err(format!("{shown} が object でない (中身が {{…}} でない)"));
    };
    sections
        .into_iter()
        .map(|(section, keys)| {
            let OValue::Object(entries) = keys else {
                return Err(format!("{shown} の {section} が object でない"));
            };
            if let Some((key, _)) = entries
                .iter()
                .find(|(_, a)| !matches!(a, OValue::String(_) | OValue::Object(_)))
            {
                return Err(format!(
                    "{shown} の {section} {key} の action が文字列でも object でもない"
                ));
            }
            Ok((section, entries))
        })
        .collect()
}

/// herdr-app の既定の値のうち、dotfiles が上書きしてよいもの (repo の `keys.defaults.json`。keys.json と同じ形で読む)。ファイルが無ければ空。
/// 今の値がここの値と同じキーは、衝突にせずに dotfiles の値へ書き換え、repo から消したキーは外さずにここの値へ戻す。
pub fn load_defaults(path: &Path) -> Result<Wanted, String> {
    match std::fs::metadata(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        _ => load_wanted(path),
    }
}

/// 記録 (`{"version":1,"files":{<keys.json のパス>:{<section>:{<キー>:<action>}}}}`) と、読めなかったときの知らせ。読めなければ空として
/// 進める (claude-skill-overrides と同じ。apply で直す)。
fn load_record(path: &Path) -> (BTreeMap<String, Written>, Option<String>) {
    let unreadable = |why: String| {
        format!(
            "記録が読めない: {} ({why})。無いものとして進める (repo から消したキーは外せない。今も書くキーはまた記録する)",
            path.display()
        )
    };
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return (BTreeMap::new(), None),
        Err(e) => return (BTreeMap::new(), Some(unreadable(e.to_string()))),
    };
    match serde_json::from_str::<serde_json::Value>(&text)
        .ok()
        .filter(|v| v.get("version") == Some(&serde_json::Value::from(1)))
        .and_then(|v| serde_json::from_value(v.get("files")?.clone()).ok())
    {
        Some(record) => (record, None),
        None => (BTreeMap::new(), Some(unreadable("形が違う".to_string()))),
    }
}

/// keys.json のパスを比べる鍵 (要素ごと。Windows は大文字小文字を区別しない)。要素に分けるので、`/` と `\`・重なった区切りの違いは消える
/// (herdr-app-mods と同じ)。
fn path_key(p: &Path) -> Vec<String> {
    p.components()
        .map(|c| {
            let s = c.as_os_str().to_string_lossy();
            if cfg!(windows) {
                s.to_lowercase()
            } else {
                s.into_owned()
            }
        })
        .collect()
}

/// herdr-app が keys.json を読めなかったときに書く keys.error の 1 行目 (※ で知らせる)。
fn keys_error(home: &Path) -> Option<String> {
    let path = home.join("keys.error");
    let text = std::fs::read_to_string(&path).ok()?;
    let first = text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim();
    Some(format!(
        "{} がある (herdr-app が keys.json を読めず、前に読めたキーで動いている): {first}。herdr-app status でも確かめる",
        path.display()
    ))
}

/// キー 1 つの扱い。
#[derive(Clone, Debug, PartialEq)]
enum Act {
    /// 無いので足す
    Add,
    /// 同じ値 (記録だけ)
    Same,
    /// dotfiles が前に書いた値 (記録どおり) から書き換える
    Update { from: OValue },
    /// herdr-app の既定の値 (keys.defaults.json どおり) から書き換える
    Replace { from: OValue },
    /// 違う値を --force で上書きする
    Force { from: OValue },
    /// 違う値を残す (`written`: dotfiles が書いた後に herdr-app の側で書き換えた。false は dotfiles が書いた値でない。`default`:
    /// keys.defaults.json の既定の値 (今の値はそれとも違う))
    Conflict {
        have: OValue,
        written: bool,
        default: Option<OValue>,
    },
    /// repo から消えたキーを外す (今の値が記録どおり)
    Remove { have: OValue },
    /// repo から消えたキーを、herdr-app の既定の値 (keys.defaults.json) に戻す (今の値が記録どおり)
    Restore { have: OValue, to: OValue },
    /// repo から消えたが、今の値が記録と違うので残す
    Kept {
        have: OValue,
        was: serde_json::Value,
    },
}

struct Change {
    section: String,
    key: String,
    want: Option<OValue>,
    act: Act,
}

/// 書き換えた keys.json・次の記録・キーごとの扱い。
struct Plan {
    doc: OValue,
    written: Written,
    changes: Vec<Change>,
}

/// keys.json に dotfiles のキーを入れる。`defaults` は herdr-app の既定の値のうち上書きしてよいもの (keys.defaults.json)。触る section が
/// object でない (null は無いものとして読む) なら、その名前を添えて誤り。
fn merge(
    doc: &OValue,
    wanted: &Wanted,
    defaults: &Wanted,
    written: &Written,
    force: bool,
) -> Result<Plan, String> {
    let default_of = |section: &str, key: &str| {
        defaults
            .iter()
            .find(|(s, _)| s == section)
            .and_then(|(_, ks)| ks.iter().find(|(k, _)| k == key))
            .map(|(_, v)| v.clone())
    };
    let mut out = doc.clone();
    let mut next: Written = BTreeMap::new();
    let mut changes = Vec::new();
    for (section, keys) in wanted {
        for (key, want) in keys {
            let was = written.get(section).and_then(|m| m.get(key));
            let default = default_of(section, key);
            let act = match entry(&out, section, key)? {
                None => Act::Add,
                Some(have) if have.to_value() == want.to_value() => Act::Same,
                Some(have) if was == Some(&have.to_value()) => Act::Update { from: have },
                // herdr-app の既定のまま (逃げ道のキーで既定に戻されたときも): 記録が無い・記録と違っても、衝突にしない
                Some(have)
                    if default
                        .as_ref()
                        .is_some_and(|d| d.to_value() == have.to_value()) =>
                {
                    Act::Replace { from: have }
                }
                Some(have) if force => Act::Force { from: have },
                Some(have) => Act::Conflict {
                    have,
                    written: was.is_some(),
                    default,
                },
            };
            if matches!(
                act,
                Act::Add | Act::Update { .. } | Act::Replace { .. } | Act::Force { .. }
            ) {
                put(&mut out, section, key, want.clone());
            }
            // 残した値は記録を変えない (前に書いた値があれば、その記録を持ち越す)
            let keep = match act {
                Act::Conflict { .. } => was.cloned(),
                _ => Some(want.to_value()),
            };
            if let Some(v) = keep {
                next.entry(section.clone())
                    .or_default()
                    .insert(key.clone(), v);
            }
            changes.push(Change {
                section: section.clone(),
                key: key.clone(),
                want: Some(want.clone()),
                act,
            });
        }
    }
    let wants = |section: &str, key: &str| {
        wanted
            .iter()
            .any(|(s, ks)| s == section && ks.iter().any(|(k, _)| k == key))
    };
    let mut emptied: Vec<&String> = Vec::new();
    for (section, keys) in written {
        for (key, was) in keys {
            if wants(section, key) {
                continue;
            }
            let act = match entry(&out, section, key)? {
                None => continue,
                // herdr-app の既定の値があれば、外さずに戻す (外すと herdr-app のそのキーが無くなる)
                Some(have) if have.to_value() == *was => match default_of(section, key) {
                    Some(to) => {
                        put(&mut out, section, key, to.clone());
                        Act::Restore { have, to }
                    }
                    None => {
                        take(&mut out, section, key);
                        if !emptied.contains(&section) {
                            emptied.push(section);
                        }
                        Act::Remove { have }
                    }
                },
                Some(have) => Act::Kept {
                    have,
                    was: was.clone(),
                },
            };
            changes.push(Change {
                section: section.clone(),
                key: key.clone(),
                want: None,
                act,
            });
        }
    }
    for section in emptied {
        if matches!(out.get(section), Some(OValue::Object(e)) if e.is_empty()) {
            out.remove(section);
        }
    }
    Ok(Plan {
        doc: out,
        written: next,
        changes,
    })
}

/// section の中のキーの値。section が無い・null なら None、object でなければ誤り。
fn entry(doc: &OValue, section: &str, key: &str) -> Result<Option<OValue>, String> {
    match doc.get(section) {
        None | Some(OValue::Null) => Ok(None),
        Some(s @ OValue::Object(_)) => Ok(s.get(key).cloned()),
        Some(_) => Err(format!("{section} が object でない")),
    }
}

/// section のキーに値を入れる (在ればその場所で替え、無ければ section の末尾に足す。section が無ければ末尾に作る)。
fn put(doc: &mut OValue, section: &str, key: &str, value: OValue) {
    let mut s = match doc.get(section) {
        Some(s @ OValue::Object(_)) => s.clone(),
        _ => OValue::Object(Vec::new()),
    };
    s.set(key, value);
    doc.set(section, s);
}

/// section のキーを外す。
fn take(doc: &mut OValue, section: &str, key: &str) {
    if let Some(s @ OValue::Object(_)) = doc.get(section) {
        let mut s = s.clone();
        s.remove(key);
        doc.set(section, s);
    }
}

/// 値を 1 行で出す (文字列はそのまま、ほかは JSON)
fn shown(v: &OValue) -> String {
    match v {
        OValue::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

fn shown_json(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// 数と、飛ばしたキー (衝突・外さなかったキー) の文。締めの行は herdr-app-mods (`linker`) と同じ形。
#[derive(Default)]
struct Tally {
    added: usize,
    updated: usize,
    removed: usize,
    same: usize,
    skipped: Vec<String>,
    errors: usize,
}

impl Tally {
    /// キー 1 つの扱いを数え、することを出す (check は「(apply で)」、dry-run は「[dry-run]」。apply は書いた後の言い方)。
    fn count(&mut self, ctx: &mut Ctx, c: &Change, mode: Mode) {
        let label = format!("{} {}", c.section, c.key);
        let want = c.want.as_ref().map(shown).unwrap_or_default();
        let say = |ctx: &mut Ctx, todo: &str, done: &str, rest: String| match mode {
            Mode::Check => ctx.say(format!("{todo} (apply で): {rest}")),
            Mode::DryRun { .. } => ctx.say(format!("[dry-run] {todo}: {rest}")),
            Mode::Apply { .. } => ctx.say(format!("{done}: {rest}")),
        };
        match &c.act {
            Act::Add => {
                self.added += 1;
                say(ctx, "足す", "足しました", format!("{label} = {want}"));
            }
            Act::Same => self.same += 1,
            Act::Update { from } => {
                self.updated += 1;
                say(
                    ctx,
                    "書き換える",
                    "書き換えました",
                    format!("{label} = {want} (前は {})", shown(from)),
                );
            }
            Act::Replace { from } => {
                self.updated += 1;
                say(
                    ctx,
                    "書き換える",
                    "書き換えました",
                    format!("{label} = {want} (前は herdr-app の既定 {})", shown(from)),
                );
            }
            Act::Force { from } => {
                self.updated += 1;
                say(
                    ctx,
                    "上書きする (--force)",
                    "上書きしました (--force)",
                    format!("{label} = {want} (前は {})", shown(from)),
                );
            }
            Act::Remove { have } => {
                self.removed += 1;
                say(
                    ctx,
                    "外す",
                    "外しました",
                    format!("{label} = {} (repo から消えた)", shown(have)),
                );
            }
            Act::Restore { have, to } => {
                self.removed += 1;
                say(
                    ctx,
                    "戻す",
                    "戻しました",
                    format!(
                        "{label} = {} (repo から消えた。herdr-app の既定に戻す。前は {})",
                        shown(to),
                        shown(have)
                    ),
                );
            }
            Act::Conflict {
                have,
                written,
                default,
            } => {
                let why = match (written, default) {
                    (true, _) => "herdr-app の側で書き換えた".to_string(),
                    (false, Some(d)) => format!(
                        "dotfiles が書いた値でも、herdr-app の既定 (keys.defaults.json の {}) でもない",
                        shown(d)
                    ),
                    (false, None) => {
                        "dotfiles が書いた値でない (herdr-app の既定・手で書いた値)".to_string()
                    }
                };
                let s = format!(
                    "{label} (keys.json は {}、dotfiles は {want}。{why} → 残すなら dotfiles の win/herdr-app/keys.json に取り込む。dotfiles の値にするなら dotfiles apply --steps herdr-app-keys --force)",
                    shown(have)
                );
                ctx.say(format!("!! 飛ばした: {s}"));
                self.skipped.push(s);
            }
            Act::Kept { have, was } => {
                let s = format!(
                    "{label} (repo から消えたが、keys.json の値 {} が dotfiles の書いた値 {} と違うので外さない。要らなければ手で消す)",
                    shown(have),
                    shown_json(was)
                );
                ctx.say(format!("!! 飛ばした: {s}"));
                self.skipped.push(s);
            }
        }
    }

    /// 締めの行 (`追加 n / 更新 n / 削除 n / 同じ n / 飛ばした n`) と、飛ばしたキーの ⚠ の行。
    fn finish(self, ctx: &mut Ctx, mode: Mode, notes: Vec<String>) -> Vec<Outcome> {
        let mut summary = format!(
            "追加 {} / 更新 {} / 削除 {} / 同じ {} / 飛ばした {}",
            self.added,
            self.updated,
            self.removed,
            self.same,
            self.skipped.len()
        );
        if self.errors > 0 {
            summary.push_str(&format!(" / エラー {}", self.errors));
        }
        if matches!(mode, Mode::DryRun { .. }) {
            summary = format!("[dry-run] {summary}");
        }
        ctx.say("");
        ctx.say(&summary);
        let kind = if self.errors > 0 {
            Kind::Failed
        } else if mode.writes() {
            Kind::Ok
        } else if self.updated + self.removed > 0 {
            Kind::Fix
        } else if self.added > 0 {
            Kind::Missing
        } else {
            Kind::Ok
        };
        let mut main = Outcome::new(kind, summary);
        main.notes = notes;
        let mut outcomes = vec![main];
        if !self.skipped.is_empty() {
            let mut o = Outcome::new(
                Kind::Manual,
                format!(
                    "飛ばした {} (dotfiles が書いた値でない・herdr-app の側で書き換えたキー) → ※ のキーを見て直す",
                    self.skipped.len()
                ),
            );
            o.notes = self.skipped;
            outcomes.push(o);
        }
        outcomes
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 無いキーを足す (check と dry-run は書かない): section の末尾に repo の順で足し、無い section は末尾に作る。ほかのキー・section と順、
    //!   制御文字の値 (`send:\u0017`)、改行の形 (CRLF・LF) はそのまま。書いたキーを記録し、2 回目は揃っている
    //! - 手で書いた同じ値は引き取る (書き換えず、記録だけ作る)。action が object なら、キーの順を見ずに比べる
    //! - 記録どおりの値は、repo を変えると書き換える。記録の無い違う値・herdr-app の側で書き換えた値は衝突 (残して ⚠。--force で上書き)
    //! - repo から消えたキーは、今の値が記録どおりなら外す (空になった section も外す)。書き換えてあれば残して ⚠
    //! - keys.defaults.json の herdr-app の既定の値は、衝突にせずに書き換える (既定に戻されたときも)。既定でも dotfiles の値でもない値は衝突
    //!   (文に既定の値を添える)。repo から消えたキーは、記録どおりなら既定の値に戻す (同じ場所で)。ファイルが無ければ空
    //! - keys.json が無ければ作らない (⚠。herdr-app を一度起こしてから)。壊れた keys.json・object でない section・壊れた repo のキーと既定の値は
    //!   failed (書かない)
    //! - 書く前の中身を控えに写す (いちばん古いものと、新しい方から 10 個)
    //! - 記録は keys.json のパスごと。同じ home を別の綴りで書いても同じ記録を引き、ほかの home の記録は残す。壊れた記録は無いものとして知らせ、
    //!   apply で直す (書くキーが無くても)。衝突したキーは apply でも残し、前に書いた値の記録を持ち越す
    //! - keys.error (herdr-app が keys.json を読めなかった) があれば ※ で知らせる。その apply で書いたときは、前の中身のものなので知らせず、
    //!   後で check で見るよう出す
    //! - 本物の repo のキー: prefix の mod を開くキーと、mod に渡す命令が、repo の mod (pjp-prefix) とそろっている。space は Ctrl+PageUp/Down
    //!   (herdr-app の既定のタブの移動を keys.defaults.json で上書きする) と Ctrl+Shift+↑↓・タブは Ctrl+↑↓ で、Ctrl+Alt+↑↓ は割り当てない。
    //!   Shift+G の argv が c の 3 か所 (fish・bash・PowerShell) と同じ引数

    use super::*;
    use crate::context::join_segments;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::ojson::OValue;
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    /// herdr-app が書く既定の keys.json の一部 (section と順・制御文字の値を残すかを見る)
    const DEFAULT: &str = r#"{
  "global": {
    "alt-1": "space.select:1",
    "ctrl-shift-t": "tab.new"
  },
  "terminal": {
    "ctrl-backspace": "send:\u0017",
    "ctrl-shift-c": "terminal.copy"
  }
}
"#;

    /// dotfiles のキー (repo の keys.json)
    const OURS: &str = r#"{
  "global": {
    "ctrl-k": "mod.open:pjp-prefix",
    "ctrl-up": "tab.prev"
  },
  "mod:pjp-prefix": {
    "ctrl-k": "pjp-prefix.literal"
  }
}
"#;

    const APPLY: Mode = Mode::Apply { force: false };

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("herdr-app-keys");
            t.write("dotfiles/win/herdr-app/keys.json", OURS);
            t.write("home/.config/herdr-app/keys.json", DEFAULT);
            Env { t }
        }

        /// 既定の home の下のパス
        fn home(&self, rel: &str) -> PathBuf {
            join_segments(
                &self.t.path().join("home"),
                &format!(".config/herdr-app/{rel}"),
            )
        }

        fn keys_text(&self) -> String {
            std::fs::read_to_string(self.home("keys.json")).unwrap()
        }

        /// herdr-app の keys.json の (section, [(キー, 値の JSON)]) の並び
        fn keys(&self) -> Vec<(String, Vec<(String, String)>)> {
            match OValue::parse(&self.keys_text()).unwrap() {
                OValue::Object(sections) => sections
                    .into_iter()
                    .map(|(s, v)| match v {
                        OValue::Object(entries) => (
                            s,
                            entries
                                .into_iter()
                                .map(|(k, v)| (k, serde_json::to_string(&v).unwrap()))
                                .collect(),
                        ),
                        other => panic!("{s} が object でない: {other:?}"),
                    })
                    .collect(),
                other => panic!("{other:?}"),
            }
        }

        fn record_text(&self) -> Option<String> {
            std::fs::read_to_string(self.t.path().join("state").join(RECORD_FILE)).ok()
        }

        /// 記録の中の、既定の home の keys.json の分 (section → キー → 値)
        fn recorded(&self) -> serde_json::Value {
            let v: serde_json::Value =
                serde_json::from_str(&self.record_text().expect("記録が無い")).unwrap();
            assert_eq!(v["version"], 1, "{v}");
            v["files"][&*self.home("keys.json").to_string_lossy()].clone()
        }

        fn backups(&self) -> Vec<String> {
            let dir = self
                .t
                .path()
                .join("state")
                .join("herdr-app-keys")
                .join("backup");
            let mut names: Vec<String> = std::fs::read_dir(dir)
                .map(|d| {
                    d.filter_map(|e| e.ok())
                        .map(|e| e.file_name().to_string_lossy().into_owned())
                        .collect()
                })
                .unwrap_or_default();
            names.sort();
            names
        }

        fn run_with(&self, mode: Mode, sys: FakeSys) -> (Vec<Outcome>, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys: &sys,
                    out: &mut out,
                };
                HerdrAppKeys.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }

        fn run(&self, mode: Mode) -> (Vec<Outcome>, String) {
            self.run_with(mode, FakeSys::new(|_| unreachable!("コマンドは打たない")))
        }
    }

    fn kinds(o: &[Outcome]) -> Vec<Kind> {
        o.iter().map(|x| x.kind).collect()
    }

    fn pairs(entries: &[(&str, &str)]) -> Vec<(String, String)> {
        entries
            .iter()
            .map(|(k, v)| (k.to_string(), format!("\"{v}\"")))
            .collect()
    }

    #[test]
    fn adds_keys_and_records() {
        let e = Env::new();
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (o, out) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Missing], "{mode:?} {o:?}\n{out}");
            assert_eq!(e.keys_text(), DEFAULT, "{mode:?} は書かない");
            assert!(e.record_text().is_none(), "{mode:?} は記録しない");
        }
        let (_, out) = e.run(Mode::Check);
        assert!(
            out.contains("足す (apply で): global ctrl-k = mod.open:pjp-prefix"),
            "{out}"
        );
        let (_, out) = e.run(Mode::DryRun { force: false });
        assert!(
            out.contains("[dry-run] 足す: mod:pjp-prefix ctrl-k = pjp-prefix.literal"),
            "{out}"
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("追加 3 / 更新 0 / 削除 0 / 同じ 0 / 飛ばした 0"),
            "{o:?}"
        );
        assert_eq!(
            e.keys(),
            vec![
                (
                    "global".to_string(),
                    pairs(&[
                        ("alt-1", "space.select:1"),
                        ("ctrl-shift-t", "tab.new"),
                        ("ctrl-k", "mod.open:pjp-prefix"),
                        ("ctrl-up", "tab.prev"),
                    ])
                ),
                (
                    "terminal".to_string(),
                    pairs(&[
                        ("ctrl-backspace", "send:\\u0017"),
                        ("ctrl-shift-c", "terminal.copy"),
                    ])
                ),
                (
                    "mod:pjp-prefix".to_string(),
                    pairs(&[("ctrl-k", "pjp-prefix.literal")])
                ),
            ]
        );
        // 制御文字は JSON の \u の形で書く (herdr-app の既定と同じ書き方)
        assert!(
            e.keys_text().contains(r#""send:\u0017""#),
            "{}",
            e.keys_text()
        );
        assert_eq!(
            e.recorded(),
            serde_json::json!({
                "global": { "ctrl-k": "mod.open:pjp-prefix", "ctrl-up": "tab.prev" },
                "mod:pjp-prefix": { "ctrl-k": "pjp-prefix.literal" },
            })
        );
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("同じ 3"), "{o:?}");
        let before = e.keys_text();
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert_eq!(e.keys_text(), before, "揃っていれば書かない");
        assert_eq!(e.backups().len(), 1, "書いたのは 1 回");
    }

    /// herdr-app は Windows で keys.json を CRLF で書く。改行の形はそのままにする (足したキーの外が差に出ないように)
    #[test]
    fn keeps_crlf_line_endings() {
        let e = Env::new();
        e.t.write(
            "home/.config/herdr-app/keys.json",
            &DEFAULT.replace('\n', "\r\n"),
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        let text = e.keys_text();
        assert!(text.ends_with("}\r\n"), "{text:?}");
        assert_eq!(
            text.matches('\n').count(),
            text.matches("\r\n").count(),
            "CR の無い改行がある: {text:?}"
        );
        assert!(
            text.contains("\"ctrl-k\": \"pjp-prefix.literal\"\r\n"),
            "{text:?}"
        );
        // LF のファイルは LF のまま (adds_keys_and_records と同じ)
        let e = Env::new();
        e.run(APPLY);
        assert!(!e.keys_text().contains('\r'));
    }

    /// 手で書いた同じ値は書き換えず、記録だけ作る。object の action はキーの順を見ずに比べる
    #[test]
    fn adopts_identical_keys() {
        let e = Env::new();
        e.t.write(
            "dotfiles/win/herdr-app/keys.json",
            r#"{ "global": { "ctrl-k": "mod.open:pjp-prefix", "ctrl-r": { "command": "layout.resize", "args": { "id": "sidebar", "px": 240 } } } }"#,
        );
        let mine = r#"{"global":{"ctrl-r":{"args":{"px":240,"id":"sidebar"},"command":"layout.resize"},"ctrl-k":"mod.open:pjp-prefix"}}"#;
        e.t.write("home/.config/herdr-app/keys.json", mine);
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("同じ 2"), "{o:?}");
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert_eq!(
            e.keys_text(),
            mine,
            "書き換えない (herdr-app が読み直さない)"
        );
        assert!(e.backups().is_empty());
        assert_eq!(
            e.recorded(),
            serde_json::json!({ "global": {
                "ctrl-k": "mod.open:pjp-prefix",
                "ctrl-r": { "command": "layout.resize", "args": { "id": "sidebar", "px": 240 } },
            } })
        );
    }

    #[test]
    fn updates_keys_it_wrote() {
        let e = Env::new();
        e.run(APPLY);
        e.t.write(
            "dotfiles/win/herdr-app/keys.json",
            &OURS.replace("\"tab.prev\"", "\"tab.next\""),
        );
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains("書き換える (apply で): global ctrl-up = tab.next (前は tab.prev)"),
            "{out}"
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.starts_with("追加 0 / 更新 1 /"), "{o:?}");
        let global = &e.keys()[0].1;
        assert_eq!(
            global[3],
            ("ctrl-up".to_string(), "\"tab.next\"".to_string()),
            "同じ場所で書き換える"
        );
        assert_eq!(e.recorded()["global"]["ctrl-up"], "tab.next");
    }

    #[test]
    fn conflicting_keys_are_kept() {
        let e = Env::new();
        // 記録の無い違う値 (herdr-app の新しい既定・手で書いた値)
        e.t.write(
            "home/.config/herdr-app/keys.json",
            &DEFAULT.replace(
                "\"ctrl-shift-t\": \"tab.new\"",
                "\"ctrl-shift-t\": \"tab.new\",\n    \"ctrl-up\": \"pane.go:up\"",
            ),
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("追加 2 / 更新 0 / 削除 0 / 同じ 0 / 飛ばした 1"),
            "{o:?}"
        );
        assert!(
            o[1].notes.iter().any(|n| n.starts_with(
                "global ctrl-up (keys.json は pane.go:up、dotfiles は tab.prev。dotfiles が書いた値でない"
            ) && n.contains("dotfiles の win/herdr-app/keys.json")
                && n.contains("--steps herdr-app-keys --force")),
            "{o:?}"
        );
        assert!(
            e.keys()[0]
                .1
                .contains(&("ctrl-up".to_string(), "\"pane.go:up\"".to_string())),
            "残す"
        );
        assert!(
            e.recorded()["global"].get("ctrl-up").is_none(),
            "衝突したキーは記録しない: {}",
            e.recorded()
        );
        // --force は dry-run では予告だけ、apply で上書きする
        let (o, out) = e.run(Mode::DryRun { force: true });
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains(
                "[dry-run] 上書きする (--force): global ctrl-up = tab.prev (前は pane.go:up)"
            ),
            "{out}"
        );
        let (o, out) = e.run(Mode::Apply { force: true });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("更新 1"), "{o:?}");
        assert_eq!(e.recorded()["global"]["ctrl-up"], "tab.prev");
        // 書いた後に herdr-app の側で書き換えた値も衝突
        let text = e.keys_text().replace(
            "\"ctrl-k\": \"mod.open:pjp-prefix\"",
            "\"ctrl-k\": \"terminal\"",
        );
        std::fs::write(e.home("keys.json"), text).unwrap();
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes.iter().any(|n| n.starts_with(
                "global ctrl-k (keys.json は terminal、dotfiles は mod.open:pjp-prefix。herdr-app の側で書き換えた"
            )),
            "{o:?}"
        );
        // apply でも残し、前に書いた値の記録を持ち越す (次も「書き換えた」と知らせ、値を戻せば dotfiles の値として扱う)
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            e.keys()[0]
                .1
                .contains(&("ctrl-k".to_string(), "\"terminal\"".to_string()))
        );
        assert_eq!(e.recorded()["global"]["ctrl-k"], "mod.open:pjp-prefix");
    }

    #[test]
    fn removes_keys_gone_from_the_repo() {
        let e = Env::new();
        e.run(APPLY);
        e.t.write(
            "dotfiles/win/herdr-app/keys.json",
            r#"{ "global": { "ctrl-k": "mod.open:pjp-prefix" } }"#,
        );
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains("外す (apply で): global ctrl-up = tab.prev (repo から消えた)"),
            "{out}"
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 2"), "{o:?}");
        let keys = e.keys();
        assert_eq!(
            keys.iter().map(|(s, _)| s.as_str()).collect::<Vec<_>>(),
            vec!["global", "terminal"],
            "空になった section も外す"
        );
        assert_eq!(
            keys[0].1,
            pairs(&[
                ("alt-1", "space.select:1"),
                ("ctrl-shift-t", "tab.new"),
                ("ctrl-k", "mod.open:pjp-prefix"),
            ])
        );
        assert_eq!(
            e.recorded(),
            serde_json::json!({ "global": { "ctrl-k": "mod.open:pjp-prefix" } })
        );
        // 書き換えてあれば外さずに知らせ、記録からは外す
        let text = e.keys_text().replace(
            "\"ctrl-k\": \"mod.open:pjp-prefix\"",
            "\"ctrl-k\": \"mod.open:picker\"",
        );
        std::fs::write(e.home("keys.json"), text).unwrap();
        e.t.write("dotfiles/win/herdr-app/keys.json", "{}");
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes.iter().any(|n| n.starts_with(
                "global ctrl-k (repo から消えたが、keys.json の値 mod.open:picker が dotfiles の書いた値 mod.open:pjp-prefix と違うので外さない"
            )),
            "{o:?}"
        );
        assert!(
            e.keys()[0]
                .1
                .contains(&("ctrl-k".to_string(), "\"mod.open:picker\"".to_string()))
        );
        let rec: serde_json::Value = serde_json::from_str(&e.record_text().unwrap()).unwrap();
        assert_eq!(rec["files"], serde_json::json!({}), "{rec}");
    }

    /// herdr-app の既定の ctrl-pageup (tab.prev) を入れた keys.json と、それを space.prev に替える repo のキー・既定の値
    fn with_pageup_default(e: &Env) {
        e.t.write(
            "home/.config/herdr-app/keys.json",
            &DEFAULT.replace(
                "\"ctrl-shift-t\": \"tab.new\"",
                "\"ctrl-pageup\": \"tab.prev\",\n    \"ctrl-shift-t\": \"tab.new\"",
            ),
        );
        e.t.write(
            "dotfiles/win/herdr-app/keys.json",
            r#"{ "global": { "ctrl-k": "mod.open:pjp-prefix", "ctrl-pageup": "space.prev" } }"#,
        );
        e.t.write(
            "dotfiles/win/herdr-app/keys.defaults.json",
            r#"{ "global": { "ctrl-pageup": "tab.prev" } }"#,
        );
    }

    /// repo の keys.defaults.json に書いた herdr-app の既定の値は、衝突にせずに dotfiles の値へ書き換える (既定に戻されたときも)。
    /// 既定でも dotfiles の値でもない値 (手で変えた値) は今までどおり衝突
    #[test]
    fn replaces_listed_herdr_app_defaults() {
        let e = Env::new();
        with_pageup_default(&e);
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains(
                "書き換える (apply で): global ctrl-pageup = space.prev (前は herdr-app の既定 tab.prev)"
            ),
            "{out}"
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("追加 1 / 更新 1 / 削除 0 / 同じ 0 / 飛ばした 0"),
            "{o:?}"
        );
        assert_eq!(
            e.keys()[0].1,
            pairs(&[
                ("alt-1", "space.select:1"),
                ("ctrl-pageup", "space.prev"),
                ("ctrl-shift-t", "tab.new"),
                ("ctrl-k", "mod.open:pjp-prefix"),
            ]),
            "同じ場所で書き換える"
        );
        assert_eq!(e.recorded()["global"]["ctrl-pageup"], "space.prev");
        // herdr-app の既定に戻された (逃げ道のキーで keys.json を作り直したなど) ら、記録と違っても衝突にせずに書き直す
        let text = e.keys_text().replace("\"space.prev\"", "\"tab.prev\"");
        std::fs::write(e.home("keys.json"), text).unwrap();
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("更新 1"), "{o:?}");
        assert!(
            e.keys()[0]
                .1
                .contains(&("ctrl-pageup".to_string(), "\"space.prev\"".to_string()))
        );
        // 既定でも dotfiles の値でもない値は衝突 (残して ⚠)。--force なら上書きする
        let e = Env::new();
        with_pageup_default(&e);
        let text = e.keys_text().replace("\"tab.prev\"", "\"pane.zoom\"");
        std::fs::write(e.home("keys.json"), &text).unwrap();
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}\n{out}");
        assert!(
            o[1].notes.iter().any(|n| n.starts_with(
                "global ctrl-pageup (keys.json は pane.zoom、dotfiles は space.prev。dotfiles が書いた値でも、herdr-app の既定 (keys.defaults.json の tab.prev) でもない"
            )),
            "{o:?}"
        );
        assert!(
            e.keys()[0]
                .1
                .contains(&("ctrl-pageup".to_string(), "\"pane.zoom\"".to_string())),
            "残す"
        );
        let (o, out) = e.run(Mode::Apply { force: true });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert_eq!(e.recorded()["global"]["ctrl-pageup"], "space.prev");
    }

    /// repo から消したキーは、今の値が記録どおりなら、keys.defaults.json の herdr-app の既定の値に戻す (外すと herdr-app のそのキーが無くなる)
    #[test]
    fn restores_herdr_app_defaults_for_keys_gone_from_the_repo() {
        let e = Env::new();
        with_pageup_default(&e);
        e.run(APPLY);
        // repo のキーから ctrl-pageup を消す (既定の値の行は残す)
        e.t.write(
            "dotfiles/win/herdr-app/keys.json",
            r#"{ "global": { "ctrl-k": "mod.open:pjp-prefix" } }"#,
        );
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains(
                "戻す (apply で): global ctrl-pageup = tab.prev (repo から消えた。herdr-app の既定に戻す。前は space.prev)"
            ),
            "{out}"
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("追加 0 / 更新 0 / 削除 1 / 同じ 1 / 飛ばした 0"),
            "{o:?}"
        );
        assert_eq!(
            e.keys()[0].1,
            pairs(&[
                ("alt-1", "space.select:1"),
                ("ctrl-pageup", "tab.prev"),
                ("ctrl-shift-t", "tab.new"),
                ("ctrl-k", "mod.open:pjp-prefix"),
            ]),
            "外さずに、同じ場所で既定の値に戻す"
        );
        assert_eq!(
            e.recorded(),
            serde_json::json!({ "global": { "ctrl-k": "mod.open:pjp-prefix" } })
        );
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("同じ 1"), "{o:?}");
    }

    /// keys.json はキーの全部 (無ければ herdr-app が既定を書く)。dotfiles のキーだけのファイルを作ると既定のキーが消えるので作らない
    #[test]
    fn missing_keys_json_is_not_created() {
        let e = Env::new();
        std::fs::remove_file(e.home("keys.json")).unwrap();
        for mode in [Mode::Check, Mode::DryRun { force: true }, APPLY] {
            let (o, out) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Manual], "{mode:?} {o:?}\n{out}");
            assert!(
                o[0].text.contains("keys.json が無い")
                    && o[0].text.contains("herdr-app を一度起こしてから"),
                "{o:?}"
            );
            assert!(!e.home("keys.json").exists(), "{mode:?} は作らない");
        }
        assert!(e.record_text().is_none());
    }

    #[test]
    fn broken_files_fail_without_writing() {
        for (text, want) in [
            ("{\"global\": ", "壊れて"),
            ("[1]", "object でない"),
            ("{\"global\": [1]}", "keys.json の global が object でない"),
        ] {
            let e = Env::new();
            e.t.write("home/.config/herdr-app/keys.json", text);
            let (o, out) = e.run(APPLY);
            assert_eq!(kinds(&o), vec![Kind::Failed], "{text}: {o:?}\n{out}");
            assert!(o[0].text.contains(want), "{text}: {o:?}");
            assert_eq!(e.keys_text(), text);
            assert!(e.record_text().is_none());
        }
        // 触らない section は object でなくてもよい
        let e = Env::new();
        let odd = "{\"global\": {}, \"terminal\": [1]}";
        e.t.write("home/.config/herdr-app/keys.json", odd);
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(e.keys_text().contains("\"terminal\": [\n    1\n  ]"));
        // repo のキーが読めない・形が違う
        for (text, want) in [
            ("{", "壊れて"),
            ("{\"global\": \"x\"}", "global が object でない"),
            (
                "{\"global\": {\"ctrl-k\": 1}}",
                "global ctrl-k の action が文字列でも object でもない",
            ),
        ] {
            let e = Env::new();
            e.t.write("dotfiles/win/herdr-app/keys.json", text);
            let (o, out) = e.run(APPLY);
            assert_eq!(kinds(&o), vec![Kind::Failed], "{text}: {o:?}\n{out}");
            assert!(o[0].text.contains(want), "{text}: {o:?}");
            assert_eq!(e.keys_text(), DEFAULT);
        }
        // repo の herdr-app の既定の値 (keys.defaults.json) が読めない・形が違う
        for (text, want) in [
            ("{", "壊れて"),
            (
                "{\"global\": {\"ctrl-pageup\": 1}}",
                "global ctrl-pageup の action が文字列でも object でもない",
            ),
        ] {
            let e = Env::new();
            e.t.write("dotfiles/win/herdr-app/keys.defaults.json", text);
            let (o, out) = e.run(APPLY);
            assert_eq!(kinds(&o), vec![Kind::Failed], "{text}: {o:?}\n{out}");
            assert!(
                o[0].text.contains(want) && o[0].text.contains("keys.defaults.json"),
                "{text}: {o:?}"
            );
            assert_eq!(e.keys_text(), DEFAULT);
            assert!(e.record_text().is_none());
        }
    }

    /// 控えは、いちばん古いもの (初めて書く前の中身) と新しい方から 10 個
    #[test]
    fn keeps_the_first_and_ten_backups() {
        let e = Env::new();
        for i in 0..12 {
            e.t.write(
                "home/.config/herdr-app/keys.json",
                &format!("{{\"global\": {{\"alt-{i}\": \"space.select:{i}\"}}}}\n"),
            );
            let (o, _) = e.run(APPLY);
            assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        }
        let backups = e.backups();
        assert_eq!(backups.len(), 11, "{backups:?}");
        assert!(
            backups
                .iter()
                .all(|b| b.starts_with("keys-") && b.ends_with(".json"))
        );
        let first =
            e.t.path()
                .join("state")
                .join("herdr-app-keys")
                .join("backup")
                .join(&backups[0]);
        assert_eq!(
            std::fs::read_to_string(first).unwrap(),
            "{\"global\": {\"alt-0\": \"space.select:0\"}}\n"
        );
    }

    /// 同じ home を別の綴りで書いても同じ記録を引く。ほかの home の記録は残す
    #[test]
    fn record_follows_the_keys_json_path() {
        let e = Env::new();
        let custom = e.t.path().join("custom-home");
        std::fs::create_dir_all(&custom).unwrap();
        std::fs::write(custom.join("keys.json"), DEFAULT).unwrap();
        let plain = custom.to_string_lossy().into_owned();
        let other = if cfg!(windows) {
            plain.replace('\\', "/")
        } else {
            plain.replacen("/custom-home", "//custom-home", 1)
        };
        assert_ne!(plain, other);
        let sys = |home: &str| FakeSys::new(|_| unreachable!()).with_env("HERDR_APP_HOME", home);
        let (o, out) = e.run_with(APPLY, sys(&plain));
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(out.contains("herdr-app の home: "), "{out}");
        // 別の綴りでも、記録どおりの値として repo から消えたキーを外せる
        e.t.write(
            "dotfiles/win/herdr-app/keys.json",
            r#"{ "global": { "ctrl-k": "mod.open:pjp-prefix" } }"#,
        );
        let (o, out) = e.run_with(APPLY, sys(&other));
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 2 / 同じ 1"), "{o:?}");
        // 既定の home の keys.json は別の記録 (custom-home の記録は残す)
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.starts_with("追加 1 /"), "{o:?}");
        let rec: serde_json::Value = serde_json::from_str(&e.record_text().unwrap()).unwrap();
        let files = rec["files"].as_object().unwrap();
        let keys_json = |home: &str| {
            PathBuf::from(home)
                .join("keys.json")
                .to_string_lossy()
                .into_owned()
        };
        assert_eq!(files.len(), 2, "{rec}");
        assert!(
            files.contains_key(&keys_json(&other)),
            "鍵は今の綴りに寄る: {rec}"
        );
        assert!(
            !files.contains_key(&keys_json(&plain)),
            "前の綴りの鍵は外す: {rec}"
        );
    }

    #[test]
    fn broken_record_is_read_as_empty() {
        let e = Env::new();
        e.t.write("state/herdr-app-keys.applied.json", "[1]");
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].notes.iter().any(|n| n.starts_with("記録が読めない")),
            "{o:?}"
        );
        assert_eq!(e.recorded()["global"]["ctrl-k"], "mod.open:pjp-prefix");
        // 書くキーが無くても、壊れた記録は直す (毎回は知らせない)
        let e = Env::new();
        e.t.write("state/herdr-app-keys.applied.json", "[1]");
        e.t.write("dotfiles/win/herdr-app/keys.json", "{}");
        let (o, _) = e.run(APPLY);
        assert!(
            o[0].notes.iter().any(|n| n.starts_with("記録が読めない")),
            "{o:?}"
        );
        let rec: serde_json::Value = serde_json::from_str(&e.record_text().unwrap()).unwrap();
        assert_eq!(rec, serde_json::json!({ "version": 1, "files": {} }));
        let (o, _) = e.run(Mode::Check);
        assert!(o[0].notes.is_empty(), "{o:?}");
    }

    #[test]
    fn notes_keys_error() {
        let e = Env::new();
        e.t.write(
            "home/.config/herdr-app/keys.error",
            "unknown command: tab.nxt\nmore\n",
        );
        let (o, _) = e.run(Mode::Check);
        assert!(
            o[0].notes.iter().any(|n| n.contains("keys.error がある")
                && n.contains("unknown command: tab.nxt")
                && !n.contains("more")),
            "{o:?}"
        );
        // 書いた直後の keys.error は前の中身のもの (herdr-app はこれから読み直す)。※ にせず、後で check で見るよう出す
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(
            !o[0].notes.iter().any(|n| n.contains("keys.error")),
            "{o:?}"
        );
        assert!(
            out.contains("読めたかは、少し後に dotfiles check --steps herdr-app-keys"),
            "{out}"
        );
        // 書かなかった apply と check では知らせる
        for mode in [APPLY, Mode::Check] {
            let (o, _) = e.run(mode);
            assert!(
                o[0].notes.iter().any(|n| n.contains("keys.error がある")),
                "{mode:?} {o:?}"
            );
        }
    }

    /// Shift+G の argv (mod の CLAUDE) が、c (fish の abbr・bash の alias・PowerShell の function) と同じ引数
    #[test]
    fn claude_argv_matches_c() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let read = |rel: &str| {
            std::fs::read_to_string(join_segments(&repo, rel))
                .unwrap_or_else(|e| panic!("{rel} が読めない ({e})"))
                .replace("\r\n", "\n")
        };
        let main = read("win/herdr-app/mods/pjp-prefix/main.js");
        let head = "const CLAUDE = [";
        let start = main.find(head).expect("main.js に CLAUDE が無い") + head.len();
        let end = start + main[start..].find(']').unwrap();
        let argv: Vec<&str> = main[start..end]
            .split(',')
            .map(|s| s.trim().trim_matches('"'))
            .collect();
        assert_eq!(argv.first(), Some(&"claude"), "{argv:?}");
        for rel in ["nix/home/modules/fish.nix", "nix/home/modules/bash.nix"] {
            let text = read(rel);
            let c: Vec<&str> = text
                .lines()
                .filter_map(|l| l.trim().strip_prefix("c = \"")?.strip_suffix("\";"))
                .collect();
            assert_eq!(c.len(), 1, "{rel} の c: {c:?}");
            assert_eq!(c[0].split_whitespace().collect::<Vec<_>>(), argv, "{rel}");
        }
        let ps = read("win/powershell/dotfiles.ps1");
        let c: Vec<&str> = ps
            .lines()
            .filter_map(|l| l.strip_prefix("function c { ")?.strip_suffix(" @args }"))
            .collect();
        assert_eq!(c.len(), 1, "dotfiles.ps1 の function c: {c:?}");
        assert_eq!(
            c[0].split_whitespace().collect::<Vec<_>>(),
            argv,
            "dotfiles.ps1"
        );
    }

    /// 本物の repo のキー: prefix の mod を開くキーが repo の mod を指し、mod の section の命令をその mod が受ける
    #[test]
    fn real_repo_keys_match_the_prefix_mod() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let wanted = load_wanted(&join_segments(&repo, KEYS)).unwrap();
        let global = &wanted
            .iter()
            .find(|(s, _)| s == "global")
            .expect("global がある")
            .1;
        let open = global
            .iter()
            .find(|(k, _)| k == "ctrl-k")
            .map(|(_, v)| v.clone());
        assert_eq!(
            open,
            Some(OValue::String("mod.open:pjp-prefix".to_string()))
        );
        let mod_dir = join_segments(&repo, "win/herdr-app/mods/pjp-prefix");
        let main = std::fs::read_to_string(mod_dir.join("main.js")).unwrap();
        let section = &wanted
            .iter()
            .find(|(s, _)| s == "mod:pjp-prefix")
            .expect("mod:pjp-prefix がある")
            .1;
        for (key, action) in section {
            let OValue::String(a) = action else {
                panic!("{key}: {action:?}")
            };
            let command = a
                .strip_prefix("pjp-prefix.")
                .unwrap_or_else(|| panic!("{key} の {a} が pjp-prefix の命令でない"));
            assert!(
                main.contains(&format!("\"{command}\"")),
                "main.js が {command} を受けない"
            );
        }
        // ほかに要る形: global に space (Ctrl+PageUp/Down と Ctrl+Shift+↑↓) と tab (Ctrl+↑↓) の移動
        let has = |keys: &[(String, OValue)], key: &str, action: &str| {
            keys.iter()
                .any(|(k, v)| k == key && *v == OValue::String(action.to_string()))
        };
        for (key, action) in [
            ("ctrl-pageup", "space.prev"),
            ("ctrl-pagedown", "space.next"),
            ("ctrl-shift-up", "space.prev"),
            ("ctrl-shift-down", "space.next"),
            ("ctrl-up", "tab.prev"),
            ("ctrl-down", "tab.next"),
        ] {
            assert!(
                has(global, key, action),
                "global の {key} が {action} でない"
            );
        }
        // Ctrl+Alt+↑↓ は割り当てない (端末のプログラムに返す)
        for key in ["ctrl-alt-up", "ctrl-alt-down"] {
            assert!(
                global.iter().all(|(k, _)| k != key),
                "global に {key} がある"
            );
        }
        // Ctrl+PageUp/Down の herdr-app の既定 (タブの移動) は、keys.defaults.json に書いて上書きする
        let defaults = load_wanted(&join_segments(&repo, DEFAULTS)).unwrap();
        let default_global = &defaults
            .iter()
            .find(|(s, _)| s == "global")
            .expect("keys.defaults.json に global がある")
            .1;
        for (key, action) in [("ctrl-pageup", "tab.prev"), ("ctrl-pagedown", "tab.next")] {
            assert!(
                has(default_global, key, action),
                "keys.defaults.json の global の {key} が {action} でない"
            );
        }
    }

    #[test]
    fn step_info() {
        let i = HerdrAppKeys.info();
        assert_eq!(
            (i.id, i.order, i.gate),
            ("herdr-app-keys", 99, Gate::Tool("windowsHerdr"))
        );
        assert!(i.ported && i.windows_only);
    }
}
