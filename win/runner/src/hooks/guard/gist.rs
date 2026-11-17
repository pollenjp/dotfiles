//! gist-guard (PreToolUse・matcher Bash|PowerShell と mcp__.*[Gg]ist.*): gist やペースト共有のサービス (0x0.st・transfer.sh・termbin など) へ上げる
//! コマンドと、gist を作る・書き換える MCP の tool を、打つ前にいつも止める。Linux の `nix/files/claude/hooks/gist-guard.sh` (dotfiles-private の
//! ADR 047) の写しで、止めるもの・通すもの・返す文は bash の版と同じ (Linux の CI が bash の版の試験 `nix/tests/gist-guard.test.sh` をこの口に流す)。
//! 通す口は作らない (Claude が自分で付けられてしまう)。
//!
//! Windows だけの足し (bash の版に無い。dotfiles-private の docs/adr/067_win_hook_guards_*): PowerShell の tool も読み、`Invoke-WebRequest`・
//! `Invoke-RestMethod` (`iwr`・`irm`。Windows PowerShell 5.1 の `curl`・`wget` も) で gist の API・ペースト共有のサービスへ送るものも止める。
//! `pwsh -Command`・`cmd /c`・`wsl` の後ろも読む。

use super::{
    FOREIGN, LEX_LIMIT, Lang, World, base_name, cmd_command, deny, ps_alias, ps_named, ps_params,
    ps_write_target, pwsh_command, skip_opts, split, wsl_command,
};
use crate::hooks::field;
use crate::process::Sys;
use serde_json::Value;
use std::collections::HashMap;

/// ペースト共有のサービス: host がこの domain か、その sub-domain なら止める
const PASTE_HOSTS: &[&str] = &[
    // テキスト
    "pastebin.com",
    "paste.rs",
    "dpaste.com",
    "dpaste.org",
    "sprunge.us",
    "termbin.com",
    "ix.io",
    "bpa.st",
    "paste.debian.net",
    "paste.ubuntu.com",
    "rentry.co",
    "rentry.org",
    "hastebin.com",
    "paste.ee",
    "clbin.com",
    // ファイル
    "0x0.st",
    "transfer.sh",
    "temp.sh",
    "catbox.moe",
    "file.io",
    "tmpfiles.org",
    "bashupload.com",
    "oshi.at",
    "x0.at",
    "uguu.se",
    "envs.sh",
];

/// ペースト共有のサービスか gist へ上げる専用のコマンド
const PASTE_CLIS: &[&str] = &[
    "pastebinit",
    "wgetpaste",
    "fpaste",
    "gist",
    "gist-paste",
    "haste",
    "nopaste",
];

pub fn run(raw: &str, input: &Value, sys: &dyn Sys) -> Option<String> {
    // 安い前段: 上げる形の語が無い入力は読まない (この hook は Bash のたびに走る)
    let lc = raw.to_lowercase();
    let keys = ["gist", "push", "snippet", "/dev/tcp/", "/dev/udp/"];
    if !keys
        .iter()
        .chain(PASTE_HOSTS)
        .chain(PASTE_CLIS)
        .any(|k| lc.contains(k))
    {
        return None;
    }
    let event = field(input, &["hook_event_name"]);
    if !event.is_empty() && event != "PreToolUse" {
        return None;
    }
    let tool = field(input, &["tool_name"]);
    let cwd = field(input, &["cwd"]);
    let mut g = Gist::new(sys, &cwd);
    if tool.starts_with("mcp__") {
        g.mcp_tool(&tool);
        return (!g.found.is_empty()).then(|| deny(&g.emit()));
    }
    let lang = match tool.as_str() {
        "Bash" => Lang::Bash,
        "PowerShell" => Lang::PowerShell,
        _ => return None,
    };
    let cmd = field(input, &["tool_input", "command"]);
    if cmd.is_empty() {
        return None;
    }
    let bytes = cmd.len();
    if bytes > LEX_LIMIT {
        g.long_command(bytes.div_ceil(1024), &cmd);
    } else {
        let dir = g.w.cwd.clone();
        g.scan_command(&dir, 0, &cmd, lang);
    }
    (!g.found.is_empty()).then(|| deny(&g.emit()))
}

/// URL の分類 (gist の API・gist の repo・ペースト共有のサービス)
#[derive(Clone, Debug, PartialEq, Eq)]
enum Kind {
    GistApi,
    GistGit,
    Paste,
}

#[derive(Clone, Debug)]
struct Url {
    kind: Kind,
    host: String,
    svc: String,
}

impl Url {
    /// 「host (ペースト共有のサービス[ 一覧の domain])」
    fn paste_label(&self) -> String {
        if self.host == self.svc {
            format!("{} (ペースト共有のサービス)", self.host)
        } else {
            format!("{} (ペースト共有のサービス {})", self.host, self.svc)
        }
    }
}

/// gist の API・gist・ペースト共有のサービスの URL (か host) なら、その分類。scheme の無いもの (curl の 0x0.st・api.github.com/gists) と、git の
/// scp の形 (git@gist.github.com:<id>.git) も読む。gist.githubusercontent.com (raw を読むだけ) は数えない
fn classify_url(u: &str) -> Option<Url> {
    let rest = if let Some((_, r)) = u.split_once("://") {
        r
    } else if let Some(r) = u.strip_prefix("//") {
        r
    } else {
        u
    };
    let hp_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let mut hostport = &rest[..hp_end];
    let mut path = rest[hp_end..].to_string();
    hostport = hostport.rsplit('@').next().unwrap_or(hostport);
    let mut host = hostport.split(':').next().unwrap_or(hostport).to_string();
    // :443 は port、:<id>.git・:gist は scp の形の path
    if let Some((_, after)) = hostport.split_once(':')
        && !after.chars().all(|c| c.is_ascii_digit())
    {
        path = format!("/{after}{path}");
    }
    if let Some(h) = host.strip_suffix('.') {
        host = h.to_string();
    }
    let host = host.to_lowercase();
    if !host.contains('.')
        || !host
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-')
    {
        return None;
    }
    let path = path.split(['?', '#']).next().unwrap_or("").to_lowercase();
    let url = |kind: Kind, svc: &str| Url {
        kind,
        host: host.clone(),
        svc: svc.to_string(),
    };
    if path == "/api/v3/gists"
        || path.starts_with("/api/v3/gists/")
        || (host == "api.github.com" && (path == "/gists" || path.starts_with("/gists/")))
    {
        return Some(url(Kind::GistApi, ""));
    }
    if host == "gist.githubusercontent.com" {
        return None;
    }
    if host.starts_with("gist.") || path.starts_with("/gist/") {
        return Some(url(Kind::GistGit, ""));
    }
    PASTE_HOSTS
        .iter()
        .find(|d| host == **d || host.ends_with(&format!(".{d}")))
        .map(|d| url(Kind::Paste, d))
}

/// gh api の endpoint が gists (gists・/gists/…・full URL・GHES の api/v3/gists) か
fn gists_endpoint(e: &str) -> bool {
    if e.contains("://") {
        return classify_url(e).is_some_and(|u| u.kind == Kind::GistApi);
    }
    let e = e.strip_prefix('/').unwrap_or(e);
    let e = e.split(['?', '#']).next().unwrap_or("").to_lowercase();
    let e = e.strip_prefix("api/v3/").unwrap_or(&e);
    e == "gists" || e.starts_with("gists/")
}

fn is_url_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || "._~:/?#@!$&*+=%-".contains(c)
}

fn is_scheme_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-')
}

/// `[A-Za-z][A-Za-z0-9+.-]*://[A-Za-z0-9._~:/?#@!$&*+=%-]+` に当たる (始まり, 終わり) を 1 行の中から (grep -Eo と同じく左から重ねずに)
fn url_spans(line: &[char]) -> Vec<(usize, usize)> {
    let n = line.len();
    let mut out = Vec::new();
    let mut from = 0;
    let mut i = 0;
    while i + 2 < n {
        if line[i] == ':' && line[i + 1] == '/' && line[i + 2] == '/' && i >= from {
            let mut s = i;
            while s > from && is_scheme_char(line[s - 1]) {
                s -= 1;
            }
            // scheme は英字で始まる (左端の英字から)
            while s < i && !line[s].is_ascii_alphabetic() {
                s += 1;
            }
            let mut e = i + 3;
            while e < n && is_url_char(line[e]) {
                e += 1;
            }
            if s < i && e > i + 3 {
                out.push((s, e));
                from = e;
                i = e;
                continue;
            }
        }
        i += 1;
    }
    out
}

