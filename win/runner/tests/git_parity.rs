//! runner が Windows に書く git の設定 (src/steps/git_config.rs) を、Linux の home/modules/git.nix (home-manager の programs.git) と突き合わせる。
//! どちらも nix/home/modules/git.toml を読むので値はそろうはずで、ここでは「Windows に入れないもの」と「OS で違うもの」の外に差が無いことを見る。
//!
//! ## 確かめること
//!
//! - runner の書き方 (`to_git_ini`) で WSL の `programs.git.iniContent` と includes を書くと、home-manager が書く `~/.config/git/config` と
//!   同じバイト列 (書き方の写しが合っている)
//! - Windows の config の includeIf より前の節が、WSL の iniContent から Windows に入れないもの (1Password の署名・delta) を除き、lfs の filter の
//!   git-lfs のパスをそろえたものと同じ。名前とメールのあるホスト (sandbox・1Password の WSL) と無いホスト (client の 1Password)
//!   (Windows だけの core.sshCommand は除いて比べ、WSL に無いことを見る)
//! - owner ごとの include の名前とメールが WSL の includes の contents と同じ。条件は WSL が `~/workdir` の下 (末尾の / なし。変えていない)、
//!   Windows が `~/ghq` の下 (末尾の /・/i)
//! - Windows の ignore が、WSL の ignore から direnv の `.direnv/` を除いたものと同じ
//!
//! nix が PATH に無ければ飛ばす (Windows の CI など)。`DOTFILES_WIN_NIX_PARITY=1` なら飛ばさずに落ちる (CI の Linux の job)。

mod common;

use common::which;
use dotfiles_win::steps::git_config::{self, GitData, Ini, IniValue};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .canonicalize()
        .unwrap()
}

fn data() -> GitData {
    let path = repo()
        .join("nix")
        .join("home")
        .join("modules")
        .join("git.toml");
    git_config::parse(&std::fs::read_to_string(path).unwrap()).unwrap()
}

/// 作り物のホストの git の設定 (home-manager が作るもの)
struct Wsl {
    name: &'static str,
    /// `~/.config/git/config`
    text: String,
    /// `~/.config/git/ignore`
    ignore: String,
    ini: Ini,
    /// (条件・include のファイルのパス・[user] の名前とメール)
    includes: Vec<(String, String, BTreeMap<String, String>)>,
}

/// `cfg` (home-manager の config を指す Nix の式。flake は `<flake>` と書く) の git の設定を評価する (flake を `path:` で読む。素のパスだと
/// repo 全体を /nix/store へ写す)。
fn wsl(name: &'static str, cfg: &str) -> Wsl {
    let flake = format!(
        "(builtins.getFlake \"path:{}\")",
        repo().join("nix").display()
    );
    let cfg = cfg.replace("<flake>", &flake);
    let expr = format!(
        r#"let c = {cfg}; in {{
          text = c.xdg.configFile."git/config".text;
          ignore = c.xdg.configFile."git/ignore".text;
          ini = c.programs.git.iniContent;
          includes = map (i: {{ inherit (i) condition; path = "${{i.path}}"; user = i.contents.user; }}) c.programs.git.includes;
        }}"#
    );
    let out = Command::new("nix")
        .args(["eval", "--impure", "--json", "--expr"])
        .arg(&expr)
        .output()
        .expect("nix を起こせない");
    assert!(
        out.status.success(),
        "{name}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let mut ini = Ini::new();
    flatten(&mut Vec::new(), &v["ini"], &mut ini);
    let includes = v["includes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| {
            let user = i["user"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, x)| (k.clone(), x.as_str().unwrap().to_string()))
                .collect();
            (
                i["condition"].as_str().unwrap().to_string(),
                i["path"].as_str().unwrap().to_string(),
                user,
            )
        })
        .collect();
    Wsl {
        name,
        text: v["text"].as_str().unwrap().to_string(),
        ignore: v["ignore"].as_str().unwrap().to_string(),
        ini,
        includes,
    }
}

/// iniContent (入れ子の attrset) を、入れ子は subsection として `.` でつないだ節にして並べる (home-manager の gitFlattenAttrs と同じ)。
fn flatten(path: &mut Vec<String>, v: &serde_json::Value, out: &mut Ini) {
    if let serde_json::Value::Object(m) = v {
        for (k, x) in m {
            path.push(k.clone());
            flatten(path, x, out);
            path.pop();
        }
        return;
    }
    let (key, section) = path.split_last().expect("iniContent の一番上に値がある");
    let values = match v {
        serde_json::Value::Array(items) => items.iter().map(scalar).collect(),
        x => vec![scalar(x)],
    };
    out.entry(section.join("."))
        .or_default()
        .insert(key.clone(), values);
}

fn scalar(v: &serde_json::Value) -> IniValue {
    match v {
        serde_json::Value::String(s) => IniValue::Str(s.clone()),
        serde_json::Value::Bool(b) => IniValue::Bool(*b),
        serde_json::Value::Number(n) => IniValue::Int(n.as_i64().expect("整数でない")),
        other => panic!("iniContent に文字列・真偽値・整数でない値: {other}"),
    }
}

