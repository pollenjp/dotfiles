//! 1 つの repo の判定と操作。
//!
//! start の順: 作業途中 (fetch しない) → origin が無い (fetch しない) → fetch --prune → 既定 branch か upstream が無い →
//! 取り込む commit が無ければ「最新」→ 既定 branch でない → 追跡中のファイルに変更がある → 分岐している →
//! merge --ff-only で fast-forward。そのまま進められない repo は問い (Outcome::Ask) を返し、HEAD を動かさない。
//! ahead / behind は既定 branch と、その upstream で数える。
//!
//! 作業途中 (index.lock を含む) の repo を fetch しないのは、index.lock がほかの git が動いている印で、fetch を重ねると
//! 互いの ref の書き込みがぶつかりうるため (問いは「何もしない」だけなので、今の差は要らない)。

use std::path::Path;

use crate::git::Git;
use crate::repo::{self, Busy, Head};

/// 確認待ちの理由
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reason {
    Busy(Busy),
    NoUpstream,
    FetchFailed {
        timed_out: bool,
        stderr: String,
    },
    NotOnDefault {
        head: Head,
        default_branch: String,
        behind: u32,
    },
    Dirty {
        behind: u32,
    },
    Diverged {
        ahead: u32,
        behind: u32,
    },
}

/// 問いで選べること (キーは s t u c f m r)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Choice {
    /// s 何もしない
    Skip,
    /// t もう一度 fetch する
    Retry,
    /// u checkout せずに既定 branch だけ進める
    BranchOnly,
    /// c 既定 branch に切り替えて進める
    Checkout,
    /// f そのまま fast-forward を試す
    TryFf,
    /// m merge commit を作る
    Merge,
    /// r rebase する
    Rebase,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Question {
    pub reason: Reason,
    pub choices: Vec<Choice>,
    /// 既定 branch ("main" など)。分かっていれば
    pub default_branch: Option<String>,
    /// 既定 branch の upstream ("refs/remotes/origin/main" など)。分かっていれば
    pub upstream: Option<String>,
    /// d で出す詳細 (git status -sb と、既定 branch と upstream の log)
    pub detail: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum How {
    FastForward,
    /// c で既定 branch に切り替えてから fast-forward した
    Switched,
    BranchOnly,
    Merged,
    Rebased,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// 取り込む commit が無い。ahead は未 push の commit の数
    UpToDate {
        ahead: u32,
    },
    /// commits 個の commit を取り込んだ
    Updated {
        how: How,
        commits: u32,
        branch: String,
    },
    Ask(Question),
    Skipped {
        reason: String,
    },
    Failed {
        what: String,
        stderr: String,
        conflict: bool,
    },
}

/// 進み具合 (画面の一覧に出す)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Checking,
    Fetching,
    Updating,
}

impl Reason {
    /// 問いの見出しとまとめに出す 1 行
    pub fn label(&self) -> String {
        match self {
            Reason::Busy(Busy::IndexLock) => "ほかの git が動いている (index.lock がある)".into(),
            Reason::Busy(Busy::Rebase) => "rebase の途中".into(),
            Reason::Busy(Busy::Merge) => "merge の途中".into(),
            Reason::Busy(Busy::CherryPick) => "cherry-pick の途中".into(),
            Reason::Busy(Busy::Revert) => "revert の途中".into(),
            Reason::NoUpstream => "既定 branch か upstream が無い".into(),
            Reason::FetchFailed {
                timed_out: true, ..
            } => "fetch が時間切れ".into(),
            Reason::FetchFailed { .. } => "fetch に失敗した".into(),
            Reason::NotOnDefault {
                head,
                default_branch,
                behind,
            } => {
                let at = match head {
                    Head::Branch(b) => format!("{b} にいる"),
                    Head::Detached => "detached HEAD".into(),
                };
                format!("既定 branch ({default_branch}) でない ({at})・behind {behind}")
            }
            Reason::Dirty { behind } => {
                format!("追跡中のファイルに変更がある・behind {behind}")
            }
            Reason::Diverged { ahead, behind } => {
                format!("分岐している (ahead {ahead} / behind {behind})")
            }
        }
    }
}

