//! ## 確かめること
//!
//! runner だけの試験 (偽の Sys。Windows の CI でも流れる。WSL の nix/tests/bootstrap-windows-pin-updates.test.sh の setup の手順のケースと、
//! check-winget-version.test.sh・check-herdr-app-version.test.sh の JSON の口のうち setup が使うもの):
//! - gh が無い・ログインしていないなら、確かめられないと 1 行出して manual (名前は確かめない)。SSH の会話なら見込みを添える。token は出さない
//! - 見送っていない新しい版があれば、頼み方の見出しと名前ごとの 1 行 (4 つ以上は頭と末尾と個数) を出し、行は · (終了コードに数えない)。出た日は引かず、
//!   herdr-app と herdr-core は 1 回で読む
//! - herdr-app に見送っていない新しい版があれば、続きの行の末尾に keys.json の注意を 2 行。herdr-core だけ・herdr-app は見送った版だけ・windowsHerdr が
//!   false なら添えない
//! - 新しい版が無い・見送った版だけなら「無い」の 1 行で ✔
//! - 名前の on/off: windowsNtn・windowsClaudeCode・windowsHerdr (herdr・herdr-app・herdr-core)・windowsTailscale (既定は off) と、bootstrap の 4 つと
//!   ghq・fzf・starship は Windows の ghq に dotfiles の clone があるときだけ。同じものを入れる手順と同じ switch (ghq・fzf・starship を入れる手順は
//!   いつも on の Windows にしか無い手順で、bootstrap の clone の runner が流す)
//! - 確かめられない名前はわけを添えて 1 行出して failed (ほかの名前の新しい版は知らせる。わけは最初の名前のもの): API の失敗 (gh の stderr)・404・一覧で
//!   ない応答・版のディレクトリが無い (herdr の Preview だけも)・上限を過ぎた・ps1 と見送りの一覧の誤り
//! - winget-pkgs の版: 固定した版より新しい版を sort -V の古い順に、見送った版は理由つきで (知らせない)。版の形でないディレクトリ・ファイル・herdr の
//!   Preview は数えない。固定した版の形 (tailscale は X.Y.Z だけ)。見送りの一覧の BOM・CRLF・注釈・同じ版は初めの行
//! - herdr-app・herdr-core: tag の vX.Y.Z のうち新しい版で、Windows の成果物の HEAD が (redirect の先で) 404 の版は数えない。見送った版は HEAD を
//!   打たない。curl が落ちた・無いときは数える。releases.json の誤り・見送りの一覧の誤り・tag を読めない (gh の stderr が先) は 2 つとも確かめられない
//! - check・dry-run・apply は同じで、何も書かない
//! - sort -V の比べ方 (filevercmp とバイト列)・bash の read の切り方・reason_of
//! - WSL の script の字と比べる (見出し・keys.json の注意・知らせる文・名前の並び・名前ごとの題と ps1 と param と変数と版の形と例と Preview・herdr の
//!   取得元と title・誤りの文の形)
//!
//! WSL の版との突き合わせ (Linux。bash と jq があれば流れ、`DOTFILES_WIN_BASH_PARITY=1` なら無いと落ちる):
//! - WSL の check-winget-version.sh --json <名前>・check-herdr-app-version.sh --json と runner の口を、同じ偽の gh・curl と同じ repo のファイルで流し、
//!   新しい版 (と見送った理由) か、確かめられなかったときの stderr の行が同じ
//! - WSL の bootstrap-windows-pin-updates.sh (本物の check-*.sh を呼ぶ) と runner の手順を同じ状態から流し、知らせる文と、打った gh・curl の引数と順が
//!   同じ (repo の本物の ps1・見送りの一覧・releases.json でも)
//! - 比べ方が sort -V と同じ

use super::herdr::{SHA_KEYS, artifact_url, final_status, title_of};
use super::winget::{SPECS, id_value, manifest_dir, pinned_value};
use super::*;
use crate::host::{Groups, parse};
use crate::manifest::Roots;
use crate::process::RunResult;
use crate::testutil::{FakeSys, TempDir, stderr_line};
use serde_json::json;
use std::collections::BTreeMap;
use std::path::PathBuf;

const GH: &str = "/fake/gh";
const CURL: &str = "/fake/curl";
const CONTENTS: &str = "repos/microsoft/winget-pkgs/contents/";
const CHECK: Mode = Mode::Check;

/// 名前ごとの作り物の固定した版とパッケージ ID (ID は本物と同じ。manifest のディレクトリを組むため)
fn pinned_of(name: &str) -> &'static str {
    match name {
        "openssh" => "10.1.0.0",
        "herdr" => "0.9.5",
        "google-japanese-input" => "3.35.6300.0",
        "ntn" => "0.23.28",
        "claude-code" => "2.1.318",
        "tailscale" => "1.104.5",
        "ghq" => "1.12.0",
        "fzf" => "0.75.0",
        "starship" => "1.27.0",
        "git" => "2.56.0.4",
        "gh" => "2.103.3",
        "pwsh" => "7.6.10.0",
        "vs-buildtools" => "17.14.44",
        "rustup" => "1.29.3",
        "herdr-app" => "0.1.15",
        "herdr-core" => "0.1.21",
        other => panic!("知らない名前: {other}"),
    }
}

fn id_of(name: &str) -> &'static str {
    match name {
        "openssh" => "Microsoft.OpenSSH.Preview",
        "herdr" => "Herdr.Herdr",
        "google-japanese-input" => "Google.JapaneseIME",
        "ntn" => "Notion.ntn",
        "claude-code" => "Anthropic.ClaudeCode",
        "tailscale" => "Tailscale.Tailscale",
        "ghq" => "x-motemen.ghq",
        "fzf" => "junegunn.fzf",
        "starship" => "Starship.Starship",
        "git" => "Git.Git",
        "gh" => "GitHub.cli",
        "pwsh" => "Microsoft.PowerShell",
        "vs-buildtools" => "Microsoft.VisualStudio.2022.BuildTools",
        "rustup" => "Rustlang.Rustup",
        other => panic!("winget でない名前: {other}"),
    }
}

fn spec_of(name: &str) -> &'static winget::WingetSpec {
    SPECS.iter().find(|s| s.name == name).unwrap()
}

/// ps1 の作り物 (本物と同じく BOM 付きで、param の頭に固定した版、関数の中に ID の変数)
fn ps1_text(params: &[(&str, &str)], ids: &[(&str, &str)]) -> String {
    let mut s = "\u{feff}<#\n.SYNOPSIS\n作り物\n#>\n[CmdletBinding()]\nparam(\n".to_string();
    for (p, v) in params {
        s.push_str(&format!("    [string]${p} = '{v}',\n"));
    }
    s.push_str("    [switch]$Check\n)\n\nfunction Get-Ids {\n");
    for (var, id) in ids {
        s.push_str(&format!("    ${var} = '{id}'\n"));
    }
    s.push_str("}\n");
    s
}

fn releases_json(app: &str, core: &str, generation: &str) -> String {
    let sha = |c: char| c.to_string().repeat(64);
    format!(
        "{{\n  \"comment\": \"作り物\",\n  \"app\": {{\"version\": \"{app}\", \"sha256\": {{\"windows-x86_64\": \"{}\"}}}},\n  \"core\": {{\"version\": \"{core}\", \"generation\": {generation}, \"sha256\": {{\"linux-aarch64\": \"{}\", \"linux-x86_64\": \"{}\", \"windows-x86_64\": \"{}\"}}}}\n}}\n",
        sha('a'),
        sha('b'),
        sha('c'),
        sha('d')
    )
}

