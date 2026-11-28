//! `pjp child new`・`restart` (spec §7.4): 子のマシンに worktree と herdr-app の space を作り、`hc run` で子の claude を立てる。
//!
//! herdr-app の無いマシン (SSH 先や WSL の Linux のハブ) では `space.new` を打てないので、新しい id の label `herdr.space`・
//! `herdr.tab` を付けて子を立て、herdr-app (Windows) にその id の space を作らせてから、子のマシンの hc の doc `herdr-app` で名前を
//! 付ける。herdr-app が作らなければ (動いていない・遅い)、名前つきの space を doc に足す。`restart` は前の端末を終えてから立て、
//! 前の端末を消すのは立てた後にする (space を空にすると herdr-app が消し、同じ id で名前の空の space を作り直す)。

use std::io::Write;
use std::time::Duration;

use pjp_core::{Error, Result, exit};
use serde_json::Value;

use super::account::{self, Account};
use super::machine::{self, Target};
use super::{
    check_cmdline, git, grand, help, open_ledger, probe, read_text_file, remote_path, short_remote,
    status_word,
};
use crate::appdoc::{self, Ensured, NewSpace, Rename};
use crate::args::{self, Parsed, Spec};
use crate::hc::{Hc, HerdrApp, Runner, app_id, finished, local_id, split_addr, state_of};
use crate::ledger::{Row, state};
use crate::mark::video::{self, State, Video};
use crate::pack;

/// 子の claude の起動の引数 (ユーザーの `c` から `--remote-control` と `--effort` を除いたもの)。
const CLAUDE_ARGS: &str = include_str!("../../assets/claude-args.toml");

/// 子に渡さない旧 herdr の env (spec §7.4 の 6。手元の WSL の core に漏れていた。pjp doctor の点検と同じ 6 つ)。
pub const HERDR_ENV_NAMES: [&str; 6] = [
    "HERDR_ENV",
    "HERDR_PANE_ID",
    "HERDR_TAB_ID",
    "HERDR_WORKSPACE_ID",
    "HERDR_SOCKET_PATH",
    "HERDR_BIN_PATH",
];

/// 受ける effort (Claude Code の `--effort` が受ける値の全部)。指揮役が自分の判断で選ぶのは high (既定)・max・medium で、
/// low・xhigh はユーザーが名指ししたときだけ使う (common.md の「effort を選ぶ」。道具は絞らない)。
const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// 立てた子の状態の報告を待つ秒数 (spec §7.4 の 7)。
const REPORT_WAIT_SECS: u32 = 30;

/// `--effort` を渡さないときの effort (new と、控えに前の値の無い restart)。common.md の「effort を選ぶ」の既定。
const DEFAULT_EFFORT: &str = "high";

/// 子のマシンで、`worktree/<名前>` の worktree と branch が既にある番号 (1 は数字なし、2 は `-2`) を出す `sh` の script。
/// $1 = checkout、$2 = worktree のパス (数字なし)、$3 = branch (数字なし)。
const USED_SUFFIXES: &str = r#"i=1
while [ "$i" -le 50 ]; do
  if [ "$i" -eq 1 ]; then s=; else s="-$i"; fi
  if [ -e "$2$s" ] || git -C "$1" rev-parse --verify --quiet "refs/heads/$3$s" >/dev/null 2>&1; then
    printf '%s\n' "$i"
  fi
  i=$((i + 1))
done
"#;

/// 続きから立てるか。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Resume<'a> {
    No,
    /// `claude --continue` (その worktree の前の会話の続き)。
    Continue,
    /// `claude --resume <会話の ID>`。
    Session(&'a str),
}

pub(crate) fn claude_config_args() -> Result<Vec<String>> {
    let table: toml::Table = toml::from_str(CLAUDE_ARGS)
        .map_err(|e| Error::config(format!("assets/claude-args.toml を読めません: {e}")))?;
    table
        .get("args")
        .and_then(toml::Value::as_array)
        .ok_or_else(|| Error::config("assets/claude-args.toml に args の配列がありません"))?
        .iter()
        .map(|v| {
            v.as_str().map(str::to_owned).ok_or_else(|| {
                Error::config("assets/claude-args.toml の args は文字列の配列にする")
            })
        })
        .collect()
}

/// 子の端末で動かす argv: `env -u HERDR_* … -u CLAUDE_CONFIG_DIR … <claude か claude-<名前>> <args> --effort <e>
/// --no-chrome|--chrome [--settings <JSON>] [--continue|--resume <ID>] [<依頼>]`。shell を通さないので、依頼の改行・引用符・
/// backquote はそのまま届く。
fn child_argv(
    claude: &str,
    effort: &str,
    chrome: bool,
    settings: Option<&str>,
    resume: Resume<'_>,
    brief: Option<&str>,
) -> Result<Vec<String>> {
    let mut argv = vec!["env".to_owned()];
    // core の env に紛れた旧 herdr の env と、アカウントの env (既定の子は ~/.claude の /login で起きるように)
    for name in HERDR_ENV_NAMES.iter().chain(&account::CLEARED_ENV) {
        argv.extend(["-u".to_owned(), (*name).to_owned()]);
    }
    argv.push(claude.to_owned());
    argv.extend(claude_config_args()?);
    argv.extend(["--effort".to_owned(), effort.to_owned()]);
    argv.push(if chrome { "--chrome" } else { "--no-chrome" }.to_owned());
    if let Some(json) = settings {
        argv.extend(["--settings".to_owned(), json.to_owned()]);
    }
    match resume {
        Resume::No => {}
        Resume::Continue => argv.push("--continue".to_owned()),
        Resume::Session(id) => argv.extend(["--resume".to_owned(), id.to_owned()]),
    }
    if let Some(text) = brief {
        // `-` で始まる依頼 (`---` の frontmatter・`- ` の箇条書き) は、claude が option と読んで起きないので、頭に改行を足す
        argv.push(if text.starts_with('-') {
            format!("\n{text}")
        } else {
            text.to_owned()
        });
    }
    Ok(argv)
}

/// 子の端末の印 (label)。
struct Labels<'a> {
    space: Option<&'a str>,
    tab: Option<&'a str>,
    letter: &'a str,
    /// 子のチケット (立て直すとき、前の端末の `pjp.ticket` を引き継ぐ)。
    ticket: Option<&'a str>,
    /// 引き継ぐ見ていない解説動画の印 (`pjp.video.<id>=<値>`。立て直すとき、前の端末から)。
    videos: &'a [String],
}

/// `hc run` の引数 (`run` の後ろ)。
///
/// `--parent` は渡さない。hc は env の `HC_TERMINAL_ID` の端末 (この会話) を親にする。`--parent` は `--on` のマシンの中で
/// 読まれるので、Windows のハブから `--on <machine> --parent t8` と渡すと、そのマシンの別の端末 t8 が親になる (指揮役が Windows で見た)。
fn run_args(
    machine: Option<&str>,
    cwd: &str,
    name: &str,
    labels: &Labels<'_>,
    argv: &[String],
) -> Vec<String> {
    let mut args: Vec<String> = ["--bg", "--json"].iter().map(|s| (*s).to_owned()).collect();
    if let Some(m) = machine {
        args.extend(["--on".to_owned(), m.to_owned()]);
    }
    args.extend([
        "--cwd".to_owned(),
        cwd.to_owned(),
        "--name".to_owned(),
        name.to_owned(),
        "--outlive-parent".to_owned(),
    ]);
    if let Some(sp) = labels.space {
        args.extend(["--label".to_owned(), format!("herdr.space={sp}")]);
    }
    if let Some(tb) = labels.tab {
        args.extend(["--label".to_owned(), format!("herdr.tab={tb}")]);
    }
    args.extend([
        "--label".to_owned(),
        "pjp.role=child".to_owned(),
        "--label".to_owned(),
        format!("pjp.letter={}", labels.letter),
    ]);
    if let Some(t) = labels.ticket {
        args.extend(["--label".to_owned(), format!("pjp.ticket={t}")]);
    }
    for pair in labels.videos {
        args.extend(["--label".to_owned(), pair.clone()]);
    }
    args.push("--".to_owned());
    args.extend(argv.iter().cloned());
    args
}

