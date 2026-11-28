//! claude-files (order 50): dotfiles の Claude Code の設定のファイルを Windows の `%USERPROFILE%\.claude\` へ置く。Linux の
//! `nix/home/modules/claude.nix` (home-manager の `home.file`) に当たる。
//!
//! | 置くもの | 置き方 |
//! | --- | --- |
//! | `CLAUDE.md` | `win/claude-code/CLAUDE.windows.md` (Windows の冒頭) + 空行 + `nix/files/claude/CLAUDE.md` の最初の「## 」の行から後ろ (+ ホストの値の道具 `devTracker` が true なら、空行と `CLAUDE.dev-tracker.md`)。Linux の冒頭 (Nix 管理の話) を差し替える形は cloud の bootstrap-claude-cloud.sh と同じ。記録つきのコピー (Windows 側で変えたら衝突) |
//! | `skills/`・`agents/`・`commands/` | `nix/files/claude/<種類>/` の中身を 1 つずつ。ディレクトリは junction、ファイルは記録つきのコピー (claude-skills の手順と同じ `linker`)。`win/claude-code/skip-skills.txt` の skill は張らない。skill の依存の表 (`groups.json` の skills。ハブと子の土台の skill) の skill は、表の道具 (herdrHub) が off のホストには張らず (前に張ったものは外す)、claude-skills の片付けの PR までは claude-skills の写しに譲る (下) |
//! | `hooks\dotfiles-claude.exe` | この runner の exe の写し。hook と status line の口 (`claude-hook <名前>`・`claude-statusline`。中身は `crate::hooks`)。dotfiles が持つ生成物なので、違えば書き直す |
//!
//! 記録は `%LOCALAPPDATA%\dotfiles\state\claude-files.deployed.json`。clone を pull したら `dotfiles apply` で配り直す
//! (dotfiles-private の docs/adr/065_win_claude_config_*)。
//!
//! ハブと子の土台の skill (pjp-hc-hub など) は claude-skills から dotfiles に移した (dotfiles-private の ADR 124)。claude-skills の片付けの PR まで
//! claude-skills にも同じ名前の写しがあり、その間は claude-skills の写しを使う (dotfiles が譲る。Linux の bootstrap-claude-skills.sh と同じ考え):
//! claudePrivateSkills のホストで claude-skills の clone (claude-skills の手順と同じ決まり) に `skills/<名前>/SKILL.md` があるか、置き先が clone への
//! junction (先がある) なら張らない (clone への junction には触らずに知らせ、この手順の前の junction は外す。同じ order 50 で名前の順に後ろの
//! claude-skills の手順が clone へ張る)。clone に無ければ (片付けの PR の後・clone が無い) 張り、先の無い clone への junction (片付けの後の残り)
//! は張り替える。claudePrivateSkills が off なら (claude-skills の手順が流れない)、clone に同じ名前があっても張る。

use super::claude_settings::hook_exe;
use super::claude_skills::clone_dir;
use super::linker::{Linker, Source};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::fsutil;
use crate::link::{is_under, link_target};
use crate::record::Records;
use crate::report::Kind;
use std::path::Path;

/// つなぐ種類 (Linux の claude.nix の linkEntries と同じ)
pub const KINDS: [&str; 3] = ["skills", "agents", "commands"];
/// コピーの記録 (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "claude-files.deployed.json";
/// Windows の CLAUDE.md の冒頭
pub const WINDOWS_HEAD: &str = "win/claude-code/CLAUDE.windows.md";
/// Windows に張らない skill の一覧
pub const SKIP_SKILLS: &str = "win/claude-code/skip-skills.txt";
/// claude-skills の片付けの PR まで、同じ名前の土台の skill を claude-skills の写しに譲るわけ
const YIELD: &str = "claude-skills の写しを使う。claude-skills の片付けの PR まで";

pub struct ClaudeFiles;

