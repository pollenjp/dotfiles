//! claude-tokens (order 99): ホストの値の claude の setup-token の token の置き場の宣言 (`[claude.tokens.<名前>]` の `label`・`item`) を
//! `%USERPROFILE%\.local\state\dotfiles\claude-tokens.json` に書く。Windows にしか無い手順 (dotfiles-private の docs/adr/123_claude_token_watch_*)。
//!
//! Linux の home/modules/claude.nix が `dotfiles.claude.tokens` から書く中身と同じ (nix/lib/claude-tokens.nix の stateText。
//! `host::claude_tokens_json`)。dotfiles が持つ生成物なので、違えば書き直す (claude-notion.json・notion-tokens.json と同じ `generated::sync`)。
//! 読むのは `claude-account audit` (Linux と同じく、ホームからの固定の場所で読む)。宣言が無くても `{"accounts":{}}` を書く (ファイルが無いのは、
//! dotfiles が古い印)。
//!
//! 値 (token) は持たない。token のファイル (`%USERPROFILE%\.config\claude-accounts\<名前>.env`) と入れた時刻の控えは見ない (見るのは
//! `claude-account audit`)。`claude-account add` が流すのは手順 claude-accounts の本体だけなので、空の宣言で上書きしない。

use super::{Gate, Mode, Outcome, Step, StepInfo, generated};
use crate::context::{Ctx, join_segments};
use crate::host::claude_tokens_json;

/// 置き先 (ホームからの相対。claude-account audit は `XDG_STATE_HOME` を見ずに、ホームからの固定の場所で読む)
pub const REL: &str = ".local/state/dotfiles/claude-tokens.json";

pub struct ClaudeTokens;

impl Step for ClaudeTokens {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-tokens",
            // 読むのは claude-account.exe (手順 claude-accounts (99) が置く)。同じ数の中では名前の順で claude-accounts の後
            order: 99,
            title: "claude の token の置き場の宣言 ([claude.tokens]) を claude-tokens.json に書く (claude-account audit が読む)",
            // claude-account.exe を置くホスト (手順 claude-accounts と同じ道具)。Linux の home/modules/claude.nix が claude-tokens.json を置くのは
            // claude.enable のホスト
            gate: Gate::AllTools(&["windowsClaudeAccounts", "windowsClaudeCode"]),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let path = join_segments(&ctx.roots.user_profile, REL);
        let desired = claude_tokens_json(&ctx.host.claude_tokens);
        vec![generated::sync(
            ctx,
            mode,
            &path,
            desired.as_bytes(),
            "claude-tokens.json",
        )]
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - ホストの値の [claude.tokens] から %USERPROFILE%\.local\state\dotfiles\claude-tokens.json を書く (check と dry-run は書かない。apply で作る。
    //!   同じなら揃っている。違えば書き直す)。宣言が無くても {"accounts":{}} を書く
    //! - 手順の gate は claude-accounts と同じ道具 (windowsClaudeAccounts と windowsClaudeCode)

    use super::*;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::report::Kind;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    fn run_with(t: &TempDir, host_text: &str, mode: Mode) -> Vec<Outcome> {
        let roots = Roots::from_home(&t.path().join("home"));
        let host = parse(host_text, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap();
        let sys = FakeSys::new(|c| panic!("外のコマンドは打たない: {:?}", c.args_lossy()));
        let mut out = Vec::new();
        let mut ctx = Ctx {
            repo: t.path().join("repo"),
            state_dir: t.path().join("state"),
            roots,
            host,
            sys: &sys,
            out: &mut out,
        };
        ClaudeTokens.run(&mut ctx, mode)
    }

    #[test]
    fn writes_the_declarations() {
        let t = TempDir::new("claude-tokens");
        let path = t
            .path()
            .join("home")
            .join(".local")
            .join("state")
            .join("dotfiles")
            .join("claude-tokens.json");
        let decl = "[claude.tokens.alt]\nitem = \"op://v/i/f\"\n";
        let rows = run_with(&t, decl, Mode::Check);
        assert_eq!(rows[0].kind, Kind::Missing, "{rows:?}");
        let rows = run_with(&t, decl, Mode::DryRun { force: false });
        assert_eq!(rows[0].kind, Kind::Missing, "{rows:?}");
        assert!(!path.exists());
        let rows = run_with(&t, decl, Mode::Apply { force: false });
        assert_eq!(rows[0].kind, Kind::Ok, "{rows:?}");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "{\"accounts\":{\"alt\":{\"item\":\"op://v/i/f\",\"label\":\"alt\"}}}\n"
        );
        let rows = run_with(&t, decl, Mode::Check);
        assert_eq!(rows[0].kind, Kind::Ok, "{rows:?}");
        // 宣言を外すと {"accounts":{}} に書き直す
        let rows = run_with(&t, "", Mode::Check);
        assert_eq!(rows[0].kind, Kind::Fix, "{rows:?}");
        let rows = run_with(&t, "", Mode::Apply { force: false });
        assert_eq!(rows[0].kind, Kind::Ok, "{rows:?}");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "{\"accounts\":{}}\n"
        );
    }

    #[test]
    fn gate_is_like_claude_accounts() {
        let ours = ClaudeTokens.info();
        let accounts = crate::steps::claude_accounts::ClaudeAccounts.info();
        assert_eq!(ours.gate, accounts.gate);
        assert_eq!(ours.order, accounts.order);
        assert!(ours.windows_only);
    }
}
