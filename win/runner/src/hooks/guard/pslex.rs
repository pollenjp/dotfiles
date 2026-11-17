//! PowerShell の書き方のコマンドの文字を単純コマンドに分ける lexer (Windows の Claude Code の PowerShell の tool)。bash の lexer (`lex`) と同じ
//! レコード (`Cmd`) を出し、読み手は bash と同じものを使う (dotfiles-private の docs/adr/067_win_hook_guards_*)。PowerShell の文法を全部は読まない:
//! guard が見るもの (コマンドの名前と引数・パイプ・書き先・同じコマンドの中の代入) が取れる形に近づける。
//!
//! - `'…'` (`''` は `'`)・`"…"` (`""` と backtick の escape)・here-string (`@'…'@`・`@"…"@`) を外して語にする。`"…"` と here-string の `@"…"@`・
//!   引用符の無い語の `$name`・`${name}`・`$env:NAME`・`$HOME` は、同じコマンドの前の方で代入した値か、hook の env の値 (`$env:`) に置き換える
//!   (分からなければ字のまま)
//! - `;`・改行・`&&`・`||`・`|` (パイプ)・`(` `)` `{` `}` で分ける。`&` は文の頭なら呼び出しの演算子 (次の語がコマンド)、ほかは区切り
//! - `$( … )`・`@( … )`・引数の中の `( … )` は、中を別の単純コマンドとしても読み、語には値 (`Get-Content <file>` ならファイルの印、ほかは
//!   `$(中の文字)`) を入れる
//! - `$name = 値` は覚えて後ろの `$name` に入れる (右がコマンドなら、そのコマンドも読む)。`$env:NAME = 値` は、後ろの単純コマンドの頭に
//!   `NAME=値` を付ける (bash の `NAME=値 cmd` と同じに読み手が見る。通す口 `$env:PJP_ALLOW_XREF='1'` もこれで効く)
//! - 引用符・変数で始まる文 (`'本文' | gh … -F -`) は、その値を出す `echo` の単純コマンドにする (パイプの先が stdin を読む)
//! - `>`・`>>`・`1>` の先は書き先にし、`2>`・`*>`・`2>&1` などは捨てる。`#` から行末と `<# … #>` はコメント。backtick と改行は行の続き。
//!   `--%` の後ろは行末まで空白で分けた語

use super::World;
use super::lex::{Cmd, MARK_CLOSE, MARK_OPEN, Stdin};
use std::collections::HashMap;

/// 語の頭の形 (文がコマンドか式かを決める)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Bare,
    Quoted,
    Var,
    Sub,
}

#[derive(Clone, Debug)]
struct Tok {
    text: String,
    kind: Kind,
}

/// PowerShell のコマンドの文字を単純コマンドに分ける
pub fn split_commands(src: &str, world: &World) -> Vec<Cmd> {
    let mut lx = Ps::new(world, HashMap::new());
    lx.run(src);
    lx.cmds
}

struct Ps<'w, 'a> {
    world: &'w World<'a>,
    cmds: Vec<Cmd>,
    toks: Vec<Tok>,
    cur: String,
    in_tok: bool,
    cur_kind: Kind,
    /// 書き先を待っているリダイレクトの fd (`""`・`1`・`2`・`*` など)
    redirect: Option<String>,
    outf: String,
    pipein: bool,
    /// 代入の文 (`$name = …`) の変数の名前 (小文字。`env:NAME` も)
    assign: Option<String>,
    /// 文の頭の `&` (次の語は引用符でもコマンド)
    call: bool,
    vars: HashMap<String, String>,
    /// `$env:NAME = 値` で付けた env (書いた名前・値)
    env: Vec<(String, String)>,
    queue: Vec<String>,
    /// `$( )` の値を読む lexer の入れ子の深さ
    nest: usize,
}

fn is_sq(c: char) -> bool {
    matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201a}' | '\u{201b}')
}

fn is_dq(c: char) -> bool {
    matches!(c, '"' | '\u{201c}' | '\u{201d}' | '\u{201e}')
}

fn at(s: &[char], i: usize) -> Option<char> {
    s.get(i).copied()
}

/// backtick の escape (`"…"` の中)
fn escaped(c: char) -> char {
    match c {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '0' => '\0',
        'a' => '\u{7}',
        'b' => '\u{8}',
        'f' => '\u{c}',
        'v' => '\u{b}',
        'e' => '\u{1b}',
        other => other,
    }
}

