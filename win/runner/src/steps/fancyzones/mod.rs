//! fancyzones (order 92): PowerToys の FancyZones へ、`win/powertoys/fancyzones/` の持つキー (settings.json)・カスタムレイアウト (uuid ごとに足す)・
//! 横向きの既定・ディスプレイへのあて方 (解像度で決める。全部の仮想デスクトップの組) を書く。WSL の `nix/scripts/bootstrap-windows-fancyzones.sh` を
//! 写したもの (段の順・判定・書く中身 (PowerToys の形のバイト列)・記録・退避・`--force`・`--import`・文言をそろえる。受け持ちを runner に切り替えた後に、
//! WSL の setup が書いたものを同じものとして引き継ぐため)。決めごとは dotfiles-private の docs/adr/042_*・046_*・053_*・054_*。
//!
//! 1. 設定 (`settings.json`): managed.json の持つキーだけを書く。値が違えば、手で変えていても dotfiles の値へ戻す (衝突にしない)。ほかのキーの値・
//!    キーの順・1 行で末尾に改行なしの形は変えない。無ければ持つキーと name・version だけで作る
//! 2. カスタムレイアウト (`custom-layouts.json`): repo のレイアウトを uuid で突き合わせて足す (`layouts.rs`)
//! 3. 横向きの既定 (`default-layouts.json`): 決まりの default のカスタムレイアウトにそろえる (`layouts.rs`)
//! 4. ディスプレイへのあて方 (`applied-layouts.json`): 解像度の決まりのレイアウトをあて、組の無い仮想デスクトップに組を作る (`assign.rs`)
//! 5. 全体の設定で FancyZones がオフなら、効かないことを知らせる (自動でオンにはしない)
//!
//! - 書くときは隣に書いて置き換えた後に更新時刻を進める (FancyZones は LastWriteTime の変更しか見ていない)。PowerToys は起動し直さない
//! - 記録 (`windows-fancyzones.applied.json`・`windows-fancyzones.assigned.json`) と退避 (`windows-fancyzones\backup\<UTC の時刻>-<pid>\`。10 回分) は
//!   `%LOCALAPPDATA%\dotfiles\state\` に WSL と同じ名前と形で置く。WSL の記録は読まない
//! - ディスプレイと仮想デスクトップは、WSL と同じ PowerShell の本文を Windows PowerShell の `-EncodedCommand` で流して聞く (check と dry-run でも
//!   聞く。読むだけ)
//! - check と dry-run は何も書かない (設定・レイアウト・記録・退避)
//! - 取り込み (`dotfiles import fancyzones <名前>…`。WSL の `--import`): PC のレイアウトを名前で選び、repo の custom-layouts.json へ写す

mod assign;
mod layouts;
#[cfg(test)]
mod tests;

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::jv::{self, Jv};
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// 持つキー (repo からの相対)
pub const MANAGED_REL: &str = "win/powertoys/fancyzones/managed.json";
/// repo のカスタムレイアウト
pub const LAYOUTS_REL: &str = "win/powertoys/fancyzones/custom-layouts.json";
/// 解像度の決まり
pub const RULES_REL: &str = "win/powertoys/fancyzones/layout-rules.json";
/// 足したレイアウトの記録 (WSL の `~/.local/state/dotfiles/` の記録と同じ名前)
pub const RECORD_FILE: &str = "windows-fancyzones.applied.json";
/// ディスプレイへのあて方の記録 (WSL と同じ名前)
pub const ASSIGNED_FILE: &str = "windows-fancyzones.assigned.json";
/// 退避の置き場 (記録の置き場からの相対。WSL の `~/.local/state/dotfiles/windows-fancyzones/backup` と同じ並び)
const BACKUP_REL: &str = "windows-fancyzones/backup";
/// 退避を残す回数 (WSL の `keep_backups`)
const KEEP_BACKUPS: usize = 10;
/// FancyZones の置き場 (`%LOCALAPPDATA%` からの相対)
const FZ_REL: &str = "Microsoft/PowerToys/FancyZones";
/// PowerToys の全体の設定 (`%LOCALAPPDATA%` からの相対)
const GLOBAL_REL: &str = "Microsoft/PowerToys/settings.json";

pub struct FancyZones;

impl Step for FancyZones {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "fancyzones",
            order: 92,
            title: "FancyZones の持つキー・カスタムレイアウト・横向きの既定・ディスプレイへのあて方を書く",
            gate: Gate::Always,
            ported: true,
            windows_only: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let mut fz = Fz::new(ctx, mode);
        settings_stage(ctx, &mut fz);
        layouts::sync_layouts(ctx, &mut fz);
        layouts::sync_default_layout(ctx, &mut fz);
        assign::assign_layouts(ctx, &mut fz);
        enabled_stage(ctx, &mut fz);
        fz.rows
    }
}

