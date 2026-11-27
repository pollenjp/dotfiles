//! check: claude-selector-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 選ぶ画面 (ui::Ui) にキーを並べて流し、起こすもの (launch::Plan) と描く中身 (Frame の字と見せ方) を見る。端末には触らない。
//!
//! - 打ってすぐ Enter 1 回で既定のまま、PATH の claude を c から --remote-control= を外した中身 (並びは effort → モデル → 権限) で起こす
//! - 画面: 一番上に見出しとキーの案内、その下にコマンド行、その下に選んでいる項目の名前と選択肢の一覧。打った直後はアカウントの項目
//! - ← → (h・l) で項目を移る (端で止まる。cs の後ろの引数は項目にしない)。選んでいる項目はコマンド行の中で見せ方を変える
//!   (Style::Selected。色を付けないときは字の前後に { } を付ける)
//! - ↑ ↓ (k・j)・Home・End で値を選ぶと、すぐにコマンド行に出る (決める操作は無い)。項目を移っても値は残る。Enter はどの項目からでも
//!   今のコマンド行のまま起こす
//! - アカウント: launcher の無い行は飛ばし、選べない。どれも選べなければ Enter で知らせ、起こさない (アカウントの項目へ戻る)
//! - 付けない値 (権限の「付けない」・Remote Control を付けない) は、灰色の括弧 (Style::Absent) で `[--permission-mode]`・`[--remote-control]`
//!   と出し、claude には渡さない。起こしたときに見せる行は、画面のコマンド行から括弧を外したもの
//! - 字を打つ値 (モデルの「手で打つ」・Remote Control の「名前を付ける」): その行の Enter は起こさずに打ち始める。打つ間はカーソルを出し、
//!   打った字はすぐコマンド行に出る。Enter で決めて一覧へ戻り、もう一度 Enter で起こす (動いて戻ったら、Enter は決めた字から打ち直す)。
//!   だめなモデルの名前は知らせて打ち直し。空で Backspace は一覧へ。Remote Control の名前は空のまま決めると名前なし
//! - 打つ値が空のまま (名前の形 `<モデル名>`・`<名前>` を見せている) なら、別の項目で Enter を押しても起こさず、その項目で打ち始める
//! - Esc・Ctrl+C はどこでもやめる (起こさない)
//! - cs の後ろの引数は最後にそのまま付き、見せる行では引用する
//! - 描く中身: 既定の印「(既定)」・カーソルの行の「> 」・説明のそろえ・一覧が読めなかった知らせ。項目を移っても枠の行の数は変わらない
//! - コマンド行は端末の幅で折り返し、字を落とさず、折り返した先でも選んでいる項目の見せ方を保つ。引数の制御文字は `\n` などの形で見せ、
//!   起こすのは argv のまま
//! - 端末の行が足りなければ、一覧はカーソルの行が見える所だけを出す (見出し・コマンド行・カーソルの行は残す)

use claude_selector::accounts::{Account, Found, Mode};
use claude_selector::app::claude_note;
use claude_selector::launch::Plan;
use claude_selector::ui::{Frame, Key, Line, Outcome, Style, Ui};
use std::ffi::OsString;
use std::path::PathBuf;
use unicode_width::UnicodeWidthStr;

fn account(name: &str, mode: Mode, launcher: bool) -> Account {
    Account {
        name: name.to_string(),
        mode,
        default: mode == Mode::Subscription,
        launcher: launcher.then(|| PathBuf::from(format!("/bin/claude-{name}"))),
    }
}

/// claude と personal・token1 の launcher があり、work の launcher が無い
fn found() -> Found {
    Found {
        claude: Some(PathBuf::from("/bin/claude")),
        accounts: vec![
            account("personal", Mode::Subscription, true),
            account("work", Mode::Subscription, false),
            account("token1", Mode::Token, true),
        ],
        warnings: Vec::new(),
    }
}

fn ui() -> Ui {
    Ui::new(&found(), "~/.claude", Vec::new())
}

/// キーを順に渡し、最後のキーの結果を返す (途中で Continue 以外が返れば落とす)
fn press(ui: &mut Ui, keys: &[Key]) -> Outcome {
    let mut last = Outcome::Continue;
    for (i, k) in keys.iter().enumerate() {
        assert_eq!(last, Outcome::Continue, "{i} 番目のキーの前に終わった");
        last = ui.handle(*k);
    }
    last
}

fn typed(ui: &mut Ui, text: &str) {
    for c in text.chars() {
        assert_eq!(ui.handle(Key::Char(c)), Outcome::Continue);
    }
}

fn launched(o: Outcome) -> Plan {
    match o {
        Outcome::Launch(p) => p,
        other => panic!("起こしていない: {other:?}"),
    }
}