/// 端末の名前 (`hc run --name`): 1〜32 字の a-z・0-9・`-`・`_`。
pub(crate) fn valid_name(name: &str) -> bool {
    (1..=32).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
}

fn required<'p>(p: &'p Parsed, name: &str) -> Result<&'p str> {
    p.value(name)?
        .filter(|v| !v.trim().is_empty())
        .ok_or_else(|| Error::config(format!("{name} が要ります (pjp child --help)")))
}

/// `--effort` の値 (無ければ `default`)。low・medium・high・xhigh・max のほかは断る。
fn effort_of<'a>(p: &'a Parsed, default: &'a str) -> Result<&'a str> {
    let effort = p.value("--effort")?.unwrap_or(default);
    if EFFORTS.contains(&effort) {
        Ok(effort)
    } else {
        Err(Error::config(format!(
            "--effort は low・medium・high・xhigh・max のどれか ({effort} は受けない)"
        )))
    }
}

/// pack の JSON (pack も同期された skill も無ければ None)。ハブの skill の SKILL.md の metadata から作る (spec §7.4 の 5)。
fn settings_for(
    r: &dyn Runner,
    packs: &[String],
    synced: &[String],
    err: &mut dyn Write,
) -> Result<Option<String>> {
    if packs.is_empty() && synced.is_empty() {
        return Ok(None);
    }
    let roots = r.skill_roots()?;
    pack::settings_json(&roots, packs, synced, err)
        .map(Some)
        .map_err(|code| Error::new(code, "pack の JSON を作れません (上の行)"))
}

/// ghq get の打ち方の説明。
const GHQ_HOW: &str = "gh の資格情報を GIT_CONFIG_* の env で付ける";

