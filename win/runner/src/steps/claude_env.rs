//! claude-env (order 50): Windows の Claude Code の `~/.claude/settings.json` の `env` に、Claude のセッションの git だけを commit・tag の
//! 署名なし・GitHub は gh の資格情報 (HTTPS) で通す設定 (`GIT_CONFIG_*`) と、plugin を HTTPS で取る印を足す。Linux の
//! `nix/scripts/bootstrap-claude-env.sh` (値は home/modules/claude.nix の gitConfigBase と lib/git-via-gh.nix) と同じ書き方:
//!
//! - 既にある `GIT_CONFIG_*` の組のうち、この手順が持つキーの組は外し、ほかの組は順を保って残し、その後ろにこの手順の組を足して 0 から番号を
//!   振り直す (番号に穴があると git はその手前までしか読まない)
//! - この手順が持つ名前 (`CLAUDE_CODE_PLUGIN_PREFER_HTTPS`・`GCM_INTERACTIVE`) は外してから足す
//! - settings.json のほかのキーと順は残す (順を保つ JSON の型 `ojson`)。キーの順を見ずに同じなら書かない。書く前に前の中身を
//!   `%LOCALAPPDATA%\dotfiles\state\claude-settings\backup\` に写す (10 回分)
//!
//! Windows だけの違い: Git for Windows は system の設定に Git Credential Manager (`credential.helper = manager`) を持ち、env で足す gh の helper
//! より先に呼ばれる。GCM が窓を出して止まらないよう `GCM_INTERACTIVE=never` も足す (GCM は窓を出さずに抜け、git は次の gh に進む)。空の値で
//! helper の並びを消す組は足さない (Windows では空の値の env が消えやすく、`GIT_CONFIG_VALUE_<n>` が欠けると git が全部落ちる)。
//! 経緯は dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*。

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::ojson::OValue;
use crate::process::CommandSpec;
use crate::report::Kind;
use std::path::Path;
use std::time::Duration;

/// Claude のセッションの git に足す設定 (git の `-c <キー>=<値>` の組。並びもこのまま)。Linux の home/modules/claude.nix の gitConfigBase
/// (commit・tag を無署名に) と nix/lib/git-via-gh.nix (GitHub の ssh の URL を https に読み替え、資格情報を gh から取る) を写したもの
pub const GIT_CONFIG: &[(&str, &str)] = &[
    ("commit.gpgsign", "false"),
    ("tag.gpgsign", "false"),
    ("url.https://github.com/.insteadOf", "git@github.com:"),
    ("url.https://github.com/.insteadOf", "ssh://git@github.com/"),
    (
        "credential.https://github.com.helper",
        "!gh auth git-credential",
    ),
];

/// env に足す名前と値 (この手順が持つ名前)。CLAUDE_CODE_PLUGIN_PREFER_HTTPS は Linux と同じ (plugin の取得の前の ssh -T を飛ばす)。
/// GCM_INTERACTIVE は Windows だけ (Git Credential Manager に窓を出させない)
pub const VARS: &[(&str, &str)] = &[
    ("CLAUDE_CODE_PLUGIN_PREFER_HTTPS", "1"),
    ("GCM_INTERACTIVE", "never"),
];

/// 書く前の settings.json を写す数
const BACKUPS: usize = 10;

pub struct ClaudeEnv;

