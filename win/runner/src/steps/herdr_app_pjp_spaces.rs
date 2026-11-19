//! herdr-app-pjp-spaces (order 98): claude-skills の herdr-app の mod `pjp-spaces` を herdr-app の home の `mods\pjp-spaces\` へ置き、同梱の
//! layout `main` を写した自分の layout `pjp-main` の spaces の block を pjp-spaces に替える。pjp-spaces は herdr-app の spaces の mod を写し、
//! space の行の 2 行目にハブと子の印 (🌱・🌳[N]・🔄・👀・🗑️・↑ TKT-n) を足したもの (claude-skills の spec
//! `docs/superpowers/specs/2026-11-15-windows-herdr-app-hc-design.md` の §7.5・§9 の W2-4)。herdr-app は Windows だけなので、WSL の setup に同じ
//! 手順は無い (Windows にしか無い手順)。
//!
//! - mod の元は claude-skills の clone の `skills/pjp-hc-hub/herdr-app/mods/pjp-spaces/` (claude-skills と決めた置き場)。置き方は herdr-app-mods と
//!   同じ記録つきのコピー (herdr-app が書くファイルと名前が `.` で始まるものは配らない。元から消えたファイルは記録どおりなら消す。mod.json を
//!   先に置く)
//! - clone にまだ無ければ (claude-skills の PR の merge 前) 何もしない。置いた後で clone から無くなったら、置いたものには触らずに知らせる
//!   (layout が mod を指しているので、片付けると sidebar が壊れる)
//! - mod.json の place が none でない mod は置かない (herdr-app は初めて見た mod を、place に従って表示中の layout へ差し込む)。同梱の main が
//!   無ければ (herdr-app をまだ起こしていない) mod も置かない
//! - layout は `layouts\pjp-main.json`。無く、作った記録も無いときだけ、apply が `herdr-app do layout.clone {"name":"main","as":"pjp-main"}` を
//!   打つ。clone は main と clicks (sidebar の幅など。`layouts\.state\`) を写して `cloned_from` を残し、表示を pjp-main に替える (画面が替わる)。
//!   続けて spaces を指す block (content.mod が spaces) を pjp-spaces に替えて書く。表示が main でなければ作らない (ユーザーの選んだ layout を
//!   替えない)
//! - 作った後は、今の main に同じ差し替えをした形 (cloned_from は今のファイルのまま) を持つ。main が変わったら (herdr-app を上げた) check が
//!   変わった node を出し、apply が書き直す。spaces を pjp-spaces に替えると今の形になるファイル (人が clone し直した・保存し直した) は、記録に
//!   よらず引き取る。ほかの違う中身 (手で直した) は衝突で残す (`--force` で上書き)。clicks には触らない
//! - 表示を替えるのは、初めて作るときの clone の 1 回だけ。作った pjp-main が無くなったら (逃げ道のキー ctrl-alt-shift-escape が退けた・手で
//!   外した)、mod も layout も置かない (外したままにする)。戻すのは人 (main を clone し直すか、退けたファイルの名前を戻す)。`--force` では戻さない
//!   (ほかの手順の衝突を解く `dotfiles apply --force` で、表示を替えない)
//! - layout を書かなかった実行で、herdr-app が layout を読めなかった理由のファイルがあれば ※ で添える
//! - herdr-app に打つのは `herdr-app do layout.clone` だけ (止めない・立て直さない)。表示中の layout は `shared.json` の `layout` で読む
//!
//! 記録は `%LOCALAPPDATA%\dotfiles\state\herdr-app-pjp-spaces.deployed.json` (mod のファイルと layout の sha256)。layout の記録は home の綴りの
//! 違い (`/` と `\`・Windows の大文字小文字) を見ずに引く。dotfiles-private の docs/adr/072_win_herdr_app_pjp_spaces_*。

use super::claude_skills::clone_dir;
use super::herdr_app_mods::{Keep, app_home, copy_mod, list_mod, prune};
use super::linker::{Linker, Source};
use super::tool_skill::{HERDR_APP_OFFICIAL, locate};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::ojson::OValue;
use crate::process::CommandSpec;
use crate::record::Records;
use crate::report::Kind;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// claude-skills の clone の中の mod の置き場 (`/` 区切り。この下の `pjp-spaces` が mod。claude-skills と決めた約束)
pub const SOURCE_ROOT: &str = "skills/pjp-hc-hub/herdr-app/mods";
/// mod の名前 (元と置き先のフォルダの名前。layout の content.mod)
pub const MOD: &str = "pjp-spaces";
/// 写す元の同梱の layout
pub const BASE: &str = "main";
/// 差し替える同梱の mod
pub const SHIPPED: &str = "spaces";
/// 自分の layout の名前 (`layouts\<名前>.json`)
pub const LAYOUT: &str = "pjp-main";
/// 記録 (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "herdr-app-pjp-spaces.deployed.json";
/// herdr-app do の待ちの上限
const DO_SECS: u64 = 60;
/// clone の後、herdr-app が layout のファイルを書き終えるのを待つ上限
const CLONE_WAIT: Duration = if cfg!(test) {
    Duration::from_millis(200)
} else {
    Duration::from_secs(10)
};

pub struct HerdrAppPjpSpaces;

impl Step for HerdrAppPjpSpaces {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "herdr-app-pjp-spaces",
            // herdr-app を入れる手順 (97) の後。dotfiles の mod を置く herdr-app-mods と並べる
            order: 98,
            title: "claude-skills の herdr-app の mod pjp-spaces を置き、main を写した layout pjp-main の spaces を pjp-spaces に替える",
            // 印はハブの道具 (pjp child・pjp mark) が付ける label を読む。claude-skills の clone を使うハブの手順 (hc-hub) と同じ switch
            gate: Gate::Tool("herdrHub"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let clone = clone_dir(ctx);
        let root = join_segments(&clone, SOURCE_ROOT);
        let src = root.join(MOD);
        let (home, why) = app_home(ctx);
        ctx.say(format!("mod の元: {}", src.display()));
        ctx.say(format!("herdr-app の home: {} ({why})", home.display()));
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let records = match Records::load(&record_path) {
            Ok(r) => r,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![
                    Outcome::new(Kind::Failed, "herdr-app-pjp-spaces の記録が壊れている").note(e),
                ];
            }
        };
        if !src.is_dir() {
            let placed = !records.keys().is_empty();
            return vec![missing_source(ctx, &clone, &src, placed)];
        }
        let layouts = home.join("layouts");
        let layout_path = layouts.join(format!("{LAYOUT}.json"));
        if record_key(&records, &layout_path).is_some() && !layout_path.exists() {
            return vec![say_out(
                ctx,
                Kind::Info,
                format!(
                    "layout {LAYOUT} は前に作ったが、今は無い (逃げ道のキー ctrl-alt-shift-escape が退けた・手で外した) ので、mod も layout も置かない (外したまま。--force でも戻さない) → 戻すなら herdr-app do layout.clone --name {BASE} --as {LAYOUT} | Out-String (表示が {LAYOUT} に替わる) の後で dotfiles apply --steps herdr-app-pjp-spaces。逃げ道のキーで退けたなら、layouts\\{LAYOUT}.json.reset-<時刻> の名前を {LAYOUT}.json に戻してもよい"
                ),
            )];
        }
        if let Err(why) = check_mod(&src) {
            return vec![say_out(ctx, Kind::Manual, why)];
        }
        let base_path = layouts.join(format!("{BASE}.json"));
        if !base_path.is_file() {
            return vec![say_out(
                ctx,
                Kind::Manual,
                format!(
                    "同梱の layout {BASE} が無い ({}。herdr-app をまだ起こしていない) → herdr-app を一度起こしてから dotfiles apply --steps herdr-app-pjp-spaces (それまで mod も置かない)",
                    base_path.display()
                ),
            )];
        }
        let m = match list_mod(&root, MOD) {
            Ok(m) => m,
            Err(why) => return vec![say_out(ctx, Kind::Failed, why)],
        };
        let mods_dir = home.join("mods");
        let source = Source {
            root,
            prev: None,
            foreign_suffix: None,
            kinds: &[],
            skip_skills: Vec::new(),
            select: None,
            origin: "clone",
            absorb: "claude-skills の skills/pjp-hc-hub/herdr-app/mods/pjp-spaces",
            step: "herdr-app-pjp-spaces",
        };
        let mut w = Linker::new(source, mods_dir.clone(), mode, records);
        let mut keep = Keep::new();
        copy_mod(ctx, &mut w, &src, &m, &mods_dir, &mut keep);
        prune(ctx, &mut w, &mods_dir, &keep);
        let mod_ok = w.tally.errors == 0;
        let mut outcomes = w.finish(ctx, &record_path, None);
        if let Some(first) = outcomes.first_mut() {
            first.text = format!("mod {MOD}: {}", first.text);
        }
        ctx.say("");
        let mut layout = sync_layout(ctx, &mut w, &home, mod_ok);
        if mode.writes()
            && let Err(e) = w.records.save_if_changed()
        {
            let why = format!("記録を書けない: {} ({e})", record_path.display());
            layout = say_out(ctx, Kind::Failed, why);
        }
        outcomes.push(layout);
        outcomes
    }
}

