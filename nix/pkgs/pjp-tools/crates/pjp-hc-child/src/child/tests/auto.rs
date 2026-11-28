//! 子のマシンを自動で選ぶテスト。`--on` も hub.toml の `default_machine` も無いとき (`--on auto`・
//! `default_machine = "auto"` も)、hc machine ls の SSH 先を測って空きコアの多い所を選び、使える所が無ければ手元の WSL に
//! 落ちる。`--on wsl` が hc machine ls の手元の WSL の machine を名前によらず引くテストも、末尾にここで持つ。
//! 偽物の答え方は親 (tests.rs) のものを使い、machine の一覧・測る script・machine ごとの探り (claude の有る無し)・
//! 名前のアカウントの用意だけをここで答える。

use std::cell::Cell;
use std::collections::HashMap;
use std::rc::Rc;

use pjp_core::exit::{CONFIG, FAILURE, OK};
use pjp_core::process::Output;
use serde_json::{Value, json};

use super::{
    Sc, World, has_call, ledger_rows, new_args, respond, run, run_call, space_new_args, value_after,
};
use crate::testutil::{Fake, TempDir, exec_ok, exec_result, fail, ok};

/// 子のマシンを測る script の目印。
const MEASURE_MARK: &str = "printf 'os=%s";
/// 子のマシンを探る script の目印 (HOME・claude・ghq)。
const PROBE_MARK: &str = "printf 'home=";
/// 名前のアカウントの launcher と用意を探る script の目印。
const ACCOUNT_MARK: &str = "printf 'launcher=";

/// Windows のハブの hc machine ls の wsl1 の target (2026-11-21 に指揮役が見た形)。
const WSL: &str = "wsl.exe -d wsl1 --cd ~ -e bash -lc";

/// 1 GiB (MemAvailable の kB で)。
const GIB: u64 = 1024 * 1024;

/// claude-work で動いているハブ (Linux)。
const WORK_HUB: [(&str, &str); 2] = [
    ("HOME", "/home/u"),
    ("CLAUDE_CONFIG_DIR", "/home/u/.claude-work"),
];

/// hc machine ls の 1 行 (hc 0.1.21 の MachineView。connected)。
fn machine(name: &str, target: &str) -> Value {
    json!({
        "name": name,
        "target": target,
        "via": target.starts_with("wsl.exe"),
        "id": format!("id-{name}"),
        "host": name,
        "version": "0.1.21",
        "state": "connected",
    })
}

/// `v` の `key` を `value` にしたもの。
fn with(mut v: Value, key: &str, value: Value) -> Value {
    v[key] = value;
    v
}

/// 測った値の答え (`uname -s`・`nproc`・`/proc/loadavg`・MemAvailable の kB)。`loadavg` は 1・5・15 分の負荷。
fn measured(os: &str, nproc: u32, loadavg: &str, mem_kb: u64) -> Output {
    exec_ok(&format!(
        "os={os}\nnproc={nproc}\nloadavg={loadavg} 2/345 6789\nmemavail_kb={mem_kb}\n"
    ))
}

/// 子のマシンの探り (HOME・claude・ghq・git-gh・checkout) の答え。空の値は「無い」。
fn probed(claude: &str, ghq: &str, checkout: &str) -> Output {
    exec_ok(&format!(
        "home=/home/u\nclaude={claude}\nghq={ghq}\ngitgh=/home/u/.nix-profile/bin/git-gh\ncheckout={checkout}\n"
    ))
}

const CHECKOUT: &str = "/home/u/ghq/github.com/pollenjp/claude-skills";

