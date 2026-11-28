//! pjp pack のテスト (pjp-herdr-other-repo の test_pack.py の場面を写したもの。一時ディレクトリに skill の木を作る)。

use std::path::PathBuf;

use serde_json::{Value, json};

use super::*;
use crate::testutil::TempDir;

fn skill_md(name: &str, pack: Option<&str>, disabled: bool, body: &str) -> String {
    let mut lines = vec![
        "---".to_owned(),
        format!("name: {name}"),
        format!("description: {name} のときに使う"),
    ];
    if disabled {
        lines.push("disable-model-invocation: true".to_owned());
    }
    if let Some(p) = pack {
        lines.push("metadata:".to_owned());
        lines.push(format!("  pjp-pack: {p}"));
    }
    lines.extend(["---".to_owned(), String::new(), body.to_owned()]);
    lines.join("\n")
}

/// 入口の SKILL.md。notes は目録の節の末尾に足す行 ((skill の名前, 行))。
fn entry_md(pack: &str, catalog: &[&str], notes: &[(&str, &str)]) -> String {
    let mut body =
        format!("# {pack} の pack の入口\n\n| すること | 呼ぶ skill |\n| --- | --- |\n\n");
    for n in catalog {
        body.push_str(&format!("## {n}\n\n- いつ: {n} のとき\n"));
        if let Some((_, note)) = notes.iter().find(|(k, _)| k == n) {
            body.push_str(&format!("{note}\n"));
        }
        body.push('\n');
    }
    skill_md(&format!("{ENTRY_PREFIX}{pack}"), None, false, &body)
}

/// multi の docs の入口で、主でない節に置く主の入口 (notion) への案内。
const NOTION_POINTER: &str = "- 詳しくは主の入口 `pjp-pack-notion` の目録";
const NOTION_POINTERS: [(&str, &str); 2] = [
    ("pjp-shared", NOTION_POINTER),
    ("pjp-manual", NOTION_POINTER),
];

/// `<root>/<名前>/SKILL.md` の木。
struct Tree {
    t: TempDir,
}

impl Tree {
    fn new() -> Self {
        Self {
            t: TempDir::new("pack"),
        }
    }

    fn root(&self) -> PathBuf {
        self.t.path().join("skills")
    }

    fn put(&self, name: &str, text: &str) {
        self.t.write(&format!("skills/{name}/SKILL.md"), text);
    }

    fn skill(&self, name: &str, pack: Option<&str>) {
        self.put(name, &skill_md(name, pack, false, "本文\n"));
    }

    fn disabled(&self, name: &str, pack: &str) {
        self.put(name, &skill_md(name, Some(pack), true, "本文\n"));
    }

    fn entry(&self, pack: &str, catalog: &[&str]) {
        self.entry_with(pack, catalog, &[]);
    }

    fn entry_with(&self, pack: &str, catalog: &[&str], notes: &[(&str, &str)]) {
        self.put(
            &format!("{ENTRY_PREFIX}{pack}"),
            &entry_md(pack, catalog, notes),
        );
    }

    fn hub_raw(&self, template: &str, raw: &str) {
        self.t.write(&format!("skills/{template}"), raw);
    }

    fn hub(&self, overrides: &Value) {
        self.hub_raw(
            HUB_TEMPLATES[0],
            &json!({"hooks": {}, "skillOverrides": overrides}).to_string(),
        );
    }

    fn synced(&self, name: &str, bucket: &str) {
        self.t.write(
            &format!("skills/synced/{bucket}/{name}/SKILL.md"),
            format!("---\nname: {name}\ndescription: x\n---\n"),
        );
    }

    /// 入口 pjp-pack-diagram と 2 本。目録には木に無い pjp-plantuml (ほかの repo の skill) もある。
    fn diagram(&self) {
        self.entry("diagram", &["pjp-plantuml", "pjp-a", "pjp-b"]);
        self.skill("pjp-a", Some("diagram"));
        self.skill("pjp-b", Some("diagram"));
        self.skill("pjp-resident", None);
    }

    /// 入口 notion と docs。pjp-shared と pjp-manual (disable-model-invocation) は両方に入り、主は notion。
    fn multi(&self) {
        self.entry("notion", &["pjp-n", "pjp-shared", "pjp-manual"]);
        self.entry_with(
            "docs",
            &["pjp-d", "pjp-shared", "pjp-manual"],
            &NOTION_POINTERS,
        );
        self.skill("pjp-n", Some("notion"));
        self.skill("pjp-d", Some("docs"));
        self.skill("pjp-shared", Some("notion docs"));
        self.disabled("pjp-manual", "notion docs");
    }

    fn run(&self, args: &[&str]) -> Run {
        let mut full: Vec<String> = args.iter().map(|a| (*a).to_owned()).collect();
        full.push("--root".to_owned());
        full.push(self.root().display().to_string());
        run(&full)
    }

    fn check(&self, partial: bool) -> Run {
        let mut args = vec!["check"];
        if partial {
            args.push("--partial");
        }
        self.run(&args)
    }
}

struct Run {
    code: u8,
    out: String,
    err: String,
}

