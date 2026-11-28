//! 子を立てるアカウントのテスト: ハブの CLAUDE_CONFIG_DIR・--account・控えから決め、子のマシンの launcher と
//! アカウントの用意を確かめてから立てる。用意は、子のマシンに claude-account があればその check の答えで、無ければファイルの
//! 有る無しで見る。偽物の答え方は親 (tests.rs) のものを使い、子のマシンで launcher と用意を探る script と
//! claude-account check だけをここで答える。

use std::cell::Cell;
use std::rc::Rc;

use pjp_core::exit::{CONFIG, FAILURE, OK};
use pjp_core::process::Output;

use super::{
    CLAUDE, Sc, World, child_term, has_call, ledger_rows, live_row, new_args, respond, run,
    run_call, seed_row,
};
use crate::ledger::Row;
use crate::testutil::{Fake, TempDir, exec_ok, exec_result, fail, ok};

const LAUNCHER: &str = "/home/u/.nix-profile/bin/claude-work";

/// 子のマシンで launcher と用意を探る script の目印。
const PROBE_MARK: &str = "printf 'launcher=";

/// 子のマシンの claude-account (アカウントを作る・確かめる dotfiles のコマンド)。
const CLAUDE_ACCOUNT: &str = "/home/u/.nix-profile/bin/claude-account";

/// 子のマシンで claude-account check を打つ hc exec (shell を通さず、名前を渡す)。
const CHECK_LINE: &str =
    "hc exec --json --on wsl1 --timeout 60 -- /home/u/.nix-profile/bin/claude-account check work";

/// 子のマシンの答え (launcher の場所と、用意のファイルがあった種類)。
fn found(launcher: &str, kinds: &[&str]) -> Output {
    let mut text = format!("launcher={launcher}\n");
    for k in kinds {
        text.push_str(&format!("{k}=1\n"));
    }
    exec_ok(&text)
}

/// [`found`] に、子のマシンにある claude-account の場所を足したもの。
fn found_with_claude_account(launcher: &str, kinds: &[&str]) -> Output {
    let mut text = format!("launcher={launcher}\nclaude-account={CLAUDE_ACCOUNT}\n");
    for k in kinds {
        text.push_str(&format!("{k}=1\n"));
    }
    exec_ok(&text)
}

/// claude-account check を打つ hc exec か (`-- <…/claude-account> check <名前>`)。
fn is_check(argv: &[String]) -> bool {
    argv.windows(2)
        .any(|w| w[0].ends_with("/claude-account") && w[1] == "check")
}

/// 終了コードの無い hc exec の答え (時間切れで止めた・シグナルで終わった)。hc 0.1.21 の形 (2026-11-19 に自分専用の core で
/// 時間切れを見た。`code` は null・`signal` は 15)。
fn exec_without_code(timed_out: bool) -> Output {
    ok(&serde_json::json!({
        "code": null,
        "ms": 60003,
        "signal": if timed_out { 15 } else { 9 },
        "stderr": "",
        "stdout": "",
        "timed_out": timed_out,
        "truncated": false,
    })
    .to_string())
}

/// 親の偽物に、launcher と用意を探る script の答えを足した世界。`env` はハブの env。
fn world_acct(sc: Sc, env: &[(&str, &str)], answer: Output) -> World {
    world_check(sc, env, answer, None)
}

/// [`world_acct`] に、claude-account check の答え (`check`) を足した世界。
fn world_check(sc: Sc, env: &[(&str, &str)], probe: Output, check: Option<Output>) -> World {
    let gets = Rc::new(Cell::new(0));
    let g = Rc::clone(&gets);
    let mut fake = Fake::new(move |argv| {
        if argv.iter().any(|a| a.contains(PROBE_MARK)) {
            return probe.clone();
        }
        if let Some(answer) = check.as_ref().filter(|_| is_check(argv)) {
            return answer.clone();
        }
        respond(&sc, &g, argv)
    })
    .env("HC_TERMINAL_ID", "t8");
    for (k, v) in env {
        fake = fake.env(k, v);
    }
    let t = TempDir::new("brief");
    let brief = t.write("brief.md", "依頼の本文\n");
    World { fake, brief, _t: t }
}

/// claude-work で動いているハブ (Linux)。
const WORK_HUB: [(&str, &str); 2] = [
    ("HOME", "/home/u"),
    ("CLAUDE_CONFIG_DIR", "/home/u/.claude-work"),
];

fn idle() -> Sc {
    Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    }
}

fn assert_nothing_made(w: &World) {
    for mutating in [
        "ghq get",
        "fetch origin",
        "worktree add",
        "herdr-app do",
        "hc run",
        "hc kill",
    ] {
        assert!(!has_call(w, mutating), "{mutating}: {:?}", w.fake.lines());
    }
}

// ---- new

