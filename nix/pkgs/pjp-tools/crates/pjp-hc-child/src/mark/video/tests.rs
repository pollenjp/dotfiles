//! pjp mark video のテスト。hc を偽物にし、端末ごとの label と `hc ls` の一覧 (親子) を持たせる。

use pjp_core::exit::{CONFIG, FAILURE, OK};
use pjp_core::process::Output;
use serde_json::{Value, json};

use super::*;
use crate::testutil::{Fake, fail, ok};

/// Fake の今 (2026-11-16T10:05:00+09:00) で付く キーと日時。
const KEY_NOW: &str = "pjp.video.20261116100500";
const AT_NOW: &str = "2026-11-16T10:05:00+09:00";

#[derive(Clone)]
struct T {
    address: &'static str,
    parent: Option<&'static str>,
    labels: Value,
}

fn t(address: &'static str, parent: Option<&'static str>, labels: Value) -> T {
    T {
        address,
        parent,
        labels,
    }
}

#[derive(Clone, Default)]
struct W {
    terms: Vec<T>,
    ls_fails: bool,
    /// `hc get` が落ちる端末 (つながらない)。
    get_fails: Vec<&'static str>,
}

fn respond(w: &W, argv: &[String]) -> Output {
    let a: Vec<&str> = argv.iter().map(String::as_str).collect();
    match a.as_slice() {
        ["hc", "get", addr, ..] if w.get_fails.contains(addr) => fail(
            1,
            r#"{"error":{"kind":"unavailable","message":"wsl1 is not connected"}}"#,
        ),
        ["hc", "get", addr, ..] => match w.terms.iter().find(|x| x.address == *addr) {
            Some(x) => ok(&json!({
                "address": x.address,
                "parent": x.parent,
                "state": "live",
                "labels": x.labels,
            })
            .to_string()),
            None => fail(3, r#"{"error":{"kind":"not_found","message":"no"}}"#),
        },
        ["hc", "ls", ..] => {
            if w.ls_fails {
                return fail(
                    1,
                    r#"{"error":{"kind":"unavailable","message":"core is busy"}}"#,
                );
            }
            // 本物の hc 0.1.21 と同じく、ls は label を出さない
            let terms: Vec<Value> = w
                .terms
                .iter()
                .map(|x| json!({"address": x.address, "parent": x.parent, "state": "live"}))
                .collect();
            ok(&json!({"terminals": terms, "hidden_finished": 0}).to_string())
        }
        ["hc", "label", ..] => ok("{}"),
        _ => fail(127, &format!("偽物が知らないコマンド: {}", a.join(" "))),
    }
}

fn fake(w: W) -> Fake {
    Fake::new(move |argv| respond(&w, argv)).env("HC_TERMINAL_ID", "t8")
}

fn one(labels: Value) -> Fake {
    fake(W {
        terms: vec![t("t8", None, labels)],
        ..W::default()
    })
}

fn run(f: &Fake, args: &[&str]) -> (u8, String, String) {
    let mut full: Vec<String> = vec!["video".to_owned()];
    full.extend(args.iter().map(|s| (*s).to_owned()));
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = crate::mark::main(f, &full, &mut out, &mut err);
    (
        code,
        String::from_utf8(out).unwrap(),
        String::from_utf8(err).unwrap(),
    )
}

fn label_calls(f: &Fake) -> Vec<Vec<String>> {
    f.calls()
        .into_iter()
        .filter(|c| c[0] == "hc" && c[1] == "label")
        .collect()
}

/// label の値 (1 行の JSON)。
fn v(name: &str, state: &str, started: &str, ended: Option<&str>) -> String {
    let mut x = json!({"name": name, "state": state, "started": started});
    if let Some(e) = ended {
        x["ended"] = json!(e);
    }
    x.to_string()
}

fn making(name: &str, started: &str) -> String {
    v(name, "making", started, None)
}

fn made(name: &str, started: &str, ended: &str) -> String {
    v(name, "done", started, Some(ended))
}

const T9: &str = "2026-11-16T09:00:00+09:00";
const T930: &str = "2026-11-16T09:30:00+09:00";

// ---- start

#[test]
fn start_sets_label_with_json() {
    let f = one(json!({"pjp.role": "child"}));
    let (code, out, err) = run(&f, &["start", "ABC-1 短尺 x"]);
    assert_eq!(code, OK, "{err}");
    let label = format!(
        "{KEY_NOW}={}",
        r#"{"name":"ABC-1 短尺 x","state":"making","started":"2026-11-16T10:05:00+09:00"}"#
    );
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", label.as_str(), "--json"]]
    );
    assert_eq!(
        out,
        "t8: 解説動画を作っている印を付けた (🎬⏳:ABC-1 短尺 x)\n"
    );
    assert_eq!(err, "");
}