fn strs(args: &[OsString]) -> Vec<String> {
    args.iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

/// 広い端末 (折り返さない・一覧を削らない)
const COLS: usize = 200;
const ROWS: usize = 60;

/// 項目を移るキー (アカウント → effort → モデル → 権限 → Remote Control)
const TO_MODEL: [Key; 2] = [Key::Right; 2];
const TO_PERMISSION: [Key; 3] = [Key::Right; 3];
const TO_RC: [Key; 4] = [Key::Right; 4];

/// コマンド行の行 (コマンド行の見せ方の塊を持つ行)
fn command_lines(f: &Frame) -> Vec<&Line> {
    f.lines
        .iter()
        .filter(|l| {
            l.spans
                .iter()
                .any(|s| matches!(s.style, Style::Command | Style::Selected | Style::Absent))
        })
        .collect()
}

/// コマンド行の字 (行頭の "$ " か "  " を外し、折り返した行を空白でつなぐ)
fn command_text(f: &Frame) -> String {
    command_lines(f)
        .iter()
        .map(|l| l.text()[2..].to_string())
        .collect::<Vec<_>>()
        .join(" ")
}

/// コマンド行のうち、選んでいる項目の字 (行ごとにつなぎ、折り返した行は空白でつなぐ)
fn selected(f: &Frame) -> String {
    command_lines(f)
        .iter()
        .map(|l| {
            l.spans
                .iter()
                .filter(|s| s.style == Style::Selected)
                .map(|s| s.text.as_str())
                .collect::<String>()
        })
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// コマンド行のうち、灰色の括弧 (付けない値) の字
fn absent(f: &Frame) -> Vec<String> {
    command_lines(f)
        .iter()
        .flat_map(|l| l.spans.iter())
        .filter(|s| s.style == Style::Absent)
        .map(|s| s.text.clone())
        .collect()
}

/// カーソルの行 (「> 」で始まる行) の字
fn cursor_line(f: &Frame) -> String {
    let rows: Vec<String> = f
        .lines
        .iter()
        .map(Line::text)
        .filter(|t| t.starts_with("> "))
        .collect();
    assert_eq!(rows.len(), 1, "{}", f.text());
    rows[0].clone()
}

/// 端末の上の桁数を、字ごとに数える (ASCII は 1 桁、ほかは 2 桁。試験の字はどちらか)
fn columns(s: &str) -> usize {
    s.chars().map(|c| if c.is_ascii() { 1 } else { 2 }).sum()
}

#[test]
fn enter_once_launches_the_defaults() {
    let mut u = ui();
    let plan = launched(u.handle(Key::Enter));
    assert_eq!(plan.program, PathBuf::from("/bin/claude"));
    assert_eq!(
        strs(&plan.args),
        [
            "--effort",
            "max",
            "--model",
            "claude-opus-5-5",
            "--dangerously-skip-permissions"
        ]
    );
    assert_eq!(
        plan.shown,
        "claude --effort max --model claude-opus-5-5 --dangerously-skip-permissions"
    );
}

#[test]
fn first_screen_shows_the_command_line_above_the_accounts() {
    let f = ui().frame(COLS, ROWS);
    let lines: Vec<String> = f.lines.iter().map(Line::text).collect();
    // 一番上に見出しとキーの案内
    assert!(lines[0].starts_with("claude-selector   "), "{lines:?}");
    for want in ["←→ / h l 項目", "↑↓ / j k 値", "Enter 起こす", "Esc やめる"] {
        assert!(lines[0].contains(want), "{want}: {lines:?}");
    }
    // その下にコマンド行。付けない Remote Control は灰色の括弧
    assert_eq!(
        lines[1],
        "$ claude --effort max --model claude-opus-5-5 --dangerously-skip-permissions [--remote-control]"
    );
    assert_eq!(absent(&f), ["[--remote-control]"]);
    // 打った直後はアカウントの項目
    assert_eq!(selected(&f), "claude");
    // その下に項目の名前とアカウントの一覧 (カーソルは素の claude)
    let at = lines.iter().position(|l| l.starts_with("> ")).unwrap();
    assert!(
        lines[2..at].iter().any(|l| l == "  アカウント"),
        "{lines:?}"
    );
    assert!(lines[at].contains("(既定)  ~/.claude"), "{lines:?}");
    for name in ["claude-personal", "claude-work", "claude-token1"] {
        assert!(
            lines[at + 1..]
                .iter()
                .any(|l| l.starts_with(&format!("  {name}"))),
            "{name}: {lines:?}"
        );
    }
    assert_eq!(f.cursor, None);
}

#[test]
fn left_right_move_between_the_fields() {
    let mut u = ui();
    let fields = [
        ("claude", "アカウント"),
        ("--effort max", "effort"),
        ("--model claude-opus-5-5", "モデル"),
        ("--dangerously-skip-permissions", "権限"),
        ("[--remote-control]", "Remote Control"),
    ];
    let check = |u: &Ui, (part, title): (&str, &str)| {
        let f = u.frame(COLS, ROWS);
        assert_eq!(selected(&f), part, "{}", f.text());
        assert!(
            f.lines.iter().any(|l| l.text() == format!("  {title}")),
            "{title}: {}",
            f.text()
        );
    };
    check(&u, fields[0]);
    for field in &fields[1..] {
        press(&mut u, &[Key::Right]);
        check(&u, *field);
    }
    // 端で止まる
    press(&mut u, &[Key::Right]);
    check(&u, fields[4]);
    for field in fields[..4].iter().rev() {
        press(&mut u, &[Key::Left]);
        check(&u, *field);
    }
    press(&mut u, &[Key::Left]);
    check(&u, fields[0]);
    // h・l も
    press(&mut u, &[Key::Char('l'), Key::Char('l')]);
    check(&u, fields[2]);
    press(&mut u, &[Key::Char('h')]);
    check(&u, fields[1]);
}

#[test]
fn fields_list_their_values() {
    let mut u = ui();
    // (カーソルの行 = 既定, ほかの行)。effort → モデル → 権限 → Remote Control
    let lists: [(&str, &[&str]); 4] = [
        ("max", &["low", "medium", "high", "xhigh"]),
        (
            "claude-opus-5-5",
            &[
                "claude-sonnet-5-5",
                "claude-haiku-5-5",
                "claude-fable-5-2",
                "claude-fable-5-1",
                "手で打つ",
            ],
        ),
        (
            "--dangerously-skip-permissions",
            &[
                "--permission-mode auto",
                "付けない",
                "--permission-mode acceptEdits",
                "--permission-mode plan",
            ],
        ),
        ("付けない", &["名前なしで付ける", "名前を付ける"]),
    ];
    for (current, others) in lists {
        press(&mut u, &[Key::Right]);
        let f = u.frame(COLS, ROWS);
        let lines: Vec<String> = f.lines.iter().map(Line::text).collect();
        let cur = cursor_line(&f);
        assert!(cur.starts_with(&format!("> {current} ")), "{cur}");
        // 既定の印は一覧に 1 つ (カーソルの初めの位置は既定)
        assert!(cur.contains("(既定)"), "{cur}");
        assert_eq!(
            lines.iter().filter(|l| l.contains("(既定)")).count(),
            1,
            "{lines:?}"
        );
        for o in others {
            assert!(
                lines.iter().any(|l| l.starts_with(&format!("  {o}"))),
                "{o}: {lines:?}"
            );
        }
    }
    // 説明: 権限は既定の印の後ろ、Remote Control は付ける形
    let text = u.frame(COLS, ROWS).text();
    let row = |label: &str| {
        text.lines()
            .find(|l| l.starts_with(&format!("  {label}")))
            .unwrap()
            .to_string()
    };
    assert!(row("名前なしで付ける").ends_with("  --remote-control="));
    assert!(row("名前を付ける").ends_with("  --remote-control=<名前>"));
    let mut u = ui();
    press(&mut u, &TO_PERMISSION);
    assert!(
        cursor_line(&u.frame(COLS, ROWS))
            .ends_with("--dangerously-skip-permissions  (既定)  確認をすべて飛ばす")
    );
}

#[test]
fn up_down_change_the_value_at_once() {
    let mut u = ui();
    press(&mut u, &[Key::Right, Key::Up]);
    let f = u.frame(COLS, ROWS);
    assert!(cursor_line(&f).starts_with("> xhigh"), "{}", f.text());
    assert_eq!(selected(&f), "--effort xhigh");
    assert_eq!(
        command_text(&f),
        "claude --effort xhigh --model claude-opus-5-5 --dangerously-skip-permissions [--remote-control]"
    );
    for (key, want) in [
        (Key::Home, "--effort low"),
        (Key::Char('j'), "--effort medium"),
        (Key::Char('j'), "--effort high"),
        (Key::Char('k'), "--effort medium"),
        (Key::End, "--effort max"),
        // 端で止まる
        (Key::Down, "--effort max"),
        (Key::Up, "--effort xhigh"),
    ] {
        press(&mut u, &[key]);
        assert_eq!(selected(&u.frame(COLS, ROWS)), want, "{key:?}");
    }
    // 項目を移っても値は残る
    press(&mut u, &[Key::Right, Key::Left]);
    assert_eq!(selected(&u.frame(COLS, ROWS)), "--effort xhigh");
    // Enter はどの項目にいても、今のコマンド行のまま起こす
    press(&mut u, &[Key::Right, Key::Right]);
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(
        strs(&plan.args),
        [
            "--effort",
            "xhigh",
            "--model",
            "claude-opus-5-5",
            "--dangerously-skip-permissions"
        ]
    );
}

#[test]
fn accounts_skip_missing_launchers() {
    let mut u = ui();
    press(&mut u, &[Key::Down]);
    let f = u.frame(COLS, ROWS);
    assert!(cursor_line(&f).starts_with("> claude-personal"));
    assert_eq!(selected(&f), "claude-personal");
    // work は launcher が無いので飛ばして token1
    press(&mut u, &[Key::Down]);
    assert!(cursor_line(&u.frame(COLS, ROWS)).starts_with("> claude-token1"));
    // 端では止まる
    press(&mut u, &[Key::Down, Key::Down]);
    assert!(cursor_line(&u.frame(COLS, ROWS)).starts_with("> claude-token1"));
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(plan.program, PathBuf::from("/bin/claude-token1"));
    assert_eq!(
        plan.shown,
        "claude-token1 --effort max --model claude-opus-5-5 --dangerously-skip-permissions"
    );
    let text = ui().frame(COLS, ROWS).text();
    assert!(text.contains("claude-work"), "{text}");
    assert!(text.contains("launcher が PATH に無い"), "{text}");
    assert!(text.contains("~/.claude-token1 (token)"), "{text}");
}

#[test]
fn nothing_to_launch_without_claude_and_launchers() {
    let f = Found {
        claude: None,
        accounts: vec![account("work", Mode::Subscription, false)],
        warnings: Vec::new(),
    };
    let mut u = Ui::new(&f, "~/.claude", Vec::new());
    assert_eq!(press(&mut u, &[Key::Enter]), Outcome::Continue);
    let text = u.frame(COLS, ROWS).text();
    assert!(text.contains("claude は選べません"), "{text}");
    assert!(text.contains("PATH に claude が無い"), "{text}");
    // ほかの項目からも起こさず、アカウントの項目へ戻る
    assert_eq!(
        press(&mut u, &[Key::Right, Key::Right, Key::Enter]),
        Outcome::Continue
    );
    let f = u.frame(COLS, ROWS);
    assert!(f.text().contains("claude は選べません"), "{}", f.text());
    assert_eq!(selected(&f), "claude");
    // 知らせは次のキーで消える
    press(&mut u, &[Key::Right]);
    assert!(!u.frame(COLS, ROWS).text().contains("選べません"));
}

#[test]
fn first_usable_account_when_claude_is_missing() {
    let mut f = found();
    f.claude = None;
    let mut u = Ui::new(&f, "~/.claude", Vec::new());
    assert!(cursor_line(&u.frame(COLS, ROWS)).starts_with("> claude-personal"));
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(plan.program, PathBuf::from("/bin/claude-personal"));
}

#[test]
fn values_left_out_are_grey_brackets_and_not_passed() {
    let mut u = ui();
    press(&mut u, &TO_PERMISSION);
    let want = [
        "--dangerously-skip-permissions",
        "--permission-mode auto",
        "[--permission-mode]",
        "--permission-mode acceptEdits",
        "--permission-mode plan",
    ];
    assert_eq!(selected(&u.frame(COLS, ROWS)), want[0]);
    for w in &want[1..] {
        press(&mut u, &[Key::Down]);
        assert_eq!(selected(&u.frame(COLS, ROWS)), *w);
    }
    // 付けないに戻し、ほかの項目へ移ると灰色の括弧
    press(&mut u, &[Key::Up, Key::Up, Key::Left]);
    let f = u.frame(COLS, ROWS);
    assert_eq!(
        command_text(&f),
        "claude --effort max --model claude-opus-5-5 [--permission-mode] [--remote-control]"
    );
    assert_eq!(absent(&f), ["[--permission-mode]", "[--remote-control]"]);
    // claude には渡さない
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(
        strs(&plan.args),
        ["--effort", "max", "--model", "claude-opus-5-5"]
    );
    assert_eq!(plan.shown, "claude --effort max --model claude-opus-5-5");
}

#[test]
fn typed_model() {
    let mut u = ui();
    press(&mut u, &TO_MODEL);
    press(&mut u, &[Key::End]);
    let f = u.frame(COLS, ROWS);
    assert!(cursor_line(&f).starts_with("> 手で打つ"), "{}", f.text());
    // 打つ前は名前の形を見せ、Enter は打ち始める (起こさない)
    assert_eq!(selected(&f), "--model <モデル名>");
    assert!(
        f.lines[0].text().contains("Enter 名前を打つ"),
        "{}",
        f.text()
    );
    assert_eq!(press(&mut u, &[Key::Enter]), Outcome::Continue);
    let f = u.frame(COLS, ROWS);
    assert!(f.cursor.is_some(), "打つ間はカーソルを出す");
    assert!(f.text().contains("モデルの名前: "), "{}", f.text());
    assert!(f.lines[0].text().contains("Enter 決める"), "{}", f.text());
    typed(&mut u, "fable");
    let f = u.frame(COLS, ROWS);
    // 打った字はすぐコマンド行に出る
    assert_eq!(selected(&f), "--model fable");
    let (row, col) = f.cursor.unwrap();
    assert!(f.lines[row].text().ends_with("モデルの名前: fable"));
    assert_eq!(col, columns("  モデルの名前: fable"));
    // Enter で決めて一覧へ戻る (一覧の行に打った名前が出る)
    assert_eq!(press(&mut u, &[Key::Enter]), Outcome::Continue);
    let f = u.frame(COLS, ROWS);
    assert_eq!(f.cursor, None);
    let current = cursor_line(&f);
    assert!(
        current.starts_with("> 手で打つ") && current.ends_with("fable"),
        "{current}"
    );
    assert_eq!(selected(&f), "--model fable");
    assert!(f.lines[0].text().contains("Enter 起こす"), "{}", f.text());
    // もう一度 Enter で起こす
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args)[2..4], ["--model", "fable"]);
}

