//! claude-t3 (order 50): T3 Code (Windows の desktop app) の会話だけに効かせる Claude の設定のファイルを、dotfiles の `win/claude-code/t3/` から
//! `%USERPROFILE%\.claude\t3\` へ記録つきのコピーで置く。T3 Code は Windows で使うので、WSL の setup に同じ手順は無い (Windows にしか無い手順)。
//!
//! | 置くもの | 中身 | T3 の Launch arguments |
//! | --- | --- | --- |
//! | `settings.json` | T3 の会話で一覧から外す skill (herdr と hc の子のもの) と出す skill (`pjp-t3-hub`) の `skillOverrides` | `--settings <パス>` (flag settings。user の settings.json より強い) |
//! | `CLAUDE.t3.md` | T3 の会話の決まり (herdr-app を前提にした指示の読み替え) | `--append-system-prompt-file <パス>` (T3 の指示の後ろに足す) |
//!
//! - T3 の Claude の設定のディレクトリ (claude-account の `~/.claude-t3`) は、中身を `~/.claude` へのリンクのまま herdr-app と共有する。T3 だけの
//!   違いは、この 2 つを T3 の Settings → Providers → Claude → Launch arguments で渡す。Launch arguments はユーザーが書く (runner は T3 の設定を
//!   書かない)。書く文 (置き先の絶対パス) はこの手順が出す
//! - 置き方は herdr-app-mods と同じ記録つきのコピー (`linker`): 無い → コピー・同じ → 記録だけ (手で置いた同じ中身も引き取る)・記録どおり →
//!   上書き・ほか → 衝突 (`--force` で上書き)。改行は LF にそろえて置く (clone の取り出し方によらず同じバイト列。claude-files の CLAUDE.md と同じ)。
//!   `.json` は JSON の object と読めなければ置かない (T3 は `--settings` のファイルが読めないと、メッセージの送信が失敗する)
//! - `FILES` から外したファイルは、中身が記録どおりなら消す。置き先の `~/.claude/t3` がリンク (手でつないだ場所) なら触らない
//!
//! 記録は `%LOCALAPPDATA%\dotfiles\state\claude-t3.deployed.json`。T3 は `--settings` のファイルを見張らないので、置き直したら T3 の会話を開き直す
//! (dotfiles-private の docs/adr/090_win_claude_t3_launch_args_*)。

use super::linker::{Linker, Source};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::link::{is_link, same_path};
use crate::record::Records;
use crate::report::Kind;
use std::path::{Path, PathBuf};

/// repo の置き場 (`/` 区切り)
pub const SOURCE: &str = "win/claude-code/t3";
/// `--settings` に渡すファイル
pub const SETTINGS: &str = "settings.json";
/// `--append-system-prompt-file` に渡すファイル
pub const PROMPT: &str = "CLAUDE.t3.md";
/// 置くファイル (`SOURCE` の中の名前。置き先は `~/.claude/t3/` の同じ名前)。T3 の Launch arguments が置き先のパスで指すので、名前を変えたら
/// Launch arguments も書き直す
pub const FILES: [&str; 2] = [SETTINGS, PROMPT];
/// コピーの記録 (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "claude-t3.deployed.json";

pub struct ClaudeT3;