/// `s[i]` が here-string の始まり (`@'` か `@"` の後ろに空白だけで改行) なら、本文の 1 文字目の位置
fn here_start(s: &[char], i: usize) -> Option<usize> {
    if at(s, i) != Some('@') {
        return None;
    }
    let q = at(s, i + 1)?;
    if !is_sq(q) && !is_dq(q) {
        return None;
    }
    let mut j = i + 2;
    while matches!(at(s, j), Some(' ' | '\t' | '\r')) {
        j += 1;
    }
    (at(s, j) == Some('\n')).then_some(j + 1)
}

/// here-string の終わり (行の頭の `'@` か `"@`) を探す。本文の終わり (改行の位置) と、終わりの印の `@` の位置
fn here_end(s: &[char], body: usize, dq: bool) -> (usize, usize) {
    let n = s.len();
    // 本文が空 (@'\n'@) のときは、始まりの改行がそのまま終わりの印の前の改行
    let mut k = body.saturating_sub(1);
    while k < n {
        if s[k] == '\n'
            && let Some(q) = at(s, k + 1)
            && (if dq { is_dq(q) } else { is_sq(q) })
            && at(s, k + 2) == Some('@')
        {
            return (k, k + 2);
        }
        k += 1;
    }
    (n, n)
}

/// `"…"` の中の `$( )` と、`$( )` の値を読む lexer の入れ子をたどる深さの上限 (Windows の main thread の stack は 1 MB しか無い。これより深い
/// ものは閉じない・値は中の文字のまま、とみなす)
const MAX_NEST: usize = 64;

/// `s[p]` の `(` に対応する `)` の位置 (無ければ `s.len()`)。引用符・here-string・コメント・backtick の中の括弧は数えない
fn paren_end(s: &[char], p: usize) -> usize {
    paren_end_n(s, p, 0)
}

fn paren_end_n(s: &[char], p: usize, nest: usize) -> usize {
    let n = s.len();
    if nest > MAX_NEST {
        return n;
    }
    let mut depth = 0i64;
    let mut j = p;
    while j < n {
        let c = s[j];
        if c == '`' {
            j += 2;
            continue;
        }
        if let Some(b) = here_start(s, j) {
            let dq = is_dq(s[j + 1]);
            j = here_end(s, b, dq).1 + 1;
            continue;
        }
        if is_sq(c) {
            j += 1;
            while j < n {
                if is_sq(s[j]) {
                    if at(s, j + 1).is_some_and(is_sq) {
                        j += 2;
                        continue;
                    }
                    break;
                }
                j += 1;
            }
        } else if is_dq(c) {
            j += 1;
            while j < n {
                let d = s[j];
                if d == '`' {
                    j += 2;
                    continue;
                }
                if is_dq(d) {
                    if at(s, j + 1).is_some_and(is_dq) {
                        j += 2;
                        continue;
                    }
                    break;
                }
                if d == '$' && at(s, j + 1) == Some('(') {
                    j = paren_end_n(s, j + 1, nest + 1) + 1;
                    continue;
                }
                j += 1;
            }
        } else if c == '<' && at(s, j + 1) == Some('#') {
            match (j + 2..n.saturating_sub(1)).find(|&k| s[k] == '#' && s[k + 1] == '>') {
                Some(k) => j = k + 1,
                None => return n,
            }
        } else if c == '#'
            && (j == 0 || matches!(s[j - 1], ' ' | '\t' | '\n' | ';' | '(' | '{' | '|'))
        {
            match s[j..].iter().position(|&x| x == '\n') {
                Some(k) => j += k - 1,
                None => return n,
            }
        } else if c == '(' {
            depth += 1;
        } else if c == ')' {
            depth -= 1;
            if depth == 0 {
                return j;
            }
        }
        j += 1;
    }
    n
}

impl<'w, 'a> Ps<'w, 'a> {
    fn new(world: &'w World<'a>, vars: HashMap<String, String>) -> Self {
        Ps {
            world,
            cmds: Vec::new(),
            toks: Vec::new(),
            cur: String::new(),
            in_tok: false,
            cur_kind: Kind::Bare,
            redirect: None,
            outf: String::new(),
            pipein: false,
            assign: None,
            call: false,
            vars,
            env: Vec::new(),
            queue: Vec::new(),
            nest: 0,
        }
    }