impl Run {
    fn errors(&self) -> Vec<String> {
        self.err
            .lines()
            .filter(|l| l.starts_with("ERROR "))
            .map(str::to_owned)
            .collect()
    }

    fn hub_errors(&self, template: &str) -> Vec<String> {
        let prefix = format!("ERROR {template}: ");
        self.errors()
            .iter()
            .filter_map(|l| l.strip_prefix(&prefix).map(str::to_owned))
            .collect()
    }

    fn json(&self) -> Value {
        assert_eq!(self.out.matches('\n').count(), 1, "{}", self.out);
        serde_json::from_str(&self.out).unwrap()
    }
}

fn run(args: &[String]) -> Run {
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = main(args, &mut out, &mut err);
    Run {
        code,
        out: String::from_utf8(out).unwrap(),
        err: String::from_utf8(err).unwrap(),
    }
}

// ---- load_skill

#[test]
fn load_skill_disabled_and_frontmatter() {
    let t = Tree::new();
    t.disabled("pjp-x", "browser");
    let s = load_skill("pjp-x", &t.root().join("pjp-x").join("SKILL.md"));
    assert_eq!(
        (s.packs, s.disabled, s.problems.len()),
        (vec!["browser".to_owned()], true, 0)
    );
}

#[test]
fn load_skill_multi_and_primary() {
    let t = Tree::new();
    t.skill("pjp-x", Some("notion docs"));
    let s = load_skill("pjp-x", &t.root().join("pjp-x").join("SKILL.md"));
    assert_eq!(s.packs, ["notion", "docs"]);
    assert_eq!((s.primary_pack(), s.problems.len()), (Some("notion"), 0));
    t.skill("pjp-y", None);
    let s = load_skill("pjp-y", &t.root().join("pjp-y").join("SKILL.md"));
    assert_eq!(s.primary_pack(), None);
}

#[test]
fn load_skill_bom_and_crlf() {
    let t = Tree::new();
    let text = format!(
        "\u{feff}{}",
        skill_md("pjp-x", Some("repo docs"), false, "本文\n").replace('\n', "\r\n")
    );
    t.put("pjp-x", &text);
    let s = load_skill("pjp-x", &t.root().join("pjp-x").join("SKILL.md"));
    assert_eq!(
        (s.packs, s.problems.len()),
        (vec!["repo".to_owned(), "docs".to_owned()], 0)
    );
}

#[test]
fn load_skill_entry_sections() {
    // 入口は目録の節の本文も読む (同じ名前の節は先のもの)
    let t = Tree::new();
    t.put(
        "pjp-pack-x",
        &skill_md(
            "pjp-pack-x",
            None,
            false,
            "## pjp-a\n先の節\n## pjp-b\n### 小見出し\nb\n## pjp-a\n後の節\n",
        ),
    );
    let s = load_skill("pjp-pack-x", &t.root().join("pjp-pack-x").join("SKILL.md"));
    assert_eq!(s.catalog, ["pjp-a", "pjp-b", "pjp-a"]);
    assert_eq!(s.sections["pjp-a"], "先の節");
    assert_eq!(s.sections["pjp-b"], "### 小見出し\nb");
}

#[test]
fn load_skill_body_metadata_is_ignored() {
    let t = Tree::new();
    t.put(
        "pjp-x",
        &skill_md("pjp-x", None, false, "metadata:\n  pjp-pack: repo\n"),
    );
    let s = load_skill("pjp-x", &t.root().join("pjp-x").join("SKILL.md"));
    assert_eq!((s.packs, s.problems.len()), (vec![], 0));
}

// ---- settings

