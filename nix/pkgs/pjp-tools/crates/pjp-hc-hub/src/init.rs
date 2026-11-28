//! `pjp hub init` と `pjp hub check` (spec §7.3。pjp-herdr-hub の `hub-init.sh` の写し)。
//!
//! DIR (既定は `~/h`。Windows は `%USERPROFILE%\h`) を、herdr-app と hc の集約ハブにする。打ち直してよい (雛形との差だけを直す)。
//!
//! 1. 止まる (何も書かずに理由を出して終了コード 1):
//!    - DIR が別の repo の中 (DIR が無ければ、最も近い既存の祖先で見る)・git のディレクトリの中
//!    - DIR が remote を持つ repo (ハブではなく本物の repo)・ハブの linked worktree
//!    - DIR がほかの skill のハブ (`git config pjp.hub.skill` が pjp-hc-hub でない。pjp-herdr-hub の `hub-init.sh` が作った
//!      旧 herdr のハブには、この設定が無い)
//!    - DIR がまだハブでなく (`git config pjp.devtracker.repo` が無い)、雛形の外のものか、雛形と中身の違う同じ名前の
//!      ファイルがある (並べて出す。黙って上書きしない)
//! 2. DIR が無ければ作り、git repo でなければ `git init -b main`
//! 3. 雛形を写す (中身が同じなら触らない。CRLF と LF の違いは見ない): `CLAUDE.md`・`.claude/settings.json` (hook の
//!    `pjp hub guard` を PreToolUse に登録する。private な足し分の雛形の重ねがあれば skillOverrides も。[`crate::templates`])・
//!    `.gitignore`。重ねのファイルが壊れていれば、何も書かずにパスとわけを出して止まる (終了コード 2)
//! 4. `git config pjp.devtracker.repo <行の名前>` (DIR の頭のホームを `~` にしたもの。`~/h`。別の値が付いていれば変えない。ハブの
//!    印で、private な足し分の Dev Tracker が Repositories の行の名前として読む) と `git config pjp.hub.skill pjp-hc-hub`
//! 5. 3 つのファイルに commit されていない差があれば、その 3 つだけを commit する。外に出さない repo なので署名せず、
//!    全体の hook でも止めない。git の名前とメールが決まらないマシンでは、pjp hub init の名前で commit する
//!
//! `--check` (`pjp hub check`) は何も書かずに差を出し、差があれば終了コード 1。

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use pjp_core::{Error, Result, paths};

use crate::git::Git;
use crate::pathx;
use crate::templates::{self, Context, Template};

/// ハブの印で、Repositories の行の名前を持つ設定 (private な足し分の Dev Tracker が読む)。
pub const ROW_KEY: &str = "pjp.devtracker.repo";
/// どの skill のハブかを持つ設定。
pub const SKILL_KEY: &str = "pjp.hub.skill";
/// この道具が作るハブの skill。
pub const SKILL: &str = "pjp-hc-hub";
const COMMIT_MESSAGE: &str = "pjp-hc-hub の pjp hub init でハブの決まりのファイルを書く";
/// git の名前とメールが決まらないマシンで、commit に使う名前とメール (ハブは外に出さない repo)。
const FALLBACK_NAME: &str = "pjp hub init";
const FALLBACK_EMAIL: &str = "pjp-hub@localhost";

/// `pjp hub init` の引数。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Options {
    /// ハブにするディレクトリ (無ければ `~/h`)。
    pub dir: Option<OsString>,
    /// 書かずに差を出す。
    pub check: bool,
}

/// 書く前に見たハブの様子。
#[derive(Debug)]
struct Survey {
    hub: PathBuf,
    /// このマシンの値で描いた雛形。
    files: Vec<Template>,
    row: String,
    is_repo: bool,
    /// `pjp.devtracker.repo` の値 (付いていればハブ)。
    current: Option<String>,
    /// `pjp.hub.skill` の値。
    skill: Option<String>,
    /// まだハブでないときに、止まるわけ (雛形の外のもの・中身の違うファイル)。
    not_yet: String,
}

