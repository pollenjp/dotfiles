//! pjp-ghq-pull の入口。引数 → 端末か → gitViaGh の事前確認 → ghq の repo の一覧 → 手元の状態 → 選ぶ画面 →
//! 実行中の画面 → 画面を閉じて stdout にまとめ、の順に流す。

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::Ordering;
use std::sync::{Arc, mpsc};
use std::time::Duration;

use pjp_ghq_pull::cli::{self, Cmd};
use pjp_ghq_pull::discover::{self, Found};
use pjp_ghq_pull::flow::{self, Outcome};
use pjp_ghq_pull::git::Git;
use pjp_ghq_pull::repo::{self, Info};
use pjp_ghq_pull::run::{Effect, Run};
use pjp_ghq_pull::runner::{Job, Runner, Work};
use pjp_ghq_pull::selection::{Action, Item, Selection};
use pjp_ghq_pull::{state, summary, ui, via_gh};
use ratatui::DefaultTerminal;
use ratatui::crossterm::event::{self, Event, KeyEventKind};

/// 実行中の画面で、キーと作業の列の知らせを見る間隔
const TICK: Duration = Duration::from_millis(100);

fn main() -> ExitCode {
    let opts = match cli::parse(std::env::args_os().skip(1)) {
        Ok(Cmd::Run(opts)) => opts,
        Ok(Cmd::Help) => {
            print!("{}", cli::USAGE);
            return ExitCode::SUCCESS;
        }
        Ok(Cmd::Version) => {
            println!("pjp-ghq-pull {}", pjp_ghq_pull::VERSION);
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("pjp-ghq-pull: {e}\n\n{}", cli::USAGE);
            return ExitCode::from(2);
        }
    };
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        eprintln!(
            "pjp-ghq-pull: 端末で起こしてください (選ぶ画面と問いに端末が要ります)。何もせずに止まります。"
        );
        return ExitCode::from(2);
    }

    let home = std::env::var_os("HOME").map(PathBuf::from);
    let via_gh = via_gh::resolve(opts.via_gh, home.as_deref());
    if via_gh && let Err(e) = via_gh::preflight(&std::env::var_os("PATH").unwrap_or_default()) {
        eprintln!("pjp-ghq-pull: {e}");
        return ExitCode::from(1);
    }
    let found = match discover::ghq_repos(opts.root.as_deref(), &[]) {
        Ok(found) => found,
        Err(e) => {
            eprintln!("pjp-ghq-pull: {e}");
            return ExitCode::from(1);
        }
    };
    if found.is_empty() {
        eprintln!("pjp-ghq-pull: ghq の repo がありません。");
        return ExitCode::from(1);
    }

    let git = Arc::new(Git::new(via_gh, opts.timeout, Vec::new()));
    let infos = inspect(&git, &found, opts.jobs);
    let items = found
        .into_iter()
        .zip(infos)
        .map(|(f, info)| Item {
            path: f.path,
            rel: f.rel,
            org: f.org,
            name: f.name,
            info,
            selected: true,
        })
        .collect();
    let state_path = state::path_from(std::env::var_os("XDG_STATE_HOME"), std::env::var_os("HOME"));
    let deselected = state_path.as_deref().map(state::load).unwrap_or_default();
    let mut sel = Selection::with_deselected(items, &deselected);
    let route = via_gh::route_label(via_gh);

    let mut terminal = ratatui::init();
    quiet_worker_panics();
    let result = tui(
        &mut terminal,
        &mut sel,
        &git,
        route,
        opts.jobs,
        state_path.as_deref(),
    );
    ratatui::restore();
    match result {
        Err(e) => {
            eprintln!("pjp-ghq-pull: 画面を描けませんでした: {e}");
            ExitCode::from(1)
        }
        Ok(None) => {
            println!("pjp-ghq-pull: やめました (何もしていません)。");
            ExitCode::SUCCESS
        }
        Ok(Some(outcomes)) => {
            print!("{}", summary::render(&outcomes));
            ExitCode::from(summary::exit_code(&outcomes))
        }
    }
}

