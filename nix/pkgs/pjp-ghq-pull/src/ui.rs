//! 画面を描く (model は selection と run が持つ。ここは描くだけ)。

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, List, ListItem, ListState, Paragraph};

use crate::flow::{Outcome, Phase};
use crate::repo::Head;
use crate::run::{Focus, Run, Status};
use crate::selection::{Mark, Row, Selection};
use crate::summary::how_text;

fn bold() -> Style {
    Style::new().add_modifier(Modifier::BOLD)
}

fn mark_text(mark: Mark) -> &'static str {
    match mark {
        Mark::All => "[x]",
        Mark::Partial => "[-]",
        Mark::None => "[ ]",
    }
}

/// 選ぶ画面: 上に経路と選んだ数、中に org と repo の木、下にキーの説明か知らせ
pub fn draw_select(frame: &mut Frame, sel: &Selection, route: &str) {
    let [head, body, foot] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(0),
        Constraint::Length(1),
    ])
    .areas(frame.area());

    let mut spans = vec![
        Span::styled("pjp-ghq-pull", bold()),
        Span::raw(format!(
            "  経路: {route}  選択 {}/{}",
            sel.selected().len(),
            sel.items().len()
        )),
    ];
    if sel.editing_filter() || !sel.filter().is_empty() {
        spans.push(Span::raw(format!("  絞り込み: {}", sel.filter())));
        if sel.editing_filter() {
            spans.push(Span::styled("▏", Style::new().fg(Color::Cyan)));
        }
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), head);

    let width = sel
        .items()
        .iter()
        .map(|i| i.name.chars().count())
        .max()
        .unwrap_or(0);
    let rows = sel.rows();
    let items: Vec<ListItem> = rows
        .iter()
        .map(|row| ListItem::new(row_line(sel, *row, width)))
        .collect();
    let mut state = ListState::default().with_selected((!rows.is_empty()).then_some(sel.cursor()));
    let list = List::new(items).highlight_style(Style::new().add_modifier(Modifier::REVERSED));
    frame.render_stateful_widget(list, body, &mut state);

    // 80 桁に収める
    let help = if sel.editing_filter() {
        "文字で絞り込み  Backspace:1 字消す  Enter:確定  Esc:消して戻る"
    } else {
        "Space:選ぶ  a:全部  n:外す  ←→:畳む/開く  /:絞り込み  Enter:始める  q:やめる"
    };
    let line = match sel.notice() {
        Some(notice) => Line::styled(notice.to_string(), Style::new().fg(Color::Yellow)),
        None => Line::styled(help, Style::new().fg(Color::DarkGray)),
    };
    frame.render_widget(Paragraph::new(line), foot);
}

fn row_line(sel: &Selection, row: Row, width: usize) -> Line<'static> {
    match row {
        Row::Org(o) => {
            let org = &sel.orgs()[o];
            let arrow = if org.expanded { "▾" } else { "▸" };
            Line::from(vec![
                Span::raw(format!("{arrow} {} ", mark_text(sel.mark(o)))),
                Span::styled(org.name.clone(), bold()),
                Span::raw(format!(" ({})", org.items.len())),
            ])
        }
        Row::Repo(i) => {
            let item = &sel.items()[i];
            let mark = if item.selected { Mark::All } else { Mark::None };
            let (branch, off_default) = match &item.info.head {
                Head::Branch(b) => (
                    b.clone(),
                    item.info.default_branch.as_deref().is_some_and(|d| d != b),
                ),
                Head::Detached => ("(detached)".to_string(), true),
            };
            let branch_style = if off_default {
                Style::new().fg(Color::Yellow)
            } else {
                Style::new().fg(Color::DarkGray)
            };
            let mut spans = vec![
                Span::raw(format!("    {} {:<width$}  ", mark_text(mark), item.name)),
                Span::styled(branch, branch_style),
            ];
            if item.info.dirty {
                spans.push(Span::raw("  "));
                spans.push(Span::styled("変更あり", Style::new().fg(Color::Red)));
            }
            Line::from(spans)
        }
    }
}

/// 確認待ちの欄に並べる問いの数 (今の問いのまわり)
const QUESTION_ROWS: usize = 5;
/// d で出す詳細の行の数
const DETAIL_ROWS: usize = 20;