#[test]
fn typed_model_must_be_a_name() {
    let mut u = ui();
    press(&mut u, &TO_MODEL);
    press(&mut u, &[Key::End, Key::Enter]);
    // 空では決まらない
    press(&mut u, &[Key::Enter]);
    let text = u.frame(COLS, ROWS).text();
    assert!(text.contains("モデルの名前を入れてください"), "{text}");
    typed(&mut u, "-x");
    press(&mut u, &[Key::Enter]);
    let f = u.frame(COLS, ROWS);
    assert!(
        f.text().contains("- で始まる名前は使えません"),
        "{}",
        f.text()
    );
    assert!(f.cursor.is_some(), "打ち直す");
    // Ctrl+U で消し、空で Backspace なら一覧へ戻る (何も決めていない)
    press(&mut u, &[Key::ClearLine, Key::Backspace]);
    let f = u.frame(COLS, ROWS);
    assert_eq!(f.cursor, None);
    assert!(cursor_line(&f).starts_with("> 手で打つ"));
    assert_eq!(selected(&f), "--model <モデル名>");
    // ← も空なら一覧へ戻る
    press(&mut u, &[Key::Enter, Key::Left]);
    assert_eq!(u.frame(COLS, ROWS).cursor, None);
    // 決めてから動いて戻ると、Enter は決めた名前から打ち直す
    press(&mut u, &[Key::Enter]);
    typed(&mut u, "opus");
    press(&mut u, &[Key::Enter, Key::Up, Key::Down]);
    assert_eq!(selected(&u.frame(COLS, ROWS)), "--model opus");
    assert_eq!(press(&mut u, &[Key::Enter]), Outcome::Continue);
    let f = u.frame(COLS, ROWS);
    assert!(f.cursor.is_some());
    assert!(f.text().contains("モデルの名前: opus"), "{}", f.text());
    // 打つ間の h・j・k・l は字
    typed(&mut u, "hjkl");
    assert_eq!(selected(&u.frame(COLS, ROWS)), "--model opushjkl");
}

