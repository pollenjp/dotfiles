//! repo のファイルの確かめ (managed.json・custom-layouts.json・layout-rules.json)、カスタムレイアウトの段 (`custom-layouts.json` に uuid ごとに足す)、
//! 横向きの既定の段 (`default-layouts.json`)、取り込み。WSL の `bootstrap-windows-fancyzones.sh` の `managed_problems`・`layout_problems`・
//! `rules_problems`・`sync_layouts`・`sync_default_layout`・`import_layouts` を写したもの (判定・文言・書く中身をそろえる)。
//!
//! カスタムレイアウトは、レイアウトごとに PC の中身・repo の中身・前に足した中身 (記録) で決める (中身は jq と同じく値で比べる):
//!
//! | PC | すること |
//! | --- | --- |
//! | 無く、記録も無い | 末尾に足す |
//! | repo と同じ | 何もしない (記録が無ければ記録だけする) |
//! | 記録と同じ (前に足したまま) | repo が更新された。同じ位置で書き換える |
//! | repo とも記録とも違う・記録が無い | PC のエディターで直した (足す前からあった)。書き換えずに知らせる (`--force` で書き換える) |
//! | 無いが、記録がある | PC で消した。足し直さずに知らせる (`--force` で足し直す) |
//!
//! PC にファイルが無ければ、記録によらず repo のレイアウトだけで作る。repo から消したレイアウトは PC から消さず、記録からだけ消す。

use super::{Fz, LAYOUTS_REL, pt_form, read_retry, row, warn};
use crate::context::Ctx;
use crate::jv::{self, Jv};
use crate::report::Kind;
use crate::steps::Mode;
use crate::steps::Outcome;
use std::path::Path;

/// uuid の形 (PowerToys の書く形: 大文字の {…})
pub(super) fn is_guid(s: &str) -> bool {
    let b = jv::anchored(s).as_bytes();
    if b.len() != 38 || b[0] != b'{' || b[37] != b'}' {
        return false;
    }
    b[1..37].iter().enumerate().all(|(i, &c)| {
        if matches!(i, 8 | 13 | 18 | 23) {
            c == b'-'
        } else {
            c.is_ascii_digit() || (b'A'..=b'F').contains(&c)
        }
    })
}

/// 中に null か空の object があるか (自身も含む。jq の `[.. | select(. == null or . == {})] | length > 0`)
fn has_null_or_empty(v: &Jv) -> bool {
    match v {
        Jv::Null => true,
        Jv::Object(o) if o.is_empty() => true,
        Jv::Object(o) => o.iter().any(|(_, x)| has_null_or_empty(x)),
        Jv::Array(a) => a.iter().any(has_null_or_empty),
        _ => false,
    }
}

/// 並べ替えたキー (jq の `keys`)
fn sorted_keys(v: &Jv) -> Vec<String> {
    let mut k: Vec<String> = v
        .as_object()
        .map(|o| o.iter().map(|(k, _)| k.clone()).collect())
        .unwrap_or_default();
    k.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    k
}

/// ファイルを読む。無い・空・JSON でなければ、出す 1 行の文
fn read_file(path: &Path) -> Result<Jv, String> {
    match std::fs::read(path) {
        Ok(b) if b.is_empty() => Err(format!("ファイルが無いか、空です ({})。", path.display())),
        Ok(b) => String::from_utf8(b)
            .map_err(|e| e.to_string())
            .and_then(|t| Jv::parse(&t))
            .map_err(|e| format!("JSON として読めません ({}): {e}", path.display())),
        Err(_) => Err(format!("ファイルが無いか、空です ({})。", path.display())),
    }
}

/// 解像度の決まり (確かめた後に読む。読めなければ null)
pub(super) fn read_rules(path: &Path) -> Jv {
    read_file(path).unwrap_or(Jv::Null)
}

/// repo のカスタムレイアウトの配列 (確かめた後に読む。読めなければ空)
pub(super) fn read_repo(path: &Path) -> Vec<Jv> {
    read_file(path).map(|d| layouts_of(&d)).unwrap_or_default()
}

/// managed.json の誤りを 1 行ずつ (WSL の `managed_problems`)。
pub(super) fn managed_problems(path: &Path) -> Vec<String> {
    let v = match read_file(path) {
        Ok(v) => v,
        Err(e) => return vec![e],
    };
    if !v.is_object() {
        return vec!["JSON の object ではありません。".to_string()];
    }
    let mut out = Vec::new();
    let others: Vec<String> = sorted_keys(&v)
        .into_iter()
        .filter(|k| k != "properties")
        .collect();
    if !others.is_empty() {
        out.push(format!(
            "properties のほかにキーがあります: {}",
            others.join(", ")
        ));
    }
    match v.get("properties") {
        Some(Jv::Object(props)) if !props.is_empty() => {
            for (k, x) in props {
                if !x.is_object() || sorted_keys(x) != ["value"] || has_null_or_empty(x) {
                    out.push(format!(
                        "properties.{k} の形が {{\"value\": 値}} ではありません。"
                    ));
                }
            }
        }
        _ => out.push("properties に持つキーがありません。".to_string()),
    }
    out
}

/// 名前の注 (「名前」)
fn name_note(l: &Jv) -> String {
    match l.get("name") {
        Some(Jv::String(n)) => format!("「{n}」"),
        _ => String::new(),
    }
}

/// custom-layouts の配列 (無い・object でなければ空。jq の `layouts`)
pub(super) fn layouts_of(doc: &Jv) -> Vec<Jv> {
    match doc.get("custom-layouts") {
        Some(Jv::Array(a)) if doc.is_object() => a.clone(),
        _ => Vec::new(),
    }
}

/// 配列の中で uuid が `u` のレイアウトの位置 (jq の `uuid_index`)
fn uuid_index(list: &[Jv], u: &Jv) -> Option<usize> {
    list.iter()
        .position(|l| l.is_object() && jv::jq_eq(l.get("uuid").unwrap_or(&Jv::Null), u))
}

