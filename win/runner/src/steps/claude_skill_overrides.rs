//! claude-skill-overrides (order 60): Windows の Claude Code の settings.json の `skillOverrides` (skill を一覧に説明つきで出すか・名前だけか・
//! 出さないか) を書く。Linux の `nix/scripts/bootstrap-claude-skill-overrides.sh` の写しで、選び方・書き方・控えの扱いは同じ:
//!
//! - host option の skill: `pjp-dev-tracker` を、ホストの値の道具 `devTracker` (Linux の `dotfiles.claude.devTracker.enable`) で on / off にする
//!   (いつも上書き)
//! - pack の skill: `~/.claude/skills/<名前>/SKILL.md` の frontmatter の `metadata.pjp-pack` に書いた pack のどれかの入口 (`pjp-pack-<pack>`) が
//!   あれば `name-only` (一覧に名前だけ。Skill tool で名前を指せば呼べる)
//! - claude.ai から同期された skill (`~/.claude/skills/synced/*/<名前>/`): `anthropic-skills:<名前>` を `user-invocable-only`
//!
//! 書いた key は控え (`%LOCALAPPDATA%\dotfiles\state\claude-skill-overrides.applied.json`。Linux は `~/.local/state/dotfiles/` の同じ名前と形) に残し、
//! 書かなくなった key は、今の値が控えた値と同じなら消して既定に戻す。手で別の値を書いた key には触らない。order は Linux と同じ 60 (claude-files と
//! claude-skills が skill をつないだ後)。Windows には claude-<名前> のアカウントの dir が無いので、同期された skill は `~/.claude` の分だけを読む。

use super::claude_settings;
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::ojson::OValue;
use crate::report::Kind;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// 控え (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "claude-skill-overrides.applied.json";

pub struct ClaudeSkillOverrides;

impl Step for ClaudeSkillOverrides {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-skill-overrides",
            order: 60,
            title: "Claude Code の settings.json の skillOverrides (pjp-dev-tracker の on/off・pack の skill を名前だけ・同期された skill を隠す) を書く",
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let path = claude_settings::path(ctx);
        let (before, existed) = match claude_settings::load(&path) {
            Ok(v) => v,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![Outcome::new(Kind::Failed, e)];
            }
        };
        let current = match before.get("skillOverrides") {
            None | Some(OValue::Null) => Vec::new(),
            Some(OValue::Object(e)) => e.clone(),
            Some(_) => {
                let why = format!(
                    "{} の skillOverrides が map (JSON object) ではない → 手で直す",
                    path.display()
                );
                ctx.say(format!("!! {why}"));
                return vec![Outcome::new(Kind::Failed, why)];
            }
        };
        let host = vec![(
            "pjp-dev-tracker".to_string(),
            if ctx.host.tool("devTracker") {
                "on"
            } else {
                "off"
            }
            .to_string(),
        )];
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let mut warnings = Vec::new();
        let record = load_record(&record_path, &mut warnings);
        let skills_dir = ctx.roots.user_profile.join(".claude").join("skills");
        let (want, mut found_warnings, info) = wanted(&skills_dir);
        warnings.append(&mut found_warnings);
        for w in &warnings {
            ctx.say(format!("!! {w}"));
        }
        if let Some(i) = info {
            ctx.say(i);
        }
        let m = merge(&before, &current, &host, &want, &record);
        for l in log_lines(&m.log, mode) {
            ctx.say(l);
        }
        let mut o = claude_settings::apply_change(
            ctx,
            mode,
            &path,
            (&before, existed),
            &m.settings,
            "skillOverrides",
            "新しい Claude Code の会話から効く (実行中の会話は起動し直すか /compact)。確かめるのは /skills",
        );
        if mode.writes() && o.kind != Kind::Failed {
            let new_record = record_json(&m.record);
            let wants_file = record_path.exists() || !m.record.is_empty();
            let same = std::fs::read_to_string(&record_path)
                .ok()
                .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
                == serde_json::from_str::<serde_json::Value>(&new_record).ok();
            if wants_file
                && !same
                && let Err(e) =
                    fsutil::write_atomic(&record_path, format!("{new_record}\n").as_bytes())
            {
                o = Outcome::new(
                    Kind::Failed,
                    format!("控えを書けない: {} ({e})", record_path.display()),
                );
            }
        }
        for w in warnings {
            o = o.note(w);
        }
        vec![o]
    }
}

