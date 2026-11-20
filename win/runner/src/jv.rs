//! jq と同じ読み書きをする JSON の値 (`Jv`)。WSL の jq で書く手順 (terminal・powertoys・fancyzones) を写すとき、WSL と同じバイト列を書き、jq と
//! 同じく比べるため。
//!
//! - 読む (`Jv::parse`): RFC 8259 の JSON の値を 1 つ (頭の BOM は読み飛ばす。jq と同じ)。jq が JSON の外で受ける書き方 (`nan`・頭の 0・`+1`・
//!   `.5`・続けて並べた 2 つ目の値) と、深すぎる入れ子は読めないものとする (どれも、書かずに知らせる側に倒れる)
//! - 数は字のまま (係数の桁と指数) 持ち、jq (1.7 から。decNumber) と同じ形で書く: `1.50` はそのまま、`1e2` は `1E+2`、`0.0000001` は `1E-7`
//! - 比べる (`jq_eq`) のは jq の `==` と同じ: object はキーの順を見ず、数は十進の値で比べる (`1` と `1.0` は同じ、`0.85` と
//!   `0.84999999999999998` は違う)
//! - 書く: `-c` の形 (`compact`)・`--indent n` の形 (`indent`)・`-S` (`sorted`)。文字列の逃がし方も jq と同じ (`jq_string`)
//! - object は出てきた順の `Vec`。同じキーが 2 度あれば、初めの場所に後の値 (jq と同じ)。キーを足すと末尾に、在るキーはその場所で替える
//!   (jq の `setpath` と同じ)
//!
//! Claude Code の settings.json など、jq と同じバイト列にしなくてよいものは `ojson::OValue` (serde) を使う。

use std::cmp::Ordering;

/// 入れ子の深さの上限 (再帰で読むので、Windows の主スレッドの 1 MB のスタックに収める)
const MAX_DEPTH: usize = 512;
/// 指数の上限 (decNumber の既定の上限と同じ桁。超える数は読めないものとする)
const MAX_EXP: i64 = 999_999_999;

/// jq と同じ読み書きをする JSON の値。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Jv {
    Null,
    Bool(bool),
    Number(Num),
    String(String),
    Array(Vec<Jv>),
    Object(Vec<(String, Jv)>),
}

/// 数 (値は 係数 × 10^指数)。読んだ字の係数の桁 (頭の 0 は落とす) と指数をそのまま持つ (`1.50` は 150 と -2)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Num {
    neg: bool,
    /// 係数の桁 (頭の 0 を落とす。0 なら "0")
    coef: String,
    exp: i64,
}

impl Num {
    /// 整数 (手順が組み立てる値。ゾーンの数など)
    pub fn int(n: i64) -> Num {
        Num {
            neg: n < 0,
            coef: n.unsigned_abs().to_string(),
            exp: 0,
        }
    }

    /// 整数として読めるならその値 (`20`・`2.0E+1` も 20。小数部の残るもの・i64 に収まらないものは None)
    pub fn as_i64(&self) -> Option<i64> {
        let (neg, coef, exp) = self.normalized();
        if exp < 0 {
            return None;
        }
        let mut digits = coef.to_string();
        for _ in 0..exp {
            digits.push('0');
        }
        let v: i64 = digits.parse().ok()?;
        Some(if neg { -v } else { v })
    }

    /// 末尾の 0 を指数へ移した形 (0 は符号も指数も見ない)。jq の `==` はこの形で比べるのと同じ
    fn normalized(&self) -> (bool, &str, i64) {
        let trimmed = self.coef.trim_end_matches('0');
        if trimmed.is_empty() {
            return (false, "0", 0);
        }
        let shift = (self.coef.len() - trimmed.len()) as i64;
        (self.neg, trimmed, self.exp + shift)
    }

    /// jq (decNumber の to-scientific-string) と同じ字。
    pub fn to_jq(&self) -> String {
        let c = &self.coef;
        let clen = c.len() as i64;
        let adjusted = self.exp + clen - 1;
        let mut s = String::new();
        if self.neg {
            s.push('-');
        }
        if self.exp <= 0 && adjusted >= -6 {
            if self.exp == 0 {
                s.push_str(c);
            } else {
                let point = clen + self.exp;
                if point > 0 {
                    let point = point as usize;
                    s.push_str(&c[..point]);
                    s.push('.');
                    s.push_str(&c[point..]);
                } else {
                    s.push_str("0.");
                    for _ in 0..-point {
                        s.push('0');
                    }
                    s.push_str(c);
                }
            }
        } else {
            s.push_str(&c[..1]);
            if clen > 1 {
                s.push('.');
                s.push_str(&c[1..]);
            }
            s.push('E');
            s.push(if adjusted >= 0 { '+' } else { '-' });
            s.push_str(&adjusted.unsigned_abs().to_string());
        }
        s
    }