impl Survey {
    /// ほかの skill のハブなら、そのわけ。
    fn foreign_hub(&self) -> Option<String> {
        self.current.as_ref()?;
        match self.skill.as_deref() {
            Some(SKILL) => None,
            None => Some(format!(
                "{} は pjp-herdr-hub (旧 herdr) のハブ (git config {SKILL_KEY} が無い。hub-init.sh が作ったもの)",
                self.hub.display()
            )),
            Some(other) => Some(format!(
                "{} は {other} のハブ (git config {SKILL_KEY} = {other})",
                self.hub.display()
            )),
        }
    }
}

/// `pjp hub init` / `check` を打つ。終了コード (0・1) か、止まったわけを返す。
pub fn run(opts: &Options) -> Result<u8> {
    let git = Git::find().ok_or_else(|| Error::config("git が見つかりません (PATH)"))?;
    let home = paths::home_dir()?;
    let cwd = std::env::current_dir().map_err(|e| Error::io("今のディレクトリを読めません", &e))?;
    let given = match &opts.dir {
        Some(d) => paths::expand_tilde_here(d, &home),
        None => home.join("h"),
    };
    let hub = pathx::absolute_lexical(&given, &cwd);
    let row = paths::contract_home(
        &hub.to_string_lossy(),
        &home.to_string_lossy(),
        cfg!(windows),
    );
    let files = templates::files(&Context::at(&home, cfg!(windows))?);
    let survey = survey(&git, hub, row, files)?;
    if opts.check {
        let diffs = diffs(&git, &survey);
        if diffs.is_empty() {
            println!("{}: 差は無い", survey.hub.display());
            return Ok(0);
        }
        for d in &diffs {
            println!("差: {d}");
        }
        return Ok(1);
    }
    write(&git, &survey)
}

/// ハブ `hub` の雛形 `files` との差 (`pjp hub check` の「差:」の行の中身)。止まる場所 (別の repo の中など) なら Err。
pub fn check_hub(git: &Git, hub: &Path, home: &Path, files: Vec<Template>) -> Result<Vec<String>> {
    let row = paths::contract_home(
        &hub.to_string_lossy(),
        &home.to_string_lossy(),
        cfg!(windows),
    );
    let survey = survey(git, hub.to_path_buf(), row, files)?;
    Ok(diffs(git, &survey))
}

fn fail(message: String) -> Error {
    Error::failure(message)
}

/// 止まる場所なら Err。止まらなければ、書く前の様子。
fn survey(git: &Git, hub: PathBuf, row: String, files: Vec<Template>) -> Result<Survey> {
    if hub.exists() && !hub.is_dir() {
        return Err(fail(format!("{} はディレクトリでない", hub.display())));
    }

    // ---- 止まる場合 (別の repo の中・git のディレクトリの中・remote を持つ repo・ハブの worktree)
    let probe = pathx::nearest_dir(&hub)
        .ok_or_else(|| fail(format!("{} の祖先にディレクトリが無い", hub.display())))?;
    let mut is_repo = false;
    if let Some(top) = git.toplevel(&probe) {
        let inside =
            probe != hub || !paths::real_path(&hub).is_ok_and(|h| paths::same_path_here(&h, &top));
        if inside {
            return Err(fail(format!(
                "{} は repo {} の中。ハブは repo の外に作る",
                hub.display(),
                top.display()
            )));
        }
        is_repo = true;
    } else if let Some(git_dir) = git.text(&probe, &["rev-parse", "--absolute-git-dir"]) {
        return Err(fail(format!(
            "{} は git のディレクトリ ({}) の中。ハブは repo の外に作る",
            hub.display(),
            pathx::from_tool(&git_dir).display()
        )));
    }

    let mut current = None;
    let mut skill = None;
    if is_repo {
        let remotes = git.remotes(&hub);
        if !remotes.is_empty() {
            return Err(fail(format!(
                "{} は remote を持つ repo ({})。ハブは remote を持たない (本物の repo はハブにしない)",
                hub.display(),
                remotes.join(", ")
            )));
        }
        let git_dir = git.git_dir(&hub);
        let common = git.common_dir(&hub);
        if let (Some(g), Some(c)) = (&git_dir, &common)
            && !paths::same_path_here(g, c)
        {
            let main = c.parent().unwrap_or(c);
            return Err(fail(format!(
                "{} はハブ {} の worktree。pjp hub init はハブの main の checkout で打つ",
                hub.display(),
                main.display()
            )));
        }
        current = git.config(&hub, ROW_KEY);
        skill = git.config(&hub, SKILL_KEY);
    }

    // ---- まだハブでない DIR に、雛形の外のものや、雛形と違う同じ名前のファイルが無いか
    let mut not_yet = String::new();
    if current.is_none() && hub.is_dir() {
        let foreign = foreign_entries(&hub)?;
        let differs: Vec<&str> = files
            .iter()
            .filter(|t| t.path_in(&hub).exists() && !same_file(t, &hub))
            .map(|t| t.rel)
            .collect();
        if !foreign.is_empty() {
            not_yet.push_str(&format!("雛形の外のものがある: {}。", foreign.join(", ")));
        }
        if !differs.is_empty() {
            not_yet.push_str(&format!(
                "雛形と中身の違うファイルがある: {} (黙って上書きしない)。",
                differs.join(", ")
            ));
        }
    }

    Ok(Survey {
        hub,
        files,
        row,
        is_repo,
        current,
        skill,
        not_yet,
    })
}