/// 各 repo の手元の状態 (branch・既定 branch・変更) を jobs 本の thread で読む
fn inspect(git: &Git, found: &[Found], jobs: usize) -> Vec<Info> {
    let chunk = found.len().div_ceil(jobs.max(1)).max(1);
    std::thread::scope(|s| {
        let handles: Vec<_> = found
            .chunks(chunk)
            .map(|part| {
                s.spawn(move || {
                    part.iter()
                        .map(|f| repo::info(git, &f.path))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        handles
            .into_iter()
            .flat_map(|h| h.join().expect("repo の状態を読む thread が止まった"))
            .collect()
    })
}

/// ratatui::init の panic hook は、どの thread の panic でも端末を元に戻す。作業の thread の panic は runner が
/// 「失敗」にして返すので、画面を壊さないよう、main の thread の panic だけを渡す
fn quiet_worker_panics() {
    let restore_and_report = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if std::thread::current().name() == Some("main") {
            restore_and_report(info);
        }
    }));
}

fn tui(
    terminal: &mut DefaultTerminal,
    sel: &mut Selection,
    git: &Arc<Git>,
    route: &str,
    jobs: usize,
    state_path: Option<&Path>,
) -> std::io::Result<Option<Vec<(String, Outcome)>>> {
    loop {
        terminal.draw(|f| ui::draw_select(f, sel, route))?;
        if let Event::Key(key) = event::read()?
            && key.kind == KeyEventKind::Press
        {
            match sel.on_key(key) {
                Action::Start => break,
                Action::Quit => return Ok(None),
                Action::None => {}
            }
        }
    }
    if let Some(path) = state_path {
        // 書けなくても続ける (次に開いたときの初期値が全部 on になるだけ)
        let _ = state::save(path, &sel.deselected());
    }

    let chosen: Vec<&Item> = sel.items().iter().filter(|i| i.selected).collect();
    let paths: Arc<Vec<PathBuf>> = Arc::new(chosen.iter().map(|i| i.path.clone()).collect());
    let mut run = Run::new(chosen.iter().map(|i| i.rel.clone()).collect());
    let work: Work = {
        let git = Arc::clone(git);
        let paths = Arc::clone(&paths);
        Arc::new(move |job, phase| match job {
            Job::Start(id) => flow::start(&git, &paths[*id], phase),
            Job::Answer(id, q, choice) => flow::answer(&git, &paths[*id], q, *choice, phase),
        })
    };
    let (tx, rx) = mpsc::channel();
    let runner = Runner::spawn(jobs, work, tx);
    for id in 0..paths.len() {
        runner.push(Job::Start(id));
    }
    let result = run_loop(terminal, &mut run, &runner, &rx, route, git);
    runner.shutdown();
    result?;
    Ok(Some(run.outcomes()))
}

fn run_loop(
    terminal: &mut DefaultTerminal,
    run: &mut Run,
    runner: &Runner,
    rx: &mpsc::Receiver<pjp_ghq_pull::runner::Msg>,
    route: &str,
    git: &Git,
) -> std::io::Result<()> {
    loop {
        terminal.draw(|f| ui::draw_run(f, run, route))?;
        let mut effects = Vec::new();
        if event::poll(TICK)?
            && let Event::Key(key) = event::read()?
            && key.kind == KeyEventKind::Press
        {
            effects.extend(run.on_key(key));
        }
        while let Ok(msg) = rx.try_recv() {
            effects.extend(run.on_msg(msg));
        }
        let mut exit = false;
        let mut i = 0;
        while i < effects.len() {
            match effects[i].clone() {
                Effect::Enqueue(job) => runner.push(job),
                Effect::Drain => {
                    // 動いている repo の流れにも、次の git を起こさせない (動いている git は終わらせる)
                    git.stop.store(true, Ordering::SeqCst);
                    let ids = runner.drain();
                    effects.extend(run.on_drained(&ids));
                }
                Effect::Exit => exit = true,
            }
            i += 1;
        }
        if exit {
            return Ok(());
        }
    }
}