#[test]
fn start_squashes_whitespace_in_name() {
    let f = one(json!({}));
    let (code, _, _) = run(&f, &["start", "  ABC-1 　短尺  x "]);
    assert_eq!(code, OK);
    assert!(
        label_calls(&f)[0][3].contains(r#""name":"ABC-1 短尺 x""#),
        "{:?}",
        f.calls()
    );
}

#[test]
fn start_same_name_is_noop() {
    let f = one(json!({"pjp.video.20261116090000": making("ABC-1 短尺 x", T9)}));
    let (code, out, _) = run(&f, &["start", "ABC-1 短尺 x"]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty(), "{:?}", f.calls());
    assert_eq!(out, "t8: もう作っていると控えてある (🎬⏳:ABC-1 短尺 x)\n");
}

#[test]
fn start_after_done_reopens_the_same_label() {
    // 作り直し: 同じ名前の ✅ を ⏳ に戻す (同じキー。作り始めた日時は新しく、済んだ日時は外す)
    let f = one(json!({"pjp.video.20261116090000": made("ABC-1 短尺 x", T9, T930)}));
    let (code, out, _) = run(&f, &["start", "ABC-1 短尺 x"]);
    assert_eq!(code, OK);
    let label = format!(
        "pjp.video.20261116090000={}",
        making("ABC-1 短尺 x", AT_NOW)
    );
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", label.as_str(), "--json"]]
    );
    assert!(out.contains("作り直す"), "{out}");
}

#[test]
fn start_key_collision_adds_suffix() {
    // 同じ秒に 2 本目を作り始めても上書きしない
    let f = one(json!({ KEY_NOW: making("ABC-1 短尺 x", AT_NOW) }));
    let (code, _, _) = run(&f, &["start", "ABC-1 詳細版 x"]);
    assert_eq!(code, OK);
    let calls = label_calls(&f);
    assert!(
        calls[0][3].starts_with(&format!("{KEY_NOW}-2=")),
        "{calls:?}"
    );
    // -2 もあれば -3
    let f = one(json!({
        KEY_NOW: making("a", AT_NOW),
        format!("{KEY_NOW}-2"): making("b", AT_NOW),
    }));
    run(&f, &["start", "c"]);
    assert!(label_calls(&f)[0][3].starts_with(&format!("{KEY_NOW}-3=")));
}

#[test]
fn start_takes_terminal_option() {
    let f = fake(W {
        terms: vec![
            t("t8", None, json!({})),
            t("wsl1/t13", Some("t8"), json!({})),
        ],
        ..W::default()
    });
    let (code, out, _) = run(&f, &["start", "x", "--terminal", "wsl1/t13"]);
    assert_eq!(code, OK);
    assert_eq!(label_calls(&f)[0][2], "wsl1/t13");
    assert!(out.starts_with("wsl1/t13: "), "{out}");
}

#[test]
fn start_on_missing_terminal_fails() {
    let f = one(json!({}));
    let (code, _, err) = run(&f, &["start", "x", "--terminal", "nope"]);
    assert_eq!(code, FAILURE);
    assert!(err.contains("hc に端末 nope がありません"), "{err}");
}

