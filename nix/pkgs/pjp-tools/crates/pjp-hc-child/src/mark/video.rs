//! `pjp mark video` (spec `docs/superpowers/specs/2026-11-21-spaces-video-mark-design.md`): 解説動画を作っている間 (⏳) と、
//! 作り終えてユーザーがまだ見ていない間 (✅) の印を、動画を作る端末の label `pjp.video.<作り始めた日時>` で付け外しする。
//! herdr-app の mod pjp-spaces が、会話とその子孫の動画を space の行の 3 行目から 1 本 1 行 (`🎬⏳:<名前>`・`🎬✅:<名前>`) で出す。
//!
//! ```text
//! pjp mark video start '<名前>' [--terminal <t>]               作っている印 (⏳) を付ける
//! pjp mark video done ['<名前>'] [--terminal <t>]              作っている印を済んだ印 (✅) にする
//! pjp mark video stop ['<名前>'] [--all] [--terminal <t>]      作りかけの印 (⏳) を、この端末と子孫から探して外す
//! pjp mark video watched ['<名前>'] [--all] [--terminal <t>]   見た動画の印 (✅) を、この端末と子孫から探して外す
//! ```
//!
//! label の値は 1 行の JSON (`name`・`state`・`started`・`ended`・`from`)。名前に空白・`=`・日本語が入っても崩れない。
//! hc の端末の外 (`HC_TERMINAL_ID` も `--terminal` も無い) では、何もせず note を出して 0 で終える (旧 herdr やただの端末で、
//! 動画の skill の手順を落とさない)。`pjp child cleanup`・`restart` も、ここの読み手で ✅ を移す・引き継ぐ。

use std::collections::{HashSet, VecDeque};
use std::io::Write;

use pjp_core::time::JstDateTime;
use pjp_core::{Error, Result, exit};
use serde_json::{Value, json};

use crate::args::{self, Spec};
use crate::hc::{Hc, Runner, label_of};

/// 動画の印の label の名前の頭 (後ろは作り始めた日時の 14 桁。重なれば `-2`…)。
pub const LABEL_PREFIX: &str = "pjp.video.";
/// pjp-spaces が出す動画の行の頭 (main.js の `MARKS.making`・`MARKS.made` と同じ。後ろに `:<名前>` が付く)。
pub const MAKING_MARK: &str = "🎬⏳";
pub const MADE_MARK: &str = "🎬✅";
/// pjp-spaces がホバーに出す名前の字数 (main.js の ASK_MAX と同じ)。これより長い名前には note を出す。
const NAME_TIP_MAX: usize = 60;

pub const USAGE: &str = "\
pjp mark video — 解説動画を作っている間 (🎬⏳) と、作り終えてユーザーがまだ見ていない間 (🎬✅) の印 (herdr-app の mod
pjp-spaces が space の行の 3 行目から 1 本 1 行で 🎬⏳:<名前>・🎬✅:<名前> と出す。会話の行には、その会話と子孫の動画が並ぶ)

使い方:
  pjp mark video start '<名前>' [--terminal <t>]              作っている印 (🎬⏳) を付ける (作り始めに。同じ名前の ⏳ が
                                                             あれば何もせず、✅ なら作り直しとして ⏳ に戻す)
  pjp mark video done ['<名前>'] [--terminal <t>]             作っている印を済んだ印 (🎬✅) にする (書き出して載せ
                                                             終えたら。⏳ が無ければ ✅ を新しく付ける)
  pjp mark video stop ['<名前>'] [--all] [--terminal <t>]     作りかけの印を外す (止めた・止まった。この端末と子孫から探す)
  pjp mark video watched ['<名前>'] [--all] [--terminal <t>]  見た動画の印を外す (ユーザーが見たと言ったら。この端末と、
                                                             hc の親子をたどった子孫の端末から探す)

