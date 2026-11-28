//! herdr-app の無いマシン (SSH 先や WSL の Linux のハブ) で、hc の core の doc `herdr-app` の space を読み書きする。
//!
//! herdr-app (Windows) は、マシンごとの space を、そのマシンの hc の core の doc `herdr-app` に置く:
//!
//! ```text
//! {"spaces": [{"id": "sp…", "name": "…", "folder": "…", "tabs": [{"id": "tb…", "name": "", "root": {"type": "row",
//!   "id": "tb…", "children": [{"type": "block", "id": "p…", "content": {"terminal": "t8"}, "size": {"weight": 0.5}}, …]}}]}, …]}
//! ```
//!
//! herdr-app は doc の event を読んで画面を描き直す。Linux の machine の hc の doc と Windows の herdr-app 0.1.16 で確かめた:
//!
//! - 知らない id の label `herdr.space`・`herdr.tab` を付けた端末を見ると、その id の space・tab を作る (name は空で、一覧には
//!   フォルダ名が出る。1 秒ほどで doc に入る)。既にある space・tab の id なら、同じ tab に並べる (E1・E2)
//! - space の最後の端末を `hc kill`・`hc rm` すると、その space を doc から消す (E10)
//! - doc から space を消すと画面から消える。中の端末は終わらない (E8)。doc に space を足して端末を指すと拾う (E7)
//! - doc の `spaces[].name` を書き替えると、一覧の名前が替わる
//!
//! doc はほかの書き手 (herdr-app) も書くので、書くときは読み直してから自分の所だけを替え、`doc.set` が版の違い (conflict) で
//! 断ったら読み直して打ち直す。

use std::collections::HashMap;
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::hc::{Doc, Hc, Runner, finished, local_id, split_addr};

/// herdr-app がマシンごとの space を置く、hc の core の doc の名前。
pub const APP_DOC: &str = "herdr-app";
/// doc.set が版の違い (conflict) で断ったときに、読み直して打つ回数の上限 (初めの 1 回を含む)。
const ATTEMPTS: u32 = 5;
/// 打ち直す前に待つ長さ (herdr-app が続けて書いている間をやり過ごす)。
const RETRY_WAIT: Duration = Duration::from_millis(200);
/// herdr-app が space を作る・消すのを待つときの、読み直しの間。
pub const POLL_WAIT: Duration = Duration::from_millis(500);
/// 立てた子の端末を herdr-app が space に置くのを待つ回数 (約 10 秒。herdr-app はふつう 1 秒ほどで置く)。
pub const PLACE_POLLS: u32 = 20;
/// 片付けた子の space を herdr-app が消すのを待つ回数 (約 5 秒)。
pub const GONE_POLLS: u32 = 10;

/// どのマシンの doc か (文に入れる句): `hc の doc herdr-app`・`<machine> の hc の doc herdr-app`。
pub fn what(on: Option<&str>) -> String {
    match on {
        Some(m) => format!("{m} の hc の doc {APP_DOC}"),
        None => format!("hc の doc {APP_DOC}"),
    }
}

/// herdr-app の id の形 (頭の字と、uuid の版 4 の形の 32 字の hex): `sp2ad5404a64864030b97e636c14d895c1`。
pub fn format_id(prefix: &str, n: u128) -> String {
    let n = (n & !(0xF << 76)) | (0x4 << 76);
    let n = (n & !(0x3 << 62)) | (0x2 << 62);
    format!("{prefix}{n:032x}")
}

/// 新しい id (`sp`・`tb`・`p` の頭)。herdr-app が作る id と同じ形で、ほかと重ならない。
pub fn new_id(r: &dyn Runner, prefix: &str) -> String {
    format_id(prefix, r.random_u128())
}