/// repo に置くカスタムレイアウトのファイルの誤りを 1 行ずつ (WSL の `layout_problems`。uuid は PowerToys の書く形 (大文字の {…})・name は空でなく
/// 重ねない)
pub(super) fn layout_problems(doc: &Jv) -> Vec<String> {
    if !doc.is_object() {
        return vec!["JSON の object ではありません。".to_string()];
    }
    let Some(Jv::Array(list)) = doc.get("custom-layouts") else {
        return vec!["custom-layouts の配列がありません。".to_string()];
    };
    let mut out = Vec::new();
    for (i, l) in list.iter().enumerate() {
        let n = i + 1;
        if !l.is_object() {
            out.push(format!("{n} 番目が object ではありません。"));
            continue;
        }
        let note = name_note(l);
        match l.get("uuid") {
            Some(Jv::String(u)) if is_guid(u) => {}
            other => out.push(format!(
                "{n} 番目{note} の uuid が、大文字の {{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}} の形ではありません: {}",
                other.unwrap_or(&Jv::Null).compact()
            )),
        }
        if !matches!(l.get("name"), Some(Jv::String(s)) if !s.is_empty()) {
            out.push(format!("{n} 番目の name が空か、文字列ではありません。"));
        }
        if !matches!(l.get("type"), Some(Jv::String(_))) {
            out.push(format!("{n} 番目{note} に type (文字列) がありません。"));
        }
        if !matches!(l.get("info"), Some(Jv::Object(_))) {
            out.push(format!("{n} 番目{note} に info (object) がありません。"));
        }
    }
    let strings = |key: &str| -> Vec<Jv> {
        list.iter()
            .filter(|l| l.is_object())
            .filter_map(|l| l.get(key).filter(|v| matches!(v, Jv::String(_))).cloned())
            .collect()
    };
    for (key, what) in [("uuid", "uuid"), ("name", "name")] {
        for g in jv::group_by(&strings(key), |v| v.clone()) {
            if g.len() > 1 {
                out.push(format!("{what} が重なっています: {}", g[0].tostring()));
            }
        }
    }
    out
}

/// repo の custom-layouts.json の誤りを 1 行ずつ (WSL の `layouts_problems`)
pub(super) fn layouts_problems(path: &Path) -> Vec<String> {
    match read_file(path) {
        Ok(v) => layout_problems(&v),
        Err(e) => vec![e],
    }
}

/// 決まりの名前の誤り (WSL の `rule_name_problem`。repo の canvas のレイアウトだけを指せる)
fn rule_name_problem(v: Option<&Jv>, what: &str, layouts: &[Jv]) -> Option<String> {
    let n = match v {
        Some(Jv::String(n)) if !n.is_empty() => n,
        _ => return Some(format!("{what} が空か、文字列ではありません。")),
    };
    let m: Vec<&Jv> = layouts
        .iter()
        .filter(|l| l.is_object() && l.get("name") == Some(&Jv::String(n.clone())))
        .collect();
    if m.is_empty() {
        Some(format!(
            "{what} の「{n}」というレイアウトが custom-layouts.json にありません。"
        ))
    } else if !jv::jq_eq(m[0].get("type").unwrap_or(&Jv::Null), &Jv::from("canvas")) {
        Some(format!(
            "{what} の「{n}」は canvas のレイアウトではありません (あてる値を確かめた canvas のレイアウトだけを指せます)。"
        ))
    } else {
        None
    }
}

/// layout-rules.json の誤りを 1 行ずつ (WSL の `rules_problems`。名前を引くので、custom-layouts.json に誤りが無いときに呼ぶ)
pub(super) fn rules_problems(rules_path: &Path, layouts_path: &Path) -> Vec<String> {
    let v = match read_file(rules_path) {
        Ok(v) => v,
        Err(e) => return vec![e],
    };
    let layouts = read_file(layouts_path)
        .map(|d| layouts_of(&d))
        .unwrap_or_default();
    if !v.is_object() {
        return vec!["JSON の object ではありません。".to_string()];
    }
    let mut out = Vec::new();
    let others: Vec<String> = sorted_keys(&v)
        .into_iter()
        .filter(|k| k != "rules" && k != "default")
        .collect();
    if !others.is_empty() {
        out.push(format!(
            "rules・default のほかにキーがあります: {}",
            others.join(", ")
        ));
    }
    match v.get("rules") {
        Some(Jv::Array(rules)) => {
            for (i, r) in rules.iter().enumerate() {
                let n = i + 1;
                if !r.is_object() {
                    out.push(format!("rules の {n} 番目が object ではありません。"));
                    continue;
                }
                let extra: Vec<String> = sorted_keys(r)
                    .into_iter()
                    .filter(|k| k != "resolution" && k != "layout")
                    .collect();
                if !extra.is_empty() {
                    out.push(format!(
                        "rules の {n} 番目に resolution・layout のほかのキーがあります: {}",
                        extra.join(", ")
                    ));
                }
                let res = r.get("resolution");
                if !matches!(res, Some(Jv::String(s)) if is_resolution(s)) {
                    out.push(format!(
                        "rules の {n} 番目の resolution が「幅x高さ」(3840x2160 など) の形ではありません: {}",
                        res.unwrap_or(&Jv::Null).compact()
                    ));
                }
                if let Some(p) = rule_name_problem(
                    r.get("layout"),
                    &format!("rules の {n} 番目の layout"),
                    &layouts,
                ) {
                    out.push(p);
                }
            }
            let res: Vec<Jv> = rules
                .iter()
                .filter(|r| r.is_object())
                .filter_map(|r| {
                    r.get("resolution")
                        .filter(|v| matches!(v, Jv::String(_)))
                        .cloned()
                })
                .collect();
            for g in jv::group_by(&res, |v| v.clone()) {
                if g.len() > 1 {
                    out.push(format!("resolution が重なっています: {}", g[0].tostring()));
                }
            }
        }
        _ => out.push("rules の配列がありません。".to_string()),
    }
    if let Some(p) = rule_name_problem(v.get("default"), "default", &layouts) {
        out.push(p);
    }
    out
}