/// 偽の machine の答え方。
#[derive(Default)]
struct Machines {
    /// hc machine ls の machines。
    list: Vec<Value>,
    /// hc machine ls が落ちるか。
    ls_fail: bool,
    /// 測る script の答え (machine の名前ごと。このマシンは `local`)。無い machine の測りは落ちる。
    measure: Vec<(&'static str, Output)>,
    /// 探りの答え (machine の名前ごと)。無い machine は親の偽物が答える (claude も checkout もある)。
    probe: Vec<(&'static str, Output)>,
    /// 名前のアカウントの launcher と用意の答え (machine の名前ごと)。
    account: Vec<(&'static str, Output)>,
}

/// 16:25 に測った値に近い 3 台: wsl1 (WSL。16 コア・1 分 5.74・21 GiB)、host-a (8 コア・1 分 1.30・8 GiB)、pc2 (4 コア・
/// 1 分 0.50・6 GiB)。1 分の負荷なら host-a が一番空いている (6.7 と 3.5)。5 分の負荷で比べると pc2 の方が空いて見える
/// (host-a 8 - 5.66 = 2.3、pc2 4 - 0.40 = 3.6)。
fn three() -> Machines {
    Machines {
        list: vec![
            machine("wsl1", WSL),
            machine("host-a", "host-a.local"),
            machine("pc2", "pc2.local"),
        ],
        measure: vec![
            ("host-a", measured("Linux", 8, "1.30 5.66 7.03", 8 * GIB)),
            ("pc2", measured("Linux", 4, "0.50 0.40 0.30", 6 * GIB)),
            ("wsl1", measured("Linux", 16, "5.74 8.01 8.08", 21 * GIB)),
        ],
        ..Machines::default()
    }
}

fn world_auto(sc: Sc, ms: Machines, env: &[(&str, &str)]) -> World {
    let gets = Rc::new(Cell::new(0));
    let g = Rc::clone(&gets);
    let list = json!({ "machines": ms.list }).to_string();
    let ls_fail = ms.ls_fail;
    let measure: HashMap<&str, Output> = ms.measure.into_iter().collect();
    let probe: HashMap<&str, Output> = ms.probe.into_iter().collect();
    let account: HashMap<&str, Output> = ms.account.into_iter().collect();
    let mut fake = Fake::new(move |argv| {
        let a: Vec<&str> = argv.iter().map(String::as_str).collect();
        if a.starts_with(&["hc", "machine", "ls"]) {
            if ls_fail {
                return fail(
                    1,
                    r#"{"error":{"kind":"unavailable","message":"the core is busy"}}"#,
                );
            }
            return ok(&list);
        }
        if a.starts_with(&["hc", "exec"]) {
            let on = value_after(argv, "--on").unwrap_or("local");
            let has = |mark: &str| a.iter().any(|x| x.contains(mark));
            if has(MEASURE_MARK) {
                return measure
                    .get(on)
                    .cloned()
                    .unwrap_or_else(|| exec_result(1, "", &format!("偽物: {on} は測れない")));
            }
            if has(PROBE_MARK)
                && let Some(answer) = probe.get(on)
            {
                return answer.clone();
            }
            if has(ACCOUNT_MARK)
                && let Some(answer) = account.get(on)
            {
                return answer.clone();
            }
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

/// `--on` を除いた `pjp child new` の引数。
fn auto_args<'a>(w: &'a World, extra: &[&'a str]) -> Vec<&'a str> {
    let mut v = new_args(w, extra);
    v.drain(1..3); // --on wsl1 を外す
    v
}

/// ハブの hub.toml を書く。
fn hub_toml(w: &World, text: &str) {
    let cfg = w.fake.base().join("config").join("pjp");
    std::fs::create_dir_all(&cfg).unwrap();
    std::fs::write(cfg.join("hub.toml"), text).unwrap();
}

fn hub_toml_path(w: &World) -> String {
    w.fake
        .base()
        .join("config")
        .join("pjp")
        .join("hub.toml")
        .display()
        .to_string()
}

/// 測った machine (hc exec の `--on`。このマシンは `local`) を打った順に。
fn measured_on(w: &World) -> Vec<String> {
    w.fake
        .calls()
        .iter()
        .filter(|c| c.len() > 1 && c[0] == "hc" && c[1] == "exec")
        .filter(|c| c.iter().any(|a| a.contains(MEASURE_MARK)))
        .map(|c| value_after(c, "--on").unwrap_or("local").to_owned())
        .collect()
}

/// 子の端末が `addr` に立つ世界の答え方。
fn sc_at(addr: &str) -> Sc {
    Sc {
        run_addr: addr.to_owned(),
        ..Sc::default()
    }
}

fn assert_out(r: &super::Out, wants: &[&str]) {
    for want in wants {
        assert!(
            r.out.contains(want),
            "{want}\n---\n{}\n---\n{}",
            r.out,
            r.err
        );
    }
}

fn assert_nothing_made(w: &World) {
    for mutating in ["fetch origin", "worktree add", "herdr-app do", "hc run"] {
        assert!(!has_call(w, mutating), "{mutating}: {:#?}", w.fake.lines());
    }
}

// ---- 選ぶ

#[test]
fn new_without_on_picks_the_ssh_machine_with_the_most_free_cores() {
    let w = world_auto(sc_at("host-a/t13"), three(), &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // 測るのは SSH 先だけ (選べたので WSL は測らない)
    assert_eq!(measured_on(&w), ["host-a", "pc2"]);
    // 子のマシンのコマンド・子の端末・space は host-a
    let execs: Vec<String> = w
        .fake
        .lines()
        .into_iter()
        .filter(|l| l.starts_with("hc exec") && !l.contains(MEASURE_MARK))
        .collect();
    assert!(
        !execs.is_empty() && execs.iter().all(|l| l.contains("--on host-a")),
        "{execs:#?}"
    );
    assert_eq!(value_after(&run_call(&w), "--on"), Some("host-a"));
    assert_eq!(space_new_args(&w)["machine"], "host-a");
    assert_eq!(ledger_rows(&w, "ABC-681")[0].machine, "host-a");
    let why = format!(
        "  自動にしたわけ: --on も {} も無い。見る順: SSH 先 → WSL。SSH 先の下限: 空きコア 1・空きメモリ 4 GiB",
        hub_toml_path(&w)
    );
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: host-a (SSH 先・空きコア 6.7 = 8 コア - 1 分の負荷 1.30・空きメモリ 8.0 GiB)",
            &why,
            "  - 次点 pc2 (SSH 先): 空きコア 3.5 = 4 コア - 1 分の負荷 0.50・空きメモリ 6.0 GiB",
            "  - 見ていない wsl1 (WSL): SSH 先から選んだ",
            "  マシン: host-a (自動で選んだ)  repo: pollenjp/claude-skills",
            "note 用: 子 A = pollenjp/claude-skills (host-a/t13・~/.herdr/worktrees/claude-skills/w22・effort high・\
             マシンは自動で host-a (SSH 先・空きコア 6.7・空きメモリ 8.0 GiB))",
        ],
    );
    // 選んでから立てる (選んだマシンとわけが、立てた行より前)
    let chose = r.out.find("子のマシンを自動で選んだ").unwrap();
    assert!(chose < r.out.find("子 A を立てた").unwrap(), "{}", r.out);
}

#[test]
fn new_falls_back_to_wsl_when_no_ssh_machine_clears_the_floors() {
    let mut ms = three();
    ms.measure = vec![
        ("host-a", measured("Linux", 8, "1.30 5.66 7.03", 2 * GIB)),
        ("pc2", measured("Linux", 4, "3.50 3.00 3.00", 8 * GIB)),
        ("wsl1", measured("Linux", 16, "5.74 8.01 8.08", 21 * GIB)),
    ];
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(measured_on(&w), ["host-a", "pc2", "wsl1"]);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
    assert_eq!(ledger_rows(&w, "ABC-681")[0].machine, "wsl1");
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: wsl1 (WSL・使える SSH 先が無い・空きコア 10.3 = 16 コア - 1 分の負荷 5.74・空きメモリ 21.0 GiB)",
            "  - 外した host-a (SSH 先): 空きメモリ 2.0 GiB が下限の 4 GiB より少ない",
            "  - 外した pc2 (SSH 先): 空きコア 0.5 が下限の 1 より少ない",
        ],
    );
}

#[test]
fn wsl_fallback_does_not_apply_the_ssh_floors() {
    // 手元の WSL は落ち先なので、混んでいても立てる (下限は SSH 先だけ)
    let ms = Machines {
        list: vec![machine("wsl1", WSL), machine("host-a", "host-a.local")],
        measure: vec![
            ("host-a", measured("Linux", 8, "7.90 7.00 7.00", 8 * GIB)),
            ("wsl1", measured("Linux", 16, "15.80 15.00 15.00", 2 * GIB)),
        ],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: wsl1 (WSL・使える SSH 先が無い・空きコア 0.2 = 16 コア - 1 分の負荷 15.80・空きメモリ 2.0 GiB)",
            "  - 外した host-a (SSH 先): 空きコア 0.1 が下限の 1 より少ない",
        ],
    );
}

#[test]
fn equal_free_cores_go_to_more_free_memory() {
    // 空きコアは出力の桁 (0.1) で比べる: host-a 8 - 5.00 = 3.0、pc2 4 - 1.04 = 2.96 → 3.0 で同じ。空きメモリの多い pc2
    let ms = Machines {
        list: vec![
            machine("host-a", "host-a.local"),
            machine("pc2", "pc2.local"),
        ],
        measure: vec![
            ("host-a", measured("Linux", 8, "5.00 5.00 5.00", 8 * GIB)),
            ("pc2", measured("Linux", 4, "1.04 1.00 1.00", 12 * GIB)),
        ],
        ..Machines::default()
    };
    let w = world_auto(sc_at("pc2/t13"), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("pc2"));
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: pc2 (SSH 先・空きコア 3.0 = 4 コア - 1 分の負荷 1.04・空きメモリ 12.0 GiB)",
            "  - 次点 host-a (SSH 先): 空きコア 3.0 = 8 コア - 1 分の負荷 5.00・空きメモリ 8.0 GiB",
        ],
    );
}

// ---- 使えない machine を飛ばす

#[test]
fn new_skips_ssh_machine_without_the_hub_account() {
    // ハブは claude-work。一番空いている host-a には claude-work が無いので、次の pc2 に立てる
    let mut ms = three();
    ms.account = vec![
        ("host-a", exec_ok("launcher=\n")),
        (
            "pc2",
            exec_ok("launcher=/home/u/.nix-profile/bin/claude-work\nlogin=1\n"),
        ),
    ];
    let w = world_auto(sc_at("pc2/t13"), ms, &WORK_HUB);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let call = run_call(&w);
    assert_eq!(value_after(&call, "--on"), Some("pc2"));
    assert!(
        call.contains(&"/home/u/.nix-profile/bin/claude-work".to_owned()),
        "{call:?}"
    );
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: pc2 (SSH 先・空きコア 3.5 = 4 コア - 1 分の負荷 0.50・空きメモリ 6.0 GiB)",
            // わけは 1 文目まで (用意の手の案内は、止まるときの文に出す)
            "  - 外した host-a (SSH 先): 子のマシン (host-a) に claude-work がありません (PATH にも ~/.nix-profile/bin・~/.local/bin にも無い)\n",
            "  (探り・アカウントの確かめで外した machine の細部は pjp child new --on <machine> --dry-run で出る)",
        ],
    );
    // 外した host-a には、作るものを何も打たない
    assert!(
        !w.fake
            .lines()
            .iter()
            .any(|l| l.contains("--on host-a") && (l.contains("fetch") || l.contains("worktree"))),
        "{:#?}",
        w.fake.lines()
    );
}