#[test]
fn new_follows_hub_config_dir_to_launcher() {
    let w = world_acct(Sc::default(), &WORK_HUB, found(LAUNCHER, &["login"]));
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // env -u HERDR_* … の後ろが、素の claude でなく launcher
    let call = run_call(&w);
    let at = call
        .iter()
        .position(|a| a == LAUNCHER)
        .expect("launcher で立てていない");
    assert_eq!(call[at + 1], "--dangerously-skip-permissions", "{call:?}");
    assert!(!call.contains(&CLAUDE.to_owned()), "{call:?}");
    // launcher と用意は、worktree・space を作る前に、子のマシンで名前を $1 で渡して確かめる
    let lines = w.fake.lines();
    let probe = lines.iter().position(|l| l.contains(PROBE_MARK)).unwrap();
    let wt = lines
        .iter()
        .position(|l| l.contains("worktree add"))
        .unwrap();
    assert!(probe < wt, "{lines:?}");
    assert!(
        lines[probe].starts_with("hc exec --json --on wsl1"),
        "{}",
        lines[probe]
    );
    assert!(lines[probe].ends_with(" sh work"), "{}", lines[probe]);
    // 控えに残し (restart が引き継ぐ)、出力にアカウントとわけを出す
    assert_eq!(ledger_rows(&w, "ABC-681")[0].account, "work");
    assert!(
        r.out.contains("  アカウント: claude-work。ハブの CLAUDE_CONFIG_DIR /home/u/.claude-work から。子のマシンに /login のアカウントの用意がある"),
        "{}",
        r.out
    );
    assert!(r.out.contains("effort high・claude-work)"), "{}", r.out);
}

#[test]
fn new_default_account_keeps_plain_claude() {
    // CLAUDE_CONFIG_DIR が無い・~/.claude なら、今までどおり素の claude (子のマシンを探る script も足さない)
    for (env, why) in [
        (vec![], "ハブの CLAUDE_CONFIG_DIR が空"),
        (
            vec![
                ("HOME", "/home/u"),
                ("CLAUDE_CONFIG_DIR", "/home/u/.claude"),
            ],
            "ハブの CLAUDE_CONFIG_DIR が /home/u/.claude",
        ),
    ] {
        let w = world_acct(Sc::default(), &env, found(LAUNCHER, &["login"]));
        let r = run(&w, &new_args(&w, &[]));
        assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
        assert!(!has_call(&w, PROBE_MARK), "{:?}", w.fake.lines());
        assert!(run_call(&w).contains(&CLAUDE.to_owned()));
        assert_eq!(ledger_rows(&w, "ABC-681")[0].account, "");
        assert!(
            r.out.contains(&format!(
                "  アカウント: 既定 (素の claude・~/.claude)。{why}"
            )),
            "{}",
            r.out
        );
        assert!(r.out.contains("effort high)"), "{}", r.out);
    }
}

