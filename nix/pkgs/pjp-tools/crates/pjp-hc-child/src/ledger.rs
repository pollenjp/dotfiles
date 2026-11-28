//! 子の英字の控え (spec §7.4 の 3)。ハブのマシンの `<XDG_STATE_HOME>/pjp/children/<親のチケット>.tsv` に、親のチケットごとに
//! 1 行 1 子で置く。英字は A…Z・AA… と振り、片付けた子の英字も使い回さない (会話の前の方の「子 A」が、後から別の子を
//! 指さないように)。
//!
//! 書くときは `<親のチケット>.lock` のロックの中で読み直してから、一時ファイルに書いて置き換える (同時に打った
//! `pjp child new` が同じ英字を取らない)。

use std::path::{Path, PathBuf};

use pjp_core::{Error, Result};

/// 控えの列 (この順で tab 区切り)。列を足すときは末尾に足す (前の控えの行は、足りない列を空で読む)。
const COLUMNS: [&str; 19] = [
    "letter",
    "state",
    "terminal",
    "name",
    "machine",
    "repo",
    "checkout",
    "worktree",
    "branch",
    "base",
    "space",
    "tab",
    "created",
    "updated",
    "effort",
    "packs",
    "chrome",
    "account",
    "space_name",
];

/// 子の状態。
pub mod state {
    /// 英字を取った (立てる途中)。
    pub const NEW: &str = "new";
    /// 立てた。
    pub const LIVE: &str = "live";
    /// 片付けた。
    pub const CLEANED: &str = "cleaned";
    /// 立てられなかった (英字は欠番のまま)。
    pub const FAILED: &str = "failed";
}

/// 控えの 1 行 (1 子)。子のマシンのパスは文字のまま持つ。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Row {
    pub letter: String,
    pub state: String,
    /// 子の端末の住所 (`<machine>/t13` の形)。
    pub terminal: String,
    /// 子の端末の名前 (`hc run --name`)。
    pub name: String,
    /// 子のマシン (空はハブと同じマシン)。
    pub machine: String,
    /// `owner/repo` (`--repo` のとき)。
    pub repo: String,
    /// 子のマシンの checkout (worktree を切った元)。
    pub checkout: String,
    /// 子の作業場所 (worktree か `--dir`)。
    pub worktree: String,
    /// worktree を作ったときの branch (`worktree/<名前>`。`--dir` なら空)。
    pub branch: String,
    /// 切った元 (`origin/main` など)。
    pub base: String,
    /// herdr-app の space と tab の id (herdr-app の形のまま。別のマシンなら `<m>/` が付く)。
    pub space: String,
    pub tab: String,
    pub created: String,
    pub updated: String,
    /// 最後に立てたときの effort (`restart` が引き継ぐ)。
    pub effort: String,
    /// 最後に立てたときの pack (空白区切り。同期された skill は `synced:<名前>`)。
    pub packs: String,
    /// 最後に立てたときに `--chrome` を付けたか (`1` か空)。
    pub chrome: String,
    /// 最後に立てたときの Claude のアカウント (`claude-<名前>` の名前。既定 (素の claude) は空。`restart` が引き継ぐ)。
    pub account: String,
    /// space に付けた名前 (`<英字> <label>`)。herdr-app の無いマシンの `restart` が、herdr-app の作り直した space に付け直す
    /// (前の控えの行は空)。
    pub space_name: String,
}

/// 同期された skill を pack の列に書くときの頭。
pub const SYNCED_MARK: &str = "synced:";

impl Row {
    fn fields(&self) -> [&str; 19] {
        [
            &self.letter,
            &self.state,
            &self.terminal,
            &self.name,
            &self.machine,
            &self.repo,
            &self.checkout,
            &self.worktree,
            &self.branch,
            &self.base,
            &self.space,
            &self.tab,
            &self.created,
            &self.updated,
            &self.effort,
            &self.packs,
            &self.chrome,
            &self.account,
            &self.space_name,
        ]
    }

    fn from_fields(f: &[&str]) -> Self {
        let get = |i: usize| f.get(i).copied().unwrap_or_default().to_owned();
        Self {
            letter: get(0),
            state: get(1),
            terminal: get(2),
            name: get(3),
            machine: get(4),
            repo: get(5),
            checkout: get(6),
            worktree: get(7),
            branch: get(8),
            base: get(9),
            space: get(10),
            tab: get(11),
            created: get(12),
            updated: get(13),
            effort: get(14),
            packs: get(15),
            chrome: get(16),
            account: get(17),
            space_name: get(18),
        }
    }

