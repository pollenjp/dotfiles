//! pjp mark のテスト。hc・herdr-app・このマシンの git を偽物にする。

use std::cell::RefCell;
use std::rc::Rc;

use pjp_core::exit::{CONFIG, OK};
use pjp_core::process::Output;
use serde_json::{Value, json};

use super::*;
use crate::hc::Runner;
use crate::testutil::{Fake, fail, ok};

#[derive(Clone)]
struct Sc {
    labels: Value,
    /// `git rev-parse --path-format=absolute --git-dir --git-common-dir` の答え。
    git_dirs: &'static str,
    hub: bool,
    terminals: Value,
    cwd: &'static str,
    /// このマシンの core の doc herdr-app (`hc connect` の doc.get・doc.set が読み書きする)。
    doc: Rc<RefCell<Doc>>,
}

impl Default for Sc {
    fn default() -> Self {
        Self {
            labels: json!({"herdr.space": "sphub", "herdr.tab": "tbhub"}),
            git_dirs: "/home/u/h/.git/worktrees/w1\n/home/u/h/.git\n",
            hub: true,
            terminals: json!([]),
            cwd: "/home/u/.herdr/worktrees/h/w1",
            doc: Rc::default(),
        }
    }
}

/// 偽の core の doc herdr-app。`hc connect` に書かれた 1 行の要求 (doc.get・doc.set) に、hc 0.1.21 の core と同じ形で答える。
#[derive(Debug, Default)]
struct Doc {
    value: Value,
    version: u64,
    /// この先の doc.set を conflict で断る回数。断るたびに、ほかの書き手 (herdr-app) が先に書いたことにする (版を 1 つ進め、
    /// space sp2 の名前を `替えた<版>` にする)。
    conflicts: u32,
    /// doc.get に返す error の `data.kind` (None なら値を返す)。
    get_error: Option<&'static str>,
    /// doc.set に返す error の `data.kind` (版が合っていても返す)。
    set_error: Option<&'static str>,
    /// `hc connect` そのものの答え (core に届かない・時間切れ。None なら要求に答える)。
    connect: Option<Output>,
}

impl Doc {
    fn at(value: Value, version: u64) -> Self {
        Self {
            value,
            version,
            ..Self::default()
        }
    }

    fn answer(&mut self, input: &str) -> Output {
        if let Some(out) = &self.connect {
            return out.clone();
        }
        let req: Value = serde_json::from_str(input).unwrap();
        let reply = |mut body: Value| {
            body["id"] = req["id"].clone();
            body["jsonrpc"] = json!("2.0");
            ok(&format!("{body}\n"))
        };
        let error = |kind: &str, message: String| {
            reply(
                json!({"error": {"code": -32000, "data": {"kind": kind, "hint": "see `hc schema`"}, "message": message}}),
            )
        };
        let params = &req["params"];
        match req["method"].as_str().unwrap_or_default() {
            "doc.get" => {
                assert_eq!(params, &json!({"name": "herdr-app"}));
                match self.get_error {
                    Some(kind) => error(kind, format!("doc.get: {kind}")),
                    None => {
                        reply(json!({"result": {"value": self.value, "version": self.version}}))
                    }
                }
            }
            "doc.set" => {
                assert_eq!(params["name"], "herdr-app");
                if let Some(kind) = self.set_error {
                    return error(kind, format!("doc.set: {kind}"));
                }
                if self.conflicts > 0 {
                    self.conflicts -= 1;
                    self.version += 1;
                    let version = self.version;
                    for sp in self.value["spaces"].as_array_mut().unwrap() {
                        if sp["id"] == "sp2" {
                            sp["name"] = json!(format!("替えた{version}"));
                        }
                    }
                }
                if params["version"].as_u64() != Some(self.version) {
                    return error(
                        "conflict",
                        format!(
                            "document \"herdr-app\" is at version {}, not {}",
                            self.version, params["version"]
                        ),
                    );
                }
                self.value = params["value"].clone();
                self.version += 1;
                reply(json!({"result": {"version": self.version}}))
            }
            m => reply(
                json!({"error": {"code": -32601, "data": {"kind": "unknown_method"}, "message": format!("unknown method {m:?}")}}),
            ),
        }
    }
}

/// herdr-app が host-a に置いた doc と同じ形の doc (space 3 つ。この端末の space は sphub)。
fn app_doc() -> Value {
    let tab = |tab: &str, pane: &str, terminal: &str| {
        json!({"id": tab, "name": "", "root": {"id": format!("{pane}-root"), "type": "split", "children": [
            {"id": format!("{pane}-col"), "type": "split", "size": {"weight": 0.62}, "children": [
                {"id": pane, "type": "pane", "content": {"terminal": terminal}, "size": {"weight": 1.0}},
            ]},
        ]}})
    };
    json!({"spaces": [
        {"folder": "/home/u/h", "id": "sp1", "name": "", "tabs": [tab("tb1", "pn1", "host-a/t1")]},
        {"folder": "/home/u/.herdr/worktrees/h/w1", "id": "sphub", "name": "w1", "tabs": [tab("tbhub", "pn8", "host-a/t8")]},
        {"folder": "/home/u/.herdr/worktrees/claude-skills/x", "id": "sp2", "name": "A claude-skills: x", "tabs": [tab("tb2", "pn9", "host-a/t9")]},
    ]})
}

