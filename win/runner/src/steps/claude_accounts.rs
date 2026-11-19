//! claude-accounts (order 99): Windows の claude-<名前> (ログインだけを分けて Windows の Claude Code を起こすコマンド。既定の personal・work と、
//! `claude-account add` で足したアカウント) が使う `%USERPROFILE%\.claude-<名前>\` を用意する。Linux の `nix/scripts/bootstrap-claude-accounts.sh` に当たり、分けるのはログインだけで、
//! CLAUDE.md・skill・hook・設定・履歴と auto memory は素の claude (`~/.claude`) と同じものを使う (dotfiles-private の
//! docs/adr/009_claude_account_config_dirs_*・docs/adr/081_win_claude_accounts_*)。
//!
//! | 置くもの | 形 |
//! | --- | --- |
//! | `settings.json`・`CLAUDE.md` | `~/.claude` へのファイルの symlink (管理者の権限か開発者モードが要る。足りないものを全部のアカウントのぶん集め、直に張れなければ UAC の確認 1 回でまとめて張る) |
//! | `projects` | `~/.claude/projects` への junction (履歴と auto memory) |
//! | `skills\`・`agents\`・`commands\`・`rules\` | 実体の dir。`~/.claude/<種類>` の中身を 1 つずつ (dir は junction、ファイルは記録つきの写し。claude-skills の手順と同じ `Linker`)。skills はリンク・`pjp-*`・runner が書く実体 (hc・herdr-app) だけ、どの種類も `synced`・`manifest.json` は写さない |
//! | `plugins\`・`.credentials.json`・`.claude.json` など | 実体。Claude Code が作る (触らない) |
//! | `%LOCALAPPDATA%\dotfiles\bin\claude-<名前>.exe`・`claude-account.exe` | この runner の exe の写し (exe の名前で launcher・管理のコマンドとして動く。`crate::launcher`・`crate::account_cli`)。動いている exe は上書きできないので、退けてから置く |
//!
//! アカウントは既定 ([`DEFAULT_ACCOUNTS`]) と、`claude-account add` が書く登録 (`crate::accounts`。`%USERPROFILE%\.config\claude-accounts\accounts.json`)。
//! 登録が読めない形なら、登録のアカウントは飛ばして ⚠ を出し、既定は用意する。管理のコマンドの add は、同じ流れ ([`run_accounts`]) を
//! 足したアカウントのぶんだけ流す (dotfiles-private の docs/adr/082_claude_token_accounts_*)。
//!
//! launcher の置き場はユーザーの PATH の末尾に足す (`user_path`。値の型と、ほかの要素の `%VAR%` の書き方は変えない)。足しても、もう動いている
//! process (herdr-app とその中の端末・Claude Code) には効かない。
//!
//! 張る場所の扱いは Linux と同じ: 無い → 張る・正しいリンク → そのまま・別の先のリンク → 張り直す・実体 → 触らずに ⚠ (片付け方は
//! win/README.md の「既に ~/.claude-<名前> があるとき」)。`~/.claude-<名前>` か `~/.claude` がもう一方へのリンクなら、自分自身を指すリンクで
//! `~/.claude` を壊さないよう、そのアカウントは丸ごと飛ばす。check と dry-run は何も書かず、昇格もしない。
//!
//! 記録は `%LOCALAPPDATA%\dotfiles\state\claude-accounts.deployed.json` (写したファイル)。

use super::claude_files::replace_file;
use super::linker::{Linker, Source, Tally};
use super::ps1::{find_powershell, run_streaming};
use super::{Gate, Mode, Outcome, Step, StepInfo, tool_skill, user_path};
use crate::accounts::{self, Registry};
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::link::{
    check_cmd_specials, create_junction, create_symlink_file, is_link, link_target, remove_link,
    same_path,
};
use crate::process::CommandSpec;
use crate::record::Records;
use crate::report::Kind;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// 既定のアカウントの名前 (Linux の claude.nix の accounts と同じ。名前の規則 `accounts::name_ok` に合うことを試験が見る。Linux の
/// claude-accounts.json との突き合わせは tests/claude_parity.rs)
pub const DEFAULT_ACCOUNTS: [&str; 2] = ["personal", "work"];
/// 中身を 1 つずつ写す種類 (Linux の bootstrap-claude-accounts.sh の mirrored_kinds と同じ)
pub const KINDS: [&str; 4] = ["skills", "agents", "commands", "rules"];
/// `~/.claude` へのファイルの symlink にするもの (Linux の shared_links のうちファイルのもの。projects は junction)
pub const SHARED_FILES: [&str; 2] = ["settings.json", "CLAUDE.md"];
/// コピーの記録 (`%LOCALAPPDATA%\dotfiles\state\` の下)
pub const RECORD_FILE: &str = "claude-accounts.deployed.json";
/// launcher の置き場 (`%LOCALAPPDATA%` からの相対。`/` 区切り)。`%USERPROFILE%\.local\bin` は native の installer の claude.exe の置き場で、
/// Install-ClaudeCode が「別の claude」と見る所なので使わない
pub const BIN_DIR_REL: &str = "dotfiles/bin";
/// PATH に足したときに添える文
const NEW_TERMINAL: &str = "PATH は新しい端末から効く。herdr-app とその中の端末・動いている Claude Code には効かないので、herdr-app を上げ直すか、新しい PowerShell で claude-<名前>・claude-account を打つ";
/// 昇格を断られた・出せなかったときの終了コード (ERROR_CANCELLED)
pub const ELEVATE_DECLINED: i32 = 1223;
/// 昇格した cmd で mklink を打つ PowerShell (cmd の引数は env で渡す。cmd は System32 のもの: 同じユーザーが差し替えられる %ComSpec% を、
/// 昇格させる exe に使わない)。Start-Process は昇格した process の出力を受けられないので、張れたかは呼ぶ側が読み直す
const ELEVATE_SCRIPT: &str = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; try { $cmd = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'; $p = Start-Process -FilePath $cmd -ArgumentList $env:DOTFILES_ELEVATE_ARGS -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop; exit $p.ExitCode } catch { Write-Output ('UAC: ' + $_.Exception.Message); exit 1223 }";
/// 実体を見つけたときに添える片付け方
const CLEANUP: &str = "片付け方は win/README.md の「既に ~/.claude-<名前> があるとき」";

/// `~/.claude/<kind>/` の中の `src` を薄い dir へ写すか。Linux の bootstrap-claude-accounts.sh の mirrorable と同じ選び方に、runner が書く
/// skill の実体 (tool_skill の dir。hc・herdr-app) を足したもの。
pub fn mirrorable(kind: &str, src: &Path) -> bool {
    let Some(name) = src.file_name().map(|n| n.to_string_lossy().into_owned()) else {
        return false;
    };
    if name == "synced" || name == "manifest.json" {
        return false;
    }
    if kind != "skills" {
        return true;
    }
    // skills は Claude Code もアカウントごとに実体を置く (synced など) ので、リンク (claude-files・claude-skills が張る)・命名規約どおりの
    // 自作 (pjp-*)・runner が書く実体だけにする
    is_link(src) || name.starts_with("pjp-") || tool_skill::SPECS.iter().any(|s| s.dir == name)
}

/// 張る組 (リンク, 先) を、昇格した cmd の mklink でまとめて張る PowerShell のコマンド。cmd の引数は `/d /c mklink "<link>" "<target>" & …`
/// (1 つ落ちても残りを打つ。張れたかは呼ぶ側が読み直す)。cmd が特別に読む文字を含むパスは断る。
pub fn elevation_command(shell: &Path, jobs: &[(PathBuf, PathBuf)]) -> Result<CommandSpec, String> {
    let paths: Vec<&Path> = jobs
        .iter()
        .flat_map(|(l, t)| [l.as_path(), t.as_path()])
        .collect();
    check_cmd_specials(&paths)?;
    let links: Vec<String> = jobs
        .iter()
        .map(|(l, t)| format!("mklink \"{}\" \"{}\"", l.display(), t.display()))
        .collect();
    Ok(CommandSpec::new(shell)
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(ELEVATE_SCRIPT)
        .env(
            "DOTFILES_ELEVATE_ARGS",
            format!("/d /c {}", links.join(" & ")),
        )
        .timeout(Duration::from_secs(300)))
}

/// 張る場所の今の状態。
#[derive(Debug, PartialEq, Eq)]
enum Place {
    Missing,
    /// 正しい先へのリンク
    Same,
    /// 別の先へのリンク
    Other(PathBuf),
    /// 実体 (リンクでない)
    Real,
}

fn place(link: &Path, target: &Path) -> Place {
    match link_target(link) {
        Some(t) if same_path(&t, target) => Place::Same,
        Some(t) => Place::Other(t),
        None if link.symlink_metadata().is_ok() => Place::Real,
        None => Place::Missing,
    }
}

/// 張るファイルの symlink 1 つ。
struct LinkJob {
    label: String,
    link: PathBuf,
    target: PathBuf,
    /// 別の先を指すリンクがある (外してから張る)
    relink: bool,
}

/// 手順の中で数えるもの (アカウントをまたいで)。
#[derive(Default)]
struct Acc {
    /// 薄い dir の行 (junction・写し・~/.claude の側のリンク先)
    tally: Tally,
    /// まだ張っていない symlink (全部のアカウントを見た後に、1 回で張る)
    jobs: Vec<LinkJob>,
    /// もう正しい symlink
    same_links: usize,
}

impl Acc {
    fn skip(&mut self, ctx: &mut Ctx, why: String) {
        ctx.say(format!("!! 飛ばす: {why}"));
        self.tally.skipped.push(why);
    }

    fn fail(&mut self, ctx: &mut Ctx, why: String) {
        ctx.say(format!("!! {why}"));
        self.tally.errors += 1;
    }

    /// アカウントの Linker が数えたものを足す (飛ばしたものには、頭にアカウントの名前を付ける)。
    fn absorb(&mut self, name: &str, t: Tally) {
        self.tally.added += t.added;
        self.tally.updated += t.updated;
        self.tally.removed += t.removed;
        self.tally.same += t.same;
        self.tally.errors += t.errors;
        self.tally
            .skipped
            .extend(t.skipped.into_iter().map(|s| format!("{name}: {s}")));
    }
}

pub struct ClaudeAccounts;

impl Step for ClaudeAccounts {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-accounts",
            // ~/.claude の側を作る手順 (claude-files・claude-skills (50) と hc-skill・herdr-app-skill (98)) の後。初回の apply で全部写せるように
            order: 99,
            title: "claude-<名前> (既定の personal・work と claude-account add で足したもの) の ~/.claude-<名前> を用意し、claude-<名前>.exe と claude-account.exe を置いてユーザーの PATH に足す (settings.json と CLAUDE.md の symlink は、足りないときだけ UAC の確認が 1 回出る)",
            // Windows の Claude Code を入れないホストでは効かない (Nix の表の requires)
            gate: Gate::AllTools(&["windowsClaudeAccounts", "windowsClaudeCode"]),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let (names, registry_error) = account_names(&ctx.roots.user_profile);
        let mut out = run_accounts(ctx, mode, &names, true);
        if let Some(e) = registry_error {
            ctx.say(format!("!! {e}"));
            out.push(
                Outcome::new(
                    Kind::Manual,
                    "claude-account の登録の一覧が読めないので、足したアカウントは飛ばした (既定は用意した) → ※ を見て直す",
                )
                .note(e),
            );
        }
        out
    }
}