/// 文の中の URL (行ごと)
fn urls_in(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.split('\n') {
        let c: Vec<char> = line.chars().collect();
        for (s, e) in url_spans(&c) {
            out.push(c[s..e].iter().collect());
        }
    }
    out
}

/// `(create|update|edit)_?gists?([^a-z_]|$)|gists\.(create|update)` (小文字にした文で、左に近く長いもの)
fn gist_call(text: &str) -> Option<String> {
    let c: Vec<char> = text.chars().collect();
    let n = c.len();
    let lit = |at: usize, s: &str| -> bool {
        let l: Vec<char> = s.chars().collect();
        at + l.len() <= n && c[at..at + l.len()] == l[..]
    };
    for p in 0..n {
        for w in ["create", "update", "edit"] {
            if !lit(p, w) {
                continue;
            }
            let mut q = p + w.len();
            if q < n && c[q] == '_' {
                q += 1;
            }
            if !lit(q, "gist") {
                continue;
            }
            q += 4;
            if q < n && c[q] == 's' {
                q += 1;
            }
            if q == n {
                return Some(c[p..q].iter().collect());
            }
            if !(c[q].is_ascii_lowercase() || c[q] == '_') {
                return Some(c[p..=q].iter().collect());
            }
        }
        if lit(p, "gists.") {
            for w in ["create", "update"] {
                if lit(p + 6, w) {
                    return Some(c[p..p + 6 + w.len()].iter().collect());
                }
            }
        }
    }
    None
}

/// bash の printf の `%b` と echo -e の escape (`\c` で出力を止める)
fn unescape(s: &str, percent_b: bool) -> (String, bool) {
    let c: Vec<char> = s.chars().collect();
    let n = c.len();
    let mut out = String::new();
    let mut i = 0;
    while i < n {
        if c[i] != '\\' || i + 1 >= n {
            out.push(c[i]);
            i += 1;
            continue;
        }
        let e = c[i + 1];
        i += 2;
        match e {
            'a' => out.push('\u{7}'),
            'b' => out.push('\u{8}'),
            'e' | 'E' => out.push('\u{1b}'),
            'f' => out.push('\u{c}'),
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'v' => out.push('\u{b}'),
            '\\' => out.push('\\'),
            'c' if percent_b => return (out, true),
            '"' if !percent_b => out.push('"'),
            '\'' if !percent_b => out.push('\''),
            '?' if !percent_b => out.push('?'),
            '0'..='7' => {
                // %b は \0NNN (0 の後ろに 3 桁まで)、書式は \NNN (3 桁まで)
                let mut v = 0u32;
                let mut k = 0;
                let mut j = if percent_b && e == '0' {
                    i
                } else {
                    v = e.to_digit(8).unwrap();
                    k = 1;
                    i
                };
                while k < 3 && j < n && c[j].is_digit(8) {
                    v = v * 8 + c[j].to_digit(8).unwrap();
                    j += 1;
                    k += 1;
                }
                i = j;
                if let Some(ch) = char::from_u32(v & 0xff) {
                    out.push(ch);
                }
            }
            'x' => {
                let mut v = 0u32;
                let mut j = i;
                while j < n && j < i + 2 && c[j].is_ascii_hexdigit() {
                    v = v * 16 + c[j].to_digit(16).unwrap();
                    j += 1;
                }
                if j == i {
                    out.push('\\');
                    out.push('x');
                } else if let Some(ch) = char::from_u32(v) {
                    out.push(ch);
                }
                i = j;
            }
            other => {
                out.push('\\');
                out.push(other);
            }
        }
    }
    (out, false)
}

/// bash の printf (書式を引数が尽きるまで繰り返す)。数でない引数を数の書式に渡すなど、bash が失敗するものは None
fn bash_printf(fmt: &str, args: &[String]) -> Option<String> {
    let f: Vec<char> = fmt.chars().collect();
    let mut out = String::new();
    let mut ai = 0;
    loop {
        let mut used = false;
        let mut i = 0;
        while i < f.len() {
            if f[i] == '\\' {
                // 書式の escape: \ から次の % の手前まで (escape の単位で)
                let mut j = i + 1;
                if j < f.len() {
                    j += 1;
                    if f[j - 1] == 'x' {
                        while j < f.len() && j < i + 4 && f[j].is_ascii_hexdigit() {
                            j += 1;
                        }
                    } else if f[j - 1].is_digit(8) {
                        while j < f.len() && j < i + 4 && f[j].is_digit(8) {
                            j += 1;
                        }
                    }
                }
                let seg: String = f[i..j].iter().collect();
                out.push_str(&unescape(&seg, false).0);
                i = j;
                continue;
            }
            if f[i] != '%' {
                out.push(f[i]);
                i += 1;
                continue;
            }
            if f.get(i + 1) == Some(&'%') {
                out.push('%');
                i += 2;
                continue;
            }
            // %[flags][width][.precision][length]conv
            let mut j = i + 1;
            let mut left = false;
            while j < f.len() && "-+ #0'".contains(f[j]) {
                left |= f[j] == '-';
                j += 1;
            }
            let ws = j;
            while j < f.len() && f[j].is_ascii_digit() {
                j += 1;
            }
            let width: usize = f[ws..j].iter().collect::<String>().parse().unwrap_or(0);
            let mut prec: Option<usize> = None;
            if f.get(j) == Some(&'.') {
                j += 1;
                let ps = j;
                while j < f.len() && f[j].is_ascii_digit() {
                    j += 1;
                }
                prec = Some(f[ps..j].iter().collect::<String>().parse().unwrap_or(0));
            }
            while j < f.len() && "hlLqjzZt".contains(f[j]) {
                j += 1;
            }
            let conv = *f.get(j)?;
            let arg = args.get(ai).cloned();
            if arg.is_some() {
                ai += 1;
            }
            used = true;
            let a = arg.unwrap_or_default();
            let mut piece = match conv {
                's' | 'q' | 'Q' => match prec {
                    Some(p) => a.chars().take(p).collect(),
                    None => a,
                },
                'b' => {
                    let (t, stop) = unescape(&a, true);
                    if stop {
                        out.push_str(&t);
                        return Some(out);
                    }
                    t
                }
                'c' => a.chars().next().map(String::from).unwrap_or_default(),
                'd' | 'i' | 'u' | 'o' | 'x' | 'X' => {
                    let v: i64 = if a.is_empty() {
                        0
                    } else {
                        a.trim().parse().ok()?
                    };
                    match conv {
                        'o' => format!("{v:o}"),
                        'x' => format!("{v:x}"),
                        'X' => format!("{v:X}"),
                        _ => v.to_string(),
                    }
                }
                'e' | 'E' | 'f' | 'F' | 'g' | 'G' | 'a' | 'A' => {
                    let v: f64 = if a.is_empty() {
                        0.0
                    } else {
                        a.trim().parse().ok()?
                    };
                    format!("{v:.*}", prec.unwrap_or(6))
                }
                _ => return None,
            };
            let len = piece.chars().count();
            if width > len {
                let pad = " ".repeat(width - len);
                piece = if left { piece + &pad } else { pad + &piece };
            }
            out.push_str(&piece);
            i = j + 1;
        }
        if !used || ai >= args.len() {
            break;
        }
    }
    Some(out)
}

/// `%[^a-zA-Z%]*([0-9]{4,}|\*)` (幅の大きい書式)
fn wide_format(fmt: &str) -> bool {
    let c: Vec<char> = fmt.chars().collect();
    for (p, _) in c.iter().enumerate().filter(|(_, x)| **x == '%') {
        let mut digits = 0;
        for &x in &c[p + 1..] {
            if x.is_ascii_alphabetic() || x == '%' {
                break;
            }
            if x == '*' {
                return true;
            }
            if x.is_ascii_digit() {
                digits += 1;
                if digits >= 4 {
                    return true;
                }
            } else {
                digits = 0;
            }
        }
    }
    false
}

