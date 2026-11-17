//! install-iac-guard (PreToolUse・matcher Bash|PowerShell): venv・project の外 (system・user の環境) へ入れる install と、terraform・tofu・terragrunt で
//! 実物 (資源か state) を変える操作を、打つ前に止める。Linux の `nix/files/claude/hooks/install-iac-guard.sh` の写しで、止めるもの・通すもの・返す文は
//! bash の版と同じ (Linux の CI が bash の版の試験 `nix/tests/install-iac-guard.test.sh` をこの口に流す)。IaC の guard を外す
//! `~/.local/state/dotfiles/claude-iac-guard.json` も同じに読む (Windows では runner が書かないので、いつも止める)。
//!
//! Windows だけの足し (bash の版に無い。dotfiles-private の docs/adr/067_win_hook_guards_*): PowerShell の tool も読む。通す口は PowerShell では
//! `$env:PJP_ALLOW_INSTALL='1';`・`$env:PJP_ALLOW_IAC='1';` (返す文も PowerShell の形にする)。Windows の venv (`<root>\Scripts\…`・`Activate.ps1`) と
//! py ランチャ (`py -m pip`) も読む。winget・scoop・choco の install と PowerShell の module の install (Install-Module・Install-PSResource など) は、
//! apt・brew と同じく OS の package として止める。

use super::{
    FOREIGN, LEX_LIMIT, Lang, World, base_name, cmd_command, deny, is_name, ps_alias, pwsh_command,
    skip_opts, split, wsl_command,
};
use crate::process::Sys;
use serde_json::Value;
use std::collections::HashSet;

pub fn run(raw: &str, input: &Value, sys: &dyn Sys) -> Option<String> {
    let iac_on = iac_enabled(sys);
    // 止める形の語を含むか (この hook は Bash のたびに走るので、まず文字で絞る)。PowerShell の名前は大文字小文字を問わないので小文字で見る
    let lower = raw.to_lowercase();
    if !has_words(&lower, iac_on) {
        return None;
    }
    let s = |v: Option<&Value>| v.and_then(Value::as_str).unwrap_or("").to_string();
    let tool = s(input.get("tool_name"));
    let cmd = s(input.get("tool_input").and_then(|t| t.get("command")));
    let cwd = s(input.get("cwd"));
    let lang = match tool.as_str() {
        "Bash" => Lang::Bash,
        "PowerShell" => Lang::PowerShell,
        _ => return None,
    };
    if !has_words(&cmd.to_lowercase(), iac_on) {
        return None;
    }
    let mut g = Iac::new(sys, &cwd, lang, iac_on);
    let bytes = cmd.len();
    if bytes > LEX_LIMIT {
        g.long_command(bytes.div_ceil(1024), &cmd);
    } else {
        let dir = g.w.cwd.clone();
        g.scan_command(&dir, 0, &cmd, lang);
    }
    (!g.found_install.is_empty() || !g.found_iac.is_empty()).then(|| deny(&g.emit()))
}

/// IaC の guard を外したマシンか (`~/.local/state/dotfiles/claude-iac-guard.json` の enable が false)。無い・読めない・壊れているときは止める
fn iac_enabled(sys: &dyn Sys) -> bool {
    let Some(home) = crate::hooks::home(sys) else {
        return true;
    };
    let p = home
        .join(".local")
        .join("state")
        .join("dotfiles")
        .join("claude-iac-guard.json");
    let Ok(text) = std::fs::read_to_string(&p) else {
        return true;
    };
    // "enable"[[:space:]]*:[[:space:]]*false
    let mut from = 0;
    while let Some(i) = text[from..].find("\"enable\"") {
        let rest = text[from + i + 8..].trim_start_matches(|c: char| c.is_ascii_whitespace());
        if let Some(r) = rest.strip_prefix(':')
            && r.trim_start_matches(|c: char| c.is_ascii_whitespace())
                .starts_with("false")
        {
            return false;
        }
        from += i + 8;
    }
    true
}

/// 止める形の語を含むか。yarn・bun は後ろの空白まで見る (cwd や transcript_path の ubuntu・bundle などに当てない)
fn has_words(s: &str, iac_on: bool) -> bool {
    [
        "install", "npm", "yarn ", "bun ", "winget", "scoop", "choco",
    ]
    .iter()
    .any(|k| s.contains(k))
        || (iac_on
            && ["terraform", "tofu", "terragrunt"]
                .iter()
                .any(|k| s.contains(k)))
}

/// simple の local
#[derive(Clone, Default)]
struct Local {
    allow_install: bool,
    allow_iac: bool,
    runner: bool,
    sudo: bool,
    in_text: String,
    in_known: bool,
    assigns: Vec<String>,
}

impl Local {
    /// 頭の代入で、その名前に真の値 (1・true・yes・on) を入れたか
    fn assigned(&self, name: &str) -> bool {
        self.assigns.iter().any(|a| {
            a.split_once('=').is_some_and(|(n, v)| {
                n == name && matches!(v.to_lowercase().as_str(), "1" | "true" | "yes" | "on")
            })
        })
    }

    /// w の頭の VAR=値 を外して assigns に足す。通す口は allow_install・allow_iac に効かせる
    fn take_assigns(&mut self, w: &mut Vec<String>) {
        while let Some(first) = w.first() {
            let Some((name, _)) = first.split_once('=') else {
                break;
            };
            if !is_name(name) {
                break;
            }
            match first.as_str() {
                "PJP_ALLOW_INSTALL=1" => self.allow_install = true,
                "PJP_ALLOW_IAC=1" => self.allow_iac = true,
                _ => {}
            }
            self.assigns.push(w.remove(0));
        }
    }
}

struct Iac<'a> {
    w: World<'a>,
    lang: Lang,
    iac_on: bool,
    found_install: Vec<String>,
    found_iac: Vec<String>,
    hint_pip: bool,
    hint_node: bool,
    hint_os: bool,
    hint_win: bool,
    long_kb: usize,
    venv_made: HashSet<String>,
    venv_active: bool,
    virtual_env: bool,
    inh_allow_install: bool,
    inh_allow_iac: bool,
    inh_runner: bool,
    inh_sudo: bool,
    next_dir: String,
    out_text: String,
    out_known: bool,
    last_out: String,
    last_known: bool,
}

/// `(^|[._-])env([._0-9-]|$)` (env の語。build-env・.env・env3 など)
fn env_word(base: &str) -> bool {
    let b = base.as_bytes();
    let mut from = 0;
    while let Some(i) = base[from..].find("env") {
        let p = from + i;
        let before_ok = p == 0 || matches!(b[p - 1], b'.' | b'_' | b'-');
        let after_ok = p + 3 == b.len() || matches!(b[p + 3], b'.' | b'_' | b'-' | b'0'..=b'9');
        if before_ok && after_ok {
            return true;
        }
        from = p + 1;
    }
    false
}

/// 語に `bin/activate` か Windows の `Scripts/activate` (Activate.ps1 も) があるか (`*/bin/activate*`・`bin/activate*`)
fn is_activate(word: &str, win: bool) -> bool {
    let w = if win {
        word.replace('\\', "/").to_lowercase()
    } else {
        word.to_string()
    };
    let hit = |dir: &str| {
        w.starts_with(&format!("{dir}/activate")) || w.contains(&format!("/{dir}/activate"))
    };
    hit("bin") || (win && hit("scripts"))
}