impl Step for ClaudeFiles {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-files",
            order: 50,
            title: "dotfiles の CLAUDE.md・skill・agent・command と hook の口 (dotfiles-claude.exe) を ~/.claude/ へ置く",
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let root = ctx.repo_path("nix/files/claude");
        ctx.say(format!("dotfiles: {}", root.display()));
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let records = match Records::load(&record_path) {
            Ok(r) => r,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![
                    Outcome::new(Kind::Failed, "claude-files のコピーの記録が壊れている").note(e),
                ];
            }
        };
        let skip_skills = match std::fs::read_to_string(ctx.repo_path(SKIP_SKILLS)) {
            Ok(text) => names(&text),
            Err(e) => {
                let why = format!("{} が読めない ({e})", ctx.repo_path(SKIP_SKILLS).display());
                ctx.say(format!("!! {why}"));
                return vec![Outcome::new(Kind::Failed, why)];
            }
        };
        let claude = ctx.roots.user_profile.join(".claude");
        let src = Source {
            root: root.clone(),
            prev: None,
            foreign_suffix: Some("nix/files/claude"),
            kinds: &KINDS,
            skip_skills,
            select: None,
            origin: "clone",
            absorb: "dotfiles",
            step: "claude-files",
        };
        let mut w = Linker::new(src, claude.clone(), mode, records);
        plan_base_skills(ctx, &mut w, &root, &claude);
        match claude_md(ctx.repo.as_path(), ctx.host.tool("devTracker")) {
            Ok(bytes) => w.copy_bytes(ctx, &bytes, &claude.join("CLAUDE.md"), "CLAUDE.md"),
            Err(why) => w.fail(ctx, why),
        }
        w.run(ctx);
        let exe = sync_exe(ctx, mode);
        w.finish(ctx, &record_path, exe)
    }
}

/// skill の依存の表 (`groups.json` の skills) にある skill (ハブと子の土台) の張り方を `w` に渡す: 表の道具が off のホストでは張らない。
/// claude-skills の片付けの PR までは claude-skills の写しに譲る (claudePrivateSkills のホストで clone に `skills/<名前>/SKILL.md` がある・置き先が
/// clone への junction で先がある)。どちらでもなければ張り、先の無い clone への junction (片付けの PR の後の残り) は張り替える。
fn plan_base_skills(ctx: &Ctx, w: &mut Linker, root: &Path, claude: &Path) {
    let clone = clone_dir(ctx).join("skills");
    let private = ctx.host.tool("claudePrivateSkills");
    for name in ctx.host.table_skills() {
        if !root.join("skills").join(name).is_dir() {
            continue;
        }
        let off = ctx.host.skill_off_tools(name);
        if !off.is_empty() {
            w.hold(
                name,
                format!(
                    "このホストでは使わない。skill の依存の表の {} が off",
                    off.join("・")
                ),
            );
            continue;
        }
        let theirs = clone.join(name);
        let to_clone = link_target(&claude.join("skills").join(name))
            .is_some_and(|t| is_under(&t, &clone) && t.exists());
        if to_clone || (private && theirs.join("SKILL.md").is_file()) {
            w.hold(name, YIELD);
        } else {
            w.adopt_dangling(theirs);
        }
    }
}