/// 控えの key と値。読めなければ知らせて空 (bash の版と同じ)。
fn load_record(path: &Path, warnings: &mut Vec<String>) -> BTreeMap<String, String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return BTreeMap::new();
    };
    let parsed = serde_json::from_str::<serde_json::Value>(&text)
        .ok()
        .and_then(|v| {
            if v.get("version") != Some(&serde_json::Value::from(1)) {
                return None;
            }
            let keys = v.get("keys")?.as_object()?;
            keys.iter()
                .map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect::<Option<BTreeMap<_, _>>>()
        });
    parsed.unwrap_or_else(|| {
        warnings.push(format!(
            "控えが読めない: {} (無いものとして進める。前に書いた key のうち、今は書かないものは戻せない。今も書く key はまた控える)",
            path.display()
        ));
        BTreeMap::new()
    })
}

/// 控えの中身 (`{"version":1,"keys":{…}}` の 1 行。bash の版の jq -c と同じ並び)。
fn record_json(record: &[(String, String)]) -> String {
    let keys = OValue::Object(
        record
            .iter()
            .map(|(k, v)| (k.clone(), OValue::String(v.clone())))
            .collect(),
    );
    let top = OValue::Object(vec![
        ("version".to_string(), OValue::Number(1.into())),
        ("keys".to_string(), keys),
    ]);
    serde_json::to_string(&top).expect("OValue は JSON にいつも書ける")
}

/// frontmatter の囲み (`^---[ \t]*$`)
fn is_fence(line: &str) -> bool {
    line.strip_prefix("---")
        .is_some_and(|r| r.chars().all(|c| c == ' ' || c == '\t'))
}

/// 値の後ろの「空白 + #」から先を外す (awk の `sub(/[ \t]+#.*$/, "")`)
fn strip_comment(v: &str) -> &str {
    let b = v.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b' ' || b[i] == b'\t' {
            let mut j = i;
            while j < b.len() && (b[j] == b' ' || b[j] == b'\t') {
                j += 1;
            }
            if j < b.len() && b[j] == b'#' {
                return &v[..i];
            }
            i = j;
        } else {
            i += 1;
        }
    }
    v
}

/// 引用符 ("…" か '…') で囲んであれば外す
fn unquote(v: &str) -> &str {
    let b = v.as_bytes();
    if b.len() >= 2
        && ((b[0] == b'"' && b[b.len() - 1] == b'"') || (b[0] == b'\'' && b[b.len() - 1] == b'\''))
    {
        &v[1..v.len() - 1]
    } else {
        v
    }
}

/// 1 行目の `---` から次の `---` までの行 (CR を落とす)。1 行目が囲みでなければ空。
fn frontmatter(text: &str) -> Vec<&str> {
    let mut lines = text.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l));
    if !lines.next().is_some_and(is_fence) {
        return Vec::new();
    }
    lines.take_while(|l| !is_fence(l)).collect()
}

/// frontmatter の metadata の直下 (最初の子の字下げ) の pjp-pack の値 (bash の版の skill_pack と同じ読み方)。
fn skill_pack(text: &str) -> Option<String> {
    let mut in_meta = false;
    let mut depth: Option<usize> = None;
    for line in frontmatter(text) {
        if line.starts_with(|c: char| !matches!(c, ' ' | '\t' | '#')) {
            let rest = line.strip_prefix("metadata:");
            in_meta = rest.is_some_and(|r| {
                let r = r.trim_start_matches([' ', '\t']);
                r.is_empty() || r.starts_with('#')
            });
            depth = None;
            continue;
        }
        let body = line.trim_start_matches([' ', '\t']);
        if !in_meta || body.is_empty() || body.starts_with('#') {
            continue;
        }
        let indent = line.len() - body.len();
        match depth {
            None => depth = Some(indent),
            Some(d) if d != indent => continue,
            Some(_) => {}
        }
        let Some(v) = body.strip_prefix("pjp-pack:") else {
            continue;
        };
        let v = strip_comment(v.trim_start_matches([' ', '\t'])).trim_end_matches([' ', '\t']);
        return Some(unquote(v).to_string());
    }
    None
}