impl<'a> Iac<'a> {
    fn new(sys: &'a dyn Sys, cwd: &str, lang: Lang, iac_on: bool) -> Self {
        Iac {
            w: World::new(sys, cwd),
            lang,
            iac_on,
            found_install: Vec::new(),
            found_iac: Vec::new(),
            hint_pip: false,
            hint_node: false,
            hint_os: false,
            hint_win: false,
            long_kb: 0,
            venv_made: HashSet::new(),
            venv_active: false,
            virtual_env: sys.env("VIRTUAL_ENV").is_some_and(|v| !v.is_empty()),
            inh_allow_install: false,
            inh_allow_iac: false,
            inh_runner: false,
            inh_sudo: false,
            next_dir: String::new(),
            out_text: String::new(),
            out_known: false,
            last_out: String::new(),
            last_known: false,
        }
    }

    /// install の止めたものを 1 行足す (同じものは 1 回だけ)
    fn add_install(&mut self, f: String, hint: &str) {
        match hint {
            "pip" => self.hint_pip = true,
            "node" => self.hint_node = true,
            "os" => self.hint_os = true,
            "win" => self.hint_win = true,
            _ => {}
        }
        if !self.found_install.contains(&f) {
            self.found_install.push(f);
        }
    }

    fn add_iac(&mut self, f: String) {
        if !self.found_iac.contains(&f) {
            self.found_iac.push(f);
        }
    }

    fn venv_key(&self, p: &str) -> String {
        if self.w.win {
            p.to_lowercase()
        } else {
            p.to_string()
        }
    }

    /// 作る venv の dir を控える (uv venv は省けば .venv)
    fn venv_new(&mut self, dir: &str, uv: bool, a: &[String]) {
        let mut got = false;
        let mut i = 0;
        while i < a.len() {
            match a[i].as_str() {
                "-p" | "--python" | "--prompt" | "--index-url" | "--extra-index-url"
                | "--find-links" | "-f" | "--index" | "--default-index" | "--cache-dir"
                | "--seeder" | "--activators" | "--creator" | "--app-data" | "--link-mode"
                | "--upgrade-deps" => i += 1,
                x if x.starts_with('-') => {}
                x => {
                    let k = self.venv_key(&self.w.abs_path(dir, x, true));
                    self.venv_made.insert(k);
                    got = true;
                }
            }
            i += 1;
        }
        if !got && uv {
            let k = self.venv_key(&self.w.abs_path(dir, ".venv", true));
            self.venv_made.insert(k);
        }
    }

    /// venv の中へ入れる印があるか。パスで呼ぶ interpreter はパスで決め、素の名前のときだけ activate・runner・VIRTUAL_ENV を見る
    fn venv_mark(&self, dir: &str, interp: &str, runner: bool) -> bool {
        let interp = self.w.norm(interp);
        if !interp.contains('/') {
            return self.venv_active || runner || self.virtual_env;
        }
        let interp = self.w.expand_home(&interp);
        if interp.contains('$') {
            return true;
        }
        let bindir = interp.rsplit_once('/').map_or("", |(d, _)| d);
        let leaf = bindir.rsplit('/').next().unwrap_or(bindir);
        let is_bin = leaf == "bin"
            || leaf == "Scripts"
            || (self.w.win && leaf.eq_ignore_ascii_case("scripts"));
        if !is_bin {
            return false;
        }
        let mut root = if bindir.contains('/') {
            bindir.rsplit_once('/').map_or("", |(r, _)| r).to_string()
        } else {
            ".".to_string()
        };
        if root.is_empty() {
            root = "/".to_string();
        }
        let abs = self.w.abs_path(dir, &root, true);
        if !abs.starts_with(FOREIGN) && std::path::Path::new(&abs).join("pyvenv.cfg").is_file() {
            return true;
        }
        if self.venv_made.contains(&self.venv_key(&abs)) {
            return true;
        }
        let base = abs.rsplit('/').next().unwrap_or(&abs).to_lowercase();
        if base.contains("venv") || env_word(&base) {
            return true;
        }
        let parent = abs.rsplit_once('/').map_or("", |(p, _)| p);
        parent.rsplit('/').next().unwrap_or(parent) == "envs"
    }