#[test]
fn new_skips_ssh_machine_without_claude() {
    let mut ms = three();
    ms.probe = vec![("host-a", probed("", "/usr/bin/ghq", CHECKOUT))];
    let w = world_auto(sc_at("pc2/t13"), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("pc2"));
    assert_out(
        &r,
        &[
            "  - 外した host-a (SSH 先): 子のマシン (host-a) に claude が見つかりません (PATH にも ~/.local/share/mise/installs/claude/latest/claude にも無い)",
        ],
    );
}

#[test]
fn new_skips_ssh_machine_that_cannot_be_probed_or_has_no_repo() {
    // host-a は探れない (hc exec の中で落ちる)、pc2 は repo の checkout も ghq も無い → WSL の wsl1
    let mut ms = three();
    ms.probe = vec![
        ("host-a", exec_result(1, "", "sh: cannot fork")),
        ("pc2", probed("/home/u/.local/bin/claude", "", "")),
    ];
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: wsl1 (WSL・使える SSH 先が無い・",
            "  - 外した host-a (SSH 先): 子のマシン (host-a) を探れません: sh: cannot fork",
            "  - 外した pc2 (SSH 先): pollenjp/claude-skills の checkout も ghq も無い",
        ],
    );
    // --dir の子は repo を探さないので、checkout も ghq も無い machine も使える
    let mut ms = three();
    ms.probe = vec![("host-a", probed("/home/u/.local/bin/claude", "", ""))];
    let w = world_auto(sc_at("host-a/t13"), ms, &[]);
    let r = run(
        &w,
        &[
            "new",
            "--dir",
            "~/.local/share/pjp-video-explainers/x",
            "--label",
            "動画: 試し",
            "--agent",
            "video",
            "--brief",
            w.brief.to_str().unwrap(),
        ],
    );
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("host-a"));
}

