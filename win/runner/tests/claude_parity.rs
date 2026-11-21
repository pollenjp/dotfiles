//! runner が Windows の Claude Code に書くものを、Linux の home/modules/claude.nix の値と突き合わせる。
//!
//! ## 確かめること
//!
//! - claude-notion.json の中身が、Linux の claude.nix が sandbox のホスト (nix/hosts/default.nix) に書くものと同じバイト列。さらに、いろいろな値
//!   (routes・override の入れ子・小数・真偽値・配列・profile の null) で、同じ値の Nix の `builtins.toJSON` (claude.nix の
//!   `builtins.toJSON { inherit profile routes override; } + "\n"`) と同じバイト列
//! - settings.json の env に足す git の組 (並びも) と、plugin を https で取る印が、Linux の claude.nix が sandbox のホストに書く claude-env.json の
//!   gitConfig と vars と同じ
//!
//! - 既定のアカウントの名前 (steps::claude_accounts::DEFAULT_ACCOUNTS) が、Linux の claude.nix が sandbox のホストに書く claude-accounts.json と
//!   同じ並び (claude-account の既定の personal・work)
//! - claude-selector (nix/pkgs/claude-selector) が Windows で並べる既定のアカウント (WINDOWS_DEFAULT_ACCOUNTS) とアカウントに使えない名前
//!   (RESERVED) が、runner の DEFAULT_ACCOUNTS・accounts::RESERVED と同じ並び (selector は別の crate なので、源の const の行を読む。nix は要らない)
//! - 略語 cs の中身が、fish の abbr (nix/home/modules/fish.nix)・bash の alias (bash.nix)・PowerShell の function (win/powershell/dotfiles.ps1)
//!   で同じ (claude-selector)。PowerShell の略語の表と function は win/powershell/dotfiles.Tests.ps1 が突き合わせる
//!
//! nix-instantiate か nix が PATH に無ければ飛ばす (Windows の CI など)。`DOTFILES_WIN_NIX_PARITY=1` なら飛ばさずに落ちる (CI の Linux の job)。

mod common;

use common::which;
use dotfiles_win::host::{Groups, parse};
use dotfiles_win::steps::claude_env::{GIT_CONFIG, VARS};
use std::path::Path;
use std::process::Command;