    /// pip の install を見る
    fn pip_cmd(&mut self, dir: &str, interp: &str, label: &str, a: &[String], l: &Local) {
        if l.allow_install {
            return;
        }
        let mut py_opt = String::new();
        let mut sub = String::new();
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                _ if x.starts_with("--python=") => py_opt = x["--python=".len()..].to_string(),
                "--python" => {
                    py_opt = a.get(i + 1).cloned().unwrap_or_default();
                    i += 1;
                }
                "--log" | "--proxy" | "--retries" | "--timeout" | "--exists-action"
                | "--trusted-host" | "--cert" | "--client-cert" | "--cache-dir"
                | "--use-feature" | "--use-deprecated" | "--keyring-provider"
                | "--resume-retries" => i += 1,
                _ if x.starts_with('-') => {}
                _ => {
                    sub = x.to_string();
                    break;
                }
            }
            i += 1;
        }
        if sub != "install" {
            return;
        }
        let (mut user, mut bsp, mut target) = (false, false, false);
        for x in &a[i + 1..] {
            match x.as_str() {
                "-h" | "--help" | "--dry-run" => return,
                "--user" => user = true,
                "--break-system-packages" => bsp = true,
                "-t" | "--target" => target = true,
                _ if x.starts_with("--target=") => target = true,
                _ => {}
            }
        }
        if l.sudo {
            self.add_install(format!("sudo 付きの {label} install"), "pip");
        } else if user {
            self.add_install(format!("{label} install --user"), "pip");
        } else if bsp {
            self.add_install(format!("{label} install --break-system-packages"), "pip");
        } else if target {
        } else if !self.venv_mark(
            dir,
            if py_opt.is_empty() { interp } else { &py_opt },
            l.runner,
        ) {
            self.add_install(format!("{label} install (venv の印が無い)"), "pip");
        }
    }

    /// -m pip・-m venv・-m virtualenv を見る
    fn python_cmd(&mut self, dir: &str, interp: &str, a: &[String], l: &Local) {
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            let module: String;
            if let Some(m) = x.strip_prefix("-m").filter(|m| !m.is_empty()) {
                module = m.to_string();
                i += 1;
            } else if x == "-m" {
                module = a.get(i + 1).cloned().unwrap_or_default();
                i += 2;
            } else if x == "-c" {
                return;
            } else if x == "-W" || x == "-X" {
                // bash の版は値を飛ばした後、module を見ずに抜ける
                return;
            } else if x.starts_with('-') {
                i += 1;
                continue;
            } else {
                return;
            }
            let rest: &[String] = if i <= a.len() { &a[i..] } else { &[] };
            match module.as_str() {
                "pip" => self.pip_cmd(dir, interp, &format!("{interp} -m pip"), rest, l),
                "venv" | "virtualenv" => self.venv_new(dir, false, rest),
                _ => {}
            }
            return;
        }
    }

    /// system へ入れる uv pip install と uv venv を見る (uv run は simple が包みとして外す)
    fn uv_cmd(&mut self, dir: &str, a: &[String], l: &Local) {
        let mut i = 0;
        while i < a.len() {
            match a[i].as_str() {
                "--directory"
                | "--project"
                | "--cache-dir"
                | "--config-file"
                | "--color"
                | "--python-preference"
                | "--python-downloads"
                | "--allow-insecure-host" => i += 1,
                x if x.starts_with('-') => {}
                _ => break,
            }
            i += 1;
        }
        match a.get(i).map(String::as_str) {
            Some("pip") => {
                if a.get(i + 1).map(String::as_str) != Some("install") || l.allow_install {
                    return;
                }
                let mut py = String::new();
                let mut j = i + 2;
                while j < a.len() {
                    let x = a[j].as_str();
                    match x {
                        "-h" | "--help" | "--dry-run" => return,
                        "--system" | "--break-system-packages" => {
                            self.add_install(format!("uv pip install {x}"), "pip");
                            return;
                        }
                        _ if x.starts_with("--python=") || x.starts_with("-p=") => {
                            py = x.split_once('=').map_or("", |(_, v)| v).to_string();
                        }
                        "--python" | "-p" => {
                            py = a.get(j + 1).cloned().unwrap_or_default();
                            j += 1;
                        }
                        _ => {}
                    }
                    j += 1;
                }
                if l.assigned("UV_SYSTEM_PYTHON") {
                    self.add_install("uv pip install (UV_SYSTEM_PYTHON=1)".to_string(), "pip");
                } else if self.w.norm(&py).contains('/') && !self.venv_mark(dir, &py, l.runner) {
                    self.add_install(
                        format!("uv pip install --python {py} (venv でない interpreter)"),
                        "pip",
                    );
                }
            }
            Some("venv") => self.venv_new(dir, true, &a[i + 1..]),
            _ => {}
        }
    }

    /// global に入れる install を見る
    fn node_cmd(&mut self, tool: &str, a: &[String], l: &Local) {
        if l.allow_install {
            return;
        }
        let (mut sub, mut sub2, mut global) = (String::new(), String::new(), false);
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "--dry-run" => return,
                "-g" | "--global" | "--global=true" | "--location=global" => global = true,
                "--location" => {
                    if a.get(i + 1).map(String::as_str) == Some("global") {
                        global = true;
                    }
                    i += 1;
                }
                _ if x.starts_with('-') => {}
                _ => {
                    if sub.is_empty() {
                        sub = x.to_string();
                    } else if sub2.is_empty() {
                        sub2 = x.to_string();
                    }
                }
            }
            i += 1;
        }
        let installs = match tool {
            "npm" => &[
                "install", "i", "add", "in", "ins", "inst", "insta", "instal", "isnt", "isnta",
                "isntal", "isntall",
            ][..],
            "pnpm" => &["add", "install", "i"][..],
            "bun" => &["add", "a", "install", "i"][..],
            _ => &[][..],
        };
        if installs.contains(&sub.as_str()) {
            if global {
                self.add_install(format!("{tool} {sub} -g"), "node");
            }
        } else if tool == "yarn" && sub == "global" && sub2 == "add" {
            self.add_install("yarn global add".to_string(), "node");
        }
    }

    /// OS の package の install を見る (確かめるだけの -s・--simulate・--dry-run などは通す)
    fn os_cmd(&mut self, tool: &str, a: &[String], l: &Local) {
        if l.allow_install {
            return;
        }
        if a.iter().any(|x| {
            matches!(
                x.as_str(),
                "-s" | "--simulate"
                    | "--dry-run"
                    | "--just-print"
                    | "--no-act"
                    | "--recon"
                    | "-h"
                    | "--help"
            )
        }) {
            return;
        }
        let mut sub = String::new();
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "-o" | "-c" | "-t" | "--option" | "--config-file" | "--target-release" => {
                    if tool != "brew" {
                        i += 1;
                    }
                }
                _ if x.starts_with('-') => {}
                _ => {
                    sub = x.to_string();
                    break;
                }
            }
            i += 1;
        }
        let lead = if l.sudo { "sudo " } else { "" };
        if sub == "install" {
            self.add_install(format!("{lead}{tool} install"), "os");
        }
    }

    /// Windows の package (winget・scoop・choco) の install (確かめるだけの --help・--noop・--whatif は通す)
    fn win_os_cmd(&mut self, tool: &str, a: &[String], l: &Local) {
        if l.allow_install {
            return;
        }
        // help と確かめるだけの印は道具ごとに違う (winget の -h は --silent、choco の -n は --skip-powershell で、どちらも入れる)
        let info: &[&str] = match tool {
            "winget" => &["-?", "--help", "/?"],
            "choco" => &[
                "-?",
                "-h",
                "--help",
                "/?",
                "--noop",
                "--whatif",
                "--what-if",
            ],
            "scoop" => &["-h", "--help", "/?"],
            _ => &[],
        };
        if a.iter().any(|x| info.contains(&x.to_lowercase().as_str())) {
            return;
        }
        let sub = a
            .iter()
            .find(|x| !x.starts_with('-'))
            .map(|x| x.to_lowercase())
            .unwrap_or_default();
        let hit = match tool {
            "winget" => matches!(sub.as_str(), "install" | "add" | "i"),
            "scoop" | "choco" => sub == "install",
            _ => false,
        };
        if hit {
            self.add_install(format!("{tool} {sub}"), "win");
        }
    }

    /// PowerShell の module・package の install (Install-Module・Install-PSResource・Install-Package・Install-Script)。-WhatIf は通す
    fn ps_install_cmd(&mut self, word: &str, a: &[String], l: &Local) {
        if l.allow_install || a.iter().any(|x| x.eq_ignore_ascii_case("-whatif")) {
            return;
        }
        self.add_install(
            format!("{word} (PowerShell の module・package を入れる)"),
            "win",
        );
    }

    /// 実物を変える subcommand なら found_iac に足す
    fn tf_sub(&mut self, tool: &str, sub: &str, rest: &[String]) {
        if rest
            .iter()
            .any(|x| matches!(x.as_str(), "-help" | "-h" | "--help"))
        {
            return;
        }
        match sub {
            "apply" | "destroy" | "import" | "taint" | "untaint" | "force-unlock" | "refresh" => {
                self.add_iac(format!("{tool} {sub}"));
            }
            "state" | "workspace" => {
                let s2 = rest
                    .iter()
                    .find(|x| !x.starts_with('-'))
                    .cloned()
                    .unwrap_or_default();
                let hit = matches!(
                    (sub, s2.as_str()),
                    ("state", "rm" | "mv" | "push" | "replace-provider") | ("workspace", "delete")
                );
                // state rm・mv の -dry-run は、消す・移すものを見るだけ
                if hit && !rest.iter().any(|x| x == "-dry-run" || x == "--dry-run") {
                    self.add_iac(format!("{tool} {sub} {s2}"));
                }
            }
            "init" => {
                for x in rest {
                    if matches!(
                        x.as_str(),
                        "-migrate-state"
                            | "--migrate-state"
                            | "-migrate-state=true"
                            | "-force-copy"
                            | "--force-copy"
                            | "-force-copy=true"
                    ) {
                        let flag = x.split('=').next().unwrap_or(x);
                        self.add_iac(format!("{tool} init {flag}"));
                        return;
                    }
                }
            }
            _ => {}
        }
    }

    /// terraform・tofu: 最初の flag でない語を subcommand とみなす (global の flag は -chdir=… の形)
    fn tf_cmd(&mut self, tool: &str, a: &[String], l: &Local) {
        if !self.iac_on || l.allow_iac {
            return;
        }
        for (i, x) in a.iter().enumerate() {
            match x.as_str() {
                "-help" | "-h" | "--help" | "-version" | "-v" | "--version" => return,
                _ if x.starts_with('-') => {}
                _ => {
                    self.tf_sub(tool, x, &a[i + 1..]);
                    return;
                }
            }
        }
    }

    /// terragrunt: 語を順に見て、flag・知らない語・run・run-all・stack・exec は飛ばし、最初に当たった terraform の subcommand か terragrunt の操作で決める
    fn tg_cmd(&mut self, a: &[String], l: &Local) {
        if !self.iac_on || l.allow_iac {
            return;
        }
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "-help" | "-h" | "--help" | "-version" | "--version" => return,
                "run" | "run-all" | "stack" | "exec" => {}
                _ if x.starts_with('-') => {}
                "apply-all" | "destroy-all" => {
                    self.add_iac(format!("terragrunt {x}"));
                    return;
                }
                "backend" => {
                    let next = a[i + 1..]
                        .iter()
                        .find(|y| !y.starts_with('-'))
                        .cloned()
                        .unwrap_or_default();
                    if matches!(next.as_str(), "bootstrap" | "delete" | "migrate") {
                        self.add_iac(format!("terragrunt backend {next}"));
                    }
                    return;
                }
                "apply" | "destroy" | "import" | "taint" | "untaint" | "force-unlock"
                | "refresh" | "state" | "workspace" | "init" | "plan" | "validate" | "output"
                | "show" | "fmt" | "graph" | "providers" | "test" | "console" | "get"
                | "version" | "login" | "logout" | "metadata" | "modules" | "query" | "render"
                | "hcl" | "find" | "list" | "info" | "catalog" | "scaffold" | "dag" => {
                    self.tf_sub("terragrunt", x, &a[i + 1..]);
                    return;
                }
                _ => {}
            }
            i += 1;
        }
    }

    /// bash -c などに文字列で渡したものを読み直す。通す口・venv の印・sudo は中にも効かせ、中の activate は外へ出さない
    fn rescan(&mut self, dir: &str, depth: usize, s: &str, lang: Lang, l: &Local) {
        let saved = (
            self.inh_allow_install,
            self.inh_allow_iac,
            self.inh_runner,
            self.inh_sudo,
            self.venv_active,
        );
        self.inh_allow_install = l.allow_install;
        self.inh_allow_iac = l.allow_iac;
        self.inh_runner = l.runner;
        self.inh_sudo = l.sudo;
        self.scan_command(dir, depth + 1, s, lang);
        (
            self.inh_allow_install,
            self.inh_allow_iac,
            self.inh_runner,
            self.inh_sudo,
            self.venv_active,
        ) = saved;
    }

    /// 単純コマンドを 1 つ見る。cd なら next_dir に行き先を入れ、出力 (パイプの先の stdin) が分かれば out_text・out_known に入れる
    fn simple(&mut self, dir: &str, depth: usize, rec: &super::lex::Cmd) {
        let mut dir = dir.to_string();
        let ci = self.w.win || rec.ps;
        let mut w: Vec<String> = rec.words.clone();
        let mut l = Local {
            allow_install: self.inh_allow_install,
            allow_iac: self.inh_allow_iac,
            runner: self.inh_runner,
            sudo: self.inh_sudo,
            ..Local::default()
        };
        if let super::lex::Stdin::Here(t) = &rec.stdin {
            l.in_text = t.clone();
            l.in_known = true;
        } else if rec.pipe {
            l.in_text = self.last_out.clone();
            l.in_known = self.last_known;
        }

        // 頭の予約語と VAR=値
        while let Some(first) = w.first().cloned() {
            match first.as_str() {
                "!" | "{" | "}" | "if" | "then" | "else" | "elif" | "do" | "while" | "until" => {
                    w.remove(0);
                }
                "for" | "case" | "select" | "function" | "fi" | "done" | "esac" | "[[" | "[" => {
                    return;
                }
                _ if first.split_once('=').is_some_and(|(n, _)| is_name(n)) => {
                    l.take_assigns(&mut w)
                }
                _ => break,
            }
        }

        // 包むコマンドを外す (包みの後ろの VAR=値 も)。中に文字列で渡すものは読み直す
        let mut guard = 0;
        while !w.is_empty() && guard < 16 {
            guard += 1;
            l.take_assigns(&mut w);
            if w.is_empty() {
                return;
            }
            let mut name = base_name(&w[0], ci);
            if rec.ps {
                name = ps_alias(&name).to_string();
            }
            // PowerShell で Windows の venv の Activate.ps1 をそのまま流す (& .venv\Scripts\Activate.ps1。拡張子の無い activate も
            // PowerShell は Activate.ps1 を選ぶ)。Git Bash で source せずに流した activate と、cmd を起こす activate.bat は今の shell に効かない
            if rec.ps && is_activate(&w[0], true) && {
                let leaf = w[0].rsplit(['/', '\\']).next().unwrap_or("").to_lowercase();
                leaf.ends_with(".ps1") || !leaf.contains('.')
            } {
                self.venv_active = true;
                return;
            }
            match name.as_str() {
                "cd" | "pushd" => {
                    self.next_dir = if w.len() > 1 {
                        let last = w[w.len() - 1].clone();
                        self.w.join_dir(&dir, &last, false)
                    } else {
                        self.w.home.clone()
                    };
                    return;
                }
                "source" | "." => {
                    if w.get(1)
                        .is_some_and(|x| is_activate(x, self.w.win || rec.ps))
                    {
                        self.venv_active = true;
                    }
                    return;
                }
                "env" => {
                    w.remove(0);
                    while let Some(first) = w.first().cloned() {
                        match first.as_str() {
                            "-S" | "--split-string" => {
                                let s = w[1..].join(" ");
                                self.rescan(&dir, depth, &s, Lang::Bash, &l);
                                return;
                            }
                            "-u" | "--unset" | "-C" | "--chdir" => {
                                w.drain(..2.min(w.len()));
                            }
                            "PJP_ALLOW_INSTALL=1" => {
                                l.allow_install = true;
                                w.remove(0);
                            }
                            "PJP_ALLOW_IAC=1" => {
                                l.allow_iac = true;
                                w.remove(0);
                            }
                            _ if first.starts_with('-') => {
                                w.remove(0);
                            }
                            _ if first.contains('=') => {
                                l.assigns.push(w.remove(0));
                            }
                            _ => break,
                        }
                    }
                }
                "sudo" | "doas" => {
                    l.sudo = true;
                    w.remove(0);
                    skip_opts(
                        &mut w,
                        &[
                            "-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R",
                        ],
                    );
                }
                "exec" => {
                    w.remove(0);
                    skip_opts(&mut w, &["-a"]);
                }
                "command" | "builtin" => {
                    if matches!(w.get(1).map(String::as_str), Some("-v" | "-V")) {
                        return;
                    }
                    w.remove(0);
                    skip_opts(&mut w, &[]);
                }
                "nohup" | "setsid" | "unbuffer" | "chronic" | "time" => {
                    w.remove(0);
                    skip_opts(&mut w, &[]);
                }
                "nice" => {
                    w.remove(0);
                    skip_opts(&mut w, &["-n", "--adjustment"]);
                }
                "ionice" => {
                    w.remove(0);
                    skip_opts(&mut w, &["-c", "-n", "--class", "--classdata"]);
                }
                "stdbuf" => {
                    w.remove(0);
                    skip_opts(
                        &mut w,
                        &["-i", "-o", "-e", "--input", "--output", "--error"],
                    );
                }
                "timeout" => {
                    w.remove(0);
                    skip_opts(&mut w, &["-s", "-k", "--signal", "--kill-after"]);
                    if !w.is_empty() {
                        w.remove(0);
                    }
                }
                "xargs" => {
                    w.remove(0);
                    skip_opts(
                        &mut w,
                        &[
                            "-I",
                            "-n",
                            "-P",
                            "-L",
                            "-d",
                            "-E",
                            "-s",
                            "-a",
                            "--max-args",
                            "--max-procs",
                            "--max-lines",
                            "--delimiter",
                            "--eof",
                            "--max-chars",
                            "--arg-file",
                        ],
                    );
                }
                "watch" => {
                    w.remove(0);
                    skip_opts(&mut w, &["-n", "--interval", "-q", "--equexit"]);
                    let s = w.join(" ");
                    self.rescan(&dir, depth, &s, Lang::Bash, &l);
                    return;
                }
                "flock" => {
                    if let Some(i) = w.iter().skip(1).position(|x| x == "-c" || x == "--command") {
                        let s = w.get(i + 2).cloned().unwrap_or_default();
                        self.rescan(&dir, depth, &s, Lang::Bash, &l);
                        return;
                    }
                    w.remove(0);
                    skip_opts(&mut w, &["-w", "-E", "--timeout", "--conflict-exit-code"]);
                    if !w.is_empty() {
                        w.remove(0);
                    }
                }
                "bash" | "sh" | "zsh" | "dash" | "ksh" | "mksh" | "fish" => {
                    let mut i = 1;
                    while i < w.len() {
                        let x = w[i].as_str();
                        match x {
                            "-o" | "+o" | "-O" | "+O" | "--rcfile" | "--init-file" => i += 1,
                            _ if x.starts_with('-') => {
                                if super::xref::is_c_flag(x) {
                                    let s = w.get(i + 1).cloned().unwrap_or_default();
                                    self.rescan(&dir, depth, &s, Lang::Bash, &l);
                                    return;
                                }
                            }
                            _ => return,
                        }
                        i += 1;
                    }
                    // -c も script のファイルも無い shell (bash <<EOF・bash -s・cat <<EOF | bash・echo … | bash) は stdin を読む
                    if l.in_known {
                        let s = l.in_text.clone();
                        self.rescan(&dir, depth, &s, Lang::Bash, &l);
                    }
                    return;
                }
                "eval" => {
                    let s = w[1..].join(" ");
                    self.rescan(&dir, depth, &s, Lang::Bash, &l);
                    return;
                }
                "su" | "runuser" | "script" => {
                    for i in 1..w.len() {
                        if w[i] == "-c" || w[i] == "--command" {
                            let s = w.get(i + 1).cloned().unwrap_or_default();
                            self.rescan(&dir, depth, &s, Lang::Bash, &l);
                            return;
                        }
                        if let Some(v) = w[i].strip_prefix("--command=") {
                            let s = v.to_string();
                            self.rescan(&dir, depth, &s, Lang::Bash, &l);
                            return;
                        }
                    }
                    return;
                }
                "nix-shell" => {
                    if let Some(i) = w
                        .iter()
                        .skip(1)
                        .position(|x| x == "--run" || x == "--command")
                    {
                        let s = w.get(i + 2).cloned().unwrap_or_default();
                        self.rescan(&dir, depth, &s, Lang::Bash, &l);
                        return;
                    }
                    break;
                }
                "nix" => {
                    if matches!(w.get(1).map(String::as_str), Some("develop" | "shell"))
                        && let Some(i) =
                            w.iter().skip(2).position(|x| x == "-c" || x == "--command")
                    {
                        w.drain(..i + 3);
                        continue;
                    }
                    break;
                }
                "mise" => {
                    if matches!(w.get(1).map(String::as_str), Some("exec" | "x"))
                        && let Some(i) = w.iter().skip(2).position(|x| x == "--")
                    {
                        w.drain(..i + 3);
                        continue;
                    }
                    break;
                }
                "uv" => {
                    // uv run … <コマンド>: 後ろは uv が用意する venv の中
                    if w.get(1).map(String::as_str) != Some("run") {
                        break;
                    }
                    l.runner = true;
                    w.drain(..2);
                    skip_opts(
                        &mut w,
                        &[
                            "--with",
                            "-w",
                            "--with-editable",
                            "--with-requirements",
                            "--python",
                            "-p",
                            "--project",
                            "--directory",
                            "--package",
                            "--extra",
                            "--group",
                            "--only-group",
                            "--no-group",
                            "--env-file",
                            "--index",
                            "--default-index",
                            "--index-url",
                            "-i",
                            "--extra-index-url",
                            "--find-links",
                            "-f",
                            "--config-file",
                            "--cache-dir",
                            "--color",
                        ],
                    );
                }
                "poetry" | "pdm" | "hatch" | "pipenv" | "rye" => {
                    if w.get(1).map(String::as_str) != Some("run") {
                        break;
                    }
                    l.runner = true;
                    w.drain(..2);
                    skip_opts(&mut w, &[]);
                }
                "conda" | "mamba" | "micromamba" => match w.get(1).map(String::as_str) {
                    Some("run") => {
                        l.runner = true;
                        w.drain(..2);
                        skip_opts(&mut w, &["-n", "--name", "-p", "--prefix", "--cwd"]);
                    }
                    Some("activate") => {
                        if let Some(env) = w.iter().skip(2).find(|x| !x.starts_with('-'))
                            && env != "base"
                        {
                            self.venv_active = true;
                        }
                        return;
                    }
                    _ => break,
                },
                // Windows: PowerShell・cmd の中のコマンド、WSL の中のコマンド
                "pwsh" | "powershell" => {
                    if let Some(s) = pwsh_command(&w[1..]) {
                        self.rescan(&dir, depth, &s, Lang::PowerShell, &l);
                    }
                    return;
                }
                "cmd" => {
                    if let Some(s) = cmd_command(&w[1..]) {
                        self.rescan(&dir, depth, &s, Lang::PowerShell, &l);
                    }
                    return;
                }
                "wsl" => {
                    w = wsl_command(&w[1..]);
                    dir = FOREIGN.to_string();
                }
                "invoke-expression" if rec.ps => {
                    let mut rest: Vec<String> = w[1..].to_vec();
                    if rest
                        .first()
                        .is_some_and(|x| x.len() > 1 && "-command".starts_with(&x.to_lowercase()))
                    {
                        rest.remove(0);
                    }
                    self.rescan(&dir, depth, &rest.join(" "), Lang::PowerShell, &l);
                    return;
                }
                _ => break,
            }
        }
        if w.is_empty() {
            return;
        }

        let mut name = base_name(&w[0], ci);
        if rec.ps {
            name = ps_alias(&name).to_string();
        }
        let args = &w[1..];
        let pip_name = |n: &str, stem: &str| {
            n.strip_prefix(stem).is_some_and(|r| {
                r.is_empty()
                    || (r.starts_with(|c: char| c.is_ascii_digit())
                        && (r.len() == 1 || r[1..].starts_with('.')))
            })
        };
        match name.as_str() {
            n if pip_name(n, "pip") => {
                let w0 = w[0].clone();
                self.pip_cmd(&dir, &w0, &w0, args, &l);
            }
            n if pip_name(n, "python") || n == "py" => {
                let w0 = w[0].clone();
                self.python_cmd(&dir, &w0, args, &l);
            }
            "virtualenv" => self.venv_new(&dir, false, args),
            "uv" => self.uv_cmd(&dir, args, &l),
            "npm" | "pnpm" | "yarn" | "bun" => self.node_cmd(&name, args, &l),
            "apt" | "apt-get" | "brew" => self.os_cmd(&name, args, &l),
            "winget" | "scoop" | "choco" => self.win_os_cmd(&name, args, &l),
            "install-module" | "install-psresource" | "install-package" | "install-script" => {
                let w0 = w[0].clone();
                self.ps_install_cmd(&w0, args, &l);
            }
            "terraform" | "tofu" => self.tf_cmd(&name, args, &l),
            "terragrunt" => self.tg_cmd(args, &l),
            "cat" | "get-content" => {
                if args.is_empty() || args[0] == "-" {
                    self.out_text = l.in_text.clone();
                    self.out_known = l.in_known;
                }
            }
            "echo" => {
                let mut i = 0;
                while i < args.len() && matches!(args[i].as_str(), "-n" | "-e" | "-E") {
                    i += 1;
                }
                self.out_text = args[i..].join(" ");
                self.out_known = true;
            }
            "printf" => {
                // 書式の後ろの引数を 1 行ずつ (printf '%s\n' 'a' 'b' の形)。引数が無ければ書式そのもの
                self.out_text = if args.len() > 1 {
                    args[1..].join("\n")
                } else {
                    args.first().cloned().unwrap_or_default()
                };
                self.out_known = true;
            }
            _ => {}
        }
    }

    /// 単純コマンドを順に見る。cd は後ろの単純コマンドの dir に効かせる
    fn scan_command(&mut self, dir: &str, depth: usize, s: &str, lang: Lang) {
        if depth > 3 || s.len() > LEX_LIMIT {
            return;
        }
        let mut dir = dir.to_string();
        self.last_out.clear();
        self.last_known = false;
        let cmds = split(lang, s, false, &self.w);
        for rec in &cmds {
            self.next_dir.clear();
            self.out_text.clear();
            self.out_known = false;
            if !rec.words.is_empty() {
                self.simple(&dir, depth, rec);
            }
            if !self.next_dir.is_empty() {
                dir = self.next_dir.clone();
            }
            self.last_out = self.out_text.clone();
            self.last_known = self.out_known;
        }
    }

    /// 読む長さを超えたコマンドは中を読まず、行を ; & | ( ) で分けた頭に止める形があれば止める (bash の版の long_awk)
    fn long_command(&mut self, kb: usize, cmd: &str) {
        self.long_kb = kb;
        let mut venv = self.virtual_env;
        let mut outs: Vec<(bool, String)> = Vec::new();
        for line in cmd.split('\n') {
            for seg in line.split([';', '&', '|', '(', ')']) {
                if let Some(o) = long_check(seg, self.iac_on, &mut venv) {
                    outs.extend(o);
                }
            }
        }
        for (install, what) in outs {
            if install {
                self.add_install(what, "pip");
            } else {
                self.add_iac(what);
            }
        }
    }

    fn emit(&self) -> String {
        let ps = self.lang == Lang::PowerShell;
        let mut msg = if self.long_kb > 0 {
            format!(
                "[install-iac-guard] コマンドが長すぎて ({} KB。中を読むのは {} KB まで) 中を読めず、行の頭に次の形があるので止めた:",
                self.long_kb,
                LEX_LIMIT / 1024
            )
        } else {
            "[install-iac-guard] 打つ前に止めた:".to_string()
        };
        for f in self.found_install.iter().chain(&self.found_iac) {
            msg.push_str("\n- ");
            msg.push_str(f);
        }
        if !self.found_install.is_empty() {
            msg.push_str("\n\ninstall は venv・project の外 (system・user の環境) へ入れるので止めた (CLAUDE.md の「同梱 script の依存ツール」)。");
            if self.hint_pip {
                msg.push_str("\n- Python は venv の中で入れる: uv の project なら uv add <pkg>。repo の手順が pip なら uv venv か python3 -m venv .venv の後に .venv/bin/pip install … (uv pip install …・uv run pip install …・source .venv/bin/activate の後の pip install … も通す)");
            }
            if self.hint_node {
                msg.push_str("\n- Node の道具は project に入れる (pnpm add -D <pkg>) か、pnpm dlx・npx で一度だけ流す");
            }
            if self.hint_os {
                msg.push_str("\n- OS の package (apt・brew) は入れない");
            }
            if self.hint_win {
                msg.push_str("\n- Windows の package (winget・scoop・choco) と PowerShell の module は入れない");
            }
            msg.push_str("\n- system に要る道具は、nix flake の devShell → mise → (その 2 つが無理なわけを述べ、確認を取ってから) system の順で用意する");
            if ps {
                msg.push_str("\n- ユーザーがこの会話で system・user の環境へ入れると明示したときだけ、コマンドの頭に $env:PJP_ALLOW_INSTALL='1'; を付けて打ち直す (PowerShell の tool。Bash の tool なら PJP_ALLOW_INSTALL=1。自分の判断では付けない)");
            } else {
                msg.push_str("\n- ユーザーがこの会話で system・user の環境へ入れると明示したときだけ、コマンドの頭に PJP_ALLOW_INSTALL=1 を付けて打ち直す(自分の判断では付けない)");
            }
        }
        if !self.found_iac.is_empty() {
            msg.push_str("\n\nIaC の操作は実物 (資源か state) を変えるので止めた。実環境への apply は、merge の後に人が流す (Claude は検査か plan まで)。");
            msg.push_str(
                "\n- plan・validate・test で確かめ、流すコマンドと plan の要点をユーザーに伝える",
            );
            if ps {
                msg.push_str("\n- ユーザーがこの会話で流すと明示したときだけ、コマンドの頭に $env:PJP_ALLOW_IAC='1'; を付けて打ち直す (PowerShell の tool。Bash の tool なら PJP_ALLOW_IAC=1。自分の判断では付けない)");
            } else {
                msg.push_str("\n- ユーザーがこの会話で流すと明示したときだけ、コマンドの頭に PJP_ALLOW_IAC=1 を付けて打ち直す (自分の判断では付けない)");
            }
            msg.push_str("\n- agent が自分で apply してよい sandbox のマシンなら、host の option dotfiles.claude.iacGuard.enable = false (Claude Code on the web では bootstrap-claude-cloud.sh の --no-iac-guard) で外せる (外すかはユーザーが決める)");
        }
        if self.long_kb > 0 {
            msg.push_str("\n\nファイルの中身は Write の tool で書いてコマンドを短くすれば、中を読んで確かめる。");
        }
        msg
    }
}

