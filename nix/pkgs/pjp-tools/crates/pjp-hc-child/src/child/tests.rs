//! pjp child のテスト。hc・herdr-app・gh・子のマシンの git を偽物にして、打つコマンドの並びと argv を見る。

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use pjp_core::exit::{CONFIG, FAILURE, OK};
use pjp_core::process::Output;
use serde_json::{Value, json};

use super::new::{HERDR_ENV_NAMES, claude_config_args, valid_name};
use super::*;
use crate::appdoc::format_id;
use crate::hc::split_addr;
use crate::ledger::{Row, state};
use crate::testutil::{
    DocSim, Fake, OutputExt, TempDir, exec_ok, exec_result, fail, ok, rpc_calls, rpc_methods,
};

mod account;
mod auto;

const HOME: &str = "/home/u";
const CK: &str = "/home/u/ghq/github.com/pollenjp/claude-skills";
const WT: &str = "/home/u/.herdr/worktrees/claude-skills/w22";
const CLAUDE: &str = "/home/u/.local/bin/claude";

/// 偽物の答え方。
#[derive(Clone)]
struct Sc {
    claude: String,
    checkout: String,
    ghq: bool,
    /// 子のマシンに `git gh` (git-gh) があるか。
    git_gh: bool,
    /// 子のマシンを 1 回で探る script が答える claude-account の場所 (空なら無い)。
    claude_account: String,
    /// gh の資格情報で打った fetch・ghq get が落ちるときの stderr (空なら通る)。
    net_fail: String,
    origin: bool,
    used: String,
    names: Vec<String>,
    app_fail: bool,
    /// `herdr-app commands` の stdout (None なら終了コード 1 で落ちる)。
    app_commands: Option<String>,
    run_fail: bool,
    /// 子のマシンの core の doc herdr-app と偽の herdr-app (`hc connect` が読み書きする。`hc run` の label と `hc kill`・`hc rm` を見る)。
    doc: Rc<RefCell<DocSim>>,
    /// `hc run` が返す子の端末の住所 (立て直しで、前の端末と別の住所にする)。`hc get` もこの住所を子とみる。
    run_addr: String,
    hub_labels: Value,
    /// ハブの会話の端末 (t8) の `hc get` に足すもの (状態の報告・前面のプロセス)。
    hub_agent: Value,
    /// 子の端末の `hc get` の答え (呼ぶたびに次へ。最後のものを繰り返す)。
    child: Vec<Value>,
    toplevel: String,
    status_short: String,
    branch_now: String,
    gh: String,
    /// 子のマシンの `hc ls --json` の答え。`hc get` で読む孫の label・`die_with_parent` も書いておく (ls の答えからは、
    /// 本物の hc 0.1.21 と同じく外す)。
    grandkids: Value,
    /// 子のマシンの `hc ls --json` の落ち方。
    ls_fail: LsFail,
    /// 孫の `hc get` が落ちるか (not_found でなく、つながらない)。
    grand_get_fails: bool,
    d_fails: bool,
    screen: String,
    /// `git reflog show --format=%gs` の答え。
    reflog: String,
    /// `git rev-parse --verify --quiet refs/heads/…` の答え (branch の先の commit)。
    tip: String,
    /// `git merge-base --is-ancestor` が通るか。
    ancestor_ok: bool,
    /// `hc label` が落ちるか (core につながらない)。
    label_fails: bool,
}

impl Default for Sc {
    fn default() -> Self {
        Self {
            claude: CLAUDE.to_owned(),
            checkout: CK.to_owned(),
            ghq: true,
            git_gh: true,
            claude_account: String::new(),
            net_fail: String::new(),
            origin: true,
            used: String::new(),
            names: vec!["other".to_owned()],
            app_fail: false,
            app_commands: Some(COMMANDS_0_1_16.to_owned()),
            run_fail: false,
            doc: Rc::default(),
            run_addr: "wsl1/t13".to_owned(),
            hub_labels: json!({"pjp.ticket": "ABC-681", "pjp.role": "hub", "herdr.space": "sphub"}),
            // Windows のハブ: root の pwsh の中で Claude が動き、状態を報告している (前面は pwsh.exe のまま)
            hub_agent: json!({
                "reported": true,
                "status": {"app": "claude-code", "state": "working"},
                "foreground": {"argv": ["C:\\pwsh.exe", "-NoExit"], "cwd": "C:\\h", "name": "pwsh.exe", "pid": 18_668},
            }),
            child: vec![child_term("working", true)],
            toplevel: "/home/u/h".to_owned(),
            status_short: String::new(),
            branch_now: "feat/ABC-691-x".to_owned(),
            gh: r#"[{"number":12,"state":"MERGED","url":"https://github.com/o/r/pull/12","headRefOid":"abc","isCrossRepository":false}]"#.to_owned(),
            grandkids: json!({"terminals": [{"address": "t1c", "name": "w22", "parent": "e5/t8", "state": "live"}]}),
            ls_fail: LsFail::No,
            grand_get_fails: false,
            d_fails: false,
            screen: "Do you trust the files in this folder?\n> 1. Yes, proceed\n  2. No, exit\n".to_owned(),
            reflog: String::new(),
            tip: "abc".to_owned(),
            ancestor_ok: true,
            label_fails: false,
        }
    }
}

/// 子のマシンの `hc ls --json` の落ち方。
#[derive(Clone, Copy, PartialEq, Eq)]
enum LsFail {
    No,
    /// 子のマシンの hc ls が落ちる (hc exec は通り、終了コード 1)。
    InExec,
    /// hc exec そのものが落ちる (子のマシンにつながらない)。
    Exec,
}

/// 本物の hc 0.1.21 の `hc ls --json` の形にする (label・`die_with_parent`・`keep` を出さない。2026-11-19 に自分専用の core で
/// 確かめた。それらは `hc get` に載る)。
fn as_ls(v: &Value) -> Value {
    let mut v = v.clone();
    if let Some(terms) = v["terminals"].as_array_mut() {
        for t in terms {
            if let Some(o) = t.as_object_mut() {
                for k in ["labels", "die_with_parent", "keep"] {
                    o.remove(k);
                }
            }
        }
    }
    v
}

/// herdr-app 0.1.16 の `herdr-app commands` (抜粋)。space.new の args に focus がある。
const COMMANDS_0_1_16: &str = r#"[
  {"name":"space.new","args":[{"name":"name","required":false},{"name":"folder","required":false},{"name":"tab","required":false},{"name":"argv","required":false},{"name":"task","required":false},{"name":"machine","required":false},{"name":"focus","required":false}],"about":"Create a space"},
  {"name":"space.close","args":[{"name":"id","required":true},{"name":"confirmed","required":false}],"about":"Close a space"}
]"#;

/// herdr-app 0.1.15 の `herdr-app commands` (抜粋)。space.new に focus が無い。
const COMMANDS_0_1_15: &str = r#"[
  {"name":"space.new","args":[{"name":"name","required":false},{"name":"folder","required":false},{"name":"tab","required":false},{"name":"argv","required":false},{"name":"task","required":false},{"name":"machine","required":false}],"about":"Create a space"},
  {"name":"space.close","args":[{"name":"id","required":true},{"name":"confirmed","required":false}],"about":"Close a space"}
]"#;

fn child_term(state: &str, reported: bool) -> Value {
    json!({
        "address": "wsl1/t13",
        "name": "w22",
        "state": "live",
        "reported": reported,
        "status": if reported { json!({"app": "claude-code", "state": state}) } else { Value::Null },
        "labels": {"pjp.role": "child", "pjp.letter": "A", "pjp.ticket": "ABC-700"},
        "parent": "t8",
    })
}

/// Claude が終わって hc の keep が shell に替えた子の端末 (hc 0.1.21 で見た形。名前・label・turn は残り、argv と前面が
/// bash、status が null、reported が false)。
fn shell_term() -> Value {
    json!({
        "address": "wsl1/t13",
        "name": "w22",
        "state": "live",
        "argv": ["/bin/bash"],
        "foreground": {"argv": ["/bin/bash"], "cwd": WT, "name": "bash", "pid": 714},
        "keep": true,
        "pid": 714,
        "reason": null,
        "reported": false,
        "status": null,
        "turn": 2,
        "labels": {"pjp.role": "child", "pjp.letter": "A", "pjp.ticket": "ABC-700"},
        "parent": "t8",
    })
}

fn value_after<'a>(argv: &'a [String], flag: &str) -> Option<&'a str> {
    argv.iter()
        .position(|a| a == flag)
        .and_then(|i| argv.get(i + 1))
        .map(String::as_str)
}