impl Choice {
    pub fn key(self) -> char {
        match self {
            Choice::Skip => 's',
            Choice::Retry => 't',
            Choice::BranchOnly => 'u',
            Choice::Checkout => 'c',
            Choice::TryFf => 'f',
            Choice::Merge => 'm',
            Choice::Rebase => 'r',
        }
    }

    pub fn label(self, default_branch: &str) -> String {
        match self {
            Choice::Skip => "何もしない".into(),
            Choice::Retry => "もう一度 fetch する".into(),
            Choice::BranchOnly => format!("checkout せずに {default_branch} だけ進める"),
            Choice::Checkout => format!("{default_branch} に切り替えて進める"),
            Choice::TryFf => "そのまま fast-forward を試す".into(),
            Choice::Merge => "merge commit を作る".into(),
            Choice::Rebase => "rebase する".into(),
        }
    }
}

pub fn start(git: &Git, dir: &Path, phase: &dyn Fn(Phase)) -> Outcome {
    phase(Phase::Checking);
    // git -C が外側の repo を指すと、選んでいない repo を触ってしまう
    if !repo::is_work_tree_root(git, dir) {
        return Outcome::Skipped {
            reason: "git の work tree の直下ではない (bare の repo か、git の repo の外)".into(),
        };
    }
    if let Some(busy) = repo::busy(git, dir) {
        return ask(git, dir, Reason::Busy(busy), vec![Choice::Skip], None, None);
    }
    if !repo::has_origin(git, dir) {
        return ask(git, dir, Reason::NoUpstream, vec![Choice::Skip], None, None);
    }
    if git.stopped() {
        return stopped();
    }
    phase(Phase::Fetching);
    let out = git.fetch(dir);
    if !out.success {
        let reason = Reason::FetchFailed {
            timed_out: out.timed_out,
            stderr: out.stderr,
        };
        return ask(
            git,
            dir,
            reason,
            vec![Choice::Skip, Choice::Retry],
            None,
            None,
        );
    }
    decide(git, dir, phase)
}

/// fetch の後の判定
fn decide(git: &Git, dir: &Path, phase: &dyn Fn(Phase)) -> Outcome {
    let Some(branch) = repo::default_branch(git, dir) else {
        return ask(git, dir, Reason::NoUpstream, vec![Choice::Skip], None, None);
    };
    let Some(up) = repo::upstream(git, dir, &branch) else {
        return ask(
            git,
            dir,
            Reason::NoUpstream,
            vec![Choice::Skip],
            Some(branch),
            None,
        );
    };
    let Some((ahead, behind)) = repo::ahead_behind(git, dir, &branch, &up) else {
        return ask(
            git,
            dir,
            Reason::NoUpstream,
            vec![Choice::Skip],
            Some(branch),
            Some(up),
        );
    };
    if behind == 0 {
        return Outcome::UpToDate { ahead };
    }
    let head = repo::head(git, dir);
    let dirty = repo::dirty(git, dir);
    if head != Head::Branch(branch.clone()) {
        let mut choices = vec![Choice::Skip, Choice::BranchOnly];
        // detached HEAD の commit がどの branch にも無ければ、切り替えると置き去りになるので c を出さない
        if !dirty && (head != Head::Detached || repo::head_on_some_branch(git, dir)) {
            choices.push(Choice::Checkout);
        }
        let reason = Reason::NotOnDefault {
            head,
            default_branch: branch.clone(),
            behind,
        };
        return ask(git, dir, reason, choices, Some(branch), Some(up));
    }
    if dirty {
        return ask(
            git,
            dir,
            Reason::Dirty { behind },
            vec![Choice::Skip, Choice::TryFf],
            Some(branch),
            Some(up),
        );
    }
    if ahead > 0 {
        return ask(
            git,
            dir,
            Reason::Diverged { ahead, behind },
            vec![Choice::Skip, Choice::Merge, Choice::Rebase],
            Some(branch),
            Some(up),
        );
    }
    fast_forward(git, dir, &branch, &up, behind, phase)
}

