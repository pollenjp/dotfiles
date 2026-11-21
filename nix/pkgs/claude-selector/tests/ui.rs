//! check: claude-selector-test (nix/flake.nix。package の build の中の cargo test が流す)
//!
//! ## 確かめること
//!
//! 選ぶ画面 (ui::Ui) にキーを並べて流し、起こすもの (launch::Plan) と描く中身 (Frame の字) を見る。端末には触らない。
//!
//! - Enter だけ (5 段 + 確かめる) で既定のまま、PATH の claude を c から --remote-control= を外した引数で起こす
//! - アカウント: ↓ で claude-<名前> へ。launcher の無い行は飛ばし、選べない (Enter で知らせ)。どれも選べなければ起こさない
//! - ← で前の段へ戻り、決めたものは残る (カーソルは決めた行)。j・k・Home・End も動く
//! - モデルを手で打つ: 打つ間はカーソルを出し、下のコマンド行に打った名前が出る。だめな名前は知らせて打ち直し。空で Backspace は一覧へ
//! - Remote Control の名前: `--remote-control=<名前>`。空のまま決めると名前なし (`--remote-control=`)
//! - Esc・Ctrl+C はどこでもやめる (起こさない)
//! - cs の後ろの引数は最後にそのまま付き、見せる行では引用する
//! - 描く中身: 既定の印「(既定)」・カーソルの行の「> 」・一番下のコマンド行・キーの案内・一覧が読めなかった知らせ・確かめる画面の段ごとの値
//!   (cs の後ろの引数があればその行も)
//! - コマンド行は端末の幅で折り返し、字を落とさない (確かめる画面でも全部見える)。引数の制御文字は `\n` などの形で見せ、起こすのは argv のまま
//! - Remote Control の名前を打ち始めて字が空なら、下のコマンド行は名前なし (`--remote-control=`)
//! - 端末の行が足りなければ、一覧はカーソルの行が見える所だけを出し、確かめる画面は段ごとの値を外す (見出し・コマンド行・案内は残す)

use claude_selector::accounts::{Account, Found, Mode};
use claude_selector::app::claude_note;
use claude_selector::launch::Plan;
use claude_selector::ui::{Key, Outcome, Style, Ui};
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

const ENTER6: [Key; 6] = [Key::Enter; 6];
/// 広い端末 (折り返さない・一覧を削らない)
const COLS: usize = 200;
const ROWS: usize = 60;

#[test]
fn enter_only_launches_the_defaults() {
    let mut u = ui();
    let plan = launched(press(&mut u, &ENTER6));
    assert_eq!(plan.program, PathBuf::from("/bin/claude"));
    assert_eq!(
        strs(&plan.args),
        [
            "--dangerously-skip-permissions",
            "--effort",
            "max",
            "--model",
            "claude-opus-5-5"
        ]
    );
    assert_eq!(
        plan.shown,
        "claude --dangerously-skip-permissions --effort max --model claude-opus-5-5"
    );
}