/// Windows に入れないもの: 1Password の署名 (commit・tag の gpgSign・[gpg]・user.signingKey) と delta (core.pager・pager の 4 つ・
/// interactive.diffFilter・[delta])。home-manager の delta が足すキーが変わったら、ここが落ちて気づく
fn wsl_only(section: &str, key: &str) -> bool {
    matches!(
        (section, key),
        ("commit", "gpgSign")
            | ("tag", "gpgSign")
            | ("user", "signingKey")
            | ("core", "pager")
            | ("interactive", "diffFilter")
            | ("pager", "diff")
            | ("pager", "log")
            | ("pager", "show")
            | ("pager", "blame")
    ) || section == "gpg"
        || section.starts_with("gpg.")
        || section == "delta"
}

/// WSL の iniContent を Windows から見た形にする: Windows に入れないものを除き、lfs の filter の git-lfs を PATH のものにそろえる。
fn windows_view(ini: &Ini) -> Ini {
    let mut out = Ini::new();
    for (section, keys) in ini {
        for (key, values) in keys {
            if wsl_only(section, key) {
                continue;
            }
            let values = values
                .iter()
                .map(|v| match v {
                    IniValue::Str(s) if section == "filter.lfs" && s.starts_with("/nix/store/") => {
                        let at = s.find("/bin/git-lfs").expect("git-lfs のパス");
                        IniValue::Str(s[at + "/bin/".len()..].to_string())
                    }
                    other => other.clone(),
                })
                .collect();
            out.entry(section.clone())
                .or_default()
                .insert(key.clone(), values);
        }
    }
    out
}

/// 作り物のホスト (名前・home-manager の config の式・名前とメールを書くか)
fn hosts() -> Vec<(Wsl, bool)> {
    vec![
        (
            wsl("sandbox", "<flake>.homeConfigurations.sandbox.config"),
            true,
        ),
        (
            wsl(
                "wsl-1password",
                r#"(<flake>.lib.mkHome { username = "user"; system = "x86_64-linux"; wsl = { enable = true; windowsUserName = "alice"; }; onePassword.enable = true; }).config"#,
            ),
            true,
        ),
        (
            wsl(
                "client-1password",
                r#"(<flake>.lib.mkHome { username = "user"; system = "x86_64-linux"; group = "client"; onePassword.enable = true; }).config"#,
            ),
            false,
        ),
    ]
}

#[test]
fn matches_home_manager() {
    if !nix_available() {
        return;
    }
    let d = data();
    for (w, identity) in hosts() {
        let name = w.name;
        // 書き方の写し: WSL の iniContent と includes を runner の書き方で書くと、home-manager の config と同じバイト列
        let mut text = git_config::to_git_ini(&w.ini);
        for (condition, path, _) in &w.includes {
            let include = Ini::from([(
                format!("includeIf.{condition}"),
                BTreeMap::from([("path".to_string(), vec![IniValue::Str(path.clone())])]),
            )]);
            text.push('\n');
            text.push_str(&git_config::to_git_ini(&include));
        }
        assert_eq!(text, w.text, "{name}: 書き方が home-manager と違う");

        // 値: Windows に入れないものと lfs のパスの外は同じ
        assert_eq!(w.ini.contains_key("user"), identity, "{name}");
        // core.sshCommand は Windows だけ (runner が Windows の OpenSSH の ssh.exe を書く)。WSL には無い
        assert!(
            !w.ini.iter().any(|(s, k)| s.eq_ignore_ascii_case("core")
                && k.keys().any(|k| k.eq_ignore_ascii_case("sshCommand"))),
            "{name}: WSL に core.sshCommand がある"
        );
        assert_eq!(
            git_config::main_ini(&d, identity, None),
            windows_view(&w.ini),
            "{name}: Windows の config と WSL の config の値が違う (どの OS でも同じにする値は git.toml に書く)"
        );

        // owner ごとの名前とメール: WSL の includes と同じ owner・名前・メール。条件は OS ごと
        let owners: Vec<&git_config::Owner> = if identity {
            d.owners.iter().collect()
        } else {
            Vec::new()
        };
        assert_eq!(w.includes.len(), owners.len(), "{name}");
        for (o, (condition, _, user)) in owners.iter().zip(&w.includes) {
            assert_eq!(
                condition,
                &format!("gitdir:~/workdir/github.com/{}", o.owner),
                "{name}: WSL の条件は変えない"
            );
            assert_eq!(
                git_config::include_condition(&o.owner),
                format!("gitdir/i:~/ghq/github.com/{}/", o.owner)
            );
            assert_eq!(
                user,
                &BTreeMap::from([
                    ("email".to_string(), o.email.clone()),
                    ("name".to_string(), o.name.clone()),
                ]),
                "{name}"
            );
        }

        // ignore: WSL の ignore から direnv の .direnv/ を除いたもの
        let files = git_config::render(&d, identity, None);
        let ignore = &files.iter().find(|(n, _)| n == "ignore").unwrap().1;
        let direnv = w.ignore.lines().filter(|l| *l == ".direnv/").count();
        assert_eq!(
            direnv, 1,
            "{name}: WSL の ignore に .direnv/ が 1 つ (direnv の module が足す)"
        );
        let wsl_lines: Vec<&str> = w.ignore.lines().filter(|l| *l != ".direnv/").collect();
        assert_eq!(ignore.lines().collect::<Vec<_>>(), wsl_lines, "{name}");
    }
}

fn nix_available() -> bool {
    let found = which("nix").is_some();
    if !found && std::env::var("DOTFILES_WIN_NIX_PARITY").as_deref() == Ok("1") {
        panic!("DOTFILES_WIN_NIX_PARITY=1 なのに nix が PATH にありません");
    }
    found
}
