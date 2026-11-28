//! `pjp pack` (spec §6.2・§7.2): skill の pack (話題ごとの組) を、SKILL.md の frontmatter の metadata から組み立てる。
//! pjp-herdr-other-repo の pack.py の移植で、出力は pack.py と同じ (道具の名前だけ `pjp pack`)。突き合わせは
//! `tests/compat_pack.rs`。
//!
//! ```text
//! pjp pack list [--root DIR]...
//! pjp pack settings PACK... [--synced NAME]... [--root DIR]...
//! pjp pack check [--root DIR]... [--partial]
//! ```
//!
//! pack.py との違いとして決めたものは 1 つ: ハブの雛形を `pjp-herdr-hub` と `pjp-hc-hub` の 2 つとも見る (spec §7.2。
//! hc 版のハブの雛形も同じ skillOverrides を持つ)。
//!
//! 1 つの skill は pack をいくつでも書ける (`pjp-pack: notion docs`。先頭が主の pack)。書いた pack すべてに入り、入口すべての
//! 目録に節を持つ。主でない入口の節には主の入口への案内を書く (docs/superpowers/specs/2026-11-15-skill-multi-pack-design.md)。

mod read;

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};

use pjp_core::exit;
use serde_json::Value;

use crate::args::{self, Spec};
pub use read::{CANON_HINT, ENTRY_PREFIX, is_pack_name};

/// 同期された skill の名前の頭 (`--settings` の key)。
pub const SYNCED_PREFIX: &str = "anthropic-skills:";

/// ハブの雛形 (root からの相対。`/` 区切り)。旧 herdr のハブと hc 版のハブ。
pub const HUB_TEMPLATES: [&str; 2] = [
    "pjp-herdr-hub/assets/hub/settings.json",
    "pjp-hc-hub/assets/hub/settings.json",
];

const USAGE: &str = "\
pjp pack — skill の pack (話題ごとの組) を SKILL.md の metadata (pjp-pack) から組み立てる