/// 1 行出して、その行の結果にする (直すことのある行は頭に !!)。
fn say_out(ctx: &mut Ctx, kind: Kind, why: String) -> Outcome {
    if kind.needs_attention() {
        ctx.say(format!("!! {why}"));
    } else {
        ctx.say(&why);
    }
    Outcome::new(kind, why)
}

/// clone に mod が無いときの行。置いた記録が無ければ (claude-skills の PR の merge 前) 知らせるだけ、あれば置いたものに触らずに知らせる。
fn missing_source(ctx: &mut Ctx, clone: &Path, src: &Path, placed: bool) -> Outcome {
    if !clone.is_dir() {
        return say_out(
            ctx,
            Kind::Manual,
            format!(
                "claude-skills の clone が無い ({}) → bootstrap (Install-Bootstrap.ps1) が clone する",
                clone.display()
            ),
        );
    }
    if placed {
        return say_out(
            ctx,
            Kind::Manual,
            format!(
                "claude-skills の clone に {MOD} が無い ({})。前に置いた mod と layout {LAYOUT} には触らない (layout が mod を指している) → clone の branch と中身を確かめる。外すなら win/README.md の「herdr-app の印 (pjp-spaces)」の切り戻し",
                src.display()
            ),
        );
    }
    say_out(
        ctx,
        Kind::Info,
        format!(
            "claude-skills の clone に {MOD} がまだ無い ({}。claude-skills の PR の merge 前) → 何もしない (merge の後に clone を pull して dotfiles apply)",
            src.display()
        ),
    )
}

/// 置いてよい mod か: main.js があり、mod.json の place が none (herdr-app は初めて見た mod を、place に従って表示中の layout へ差し込む。
/// none なら layout が指す所にだけ出る)。
fn check_mod(src: &Path) -> Result<(), String> {
    if !src.join("main.js").is_file() {
        return Err(format!(
            "{MOD} に main.js が無い ({}) → 置かない。claude-skills の mod を確かめる",
            src.display()
        ));
    }
    let path = src.join("mod.json");
    let text = std::fs::read_to_string(&path).map_err(|e| {
        format!(
            "{MOD} の mod.json が読めない ({}: {e}) → 置かない",
            path.display()
        )
    })?;
    let v: serde_json::Value = serde_json::from_str(text.trim_start_matches('\u{feff}'))
        .map_err(|e| format!("{MOD} の mod.json が JSON として読めない ({e}) → 置かない"))?;
    match v.get("place").and_then(|p| p.as_str()) {
        Some("none") => Ok(()),
        other => Err(format!(
            "{MOD} の mod.json の place が none でない ({}) → 置かない (herdr-app は初めて見た mod を、place に従って表示中の layout へ差し込む)。claude-skills の mod を直す",
            other.unwrap_or("書いていない")
        )),
    }
}