impl Step for ClaudeT3 {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-t3",
            // ~/.claude のファイルを置く claude-files と並べる (ほかの手順の後でなくてよい)
            order: 50,
            title: "T3 Code の会話だけの Claude の設定 (win/claude-code/t3/ の settings.json・CLAUDE.t3.md) を ~/.claude/t3/ へ置く",
            // ほかの Claude Code の設定の手順と同じ switch
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let root = ctx.repo_path(SOURCE);
        let dir = t3_dir(ctx);
        ctx.say(format!("dotfiles: {}", root.display()));
        ctx.say(format!("置き先: {}", dir.display()));
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let records = match Records::load(&record_path) {
            Ok(r) => r,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![
                    Outcome::new(Kind::Failed, "claude-t3 のコピーの記録が壊れている").note(e),
                ];
            }
        };
        let src = Source {
            root: root.clone(),
            prev: None,
            foreign_suffix: None,
            kinds: &[],
            skip_skills: Vec::new(),
            select: None,
            origin: "clone",
            absorb: "dotfiles の win/claude-code/t3",
            step: "claude-t3",
        };
        let mut w = Linker::new(src, dir.clone(), mode, records);
        if is_link(&dir) {
            w.skip(
                ctx,
                "t3 (置き先がリンク。手でつないだ場所なので触らない)".to_string(),
            );
            return w.finish(ctx, &record_path, None);
        }
        for name in FILES {
            let label = format!("t3/{name}");
            match read_source(&root, name) {
                Ok(bytes) => w.copy_bytes(ctx, &bytes, &dir.join(name), &label),
                Err(why) => w.fail(ctx, format!("{label} を置かない: {why}")),
            }
        }
        prune(ctx, &mut w, &dir);
        ctx.say("");
        ctx.say(
            "T3 の Settings → Providers → Claude → Launch arguments に書く文 (ファイルを置いてから書く。書いた後と、置き直した後は T3 の会話を開き直す):",
        );
        ctx.say(format!("  {}", launch_args(&dir)));
        w.finish(ctx, &record_path, None)
    }
}

/// 置き先 (`%USERPROFILE%\.claude\t3`)
pub fn t3_dir(ctx: &Ctx) -> PathBuf {
    ctx.roots.user_profile.join(".claude").join("t3")
}

/// T3 の Launch arguments に書く文 (置き先の絶対パス)。空白を含むパスは `"` で囲む (T3 は Launch arguments を shell のように区切り、`"` の中の
/// 空白を区切りにしない。引用符の外の `\` は、空白と引用符の前でなければ字のまま読む)。
pub fn launch_args(dir: &Path) -> String {
    let arg = |name: &str| {
        let p = dir.join(name).to_string_lossy().into_owned();
        if p.chars().any(char::is_whitespace) {
            format!("\"{p}\"")
        } else {
            p
        }
    };
    format!(
        "--settings {} --append-system-prompt-file {}",
        arg(SETTINGS),
        arg(PROMPT)
    )
}

/// repo のファイルの中身 (改行を LF にそろえる)。`.json` は JSON の object と読めなければ Err (置かない)。
fn read_source(root: &Path, name: &str) -> Result<Vec<u8>, String> {
    let p = root.join(name);
    let text = std::fs::read_to_string(&p)
        .map_err(|e| format!("コピー元 {} が読めない ({e})", p.display()))?
        .replace("\r\n", "\n");
    if name.ends_with(".json") {
        match serde_json::from_str::<serde_json::Value>(&text) {
            Ok(v) if v.is_object() => {}
            Ok(_) => {
                return Err(format!(
                    "{} が JSON の object でない → repo のファイルを直す",
                    p.display()
                ));
            }
            Err(e) => {
                return Err(format!(
                    "{} が JSON として読めない ({e}) → repo のファイルを直す",
                    p.display()
                ));
            }
        }
    }
    Ok(text.into_bytes())
}