/// 用意するアカウントの名前 (既定のあとに登録を名前の順)。登録が読めなければ既定だけと、わけ
pub fn account_names(home: &Path) -> (Vec<String>, Option<String>) {
    match Registry::load(&accounts::registry_path(home)) {
        Ok(r) => (accounts::all_names(&DEFAULT_ACCOUNTS, &r), None),
        Err(e) => (
            DEFAULT_ACCOUNTS.iter().map(|s| s.to_string()).collect(),
            Some(e),
        ),
    }
}

/// `names` のアカウントの薄い dir・symlink・launcher を揃える (手順の本体。`claude-account add` は足したアカウント 1 つで流す)。
/// `place_manager` なら `claude-account.exe` も置く。締めの表の行を返す
pub fn run_accounts(
    ctx: &mut Ctx,
    mode: Mode,
    names: &[String],
    place_manager: bool,
) -> Vec<Outcome> {
    let home = ctx.roots.user_profile.clone();
    let base = home.join(".claude");
    if !base.is_dir() {
        let why = format!(
            "~/.claude が無い ({}) → claude-files などの手順 (dotfiles apply) が作ってから流し直す",
            base.display()
        );
        ctx.say(format!("!! {why}"));
        return vec![Outcome::new(Kind::Manual, why)];
    }
    let record_path = ctx.state_dir.join(RECORD_FILE);
    let mut records = match Records::load(&record_path) {
        Ok(r) => r,
        Err(e) => {
            ctx.say(format!("!! {e}"));
            return vec![
                Outcome::new(Kind::Failed, "claude-accounts のコピーの記録が壊れている").note(e),
            ];
        }
    };
    let mut acc = Acc::default();
    prepare_base(ctx, mode, &base, &mut acc);
    for name in names {
        records = account(ctx, mode, &home, &base, name, records, &mut acc);
    }
    if mode.writes()
        && let Err(e) = records.save_if_changed()
    {
        let why = format!("コピーの記録を書けない: {} ({e})", record_path.display());
        acc.fail(ctx, why);
    }
    let links = sync_links(ctx, mode, &mut acc);
    let commands = sync_commands(ctx, mode, names, place_manager);
    let mut out = vec![dirs_outcome(mode, &acc.tally, names), links, commands];
    if !acc.tally.skipped.is_empty() {
        let mut o = Outcome::new(
            Kind::Manual,
            format!(
                "飛ばした {} (実体・別の先のリンク・中身の違うコピー) → ※ の名前を見て直す",
                acc.tally.skipped.len()
            ),
        );
        for s in &acc.tally.skipped {
            o = o.note(s.clone());
        }
        out.push(o);
    }
    out
}

/// リンクが切れないよう、`~/.claude` の側のリンク先を用意する (projects は空の dir、settings.json は `{}`。Linux と同じ。CLAUDE.md は
/// claude-files が置く)。
fn prepare_base(ctx: &mut Ctx, mode: Mode, base: &Path, acc: &mut Acc) {
    for (rel, file) in [("projects", None), ("settings.json", Some(&b"{}\n"[..]))] {
        let path = base.join(rel);
        if path.symlink_metadata().is_ok() {
            continue;
        }
        match mode {
            Mode::Check => ctx.say(format!("作る (apply で): ~/.claude/{rel} (リンクの先)")),
            Mode::DryRun { .. } => ctx.say(format!("[dry-run] 作る: ~/.claude/{rel}")),
            Mode::Apply { .. } => {
                let made = match file {
                    None => std::fs::create_dir_all(&path),
                    Some(bytes) => fsutil::write_atomic(&path, bytes),
                };
                if let Err(e) = made {
                    acc.fail(ctx, format!("{} を作れない ({e})", path.display()));
                    continue;
                }
                ctx.say(format!("作りました: ~/.claude/{rel} (リンクの先)"));
            }
        }
        acc.tally.added += 1;
    }
}

/// 1 つのアカウントの薄い dir を揃える。記録は受け取って返す (アカウントをまたいで 1 つのファイル)。
fn account(
    ctx: &mut Ctx,
    mode: Mode,
    home: &Path,
    base: &Path,
    name: &str,
    records: Records,
    acc: &mut Acc,
) -> Records {
    let dir = home.join(format!(".claude-{name}"));
    let shown = format!("~/.claude-{name}");
    ctx.say("");
    ctx.say(format!("==> {}", dir.display()));
    // ~/.claude と同じ場所だと、リンクで ~/.claude 自身を壊してしまう
    if is_link(&dir) {
        acc.skip(
            ctx,
            format!("{name}: {shown} (リンク。実体の dir にしてから流し直す)"),
        );
        return records;
    }
    if dir.is_dir() && same_path(&dir, base) {
        acc.skip(
            ctx,
            format!("{name}: {shown} (~/.claude と同じ場所。~/.claude が {shown} へのリンクになっている)"),
        );
        return records;
    }
    if dir.symlink_metadata().is_err() {
        match mode {
            Mode::Check => ctx.say(format!("作る (apply で): {shown}")),
            Mode::DryRun { .. } => ctx.say(format!("[dry-run] 作る: {shown}")),
            Mode::Apply { .. } => {
                if let Err(e) = std::fs::create_dir_all(&dir) {
                    acc.fail(ctx, format!("{} を作れない ({e})", dir.display()));
                    return records;
                }
                ctx.say(format!("作りました: {shown}"));
            }
        }
    } else if !dir.is_dir() {
        acc.skip(ctx, format!("{name}: {shown} (ディレクトリでない)"));
        return records;
    }
    for file in SHARED_FILES {
        plan_symlink(ctx, name, &dir.join(file), &base.join(file), file, acc);
    }
    link_projects(
        ctx,
        mode,
        name,
        &dir.join("projects"),
        &base.join("projects"),
        acc,
    );
    let src = Source {
        root: base.to_path_buf(),
        prev: None,
        foreign_suffix: None,
        kinds: &KINDS,
        skip_skills: Vec::new(),
        select: Some(mirrorable),
        origin: "~/.claude",
        absorb: "~/.claude",
        step: "claude-accounts",
    };
    let mut w = Linker::new(src, dir, mode, records);
    w.run(ctx);
    acc.absorb(name, std::mem::take(&mut w.tally));
    w.records
}