#[test]
fn long_name_notes() {
    let f = one(json!({}));
    let long = "あ".repeat(61);
    let (code, _, err) = run(&f, &["start", &long]);
    assert_eq!(code, OK);
    assert!(err.contains("名前が長い (61 字)"), "{err}");
    let f = one(json!({}));
    let (_, _, err) = run(&f, &["start", &"あ".repeat(60)]);
    assert_eq!(err, "");
}

#[test]
fn bad_names_and_args_are_config_errors() {
    let f = one(json!({}));
    for args in [
        &["start"][..],
        &["start", ""][..],
        &["start", "  "][..],
        &["start", "a\nb"][..],
        &["start", "a\tb"][..],
        &["start", "a", "b"][..],
        &["done", "a", "b"][..],
        &["start", "a", "--all"][..],
        &["nope"][..],
        &[][..],
    ] {
        let (code, _, err) = run(&f, args);
        assert_eq!(code, CONFIG, "{args:?}: {err}");
    }
    assert!(label_calls(&f).is_empty());
}

#[test]
fn outside_hc_terminal_is_noop_with_note() {
    let f = one(json!({})).env("HC_TERMINAL_ID", "");
    for args in [
        &["start", "x"][..],
        &["done", "x"][..],
        &["stop"][..],
        &["watched", "--all"][..],
    ] {
        let (code, out, err) = run(&f, args);
        assert_eq!(code, OK, "{args:?}");
        assert_eq!(out, "", "{args:?}");
        assert!(err.contains("hc の端末の外"), "{args:?}: {err}");
    }
    // hc を呼ばない (hc の無いマシンでも落ちない)
    assert!(f.calls().is_empty(), "{:?}", f.calls());
    let f = one(json!({})).env("HC_TERMINAL_ID", "").without("hc");
    assert_eq!(run(&f, &["start", "x"]).0, OK);
}

#[test]
fn help_lists_subcommands() {
    let f = one(json!({}));
    let (code, out, _) = run(&f, &["--help"]);
    assert_eq!(code, OK);
    for want in [
        "start",
        "done",
        "stop",
        "watched",
        "🎬⏳",
        "🎬✅",
        "3 行目から 1 本 1 行",
    ] {
        assert!(out.contains(want), "{want}: {out}");
    }
    let (code, _, err) = run(&f, &["nope"]);
    assert_eq!(code, CONFIG);
    assert!(err.contains("start・done・stop・watched"), "{err}");
}

// ---- done

#[test]
fn done_marks_matching_making() {
    let f = one(json!({"pjp.video.20261116090000": making("ABC-1 短尺 x", T9)}));
    let (code, out, err) = run(&f, &["done", "ABC-1 短尺 x"]);
    assert_eq!(code, OK, "{err}");
    let label = format!(
        "pjp.video.20261116090000={}",
        made("ABC-1 短尺 x", T9, AT_NOW)
    );
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", label.as_str(), "--json"]]
    );
    assert!(
        out.starts_with("t8: 済んだ印にした (🎬✅:ABC-1 短尺 x"),
        "{out}"
    );
    assert!(out.contains("pjp mark video watched"), "{out}");
}

#[test]
fn done_prefers_the_same_name() {
    let f = one(json!({
        "pjp.video.20261116090000": making("ABC-1 短尺 x", T9),
        "pjp.video.20261116090100": making("ABC-1 短尺 x 続き", T9),
    }));
    let (code, _, _) = run(&f, &["done", "ABC-1 短尺 x"]);
    assert_eq!(code, OK);
    let calls = label_calls(&f);
    assert_eq!(calls.len(), 1);
    assert!(
        calls[0][3].starts_with("pjp.video.20261116090000="),
        "{calls:?}"
    );
}