    fn run(&mut self, src: &str) {
        let src = src.replace("\r\n", "\n");
        let chars: Vec<char> = src.chars().collect();
        self.lex(&chars);
        self.flush(false);
        let mut qi = 0;
        while qi < self.queue.len() {
            self.pipein = false;
            let inner: Vec<char> = self.queue[qi].chars().collect();
            self.lex(&inner);
            self.flush(false);
            qi += 1;
        }
    }

    fn add(&mut self, s: &str, kind: Kind) {
        if !self.in_tok {
            self.cur_kind = kind;
            self.in_tok = true;
        }
        self.cur.push_str(s);
    }

    fn end_tok(&mut self) {
        if !self.in_tok {
            return;
        }
        let text = std::mem::take(&mut self.cur);
        self.in_tok = false;
        if let Some(fd) = self.redirect.take() {
            if fd.is_empty() || fd == "1" {
                self.outf = text;
            }
            return;
        }
        self.toks.push(Tok {
            text,
            kind: self.cur_kind,
        });
    }

    fn env_words(&self) -> Vec<String> {
        self.env.iter().map(|(n, v)| format!("{n}={v}")).collect()
    }

    fn push_cmd(&mut self, words: Vec<String>) {
        let mut all = self.env_words();
        all.extend(words);
        while all.last().is_some_and(String::is_empty) {
            all.pop();
        }
        self.cmds.push(Cmd {
            pipe: self.pipein,
            stdin: Stdin::None,
            outf: std::mem::take(&mut self.outf),
            net: Vec::new(),
            words: all,
            ps: true,
        });
    }

    /// 文を 1 つ閉じる。`pipe` なら、次の文はこの文の出力をパイプで受ける
    fn flush(&mut self, pipe: bool) {
        self.end_tok();
        self.redirect = None;
        let toks = std::mem::take(&mut self.toks);
        let call = std::mem::replace(&mut self.call, false);
        let mut stored = false;
        if let Some(name) = self.assign.take() {
            let command = !toks.is_empty() && (call || !value_tok(&toks[0]));
            let words: Vec<String> = toks.iter().map(|t| t.text.clone()).collect();
            let value = if command {
                file_mark(&words)
            } else if !toks.is_empty()
                && toks
                    .iter()
                    .all(|t| value_tok(t) || (t.kind == Kind::Bare && t.text == "+"))
            {
                // 'a' + 'b' のような文字のつなぎ
                Some(
                    toks.iter()
                        .filter(|t| value_tok(t))
                        .map(|t| t.text.as_str())
                        .collect(),
                )
            } else {
                None
            };
            let value = value.filter(|v| v != "$null");
            if command {
                self.push_cmd(words);
                stored = true;
            }
            let lower = name.to_lowercase();
            if lower.starts_with("env:") {
                let env = &name[4..];
                self.env.retain(|(n, _)| !n.eq_ignore_ascii_case(env));
                if let Some(v) = value {
                    self.env.push((env.to_string(), v));
                }
            } else {
                match value {
                    Some(v) => {
                        self.vars.insert(lower, v);
                    }
                    None => {
                        self.vars.remove(&lower);
                    }
                }
            }
        } else if !toks.is_empty() {
            if call || !value_tok(&toks[0]) {
                self.push_cmd(toks.into_iter().map(|t| t.text).collect());
            } else {
                // 式の文 ('本文' | …): 値を出す echo にする
                let v = toks[0].text.clone();
                self.push_cmd(vec!["echo".to_string(), v]);
            }
            stored = true;
        } else {
            self.outf.clear();
        }
        if stored || pipe {
            self.pipein = pipe;
        }
    }

    /// 変数の値 (`name` は `$` を除いた字。分からなければ None)
    fn var_value(&self, name: &str) -> Option<String> {
        let l = name.to_lowercase();
        if let Some(env) = l.strip_prefix("env:") {
            if let Some((_, v)) = self
                .env
                .iter()
                .rev()
                .find(|(n, _)| n.eq_ignore_ascii_case(env))
            {
                return Some(v.clone());
            }
            return self.world.sys.env(&name[4..]).filter(|v| !v.is_empty());
        }
        let base = ["script:", "global:", "local:", "private:", "using:"]
            .iter()
            .find_map(|p| l.strip_prefix(p))
            .unwrap_or(&l);
        if base == "home" {
            return Some(self.world.home.clone());
        }
        self.vars.get(base).cloned()
    }

