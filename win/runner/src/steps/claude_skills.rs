//! claude-skills (order 50): claude-skills の clone の `skills/`・`agents/`・`commands/`・`rules/` の中身を 1 つずつ `~/.claude/<種類>/` へつなぐ。
//! Linux の `nix/scripts/bootstrap-claude-skills.sh` と同じ選び方 (README.md は除く・同じ名前の実体や別のリンクは飛ばす・clone から消えた
//! ものを片付ける・clone の場所を `~/.local/state/dotfiles/claude-skills-dir` に書く)。
//!
//! Windows では、ディレクトリは junction (`cmd /c mklink /J`。権限が要らない)、ファイルはコピー (ファイルの symlink は開発者モードか管理者が
//! 要り、hard link は git が取り出し直すと切れる) にする。コピーは files と同じ記録 (`%LOCALAPPDATA%\dotfiles\state\claude-skills.deployed.json`)
//! で判定する: 置き先が無い → コピー・同じ中身 → 何もしない・記録と同じ中身 → 上書き・ほか → 衝突 (`--force` で上書き)。clone を pull したら
//! `dotfiles apply` で写し直す (dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*)。つなぎ方は claude-files と共有 (`linker`)。
//!
//! clone は runner の clone の隣、無ければ bootstrap の置き場 (`ctx.sibling`)。runner は取得しない (bootstrap が clone し、進めるのは人が
//! 打つ PowerShell の `dotfiles --self-update`。dotfiles 関数が clone の中の `win/powershell/Invoke-DotfilesSelfUpdate.ps1` を呼び、3 つの clone を
//! fast-forward してから runner を流す。dotfiles-private の docs/adr/104_win_dotfiles_self_update_*)。

use super::linker::{Linker, Source};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::link::same_path;
use crate::record::Records;
use crate::report::Kind;
use std::path::{Path, PathBuf};

/// つなぐ種類 (clone と `~/.claude` の下のディレクトリの名前)。Linux の bootstrap-claude-skills.sh の kinds と同じ
pub const KINDS: [&str; 4] = ["skills", "agents", "commands", "rules"];
/// コピーの記録 (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "claude-skills.deployed.json";
/// clone の場所の控え (ホームからの相対)。shim の pjp と Linux の bootstrap-pjp.sh が読む
pub const STATE_FILE_REL: &str = ".local/state/dotfiles/claude-skills-dir";

/// claude-skills の clone (runner の clone の隣、無ければ bootstrap の置き場)。
pub fn clone_dir(ctx: &Ctx) -> PathBuf {
    ctx.sibling("claude-skills")
}

/// 控え (claude-skills-dir) の 1 行目。BOM・CRLF・前後の空白を落とす。無い・空なら None。
fn read_state_line(path: &Path) -> Option<PathBuf> {
    let bytes = std::fs::read(path).ok()?;
    let text = String::from_utf8_lossy(&bytes);
    let line = text.trim_start_matches('\u{feff}').lines().next()?.trim();
    (!line.is_empty()).then(|| PathBuf::from(line))
}

pub struct ClaudeSkills;

impl Step for ClaudeSkills {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-skills",
            order: 50,
            title: "claude-skills の skill・rule などを ~/.claude/ へつなぐ (ディレクトリは junction、ファイルはコピー)",
            gate: Gate::Tool("claudePrivateSkills"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let clone = clone_dir(ctx);
        if !clone.is_dir() {
            ctx.say(format!(
                "!! claude-skills の clone がありません: {}",
                clone.display()
            ));
            return vec![Outcome::new(
                Kind::Manual,
                format!(
                    "claude-skills の clone が無い ({}) → -Private の bootstrap (Install-Bootstrap.ps1 -Private) が clone する",
                    clone.display()
                ),
            )];
        }
        ctx.say(format!("clone: {}", clone.display()));
        let home = ctx.roots.user_profile.clone();
        let state_file = join_segments(&home, STATE_FILE_REL);
        // 控えの値を前の clone として信じるのは、名前が claude-skills のときだけ (この手順はいつも clone の場所を書く。ホームのような広い値で、
        // ユーザーのリンクまで「この手順のもの」として外さない)
        let prev = read_state_line(&state_file).filter(|p| {
            !same_path(p, &clone)
                && p.file_name()
                    .is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case("claude-skills"))
        });
        let record_path = ctx.state_dir.join(RECORD_FILE);
        let records = match Records::load(&record_path) {
            Ok(r) => r,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![
                    Outcome::new(Kind::Failed, "claude-skills のコピーの記録が壊れている").note(e),
                ];
            }
        };
        let src = Source {
            root: clone,
            prev,
            foreign_suffix: None,
            kinds: &KINDS,
            skip_skills: Vec::new(),
            select: None,
            origin: "clone",
            absorb: "claude-skills",
            step: "claude-skills",
        };
        let mut w = Linker::new(src, home.join(".claude"), mode, records);
        w.run(ctx);
        let state = sync_state_file(ctx, &mut w, &state_file);
        w.finish(ctx, &record_path, state)
    }
}