#[test]
fn done_matches_by_words_in_any_order_and_case() {
    let f = one(json!({
        "pjp.video.20261116090000": making("ABC-1 短尺 x", T9),
        "pjp.video.20261116090100": making("ABC-1 詳細版 x", T9),
    }));
    let (code, _, _) = run(&f, &["done", "短尺 abc-1"]);
    assert_eq!(code, OK);
    let calls = label_calls(&f);
    assert_eq!(calls.len(), 1);
    assert!(calls[0][3].contains("短尺"), "{calls:?}");
}

#[test]
fn done_without_making_creates_done() {
    // start を打ち損ねても、見ていない動画の印は残す
    let f = one(json!({}));
    let (code, out, _) = run(&f, &["done", "ABC-1 短尺 x"]);
    assert_eq!(code, OK);
    let label = format!("{KEY_NOW}={}", made("ABC-1 短尺 x", AT_NOW, AT_NOW));
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", label.as_str(), "--json"]]
    );
    assert!(out.contains("作っている印が無かったので"), "{out}");
}

#[test]
fn done_again_is_noop() {
    let f = one(json!({"pjp.video.20261116090000": made("ABC-1 短尺 x", T9, T930)}));
    let (code, out, _) = run(&f, &["done", "ABC-1 短尺 x"]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty());
    assert!(out.contains("もう済んだと控えてある"), "{out}");
}

#[test]
fn done_without_name_takes_the_only_making() {
    let f = one(json!({"pjp.video.20261116090000": making("ABC-1 短尺 x", T9)}));
    let (code, _, _) = run(&f, &["done"]);
    assert_eq!(code, OK);
    assert_eq!(label_calls(&f).len(), 1);
    // 作っているものが無ければ何もしない
    let f = one(json!({}));
    let (code, out, err) = run(&f, &["done"]);
    assert_eq!((code, out.as_str()), (OK, ""));
    assert!(err.contains("作っている解説動画の印が無い"), "{err}");
}

#[test]
fn done_ambiguous_lists_and_exits_1() {
    let f = one(json!({
        "pjp.video.20261116090000": making("ABC-1 短尺 x", T9),
        "pjp.video.20261116090100": making("ABC-1 詳細版 x", T9),
    }));
    let (code, out, _) = run(&f, &["done", "ABC-1"]);
    assert_eq!(code, FAILURE);
    assert!(label_calls(&f).is_empty());
    assert!(out.contains("2 つに当たる"), "{out}");
    assert!(out.contains("🎬⏳:ABC-1 短尺 x"), "{out}");
    assert!(out.contains("🎬⏳:ABC-1 詳細版 x"), "{out}");
}

// ---- stop