#[test]
fn remote_control_names() {
    // 名前なし
    let mut u = ui();
    press(&mut u, &TO_RC);
    press(&mut u, &[Key::Down]);
    assert_eq!(selected(&u.frame(COLS, ROWS)), "--remote-control=");
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args).last().unwrap(), "--remote-control=");
    // 名前を付ける
    let mut u = ui();
    press(&mut u, &TO_RC);
    press(&mut u, &[Key::End]);
    assert_eq!(selected(&u.frame(COLS, ROWS)), "--remote-control=<名前>");
    press(&mut u, &[Key::Enter]);
    typed(&mut u, " 作業 1 ");
    press(&mut u, &[Key::Enter]);
    let f = u.frame(COLS, ROWS);
    assert_eq!(f.cursor, None);
    assert_eq!(selected(&f), "'--remote-control=作業 1'");
    let current = cursor_line(&f);
    assert!(
        current.starts_with("> 名前を付ける") && current.ends_with("--remote-control=作業 1"),
        "{current}"
    );
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args).last().unwrap(), "--remote-control=作業 1");
    // 空のまま決めると名前なし (カーソルは名前なしの行へ)
    let mut u = ui();
    press(&mut u, &TO_RC);
    press(&mut u, &[Key::End, Key::Enter, Key::Enter]);
    let f = u.frame(COLS, ROWS);
    assert!(cursor_line(&f).starts_with("> 名前なしで付ける"));
    assert_eq!(selected(&f), "--remote-control=");
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args).last().unwrap(), "--remote-control=");
}

