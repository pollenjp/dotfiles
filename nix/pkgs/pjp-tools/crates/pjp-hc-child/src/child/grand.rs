//! 孫 (子の端末を親に持つ端末。指揮役から見た孫) を探す。`pjp child cleanup` は孫がいれば片付けない。`restart` は前の端末を
//! 終える前に孫を知らせ、前の端末と一緒に終わる孫 (`--outlive-parent` なしで立てた端末) がいれば止まる (`--force` で進む)。
//!
//! 孫は子のマシンの `hc ls --json` の parent で探す。hc 0.1.21 の ls は label も `die_with_parent` も出さないので、restart は
//! 見つけた孫を `hc get` で読み直す。2026-11-19 に自分専用の core で確かめた: `--outlive-parent` なしで立てた子は
//! `die_with_parent` が true で、親を `hc kill` すると一緒に終わる。ありの子は残り、親を `hc rm` した後も parent は消えた住所の
//! まま (hc には親を付け替えるコマンドが無いので、herdr-app の Agents 欄の木で、立て直した子の下に出ない)。

use pjp_core::{Error, Result};
use serde_json::Value;

use crate::hc::{Hc, finished, label_of, split_addr};
use crate::ledger::Row;

/// 子の端末 (控えの `row.terminal`) を親に持つ生きた端末を、子のマシンの一覧 (`hc ls --json`) から探す。parent が子の端末の
/// マシンの中の住所 (`t13`) か、マシン付きの住所 (`<machine>/t13`) のものを拾い、子の端末自身は数えない。返す端末は一覧のまま
/// (住所は子のマシンの中の住所)。一覧を読めなければ Err。
pub(super) fn find(hc: &Hc<'_>, row: &Row) -> Result<Vec<Value>> {
    let m = row.machine();
    let (_, child_local) = split_addr(&row.terminal);
    let terms = if m.is_some() {
        let o = hc.exec(m, None, 60, &["hc", "ls", "--json"])?;
        if !o.ok() {
            return Err(Error::failure(o.why()));
        }
        serde_json::from_str::<Value>(o.stdout.trim())
            .map(|v| v["terminals"].as_array().cloned().unwrap_or_default())
            .map_err(|e| Error::failure(format!("hc ls の出力を読めません: {e}")))?
    } else {
        hc.ls(false)?
    };
    Ok(terms
        .into_iter()
        .filter(|t| t["address"].as_str() != Some(child_local))
        .filter(|t| {
            t["parent"]
                .as_str()
                .is_some_and(|p| p == child_local || p == row.terminal)
        })
        .filter(|t| t["state"].as_str().is_none_or(|s| s == "live"))
        .collect())
}

/// 一覧の端末の住所と名前 (`t20 (grand)`)。
pub(super) fn label(t: &Value) -> String {
    let addr = t["address"].as_str().unwrap_or("?");
    match t["name"].as_str() {
        Some(n) => format!("{addr} ({n})"),
        None => addr.to_owned(),
    }
}

/// 孫が herdr-app のどこに出ているか。
#[derive(Debug, Clone, PartialEq, Eq)]
enum Place {
    /// label の where (herdr-app が付ける「<space の名前> / <tab の名前>」)。
    Where(String),
    /// label の `herdr.space`・`herdr.tab` の id (where が無いとき)。
    Ids { space: String, tab: Option<String> },
    /// space・tab の label が無い。
    NoLabel,
    /// `hc get` で読めなかった。
    Unread,
}

fn place_of(t: &Value) -> Place {
    if let Some(w) = label_of(t, "where") {
        return Place::Where(w.to_owned());
    }
    match label_of(t, "herdr.space") {
        Some(sp) => Place::Ids {
            space: sp.to_owned(),
            tab: label_of(t, "herdr.tab").map(str::to_owned),
        },
        None => Place::NoLabel,
    }
}