#[test]
fn new_skips_machine_whose_measure_times_out_and_stops_when_machine_ls_fails() {
    let mut ms = three();
    ms.measure[0] = (
        "host-a",
        ok(&json!({"code": null, "stdout": "", "stderr": "", "timed_out": true, "truncated": false, "ms": 20003})
            .to_string()),
    );
    let w = world_auto(sc_at("pc2/t13"), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("pc2"));
    assert_out(&r, &["  - 外した host-a (SSH 先): 測れない (時間切れ)"]);

    // hc machine ls が落ちたら、何も作らずに止まる
    let w = world_auto(
        Sc::default(),
        Machines {
            ls_fail: true,
            ..three()
        },
        &[],
    );
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    assert!(
        r.err.contains("hc machine が落ちました: the core is busy"),
        "{}",
        r.err
    );
    assert_nothing_made(&w);
}

#[test]
fn ssh_host_named_wsl_is_an_ssh_machine() {
    // WSL とみるのは --via の machine だけ (~/.ssh/config の Host が wsl でも SSH 先)
    let ms = Machines {
        list: vec![machine("wsl1", WSL), {
            let mut m = machine("wsl", "wsl");
            m["via"] = json!(false);
            m
        }],
        measure: vec![
            ("wsl", measured("Linux", 8, "0.10 0.10 0.10", 8 * GIB)),
            ("wsl1", measured("Linux", 16, "5.74 8.01 8.08", 21 * GIB)),
        ],
        ..Machines::default()
    };
    let w = world_auto(sc_at("wsl/t13"), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl"));
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: wsl (SSH 先・",
            "  - 見ていない wsl1 (WSL): SSH 先から選んだ",
        ],
    );
}

#[test]
fn new_skips_machines_it_cannot_use() {
    let ms = Machines {
        list: vec![
            with(machine("box", "box.example"), "temporary", json!(true)),
            with(
                with(machine("off", "off.local"), "state", json!("unreachable")),
                "why",
                json!("ssh: connect to host off.local port 22: No route to host"),
            ),
            machine("mac", "mac.local"),
            machine("old", "old.local"),
            machine("half", "half.local"),
            machine("host-a", "host-a.local"),
        ],
        measure: vec![
            ("box", measured("Linux", 64, "0.00 0.00 0.00", 64 * GIB)),
            ("mac", measured("Darwin", 10, "0.10 0.10 0.10", 16 * GIB)),
            ("old", exec_result(127, "", "sh: 1: nproc: not found")),
            ("half", exec_ok("os=Linux\nnproc=2\n")),
            ("host-a", measured("Linux", 8, "1.30 5.66 7.03", 8 * GIB)),
        ],
        ..Machines::default()
    };
    let w = world_auto(sc_at("host-a/t13"), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("host-a"));
    // 一時の machine と、つながっていない machine は測らない
    assert_eq!(measured_on(&w), ["mac", "old", "half", "host-a"]);
    assert_out(
        &r,
        &[
            "  - 外した box (SSH 先): 一時の machine (temporary)",
            "  - 外した off (SSH 先): connected でない (unreachable: ssh: connect to host off.local port 22: No route to host)",
            "  - 外した mac (SSH 先): Linux でない (Darwin)",
            "  - 外した old (SSH 先): 測れない (sh: 1: nproc: not found)",
            "  - 外した half (SSH 先): 測った値を読めない (/proc/loadavg・MemAvailable が無い)",
        ],
    );
}

