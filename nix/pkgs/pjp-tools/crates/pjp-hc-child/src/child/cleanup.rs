//! `pjp child cleanup` (spec §7.8): 確かめてから、子の端末を終えて消し、space を閉じ、worktree と branch を消す。
//!
//! 子を終えるのは `hc kill` → `hc rm`。`hc send` の `/exit` は `<hc from=…>/exit</hc>` の札つきの文として届き、command として
//! 効かない (指揮役が確かめた。hc の手引きの片付けも kill → rm)。
//!
//! 解説動画の印 (spec `2026-11-21-spaces-video-mark-design.md` の §7.5): 子の端末の見ていない動画 (✅) は、子を終える前に
//! この会話の端末 (無ければ子の hc の親) へ移す (ユーザーが見るまで親の行に出る)。作りかけ (⏳) があれば、子の Claude が
//! 動いている間は片付けない (子を終えると作るのが止まる。`--force` なら捨てる)。

use std::io::Write;

use pjp_core::process::Cmd;
use pjp_core::{Error, Result, exit};
use serde_json::{Value, json};

use super::agent::{Agent, agent_of};
use super::new::end_terminal;
use super::{ChildTerm, child_terminal, find_child, grand, help, open_ledger, short_remote};
use crate::appdoc::{self, Others, Removed};
use crate::args::{self, Spec};
use crate::hc::{Hc, HerdrApp, Runner, app_id, finished, first_line, split_addr, state_of};
use crate::ledger::{Row, state};
use crate::mark::video::{self, State, Video};

/// gh を待つ長さ。
const GH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

/// 子の作業の branch の PR (gh で引く。fork からの PR は数えない)。
#[derive(Debug, Clone, PartialEq, Eq)]
enum PrState {
    /// merge 済み。PR の head の commit (`headRefOid`) を持つ。
    Merged {
        show: String,
        oid: String,
    },
    Open(String),
    None,
}

fn pr_state(r: &dyn Runner, repo: &str, branch: &str) -> Result<PrState> {
    if r.which("gh").is_none() {
        return Err(Error::config("gh が見つかりません (PR を確かめるのに使う)"));
    }
    let cmd = Cmd::new("gh")
        .args([
            "pr",
            "list",
            "--repo",
            repo,
            "--head",
            branch,
            "--state",
            "all",
            "--json",
            "number,state,url,headRefOid,isCrossRepository",
            "--limit",
            "30",
        ])
        .timeout(GH_TIMEOUT);
    let out = r.run(&cmd)?;
    if !out.success() {
        return Err(Error::failure(format!(
            "gh pr list が落ちました: {}",
            first_line(&out.stderr)
        )));
    }
    let prs: Vec<Value> = serde_json::from_str(out.stdout.trim()).unwrap_or_default();
    let ours: Vec<&Value> = prs
        .iter()
        .filter(|p| p["isCrossRepository"].as_bool() != Some(true))
        .collect();
    let show = |p: &Value| format!("#{} {}", p["number"], p["url"].as_str().unwrap_or(""));
    if let Some(p) = ours.iter().find(|p| p["state"] == "OPEN") {
        return Ok(PrState::Open(show(p)));
    }
    if let Some(p) = ours.iter().find(|p| p["state"] == "MERGED") {
        return Ok(PrState::Merged {
            show: show(p),
            oid: p["headRefOid"].as_str().unwrap_or_default().to_owned(),
        });
    }
    Ok(PrState::None)
}

/// `git reflog` の文 (`checkout: moving from <branch> to <先>`) から、HEAD を離す前の branch を引く。
fn branch_before_detach(reflog: &str) -> Option<&str> {
    reflog.lines().find_map(|l| {
        let rest = l.trim().strip_prefix("checkout: moving from ")?;
        let (from, _) = rest.split_once(" to ")?;
        (!from.is_empty() && !from.contains(' ')).then_some(from)
    })
}

