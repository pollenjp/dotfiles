//! 手順の結果の行・締めの表・締めの行・終了コード。
//!
//! 決まりは bootstrap (`win/bootstrap/Install-Bootstrap.ps1`) と同じ: 直すことがある行の頭に ⚠、締めの行は ⚠️ で始めて ⚠️ で終え、
//! 種類ごとに分ける。終了コードは 0 (直すことが無い)・3 (入っていない・無いものだけ)・1 (ほかに直すことがある)。2 (runner が
//! 動けない) は行にせず、cli が返す。

/// 行の種類。`Ok`・`Info`・`Off` は終了コードに数えない。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// 揃っている
    Ok,
    /// 知らせるだけ (runner にまだ無い手順で、受け持ちが WSL のホスト)
    Info,
    /// このホストでは off
    Off,
    /// 入っていない・無い (apply で入れる・作る)
    Missing,
    /// 足りない・ずれている (apply で直る)
    Fix,
    /// runner では直らない (※ の手順で直す)
    Manual,
    /// 確かめられなかった・落ちた
    Failed,
    /// 止める理由 (apply を止めた)
    Blocker,
}

impl Kind {
    /// 直すことがある (終了コードに数える) か
    pub fn needs_attention(self) -> bool {
        matches!(
            self,
            Kind::Missing | Kind::Fix | Kind::Manual | Kind::Failed | Kind::Blocker
        )
    }

    fn mark(self) -> &'static str {
        match self {
            Kind::Ok => "✔",
            Kind::Info => "·",
            Kind::Off => "↷",
            _ => "⚠",
        }
    }
}

/// 締めの表の 1 行。`order` が無い行 (ホストの値など) は順番の欄を空ける。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub order: Option<u16>,
    pub id: String,
    pub kind: Kind,
    pub text: String,
    /// 行の下に出す ※ の行 (直し方など)
    pub notes: Vec<String>,
}

impl Row {
    pub fn new(order: Option<u16>, id: &str, kind: Kind, text: impl Into<String>) -> Self {
        Row {
            order,
            id: id.to_string(),
            kind,
            text: text.into(),
            notes: Vec::new(),
        }
    }

    pub fn with_notes(mut self, notes: Vec<String>) -> Self {
        self.notes = notes;
        self
    }
}

/// 終了コード。直すことが無ければ 0、入っていない・無いものだけなら 3、ほかがあれば 1。
pub fn exit_code(rows: &[Row]) -> i32 {
    let kinds: Vec<Kind> = rows
        .iter()
        .map(|r| r.kind)
        .filter(|k| k.needs_attention())
        .collect();
    if kinds.is_empty() {
        0
    } else if kinds.iter().all(|k| *k == Kind::Missing) {
        3
    } else {
        1
    }
}

/// 締めの表。行ごとに「頭の 2 字・印・順番・id・文」を並べ、※ の行は字下げして続ける。
pub fn format_table(rows: &[Row]) -> Vec<String> {
    let width = rows.iter().map(|r| r.id.len()).max().unwrap_or(0).max(14);
    let mut lines = Vec::new();
    for r in rows {
        let order = match r.order {
            Some(n) => format!("[{n:>2}]"),
            None => "    ".to_string(),
        };
        lines.push(format!(
            "  {} {} {:<width$}  {}",
            r.kind.mark(),
            order,
            r.id,
            r.text
        ));
        for n in &r.notes {
            lines.push(format!("      ※ {n}"));
        }
    }
    lines
}