/// 控え (claude-skills-dir) に clone の場所を書く。揃っていれば None、無い・違えばその種類 (apply では書く)。
fn sync_state_file(ctx: &mut Ctx, w: &mut Linker, path: &Path) -> Option<Kind> {
    let desired = format!("{}\n", w.src.root.display());
    let kind = match std::fs::read(path) {
        Ok(have) if have == desired.as_bytes() => return None,
        Ok(_) => Kind::Fix,
        Err(_) => Kind::Missing,
    };
    let shown = path.display();
    match w.mode {
        Mode::Check => ctx.say(format!("clone の場所の控えを書く (apply で): {shown}")),
        Mode::DryRun { .. } => ctx.say(format!("[dry-run] clone の場所の控えを書く: {shown}")),
        Mode::Apply { .. } => match fsutil::write_atomic(path, desired.as_bytes()) {
            Ok(()) => ctx.say(format!("clone の場所の控えを書きました: {shown}")),
            Err(e) => w.fail(ctx, format!("{shown} を書けない ({e})")),
        },
    }
    Some(kind)
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (Linux の nix/tests/bootstrap-claude-skills.test.sh の選び方)
    //!
    //! - ディレクトリは junction、ファイルはコピー、README.md は除く。check と dry-run は何も書かない。2 回目は揃っている
    //! - 置き先の実体 (手で置いたディレクトリ) と別の先へのリンクは飛ばし、触らない
    //! - 前の clone (claude-skills-dir の値) を指すリンクは張り替え、今の clone に無いものを指すリンクは外す (先は残す)
    //! - clone から消えたコピーは、中身が記録どおりなら消し、変えていれば残して知らせる
    //! - 記録の無い違う中身のコピーは衝突 (`--force` で上書き)
    //! - clone が無ければ manual

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::link::{is_link, link_target, same_path};
    use crate::manifest::Roots;
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir, fake_mklink};
    use std::path::{Path, PathBuf};

    struct Env {
        t: TempDir,
    }

    impl Env {
        fn new() -> Self {
            let t = TempDir::new("claude-skills");
            std::fs::create_dir_all(t.path().join("g").join("dotfiles")).unwrap();
            t.write("g/claude-skills/skills/pjp-a/SKILL.md", "a\n");
            t.write("g/claude-skills/skills/README.md", "readme\n");
            t.write("g/claude-skills/rules/pjp-r.md", "rule\n");
            t.write("g/claude-skills/rules/README.md", "readme\n");
            t.write("g/claude-skills/agents/README.md", "readme\n");
            Env { t }
        }

        fn clone(&self) -> PathBuf {
            self.t.path().join("g").join("claude-skills")
        }

        fn claude(&self, rel: &str) -> PathBuf {
            let mut p = self.t.path().join("home").join(".claude");
            for seg in rel.split('/') {
                p.push(seg);
            }
            p
        }

        fn state_file(&self) -> PathBuf {
            self.t
                .path()
                .join("home")
                .join(".local")
                .join("state")
                .join("dotfiles")
                .join("claude-skills-dir")
        }

        fn run(&self, mode: Mode) -> (Vec<Outcome>, String) {
            let sys = FakeSys::new(|c| fake_mklink(c).expect("mklink だけを打つ"));
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("g").join("dotfiles"),
                    roots: Roots::from_home(&self.t.path().join("home")),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys: &sys,
                    out: &mut out,
                };
                ClaudeSkills.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }
    }

    fn kinds(o: &[Outcome]) -> Vec<Kind> {
        o.iter().map(|x| x.kind).collect()
    }

    #[test]
    fn links_dirs_and_copies_files() {
        let e = Env::new();
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (o, _) = e.run(mode);
            assert_eq!(kinds(&o), vec![Kind::Missing], "{mode:?} {o:?}");
            assert!(!e.claude("skills").exists());
            assert!(!e.state_file().exists());
        }
        let (o, out) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(
            o[0].text
                .starts_with("追加 2 / 更新 0 / 削除 0 / 同じ 0 / 飛ばした 0"),
            "{o:?}"
        );
        let link = e.claude("skills/pjp-a");
        assert!(is_link(&link));
        assert!(same_path(
            &link_target(&link).unwrap(),
            &e.clone().join("skills").join("pjp-a")
        ));
        assert!(!is_link(&e.claude("rules/pjp-r.md")));
        assert_eq!(
            std::fs::read_to_string(e.claude("rules/pjp-r.md")).unwrap(),
            "rule\n"
        );
        assert!(!e.claude("skills/README.md").exists());
        assert!(!e.claude("rules/README.md").exists());
        assert!(!e.claude("agents/README.md").exists());
        assert_eq!(
            std::fs::read_to_string(e.state_file()).unwrap(),
            format!("{}\n", e.clone().display())
        );
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert!(o[0].text.contains("同じ 2"), "{o:?}");
    }

    #[test]
    fn skips_real_dirs_and_foreign_links() {
        let e = Env::new();
        e.t.write("g/claude-skills/skills/pjp-c/SKILL.md", "c\n");
        // 手で置いた同じ名前のディレクトリと、別の先へのリンク
        e.t.write("home/.claude/skills/pjp-a/SKILL.md", "mine\n");
        let elsewhere = e.t.path().join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        crate::link::create_junction(&sys, &e.claude("skills/pjp-c"), &elsewhere).unwrap();

        let (o, _) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(o[1].text.contains("飛ばした 2"), "{o:?}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("skills/pjp-a (実体がある")),
            "{o:?}"
        );
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("skills/pjp-c (別のリンクがある")),
            "{o:?}"
        );
        assert!(!is_link(&e.claude("skills/pjp-a")));
        assert_eq!(
            std::fs::read_to_string(e.claude("skills/pjp-a/SKILL.md")).unwrap(),
            "mine\n"
        );
        assert!(same_path(
            &link_target(&e.claude("skills/pjp-c")).unwrap(),
            &elsewhere
        ));
    }

    #[test]
    fn relinks_from_the_previous_clone_and_prunes() {
        let e = Env::new();
        let old = e.t.path().join("old").join("claude-skills");
        e.t.write("old/claude-skills/skills/pjp-a/SKILL.md", "old\n");
        e.t.write("old/claude-skills/skills/pjp-gone/SKILL.md", "gone\n");
        e.t.write(
            "home/.local/state/dotfiles/claude-skills-dir",
            &format!("\u{feff}{}\r\n", old.display()),
        );
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        std::fs::create_dir_all(e.claude("skills")).unwrap();
        for name in ["pjp-a", "pjp-gone"] {
            crate::link::create_junction(
                &sys,
                &e.claude(&format!("skills/{name}")),
                &old.join("skills").join(name),
            )
            .unwrap();
        }

        let (o, out) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}\n{out}");
        assert!(same_path(
            &link_target(&e.claude("skills/pjp-a")).unwrap(),
            &old.join("skills").join("pjp-a")
        ));

        let (o, out) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("更新 1 / 削除 1"), "{o:?}");
        assert!(same_path(
            &link_target(&e.claude("skills/pjp-a")).unwrap(),
            &e.clone().join("skills").join("pjp-a")
        ));
        assert!(!is_link(&e.claude("skills/pjp-gone")) && !e.claude("skills/pjp-gone").exists());
        // 先 (前の clone の中身) は消さない
        assert!(
            old.join("skills")
                .join("pjp-gone")
                .join("SKILL.md")
                .is_file()
        );
        assert_eq!(
            std::fs::read_to_string(e.state_file()).unwrap(),
            format!("{}\n", e.clone().display())
        );
    }

    #[test]
    fn removes_copies_and_links_gone_from_the_clone() {
        let e = Env::new();
        e.t.write("g/claude-skills/rules/pjp-kept.md", "kept\n");
        e.run(Mode::Apply { force: false });
        std::fs::remove_dir_all(e.clone().join("skills").join("pjp-a")).unwrap();
        std::fs::remove_file(e.clone().join("rules").join("pjp-r.md")).unwrap();
        // 手で変えたコピーは残す
        std::fs::write(e.claude("rules/pjp-kept.md"), "changed\n").unwrap();
        std::fs::remove_file(e.clone().join("rules").join("pjp-kept.md")).unwrap();

        let (o, out) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 2"), "{o:?}");
        assert!(!is_link(&e.claude("skills/pjp-a")) && !e.claude("skills/pjp-a").exists());
        assert!(!e.claude("rules/pjp-r.md").exists());
        assert_eq!(
            std::fs::read_to_string(e.claude("rules/pjp-kept.md")).unwrap(),
            "changed\n"
        );
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("rules/pjp-kept.md (clone から消えた")),
            "{o:?}"
        );
        // 記録から外したので、次は何も言わない
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
    }

    /// `~/.claude/<種類>` そのものがリンク (手で別の場所へつないだ) なら、その種類には触らない (先へ書かない・先を消さない)
    #[test]
    fn skips_a_kind_dir_that_is_a_link() {
        let e = Env::new();
        let elsewhere = e.t.path().join("my-rules");
        e.t.write("my-rules/pjp-r.md", "mine\n");
        std::fs::create_dir_all(e.claude("")).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        crate::link::create_junction(&sys, &e.claude("rules"), &elsewhere).unwrap();
        let (o, out) = e.run(Mode::Apply { force: true });
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}\n{out}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("rules (~/.claude/rules がリンク")),
            "{o:?}"
        );
        assert_eq!(
            std::fs::read_to_string(elsewhere.join("pjp-r.md")).unwrap(),
            "mine\n"
        );
        // skills は張る
        assert!(is_link(&e.claude("skills/pjp-a")));
    }

    /// 控えの値は、名前が claude-skills のときだけ前の clone として信じる (ホームのような広い値で、ユーザーのリンクを外さない)
    #[test]
    fn ignores_a_broad_previous_clone() {
        let e = Env::new();
        let home = e.t.path().join("home");
        e.t.write(
            "home/.local/state/dotfiles/claude-skills-dir",
            &format!("{}\n", home.display()),
        );
        e.t.write("home/my-skills/mine/SKILL.md", "mine\n");
        std::fs::create_dir_all(e.claude("skills")).unwrap();
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        crate::link::create_junction(
            &sys,
            &e.claude("skills/mine"),
            &home.join("my-skills").join("mine"),
        )
        .unwrap();
        let (o, out) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(o[0].text.contains("削除 0"), "{o:?}");
        assert!(is_link(&e.claude("skills/mine")));
    }

    #[test]
    fn copy_conflict_needs_force() {
        let e = Env::new();
        e.t.write("home/.claude/rules/pjp-r.md", "mine\n");
        let (o, _) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok, Kind::Manual], "{o:?}");
        assert!(
            o[1].notes
                .iter()
                .any(|n| n.starts_with("rules/pjp-r.md (中身が違う")),
            "{o:?}"
        );
        assert_eq!(
            std::fs::read_to_string(e.claude("rules/pjp-r.md")).unwrap(),
            "mine\n"
        );
        let (o, _) = e.run(Mode::Apply { force: true });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        assert_eq!(
            std::fs::read_to_string(e.claude("rules/pjp-r.md")).unwrap(),
            "rule\n"
        );
        // 上書きした後は記録どおりなので、clone の側の更新は上書きで入る
        e.t.write("g/claude-skills/rules/pjp-r.md", "rule2\n");
        let (o, _) = e.run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Fix], "{o:?}");
        e.run(Mode::Apply { force: false });
        assert_eq!(
            std::fs::read_to_string(e.claude("rules/pjp-r.md")).unwrap(),
            "rule2\n"
        );
    }

    /// Windows では本物の口 (`%ComSpec%` の `/c mklink /J`) で junction を張り、外すと先が残る
    #[cfg(windows)]
    #[test]
    fn real_junction_round_trip() {
        let e = Env::new();
        let run = |mode| {
            let mut out = Vec::new();
            let mut ctx = Ctx {
                repo: e.t.path().join("g").join("dotfiles"),
                roots: Roots::from_home(&e.t.path().join("home")),
                state_dir: e.t.path().join("state"),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys: &crate::testutil::RealSysPlain,
                out: &mut out,
            };
            let o = ClaudeSkills.run(&mut ctx, mode);
            (o, String::from_utf8(out).unwrap())
        };
        let (o, out) = run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        let link = e.claude("skills/pjp-a");
        assert!(is_link(&link));
        assert_eq!(
            std::fs::read_to_string(link.join("SKILL.md")).unwrap(),
            "a\n"
        );
        let (o, _) = run(Mode::Check);
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}");
        // clone から消すと外れ、clone の側のほかのものは残る
        std::fs::rename(
            e.clone().join("skills").join("pjp-a"),
            e.t.path().join("moved-pjp-a"),
        )
        .unwrap();
        let (o, out) = run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Ok], "{o:?}\n{out}");
        assert!(!is_link(&link) && !link.exists());
        assert!(e.t.path().join("moved-pjp-a").join("SKILL.md").is_file());
    }

    #[test]
    fn missing_clone_is_manual() {
        let e = Env::new();
        std::fs::remove_dir_all(e.clone()).unwrap();
        let (o, _) = e.run(Mode::Apply { force: false });
        assert_eq!(kinds(&o), vec![Kind::Manual], "{o:?}");
        assert!(o[0].text.contains("claude-skills の clone が無い"), "{o:?}");
        assert!(!e.claude("skills").exists());
    }
}