#[test]
fn accounts_skip_missing_launchers() {
    let mut u = ui();
    press(&mut u, &[Key::Down]);
    assert!(u.frame(COLS, ROWS).text().contains("> claude-personal"));
    // work は launcher が無いので飛ばして token1
    press(&mut u, &[Key::Down]);
    assert!(
        u.frame(COLS, ROWS).text().contains("> claude-token1"),
        "{}",
        u.frame(COLS, ROWS).text()
    );
    // 端では止まる
    press(&mut u, &[Key::Down, Key::Down]);
    assert!(u.frame(COLS, ROWS).text().contains("> claude-token1"));
    let plan = launched(press(&mut u, &ENTER6));
    assert_eq!(plan.program, PathBuf::from("/bin/claude-token1"));
    assert!(
        plan.shown
            .starts_with("claude-token1 --dangerously-skip-permissions")
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
    // 段は進んでいない
    assert!(text.contains("[1/5] アカウント"), "{text}");
}

#[test]
fn first_usable_account_when_claude_is_missing() {
    let mut f = found();
    f.claude = None;
    let mut u = Ui::new(&f, "~/.claude", Vec::new());
    assert!(u.frame(COLS, ROWS).text().contains("> claude-personal"));
    let plan = launched(press(&mut u, &ENTER6));
    assert_eq!(plan.program, PathBuf::from("/bin/claude-personal"));
}

#[test]
fn back_keeps_the_choices() {
    let mut u = ui();
    // 権限で plan (5 つ目) を選ぶ
    press(
        &mut u,
        &[
            Key::Enter,
            Key::Down,
            Key::Down,
            Key::Down,
            Key::Down,
            Key::Enter,
        ],
    );
    assert!(u.frame(COLS, ROWS).text().contains("[3/5] effort"));
    press(&mut u, &[Key::Left]);
    let text = u.frame(COLS, ROWS).text();
    assert!(text.contains("[2/5] 権限"), "{text}");
    assert!(text.contains("> --permission-mode plan"), "{text}");
    // Backspace・h も戻る。最初の段ではそれ以上戻らない
    press(&mut u, &[Key::Backspace, Key::Char('h'), Key::Left]);
    assert!(u.frame(COLS, ROWS).text().contains("[1/5] アカウント"));
    let plan = launched(press(&mut u, &ENTER6));
    assert_eq!(strs(&plan.args)[..2], ["--permission-mode", "plan"]);
}

#[test]
fn vim_keys_home_end() {
    let mut u = ui();
    press(&mut u, &[Key::Enter, Key::Enter]);
    // effort は既定の max から
    assert!(u.frame(COLS, ROWS).text().contains("> max"));
    press(&mut u, &[Key::Home]);
    assert!(u.frame(COLS, ROWS).text().contains("> low"));
    press(&mut u, &[Key::Char('j'), Key::Char('j')]);
    assert!(u.frame(COLS, ROWS).text().contains("> high"));
    press(&mut u, &[Key::Char('k')]);
    assert!(u.frame(COLS, ROWS).text().contains("> medium"));
    press(&mut u, &[Key::End]);
    assert!(u.frame(COLS, ROWS).text().contains("> max"));
    press(&mut u, &[Key::Up, Key::Char('l')]);
    assert!(u.frame(COLS, ROWS).text().contains("[4/5] モデル"));
    let plan = launched(press(&mut u, &[Key::Enter, Key::Enter, Key::Enter]));
    assert_eq!(strs(&plan.args)[1..3], ["--effort", "xhigh"]);
}

#[test]
fn typed_model() {
    let mut u = ui();
    press(&mut u, &[Key::Enter, Key::Enter, Key::Enter, Key::End]);
    assert!(u.frame(COLS, ROWS).text().contains("> 手で打つ"));
    press(&mut u, &[Key::Enter]);
    let f = u.frame(COLS, ROWS);
    assert!(f.cursor.is_some(), "打つ間はカーソルを出す");
    assert!(f.text().contains("モデルの名前: "), "{}", f.text());
    typed(&mut u, "fable");
    let f = u.frame(COLS, ROWS);
    assert!(f.text().contains("--model fable"), "{}", f.text());
    let (row, col) = f.cursor.unwrap();
    assert!(f.lines[row].text().ends_with("fable"));
    assert_eq!(
        col,
        "  モデルの名前: fable"
            .chars()
            .map(|c| if c.is_ascii() { 1 } else { 2 })
            .sum::<usize>()
    );
    // Enter で決まり、Remote Control の段へ
    press(&mut u, &[Key::Enter]);
    assert!(u.frame(COLS, ROWS).text().contains("[5/5] Remote Control"));
    assert_eq!(u.frame(COLS, ROWS).cursor, None);
    let plan = launched(press(&mut u, &[Key::Enter, Key::Enter]));
    assert_eq!(strs(&plan.args)[3..5], ["--model", "fable"]);
}

#[test]
fn typed_model_must_be_a_name() {
    let mut u = ui();
    press(
        &mut u,
        &[Key::Enter, Key::Enter, Key::Enter, Key::End, Key::Enter],
    );
    // 空では決まらない
    press(&mut u, &[Key::Enter]);
    assert!(
        u.frame(COLS, ROWS)
            .text()
            .contains("モデルの名前を入れてください")
    );
    typed(&mut u, "-x");
    press(&mut u, &[Key::Enter]);
    let text = u.frame(COLS, ROWS).text();
    assert!(text.contains("- で始まる名前は使えません"), "{text}");
    assert!(text.contains("[4/5] モデル"), "{text}");
    // Ctrl+U で消し、空で Backspace なら一覧へ戻る
    press(&mut u, &[Key::ClearLine, Key::Backspace]);
    let f = u.frame(COLS, ROWS);
    assert_eq!(f.cursor, None);
    assert!(f.text().contains("> 手で打つ"), "{}", f.text());
    // 戻ってきたら決めた名前を打ちかけの字にする
    press(&mut u, &[Key::Enter]);
    typed(&mut u, "opus");
    press(&mut u, &[Key::Enter, Key::Left, Key::Enter]);
    assert!(u.frame(COLS, ROWS).text().contains("モデルの名前: opus"));
}

#[test]
fn remote_control_names() {
    let to_rc = [Key::Enter, Key::Enter, Key::Enter, Key::Enter];
    // 名前なし
    let mut u = ui();
    press(&mut u, &to_rc);
    press(&mut u, &[Key::Down]);
    assert!(u.frame(COLS, ROWS).text().contains("--remote-control="));
    let plan = launched(press(&mut u, &[Key::Enter, Key::Enter]));
    assert_eq!(strs(&plan.args).last().unwrap(), "--remote-control=");
    // 名前を付ける
    let mut u = ui();
    press(&mut u, &to_rc);
    press(&mut u, &[Key::End, Key::Enter]);
    typed(&mut u, " 作業 1 ");
    press(&mut u, &[Key::Enter]);
    let text = u.frame(COLS, ROWS).text();
    assert!(text.contains("これで起こす"), "{text}");
    assert!(text.contains("名前を付ける (作業 1)"), "{text}");
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args).last().unwrap(), "--remote-control=作業 1");
    // 空のまま決めると名前なし
    let mut u = ui();
    press(&mut u, &to_rc);
    press(&mut u, &[Key::End, Key::Enter, Key::Enter]);
    assert!(u.frame(COLS, ROWS).text().contains("名前なしで付ける"));
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args).last().unwrap(), "--remote-control=");
}