fn blank(c: char) -> bool {
    c == ' ' || c == '\t'
}

/// `^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'[^']*'|[^ \t]*)[ \t]+` に当たる頭の長さ (バイト)
fn assign_prefix(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    let mut i = 0;
    if !(i < b.len() && (b[i].is_ascii_alphabetic() || b[i] == b'_')) {
        return None;
    }
    while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
        i += 1;
    }
    if b.get(i) != Some(&b'=') {
        return None;
    }
    i += 1;
    let ws = |mut j: usize| -> Option<usize> {
        let st = j;
        while j < b.len() && (b[j] == b' ' || b[j] == b'\t') {
            j += 1;
        }
        (j > st).then_some(j)
    };
    let mut best: Option<usize> = None;
    for q in *b"\"'" {
        if b.get(i) == Some(&q)
            && let Some(k) = b[i + 1..].iter().position(|&x| x == q)
            && let Some(e) = ws(i + 1 + k + 1)
        {
            best = Some(best.map_or(e, |x| x.max(e)));
        }
    }
    let mut j = i;
    while j < b.len() && b[j] != b' ' && b[j] != b'\t' {
        j += 1;
    }
    if let Some(e) = ws(j) {
        best = Some(best.map_or(e, |x| x.max(e)));
    }
    best
}