/// doc を読めなかったわけ (中身は文に入れる句)。
#[derive(Debug)]
enum ReadErr {
    /// まだ無い (版 0。herdr-app がこのマシンの space を置いたことが無い)。herdr-app が初めて書くこともあるので、待つ間は読み直す。
    Missing(String),
    /// 形が違う・hc が doc.get を知らない (読み直しても変わらない)。
    Bad(String),
    /// 読めない (hc connect が落ちた・時間切れ・core の error)。一時のこともあるので、待つ間は読み直す。
    Failed(String),
}

impl ReadErr {
    fn why(self) -> String {
        match self {
            Self::Missing(w) | Self::Bad(w) | Self::Failed(w) => w,
        }
    }
}

/// doc を読み、`spaces` の配列がある形かを確かめる。読めない・まだ無い (版 0)・形が違うときは、わけを返す。
fn read_doc(hc: &Hc<'_>, on: Option<&str>) -> std::result::Result<Doc, ReadErr> {
    let what = what(on);
    let doc = match hc.doc_get(APP_DOC, on) {
        Ok(Ok(doc)) => doc,
        Ok(Err(f)) if f.kind == "unknown_method" => {
            return Err(ReadErr::Bad(format!(
                "hc が doc.get を知らない ({})",
                f.message
            )));
        }
        Ok(Err(f)) => {
            return Err(ReadErr::Failed(format!(
                "{what} を読めない ({})",
                f.message
            )));
        }
        Err(e) => {
            return Err(ReadErr::Failed(format!(
                "{what} を読めない ({})",
                e.message()
            )));
        }
    };
    if doc.version == 0 {
        // herdr-app がこのマシンの space を置いたことが無い。herdr-app が置く前の doc を作らない
        return Err(ReadErr::Missing(format!("{what} もまだ無い (版 0)")));
    }
    if spaces(&doc.value).is_none() {
        return Err(ReadErr::Bad(format!(
            "{what} の形が違う (spaces の配列が無い)"
        )));
    }
    Ok(doc)
}

fn spaces(value: &Value) -> Option<&Vec<Value>> {
    value.get("spaces").and_then(Value::as_array)
}

fn spaces_mut(value: &mut Value) -> Option<&mut Vec<Value>> {
    value.get_mut("spaces").and_then(Value::as_array_mut)
}

/// id の space (同じ id が 2 つあれば両方)。
fn with_id<'v>(value: &'v Value, id: &str) -> Vec<&'v Value> {
    spaces(value)
        .map(|all| all.iter().filter(|sp| sp["id"] == id).collect())
        .unwrap_or_default()
}

/// space のペインの端末 (`content.terminal`) を、そのマシンの中の住所で並べる (row・column の入れ子の形を問わず拾う)。
pub fn terminals_of(space: &Value) -> Vec<String> {
    fn walk(v: &Value, out: &mut Vec<String>) {
        match v {
            Value::Object(o) => {
                if let Some(t) = o
                    .get("content")
                    .and_then(|c| c.get("terminal"))
                    .and_then(Value::as_str)
                {
                    let local = split_addr(t).1.to_owned();
                    if !out.contains(&local) {
                        out.push(local);
                    }
                }
                for child in o.values() {
                    walk(child, out);
                }
            }
            Value::Array(a) => {
                for child in a {
                    walk(child, out);
                }
            }
            _ => {}
        }
    }
    let mut out = Vec::new();
    walk(&space["tabs"], &mut out);
    out
}

fn has_terminal(space: &Value, terminal: &str) -> bool {
    let local = split_addr(terminal).1;
    terminals_of(space).iter().any(|t| t == local)
}

/// 端末のペインのある space の id (最初のもの)。
fn space_of(value: &Value, terminal: &str) -> Option<String> {
    spaces(value)?
        .iter()
        .find(|s| has_terminal(s, terminal))
        .and_then(|s| s["id"].as_str().map(str::to_owned))
}