fn respond(sc: &Sc, argv: &[String]) -> Output {
    let a: Vec<&str> = argv.iter().map(String::as_str).collect();
    match a.as_slice() {
        // 偽の Runner は stdin の中身を argv の最後に足す
        ["hc", "connect", input] => sc.doc.borrow_mut().answer(input),
        ["hc", "get", addr, ..] => {
            if addr.starts_with("nope") {
                return fail(3, r#"{"error":{"kind":"not_found","message":"no"}}"#);
            }
            ok(&json!({
                "address": addr,
                "name": "hub",
                "state": "live",
                "labels": sc.labels,
                "parent": null,
                "cwd": sc.cwd,
                "status": {"state": "idle"},
            })
            .to_string())
        }
        ["hc", "label", ..] => ok("{}"),
        ["hc", "ls", ..] => ok(&json!({"terminals": sc.terminals}).to_string()),
        ["herdr-app", "do", ..] => ok("{}"),
        ["git", "-C", _, "rev-parse", ..] => ok(sc.git_dirs),
        ["git", "-C", _, "config", "--get", "pjp.devtracker.repo"] => {
            if sc.hub {
                ok("~/h\n")
            } else {
                fail(1, "")
            }
        }
        ["git", "-C", _, "remote"] => ok(if sc.hub { "" } else { "origin\n" }),
        _ => fail(127, &format!("偽物が知らないコマンド: {}", a.join(" "))),
    }
}

fn fake(sc: Sc) -> Fake {
    let cwd = std::path::PathBuf::from(sc.cwd);
    Fake::new(move |argv| respond(&sc, argv))
        .env("HC_TERMINAL_ID", "t8")
        .cwd(&cwd)
}

fn run(f: &Fake, args: &[&str]) -> (u8, String, String) {
    let args: Vec<String> = args.iter().map(|s| (*s).to_owned()).collect();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = main(f, &args, &mut out, &mut err);
    (
        code,
        String::from_utf8(out).unwrap(),
        String::from_utf8(err).unwrap(),
    )
}

fn calls_of(f: &Fake, program: &str) -> Vec<Vec<String>> {
    f.calls().into_iter().filter(|c| c[0] == program).collect()
}

#[test]
fn name_renames_space_and_labels() {
    let f = fake(Sc::default());
    let (code, out, err) = run(&f, &["name", "ABC-681 Windows体制"]);
    assert_eq!(code, OK, "{err}");
    assert!(f.calls().iter().any(|c| c
        == &[
            "hc",
            "label",
            "t8",
            "pjp.ticket=ABC-681",
            "pjp.role=hub",
            "--json"
        ]));
    let app = calls_of(&f, "herdr-app");
    assert_eq!(app.len(), 1);
    assert_eq!(app[0][2], "space.rename");
    assert_eq!(
        serde_json::from_str::<Value>(&app[0][3]).unwrap(),
        json!({"id": "sphub", "name": "ABC-681 Windows体制"})
    );
    assert!(
        out.contains("t8: label pjp.ticket=ABC-681 pjp.role=hub を付けた"),
        "{out}"
    );
    assert!(
        out.contains("t8: space sphub の名前を ABC-681 Windows体制 にした"),
        "{out}"
    );
    // herdr-app があるマシン (Windows のハブ) では hc の doc を読まない
    assert!(rpc_calls(&f).is_empty(), "{:?}", f.calls());
}

/// `hc connect` に書いた要求 (偽の Runner は stdin の中身を argv の最後に足す)。
fn rpc_calls(f: &Fake) -> Vec<Value> {
    calls_of(f, "hc")
        .into_iter()
        .filter(|c| c[1] == "connect")
        .map(|c| serde_json::from_str(&c[2]).unwrap())
        .collect()
}

fn rpc_methods(f: &Fake) -> Vec<String> {
    rpc_calls(f)
        .iter()
        .map(|r| r["method"].as_str().unwrap_or_default().to_owned())
        .collect()
}

/// herdr-app の無いマシン (host-a・wsl1) の偽物。doc を後から読むために、doc の控えも返す。
fn no_app(doc: Doc) -> (Fake, Rc<RefCell<Doc>>) {
    let doc = Rc::new(RefCell::new(doc));
    let f = fake(Sc {
        doc: Rc::clone(&doc),
        ..Sc::default()
    })
    .without("herdr-app");
    (f, doc)
}

#[test]
fn name_without_herdr_app_renames_the_space_in_hc_doc() {
    let (f, doc) = no_app(Doc::at(app_doc(), 66));
    let (code, out, err) = run(&f, &["name", "ABC-681 Windows体制"]);
    assert_eq!(code, OK, "{err}");
    assert_eq!(err, "");
    assert_eq!(rpc_methods(&f), ["doc.get", "doc.set"]);
    // 読んだ版で書く
    assert_eq!(rpc_calls(&f)[1]["params"]["version"], 66);
    // この端末の space (label herdr.space) の name だけが替わり、ほか (ほかの space・tab・ペイン) は読んだまま
    let mut want = app_doc();
    want["spaces"][1]["name"] = json!("ABC-681 Windows体制");
    assert_eq!(doc.borrow().value, want);
    assert_eq!(doc.borrow().version, 67);
    assert!(
        out.contains("t8: label pjp.ticket=ABC-681 pjp.role=hub を付けた"),
        "{out}"
    );
    assert!(
        out.contains("t8: space sphub の名前を ABC-681 Windows体制 にした (hc の doc herdr-app を書いた。版 66 → 67)"),
        "{out}"
    );
}

#[test]
fn name_in_hc_doc_reads_again_and_retries_on_conflict() {
    // herdr-app が間に 2 回書いた (sp2 の名前を替えた)
    let (f, doc) = no_app(Doc {
        conflicts: 2,
        ..Doc::at(app_doc(), 66)
    });
    let (code, out, err) = run(&f, &["name", "ABC-681 x"]);
    assert_eq!(code, OK, "{err}");
    assert_eq!(err, "");
    assert_eq!(
        rpc_methods(&f),
        [
            "doc.get", "doc.set", "doc.get", "doc.set", "doc.get", "doc.set"
        ]
    );
    // 打ち直すたびに読み直し、その版で書く
    let set_versions: Vec<u64> = rpc_calls(&f)
        .iter()
        .filter(|r| r["method"] == "doc.set")
        .map(|r| r["params"]["version"].as_u64().unwrap())
        .collect();
    assert_eq!(set_versions, [66, 67, 68]);
    // ほかの書き手が替えた所を、読み直す前の値で書き戻さない
    let d = doc.borrow();
    assert_eq!(d.value["spaces"][2]["name"], "替えた68");
    assert_eq!(d.value["spaces"][1]["name"], "ABC-681 x");
    assert_eq!(d.version, 69);
    assert!(out.contains("版 68 → 69"), "{out}");
    // 打ち直す前に少し待つ
    assert_eq!(f.slept().len(), 2, "{:?}", f.slept());
}

#[test]
fn name_in_hc_doc_gives_up_after_five_conflicts() {
    let (f, doc) = no_app(Doc {
        conflicts: u32::MAX,
        ..Doc::at(app_doc(), 66)
    });
    let (code, out, err) = run(&f, &["name", "ABC-681 x"]);
    // label を付けた後の名前の失敗は、herdr-app で替えられないときと同じく !! を出して 0
    assert_eq!(code, OK);
    let sets = rpc_methods(&f).iter().filter(|m| *m == "doc.set").count();
    assert_eq!(sets, 5);
    assert!(
        err.contains("!! space sphub の名前を替えられない (hc の doc herdr-app: "),
        "{err}"
    );
    assert_eq!(doc.borrow().value["spaces"][1]["name"], "w1");
    assert!(!out.contains("にした"), "{out}");
    assert!(out.contains("pjp.ticket=ABC-681"), "{out}");
}

#[test]
fn name_in_hc_doc_notes_when_the_space_is_not_in_doc() {
    let mut value = app_doc();
    value["spaces"].as_array_mut().unwrap().remove(1);
    let (f, doc) = no_app(Doc::at(value, 66));
    let (code, out, err) = run(&f, &["name", "ABC-681 x"]);
    assert_eq!(code, OK);
    assert_eq!(rpc_methods(&f), ["doc.get"]);
    assert_eq!(doc.borrow().version, 66);
    assert_eq!(
        err,
        "note: herdr-app が無く、hc の doc herdr-app に space sphub が無いので、名前は替えない\n"
    );
    // label は付ける
    assert!(
        out.contains("t8: label pjp.ticket=ABC-681 pjp.role=hub を付けた"),
        "{out}"
    );
}

#[test]
fn name_in_hc_doc_notes_when_doc_is_not_written_yet() {
    let (f, _) = no_app(Doc::default());
    let (code, out, err) = run(&f, &["name", "ABC-681 x"]);
    assert_eq!(code, OK);
    assert_eq!(rpc_methods(&f), ["doc.get"]);
    assert_eq!(
        err,
        "note: herdr-app が無く、hc の doc herdr-app もまだ無い (版 0) ので、space sphub の名前は替えない\n"
    );
    assert!(out.contains("pjp.ticket=ABC-681"), "{out}");
}

#[test]
fn name_in_hc_doc_notes_when_hc_does_not_answer() {
    let cases: [(Doc, &str); 3] = [
        (
            Doc {
                connect: Some(fail(
                    1,
                    r#"{"error":{"kind":"unavailable","message":"core does not answer"}}"#,
                )),
                ..Doc::at(app_doc(), 66)
            },
            "note: herdr-app が無く、hc の doc herdr-app を読めない (core does not answer) ので、space sphub の名前は替えない\n",
        ),
        (
            Doc {
                connect: Some(Output {
                    code: None,
                    stdout: String::new(),
                    stderr: String::new(),
                    timed_out: true,
                }),
                ..Doc::at(app_doc(), 66)
            },
            "note: herdr-app が無く、hc の doc herdr-app を読めない (時間切れ) ので、space sphub の名前は替えない\n",
        ),
        (
            Doc {
                get_error: Some("unknown_method"),
                ..Doc::at(app_doc(), 66)
            },
            "note: herdr-app が無く、hc が doc.get を知らない (doc.get: unknown_method (see `hc schema`)) ので、space sphub の名前は替えない\n",
        ),
    ];
    for (doc, want) in cases {
        let (f, _) = no_app(doc);
        let (code, out, err) = run(&f, &["name", "ABC-681 x"]);
        assert_eq!(code, OK, "{want}");
        assert_eq!(err, want);
        assert!(rpc_methods(&f).iter().all(|m| m != "doc.set"));
        assert!(out.contains("pjp.ticket=ABC-681"), "{out}");
    }
}

#[test]
fn name_in_hc_doc_does_not_write_the_same_name() {
    let mut value = app_doc();
    value["spaces"][1]["name"] = json!("ABC-681 x");
    let (f, doc) = no_app(Doc::at(value, 66));
    let (code, out, err) = run(&f, &["name", "ABC-681 x"]);
    assert_eq!((code, err.as_str()), (OK, ""));
    assert_eq!(rpc_methods(&f), ["doc.get"]);
    assert_eq!(doc.borrow().version, 66);
    assert!(
        out.contains("t8: space sphub の名前はもう ABC-681 x (hc の doc herdr-app は書き替えない)"),
        "{out}"
    );
}

#[test]
fn name_in_hc_doc_reports_other_set_errors_without_retry() {
    let (f, doc) = no_app(Doc {
        set_error: Some("invalid_params"),
        ..Doc::at(app_doc(), 66)
    });
    let (code, _, err) = run(&f, &["name", "ABC-681 x"]);
    assert_eq!(code, OK);
    assert_eq!(rpc_methods(&f), ["doc.get", "doc.set"]);
    assert_eq!(
        err,
        "!! space sphub の名前を替えられない (hc の doc herdr-app: doc.set: invalid_params (see `hc schema`))\n"
    );
    assert_eq!(doc.borrow().version, 66);
}

#[test]
fn name_in_hc_doc_notes_odd_docs() {
    let mut twice = app_doc();
    let again = twice["spaces"][1].clone();
    twice["spaces"].as_array_mut().unwrap().push(again);
    let cases = [
        (
            twice,
            "note: herdr-app が無く、hc の doc herdr-app に space sphub が 2 つあるので、名前は替えない\n",
        ),
        (
            json!({"spaces": "sphub"}),
            "note: herdr-app が無く、hc の doc herdr-app の形が違う (spaces の配列が無い) ので、space sphub の名前は替えない\n",
        ),
        (
            json!("{\"spaces\":[]}"),
            "note: herdr-app が無く、hc の doc herdr-app の形が違う (spaces の配列が無い) ので、space sphub の名前は替えない\n",
        ),
    ];
    for (value, want) in cases {
        let (f, _) = no_app(Doc::at(value, 66));
        let (code, _, err) = run(&f, &["name", "ABC-681 x"]);
        assert_eq!(code, OK);
        assert_eq!(err, want);
        assert_eq!(rpc_methods(&f), ["doc.get"]);
    }
}

#[test]
fn name_without_herdr_app_still_skips_child_checkout_and_spaceless_terminals() {
    let cases = [
        (
            Sc {
                labels: json!({"herdr.space": "sp2", "pjp.role": "child", "pjp.letter": "A"}),
                ..Sc::default()
            },
            "子の space の名前は親が付けたもの",
        ),
        (
            Sc {
                git_dirs: "/home/u/h/.git\n/home/u/h/.git\n",
                ..Sc::default()
            },
            "repo の checkout・repo の外の space",
        ),
        (
            Sc {
                labels: json!({}),
                ..Sc::default()
            },
            "この端末は herdr-app の space に入っていない",
        ),
    ];
    for (sc, why) in cases {
        let doc = Rc::new(RefCell::new(Doc::at(app_doc(), 66)));
        let f = fake(Sc {
            doc: Rc::clone(&doc),
            ..sc
        })
        .without("herdr-app");
        let (code, out, err) = run(&f, &["name", "ABC-700 x"]);
        assert_eq!((code, err.as_str()), (OK, ""), "{why}");
        assert!(out.contains(why), "{out}");
        assert!(rpc_calls(&f).is_empty(), "{why}: {:?}", f.calls());
        assert_eq!(doc.borrow().version, 66);
    }
}

#[test]
fn name_keeps_labels_already_set() {
    let f = fake(Sc {
        labels: json!({"herdr.space": "sphub", "pjp.ticket": "ABC-681", "pjp.role": "hub"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["name", "ABC-681 主題を直した"]);
    assert_eq!(code, OK);
    assert!(
        calls_of(&f, "hc").iter().all(|c| c[1] != "label"),
        "{:?}",
        f.calls()
    );
    assert!(out.contains("名前を ABC-681 主題を直した にした"), "{out}");
}

#[test]
fn name_skips_child_space() {
    let f = fake(Sc {
        labels: json!({"herdr.space": "sp1", "pjp.role": "child", "pjp.letter": "A"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["name", "ABC-700 子の主題"]);
    assert_eq!(code, OK);
    // 子もチケットの印は付ける (pjp child ls に出る)。名前は替えない
    assert!(
        f.calls()
            .iter()
            .any(|c| c == &["hc", "label", "t8", "pjp.ticket=ABC-700", "--json"])
    );
    assert!(calls_of(&f, "herdr-app").is_empty());
    assert!(out.contains("子の space の名前は親が付けたもの"), "{out}");
}

#[test]
fn name_skips_checkout_space() {
    let f = fake(Sc {
        git_dirs: "/home/u/h/.git\n/home/u/h/.git\n",
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["name", "ABC-681 x"]);
    assert_eq!(code, OK);
    assert!(calls_of(&f, "herdr-app").is_empty());
    assert!(out.contains("repo の checkout・repo の外の space"), "{out}");
}

#[test]
fn name_outside_hub_does_not_mark_hub() {
    let f = fake(Sc {
        hub: false,
        ..Sc::default()
    });
    let (code, _, _) = run(&f, &["name", "ABC-5 x"]);
    assert_eq!(code, OK);
    assert!(
        f.calls()
            .iter()
            .any(|c| c == &["hc", "label", "t8", "pjp.ticket=ABC-5", "--json"])
    );
}

#[test]
fn name_rejects_marks_and_empty() {
    let f = fake(Sc::default());
    for bad in ["🌳[2] x", " 🌱 x", "❓ x", "🎬 x", "", "a\nb"] {
        let (code, _, err) = run(&f, &["name", bad]);
        assert_eq!(code, CONFIG, "{bad:?}: {err}");
    }
    assert!(calls_of(&f, "herdr-app").is_empty());
    assert!(
        f.calls()
            .iter()
            .all(|c| c.get(1).is_none_or(|s| s != "label"))
    );
}

#[test]
fn name_without_ticket_sets_only_role() {
    let f = fake(Sc::default());
    let (code, _, _) = run(&f, &["name", "相談"]);
    assert_eq!(code, OK);
    assert!(
        f.calls()
            .iter()
            .any(|c| c == &["hc", "label", "t8", "pjp.role=hub", "--json"])
    );
}

#[test]
fn finished_sets_label_once() {
    let f = fake(Sc::default());
    let want = f.now().unwrap().to_jst().iso_minutes();
    let (code, out, _) = run(&f, &["finished"]);
    assert_eq!(code, OK);
    let label = format!("pjp.finished={want}");
    assert!(
        f.calls()
            .iter()
            .any(|c| c == &["hc", "label", "t8", label.as_str(), "--json"]),
        "{:?}",
        f.calls()
    );
    assert!(
        out.contains(&format!("t8: 済んだと控えた ({label})")),
        "{out}"
    );

    let f = fake(Sc {
        labels: json!({"pjp.finished": "2026-11-15T23:10+09:00"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["finished"]);
    assert_eq!(code, OK);
    assert!(calls_of(&f, "hc").iter().all(|c| c[1] != "label"));
    assert!(
        out.contains("もう済んだと控えてある (pjp.finished=2026-11-15T23:10+09:00)"),
        "{out}"
    );
}

#[test]
fn finished_skips_checkout_conversation() {
    let f = fake(Sc {
        git_dirs: "/home/u/h/.git\n/home/u/h/.git\n",
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["finished"]);
    assert_eq!(code, OK);
    assert!(calls_of(&f, "hc").iter().all(|c| c[1] != "label"));
    assert!(out.contains("worktree の会話ではない"), "{out}");
}

#[test]
fn unfinished_removes_label() {
    let f = fake(Sc {
        labels: json!({"pjp.finished": "2026-11-15T23:10+09:00"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["unfinished"]);
    assert_eq!(code, OK);
    assert!(
        f.calls()
            .iter()
            .any(|c| c == &["hc", "label", "t8", "pjp.finished=", "--json"])
    );
    assert!(out.contains("t8: 済んだの控えを消した"), "{out}");
    // 無ければ何もしない
    let f = fake(Sc::default());
    let (code, out, _) = run(&f, &["unfinished"]);
    assert_eq!((code, out.as_str()), (OK, ""));
}

#[test]
fn checkout_targets_local_terminals_under_path() {
    let f = fake(Sc {
        terminals: json!([
            {"address": "t5", "cwd": "/home/u/wt/sub"},
            {"address": "t7", "cwd": "/home/u/wt"},
            {"address": "wsl1/t9", "cwd": "/home/u/wt"},
            {"address": "t6", "cwd": "/home/u/wt2"},
        ]),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["unfinished", "--checkout", "/home/u/wt/"]);
    assert_eq!(code, OK);
    let gets: Vec<String> = calls_of(&f, "hc")
        .into_iter()
        .filter(|c| c[1] == "get")
        .map(|c| c[2].clone())
        .collect();
    assert_eq!(gets, ["t5", "t7"]);
    assert_eq!(out, "");
    // --terminal と --checkout は一緒に渡さない
    let (code, _, _) = run(&f, &["finished", "--terminal", "t5", "--checkout", "/x"]);
    assert_eq!(code, CONFIG);
}

#[test]
fn finished_on_missing_terminal_is_quiet() {
    let f = fake(Sc::default());
    let (code, out, _) = run(&f, &["finished", "--terminal", "nope1"]);
    assert_eq!(code, OK);
    assert!(out.contains("nope1: hc に端末が無い"), "{out}");
}

#[test]
fn show_prints_labels() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.ticket": "ABC-681", "herdr.space": "sp9"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["show"]);
    assert_eq!(code, OK);
    assert!(out.starts_with("t8 (名前 hub)\n"), "{out}");
    assert!(out.contains("  pjp.role: hub\n  pjp.ticket: ABC-681\n  pjp.letter: -\n  pjp.finished: -\n  pjp.asking: -\n  pjp.asked: -\n  herdr.space: sp9"), "{out}");
    assert!(out.contains("  状態: idle"), "{out}");
}

#[test]
fn show_prints_videos_of_the_terminal_and_its_descendants() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub",
            "pjp.video.20261116090000": r#"{"name":"ABC-1 短尺 x","state":"making","started":"2026-11-16T09:00:00+09:00"}"#}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["show"]);
    assert_eq!(code, OK);
    assert!(
        out.contains("  動画 (この端末と子孫。space の行の 3 行目から 1 本 1 行): 1 本\n    🎬⏳:ABC-1 短尺 x (t8・11/16 09:00 から作っている)\n"),
        "{out}"
    );
    // 動画が無ければ 1 行
    let f = fake(Sc::default());
    let (_, out, _) = run(&f, &["show"]);
    assert!(out.ends_with("  動画: -\n"), "{out}");
}

#[test]
fn usage_lists_video() {
    let f = fake(Sc::default());
    let (_, out, _) = run(&f, &["--help"]);
    assert!(out.contains("pjp mark video start '<名前>'"), "{out}");
    assert!(out.contains("pjp mark video watched"), "{out}");
    assert!(out.contains("🎬) で始めない"), "{out}");
    let (code, _, err) = run(&f, &["nope"]);
    assert_eq!(code, CONFIG);
    assert!(err.contains("show・video・hook"), "{err}");
}

#[test]
fn show_prints_asking() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.asking": "案 A と B のどちらで進めるか"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["show"]);
    assert_eq!(code, OK);
    assert!(
        out.contains("  pjp.asking: 案 A と B のどちらで進めるか\n"),
        "{out}"
    );
}

fn label_calls(f: &Fake) -> Vec<Vec<String>> {
    calls_of(f, "hc")
        .into_iter()
        .filter(|c| c[1] == "label")
        .collect()
}

#[test]
fn asking_sets_label() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "herdr.space": "sphub"}),
        ..Sc::default()
    });
    let (code, out, err) = run(&f, &["asking", "案 A と B のどちらで進めるか"]);
    assert_eq!(code, OK, "{err}");
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "t8",
            "pjp.asking=案 A と B のどちらで進めるか",
            "--json"
        ]]
    );
    assert_eq!(
        out,
        "t8: 答えを待つ印を付けた (pjp.asking=案 A と B のどちらで進めるか)\n"
    );
    assert_eq!(err, "");
}

#[test]
fn asking_again_replaces_or_keeps_the_summary() {
    let labels = json!({"pjp.role": "hub", "pjp.asking": "PR #195 を merge してよいか"});
    // 違う要旨なら替える
    let f = fake(Sc {
        labels: labels.clone(),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["asking", "PR #196 も merge してよいか"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "t8",
            "pjp.asking=PR #196 も merge してよいか",
            "--json"
        ]]
    );
    assert_eq!(
        out,
        "t8: 答えを待つ印の要旨を替えた (pjp.asking=PR #196 も merge してよいか。前は PR #195 を merge してよいか)\n"
    );
    // 同じ要旨なら打たない
    let f = fake(Sc {
        labels,
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["asking", " PR #195 を merge してよいか "]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty(), "{:?}", f.calls());
    assert_eq!(
        out,
        "t8: もう同じ問いで控えてある (pjp.asking=PR #195 を merge してよいか)\n"
    );
}

#[test]
fn asking_trims_and_rejects_bad_summaries() {
    let f = fake(Sc::default());
    for bad in ["", "   ", "一行目\n二行目", "a\tb"] {
        let (code, _, err) = run(&f, &["asking", bad]);
        assert_eq!(code, CONFIG, "{bad:?}: {err}");
    }
    // 要旨は 1 つだけ
    assert_eq!(run(&f, &["asking"]).0, CONFIG);
    assert_eq!(run(&f, &["asking", "a", "b"]).0, CONFIG);
    assert!(label_calls(&f).is_empty(), "{:?}", f.calls());
    // 前後の空白は落として付ける
    let (code, _, _) = run(&f, &["asking", "  どちらにするか  "]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.asking=どちらにするか", "--json"]]
    );
}

#[test]
fn asking_takes_terminal_option() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub"}),
        ..Sc::default()
    });
    let (code, out, err) = run(&f, &["asking", "どちらにするか", "--terminal", "wsl1/t9"]);
    assert_eq!(code, OK);
    assert_eq!(err, "");
    assert!(
        calls_of(&f, "hc")
            .iter()
            .any(|c| c[1] == "get" && c[2] == "wsl1/t9")
    );
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "wsl1/t9",
            "pjp.asking=どちらにするか",
            "--json"
        ]]
    );
    assert!(out.starts_with("wsl1/t9: 答えを待つ印を付けた"), "{out}");
    // --checkout は受けない (問いを出すのは 1 つの会話)
    let (code, _, _) = run(&f, &["asking", "x", "--checkout", "/home/u/wt"]);
    assert_eq!(code, CONFIG);
}

