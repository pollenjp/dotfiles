//! 手順の結果の行・締めの表・締めの行・終了コード。
//!
//! 決まりは bootstrap (`win/bootstrap/Install-Bootstrap.ps1`) と同じ: 直すことがある行の頭に ⚠、締めの行は ⚠️ で始めて ⚠️ で終え、
//! 種類ごとに分ける。終了コードは 0 (直すことが無い)・3 (入っていない・無いものだけ)・1 (ほかに直すことがある)。2 (runner が
//! 動けない) は行にせず、cli が返す。

use crate::color::Paint;

/// 行の種類。`Ok`・`Info`・`Off` は終了コードに数えない。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// 揃っている
    Ok,
    /// 知らせるだけ (runner にまだ無い手順で受け持ちが WSL のホスト・受け持ちが WSL なので apply では流さない手順・前提がまだ無いので
    /// 流さない手順)
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

    /// 端末に出すときの色で包む (nix の setup.sh の結果と警告のまとめにそろえる。`color`)
    fn paint(self, paint: Paint, text: &str) -> String {
        match self {
            Kind::Ok => paint.green(text),
            Kind::Info | Kind::Off => paint.dim(text),
            Kind::Missing | Kind::Fix | Kind::Manual => paint.warn(text),
            Kind::Failed | Kind::Blocker => paint.red(text),
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

/// 締めの表。行ごとに「頭の 2 字・印・順番・id・文」を並べ、※ の行は字下げして続ける (色なし。端末に出すときは `paint_table`)。
pub fn format_table(rows: &[Row]) -> Vec<String> {
    paint_table(rows, Paint::OFF)
}

/// 端末に出す締めの表 (字は `format_table` と同じ)。✔ の行は印だけを緑にし、ほかの行は印から行の終わりまでを種類の色にする (直すことが
/// ある ⚠ は太い黄・落ちた・止めた ⚠ は赤・↷ と · は薄く)。※ の行は色を付けない (直し方を読ませる)。
pub fn paint_table(rows: &[Row], paint: Paint) -> Vec<String> {
    let width = rows.iter().map(|r| r.id.len()).max().unwrap_or(0).max(14);
    let mut lines = Vec::new();
    for r in rows {
        let order = match r.order {
            Some(n) => format!("[{n:>2}]"),
            None => "    ".to_string(),
        };
        let body = format!("{order} {:<width$}  {}", r.id, r.text);
        let line = match r.kind {
            // 揃っている行は数が多いので、印だけを緑にして、直すことがある行を目立たせる (setup.sh の結果の ✔ と同じ)
            Kind::Ok => format!("{} {body}", r.kind.paint(paint, r.kind.mark())),
            k => k.paint(paint, &format!("{} {body}", k.mark())),
        };
        lines.push(format!("  {line}"));
        for n in &r.notes {
            lines.push(format!("      ※ {n}"));
        }
    }
    lines
}

/// 締めの行 (⚠️ で始めて ⚠️ で終える)。直すことが無ければ「直すことはありません」の 1 行。止めた行があれば、それだけを返す
/// (色なし。端末に出すときは `paint_verdict`)。
pub fn verdict_lines(rows: &[Row]) -> Vec<String> {
    paint_verdict(rows, Paint::OFF)
}

/// 端末に出す締めの行 (字は `verdict_lines` と同じ)。行を出させた種類の色で行ごと包む (止めた・落ちたは赤・ほかの ⚠️ は太い黄・直すことが
/// 無ければ緑)。
pub fn paint_verdict(rows: &[Row], paint: Paint) -> Vec<String> {
    verdicts(rows)
        .into_iter()
        .map(|(kind, line)| kind.paint(paint, line))
        .collect()
}

/// 締めの行と、それを出させた行の種類 (直すことが無いときの行は `Ok`)。
fn verdicts(rows: &[Row]) -> Vec<(Kind, &'static str)> {
    let has = |k: Kind| rows.iter().any(|r| r.kind == k);
    if has(Kind::Blocker) {
        return vec![(
            Kind::Blocker,
            "⚠️ 止めたので何も変えていない → ⚠ の行と ※ の手順で直してから流し直す ⚠️",
        )];
    }
    let lines: Vec<(Kind, &'static str)> = [
        (
            Kind::Missing,
            "⚠️ 入っていない・無いものがある → dotfiles apply で揃える ⚠️",
        ),
        (
            Kind::Fix,
            "⚠️ 足りないもの・ずれているものがある → dotfiles apply で直す ⚠️",
        ),
        (
            Kind::Manual,
            "⚠️ runner では直らない差がある → ※ の手順で直す ⚠️",
        ),
        (
            Kind::Failed,
            "⚠️ 確かめられなかった・落ちた手順がある → 上の出力を見る ⚠️",
        ),
    ]
    .into_iter()
    .filter(|(k, _)| has(*k))
    .collect();
    if lines.is_empty() {
        return vec![(Kind::Ok, "✔ 直すことはありません")];
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
    //! - 端末に出す表と締めの行の色: 行の種類で色を付け、色を落とすと色なしの字と同じ

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

    /// 端末に出す締めの表: ✔ は印だけ緑、直すことがある行は太い黄、落ちた・止めた行は赤、↷ と · は薄く、※ の行は色なし。色を落とすと
    /// 色なしの表と同じ字
    #[test]
    fn painted_table_colors_by_kind() {
        let rows = vec![
            Row::new(Some(90), "files", Kind::Ok, "同じ 13"),
            Row::new(Some(97), "ntn", Kind::Missing, "入っていない")
                .with_notes(vec!["Install-Ntn で入れる".to_string()]),
            Row::new(None, "host", Kind::Manual, "無い"),
            Row::new(Some(5), "bootstrap", Kind::Off, "off"),
            Row::new(Some(98), "x-pending", Kind::Info, "まだ無い"),
            Row::new(Some(91), "ps1", Kind::Failed, "落ちた"),
            Row::new(Some(92), "fix", Kind::Fix, "ずれている"),
            Row::new(None, "apply", Kind::Blocker, "止めた"),
        ];
        let lines = paint_table(&rows, Paint::ON);
        assert_eq!(
            lines,
            vec![
                "  \u{1b}[32m✔\u{1b}[0m [90] files           同じ 13",
                "  \u{1b}[1;33m⚠ [97] ntn             入っていない\u{1b}[0m",
                "      ※ Install-Ntn で入れる",
                "  \u{1b}[1;33m⚠      host            無い\u{1b}[0m",
                "  \u{1b}[2m↷ [ 5] bootstrap       off\u{1b}[0m",
                "  \u{1b}[2m· [98] x-pending       まだ無い\u{1b}[0m",
                "  \u{1b}[31m⚠ [91] ps1             落ちた\u{1b}[0m",
                "  \u{1b}[1;33m⚠ [92] fix             ずれている\u{1b}[0m",
                "  \u{1b}[31m⚠      apply           止めた\u{1b}[0m",
            ]
        );
        let plain: Vec<String> = lines
            .iter()
            .map(|l| crate::process::strip_ansi(l))
            .collect();
        assert_eq!(plain, format_table(&rows));
        assert_eq!(paint_table(&rows, Paint::OFF), format_table(&rows));
    }

    /// 端末に出す締めの行: 止めた・落ちたは赤、ほかの ⚠️ は太い黄、直すことが無ければ緑。色を付けなければ色なしの締めの行と同じ字
    #[test]
    fn painted_verdict_colors_by_kind() {
        let all = [
            row(Kind::Missing),
            row(Kind::Fix),
            row(Kind::Manual),
            row(Kind::Failed),
        ];
        assert_eq!(
            paint_verdict(&all, Paint::ON),
            vec![
                "\u{1b}[1;33m⚠️ 入っていない・無いものがある → dotfiles apply で揃える ⚠️\u{1b}[0m",
                "\u{1b}[1;33m⚠️ 足りないもの・ずれているものがある → dotfiles apply で直す ⚠️\u{1b}[0m",
                "\u{1b}[1;33m⚠️ runner では直らない差がある → ※ の手順で直す ⚠️\u{1b}[0m",
                "\u{1b}[31m⚠️ 確かめられなかった・落ちた手順がある → 上の出力を見る ⚠️\u{1b}[0m",
            ]
        );
        assert_eq!(
            paint_verdict(&[row(Kind::Missing), row(Kind::Blocker)], Paint::ON),
            vec![
                "\u{1b}[31m⚠️ 止めたので何も変えていない → ⚠ の行と ※ の手順で直してから流し直す ⚠️\u{1b}[0m"
            ]
        );
        assert_eq!(
            paint_verdict(&[row(Kind::Ok), row(Kind::Off), row(Kind::Info)], Paint::ON),
            vec!["\u{1b}[32m✔ 直すことはありません\u{1b}[0m"]
        );
        for rows in [&all[..], &[row(Kind::Blocker)][..], &[row(Kind::Ok)][..]] {
            assert_eq!(paint_verdict(rows, Paint::OFF), verdict_lines(rows));
        }
    }
}