/// Linux の claude.nix が sandbox のホスト (nix/hosts/default.nix) に書く `~/.local/state/dotfiles/<name>` の中身 (flake を `path:` で評価する。
/// 素のパスだと repo 全体を /nix/store へ写す)
fn sandbox_file(name: &str) -> String {
    let flake = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("nix")
        .canonicalize()
        .unwrap();
    let attr = format!(
        "path:{}#homeConfigurations.sandbox.config.home.file.\".local/state/dotfiles/{name}\".text",
        flake.display()
    );
    let out = Command::new("nix")
        .args(["eval", "--raw"])
        .arg(&attr)
        .output()
        .expect("nix を起こせない");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

/// settings.json の env に足す git の組と名前が、Linux の claude.nix の claude-env.json (gitConfigBase と git-via-gh の組・vars) と同じ
#[test]
fn git_config_matches_claude_nix() {
    if !nix_available() {
        return;
    }
    let env: serde_json::Value = serde_json::from_str(&sandbox_file("claude-env.json")).unwrap();
    let linux: Vec<(String, String)> = env["gitConfig"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            (
                p["k"].as_str().unwrap().to_string(),
                p["v"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    let ours: Vec<(String, String)> = GIT_CONFIG
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    assert_eq!(ours, linux);
    // plugin を https で取る印は Linux と同じ値 (CLAUDE_CODE_SHELL は Windows に無い。GCM_INTERACTIVE は Windows だけ)
    let prefer = VARS
        .iter()
        .find(|(k, _)| *k == "CLAUDE_CODE_PLUGIN_PREFER_HTTPS")
        .map(|(_, v)| *v);
    assert_eq!(
        prefer,
        env["vars"]["CLAUDE_CODE_PLUGIN_PREFER_HTTPS"].as_str()
    );
}

/// claude-notion.json の中身が、Linux の claude.nix が sandbox のホストに書くものと同じ (同じ profile のとき)
#[test]
fn notion_json_matches_claude_nix() {
    if !nix_available() {
        return;
    }
    let linux = sandbox_file("claude-notion.json");
    let v: serde_json::Value = serde_json::from_str(&linux).unwrap();
    let toml_text = match v["profile"].as_str() {
        Some(p) => format!("[claude.notion]\nprofile = \"{p}\"\n"),
        None => String::new(),
    };
    assert_eq!(runner_json(&toml_text), linux);
}

/// 既定のアカウントの名前が、Linux の claude.nix の accounts (claude-accounts.json) と同じ並び
#[test]
fn default_accounts_match_claude_nix() {
    if !nix_available() {
        return;
    }
    let linux: Vec<String> = serde_json::from_str(&sandbox_file("claude-accounts.json")).unwrap();
    assert_eq!(
        linux,
        dotfiles_win::steps::claude_accounts::DEFAULT_ACCOUNTS.to_vec()
    );
}

/// claude-selector が Windows で並べる既定のアカウントと、アカウントに使えない名前が、runner のものと同じ並び
#[test]
fn claude_selector_accounts_match_runner() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("nix")
        .join("pkgs")
        .join("claude-selector")
        .join("src")
        .join("accounts.rs");
    let src = std::fs::read_to_string(&path).unwrap();
    // `pub const <name>: [&str; N] = ["…", "…"];` の "…" を並びのまま拾う (Windows の checkout の CRLF は lines が外す)
    let names = |name: &str| -> Vec<String> {
        let head = format!("pub const {name}: ");
        let line = src
            .lines()
            .find(|l| l.starts_with(&head))
            .unwrap_or_else(|| panic!("{} に {name} が無い", path.display()));
        let (_, value) = line.split_once('=').unwrap();
        value
            .split('"')
            .skip(1)
            .step_by(2)
            .map(str::to_string)
            .collect()
    };
    assert_eq!(
        names("WINDOWS_DEFAULT_ACCOUNTS"),
        dotfiles_win::steps::claude_accounts::DEFAULT_ACCOUNTS.to_vec()
    );
    assert_eq!(names("RESERVED"), dotfiles_win::accounts::RESERVED.to_vec());
}

/// 略語 cs の中身が fish・bash・PowerShell で同じ (claude-selector)
#[test]
fn cs_is_the_same_everywhere() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
    let read = |rel: &[&str]| {
        let path = rel.iter().fold(repo.clone(), |p, s| p.join(s));
        std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("{} が読めない ({e})", path.display()))
    };
    for file in ["fish.nix", "bash.nix"] {
        let text = read(&["nix", "home", "modules", file]);
        let cs: Vec<&str> = text
            .lines()
            .filter_map(|l| l.trim().strip_prefix("cs = \"")?.strip_suffix("\";"))
            .collect();
        assert_eq!(cs, ["claude-selector"], "{file} の cs");
    }
    let ps = read(&["win", "powershell", "dotfiles.ps1"]);
    let cs: Vec<&str> = ps
        .lines()
        .filter_map(|l| l.strip_prefix("function cs { ")?.strip_suffix(" @args }"))
        .collect();
    assert_eq!(cs, ["claude-selector"], "dotfiles.ps1 の function cs");
}

fn nix_available() -> bool {
    let found = which("nix-instantiate").is_some() && which("nix").is_some();
    if !found && std::env::var("DOTFILES_WIN_NIX_PARITY").as_deref() == Ok("1") {
        panic!("DOTFILES_WIN_NIX_PARITY=1 なのに nix-instantiate か nix が PATH にありません");
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