/// まだハブでない DIR の中の、雛形の外のもの (名前の順)。`.claude/settings.local.json` は Claude Code がこのマシンの
/// 許可を書くので数えない。
fn foreign_entries(hub: &Path) -> Result<Vec<String>> {
    let mut foreign = Vec::new();
    for name in dir_names(hub)? {
        match name.as_str() {
            ".git" | "CLAUDE.md" | ".gitignore" => {}
            ".claude" => {
                let dot_claude = hub.join(".claude");
                let real_dir = dot_claude
                    .symlink_metadata()
                    .is_ok_and(|m| m.is_dir() && !m.file_type().is_symlink());
                if real_dir {
                    for inner in dir_names(&dot_claude)? {
                        if inner != "settings.json" && inner != "settings.local.json" {
                            foreign.push(format!(".claude/{inner}"));
                        }
                    }
                } else {
                    foreign.push(".claude".to_owned());
                }
            }
            other => foreign.push(other.to_owned()),
        }
    }
    Ok(foreign)
}

fn dir_names(dir: &Path) -> Result<Vec<String>> {
    let entries = std::fs::read_dir(dir)
        .map_err(|e| Error::io(format!("{} を読めません", dir.display()), &e))?;
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    Ok(names)
}

/// `hub` の中のファイルが雛形と同じ中身か (読めない・ディレクトリなら違う)。
fn same_file(t: &Template, hub: &Path) -> bool {
    std::fs::read(t.path_in(hub)).is_ok_and(|b| t.same_as(&b))
}

fn join(items: &[&str]) -> String {
    items.join(", ")
}

/// `--check` の差の行 (無ければ空)。
fn diffs(git: &Git, s: &Survey) -> Vec<String> {
    let mut out = Vec::new();
    if !s.hub.is_dir() {
        out.push(format!("{} が無い", s.hub.display()));
    } else if !s.is_repo {
        out.push(format!("{} は git repo でない", s.hub.display()));
    } else {
        for t in &s.files {
            if !t.path_in(&s.hub).exists() {
                out.push(format!("{} が無い", t.rel));
            } else if !same_file(t, &s.hub) {
                out.push(format!("{} が雛形と違う", t.rel));
            }
        }
        if s.current.is_none() {
            out.push(format!("git config {ROW_KEY} が無い"));
            if s.skill.is_none() {
                out.push(format!("git config {SKILL_KEY} が無い"));
            }
        }
        // 新しい worktree が受け取る HEAD の中身で見る (status では、全体の ignore で add されなかったファイルが見えない)
        let uncommitted: Vec<&str> = s
            .files
            .iter()
            .filter(|t| !committed(git, &s.hub, t))
            .map(|t| t.rel)
            .collect();
        if !uncommitted.is_empty() {
            out.push(format!(
                "commit されていない: {} (HEAD に無いか雛形と違う。commit しないと worktree に入らない)",
                join(&uncommitted)
            ));
        }
    }
    if let Some(why) = s.foreign_hub() {
        out.push(format!("{why}。このままでは pjp hub init は止まる"));
    }
    if !s.not_yet.is_empty() {
        out.push(format!(
            "まだハブでない。{}このままでは pjp hub init は止まる",
            s.not_yet
        ));
    }
    out
}