    /// `s[i]` の `$` からの変数・`$( )` を読む。(値、読み終えた最後の位置)
    fn dollar(&mut self, s: &[char], i: usize) -> (String, usize) {
        let n = s.len();
        match at(s, i + 1) {
            Some('(') => {
                let e = paren_end(s, i + 1);
                let inner: String = s[i + 2..e.min(n)].iter().collect();
                self.queue.push(inner.clone());
                (self.subst_value(&inner), e)
            }
            Some('{') => {
                let close = s[i + 2..].iter().position(|&c| c == '}');
                match close {
                    Some(k) => {
                        let name: String = s[i + 2..i + 2 + k].iter().collect();
                        let raw: String = s[i..=i + 2 + k].iter().collect();
                        (self.var_value(&name).unwrap_or(raw), i + 2 + k)
                    }
                    None => (s[i..].iter().collect(), n),
                }
            }
            Some(c) if c.is_alphanumeric() || c == '_' => {
                let (name, e) = read_var_name(s, i + 1);
                let raw: String = s[i..e].iter().collect();
                (self.var_value(&name).unwrap_or(raw), e - 1)
            }
            Some(c @ ('$' | '?' | '^')) => (format!("${c}"), i + 1),
            _ => ("$".to_string(), i),
        }
    }

    /// `$( )` の値: `Get-Content <file>` (`gc`・`cat`・`type` も) だけならファイルの印、ほかは `$(中の文字)`
    fn subst_value(&self, inner: &str) -> String {
        // 頭の語が Get-Content (gc・cat・type) のときだけ読む (ほかは中を読み直さない。入れ子の深いコマンドで二乗に遅くならないように)
        let head: String = inner
            .trim_start()
            .chars()
            .take_while(|c| !c.is_whitespace() && !matches!(c, ';' | '|' | '(' | ')' | '{' | '}'))
            .collect();
        let name = super::base_name(head.trim_matches(['\'', '"']), true);
        if self.nest >= MAX_NEST || super::ps_alias(&name) != "get-content" {
            return format!("$({inner})");
        }
        let mut sub = Ps::new(self.world, self.vars.clone());
        sub.nest = self.nest + 1;
        let chars: Vec<char> = inner.replace("\r\n", "\n").chars().collect();
        sub.lex(&chars);
        sub.flush(false);
        if sub.cmds.len() == 1
            && let Some(m) = file_mark(&sub.cmds[0].words)
        {
            return m;
        }
        format!("$({inner})")
    }

    /// 文の頭か (語も代入も無い)
    fn at_start(&self) -> bool {
        self.toks.is_empty() && !self.in_tok && self.assign.is_none()
    }

    /// 引用符で囲んだ `"…"` を読む (`s[i]` は開きの引用符)。閉じの位置を返す
    fn dq(&mut self, s: &[char], i: usize) -> usize {
        let n = s.len();
        let start_kind = Kind::Quoted;
        self.add("", start_kind);
        let mut j = i + 1;
        while j < n {
            let d = s[j];
            if is_dq(d) {
                if at(s, j + 1).is_some_and(is_dq) {
                    self.cur.push('"');
                    j += 2;
                    continue;
                }
                return j;
            }
            if d == '`' {
                if let Some(x) = at(s, j + 1) {
                    self.cur.push(escaped(x));
                }
                j += 2;
                continue;
            }
            if d == '$' {
                let (v, e) = self.dollar(s, j);
                self.cur.push_str(&v);
                j = e + 1;
                continue;
            }
            self.cur.push(d);
            j += 1;
        }
        n
    }

    /// here-string の本文を足す (`@"…"@` は変数と escape を読む)。終わりの印の `@` の位置を返す
    fn here(&mut self, s: &[char], i: usize, body: usize) -> usize {
        let dq = is_dq(s[i + 1]);
        let (end, last) = here_end(s, body, dq);
        self.add("", Kind::Quoted);
        if !dq {
            let text: String = s[body.min(end)..end].iter().collect();
            self.cur.push_str(&text);
            return last;
        }
        let mut j = body;
        while j < end {
            let d = s[j];
            if d == '`' {
                if let Some(x) = at(s, j + 1) {
                    self.cur.push(escaped(x));
                }
                j += 2;
                continue;
            }
            if d == '$' {
                let (v, e) = self.dollar(&s[..end], j);
                self.cur.push_str(&v);
                j = e + 1;
                continue;
            }
            self.cur.push(d);
            j += 1;
        }
        last
    }