/// 「幅x高さ」の形 (jq の `test("^[1-9][0-9]*x[1-9][0-9]*$")`)
fn is_resolution(s: &str) -> bool {
    let s = jv::anchored(s);
    let Some((w, h)) = s.split_once('x') else {
        return false;
    };
    let num =
        |p: &str| !p.is_empty() && p.as_bytes()[0] != b'0' && p.bytes().all(|b| b.is_ascii_digit());
    num(w) && num(h)
}

/// レイアウトの判定。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Same,
    Update,
    Add,
    Force,
    Readd,
    Edited,
    Differs,
    Deleted,
}

/// repo のレイアウト 1 つの計画。
struct Entry {
    uuid: Jv,
    name: Jv,
    want: Jv,
    cur: Option<Jv>,
    action: Action,
}

impl Entry {
    fn write(&self) -> bool {
        matches!(
            self.action,
            Action::Add | Action::Update | Action::Force | Action::Readd
        )
    }
}

/// 記録 (`{"version":1,"layouts":{"<uuid>":<レイアウト>}}`) を読む。無ければ空。壊れていれば None
fn load_record(path: &Path) -> Option<Jv> {
    match std::fs::read_to_string(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Some(Jv::parse(r#"{"version":1,"layouts":{}}"#).expect("空の記録"))
        }
        Err(_) => None,
        Ok(t) => Jv::parse(&t)
            .ok()
            .filter(|v| matches!(v.get("layouts"), Some(Jv::Object(_)))),
    }
}

/// 記録を書く (変わったときだけ。dry-run では書かない。WSL の `save_record`)。repo から消したレイアウトは記録から消し、揃っているものと、書けた
/// ときは書いたものを、repo の中身で記録する。
fn save_record(ctx: &mut Ctx, fz: &mut Fz, rec: &Jv, repo: &[Jv], entries: &[Entry], wrote: bool) {
    if fz.dry() || fz.mode == Mode::Check {
        return;
    }
    let ids: Vec<&Jv> = repo.iter().filter_map(|l| l.get("uuid")).collect();
    let mut layouts: Vec<(String, Jv)> = rec
        .get("layouts")
        .and_then(Jv::as_object)
        .map(|o| {
            o.iter()
                .filter(|(k, _)| ids.iter().any(|u| jv::jq_eq(u, &Jv::String(k.clone()))))
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    let mut obj = Jv::Object(std::mem::take(&mut layouts));
    for e in entries {
        if e.action == Action::Same || (wrote && e.write()) {
            obj.set(&e.uuid.tostring(), e.want.clone());
        }
    }
    let new = Jv::Object(vec![
        ("version".into(), Jv::from(1)),
        ("layouts".into(), obj),
    ]);
    let new_text = format!("{}\n", new.sorted().indent(2));
    let old_text = if fz.record.exists() {
        std::fs::read_to_string(&fz.record)
            .ok()
            .and_then(|t| Jv::parse(&t).ok())
            .map(|v| format!("{}\n", v.sorted().indent(2)))
    } else {
        Some(format!(
            "{}\n",
            Jv::parse(r#"{"version":1,"layouts":{}}"#)
                .expect("空の記録")
                .sorted()
                .indent(2)
        ))
    };
    if old_text.as_deref() == Some(new_text.as_str()) {
        return;
    }
    if crate::fsutil::write_atomic(&fz.record, new_text.as_bytes()).is_err() {
        let lines = [
            format!(
                "FancyZones のカスタムレイアウトの記録を書けませんでした: {}",
                fz.record.display()
            ),
            "次の回は、前に足したレイアウトを見分けられないことがあります (PC で直したものとして知らせます)。".to_string(),
        ];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Failed,
            "FancyZones のカスタムレイアウトの記録を書けない",
            &lines[1..],
        ));
    }
}

/// 書き換えずに残したもの (PC で直した・足す前からあった・消えた) を知らせ、直されたものの違いをその場にだけ出す (WSL の `report_kept`)
fn report_kept(ctx: &mut Ctx, fz: &mut Fz, entries: &[Entry]) {
    let kept: Vec<&Entry> = entries
        .iter()
        .filter(|e| matches!(e.action, Action::Edited | Action::Differs | Action::Deleted))
        .collect();
    if kept.is_empty() {
        return;
    }
    let lines: Vec<String> = kept
        .iter()
        .map(|e| {
            let why = match e.action {
                Action::Edited => "PC のエディターで直されています (前に足した中身と違う)",
                Action::Differs => "dotfiles が足す前から PC にあり、repo と中身が違います",
                _ => "PC から消えています (前に足したもの。エディターで消したか、エディターを開いたまま流して閉じると消えます)",
            };
            let renamed = match &e.cur {
                Some(c) => {
                    let pc_name = c.field("name").cloned().unwrap_or(Jv::Null);
                    if jv::jq_eq(&pc_name, &e.name) {
                        String::new()
                    } else {
                        format!(" (PC での名前は「{}」)", pc_name.tostring())
                    }
                }
                None => String::new(),
            };
            format!("{}: {why}{renamed}", e.name.tostring())
        })
        .collect();
    // PC にあるもの (直した・足す前からあった) は取り込める。取り込みは PC の名前で引く
    let in_pc: Vec<&&Entry> = kept
        .iter()
        .filter(|e| matches!(e.action, Action::Edited | Action::Differs))
        .collect();
    let pc_names: Vec<String> = in_pc
        .iter()
        .map(|e| {
            e.cur
                .as_ref()
                .and_then(|c| c.field("name").cloned())
                .unwrap_or(Jv::Null)
                .tostring()
        })
        .collect();
    let mut out = vec![
        format!(
            "FancyZones のカスタムレイアウトのうち、次のものは PC の中身を残しました (書き換えていません。{}):",
            fz.pc_layouts.display()
        ),
        lines.join("\n"),
        format!(
            "repo の中身にするなら (PC のファイルは退避します): {}",
            super::force_command(ctx)
        ),
        format!(
            "--force は、手でディスプレイにあてたカスタムレイアウト・blank の組も、解像度の決まりのレイアウトで上書きします。先に {} で何が変わるかを見られます。",
            super::dry_force_command(ctx)
        ),
    ];
    if !pc_names.is_empty() {
        out.push(format!(
            "PC の中身を repo へ取り込むなら (commit は自分で): {}",
            super::import_command(ctx, &pc_names)
        ));
    }
    warn(ctx, &out);
    fz.rows.push(row(
        Kind::Manual,
        format!(
            "PC で直した・足す前からあった・消えたカスタムレイアウト {} 件は、PC の中身を残した",
            kept.len()
        ),
        &out[2..],
    ));
    // 直されたものの違い (PC → repo。キーの順に並べた 2 字下げ)
    for e in in_pc {
        let cur = e.cur.as_ref().expect("PC にある").sorted();
        let want = e.want.sorted();
        ctx.say(format!("   --- {} (PC) → (repo)", e.name.tostring()));
        show_diff(ctx, &cur.indent(2), &want.indent(2));
    }
}

/// 2 つの中身の diff を `git diff --no-index` で出す (一時ディレクトリに書いてから)
fn show_diff(ctx: &mut Ctx, left: &str, right: &str) {
    let dir = std::env::temp_dir().join(format!(
        "dotfiles-win-fz-diff-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    if std::fs::create_dir(&dir).is_err() {
        return;
    }
    let (pc, repo) = (dir.join("PC.json"), dir.join("repo.json"));
    if std::fs::write(&pc, format!("{left}\n")).is_ok()
        && std::fs::write(&repo, format!("{right}\n")).is_ok()
    {
        super::super::deploy::show_diff(ctx, &pc, &repo);
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// カスタムレイアウトの段 (WSL の `sync_layouts`)。
pub(super) fn sync_layouts(ctx: &mut Ctx, fz: &mut Fz) {
    let problems = layouts_problems(&fz.layouts);
    if !problems.is_empty() {
        let lines = [
            format!("{LAYOUTS_REL} に誤りがあるので、FancyZones のカスタムレイアウトを書きません:"),
            problems.join("\n"),
        ];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Failed,
            format!("{LAYOUTS_REL} に誤りがあるので、カスタムレイアウトを書いていない"),
            &problems,
        ));
        return;
    }
    let repo = layouts_of(&read_file(&fz.layouts).expect("確かめた"));
    // repo にレイアウトが無ければ、PC のファイルは読まない (前に足した記録があれば消す)
    if repo.is_empty() {
        if fz.record.exists()
            && let Some(rec) = load_record(&fz.record)
        {
            save_record(ctx, fz, &rec, &repo, &[], false);
        }
        return;
    }
    let Some(rec) = load_record(&fz.record) else {
        let lines = [
            format!("FancyZones のカスタムレイアウトの記録が壊れているので、カスタムレイアウトを書きません: {}", fz.record.display()),
            "消してから流し直すと、PC にあって repo と中身が違うレイアウトは、PC の中身を残して知らせます (--force か取り込みで解く)。".to_string(),
        ];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Failed,
            "FancyZones のカスタムレイアウトの記録が壊れている",
            &lines[1..],
        ));
        return;
    };
    // 無いのは PowerToys の設定を消したとき (エディターは消さない)。記録によらず repo のレイアウトだけで作る
    let fresh = !fz.pc_layouts.exists();
    let pc = if fresh {
        Jv::Object(Vec::new())
    } else {
        match read_retry(ctx, &fz.pc_layouts, super::layouts_shape) {
            Some(v) => v,
            None => {
                let lines = [
                    format!(
                        "FancyZones の custom-layouts.json を読めないので、カスタムレイアウトを書きません: {}",
                        fz.pc_layouts.display()
                    ),
                    "中身を確かめて直してから、流し直してください。".to_string(),
                ];
                warn(ctx, &lines);
                fz.rows.push(row(
                    Kind::Failed,
                    "FancyZones の custom-layouts.json を読めないので、カスタムレイアウトを書いていない",
                    &lines[1..],
                ));
                return;
            }
        }
    };
    let cur_list = layouts_of(&pc);
    let recs = rec
        .get("layouts")
        .cloned()
        .unwrap_or(Jv::Object(Vec::new()));
    let force = fz.mode.force();
    let entries: Vec<Entry> = repo
        .iter()
        .map(|w| {
            let uuid = w.get("uuid").cloned().unwrap_or(Jv::Null);
            let cur = uuid_index(&cur_list, &uuid).map(|i| cur_list[i].clone());
            let rec_v = recs.get(&uuid.tostring()).cloned();
            let action = match (&cur, &rec_v) {
                (Some(c), _) if jv::jq_eq(c, w) => Action::Same,
                (Some(c), Some(r)) if jv::jq_eq(c, r) => Action::Update,
                (None, r) if fresh || r.is_none() => Action::Add,
                (Some(_), _) if force => Action::Force,
                (None, _) if force => Action::Readd,
                (Some(_), Some(_)) => Action::Edited,
                (Some(_), None) => Action::Differs,
                (None, _) => Action::Deleted,
            };
            Entry {
                name: w.get("name").cloned().unwrap_or(Jv::Null),
                uuid,
                want: w.clone(),
                cur,
                action,
            }
        })
        .collect();
    let pc_only: Vec<String> = cur_list
        .iter()
        .filter(|l| l.is_object())
        .filter(|l| {
            let u = l.get("uuid").unwrap_or(&Jv::Null);
            repo.iter()
                .all(|w| !jv::jq_eq(w.get("uuid").unwrap_or(&Jv::Null), u))
        })
        .map(|l| match l.get("name") {
            None | Some(Jv::Null) | Some(Jv::Bool(false)) => "(名前なし)".to_string(),
            Some(n) => n.tostring(),
        })
        .collect();
    let pre = fz.pre;
    let lines: Vec<String> = entries
        .iter()
        .filter(|e| e.write())
        .map(|e| {
            let what = match (fz.mode, e.action) {
                (Mode::Check, Action::Add) => "無い (apply で足す)",
                (Mode::Check, _) => "repo が更新された (apply で書き換える)",
                (_, Action::Add) => "足す",
                (_, Action::Update) => "書き換える (repo が更新された)",
                (_, Action::Force) => "書き換える (--force)",
                _ => "足し直す (--force。PC に無かった)",
            };
            format!("  {pre}{}: {what}", e.name.tostring())
        })
        .collect();
    let nwrite = lines.len();
    let nsame = entries.iter().filter(|e| e.action == Action::Same).count();
    // dry-run では書かないので、後の段が「足したら PC にある」と見られるよう、足す・書き換えるものを渡す
    if fz.dry() && nwrite > 0 {
        fz.pending_layouts = entries
            .iter()
            .filter(|e| e.write())
            .map(|e| e.uuid.tostring())
            .collect();
    }

    if nwrite == 0 {
        save_record(ctx, fz, &rec, &repo, &entries, false);
        if entries.iter().all(|e| e.action == Action::Same) {
            let tail = if pc_only.is_empty() {
                String::new()
            } else {
                format!("。PC にだけあるもの {} 件には触りません", pc_only.len())
            };
            ctx.say(format!(
                "FancyZones のカスタムレイアウトは揃っています (dotfiles のもの {nsame} 件{tail})。"
            ));
            fz.rows.push(row(
                Kind::Ok,
                format!(
                    "FancyZones のカスタムレイアウトは揃っている (dotfiles のもの {nsame} 件{tail})"
                ),
                &[],
            ));
        }
        report_kept(ctx, fz, &entries);
        return;
    }

    if fz.mode.writes() {
        let failed = |ctx: &mut Ctx, fz: &mut Fz, lines: Vec<String>, text: &str| {
            warn(ctx, &lines);
            fz.rows
                .push(row(Kind::Failed, text.to_string(), &lines[1..]));
        };
        if fresh && std::fs::create_dir_all(&fz.fz_dir).is_err() {
            failed(
                ctx,
                fz,
                vec![
                    format!(
                        "FancyZones の custom-layouts.json を作れませんでした: {}",
                        fz.pc_layouts.display()
                    ),
                    "Windows 側のディレクトリを確かめてから、流し直してください。".to_string(),
                ],
                "FancyZones の custom-layouts.json を作れなかった",
            );
            save_record(ctx, fz, &rec, &repo, &entries, false);
            report_kept(ctx, fz, &entries);
            return;
        }
        if fz.backup.file(&fz.pc_layouts.clone()).is_err() {
            failed(
                ctx,
                fz,
                vec![
                    format!(
                        "FancyZones の custom-layouts.json を退避できないので、カスタムレイアウトを書きません: {}",
                        fz.backup.root.display()
                    ),
                    lines.join("\n"),
                ],
                "FancyZones の custom-layouts.json を退避できないので、カスタムレイアウトを書いていない",
            );
            save_record(ctx, fz, &rec, &repo, &entries, false);
            report_kept(ctx, fz, &entries);
            return;
        }
        // 書く中身: PC のファイルに、書くものを当てる (同じ uuid は同じ位置で替え、無ければ末尾に足す)
        let mut list = cur_list.clone();
        for e in entries.iter().filter(|e| e.write()) {
            match uuid_index(&list, &e.uuid) {
                Some(i) => list[i] = e.want.clone(),
                None => list.push(e.want.clone()),
            }
        }
        let mut doc = if pc.is_object() {
            pc.clone()
        } else {
            Jv::Object(Vec::new())
        };
        doc.set("custom-layouts", Jv::Array(list));
        if super::place(&fz.pc_layouts, &pt_form(&doc)).is_err() {
            failed(
                ctx,
                fz,
                vec![
                    format!(
                        "FancyZones の custom-layouts.json に書けないので、カスタムレイアウトを足せませんでした: {}",
                        fz.pc_layouts.display()
                    ),
                    lines.join("\n"),
                ],
                "FancyZones の custom-layouts.json に書けないので、カスタムレイアウトを足せなかった",
            );
            save_record(ctx, fz, &rec, &repo, &entries, false);
            report_kept(ctx, fz, &entries);
            return;
        }
        super::reload(ctx, fz, &fz.pc_layouts.clone(), "custom-layouts.json");
        save_record(ctx, fz, &rec, &repo, &entries, true);
    }

    ctx.say(format!(
        "==> {pre}FancyZones のカスタムレイアウト ({})",
        fz.pc_layouts.display()
    ));
    if fresh {
        ctx.say(format!("  {pre}custom-layouts.json が無いので作る"));
    }
    for l in &lines {
        ctx.say(l);
    }
    if !pc_only.is_empty() {
        ctx.say(format!(
            "  PC にだけあるレイアウトには触りません: {}",
            pc_only.join("、")
        ));
    }
    if let Some(dir) = &fz.backup.dir {
        ctx.say(format!(
            "  書き換える前のファイルは {} に退避しました。",
            dir.display()
        ));
    }
    let adds = entries
        .iter()
        .filter(|e| matches!(e.action, Action::Add | Action::Readd))
        .count();
    let kind = match fz.mode {
        Mode::Apply { .. } => Kind::Ok,
        _ if adds < nwrite => Kind::Fix,
        _ => Kind::Missing,
    };
    let verb = if fz.mode.writes() {
        "書いた"
    } else {
        "書く"
    };
    fz.rows.push(row(
        kind,
        format!("{pre}FancyZones のカスタムレイアウト {nwrite} 件を{verb} (同じ {nsame} 件)"),
        &[],
    ));
    report_kept(ctx, fz, &entries);
}

/// キーで引く表 (出てきた順。jq の object を from_entries で作ったもの)
pub(super) type Table = Vec<(String, Jv)>;

/// あてられるレイアウトか (canvas で、info.zones が配列。jq の `usable_layout`)
pub(super) fn usable_layout(l: Option<&Jv>) -> bool {
    let Some(l) = l else { return false };
    l.is_object()
        && jv::jq_eq(l.get("type").unwrap_or(&Jv::Null), &Jv::from("canvas"))
        && matches!(l.get("info"), Some(Jv::Object(_)))
        && matches!(
            l.get("info").and_then(|i| i.get("zones")),
            Some(Jv::Array(_))
        )
}

/// PC のレイアウトを uuid で引く表 (uuid が文字列の object。同じ uuid は後のもの) と、dry-run で足すものを PC にあるものとして見る表 (jq の
/// `$pc_by_uuid` と `$present`)
pub(super) fn pc_tables(pc: &Jv, repo: &[Jv], pending: &[String]) -> (Table, Table) {
    let mut by_uuid: Vec<(String, Jv)> = Vec::new();
    let put =
        |t: &mut Vec<(String, Jv)>, k: String, v: Jv| match t.iter_mut().find(|(x, _)| *x == k) {
            Some((_, old)) => *old = v,
            None => t.push((k, v)),
        };
    for l in layouts_of(pc) {
        if let Some(Jv::String(u)) = l.get("uuid") {
            let u = u.clone();
            put(&mut by_uuid, u, l);
        }
    }
    let mut present = by_uuid.clone();
    for l in repo {
        if let Some(u) = l.get("uuid")
            && pending.iter().any(|p| jv::jq_eq(&Jv::String(p.clone()), u))
        {
            put(&mut present, u.tostring(), l.clone());
        }
    }
    (by_uuid, present)
}

/// 表から引く
pub(super) fn lookup<'a>(t: &'a [(String, Jv)], key: &str) -> Option<&'a Jv> {
    t.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

