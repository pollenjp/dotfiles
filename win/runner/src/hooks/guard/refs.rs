//! xref-guard がほかの repo への参照を探す道具。Linux の `xref-guard.sh` の jq (`refs_lib`。claude-skills の ticket.py の XREF_RES と strip_code と
//! 同じ形) を写した。jq の Oniguruma の `\w`・`\b` は日本語も語の文字に数えるので、bash の版と同じく ASCII の文字の組で探す (日本語の直後の
//! `owner/repo#1` も拾う)。
//!
//! - `owner/repo#番号`・`owner/repo@sha` (7〜40 桁)・github.com の issues・pull・discussions・commit の URL を拾う
//! - Markdown の文 (`md`) は、code block (``` か ~~~ の囲み) の行と inline code を外してから探す (行の番号は保つ)

/// 調べる文 1 つ (jq の `{head, suffix, numbered, mode, fix, text}`)
#[derive(Clone, Debug)]
pub struct Text {
    pub head: String,
    pub suffix: String,
    pub numbered: bool,
    /// Markdown として読む (code block と inline code の外だけを数える)
    pub md: bool,
    /// 直し方の種類 (commit・title・body・long)
    pub fix: String,
    pub text: String,
}

/// 見つけた参照 1 つ
#[derive(Clone, Debug, PartialEq, Eq)]
struct Found {
    line: usize,
    reference: String,
    ctx: String,
}

/// 文の並びを調べ、参照があれば (直し方の種類 (並べて重ねない)、理由に書く行) を返す。`own` は同じ repo (小文字の owner/repo)
pub fn report(texts: &[Text], own: &[String]) -> Option<(Vec<String>, String)> {
    let mut hits: Vec<(&Text, Found)> = Vec::new();
    for t in texts {
        for f in refs_of(t, own) {
            hits.push((t, f));
        }
    }
    if hits.is_empty() {
        return None;
    }
    let mut fixes: Vec<String> = hits.iter().map(|(t, _)| t.fix.clone()).collect();
    fixes.sort();
    fixes.dedup();
    let mut lines: Vec<String> = hits.iter().take(20).map(|(t, f)| line_of(t, f)).collect();
    if hits.len() > 20 {
        lines.push(format!("- ほか {} 件", hits.len() - 20));
    }
    Some((fixes, lines.join("\n")))
}

/// `git log --format='%H%x1f%B%x1e'` の出力 → commit ごとの文
pub fn log_texts(log: &str) -> Vec<Text> {
    log.split('\u{1e}')
        .filter_map(|e| {
            let e = e.strip_prefix('\n').unwrap_or(e);
            let (sha, msg) = e.split_once('\u{1f}')?;
            let short: String = sha.chars().take(7).collect();
            let first = msg.split('\n').next().unwrap_or("");
            Some(Text {
                head: format!("commit {short}「{}」の", clip(first, 40)),
                suffix: String::new(),
                numbered: true,
                md: false,
                fix: "commit".to_string(),
                text: msg.to_string(),
            })
        })
        .collect()
}

fn line_of(t: &Text, f: &Found) -> String {
    if t.numbered {
        format!(
            "- {} {} 行目{}: {} —「{}」",
            t.head, f.line, t.suffix, f.reference, f.ctx
        )
    } else {
        format!("- {}{}: {}", t.head, t.suffix, f.reference)
    }
}

/// jq の clip: n 文字を超えたら n - 1 文字と「…」
pub fn clip(s: &str, n: usize) -> String {
    let len = s.chars().count();
    if len > n {
        let mut out: String = s.chars().take(n - 1).collect();
        out.push('…');
        out
    } else {
        s.to_string()
    }
}

/// 行のうち、参照のまわりだけを見せる (jq の around)
fn around(line: &str, reference: &str) -> String {
    let chars: Vec<char> = line.chars().collect();
    let len = chars.len();
    if len <= 60 {
        return line.to_string();
    }
    let Some(byte_i) = line.find(reference) else {
        return clip(line, 60);
    };
    let i = line[..byte_i].chars().count();
    let s = i.saturating_sub(25);
    let e = i + reference.chars().count() + 25;
    let mut out = String::new();
    if s > 0 {
        out.push('…');
    }
    out.extend(&chars[s.min(len)..e.min(len)]);
    if e < len {
        out.push('…');
    }
    out
}