/// curl の値を取るオプション
const CURL_SHORT: &str = "AbcCdDeEFHKmoPQrtTuUwxXyYz";
const CURL_LONG: &str = "|abstract-unix-socket|alt-svc|aws-sigv4|cacert|capath|cert|cert-type|ciphers|config|connect-timeout|connect-to|continue-at|cookie|cookie-jar|create-file-mode|curves|delegation|dns-interface|dns-ipv4-addr|dns-ipv6-addr|dns-servers|doh-url|dump-header|ech|egd-file|engine|etag-compare|etag-save|expect100-timeout|ftp-account|ftp-alternative-to-user|ftp-method|ftp-port|ftp-ssl-ccc-mode|happy-eyeballs-timeout-ms|haproxy-clientip|header|hostpubmd5|hostpubsha256|hsts|interface|ip-tos|ipfs-gateway|keepalive-cnt|keepalive-time|key|key-type|krb|libcurl|limit-rate|local-port|login-options|mail-auth|mail-from|mail-rcpt|max-filesize|max-redirs|max-time|netrc-file|noproxy|oauth2-bearer|output|output-dir|parallel-max|pass|pinnedpubkey|preproxy|proto|proto-default|proto-redir|proxy|proxy-cacert|proxy-capath|proxy-cert|proxy-cert-type|proxy-ciphers|proxy-crlfile|proxy-header|proxy-key|proxy-key-type|proxy-pass|proxy-pinnedpubkey|proxy-service-name|proxy-tls13-ciphers|proxy-tlsauthtype|proxy-tlspassword|proxy-tlsuser|proxy-user|quote|random-file|range|rate|referer|request-target|resolve|retry|retry-delay|retry-max-time|sasl-authzid|service-name|socks4|socks4a|socks5|socks5-gssapi-service|socks5-hostname|speed-limit|speed-time|stderr|telnet-option|tftp-blksize|time-cond|tls-max|tls13-ciphers|tlsauthtype|tlspassword|tlsuser|trace|trace-ascii|trace-config|unix-socket|url-query|user|user-agent|variable|write-out|";
/// wget の値を取るオプション
const WGET_SHORT: &str = "aBDeIilOoPQRtTUwXY";
const WGET_LONG: &str = "|output-document|output-file|append-output|input-file|base|config|tries|timeout|dns-timeout|connect-timeout|read-timeout|wait|waitretry|quota|limit-rate|bind-address|user|password|http-user|http-password|ftp-user|ftp-password|proxy-user|proxy-password|header|referer|user-agent|load-cookies|save-cookies|certificate|certificate-type|private-key|private-key-type|ca-certificate|ca-directory|crl-file|pinnedpubkey|secure-protocol|ciphers|directory-prefix|cut-dirs|level|accept|reject|accept-regex|reject-regex|domains|exclude-domains|include-directories|exclude-directories|execute|local-encoding|remote-encoding|restrict-file-names|default-page|max-redirect|compression|report-speed|use-askpass|regex-type|rejected-log|hsts-file|warc-file|warc-header|warc-max-size|warc-dedup|warc-tempdir|";

/// simple の local
#[derive(Clone, Default)]
struct Local {
    in_text: String,
    in_known: bool,
    in_given: bool,
}

struct Gist<'a> {
    w: World<'a>,
    found: Vec<String>,
    long_kb: usize,
    new_remotes: HashMap<String, String>,
    next_dir: String,
    out_text: String,
    out_known: bool,
    last_out: String,
    last_known: bool,
}

impl<'a> Gist<'a> {
    fn new(sys: &'a dyn Sys, cwd: &str) -> Self {
        Gist {
            w: World::new(sys, cwd),
            found: Vec::new(),
            long_kb: 0,
            new_remotes: HashMap::new(),
            next_dir: String::new(),
            out_text: String::new(),
            out_known: false,
            last_out: String::new(),
            last_known: false,
        }
    }

    /// 止める理由に 1 行足す (同じものは 1 回だけ)
    fn add_found(&mut self, f: String) {
        if !self.found.contains(&f) {
            self.found.push(f);
        }
    }

    fn emit(&self) -> String {
        let mut msg = if self.long_kb > 0 {
            format!(
                "[gist-guard] コマンドが長すぎて ({} KB。中を読むのは {} KB まで) 中を読めず、gist かペースト共有のサービスへ上げる形の文字があるので止めた:",
                self.long_kb,
                LEX_LIMIT / 1024
            )
        } else {
            "[gist-guard] gist かペースト共有のサービスへ上げようとしているので、打つ前に止めた:"
                .to_string()
        };
        for f in &self.found {
            msg.push_str("\n- ");
            msg.push_str(f);
        }
        msg.push_str("\n\n確かめずに外へ上げると、private な中身 (コード・設定・会話の中身) も公開される。secret gist も URL を知る人は誰でも読め、ペースト共有のサービスの多くは消せない。上げてよいかを Claude が決めないよう、この hook はいつも止める。");
        msg.push_str("\n\n次のようにする:");
        if self.long_kb > 0 {
            msg.push_str("\n- 上げるつもりが無いなら、コマンドを分けて打ち直す (短いコマンドなら中を読んで確かめる)。長い本文は heredoc にせず、Write の tool でファイルに書く");
        }
        msg.push_str("\n- 回り込まない: 別のコマンド・別のサービス・gh api や curl で同じ API を叩く・script のファイルに書いて流す、をしない");
        msg.push_str("\n- ユーザーがこの会話で上げると明示しているなら、自分では打たず、ユーザーに `! gh gist create <file>` のように ! を付けて自分で打ってもらう (止めたコマンドをそのまま渡してよい)");
        msg.push_str(
            "\n- 明示されていないなら上げずに、何を・どこへ・なぜ上げたいかをユーザーに聞く",
        );
        msg.push_str("\n- Notion に載せたい HTML なら、外へ置かずに Notion の HTML ブロック (.html を File Upload で上げ、embed.file_upload に付ける) で直接載せる");
        msg
    }

    /// mcp__<server>__<tool> を _・-・.・大文字の頭で語に分け、gist・gists と書き込みの語を両方含めば止める
    fn mcp_tool(&mut self, name: &str) {
        let mut s = String::new();
        let mut prev: Option<char> = None;
        for c in name.chars() {
            if c.is_uppercase() && prev.is_some_and(|p| p.is_lowercase() || p.is_ascii_digit()) {
                s.push('_');
            }
            s.push(c);
            prev = Some(c);
        }
        let s = s.to_lowercase().replace(['-', '.'], "_");
        let (mut gist, mut write) = (false, false);
        for w in s.split('_') {
            match w {
                "gist" | "gists" => gist = true,
                "create" | "update" | "edit" | "new" | "fork" | "upload" | "write" | "put"
                | "post" | "patch" | "add" | "rename" | "comment" | "publish" | "share"
                | "save" | "set" | "append" | "upsert" | "paste" | "star" | "modify"
                | "replace" => write = true,
                _ => {}
            }
        }
        if gist && write {
            self.add_found(format!("MCP の tool {name} (gist を作る・書き換える)"));
        }
    }

    /// gist の API への書き込み (GET・HEAD・DELETE・OPTIONS でない method) と、ペースト共有のサービスへの送信 (本文があるか、書き込みの method)
    fn send_check(&mut self, dir: &str, name: &str, method: &str, body: bool, urls: &[String]) {
        let read_only = matches!(method, "GET" | "HEAD" | "DELETE" | "OPTIONS");
        for u in urls {
            let expanded = self.w.expand_value(dir, u);
            let Some(c) = classify_url(&expanded) else {
                continue;
            };
            match c.kind {
                Kind::GistApi if !read_only => {
                    self.add_found(format!(
                        "{name} {method} {expanded} (gist の API に書き込む)"
                    ));
                }
                Kind::Paste if !(read_only && !body) => {
                    self.add_found(format!("{name} → {}", c.paste_label()));
                }
                _ => {}
            }
        }
    }

    /// 文の中の gist の API・gist・ペースト共有のサービスの URL と、gist を作る呼び出し (create_gist・gists.create など)
    fn code_urls(&mut self, name: &str, text: &str) {
        for u in urls_in(text) {
            let Some(c) = classify_url(&u) else {
                continue;
            };
            let f = match c.kind {
                Kind::GistApi => format!("{name} のコードの {u} (gist の API)"),
                Kind::GistGit => format!("{name} のコードの {u} (gist)"),
                Kind::Paste => format!("{name} のコードの {u} → {}", c.paste_label()),
            };
            self.add_found(f);
        }
        if let Some(m) = gist_call(&text.to_lowercase()) {
            self.add_found(format!(
                "{name} のコードの {m} (gist を作る・書き換える呼び出し)"
            ));
        }
    }

    /// gh gist と gh api を見る
    fn gh_cmd(&mut self, prog: &str, a: &[String]) {
        let mut i = 0;
        while i < a.len() {
            match a[i].as_str() {
                "-h" | "--help" | "--version" => return,
                x if x.starts_with('-') => {}
                _ => break,
            }
            i += 1;
        }
        match a.get(i).map(String::as_str) {
            Some("gist") => self.gh_gist(prog, &a[i + 1..]),
            Some("api") => self.gh_api(prog, &a[i + 1..]),
            _ => {}
        }
    }