    /// 十進の値で比べる (jq の `==`・`<` と同じ)
    fn cmp_value(&self, other: &Num) -> Ordering {
        let (an, ac, ae) = self.normalized();
        let (bn, bc, be) = other.normalized();
        let a_zero = ac == "0";
        let b_zero = bc == "0";
        let sign = |neg: bool, zero: bool| -> i8 {
            if zero {
                0
            } else if neg {
                -1
            } else {
                1
            }
        };
        let (sa, sb) = (sign(an, a_zero), sign(bn, b_zero));
        if sa != sb {
            return sa.cmp(&sb);
        }
        if sa == 0 {
            return Ordering::Equal;
        }
        // 桁の位置 (いちばん上の桁の 10 の何乗か) で比べ、同じなら桁を頭から比べる
        let (aa, ba) = (ae + ac.len() as i64, be + bc.len() as i64);
        let mag = aa.cmp(&ba).then_with(|| {
            let n = ac.len().max(bc.len());
            let pad = |c: &str| {
                let mut s = c.to_string();
                while s.len() < n {
                    s.push('0');
                }
                s
            };
            pad(ac).cmp(&pad(bc))
        });
        if sa < 0 { mag.reverse() } else { mag }
    }
}

impl From<i64> for Jv {
    fn from(n: i64) -> Jv {
        Jv::Number(Num::int(n))
    }
}

impl From<&str> for Jv {
    fn from(s: &str) -> Jv {
        Jv::String(s.to_string())
    }
}

impl From<bool> for Jv {
    fn from(b: bool) -> Jv {
        Jv::Bool(b)
    }
}

impl Jv {
    /// JSON の文を読む (値は 1 つ。前後の空白と頭の BOM はよい)。読めなければ、何行目の何字目か・何が違うかの文を返す。
    pub fn parse(text: &str) -> Result<Jv, String> {
        let text = text.strip_prefix('\u{feff}').unwrap_or(text);
        let mut p = Parser {
            s: text,
            b: text.as_bytes(),
            i: 0,
            depth: 0,
        };
        p.ws();
        if p.i >= p.b.len() {
            return Err("中身が空です".to_string());
        }
        let v = p.value()?;
        p.ws();
        if p.i < p.b.len() {
            return Err(p.err("値の後ろに続きがあります"));
        }
        Ok(v)
    }