/// 記録にあるコピーのうち、置き先の直下にあって今は置かないもの (`FILES` から外したファイル) を消す。中身が記録どおりでなければ残して知らせる
/// (記録からは外す)。置き先の外の記録はそのまま残す。
fn prune(ctx: &mut Ctx, w: &mut Linker, dir: &Path) {
    for key in w.records.keys() {
        let dest = PathBuf::from(&key);
        let (Some(parent), Some(name)) = (dest.parent(), dest.file_name()) else {
            continue;
        };
        if !same_path(parent, dir) || FILES.iter().any(|f| same_path(&dir.join(f), &dest)) {
            continue;
        }
        let label = format!("t3/{}", name.to_string_lossy());
        if !dest.exists() || is_link(&dest) {
            if w.mode.writes() {
                w.records.remove(&key);
            }
            continue;
        }
        let recorded = w.records.get(&key).map(str::to_string);
        match fsutil::sha256_file(&dest) {
            Ok(have) if recorded.as_deref() == Some(have.as_str()) => {
                match w.mode {
                    Mode::Check => {
                        ctx.say(format!("消す (apply で): {label} (置くファイルから外れた)"))
                    }
                    Mode::DryRun { .. } => ctx.say(format!("[dry-run] 消す: {label}")),
                    Mode::Apply { .. } => {
                        if let Err(e) = std::fs::remove_file(&dest) {
                            w.fail(ctx, format!("{label} を消せない ({e})"));
                            continue;
                        }
                        w.records.remove(&key);
                        ctx.say(format!("消しました: {label} (置くファイルから外れた)"));
                    }
                }
                w.tally.removed += 1;
            }
            Ok(_) => {
                w.skip(
                    ctx,
                    format!(
                        "{label} (置くファイルから外れたが、Windows 側で変わっているので消さない。要らなければ手で消す)"
                    ),
                );
                if w.mode.writes() {
                    w.records.remove(&key);
                }
            }
            Err(e) => w.fail(ctx, format!("{label} が読めない ({e})")),
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 記録つきのコピー: 無い → missing (check と dry-run は書かない)・apply で置いて記録する・2 回目は ok。repo を変えると fix で上書きする
    //! - 改行は LF にそろえて置く (CRLF で取り出した clone でも同じバイト列)
    //! - 置き先で変えたもの・記録の無い違う中身は衝突 (manual。apply も書かない) で、--force で上書きする。手で置いた同じ中身は引き取る
    //! - repo のファイルが読めない・`.json` が JSON の object でないときは、そのファイルを置かない (failed。ほかのファイルは置く)
    //! - FILES から外したファイルは、中身が記録どおりなら消す (変えてあれば残して知らせる)。置き先の外の記録には触らない。置き先がリンクなら触らない
    //! - Launch arguments に書く文 (置き先の絶対パス。空白を含めば引用符で囲む) を出す
    //! - 本物の repo のファイル: 置き場にあるのは FILES だけで、どれも読め、settings.json は herdr と hc の子の skill を off・pjp-t3-hub を on に
    //!   する (hc は残す)。CLAUDE.t3.md は子を T3 のスレッドとして立てる向き

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir, fake_mklink};

    const SETTINGS_JSON: &str = "{\n  \"skillOverrides\": {\n    \"pjp-t3-hub\": \"on\"\n  }\n}\n";
    const PROMPT_MD: &str = "# T3 Code の会話\n\n- 読み替える\n";

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("claude-t3");
            t.write("dotfiles/win/claude-code/t3/settings.json", SETTINGS_JSON);
            t.write("dotfiles/win/claude-code/t3/CLAUDE.t3.md", PROMPT_MD);
            Env { t }
        }

        /// 置き先 (`<home>/.claude/t3`)
        fn dir(&self) -> PathBuf {
            self.t.path().join("home").join(".claude").join("t3")
        }

        /// 置き先の下のパス
        fn dest(&self, name: &str) -> PathBuf {
            self.dir().join(name)
        }

        fn read(&self, name: &str) -> String {
            std::fs::read_to_string(self.dest(name)).unwrap()
        }

        fn record_path(&self) -> PathBuf {
            self.t.path().join("state").join(RECORD_FILE)
        }

        fn record(&self) -> serde_json::Map<String, serde_json::Value> {
            let text = std::fs::read_to_string(self.record_path()).unwrap();
            match serde_json::from_str(&text).unwrap() {
                serde_json::Value::Object(m) => m,
                other => panic!("{other:?}"),
            }
        }

        fn run(&self, mode: Mode) -> (Vec<Outcome>, String) {
            let sys = FakeSys::new(|_| unreachable!("コマンドは打たない"));
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys: &sys,
                    out: &mut out,
                };
                ClaudeT3.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }
    }

    fn kinds(o: &[Outcome]) -> Vec<Kind> {
        o.iter().map(|x| x.kind).collect()
    }

    const APPLY: Mode = Mode::Apply { force: false };

    #[test]
    fn places_and_records() {
        let e = Env::new();
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (o, out) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Missing], "{mode:?} {o:?}\n{out}");
            assert!(!e.dir().exists(), "{mode:?} は書かない");
            assert!(!e.record_path().exists(), "{mode:?} は記録を書かない");
        }
        let (_, out) = e.run(Mode::Check);
        assert!(
            out.contains("コピーする (apply で): t3/settings.json"),
            "{out}"
        );
        assert!(
            out.contains("コピーする (apply で): t3/CLAUDE.t3.md"),
            "{out}"
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("追加 2 / 更新 0 / 削除 0 / 同じ 0 / 飛ばした 0"),
            "{o:?}"
        );
        assert_eq!(e.read("settings.json"), SETTINGS_JSON);
        assert_eq!(e.read("CLAUDE.t3.md"), PROMPT_MD);
        let rec = e.record();
        assert_eq!(rec.len(), 2, "{rec:?}");
        assert_eq!(
            rec.get(&*e.dest("settings.json").to_string_lossy())
                .and_then(|v| v.as_str()),
            Some(fsutil::sha256_bytes(SETTINGS_JSON.as_bytes()).as_str())
        );
        // 2 回目は同じ (check も apply も)
        for mode in [Mode::Check, APPLY] {
            let (o, out) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Ok], "{mode:?} {o:?}\n{out}");
            assert!(
                o[0].text
                    .starts_with("追加 0 / 更新 0 / 削除 0 / 同じ 2 / 飛ばした 0"),
                "{mode:?} {o:?}"
            );
        }
        // repo を変えると (記録どおりの置き先なので) 上書きする
        e.t.write("dotfiles/win/claude-code/t3/CLAUDE.t3.md", "# v2\n");
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}");
        assert!(
            out.contains("上書きする (apply で): t3/CLAUDE.t3.md"),
            "{out}"
        );
        assert_eq!(e.read("CLAUDE.t3.md"), PROMPT_MD, "check は書かない");
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(o[0].text.starts_with("追加 0 / 更新 1 /"), "{o:?}");
        assert_eq!(e.read("CLAUDE.t3.md"), "# v2\n");
    }

    #[test]
    fn line_endings_become_lf() {
        let e = Env::new();
        e.t.write(
            "dotfiles/win/claude-code/t3/settings.json",
            &SETTINGS_JSON.replace('\n', "\r\n"),
        );
        e.t.write(
            "dotfiles/win/claude-code/t3/CLAUDE.t3.md",
            &PROMPT_MD.replace('\n', "\r\n"),
        );
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert_eq!(e.read("settings.json"), SETTINGS_JSON);
        assert_eq!(e.read("CLAUDE.t3.md"), PROMPT_MD);
        // LF で取り出した clone に戻しても同じ
        e.t.write("dotfiles/win/claude-code/t3/settings.json", SETTINGS_JSON);
        e.t.write("dotfiles/win/claude-code/t3/CLAUDE.t3.md", PROMPT_MD);
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(o[0].text.contains("同じ 2"), "{o:?}");
    }

    #[test]
    fn edited_files_conflict() {
        let e = Env::new();
        // 記録の無い違う中身 (手で置いた) は衝突。同じ中身は引き取る
        e.t.write("home/.claude/t3/CLAUDE.t3.md", "# 手で書いた\n");
        e.t.write("home/.claude/t3/settings.json", SETTINGS_JSON);
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}\n{out}");
        assert!(o[0].text.contains("同じ 1 / 飛ばした 1"), "{o:?}");
        assert!(
            o[1].notes.iter().any(|n| n
                .starts_with("t3/CLAUDE.t3.md (中身が違う。置いた記録が無い")
                && n.contains("dotfiles の win/claude-code/t3 へ取り込む")
                && n.contains("--steps claude-t3 --force")),
            "{o:?}"
        );
        assert_eq!(e.read("CLAUDE.t3.md"), "# 手で書いた\n", "apply も書かない");
        assert_eq!(e.record().len(), 1, "同じ中身は記録だけ作る");
        let (o, _) = e.run(Mode::Apply { force: true });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert_eq!(e.read("CLAUDE.t3.md"), PROMPT_MD);
        // 置いた後に Windows 側で変えたもの
        std::fs::write(e.dest("settings.json"), "{}\n").unwrap();
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("t3/settings.json (中身が違う。Windows 側で変わった")),
            "{o:?}"
        );
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert_eq!(e.read("settings.json"), "{}\n");
        let (o, _) = e.run(Mode::Apply { force: true });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert_eq!(e.read("settings.json"), SETTINGS_JSON);
    }

    #[test]
    fn broken_sources_are_not_placed() {
        for (bad, why) in [
            ("{ \"skillOverrides\": ", "JSON として読めない"),
            ("[]\n", "JSON の object でない"),
        ] {
            let e = Env::new();
            e.t.write("dotfiles/win/claude-code/t3/settings.json", bad);
            let (o, out) = e.run(APPLY);
            assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}\n{out}");
            assert!(o[0].text.contains("エラー 1"), "{o:?}");
            assert!(
                out.contains("!! t3/settings.json を置かない: ") && out.contains(why),
                "{out}"
            );
            assert!(!e.dest("settings.json").exists(), "置かない");
            assert_eq!(e.read("CLAUDE.t3.md"), PROMPT_MD, "ほかのファイルは置く");
        }
        let e = Env::new();
        std::fs::remove_file(e.t.path().join("dotfiles/win/claude-code/t3/CLAUDE.t3.md")).unwrap();
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}\n{out}");
        assert!(
            out.contains("!! t3/CLAUDE.t3.md を置かない: コピー元"),
            "{out}"
        );
    }

    #[test]
    fn removes_files_dropped_from_the_list() {
        let e = Env::new();
        e.run(APPLY);
        // 前に置いた old.md (今は FILES に無い) と、置き先の外の記録
        let old = e.t.write("home/.claude/t3/old.md", "old\n");
        let outside = e.t.write("home/.claude/other.md", "other\n");
        let mut r = Records::load(&e.record_path()).unwrap();
        r.set(&old.to_string_lossy(), &fsutil::sha256_bytes(b"old\n"));
        r.set(
            &outside.to_string_lossy(),
            &fsutil::sha256_bytes(b"other\n"),
        );
        r.save_if_changed().unwrap();
        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains("消す (apply で): t3/old.md (置くファイルから外れた)"),
            "{out}"
        );
        assert!(old.exists());
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 1 / 同じ 2"), "{o:?}");
        assert!(!old.exists());
        assert!(outside.exists(), "置き先の外には触らない");
        let rec = e.record();
        assert_eq!(rec.len(), 3, "{rec:?}");
        assert!(!rec.contains_key(&*old.to_string_lossy()));
        assert!(rec.contains_key(&*outside.to_string_lossy()));
        // 変えてあれば消さずに知らせ、記録から外す
        let kept = e.t.write("home/.claude/t3/kept.md", "kept (手で直した)\n");
        let mut r = Records::load(&e.record_path()).unwrap();
        r.set(&kept.to_string_lossy(), &fsutil::sha256_bytes(b"kept\n"));
        r.save_if_changed().unwrap();
        let (o, _) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes.iter().any(|n| n.starts_with(
                "t3/kept.md (置くファイルから外れたが、Windows 側で変わっているので消さない"
            )),
            "{o:?}"
        );
        assert!(kept.exists());
        assert!(!e.record().contains_key(&*kept.to_string_lossy()));
    }

    #[test]
    fn linked_folder_is_left_alone() {
        let e = Env::new();
        let elsewhere = e.t.path().join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::fs::create_dir_all(e.dir().parent().unwrap()).unwrap();
        let mk = FakeSys::new(|c| fake_mklink(c).unwrap());
        crate::link::create_junction(&mk, &e.dir(), &elsewhere).unwrap();
        let (o, out) = e.run(APPLY);
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}\n{out}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("t3 (置き先がリンク")),
            "{o:?}"
        );
        assert_eq!(std::fs::read_dir(&elsewhere).unwrap().count(), 0);
    }

    #[test]
    fn prints_launch_arguments() {
        let e = Env::new();
        let (_, out) = e.run(Mode::Check);
        assert!(out.contains("Launch arguments に書く文"), "{out}");
        assert!(
            out.contains(&format!("  {}\n", launch_args(&e.dir()))),
            "{out}"
        );
        let plain = Path::new("/home/a/.claude/t3");
        assert_eq!(
            launch_args(plain),
            format!(
                "--settings {} --append-system-prompt-file {}",
                plain.join("settings.json").display(),
                plain.join("CLAUDE.t3.md").display()
            )
        );
        let spaced = Path::new("/home/a b/.claude/t3");
        assert_eq!(
            launch_args(spaced),
            format!(
                "--settings \"{}\" --append-system-prompt-file \"{}\"",
                spaced.join("settings.json").display(),
                spaced.join("CLAUDE.t3.md").display()
            )
        );
    }

    /// 本物の repo の置き場: FILES だけがあり、settings.json は herdr と hc の子の skill を off・pjp-t3-hub を on にする (hc は T3 でも使うので
    /// 触らない)。CLAUDE.t3.md は、子を T3 のスレッドとして立てる (t3_thread_launch) 向きで書く
    #[test]
    fn real_repo_files() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let root = crate::context::join_segments(&repo, SOURCE);
        let mut names: Vec<String> = std::fs::read_dir(&root)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        let mut want: Vec<String> = FILES.iter().map(|s| s.to_string()).collect();
        want.sort();
        assert_eq!(names, want, "置き場には置くファイルだけを置く");
        for name in FILES {
            let bytes = read_source(&root, name).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert!(!bytes.is_empty(), "{name} が空");
        }
        let v: serde_json::Value =
            serde_json::from_slice(&read_source(&root, SETTINGS).unwrap()).unwrap();
        let so = v["skillOverrides"]
            .as_object()
            .expect("skillOverrides がある");
        for off in [
            "herdr-app",
            "pjp-herdr-hub",
            "pjp-herdr-other-repo",
            "pjp-hc-hub",
            "pjp-hc-child",
        ] {
            assert_eq!(so.get(off).and_then(|x| x.as_str()), Some("off"), "{off}");
        }
        assert_eq!(so.get("pjp-t3-hub").and_then(|x| x.as_str()), Some("on"));
        assert!(so.get("hc").is_none(), "hc は T3 でも使う");
        let prompt = String::from_utf8(read_source(&root, PROMPT).unwrap()).unwrap();
        assert!(prompt.starts_with("# "), "{prompt}");
        for word in ["T3CODE_THREAD_ID", "t3_thread_launch", "pjp-t3-hub"] {
            assert!(prompt.contains(word), "{word} が無い");
        }
        assert!(
            !prompt.contains("<hc from"),
            "hc の受け口の札の話は書かない"
        );
    }

    #[test]
    fn step_info() {
        let i = ClaudeT3.info();
        assert_eq!(
            (i.id, i.order, i.gate),
            ("claude-t3", 50, Gate::Tool("windowsClaudeCode"))
        );
        assert!(i.ported && i.windows_only);
    }
}