    /// 作る・書き換える subcommand と、知らない subcommand を止める
    fn gh_gist(&mut self, prog: &str, a: &[String]) {
        if a.iter().any(|x| x == "-h" || x == "--help") {
            return;
        }
        let sub = a
            .iter()
            .find(|x| !x.starts_with('-'))
            .cloned()
            .unwrap_or_default();
        match sub.as_str() {
            "" | "list" | "ls" | "view" | "clone" | "delete" => return,
            "show" if prog == "hub" => return,
            _ => {}
        }
        let what = match sub.as_str() {
            "create" | "new" => "gist を作る",
            "edit" | "rename" => "gist を書き換える",
            _ => "知らない subcommand。gist を作る・書き換えるものとみなす",
        };
        self.add_found(format!("{prog} gist {sub} ({what})"));
    }

    /// gists の endpoint への書き込みを止める。method は -X・--method、無ければ -f・-F・--input があれば POST、無ければ GET (gh の決まり)
    fn gh_api(&mut self, prog: &str, a: &[String]) {
        let (mut method, mut body, mut endpoint) = (String::new(), false, String::new());
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "--" => {
                    if endpoint.is_empty() {
                        endpoint = a.get(i + 1).cloned().unwrap_or_default();
                    }
                    break;
                }
                "-h" | "--help" => return,
                _ if x.starts_with("--method=") => method = x["--method=".len()..].to_string(),
                "--method" => {
                    method = a.get(i + 1).cloned().unwrap_or_default();
                    i += 1;
                }
                _ if x.starts_with("--field=")
                    || x.starts_with("--raw-field=")
                    || x.starts_with("--input=") =>
                {
                    body = true
                }
                "--field" | "--raw-field" | "--input" => {
                    body = true;
                    i += 1;
                }
                _ if x.starts_with("--") && x.contains('=') => {}
                "--header" | "--jq" | "--template" | "--hostname" | "--cache" | "--preview" => {
                    i += 1
                }
                _ if x.starts_with("--") => {}
                _ if x.len() >= 2 && x.starts_with('-') => {
                    // 束ねた短いオプション (-XPUT・-iX POST)。値を取るものが来たら、残りの文字 (頭の = は外す) か次の語が値
                    let cs: Vec<char> = x.chars().collect();
                    for k in 1..cs.len() {
                        let c = cs[k];
                        if !"XfFHqtp".contains(c) {
                            continue;
                        }
                        let mut v: String = cs[k + 1..].iter().collect();
                        if v.is_empty() {
                            v = a.get(i + 1).cloned().unwrap_or_default();
                            i += 1;
                        }
                        match c {
                            'X' => method = v.strip_prefix('=').unwrap_or(&v).to_string(),
                            'f' | 'F' => body = true,
                            _ => {}
                        }
                        break;
                    }
                }
                _ => {
                    if endpoint.is_empty() {
                        endpoint = x.to_string();
                    }
                }
            }
            i += 1;
        }
        let mut method = method.to_uppercase();
        if method.is_empty() {
            method = if body { "POST" } else { "GET" }.to_string();
        }
        if matches!(method.as_str(), "GET" | "HEAD" | "DELETE" | "OPTIONS")
            || !gists_endpoint(&endpoint)
        {
            return;
        }
        self.add_found(format!(
            "{prog} api {method} {endpoint} (gist の API に書き込む)"
        ));
    }

    /// glab snippet create・new (GitLab の snippet は gist にあたる) を止める
    fn glab_cmd(&mut self, a: &[String]) {
        if a.iter().any(|x| x == "-h" || x == "--help") {
            return;
        }
        let mut i = a
            .iter()
            .position(|x| !x.starts_with('-'))
            .unwrap_or(a.len());
        if a.get(i).map(String::as_str) != Some("snippet") {
            return;
        }
        i += 1;
        while i < a.len() && a[i].starts_with('-') {
            i += 1;
        }
        if let Some(sub @ ("create" | "new")) = a.get(i).map(String::as_str) {
            self.add_found(format!(
                "glab snippet {sub} (GitLab の snippet を作る。gist にあたる)"
            ));
        }
    }

    /// git push と、push より前に足す remote (git remote add・set-url) を見る
    fn git_cmd(&mut self, dir: &str, args: &[String]) {
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
                s if [
                    "--git-dir=",
                    "--work-tree=",
                    "--namespace=",
                    "--config-env=",
                ]
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
        if sub == "gh" {
            sub = a.first().cloned().unwrap_or_default();
            if !a.is_empty() {
                a.remove(0);
            }
        }
        match sub.as_str() {
            "push" => self.push_job(&gdir, &gopts, &a),
            "remote" => self.remote_job(&gdir, &a),
            _ => {}
        }
    }

    /// 同じコマンドで足す・付け替える remote の URL を覚える (hook が走る時点では、まだ config に無い)
    fn remote_job(&mut self, dir: &str, a: &[String]) {
        if !matches!(a.first().map(String::as_str), Some("add" | "set-url")) {
            return;
        }
        let mut pos: Vec<String> = Vec::new();
        let mut i = 1;
        while i < a.len() {
            match a[i].as_str() {
                "-t" | "-m" => i += 1,
                x if x.starts_with('-') => {}
                x => pos.push(x.to_string()),
            }
            i += 1;
        }
        if pos.len() < 2 {
            return;
        }
        let v = self.w.expand_value(dir, &pos[1]);
        self.new_remotes.insert(pos[0].clone(), v);
    }

    /// push の先の URL が gist なら止める
    fn push_job(&mut self, dir: &str, gopts: &[String], a: &[String]) {
        let mut repo_opt = String::new();
        let mut pos: Vec<String> = Vec::new();
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "--" => {
                    pos.extend(a[i + 1..].iter().cloned());
                    break;
                }
                // --dry-run は送らない
                "-h" | "--help" | "-n" | "--dry-run" => return,
                _ if x.starts_with("--repo=") => repo_opt = x["--repo=".len()..].to_string(),
                "--repo" | "-o" | "--push-option" | "--receive-pack" | "--exec" => {
                    if x == "--repo" {
                        repo_opt = a.get(i + 1).cloned().unwrap_or_default();
                    }
                    i += 1;
                }
                _ if x.starts_with("--") => {}
                _ if x.starts_with('-') => {
                    let cs: Vec<char> = x.chars().collect();
                    for k in 1..cs.len() {
                        if cs[k] == 'n' {
                            return;
                        }
                        if cs[k] == 'o' {
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

        // push の先: 引数・--repo、無ければ branch.<今>.pushRemote → remote.pushDefault → branch.<今>.remote → origin
        let mut remote = pos
            .first()
            .cloned()
            .filter(|s| !s.is_empty())
            .unwrap_or(repo_opt);
        if !remote.is_empty() {
            remote = self.w.expand_value(dir, &remote);
        }
        let (ok, cur) = self
            .w
            .git(dir, gopts, &["symbolic-ref", "-q", "--short", "HEAD"]);
        let cur = if ok { cur } else { String::new() };
        if remote.is_empty() {
            if !cur.is_empty() {
                remote = self
                    .w
                    .git(
                        dir,
                        gopts,
                        &["config", "--get", &format!("branch.{cur}.pushRemote")],
                    )
                    .1;
            }
            if remote.is_empty() {
                remote = self
                    .w
                    .git(dir, gopts, &["config", "--get", "remote.pushDefault"])
                    .1;
            }
            if remote.is_empty() && !cur.is_empty() {
                remote = self
                    .w
                    .git(
                        dir,
                        gopts,
                        &["config", "--get", &format!("branch.{cur}.remote")],
                    )
                    .1;
            }
            if remote.is_empty() {
                remote = "origin".to_string();
            }
        }
        let mut urls: Vec<String> = if let Some(u) = self.new_remotes.get(&remote) {
            vec![u.clone()]
        } else if !remote.contains('/')
            && !self
                .w
                .git(
                    dir,
                    gopts,
                    &["config", "--get", &format!("remote.{remote}.url")],
                )
                .1
                .is_empty()
        {
            // push の URL は pushurl と pushInsteadOf を解いたもの。pushurl が複数なら全部へ送る
            self.w.git_lines(
                dir,
                gopts,
                &["remote", "get-url", "--push", "--all", &remote],
            )
        } else {
            self.w
                .git_lines(dir, gopts, &["ls-remote", "--get-url", &remote])
        };
        if urls.is_empty() {
            urls = vec![remote.clone()];
        }
        for u in urls {
            if classify_url(&u).is_some_and(|c| c.kind == Kind::GistGit || c.kind == Kind::GistApi)
            {
                self.add_found(format!("git push → {u} (gist の repo)"));
            }
        }
    }

    /// curl: method は -X・--request、無ければ本文 (-d・-F・-T など) があれば POST (-G なら GET)、-I なら HEAD、ほかは GET
    fn curl_cmd(&mut self, dir: &str, a: &[String]) {
        let (mut method, mut body, mut get, mut head) = (String::new(), false, false, false);
        let mut urls: Vec<String> = Vec::new();
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "--" => {
                    urls.extend(a[i + 1..].iter().cloned());
                    break;
                }
                "-h" | "--help" | "-M" | "--manual" | "-V" | "--version" => return,
                "--request" => {
                    method = a.get(i + 1).cloned().unwrap_or_default();
                    i += 1;
                }
                "--data" | "--data-ascii" | "--data-binary" | "--data-raw" | "--data-urlencode"
                | "--json" | "--form" | "--form-string" | "--upload-file" => {
                    body = true;
                    i += 1;
                }
                "--url" => {
                    urls.push(a.get(i + 1).cloned().unwrap_or_default());
                    i += 1;
                }
                "--get" => get = true,
                "--head" => head = true,
                _ if x.starts_with("--") => {
                    if CURL_LONG.contains(&format!("|{}|", &x[2..])) {
                        i += 1;
                    }
                }
                _ if x.len() >= 2 && x.starts_with('-') => {
                    // 束ねた短いオプション (-sF x・-XPOST)。値を取るものが来たら、残りの文字か次の語が値
                    let cs: Vec<char> = x.chars().collect();
                    for k in 1..cs.len() {
                        let c = cs[k];
                        match c {
                            'G' => get = true,
                            'I' => head = true,
                            _ => {}
                        }
                        if !CURL_SHORT.contains(c) {
                            continue;
                        }
                        let mut v: String = cs[k + 1..].iter().collect();
                        if v.is_empty() {
                            v = a.get(i + 1).cloned().unwrap_or_default();
                            i += 1;
                        }
                        match c {
                            'X' => method = v,
                            'd' | 'F' | 'T' => body = true,
                            _ => {}
                        }
                        break;
                    }
                }
                _ => urls.push(x.to_string()),
            }
            i += 1;
        }
        let mut method = method.to_uppercase();
        if method.is_empty() {
            method = if body && !get {
                "POST"
            } else if head {
                "HEAD"
            } else {
                "GET"
            }
            .to_string();
        }
        self.send_check(dir, "curl", &method, body, &urls);
    }

    /// wget: method は --method、無ければ --post-data・--post-file があれば POST、ほかは GET
    fn wget_cmd(&mut self, dir: &str, a: &[String]) {
        let (mut method, mut body) = (String::new(), false);
        let mut urls: Vec<String> = Vec::new();
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "--" => {
                    urls.extend(a[i + 1..].iter().cloned());
                    break;
                }
                "-h" | "--help" | "-V" | "--version" => return,
                _ if [
                    "--post-data=",
                    "--post-file=",
                    "--body-data=",
                    "--body-file=",
                ]
                .iter()
                .any(|p| x.starts_with(p)) =>
                {
                    body = true;
                }
                "--post-data" | "--post-file" | "--body-data" | "--body-file" => {
                    body = true;
                    i += 1;
                }
                _ if x.starts_with("--method=") => method = x["--method=".len()..].to_string(),
                "--method" => {
                    method = a.get(i + 1).cloned().unwrap_or_default();
                    i += 1;
                }
                _ if x.starts_with("--") && x.contains('=') => {}
                _ if x.starts_with("--") => {
                    if WGET_LONG.contains(&format!("|{}|", &x[2..])) {
                        i += 1;
                    }
                }
                _ if x.len() >= 2 && x.starts_with('-') => {
                    let cs: Vec<char> = x.chars().collect();
                    for k in 1..cs.len() {
                        if !WGET_SHORT.contains(cs[k]) {
                            continue;
                        }
                        if k + 1 >= cs.len() {
                            i += 1;
                        }
                        break;
                    }
                }
                _ => urls.push(x.to_string()),
            }
            i += 1;
        }
        let mut method = method.to_uppercase();
        if method.is_empty() {
            method = if body { "POST" } else { "GET" }.to_string();
        }
        self.send_check(dir, "wget", &method, body, &urls);
    }

    /// HTTPie (http・https) と xh。[METHOD] URL [ITEM…] の ITEM (field=値・field:=JSON・field@file。name==値 は query) か stdin があれば本文で、
    /// method の既定は POST
    fn httpie_cmd(&mut self, dir: &str, name: &str, a: &[String], l: &Local) {
        let (mut method, mut body, mut no_stdin) = (String::new(), false, false);
        let mut urls: Vec<String> = Vec::new();
        let mut i = 0;
        while i < a.len() {
            let x = a[i].as_str();
            match x {
                "--help" | "--version" => return,
                "-f" | "--form" | "--multipart" => body = true,
                _ if x.starts_with("--raw=") => body = true,
                "--raw" => {
                    body = true;
                    i += 1;
                }
                "-I" | "--ignore-stdin" => no_stdin = true,
                _ if x.starts_with("--") && x.contains('=') => {}
                "--auth"
                | "--auth-type"
                | "--output"
                | "--session"
                | "--session-read-only"
                | "--verify"
                | "--cert"
                | "--cert-key"
                | "--proxy"
                | "--timeout"
                | "--max-redirects"
                | "--print"
                | "--pretty"
                | "--style"
                | "--format-options"
                | "--response-charset"
                | "--response-mime"
                | "--boundary"
                | "--ssl"
                | "--ciphers"
                | "--default-scheme"
                | "--max-headers"
                | "--history-print"
                | "--unix-socket" => i += 1,
                _ if x.starts_with("--") => {}
                _ if x.len() >= 2 && x.starts_with('-') => {
                    let cs: Vec<char> = x.chars().collect();
                    if cs[1..].iter().all(|c| c.is_ascii_alphabetic())
                        && "aAopsP".contains(cs[cs.len() - 1])
                    {
                        i += 1;
                    }
                }
                _ => {
                    if urls.is_empty() {
                        let up = x.to_uppercase();
                        if method.is_empty()
                            && matches!(
                                up.as_str(),
                                "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD" | "OPTIONS"
                            )
                        {
                            method = up;
                        } else {
                            urls.push(x.to_string());
                        }
                    } else if !x.contains("==") && (x.contains('=') || x.contains('@')) {
                        body = true;
                    }
                }
            }
            i += 1;
        }
        if !no_stdin && l.in_given {
            body = true;
        }
        if method.is_empty() {
            method = if body { "POST" } else { "GET" }.to_string();
        }
        self.send_check(dir, name, &method, body, &urls);
    }

    /// PowerShell の Invoke-WebRequest・Invoke-RestMethod (Windows PowerShell 5.1 の curl・wget も): method は -Method (既定は GET)、-Body・
    /// -InFile・-Form があれば本文
    fn iwr_cmd(&mut self, dir: &str, name: &str, a: &[String]) {
        let switches = [
            "usebasicparsing",
            "usedefaultcredentials",
            "skipcertificatecheck",
            "skipheadervalidation",
            "skiphttperrorcheck",
            "passthru",
            "resume",
            "allowunencryptedauthentication",
            "allowinsecureredirect",
            "disablekeepalive",
            "noproxy",
            "preservehttpmethodonredirect",
            "preserveauthorizationonredirect",
            "followrellink",
        ];
        let (named, pos) = ps_params(a, &switches);
        let Some(uri) = ps_named(&named, &["uri"])
            .map(str::to_string)
            .or_else(|| pos.first().cloned())
        else {
            return;
        };
        let method = ps_named(&named, &["method", "custommethod"])
            .unwrap_or("GET")
            .to_uppercase();
        let body = ps_named(&named, &["body", "infile", "form"]).is_some();
        self.send_check(dir, name, &method, body, &[uri]);
    }

    /// nc・ncat・netcat・socat・telnet の宛先 (socat は TCP:<host>:<port> などの host) がペースト共有のサービスなら止める
    fn net_cmd(&mut self, dir: &str, name: &str, a: &[String]) {
        for x in a {
            if x.starts_with('-') {
                continue;
            }
            let mut v = self.w.expand_value(dir, x);
            // ^[A-Za-z0-9-]+:([^:,]+):
            if let Some((proto, rest)) = v.split_once(':')
                && !proto.is_empty()
                && proto.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
                && let Some((host, _)) = rest.split_once(':')
                && !host.is_empty()
                && !host.contains(',')
            {
                v = host.to_string();
            }
            if let Some(c) = classify_url(&v)
                && c.kind == Kind::Paste
            {
                self.add_found(format!("{name} → {}", c.paste_label()));
            }
        }
    }

    /// python・node などの引数 (-c・-e の中)・stdin・同じコマンドで書いた script の中の URL を見る
    fn interp_cmd(&mut self, dir: &str, name: &str, a: &[String], l: &Local) {
        let mut text = String::new();
        for x in a {
            text.push_str(x);
            text.push('\n');
            if x.starts_with('-') {
                continue;
            }
            if let Some(t) = self.w.read_written(dir, x) {
                text.push_str(&t);
                text.push('\n');
            }
        }
        if l.in_known {
            text.push_str(&l.in_text);
        }
        self.code_urls(name, &text);
    }

    /// ペースト共有のサービスか gist へ上げる専用のコマンド。--help・-h・--version (pastebinit は -v・-l も) は通す
    fn paste_cli(&mut self, name: &str, a: &[String]) {
        let mut info = vec!["-h", "--help", "--version"];
        if name == "pastebinit" {
            info.extend(["-v", "-l"]);
        }
        if a.iter().any(|x| info.contains(&x.as_str())) {
            return;
        }
        self.add_found(format!(
            "{name} (ペースト共有のサービスか gist へ上げるコマンド)"
        ));
    }

    /// echo の出力 (-e なら \n などを戻す)
    fn echo_out(&mut self, a: &[String]) {
        let mut esc = false;
        let mut i = 0;
        while i < a.len()
            && a[i].len() >= 2
            && a[i].starts_with('-')
            && a[i][1..].chars().all(|c| "neE".contains(c))
        {
            if a[i].contains('e') {
                esc = true;
            }
            i += 1;
        }
        let mut out = format!("{}\n", a[i..].join(" "));
        if esc {
            out = unescape(&out, true).0;
        }
        self.out_text = out;
        self.out_known = true;
    }

    /// printf の出力。幅の大きい書式 (%99999s・%*s) は打たずに、書式と引数を並べたものにする (長い文字を作らない)
    fn printf_out(&mut self, a: &[String]) {
        let mut a = a;
        if a.first().map(String::as_str) == Some("--") {
            a = &a[1..];
        }
        // -v <変数> は出力しない
        if a.first().map(String::as_str) == Some("-v") {
            return;
        }
        let fmt = a.first().cloned().unwrap_or_default();
        let rest: &[String] = if a.is_empty() { &[] } else { &a[1..] };
        let fallback = || format!("{}\n{}", unescape(&fmt, true).0, rest.join(" "));
        self.out_text = if wide_format(&fmt) {
            fallback()
        } else {
            bash_printf(&fmt, rest).unwrap_or_else(fallback)
        };
        self.out_known = true;
    }

    /// bash -c などに文字列で渡したものを読み直す
    fn rescan(&mut self, dir: &str, depth: usize, s: &str, lang: Lang) {
        self.scan_command(dir, depth + 1, s, lang);
    }

    /// 単純コマンドを 1 つ見る
    fn simple(&mut self, dir: &str, depth: usize, rec: &super::lex::Cmd) {
        let mut dir = dir.to_string();
        let ci = self.w.win || rec.ps;
        let mut w: Vec<String> = rec.words.clone();
        let mut l = Local::default();
        match &rec.stdin {
            super::lex::Stdin::Here(t) => {
                l.in_text = t.clone();
                l.in_known = true;
                l.in_given = true;
            }
            super::lex::Stdin::File(p) => {
                l.in_given = true;
                if let Some(t) = self.w.read_written(&dir, p) {
                    l.in_text = t;
                    l.in_known = true;
                }
            }
            super::lex::Stdin::None => {
                if rec.pipe {
                    l.in_given = true;
                    l.in_text = self.last_out.clone();
                    l.in_known = self.last_known;
                }
            }
        }

        // > /dev/tcp/<host>/<port> などへの書き込み (bash が開くソケット)
        for a in &rec.net {
            let name = a
                .strip_prefix("/dev/")
                .and_then(|r| r.split_once('/'))
                .map_or(a.as_str(), |(_, r)| r);
            let host = name.split('/').next().unwrap_or(name);
            if let Some(c) = classify_url(host)
                && c.kind == Kind::Paste
            {
                self.add_found(format!("{a} への書き込み → {}", c.paste_label()));
            }
        }

        // 頭の VAR=値 と予約語
        let mut assigns: Vec<String> = Vec::new();
        while let Some(first) = w.first().cloned() {
            if matches!(
                first.as_str(),
                "!" | "{" | "}" | "if" | "then" | "else" | "elif" | "do" | "while" | "until"
            ) {
            } else if matches!(
                first.as_str(),
                "for" | "case" | "select" | "function" | "fi" | "done" | "esac" | "[[" | "["
            ) {
                return;
            } else if let Some((name, _)) = first.split_once('=') {
                if !super::is_name(name) {
                    break;
                }
                assigns.push(first.clone());
            } else {
                break;
            }
            w.remove(0);
        }
        if w.is_empty() {
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
                            "-S" | "--split-string" => {
                                let s = w[1..].join(" ");
                                self.rescan(&dir, depth, &s, Lang::Bash);
                                return;
                            }
                            "-u" | "--unset" | "-C" | "--chdir" => {
                                w.drain(..2.min(w.len()));
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
                    self.rescan(&dir, depth, &s, Lang::Bash);
                    return;
                }
                "flock" => {
                    if let Some(i) = w.iter().skip(1).position(|x| x == "-c" || x == "--command") {
                        let s = w.get(i + 2).cloned().unwrap_or_default();
                        self.rescan(&dir, depth, &s, Lang::Bash);
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
                        let x = w[i].clone();
                        match x.as_str() {
                            "-o" | "+o" | "-O" | "+O" | "--rcfile" | "--init-file" => i += 1,
                            _ if x.starts_with('-') => {
                                if super::xref::is_c_flag(&x) {
                                    let s = w.get(i + 1).cloned().unwrap_or_default();
                                    self.rescan(&dir, depth, &s, Lang::Bash);
                                    return;
                                }
                            }
                            _ => {
                                // script のファイル。同じコマンドで書いたものだけ読む
                                if let Some(t) = self.w.read_written(&dir, &x) {
                                    self.rescan(&dir, depth, &t, Lang::Bash);
                                }
                                return;
                            }
                        }
                        i += 1;
                    }
                    // -c も script のファイルも無い shell (bash <<EOF・bash -s・cat … | bash) は stdin を読む
                    if l.in_known {
                        let s = l.in_text.clone();
                        self.rescan(&dir, depth, &s, Lang::Bash);
                    }
                    return;
                }
                "source" | "." => {
                    if w.len() > 1
                        && let Some(t) = self.w.read_written(&dir, &w[1])
                    {
                        let lang = if rec.ps { Lang::PowerShell } else { Lang::Bash };
                        self.rescan(&dir, depth, &t, lang);
                    }
                    return;
                }
                "eval" => {
                    let s = w[1..].join(" ");
                    self.rescan(&dir, depth, &s, Lang::Bash);
                    return;
                }
                "su" | "runuser" | "script" => {
                    for i in 1..w.len() {
                        if w[i] == "-c" || w[i] == "--command" {
                            let s = w.get(i + 1).cloned().unwrap_or_default();
                            self.rescan(&dir, depth, &s, Lang::Bash);
                            return;
                        }
                        if let Some(v) = w[i].strip_prefix("--command=") {
                            let s = v.to_string();
                            self.rescan(&dir, depth, &s, Lang::Bash);
                            return;
                        }
                    }
                    return;
                }
                "ssh" => {
                    // ssh [オプション] <host> <コマンド>…: host の後ろをコマンドとして読み直す
                    let mut i = 1;
                    while i < w.len() {
                        let x = w[i].as_str();
                        if x.len() == 2
                            && x.starts_with('-')
                            && "BbcDEeFIiJLlmOoPpQRSWw".contains(&x[1..])
                        {
                            i += 1;
                        } else if !x.starts_with('-') {
                            if i + 1 < w.len() {
                                let s = w[i + 1..].join(" ");
                                self.rescan(&dir, depth, &s, Lang::Bash);
                            }
                            return;
                        }
                        i += 1;
                    }
                    return;
                }
                "find" => {
                    // -exec・-execdir・-ok・-okdir の後ろから ; か + までを、1 つの単純コマンドとして見る
                    let mut i = 1;
                    while i < w.len() {
                        if matches!(w[i].as_str(), "-exec" | "-execdir" | "-ok" | "-okdir") {
                            let mut sub = Vec::new();
                            i += 1;
                            while i < w.len() && w[i] != ";" && w[i] != "+" {
                                sub.push(w[i].clone());
                                i += 1;
                            }
                            if !sub.is_empty() && depth < 3 {
                                let inner = super::lex::Cmd {
                                    words: sub,
                                    ps: rec.ps,
                                    ..super::lex::Cmd::default()
                                };
                                self.simple(&dir, depth + 1, &inner);
                            }
                        }
                        i += 1;
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
                        self.rescan(&dir, depth, &s, Lang::Bash);
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
                    // mise exec … -- <コマンド>
                    if matches!(w.get(1).map(String::as_str), Some("exec" | "x"))
                        && let Some(i) = w.iter().skip(2).position(|x| x == "--")
                    {
                        w.drain(..i + 3);
                        continue;
                    }
                    break;
                }
                // Windows: PowerShell・cmd の中のコマンド、WSL の中のコマンド
                "pwsh" | "powershell" => {
                    if let Some(s) = pwsh_command(&w[1..]) {
                        self.rescan(&dir, depth, &s, Lang::PowerShell);
                    }
                    return;
                }
                "cmd" => {
                    if let Some(s) = cmd_command(&w[1..]) {
                        self.rescan(&dir, depth, &s, Lang::Bash);
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
                    self.rescan(&dir, depth, &rest.join(" "), Lang::PowerShell);
                    return;
                }
                _ => break,
            }
        }
        if w.is_empty() {
            return;
        }

        let mut name = base_name(&w[0], ci);
        if let Some(n) = name.strip_suffix(".exe") {
            name = n.to_string();
        }
        if rec.ps {
            name = ps_alias(&name).to_string();
        }
        let args = &w[1..];
        match name.as_str() {
            "gh" | "hub" => self.gh_cmd(&name, args),
            "glab" => self.glab_cmd(args),
            "git" => self.git_cmd(&dir, args),
            "curl" => {
                self.curl_cmd(&dir, args);
                if rec.ps {
                    self.iwr_cmd(&dir, &w[0], args);
                }
            }
            "wget" | "wget2" => {
                self.wget_cmd(&dir, args);
                if rec.ps {
                    self.iwr_cmd(&dir, &w[0], args);
                }
            }
            "http" | "https" | "xh" | "xhs" => self.httpie_cmd(&dir, &name, args, &l),
            "nc" | "ncat" | "netcat" | "nc.openbsd" | "nc.traditional" | "socat" | "telnet" => {
                self.net_cmd(&dir, &name, args);
            }
            "invoke-webrequest" => self.iwr_cmd(&dir, &w[0], args),
            n if is_interp(n) => self.interp_cmd(&dir, n, args, &l),
            "cat" => {
                if args.is_empty() || args[0] == "-" {
                    self.out_text = l.in_text.clone();
                    self.out_known = l.in_known;
                } else if let Some(t) = self.w.read_written(&dir, &args[0]) {
                    self.out_text = t;
                    self.out_known = true;
                }
            }
            "echo" => self.echo_out(args),
            "printf" => self.printf_out(args),
            "tee" => {
                self.out_text = l.in_text.clone();
                self.out_known = l.in_known;
                for a in args {
                    if !a.starts_with('-') {
                        self.w.remember_write(&dir, a, l.in_known, &l.in_text);
                    }
                }
            }
            // PowerShell の Get-Content・Tee-Object・Set-Content (Out-File・Add-Content)
            "get-content" => {
                let (named, pos) = ps_params(args, &["raw", "force", "wait", "asbytestream"]);
                if let Some(p) = ps_named(&named, &["path", "literalpath"])
                    .map(str::to_string)
                    .or(pos.first().cloned())
                    && let Some(t) = self.w.read_written(&dir, &p)
                {
                    self.out_text = t;
                    self.out_known = true;
                }
            }
            "tee-object" => {
                self.out_text = l.in_text.clone();
                self.out_known = l.in_known;
                let (named, pos) = ps_params(args, &["append"]);
                if let Some(p) = ps_named(&named, &["filepath", "literalpath", "path"])
                    .map(str::to_string)
                    .or(pos.first().cloned())
                {
                    self.w.remember_write(&dir, &p, l.in_known, &l.in_text);
                }
            }
            "set-content" | "out-file" => {
                if let Some((p, known, v)) = ps_write_target(&name, args, &l.in_text, l.in_known) {
                    self.w.remember_write(&dir, &p, known, &v);
                }
            }
            n if PASTE_CLIS.contains(&n) => self.paste_cli(n, args),
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
        let cmds = split(lang, s, true, &self.w);
        for rec in &cmds {
            self.next_dir.clear();
            self.out_text.clear();
            self.out_known = false;
            if !rec.words.is_empty() || !rec.net.is_empty() {
                self.simple(&dir, depth, rec);
            }
            if !self.next_dir.is_empty() {
                dir = self.next_dir.clone();
            }
            self.last_out = self.out_text.clone();
            self.last_known = self.out_known;
        }
    }

    /// 読む長さを超えたコマンドは中を読まず、上げる形の文字があれば止める (1 行ずつ探す)
    fn long_command(&mut self, kb: usize, cmd: &str) {
        self.long_kb = kb;
        let mut n = 0;
        'lines: for line in cmd.split('\n') {
            let c: Vec<char> = line.chars().collect();
            for (s, e) in long_spans(&c) {
                let m: String = c[s..e].iter().collect();
                if m.split_once("://").is_some_and(|(sch, _)| {
                    !sch.is_empty()
                        && sch.starts_with(|x: char| x.is_ascii_alphabetic())
                        && sch.chars().all(is_scheme_char)
                }) && classify_url(&m).is_none()
                {
                    continue;
                }
                let mut m = m.as_str();
                if let Some(f) = m.chars().next()
                    && !(f.is_ascii_alphanumeric() || f == '/')
                {
                    m = &m[f.len_utf8()..];
                }
                if let Some(l) = m.chars().last()
                    && !l.is_ascii_alphanumeric()
                {
                    m = &m[..m.len() - l.len_utf8()];
                }
                self.add_found(format!("コマンドの文字「{m}」"));
                n += 1;
                if n >= 5 {
                    break 'lines;
                }
            }
        }
        // git … push は、今の dir の push の先が gist なら止める (1 行の中だけで探す)
        if super::xref::has_git_push(cmd) {
            let cwd = self.w.cwd.clone();
            self.push_job(&cwd, &[], &[]);
        }
    }
}