/// 孫を `hc get` で読み直したもの。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Grand {
    /// ハブから見た住所 (`<machine>/t20`)。
    addr: String,
    name: Option<String>,
    /// 親と一緒に終わるか (`die_with_parent`)。読めなければ None。
    dies: Option<bool>,
    place: Place,
}

impl Grand {
    /// 1 行の説明 (`<machine>/t20 (kabu-live)  space・tab: A kabu-bot: 運用 / 1`)。
    fn line(&self) -> String {
        let name = self
            .name
            .as_deref()
            .map_or_else(String::new, |n| format!(" ({n})"));
        let place = match &self.place {
            Place::Where(w) => format!("space・tab: {w}"),
            Place::Ids {
                space,
                tab: Some(tab),
            } => format!("space {space}・tab {tab}"),
            Place::Ids { space, tab: None } => format!("space {space}"),
            Place::NoLabel => "space・tab の label なし".to_owned(),
            Place::Unread => "space・tab は分からない (hc get で読めない)".to_owned(),
        };
        format!("{}{name}  {place}", self.addr)
    }
}

/// 一覧の孫 ([`find`] の答え) を `hc get` で読み直す (一覧には label と `die_with_parent` が無い)。もう無い・終わっていた孫は
/// 除く。`m` は子のマシン。
pub(super) fn inspect(hc: &Hc<'_>, m: Option<&str>, terms: &[Value]) -> Vec<Grand> {
    terms
        .iter()
        .filter_map(|t| {
            let local = t["address"].as_str().unwrap_or("?");
            let name = t["name"].as_str().map(str::to_owned);
            let unread = |addr: String| Grand {
                addr,
                name: name.clone(),
                dies: None,
                place: Place::Unread,
            };
            let addr = match m {
                Some(m) if !local.contains('/') => format!("{m}/{local}"),
                // 子のマシンがつないだ別のマシンの端末 (子のマシンの一覧の <別のマシン>/t5) は、ハブから同じ住所で引けるとは限らないので読まない
                Some(_) => return Some(unread(local.to_owned())),
                None => local.to_owned(),
            };
            match hc.get(&addr) {
                Ok(Some(full)) if finished(&full) => None,
                Ok(Some(full)) => Some(Grand {
                    dies: full["die_with_parent"].as_bool(),
                    place: place_of(&full),
                    addr,
                    name: name.clone(),
                }),
                Ok(None) => None,
                Err(_) => Some(unread(addr)),
            }
        })
        .collect()
}

/// 前の端末の今の様子。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum OldTerm {
    /// 生きている (終えると、`die_with_parent` の孫も一緒に終わる)。
    Live,
    /// 終わっているが、まだ消していない。
    Ended,
    /// もう無い。
    Gone,
}

/// 孫を、前の端末と一緒に終わるもの (前の端末が生きていて `die_with_parent` が true) と、残るものに分ける。
pub(super) fn split(grands: Vec<Grand>, old: OldTerm) -> (Vec<Grand>, Vec<Grand>) {
    grands
        .into_iter()
        .partition(|g| old == OldTerm::Live && g.dies == Some(true))
}

/// 一覧の行の頭 (`!!` の見出しの下)。
const ITEM: &str = "     ";
/// 説明の行の頭 (`!!` の後ろにそろえる)。
const TEXT: &str = "   ";

fn push_items(s: &mut String, grands: &[Grand], caveat: impl Fn(&Grand) -> bool) {
    for g in grands {
        s.push_str(ITEM);
        s.push_str(&g.line());
        if caveat(g) {
            s.push_str("  (--outlive-parent で立てていなければ、前の端末と一緒に終わる)");
        }
        s.push('\n');
    }
}