/// 1 つの文の参照。同じ参照は最初の行だけ
fn refs_of(t: &Text, own: &[String]) -> Vec<Found> {
    let orig: Vec<&str> = t.text.split('\n').collect();
    let scanned = if t.md {
        strip_spans(&strip_fences(&t.text))
    } else {
        t.text.clone()
    };
    let mut out: Vec<Found> = Vec::new();
    for (i, line) in scanned.split('\n').enumerate() {
        let chars: Vec<char> = line.chars().collect();
        let mut ms = match_r1(&chars);
        ms.extend(match_r2(&chars));
        ms.sort_by_key(|m| m.0);
        for (start, end, slug) in ms {
            if own.iter().any(|o| *o == slug.to_ascii_lowercase()) {
                continue;
            }
            let reference: String = chars[start..end].iter().collect();
            if out.iter().any(|f| f.reference == reference) {
                continue;
            }
            let ctx = around(orig.get(i).copied().unwrap_or(line), &reference);
            out.push(Found {
                line: i + 1,
                reference,
                ctx,
            });
        }
    }
    out
}

fn is_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// `(?<![A-Za-z0-9_./-])(?<o>[A-Za-z0-9][A-Za-z0-9-]*)/(?<r>[A-Za-z0-9_.-]+)(?:#[0-9]+|@[0-9a-fA-F]{7,40})(?![A-Za-z0-9_])`
fn match_r1(c: &[char]) -> Vec<(usize, usize, String)> {
    let n = c.len();
    let mut out = Vec::new();
    let mut i = 0;
    while i < n {
        let lb_ok = i == 0 || !(is_word(c[i - 1]) || matches!(c[i - 1], '.' | '/' | '-'));
        if c[i].is_ascii_alphanumeric() && lb_ok {
            let mut j = i + 1;
            while j < n && (c[j].is_ascii_alphanumeric() || c[j] == '-') {
                j += 1;
            }
            if j < n && c[j] == '/' {
                let rs = j + 1;
                let mut k = rs;
                while k < n && (is_word(c[k]) || matches!(c[k], '.' | '-')) {
                    k += 1;
                }
                if k > rs && k < n {
                    let end = match c[k] {
                        '#' => {
                            let mut d = k + 1;
                            while d < n && c[d].is_ascii_digit() {
                                d += 1;
                            }
                            (d > k + 1 && !(d < n && is_word(c[d]))).then_some(d)
                        }
                        '@' => {
                            let mut d = k + 1;
                            while d < n && c[d].is_ascii_hexdigit() {
                                d += 1;
                            }
                            let h = d - k - 1;
                            ((7..=40).contains(&h) && !(d < n && is_word(c[d]))).then_some(d)
                        }
                        _ => None,
                    };
                    if let Some(end) = end {
                        let slug: String = c[i..k].iter().collect();
                        out.push((i, end, slug));
                        i = end;
                        continue;
                    }
                }
            }
        }
        i += 1;
    }
    out
}

/// 大文字小文字を問わず `lit` で始まるか
fn starts_ci(c: &[char], at: usize, lit: &str) -> bool {
    let l: Vec<char> = lit.chars().collect();
    at + l.len() <= c.len()
        && c[at..at + l.len()]
            .iter()
            .zip(&l)
            .all(|(a, b)| a.eq_ignore_ascii_case(b))
}