/// HEAD の中身が雛形と同じか。
fn committed(git: &Git, hub: &Path, t: &Template) -> bool {
    let spec = format!("HEAD:{}", t.rel);
    match git.output(hub, &["cat-file", "blob", spec.as_str()]) {
        Ok(out) if out.success() => t.same_as(out.stdout.as_bytes()),
        _ => false,
    }
}

/// 書く。
fn write(git: &Git, s: &Survey) -> Result<u8> {
    if let Some(why) = s.foreign_hub() {
        // 旧ハブを hc 版に移すときの手。旧ハブを作り直す道具 (dotfiles の setup の bootstrap-herdr-hub が打つ hub-init.sh) を
        // 先に止めないと、次の setup が旧版の雛形に戻す
        let hint = if s.skill.is_none() {
            format!(
                "。hc 版に移すなら、旧ハブを作り直す道具 (dotfiles の bootstrap-herdr-hub の hub-init.sh) を止めてから git -C {} config {SKILL_KEY} {SKILL} を付けて打ち直す",
                s.hub.display()
            )
        } else {
            String::new()
        };
        return Err(fail(format!(
            "{why}。pjp hub init は {SKILL} の雛形を書くので、何も書かずに止まる{hint}"
        )));
    }
    if !s.not_yet.is_empty() {
        return Err(fail(format!(
            "{} はまだハブでない (git config {ROW_KEY} が無い)。{}中身を確かめて移すか消してから打ち直す",
            s.hub.display(),
            s.not_yet
        )));
    }

    let hub = &s.hub;
    let mut changed = false;
    std::fs::create_dir_all(hub)
        .map_err(|e| Error::io(format!("{} を作れません", hub.display()), &e))?;
    if !s.is_repo {
        run_git(git, hub, &["init", "-q", "-b", "main"])?;
        println!("git init した: {} (branch main)", hub.display());
        changed = true;
    }
    for t in &s.files {
        if t.path_in(hub).exists() && same_file(t, hub) {
            println!("同じ: {}", t.rel);
            continue;
        }
        let dst = t.path_in(hub);
        if let Some(dir) = dst.parent() {
            std::fs::create_dir_all(dir)
                .map_err(|e| Error::io(format!("{} を作れません", dir.display()), &e))?;
        }
        std::fs::write(&dst, t.content())
            .map_err(|e| Error::io(format!("{} を書けません", dst.display()), &e))?;
        println!("書いた: {}", t.rel);
        changed = true;
    }
    match &s.current {
        None => {
            run_git(git, hub, &["config", "--local", ROW_KEY, s.row.as_str()])?;
            println!("git config {ROW_KEY} = {} を付けた", s.row);
            changed = true;
        }
        Some(cur) if *cur != s.row => println!(
            "git config {ROW_KEY} = {cur} のまま (pjp hub init が付ける名前は {}。変えるなら git config で直す)",
            s.row
        ),
        Some(cur) => println!("git config {ROW_KEY} = {cur} (そのまま)"),
    }
    if s.skill.is_none() {
        run_git(git, hub, &["config", "--local", SKILL_KEY, SKILL])?;
        println!("git config {SKILL_KEY} = {SKILL} を付けた");
        changed = true;
    }

    let rels: Vec<&str> = s.files.iter().map(|t| t.rel).collect();
    // 改行は LF で index に入れる。CRLF の作業ツリーのファイル (core.autocrlf=true で出したもの) を「同じ」とみて書き直さない
    // ので、そのまま add すると、core.autocrlf が無い repo では CRLF が入り、雛形の変更でない commit ができる。
    // commit もパスを渡すと作業ツリーから入れ直すので、同じ設定を渡す
    const LF_INDEX: [&str; 4] = ["-c", "core.autocrlf=input", "-c", "core.safecrlf=false"];
    // -f: 全体の ignore (core.excludesFile) に .claude/ があっても add する (無いと worktree で hook が効かない)
    let mut add: Vec<&str> = LF_INDEX.to_vec();
    add.extend(["add", "-f", "--"]);
    add.extend(&rels);
    run_git(git, hub, &add)?;
    let mut diff = vec!["diff", "--cached", "--quiet", "--"];
    diff.extend(&rels);
    let staged = git.output(hub, &diff)?;
    match staged.code {
        Some(0) if !staged.timed_out => println!("commit するものは無い"),
        Some(1) if !staged.timed_out => {
            // パスを渡して 3 つだけを commit する (ほかに stage されたものは入れない)。署名と同じく、全体の hook
            // (core.hooksPath の pre-commit など) でも止めない (外に出さない repo に、雛形だけを commit する)
            let mut commit: Vec<&str> = LF_INDEX.to_vec();
            commit.extend(["-c", "commit.gpgsign=false"]);
            let fallback = !has_identity(git, hub);
            let name = format!("user.name={FALLBACK_NAME}");
            let email = format!("user.email={FALLBACK_EMAIL}");
            if fallback {
                commit.extend(["-c", name.as_str(), "-c", email.as_str()]);
            }
            commit.extend(["commit", "-q", "--no-verify", "-m", COMMIT_MESSAGE, "--"]);
            commit.extend(&rels);
            run_git(git, hub, &commit)?;
            let head = git
                .text(hub, &["log", "-1", "--format=%h %s"])
                .unwrap_or_default();
            if fallback {
                println!(
                    "commit した: {head} (git の user.name・user.email が決まらないので、{FALLBACK_NAME} の名前で)"
                );
            } else {
                println!("commit した: {head}");
            }
            changed = true;
        }
        _ => {
            return Err(fail(format!(
                "git diff --cached が落ちました: {}",
                staged.stderr.trim()
            )));
        }
    }
    if changed {
        println!("作り済みの worktree は直さない (雛形の変更は、これから切る worktree から効く)");
    } else {
        println!("{}: 差は無い", hub.display());
    }
    Ok(0)
}