#[test]
fn asking_on_missing_terminal_fails() {
    let f = fake(Sc::default());
    let (code, _, err) = run(&f, &["asking", "x", "--terminal", "nope1"]);
    assert_eq!(code, pjp_core::exit::FAILURE);
    assert!(err.contains("hc に端末 nope1 がありません"), "{err}");
    assert!(label_calls(&f).is_empty());
}

#[test]
fn asking_notes_when_terminal_has_no_role() {
    // pjp.role の無い端末は、子がいなければ pjp-spaces が行を 2 行にしない (印が出ない)。付けはする
    let f = fake(Sc {
        labels: json!({"herdr.space": "sphub"}),
        ..Sc::default()
    });
    let (code, out, err) = run(&f, &["asking", "どちらにするか"]);
    assert_eq!(code, OK);
    assert_eq!(label_calls(&f).len(), 1);
    assert!(out.contains("答えを待つ印を付けた"), "{out}");
    assert!(err.contains("pjp.role が無い"), "{err}");
    assert!(err.contains("pjp mark name"), "{err}");
}

#[test]
fn asking_notes_when_terminal_is_a_child() {
    // 子は親 (指揮役) に聞くので、ふつうは打たない。ユーザーが子の space で子と直に話すこともあるので、断らずに付ける
    let f = fake(Sc {
        labels: json!({"pjp.role": "child", "pjp.letter": "A"}),
        ..Sc::default()
    });
    let (code, out, err) = run(&f, &["asking", "どちらにするか"]);
    assert_eq!(code, OK);
    assert_eq!(label_calls(&f).len(), 1);
    assert!(out.contains("答えを待つ印を付けた"), "{out}");
    assert!(err.contains("子の会話 (pjp.role=child)"), "{err}");
}