/// settings.json・CLAUDE.md の symlink の要否を見て、張るものを控える (張るのは全部のアカウントを見た後に 1 回で)。
fn plan_symlink(ctx: &mut Ctx, name: &str, link: &Path, target: &Path, file: &str, acc: &mut Acc) {
    let label = format!("{name}/{file}");
    let relink = match place(link, target) {
        Place::Same => {
            acc.same_links += 1;
            return;
        }
        Place::Real => {
            acc.skip(
                ctx,
                format!("{name}: {file} (実体がある。この dir で先に Claude Code を起動した、など。{CLEANUP})"),
            );
            return;
        }
        Place::Missing => {
            ctx.say(format!("無い (apply で張る。管理者の権限が要る): {label}"));
            false
        }
        Place::Other(t) => {
            ctx.say(format!(
                "別の先を指している (apply で張り直す): {label} (今は -> {})",
                t.display()
            ));
            true
        }
    };
    acc.jobs.push(LinkJob {
        label,
        link: link.to_path_buf(),
        target: target.to_path_buf(),
        relink,
    });
}

/// projects を `~/.claude/projects` への junction にする (権限は要らない)。
fn link_projects(ctx: &mut Ctx, mode: Mode, name: &str, link: &Path, target: &Path, acc: &mut Acc) {
    let label = format!("{name}/projects");
    let relink = match place(link, target) {
        Place::Same => {
            acc.tally.same += 1;
            return;
        }
        Place::Real => {
            acc.skip(
                ctx,
                format!("{name}: projects (実体がある。この dir で先に Claude Code を起動した、など。{CLEANUP})"),
            );
            return;
        }
        Place::Missing => false,
        Place::Other(t) => {
            ctx.say(format!(
                "別の先を指している: {label} (今は -> {})",
                t.display()
            ));
            true
        }
    };
    let todo = if relink { "張り直す" } else { "張る" };
    match mode {
        Mode::Check => ctx.say(format!("{todo} (apply で): {label}")),
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] {todo}: {label} -> {}", target.display()))
        }
        Mode::Apply { .. } => {
            if relink && let Err(e) = remove_link(link) {
                acc.fail(ctx, format!("{label} のリンクを外せない ({e})"));
                return;
            }
            if let Err(e) = create_junction(ctx.sys, link, target) {
                acc.fail(ctx, format!("{label} を張れない ({e})"));
                return;
            }
            ctx.say(format!("張りました: {label} -> {}", target.display()));
        }
    }
    if relink {
        acc.tally.updated += 1;
    } else {
        acc.tally.added += 1;
    }
}

/// settings.json・CLAUDE.md の symlink の行。apply では張る: 別の先のリンクを外し、1 つ目を直に張ってみて (開発者モード・昇格した会話なら
/// 通る)、落ちたら全部を 1 回の昇格で張り、最後に読み直して数える。断られた・出せないときは ⚠ (次の apply でまた聞く)。
fn sync_links(ctx: &mut Ctx, mode: Mode, acc: &mut Acc) -> Outcome {
    const LABEL: &str = "symlink (settings.json・CLAUDE.md)";
    let jobs = std::mem::take(&mut acc.jobs);
    let same = acc.same_links;
    if jobs.is_empty() {
        return Outcome::new(Kind::Ok, format!("{LABEL}: 同じ {same}"));
    }
    let relink = jobs.iter().filter(|j| j.relink).count();
    let add = jobs.len() - relink;
    if !mode.writes() {
        let kind = if relink > 0 { Kind::Fix } else { Kind::Missing };
        let mut text = format!(
            "{LABEL}: 張る {add} / 張り直す {relink} / 同じ {same} → dotfiles apply で張る (管理者の権限が要る。無ければ UAC の確認が 1 回出る)"
        );
        if matches!(mode, Mode::DryRun { .. }) {
            text = format!("[dry-run] {text}");
        }
        return Outcome::new(kind, text);
    }
    let mut notes = Vec::new();
    // 別の先を指すリンクを外す (リンクを消すのに権限は要らない)。外せなかったものは張らない (張れずに UAC を無駄にしない)
    let mut todo: Vec<&LinkJob> = Vec::new();
    for j in &jobs {
        if j.relink
            && let Err(e) = remove_link(&j.link)
            && e.kind() != std::io::ErrorKind::NotFound
        {
            ctx.say(format!("!! {} のリンクを外せない ({e})", j.label));
            notes.push(format!("{} のリンクを外せない ({e})", j.label));
            continue;
        }
        todo.push(j);
    }
    let how = if todo.is_empty() {
        "張れるものが無い"
    } else {
        link_files(ctx, &todo, &mut notes)
    };
    let failed: Vec<&str> = jobs
        .iter()
        .filter(|j| place(&j.link, &j.target) != Place::Same)
        .map(|j| j.label.as_str())
        .collect();
    let done = jobs.len() - failed.len();
    if failed.is_empty() {
        return Outcome::new(
            Kind::Ok,
            format!("{LABEL}: 張った {done} ({how}) / 同じ {same}"),
        );
    }
    let mut o = Outcome::new(
        Kind::Missing,
        format!(
            "{LABEL}: 張れなかった {} / 張った {done} / 同じ {same} → 次の dotfiles apply でまた聞く (ほかは用意した)",
            failed.len()
        ),
    );
    for n in notes {
        o = o.note(n);
    }
    o.note(format!("張れなかったもの: {}", failed.join("・")))
}

/// `todo` (空でない) のファイルの symlink を張る: 1 つ目を直に張ってみて (開発者モード・昇格した会話なら通る)、通れば残りも直に、落ちたら
/// 全部を 1 回の昇格で張る。どう張ったかの言葉を返す。
fn link_files(ctx: &mut Ctx, todo: &[&LinkJob], notes: &mut Vec<String>) -> &'static str {
    match create_symlink_file(ctx.sys, &todo[0].link, &todo[0].target) {
        Ok(()) => {
            ctx.say(format!("張りました: {}", todo[0].label));
            for j in &todo[1..] {
                match create_symlink_file(ctx.sys, &j.link, &j.target) {
                    Ok(()) => ctx.say(format!("張りました: {}", j.label)),
                    Err(e) => notes.push(format!("{} を張れない ({e})", j.label)),
                }
            }
            "権限があったので UAC なし"
        }
        Err(direct) => {
            ctx.say(format!("直には張れない: {direct}"));
            if let Err(e) = elevate(ctx, todo) {
                ctx.say(format!("!! {e}"));
                notes.push(e);
            }
            "UAC で"
        }
    }
}

/// 張るものを全部、1 回の昇格 (UAC の確認) で張る。
fn elevate(ctx: &mut Ctx, jobs: &[&LinkJob]) -> Result<(), String> {
    let Some(shell) = find_powershell(ctx) else {
        return Err("PowerShell が見つからない (pwsh・powershell) ので昇格できない".to_string());
    };
    let pairs: Vec<(PathBuf, PathBuf)> = jobs
        .iter()
        .map(|j| (j.link.clone(), j.target.clone()))
        .collect();
    let spec = elevation_command(&shell, &pairs)?;
    ctx.say(format!(
        "UAC の確認を 1 回出す (settings.json と CLAUDE.md の symlink を {} 個張る)。Windows のデスクトップに確認が出たら「はい」を押す",
        pairs.len()
    ));
    let r = run_streaming(ctx, &spec);
    match r.code() {
        Some(0) => Ok(()),
        Some(ELEVATE_DECLINED) => Err(format!(
            "UAC の確認を断った・出せなかった (SSH の会話など): {}",
            r.output.join(" / ")
        )),
        _ => Err(format!(
            "昇格した mklink が落ちた ({:?}): {}",
            r.exit,
            r.output.join(" / ")
        )),
    }
}

/// ユーザーの PATH の様子。
enum PathState {
    Listed,
    /// apply で足す (check・dry-run)
    ToAdd,
    /// 足した (apply)
    Added,
}