/// 1 回ぶんの状態 (置き場所・流し方・段の間で渡すもの・締めの表の行)。
struct Fz {
    mode: Mode,
    /// 出力の頭 (dry-run なら `[dry-run] `)
    pre: &'static str,
    managed: PathBuf,
    layouts: PathBuf,
    rules: PathBuf,
    fz_dir: PathBuf,
    settings: PathBuf,
    pc_layouts: PathBuf,
    pc_applied: PathBuf,
    pc_defaults: PathBuf,
    global: PathBuf,
    record: PathBuf,
    assigned: PathBuf,
    backup: fsutil::RunBackup,
    /// check と dry-run で、カスタムレイアウトの段が足す・書き換えるレイアウトの uuid (書かないので、後の段は PC にあるものとして見る)
    pending_layouts: Vec<String>,
    /// カスタムレイアウトの段の後の PC の custom-layouts.json (後の段で 1 回だけ読む。読めなければ Err)
    pc_layouts_doc: Option<Result<Jv, ()>>,
    rows: Vec<Outcome>,
}

impl Fz {
    fn new(ctx: &Ctx, mode: Mode) -> Fz {
        let fz_dir = join_segments(&ctx.roots.local_app_data, FZ_REL);
        Fz {
            mode,
            pre: if matches!(mode, Mode::DryRun { .. }) {
                "[dry-run] "
            } else {
                ""
            },
            managed: ctx.repo_path(MANAGED_REL),
            layouts: ctx.repo_path(LAYOUTS_REL),
            rules: ctx.repo_path(RULES_REL),
            settings: fz_dir.join("settings.json"),
            pc_layouts: fz_dir.join("custom-layouts.json"),
            pc_applied: fz_dir.join("applied-layouts.json"),
            pc_defaults: fz_dir.join("default-layouts.json"),
            fz_dir,
            global: join_segments(&ctx.roots.local_app_data, GLOBAL_REL),
            record: ctx.state_dir.join(RECORD_FILE),
            assigned: ctx.state_dir.join(ASSIGNED_FILE),
            backup: fsutil::RunBackup::new(join_segments(&ctx.state_dir, BACKUP_REL), KEEP_BACKUPS),
            pending_layouts: Vec::new(),
            pc_layouts_doc: None,
            rows: Vec::new(),
        }
    }

    fn dry(&self) -> bool {
        matches!(self.mode, Mode::DryRun { .. })
    }

    /// カスタムレイアウトの段の後の PC の custom-layouts.json (無ければ空の object。読めなければ Err。1 回だけ読む)
    fn read_pc_layouts(&mut self, ctx: &mut Ctx) -> Result<Jv, ()> {
        if self.pc_layouts_doc.is_none() {
            let doc = if !self.pc_layouts.exists() {
                Ok(Jv::Object(Vec::new()))
            } else {
                read_retry(ctx, &self.pc_layouts, layouts_shape).ok_or(())
            };
            self.pc_layouts_doc = Some(doc);
        }
        self.pc_layouts_doc.clone().expect("読んだ")
    }
}

/// custom-layouts.json の形 (custom-layouts が配列の JSON の object。無いのはよい)
fn layouts_shape(v: &Jv) -> bool {
    v.is_object()
        && v.get("custom-layouts")
            .is_none_or(|l| matches!(l, Jv::Array(_)))
}

/// 読みかけ (書いている途中) に当たっても読めるよう、`ok` な JSON になるまで 5 回読む (読めないたびに 1 秒待つ。WSL の `readable_object`・
/// `snapshot_*`)
fn read_retry(ctx: &mut Ctx, path: &Path, ok: fn(&Jv) -> bool) -> Option<Jv> {
    for _ in 0..5 {
        if let Some(v) = std::fs::read_to_string(path)
            .ok()
            .and_then(|t| Jv::parse(&t).ok())
            .filter(ok)
        {
            return Some(v);
        }
        ctx.sys.sleep(Duration::from_secs(1));
    }
    None
}

/// PowerToys の書く形 (字下げ 2・CRLF・末尾に改行なし。エディターが書くバイト列と同じ形。WSL の `to_pt_form`)
fn pt_form(v: &Jv) -> String {
    v.indent(2).replace('\n', "\r\n")
}

/// 隣に書いて置き換える (読みかけを見せない)
fn place(path: &Path, body: &str) -> std::io::Result<()> {
    fsutil::write_atomic(path, body.as_bytes())
}