fn fast_forward(
    git: &Git,
    dir: &Path,
    branch: &str,
    up: &str,
    behind: u32,
    phase: &dyn Fn(Phase),
) -> Outcome {
    if git.stopped() {
        return stopped();
    }
    phase(Phase::Updating);
    let out = git.run(dir, &["merge", "--ff-only", "--no-autostash", up]);
    if out.success {
        Outcome::Updated {
            how: How::FastForward,
            commits: behind,
            branch: branch.to_string(),
        }
    } else {
        Outcome::Failed {
            what: "fast-forward できなかった".into(),
            stderr: out.stderr,
            conflict: false,
        }
    }
}

/// 問いへの答えを流す。u・c・f・m・r は、流す前に判定をやり直し、同じ理由の問いで同じ答えが選べるときだけ流す
/// (問いが待っている間にユーザーが repo を触ることがあるため)。そうでなければ、やり直した判定の結果を返す
pub fn answer(
    git: &Git,
    dir: &Path,
    q: &Question,
    choice: Choice,
    phase: &dyn Fn(Phase),
) -> Outcome {
    match choice {
        Choice::Skip => Outcome::Skipped {
            reason: q.reason.label(),
        },
        Choice::Retry => start(git, dir, phase),
        _ => {
            phase(Phase::Checking);
            match recheck(git, dir, q, choice, phase) {
                Recheck::Go(target) => act(git, dir, &target, choice, phase),
                Recheck::Stop(outcome) => outcome,
            }
        }
    }
}

/// 答えを流す相手: 既定 branch・その upstream・取り込む commit の数
struct Target {
    branch: String,
    up: String,
    behind: u32,
}

/// 判定をやり直した結果: 答えを流す (Go) か、やり直した判定の結果を返す (Stop)
enum Recheck {
    Go(Target),
    Stop(Outcome),
}

fn recheck(git: &Git, dir: &Path, q: &Question, choice: Choice, phase: &dyn Fn(Phase)) -> Recheck {
    match decide(git, dir, phase) {
        Outcome::Ask(now)
            if std::mem::discriminant(&now.reason) == std::mem::discriminant(&q.reason)
                && now.choices.contains(&choice) =>
        {
            let behind = match now.reason {
                Reason::NotOnDefault { behind, .. }
                | Reason::Dirty { behind }
                | Reason::Diverged { behind, .. } => behind,
                _ => return Recheck::Stop(Outcome::Ask(now)),
            };
            match (&now.default_branch, &now.upstream) {
                (Some(branch), Some(up)) => Recheck::Go(Target {
                    branch: branch.clone(),
                    up: up.clone(),
                    behind,
                }),
                _ => Recheck::Stop(Outcome::Ask(now)),
            }
        }
        other => Recheck::Stop(other),
    }
}

