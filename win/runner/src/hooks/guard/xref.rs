//! xref-guard (PreToolUse・matcher Bash|PowerShell): public な repo に、ほかの repo の issue・PR・commit への参照を書く git push と gh pr create
//! などを、打つ前に止める。Linux の `nix/files/claude/hooks/xref-guard.sh` (dotfiles-private の ADR 033) の写しで、止めるもの・通すもの・返す文は
//! bash の版と同じ (Linux の CI が bash の版の試験 `nix/tests/xref-guard.test.sh` をこの口に流す)。
//!
//! Windows だけの足し (bash の版に無い。dotfiles-private の docs/adr/067_win_hook_guards_*): PowerShell の tool も読む (`guard::pslex`)。通す口は
//! PowerShell では `$env:PJP_ALLOW_XREF='1';` (返す文も PowerShell の形にする)。`wsl` の後ろの git push は、押す commit を Windows の hook から読めない
//! ので、押す先が private と分からなければ止める。`pwsh -Command`・`cmd /c` の中も読む。

use super::refs::{self, Text};
use super::{
    FOREIGN, LEX_LIMIT, Lang, World, base_name, cmd_command, deny, is_name, ps_alias, ps_named, ps_params,
    pwsh_command, skip_opts, split, wsl_command,
};
use crate::hooks::field;
use crate::process::{CommandSpec, Exit, Sys};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub fn run(raw: &str, input: &Value, sys: &dyn Sys) -> Option<String> {
    // 安い前段: push も gh も無い入力は読まない (この hook は Bash のたびに走る)
    if !(raw.contains("push") || raw.contains("gh")) {
        return None;
    }
    let lang = match field(input, &["tool_name"]).as_str() {
        "Bash" => Lang::Bash,
        "PowerShell" => Lang::PowerShell,
        _ => return None,
    };
    let cmd = field(input, &["tool_input", "command"]);
    let cwd = field(input, &["cwd"]);
    if !(cmd.contains("push") || (cmd.contains("gh") && (cmd.contains("pr") || cmd.contains("issue")))) {
        return None;
    }
    let mut x = Xref::new(sys, &cwd, lang);
    let bytes = cmd.len();
    if bytes > LEX_LIMIT {
        x.long_command(bytes.div_ceil(1024), &cmd);
    } else {
        let dir = x.w.cwd.clone();
        x.scan_command(&dir, 0, &cmd, lang);
    }
    (!x.sections.is_empty()).then(|| deny(&x.emit()))
}

/// simple の local (bash の版で、simple から呼ぶ関数が dynamic scope で読む変数)
#[derive(Clone, Default)]
struct Local {
    allow: bool,
    env_repo: String,
    env_host: String,
    in_text: String,
    in_known: bool,
}

struct Xref<'a> {
    w: World<'a>,
    lang: Lang,
    sections: Vec<String>,
    fixes: Vec<String>,
    vis_seen: HashMap<String, (String, String, String)>,
    pending_msgs: Vec<String>,
    amend_head: bool,
    inh_allow: bool,
    inh_repo: String,
    inh_host: String,
    long_kb: usize,
    next_dir: String,
    out_text: String,
    out_known: bool,
    last_out: String,
    last_known: bool,
    gh: Option<Option<PathBuf>>,
}

/// git の remote の URL を (host (小文字)・owner/repo) に分ける。手元の path・file:// は None
fn url_parse(u: &str, win: bool) -> Option<(String, String)> {
    if u.is_empty()
        || u.starts_with("file://")
        || u.starts_with('/')
        || u.starts_with("./")
        || u.starts_with("../")
        || u.starts_with('~')
    {
        return None;
    }
    // Windows の手元の path (C:\…・C:/…・\\server\…) も GitHub に届かない
    if win {
        let b = u.as_bytes();
        if u.starts_with('\\') || (b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && matches!(b[2], b'/' | b'\\')) {
            return None;
        }
    }
    let (host, mut rest): (String, String) = if let Some((_, after)) = u.split_once("://") {
        let hostpart = after.split('/').next().unwrap_or(after);
        let hostpart = hostpart.rsplit('@').next().unwrap_or(hostpart);
        let host = hostpart.split(':').next().unwrap_or(hostpart).to_string();
        let rest = after.split_once('/').map_or(after, |(_, r)| r).to_string();
        (host, rest)
    } else {
        // ^([^@/:]+@)?([^/:]+):(.*)$
        let (user_and_host, rest) = u.split_once(':')?;
        let host = match user_and_host.split_once('@') {
            Some((user, h)) => {
                if user.is_empty() || user.contains('/') || h.contains(['@', '/']) {
                    return None;
                }
                h
            }
            None => user_and_host,
        };
        if host.is_empty() || host.contains('/') {
            return None;
        }
        (host.to_string(), rest.to_string())
    };
    if let Some(r) = rest.strip_suffix('/') {
        rest = r.to_string();
    }
    if let Some(r) = rest.strip_suffix(".git") {
        rest = r.to_string();
    }
    let (head, name) = rest.rsplit_once('/')?;
    let owner = head.rsplit('/').next().unwrap_or(head);
    if owner.is_empty() || name.is_empty() {
        return None;
    }
    let host = host.to_lowercase();
    (!host.is_empty()).then(|| (host, format!("{owner}/{name}")))
}