/// `base` に作り物の repo のファイル (ps1・releases.json) を書く (見送りの一覧は無い)。
fn write_repo(base: &Path) {
    let write = |rel: &str, text: &str| {
        let p = crate::context::join_segments(base, rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    };
    for s in SPECS
        .iter()
        .filter(|s| !s.ps1.starts_with("win/bootstrap/"))
    {
        write(
            s.ps1,
            &ps1_text(
                &[(s.version_param, pinned_of(s.name))],
                &[(s.id_var, id_of(s.name))],
            ),
        );
    }
    let boot: Vec<&winget::WingetSpec> = SPECS
        .iter()
        .filter(|s| s.ps1.starts_with("win/bootstrap/"))
        .collect();
    let params: Vec<(&str, &str)> = boot
        .iter()
        .map(|s| (s.version_param, pinned_of(s.name)))
        .collect();
    let ids: Vec<(&str, &str)> = boot.iter().map(|s| (s.id_var, id_of(s.name))).collect();
    write(
        "win/bootstrap/Install-Bootstrap.ps1",
        &ps1_text(&params, &ids),
    );
    write(
        "nix/pkgs/herdr-core/releases.json",
        &releases_json(pinned_of("herdr-app"), pinned_of("herdr-core"), "1"),
    );
}

/// 偽の gh・curl の 1 つの答え
#[derive(Clone, Debug)]
struct Answer {
    exit: Exit,
    out: Vec<String>,
    err: Vec<String>,
}

impl Answer {
    fn ok(out: &[&str]) -> Answer {
        Answer {
            exit: Exit::Code(0),
            out: out.iter().map(|s| s.to_string()).collect(),
            err: Vec::new(),
        }
    }

    fn fail(code: i32, out: &[&str], err: &[&str]) -> Answer {
        Answer {
            exit: Exit::Code(code),
            out: out.iter().map(|s| s.to_string()).collect(),
            err: err.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn timed_out() -> Answer {
        Answer {
            exit: Exit::TimedOut,
            out: Vec::new(),
            err: Vec::new(),
        }
    }

    /// 本物の gh の 404 (本文を stdout、わけを stderr に)
    fn not_found() -> Answer {
        Answer::fail(
            1,
            &[r#"{"message":"Not Found","status":"404"}"#],
            &["gh: Not Found (HTTP 404)"],
        )
    }
}

/// winget-pkgs の contents の答え (`file:` で始まる名前はファイル)
fn dirs(names: &[&str]) -> Answer {
    let items: Vec<serde_json::Value> = names
        .iter()
        .map(|n| match n.strip_prefix("file:") {
            Some(f) => json!({"name": f, "path": format!("x/{f}"), "type": "file"}),
            None => json!({"name": n, "path": format!("x/{n}"), "type": "dir"}),
        })
        .collect();
    Answer::ok(&[&serde_json::Value::Array(items).to_string()])
}

/// curl -sSIL の答え (状態の行を並べる。redirect なら 301 の後ろに最後の状態)
fn head(codes: &[&str]) -> Answer {
    let mut out = Vec::new();
    for c in codes {
        out.push(format!("HTTP/2 {c}"));
        out.push("last-modified: Wed, 12 Nov 2026 03:04:05 GMT".to_string());
        out.push(String::new());
    }
    Answer {
        exit: Exit::Code(0),
        out,
        err: Vec::new(),
    }
}

/// 偽の GitHub と releases.herdr.dev の答え
#[derive(Clone, Default)]
struct Net {
    no_login: bool,
    /// manifest のディレクトリ → contents の答え (無ければ 404)
    contents: BTreeMap<String, Answer>,
    /// repo (owner/name) → tags の答え (無ければ 404)
    tags: BTreeMap<String, Answer>,
    /// URL → HEAD の答え (無ければ 200)
    heads: BTreeMap<String, Answer>,
}

impl Net {
    fn answer(&self, c: &CommandSpec) -> Answer {
        let args = c.args_lossy();
        let a: Vec<&str> = args.iter().map(String::as_str).collect();
        match (c.program.to_string_lossy().as_ref(), a.as_slice()) {
            (GH, ["auth", "token"]) => {
                if self.no_login {
                    Answer::fail(1, &[], &["no oauth token found for github.com"])
                } else {
                    Answer::ok(&["gho_fake"])
                }
            }
            (GH, ["api", ep]) if ep.starts_with(CONTENTS) => self
                .contents
                .get(&ep[CONTENTS.len()..])
                .cloned()
                .unwrap_or_else(Answer::not_found),
            (GH, ["api", "--paginate", ep, "--jq", ".[].name"]) => {
                let repo = ep
                    .strip_prefix("repos/")
                    .and_then(|r| r.strip_suffix("/tags?per_page=100"))
                    .unwrap_or_else(|| panic!("知らない tags: {ep}"));
                self.tags
                    .get(repo)
                    .cloned()
                    .unwrap_or_else(Answer::not_found)
            }
            (CURL, ["-sSIL", "--max-time", "60", url]) => self
                .heads
                .get(*url)
                .cloned()
                .unwrap_or_else(|| head(&["200"])),
            (p, a) => panic!("知らないコマンド: {p} {a:?}"),
        }
    }

    /// この答えを返す偽の口 (stderr の行は印を付ける)
    fn sys(&self) -> FakeSys {
        let net = self.clone();
        FakeSys::new(move |c| {
            let a = net.answer(c);
            let mut output = a.out.clone();
            output.extend(a.err.iter().map(|e| stderr_line(e)));
            RunResult {
                exit: a.exit,
                output,
            }
        })
    }
}

/// 作り物の Windows と repo と GitHub。
struct World {
    t: TempDir,
    host: String,
    env: Vec<(String, String)>,
    no_gh: bool,
    no_curl: bool,
    net: Net,
}

/// 流した結果
struct Ran {
    outcomes: Vec<Outcome>,
    /// 手順の出力の行
    out: Vec<String>,
    /// 打ったコマンド (`gh …`・`curl …`)
    calls: Vec<String>,
    specs: Vec<CommandSpec>,
}

impl World {
    /// グループ minimum に Claude Code・herdr・ntn を足したホスト (tailscale は off)・bootstrap の clone は無い・どの名前も固定した版が最新
    fn new() -> World {
        let t = TempDir::new("pin-updates");
        write_repo(&t.path().join("repo"));
        std::fs::create_dir_all(t.path().join("home")).unwrap();
        let mut w = World {
            t,
            host: "group = \"minimum\"\n[tools]\nwindowsClaudeCode = true\nwindowsHerdr = true\nwindowsNtn = true\n"
                .to_string(),
            env: Vec::new(),
            no_gh: false,
            no_curl: false,
            net: Net::default(),
        };
        for s in SPECS {
            w.set_contents(s.name, dirs(&[pinned_of(s.name)]));
        }
        w.set_tags("herdr-app", &[&format!("v{}", pinned_of("herdr-app"))]);
        w.set_tags("herdr-core", &[&format!("v{}", pinned_of("herdr-core"))]);
        w
    }

    fn set_contents(&mut self, name: &str, a: Answer) {
        self.net.contents.insert(manifest_dir(id_of(name)), a);
    }

    fn set_tags(&mut self, name: &str, names: &[&str]) {
        self.net
            .tags
            .insert(format!("herdrdev/{name}"), Answer::ok(names));
    }

    fn set_head(&mut self, url: String, a: Answer) {
        self.net.heads.insert(url, a);
    }

    fn ctx_parts(&self) -> (PathBuf, Roots, PathBuf, crate::host::HostValues) {
        let groups = Groups::embedded().unwrap();
        (
            self.t.path().join("repo"),
            Roots::from_home(&self.t.path().join("home")),
            self.t.path().join("state"),
            parse(&self.host, Path::new("h.toml"), groups).unwrap(),
        )
    }

    fn write(&self, rel: &str, text: &str) {
        self.t.write(&format!("repo/{rel}"), text);
    }

    /// Windows の ghq に dotfiles の clone を置く (bootstrap を流した)
    fn bootstrapped(&self) {
        std::fs::create_dir_all(
            self.t
                .path()
                .join("home")
                .join("ghq")
                .join("github.com")
                .join("pollenjp")
                .join("dotfiles")
                .join(".git"),
        )
        .unwrap();
    }

    fn run(&self, mode: Mode) -> Ran {
        let mut sys = self.net.sys();
        if !self.no_gh {
            sys = sys.with_program("gh", GH);
        }
        if !self.no_curl {
            sys = sys.with_program("curl", CURL);
        }
        for (k, v) in &self.env {
            sys = sys.with_env(k, v);
        }
        let (repo, roots, state_dir, host) = self.ctx_parts();
        let mut out = Vec::new();
        let outcomes = {
            let mut ctx = Ctx {
                repo,
                roots,
                state_dir,
                host,
                sys: &sys,
                out: &mut out,
            };
            PinUpdates.run(&mut ctx, mode)
        };
        assert!(
            !self.t.path().join("state").exists(),
            "記録の置き場に何も書かない"
        );
        let specs = sys.calls.borrow().clone();
        let calls = specs
            .iter()
            .map(|c| {
                let p = c.program.to_string_lossy();
                let name = if p == GH { "gh" } else { "curl" };
                format!("{name} {}", c.args_lossy().join(" "))
            })
            .collect();
        Ran {
            outcomes,
            out: String::from_utf8(out)
                .unwrap()
                .lines()
                .map(str::to_string)
                .collect(),
            calls,
            specs,
        }
    }
}

fn contents_call(name: &str) -> String {
    format!("gh api {CONTENTS}{}", manifest_dir(id_of(name)))
}

fn tags_call(name: &str) -> String {
    format!("gh api --paginate repos/herdrdev/{name}/tags?per_page=100 --jq .[].name")
}

fn head_call(kind: &str, version: &str) -> String {
    format!("curl -sSIL --max-time 60 {}", artifact_url(kind, version))
}

fn rows(outcomes: &[Outcome]) -> Vec<crate::report::Row> {
    outcomes
        .iter()
        .map(|o| crate::report::Row::new(Some(97), "pin-updates", o.kind, o.text.clone()))
        .collect()
}

// ------------------------------------------------------------------ gh が無い・ログインしていない

/// gh が無い・ログインしていないなら、確かめられないと 1 行出して manual (名前は確かめない)。SSH の会話なら見込みを添える
#[test]
fn gh_missing_or_not_logged_in_checks_nothing() {
    let mut w = World::new();
    w.no_gh = true;
    let r = w.run(CHECK);
    assert_eq!(r.out, vec![format!("!! {NO_GH}")]);
    assert!(r.calls.is_empty());
    assert_eq!(r.outcomes.len(), 1);
    assert_eq!(r.outcomes[0].kind, Kind::Manual);
    assert!(r.outcomes[0].text.contains("gh が見つからない"));

    let mut w = World::new();
    w.net.no_login = true;
    let r = w.run(CHECK);
    assert_eq!(r.out, vec![format!("!! {NOT_LOGGED_IN}")]);
    assert_eq!(r.calls, vec!["gh auth token"]);
    assert_eq!(r.outcomes[0].kind, Kind::Manual);
    assert!(r.outcomes[0].text.contains("gh にログインしていない"));
    assert!(!r.outcomes[0].notes.iter().any(|n| n.contains("SSH")));

    w.env
        .push(("SSH_CONNECTION".into(), "10.0.0.1 50000 10.0.0.2 22".into()));
    let r = w.run(CHECK);
    assert_eq!(r.outcomes[0].kind, Kind::Manual);
    assert!(r.outcomes[0].notes.iter().any(|n| n == SSH_NOTE));
}

/// gh auth token の出力 (token) は流す口にも出力にも出さない。stdout だけを取り、30 秒で打ち切る
#[test]
fn token_never_reaches_the_output() {
    let w = World::new();
    let r = w.run(CHECK);
    assert!(!r.out.join("\n").contains("gho_fake"));
    assert!(
        r.outcomes.iter().all(
            |o| !o.text.contains("gho_fake") && o.notes.iter().all(|n| !n.contains("gho_fake"))
        )
    );
    // token (stdout) は写しに取らない
    let auth = &r.specs[0];
    assert_eq!(auth.args_lossy(), vec!["auth", "token"]);
    assert!(auth.stderr_only && !auth.stdout_only);
    assert_eq!(auth.timeout, Some(Duration::from_secs(30)));
}

/// gh api と curl は、名前ごとの上限 (WSL の timeout 60) の残りまでしか待たない。上限を過ぎていれば打たずに「60 秒で返らなかった」
#[test]
fn every_call_waits_at_most_the_wsl_limit() {
    let mut w = World::new();
    w.set_tags("herdr-app", &["v0.1.15", "v0.1.16"]);
    w.set_tags("herdr-core", &["v0.1.21", "v0.1.22"]);
    let r = w.run(CHECK);
    let limit = Duration::from_secs(LIMIT_SECS);
    assert_eq!(LIMIT_SECS, 60);
    let net: Vec<&CommandSpec> = r.specs.iter().skip(1).collect();
    assert_eq!(net.len(), 5 + 2 + 2, "{:?}", r.calls);
    for c in net {
        let t = c
            .timeout
            .unwrap_or_else(|| panic!("待つ上限が無い: {:?}", c.args_lossy()));
        assert!(
            t <= limit && t > limit - Duration::from_secs(10),
            "{t:?}: {:?}",
            c.args_lossy()
        );
    }
    // 上限を過ぎていれば打たない
    let sys = w.net.sys();
    let (repo, roots, state_dir, host) = w.ctx_parts();
    let mut out = Vec::new();
    let ctx = Ctx {
        repo,
        roots,
        state_dir,
        host,
        sys: &sys,
        out: &mut out,
    };
    let past = std::time::Instant::now();
    assert_eq!(
        winget::check(&ctx, Path::new(GH), spec_of("ntn"), past).unwrap_err(),
        vec!["60 秒で返らなかった"]
    );
    assert_eq!(
        herdr::check(&ctx, Path::new(GH), Some(Path::new(CURL)), past).unwrap_err(),
        vec!["60 秒で返らなかった"]
    );
    assert!(sys.calls.borrow().is_empty());
}

// ------------------------------------------------------------------ 新しい版

/// 新しい版があれば名前ごとに 1 行 (4 つ以上は頭と末尾と個数)。行は · で、終了コードに数えない。出た日は引かず、herdr-app と herdr-core は 1 回で読む
#[test]
fn reports_newer_versions_per_name() {
    let mut w = World::new();
    w.set_contents("herdr", dirs(&["0.9.5", "0.9.6"]));
    w.set_contents(
        "claude-code",
        dirs(&[
            "2.1.318", "2.1.321", "2.1.322", "2.1.323", "2.1.325", "2.1.330",
        ]),
    );
    w.set_tags("herdr-core", &["v0.1.21", "v0.1.22"]);
    let r = w.run(CHECK);
    assert_eq!(
        r.out,
        vec![
            format!("!! {HEADING}"),
            "   Windows の herdr: 0.9.5 → 0.9.6".to_string(),
            "   Windows の Claude Code: 2.1.318 → 2.1.321・…・2.1.330 (新しい版 5 個)".to_string(),
            "   herdr-core: 0.1.21 → 0.1.22".to_string(),
        ]
    );
    assert_eq!(r.outcomes.len(), 1);
    assert_eq!(r.outcomes[0].kind, Kind::Info);
    assert_eq!(r.outcomes[0].text, HEADING);
    assert_eq!(
        r.outcomes[0].notes,
        vec![
            "Windows の herdr: 0.9.5 → 0.9.6",
            "Windows の Claude Code: 2.1.318 → 2.1.321・…・2.1.330 (新しい版 5 個)",
            "herdr-core: 0.1.21 → 0.1.22",
        ]
    );
    assert_eq!(crate::report::exit_code(&rows(&r.outcomes)), 0);
    assert_eq!(
        r.calls,
        vec![
            "gh auth token".to_string(),
            contents_call("openssh"),
            contents_call("herdr"),
            contents_call("google-japanese-input"),
            contents_call("ntn"),
            contents_call("claude-code"),
            tags_call("herdr-app"),
            tags_call("herdr-core"),
            head_call("core", "0.1.22"),
        ]
    );
    // 3 つまでは並べ、4 つからは頭と末尾と個数
    let mut w = World::new();
    w.set_contents("ntn", dirs(&["0.23.28", "0.23.29", "0.23.30", "0.23.31"]));
    w.set_contents(
        "openssh",
        dirs(&["10.1.0.0", "10.1.0.1", "10.1.0.2", "10.1.0.3", "10.1.0.4"]),
    );
    let r = w.run(CHECK);
    assert_eq!(
        r.out[1],
        "   Windows の OpenSSH: 10.1.0.0 → 10.1.0.1・…・10.1.0.4 (新しい版 4 個)"
    );
    assert_eq!(
        r.out[2],
        "   Windows の ntn: 0.23.28 → 0.23.29・0.23.30・0.23.31"
    );
}

/// herdr-app に見送っていない新しい版があれば、続きの行の末尾 (ほかの名前の行より後ろ) に keys.json の注意を 2 行。herdr-core だけ・herdr-app は
/// 見送った版だけ・windowsHerdr が false なら添えない
#[test]
fn keys_json_note_follows_only_a_herdr_app_update() {
    let mut w = World::new();
    w.set_contents("openssh", dirs(&["10.1.0.0", "10.2.0.0"]));
    w.set_tags("herdr-app", &["v0.1.15", "v0.1.16"]);
    w.set_tags("herdr-core", &["v0.1.21", "v0.1.22"]);
    let r = w.run(CHECK);
    assert_eq!(
        r.out,
        vec![
            format!("!! {HEADING}"),
            "   Windows の OpenSSH: 10.1.0.0 → 10.2.0.0".to_string(),
            "   Windows の herdr-app: 0.1.15 → 0.1.16".to_string(),
            "   herdr-core: 0.1.21 → 0.1.22".to_string(),
            format!("   {}", KEYS_NOTE[0]),
            format!("   {}", KEYS_NOTE[1]),
        ]
    );
    let notes = &r.outcomes[0].notes;
    assert_eq!(notes.len(), 5);
    assert!(notes[3].starts_with("herdr-app を上げるなら、新しい既定のキーも足す"));
    assert!(notes[4].starts_with("→ 上げる版までの更新ノート"));

    // herdr-core だけ・herdr-app は見送った版だけ
    let mut w = World::new();
    w.set_tags("herdr-core", &["v0.1.21", "v0.1.22"]);
    w.write(
        herdr::SKIPPED_REL,
        "# 見送った版\napp 0.1.16 設定が読めなかった\n",
    );
    w.set_tags("herdr-app", &["v0.1.15", "v0.1.16"]);
    let r = w.run(CHECK);
    assert_eq!(r.out.last().unwrap(), "   herdr-core: 0.1.21 → 0.1.22");
    assert!(!r.out.join("\n").contains("keys.json"));
    // 見送った版は HEAD を打たない
    assert!(!r.calls.contains(&head_call("app", "0.1.16")));
    assert!(r.calls.contains(&head_call("core", "0.1.22")));

    // windowsHerdr が false なら herdr・herdr-app・herdr-core を確かめない (ntn・Claude Code は確かめる)
    let mut w = World::new();
    w.host =
        "[tools]\nwindowsHerdr = false\nwindowsClaudeCode = true\nwindowsNtn = true\n".to_string();
    w.set_contents("openssh", dirs(&["10.1.0.0", "10.2.0.0"]));
    w.set_tags("herdr-app", &["v0.1.15", "v0.1.16"]);
    let r = w.run(CHECK);
    assert_eq!(
        r.out,
        vec![
            format!("!! {HEADING}"),
            "   Windows の OpenSSH: 10.1.0.0 → 10.2.0.0".to_string(),
        ]
    );
    assert!(
        r.calls.iter().all(|c| !c.contains("herdr")),
        "{:?}",
        r.calls
    );
}

/// 新しい版が無い・見送った版だけなら「無い」の 1 行で ✔
#[test]
fn nothing_newer_is_ok() {
    let mut w = World::new();
    w.set_contents("herdr", dirs(&["0.9.5", "0.9.6"]));
    w.write(
        "win/herdr/skipped-versions.txt",
        "0.9.6 試したら設定が読めなかった\n",
    );
    let r = w.run(CHECK);
    assert_eq!(
        r.out,
        vec![format!(
            "{NONE_PREFIX}openssh・herdr・google-japanese-input・ntn・claude-code・herdr-app・herdr-core)。"
        )]
    );
    assert_eq!(r.outcomes.len(), 1);
    assert_eq!(r.outcomes[0].kind, Kind::Ok);
    assert_eq!(
        r.outcomes[0].text,
        "固定した版より新しい版は無い (見送った版を除く。7 個を確かめた)"
    );
}

// ------------------------------------------------------------------ 名前の on/off

/// ntn・Claude Code は windowsNtn・windowsClaudeCode が false なら確かめない。tailscale は windowsTailscale が true のときだけ。bootstrap の 4 つと
/// ghq・fzf・starship は Windows の ghq に dotfiles の clone があるときだけ
#[test]
fn names_follow_the_host_switches() {
    let checked = |w: &World| -> Vec<String> {
        w.run(CHECK)
            .calls
            .into_iter()
            .filter(|c| c.starts_with("gh api") && c.contains(CONTENTS))
            .collect()
    };
    let mut w = World::new();
    w.host =
        "[tools]\nwindowsNtn = false\nwindowsClaudeCode = false\nwindowsHerdr = true\n".to_string();
    assert_eq!(
        checked(&w),
        vec![
            contents_call("openssh"),
            contents_call("herdr"),
            contents_call("google-japanese-input"),
        ]
    );
    w.host = "[tools]\nwindowsTailscale = true\nwindowsClaudeCode = true\nwindowsHerdr = true\nwindowsNtn = true\n"
        .to_string();
    w.bootstrapped();
    assert_eq!(
        checked(&w),
        SPECS
            .iter()
            .map(|s| contents_call(s.name))
            .collect::<Vec<_>>()
    );
    // グループ minimum のまま (道具を足さない) なら、herdr も ntn も Claude Code も入れない
    let mut w = World::new();
    w.host = "group = \"minimum\"\n".to_string();
    assert_eq!(
        checked(&w),
        vec![
            contents_call("openssh"),
            contents_call("google-japanese-input"),
        ]
    );
    assert_eq!(selected_of(&w), vec!["openssh", "google-japanese-input"]);
}

fn selected_of(w: &World) -> Vec<&'static str> {
    let sys = FakeSys::new(|_| unreachable!());
    let (repo, roots, state_dir, host) = w.ctx_parts();
    let mut out = Vec::new();
    let ctx = Ctx {
        repo,
        roots,
        state_dir,
        host,
        sys: &sys,
        out: &mut out,
    };
    selected(&ctx)
}

/// 名前の on/off の switch は、同じものを入れる手順 (ps1 の手順) の gate と同じ
#[test]
fn name_switches_match_the_install_steps() {
    for (name, step) in [
        ("herdr", "herdr"),
        ("ntn", "ntn"),
        ("claude-code", "claude-code"),
        ("tailscale", "tailscale"),
        ("herdr-app", "herdr-app"),
        ("herdr-core", "herdr-app"),
    ] {
        let gate = crate::steps::ps1::SPECS
            .iter()
            .find(|s| s.id == step)
            .unwrap_or_else(|| panic!("{step} の手順が無い"))
            .gate;
        match (name_gate(name), gate) {
            (NameGate::Tool(a), Gate::Tool(b)) => assert_eq!(a, b, "{name}"),
            other => panic!("{name}: {other:?}"),
        }
    }
    for name in ["openssh", "google-japanese-input"] {
        assert_eq!(name_gate(name), NameGate::Always);
    }
    for name in ["git", "gh", "pwsh", "vs-buildtools", "rustup"] {
        assert_eq!(name_gate(name), NameGate::Bootstrapped);
    }
    // ghq・fzf・starship を入れる手順はいつも on の Windows にしか無い手順で、bootstrap が clone した dotfiles の runner が流す。知らせるのも、bootstrap の
    // 4 つと同じく clone があるときだけ (WSL の setup も同じ)
    for name in ["ghq", "fzf", "starship"] {
        let step = crate::steps::ps1::SPECS
            .iter()
            .find(|s| s.id == name)
            .unwrap_or_else(|| panic!("{name} の手順が無い"));
        assert_eq!(step.gate, Gate::Always, "{name}");
        assert!(step.windows_only, "{name}");
        assert_eq!(name_gate(name), NameGate::Bootstrapped, "{name}");
    }
}

// ------------------------------------------------------------------ 確かめられない

/// 確かめられない名前は、わけ (最初の名前のもの) を添えて 1 行出して failed。ほかの名前の新しい版は知らせる
#[test]
fn unreadable_names_are_failed_with_the_first_reason() {
    let mut w = World::new();
    w.set_contents(
        "openssh",
        Answer::fail(
            1,
            &[r#"{"message":"API rate limit exceeded"}"#],
            &[
                "gh: API rate limit exceeded for user ID 1. (HTTP 403)",
                "second line",
            ],
        ),
    );
    w.set_contents("ntn", Answer::ok(&["not json"]));
    w.set_contents("herdr", dirs(&["0.9.5", "0.9.6"]));
    let r = w.run(CHECK);
    let failed = format!(
        "!! {FAILED_PREFIX}openssh・ntn (winget-pkgs の manifests/m/Microsoft/OpenSSH/Preview を読めませんでした (gh api repos/microsoft/winget-pkgs/contents/manifests/m/Microsoft/OpenSSH/Preview): / gh: API rate limit exceeded for user ID 1. (HTTP 403))。"
    );
    assert_eq!(
        r.out,
        vec![
            format!("!! {HEADING}"),
            "   Windows の herdr: 0.9.5 → 0.9.6".to_string(),
            failed,
        ]
    );
    assert_eq!(r.outcomes.len(), 2);
    assert_eq!(r.outcomes[0].kind, Kind::Info);
    assert_eq!(r.outcomes[1].kind, Kind::Failed);
    assert_eq!(
        r.outcomes[1].text,
        "固定した版より新しい版があるかを確かめられなかったもの: openssh・ntn"
    );
    assert!(r.outcomes[1].notes[1].starts_with(
        "ntn: winget-pkgs の応答が読めませんでした (ディレクトリの一覧ではない): / not json"
    ));
    assert_eq!(crate::report::exit_code(&rows(&r.outcomes)), 1);
}

/// わけの文 (WSL の check-winget-version.sh と同じ): 404 はパッケージが無い・版のディレクトリが無い (herdr の Preview だけも)・上限を過ぎた・gh の stderr が
/// 空・応答の頭の 300 バイト
#[test]
fn winget_trouble_reasons() {
    let reason = |name: &str, a: Answer| -> String {
        let mut w = World::new();
        w.set_contents(name, a);
        let r = w.run(CHECK);
        let f = r
            .outcomes
            .iter()
            .find(|o| o.kind == Kind::Failed)
            .unwrap_or_else(|| panic!("{name}: {:?}", r.out));
        f.notes[0].clone()
    };
    assert_eq!(
        reason("claude-code", Answer::not_found()),
        "claude-code: Anthropic.ClaudeCode が winget-pkgs に無い (manifests/a/Anthropic/ClaudeCode が無い)。新しい版を出せない"
    );
    assert_eq!(
        reason("ntn", dirs(&["file:a.yaml"])),
        "ntn: Notion.ntn が winget-pkgs に無い (manifests/n/Notion/ntn に版のディレクトリが無い)。新しい版を出せない"
    );
    assert_eq!(
        reason("herdr", dirs(&["Preview"])),
        "herdr: Herdr.Herdr が winget-pkgs に無い (manifests/h/Herdr/Herdr に版のディレクトリが無い)。新しい版を出せない"
    );
    assert_eq!(
        reason("openssh", Answer::timed_out()),
        "openssh: 60 秒で返らなかった"
    );
    assert_eq!(
        reason("openssh", Answer::fail(1, &[], &[])),
        "openssh: winget-pkgs の manifests/m/Microsoft/OpenSSH/Preview を読めませんでした (gh api repos/microsoft/winget-pkgs/contents/manifests/m/Microsoft/OpenSSH/Preview):"
    );
    let long = format!("[{}", "x".repeat(400));
    assert_eq!(
        reason("openssh", Answer::ok(&[&long])),
        format!(
            "openssh: winget-pkgs の応答が読めませんでした (ディレクトリの一覧ではない): / [{}",
            "x".repeat(299)
        )
    );
    // object の一覧の要素でない (jq のエラー)・一覧でない
    assert!(reason("openssh", Answer::ok(&["[1]"])).contains("ディレクトリの一覧ではない"));
    assert!(reason("openssh", Answer::ok(&[r#"{"a":1}"#])).contains("ディレクトリの一覧ではない"));
}

/// ps1 と見送りの一覧の誤りは、gh を呼ばずに確かめられない (WSL と同じ文)
#[test]
fn ps1_and_skip_list_troubles() {
    let first_reason = |w: &World| -> (String, Vec<String>) {
        let r = w.run(CHECK);
        let f = r.outcomes.iter().find(|o| o.kind == Kind::Failed).unwrap();
        (f.notes[0].clone(), r.calls)
    };
    let w = World::new();
    std::fs::remove_file(w.t.path().join("repo/win/ntn/Install-Ntn.ps1")).unwrap();
    let (why, calls) = first_reason(&w);
    assert_eq!(
        why,
        "ntn: Install-Ntn.ps1 が読めません: win/ntn/Install-Ntn.ps1"
    );
    assert!(!calls.contains(&contents_call("ntn")));

    w.write("win/ntn/Install-Ntn.ps1", "$packageId = 'Notion.ntn'\n");
    assert_eq!(
        first_reason(&w).0,
        "ntn: 固定した版が読めません: win/ntn/Install-Ntn.ps1 に [string]$Version = '<版>' の行がありません。"
    );
    w.write(
        "win/ntn/Install-Ntn.ps1",
        "[string]$Version = '0.23'\n$packageId = 'Notion.ntn'\n",
    );
    assert_eq!(
        first_reason(&w).0,
        "ntn: 固定した版が読めません: win/ntn/Install-Ntn.ps1 の -Version の既定値 '0.23' が Windows の ntn の版の形ではありません (例: 0.23.28)。"
    );
    w.write("win/ntn/Install-Ntn.ps1", "[string]$Version = '0.23.28'\n");
    assert_eq!(
        first_reason(&w).0,
        "ntn: パッケージ ID が読めません: win/ntn/Install-Ntn.ps1 に $packageId = '<ID>' の行がありません。"
    );
    // tailscale の固定した版は X.Y.Z だけ (winget-pkgs の版は 4 つ区切りも読む)
    let mut w = World::new();
    w.host = "[tools]\nwindowsTailscale = true\n".to_string();
    w.write(
        "win/tailscale/Install-Tailscale.ps1",
        &ps1_text(
            &[("Version", "1.104.5.0")],
            &[("packageId", "Tailscale.Tailscale")],
        ),
    );
    assert_eq!(
        first_reason(&w).0,
        "tailscale: 固定した版が読めません: win/tailscale/Install-Tailscale.ps1 の -Version の既定値 '1.104.5.0' が Windows の Tailscale の版の形ではありません (例: 1.104.5)。"
    );
    // 見送りの一覧の書き損じ (理由が無い・版の形でない)
    let w = World::new();
    w.write("win/herdr/skipped-versions.txt", "# 注釈\n\n0.9.6\n");
    let (why, calls) = first_reason(&w);
    assert_eq!(
        why,
        "herdr: 見送りの一覧の 3 行目が読めません (win/herdr/skipped-versions.txt): 0.9.6 / 1 行に「版 理由」を空白で区切って書く。版は Windows の herdr の版の形 (例: 0.9.5 試したら設定が読めなかった)。"
    );
    assert!(!calls.contains(&contents_call("herdr")));
    w.write("win/herdr/skipped-versions.txt", "preview-1 速すぎた\n");
    assert!(first_reason(&w).0.starts_with(
        "herdr: 見送りの一覧の 1 行目が読めません (win/herdr/skipped-versions.txt): preview-1 速すぎた"
    ));
}

// ------------------------------------------------------------------ winget-pkgs の版

/// 固定した版より新しい版を sort -V の古い順に。版の形でないディレクトリ・ファイル・herdr の Preview は数えない。見送った版は理由つきで知らせない
#[test]
fn winget_versions_are_ordered_and_filtered() {
    let mut w = World::new();
    w.set_contents(
        "herdr",
        dirs(&[
            "0.10.0",
            "0.9.5",
            "Preview",
            "0.9.10",
            "0.9.6",
            "odd",
            "file:0.9.7",
            "0.9.4",
        ]),
    );
    w.set_contents(
        "openssh",
        dirs(&["10.1.0.0", "9.8.3.0", "10.1.0.1", "10.2", "10.1.0.0.1"]),
    );
    let r = w.run(CHECK);
    assert_eq!(r.out[1], "   Windows の OpenSSH: 10.1.0.0 → 10.1.0.1・10.2");
    assert_eq!(
        r.out[2],
        "   Windows の herdr: 0.9.5 → 0.9.6・0.9.10・0.10.0"
    );
    // 見送りの一覧: BOM・CRLF・注釈と空行・前後の空白。同じ版は初めの行の理由
    let w2 = World::new();
    w2.write(
        "win/herdr/skipped-versions.txt",
        "\u{feff}# 見送った版\r\n\r\n  0.9.6   試したら  設定が読めなかった \r\n0.9.6 後の行\r\n",
    );
    let mut w2 = w2;
    w2.set_contents("herdr", dirs(&["0.9.5", "0.9.6", "0.9.7"]));
    let found = found_of(&w2, "herdr");
    assert_eq!(
        found.newer,
        vec![
            Newer {
                version: "0.9.6".into(),
                skipped: Some("試したら  設定が読めなかった".into())
            },
            Newer {
                version: "0.9.7".into(),
                skipped: None
            },
        ]
    );
    assert_eq!(found.line().unwrap(), "Windows の herdr: 0.9.5 → 0.9.7");
}

/// 候補の線を決めた名前 (pwsh の 7.6 の線) は、その線の版だけを新しい版にする (7.7 の版と Preview のディレクトリは数えない)
#[test]
fn series_limits_the_candidates() {
    let mut w = World::new();
    w.bootstrapped();
    w.set_contents(
        "pwsh",
        dirs(&[
            "7.6.9.0", "7.6.10.0", "7.7.0.0", "Preview", "7.6.11.0", "7.7.1.0",
        ]),
    );
    let found = found_of(&w, "pwsh");
    assert_eq!(found.title, "Windows の PowerShell 7");
    assert_eq!(found.pinned, "7.6.10.0");
    assert_eq!(
        found.newer,
        vec![Newer {
            version: "7.6.11.0".into(),
            skipped: None
        }]
    );
    assert_eq!(
        found.line().unwrap(),
        "Windows の PowerShell 7: 7.6.10.0 → 7.6.11.0"
    );
    // 7.6 の線に新しい版が無ければ、7.7 の版があっても知らせない
    let mut w = World::new();
    w.bootstrapped();
    w.set_contents("pwsh", dirs(&["7.6.10.0", "7.7.0.0", "Preview"]));
    assert!(found_of(&w, "pwsh").newer.is_empty());
}

/// 空白は C.UTF-8 の bash の [[:space:]] と同じに読む: 全角の空白などだけの行・その後ろの注釈は見送りの一覧で読み飛ばし、ps1 の行頭と `=` の前後も
/// 空白。改行しない空白 (U+00A0) は空白でない (書き損じの行)
#[test]
fn unicode_spaces_follow_bash_in_c_utf8() {
    let mut w = World::new();
    w.set_contents("herdr", dirs(&["0.9.5", "0.9.6", "0.9.7"]));
    w.write(
        "win/herdr/skipped-versions.txt",
        "\u{3000}\n\u{3000}# 全角の空白の後ろの注釈\n\u{2003}\u{205f}\t\n0.9.6 試したら設定が読めなかった\n",
    );
    w.write(
        herdr::SKIPPED_REL,
        "\u{3000}\n\u{2028}# 注釈\napp 0.1.16 窓が開かなかった\n",
    );
    w.set_tags("herdr-app", &["v0.1.15", "v0.1.16"]);
    w.write(
        "win/ntn/Install-Ntn.ps1",
        "\u{3000}[string]$Version\u{2003}=\u{3000}'0.23.28'\n\u{1680}$packageId = 'Notion.ntn'\n",
    );
    w.set_contents("ntn", dirs(&["0.23.28", "0.23.29"]));
    let r = w.run(CHECK);
    assert_eq!(
        r.out,
        vec![
            format!("!! {HEADING}"),
            "   Windows の herdr: 0.9.5 → 0.9.7".to_string(),
            "   Windows の ntn: 0.23.28 → 0.23.29".to_string(),
        ]
    );
    w.write("win/herdr/skipped-versions.txt", "\u{a0}\n");
    let r = w.run(CHECK);
    let failed = r.outcomes.iter().find(|o| o.kind == Kind::Failed).unwrap();
    assert!(failed.notes[0].starts_with(
        "herdr: 見送りの一覧の 1 行目が読めません (win/herdr/skipped-versions.txt): \u{a0}"
    ));
    // わけの行頭の空白も同じ
    assert_eq!(
        reason_of(&["!! \u{3000}a".into(), "\u{2003}b".into()]),
        "a / b"
    );
    for c in [
        '\u{a0}', '\u{2007}', '\u{202f}', '\u{85}', '\u{200b}', '\u{feff}',
    ] {
        assert!(!is_space(c), "{:04X}", c as u32);
    }
}

/// winget の 1 つの名前を確かめた結果 (手順を通さずに口を呼ぶ)
fn found_of(w: &World, name: &str) -> Found {
    let sys = w.net.sys();
    let (repo, roots, state_dir, host) = w.ctx_parts();
    let mut out = Vec::new();
    let ctx = Ctx {
        repo,
        roots,
        state_dir,
        host,
        sys: &sys,
        out: &mut out,
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(LIMIT_SECS);
    winget::check(&ctx, Path::new(GH), spec_of(name), deadline).unwrap()
}

// ------------------------------------------------------------------ herdr-app・herdr-core

/// tag の vX.Y.Z のうち新しい版で、Windows の成果物の HEAD が (redirect の先で) 404 の版は数えない。curl が落ちた・無いときは数える
#[test]
fn herdr_versions_follow_tags_and_artifacts() {
    let mut w = World::new();
    w.set_tags(
        "herdr-app",
        &[
            "v0.1.15",
            "v0.1.9",
            "preview-20261101-abc",
            "v0.1.16",
            "v0.1.17",
            "v0.1.18",
            "v0.1.20",
            "0.1.19",
            "v0.1.21-rc1",
        ],
    );
    w.set_head(artifact_url("app", "0.1.16"), head(&["404"]));
    w.set_head(artifact_url("app", "0.1.17"), head(&["302", "404"]));
    w.set_head(
        artifact_url("app", "0.1.18"),
        Answer::fail(
            6,
            &[],
            &["curl: (6) Could not resolve host: releases.herdr.dev"],
        ),
    );
    w.set_head(artifact_url("app", "0.1.20"), head(&["404", "200"]));
    let r = w.run(CHECK);
    assert_eq!(r.out[1], "   Windows の herdr-app: 0.1.15 → 0.1.18・0.1.20");
    assert_eq!(
        r.calls
            .iter()
            .filter(|c| c.starts_with("curl"))
            .cloned()
            .collect::<Vec<_>>(),
        vec![
            head_call("app", "0.1.16"),
            head_call("app", "0.1.17"),
            head_call("app", "0.1.18"),
            head_call("app", "0.1.20"),
        ]
    );
    // curl が無ければ版を入れる (404 か分からない)
    let mut w = World::new();
    w.no_curl = true;
    w.set_tags("herdr-core", &["v0.1.21", "v0.1.22"]);
    w.set_head(artifact_url("core", "0.1.22"), head(&["404"]));
    let r = w.run(CHECK);
    assert_eq!(r.out[1], "   herdr-core: 0.1.21 → 0.1.22");
    assert!(r.calls.iter().all(|c| !c.starts_with("curl")));
}

/// releases.json・見送りの一覧の誤りと、tag を読めない (gh の stderr が先) のは、herdr-app と herdr-core の 2 つとも確かめられない
#[test]
fn herdr_troubles_fail_both_components() {
    let failed = |w: &World| -> (Vec<String>, String) {
        let r = w.run(CHECK);
        let f = r
            .outcomes
            .iter()
            .find(|o| o.kind == Kind::Failed)
            .unwrap_or_else(|| panic!("{:?}", r.out));
        (f.notes.clone(), r.out.last().unwrap().clone())
    };
    let mut w = World::new();
    w.net
        .tags
        .insert("herdrdev/herdr-app".into(), Answer::not_found());
    let (notes, line) = failed(&w);
    let why = "gh: Not Found (HTTP 404) / 確かめられなかった: GitHub の herdrdev/herdr-app の tag を読めない (gh api repos/herdrdev/herdr-app/tags)";
    assert_eq!(notes[0], format!("herdr-app: {why}"));
    assert_eq!(notes[1], format!("herdr-core: {why}"));
    assert_eq!(
        line,
        format!("!! {FAILED_PREFIX}herdr-app・herdr-core ({why})。")
    );

    // core の tag だけ読めない: app で打った curl の stderr も、わけの頭に来る (WSL の口の stderr と同じ順)
    let mut w = World::new();
    w.set_tags("herdr-app", &["v0.1.15", "v0.1.16"]);
    w.set_head(
        artifact_url("app", "0.1.16"),
        Answer::fail(28, &[], &["curl: (28) Operation timed out"]),
    );
    w.net.tags.insert(
        "herdrdev/herdr-core".into(),
        Answer::fail(1, &[], &["gh: Bad credentials (HTTP 401)"]),
    );
    let (notes, _) = failed(&w);
    assert_eq!(
        notes[0],
        "herdr-app: curl: (28) Operation timed out / gh: Bad credentials (HTTP 401)"
    );

    let w = World::new();
    w.write(herdr::RELEASES_REL, "not json");
    let (notes, _) = failed(&w);
    let path =
        w.t.path()
            .join("repo")
            .join("nix")
            .join("pkgs")
            .join("herdr-core")
            .join("releases.json");
    assert_eq!(
        notes[0],
        format!(
            "herdr-app: releases.json が読めません (無い・JSON でない): {}",
            path.display()
        )
    );
    let w = World::new();
    w.write(
        herdr::RELEASES_REL,
        r#"{"app":{"version":"0.1","sha256":{"windows-x86_64":"x"}},"core":{"version":"0.1.21","generation":0,"sha256":{}}}"#,
    );
    let (notes, _) = failed(&w);
    assert!(notes[0].starts_with(
        "herdr-app: releases.json から固定した版と sha256 を読めません (app.version=0.1 core.generation=0 core.sha256.linux-aarch64= app.sha256.windows-x86_64=x core.sha256.windows-x86_64= core.sha256.linux-x86_64=): "
    ), "{}", notes[0]);
    let w = World::new();
    w.write(herdr::SKIPPED_REL, "app 0.1.16\n");
    let (notes, _) = failed(&w);
    assert_eq!(
        notes[0],
        "herdr-app: 確かめられなかった: 見送りの一覧の 1 行目が読めません (nix/pkgs/herdr-core/skipped-versions.txt): app 0.1.16 / 1 行に「app か core・版・理由」を空白で区切って書く (例: app 0.1.14 試したら窓が開かなかった)。"
    );
    // 上限を過ぎた (それまでに stderr に出た行が無ければ「60 秒で返らなかった」)
    let mut w = World::new();
    w.net
        .tags
        .insert("herdrdev/herdr-app".into(), Answer::timed_out());
    let (notes, _) = failed(&w);
    assert_eq!(notes[0], "herdr-app: 60 秒で返らなかった");
}

// ------------------------------------------------------------------ 流し方

/// check・dry-run・apply は同じことをして、何も書かない (World::run が記録の置き場を見る)
#[test]
fn every_mode_only_reads() {
    let mut w = World::new();
    w.set_contents("ntn", dirs(&["0.23.28", "0.23.29"]));
    let check = w.run(CHECK);
    for mode in [
        Mode::DryRun { force: false },
        Mode::DryRun { force: true },
        Mode::Apply { force: false },
        Mode::Apply { force: true },
    ] {
        let r = w.run(mode);
        assert_eq!(r.out, check.out, "{mode:?}");
        assert_eq!(r.calls, check.calls, "{mode:?}");
        assert_eq!(r.outcomes, check.outcomes, "{mode:?}");
    }
    let info = PinUpdates.info();
    assert_eq!(
        (
            info.id,
            info.order,
            info.gate,
            info.ported,
            info.windows_only
        ),
        ("pin-updates", 97, Gate::Tool("privateRepos"), true, false)
    );
}

// ------------------------------------------------------------------ 部品

#[test]
fn version_cmp_is_sort_v() {
    use std::cmp::Ordering::*;
    for (a, b, o) in [
        ("1.9", "1.10", Less),
        ("0.9.5", "0.10.0", Less),
        ("9.8.3.0", "10.0.0.0", Less),
        ("1.104.6", "1.104.6.0", Less),
        ("2.56.0.4", "2.56.1", Less),
        ("1.01", "1.1", Less),
        ("01.1", "1.001", Less),
        ("1.2.3", "1.2.3", Equal),
        ("1.0~rc1", "1.0", Less),
        ("1.0a", "1.0", Greater),
        ("a.tar.gz", "a.1.tar.gz", Less),
        ("", "1", Less),
        (".", "..", Less),
        (".a", "b", Less),
    ] {
        assert_eq!(version_cmp(a, b), o, "{a} {b}");
        assert_eq!(version_cmp(b, a), o.reverse(), "{b} {a}");
    }
    assert!(newer_than("0.10.0", "0.9.5"));
    assert!(!newer_than("0.9.5", "0.9.5"));
    assert!(!newer_than("0.9.4", "0.9.5"));
}

#[test]
fn bash_like_helpers() {
    assert_eq!(
        read_fields("  1.2.3 \t  a  b \t ", 2),
        vec!["1.2.3", "a  b"]
    );
    assert_eq!(read_fields("1.2.3", 2), vec!["1.2.3", ""]);
    assert_eq!(
        read_fields(" app  0.1.14   x y  ", 3),
        vec!["app", "0.1.14", "x y"]
    );
    assert_eq!(read_fields("app", 3), vec!["app", "", ""]);
    assert_eq!(read_lines("a\n\nb"), vec!["a", "", "b"]);
    assert_eq!(read_lines("a\r\n"), vec!["a\r"]);
    assert!(read_lines("").is_empty());
    assert_eq!(
        reason_of(&["!! a".into(), "   ".into(), "   b".into(), "c".into()]),
        "a / b"
    );
    assert_eq!(reason_of(&["x".into()]), "x");
    assert_eq!(
        pinned_value("    [string]$Version = '0.9.5',\r", "Version").as_deref(),
        Some("0.9.5")
    );
    assert_eq!(pinned_value("[string]$VersionX = '1'", "Version"), None);
    assert_eq!(pinned_value("[String]$Version = '1'", "Version"), None);
    assert_eq!(
        pinned_value("[string]$Version = ''", "Version").as_deref(),
        Some("")
    );
    assert_eq!(
        id_value("    $packageId = 'Herdr.Herdr'", "packageId").as_deref(),
        Some("Herdr.Herdr")
    );
    assert_eq!(id_value("$packageId = '.x'", "packageId"), None);
    assert_eq!(id_value("$packageId = 'a b'", "packageId"), None);
    assert_eq!(
        manifest_dir("Microsoft.VisualStudio.2022.BuildTools"),
        "manifests/m/Microsoft/VisualStudio/2022/BuildTools"
    );
    assert_eq!(
        final_status(&["HTTP/1.1 301 Moved".into(), "HTTP/2 404".into()]).as_deref(),
        Some("404")
    );
    assert_eq!(final_status(&["x".into()]), None);
    assert_eq!(title_of("herdr-core"), "herdr-core");
    assert_eq!(title_of("herdr-app"), "Windows の herdr-app");
}

/// run_split: 流す口に来た行から写しの行を順に除いたものが stderr
#[test]
fn run_split_separates_stderr() {
    let sys = FakeSys::new(|_| RunResult {
        exit: Exit::Code(1),
        output: vec!["body".into(), stderr_line("gh: x"), "body2".into()],
    });
    let mut out = Vec::new();
    let ctx = Ctx {
        repo: "/r".into(),
        roots: Roots::from_home(Path::new("/h")),
        state_dir: "/s".into(),
        host: parse("", Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
        sys: &sys,
        out: &mut out,
    };
    let s = run_split(&ctx, CommandSpec::new("gh"));
    assert_eq!(s.out, vec!["body", "body2"]);
    assert_eq!(s.err, vec!["gh: x"]);
    assert!(sys.calls.borrow()[0].stdout_only);
}

// ------------------------------------------------------------------ WSL の script の字

fn script_text(rel: &str) -> String {
    let p = crate::context::join_segments(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join(".."),
        rel,
    );
    // Windows の CI の checkout は CRLF になりうる
    std::fs::read_to_string(&p)
        .unwrap_or_else(|e| panic!("{}: {e}", p.display()))
        .replace("\r\n", "\n")
}

/// 知らせる文・名前の並びは WSL の bootstrap-windows-pin-updates.sh と同じ字
#[test]
fn notice_texts_match_the_wsl_script() {
    let s = script_text("nix/scripts/bootstrap-windows-pin-updates.sh");
    assert!(s.contains(&format!("all_names=({})", NAMES.join(" "))));
    assert!(s.contains(&format!("warn \"{HEADING}\" \\")));
    for note in KEYS_NOTE {
        assert!(s.contains(&format!("\"{note}\"")), "{note}");
    }
    assert!(s.contains(&format!("warn \"{NOT_LOGGED_IN}\"")));
    // gh が無いときは、直し方だけが違う
    let (head, _) = NO_GH.split_once("gh が見つからない。").unwrap();
    assert!(s.contains(&format!(
        "warn \"{head}gh が見つからない。home-manager switch の後に流し直す)。\""
    )));
    assert!(s.contains(&format!(
        "echo \"{NONE_PREFIX}$(printf '%s・' \"${{names[@]}}\" | sed 's/・$//'))。\""
    )));
    assert!(s.contains(&format!(
        "warn \"{FAILED_PREFIX}$(printf '%s・' \"${{failed[@]}}\" | sed 's/・$//') ($(reason_of \"${{failed[0]}}\"))。setup は続けます。\""
    )));
    // 1 行の形 (3 つまでは並べ、4 つ以上は頭と末尾と個数)・名前ごとの待つ上限・gh のログインの見方
    assert!(
        s.contains(r#"elif ($n | length) <= 3 then "\(.title): \(.pinned) → \($n | join("・"))""#)
    );
    assert!(s.contains(
        r#"else "\(.title): \(.pinned) → \($n[0])・…・\($n[-1]) (新しい版 \($n | length) 個)""#
    ));
    assert!(s.contains(&format!("if ! fetch \"${{name}}\" {LIMIT_SECS} 0; then")));
    assert!(s.contains("if ! gh auth token &>/dev/null; then"));
    assert!(s.contains("echo \"${limit} 秒で返らなかった\" >\"${tmp}/${name}.err\""));
    // 名前の on/off (WSL の記録の欄) と bootstrap の clone の場所
    assert!(s.contains("ntn) key=ntn ;;") && s.contains("claude-code) key=claudeCode ;;"));
    assert!(s.contains(
        "herdr | herdr-app | herdr-core)\n      [[ ${windows_herdr} != false ]] || continue"
    ));
    assert!(s.contains("tailscale)\n      [[ ${windows_tailscale} == true ]] || continue"));
    assert!(s.contains(
        "git | gh | pwsh | vs-buildtools | rustup | ghq | fzf | starship)\n      ((bootstrapped)) || continue"
    ));
    assert!(s.contains("${windows_home}/ghq/github.com/pollenjp/dotfiles/.git"));
    // reason_of は空でない最初の 2 行を「 / 」でつなぐ
    assert!(
        s.contains("line=${line#'!! '}")
            && s.contains("out+=\"${out:+ / }${line}\"")
            && s.contains("if ((n == 2)); then")
    );
}

/// 版の正規表現を、runner の欄の数にする
fn parts_of(re: &str) -> (usize, usize) {
    match re {
        r"^[0-9]+(\.[0-9]+){1,3}$" => (2, 4),
        r"^[0-9]+\.[0-9]+\.[0-9]+$" => (3, 3),
        r"^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$" => (3, 4),
        r"^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" => (4, 4),
        other => panic!("知らない版の形: {other} (runner の version_parts に写す)"),
    }
}

/// 名前ごとの題・ps1・見送りの一覧・param・変数・版の形・例・Preview は WSL の check-winget-version.sh と同じ
#[test]
fn winget_specs_match_the_wsl_script() {
    let s = script_text("nix/scripts/check-winget-version.sh");
    let start = s.find("case ${name} in\n").unwrap();
    let body = &s[start..s[start..].find("\nesac\n").unwrap() + start];
    let value = |block: &str, key: &str| -> Option<String> {
        block.lines().find_map(|l| {
            let l = l.trim();
            let v = l.strip_prefix(&format!("{key}="))?;
            Some(v.trim_matches('\'').to_string())
        })
    };
    for spec in SPECS {
        let open = format!("\n  {})\n", spec.name);
        let i = body
            .find(&open)
            .unwrap_or_else(|| panic!("{} の case が無い", spec.name));
        let block = &body[i + open.len()..];
        let block = &block[..block.find("\n    ;;").unwrap()];
        assert_eq!(
            value(block, "title").as_deref(),
            Some(spec.title),
            "{}",
            spec.name
        );
        let ps1_name = value(block, "ps1_name").unwrap();
        let ps1 = value(block, "ps1_rel")
            .map(|r| format!("win/{r}"))
            .unwrap_or_else(|| format!("win/{}/{ps1_name}", spec.name));
        assert_eq!(ps1, spec.ps1, "{}", spec.name);
        assert!(spec.ps1.ends_with(&ps1_name));
        let skipped = value(block, "skipped_rel")
            .map(|r| format!("win/{r}"))
            .unwrap_or_else(|| format!("win/{}/skipped-versions.txt", spec.name));
        assert_eq!(skipped, spec.skipped, "{}", spec.name);
        assert_eq!(
            value(block, "version_param").unwrap_or_else(|| "Version".into()),
            spec.version_param,
            "{}",
            spec.name
        );
        assert_eq!(
            value(block, "id_var").unwrap_or_else(|| "packageId".into()),
            spec.id_var,
            "{}",
            spec.name
        );
        assert_eq!(
            parts_of(&value(block, "version_re").unwrap()),
            spec.version_parts,
            "{}",
            spec.name
        );
        assert_eq!(
            value(block, "pinned_version_re").map(|r| parts_of(&r)),
            spec.pinned_parts,
            "{}",
            spec.name
        );
        assert_eq!(
            value(block, "version_example").as_deref(),
            Some(spec.version_example),
            "{}",
            spec.name
        );
        let nested: Vec<String> = value(block, "nested_dirs")
            .map(|v| {
                v.trim_start_matches('(')
                    .trim_end_matches(')')
                    .split_whitespace()
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        assert_eq!(nested, spec.nested_dirs, "{}", spec.name);
        // 候補の線は正規表現の `^7\.6\.` を頭の字の `7.6.` にしたもの
        let series =
            value(block, "series_re").map(|r| r.trim_start_matches('^').replace("\\.", "."));
        assert_eq!(series.as_deref(), spec.series, "{}", spec.name);
    }
    // case の名前は SPECS と同じ並び (WSL の all_names の winget の名前)
    let names: Vec<&str> = body
        .lines()
        .filter_map(|l| l.strip_prefix("  ")?.strip_suffix(')'))
        .filter(|n| !n.starts_with(' ') && *n != "*")
        .collect();
    assert_eq!(names, SPECS.iter().map(|s| s.name).collect::<Vec<_>>());
    // 読み方と誤りの文の形
    for needle in [
        r#"pinned_re="^[[:space:]]*\\[string\\][\$]${version_param}[[:space:]]*=[[:space:]]*'([^']*)'""#,
        r#"id_re="^[[:space:]]*[\$]${id_var}[[:space:]]*=[[:space:]]*'([A-Za-z0-9][A-Za-z0-9.-]*)'""#,
        r#"cannot_check "${ps1_name} が読めません: ${ps1_label}""#,
        r#"cannot_check "固定した版が読めません: ${ps1_label} に [string]\$${version_param} = '<版>' の行がありません。""#,
        r#"cannot_check "固定した版が読めません: ${ps1_label} の -${version_param} の既定値 '${pinned}' が ${title} の版の形ではありません (例: ${version_example})。""#,
        r#"cannot_check "パッケージ ID が読めません: ${ps1_label} に \$${id_var} = '<ID>' の行がありません。""#,
        r#"manifest_dir="manifests/${initial,,}/${package_id//.//}""#,
        r#"contents_api="repos/microsoft/winget-pkgs/contents/${manifest_dir}""#,
        r#"cannot_check "見送りの一覧の ${n} 行目が読めません (${skipped_label}): ${line}" \"#,
        r#""1 行に「版 理由」を空白で区切って書く。版は ${title} の版の形 (例: ${version_example} 試したら設定が読めなかった)。""#,
        r#"if ! grep -q 'HTTP 404' "${tmp}/contents.err"; then"#,
        r#"cannot_check "winget-pkgs の ${manifest_dir} を読めませんでした (gh api ${contents_api}):" \"#,
        r#"cannot_check "winget-pkgs の応答が読めませんでした (ディレクトリの一覧ではない):" \"#,
        r#""$(head -c 300 "${tmp}/contents.json")""#,
        r#"gone_why="${manifest_dir} に版のディレクトリが無い""#,
        r#"cannot_check "${package_id} が winget-pkgs に無い (${gone_why})。新しい版を出せない""#,
        r#"versions=$(grep -E "${version_re}" <<<"${names}" | sort -V -r || true)"#,
        r#"versions=$(grep -E "${series_re}" <<<"${versions}" || true)"#,
    ] {
        assert!(
            s.contains(needle),
            "check-winget-version.sh に無い: {needle}"
        );
    }
}

/// herdr-app・herdr-core の読み方と文は WSL の check-herdr-app-version.sh と同じ
#[test]
fn herdr_texts_match_the_wsl_script() {
    let s = script_text("nix/scripts/check-herdr-app-version.sh");
    for needle in [
        format!("releases='{}'", herdr::RELEASES_URL),
        r#"app:*) echo "${releases}/app/$2/herdr-app-windows-x86_64.tar.gz" ;;"#.to_string(),
        r#"core:windows-x86_64) echo "${releases}/core/$2/herdr-core-windows-x86_64.zip" ;;"#.to_string(),
        r#"releases_file=${args[0]:-${repo_dir}/nix/pkgs/herdr-core/releases.json}"#.to_string(),
        r#"echo "!! releases.json が読めません (無い・JSON でない): ${releases_file}" >&2"#.to_string(),
        r#"echo "!! releases.json から固定した版と sha256 を読めません (${bad# }): ${releases_file}" >&2"#.to_string(),
        r#"echo "!! 確かめられなかった: 見送りの一覧の ${n} 行目が読めません (${skipped_label}): ${line}" >&2"#.to_string(),
        r#"echo "   1 行に「app か core・版・理由」を空白で区切って書く (例: app 0.1.14 試したら窓が開かなかった)。" >&2"#.to_string(),
        r#"gh api --paginate "repos/$1/tags?per_page=100" --jq '.[].name' </dev/null >"${tmp}/tags" || return 1"#.to_string(),
        r#"sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' "${tmp}/tags" | sort -V"#.to_string(),
        r#"echo "!! 確かめられなかった: GitHub の ${repo} の tag を読めない (gh api repos/${repo}/tags)" >&2"#.to_string(),
        r#"headers=$(curl -sSIL --max-time 60 "$1" </dev/null) || return 1"#.to_string(),
        r#"if [[ ${status} == 404 ]]; then"#.to_string(),
        r#"json_component app "${app_version}" herdrdev/herdr-app herdr-app "${tmp}/app.json" || exit 2"#.to_string(),
        r#"json_component core "${core_version}" herdrdev/herdr-core herdr-core "${tmp}/core.json" || exit 2"#.to_string(),
        r#"if [[ $1 == herdr-core ]]; then"#.to_string(),
        r#"echo "Windows の $1""#.to_string(),
        "app_targets=(windows-x86_64)".to_string(),
        "core_targets=(linux-aarch64 linux-x86_64 windows-x86_64)".to_string(),
    ] {
        assert!(s.contains(&needle), "check-herdr-app-version.sh に無い: {needle}");
    }
    assert_eq!(herdr::RELEASES_REL, "nix/pkgs/herdr-core/releases.json");
    assert_eq!(
        herdr::SKIPPED_REL,
        "nix/pkgs/herdr-core/skipped-versions.txt"
    );
    // sha256 の誤りの並びは、WSL の連想配列が持つ 4 つの鍵 (並びは bash の鍵の順)
    let mut keys: Vec<String> = SHA_KEYS.iter().map(|(k, t)| format!("{k}:{t}")).collect();
    keys.sort();
    assert_eq!(
        keys,
        vec![
            "app:windows-x86_64",
            "core:linux-aarch64",
            "core:linux-x86_64",
            "core:windows-x86_64"
        ]
    );
}

/// repo の本物の ps1・見送りの一覧・releases.json を読める (gh には新しい版を 1 つずつ答えさせる)
#[test]
fn reads_the_real_repo_files() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
    let groups = Groups::embedded().unwrap();
    let t = TempDir::new("pin-updates-real");
    let sys = FakeSys::new(|c| {
        let args = c.args_lossy();
        let a: Vec<&str> = args.iter().map(String::as_str).collect();
        let output = match a.as_slice() {
            ["auth", "token"] => vec!["gho_fake".to_string()],
            // pwsh は 7.6 の線の 4 つの数の版だけを読む (7.7 の版と Preview は数えない)
            ["api", ep] if *ep == format!("{CONTENTS}manifests/m/Microsoft/PowerShell") => vec![
                json!([{"name": "7.6.99.0", "type": "dir"}, {"name": "7.7.0.0", "type": "dir"}, {"name": "Preview", "type": "dir"}])
                    .to_string(),
            ],
            ["api", ep] if ep.starts_with(CONTENTS) => vec![
                json!([{"name": "99.0.0", "type": "dir"}, {"name": "0.0.1", "type": "dir"}])
                    .to_string(),
            ],
            ["api", "--paginate", ..] => vec!["v99.0.0".to_string(), "v0.0.1".to_string()],
            _ => head(&["200"]).out,
        };
        RunResult {
            exit: Exit::Code(0),
            output,
        }
    })
    .with_program("gh", GH)
    .with_program("curl", CURL);
    std::fs::create_dir_all(t.path().join("ghq/github.com/pollenjp/dotfiles/.git")).unwrap();
    let mut out = Vec::new();
    let outcomes = {
        let mut ctx = Ctx {
            repo,
            roots: Roots::from_home(t.path()),
            state_dir: t.path().join("state"),
            host: parse(
                "[tools]\nwindowsTailscale = true\nwindowsClaudeCode = true\nwindowsHerdr = true\nwindowsNtn = true\n",
                Path::new("h.toml"),
                groups,
            )
            .unwrap(),
            sys: &sys,
            out: &mut out,
        };
        PinUpdates.run(&mut ctx, CHECK)
    };
    let out = String::from_utf8(out).unwrap();
    assert_eq!(outcomes[0].kind, Kind::Info, "{out}");
    assert_eq!(outcomes[0].notes.len(), NAMES.len() + 2, "{out}");
    for spec in SPECS {
        let want = if spec.name == "pwsh" {
            "7.6.99.0"
        } else {
            "99.0.0"
        };
        assert!(
            out.contains(&format!("   {}: ", spec.title)) && out.contains(&format!(" → {want}\n")),
            "{}: {out}",
            spec.name
        );
    }
}

// ------------------------------------------------------------------ WSL の版との突き合わせ

#[cfg(unix)]
mod parity {
    use super::*;
    use crate::hooks::parity as bash;
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Command, Stdio};

    /// 偽の gh (WSL と runner が同じものを打つ)。打たれた引数を FAKE_LOG に足し、FAKE_DIR の作り物から答える。
    ///   auth token                     FAKE_DIR/nologin があればログインしていない
    ///   api [--paginate] <ep> [--jq e] FAKE_DIR/api/<ep の / ? = & : を _ にしたもの>.{json,rc,err} (無ければ contents・tags の既定、それも無ければ 404)
    const FAKE_GH: &str = r#"printf 'gh %s\n' "$*" >>"${FAKE_LOG}"
if [[ $1 == auth && $2 == token ]]; then
  if [[ -e ${FAKE_DIR}/nologin ]]; then
    echo 'no oauth token found for github.com' >&2
    exit 1
  fi
  echo gho_fake
  exit 0
fi
[[ $1 == api ]] || { echo "偽の gh: 知らない: $*" >&2; exit 99; }
shift
jqexpr=''
ep=''
while (($#)); do
  case $1 in
    --paginate) ;;
    --jq) jqexpr=$2; shift ;;
    *) ep=$1 ;;
  esac
  shift
done
key=$(printf '%s' "${ep}" | tr '/?=&:' '_____')
f="${FAKE_DIR}/api/${key}"
if [[ ! -e ${f}.json && ! -e ${f}.rc ]]; then
  case ${ep} in
    repos/microsoft/winget-pkgs/contents/*) f="${FAKE_DIR}/api/default-contents" ;;
    repos/*/tags*) f="${FAKE_DIR}/api/default-tags" ;;
  esac
fi
if [[ ! -e ${f}.json && ! -e ${f}.rc ]]; then
  printf '%s' '{"message":"Not Found","status":"404"}'
  echo 'gh: Not Found (HTTP 404)' >&2
  exit 1
fi
rc=0
[[ ! -e ${f}.rc ]] || rc=$(<"${f}.rc")
[[ ! -e ${f}.err ]] || cat "${f}.err" >&2
if [[ ${rc} != 0 ]]; then
  [[ ! -e ${f}.json ]] || cat "${f}.json"
  exit "${rc}"
fi
if [[ -n ${jqexpr} ]]; then
  jq -r "${jqexpr}" "${f}.json"
else
  cat "${f}.json"
fi
"#;

    /// 偽の curl。FAKE_DIR/head/<URL の / : を _ にしたもの>.{txt,rc,err} から答える (無ければ 200)
    const FAKE_CURL: &str = r#"printf 'curl %s\n' "$*" >>"${FAKE_LOG}"
url=${*: -1}
key=$(printf '%s' "${url}" | tr '/:' '__')
f="${FAKE_DIR}/head/${key}"
rc=0
[[ ! -e ${f}.rc ]] || rc=$(<"${f}.rc")
[[ ! -e ${f}.err ]] || cat "${f}.err" >&2
if [[ -e ${f}.txt ]]; then
  cat "${f}.txt"
elif [[ ${rc} == 0 ]]; then
  printf 'HTTP/2 200\r\nlast-modified: Wed, 12 Nov 2026 03:04:05 GMT\r\n\r\n'
fi
exit "${rc}"
"#;

    fn key(s: &str, chars: &[char]) -> String {
        s.chars()
            .map(|c| if chars.contains(&c) { '_' } else { c })
            .collect()
    }

    /// WSL と runner を同じ偽の gh・curl と同じ repo のファイルで流す組
    struct Pw {
        _t: TempDir,
        root: PathBuf,
        sys_bin: PathBuf,
        fake_bin: PathBuf,
        repo: PathBuf,
        /// WSL の HOME (windows-files.json・group.json)
        wsl_home: PathBuf,
        /// Windows のホーム (bootstrap の clone を見る所。WSL の windowsHome と runner の %USERPROFILE%)
        win_home: PathBuf,
    }

    impl Pw {
        /// `real` なら repo は本物 (script もそこから流す)、でなければ作り物の repo に 3 つの script を写す
        fn new(real: bool) -> Option<Pw> {
            if !bash::available() {
                return None;
            }
            let t = TempDir::new("pin-updates-parity");
            let root = std::fs::canonicalize(t.path()).unwrap();
            let sys_bin = root.join("sys-bin");
            let fake_bin = root.join("fake-bin");
            std::fs::create_dir_all(&sys_bin).unwrap();
            std::fs::create_dir_all(&fake_bin).unwrap();
            let path = std::env::var_os("PATH").unwrap_or_default();
            for c in [
                "bash", "env", "jq", "grep", "sed", "sort", "tr", "cat", "head", "tail", "mktemp",
                "rm", "cp", "dirname", "basename", "timeout", "date", "mkdir", "sleep",
            ] {
                let found = std::env::split_paths(&path)
                    .filter(|d| !d.starts_with("/mnt"))
                    .map(|d| d.join(c))
                    .find(|p| p.is_file())
                    .unwrap_or_else(|| panic!("{c} が無い"));
                std::os::unix::fs::symlink(found, sys_bin.join(c)).unwrap();
            }
            for (name, body) in [("gh", FAKE_GH), ("curl", FAKE_CURL)] {
                let f = fake_bin.join(name);
                std::fs::write(&f, format!("#!{}\n{body}", sys_bin.join("bash").display()))
                    .unwrap();
                std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            let repo = if real {
                std::fs::canonicalize(bash::repo_file("")).unwrap()
            } else {
                let repo = root.join("repo");
                write_repo(&repo);
                let scripts = repo.join("nix").join("scripts");
                std::fs::create_dir_all(&scripts).unwrap();
                for s in [
                    "bootstrap-windows-pin-updates.sh",
                    "check-winget-version.sh",
                    "check-herdr-app-version.sh",
                ] {
                    std::fs::copy(
                        bash::repo_file(&format!("nix/scripts/{s}")),
                        scripts.join(s),
                    )
                    .unwrap();
                }
                repo
            };
            for d in ["fx/api", "fx/head", "wsl-home", "win-home", "tmp"] {
                std::fs::create_dir_all(root.join(d)).unwrap();
            }
            Some(Pw {
                wsl_home: root.join("wsl-home"),
                win_home: root.join("win-home"),
                _t: t,
                root,
                sys_bin,
                fake_bin,
                repo,
            })
        }

        fn fx(&self) -> PathBuf {
            self.root.join("fx")
        }

        /// repo のファイルを書く (親のディレクトリも作る)
        fn write(&self, rel: &str, text: impl AsRef<[u8]>) {
            let f = crate::context::join_segments(&self.repo, rel);
            std::fs::create_dir_all(f.parent().unwrap()).unwrap();
            std::fs::write(f, text).unwrap();
        }

        /// gh api の答え (`ep` は gh に渡す endpoint。default-contents・default-tags は既定)
        fn api(&self, ep: &str, json: &str, rc: i32, err: &str) {
            let base = self
                .fx()
                .join("api")
                .join(key(ep, &['/', '?', '=', '&', ':']));
            let file = |ext: &str| PathBuf::from(format!("{}.{ext}", base.display()));
            std::fs::write(file("json"), json).unwrap();
            if rc != 0 {
                std::fs::write(file("rc"), rc.to_string()).unwrap();
            }
            if !err.is_empty() {
                std::fs::write(file("err"), err).unwrap();
            }
        }

        fn contents(&self, name: &str, versions: &[&str]) {
            self.api(
                &format!("{CONTENTS}{}", manifest_dir(id_of(name))),
                &dirs(versions).out[0],
                0,
                "",
            );
        }

        fn tags(&self, name: &str, tags: &[&str]) {
            let json: Vec<serde_json::Value> = tags.iter().map(|t| json!({"name": t})).collect();
            self.api(
                &format!("repos/herdrdev/{name}/tags?per_page=100"),
                &serde_json::Value::Array(json).to_string(),
                0,
                "",
            );
        }

        /// curl の答え (`txt` は応答の頭。空なら書かない)
        fn head(&self, url: &str, txt: &str, rc: i32, err: &str) {
            let base = self.fx().join("head").join(key(url, &['/', ':']));
            let file = |ext: &str| PathBuf::from(format!("{}.{ext}", base.display()));
            if !txt.is_empty() {
                std::fs::write(file("txt"), txt).unwrap();
            }
            if rc != 0 {
                std::fs::write(file("rc"), rc.to_string()).unwrap();
            }
            if !err.is_empty() {
                std::fs::write(file("err"), err).unwrap();
            }
        }

        /// WSL の記録 (windows-files.json・group.json) と、Windows の bootstrap の clone
        fn state(&self, ntn: bool, claude: bool, herdr: bool, tailscale: bool, boot: bool) {
            let d = self.wsl_home.join(".local/state/dotfiles");
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(
                d.join("windows-files.json"),
                json!({"claudeCode": claude, "enable": true, "ntn": ntn, "typeClipboard": false, "version": 1,
                       "windowsHome": self.win_home.display().to_string()})
                .to_string(),
            )
            .unwrap();
            std::fs::write(
                d.join("group.json"),
                json!({"group": "minimum", "tools": {"windowsHerdr": herdr, "windowsTailscale": tailscale}, "version": 2})
                    .to_string(),
            )
            .unwrap();
            let git = self.win_home.join("ghq/github.com/pollenjp/dotfiles/.git");
            if boot {
                std::fs::create_dir_all(&git).unwrap();
            } else if git.exists() {
                std::fs::remove_dir_all(&git).unwrap();
            }
        }

        /// 同じ状態の、runner のホストの値
        fn host(ntn: bool, claude: bool, herdr: bool, tailscale: bool) -> String {
            format!(
                "[tools]\nwindowsNtn = {ntn}\nwindowsClaudeCode = {claude}\nwindowsHerdr = {herdr}\nwindowsTailscale = {tailscale}\n"
            )
        }

        fn log(&self, side: &str) -> Vec<String> {
            std::fs::read_to_string(self.root.join(format!("{side}.log")))
                .unwrap_or_default()
                .lines()
                .map(str::to_string)
                .collect()
        }

        fn reset_logs(&self) {
            for side in ["wsl", "rn"] {
                let _ = std::fs::remove_file(self.root.join(format!("{side}.log")));
            }
        }

        /// WSL の check の口を流す (終了コードと、stdout の行と stderr の行)
        fn wsl(&self, script: &str, args: &[&str]) -> (i32, Vec<String>, Vec<String>) {
            let path = format!("{}:{}", self.fake_bin.display(), self.sys_bin.display());
            let o = Command::new(self.sys_bin.join("bash"))
                .arg(self.repo.join("nix/scripts").join(script))
                .args(args)
                .env_clear()
                .env("HOME", &self.wsl_home)
                .env("PATH", path)
                .env("FAKE_DIR", self.fx())
                .env("FAKE_LOG", self.root.join("wsl.log"))
                .env("TMPDIR", self.root.join("tmp"))
                .env("LC_ALL", "C.UTF-8")
                .stdin(Stdio::null())
                .output()
                .unwrap();
            let lines = |b: &[u8]| -> Vec<String> {
                String::from_utf8_lossy(b)
                    .lines()
                    .map(str::to_string)
                    .collect()
            };
            (
                o.status.code().unwrap_or(-1),
                lines(&o.stdout),
                lines(&o.stderr),
            )
        }

        /// WSL の setup の手順 (stdout と stderr を届いた順に 1 つの pipe で)
        fn wsl_setup(&self, gh: bool) -> Vec<String> {
            let mut path = self.sys_bin.display().to_string();
            if gh {
                path = format!("{}:{path}", self.fake_bin.display());
            }
            let o = Command::new(self.sys_bin.join("bash"))
                .arg("-c")
                .arg("exec 2>&1; exec \"$0\" \"$@\"")
                .arg(self.sys_bin.join("bash"))
                .arg(
                    self.repo
                        .join("nix/scripts/bootstrap-windows-pin-updates.sh"),
                )
                .env_clear()
                .env("HOME", &self.wsl_home)
                .env("PATH", path)
                .env("FAKE_DIR", self.fx())
                .env("FAKE_LOG", self.root.join("wsl.log"))
                .env("TMPDIR", self.root.join("tmp"))
                .env("LC_ALL", "C.UTF-8")
                .stdin(Stdio::null())
                .output()
                .unwrap();
            assert_eq!(o.status.code(), Some(0), "WSL の setup の手順は exit 0");
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .map(str::to_string)
                .collect()
        }

        /// runner の側の外のコマンドの口 (偽の gh・curl を本物の口で打つ)
        fn sys(&self, gh: bool) -> ParitySys {
            ParitySys {
                gh: gh.then(|| self.fake_bin.join("gh")),
                curl: self.fake_bin.join("curl"),
                envs: vec![
                    ("PATH".into(), self.sys_bin.display().to_string()),
                    ("FAKE_DIR".into(), self.fx().display().to_string()),
                    (
                        "FAKE_LOG".into(),
                        self.root.join("rn.log").display().to_string(),
                    ),
                    ("LC_ALL".into(), "C.UTF-8".into()),
                ],
            }
        }

        fn with_ctx<T>(
            &self,
            host: &str,
            gh: bool,
            f: impl FnOnce(&mut Ctx) -> T,
        ) -> (T, Vec<String>) {
            let sys = self.sys(gh);
            let groups = Groups::embedded().unwrap();
            let mut out = Vec::new();
            let v = {
                let mut ctx = Ctx {
                    repo: self.repo.clone(),
                    roots: Roots::from_home(&self.win_home),
                    state_dir: self.root.join("state"),
                    host: parse(host, Path::new("h.toml"), groups).unwrap(),
                    sys: &sys,
                    out: &mut out,
                };
                f(&mut ctx)
            };
            assert!(!self.root.join("state").exists());
            (
                v,
                String::from_utf8(out)
                    .unwrap()
                    .lines()
                    .map(str::to_string)
                    .collect(),
            )
        }

        /// runner の手順の出力
        fn runner_setup(&self, host: &str, gh: bool) -> (Vec<Outcome>, Vec<String>) {
            self.with_ctx(host, gh, |ctx| PinUpdates.run(ctx, Mode::Check))
        }

        /// winget の 1 つの名前の口を両方で流して比べる
        fn same_winget(&self, name: &str) {
            self.reset_logs();
            let (rc, stdout, stderr) = self.wsl("check-winget-version.sh", &["--json", name]);
            let (found, _) = self.with_ctx("", true, |ctx| {
                winget::check(
                    ctx,
                    &self.fake_bin.join("gh"),
                    spec_of(name),
                    std::time::Instant::now() + Duration::from_secs(LIMIT_SECS),
                )
            });
            match found {
                Ok(f) => {
                    assert_eq!(rc, 0, "{name}: {stderr:?}");
                    let v: serde_json::Value = serde_json::from_str(&stdout.join("\n")).unwrap();
                    assert_eq!(v["title"], json!(f.title), "{name}");
                    assert_eq!(v["pinned"], json!(f.pinned), "{name}");
                    let newer: Vec<(String, Option<String>)> = v["newer"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|n| {
                            (
                                n["version"].as_str().unwrap().to_string(),
                                n["skipped"].as_str().map(str::to_string),
                            )
                        })
                        .collect();
                    let mine: Vec<(String, Option<String>)> = f
                        .newer
                        .into_iter()
                        .map(|n| (n.version, n.skipped))
                        .collect();
                    assert_eq!(newer, mine, "{name}");
                }
                Err(trouble) => {
                    assert_eq!(rc, 2, "{name}: {stdout:?}");
                    assert_eq!(stderr, trouble, "{name}");
                }
            }
            assert_eq!(self.log("wsl"), self.log("rn"), "{name}: 打った gh");
        }

        /// herdr-app・herdr-core の口を両方で流して比べる
        fn same_herdr(&self) {
            self.reset_logs();
            let (rc, stdout, stderr) = self.wsl("check-herdr-app-version.sh", &["--json"]);
            let (found, _) = self.with_ctx("", true, |ctx| {
                herdr::check(
                    ctx,
                    &self.fake_bin.join("gh"),
                    Some(&self.fake_bin.join("curl")),
                    std::time::Instant::now() + Duration::from_secs(LIMIT_SECS),
                )
            });
            match found {
                Ok((app, core)) => {
                    assert_eq!(rc, 0, "{stderr:?}");
                    assert_eq!(stdout.len(), 2, "{stdout:?}");
                    for (line, f) in stdout.iter().zip([app, core]) {
                        let v: serde_json::Value = serde_json::from_str(line).unwrap();
                        assert_eq!(v["title"], json!(f.title));
                        assert_eq!(v["pinned"], json!(f.pinned));
                        let newer: Vec<(String, Option<String>)> = v["newer"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|n| {
                                (
                                    n["version"].as_str().unwrap().to_string(),
                                    n["skipped"].as_str().map(str::to_string),
                                )
                            })
                            .collect();
                        let mine: Vec<(String, Option<String>)> = f
                            .newer
                            .into_iter()
                            .map(|n| (n.version, n.skipped))
                            .collect();
                        assert_eq!(newer, mine);
                    }
                }
                Err(trouble) => {
                    assert_eq!(rc, 2, "{stdout:?}");
                    assert_eq!(stderr, trouble);
                }
            }
            assert_eq!(self.log("wsl"), self.log("rn"), "打った gh と curl");
        }

        /// setup の手順を両方で流し、知らせる文と、打った gh・curl を比べる
        fn same_setup(
            &self,
            ntn: bool,
            claude: bool,
            herdr: bool,
            tailscale: bool,
            boot: bool,
            gh: bool,
        ) -> Vec<String> {
            self.state(ntn, claude, herdr, tailscale, boot);
            self.reset_logs();
            let wsl = self.wsl_setup(gh);
            let (outcomes, rn) = self.runner_setup(&Self::host(ntn, claude, herdr, tailscale), gh);
            // runner が変えたのは、確かめられなかったときの「setup は続けます。」と、gh が無いときの直し方だけ
            let wsl: Vec<String> = wsl
                .into_iter()
                .map(|l| l.replace("。setup は続けます。", "。"))
                .map(|l| {
                    l.replace(
                        "gh が見つからない。home-manager switch の後に流し直す",
                        "gh が見つからない。gh は bootstrap (win/bootstrap/Install-Bootstrap.ps1) が入れる。入れた後に流し直す",
                    )
                })
                .collect();
            assert_eq!(wsl, rn, "知らせる文");
            assert_eq!(self.log("wsl"), self.log("rn"), "打った gh と curl");
            assert!(!outcomes.is_empty());
            rn
        }
    }

    /// runner の側の口: 偽の gh・curl を本物の口で打つ (要るコマンドだけを並べた PATH で)
    struct ParitySys {
        gh: Option<PathBuf>,
        curl: PathBuf,
        envs: Vec<(String, String)>,
    }

    impl crate::process::Sys for ParitySys {
        fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
            let mut s = spec.clone().env_remove("GH_TOKEN");
            for (k, v) in &self.envs {
                s = s.env(k, v);
            }
            crate::process::RealSys.run(&s, on_line)
        }

        fn which(&self, name: &str) -> Option<PathBuf> {
            match name {
                "gh" => self.gh.clone(),
                "curl" => Some(self.curl.clone()),
                _ => None,
            }
        }

        fn env(&self, _name: &str) -> Option<String> {
            None
        }
    }

    /// winget の口: 新しい版・見送り・版の並び・Preview・ファイル・404・API の失敗・一覧でない応答・ps1 と見送りの一覧の誤り
    #[test]
    fn winget_matches_check_winget_version() {
        let Some(p) = Pw::new(false) else { return };
        for s in SPECS {
            p.contents(s.name, &[pinned_of(s.name)]);
        }
        for s in SPECS {
            p.same_winget(s.name);
        }
        p.contents(
            "herdr",
            &[
                "0.10.0",
                "0.9.5",
                "Preview",
                "0.9.10",
                "0.9.6",
                "odd",
                "file:0.9.7",
                "0.9.4",
            ],
        );
        p.contents(
            "openssh",
            &[
                "10.1.0.0",
                "9.8.3.0",
                "10.1.0.1",
                "10.2",
                "10.1.0.0.1",
                "010.1.0.1",
            ],
        );
        p.contents(
            "tailscale",
            &["1.104.5", "1.104.6", "0.98.0.0", "1.104.6.1", "1.104.10"],
        );
        p.contents("git", &["2.56.0.4", "2.56.1", "2.56.0.5", "2.57.0"]);
        p.write("win/herdr/skipped-versions.txt", "\u{feff}# 見送った版\r\n\r\n  0.9.6   試したら  設定が読めなかった \r\n0.9.6 後の行\r\n");
        p.write(
            "win/bootstrap/skipped-versions/git.txt",
            "\u{3000}\n\u{3000}# 全角の空白の後ろの注釈\n\u{2003}\u{205f}\t\n2.56.1 速すぎた\n",
        );
        // ps1 の行頭と = の前後の Unicode の空白 (C.UTF-8 の [[:space:]])
        p.write(
            "win/google-japanese-input/Install-GoogleJapaneseInput.ps1",
            "\u{3000}[string]$Version\u{2003}=\u{3000}'3.35.6300.0'\n\u{1680}$packageId = 'Google.JapaneseIME'\n",
        );
        p.contents("google-japanese-input", &["3.35.6300.0", "3.35.6301.0"]);
        for n in [
            "herdr",
            "openssh",
            "tailscale",
            "git",
            "google-japanese-input",
        ] {
            p.same_winget(n);
        }
        // 確かめられない: 404・版のディレクトリが無い・Preview だけ・API の失敗 (stderr が空のときも)・一覧でない応答
        p.api(
            &format!("{CONTENTS}{}", manifest_dir(id_of("ntn"))),
            r#"{"message":"Not Found"}"#,
            1,
            "gh: Not Found (HTTP 404)\n",
        );
        p.contents("claude-code", &["file:x.yaml"]);
        p.contents("herdr", &["Preview"]);
        p.api(
            &format!("{CONTENTS}{}", manifest_dir(id_of("openssh"))),
            r#"{"message":"API rate limit exceeded"}"#,
            1,
            "gh: API rate limit exceeded for user ID 1. (HTTP 403)\n  second\n",
        );
        p.api(
            &format!("{CONTENTS}{}", manifest_dir(id_of("gh"))),
            "",
            1,
            "",
        );
        p.api(
            &format!("{CONTENTS}{}", manifest_dir(id_of("rustup"))),
            "[1, 2]",
            0,
            "",
        );
        p.api(
            &format!("{CONTENTS}{}", manifest_dir(id_of("vs-buildtools"))),
            &format!("[{}", "y".repeat(500)),
            0,
            "",
        );
        p.api(
            &format!("{CONTENTS}{}", manifest_dir(id_of("google-japanese-input"))),
            "",
            0,
            "",
        );
        for s in SPECS {
            p.same_winget(s.name);
        }
        // ps1 と見送りの一覧の誤り
        p.write("win/ntn/Install-Ntn.ps1", "$packageId = 'Notion.ntn'\n");
        p.write(
            "win/claude-code/Install-ClaudeCode.ps1",
            "[string]$Version = '2.1'\n$packageId = 'Anthropic.ClaudeCode'\n",
        );
        p.write(
            "win/herdr/Install-Herdr.ps1",
            "[string]$Version = '0.9.5'\n",
        );
        std::fs::remove_file(p.repo.join("win/openssh/Install-OpenSSH.ps1")).unwrap();
        p.write("win/bootstrap/skipped-versions/gh.txt", "# x\n2.104.0\n");
        p.write(
            "win/bootstrap/skipped-versions/rustup.txt",
            "v1.29.4 速い\n",
        );
        p.write(
            "win/tailscale/Install-Tailscale.ps1",
            ps1_text(
                &[("Version", "1.104.5.0")],
                &[("packageId", "Tailscale.Tailscale")],
            ),
        );
        for s in SPECS {
            p.same_winget(s.name);
        }
    }

    /// herdr-app・herdr-core の口: 新しい版・見送り (HEAD を打たない)・404 (redirect の先も)・curl の失敗・tag を読めない・releases.json と見送りの一覧の誤り
    #[test]
    fn herdr_matches_check_herdr_app_version() {
        let Some(p) = Pw::new(false) else { return };
        p.tags("herdr-app", &["v0.1.15"]);
        p.tags("herdr-core", &["v0.1.21"]);
        p.same_herdr();
        p.tags(
            "herdr-app",
            &[
                "v0.1.15",
                "v0.1.9",
                "preview-20261101-abc",
                "v0.1.16",
                "v0.1.17",
                "v0.1.18",
                "v0.1.20",
                "0.1.19",
                "v0.1.21-rc1",
            ],
        );
        p.tags("herdr-core", &["v0.1.21", "v0.1.22", "v0.1.23"]);
        p.head(&artifact_url("app", "0.1.16"), "HTTP/2 404\r\n\r\n", 0, "");
        p.head(
            &artifact_url("app", "0.1.17"),
            "HTTP/1.1 302 Found\r\nlocation: x\r\n\r\nHTTP/2 404\r\n\r\n",
            0,
            "",
        );
        p.head(
            &artifact_url("app", "0.1.18"),
            "",
            6,
            "curl: (6) Could not resolve host: releases.herdr.dev\n",
        );
        p.head(&artifact_url("core", "0.1.22"), "HTTP/2 500\r\n\r\n", 0, "");
        p.write(
            herdr::SKIPPED_REL,
            "# 見送った版\n\u{3000}\n\u{2028}# 注釈\napp 0.1.20 窓が開かなかった\ncore 0.1.23 一つ目\ncore 0.1.23 後の理由\n",
        );
        p.same_herdr();
        // core の tag を読めない: app の curl の stderr と gh の stderr が先に来る
        p.api(
            "repos/herdrdev/herdr-core/tags?per_page=100",
            "{}",
            1,
            "gh: Bad credentials (HTTP 401)\n",
        );
        p.same_herdr();
        p.api(
            "repos/herdrdev/herdr-app/tags?per_page=100",
            r#"{"message":"Not Found"}"#,
            1,
            "gh: Not Found (HTTP 404)\n",
        );
        p.same_herdr();
        // releases.json と見送りの一覧の誤り
        p.tags("herdr-app", &["v0.1.15"]);
        p.tags("herdr-core", &["v0.1.21"]);
        p.write(herdr::SKIPPED_REL, "app 0.1.16\n");
        p.same_herdr();
        p.write(herdr::SKIPPED_REL, "both 0.1.16 x\n");
        p.same_herdr();
        std::fs::remove_file(p.repo.join(herdr::SKIPPED_REL)).unwrap();
        // sha256 の誤りは 1 つだけにする (2 つ以上の並びは bash の連想配列の鍵の順で、bash の版によって変わりうる。並びは単体の試験で見る)
        p.write(
            herdr::RELEASES_REL,
            json!({"app": {"version": "0.1", "sha256": {"windows-x86_64": "x"}},
                   "core": {"version": "0.1.21", "generation": 0,
                            "sha256": {"linux-aarch64": "b".repeat(64), "linux-x86_64": "c".repeat(64), "windows-x86_64": "d".repeat(64)}}})
            .to_string(),
        );
        p.same_herdr();
        p.write(herdr::RELEASES_REL, "[1]");
        p.same_herdr();
        p.write(
            herdr::RELEASES_REL,
            releases_json("0.1.15", "0.1.21", "\"2\""),
        );
        p.same_herdr();
    }

    /// setup の手順: 新しい版 (4 つ以上・見送り・Preview・keys.json の注意)・確かめられない名前・新しい版が無い・名前の on/off・gh が無い・ログインしていない
    #[test]
    fn setup_matches_bootstrap_windows_pin_updates() {
        let Some(p) = Pw::new(false) else { return };
        for s in SPECS {
            p.contents(s.name, &[pinned_of(s.name)]);
        }
        p.tags("herdr-app", &["v0.1.15"]);
        p.tags("herdr-core", &["v0.1.21"]);
        // 新しい版が無い
        let rn = p.same_setup(true, true, true, true, true, true);
        assert!(rn[0].starts_with(NONE_PREFIX), "{rn:?}");
        // 新しい版がある (4 つ以上・見送り・Preview・ファイル・keys.json の注意・成果物の無い版)
        p.contents("herdr", &["0.9.5", "0.9.6", "Preview", "file:0.9.7"]);
        p.contents(
            "claude-code",
            &[
                "2.1.318", "2.1.321", "2.1.322", "2.1.323", "2.1.325", "2.1.330",
            ],
        );
        p.contents("gh", &["2.103.3", "2.104.0", "2.105.0"]);
        p.contents(
            "ntn",
            &["0.23.28", "0.23.29", "0.23.30", "0.23.31", "0.23.32"],
        );
        p.contents("openssh", &["10.1.0.0", "10.1.0.1", "10.1.0.2", "10.1.0.3"]);
        p.write(
            "win/bootstrap/skipped-versions/gh.txt",
            "2.104.0 速すぎた\n",
        );
        p.tags("herdr-app", &["v0.1.15", "v0.1.16"]);
        p.tags("herdr-core", &["v0.1.21", "v0.1.22", "v0.1.23"]);
        p.head(&artifact_url("core", "0.1.23"), "HTTP/2 404\r\n\r\n", 0, "");
        let rn = p.same_setup(true, true, true, true, true, true);
        assert!(rn.iter().any(|l| l.ends_with(KEYS_NOTE[1])), "{rn:?}");
        // 名前の on/off
        p.same_setup(false, false, true, false, false, true);
        p.same_setup(true, true, false, true, true, true);
        // 確かめられない名前 (ほかの新しい版は知らせる)
        p.api(
            &format!("{CONTENTS}{}", manifest_dir(id_of("openssh"))),
            "{}",
            1,
            "gh: API rate limit exceeded for user ID 1. (HTTP 403)\n",
        );
        p.api(
            &format!("{CONTENTS}{}", manifest_dir(id_of("ntn"))),
            "not json",
            0,
            "",
        );
        let rn = p.same_setup(true, true, true, true, true, true);
        assert!(
            rn.last()
                .unwrap()
                .starts_with(&format!("!! {FAILED_PREFIX}openssh・ntn (")),
            "{rn:?}"
        );
        p.api(
            "repos/herdrdev/herdr-app/tags?per_page=100",
            "{}",
            1,
            "gh: Bad credentials (HTTP 401)\n",
        );
        p.same_setup(true, true, true, true, true, true);
        // gh が無い・ログインしていない
        p.same_setup(true, true, true, true, true, false);
        std::fs::write(p.fx().join("nologin"), "").unwrap();
        let rn = p.same_setup(true, true, true, true, true, true);
        assert_eq!(rn, vec![format!("!! {NOT_LOGGED_IN}")]);
    }

    /// repo の本物の ps1・見送りの一覧・releases.json で、setup の手順を両方で流す (どの名前にも新しい版 99.0.0 を答えさせる)
    #[test]
    fn setup_matches_on_the_real_repo_files() {
        let Some(p) = Pw::new(true) else { return };
        p.api(
            "default-contents",
            &json!([{"name": "0.0.1", "type": "dir"}, {"name": "99.0.0", "type": "dir"}])
                .to_string(),
            0,
            "",
        );
        p.api(
            "default-tags",
            &json!([{"name": "v0.0.1"}, {"name": "v99.0.0"}]).to_string(),
            0,
            "",
        );
        // pwsh は 7.6 の線の 4 つの数の版だけを読む (7.7 の版と Preview は数えない)
        p.contents("pwsh", &["7.6.9.0", "7.6.99.0", "7.7.0.0", "Preview"]);
        // 作り物の名前は default のファイルを指す (偽の gh が default-contents.json・default-tags.json を読む)
        let rn = p.same_setup(true, true, true, true, true, true);
        assert_eq!(rn[0], format!("!! {HEADING}"));
        assert_eq!(rn.len(), 1 + NAMES.len() + 2, "{rn:?}");
        for l in &rn[1..=NAMES.len()] {
            let want = if l.contains("PowerShell 7") {
                " → 7.6.99.0"
            } else {
                " → 99.0.0"
            };
            assert!(l.ends_with(want), "{l}");
        }
        for s in SPECS {
            p.same_winget(s.name);
        }
        p.same_herdr();
    }

    /// is_space は、C.UTF-8 の bash の `[[:space:]]` (正規表現と glob) と同じ字を空白と読む (Unicode の空白とその近くの字で比べる)
    #[test]
    fn is_space_matches_bash_space_class() {
        if !bash::available() {
            return;
        }
        let mut cands: Vec<u32> = (1..=0x20).collect();
        cands.extend([
            0x7f, 0x85, 0xa0, 0x1680, 0x180e, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
            0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x200b, 0x200c, 0x200d, 0x2028, 0x2029, 0x202f,
            0x205f, 0x2060, 0x3000, 0x3001, 0xfeff,
        ]);
        let script = r#"for cp in "$@"; do printf -v c "\\U$(printf '%08x' "$cp")"; r=0; g=0; [[ $c =~ ^[[:space:]]$ ]] && r=1; case $c in [[:space:]]) g=1 ;; esac; echo "$cp $r $g"; done"#;
        let o = Command::new("bash")
            .arg("-c")
            .arg(script)
            .arg("bash")
            .args(cands.iter().map(|c| c.to_string()))
            .env("LC_ALL", "C.UTF-8")
            .stdin(Stdio::null())
            .output()
            .unwrap();
        let out = String::from_utf8(o.stdout).unwrap();
        assert_eq!(out.lines().count(), cands.len(), "{out}");
        for l in out.lines() {
            let f: Vec<&str> = l.split(' ').collect();
            let c = char::from_u32(f[0].parse().unwrap()).unwrap();
            assert_eq!(f[1], f[2], "正規表現と glob が違う: U+{:04X}", c as u32);
            assert_eq!(is_space(c), f[1] == "1", "U+{:04X}", c as u32);
        }
    }

    /// 版の比べ方は sort -V (C の locale) と同じ。比べるのは、WSL と runner が並べる形 (版の形の正規表現を通った、数と `.` だけの字。頭の 0 も
    /// 欄の数の違いも) だけ。`.` で始まる名前・英字や `~` の拡張子の扱いは coreutils の版で違う (CI の ubuntu の sort と nix の sort でも違う) ので
    /// 比べない
    #[test]
    fn version_cmp_matches_sort_v() {
        if !bash::available() {
            return;
        }
        let mut items: Vec<String> = Vec::new();
        let parts = [
            "0", "1", "2", "9", "10", "010", "00", "09", "100", "19", "2026", "0001",
        ];
        let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for _ in 0..3000 {
            let n = 1 + (next() % 5) as usize;
            let s: Vec<&str> = (0..n)
                .map(|_| parts[(next() % parts.len() as u64) as usize])
                .collect();
            items.push(s.join("."));
        }
        for v in [
            "1.104.6",
            "1.104.6.0",
            "0.9.5",
            "0.10.0",
            "2.56.0.4",
            "2.56.1",
            "1.01",
            "1.1",
            "01.1",
        ] {
            items.push(v.to_string());
        }
        items.sort();
        items.dedup();
        let mut child = Command::new("sort")
            .arg("-V")
            .env("LC_ALL", "C")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        {
            use std::io::Write;
            let mut stdin = child.stdin.take().unwrap();
            stdin.write_all(items.join("\n").as_bytes()).unwrap();
            stdin.write_all(b"\n").unwrap();
        }
        let out = child.wait_with_output().unwrap();
        let sorted: Vec<String> = String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        let mut mine = items.clone();
        mine.sort_by(|a, b| version_cmp(a, b));
        assert_eq!(sorted, mine);
    }
}
