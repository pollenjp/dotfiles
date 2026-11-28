//! appdoc のテスト。hc の core の doc herdr-app と、それを読み書きする herdr-app を偽物 ([`DocSim`]) にする。

use std::cell::RefCell;
use std::rc::Rc;

use pjp_core::process::Output;
use serde_json::{Value, json};

use super::*;
use crate::hc::Hc;
use crate::testutil::{DocSim, Fake, fail, ok, rpc_calls, rpc_methods};

/// host-a の herdr-app が書いた doc と同じ形 (2026-11-21 にユーザーの core で読んだもの。root は row で id は tab と同じ、ペインは
/// block で id は p + 32 字の hex、content.terminal はそのマシンの中の住所)。space sp1 に t1、sphub に t8。
fn host_a_doc() -> Value {
    let space = |id: &str, name: &str, folder: &str, tab: &str, pane: &str, terminal: &str| {
        json!({"folder": folder, "id": id, "name": name, "tabs": [{"id": tab, "name": "", "root": {
            "children": [{"content": {"terminal": terminal}, "id": pane, "type": "block"}],
            "id": tab, "type": "row"}}]})
    };
    json!({"spaces": [
        space("sp1", "", "/home/u/h", "tb1", "p9ca56f1b0bfd0992386d84fd6edd7e57", "t1"),
        space("sphub", "ABC-833 移行", "/home/u/.herdr/worktrees/h/w1", "tbhub", "pf4b87ec514be4e429afe840ff85c8c3b", "t8"),
    ]})
}

/// 子のマシンの端末の状態 (`hc get` に答える)。無い住所は not_found。
#[derive(Clone, Default)]
struct Terms {
    /// 生きている端末の住所 (`hc get` に渡る形。別のマシンなら `wsl1/t29`)。
    live: Vec<&'static str>,
    /// 終わった端末の住所。
    finished: Vec<&'static str>,
    /// `hc get` そのものが落ちる住所 (つながらない)。
    broken: Vec<&'static str>,
}

fn world(doc: DocSim, terms: Terms) -> (Fake, Rc<RefCell<DocSim>>) {
    let doc = Rc::new(RefCell::new(doc));
    let d = Rc::clone(&doc);
    let fake = Fake::new(move |argv| {
        let a: Vec<&str> = argv.iter().map(String::as_str).collect();
        match a.as_slice() {
            ["hc", "connect", input] => d.borrow_mut().answer(input),
            ["hc", "get", addr, "--json"] => {
                if terms.broken.contains(addr) {
                    fail(
                        1,
                        r#"{"error":{"kind":"unavailable","message":"wsl1 is not connected"}}"#,
                    )
                } else if terms.live.contains(addr) {
                    ok(&json!({"address": addr, "state": "live"}).to_string())
                } else if terms.finished.contains(addr) {
                    ok(&json!({"address": addr, "state": "finished"}).to_string())
                } else {
                    fail(
                        3,
                        r#"{"error":{"kind":"not_found","message":"no such terminal"}}"#,
                    )
                }
            }
            _ => fail(127, &format!("偽物が知らないコマンド: {}", a.join(" "))),
        }
    });
    (fake, doc)
}

/// 新しい space (子 A。label の id は sp1・tb1 と被らない)。
fn new_space() -> NewSpace<'static> {
    NewSpace {
        id: "spnew",
        tab: "tbnew",
        name: "A claude-skills: x",
        folder: "/home/u/.herdr/worktrees/claude-skills/x",
        terminal: "t13",
    }
}

// ---- id

#[test]
fn ids_have_the_shape_of_herdr_app_ids() {
    // herdr-app の id と同じく、頭の字と uuid (版 4) の 32 字の hex
    assert_eq!(format_id("sp", 1), "sp00000000000040008000000000000001");
    assert_eq!(
        format_id("tb", u128::MAX),
        "tbffffffffffff4fffbfffffffffffffff"
    );
    let fake = Fake::new(|_| ok(""));
    assert_eq!(new_id(&fake, "sp"), "sp00000000000040008000000000000001");
    assert_eq!(new_id(&fake, "tb"), "tb00000000000040008000000000000002");
    // 本物の乱数は、呼ぶたびに違い、版 4 の形
    let a = format_id("sp", crate::hc::random_u128());
    let b = format_id("sp", crate::hc::random_u128());
    assert_ne!(a, b);
    for id in [&a, &b] {
        assert_eq!(id.len(), 34, "{id}");
        assert!(
            id[2..]
                .bytes()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "{id}"
        );
        assert_eq!(&id[14..15], "4", "{id}");
        assert!(matches!(&id[18..19], "8" | "9" | "a" | "b"), "{id}");
    }
}