impl Step for ClaudeEnv {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-env",
            order: 50,
            title: "Claude Code の settings.json の env に、Claude の git を無署名・GitHub は gh の資格情報 (HTTPS) で通す設定を足す",
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let path = ctx.roots.user_profile.join(".claude").join("settings.json");
        let shown = path.display().to_string();
        let notes = notes(ctx);
        let (before, exists) = match std::fs::read_to_string(&path) {
            Ok(text) => match OValue::parse(&text) {
                Ok(v) => (v, true),
                Err(e) => {
                    ctx.say(format!("!! {shown} が JSON として壊れています ({e})"));
                    return vec![failed(
                        format!("{shown} が JSON として壊れている → 手で直す ({e})"),
                        notes,
                    )];
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                (OValue::Object(Vec::new()), false)
            }
            Err(e) => return vec![failed(format!("{shown} が読めない ({e})"), notes)],
        };
        let after = match with_env(&before) {
            Ok(v) => v,
            Err(why) => {
                ctx.say(format!("!! {shown}: {why}"));
                return vec![failed(format!("{shown}: {why} → 手で直す"), notes)];
            }
        };
        if exists && before.to_value() == after.to_value() {
            ctx.say(format!("登録済みです: {shown} の env"));
            return vec![with_notes(
                Outcome::new(Kind::Ok, "settings.json の env は登録済み"),
                notes,
            )];
        }
        let kind = if exists { Kind::Fix } else { Kind::Missing };
        let o = match mode {
            Mode::Check => {
                ctx.say(format!("env に足す (apply で): {shown}"));
                Outcome::new(
                    kind,
                    "settings.json の env に git の設定が無い・違う → apply で足す",
                )
            }
            Mode::DryRun { .. } => {
                ctx.say(format!("[dry-run] env に足す: {shown}"));
                Outcome::new(kind, "[dry-run] settings.json の env に git の設定を足す")
            }
            Mode::Apply { .. } => {
                if exists && let Err(e) = backup(ctx, &path) {
                    return vec![failed(
                        format!("{shown} を控えに写せないので書かない ({e})"),
                        notes,
                    )];
                }
                match fsutil::write_atomic(&path, after.to_pretty().as_bytes()) {
                    Ok(()) => {
                        ctx.say(format!("登録しました: {shown} の env (commit・tag を無署名にし、GitHub へは gh の資格情報 (HTTPS) で通す)"));
                        ctx.say("git の設定は実行中の Claude Code の会話にも入る。入らなければ Claude Code を起動し直す");
                        Outcome::new(Kind::Ok, "settings.json の env に git の設定を足した")
                    }
                    Err(e) => failed(format!("{shown} を書けない ({e})"), Vec::new()),
                }
            }
        };
        vec![with_notes(o, notes)]
    }
}

fn failed(text: String, notes: Vec<String>) -> Outcome {
    with_notes(Outcome::new(Kind::Failed, text), notes)
}

fn with_notes(mut o: Outcome, notes: Vec<String>) -> Outcome {
    o.notes.extend(notes);
    o
}

/// `GIT_CONFIG_COUNT`・`GIT_CONFIG_KEY_<n>`・`GIT_CONFIG_VALUE_<n>` の名前か。
fn is_git_config_name(name: &str) -> bool {
    let numbered = |prefix: &str| {
        name.strip_prefix(prefix)
            .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
    };
    name == "GIT_CONFIG_COUNT" || numbered("GIT_CONFIG_KEY_") || numbered("GIT_CONFIG_VALUE_")
}

/// settings.json に、この手順の env を入れたもの (ほかのキーと順は残す)。
fn with_env(settings: &OValue) -> Result<OValue, String> {
    let OValue::Object(_) = settings else {
        return Err("object でない (中身が {…} でない)".to_string());
    };
    let env = match settings.get("env") {
        None => OValue::Object(Vec::new()),
        Some(v @ OValue::Object(_)) => v.clone(),
        Some(_) => return Err("env が object でない".to_string()),
    };
    let OValue::Object(entries) = &env else {
        unreachable!("上で object だけを通した")
    };
    let count = match env.get("GIT_CONFIG_COUNT") {
        None => 0,
        Some(OValue::String(s)) => s
            .trim()
            .parse::<usize>()
            .map_err(|_| format!("env の GIT_CONFIG_COUNT が数でない ({s})"))?,
        Some(OValue::Number(n)) => n
            .as_u64()
            .map(|n| n as usize)
            .ok_or_else(|| format!("env の GIT_CONFIG_COUNT が数でない ({n})"))?,
        Some(other) => return Err(format!("env の GIT_CONFIG_COUNT が数でない ({other:?})")),
    };
    let ours: Vec<&str> = GIT_CONFIG.iter().map(|(k, _)| *k).collect();
    // 今の組のうち、この手順のキーでないものを順に残す (キーの無い番号は飛ばす。jq の select(.k != null) と同じ)
    let mut all: Vec<(OValue, OValue)> = (0..count)
        .filter_map(|i| {
            let key = env.get(&format!("GIT_CONFIG_KEY_{i}"))?.clone();
            let value = env
                .get(&format!("GIT_CONFIG_VALUE_{i}"))
                .cloned()
                .unwrap_or(OValue::Null);
            Some((key, value))
        })
        .filter(|(k, _)| !matches!(k, OValue::String(s) if ours.contains(&s.as_str())))
        .collect();
    all.extend(
        GIT_CONFIG
            .iter()
            .map(|(k, v)| (OValue::String(k.to_string()), OValue::String(v.to_string()))),
    );
    let names: Vec<&str> = VARS.iter().map(|(k, _)| *k).collect();
    let mut out: Vec<(String, OValue)> = entries
        .iter()
        .filter(|(k, _)| !is_git_config_name(k) && !names.contains(&k.as_str()))
        .cloned()
        .collect();
    out.push((
        "GIT_CONFIG_COUNT".to_string(),
        OValue::String(all.len().to_string()),
    ));
    for (i, (k, v)) in all.into_iter().enumerate() {
        out.push((format!("GIT_CONFIG_KEY_{i}"), k));
        out.push((format!("GIT_CONFIG_VALUE_{i}"), v));
    }
    for (k, v) in VARS {
        out.push((k.to_string(), OValue::String(v.to_string())));
    }
    let mut result = settings.clone();
    result.set("env", OValue::Object(out));
    Ok(result)
}