#[test]
fn new_account_flag_overrides_hub() {
    // ハブが claude-work でも、--account default なら素の claude
    let w = world_acct(Sc::default(), &WORK_HUB, found(LAUNCHER, &["login"]));
    let r = run(&w, &new_args(&w, &["--account", "default"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!has_call(&w, PROBE_MARK));
    assert!(run_call(&w).contains(&CLAUDE.to_owned()));
    assert!(r.out.contains("。--account default から"), "{}", r.out);
    // ハブが既定でも、--account personal なら claude-personal (token のアカウントの用意)
    let personal = "/home/u/.nix-profile/bin/claude-personal";
    let w = world_acct(Sc::default(), &[], found(personal, &["token"]));
    let r = run(&w, &new_args(&w, &["--account", "personal"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(run_call(&w).contains(&personal.to_owned()));
    // 子のマシンでは --account の名前を確かめる (ハブの今のアカウントではない)
    let probe = w
        .fake
        .lines()
        .into_iter()
        .find(|l| l.contains(PROBE_MARK))
        .unwrap();
    assert!(probe.ends_with(" sh personal"), "{probe}");
    assert!(
        r.out.contains("  アカウント: claude-personal。--account から。子のマシンに token のアカウントの用意がある"),
        "{}",
        r.out
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].account, "personal");
}

#[test]
fn new_stops_before_anything_on_unreadable_hub_config_dir() {
    let env = [
        ("HOME", "/home/u"),
        ("CLAUDE_CONFIG_DIR", "/home/u/.config/claude"),
    ];
    let w = world_acct(Sc::default(), &env, found(LAUNCHER, &["login"]));
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, CONFIG, "{}\n{}", r.out, r.err);
    assert!(r.err.contains("/home/u/.config/claude"), "{}", r.err);
    assert!(r.err.contains("--account default"), "{}", r.err);
    // hc にも子のマシンにも何も打たない
    assert!(w.fake.calls().is_empty(), "{:?}", w.fake.lines());
    // --account を渡せば、ハブの CLAUDE_CONFIG_DIR は読まない
    let r = run(&w, &new_args(&w, &["--account", "work"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
}

#[test]
fn new_stops_before_creating_anything_when_launcher_is_missing() {
    let w = world_acct(Sc::default(), &WORK_HUB, found("", &[]));
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err
            .contains("子のマシン (wsl1) に claude-work がありません"),
        "{}",
        r.err
    );
    assert!(r.err.contains("--account default"), "{}", r.err);
    assert_nothing_made(&w);
    assert!(ledger_rows(&w, "ABC-681").is_empty());
}

#[test]
fn new_stops_when_account_is_not_ready_and_shows_both_fixes() {
    // 素の claude に黙って落とさない
    let w = world_acct(Sc::default(), &WORK_HUB, found(LAUNCHER, &[]));
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "子のマシン (wsl1) の claude-work は用意ができていません (~/.claude-work/.credentials.json も ~/.config/claude-accounts/work.env も無い)",
        "claude-work を起こして /login する",
        "token のアカウントなら、子のマシンの端末で claude-work を一度起こし、出る案内どおりに ~/.config/claude-accounts/work.env に token を置く",
        "--account default",
    ] {
        assert!(r.err.contains(want), "{want}: {}", r.err);
    }
    // token のファイルの中身の形 (値そのもの・1Password の参照) は決めつけず、launcher の案内に任せる
    assert!(!r.err.contains("op://"), "{}", r.err);
    assert_nothing_made(&w);
    assert!(ledger_rows(&w, "ABC-681").is_empty());
}

#[test]
fn new_dry_run_shows_account_and_launcher() {
    let w = world_acct(Sc::default(), &WORK_HUB, found(LAUNCHER, &["login"]));
    let r = run(&w, &new_args(&w, &["--dry-run"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        r.out.contains("  アカウント: claude-work。ハブの CLAUDE_CONFIG_DIR /home/u/.claude-work から。子のマシンに /login のアカウントの用意がある"),
        "{}",
        r.out
    );
    assert!(
        r.out
            .contains(&format!("{LAUNCHER} --dangerously-skip-permissions")),
        "{}",
        r.out
    );
    assert_nothing_made(&w);
    assert!(ledger_rows(&w, "ABC-681").is_empty());
    // 用意ができていなければ、--dry-run も同じわけで止まる
    let w = world_acct(Sc::default(), &WORK_HUB, found(LAUNCHER, &[]));
    let r = run(&w, &new_args(&w, &["--dry-run"]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(r.err.contains("用意ができていません"), "{}", r.err);
}

#[test]
fn new_stops_when_launcher_is_only_off_the_core_path() {
    // ~/.nix-profile/bin (home-manager) や ~/.local/bin (claude-account add の link) にあっても、core の PATH に無い launcher は
    // claude を見つけられないので使わない。どこにあったかを出す
    for (offpath, place) in [
        ("/home/u/.nix-profile/bin/claude-work", "~/.nix-profile/bin"),
        ("/home/u/.local/bin/claude-work", "~/.local/bin"),
    ] {
        let off = exec_ok(&format!("launcher=\noffpath={offpath}\nlogin=1\n"));
        let w = world_acct(Sc::default(), &WORK_HUB, off);
        let r = run(&w, &new_args(&w, &[]));
        assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
        let head = format!(
            "子のマシン (wsl1) の claude-work は {place} にあるが、hc の core の PATH に無い"
        );
        for want in [
            head.as_str(),
            "hc server restart --fresh",
            "--account default",
        ] {
            assert!(r.err.contains(want), "{want}: {}", r.err);
        }
        assert_nothing_made(&w);
    }
}

#[test]
fn new_stops_when_the_probe_cannot_run() {
    let w = world_acct(
        Sc::default(),
        &WORK_HUB,
        exec_result(127, "", "sh: 1: sh: not found"),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err.contains(
            "子のマシン (wsl1) で claude-work の用意を確かめられません: sh: 1: sh: not found"
        ),
        "{}",
        r.err
    );
    assert_nothing_made(&w);
}

#[test]
fn every_child_drops_account_env_inherited_from_the_core() {
    // hc の子は core の env で起きる。core を claude-work の会話から立て直すと CLAUDE_CONFIG_DIR が紛れ込むので、
    // 既定の子も名前のアカウントの子も、claude (launcher) の前に env -u で外す
    for (extra, program) in [(vec![], CLAUDE), (vec!["--account", "work"], LAUNCHER)] {
        let w = world_acct(Sc::default(), &[], found(LAUNCHER, &["login"]));
        let mut args = new_args(&w, &[]);
        args.extend(extra);
        let r = run(&w, &args);
        assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
        let call = run_call(&w);
        let at = call.iter().position(|a| a == program).unwrap();
        for name in [
            "CLAUDE_CONFIG_DIR",
            "ANTHROPIC_API_KEY",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "ANTHROPIC_AUTH_TOKEN",
        ] {
            let i = call
                .iter()
                .position(|a| a == name)
                .unwrap_or_else(|| panic!("{name} を外していない: {call:?}"));
            assert!(call[i - 1] == "-u" && i < at, "{name}: {call:?}");
        }
    }
}

// ---- restart

#[test]
fn restart_keeps_the_account_it_was_started_with() {
    // ハブが今は別のアカウント (claude-personal) で動いていても、控えのアカウントで立て直す
    let env = [
        ("HOME", "/home/u"),
        ("CLAUDE_CONFIG_DIR", "/home/u/.claude-personal"),
    ];
    let w = world_acct(idle(), &env, found(LAUNCHER, &["login"]));
    seed_row(
        &w,
        "ABC-681",
        Row {
            account: "work".into(),
            ..live_row()
        },
    );
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // 子のマシンでは控えのアカウントを確かめる (ハブの今の personal ではない)
    let probe = w
        .fake
        .lines()
        .into_iter()
        .find(|l| l.contains(PROBE_MARK))
        .unwrap();
    assert!(probe.ends_with(" sh work"), "{probe}");
    let call = run_call(&w);
    assert!(call.contains(&LAUNCHER.to_owned()), "{call:?}");
    assert!(call.contains(&"--continue".to_owned()), "{call:?}");
    assert!(
        r.out.contains("  アカウント: claude-work。控えから (立てたときのアカウント)。子のマシンに /login のアカウントの用意がある"),
        "{}",
        r.out
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].account, "work");
}

#[test]
fn restart_account_flag_switches_and_is_recorded() {
    let w = world_acct(idle(), &[], found(LAUNCHER, &["login"]));
    seed_row(
        &w,
        "ABC-681",
        Row {
            account: "work".into(),
            ..live_row()
        },
    );
    let r = run(&w, &["restart", "A", "--account", "default"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!has_call(&w, PROBE_MARK));
    assert!(run_call(&w).contains(&CLAUDE.to_owned()));
    assert!(r.out.contains("。--account default から"), "{}", r.out);
    assert_eq!(ledger_rows(&w, "ABC-681")[0].account, "");
    // 列の無い前の控えの子 (空) は、素の claude のまま
    let w = world_acct(idle(), &WORK_HUB, found(LAUNCHER, &["login"]));
    seed_row(&w, "ABC-681", live_row());
    assert_eq!(run(&w, &["restart", "A"]).code, OK);
    assert!(!has_call(&w, PROBE_MARK));
    assert!(run_call(&w).contains(&CLAUDE.to_owned()));
}

#[test]
fn restart_checks_the_account_before_ending_the_old_terminal() {
    let w = world_acct(idle(), &[], found(LAUNCHER, &[]));
    seed_row(
        &w,
        "ABC-681",
        Row {
            account: "work".into(),
            ..live_row()
        },
    );
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(r.err.contains("用意ができていません"), "{}", r.err);
    assert_nothing_made(&w);
    // 打ち間違えた --account も、前の端末に触る前に断る
    let r = run(&w, &["restart", "A", "--account", "claude-work"]);
    assert_eq!(r.code, CONFIG, "{}", r.err);
    assert_nothing_made(&w);
}

// ---- claude-account

#[test]
fn new_asks_claude_account_check_when_the_child_machine_has_it() {
    // 用意のファイルが無くても、claude-account が使えると答えれば立てる (見分けは claude-account に任せる)
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found_with_claude_account(LAUNCHER, &[]),
        Some(exec_ok("work: /login 済み\n")),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // 名前を渡して打ち、worktree・space を作る前に答えを見る
    let lines = w.fake.lines();
    let check = lines
        .iter()
        .position(|l| l == CHECK_LINE)
        .unwrap_or_else(|| panic!("{lines:?}"));
    let wt = lines
        .iter()
        .position(|l| l.contains("worktree add"))
        .unwrap();
    assert!(check < wt, "{lines:?}");
    assert!(run_call(&w).contains(&LAUNCHER.to_owned()));
    // 答えの 1 行を、アカウントの行に出す
    assert!(
        r.out.contains("  アカウント: claude-work。ハブの CLAUDE_CONFIG_DIR /home/u/.claude-work から。子のマシンの claude-account check の答え: work: /login 済み\n"),
        "{}",
        r.out
    );
}

#[test]
fn new_stops_with_the_fixes_claude_account_check_gives() {
    // 用意のファイルがあっても、claude-account が用意が無いと答えれば止まり、出した手を字のまま出す
    let fixes =
        "claude-work は /login がまだ\n子のマシンの端末で claude-work を起こして /login する\n";
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found_with_claude_account(LAUNCHER, &["login", "token"]),
        Some(exec_result(1, "", fixes)),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "子のマシン (wsl1) の claude-work は用意ができていません。claude-account check work の答え (終了コード 1):\n    claude-work は /login がまだ\n    子のマシンの端末で claude-work を起こして /login する\n",
        "  - 上の手をする (ユーザーの手)\n",
        "  - --account default で素の claude (~/.claude) で立てる",
    ] {
        assert!(r.err.contains(want), "{want}: {}", r.err);
    }
    // 止まるときの token の手は claude-account に任せ、ファイルで見分けるときの文は出さない
    assert!(
        !r.err.contains("~/.config/claude-accounts/work.env"),
        "{}",
        r.err
    );
    assert_nothing_made(&w);
    assert!(ledger_rows(&w, "ABC-681").is_empty());
}

#[test]
fn new_stops_when_claude_account_does_not_know_the_name() {
    // launcher も無い名前。ファイルで見分けるときの「claude-work がありません」より、claude-account の答えを出す
    let said = "claude-account: work というアカウントはありません (claude-account list で見る)\n";
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found_with_claude_account("", &[]),
        Some(exec_result(2, "", said)),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "claude-account check work の答え (終了コード 2):\n    claude-account: work というアカウントはありません (claude-account list で見る)\n",
        "--account default",
    ] {
        assert!(r.err.contains(want), "{want}: {}", r.err);
    }
    assert!(!r.err.contains("claude-work がありません"), "{}", r.err);
    assert_nothing_made(&w);
    // 文を stderr でなく stdout に出したときは、stdout を出す (「何も出さなかった」とは書かない)
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found_with_claude_account("", &[]),
        Some(exec_result(2, said, "")),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err.contains("(終了コード 2):\n    claude-account: work というアカウントはありません (claude-account list で見る)\n"),
        "{}",
        r.err
    );
}

#[test]
fn new_points_to_the_core_path_when_claude_account_says_usable_but_no_launcher_is_found() {
    // claude-account は launcher (link) があるときだけ使えると答える。それでも core の PATH で見つからないのは core の env が
    // 古いときなので、dotfiles を新しくする手でなく、core を立て直す手を出す
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found_with_claude_account("", &[]),
        Some(exec_ok("claude-work: subscription (ログイン済み)\n")),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "子のマシン (wsl1) の claude-account は claude-work を使えると答えたが、claude-work が hc の core の PATH に無い",
        "hc server restart --fresh",
        "--account default",
    ] {
        assert!(r.err.contains(want), "{want}: {}", r.err);
    }
    assert!(!r.err.contains("dotfiles を新しくして"), "{}", r.err);
    assert_nothing_made(&w);
}

#[test]
fn new_default_account_does_not_ask_the_name_probe_for_claude_account() {
    // 素の claude の子は、名前のアカウントの探り (launcher と用意のファイル) を使わない。claude-account の有る無しは、子のマシンを
    // 1 回で探る script の答えで見る (ここでは無いと答える) ので、check は打たない
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found_with_claude_account(LAUNCHER, &["login"]),
        Some(exec_result(1, "", "claude-work は /login がまだ\n")),
    );
    let r = run(&w, &new_args(&w, &["--account", "default"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        !has_call(&w, "/claude-account check"),
        "{:?}",
        w.fake.lines()
    );
}

#[test]
fn new_falls_back_to_the_files_without_claude_account() {
    // claude-account の無いマシン (dotfiles が古い) は、今までどおり launcher と用意のファイルで見分ける
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found(LAUNCHER, &[]),
        Some(exec_ok("work: /login 済み\n")),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        !has_call(&w, "/claude-account check"),
        "{:?}",
        w.fake.lines()
    );
    assert!(
        r.err.contains("token のアカウントなら、子のマシンの端末で claude-work を一度起こし、出る案内どおりに ~/.config/claude-accounts/work.env に token を置く"),
        "{}",
        r.err
    );
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found(LAUNCHER, &["login"]),
        Some(exec_result(1, "", "claude-work は /login がまだ\n")),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!has_call(&w, "/claude-account check"));
    assert!(
        r.out
            .contains("。子のマシンに /login のアカウントの用意がある\n"),
        "{}",
        r.out
    );
}

#[test]
fn new_stops_without_falling_back_when_claude_account_check_ends_oddly() {
    // ほかの終了コード・時間切れ・打てないときは、用意のファイルがあっても (login=1) ファイルの見分けに戻らずに止まる
    let spawn_failed = fail(
        1,
        r#"{"error":{"hint":"","kind":"spawn_failed","message":"cannot start /home/u/.nix-profile/bin/claude-account: No such file or directory (os error 2)"}}"#,
    );
    for (answer, want) in [
        (
            exec_result(3, "", "jq: command not found\n"),
            "子のマシン (wsl1) の claude-account check work が思わぬ終わり方をしました (終了コード 3)。用意のファイルの有る無しの見分けには戻らずに止まる。claude-account の出した文:\n    jq: command not found\n",
        ),
        (
            exec_without_code(true),
            "子のマシン (wsl1) の claude-account check work が思わぬ終わり方をしました (60 秒で時間切れ)",
        ),
        (
            exec_without_code(false),
            "子のマシン (wsl1) の claude-account check work が思わぬ終わり方をしました (終了コードなし。シグナルなどで終わった)",
        ),
        (
            spawn_failed,
            "子のマシン (wsl1) で claude-account check work を打てません (hc exec /home/u/.nix-profile/bin/claude-account が落ちました: cannot start /home/u/.nix-profile/bin/claude-account: No such file or directory (os error 2))。用意のファイルの有る無しの見分けには戻らずに止まる",
        ),
    ] {
        let w = world_check(
            Sc::default(),
            &WORK_HUB,
            found_with_claude_account(LAUNCHER, &["login"]),
            Some(answer),
        );
        let r = run(&w, &new_args(&w, &[]));
        assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
        assert!(r.err.contains(want), "{want}: {}", r.err);
        assert!(r.err.contains("--account default"), "{}", r.err);
        assert_nothing_made(&w);
    }
}

#[test]
fn new_does_not_ask_claude_account_when_the_launcher_is_off_the_core_path() {
    // core の PATH が古い (launcher が ~/.nix-profile/bin にしか無い) なら、claude-account を打つ前に止まる
    let off = exec_ok(&format!(
        "launcher=\noffpath={LAUNCHER}\nclaude-account={CLAUDE_ACCOUNT}\n"
    ));
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        off,
        Some(exec_ok("work: /login 済み\n")),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(r.err.contains("hc server restart --fresh"), "{}", r.err);
    assert!(
        !has_call(&w, "/claude-account check"),
        "{:?}",
        w.fake.lines()
    );
}

#[test]
fn new_dry_run_asks_claude_account_too() {
    // claude-account check は読むだけなので、--dry-run でも打つ
    let w = world_check(
        Sc::default(),
        &WORK_HUB,
        found_with_claude_account(LAUNCHER, &["login"]),
        Some(exec_result(1, "", "claude-work は /login がまだ\n")),
    );
    let r = run(&w, &new_args(&w, &["--dry-run"]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, CHECK_LINE), "{:?}", w.fake.lines());
    assert!(
        r.err.contains("    claude-work は /login がまだ\n"),
        "{}",
        r.err
    );
}

#[test]
fn restart_asks_claude_account_before_ending_the_old_terminal() {
    let w = world_check(
        idle(),
        &[],
        found_with_claude_account(LAUNCHER, &["login"]),
        Some(exec_result(1, "", "claude-work は /login がまだ\n")),
    );
    seed_row(
        &w,
        "ABC-681",
        Row {
            account: "work".into(),
            ..live_row()
        },
    );
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, CHECK_LINE), "{:?}", w.fake.lines());
    assert!(
        r.err.contains("    claude-work は /login がまだ\n"),
        "{}",
        r.err
    );
    assert_nothing_made(&w);
}

/// 偽の claude-account (check の約束どおりに 0・1・2 で答える sh の script)。
#[cfg(unix)]
const FAKE_CLAUDE_ACCOUNT: &str = r#"#!/bin/sh
if [ "$1" != check ] || [ $# -ne 2 ]; then
  echo "使い方: claude-account check <名前>" >&2
  exit 2
fi
case $2 in
work) echo "work: /login 済み" ;;
personal)
  echo "personal は /login がまだ" >&2
  echo "子のマシンの端末で claude-personal を起こして /login する" >&2
  exit 1
  ;;