    fn lex(&mut self, s: &[char]) {
        let n = s.len();
        let mut i = 0;
        while i < n {
            let c = s[i];
            // --% の後ろは行末まで、空白で分けた語 (引用符は外す)
            if !self.in_tok
                && c == '-'
                && s[i..].starts_with(&['-', '-', '%'])
                && !matches!(at(s, i + 3), Some(x) if !x.is_whitespace())
            {
                let end = s[i..].iter().position(|&x| x == '\n').map_or(n, |k| i + k);
                let rest: String = s[i + 3..end].iter().collect();
                for w in rest.split_whitespace() {
                    self.toks.push(Tok {
                        text: w.trim_matches('"').to_string(),
                        kind: Kind::Bare,
                    });
                }
                i = end;
                continue;
            }
            match c {
                ' ' | '\t' | '\r' => self.end_tok(),
                '\n' | ';' => self.flush(false),
                '|' => {
                    if at(s, i + 1) == Some('|') {
                        i += 1;
                        self.flush(false);
                    } else {
                        self.flush(true);
                    }
                }
                '&' => {
                    if at(s, i + 1) == Some('&') {
                        i += 1;
                        self.flush(false);
                    } else if self.toks.is_empty() && !self.in_tok {
                        // 呼び出しの演算子 (& 'C:\…\git.exe' push・& { … })
                        self.call = true;
                    } else {
                        self.flush(false);
                    }
                }
                '#' if !self.in_tok => match s[i..].iter().position(|&x| x == '\n') {
                    Some(k) => i += k - 1,
                    None => i = n,
                },
                '<' if !self.in_tok && at(s, i + 1) == Some('#') => {
                    match (i + 2..n.saturating_sub(1)).find(|&k| s[k] == '#' && s[k + 1] == '>') {
                        Some(k) => i = k + 1,
                        None => i = n,
                    }
                }
                '`' => match at(s, i + 1) {
                    Some('\n') => {
                        self.end_tok();
                        i += 1;
                    }
                    Some(x) => {
                        self.add(&x.to_string(), Kind::Bare);
                        i += 1;
                    }
                    None => {}
                },
                c if is_sq(c) => {
                    self.add("", Kind::Quoted);
                    let mut j = i + 1;
                    while j < n {
                        if is_sq(s[j]) {
                            if at(s, j + 1).is_some_and(is_sq) {
                                self.cur.push('\'');
                                j += 2;
                                continue;
                            }
                            break;
                        }
                        self.cur.push(s[j]);
                        j += 1;
                    }
                    i = j;
                }
                c if is_dq(c) => i = self.dq(s, i),
                '@' if !self.in_tok && here_start(s, i).is_some() => {
                    let body = here_start(s, i).unwrap();
                    i = self.here(s, i, body);
                }
                '@' if !self.in_tok && at(s, i + 1) == Some('(') => {
                    let e = paren_end(s, i + 1);
                    let inner: String = s[i + 2..e.min(n)].iter().collect();
                    self.queue.push(inner.clone());
                    let v = self.subst_value(&inner);
                    self.add(&v, Kind::Sub);
                    i = e;
                }
                '@' if !self.in_tok && at(s, i + 1) == Some('{') => {
                    self.flush(false);
                    i += 1;
                }
                '$' => {
                    // 文の頭の $name = … は代入
                    if self.at_start() && !self.call {
                        let (name, e) = match at(s, i + 1) {
                            Some('{') => match s[i + 2..].iter().position(|&x| x == '}') {
                                Some(k) => {
                                    (s[i + 2..i + 2 + k].iter().collect::<String>(), i + 3 + k)
                                }
                                None => (String::new(), i),
                            },
                            Some(x) if x.is_alphanumeric() || x == '_' => read_var_name(s, i + 1),
                            _ => (String::new(), i),
                        };
                        if !name.is_empty() {
                            let mut j = e;
                            while matches!(at(s, j), Some(' ' | '\t')) {
                                j += 1;
                            }
                            let op_len = match (at(s, j), at(s, j + 1), at(s, j + 2)) {
                                (Some('='), Some(x), _) if x != '=' => 1,
                                (Some('='), None, _) => 1,
                                (Some('+' | '-' | '*' | '/' | '%'), Some('='), _) => 2,
                                (Some('?'), Some('?'), Some('=')) => 3,
                                _ => 0,
                            };
                            if op_len > 0 {
                                self.assign = Some(name);
                                i = j + op_len;
                                continue;
                            }
                        }
                    }
                    let (v, e) = self.dollar(s, i);
                    let kind = if at(s, i + 1) == Some('(') {
                        Kind::Sub
                    } else {
                        Kind::Var
                    };
                    self.add(&v, kind);
                    i = e;
                }
                '(' => {
                    if self.at_start() && !self.call {
                        self.flush(false);
                    } else {
                        let e = paren_end(s, i);
                        let inner: String = s[i + 1..e.min(n)].iter().collect();
                        self.queue.push(inner.clone());
                        let v = self.subst_value(&inner);
                        self.add(&v, Kind::Sub);
                        i = e;
                    }
                }
                ')' | '{' | '}' => self.flush(false),
                '>' => {
                    let mut fd = String::new();
                    if self.in_tok
                        && self.cur_kind == Kind::Bare
                        && !self.cur.is_empty()
                        && (self.cur == "*" || self.cur.chars().all(|d| d.is_ascii_digit()))
                    {
                        fd = std::mem::take(&mut self.cur);
                        self.in_tok = false;
                    } else {
                        self.end_tok();
                    }
                    let mut j = i + 1;
                    if at(s, j) == Some('>') {
                        j += 1;
                    }
                    if at(s, j) == Some('&') {
                        j += 1;
                        while at(s, j).is_some_and(|d| d.is_ascii_digit()) {
                            j += 1;
                        }
                    } else {
                        self.redirect = Some(fd);
                    }
                    i = j - 1;
                }
                _ => self.add(&c.to_string(), Kind::Bare),
            }
            i += 1;
        }
    }
}

