//! ハブの決まりのファイルの雛形 (`assets/hub/`)。exe に埋め込み、動くときにこのマシンの値で描く ([`files`])。改行は LF に
//! そろえて書き・比べる (Windows の git の core.autocrlf で CRLF になっても、同じ中身とみる)。
//!
//! - `CLAUDE.md`: 中の `%USERPROFILE%\h` を、Windows ではそのマシンのホームの下の `h` にする (ほかの OS ではそのまま)
//! - `.claude/settings.json`: 公開の雛形は hook だけを持つ。private な足し分の skill (`pjp-hc-hub-private`) が雛形の重ねのファイル
//!   (`~/.claude/skills/pjp-hc-hub-private/assets/hub/settings.overlay.json`。形は `{"skillOverrides": {"<skill>": "on", …}}`) を
//!   持っていれば、その `skillOverrides` を重ねる (dotfiles-private の ADR 124。公開の雛形に private な skill の名前を並べない)
//! - `.gitignore`: そのまま

use std::path::{Path, PathBuf};

use pjp_core::{Error, Result, paths};
use serde_json::{Map, Value};

/// 埋め込んだ雛形の 1 つ (描く前)。
#[derive(Debug, Clone, Copy)]
struct Raw {
    rel: &'static str,
    source: &'static str,
    text: &'static str,
}

/// ハブの決まりのファイル (この順に写して出す)。gitignore は assets の中に `.gitignore` の名前で置くと、git がその場で
/// 効かせるので、別の名前で置く。
const RAW: [Raw; 3] = [
    Raw {
        rel: "CLAUDE.md",
        source: "CLAUDE.md",
        text: include_str!("../assets/hub/CLAUDE.md"),
    },
    Raw {
        rel: ".claude/settings.json",
        source: "settings.json",
        text: include_str!("../assets/hub/settings.json"),
    },
    Raw {
        rel: ".gitignore",
        source: "gitignore",
        text: include_str!("../assets/hub/gitignore"),
    },
];

/// CLAUDE.md の中で、Windows のハブの場所に置き換える字。
pub const WINDOWS_HUB_MARK: &str = r"%USERPROFILE%\h";
/// 雛形の重ねのファイル (ホームからの相対。`/` 区切り)。
pub const OVERLAY_REL: &str = ".claude/skills/pjp-hc-hub-private/assets/hub/settings.overlay.json";
/// 重ねのファイルに書けるキー。
const OVERLAY_KEY: &str = "skillOverrides";

/// 描いた雛形の 1 つ。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Template {
    /// ハブの中のパス (`/` 区切り。git の pathspec にもそのまま使う)。
    pub rel: &'static str,
    /// `assets/hub/` の中の名前。
    pub source: &'static str,
    content: String,
}

/// 雛形を描く元 (このマシンの値)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Context {
    /// CLAUDE.md の `%USERPROFILE%\h` に置く字 (Windows ではホームの下の `h`、ほかの OS では `%USERPROFILE%\h` のまま)。
    pub windows_hub: String,
    /// 重ねる skillOverrides (重ねのファイルが無ければ None)。
    pub overlay: Option<Map<String, Value>>,
}

impl Context {
    /// このマシンの値 (ホームは Unix では `HOME`、Windows では `USERPROFILE`)。重ねのファイルが壊れていれば Err (終了コード 2)。
    pub fn here() -> Result<Context> {
        Context::at(&paths::home_dir()?, cfg!(windows))
    }

    /// ホーム `home` の値。`windows` なら CLAUDE.md の Windows のハブの場所を `home` の下の `h` にする。
    pub fn at(home: &Path, windows: bool) -> Result<Context> {
        let windows_hub = if windows {
            home.join("h").to_string_lossy().into_owned()
        } else {
            WINDOWS_HUB_MARK.to_owned()
        };
        Ok(Context {
            windows_hub,
            overlay: read_overlay(&overlay_path(home))?,
        })
    }
}