/// パスを比べる要素 (区切りの `/` と `\`・重なった区切りを見ない。Windows は大文字小文字も見ない)。
fn path_parts(p: &Path) -> Vec<String> {
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

/// 記録の鍵のうち、`path` と同じ場所を指すもの (home を別の綴りで書いた記録も引く)。
fn record_key(records: &Records, path: &Path) -> Option<String> {
    let want = path_parts(path);
    records
        .keys()
        .into_iter()
        .find(|k| path_parts(Path::new(k)) == want)
}

/// layout の記録を今の綴りの鍵で書く (別の綴りの鍵は外す)。
fn set_record(w: &mut Linker, found: Option<&str>, key_now: &str, sha: &str) {
    if let Some(old) = found
        && old != key_now
    {
        w.records.remove(old);
    }
    w.records.set(key_now, sha);
}

/// layout `pjp-main` を揃え、その行を返す。`mod_ok` は mod を置けたか (置けなければ layout を作らない)。
fn sync_layout(ctx: &mut Ctx, w: &mut Linker, home: &Path, mod_ok: bool) -> Outcome {
    let layouts = home.join("layouts");
    let base_path = layouts.join(format!("{BASE}.json"));
    let dest = layouts.join(format!("{LAYOUT}.json"));
    let label = format!("layouts/{LAYOUT}.json");
    let base = match std::fs::read_to_string(&base_path) {
        Ok(text) => match OValue::parse(&text) {
            Ok(v) => v,
            Err(e) => {
                return say_out(
                    ctx,
                    Kind::Failed,
                    format!(
                        "同梱の layout {BASE} が JSON として読めない ({}: {e})",
                        base_path.display()
                    ),
                );
            }
        },
        Err(e) => {
            return say_out(
                ctx,
                Kind::Failed,
                format!(
                    "同梱の layout {BASE} が読めない ({}: {e})",
                    base_path.display()
                ),
            );
        }
    };
    let mut wanted = base;
    if point_to(&mut wanted, SHIPPED, MOD) == 0 {
        return say_out(
            ctx,
            Kind::Manual,
            format!(
                "同梱の layout {BASE} に {SHIPPED} を指す block (content.mod が {SHIPPED}) が無い (herdr-app の形が変わった) → {label} は前のまま。差し替える所を決め直す"
            ),
        );
    }
    match std::fs::read(&dest) {
        Ok(bytes) => match update_layout(ctx, w, &dest, &label, wanted, &bytes) {
            (o, _) if o.kind == Kind::Failed => o,
            (o, wrote) => annotate(home, o, wrote),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            create_layout(ctx, w, home, &dest, &label, wanted, mod_ok)
        }
        Err(e) => say_out(ctx, Kind::Failed, format!("{label} が読めない ({e})")),
    }
}

/// layout が無いとき (初めて。前に作って外したものは run が先に止める): main を clone して表示を替え、spaces を指す block を pjp-spaces に
/// 替えて書く。
fn create_layout(
    ctx: &mut Ctx,
    w: &mut Linker,
    home: &Path,
    dest: &Path,
    label: &str,
    wanted: OValue,
    mod_ok: bool,
) -> Outcome {
    let mode = w.mode;
    match shown_layout(home) {
        Ok(name) if name == BASE => {}
        Ok(name) => {
            return say_out(
                ctx,
                Kind::Info,
                format!(
                    "表示している layout が {name} ({BASE} でない) ので、{label} は作らない ({LAYOUT} は {BASE} を写して作り、写すと表示が替わる) → 使うなら {BASE} に戻して (ctrl-shift-l か herdr-app do layout.switch --name {BASE} | Out-String) から dotfiles apply --steps herdr-app-pjp-spaces"
                ),
            );
        }
        Err(why) => {
            return say_out(
                ctx,
                Kind::Failed,
                format!("表示している layout が分からない ({why}) ので、{label} は作らない"),
            );
        }
    }
    let exe = match locate(ctx, "herdr-app", HERDR_APP_OFFICIAL) {
        Ok(p) => p,
        Err(official) => {
            return say_out(
                ctx,
                Kind::Manual,
                format!(
                    "herdr-app が見つからない (PATH と {}) → herdr-app の手順 (Install-HerdrApp.ps1) で入れてから、{label} を作る",
                    official.display()
                ),
            );
        }
    };
    let todo = format!(
        "{label} (herdr-app do layout.clone で {BASE} を写して表示を {LAYOUT} に替え、{SHIPPED} を指す block を {MOD} に替える)"
    );
    match mode {
        Mode::Check => {
            ctx.say(format!("作る (apply で): {todo}"));
            return Outcome::new(
                Kind::Missing,
                format!(
                    "layout {LAYOUT} が無い → apply で {BASE} を写して作り、表示を {LAYOUT} に替える (画面が替わる)"
                ),
            );
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] 作る: {todo}"));
            return Outcome::new(
                Kind::Missing,
                format!(
                    "[dry-run] layout {LAYOUT} を作り、表示を {LAYOUT} に替える (画面が替わる)"
                ),
            );
        }
        Mode::Apply { .. } => {}
    }
    if !mod_ok || !home.join("mods").join(MOD).join("main.js").is_file() {
        return say_out(
            ctx,
            Kind::Failed,
            format!("mod {MOD} を置けていないので、{label} は作らない (上の mod の行を見る)"),
        );
    }
    ctx.say(format!(
        "表示する layout を {BASE} から {LAYOUT} に替えます (herdr-app do layout.clone。画面の sidebar の spaces が {MOD} になる)"
    ));
    let args = format!("{{\"name\":\"{BASE}\",\"as\":\"{LAYOUT}\"}}");
    let r = ctx.sys.run(
        &CommandSpec::new(&exe)
            .arg("do")
            .arg("layout.clone")
            .arg(&args)
            .timeout(Duration::from_secs(DO_SECS)),
        &mut |_| {},
    );
    for l in &r.output {
        ctx.say(format!("  {l}"));
    }
    if r.code() != Some(0) {
        return say_out(
            ctx,
            Kind::Failed,
            format!(
                "herdr-app do layout.clone が落ちた ({:?}: {}) → herdr-app の窓が開いているか確かめて dotfiles apply --steps herdr-app-pjp-spaces",
                r.exit,
                r.output.join(" / ")
            ),
        );
    }
    let Some(cloned) = wait_for_layout(dest) else {
        return say_out(
            ctx,
            Kind::Failed,
            format!(
                "herdr-app do layout.clone の後に {label} ができない (表示は {LAYOUT} に替わったかもしれない) → herdr-app status | Out-String を見てから dotfiles apply --steps herdr-app-pjp-spaces"
            ),
        );
    };
    let desired = with_cloned_from(wanted, &cloned).to_pretty();
    if let Err(e) = fsutil::write_atomic(dest, desired.as_bytes()) {
        return say_out(
            ctx,
            Kind::Failed,
            format!(
                "{label} を書けない ({e})。表示は {SHIPPED} のままの {LAYOUT} に替わった → dotfiles apply --steps herdr-app-pjp-spaces で書き直す"
            ),
        );
    }
    let found = record_key(&w.records, dest);
    set_record(
        w,
        found.as_deref(),
        &dest.to_string_lossy(),
        &fsutil::sha256_bytes(desired.as_bytes()),
    );
    ctx.say(format!(
        "作りました: {label} (表示を {LAYOUT} に替えた。戻すなら ctrl-shift-l か herdr-app do layout.switch --name {BASE} | Out-String)"
    ));
    Outcome::new(
        Kind::Ok,
        format!("layout {LAYOUT} を作り、表示を {LAYOUT} に替えた ({SHIPPED} → {MOD})"),
    )
}

/// layout があるとき: 今の main に同じ差し替えをした形 (cloned_from は今のファイルのまま) にそろえ、行と、書いたかを返す。runner が書いたまま
/// (記録どおり) なら書き直し、spaces を pjp-spaces に替えると今の形になるもの (clone の写し・保存し直したもの) は記録によらず引き取り、
/// ほかは衝突 (`--force` で上書き)。
fn update_layout(
    ctx: &mut Ctx,
    w: &mut Linker,
    dest: &Path,
    label: &str,
    wanted: OValue,
    bytes: &[u8],
) -> (Outcome, bool) {
    let mode = w.mode;
    let key_now = dest.to_string_lossy().into_owned();
    let found = record_key(&w.records, dest);
    let have = fsutil::sha256_bytes(bytes);
    let recorded = found
        .as_deref()
        .and_then(|k| w.records.get(k))
        .map(str::to_string);
    let current = OValue::parse(&String::from_utf8_lossy(bytes)).ok();
    let desired_value = match &current {
        Some(c) => with_cloned_from(wanted, c),
        None => wanted,
    };
    let desired = desired_value.to_pretty();
    let want = fsutil::sha256_bytes(desired.as_bytes());
    if have == want {
        if mode.writes()
            && (recorded.as_deref() != Some(want.as_str())
                || found.as_deref() != Some(key_now.as_str()))
        {
            set_record(w, found.as_deref(), &key_now, &want);
        }
        let o = Outcome::new(
            Kind::Ok,
            format!("layout {LAYOUT} は今の {BASE} と同じ形 ({SHIPPED} → {MOD})"),
        );
        return (o, false);
    }
    let reason = match &current {
        // runner が書いたまま: main (か差し替え方) が変わった
        Some(c) if recorded.as_deref() == Some(have.as_str()) => Some(format!(
            "同梱の {BASE} から作り直す。{}",
            changed_nodes(c, &desired_value)
        )),
        // 差し替えると今の形になる: 人が clone し直した (逃げ道のキーの後など)・clone の後で書けなかった・保存し直した
        Some(c) if same(&pointed(c), &desired_value) => Some(if same(c, &desired_value) {
            "中身は同じで書き方だけが違う (保存し直された) ので、runner の形に書き直す".to_string()
        } else {
            format!(
                "{BASE} の写し (layout.clone) を引き取り、{SHIPPED} を指す block を {MOD} に替える"
            )
        }),
        _ if mode.force() => Some("--force で上書き (Windows 側の中身は残らない)".to_string()),
        _ => None,
    };
    let Some(reason) = reason else {
        let why = if recorded.is_some() {
            "Windows 側で変わった"
        } else {
            "置いた記録が無い"
        };
        let o = say_out(
            ctx,
            Kind::Manual,
            format!(
                "{label} の中身が違う ({why}) → 残すなら別の名前の layout に写して使い (herdr-app do layout.clone --name {LAYOUT} --as <名前> | Out-String)、{BASE} から作り直すなら dotfiles apply --steps herdr-app-pjp-spaces --force"
            ),
        );
        return (o, false);
    };
    match mode {
        Mode::Check => {
            ctx.say(format!("上書きする (apply で): {label} ({reason})"));
            let o = Outcome::new(Kind::Fix, format!("layout {LAYOUT} を書き直す ({reason})"));
            (o, false)
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] 上書きする: {label} ({reason})"));
            let o = Outcome::new(
                Kind::Fix,
                format!("[dry-run] layout {LAYOUT} を書き直す ({reason})"),
            );
            (o, false)
        }
        Mode::Apply { .. } => match fsutil::write_atomic(dest, desired.as_bytes()) {
            Ok(()) => {
                set_record(w, found.as_deref(), &key_now, &want);
                ctx.say(format!("上書きしました: {label} ({reason})"));
                let o = Outcome::new(Kind::Ok, format!("layout {LAYOUT} を書き直した ({reason})"));
                (o, true)
            }
            Err(e) => (
                say_out(ctx, Kind::Failed, format!("{label} を書けない ({e})")),
                false,
            ),
        },
    }
}