fn respond(sc: &Sc, gets: &Cell<usize>, argv: &[String]) -> Output {
    let a: Vec<&str> = argv.iter().map(String::as_str).collect();
    match a.as_slice() {
        ["hc", "get", addr, ..] => {
            if *addr == "t8" {
                let mut t = json!({"address": "t8", "state": "live", "labels": sc.hub_labels, "parent": null});
                if let (Some(t), Some(extra)) = (t.as_object_mut(), sc.hub_agent.as_object()) {
                    t.extend(extra.clone());
                }
                return ok(&t.to_string());
            }
            if addr.ends_with("t13") || *addr == sc.run_addr {
                let n = gets.get();
                gets.set(n + 1);
                let t = sc
                    .child
                    .get(n)
                    .or(sc.child.last())
                    .cloned()
                    .unwrap_or(Value::Null);
                return ok(&t.to_string());
            }
            // 孫 (子のマシンの一覧の住所に wsl1/ を付けたもの)。ls と違い、label と die_with_parent も返す
            let grand = sc.grandkids["terminals"].as_array().and_then(|terms| {
                terms.iter().find(|t| {
                    t["address"]
                        .as_str()
                        .is_some_and(|local| format!("wsl1/{local}") == *addr)
                })
            });
            if let Some(t) = grand {
                if sc.grand_get_fails {
                    return fail(
                        1,
                        r#"{"error":{"kind":"unavailable","message":"wsl1 is not connected"}}"#,
                    );
                }
                return ok(&t.to_string());
            }
            fail(
                3,
                r#"{"error":{"kind":"not_found","message":"no such terminal"}}"#,
            )
        }
        ["hc", "ls", ..] => {
            let terms: Vec<Value> = sc
                .names
                .iter()
                .map(|n| json!({"address": "t3", "name": n}))
                .collect();
            ok(&json!({"terminals": terms, "hidden_finished": 0}).to_string())
        }
        ["hc", "exec", ..] => {
            let pos = a.iter().position(|x| *x == "--").unwrap();
            if sc.ls_fail == LsFail::Exec && a[pos + 1..] == ["hc", "ls", "--json"] {
                return fail(
                    1,
                    r#"{"error":{"kind":"unreachable","message":"wsl1 is unreachable"}}"#,
                );
            }
            let env: Vec<&str> = a[..pos]
                .windows(2)
                .filter(|w| w[0] == "--env")
                .map(|w| w[1])
                .collect();
            exec(sc, &env, &a[pos + 1..])
        }
        ["hc", "connect", input] => sc.doc.borrow_mut().answer(input),
        ["hc", "kill", addr, ..] if sc.doc.borrow().drop_on_kill => {
            sc.doc.borrow_mut().removed(split_addr(addr).1);
            ok("{}")
        }
        ["hc", "run", ..] => {
            if sc.run_fail {
                return fail(
                    1,
                    r#"{"error":{"kind":"spawn_failed","message":"cannot start"}}"#,
                );
            }
            let name = value_after(argv, "--name").unwrap_or("?");
            // label herdr.space・herdr.tab の付いた端末は、偽の herdr-app (動いていれば) が space に置く
            let label = |key: &str| {
                argv.windows(2)
                    .filter(|w| w[0] == "--label")
                    .find_map(|w| w[1].strip_prefix(&format!("{key}=")).map(str::to_owned))
            };
            if let (Some(sp), Some(tb)) = (label("herdr.space"), label("herdr.tab")) {
                sc.doc.borrow_mut().placed(
                    &sp,
                    &tb,
                    split_addr(&sc.run_addr).1,
                    value_after(argv, "--cwd").unwrap_or_default(),
                );
            }
            ok(&json!({"address": sc.run_addr, "name": name, "state": "live"}).to_string())
        }
        ["hc", "label", ..] if sc.label_fails => fail(
            1,
            r#"{"error":{"kind":"unavailable","message":"core is busy"}}"#,
        ),
        ["hc", "kill", ..] | ["hc", "wait", ..] | ["hc", "label", ..] => ok("{}"),
        ["hc", "rm", addr, ..] => {
            sc.doc.borrow_mut().removed(split_addr(addr).1);
            ok(&json!({"removed": addr}).to_string())
        }
        ["hc", "read", ..] => {
            ok(&json!({"text": sc.screen, "complete": true, "how": "screen"}).to_string())
        }
        ["hc", "send", ..] => ok(r#"{"started":true,"status":"idle","turn":3}"#),
        ["herdr-app", "commands"] => match &sc.app_commands {
            Some(list) => ok(list),
            None => fail(1, "herdr-app: cannot read commands"),
        },
        ["herdr-app", "do", cmd, json] => {
            // 0.1.15 は知らない引数 (focus) を断る
            if *cmd == "space.new"
                && json.contains("\"focus\"")
                && sc.app_commands.as_deref() == Some(COMMANDS_0_1_15)
            {
                return fail(1, "").with_stdout(r#"{"error":"unknown argument: focus"}"#);
            }
            if sc.app_fail {
                return fail(1, "").with_stdout(r#"{"error":"window is not running"}"#);
            }
            match *cmd {
                "space.new" => {
                    ok(r#"{"space":"wsl1/sp1","tab":"wsl1/tb1","pane":"p3","terminal":"wsl1/t1b"}"#)
                }
                _ => ok("{}"),
            }
        }
        ["gh", ..] => ok(&sc.gh),
        _ => fail(127, &format!("偽物が知らないコマンド: {}", a.join(" "))),
    }
}

/// 素の env の git が GitHub の private な repo に出たときのエラー (hc exec の env には資格情報が無い)。
const NO_CRED: &str =
    "fatal: could not read Username for 'https://github.com': terminal prompts disabled";

/// gh の資格情報の組を `-c` で付けた git の頭 (`git gh` の無いマシン)。
const GH_C: [&str; 9] = [
    "git",
    "-c",
    "credential.https://github.com.helper=",
    "-c",
    "url.https://github.com/.insteadOf=git@github.com:",
    "-c",
    "url.https://github.com/.insteadOf=ssh://git@github.com/",
    "-c",
    "credential.https://github.com.helper=!gh auth git-credential",
];

/// ghq get に渡す env (gh の資格情報の組)。
const GH_ENV: [&str; 7] = [
    "GIT_CONFIG_COUNT=3",
    "GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf",
    "GIT_CONFIG_VALUE_0=git@github.com:",
    "GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf",
    "GIT_CONFIG_VALUE_1=ssh://git@github.com/",
    "GIT_CONFIG_KEY_2=credential.https://github.com.helper",
    "GIT_CONFIG_VALUE_2=!gh auth git-credential",
];

/// gh の資格情報で打った GitHub への操作の答え。
fn net(sc: &Sc) -> Output {
    if sc.net_fail.is_empty() {
        exec_ok("")
    } else {
        exec_result(128, "", &sc.net_fail)
    }
}

fn exec(sc: &Sc, env: &[&str], cmd: &[&str]) -> Output {
    // gh の資格情報の組が付いていれば (git gh・git -c・env)、それを除いて答える
    if cmd.starts_with(&GH_C) {
        if !sc.git_gh && cmd[GH_C.len()..].ends_with(&["fetch", "origin"]) {
            return net(sc);
        }
        return exec_result(127, "", &format!("偽物が知らない exec: {}", cmd.join(" ")));
    }
    match cmd {
        ["git", "-C", _, "gh", "fetch", "origin"] if sc.git_gh => return net(sc),
        ["git", "-C", _, "gh", ..] => {
            return exec_result(1, "", "git: 'gh' is not a git command. See 'git --help'.");
        }
        ["ghq", "get", _] if env == GH_ENV => return net(sc),
        ["git", "-C", _, "fetch", "origin"] | ["ghq", "get", _] => {
            return exec_result(128, "", NO_CRED);
        }
        _ => {}
    }
    match cmd {
        ["sh", "-c", script, "sh", ..] if script.contains("printf 'home=") => {
            let mut text = format!(
                "home={HOME}\nclaude={}\nghq={}\ngitgh={}\nclaude-account={}\n",
                sc.claude,
                if sc.ghq { "/usr/bin/ghq" } else { "" },
                if sc.git_gh {
                    "/home/u/.nix-profile/bin/git-gh"
                } else {
                    ""
                },
                sc.claude_account
            );
            if cmd.get(4).is_some_and(|r| !r.is_empty()) && sc.ghq {
                text.push_str(&format!("checkout={}\n", sc.checkout));
            }
            exec_ok(&text)
        }
        ["sh", "-c", script, "sh", ..] if script.contains("rev-parse --verify --quiet") => {
            exec_ok(&sc.used)
        }
        ["git", "-C", _, "remote", "get-url", "origin"] => {
            if sc.origin {
                exec_ok("git@github.com:pollenjp/claude-skills.git\n")
            } else {
                exec_result(2, "", "error: No such remote 'origin'")
            }
        }
        [
            "git",
            "-C",
            _,
            "symbolic-ref",
            "--short",
            "refs/remotes/origin/HEAD",
        ] => exec_ok("origin/main\n"),
        ["git", "-C", _, "symbolic-ref", "--short", "HEAD"] => exec_ok("main\n"),
        ["git", "-C", _, "rev-parse", "--show-toplevel"] => exec_ok(&format!("{}\n", sc.toplevel)),
        ["git", "-C", _, "status", "--short"] => exec_ok(&sc.status_short),
        ["git", "-C", _, "branch", "--show-current"] => exec_ok(&format!("{}\n", sc.branch_now)),
        ["git", "-C", _, "rev-parse", "--verify", "--quiet", _] => {
            exec_ok(&format!("{}\n", sc.tip))
        }
        [
            "git",
            "-C",
            _,
            "reflog",
            "show",
            "--format=%gs",
            "-n",
            "50",
            "HEAD",
        ] => exec_ok(&sc.reflog),
        ["git", "-C", _, "merge-base", "--is-ancestor", _, _] => {
            if sc.ancestor_ok {
                exec_ok("")
            } else {
                exec_result(1, "", "")
            }
        }
        ["git", "-C", _, "branch", "-d", _] => {
            if sc.d_fails {
                exec_result(1, "", "error: the branch 'x' is not fully merged")
            } else {
                exec_ok("Deleted branch\n")
            }
        }
        ["git", ..] | ["mkdir", "-p", _] => exec_ok(""),
        ["hc", "ls", "--json"] => {
            if sc.ls_fail == LsFail::InExec {
                exec_result(
                    1,
                    "",
                    r#"{"error":{"kind":"unavailable","message":"the core is not running"}}"#,
                )
            } else {
                exec_ok(&as_ls(&sc.grandkids).to_string())
            }
        }
        _ => exec_result(127, "", &format!("偽物が知らない exec: {}", cmd.join(" "))),
    }
}

struct World {
    fake: Fake,
    brief: PathBuf,
    _t: TempDir,
}

fn world(sc: Sc) -> World {
    world_with(sc, |f| f)
}

fn world_with(sc: Sc, tweak: impl FnOnce(Fake) -> Fake) -> World {
    let gets = Rc::new(Cell::new(0));
    let g = Rc::clone(&gets);
    let fake = tweak(Fake::new(move |argv| respond(&sc, &g, argv)).env("HC_TERMINAL_ID", "t8"));
    let t = TempDir::new("brief");
    let brief = t.write("brief.md", "依頼の本文\n");
    World { fake, brief, _t: t }
}

struct Out {
    code: u8,
    out: String,
    err: String,
}

fn run(w: &World, args: &[&str]) -> Out {
    let args: Vec<String> = args.iter().map(|s| (*s).to_owned()).collect();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = main(&w.fake, &args, &mut out, &mut err);
    Out {
        code,
        out: String::from_utf8(out).unwrap(),
        err: String::from_utf8(err).unwrap(),
    }
}

fn new_args<'a>(w: &'a World, extra: &[&'a str]) -> Vec<&'a str> {
    let mut v = vec![
        "new",
        "--on",
        "wsl1",
        "--repo",
        "pollenjp/claude-skills",
        "--label",
        "claude-skills: W2-2",
        "--agent",
        "w22",
        "--brief",
        w.brief.to_str().unwrap(),
    ];
    v.extend_from_slice(extra);
    v
}

/// hc run の argv (`hc run …`)。
fn run_call(w: &World) -> Vec<String> {
    w.fake
        .calls()
        .into_iter()
        .find(|c| c.len() > 1 && c[0] == "hc" && c[1] == "run")
        .expect("hc run が打たれていない")
}

fn ledger_rows(w: &World, key: &str) -> Vec<Row> {
    crate::ledger::Ledger::open(
        &w.fake.base().join("state").join("pjp").join("children"),
        key,
    )
    .unwrap()
    .rows()
    .unwrap()
}

/// `herdr-app do space.new` に渡した JSON。
fn space_new_args(w: &World) -> Value {
    let call = w
        .fake
        .calls()
        .into_iter()
        .find(|c| c.len() > 3 && c[0] == "herdr-app" && c[2] == "space.new")
        .expect("space.new が打たれていない");
    serde_json::from_str(&call[3]).unwrap()
}

fn has_call(w: &World, needle: &str) -> bool {
    w.fake.lines().iter().any(|l| l.contains(needle))
}

// ---- new

#[test]
fn new_happy_path() {
    let w = world(Sc::default());
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let lines = w.fake.lines();
    let order = [
        "hc get t8 --json",
        "sh -c",
        "hc ls --json",
        &format!("git -C {CK} remote get-url origin"),
        &format!("git -C {CK} gh fetch origin"),
        &format!("git -C {CK} symbolic-ref --short refs/remotes/origin/HEAD"),
        "rev-parse --verify --quiet",
        &format!("git -C {CK} worktree add -b worktree/w22 {WT} origin/main"),
        &format!("git -C {WT} branch --unset-upstream"),
        "herdr-app do space.new",
        "hc run --bg --json",
    ];
    let mut at = 0;
    for want in order {
        let found = lines[at..].iter().position(|l| l.contains(want));
        assert!(
            found.is_some(),
            "{want} が {at} 行目より後に無い:\n{}",
            lines.join("\n")
        );
        at += found.unwrap() + 1;
    }
    // 子のマシンのコマンドは hc exec --on wsl1 で打つ
    assert!(
        lines
            .iter()
            .filter(|l| l.starts_with("hc exec"))
            .all(|l| l.contains("--on wsl1")),
        "{lines:?}"
    );
    // space は「英字 label」の名前で、子のマシンに作る
    // herdr-app が focus を知っていれば (0.1.16 から) "focus": false を渡し、画面を子の space に移さない
    let args = space_new_args(&w);
    assert_eq!(
        args,
        json!({"name": "A claude-skills: W2-2", "folder": WT, "machine": "wsl1", "focus": false})
    );
    assert!(!r.err.contains("画面は子の space に移る"), "{}", r.err);

    // --parent は渡さない (hc は HC_TERMINAL_ID の端末を親にする。--parent は --on のマシンの中で読まれる)
    let mut want: Vec<String> = [
        "hc",
        "run",
        "--bg",
        "--json",
        "--on",
        "wsl1",
        "--cwd",
        WT,
        "--name",
        "w22",
        "--outlive-parent",
        "--label",
        "herdr.space=sp1",
        "--label",
        "herdr.tab=tb1",
        "--label",
        "pjp.role=child",
        "--label",
        "pjp.letter=A",
        "--",
        "env",
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect();
    for n in HERDR_ENV_NAMES {
        want.extend(["-u".to_owned(), n.to_owned()]);
    }
    for n in super::account::CLEARED_ENV {
        want.extend(["-u".to_owned(), n.to_owned()]);
    }
    want.push(CLAUDE.to_owned());
    want.extend(claude_config_args().unwrap());
    want.extend(
        ["--effort", "high", "--no-chrome", "依頼の本文\n"]
            .iter()
            .map(|s| (*s).to_owned()),
    );
    assert_eq!(run_call(&w), want);

    let rows = ledger_rows(&w, "ABC-681");
    assert_eq!(rows.len(), 1);
    let row = &rows[0];
    assert_eq!(
        (
            row.letter.as_str(),
            row.state.as_str(),
            row.terminal.as_str(),
            row.name.as_str()
        ),
        ("A", state::LIVE, "wsl1/t13", "w22")
    );
    assert_eq!(
        (
            row.machine.as_str(),
            row.worktree.as_str(),
            row.branch.as_str()
        ),
        ("wsl1", WT, "worktree/w22")
    );
    assert_eq!(
        (row.space.as_str(), row.tab.as_str(), row.base.as_str()),
        ("wsl1/sp1", "wsl1/tb1", "origin/main")
    );

    assert!(r.out.contains("子 A を立てた: w22 (wsl1/t13)"), "{}", r.out);
    assert!(
        r.out.contains(
            "worktree: ~/.herdr/worktrees/claude-skills/w22 (branch worktree/w22、base origin/main)"
        ),
        "{}",
        r.out
    );
    assert!(
        r.out
            .contains("space: A claude-skills: W2-2 (space sp1・tab tb1)"),
        "{}",
        r.out
    );
    assert!(
        r.out.contains("chrome: 使わない (--no-chrome)"),
        "{}",
        r.out
    );
    assert!(r.out.contains("状態: working"), "{}", r.out);
    assert!(r.out.contains("note 用: 子 A = pollenjp/claude-skills (wsl1/t13・~/.herdr/worktrees/claude-skills/w22・effort high)"), "{}", r.out);
    assert!(!r.out.contains("!!"), "{}", r.out);
}

#[test]
fn new_builds_remote_paths_with_slashes() {
    let w = world(Sc::default());
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    let call = run_call(&w);
    let cwd = value_after(&call, "--cwd").unwrap();
    assert_eq!(cwd, WT);
    assert!(!cwd.contains('\\'));
}

#[test]
fn new_picks_free_suffix() {
    // worktree か branch が 1・2 番で使われている
    let w = world(Sc {
        used: "1\n2\n".to_owned(),
        ..Sc::default()
    });
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    let call = run_call(&w);
    assert_eq!(value_after(&call, "--name"), Some("w22-3"));
    assert_eq!(
        value_after(&call, "--cwd"),
        Some(format!("{WT}-3").as_str())
    );
    assert!(has_call(
        &w,
        &format!("worktree add -b worktree/w22-3 {WT}-3 origin/main")
    ));

    // 端末の名前だけが使われている
    let w = world(Sc {
        names: vec!["w22".to_owned()],
        ..Sc::default()
    });
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    assert_eq!(value_after(&run_call(&w), "--name"), Some("w22-2"));
}

// ---- new・restart・cleanup: herdr-app の無いマシン (Linux のハブ)

/// 子のマシン (wsl1) の doc herdr-app にある、ほかの会話の space (このマシンの別の worktree の会話)。
fn other_space() -> Value {
    json!({"folder": "/home/u/.herdr/worktrees/h/w1", "id": "sphub", "name": "ABC-833 移行", "tabs": [{"id": "tbhub", "name": "",
        "root": {"children": [{"content": {"terminal": "t8"}, "id": "p8", "type": "block"}], "id": "tbhub", "type": "row"}}]})
}

/// 子 A の space (控えの live_row の wsl1/sp1・wsl1/tb1) に、端末 `terminals` のペインを置いたもの。
fn child_space(name: &str, terminals: &[&str]) -> Value {
    let children: Vec<Value> = terminals
        .iter()
        .map(|t| json!({"content": {"terminal": t}, "id": format!("p-{t}"), "type": "block"}))
        .collect();
    json!({"folder": WT, "id": "sp1", "name": name, "tabs": [{"id": "tb1", "name": "",
        "root": {"children": children, "id": "tb1", "type": "row"}}]})
}

/// herdr-app の無いハブの世界。wsl1 の doc は `doc`。
fn no_app_world(sc: Sc, doc: DocSim) -> (World, Rc<RefCell<DocSim>>) {
    let doc = Rc::new(RefCell::new(doc));
    let w = world_with(
        Sc {
            doc: Rc::clone(&doc),
            ..sc
        },
        |f| f.without("herdr-app"),
    );
    (w, doc)
}

/// herdr-app を打ったか (doc の要求の JSON にも "herdr-app" の字は入るので、program で見る)。
fn called_herdr_app(w: &World) -> bool {
    w.fake.calls().iter().any(|c| c[0] == "herdr-app")
}

#[test]
fn new_without_herdr_app_makes_the_space_with_labels_and_names_it_in_doc() {
    // 偽の herdr-app (Windows。wsl1 の core につながっている) は、label を見て doc.get 1 回の後に space を作る
    let (w, doc) = no_app_world(
        Sc::default(),
        DocSim::at(json!({"spaces": [other_space()]}), 30)
            .on("wsl1")
            .running(1),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // 新しい id (herdr-app と同じ形) の label で立てる
    let (sp, tb) = (format_id("sp", 1), format_id("tb", 2));
    let call = run_call(&w);
    assert!(call.contains(&format!("herdr.space={sp}")), "{call:?}");
    assert!(call.contains(&format!("herdr.tab={tb}")), "{call:?}");
    assert!(!called_herdr_app(&w), "{:?}", w.fake.lines());
    // herdr-app が作った space に、herdr-app があるときと同じ名前を付ける (ほかの space はそのまま)
    let d = doc.borrow();
    assert_eq!(d.space_ids(), ["sphub".to_owned(), sp.clone()]);
    assert_eq!(d.space(&sp).unwrap()["name"], "A claude-skills: W2-2");
    assert_eq!(d.space("sphub").unwrap(), &other_space());
    // 待ってから名前を付けるのは、子の状態の報告を待った後
    let lines = w.fake.lines();
    let reported = lines
        .iter()
        .rposition(|l| l.starts_with("hc get wsl1/t13"))
        .unwrap();
    let first_doc = lines
        .iter()
        .position(|l| l.starts_with("hc connect"))
        .unwrap();
    assert!(reported < first_doc, "{lines:?}");
    assert_eq!(
        rpc_methods(&w.fake),
        ["doc.get", "doc.get", "doc.get", "doc.set"]
    );
    // 控えには herdr-app の形の id (別のマシンなら wsl1/ が付く) と、space の名前
    let row = &ledger_rows(&w, "ABC-681")[0];
    assert_eq!(row.space, format!("wsl1/{sp}"));
    assert_eq!(row.tab, format!("wsl1/{tb}"));
    assert_eq!(row.space_name, "A claude-skills: W2-2");
    assert!(
        r.out.contains(&format!(
            "space: A claude-skills: W2-2 (space {sp}・tab {tb}。herdr-app が無いので、label から herdr-app に作らせ、名前は hc の doc で付ける)"
        )),
        "{}",
        r.out
    );
    assert!(
        r.out.contains(
            "space の名前: herdr-app が label から作った space に付けた (wsl1 の hc の doc herdr-app の版 31 → 32)"
        ),
        "{}",
        r.out
    );
    assert!(
        !r.out.contains("!!") && !r.err.contains("!!"),
        "{}\n{}",
        r.out,
        r.err
    );
}

#[test]
fn new_without_herdr_app_adds_the_space_when_herdr_app_does_not_make_it() {
    // herdr-app が動いていない (Windows で閉じている)。待っても space ができないので、名前つきの space を doc に足す
    let (w, doc) = no_app_world(
        Sc::default(),
        DocSim::at(json!({"spaces": [other_space()]}), 30).on("wsl1"),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let (sp, tb) = (format_id("sp", 1), format_id("tb", 2));
    let d = doc.borrow();
    assert_eq!(
        d.space(&sp).unwrap(),
        &json!({"folder": WT, "id": sp, "name": "A claude-skills: W2-2", "tabs": [{"id": tb, "name": "",
            "root": {"children": [{"content": {"terminal": "t13"}, "id": format_id("p", 3), "type": "block"}],
                "id": tb, "type": "row"}}]})
    );
    assert!(
        r.out.contains(
            "space の名前: herdr-app が space を作らなかった (動いていない・遅い) ので、wsl1 の hc の doc herdr-app に名前つきの space を足した (版 30 → 31)。herdr-app が開くと、この space に子が出る"
        ),
        "{}",
        r.out
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].space, format!("wsl1/{sp}"));
}

#[test]
fn new_without_herdr_app_on_this_machine_reads_this_core_doc() {
    // --on local: このマシンの core の doc (on を渡さない)。控えの id にもマシンを付けない
    let (w, doc) = no_app_world(
        Sc::default(),
        DocSim::at(json!({"spaces": [other_space()]}), 30).running(0),
    );
    let mut args = new_args(&w, &[]);
    args[2] = "local";
    let r = run(&w, &args);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let sp = format_id("sp", 1);
    assert_eq!(
        doc.borrow().space(&sp).unwrap()["name"],
        "A claude-skills: W2-2"
    );
    assert!(
        rpc_calls(&w.fake)
            .iter()
            .all(|r| r["params"].get("on").is_none())
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].space, sp);
    assert!(
        r.out.contains("(hc の doc herdr-app の版 31 → 32)"),
        "{}",
        r.out
    );
}

#[test]
fn new_without_herdr_app_goes_on_when_the_doc_cannot_be_used() {
    // doc がまだ無い (このマシンの space を herdr-app が置いたことが無い)。書かずに進め、label は付けたまま
    let (w, doc) = no_app_world(Sc::default(), DocSim::default().on("wsl1"));
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(run_call(&w).contains(&format!("herdr.space={}", format_id("sp", 1))));
    assert!(rpc_methods(&w.fake).iter().all(|m| m == "doc.get"));
    assert_eq!(doc.borrow().version, 0);
    assert!(
        r.out.contains(
            "!! space の名前を付けない (wsl1 の hc の doc herdr-app もまだ無い (版 0))。herdr-app が開くと label から space を作る (名前はフォルダ名)"
        ),
        "{}",
        r.out
    );
    // 立てた子は立てたまま
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::LIVE);
}

#[test]
fn new_without_herdr_app_rolls_back_without_the_space() {
    // hc run が落ち、子も見つからない。label の space は herdr-app が作っていないので、閉じるものは無い
    let (w, doc) = no_app_world(
        Sc {
            run_fail: true,
            grandkids: json!({"terminals": []}),
            ..Sc::default()
        },
        DocSim::at(json!({"spaces": [other_space()]}), 30).on("wsl1"),
    );
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(!called_herdr_app(&w), "{:?}", w.fake.lines());
    assert!(!r.err.contains("space"), "{}", r.err);
    assert!(r.err.contains("戻した: worktree"), "{}", r.err);
    assert!(rpc_calls(&w.fake).is_empty(), "{:?}", w.fake.lines());
    assert_eq!(doc.borrow().version, 30);
}

#[test]
fn new_space_focus_follows_herdr_app_commands() {
    // 0.1.15: commands の space.new に focus が無いので渡さない (渡すと落ちる)。画面が移ると 1 行出す
    let w = world(Sc {
        app_commands: Some(COMMANDS_0_1_15.to_owned()),
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}", r.err);
    let args = space_new_args(&w);
    assert!(args.get("focus").is_none(), "{args}");
    assert_eq!(
        args,
        json!({"name": "A claude-skills: W2-2", "folder": WT, "machine": "wsl1"})
    );
    assert!(
        r.err.contains(
            "note: herdr-app の版が space.new の focus を知らない (0.1.16 から) ので、画面は子の space に移る"
        ),
        "{}",
        r.err
    );
    assert!(r.out.contains("space: "), "{}", r.out);
    assert!(!r.out.contains("space: なし"), "{}", r.out);

    // commands が落ちる: 渡さない側に倒し、space.new そのものは打つ
    let w = world(Sc {
        app_commands: None,
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(space_new_args(&w).get("focus").is_none());
    assert!(
        r.err.contains("note: herdr-app commands を読めない (終了コード 1: herdr-app: cannot read commands) ので space.new に focus を渡さない"),
        "{}",
        r.err
    );
    assert!(!r.out.contains("space: なし"), "{}", r.out);

    // commands が JSON の配列でない・space.new が載っていない: 渡さない
    for (list, why) in [
        ("not json", "JSON の配列でない"),
        (
            r#"[{"name":"tab.new","args":[{"name":"focus","required":false}]}]"#,
            "space.new が載っていない",
        ),
    ] {
        let w = world(Sc {
            app_commands: Some(list.to_owned()),
            ..Sc::default()
        });
        let r = run(&w, &new_args(&w, &[]));
        assert_eq!(r.code, OK, "{}", r.err);
        assert!(space_new_args(&w).get("focus").is_none(), "{list}");
        assert!(r.err.contains(&format!("読めない ({why})")), "{}", r.err);
    }

    // commands は 1 回だけ読む
    let w = world(Sc::default());
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    let n = w
        .fake
        .lines()
        .iter()
        .filter(|l| *l == "herdr-app commands")
        .count();
    assert_eq!(n, 1, "{:?}", w.fake.lines());
}

#[test]
fn new_dry_run_shows_space_focus() {
    for (commands, want) in [
        (
            Some(COMMANDS_0_1_16),
            "herdr-app do space.new (名前 'A claude-skills: W2-2'。focus: false。画面は移さない)",
        ),
        (
            Some(COMMANDS_0_1_15),
            "herdr-app do space.new (名前 'A claude-skills: W2-2'。focus を渡さない (herdr-app の版が知らない)。画面は子の space に移る)",
        ),
        (
            None,
            "herdr-app do space.new (名前 'A claude-skills: W2-2'。focus を渡さない (herdr-app commands を読めない: 終了コード 1: herdr-app: cannot read commands)。画面は子の space に移る)",
        ),
    ] {
        let w = world(Sc {
            app_commands: commands.map(str::to_owned),
            ..Sc::default()
        });
        let r = run(&w, &new_args(&w, &["--dry-run"]));
        assert_eq!(r.code, OK, "{}", r.err);
        assert!(r.out.contains(want), "{want}\n{}", r.out);
        assert!(!has_call(&w, "herdr-app do"), "{:?}", w.fake.lines());
    }
    let (w, _) = no_app_world(Sc::default(), DocSim::default().on("wsl1"));
    let r = run(&w, &new_args(&w, &["--dry-run"]));
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        r.out.contains(
            "space 'A claude-skills: W2-2': herdr-app が無いので、新しい id の label herdr.space・herdr.tab で立てて herdr-app に作らせ、wsl1 の hc の doc herdr-app で名前を付ける (作られなければ doc に足す)"
        ),
        "{}",
        r.out
    );
    assert!(!r.out.contains("herdr-app do space.new"), "{}", r.out);
    assert!(rpc_calls(&w.fake).is_empty());
}

#[test]
fn new_herdr_app_error_skips_space() {
    let w = world(Sc {
        app_fail: true,
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(!run_call(&w).iter().any(|a| a.starts_with("herdr.")));
    assert!(r.err.contains("space を作れませんでした"), "{}", r.err);
}

#[test]
fn new_passes_brief_as_one_argument() {
    let w = world(Sc::default());
    let brief = "1 行目\n\"引用\" 'single' `cmd` $(rm -rf ~) \\ $HOME\n";
    std::fs::write(&w.brief, brief).unwrap();
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    assert_eq!(run_call(&w).last().unwrap(), brief);
}

#[test]
fn new_brief_with_bom_and_crlf() {
    let w = world(Sc::default());
    std::fs::write(&w.brief, b"\xEF\xBB\xBFa\r\nb\r\n").unwrap();
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    assert_eq!(run_call(&w).last().unwrap(), "a\nb\n");
    // UTF-16 (PowerShell 5 の Out-File)
    let mut utf16 = vec![0xFF, 0xFE];
    for u in "ユ\n".encode_utf16() {
        utf16.extend(u.to_le_bytes());
    }
    let w = world(Sc::default());
    std::fs::write(&w.brief, utf16).unwrap();
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    assert_eq!(run_call(&w).last().unwrap(), "ユ\n");
}

#[test]
fn new_chrome_and_settings() {
    let w = world(Sc::default());
    // pack の木 (ハブの skill の置き場)
    let skills = w.fake.base().join("skills");
    std::fs::create_dir_all(skills.join("pjp-pack-diagram")).unwrap();
    std::fs::write(
        skills.join("pjp-pack-diagram").join("SKILL.md"),
        "---\nname: pjp-pack-diagram\ndescription: x\n---\n\n## pjp-a\n",
    )
    .unwrap();
    std::fs::create_dir_all(skills.join("pjp-a")).unwrap();
    std::fs::write(
        skills.join("pjp-a").join("SKILL.md"),
        "---\nname: pjp-a\ndescription: x\nmetadata:\n  pjp-pack: diagram\n---\n",
    )
    .unwrap();
    let r = run(
        &w,
        &new_args(&w, &["--chrome", "--pack", "diagram", "--effort", "high"]),
    );
    assert_eq!(r.code, OK, "{}", r.err);
    let call = run_call(&w);
    assert!(call.contains(&"--chrome".to_owned()));
    assert!(!call.contains(&"--no-chrome".to_owned()));
    assert_eq!(
        value_after(&call, "--settings"),
        Some(r#"{"skillOverrides":{"pjp-a":"on"}}"#)
    );
    assert_eq!(value_after(&call, "--effort"), Some("high"));
    assert!(r.out.contains("pack: diagram"), "{}", r.out);
    assert!(r.out.contains("chrome: 使う (--chrome)"), "{}", r.out);

    // 入口の無い pack では何も作らずに止まる
    let w2 = world(Sc::default());
    let r = run(&w2, &new_args(&w2, &["--pack", "nosuch"]));
    assert_eq!(r.code, CONFIG, "{}", r.err);
    assert!(!has_call(&w2, "worktree add"));
    assert!(!has_call(&w2, "hc run"));
}

#[test]
fn new_rejects_long_brief() {
    let w = world(Sc::default());
    std::fs::write(&w.brief, "あ".repeat(31_000)).unwrap();
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, CONFIG, "{}", r.err);
    assert!(r.err.contains("依頼が長すぎます"), "{}", r.err);
    assert!(!has_call(&w, "worktree add"));
    assert!(!has_call(&w, "hc run"));
    assert!(ledger_rows(&w, "ABC-681").is_empty());
}

#[test]
fn new_dir_skips_worktree() {
    let w = world(Sc::default());
    let r = run(
        &w,
        &[
            "new",
            "--on",
            "wsl1",
            "--dir",
            "~/.local/share/pjp-video/x",
            "--label",
            "video: 短尺",
            "--agent",
            "vid",
            "--brief",
            w.brief.to_str().unwrap(),
        ],
    );
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(has_call(&w, "mkdir -p /home/u/.local/share/pjp-video/x"));
    assert!(!has_call(&w, "worktree add"));
    assert_eq!(
        value_after(&run_call(&w), "--cwd"),
        Some("/home/u/.local/share/pjp-video/x")
    );
    assert!(r.out.contains("(worktree なし)"), "{}", r.out);
}

#[test]
fn new_checkout_without_origin() {
    let w = world(Sc {
        origin: false,
        ..Sc::default()
    });
    let r = run(
        &w,
        &[
            "new",
            "--on",
            "wsl1",
            "--checkout",
            "~/h",
            "--label",
            "h: chrome",
            "--agent",
            "mf",
            "--brief",
            w.brief.to_str().unwrap(),
        ],
    );
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(has_call(&w, "git -C /home/u/h rev-parse --show-toplevel"));
    assert!(!has_call(&w, "fetch origin"));
    assert!(has_call(
        &w,
        "git -C /home/u/h worktree add -b worktree/mf /home/u/.herdr/worktrees/h/mf main"
    ));
}

#[test]
fn new_reports_blocked_screen() {
    let w = world(Sc {
        child: vec![child_term("blocked", true)],
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(r.out.contains("状態: blocked"), "{}", r.out);
    assert!(
        r.out.contains("!! 子は確認の画面で止まっています"),
        "{}",
        r.out
    );
    assert!(
        r.out.contains("| Do you trust the files in this folder?"),
        "{}",
        r.out
    );
    assert!(r.out.contains("hc keys wsl1/t13"), "{}", r.out);
}

#[test]
fn new_waits_for_report() {
    let w = world(Sc {
        child: vec![
            child_term("", false),
            child_term("", false),
            child_term("working", true),
        ],
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}", r.err);
    assert_eq!(w.fake.slept().len(), 2);
    assert!(r.out.contains("状態: working"), "{}", r.out);
    // 30 秒たっても報告が無ければ画面を出す
    let w = world(Sc {
        child: vec![child_term("", false)],
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(w.fake.slept().len(), 29);
    assert!(
        r.out.contains("30 秒たっても状態の報告がありません"),
        "{}",
        r.out
    );
}

#[test]
fn new_needs_hc_terminal_and_valid_args() {
    let w = world_with(Sc::default(), |f| f.env("HC_TERMINAL_ID", ""));
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, CONFIG);
    assert!(r.err.contains("hc の端末の中で打つ"), "{}", r.err);

    let w = world(Sc::default());
    for bad in [
        vec!["--effort", "ultra"],
        vec!["--checkout", "~/h"],
        vec!["--agent", "Bad_Name"],
    ] {
        let mut args = new_args(&w, &[]);
        if bad[0] == "--agent" {
            let i = args.iter().position(|a| *a == "w22").unwrap();
            args[i] = bad[1];
        } else {
            args.extend(bad);
        }
        let r = run(&w, &args);
        assert_eq!(r.code, CONFIG, "{args:?}: {}", r.err);
    }
    assert!(!has_call(&w, "hc run"));
}

#[test]
fn new_rejects_windows_path_for_dir() {
    let w = world(Sc::default());
    let r = run(
        &w,
        &[
            "new",
            "--on",
            "wsl1",
            "--dir",
            r"C:\Users\user/x",
            "--label",
            "x",
            "--agent",
            "x",
            "--brief",
            w.brief.to_str().unwrap(),
        ],
    );
    assert_eq!(r.code, CONFIG, "{}", r.err);
    assert!(
        r.err.contains("子のマシンのパスではありません"),
        "{}",
        r.err
    );
}

#[test]
fn new_machine_from_hub_toml_and_local() {
    let w = world(Sc::default());
    let cfg = w.fake.base().join("config").join("pjp");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::write(cfg.join("hub.toml"), "default_machine = \"host-a\"\n").unwrap();
    let mut args = new_args(&w, &[]);
    args.drain(1..3); // --on wsl1 を外す
    assert_eq!(run(&w, &args).code, OK);
    assert!(
        w.fake
            .lines()
            .iter()
            .filter(|l| l.starts_with("hc exec"))
            .all(|l| l.contains("--on host-a"))
    );
    assert_eq!(value_after(&run_call(&w), "--on"), Some("host-a"));
    // hub.toml の default_machine を使うときは、machine の一覧を読まない (自動で選ぶのは tests/auto.rs)
    assert!(!has_call(&w, "hc machine ls"));

    // local はこのマシン (--on を付けない)
    let w = world(Sc::default());
    let mut args = new_args(&w, &[]);
    args[2] = "local";
    assert_eq!(run(&w, &args).code, OK);
    assert!(
        !w.fake.lines().iter().any(|l| l.contains("--on")),
        "{:?}",
        w.fake.lines()
    );
    assert!(space_new_args(&w).get("machine").is_none());
}

#[test]
fn new_letters_advance_and_ticket_fallback() {
    let w = world(Sc::default());
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK);
    assert!(r.out.contains("子 B を立てた"), "{}", r.out);
    let rows = ledger_rows(&w, "ABC-681");
    assert_eq!(
        rows.iter().map(|r| r.letter.as_str()).collect::<Vec<_>>(),
        ["A", "B"]
    );

    // この端末に pjp.ticket が無ければ、この端末の住所で控える
    let w = world(Sc {
        hub_labels: json!({}),
        ..Sc::default()
    });
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    assert_eq!(ledger_rows(&w, "t-t8").len(), 1);
    // --ticket が先
    assert_eq!(run(&w, &new_args(&w, &["--ticket", "ABC-9"])).code, OK);
    assert_eq!(ledger_rows(&w, "ABC-9")[0].letter, "A");
}

#[test]
fn new_rollback_when_run_fails() {
    // 子のマシンの一覧にも、その名前の端末がいない (本当に立たなかった)
    let w = world(Sc {
        run_fail: true,
        grandkids: json!({"terminals": []}),
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}", r.out);
    assert!(r.err.contains("cannot start"), "{}", r.err);
    assert!(
        r.err.contains("戻した: space wsl1/sp1 を閉じた"),
        "{}",
        r.err
    );
    assert!(has_call(
        &w,
        &format!("git -C {CK} worktree remove --force {WT}")
    ));
    assert!(has_call(&w, &format!("git -C {CK} branch -D worktree/w22")));
    let close = w
        .fake
        .calls()
        .into_iter()
        .find(|c| c.len() > 3 && c[0] == "herdr-app" && c[2] == "space.close")
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&close[3]).unwrap(),
        json!({"id": "wsl1/sp1", "confirmed": true})
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::FAILED);
}

#[test]
fn new_dry_run_does_not_mutate() {
    let w = world(Sc::default());
    let r = run(&w, &new_args(&w, &["--dry-run"]));
    assert_eq!(r.code, OK, "{}", r.err);
    for mutating in [
        "fetch origin",
        "worktree add",
        "herdr-app do",
        "hc run",
        "unset-upstream",
    ] {
        assert!(!has_call(&w, mutating), "{mutating}: {:?}", w.fake.lines());
    }
    assert!(ledger_rows(&w, "ABC-681").is_empty());
    assert!(r.out.contains("(--dry-run) 子 A を立てるなら"), "{}", r.out);
    assert!(
        r.out.contains(
            "worktree add -b worktree/w22 ~/.herdr/worktrees/claude-skills/w22 origin/main"
        ),
        "{}",
        r.out
    );
    assert!(r.out.contains("<依頼 (6 字)>"), "{}", r.out);
}

#[test]
fn new_clones_with_ghq_when_missing() {
    let w = world(Sc {
        checkout: String::new(),
        ..Sc::default()
    });
    // ghq get の後の探りでも checkout が空なら止まる
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}", r.err);
    assert!(has_call(&w, "ghq get pollenjp/claude-skills"));
    assert!(r.err.contains("ghq get の後も"), "{}", r.err);
}

// ---- new: GitHub へ出る git を gh の資格情報で打つ

#[test]
fn new_fetch_uses_git_gh() {
    let w = world(Sc::default());
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(has_call(
        &w,
        &format!("hc exec --json --on wsl1 --timeout 300 -- git -C {CK} gh fetch origin")
    ));
    assert!(!has_call(&w, &format!("-- git -C {CK} fetch origin")));
}

#[test]
fn new_fetch_without_git_gh_adds_config_with_c() {
    let w = world(Sc {
        git_gh: false,
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let want = format!("-- {} -C {CK} fetch origin", GH_C.join(" "));
    assert!(has_call(&w, &want), "{want}: {:?}", w.fake.lines());
    assert!(!has_call(&w, " gh fetch origin"));
}

#[test]
fn new_ghq_get_passes_gh_config_in_env() {
    let w = world(Sc {
        checkout: String::new(),
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    // 偽物の ghq get は env の組が無ければ認証で落ちる。通ったので、後の探りで checkout が空と止まる
    assert_eq!(r.code, FAILURE, "{}", r.err);
    assert!(r.err.contains("ghq get の後も"), "{}", r.err);
    let env: Vec<String> = GH_ENV.iter().map(|kv| format!("--env {kv}")).collect();
    let want = format!(
        "hc exec --json --on wsl1 {} --timeout 300 -- ghq get pollenjp/claude-skills",
        env.join(" ")
    );
    assert!(has_call(&w, &want), "{want}: {:?}", w.fake.lines());
}

#[test]
fn new_fetch_auth_failure_explains_and_creates_nothing() {
    let w = world(Sc {
        net_fail: NO_CRED.to_owned(),
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}", r.err);
    for want in [
        &format!(
            "子のマシン (wsl1) で git -C {CK} fetch origin が落ちました (git gh で gh の資格情報を付ける): {NO_CRED}"
        ) as &str,
        "gh auth status",
        "pjp child new --dir",
        "--repo <owner/repo> --branch <作業の branch>",
    ] {
        assert!(r.err.contains(want), "{want}: {}", r.err);
    }
    for mutating in ["worktree add", "herdr-app", "hc run"] {
        assert!(!has_call(&w, mutating), "{mutating}: {:?}", w.fake.lines());
    }
    assert!(ledger_rows(&w, "ABC-681").is_empty());
}

#[test]
fn new_ghq_get_failure_names_repo() {
    let w = world(Sc {
        checkout: String::new(),
        // ghq は stderr の頭に進み具合を出す
        net_fail: "     clone https://github.com/pollenjp/claude-skills -> /home/u/ghq/github.com/pollenjp/claude-skills\n\
                   fatal: Authentication failed for 'https://github.com/pollenjp/claude-skills/'\n\
                   \x1b[0;31m     error\x1b[0m failed to get \"pollenjp/claude-skills\""
            .to_owned(),
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}", r.err);
    assert!(
        r.err.contains(
            "子のマシン (wsl1) で ghq get pollenjp/claude-skills が落ちました (gh の資格情報を GIT_CONFIG_* の env で付ける): fatal: Authentication failed"
        ),
        "{}",
        r.err
    );
}

#[test]
fn new_dry_run_shows_how_credentials_are_added() {
    let w = world(Sc::default());
    let r = run(&w, &new_args(&w, &["--dry-run"]));
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        r.out.contains(
            "git -C ~/ghq/github.com/pollenjp/claude-skills fetch origin (git gh で gh の資格情報を付ける)"
        ),
        "{}",
        r.out
    );
    let w = world(Sc {
        checkout: String::new(),
        git_gh: false,
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &["--dry-run"]));
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        r.out.contains(
            "ghq get pollenjp/claude-skills (gh の資格情報を GIT_CONFIG_* の env で付ける)"
        ),
        "{}",
        r.out
    );
    assert!(
        r.out
            .contains("fetch origin (gh の資格情報を git -c で付ける)"),
        "{}",
        r.out
    );
    assert!(!has_call(&w, "ghq get"));
}

#[test]
fn claude_args_leave_flags_to_pjp_child() {
    let args = claude_config_args().unwrap();
    for owned in [
        "--effort",
        "--remote-control",
        "--chrome",
        "--no-chrome",
        "--settings",
        "--continue",
        "--resume",
    ] {
        assert!(
            !args.iter().any(|a| a.starts_with(owned)),
            "{owned} は pjp child が足す: {args:?}"
        );
    }
    assert!(args.contains(&"--dangerously-skip-permissions".to_owned()));
    assert!(valid_name("skills-w22"));
    assert!(!valid_name(""));
    assert!(!valid_name(&"a".repeat(33)));
}

// ---- restart

fn seed_row(w: &World, key: &str, row: Row) {
    let l = crate::ledger::Ledger::open(
        &w.fake.base().join("state").join("pjp").join("children"),
        key,
    )
    .unwrap();
    l.reserve(|_| row).unwrap();
}

fn live_row() -> Row {
    Row {
        state: state::LIVE.into(),
        terminal: "wsl1/t13".into(),
        name: "w22".into(),
        machine: "wsl1".into(),
        repo: "pollenjp/claude-skills".into(),
        checkout: CK.into(),
        worktree: WT.into(),
        branch: "worktree/w22".into(),
        base: "origin/main".into(),
        space: "wsl1/sp1".into(),
        tab: "wsl1/tb1".into(),
        ..Row::default()
    }
}

#[test]
fn restart_continues_in_same_worktree() {
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "a", "--effort", "max"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let lines = w.fake.lines();
    let kill = lines
        .iter()
        .position(|l| l.starts_with("hc kill wsl1/t13"))
        .unwrap();
    let rm = lines
        .iter()
        .position(|l| l.starts_with("hc rm wsl1/t13"))
        .unwrap();
    let start = lines.iter().position(|l| l.starts_with("hc run")).unwrap();
    assert!(kill < rm && rm < start, "{lines:?}");
    let call = run_call(&w);
    assert_eq!(value_after(&call, "--name"), Some("w22"));
    assert_eq!(value_after(&call, "--cwd"), Some(WT));
    assert!(call.contains(&"herdr.space=sp1".to_owned()));
    assert!(call.contains(&"pjp.letter=A".to_owned()));
    // 子のチケットの印は前の端末から引き継ぐ
    assert!(call.contains(&"pjp.ticket=ABC-700".to_owned()));
    assert!(call.contains(&"--continue".to_owned()));
    assert!(!call.contains(&"--resume".to_owned()));
    assert!(r.out.contains("子 A を立て直した"), "{}", r.out);
    // herdr-app のあるハブ (Windows) は、hc の doc に触らない (space は herdr-app の shell が持っている)
    assert!(rpc_calls(&w.fake).is_empty(), "{:?}", w.fake.lines());
}

#[test]
fn restart_fresh_starts_new_conversation() {
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let brief = w.brief.to_str().unwrap();
    let r = run(&w, &["restart", "A", "--fresh", "--brief", brief]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let call = run_call(&w);
    // 同じ worktree・名前・英字で、前の会話を続けない
    assert_eq!(value_after(&call, "--cwd"), Some(WT));
    assert_eq!(value_after(&call, "--name"), Some("w22"));
    assert!(call.contains(&"pjp.letter=A".to_owned()));
    assert!(!call.contains(&"--continue".to_owned()));
    assert!(!call.contains(&"--resume".to_owned()));
    assert_eq!(call.last().map(String::as_str), Some("依頼の本文\n"));
    // 別の作業のことが多いので、子のチケットの印は引き継がない
    assert!(
        !call.iter().any(|a| a.starts_with("pjp.ticket=")),
        "{call:?}"
    );
    assert!(r.err.contains("pjp.ticket) は引き継がない"), "{}", r.err);
    assert!(r.out.contains("新しい会話"), "{}", r.out);
}

#[test]
fn restart_fresh_needs_brief_and_no_session() {
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A", "--fresh"]);
    assert_eq!(r.code, CONFIG, "{}", r.err);
    assert!(r.err.contains("--brief が要る"), "{}", r.err);
    let brief = w.brief.to_str().unwrap();
    let r = run(
        &w,
        &[
            "restart",
            "A",
            "--fresh",
            "--session",
            "x",
            "--brief",
            brief,
        ],
    );
    assert_eq!(r.code, CONFIG, "{}", r.err);
    assert!(!has_call(&w, "hc kill"));
    assert!(!has_call(&w, "hc run"));
}

#[test]
fn restart_refuses_working_without_force() {
    let w = world(Sc::default());
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE);
    assert!(r.err.contains("まだ working"), "{}", r.err);
    assert!(!has_call(&w, "hc kill"));
    let r = run(&w, &["restart", "A", "--force", "--session", "abc-123"]);
    assert_eq!(r.code, OK, "{}", r.err);
    let call = run_call(&w);
    assert_eq!(value_after(&call, "--resume"), Some("abc-123"));
    assert!(!call.contains(&"--continue".to_owned()));
}

/// 子 A の space の端末の並び (doc の sp1 の tab のペイン)。
fn child_space_terminals(doc: &DocSim) -> Vec<String> {
    doc.space("sp1").unwrap()["tabs"][0]["root"]["children"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b["content"]["terminal"].as_str().unwrap().to_owned())
        .collect()
}

/// `hc connect` の要求のうち、`after` 番目の呼び出しより後の最初のもの (doc を読んだ所) の位置。
fn first_rpc_after(w: &World, after: usize) -> usize {
    let lines = w.fake.lines();
    lines
        .iter()
        .enumerate()
        .skip(after + 1)
        .find(|(_, l)| l.starts_with("hc connect"))
        .map(|(i, _)| i)
        .unwrap_or_else(|| panic!("{after} より後に hc connect が無い: {lines:?}"))
}

#[test]
fn restart_without_herdr_app_starts_the_new_terminal_before_removing_the_old() {
    // 子 A の space は herdr-app が label から作ったもの (中は子の端末 t13 だけ)。立て直した子は wsl1/t14。herdr-app は doc.get
    // 1 回の後に新しい端末を置く
    let (w, doc) = no_app_world(
        Sc {
            child: vec![child_term("idle", true)],
            run_addr: "wsl1/t14".to_owned(),
            ..Sc::default()
        },
        DocSim::at(
            json!({"spaces": [other_space(), child_space("A claude-skills: W2-2", &["t13"])]}),
            50,
        )
        .on("wsl1")
        .running(1),
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // 前の端末を終えてから立て、消すのは herdr-app が新しい端末を space に置いたのを doc で見た後 (space を空にしない)
    let (kill, wait, start, rm) = (
        call_at(&w, "hc kill wsl1/t13"),
        call_at(&w, "hc wait wsl1/t13"),
        call_at(&w, "hc run"),
        call_at(&w, "hc rm wsl1/t13"),
    );
    assert!(
        kill < wait && wait < start && start < rm,
        "{:?}",
        w.fake.lines()
    );
    let lines = w.fake.lines();
    let polls: Vec<usize> = (start..rm)
        .filter(|i| lines[*i].starts_with("hc connect"))
        .collect();
    assert_eq!(
        polls.len(),
        3,
        "置かれるまで 2 回読み、名前を確かめて 1 回: {lines:?}"
    );
    assert_eq!(polls[0], first_rpc_after(&w, start));
    assert!(run_call(&w).contains(&"herdr.space=sp1".to_owned()));
    // space も名前もそのまま (herdr-app は新しい端末を同じ tab に置いた。前の端末のペインは、herdr-app が rm を読んだら外す)
    let d = doc.borrow();
    assert_eq!(d.space_ids(), ["sphub", "sp1"]);
    assert_eq!(d.space("sp1").unwrap()["name"], "A claude-skills: W2-2");
    assert_eq!(child_space_terminals(&d), ["t13", "t14"]);
    // 名前は確かめるだけ (書かない)
    assert!(!rpc_methods(&w.fake).contains(&"doc.set".to_owned()));
    for want in [
        "前の端末 wsl1/t13 を終えた (消すのは、新しい端末が space に入ってから。space を空にしない)",
        "前の端末 wsl1/t13 を消した",
        "space の名前: 前と同じ (A claude-skills: W2-2)",
    ] {
        assert!(r.out.contains(want), "{want}\n{}", r.out);
    }
    let row = &ledger_rows(&w, "ABC-681")[0];
    assert_eq!(
        (
            row.terminal.as_str(),
            row.space.as_str(),
            row.space_name.as_str()
        ),
        ("wsl1/t14", "wsl1/sp1", "A claude-skills: W2-2")
    );
}

#[test]
fn restart_without_herdr_app_renames_the_space_when_herdr_app_drops_the_pane_at_kill() {
    // 確かめていない場面: herdr-app が、終えただけ (hc kill) の端末のペインもすぐ外す。space が空になって消され、新しい端末の
    // label から同じ id で名前の空の space が作り直される。前の名前を付け直す
    let (w, doc) = no_app_world(
        Sc {
            child: vec![child_term("idle", true)],
            run_addr: "wsl1/t14".to_owned(),
            ..Sc::default()
        },
        DocSim {
            drop_on_kill: true,
            ..DocSim::at(
                json!({"spaces": [other_space(), child_space("A claude-skills: W2-2", &["t13"])]}),
                50,
            )
            .on("wsl1")
            .running(0)
        },
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let d = doc.borrow();
    // 作り直された space は一覧の末尾に来る (herdr-app の新しい space と同じ)。名前は前と同じに戻る
    assert_eq!(d.space_ids(), ["sphub", "sp1"]);
    assert_eq!(d.space("sp1").unwrap()["name"], "A claude-skills: W2-2");
    assert_eq!(child_space_terminals(&d), ["t14"]);
    assert!(
        r.out.contains(
            "space の名前: herdr-app が label から作った space に付けた (wsl1 の hc の doc herdr-app の版 52 → 53)"
        ),
        "{}",
        r.out
    );
}

#[test]
fn restart_without_herdr_app_does_not_take_the_old_terminal_for_the_new_one() {
    // hc run が落ちた。前の端末 (wsl1/t13。終えただけで、まだ消していない) が一覧に生きた端末として出ても、立った子とみない
    let base = Sc {
        child: vec![child_term("idle", true)],
        run_fail: true,
        grandkids: json!({"terminals": []}),
        ..Sc::default()
    };
    let doc = Rc::new(RefCell::new(
        DocSim::at(
            json!({"spaces": [other_space(), child_space("A claude-skills: W2-2", &["t13"])]}),
            50,
        )
        .on("wsl1"),
    ));
    let base = Sc {
        doc: Rc::clone(&doc),
        ..base
    };
    let gets = Rc::new(Cell::new(0));
    let g = Rc::clone(&gets);
    let fake = Fake::new(move |argv| {
        if argv.len() > 1 && argv[0] == "hc" && argv[1] == "ls" {
            return ok(r#"{"terminals":[{"address":"wsl1/t13","name":"w22","state":"live"}]}"#);
        }
        respond(&base, &g, argv)
    })
    .env("HC_TERMINAL_ID", "t8")
    .without("herdr-app");
    let t = TempDir::new("brief-old");
    let brief = t.write("brief.md", "依頼\n");
    let w = World { fake, brief, _t: t };
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(r.err.contains("cannot start"), "{}", r.err);
    assert!(!r.err.contains("が立っているので"), "{}", r.err);
    // 前の端末は消さず (space を残す)、控えも前のまま
    assert!(!has_call(&w, "hc rm"), "{:?}", w.fake.lines());
    assert_eq!(ledger_rows(&w, "ABC-681")[0].terminal, "wsl1/t13");
}

#[test]
fn restart_without_herdr_app_names_the_space_herdr_app_makes_again() {
    // 前の端末 (wsl1/t40) はもう無く、herdr-app は space を消していた。控えの名前を、作り直された space に付ける
    let (w, doc) = no_app_world(
        Sc {
            child: vec![child_term("idle", true)],
            run_addr: "wsl1/t14".to_owned(),
            grandkids: json!({"terminals": []}),
            ..Sc::default()
        },
        DocSim::at(json!({"spaces": [other_space()]}), 50)
            .on("wsl1")
            .running(0),
    );
    seed_row(
        &w,
        "ABC-681",
        Row {
            terminal: "wsl1/t40".into(),
            space_name: "A claude-skills: W2-2".into(),
            ..live_row()
        },
    );
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!has_call(&w, "hc kill"), "{:?}", w.fake.lines());
    let d = doc.borrow();
    assert_eq!(d.space("sp1").unwrap()["name"], "A claude-skills: W2-2");
    assert_eq!(child_space_terminals(&d), ["t14"]);
    assert!(
        r.out.contains(
            "space の名前: herdr-app が label から作った space に付けた (wsl1 の hc の doc herdr-app の版 51 → 52)"
        ),
        "{}",
        r.out
    );
}

#[test]
fn restart_without_herdr_app_keeps_the_old_terminal_when_starting_fails() {
    // 立てられなかった (子も見つからない)。前の端末は終えたまま消さずに残し (space・名前・並びが残る)、space の名前は控えに
    // 残す。次の restart は同じ道で通る
    let (w, doc) = no_app_world(
        Sc {
            child: vec![child_term("idle", true)],
            run_fail: true,
            grandkids: json!({"terminals": []}),
            ..Sc::default()
        },
        DocSim::at(
            json!({"spaces": [other_space(), child_space("A claude-skills: W2-2", &["t13"])]}),
            50,
        )
        .on("wsl1")
        .running(0),
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(r.err.contains("cannot start"), "{}", r.err);
    assert!(has_call(&w, "hc kill wsl1/t13"));
    assert!(!has_call(&w, "hc rm"), "{:?}", w.fake.lines());
    assert!(
        r.out
            .contains("前の端末 wsl1/t13 を終えた (消すのは、新しい端末が space に入ってから"),
        "{}",
        r.out
    );
    assert_eq!(
        doc.borrow().space("sp1").unwrap()["name"],
        "A claude-skills: W2-2"
    );
    let row = &ledger_rows(&w, "ABC-681")[0];
    assert_eq!(row.space_name, "A claude-skills: W2-2");
    assert_eq!(row.terminal, "wsl1/t13");
}

#[test]
fn restart_without_herdr_app_leaves_the_name_when_it_is_unknown() {
    // doc にも (space が無い) 控えにも (前の版の控え) 名前が無い。名前は付けない
    let (w, doc) = no_app_world(
        Sc {
            child: vec![child_term("idle", true)],
            run_addr: "wsl1/t14".to_owned(),
            ..Sc::default()
        },
        DocSim::at(json!({"spaces": [other_space()]}), 50)
            .on("wsl1")
            .running(0),
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        doc.borrow()
            .space("sp1")
            .is_none_or(|sp| sp["name"].as_str() == Some(""))
    );
    assert!(!rpc_methods(&w.fake).contains(&"doc.set".to_owned()));
    assert!(
        r.out.contains(
            "note: space sp1 の前の名前が分からない (doc にも控えにも無い) ので、名前は付けない"
        ),
        "{}",
        r.out
    );
}

// ---- restart: 前の端末が立てた端末 (指揮役から見た孫)

/// 子のマシンの端末 (`hc get` の形)。`dies` は `die_with_parent` (`--outlive-parent` なしで立てたら true)。
fn grand_term(addr: &str, name: &str, parent: &str, dies: bool, labels: Value) -> Value {
    json!({
        "address": addr,
        "agent": "bash",
        "cwd": "/home/u/ghq/github.com/pollenjp/kabu-bot",
        "name": name,
        "parent": parent,
        "state": "live",
        "turn": 0,
        "die_with_parent": dies,
        "keep": true,
        "labels": labels,
    })
}

/// 子が idle で、子のマシンの一覧が `terms` の世界 (控えの子 A は wsl1/t13)。
fn restart_world(terms: Vec<Value>) -> World {
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        grandkids: json!({ "terminals": terms }),
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    w
}

/// `head` で始まる最初の呼び出しの位置。
fn call_at(w: &World, head: &str) -> usize {
    let lines = w.fake.lines();
    lines
        .iter()
        .position(|l| l.starts_with(head))
        .unwrap_or_else(|| panic!("{head} が打たれていない: {lines:?}"))
}

const LS_ON_CHILD: &str = "hc exec --json --on wsl1 --timeout 60 -- hc ls --json";

#[test]
fn restart_notices_terminals_left_by_old_terminal() {
    // 2026-11-19 の朝の形: 前の子が --outlive-parent で立てた live と monitor が残っている
    let w = restart_world(vec![
        grand_term(
            "t20",
            "kabu-live",
            "t13",
            false,
            json!({"herdr.space": "sp5", "herdr.tab": "tb5", "where": "A kabu-bot: 運用 / 1"}),
        ),
        grand_term("t21", "kabu-monitor", "t13", false, json!({})),
        json!({"address": "t1c", "name": "w22", "parent": "e5/t8", "state": "live"}),
    ]);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // 前の端末を終える前に、子のマシンの一覧で探し、見つけた端末を hc get で読む (一覧には label が無い)
    let kill = call_at(&w, "hc kill wsl1/t13");
    assert!(call_at(&w, LS_ON_CHILD) < kill);
    assert!(call_at(&w, "hc get wsl1/t20 --json") < kill);
    assert!(call_at(&w, "hc get wsl1/t21 --json") < kill);
    for want in [
        "!! 前の端末 wsl1/t13 が立てた端末が 2 つ生きている",
        "wsl1/t20 (kabu-live)  space・tab: A kabu-bot: 運用 / 1",
        "wsl1/t21 (kabu-monitor)  space・tab の label なし",
        "親は消えた端末 wsl1/t13 のまま",
        "Agents 欄の木で新しい子の下に出ない",
        "hc には親を付け替える手が無い",
        "新しい子の端末から hc run --outlive-parent で立て直させる",
        "hc kill → hc rm",
    ] {
        assert!(r.err.contains(want), "{want}:\n{}", r.err);
    }
    // --outlive-parent で立てた端末なので、一緒に終わるとは言わず、立て直しは進む
    assert!(!r.err.contains("一緒に終わる"), "{}", r.err);
    assert!(call_at(&w, "hc run") > kill);
    assert!(r.out.contains("子 A を立て直した"), "{}", r.out);
}

#[test]
fn restart_says_nothing_without_grandchildren() {
    let w = restart_world(vec![
        json!({"address": "t1c", "name": "w22", "parent": "e5/t8", "state": "live"}),
    ]);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // 探しはしたが、何も出さない
    assert!(has_call(&w, LS_ON_CHILD));
    assert_eq!(r.err, "");
    assert!(!r.out.contains("立てた端末"), "{}", r.out);
}

#[test]
fn restart_does_not_count_itself_or_siblings_as_grandchildren() {
    let w = restart_world(vec![
        // 子の端末そのもの (親は、ハブの端末を子のマシンから見た住所)
        json!({"address": "t13", "name": "w22", "parent": "e5/t8", "state": "live"}),
        // 兄弟 (ハブの端末の別の子)
        json!({"address": "t9", "name": "sib", "parent": "e5/t8", "state": "live"}),
        // ハブのマシンの t13 (子の端末とは別の端末) の子
        json!({"address": "t30", "name": "hubs", "parent": "e5/t13", "state": "live"}),
        // 終わった端末
        json!({"address": "t31", "name": "done", "parent": "t13", "state": "finished"}),
    ]);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(r.err, "");
    for addr in ["wsl1/t9", "wsl1/t30", "wsl1/t31"] {
        assert!(
            !has_call(&w, &format!("hc get {addr} ")),
            "{addr}: {:?}",
            w.fake.lines()
        );
    }
}

#[test]
fn restart_notices_grandchild_whose_parent_has_machine() {
    // 一覧の parent が、マシン付きの住所 (wsl1/t13) でも拾う
    let w = restart_world(vec![grand_term(
        "t20",
        "kabu-live",
        "wsl1/t13",
        false,
        json!({}),
    )]);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        r.err
            .contains("!! 前の端末 wsl1/t13 が立てた端末が 1 つ生きている"),
        "{}",
        r.err
    );
    assert!(r.err.contains("wsl1/t20 (kabu-live)"), "{}", r.err);
}

#[test]
fn restart_goes_on_when_grandchildren_cannot_be_listed() {
    // 子のマシンの hc ls が落ちる・hc exec そのものが落ちる。再起動の後の立て直しなので止めない
    for how in [LsFail::InExec, LsFail::Exec] {
        let w = world(Sc {
            child: vec![child_term("idle", true)],
            ls_fail: how,
            ..Sc::default()
        });
        seed_row(&w, "ABC-681", live_row());
        let r = run(&w, &["restart", "A"]);
        assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
        assert_eq!(r.err.lines().count(), 1, "{}", r.err);
        assert!(
            r.err
                .starts_with("!! 前の端末が立てた端末 (孫) が残っていないかを確かめられない ("),
            "{}",
            r.err
        );
        assert!(call_at(&w, "hc kill wsl1/t13") < call_at(&w, "hc run"));
    }
}

#[test]
fn restart_stops_before_ending_terminals_that_would_end_with_it() {
    let w = restart_world(vec![
        // --outlive-parent なしで立てた手伝い (前の端末と一緒に終わる)
        grand_term("t22", "tests", "t13", true, json!({})),
        grand_term(
            "t20",
            "kabu-live",
            "t13",
            false,
            json!({"where": "A kabu-bot: 運用 / 1"}),
        ),
    ]);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in ["一緒に終わる", "wsl1/t22 (tests)", "--force"] {
        assert!(r.err.contains(want), "{want}:\n{}", r.err);
    }
    // 前の端末には触らず、立てもしない
    for touched in ["hc kill", "hc rm", "hc run"] {
        assert!(!has_call(&w, touched), "{touched}: {:?}", w.fake.lines());
    }
    assert_eq!(ledger_rows(&w, "ABC-681")[0].terminal, "wsl1/t13");

    // --force なら、一緒に終わる端末を並べてから進む。残る端末は、ふつうの知らせに出る
    let r = run(&w, &["restart", "A", "--force"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    for want in [
        "!! --force なので",
        "wsl1/t22 (tests)",
        "!! 前の端末 wsl1/t13 が立てた端末が 1 つ生きている",
        "wsl1/t20 (kabu-live)  space・tab: A kabu-bot: 運用 / 1",
    ] {
        assert!(r.err.contains(want), "{want}:\n{}", r.err);
    }
    assert!(call_at(&w, "hc kill wsl1/t13") < call_at(&w, "hc run"));
}

#[test]
fn restart_lists_working_child_and_ending_terminals_in_one_refusal() {
    // 子は working (Sc の既定) で、前の端末と一緒に終わる端末もある。1 度の断りで両方を出す
    let w = world(Sc {
        grandkids: json!({"terminals": [grand_term("t22", "tests", "t13", true, json!({}))]}),
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in ["まだ working", "wsl1/t22 (tests)", "--force"] {
        assert!(r.err.contains(want), "{want}:\n{}", r.err);
    }
    assert!(!has_call(&w, "hc kill"));
    let r = run(&w, &["restart", "A", "--force"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, "hc kill wsl1/t13"));
}

#[test]
fn restart_does_not_stop_when_outlive_is_unknown() {
    // hc get に die_with_parent が無い (古い hc)。止めずに、知らせに添える
    let w = restart_world(vec![json!({
        "address": "t20",
        "name": "old-hc",
        "parent": "t13",
        "state": "live",
        "labels": {"herdr.space": "sp5", "herdr.tab": "tb5"},
    })]);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    for want in [
        "wsl1/t20 (old-hc)  space sp5・tab tb5",
        "--outlive-parent で立てていなければ、前の端末と一緒に終わる",
    ] {
        assert!(r.err.contains(want), "{want}:\n{}", r.err);
    }
    assert!(has_call(&w, "hc kill wsl1/t13"));

    // 孫の hc get が落ちた (一緒に終わるかも、どこにいるかも読めない)
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        grandkids: json!({"terminals": [grand_term("t20", "kabu-live", "t13", true, json!({"where": "A kabu-bot: 運用 / 1"}))]}),
        grand_get_fails: true,
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    for want in [
        "wsl1/t20 (kabu-live)  space・tab は分からない",
        "--outlive-parent で立てていなければ、前の端末と一緒に終わる",
    ] {
        assert!(r.err.contains(want), "{want}:\n{}", r.err);
    }
    assert!(has_call(&w, "hc kill wsl1/t13"));
}

#[test]
fn restart_notices_terminals_left_when_old_terminal_is_gone() {
    // 前の端末 (wsl1/t40) はもう無い (前の restart が hc run で落ちたなど)。その端末が立てた端末が残っている
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        grandkids: json!({"terminals": [grand_term("t41", "kabu-live", "t40", false, json!({}))]}),
        ..Sc::default()
    });
    seed_row(
        &w,
        "ABC-681",
        Row {
            terminal: "wsl1/t40".into(),
            ..live_row()
        },
    );
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    for want in [
        "!! 前の端末 wsl1/t40 (もう無い) が立てた端末が 1 つ生きている",
        "wsl1/t41 (kabu-live)",
        "親は消えた端末 wsl1/t40 のまま",
    ] {
        assert!(r.err.contains(want), "{want}:\n{}", r.err);
    }
    assert!(!has_call(&w, "hc kill"), "{:?}", w.fake.lines());
    assert!(has_call(&w, "hc run"));
}

#[test]
fn restart_does_not_look_for_grandchildren_of_reassigned_terminal() {
    // 控えの住所に別の端末がいる (core を立て直して住所が振り直された)。その端末の子は前の子の孫ではない
    let other = json!({"address": "wsl1/t13", "name": "someone", "state": "live", "status": {"state": "idle"}, "labels": {}});
    let w = world(Sc {
        child: vec![other, child_term("idle", true)],
        grandkids: json!({"terminals": [grand_term("t20", "x", "t13", true, json!({}))]}),
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(r.err.contains("別の端末になっている"), "{}", r.err);
    assert!(!has_call(&w, LS_ON_CHILD), "{:?}", w.fake.lines());
    assert!(!r.err.contains("立てた端末"), "{}", r.err);
    assert!(!has_call(&w, "hc kill"));
    assert!(has_call(&w, "hc run"));
}

// ---- ls・send・read・report

#[test]
fn ls_shows_children() {
    let w = world(Sc::default());
    seed_row(&w, "ABC-681", live_row());
    seed_row(
        &w,
        "ABC-681",
        Row {
            state: state::CLEANED.into(),
            name: "old".into(),
            terminal: "wsl1/t9".into(),
            ..Row::default()
        },
    );
    let r = run(&w, &["ls"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        r.out
            .contains("A  w22  wsl1/t13  working  チケット ABC-700  pollenjp/claude-skills"),
        "{}",
        r.out
    );
    assert!(!r.out.contains("old"), "{}", r.out);
    let r = run(&w, &["ls", "--all"]);
    assert!(r.out.contains("B  old  wsl1/t9  片付けた"), "{}", r.out);
}

#[test]
fn send_read_and_report() {
    let w = world(Sc::default());
    seed_row(&w, "ABC-681", live_row());
    let t = TempDir::new("answer");
    let f = t.write("a.md", "案 A で進めて\n");
    let r = run(&w, &["send", "A", "--file", f.to_str().unwrap()]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        w.fake
            .calls()
            .iter()
            .any(|c| c == &["hc", "send", "--json", "wsl1/t13", "--", "案 A で進めて\n"])
    );
    assert!(r.out.contains("started: true"), "{}", r.out);

    let r = run(&w, &["read", "A", "--lines", "50"]);
    assert_eq!(r.code, OK);
    assert!(has_call(&w, "hc read wsl1/t13 --lines 50 --json"));
    assert!(r.out.contains("Do you trust"), "{}", r.out);

    // report は子の会話から打つ (親は hc get の parent)
    let w = world_with(Sc::default(), |f| f.env("HC_TERMINAL_ID", "t13"));
    let r = run(&w, &["report", "ABC-700: PR を出した"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        w.fake
            .calls()
            .iter()
            .any(|c| c == &["hc", "send", "--json", "t8", "--", "ABC-700: PR を出した"])
    );
}

#[test]
fn send_to_blocked_child_explains() {
    let w = world(Sc::default());
    seed_row(&w, "ABC-681", live_row());
    // send だけ blocked で断る偽物 (子は確認の画面で止まっていると報告している。送る前の守りは通し、hc send が断る)
    let base = Sc {
        child: vec![child_term("blocked", true)],
        ..Sc::default()
    };
    let gets = Rc::new(Cell::new(0));
    let fake = Fake::new(move |argv| {
        if argv.len() > 1 && argv[1] == "send" {
            return fail(9, r#"{"error":{"kind":"blocked","message":"blocked"}}"#);
        }
        respond(&base, &gets, argv)
    })
    .env("HC_TERMINAL_ID", "t8");
    let w2 = World {
        fake,
        brief: w.brief.clone(),
        _t: TempDir::new("b2"),
    };
    seed_row(&w2, "ABC-681", live_row());
    let r = run(&w2, &["send", "A", "続けて"]);
    assert_eq!(r.code, FAILURE);
    assert!(r.err.contains("確認の画面で止まっています"), "{}", r.err);
}

// ---- 送る前の守り: 子の端末で Claude が動いているかを hc get で確かめてから送る

/// `hc send` を打ったか。
fn sent(w: &World) -> bool {
    w.fake
        .calls()
        .iter()
        .any(|c| c.len() > 1 && c[0] == "hc" && c[1] == "send")
}

/// 子の端末を `child` にした世界と、控えの子 A。
fn guard_world(child: Value) -> World {
    let w = world(Sc {
        child: vec![child],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    w
}

#[test]
fn send_guard_sends_while_claude_reports() {
    for state in ["idle", "working", "done"] {
        let w = guard_world(child_term(state, true));
        let r = run(&w, &["send", "A", "続けて"]);
        assert_eq!(r.code, OK, "{state}: {}", r.err);
        assert!(sent(&w), "{state}");
    }
}

#[test]
fn send_guard_refuses_shell_after_claude_ended() {
    let w = guard_world(shell_term());
    // 引用 (`>`) の行はリダイレクトに、kill の行はそのままコマンドになる文
    let r = run(&w, &["send", "A", "> 引用の行\nkill 1234"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(!sent(&w), "{:?}", w.fake.lines());
    for want in [
        "子 A (wsl1/t13) で Claude が動いていないので送らない",
        "前面のプロセスが bash で、状態の報告 (OSC 7501) が無い",
        "pjp child restart A",
        "pjp child read A --lines 0",
        "--no-agent-check",
    ] {
        assert!(r.err.contains(want), "{want}: {}", r.err);
    }
    // 何が見えたかと、どうすればよいかの 2 行
    assert_eq!(r.err.trim_end().lines().count(), 2, "{}", r.err);
}

#[test]
fn send_guard_refuses_when_it_cannot_tell() {
    // 状態の報告が無く、前面のプロセス (foreground) を返さない hc
    let w = guard_world(child_term("", false));
    let r = run(&w, &["send", "A", "続けて"]);
    assert_eq!(r.code, FAILURE, "{}", r.err);
    assert!(!sent(&w));
    assert!(
        r.err
            .contains("子 A (wsl1/t13) で Claude が動いているか確かめられないので送らない"),
        "{}",
        r.err
    );
    assert!(r.err.contains("hc が古い"), "{}", r.err);
    assert!(r.err.contains("pjp child read A --lines 0"), "{}", r.err);

    // 落ちた claude を hc が shell に替えている途中 (foreground が省かれ、pid が null で reason が付く)
    let mut lost = child_term("", false);
    lost["pid"] = Value::Null;
    lost["reason"] = json!("signaled");
    let w = guard_world(lost);
    let r = run(&w, &["send", "A", "続けて"]);
    assert_eq!(r.code, FAILURE);
    assert!(!sent(&w));
    assert!(r.err.contains("reason: signaled"), "{}", r.err);
}

#[test]
fn send_guard_no_agent_check_types_into_shell() {
    let w = guard_world(shell_term());
    let r = run(&w, &["send", "A", "--no-agent-check", "echo hi"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        w.fake
            .calls()
            .iter()
            .any(|c| c == &["hc", "send", "--json", "wsl1/t13", "--", "echo hi"])
    );
}

#[test]
fn send_guard_sends_to_quiet_claude_in_front() {
    // 状態を報告しない claude (立てた直後など) でも、前面のプロセスが claude なら送る
    let mut quiet = child_term("", false);
    quiet["foreground"] =
        json!({"argv": [CLAUDE, "--effort", "max"], "cwd": WT, "name": "claude", "pid": 9});
    let w = guard_world(quiet);
    let r = run(&w, &["send", "A", "続けて"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(sent(&w));
}

#[test]
fn send_guard_refuses_finished_child() {
    let mut done = child_term("", false);
    done["state"] = json!("finished");
    done["exit_code"] = json!(0);
    let w = guard_world(done);
    let r = run(&w, &["send", "A", "続けて"]);
    assert_eq!(r.code, FAILURE);
    assert!(!sent(&w));
    assert!(
        r.err
            .contains("子 A (wsl1/t13) の端末は終わっている (終了コード 0)"),
        "{}",
        r.err
    );
    assert!(r.err.contains("pjp child restart A"), "{}", r.err);
}

#[test]
fn report_guard_checks_the_parent() {
    // 親 (Windows のハブ) の Claude が終わり、hc が pwsh に替えた
    let w = world_with(
        Sc {
            hub_agent: json!({
                "reported": false,
                "status": null,
                "foreground": {"argv": ["C:\\pwsh.exe"], "cwd": "C:\\h", "name": "pwsh.exe", "pid": 2},
            }),
            ..Sc::default()
        },
        |f| f.env("HC_TERMINAL_ID", "t13"),
    );
    let r = run(&w, &["report", "ABC-700: PR を出した"]);
    assert_eq!(r.code, FAILURE, "{}", r.err);
    assert!(!sent(&w));
    assert!(
        r.err
            .contains("親 (t8) で Claude が動いていないので知らせない"),
        "{}",
        r.err
    );
    assert!(r.err.contains("前面のプロセスが pwsh.exe"), "{}", r.err);
    // 抜け道
    let r = run(&w, &["report", "--no-agent-check", "ABC-700: PR を出した"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        w.fake
            .calls()
            .iter()
            .any(|c| c == &["hc", "send", "--json", "t8", "--", "ABC-700: PR を出した"])
    );
}

#[test]
fn ls_marks_child_whose_claude_ended() {
    let w = guard_world(shell_term());
    let r = run(&w, &["ls"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        r.out.contains(
            "A  w22  wsl1/t13  Claude が動いていない (前面 bash)  チケット ABC-700  pollenjp/claude-skills"
        ),
        "{}",
        r.out
    );
}

// ---- cleanup

fn cleanup_world(sc: Sc) -> World {
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..sc
    });
    seed_row(&w, "ABC-681", live_row());
    w
}

#[test]
fn cleanup_full_sequence() {
    let w = cleanup_world(Sc {
        d_fails: true,
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let lines = w.fake.lines();
    let order = [
        &format!("git -C {WT} status --short") as &str,
        "gh pr list --repo pollenjp/claude-skills --head feat/ABC-691-x",
        "hc exec --json --on wsl1 --timeout 60 -- hc ls --json",
        "hc kill wsl1/t13",
        "hc wait wsl1/t13",
        "hc rm wsl1/t13",
        "herdr-app do space.close",
        &format!("git -C {CK} worktree remove {WT}"),
        &format!("git -C {CK} branch -d feat/ABC-691-x"),
        &format!("git -C {CK} branch -D feat/ABC-691-x"),
        &format!("git -C {CK} branch -d worktree/w22"),
    ];
    let mut at = 0;
    for want in order {
        let found = lines[at..].iter().position(|l| l.contains(want));
        assert!(
            found.is_some(),
            "{want} が {at} 行目より後に無い:\n{}",
            lines.join("\n")
        );
        at += found.unwrap() + 1;
    }
    // /exit は送らない
    assert!(
        !w.fake.calls().iter().any(|c| c.len() > 1 && c[1] == "send"),
        "{lines:?}"
    );
    let close = w
        .fake
        .calls()
        .into_iter()
        .find(|c| c[0] == "herdr-app")
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&close[3]).unwrap(),
        json!({"id": "wsl1/sp1", "confirmed": true})
    );
    assert!(r.out.contains("PR が merge 済み (squash)"), "{}", r.out);
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::CLEANED);
    // herdr-app のあるハブ (Windows) は space.close で閉じ、hc の doc に触らない
    assert!(rpc_calls(&w.fake).is_empty(), "{lines:?}");
    // 打ち直しても何もしない
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK);
    assert!(r.out.contains("もう片付けてある"), "{}", r.out);
}

fn assert_refused(w: &World, r: &Out, why: &str) {
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(r.out.contains(why), "{why}: {}", r.out);
    for mutating in [
        "hc kill",
        "hc rm",
        "space.close",
        "worktree remove",
        "branch -d",
        "branch -D",
    ] {
        assert!(!has_call(w, mutating), "{mutating}: {:?}", w.fake.lines());
    }
    assert_eq!(ledger_rows(w, "ABC-681")[0].state, state::LIVE);
}

#[test]
fn cleanup_refuses_open_pr() {
    let w = cleanup_world(Sc {
        gh: r#"[{"number":13,"state":"OPEN","url":"u"}]"#.to_owned(),
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "PR #13 u がまだ open");
}

#[test]
fn cleanup_refuses_dirty_worktree() {
    let w = cleanup_world(Sc {
        status_short: " M SKILL.md\n?? x.txt\n".to_owned(),
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "commit していない変更がある");
    assert!(r.out.contains("?? x.txt"), "{}", r.out);
}

#[test]
fn cleanup_refuses_grandchildren() {
    let w = cleanup_world(Sc {
        grandkids: json!({"terminals": [{"address": "t20", "name": "grand", "parent": "t13", "state": "live"}]}),
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "子に生きている子 (孫) がいる: t20 (grand)");
}

#[test]
fn cleanup_refuses_when_grandchildren_cannot_be_checked() {
    // 子のマシンの hc ls が落ちたら片付けず、--force なら進む (孫の探し方を restart と分け合っても同じ)
    let w = cleanup_world(Sc {
        ls_fail: LsFail::InExec,
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "孫がいないかを確かめられない");
    let r = run(&w, &["cleanup", "A", "--force"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, "hc kill wsl1/t13"));
}

#[test]
fn cleanup_refuses_working() {
    let w = world(Sc::default()); // 子は working
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "まだ working");
}

#[test]
fn cleanup_no_pr_needs_flag() {
    // 作業の branch を切っていない (worktree/w22 のまま)
    let w = cleanup_world(Sc {
        branch_now: "worktree/w22".to_owned(),
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "PR の無い子なら --no-pr");
    let r = run(&w, &["cleanup", "A", "--no-pr"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!has_call(&w, "gh pr list"));
    assert!(has_call(&w, "hc kill wsl1/t13"));
}

/// `--dir` で立てた子 (控えに repo・worktree・branch が無い)。
fn dir_row() -> Row {
    Row {
        repo: String::new(),
        checkout: String::new(),
        worktree: "/home/u/.herdr/worktrees/repo-x/x".into(),
        branch: String::new(),
        base: String::new(),
        ..live_row()
    }
}

#[test]
fn cleanup_dir_child_checks_pr_with_repo_flag() {
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", dir_row());
    let r = run(&w, &["cleanup", "A", "--branch", "fix/ABC-9-x"]);
    assert_refused(&w, &r, "--repo <owner/repo> で渡す");
    let r = run(
        &w,
        &[
            "cleanup",
            "A",
            "--branch",
            "fix/ABC-9-x",
            "--repo",
            "example-org/repo-x",
        ],
    );
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(has_call(
        &w,
        "gh pr list --repo example-org/repo-x --head fix/ABC-9-x"
    ));
    // worktree は pjp child new が作ったものではないので消さない
    assert!(!has_call(&w, "worktree remove"));
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::CLEANED);
}

#[test]
fn cleanup_refuses_repo_flag_differing_from_ledger() {
    let w = cleanup_world(Sc::default());
    let r = run(&w, &["cleanup", "A", "--repo", "pollenjp/other"]);
    assert_eq!(r.code, CONFIG, "{}\n{}", r.out, r.err);
    assert!(
        r.err
            .contains("控えの repo (pollenjp/claude-skills) と違います"),
        "{}",
        r.err
    );
    assert!(!has_call(&w, "hc kill"));
}

#[test]
fn cleanup_dry_run() {
    let w = cleanup_world(Sc::default());
    let r = run(&w, &["cleanup", "A", "--dry-run"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        r.out
            .contains("hc kill wsl1/t13 → hc wait wsl1/t13 → hc rm wsl1/t13"),
        "{}",
        r.out
    );
    assert!(!has_call(&w, "hc kill"));
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::LIVE);
}

/// herdr-app の無いハブで片付ける子 A の世界。wsl1 の doc に、子の space (`child`) とほかの会話の space。
fn no_app_cleanup_world(sc: Sc, child: Value, doc: DocSim) -> (World, Rc<RefCell<DocSim>>) {
    let doc = DocSim {
        value: json!({"spaces": [other_space(), child]}),
        version: 50,
        ..doc
    };
    let (w, doc) = no_app_world(
        Sc {
            child: vec![child_term("idle", true)],
            ..sc
        },
        doc.on("wsl1"),
    );
    seed_row(&w, "ABC-681", live_row());
    (w, doc)
}

#[test]
fn cleanup_without_herdr_app_leaves_the_space_to_herdr_app() {
    // 子の端末を消すと、herdr-app が doc.get 1 回の後に space を消す (E10)
    let (w, doc) = no_app_cleanup_world(
        Sc::default(),
        child_space("A claude-skills: W2-2", &["t13"]),
        DocSim::default().running(1),
    );
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!called_herdr_app(&w), "{:?}", w.fake.lines());
    // 子を終える前に 1 回 (子のほかの端末がいないか)、終えた後に消えるのを待って読む
    let rm = call_at(&w, "hc rm wsl1/t13");
    assert!(call_at(&w, "hc connect") < call_at(&w, "hc kill wsl1/t13"));
    let after = first_rpc_after(&w, rm);
    assert!(
        after
            < call_at(
                &w,
                &format!("hc exec --json --on wsl1 --timeout 120 -- git -C {CK} worktree remove")
            )
    );
    assert_eq!(doc.borrow().space_ids(), ["sphub"]);
    assert!(!rpc_methods(&w.fake).contains(&"doc.set".to_owned()));
    assert!(
        r.out
            .contains("space wsl1/sp1 は wsl1 の hc の doc herdr-app に無い (herdr-app が消した)"),
        "{}",
        r.out
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::CLEANED);
}

#[test]
fn cleanup_without_herdr_app_removes_the_space_herdr_app_left() {
    // herdr-app が動いていない。待っても消えないので、中に生きた端末の無い space を doc から消す
    let (w, doc) = no_app_cleanup_world(
        Sc::default(),
        child_space("A claude-skills: W2-2", &["t13"]),
        DocSim::default(),
    );
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let d = doc.borrow();
    assert_eq!(d.space_ids(), ["sphub"]);
    assert_eq!(d.space("sphub").unwrap(), &other_space());
    assert!(
        r.out.contains(
            "herdr-app が space wsl1/sp1 を消さなかった (動いていない・遅い) ので、wsl1 の hc の doc herdr-app から消した (版 50 → 51)"
        ),
        "{}",
        r.out
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::CLEANED);
}

#[test]
fn cleanup_without_herdr_app_stops_while_another_terminal_is_in_the_space() {
    // ユーザーが子の space に開いた shell (wsl1/t29。親なし) が生きている。子を終える前に止まる (片付けると、その shell が
    // 消えた worktree に残る。space.close は使えず、自分が立てていない端末は終わらせない)
    let sc = Sc {
        grandkids: json!({"terminals": [{"address": "t29", "parent": null, "state": "live",
            "labels": {"herdr.space": "sp1", "herdr.tab": "tb1"}}]}),
        ..Sc::default()
    };
    let (w, doc) = no_app_cleanup_world(
        sc,
        child_space("A claude-skills: W2-2", &["t13", "t29"]),
        DocSim::default(),
    );
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(
        &w,
        &r,
        "子の space wsl1/sp1 に、子のほかの端末 (wsl1/t29) がいる。herdr-app の画面で閉じてから片付ける (閉じずに進めるなら --force。その端末と space は残し、worktree は消す)",
    );
    assert!(has_call(&w, "hc get wsl1/t29 --json"));
    assert!(!rpc_methods(&w.fake).contains(&"doc.set".to_owned()));

    // --force: 子を片付け、shell と space は残す
    let r = run(&w, &["cleanup", "A", "--force"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, "hc kill wsl1/t13"));
    assert!(!has_call(&w, "hc kill wsl1/t29"), "{:?}", w.fake.lines());
    assert!(doc.borrow().space("sp1").is_some());
    assert!(!rpc_methods(&w.fake).contains(&"doc.set".to_owned()));
    assert!(
        r.err.contains(
            "!! space wsl1/sp1 に、子のほかの端末 (wsl1/t29) が残っているので閉じない (要らなければ herdr-app の画面で閉じる。space.close は中の端末も終わらせる)"
        ),
        "{}",
        r.err
    );
    assert!(has_call(&w, &format!("git -C {CK} worktree remove {WT}")));
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::CLEANED);
}

#[test]
fn cleanup_without_herdr_app_counts_terminals_it_cannot_check() {
    // 子の space の端末 (wsl1/t29) を hc get で確かめられない (つながらない)。生きているとみて止まり、そう書く
    let (w, _) = no_app_cleanup_world(
        Sc {
            grandkids: json!({"terminals": [{"address": "t29", "parent": null, "state": "live"}]}),
            grand_get_fails: true,
            ..Sc::default()
        },
        child_space("A claude-skills: W2-2", &["t13", "t29"]),
        DocSim::default(),
    );
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "子のほかの端末 (wsl1/t29 (確かめられない)) がいる");
}

#[test]
fn cleanup_dry_run_without_herdr_app() {
    let (w, _) = no_app_cleanup_world(
        Sc::default(),
        child_space("A claude-skills: W2-2", &["t13"]),
        DocSim::default(),
    );
    let r = run(&w, &["cleanup", "A", "--dry-run"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(
        r.out.contains(
            "wsl1 の hc の doc herdr-app から space wsl1/sp1 が消えるのを待つ (子の端末を消すと herdr-app が消す)。残っていて、中にほかの生きた端末が無ければ doc から消す"
        ),
        "{}",
        r.out
    );
    assert!(!r.out.contains("space.close"), "{}", r.out);
    // 読むのは確かめ (子の space に子のほかの端末がいないか) だけで、書かない
    assert_eq!(rpc_methods(&w.fake), ["doc.get"]);
}

#[test]
fn unknown_letter_and_subcommand() {
    let w = world(Sc::default());
    let r = run(&w, &["read", "Q"]);
    assert_eq!(r.code, FAILURE);
    assert!(r.err.contains("子 Q は控えにありません"), "{}", r.err);
    assert_eq!(run(&w, &["nope"]).code, CONFIG);
    assert_eq!(run(&w, &[]).code, CONFIG);
    let r = run(&w, &["--help"]);
    assert_eq!(r.code, OK);
    assert!(r.out.contains("pjp child new"), "{}", r.out);
}

#[test]
fn remote_paths() {
    assert_eq!(remote_path("~", HOME).unwrap(), HOME);
    assert_eq!(remote_path("~/h", HOME).unwrap(), "/home/u/h");
    assert_eq!(remote_path("/srv/x", HOME).unwrap(), "/srv/x");
    for bad in ["h", r"C:\x", "C:/x", r"\\wsl.localhost\x"] {
        assert!(remote_path(bad, HOME).is_err(), "{bad}");
    }
    assert_eq!(short_remote("/home/u/.herdr/x", "/home/u/"), "~/.herdr/x");
    assert_eq!(short_remote("/home/uu/x", "/home/u"), "/home/uu/x");
}

// ---- レビューの指摘の場面

/// pack の木 (ハブの skill の置き場) に diagram の pack を置く。
fn diagram_pack(w: &World) {
    let skills = w.fake.base().join("skills");
    std::fs::create_dir_all(skills.join("pjp-pack-diagram")).unwrap();
    std::fs::write(
        skills.join("pjp-pack-diagram").join("SKILL.md"),
        "---\nname: pjp-pack-diagram\ndescription: x\n---\n\n## pjp-a\n",
    )
    .unwrap();
    std::fs::create_dir_all(skills.join("pjp-a")).unwrap();
    std::fs::write(
        skills.join("pjp-a").join("SKILL.md"),
        "---\nname: pjp-a\ndescription: x\nmetadata:\n  pjp-pack: diagram\n---\n",
    )
    .unwrap();
}

#[test]
fn new_records_effort_packs_and_chrome() {
    let w = world(Sc::default());
    diagram_pack(&w);
    let r = run(
        &w,
        &new_args(&w, &["--effort", "high", "--pack", "diagram", "--chrome"]),
    );
    assert_eq!(r.code, OK, "{}", r.err);
    let row = &ledger_rows(&w, "ABC-681")[0];
    assert_eq!(
        (row.effort.as_str(), row.packs.as_str(), row.chrome.as_str()),
        ("high", "diagram", "1")
    );
}

#[test]
fn new_and_restart_accept_every_effort_level() {
    // 道具は Claude Code の受ける 5 つを全部受ける (low・xhigh はユーザーが名指ししたとき用)
    for effort in ["low", "medium", "high", "xhigh", "max"] {
        let w = world(Sc::default());
        let r = run(&w, &new_args(&w, &["--effort", effort]));
        assert_eq!(r.code, OK, "{effort}: {}", r.err);
        assert_eq!(value_after(&run_call(&w), "--effort"), Some(effort));
        assert_eq!(ledger_rows(&w, "ABC-681")[0].effort, effort);

        let w = world(Sc {
            child: vec![child_term("idle", true)],
            ..Sc::default()
        });
        seed_row(&w, "ABC-681", live_row());
        let r = run(&w, &["restart", "A", "--effort", effort]);
        assert_eq!(r.code, OK, "{effort}: {}\n{}", r.out, r.err);
        assert_eq!(value_after(&run_call(&w), "--effort"), Some(effort));
    }
    // 受けない値は断る
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A", "--effort", "ultra"]);
    assert_eq!(r.code, CONFIG, "{}", r.err);
    assert!(r.err.contains("low・medium・high・xhigh・max"), "{}", r.err);
}

#[test]
fn restart_inherits_effort_packs_and_chrome() {
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    });
    diagram_pack(&w);
    seed_row(
        &w,
        "ABC-681",
        Row {
            effort: "max".into(),
            packs: "diagram".into(),
            chrome: "1".into(),
            ..live_row()
        },
    );
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let call = run_call(&w);
    assert_eq!(value_after(&call, "--effort"), Some("max"));
    assert!(call.contains(&"--chrome".to_owned()));
    assert_eq!(
        value_after(&call, "--settings"),
        Some(r#"{"skillOverrides":{"pjp-a":"on"}}"#)
    );
    // 渡したものが先 (effort を上げ、chrome を外す)
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    });
    seed_row(
        &w,
        "ABC-681",
        Row {
            effort: "medium".into(),
            chrome: "1".into(),
            ..live_row()
        },
    );
    assert_eq!(
        run(&w, &["restart", "A", "--effort", "max", "--no-chrome"]).code,
        OK
    );
    let call = run_call(&w);
    assert_eq!(value_after(&call, "--effort"), Some("max"));
    assert!(call.contains(&"--no-chrome".to_owned()));
    let row = &ledger_rows(&w, "ABC-681")[0];
    assert_eq!((row.effort.as_str(), row.chrome.as_str()), ("max", ""));
}

#[test]
fn new_and_restart_default_to_high_effort() {
    // --effort を渡さない new は既定の high で立てて控えに残す
    let w = world(Sc::default());
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}", r.err);
    assert_eq!(value_after(&run_call(&w), "--effort"), Some("high"));
    assert_eq!(ledger_rows(&w, "ABC-681")[0].effort, "high");
    // 控えに前の値が無い restart も既定の high
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--effort"), Some("high"));
}

#[test]
fn restart_refuses_failed_row() {
    let w = world(Sc::default());
    seed_row(
        &w,
        "ABC-681",
        Row {
            state: state::FAILED.into(),
            ..live_row()
        },
    );
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE);
    assert!(r.err.contains("立てられなかった子"), "{}", r.err);
    assert!(!has_call(&w, "hc run"));
    assert!(!has_call(&w, "hc kill"));
}

#[test]
fn cleanup_failed_row_only_marks_ledger() {
    let w = world(Sc::default());
    seed_row(
        &w,
        "ABC-681",
        Row {
            state: state::FAILED.into(),
            ..live_row()
        },
    );
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}", r.err);
    assert!(r.out.contains("控えだけを片付けた"), "{}", r.out);
    for touched in [
        "hc kill",
        "hc rm",
        "herdr-app",
        "worktree remove",
        "branch -",
        "gh pr",
    ] {
        assert!(!has_call(&w, touched), "{touched}: {:?}", w.fake.lines());
    }
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::CLEANED);
}

#[test]
fn cleanup_detached_head_uses_reflog_branch() {
    let w = cleanup_world(Sc {
        branch_now: String::new(),
        reflog: "checkout: moving from feat/ABC-691-x to origin/main\ncommit: done\n".to_owned(),
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        r.out.contains("reflog の直前の branch feat/ABC-691-x"),
        "{}",
        r.out
    );
    assert!(has_call(
        &w,
        "gh pr list --repo pollenjp/claude-skills --head feat/ABC-691-x"
    ));
    assert!(has_call(
        &w,
        &format!("git -C {CK} branch -d feat/ABC-691-x")
    ));
    // reflog でも分からなければ止まり、--branch で渡せる
    let w = cleanup_world(Sc {
        branch_now: String::new(),
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "--branch <作業の branch>");
    let r = run(&w, &["cleanup", "A", "--branch", "feat/ABC-691-x"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
}

#[test]
fn cleanup_keeps_branch_with_commits_after_merge() {
    // PR の head (abc) より先の commit (def) が local の branch にある
    let w = cleanup_world(Sc {
        d_fails: true,
        tip: "def".to_owned(),
        ancestor_ok: false,
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        !has_call(&w, "branch -D feat/ABC-691-x"),
        "{:?}",
        w.fake.lines()
    );
    assert!(
        r.out.contains("branch feat/ABC-691-x は消さない"),
        "{}",
        r.out
    );
}

#[test]
fn cleanup_ignores_fork_prs() {
    let w = cleanup_world(Sc {
        gh: r#"[{"number":9,"state":"MERGED","url":"u","headRefOid":"abc","isCrossRepository":true}]"#.to_owned(),
        ..Sc::default()
    });
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(&w, &r, "PR がありません");
}

#[test]
fn cleanup_does_not_count_itself_or_siblings_as_grandchildren() {
    // 子の住所 (t8) が、ハブの端末の住所 (e5/t8) の後ろと同じでも、孫に数えない
    let w = world(Sc {
        child: vec![child_term("idle", true)],
        grandkids: json!({"terminals": [
            {"address": "t8", "name": "w22", "parent": "e5/t8", "state": "live"},
            {"address": "t9", "name": "sib", "parent": "e5/t8", "state": "live"},
        ]}),
        ..Sc::default()
    });
    seed_row(
        &w,
        "ABC-681",
        Row {
            terminal: "wsl1/t8".into(),
            ..live_row()
        },
    );
    // 子の端末の hc get が t13 の名前を返すと「別の端末」になるので、この場面では端末を見ない
    let r = run(&w, &["cleanup", "A", "--dry-run"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!r.out.contains("孫"), "{}", r.out);
}

#[test]
fn cleanup_and_send_skip_reassigned_terminal() {
    // 控えの住所に、別の名前の端末がいる (core を立て直して住所が振り直された)
    let other = json!({"address": "wsl1/t13", "name": "someone", "state": "live", "status": {"state": "idle"}, "labels": {}});
    let w = world(Sc {
        child: vec![other],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["send", "A", "hello"]);
    assert_eq!(r.code, FAILURE);
    assert!(r.err.contains("別の端末になっている"), "{}", r.err);
    assert!(!has_call(&w, "hc send"));
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!has_call(&w, "hc kill"), "{:?}", w.fake.lines());
    assert!(r.err.contains("その端末は終えない"), "{}", r.err);
}

#[test]
fn new_does_not_roll_back_when_child_is_live() {
    // hc run は時間切れで落ちたように見えたが、子は立っていた
    let base = Sc {
        run_fail: true,
        ..Sc::default()
    };
    let gets = Rc::new(Cell::new(0));
    let lists = Rc::new(Cell::new(0));
    let (g, l) = (Rc::clone(&gets), Rc::clone(&lists));
    let fake = Fake::new(move |argv| {
        if argv.len() > 1 && argv[0] == "hc" && argv[1] == "ls" {
            let n = l.get();
            l.set(n + 1);
            if n > 0 {
                return ok(r#"{"terminals":[{"address":"wsl1/t13","name":"w22","state":"live"}]}"#);
            }
        }
        respond(&base, &g, argv)
    })
    .env("HC_TERMINAL_ID", "t8");
    let t = TempDir::new("brief-live");
    let brief = t.write("brief.md", "依頼\n");
    let w = World { fake, brief, _t: t };
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        r.err.contains("端末 wsl1/t13 (w22) が立っている"),
        "{}",
        r.err
    );
    assert!(!has_call(&w, "worktree remove --force"));
    let row = &ledger_rows(&w, "ABC-681")[0];
    assert_eq!(
        (row.state.as_str(), row.terminal.as_str()),
        (state::LIVE, "wsl1/t13")
    );
}

#[test]
fn new_does_not_roll_back_when_child_shows_up_late() {
    // hc run が落ちた (host-a の hc は「registry persistence timed out; the operation may already have completed」を返すことが
    // あり、そのときも端末は立っていた)。子は立っていたが、一覧に出るのが遅れた (落ちた直後の探しでは見えず、2 回目で見えた)
    let base = Sc {
        run_fail: true,
        grandkids: json!({"terminals": []}),
        ..Sc::default()
    };
    let gets = Rc::new(Cell::new(0));
    let lists = Rc::new(Cell::new(0));
    let (g, l) = (Rc::clone(&gets), Rc::clone(&lists));
    let fake = Fake::new(move |argv| {
        if argv.len() > 1 && argv[0] == "hc" && argv[1] == "ls" {
            let n = l.get();
            l.set(n + 1);
            // 1 回目は名前の重なりの確かめ、2 回目は落ちた直後の探し
            if n >= 2 {
                return ok(r#"{"terminals":[{"address":"wsl1/t13","name":"w22","state":"live"}]}"#);
            }
        }
        respond(&base, &g, argv)
    })
    .env("HC_TERMINAL_ID", "t8");
    let t = TempDir::new("brief-late");
    let brief = t.write("brief.md", "依頼\n");
    let w = World { fake, brief, _t: t };
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        r.err.contains("端末 wsl1/t13 (w22) が立っている"),
        "{}",
        r.err
    );
    assert!(!has_call(&w, "worktree remove --force"));
    // 探し直す前に待つ
    assert!(
        w.fake.slept().contains(&std::time::Duration::from_secs(2)),
        "{:?}",
        w.fake.slept()
    );
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::LIVE);
}

#[test]
fn new_stops_looking_for_the_child_after_a_while() {
    // hc が詰まっていて一覧が遅い (1 回に 35 秒かかる)。落ちてから 30 秒を過ぎたら探し直さない (待ちを重ねない)
    let base = Sc {
        run_fail: true,
        grandkids: json!({"terminals": []}),
        ..Sc::default()
    };
    let clock = Rc::new(Cell::new(0_i64));
    let c = Rc::clone(&clock);
    let gets = Rc::new(Cell::new(0));
    let g = Rc::clone(&gets);
    let fake = Fake::new(move |argv| {
        if argv.len() > 1 && argv[0] == "hc" && argv[1] == "ls" {
            c.set(c.get() + 35);
        }
        respond(&base, &g, argv)
    })
    .env("HC_TERMINAL_ID", "t8")
    .clock(clock);
    let t = TempDir::new("brief-slow");
    let brief = t.write("brief.md", "依頼\n");
    let w = World { fake, brief, _t: t };
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    // 名前の重なりの確かめで 1 回、落ちた後の探しで 1 回 (探し直さない)
    let lists = w
        .fake
        .lines()
        .iter()
        .filter(|l| l.starts_with("hc ls"))
        .count();
    assert_eq!(lists, 2, "{:?}", w.fake.lines());
    assert!(
        !w.fake.slept().contains(&std::time::Duration::from_secs(2)),
        "{:?}",
        w.fake.slept()
    );
    assert!(r.err.contains("戻した: worktree"), "{}", r.err);
}

#[test]
fn new_brief_starting_with_dash_gets_newline() {
    let w = world(Sc::default());
    std::fs::write(&w.brief, "---\ntitle: x\n---\n- item\n").unwrap();
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    assert_eq!(
        run_call(&w).last().unwrap(),
        "\n---\ntitle: x\n---\n- item\n"
    );
}

#[test]
fn new_rejects_dash_base() {
    let w = world(Sc::default());
    let r = run(&w, &new_args(&w, &["--base", "--upload-pack=x"]));
    assert_eq!(r.code, CONFIG, "{}", r.err);
}

#[test]
fn new_and_restart_never_pass_parent_and_check_it() {
    // 呼び手 (ハブ。HC_TERMINAL_ID=t8) と --on のマシン (wsl1) が違う。--parent t8 を渡すと wsl1 の t8 が親になる
    let w = world(Sc::default());
    assert_eq!(run(&w, &new_args(&w, &[])).code, OK);
    assert!(
        !run_call(&w).contains(&"--parent".to_owned()),
        "{:?}",
        run_call(&w)
    );

    // 子の親が wsl1/t8 (子のマシンの別の端末) になっていたら !! を出して失敗にする
    let mut wrong = child_term("working", true);
    wrong["parent"] = json!("wsl1/t8");
    let w = world(Sc {
        child: vec![wrong.clone()],
        ..Sc::default()
    });
    let r = run(&w, &new_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}", r.out);
    assert!(
        r.out
            .contains("!! 子の hc の親が wsl1/t8 で、この会話の端末 t8 ではない"),
        "{}",
        r.out
    );

    // restart も同じ
    let mut idle = child_term("idle", true);
    idle["parent"] = json!("wsl1/t8");
    let w = world(Sc {
        child: vec![idle],
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}", r.out);
    assert!(!run_call(&w).contains(&"--parent".to_owned()));
    assert!(r.out.contains("この会話の端末 t8 ではない"), "{}", r.out);
}

#[test]
fn parent_forms() {
    use super::new::parent_is;
    assert!(parent_is(Some("t8"), "t8", Some("wsl1")));
    // 別のマシンの core から見た住所 (core の id/t8) は合う
    assert!(parent_is(Some("0123abcd/t8"), "t8", Some("wsl1")));
    // 子のマシンの中の同じ住所は別の端末
    assert!(!parent_is(Some("wsl1/t8"), "t8", Some("wsl1")));
    assert!(!parent_is(Some("t9"), "t8", Some("wsl1")));
    assert!(!parent_is(None, "t8", None));
    assert!(parent_is(Some("t8"), "t8", None));
}

// ---- 解説動画の印 (cleanup・restart。spec 2026-11-21-spaces-video-mark-design.md の §7.5)

const MADE: &str = r#"{"name":"ABC-700 短尺 x","state":"done","started":"2026-11-16T09:00:00+09:00","ended":"2026-11-16T09:30:00+09:00"}"#;
const MAKING: &str =
    r#"{"name":"ABC-700 詳細版 x","state":"making","started":"2026-11-16T09:40:00+09:00"}"#;
const MADE_KEY: &str = "pjp.video.20261116090000";
const MAKING_KEY: &str = "pjp.video.20261116094000";

/// 動画の印を足した子の端末。
fn with_videos(mut t: Value, videos: &[(&str, &str)]) -> Value {
    for (k, v) in videos {
        t["labels"][*k] = json!(v);
    }
    t
}

/// 控えの子 A (wsl1/t13) が `child` の世界。
fn video_world(child: Value, hub_labels: Option<Value>) -> World {
    let mut sc = Sc {
        child: vec![child],
        ..Sc::default()
    };
    if let Some(l) = hub_labels {
        sc.hub_labels = l;
    }
    let w = world(sc);
    seed_row(&w, "ABC-681", live_row());
    w
}

fn idle_child(videos: &[(&str, &str)]) -> Value {
    with_videos(child_term("idle", true), videos)
}

/// `hc label <addr> …` の行。
fn label_lines(w: &World, addr: &str) -> Vec<String> {
    let head = format!("hc label {addr} ");
    w.fake
        .lines()
        .into_iter()
        .filter(|l| l.starts_with(&head))
        .collect()
}

#[test]
fn cleanup_moves_unwatched_videos_to_this_terminal() {
    let w = video_world(idle_child(&[(MADE_KEY, MADE)]), None);
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let moved = format!(
        "hc label t8 {MADE_KEY}={} --json",
        r#"{"name":"ABC-700 短尺 x","state":"done","started":"2026-11-16T09:00:00+09:00","ended":"2026-11-16T09:30:00+09:00","from":"子 A (wsl1/t13)"}"#
    );
    assert_eq!(label_lines(&w, "t8"), std::slice::from_ref(&moved));
    // 子の端末を終える前に移す (移せなければ、何も片付けずに止まる)
    assert!(call_at(&w, &moved) < call_at(&w, "hc kill wsl1/t13"));
    assert!(
        r.out
            .contains("見ていない解説動画の印 1 本を t8 へ移した (🎬✅:ABC-700 短尺 x)"),
        "{}",
        r.out
    );
}

#[test]
fn cleanup_moved_video_avoids_a_taken_key() {
    let hub = json!({"pjp.ticket": "ABC-681", "pjp.role": "hub", "herdr.space": "sphub",
        MADE_KEY: r#"{"name":"ABC-681 短尺 別","state":"done","started":"2026-11-16T09:00:00+09:00"}"#});
    let w = video_world(idle_child(&[(MADE_KEY, MADE)]), Some(hub));
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let lines = label_lines(&w, "t8");
    assert_eq!(lines.len(), 1);
    assert!(
        lines[0].starts_with(&format!("hc label t8 {MADE_KEY}-2=")),
        "{lines:?}"
    );
}

#[test]
fn cleanup_refuses_while_child_makes_video() {
    let w = video_world(idle_child(&[(MADE_KEY, MADE), (MAKING_KEY, MAKING)]), None);
    let r = run(&w, &["cleanup", "A"]);
    assert_refused(
        &w,
        &r,
        "子 A は解説動画を作っている (🎬⏳:ABC-700 詳細版 x)",
    );
    assert!(r.out.contains("pjp mark video stop"), "{}", r.out);
    assert!(!has_call(&w, "hc label"));
}

#[test]
fn cleanup_force_drops_making_video_and_moves_unwatched() {
    let w = video_world(idle_child(&[(MADE_KEY, MADE), (MAKING_KEY, MAKING)]), None);
    let r = run(&w, &["cleanup", "A", "--force"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let lines = label_lines(&w, "t8");
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].contains(MADE_KEY), "{lines:?}");
    assert!(!lines[0].contains("詳細版"), "{lines:?}");
    assert!(
        r.err
            .contains("作りかけの解説動画の印 (🎬⏳:ABC-700 詳細版 x) は移さない"),
        "{}",
        r.err
    );
}

#[test]
fn cleanup_does_not_wait_for_a_making_video_of_an_ended_claude() {
    // 子の Claude が終わって shell に替わっている (作るのはもう止まっている): 止める理由にせず、印は移さない
    let w = video_world(
        with_videos(shell_term(), &[(MADE_KEY, MADE), (MAKING_KEY, MAKING)]),
        None,
    );
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(label_lines(&w, "t8").len(), 1);
    assert!(r.err.contains("は移さない"), "{}", r.err);
}

#[test]
fn cleanup_dry_run_lists_video_moves() {
    let w = video_world(idle_child(&[(MADE_KEY, MADE)]), None);
    let r = run(&w, &["cleanup", "A", "--dry-run"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        r.out.contains(&format!("  hc label t8 {MADE_KEY}=")),
        "{}",
        r.out
    );
    assert!(
        r.out.contains("見ていない解説動画の印 1 本を移す"),
        "{}",
        r.out
    );
    assert!(!has_call(&w, "hc label"));
    assert!(!has_call(&w, "hc kill"));
}

#[test]
fn cleanup_without_a_place_for_unwatched_videos_refuses_unless_forced() {
    // hc の端末の外で --ticket を付けて打ち、子の hc の親 (t99) も hc にいない
    let mut child = idle_child(&[(MADE_KEY, MADE)]);
    child["parent"] = json!("t99");
    let w = world_with(
        Sc {
            child: vec![child],
            ..Sc::default()
        },
        |f| f.env("HC_TERMINAL_ID", ""),
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["cleanup", "A", "--ticket", "ABC-681"]);
    assert_refused(&w, &r, "を移す先が無い");
    let r = run(&w, &["cleanup", "A", "--ticket", "ABC-681", "--force"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(!has_call(&w, "hc label"));
    assert!(r.err.contains("子と一緒に消える"), "{}", r.err);
}

#[test]
fn cleanup_moves_to_the_child_parent_outside_hc_terminal() {
    let w = world_with(
        Sc {
            child: vec![idle_child(&[(MADE_KEY, MADE)])],
            ..Sc::default()
        },
        |f| f.env("HC_TERMINAL_ID", ""),
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["cleanup", "A", "--ticket", "ABC-681"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(label_lines(&w, "t8").len(), 1);
}

#[test]
fn restart_carries_unwatched_videos() {
    let w = video_world(idle_child(&[(MADE_KEY, MADE)]), None);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let call = run_call(&w);
    let pair = format!("{MADE_KEY}={MADE}");
    assert!(
        call.windows(2).any(|p| p[0] == "--label" && p[1] == pair),
        "{call:?}"
    );
    assert!(
        r.out
            .contains("見ていない解説動画の印 1 本を新しい端末へ引き継いだ"),
        "{}",
        r.out
    );
    // --fresh でも引き継ぐ (印はユーザーのためのもので、会話の文脈ではない)
    let w = video_world(idle_child(&[(MADE_KEY, MADE)]), None);
    let brief = w.brief.to_str().unwrap();
    let r = run(&w, &["restart", "A", "--fresh", "--brief", brief]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(run_call(&w).contains(&pair));
}

#[test]
fn restart_refuses_while_making_video() {
    let w = video_world(idle_child(&[(MADE_KEY, MADE), (MAKING_KEY, MAKING)]), None);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err
            .contains("子 A (wsl1/t13) は解説動画を作っている (🎬⏳:ABC-700 詳細版 x)"),
        "{}",
        r.err
    );
    assert!(!has_call(&w, "hc kill"));
    assert!(!has_call(&w, "hc run"));
    let r = run(&w, &["restart", "A", "--force"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let call = run_call(&w);
    assert!(call.contains(&format!("{MADE_KEY}={MADE}")), "{call:?}");
    assert!(!call.iter().any(|a| a.contains("詳細版")), "{call:?}");
    assert!(
        r.err
            .contains("作りかけの解説動画の印 (🎬⏳:ABC-700 詳細版 x) は引き継がない"),
        "{}",
        r.err
    );
}

#[test]
fn restart_does_not_wait_for_a_making_video_of_an_ended_claude() {
    let w = video_world(with_videos(shell_term(), &[(MAKING_KEY, MAKING)]), None);
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(r.err.contains("は引き継がない"), "{}", r.err);
}

#[test]
fn cleanup_does_not_end_the_child_when_moving_marks_fails() {
    let w = world(Sc {
        child: vec![idle_child(&[(MADE_KEY, MADE)])],
        label_fails: true,
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, "hc label t8"));
    for mutating in ["hc kill", "hc rm", "space.close", "worktree remove"] {
        assert!(!has_call(&w, mutating), "{mutating}: {:?}", w.fake.lines());
    }
    assert_eq!(ledger_rows(&w, "ABC-681")[0].state, state::LIVE);
}

#[test]
fn cleanup_again_does_not_copy_marks_twice() {
    // 前の片付けで移した後に子を終えられなかった: 移す先に同じ動画 (名前と作り始めた日時が同じ ✅) があれば重ねない
    let hub = json!({"pjp.ticket": "ABC-681", "pjp.role": "hub", "herdr.space": "sphub",
        "pjp.video.20261116090000": r#"{"name":"ABC-700 短尺 x","state":"done","started":"2026-11-16T09:00:00+09:00","ended":"2026-11-16T09:30:00+09:00","from":"子 A (wsl1/t13)"}"#});
    let w = video_world(idle_child(&[(MADE_KEY, MADE)]), Some(hub));
    let r = run(&w, &["cleanup", "A"]);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(label_lines(&w, "t8").is_empty(), "{:?}", w.fake.lines());
    assert!(r.out.contains("t8 にもう移してある"), "{}", r.out);
    assert!(has_call(&w, "hc kill wsl1/t13"));
}

#[test]
fn cleanup_dry_run_says_marks_vanish_without_a_place() {
    let mut child = idle_child(&[(MADE_KEY, MADE)]);
    child["parent"] = json!("t99");
    let w = world_with(
        Sc {
            child: vec![child],
            ..Sc::default()
        },
        |f| f.env("HC_TERMINAL_ID", ""),
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(
        &w,
        &[
            "cleanup",
            "A",
            "--ticket",
            "ABC-681",
            "--force",
            "--dry-run",
        ],
    );
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(
        r.out.contains(
            "見ていない解説動画の印 🎬✅:ABC-700 短尺 x は移す先が無いので、子と一緒に消える"
        ),
        "{}",
        r.out
    );
}

#[test]
fn restart_without_herdr_app_leaves_unwatched_marks_on_the_kept_old_terminal() {
    // herdr-app の無いマシンで立てられなかった: 前の端末は終えただけで消さずに残すので、見ていない印はそこに残り (次の
    // restart が引き継ぐ)、この会話の端末へは逃がさない (写しを作らない)
    let (w, _doc) = no_app_world(
        Sc {
            child: vec![idle_child(&[(MADE_KEY, MADE)])],
            run_fail: true,
            grandkids: json!({"terminals": []}),
            ..Sc::default()
        },
        DocSim::at(
            json!({"spaces": [other_space(), child_space("A claude-skills: W2-2", &["t13"])]}),
            50,
        )
        .on("wsl1")
        .running(0),
    );
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, "hc kill wsl1/t13"));
    assert!(!has_call(&w, "hc rm"), "{:?}", w.fake.lines());
    assert!(label_lines(&w, "t8").is_empty(), "{:?}", w.fake.lines());
    assert!(
        r.err
            .contains("見ていない解説動画の印 1 本は、終えた前の端末 wsl1/t13 に残る"),
        "{}",
        r.err
    );
}

#[test]
fn restart_moves_unwatched_marks_here_when_it_cannot_start_again() {
    // 前の端末を消した後に hc run が落ち、立った端末も見つからない: 見ていない印をこの会話の端末へ逃がす
    let w = world(Sc {
        child: vec![idle_child(&[(MADE_KEY, MADE)])],
        run_fail: true,
        grandkids: json!({"terminals": []}),
        ..Sc::default()
    });
    seed_row(&w, "ABC-681", live_row());
    let r = run(&w, &["restart", "A"]);
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(has_call(&w, "hc kill wsl1/t13"));
    let moved = label_lines(&w, "t8");
    assert_eq!(moved.len(), 1, "{:?}", w.fake.lines());
    assert!(
        moved[0].contains(r#""from":"子 A (wsl1/t13)""#),
        "{moved:?}"
    );
    assert!(r.err.contains("立て直せなかったので"), "{}", r.err);
}