#[test]
fn stop_removes_making_only() {
    let f = one(json!({
        "pjp.video.20261116090000": made("ABC-1 短尺 x", T9, T930),
        "pjp.video.20261116093000": making("ABC-1 詳細版 x", T930),
    }));
    let (code, out, _) = run(&f, &["stop"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.video.20261116093000=", "--json"]]
    );
    assert_eq!(out, "t8: 作りかけの印を外した (🎬⏳:ABC-1 詳細版 x)\n");
}

#[test]
fn stop_many_needs_name_or_all() {
    let labels = json!({
        "pjp.video.20261116090000": making("ABC-1 短尺 x", T9),
        "pjp.video.20261116093000": making("ABC-1 詳細版 x", T930),
    });
    let f = one(labels.clone());
    let (code, out, _) = run(&f, &["stop"]);
    assert_eq!(code, FAILURE);
    assert!(out.contains("--all"), "{out}");
    assert!(label_calls(&f).is_empty());
    let f = one(labels.clone());
    let (code, _, _) = run(&f, &["stop", "詳細版"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.video.20261116093000=", "--json"]]
    );
    // --all は 1 回の hc label で全部
    let f = one(labels);
    let (code, _, _) = run(&f, &["stop", "--all"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "t8",
            "pjp.video.20261116090000=",
            "pjp.video.20261116093000=",
            "--json"
        ]]
    );
}

#[test]
fn stop_without_match_is_ok_with_note() {
    let f = one(json!({"pjp.video.20261116090000": made("ABC-1 短尺 x", T9, T930)}));
    let (code, out, err) = run(&f, &["stop", "短尺"]);
    assert_eq!((code, out.as_str()), (OK, ""));
    assert!(err.contains("作りかけの解説動画の印が無い"), "{err}");
    assert!(label_calls(&f).is_empty());
}

// ---- watched

/// ハブ t8 の子 A (wsl1/t13)・孫 (wsl1/t14)、ハブの子でない会話 t9。
fn family_world(ls_fails: bool) -> Fake {
    fake(W {
        terms: vec![
            t("t8", None, json!({"pjp.role": "hub"})),
            t(
                "wsl1/t13",
                Some("t8"),
                json!({"pjp.role": "child", "pjp.letter": "A",
                       "pjp.video.20261116090000": made("ABC-2 短尺 y", T9, T930)}),
            ),
            t(
                "wsl1/t14",
                Some("wsl1/t13"),
                json!({"pjp.role": "child", "pjp.ticket": "ABC-3",
                       "pjp.video.20261116091000": made("ABC-3 詳細版 z", T9, T930),
                       "pjp.video.20261116092000": making("ABC-3 短尺 z", T930)}),
            ),
            t(
                "t9",
                None,
                json!({"pjp.video.20261116090000": made("ABC-2 短尺 other", T9, T930)}),
            ),
        ],
        ls_fails,
        ..W::default()
    })
}

#[test]
fn watched_searches_descendants() {
    let f = family_world(false);
    let (code, out, err) = run(&f, &["watched", "詳細版"]);
    assert_eq!(code, OK, "{err}");
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "wsl1/t14",
            "pjp.video.20261116091000=",
            "--json"
        ]]
    );
    assert_eq!(
        out,
        "wsl1/t14: 見た動画の印を外した (🎬✅:ABC-3 詳細版 z)\n"
    );
}

#[test]
fn watched_without_name_lists_when_many() {
    // ハブの子孫に ✅ が 2 つ (子でない t9 の分は数えない)
    let f = family_world(false);
    let (code, out, _) = run(&f, &["watched"]);
    assert_eq!(code, FAILURE);
    assert!(label_calls(&f).is_empty());
    assert!(out.contains("2 つに当たる"), "{out}");
    assert!(
        out.contains("🎬✅:ABC-2 短尺 y (子 A wsl1/t13・11/16 09:30 に載せた・見ていない)"),
        "{out}"
    );
    assert!(out.contains("ABC-3 詳細版 z (ABC-3 wsl1/t14・"), "{out}");
    assert!(!out.contains("other"), "{out}");
}

#[test]
fn watched_all_removes_each_holder_once() {
    let f = family_world(false);
    let (code, _, _) = run(&f, &["watched", "--all"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [
            [
                "hc",
                "label",
                "wsl1/t13",
                "pjp.video.20261116090000=",
                "--json"
            ],
            [
                "hc",
                "label",
                "wsl1/t14",
                "pjp.video.20261116091000=",
                "--json"
            ],
        ]
    );
}

#[test]
fn watched_hints_when_only_making_matches() {
    let f = family_world(false);
    let (code, out, _) = run(&f, &["watched", "ABC-3 短尺"]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty());
    assert!(out.contains("まだ作っている"), "{out}");
    assert!(out.contains("🎬⏳:ABC-3 短尺 z"), "{out}");
}

#[test]
fn watched_nothing_is_ok_with_note() {
    let f = one(json!({}));
    let (code, out, err) = run(&f, &["watched"]);
    assert_eq!((code, out.as_str()), (OK, ""));
    assert!(err.contains("見ていない解説動画の印が無い"), "{err}");
}

#[test]
fn watched_from_a_child_terminal_sees_only_its_family() {
    let f = family_world(false);
    let (code, _, _) = run(&f, &["watched", "--all", "--terminal", "wsl1/t14"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "wsl1/t14",
            "pjp.video.20261116091000=",
            "--json"
        ]]
    );
}

