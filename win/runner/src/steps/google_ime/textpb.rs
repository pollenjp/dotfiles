//! protobuf のテキスト形式 (`config.txtpb`) の読み書き。pjp-google-ime が使う Python の protobuf の `text_format.Parse` と
//! `text_format.MessageToString(as_utf8=True)` (protobuf 7.36.2) を、要る型 (`pb::Ty`) の分だけ写したもの。
//!
//! - 読み: 行ごとに字句に分け (Python の `Tokenizer` と同じ正規表現の振る舞い)、項目ごとに読む。repeated でない項目が 2 度出たら止める
//!   (`Parse` は Merge と違い、上書きしない)。整数は Python の `int(…, 0)` と同じ書き方 (`0x`・`0o`・`0b`・`_`。頭が 0 の 10 進は 8 進)、bool は
//!   `true`・`t`・`1`・`True` とその逆、enum は名前か番号 (閉じた enum に無い番号は止める)。文字列は隣り合う引用を続け、エスケープは Python の
//!   `CUnescape` と同じ 4 段 (1 桁の `\x` を 2 桁に・raw_unicode_escape・unicode_escape・latin-1) で読む。`\N{…}` は読まない (Python は名前で字を引く)
//! - 書き: 値のある項目を番号の順に `名前: 値` (メッセージは `名前 {` と 2 字下げ)。string は UTF-8 のまま、制御文字と `"` `'` `\` だけを
//!   エスケープし、UTF-8 でないバイトは `\ooo` にする

use super::pb::{EnumDesc, Message, MsgDesc, Ty, Value};

/// 読めないところ (行と桁は 1 から。桁は字で数える)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    pub line: usize,
    pub column: usize,
    pub message: String,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}:{} : {}", self.line, self.column, self.message)
    }
}

// ------------------------------------------------------------------ 書く

/// テキスト形式にする (`MessageToString(as_utf8=True)` と同じ字)。
pub fn print(m: &Message) -> String {
    let mut out = String::new();
    print_into(m, 0, &mut out);
    out
}

fn print_into(m: &Message, indent: usize, out: &mut String) {
    for (f, values) in m.list() {
        for v in values {
            out.push_str(&" ".repeat(indent));
            out.push_str(f.name);
            match v {
                Value::Msg(sub) => {
                    out.push_str(" {\n");
                    print_into(sub, indent + 2, out);
                    out.push_str(&" ".repeat(indent));
                    out.push_str("}\n");
                }
                _ => {
                    out.push_str(": ");
                    out.push_str(&value_text(f.ty, v));
                    out.push('\n');
                }
            }
        }
    }
}

fn value_text(ty: Ty, v: &Value) -> String {
    match (ty, v) {
        (Ty::Enum(e), Value::I32(n)) => e.name_of(*n).map_or_else(|| n.to_string(), str::to_string),
        (_, Value::I32(n)) => n.to_string(),
        (_, Value::U32(n)) => n.to_string(),
        (_, Value::U64(n)) => n.to_string(),
        (_, Value::Bool(b)) => (if *b { "true" } else { "false" }).to_string(),
        (Ty::Bytes, Value::Bytes(b)) => format!("\"{}\"", escape_bytes(b)),
        (_, Value::Bytes(b)) => format!("\"{}\"", escape_utf8(b)),
        (_, Value::Msg(_)) => unreachable!("メッセージは print_into が書く"),
    }
}

/// ASCII の 1 字のエスケープ (Python の `_str_escapes`)。エスケープしない字は None
fn ascii_escape(c: u32) -> Option<String> {
    Some(match c {
        0x09 => "\\t".into(),
        0x0a => "\\n".into(),
        0x0d => "\\r".into(),
        0x22 => "\\\"".into(),
        0x27 => "\\'".into(),
        0x5c => "\\\\".into(),
        c if c < 32 || c == 127 => format!("\\{c:03o}"),
        _ => return None,
    })
}