端末を省くとこの端末 ($HC_TERMINAL_ID)。hc の端末の外では何もせず、note を出して終了コード 0。
名前は '<チケットの ID> <短尺 | 詳細版> <一言>' の形 (チケットの ID・短尺と詳細版の別が無ければ省く)。名前を省くと、その
状態の印がちょうど 1 つのときだけそれを選ぶ。名前は、同じ名前のもの (状態を問わない) を先に、無ければ空白で分けた語がどれも
入っているものを選ぶ (英字は大文字と小文字を区別しない。watched 短尺・watched 'TKT-n 詳細')。2 つ以上に当たれば、候補を
並べて何もせずに終了コード 1 (全部なら --all。名前と合わせて --all 'TKT-n' のように絞れる)。同じ動画の写し (名前・作り
始めた日時・状態が同じ。片付けで親へ移した後に子を終えられなかったときなど) は 1 本と数え、まとめて外す。
";

/// 動画の状態。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum State {
    /// 作っている (⏳)。
    Making,
    /// 作り終えて載せたが、ユーザーがまだ見ていない (✅)。
    Done,
}

impl State {
    fn word(self) -> &'static str {
        match self {
            State::Making => "making",
            State::Done => "done",
        }
    }

    fn from_word(word: &str) -> Option<Self> {
        match word {
            "making" => Some(State::Making),
            "done" => Some(State::Done),
            _ => None,
        }
    }
}

/// 動画 1 本の印 (label 1 つ)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Video {
    /// label の名前 (`pjp.video.20261121130512`)。
    pub key: String,
    pub name: String,
    pub state: State,
    /// 作り始めた日時 (`2026-11-21T13:05:12+09:00`)。並べる順。
    pub started: String,
    /// 済んだ日時 (`done` のとき)。
    pub ended: Option<String>,
    /// `pjp child cleanup` が親へ移したとき、元の端末 (`子 A (<machine>/t92)`)。
    pub from: Option<String>,
}

impl Video {
    /// label の値 (1 行の JSON)。
    pub fn value(&self) -> String {
        let mut v = json!({"name": self.name, "state": self.state.word(), "started": self.started});
        if let Some(e) = &self.ended {
            v["ended"] = json!(e);
        }
        if let Some(f) = &self.from {
            v["from"] = json!(f);
        }
        v.to_string()
    }

    /// `hc label` に渡す `<キー>=<値>`。
    pub fn pair(&self) -> String {
        format!("{}={}", self.key, self.value())
    }

    /// pjp-spaces の動画の行の頭 (`🎬⏳`・`🎬✅`)。
    pub fn mark(&self) -> &'static str {
        match self.state {
            State::Making => MAKING_MARK,
            State::Done => MADE_MARK,
        }
    }

    /// pjp-spaces が space の行の 3 行目から出す 1 本の行の字面 (`🎬⏳:TKT-n 短尺 x`。main.js の `videoText` と同じ。
    /// ユーザーが書いた形のまま、`:` の後ろに空白を置かない)。
    pub fn row_text(&self) -> String {
        format!("{}:{}", self.mark(), self.name)
    }

    /// 1 行の説明 (`🎬⏳:TKT-n 短尺 x (子 A <machine>/t13・11/21 13:05 から作っている)`)。`at` はどの端末か。
    pub fn describe(&self, at: Option<&str>) -> String {
        let mut parts: Vec<String> = at.map(str::to_owned).into_iter().collect();
        parts.push(match self.state {
            State::Making => format!("{} から作っている", short_time(&self.started)),
            State::Done => format!(
                "{} に載せた・見ていない",
                short_time(self.ended.as_deref().unwrap_or(&self.started))
            ),
        });
        if let Some(f) = &self.from {
            parts.push(format!("片付けた{f} から移した"));
        }
        format!("{} ({})", self.row_text(), parts.join("・"))
    }
}

/// 端末 (`hc get` の答え) の動画の印。読めない値 (JSON の object でない・`state` が知らない語) は除き、作っているもの (⏳) を
/// 先に、それぞれ作り始めた順に並べる (pjp-spaces の並びと同じ)。
pub fn videos_of(term: &Value) -> Vec<Video> {
    let Some(labels) = term["labels"].as_object() else {
        return Vec::new();
    };
    let mut out: Vec<Video> = labels
        .iter()
        .filter_map(|(k, v)| parse(k, v.as_str()?))
        .collect();
    out.sort_by(order);
    out
}