使い方:
  pjp pack list [--root DIR]...
  pjp pack settings PACK... [--synced NAME]... [--root DIR]...
  pjp pack check [--root DIR]... [--partial]

  list      pack ごとに、入口 (pjp-pack-<pack>) の有無と skill を並べる。主でない pack の行では「名前(主: <pack>)」と
            書く。同期された skill の名前も出す
  settings  子の claude の起動の引数 --settings に渡す JSON を 1 行で出す。選んだ pack のどれかに入る skill を \"on\" にする
            ({\"skillOverrides\": {\"pjp-plantuml\": \"on\", …}})。--synced pdf で \"anthropic-skills:pdf\": \"on\" も足す。
            落ちたら stdout に何も出さない (終了コード 2)
  check     割り当て (metadata の pjp-pack)・入口の目録 (## <skill> の節)・ハブの雛形の食い違いを ERROR / WARN の行で
            stderr に出す。ERROR があれば終了コード 1

  --root DIR  skill を読む場所 (<DIR>/<名前>/SKILL.md)。繰り返せる。既定は ${CLAUDE_CONFIG_DIR:-~/.claude}/skills
  --partial   (check) root がこの PC の skill の一部 (claude-skills の repo だけなど)。root に無い skill を確かめない
";

/// 読んだ skill。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Skill {
    pub name: String,
    /// metadata の pjp-pack に書いた pack (書いた順。先頭が主の pack)。
    pub packs: Vec<String>,
    /// disable-model-invocation: true (Claude は自分では呼ばない)。
    pub disabled: bool,
    pub problems: Vec<String>,
    /// 入口だけ。目録の節の skill の名前 (書いた順)。
    pub catalog: Vec<String>,
    /// 入口だけ。目録の節の本文 (同じ名前の節は先のもの)。
    pub sections: BTreeMap<String, String>,
}

impl Skill {
    /// 主の pack (入口の目録に節を全部書く pack)。pack の無い skill は None。
    pub fn primary_pack(&self) -> Option<&str> {
        self.packs.first().map(String::as_str)
    }

    pub fn is_entry(&self) -> bool {
        self.name.starts_with(ENTRY_PREFIX)
    }

    pub fn entry_pack(&self) -> &str {
        &self.name[ENTRY_PREFIX.len()..]
    }
}

/// `<名前>/SKILL.md` を読む。
pub fn load_skill(name: &str, skill_md: &Path) -> Skill {
    let mut skill = Skill {
        name: name.to_owned(),
        ..Skill::default()
    };
    let text = match std::fs::read(skill_md).map(String::from_utf8) {
        Ok(Ok(t)) => t,
        Ok(Err(e)) => {
            skill.problems.push(format!("SKILL.md を読めません ({e})"));
            return skill;
        }
        Err(e) => {
            skill.problems.push(format!("SKILL.md を読めません ({e})"));
            return skill;
        }
    };
    let (fm, body) = read::split_frontmatter(&text);
    let Some(fm) = fm else {
        return skill; // frontmatter の無い SKILL.md は lint.sh が落とす。pack には数えない
    };
    (skill.packs, skill.problems) = read::read_packs(&fm);
    skill.disabled = read::is_disabled(&fm);
    if skill.is_entry() {
        for (name, text) in read::read_sections(&body) {
            skill.catalog.push(name.clone());
            skill.sections.entry(name).or_insert(text);
        }
    }
    skill
}

/// 既定の root (`${CLAUDE_CONFIG_DIR:-~/.claude}/skills`。この PC に入っている skill)。
pub fn default_roots() -> pjp_core::Result<Vec<PathBuf>> {
    let home = pjp_core::paths::home_dir()?;
    let base = match std::env::var("CLAUDE_CONFIG_DIR")
        .ok()
        .filter(|v| !v.is_empty())
    {
        Some(v) => expand_user(&v, &home),
        None => home.join(".claude"),
    };
    Ok(vec![base.join("skills")])
}

/// `--root` の値を pack.py の `pathlib.Path` と同じ形にする (POSIX: 重なった `/`・`.`・末尾の `/` を落とし、空は `.`)。
/// 置き場所が無いときの文に出るパスと、`--root ""` を pack.py にそろえる。
fn py_path(v: &str) -> PathBuf {
    if cfg!(windows) {
        return PathBuf::from(if v.is_empty() { "." } else { v });
    }
    let mut out = String::new();
    if v.starts_with('/') {
        // POSIX は先頭のちょうど 2 つの `/` を残す (pathlib と同じ)
        out.push_str(if v.starts_with("//") && !v.starts_with("///") {
            "//"
        } else {
            "/"
        });
    }
    let parts: Vec<&str> = v
        .split('/')
        .filter(|p| !p.is_empty() && *p != ".")
        .collect();
    out.push_str(&parts.join("/"));
    if out.is_empty() {
        out.push('.');
    }
    PathBuf::from(out)
}

/// Python の `os.path.expanduser` の `~` と `~/…` だけ。
fn expand_user(v: &str, home: &Path) -> PathBuf {
    if v == "~" {
        return home.to_path_buf();
    }
    match v.strip_prefix("~/").or_else(|| v.strip_prefix("~\\")) {
        Some(rest) => home.join(rest),
        None => PathBuf::from(v),
    }
}

/// root の直下の `<名前>/SKILL.md` を読む。同じ名前が複数の root にあれば先の root のものを使う。
pub fn scan(roots: &[PathBuf]) -> BTreeMap<String, Skill> {
    let mut skills = BTreeMap::new();
    for root in roots {
        let Ok(entries) = std::fs::read_dir(root) else {
            continue;
        };
        let mut names: Vec<String> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        for name in names {
            let md = root.join(&name).join("SKILL.md");
            if skills.contains_key(&name) || !md.is_file() {
                continue;
            }
            let skill = load_skill(&name, &md);
            skills.insert(name, skill);
        }
    }
    skills
}

/// claude.ai から同期された skill (`<root>/synced/<bucket>/<名前>/SKILL.md`) の名前。
pub fn synced_names(roots: &[PathBuf]) -> Vec<String> {
    let mut names = BTreeSet::new();
    for root in roots {
        let Ok(buckets) = std::fs::read_dir(root.join("synced")) else {
            continue;
        };
        for bucket in buckets.filter_map(|e| e.ok()) {
            let Ok(skills) = std::fs::read_dir(bucket.path()) else {
                continue;
            };
            for s in skills.filter_map(|e| e.ok()) {
                if s.path().join("SKILL.md").is_file() {
                    names.insert(s.file_name().to_string_lossy().into_owned());
                }
            }
        }
    }
    names.into_iter().collect()
}

/// scan の結果を pack ごとに引く。
pub struct Packs {
    pub skills: BTreeMap<String, Skill>,
    /// pack の名前 → 入口の skill の名前。
    pub entries: BTreeMap<String, String>,
    /// pack の名前 → pack の skill の名前 (名前の順。入口は入れない)。複数の pack を書いた skill は、書いた pack すべてに入る。
    pub members: BTreeMap<String, Vec<String>>,
}

impl Packs {
    pub fn new(skills: BTreeMap<String, Skill>) -> Self {
        let mut entries = BTreeMap::new();
        let mut members: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for s in skills.values() {
            if s.is_entry() {
                entries.insert(s.entry_pack().to_owned(), s.name.clone());
            } else {
                for p in &s.packs {
                    members.entry(p.clone()).or_default().push(s.name.clone());
                }
            }
        }
        Self {
            skills,
            entries,
            members,
        }
    }

    pub fn names(&self) -> Vec<String> {
        let mut all: BTreeSet<&String> = self.entries.keys().collect();
        all.extend(self.members.keys());
        all.into_iter().cloned().collect()
    }

    fn entry(&self, pack: &str) -> Option<&Skill> {
        self.entries.get(pack).and_then(|n| self.skills.get(n))
    }

    fn members_of(&self, pack: &str) -> impl Iterator<Item = &Skill> {
        self.members
            .get(pack)
            .into_iter()
            .flatten()
            .filter_map(|n| self.skills.get(n))
    }
}

fn check_roots(roots: &[PathBuf]) -> Option<String> {
    let missing: Vec<String> = roots
        .iter()
        .filter(|r| !r.is_dir())
        .map(|r| r.display().to_string())
        .collect();
    (!missing.is_empty()).then(|| format!("skill の置き場所がありません: {}", missing.join(", ")))
}

/// 順を保って重複を除く。
fn dedup(items: &[String]) -> Vec<&String> {
    let mut seen = BTreeSet::new();
    items.iter().filter(|i| seen.insert(i.as_str())).collect()
}

macro_rules! say {
    ($w:expr, $($arg:tt)*) => {
        // 書けなくても続ける (stdout・stderr が閉じていても、終了コードで結果を返す)
        let _ = writeln!($w, $($arg)*);
    };
}

// ---- list

/// list の行の skill の名前。主でない pack の行では主の pack を添え (`名前(主: <pack>)`)、`marked` を立てる。
fn list_label(s: &Skill, pack: &str, marked: &mut bool) -> String {
    match s.primary_pack() {
        Some(primary) if primary != pack => {
            *marked = true;
            format!("{}(主: {primary})", s.name)
        }
        _ => s.name.clone(),
    }
}

fn cmd_list(roots: &[PathBuf], out: &mut dyn Write, err: &mut dyn Write) -> u8 {
    if let Some(problem) = check_roots(roots) {
        say!(err, "pjp pack: {problem}");
        return exit::CONFIG;
    }
    let packs = Packs::new(scan(roots));
    let mut marked = false; // 主でない pack の行に、主の pack を添えた skill があったか
    for p in packs.names() {
        let entry = if packs.entries.contains_key(&p) {
            format!("入口 {ENTRY_PREFIX}{p}")
        } else {
            "入口なし".to_owned()
        };
        let on: Vec<String> = packs
            .members_of(&p)
            .filter(|s| !s.disabled)
            .map(|s| list_label(s, &p, &mut marked))
            .collect();
        let manual: Vec<String> = packs
            .members_of(&p)
            .filter(|s| s.disabled)
            .map(|s| list_label(s, &p, &mut marked))
            .collect();
        let mut text = format!(
            "{p}  ({entry})  {}",
            if on.is_empty() {
                "(skill なし)".to_owned()
            } else {
                on.join(" ")
            }
        );
        if !manual.is_empty() {
            text.push_str(&format!("  / 自動では呼ばない: {}", manual.join(" ")));
        }
        say!(out, "{text}");
    }
    if marked {
        say!(
            out,
            "(主: <pack>) は、複数の pack に入る skill の主の pack (その入口の目録に節を全部書く)"
        );
    }
    let synced = synced_names(roots);
    if !synced.is_empty() {
        say!(
            out,
            "同期された skill (settings --synced <名前>): {}",
            synced.join(" ")
        );
    }
    for s in packs.skills.values() {
        for problem in &s.problems {
            say!(err, "WARN  {}: {problem}", s.name);
        }
    }
    exit::OK
}

// ---- settings

/// 選んだ pack のどれかに入る skill (と同期された skill) を on にする `--settings` の JSON (1 行)。落ちたら理由を `err` に
/// 書いて、終了コード (2) を返す。`pjp child new` も使う。
pub fn settings_json(
    roots: &[PathBuf],
    pack_names: &[String],
    synced: &[String],
    err: &mut dyn Write,
) -> Result<String, u8> {
    if pack_names.is_empty() && synced.is_empty() {
        say!(
            err,
            "pjp pack settings: pack の名前か --synced <名前> を 1 つ以上渡す"
        );
        return Err(exit::CONFIG);
    }
    if let Some(problem) = check_roots(roots) {
        say!(err, "pjp pack settings: {problem}");
        return Err(exit::CONFIG);
    }
    let packs = Packs::new(scan(roots));
    for s in packs.skills.values() {
        for problem in &s.problems {
            say!(
                err,
                "WARN  {}: {problem} (この skill はどの pack にも数えない)",
                s.name
            );
        }
    }

    // 渡した pack のどれかに入る skill を、すべて on にする。複数の pack に入る skill は 1 つにまとまる (map の key)
    let mut overrides: BTreeMap<String, &str> = BTreeMap::new();
    // disable-model-invocation の note を出した skill (複数の pack に入っていても 1 回)
    let mut noted: BTreeSet<&str> = BTreeSet::new();
    let mut failed = false;
    for p in dedup(pack_names) {
        if !packs.entries.contains_key(p) {
            let known: Vec<&str> = packs.entries.keys().map(String::as_str).collect();
            let known = if known.is_empty() {
                "なし".to_owned()
            } else {
                known.join(", ")
            };
            say!(
                err,
                "pjp pack settings: pack {p} の入口 {ENTRY_PREFIX}{p} がありません (ある pack: {known})"
            );
            failed = true;
            continue;
        }
        let mut on = Vec::new();
        for s in packs.members_of(p) {
            if !s.disabled {
                on.push(s.name.clone());
            } else if noted.insert(s.name.as_str()) {
                say!(
                    err,
                    "note: {} は disable-model-invocation なので on にしない (ユーザーが /{} と打って呼ぶ)",
                    s.name,
                    s.name
                );
            }
        }
        if on.is_empty() {
            say!(
                err,
                "pjp pack settings: pack {p} に on にできる skill がありません (metadata の pjp-pack に {p} を書いた skill が無い)"
            );
            failed = true;
            continue;
        }
        for n in on {
            overrides.insert(n, "on");
        }
    }

    if !synced.is_empty() {
        let names = synced_names(roots);
        for raw in dedup(synced) {
            let n = raw.strip_prefix(SYNCED_PREFIX).unwrap_or(raw);
            if !names.iter().any(|x| x == n) {
                let known = if names.is_empty() {
                    "なし".to_owned()
                } else {
                    names.join(", ")
                };
                say!(
                    err,
                    "pjp pack settings: 同期された skill {n} がありません (ある skill: {known})"
                );
                failed = true;
                continue;
            }
            overrides.insert(format!("{SYNCED_PREFIX}{n}"), "on");
        }
    }

    if failed {
        return Err(exit::CONFIG);
    }
    let map: serde_json::Map<String, Value> = overrides
        .into_iter()
        .map(|(k, v)| (k, Value::from(v)))
        .collect();
    Ok(serde_json::json!({ "skillOverrides": map }).to_string())
}

fn cmd_settings(
    roots: &[PathBuf],
    pack_names: &[String],
    synced: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> u8 {
    match settings_json(roots, pack_names, synced, err) {
        Ok(json) => {
            say!(out, "{json}");
            exit::OK
        }
        Err(code) => code,
    }
}

// ---- check

struct Report<'w> {
    /// ERROR・WARN の行を書く先 (stderr)。
    sink: &'w mut dyn Write,
    errors: usize,
    warnings: usize,
    unverified: BTreeSet<String>,
}

impl Report<'_> {
    fn err(&mut self, label: &str, msg: &str) {
        say!(self.sink, "ERROR {label}: {msg}");
        self.errors += 1;
    }

    fn warn(&mut self, label: &str, msg: &str) {
        say!(self.sink, "WARN  {label}: {msg}");
        self.warnings += 1;
    }
}

/// `text` に入口 `pjp-pack-<pack>` の名前があるか。`pjp-pack-<pack>x` のような長い名前は数えない (pack.py の `mentions_entry`)。
///
/// 名前の後ろは英小文字・数字・ハイフンでないことだけを見る (`\w` は日本語にも当たり、「pjp-pack-notionの目録」を外すので
/// 使わない)。pack.py の `re.search` と同じく、重なった出どころも 1 つずつ見る。
fn mentions_entry(text: &str, pack: &str) -> bool {
    let name = format!("{ENTRY_PREFIX}{pack}");
    let mut start = 0;
    while let Some(k) = text[start..].find(&name) {
        let at = start + k;
        let next = text[at + name.len()..].chars().next();
        if next.is_none_or(|c| c != '-' && !c.is_ascii_lowercase() && !c.is_ascii_digit()) {
            return true;
        }
        start = at + 1; // 名前の頭は ASCII の p なので、1 byte 先も文字の境目
    }
    false
}

fn check_skills(packs: &Packs, partial: bool, rep: &mut Report<'_>) {
    for s in packs.skills.values() {
        for problem in &s.problems {
            rep.err(&s.name, problem);
        }
        if s.is_entry() && !s.packs.is_empty() {
            rep.err(
                &s.name,
                "入口に metadata の pjp-pack を書かない (入口は常駐で、pack の skill ではない)",
            );
        }
        if s.is_entry() {
            continue;
        }
        // 書いた pack の入口すべての目録に節が要る。主でない入口の節には、主の入口への案内も要る (spec 2026-11-15 §2.2)。
        // 主の pack に入口が無ければ案内は求めない (無い入口を指す案内を書かせない。入口の無いことは上の行で出る)
        let primary = s.primary_pack().filter(|q| packs.entries.contains_key(*q));
        for p in &s.packs {
            match packs.entry(p) {
                None => rep.err(
                    &s.name,
                    &format!(
                        "pjp-pack の {p} の入口 {ENTRY_PREFIX}{p} がありません (入口の無い pack からは、この skill を辿れない)"
                    ),
                ),
                Some(entry) if !entry.catalog.contains(&s.name) => rep.err(
                    &entry.name,
                    &format!("目録に {} の節がありません (## {} を足す)", s.name, s.name),
                ),
                Some(entry) => {
                    if let Some(primary) = primary.filter(|q| q != p)
                        && !mentions_entry(
                            entry.sections.get(&s.name).map_or("", String::as_str),
                            primary,
                        )
                    {
                        let primary_entry = format!("{ENTRY_PREFIX}{primary}");
                        rep.err(
                            &entry.name,
                            &format!(
                                "目録の {} の節に、主の入口 {primary_entry} への案内がありません (主でない pack の入口の節には「詳しくは主の入口 {primary_entry} の目録」と書く)",
                                s.name
                            ),
                        );
                    }
                }
            }
        }
    }

    for (p, entry_name) in &packs.entries {
        let entry = &packs.skills[entry_name];
        let mut seen = BTreeSet::new();
        for n in &entry.catalog {
            if !seen.insert(n.as_str()) {
                rep.err(&entry.name, &format!("目録に {n} の節が 2 つあります"));
                continue;
            }
            match packs.skills.get(n) {
                None => {
                    if partial {
                        rep.unverified.insert(n.clone());
                    } else {
                        rep.err(
                            &entry.name,
                            &format!("目録の {n} が見つかりません (名前の打ち間違いか、この PC に入っていない)"),
                        );
                    }
                }
                Some(t) if t.is_entry() => {
                    rep.err(&entry.name, &format!("目録に入口 {n} を載せない"));
                }
                Some(t) if !t.problems.is_empty() => {} // 読めない形は、その skill の行で出した
                Some(t) if t.packs.is_empty() => rep.err(
                    &entry.name,
                    &format!(
                        "目録の {n} に metadata の pjp-pack: {p} がありません (その SKILL.md に足すか、目録から外す)"
                    ),
                ),
                Some(t) if !t.packs.contains(p) => rep.err(
                    &entry.name,
                    &format!(
                        "目録の {n} は pjp-pack: {} です (pjp-pack に {p} を足すか、目録から外す)",
                        t.packs.join(" ")
                    ),
                ),
                Some(_) => {}
            }
        }
        if entry.catalog.is_empty() && !packs.members.contains_key(p) {
            rep.warn(&entry.name, "目録も割り当ても空です");
        }
    }
}

/// ハブの雛形の skillOverrides の on を見る。雛形ごとに、それを持つ最初の root のものを見る。
///
/// on の skill はどれも、丸ごと on の pack (`pack_want` が全部 on の pack) のどれかに入っていること (spec 2026-11-15 §2.5)。
/// 複数の pack に入る skill のために一部だけ on になった pack は咎めない。
fn check_hub(packs: &Packs, roots: &[PathBuf], partial: bool, rep: &mut Report<'_>) {
    for template in HUB_TEMPLATES {
        let Some(path) = roots
            .iter()
            .map(|r| template.split('/').fold(r.clone(), |p, c| p.join(c)))
            .find(|p| p.is_file())
        else {
            continue;
        };
        check_hub_template(packs, &path, template, partial, rep);
    }
}

fn check_hub_template(
    packs: &Packs,
    path: &Path,
    label: &str,
    partial: bool,
    rep: &mut Report<'_>,
) {
    let data: Value = match std::fs::read(path)
        .map_err(|e| e.to_string())
        .and_then(|b| String::from_utf8(b).map_err(|e| e.to_string()))
        .and_then(|t| serde_json::from_str(&t).map_err(|e| e.to_string()))
    {
        Ok(v) => v,
        Err(e) => {
            rep.err(label, &format!("JSON として読めません ({e})"));
            return;
        }
    };
    let overrides = match data.get("skillOverrides") {
        None | Some(Value::Null) => return,
        Some(Value::Object(o)) => o,
        Some(_) => {
            rep.err(label, "skillOverrides が object ではありません");
            return;
        }
    };
    let on: BTreeSet<&str> = overrides
        .iter()
        .filter(|(_, v)| v.as_str() == Some("on"))
        .map(|(k, _)| k.as_str())
        .collect();
    // 目録から引く skill の pack (名前の順)。root に無い skill・割り当てを読めない skill は、これで数える
    let mut catalog_packs: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for (p, entry_name) in &packs.entries {
        let mut seen = BTreeSet::new();
        for n in &packs.skills[entry_name].catalog {
            if seen.insert(n.as_str()) {
                catalog_packs
                    .entry(n.as_str())
                    .or_default()
                    .push(p.as_str());
            }
        }
    }

    // on の skill ごとに、入る pack を決める
    let mut on_packs: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for &k in &on {
        match packs.skills.get(k) {
            Some(s) if !s.problems.is_empty() => {
                // 読めない形は、その skill の行で出した。目録にあれば、目録の pack に入るものとして数える
                if let Some(ps) = catalog_packs.get(k) {
                    on_packs.insert(k, ps.clone());
                }
            }
            Some(s) if s.is_entry() => {
                rep.err(label, &format!("{k} は入口 (常駐) なので on にしなくてよい"));
            }
            Some(s) if s.packs.is_empty() => match catalog_packs.get(k) {
                // 目録にあるのに割り当てが無い。それは目録の検査が出すので、ここでは目録の pack に数えるだけ
                Some(ps) => {
                    on_packs.insert(k, ps.clone());
                }
                None => rep.err(
                    label,
                    &format!("{k} は pack の skill ではありません (on にするのは pack の skill だけ)"),
                ),
            },
            Some(s) if s.disabled => {
                rep.err(label, &format!("{k} は disable-model-invocation なので on にしない"));
            }
            Some(s) => {
                on_packs.insert(k, s.packs.iter().map(String::as_str).collect());
            }
            None => match catalog_packs.get(k) {
                Some(ps) => {
                    on_packs.insert(k, ps.clone());
                    if partial {
                        rep.unverified.insert(k.to_owned());
                    }
                    // partial でなければ、見つからないことは目録の検査が出す
                }
                None => rep.err(
                    label,
                    &format!("{k} はどの入口の目録にもありません (名前の打ち間違いか、pack の skill ではない)"),
                ),
            },
        }
    }

    // 入口の無い pack (書き違い) は、その skill だけで丸ごと on に見えるので数えない (入口の無いことは check_skills が出す)
    let on_packs: BTreeMap<&str, Vec<&str>> = on_packs
        .into_iter()
        .filter_map(|(k, ps)| {
            let kept: Vec<&str> = ps
                .into_iter()
                .filter(|p| packs.entries.contains_key(*p))
                .collect();
            (!kept.is_empty()).then_some((k, kept))
        })
        .collect();
    // pack ごとの足りない skill (空なら丸ごと on)。どの pack も丸ごと on でない skill を咎める
    let mut missing: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for &p in on_packs.values().flatten() {
        missing.entry(p).or_insert_with(|| {
            pack_want(packs, p)
                .into_iter()
                .filter(|n| !on.contains(n))
                .collect()
        });
    }
    let uncovered: Vec<(&str, &Vec<&str>)> = on_packs
        .iter()
        .filter(|(_, ps)| ps.iter().all(|p| !missing[p].is_empty()))
        .map(|(k, ps)| (*k, ps))
        .collect();
    // pack が 1 つの skill は、その pack を丸ごと on にするしかない
    let must: BTreeSet<&str> = uncovered
        .iter()
        .filter(|(_, ps)| ps.len() == 1)
        .map(|(_, ps)| ps[0])
        .collect();
    for p in &must {
        for n in &missing[p] {
            rep.err(
                label,
                &format!("pack {p} の {n} がありません (ハブでは pack を丸ごと on にする)"),
            );
        }
    }
    // 複数の pack に入る skill は、そのどれかが上で出ていれば、それを丸ごとにすれば片付くので重ねて出さない
    for (k, ps) in &uncovered {
        if ps.len() == 1 || ps.iter().any(|p| must.contains(p)) {
            continue;
        }
        let detail: Vec<String> = ps
            .iter()
            .map(|p| format!("{p} の {}", missing[p].join("・")))
            .collect();
        rep.err(
            label,
            &format!(
                "{k} の入る pack ({}) が、どれも丸ごと on になっていません ({} がありません。ハブでは、どれか 1 つの pack を丸ごと on にする)",
                ps.join("・"),
                detail.join("、")
            ),
        );
    }
}

/// pack を丸ごと on にするとき on にする skill: disable-model-invocation でない skill と、目録にあって root に無い skill
/// (pack.py の `pack_want`)。
fn pack_want<'a>(packs: &'a Packs, p: &str) -> BTreeSet<&'a str> {
    let mut want: BTreeSet<&str> = packs
        .members_of(p)
        .filter(|s| !s.disabled)
        .map(|s| s.name.as_str())
        .collect();
    if let Some(entry) = packs.entry(p) {
        want.extend(
            entry
                .catalog
                .iter()
                .filter(|n| !packs.skills.contains_key(*n))
                .map(String::as_str),
        );
    }
    want
}