/// frontmatter の 0 桁目の `<key>:` の 1 行の値 (bash の版の fm_top_value と同じ読み方)。
fn fm_top_value(text: &str, key: &str) -> Option<String> {
    let head = format!("{key}:");
    frontmatter(text).into_iter().find_map(|line| {
        let v = line.strip_prefix(&head)?;
        let v = strip_comment(v.trim_start_matches([' ', '\t'])).trim_end_matches([' ', '\t']);
        Some(unquote(v).to_string())
    })
}

/// pack の名前の形 (`^[a-z0-9]+(-[a-z0-9]+)*$`)
fn pack_name_ok(n: &str) -> bool {
    !n.is_empty()
        && n.split('-').all(|p| {
            !p.is_empty()
                && p.bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

/// 同期された skill の名前の形 (`^[A-Za-z0-9._-]+$`。`.` と `..` は除く)
fn plain_name_ok(n: &str) -> bool {
    !n.is_empty()
        && n != "."
        && n != ".."
        && n.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// dir の中の名前 (bash の glob の `*` と同じく `.` で始まる名前は除き、並べる)
fn entries(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|d| {
            d.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| !n.starts_with('.'))
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

/// 書きたい key と値・警告・知らせ (bash の版の「書きたい key と値を集める」と同じ)。
fn wanted(skills_dir: &Path) -> (BTreeMap<String, String>, Vec<String>, Option<String>) {
    let shown = skills_dir.display();
    let mut want = BTreeMap::new();
    let mut warnings = Vec::new();
    let entry = |pack: &str| {
        skills_dir
            .join(format!("pjp-pack-{pack}"))
            .join("SKILL.md")
            .is_file()
    };
    let any_entry = entries(skills_dir)
        .iter()
        .any(|n| n.starts_with("pjp-pack-") && skills_dir.join(n).join("SKILL.md").is_file());
    // 入口の無い pack ごとの (skill, ほかの入口から辿れるか)
    let mut missing: BTreeMap<String, Vec<(String, bool)>> = BTreeMap::new();
    let mut unreachable = 0;
    for skill in entries(skills_dir) {
        let skill_dir = skills_dir.join(&skill);
        let f = skill_dir.join("SKILL.md");
        if !f.is_file() {
            continue;
        }
        let text = String::from_utf8_lossy(&std::fs::read(&f).unwrap_or_default()).into_owned();
        let value = skill_pack(&text).unwrap_or_default();
        // bash の `read -a` と同じく、空白・タブ・改行だけで分ける (全角の空白などは名前の字として読み、読めない名前になる)
        let names: Vec<&str> = value
            .split([' ', '\t', '\n'])
            .filter(|s| !s.is_empty())
            .collect();
        if names.is_empty() {
            continue;
        }
        let fs = f.display();
        if !names.iter().all(|n| pack_name_ok(n)) {
            warnings.push(format!("{fs} の metadata の pjp-pack が、pack の名前として読めない: {value} (pack の名前は小文字の英数字とハイフン。複数の pack は空白で区切る。この skill は説明つきのまま残す)"));
            continue;
        }
        if skill.starts_with("pjp-pack-") {
            warnings.push(format!("入口の skill {skill} に metadata の pjp-pack がある ({value})。入口は常駐なので、名前だけにはしない ({fs} から pjp-pack を外す)"));
            continue;
        }
        if skill_dir
            .join(".claude-plugin")
            .join("plugin.json")
            .is_file()
        {
            warnings.push(format!("mod を兼ねる skill {skill} に metadata の pjp-pack がある ({value})。plugin として読まれ skillOverrides が効かないので、名前だけにはしない"));
            continue;
        }
        if matches!(
            fm_top_value(&text, "disable-model-invocation").as_deref(),
            Some("true" | "True" | "TRUE")
        ) {
            continue;
        }
        let mut distinct: Vec<&str> = Vec::new();
        for n in names {
            if !distinct.contains(&n) {
                distinct.push(n);
            }
        }
        let reach = distinct.iter().any(|p| entry(p));
        for p in &distinct {
            if !entry(p) {
                missing
                    .entry(p.to_string())
                    .or_default()
                    .push((skill.clone(), reach));
            }
        }
        if reach {
            want.insert(skill.clone(), "name-only".to_string());
        } else {
            unreachable += 1;
        }
    }
    let mut info = None;
    if any_entry {
        for (pack, rows) in &missing {
            let mut kept: Vec<&str> = rows.iter().filter(|r| !r.1).map(|r| r.0.as_str()).collect();
            let mut via: Vec<&str> = rows.iter().filter(|r| r.1).map(|r| r.0.as_str()).collect();
            kept.sort();
            via.sort();
            let mut w = format!("pack {pack} の入口 {shown}/pjp-pack-{pack} が無い。");
            if !kept.is_empty() {
                w.push_str(&format!(
                    "次の skill は説明つきのまま残す: {}。",
                    kept.join(", ")
                ));
            }
            if !via.is_empty() {
                w.push_str(&format!(
                    "次の skill は、ほかに書いた pack の入口から辿れるので名前だけにする: {}。",
                    via.join(", ")
                ));
            }
            w.push_str("claude-skills の clone が古いか、入口の名前が変わった・消えたか、skill の metadata の pjp-pack を書き違えている");
            warnings.push(w);
        }
    } else if unreachable > 0 {
        info = Some(format!(
            "pack の入口 ({shown}/pjp-pack-*) が 1 つも無いので、pack の skill ({unreachable} 本) は説明つきのまま残します (claude-skills を取れないマシン・入口がまだ無い版)。"
        ));
    }
    // claude.ai から同期された skill
    let synced = skills_dir.join("synced");
    for group in entries(&synced) {
        for name in entries(&synced.join(&group)) {
            if synced.join(&group).join(&name).join("SKILL.md").exists() && plain_name_ok(&name) {
                want.insert(
                    format!("anthropic-skills:{name}"),
                    "user-invocable-only".to_string(),
                );
            }
        }
    }
    (want, warnings, info)
}

/// した事 (bash の版の log の 1 件)
#[derive(Clone, Debug, PartialEq)]
struct Act {
    act: &'static str,
    key: String,
    value: OValue,
    want: Option<String>,
}

struct Merged {
    settings: OValue,
    record: Vec<(String, String)>,
    log: Vec<Act>,
}

/// skillOverrides と控えを組む (bash の版の jq の式と同じ)。
fn merge(
    doc: &OValue,
    before: &[(String, OValue)],
    host: &[(String, String)],
    want: &BTreeMap<String, String>,
    record: &BTreeMap<String, String>,
) -> Merged {
    let want: BTreeMap<&String, &String> = want
        .iter()
        .filter(|(k, _)| !host.iter().any(|(h, _)| h == *k))
        .collect();
    let mut s: Vec<(String, OValue)> = before.to_vec();
    let get = |s: &Vec<(String, OValue)>, k: &str| -> OValue {
        s.iter()
            .find(|(x, _)| x == k)
            .map(|(_, v)| v.clone())
            .unwrap_or(OValue::Null)
    };
    let set = |s: &mut Vec<(String, OValue)>, k: &str, v: OValue| match s
        .iter_mut()
        .find(|(x, _)| x == k)
    {
        Some((_, old)) => *old = v,
        None => s.push((k.to_string(), v)),
    };
    let mut rec: Vec<(String, String)> = Vec::new();
    let mut log = Vec::new();
    let keys: BTreeSet<&String> = want.keys().copied().chain(record.keys()).collect();
    for k in keys {
        let d = want.get(k);
        let r = record.get(k);
        let cur = get(&s, k);
        match d {
            Some(d) => {
                let dv = OValue::String((*d).clone());
                if cur == OValue::Null {
                    set(&mut s, k, dv.clone());
                    rec.push((k.clone(), (*d).clone()));
                    log.push(Act {
                        act: "add",
                        key: k.clone(),
                        value: dv,
                        want: None,
                    });
                } else if cur == dv {
                    rec.push((k.clone(), (*d).clone()));
                } else if r.is_some_and(|r| cur == OValue::String(r.clone())) {
                    set(&mut s, k, dv.clone());
                    rec.push((k.clone(), (*d).clone()));
                    log.push(Act {
                        act: "update",
                        key: k.clone(),
                        value: dv,
                        want: None,
                    });
                } else {
                    log.push(Act {
                        act: "keep",
                        key: k.clone(),
                        value: cur,
                        want: Some((*d).clone()),
                    });
                }
            }
            None => {
                if let Some(r) = r
                    && cur != OValue::Null
                    && cur == OValue::String(r.clone())
                {
                    s.retain(|(x, _)| x != k);
                    log.push(Act {
                        act: "revert",
                        key: k.clone(),
                        value: cur,
                        want: None,
                    });
                }
            }
        }
    }
    for (k, v) in host {
        let was = before
            .iter()
            .find(|(x, _)| x == k)
            .map(|(_, v)| v.clone())
            .unwrap_or(OValue::Null);
        if was != OValue::String(v.clone()) {
            log.push(Act {
                act: "host",
                key: k.clone(),
                value: OValue::String(v.clone()),
                want: None,
            });
        }
        set(&mut s, k, OValue::String(v.clone()));
    }
    let settings = if s.is_empty() && doc.get("skillOverrides").is_none() {
        doc.clone()
    } else {
        let mut d = doc.clone();
        d.set("skillOverrides", OValue::Object(s));
        d
    };
    Merged {
        settings,
        record: rec,
        log,
    }
}

/// 値を jq の文字列の埋め込み (`\(.value)`) と同じに書く
fn shown(v: &OValue) -> String {
    match v {
        OValue::String(s) => s.clone(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

/// まとめる鍵 (した事・値・書きたい値) と、その key の並び
type LogGroup<'a> = ((&'a str, String, String), Vec<&'a str>);

/// した事と値ごとに 1 行 (bash の版の group_by([.act, .value, .want]) と同じ並び)。apply でなければ、することとして出す (check は
/// 「(apply で)」、dry-run は「[dry-run]」を添える)。
fn log_lines(log: &[Act], mode: Mode) -> Vec<String> {
    let done = mode.writes();
    log_lines_past(log)
        .into_iter()
        .map(|l| {
            if done {
                return l;
            }
            let todo = l
                .replacen("書きました", "書く", 1)
                .replacen("書き換えました", "書き換える", 1)
                .replacen("戻しました", "戻す", 1)
                .replacen("残しました", "残す", 1);
            match mode {
                Mode::DryRun { .. } => format!("[dry-run] {todo}"),
                _ => format!("{todo} (apply で)"),
            }
        })
        .collect()
}

/// した事と値ごとに 1 行 (書いた後の言い方)。
fn log_lines_past(log: &[Act]) -> Vec<String> {
    let mut groups: Vec<LogGroup> = Vec::new();
    for a in log {
        let key = (a.act, shown(&a.value), a.want.clone().unwrap_or_default());
        match groups.iter_mut().find(|(k, _)| *k == key) {
            Some((_, keys)) => keys.push(&a.key),
            None => groups.push((key, vec![&a.key])),
        }
    }
    groups.sort_by(|a, b| a.0.cmp(&b.0));
    groups
        .into_iter()
        .map(|((act, value, want), keys)| {
            let keys = keys.join(", ");
            match act {
                "host" => format!("host option の値を書きました ({value}): {keys}"),
                "add" => format!("書きました ({value}): {keys}"),
                "update" => format!("書き換えました ({value}): {keys}"),
                "revert" => format!("戻しました ({value} を消した): {keys}"),
                _ => {
                    format!("手で書いた値を残しました ({value}。runner が書くなら {want}): {keys}")
                }
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - frontmatter の読み方 (metadata の直下の pjp-pack・引用符・コメント・CRLF・字下げの違う行・囲みの無いファイル・disable-model-invocation)
    //! - pack の skill は入口があれば name-only、入口の無い pack を知らせ、入口・mod・読めない名前・disable-model-invocation は名前だけにしない
    //! - 同期された skill は user-invocable-only。pjp-dev-tracker はホストの値の devTracker で on / off
    //! - 控えの扱い (書いた・控えた値から書き換えた・手で書いた値を残した・書かなくなった key を戻した)。2 回目は何も変わらない
    //! - bash の版 (nix/scripts/bootstrap-claude-skill-overrides.sh) と同じ skill の並びで、同じ skillOverrides と控え (bash と jq がある Linux)

    use super::*;
    use crate::hooks::parity;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::PathBuf;

    #[test]
    fn reads_frontmatter_like_awk() {
        let md = "---\nname: x\nmetadata:\n  other: 1\n  pjp-pack: \"diagram lang\" # c\n---\n";
        assert_eq!(skill_pack(md).as_deref(), Some("diagram lang"));
        assert_eq!(
            skill_pack("---\r\nmetadata:\r\n  pjp-pack: video\r\n---\r\n").as_deref(),
            Some("video")
        );
        assert_eq!(
            skill_pack("---\nmetadata:\n  a: 1\n    pjp-pack: x\n---\n"),
            None,
            "字下げの違う行は読まない"
        );
        assert_eq!(
            skill_pack("---\nmetadata: # m\n\n  # c\n  pjp-pack: 'x'\n"),
            Some("x".to_string())
        );
        assert_eq!(skill_pack("---\nmetadata: {pjp-pack: x}\n---\n"), None);
        assert_eq!(
            skill_pack("name: x\nmetadata:\n  pjp-pack: x\n"),
            None,
            "囲みが無い"
        );
        assert_eq!(
            skill_pack("---\nmetadata:\n  pjp-pack: x\n---\nmetadata:\n  pjp-pack: y\n"),
            Some("x".to_string())
        );
        assert_eq!(skill_pack("---\nother:\n  pjp-pack: x\n---\n"), None);
        assert_eq!(
            fm_top_value(
                "---\ndisable-model-invocation: true # x\n---\n",
                "disable-model-invocation"
            )
            .as_deref(),
            Some("true")
        );
        assert_eq!(
            fm_top_value(
                "---\n  disable-model-invocation: true\n---\n",
                "disable-model-invocation"
            ),
            None
        );
        assert_eq!(strip_comment("a#b"), "a#b");
        assert_eq!(strip_comment("a  # b # c"), "a");
        assert!(
            pack_name_ok("diagram")
                && pack_name_ok("a-b1")
                && !pack_name_ok("Diagram")
                && !pack_name_ok("a--b")
                && !pack_name_ok("-a")
        );
    }

    /// 突き合わせと単体の試験の skill の並び (`<home>/.claude/skills` に置く)
    fn fixture(home: &Path) {
        let w = |rel: &str, text: &str| {
            let p = home.join(".claude").join("skills").join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        };
        let pack = |p: &str| format!("---\nname: x\nmetadata:\n  pjp-pack: {p}\n---\nbody\n");
        w(
            "pjp-pack-diagram/SKILL.md",
            "---\nname: pjp-pack-diagram\n---\n",
        );
        w(
            "pjp-pack-notion/SKILL.md",
            "---\nname: pjp-pack-notion\n---\n",
        );
        w("pjp-pack-repo/SKILL.md", &pack("repo"));
        w("pjp-plantuml/SKILL.md", &pack("diagram"));
        w(
            "pjp-crlf/SKILL.md",
            "---\r\nmetadata:\r\n  pjp-pack: diagram\r\n---\r\n",
        );
        w("pjp-multi/SKILL.md", &pack("\"diagram lang diagram\""));
        w("pjp-lonely/SKILL.md", &pack("video # c"));
        w("pjp-lonely2/SKILL.md", &pack("video"));
        w("pjp-bad/SKILL.md", &pack("Diagram"));
        w("pjp-fullwidth/SKILL.md", &pack("diagram\u{3000}lang"));
        w("pjp-mod/SKILL.md", &pack("diagram"));
        w("pjp-mod/.claude-plugin/plugin.json", "{}");
        w(
            "pjp-dmi/SKILL.md",
            "---\ndisable-model-invocation: True\nmetadata:\n  pjp-pack: diagram\n---\n",
        );
        w("pjp-upd/SKILL.md", &pack("notion"));
        w("pjp-dev-tracker/SKILL.md", &pack("notion"));
        w("pjp-nopack/SKILL.md", "---\nname: x\n---\n");
        w(".hidden/SKILL.md", &pack("diagram"));
        w("synced/u1/my-skill/SKILL.md", "---\nname: my-skill\n---\n");
        w("synced/u1/bad name/SKILL.md", "---\nname: x\n---\n");
        w("synced/.h/hidden/SKILL.md", "x");
    }

    const SETTINGS: &str = "{\n  \"theme\": \"dark\",\n  \"skillOverrides\": {\n    \"pjp-plantuml\": \"off\",\n    \"pjp-old\": \"name-only\",\n    \"keep-me\": \"on\",\n    \"pjp-multi\": \"name-only\",\n    \"pjp-gone-manual\": \"off\",\n    \"pjp-upd\": \"user-invocable-only\",\n    \"pjp-dev-tracker\": \"off\"\n  }\n}\n";
    const RECORD: &str = "{\"version\":1,\"keys\":{\"pjp-old\":\"name-only\",\"pjp-plantuml\":\"name-only\",\"pjp-gone-manual\":\"name-only\",\"pjp-upd\":\"user-invocable-only\"}}\n";

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("skill-overrides");
            fixture(&t.path().join("home"));
            t.write("home/.claude/settings.json", SETTINGS);
            t.write(&format!("state/{RECORD_FILE}"), RECORD);
            Env { t }
        }

        fn run(&self, mode: Mode, dev_tracker: bool) -> (Outcome, String) {
            let sys = FakeSys::new(|_| unreachable!());
            let host = format!("[tools]\ndevTracker = {dev_tracker}\n");
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: parse(&host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                ClaudeSkillOverrides.run(&mut ctx, mode).remove(0)
            };
            (o, String::from_utf8(out).unwrap())
        }

        fn settings(&self) -> serde_json::Value {
            OValue::parse(
                &std::fs::read_to_string(self.t.path().join("home/.claude/settings.json")).unwrap(),
            )
            .unwrap()
            .to_value()
        }

        fn record(&self) -> serde_json::Value {
            serde_json::from_str(
                &std::fs::read_to_string(self.t.path().join("state").join(RECORD_FILE)).unwrap(),
            )
            .unwrap()
        }
    }

    #[test]
    fn writes_and_records() {
        let e = Env::new();
        let (o, out) = e.run(Mode::Check, true);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        assert_eq!(
            e.settings(),
            OValue::parse(SETTINGS).unwrap().to_value(),
            "check は書かない"
        );
        assert!(
            out.contains("host option の値を書く (on): pjp-dev-tracker (apply で)"),
            "{out}"
        );
        let (_, out) = e.run(Mode::DryRun { force: false }, true);
        assert!(
            out.contains("[dry-run] 戻す (name-only を消した): pjp-old"),
            "{out}"
        );
        let (o, out) = e.run(Mode::Apply { force: false }, true);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        let s = e.settings();
        let so = &s["skillOverrides"];
        assert_eq!(so["pjp-plantuml"], "off", "手で書いた値は残す");
        assert!(so.get("pjp-old").is_none(), "書かなくなった key は戻す");
        assert_eq!(so["keep-me"], "on");
        assert_eq!(so["pjp-crlf"], "name-only");
        assert_eq!(so["pjp-multi"], "name-only");
        assert_eq!(so["pjp-upd"], "name-only", "控えた値から書き換える");
        assert_eq!(so["pjp-gone-manual"], "off");
        assert_eq!(so["pjp-dev-tracker"], "on");
        assert_eq!(so["anthropic-skills:my-skill"], "user-invocable-only");
        for k in [
            "pjp-lonely",
            "pjp-bad",
            "pjp-fullwidth",
            "pjp-mod",
            "pjp-dmi",
            "pjp-pack-repo",
            "pjp-nopack",
            ".hidden",
            "anthropic-skills:bad name",
        ] {
            assert!(so.get(k).is_none(), "{k}");
        }
        assert!(
            out.contains(
                "手で書いた値を残しました (off。runner が書くなら name-only): pjp-plantuml"
            ),
            "{out}"
        );
        assert!(
            out.contains("戻しました (name-only を消した): pjp-old"),
            "{out}"
        );
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("pack video の入口") && n.contains("pjp-lonely, pjp-lonely2")),
            "{o:?}"
        );
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("pack lang の入口") && n.contains("名前だけにする: pjp-multi")),
            "{o:?}"
        );
        assert!(o.notes.iter().any(|n| n.contains("pjp-bad")), "{o:?}");
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("pjp-fullwidth") && n.contains("読めない")),
            "全角の空白は区切りにしない (bash の read -a と同じ): {o:?}"
        );
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("入口の skill pjp-pack-repo")),
            "{o:?}"
        );
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("mod を兼ねる skill pjp-mod")),
            "{o:?}"
        );
        let rec = e.record();
        assert_eq!(rec["version"], 1);
        assert!(rec["keys"].get("pjp-old").is_none() && rec["keys"].get("pjp-plantuml").is_none());
        assert_eq!(rec["keys"]["pjp-upd"], "name-only");
        // 2 回目は同じ
        let (o, _) = e.run(Mode::Check, true);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        // devTracker を外すと off
        let (o, _) = e.run(Mode::Apply { force: false }, false);
        assert_eq!(o.kind, Kind::Ok);
        assert_eq!(e.settings()["skillOverrides"]["pjp-dev-tracker"], "off");
    }

    #[test]
    fn rejects_non_object_overrides() {
        let e = Env::new();
        e.t.write("home/.claude/settings.json", "{\"skillOverrides\": []}");
        let (o, _) = e.run(Mode::Apply { force: false }, true);
        assert_eq!(o.kind, Kind::Failed);
        assert_eq!(
            std::fs::read_to_string(e.t.path().join("home/.claude/settings.json")).unwrap(),
            "{\"skillOverrides\": []}"
        );
    }

    #[test]
    fn unreadable_record_is_noted() {
        let e = Env::new();
        e.t.write(&format!("state/{RECORD_FILE}"), "{\"version\": 2}");
        let (o, _) = e.run(Mode::Check, true);
        assert!(
            o.notes.iter().any(|n| n.contains("控えが読めない")),
            "{o:?}"
        );
    }

    #[test]
    fn matches_bash() {
        if !parity::available() {
            return;
        }
        let script = parity::repo_file("nix/scripts/bootstrap-claude-skill-overrides.sh");
        for dev_tracker in [true, false] {
            let e = Env::new();
            // bash の版の HOME (同じ skill の並び・settings.json・控え・host option のファイル)
            let bash_home: PathBuf = e.t.path().join("bash-home");
            fixture(&bash_home);
            std::fs::write(bash_home.join(".claude/settings.json"), SETTINGS).unwrap();
            let state = bash_home.join(".local/state/dotfiles");
            std::fs::create_dir_all(&state).unwrap();
            std::fs::write(state.join(RECORD_FILE), RECORD).unwrap();
            std::fs::write(
                state.join("claude-skill-overrides.json"),
                format!(
                    "{{\"pjp-dev-tracker\":\"{}\"}}\n",
                    if dev_tracker { "on" } else { "off" }
                ),
            )
            .unwrap();
            for round in 0..2 {
                parity::run_bash(
                    &script,
                    "",
                    &[
                        ("HOME", Some(&bash_home.to_string_lossy())),
                        ("DOTFILES_SETUP_WARNINGS", None),
                    ],
                    None,
                );
                e.run(Mode::Apply { force: false }, dev_tracker);
                let bash_settings = OValue::parse(
                    &std::fs::read_to_string(bash_home.join(".claude/settings.json")).unwrap(),
                )
                .unwrap()
                .to_value();
                assert_eq!(
                    e.settings(),
                    bash_settings,
                    "devTracker={dev_tracker} {round} 回目"
                );
                let bash_record: serde_json::Value = serde_json::from_str(
                    &std::fs::read_to_string(state.join(RECORD_FILE)).unwrap(),
                )
                .unwrap();
                assert_eq!(
                    e.record(),
                    bash_record,
                    "devTracker={dev_tracker} {round} 回目"
                );
            }
        }
    }
}