#[test]
fn asking_notes_when_summary_is_long() {
    // 長い要旨も付けるが、pjp-spaces のホバーでは 60 字で切れる
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub"}),
        ..Sc::default()
    });
    let long = "あ".repeat(61);
    let (code, _, err) = run(&f, &["asking", &long]);
    assert_eq!(code, OK);
    let label = format!("pjp.asking={long}");
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", label.as_str(), "--json"]]
    );
    assert!(err.contains("要旨が長い (61 字)"), "{err}");
    // 60 字までは何も言わない
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub"}),
        ..Sc::default()
    });
    let (code, _, err) = run(&f, &["asking", &"あ".repeat(60)]);
    assert_eq!((code, err.as_str()), (OK, ""));
}

#[test]
fn asking_replaces_a_blank_old_value_as_new() {
    // 手で付けた空白だけの値は無いとみなし、付け直す (pjp-spaces も ❓ を出さない値)
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.asking": "  "}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["asking", "どちらにするか"]);
    assert_eq!(code, OK);
    assert_eq!(label_calls(&f).len(), 1);
    assert_eq!(
        out,
        "t8: 答えを待つ印を付けた (pjp.asking=どちらにするか)\n"
    );
}

#[test]
fn asking_and_answered_outside_hc_terminal_are_config_errors() {
    let f = fake(Sc::default()).env("HC_TERMINAL_ID", "");
    for args in [&["asking", "x"][..], &["answered"][..]] {
        let (code, _, err) = run(&f, args);
        assert_eq!(code, CONFIG, "{args:?}");
        assert!(err.contains("hc の端末の外"), "{args:?}: {err}");
    }
    assert!(label_calls(&f).is_empty());
}