/// worktree の作業の branch。今の branch、detached なら reflog の直前の branch (merge の後の作業で
/// `git switch --detach origin/main` した worktree)。
fn work_branch(
    hc: &Hc<'_>,
    m: Option<&str>,
    row: &Row,
    out: &mut dyn Write,
) -> Result<Option<String>> {
    let cur = hc.exec(
        m,
        None,
        30,
        &["git", "-C", &row.worktree, "branch", "--show-current"],
    )?;
    if cur.ok() && !cur.stdout.trim().is_empty() {
        return Ok(Some(cur.stdout.trim().to_owned()));
    }
    let log = hc.exec(
        m,
        None,
        30,
        &[
            "git",
            "-C",
            &row.worktree,
            "reflog",
            "show",
            "--format=%gs",
            "-n",
            "50",
            "HEAD",
        ],
    )?;
    if !log.ok() {
        return Ok(None);
    }
    let Some(b) = branch_before_detach(&log.stdout) else {
        return Ok(None);
    };
    let exists = hc.exec(
        m,
        None,
        30,
        &[
            "git",
            "-C",
            &row.worktree,
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("refs/heads/{b}"),
        ],
    )?;
    if !exists.ok() {
        return Ok(None);
    }
    let _ = writeln!(
        out,
        "worktree は detached HEAD。reflog の直前の branch {b} を作業の branch とみる"
    );
    Ok(Some(b.to_owned()))
}