/// space の今の名前 (空でないとき)。読めない・無い・同じ id が 2 つあれば None。
pub fn name_of(hc: &Hc<'_>, on: Option<&str>, space: &str) -> Option<String> {
    let doc = read_doc(hc, on).ok()?;
    match with_id(&doc.value, local_id(space)).as_slice() {
        [sp] => sp["name"]
            .as_str()
            .filter(|n| !n.is_empty())
            .map(str::to_owned),
        _ => None,
    }
}

/// [`rename`] の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum Rename {
    /// 替えた (書く前の版 → 書いた後の版)。
    Renamed { from: u64, to: u64 },
    /// もうその名前だった (書かない。版を進めず、doc の event も出さない)。
    Same,
    /// 替えずに終える (`note: ` に続ける 1 行)。
    Skip(String),
    /// 書けなかった (わけ)。
    Failed(String),
}

/// doc の、id が `space` の space の name だけを `name` にする (ほかの space・tab・ペインは読んだまま書き戻す)。doc がまだ
/// 無い (版 0) なら書かない (herdr-app が置く前の doc を作らない)。`on` は別のマシンの doc (None はこの core)。
pub fn rename(r: &dyn Runner, hc: &Hc<'_>, on: Option<&str>, space: &str, name: &str) -> Rename {
    let space = local_id(space);
    let what = what(on);
    let skip = |why: String| Rename::Skip(format!("herdr-app が無く、{why}"));
    for attempt in 1..=ATTEMPTS {
        if attempt > 1 {
            r.sleep(RETRY_WAIT);
        }
        let mut doc = match read_doc(hc, on) {
            Ok(doc) => doc,
            Err(e) => {
                return skip(format!("{} ので、space {space} の名前は替えない", e.why()));
            }
        };
        let Some(all) = spaces_mut(&mut doc.value) else {
            return skip(format!(
                "{what} の形が違う (spaces の配列が無い) ので、space {space} の名前は替えない"
            ));
        };
        let mut hits: Vec<&mut Map<String, Value>> = all
            .iter_mut()
            .filter_map(Value::as_object_mut)
            .filter(|sp| sp.get("id").and_then(Value::as_str) == Some(space))
            .collect();
        let sp = match hits.as_mut_slice() {
            [sp] => sp,
            [] => {
                return skip(format!(
                    "{what} に space {space} が無いので、名前は替えない"
                ));
            }
            many => {
                return skip(format!(
                    "{what} に space {space} が {} つあるので、名前は替えない",
                    many.len()
                ));
            }
        };
        if sp.get("name").and_then(Value::as_str) == Some(name) {
            return Rename::Same;
        }
        sp.insert("name".to_owned(), json!(name));
        match hc.doc_set(APP_DOC, on, &doc.value, doc.version) {
            Ok(Ok(to)) => {
                return Rename::Renamed {
                    from: doc.version,
                    to,
                };
            }
            Ok(Err(f)) if f.kind == "conflict" => {}
            Ok(Err(f)) => return Rename::Failed(f.message),
            Err(e) => return Rename::Failed(e.message().to_owned()),
        }
    }
    Rename::Failed(gave_up())
}

fn gave_up() -> String {
    format!("{ATTEMPTS} 回とも版が合わない (読んでから書くまでに、ほかが doc を書き替えた)")
}

/// 子の端末の space ([`ensure`] が確かめる。id はそのマシンの中の id)。
#[derive(Debug, Clone, Copy)]
pub struct NewSpace<'a> {
    pub id: &'a str,
    pub tab: &'a str,
    /// 付ける名前 (`<英字> <label>`)。
    pub name: &'a str,
    /// space のフォルダ (子の worktree。子のマシンのパス)。
    pub folder: &'a str,
    /// 子の端末 (そのマシンの中の住所でも、マシン付きの住所でもよい)。
    pub terminal: &'a str,
}