#[test]
fn watched_checks_only_the_root_when_ls_fails() {
    let f = fake(W {
        terms: vec![t(
            "t8",
            None,
            json!({"pjp.video.20261116090000": made("ABC-1 短尺 x", T9, T930)}),
        )],
        ls_fails: true,
        ..W::default()
    });
    let (code, _, err) = run(&f, &["watched"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.video.20261116090000=", "--json"]]
    );
    assert!(err.contains("子孫の端末を読めない"), "{err}");
}

#[test]
fn watched_does_not_loop_on_a_parent_cycle() {
    let f = fake(W {
        terms: vec![
            t(
                "t8",
                Some("t9"),
                json!({"pjp.video.1": made("a", T9, T930)}),
            ),
            t(
                "t9",
                Some("t8"),
                json!({"pjp.video.1": made("b", T9, T930)}),
            ),
        ],
        ..W::default()
    });
    let (code, out, _) = run(&f, &["watched", "--all"]);
    assert_eq!(code, OK, "{out}");
    assert_eq!(label_calls(&f).len(), 2);
}

// ---- 読み方

#[test]
fn malformed_labels_are_ignored() {
    let term = json!({"labels": {
        "pjp.video.a": "not json",
        "pjp.video.b": r#"{"name":"x","state":"weird"}"#,
        "pjp.video.c": r#"["done"]"#,
        "pjp.video.": made("no id", T9, T930),
        "pjp.videox": made("not ours", T9, T930),
        "pjp.video.d": made("ok", T9, T930),
    }});
    let got = videos_of(&term);
    assert_eq!(got.len(), 1, "{got:?}");
    assert_eq!(got[0].key, "pjp.video.d");
    assert_eq!(got[0].name, "ok");
    assert!(videos_of(&json!({})).is_empty());
    assert!(videos_of(&json!({"labels": null})).is_empty());
}

#[test]
fn videos_are_sorted_making_first_then_by_start() {
    let term = json!({"labels": {
        "pjp.video.3": made("c", "2026-11-16T08:00:00+09:00", T930),
        "pjp.video.1": making("b", "2026-11-16T09:00:00+09:00"),
        "pjp.video.2": making("a", "2026-11-16T08:30:00+09:00"),
        "pjp.video.4": made("d", "2026-11-16T07:00:00+09:00", T930),
    }});
    let names: Vec<String> = videos_of(&term).into_iter().map(|v| v.name).collect();
    assert_eq!(names, ["a", "b", "d", "c"]);
}

#[test]
fn value_round_trips_and_keeps_from() {
    let video = Video {
        key: "pjp.video.20261116090000".to_owned(),
        name: "ABC-1 \"短尺\" = x".to_owned(),
        state: State::Done,
        started: T9.to_owned(),
        ended: Some(T930.to_owned()),
        from: Some("子 A (wsl1/t13)".to_owned()),
    };
    let term = json!({"labels": {video.key.clone(): video.value()}});
    assert_eq!(videos_of(&term), std::slice::from_ref(&video));
    assert_eq!(
        video.value(),
        r#"{"name":"ABC-1 \"短尺\" = x","state":"done","started":"2026-11-16T09:00:00+09:00","ended":"2026-11-16T09:30:00+09:00","from":"子 A (wsl1/t13)"}"#
    );
    assert_eq!(
        video.describe(Some("t8")),
        "🎬✅:ABC-1 \"短尺\" = x (t8・11/16 09:30 に載せた・見ていない・片付けた子 A (wsl1/t13) から移した)"
    );
    // pjp-spaces の動画の行の字面 (main.js の videoText と同じ。`:` の後ろに空白を置かない)
    assert_eq!(video.row_text(), "🎬✅:ABC-1 \"短尺\" = x");
    let making = Video {
        state: State::Making,
        ..video
    };
    assert_eq!(making.row_text(), "🎬⏳:ABC-1 \"短尺\" = x");
}

#[test]
fn moved_pairs_add_from_and_avoid_taken_keys() {
    let videos = vec![
        Video {
            key: "pjp.video.1".to_owned(),
            name: "a".to_owned(),
            state: State::Done,
            started: T9.to_owned(),
            ended: Some(T930.to_owned()),
            from: None,
        },
        Video {
            key: "pjp.video.2".to_owned(),
            name: "b".to_owned(),
            state: State::Making,
            started: T9.to_owned(),
            ended: None,
            from: None,
        },
        Video {
            key: "pjp.video.3".to_owned(),
            name: "c".to_owned(),
            state: State::Done,
            started: T930.to_owned(),
            ended: Some(T930.to_owned()),
            from: None,
        },
    ];
    // 移す先にもう pjp.video.1 (別の動画) と、同じ動画 c (前の片付けで移した) がある
    let home = json!({"labels": {
        "pjp.video.1": made("other", T9, T930),
        "pjp.video.3": v("c", "done", T930, Some(T930)),
    }});
    let pairs = moved_pairs(&videos, &home, "子 A (wsl1/t13)");
    assert_eq!(
        pairs,
        [format!(
            "pjp.video.1-2={}",
            r#"{"name":"a","state":"done","started":"2026-11-16T09:00:00+09:00","ended":"2026-11-16T09:30:00+09:00","from":"子 A (wsl1/t13)"}"#
        )]
    );
}

#[test]
fn short_times() {
    assert_eq!(short_time("2026-11-06T09:05:00+09:00"), "11/6 09:05");
    assert_eq!(short_time("2026-01-16T23:59:59+09:00"), "1/16 23:59");
    assert_eq!(short_time("きのう"), "きのう");
    assert_eq!(short_time(""), "");
}

// ---- レビューで足したもの (名前の当て方・写し・子孫)

#[test]
fn done_by_part_of_a_done_name_does_not_add_another() {
    // subagent が付けた ✅ に、親が名前の一部で done を打ち直しても、✅ を重ねない
    let f =
        one(json!({"pjp.video.20261116090000": made("ABC-839 短尺 space の動画の印", T9, T930)}));
    let (code, out, _) = run(&f, &["done", "ABC-839 短尺"]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty(), "{:?}", f.calls());
    assert!(
        out.contains("もう済んだと控えてある (🎬✅:ABC-839 短尺 space の動画の印)"),
        "{out}"
    );
}

#[test]
fn the_same_name_wins_across_states() {
    // 同じ名前の ⏳ があれば、部分一致の ✅ は選ばない (watched X で ✅ の「X Y」を外さない)
    let labels = json!({
        "pjp.video.1": making("X", T9),
        "pjp.video.2": made("X Y", T9, T930),
    });
    let f = one(labels.clone());
    let (code, out, _) = run(&f, &["watched", "X"]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty(), "{:?}", f.calls());
    assert!(out.contains("まだ作っている"), "{out}");
    // 同じ名前の ✅ があれば、done は部分一致の ⏳ を済にしない
    let f = one(json!({
        "pjp.video.1": made("X", T9, T930),
        "pjp.video.2": making("X Y", T9),
    }));
    let (code, out, _) = run(&f, &["done", "X"]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty(), "{:?}", f.calls());
    assert!(out.contains("もう済んだと控えてある"), "{out}");
}

#[test]
fn watched_without_name_hints_when_only_making() {
    let f = one(json!({"pjp.video.1": making("ABC-1 短尺 x", T9)}));
    let (code, out, _) = run(&f, &["watched"]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty());
    assert!(out.contains("まだ作っている"), "{out}");
    assert!(out.contains("🎬⏳:ABC-1 短尺 x"), "{out}");
}

#[test]
fn stop_searches_descendants() {
    // ハブが Linux の子に作らせた動画が止まったとき、ハブから名前で外せる
    let f = family_world(false);
    let (code, out, err) = run(&f, &["stop", "ABC-3 短尺"]);
    assert_eq!(code, OK, "{err}");
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "wsl1/t14",
            "pjp.video.20261116092000=",
            "--json"
        ]]
    );
    assert_eq!(out, "wsl1/t14: 作りかけの印を外した (🎬⏳:ABC-3 短尺 z)\n");
    // 済んだ印にだけ当たれば外さずに知らせる
    let f = family_world(false);
    let (code, _, err) = run(&f, &["stop", "ABC-2"]);
    assert_eq!(code, OK);
    assert!(label_calls(&f).is_empty());
    assert!(err.contains("済んだ印には当たった"), "{err}");
}