/// 空白で区切った語 (前後の [ \t] つき) が s の中にあるか (`[ \t](a|b)[ \t]`)。`tail_eq` なら後ろが `=` でもよい
fn has_tok(s: &str, toks: &[&str], tail_eq: bool) -> bool {
    let b = s.as_bytes();
    for t in toks {
        let mut from = 0;
        while let Some(i) = s[from..].find(t) {
            let p = from + i;
            let e = p + t.len();
            let before = p > 0 && (b[p - 1] == b' ' || b[p - 1] == b'\t');
            let after = e < b.len() && (b[e] == b' ' || b[e] == b'\t' || (tail_eq && b[e] == b'='));
            if before && after {
                return true;
            }
            from = p + 1;
        }
    }
    false
}

/// 頭の語 (空白の前まで) と、その後ろ
fn first_word(s: &str) -> (&str, &str) {
    match s.find([' ', '\t']) {
        Some(i) => (&s[..i], &s[i..]),
        None => (s, ""),
    }
}

/// 長いコマンドの 1 つの区切りを見る (bash の版の long_awk の check)。止めるものを (install か, 止めたもの) で返す
fn long_check(seg: &str, iac: bool, venv: &mut bool) -> Option<Vec<(bool, String)>> {
    let ai = seg.contains("PJP_ALLOW_INSTALL=1");
    let aa = seg.contains("PJP_ALLOW_IAC=1");
    let mut s: String = seg.to_string();
    let mut w = false;
    loop {
        s = s.trim_start_matches(blank).to_string();
        let (fw, rest) = first_word(&s);
        if let Some(n) = assign_prefix(&s) {
            s = s[n..].to_string();
        } else if matches!(
            fw,
            "sudo" | "doas" | "env" | "time" | "nohup" | "exec" | "command" | "nice"
        ) && rest.starts_with(blank)
        {
            s = rest.trim_start_matches(blank).to_string();
            w = true;
        } else if w && fw.starts_with('-') && rest.starts_with(blank) {
            s = rest.trim_start_matches(blank).to_string();
        } else if fw == "timeout" && rest.starts_with(blank) {
            let r = rest.trim_start_matches(blank);
            let (_, r2) = first_word(r);
            if r2.starts_with(blank) && !r.is_empty() && !r.starts_with(blank) {
                s = r2.trim_start_matches(blank).to_string();
            } else {
                break;
            }
        } else if matches!(fw, "bash" | "sh" | "zsh" | "dash") && rest.starts_with(blank) {
            let r = rest.trim_start_matches(blank);
            let (flag, r2) = first_word(r);
            let r3 = r2.trim_start_matches(blank);
            if super::xref::is_c_flag(flag)
                && r2.starts_with(blank)
                && (r3.starts_with('"') || r3.starts_with('\''))
            {
                s = r3[1..].to_string();
            } else {
                break;
            }
        } else {
            break;
        }
    }
    // 引用符は語を分けるだけなので空白にする (bash -c 'terraform apply' の閉じる ' など)
    let mut s = s.replace(['"', '\''], " ");
    s.push(' ');
    let (fw, rest) = first_word(&s);
    if (fw == "source" || fw == ".") && rest.starts_with(blank) {
        let r = rest.trim_start_matches(blank);
        let (path, _) = first_word(r);
        if path.contains("bin/activate") {
            *venv = true;
            return None;
        }
    }
    let mut out = Vec::new();
    let note = |what: &str| format!("{what} (長いコマンドの中)");
    if !ai {
        if pip_head(&s)
            && !*venv
            && !has_tok(&s, &["-t", "--target", "--dry-run", "-h", "--help"], true)
        {
            out.push((true, note("pip install")));
        } else if uv_pip_install(&s) && has_tok(&s, &["--system", "--break-system-packages"], false)
        {
            out.push((true, note("uv pip install --system")));
        } else if matches!(fw, "npm" | "pnpm" | "bun")
            && has_tok(
                &s,
                &[
                    "install", "i", "add", "a", "in", "ins", "inst", "insta", "instal", "isnt",
                    "isnta", "isntal", "isntall",
                ],
                false,
            )
            && has_tok(&s, &["-g", "--global", "--location=global"], false)
            && !has_tok(&s, &["--dry-run"], false)
        {
            out.push((true, note("npm・pnpm・bun の -g")));
        } else if seq_head(&s, &["yarn", "global", "add"]) {
            out.push((true, note("yarn global add")));
        } else if matches!(fw, "apt" | "apt-get")
            && has_tok(&s, &["install"], false)
            && !has_tok(
                &s,
                &[
                    "-s",
                    "--simulate",
                    "--dry-run",
                    "--just-print",
                    "--no-act",
                    "--recon",
                ],
                false,
            )
        {
            out.push((true, note("apt-get install")));
        } else if seq_head(&s, &["brew", "install"]) && !has_tok(&s, &["--dry-run"], false) {
            out.push((true, note("brew install")));
        }
    }
    if iac
        && !aa
        && matches!(fw, "terraform" | "tofu" | "terragrunt")
        && !has_tok(&s, &["-help", "-h", "--help"], false)
    {
        let changes = has_tok(
            &s,
            &[
                "apply",
                "destroy",
                "import",
                "taint",
                "untaint",
                "force-unlock",
                "refresh",
                "apply-all",
                "destroy-all",
            ],
            false,
        ) || (seq_any(&s, &["state"], &["rm", "mv", "push", "replace-provider"])
            && !has_tok(&s, &["--dry-run", "-dry-run"], false))
            || seq_any(&s, &["workspace"], &["delete"])
            || seq_any(&s, &["backend"], &["bootstrap", "delete", "migrate"])
            || has_tok(
                &s,
                &[
                    "-migrate-state",
                    "--migrate-state",
                    "-force-copy",
                    "--force-copy",
                    "-migrate-state=true",
                    "--migrate-state=true",
                    "-force-copy=true",
                    "--force-copy=true",
                ],
                false,
            );
        if changes {
            // awk の substr(s, 1, index(s, " ") - 1) (最初の空白 (タブは数えない) の手前まで。s の末尾には空白を足してある)
            let label = &s[..s.find(' ').unwrap_or(s.len())];
            out.push((false, note(&format!("{label} の実物を変える操作"))));
        }
    }
    (!out.is_empty()).then_some(out)
}