/// git の名前とメールが決まるか (決まらないと commit が落ちる)。
fn has_identity(git: &Git, hub: &Path) -> bool {
    ["GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"]
        .iter()
        .all(|v| git.text(hub, &["var", v]).is_some())
}

/// git を打ち、落ちたら git の文を添えた Err。
fn run_git(git: &Git, dir: &Path, args: &[&str]) -> Result<()> {
    let out = git.output(dir, args)?;
    if out.success() {
        return Ok(());
    }
    let why = if out.timed_out {
        "時間切れ".to_owned()
    } else {
        out.stderr.trim().to_owned()
    };
    Err(fail(format!("git {} が落ちました: {why}", args.join(" "))))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn survey_with(current: Option<&str>, skill: Option<&str>) -> Survey {
        Survey {
            hub: PathBuf::from("hub"),
            files: Vec::new(),
            row: "~/h".to_owned(),
            is_repo: true,
            current: current.map(str::to_owned),
            skill: skill.map(str::to_owned),
            not_yet: String::new(),
        }
    }

    #[test]
    fn foreign_hub_is_only_for_hubs_of_another_skill() {
        assert_eq!(survey_with(None, None).foreign_hub(), None);
        assert_eq!(survey_with(Some("~/h"), Some(SKILL)).foreign_hub(), None);
        let herdr = survey_with(Some("~/h"), None).foreign_hub().unwrap();
        assert!(herdr.contains("pjp-herdr-hub"), "{herdr}");
        let other = survey_with(Some("~/h"), Some("pjp-x-hub"))
            .foreign_hub()
            .unwrap();
        assert!(other.contains("pjp-x-hub"), "{other}");
    }

    #[test]
    fn template_rels_are_the_three_files() {
        let ctx = Context {
            windows_hub: String::new(),
            overlay: None,
        };
        let files = templates::files(&ctx);
        let rels: Vec<&str> = files.iter().map(|t| t.rel).collect();
        assert_eq!(rels, ["CLAUDE.md", ".claude/settings.json", ".gitignore"]);
    }
}