fn act(git: &Git, dir: &Path, t: &Target, choice: Choice, phase: &dyn Fn(Phase)) -> Outcome {
    if git.stopped() {
        return stopped();
    }
    phase(Phase::Updating);
    let branch = t.branch.as_str();
    let up = t.up.as_str();
    let updated = |how| Outcome::Updated {
        how,
        commits: t.behind,
        branch: branch.to_string(),
    };
    let failed = |what: String, stderr: String, conflict: bool| Outcome::Failed {
        what,
        stderr,
        conflict,
    };
    match choice {
        Choice::BranchOnly => {
            // fast-forward でない・別の worktree で checkout 中なら git が断る
            let spec = format!("{up}:refs/heads/{branch}");
            let out = git.run(
                dir,
                &[
                    "fetch",
                    "--no-prune",
                    "--no-tags",
                    "--no-recurse-submodules",
                    ".",
                    &spec,
                ],
            );
            if out.success {
                updated(How::BranchOnly)
            } else {
                failed(format!("{branch} を進められなかった"), out.stderr, false)
            }
        }
        Choice::Checkout => {
            let out = git.run(dir, &["switch", branch]);
            if out.success {
                match decide(git, dir, phase) {
                    Outcome::Updated {
                        how: How::FastForward,
                        commits,
                        branch,
                    } => Outcome::Updated {
                        how: How::Switched,
                        commits,
                        branch,
                    },
                    other => other,
                }
            } else {
                failed(
                    format!("{branch} に切り替えられなかった"),
                    out.stderr,
                    false,
                )
            }
        }
        Choice::TryFf => {
            let out = git.run(dir, &["merge", "--ff-only", "--no-autostash", up]);
            if out.success {
                updated(How::FastForward)
            } else {
                failed("fast-forward できなかった".into(), out.stderr, false)
            }
        }
        Choice::Merge => {
            let out = git.run(dir, &["merge", "--no-edit", "--no-autostash", up]);
            if out.success {
                updated(How::Merged)
            } else if repo::busy(git, dir) == Some(Busy::Merge) {
                git.run(dir, &["merge", "--abort"]);
                failed("merge で衝突したので元に戻した".into(), out.stderr, true)
            } else {
                failed("merge できなかった".into(), out.stderr, false)
            }
        }
        Choice::Rebase => {
            let out = git.run(dir, &["rebase", "--no-autostash", "--no-update-refs", up]);
            if out.success {
                updated(How::Rebased)
            } else if repo::busy(git, dir) == Some(Busy::Rebase) {
                git.run(dir, &["rebase", "--abort"]);
                failed("rebase で衝突したので元に戻した".into(), out.stderr, true)
            } else {
                failed("rebase できなかった".into(), out.stderr, false)
            }
        }
        Choice::Skip | Choice::Retry => unreachable!("answer が先に扱う"),
    }
}

/// q・Ctrl-C で止めた後は、次の git を起こさずにスキップにする (動いていた git は終わらせてある)
fn stopped() -> Outcome {
    Outcome::Skipped {
        reason: "やめたので途中で止めた".into(),
    }
}

fn ask(
    git: &Git,
    dir: &Path,
    reason: Reason,
    choices: Vec<Choice>,
    default_branch: Option<String>,
    upstream: Option<String>,
) -> Outcome {
    let mut detail = detail(git, dir, default_branch.as_deref(), upstream.as_deref());
    if let Reason::FetchFailed { stderr, .. } = &reason {
        detail = format!("fetch の stderr:\n{}\n\n{detail}", stderr.trim_end());
    }
    Outcome::Ask(Question {
        reason,
        choices,
        default_branch,
        upstream,
        detail,
    })
}

/// git status -sb と、既定 branch と upstream の log (< は手元だけ・> は upstream だけの commit)
fn detail(git: &Git, dir: &Path, branch: Option<&str>, up: Option<&str>) -> String {
    let mut text = git
        .run(dir, &["--no-optional-locks", "status", "-sb"])
        .stdout;
    if let (Some(branch), Some(up)) = (branch, up) {
        let range = format!("{branch}...{up}");
        let log = git.run(
            dir,
            &[
                "log",
                "--oneline",
                "--no-show-signature",
                "--left-right",
                "-n",
                "20",
                &range,
            ],
        );
        if !log.stdout.trim().is_empty() {
            text.push_str(&format!(
                "\n{branch}...{} (< 手元だけ / > upstream だけ。新しい方から 20 まで)\n",
                repo::short_ref(up)
            ));
            text.push_str(&log.stdout);
        }
    }
    text
}
