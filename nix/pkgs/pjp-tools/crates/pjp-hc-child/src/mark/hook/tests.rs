//! pjp mark hook のテスト。hc を偽物にし、hook の入力 (stdin) は偽の Runner から渡す。

use std::time::Duration;

use pjp_core::exit::{CONFIG, OK};
use pjp_core::process::Output;
use serde_json::{Value, json};

use super::*;
use crate::testutil::{Fake, fail, ok};

/// 偽の hc の場面。
#[derive(Clone)]
struct Hcs {
    labels: Value,
    /// hc get が落ちる (not_found でない失敗)。
    get_fails: bool,
    /// hc label が落ちる。
    label_fails: bool,
}

impl Default for Hcs {
    fn default() -> Self {
        Self {
            labels: json!({"pjp.role": "hub"}),
            get_fails: false,
            label_fails: false,
        }
    }
}

fn with_labels(labels: Value) -> Hcs {
    Hcs {
        labels,
        ..Hcs::default()
    }
}

fn respond(h: &Hcs, argv: &[String]) -> Output {
    let a: Vec<&str> = argv.iter().map(String::as_str).collect();
    let boom = r#"{"error":{"kind":"internal","message":"boom"}}"#;
    match a.as_slice() {
        ["hc", "get", addr, ..] => {
            if h.get_fails {
                return fail(1, boom);
            }
            if addr.starts_with("nope") {
                return fail(3, r#"{"error":{"kind":"not_found","message":"no"}}"#);
            }
            ok(&json!({
                "address": addr,
                "name": "hub",
                "state": "live",
                "labels": h.labels,
                "parent": null,
                "status": {"state": "working"},
            })
            .to_string())
        }
        ["hc", "label", ..] => {
            if h.label_fails {
                fail(1, boom)
            } else {
                ok("{}")
            }
        }
        _ => fail(127, &format!("偽物が知らないコマンド: {}", a.join(" "))),
    }
}

fn fake(h: Hcs, stdin: Option<&[u8]>) -> Fake {
    let f = Fake::new(move |argv| respond(&h, argv)).env("HC_TERMINAL_ID", "t8");
    match stdin {
        Some(bytes) => f.stdin(bytes),
        None => f,
    }
}

/// `pjp mark hook <args>…` を打つ。
fn hook(f: &Fake, args: &[&str]) -> (u8, String, String) {
    let mut full = vec!["hook".to_owned()];
    full.extend(args.iter().map(|s| (*s).to_owned()));
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = crate::mark::main(f, &full, &mut out, &mut err);
    (
        code,
        String::from_utf8(out).unwrap(),
        String::from_utf8(err).unwrap(),
    )
}

/// UserPromptSubmit の入力 (2026-11-19 に Windows で書き出した欄と同じ)。
fn prompt_input(prompt: &str) -> Vec<u8> {
    json!({
        "session_id": "s1",
        "transcript_path": "C:\\Users\\u\\.claude\\projects\\h\\s1.jsonl",
        "cwd": "C:\\Users\\u\\h",
        "prompt_id": "p1",
        "permission_mode": "bypassPermissions",
        "hook_event_name": "UserPromptSubmit",
        "prompt": prompt,
    })
    .to_string()
    .into_bytes()
}

/// Stop の入力。
fn stop_input(active: bool) -> Vec<u8> {
    json!({
        "session_id": "s1",
        "hook_event_name": "Stop",
        "stop_hook_active": active,
        "last_assistant_message": "済みました",
        "background_tasks": [],
        "session_crons": [],
    })
    .to_string()
    .into_bytes()
}

fn label_calls(f: &Fake) -> Vec<Vec<String>> {
    f.calls()
        .into_iter()
        .filter(|c| c[0] == "hc" && c[1] == "label")
        .collect()
}

/// stdout を、1 行の ASCII だけの JSON として読む。
fn output_json(out: &str) -> Value {
    assert!(out.ends_with('\n') && out.lines().count() == 1, "{out:?}");
    assert!(out.is_ascii(), "{out}");
    serde_json::from_str(out.trim()).unwrap()
}

/// 長い文が Claude Code の貼り付けの道を通ったときの包み (2026-11-19 に Windows で確かめた形)。
fn wrapped(s: &str) -> String {
    format!("<pasted_content id=\"17ee\">\n{s}\n</pasted_content id=\"17ee\">")
}

#[test]
fn from_user_rejects_child_reports_and_task_notifications() {
    for p in [
        "<hc from=\"wsl1/t13\">ABC-1: x</hc>",
        "<hc>x</hc>",
        "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>",
        "\n  <hc from=\"t2h\">x</hc>",
        "<hc from=\"t2h\"",
    ] {
        assert!(!from_user(p), "{p:?}");
        assert!(!from_user(&wrapped(p)), "包んだ {p:?}");
    }
}

#[test]
fn from_user_accepts_user_text_and_notion_comments() {
    for p in [
        "ふつうの答え",
        "<hc from=\"t5 pjp-hubd\">[Notion のコメント] ABC-302 · 2026/10/22 14:05 · discussion=d1\nこの案で進めて\n</hc>",
        "<hc>\n[Notion のコメント] ABC-302 · x</hc>",
        "#12 -> 案 A",
        "<bash-input>ls</bash-input>",
        "/compact",
        "<hcx>a</hcx>",
        "",
    ] {
        assert!(from_user(p), "{p:?}");
        assert!(from_user(&wrapped(p)), "包んだ {p:?}");
    }
    // 包みの中身がふつうの文 (ユーザーの貼り付け)・包みの前に書きかけ (hc が待ってから貼った)
    assert!(from_user(
        "<pasted_content id=\"1\">\n長い貼り付け\n</pasted_content id=\"1\">"
    ));
    assert!(from_user(
        "これ見て <pasted_content id=\"2\">\n<hc from=\"x\">y</hc>\n</pasted_content id=\"2\">"
    ));
}

#[test]
fn prompt_moves_asking_to_asked() {
    let f = fake(
        with_labels(json!({"pjp.role": "hub", "pjp.asking": "案 A と B のどちらで進めるか"})),
        Some(&prompt_input("A で")),
    );
    let (code, out, err) = hook(&f, &["prompt"]);
    assert_eq!(code, OK, "{err}");
    assert_eq!(
        label_calls(&f),
        [[
            "hc",
            "label",
            "t8",
            "pjp.asked=案 A と B のどちらで進めるか",
            "pjp.asking=",
            "--json"
        ]]
    );
    let v = output_json(&out);
    assert_eq!(v["hookSpecificOutput"]["hookEventName"], "UserPromptSubmit");
    let ctx = v["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .unwrap();
    for want in [
        "案 A と B のどちらで進めるか",
        "pjp.asked",
        "pjp mark answered",
        "pjp mark asking",
        "pjp mark hook stop",
    ] {
        assert!(ctx.contains(want), "{want}: {ctx}");
    }
    assert!(v.get("decision").is_none(), "{v}");
    assert_eq!(err, "");
}

#[test]
fn prompt_from_child_or_task_does_nothing() {
    let long_report = wrapped("<hc from=\"t2h\">長い子の報告</hc>");
    for p in [
        "<hc from=\"wsl1/t13\">ABC-1: x</hc>",
        long_report.as_str(),
        "<task-notification>x</task-notification>",
    ] {
        let f = fake(
            with_labels(json!({"pjp.asking": "どちらにするか"})),
            Some(&prompt_input(p)),
        );
        let (code, out, err) = hook(&f, &["prompt"]);
        assert_eq!((code, out.as_str(), err.as_str()), (OK, "", ""), "{p:?}");
        assert!(f.calls().is_empty(), "{p:?}: {:?}", f.calls());
    }
}

#[test]
fn prompt_without_asking_is_quiet() {
    for labels in [
        json!({"pjp.role": "hub"}),
        json!({"pjp.role": "hub", "pjp.asking": "  "}),
    ] {
        let f = fake(with_labels(labels), Some(&prompt_input("こんにちは")));
        let (code, out, err) = hook(&f, &["prompt"]);
        assert_eq!((code, out.as_str(), err.as_str()), (OK, "", ""));
        // hc get だけ
        assert_eq!(f.calls().len(), 1, "{:?}", f.calls());
        assert!(label_calls(&f).is_empty());
    }
}

#[test]
fn prompt_reads_bom_input() {
    // PowerShell が BOM を付けて流しても読む
    let mut input = "\u{feff}".as_bytes().to_vec();
    input.extend(prompt_input("A で"));
    let f = fake(
        with_labels(json!({"pjp.asking": "どちらにするか"})),
        Some(&input),
    );
    let (code, out, err) = hook(&f, &["prompt"]);
    assert_eq!(code, OK, "{err}");
    assert_eq!(label_calls(&f).len(), 1, "{err}");
    assert_eq!(
        output_json(&out)["hookSpecificOutput"]["hookEventName"],
        "UserPromptSubmit"
    );
}

#[test]
fn stop_continues_once_with_context() {
    let f = fake(
        with_labels(json!({"pjp.role": "hub", "pjp.asked": "どちらにするか"})),
        Some(&stop_input(false)),
    );
    let (code, out, err) = hook(&f, &["stop"]);
    assert_eq!(code, OK, "{err}");
    assert!(label_calls(&f).is_empty());
    let v = output_json(&out);
    assert_eq!(v["hookSpecificOutput"]["hookEventName"], "Stop");
    let ctx = v["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .unwrap();
    for want in [
        "どちらにするか",
        "pjp mark answered",
        "pjp mark asking",
        "pjp ticket wait",
    ] {
        assert!(ctx.contains(want), "{want}: {ctx}");
    }
    // block (hook のエラーとして出る) は使わない (spec §4.3・§14)
    assert!(v.get("decision").is_none(), "{v}");
    assert_eq!(err, "");
}

#[test]
fn stop_context_does_not_claim_the_answer_came_this_turn() {
    // pjp.asked は、Esc で止めた・API のエラーで終わったターンから持ち越されうる (Stop が動かない)。その次のターンが子の報告で
    // 始まっても、子の報告を答えと取り違えないよう「このターンに届いた」とは書かない (spec §4.3 の 3)
    let f = fake(
        with_labels(json!({"pjp.asked": "どちらにするか"})),
        Some(&stop_input(false)),
    );
    let (code, out, err) = hook(&f, &["stop"]);
    assert_eq!(code, OK, "{err}");
    let v = output_json(&out);
    let ctx = v["hookSpecificOutput"]["additionalContext"]
        .as_str()
        .unwrap();
    assert!(!ctx.contains("このターン"), "{ctx}");
    assert!(ctx.contains("ユーザーの発言が届いたときに"), "{ctx}");
}

#[test]
fn stop_second_time_clears_asked() {
    let f = fake(
        with_labels(json!({"pjp.role": "hub", "pjp.asked": "どちらにするか"})),
        Some(&stop_input(true)),
    );
    let (code, out, err) = hook(&f, &["stop"]);
    assert_eq!((code, out.as_str()), (OK, ""), "{err}");
    assert_eq!(
        label_calls(&f),
        [["hc", "label", "t8", "pjp.asked=", "--json"]]
    );
}

#[test]
fn stop_without_asked_is_quiet() {
    for active in [false, true] {
        let f = fake(
            with_labels(json!({"pjp.role": "hub", "pjp.asking": "まだ待つ問い"})),
            Some(&stop_input(active)),
        );
        let (code, out, err) = hook(&f, &["stop"]);
        assert_eq!((code, out.as_str(), err.as_str()), (OK, "", ""));
        assert!(label_calls(&f).is_empty());
    }
}

#[test]
fn stop_without_active_field_counts_as_first() {
    let f = fake(
        with_labels(json!({"pjp.asked": "どちらにするか"})),
        Some(b"{}"),
    );
    let (code, out, _) = hook(&f, &["stop"]);
    assert_eq!(code, OK);
    assert_eq!(
        output_json(&out)["hookSpecificOutput"]["hookEventName"],
        "Stop"
    );
    assert!(label_calls(&f).is_empty());
}

#[test]
fn hooks_never_fail() {
    let labels = json!({"pjp.role": "hub", "pjp.asking": "x", "pjp.asked": "y"});
    for event in ["prompt", "stop"] {
        let good = if event == "prompt" {
            prompt_input("答え")
        } else {
            stop_input(true)
        };
        let base = || with_labels(labels.clone());
        let cases: Vec<(&str, Fake)> = vec![
            ("stdin が端末", fake(base(), None)),
            ("stdin が空", fake(base(), Some(b""))),
            ("JSON でない", fake(base(), Some(b"not json"))),
            ("object でない", fake(base(), Some(b"[]"))),
            (
                "HC_TERMINAL_ID が無い",
                fake(base(), Some(&good)).env("HC_TERMINAL_ID", ""),
            ),
            ("hc が無い", fake(base(), Some(&good)).without("hc")),
            (
                "hc get が落ちる",
                fake(
                    Hcs {
                        get_fails: true,
                        ..base()
                    },
                    Some(&good),
                ),
            ),
            (
                "端末が無い",
                fake(base(), Some(&good)).env("HC_TERMINAL_ID", "nope1"),
            ),
            (
                "hc label が落ちる",
                fake(
                    Hcs {
                        label_fails: true,
                        ..base()
                    },
                    Some(&good),
                ),
            ),
        ];
        for (name, f) in cases {
            let (code, out, err) = hook(&f, &[event]);
            assert_eq!(code, OK, "{event} {name}: {err}");
            assert_eq!(out, "", "{event} {name}");
            assert!(
                err.starts_with(&format!("pjp mark hook {event}: ")),
                "{event} {name}: {err:?}"
            );
            assert_eq!(err.lines().count(), 1, "{event} {name}: {err:?}");
        }
    }
    // hook の名前が無い・知らない
    let f = fake(Hcs::default(), Some(b"{}"));
    for args in [&[][..], &["nope"][..]] {
        let (code, out, err) = hook(&f, args);
        assert_eq!((code, out.as_str()), (OK, ""), "{args:?}");
        assert!(err.starts_with("pjp mark hook: "), "{args:?}: {err}");
    }
    assert!(f.calls().is_empty(), "{:?}", f.calls());
}

#[test]
fn hook_ignores_extra_args() {
    let f = fake(
        with_labels(json!({"pjp.asking": "どちらにするか"})),
        Some(&prompt_input("A で")),
    );
    let (code, out, err) = hook(&f, &["prompt", "--bogus"]);
    assert_eq!(code, OK);
    assert!(err.contains("--bogus"), "{err}");
    assert_eq!(label_calls(&f).len(), 1);
    assert!(!out.is_empty());
}

#[test]
fn hook_waits_ten_seconds_for_hc() {
    let f = fake(
        with_labels(json!({"pjp.asking": "x"})),
        Some(&prompt_input("答え")),
    );
    let (code, _, err) = hook(&f, &["prompt"]);
    assert_eq!(code, OK, "{err}");
    let t = f.timeouts();
    // hc get と hc label
    assert_eq!(t.len(), 2, "{t:?}");
    assert!(
        t.iter().all(|d| *d == Some(Duration::from_secs(10))),
        "{t:?}"
    );
}

#[test]
fn usage_lists_hooks() {
    let f = fake(Hcs::default(), None);
    let run = |args: &[&str]| -> (u8, String, String) {
        let args: Vec<String> = args.iter().map(|s| (*s).to_owned()).collect();
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let code = crate::mark::main(&f, &args, &mut out, &mut err);
        (
            code,
            String::from_utf8(out).unwrap(),
            String::from_utf8(err).unwrap(),
        )
    };
    for args in [&["--help"][..], &["hook", "--help"][..]] {
        let (code, out, _) = run(args);
        assert_eq!(code, OK, "{args:?}");
        for want in [
            "pjp mark hook prompt",
            "pjp mark hook stop",
            "pjp.asked",
            "; exit 0",
        ] {
            assert!(out.contains(want), "{args:?} {want}: {out}");
        }
    }
    let (code, _, err) = run(&["nope"]);
    assert_eq!(code, CONFIG);
    assert!(err.contains("・hook"), "{err}");
}