/// `(^|[^[:alnum:]_.-])git[[:space:]]+([^;&|\n]*[[:space:]])?push([[:space:]]|$)` (git … push を 1 行の中で探す)
pub fn has_git_push(cmd: &str) -> bool {
    let c: Vec<char> = cmd.chars().collect();
    let n = c.len();
    let space = |x: char| matches!(x, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r');
    // 各位置から次の ; & | 改行 までの終わり (後ろから一度で求める)
    let mut stop = vec![n; n + 1];
    for i in (0..n).rev() {
        stop[i] = if matches!(c[i], ';' | '&' | '|' | '\n') { i } else { stop[i + 1] };
    }
    let push_at: Vec<usize> = (0..n.saturating_sub(3))
        .filter(|&p| {
            c[p..p + 4] == ['p', 'u', 's', 'h']
                && p > 0
                && space(c[p - 1])
                && (p + 4 == n || space(c[p + 4]))
        })
        .collect();
    for g in 0..n.saturating_sub(2) {
        if c[g..g + 3] != ['g', 'i', 't'] {
            continue;
        }
        if g > 0 && (c[g - 1].is_alphanumeric() || matches!(c[g - 1], '_' | '.' | '-')) {
            continue;
        }
        let mut q = g + 3;
        if q >= n || !space(c[q]) {
            continue;
        }
        while q < n && space(c[q]) {
            q += 1;
        }
        let end = stop[q.min(n)];
        let k = push_at.partition_point(|&p| p < q);
        if push_at.get(k).is_some_and(|&p| p < end) {
            return true;
        }
    }
    false
}

/// PowerShell の通す口 (`$env:NAME = 1`・`'1'`・`"1"`) か、bash の `NAME=1` がコマンドの文字にあるか
pub fn allow_in_text(cmd: &str, name: &str) -> bool {
    if cmd.contains(&format!("{name}=1")) {
        return true;
    }
    let mut from = 0;
    while let Some(i) = cmd[from..].find(name) {
        let rest = cmd[from + i + name.len()..].trim_start_matches([' ', '\t']);
        if let Some(v) = rest.strip_prefix('=') {
            let v = v.trim_start_matches([' ', '\t']);
            let v = v.trim_start_matches(['\'', '"']);
            if v.starts_with('1') {
                return true;
            }
        }
        from += i + name.len();
    }
    false
}

impl<'a> Xref<'a> {
    fn new(sys: &'a dyn Sys, cwd: &str, lang: Lang) -> Self {
        let w = World::new(sys, cwd);
        Xref {
            inh_repo: sys.env("GH_REPO").unwrap_or_default(),
            inh_host: sys.env("GH_HOST").unwrap_or_default(),
            w,
            lang,
            sections: Vec::new(),
            fixes: Vec::new(),
            vis_seen: HashMap::new(),
            pending_msgs: Vec::new(),
            amend_head: false,
            inh_allow: false,
            long_kb: 0,
            next_dir: String::new(),
            out_text: String::new(),
            out_known: false,
            last_out: String::new(),
            last_known: false,
            gh: None,
        }
    }

    /// dir の repo の remote の owner/repo
    fn remote_slugs(&mut self, dir: &str) -> Vec<String> {
        let mut out = Vec::new();
        for r in self.w.git_lines(dir, &[], &["remote"]) {
            if r.is_empty() {
                continue;
            }
            let (ok, u) = self.w.git(dir, &[], &["remote", "get-url", &r]);
            if ok && let Some((_, slug)) = url_parse(&u, self.w.win) {
                out.push(slug);
            }
        }
        out
    }

    /// 公開範囲を (PUBLIC・PRIVATE・INTERNAL か空、owner/repo、引けなかったわけ) で返す。同じ repo は 1 回の実行で 1 回だけ引く
    fn visibility(&mut self, dir: &str, target: &str) -> (String, String, String) {
        let key = if target.is_empty() {
            format!("dir:{dir}")
        } else {
            target.to_string()
        };
        if let Some(v) = self.vis_seen.get(&key) {
            return v.clone();
        }
        let result = self.lookup_visibility(dir, target);
        self.vis_seen.insert(key, result.clone());
        result
    }

    fn lookup_visibility(&mut self, dir: &str, target: &str) -> (String, String, String) {
        if self.gh.is_none() {
            self.gh = Some(self.w.sys.which("gh"));
        }
        let Some(Some(gh)) = self.gh.clone() else {
            return (String::new(), String::new(), "gh が見つからない".to_string());
        };
        if target.is_empty() && dir.starts_with(FOREIGN) {
            return (
                String::new(),
                String::new(),
                "WSL の中の repo は Windows の hook から確かめられない".to_string(),
            );
        }
        let run_dir = if Path::new(dir).is_dir() {
            dir.to_string()
        } else {
            self.w.cwd.clone()
        };
        let mut spec = CommandSpec::new(gh)
            .arg("repo")
            .arg("view")
            .current_dir(run_dir)
            .timeout(Duration::from_secs(10))
            .stdout_only();
        if !target.is_empty() {
            spec = spec.arg(target);
        }
        spec = spec.arg("--json").arg("nameWithOwner,visibility");
        let mut all: Vec<String> = Vec::new();
        let r = self.w.sys.run(&spec, &mut |l| all.push(l.to_string()));
        match r.exit {
            Exit::TimedOut => (String::new(), String::new(), "gh が 10 秒で返らなかった".to_string()),
            Exit::Code(0) => {
                let v: Option<Value> = serde_json::from_str(r.output.join("\n").trim()).ok();
                let vis = v
                    .as_ref()
                    .and_then(|v| v.get("visibility"))
                    .and_then(Value::as_str)
                    .map(str::to_ascii_uppercase)
                    .unwrap_or_default();
                let name = v
                    .as_ref()
                    .and_then(|v| v.get("nameWithOwner"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let why = if vis.is_empty() {
                    "gh の出力を読めない".to_string()
                } else {
                    String::new()
                };
                (vis, name, why)
            }
            other => {
                let first = all.iter().find(|l| !l.trim().is_empty()).cloned();
                let why = match (first, other) {
                    (Some(f), _) => format!("gh: {f}"),
                    (None, Exit::Code(c)) => format!("gh: 終了コード {c}"),
                    (None, Exit::SpawnFailed(m)) => format!("gh: {m}"),
                    (None, _) => "gh: 終了コード 1".to_string(),
                };
                (String::new(), String::new(), why)
            }
        }
    }

    /// 文を同じ repo (own) として調べる。参照があって、public か公開範囲を確かめられない repo なら、止める理由の節を足す
    fn check_texts(&mut self, label: &str, dir: &str, target: &str, hint: &str, texts: &[Text], own: &[String]) {
        if texts.is_empty() {
            return;
        }
        let own: Vec<String> = own.iter().map(|o| o.to_ascii_lowercase()).collect();
        let Some((fixes, lines)) = refs::report(texts, &own) else {
            return;
        };
        let (vis, vis_name, why) = self.visibility(dir, target);
        if vis == "PRIVATE" || vis == "INTERNAL" {
            return;
        }
        let mut name = if vis_name.is_empty() {
            target.split_once('/').map_or(target, |(_, r)| r).to_string()
        } else {
            vis_name
        };
        if name.is_empty() {
            name = if hint.is_empty() {
                "この dir の repo".to_string()
            } else {
                hint.to_string()
            };
        }
        let desc = if vis == "PUBLIC" {
            "public な repo".to_string()
        } else {
            format!("公開範囲を確かめられない: {why}")
        };
        self.sections.push(format!("{label} → {name} ({desc}):\n{lines}"));
        for f in fixes {
            if !self.fixes.contains(&f) {
                self.fixes.push(f);
            }
        }
    }

    /// gh の -R・GH_REPO の値から、同じ repo と公開範囲を引く repo を決める
    fn gh_target(v: &str, env_host: &str) -> (Vec<String>, String) {
        let v = v.strip_suffix('/').unwrap_or(v);
        let (host, slug) = if v.matches('/').count() >= 2 {
            let (h, s) = v.split_once('/').unwrap();
            (h.to_string(), s.to_string())
        } else {
            let h = if env_host.is_empty() { "github.com" } else { env_host };
            (h.to_string(), v.to_string())
        };
        (vec![slug.clone()], format!("{}/{slug}", host.to_lowercase()))
    }

    /// gh repo set-default が書く remote.<名前>.gh-resolved があれば、その repo を同じ repo と公開範囲を引く repo にする
    fn gh_default(&mut self, dir: &str) -> Option<(Vec<String>, String)> {
        for line in self
            .w
            .git_lines(dir, &[], &["config", "--get-regexp", "^remote\\..*\\.gh-resolved$"])
        {
            let line = line.trim_start();
            let (key, val) = match line.split_once([' ', '\t']) {
                Some((k, v)) => (k, v.trim()),
                None => (line, ""),
            };
            let name = key.strip_prefix("remote.").unwrap_or(key);
            let name = name.strip_suffix(".gh-resolved").unwrap_or(name);
            let (ok, u) = self.w.git(dir, &[], &["remote", "get-url", name]);
            let u = if ok { u } else { String::new() };
            if val == "base" {
                let Some((host, slug)) = url_parse(&u, self.w.win) else {
                    continue;
                };
                return Some((vec![slug.clone()], format!("{host}/{slug}")));
            } else if val.contains('/') {
                let host = url_parse(&u, self.w.win).map_or_else(|| "github.com".to_string(), |(h, _)| h);
                return Some((vec![val.to_string()], format!("{host}/{val}")));
            }
        }
        None
    }

    /// gh pr|issue … のタイトルと本文を調べる
    fn gh_cmd(&mut self, dir: &str, args: &[String], l: &Local) {
        let kind = format!(
            "{} {}",
            args.first().map_or("", String::as_str),
            args.get(1).map_or("", String::as_str)
        );
        let (vshort, vlong, mut head_t, mut head_b, mut suffix_b, mut md_b, fix_t, mut fix_b): (
            &str,
            &str,
            &str,
            &str,
            &str,
            bool,
            &str,
            &str,
        ) = match kind.as_str() {
            "pr create" => (
                "tbFRBHalmprT",
                "|title|body|body-file|repo|base|head|assignee|label|milestone|project|reviewer|template|recover|",
                "",
                "",
                "",
                true,
                "",
                "",
            ),
            "pr edit" => (
                "tbFRBm",
                "|title|body|body-file|repo|base|milestone|add-assignee|remove-assignee|add-label|remove-label|add-project|remove-project|add-reviewer|remove-reviewer|",
                "",
                "",
                "",
                true,
                "",
                "",
            ),
            "pr comment" | "issue comment" => ("bFR", "|body|body-file|repo|", "", "コメントの", "", true, "", ""),
            "pr review" => ("bFR", "|body|body-file|repo|", "", "review の本文の", "", true, "", ""),
            "pr merge" => (
                "tbFRA",
                "|subject|body|body-file|repo|match-head-commit|author-email|",
                "merge の commit の件名",
                "merge の commit の本文の",
                "",
                false,
                "",
                "title",
            ),
            "issue create" => (
                "tbFRalmpT",
                "|title|body|body-file|repo|assignee|label|milestone|project|template|recover|",
                "",
                "",
                "",
                true,
                "",
                "",
            ),
            "issue edit" => (
                "tbFRm",
                "|title|body|body-file|repo|milestone|add-assignee|remove-assignee|add-label|remove-label|add-project|remove-project|",
                "",
                "",
                "",
                true,
                "",
                "",
            ),
            _ => return,
        };
        if head_t.is_empty() {
            head_t = "タイトル";
        }
        if head_b.is_empty() {
            head_b = "本文の";
        }
        if kind != "pr merge" {
            suffix_b = " (backquote の外)";
            md_b = true;
            fix_b = "body";
        }
        let fix_t = if fix_t.is_empty() { "title" } else { fix_t };
        let a: &[String] = if args.len() > 2 { &args[2..] } else { &[] };
        let (mut title, mut title_set, mut body, mut body_set, mut body_file, mut bf_set) =
            (String::new(), false, String::new(), false, String::new(), false);
        let mut repo_flag = String::new();
        let (mut url_host, mut url_repo) = (String::new(), String::new());
        let mut flag = |name: &str, v: &str| match name {
            "t" | "title" | "subject" => {
                title = v.to_string();
                title_set = true;
            }
            "b" | "body" => {
                body = v.to_string();
                body_set = true;
            }
            "F" | "body-file" => {
                body_file = v.to_string();
                bf_set = true;
            }
            "R" | "repo" => repo_flag = v.to_string(),
            _ => {}
        };
        let mut i = 0;
        while i < a.len() {
            let x = &a[i];
            if x == "--" {
                break;
            } else if let Some(long) = x.strip_prefix("--") {
                if let Some((n, v)) = long.split_once('=') {
                    flag(n, v);
                } else if vlong.contains(&format!("|{long}|")) {
                    flag(long, a.get(i + 1).map_or("", String::as_str));
                    i += 1;
                }
            } else if x.len() >= 2 && x.starts_with('-') {
                // 束ねた短いオプション (-db x)。値を取るものが来たら、残りの文字 (頭の = は外す) か次の語が値
                let cs: Vec<char> = x.chars().collect();
                for k in 1..cs.len() {
                    let c = cs[k];
                    if !vshort.contains(c) {
                        continue;
                    }
                    let mut v: String = cs[k + 1..].iter().collect();
                    if v.is_empty() {
                        v = a.get(i + 1).cloned().unwrap_or_default();
                        i += 1;
                    }
                    let v = v.strip_prefix('=').map(str::to_string).unwrap_or(v);
                    flag(&c.to_string(), &v);
                    break;
                }
            } else if let Some((h, r)) = pr_url(x) {
                url_host = h;
                url_repo = r;
            }
            i += 1;
        }

        // 同じ repo と、公開範囲を引く repo。どれも無ければ dir の remote の repo を全部同じ repo とみなし、gh に dir で引かせる
        let mut hint = String::new();
        let (own, target): (Vec<String>, String) = if !url_repo.is_empty() {
            (vec![url_repo.clone()], format!("{url_host}/{url_repo}"))
        } else if !repo_flag.is_empty() {
            Self::gh_target(&repo_flag, &l.env_host)
        } else if !l.env_repo.is_empty() {
            Self::gh_target(&l.env_repo, &l.env_host)
        } else if let Some(d) = self.gh_default(dir) {
            d
        } else {
            let own = self.remote_slugs(dir);
            hint = own.first().cloned().unwrap_or_default();
            (own, String::new())
        };

        let mut texts = Vec::new();
        let text = |head: &str, suffix: &str, numbered: bool, md: bool, fix: &str, t: String| Text {
            head: head.to_string(),
            suffix: suffix.to_string(),
            numbered,
            md,
            fix: fix.to_string(),
            text: t,
        };
        if title_set {
            let v = self.w.expand_value(dir, &title);
            texts.push(text(head_t, "", false, false, fix_t, v));
        }
        if body_set {
            let v = self.w.expand_value(dir, &body);
            texts.push(text(head_b, suffix_b, true, md_b, fix_b, v));
        }
        if bf_set {
            if body_file == "-" || body_file == "/dev/stdin" {
                if l.in_known {
                    texts.push(text(head_b, suffix_b, true, md_b, fix_b, l.in_text.clone()));
                }
            } else if let Some(t) = self.w.read_file(dir, &body_file) {
                texts.push(text(head_b, suffix_b, true, md_b, fix_b, t));
            } else {
                // 読めないファイル (<( ) など) は、語の文字のまま数える
                texts.push(text(head_b, suffix_b, true, md_b, fix_b, body_file.clone()));
            }
        }
        self.check_texts(&format!("gh {kind}"), dir, &target, &hint, &texts, &own);
    }

    /// git push と、push より前に作る commit (git commit -m・-F) を見る
    fn git_cmd(&mut self, dir: &str, args: &[String], l: &Local) {
        let mut gdir = dir.to_string();
        let mut gopts: Vec<String> = Vec::new();
        let mut a: Vec<String> = args.to_vec();
        let mut sub = String::new();
        while let Some(first) = a.first().cloned() {
            match first.as_str() {
                "-C" => {
                    let target = a.get(1).cloned().unwrap_or_default();
                    gdir = self.w.join_dir(&gdir, &target, true);
                    a.drain(..2.min(a.len()));
                }
                "-c" | "--git-dir" | "--work-tree" | "--namespace" | "--config-env" => {
                    gopts.push(first.clone());
                    gopts.push(a.get(1).cloned().unwrap_or_default());
                    a.drain(..2.min(a.len()));
                }
                s if ["--git-dir=", "--work-tree=", "--namespace=", "--config-env="]
                    .iter()
                    .any(|p| s.starts_with(p)) =>
                {
                    gopts.push(first.clone());
                    a.remove(0);
                }
                s if s.starts_with('-') => {
                    a.remove(0);
                }
                _ => {
                    sub = first;
                    a.remove(0);
                    break;
                }
            }
        }
        // git gh <コマンド> (GitHub へ gh の資格情報で通す dotfiles の git-gh) は、後ろの語を git の語として読む
        if sub == "gh" {
            sub = a.first().cloned().unwrap_or_default();
            if !a.is_empty() {
                a.remove(0);
            }
        }
        if l.allow {
            return;
        }
        match sub.as_str() {
            "push" => self.push_job(&gdir, &gopts, &a),
            "commit" => self.commit_msg(&gdir, &a, l),
            _ => {}
        }
    }

    /// -m・--message (重ねたものは空行でつなぐ)・-F・--file の message を、後ろの push で数えるよう控える
    fn commit_msg(&mut self, dir: &str, a: &[String], l: &Local) {
        let mut msg = String::new();
        let mut have = false;
        let mut amend = false;
        let mut add_msg = |this: &mut Self, kind: char, v: &str| {
            let text = if kind == 'm' {
                Some(this.w.expand_value(dir, v))
            } else if v == "-" {
                l.in_known.then(|| l.in_text.clone())
            } else {
                this.w.read_file(dir, v)
            };
            if let Some(t) = text {
                if !msg.is_empty() {
                    msg.push_str("\n\n");
                }
                msg.push_str(&t);
                have = true;
            }
        };
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "--" => break,
                "--amend" => amend = true,
                _ if x.starts_with("--message=") => add_msg(self, 'm', &x["--message=".len()..]),
                _ if x.starts_with("--file=") => add_msg(self, 'F', &x["--file=".len()..]),
                "--message" | "--file" | "--reuse-message" | "--reedit-message" | "--template" | "--author" | "--date"
                | "--fixup" | "--squash" | "--trailer" => {
                    let v = a.get(i + 1).cloned().unwrap_or_default();
                    if x == "--message" {
                        add_msg(self, 'm', &v);
                    }
                    if x == "--file" {
                        add_msg(self, 'F', &v);
                    }
                    i += 1;
                }
                _ if x.len() >= 2 && x.starts_with('-') && !x.starts_with("--") => {
                    // 束ねた短いオプション (-am x・-mx)。値を取るもの (m・F・c・C・t) が来たら、残りの文字か次の語が値
                    let cs: Vec<char> = x.chars().collect();
                    for k in 1..cs.len() {
                        let c = cs[k];
                        if !"mFcCt".contains(c) {
                            continue;
                        }
                        let mut v: String = cs[k + 1..].iter().collect();
                        if v.is_empty() {
                            v = a.get(i + 1).cloned().unwrap_or_default();
                            i += 1;
                        }
                        if c == 'm' || c == 'F' {
                            add_msg(self, c, &v);
                        }
                        break;
                    }
                }
                _ => {}
            }
            i += 1;
        }
        // amend は HEAD を書き換える: 後ろの push では書き換える前の HEAD を数えない。message を変えない amend も新しい commit になる
        // (push すると跡がまた付く) ので、今の HEAD の message を数える
        if amend {
            self.amend_head = true;
            if !have {
                let (ok, m) = self.w.git(dir, &[], &["log", "-1", "--format=%B", "HEAD"]);
                if ok {
                    msg = m;
                    have = true;
                }
            }
        }
        if have {
            self.pending_msgs.push(msg);
        }
    }

    /// 押す commit (押す ref から辿れて、どの remote-tracking ref からも辿れないもの。新しい方から 1000 個) と、控えた message を調べる
    fn push_job(&mut self, dir: &str, gopts: &[String], a: &[String]) {
        let mut repo_opt = String::new();
        let (mut all, mut mirror, mut tags) = (false, false, false);
        let mut pos: Vec<String> = Vec::new();
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "--" => {
                    pos.extend(a[i + 1..].iter().cloned());
                    break;
                }
                // 削除・--dry-run は commit を送らない
                "-h" | "--help" | "-n" | "--dry-run" | "-d" | "--delete" => return,
                "--all" | "--branches" => all = true,
                "--mirror" => mirror = true,
                "--tags" => tags = true,
                _ if x.starts_with("--repo=") => repo_opt = x["--repo=".len()..].to_string(),
                "--repo" | "-o" | "--push-option" | "--receive-pack" | "--exec" => {
                    if x == "--repo" {
                        repo_opt = a.get(i + 1).cloned().unwrap_or_default();
                    }
                    i += 1;
                }
                _ if x.starts_with("--") => {}
                _ if x.starts_with('-') => {
                    // 束ねた短いオプション (-fu など)。-o は値を取る
                    let cs: Vec<char> = x.chars().collect();
                    for k in 1..cs.len() {
                        let c = cs[k];
                        if c == 'n' || c == 'd' {
                            return;
                        }
                        if c == 'o' {
                            if k + 1 >= cs.len() {
                                i += 1;
                            }
                            break;
                        }
                    }
                }
                _ => pos.push(x.to_string()),
            }
            i += 1;
        }

        // WSL の中の repo (Windows の hook から読めない): 押す先が private と分からなければ止める
        if dir.starts_with(FOREIGN) {
            let arg = pos.first().cloned().unwrap_or(repo_opt);
            let parsed = url_parse(&arg, false);
            if let Some((host, slug)) = &parsed {
                let cwd = self.w.cwd.clone();
                let (vis, _, _) = self.visibility(&cwd, &format!("{host}/{slug}"));
                if vis == "PRIVATE" || vis == "INTERNAL" {
                    return;
                }
            }
            let name = parsed.map_or_else(|| "WSL の中の repo".to_string(), |(_, s)| s);
            self.sections.push(format!(
                "git push → {name} (公開範囲を確かめられない: WSL の中の repo は Windows の hook から確かめられない):\n- 押す commit の message を確かめられない"
            ));
            if !self.fixes.iter().any(|f| f == "wsl") {
                self.fixes.push("wsl".to_string());
            }
            return;
        }

        // 押す先: 引数・--repo、無ければ branch.<今>.pushRemote → remote.pushDefault → branch.<今>.remote → origin
        let mut remote = pos.first().cloned().filter(|s| !s.is_empty()).unwrap_or(repo_opt);
        let (ok, cur) = self.w.git(dir, gopts, &["symbolic-ref", "-q", "--short", "HEAD"]);
        let cur = if ok { cur } else { String::new() };
        if remote.is_empty() {
            if !cur.is_empty() {
                remote = self.w.git(dir, gopts, &["config", "--get", &format!("branch.{cur}.pushRemote")]).1;
            }
            if remote.is_empty() {
                remote = self.w.git(dir, gopts, &["config", "--get", "remote.pushDefault"]).1;
            }
            if remote.is_empty() && !cur.is_empty() {
                remote = self.w.git(dir, gopts, &["config", "--get", &format!("branch.{cur}.remote")]).1;
            }
            if remote.is_empty() {
                remote = "origin".to_string();
            }
        }
        let url = if !remote.contains('/')
            && !self
                .w
                .git(dir, gopts, &["config", "--get", &format!("remote.{remote}.url")])
                .1
                .is_empty()
        {
            self.w.git(dir, gopts, &["remote", "get-url", "--push", &remote]).1
        } else {
            self.w.git(dir, gopts, &["ls-remote", "--get-url", &remote]).1
        };
        // 手元の path・file:// は GitHub に届かないので見ない
        let Some((url_host, url_slug)) = url_parse(if url.is_empty() { &remote } else { &url }, self.w.win) else {
            return;
        };

        // 押す ref: refspec の左 (+・tag <名前>・glob も)。無ければ remote.<名前>.push、それも無ければ HEAD
        let mut specs: Vec<String> = pos.iter().skip(1).cloned().collect();
        let mut revs: Vec<String> = Vec::new();
        if mirror
            || self
                .w
                .git(dir, gopts, &["config", "--type=bool", "--get", &format!("remote.{remote}.mirror")])
                .1
                == "true"
        {
            revs.push("--all".to_string());
        }
        if all {
            revs.push("--branches".to_string());
        }
        if tags {
            revs.push("--tags".to_string());
        }
        if specs.is_empty() && revs.is_empty() {
            specs = self
                .w
                .git_lines(dir, gopts, &["config", "--get-all", &format!("remote.{remote}.push")]);
            if specs.is_empty() {
                specs = vec!["HEAD".to_string()];
            }
        }
        let mut k = 0;
        while k < specs.len() {
            let mut src = specs[k].strip_prefix('+').unwrap_or(&specs[k]).to_string();
            if src == "tag" {
                src = format!("refs/tags/{}", specs.get(k + 1).map_or("", String::as_str));
                k += 1;
            }
            k += 1;
            if src.starts_with('^') {
                continue;
            }
            let src = src.split(':').next().unwrap_or("").to_string();
            if src.is_empty() {
                continue;
            }
            if src.contains('*') {
                revs.push(format!("--glob={src}"));
                continue;
            }
            let expanded = self.w.expand_value(dir, &src);
            let (ok, r) = self
                .w
                .git(dir, gopts, &["rev-parse", "--verify", "-q", &format!("{expanded}^{{commit}}")]);
            if ok {
                revs.push(r);
            } else {
                // 解けない ref (同じコマンドで作る branch・$( )・変数) は、HEAD から作るものとみなす
                let (ok, r) = self.w.git(dir, gopts, &["rev-parse", "--verify", "-q", "HEAD^{commit}"]);
                if ok {
                    revs.push(r);
                }
            }
        }
        // 同じコマンドの amend で書き換える HEAD は数えず、その親から辿る (新しい message は pending_msgs で数える)
        if self.amend_head {
            let (ok, head) = self.w.git(dir, gopts, &["rev-parse", "--verify", "-q", "HEAD^{commit}"]);
            if ok {
                let mut kept = Vec::new();
                for r in revs {
                    if r == head {
                        kept.extend(self.w.git_lines(dir, gopts, &["rev-parse", "HEAD^@"]));
                    } else {
                        kept.push(r);
                    }
                }
                revs = kept;
            }
        }

        let mut texts: Vec<Text> = Vec::new();
        if !revs.is_empty() {
            let mut args: Vec<&str> = vec!["log", "--no-color", "--format=%H%x1f%B%x1e", "--max-count=1000"];
            args.extend(revs.iter().map(String::as_str));
            args.extend(["--not", "--remotes", "--"]);
            let (_, log) = self.w.git(dir, gopts, &args);
            texts = refs::log_texts(&log);
        }
        for m in self.pending_msgs.clone() {
            texts.push(Text {
                head: "これから作る commit (git commit) の".to_string(),
                suffix: String::new(),
                numbered: true,
                md: false,
                fix: "commit".to_string(),
                text: m,
            });
        }
        let target = format!("{url_host}/{url_slug}");
        self.check_texts("git push", dir, &target, &url_slug.clone(), &texts, &[url_slug]);
    }

    /// bash -c などに文字列で渡したものを読み直す。頭の VAR=値 (通す口・GH_REPO・GH_HOST) は中にも効かせる
    fn rescan(&mut self, dir: &str, depth: usize, s: &str, lang: Lang, l: &Local) {
        let saved = (self.inh_allow, self.inh_repo.clone(), self.inh_host.clone());
        self.inh_allow = l.allow;
        self.inh_repo = l.env_repo.clone();
        self.inh_host = l.env_host.clone();
        self.scan_command(dir, depth + 1, s, lang);
        (self.inh_allow, self.inh_repo, self.inh_host) = saved;
    }

    /// 単純コマンドを 1 つ見る。cd なら next_dir に行き先を入れ、出力 (パイプの先の stdin・> f の中身) が分かれば out_text・out_known に入れる
    fn simple(&mut self, dir: &str, depth: usize, rec: &super::lex::Cmd) {
        let mut dir = dir.to_string();
        let ci = self.w.win || rec.ps;
        let mut w: Vec<String> = rec.words.clone();
        let mut l = Local {
            allow: self.inh_allow,
            env_repo: self.inh_repo.clone(),
            env_host: self.inh_host.clone(),
            ..Local::default()
        };
        match &rec.stdin {
            super::lex::Stdin::Here(t) => {
                l.in_text = t.clone();
                l.in_known = true;
            }
            super::lex::Stdin::File(p) => {
                if let Some(t) = self.w.read_file(&dir, p) {
                    l.in_text = t;
                    l.in_known = true;
                }
            }
            super::lex::Stdin::None => {
                if rec.pipe {
                    l.in_text = self.last_out.clone();
                    l.in_known = self.last_known;
                }
            }
        }

        // 頭の VAR=値 と予約語
        let mut assigns: Vec<String> = Vec::new();
        while let Some(first) = w.first().cloned() {
            if let Some(v) = first.strip_prefix("PJP_ALLOW_XREF=") {
                if v == "1" {
                    l.allow = true;
                }
            } else if let Some(v) = first.strip_prefix("GH_REPO=") {
                l.env_repo = v.to_string();
            } else if let Some(v) = first.strip_prefix("GH_HOST=") {
                l.env_host = v.to_string();
            } else if matches!(
                first.as_str(),
                "!" | "{" | "}" | "if" | "then" | "else" | "elif" | "do" | "while" | "until"
            ) {
            } else if matches!(
                first.as_str(),
                "for" | "case" | "select" | "function" | "fi" | "done" | "esac" | "[[" | "["
            ) {
                return;
            } else if let Some((name, _)) = first.split_once('=') {
                if !is_name(name) {
                    break;
                }
                assigns.push(first.clone());
            } else {
                break;
            }
            w.remove(0);
        }
        if w.is_empty() {
            // 代入だけの単純コマンドは、後ろの "$NAME" のために覚える
            self.w.remember(&assigns);
            return;
        }

        // 包むコマンドを外す。中に文字列で渡すものは読み直す
        let mut guard = 0;
        while !w.is_empty() && guard < 16 {
            guard += 1;
            let mut name = base_name(&w[0], ci);
            if rec.ps {
                name = ps_alias(&name).to_string();
            }
            match name.as_str() {
                "cd" | "pushd" => {
                    self.next_dir = if w.len() > 1 {
                        let last = w[w.len() - 1].clone();
                        self.w.join_dir(&dir, &last, true)
                    } else {
                        self.w.home.clone()
                    };
                    return;
                }
                "export" => {
                    self.w.remember(&w[1..]);
                    return;
                }
                "env" => {
                    w.remove(0);
                    while let Some(first) = w.first().cloned() {
                        match first.as_str() {
                            "-u" | "--unset" | "-C" | "--chdir" | "-S" | "--split-string" => {
                                w.drain(..2.min(w.len()));
                            }
                            _ if first.starts_with("PJP_ALLOW_XREF=")
                                || first.starts_with("GH_REPO=")
                                || first.starts_with("GH_HOST=") =>
                            {
                                if first == "PJP_ALLOW_XREF=1" {
                                    l.allow = true;
                                } else if let Some(v) = first.strip_prefix("GH_REPO=") {
                                    l.env_repo = v.to_string();
                                } else if let Some(v) = first.strip_prefix("GH_HOST=") {
                                    l.env_host = v.to_string();
                                }
                                w.remove(0);
                            }
                            _ if first.starts_with('-') || first.contains('=') => {
                                w.remove(0);
                            }
                            _ => break,
                        }
                    }
                }
                "sudo" | "doas" => {
                    w.remove(0);
                    skip_opts(&mut w, &["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R"]);
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
                    skip_opts(&mut w, &["-i", "-o", "-e", "--input", "--output", "--error"]);
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
                            "-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a", "--max-args", "--max-procs", "--max-lines",
                            "--delimiter", "--eof", "--max-chars", "--arg-file",
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
                    // -c は lock のファイルの後ろにも置ける (flock FILE -c CMD)
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
                "bash" | "sh" | "zsh" | "dash" | "ksh" | "fish" => {
                    let mut i = 1;
                    while i < w.len() {
                        let x = w[i].as_str();
                        match x {
                            "-o" | "+o" | "-O" | "+O" => i += 1,
                            _ if x.starts_with('-') => {
                                if is_c_flag(x) {
                                    let s = w.get(i + 1).cloned().unwrap_or_default();
                                    self.rescan(&dir, depth, &s, Lang::Bash, &l);
                                    return;
                                }
                            }
                            _ => return,
                        }
                        i += 1;
                    }
                    // -c も script のファイルも無い shell (bash <<EOF・bash -s・cat … | bash) は stdin を読む
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
                    if let Some(i) = w.iter().skip(1).position(|x| x == "--run" || x == "--command") {
                        let s = w.get(i + 2).cloned().unwrap_or_default();
                        self.rescan(&dir, depth, &s, Lang::Bash, &l);
                        return;
                    }
                    break;
                }
                "nix" => {
                    if matches!(w.get(1).map(String::as_str), Some("develop" | "shell"))
                        && let Some(i) = w.iter().skip(2).position(|x| x == "-c" || x == "--command")
                    {
                        w.drain(..i + 3);
                        continue;
                    }
                    break;
                }
                // Windows: PowerShell・cmd の中のコマンド、WSL の中のコマンド
                "pwsh" | "powershell" => {
                    if let Some(s) = pwsh_command(&w[1..]) {
                        self.rescan(&dir, depth, &s, Lang::PowerShell, &l);
                    }
                    return;
                }
                "cmd" => {
                    if let Some(s) = cmd_command(&w[1..]) {
                        self.rescan(&dir, depth, &s, Lang::Bash, &l);
                    }
                    return;
                }
                "wsl" => {
                    w = wsl_command(&w[1..]);
                    dir = FOREIGN.to_string();
                }
                "invoke-expression" if rec.ps => {
                    let mut rest: Vec<String> = w[1..].to_vec();
                    if rest.first().is_some_and(|x| "-command".starts_with(&x.to_lowercase()) && x.len() > 1) {
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
        match name.as_str() {
            "git" => self.git_cmd(&dir, &w[1..], &l),
            "gh" => {
                if !l.allow {
                    self.gh_cmd(&dir, &w[1..], &l);
                }
            }
            "cat" => {
                if w.len() == 1 || w[1] == "-" {
                    self.out_text = l.in_text.clone();
                    self.out_known = l.in_known;
                } else if let Some(t) = self.w.read_file(&dir, &w[1]) {
                    self.out_text = t;
                    self.out_known = true;
                }
            }
            "echo" | "printf" => {
                self.out_text = w[1..].join(" ");
                self.out_known = true;
            }
            "tee" => {
                self.out_text = l.in_text.clone();
                self.out_known = l.in_known;
                for a in &w[1..] {
                    if !a.starts_with('-') {
                        self.w.remember_write(&dir, a, l.in_known, &l.in_text);
                    }
                }
            }
            // PowerShell の Get-Content・Tee-Object・Set-Content (Out-File・Add-Content)
            "get-content" => {
                let (named, pos) = ps_params(&w[1..], &["raw", "force", "wait", "asbytestream"]);
                if let Some(p) = ps_named(&named, &["path", "literalpath"]).map(str::to_string).or(pos.first().cloned())
                    && let Some(t) = self.w.read_file(&dir, &p)
                {
                    self.out_text = t;
                    self.out_known = true;
                }
            }
            "tee-object" => {
                self.out_text = l.in_text.clone();
                self.out_known = l.in_known;
                let (named, pos) = ps_params(&w[1..], &["append"]);
                if let Some(p) = ps_named(&named, &["filepath", "literalpath", "path"]).map(str::to_string).or(pos.first().cloned()) {
                    self.w.remember_write(&dir, &p, l.in_known, &l.in_text);
                }
            }
            "set-content" | "out-file" => {
                if let Some((p, known, v)) = super::ps_write_target(&name, &w[1..], &l.in_text, l.in_known) {
                    self.w.remember_write(&dir, &p, known, &v);
                }
            }
            _ => {}
        }
        if !rec.outf.is_empty() {
            let (known, text) = (self.out_known, self.out_text.clone());
            self.w.remember_write(&dir, &rec.outf, known, &text);
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

    /// 読む長さを超えたコマンドは中を読まず、文字のどこかに参照か git … push があれば止める (dir の repo が private・internal なら通す)
    fn long_command(&mut self, kb: usize, cmd: &str) {
        let allowed = match self.lang {
            Lang::Bash => cmd.contains("PJP_ALLOW_XREF=1"),
            Lang::PowerShell => allow_in_text(cmd, "PJP_ALLOW_XREF"),
        };
        if allowed {
            return;
        }
        self.long_kb = kb;
        let cwd = self.w.cwd.clone();
        let own = self.remote_slugs(&cwd);
        let texts = vec![Text {
            head: "コマンドの".to_string(),
            suffix: String::new(),
            numbered: true,
            md: false,
            fix: "long".to_string(),
            text: cmd.to_string(),
        }];
        let hint = own.first().cloned().unwrap_or_default();
        self.check_texts("コマンドの文字", &cwd, "", &hint, &texts, &own);
        if !self.sections.is_empty() || !has_git_push(cmd) {
            return;
        }
        let (vis, vis_name, why) = self.visibility(&cwd, "");
        if vis == "PRIVATE" || vis == "INTERNAL" {
            return;
        }
        let name = if !vis_name.is_empty() {
            vis_name
        } else if !hint.is_empty() {
            hint
        } else {
            "この dir の repo".to_string()
        };
        let desc = if vis == "PUBLIC" {
            "public な repo".to_string()
        } else {
            format!("公開範囲を確かめられない: {why}")
        };
        self.sections
            .push(format!("git push → {name} ({desc}):\n- 押す commit の message を確かめられない"));
    }

    fn emit(&self) -> String {
        let has = |f: &str| self.fixes.iter().any(|x| x == f);
        let mut msg = if self.long_kb > 0 {
            format!(
                "[xref-guard] コマンドが長すぎて ({} KB。中を読むのは {} KB まで) 中を読めず、ほかの repo への参照か git push があるので止めた。",
                self.long_kb,
                LEX_LIMIT / 1024
            )
        } else {
            "[xref-guard] ほかの repo の issue・PR・commit への参照を書こうとしているので止めた。".to_string()
        };
        msg.push_str("GitHub は参照先の timeline に跡を残し、付いた跡は本文を直しても force push で commit を外しても消えない。");
        for s in &self.sections {
            msg.push_str("\n\n");
            msg.push_str(s);
        }
        msg.push_str("\n\n直し方:");
        if self.long_kb > 0 {
            msg.push_str("\n- PR・issue の本文はファイルに書いて --body-file で渡し、git push は別のコマンドで打つ (短いコマンドなら、中を読んで本文と押す commit の参照を確かめる)");
        }
        if has("long") {
            msg.push_str("\n- 参照は、commit の message とタイトルからは消し (「nixpkgs の PR 577218」のように言葉で書く)、本文とコメントでは backquote で囲む");
        }
        if has("commit") {
            msg.push_str("\n- commit の message からは参照を消し、「nixpkgs の PR 577218」のように # も URL も使わずに書く (commit の message は Markdown ではないので、backquote で囲んでも跡が付く)。参照は PR の本文に backquote で囲んで書く");
            msg.push_str("\n- 直前の commit なら git commit --amend、前の commit なら git rebase で message を書き換えてから push し直す (同じコマンドで作る commit なら、-m の文を直す)");
        }
        if has("title") {
            msg.push_str("\n- タイトルからは消す (merge の commit の件名・本文も。backquote で囲んでも、merge の commit の message に写って跡が付く)。「nixpkgs の PR 577218」のように言葉で書き、参照は本文に backquote で囲んで書く");
        }
        if has("body") {
            msg.push_str("\n- 本文・コメントの参照は backquote で囲む (`owner/repo#123` の形の inline code にする)。[文](URL) のリンクにもしない");
        }
        if has("wsl") {
            msg.push_str("\n- WSL の中の repo への push は、WSL の Claude の会話 (hc の子) で打つ (WSL の hook が押す commit の message を読んで確かめる)");
        }
        if self.lang == Lang::PowerShell {
            msg.push_str("\n- ユーザーがこの参照を書くと明示したときだけ、コマンドの頭に $env:PJP_ALLOW_XREF='1'; を付けて打ち直す (PowerShell の tool。Bash の tool なら PJP_ALLOW_XREF=1。自分の判断では付けない)");
        } else {
            msg.push_str("\n- ユーザーがこの参照を書くと明示したときだけ、コマンドの頭に PJP_ALLOW_XREF=1 を付けて打ち直す (自分の判断では付けない)");
        }
        msg
    }
}

/// `^-[A-Za-z]*c[A-Za-z]*$` (bash -c・-lc・-ec など)
pub fn is_c_flag(x: &str) -> bool {
    x.len() >= 2
        && x.starts_with('-')
        && x[1..].chars().all(|c| c.is_ascii_alphabetic())
        && x[1..].contains('c')
}

/// `^https?://([^/]+)/([^/]+)/([^/]+)/(pull|issues)/[0-9]+` の (host (小文字)、owner/repo)
fn pr_url(x: &str) -> Option<(String, String)> {
    let rest = x.strip_prefix("https://").or_else(|| x.strip_prefix("http://"))?;
    let parts: Vec<&str> = rest.splitn(5, '/').collect();
    if parts.len() == 5
        && parts[..3].iter().all(|p| !p.is_empty())
        && matches!(parts[3], "pull" | "issues")
        && parts[4].starts_with(|c: char| c.is_ascii_digit())
    {
        return Some((parts[0].to_lowercase(), format!("{}/{}", parts[1], parts[2])));
    }
    None
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - remote の URL の読み方 (https・ssh・scp の形・手元の path・Windows の手元の path)
    //! - 長いコマンドの git … push の探し方 (1 行の中だけ・語の頭)
    //! - PowerShell の tool のコマンド (here-string の本文・$env: の通す口・Set-Location・Set-Content で書いた本文) を bash と同じに読む。
    //!   止める文の通す口は PowerShell の形。wsl の後ろの git push は止める
    //! - bash の版の試験 (nix/tests/xref-guard.test.sh) をこの口に流して通る (`tests/guard_suites.rs`。bash と jq と git がある Linux)

    use super::*;
    use crate::process::{RealSys, RunResult};
    use crate::testutil::{FakeSys, TempDir};
    use serde_json::json;
    use std::process::Command;

    #[test]
    fn parses_remote_urls() {
        let p = |u: &str| url_parse(u, false);
        assert_eq!(p("https://github.com/o/r.git"), Some(("github.com".into(), "o/r".into())));
        assert_eq!(p("git@github.com:o/r.git"), Some(("github.com".into(), "o/r".into())));
        assert_eq!(p("ssh://git@GitHub.com:22/o/r/"), Some(("github.com".into(), "o/r".into())));
        assert_eq!(p("https://github.com"), None);
        assert_eq!(p("/tmp/bare.git"), None);
        assert_eq!(p("../bare.git"), None);
        assert_eq!(url_parse("C:/Users/u/bare.git", true), None);
        assert_eq!(url_parse("C:\\Users\\u\\bare.git", true), None);
        assert_eq!(url_parse("\\\\srv\\share\\r.git", true), None);
    }

    #[test]
    fn finds_git_push_in_text() {
        assert!(has_git_push("x; git push"));
        assert!(has_git_push("git -C repo push -u origin x"));
        assert!(has_git_push("git\n push"));
        assert!(!has_git_push("git stash; push"));
        assert!(!has_git_push("mygit push"));
        assert!(!has_git_push("git pushx"));
        assert!(!has_git_push("git log --grep x\npush"));
    }

    fn git(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", if cfg!(windows) { "NUL" } else { "/dev/null" })
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@example.com")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@example.com")
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    }

    /// public な repo の clone (commit は remote-tracking ref に無い 1 つ)。gh は偽物で、公開範囲は `vis` を返す
    fn setup(t: &TempDir, msg: &str) -> PathBuf {
        let r = t.path().join("repo");
        std::fs::create_dir_all(&r).unwrap();
        git(&r, &["init", "-q", "-b", "main"]);
        git(&r, &["remote", "add", "origin", "https://github.com/pollenjp/dotfiles.git"]);
        git(&r, &["commit", "-q", "--allow-empty", "-m", "init"]);
        git(&r, &["update-ref", "refs/remotes/origin/main", "HEAD"]);
        git(&r, &["switch", "-q", "-c", "feat"]);
        git(&r, &["commit", "-q", "--allow-empty", "-m", msg]);
        r
    }

    fn sys(vis: &'static str) -> FakeSys {
        FakeSys::new(move |spec| {
            if spec.program.to_string_lossy().contains("fake-gh") {
                return RunResult {
                    exit: Exit::Code(0),
                    output: vec![format!("{{\"nameWithOwner\":\"pollenjp/dotfiles\",\"visibility\":\"{vis}\"}}")],
                };
            }
            RealSys.run(spec, &mut |_| {})
        })
        .with_program("gh", "/fake-gh")
        .with_program("git", "git")
    }

    fn input(tool: &str, cmd: &str, cwd: &Path) -> (String, Value) {
        let v = json!({"tool_name": tool, "tool_input": {"command": cmd}, "cwd": cwd.to_string_lossy()});
        (v.to_string(), v)
    }

    fn reason(out: Option<String>) -> Option<String> {
        let v: Value = serde_json::from_str(out?.trim()).ok()?;
        v["hookSpecificOutput"]["permissionDecisionReason"].as_str().map(str::to_string)
    }

    #[test]
    fn powershell_commands() {
        let t = TempDir::new("xref-ps");
        let r = setup(&t, "fix: see NixOS/nixpkgs#577218");
        let s = sys("PUBLIC");
        let deny = |cmd: &str| {
            let (raw, v) = input("PowerShell", cmd, &r);
            reason(run(&raw, &v, &s))
        };
        let why = deny("git push -u origin feat").expect("push を止める");
        assert!(why.contains("NixOS/nixpkgs#577218"), "{why}");
        assert!(why.contains("$env:PJP_ALLOW_XREF='1';"), "{why}");
        assert!(deny("$env:PJP_ALLOW_XREF = '1'; git push").is_none());
        let why = deny("gh pr create --title x --body @'\n## 概要\n- NixOS/nixpkgs#1 を待つ\n'@").expect("本文の参照");
        assert!(why.contains("本文の 2 行目 (backquote の外): NixOS/nixpkgs#1"), "{why}");
        assert!(deny("gh pr create --title x --body @'\n- `NixOS/nixpkgs#1`\n'@").is_none());
        assert!(deny("$b = @'\nNixOS/nixpkgs#2\n'@\ngh pr create -t x -b $b").is_some());
        assert!(deny("Set-Content -Path b.md -Value 'NixOS/nixpkgs#3'; gh pr create -t x --body-file b.md").is_some());
        assert!(deny("@'\nNixOS/nixpkgs#4\n'@ | gh pr create -t x -F -").is_some());
        assert!(deny("Set-Location ..; git -C repo push").is_some());
        assert!(deny("pwsh -NoProfile -Command \"git push\"").is_some());
        let why = deny("wsl -d u24 -- git push").expect("WSL の中の push は止める");
        assert!(why.contains("WSL の中の repo"), "{why}");
        assert!(deny("gh pr view 1").is_none());
        // Bash の tool の文は bash の版と同じ通す口
        let (raw, v) = input("Bash", "git push", &r);
        let why = reason(run(&raw, &v, &s)).unwrap();
        assert!(why.ends_with("コマンドの頭に PJP_ALLOW_XREF=1 を付けて打ち直す (自分の判断では付けない)"), "{why}");
        // private な repo は通す
        let p = sys("PRIVATE");
        let (raw, v) = input("PowerShell", "git push", &r);
        assert!(run(&raw, &v, &p).is_none());
    }
}