/// 締めの行 (⚠️ で始めて ⚠️ で終える)。直すことが無ければ「直すことはありません」の 1 行。止めた行があれば、それだけを返す。
pub fn verdict_lines(rows: &[Row]) -> Vec<String> {
    let has = |k: Kind| rows.iter().any(|r| r.kind == k);
    if has(Kind::Blocker) {
        return vec![
            "⚠️ 止めたので何も変えていない → ⚠ の行と ※ の手順で直してから流し直す ⚠️".to_string(),
        ];
    }
    let mut lines = Vec::new();
    if has(Kind::Missing) {
        lines.push("⚠️ 入っていない・無いものがある → dotfiles apply で揃える ⚠️".to_string());
    }
    if has(Kind::Fix) {
        lines.push("⚠️ 足りないもの・ずれているものがある → dotfiles apply で直す ⚠️".to_string());
    }
    if has(Kind::Manual) {
        lines.push("⚠️ runner では直らない差がある → ※ の手順で直す ⚠️".to_string());
    }
    if has(Kind::Failed) {
        lines.push("⚠️ 確かめられなかった・落ちた手順がある → 上の出力を見る ⚠️".to_string());
    }
    if lines.is_empty() {
        lines.push("✔ 直すことはありません".to_string());
    }
    lines
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 終了コード: 行が無い・ok/info/off だけなら 0、missing だけなら 3、ほかが混ざれば 1
    //! - 締めの行: 種類ごとに 1 行・混ざれば並べる・止めた行があればそれだけ・直すことが無ければ 1 行
    //! - 締めの表: 直すことがあれば ⚠、順番の無い行は欄を空け、※ の行を字下げして続ける

    use super::*;

    fn row(kind: Kind) -> Row {
        Row::new(Some(90), "files", kind, "t")
    }

    #[test]
    fn exit_code_is_zero_without_attention() {
        assert_eq!(exit_code(&[]), 0);
        assert_eq!(
            exit_code(&[row(Kind::Ok), row(Kind::Info), row(Kind::Off)]),
            0
        );
    }

    #[test]
    fn exit_code_is_three_when_only_missing() {
        assert_eq!(exit_code(&[row(Kind::Ok), row(Kind::Missing)]), 3);
    }

    #[test]
    fn exit_code_is_one_when_anything_else_needs_attention() {
        for k in [Kind::Fix, Kind::Manual, Kind::Failed, Kind::Blocker] {
            assert_eq!(exit_code(&[row(Kind::Missing), row(k)]), 1, "{k:?}");
            assert_eq!(exit_code(&[row(k)]), 1, "{k:?}");
        }
    }

    #[test]
    fn verdict_lists_each_kind_once() {
        let lines = verdict_lines(&[row(Kind::Missing), row(Kind::Missing), row(Kind::Manual)]);
        assert_eq!(
            lines,
            vec![
                "⚠️ 入っていない・無いものがある → dotfiles apply で揃える ⚠️",
                "⚠️ runner では直らない差がある → ※ の手順で直す ⚠️",
            ]
        );
    }

    #[test]
    fn verdict_with_blocker_is_only_blocker() {
        let lines = verdict_lines(&[row(Kind::Missing), row(Kind::Blocker)]);
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("止めたので何も変えていない"));
    }

    #[test]
    fn verdict_without_attention_says_nothing_to_do() {
        assert_eq!(
            verdict_lines(&[row(Kind::Ok), row(Kind::Off)]),
            vec!["✔ 直すことはありません"]
        );
    }

    #[test]
    fn verdict_fix_and_failed() {
        let lines = verdict_lines(&[row(Kind::Fix), row(Kind::Failed)]);
        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("dotfiles apply で直す"));
        assert!(lines[1].contains("上の出力を見る"));
    }

    #[test]
    fn table_marks_rows_and_indents_notes() {
        let rows = vec![
            Row::new(Some(90), "files", Kind::Ok, "同じ 13"),
            Row::new(Some(97), "ntn", Kind::Missing, "入っていない")
                .with_notes(vec!["Install-Ntn で入れる".to_string()]),
            Row::new(None, "host", Kind::Manual, "無い"),
            Row::new(Some(5), "bootstrap", Kind::Off, "off"),
        ];
        let lines = format_table(&rows);
        assert_eq!(lines[0], "  ✔ [90] files           同じ 13");
        assert_eq!(lines[1], "  ⚠ [97] ntn             入っていない");
        assert_eq!(lines[2], "      ※ Install-Ntn で入れる");
        assert_eq!(lines[3], "  ⚠      host            無い");
        assert_eq!(lines[4], "  ↷ [ 5] bootstrap       off");
    }
}