/// launcher の置き場をユーザーの PATH の末尾に足す (入っていれば何もしない)。
fn sync_user_path(ctx: &mut Ctx, mode: Mode, bin: &Path) -> Result<PathState, String> {
    let Some(shell) = find_powershell(ctx) else {
        return Err(
            "PowerShell が見つからない (pwsh・powershell) ので、ユーザーの PATH を確かめられない"
                .to_string(),
        );
    };
    let cur = user_path::read(ctx.sys, &shell)?;
    let sys = ctx.sys;
    let shown = bin.display();
    if user_path::listed(&cur.raw, bin, &|n| sys.env(n)) {
        ctx.say(format!("ユーザーの PATH に入っている: {shown}"));
        return Ok(PathState::Listed);
    }
    match mode {
        Mode::Check => {
            ctx.say(format!("ユーザーの PATH の末尾に足す (apply で): {shown}"));
            Ok(PathState::ToAdd)
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] ユーザーの PATH の末尾に足す: {shown}"));
            Ok(PathState::ToAdd)
        }
        Mode::Apply { .. } => {
            let new = user_path::with_entry(&cur.raw, bin);
            user_path::write(ctx.sys, &shell, &cur.raw, &new)?;
            // PowerShell が 0 で終わっても、読み直して入っていなければ足したと言わない
            let after = user_path::read(ctx.sys, &shell)?;
            if !user_path::listed(&after.raw, bin, &|n| sys.env(n)) {
                return Err(format!(
                    "ユーザーの PATH に書いたはずが、読み直すと {shown} が入っていない (registry への書き込みが止められた、など)"
                ));
            }
            ctx.say(format!("ユーザーの PATH の末尾に足しました: {shown}"));
            Ok(PathState::Added)
        }
    }
}

/// launcher (`claude-<名前>.exe` = この runner の exe の写し) を置き、置き場をユーザーの PATH に足す。中身が違えば置き直す (動いていれば
/// 退けてから置く。退けたものは次に置くときに消す)。
fn sync_commands(ctx: &mut Ctx, mode: Mode, names: &[String], place_manager: bool) -> Outcome {
    let mut commands: Vec<String> = names.iter().map(|n| format!("claude-{n}")).collect();
    if place_manager {
        commands.push(format!("claude-{}", accounts::MANAGER));
    }
    let label = format!("コマンド ({})", commands.join("・"));
    let bin = join_segments(&ctx.roots.local_app_data, BIN_DIR_REL);
    ctx.say("");
    ctx.say(format!("==> {} (launcher)", bin.display()));
    let bytes = match ctx.sys.current_exe() {
        None => Err("runner の exe の場所が分からない".to_string()),
        Some(exe) => std::fs::read(&exe)
            .map_err(|e| format!("runner の exe が読めない: {} ({e})", exe.display())),
    };
    let bytes = match bytes {
        Ok(b) => b,
        Err(why) => {
            ctx.say(format!("!! {why}"));
            return Outcome::new(
                Kind::Failed,
                format!("{label}: {why} (claude-<名前>.exe を置けない)"),
            );
        }
    };
    let want = fsutil::sha256_bytes(&bytes);
    let (mut add, mut update, mut same) = (0, 0, 0);
    let mut errors = Vec::new();
    for command in &commands {
        let dest = bin.join(format!("{command}.exe"));
        let stale = match std::fs::read(&dest) {
            Ok(have) if fsutil::sha256_bytes(&have) == want => {
                same += 1;
                continue;
            }
            Ok(_) => true,
            Err(_) => false,
        };
        let (todo, done) = if stale {
            ("書き直す", "書き直しました")
        } else {
            ("置く", "置きました")
        };
        let shown = dest.display();
        match mode {
            Mode::Check => ctx.say(format!("{todo} (apply で): {shown}")),
            Mode::DryRun { .. } => ctx.say(format!("[dry-run] {todo}: {shown}")),
            Mode::Apply { .. } => {
                if let Err(e) = replace_file(&bytes, &dest) {
                    let why = format!("{shown} を書けない ({e})");
                    ctx.say(format!("!! {why}"));
                    errors.push(why);
                    continue;
                }
                ctx.say(format!("{done}: {shown}"));
            }
        }
        if stale {
            update += 1;
        } else {
            add += 1;
        }
    }
    let path = sync_user_path(ctx, mode, &bin);
    let mut notes = Vec::new();
    let path_text = match &path {
        Ok(PathState::Listed) => "入っている",
        Ok(PathState::ToAdd) => {
            notes.push(format!(
                "置き場 {} をユーザーの PATH の末尾に足す (値の型と、ほかの要素の %VAR% の書き方は変えない)",
                bin.display()
            ));
            "足す"
        }
        Ok(PathState::Added) => {
            notes.push(NEW_TERMINAL.to_string());
            "足した"
        }
        Err(e) => {
            ctx.say(format!("!! {e}"));
            notes.push(e.clone());
            "確かめられない"
        }
    };
    notes.extend(errors.iter().cloned());
    let to_add = matches!(path, Ok(PathState::ToAdd));
    let mut text = if mode.writes() {
        format!("{label}: 置いた {add} / 書き直した {update} / 同じ {same} / PATH: {path_text}")
    } else {
        format!("{label}: 置く {add} / 書き直す {update} / 同じ {same} / PATH: {path_text}")
    };
    if !mode.writes() && (add + update > 0 || to_add) {
        text.push_str(" → dotfiles apply で揃える");
    }
    if matches!(mode, Mode::DryRun { .. }) {
        text = format!("[dry-run] {text}");
    }
    let kind = if !errors.is_empty() || path.is_err() {
        Kind::Failed
    } else if mode.writes() {
        Kind::Ok
    } else if update > 0 {
        Kind::Fix
    } else if add > 0 || to_add {
        Kind::Missing
    } else {
        Kind::Ok
    };
    let mut o = Outcome::new(kind, text);
    for n in notes {
        o = o.note(n);
    }
    o
}

