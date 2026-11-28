//! runner が Windows の Claude Code に書くものを、Linux の home/modules/claude.nix の値と突き合わせる。
//!
//! ## 確かめること
//!
//! - claude-notion.json の中身が、Linux の claude.nix が sandbox のホスト (nix/hosts/default.nix) に書くものと同じバイト列。さらに、いろいろな値
//!   (routes・override の入れ子・小数・真偽値・配列・profile の null) で、同じ値の Nix の `builtins.toJSON` (claude.nix の
//!   `builtins.toJSON { inherit profile routes override; } + "\n"`) と同じバイト列
//! - settings.json の env に足す git の組 (並びも) と、plugin を https で取る印が、Linux の claude.nix が sandbox のホストに書く claude-env.json の
//!   gitConfig と vars と同じ
//! - notion-tokens.json の中身 (ホストの値の [claude.notion.tokens]) が、同じ宣言の Linux の nix/lib/notion-tokens.nix の stateText と同じバイト列
//!   (宣言なし・item の null・セクションのある参照・空白と ASCII でない字の参照・- のある名前)。宣言を止めるか通すかが、同じ宣言の
//!   notion-tokens.nix の assertions と同じ (名前の形・item の形・同じ変数になる 2 つの名前。kind は Nix の型 (enum) が見るので、ここでは
//!   比べず単体の試験で見る)
//! - claude-tokens.json の中身 (ホストの値の [claude.tokens]) が、同じ宣言の Linux の nix/lib/claude-tokens.nix の stateText と同じバイト列
//!   (宣言なし・label を省く (アカウントの名前)・. _ - のある呼び名・item の null・セクションのある参照)。宣言を止めるか通すかが、同じ宣言の
//!   claude-tokens.nix の assertions と同じ (名前の形・32 字・sk-ant-・account・selector・label の形・64 字・item の形と、tokens や名前ごとの値が
//!   表でない・知らないキー・label が文字列でない。Nix の option の型は anything で、形は assertions だけが見る)。違うのは素の claude の
//!   default だけ (Nix は通し、Windows は止める。Windows の素の claude は token を読まない)
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
use dotfiles_win::host::{Groups, claude_tokens_json, parse};
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

/// Linux の nix/lib/notion-tokens.nix (`nt`。lib は flake の nixpkgs のもの) を使う Nix の式 `expr` を評価した JSON。flake は `path:` で読む
/// (素のパスだと repo 全体を /nix/store へ写す)
fn notion_tokens_nix(expr: &str) -> serde_json::Value {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("nix")
        .canonicalize()
        .unwrap();
    let dir = dir.to_str().unwrap();
    let full = format!(
        "let flake = builtins.getFlake \"path:{dir}\"; lib = flake.inputs.nixpkgs.lib; nt = import (/. + \"{dir}/lib/notion-tokens.nix\") {{ inherit lib; }}; in {expr}"
    );
    let out = Command::new("nix")
        .args(["eval", "--impure", "--json", "--expr"])
        .arg(&full)
        .output()
        .expect("nix を起こせない");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("nix eval の出力が JSON でない")
}