#[test]
fn empty_remote_control_name_previews_unnamed() {
    let mut u = ui();
    press(&mut u, &TO_RC);
    press(&mut u, &[Key::End]);
    // 打つ前は名前の形を見せる
    assert_eq!(selected(&u.frame(COLS, ROWS)), "--remote-control=<名前>");
    // 打ち始めて字が空なら、Enter で決まる名前なし
    press(&mut u, &[Key::Enter]);
    assert_eq!(selected(&u.frame(COLS, ROWS)), "--remote-control=");
    typed(&mut u, "x");
    assert_eq!(selected(&u.frame(COLS, ROWS)), "--remote-control=x");
}

#[test]
fn placeholders_are_never_launched() {
    // 手で打つに置いたまま権限の項目へ移って Enter: 起こさず、モデルの名前を打ち始める
    let mut u = ui();
    press(&mut u, &TO_MODEL);
    press(&mut u, &[Key::End, Key::Right]);
    assert_eq!(press(&mut u, &[Key::Enter]), Outcome::Continue);
    let f = u.frame(COLS, ROWS);
    assert!(f.cursor.is_some(), "{}", f.text());
    assert!(f.text().contains("モデルの名前: "), "{}", f.text());
    assert_eq!(selected(&f), "--model <モデル名>");
    typed(&mut u, "opus");
    press(&mut u, &[Key::Enter]);
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args)[2..4], ["--model", "opus"]);
    // Remote Control の名前も (アカウントの項目まで戻って Enter)
    let mut u = ui();
    press(&mut u, &TO_RC);
    press(
        &mut u,
        &[Key::End, Key::Left, Key::Left, Key::Left, Key::Left],
    );
    assert_eq!(press(&mut u, &[Key::Enter]), Outcome::Continue);
    let f = u.frame(COLS, ROWS);
    assert!(f.text().contains("Remote Control の名前: "), "{}", f.text());
    assert_eq!(selected(&f), "--remote-control=");
}