/// 横向きの既定の段 (WSL の `sync_default_layout`): FancyZones が組の無い横向きの画面にあてる既定 (default-layouts.json の horizontal) を、決まりの
/// default のカスタムレイアウトにそろえる。縦向き (vertical) には触らない。
pub(super) fn sync_default_layout(ctx: &mut Ctx, fz: &mut Fz) {
    // 決まりか repo のレイアウトに誤りがあれば、黙って飛ばす (あて方の段が組のあるときに知らせる。CI の --check も見る)
    if !layouts_problems(&fz.layouts).is_empty()
        || !rules_problems(&fz.rules, &fz.layouts).is_empty()
    {
        return;
    }
    let Ok(pc) = fz.read_pc_layouts(ctx) else {
        let lines = [format!(
            "FancyZones の custom-layouts.json を読めないので、FancyZones の横向きの既定を書きません: {}",
            fz.pc_layouts.display()
        )];
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Failed,
            "FancyZones の custom-layouts.json を読めないので、横向きの既定を書いていない",
            &[],
        ));
        return;
    };
    let shape = |v: &Jv| {
        v.is_object()
            && v.get("default-layouts")
                .is_none_or(|l| matches!(l, Jv::Array(_)))
    };
    // 無いのは、エディターを一度も開いていない PC。横向きの項目だけで作る (縦向きは FancyZones の既定のまま)
    let fresh = !fz.pc_defaults.exists();
    let dl = if fresh {
        Jv::Object(Vec::new())
    } else {
        match read_retry(ctx, &fz.pc_defaults, shape) {
            Some(v) => v,
            None => {
                let lines = [
                    format!(
                        "FancyZones の default-layouts.json を読めないので、横向きの既定を書きません: {}",
                        fz.pc_defaults.display()
                    ),
                    "中身を確かめて直してから、流し直してください。".to_string(),
                ];
                warn(ctx, &lines);
                fz.rows.push(row(
                    Kind::Failed,
                    "FancyZones の default-layouts.json を読めないので、横向きの既定を書いていない",
                    &lines[1..],
                ));
                return;
            }
        }
    };
    let repo = layouts_of(&read_file(&fz.layouts).expect("確かめた"));
    let rules = read_file(&fz.rules).expect("確かめた");
    let tname = rules.get("default").cloned().unwrap_or(Jv::Null);
    let tl = repo
        .iter()
        .find(|l| l.is_object() && jv::jq_eq(l.get("name").unwrap_or(&Jv::Null), &tname))
        .cloned()
        .unwrap_or(Jv::Null);
    let t_uuid = tl.field("uuid").cloned().unwrap_or(Jv::Null);
    let (by_uuid, present) = pc_tables(&pc, &repo, &fz.pending_layouts);
    let list = match dl.get("default-layouts") {
        Some(Jv::Array(a)) => a.clone(),
        _ => Vec::new(),
    };
    let is_hz = |e: &Jv| {
        e.is_object()
            && jv::jq_eq(
                e.get("monitor-configuration").unwrap_or(&Jv::Null),
                &Jv::from("horizontal"),
            )
    };
    let hz: Vec<&Jv> = list.iter().filter(|e| is_hz(e)).collect();
    let want = Jv::Object(vec![
        ("uuid".into(), t_uuid.clone()),
        ("type".into(), Jv::from("custom")),
        ("show-spacing".into(), Jv::Bool(false)),
        ("spacing".into(), Jv::from(0)),
        ("zone-count".into(), Jv::from(0)),
        ("sensitivity-radius".into(), Jv::from(0)),
    ]);
    let before = match hz.first().map(|h| h.get("layout")) {
        None | Some(None) | Some(Some(Jv::Null)) => "(横向きの既定なし)".to_string(),
        Some(Some(l)) if !l.is_object() => "(横向きの既定なし)".to_string(),
        Some(Some(l)) => {
            if jv::jq_eq(l.get("type").unwrap_or(&Jv::Null), &Jv::from("custom")) {
                let u = l.get("uuid").cloned().unwrap_or(Jv::Null);
                match lookup(&by_uuid, &u.tostring()).and_then(|x| x.get("name")) {
                    Some(n) if !matches!(n, Jv::Null | Jv::Bool(false)) => n.tostring(),
                    _ => format!("カスタム {}", u.tostring()),
                }
            } else {
                l.get("type").cloned().unwrap_or(Jv::Null).tostring()
            }
        }
    };
    let aligned = !hz.is_empty()
        && hz.iter().all(|h| match h.get("layout") {
            Some(l @ Jv::Object(_)) => {
                jv::jq_eq(l.get("type").unwrap_or(&Jv::Null), &Jv::from("custom"))
                    && jv::jq_eq(l.get("uuid").unwrap_or(&Jv::Null), &t_uuid)
            }
            _ => false,
        });
    let usable = usable_layout(lookup(&present, &t_uuid.tostring()));
    let tname_s = tname.tostring();
    let pc_defaults = fz.pc_defaults.display().to_string();
    if !usable {
        let lines = if aligned {
            [
                format!(
                    "決まりの既定のレイアウト「{tname_s}」が PC の custom-layouts.json に無い (か canvas でない) ので、FancyZones の横向きの既定 (このレイアウト) が使えません: {pc_defaults}"
                ),
                format!(
                    "PC で消したものなら、--force で足し直してください (先に {} で何が変わるかを見られます)。",
                    super::dry_force_command(ctx)
                ),
            ]
        } else {
            [
                format!(
                    "決まりの既定のレイアウト「{tname_s}」が PC の custom-layouts.json に無い (か canvas でない) ので、FancyZones の横向きの既定にしていません: {pc_defaults}"
                ),
                format!(
                    "PC で消したものなら、--force で足し直すと既定にします (先に {} で何が変わるかを見られます)。",
                    super::dry_force_command(ctx)
                ),
            ]
        };
        warn(ctx, &lines);
        fz.rows.push(row(
            Kind::Manual,
            format!("決まりの既定のレイアウト「{tname_s}」が PC に無い (か canvas でない) ので、横向きの既定が使えない"),
            &[format!("PC で消したものなら、{} で足し直す", super::force_command(ctx))],
        ));
        return;
    }
    if aligned {
        ctx.say(format!(
            "FancyZones の横向きの既定のレイアウトは揃っています ({tname_s})。"
        ));
        fz.rows.push(row(
            Kind::Ok,
            format!("FancyZones の横向きの既定のレイアウトは揃っている ({tname_s})"),
            &[],
        ));
        return;
    }
    let mut doc = dl.clone();
    let new_list = if hz.is_empty() {
        let mut l = list.clone();
        l.push(Jv::Object(vec![
            ("monitor-configuration".into(), Jv::from("horizontal")),
            ("layout".into(), want.clone()),
        ]));
        l
    } else {
        list.iter()
            .map(|e| {
                if is_hz(e) {
                    let mut e = e.clone();
                    e.set("layout", want.clone());
                    e
                } else {
                    e.clone()
                }
            })
            .collect()
    };
    doc.set("default-layouts", Jv::Array(new_list));
    let pre = fz.pre;
    if fz.mode.writes() {
        let failed = |ctx: &mut Ctx, fz: &mut Fz, lines: [String; 2], text: &str| {
            warn(ctx, &lines);
            fz.rows
                .push(row(Kind::Failed, text.to_string(), &lines[1..]));
        };
        if fresh && std::fs::create_dir_all(&fz.fz_dir).is_err() {
            failed(
                ctx,
                fz,
                [
                    format!("FancyZones の default-layouts.json を作れませんでした: {pc_defaults}"),
                    "Windows 側のディレクトリを確かめてから、流し直してください。".to_string(),
                ],
                "FancyZones の default-layouts.json を作れなかった",
            );
            return;
        }
        if fz.backup.file(&fz.pc_defaults.clone()).is_err() {
            failed(
                ctx,
                fz,
                [
                    format!(
                        "FancyZones の default-layouts.json を退避できないので、横向きの既定を書きません: {}",
                        fz.backup.root.display()
                    ),
                    format!("{before} → {tname_s}"),
                ],
                "FancyZones の default-layouts.json を退避できないので、横向きの既定を書いていない",
            );
            return;
        }
        if super::place(&fz.pc_defaults, &pt_form(&doc)).is_err() {
            failed(
                ctx,
                fz,
                [
                    format!(
                        "FancyZones の default-layouts.json に書けないので、横向きの既定を変えられませんでした: {pc_defaults}"
                    ),
                    format!("{before} → {tname_s}"),
                ],
                "FancyZones の default-layouts.json に書けないので、横向きの既定を変えられなかった",
            );
            return;
        }
        super::reload(ctx, fz, &fz.pc_defaults.clone(), "default-layouts.json");
    }
    ctx.say(format!(
        "==> {pre}FancyZones の横向きの既定のレイアウト ({pc_defaults})"
    ));
    if fresh {
        ctx.say(format!("  {pre}default-layouts.json が無いので作る"));
    }
    ctx.say(format!("  {pre}{before} → {tname_s}"));
    // 作った回は退避していない (同じ回にカスタムレイアウトの段が退避していても、そこに default-layouts.json は無い)
    if fz.mode.writes()
        && !fresh
        && let Some(dir) = &fz.backup.dir
    {
        ctx.say(format!(
            "  書き換える前のファイルは {} に退避しました。",
            dir.display()
        ));
    }
    let (kind, verb) = match fz.mode {
        Mode::Apply { .. } => (Kind::Ok, "にした"),
        _ if fresh => (Kind::Missing, "にする"),
        _ => (Kind::Fix, "にする"),
    };
    fz.rows.push(row(
        kind,
        format!("{pre}FancyZones の横向きの既定を {tname_s} {verb} ({before} → {tname_s})"),
        &[],
    ));
}