/// layout の行に ※ を添える: 表示が pjp-main でなければ替え方 (runner は作るとき (clone) のほかは表示を替えない)。layout を書かなかった実行で
/// は、herdr-app が layout を読めなかった理由のファイルがあれば、その 1 行目 (書いた実行では前の中身のものなので見ない)。
fn annotate(home: &Path, mut o: Outcome, wrote: bool) -> Outcome {
    let shown = shown_layout(home).ok();
    if let Some(name) = shown.as_deref()
        && name != LAYOUT
    {
        o = o.note(format!(
            "表示している layout は {name}。{MOD} の印を出すなら ctrl-shift-l か herdr-app do layout.switch --name {LAYOUT} | Out-String"
        ));
    }
    if !wrote {
        for path in error_files(home, shown.as_deref() == Some(LAYOUT)) {
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let first: String = text
                .lines()
                .map(str::trim)
                .find(|l| !l.is_empty())
                .unwrap_or("")
                .chars()
                .take(200)
                .collect();
            o = o.note(format!(
                "herdr-app が layout を読めなかった ({}: {first}) → herdr-app status | Out-String で見る (herdr-app は前に読めた形のまま動く)",
                path.display()
            ));
        }
    }
    o
}

/// herdr-app が layout を読めなかったときに理由を書くファイル (AGENTS.md の「`<name>.error` (`layout.error`, …)」)。置き場所は確かめていない
/// ので、layout の隣の `pjp-main.error` と、pjp-main を表示しているときは home の `layout.error` を見る。
fn error_files(home: &Path, shown_is_ours: bool) -> Vec<PathBuf> {
    let mut files = vec![home.join("layouts").join(format!("{LAYOUT}.error"))];
    if shown_is_ours {
        files.push(home.join("layout.error"));
    }
    files
}

/// 表示している layout の名前 (herdr-app の home の shared.json の `layout`。ファイルかキーが無ければ既定の main)。
fn shown_layout(home: &Path) -> Result<String, String> {
    let path = home.join("shared.json");
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(BASE.to_string()),
        Err(e) => return Err(format!("{} が読めない ({e})", path.display())),
    };
    let v: serde_json::Value = serde_json::from_str(text.trim_start_matches('\u{feff}'))
        .map_err(|e| format!("{} が JSON として読めない ({e})", path.display()))?;
    match v.get("layout") {
        None | Some(serde_json::Value::Null) => Ok(BASE.to_string()),
        Some(serde_json::Value::String(s)) => Ok(s.clone()),
        Some(other) => Err(format!(
            "{} の layout が文字列でない ({other})",
            path.display()
        )),
    }
}