/// 更新時刻を今にする (WSL の `touch`。FancyZones は LastWriteTime の変更しか見ていないので、置き換えただけでは読み直さない)
fn touch(path: &Path) -> std::io::Result<()> {
    std::fs::File::options()
        .write(true)
        .open(path)?
        .set_modified(SystemTime::now())
}

/// 止めない警告を出す (WSL の `warn`。1 行目は `!! `、続きは字下げ)
fn warn(ctx: &mut Ctx, lines: &[String]) {
    for (i, l) in lines.iter().enumerate() {
        for (j, part) in l.split('\n').enumerate() {
            if i == 0 && j == 0 {
                ctx.say(format!("!! {part}"));
            } else {
                ctx.say(format!("   {part}"));
            }
        }
    }
}

/// 締めの表の行の注に、警告の続きの行を写す
fn row(kind: Kind, text: impl Into<String>, notes: &[String]) -> Outcome {
    let mut o = Outcome::new(kind, text);
    o.notes = notes
        .iter()
        .flat_map(|n| n.split('\n').map(str::to_string).collect::<Vec<_>>())
        .filter(|n| !n.trim().is_empty())
        .collect();
    o
}

/// `--force` のコマンド (受け持ちで替える)
fn force_command(ctx: &Ctx) -> String {
    super::deploy::force_command(ctx, "fancyzones")
}

/// `--dry-run --force` のコマンド (受け持ちで替える)
fn dry_force_command(ctx: &Ctx) -> String {
    if ctx.host.runner_enable {
        "dotfiles apply --dry-run --steps fancyzones --force".to_string()
    } else {
        "WSL で nix/scripts/bootstrap-windows-fancyzones.sh --dry-run --force".to_string()
    }
}

/// 取り込みのコマンド (受け持ちで替える。runner は PowerShell の一重引用符、WSL の script は bash の一重引用符で名前を囲む)
fn import_command(ctx: &Ctx, names: &[String]) -> String {
    if ctx.host.runner_enable {
        let quoted: Vec<String> = names
            .iter()
            .map(|n| format!("'{}'", super::ps1::ps_quote(n)))
            .collect();
        format!("dotfiles import fancyzones {}", quoted.join(" "))
    } else {
        let args: Vec<String> = names
            .iter()
            .map(|n| format!("--import {}", super::deploy::sh_quote(n)))
            .collect();
        format!(
            "WSL で nix/scripts/bootstrap-windows-fancyzones.sh {} (受け持ちが WSL の setup の間。runner の取り込みは止まる)",
            args.join(" ")
        )
    }
}

/// jq の `apply($m)`: `$m` の持つキーだけを書き込む (途中が object でも null でもなければ書けない)
fn apply_managed(doc: &mut Jv, managed: &Jv) -> Result<(), String> {
    for p in managed.leaf_paths() {
        let want = managed.lookup(&p).cloned().unwrap_or(Jv::Null);
        doc.set_path(&p, want)?;
    }
    Ok(())
}