    /// 型の名前 (jq の `type`)
    pub fn type_name(&self) -> &'static str {
        match self {
            Jv::Null => "null",
            Jv::Bool(_) => "boolean",
            Jv::Number(_) => "number",
            Jv::String(_) => "string",
            Jv::Array(_) => "array",
            Jv::Object(_) => "object",
        }
    }

    pub fn is_object(&self) -> bool {
        matches!(self, Jv::Object(_))
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Jv::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&Vec<Jv>> {
        match self {
            Jv::Array(a) => Some(a),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&Vec<(String, Jv)>> {
        match self {
            Jv::Object(o) => Some(o),
            _ => None,
        }
    }

    /// object のキーの値 (object でない・無ければ None)
    pub fn get(&self, key: &str) -> Option<&Jv> {
        self.as_object()?
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v)
    }

    /// jq の `.key` (object に無い・null なら null。object でも null でもなければ None (jq はエラー))
    pub fn field(&self, key: &str) -> Option<&Jv> {
        match self {
            Jv::Object(_) => Some(self.get(key).unwrap_or(&NULL)),
            Jv::Null => Some(&NULL),
            _ => None,
        }
    }

    /// object のキーに値を入れる。在ればその場所で替え、無ければ末尾に足す (object でなければ何もしない)。
    pub fn set(&mut self, key: &str, value: Jv) {
        if let Jv::Object(entries) = self {
            match entries.iter_mut().find(|(k, _)| k == key) {
                Some((_, v)) => *v = value,
                None => entries.push((key.to_string(), value)),
            }
        }
    }

    /// object のキーを外し、その値を返す。
    pub fn remove(&mut self, key: &str) -> Option<Jv> {
        match self {
            Jv::Object(entries) => {
                let i = entries.iter().position(|(k, _)| k == key)?;
                Some(entries.remove(i).1)
            }
            _ => None,
        }
    }

    /// 持つキーのパス (object を辿った先の、object でない値の 1 つが 1 つのパス。配列の中は見ない。空の object は何も持たない)。jq の
    /// `def leaf_paths: if type == "object" then to_entries[] | [.key] + (.value | leaf_paths) else [] end` と同じ順。
    pub fn leaf_paths(&self) -> Vec<Vec<String>> {
        match self {
            Jv::Object(entries) => entries
                .iter()
                .flat_map(|(k, v)| {
                    v.leaf_paths().into_iter().map(move |mut p| {
                        p.insert(0, k.clone());
                        p
                    })
                })
                .collect(),
            _ => vec![Vec::new()],
        }
    }

    /// パスの値 (途中がどれも object で、キーがあるときだけ。jq の `lookup` (terminal) と同じ)
    pub fn lookup(&self, path: &[String]) -> Option<&Jv> {
        let mut cur = self;
        for k in path {
            cur = cur.get(k)?;
        }
        Some(cur)
    }

    /// jq の `getpath` (途中が無い・null なら null。途中が object でも null でもなければ None (jq はエラー))
    pub fn getpath(&self, path: &[String]) -> Option<&Jv> {
        let mut cur = self;
        for k in path {
            cur = cur.field(k)?;
        }
        Some(cur)
    }

    /// パスの途中にある、object でない値の手前までの長さ (1 から。無ければ None)。そこから先へは書けない (jq の `blocked` (terminal) と同じ。
    /// null も object でないので書けないとみなす)
    pub fn blocked(&self, path: &[String]) -> Option<usize> {
        (1..path.len()).find(|&i| self.lookup(&path[..i]).is_some_and(|v| !v.is_object()))
    }

    /// jq の `setpath` と同じ: 途中が無ければ object を作り、null なら object にする。途中が object でも null でもなければ、そのわけを返す
    /// (jq はエラーで止まる)。
    pub fn set_path(&mut self, path: &[String], value: Jv) -> Result<(), String> {
        let Some((first, rest)) = path.split_first() else {
            *self = value;
            return Ok(());
        };
        if matches!(self, Jv::Null) {
            *self = Jv::Object(Vec::new());
        }
        let Jv::Object(entries) = self else {
            return Err(format!(
                "{} の中に {} を書けません ({} は object ではない)",
                self.type_name(),
                jq_string(first),
                self.type_name()
            ));
        };
        let i = match entries.iter().position(|(k, _)| k == first) {
            Some(i) => i,
            None => {
                entries.push((first.clone(), Jv::Null));
                entries.len() - 1
            }
        };
        entries[i].1.set_path(rest, value)
    }

    /// jq の `delpaths([path])` (途中が無ければ何もしない)
    pub fn del_path(&mut self, path: &[String]) {
        let Some((last, parents)) = path.split_last() else {
            *self = Jv::Null;
            return;
        };
        let mut cur = self;
        for k in parents {
            match cur {
                Jv::Object(entries) => match entries.iter_mut().find(|(key, _)| key == k) {
                    Some((_, v)) => cur = v,
                    None => return,
                },
                _ => return,
            }
        }
        cur.remove(last);
    }

    /// `path` から上へ、空になった object を消す (terminal の `prune_empty`。--import でキーを消した後)
    pub fn prune_empty(&mut self, path: &[String]) {
        let mut p = path.to_vec();
        while !p.is_empty() && self.getpath(&p) == Some(&Jv::Object(Vec::new())) {
            self.del_path(&p);
            p.pop();
        }
    }

    /// jq の `-c` の形 (末尾の改行なし)
    pub fn compact(&self) -> String {
        let mut s = String::new();
        self.write(&mut s, None, 0);
        s
    }

    /// jq の `--indent n` の形 (末尾の改行なし。jq は改行を足す)
    pub fn indent(&self, n: usize) -> String {
        let mut s = String::new();
        self.write(&mut s, Some(n), 0);
        s
    }

    /// object のキーをバイト列の順に並べ替えた写し (入れ子も。jq の `-S`)
    pub fn sorted(&self) -> Jv {
        match self {
            Jv::Array(items) => Jv::Array(items.iter().map(Jv::sorted).collect()),
            Jv::Object(entries) => {
                let mut e: Vec<(String, Jv)> = entries
                    .iter()
                    .map(|(k, v)| (k.clone(), v.sorted()))
                    .collect();
                e.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
                Jv::Object(e)
            }
            other => other.clone(),
        }
    }

    fn write(&self, out: &mut String, indent: Option<usize>, level: usize) {
        let newline = |out: &mut String, level: usize| {
            if let Some(n) = indent {
                out.push('\n');
                for _ in 0..n * level {
                    out.push(' ');
                }
            }
        };
        match self {
            Jv::Null => out.push_str("null"),
            Jv::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Jv::Number(n) => out.push_str(&n.to_jq()),
            Jv::String(s) => out.push_str(&jq_string(s)),
            Jv::Array(items) => {
                if items.is_empty() {
                    out.push_str("[]");
                    return;
                }
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    newline(out, level + 1);
                    item.write(out, indent, level + 1);
                }
                newline(out, level);
                out.push(']');
            }
            Jv::Object(entries) => {
                if entries.is_empty() {
                    out.push_str("{}");
                    return;
                }
                out.push('{');
                for (i, (k, v)) in entries.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    newline(out, level + 1);
                    out.push_str(&jq_string(k));
                    out.push(':');
                    if indent.is_some() {
                        out.push(' ');
                    }
                    v.write(out, indent, level + 1);
                }
                newline(out, level);
                out.push('}');
            }
        }
    }
}