fn cmd_check(roots: &[PathBuf], partial: bool, out: &mut dyn Write, err: &mut dyn Write) -> u8 {
    if let Some(problem) = check_roots(roots) {
        say!(err, "pjp pack check: {problem}");
        return exit::CONFIG;
    }
    let packs = Packs::new(scan(roots));
    let mut rep = Report {
        sink: err,
        errors: 0,
        warnings: 0,
        unverified: BTreeSet::new(),
    };
    check_skills(&packs, partial, &mut rep);
    check_hub(&packs, roots, partial, &mut rep);
    // 複数の pack に入る skill は 1 つに数える
    let n_members = packs
        .members
        .values()
        .flatten()
        .collect::<BTreeSet<_>>()
        .len();
    say!(
        out,
        "pack {} 件 / pack の skill {n_members} 件 / エラー {} / 警告 {}",
        packs.names().len(),
        rep.errors,
        rep.warnings
    );
    if !rep.unverified.is_empty() {
        let names: Vec<&str> = rep.unverified.iter().map(String::as_str).collect();
        say!(
            out,
            "  root に無い skill (--partial なので確かめていない): {}",
            names.join(" ")
        );
    }
    if rep.errors > 0 {
        exit::FAILURE
    } else {
        exit::OK
    }
}

// ---- 入口