/// 設定の段 (WSL の `sync_settings`): managed.json の持つキーだけを書く。値が違えば dotfiles の値へ戻す (衝突にしない)。
fn settings_stage(ctx: &mut Ctx, fz: &mut Fz) {
    let problems = layouts::managed_problems(&fz.managed);
    if !problems.is_empty() {
        let mut lines = vec![format!(
            "{MANAGED_REL} に誤りがあるので、FancyZones の設定を書きません:"
        )];
        lines.push(problems.join("\n"));
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Failed,
            format!("{MANAGED_REL} に誤りがあるので、FancyZones の設定を書いていない"),
            &problems,
        ));
        return;
    }
    // 確かめた後に読み直す (間に pull などで変わって読めなければ、書かずに知らせる)
    let Some(managed) = std::fs::read_to_string(&fz.managed)
        .ok()
        .and_then(|t| Jv::parse(&t).ok())
    else {
        reread_failed(ctx, fz, MANAGED_REL);
        return;
    };
    let n = managed.leaf_paths().len();
    let shown = fz.settings.display().to_string();
    let pre = fz.pre;
    if !fz.settings.exists() {
        match fz.mode {
            Mode::Check => {
                ctx.say(format!("FancyZones の settings.json がありません (apply で、持つキーだけで作る。持つキー {n} 件): {shown}"));
                fz.rows.push(row(
                    Kind::Missing,
                    format!(
                        "FancyZones の settings.json が無い → apply で持つキー {n} 件だけで作る"
                    ),
                    &[],
                ));
            }
            Mode::DryRun { .. } => {
                ctx.say(format!("[dry-run] FancyZones の settings.json が無いので、持つキーだけで作ります (持つキー {n} 件): {shown}"));
                fz.rows.push(row(
                    Kind::Missing,
                    format!(
                        "[dry-run] FancyZones の settings.json が無いので、持つキー {n} 件だけで作る"
                    ),
                    &[],
                ));
            }
            Mode::Apply { .. } => {
                // FancyZones は name が無いとエラーのダイアログを出し、無いキーは今の値のまま読むので、持つキーと name・version で足りる
                let mut doc = Jv::parse(r#"{"properties":{},"name":"FancyZones","version":"1.0"}"#)
                    .expect("作る形");
                let written = std::fs::create_dir_all(&fz.fz_dir)
                    .map_err(|e| e.to_string())
                    .and_then(|()| apply_managed(&mut doc, &managed))
                    .and_then(|()| place(&fz.settings, &doc.compact()).map_err(|e| e.to_string()));
                if let Err(e) = written {
                    let lines = [
                        format!("FancyZones の settings.json を作れませんでした: {shown}"),
                        "Windows 側のディレクトリを確かめてから、流し直してください。".to_string(),
                    ];
                    warn(ctx, &lines);
                    fz.rows.push(row(
                        Kind::Failed,
                        format!("FancyZones の settings.json を作れなかった ({e})"),
                        &lines[1..],
                    ));
                    return;
                }
                reload(ctx, fz, &fz.settings.clone(), "settings.json");
                ctx.say(format!("FancyZones の settings.json が無いので、持つキーだけで作りました (持つキー {n} 件): {shown}"));
                fz.rows.push(row(
                    Kind::Ok,
                    format!("FancyZones の settings.json を持つキー {n} 件だけで作った"),
                    &[],
                ));
            }
        }
        return;
    }

    let unreadable = |ctx: &mut Ctx, fz: &mut Fz| {
        let lines = [
            format!("FancyZones の settings.json を読めないので、書きません: {shown}"),
            "中身を確かめて直すか、ファイルを消してから流し直してください (無ければ、持つキーだけで作ります)。".to_string(),
        ];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Failed,
            "FancyZones の settings.json を読めないので書いていない",
            &lines[1..],
        ));
    };
    let Some(doc) = read_retry(ctx, &fz.settings, Jv::is_object) else {
        unreadable(ctx, fz);
        return;
    };
    // 値が違うキーを 1 行ずつ (途中が object でなくても落ちない。書くときに落ちて、書けないと知らせる)
    let changes: Vec<String> = managed
        .leaf_paths()
        .iter()
        .filter_map(|p| {
            let want = managed.lookup(p).cloned().unwrap_or(Jv::Null);
            let cur = doc.getpath(p).cloned().unwrap_or(Jv::Null);
            (!jv::jq_eq(&cur, &want)).then(|| {
                let shown_cur = if cur == Jv::Null {
                    "(無い)".to_string()
                } else {
                    cur.compact()
                };
                format!("{} {shown_cur} → {}", p.join("."), want.compact())
            })
        })
        .collect();
    if changes.is_empty() {
        ctx.say(format!(
            "FancyZones の設定は揃っています (持つキー {n} 件)。"
        ));
        fz.rows.push(row(
            Kind::Ok,
            format!("FancyZones の持つキー {n} 件は揃っている"),
            &[],
        ));
        return;
    }
    let mut rendered = doc.clone();
    let render = apply_managed(&mut rendered, &managed);
    let k = changes.len();
    match fz.mode {
        Mode::Check | Mode::DryRun { .. } => {
            if render.is_ok() {
                for c in &changes {
                    if fz.mode == Mode::Check {
                        ctx.say(format!(
                            "FancyZones の設定が dotfiles の値と違います (apply で戻す): {c}"
                        ));
                    } else {
                        ctx.say(format!(
                            "[dry-run] FancyZones の設定を dotfiles の値へ戻します: {c}"
                        ));
                    }
                }
                fz.rows.push(row(
                    Kind::Fix,
                    format!("{pre}FancyZones の持つキー {k} 件を dotfiles の値へ戻す (設定画面で変えていても戻す)"),
                    &[],
                ));
            } else {
                ctx.say(format!(
                    "{pre}FancyZones の settings.json に書けません: {shown}"
                ));
                for c in &changes {
                    ctx.say(c);
                }
                fz.rows.push(row(
                    Kind::Failed,
                    format!("{pre}FancyZones の settings.json に書けない (途中が object でない)"),
                    &changes,
                ));
            }
        }
        Mode::Apply { .. } => {
            let written = render
                .and_then(|()| place(&fz.settings, &rendered.compact()).map_err(|e| e.to_string()));
            if written.is_err() {
                let mut lines = vec![format!(
                    "FancyZones の settings.json に書けないので、dotfiles の値にできませんでした: {shown}"
                )];
                lines.push(changes.join("\n"));
                warn(ctx, &lines);
                fz.rows.push(row(
                    Kind::Failed,
                    "FancyZones の settings.json に書けないので、dotfiles の値にできなかった",
                    &changes,
                ));
                return;
            }
            reload(ctx, fz, &fz.settings.clone(), "settings.json");
            for c in &changes {
                ctx.say(format!(
                    "FancyZones の設定を dotfiles の値へ戻しました: {c}"
                ));
            }
            fz.rows.push(row(
                Kind::Ok,
                format!("FancyZones の持つキー {k} 件を dotfiles の値へ戻した"),
                &[],
            ));
        }
    }
}