/// string の値 (`CEscape(…, as_utf8=True)`): UTF-8 の字はそのまま (ASCII の制御文字と引用符と `\` だけエスケープ)、UTF-8 でないバイトは `\ooo`
fn escape_utf8(b: &[u8]) -> String {
    let mut out = String::new();
    let mut rest = b;
    loop {
        let (valid, bad) = match std::str::from_utf8(rest) {
            Ok(s) => (s, None),
            Err(e) => (
                std::str::from_utf8(&rest[..e.valid_up_to()]).expect("valid_up_to までは UTF-8"),
                Some(rest[e.valid_up_to()]),
            ),
        };
        for c in valid.chars() {
            match ascii_escape(c as u32) {
                Some(s) => out.push_str(&s),
                None => out.push(c),
            }
        }
        match bad {
            None => return out,
            Some(byte) => {
                out.push_str(&format!("\\{byte:03o}"));
                rest = &rest[valid.len() + 1..];
            }
        }
    }
}

/// bytes の値 (`CEscape(…, as_utf8=False)`): 表示できる ASCII のほかは全部エスケープ
fn escape_bytes(b: &[u8]) -> String {
    let mut out = String::new();
    for &byte in b {
        match ascii_escape(u32::from(byte)) {
            Some(s) => out.push_str(&s),
            None if byte < 128 => out.push(byte as char),
            None => out.push_str(&format!("\\{byte:03o}")),
        }
    }
    out
}

// ------------------------------------------------------------------ 字句

/// Python の正規表現 `\s` (str の isspace) に当たる字
fn is_py_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n'
            | '\u{0b}'
            | '\u{0c}'
            | '\r'
            | '\u{1c}'..='\u{1f}'
            | ' '
            | '\u{85}'
            | '\u{a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
    )
}

/// 行の `col` から、空白と `#` からのコメントが続く長さ (`(\s|(#.*$))+`。無ければ 0)
fn space_len(line: &[char], col: usize) -> usize {
    let mut i = col;
    while i < line.len() {
        if line[i] == '#' {
            i = line.len();
        } else if is_py_space(line[i]) {
            i += 1;
        } else {
            break;
        }
    }
    i - col
}

/// 行の `col` からの字句の長さ (識別子・数・引用の正規表現。どれにも当たらなければ 0 で、1 字の字句になる)
fn token_len(line: &[char], col: usize) -> usize {
    let c = line[col];
    let tail = |from: usize, ok: &dyn Fn(char) -> bool| {
        line[from..].iter().take_while(|c| ok(**c)).count()
    };
    if c.is_ascii_alphabetic() || c == '_' {
        // [a-zA-Z_][0-9a-zA-Z_+-]*
        1 + tail(col + 1, &|c| {
            c.is_ascii_alphanumeric() || matches!(c, '_' | '+' | '-')
        })
    } else if c.is_ascii_digit()
        || c == '+'
        || c == '-'
        || (c == '.' && line.get(col + 1).is_some_and(char::is_ascii_digit))
    {
        // ([0-9+-]|(\.[0-9]))[0-9a-zA-Z_.+-]*
        let head = if c == '.' { 2 } else { 1 };
        head + tail(col + head, &|c| {
            c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '+' | '-')
        })
    } else if c == '"' || c == '\'' {
        // {q}[^{q}\n\\]*((\\.)+[^{q}\n\\]*)*({q}|\\?$): 閉じる引用までか、行の終わりまで
        let mut i = col + 1;
        loop {
            if i >= line.len() {
                return line.len() - col;
            }
            if line[i] == c {
                return i + 1 - col;
            }
            if line[i] == '\\' {
                if i + 1 < line.len() {
                    i += 2;
                    continue;
                }
                return line.len() - col;
            }
            i += 1;
        }
    } else {
        0
    }
}

/// Python の `Tokenizer` を写したもの。
struct Tokenizer {
    lines: Vec<Vec<char>>,
    next_line: usize,
    /// 今の行の番号 (0 から。読む前は -1)
    line: isize,
    current: Vec<char>,
    column: usize,
    more_lines: bool,
    /// 今の字句 (空なら終わり)
    token: Vec<char>,
    prev_line: isize,
    prev_column: usize,
}

impl Tokenizer {
    fn new(text: &str) -> Tokenizer {
        let mut t = Tokenizer {
            lines: text.split('\n').map(|l| l.chars().collect()).collect(),
            next_line: 0,
            line: -1,
            current: Vec::new(),
            column: 0,
            more_lines: true,
            token: Vec::new(),
            prev_line: 0,
            prev_column: 0,
        };
        t.skip_space();
        t.next_token();
        t
    }