/// 実行中の画面: 上に経路と進み具合、中に repo ごとの状態、下に確認待ちの欄
pub fn draw_run(frame: &mut Frame, run: &Run, route: &str) {
    let area = frame.area();
    let (ids, q_cursor) = run.waiting_ids();
    let question = run.current_question();
    let detail = match question {
        Some((_, q)) if run.show_detail() => q.detail.lines().take(DETAIL_ROWS).count(),
        _ => 0,
    };
    // 確認待ちの欄の行: 問いの一覧・空行・今の問いの repo・理由・選べること (1 行に 1 つ)・[d]・知らせ・詳細
    let notice = usize::from(run.notice().is_some());
    let q_rows = match question {
        None => 1,
        Some((_, q)) => ids.len().min(QUESTION_ROWS) + 3 + q.choices.len() + 1 + notice + detail,
    };
    let [head, body, questions, foot] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(3),
        Constraint::Length(q_rows as u16 + 2),
        Constraint::Length(1),
    ])
    .areas(area);

    let spans = vec![
        Span::styled("pjp-ghq-pull", bold()),
        Span::raw(format!(
            "  経路: {route}  完了 {}/{}  確認待ち {}",
            run.done(),
            run.labels().len(),
            run.waiting()
        )),
    ];
    frame.render_widget(Paragraph::new(Line::from(spans)), head);

    let width = run
        .labels()
        .iter()
        .map(|l| l.chars().count())
        .max()
        .unwrap_or(0);
    let items: Vec<ListItem> = run
        .labels()
        .iter()
        .enumerate()
        .map(|(id, label)| {
            ListItem::new(Line::from(vec![
                Span::raw(format!("{label:<width$}  ")),
                status_span(run.status(id)),
            ]))
        })
        .collect();
    let list_focus = run.focus() == Focus::List;
    let mut state = ListState::default().with_selected(Some(run.list_cursor()));
    let highlight = if list_focus {
        Style::new().add_modifier(Modifier::REVERSED)
    } else {
        Style::new()
    };
    frame.render_stateful_widget(
        List::new(items).highlight_style(highlight),
        body,
        &mut state,
    );

    let border = if list_focus {
        Style::new().fg(Color::DarkGray)
    } else {
        Style::new().fg(Color::Yellow)
    };
    let block = Block::bordered()
        .border_style(border)
        .title(format!(" 確認待ち {} ", ids.len()));
    let mut lines = Vec::new();
    if ids.is_empty() {
        lines.push(Line::styled(
            "確認待ちはありません",
            Style::new().fg(Color::DarkGray),
        ));
    }
    let first = q_cursor.saturating_sub(QUESTION_ROWS - 1);
    for (pos, &id) in ids.iter().enumerate().skip(first).take(QUESTION_ROWS) {
        let mark = if pos == q_cursor { "> " } else { "  " };
        let reason = match run.status(id) {
            Status::Waiting(q) => q.reason.label(),
            _ => String::new(),
        };
        lines.push(Line::from(vec![
            Span::raw(format!("{mark}{}  ", run.labels()[id])),
            Span::styled(reason, Style::new().fg(Color::Yellow)),
        ]));
    }
    if let Some((id, q)) = question {
        lines.push(Line::raw(""));
        // 答えると次の問い (別の repo) が同じ所に出るので、どの repo の問いかを目立たせる
        lines.push(Line::styled(
            format!("▶ {}", run.labels()[id]),
            Style::new().add_modifier(Modifier::BOLD | Modifier::REVERSED),
        ));
        lines.push(Line::styled(
            q.reason.label(),
            Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        ));
        let branch = q.default_branch.as_deref().unwrap_or("既定 branch");
        let key = Style::new().fg(Color::Cyan).add_modifier(Modifier::BOLD);
        for choice in &q.choices {
            lines.push(Line::from(vec![
                Span::styled(format!("[{}]", choice.key()), key),
                Span::raw(format!(" {}", choice.label(branch))),
            ]));
        }
        lines.push(Line::from(vec![
            Span::styled("[d]", Style::new().fg(Color::Cyan)),
            Span::raw(" 詳細"),
        ]));
        if let Some(notice) = run.notice() {
            lines.push(Line::styled(
                notice.to_string(),
                Style::new().fg(Color::Red).add_modifier(Modifier::BOLD),
            ));
        }
        if run.show_detail() {
            lines.extend(
                q.detail
                    .lines()
                    .take(DETAIL_ROWS)
                    .map(|l| Line::styled(l.to_string(), Style::new().fg(Color::DarkGray))),
            );
        }
    }
    frame.render_widget(Paragraph::new(lines).block(block), questions);

    // 80 桁に収める。やめる途中と、全部が終わったときは知らせに替える
    let foot_line = if run.quitting() {
        Line::styled(
            "やめます: 動いている git が終わるのを待っています",
            Style::new().fg(Color::Yellow),
        )
    } else if run.finished() {
        Line::styled(
            "完了: Enter か q で閉じる",
            Style::new().fg(Color::Green).add_modifier(Modifier::BOLD),
        )
    } else {
        Line::styled(
            "Tab:欄を切り替え  ↑↓:動く  d:詳細  q:やめる (動いている git は待つ)",
            Style::new().fg(Color::DarkGray),
        )
    };
    frame.render_widget(Paragraph::new(foot_line), foot);
}

fn status_span(status: &Status) -> Span<'static> {
    let cyan = Style::new().fg(Color::Cyan);
    let gray = Style::new().fg(Color::DarkGray);
    match status {
        Status::Queued => Span::styled("待ち", gray),
        Status::Working(Phase::Checking) => Span::styled("確認中", cyan),
        Status::Working(Phase::Fetching) => Span::styled("fetch 中", cyan),
        Status::Working(Phase::Updating) => Span::styled("更新中", cyan),
        Status::Waiting(_) | Status::Final(Outcome::Ask(_)) => {
            Span::styled("確認待ち", Style::new().fg(Color::Yellow))
        }
        Status::Final(Outcome::Updated {
            how,
            commits,
            branch,
        }) => Span::styled(
            format!("更新 +{commits} ({})", how_text(*how, branch)),
            Style::new().fg(Color::Green),
        ),
        Status::Final(Outcome::UpToDate { ahead: 0 }) => Span::raw("最新"),
        Status::Final(Outcome::UpToDate { ahead }) => Span::raw(format!("最新 (未 push {ahead})")),
        Status::Final(Outcome::Skipped { reason }) => {
            Span::styled(format!("スキップ ({reason})"), gray)
        }
        Status::Final(Outcome::Failed { what, .. }) => {
            Span::styled(format!("失敗: {what}"), Style::new().fg(Color::Red))
        }
    }
}