#[test]
fn new_stops_when_no_machine_is_usable() {
    let ms = Machines {
        list: vec![
            with(
                with(machine("wsl1", WSL), "state", json!("unreachable")),
                "why",
                json!("wsl.exe exited"),
            ),
            machine("host-a", "host-a.local"),
            machine("mac", "mac.local"),
        ],
        measure: vec![
            ("host-a", measured("Linux", 8, "7.90 7.00 7.00", 8 * GIB)),
            ("mac", measured("Darwin", 10, "0.10 0.10 0.10", 16 * GIB)),
        ],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "子のマシンを自動で選べません (使える SSH 先も WSL もありません)",
        "  - 外した host-a (SSH 先): 空きコア 0.1 が下限の 1 より少ない",
        "  - 外した mac (SSH 先): Linux でない (Darwin)",
        "  - 外した wsl1 (WSL): connected でない (unreachable: wsl.exe exited)",
        "--on <machine>",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert_nothing_made(&w);
    assert!(ledger_rows(&w, "ABC-681").is_empty());
}

#[test]
fn new_stops_with_the_account_fix_when_no_machine_has_the_account() {
    // アカウントで外したときは、止まる文に用意の手 (claude-account などの文) も出す
    let ms = Machines {
        list: vec![machine("host-a", "host-a.local")],
        measure: vec![("host-a", measured("Linux", 8, "1.30 5.66 7.03", 8 * GIB))],
        account: vec![(
            "host-a",
            exec_ok("launcher=/home/u/.nix-profile/bin/claude-work\n"),
        )],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &WORK_HUB);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "  - 外した host-a (SSH 先): 子のマシン (host-a) の claude-work は用意ができていません",
        "子のマシンの端末で claude-work を起こして /login する",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert_nothing_made(&w);
}

#[test]
fn new_without_machines_says_how_to_choose() {
    let w = world_auto(Sc::default(), Machines::default(), &[]);
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, CONFIG, "{}\n{}", r.out, r.err);
    for want in [
        "hc machine ls に SSH 先も WSL もありません",
        "--on <machine>",
        "default_machine = \"<machine>\"",
        // 見る順に WSL があれば、手元の WSL の足し方も出す
        "Windows のハブで手元の WSL を足すなら",
        "\n  hc machine add --via 'wsl.exe -d <ディストリビューション> --cd ~ -e bash -lc' --name <名前>",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert_nothing_made(&w);
}

// ---- --dry-run・--chrome

#[test]
fn new_dry_run_measures_and_shows_the_choice() {
    let w = world_auto(sc_at("host-a/t13"), three(), &[]);
    let r = run(&w, &auto_args(&w, &["--dry-run"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    // --dry-run でも測って選ぶ (測る・探るのは読むだけ)
    assert_eq!(measured_on(&w), ["host-a", "pc2"]);
    assert_nothing_made(&w);
    assert!(ledger_rows(&w, "ABC-681").is_empty());
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: host-a (SSH 先・空きコア 6.7 = 8 コア - 1 分の負荷 1.30・空きメモリ 8.0 GiB)",
            "(--dry-run) 子 A を立てるなら",
            "  マシン: host-a (自動で選んだ)\n",
            "hc run --bg --json --on host-a --cwd /home/u/.herdr/worktrees/claude-skills/w22",
        ],
    );
}

#[test]
fn chrome_child_is_chosen_from_wsl_only() {
    // Claude in Chrome は WSL の子で確かめた (Windows の Chrome につながる)。SSH 先は見ない
    let w = world_auto(Sc::default(), three(), &[]);
    let r = run(&w, &auto_args(&w, &["--chrome"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(measured_on(&w), ["wsl1"]);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: wsl1 (WSL・空きコア 10.3 = 16 コア - 1 分の負荷 5.74・空きメモリ 21.0 GiB)",
            "見る順: WSL (--chrome の子は WSL から選ぶ)",
            "  - 見ていない host-a (SSH 先): --chrome の子は WSL から選ぶ",
            "  - 見ていない pc2 (SSH 先): --chrome の子は WSL から選ぶ",
        ],
    );
}

// ---- hub.toml

#[test]
fn on_auto_and_default_machine_auto_choose_automatically() {
    // --on auto は hub.toml の default_machine より先
    let w = world_auto(sc_at("host-a/t13"), three(), &[]);
    hub_toml(&w, "default_machine = \"wsl1\"\n");
    let mut args = new_args(&w, &[]);
    args[2] = "auto";
    let r = run(&w, &args);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("host-a"));
    assert_out(&r, &["  自動にしたわけ: --on auto。見る順: SSH 先 → WSL"]);

    // default_machine = "auto"
    let w = world_auto(sc_at("host-a/t13"), three(), &[]);
    hub_toml(&w, "default_machine = \"auto\"\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("host-a"));
    let why = format!(
        "  自動にしたわけ: {} の default_machine が auto。",
        hub_toml_path(&w)
    );
    assert_out(&r, &[&why]);

    // [auto] だけで default_machine の無い hub.toml も自動
    let w = world_auto(sc_at("host-a/t13"), three(), &[]);
    hub_toml(&w, "[auto]\nmin_free_cores = 1\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    let why = format!(
        "  自動にしたわけ: --on も {} の default_machine も無い。",
        hub_toml_path(&w)
    );
    assert_out(&r, &[&why]);

    // default_machine が machine の名前なら今までどおり (machine の一覧も読まず、測らない)
    let w = world_auto(Sc::default(), three(), &[]);
    hub_toml(&w, "default_machine = \"wsl1\"\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
    assert!(!has_call(&w, "hc machine ls"));
    assert!(measured_on(&w).is_empty());
    assert!(!r.out.contains("自動"), "{}", r.out);

    // default_machine が machine の名前なら、[auto] は読まない (自動のときだけ確かめる)
    let w = world_auto(Sc::default(), three(), &[]);
    hub_toml(
        &w,
        "default_machine = \"wsl1\"\n[auto]\nmin_free_core = 1\n",
    );
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
}

#[test]
fn checkout_needs_on_because_the_path_belongs_to_one_machine() {
    // --checkout は子のマシンの repo (~/h など) を指す。--on を省くと、同じパスのほかのマシンの repo を選びうるので止まる
    let checkout_args = |w: &World, extra: &[&str]| -> Vec<String> {
        let mut v: Vec<String> = [
            "new",
            "--checkout",
            "~/h",
            "--label",
            "h: 試し",
            "--agent",
            "w22",
            "--brief",
            w.brief.to_str().unwrap(),
        ]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
        v.extend(extra.iter().map(|s| (*s).to_owned()));
        v
    };
    for hub in [None, Some("default_machine = \"auto\"\n")] {
        let w = world_auto(Sc::default(), three(), &[]);
        if let Some(text) = hub {
            hub_toml(&w, text);
        }
        let args = checkout_args(&w, &[]);
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let r = run(&w, &args);
        assert_eq!(r.code, CONFIG, "{hub:?}: {}\n{}", r.out, r.err);
        for want in ["--checkout", "--on <machine>", "--on auto"] {
            assert!(r.err.contains(want), "{hub:?}: {want}\n---\n{}", r.err);
        }
        assert!(!has_call(&w, "hc machine ls"), "{hub:?}");
        assert_nothing_made(&w);
    }
    // --on auto と渡せば自動で選ぶ
    let w = world_auto(sc_at("host-a/t13"), three(), &[]);
    let args = checkout_args(&w, &["--on", "auto"]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let r = run(&w, &args);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("host-a"));
    // default_machine が machine の名前なら、今までどおりそのマシン
    let w = world_auto(Sc::default(), three(), &[]);
    hub_toml(&w, "default_machine = \"wsl1\"\n");
    let args = checkout_args(&w, &[]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let r = run(&w, &args);
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
}

#[test]
fn hub_toml_auto_section_sets_exclude_floors_and_order() {
    // exclude: 名前で外す (測らない)
    let w = world_auto(sc_at("pc2/t13"), three(), &[]);
    hub_toml(&w, "[auto]\nexclude = [\"host-a\"]\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("pc2"));
    assert_eq!(measured_on(&w), ["pc2"]);
    assert_out(
        &r,
        &["  - 外した host-a (SSH 先): hub.toml の exclude にある"],
    );

    // hc machine ls に無い名前の exclude は、綴りの誤りかもしれないので知らせる (止めない)
    let w = world_auto(sc_at("host-a/t13"), three(), &[]);
    hub_toml(&w, "[auto]\nexclude = [\"hsot-a\"]\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("host-a"));
    assert_out(
        &r,
        &["  - hub.toml の exclude の hsot-a は hc machine ls に無い (綴りを確かめる)"],
    );

    // 下限 (小数も書ける)
    let w = world_auto(Sc::default(), three(), &[]);
    hub_toml(&w, "[auto]\nmin_free_cores = 4\nmin_free_mem_gib = 8.5\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
    assert_out(
        &r,
        &[
            "SSH 先の下限: 空きコア 4・空きメモリ 8.5 GiB",
            "  - 外した host-a (SSH 先): 空きメモリ 8.0 GiB が下限の 8.5 GiB より少ない",
            "  - 外した pc2 (SSH 先): 空きコア 3.5 が下限の 4 より少ない・空きメモリ 6.0 GiB が下限の 8.5 GiB より少ない",
        ],
    );

    // order: WSL を先に見る
    let w = world_auto(Sc::default(), three(), &[]);
    hub_toml(&w, "[auto]\norder = [\"wsl\", \"ssh\"]\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl1"));
    assert_eq!(measured_on(&w), ["wsl1"]);
    assert_out(
        &r,
        &[
            "見る順: WSL → SSH 先",
            "子のマシンを自動で選んだ: wsl1 (WSL・空きコア 10.3",
            "  - 見ていない host-a (SSH 先): WSL から選んだ",
        ],
    );

    // order に無い種類は見ない (SSH 先だけ。使えなければ WSL に落ちずに止まる)
    let mut ms = three();
    ms.measure = vec![
        ("host-a", measured("Linux", 8, "7.90 7.00 7.00", 8 * GIB)),
        ("pc2", measured("Linux", 4, "3.90 3.00 3.00", 8 * GIB)),
    ];
    let w = world_auto(Sc::default(), ms, &[]);
    hub_toml(&w, "[auto]\norder = [\"ssh\"]\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "子のマシンを自動で選べません (使える SSH 先がありません)",
        "  - 見ていない wsl1 (WSL): hub.toml の [auto] の order に無い",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert_nothing_made(&w);
}

#[test]
fn order_with_local_falls_back_to_this_machine() {
    // Linux のハブ (WSL の無いマシン) は order に local を書くと、使える SSH 先が無いときにこのマシンに立てる。このマシンにも
    // 下限は効かせない (空きメモリ 1 GiB でも選ぶ)
    let ms = Machines {
        list: vec![machine("host-a", "host-a.local")],
        measure: vec![
            ("host-a", measured("Linux", 8, "1.30 5.66 7.03", GIB)),
            ("local", measured("Linux", 4, "0.10 0.10 0.10", GIB)),
        ],
        ..Machines::default()
    };
    let w = world_auto(sc_at("t13"), ms, &[]);
    hub_toml(&w, "[auto]\norder = [\"ssh\", \"local\"]\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), None);
    assert!(space_new_args(&w).get("machine").is_none());
    assert_eq!(ledger_rows(&w, "ABC-681")[0].machine, "");
    assert_out(
        &r,
        &[
            "子のマシンを自動で選んだ: local (このマシン・使える SSH 先が無い・空きコア 3.9 = 4 コア - 1 分の負荷 0.10・空きメモリ 1.0 GiB)",
            "  - 外した host-a (SSH 先): 空きメモリ 1.0 GiB が下限の 4 GiB より少ない",
            "  マシン: local (自動で選んだ)  repo: pollenjp/claude-skills\n",
        ],
    );
    // --dry-run の行も、このマシンを自動で選んだと出す (括弧を重ねない)
    let r = run(&w, &auto_args(&w, &["--dry-run"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_out(&r, &["  マシン: local (このマシン。自動で選んだ)\n"]);
}

#[test]
fn hub_toml_mistakes_stop_before_measuring() {
    for (text, want) in [
        ("[auto]\nmin_free_core = 1\n", "min_free_core"),
        ("[auto]\norder = [\"ssh\", \"mac\"]\n", "mac"),
        ("[auto]\norder = []\n", "order"),
        ("[auto]\norder = [\"ssh\", \"ssh\"]\n", "ssh"),
        ("[auto]\nmin_free_mem_gib = -1\n", "min_free_mem_gib"),
        ("[auto]\nexclude = \"host-a\"\n", "exclude"),
        ("auto = 1\n", "[auto]"),
        ("default_machine = 1\n", "default_machine"),
    ] {
        let w = world_auto(Sc::default(), three(), &[]);
        hub_toml(&w, text);
        let r = run(&w, &auto_args(&w, &[]));
        assert_eq!(r.code, CONFIG, "{text}: {}\n{}", r.out, r.err);
        assert!(r.err.contains(want), "{text}: {want}\n---\n{}", r.err);
        assert!(!has_call(&w, "hc machine ls"), "{text}");
        assert_nothing_made(&w);
    }
}

// ---- --on wsl

/// WSL を Ubuntu-24.04 のまま足した PC の hc machine ls の target。名前は PC ごとに違う。
const WSL_UBUNTU: &str = "wsl.exe -d Ubuntu-24.04 --cd ~ -e bash -lc";

/// `--on wsl` の `pjp child new` の引数。
fn wsl_args<'a>(w: &'a World, extra: &[&'a str]) -> Vec<&'a str> {
    let mut v = new_args(w, extra);
    v[2] = "wsl";
    v
}

/// connected でない machine。
fn down(m: Value, why: &str) -> Value {
    with(with(m, "state", json!("unreachable")), "why", json!(why))
}

#[test]
fn on_wsl_picks_the_wsl_machine_whatever_its_name() {
    // --on wsl は --via のコマンドが wsl.exe の machine を、名前によらず選ぶ。測らない
    let ms = Machines {
        list: vec![
            machine("host-a", "host-a.local"),
            machine("ubuntu", WSL_UBUNTU),
        ],
        ..Machines::default()
    };
    let w = world_auto(sc_at("ubuntu/t13"), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert!(measured_on(&w).is_empty(), "{:#?}", w.fake.lines());
    // 子のマシンのコマンド・子の端末・space・控えは、選んだ machine の名前 (restart・cleanup は控えの名前を使う)
    let execs: Vec<String> = w
        .fake
        .lines()
        .into_iter()
        .filter(|l| l.starts_with("hc exec"))
        .collect();
    assert!(
        !execs.is_empty() && execs.iter().all(|l| l.contains("--on ubuntu")),
        "{execs:#?}"
    );
    assert_eq!(value_after(&run_call(&w), "--on"), Some("ubuntu"));
    assert_eq!(space_new_args(&w)["machine"], "ubuntu");
    assert_eq!(ledger_rows(&w, "ABC-681")[0].machine, "ubuntu");
    assert_out(
        &r,
        &[
            "子のマシン: ubuntu (手元の WSL。--on wsl)\n",
            "  マシン: ubuntu (手元の WSL)  repo: pollenjp/claude-skills",
            "note 用: 子 A = pollenjp/claude-skills (ubuntu/t13・~/.herdr/worktrees/claude-skills/w22・effort high・\
             マシンは手元の WSL)",
        ],
    );
    // 引いてから立てる (選んだマシンが、立てた行より前)
    let chose = r.out.find("子のマシン: ubuntu").unwrap();
    assert!(chose < r.out.find("子 A を立てた").unwrap(), "{}", r.out);
}

#[test]
fn on_wsl_and_a_wsl_machine_named_wsl_are_the_same_machine() {
    // WSL を wsl という名前で足した PC (hc machine add --help の例の名前)。語と名前が同じ machine を指すので、ぶつからない
    let ms = Machines {
        list: vec![
            machine("host-a", "host-a.local"),
            machine("wsl", WSL_UBUNTU),
        ],
        ..Machines::default()
    };
    let w = world_auto(sc_at("wsl/t13"), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl"));
    assert_eq!(ledger_rows(&w, "ABC-681")[0].machine, "wsl");
    assert_out(
        &r,
        &[
            "子のマシン: wsl (手元の WSL。--on wsl)\n",
            "  マシン: wsl (手元の WSL)",
        ],
    );
}

#[test]
fn on_wsl_with_two_wsl_machines_takes_the_one_named_wsl_or_stops() {
    // 2 つ以上なら、名前が wsl の WSL の machine を選ぶ
    let ms = Machines {
        list: vec![machine("wsl1", WSL), machine("wsl", WSL_UBUNTU)],
        ..Machines::default()
    };
    let w = world_auto(sc_at("wsl/t13"), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("wsl"));
    assert_out(
        &r,
        &[
            "子のマシン: wsl (手元の WSL。--on wsl)\n",
            "  - ほかの WSL の machine: wsl1 (connected) (名前が wsl の machine を選んだ。ほかを使うなら --on <machine> で名指しする)",
        ],
    );

    // 名前が wsl のものが無ければ 1 つに決まらないので、候補を並べて止まる (connected でない machine も並べる)
    let ms = Machines {
        list: vec![
            machine("wsl1", WSL),
            down(machine("ubuntu", WSL_UBUNTU), "wsl.exe exited"),
        ],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, CONFIG, "{}\n{}", r.out, r.err);
    for want in [
        "手元の WSL の machine が 2 つあり、--on wsl では 1 つに決まりません: wsl1 (connected)・ubuntu (unreachable: wsl.exe exited)",
        "--on <machine> で名指しして打ち直す",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert_nothing_made(&w);
    assert!(ledger_rows(&w, "ABC-681").is_empty());
}

#[test]
fn on_wsl_without_a_wsl_machine_says_how_to_add_one() {
    let ms = Machines {
        list: vec![machine("host-a", "host-a.local")],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, CONFIG, "{}\n{}", r.out, r.err);
    for want in [
        "手元の WSL の machine が hc machine ls にありません",
        "名前は自由",
        "wsl.exe -l -v",
        "\n  hc machine add --via 'wsl.exe -d <ディストリビューション> --cd ~ -e bash -lc' --name <名前>",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    // 探らず、何も作らない
    assert!(!has_call(&w, "hc exec"), "{:#?}", w.fake.lines());
    assert_nothing_made(&w);
}

#[test]
fn ssh_machine_named_wsl_is_not_picked_by_on_wsl() {
    // 語が machine の名前より先 (local・auto と同じ)。名前が wsl の SSH 先は選ばず、わけと名前の替え方を出す
    let ms = Machines {
        list: vec![machine("wsl", "box.local"), machine("ubuntu", WSL_UBUNTU)],
        ..Machines::default()
    };
    let w = world_auto(sc_at("ubuntu/t13"), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("ubuntu"));
    assert!(!has_call(&w, "--on wsl"), "{:#?}", w.fake.lines());
    assert_out(
        &r,
        &[
            "子のマシン: ubuntu (手元の WSL。--on wsl)\n",
            "  - 名前が wsl の machine は WSL でない (SSH 先。target box.local) ので選ばない (--on wsl は手元の WSL を選ぶ語)。",
            "hc machine rename wsl <新しい名前>",
        ],
    );

    // WSL の machine が無ければ止まり、足し方と、名前が wsl の machine を選ばないわけを出す
    let ms = Machines {
        list: vec![machine("wsl", "box.local")],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, CONFIG, "{}\n{}", r.out, r.err);
    for want in [
        "手元の WSL の machine が hc machine ls にありません",
        "\n  - 名前が wsl の machine は WSL でない (SSH 先。target box.local) ので選ばない",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert!(!has_call(&w, "--on wsl"), "{:#?}", w.fake.lines());
    assert_nothing_made(&w);
}

#[test]
fn on_wsl_stops_when_the_wsl_machine_is_down_and_skips_temporary_ones() {
    // connected でなければ止まる。一時の machine (temporary) は自動と同じく選ばない
    let ms = Machines {
        list: vec![
            down(machine("ubuntu", WSL_UBUNTU), "wsl.exe exited"),
            with(machine("try", WSL), "temporary", json!(true)),
        ],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "手元の WSL の machine ubuntu は connected でない (unreachable: wsl.exe exited)。hc machine ls で状態を確かめてから打ち直す",
        "\n  - 一時の machine (temporary) の WSL は選ばない: try (使うなら --on <machine> で名指しする)",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert_nothing_made(&w);

    // 一時の machine は数えない (WSL の machine が 1 つに決まる)
    let ms = Machines {
        list: vec![
            machine("ubuntu", WSL_UBUNTU),
            with(machine("try", WSL), "temporary", json!(true)),
        ],
        ..Machines::default()
    };
    let w = world_auto(sc_at("ubuntu/t13"), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("ubuntu"));
    assert_out(
        &r,
        &["  - 一時の machine (temporary) の WSL は選ばない: try"],
    );

    // 2 つのうち名前が wsl の方がつながっていなければ止まり、ほかの WSL の machine を名指しの候補に出す
    let ms = Machines {
        list: vec![
            machine("ubuntu", WSL_UBUNTU),
            down(machine("wsl", WSL), "wsl.exe exited"),
        ],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, FAILURE, "{}\n{}", r.out, r.err);
    for want in [
        "手元の WSL の machine wsl は connected でない (unreachable: wsl.exe exited)",
        "\n  - ほかの WSL の machine: ubuntu (connected) (使うなら --on <machine> で名指しする)",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert_nothing_made(&w);
}

#[test]
fn default_machine_wsl_checkout_and_dry_run() {
    let ms = || Machines {
        list: vec![
            machine("host-a", "host-a.local"),
            machine("ubuntu", WSL_UBUNTU),
        ],
        ..Machines::default()
    };
    // hub.toml の default_machine = "wsl" も同じ語
    let w = world_auto(sc_at("ubuntu/t13"), ms(), &[]);
    hub_toml(&w, "default_machine = \"wsl\"\n");
    let r = run(&w, &auto_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("ubuntu"));
    assert!(measured_on(&w).is_empty());
    let why = format!(
        "子のマシン: ubuntu (手元の WSL。{} の default_machine が wsl)\n",
        hub_toml_path(&w)
    );
    assert_out(&r, &[&why]);

    // --on wsl は名指しと同じく 1 台に決まるので、--checkout にも使える (--on を省くと止まる)
    let w = world_auto(sc_at("ubuntu/t13"), ms(), &[]);
    let brief = w.brief.to_str().unwrap();
    let r = run(
        &w,
        &[
            "new",
            "--on",
            "wsl",
            "--checkout",
            "~/h",
            "--label",
            "h: 試し",
            "--agent",
            "w22",
            "--brief",
            brief,
        ],
    );
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("ubuntu"));

    // --dry-run も引いて出す (打つのは hc machine ls と探りだけ)
    let w = world_auto(sc_at("ubuntu/t13"), ms(), &[]);
    let r = run(&w, &wsl_args(&w, &["--dry-run"]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_nothing_made(&w);
    assert!(ledger_rows(&w, "ABC-681").is_empty());
    assert_out(
        &r,
        &[
            "子のマシン: ubuntu (手元の WSL。--on wsl)\n",
            "(--dry-run) 子 A を立てるなら",
            "  マシン: ubuntu (手元の WSL)\n",
            "hc run --bg --json --on ubuntu --cwd /home/u/.herdr/worktrees/claude-skills/w22",
        ],
    );
}

#[test]
fn on_wsl_skips_nameless_machines_and_explains_a_temporary_one_named_wsl() {
    // 名前の無い machine は選ばない (自動と同じ。控えの空の machine はこのマシンと読まれる)。名前のある 1 つに決まる
    let ms = Machines {
        list: vec![
            json!({"target": WSL_UBUNTU, "via": true, "state": "connected"}),
            machine("ubuntu", WSL_UBUNTU),
        ],
        ..Machines::default()
    };
    let w = world_auto(sc_at("ubuntu/t13"), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, OK, "{}\n{}", r.out, r.err);
    assert_eq!(value_after(&run_call(&w), "--on"), Some("ubuntu"));
    assert!(!r.out.contains("ほかの WSL の machine"), "{}", r.out);

    // 名前が wsl の一時の machine は選ばない。--on wsl は語として読むので、名指しの代わりに名前の替え方を出す。
    // このマシンが WSL の中の Linux のハブなら、--on local を勧める
    let ms = Machines {
        list: vec![with(machine("wsl", WSL_UBUNTU), "temporary", json!(true))],
        ..Machines::default()
    };
    let w = world_auto(Sc::default(), ms, &[]);
    let r = run(&w, &wsl_args(&w, &[]));
    assert_eq!(r.code, CONFIG, "{}\n{}", r.out, r.err);
    for want in [
        "手元の WSL の machine が hc machine ls にありません",
        "\nこのマシンが WSL (WSL の中の Linux のハブ) なら、--on local でこのマシンに立てる",
        "\n  - 一時の machine (temporary) の WSL は選ばない: wsl (使うなら --on <machine> で名指しする。名前が wsl のものは\
         語と同じで名指しできないので、hc machine rename wsl <新しい名前> で名前を替える)",
    ] {
        assert!(r.err.contains(want), "{want}\n---\n{}", r.err);
    }
    assert_nothing_made(&w);
}

#[test]
fn help_shows_the_same_wsl_add_command() {
    // pjp child --help の足し方は、--on wsl が止まるときに出すもの (pjp hub hello も同じ形を出す) と同じ
    assert!(
        super::super::USAGE.contains(super::super::WSL_ADD),
        "{}",
        super::super::WSL_ADD
    );
}