#[test]
fn esc_and_ctrl_c_cancel_everywhere() {
    for keys in [
        vec![Key::Esc],
        vec![Key::Interrupt],
        vec![Key::Right, Key::Right, Key::Esc],
        vec![Key::Right, Key::Down, Key::Interrupt],
        // 字を打つ間
        vec![
            Key::Right,
            Key::Right,
            Key::End,
            Key::Enter,
            Key::Char('x'),
            Key::Esc,
        ],
        vec![Key::Right, Key::Right, Key::End, Key::Enter, Key::Interrupt],
        // 最後の項目
        TO_RC.into_iter().chain([Key::Esc]).collect(),
    ] {
        let mut u = ui();
        assert_eq!(press(&mut u, &keys), Outcome::Cancel, "{keys:?}");
    }
}

#[test]
fn extra_args_go_last() {
    let extra: Vec<OsString> = vec!["-c".into(), "質問 です".into()];
    let mut u = Ui::new(&found(), "~/.claude", extra);
    let f = u.frame(COLS, ROWS);
    assert_eq!(
        command_text(&f),
        "claude --effort max --model claude-opus-5-5 --dangerously-skip-permissions [--remote-control] -c '質問 です'"
    );
    // 項目にはしない
    press(&mut u, &[Key::Right; 6]);
    assert_eq!(selected(&u.frame(COLS, ROWS)), "[--remote-control]");
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args)[5..], ["-c", "質問 です"]);
    assert!(
        plan.shown
            .ends_with("--dangerously-skip-permissions -c '質問 です'")
    );
}