/// `https?://(?:www\.)?github\.com/(?<o>[A-Za-z0-9_.-]+)/(?<r>[A-Za-z0-9_.-]+)/(?:(?:issues|pull|discussions)/[0-9]+|commit/[0-9a-fA-F]{7,40})(?![A-Za-z0-9_])`
/// (大文字小文字を問わない)
fn match_r2(c: &[char]) -> Vec<(usize, usize, String)> {
    let n = c.len();
    let seg = |k: usize| -> usize {
        let mut e = k;
        while e < n && (is_word(c[e]) || matches!(c[e], '.' | '-')) {
            e += 1;
        }
        e
    };
    let mut out = Vec::new();
    let mut i = 0;
    while i < n {
        let found = (|| -> Option<(usize, String)> {
            if !starts_ci(c, i, "http") {
                return None;
            }
            let mut p = i + 4;
            if starts_ci(c, p, "s://") {
                p += 1;
            }
            if !starts_ci(c, p, "://") {
                return None;
            }
            p += 3;
            if starts_ci(c, p, "www.github.com/") {
                p += 4;
            }
            if !starts_ci(c, p, "github.com/") {
                return None;
            }
            p += 11;
            let oe = seg(p);
            if oe == p || oe >= n || c[oe] != '/' {
                return None;
            }
            let re = seg(oe + 1);
            if re == oe + 1 || re >= n || c[re] != '/' {
                return None;
            }
            let slug: String = c[p..re].iter().collect();
            let q = re + 1;
            for kind in ["issues/", "pull/", "discussions/"] {
                if starts_ci(c, q, kind) {
                    let s = q + kind.len();
                    let mut d = s;
                    while d < n && c[d].is_ascii_digit() {
                        d += 1;
                    }
                    if d > s && !(d < n && is_word(c[d])) {
                        return Some((d, slug));
                    }
                    return None;
                }
            }
            if starts_ci(c, q, "commit/") {
                let s = q + 7;
                let mut d = s;
                while d < n && c[d].is_ascii_hexdigit() {
                    d += 1;
                }
                if (7..=40).contains(&(d - s)) && !(d < n && is_word(c[d])) {
                    return Some((d, slug));
                }
            }
            None
        })();
        if let Some((end, slug)) = found {
            out.push((i, end, slug));
            i = end;
        } else {
            i += 1;
        }
    }
    out
}

/// code block (``` か ~~~ の囲み) の行を空にする。backquote の囲みの情報文字列に ` は来ない
fn strip_fences(text: &str) -> String {
    let mut fence: Option<String> = None;
    let mut out: Vec<String> = Vec::new();
    for line in text.split('\n') {
        let m = fence_at(line);
        if let Some(f) = &fence {
            if let Some((mf, mlen)) = &m
                && mf.chars().next() == f.chars().next()
                && mf.chars().count() >= f.chars().count()
                && line.chars().skip(*mlen).all(char::is_whitespace)
            {
                fence = None;
            }
            out.push(String::new());
        } else if let Some((mf, mlen)) = m
            && !(mf.starts_with('`') && line.chars().skip(mlen).any(|c| c == '`'))
        {
            fence = Some(mf);
            out.push(String::new());
        } else {
            out.push(line.to_string());
        }
    }
    out.join("\n")
}

/// `^ {0,3}(?<f>`{3,}|~{3,})` の (f, 全体の文字数)
fn fence_at(line: &str) -> Option<(String, usize)> {
    let chars: Vec<char> = line.chars().collect();
    let mut i = 0;
    while i < 3 && i < chars.len() && chars[i] == ' ' {
        i += 1;
    }
    let ch = *chars.get(i)?;
    if ch != '`' && ch != '~' {
        return None;
    }
    let mut j = i;
    while j < chars.len() && chars[j] == ch {
        j += 1;
    }
    (j - i >= 3).then(|| (chars[i..j].iter().collect(), j))
}