/// 並び: 作っているもの (⏳) を先、済んだもの (✅) を後に、それぞれ作り始めた順 (main.js の byVideo と同じ)。
fn order(a: &Video, b: &Video) -> std::cmp::Ordering {
    let rank = |v: &Video| u8::from(v.state == State::Done);
    rank(a)
        .cmp(&rank(b))
        .then_with(|| a.started.cmp(&b.started))
        .then_with(|| a.key.cmp(&b.key))
}

fn parse(key: &str, value: &str) -> Option<Video> {
    let id = key.strip_prefix(LABEL_PREFIX)?;
    if id.is_empty() {
        return None;
    }
    let v: Value = serde_json::from_str(value).ok()?;
    let state = State::from_word(v.get("state")?.as_str()?)?;
    let text = |k: &str| {
        v.get(k)
            .and_then(Value::as_str)
            .map(squash)
            .filter(|s| !s.is_empty())
    };
    Some(Video {
        key: key.to_owned(),
        name: text("name").unwrap_or_else(|| id.to_owned()),
        state,
        started: text("started").unwrap_or_default(),
        ended: text("ended"),
        from: text("from"),
    })
}

/// 空白の続きを 1 つの空白にし、前後を除く (pjp-spaces の `replace(/\s+/g, " ").trim()` と同じ)。
fn squash(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `2026-11-21T13:05:12+09:00` → `11/21 13:05` (読めなければそのまま。pjp-spaces のホバーと同じ形)。
pub fn short_time(iso: &str) -> String {
    let short = || -> Option<String> {
        let month: u32 = iso.get(5..7)?.parse().ok()?;
        let day: u32 = iso.get(8..10)?.parse().ok()?;
        let hm = iso.get(11..16)?;
        (iso.get(4..5)? == "-" && iso.get(10..11)? == "T" && hm.get(2..3)? == ":")
            .then(|| format!("{month}/{day} {hm}"))
    };
    short().unwrap_or_else(|| iso.to_owned())
}

/// 作り始めた日時のキー (`pjp.video.20261121130512`)。
fn key_at(at: &JstDateTime) -> String {
    format!(
        "{LABEL_PREFIX}{:04}{:02}{:02}{:02}{:02}{:02}",
        at.year, at.month, at.day, at.hour, at.minute, at.second
    )
}

/// 端末の label の名前。
fn label_keys(term: &Value) -> HashSet<String> {
    term["labels"]
        .as_object()
        .map(|m| m.keys().cloned().collect())
        .unwrap_or_default()
}

/// `taken` に無いキー (`key`、あれば `key-2`・`key-3`…)。
fn free_key(taken: &HashSet<String>, key: &str) -> String {
    let mut n = 1;
    let mut k = key.to_owned();
    while taken.contains(&k) {
        n += 1;
        k = format!("{key}-{n}");
    }
    k
}

/// 子の見ていない動画 (✅) を `home` の端末 (`hc get` の答え) へ移す label の組 (`<キー>=<値>`)。`home` にキーがあれば `-2`… を
/// 足し、`from` が無ければ `from` を足す。`home` に同じ動画 (名前と作り始めた日時が同じ ✅。前の片付けで移したもの) があれば
/// 移さない。作っているもの (⏳) は移さない。
pub fn moved_pairs(videos: &[Video], home: &Value, from: &str) -> Vec<String> {
    let there = videos_of(home);
    let mut taken = label_keys(home);
    videos
        .iter()
        .filter(|v| v.state == State::Done)
        .filter(|v| {
            !there
                .iter()
                .any(|h| h.state == State::Done && h.name == v.name && h.started == v.started)
        })
        .map(|v| {
            let key = free_key(&taken, &v.key);
            taken.insert(key.clone());
            Video {
                key,
                from: v.from.clone().or_else(|| Some(from.to_owned())),
                ..v.clone()
            }
            .pair()
        })
        .collect()
}

/// 名前を確かめる (改行・タブなどの制御文字を断る)。空白の続きを 1 つにし、前後を除いて返す。空なら断る。
fn check_name(name: &str) -> Result<String> {
    if name.chars().any(char::is_control) {
        return Err(Error::config(
            "動画の名前は 1 行で書く (改行やタブなどの制御文字を入れない)",
        ));
    }
    let s = squash(name);
    if s.is_empty() {
        return Err(Error::config("動画の名前が空です"));
    }
    Ok(s)
}

fn note_long(name: &str, err: &mut dyn Write) {
    let n = name.chars().count();
    if n > NAME_TIP_MAX {
        let _ = writeln!(
            err,
            "note: 名前が長い ({n} 字)。pjp-spaces のホバーでは {NAME_TIP_MAX} 字で切れる"
        );
    }
}

/// 印のある端末と、そこにある動画 1 本。
#[derive(Debug, Clone)]
pub struct Found {
    /// 印のある端末の住所 (hc にそのまま渡せる形)。
    pub holder: String,
    /// どの端末か (`t8`・`子 A <machine>/t13`・`TKT-n <machine>/t40`・`手伝いの端末 t60`)。
    pub at: String,
    pub video: Video,
}

impl Found {
    fn line(&self) -> String {
        self.video.describe(Some(&self.at))
    }
}

/// 端末の動画。`root` (探し始めの端末) は住所だけ、子孫は pjp-spaces のホバーと同じ札 (英字・チケット・手伝いの端末) を付ける。
fn found_in(addr: &str, term: &Value, root: bool) -> Vec<Found> {
    let tag = if root {
        None
    } else if let Some(l) = label_of(term, "pjp.letter") {
        Some(format!("子 {l}"))
    } else if let Some(t) = label_of(term, "pjp.ticket") {
        Some(t.to_owned())
    } else if matches!(label_of(term, "pjp.role"), Some("hub" | "child")) {
        None
    } else {
        Some("手伝いの端末".to_owned())
    };
    let at = tag.map_or_else(|| addr.to_owned(), |t| format!("{t} {addr}"));
    videos_of(term)
        .into_iter()
        .map(|video| Found {
            holder: addr.to_owned(),
            at: at.clone(),
            video,
        })
        .collect()
}

/// 同じ動画の写し (名前・作り始めた日時・状態が同じ。cleanup が親へ移した後に子を終えられなかったときなど) を 1 本と数えた数。
fn distinct(hits: &[&Found]) -> usize {
    let mut seen: HashSet<(&str, &str, State)> = HashSet::new();
    hits.iter()
        .filter(|f| {
            seen.insert((
                f.video.name.as_str(),
                f.video.started.as_str(),
                f.video.state,
            ))
        })
        .count()
}

/// その状態のものだけ。
fn in_state<'a>(hits: &[&'a Found], state: State) -> Vec<&'a Found> {
    hits.iter()
        .copied()
        .filter(|f| f.video.state == state)
        .collect()
}