#[test]
fn asking_takes_a_summary_starting_with_dash_after_double_dash() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub"}),
        ..Sc::default()
    });
    // 空白の無い - で始まる 1 語は option とみなされる
    assert_eq!(run(&f, &["asking", "--no-verify?"]).0, CONFIG);
    let (code, _, _) = run(&f, &["asking", "--", "--no-verify?"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.asking=--no-verify?", "--json"]]
    );
}

#[test]
fn answered_removes_label() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.asking": "どちらにするか"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["answered"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.asking=", "--json"]]
    );
    assert_eq!(
        out,
        "t8: 答えを待つ印を外した (pjp.asking=どちらにするか)\n"
    );
    // 無ければ何もしない (問いを出さずに答えを受けたときも、そのまま打ってよい)
    let f = fake(Sc::default());
    let (code, out, _) = run(&f, &["answered"]);
    assert_eq!((code, out.as_str()), (OK, ""));
    assert!(label_calls(&f).is_empty());
    // 端末が無ければ何もしない
    let (code, out, _) = run(&f, &["answered", "--terminal", "nope1"]);
    assert_eq!((code, out.as_str()), (OK, ""));
    // 余分な引数・--checkout は断る
    assert_eq!(run(&f, &["answered", "x"]).0, CONFIG);
    assert_eq!(run(&f, &["answered", "--checkout", "/x"]).0, CONFIG);
}