#[test]
fn shown_line_is_the_command_line_without_the_brackets() {
    let extra: Vec<OsString> = vec!["-c".into()];
    let cases: [&[Key]; 4] = [
        &[],
        &[Key::Down, Key::Right, Key::Up],
        &[Key::Right, Key::Right, Key::Right, Key::Down, Key::Down],
        &[
            Key::Right,
            Key::Right,
            Key::Right,
            Key::Right,
            Key::End,
            Key::Enter,
            Key::Char('a'),
            Key::Enter,
        ],
    ];
    for keys in cases {
        let mut u = Ui::new(&found(), "~/.claude", extra.clone());
        press(&mut u, keys);
        let screen = command_text(&u.frame(COLS, ROWS))
            .replace(" [--permission-mode]", "")
            .replace(" [--remote-control]", "");
        let plan = launched(press(&mut u, &[Key::Enter]));
        assert_eq!(plan.shown, screen, "{keys:?}");
    }
    // 手で打ったモデルの名前は、起こす行と同じく引用する (名前の形 <モデル名> だけは引用しない。打った字が同じ形でも引用する)
    for (name, want) in [
        ("claude-opus-5-5[1m]", "--model 'claude-opus-5-5[1m]'"),
        ("<モデル名>", "--model '<モデル名>'"),
    ] {
        let mut u = ui();
        press(&mut u, &TO_MODEL);
        press(&mut u, &[Key::End]);
        assert_eq!(selected(&u.frame(COLS, ROWS)), "--model <モデル名>");
        press(&mut u, &[Key::Enter]);
        typed(&mut u, name);
        press(&mut u, &[Key::Enter]);
        let f = u.frame(COLS, ROWS);
        assert_eq!(selected(&f), want);
        let screen = command_text(&f).replace(" [--remote-control]", "");
        let plan = launched(press(&mut u, &[Key::Enter]));
        assert_eq!(plan.shown, screen);
        assert_eq!(strs(&plan.args)[2..4], ["--model", name]);
    }
}

#[test]
fn no_color_marks_the_selected_part() {
    let mut u = Ui::new(&found(), "~/.claude", Vec::new()).with_color(false);
    let line = |u: &Ui| command_lines(&u.frame(COLS, ROWS))[0].text();
    assert_eq!(
        line(&u),
        "$ {claude} --effort max --model claude-opus-5-5 --dangerously-skip-permissions [--remote-control]"
    );
    press(&mut u, &[Key::Right]);
    assert_eq!(
        line(&u),
        "$ claude {--effort max} --model claude-opus-5-5 --dangerously-skip-permissions [--remote-control]"
    );
    press(&mut u, &[Key::Right; 3]);
    assert_eq!(
        line(&u),
        "$ claude --effort max --model claude-opus-5-5 --dangerously-skip-permissions {[--remote-control]}"
    );
    // 起こす行には付けない
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert!(!plan.shown.contains('{'), "{}", plan.shown);
    // 色を付けるときは付けない
    assert!(!ui().frame(COLS, ROWS).text().contains('{'));
}

#[test]
fn defaults_are_marked_before_the_notes() {
    let f = ui().frame(COLS, ROWS);
    let lines: Vec<String> = f.lines.iter().map(Line::text).collect();
    let current = cursor_line(&f);
    // 印は説明より前 (狭い端末で行の後ろが切れても見える)
    assert!(current.contains("(既定)  ~/.claude"), "{current}");
    assert_eq!(lines.iter().filter(|l| l.contains("(既定)")).count(), 1);
    // 説明のそろえ: 印の無い行も同じ桁から説明が始まる
    let personal = lines
        .iter()
        .find(|l| l.contains("claude-personal"))
        .unwrap();
    let column = |l: &str| UnicodeWidthStr::width(&l[..l.find("~/.claude").unwrap()]);
    assert_eq!(column(&current), column(personal), "{current}\n{personal}");
}

#[test]
fn frame_height_stays_while_moving() {
    let mut u = ui();
    let height = u.frame(COLS, ROWS).lines.len();
    for keys in [
        &[Key::Right][..],
        &[Key::Right],
        &[Key::End],
        // 字を打つ間も
        &[Key::Enter],
        &[Key::Char('x'), Key::Enter],
        &[Key::Right],
        &[Key::Right],
    ] {
        press(&mut u, keys);
        let f = u.frame(COLS, ROWS);
        assert_eq!(f.lines.len(), height, "{keys:?}\n{}", f.text());
    }
}

#[test]
fn warnings_are_shown() {
    let mut f = found();
    f.warnings.push("登録の一覧が読めない".to_string());
    let u = Ui::new(&f, "~/.claude", Vec::new());
    assert!(
        u.frame(COLS, ROWS)
            .text()
            .contains("! 登録の一覧が読めない")
    );
}

#[test]
fn claude_note_follows_claude_config_dir() {
    assert_eq!(claude_note(None), "~/.claude");
    assert_eq!(claude_note(Some(OsString::new())), "~/.claude");
    assert_eq!(
        claude_note(Some(OsString::from("/home/u/.claude-work"))),
        "CLAUDE_CONFIG_DIR=/home/u/.claude-work"
    );
    let u = Ui::new(&found(), &claude_note(Some("/x".into())), Vec::new());
    assert!(u.frame(COLS, ROWS).text().contains("CLAUDE_CONFIG_DIR=/x"));
}