/// 薄い dir の行 (junction・写し・`~/.claude` の側のリンク先)。
fn dirs_outcome(mode: Mode, t: &Tally, accounts: &[String]) -> Outcome {
    let names: Vec<String> = accounts.iter().map(|n| format!("~/.claude-{n}")).collect();
    let mut text = format!(
        "{}: 追加 {} / 更新 {} / 削除 {} / 同じ {} / 飛ばした {}",
        names.join("・"),
        t.added,
        t.updated,
        t.removed,
        t.same,
        t.skipped.len()
    );
    if t.errors > 0 {
        text.push_str(&format!(" / エラー {}", t.errors));
    }
    if matches!(mode, Mode::DryRun { .. }) {
        text = format!("[dry-run] {text}");
    }
    let kind = if t.errors > 0 {
        Kind::Failed
    } else if mode.writes() {
        Kind::Ok
    } else if t.updated + t.removed > 0 {
        Kind::Fix
    } else if t.added > 0 {
        Kind::Missing
    } else {
        Kind::Ok
    };
    Outcome::new(kind, text)
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (Linux の nix/tests/bootstrap-claude-accounts.test.sh と同じ分かれ道を、Windows の張り方で)
    //!
    //! - check と dry-run は何も書かず、mklink も昇格のコマンドも打たない。symlink の行に「UAC の確認が 1 回出る」
    //! - apply で両方のアカウントに settings.json・CLAUDE.md の symlink・projects の junction・skills の junction (リンク・pjp-*・runner が
    //!   書く hc)・rules の写しができる。skills の手で置いた実体・synced・manifest.json は写さない。2 回目の check は全部 ✔
    //! - 直に張れなければ、全部のアカウントのぶんを 1 回の昇格で張る。昇格を断られたら symlink の行だけ ⚠ (次の apply でまた聞く)
    //! - 薄い dir の実体 (settings.json・projects/) は触らずに ⚠。別の先の symlink は張り直す
    //! - 薄い dir が ~/.claude へのリンク・~/.claude が薄い dir へのリンクなら、そのアカウントは丸ごと飛ばし、~/.claude に何も足さない
    //! - ~/.claude から消えたものは片付ける。~/.claude/projects と settings.json が無ければ作る
    //! - 昇格のコマンドの形 (cmd の引数・特殊文字を断る)。アカウントの名前は launcher の名前の規則に合う

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::link::{create_junction, is_link, link_target, same_path};
    use crate::manifest::Roots;
    use crate::process::{Exit, RunResult};
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir, fake_file_symlink, fake_mklink};
    use std::cell::{Cell, RefCell};
    use std::rc::Rc;
    use std::time::Duration;

    /// 昇格 (UAC) の偽物のふるまい
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Uac {
        /// 直の mklink が通る (開発者モード・昇格した会話)。昇格は打たれない
        NotNeeded,
        /// 直の mklink は権限が無くて落ち、昇格で張れる
        Accept,
        /// 直の mklink は落ち、昇格は断られる
        Decline,
    }

    /// `/d /c mklink "<link>" "<target>" & mklink …` から組を拾う (偽の昇格が張るため)
    fn parse_mklinks(args: &str) -> Vec<(String, String)> {
        let rest = args.strip_prefix("/d /c ").expect("/d /c で始まる");
        rest.split(" & ")
            .map(|part| {
                let q: Vec<&str> = part
                    .strip_prefix("mklink ")
                    .expect("mklink")
                    .split('"')
                    .collect();
                // ["", link, " ", target, ""]
                assert_eq!(q.len(), 5, "{part}");
                (q[1].to_string(), q[3].to_string())
            })
            .collect()
    }

    /// 偽の外のコマンド: mklink (junction とファイルの symlink)・昇格・ユーザーの PATH (`reg` を registry の Path の生の値として読み書き
    /// する)。current_exe は `exe`、%LOCALAPPDATA% は `local`
    fn fake(
        uac: Uac,
        reg: Rc<RefCell<String>>,
        sticky: Rc<Cell<bool>>,
        exe: &Path,
        local: &Path,
    ) -> FakeSys {
        FakeSys::new(move |c| {
            let args = c.args_lossy();
            if args.len() == 4 && args[1] == "mklink" && uac != Uac::NotNeeded {
                return RunResult {
                    exit: Exit::Code(1),
                    output: vec!["この操作を実行するための十分な特権がありません。".to_string()],
                };
            }
            if let Some(r) = fake_mklink(c) {
                return r;
            }
            if let Some(a) = c.env_value("DOTFILES_ELEVATE_ARGS") {
                assert_ne!(uac, Uac::NotNeeded, "直に張れるのに昇格した");
                if uac == Uac::Decline {
                    return RunResult {
                        exit: Exit::Code(1223),
                        output: vec!["UAC: The operation was canceled by the user.".to_string()],
                    };
                }
                // cmd の & と同じく、落ちたものがあっても残りも張り、終了コードは最後のもの
                let mut last = Exit::Code(0);
                for (l, t) in parse_mklinks(&a) {
                    last = fake_file_symlink(&l, &t).exit;
                }
                return RunResult {
                    exit: last,
                    output: Vec::new(),
                };
            }
            if let Some(new) = c.env_value("DOTFILES_USER_PATH_NEW") {
                let old = c.env_value("DOTFILES_USER_PATH_OLD").unwrap_or_default();
                if *reg.borrow() != old {
                    return RunResult {
                        exit: Exit::Code(3),
                        output: vec!["changed".to_string()],
                    };
                }
                // 書き込みが止められた registry を真似るときは、0 を返しても値を変えない
                if sticky.get() {
                    *reg.borrow_mut() = new;
                }
                return RunResult {
                    exit: Exit::Code(0),
                    output: Vec::new(),
                };
            }
            if args
                .last()
                .is_some_and(|a| a.contains("DoNotExpandEnvironmentNames"))
            {
                return RunResult {
                    exit: Exit::Code(0),
                    output: vec![
                        "kind=ExpandString".to_string(),
                        format!("raw={}", reg.borrow()),
                    ],
                };
            }
            panic!("知らないコマンド: {:?} {args:?}", c.program);
        })
        .with_program("pwsh", "pwsh")
        .with_env("ComSpec", "C:\\Windows\\system32\\cmd.exe")
        .with_env("LOCALAPPDATA", &local.to_string_lossy())
        .with_exe(exe)
    }

    /// ファイルの symlink を張れる環境か (Windows で開発者モードでも昇格もしていないと張れない。張れなければ試験を飛ばす)
    fn file_symlinks_work(t: &TempDir) -> bool {
        let target = t.write("probe/target", "x");
        let link = t.path().join("probe").join("link");
        let ok = fake_file_symlink(&link.to_string_lossy(), &target.to_string_lossy()).exit
            == Exit::Code(0);
        let _ = std::fs::remove_file(&link);
        if !ok {
            eprintln!("ファイルの symlink を張る権限が無いので飛ばす");
        }
        ok
    }

    struct Env {
        t: TempDir,
        /// registry のユーザーの PATH の生の値 (偽物が読み書きする)
        reg: Rc<RefCell<String>>,
        /// 偽物の PATH の書き込みが値を変えるか (false で、書き込みが止められた registry を真似る)
        sticky: Rc<Cell<bool>>,
    }

    impl Env {
        /// ~/.claude を作らない家 (runner の exe と、PATH が C:\Windows だけの registry を持つ)
        fn bare(t: TempDir) -> Self {
            t.write("exe/dotfiles-win.exe", "runner-v1");
            Env {
                t,
                reg: Rc::new(RefCell::new("C:\\Windows".to_string())),
                sticky: Rc::new(Cell::new(true)),
            }
        }

        fn new() -> Self {
            let t = TempDir::new("claude-accounts");
            t.write("home/.claude/settings.json", "{\"theme\":\"dark\"}\n");
            t.write("home/.claude/CLAUDE.md", "# 指示\n");
            t.write("home/.claude/projects/p1/s.jsonl", "{}\n");
            // claude-skills の clone への junction (claude-skills の手順が張る)・runner が書く実体 (hc)・手で置いた実体・配信の実体
            t.write("g/claude-skills/skills/pjp-a/SKILL.md", "a\n");
            t.write("home/.claude/skills/hc/SKILL.md", "hc\n");
            t.write("home/.claude/skills/mine/SKILL.md", "mine\n");
            t.write("home/.claude/skills/synced/x/SKILL.md", "s\n");
            t.write("home/.claude/skills/manifest.json", "{}\n");
            t.write("home/.claude/rules/pjp-r.md", "rule\n");
            let e = Env::bare(t);
            let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
            create_junction(
                &sys,
                &e.claude("skills/pjp-a"),
                &e.t.path()
                    .join("g")
                    .join("claude-skills")
                    .join("skills")
                    .join("pjp-a"),
            )
            .unwrap();
            e
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn fake(&self, uac: Uac) -> FakeSys {
            fake(
                uac,
                self.reg.clone(),
                self.sticky.clone(),
                &self.exe(),
                &self.local(),
            )
        }

        fn exe(&self) -> PathBuf {
            self.t.path().join("exe").join("dotfiles-win.exe")
        }

        /// %LOCALAPPDATA% (Roots::from_home と同じ)
        fn local(&self) -> PathBuf {
            self.home().join("AppData").join("Local")
        }

        fn bin(&self, name: &str) -> PathBuf {
            self.local()
                .join("dotfiles")
                .join("bin")
                .join(format!("claude-{name}.exe"))
        }

        fn claude(&self, rel: &str) -> PathBuf {
            crate::context::join_segments(&self.home().join(".claude"), rel)
        }

        fn dir(&self, name: &str, rel: &str) -> PathBuf {
            crate::context::join_segments(&self.home().join(format!(".claude-{name}")), rel)
        }

        fn run(&self, mode: Mode, sys: &FakeSys) -> (Vec<Outcome>, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("g").join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys,
                    out: &mut out,
                };
                ClaudeAccounts.run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        }
    }

    /// 文がこれで始まる行
    fn row<'a>(o: &'a [Outcome], head: &str) -> &'a Outcome {
        o.iter()
            .find(|x| x.text.starts_with(head) || x.text.starts_with(&format!("[dry-run] {head}")))
            .unwrap_or_else(|| panic!("{head} の行が無い: {o:?}"))
    }

    const DIRS: &str = "~/.claude-personal・~/.claude-work:";
    const LINKS: &str = "symlink (settings.json・CLAUDE.md):";
    const COMMANDS: &str = "コマンド (claude-personal・claude-work・claude-account):";

    fn path_writes(sys: &FakeSys) -> usize {
        sys.calls
            .borrow()
            .iter()
            .filter(|c| c.env_value("DOTFILES_USER_PATH_NEW").is_some())
            .count()
    }

    fn elevated(sys: &FakeSys) -> usize {
        sys.calls
            .borrow()
            .iter()
            .filter(|c| c.env_value("DOTFILES_ELEVATE_ARGS").is_some())
            .count()
    }

    fn mklinks(sys: &FakeSys) -> usize {
        sys.calls
            .borrow()
            .iter()
            .filter(|c| c.args_lossy().get(1).is_some_and(|a| a == "mklink"))
            .count()
    }

    #[test]
    fn accounts_follow_the_name_rule() {
        for name in DEFAULT_ACCOUNTS {
            assert!(crate::accounts::name_ok(name), "{name}");
        }
    }

    #[test]
    fn info_runs_after_the_tool_skills() {
        let i = ClaudeAccounts.info();
        assert_eq!(
            (i.id, i.order, i.windows_only, i.ported),
            ("claude-accounts", 99, true, true)
        );
        assert_eq!(
            i.gate,
            Gate::AllTools(&["windowsClaudeAccounts", "windowsClaudeCode"])
        );
    }

    #[test]
    fn check_and_dry_run_write_nothing() {
        let e = Env::new();
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let sys = e.fake(Uac::Accept);
            let (o, out) = e.run(mode, &sys);
            assert_eq!(row(&o, DIRS).kind, Kind::Missing, "{mode:?} {o:?}\n{out}");
            let links = row(&o, LINKS);
            assert_eq!(links.kind, Kind::Missing, "{o:?}");
            assert!(links.text.contains("張る 4"), "{links:?}");
            assert!(links.text.contains("UAC の確認が 1 回出る"), "{links:?}");
            assert!(!e.dir("personal", "").exists());
            assert!(!e.dir("work", "").exists());
            assert_eq!((mklinks(&sys), elevated(&sys)), (0, 0), "{mode:?}");
            let cmds = row(&o, COMMANDS);
            assert_eq!(cmds.kind, Kind::Missing, "{cmds:?}");
            assert!(cmds.text.contains("置く 3"), "{cmds:?}");
            assert!(cmds.text.contains("PATH: 足す"), "{cmds:?}");
            assert_eq!(path_writes(&sys), 0);
            assert!(!e.bin("work").exists());
            assert_eq!(*e.reg.borrow(), "C:\\Windows");
        }
    }

    #[test]
    fn apply_builds_thin_dirs() {
        let e = Env::new();
        if !file_symlinks_work(&e.t) {
            return;
        }
        let sys = e.fake(Uac::NotNeeded);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        assert_eq!(row(&o, DIRS).kind, Kind::Ok, "{o:?}\n{out}");
        assert_eq!(row(&o, LINKS).kind, Kind::Ok, "{o:?}\n{out}");
        assert!(row(&o, LINKS).text.contains("張った 4"), "{o:?}");
        assert!(!o.iter().any(|x| x.kind == Kind::Manual), "{o:?}");
        assert_eq!(elevated(&sys), 0);
        for name in DEFAULT_ACCOUNTS {
            for f in ["settings.json", "CLAUDE.md"] {
                assert!(
                    same_path(&link_target(&e.dir(name, f)).unwrap(), &e.claude(f)),
                    "{name}/{f}"
                );
            }
            assert!(same_path(
                &link_target(&e.dir(name, "projects")).unwrap(),
                &e.claude("projects")
            ));
            for s in ["pjp-a", "hc"] {
                assert!(
                    same_path(
                        &link_target(&e.dir(name, &format!("skills/{s}"))).unwrap(),
                        &e.claude(&format!("skills/{s}"))
                    ),
                    "{name}/skills/{s}"
                );
            }
            for s in ["mine", "synced", "manifest.json"] {
                assert!(
                    std::fs::symlink_metadata(e.dir(name, &format!("skills/{s}"))).is_err(),
                    "{name}/skills/{s} は写さない"
                );
            }
            assert!(!is_link(&e.dir(name, "rules/pjp-r.md")));
            assert_eq!(
                std::fs::read_to_string(e.dir(name, "rules/pjp-r.md")).unwrap(),
                "rule\n"
            );
            // 写した skill は読める (リンクのリンク)
            assert_eq!(
                std::fs::read_to_string(e.dir(name, "skills/pjp-a/SKILL.md")).unwrap(),
                "a\n"
            );
        }
        let record = std::fs::read_to_string(e.t.path().join("state").join(RECORD_FILE)).unwrap();
        assert_eq!(record.matches("pjp-r.md").count(), 2, "{record}");
        // ~/.claude の中身は変えない
        assert_eq!(
            std::fs::read_to_string(e.claude("settings.json")).unwrap(),
            "{\"theme\":\"dark\"}\n"
        );

        let sys = e.fake(Uac::Accept);
        let (o, out) = e.run(Mode::Check, &sys);
        assert_eq!(row(&o, DIRS).kind, Kind::Ok, "{o:?}\n{out}");
        assert_eq!(row(&o, LINKS).kind, Kind::Ok, "{o:?}");
        assert!(row(&o, LINKS).text.contains("同じ 4"), "{o:?}");
    }

    #[test]
    fn elevates_once_for_all_accounts() {
        let e = Env::new();
        if !file_symlinks_work(&e.t) {
            return;
        }
        let sys = e.fake(Uac::Accept);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        assert_eq!(row(&o, LINKS).kind, Kind::Ok, "{o:?}\n{out}");
        assert_eq!(elevated(&sys), 1);
        // 直に試したのは 1 つ目だけ
        let file_mklinks = sys
            .calls
            .borrow()
            .iter()
            .filter(|c| c.args_lossy().len() == 4 && c.args_lossy()[1] == "mklink")
            .count();
        assert_eq!(file_mklinks, 1);
        assert!(out.contains("UAC の確認を 1 回出す"), "{out}");
        for name in DEFAULT_ACCOUNTS {
            for f in ["settings.json", "CLAUDE.md"] {
                assert!(same_path(
                    &link_target(&e.dir(name, f)).unwrap(),
                    &e.claude(f)
                ));
            }
        }
        // 2 回目の apply は昇格しない
        let sys = e.fake(Uac::Accept);
        let (o, _) = e.run(Mode::Apply { force: false }, &sys);
        assert_eq!(row(&o, LINKS).kind, Kind::Ok);
        assert_eq!((elevated(&sys), mklinks(&sys)), (0, 0));
    }

    #[test]
    fn declined_uac_keeps_the_rest() {
        let e = Env::new();
        let sys = e.fake(Uac::Decline);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        let links = row(&o, LINKS);
        assert_eq!(links.kind, Kind::Missing, "{o:?}\n{out}");
        assert!(
            links.text.contains("次の dotfiles apply でまた聞く"),
            "{links:?}"
        );
        assert!(
            links
                .notes
                .iter()
                .any(|n| n.contains("canceled by the user")),
            "{links:?}"
        );
        assert_eq!(row(&o, DIRS).kind, Kind::Ok, "{o:?}");
        assert!(is_link(&e.dir("work", "projects")));
        assert!(e.dir("work", "rules/pjp-r.md").is_file());
        assert!(std::fs::symlink_metadata(e.dir("work", "settings.json")).is_err());
    }

    #[test]
    fn real_files_are_left_alone() {
        let e = Env::new();
        e.t.write("home/.claude-work/settings.json", "{\"mine\":1}\n");
        e.t.write("home/.claude-work/projects/q/s.jsonl", "{}\n");
        let sys = e.fake(Uac::Decline);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        let manual = o
            .iter()
            .find(|x| x.kind == Kind::Manual)
            .unwrap_or_else(|| panic!("{o:?}\n{out}"));
        for head in [
            "work: settings.json (実体がある",
            "work: projects (実体がある",
        ] {
            assert!(
                manual
                    .notes
                    .iter()
                    .any(|n| n.starts_with(head) && n.contains("既に ~/.claude-<名前> があるとき")),
                "{head}: {manual:?}"
            );
        }
        assert_eq!(
            std::fs::read_to_string(e.dir("work", "settings.json")).unwrap(),
            "{\"mine\":1}\n"
        );
        assert!(!is_link(&e.dir("work", "projects")));
        assert!(e.dir("work", "projects/q/s.jsonl").is_file());
        // personal は用意する (symlink は昇格を断られたので無い)
        assert!(is_link(&e.dir("personal", "projects")));
    }

    #[test]
    fn skips_an_account_dir_that_links_to_base() {
        let e = Env::new();
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        create_junction(&sys, &e.dir("work", ""), &e.claude("")).unwrap();
        let before: Vec<String> = names(&e.claude(""));
        let sys = e.fake(Uac::Decline);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        let manual = o
            .iter()
            .find(|x| x.kind == Kind::Manual)
            .unwrap_or_else(|| panic!("{o:?}\n{out}"));
        assert!(
            manual
                .notes
                .iter()
                .any(|n| n.starts_with("work: ~/.claude-work (リンク")),
            "{manual:?}"
        );
        assert_eq!(names(&e.claude("")), before, "~/.claude に何も足さない");
        assert_eq!(
            std::fs::read_to_string(e.claude("settings.json")).unwrap(),
            "{\"theme\":\"dark\"}\n"
        );
    }

    #[test]
    fn skips_an_account_when_base_links_to_it() {
        let t = TempDir::new("claude-accounts-base-link");
        t.write("home/.claude-work/settings.json", "{}\n");
        t.write("home/.claude-work/CLAUDE.md", "# 指示\n");
        let sys = FakeSys::new(|c| fake_mklink(c).unwrap());
        create_junction(
            &sys,
            &t.path().join("home").join(".claude"),
            &t.path().join("home").join(".claude-work"),
        )
        .unwrap();
        let e = Env::bare(t);
        let sys = e.fake(Uac::Decline);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        let manual = o
            .iter()
            .find(|x| x.kind == Kind::Manual)
            .unwrap_or_else(|| panic!("{o:?}\n{out}"));
        assert!(
            manual
                .notes
                .iter()
                .any(|n| n.starts_with("work: ~/.claude-work (~/.claude と同じ場所")),
            "{manual:?}"
        );
        // 自分自身を指すリンクで壊さない
        assert!(!is_link(&e.dir("work", "settings.json")));
        assert!(!is_link(&e.dir("work", "projects")));
    }

    #[test]
    fn relinks_a_symlink_to_elsewhere() {
        let e = Env::new();
        if !file_symlinks_work(&e.t) {
            return;
        }
        let other = e.t.write("home/other.json", "{\"other\":1}\n");
        std::fs::create_dir_all(e.dir("work", "")).unwrap();
        let r = fake_file_symlink(
            &e.dir("work", "settings.json").to_string_lossy(),
            &other.to_string_lossy(),
        );
        assert_eq!(r.exit, Exit::Code(0));
        let sys = e.fake(Uac::Accept);
        let (o, _) = e.run(Mode::Check, &sys);
        let links = row(&o, LINKS);
        assert_eq!(links.kind, Kind::Fix, "{o:?}");
        assert!(links.text.contains("張り直す 1"), "{links:?}");
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        assert_eq!(row(&o, LINKS).kind, Kind::Ok, "{o:?}\n{out}");
        assert!(same_path(
            &link_target(&e.dir("work", "settings.json")).unwrap(),
            &e.claude("settings.json")
        ));
        assert_eq!(std::fs::read_to_string(&other).unwrap(), "{\"other\":1}\n");
    }

    #[test]
    fn prunes_mirrors_gone_from_base() {
        let e = Env::new();
        let sys = e.fake(Uac::Decline);
        e.run(Mode::Apply { force: false }, &sys);
        assert!(is_link(&e.dir("work", "skills/pjp-a")));
        crate::link::remove_link(&e.claude("skills/pjp-a")).unwrap();
        std::fs::remove_file(e.claude("rules/pjp-r.md")).unwrap();
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        assert!(row(&o, DIRS).text.contains("削除 4"), "{o:?}\n{out}");
        for name in DEFAULT_ACCOUNTS {
            assert!(std::fs::symlink_metadata(e.dir(name, "skills/pjp-a")).is_err());
            assert!(!e.dir(name, "rules/pjp-r.md").exists());
        }
        // 元 (clone の中身) は消さない
        assert!(
            e.t.path()
                .join("g/claude-skills/skills/pjp-a/SKILL.md")
                .is_file()
        );
    }

    #[test]
    fn creates_base_projects_and_settings() {
        let e = Env::new();
        std::fs::remove_dir_all(e.claude("projects")).unwrap();
        std::fs::remove_file(e.claude("settings.json")).unwrap();
        let sys = e.fake(Uac::Decline);
        let (o, out) = e.run(Mode::Check, &sys);
        assert_eq!(row(&o, DIRS).kind, Kind::Missing, "{o:?}\n{out}");
        assert!(!e.claude("projects").exists() && !e.claude("settings.json").exists());
        e.run(Mode::Apply { force: false }, &sys);
        assert!(e.claude("projects").is_dir());
        assert_eq!(
            std::fs::read_to_string(e.claude("settings.json")).unwrap(),
            "{}\n"
        );
        assert!(same_path(
            &link_target(&e.dir("work", "projects")).unwrap(),
            &e.claude("projects")
        ));
    }

    #[test]
    fn missing_base_is_manual() {
        let t = TempDir::new("claude-accounts-no-base");
        std::fs::create_dir_all(t.path().join("home")).unwrap();
        let e = Env::bare(t);
        let sys = e.fake(Uac::Decline);
        let (o, _) = e.run(Mode::Apply { force: false }, &sys);
        assert_eq!(o.len(), 1, "{o:?}");
        assert_eq!(o[0].kind, Kind::Manual);
        assert!(o[0].text.contains("~/.claude が無い"), "{o:?}");
        assert!(!e.dir("work", "").exists());
    }

    #[test]
    fn mirrorable_picks_links_pjp_and_runner_skills() {
        let e = Env::new();
        let m = |kind: &str, rel: &str| mirrorable(kind, &e.claude(rel));
        assert!(m("skills", "skills/pjp-a"));
        assert!(m("skills", "skills/hc"));
        assert!(m("skills", "skills/herdr-app"));
        assert!(m("skills", "skills/pjp-local"));
        assert!(!m("skills", "skills/mine"));
        assert!(!m("skills", "skills/synced"));
        assert!(!m("skills", "skills/manifest.json"));
        assert!(m("rules", "rules/anything.md"));
        assert!(!m("rules", "rules/synced"));
        assert!(!m("agents", "agents/manifest.json"));
    }

    #[test]
    fn elevation_command_quotes_paths() {
        let pairs = vec![
            (
                PathBuf::from("C:\\Users\\a b\\.claude-personal\\settings.json"),
                PathBuf::from("C:\\Users\\a b\\.claude\\settings.json"),
            ),
            (
                PathBuf::from("C:\\Users\\a b\\.claude-work\\CLAUDE.md"),
                PathBuf::from("C:\\Users\\a b\\.claude\\CLAUDE.md"),
            ),
        ];
        let c = elevation_command(Path::new("C:\\pwsh\\pwsh.exe"), &pairs).unwrap();
        assert_eq!(c.program, PathBuf::from("C:\\pwsh\\pwsh.exe"));
        assert_eq!(
            c.env_value("DOTFILES_ELEVATE_ARGS").unwrap(),
            "/d /c mklink \"C:\\Users\\a b\\.claude-personal\\settings.json\" \"C:\\Users\\a b\\.claude\\settings.json\" & mklink \"C:\\Users\\a b\\.claude-work\\CLAUDE.md\" \"C:\\Users\\a b\\.claude\\CLAUDE.md\""
        );
        // 昇格させる cmd は System32 のもの (同じユーザーが差し替えられる %ComSpec% を見ない)
        assert_eq!(c.env_value("DOTFILES_ELEVATE_FILE"), None);
        let args = c.args_lossy();
        assert_eq!(
            &args[..5],
            [
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command"
            ]
        );
        assert!(
            args[5].contains("Join-Path ([Environment]::SystemDirectory) 'cmd.exe'"),
            "{}",
            args[5]
        );
        assert!(
            args[5].contains("-ArgumentList $env:DOTFILES_ELEVATE_ARGS -Verb RunAs"),
            "{}",
            args[5]
        );
        assert!(!args[5].contains("ComSpec"), "{}", args[5]);
        assert!(args[5].contains("exit 1223"), "{}", args[5]);
        assert_eq!(c.timeout, Some(Duration::from_secs(300)));
        let bad = vec![(
            PathBuf::from("C:\\Users\\a%b\\.claude-work\\settings.json"),
            PathBuf::from("C:\\Users\\a%b\\.claude\\settings.json"),
        )];
        let e = elevation_command(Path::new("pwsh"), &bad).unwrap_err();
        assert!(e.contains("cmd が特別に読む文字 (%)"), "{e}");
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn places_launchers_and_adds_path() {
        let e = Env::new();
        let sys = e.fake(Uac::Decline);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        let cmds = row(&o, COMMANDS);
        assert_eq!(cmds.kind, Kind::Ok, "{o:?}\n{out}");
        assert!(cmds.text.contains("置いた 3"), "{cmds:?}");
        assert!(cmds.text.contains("PATH: 足した"), "{cmds:?}");
        assert!(
            cmds.notes.iter().any(|n| n.contains("新しい端末から効く")),
            "{cmds:?}"
        );
        for name in DEFAULT_ACCOUNTS.iter().chain(&[crate::accounts::MANAGER]) {
            assert_eq!(std::fs::read(e.bin(name)).unwrap(), b"runner-v1", "{name}");
        }
        let bin_dir = e.local().join("dotfiles").join("bin");
        assert_eq!(
            *e.reg.borrow(),
            format!("C:\\Windows;{}", bin_dir.display())
        );
        assert_eq!(path_writes(&sys), 1);
        // 2 回目は同じ (PATH も書かない)
        let sys = e.fake(Uac::Decline);
        let (o, _) = e.run(Mode::Apply { force: false }, &sys);
        let cmds = row(&o, COMMANDS);
        assert_eq!(cmds.kind, Kind::Ok, "{cmds:?}");
        assert!(cmds.text.contains("同じ 3"), "{cmds:?}");
        assert!(cmds.text.contains("PATH: 入っている"), "{cmds:?}");
        assert_eq!(path_writes(&sys), 0);
    }

    #[test]
    fn rewrites_stale_launchers() {
        let e = Env::new();
        e.t.write(
            "home/AppData/Local/dotfiles/bin/claude-work.exe",
            "runner-v0",
        );
        // 別の書き方 (%VAR%・末尾の区切り) で入っていれば足さない
        *e.reg.borrow_mut() = "C:\\Windows;%LOCALAPPDATA%\\dotfiles\\bin\\".to_string();
        let sys = e.fake(Uac::Decline);
        let (o, _) = e.run(Mode::Check, &sys);
        let cmds = row(&o, COMMANDS);
        assert_eq!(cmds.kind, Kind::Fix, "{cmds:?}");
        assert!(cmds.text.contains("置く 2 / 書き直す 1"), "{cmds:?}");
        assert!(cmds.text.contains("PATH: 入っている"), "{cmds:?}");
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        assert_eq!(row(&o, COMMANDS).kind, Kind::Ok, "{o:?}\n{out}");
        assert_eq!(std::fs::read(e.bin("work")).unwrap(), b"runner-v1");
        assert_eq!(path_writes(&sys), 0);
    }

    #[test]
    fn unreadable_exe_fails_the_commands_row() {
        let e = Env::new();
        std::fs::remove_file(e.exe()).unwrap();
        let sys = e.fake(Uac::Decline);
        let (o, _) = e.run(Mode::Apply { force: false }, &sys);
        let cmds = row(&o, COMMANDS);
        assert_eq!(cmds.kind, Kind::Failed, "{cmds:?}");
        assert!(cmds.text.contains("runner の exe が読めない"), "{cmds:?}");
        // ほかは用意する
        assert_eq!(row(&o, DIRS).kind, Kind::Ok, "{o:?}");
    }

    /// PowerShell が 0 で終わっても、読み直して入っていなければ「足した」と言わない (書き込みを止められた registry など)
    #[test]
    fn path_write_that_does_not_stick_fails() {
        let e = Env::new();
        e.sticky.set(false);
        let sys = e.fake(Uac::Decline);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        let cmds = row(&o, COMMANDS);
        assert_eq!(cmds.kind, Kind::Failed, "{cmds:?}\n{out}");
        assert!(
            cmds.notes.iter().any(|n| n.contains("読み直すと")),
            "{cmds:?}"
        );
        assert!(!out.contains("末尾に足しました"), "{out}");
    }

    /// 別の先を指す symlink を外せなければ、それは張らずに知らせ、ほかは 1 回の昇格で張る (外せなかったもので UAC を無駄にしない)
    #[cfg(unix)]
    #[test]
    fn skips_links_it_cannot_remove() {
        use std::os::unix::fs::PermissionsExt;
        let e = Env::new();
        let other = e.t.write("home/other.json", "{}\n");
        let work = e.dir("work", "");
        std::fs::create_dir_all(&work).unwrap();
        std::os::unix::fs::symlink(&other, e.dir("work", "settings.json")).unwrap();
        std::fs::set_permissions(&work, std::fs::Permissions::from_mode(0o555)).unwrap();
        // root は読み取りだけの dir でも消せるので、この試験にならない
        let probe = work.join("probe");
        if std::fs::write(&probe, "x").is_ok() {
            let _ = std::fs::remove_file(&probe);
            std::fs::set_permissions(&work, std::fs::Permissions::from_mode(0o755)).unwrap();
            eprintln!("読み取りだけの dir に書けた (root) ので飛ばす");
            return;
        }
        let sys = e.fake(Uac::Accept);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        std::fs::set_permissions(&work, std::fs::Permissions::from_mode(0o755)).unwrap();
        let links = row(&o, LINKS);
        assert_eq!(links.kind, Kind::Missing, "{o:?}\n{out}");
        assert!(
            links
                .notes
                .iter()
                .any(|n| n.starts_with("work/settings.json のリンクを外せない")),
            "{links:?}"
        );
        let calls = sys.calls.borrow();
        let elevated: Vec<String> = calls
            .iter()
            .filter_map(|c| c.env_value("DOTFILES_ELEVATE_ARGS"))
            .collect();
        assert_eq!(elevated.len(), 1, "{elevated:?}");
        let stuck = e.dir("work", "settings.json").display().to_string();
        assert!(!elevated[0].contains(&stuck), "{elevated:?}");
        assert!(elevated[0].contains("claude-personal"), "{elevated:?}");
        drop(calls);
        // personal は張れた
        for f in ["settings.json", "CLAUDE.md"] {
            assert!(same_path(
                &link_target(&e.dir("personal", f)).unwrap(),
                &e.claude(f)
            ));
        }
        // 外せなかったリンクはそのまま
        assert!(same_path(
            &link_target(&e.dir("work", "settings.json")).unwrap(),
            &other
        ));
    }

    /// claude-account add で足したアカウント (登録) も、既定と同じ形に用意し、launcher を置く。管理のコマンドは run_accounts で
    /// 1 つのアカウントのぶんだけ流せる (claude-account.exe は置かない)
    #[test]
    fn registered_accounts_are_prepared_too() {
        let e = Env::new();
        if !file_symlinks_work(&e.t) {
            return;
        }
        e.t.write(
            "home/.config/claude-accounts/accounts.json",
            "{\"version\":1,\"accounts\":{\"token1\":{\"mode\":\"token\"}}}\n",
        );
        let sys = e.fake(Uac::NotNeeded);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        assert_eq!(
            row(&o, "~/.claude-personal・~/.claude-work・~/.claude-token1:").kind,
            Kind::Ok,
            "{o:?}\n{out}"
        );
        assert!(row(&o, LINKS).text.contains("張った 6"), "{o:?}");
        let cmds = row(
            &o,
            "コマンド (claude-personal・claude-work・claude-token1・claude-account):",
        );
        assert!(cmds.text.contains("置いた 4"), "{cmds:?}");
        for f in ["settings.json", "CLAUDE.md", "projects"] {
            assert!(
                same_path(&link_target(&e.dir("token1", f)).unwrap(), &e.claude(f)),
                "token1/{f}"
            );
        }
        assert_eq!(std::fs::read(e.bin("token1")).unwrap(), b"runner-v1");

        // 1 つのアカウントだけ (claude-account add の形)
        std::fs::remove_dir_all(e.dir("token1", "")).unwrap();
        std::fs::remove_file(e.bin("token1")).unwrap();
        std::fs::remove_file(e.bin(crate::accounts::MANAGER)).unwrap();
        let sys = e.fake(Uac::NotNeeded);
        let mut buf = Vec::new();
        let o = {
            let mut ctx = Ctx {
                repo: PathBuf::new(),
                roots: Roots::from_home(&e.home()),
                state_dir: e.t.path().join("state"),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys: &sys,
                out: &mut buf,
            };
            run_accounts(
                &mut ctx,
                Mode::Apply { force: false },
                &["token1".to_string()],
                false,
            )
        };
        assert!(o.iter().all(|x| x.kind == Kind::Ok), "{o:?}");
        assert!(row(&o, "~/.claude-token1:").text.contains("追加"), "{o:?}");
        assert!(
            row(&o, "コマンド (claude-token1):")
                .text
                .contains("置いた 1"),
            "{o:?}"
        );
        assert!(is_link(&e.dir("token1", "settings.json")));
        assert!(e.bin("token1").exists());
        assert!(!e.bin(crate::accounts::MANAGER).exists());
    }

    /// 登録の一覧が読めなければ、既定は用意して、⚠ (Manual) の行で知らせる
    #[test]
    fn broken_registry_keeps_the_defaults() {
        let e = Env::new();
        e.t.write(
            "home/.config/claude-accounts/accounts.json",
            "{\"version\":1,\"accounts\":[",
        );
        let sys = e.fake(Uac::Decline);
        let (o, out) = e.run(Mode::Apply { force: false }, &sys);
        assert_eq!(row(&o, DIRS).kind, Kind::Ok, "{o:?}\n{out}");
        let m = row(&o, "claude-account の登録の一覧が読めない");
        assert_eq!(m.kind, Kind::Manual, "{m:?}");
        assert!(m.notes.iter().any(|n| n.contains("accounts.json")), "{m:?}");
        assert!(e.dir("work", "projects").exists());
    }
}