#[test]
fn asking_also_clears_asked() {
    // 新しい問いを出したら、前の答えの後始末は済んだとみる (hook が残した pjp.asked も 1 回の hc label で外す)
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.asked": "前の問い"}),
        ..Sc::default()
    });
    let (code, out, err) = run(&f, &["asking", "新しい問い"]);
    assert_eq!(code, OK, "{err}");
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "t8",
            "pjp.asking=新しい問い",
            "pjp.asked=",
            "--json"
        ]]
    );
    assert!(
        out.contains("t8: 答えを待つ印を付けた (pjp.asking=新しい問い)\n"),
        "{out}"
    );
    assert!(
        out.contains("t8: 答えが届いた問いの控えを外した (pjp.asked=前の問い)\n"),
        "{out}"
    );
}

#[test]
fn asking_same_summary_still_clears_asked() {
    // hook が外した問いを、まだ待つので同じ要旨で付け直すとき (pjp.asking は今のまま、pjp.asked だけ外す)
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.asking": "X", "pjp.asked": "Y"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["asking", "X"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.asked=", "--json"]]
    );
    assert!(
        out.contains("もう同じ問いで控えてある (pjp.asking=X)"),
        "{out}"
    );
    assert!(
        out.contains("答えが届いた問いの控えを外した (pjp.asked=Y)"),
        "{out}"
    );
}