/// 取り込み (WSL の `import_layouts`): PC のレイアウトを名前で選び、repo の custom-layouts.json へ写す。同じ uuid は同じ位置で置き換え、無ければ
/// 末尾に足す。PC のファイル・settings.json・記録には書かない。
pub(super) fn import_layouts(ctx: &mut Ctx, fz: &mut Fz, names: &[String]) -> Outcome {
    let fail = |ctx: &mut Ctx, lines: Vec<String>, text: String| -> Outcome {
        warn(ctx, &lines);
        row(Kind::Failed, text, &lines[1..])
    };
    let problems = layouts_problems(&fz.layouts);
    if !problems.is_empty() {
        return fail(
            ctx,
            vec![
                format!("{LAYOUTS_REL} に誤りがあるので、取り込めません。先に直してください:"),
                problems.join("\n"),
            ],
            format!("{LAYOUTS_REL} に誤りがあるので取り込まない"),
        );
    }
    if let Err(lines) = crate::steps::terminal::uncommitted(ctx, LAYOUTS_REL) {
        for l in &lines {
            ctx.say(l);
        }
        return row(
            Kind::Failed,
            format!(
                "{LAYOUTS_REL} に commit していない変更があるか、確かめられないので取り込まない"
            ),
            &[lines[0].trim_start_matches("!! ").to_string()],
        );
    }
    if !fz.pc_layouts.exists() {
        return fail(
            ctx,
            vec![format!(
                "PC に custom-layouts.json がありません: {}",
                fz.pc_layouts.display()
            )],
            "PC に custom-layouts.json が無い".to_string(),
        );
    }
    let Some(pc) = read_retry(ctx, &fz.pc_layouts, super::layouts_shape) else {
        return fail(
            ctx,
            vec![format!(
                "PC の custom-layouts.json を読めません: {}",
                fz.pc_layouts.display()
            )],
            "PC の custom-layouts.json を読めない".to_string(),
        );
    };
    let cur = layouts_of(&pc);
    let mut doc = read_file(&fz.layouts).expect("確かめた");
    let mut log = Vec::new();
    let mut errors = Vec::new();
    let mut changed = false;
    for n in names {
        let name = Jv::String(n.clone());
        let m: Vec<&Jv> = cur
            .iter()
            .filter(|l| l.is_object() && jv::jq_eq(l.get("name").unwrap_or(&Jv::Null), &name))
            .collect();
        if m.is_empty() {
            let have: Vec<String> = cur
                .iter()
                .filter(|l| l.is_object())
                .map(|l| match l.get("name") {
                    None | Some(Jv::Null) | Some(Jv::Bool(false)) => "(名前なし)".to_string(),
                    Some(x) => x.tostring(),
                })
                .collect();
            errors.push(format!(
                "PC に「{n}」というカスタムレイアウトがありません (PC にあるもの: {})。",
                have.join("、")
            ));
            continue;
        }
        if m.len() > 1 {
            let uuids: Vec<String> = m
                .iter()
                .map(|l| match l.get("uuid") {
                    None | Some(Jv::Null) | Some(Jv::Bool(false)) => "(無い)".to_string(),
                    Some(x) => x.tostring(),
                })
                .collect();
            errors.push(format!(
                "PC に「{n}」というカスタムレイアウトが {} つあります (uuid: {})。エディターで名前を変えてから取り込んでください。",
                m.len(),
                uuids.join("、")
            ));
            continue;
        }
        let l = m[0].clone();
        let bad = layout_problems(&Jv::Object(vec![(
            "custom-layouts".into(),
            Jv::Array(vec![l.clone()]),
        )]));
        if !bad.is_empty() {
            errors.push(format!(
                "「{n}」は repo に置けない形です: {}",
                bad.join(" ")
            ));
            continue;
        }
        let list = layouts_of(&doc);
        let uuid = l.get("uuid").cloned().unwrap_or(Jv::Null);
        match uuid_index(&list, &uuid) {
            Some(i) => {
                if jv::jq_eq(&list[i], &l) {
                    log.push(format!("  {n}: repo と同じです"));
                } else {
                    let mut list = list;
                    list[i] = l;
                    doc.set("custom-layouts", Jv::Array(list));
                    changed = true;
                    log.push(format!("  {n}: repo の同じ uuid のレイアウトを置き換えた"));
                }
            }
            None => {
                let same: Vec<String> = list
                    .iter()
                    .filter(|x| jv::jq_eq(x.get("name").unwrap_or(&Jv::Null), &name))
                    .map(|x| x.get("uuid").cloned().unwrap_or(Jv::Null).tostring())
                    .collect();
                if !same.is_empty() {
                    errors.push(format!(
                        "repo に、同じ名前「{n}」の別のレイアウトがあります (uuid: {})。エディターで名前を変えてから取り込んでください。",
                        same.join("、")
                    ));
                } else {
                    let mut list = list;
                    list.push(l);
                    doc.set("custom-layouts", Jv::Array(list));
                    changed = true;
                    log.push(format!("  {n}: 足した"));
                }
            }
        }
    }
    if !errors.is_empty() {
        for e in &errors {
            ctx.say(format!("!! {e}"));
        }
        ctx.say("   何も取り込んでいません。");
        let mut o = row(
            Kind::Failed,
            format!(
                "取り込めない名前がある ({} 件。何も取り込んでいない)",
                errors.len()
            ),
            &[],
        );
        o.notes = errors;
        return o;
    }
    if !changed {
        ctx.say("取り込むものはありません (repo と同じです)。");
        for l in &log {
            ctx.say(l);
        }
        return row(Kind::Ok, "取り込むものは無い (repo と同じ)", &[]);
    }
    let problems = layout_problems(&doc);
    if !problems.is_empty() {
        return fail(
            ctx,
            vec![
                format!("取り込むと {LAYOUTS_REL} に誤りができるので、取り込めません:"),
                problems.join("\n"),
            ],
            format!("取り込むと {LAYOUTS_REL} に誤りができるので取り込まない"),
        );
    }
    if let Err(e) = super::place(&fz.layouts, &pt_form(&doc)) {
        return fail(
            ctx,
            vec![format!(
                "{LAYOUTS_REL} に書けませんでした: {} ({e})",
                fz.layouts.display()
            )],
            format!("{LAYOUTS_REL} に書けない"),
        );
    }
    ctx.say(format!(
        "==> PC のレイアウトを {LAYOUTS_REL} へ取り込みました"
    ));
    for l in &log {
        ctx.say(l);
    }
    ctx.say(format!(
        "git -C {} diff -- {LAYOUTS_REL} で見て commit してください。",
        ctx.repo.display()
    ));
    ctx.say("push すると、ほかの PC には次の apply で足されます (その PC で直していたものは、書き換えずに知らせます)。");
    row(
        Kind::Ok,
        format!("PC のレイアウトを {LAYOUTS_REL} へ取り込んだ"),
        &[format!(
            "git -C {} diff -- {LAYOUTS_REL} で見て commit して push する",
            ctx.repo.display()
        )],
    )
}