/// `pjp pack <サブコマンド> …` (args は道具の名前を除いたもの)。終了コードを返す。
pub fn main(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> u8 {
    let Some((sub, rest)) = args.split_first() else {
        let _ = write!(err, "{USAGE}");
        return exit::CONFIG;
    };
    if sub == "-h" || sub == "--help" {
        let _ = write!(out, "{USAGE}");
        return exit::OK;
    }
    let spec = match sub.as_str() {
        "list" => Spec {
            flags: &[],
            values: &["--root"],
        },
        "settings" => Spec {
            flags: &[],
            values: &["--root", "--synced"],
        },
        "check" => Spec {
            flags: &["--partial"],
            values: &["--root"],
        },
        _ => {
            say!(
                err,
                "pjp pack: 知らないサブコマンドです: {sub} (list・settings・check)"
            );
            return exit::CONFIG;
        }
    };
    let parsed = match args::parse(rest, &spec) {
        Ok(p) => p,
        Err(e) => {
            say!(err, "pjp pack {sub}: {e}");
            return e.code();
        }
    };
    if parsed.help() {
        let _ = write!(out, "{USAGE}");
        return exit::OK;
    }
    if sub != "settings" && !parsed.positionals.is_empty() {
        say!(
            err,
            "pjp pack {sub}: 余分な引数です: {}",
            parsed.positionals.join(" ")
        );
        return exit::CONFIG;
    }
    let roots: Vec<PathBuf> = if parsed.values("--root").is_empty() {
        match default_roots() {
            Ok(r) => r,
            Err(e) => {
                say!(err, "pjp pack: {e}");
                return e.code();
            }
        }
    } else {
        parsed.values("--root").iter().map(|v| py_path(v)).collect()
    };
    match sub.as_str() {
        "list" => cmd_list(&roots, out, err),
        "settings" => cmd_settings(
            &roots,
            &parsed.positionals,
            parsed.values("--synced"),
            out,
            err,
        ),
        _ => cmd_check(&roots, parsed.flag("--partial"), out, err),
    }
}

#[cfg(test)]
mod tests;
