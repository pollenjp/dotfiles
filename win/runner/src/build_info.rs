//! runner の exe を作ったときの情報 (dotfiles-private の docs/adr/117_win_runner_exe_release_*)。
//!
//! CI (`.github/workflows/win-runner-release.yml`) は、Release に置く exe を作るときに環境変数で 2 つを渡し、`option_env!` で埋める:
//!
//! | 環境変数 | 中身 |
//! | --- | --- |
//! | `DOTFILES_WIN_RUNNER_KEY` | key。作った commit の `win/runner` の git の tree の hash (`git rev-parse HEAD:win/runner`。40 字の 16 進) |
//! | `DOTFILES_WIN_RUNNER_COMMIT` | 作った commit (40 字の 16 進) |
//!
//! 手元の `cargo run` (dotfiles 関数の cargo の道・runner を直す人) には無く、そのときは手元の build として扱う。key を埋めた exe は、
//! 既定の clone を bootstrap が clone する所にし (`cli::default_repo`)、clone の HEAD の `win/runner` が key と違えば流さない
//! (`cli::check_runner_key`)。launcher (`win/powershell/Invoke-DotfilesRunner.ps1`) は `version` の行の key を読んで、落とした exe を確かめる。

/// 埋めた key (CI の exe だけ。空の値は埋めていないのと同じ。`key()`)
const KEY: Option<&str> = option_env!("DOTFILES_WIN_RUNNER_KEY");

/// 埋めた commit (CI の exe だけ。`commit()`)
const COMMIT: Option<&str> = option_env!("DOTFILES_WIN_RUNNER_COMMIT");

/// 埋めた key。無い・空なら None (手元の build)
pub fn key() -> Option<&'static str> {
    non_empty(KEY)
}

/// 埋めた commit。無い・空なら None
pub fn commit() -> Option<&'static str> {
    non_empty(COMMIT)
}

fn non_empty(v: Option<&'static str>) -> Option<&'static str> {
    v.filter(|s| !s.is_empty())
}

/// `version` が出す行。1 行目は版、続く 3 行は `名前=値` (launcher が読む。無い値は空)。key があれば Release の exe (`build=release`)、
/// 無ければ手元の build (`build=local`)
pub fn lines(key: Option<&str>, commit: Option<&str>) -> Vec<String> {
    let build = if key.is_some() { "release" } else { "local" };
    vec![
        format!("dotfiles-win {}", env!("CARGO_PKG_VERSION")),
        format!("key={}", key.unwrap_or_default()),
        format!("commit={}", commit.unwrap_or_default()),
        format!("build={build}"),
    ]
}

/// 40 字の小文字の 16 進か (git の SHA-1 の object の名前の形。key と commit)
pub fn is_object_name(s: &str) -> bool {
    s.len() == 40
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - key と commit があれば `build=release`、無ければ空の値と `build=local`。1 行目は版
    //! - object の名前は 40 字の小文字の 16 進だけ

    use super::*;

    const K: &str = "261aff1f714694bfe0c0199428617dfc448336a4";
    const C: &str = "ce27ad2d6c0a3d3f3f6c3e1a0e8f9f6a1b2c3d4e";

    #[test]
    fn release_lines() {
        let l = lines(Some(K), Some(C));
        assert_eq!(l.len(), 4);
        assert_eq!(l[0], format!("dotfiles-win {}", env!("CARGO_PKG_VERSION")));
        assert_eq!(l[1], format!("key={K}"));
        assert_eq!(l[2], format!("commit={C}"));
        assert_eq!(l[3], "build=release");
    }

    #[test]
    fn local_lines() {
        assert_eq!(
            lines(None, None)[1..],
            ["key=", "commit=", "build=local"].map(String::from)
        );
    }

    #[test]
    fn empty_values_are_absent() {
        assert_eq!(non_empty(Some("")), None);
        assert_eq!(non_empty(None), None);
        assert_eq!(non_empty(Some(K)), Some(K));
    }

    #[test]
    fn object_names() {
        assert!(is_object_name(K));
        assert!(!is_object_name(&K.to_uppercase()));
        assert!(!is_object_name(&K[..39]));
        assert!(!is_object_name(&format!("{}g", &K[..39])));
        assert!(!is_object_name(""));
    }
}