*)
  echo "知らないアカウント: $2" >&2
  exit 2
  ;;
esac
"#;

/// 偽の claude-account と、用意を探る script を、子のマシンの代わりにこのマシンで本当に流す (hc exec の `--` の後ろを偽の
/// HOME と PATH で打つ)。ほかの呼び出しは親の偽物が答える。0・1・2・claude-account が無い、の 4 通り。
#[cfg(unix)]
#[test]
fn fake_claude_account_decides_in_four_ways() {
    use std::os::unix::fs::PermissionsExt;

    let t = TempDir::new("acct-real");
    let home = t.path().join("home");
    let bin = home.join(".nix-profile").join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let put = |name: &str, body: &str| {
        let p = bin.join(name);
        std::fs::write(&p, body).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    };
    for n in ["claude-work", "claude-personal"] {
        put(n, "#!/bin/sh\nexit 0\n");
    }
    put("claude-account", FAKE_CLAUDE_ACCOUNT);
    let path = format!("{}:/usr/bin:/bin", bin.to_string_lossy());
    let world = || -> World {
        let (home, path) = (home.clone(), path.clone());
        let gets = Rc::new(Cell::new(0));
        let g = Rc::clone(&gets);
        let sc = Sc::default();
        let fake = Fake::new(move |argv| {
            if !(argv.iter().any(|a| a.contains(PROBE_MARK)) || is_check(argv)) {
                return respond(&sc, &g, argv);
            }
            let cmd = &argv[argv.iter().position(|a| a == "--").unwrap() + 1..];
            match std::process::Command::new(&cmd[0])
                .args(&cmd[1..])
                .env_clear()
                .env("HOME", &home)
                .env("PATH", &path)
                .output()
            {
                Ok(o) => exec_result(
                    o.status.code().unwrap_or(-1),
                    &String::from_utf8_lossy(&o.stdout),
                    &String::from_utf8_lossy(&o.stderr),
                ),
                Err(e) => fail(1, &format!("cannot start {}: {e}", cmd[0])),
            }
        })
        .env("HC_TERMINAL_ID", "t8");
        let t = TempDir::new("brief");
        let brief = t.write("brief.md", "依頼の本文\n");
        World { fake, brief, _t: t }
    };
    // 0: 使える。launcher で立てる
    let w = world();
    let r = run(&w, &new_args(&w, &["--account", "work"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let launcher = bin.join("claude-work").to_string_lossy().into_owned();
    assert!(run_call(&w).contains(&launcher), "{:?}", run_call(&w));
    assert!(
        r.out
            .contains("。子のマシンの claude-account check の答え: work: /login 済み\n"),
        "{}",
        r.out
    );
    // 1: 用意が無い。出した手を字のまま出して止まる
    let w = world();
    let r = run(&w, &new_args(&w, &["--account", "personal"]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err.contains("    personal は /login がまだ\n    子のマシンの端末で claude-personal を起こして /login する\n"),
        "{}",
        r.err
    );
    assert_nothing_made(&w);
    // 2: 知らない名前 (launcher も無い)。claude-account の答えを出して止まる
    let w = world();
    let r = run(&w, &new_args(&w, &["--account", "nobody"]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err
            .contains("(終了コード 2):\n    知らないアカウント: nobody\n"),
        "{}",
        r.err
    );
    assert_nothing_made(&w);
    // claude-account が無い: ファイルの有る無しで見分ける (用意のファイルが無いので止まる)
    std::fs::remove_file(bin.join("claude-account")).unwrap();
    let w = world();
    let r = run(&w, &new_args(&w, &["--account", "work"]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err.contains(
            "(~/.claude-work/.credentials.json も ~/.config/claude-accounts/work.env も無い)"
        ),
        "{}",
        r.err
    );
    assert!(!has_call(&w, "/claude-account check"));
}

// ---- ls

#[test]
fn ls_shows_named_account_only() {
    let w = world_acct(Sc::default(), &[], found(LAUNCHER, &["login"]));
    seed_row(
        &w,
        "ABC-681",
        Row {
            account: "work".into(),
            ..live_row()
        },
    );
    seed_row(
        &w,
        "ABC-681",
        Row {
            name: "w23".into(),
            ..live_row()
        },
    );
    let r = run(&w, &["ls"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        r.out
            .contains("A  w22  wsl1/t13  working  チケット ABC-700  pollenjp/claude-skills  アカウント claude-work\n"),
        "{}",
        r.out
    );
    // 既定のアカウントの子の行は今までどおり
    assert!(r.out.contains("  pollenjp/claude-skills\n"), "{}", r.out);
}

// ---- 素の claude の子も claude-account check default で確かめる (dotfiles-private の ADR 123 §2 H)

/// 子のマシンで素の claude の用意を聞く hc exec。
const CHECK_DEFAULT_LINE: &str = "hc exec --json --on wsl1 --timeout 60 -- /home/u/.nix-profile/bin/claude-account check default";

/// 子のマシンを 1 回で探る script が claude-account を見つける世界 (ハブは素の claude)。`check` は check default の答え。
fn world_default(sc: Sc, check: Output) -> World {
    let sc = Sc {
        claude_account: CLAUDE_ACCOUNT.to_owned(),
        ..sc
    };
    // 名前のアカウントの探りは打たれない (打たれたら、claude-account の無い答えを返す)
    world_check(sc, &[], found("", &[]), Some(check))
}

#[test]
fn new_default_account_asks_claude_account_check_default() {
    let w = world_default(
        Sc::default(),
        exec_ok("claude: token (default.env・権限 600・wrapper あり)\n"),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // worktree・space を作る前に打つ。名前のアカウントの探りは使わない
    let lines = w.fake.lines();
    let check = lines
        .iter()
        .position(|l| l == CHECK_DEFAULT_LINE)
        .unwrap_or_else(|| panic!("{lines:?}"));
    let wt = lines
        .iter()
        .position(|l| l.contains("worktree add"))
        .unwrap();
    assert!(check < wt, "{lines:?}");
    assert!(!has_call(&w, PROBE_MARK), "{lines:?}");
    // 素の claude で立て、答えの 1 行をアカウントの行に出す
    assert!(run_call(&w).contains(&CLAUDE.to_owned()));
    assert!(
        r.out.contains("  アカウント: 既定 (素の claude・~/.claude)。ハブの CLAUDE_CONFIG_DIR が空。子のマシンの claude-account check default の答え: claude: token (default.env・権限 600・wrapper あり)\n"),
        "{}",
        r.out
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].account, "");
}

#[test]
fn new_default_account_stops_when_claude_account_says_not_ready() {
    // 宣言の無いホストで /login していない (wsl1 の素の claude など)。立っても動かない子なので、何も作らずに止まる
    let said = "claude: まだログインしていません。wsl1 の端末で claude を起こし、/login する。\n";
    for extra in [&[][..], &["--dry-run"][..]] {
        let w = world_default(Sc::default(), exec_result(1, "", said));
        let r = run(&w, &new_args(&w, extra));
        assert_eq!(r.code, FAILURE, "{extra:?}: {}\n{}", r.out, r.err);
        assert!(has_call(&w, CHECK_DEFAULT_LINE), "{:?}", w.fake.lines());
        for want in [
            "子のマシン (wsl1) の素の claude (~/.claude) は用意ができていません。claude-account check default の答え (終了コード 1):\n    claude: まだログインしていません。wsl1 の端末で claude を起こし、/login する。\n",
            "  - 上の手をする (ユーザーの手)\n",
            "  - --account <名前> で、子のマシンで用意のできた名前のアカウント (claude-<名前>) で立てる",
        ] {
            assert!(r.err.contains(want), "{extra:?}: {want}: {}", r.err);
        }
        // 素の claude で止まったのに「--account default で立てる」は勧めない
        assert!(!r.err.contains("--account default"), "{}", r.err);
        assert_nothing_made(&w);
        assert!(ledger_rows(&w, "ABC-681").is_empty());
    }
}

#[test]
fn new_default_account_starts_unchecked_with_an_old_claude_account() {
    // default を知らない古い claude-account (#347 より前) は 2 を返す。今までどおり確かめずに立て、そのことを行に添える
    let said = "claude-account: claude-default は既定のアカウントでも、登録したアカウントでもありません (一覧は claude-account list)。\n";
    let w = world_default(Sc::default(), exec_result(2, "", said));
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, CHECK_DEFAULT_LINE), "{:?}", w.fake.lines());
    assert!(run_call(&w).contains(&CLAUDE.to_owned()));
    assert!(
        r.out.contains("  アカウント: 既定 (素の claude・~/.claude)。ハブの CLAUDE_CONFIG_DIR が空。子のマシンの claude-account は default を知らない版なので、素の claude の用意は確かめていない\n"),
        "{}",
        r.out
    );
}

#[test]
fn new_default_account_without_claude_account_starts_as_before() {
    // claude-account の無いマシン (dotfiles が古い) は、今までどおり確かめずに立てる
    let w = world_check(
        Sc::default(),
        &[],
        found("", &[]),
        Some(exec_result(1, "", "打たれないはず\n")),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        !has_call(&w, "/claude-account check"),
        "{:?}",
        w.fake.lines()
    );
    assert!(
        r.out.contains(
            "  アカウント: 既定 (素の claude・~/.claude)。ハブの CLAUDE_CONFIG_DIR が空\n"
        ),
        "{}",
        r.out
    );
}

#[test]
fn new_default_account_stops_when_claude_account_check_default_ends_oddly() {
    // 名前のアカウントと同じく、ほかの終了コード・時間切れは確かめないまま立てずに止まる
    let w = world_default(Sc::default(), exec_result(3, "", "jq: command not found\n"));
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err.contains("子のマシン (wsl1) の claude-account check default が思わぬ終わり方をしました (終了コード 3)。確かめないまま立てずに止まる。claude-account の出した文:\n    jq: command not found\n"),
        "{}",
        r.err
    );
    assert_nothing_made(&w);
}

#[test]
fn restart_default_account_asks_claude_account_before_ending_the_old_terminal() {
    let w = world_default(
        idle(),
        exec_result(1, "", "claude: まだログインしていません。\n"),
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, CHECK_DEFAULT_LINE), "{:?}", w.fake.lines());
    assert!(!has_call(&w, "hc kill"), "{:?}", w.fake.lines());
}

/// 子のマシンを 1 回で探る script を本物の sh で流し、claude-account の場所の行が出る (素の claude の子が check default を打つのに使う)。
#[cfg(unix)]
#[test]
fn child_probe_script_reports_claude_account_in_real_sh() {
    use std::os::unix::fs::PermissionsExt;

    let t = TempDir::new("child-probe");
    let home = t.path().join("home");
    let bin = home.join(".nix-profile").join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let run_probe = || -> String {
        let out = std::process::Command::new("sh")
            .args(["-c", &super::super::probe_script(), "sh", ""])
            .env("HOME", &home)
            .env("PATH", "/usr/bin:/bin")
            .output()
            .unwrap();
        assert!(out.status.success(), "{out:?}");
        String::from_utf8(out.stdout).unwrap()
    };
    // 無ければ空の行
    assert!(run_probe().lines().any(|l| l == "claude-account="));
    // PATH に無くても ~/.nix-profile/bin のものを使う
    let p = bin.join("claude-account");
    std::fs::write(&p, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    let want = format!("claude-account={}", p.to_string_lossy());
    assert!(run_probe().lines().any(|l| l == want), "{}", run_probe());
    // checkout の行は repo を渡したときだけ (後ろの断片も続いている)
    assert!(!run_probe().contains("checkout="));
}