#[test]
fn settings_on_for_the_pack() {
    let t = Tree::new();
    t.diagram();
    let r = t.run(&["settings", "diagram"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.out,
        "{\"skillOverrides\":{\"pjp-a\":\"on\",\"pjp-b\":\"on\"}}\n"
    );
}

#[test]
fn settings_several_packs_and_duplicates() {
    let t = Tree::new();
    t.diagram();
    t.entry("video", &["pjp-v"]);
    t.skill("pjp-v", Some("video"));
    let r = t.run(&["settings", "video", "diagram", "video"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.json(),
        json!({"skillOverrides": {"pjp-a": "on", "pjp-b": "on", "pjp-v": "on"}})
    );
}

#[test]
fn settings_multi_pack_skill_is_on_once() {
    // 両方の pack に入る skill は 1 つにまとめ、disable-model-invocation の note も 1 回だけ出す
    let t = Tree::new();
    t.multi();
    let r = t.run(&["settings", "notion", "docs"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.json(),
        json!({"skillOverrides": {"pjp-d": "on", "pjp-n": "on", "pjp-shared": "on"}})
    );
    assert_eq!(
        r.err
            .matches("pjp-manual は disable-model-invocation")
            .count(),
        1,
        "{}",
        r.err
    );
}

#[test]
fn settings_either_pack_turns_it_on() {
    // 主でない pack だけを渡しても on になる
    let t = Tree::new();
    t.multi();
    let r = t.run(&["settings", "docs"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.json(),
        json!({"skillOverrides": {"pjp-d": "on", "pjp-shared": "on"}})
    );
}

#[test]
fn settings_one_pack_without_entry() {
    // 入口の無い pack を一緒に書いた skill も、入口のある pack を渡せば on になる (入口の無いことは check が出す)
    let t = Tree::new();
    t.diagram();
    t.skill("pjp-x", Some("diagram nothing"));
    let r = t.run(&["settings", "diagram"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.json(),
        json!({"skillOverrides": {"pjp-a": "on", "pjp-b": "on", "pjp-x": "on"}})
    );
}

#[test]
fn settings_pack_without_skills_message() {
    let t = Tree::new();
    t.entry("empty", &[]);
    let r = t.run(&["settings", "empty"]);
    assert_eq!(
        r.err,
        "pjp pack settings: pack empty に on にできる skill がありません (metadata の pjp-pack に empty を書いた skill が無い)\n"
    );
}

#[test]
fn settings_disabled_skill_is_not_turned_on() {
    let t = Tree::new();
    t.entry("browser", &["pjp-p", "pjp-e2e"]);
    t.skill("pjp-p", Some("browser"));
    t.disabled("pjp-e2e", "browser");
    let r = t.run(&["settings", "browser"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(r.json(), json!({"skillOverrides": {"pjp-p": "on"}}));
    assert!(
        r.err.contains("pjp-e2e は disable-model-invocation"),
        "{}",
        r.err
    );
}

#[test]
fn settings_unknown_pack() {
    let t = Tree::new();
    t.diagram();
    let r = t.run(&["settings", "diagram", "nosuch"]);
    assert_eq!(r.code, 2);
    assert_eq!(r.out, "");
    assert!(
        r.err
            .contains("pack nosuch の入口 pjp-pack-nosuch がありません (ある pack: diagram)"),
        "{}",
        r.err
    );
}

#[test]
fn settings_pack_without_skills() {
    let t = Tree::new();
    t.entry("empty", &[]);
    let r = t.run(&["settings", "empty"]);
    assert_eq!((r.code, r.out.as_str()), (2, ""));
    assert!(
        r.err.contains("on にできる skill がありません"),
        "{}",
        r.err
    );
}

#[test]
fn settings_no_arguments() {
    let t = Tree::new();
    let r = t.run(&["settings"]);
    assert_eq!((r.code, r.out.as_str()), (2, ""));
}

#[test]
fn settings_synced() {
    let t = Tree::new();
    t.diagram();
    t.synced("pdf", "bucket-1");
    t.synced("docx", "bucket-2");
    let r = t.run(&[
        "settings",
        "diagram",
        "--synced",
        "pdf",
        "--synced",
        "anthropic-skills:docx",
    ]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.json()["skillOverrides"],
        json!({"anthropic-skills:docx": "on", "anthropic-skills:pdf": "on", "pjp-a": "on", "pjp-b": "on"})
    );
    // 同期された skill だけでもよい
    let r = t.run(&["settings", "--synced", "pdf"]);
    assert_eq!(
        r.json(),
        json!({"skillOverrides": {"anthropic-skills:pdf": "on"}})
    );
}

#[test]
fn settings_unknown_synced() {
    let t = Tree::new();
    t.diagram();
    t.synced("pdf", "bucket-1");
    let r = t.run(&["settings", "diagram", "--synced", "pfd"]);
    assert_eq!((r.code, r.out.as_str()), (2, ""));
    assert!(
        r.err
            .contains("同期された skill pfd がありません (ある skill: pdf)"),
        "{}",
        r.err
    );
}

#[test]
fn settings_unreadable_metadata_is_warned_and_skipped() {
    let t = Tree::new();
    t.diagram();
    t.put(
        "pjp-bad",
        &skill_md("pjp-bad", None, false, "本文\n").replacen(
            "---\n\n",
            "metadata:\n  pjp-pack: \"diagram\"\n---\n\n",
            1,
        ),
    );
    // 値は読めても、ほかに読めない行があれば数えない (pjp-pack が 2 つ。YAML は後の値を採る)
    t.put(
        "pjp-dup",
        &skill_md("pjp-dup", None, false, "本文\n").replacen(
            "---\n\n",
            "metadata:\n  pjp-pack: diagram\n  pjp-pack: video\n---\n\n",
            1,
        ),
    );
    let r = t.run(&["settings", "diagram"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.json(),
        json!({"skillOverrides": {"pjp-a": "on", "pjp-b": "on"}})
    );
    assert!(r.err.contains("WARN  pjp-bad:"), "{}", r.err);
    assert!(r.err.contains("WARN  pjp-dup:"), "{}", r.err);
}

#[test]
fn settings_first_root_wins() {
    let t = Tree::new();
    t.diagram();
    let other = TempDir::new("pack-other");
    other.write(
        "pjp-a/SKILL.md",
        skill_md("pjp-a", Some("video"), false, "本文\n"), // 先の root にある名前は読まない
    );
    other.write(
        "pjp-c/SKILL.md",
        skill_md("pjp-c", Some("diagram"), false, "本文\n"),
    );
    let args: Vec<String> = [
        "settings".to_owned(),
        "diagram".to_owned(),
        "--root".to_owned(),
        t.root().display().to_string(),
        "--root".to_owned(),
        other.path().display().to_string(),
    ]
    .into();
    let r = run(&args);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.json(),
        json!({"skillOverrides": {"pjp-a": "on", "pjp-b": "on", "pjp-c": "on"}})
    );
}

#[test]
fn settings_missing_root() {
    let t = Tree::new();
    let args: Vec<String> = [
        "settings".to_owned(),
        "diagram".to_owned(),
        "--root".to_owned(),
        t.t.path().join("nothing").display().to_string(),
    ]
    .into();
    let r = run(&args);
    assert_eq!((r.code, r.out.as_str()), (2, ""));
    assert!(r.err.contains("skill の置き場所がありません"), "{}", r.err);
}

#[test]
fn settings_json_for_child() {
    let t = Tree::new();
    t.diagram();
    let mut err = Vec::new();
    let json = settings_json(&[t.root()], &["diagram".to_owned()], &[], &mut err).unwrap();
    assert_eq!(
        json,
        "{\"skillOverrides\":{\"pjp-a\":\"on\",\"pjp-b\":\"on\"}}"
    );
    assert_eq!(
        settings_json(&[t.root()], &["nosuch".to_owned()], &[], &mut err),
        Err(2)
    );
}

// ---- check

#[test]
fn check_consistent() {
    let t = Tree::new();
    t.diagram();
    let r = t.check(true);
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(
        r.out
            .contains("pack 1 件 / pack の skill 2 件 / エラー 0 / 警告 0"),
        "{}",
        r.out
    );
    assert!(r.out.contains("確かめていない): pjp-plantuml"), "{}", r.out);
}

#[test]
fn check_full_mode_reports_missing_catalog_skill() {
    let t = Tree::new();
    t.diagram();
    let r = t.check(false);
    assert_eq!(r.code, 1);
    assert_eq!(
        r.errors(),
        [
            "ERROR pjp-pack-diagram: 目録の pjp-plantuml が見つかりません (名前の打ち間違いか、この PC に入っていない)"
        ]
    );
}

#[test]
fn check_pack_without_entry() {
    let t = Tree::new();
    t.diagram();
    t.skill("pjp-x", Some("nothing"));
    let r = t.check(true);
    assert_eq!(r.code, 1);
    assert_eq!(r.errors(), [NO_ENTRY_NOTHING]);
}

const NO_ENTRY_NOTHING: &str = "ERROR pjp-x: pjp-pack の nothing の入口 pjp-pack-nothing がありません (入口の無い pack からは、この skill を辿れない)";

#[test]
fn check_multi_pack_with_one_entry_missing() {
    // 入口の無い pack の分だけ落ちる。入口のある pack の目録の節はそのまま見る
    let t = Tree::new();
    t.diagram();
    t.entry("diagram", &["pjp-plantuml", "pjp-a", "pjp-b", "pjp-x"]);
    t.skill("pjp-x", Some("diagram nothing"));
    assert_eq!(t.check(true).errors(), [NO_ENTRY_NOTHING]);
}

#[test]
fn check_primary_pack_without_entry() {
    // 主の pack に入口が無ければ、無い入口への案内は求めない (入口の無いことだけを出す)
    let t = Tree::new();
    t.diagram();
    t.entry("diagram", &["pjp-plantuml", "pjp-a", "pjp-b", "pjp-x"]);
    t.skill("pjp-x", Some("nothing diagram"));
    assert_eq!(t.check(true).errors(), [NO_ENTRY_NOTHING]);
}

#[test]
fn check_multi_pack_consistent() {
    let t = Tree::new();
    t.multi();
    let r = t.check(true);
    assert_eq!(r.code, 0, "{}", r.err);
    // pjp-shared・pjp-manual は 2 つの pack に入るが、pack の skill は重ねずに数える
    assert!(
        r.out
            .contains("pack 2 件 / pack の skill 4 件 / エラー 0 / 警告 0"),
        "{}",
        r.out
    );
}

#[test]
fn check_missing_section_in_secondary_entry() {
    let t = Tree::new();
    t.multi();
    t.entry_with(
        "docs",
        &["pjp-d", "pjp-manual"],
        &[("pjp-manual", NOTION_POINTER)],
    );
    assert_eq!(
        t.check(true).errors(),
        ["ERROR pjp-pack-docs: 目録に pjp-shared の節がありません (## pjp-shared を足す)"]
    );
}

#[test]
fn check_pointer_names_the_primary_entry() {
    // 主でない入口の節には、主の入口の名前が要る。次の節 (pjp-manual) にあるだけ・似た名前・別の入口の名前では足りない
    let want = "ERROR pjp-pack-docs: 目録の pjp-shared の節に、主の入口 pjp-pack-notion への案内がありません (主でない pack の入口の節には「詳しくは主の入口 pjp-pack-notion の目録」と書く)";
    for note in [
        None,
        Some("- 詳しくは `pjp-pack-notionx` の目録"),
        Some("- 詳しくは主の入口 `pjp-pack-docs` の目録"),
        Some("- 詳しくは主の入口 `pjp-pack-notion-x` の目録"),
    ] {
        let t = Tree::new();
        t.multi();
        let mut notes = vec![("pjp-manual", NOTION_POINTER)];
        if let Some(n) = note {
            notes.push(("pjp-shared", n));
        }
        t.entry_with("docs", &["pjp-d", "pjp-shared", "pjp-manual"], &notes);
        assert_eq!(t.check(true).errors(), [want], "{note:?}");
    }
}

#[test]
fn check_pointer_may_touch_japanese_text() {
    // backquote で囲まず、すぐ後ろに日本語が続いても案内に数える。節の中の ### の下にあってもよい
    let t = Tree::new();
    t.multi();
    t.entry_with(
        "docs",
        &["pjp-d", "pjp-shared", "pjp-manual"],
        &[
            ("pjp-shared", "- 詳しくは主の入口 pjp-pack-notionの目録"),
            ("pjp-manual", "### 小見出し\n詳しくは pjp-pack-notion"),
        ],
    );
    let r = t.check(true);
    assert_eq!(r.code, 0, "{}", r.err);
}

#[test]
fn check_pointer_after_a_closing_heading_is_not_counted() {
    // 案内が、節を閉じる ## の見出しの後ろにあれば、その節の案内に数えない
    let t = Tree::new();
    t.multi();
    t.entry_with(
        "docs",
        &["pjp-d", "pjp-shared", "pjp-manual"],
        &[
            (
                "pjp-shared",
                "## 使い分け\n- 詳しくは主の入口 `pjp-pack-notion` の目録",
            ),
            ("pjp-manual", NOTION_POINTER),
        ],
    );
    assert_eq!(
        t.check(true).errors(),
        [
            "ERROR pjp-pack-docs: 目録の pjp-shared の節に、主の入口 pjp-pack-notion への案内がありません (主でない pack の入口の節には「詳しくは主の入口 pjp-pack-notion の目録」と書く)"
        ]
    );
}

#[test]
fn check_assigned_but_not_in_catalog() {
    let t = Tree::new();
    t.diagram();
    t.skill("pjp-c", Some("diagram"));
    assert_eq!(
        t.check(true).errors(),
        ["ERROR pjp-pack-diagram: 目録に pjp-c の節がありません (## pjp-c を足す)"]
    );
}

#[test]
fn check_catalog_skill_without_or_with_other_pack() {
    let t = Tree::new();
    t.entry("diagram", &["pjp-a", "pjp-v", "pjp-pack-video", "pjp-a"]);
    t.skill("pjp-a", None);
    t.entry("video", &["pjp-v"]);
    t.skill("pjp-v", Some("video"));
    assert_eq!(
        t.check(true).errors(),
        [
            "ERROR pjp-pack-diagram: 目録の pjp-a に metadata の pjp-pack: diagram がありません (その SKILL.md に足すか、目録から外す)",
            "ERROR pjp-pack-diagram: 目録の pjp-v は pjp-pack: video です (pjp-pack に diagram を足すか、目録から外す)",
            "ERROR pjp-pack-diagram: 目録に入口 pjp-pack-video を載せない",
            "ERROR pjp-pack-diagram: 目録に pjp-a の節が 2 つあります",
        ]
    );
}

#[test]
fn check_catalog_lists_a_multi_pack_skill_of_other_packs() {
    let t = Tree::new();
    t.multi();
    t.entry("repo", &["pjp-shared"]);
    assert_eq!(
        t.check(true).errors(),
        [
            "ERROR pjp-pack-repo: 目録の pjp-shared は pjp-pack: notion docs です (pjp-pack に repo を足すか、目録から外す)"
        ]
    );
}

#[test]
fn check_entry_with_pack() {
    let t = Tree::new();
    t.put(
        "pjp-pack-x",
        &skill_md("pjp-pack-x", Some("x"), false, "## pjp-a\n"),
    );
    t.skill("pjp-a", Some("x"));
    assert_eq!(
        t.check(true).errors(),
        [
            "ERROR pjp-pack-x: 入口に metadata の pjp-pack を書かない (入口は常駐で、pack の skill ではない)"
        ]
    );
}

#[test]
fn check_empty_entry_is_a_warning() {
    let t = Tree::new();
    t.entry("empty", &[]);
    let r = t.check(true);
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(
        r.err
            .contains("WARN  pjp-pack-empty: 目録も割り当ても空です"),
        "{}",
        r.err
    );
}

#[test]
fn check_unreadable_metadata() {
    let t = Tree::new();
    t.put(
        "pjp-a",
        &skill_md("pjp-a", None, false, "本文\n").replacen(
            "---\n\n",
            "metadata: {pjp-pack: x}\n---\n\n",
            1,
        ),
    );
    let r = t.check(true);
    assert_eq!(r.code, 1);
    // ファイルの 4 行目 (---・name・description の次)
    assert!(
        r.err
            .contains("ERROR pjp-a: 4 行目の metadata を 1 行で書いています"),
        "{}",
        r.err
    );
}

#[test]
fn check_unreadable_metadata_is_reported_once() {
    // 目録にある skill が読めない形でも、目録の検査は重ねて出さない
    let t = Tree::new();
    t.diagram();
    t.put(
        "pjp-a",
        &skill_md("pjp-a", None, false, "本文\n").replacen(
            "---\n\n",
            "metadata:\n  pjp-pack: diagram\n  pjp-pack: diagram\n---\n\n",
            1,
        ),
    );
    assert_eq!(
        t.check(true).errors(),
        [
            "ERROR pjp-a: 6 行目: pjp-pack の行が 2 つあります (pack をいくつも書くなら、1 行に空白で区切って並べる)"
        ]
    );
}

#[test]
fn check_missing_root() {
    let t = Tree::new();
    let args: Vec<String> = [
        "check".to_owned(),
        "--root".to_owned(),
        t.t.path().join("nothing").display().to_string(),
    ]
    .into();
    assert_eq!(run(&args).code, 2);
}

// ---- check (ハブの雛形)

fn hub_tree() -> (Tree, Value) {
    let t = Tree::new();
    t.diagram();
    t.entry("video", &["pjp-v"]);
    t.skill("pjp-v", Some("video"));
    t.entry("browser", &["pjp-p", "pjp-e2e"]);
    t.skill("pjp-p", Some("browser"));
    t.disabled("pjp-e2e", "browser");
    let whole = json!({"pjp-a": "on", "pjp-b": "on", "pjp-plantuml": "on", "pjp-v": "on"});
    (t, whole)
}

fn without(v: &Value, key: &str) -> Value {
    let mut v = v.clone();
    v.as_object_mut().unwrap().remove(key);
    v
}

fn with(v: &Value, extra: &Value) -> Value {
    let mut v = v.clone();
    for (k, x) in extra.as_object().unwrap() {
        v[k] = x.clone();
    }
    v
}

#[test]
fn check_hub_whole_packs() {
    let (t, whole) = hub_tree();
    t.hub(&whole);
    let r = t.check(true);
    assert_eq!(r.code, 0, "{}", r.err);
}

#[test]
fn check_hub_missing_member() {
    let (t, whole) = hub_tree();
    t.hub(&without(&whole, "pjp-b"));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        ["pack diagram の pjp-b がありません (ハブでは pack を丸ごと on にする)"]
    );
}

#[test]
fn check_hub_missing_skill_of_another_repo() {
    // 木に無い pjp-plantuml も、目録にあれば丸ごとに数える
    let (t, whole) = hub_tree();
    t.hub(&without(&whole, "pjp-plantuml"));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        ["pack diagram の pjp-plantuml がありません (ハブでは pack を丸ごと on にする)"]
    );
}

#[test]
fn check_hub_wrong_names() {
    let (t, whole) = hub_tree();
    t.hub(&with(
        &whole,
        &json!({"pjp-resident": "on", "pjp-pack-video": "on", "pjp-typo": "on", "pjp-x": "name-only"}),
    ));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        [
            "pjp-pack-video は入口 (常駐) なので on にしなくてよい",
            "pjp-resident は pack の skill ではありません (on にするのは pack の skill だけ)",
            "pjp-typo はどの入口の目録にもありません (名前の打ち間違いか、pack の skill ではない)",
        ]
    );
}

#[test]
fn check_hub_disabled_member() {
    let (t, whole) = hub_tree();
    t.hub(&with(&whole, &json!({"pjp-p": "on", "pjp-e2e": "on"})));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        ["pjp-e2e は disable-model-invocation なので on にしない"]
    );
}

#[test]
fn check_hub_disabled_member_is_not_required() {
    let (t, whole) = hub_tree();
    t.hub(&with(&whole, &json!({"pjp-p": "on"})));
    assert_eq!(t.check(true).code, 0);
}

#[test]
fn check_hub_broken_json() {
    let (t, _) = hub_tree();
    t.hub_raw(HUB_TEMPLATES[0], "{");
    let errs = t.check(true).hub_errors(HUB_TEMPLATES[0]);
    assert_eq!(errs.len(), 1);
    assert!(errs[0].contains("JSON として読めません"), "{errs:?}");
}

#[test]
fn check_hub_without_skill_overrides() {
    let (t, _) = hub_tree();
    t.hub_raw(HUB_TEMPLATES[0], r#"{"hooks": {}}"#);
    assert_eq!(t.check(true).code, 0);
    // null も無いのと同じ (pack.py の data.get("skillOverrides") は None)
    t.hub_raw(HUB_TEMPLATES[0], r#"{"skillOverrides": null}"#);
    assert_eq!(t.check(true).code, 0);
    t.hub_raw(HUB_TEMPLATES[0], r#"{"skillOverrides": []}"#);
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        ["skillOverrides が object ではありません"]
    );
}

#[test]
fn check_hub_reads_both_templates() {
    // hc 版のハブの雛形も同じ決まりで見る (spec §7.2)
    let (t, whole) = hub_tree();
    t.hub(&whole);
    t.hub_raw(
        HUB_TEMPLATES[1],
        &json!({"skillOverrides": without(&whole, "pjp-v")})
            .to_string()
            .replace("\"pjp-a\":\"on\"", "\"pjp-a\":\"on\",\"pjp-typo\":\"on\""),
    );
    let r = t.check(true);
    assert_eq!(r.code, 1);
    assert_eq!(r.hub_errors(HUB_TEMPLATES[0]), Vec::<String>::new());
    assert_eq!(
        r.hub_errors(HUB_TEMPLATES[1]),
        ["pjp-typo はどの入口の目録にもありません (名前の打ち間違いか、pack の skill ではない)"]
    );
    // pjp-v を外しても、ほかに video の skill が on でなければ video の pack は数えない (丸ごと off)
    assert!(!r.err.contains("pack video"), "{}", r.err);
}

#[test]
fn check_hub_partial_pack_through_overlap_is_fine() {
    // notion (pjp-shared の主) を丸ごと on にすると、docs は pjp-shared だけが on になる。重なりのためなので咎めない
    let (t, whole) = hub_tree();
    t.multi();
    t.hub(&with(&whole, &json!({"pjp-n": "on", "pjp-shared": "on"})));
    let r = t.check(true);
    assert_eq!(r.code, 0, "{}", r.err);
}

#[test]
fn check_hub_either_whole_pack_covers_it() {
    // 主でない pack (docs) が丸ごと on なら、主の pack (notion) が一部だけでもよい
    let (t, whole) = hub_tree();
    t.multi();
    t.hub(&with(&whole, &json!({"pjp-d": "on", "pjp-shared": "on"})));
    let r = t.check(true);
    assert_eq!(r.code, 0, "{}", r.err);
}

const UNCOVERED_SHARED: &str = "pjp-shared の入る pack (notion・docs) が、どれも丸ごと on になっていません (notion の pjp-n、docs の pjp-d がありません。ハブでは、どれか 1 つの pack を丸ごと on にする)";

#[test]
fn check_hub_no_whole_pack_for_a_multi_pack_skill() {
    let (t, whole) = hub_tree();
    t.multi();
    t.hub(&with(&whole, &json!({"pjp-shared": "on"})));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        [UNCOVERED_SHARED]
    );
}

#[test]
fn check_hub_multi_rule_reads_the_hc_template_too() {
    // hc 版のハブの雛形も、同じ決まりで見る (pack.py は旧 herdr のハブの雛形だけを見る)
    let (t, whole) = hub_tree();
    t.multi();
    t.hub_raw(
        HUB_TEMPLATES[1],
        &json!({"skillOverrides": with(&whole, &json!({"pjp-shared": "on"}))}).to_string(),
    );
    let r = t.check(true);
    assert_eq!(r.hub_errors(HUB_TEMPLATES[0]), Vec::<String>::new());
    assert_eq!(r.hub_errors(HUB_TEMPLATES[1]), [UNCOVERED_SHARED]);
}

#[test]
fn check_hub_single_pack_skill_still_needs_its_pack() {
    // pjp-d は docs だけに入るので、docs を丸ごと on にする (pjp-d2 が要る)。2 つの pack に入る pjp-shared は、
    // docs を丸ごとにすれば片付くので、notion の足りない skill (pjp-n) は出さない
    let (t, whole) = hub_tree();
    t.multi();
    t.entry_with(
        "docs",
        &["pjp-d", "pjp-d2", "pjp-shared", "pjp-manual"],
        &NOTION_POINTERS,
    );
    t.skill("pjp-d2", Some("docs"));
    t.hub(&with(&whole, &json!({"pjp-d": "on", "pjp-shared": "on"})));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        ["pack docs の pjp-d2 がありません (ハブでは pack を丸ごと on にする)"]
    );
}

#[test]
fn check_hub_pack_without_entry_does_not_cover() {
    // 入口の無い pack (書き違い) は、その skill だけで丸ごと on に見えても数えない。入口のある diagram を丸ごとにする
    let (t, _) = hub_tree();
    t.entry("diagram", &["pjp-plantuml", "pjp-a", "pjp-b", "pjp-x"]);
    t.skill("pjp-x", Some("diagram nothing"));
    t.hub(&json!({"pjp-v": "on", "pjp-x": "on"}));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        ["pjp-a", "pjp-b", "pjp-plantuml"].map(|n| format!(
            "pack diagram の {n} がありません (ハブでは pack を丸ごと on にする)"
        ))
    );
}

#[test]
fn check_hub_skill_of_another_repo_in_two_catalogs() {
    // 木に無い skill が 2 つの入口の目録にあれば、どちらかの pack が丸ごと on ならよい
    let (t, whole) = hub_tree();
    t.multi();
    t.entry("notion", &["pjp-n", "pjp-shared", "pjp-manual", "pjp-ext"]);
    t.entry_with(
        "docs",
        &["pjp-d", "pjp-shared", "pjp-manual", "pjp-ext"],
        &NOTION_POINTERS,
    );
    t.hub(&with(
        &whole,
        &json!({"pjp-d": "on", "pjp-shared": "on", "pjp-ext": "on"}),
    ));
    let r = t.check(true);
    assert_eq!(r.code, 0, "{}", r.err);
    // どの pack も丸ごとでなければ、目録の pack の順 (名前の順) で並べる
    t.hub(&with(&whole, &json!({"pjp-ext": "on"})));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        [
            "pjp-ext の入る pack (docs・notion) が、どれも丸ごと on になっていません (docs の pjp-d・pjp-shared、notion の pjp-n・pjp-shared がありません。ハブでは、どれか 1 つの pack を丸ごと on にする)"
        ]
    );
}

#[test]
fn check_hub_skill_of_another_repo_listed_twice_in_one_catalog() {
    // 1 つの目録に 2 回載った木に無い skill も、入る pack は 1 つ (docs)。その pack を丸ごと on にする文を出す
    let (t, whole) = hub_tree();
    t.multi();
    t.entry_with(
        "docs",
        &["pjp-d", "pjp-shared", "pjp-manual", "pjp-ext", "pjp-ext"],
        &NOTION_POINTERS,
    );
    t.hub(&with(&whole, &json!({"pjp-ext": "on"})));
    assert_eq!(
        t.check(true).hub_errors(HUB_TEMPLATES[0]),
        ["pjp-d", "pjp-shared"]
            .map(|n| format!("pack docs の {n} がありません (ハブでは pack を丸ごと on にする)"))
    );
}

#[test]
fn check_hub_on_skill_with_only_packs_without_entry() {
    // 入口の無い pack しか書いていない skill を on にしても、ハブの行は出さない (入口の無いことは skill の行で出る)
    let (t, whole) = hub_tree();
    t.skill("pjp-x", Some("nothing"));
    t.hub(&with(&whole, &json!({"pjp-x": "on"})));
    let r = t.check(true);
    assert_eq!(r.hub_errors(HUB_TEMPLATES[0]), Vec::<String>::new());
    assert_eq!(r.errors(), [NO_ENTRY_NOTHING]);
}

// ---- list

#[test]
fn list_packs() {
    let t = Tree::new();
    t.diagram();
    t.entry("browser", &["pjp-p", "pjp-e2e"]);
    t.skill("pjp-p", Some("browser"));
    t.disabled("pjp-e2e", "browser");
    t.skill("pjp-x", Some("orphan"));
    t.synced("pdf", "bucket-1");
    let r = t.run(&["list"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.out.lines().collect::<Vec<_>>(),
        [
            "browser  (入口 pjp-pack-browser)  pjp-p  / 自動では呼ばない: pjp-e2e",
            "diagram  (入口 pjp-pack-diagram)  pjp-a pjp-b",
            "orphan  (入口なし)  pjp-x",
            "同期された skill (settings --synced <名前>): pdf",
        ]
    );
}

#[test]
fn list_marks_the_primary() {
    // 主でない pack の行では、skill に主の pack を添える。添えたときだけ、意味を 1 行で出す (同期された skill の行より前)
    let t = Tree::new();
    t.multi();
    t.synced("pdf", "bucket-1");
    let r = t.run(&["list"]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.out.lines().collect::<Vec<_>>(),
        [
            "docs  (入口 pjp-pack-docs)  pjp-d pjp-shared(主: notion)  / 自動では呼ばない: pjp-manual(主: notion)",
            "notion  (入口 pjp-pack-notion)  pjp-n pjp-shared  / 自動では呼ばない: pjp-manual",
            "(主: <pack>) は、複数の pack に入る skill の主の pack (その入口の目録に節を全部書く)",
            "同期された skill (settings --synced <名前>): pdf",
        ]
    );
}

// ---- 引数

#[test]
fn usage_errors_are_config_errors() {
    assert_eq!(run(&[]).code, 2);
    assert_eq!(run(&["nope".to_owned()]).code, 2);
    assert_eq!(run(&["list".to_owned(), "extra".to_owned()]).code, 2);
    assert_eq!(run(&["check".to_owned(), "--nope".to_owned()]).code, 2);
    let r = run(&["--help".to_owned()]);
    assert_eq!(r.code, 0);
    assert!(r.out.contains("pjp pack settings"), "{}", r.out);
}

#[test]
fn expand_user_handles_tilde() {
    let home = PathBuf::from("/home/u");
    assert_eq!(expand_user("~", &home), home);
    assert_eq!(
        expand_user("~/.claude-work", &home),
        home.join(".claude-work")
    );
    assert_eq!(expand_user("/x/y", &home), PathBuf::from("/x/y"));
}

#[cfg(unix)]
#[test]
fn root_paths_are_normalized_like_pathlib() {
    for (raw, want) in [
        ("nothing/", "nothing"),
        ("./x", "x"),
        ("a//b/./c/", "a/b/c"),
        ("", "."),
        (".", "."),
        ("/tmp//x/", "/tmp/x"),
        ("//srv/x", "//srv/x"),
        ("///srv", "/srv"),
        ("../x", "../x"),
    ] {
        assert_eq!(py_path(raw), PathBuf::from(want), "{raw:?}");
    }
}