/// [`ensure`] の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum Ensured {
    /// space に子の端末がいる (herdr-app が label から置いた)。名前をそろえた結果。
    Placed(Rename),
    /// herdr-app が置かなかった (動いていない・遅い)。space が無かったので、名前つきの space を doc に足した (版)。
    Added { from: u64, to: u64 },
    /// space はあるが、子の端末がまだいない (立て直す前の端末の space で、herdr-app が動いていない)。名前をそろえた結果。
    Unplaced(Rename),
    /// 子の端末が、ほかの space (id) にいる。名前も space も書かない。
    Elsewhere(String),
    /// doc を読めない・まだ無い・形が違う (わけの句)。何も書いていない。
    Skip(String),
    /// 書けなかった (わけ)。
    Failed(String),
}

/// label `herdr.space`・`herdr.tab` で立てた子の端末の space を確かめ、名前を付ける (`pjp child new`・`restart`)。herdr-app が
/// 子の端末を space に置くのを最長 `polls` 回 ([`POLL_WAIT`] おき) 待ち、置いたら名前をそろえる。置かなければ、space が無ければ
/// herdr-app と同じ形 (1 つの tab に子の端末のペインだけ) で doc の末尾に足し、あれば名前だけそろえる。
pub fn ensure(
    r: &dyn Runner,
    hc: &Hc<'_>,
    on: Option<&str>,
    sp: &NewSpace<'_>,
    polls: u32,
) -> Ensured {
    match wait_placed(r, hc, on, sp.id, sp.terminal, polls) {
        Wait::Placed => Ensured::Placed(rename(r, hc, on, sp.id, sp.name)),
        Wait::Elsewhere(other) => Ensured::Elsewhere(other),
        Wait::Skip(why) => Ensured::Skip(why),
        Wait::NotYet => add(r, hc, on, sp),
    }
}

/// [`wait_placed`] の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum Wait {
    /// space に子の端末のペインがある。
    Placed,
    /// 待ち終えても無い (herdr-app が動いていない・遅い)。
    NotYet,
    /// 子の端末が、ほかの space (id) にいる。
    Elsewhere(String),
    /// 子の端末の住所が分からない・doc の形が違う (わけの句)。
    Skip(String),
}

/// herdr-app が子の端末を space `space` に置くのを、最長 `polls` 回 ([`POLL_WAIT`] おき) 待つ。doc がまだ無い (herdr-app が
/// 初めて書くこともある)・一時に読めないときは読み直す。
pub fn wait_placed(
    r: &dyn Runner,
    hc: &Hc<'_>,
    on: Option<&str>,
    space: &str,
    terminal: &str,
    polls: u32,
) -> Wait {
    let id = local_id(space);
    let terminal = split_addr(terminal).1;
    if terminal.is_empty() {
        // 空の端末を指すペインを、ほかの書き手と分け合う doc に書かない
        return Wait::Skip("子の端末の住所が分からない".to_owned());
    }
    for i in 0..polls {
        if i > 0 {
            r.sleep(POLL_WAIT);
        }
        match read_doc(hc, on) {
            Ok(doc) => match space_of(&doc.value, terminal) {
                Some(found) if found == id => return Wait::Placed,
                Some(other) => return Wait::Elsewhere(other),
                None => {}
            },
            Err(ReadErr::Bad(why)) => return Wait::Skip(why),
            Err(ReadErr::Missing(_) | ReadErr::Failed(_)) => {}
        }
    }
    Wait::NotYet
}

