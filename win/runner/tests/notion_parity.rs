//! runner が書く claude-notion.json の中身を、Linux の home/modules/claude.nix (`builtins.toJSON { inherit profile routes override; } + "\n"`)
//! と突き合わせる。
//!
//! ## 確かめること
//!
//! - ホストの値の `[claude.notion]` から作った中身が、同じ値の Nix の `builtins.toJSON` と同じバイト列 (キーの順・空白なし・小数・真偽値・
//!   配列・入れ子・profile の null)
//!
//! nix-instantiate が PATH に無ければ飛ばす (Windows の CI など)。`DOTFILES_WIN_NIX_PARITY=1` なら飛ばさずに落ちる (CI の Linux の job)。

mod common;

use common::which;
use dotfiles_win::host::{Groups, parse};
use std::path::Path;
use std::process::Command;

fn nix_available() -> bool {
    let found = which("nix-instantiate").is_some();
    if !found && std::env::var("DOTFILES_WIN_NIX_PARITY").as_deref() == Ok("1") {
        panic!("DOTFILES_WIN_NIX_PARITY=1 なのに nix-instantiate が PATH にありません");
    }
    found
}

/// Nix の式 `attrs` (profile・routes・override を持つ attrset) を `builtins.toJSON … + "\n"` にした文字列。
fn nix_json(attrs: &str) -> String {
    let expr = format!("builtins.toJSON ({attrs}) + \"\\n\"");
    let out = Command::new("nix-instantiate")
        .args(["--eval", "--strict", "--json", "-E"])
        .arg(&expr)
        .output()
        .expect("nix-instantiate を起こせない");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice::<String>(&out.stdout)
        .expect("nix-instantiate の出力が JSON の文字列でない")
}

fn runner_json(toml_text: &str) -> String {
    parse(toml_text, Path::new("h.toml"), Groups::embedded().unwrap())
        .unwrap()
        .notion
        .json()
}

#[test]
fn notion_json_matches_nix() {
    if !nix_available() {
        return;
    }
    let cases = [
        ("", "{ profile = null; routes = { }; override = { }; }"),
        (
            "[claude.notion]\nprofile = \"personal\"\n",
            "{ profile = \"personal\"; routes = { }; override = { }; }",
        ),
        (
            "[claude.notion]\nprofile = \"work\"\nroutes = { \"pollenjp/x\" = \"work\", \"a/*\" = \"personal\" }\n\n[claude.notion.override.personal]\nscanData = \"https://app.notion.com/p/x\"\ndevTracker = { linkFromRepo = false, prefix = \"TKT\" }\nn = [1, 2.5, true, \"日本語\"]\n",
            "{ profile = \"work\"; routes = { \"pollenjp/x\" = \"work\"; \"a/*\" = \"personal\"; }; override = { personal = { scanData = \"https://app.notion.com/p/x\"; devTracker = { linkFromRepo = false; prefix = \"TKT\"; }; n = [ 1 2.5 true \"日本語\" ]; }; }; }",
        ),
    ];
    for (toml_text, nix_attrs) in cases {
        assert_eq!(runner_json(toml_text), nix_json(nix_attrs), "{toml_text}");
    }
}