#[test]
fn esc_and_ctrl_c_cancel_everywhere() {
    for keys in [
        vec![Key::Esc],
        vec![Key::Interrupt],
        vec![Key::Enter, Key::Enter, Key::Esc],
        // 字を打つ間
        vec![
            Key::Enter,
            Key::Enter,
            Key::Enter,
            Key::End,
            Key::Enter,
            Key::Char('x'),
            Key::Esc,
        ],
        vec![
            Key::Enter,
            Key::Enter,
            Key::Enter,
            Key::End,
            Key::Enter,
            Key::Interrupt,
        ],
        // 確かめる画面
        vec![Key::Enter; 5].into_iter().chain([Key::Esc]).collect(),
    ] {
        let mut u = ui();
        assert_eq!(press(&mut u, &keys), Outcome::Cancel, "{keys:?}");
    }
}

#[test]
fn extra_args_go_last() {
    let extra: Vec<OsString> = vec!["-c".into(), "質問 です".into()];
    let mut u = Ui::new(&found(), "~/.claude", extra);
    let text = u.frame(COLS, ROWS).text();
    assert!(text.contains("claude-opus-5-5 -c '質問 です'"), "{text}");
    let plan = launched(press(&mut u, &ENTER6));
    assert_eq!(strs(&plan.args)[5..], ["-c", "質問 です"]);
}