/// 値の語か (引用符・変数・`$( )`・数。引用符の無いほかの語はコマンドの名前)
fn value_tok(t: &Tok) -> bool {
    t.kind != Kind::Bare
        || (!t.text.is_empty()
            && t.text
                .trim_start_matches('-')
                .chars()
                .all(|c| c.is_ascii_digit() || c == '.')
            && t.text.chars().any(|c| c.is_ascii_digit()))
}

/// 変数の名前 (`name`・`env:NAME`・`script:name`) と、その次の位置
fn read_var_name(s: &[char], i: usize) -> (String, usize) {
    let n = s.len();
    let mut j = i;
    while j < n && (s[j].is_alphanumeric() || s[j] == '_') {
        j += 1;
    }
    let first: String = s[i..j].iter().collect();
    let scope = ["env", "script", "global", "local", "private", "using"];
    if at(s, j) == Some(':')
        && scope.contains(&first.to_lowercase().as_str())
        && at(s, j + 1).is_some_and(|c| c.is_alphanumeric() || c == '_')
    {
        let mut k = j + 1;
        while k < n && (s[k].is_alphanumeric() || s[k] == '_') {
            k += 1;
        }
        let rest: String = s[j + 1..k].iter().collect();
        return (format!("{first}:{rest}"), k);
    }
    (first, j)
}