/// `[ \t]a[ \t]+b[ \t]` (a の後ろに 1 つ以上の空白を挟んで b) が s の中にあるか
fn seq_any(s: &str, a: &[&str], b: &[&str]) -> bool {
    let bs = s.as_bytes();
    for x in a {
        let mut from = 0;
        while let Some(i) = s[from..].find(x) {
            let p = from + i;
            let e = p + x.len();
            if p > 0 && blank(bs[p - 1] as char) && e < bs.len() && blank(bs[e] as char) {
                let r = s[e..].trim_start_matches(blank);
                for y in b {
                    if r.starts_with(y) && r[y.len()..].starts_with(blank) {
                        return true;
                    }
                }
            }
            from = p + 1;
        }
    }
    false
}

/// `^a[ \t]+b[ \t]+c[ \t]` (頭から語が並ぶ)
fn seq_head(s: &str, ws: &[&str]) -> bool {
    let mut r = s;
    for (k, w) in ws.iter().enumerate() {
        let Some(rest) = r.strip_prefix(w) else {
            return false;
        };
        if !rest.starts_with(blank) {
            return false;
        }
        r = if k + 1 < ws.len() {
            rest.trim_start_matches(blank)
        } else {
            rest
        };
    }
    true
}

/// `^(pip[0-9.]*|python[0-9.]*[ \t]+-m[ \t]+pip)[ \t]+install[ \t]`
fn pip_head(s: &str) -> bool {
    let after_ver = |r: &str| {
        r.trim_start_matches(|c: char| c.is_ascii_digit() || c == '.')
            .to_string()
    };
    let rest = if let Some(r) = s.strip_prefix("pip") {
        after_ver(r)
    } else if let Some(r) = s.strip_prefix("python") {
        let r = after_ver(r);
        if !r.starts_with(blank) {
            return false;
        }
        let r = r.trim_start_matches(blank);
        let Some(r) = r.strip_prefix("-m") else {
            return false;
        };
        if !r.starts_with(blank) {
            return false;
        }
        let Some(r) = r.trim_start_matches(blank).strip_prefix("pip") else {
            return false;
        };
        r.to_string()
    } else {
        return false;
    };
    if !rest.starts_with(blank) {
        return false;
    }
    let r = rest.trim_start_matches(blank);
    r.strip_prefix("install")
        .is_some_and(|x| x.starts_with(blank))
}

