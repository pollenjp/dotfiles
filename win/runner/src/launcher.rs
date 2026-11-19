//! `claude-<名前>.exe` の launcher (claude-accounts の手順が `%LOCALAPPDATA%\dotfiles\bin\` に置く、この runner の exe の写し)。
//!
//! Linux の `nix/home/modules/claude.nix` の `claude-<名前>` に当たる (dotfiles-private の docs/adr/081_win_claude_accounts_*)。

/// アカウントの名前の形 (`[a-z0-9][a-z0-9_-]*`。Linux の claude.nix と bootstrap-claude-accounts.sh と同じ)。dir の名前 (`~/.claude-<名前>`)
/// とコマンドの名前に使うので、パスを壊す字を入れない。
pub fn account_name_ok(name: &str) -> bool {
    let mut chars = name.chars();
    let lead_ok = chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    lead_ok && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - アカウントの名前の形 (英小文字・数字で始まり、英小文字・数字・- と _ だけ)

    use super::*;

    #[test]
    fn account_names() {
        for ok in ["personal", "work", "a-b_c", "0x"] {
            assert!(account_name_ok(ok), "{ok}");
        }
        for ng in ["", "Work", "-a", "_a", "a.b", "a b", "a/b", "a\\b", "ａ"] {
            assert!(!account_name_ok(ng), "{ng}");
        }
    }
}