#[test]
fn answered_clears_both_in_one_call() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.asking": "A", "pjp.asked": "B"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["answered"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.asking=", "pjp.asked=", "--json"]]
    );
    assert_eq!(
        out,
        "t8: 答えを待つ印を外した (pjp.asking=A)\nt8: 答えが届いた問いの控えを外した (pjp.asked=B)\n"
    );
    // pjp.asked だけ (答えが届いて hook が pjp.asking を外した後に、Claude が打つ answered)
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.asked": "B"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["answered"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.asked=", "--json"]]
    );
    assert_eq!(out, "t8: 答えが届いた問いの控えを外した (pjp.asked=B)\n");
}

#[test]
fn show_prints_asked() {
    let f = fake(Sc {
        labels: json!({"pjp.role": "hub", "pjp.asked": "案 A"}),
        ..Sc::default()
    });
    let (code, out, _) = run(&f, &["show"]);
    assert_eq!(code, OK);
    assert!(
        out.contains("  pjp.asking: -\n  pjp.asked: 案 A\n  herdr.space:"),
        "{out}"
    );
}

#[test]
fn usage_lists_asking_and_answered() {
    let f = fake(Sc::default());
    let (code, out, _) = run(&f, &["--help"]);
    assert_eq!(code, OK);
    assert!(out.contains("pjp mark asking '<問いの要旨>'"), "{out}");
    assert!(out.contains("pjp mark answered"), "{out}");
    assert!(out.contains("❓"), "{out}");
    // - で始まる要旨の渡し方と、答えの届き方 (Notion のコメントも)
    assert!(out.contains("pjp mark asking -- "), "{out}");
    assert!(out.contains("Notion のコメント"), "{out}");
    // herdr-app の無いマシンの name の替え方
    assert!(out.contains("hc の doc herdr-app"), "{out}");
    // 知らないサブコマンドの文にも並べる
    let (code, _, err) = run(&f, &["nope"]);
    assert_eq!(code, CONFIG);
    assert!(err.contains("asking・answered"), "{err}");
}