    fn pop_line(&mut self) {
        while self.current.len() <= self.column {
            let Some(l) = self.lines.get(self.next_line) else {
                self.current.clear();
                self.more_lines = false;
                return;
            };
            self.current = l.clone();
            self.next_line += 1;
            self.line += 1;
            self.column = 0;
        }
    }

    fn skip_space(&mut self) {
        loop {
            self.pop_line();
            let n = space_len(&self.current, self.column);
            if n == 0 {
                break;
            }
            self.column += n;
        }
    }

    fn next_token(&mut self) {
        self.prev_line = self.line;
        self.prev_column = self.column;
        self.column += self.token.len();
        self.skip_space();
        if !self.more_lines {
            self.token.clear();
            return;
        }
        let n = token_len(&self.current, self.column).max(1);
        self.token = self.current[self.column..self.column + n].to_vec();
    }

    fn at_end(&self) -> bool {
        self.token.is_empty()
    }

    fn text(&self) -> String {
        self.token.iter().collect()
    }

    fn is(&self, s: &str) -> bool {
        self.token.iter().copied().eq(s.chars())
    }

    fn try_consume(&mut self, s: &str) -> bool {
        if self.is(s) {
            self.next_token();
            true
        } else {
            false
        }
    }

    fn consume(&mut self, s: &str) -> Result<(), ParseError> {
        if self.try_consume(s) {
            Ok(())
        } else {
            Err(self.error(format!("「{s}」が要る")))
        }
    }

    /// 今の字句の誤り (Python の ParseError。行の字を添える)
    fn error(&self, message: String) -> ParseError {
        let current: String = self.current.iter().collect();
        ParseError {
            line: (self.line + 1).max(0) as usize,
            column: self.column + 1,
            message: format!("'{current}': {message}"),
        }
    }

    /// 前の字句の誤り (Python の ParseErrorPreviousToken)
    fn error_prev(&self, message: String) -> ParseError {
        ParseError {
            line: (self.prev_line + 1).max(0) as usize,
            column: self.prev_column + 1,
            message,
        }
    }
}

// ------------------------------------------------------------------ 読む

/// テキスト形式を読む (`text_format.Parse`)。
pub fn parse(desc: &'static MsgDesc, text: &str) -> Result<Message, ParseError> {
    let mut t = Tokenizer::new(text);
    let mut m = Message::new(desc);
    while !t.at_end() {
        merge_field(&mut t, &mut m)?;
    }
    Ok(m)
}

fn merge_field(t: &mut Tokenizer, m: &mut Message) -> Result<(), ParseError> {
    if t.try_consume("[") {
        // 拡張の名前 (この .proto のメッセージは拡張を持たない)
        while !t.at_end() && !t.is("]") {
            t.next_token();
        }
        return Err(t.error_prev(format!("{} は拡張 ([…]) を持たない", m.desc.full_name)));
    }
    // 項目の名前 (Python の `\w+` の頭)
    if !t
        .token
        .first()
        .is_some_and(|c| c.is_alphanumeric() || *c == '_')
    {
        return Err(t.error(format!("項目の名前が要る ({} がある)", t.text())));
    }
    let name = t.text();
    t.next_token();
    let Some(f) = m.desc.by_name(&name) else {
        return Err(t.error_prev(format!("{} に {name} という項目は無い", m.desc.full_name)));
    };
    if matches!(f.ty, Ty::Message(_)) {
        t.try_consume(":");
    } else {
        t.consume(":")?;
    }
    if f.repeated && t.try_consume("[") {
        // 短い repeated の書き方 (`名前: [a, b]`)
        if !t.try_consume("]") {
            loop {
                merge_value(t, m, f)?;
                if t.try_consume("]") {
                    break;
                }
                t.consume(",")?;
            }
        }
    } else {
        merge_value(t, m, f)?;
    }
    // 項目の区切りに , か ; を置いてもよい
    if !t.try_consume(",") {
        t.try_consume(";");
    }
    Ok(())
}