/// `Get-Content <file>` (`gc`・`cat`・`type`) の語なら、そのファイルの印
fn file_mark(words: &[String]) -> Option<String> {
    let first = words.first()?;
    let name = super::base_name(first, true);
    if !matches!(super::ps_alias(&name), "get-content" | "cat") {
        return None;
    }
    let (named, pos) = super::ps_params(&words[1..], &["raw", "force", "wait", "asbytestream"]);
    let path = super::ps_named(&named, &["path", "literalpath"])
        .map(str::to_string)
        .or_else(|| pos.first().cloned())?;
    if path.is_empty() || path.contains(['$', '*', '?', '\n']) {
        return None;
    }
    Some(format!("{MARK_OPEN}{path}{MARK_CLOSE}"))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 引用符 (`''`・`""`・backtick の escape)・here-string・コメント・行の続き・`--%` を外して語にする
    //! - `;`・`&&`・`||`・`|`・`{ }`・`( )` で分け、文の頭の `&` の後ろの語をコマンドにする
    //! - `$name = 値` と `$env:NAME = 値` を後ろに効かせる (env は単純コマンドの頭の `NAME=値`)。式の文は echo にする
    //! - `$( )` の中も読み、`Get-Content <file>` の値はファイルの印。書き先 (`>`・`>>`) を残し、`2>`・`2>&1` は捨てる

    use super::*;
    use crate::testutil::FakeSys;

    fn split(src: &str) -> Vec<Cmd> {
        let sys = FakeSys::new(|_| unreachable!()).with_env("TEMP", "C:\\Temp");
        let w = World::with_style(&sys, ".", true);
        split_commands(src, &w)
    }

    fn words(src: &str) -> Vec<Vec<String>> {
        split(src).into_iter().map(|c| c.words).collect()
    }

    fn w(list: &[&[&str]]) -> Vec<Vec<String>> {
        list.iter()
            .map(|c| c.iter().map(|s| s.to_string()).collect())
            .collect()
    }

    #[test]
    fn quotes_and_separators() {
        assert_eq!(
            words("git commit -m 'it''s' && gh pr create --title \"a `\"b`\" \"\"c\"\"\""),
            w(&[
                &["git", "commit", "-m", "it's"],
                &["gh", "pr", "create", "--title", "a \"b\" \"c\""]
            ])
        );
        assert_eq!(
            words("git push # c\n<# block\n x #> ls; x || y"),
            w(&[&["git", "push"], &["ls"], &["x"], &["y"]])
        );
        assert_eq!(words("git `\n  push"), w(&[&["git", "push"]]));
        assert_eq!(
            words("& 'C:\\Program Files\\Git\\cmd\\git.exe' push"),
            w(&[&["C:\\Program Files\\Git\\cmd\\git.exe", "push"]])
        );
        assert_eq!(
            words("if ($x) { git push } else { gh pr view }"),
            w(&[
                &["if", "$($x)"],
                &["git", "push"],
                &["else"],
                &["gh", "pr", "view"],
                &["echo", "$x"]
            ])
        );
        assert_eq!(
            words("cmd --% /c \"git push\" x"),
            w(&[&["cmd", "/c", "git", "push", "x"]])
        );
    }

    #[test]
    fn here_strings_and_variables() {
        let c = split(
            "$body = @'\nline1\nNixOS/nixpkgs#1\n'@\ngh pr create --body $body --title \"t $body\"",
        );
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].words[4], "line1\nNixOS/nixpkgs#1");
        assert!(c[0].words[6].starts_with("t line1"));
        let c = split("@\"\na $env:TEMP `t\n\"@ | gh pr create -F -");
        assert_eq!(c[0].words, vec!["echo", "a C:\\Temp \t"]);
        assert!(c[1].pipe);
        let c =
            split("$env:PJP_ALLOW_XREF = '1'; gh pr create; $env:PJP_ALLOW_XREF = $null; git push");
        assert_eq!(c[0].words[0], "PJP_ALLOW_XREF=1");
        assert_eq!(c[1].words, vec!["git", "push"]);
        let c = split("$b = Get-Content -Raw body.md; gh pr create --body $b");
        assert_eq!(c[0].words, vec!["Get-Content", "-Raw", "body.md"]);
        assert_eq!(c[1].words[4], "\u{2}body.md\u{3}");
        let c = split("gh pr create --body (Get-Content body.md -Raw) --title $(git log -1)");
        assert_eq!(c[0].words[4], "\u{2}body.md\u{3}");
        assert_eq!(c[0].words[6], "$(git log -1)");
        assert!(c.iter().any(|x| x.words == vec!["git", "log", "-1"]));
        assert_eq!(words("$x = 'a' + 'b'; echo $x"), w(&[&["echo", "ab"]]));
        assert_eq!(
            words("$env:PJP_ALLOW_IAC = 1; terraform apply"),
            w(&[&["PJP_ALLOW_IAC=1", "terraform", "apply"]])
        );
        assert_eq!(words("$n = 3"), Vec::<Vec<String>>::new());
    }

    /// 引用符の中の $( ) を深く入れ子にしても stack が溢れない (Windows の main thread の stack は 1 MB)
    #[test]
    fn deep_nesting_does_not_overflow() {
        assert!(!split(&"echo \"$(".repeat(1000)).is_empty());
        assert!(!split(&"echo $(".repeat(1000)).is_empty());
    }

    #[test]
    fn redirections() {
        let c = split("'x' > body.md 2>$null; git push 2>&1 *> log.txt");
        assert_eq!(c[0].words, vec!["echo", "x"]);
        assert_eq!(c[0].outf, "body.md");
        assert_eq!(c[1].words, vec!["git", "push"]);
        assert_eq!(c[1].outf, "");
        let c = split("Set-Content -Path b.md -Value 'x' >> out.txt");
        assert_eq!(c[0].outf, "out.txt");
    }
}