#[test]
fn outside_hc_terminal_is_config_error() {
    let f = fake(Sc::default()).env("HC_TERMINAL_ID", "");
    let (code, _, err) = run(&f, &["name", "ABC-1 x"]);
    assert_eq!(code, CONFIG);
    assert!(err.contains("hc の端末の外"), "{err}");
    assert_eq!(run(&f, &["nope"]).0, CONFIG);
}

#[test]
fn ticket_ids() {
    assert_eq!(ticket_of("ABC-683 hc 版"), Some("ABC-683"));
    assert_eq!(ticket_of("WRK-ABC-12 x"), Some("WRK-ABC-12"));
    assert_eq!(ticket_of("ABC-683"), Some("ABC-683"));
    assert_eq!(ticket_of("abc-1 x"), None);
    assert_eq!(ticket_of("TKT- x"), None);
    assert_eq!(ticket_of("ABC-12a x"), None);
    assert_eq!(ticket_of("相談"), None);
    assert_eq!(ticket_of("AB1-2 x"), Some("AB1-2"));
    assert_eq!(ticket_of("A-1B-2 x"), None);
}

#[test]
fn name_adopts_children_ledgered_by_terminal() {
    let f = fake(Sc::default());
    let dir = f.state_dir().unwrap().join("children");
    let early = crate::ledger::Ledger::open(&dir, "t-t8").unwrap();
    early.reserve(|_| crate::ledger::Row::default()).unwrap();
    let (code, out, _) = run(&f, &["name", "ABC-681 主題"]);
    assert_eq!(code, OK);
    assert!(
        out.contains("t8: 子の控えを t-t8 から ABC-681 へ移した"),
        "{out}"
    );
    let moved = crate::ledger::Ledger::open(&dir, "ABC-681").unwrap();
    // 前に振った A を使い回さない
    assert_eq!(moved.peek_next().unwrap(), "B");
    assert!(!early.path().exists());
}

#[test]
fn tell_matches_finished_and_unfinished() {
    // pjp ticket が Status を書いた後の口 (spec §8.4): finished・unfinished と同じ動き
    let f = fake(Sc::default());
    let want = f.now().unwrap().to_jst().iso_minutes();
    let mut out = Vec::new();
    tell(&f, "t8", true, &mut out).unwrap();
    let label = format!("pjp.finished={want}");
    assert!(
        f.calls()
            .iter()
            .any(|c| c == &["hc", "label", "t8", label.as_str(), "--json"]),
        "{:?}",
        f.calls()
    );
    assert_eq!(
        String::from_utf8(out).unwrap(),
        format!("t8: 済んだと控えた ({label})\n")
    );

    let f = fake(Sc {
        labels: json!({"pjp.finished": "2026-11-15T23:10+09:00"}),
        ..Sc::default()
    });
    let mut out = Vec::new();
    tell(&f, "t8", false, &mut out).unwrap();
    assert!(
        f.calls()
            .iter()
            .any(|c| c == &["hc", "label", "t8", "pjp.finished=", "--json"])
    );
    assert_eq!(
        String::from_utf8(out).unwrap(),
        "t8: 済んだの控えを消した\n"
    );

    // hc が無ければ Err (呼ぶ側が注意を 1 行にする)。hc は打たない
    let f = fake(Sc::default()).without("hc");
    let mut out = Vec::new();
    let e = tell(&f, "t8", true, &mut out).unwrap_err();
    assert!(e.message().contains("hc が見つかりません"), "{e}");
    assert!(calls_of(&f, "hc").is_empty());
}