#[test]
fn frame_marks_defaults_and_shows_the_command() {
    let u = ui();
    let f = u.frame(COLS, ROWS);
    let lines: Vec<String> = f.lines.iter().map(|l| l.text()).collect();
    assert!(
        lines[0].starts_with("claude-selector  [1/5] アカウント"),
        "{lines:?}"
    );
    let current = lines.iter().find(|l| l.starts_with("> ")).unwrap();
    assert!(
        current.contains("claude") && current.contains("~/.claude"),
        "{current}"
    );
    // 印は説明より前 (狭い端末で行の後ろが切れても見える)
    assert!(current.contains("(既定)  ~/.claude"), "{current}");
    assert_eq!(lines.iter().filter(|l| l.contains("(既定)")).count(), 1);
    // 説明のそろえ: 印の無い行も同じ桁から説明が始まる
    let personal = lines
        .iter()
        .find(|l| l.contains("claude-personal"))
        .unwrap();
    let column = |l: &str| UnicodeWidthStr::width(&l[..l.find("~/.claude").unwrap()]);
    assert_eq!(column(current), column(personal), "{current}\n{personal}");
    assert_eq!(
        lines[lines.len() - 2],
        "$ claude --dangerously-skip-permissions --effort max --model claude-opus-5-5"
    );
    assert!(lines.last().unwrap().contains("Enter 決める"));
    assert!(
        !lines.last().unwrap().contains("戻る"),
        "最初の段は戻れない"
    );
    assert_eq!(f.cursor, None);
    // 権限の段: 既定は --dangerously-skip-permissions、カーソルを動かすと下の行が変わる
    let mut u = ui();
    press(&mut u, &[Key::Enter, Key::Down]);
    let text = u.frame(COLS, ROWS).text();
    assert!(
        text.contains("--dangerously-skip-permissions  (既定)  確認をすべて飛ばす"),
        "{text}"
    );
    assert!(
        text.contains("$ claude --permission-mode auto --effort max"),
        "{text}"
    );
    assert!(text.contains("← 戻る"), "{text}");
}