// ---- rename (pjp mark name と同じ書き替え。別のマシンの doc も)

#[test]
fn rename_on_another_machine_passes_on() {
    let (f, doc) = world(DocSim::at(host_a_doc(), 40).on("wsl1"), Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        rename(&f, &hc, Some("wsl1"), "wsl1/sp1", "A claude-skills: x"),
        Rename::Renamed { from: 40, to: 41 }
    );
    assert_eq!(
        doc.borrow().space("sp1").unwrap()["name"],
        "A claude-skills: x"
    );
    assert!(rpc_calls(&f).iter().all(|r| r["params"]["on"] == "wsl1"));
    // このマシンなら on を渡さない (偽物が on: None を確かめる)
    let (f, _) = world(DocSim::at(host_a_doc(), 40), Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(rename(&f, &hc, None, "sp1", ""), Rename::Same);
    // 読めないときのわけに、どのマシンの doc かを書く
    let (f, _) = world(DocSim::default().on("wsl1"), Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        rename(&f, &hc, Some("wsl1"), "sp1", "x"),
        Rename::Skip(
            "herdr-app が無く、wsl1 の hc の doc herdr-app もまだ無い (版 0) ので、space sp1 の名前は替えない".to_owned()
        )
    );
}

#[test]
fn name_of_reads_the_current_name() {
    let (f, _) = world(DocSim::at(host_a_doc(), 40), Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(name_of(&hc, None, "sphub").as_deref(), Some("ABC-833 移行"));
    // 名前が空・space が無い・doc が無い
    assert_eq!(name_of(&hc, None, "sp1"), None);
    assert_eq!(name_of(&hc, None, "nosuch"), None);
    let (f, _) = world(DocSim::default(), Terms::default());
    assert_eq!(name_of(&Hc::new(&f), None, "sphub"), None);
}

// ---- ensure (pjp child new・restart)

#[test]
fn ensure_names_the_space_herdr_app_made() {
    // herdr-app が label を見て、doc.get 2 回の後に space を作る
    let mut sim = DocSim::at(host_a_doc(), 40).running(2);
    sim.placed(
        "spnew",
        "tbnew",
        "t13",
        "/home/u/.herdr/worktrees/claude-skills/x",
    );
    let (f, doc) = world(sim, Terms::default());
    let hc = Hc::new(&f);
    let got = ensure(&f, &hc, None, &new_space(), PLACE_POLLS);
    assert_eq!(got, Ensured::Placed(Rename::Renamed { from: 41, to: 42 }));
    let d = doc.borrow();
    let sp = d.space("spnew").unwrap();
    assert_eq!(sp["name"], "A claude-skills: x");
    // herdr-app が作ったもの (folder・tab・ペイン) はそのまま
    assert_eq!(sp["folder"], "/home/u/.herdr/worktrees/claude-skills/x");
    assert_eq!(
        sp["tabs"][0]["root"]["children"][0]["content"]["terminal"],
        "t13"
    );
    assert_eq!(d.space_ids(), ["sp1", "sphub", "spnew"]);
    // 置かれるまで 500ms ずつ待って読み直す (2 回待ち、3 回目で見えた)
    assert_eq!(f.slept(), [POLL_WAIT, POLL_WAIT]);
    assert_eq!(
        rpc_methods(&f),
        ["doc.get", "doc.get", "doc.get", "doc.get", "doc.set"]
    );
}

#[test]
fn ensure_adds_the_space_when_herdr_app_does_not_make_it() {
    // herdr-app が動いていない (label を見る者がいない)
    let (f, doc) = world(DocSim::at(host_a_doc(), 40), Terms::default());
    let hc = Hc::new(&f);
    let got = ensure(&f, &hc, None, &new_space(), PLACE_POLLS);
    assert_eq!(got, Ensured::Added { from: 40, to: 41 });
    assert_eq!(f.slept().len(), (PLACE_POLLS - 1) as usize);
    let d = doc.borrow();
    // herdr-app が新しい space を書く形と同じ形で、末尾に足す (ほかの space はそのまま)
    assert_eq!(d.space_ids(), ["sp1", "sphub", "spnew"]);
    assert_eq!(&d.value["spaces"][0], &host_a_doc()["spaces"][0]);
    assert_eq!(
        d.space("spnew").unwrap(),
        &json!({"folder": "/home/u/.herdr/worktrees/claude-skills/x", "id": "spnew", "name": "A claude-skills: x",
            "tabs": [{"id": "tbnew", "name": "", "root": {
                "children": [{"content": {"terminal": "t13"}, "id": "p00000000000040008000000000000001", "type": "block"}],
                "id": "tbnew", "type": "row"}}]})
    );
}

#[test]
fn ensure_names_the_space_herdr_app_wrote_first() {
    // herdr-app が遅く、待ち終えて足そうとした所で先に書いた (conflict)。読み直すと herdr-app の space があるので、名前だけ付ける
    let mut sim = DocSim {
        conflicts: 1,
        ..DocSim::at(host_a_doc(), 40).running(PLACE_POLLS + 5)
    };
    sim.placed(
        "spnew",
        "tbnew",
        "t13",
        "/home/u/.herdr/worktrees/claude-skills/x",
    );
    let (f, doc) = world(sim, Terms::default());
    let hc = Hc::new(&f);
    let got = ensure(&f, &hc, None, &new_space(), PLACE_POLLS);
    assert_eq!(got, Ensured::Placed(Rename::Renamed { from: 41, to: 42 }));
    let d = doc.borrow();
    // space は 1 つだけで、herdr-app のペイン (pane1) のまま
    assert_eq!(d.space_ids(), ["sp1", "sphub", "spnew"]);
    let sp = d.space("spnew").unwrap();
    assert_eq!(sp["name"], "A claude-skills: x");
    assert_eq!(sp["tabs"][0]["root"]["children"][0]["id"], "pane1");
}

#[test]
fn ensure_renames_an_existing_space_without_the_terminal() {
    // 前の端末の space が残っている (restart で、herdr-app が動いていない)。名前だけそろえ、ペインは herdr-app に任せる
    let mut value = host_a_doc();
    value["spaces"][0]["name"] = json!("");
    let (f, doc) = world(DocSim::at(value, 40), Terms::default());
    let hc = Hc::new(&f);
    let sp = NewSpace {
        id: "sp1",
        tab: "tb1",
        terminal: "t14",
        ..new_space()
    };
    assert_eq!(
        ensure(&f, &hc, None, &sp, 3),
        Ensured::Unplaced(Rename::Renamed { from: 40, to: 41 })
    );
    let d = doc.borrow();
    assert_eq!(d.space("sp1").unwrap()["name"], "A claude-skills: x");
    assert_eq!(
        d.space("sp1").unwrap()["tabs"][0]["root"]["children"][0]["content"]["terminal"],
        "t1"
    );
}

#[test]
fn ensure_does_not_write_a_doc_herdr_app_never_wrote() {
    for (sim, why) in [
        (DocSim::default(), "hc の doc herdr-app もまだ無い (版 0)"),
        (
            DocSim::at(json!({"spaces": "x"}), 3),
            "hc の doc herdr-app の形が違う (spaces の配列が無い)",
        ),
        (
            DocSim {
                get_error: Some("unavailable"),
                ..DocSim::at(host_a_doc(), 40)
            },
            "hc の doc herdr-app を読めない (doc.get: unavailable (see `hc schema`))",
        ),
    ] {
        let (f, _) = world(sim, Terms::default());
        let hc = Hc::new(&f);
        assert_eq!(
            ensure(&f, &hc, None, &new_space(), PLACE_POLLS),
            Ensured::Skip(why.to_owned())
        );
        assert!(rpc_methods(&f).iter().all(|m| m == "doc.get"), "{why}");
    }
}

#[test]
fn ensure_on_another_machine_reads_and_writes_that_doc() {
    let mut sim = DocSim::at(host_a_doc(), 7).on("wsl1").running(0);
    sim.placed("spnew", "tbnew", "t13", "/home/u/x");
    let (f, _) = world(sim, Terms::default());
    let hc = Hc::new(&f);
    let got = ensure(&f, &hc, Some("wsl1"), &new_space(), PLACE_POLLS);
    assert_eq!(got, Ensured::Placed(Rename::Renamed { from: 8, to: 9 }));
    assert!(f.slept().is_empty());
}

#[test]
fn ensure_gives_up_after_conflicts() {
    let (f, doc) = world(
        DocSim {
            conflicts: u32::MAX,
            ..DocSim::at(host_a_doc(), 40)
        },
        Terms::default(),
    );
    let hc = Hc::new(&f);
    let got = ensure(&f, &hc, None, &new_space(), 2);
    assert!(
        matches!(&got, Ensured::Failed(w) if w.contains("5 回とも版が合わない")),
        "{got:?}"
    );
    assert!(doc.borrow().space("spnew").is_none());
}

// ---- remove (pjp child cleanup)

#[test]
fn remove_waits_for_herdr_app_to_drop_the_space() {
    // 子の端末 (t1) を消すと、herdr-app が doc.get 1 回の後に space sp1 を消す (E10)
    let mut sim = DocSim::at(host_a_doc(), 40).running(1);
    sim.removed("t1");
    let (f, doc) = world(sim, Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        remove(&f, &hc, None, "sp1", Some("t1"), GONE_POLLS),
        Removed::Gone
    );
    assert_eq!(doc.borrow().space_ids(), ["sphub"]);
    assert_eq!(rpc_methods(&f), ["doc.get", "doc.get"]);
    assert_eq!(f.slept(), [POLL_WAIT]);
}

#[test]
fn remove_drops_the_space_when_herdr_app_does_not() {
    // herdr-app が動いていない。space に残るのは消した子の端末 (t1) のペインだけ
    let (f, doc) = world(DocSim::at(host_a_doc(), 40), Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        remove(&f, &hc, None, "sp1", Some("t1"), GONE_POLLS),
        Removed::Removed { from: 40, to: 41 }
    );
    let d = doc.borrow();
    assert_eq!(d.space_ids(), ["sphub"]);
    assert_eq!(&d.value["spaces"][0], &host_a_doc()["spaces"][1]);
    assert_eq!(f.slept().len(), (GONE_POLLS - 1) as usize);
    // 子の端末そのものは確かめない (もう消した)
    assert!(
        !f.lines().iter().any(|l| l.starts_with("hc get")),
        "{:?}",
        f.lines()
    );
}

#[test]
fn remove_keeps_the_space_with_other_live_terminals() {
    // ユーザーが同じ space に開いた shell (t29) が生きている。終わった端末 (t30) と消えた端末 (t31) のペインは数えない
    let mut value = host_a_doc();
    let children = value["spaces"][0]["tabs"][0]["root"]["children"]
        .as_array_mut()
        .unwrap();
    for t in ["t29", "t30", "t31"] {
        children.push(json!({"content": {"terminal": t}, "id": format!("p-{t}"), "type": "block"}));
    }
    let (f, doc) = world(
        DocSim::at(value.clone(), 40),
        Terms {
            live: vec!["t29"],
            finished: vec!["t30"],
            ..Terms::default()
        },
    );
    let hc = Hc::new(&f);
    assert_eq!(
        remove(&f, &hc, None, "sp1", Some("t1"), GONE_POLLS),
        Removed::Kept(Others {
            live: vec!["t29".to_owned()],
            unknown: vec![],
        })
    );
    assert_eq!(doc.borrow().value, value);
    assert!(rpc_methods(&f).iter().all(|m| m == "doc.get"));
    // 生きた端末を見つけたら待たない
    assert!(f.slept().is_empty());
}

#[test]
fn remove_keeps_the_space_when_a_terminal_cannot_be_checked() {
    let mut value = host_a_doc();
    value["spaces"][0]["tabs"][0]["root"]["children"]
        .as_array_mut()
        .unwrap()
        .push(json!({"content": {"terminal": "t29"}, "id": "p-t29", "type": "block"}));
    let (f, _) = world(
        DocSim::at(value, 40).on("wsl1"),
        Terms {
            broken: vec!["wsl1/t29"],
            ..Terms::default()
        },
    );
    let hc = Hc::new(&f);
    // 別のマシンの端末は、マシン付きの住所で確かめる。確かめられない端末は、生きている端末と分けて返す
    assert_eq!(
        remove(&f, &hc, Some("wsl1"), "wsl1/sp1", Some("t1"), GONE_POLLS),
        Removed::Kept(Others {
            live: vec![],
            unknown: vec!["t29".to_owned()],
        })
    );
    assert!(
        f.lines().iter().any(|l| l == "hc get wsl1/t29 --json"),
        "{:?}",
        f.lines()
    );
}

#[test]
fn remove_counts_the_ledger_address_when_it_is_someone_else() {
    // 控えの住所 (t1) に別の端末がいる (ended が None)。その端末が space にいれば残す
    let (f, _) = world(
        DocSim::at(host_a_doc(), 40),
        Terms {
            live: vec!["t1"],
            ..Terms::default()
        },
    );
    let hc = Hc::new(&f);
    assert_eq!(
        remove(&f, &hc, None, "sp1", None, GONE_POLLS),
        Removed::Kept(Others {
            live: vec!["t1".to_owned()],
            unknown: vec![],
        })
    );
}

#[test]
fn remove_when_the_space_is_already_gone_or_doc_is_missing() {
    let (f, _) = world(DocSim::at(host_a_doc(), 40), Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        remove(&f, &hc, None, "nosuch", Some("t1"), GONE_POLLS),
        Removed::Gone
    );
    assert!(f.slept().is_empty());
    let (f, _) = world(DocSim::default(), Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        remove(&f, &hc, None, "sp1", Some("t1"), GONE_POLLS),
        Removed::Skip("hc の doc herdr-app もまだ無い (版 0)".to_owned())
    );
}

#[test]
fn remove_reads_again_on_conflict() {
    // 消そうとした所で、ほかの書き手が先に書いた (版だけ進む)。読み直して消す
    let (f, doc) = world(
        DocSim {
            conflicts: 1,
            ..DocSim::at(host_a_doc(), 40)
        },
        Terms::default(),
    );
    let hc = Hc::new(&f);
    assert_eq!(
        remove(&f, &hc, None, "sp1", Some("t1"), 1),
        Removed::Removed { from: 41, to: 42 }
    );
    assert_eq!(doc.borrow().space_ids(), ["sphub"]);
}

#[test]
fn hc_connect_failure_is_a_skip() {
    let fake = Fake::new(|_| Output {
        code: None,
        stdout: String::new(),
        stderr: String::new(),
        timed_out: true,
    });
    let hc = Hc::new(&fake);
    assert_eq!(
        remove(&fake, &hc, None, "sp1", Some("t1"), GONE_POLLS),
        Removed::Skip("hc の doc herdr-app を読めない (時間切れ)".to_owned())
    );
    assert_eq!(
        ensure(&fake, &hc, None, &new_space(), PLACE_POLLS),
        Ensured::Skip("hc の doc herdr-app を読めない (時間切れ)".to_owned())
    );
}

// ---- review の指摘

#[test]
fn ensure_keeps_waiting_through_a_busy_core() {
    // core が 2 回だけ答えない (host-a の hc の registry persistence timed out のような一時の失敗)。待つのをやめない
    let mut sim = DocSim {
        get_fails: 2,
        ..DocSim::at(host_a_doc(), 40).running(0)
    };
    sim.placed("spnew", "tbnew", "t13", "/home/u/x");
    let (f, doc) = world(sim, Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        ensure(&f, &hc, None, &new_space(), PLACE_POLLS),
        Ensured::Placed(Rename::Renamed { from: 41, to: 42 })
    );
    assert_eq!(
        doc.borrow().space("spnew").unwrap()["name"],
        "A claude-skills: x"
    );
    assert_eq!(f.slept(), [POLL_WAIT, POLL_WAIT]);
}

#[test]
fn ensure_waits_for_herdr_app_to_write_the_first_doc() {
    // このマシンの space を herdr-app がまだ置いたことが無い (版 0)。label を見て herdr-app が初めて doc を書くのを待つ
    let mut sim = DocSim::default().running(1);
    sim.placed("spnew", "tbnew", "t13", "/home/u/x");
    let (f, doc) = world(sim, Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        ensure(&f, &hc, None, &new_space(), PLACE_POLLS),
        Ensured::Placed(Rename::Renamed { from: 1, to: 2 })
    );
    assert_eq!(
        doc.borrow().space("spnew").unwrap()["name"],
        "A claude-skills: x"
    );
}

#[test]
fn ensure_does_not_touch_a_terminal_in_another_space() {
    // 子の端末 (t8) が、もうほかの space (sphub) にいる。その space の名前は替えず、space も足さない
    let (f, doc) = world(DocSim::at(host_a_doc(), 40), Terms::default());
    let hc = Hc::new(&f);
    let sp = NewSpace {
        terminal: "t8",
        ..new_space()
    };
    assert_eq!(
        ensure(&f, &hc, None, &sp, 2),
        Ensured::Elsewhere("sphub".to_owned())
    );
    assert_eq!(doc.borrow().value, host_a_doc());
}

#[test]
fn ensure_without_the_terminal_address_writes_nothing() {
    let (f, doc) = world(DocSim::at(host_a_doc(), 40), Terms::default());
    let hc = Hc::new(&f);
    let sp = NewSpace {
        terminal: "",
        ..new_space()
    };
    assert_eq!(
        ensure(&f, &hc, None, &sp, PLACE_POLLS),
        Ensured::Skip("子の端末の住所が分からない".to_owned())
    );
    assert!(rpc_calls(&f).is_empty());
    assert_eq!(doc.borrow().version, 40);
}

#[test]
fn ensure_added_space_is_not_doubled_when_herdr_app_comes_late() {
    // herdr-app が待ち終えた後に label を読んだ。doc に足した space にもう子の端末がいるので、二重に置かない (E7)
    let mut sim = DocSim::at(host_a_doc(), 40).running(PLACE_POLLS + 1);
    sim.placed("spnew", "tbnew", "t13", "/home/u/x");
    let (f, doc) = world(sim, Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        ensure(&f, &hc, None, &new_space(), PLACE_POLLS),
        Ensured::Added { from: 40, to: 41 }
    );
    // もう 1 回読む (遅れた herdr-app が書く番)
    assert_eq!(
        name_of(&hc, None, "spnew").as_deref(),
        Some("A claude-skills: x")
    );
    let d = doc.borrow();
    assert_eq!(d.space_ids(), ["sp1", "sphub", "spnew"]);
    assert_eq!(terminals_of(d.space("spnew").unwrap()), ["t13"]);
    assert_eq!(d.version, 41);
}

#[test]
fn remove_keeps_waiting_through_a_busy_core() {
    let mut sim = DocSim {
        get_fails: 1,
        ..DocSim::at(host_a_doc(), 40).running(0)
    };
    sim.removed("t1");
    let (f, doc) = world(sim, Terms::default());
    let hc = Hc::new(&f);
    assert_eq!(
        remove(&f, &hc, None, "sp1", Some("t1"), GONE_POLLS),
        Removed::Gone
    );
    assert_eq!(doc.borrow().space_ids(), ["sphub"]);
    assert_eq!(f.slept(), [POLL_WAIT]);
}

#[test]
fn others_lists_live_and_unknown_terminals_in_the_space() {
    // cleanup の確かめ (子を終える前): 子 (t1) のほかの端末を、生きている・確かめられないに分ける。終わった・消えた端末は数えない
    let mut value = host_a_doc();
    let children = value["spaces"][0]["tabs"][0]["root"]["children"]
        .as_array_mut()
        .unwrap();
    for t in ["t29", "t30", "t31", "t32"] {
        children.push(json!({"content": {"terminal": t}, "id": format!("p-{t}"), "type": "block"}));
    }
    let (f, _) = world(
        DocSim::at(value, 40),
        Terms {
            live: vec!["t29"],
            finished: vec!["t30"],
            broken: vec!["t32"],
        },
    );
    let hc = Hc::new(&f);
    assert_eq!(
        others(&hc, None, "sp1", Some("t1")),
        Ok(Others {
            live: vec!["t29".to_owned()],
            unknown: vec!["t32".to_owned()],
        })
    );
    // space が無い・doc を読めない
    assert_eq!(
        others(&hc, None, "nosuch", Some("t1")),
        Ok(Others::default())
    );
    let (f, _) = world(DocSim::default(), Terms::default());
    assert!(others(&Hc::new(&f), None, "sp1", Some("t1")).is_err());
}