/// 名前で当てる (状態を問わずに当ててから、呼ぶ側が状態で絞る): 同じ名前のものがどれかの状態にあればそれだけ、無ければ、渡した
/// 文字を空白で分けた語がどれも名前に入っているもの (英字は大文字と小文字を区別しない)。`query` が None なら全部。
fn select<'a>(items: &'a [Found], query: Option<&str>) -> Vec<&'a Found> {
    let Some(q) = query else {
        return items.iter().collect();
    };
    let exact: Vec<&Found> = items.iter().filter(|f| f.video.name == q).collect();
    if !exact.is_empty() {
        return exact;
    }
    let words: Vec<String> = q.split_whitespace().map(str::to_ascii_lowercase).collect();
    items
        .iter()
        .filter(|f| {
            let name = f.video.name.to_ascii_lowercase();
            words.iter().all(|w| name.contains(w.as_str()))
        })
        .collect()
}

fn need(hc: &Hc<'_>, target: &str) -> Result<Value> {
    hc.get(target)?
        .ok_or_else(|| Error::failure(format!("hc に端末 {target} がありません")))
}

/// `root` の端末の生きた子孫 (`hc ls` の `parent` をたどる。近い順。同じ端末は 2 度たどらない)。ハブの core の一覧には、つないだ
/// マシンの端末も `<machine>/t13` の形で並び、`parent` もハブから見た住所になる (hc 0.1.21 で確かめた。spec §7.2)。
fn descendants(list: &[Value], root: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen: HashSet<&str> = HashSet::from([root]);
    let mut todo: VecDeque<&str> = VecDeque::from([root]);
    while let Some(p) = todo.pop_front() {
        for t in list {
            let (Some(addr), Some(parent)) = (t["address"].as_str(), t["parent"].as_str()) else {
                continue;
            };
            let live = t["state"].as_str().is_none_or(|s| s == "live");
            if parent == p && live && seen.insert(addr) {
                out.push(addr.to_owned());
                todo.push_back(addr);
            }
        }
    }
    out
}