/// 作業場所の決め方。
enum Place<'a> {
    Repo(&'a str),
    Checkout(&'a str),
    Dir(&'a str),
}

/// 名指しでなく選んだ子のマシン (自動・`--on wsl`) を、出力と note 用の行に添えるもの。
struct Chose {
    /// マシンの名前の後ろに付ける印 (` (自動で選んだ)`・` (手元の WSL)`)。
    mark: &'static str,
    /// note 用の行に足す文。
    note: String,
}

/// 決まった作業場所。
struct Planned {
    repo: String,
    checkout: String,
    /// worktree か dir。
    dir: String,
    /// worktree の branch (dir なら空)。
    branch: String,
    base: String,
    name: String,
    /// 打つ git (dry-run で見せる)。
    fetch: bool,
    needs_ghq_get: bool,
}

pub fn new(
    r: &dyn Runner,
    args: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let spec = Spec {
        flags: &["--chrome", "--dry-run"],
        values: &[
            "--agent",
            "--label",
            "--brief",
            "--repo",
            "--checkout",
            "--dir",
            "--on",
            "--base",
            "--effort",
            "--pack",
            "--synced",
            "--ticket",
            "--account",
        ],
    };
    let p = args::parse(args, &spec)?;
    if help(&p, out) {
        return Ok(exit::OK);
    }
    if !p.positionals.is_empty() {
        return Err(Error::config(format!(
            "余分な引数です: {}",
            p.positionals.join(" ")
        )));
    }
    let agent = required(&p, "--agent")?;
    if !valid_name(agent) {
        return Err(Error::config(format!(
            "--agent {agent} は 1〜32 字の a-z・0-9・-・_ にする (hc の端末の名前)"
        )));
    }
    let label = required(&p, "--label")?;
    if label.chars().any(char::is_control) {
        return Err(Error::config("--label に改行などの制御文字を入れない"));
    }
    let brief = read_text_file(required(&p, "--brief")?)?;
    if brief.trim().is_empty() {
        return Err(Error::config("--brief のファイルが空です"));
    }
    let effort = effort_of(&p, DEFAULT_EFFORT)?;
    let chrome = p.flag("--chrome");
    let dry = p.flag("--dry-run");
    if p.value("--base")?.is_some_and(|b| b.starts_with('-')) {
        return Err(Error::config(
            "--base は - で始めない (git が option と読む)",
        ));
    }
    let place = match (
        p.value("--repo")?,
        p.value("--checkout")?,
        p.value("--dir")?,
    ) {
        (Some(repo), None, None) => {
            let ok = repo.split_once('/').is_some_and(|(o, n)| {
                !o.is_empty()
                    && !n.is_empty()
                    && repo.split('/').count() == 2
                    && repo.bytes().all(|b| {
                        b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'/')
                    })
            });
            if !ok {
                return Err(Error::config(format!(
                    "--repo は owner/repo の形にする ({repo})"
                )));
            }
            Place::Repo(repo)
        }
        (None, Some(path), None) => Place::Checkout(path),
        (None, None, Some(path)) => Place::Dir(path),
        _ => {
            return Err(Error::config(
                "--repo・--checkout・--dir のどれか 1 つで作業場所を決める",
            ));
        }
    };
    // 子を立てるアカウント (--account か、ハブの CLAUDE_CONFIG_DIR)。決まらなければ何も打たずに止まる
    let choice = account::choose(r, p.value("--account")?)?;

    let hc = Hc::new(r);
    hc.require()?;
    let parent = r
        .env("HC_TERMINAL_ID")
        .ok_or_else(|| Error::config("hc の端末の中で打つ (子はこの端末の子として立つ)"))?;
    // --on → hub.toml の default_machine → 自動 (自動なら、測る前に hub.toml の [auto] を確かめる)
    let target = machine::resolve(r, p.value("--on")?)?;
    // --checkout は、あるマシンの repo (~/h など) を指す。--on を省いて自動にすると、同じパスのほかのマシンの repo を選びうるので、
    // マシンを名指しさせる (--on auto と打てば自動)
    if let (Place::Checkout(path), Target::Auto(auto)) = (&place, &target)
        && !auto.explicit()
    {
        return Err(Error::config(format!(
            "--checkout {path} は子のマシンの repo を指すので、子のマシンを --on <machine> で渡す (自動で選んでよければ --on auto。\
             --on を省いて自動にすると、同じパスのほかのマシンの repo を選びうる)"
        )));
    }
    let settings = settings_for(r, p.values("--pack"), p.values("--synced"), err)?;
    let (ledger, key) = open_ledger(r, &hc, p.value("--ticket")?)?;

    let repo_arg = match place {
        Place::Repo(repo) => repo,
        _ => "",
    };
    // 子のマシンを探り、起こすものを決める。名前のアカウントは launcher と用意を、ghq get・fetch・worktree・space の前に
    // 確かめる。自動なら、測った machine のうち用意の通った所を選び、選んだマシンとわけをここで出す (立てる前・--dry-run でも)。
    // --on wsl なら、hc machine ls の手元の WSL の machine を引いて出す
    let (picked, pr, ready, chose) = match target {
        Target::Fixed(on) => {
            let pr = probe(&hc, on.as_deref(), repo_arg)?;
            let ready = account::ready(
                &hc,
                on.as_deref(),
                &pr.claude,
                &pr.claude_account,
                &choice.account,
            )?;
            (on, pr, ready, None)
        }
        Target::Wsl(why) => {
            let got = machine::wsl(&hc, &why)?;
            for line in &got.lines {
                let _ = writeln!(out, "{line}");
            }
            let pr = probe(&hc, Some(&got.machine), repo_arg)?;
            let ready = account::ready(
                &hc,
                Some(&got.machine),
                &pr.claude,
                &pr.claude_account,
                &choice.account,
            )?;
            let chose = Chose {
                mark: " (手元の WSL)",
                note: "マシンは手元の WSL".to_owned(),
            };
            (Some(got.machine), pr, ready, Some(chose))
        }
        Target::Auto(auto) => {
            let got = machine::choose(&hc, &auto, repo_arg, &choice.account, chrome)?;
            for line in &got.lines {
                let _ = writeln!(out, "{line}");
            }
            let chose = Chose {
                mark: " (自動で選んだ)",
                note: got.note,
            };
            (got.machine, got.probe, got.ready, Some(chose))
        }
    };
    let m = picked.as_deref();
    let chose_mark = chose.as_ref().map_or("", |c| c.mark);
    let taken_names: Vec<String> = hc
        .ls(false)?
        .iter()
        .filter_map(|t| t["name"].as_str().map(str::to_owned))
        .collect();
    let plan = plan_place(
        &hc,
        m,
        &pr,
        &place,
        p.value("--base")?,
        agent,
        &taken_names,
        dry,
    )?;

    // 長すぎる依頼は、何かを作る前に断る (space・tab の id は長めの仮の値で数える)
    let argv = child_argv(
        &ready.program,
        effort,
        chrome,
        settings.as_deref(),
        Resume::No,
        Some(&brief),
    )?;
    let dummy = "x".repeat(40);
    let probe_args = run_args(
        m,
        &plan.dir,
        &plan.name,
        &Labels {
            space: Some(&dummy),
            tab: Some(&dummy),
            letter: "AAA",
            ticket: None,
            videos: &[],
        },
        &argv,
    );
    check_cmdline(&probe_args, "依頼")?;

    let home = &pr.home;
    let space_name = |letter: &str| format!("{letter} {label}");
    if dry {
        let letter = ledger.peek_next()?;
        let _ = writeln!(
            out,
            "(--dry-run) 子 {letter} を立てるなら、次のとおりに打つ (控え: {key})"
        );
        let shown_machine = match (m, chose.is_some()) {
            (Some(m), _) => format!("{m}{chose_mark}"),
            // 名指しでなくこのマシンになるのは、自動 (hub.toml の order の local) だけ
            (None, true) => "local (このマシン。自動で選んだ)".to_owned(),
            (None, false) => "local (このマシン)".to_owned(),
        };
        let _ = writeln!(out, "  マシン: {shown_machine}");
        let _ = writeln!(out, "  アカウント: {}", account::describe(&choice, &ready));
        if plan.needs_ghq_get {
            let _ = writeln!(out, "  ghq get {} ({GHQ_HOW})", plan.repo);
        }
        if !plan.branch.is_empty() {
            if plan.fetch {
                let _ = writeln!(
                    out,
                    "  git -C {} fetch origin ({})",
                    short_remote(&plan.checkout, home),
                    super::gh_git_how(&pr)
                );
            }
            let _ = writeln!(
                out,
                "  git -C {} worktree add -b {} {} {}",
                short_remote(&plan.checkout, home),
                plan.branch,
                short_remote(&plan.dir, home),
                plan.base
            );
        } else {
            let _ = writeln!(out, "  mkdir -p {}", short_remote(&plan.dir, home));
        }
        let app = HerdrApp::new(r);
        if app.available() {
            let _ = writeln!(
                out,
                "  herdr-app do space.new (名前 '{}'。{})",
                space_name(&letter),
                app.space_focus().dry_run_hint()
            );
        } else {
            let _ = writeln!(
                out,
                "  space '{}': herdr-app が無いので、新しい id の label herdr.space・herdr.tab で立てて herdr-app に作らせ、{} で名前を付ける (作られなければ doc に足す)",
                space_name(&letter),
                appdoc::what(m)
            );
        }
        let shown = run_args(
            m,
            &plan.dir,
            &plan.name,
            &Labels {
                space: Some("<space>"),
                tab: Some("<tab>"),
                letter: &letter,
                ticket: None,
                videos: &[],
            },
            &argv[..argv.len() - 1],
        );
        let _ = writeln!(
            out,
            "  hc run {} <依頼 ({} 字)>",
            shown.join(" "),
            brief.chars().count()
        );
        return Ok(exit::OK);
    }

    let now = r.now()?.to_jst().iso_seconds();
    let row = ledger.reserve(|_| Row {
        state: state::NEW.into(),
        name: plan.name.clone(),
        machine: m.unwrap_or_default().to_owned(),
        repo: plan.repo.clone(),
        checkout: plan.checkout.clone(),
        worktree: plan.dir.clone(),
        branch: plan.branch.clone(),
        base: plan.base.clone(),
        created: now.clone(),
        updated: now.clone(),
        effort: effort.to_owned(),
        packs: Row::join_packs(p.values("--pack"), p.values("--synced")),
        chrome: if chrome { "1" } else { "" }.to_owned(),
        account: choice.account.ledger_value().to_owned(),
        ..Row::default()
    })?;
    let letter = row.letter.clone();
    let fail_row = |e: Error| -> Error {
        let _ = ledger.update(&letter, |r| r.state = state::FAILED.into());
        e
    };

    // worktree (か dir) を作る
    let created_worktree = if plan.branch.is_empty() {
        let mk = hc
            .exec(m, None, 60, &["mkdir", "-p", &plan.dir])
            .map_err(fail_row)?;
        if !mk.ok() {
            return Err(fail_row(Error::failure(format!(
                "{} を作れません: {}",
                plan.dir,
                mk.why()
            ))));
        }
        false
    } else {
        git(
            &hc,
            m,
            120,
            &[
                "-C",
                &plan.checkout,
                "worktree",
                "add",
                "-b",
                &plan.branch,
                &plan.dir,
                &plan.base,
            ],
        )
        .map_err(fail_row)?;
        // worktree add -b は既定の branch の追跡先を付けるので外す (push・gh pr create が main を相手に取り違えないように)
        let _ = hc.exec(
            m,
            None,
            30,
            &["git", "-C", &plan.dir, "branch", "--unset-upstream"],
        );
        true
    };

    // herdr-app の space (herdr-app が答えないときは作らずに進める。spec §12 の 19)
    let app = HerdrApp::new(r);
    // herdr-app の無いマシン: label で herdr-app に作らせ、名前は doc で付ける
    let by_label = !app.available();
    let (space, tab) = if app.available() {
        // herdr-app 0.1.16 から space.new は focus を知り、false なら画面 (表示中の space と打ち込み先) を動かさない。
        // 0.1.15 は知らない引数で落ちるので、commands に載っているときだけ渡す
        let focus = app.space_focus();
        if let Some(note) = focus.note() {
            let _ = writeln!(err, "{note}");
        }
        match app.space_new(&space_name(&letter), &plan.dir, m, &focus) {
            Ok(ids) => ids,
            Err(e) => {
                let _ = writeln!(
                    err,
                    "!! space を作れませんでした ({e})。子は herdr-app の Agents 欄にだけ出る"
                );
                (None, None)
            }
        }
    } else {
        // herdr-app が作る id と同じ形の、新しい id (知らない id の label を見ると、herdr-app がその id の space を作る)
        let sp = appdoc::new_id(r, "sp");
        let tb = appdoc::new_id(r, "tb");
        (Some(app_id(&sp, m)), Some(app_id(&tb, m)))
    };

    let labels = Labels {
        space: space.as_deref().map(local_id),
        tab: tab.as_deref().map(local_id),
        letter: &letter,
        ticket: None,
        videos: &[],
    };
    let run = run_args(m, &plan.dir, &plan.name, &labels, &argv);
    let addr = match hc.run(&run) {
        Ok(t) => t["address"].as_str().unwrap_or_default().to_owned(),
        // 落ちたように見えても (時間切れ・出力の読み違い)、子が立っていれば戻さない (claude が消した worktree で動き続けないように)
        Err(e) => match super::find_live_soon(r, &hc, m, &plan.name, None) {
            Some(found) => {
                let _ = writeln!(
                    err,
                    "!! hc run は落ちたが ({e})、端末 {found} ({}) が立っているので、そのまま進める",
                    plan.name
                );
                found
            }
            None => {
                // label で作らせる space は、子が立たなければ herdr-app も作らない (閉じるものが無い)
                let made = space.as_deref().filter(|_| !by_label);
                let undone = rollback(&hc, &app, m, &plan, made, created_worktree);
                let _ = ledger.update(&letter, |r| r.state = state::FAILED.into());
                return Err(Error::failure(format!("{e}\n{undone}")));
            }
        },
    };
    ledger.update(&letter, |r| {
        r.state = state::LIVE.into();
        r.terminal = addr.clone();
        r.space = space.clone().unwrap_or_default();
        r.tab = tab.clone().unwrap_or_default();
        r.space_name = if space.is_some() {
            space_name(&letter)
        } else {
            String::new()
        };
        r.updated = now.clone();
    })?;

    let _ = writeln!(out, "子 {letter} を立てた: {} ({addr})", plan.name);
    let where_ = if plan.repo.is_empty() {
        String::new()
    } else {
        format!("  repo: {}", plan.repo)
    };
    let _ = writeln!(
        out,
        "  マシン: {}{chose_mark}{where_}",
        m.unwrap_or("local")
    );
    let _ = writeln!(out, "  アカウント: {}", account::describe(&choice, &ready));
    let shown_dir = short_remote(&plan.dir, home);
    if plan.branch.is_empty() {
        let _ = writeln!(out, "  作業場所: {shown_dir} (worktree なし)");
    } else {
        let _ = writeln!(
            out,
            "  worktree: {shown_dir} (branch {}、base {})",
            plan.branch, plan.base
        );
    }
    match (&space, &tab) {
        (Some(sp), tb) => {
            let _ = writeln!(
                out,
                "  space: {} (space {}・tab {}{})",
                space_name(&letter),
                local_id(sp),
                tb.as_deref().map_or("-", local_id),
                if by_label {
                    "。herdr-app が無いので、label から herdr-app に作らせ、名前は hc の doc で付ける"
                } else {
                    ""
                }
            );
        }
        (None, _) => {
            let _ = writeln!(out, "  space: なし");
        }
    }
    let packs = p.values("--pack");
    let synced = p.values("--synced");
    let mut pack_text = packs.join(" ");
    if !synced.is_empty() {
        pack_text = format!("{pack_text} (同期: {})", synced.join(" "))
            .trim()
            .to_owned();
    }
    let _ = writeln!(
        out,
        "  effort: {effort}  pack: {}  chrome: {}",
        if pack_text.is_empty() {
            "なし"
        } else {
            &pack_text
        },
        if chrome {
            "使う (--chrome)"
        } else {
            "使わない (--no-chrome)"
        }
    );
    // 子はもう立っているので、確かめられなくても失敗にしない。親が違うときだけ失敗 (子の報告が別の端末に打たれる)
    let parent_ok = match confirm(r, &hc, &addr, &parent, m, out) {
        Ok(ok) => ok,
        Err(e) => {
            let _ = writeln!(
                out,
                "  !! 子の状態を確かめられません ({e})。pjp child ls で見る"
            );
            true
        }
    };
    // herdr-app が label から space を作るのを待ち、名前を付ける。子の状態の報告を待った (最長 30 秒) 後にするので、herdr-app には
    // その分の時間もある
    if by_label && let (Some(sp), Some(tb)) = (&space, &tab) {
        let name = space_name(&letter);
        let got = appdoc::ensure(
            r,
            &hc,
            m,
            &NewSpace {
                id: sp,
                tab: tb,
                name: &name,
                folder: &plan.dir,
                terminal: &addr,
            },
            appdoc::PLACE_POLLS,
        );
        let _ = writeln!(out, "  {}", space_report(&got, m, &name, false));
    }
    let what = if !plan.repo.is_empty() {
        plan.repo.clone()
    } else if !plan.checkout.is_empty() {
        short_remote(&plan.checkout, home)
    } else {
        shown_dir.clone()
    };
    let account_note = match &choice.account {
        Account::Default => String::new(),
        named => format!("・{}", named.label()),
    };
    // 自動・--on wsl で選んだなら、どのマシンをなぜ選んだかも (子の住所の頭のマシンの名前だけでは、自動で選んだ・手元の WSL だと
    // 分からない)
    let machine_note = chose.map(|c| format!("・{}", c.note)).unwrap_or_default();
    let _ = writeln!(
        out,
        "  note 用: 子 {letter} = {what} ({addr}・{shown_dir}・effort {effort}{account_note}{machine_note})"
    );
    Ok(if parent_ok { exit::OK } else { exit::FAILURE })
}

/// 作業場所を決める (checkout を探す・fetch・切る元・重ならない名前)。dry-run では書き換えるもの (ghq get・fetch) を打たない。
#[allow(clippy::too_many_arguments)]
fn plan_place(
    hc: &Hc<'_>,
    m: Option<&str>,
    pr: &super::Probe,
    place: &Place<'_>,
    base: Option<&str>,
    agent: &str,
    taken_names: &[String],
    dry: bool,
) -> Result<Planned> {
    let free_name = |used: &[u32]| -> Result<(String, u32)> {
        for i in 1..=50u32 {
            let name = if i == 1 {
                agent.to_owned()
            } else {
                format!("{agent}-{i}")
            };
            if !used.contains(&i) && !taken_names.contains(&name) {
                if !valid_name(&name) {
                    return Err(Error::config(format!(
                        "名前 {name} が 32 字を超える (--agent を短くする)"
                    )));
                }
                return Ok((name, i));
            }
        }
        Err(Error::failure(format!(
            "{agent} の名前が 50 個とも使われています"
        )))
    };

    let (repo, checkout, needs_ghq_get) = match place {
        Place::Dir(path) => {
            let dir = remote_path(path, &pr.home)?;
            let (name, _) = free_name(&[])?;
            return Ok(Planned {
                repo: String::new(),
                checkout: String::new(),
                dir,
                branch: String::new(),
                base: String::new(),
                name,
                fetch: false,
                needs_ghq_get: false,
            });
        }
        Place::Repo(repo) => {
            if !pr.checkout.is_empty() {
                ((*repo).to_owned(), pr.checkout.clone(), false)
            } else if pr.ghq.is_empty() {
                return Err(Error::config(format!(
                    "子のマシンに {repo} の checkout が無く、ghq もありません (ghq を入れるか --checkout で渡す)"
                )));
            } else if dry {
                (
                    (*repo).to_owned(),
                    format!("{}/ghq/github.com/{repo}", pr.home),
                    true,
                )
            } else {
                // ghq は中で git を呼ぶので、gh の資格情報の組を env で渡す
                let got = hc.exec_env(m, None, &super::gh_git_env(), 300, &["ghq", "get", repo])?;
                if !got.ok() {
                    return Err(super::gh_net_failure(
                        m,
                        &format!("ghq get {repo}"),
                        GHQ_HOW,
                        &got,
                    ));
                }
                let again = super::probe(hc, m, repo)?;
                if again.checkout.is_empty() {
                    return Err(Error::failure(format!(
                        "ghq get の後も {repo} の checkout が見つかりません"
                    )));
                }
                ((*repo).to_owned(), again.checkout, false)
            }
        }
        Place::Checkout(path) => {
            let path = remote_path(path, &pr.home)?;
            let top = git(hc, m, 30, &["-C", &path, "rev-parse", "--show-toplevel"])?;
            (String::new(), top.trim().to_owned(), false)
        }
    };
    let repo_name = match place {
        Place::Repo(r) => r.rsplit('/').next().unwrap_or(r).to_owned(),
        _ => checkout.rsplit('/').next().unwrap_or(&checkout).to_owned(),
    };

    // origin があれば fetch して、既定の branch (origin/HEAD) から切る。無ければ (~/h のような local の repo) 今の branch から
    let has_origin = needs_ghq_get
        || hc
            .exec(
                m,
                None,
                30,
                &["git", "-C", &checkout, "remote", "get-url", "origin"],
            )?
            .ok();
    if has_origin && !dry {
        let argv = super::gh_git_argv(pr, &checkout, &["fetch", "origin"]);
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        let fetched = hc.exec(m, None, 300, &argv)?;
        if !fetched.ok() {
            return Err(super::gh_net_failure(
                m,
                &format!("git -C {checkout} fetch origin"),
                super::gh_git_how(pr),
                &fetched,
            ));
        }
    }
    let base = match base {
        Some(b) => b.to_owned(),
        None if needs_ghq_get => "origin/HEAD".to_owned(),
        None if has_origin => git(hc, m, 30, &["-C", &checkout, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
            .map_err(|e| {
                Error::failure(format!(
                    "{e} (既定の branch が分かりません。git -C {checkout} remote set-head origin --auto を打つか、--base で渡す)"
                ))
            })?
            .trim()
            .to_owned(),
        None => git(hc, m, 30, &["-C", &checkout, "symbolic-ref", "--short", "HEAD"])?
            .trim()
            .to_owned(),
    };

    let base_dir = format!(
        "{}/.herdr/worktrees/{repo_name}/{agent}",
        pr.home.trim_end_matches('/')
    );
    let base_branch = format!("worktree/{agent}");
    let used: Vec<u32> = if needs_ghq_get {
        Vec::new()
    } else {
        let out = hc.exec(
            m,
            None,
            60,
            &[
                "sh",
                "-c",
                USED_SUFFIXES,
                "sh",
                &checkout,
                &base_dir,
                &base_branch,
            ],
        )?;
        if !out.ok() {
            return Err(Error::failure(format!(
                "使われている worktree を確かめられません: {}",
                out.why()
            )));
        }
        out.stdout
            .lines()
            .filter_map(|l| l.trim().parse().ok())
            .collect()
    };
    let (name, i) = free_name(&used)?;
    let suffix = if i == 1 {
        String::new()
    } else {
        format!("-{i}")
    };
    Ok(Planned {
        repo,
        checkout,
        dir: format!("{base_dir}{suffix}"),
        branch: format!("{base_branch}{suffix}"),
        base,
        name,
        fetch: has_origin,
        needs_ghq_get,
    })
}

/// `hc run` が落ちたら、作ったもの (space・worktree・branch) を戻す。戻したこと (戻せなかったこと) を文で返す。
fn rollback(
    hc: &Hc<'_>,
    app: &HerdrApp<'_>,
    m: Option<&str>,
    plan: &Planned,
    space: Option<&str>,
    created_worktree: bool,
) -> String {
    let mut lines = Vec::new();
    if let Some(sp) = space {
        let id = app_id(sp, m);
        match app.run(
            "space.close",
            &serde_json::json!({ "id": id, "confirmed": true }),
        ) {
            Ok(_) => lines.push(format!("  戻した: space {id} を閉じた")),
            Err(e) => lines.push(format!("  戻せなかった: space {id} ({e})")),
        }
    }
    if created_worktree {
        let removed = hc.exec(
            m,
            None,
            60,
            &[
                "git",
                "-C",
                &plan.checkout,
                "worktree",
                "remove",
                "--force",
                &plan.dir,
            ],
        );
        let deleted = hc.exec(
            m,
            None,
            30,
            &["git", "-C", &plan.checkout, "branch", "-D", &plan.branch],
        );
        match (removed, deleted) {
            (Ok(a), Ok(b)) if a.ok() && b.ok() => {
                lines.push(format!("  戻した: worktree {} と branch {} を消した", plan.dir, plan.branch));
            }
            _ => lines.push(format!(
                "  戻せなかった: worktree {} と branch {} を手で消す (git -C {} worktree remove … / branch -D …)",
                plan.dir, plan.branch, plan.checkout
            )),
        }
    }
    lines.join("\n")
}

/// 子の hc の親が、この会話の端末 (`me`) か。ハブの core から見た親は `t8` の形。別のマシンの core から見た `<core の id>/t8`
/// は合うが、子のマシンの中の同じ住所 (`<machine>/t8`) は別の端末。
pub(crate) fn parent_is(parent: Option<&str>, me: &str, m: Option<&str>) -> bool {
    match parent {
        Some(p) if p == me => true,
        Some(p) => {
            p.ends_with(&format!("/{me}")) && m.is_none_or(|m| !p.starts_with(&format!("{m}/")))
        }
        None => false,
    }
}

/// 立てた子の親を確かめる。この会話でなければ `!!` を出して false (子の報告が別の端末に打たれ、Agents 欄でこの会話の下に出ない)。
fn check_parent(term: &Value, addr: &str, me: &str, m: Option<&str>, out: &mut dyn Write) -> bool {
    let parent = term["parent"].as_str().filter(|p| !p.is_empty());
    if parent_is(parent, me, m) {
        return true;
    }
    let _ = writeln!(
        out,
        "  !! 子の hc の親が {} で、この会話の端末 {me} ではない。子の報告 (hc send) が別の端末に打たれ、Agents 欄でもこの会話の下に出ない。\
         hc kill {addr} と hc rm {addr} で終え、pjp child cleanup <英字> --no-pr --force で控えと worktree を片付けて立て直す",
        parent.unwrap_or("(なし)")
    );
    false
}

/// 立てた子が状態を報告するのを、最長 30 秒待って確かめる (spec §7.4 の 7)。確認の画面で止まっていれば画面を出す。
/// 子の親がこの会話の端末 (`me`) かも確かめ、違えば false を返す。
fn confirm(
    r: &dyn Runner,
    hc: &Hc<'_>,
    addr: &str,
    me: &str,
    m: Option<&str>,
    out: &mut dyn Write,
) -> Result<bool> {
    let mut last: Option<Value> = None;
    for i in 0..REPORT_WAIT_SECS {
        if i > 0 {
            r.sleep(Duration::from_secs(1));
        }
        let t = hc.get(addr)?;
        let done = match &t {
            None => true,
            Some(t) => finished(t) || t["reported"].as_bool() == Some(true),
        };
        last = t;
        if done {
            break;
        }
    }
    let Some(term) = last else {
        let _ = writeln!(
            out,
            "  !! hc に子の端末 {addr} が見つかりません (すぐに消えた)"
        );
        return Ok(true);
    };
    let parent_ok = check_parent(&term, addr, me, m, out);
    let reported = term["reported"].as_bool() == Some(true);
    let word = status_word(&term);
    let _ = writeln!(
        out,
        "  状態: {word}{}",
        if reported {
            ""
        } else {
            " (まだ報告が無い)"
        }
    );
    let stuck = finished(&term) || !reported || state_of(&term) == Some("blocked");
    if stuck {
        let why = if finished(&term) {
            "子の claude が終わっています"
        } else if reported {
            "子は確認の画面で止まっています"
        } else {
            "30 秒たっても状態の報告がありません"
        };
        let _ = writeln!(out, "  !! {why}。画面:");
        match hc.read(addr, 0) {
            Ok(text) => {
                let lines: Vec<&str> = text.lines().collect();
                let start = lines.len().saturating_sub(30);
                for l in &lines[start..] {
                    let _ = writeln!(out, "     | {l}");
                }
            }
            Err(e) => {
                let _ = writeln!(out, "     (画面を読めません: {e})");
            }
        }
        if !finished(&term) {
            let _ = writeln!(
                out,
                "  !! 今作った worktree の信頼の確認・Claude in Chrome の案内 (--chrome の子) なら、hc keys {addr} <キー>… で答える (並びは画面で確かめる)。ほかの画面はユーザーに聞く"
            );
        }
    }
    Ok(parent_ok)
}

/// 立て直せなかったとき (前の端末はもう消した)、引き継ぐはずだった見ていない解説動画の印を、この会話の端末 (`home`) へ移す。
/// 移せなければ、付け直すための hc label の行を出す。
fn rescue_videos(hc: &Hc<'_>, home: &str, videos: &[Video], row: &Row, err: &mut dyn Write) {
    let unwatched: Vec<Video> = videos
        .iter()
        .filter(|v| v.state == State::Done)
        .cloned()
        .collect();
    if unwatched.is_empty() {
        return;
    }
    let names = super::cleanup::names_of(&unwatched, State::Done);
    let moved = hc.get(home).and_then(|t| {
        let t = t.ok_or_else(|| Error::failure(format!("hc に端末 {home} がありません")))?;
        let pairs = video::moved_pairs(&unwatched, &t, &super::cleanup::moved_from(row));
        if !pairs.is_empty() {
            hc.label(home, &pairs)?;
        }
        Ok(())
    });
    match moved {
        Ok(()) => {
            let _ = writeln!(
                err,
                "!! 立て直せなかったので、前の端末の見ていない解説動画の印 ({names}) を {home} へ移した"
            );
        }
        Err(e) => {
            let _ = writeln!(
                err,
                "!! 前の端末の見ていない解説動画の印 ({names}) を移せない ({e})。付け直すなら: hc label {home} {}",
                unwatched
                    .iter()
                    .map(|v| format!("'{}'", v.pair()))
                    .collect::<Vec<_>>()
                    .join(" ")
            );
        }
    }
}

/// 子の端末を終えて消す (`hc kill` → `hc wait` → `hc rm`)。hc send の `/exit` は札で包まれて効かないので送らない。
pub(super) fn end_terminal(r: &dyn Runner, hc: &Hc<'_>, addr: &str) -> Result<()> {
    stop_terminal(hc, addr)?;
    remove_terminal(r, hc, addr)
}

/// 子の端末の program を終える (`hc kill` → `hc wait`)。端末は消さない (finished のまま残る)。
fn stop_terminal(hc: &Hc<'_>, addr: &str) -> Result<()> {
    hc.kill(addr)?;
    hc.wait(addr, 15)
}

/// 終えた端末を消す (`hc rm`。断られたら 1 秒おきに 5 回まで)。もう無ければ何もしない。
fn remove_terminal(r: &dyn Runner, hc: &Hc<'_>, addr: &str) -> Result<()> {
    let mut tries = 0;
    loop {
        match hc.rm(addr) {
            Ok(()) => return Ok(()),
            Err(f) if f.not_found() => return Ok(()),
            Err(f) => {
                tries += 1;
                if tries >= 5 {
                    return Err(f.into_error("rm"));
                }
                r.sleep(Duration::from_secs(1));
            }
        }
    }
}

/// [`appdoc::ensure`] の結果を 1 行に (herdr-app の無いマシンの `new`・`restart`)。`!!` で始まる行は、名前を付けられ
/// なかったとき。`restart` なら、前と同じ名前のときにそう書く (space は前からあるので、herdr-app が作る話はしない)。
fn space_report(got: &Ensured, on: Option<&str>, name: &str, restart: bool) -> String {
    let what = appdoc::what(on);
    let kept = |tail: &str| {
        if restart {
            format!("space の名前: 前と同じ ({name}){tail}")
        } else {
            format!("space の名前: もう {name}{tail}")
        }
    };
    let unplaced = "。herdr-app は子の端末をまだ space に置いていない (動いていない・遅い)";
    match got {
        Ensured::Placed(Rename::Renamed { from, to }) => format!(
            "space の名前: herdr-app が label から作った space に付けた ({what} の版 {from} → {to})"
        ),
        Ensured::Placed(Rename::Same) => kept(""),
        Ensured::Unplaced(Rename::Renamed { from, to }) => {
            format!("space の名前: {what} の space に付けた (版 {from} → {to}){unplaced}")
        }
        Ensured::Unplaced(Rename::Same) => kept(unplaced),
        Ensured::Placed(Rename::Skip(why)) | Ensured::Unplaced(Rename::Skip(why)) => {
            format!("!! {why}")
        }
        Ensured::Placed(Rename::Failed(why)) | Ensured::Unplaced(Rename::Failed(why)) => {
            format!("!! space の名前を付けられない ({what}: {why})")
        }
        Ensured::Added { from, to } => format!(
            "space の名前: herdr-app が space を作らなかった (動いていない・遅い) ので、{what} に名前つきの space を足した (版 {from} → {to})。herdr-app が開くと、この space に子が出る"
        ),
        Ensured::Elsewhere(other) => format!(
            "!! 子の端末が {what} の別の space {other} にいるので、space の名前は付けない (要るなら herdr-app の画面で直す)"
        ),
        Ensured::Skip(why) if restart => format!("!! space の名前をそろえない ({why})"),
        Ensured::Skip(why) => format!(
            "!! space の名前を付けない ({why})。herdr-app が開くと label から space を作る (名前はフォルダ名)"
        ),
        Ensured::Failed(why) => format!("!! space を確かめられない ({what}: {why})"),
    }
}

pub fn restart(
    r: &dyn Runner,
    args: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let spec = Spec {
        flags: &["--chrome", "--no-chrome", "--force", "--fresh"],
        values: &[
            "--effort",
            "--pack",
            "--synced",
            "--session",
            "--brief",
            "--ticket",
            "--account",
        ],
    };
    let p = args::parse(args, &spec)?;
    if help(&p, out) {
        return Ok(exit::OK);
    }
    let [letter] = p.positionals.as_slice() else {
        return Err(Error::config(
            "立て直す子の英字を 1 つ渡す (pjp child restart A)",
        ));
    };
    if p.flag("--chrome") && p.flag("--no-chrome") {
        return Err(Error::config("--chrome と --no-chrome はどちらか 1 つ"));
    }
    // --fresh: 前の会話を続けずに新しい会話で立てる (前の作業の文脈を持ち越さない)。文脈が無いので依頼が要る
    let fresh = p.flag("--fresh");
    if fresh && p.value("--session")?.is_some() {
        return Err(Error::config("--fresh と --session はどちらか 1 つ"));
    }
    if fresh && p.value("--brief")?.is_none() {
        return Err(Error::config(
            "--fresh には --brief が要る (新しい会話は前の文脈を持たないので、引き継ぐことを依頼に書く)",
        ));
    }
    let brief = match p.value("--brief")? {
        Some(path) => Some(read_text_file(path)?),
        None => None,
    };
    let hc = Hc::new(r);
    hc.require()?;
    let parent = r
        .env("HC_TERMINAL_ID")
        .ok_or_else(|| Error::config("hc の端末の中で打つ (子はこの端末の子として立つ)"))?;
    let (ledger, _key) = open_ledger(r, &hc, p.value("--ticket")?)?;
    let row = super::find_child(&ledger, letter)?;
    if row.cleaned() {
        return Err(Error::failure(format!(
            "子 {} は片付けてある (立て直せない)",
            row.letter
        )));
    }
    if !row.live() {
        // 立てられなかった子の worktree は戻してあり、同じ名前で別の子が使っているかもしれない
        return Err(Error::failure(format!(
            "子 {} は立てられなかった子です ({})。pjp child new で立て直す",
            row.letter, row.state
        )));
    }
    if row.worktree.is_empty() || row.name.is_empty() {
        return Err(Error::failure(format!(
            "子 {} の控えに worktree か名前がありません",
            row.letter
        )));
    }
    // effort・pack・chrome は、渡されなければ控えの前の起動の値を引き継ぐ
    let effort = effort_of(
        &p,
        if row.effort.is_empty() {
            DEFAULT_EFFORT
        } else {
            &row.effort
        },
    )?;
    let chrome = if p.flag("--chrome") {
        true
    } else if p.flag("--no-chrome") {
        false
    } else {
        row.chrome == "1"
    };
    let (packs, synced) = if p.values("--pack").is_empty() && p.values("--synced").is_empty() {
        row.pack_lists()
    } else {
        (p.values("--pack").to_vec(), p.values("--synced").to_vec())
    };
    // アカウントは、渡されなければ控えの立てたときのもの。名前のアカウントは、前の端末を終える前に launcher と用意を確かめる
    let choice = account::choose_again(p.value("--account")?, &row.account)?;
    let settings = settings_for(r, &packs, &synced, err)?;
    let m = row.machine();
    let pr = probe(&hc, m, "")?;
    let ready = account::ready(&hc, m, &pr.claude, &pr.claude_account, &choice.account)?;
    let resume = match p.value("--session")? {
        Some(id) => Resume::Session(id),
        None if fresh => Resume::No,
        None => Resume::Continue,
    };
    let argv = child_argv(
        &ready.program,
        effort,
        chrome,
        settings.as_deref(),
        resume,
        brief.as_deref(),
    )?;
    // reassigned: 控えの住所に別の端末がいる (その端末も、その端末が立てた端末も、前の子のものではない)
    let (old, reassigned) = match super::child_terminal(&hc, &row)? {
        super::ChildTerm::Ours(t) => (Some(t), false),
        super::ChildTerm::Missing => (None, false),
        super::ChildTerm::Other(why) => {
            let _ = writeln!(
                err,
                "!! 控えの端末は別の端末になっている ({why})。前の端末は触らずに立てる"
            );
            (None, true)
        }
    };
    // 子のチケットの印は、前の端末から引き継ぐ (同じ会話の続き)。--fresh は別の作業のことが多いので引き継がない
    let ticket = old
        .as_ref()
        .filter(|_| !fresh)
        .and_then(|t| crate::hc::label_of(t, "pjp.ticket"))
        .map(str::to_owned);
    if fresh {
        let _ = writeln!(
            err,
            "note: --fresh なので子のチケットの印 (pjp.ticket) は引き継がない。依頼で、子に pjp mark name を打たせる"
        );
    } else if old.is_none() {
        // 前の端末が無いと、子のチケットの印を引き継げない (前の端末にも無かったなら、失うものは無い)
        let _ = writeln!(
            err,
            "note: 前の端末が無いので、子のチケットの印 (pjp.ticket) を引き継げない。続きの依頼で、子に pjp mark name を打ち直させる"
        );
    }
    // 解説動画の印 (spec 2026-11-21-spaces-video-mark-design.md の §7.5): 見ていない (✅) は新しい端末へ引き継ぐ (同じ space の
    // 行に出たまま。--fresh でも。印はユーザーのためのもので、会話の文脈ではない)。作りかけ (⏳) は、前の端末の Claude が動いて
    // いる (か分からない) 間は立て直さない (前の端末を終えると作るのが止まる。--force なら引き継がない)
    let videos = old.as_ref().map(video::videos_of).unwrap_or_default();
    let carried: Vec<String> = videos
        .iter()
        .filter(|v| v.state == State::Done)
        .map(Video::pair)
        .collect();
    let making = super::cleanup::names_of(&videos, State::Making);
    let still_making =
        !making.is_empty() && old.as_ref().is_some_and(super::cleanup::may_be_running);
    let labels = Labels {
        space: (!row.space.is_empty()).then(|| local_id(&row.space)),
        tab: (!row.tab.is_empty()).then(|| local_id(&row.tab)),
        letter: &row.letter,
        ticket: ticket.as_deref(),
        videos: &carried,
    };
    let run = run_args(m, &row.worktree, &row.name, &labels, &argv);
    check_cmdline(&run, "依頼")?;

    // 前の端末が立てた端末 (孫) を、前の端末を終える前に探す。探せなくても立て直しは止めない (再起動の後に使う)
    let old_state = match &old {
        Some(t) if !finished(t) => grand::OldTerm::Live,
        Some(_) => grand::OldTerm::Ended,
        None => grand::OldTerm::Gone,
    };
    let grands = if reassigned || row.terminal.is_empty() {
        Vec::new()
    } else {
        match grand::find(&hc, &row) {
            Ok(terms) => grand::inspect(&hc, m, &terms),
            Err(e) => {
                let _ = writeln!(
                    err,
                    "!! 前の端末が立てた端末 (孫) が残っていないかを確かめられない ({e})。そのまま立て直す"
                );
                Vec::new()
            }
        }
    };
    let (dying, staying) = grand::split(grands, old_state);

    // 前の端末と一緒に終わる孫がいる・子が working なら、--force が無ければ前の端末を終える前に止まる
    let force = p.flag("--force");
    let working = old
        .as_ref()
        .is_some_and(|t| !finished(t) && state_of(t) == Some("working"));
    if !force && !dying.is_empty() {
        return Err(Error::failure(grand::refusal(
            &row.letter,
            &row.terminal,
            &dying,
            working,
        )));
    }
    if !force && working {
        return Err(Error::failure(format!(
            "子 {} ({}) はまだ working です。止めて立て直すなら --force を付ける",
            row.letter, row.terminal
        )));
    }
    if !force && still_making {
        return Err(Error::failure(format!(
            "子 {} ({}) は解説動画を作っている ({making})。前の端末を終えると作るのが止まる。作り終えるのを待つか、止まっているなら --force で立て直す (作りかけの印は引き継がない)",
            row.letter, row.terminal
        )));
    }
    if !making.is_empty() {
        let why = if still_making {
            "--force。前の端末を終えると作るのが止まる"
        } else {
            "前の端末の Claude が終わっていて、作るのはもう止まっている"
        };
        let _ = writeln!(
            err,
            "note: 作りかけの解説動画の印 ({making}) は引き継がない ({why})"
        );
    }
    if !dying.is_empty() {
        let _ = write!(err, "{}", grand::ending(&row.terminal, &dying));
    }
    if !staying.is_empty() {
        let _ = write!(err, "{}", grand::notice(&row.terminal, old_state, &staying));
    }

    // herdr-app の無いマシンで label から作らせた space の子: 前の名前 (doc の今の名前、無ければ控え) を、立て直した後の
    // space にそろえる。前の端末を消すのは立てた後にする (先に消すと space が空になり、herdr-app が space を消して、同じ id で名前の
    // 空の space を作り直す)
    let by_label = !HerdrApp::new(r).available() && !row.space.is_empty() && !row.tab.is_empty();
    let want_name = if by_label {
        appdoc::name_of(&hc, m, &row.space)
            .or_else(|| (!row.space_name.is_empty()).then(|| row.space_name.clone()))
    } else {
        None
    };
    if let Some(name) = want_name.as_ref().filter(|n| **n != row.space_name) {
        // 立て直せずに終わっても、次の restart が名前を戻せるように、前の端末を終える前に控える
        ledger.update(&row.letter, |x| x.space_name = name.clone())?;
    }
    let defer_rm = by_label && old.is_some();

    // 前の端末を終える
    if old.is_some() {
        if defer_rm {
            // 立てられなかったときは消さずに残す (space・名前・並びが残り、次の restart も同じ道で通る)
            stop_terminal(&hc, &row.terminal)?;
            let _ = writeln!(
                out,
                "前の端末 {} を終えた (消すのは、新しい端末が space に入ってから。space を空にしない)",
                row.terminal
            );
        } else {
            end_terminal(r, &hc, &row.terminal)?;
            let _ = writeln!(out, "前の端末 {} を終えて消した", row.terminal);
        }
    }

    let addr = match hc.run(&run) {
        Ok(t) => t["address"].as_str().unwrap_or_default().to_owned(),
        // 前の端末 (終えただけで、まだ消していない) は、立った子とみない
        Err(e) => match super::find_live_soon(r, &hc, m, &row.name, Some(&row.terminal)) {
            Some(found) => {
                let _ = writeln!(
                    err,
                    "!! hc run は落ちたが ({e})、端末 {found} ({}) が立っているので、そのまま進める",
                    row.name
                );
                found
            }
            None => {
                if defer_rm {
                    // 前の端末は終えただけで消していないので、見ていない動画の印はそこに残る (次の restart が引き継ぎ、cleanup は
                    // この会話の端末へ移す)。ここで逃がすと写しができるので移さない
                    if !carried.is_empty() {
                        let _ = writeln!(
                            err,
                            "note: 見ていない解説動画の印 {} 本は、終えた前の端末 {} に残る (次の restart が引き継ぐ)",
                            carried.len(),
                            row.terminal
                        );
                    }
                } else {
                    // 前の端末はもう消したので、引き継ぐはずだった見ていない動画の印は、この会話の端末へ逃がす (黙って消さない)
                    rescue_videos(&hc, &parent, &videos, &row, err);
                }
                return Err(e);
            }
        },
    };
    // herdr-app が新しい端末を space に置くのを待ってから (置かなければ待ち終えてから)、前の端末を消す。先に消すと、herdr-app が
    // 「前の端末が消えた」を「新しい端末を置く」より先に読んで、space を消しうる
    let space_line = if by_label {
        let local = split_addr(&addr).1;
        Some(match &want_name {
            Some(name) => {
                let got = appdoc::ensure(
                    r,
                    &hc,
                    m,
                    &NewSpace {
                        id: &row.space,
                        tab: &row.tab,
                        name,
                        folder: &row.worktree,
                        terminal: local,
                    },
                    appdoc::PLACE_POLLS,
                );
                space_report(&got, m, name, true)
            }
            None => {
                let _ = appdoc::wait_placed(r, &hc, m, &row.space, local, appdoc::PLACE_POLLS);
                format!(
                    "note: space {} の前の名前が分からない (doc にも控えにも無い) ので、名前は付けない",
                    local_id(&row.space)
                )
            }
        })
    } else {
        None
    };
    if defer_rm {
        match remove_terminal(r, &hc, &row.terminal) {
            Ok(()) => {
                let _ = writeln!(out, "前の端末 {} を消した", row.terminal);
            }
            Err(e) => {
                let _ = writeln!(
                    err,
                    "!! 前の端末 {0} は終えたが消せない ({e})。hc rm {0} で消す",
                    row.terminal
                );
            }
        }
    }
    let now = r.now()?.to_jst().iso_seconds();
    ledger.update(&row.letter, |x| {
        x.state = state::LIVE.into();
        x.terminal = addr.clone();
        x.updated = now;
        x.effort = effort.to_owned();
        x.packs = crate::ledger::Row::join_packs(&packs, &synced);
        x.chrome = if chrome { "1" } else { "" }.to_owned();
        x.account = choice.account.ledger_value().to_owned();
    })?;
    let how = match resume {
        Resume::Session(id) => format!("--resume {id}"),
        Resume::No => "新しい会話 (--continue なし)".to_owned(),
        Resume::Continue => "--continue".to_owned(),
    };
    let pack_text = crate::ledger::Row::join_packs(&packs, &synced);
    let _ = writeln!(
        out,
        "子 {} を立て直した: {} ({addr})。{how}、effort {effort}、pack {}、chrome {}",
        row.letter,
        row.name,
        if pack_text.is_empty() {
            "なし"
        } else {
            &pack_text
        },
        if chrome { "使う" } else { "使わない" }
    );
    let _ = writeln!(out, "  worktree: {}", short_remote(&row.worktree, &pr.home));
    let _ = writeln!(out, "  アカウント: {}", account::describe(&choice, &ready));
    if !carried.is_empty() {
        let _ = writeln!(
            out,
            "  見ていない解説動画の印 {} 本を新しい端末へ引き継いだ ({})",
            carried.len(),
            super::cleanup::names_of(&videos, State::Done)
        );
    }
    // 子はもう立っているので、確かめられなくても失敗にしない。親が違うときだけ失敗 (子の報告が別の端末に打たれる)
    let parent_ok = match confirm(r, &hc, &addr, &parent, m, out) {
        Ok(ok) => ok,
        Err(e) => {
            let _ = writeln!(
                out,
                "  !! 子の状態を確かめられません ({e})。pjp child ls で見る"
            );
            true
        }
    };
    if let Some(line) = space_line {
        let _ = writeln!(out, "  {line}");
    }
    Ok(if parent_ok { exit::OK } else { exit::FAILURE })
}