/// 書く前の settings.json を `<state_dir>\claude-settings\backup\settings-<秒>-<ナノ秒>.json` に写し、新しい方から 10 個だけ残す。
fn backup(ctx: &mut Ctx, path: &Path) -> std::io::Result<()> {
    let dir = ctx.state_dir.join("claude-settings").join("backup");
    std::fs::create_dir_all(&dir)?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let mut name = format!(
        "settings-{:012}-{:09}.json",
        now.as_secs(),
        now.subsec_nanos()
    );
    // 同じ時刻の写しを上書きしない
    let mut n = 0;
    while dir.join(&name).exists() {
        n += 1;
        name = format!(
            "settings-{:012}-{:09}-{n}.json",
            now.as_secs(),
            now.subsec_nanos()
        );
    }
    std::fs::copy(path, dir.join(&name))?;
    let mut olds: Vec<String> = std::fs::read_dir(&dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("settings-") && n.ends_with(".json"))
        .collect();
    olds.sort();
    while olds.len() > BACKUPS {
        let old = olds.remove(0);
        let _ = std::fs::remove_file(dir.join(old));
    }
    ctx.say(format!(
        "前の中身を写しました: {}",
        dir.join(&name).display()
    ));
    Ok(())
}

/// 書いても効かないかもしれないわけ (※ で知らせる。env は書く): gh が無い・ログインしていない、git の設定ファイルにほかの credential helper
/// がある (Linux の bootstrap-claude-env.sh と同じ見方)。
fn notes(ctx: &mut Ctx) -> Vec<String> {
    let mut notes = Vec::new();
    match ctx.sys.which("gh") {
        None => notes.push(
            "gh が見つからない。Claude の git は gh の資格情報で GitHub へ HTTPS で通す (gh は bootstrap が入れる)".to_string(),
        ),
        Some(gh) => {
            let spec = CommandSpec::new(gh)
                .arg("auth")
                .arg("status")
                .arg("--hostname")
                .arg("github.com")
                .timeout(Duration::from_secs(30));
            // 出力は見ない (token は伏せて出るが、写しを持たない)
            if ctx.sys.run(&spec, &mut |_| {}).code() != Some(0) {
                notes.push(
                    "gh が github.com にログインしていない → gh auth login (Claude の git は gh の資格情報で GitHub へ HTTPS で通す)"
                        .to_string(),
                );
            }
        }
    }
    if let Some(git) = ctx.sys.which("git") {
        let spec = CommandSpec::new(git)
            .arg("config")
            .arg("--show-scope")
            .arg("--get-regexp")
            .arg(r"^credential\..*helper$")
            .timeout(Duration::from_secs(30));
        let r = ctx.sys.run(&spec, &mut |_| {});
        // env (command の scope) は Claude の会話の中から流したときの自分の組。空の値の reset と gh 自身は害が無い
        let others: Vec<String> = r
            .output
            .iter()
            .filter_map(|l| {
                let (scope, rest) = l.split_once('\t')?;
                let (_, value) = rest.split_once(' ').unwrap_or((rest, ""));
                (scope != "command"
                    && !value.trim().is_empty()
                    && !value.contains("gh auth git-credential"))
                .then(|| format!("{scope} {}", rest.trim_end()))
            })
            .collect();
        if !others.is_empty() {
            notes.push(format!(
                "git の設定ファイルに credential helper がある ({})。Claude の git では gh より先に呼ばれ、gh で通った token がそちらにも保存される (Git Credential Manager なら GCM_INTERACTIVE=never で窓は出さない)",
                others.join("・")
            ));
        }
    }
    notes
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - settings.json が無ければ作る (check と dry-run は書かない)。env に 5 組と 2 つの名前が入り、2 回目は揃っている
    //! - ほかのキーと順・ユーザーの env の名前は残り、関係の無い GIT_CONFIG の組は前に残って番号が振り直され、この手順のキーの古い組は外れる。
    //!   書く前の中身を控えに写す
    //! - 壊れた JSON・object でない env・数でない GIT_CONFIG_COUNT は failed (書かない)
    //! - gh が無い・ログインしていない、git の設定ファイルにほかの credential helper があるときは ※ で知らせる (env は書く)
    //! - 組の値は Linux の nix/lib/git-via-gh.nix と同じ (Linux の CI で nix-instantiate と突き合わせる)

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::ojson::OValue;
    use crate::process::{Exit, RunResult};
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::{Path, PathBuf};

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            Env {
                t: TempDir::new("claude-env"),
            }
        }

        fn settings(&self) -> PathBuf {
            self.t
                .path()
                .join("home")
                .join(".claude")
                .join("settings.json")
        }

        fn backups(&self) -> Vec<String> {
            let dir = self
                .t
                .path()
                .join("state")
                .join("claude-settings")
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

        fn run_with(&self, sys: &FakeSys, mode: Mode) -> Outcome {
            let mut out = Vec::new();
            let mut ctx = Ctx {
                repo: self.t.path().join("dotfiles"),
                roots: Roots::from_home(&self.t.path().join("home")),
                state_dir: self.t.path().join("state"),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys,
                out: &mut out,
            };
            ClaudeEnv.run(&mut ctx, mode).remove(0)
        }

        /// gh があってログインしている・git の設定ファイルに helper が無い偽物
        fn run(&self, mode: Mode) -> Outcome {
            let sys = FakeSys::new(|_| RunResult {
                exit: Exit::Code(0),
                output: vec![],
            })
            .with_program("gh", "gh")
            .with_program("git", "git");
            self.run_with(&sys, mode)
        }
    }

    fn env_of(path: &Path) -> Vec<(String, String)> {
        let v = OValue::parse(&std::fs::read_to_string(path).unwrap()).unwrap();
        match v.get("env") {
            Some(OValue::Object(entries)) => entries
                .iter()
                .map(|(k, v)| match v {
                    OValue::String(s) => (k.clone(), s.clone()),
                    other => (k.clone(), format!("{other:?}")),
                })
                .collect(),
            other => panic!("env が object でない: {other:?}"),
        }
    }

    fn pairs(entries: &[(&str, &str)]) -> Vec<(String, String)> {
        entries
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    const OURS: [(&str, &str); 13] = [
        ("GIT_CONFIG_COUNT", "5"),
        ("GIT_CONFIG_KEY_0", "commit.gpgsign"),
        ("GIT_CONFIG_VALUE_0", "false"),
        ("GIT_CONFIG_KEY_1", "tag.gpgsign"),
        ("GIT_CONFIG_VALUE_1", "false"),
        ("GIT_CONFIG_KEY_2", "url.https://github.com/.insteadOf"),
        ("GIT_CONFIG_VALUE_2", "git@github.com:"),
        ("GIT_CONFIG_KEY_3", "url.https://github.com/.insteadOf"),
        ("GIT_CONFIG_VALUE_3", "ssh://git@github.com/"),
        ("GIT_CONFIG_KEY_4", "credential.https://github.com.helper"),
        ("GIT_CONFIG_VALUE_4", "!gh auth git-credential"),
        ("CLAUDE_CODE_PLUGIN_PREFER_HTTPS", "1"),
        ("GCM_INTERACTIVE", "never"),
    ];

    #[test]
    fn creates_settings_when_missing() {
        let e = Env::new();
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let o = e.run(mode);
            assert_eq!(o.kind, Kind::Missing, "{mode:?} {o:?}");
            assert!(!e.settings().exists());
        }
        let o = e.run(Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert_eq!(env_of(&e.settings()), pairs(&OURS));
        assert!(e.backups().is_empty());
        let o = e.run(Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(o.text.contains("登録済み"), "{o:?}");
    }

    #[test]
    fn keeps_user_keys_and_renumbers() {
        let e = Env::new();
        e.t.write(
            "home/.claude/settings.json",
            "{\n  \"skipDangerousModePermissionPrompt\": true,\n  \"env\": {\n    \"FOO\": \"1\",\n    \"GIT_CONFIG_COUNT\": \"2\",\n    \"GIT_CONFIG_KEY_0\": \"core.autocrlf\",\n    \"GIT_CONFIG_VALUE_0\": \"false\",\n    \"GIT_CONFIG_KEY_1\": \"commit.gpgsign\",\n    \"GIT_CONFIG_VALUE_1\": \"true\",\n    \"GCM_INTERACTIVE\": \"auto\"\n  },\n  \"theme\": \"dark\"\n}\n",
        );
        let o = e.run(Mode::Check);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        let o = e.run(Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        let text = std::fs::read_to_string(e.settings()).unwrap();
        let skip = text.find("skipDangerousModePermissionPrompt").unwrap();
        let env = text.find("\"env\"").unwrap();
        let theme = text.find("\"theme\"").unwrap();
        assert!(skip < env && env < theme, "{text}");
        let mut want = pairs(&[
            ("FOO", "1"),
            ("GIT_CONFIG_COUNT", "6"),
            ("GIT_CONFIG_KEY_0", "core.autocrlf"),
            ("GIT_CONFIG_VALUE_0", "false"),
        ]);
        for (i, (k, v)) in GIT_CONFIG.iter().enumerate() {
            want.push((format!("GIT_CONFIG_KEY_{}", i + 1), k.to_string()));
            want.push((format!("GIT_CONFIG_VALUE_{}", i + 1), v.to_string()));
        }
        want.extend(pairs(&[
            ("CLAUDE_CODE_PLUGIN_PREFER_HTTPS", "1"),
            ("GCM_INTERACTIVE", "never"),
        ]));
        assert_eq!(env_of(&e.settings()), want);
        let backups = e.backups();
        assert_eq!(backups.len(), 1, "{backups:?}");
        assert!(backups[0].starts_with("settings-") && backups[0].ends_with(".json"));
        assert_eq!(e.run(Mode::Check).kind, Kind::Ok);
    }

    #[test]
    fn keeps_ten_backups() {
        let e = Env::new();
        for i in 0..12 {
            e.t.write("home/.claude/settings.json", &format!("{{\"n\": {i}}}\n"));
            assert_eq!(e.run(Mode::Apply { force: false }).kind, Kind::Ok);
        }
        assert_eq!(e.backups().len(), 10);
    }

    #[test]
    fn broken_settings_fail_without_writing() {
        for (text, want) in [
            ("{\"env\": ", "壊れて"),
            ("[1]", "object でない"),
            ("{\"env\": [1]}", "env が object でない"),
            (
                "{\"env\": {\"GIT_CONFIG_COUNT\": \"x\"}}",
                "GIT_CONFIG_COUNT",
            ),
        ] {
            let e = Env::new();
            e.t.write("home/.claude/settings.json", text);
            let o = e.run(Mode::Apply { force: false });
            assert_eq!(o.kind, Kind::Failed, "{text}: {o:?}");
            assert!(o.text.contains(want), "{text}: {o:?}");
            assert_eq!(std::fs::read_to_string(e.settings()).unwrap(), text);
        }
    }

    #[test]
    fn notes_gh_and_other_helpers() {
        let e = Env::new();
        // gh が無い
        let sys = FakeSys::new(|_| unreachable!());
        let o = e.run_with(&sys, Mode::Check);
        assert!(
            o.notes.iter().any(|n| n.contains("gh が見つからない")),
            "{o:?}"
        );
        // gh がログインしていない・system に Git Credential Manager
        let sys = FakeSys::new(|c| {
            let args = c.args_lossy();
            if args.first().map(String::as_str) == Some("auth") {
                RunResult {
                    exit: Exit::Code(1),
                    output: vec![],
                }
            } else {
                assert_eq!(
                    args,
                    vec![
                        "config",
                        "--show-scope",
                        "--get-regexp",
                        "^credential\\..*helper$"
                    ]
                );
                RunResult {
                    exit: Exit::Code(0),
                    output: vec![
                        "system\tcredential.helper manager".to_string(),
                        "command\tcredential.https://github.com.helper !gh auth git-credential"
                            .to_string(),
                        "global\tcredential.helper ".to_string(),
                    ],
                }
            }
        })
        .with_program("gh", "gh")
        .with_program("git", "git");
        let o = e.run_with(&sys, Mode::Apply { force: false });
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("gh が github.com にログインしていない")),
            "{o:?}"
        );
        let helper = o
            .notes
            .iter()
            .find(|n| n.contains("credential helper"))
            .unwrap_or_else(|| panic!("{o:?}"));
        assert!(
            helper.contains("system credential.helper manager"),
            "{helper}"
        );
        assert!(!helper.contains("command"), "{helper}");
        assert!(!helper.contains("global"), "{helper}");
    }
}