/// 確かめた repo のファイルを読み直せなかった (間に pull などで変わった) と知らせる
fn reread_failed(ctx: &mut Ctx, fz: &mut Fz, rel: &str) {
    let lines = [
        format!("{rel} を読み直せないので、書きません (確かめた後に変わったかもしれません)。"),
        "流し直してください。".to_string(),
    ];
    warn(ctx, &lines);
    fz.rows.push(row(
        Kind::Failed,
        format!("{rel} を読み直せないので書いていない"),
        &lines[1..],
    ));
}

/// 書いた後に更新時刻を進めて、動いている FancyZones に読み直させる。進められなければ知らせる (書いたものは残る)
fn reload(ctx: &mut Ctx, fz: &mut Fz, path: &Path, name: &str) {
    if touch(path).is_err() {
        let restart = if name == "custom-layouts.json" {
            "PowerToys を起動し直すか、エディターを開いて閉じると読みます。"
        } else {
            "PowerToys を起動し直すと読みます。"
        };
        let lines = [
            format!(
                "FancyZones の {name} に書きましたが、FancyZones に読み直させられませんでした: {}",
                path.display()
            ),
            restart.to_string(),
        ];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Manual,
            format!("FancyZones の {name} に書いたが、FancyZones に読み直させられなかった"),
            &lines[1..],
        ));
    }
}

/// 全体の設定で FancyZones がオフなら、効かないことを知らせる (WSL の `check_enabled`。5 回まで読む。キーやファイルが無ければオン)
fn enabled_stage(ctx: &mut Ctx, fz: &mut Fz) {
    if !fz.global.exists() {
        return;
    }
    for _ in 0..5 {
        // jq の `.enabled.FancyZones` (-r) が読めて、何か出したら確かめた
        let state = std::fs::read_to_string(&fz.global)
            .ok()
            .and_then(|t| Jv::parse(&t).ok())
            .and_then(|v| {
                v.field("enabled")
                    .and_then(|e| e.field("FancyZones"))
                    .cloned()
            });
        if let Some(v) = state {
            if v == Jv::Bool(false) || v == Jv::from("false") {
                let lines = [
                    format!("FancyZones がオフなので、FancyZones の設定は効きません (全体の設定の enabled.FancyZones が false。{})。", fz.global.display()),
                    "自動ではオンにしません。使うなら、PowerToys の設定画面で「ウィンドウとレイアウト」→「FancyZones」をオンにしてください。オンにすると、書いてある設定を読みます。".to_string(),
                ];
                warn(ctx, &lines);
                fz.rows.push(row(
                    Kind::Manual,
                    "FancyZones がオフなので、FancyZones の設定は効かない (自動ではオンにしない)",
                    &lines[1..],
                ));
            }
            return;
        }
        ctx.sys.sleep(Duration::from_secs(1));
    }
    warn(
        ctx,
        &[format!(
            "PowerToys の全体の設定を読めないので、FancyZones がオンかを確かめられません: {}",
            fz.global.display()
        )],
    );
    fz.rows.push(row(
        Kind::Failed,
        "PowerToys の全体の設定を読めないので、FancyZones がオンかを確かめられない",
        &[],
    ));
}

/// 取り込み (`dotfiles import fancyzones <名前>…`。WSL の `--import`): PC のレイアウトを名前で選び、repo の custom-layouts.json へ写す。PC のファイル・
/// settings.json・記録には書かない (次の apply が、PC と repo が同じと見て記録する)。
pub fn import(ctx: &mut Ctx, names: &[String]) -> Outcome {
    let mut fz = Fz::new(ctx, Mode::Apply { force: false });
    layouts::import_layouts(ctx, &mut fz, names)
}