/// Nix の文字列の literal (`"…"`。\ と " と $ と改行・タブ・CR を逃がす)
fn nix_str(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '$' => out.push_str("\\$"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// TOML の basic string の literal (`"…"`。\ と " と改行・タブ・CR を逃がす)
fn toml_str(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// 宣言 (名前・種類・item) を、ホストの値の TOML と Nix の attrset にする
fn token_decls(decls: &[(&str, &str, Option<&str>)]) -> (String, String) {
    let mut toml_text = String::new();
    let mut nix = String::from("{ ");
    for (name, kind, item) in decls {
        toml_text.push_str(&format!(
            "[claude.notion.tokens.{}]\nkind = \"{kind}\"\n",
            toml_str(name)
        ));
        if let Some(i) = item {
            toml_text.push_str(&format!("item = {}\n", toml_str(i)));
        }
        nix.push_str(&format!(
            "{} = {{ kind = \"{kind}\"; item = {}; }}; ",
            nix_str(name),
            item.map_or("null".to_string(), nix_str)
        ));
    }
    nix.push('}');
    (toml_text, nix)
}

/// notion-tokens.json の中身が、同じ宣言の Linux の notion-tokens.nix の stateText と同じバイト列
#[test]
fn notion_tokens_json_matches_nix() {
    if !nix_available() {
        return;
    }
    let cases: Vec<Vec<(&str, &str, Option<&str>)>> = vec![
        vec![],
        vec![("personal", "personal", None)],
        vec![
            ("personal", "personal", Some("op://vvvv/iiii/ffff")),
            ("my-ws", "integration", None),
            (
                "sec_1",
                "integration",
                Some("op://Private Vault/My Item/s1/credential"),
            ),
            ("0w", "personal", Some("op://金庫/項目/欄 ")),
        ],
    ];
    let mut ours = Vec::new();
    let mut nix_list = String::from("map nt.stateText [ ");
    for decls in &cases {
        let (toml_text, nix) = token_decls(decls);
        ours.push(
            parse(&toml_text, Path::new("h.toml"), Groups::embedded().unwrap())
                .unwrap()
                .notion
                .tokens_json(),
        );
        nix_list.push_str(&format!("({nix}) "));
    }
    nix_list.push(']');
    let linux: Vec<String> = serde_json::from_value(notion_tokens_nix(&nix_list)).unwrap();
    assert_eq!(ours, linux);
    assert_eq!(linux[0], "{\"tokens\":{}}\n");
}

/// 宣言を止めるか通すかが、同じ宣言の Linux の notion-tokens.nix の assertions (どれも true なら通す) と同じ
#[test]
fn notion_tokens_rejects_like_nix() {
    if !nix_available() {
        return;
    }
    let p = |name: &'static str| vec![(name, "personal", None)];
    let item = |i: &'static str| vec![("personal", "personal", Some(i))];
    let cases: Vec<Vec<(&str, &str, Option<&str>)>> = vec![
        p("personal"),
        p("0a"),
        p("a-b_c"),
        p("Personal"),
        p("-x"),
        p("_x"),
        p("a b"),
        p("a.b"),
        item("op://a/b/c"),
        item("op://a/b/s/c"),
        item("op://Private Vault/My Item/credential"),
        item("op://金庫/項目/欄"),
        item("op://a/b/c "),
        item("ntn_not_a_reference"),
        item("op://a/b"),
        item("op://a/b/c/d/e"),
        item(" op://a/b/c"),
        item("op://a/b/c\n"),
        item("op://a/b/c\tx"),
        item("op://a//c"),
        item("op://a/b/c/"),
        item(""),
        item("OP://a/b/c"),
        vec![("my-ws", "personal", None), ("my_ws", "integration", None)],
        vec![("a-b", "personal", None), ("a_c", "integration", None)],
    ];
    let mut ours = Vec::new();
    let mut nix_list = String::from("map (t: builtins.all (a: a.assertion) (nt.assertions t)) [ ");
    for decls in &cases {
        let (toml_text, nix) = token_decls(decls);
        ours.push(parse(&toml_text, Path::new("h.toml"), Groups::embedded().unwrap()).is_ok());
        nix_list.push_str(&format!("({nix}) "));
    }
    nix_list.push(']');
    let linux: Vec<bool> = serde_json::from_value(notion_tokens_nix(&nix_list)).unwrap();
    for (i, decls) in cases.iter().enumerate() {
        assert_eq!(ours[i], linux[i], "{decls:?}");
    }
    // 通すものと止めるものの両方がある (どちらかに寄った比べ方になっていない)
    assert!(linux.contains(&true) && linux.contains(&false));
}

/// Linux の nix/lib/claude-tokens.nix (`ct`) を使う Nix の式 `expr` を評価した JSON (notion_tokens_nix と同じ読み方)
fn claude_tokens_nix(expr: &str) -> serde_json::Value {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("nix")
        .canonicalize()
        .unwrap();
    let dir = dir.to_str().unwrap();
    let full = format!(
        "let flake = builtins.getFlake \"path:{dir}\"; lib = flake.inputs.nixpkgs.lib; ct = import (/. + \"{dir}/lib/claude-tokens.nix\") {{ inherit lib; }}; in {expr}"
    );
    let out = Command::new("nix")
        .args(["eval", "--impure", "--json", "--expr"])
        .arg(&full)
        .output()
        .expect("nix を起こせない");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("nix eval の出力が JSON でない")
}

/// claude の token の宣言 1 つ (名前・label・item)
type ClaudeTokenDecl<'a> = (&'a str, Option<&'a str>, Option<&'a str>);

/// claude の token の宣言を、ホストの値の TOML と Nix の attrset にする (どちらも、省いた label・item は書かない。Nix の側は stateText が
/// label をアカウントの名前、item を null で補う)
fn claude_token_decls(decls: &[ClaudeTokenDecl]) -> (String, String) {
    let mut toml_text = String::new();
    let mut nix = String::from("{ ");
    for (name, label, item) in decls {
        toml_text.push_str(&format!("[claude.tokens.{}]\n", toml_str(name)));
        if let Some(l) = label {
            toml_text.push_str(&format!("label = {}\n", toml_str(l)));
        }
        if let Some(i) = item {
            toml_text.push_str(&format!("item = {}\n", toml_str(i)));
        }
        let mut body = String::new();
        if let Some(l) = label {
            body.push_str(&format!("label = {}; ", nix_str(l)));
        }
        if let Some(i) = item {
            body.push_str(&format!("item = {}; ", nix_str(i)));
        }
        nix.push_str(&format!("{} = {{ {body}}}; ", nix_str(name)));
    }
    nix.push('}');
    (toml_text, nix)
}

/// claude-tokens.json の中身が、同じ宣言の Linux の claude-tokens.nix の stateText と同じバイト列
#[test]
fn claude_tokens_json_matches_nix() {
    if !nix_available() {
        return;
    }
    let cases: Vec<Vec<ClaudeTokenDecl>> = vec![
        vec![],
        vec![("alt", None, None)],
        vec![
            ("alt", Some("shared"), Some("op://vvvv/iiii/ffff")),
            ("b-2_c", None, None),
            (
                "0w",
                Some("m.v2_x-1"),
                Some("op://Private Vault/My Item/s1/credential"),
            ),
            ("z", Some("shared"), Some("op://金庫/項目/欄 ")),
        ],
    ];
    let mut ours = Vec::new();
    let mut nix_list = String::from("map ct.stateText [ ");
    for decls in &cases {
        let (toml_text, nix) = claude_token_decls(decls);
        ours.push(claude_tokens_json(
            &parse(&toml_text, Path::new("h.toml"), Groups::embedded().unwrap())
                .unwrap()
                .claude_tokens,
        ));
        nix_list.push_str(&format!("({nix}) "));
    }
    nix_list.push(']');
    let linux: Vec<String> = serde_json::from_value(claude_tokens_nix(&nix_list)).unwrap();
    assert_eq!(ours, linux);
    assert_eq!(linux[0], "{\"accounts\":{}}\n");
}

/// 宣言を止めるか通すかが、同じ宣言の Linux の claude-tokens.nix の assertions (どれも true なら通す) と同じ。素の claude の default だけは、
/// Nix が通し Windows が止める
#[test]
fn claude_tokens_rejects_like_nix() {
    if !nix_available() {
        return;
    }
    let n = |name: &'static str| vec![(name, None, None)];
    let label = |l: &'static str| vec![("alt", Some(l), None)];
    let item = |i: &'static str| vec![("alt", None, Some(i))];
    let cases: Vec<Vec<ClaudeTokenDecl>> = vec![
        n("alt"),
        n("0a"),
        n("a-b_c"),
        n("a2345678901234567890123456789012"),
        n("a23456789012345678901234567890123"),
        n("Alt"),
        n("-x"),
        n("_x"),
        n("a b"),
        n("a.b"),
        n("sk-ant-x"),
        n("account"),
        n("selector"),
        label("m.v2_x-1"),
        label("a234567890123456789012345678901234567890123456789012345678901234"),
        label("a2345678901234567890123456789012345678901234567890123456789012345"),
        label("Main"),
        label("a b"),
        label(""),
        label(".x"),
        label("sk-ant-oat01-x"),
        item("op://a/b/c"),
        item("op://a/b/s/c"),
        item("op://Private Vault/My Item/credential"),
        item("op://a/b"),
        item("op://a/b/c/d/e"),
        item(" op://a/b/c"),
        item("op://a/b/c\n"),
        item(""),
        item("sk-ant-oat01-x"),
    ];
    let mut ours = Vec::new();
    let mut nix_list = String::from("map (t: builtins.all (a: a.assertion) (ct.assertions t)) [ ");
    for decls in &cases {
        let (toml_text, nix) = claude_token_decls(decls);
        ours.push(parse(&toml_text, Path::new("h.toml"), Groups::embedded().unwrap()).is_ok());
        nix_list.push_str(&format!("({nix}) "));
    }
    nix_list.push_str(&format!("({}) ", claude_token_decls(&n("default")).1));
    nix_list.push(']');
    let mut linux: Vec<bool> = serde_json::from_value(claude_tokens_nix(&nix_list)).unwrap();
    let bare_in_nix = linux.pop().unwrap();
    for (i, decls) in cases.iter().enumerate() {
        assert_eq!(ours[i], linux[i], "{decls:?}");
    }
    // 通すものと止めるものの両方がある (どちらかに寄った比べ方になっていない)
    assert!(linux.contains(&true) && linux.contains(&false));
    // 素の claude の default: Nix は通す (Linux では素の claude が token で起きる)・Windows は止める
    assert!(bare_in_nix);
    let (toml_text, _) = claude_token_decls(&n("default"));
    assert!(parse(&toml_text, Path::new("h.toml"), Groups::embedded().unwrap()).is_err());
}

/// 形を誤った宣言 (tokens・名前ごとの値が表でない・知らないキー・label が文字列でない) を止めるか通すかも、Linux の claude-tokens.nix の
/// assertions と同じ (Nix の option の型は anything で、型では止めない)
#[test]
fn claude_tokens_shapes_reject_like_nix() {
    if !nix_available() {
        return;
    }
    let cases = [
        ("[claude]\ntokens = 1\n", "1"),
        ("[claude]\ntokens = \"x\"\n", "\"x\""),
        ("[claude.tokens]\nalt = \"x\"\n", "{ alt = \"x\"; }"),
        (
            "[claude.tokens.alt]\ntoken = \"x\"\n",
            "{ alt = { token = \"x\"; }; }",
        ),
        (
            "[claude.tokens.alt]\nlabel = 1\n",
            "{ alt = { label = 1; }; }",
        ),
        (
            "[claude.tokens.alt]\nitem = 1\n",
            "{ alt = { item = 1; }; }",
        ),
        ("[claude.tokens.alt]\n", "{ alt = { }; }"),
        ("", "{ }"),
    ];
    let mut ours = Vec::new();
    let mut nix_list = String::from("map (t: builtins.all (a: a.assertion) (ct.assertions t)) [ ");
    for (toml_text, nix) in cases {
        ours.push(parse(toml_text, Path::new("h.toml"), Groups::embedded().unwrap()).is_ok());
        nix_list.push_str(&format!("({nix}) "));
    }
    nix_list.push(']');
    let linux: Vec<bool> = serde_json::from_value(claude_tokens_nix(&nix_list)).unwrap();
    for (i, (toml_text, _)) in cases.iter().enumerate() {
        assert_eq!(ours[i], linux[i], "{toml_text}");
    }
    assert_eq!(
        linux,
        vec![false, false, false, false, false, false, true, true]
    );
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