/// inline code を外す (閉じない backquote は空行を越えない)。行の番号を保つよう、中の改行は残す
fn strip_spans(text: &str) -> String {
    let c: Vec<char> = text.chars().collect();
    let n = c.len();
    let mut out = String::new();
    let mut i = 0;
    while i < n {
        if c[i] == '`' && (i == 0 || c[i - 1] != '`') {
            let mut l = i;
            while l < n && c[l] == '`' {
                l += 1;
            }
            let run = l - i;
            let start = l;
            let mut end = None;
            let mut e = start + 1;
            while e <= n {
                // 中身の最後の文字 (e - 1) で空行が始まるなら、そこより先へは伸ばせない
                let p = e - 1;
                if c[p] == '\n' {
                    let mut q = p + 1;
                    while q < n && matches!(c[q], ' ' | '\t') {
                        q += 1;
                    }
                    if q < n && c[q] == '\n' {
                        break;
                    }
                }
                if e + run <= n
                    && c[e..e + run].iter().all(|&x| x == '`')
                    && c[e - 1] != '`'
                    && !(e + run < n && c[e + run] == '`')
                {
                    end = Some(e);
                    break;
                }
                e += 1;
            }
            match end {
                Some(e) => {
                    out.push(' ');
                    out.extend(c[start..e].iter().filter(|&&x| x == '\n'));
                    i = e + run;
                }
                None => {
                    out.extend(&c[i..l]);
                    i = l;
                }
            }
            continue;
        }
        out.push(c[i]);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 拾う形 (owner/repo#番号・@sha・github.com の URL) と拾わない形 (foo.bar/baz#1・owner/repo#12abc・6 桁の sha・同じ repo)
    //! - Markdown の code block と inline code の中は数えず、閉じない backquote は空行を越えない。行の番号を保つ
    //! - 21 件目からは件数だけ。git log の出力を commit ごとの文にする

    use super::*;

    fn md(text: &str) -> Text {
        Text {
            head: "本文の".to_string(),
            suffix: " (backquote の外)".to_string(),
            numbered: true,
            md: true,
            fix: "body".to_string(),
            text: text.to_string(),
        }
    }

    fn refs(text: &str) -> Vec<String> {
        refs_of(&md(text), &["pollenjp/dotfiles".to_string()])
            .into_iter()
            .map(|f| f.reference)
            .collect()
    }

    #[test]
    fn finds_reference_shapes() {
        for r in [
            "NixOS/nixpkgs#577218",
            "https://github.com/NixOS/nixpkgs/pull/577218",
            "https://GitHub.com/NixOS/nixpkgs/discussions/2",
            "https://www.github.com/NixOS/nixpkgs/commit/abcdef1",
            "NixOS/nixpkgs@abcdef1234",
        ] {
            assert_eq!(refs(&format!("see {r} x")), vec![r.to_string()], "{r}");
        }
        assert_eq!(refs("これはNixOS/nixpkgs#1を待つ"), vec!["NixOS/nixpkgs#1"]);
        for none in [
            "foo.bar/baz#1",
            "owner/repo#12abc",
            "owner/repo@abcde1",
            "#12",
            "PollenJP/Dotfiles#3",
            "https://github.com/NixOS/nixpkgs",
            "a/b/c#1",
        ] {
            assert!(refs(none).is_empty(), "{none}");
        }
    }

    #[test]
    fn skips_code() {
        assert!(refs("- `NixOS/nixpkgs#1` を待つ").is_empty());
        assert!(refs("```\nNixOS/nixpkgs#1\n```").is_empty());
        assert!(refs("~~~sh\nNixOS/nixpkgs#1\n~~~").is_empty());
        assert!(refs("``a `NixOS/nixpkgs#1` b``").is_empty());
        assert_eq!(
            refs("[`x`](https://github.com/NixOS/nixpkgs/pull/1)").len(),
            1
        );
        assert_eq!(refs("`閉じない\n\nNixOS/nixpkgs#1 `").len(), 1);
        let f = refs_of(&md("```\nx\n```\nNixOS/nixpkgs#1"), &[]);
        assert_eq!(f[0].line, 4);
    }

    #[test]
    fn report_lines() {
        let texts: Vec<Text> = (1..=25)
            .map(|i| Text {
                head: "commit".to_string(),
                suffix: String::new(),
                numbered: false,
                md: false,
                fix: "commit".to_string(),
                text: format!("acme/open#{i}"),
            })
            .collect();
        let (fixes, lines) = report(&texts, &[]).unwrap();
        assert_eq!(fixes, vec!["commit"]);
        assert!(lines.ends_with("- ほか 5 件"));
        let log = "abcdef1234\u{1f}fix: x\n\nbody\n\u{1e}\nfedcba98\u{1f}y\n\u{1e}\n";
        let t = log_texts(log);
        assert_eq!(t.len(), 2);
        assert_eq!(t[0].head, "commit abcdef1「fix: x」の");
        assert_eq!(t[1].text, "y\n");
    }

    #[test]
    fn context_around() {
        let line = format!("{}NixOS/nixpkgs#1{}", "あ".repeat(40), "い".repeat(40));
        let ctx = around(&line, "NixOS/nixpkgs#1");
        assert!(ctx.starts_with('…') && ctx.ends_with('…'));
        assert_eq!(ctx.chars().count(), 1 + 25 + 15 + 25 + 1);
    }
}