#[test]
fn command_line_wraps_to_the_width() {
    let extra: Vec<OsString> = vec!["-c".into(), "質問 です".into()];
    let mut u = Ui::new(&found(), "~/.claude", extra);
    press(&mut u, &[Key::Down]);
    let full = "claude-personal --effort max --model claude-opus-5-5 --dangerously-skip-permissions [--remote-control] -c '質問 です'";
    let squeeze = |s: &str| s.replace(' ', "");
    for (keys, part) in [
        (&[][..], "claude-personal"),
        (&[Key::Right, Key::Right][..], "--model claude-opus-5-5"),
        (&[Key::Right, Key::Right][..], "[--remote-control]"),
    ] {
        press(&mut u, keys);
        for cols in [12, 20, 40, 80, 200] {
            let f = u.frame(cols, ROWS);
            let parts: Vec<String> = command_lines(&f).iter().map(|l| l.text()).collect();
            assert!(parts[0].starts_with("$ "), "{cols}: {parts:?}");
            for p in &parts[1..] {
                assert!(p.starts_with("  "), "{cols}: {parts:?}");
            }
            // どの行も幅に収まり、字を落とさない (空白で切ったところは空白が消える)
            for p in &parts {
                assert!(UnicodeWidthStr::width(p.as_str()) <= cols, "{cols}: {p:?}");
            }
            assert_eq!(
                squeeze(&command_text(&f)),
                squeeze(full),
                "{cols}: {parts:?}"
            );
            // 折り返した先でも、選んでいる項目の見せ方を保つ
            assert_eq!(squeeze(&selected(&f)), squeeze(part), "{cols}: {parts:?}");
        }
    }
    assert_eq!(command_lines(&u.frame(200, ROWS)).len(), 1);
}

#[test]
fn control_characters_are_shown_escaped() {
    let extra: Vec<OsString> = vec!["a\nb".into(), "\u{1b}[31m".into()];
    let mut u = Ui::new(&found(), "~/.claude", extra);
    for keys in [&[][..], &TO_RC[..]] {
        press(&mut u, keys);
        let f = u.frame(COLS, ROWS);
        for l in &f.lines {
            let t = l.text();
            assert!(!t.chars().any(char::is_control), "{t:?}");
        }
        let text = command_text(&f);
        assert!(text.contains("a\\nb"), "{text}");
        assert!(text.contains("\\u{1b}[31m"), "{text}");
    }
    // 起こすのは argv のまま
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args)[5..], ["a\nb", "\u{1b}[31m"]);
}

#[test]
fn small_terminal_keeps_the_cursor_row_visible() {
    let mut f = found();
    f.accounts = (0..20)
        .map(|i| account(&format!("a{i:02}"), Mode::Subscription, true))
        .collect();
    let mut u = Ui::new(&f, "~/.claude", Vec::new());
    let rows = 8;
    let check = |u: &Ui, want: &str| {
        let f = u.frame(80, rows);
        assert!(f.lines.len() <= rows, "{}", f.text());
        assert!(
            f.lines[0].text().starts_with("claude-selector"),
            "{}",
            f.text()
        );
        assert!(!command_lines(&f).is_empty(), "{}", f.text());
        assert!(cursor_line(&f).contains(want), "{want}: {}", f.text());
    };
    check(&u, "claude ");
    press(&mut u, &[Key::End]);
    check(&u, "claude-a19");
    press(&mut u, &[Key::Up, Key::Up, Key::Up]);
    check(&u, "claude-a16");
    press(&mut u, &[Key::Home]);
    check(&u, "claude ");
}

#[test]
fn small_terminal_keeps_the_title_command_and_cursor_row() {
    let mut u = ui();
    press(&mut u, &[Key::Right]);
    for rows in [3, 4, 5] {
        let f = u.frame(COLS, rows);
        assert!(f.lines.len() <= rows, "{rows}: {}", f.text());
        assert!(
            f.lines[0].text().starts_with("claude-selector"),
            "{rows}: {}",
            f.text()
        );
        assert_eq!(selected(&f), "--effort max", "{rows}: {}", f.text());
        assert!(cursor_line(&f).starts_with("> max"), "{rows}: {}", f.text());
    }
    // 知らせも残す
    let mut f = found();
    f.claude = None;
    f.accounts.clear();
    let mut u = Ui::new(&f, "~/.claude", Vec::new());
    press(&mut u, &[Key::Enter]);
    let f = u.frame(COLS, 4);
    assert!(f.lines.len() <= 4, "{}", f.text());
    assert!(f.text().contains("claude は選べません"), "{}", f.text());
    // 字を打つ間は、打つ行を残す
    let mut u = ui();
    press(&mut u, &TO_MODEL);
    press(&mut u, &[Key::End, Key::Enter]);
    let f = u.frame(COLS, 3);
    assert!(f.lines.len() <= 3, "{}", f.text());
    let (row, _) = f.cursor.unwrap();
    assert!(
        f.lines[row].text().contains("モデルの名前: "),
        "{}",
        f.text()
    );
}