    /// 子のマシン (None はハブと同じマシン)。
    pub fn machine(&self) -> Option<&str> {
        (!self.machine.is_empty()).then_some(self.machine.as_str())
    }

    pub fn cleaned(&self) -> bool {
        self.state == state::CLEANED
    }

    pub fn live(&self) -> bool {
        self.state == state::LIVE
    }

    /// 控えた pack と同期された skill を (pack, synced) に分ける。
    pub fn pack_lists(&self) -> (Vec<String>, Vec<String>) {
        let mut packs = Vec::new();
        let mut synced = Vec::new();
        for item in self.packs.split_whitespace() {
            match item.strip_prefix(SYNCED_MARK) {
                Some(n) => synced.push(n.to_owned()),
                None => packs.push(item.to_owned()),
            }
        }
        (packs, synced)
    }

    /// pack と同期された skill を pack の列に書く形にする。
    pub fn join_packs(packs: &[String], synced: &[String]) -> String {
        packs
            .iter()
            .cloned()
            .chain(synced.iter().map(|s| format!("{SYNCED_MARK}{s}")))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// 値に tab と改行を入れない (1 行 1 子を崩さない)。
fn clean(v: &str) -> String {
    v.chars()
        .map(|c| {
            if matches!(c, '\t' | '\n' | '\r') {
                ' '
            } else {
                c
            }
        })
        .collect()
}

/// 英字の並びの何番目か (A = 1、Z = 26、AA = 27)。英大文字でなければ None。
pub fn letter_index(letter: &str) -> Option<u64> {
    if letter.is_empty() || !letter.bytes().all(|b| b.is_ascii_uppercase()) {
        return None;
    }
    letter.bytes().try_fold(0u64, |n, b| {
        n.checked_mul(26)?.checked_add(u64::from(b - b'A' + 1))
    })
}

/// n 番目 (1 から) の英字。
pub fn letter_of(mut n: u64) -> String {
    let mut out = Vec::new();
    while n > 0 {
        let d = (n - 1) % 26;
        out.push(b'A' + u8::try_from(d).unwrap_or(0));
        n = (n - 1) / 26;
    }
    out.reverse();
    String::from_utf8(out).unwrap_or_default()
}

/// 振った英字 (片付けた子も) の次。
pub fn next_letter<'a>(taken: impl IntoIterator<Item = &'a str>) -> String {
    let max = taken
        .into_iter()
        .filter_map(letter_index)
        .max()
        .unwrap_or(0);
    letter_of(max + 1)
}

/// 控えのファイルの名前に使える形 (`TKT-n` の形はそのまま。ほかの字は `_`)。
pub fn sanitize_key(key: &str) -> String {
    key.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// 端末の住所で控えたときの控えの名前 (この端末にまだ `pjp.ticket` が無かったとき)。
pub fn terminal_key(terminal: &str) -> String {
    format!("t-{terminal}")
}

/// 親のチケットが決まる前に端末の住所 (`t-<端末>`) で控えた子を、チケットの控えへ移す (同じ会話で英字を使い回さない)。
/// 移したら、その文を返す。チケットの控えが既にあれば移さず、そう返す。
pub fn adopt(dir: &Path, from_key: &str, to_key: &str) -> Result<Option<String>> {
    let from = Ledger::open(dir, from_key)?;
    let to = Ledger::open(dir, to_key)?;
    if !from.path.is_file() || from.path == to.path {
        return Ok(None);
    }
    let _held = pjp_core::lock::lock_exclusive(&from.lock)?;
    if to.path.exists() {
        return Ok(Some(format!(
            "!! 子の控え {} と {} が両方ある。移さない (前の子は pjp child … --ticket {from_key} で扱う)",
            from.path.display(),
            to.path.display()
        )));
    }
    std::fs::rename(&from.path, &to.path)
        .map_err(|e| Error::io(format!("{} を移せません", from.path.display()), &e))?;
    Ok(Some(format!(
        "子の控えを {from_key} から {to_key} へ移した"
    )))
}

/// 親のチケット 1 つぶんの控え。
pub struct Ledger {
    path: PathBuf,
    lock: PathBuf,
}

impl Ledger {
    /// `dir` (`<state>/pjp/children`) の `<key>.tsv`。
    pub fn open(dir: &Path, key: &str) -> Result<Self> {
        let key = sanitize_key(key);
        if key.is_empty() || key.chars().all(|c| c == '.') {
            return Err(Error::config("控えの名前 (親のチケット) が空です"));
        }
        Ok(Self {
            path: dir.join(format!("{key}.tsv")),
            lock: dir.join(format!("{key}.lock")),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 全部の行 (書いた順)。ファイルが無ければ空。
    pub fn rows(&self) -> Result<Vec<Row>> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => {
                return Err(Error::io(
                    format!("{} を読めません", self.path.display()),
                    &e,
                ));
            }
        };
        Ok(text
            .lines()
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .map(|l| Row::from_fields(&l.split('\t').collect::<Vec<_>>()))
            .collect())
    }

    /// 英字 (大文字小文字を問わない) の行。
    pub fn find(&self, letter: &str) -> Result<Option<Row>> {
        let want = letter.trim().to_ascii_uppercase();
        Ok(self.rows()?.into_iter().find(|r| r.letter == want))
    }

    fn write(&self, rows: &[Row]) -> Result<()> {
        let mut text = format!("# {}\n", COLUMNS.join("\t"));
        for r in rows {
            let fields: Vec<String> = r.fields().iter().map(|f| clean(f)).collect();
            text.push_str(&fields.join("\t"));
            text.push('\n');
        }
        pjp_core::text::write_atomic(&self.path, &text)
    }

    /// ロックの中で次の英字を取り、`make(英字)` の行を足す。
    pub fn reserve(&self, make: impl FnOnce(&str) -> Row) -> Result<Row> {
        let _held = pjp_core::lock::lock_exclusive(&self.lock)?;
        let mut rows = self.rows()?;
        let letter = next_letter(rows.iter().map(|r| r.letter.as_str()));
        let mut row = make(&letter);
        row.letter = letter;
        rows.push(row.clone());
        self.write(&rows)?;
        Ok(row)
    }

    /// 次に振る英字 (取らない。`--dry-run` 用)。
    pub fn peek_next(&self) -> Result<String> {
        Ok(next_letter(self.rows()?.iter().map(|r| r.letter.as_str())))
    }

    /// ロックの中で英字の行を直す。
    pub fn update(&self, letter: &str, change: impl FnOnce(&mut Row)) -> Result<Row> {
        let _held = pjp_core::lock::lock_exclusive(&self.lock)?;
        let mut rows = self.rows()?;
        let want = letter.to_ascii_uppercase();
        let row = rows.iter_mut().find(|r| r.letter == want).ok_or_else(|| {
            Error::failure(format!(
                "控えに子 {want} がありません ({})",
                self.path.display()
            ))
        })?;
        change(row);
        let out = row.clone();
        self.write(&rows)?;
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn letters_go_past_z() {
        assert_eq!(letter_of(1), "A");
        assert_eq!(letter_of(26), "Z");
        assert_eq!(letter_of(27), "AA");
        assert_eq!(letter_of(52), "AZ");
        assert_eq!(letter_of(53), "BA");
        assert_eq!(letter_of(702), "ZZ");
        assert_eq!(letter_of(703), "AAA");
        for n in [1, 26, 27, 52, 53, 702, 703, 12345] {
            assert_eq!(letter_index(&letter_of(n)), Some(n));
        }
        assert_eq!(letter_index("a"), None);
        assert_eq!(letter_index(""), None);
    }

    #[test]
    fn next_letter_counts_cleaned_children() {
        assert_eq!(next_letter([]), "A");
        assert_eq!(next_letter(["A", "B"]), "C");
        // 片付けた子の英字も数え、穴を埋めない
        assert_eq!(next_letter(["C", "A"]), "D");
        assert_eq!(next_letter(["Z"]), "AA");
        assert_eq!(next_letter(["?", ""]), "A");
    }

    #[test]
    fn ledger_roundtrip_and_update() {
        let t = TempDir::new("ledger");
        let l = Ledger::open(t.path(), "ABC-681").unwrap();
        assert_eq!(l.path(), t.path().join("ABC-681.tsv"));
        assert!(l.rows().unwrap().is_empty());
        assert_eq!(l.peek_next().unwrap(), "A");
        let a = l
            .reserve(|letter| Row {
                state: state::NEW.into(),
                name: format!("x-{letter}"),
                worktree: "/home/u/a\tb".into(),
                ..Row::default()
            })
            .unwrap();
        assert_eq!((a.letter.as_str(), a.name.as_str()), ("A", "x-A"));
        let b = l.reserve(|_| Row::default()).unwrap();
        assert_eq!(b.letter, "B");
        l.update("a", |r| {
            r.state = state::LIVE.into();
            r.terminal = "wsl1/t13".into();
        })
        .unwrap();
        let rows = l.rows().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].terminal, "wsl1/t13");
        assert_eq!(rows[0].state, "live");
        // tab は空白にして 1 行を崩さない
        assert_eq!(rows[0].worktree, "/home/u/a b");
        assert_eq!(l.find("b").unwrap().unwrap().letter, "B");
        assert!(l.find("C").unwrap().is_none());
        assert!(l.update("Q", |_| {}).is_err());
        let text = std::fs::read_to_string(l.path()).unwrap();
        assert!(text.starts_with("# letter\tstate\tterminal"), "{text}");
    }

    #[test]
    fn adopt_moves_terminal_ledger_to_ticket() {
        let t = TempDir::new("adopt");
        let from = Ledger::open(t.path(), &terminal_key("t8")).unwrap();
        assert_eq!(adopt(t.path(), "t-t8", "ABC-1").unwrap(), None);
        from.reserve(|_| Row::default()).unwrap();
        let msg = adopt(t.path(), "t-t8", "ABC-1").unwrap().unwrap();
        assert!(msg.contains("移した"), "{msg}");
        let to = Ledger::open(t.path(), "ABC-1").unwrap();
        assert_eq!(to.peek_next().unwrap(), "B");
        assert!(!from.path().exists());
        // 両方あれば移さない
        from.reserve(|_| Row::default()).unwrap();
        let msg = adopt(t.path(), "t-t8", "ABC-1").unwrap().unwrap();
        assert!(msg.starts_with("!!"), "{msg}");
        assert!(from.path().exists());
    }

    #[test]
    fn packs_roundtrip() {
        let row = Row {
            packs: Row::join_packs(&["lang".into(), "notion".into()], &["pdf".into()]),
            ..Row::default()
        };
        assert_eq!(row.packs, "lang notion synced:pdf");
        assert_eq!(
            row.pack_lists(),
            (
                vec!["lang".to_owned(), "notion".to_owned()],
                vec!["pdf".to_owned()]
            )
        );
        assert_eq!(Row::default().pack_lists(), (vec![], vec![]));
        // 列の足りない古い行も読める
        let old = Row::from_fields(&["A", "live", "t1"]);
        assert_eq!((old.letter.as_str(), old.effort.as_str()), ("A", ""));
    }

    #[test]
    fn account_column_roundtrip() {
        let t = TempDir::new("ledger-account");
        let l = Ledger::open(t.path(), "ABC-807").unwrap();
        l.reserve(|_| Row {
            account: "work".into(),
            ..Row::default()
        })
        .unwrap();
        assert_eq!(l.find("A").unwrap().unwrap().account, "work");
        let text = std::fs::read_to_string(l.path()).unwrap();
        assert!(text.starts_with("# letter\t"), "{text}");
        assert!(
            text.lines().next().unwrap().contains("\tchrome\taccount"),
            "{text}"
        );
        // 列の無い前の控えの行は、空 (既定のアカウント) で読む
        let old = Row::from_fields(&COLUMNS[..17]);
        assert_eq!(old.account, "");
    }

    #[test]
    fn space_name_column_roundtrip() {
        let t = TempDir::new("ledger-space-name");
        let l = Ledger::open(t.path(), "ABC-851").unwrap();
        l.reserve(|_| Row {
            space: "wsl1/sp1".into(),
            space_name: "A claude-skills: x".into(),
            ..Row::default()
        })
        .unwrap();
        assert_eq!(
            l.find("A").unwrap().unwrap().space_name,
            "A claude-skills: x"
        );
        let text = std::fs::read_to_string(l.path()).unwrap();
        assert!(
            text.lines()
                .next()
                .unwrap()
                .ends_with("\taccount\tspace_name"),
            "{text}"
        );
        // 列の無い前の控えの行 (列を足す前の版が書いたもの) は、空で読む
        let old = Row::from_fields(&COLUMNS[..18]);
        assert_eq!(old.space_name, "");
    }

    #[test]
    fn keys_are_sanitized() {
        assert_eq!(sanitize_key("ABC-681"), "ABC-681");
        assert_eq!(sanitize_key("t-wsl1/t8"), "t-wsl1_t8");
        assert!(Ledger::open(Path::new("/x"), "").is_err());
        assert!(Ledger::open(Path::new("/x"), "..").is_err());
    }
}