pub fn cleanup(
    r: &dyn Runner,
    args: &[String],
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<u8> {
    let p = args::parse(
        args,
        &Spec {
            flags: &["--no-pr", "--force", "--dry-run"],
            values: &["--ticket", "--branch", "--repo"],
        },
    )?;
    if help(&p, out) {
        return Ok(exit::OK);
    }
    let [letter] = p.positionals.as_slice() else {
        return Err(Error::config(
            "片付ける子の英字を 1 つ渡す (pjp child cleanup A)",
        ));
    };
    let (no_pr, force, dry) = (p.flag("--no-pr"), p.flag("--force"), p.flag("--dry-run"));
    let hc = Hc::new(r);
    hc.require()?;
    let (ledger, _) = open_ledger(r, &hc, p.value("--ticket")?)?;
    let row = find_child(&ledger, letter)?;
    if row.cleaned() {
        let _ = writeln!(out, "子 {} はもう片付けてある", row.letter);
        return Ok(exit::OK);
    }
    if !row.live() {
        // 立てられなかった子: worktree と branch は戻してあり、同じ名前で別の子が使っているかもしれないので触らない
        if !dry {
            let now = r.now()?.to_jst().iso_seconds();
            ledger.update(&row.letter, |x| {
                x.state = state::CLEANED.into();
                x.updated = now;
            })?;
        }
        let _ = writeln!(
            out,
            "子 {} は立てられなかった子 ({})。控えだけを片付けた{} (worktree・branch・端末には触らない。{} が残っていれば手で消す)",
            row.letter,
            row.state,
            if dry {
                " (--dry-run なので書いていない)"
            } else {
                ""
            },
            if row.worktree.is_empty() {
                "-"
            } else {
                &row.worktree
            }
        );
        return Ok(exit::OK);
    }
    let m = row.machine();
    let has_worktree = !row.branch.is_empty();

    // 1. 確かめる (どれかが外れたら何もしない)
    let mut problems: Vec<String> = Vec::new();
    // reassigned: 控えの住所に別の端末がいる (その端末は子ではない)
    let (term, reassigned) = match child_terminal(&hc, &row)? {
        ChildTerm::Ours(t) => (Some(t), false),
        ChildTerm::Missing => (None, false),
        ChildTerm::Other(why) => {
            let _ = writeln!(
                err,
                "!! 控えの端末は別の端末になっている ({why})。その端末は終えない"
            );
            (None, true)
        }
    };
    if let Some(t) = &term
        && !finished(t)
        && state_of(t) == Some("working")
        && !force
    {
        problems.push(format!(
            "子の端末 {} はまだ working (最後の発言の頭が「作業中」なら終わっていない。止めてよいなら --force)",
            row.terminal
        ));
    }

    // 解説動画の印: 作りかけ (⏳) は、子の Claude が動いている (か分からない) 間は片付けない。見ていない (✅) は移す先を決める
    let videos = term.as_ref().map(video::videos_of).unwrap_or_default();
    let making = names_of(&videos, State::Making);
    let still_making = !making.is_empty() && term.as_ref().is_some_and(may_be_running);
    if still_making && !force {
        problems.push(format!(
            "子 {} は解説動画を作っている ({making})。作り終えるのを待つ。止まっているなら子に pjp mark video stop を打たせるか、--force で片付ける (作りかけの印は捨てる)",
            row.letter
        ));
    }
    let unwatched: Vec<Video> = videos
        .iter()
        .filter(|v| v.state == State::Done)
        .cloned()
        .collect();
    let home = video_home(r, &hc, term.as_ref(), &unwatched)?;
    if !unwatched.is_empty() && home.is_none() && !force {
        problems.push(format!(
            "見ていない解説動画の印 ({}) を移す先が無い (この会話の端末も子の hc の親も hc にいない)。--force で片付ける (印は子と一緒に消える)",
            names_of(&videos, State::Done)
        ));
    }

    let mut branch: Option<String> = p.value("--branch")?.map(str::to_owned);
    if has_worktree {
        let st = hc.exec(
            m,
            None,
            60,
            &["git", "-C", &row.worktree, "status", "--short"],
        )?;
        if !st.ok() {
            problems.push(format!(
                "worktree {} の status を読めません: {}",
                row.worktree,
                st.why()
            ));
        } else if !st.stdout.trim().is_empty() {
            let lines: Vec<&str> = st.stdout.lines().take(10).collect();
            problems.push(format!(
                "worktree {} に commit していない変更がある:\n      {}",
                row.worktree,
                lines.join("\n      ")
            ));
        }
        if branch.is_none() {
            branch = work_branch(&hc, m, &row, out)?;
        }
    }
    // 作業の branch (worktree を作ったときの worktree/<名前> のほか)
    let work = branch.as_deref().filter(|b| *b != row.branch);

    // PR を確かめる repo: 控えの repo (--repo で立てた子)。控えに無い子 (--checkout・--dir で立てた子) は --repo で渡せる
    let repo = match p.value("--repo")? {
        Some(given) if !row.repo.is_empty() && given != row.repo => {
            return Err(Error::config(format!(
                "--repo {given} が控えの repo ({}) と違います (控えに repo のある子には --repo は要らない)",
                row.repo
            )));
        }
        Some(given) => given.to_owned(),
        None => row.repo.clone(),
    };
    let mut merged_oid: Option<String> = None;
    if !no_pr {
        if repo.is_empty() {
            problems.push(
                "repo (owner/repo) が分からないので PR を確かめられない (--repo <owner/repo> で渡す。PR の無い子なら --no-pr)"
                    .to_owned(),
            );
        } else {
            match (branch.as_deref(), work) {
                (None, _) => problems.push(
                    "子の作業の branch が分からない (--branch <作業の branch> で渡す。PR の無い子なら --no-pr)".to_owned(),
                ),
                (Some(b), None) => problems.push(format!(
                    "子は作業の branch を切っていない ({b} のまま。PR の無い子なら --no-pr)"
                )),
                (_, Some(b)) => match pr_state(r, &repo, b)? {
                    PrState::Merged { oid, .. } => merged_oid = Some(oid),
                    PrState::Open(pr) => problems.push(format!("PR {pr} がまだ open (merge されてから片付ける)")),
                    PrState::None => {
                        problems.push(format!("branch {b} の PR がありません (PR の無い子なら --no-pr)"));
                    }
                },
            }
        }
    }

    if !row.terminal.is_empty() {
        // 子のマシンの一覧で、子の端末を親に持つ生きた端末 (孫) を探す
        match grand::find(&hc, &row) {
            Ok(terms) => {
                let kids: Vec<String> = terms.iter().map(grand::label).collect();
                if !kids.is_empty() {
                    problems.push(format!(
                        "子に生きている子 (孫) がいる: {} (先に子に孫を片付けさせる)",
                        kids.join("・")
                    ));
                }
            }
            Err(e) if !force => problems.push(format!(
                "孫がいないかを確かめられない ({e})。確かめてから --force で片付ける"
            )),
            Err(_) => {}
        }
    }

    // herdr-app の無いマシン: 子の space に子のほかの端末 (ユーザーが開いた shell など) がいれば片付けない。space.close
    // が使えず、自分が立てていない端末は終わらせないので、片付けるとその端末と space が残り、端末は消えた worktree に居ることになる
    let ended = (!reassigned).then(|| split_addr(&row.terminal).1);
    if !row.space.is_empty()
        && !HerdrApp::new(r).available()
        && let Ok(others) = appdoc::others(&hc, m, &row.space, ended)
        && !others.is_empty()
        && !force
    {
        problems.push(format!(
            "子の space {} に、子のほかの端末 ({}) がいる。herdr-app の画面で閉じてから片付ける (閉じずに進めるなら --force。その端末と space は残し、worktree は消す)",
            app_id(&row.space, m),
            others_text(&others, m)
        ));
    }

    if !problems.is_empty() {
        let _ = writeln!(out, "子 {} ({}) を片付けない:", row.letter, row.name);
        for pr in &problems {
            let _ = writeln!(out, "  - {pr}");
        }
        return Ok(exit::FAILURE);
    }

    let checkout = row.checkout.as_str();
    if dry {
        let _ = writeln!(
            out,
            "(--dry-run) 子 {} ({}) を片付けるなら、次のとおりに打つ",
            row.letter, row.name
        );
        if let Some((h, home_term)) = &home {
            let pairs = video::moved_pairs(&unwatched, home_term, &moved_from(&row));
            for pair in &pairs {
                let _ = writeln!(out, "  hc label {h} {pair}");
            }
            if !pairs.is_empty() {
                let _ = writeln!(
                    out,
                    "  (見ていない解説動画の印 {} 本を移す。ユーザーが見るまで {h} の行に出る)",
                    pairs.len()
                );
            }
        } else if !unwatched.is_empty() {
            let _ = writeln!(
                out,
                "  (見ていない解説動画の印 {} は移す先が無いので、子と一緒に消える)",
                names_of(&unwatched, State::Done)
            );
        }
        if !making.is_empty() {
            let _ = writeln!(
                out,
                "  (作りかけの解説動画の印 {making} は移さない。子と一緒に作るのが止まる)"
            );
        }
        if term.is_some() {
            let _ = writeln!(out, "  hc kill {0} → hc wait {0} → hc rm {0}", row.terminal);
        }
        if !row.space.is_empty() {
            if HerdrApp::new(r).available() {
                let _ = writeln!(
                    out,
                    "  herdr-app do space.close {}",
                    json!({"id": app_id(&row.space, m), "confirmed": true})
                );
            } else {
                let _ = writeln!(
                    out,
                    "  {} から space {} が消えるのを待つ (子の端末を消すと herdr-app が消す)。残っていて、中にほかの生きた端末が無ければ doc から消す",
                    appdoc::what(m),
                    app_id(&row.space, m)
                );
            }
        }
        if has_worktree {
            let _ = writeln!(out, "  git -C {checkout} worktree remove {}", row.worktree);
            if let Some(b) = work {
                let _ = writeln!(
                    out,
                    "  git -C {checkout} branch -d {b}{}",
                    if merged_oid.is_some() {
                        " (squash なら、PR の head と同じ commit のときだけ -D)"
                    } else {
                        ""
                    }
                );
            }
            let _ = writeln!(
                out,
                "  git -C {checkout} branch -d {} (base の祖先なら -D)",
                row.branch
            );
        }
        return Ok(exit::OK);
    }

    // 2. の前に、見ていない解説動画の印を移す (移せなければ、ここで止まって何も片付けない)
    move_videos(&hc, home.as_ref(), &unwatched, &row, out, err)?;
    if !making.is_empty() {
        let why = if still_making {
            "--force。子と一緒に作るのが止まる"
        } else {
            "子の Claude が終わっていて、作るのはもう止まっている"
        };
        let _ = writeln!(
            err,
            "note: 作りかけの解説動画の印 ({making}) は移さない ({why})"
        );
    }

    // 2. 子の端末を終えて消す
    if term.is_some() {
        end_terminal(r, &hc, &row.terminal)?;
        let _ = writeln!(
            out,
            "子 {} の端末 {} を終えて消した (hc kill → hc rm)",
            row.letter, row.terminal
        );
    }

    // 3. space を閉じる (中の端末も終わる)
    if !row.space.is_empty() {
        let app = HerdrApp::new(r);
        let id = app_id(&row.space, m);
        if !app.available() {
            // herdr-app の無いマシン (Linux のハブ) では space.close を打てない。space の最後の端末を消すと herdr-app が
            // space を消すので、子のマシンの hc の doc herdr-app で消えるのを待ち、残っていて中にほかの生きた端末が無ければ doc
            // から消す ([`appdoc::remove`])
            let got = appdoc::remove(r, &hc, m, &row.space, ended, appdoc::GONE_POLLS);
            report_removed(&got, m, &id, out, err);
        } else {
            match app.run("space.close", &json!({"id": id, "confirmed": true})) {
                Ok(_) => {
                    let _ = writeln!(out, "space {id} を閉じた");
                }
                Err(e) => {
                    let _ = writeln!(
                        err,
                        "!! space {id} を閉じられない ({e})。herdr-app の画面で閉じる"
                    );
                }
            }
        }
    }

    // 4. worktree と branch を消す
    if has_worktree {
        let rm = hc.exec(
            m,
            None,
            120,
            &["git", "-C", checkout, "worktree", "remove", &row.worktree],
        )?;
        if !rm.ok() {
            return Err(Error::failure(format!(
                "git worktree remove {} が落ちました: {} (端末と space は片付けた。worktree は手で消す)",
                row.worktree,
                rm.why()
            )));
        }
        let home_guess = row.worktree.split("/.herdr/").next().unwrap_or("");
        let _ = writeln!(
            out,
            "worktree {} を消した",
            short_remote(&row.worktree, home_guess)
        );
        if let Some(b) = work {
            delete_branch(
                &hc,
                m,
                checkout,
                b,
                Safe::MergedHead(merged_oid.as_deref()),
                out,
            )?;
        }
        delete_branch(
            &hc,
            m,
            checkout,
            &row.branch,
            Safe::AncestorOf(&row.base),
            out,
        )?;
    }

    let now = r.now()?.to_jst().iso_seconds();
    ledger.update(&row.letter, |x| {
        x.state = state::CLEANED.into();
        x.updated = now;
    })?;
    let _ = writeln!(
        out,
        "子 {} を片付けた (英字 {} は使い回さない)",
        row.letter, row.letter
    );
    Ok(exit::OK)
}

/// 子の端末で Claude が動いているかもしれないか (動いている・見分けられない)。終わった・shell に替わった端末の作りかけの
/// 動画の印は、作るのがもう止まっている。
pub(super) fn may_be_running(term: &Value) -> bool {
    matches!(agent_of(term), Agent::Running | Agent::Unknown(_))
}

/// その状態の動画の印を 1 行に (`🎬⏳:TKT-n 短尺 x・🎬⏳:…`)。無ければ空。
pub(super) fn names_of(videos: &[Video], state: State) -> String {
    videos
        .iter()
        .filter(|v| v.state == state)
        .map(Video::row_text)
        .collect::<Vec<_>>()
        .join("・")
}

/// 親へ移した印の `from` (`子 A (<machine>/t13)`)。
pub(super) fn moved_from(row: &Row) -> String {
    format!("子 {} ({})", row.letter, row.terminal)
}

/// 見ていない動画の印を移す先: この会話の端末 (`HC_TERMINAL_ID`)、無ければ子の hc の親。hc にいなければ次を見る。移すものが
/// 無ければ引かない。
fn video_home(
    r: &dyn Runner,
    hc: &Hc<'_>,
    term: Option<&Value>,
    unwatched: &[Video],
) -> Result<Option<(String, Value)>> {
    if unwatched.is_empty() {
        return Ok(None);
    }
    let parent = term
        .and_then(|t| t["parent"].as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_owned);
    for addr in [r.env("HC_TERMINAL_ID"), parent].into_iter().flatten() {
        if let Some(t) = hc.get(&addr)? {
            return Ok(Some((addr, t)));
        }
    }
    Ok(None)
}

/// 見ていない動画の印を `home` へ移す (1 回の hc label。落ちたら失敗で返し、子は終えない)。移す先が無いのは `--force` のときだけ
/// (確かめで止めている)。
fn move_videos(
    hc: &Hc<'_>,
    home: Option<&(String, Value)>,
    unwatched: &[Video],
    row: &Row,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<()> {
    if unwatched.is_empty() {
        return Ok(());
    }
    let names = names_of(unwatched, State::Done);
    let Some((h, home_term)) = home else {
        let _ = writeln!(
            err,
            "!! 見ていない解説動画の印 ({names}) を移す先が無いので、子と一緒に消える (--force)"
        );
        return Ok(());
    };
    let pairs = video::moved_pairs(unwatched, home_term, &moved_from(row));
    if pairs.is_empty() {
        let _ = writeln!(
            out,
            "見ていない解説動画の印 ({names}) は {h} にもう移してある"
        );
        return Ok(());
    }
    hc.label(h, &pairs)?;
    let _ = writeln!(
        out,
        "見ていない解説動画の印 {} 本を {h} へ移した ({names})",
        pairs.len()
    );
    Ok(())
}

/// `-d` が通らなかった branch を `-D` で消してよいとみる決まり。
enum Safe<'a> {
    /// PR が merge 済みで、branch の先が PR の head の commit と同じか、その祖先 (merge の後に足した commit が無い)。
    MergedHead(Option<&'a str>),
    /// branch の先が `base` の祖先 (worktree を作ったときから commit が無い)。
    AncestorOf(&'a str),
}

/// branch を `-d` で消す。通らなければ [`Safe`] の決まりに当たるときだけ `-D`。当たらなければ残して、そう出す。
fn delete_branch(
    hc: &Hc<'_>,
    m: Option<&str>,
    checkout: &str,
    branch: &str,
    safe: Safe<'_>,
    out: &mut dyn Write,
) -> Result<()> {
    let refname = format!("refs/heads/{branch}");
    let exists = hc.exec(
        m,
        None,
        30,
        &[
            "git",
            "-C",
            checkout,
            "rev-parse",
            "--verify",
            "--quiet",
            &refname,
        ],
    )?;
    if !exists.ok() {
        return Ok(());
    }
    let soft = hc.exec(
        m,
        None,
        30,
        &["git", "-C", checkout, "branch", "-d", branch],
    )?;
    if soft.ok() {
        let _ = writeln!(out, "branch {branch} を消した");
        return Ok(());
    }
    let is_ancestor = |of: &str| -> bool {
        !of.is_empty()
            && hc
                .exec(
                    m,
                    None,
                    30,
                    &[
                        "git",
                        "-C",
                        checkout,
                        "merge-base",
                        "--is-ancestor",
                        &refname,
                        of,
                    ],
                )
                .is_ok_and(|o| o.ok())
    };
    let (ok, why) = match safe {
        Safe::MergedHead(Some(oid)) => (
            exists.stdout.trim() == oid || is_ancestor(oid),
            "PR が merge 済み (squash) で、PR の head より先の commit が無い",
        ),
        Safe::MergedHead(None) => (false, ""),
        Safe::AncestorOf(base) => (is_ancestor(base), "commit が無い"),
    };
    if !ok {
        let _ = writeln!(
            out,
            "branch {branch} は消さない (-d が通らない: {}。PR の head より先の commit があるか、merge を確かめていない)",
            soft.why()
        );
        return Ok(());
    }
    let hard = hc.exec(
        m,
        None,
        30,
        &["git", "-C", checkout, "branch", "-D", branch],
    )?;
    if hard.ok() {
        let _ = writeln!(out, "branch {branch} を消した (-D。{why})");
    } else {
        let _ = writeln!(out, "branch {branch} を消せない: {}", hard.why());
    }
    Ok(())
}

/// space の子のほかの端末を 1 句に (`<machine>/t29`・`<machine>/t30 (確かめられない)`)。
fn others_text(others: &Others, m: Option<&str>) -> String {
    others
        .live
        .iter()
        .map(|t| app_id(t, m))
        .chain(
            others
                .unknown
                .iter()
                .map(|t| format!("{} (確かめられない)", app_id(t, m))),
        )
        .collect::<Vec<_>>()
        .join("・")
}

/// [`appdoc::remove`] の結果を出す (`id` は herdr-app の形の space の id)。消えた・消したは `out`、残した・確かめられないは `err`。
fn report_removed(
    got: &Removed,
    m: Option<&str>,
    id: &str,
    out: &mut dyn Write,
    err: &mut dyn Write,
) {
    let what = appdoc::what(m);
    let _ = match got {
        Removed::Gone => writeln!(out, "space {id} は {what} に無い (herdr-app が消した)"),
        Removed::Removed { from, to } => writeln!(
            out,
            "herdr-app が space {id} を消さなかった (動いていない・遅い) ので、{what} から消した (版 {from} → {to})"
        ),
        Removed::Kept(others) => writeln!(
            err,
            "!! space {id} に、子のほかの端末 ({}) が残っているので閉じない (要らなければ herdr-app の画面で閉じる。space.close は中の端末も終わらせる)",
            others_text(others, m)
        ),
        Removed::Skip(why) => writeln!(
            err,
            "note: {why} ので、space {id} が残っていないかを確かめない"
        ),
        Removed::Failed(why) => writeln!(
            err,
            "!! space {id} を {what} から消せない ({why})。残っていれば herdr-app の画面で閉じる"
        ),
    };
}

#[cfg(test)]
mod tests {
    use super::branch_before_detach;

    #[test]
    fn reflog_branch_before_detach() {
        let log = "checkout: moving from feat/ABC-1-x to origin/main\ncommit: x\ncheckout: moving from worktree/a to feat/ABC-1-x\n";
        assert_eq!(branch_before_detach(log), Some("feat/ABC-1-x"));
        assert_eq!(
            branch_before_detach("commit: x\nreset: moving to HEAD\n"),
            None
        );
        assert_eq!(branch_before_detach(""), None);
    }
}