/// herdr-app が置かなかった子の端末の space を、doc の末尾に足す (もうあれば名前だけそろえる)。
fn add(r: &dyn Runner, hc: &Hc<'_>, on: Option<&str>, sp: &NewSpace<'_>) -> Ensured {
    let (id, tab) = (local_id(sp.id), local_id(sp.tab));
    let terminal = split_addr(sp.terminal).1;
    let pane = new_id(r, "p");
    for attempt in 1..=ATTEMPTS {
        if attempt > 1 {
            r.sleep(RETRY_WAIT);
        }
        let mut doc = match read_doc(hc, on) {
            Ok(doc) => doc,
            Err(e) => return Ensured::Skip(e.why()),
        };
        let hits = with_id(&doc.value, id);
        if !hits.is_empty() {
            // 待ち終えた後に herdr-app が作った・前の端末の space が残っている
            let placed = hits.iter().any(|s| has_terminal(s, terminal));
            let renamed = rename(r, hc, on, id, sp.name);
            return if placed {
                Ensured::Placed(renamed)
            } else {
                Ensured::Unplaced(renamed)
            };
        }
        if let Some(other) = space_of(&doc.value, terminal) {
            return Ensured::Elsewhere(other);
        }
        // herdr-app が新しい space を書く形と同じ (root の id は tab と同じ。1 つのペインには size を付けない)
        let entry = json!({
            "folder": sp.folder,
            "id": id,
            "name": sp.name,
            "tabs": [{
                "id": tab,
                "name": "",
                "root": {
                    "children": [{"content": {"terminal": terminal}, "id": pane, "type": "block"}],
                    "id": tab,
                    "type": "row",
                },
            }],
        });
        let Some(all) = spaces_mut(&mut doc.value) else {
            return Ensured::Skip(format!("{} の形が違う (spaces の配列が無い)", what(on)));
        };
        all.push(entry);
        match hc.doc_set(APP_DOC, on, &doc.value, doc.version) {
            Ok(Ok(to)) => {
                return Ensured::Added {
                    from: doc.version,
                    to,
                };
            }
            Ok(Err(f)) if f.kind == "conflict" => {}
            Ok(Err(f)) => return Ensured::Failed(f.message),
            Err(e) => return Ensured::Failed(e.message().to_owned()),
        }
    }
    Ensured::Failed(gave_up())
}

/// [`remove`] の結果。
#[derive(Debug, PartialEq, Eq)]
pub enum Removed {
    /// doc に space が無い (herdr-app が消した・もう無かった)。
    Gone,
    /// herdr-app が消さなかった (動いていない・遅い) ので、doc から消した (版)。
    Removed { from: u64, to: u64 },
    /// space に子のほかの生きた端末 (か、確かめられない端末) がいるので残した。
    Kept(Others),
    /// doc を読めない・まだ無い・形が違う (わけの句)。何も書いていない。
    Skip(String),
    /// 書けなかった (わけ)。
    Failed(String),
}

/// 片付けた子の space が残らないようにする (`pjp child cleanup`。子の端末を消した後に打つ)。最後の端末が消えると herdr-app が
/// space を消すので、最長 `polls` 回 ([`POLL_WAIT`] おき) 待つ。残っていて、中に子 (`ended`。もう消した端末) のほかの生きた
/// 端末が無ければ doc から消す。ほかの生きた端末 (ユーザーが開いた shell など) がいれば、残す (herdr-app の `space.close` は
/// 中の端末も終わらせるので使わない。doc から消しても、label のある端末は herdr-app が space に置き直す)。`ended` が None
/// (控えの住所に別の端末がいる) なら、どの端末も子とみない。
pub fn remove(
    r: &dyn Runner,
    hc: &Hc<'_>,
    on: Option<&str>,
    space: &str,
    ended: Option<&str>,
    polls: u32,
) -> Removed {
    let id = local_id(space);
    let ended = ended.map(|t| split_addr(t).1);
    let mut checked: HashMap<String, Live> = HashMap::new();
    for i in 0..polls {
        if i > 0 {
            r.sleep(POLL_WAIT);
        }
        let doc = match read_doc(hc, on) {
            Ok(doc) => doc,
            // 一時に読めない: 読み直す (読めないまま待ち終えたら、下の読み直しでわけを返す)
            Err(ReadErr::Failed(_)) => continue,
            Err(e) => return Removed::Skip(e.why()),
        };
        let hits = with_id(&doc.value, id);
        if hits.is_empty() {
            return Removed::Gone;
        }
        let others = others_of(hc, on, &hits, ended, &mut checked);
        if !others.is_empty() {
            return Removed::Kept(others);
        }
    }
    for attempt in 1..=ATTEMPTS {
        if attempt > 1 {
            r.sleep(RETRY_WAIT);
        }
        let mut doc = match read_doc(hc, on) {
            Ok(doc) => doc,
            Err(e) => return Removed::Skip(e.why()),
        };
        let hits = with_id(&doc.value, id);
        if hits.is_empty() {
            return Removed::Gone;
        }
        let others = others_of(hc, on, &hits, ended, &mut checked);
        if !others.is_empty() {
            return Removed::Kept(others);
        }
        let Some(all) = spaces_mut(&mut doc.value) else {
            return Removed::Skip(format!("{} の形が違う (spaces の配列が無い)", what(on)));
        };
        all.retain(|sp| sp["id"] != id);
        match hc.doc_set(APP_DOC, on, &doc.value, doc.version) {
            Ok(Ok(to)) => {
                return Removed::Removed {
                    from: doc.version,
                    to,
                };
            }
            Ok(Err(f)) if f.kind == "conflict" => {}
            Ok(Err(f)) => return Removed::Failed(f.message),
            Err(e) => return Removed::Failed(e.message().to_owned()),
        }
    }
    Removed::Failed(gave_up())
}