/// 一覧のファイルの名前 (1 行 1 名前。「#」から行末と空行は読まない)。
fn names(text: &str) -> Vec<String> {
    text.lines()
        .map(|l| l.split('#').next().unwrap_or("").trim())
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

/// Windows の CLAUDE.md の中身。改行は LF にそろえる (clone の取り出し方によらず同じバイト列にし、記録の判定を揺らさない)。
pub fn claude_md(repo: &Path, dev_tracker: bool) -> Result<Vec<u8>, String> {
    let read = |rel: &str| -> Result<String, String> {
        let p = crate::context::join_segments(repo, rel);
        std::fs::read_to_string(&p)
            .map(|t| t.replace("\r\n", "\n"))
            .map_err(|e| format!("{} が読めない ({e})", p.display()))
    };
    let head = read(WINDOWS_HEAD)?;
    let common = read("nix/files/claude/CLAUDE.md")?;
    let at = if common.starts_with("## ") {
        Some(0)
    } else {
        common.find("\n## ").map(|i| i + 1)
    };
    let Some(at) = at else {
        return Err("nix/files/claude/CLAUDE.md に「## 」で始まる行が無い (その行より前を Windows の冒頭に差し替える)".to_string());
    };
    let mut out = head;
    if !out.ends_with('\n') {
        out.push('\n');
    }
    out.push('\n');
    out.push_str(&common[at..]);
    if !out.ends_with('\n') {
        out.push('\n');
    }
    if dev_tracker {
        out.push('\n');
        out.push_str(&read("nix/files/claude/CLAUDE.dev-tracker.md")?);
    }
    Ok(out.into_bytes())
}

/// hook の口 (`~/.claude/hooks/dotfiles-claude.exe`) をこの runner の exe に揃える。揃っていれば None、直すことがあればその種類。
fn sync_exe(ctx: &mut Ctx, mode: Mode) -> Option<Kind> {
    let dest = hook_exe(ctx);
    let shown = dest.display().to_string();
    let Some(src) = ctx.sys.current_exe() else {
        ctx.say("!! runner の exe の場所が分からない (hook の口を写せない)");
        return Some(Kind::Failed);
    };
    let bytes = match std::fs::read(&src) {
        Ok(b) => b,
        Err(e) => {
            ctx.say(format!(
                "!! runner の exe が読めない: {} ({e})",
                src.display()
            ));
            return Some(Kind::Failed);
        }
    };
    let state = match std::fs::read(&dest) {
        Ok(have) if fsutil::sha256_bytes(&have) == fsutil::sha256_bytes(&bytes) => {
            ctx.say(format!("同じです: {shown}"));
            return None;
        }
        Ok(_) => Kind::Fix,
        Err(_) => Kind::Missing,
    };
    let todo = if state == Kind::Fix {
        "書き直す"
    } else {
        "写す"
    };
    match mode {
        Mode::Check => ctx.say(format!("hook の口を{todo} (apply で): {shown}")),
        Mode::DryRun { .. } => ctx.say(format!("[dry-run] hook の口を{todo}: {shown}")),
        Mode::Apply { .. } => match replace_file(&bytes, &dest) {
            Ok(()) => {
                ctx.say(format!(
                    "hook の口を写しました: {shown} (<- {})",
                    src.display()
                ));
                return None;
            }
            Err(e) => {
                ctx.say(format!("!! hook の口を書けない: {shown} ({e})"));
                return Some(Kind::Failed);
            }
        },
    }
    Some(state)
}

/// `dest` を中身 `bytes` に替える。動いている exe は上書きも消すこともできないが (Windows)、名前は替えられるので、退けてから置く (退けたものは
/// 消せれば消し、消せなければ次に写すときに消す)。claude-accounts も launcher (`claude-<名前>.exe`) を置くのに使う。
pub fn replace_file(bytes: &[u8], dest: &Path) -> std::io::Result<()> {
    let dir = dest
        .parent()
        .ok_or_else(|| std::io::Error::other("親のディレクトリが無い"))?;
    std::fs::create_dir_all(dir)?;
    let name = dest
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    // 前に退けたもの (動いていて消せなかった) と、落ちた apply が残した一時のもの
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if n.starts_with(&format!("{name}.old-")) || n.starts_with(&format!("{name}.new-")) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp = dir.join(format!("{name}.new-{}-{nanos}", std::process::id()));
    std::fs::write(&tmp, bytes)?;
    let result = match std::fs::rename(&tmp, dest) {
        Ok(()) => Ok(()),
        Err(_) if dest.exists() => {
            let old = dir.join(format!("{name}.old-{nanos}"));
            let swapped = std::fs::rename(dest, &old).and_then(|()| {
                std::fs::rename(&tmp, dest).inspect_err(|_| {
                    let _ = std::fs::rename(&old, dest);
                })
            });
            if swapped.is_ok() {
                let _ = std::fs::remove_file(&old);
            }
            swapped
        }
        Err(e) => Err(e),
    };
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - CLAUDE.md は Windows の冒頭 + 空行 + 共通の CLAUDE.md の最初の「## 」から後ろ (+ devTracker なら空行とタスク管理の節)。CRLF の clone でも
    //!   同じバイト列。「## 」が無ければ failed
    //! - skills・agents・commands はディレクトリを junction、ファイルをコピー。README.md と skip-skills.txt の skill は張らず、前に張った skip の skill は
    //!   外す。ほかの dotfiles の clone の同じ場所を指すリンクは張り替える
    //! - Windows 側で変えた CLAUDE.md は衝突 (--force で上書き)
    //! - hook の口は runner の exe と同じ中身に揃え、違えば書き直す。exe の場所が分からなければ failed
    //! - repo の CLAUDE.md と冒頭・skip-skills.txt から組み立てられる (本物の repo)
    //! - skill の依存の表の skill (ハブと子の土台の 4 つ) は、表の道具 (herdrHub) が off のホストには張らず、前にこの手順が張ったものは外す
    //!   (ほかのリンクには触らない)。on なら張る
    //! - claude-skills の片付けの PR までは claude-skills の写しに譲る: claudePrivateSkills のホストで clone に同じ名前があれば張らず、置き先が
    //!   clone への junction なら触らずに知らせ (飛ばしたにしない)、この手順の前の junction は外す (続く claude-skills の手順が clone へ張る)。
    //!   clone から消えたら (片付けの PR の後) 張り、先の無い clone への junction は張り替える。claudePrivateSkills が off なら clone に同じ名前が
    //!   あっても張る (claude-skills の手順が流れないので)
    //! - 本物の repo: 表の skill は全部 dotfiles の skill にあり、skip-skills.txt に無い

    use super::*;
    use crate::host::{Groups, parse};
    use crate::link::{is_link, link_target, same_path};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir, fake_mklink};
    use std::path::PathBuf;

    /// skill の依存の表の skill (groups.json の skills。ハブと子の土台)
    const BASE: [&str; 4] = [
        "pjp-hc-child",
        "pjp-hc-hub",
        "pjp-hc-hub-panel",
        "pjp-pack-hc",
    ];
    /// ハブのホスト (herdrHub = true。claude-skills は使わない)
    const HUB: &str = "[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nherdrHub = true\n";
    /// ハブで claude-skills も使うホスト
    const HUB_PRIVATE: &str = "[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nherdrHub = true\nprivateRepos = true\nclaudePrivateSkills = true\n";
    const APPLY: Mode = Mode::Apply { force: false };

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("claude-files");
            t.write(
                "g/dotfiles/win/claude-code/CLAUDE.windows.md",
                "# 指示\n\nWindows の冒頭\n",
            );
            t.write(
                "g/dotfiles/win/claude-code/skip-skills.txt",
                "# c\n\npjp-linux-only # Linux だけ\n",
            );
            t.write(
                "g/dotfiles/nix/files/claude/CLAUDE.md",
                "# 指示\n\nNix の冒頭\n\n## 言語\n\n日本語\n",
            );
            t.write(
                "g/dotfiles/nix/files/claude/CLAUDE.dev-tracker.md",
                "## タスク管理\n\nチケット\n",
            );
            t.write("g/dotfiles/nix/files/claude/skills/pjp-a/SKILL.md", "a\n");
            t.write(
                "g/dotfiles/nix/files/claude/skills/pjp-linux-only/SKILL.md",
                "l\n",
            );
            t.write("g/dotfiles/nix/files/claude/skills/README.md", "r\n");
            t.write("g/dotfiles/nix/files/claude/agents/README.md", "r\n");
            t.write("g/dotfiles/nix/files/claude/commands/pjp-c.md", "c\n");
            t.write("exe/dotfiles-win.exe", "EXE1");
            Env { t }
        }

        fn repo(&self) -> PathBuf {
            self.t.path().join("g").join("dotfiles")
        }

        fn claude(&self, rel: &str) -> PathBuf {
            let mut p = self.t.path().join("home").join(".claude");
            for seg in rel.split('/').filter(|s| !s.is_empty()) {
                p.push(seg);
            }
            p
        }

        fn run_with(&self, mode: Mode, host: &str, exe: Option<&str>) -> (Vec<Outcome>, String) {
            let mut sys = FakeSys::new(|c| fake_mklink(c).expect("mklink だけを打つ"));
            if let Some(e) = exe {
                sys = sys.with_exe(&self.t.path().join(e));
            }
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.repo(),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                ClaudeFiles.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }

        fn run(&self, mode: Mode) -> (Vec<Outcome>, String) {
            self.run_with(
                mode,
                "[tools]\ndevTracker = true\n",
                Some("exe/dotfiles-win.exe"),
            )
        }

        /// dotfiles にハブと子の土台の skill (表の 4 つ) を置く
        fn add_base_skills(&self) {
            for name in BASE {
                self.t.write(
                    &format!("g/dotfiles/nix/files/claude/skills/{name}/SKILL.md"),
                    "base\n",
                );
            }
        }

        /// claude-skills の clone (dotfiles の clone の隣) に同じ名前の skill を置く
        fn add_clone_skills(&self) {
            for name in BASE {
                self.t.write(
                    &format!("g/claude-skills/skills/{name}/SKILL.md"),
                    "private\n",
                );
            }
        }

        fn clone_skill(&self, name: &str) -> PathBuf {
            self.t
                .path()
                .join("g")
                .join("claude-skills")
                .join("skills")
                .join(name)
        }

        fn base_src(&self, name: &str) -> PathBuf {
            self.repo()
                .join("nix")
                .join("files")
                .join("claude")
                .join("skills")
                .join(name)
        }

        /// `~/.claude/skills/<name>` に `target` への junction を張る (前の手順・claude-skills の手順が張ったものの代わり)
        fn junction(&self, name: &str, target: &Path) {
            std::fs::create_dir_all(self.claude("skills")).unwrap();
            let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
            crate::link::create_junction(&sys, &self.claude(&format!("skills/{name}")), target)
                .unwrap();
        }

        fn target(&self, name: &str) -> Option<PathBuf> {
            link_target(&self.claude(&format!("skills/{name}")))
        }

        fn run_on(&self, mode: Mode, host: &str) -> (Vec<Outcome>, String) {
            self.run_with(mode, host, Some("exe/dotfiles-win.exe"))
        }
    }

    fn kinds(o: &[Outcome]) -> Vec<Kind> {
        o.iter().map(|x| x.kind).collect()
    }

    #[test]
    fn composes_claude_md() {
        let e = Env::new();
        let md = String::from_utf8(claude_md(&e.repo(), true).unwrap()).unwrap();
        assert_eq!(
            md,
            "# 指示\n\nWindows の冒頭\n\n## 言語\n\n日本語\n\n## タスク管理\n\nチケット\n"
        );
        let md = String::from_utf8(claude_md(&e.repo(), false).unwrap()).unwrap();
        assert_eq!(md, "# 指示\n\nWindows の冒頭\n\n## 言語\n\n日本語\n");
        // CRLF の clone でも同じ
        e.t.write(
            "g/dotfiles/nix/files/claude/CLAUDE.md",
            "# 指示\r\n\r\nNix の冒頭\r\n\r\n## 言語\r\n\r\n日本語\r\n",
        );
        let crlf = String::from_utf8(claude_md(&e.repo(), false).unwrap()).unwrap();
        assert_eq!(crlf, md);
        e.t.write(
            "g/dotfiles/nix/files/claude/CLAUDE.md",
            "# 指示\n\n見出しなし\n",
        );
        assert!(claude_md(&e.repo(), false).unwrap_err().contains("## "));
    }

    #[test]
    fn places_files_links_and_the_exe() {
        let e = Env::new();
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (o, out) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Missing], "{mode:?} {o:?}\n{out}");
            assert!(!e.claude("").exists());
        }
        let (o, out) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("追加 3 / 更新 0 / 削除 0 / 同じ 0 / 飛ばした 0"),
            "{o:?}"
        );
        assert!(
            std::fs::read_to_string(e.claude("CLAUDE.md"))
                .unwrap()
                .contains("## タスク管理")
        );
        assert!(is_link(&e.claude("skills/pjp-a")));
        assert!(!e.claude("skills/pjp-linux-only").exists());
        assert!(!e.claude("skills/README.md").exists() && !e.claude("agents/README.md").exists());
        assert_eq!(
            std::fs::read_to_string(e.claude("commands/pjp-c.md")).unwrap(),
            "c\n"
        );
        assert_eq!(
            std::fs::read(e.claude("hooks/dotfiles-claude.exe")).unwrap(),
            b"EXE1"
        );
        assert!(
            out.contains("張らない (このマシンでは使わない): skills/pjp-linux-only"),
            "{out}"
        );
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        // runner を作り直すと hook の口を書き直す
        e.t.write("exe/dotfiles-win.exe", "EXE2");
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}");
        e.run(Mode::Apply { force: false });
        assert_eq!(
            std::fs::read(e.claude("hooks/dotfiles-claude.exe")).unwrap(),
            b"EXE2"
        );
        // devTracker を外すと CLAUDE.md を書き直す (記録どおりの中身なので上書き)
        let (o, _) = e.run_with(
            Mode::Apply { force: false },
            "",
            Some("exe/dotfiles-win.exe"),
        );
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(
            !std::fs::read_to_string(e.claude("CLAUDE.md"))
                .unwrap()
                .contains("## タスク管理")
        );
    }

    #[test]
    fn edited_claude_md_conflicts() {
        let e = Env::new();
        e.t.write("home/.claude/CLAUDE.md", "手で書いた指示\n");
        let (o, _) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("CLAUDE.md (中身が違う。置いた記録が無い")
                    && n.contains("dotfiles へ取り込む")
                    && n.contains("--steps claude-files --force")),
            "{o:?}"
        );
        assert_eq!(
            std::fs::read_to_string(e.claude("CLAUDE.md")).unwrap(),
            "手で書いた指示\n"
        );
        let (o, _) = e.run(Mode::Apply { force: true });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(
            std::fs::read_to_string(e.claude("CLAUDE.md"))
                .unwrap()
                .starts_with("# 指示\n\nWindows の冒頭\n")
        );
    }

    #[test]
    fn relinks_other_clones_and_removes_skipped_links() {
        let e = Env::new();
        let other =
            e.t.path()
                .join("tmp")
                .join("dotfiles")
                .join("nix")
                .join("files")
                .join("claude")
                .join("skills");
        e.t.write(
            "tmp/dotfiles/nix/files/claude/skills/pjp-a/SKILL.md",
            "old\n",
        );
        e.t.write(
            "tmp/dotfiles/nix/files/claude/skills/pjp-linux-only/SKILL.md",
            "old\n",
        );
        std::fs::create_dir_all(e.claude("skills")).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        for name in ["pjp-a", "pjp-linux-only"] {
            crate::link::create_junction(
                &sys,
                &e.claude(&format!("skills/{name}")),
                &other.join(name),
            )
            .unwrap();
        }
        let (o, out) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("更新 1 / 削除 1"), "{o:?}");
        assert!(same_path(
            &link_target(&e.claude("skills/pjp-a")).unwrap(),
            &e.repo()
                .join("nix")
                .join("files")
                .join("claude")
                .join("skills")
                .join("pjp-a")
        ));
        assert!(!e.claude("skills/pjp-linux-only").exists());
        assert!(
            other.join("pjp-linux-only").join("SKILL.md").is_file(),
            "先は残す"
        );
    }

    #[test]
    fn missing_exe_fails() {
        let e = Env::new();
        let (o, out) = e.run_with(Mode::Check, "", None);
        assert_eq!(kinds(&o), vec![Kind::Failed], "{o:?}\n{out}");
        assert!(out.contains("runner の exe の場所が分からない"), "{out}");
    }

    #[test]
    fn replaces_an_existing_file() {
        let t = TempDir::new("claude-files-replace");
        let dest = t.path().join("hooks").join("x.exe");
        replace_file(b"one", &dest).unwrap();
        t.write("hooks/x.exe.old-1", "stale");
        t.write("hooks/x.exe.new-9-1", "crashed");
        t.write("hooks/y.exe.new-9-1", "someone else");
        replace_file(b"two", &dest).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"two");
        let mut left: Vec<String> = std::fs::read_dir(t.path().join("hooks"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(
            left,
            vec!["x.exe".to_string(), "y.exe.new-9-1".to_string()],
            "退けたものと一時のものは残さない (ほかの名前のものには触らない)"
        );
    }

    /// Windows では、動いている exe も入れ替えられる (上書きできないので退けてから置き、退けたものは次に消す)
    #[cfg(windows)]
    #[test]
    fn replaces_a_running_exe() {
        let t = TempDir::new("claude-files-running");
        let dest = t.path().join("hooks").join("x.exe");
        std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
        let ping = PathBuf::from(std::env::var("SystemRoot").unwrap())
            .join("System32")
            .join("PING.EXE");
        std::fs::copy(&ping, &dest).unwrap();
        let mut child = std::process::Command::new(&dest)
            .args(["-n", "30", "127.0.0.1"])
            .stdout(std::process::Stdio::null())
            .spawn()
            .unwrap();
        // 動いている間は上書きできない (この試験が確かめたい場面になっている)
        assert!(std::fs::write(&dest, b"x").is_err());
        let replaced = replace_file(b"new", &dest);
        let _ = child.kill();
        let _ = child.wait();
        replaced.unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"new");
        // 止まった後の次の入れ替えで、退けたものが消える
        replace_file(b"newer", &dest).unwrap();
        let left: Vec<String> = std::fs::read_dir(t.path().join("hooks"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(left, vec!["x.exe".to_string()]);
    }

    /// 表の道具 (herdrHub) が off のホストには土台の skill を張らず、on なら張る。off に戻すと、この手順が張ったものだけを外す
    #[test]
    fn base_skills_follow_the_host() {
        let e = Env::new();
        e.add_base_skills();
        let (o, out) = e.run_on(APPLY, "");
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        for name in BASE {
            assert!(!e.claude(&format!("skills/{name}")).exists(), "{name}");
            assert!(
                out.contains(&format!(
                    "張らない (このホストでは使わない。skill の依存の表の herdrHub が off): skills/{name}"
                )),
                "{out}"
            );
        }
        let (o, out) = e.run_on(APPLY, HUB);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("追加 4"), "{o:?}");
        for name in BASE {
            assert!(
                same_path(&e.target(name).unwrap(), &e.base_src(name)),
                "{name}"
            );
        }
        // off に戻す: この手順が張った junction は外し (先は残す)、ほかの先へのリンクには触らない
        let elsewhere = e.t.path().join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        crate::link::remove_link(&e.claude("skills/pjp-pack-hc")).unwrap();
        e.junction("pjp-pack-hc", &elsewhere);
        let (o, out) = e.run_on(Mode::Check, "");
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains("外す (apply で): skills/pjp-hc-hub")
                && out.contains("このホストでは使わない"),
            "{out}"
        );
        let (o, out) = e.run_on(APPLY, "");
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 3"), "{o:?}");
        for name in ["pjp-hc-child", "pjp-hc-hub", "pjp-hc-hub-panel"] {
            assert!(!e.claude(&format!("skills/{name}")).exists(), "{name}");
            assert!(e.base_src(name).join("SKILL.md").is_file(), "先は残す");
        }
        assert!(same_path(&e.target("pjp-pack-hc").unwrap(), &elsewhere));
    }

    /// claude-skills の片付けの PR までは claude-skills の写しに譲る: 張らず、clone への junction は触らずに知らせ、この手順の前の junction は外して
    /// claude-skills の手順 (claude-files の後に流れる) に clone へ張らせる
    #[test]
    fn yields_to_the_claude_skills_copy() {
        let e = Env::new();
        e.add_base_skills();
        e.add_clone_skills();
        // pjp-hc-hub は claude-skills の手順が張った clone への junction、pjp-hc-child はこの手順が前に張った dotfiles への junction
        e.junction("pjp-hc-hub", &e.clone_skill("pjp-hc-hub"));
        e.junction("pjp-hc-child", &e.base_src("pjp-hc-child"));
        let (o, out) = e.run_on(Mode::Check, HUB_PRIVATE);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains("外す (apply で): skills/pjp-hc-child"),
            "{out}"
        );
        let (o, out) = e.run_on(APPLY, HUB_PRIVATE);
        assert_eq!(kinds(&o), vec![Kind::Ok], "飛ばしたにしない: {o:?}\n{out}");
        assert!(o[0].text.contains("追加 3 / 更新 0 / 削除 1"), "{o:?}");
        for name in BASE {
            assert!(
                out.contains(&format!(
                    "張らない (claude-skills の写しを使う。claude-skills の片付けの PR まで): skills/{name}"
                )),
                "{out}"
            );
        }
        assert!(same_path(
            &e.target("pjp-hc-hub").unwrap(),
            &e.clone_skill("pjp-hc-hub")
        ));
        assert!(!e.claude("skills/pjp-hc-child").exists());
        assert!(!e.claude("skills/pjp-hc-hub-panel").exists());
        // 続く claude-skills の手順が clone へ張る (衝突しない)
        let sys = FakeSys::new(|c| fake_mklink(c).expect("mklink だけを打つ"));
        let mut buf = Vec::new();
        let o = {
            let mut ctx = Ctx {
                repo: e.repo(),
                roots: Roots::from_home(&e.t.path().join("home")),
                state_dir: e.t.path().join("state"),
                host: parse(
                    HUB_PRIVATE,
                    Path::new("h.toml"),
                    Groups::embedded().unwrap(),
                )
                .unwrap(),
                sys: &sys,
                out: &mut buf,
            };
            super::super::claude_skills::ClaudeSkills.run(&mut ctx, APPLY)
        };
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        for name in BASE {
            assert!(
                same_path(&e.target(name).unwrap(), &e.clone_skill(name)),
                "{name}"
            );
        }
        // 2 回目の claude-files は clone への junction に触らない
        let (o, out) = e.run_on(Mode::Check, HUB_PRIVATE);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
    }

    /// clone から消えたら (片付けの PR の後) 張る。先の無い clone への junction (片付けの後の残り) は張り替える
    #[test]
    fn links_after_claude_skills_drops_it() {
        let e = Env::new();
        e.add_base_skills();
        e.add_clone_skills();
        for name in BASE {
            e.junction(name, &e.clone_skill(name));
        }
        std::fs::remove_dir_all(e.t.path().join("g").join("claude-skills").join("skills")).unwrap();
        let (o, out) = e.run_on(Mode::Check, HUB_PRIVATE);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(
            out.contains("張り替える (apply で): skills/pjp-hc-hub"),
            "{out}"
        );
        let (o, out) = e.run_on(APPLY, HUB_PRIVATE);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("更新 4"), "{o:?}");
        for name in BASE {
            assert!(
                same_path(&e.target(name).unwrap(), &e.base_src(name)),
                "{name}"
            );
        }
        // clone そのものが無いホストでも張る
        let e = Env::new();
        e.add_base_skills();
        let (o, out) = e.run_on(APPLY, HUB_PRIVATE);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(same_path(
            &e.target("pjp-hc-hub").unwrap(),
            &e.base_src("pjp-hc-hub")
        ));
    }

    /// claudePrivateSkills が off なら (claude-skills の手順が流れない) clone に同じ名前があっても張る。ただし置き先が clone への junction (先が
    /// ある) なら触らずに知らせる
    #[test]
    fn links_when_claude_skills_is_off() {
        let e = Env::new();
        e.add_base_skills();
        e.add_clone_skills();
        e.junction("pjp-hc-hub", &e.clone_skill("pjp-hc-hub"));
        let (o, out) = e.run_on(APPLY, HUB);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        // CLAUDE.md・pjp-a・commands/pjp-c.md と、土台の 3 つ
        assert!(o[0].text.contains("追加 6"), "{o:?}");
        for name in ["pjp-hc-child", "pjp-hc-hub-panel", "pjp-pack-hc"] {
            assert!(
                same_path(&e.target(name).unwrap(), &e.base_src(name)),
                "{name}"
            );
        }
        assert!(same_path(
            &e.target("pjp-hc-hub").unwrap(),
            &e.clone_skill("pjp-hc-hub")
        ));
        assert!(
            out.contains("張らない (claude-skills の写しを使う。claude-skills の片付けの PR まで): skills/pjp-hc-hub"),
            "{out}"
        );
    }

    /// 本物の repo の表の skill は、全部 dotfiles の skill にあり、Windows に張らない一覧 (skip-skills.txt) に無い
    #[test]
    fn real_repo_carries_the_table_skills() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let host =
            crate::host::HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap());
        let skip = names(&std::fs::read_to_string(repo.join(SKIP_SKILLS)).unwrap());
        let table = host.table_skills();
        assert!(!table.is_empty());
        for name in table {
            assert!(
                repo.join("nix/files/claude/skills")
                    .join(name)
                    .join("SKILL.md")
                    .is_file(),
                "{name} が dotfiles の skill に無い"
            );
            assert!(
                !skip.iter().any(|s| s == name),
                "{name} が skip-skills.txt にある"
            );
        }
    }

    /// 本物の repo の冒頭・共通の CLAUDE.md・skip-skills.txt から組み立てられ、skip の skill は dotfiles にある
    #[test]
    fn real_repo_composes() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let md = String::from_utf8(claude_md(&repo, true).unwrap()).unwrap();
        assert!(md.starts_with("# ユーザーレベルの指示\n"), "{md}");
        assert!(
            !md.contains("home-manager switch"),
            "Linux の冒頭を差し替える"
        );
        assert!(md.contains("\n## 応答の言語\n") && md.contains("\n## タスク管理\n"));
        let skip = names(&std::fs::read_to_string(repo.join(SKIP_SKILLS)).unwrap());
        assert!(!skip.is_empty());
        for s in skip {
            assert!(
                repo.join("nix/files/claude/skills").join(&s).is_dir(),
                "{s} が dotfiles の skill に無い"
            );
        }
    }
}