fn merge_value(
    t: &mut Tokenizer,
    m: &mut Message,
    f: &'static super::pb::FieldDesc,
) -> Result<(), ParseError> {
    let value = match f.ty {
        Ty::Message(sub_desc) => {
            let end = if t.try_consume("<") {
                ">"
            } else {
                t.consume("{")?;
                "}"
            };
            if !f.repeated && m.has(f.name) {
                return Err(t.error_prev(format!("{} の {} が 2 つある", m.desc.full_name, f.name)));
            }
            let mut sub = Message::new(sub_desc);
            while !t.try_consume(end) {
                if t.at_end() {
                    return Err(t.error_prev(format!("「{end}」が要る")));
                }
                merge_field(t, &mut sub)?;
            }
            Value::Msg(sub)
        }
        Ty::Int32 => {
            Value::I32(consume_integer(t, i128::from(i32::MIN), i128::from(i32::MAX))? as i32)
        }
        Ty::Uint32 => Value::U32(consume_integer(t, 0, i128::from(u32::MAX))? as u32),
        Ty::Uint64 => Value::U64(consume_integer(t, 0, i128::from(u64::MAX))? as u64),
        Ty::Bool => Value::Bool(consume_bool(t)?),
        Ty::String => {
            let b = consume_byte_string(t)?;
            if std::str::from_utf8(&b).is_err() {
                return Err(t.error("文字列が UTF-8 ではない".to_string()));
            }
            Value::Bytes(b)
        }
        Ty::Bytes => Value::Bytes(consume_byte_string(t)?),
        Ty::Enum(e) => Value::I32(consume_enum(t, e)?),
    };
    if f.repeated {
        m.push(f.name, value);
    } else {
        if m.has(f.name) {
            return Err(t.error_prev(format!("{} の {} が 2 つある", m.desc.full_name, f.name)));
        }
        m.set(f.name, value);
    }
    Ok(())
}

/// Python の `int(text, 0)` (符号・`0x`・`0o`・`0b`・数字の間の `_`。10 進は頭の 0 を許さない (0 だけは許す))。大きすぎる値は i128 の端にする
/// (どの項目にも収まらないので範囲の外になる)。読めなければ None
fn python_int(text: &str) -> Option<i128> {
    let (negative, body) = match text.as_bytes().first() {
        Some(b'-') => (true, &text[1..]),
        Some(b'+') => (false, &text[1..]),
        _ => (false, text),
    };
    let lower = body.to_ascii_lowercase();
    let (radix, digits) = if let Some(d) = lower.strip_prefix("0x") {
        (16, d)
    } else if let Some(d) = lower.strip_prefix("0o") {
        (8, d)
    } else if let Some(d) = lower.strip_prefix("0b") {
        (2, d)
    } else {
        (10, lower.as_str())
    };
    // 基数の印の直後には _ を 1 つ置いてよい (0x_ff)
    let digits = if radix != 10 {
        digits.strip_prefix('_').unwrap_or(digits)
    } else {
        digits
    };
    if digits.is_empty()
        || digits.starts_with('_')
        || digits.ends_with('_')
        || digits.contains("__")
    {
        return None;
    }
    let plain: String = digits.chars().filter(|c| *c != '_').collect();
    if radix == 10 && plain.len() > 1 && plain.starts_with('0') && plain.chars().any(|c| c != '0') {
        return None;
    }
    let mut v: i128 = 0;
    let mut big = false;
    for c in plain.chars() {
        let d = c.to_digit(radix)?;
        match v
            .checked_mul(i128::from(radix))
            .and_then(|x| x.checked_add(i128::from(d)))
        {
            Some(x) => v = x,
            None => big = true,
        }
    }
    if big {
        v = i128::MAX;
    }
    Some(if negative { -v } else { v })
}

/// Python の `_ParseAbstractInteger` (頭が 0 の 10 進 (`010`) は 8 進として読む)
fn abstract_integer(text: &str) -> Option<i128> {
    let body = text.strip_prefix('-').unwrap_or(text);
    if body.len() > 1 && body.starts_with('0') && body.bytes().all(|b| b.is_ascii_digit()) {
        let sign = if text.starts_with('-') { "-" } else { "" };
        return python_int(&format!("{sign}0o{}", &body[1..]));
    }
    python_int(text)
}

fn consume_integer(t: &mut Tokenizer, min: i128, max: i128) -> Result<i128, ParseError> {
    let text = t.text();
    let v =
        abstract_integer(&text).ok_or_else(|| t.error(format!("整数として読めない: {text}")))?;
    if v < min || v > max {
        return Err(t.error(format!("値が範囲の外: {text}")));
    }
    t.next_token();
    Ok(v)
}