/// `root` の端末と、その子孫の動画 (⏳ を先に作り始めた順)。子孫を読めなければ、root だけを見て `err` に知らせる。
pub fn family(hc: &Hc<'_>, root: &str, err: &mut dyn Write) -> Result<Vec<Found>> {
    let term = need(hc, root)?;
    let addr = term["address"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or(root)
        .to_owned();
    let mut found = found_in(&addr, &term, true);
    match hc.ls(false) {
        Ok(list) => {
            for d in descendants(&list, &addr) {
                match hc.get(&d) {
                    Ok(Some(t)) => found.extend(found_in(&d, &t, false)),
                    Ok(None) => {}
                    Err(e) => {
                        let _ = writeln!(err, "!! {d} の印を読めない ({e})");
                    }
                }
            }
        }
        Err(e) => {
            let _ = writeln!(err, "!! 子孫の端末を読めない ({e})。{addr} の印だけを見る");
        }
    }
    // pjp-spaces の行と同じ並び (端末をまたいで、⏳ を先に作り始めた順)。同じ日時なら探した順 (root が先)
    found.sort_by(|a, b| order(&a.video, &b.video));
    Ok(found)
}

/// 当たった印を外す (端末ごとに 1 回の hc label)。
fn remove(hc: &Hc<'_>, hits: &[&Found]) -> Result<()> {
    let mut holders: Vec<&str> = Vec::new();
    for f in hits {
        if !holders.contains(&f.holder.as_str()) {
            holders.push(&f.holder);
        }
    }
    for h in holders {
        let pairs: Vec<String> = hits
            .iter()
            .filter(|f| f.holder == h)
            .map(|f| format!("{}=", f.video.key))
            .collect();
        hc.label(h, &pairs)?;
    }
    Ok(())
}

fn list_hits(out: &mut dyn Write, what: &str, hits: &[&Found], how: &str) {
    let _ = writeln!(
        out,
        "{what}が {} つに当たる (どれも変えていない。{how}):",
        hits.len()
    );
    for f in hits {
        let _ = writeln!(out, "  {}", f.line());
    }
}

/// `pjp mark video …` (args は `video` の後ろ)。
pub fn run(
    r: &dyn Runner,
    args: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let Some((sub, rest)) = args.split_first() else {
        let _ = write!(err, "{USAGE}");
        return Ok(exit::CONFIG);
    };
    if sub == "-h" || sub == "--help" {
        let _ = write!(out, "{USAGE}");
        return Ok(exit::OK);
    }
    let spec = match sub.as_str() {
        "start" | "done" => Spec {
            flags: &[],
            values: &["--terminal"],
        },
        "stop" | "watched" => Spec {
            flags: &["--all"],
            values: &["--terminal"],
        },
        _ => {
            return Err(Error::config(format!(
                "知らないサブコマンドです: video {sub} (start・done・stop・watched)"
            )));
        }
    };
    let p = args::parse(rest, &spec)?;
    if p.help() {
        let _ = write!(out, "{USAGE}");
        return Ok(exit::OK);
    }
    let name = match p.positionals.as_slice() {
        [] => None,
        [n] => Some(check_name(n)?),
        _ => {
            return Err(Error::config(
                "動画の名前は 1 つだけ渡す (空白を含む名前は引用符で囲む)",
            ));
        }
    };
    if sub == "start" && name.is_none() {
        return Err(Error::config(
            "動画の名前を渡す (pjp mark video start '<名前>')",
        ));
    }
    let target = match p.value("--terminal")? {
        Some(t) => t.to_owned(),
        None => match r.env("HC_TERMINAL_ID") {
            Some(id) => id,
            None => {
                let _ = writeln!(
                    err,
                    "note: hc の端末の外なので、解説動画の印は付け外ししない (HC_TERMINAL_ID が無い)"
                );
                return Ok(exit::OK);
            }
        },
    };
    let hc = Hc::new(r);
    hc.require()?;
    let all = p.flag("--all");
    match (sub.as_str(), name.as_deref()) {
        ("start", Some(n)) => start(r, &hc, &target, n, out, err),
        ("done", n) => done(r, &hc, &target, n, out, err),
        ("stop", n) => stop(&hc, &target, n, all, out, err),
        (_, n) => watched(&hc, &target, n, all, out, err),
    }
}

fn start(
    r: &dyn Runner,
    hc: &Hc<'_>,
    target: &str,
    name: &str,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let term = need(hc, target)?;
    let videos = videos_of(&term);
    let now = r.now()?.to_jst();
    if videos
        .iter()
        .any(|v| v.state == State::Making && v.name == name)
    {
        let _ = writeln!(
            out,
            "{target}: もう作っていると控えてある ({MAKING_MARK}:{name})"
        );
        return Ok(exit::OK);
    }
    if let Some(v) = videos
        .iter()
        .find(|v| v.state == State::Done && v.name == name)
    {
        let again = Video {
            state: State::Making,
            started: now.iso_seconds(),
            ended: None,
            from: None,
            ..v.clone()
        };
        hc.label(target, &[again.pair()])?;
        let _ = writeln!(
            out,
            "{target}: 作り直すので、済んだ印を作っている印に戻した ({MAKING_MARK}:{name})"
        );
    } else {
        let video = Video {
            key: free_key(&label_keys(&term), &key_at(&now)),
            name: name.to_owned(),
            state: State::Making,
            started: now.iso_seconds(),
            ended: None,
            from: None,
        };
        hc.label(target, &[video.pair()])?;
        let _ = writeln!(
            out,
            "{target}: 解説動画を作っている印を付けた ({MAKING_MARK}:{name})"
        );
    }
    note_long(name, err);
    Ok(exit::OK)
}

fn done(
    r: &dyn Runner,
    hc: &Hc<'_>,
    target: &str,
    name: Option<&str>,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let term = need(hc, target)?;
    let all = found_in(target, &term, true);
    let hits = select(&all, name);
    let making = in_state(&hits, State::Making);
    let now = r.now()?.to_jst();
    match (distinct(&making), name) {
        (1, _) => {
            let pairs: Vec<String> = making
                .iter()
                .map(|f| {
                    Video {
                        state: State::Done,
                        ended: Some(now.iso_seconds()),
                        ..f.video.clone()
                    }
                    .pair()
                })
                .collect();
            hc.label(target, &pairs)?;
            let _ = writeln!(
                out,
                "{target}: 済んだ印にした ({MADE_MARK}:{}。ユーザーが見たと言ったら pjp mark video watched で外す)",
                making[0].video.name
            );
            Ok(exit::OK)
        }
        (0, Some(n)) => {
            // 済んだ印に当たれば、もう済んでいる (名前の一部で打ち直しても、✅ を重ねて付けない)
            let made = in_state(&hits, State::Done);
            if let Some(f) = made.first() {
                let _ = writeln!(
                    out,
                    "{target}: もう済んだと控えてある ({MADE_MARK}:{})",
                    f.video.name
                );
                return Ok(exit::OK);
            }
            let video = Video {
                key: free_key(&label_keys(&term), &key_at(&now)),
                name: n.to_owned(),
                state: State::Done,
                started: now.iso_seconds(),
                ended: Some(now.iso_seconds()),
                from: None,
            };
            hc.label(target, &[video.pair()])?;
            let _ = writeln!(
                out,
                "{target}: 作っている印が無かったので、済んだ印を新しく付けた ({MADE_MARK}:{n})"
            );
            note_long(n, err);
            Ok(exit::OK)
        }
        (0, None) => {
            let _ = writeln!(
                err,
                "note: {target} に作っている解説動画の印が無い (何もしない)"
            );
            Ok(exit::OK)
        }
        _ => {
            list_hits(
                out,
                "作っている解説動画の印",
                &making,
                "名前の一部を足して打ち直す",
            );
            Ok(exit::FAILURE)
        }
    }
}

fn stop(
    hc: &Hc<'_>,
    root: &str,
    name: Option<&str>,
    all: bool,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let found = family(hc, root, err)?;
    let hits = select(&found, name);
    let making = in_state(&hits, State::Making);
    if making.is_empty() {
        let made = in_state(&hits, State::Done);
        let _ = writeln!(
            err,
            "note: {root} と子孫に{}作りかけの解説動画の印が無い (何もしない{})",
            name.map(|n| format!("「{n}」に当たる")).unwrap_or_default(),
            if name.is_some() && !made.is_empty() {
                "。済んだ印には当たった。見たなら pjp mark video watched"
            } else {
                ""
            }
        );
        return Ok(exit::OK);
    }
    if distinct(&making) > 1 && !all {
        list_hits(
            out,
            "作りかけの解説動画の印",
            &making,
            "名前の一部を足して打ち直すか、全部なら --all",
        );
        return Ok(exit::FAILURE);
    }
    remove(hc, &making)?;
    for f in &making {
        let _ = writeln!(
            out,
            "{}: 作りかけの印を外した ({MAKING_MARK}:{})",
            f.holder, f.video.name
        );
    }
    Ok(exit::OK)
}

fn watched(
    hc: &Hc<'_>,
    root: &str,
    name: Option<&str>,
    all: bool,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let found = family(hc, root, err)?;
    let hits = select(&found, name);
    let made = in_state(&hits, State::Done);
    if made.is_empty() {
        let still = in_state(&hits, State::Making);
        if still.is_empty() {
            let _ = writeln!(
                err,
                "note: {root} と子孫に{}見ていない解説動画の印が無い (何もしない。子のマシンの端末は、そのマシンが hc に\
                 つながっている間だけ見える)",
                name.map(|n| format!("「{n}」に当たる")).unwrap_or_default()
            );
        } else {
            let _ = writeln!(
                out,
                "見ていない印は無く、まだ作っている動画に当たった (外していない。止めたなら pjp mark video stop):"
            );
            for f in still {
                let _ = writeln!(out, "  {}", f.line());
            }
        }
        return Ok(exit::OK);
    }
    if distinct(&made) > 1 && !all {
        list_hits(
            out,
            "見ていない解説動画の印",
            &made,
            "名前の一部を足して打ち直すか、全部見たなら --all",
        );
        return Ok(exit::FAILURE);
    }
    remove(hc, &made)?;
    for f in &made {
        let _ = writeln!(
            out,
            "{}: 見た動画の印を外した ({MADE_MARK}:{})",
            f.holder, f.video.name
        );
    }
    Ok(exit::OK)
}

/// `pjp mark show` の末尾に足す行 (その端末と子孫の動画)。
pub fn show_lines(hc: &Hc<'_>, root: &str) -> Vec<String> {
    let mut notes: Vec<u8> = Vec::new();
    let mut lines = match family(hc, root, &mut notes) {
        Ok(found) if found.is_empty() => vec!["  動画: -".to_owned()],
        Ok(found) => {
            let mut v = vec![format!(
                "  動画 (この端末と子孫。space の行の 3 行目から 1 本 1 行): {} 本",
                found.len()
            )];
            v.extend(found.iter().map(|f| format!("    {}", f.line())));
            v
        }
        Err(e) => vec![format!("  動画: 読めない ({e})")],
    };
    lines.extend(
        String::from_utf8_lossy(&notes)
            .lines()
            .map(|l| format!("    {l}")),
    );
    lines
}

#[cfg(test)]
mod tests;