#[test]
fn copies_of_one_video_count_as_one() {
    // 片付けで親へ移した後に子を終えられなかった: 同じ動画が親と子にある。名前を省いても 1 本とみて、両方を外す
    let copy = r#"{"name":"ABC-2 短尺 y","state":"done","started":"2026-11-16T09:00:00+09:00","ended":"2026-11-16T09:30:00+09:00","from":"子 A (wsl1/t13)"}"#;
    let f = fake(W {
        terms: vec![
            t(
                "t8",
                None,
                json!({"pjp.role": "hub", "pjp.video.20261116090000": copy}),
            ),
            t(
                "wsl1/t13",
                Some("t8"),
                json!({"pjp.role": "child", "pjp.letter": "A",
                       "pjp.video.20261116090000": made("ABC-2 短尺 y", T9, T930)}),
            ),
        ],
        ..W::default()
    });
    let (code, out, _) = run(&f, &["watched"]);
    assert_eq!(code, OK, "{out}");
    assert_eq!(
        label_calls(&f),
        [
            ["hc", "label", "t8", "pjp.video.20261116090000=", "--json"],
            [
                "hc",
                "label",
                "wsl1/t13",
                "pjp.video.20261116090000=",
                "--json"
            ],
        ]
    );
}

#[test]
fn show_lists_videos_of_descendants_in_row_order() {
    let f = family_world(false);
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = crate::mark::main(&f, &["show".to_owned()], &mut out, &mut err);
    let out = String::from_utf8(out).unwrap();
    assert_eq!(code, OK);
    assert!(
        out.contains(
            "  動画 (この端末と子孫。space の行の 3 行目から 1 本 1 行): 3 本\n    🎬⏳:ABC-3 短尺 z (ABC-3 wsl1/t14・11/16 09:30 から作っている)\n    🎬✅:ABC-2 短尺 y (子 A wsl1/t13・"
        ),
        "{out}"
    );
    // ハブの子でない t9 は出さない
    assert!(!out.contains("other"), "{out}");
}