/// ホーム `home` の重ねのファイルのパス。
pub fn overlay_path(home: &Path) -> PathBuf {
    OVERLAY_REL
        .split('/')
        .fold(home.to_path_buf(), |p, c| p.join(c))
}

/// 重ねのファイルを読む。無ければ None。読めない・形が違えば、パスとわけを添えた Err (終了コード 2)。
pub fn read_overlay(path: &Path) -> Result<Option<Map<String, Value>>> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(Error::config(format!(
                "{}: 雛形の重ねのファイルを読めません ({e})",
                path.display()
            )));
        }
    };
    let bad = |why: String| {
        Error::config(format!(
            "{}: 雛形の重ねのファイルの形が違います ({why})。形は {{\"{OVERLAY_KEY}\": {{\"<skill>\": \"on\", …}}}}",
            path.display()
        ))
    };
    let v: Value = serde_json::from_str(text.trim_start_matches('\u{feff}'))
        .map_err(|e| bad(format!("JSON として読めない: {e}")))?;
    let Value::Object(top) = v else {
        return Err(bad("JSON の object でない".to_owned()));
    };
    let unknown: Vec<&str> = top
        .keys()
        .map(String::as_str)
        .filter(|k| *k != OVERLAY_KEY)
        .collect();
    if !unknown.is_empty() {
        return Err(bad(format!(
            "知らないキー: {} (書けるのは {OVERLAY_KEY} だけ)",
            unknown.join(", ")
        )));
    }
    let Some(over) = top.get(OVERLAY_KEY) else {
        return Err(bad(format!("{OVERLAY_KEY} が無い")));
    };
    let Value::Object(over) = over else {
        return Err(bad(format!("{OVERLAY_KEY} が object でない")));
    };
    if let Some((k, _)) = over.iter().find(|(_, v)| !v.is_string()) {
        return Err(bad(format!("{OVERLAY_KEY}.{k} が文字列でない")));
    }
    Ok(Some(over.clone()))
}

/// このマシンの値 `ctx` で描いたハブの決まりのファイル (この順に写して出す)。
pub fn files(ctx: &Context) -> Vec<Template> {
    RAW.iter()
        .map(|r| {
            let text = r.text.replace("\r\n", "\n");
            let content = match r.source {
                "CLAUDE.md" => text.replace(WINDOWS_HUB_MARK, &ctx.windows_hub),
                "settings.json" => settings(&text, ctx.overlay.as_ref()),
                _ => text,
            };
            Template {
                rel: r.rel,
                source: r.source,
                content,
            }
        })
        .collect()
}

/// settings.json の雛形 `base` に skillOverrides を重ねた中身。重ねが無ければ `base` のまま (雛形は重ねたときと同じ形で書いて
/// ある: 2 字の字下げ・末尾の改行)。
fn settings(base: &str, overlay: Option<&Map<String, Value>>) -> String {
    let Some(overlay) = overlay else {
        return base.to_owned();
    };
    let mut v: Map<String, Value> =
        serde_json::from_str(base).expect("埋め込んだ settings.json の雛形は JSON の object");
    v.insert(OVERLAY_KEY.to_owned(), Value::Object(overlay.clone()));
    let mut out =
        serde_json::to_string_pretty(&Value::Object(v)).expect("JSON の値は文字列に書ける");
    out.push('\n');
    out
}

impl Template {
    /// 中身 (改行は LF)。
    pub fn content(&self) -> &str {
        &self.content
    }

    /// `hub` の中のこのファイルのパス (区切りはその OS の形)。
    pub fn path_in(&self, hub: &Path) -> PathBuf {
        self.rel
            .split('/')
            .fold(hub.to_path_buf(), |p, c| p.join(c))
    }

    /// `bytes` (ファイルか blob の中身) が雛形と同じか (CRLF と LF の違いは見ない)。
    pub fn same_as(&self, bytes: &[u8]) -> bool {
        lf(bytes) == self.content.as_bytes()
    }
}