fn consume_bool(t: &mut Tokenizer) -> Result<bool, ParseError> {
    let v = match t.text().as_str() {
        "true" | "t" | "1" | "True" => true,
        "false" | "f" | "0" | "False" => false,
        _ => return Err(t.error("true か false が要る".to_string())),
    };
    t.next_token();
    Ok(v)
}

fn consume_enum(t: &mut Tokenizer, e: &'static EnumDesc) -> Result<i32, ParseError> {
    let text = t.text();
    // 番号 (Python の int(value, 0)。頭が 0 の 10 進は名前として読む) か名前。閉じた enum に無い番号は止める
    let v = match python_int(&text) {
        Some(n) => i32::try_from(n)
            .ok()
            .filter(|n| e.name_of(*n).is_some())
            .ok_or_else(|| t.error(format!("{} に番号 {text} の値は無い", e.full_name)))?,
        None => e
            .number_of(&text)
            .ok_or_else(|| t.error(format!("{} に {text} という値は無い", e.full_name)))?,
    };
    t.next_token();
    Ok(v)
}

/// 隣り合う引用を続けて読む (Python の ConsumeByteString)
fn consume_byte_string(t: &mut Tokenizer) -> Result<Vec<u8>, ParseError> {
    let mut out = consume_single_string(t)?;
    while t.token.first().is_some_and(|c| *c == '"' || *c == '\'') {
        out.extend(consume_single_string(t)?);
    }
    Ok(out)
}

fn consume_single_string(t: &mut Tokenizer) -> Result<Vec<u8>, ParseError> {
    let tok = t.token.clone();
    let Some(&q) = tok.first().filter(|c| **c == '"' || **c == '\'') else {
        return Err(t.error(format!("文字列が要る ({} がある)", t.text())));
    };
    if tok.len() < 2 || tok[tok.len() - 1] != q {
        return Err(t.error("文字列の閉じる引用符が無い".to_string()));
    }
    let bytes = cunescape(&tok[1..tok.len() - 1])
        .map_err(|e| t.error(format!("文字列のエスケープを読めない ({e})")))?;
    t.next_token();
    Ok(bytes)
}

fn hex_digit(c: u32) -> Option<u32> {
    char::from_u32(c).and_then(|c| c.to_digit(16))
}