#[test]
fn confirm_screen_lists_the_choices() {
    let mut u = ui();
    press(
        &mut u,
        &[
            Key::Down,
            Key::Enter,
            Key::Enter,
            Key::Enter,
            Key::Enter,
            Key::Enter,
        ],
    );
    let text = u.frame(COLS, ROWS).text();
    assert!(text.contains("これで起こす"), "{text}");
    for want in [
        "アカウント      claude-personal",
        "権限            --dangerously-skip-permissions",
        "effort          max",
        "モデル          claude-opus-5-5",
        "Remote Control  付けない",
        "Enter 起こす",
    ] {
        assert!(text.contains(want), "{want}: {text}");
    }
    // ← で Remote Control の段へ戻る
    press(&mut u, &[Key::Left]);
    assert!(u.frame(COLS, ROWS).text().contains("[5/5] Remote Control"));
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

/// コマンド行の行 (Style::Command の塊を持つ行) の字
fn command_parts(f: &claude_selector::ui::Frame) -> Vec<String> {
    f.lines
        .iter()
        .filter(|l| l.spans.iter().any(|s| s.style == Style::Command))
        .map(|l| l.text())
        .collect()
}

#[test]
fn command_line_wraps_to_the_width() {
    let extra: Vec<OsString> = vec!["-c".into(), "質問 です".into()];
    let mut u = Ui::new(&found(), "~/.claude", extra);
    press(
        &mut u,
        &[
            Key::Down,
            Key::Enter,
            Key::Enter,
            Key::Enter,
            Key::Enter,
            Key::Enter,
        ],
    );
    let full = "claude-personal --dangerously-skip-permissions --effort max --model claude-opus-5-5 -c '質問 です'";
    for cols in [12, 20, 40, 80, 200] {
        let f = u.frame(cols, ROWS);
        let parts = command_parts(&f);
        assert!(parts[0].starts_with("$ "), "{cols}: {parts:?}");
        for p in &parts[1..] {
            assert!(p.starts_with("  "), "{cols}: {parts:?}");
        }
        // どの行も幅に収まり、字を落とさない (空白で切ったところは空白が消える)
        for p in &parts {
            assert!(UnicodeWidthStr::width(p.as_str()) <= cols, "{cols}: {p:?}");
        }
        let joined: String = parts.iter().map(|p| &p[2..]).collect::<Vec<_>>().join(" ");
        assert_eq!(
            joined.replace(' ', ""),
            full.replace(' ', ""),
            "{cols}: {parts:?}"
        );
    }
    assert_eq!(command_parts(&u.frame(200, ROWS)), [format!("$ {full}")]);
}

#[test]
fn confirm_screen_shows_the_extra_args() {
    let extra: Vec<OsString> = vec!["-c".into(), "質問 です".into()];
    let mut u = Ui::new(&found(), "~/.claude", extra);
    press(&mut u, &[Key::Enter; 5]);
    let text = u.frame(COLS, ROWS).text();
    assert!(text.contains("後ろの引数      -c '質問 です'"), "{text}");
    // 後ろの引数が無ければ行も無い
    let mut u = ui();
    press(&mut u, &[Key::Enter; 5]);
    assert!(!u.frame(COLS, ROWS).text().contains("後ろの引数"));
}

#[test]
fn control_characters_are_shown_escaped() {
    let extra: Vec<OsString> = vec!["a\nb".into(), "\u{1b}[31m".into()];
    let mut u = Ui::new(&found(), "~/.claude", extra);
    for keys in [&[][..], &[Key::Enter; 5][..]] {
        press(&mut u, keys);
        let f = u.frame(COLS, ROWS);
        for l in &f.lines {
            let t = l.text();
            assert!(!t.chars().any(char::is_control), "{t:?}");
        }
        let text = f.text();
        assert!(text.contains("a\\nb"), "{text}");
        assert!(text.contains("\\u{1b}[31m"), "{text}");
    }
    // 起こすのは argv のまま
    let plan = launched(press(&mut u, &[Key::Enter]));
    assert_eq!(strs(&plan.args)[5..], ["a\nb", "\u{1b}[31m"]);
}

#[test]
fn empty_remote_control_name_previews_unnamed() {
    let mut u = ui();
    press(
        &mut u,
        &[Key::Enter, Key::Enter, Key::Enter, Key::Enter, Key::End],
    );
    // 打つ前は名前の形を見せる
    let before = command_parts(&u.frame(COLS, ROWS)).join("\n");
    assert!(before.contains("<名前>"), "{before}");
    // 打ち始めて字が空なら、Enter で決まる名前なし
    press(&mut u, &[Key::Enter]);
    let typing = command_parts(&u.frame(COLS, ROWS)).join("\n");
    assert!(typing.ends_with("--remote-control="), "{typing}");
    typed(&mut u, "x");
    let named = command_parts(&u.frame(COLS, ROWS)).join("\n");
    assert!(named.ends_with("--remote-control=x"), "{named}");
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
            f.lines[0].text().starts_with("claude-selector  [1/5]"),
            "{}",
            f.text()
        );
        let current: Vec<String> = f
            .lines
            .iter()
            .map(|l| l.text())
            .filter(|t| t.starts_with("> "))
            .collect();
        assert_eq!(current.len(), 1, "{}", f.text());
        assert!(current[0].contains(want), "{want}: {}", f.text());
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
fn small_terminal_drops_the_summary_on_confirm() {
    let mut u = ui();
    press(&mut u, &[Key::Enter; 5]);
    let f = u.frame(80, 4);
    assert!(f.lines.len() <= 4, "{}", f.text());
    let text = f.text();
    assert!(text.contains("これで起こす"), "{text}");
    assert!(
        text.contains("$ claude --dangerously-skip-permissions"),
        "{text}"
    );
    assert!(text.contains("Enter 起こす"), "{text}");
    assert!(!text.contains("アカウント      claude"), "{text}");
}