#[test]
fn unreadable_descendant_is_noted_and_skipped() {
    let mut w = W {
        terms: vec![
            t("t8", None, json!({})),
            t(
                "wsl1/t13",
                Some("t8"),
                json!({"pjp.video.1": made("a", T9, T930)}),
            ),
            t(
                "wsl1/t15",
                Some("t8"),
                json!({"pjp.video.1": made("b", T9, T930)}),
            ),
        ],
        ..W::default()
    };
    w.get_fails = vec!["wsl1/t15"];
    let f = fake(w);
    let (code, _, err) = run(&f, &["watched"]);
    assert_eq!(code, OK);
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "wsl1/t13", "pjp.video.1=", "--json"]]
    );
    assert!(err.contains("!! wsl1/t15 の印を読めない"), "{err}");
}

#[test]
fn helper_terminals_are_tagged() {
    let f = fake(W {
        terms: vec![
            t("t8", None, json!({"pjp.role": "hub"})),
            t(
                "t60",
                Some("t8"),
                json!({"pjp.video.1": made("h", T9, T930), "pjp.video.2": made("i", T9, T930)}),
            ),
        ],
        ..W::default()
    });
    let (code, out, _) = run(&f, &["watched"]);
    assert_eq!(code, FAILURE);
    assert!(out.contains("🎬✅:h (手伝いの端末 t60・"), "{out}");
}