/// herdr-app が clone で書いた layout を読む (JSON として読めるまで少し待つ)。
fn wait_for_layout(path: &Path) -> Option<OValue> {
    let start = Instant::now();
    loop {
        if let Ok(text) = std::fs::read_to_string(path)
            && let Ok(v) = OValue::parse(&text)
        {
            return Some(v);
        }
        if start.elapsed() >= CLONE_WAIT {
            return None;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// `wanted` に、今の layout の `cloned_from` (herdr-app が clone で残したもの) を写す。無ければ足さない。
fn with_cloned_from(mut wanted: OValue, current: &OValue) -> OValue {
    if let Some(cf) = current.get("cloned_from") {
        wanted.set("cloned_from", cf.clone());
    }
    wanted
}

/// `from` を指す block (`content` の `mod` が `from`) を `to` に替え、替えた数を返す (木のどこにあっても。props などはそのまま)。
fn point_to(v: &mut OValue, from: &str, to: &str) -> usize {
    match v {
        OValue::Object(entries) => {
            let mut n = 0;
            for (k, child) in entries.iter_mut() {
                if k == "content"
                    && let OValue::Object(content) = child
                {
                    for (ck, cv) in content.iter_mut() {
                        if ck == "mod" && matches!(cv, OValue::String(s) if s == from) {
                            *cv = OValue::String(to.to_string());
                            n += 1;
                        }
                    }
                }
                n += point_to(child, from, to);
            }
            n
        }
        OValue::Array(items) => items.iter_mut().map(|i| point_to(i, from, to)).sum(),
        _ => 0,
    }
}

/// spaces を指す block を pjp-spaces に替えた写し。
fn pointed(v: &OValue) -> OValue {
    let mut p = v.clone();
    point_to(&mut p, SHIPPED, MOD);
    p
}

/// JSON の値が同じか (object はキーの順を見ない。数は値で比べ、herdr-app が書く `268.0` と main の `268` を同じにする)。
fn same(a: &OValue, b: &OValue) -> bool {
    match (a, b) {
        (OValue::Number(x), OValue::Number(y)) => {
            x == y || matches!((x.as_f64(), y.as_f64()), (Some(p), Some(q)) if p == q)
        }
        (OValue::Array(x), OValue::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (OValue::Object(x), OValue::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| b.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

/// 2 つの layout の node (id を持つ object) の違いを 1 行で (変わった・増えた・消えた id)。
fn changed_nodes(old: &OValue, new: &OValue) -> String {
    let (a, b) = (nodes(old), nodes(new));
    let changed: Vec<&str> = b
        .iter()
        .filter(|(id, v)| a.get(*id).is_some_and(|w| !same(v, w)))
        .map(|(id, _)| id.as_str())
        .collect();
    let added: Vec<&str> = b
        .keys()
        .filter(|id| !a.contains_key(*id))
        .map(String::as_str)
        .collect();
    let removed: Vec<&str> = a
        .keys()
        .filter(|id| !b.contains_key(*id))
        .map(String::as_str)
        .collect();
    let mut parts = Vec::new();
    for (what, ids) in [
        ("変わった", changed),
        ("増えた", added),
        ("消えた", removed),
    ] {
        if !ids.is_empty() {
            parts.push(format!("{what} node: {}", ids.join("・")));
        }
    }
    if parts.is_empty() {
        "node の中身は同じ (書き方だけ)".to_string()
    } else {
        parts.join(" / ")
    }
}

/// layout の木の node を、id → 子 (`children`・`floating`) を除いた中身で集める。
fn nodes(v: &OValue) -> BTreeMap<String, OValue> {
    fn walk(v: &OValue, out: &mut BTreeMap<String, OValue>) {
        match v {
            OValue::Object(entries) => {
                if let Some(OValue::String(id)) = v.get("id") {
                    let own = entries
                        .iter()
                        .filter(|(k, _)| k != "children" && k != "floating")
                        .cloned()
                        .collect();
                    out.insert(id.clone(), OValue::Object(own));
                }
                for (k, child) in entries {
                    if k == "children" || k == "floating" {
                        walk(child, out);
                    }
                }
            }
            OValue::Array(items) => items.iter().for_each(|i| walk(i, out)),
            _ => {}
        }
    }
    let mut out = BTreeMap::new();
    walk(v, &mut out);
    out
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 初めて: check と dry-run は mod も layout も「無い」(3 の種類) で何も書かず、herdr-app も打たない。apply は mod を記録つきで置き、
    //!   `herdr-app do layout.clone {"name":"main","as":"pjp-main"}` を 1 回だけ打ち、clone の写しを「main の spaces を pjp-spaces に替えた形 +
    //!   cloned_from」で書き直して記録する。2 回目は揃っていて、herdr-app を打たない。herdr-app が書くファイルは配らない
    //! - clone に mod がまだ無ければ知らせるだけ (· で、何も書かない)。置いた後で無くなったら、置いたものに触らずに ⚠。clone が無ければ ⚠
    //! - mod.json の place が none でない・main.js が無い mod は置かない (⚠)
    //! - 表示が main でなければ layout を作らない (·)。herdr-app が無い・同梱の main が無い・main に spaces の block が無いときは ⚠ で、
    //!   herdr-app を打たない。clone が落ちたら ⚠ で、記録を作らない (次の apply で作り直せる)
    //! - main が変わったら check が変わった node を出し、apply が書き直す (clone し直さない・cloned_from は残す)
    //! - 手で直した layout は衝突で残し、--force で上書きする。main の写し (人が clone した・し直した) と、書き方だけ違うもの (CRLF で保存し
    //!   直した) は、記録によらず引き取って差し替える
    //! - 作った layout が無くなったら (逃げ道のキー・手で外した) mod も layout も置かない (·)。--force でも戻さず、herdr-app を打たない。人が
    //!   clone し直すか、退けたファイルの名前を戻せば揃う。同梱の main が無ければ mod も置かない
    //! - 表示が pjp-main でなければ ※ で替え方を添える。書かなかった実行では、herdr-app が layout を読めなかった理由のファイルも ※ で添える。
    //!   元から消えたファイルは記録どおりなら消す。mod.json を先に置く
    //! - layout の記録は home の綴りの違いを見ずに引く (作り直さない・外したままも保つ。記録の鍵は今の綴りに寄る)
    //! - 差し替え (point_to) と node の違い (changed_nodes)・数を値で比べる (same)
    //! - dotfiles の repo に pjp-spaces を置いていない (claude-skills のもの。herdr-app-mods と二重に配らない)

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::{Exit, RunResult};
    use crate::testutil::{FakeSys, TempDir};

    const MAIN_JS: &str = "// pjp-spaces\n";
    const MOD_JSON: &str = "{ \"place\": \"none\", \"title\": \"Spaces\" }\n";
    /// 同梱の main を縮めたもの (sidebar の spaces・agents と、pane の header の mod)
    const BASE_JSON: &str = r#"{
  "id": "root",
  "type": "row",
  "titlebar": "none",
  "children": [
    {
      "id": "sidebar",
      "type": "column",
      "size": { "px": 268 },
      "children": [
        { "id": "spaces", "type": "block", "size": { "weight": 1 }, "content": { "mod": "spaces" } },
        { "id": "agents", "type": "block", "content": { "mod": "agents" } }
      ]
    },
    {
      "id": "main",
      "type": "block",
      "content": { "tab": "active", "pane": { "header": { "content": { "mod": "pane" } } } }
    }
  ]
}
"#;
    const CLONE_ARGS: &str = "do layout.clone {\"name\":\"main\",\"as\":\"pjp-main\"}";
    const SRC: &str = "claude-skills/skills/pjp-hc-hub/herdr-app/mods/pjp-spaces";

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("herdr-app-pjp-spaces");
            t.write("dotfiles/README.md", "dotfiles\n");
            t.write(&format!("{SRC}/main.js"), MAIN_JS);
            t.write(&format!("{SRC}/mod.json"), MOD_JSON);
            t.write("home/.config/herdr-app/layouts/main.json", BASE_JSON);
            let e = Env { t };
            e.show("main");
            e
        }

        /// 既定の home の下のパス
        fn home(&self, rel: &str) -> PathBuf {
            join_segments(
                &self.t.path().join("home"),
                &format!(".config/herdr-app/{rel}"),
            )
        }

        fn read(&self, rel: &str) -> String {
            std::fs::read_to_string(self.home(rel)).unwrap()
        }

        fn layout(&self) -> OValue {
            OValue::parse(&self.read("layouts/pjp-main.json")).unwrap()
        }

        /// 表示している layout (shared.json の layout) を替える (herdr-app の ctrl-shift-l の代わり)
        fn show(&self, name: &str) {
            self.t.write(
                "home/.config/herdr-app/shared.json",
                &format!("{{\"layout\":\"{name}\",\"space.colors\":{{}}}}\n"),
            );
        }

        fn record(&self) -> serde_json::Map<String, serde_json::Value> {
            let text =
                std::fs::read_to_string(self.t.path().join("state").join(RECORD_FILE)).unwrap();
            match serde_json::from_str(&text).unwrap() {
                serde_json::Value::Object(m) => m,
                other => panic!("{other:?}"),
            }
        }

        fn layout_key(&self) -> String {
            self.home("layouts/pjp-main.json")
                .to_string_lossy()
                .into_owned()
        }

        /// herdr-app の layout.clone を真似る偽の口 (herdr-app は PATH にある)
        fn sys(&self) -> FakeSys {
            let home = self.home("");
            FakeSys::new(move |c| fake_clone(&home, c)).with_program("herdr-app", "herdr-app")
        }

        fn run_with(&self, mode: Mode, sys: &FakeSys) -> (Vec<Outcome>, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys,
                    out: &mut out,
                };
                HerdrAppPjpSpaces.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }

        /// 流して、結果・出力・打ったコマンドを返す
        fn run(&self, mode: Mode) -> (Vec<Outcome>, String, Vec<String>) {
            let sys = self.sys();
            let (o, out) = self.run_with(mode, &sys);
            (o, out, sys.call_args())
        }
    }

    /// herdr-app の `do layout.clone` の偽物: main の写しに cloned_from を足して書き (数は herdr-app が書くように小数、改行は CRLF)、
    /// 表示を pjp-main に替える。ほかのコマンドは打たない約束なので落とす
    fn fake_clone(home: &Path, c: &CommandSpec) -> RunResult {
        assert_eq!(
            c.args_lossy().join(" "),
            CLONE_ARGS,
            "打つのは layout.clone だけ"
        );
        let base = std::fs::read_to_string(home.join("layouts").join("main.json")).unwrap();
        let mut v = OValue::parse(&base).unwrap();
        floats(&mut v);
        v.set(
            "cloned_from",
            OValue::parse(r#"{"name":"main","version":"0.1.15"}"#).unwrap(),
        );
        std::fs::write(
            home.join("layouts").join("pjp-main.json"),
            v.to_pretty().replace('\n', "\r\n"),
        )
        .unwrap();
        std::fs::write(home.join("shared.json"), "{\"layout\":\"pjp-main\"}\n").unwrap();
        RunResult {
            exit: Exit::Code(0),
            output: vec!["{}".to_string()],
        }
    }

    /// 人が打つ `herdr-app do layout.clone` (偽の口に直に渡す)
    fn clone_spec() -> CommandSpec {
        CommandSpec::new("herdr-app")
            .arg("do")
            .arg("layout.clone")
            .arg("{\"name\":\"main\",\"as\":\"pjp-main\"}")
    }

    fn floats(v: &mut OValue) {
        match v {
            OValue::Number(n) => {
                if let Some(f) = n.as_f64().and_then(serde_json::Number::from_f64) {
                    *n = f;
                }
            }
            OValue::Array(items) => items.iter_mut().for_each(floats),
            OValue::Object(entries) => entries.iter_mut().for_each(|(_, v)| floats(v)),
            _ => {}
        }
    }

    fn kinds(o: &[Outcome]) -> Vec<Kind> {
        o.iter().map(|x| x.kind).collect()
    }

    /// layout の中の、ある id の node の content.mod
    fn mod_of(layout: &OValue, id: &str) -> Option<String> {
        let found = nodes(layout).remove(id)?;
        match found.get("content")?.get("mod")? {
            OValue::String(s) => Some(s.clone()),
            _ => None,
        }
    }

    const APPLY: Mode = Mode::Apply { force: false };
    const FORCE: Mode = Mode::Apply { force: true };

    #[test]
    fn installs_the_mod_and_clones_the_layout_once() {
        let e = Env::new();
        // herdr-app が mod のフォルダに書くファイルは、元にあっても配らない
        e.t.write(&format!("{SRC}/gpui-kit.d.ts"), "declare module;\n");
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (o, out, calls) = e.run(mode);
            assert_eq!(
                kinds(&o),
                vec![Kind::Missing, Kind::Missing],
                "{mode:?} {o:?}\n{out}"
            );
            assert!(
                calls.is_empty(),
                "{mode:?} は herdr-app を打たない: {calls:?}"
            );
            assert!(!e.home("mods").exists(), "{mode:?} は書かない");
            assert!(!e.home("layouts/pjp-main.json").exists());
            assert!(o[1].text.contains("画面が替わる"), "{o:?}");
        }
        let (o, out, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("mod pjp-spaces: 追加 2 / 更新 0 / 削除 0 / 同じ 0 / 飛ばした 0"),
            "{o:?}"
        );
        assert_eq!(calls, vec![CLONE_ARGS.to_string()]);
        assert!(
            out.contains("表示する layout を main から pjp-main に替えます"),
            "{out}"
        );
        let at = |s: &str| out.find(s).unwrap_or_else(|| panic!("{s} が無い\n{out}"));
        assert!(
            at("コピーしました: mods/pjp-spaces/mod.json")
                < at("コピーしました: mods/pjp-spaces/main.js"),
            "mod.json を先に置く"
        );
        assert_eq!(e.read("mods/pjp-spaces/main.js"), MAIN_JS);
        assert_eq!(e.read("mods/pjp-spaces/mod.json"), MOD_JSON);
        assert!(!e.home("mods/pjp-spaces/gpui-kit.d.ts").exists());
        // clone の写しを、main の spaces を pjp-spaces に替えた形 + cloned_from に書き直す (数は main のまま)
        let layout = e.layout();
        assert_eq!(mod_of(&layout, "spaces").as_deref(), Some("pjp-spaces"));
        assert_eq!(mod_of(&layout, "agents").as_deref(), Some("agents"));
        let mut expected = OValue::parse(BASE_JSON).unwrap();
        assert_eq!(point_to(&mut expected, "spaces", "pjp-spaces"), 1);
        expected.set(
            "cloned_from",
            OValue::parse(r#"{"name":"main","version":"0.1.15"}"#).unwrap(),
        );
        assert_eq!(layout, expected);
        assert_eq!(e.read("layouts/pjp-main.json"), expected.to_pretty());
        assert_eq!(
            e.read("layouts/main.json"),
            BASE_JSON,
            "同梱の main は直さない"
        );
        let rec = e.record();
        assert_eq!(rec.len(), 3, "{rec:?}");
        assert_eq!(
            rec.get(&e.layout_key()).and_then(|v| v.as_str()),
            Some(fsutil::sha256_bytes(expected.to_pretty().as_bytes()).as_str())
        );
        // 2 回目は揃っていて、herdr-app を打たない
        for mode in [Mode::Check, APPLY] {
            let (o, out, calls) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{mode:?} {o:?}\n{out}");
            assert!(calls.is_empty(), "{calls:?}");
            assert!(o[1].notes.is_empty(), "表示は pjp-main: {o:?}");
        }
    }

    #[test]
    fn waits_for_claude_skills_to_carry_the_mod() {
        let e = Env::new();
        std::fs::remove_dir_all(e.t.path().join(SRC)).unwrap();
        for mode in [Mode::Check, APPLY] {
            let (o, out, calls) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Info], "{mode:?} {o:?}\n{out}");
            assert!(o[0].text.contains("まだ無い"), "{o:?}");
            assert!(calls.is_empty());
        }
        assert!(!e.home("mods").exists());
        assert!(!e.t.path().join("state").join(RECORD_FILE).exists());
        // clone そのものが無い
        std::fs::remove_dir_all(e.t.path().join("claude-skills")).unwrap();
        let (o, _, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Manual], "{o:?}");
        assert!(o[0].text.contains("clone が無い"), "{o:?}");
    }

    #[test]
    fn keeps_placed_files_when_the_mod_leaves_the_clone() {
        let e = Env::new();
        e.run(APPLY);
        std::fs::remove_dir_all(e.t.path().join(SRC)).unwrap();
        for mode in [Mode::Check, FORCE] {
            let (o, out, calls) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Manual], "{mode:?} {o:?}\n{out}");
            assert!(o[0].text.contains("前に置いた mod と layout"), "{o:?}");
            assert!(calls.is_empty());
        }
        assert_eq!(e.read("mods/pjp-spaces/main.js"), MAIN_JS);
        assert!(e.home("layouts/pjp-main.json").is_file());
    }

    #[test]
    fn refuses_mods_that_would_dock_or_cannot_load() {
        let e = Env::new();
        e.t.write(&format!("{SRC}/mod.json"), "{ \"place\": \"left\" }\n");
        let (o, out, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Manual], "{o:?}\n{out}");
        assert!(o[0].text.contains("place が none でない (left)"), "{o:?}");
        assert!(calls.is_empty());
        assert!(!e.home("mods").exists());
        e.t.write(&format!("{SRC}/mod.json"), MOD_JSON);
        std::fs::remove_file(e.t.path().join(SRC).join("main.js")).unwrap();
        let (o, _, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Manual], "{o:?}");
        assert!(o[0].text.contains("main.js が無い"), "{o:?}");
        assert!(!e.home("mods").exists());
    }

    #[test]
    fn does_not_switch_away_from_another_layout() {
        let e = Env::new();
        e.show("win98");
        let (o, out, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Info], "{o:?}\n{out}");
        assert!(o[1].text.contains("表示している layout が win98"), "{o:?}");
        assert!(calls.is_empty(), "{calls:?}");
        assert!(!e.home("layouts/pjp-main.json").exists());
        assert_eq!(e.read("mods/pjp-spaces/main.js"), MAIN_JS, "mod は置く");
        // main に戻せば次の apply で作る
        e.show("main");
        let (o, _, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}");
        assert_eq!(calls, vec![CLONE_ARGS.to_string()]);
    }

    #[test]
    fn needs_herdr_app_and_its_main_layout() {
        let e = Env::new();
        // herdr-app が PATH にも公式の置き場所にも無い
        let sys = FakeSys::new(|_| unreachable!("打たない"));
        let (o, out) = e.run_with(APPLY, &sys);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}\n{out}");
        assert!(o[1].text.contains("herdr-app が見つからない"), "{o:?}");
        // 同梱の main に spaces の block が無い (形が変わった)
        e.t.write(
            "home/.config/herdr-app/layouts/main.json",
            &BASE_JSON.replace("\"spaces\" }", "\"other\" }"),
        );
        let (o, _, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(o[1].text.contains("spaces を指す block"), "{o:?}");
        assert!(calls.is_empty());
        // 同梱の main が無い (herdr-app をまだ起こしていない): mod も置かない
        let e = Env::new();
        std::fs::remove_file(e.home("layouts/main.json")).unwrap();
        for mode in [Mode::Check, APPLY] {
            let (o, out, calls) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Manual], "{mode:?} {o:?}\n{out}");
            assert!(o[0].text.contains("同梱の layout main が無い"), "{o:?}");
            assert!(calls.is_empty());
        }
        assert!(
            !e.home("mods").exists(),
            "herdr-app の home に mod を作らない"
        );
        assert!(!e.home("layouts/pjp-main.json").exists());
    }

    #[test]
    fn failed_clone_leaves_no_layout_record() {
        let e = Env::new();
        let sys = FakeSys::new(|_| RunResult {
            exit: Exit::Code(1),
            output: vec!["{ \"error\": \"Herdr isn't running\" }".to_string()],
        })
        .with_program("herdr-app", "herdr-app");
        let (o, out) = e.run_with(APPLY, &sys);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Failed], "{o:?}\n{out}");
        assert!(o[1].text.contains("Herdr isn't running"), "{o:?}");
        assert!(!e.record().contains_key(&e.layout_key()));
        // 窓を開いて流し直せば作る (前に作った記録が無いので)
        let (o, _, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}");
        assert_eq!(calls, vec![CLONE_ARGS.to_string()]);
    }

    #[test]
    fn follows_a_changed_main_layout() {
        let e = Env::new();
        e.run(APPLY);
        // herdr-app を上げて main が変わった: sidebar の幅と、新しい block
        let changed = BASE_JSON.replace("\"px\": 268", "\"px\": 300").replace(
            "{ \"id\": \"agents\"",
            "{ \"id\": \"hint\", \"type\": \"block\" },\n        { \"id\": \"agents\"",
        );
        e.t.write("home/.config/herdr-app/layouts/main.json", &changed);
        let (o, out, calls) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Fix], "{o:?}\n{out}");
        assert!(
            o[1].text
                .contains("変わった node: sidebar / 増えた node: hint"),
            "{o:?}"
        );
        assert!(calls.is_empty());
        let (o, out, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(calls.is_empty(), "clone し直さない: {calls:?}");
        let layout = e.layout();
        assert!(nodes(&layout).contains_key("hint"));
        assert_eq!(mod_of(&layout, "spaces").as_deref(), Some("pjp-spaces"));
        assert_eq!(
            layout.get("cloned_from"),
            Some(&OValue::parse(r#"{"name":"main","version":"0.1.15"}"#).unwrap()),
            "cloned_from は残す"
        );
        let (o, _, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}");
    }

    #[test]
    fn hand_edited_layout_conflicts_until_forced() {
        let e = Env::new();
        e.run(APPLY);
        let mut edited = e.layout();
        edited.set("theme", OValue::String("graphite".into()));
        std::fs::write(e.home("layouts/pjp-main.json"), edited.to_pretty()).unwrap();
        for mode in [Mode::Check, APPLY] {
            let (o, out, _) = e.run(mode);
            assert_eq!(
                kinds(&o),
                vec![Kind::Ok, Kind::Manual],
                "{mode:?} {o:?}\n{out}"
            );
            assert!(
                o[1].text.contains("中身が違う (Windows 側で変わった)")
                    && o[1].text.contains("--force"),
                "{o:?}"
            );
        }
        assert_eq!(e.layout(), edited, "衝突したら書かない");
        let (o, out, calls) = e.run(FORCE);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(calls.is_empty());
        assert_eq!(e.layout().get("theme"), None);
    }

    #[test]
    fn adopts_clones_and_resaves_of_main() {
        let e = Env::new();
        // 指揮役が手で layout.clone した (spaces のまま。記録が無い)
        fake_clone(&e.home(""), &clone_spec());
        let (o, out, calls) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Missing, Kind::Fix], "{o:?}\n{out}");
        assert!(
            o[1].text.contains("main の写し (layout.clone) を引き取り"),
            "{o:?}"
        );
        assert!(calls.is_empty());
        let (o, _, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}");
        assert!(calls.is_empty());
        assert_eq!(mod_of(&e.layout(), "spaces").as_deref(), Some("pjp-spaces"));
        assert!(e.record().contains_key(&e.layout_key()));
        // 記録があっても、中身が同じで書き方だけ違う (CRLF で保存し直した) なら書き直す
        let text = e.read("layouts/pjp-main.json");
        std::fs::write(e.home("layouts/pjp-main.json"), text.replace('\n', "\r\n")).unwrap();
        let (o, out, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(o[1].text.contains("書き方だけが違う"), "{o:?}");
        assert_eq!(e.read("layouts/pjp-main.json"), text);
        // 記録があっても、人が clone し直した (spaces のまま) なら引き取る
        fake_clone(&e.home(""), &clone_spec());
        let (o, out, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(o[1].text.contains("引き取り"), "{o:?}");
        assert!(calls.is_empty());
        assert_eq!(e.read("layouts/pjp-main.json"), text);
    }

    #[test]
    fn removed_layout_stays_removed_even_with_force() {
        let e = Env::new();
        e.run(APPLY);
        // 切り戻し: 表示を main に戻し、配ったファイルを外す
        e.show("main");
        std::fs::remove_file(e.home("layouts/pjp-main.json")).unwrap();
        std::fs::remove_dir_all(e.home("mods/pjp-spaces")).unwrap();
        for mode in [Mode::Check, APPLY, FORCE] {
            let (o, out, calls) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Info], "{mode:?} {o:?}\n{out}");
            assert!(
                o[0].text.contains("mod も layout も置かない")
                    && o[0].text.contains("--force でも戻さない"),
                "{o:?}"
            );
            assert!(calls.is_empty(), "{mode:?} は表示を替えない: {calls:?}");
        }
        assert!(!e.home("layouts/pjp-main.json").exists());
        assert!(!e.home("mods/pjp-spaces").exists(), "外したままにする");
        // 戻す: 人が main を clone し直し (表示が替わる)、apply が mod を置いて差し替える (runner は clone を打たない)
        fake_clone(&e.home(""), &clone_spec());
        let (o, out, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("追加 2"), "{o:?}");
        assert!(
            o[1].text.contains("main の写し (layout.clone) を引き取り"),
            "{o:?}"
        );
        assert!(calls.is_empty(), "{calls:?}");
        assert_eq!(mod_of(&e.layout(), "spaces").as_deref(), Some("pjp-spaces"));
    }

    #[test]
    fn escape_hatch_file_can_be_renamed_back() {
        let e = Env::new();
        e.run(APPLY);
        // 逃げ道のキー: 表示中の layout を退けて main に戻す
        let reset = e.home("layouts/pjp-main.json.reset-20261117T2300");
        std::fs::rename(e.home("layouts/pjp-main.json"), &reset).unwrap();
        e.show("main");
        let (o, _, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Info], "{o:?}");
        assert!(calls.is_empty());
        // 名前を戻せば、記録どおりの中身として揃う (表示は替えない。※ で替え方を添える)
        std::fs::rename(&reset, e.home("layouts/pjp-main.json")).unwrap();
        let (o, out, calls) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(calls.is_empty());
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("表示している layout は main。")),
            "{o:?}"
        );
    }

    /// 同じ home を別の綴りで書いても (HERDR_APP_HOME を / で書いた Windows など)、layout の記録を引く (作り直さず、外したままも保つ)
    #[test]
    fn layout_record_follows_the_home_spelling() {
        let e = Env::new();
        let plain = e.home("").to_string_lossy().into_owned();
        let other = if cfg!(windows) {
            plain.replace('\\', "/")
        } else {
            plain.replacen("/home/", "//home/", 1)
        };
        assert_ne!(plain, other);
        let sys = |h: &str| {
            let home = e.home("");
            FakeSys::new(move |c| fake_clone(&home, c))
                .with_program("herdr-app", "herdr-app")
                .with_env("HERDR_APP_HOME", h)
        };
        let (o, out) = e.run_with(APPLY, &sys(&plain));
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        let s = sys(&other);
        let (o, out) = e.run_with(APPLY, &s);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(s.call_args().is_empty(), "作り直さない");
        let rec = e.record();
        let layouts: Vec<&String> = rec
            .keys()
            .filter(|k| k.ends_with("pjp-main.json"))
            .collect();
        assert_eq!(layouts.len(), 1, "{rec:?}");
        assert!(
            layouts[0].starts_with(&other),
            "記録の鍵は今の綴りに寄る: {rec:?}"
        );
        // 外した後も、別の綴りで外したままと分かる
        std::fs::remove_file(e.home("layouts/pjp-main.json")).unwrap();
        e.show("main");
        let s = sys(&plain);
        let (o, out) = e.run_with(APPLY, &s);
        assert_eq!(kinds(&o), vec![Kind::Info], "{o:?}\n{out}");
        assert!(s.call_args().is_empty());
    }

    #[test]
    fn notes_layout_errors_only_when_not_written() {
        let e = Env::new();
        e.run(APPLY);
        e.t.write(
            "home/.config/herdr-app/layouts/pjp-main.error",
            "\nunknown mod: pjp-spaces\n",
        );
        let (o, out, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.contains("pjp-main.error: unknown mod: pjp-spaces")),
            "{o:?}"
        );
        // 書いた実行では見ない (前の中身のもの)
        e.t.write(
            "home/.config/herdr-app/layouts/main.json",
            &BASE_JSON.replace("\"px\": 268", "\"px\": 300"),
        );
        let (o, out, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(o[1].notes.is_empty(), "{o:?}");
        // pjp-main を表示している間は、home の layout.error も見る
        std::fs::remove_file(e.home("layouts/pjp-main.error")).unwrap();
        e.t.write("home/.config/herdr-app/layout.error", "bad node\n");
        let (o, _, _) = e.run(Mode::Check);
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.contains("layout.error: bad node")),
            "{o:?}"
        );
        e.show("win98");
        let (o, _, _) = e.run(Mode::Check);
        assert!(
            !o[1].notes.iter().any(|n| n.contains("layout.error")),
            "表示が pjp-main でなければ見ない: {o:?}"
        );
    }

    #[test]
    fn notes_how_to_show_the_layout_and_prunes_removed_files() {
        let e = Env::new();
        e.t.write(&format!("{SRC}/dot.svg"), "<svg/>\n");
        e.run(APPLY);
        // ユーザーが ctrl-shift-l で main に戻した: 替え直さず、替え方を ※ で添える
        e.show("main");
        std::fs::remove_file(e.t.path().join(SRC).join("dot.svg")).unwrap();
        let (o, out, calls) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Ok], "{o:?}\n{out}");
        assert!(calls.is_empty());
        assert!(o[0].text.contains("削除 1"), "{o:?}");
        assert!(!e.home("mods/pjp-spaces/dot.svg").exists());
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("表示している layout は main。")
                    && n.contains("layout.switch --name pjp-main")),
            "{o:?}"
        );
    }

    #[test]
    fn point_to_and_changed_nodes() {
        let mut v = OValue::parse(BASE_JSON).unwrap();
        let before = v.clone();
        assert_eq!(point_to(&mut v, "spaces", "pjp-spaces"), 1);
        assert_eq!(point_to(&mut v, "spaces", "pjp-spaces"), 0);
        assert_eq!(changed_nodes(&before, &v), "変わった node: spaces");
        assert_eq!(changed_nodes(&v, &v), "node の中身は同じ (書き方だけ)");
        // 数は値で比べる (herdr-app の写しの 268.0 と main の 268)
        let mut f = before.clone();
        floats(&mut f);
        assert_ne!(f, before);
        assert!(same(&f, &before));
        assert_eq!(changed_nodes(&f, &before), "node の中身は同じ (書き方だけ)");
        let gone = OValue::parse(r#"{"id":"root","children":[]}"#).unwrap();
        assert_eq!(
            changed_nodes(&before, &gone),
            "変わった node: root / 消えた node: agents・main・sidebar・spaces"
        );
    }

    #[test]
    fn real_repo_does_not_carry_the_mod() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let dotfiles_mods = join_segments(&repo, crate::steps::herdr_app_mods::MODS);
        assert!(
            !dotfiles_mods.join(MOD).exists(),
            "pjp-spaces は claude-skills のもの (herdr-app-mods と二重に配らない)"
        );
    }

    #[test]
    fn step_info() {
        let i = HerdrAppPjpSpaces.info();
        assert_eq!(
            (i.id, i.order, i.gate),
            ("herdr-app-pjp-spaces", 98, Gate::Tool("herdrHub"))
        );
        assert!(i.ported && i.windows_only);
    }
}