/// 一緒に終わる孫がいて止まるときの文 (失敗の文。`pjp child: ` の後ろに出る)。`working` は子がまだ working か。
pub(super) fn refusal(letter: &str, old: &str, dying: &[Grand], working: bool) -> String {
    let mut s = format!(
        "子 {letter} の前の端末 {old} を終えると、その端末が立てた次の端末も一緒に終わる (--outlive-parent で立てていない):\n"
    );
    push_items(&mut s, dying, |_| false);
    if working {
        s.push_str(&format!("{TEXT}子 {letter} はまだ working でもある\n"));
    }
    s.push_str(&format!(
        "{TEXT}止めて立て直すなら --force を付ける (一緒に終わる端末も終わる)。終わらせたくなければ、子がその端末を使い終えるのを待ってから立て直す"
    ));
    s
}

/// `--force` で進むときに、一緒に終わる孫を並べる文 (`!!` で始まる数行。末尾に改行)。
pub(super) fn ending(old: &str, dying: &[Grand]) -> String {
    let mut s = format!(
        "!! --force なので、前の端末 {old} と一緒に次の端末も終わる (--outlive-parent で立てていない):\n"
    );
    push_items(&mut s, dying, |_| false);
    s
}

/// 前の端末を終えても残る孫の知らせ (`!!` で始まる数行。末尾に改行)。
pub(super) fn notice(old: &str, state: OldTerm, staying: &[Grand]) -> String {
    let gone = state == OldTerm::Gone;
    let mut s = format!(
        "!! 前の端末 {old}{} が立てた端末が {} つ生きている:\n",
        if gone { " (もう無い)" } else { "" },
        staying.len()
    );
    // 一緒に終わるかを読めなかった孫には、前の端末を終えると終わりうることを添える
    push_items(&mut s, staying, |g| {
        state == OldTerm::Live && g.dies.is_none()
    });
    if gone {
        s.push_str(&format!(
            "{TEXT}これらの親は消えた端末 {old} のままで、herdr-app の Agents 欄の木で新しい子の下に出ない (hc には親を付け替える手が無い)\n"
        ));
    } else {
        s.push_str(&format!(
            "{TEXT}前の端末を消すと、残った端末の親は消えた端末 {old} のままになり、herdr-app の Agents 欄の木で新しい子の下に出ない (hc には親を付け替える手が無い)\n"
        ));
    }
    s.push_str(&format!(
        "{TEXT}新しい子に使わせるなら、新しい子の端末から hc run --outlive-parent で立て直させる (木で新しい子の下に出る)。要らなければ閉じる (hc kill → hc rm。片付けるのは立てた側なので、新しい子への依頼に書く)\n"
    ));
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grand(dies: Option<bool>) -> Grand {
        Grand {
            addr: "wsl1/t20".to_owned(),
            name: Some("tests".to_owned()),
            dies,
            place: Place::NoLabel,
        }
    }

    #[test]
    fn only_live_old_terminal_takes_grandchildren_with_it() {
        // 生きている前の端末を終えると、die_with_parent が true の孫だけが一緒に終わる
        let (dying, staying) = split(
            vec![grand(Some(true)), grand(Some(false)), grand(None)],
            OldTerm::Live,
        );
        assert_eq!(dying, vec![grand(Some(true))]);
        assert_eq!(staying, vec![grand(Some(false)), grand(None)]);
        // 終わっている・無い前の端末は、終えても孫を道連れにしない
        for old in [OldTerm::Ended, OldTerm::Gone] {
            let (dying, staying) = split(vec![grand(Some(true))], old);
            assert!(dying.is_empty(), "{old:?}");
            assert_eq!(staying.len(), 1, "{old:?}");
        }
    }

    #[test]
    fn caveat_only_for_unknown_outlive_of_live_old_terminal() {
        let caveat = "--outlive-parent で立てていなければ";
        assert!(notice("wsl1/t13", OldTerm::Live, &[grand(None)]).contains(caveat));
        assert!(!notice("wsl1/t13", OldTerm::Live, &[grand(Some(false))]).contains(caveat));
        // 前の端末がもう無いなら、終えることも無い
        assert!(!notice("wsl1/t13", OldTerm::Gone, &[grand(None)]).contains(caveat));
    }
}