/// Python の `text_encoding.CUnescape` (protobuf 7.36.2) と同じ 4 段で、引用の中身をバイト列にする。
pub(crate) fn cunescape(text: &[char]) -> Result<Vec<u8>, String> {
    // 1. 1 桁の \x (奇数個の \ の後) を 2 桁にする: re.sub(r'(\\+)x([0-9a-fA-F])(?![0-9a-fA-F])', …)
    let mut s1: Vec<char> = Vec::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i] != '\\' {
            s1.push(text[i]);
            i += 1;
            continue;
        }
        let start = i;
        while i < text.len() && text[i] == '\\' {
            i += 1;
        }
        let run = i - start;
        s1.extend(std::iter::repeat_n('\\', run));
        let is_hex = |k: usize| text.get(k).is_some_and(char::is_ascii_hexdigit);
        if text.get(i) == Some(&'x') && is_hex(i + 1) && !is_hex(i + 2) {
            s1.push('x');
            if run % 2 == 1 {
                s1.push('0');
            }
            s1.push(text[i + 1]);
            i += 2;
        }
    }
    // 2. raw_unicode_escape で書いて読み直す (\uXXXX・\UXXXXXXXX を字にする。\ は次の字と組になる)
    let mut b2: Vec<u8> = Vec::new();
    for c in &s1 {
        let n = *c as u32;
        if n < 0x100 {
            b2.push(n as u8);
        } else if n < 0x10000 {
            b2.extend(format!("\\u{n:04x}").bytes());
        } else {
            b2.extend(format!("\\U{n:08x}").bytes());
        }
    }
    let mut s2: Vec<u32> = Vec::new();
    let mut i = 0;
    while i < b2.len() {
        let c = b2[i];
        i += 1;
        if c != b'\\' {
            s2.push(u32::from(c));
            continue;
        }
        let Some(&c2) = b2.get(i) else {
            s2.push(u32::from(b'\\'));
            continue;
        };
        i += 1;
        let count = match c2 {
            b'u' => 4,
            b'U' => 8,
            _ => {
                s2.push(u32::from(b'\\'));
                s2.push(u32::from(c2));
                continue;
            }
        };
        let mut ch: u32 = 0;
        for _ in 0..count {
            let d = b2
                .get(i)
                .and_then(|b| hex_digit(u32::from(*b)))
                .ok_or("\\u・\\U の 16 進が足りない")?;
            ch = (ch << 4) | d;
            i += 1;
        }
        if ch > 0x10ffff {
            return Err("\\U が Unicode の範囲の外".into());
        }
        s2.push(ch);
    }
    // 3. UTF-8 にして unicode_escape で読む (\n・\t・\ooo・\xXX などを字にする。知らない \c はそのまま)
    let mut b3 = Vec::new();
    for ch in s2 {
        let c = char::from_u32(ch).ok_or("サロゲートの字は UTF-8 にできない")?;
        let mut buf = [0u8; 4];
        b3.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
    }
    let mut s3: Vec<u32> = Vec::new();
    let mut i = 0;
    while i < b3.len() {
        let c = b3[i];
        i += 1;
        if c != b'\\' {
            s3.push(u32::from(c));
            continue;
        }
        let c2 = *b3.get(i).ok_or("文字列の終わりに \\ だけがある")?;
        i += 1;
        let simple = |ch: u8| -> Option<u32> {
            Some(match ch {
                b'\\' => 0x5c,
                b'\'' => 0x27,
                b'"' => 0x22,
                b'b' => 0x08,
                b'f' => 0x0c,
                b't' => 0x09,
                b'n' => 0x0a,
                b'r' => 0x0d,
                b'v' => 0x0b,
                b'a' => 0x07,
                _ => return None,
            })
        };
        if c2 == b'\n' {
            continue;
        }
        if let Some(ch) = simple(c2) {
            s3.push(ch);
            continue;
        }
        match c2 {
            b'0'..=b'7' => {
                let mut ch = u32::from(c2 - b'0');
                for _ in 0..2 {
                    match b3.get(i) {
                        Some(d @ b'0'..=b'7') => {
                            ch = (ch << 3) + u32::from(d - b'0');
                            i += 1;
                        }
                        _ => break,
                    }
                }
                s3.push(ch);
            }
            b'x' | b'u' | b'U' => {
                let count = match c2 {
                    b'x' => 2,
                    b'u' => 4,
                    _ => 8,
                };
                let mut ch: u32 = 0;
                for _ in 0..count {
                    let d = b3
                        .get(i)
                        .and_then(|b| hex_digit(u32::from(*b)))
                        .ok_or("\\x・\\u・\\U の 16 進が足りない")?;
                    ch = (ch << 4) | d;
                    i += 1;
                }
                if ch > 0x10ffff {
                    return Err("Unicode の範囲の外の字".into());
                }
                s3.push(ch);
            }
            b'N' => return Err("\\N{…} (名前で引く字) は使えない".into()),
            other => {
                s3.push(u32::from(b'\\'));
                s3.push(u32::from(other));
            }
        }
    }
    // 4. latin-1 でバイト列に戻す (0xff を超える字は止める)
    s3.into_iter()
        .map(|ch| u8::try_from(ch).map_err(|_| format!("U+{ch:04X} は 1 バイトに収まらない")))
        .collect()
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! Python の protobuf 7.36.2 (pjp-google-ime と同じ nixpkgs のもの) で確かめた値と同じになる:
    //! - 書き: 番号の順・メッセージの入れ子と空のメッセージ・enum の名前 (負の値も)・string のエスケープ (制御文字は 8 進・UTF-8 でないバイトも 8 進)
    //! - 読み: 整数の書き方 (8 進・16 進・2 進・_・符号・範囲)・bool・enum の名前と番号 (閉じた enum)・2 度出た項目・メッセージの `<>` と `:`・
    //!   短い repeated・区切りの , と ;・コメント・隣り合う引用・エスケープ (\x の 1 桁・\u・\U・8 進・知らない \c・\あ・\u005cn)・閉じない引用・
    //!   知らない項目

    use super::super::pb::{self, CONFIG};
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    /// 読んで直列化したもの (読めなければ "ERR")
    fn p(text: &str) -> String {
        match parse(&CONFIG, text) {
            Ok(m) => hex(&m.encode()),
            Err(_) => "ERR".to_string(),
        }
    }

    fn un(s: &str) -> Result<Vec<u8>, String> {
        cunescape(&s.chars().collect::<Vec<_>>())
    }

    #[test]
    fn prints_like_message_to_string() {
        let mut c = Message::new(&CONFIG);
        c.set("verbose_level", Value::I32(0));
        let mut r = Message::new(&pb::CHARACTER_FORM_RULE);
        r.set(
            "group",
            Value::Bytes("a\u{1}\u{7f}\t\"'\\é".as_bytes().to_vec()),
        );
        c.push("character_form_rules", Value::Msg(r));
        c.set("session_keymap", Value::I32(-1));
        c.push("overlay_keymaps", Value::I32(100));
        c.push("overlay_keymaps", Value::I32(1));
        c.set(
            "information_list_config",
            Value::Msg(Message::new(&pb::INFORMATION_LIST_CONFIG)),
        );
        assert_eq!(
            print(&c),
            "verbose_level: 0\nsession_keymap: NONE\ncharacter_form_rules {\n  group: \"a\\001\\177\\t\\\"\\'\\\\é\"\n}\noverlay_keymaps: OVERLAY_HENKAN_MUHENKAN_TO_IME_ON_OFF\noverlay_keymaps: ATOK\ninformation_list_config {\n}\n"
        );
        // UTF-8 でないバイトは 8 進
        let m = pb::decode(&CONFIG, &[0xb2, 0x03, 0x04, 0x0a, 0x02, 0xe3, 0x81]).unwrap();
        assert_eq!(
            print(&m),
            "character_form_rules {\n  group: \"\\343\\201\"\n}\n"
        );
        // 大きな uint64
        let mut g = Message::new(&pb::GENERAL_CONFIG);
        g.set("config_version", Value::U32(1));
        g.set("last_modified_time", Value::U64(1 << 63));
        let mut c = Message::new(&CONFIG);
        c.set("general_config", Value::Msg(g));
        assert_eq!(
            print(&c),
            "general_config {\n  config_version: 1\n  last_modified_time: 9223372036854775808\n}\n"
        );
        // bytes の値は表示できない字を全部 8 進にする
        let mut c = Message::new(&CONFIG);
        c.set(
            "custom_keymap_table",
            Value::Bytes("a\té".as_bytes().to_vec()),
        );
        assert_eq!(print(&c), "custom_keymap_table: \"a\\t\\303\\251\"\n");
    }

    #[test]
    fn parses_like_text_format_parse() {
        let cases: &[(&str, &str)] = &[
            ("session_keymap: 6", "ERR"),
            ("session_keymap: -1", "c802ffffffffffffffffff01"),
            ("session_keymap: 0x1", "c80201"),
            ("session_keymap: NONE", "c802ffffffffffffffffff01"),
            ("session_keymap: 010", "ERR"),
            ("session_keymap: 00", "c80200"),
            ("verbose_level: 010", "5008"),
            ("verbose_level: 0x10", "5010"),
            ("verbose_level: -0x10", "50f0ffffffffffffffff01"),
            ("verbose_level: -010", "50f8ffffffffffffffff01"),
            ("suggestions_size: -1", "ERR"),
            ("suggestions_size: 4294967296", "ERR"),
            ("suggestions_size: 4294967295", "f006ffffffff0f"),
            ("incognito_mode: t", "a00101"),
            ("incognito_mode: 1", "a00101"),
            ("incognito_mode: True", "a00101"),
            ("incognito_mode: TRUE", "ERR"),
            ("incognito_mode: f", "a00100"),
            ("verbose_level: 1 verbose_level: 2", "ERR"),
            (
                "character_form_rules { group: \"a\" \"b\" }",
                "b203040a026162",
            ),
            ("character_form_rules < group: 'x' >", "b203030a0178"),
            (
                "character_form_rules: { group: \"\\x41\\101\\u3042\" }",
                "b203070a054141e38182",
            ),
            (
                "information_list_config {} information_list_config {}",
                "ERR",
            ),
            ("overlay_keymaps: [CUSTOM, 1]", "a204020001"),
            ("overlay_keymaps: []", ""),
            ("verbose_level: 1, incognito_mode: true;", "5001a00101"),
            ("verbose_level:1#c\nincognito_mode:true", "5001a00101"),
            ("character_form_rules { group: \"\\xe3\\x81\" }", "ERR"),
            (
                "character_form_rules { group: \"\\N{HIRAGANA LETTER A}\" }",
                "ERR",
            ),
            ("character_form_rules { group: \"\\q\" }", "b203040a025c71"),
            ("character_form_rules { group: \"\\777\" }", "ERR"),
            ("character_form_rules { group: \"ab", "ERR"),
            ("verbose_level 1", "ERR"),
            (
                "information_list_config: { use_local_usage_dictionary: false }",
                "d205020800",
            ),
            ("nosuch: 1", "ERR"),
            ("verbose_level: 1.0", "ERR"),
            ("verbose_level: 2147483648", "ERR"),
            ("verbose_level: -2147483649", "ERR"),
            ("verbose_level: -2147483648", "5080808080f8ffffffff01"),
            ("verbose_level: +1", "5001"),
            ("verbose_level: 1_0", "500a"),
            ("verbose_level: 1__0", "ERR"),
            ("verbose_level: _1", "ERR"),
            ("character_form_rules {", "ERR"),
            ("verbose_level: 1 }", "ERR"),
            ("auto_conversion_key: 0b1", "f00301"),
            ("auto_conversion_key: 0o7", "f00307"),
            ("auto_conversion_key: 0x_f", "f0030f"),
            ("auto_conversion_key: 08", "ERR"),
            ("auto_conversion_key: 1e3", "ERR"),
            ("verbose_level: - 1", "ERR"),
            ("Verbose_level: 1", "ERR"),
            ("10: 1", "ERR"),
            ("character_form_rules { group: \"\\x4\" }", "b203030a0104"),
            ("character_form_rules { group: \"a\\\nb\" }", "ERR"),
            (
                "character_form_rules {group:\"\\U0001F600\"}",
                "b203060a04f09f9880",
            ),
            (
                "character_form_rules {group:\"\\u00e9\\303\\251\"}",
                "b203060a04c3a9c3a9",
            ),
            (
                "character_form_rules {group:\"\\a\\b\\f\\v\\?\"}",
                "b203080a0607080c0b5c3f",
            ),
            ("[ext]: 1", "ERR"),
            ("verbose_level: 1;;", "ERR"),
            ("\u{feff}verbose_level: 1", "ERR"),
            ("verbose_level:\u{3000}1", "5001"),
            ("verbose_level: 1\r\nincognito_mode: true\r\n", "5001a00101"),
            (
                "general_config { last_modified_time: 18446744073709551615 }",
                "0a0b18ffffffffffffffffff01",
            ),
            ("custom_keymap_table: \"\\377\"", "d20201ff"),
        ];
        for (text, want) in cases {
            assert_eq!(&p(text), want, "{text:?}");
        }
    }

    #[test]
    fn cunescape_like_python() {
        assert_eq!(un("\\\\u0041").unwrap(), b"\\u0041");
        assert_eq!(un("\\\\\\u0041").unwrap(), b"\\A");
        assert_eq!(un("\\u3042").unwrap(), "あ".as_bytes());
        assert!(un("a\\").is_err());
        assert_eq!(un("\\あ").unwrap(), b"\\u3042");
        assert_eq!(un("\\u005cn").unwrap(), b"\n");
        assert_eq!(un("\\x4").unwrap(), b"\x04");
        assert_eq!(un("é\\x41").unwrap(), "éA".as_bytes());
        assert_eq!(un("\\\\x4").unwrap(), b"\\x4");
        assert_eq!(un("\\x4g").unwrap(), b"\x04g");
        assert!(un("\\xg").is_err());
        assert!(un("\\ud800").is_err());
        assert_eq!(un("😀").unwrap(), "😀".as_bytes());
    }

    #[test]
    fn errors_name_the_line_and_column() {
        let e = parse(&CONFIG, "verbose_level: 0\nsession_keymap: 6\n").unwrap_err();
        assert_eq!((e.line, e.column), (2, 17));
        assert!(e.message.contains("session_keymap: 6"), "{}", e.message);
        let e = parse(&CONFIG, "verbose_level: 0\nnosuch: 1\n").unwrap_err();
        assert_eq!((e.line, e.column), (2, 1));
    }
}
