//! 画面を閉じた後に端末 (stdout) に残すまとめ。更新・最新・スキップ・失敗 の順に repo を並べる。

use crate::flow::{How, Outcome};

/// 失敗に添える git の stderr の行の数 (最後から。空行は数えない)
const STDERR_LINES: usize = 3;

pub fn render(outcomes: &[(String, Outcome)]) -> String {
    let width = outcomes
        .iter()
        .map(|(label, _)| label.chars().count())
        .max()
        .unwrap_or(0);
    let mut sections: [(&str, Vec<String>); 4] = [
        ("更新", Vec::new()),
        ("最新", Vec::new()),
        ("スキップ", Vec::new()),
        ("失敗", Vec::new()),
    ];
    for (label, outcome) in outcomes {
        let (i, text) = match outcome {
            Outcome::Updated {
                how,
                commits,
                branch,
            } => (0, format!("+{commits} ({})", how_text(*how, branch))),
            Outcome::UpToDate { ahead: 0 } => (1, String::new()),
            Outcome::UpToDate { ahead } => (1, format!("(未 push の commit {ahead})")),
            Outcome::Skipped { reason } => (2, reason.clone()),
            Outcome::Ask(q) => (2, q.reason.label()),
            Outcome::Failed { what, stderr, .. } => {
                let mut text = what.clone();
                let lines: Vec<&str> = stderr.lines().filter(|l| !l.trim().is_empty()).collect();
                for line in &lines[lines.len().saturating_sub(STDERR_LINES)..] {
                    text.push_str(&format!("\n      {}", line.trim_end()));
                }
                (3, text)
            }
        };
        sections[i]
            .1
            .push(format!("  {label:<width$}  {text}").trim_end().to_string());
    }
    let counts: Vec<String> = sections
        .iter()
        .map(|(name, items)| format!("{name} {}", items.len()))
        .collect();
    let mut out = format!(
        "pjp-ghq-pull: {} repo ({})\n",
        outcomes.len(),
        counts.join("・")
    );
    for (name, items) in &sections {
        if items.is_empty() {
            continue;
        }
        out.push_str(&format!("\n{name} ({})\n", items.len()));
        for item in items {
            out.push_str(item);
            out.push('\n');
        }
    }
    out
}

pub fn exit_code(outcomes: &[(String, Outcome)]) -> u8 {
    u8::from(
        outcomes
            .iter()
            .any(|(_, o)| matches!(o, Outcome::Failed { .. })),
    )
}

pub fn how_text(how: How, branch: &str) -> String {
    match how {
        How::FastForward => "fast-forward".into(),
        How::Switched => format!("{branch} に切り替えて fast-forward"),
        How::BranchOnly => format!("checkout せずに {branch} を進めた"),
        How::Merged => "merge commit を作った".into(),
        How::Rebased => "rebase した".into(),
    }
}