/// `^uv[ \t].*[ \t]pip[ \t]+install[ \t]` (uv の後ろの空白より後ろに、空白に挟まれた pip install)
fn uv_pip_install(s: &str) -> bool {
    let Some(r) = s.strip_prefix("uv") else {
        return false;
    };
    if !r.starts_with(blank) {
        return false;
    }
    let tail = &s[3..];
    let b = tail.as_bytes();
    let mut from = 0;
    while let Some(i) = tail[from..].find("pip") {
        let p = from + i;
        if p > 0 && blank(b[p - 1] as char) {
            let r = &tail[p + 3..];
            if r.starts_with(blank) {
                let r = r.trim_start_matches(blank);
                if r.strip_prefix("install")
                    .is_some_and(|x| x.starts_with(blank))
                {
                    return true;
                }
            }
        }
        from = p + 1;
    }
    false
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - venv の印 (pyvenv.cfg・名前・envs・同じコマンドで作った venv・Windows の Scripts)、env の語の判定
    //! - 長いコマンドの区切りの頭の読み方 (bash の版の long_awk の正規表現の写し)
    //! - PowerShell の tool のコマンド (pip・py -m pip・npm -g・winget・Install-Module・terraform apply と、$env: の通す口・.venv\Scripts の pip・
    //!   Activate.ps1 の後の pip) を止める・通す。止める文の通す口は PowerShell の形
    //! - bash の版の試験 (nix/tests/install-iac-guard.test.sh) をこの口に流して通る (`tests/guard_suites.rs`。bash と jq がある Linux)

    use super::*;
    use crate::testutil::{FakeSys, TempDir};
    use serde_json::json;

    #[test]
    fn env_words_and_activate() {
        for yes in ["env", ".env", "build-env", "env3", "my_env.d"] {
            assert!(env_word(yes), "{yes}");
        }
        for no in ["environment", "venvx", "denv"] {
            assert!(!env_word(no), "{no}");
        }
        assert!(is_activate(".venv/bin/activate", false));
        assert!(is_activate("bin/activate.fish", false));
        assert!(is_activate(".venv\\Scripts\\Activate.ps1", true));
        assert!(!is_activate(".venv\\Scripts\\Activate.ps1", false));
    }

    #[test]
    fn long_segments() {
        let mut venv = false;
        let c = |seg: &str, venv: &mut bool| long_check(seg, true, venv).unwrap_or_default();
        assert_eq!(c("sudo -E pip install x", &mut venv).len(), 1);
        assert_eq!(
            c(" FOO=\"a b\" terraform apply", &mut venv)[0].1,
            "terraform の実物を変える操作 (長いコマンドの中)"
        );
        assert_eq!(c("bash -c 'terraform apply", &mut venv).len(), 1);
        assert!(c("npm ls -g", &mut venv).is_empty());
        assert!(c("terraform init -migrate-state=false", &mut venv).is_empty());
        assert!(c("terraform plan", &mut venv).is_empty());
        assert!(c("source .venv/bin/activate ", &mut venv).is_empty());
        assert!(venv);
        assert!(c("pip install x", &mut venv).is_empty());
        assert!(pip_head("python3 -m pip install x "));
        assert!(!pip_head("pipx install x "));
        assert!(uv_pip_install("uv --quiet pip install --system x "));
        assert!(!uv_pip_install("uv pip install --system x "));
    }

    #[test]
    fn powershell_commands() {
        let t = TempDir::new("iac-ps");
        std::fs::create_dir_all(t.path().join("box").join("Scripts")).unwrap();
        std::fs::write(t.path().join("box").join("pyvenv.cfg"), "home = x\n").unwrap();
        let home = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
        let sys = FakeSys::new(|_| unreachable!()).with_env(home, &t.path().to_string_lossy());
        let ps = |cmd: &str| {
            let v = json!({"tool_name": "PowerShell", "tool_input": {"command": cmd}, "cwd": t.path().to_string_lossy()});
            run(&v.to_string(), &v, &sys).map(|o| {
                let v: Value = serde_json::from_str(o.trim()).unwrap();
                v["hookSpecificOutput"]["permissionDecisionReason"]
                    .as_str()
                    .unwrap()
                    .to_string()
            })
        };
        let why = ps("pip install requests").expect("pip install");
        assert!(why.contains("$env:PJP_ALLOW_INSTALL='1';"), "{why}");
        assert!(ps("py -3.12 -m pip install requests").is_some());
        assert!(ps("npm install -g foo").is_some());
        assert!(
            ps("winget install --id Git.Git")
                .unwrap()
                .contains("Windows の package")
        );
        assert!(ps("Install-Module -Name Pester -Scope CurrentUser").is_some());
        let why = ps("terraform apply").expect("terraform apply");
        assert!(why.contains("$env:PJP_ALLOW_IAC='1';"), "{why}");
        assert!(ps("$env:PJP_ALLOW_INSTALL = '1'; pip install x").is_none());
        assert!(ps("$env:PJP_ALLOW_IAC=1; terraform apply").is_none());
        assert!(ps("winget list").is_none());
        assert!(ps("Install-Module Pester -WhatIf").is_none());
        assert!(ps("terraform plan").is_none());
        // help と確かめるだけの印は道具ごと (winget の -h は --silent、choco の -n は --skip-powershell)
        assert!(ps("winget install -e --id Git.Git -h").is_some());
        assert!(ps("choco install git -y -n").is_some());
        assert!(ps("choco install git --noop").is_none());
        assert!(ps("winget install --help").is_none());
        // PowerShell で Activate.ps1 (拡張子の無い activate も) を流すと venv の中。activate.bat は今の shell に効かない
        assert!(ps("& .venv\\Scripts\\Activate.ps1; pip install x").is_none());
        assert!(ps(". .\\.venv\\Scripts\\Activate.ps1; pip install x").is_none());
        assert!(ps(".venv\\Scripts\\activate; pip install x").is_none());
        assert!(ps(".venv\\Scripts\\activate.bat; pip install x").is_some());
        assert!(ps("powershell -NoProfile -Exec Bypass -Command \"pip install x\"").is_some());
        // Git Bash で source せずに流した activate は、今の shell に効かない
        let bash = |cmd: &str| {
            let v = json!({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": t.path().to_string_lossy()});
            run(&v.to_string(), &v, &sys)
        };
        assert!(bash(".venv/Scripts/activate; pip install x").is_some());
        if cfg!(windows) {
            assert!(bash("source .venv/Scripts/activate; pip install x").is_none());
            assert!(ps(".\\box\\Scripts\\pip.exe install x").is_none());
        }
    }
}