/// CRLF を LF にする。
pub fn lf(bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\r' && bytes.get(i + 1) == Some(&b'\n') {
            out.push(b'\n');
            i += 2;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 埋めた雛形は assets/hub のファイルと同じ中身で、CR を持たない
    //! - CLAUDE.md の `%USERPROFILE%\h` は、Windows ではホームの下の h になり、ほかの OS ではそのまま
    //! - settings.json: 重ねが無ければ hook だけ (skillOverrides の鍵が無い)。重ねれば skillOverrides が hook の後ろに書いた順で入り、
    //!   2 字の字下げと末尾の改行の形は雛形と同じ。重ねが無いときの雛形も、その形で書いてある
    //! - 重ねのファイルが無ければ None。JSON でない・object でない・知らないキー・skillOverrides が無い・object でない・値が文字列でない
    //!   ものは、パスを添えて止まる (終了コード 2)。頭の BOM は読み飛ばす
    //! - hook の command は shell によらず同じに読める形。答え待ちの印を外す hook はいつも 0 で終える

    use super::*;
    use serde_json::json;

    fn ctx(overlay: Option<Value>) -> Context {
        Context {
            windows_hub: WINDOWS_HUB_MARK.to_owned(),
            overlay: overlay.map(|v| v.as_object().unwrap().clone()),
        }
    }

    fn file(ctx: &Context, source: &str) -> Template {
        files(ctx).into_iter().find(|t| t.source == source).unwrap()
    }

    struct Dir(PathBuf);

    impl Dir {
        fn new(name: &str) -> Dir {
            let d = std::env::temp_dir().join(format!(
                "pjp-hc-hub-templates-{}-{name}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            Dir(d)
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn templates_are_the_assets() {
        let assets = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("assets")
            .join("hub");
        for r in RAW {
            let on_disk = std::fs::read(assets.join(r.source)).unwrap();
            assert_eq!(
                lf(&on_disk),
                r.text.replace("\r\n", "\n").as_bytes(),
                "{}",
                r.source
            );
        }
        for t in files(&ctx(None)) {
            assert!(!t.content().contains('\r'), "{}", t.source);
        }
    }

    #[test]
    fn claude_md_names_the_windows_hub_of_this_machine() {
        let raw = file(&ctx(None), "CLAUDE.md");
        assert!(
            raw.content().contains(r"`%USERPROFILE%\h`"),
            "{}",
            raw.content()
        );
        let home = Path::new("C:").join("Users").join("user");
        let win = Context::at(&home, true).unwrap();
        let text = file(&win, "CLAUDE.md");
        let want = home.join("h").to_string_lossy().into_owned();
        assert!(
            text.content().contains(&format!("`{want}`")),
            "{}",
            text.content()
        );
        assert!(!text.content().contains(WINDOWS_HUB_MARK));
        assert_eq!(
            Context::at(&home, false).unwrap().windows_hub,
            WINDOWS_HUB_MARK
        );
    }

    #[test]
    fn settings_without_overlay_has_only_hooks() {
        let t = file(&ctx(None), "settings.json");
        let v: Value = serde_json::from_str(t.content()).unwrap();
        assert_eq!(v.as_object().unwrap().keys().collect::<Vec<_>>(), ["hooks"]);
        // 重ねたときと同じ形 (2 字の字下げ・末尾の改行) で書いてある
        let mut again = serde_json::to_string_pretty(&v).unwrap();
        again.push('\n');
        assert_eq!(t.content(), again);
    }

    #[test]
    fn overlay_adds_skill_overrides_after_the_hooks() {
        let t = file(
            &ctx(Some(json!({"pjp-b": "on", "pjp-a": "off"}))),
            "settings.json",
        );
        let v: Value = serde_json::from_str(t.content()).unwrap();
        let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
        assert_eq!(keys, ["hooks", "skillOverrides"]);
        let skills: Vec<&String> = v["skillOverrides"].as_object().unwrap().keys().collect();
        assert_eq!(skills, ["pjp-b", "pjp-a"]);
        assert!(t.content().ends_with("}\n"), "{}", t.content());
        assert!(
            t.content()
                .contains("\n  \"skillOverrides\": {\n    \"pjp-b\": \"on\",\n"),
            "{}",
            t.content()
        );
    }

    #[test]
    fn overlay_file_is_read_or_refused_with_its_path() {
        let d = Dir::new("overlay");
        let p = overlay_path(&d.0);
        assert!(
            p.ends_with(
                Path::new(".claude")
                    .join("skills")
                    .join("pjp-hc-hub-private")
                    .join("assets")
                    .join("hub")
                    .join("settings.overlay.json")
            )
        );
        assert_eq!(read_overlay(&p).unwrap(), None);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, "\u{feff}{\"skillOverrides\": {\"pjp-x\": \"on\"}}\n").unwrap();
        let got = read_overlay(&p).unwrap().unwrap();
        assert_eq!(Value::Object(got), json!({"pjp-x": "on"}));
        assert_eq!(
            Context::at(&d.0, false).unwrap().overlay,
            Some(json!({"pjp-x": "on"}).as_object().unwrap().clone())
        );
        for (text, why) in [
            ("{", "JSON として読めない"),
            ("[]", "object でない"),
            (
                "{\"skillOverrides\": {}, \"hooks\": {}}",
                "知らないキー: hooks",
            ),
            ("{}", "skillOverrides が無い"),
            (
                "{\"skillOverrides\": []}",
                "skillOverrides が object でない",
            ),
            (
                "{\"skillOverrides\": {\"pjp-x\": true}}",
                "skillOverrides.pjp-x が文字列でない",
            ),
        ] {
            std::fs::write(&p, text).unwrap();
            let e = read_overlay(&p).unwrap_err();
            assert_eq!(e.code(), pjp_core::exit::CONFIG, "{text}");
            assert!(e.message().contains(&p.display().to_string()), "{e}");
            assert!(e.message().contains(why), "{text}: {e}");
        }
    }

    #[test]
    fn same_as_ignores_crlf_only() {
        let t = file(&ctx(None), "CLAUDE.md");
        let crlf = t.content().replace('\n', "\r\n");
        assert!(t.same_as(crlf.as_bytes()));
        assert!(!t.same_as(b"# other\n"));
        assert_eq!(lf(b"a\r\nb\rc\r\n"), b"a\nb\rc\n");
    }

    #[test]
    fn path_in_uses_os_separators() {
        let hub = Path::new("hub");
        assert_eq!(
            file(&ctx(None), "settings.json").path_in(hub),
            hub.join(".claude").join("settings.json")
        );
    }

    #[test]
    fn hook_command_is_shell_neutral() {
        // PowerShell でも Git Bash でも同じに読める形 (~・$・引用符・; を使わない)
        let v: Value = serde_json::from_str(file(&ctx(None), "settings.json").content()).unwrap();
        let cmd = v["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        assert_eq!(cmd, "pjp hub guard");
        assert!(
            cmd.chars()
                .all(|c| c.is_ascii_alphanumeric() || c == ' ' || c == '-')
        );
        assert_eq!(
            v["hooks"]["PreToolUse"][0]["matcher"],
            "Write|Edit|MultiEdit|NotebookEdit"
        );
    }

    /// 答え待ちの印を外す hook。どう落ちても発言を止めず、ターンの終わりで回り続けないよう、`; exit 0` でいつも 0 で終える
    /// (shell を通さない args の形にはしない)。
    #[test]
    fn asking_hooks_are_fail_open() {
        let v: Value = serde_json::from_str(file(&ctx(None), "settings.json").content()).unwrap();
        for (event, cmd) in [
            ("UserPromptSubmit", "pjp mark hook prompt; exit 0"),
            ("Stop", "pjp mark hook stop; exit 0"),
        ] {
            let groups = v["hooks"][event].as_array().unwrap();
            assert_eq!(groups.len(), 1, "{event}");
            assert!(groups[0].get("matcher").is_none(), "{event}");
            assert_eq!(
                groups[0]["hooks"],
                json!([{"type": "command", "command": cmd}]),
                "{event}"
            );
        }
    }
}