static NULL: Jv = Jv::Null;

impl Jv {
    /// jq の `tostring` と文字列の中の `\(…)` (文字列はそのまま、ほかは `-c` の形)
    pub fn tostring(&self) -> String {
        match self {
            Jv::String(s) => s.clone(),
            other => other.compact(),
        }
    }

    /// jq の並べ方での順位 (null < false < true < 数 < 文字列 < 配列 < object)
    fn rank(&self) -> u8 {
        match self {
            Jv::Null => 0,
            Jv::Bool(false) => 1,
            Jv::Bool(true) => 2,
            Jv::Number(_) => 3,
            Jv::String(_) => 4,
            Jv::Array(_) => 5,
            Jv::Object(_) => 6,
        }
    }
}

/// jq の並べ方 (`sort`・`group_by`・`unique` の順): 型の順位、数は十進の値、文字列はバイト列、配列は前から、object はキーの並び (並べ替えた
/// もの) を比べてから、そのキーの順に値を比べる。
pub fn jq_cmp(a: &Jv, b: &Jv) -> Ordering {
    match (a, b) {
        (Jv::Number(x), Jv::Number(y)) => x.cmp_value(y),
        (Jv::String(x), Jv::String(y)) => x.as_bytes().cmp(y.as_bytes()),
        (Jv::Array(x), Jv::Array(y)) => {
            for (p, q) in x.iter().zip(y) {
                let o = jq_cmp(p, q);
                if o != Ordering::Equal {
                    return o;
                }
            }
            x.len().cmp(&y.len())
        }
        (Jv::Object(x), Jv::Object(y)) => {
            fn keys(o: &[(String, Jv)]) -> Vec<&String> {
                let mut k: Vec<&String> = o.iter().map(|(k, _)| k).collect();
                k.sort_by(|p, q| p.as_bytes().cmp(q.as_bytes()));
                k
            }
            let (kx, ky) = (keys(x), keys(y));
            let o = kx
                .iter()
                .map(|k| k.as_bytes())
                .cmp(ky.iter().map(|k| k.as_bytes()));
            if o != Ordering::Equal {
                return o;
            }
            for k in kx {
                let vx = a.get(k).expect("キーがある");
                let vy = b.get(k).expect("同じキーの並び");
                let o = jq_cmp(vx, vy);
                if o != Ordering::Equal {
                    return o;
                }
            }
            Ordering::Equal
        }
        _ => a.rank().cmp(&b.rank()),
    }
}

/// jq の `group_by(f)`: `f` の値で安定に並べ、同じ値の組に分ける (組の中は元の順)。
pub fn group_by<T: Clone>(items: &[T], key: impl Fn(&T) -> Jv) -> Vec<Vec<T>> {
    let mut keyed: Vec<(Jv, T)> = items.iter().map(|i| (key(i), i.clone())).collect();
    keyed.sort_by(|a, b| jq_cmp(&a.0, &b.0));
    let mut groups: Vec<(Jv, Vec<T>)> = Vec::new();
    for (k, item) in keyed {
        match groups.last_mut() {
            Some((gk, g)) if jq_cmp(gk, &k) == Ordering::Equal => g.push(item),
            _ => groups.push((k, vec![item])),
        }
    }
    groups.into_iter().map(|(_, g)| g).collect()
}

/// jq の `test("^…$")` の `$` は、末尾の改行 1 つの前でも合う (Perl と同じ)。その改行を落とした中身。
pub fn anchored(s: &str) -> &str {
    s.strip_suffix('\n').unwrap_or(s)
}

/// jq の `==` と同じ比べ方 (object はキーの順を見ない、数は十進の値)。
pub fn jq_eq(a: &Jv, b: &Jv) -> bool {
    match (a, b) {
        (Jv::Null, Jv::Null) => true,
        (Jv::Bool(x), Jv::Bool(y)) => x == y,
        (Jv::Number(x), Jv::Number(y)) => x.cmp_value(y) == Ordering::Equal,
        (Jv::String(x), Jv::String(y)) => x == y,
        (Jv::Array(x), Jv::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| jq_eq(p, q))
        }
        (Jv::Object(x), Jv::Object(y)) => {
            x.len() == y.len()
                && x.iter()
                    .all(|(k, v)| y.iter().any(|(k2, v2)| k == k2 && jq_eq(v, v2)))
        }
        _ => false,
    }
}