/// space の、子 (`ended`) のほかの端末 (そのマシンの中の住所)。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Others {
    /// 生きている端末。
    pub live: Vec<String>,
    /// `hc get` で確かめられなかった端末 (生きているとみる)。
    pub unknown: Vec<String>,
}

impl Others {
    pub fn is_empty(&self) -> bool {
        self.live.is_empty() && self.unknown.is_empty()
    }
}

/// 端末の生き死に (`hc get` で確かめた)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Live {
    Yes,
    No,
    Unknown,
}

/// 子の space (`space`) にいる、子 (`ended`) のほかの端末 (`pjp child cleanup` が子を終える前に確かめる)。space が無ければ空。
/// doc を読めなければ、わけを返す。
pub fn others(
    hc: &Hc<'_>,
    on: Option<&str>,
    space: &str,
    ended: Option<&str>,
) -> std::result::Result<Others, String> {
    let doc = read_doc(hc, on).map_err(ReadErr::why)?;
    let hits = with_id(&doc.value, local_id(space));
    Ok(others_of(
        hc,
        on,
        &hits,
        ended.map(|t| split_addr(t).1),
        &mut HashMap::new(),
    ))
}

/// space のペインの端末のうち、`ended` のほかで生きている (確かめられない) もの。終わった・消えた端末のペインは数えない。
/// 確かめた結果は `checked` に控える (待つ間に打ち直さない)。
fn others_of(
    hc: &Hc<'_>,
    on: Option<&str>,
    hits: &[&Value],
    ended: Option<&str>,
    checked: &mut HashMap<String, Live>,
) -> Others {
    let mut out = Others::default();
    for t in hits.iter().flat_map(|sp| terminals_of(sp)) {
        if Some(t.as_str()) == ended || out.live.contains(&t) || out.unknown.contains(&t) {
            continue;
        }
        let live = *checked.entry(t.clone()).or_insert_with(|| {
            let addr = match on {
                Some(m) => format!("{m}/{t}"),
                None => t.clone(),
            };
            match hc.get(&addr) {
                Ok(Some(term)) if finished(&term) => Live::No,
                Ok(Some(_)) => Live::Yes,
                Ok(None) => Live::No,
                Err(_) => Live::Unknown,
            }
        });
        match live {
            Live::Yes => out.live.push(t),
            Live::Unknown => out.unknown.push(t),
            Live::No => {}
        }
    }
    out
}

#[cfg(test)]
mod tests;