fn is_interp(n: &str) -> bool {
    let py = |rest: &str| {
        rest.is_empty()
            || ((rest.starts_with('2') || rest.starts_with('3'))
                && (rest.len() == 1 || rest[1..].starts_with('.')))
    };
    matches!(
        n,
        "pypy"
            | "pypy2"
            | "pypy3"
            | "node"
            | "nodejs"
            | "deno"
            | "bun"
            | "ruby"
            | "perl"
            | "php"
            | "py"
    ) || n.strip_prefix("python").is_some_and(py)
}

fn is_alnum(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

fn is_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r')
}

/// 長いコマンドの 1 行から、上げる形の文字 (grep -Eo の 7 つの形) を左から重ねずに取り出す
fn long_spans(c: &[char]) -> Vec<(usize, usize)> {
    let n = c.len();
    let lit = |at: usize, s: &str| -> bool {
        let l: Vec<char> = s.chars().collect();
        at + l.len() <= n && c[at..at + l.len()] == l[..]
    };
    // (^|[^[:alnum:]_.-]) の前の文字を含めた始まり。p は語の頭
    let lead = |p: usize, extra_slash: bool| -> Option<usize> {
        if p == 0 {
            return Some(0);
        }
        let b = c[p - 1];
        let bad = is_alnum(b) || matches!(b, '_' | '.' | '-') || (extra_slash && b == '/');
        (!bad).then(|| p - 1)
    };
    let hosts_at = |at: usize| -> Option<usize> {
        PASTE_HOSTS
            .iter()
            .filter(|h| lit(at, h))
            .map(|h| at + h.len())
            .max()
    };
    let mut cands: Vec<(usize, usize)> = Vec::new();
    for (s, e) in url_spans(c) {
        cands.push((s, e));
    }
    for p in 0..n {
        // (gh|hub)(\.exe)?[[:space:]]+gist[[:space:]]+(create|new|edit|rename) と api[[:space:]][^;&|]*gists
        for prog in ["gh", "hub"] {
            if !lit(p, prog) {
                continue;
            }
            let Some(start) = lead(p, false) else {
                continue;
            };
            let mut q = p + prog.len();
            if lit(q, ".exe") {
                q += 4;
            }
            if q >= n || !is_space(c[q]) {
                continue;
            }
            while q < n && is_space(c[q]) {
                q += 1;
            }
            if lit(q, "gist") {
                let mut r = q + 4;
                if r < n && is_space(c[r]) {
                    while r < n && is_space(c[r]) {
                        r += 1;
                    }
                    for w in ["create", "new", "edit", "rename"] {
                        if lit(r, w) {
                            cands.push((start, r + w.len()));
                        }
                    }
                }
            }
            if lit(q, "api") && q + 3 < n && is_space(c[q + 3]) {
                // [^;&|]* は欲張るので、区切りの手前の最後の gists まで
                let stop = (q + 4..n)
                    .find(|&k| matches!(c[k], ';' | '&' | '|'))
                    .unwrap_or(n);
                if let Some(k) = (q + 4..stop).rev().find(|&k| lit(k, "gists")) {
                    cands.push((start, k + 5));
                }
            }
        }
        // glab(\.exe)?[[:space:]]+snippet[[:space:]]+(create|new)
        if lit(p, "glab")
            && let Some(start) = lead(p, false)
        {
            let mut q = p + 4;
            if lit(q, ".exe") {
                q += 4;
            }
            if q < n && is_space(c[q]) {
                while q < n && is_space(c[q]) {
                    q += 1;
                }
                if lit(q, "snippet") && q + 7 < n && is_space(c[q + 7]) {
                    let mut r = q + 7;
                    while r < n && is_space(c[r]) {
                        r += 1;
                    }
                    for w in ["create", "new"] {
                        if lit(r, w) {
                            cands.push((start, r + w.len()));
                        }
                    }
                }
            }
        }
        // (^|[^[:alnum:]_./-])(pastebinit|wgetpaste|fpaste|gist-paste|nopaste)([^[:alnum:]_.-]|$)
        for name in ["pastebinit", "wgetpaste", "fpaste", "gist-paste", "nopaste"] {
            if lit(p, name)
                && let Some(start) = lead(p, true)
            {
                let q = p + name.len();
                if q == n {
                    cands.push((start, q));
                } else if !(is_alnum(c[q]) || matches!(c[q], '_' | '.' | '-')) {
                    cands.push((start, q + 1));
                }
            }
        }
        // /dev/(tcp|udp)/([A-Za-z0-9-]+\.)*(hosts)
        if lit(p, "/dev/tcp/") || lit(p, "/dev/udp/") {
            let mut best: Option<usize> = None;
            let mut k = p + 9;
            loop {
                if let Some(e) = hosts_at(k) {
                    best = Some(best.map_or(e, |b: usize| b.max(e)));
                }
                // 次のラベル ([A-Za-z0-9-]+\.)
                let mut j = k;
                while j < n && (is_alnum(c[j]) || c[j] == '-') {
                    j += 1;
                }
                if j > k && j < n && c[j] == '.' {
                    k = j + 1;
                } else {
                    break;
                }
            }
            if let Some(e) = best {
                cands.push((p, e));
            }
        }
        // (^|[^[:alnum:]_.-])(nc|ncat|netcat|socat|telnet)[[:space:]][^;&|]*(hosts)
        for name in ["ncat", "netcat", "nc", "socat", "telnet"] {
            if lit(p, name)
                && let Some(start) = lead(p, false)
            {
                let q = p + name.len();
                if q < n && is_space(c[q]) {
                    let stop = (q + 1..n)
                        .find(|&k| matches!(c[k], ';' | '&' | '|'))
                        .unwrap_or(n);
                    if let Some(e) = (q + 1..stop)
                        .filter_map(hosts_at)
                        .filter(|&e| e <= stop)
                        .max()
                    {
                        cands.push((start, e));
                    }
                }
            }
        }
    }
    // 左に近いものから、同じ始まりなら長いものを取り、重ならないように並べる
    cands.sort_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)));
    let mut out = Vec::new();
    let mut from = 0;
    for (s, e) in cands {
        if s >= from && e > s {
            out.push((s, e));
            from = e;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - URL の分類 (gist の API・gist の repo・ペースト共有のサービスと sub-domain・raw は数えない・path やただの文字では止めない)
    //! - gist を作る呼び出しの探し方・printf と echo -e の出力・幅の大きい書式
    //! - PowerShell の tool のコマンド (Invoke-RestMethod の POST・curl.exe・gh gist create・here-string を流す python) を止め、GET は通す
    //! - bash の版の試験 (nix/tests/gist-guard.test.sh) をこの口に流して通る (`tests/guard_suites.rs`。bash と jq と git がある Linux)

    use super::*;
    use crate::process::RealSys;
    use crate::testutil::{FakeSys, TempDir};
    use serde_json::json;

    #[test]
    fn classifies_urls() {
        assert_eq!(
            classify_url("https://api.github.com/gists").unwrap().kind,
            Kind::GistApi
        );
        assert_eq!(
            classify_url("ghes.example.com/api/v3/gists/1")
                .unwrap()
                .kind,
            Kind::GistApi
        );
        assert_eq!(
            classify_url("git@gist.github.com:0123abcd.git")
                .unwrap()
                .kind,
            Kind::GistGit
        );
        assert_eq!(
            classify_url("https://ghes.example.com/gist/1.git")
                .unwrap()
                .kind,
            Kind::GistGit
        );
        let u = classify_url("https://litterbox.catbox.moe/x").unwrap();
        assert_eq!(
            u.paste_label(),
            "litterbox.catbox.moe (ペースト共有のサービス catbox.moe)"
        );
        assert!(classify_url("https://gist.githubusercontent.com/u/1/raw").is_none());
        assert!(classify_url("https://example.com/0x0.st").is_none());
        assert!(classify_url("0x0.st:443").is_some());
    }

    #[test]
    fn calls_and_printf() {
        assert_eq!(
            gist_call("g.create_gist(true, {})").as_deref(),
            Some("create_gist(")
        );
        assert_eq!(
            gist_call("client.gists.create(x)").as_deref(),
            Some("gists.create")
        );
        assert!(gist_call("logistics").is_none());
        let s = |l: &[&str]| -> Vec<String> { l.iter().map(|x| x.to_string()).collect() };
        assert_eq!(
            bash_printf("curl %s\\n", &s(&["x"])).as_deref(),
            Some("curl x\n")
        );
        assert_eq!(
            bash_printf("%s\\n", &s(&["a", "b"])).as_deref(),
            Some("a\nb\n")
        );
        assert_eq!(bash_printf("%d", &s(&["x"])), None);
        assert!(wide_format("%99999s"));
        assert!(wide_format("%*s"));
        assert!(!wide_format("%s %10s"));
        assert_eq!(unescape("a\\tb\\c rest", true), ("a\tb".to_string(), true));
    }

    #[test]
    fn powershell_commands() {
        let t = TempDir::new("gist-ps");
        let sys = FakeSys::new(|spec| RealSys.run(spec, &mut |_| {})).with_program("git", "git");
        let run_ps = |cmd: &str| {
            let v = json!({"tool_name": "PowerShell", "tool_input": {"command": cmd}, "cwd": t.path().to_string_lossy()});
            run(&v.to_string(), &v, &sys)
        };
        for cmd in [
            "Invoke-RestMethod -Method Post -Uri https://api.github.com/gists -Body $json",
            "irm https://0x0.st -Method POST -Form @{file = Get-Item a.txt}",
            "curl.exe -F 'file=@a.txt' https://0x0.st",
            "gh gist create a.txt",
            "& 'C:\\Program Files\\GitHub CLI\\gh.exe' gist create a.txt",
            "@'\nimport requests\nrequests.post('https://paste.rs', data=b'x')\n'@ | python -",
            "Invoke-WebRequest -Uri https://paste.rs -InFile a.txt",
        ] {
            assert!(run_ps(cmd).is_some(), "止める: {cmd}");
        }
        for cmd in [
            "Invoke-RestMethod https://api.github.com/gists/0123abcd",
            "gh gist view 0123abcd",
            "Write-Output 'gh gist create a.txt'",
            "iwr https://0x0.st/abcd.txt -OutFile x.txt",
        ] {
            assert!(run_ps(cmd).is_none(), "通す: {cmd}");
        }
    }
}