/// jq の文字列の書き方: `"` と `\` は前に `\`、制御文字 (U+0000〜U+001F と U+007F) は `\b` `\t` `\n` `\f` `\r` か `\u00xx` (小文字)、ほかは
/// そのまま。
pub fn jq_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => {
                out.push_str(&format!("\\u{:04x}", c as u32))
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// jq の `tojson` (`-c` の形の文字列。記録の鍵にパスの配列を書くときなど)
pub fn tojson_path(path: &[String]) -> String {
    Jv::Array(path.iter().map(|k| Jv::String(k.clone())).collect()).compact()
}

struct Parser<'a> {
    s: &'a str,
    b: &'a [u8],
    i: usize,
    depth: usize,
}

impl<'a> Parser<'a> {
    /// 今の場所 (何行目の何字目) を添えた文
    fn err(&self, what: &str) -> String {
        let end = (0..=self.i.min(self.s.len()))
            .rev()
            .find(|&j| self.s.is_char_boundary(j))
            .unwrap_or(0);
        let before = &self.s[..end];
        let line = before.matches('\n').count() + 1;
        let col = before.rsplit('\n').next().unwrap_or("").chars().count() + 1;
        format!("{line} 行 {col} 字目: {what}")
    }

    fn ws(&mut self) {
        while self.i < self.b.len() && matches!(self.b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.b.get(self.i).copied()
    }

    fn value(&mut self) -> Result<Jv, String> {
        self.ws();
        match self.peek() {
            Some(b'{') => self.nested(Parser::object),
            Some(b'[') => self.nested(Parser::array),
            Some(b'"') => self.string().map(Jv::String),
            Some(b't') => self.literal("true", Jv::Bool(true)),
            Some(b'f') => self.literal("false", Jv::Bool(false)),
            Some(b'n') => self.literal("null", Jv::Null),
            Some(b'-' | b'0'..=b'9') => self.number().map(Jv::Number),
            Some(_) => Err(self.err("JSON の値ではありません")),
            None => Err(self.err("値の途中で終わっています")),
        }
    }

    fn nested(&mut self, f: fn(&mut Self) -> Result<Jv, String>) -> Result<Jv, String> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            return Err(self.err("入れ子が深すぎます"));
        }
        let v = f(self);
        self.depth -= 1;
        v
    }

    fn literal(&mut self, word: &str, v: Jv) -> Result<Jv, String> {
        if self.b[self.i..].starts_with(word.as_bytes()) {
            self.i += word.len();
            Ok(v)
        } else {
            Err(self.err("JSON の値ではありません"))
        }
    }

    fn object(&mut self) -> Result<Jv, String> {
        self.i += 1;
        let mut obj = Jv::Object(Vec::new());
        self.ws();
        if self.peek() == Some(b'}') {
            self.i += 1;
            return Ok(obj);
        }
        loop {
            self.ws();
            if self.peek() != Some(b'"') {
                return Err(self.err("object のキー (\"…\") がありません"));
            }
            let key = self.string()?;
            self.ws();
            if self.peek() != Some(b':') {
                return Err(self.err("キーの後ろに : がありません"));
            }
            self.i += 1;
            let v = self.value()?;
            obj.set(&key, v);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b'}') => {
                    self.i += 1;
                    return Ok(obj);
                }
                _ => return Err(self.err("object の , か } がありません")),
            }
        }
    }

    fn array(&mut self) -> Result<Jv, String> {
        self.i += 1;
        let mut items = Vec::new();
        self.ws();
        if self.peek() == Some(b']') {
            self.i += 1;
            return Ok(Jv::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.ws();
            match self.peek() {
                Some(b',') => self.i += 1,
                Some(b']') => {
                    self.i += 1;
                    return Ok(Jv::Array(items));
                }
                _ => return Err(self.err("配列の , か ] がありません")),
            }
        }
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let h = self
            .s
            .get(self.i..self.i + 4)
            .filter(|h| h.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(|| self.err("\\u の後ろが 16 進の 4 桁ではありません"))?;
        self.i += 4;
        Ok(u32::from_str_radix(h, 16).expect("16 進の 4 桁を確かめた"))
    }

    fn string(&mut self) -> Result<String, String> {
        self.i += 1;
        let mut out = String::new();
        loop {
            let Some(c) = self.s[self.i..].chars().next() else {
                return Err(self.err("文字列が閉じていません"));
            };
            match c {
                '"' => {
                    self.i += 1;
                    return Ok(out);
                }
                '\\' => {
                    self.i += 1;
                    let Some(e) = self.peek() else {
                        return Err(self.err("文字列が閉じていません"));
                    };
                    self.i += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let code = if (0xD800..0xDC00).contains(&hi) {
                                if !self.b[self.i..].starts_with(b"\\u") {
                                    return Err(self.err("対になっていないサロゲートがあります"));
                                }
                                self.i += 2;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return Err(self.err("対になっていないサロゲートがあります"));
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else if (0xDC00..0xE000).contains(&hi) {
                                return Err(self.err("対になっていないサロゲートがあります"));
                            } else {
                                hi
                            };
                            out.push(char::from_u32(code).expect("サロゲートを除いた"));
                        }
                        _ => return Err(self.err("知らない逃がし方 (\\…) があります")),
                    }
                }
                c if (c as u32) < 0x20 => {
                    return Err(self.err("文字列の中に、逃がしていない制御文字があります"));
                }
                c => {
                    out.push(c);
                    self.i += c.len_utf8();
                }
            }
        }
    }

    fn digits(&mut self) -> &'a str {
        let start = self.i;
        while self.peek().is_some_and(|b| b.is_ascii_digit()) {
            self.i += 1;
        }
        let s: &'a str = self.s;
        &s[start..self.i]
    }

    fn number(&mut self) -> Result<Num, String> {
        let neg = self.peek() == Some(b'-');
        if neg {
            self.i += 1;
        }
        let int = self.digits();
        if int.is_empty() || (int.len() > 1 && int.starts_with('0')) {
            return Err(self.err("数の書き方が違います"));
        }
        let mut frac = "";
        if self.peek() == Some(b'.') {
            self.i += 1;
            frac = self.digits();
            if frac.is_empty() {
                return Err(self.err("数の書き方が違います"));
            }
        }
        let mut e: i64 = 0;
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.i += 1;
            let eneg = match self.peek() {
                Some(b'-') => {
                    self.i += 1;
                    true
                }
                Some(b'+') => {
                    self.i += 1;
                    false
                }
                _ => false,
            };
            let ed = self.digits();
            if ed.is_empty() {
                return Err(self.err("数の書き方が違います"));
            }
            let sig = ed.trim_start_matches('0');
            if sig.len() > 18 {
                return Err(self.err("数の指数が大きすぎます"));
            }
            let v: i64 = if sig.is_empty() {
                0
            } else {
                sig.parse().expect("18 桁までの数字")
            };
            e = if eneg { -v } else { v };
        }
        let mut coef = format!("{int}{frac}");
        let trimmed = coef.trim_start_matches('0');
        coef = if trimmed.is_empty() {
            "0".to_string()
        } else {
            trimmed.to_string()
        };
        let exp = e
            .checked_sub(frac.len() as i64)
            .filter(|x| x.abs() <= MAX_EXP && (x + coef.len() as i64 - 1).abs() <= MAX_EXP)
            .ok_or_else(|| self.err("数の指数が大きすぎます"))?;
        Ok(Num { neg, coef, exp })
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (期待する字は jq 1.8.2 の出力)
    //!
    //! - 数の字: 係数と指数をそのまま持ち、decNumber の形で書く (`1.50`・`1E+2`・`1E-7`・`-0`・`0E+5`・桁の多い整数)
    //! - 数の比べ方: 十進の値 (`1` と `1.0` は同じ、`0.85` と `0.84999999999999998` は違う、`-0` と `0` は同じ)
    //! - 読める・読めない JSON (BOM・コメント・末尾の ,・頭の 0・制御文字・サロゲート・続きの値・空・深すぎる入れ子)
    //! - 重なったキーは初めの場所に後の値・`-c`・`--indent 4`・`-S`・文字列の逃がし方
    //! - パス (持つキー・lookup・getpath・blocked・setpath・delpaths・空の object を消す)

    use super::*;

    fn n(s: &str) -> Num {
        match Jv::parse(s).unwrap() {
            Jv::Number(n) => n,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn numbers_print_like_jq() {
        for (lit, want) in [
            ("1.0", "1.0"),
            ("1.50", "1.50"),
            ("1e2", "1E+2"),
            ("1E2", "1E+2"),
            ("1E+2", "1E+2"),
            ("-0", "-0"),
            ("0.1", "0.1"),
            ("1e-7", "1E-7"),
            ("0.0000001", "1E-7"),
            (
                "123456789012345678901234567890",
                "123456789012345678901234567890",
            ),
            ("3.0e10", "3.0E+10"),
            ("0.84999999999999998", "0.84999999999999998"),
            ("1.7976931348623157e308", "1.7976931348623157E+308"),
            ("1e400", "1E+400"),
            ("-1.5E-3", "-0.0015"),
            ("100", "100"),
            ("5e-324", "5E-324"),
            ("1e-6", "0.000001"),
            ("-1e-6", "-0.000001"),
            ("12e-8", "1.2E-7"),
            ("123.456e-10", "1.23456E-8"),
            ("0.000", "0.000"),
            ("0.0e3", "0E+2"),
            ("10e-1", "1.0"),
            ("100e-2", "1.00"),
            ("1.23e5", "1.23E+5"),
            ("1.2300e2", "123.00"),
            ("0e-7", "0E-7"),
            ("0.00000001", "1E-8"),
            ("9.9e-7", "9.9E-7"),
            ("-0e0", "-0"),
            ("0.5e1", "5"),
            ("1000000", "1000000"),
            ("1e6", "1E+6"),
            ("12345678901234567e10", "1.2345678901234567E+26"),
            ("-0.0", "-0.0"),
            ("0e5", "0E+5"),
            ("2560", "2560"),
        ] {
            assert_eq!(n(lit).to_jq(), want, "{lit}");
        }
        assert_eq!(Num::int(20).to_jq(), "20");
        assert_eq!(Num::int(-3).to_jq(), "-3");
        assert_eq!(Num::int(0).to_jq(), "0");
    }

    #[test]
    fn numbers_compare_by_decimal_value() {
        let eq = |a: &str, b: &str| jq_eq(&Jv::parse(a).unwrap(), &Jv::parse(b).unwrap());
        assert!(eq("1", "1.0"));
        assert!(eq("1.0", "1.00"));
        assert!(eq("1", "10e-1"));
        assert!(eq("0.1", "0.10"));
        assert!(eq("-0", "0"));
        assert!(eq("0", "0.0"));
        assert!(eq("1e400", "1E+400"));
        assert!(eq("20", "2.0E+1"));
        assert!(!eq("0.84999999999999998", "0.85"));
        assert!(!eq(
            "100000000000000000000000000001",
            "100000000000000000000000000000"
        ));
        assert!(!eq("1", "-1"));
        assert!(!eq("1", "\"1\""));
        assert!(!eq("0.5", "5"));
        assert_eq!(n("1.5").cmp_value(&n("2")), Ordering::Less);
        assert_eq!(n("-1.5").cmp_value(&n("-2")), Ordering::Greater);
        assert_eq!(n("0.01").cmp_value(&n("0.1")), Ordering::Less);
        assert_eq!(n("20").as_i64(), Some(20));
        assert_eq!(n("2.0E+1").as_i64(), Some(20));
        assert_eq!(n("-7").as_i64(), Some(-7));
        assert_eq!(n("1.5").as_i64(), None);
    }

    #[test]
    fn reads_json_like_jq_or_refuses() {
        assert_eq!(
            Jv::parse("\u{feff}{\"a\":1}").unwrap().compact(),
            "{\"a\":1}"
        );
        assert_eq!(
            Jv::parse(" \n{\"a\":1,\"b\":2,\"a\":3}\n")
                .unwrap()
                .compact(),
            "{\"a\":3,\"b\":2}"
        );
        assert_eq!(
            Jv::parse(r#"{"a":"\u00e9\ud83d\ude00\/\b\f\n\r\t\u0000"}"#)
                .unwrap()
                .get("a")
                .unwrap()
                .as_str()
                .unwrap(),
            "é😀/\u{8}\u{c}\n\r\t\u{0}"
        );
        for bad in [
            "",
            "  \n",
            "{\"a\":1 // c\n}",
            "{\"a\":/*x*/1}",
            "{\"a\":1,}",
            "[1,]",
            "{\"a\":nan}",
            "{\"a\":012}",
            "{\"a\":+1}",
            "{\"a\":.5}",
            "{\"a\":5.}",
            "{\"a\":0x10}",
            "{'a':1}",
            "{\"a\":\"\\x\"}",
            "{\"a\":\"x\ty\"}",
            "{\"a\":\"x\ny\"}",
            "{\"a\":\"\\ud800\"}",
            "{\"a\":\"\\udc00\"}",
            "{\"a\":\"\\ud800\\u0041\"}",
            "{\"a\":1}{\"b\":2}",
            "{\"a\":1} x",
            "{\"a\":1e1000000000000}",
            "{\"a\"",
            "[",
            "tru",
        ] {
            assert!(Jv::parse(bad).is_err(), "{bad:?}");
        }
        let deep = format!("{}{}", "[".repeat(600), "]".repeat(600));
        assert!(Jv::parse(&deep).unwrap_err().contains("深すぎ"));
        let ok = format!("{}{}", "[".repeat(100), "]".repeat(100));
        assert!(Jv::parse(&ok).is_ok());
        let e = Jv::parse("{\n  \"a\": 1,\n  \"b\": x\n}").unwrap_err();
        assert!(e.starts_with("3 行 8 字目"), "{e}");
    }

    #[test]
    fn writes_like_jq() {
        let v = Jv::parse(
            r#"{"a":[],"b":{},"c":[1,{"x":[]},[]],"d":"\u00e9\u0001\u001f\"\\","e":{"f":{"g":null}},"日":true,"k":"\u007f"}"#,
        )
        .unwrap();
        assert_eq!(
            v.indent(4),
            "{\n    \"a\": [],\n    \"b\": {},\n    \"c\": [\n        1,\n        {\n            \"x\": []\n        },\n        []\n    ],\n    \"d\": \"é\\u0001\\u001f\\\"\\\\\",\n    \"e\": {\n        \"f\": {\n            \"g\": null\n        }\n    },\n    \"日\": true,\n    \"k\": \"\\u007f\"\n}"
        );
        assert_eq!(
            v.compact(),
            r#"{"a":[],"b":{},"c":[1,{"x":[]},[]],"d":"é\u0001\u001f\"\\","e":{"f":{"g":null}},"日":true,"k":"\u007f"}"#
        );
        let s = Jv::parse(r#"{"b":{"z":1,"a":[{"y":1,"b":2}]},"a":1,"B":0,"é":1,"e":2}"#)
            .unwrap()
            .sorted();
        assert_eq!(
            s.indent(2),
            "{\n  \"B\": 0,\n  \"a\": 1,\n  \"b\": {\n    \"a\": [\n      {\n        \"b\": 2,\n        \"y\": 1\n      }\n    ],\n    \"z\": 1\n  },\n  \"e\": 2,\n  \"é\": 1\n}"
        );
        assert_eq!(
            tojson_path(&["a.b".into(), "c\"d".into(), "日".into()]),
            r#"["a.b","c\"d","日"]"#
        );
        assert_eq!(Jv::parse("[1.50,1e2]").unwrap().compact(), "[1.50,1E+2]");
    }

    #[test]
    fn objects_compare_without_order() {
        let a = Jv::parse(r#"{"a":1,"b":{"x":1,"y":[1,2]}}"#).unwrap();
        let b = Jv::parse(r#"{"b":{"y":[1,2.0],"x":1},"a":1.0}"#).unwrap();
        assert!(jq_eq(&a, &b));
        assert_ne!(a, b);
        let c = Jv::parse(r#"{"b":{"y":[2,1],"x":1},"a":1}"#).unwrap();
        assert!(!jq_eq(&a, &c));
        let d = Jv::parse(r#"{"a":1}"#).unwrap();
        assert!(!jq_eq(&a, &d));
        assert!(!jq_eq(&d, &a));
    }

    fn p(keys: &[&str]) -> Vec<String> {
        keys.iter().map(|k| k.to_string()).collect()
    }

    #[test]
    fn paths_like_jq() {
        let v = Jv::parse(
            r#"{"profiles":{"defaults":{"bellSound":["x"],"e":{}},"list":[1]},"compatibility.allowHeadless":true,"n":null}"#,
        )
        .unwrap();
        assert_eq!(
            v.leaf_paths(),
            vec![
                p(&["profiles", "defaults", "bellSound"]),
                p(&["profiles", "list"]),
                p(&["compatibility.allowHeadless"]),
                p(&["n"]),
            ]
        );
        assert_eq!(Jv::from(1).leaf_paths(), vec![Vec::<String>::new()]);
        assert_eq!(
            v.lookup(&p(&["profiles", "defaults", "bellSound"])),
            Some(&Jv::Array(vec![Jv::from("x")]))
        );
        assert_eq!(v.lookup(&p(&["profiles", "x"])), None);
        assert_eq!(v.lookup(&p(&["n", "x"])), None);
        assert_eq!(v.getpath(&p(&["n", "x"])), Some(&Jv::Null));
        assert_eq!(v.getpath(&p(&["zz", "x"])), Some(&Jv::Null));
        assert_eq!(v.getpath(&p(&["profiles", "list", "x"])), None);
        assert_eq!(v.blocked(&p(&["profiles", "list", "x"])), Some(2));
        assert_eq!(v.blocked(&p(&["n", "x"])), Some(1));
        assert_eq!(v.blocked(&p(&["profiles", "defaults", "x"])), None);
        assert_eq!(v.blocked(&p(&["zz", "x"])), None);

        let mut w = v.clone();
        w.set_path(&p(&["profiles", "defaults", "bellSound"]), Jv::from("y"))
            .unwrap();
        w.set_path(&p(&["new", "deep"]), Jv::from(1)).unwrap();
        w.set_path(&p(&["n", "x"]), Jv::from(2)).unwrap();
        assert_eq!(
            w.compact(),
            r#"{"profiles":{"defaults":{"bellSound":"y","e":{}},"list":[1]},"compatibility.allowHeadless":true,"n":{"x":2},"new":{"deep":1}}"#
        );
        assert!(
            w.set_path(&p(&["profiles", "list", "x"]), Jv::from(1))
                .is_err()
        );

        let mut m = Jv::parse(r#"{"profiles":{"defaults":{"bellSound":"x"}},"a":1}"#).unwrap();
        let bell = p(&["profiles", "defaults", "bellSound"]);
        m.del_path(&bell);
        m.prune_empty(&bell[..2]);
        assert_eq!(m.compact(), r#"{"a":1}"#);
        m.del_path(&p(&["zz", "y"]));
        m.del_path(&p(&["a", "y"]));
        assert_eq!(m.compact(), r#"{"a":1}"#);
    }
}
