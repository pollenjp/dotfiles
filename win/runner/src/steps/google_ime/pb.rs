//! 要るメッセージだけの protobuf (proto2) の読み書き。Google 日本語入力の `config1.db` (Mozc の `mozc.config.Config`) と `user_dictionary.db`
//! (`mozc.user_dictionary.UserDictionaryStorage`) を、pjp-google-ime (Python の protobuf。upb) と同じバイト列で読み書きする (dotfiles-private の
//! docs/superpowers/specs/2026-11-16-win-runner-core-design.md §8 の 5: protoc の要る crate を足さず、要るメッセージだけを手で読み書きする)。
//!
//! - 型は Mozc の .proto の写し (`nix/pkgs/pjp-google-ime/proto/`) を手で写した表 (`CONFIG`・`STORAGE` とその下)。試験が .proto と突き合わせる
//! - 値は型の表から引く動的なメッセージ (`Message`) に持つ。値のある項目は番号ごとに並べ、repeated でない項目は値を 1 つだけ持つ (proto2 の
//!   「値がある」を、既定の値と別に持つ)
//! - 読み方は upb と同じ: 同じ項目が 2 度来たら、スカラーは後のもの、メッセージは混ぜる。repeated の数の型は packed でもそうでなくても読む。閉じた
//!   enum の知らない値と、型の合わない wire type の項目は「知らない項目」に入れる (packed でない項目は元のバイトのまま、packed の enum の知らない値は
//!   1 つずつ varint の項目に作り直す)。string は UTF-8 を確かめずにバイト列のまま持つ。入れ子 (メッセージと group) は 100 段まで
//! - 書き方も upb と同じ: 値のある項目を番号の順に書き (packed の項目は 1 つにまとめる)、知らない項目を読んだ順のまま末尾に足す。int32 と enum の
//!   負の値は 10 バイトの varint にする

use std::collections::BTreeMap;

/// 項目の型 (Mozc の .proto に出てくるものだけ)。
#[derive(Clone, Copy)]
pub enum Ty {
    Int32,
    Uint32,
    Uint64,
    Bool,
    /// 閉じた enum (proto2)。値は `Value::I32`
    Enum(&'static EnumDesc),
    /// 値は `Value::Bytes` (UTF-8 を確かめない)
    String,
    Bytes,
    Message(&'static MsgDesc),
}

impl Ty {
    /// varint で書く型か (packed にできる型)
    fn is_varint(self) -> bool {
        matches!(
            self,
            Ty::Int32 | Ty::Uint32 | Ty::Uint64 | Ty::Bool | Ty::Enum(_)
        )
    }
}

/// 項目の名札。
pub struct FieldDesc {
    pub number: u32,
    pub name: &'static str,
    pub ty: Ty,
    pub repeated: bool,
    /// `[packed = true]`
    pub packed: bool,
}

/// メッセージの型。`fields` は番号の順。
pub struct MsgDesc {
    pub full_name: &'static str,
    pub fields: &'static [FieldDesc],
}

impl MsgDesc {
    pub fn by_number(&'static self, number: u32) -> Option<&'static FieldDesc> {
        self.fields.iter().find(|f| f.number == number)
    }

    pub fn by_name(&'static self, name: &str) -> Option<&'static FieldDesc> {
        self.fields.iter().find(|f| f.name == name)
    }
}

/// enum の型。
pub struct EnumDesc {
    pub full_name: &'static str,
    pub values: &'static [(&'static str, i32)],
}

impl EnumDesc {
    /// 番号の名前 (同じ番号が 2 つあれば先のもの。Python の values_by_number と同じ)
    pub fn name_of(&self, number: i32) -> Option<&'static str> {
        self.values.iter().find(|v| v.1 == number).map(|v| v.0)
    }

    pub fn number_of(&self, name: &str) -> Option<i32> {
        self.values.iter().find(|v| v.0 == name).map(|v| v.1)
    }
}

/// 1 つの値。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    /// int32 と enum
    I32(i32),
    U32(u32),
    U64(u64),
    Bool(bool),
    /// string と bytes
    Bytes(Vec<u8>),
    Msg(Message),
}

/// 動的なメッセージ。
#[derive(Clone)]
pub struct Message {
    pub desc: &'static MsgDesc,
    /// 値のある項目 (番号 → 値。repeated でない項目は 1 つ)
    fields: BTreeMap<u32, Vec<Value>>,
    /// 知らない項目 (読んだ順のバイト列)
    unknown: Vec<u8>,
}

impl PartialEq for Message {
    fn eq(&self, other: &Message) -> bool {
        std::ptr::eq(self.desc, other.desc)
            && self.fields == other.fields
            && self.unknown == other.unknown
    }
}

impl Eq for Message {}

impl std::fmt::Debug for Message {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct(self.desc.full_name)
            .field("fields", &self.fields)
            .field("unknown", &self.unknown)
            .finish()
    }
}

impl Message {
    pub fn new(desc: &'static MsgDesc) -> Message {
        Message {
            desc,
            fields: BTreeMap::new(),
            unknown: Vec::new(),
        }
    }

    fn field(&self, name: &str) -> &'static FieldDesc {
        self.desc
            .by_name(name)
            .unwrap_or_else(|| panic!("{} に {name} という項目は無い", self.desc.full_name))
    }

    /// 値があるか (repeated は 1 つ以上あるか)
    pub fn has(&self, name: &str) -> bool {
        self.fields.contains_key(&self.field(name).number)
    }

    /// repeated でない項目の値
    pub fn get(&self, name: &str) -> Option<&Value> {
        self.fields
            .get(&self.field(name).number)
            .and_then(|v| v.last())
    }

    pub fn get_i32(&self, name: &str) -> Option<i32> {
        match self.get(name) {
            Some(Value::I32(n)) => Some(*n),
            _ => None,
        }
    }

    pub fn get_bytes(&self, name: &str) -> Option<&[u8]> {
        match self.get(name) {
            Some(Value::Bytes(b)) => Some(b),
            _ => None,
        }
    }

    /// repeated でない項目に値を入れる (前の値は捨てる)
    pub fn set(&mut self, name: &str, value: Value) {
        let n = self.field(name).number;
        self.fields.insert(n, vec![value]);
    }

    /// 値を外す (repeated は全部)
    pub fn clear(&mut self, name: &str) {
        let n = self.field(name).number;
        self.fields.remove(&n);
    }

    /// repeated の値の並び (repeated でない項目は 0 か 1 つ)
    pub fn values(&self, name: &str) -> &[Value] {
        self.fields
            .get(&self.field(name).number)
            .map_or(&[][..], Vec::as_slice)
    }

    /// repeated の項目の末尾に足す
    pub fn push(&mut self, name: &str, value: Value) {
        let n = self.field(name).number;
        self.fields.entry(n).or_default().push(value);
    }

    /// 値のある項目を番号の順に (Python の ListFields と同じ並び)
    pub fn list(&self) -> impl Iterator<Item = (&'static FieldDesc, &[Value])> {
        self.fields.iter().map(|(n, v)| {
            (
                self.desc
                    .by_number(*n)
                    .expect("値は型の表にある項目にしか入らない"),
                v.as_slice(),
            )
        })
    }

    /// 知らない項目のバイト列
    #[cfg(test)]
    pub fn unknown(&self) -> &[u8] {
        &self.unknown
    }

    /// このメッセージか、その中のメッセージに、知らない項目があるか (pjp-google-ime の has_unknown)
    pub fn has_unknown(&self) -> bool {
        !self.unknown.is_empty()
            || self
                .fields
                .values()
                .flatten()
                .any(|v| matches!(v, Value::Msg(m) if m.has_unknown()))
    }

    /// 直列化する (upb の SerializeToString(deterministic=True) と同じバイト列)
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.encode_into(&mut out);
        out
    }

    fn encode_into(&self, out: &mut Vec<u8>) {
        for (f, values) in self.list() {
            if f.repeated && f.packed && f.ty.is_varint() {
                if values.is_empty() {
                    continue;
                }
                let mut body = Vec::new();
                for v in values {
                    put_varint(&mut body, varint_of(v));
                }
                put_tag(out, f.number, WT_LEN);
                put_varint(out, body.len() as u64);
                out.extend_from_slice(&body);
                continue;
            }
            for v in values {
                match v {
                    Value::Bytes(b) => {
                        put_tag(out, f.number, WT_LEN);
                        put_varint(out, b.len() as u64);
                        out.extend_from_slice(b);
                    }
                    Value::Msg(m) => {
                        let body = m.encode();
                        put_tag(out, f.number, WT_LEN);
                        put_varint(out, body.len() as u64);
                        out.extend_from_slice(&body);
                    }
                    _ => {
                        put_tag(out, f.number, WT_VARINT);
                        put_varint(out, varint_of(v));
                    }
                }
            }
        }
        out.extend_from_slice(&self.unknown);
    }
}

/// 読めない理由 (pjp-google-ime の DecodeError に当たる)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodeError(pub &'static str);

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

const WT_VARINT: u32 = 0;
const WT_I64: u32 = 1;
const WT_LEN: u32 = 2;
const WT_START_GROUP: u32 = 3;
const WT_END_GROUP: u32 = 4;
const WT_I32: u32 = 5;
/// 入れ子の上限 (upb の既定。メッセージと group を 1 段と数える)
const DEPTH_LIMIT: u32 = 100;

/// varint で書く値 (int32 と enum の負の値は 64 ビットに広げる)
fn varint_of(v: &Value) -> u64 {
    match v {
        Value::I32(n) => i64::from(*n) as u64,
        Value::U32(n) => u64::from(*n),
        Value::U64(n) => *n,
        Value::Bool(b) => u64::from(*b),
        Value::Bytes(_) | Value::Msg(_) => unreachable!("varint で書かない値"),
    }
}

pub(crate) fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

fn put_tag(out: &mut Vec<u8>, number: u32, wt: u32) {
    put_varint(out, u64::from((number << 3) | wt));
}

/// バイト列を読む口。
struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn at_end(&self) -> bool {
        self.pos >= self.buf.len()
    }

    /// varint (10 バイトまで。64 ビットを超える分は捨てる。upb と同じ)
    fn varint(&mut self) -> Result<u64, DecodeError> {
        let mut v: u64 = 0;
        for i in 0..10 {
            let Some(&b) = self.buf.get(self.pos) else {
                return Err(DecodeError("varint の途中で終わっている"));
            };
            self.pos += 1;
            v |= u64::from(b & 0x7f) << (7 * i);
            if b & 0x80 == 0 {
                return Ok(v);
            }
        }
        Err(DecodeError("varint が 10 バイトを超える"))
    }

    /// tag (5 バイトまでの varint で、32 ビットに収まる。upb と同じ)
    fn tag(&mut self) -> Result<u32, DecodeError> {
        let mut v: u64 = 0;
        for i in 0..5 {
            let Some(&b) = self.buf.get(self.pos) else {
                return Err(DecodeError("tag の途中で終わっている"));
            };
            self.pos += 1;
            v |= u64::from(b & 0x7f) << (7 * i);
            if b & 0x80 == 0 {
                return u32::try_from(v).map_err(|_| DecodeError("tag が 32 ビットを超える"));
            }
        }
        Err(DecodeError("tag が 5 バイトを超える"))
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        let end = self
            .pos
            .checked_add(n)
            .filter(|e| *e <= self.buf.len())
            .ok_or(DecodeError("項目の途中で終わっている"))?;
        let s = &self.buf[self.pos..end];
        self.pos = end;
        Ok(s)
    }

    /// 長さの付いた中身
    fn delimited(&mut self) -> Result<&'a [u8], DecodeError> {
        let n = self.varint()?;
        let n = usize::try_from(n).map_err(|_| DecodeError("長さが大きすぎる"))?;
        self.take(n)
    }
}

/// `buf` を `desc` のメッセージとして読む。
pub fn decode(desc: &'static MsgDesc, buf: &[u8]) -> Result<Message, DecodeError> {
    let mut m = Message::new(desc);
    merge(&mut m, buf, DEPTH_LIMIT)?;
    Ok(m)
}

/// 入れ子に入る (残りの段を 1 つ減らす。尽きていれば読めない)
fn deeper(depth: u32) -> Result<u32, DecodeError> {
    depth.checked_sub(1).ok_or(DecodeError("入れ子が深すぎる"))
}

/// `buf` を `m` に混ぜて読む (同じ項目が既にあれば、スカラーは上書き、メッセージは混ぜる)。
fn merge(m: &mut Message, buf: &[u8], depth: u32) -> Result<(), DecodeError> {
    let mut r = Reader { buf, pos: 0 };
    while !r.at_end() {
        let start = r.pos;
        let tag = r.tag()?;
        let number = tag >> 3;
        let wt = tag & 7;
        if number == 0 {
            return Err(DecodeError("項目の番号が 0"));
        }
        if wt == WT_END_GROUP {
            return Err(DecodeError("group の終わりに合う始まりが無い"));
        }
        if wt > WT_I32 {
            return Err(DecodeError("知らない wire type"));
        }
        let field = m.desc.by_number(number);
        match field {
            Some(f) if f.ty.is_varint() && wt == WT_VARINT => {
                let v = r.varint()?;
                match scalar(f.ty, v) {
                    Some(value) => store(m, f, value),
                    // 閉じた enum の知らない値: 元のバイトのまま知らない項目へ
                    None => m.unknown.extend_from_slice(&r.buf[start..r.pos]),
                }
            }
            Some(f) if f.ty.is_varint() && f.repeated && wt == WT_LEN => {
                let body = r.delimited()?;
                let mut p = Reader { buf: body, pos: 0 };
                while !p.at_end() {
                    let v = p.varint()?;
                    match scalar(f.ty, v) {
                        Some(value) => store(m, f, value),
                        // packed の enum の知らない値: 1 つずつ varint の項目に作り直す
                        None => {
                            put_tag(&mut m.unknown, f.number, WT_VARINT);
                            put_varint(&mut m.unknown, v);
                        }
                    }
                }
            }
            Some(f) if matches!(f.ty, Ty::String | Ty::Bytes) && wt == WT_LEN => {
                let body = r.delimited()?;
                store(m, f, Value::Bytes(body.to_vec()));
            }
            Some(f) if wt == WT_LEN && matches!(f.ty, Ty::Message(_)) => {
                let Ty::Message(sub_desc) = f.ty else {
                    unreachable!()
                };
                let body = r.delimited()?;
                let d = deeper(depth)?;
                if f.repeated {
                    let mut sub = Message::new(sub_desc);
                    merge(&mut sub, body, d)?;
                    m.fields.entry(f.number).or_default().push(Value::Msg(sub));
                } else {
                    let slot = m
                        .fields
                        .entry(f.number)
                        .or_insert_with(|| vec![Value::Msg(Message::new(sub_desc))]);
                    let Some(Value::Msg(sub)) = slot.last_mut() else {
                        unreachable!("メッセージの項目にはメッセージしか入らない")
                    };
                    merge(sub, body, d)?;
                }
            }
            // 知らない項目と、型の合わない wire type の項目: 元のバイトのまま知らない項目へ
            _ => {
                skip(&mut r, number, wt, depth)?;
                m.unknown.extend_from_slice(&r.buf[start..r.pos]);
            }
        }
    }
    Ok(())
}

/// varint の値を項目の型の値にする (閉じた enum の知らない値は None)。int32 と enum は下の 32 ビット、uint32 も下の 32 ビット。
fn scalar(ty: Ty, v: u64) -> Option<Value> {
    Some(match ty {
        Ty::Int32 => Value::I32(v as u32 as i32),
        Ty::Uint32 => Value::U32(v as u32),
        Ty::Uint64 => Value::U64(v),
        Ty::Bool => Value::Bool(v != 0),
        Ty::Enum(e) => {
            let n = v as u32 as i32;
            e.name_of(n)?;
            Value::I32(n)
        }
        Ty::String | Ty::Bytes | Ty::Message(_) => unreachable!("varint で読まない型"),
    })
}

fn store(m: &mut Message, f: &'static FieldDesc, value: Value) {
    let slot = m.fields.entry(f.number).or_default();
    if f.repeated {
        slot.push(value);
    } else {
        *slot = vec![value];
    }
}

/// 項目を読み飛ばす (group は終わりまで。入れ子の group も)。
fn skip(r: &mut Reader, number: u32, wt: u32, depth: u32) -> Result<(), DecodeError> {
    match wt {
        WT_VARINT => {
            r.varint()?;
        }
        WT_I64 => {
            r.take(8)?;
        }
        WT_LEN => {
            r.delimited()?;
        }
        WT_I32 => {
            r.take(4)?;
        }
        WT_START_GROUP => {
            let d = deeper(depth)?;
            loop {
                if r.at_end() {
                    return Err(DecodeError("group が閉じていない"));
                }
                let tag = r.tag()?;
                let (n, w) = (tag >> 3, tag & 7);
                if n == 0 {
                    return Err(DecodeError("項目の番号が 0"));
                }
                if w == WT_END_GROUP {
                    if n == number {
                        return Ok(());
                    }
                    return Err(DecodeError("group の終わりの番号が始まりと違う"));
                }
                if w > WT_I32 {
                    return Err(DecodeError("知らない wire type"));
                }
                skip(r, n, w, d)?;
            }
        }
        _ => return Err(DecodeError("知らない wire type")),
    }
    Ok(())
}

// ------------------------------------------------------------------ 型の表 (Mozc の .proto の写しを手で写したもの)

macro_rules! field {
    ($number:expr, $name:expr, $ty:expr) => {
        FieldDesc {
            number: $number,
            name: $name,
            ty: $ty,
            repeated: false,
            packed: false,
        }
    };
    ($number:expr, $name:expr, $ty:expr, repeated) => {
        FieldDesc {
            number: $number,
            name: $name,
            ty: $ty,
            repeated: true,
            packed: false,
        }
    };
    ($number:expr, $name:expr, $ty:expr, packed) => {
        FieldDesc {
            number: $number,
            name: $name,
            ty: $ty,
            repeated: true,
            packed: true,
        }
    };
}

pub static GENERAL_CONFIG: MsgDesc = MsgDesc {
    full_name: "mozc.config.GeneralConfig",
    fields: &[
        field!(1, "config_version", Ty::Uint32),
        field!(2, "last_modified_product_version", Ty::String),
        field!(3, "last_modified_time", Ty::Uint64),
        field!(4, "platform", Ty::String),
        field!(5, "ui_locale", Ty::String),
        field!(6, "upload_usage_stats", Ty::Bool),
    ],
};

pub static PREEDIT_METHOD: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.PreeditMethod",
    values: &[("ROMAN", 0), ("KANA", 1)],
};

pub static SESSION_KEYMAP: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.SessionKeymap",
    values: &[
        ("NONE", -1),
        ("CUSTOM", 0),
        ("ATOK", 1),
        ("MSIME", 2),
        ("KOTOERI", 3),
        ("MOBILE", 4),
        ("CHROMEOS", 5),
        ("OVERLAY_HENKAN_MUHENKAN_TO_IME_ON_OFF", 100),
        ("OVERLAY_FOR_TEST", 10000),
    ],
};

pub static PUNCTUATION_METHOD: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.PunctuationMethod",
    values: &[
        ("TOUTEN_KUTEN", 0),
        ("COMMA_PERIOD", 1),
        ("TOUTEN_PERIOD", 2),
        ("COMMA_KUTEN", 3),
    ],
};

pub static SYMBOL_METHOD: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.SymbolMethod",
    values: &[
        ("CORNER_BRACKET_MIDDLE_DOT", 0),
        ("SQUARE_BRACKET_SLASH", 1),
        ("CORNER_BRACKET_SLASH", 2),
        ("SQUARE_BRACKET_MIDDLE_DOT", 3),
    ],
};

pub static FUNDAMENTAL_CHARACTER_FORM: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.FundamentalCharacterForm",
    values: &[
        ("FUNDAMENTAL_INPUT_MODE", 0),
        ("FUNDAMENTAL_FULL_WIDTH", 1),
        ("FUNDAMENTAL_HALF_WIDTH", 2),
    ],
};

pub static HISTORY_LEARNING_LEVEL: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.HistoryLearningLevel",
    values: &[("DEFAULT_HISTORY", 0), ("READ_ONLY", 1), ("NO_HISTORY", 2)],
};

pub static SELECTION_SHORTCUT: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.SelectionShortcut",
    values: &[
        ("NO_SHORTCUT", 0),
        ("SHORTCUT_123456789", 1),
        ("SHORTCUT_ASDFGHJKL", 2),
    ],
};

pub static CHARACTER_FORM: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.CharacterForm",
    values: &[
        ("HALF_WIDTH", 0),
        ("FULL_WIDTH", 1),
        ("LAST_FORM", 2),
        ("NO_CONVERSION", 3),
    ],
};

pub static CHARACTER_FORM_RULE: MsgDesc = MsgDesc {
    full_name: "mozc.config.Config.CharacterFormRule",
    fields: &[
        field!(1, "group", Ty::String),
        field!(2, "preedit_character_form", Ty::Enum(&CHARACTER_FORM)),
        field!(3, "conversion_character_form", Ty::Enum(&CHARACTER_FORM)),
    ],
};

pub static SHIFT_KEY_MODE_SWITCH: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.ShiftKeyModeSwitch",
    values: &[
        ("OFF", 0),
        ("ASCII_INPUT_MODE", 1),
        ("KATAKANA_INPUT_MODE", 2),
    ],
};

pub static NUMPAD_CHARACTER_FORM: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.NumpadCharacterForm",
    values: &[
        ("NUMPAD_INPUT_MODE", 0),
        ("NUMPAD_FULL_WIDTH", 1),
        ("NUMPAD_HALF_WIDTH", 2),
        ("NUMPAD_DIRECT_INPUT", 3),
    ],
};

pub static YEN_SIGN_CHARACTER: EnumDesc = EnumDesc {
    full_name: "mozc.config.Config.YenSignCharacter",
    values: &[("YEN_SIGN", 0), ("BACKSLASH", 1)],
};

pub static INFORMATION_LIST_CONFIG: MsgDesc = MsgDesc {
    full_name: "mozc.config.Config.InformationListConfig",
    fields: &[field!(1, "use_local_usage_dictionary", Ty::Bool)],
};

/// `mozc.config.Config` (`config1.db`)
pub static CONFIG: MsgDesc = MsgDesc {
    full_name: "mozc.config.Config",
    fields: &[
        field!(1, "general_config", Ty::Message(&GENERAL_CONFIG)),
        field!(10, "verbose_level", Ty::Int32),
        field!(20, "incognito_mode", Ty::Bool),
        field!(22, "check_default", Ty::Bool),
        field!(23, "presentation_mode", Ty::Bool),
        field!(40, "preedit_method", Ty::Enum(&PREEDIT_METHOD)),
        field!(41, "session_keymap", Ty::Enum(&SESSION_KEYMAP)),
        field!(42, "custom_keymap_table", Ty::Bytes),
        field!(43, "custom_roman_table", Ty::Bytes),
        field!(45, "punctuation_method", Ty::Enum(&PUNCTUATION_METHOD)),
        field!(46, "symbol_method", Ty::Enum(&SYMBOL_METHOD)),
        field!(
            47,
            "space_character_form",
            Ty::Enum(&FUNDAMENTAL_CHARACTER_FORM)
        ),
        field!(48, "use_keyboard_to_change_preedit_method", Ty::Bool),
        field!(
            50,
            "history_learning_level",
            Ty::Enum(&HISTORY_LEARNING_LEVEL)
        ),
        field!(52, "selection_shortcut", Ty::Enum(&SELECTION_SHORTCUT)),
        field!(
            54,
            "character_form_rules",
            Ty::Message(&CHARACTER_FORM_RULE),
            repeated
        ),
        field!(56, "auto_switch_composition_mode", Ty::Bool),
        field!(58, "use_cascading_window", Ty::Bool),
        field!(
            59,
            "shift_key_mode_switch",
            Ty::Enum(&SHIFT_KEY_MODE_SWITCH)
        ),
        field!(
            60,
            "numpad_character_form",
            Ty::Enum(&NUMPAD_CHARACTER_FORM)
        ),
        field!(61, "use_auto_conversion", Ty::Bool),
        field!(62, "auto_conversion_key", Ty::Uint32),
        field!(63, "yen_sign_character", Ty::Enum(&YEN_SIGN_CHARACTER)),
        field!(64, "use_japanese_layout", Ty::Bool),
        field!(65, "use_kana_modifier_insensitive_conversion", Ty::Bool),
        field!(66, "use_typing_correction", Ty::Bool),
        field!(67, "composing_timeout_threshold_msec", Ty::Int32),
        field!(68, "overlay_keymaps", Ty::Enum(&SESSION_KEYMAP), packed),
        field!(80, "use_date_conversion", Ty::Bool),
        field!(81, "use_single_kanji_conversion", Ty::Bool),
        field!(82, "use_symbol_conversion", Ty::Bool),
        field!(83, "use_number_conversion", Ty::Bool),
        field!(84, "use_emoticon_conversion", Ty::Bool),
        field!(85, "use_calculator", Ty::Bool),
        field!(86, "use_t13n_conversion", Ty::Bool),
        field!(87, "use_zip_code_conversion", Ty::Bool),
        field!(88, "use_spelling_correction", Ty::Bool),
        field!(89, "use_emoji_conversion", Ty::Bool),
        field!(
            90,
            "information_list_config",
            Ty::Message(&INFORMATION_LIST_CONFIG)
        ),
        field!(100, "use_history_suggest", Ty::Bool),
        field!(101, "use_dictionary_suggest", Ty::Bool),
        field!(102, "use_realtime_conversion", Ty::Bool),
        field!(110, "suggestions_size", Ty::Uint32),
        field!(120, "use_mode_indicator", Ty::Bool),
    ],
};

pub static POS_TYPE: EnumDesc = EnumDesc {
    full_name: "mozc.user_dictionary.UserDictionary.PosType",
    values: &[
        ("NO_POS", 0),
        ("NOUN", 1),
        ("ABBREVIATION", 2),
        ("SUGGESTION_ONLY", 3),
        ("PROPER_NOUN", 4),
        ("PERSONAL_NAME", 5),
        ("FAMILY_NAME", 6),
        ("FIRST_NAME", 7),
        ("ORGANIZATION_NAME", 8),
        ("PLACE_NAME", 9),
        ("SA_IRREGULAR_CONJUGATION_NOUN", 10),
        ("ADJECTIVE_VERBAL_NOUN", 11),
        ("NUMBER", 12),
        ("ALPHABET", 13),
        ("SYMBOL", 14),
        ("EMOTICON", 15),
        ("ADVERB", 16),
        ("PRENOUN_ADJECTIVAL", 17),
        ("CONJUNCTION", 18),
        ("INTERJECTION", 19),
        ("PREFIX", 20),
        ("COUNTER_SUFFIX", 21),
        ("GENERIC_SUFFIX", 22),
        ("PERSON_NAME_SUFFIX", 23),
        ("PLACE_NAME_SUFFIX", 24),
        ("WA_GROUP1_VERB", 25),
        ("KA_GROUP1_VERB", 26),
        ("SA_GROUP1_VERB", 27),
        ("TA_GROUP1_VERB", 28),
        ("NA_GROUP1_VERB", 29),
        ("MA_GROUP1_VERB", 30),
        ("RA_GROUP1_VERB", 31),
        ("GA_GROUP1_VERB", 32),
        ("BA_GROUP1_VERB", 33),
        ("HA_GROUP1_VERB", 34),
        ("GROUP2_VERB", 35),
        ("KURU_GROUP3_VERB", 36),
        ("SURU_GROUP3_VERB", 37),
        ("ZURU_GROUP3_VERB", 38),
        ("RU_GROUP3_VERB", 39),
        ("ADJECTIVE", 40),
        ("SENTENCE_ENDING_PARTICLE", 41),
        ("PUNCTUATION", 42),
        ("FREE_STANDING_WORD", 43),
        ("SUPPRESSION_WORD", 44),
    ],
};

pub static ENTRY: MsgDesc = MsgDesc {
    full_name: "mozc.user_dictionary.UserDictionary.Entry",
    fields: &[
        field!(1, "key", Ty::String),
        field!(2, "value", Ty::String),
        field!(4, "comment", Ty::String),
        field!(5, "pos", Ty::Enum(&POS_TYPE)),
        field!(12, "locale", Ty::String),
    ],
};

pub static USER_DICTIONARY: MsgDesc = MsgDesc {
    full_name: "mozc.user_dictionary.UserDictionary",
    fields: &[
        field!(1, "id", Ty::Uint64),
        field!(3, "name", Ty::String),
        field!(4, "entries", Ty::Message(&ENTRY), repeated),
    ],
};

/// `mozc.user_dictionary.UserDictionaryStorage` (`user_dictionary.db`)
pub static STORAGE: MsgDesc = MsgDesc {
    full_name: "mozc.user_dictionary.UserDictionaryStorage",
    fields: &[
        field!(1, "version", Ty::Int32),
        field!(2, "dictionaries", Ty::Message(&USER_DICTIONARY), repeated),
    ],
};

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 型の表が Mozc の .proto の写し (`nix/pkgs/pjp-google-ime/proto/`) と同じ (項目の番号・名前・型・repeated・packed、enum の値)
    //! - upb と同じ読み書き (値は Python の protobuf 7.36.2 (upb) で確かめたバイト列): 番号の順に書き、知らない項目を末尾に足す・閉じた enum の
    //!   知らない値 (packed でないものは元のバイト、packed のものは作り直す)・型の合わない wire type・同じ項目の上書きと混ぜ方・負の int32 は
    //!   10 バイト・bool の 2 は 1・32 ビットを超える値は切る・10 バイト目の varint・tag の上限・入れ子の上限・壊れたバイト列

    use super::*;
    use std::path::Path;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    /// 読んで書き直したバイト列 (読めなければ None)
    fn roundtrip(desc: &'static MsgDesc, input: &str) -> Option<String> {
        decode(desc, &unhex(input)).ok().map(|m| hex(&m.encode()))
    }

    #[test]
    fn writes_known_fields_in_number_order_and_unknown_at_the_end() {
        // verbose_level=0・session_keymap=6 (知らない値)・incognito_mode=true の順で読むと、知らない値が末尾に回る
        assert_eq!(
            roundtrip(&CONFIG, "5000c80206a00101").as_deref(),
            Some("5000a00101c80206")
        );
        // 知らない項目は読んだ順のまま (番号の順に並べ直さない)
        assert_eq!(
            roundtrip(&CONFIG, "f807015000f00702").as_deref(),
            Some("5000f80701f00702")
        );
        // 入れ子のメッセージの知らない項目も残る
        assert_eq!(
            roundtrip(&CONFIG, "d20503f80701").as_deref(),
            Some("d20503f80701")
        );
        let m = decode(&CONFIG, &unhex("d20503f80701")).unwrap();
        assert!(m.has_unknown() && m.unknown().is_empty());
    }

    #[test]
    fn unknown_enum_values() {
        // packed でない: 元のバイトのまま (10 バイト・5 バイト・冗長な 2 バイト)
        assert_eq!(
            roundtrip(&CONFIG, "c802feffffffffffffffff01").as_deref(),
            Some("c802feffffffffffffffff01")
        );
        assert_eq!(
            roundtrip(&CONFIG, "c802feffffff0f").as_deref(),
            Some("c802feffffff0f")
        );
        assert_eq!(roundtrip(&CONFIG, "c8028600").as_deref(), Some("c8028600"));
        // 冗長な書き方の知っている値は、短い形に直す
        assert_eq!(roundtrip(&CONFIG, "c8028100").as_deref(), Some("c80201"));
        // 2^32+1 は下の 32 ビット (1 = ATOK)
        assert_eq!(
            roundtrip(&CONFIG, "c8028180808010").as_deref(),
            Some("c80201")
        );
        // packed: 知っている値は packed のまま、知らない値は 1 つずつ varint の項目に作り直して末尾へ
        assert_eq!(
            roundtrip(&CONFIG, "a204020107").as_deref(),
            Some("a2040101a00407")
        );
        assert_eq!(
            roundtrip(&CONFIG, "a2040afeffffffffffffffff01").as_deref(),
            Some("a004feffffffffffffffff01")
        );
        assert_eq!(
            roundtrip(&CONFIG, "a20405feffffff0f").as_deref(),
            Some("a004feffffff0f")
        );
        assert_eq!(roundtrip(&CONFIG, "a204028600").as_deref(), Some("a00406"));
        // packed の知っている -1 (5 バイト) は 10 バイトで書く
        assert_eq!(
            roundtrip(&CONFIG, "a20405ffffffff0f").as_deref(),
            Some("a2040affffffffffffffffff01")
        );
        // packed でない repeated も読み、packed で書く。空の packed は書かない
        assert_eq!(
            roundtrip(&CONFIG, "a00401a00402").as_deref(),
            Some("a204020102")
        );
        assert_eq!(roundtrip(&CONFIG, "a20400").as_deref(), Some(""));
        // 辞書の品詞の知らない値 (99) は語の中に残る
        assert_eq!(
            roundtrip(&STORAGE, "120422022863").as_deref(),
            Some("120422022863")
        );
    }

    #[test]
    fn mismatched_wire_types_become_unknown() {
        // int32 を長さ付きで: 知らない項目 (値は無い)
        let m = decode(&CONFIG, &unhex("520141")).unwrap();
        assert!(!m.has("verbose_level"));
        assert_eq!(hex(&m.encode()), "520141");
        // メッセージを group で・string を varint で
        assert_eq!(roundtrip(&CONFIG, "0b08010c").as_deref(), Some("0b08010c"));
        assert_eq!(roundtrip(&STORAGE, "12021801").as_deref(), Some("12021801"));
        // 知らない項目の長さ付き・fixed32・fixed64・入れ子の group
        assert_eq!(
            roundtrip(&CONFIG, "fa07024142").as_deref(),
            Some("fa07024142")
        );
        assert_eq!(
            roundtrip(&CONFIG, "fd0701020304").as_deref(),
            Some("fd0701020304")
        );
        assert_eq!(
            roundtrip(&CONFIG, "f9070102030405060708").as_deref(),
            Some("f9070102030405060708")
        );
        assert_eq!(
            roundtrip(&CONFIG, "fb071201411d01020304fc07").as_deref(),
            Some("fb071201411d01020304fc07")
        );
        assert_eq!(
            roundtrip(&CONFIG, "fb070b0cfc07").as_deref(),
            Some("fb070b0cfc07")
        );
    }

    #[test]
    fn repeated_reads_overwrite_scalars_and_merge_messages() {
        assert_eq!(roundtrip(&CONFIG, "50015002").as_deref(), Some("5002"));
        // information_list_config が 2 度: 混ぜる (中の値は残る)
        assert_eq!(
            roundtrip(&CONFIG, "d20502080 0d20500".replace(' ', "").as_str()).as_deref(),
            Some("d205020800")
        );
        // 空のメッセージも「値がある」
        let m = decode(&CONFIG, &unhex("d20500")).unwrap();
        assert!(m.has("information_list_config"));
        assert_eq!(hex(&m.encode()), "d20500");
    }

    #[test]
    fn scalar_conversions() {
        // bool の 2 は 1、負の int32 (5 バイトの 0xffffffff) は 10 バイト、uint32 は下の 32 ビット、uint64 の冗長な書き方は短く
        assert_eq!(roundtrip(&CONFIG, "a00102").as_deref(), Some("a00101"));
        assert_eq!(
            roundtrip(&CONFIG, "50ffffffff0f").as_deref(),
            Some("50ffffffffffffffffff01")
        );
        assert_eq!(
            roundtrip(&CONFIG, "f0068180808010").as_deref(),
            Some("f00601")
        );
        assert_eq!(
            roundtrip(&STORAGE, "1203088100").as_deref(),
            Some("12020801")
        );
        assert_eq!(
            roundtrip(&STORAGE, "08feffffff0f").as_deref(),
            Some("08feffffffffffffffff01")
        );
        // 10 バイト目は続きの印が無ければ受ける (64 ビットを超える分は捨てる)
        assert_eq!(
            roundtrip(&CONFIG, "50ffffffffffffffffff7f").as_deref(),
            Some("50ffffffffffffffffff01")
        );
        assert_eq!(
            roundtrip(&CONFIG, "5080808080808080808002").as_deref(),
            Some("5000")
        );
        // string は UTF-8 を確かめずに持つ
        assert_eq!(
            roundtrip(&STORAGE, "12031a01ff").as_deref(),
            Some("12031a01ff")
        );
    }

    #[test]
    fn broken_inputs_are_refused() {
        for input in [
            "50808080808080808080800000", // 11 バイトの varint
            "0000",                       // 番号 0
            "520541",                     // 長さが足りない
            "0c",                         // 始まりの無い group の終わり
            "0e",                         // wire type 6
            "0f",                         // wire type 7
            "d08080808080000101",         // 6 バイトの tag
            "f8ffffff1f01",               // 32 ビットを超える tag
            "9205ffffffff0f",             // 大きすぎる長さ
            "fb070c",                     // group の終わりの番号が違う
            "fb07",                       // 閉じていない group
            "a204028080",                 // packed の中の varint が途中で終わる
        ] {
            assert!(decode(&CONFIG, &unhex(input)).is_err(), "{input}");
        }
        // 5 バイトの冗長な tag と、いちばん大きい番号は受ける
        assert_eq!(roundtrip(&CONFIG, "d08080800001").as_deref(), Some("5001"));
        assert_eq!(
            roundtrip(&CONFIG, "f8ffffff0f01").as_deref(),
            Some("f8ffffff0f01")
        );
    }

    #[test]
    fn nesting_is_limited_to_100() {
        let groups = |n: usize| {
            let mut s = "fb07".repeat(n);
            s.push_str(&"fc07".repeat(n));
            s
        };
        assert!(decode(&CONFIG, &unhex(&groups(100))).is_ok());
        assert!(decode(&CONFIG, &unhex(&groups(101))).is_err());
        // 辞書と語のメッセージも 1 段ずつ数える (98 段の group まで)
        let in_entry = |n: usize| {
            let inner = unhex(&groups(n));
            let mut entry = vec![0x22];
            put_varint(&mut entry, inner.len() as u64);
            entry.extend(inner);
            let mut out = vec![0x12];
            put_varint(&mut out, entry.len() as u64);
            out.extend(entry);
            out
        };
        assert!(decode(&STORAGE, &in_entry(98)).is_ok());
        assert!(decode(&STORAGE, &in_entry(99)).is_err());
    }

    #[test]
    fn builds_and_writes_values() {
        let mut m = Message::new(&CONFIG);
        m.set("verbose_level", Value::I32(0));
        m.set("session_keymap", Value::I32(-1));
        m.push("overlay_keymaps", Value::I32(100));
        m.push("overlay_keymaps", Value::I32(1));
        let mut rule = Message::new(&CHARACTER_FORM_RULE);
        rule.set("group", Value::Bytes(b"a".to_vec()));
        m.push("character_form_rules", Value::Msg(rule));
        m.set(
            "information_list_config",
            Value::Msg(Message::new(&INFORMATION_LIST_CONFIG)),
        );
        assert_eq!(
            hex(&m.encode()),
            "5000c802ffffffffffffffffff01b203030a0161a204026401d20500"
        );
        assert_eq!(decode(&CONFIG, &m.encode()).unwrap(), m);
        m.clear("overlay_keymaps");
        assert!(!m.has("overlay_keymaps") && m.values("overlay_keymaps").is_empty());
    }

    // ---------------------------------------------------------- .proto との突き合わせ

    /// .proto の写しから読んだ項目 1 つ (番号, 名前, 型の名前, repeated, packed)
    type ProtoField = (u32, String, String, bool, bool);

    /// .proto の写しから読んだメッセージ (名前 → 項目) と enum (名前 → 値)
    struct Proto {
        messages: Vec<(String, Vec<ProtoField>)>,
        enums: Vec<(String, Vec<(String, i32)>)>,
    }

    /// .proto を読む (コメントを外し、`;`・`{`・`}` で区切った文を、入れ子のメッセージと enum の中で読む。写しの .proto に出てくる書き方だけ)
    fn read_proto(text: &str) -> Proto {
        let mut clean = String::new();
        for line in text.lines() {
            clean.push_str(line.split("//").next().unwrap());
            clean.push('\n');
        }
        let mut package = String::new();
        let mut stack: Vec<(bool, String)> = Vec::new();
        let mut p = Proto {
            messages: Vec::new(),
            enums: Vec::new(),
        };
        let mut stmt = String::new();
        for c in clean.chars() {
            match c {
                '{' => {
                    let words: Vec<&str> = stmt.split_whitespace().collect();
                    let is_enum = words[0] == "enum";
                    let scope: Vec<String> = stack.iter().map(|s| s.1.clone()).collect();
                    let full = format!(
                        "{package}.{}",
                        [scope, vec![words[1].to_string()]].concat().join(".")
                    );
                    if is_enum {
                        p.enums.push((full.clone(), Vec::new()));
                    } else {
                        p.messages.push((full.clone(), Vec::new()));
                    }
                    stack.push((is_enum, words[1].to_string()));
                    stmt.clear();
                }
                '}' => {
                    stack.pop();
                    stmt.clear();
                }
                ';' => {
                    let s = stmt.split_whitespace().collect::<Vec<_>>().join(" ");
                    stmt.clear();
                    if let Some(rest) = s.strip_prefix("package ") {
                        package = rest.to_string();
                        continue;
                    }
                    let Some((is_enum, _)) = stack.last() else {
                        continue;
                    };
                    let scope: Vec<String> = stack.iter().map(|s| s.1.clone()).collect();
                    let full = format!("{package}.{}", scope.join("."));
                    if *is_enum {
                        let Some((name, num)) = s.split_once(" = ") else {
                            continue;
                        };
                        if name.starts_with("option") || name.starts_with("reserved") {
                            continue;
                        }
                        let e = p.enums.iter_mut().find(|e| e.0 == full).unwrap();
                        e.1.push((name.to_string(), num.trim().parse().unwrap()));
                    } else {
                        let words: Vec<&str> = s.split(' ').collect();
                        if !matches!(words[0], "optional" | "repeated") {
                            continue;
                        }
                        let number: u32 = words[4].trim_end_matches(';').parse().unwrap();
                        let packed = s.contains("packed = true");
                        let m = p.messages.iter_mut().find(|m| m.0 == full).unwrap();
                        m.1.push((
                            number,
                            words[2].to_string(),
                            words[1].to_string(),
                            words[0] == "repeated",
                            packed,
                        ));
                    }
                }
                _ => stmt.push(c),
            }
        }
        p
    }

    /// 型の表の型の名前 (.proto に書く名前。enum とメッセージは最後の要素)
    fn ty_name(ty: Ty) -> String {
        match ty {
            Ty::Int32 => "int32".into(),
            Ty::Uint32 => "uint32".into(),
            Ty::Uint64 => "uint64".into(),
            Ty::Bool => "bool".into(),
            Ty::String => "string".into(),
            Ty::Bytes => "bytes".into(),
            Ty::Enum(e) => e.full_name.rsplit('.').next().unwrap().into(),
            Ty::Message(m) => m.full_name.rsplit('.').next().unwrap().into(),
        }
    }

    #[test]
    fn tables_match_the_proto_copies() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("nix")
            .join("pkgs")
            .join("pjp-google-ime")
            .join("proto");
        let mut messages = Vec::new();
        let mut enums = Vec::new();
        for f in ["config.proto", "user_dictionary_storage.proto"] {
            let p = read_proto(&std::fs::read_to_string(dir.join(f)).unwrap());
            messages.extend(p.messages);
            enums.extend(p.enums);
        }
        let ours: [&'static MsgDesc; 7] = [
            &GENERAL_CONFIG,
            &CONFIG,
            &CHARACTER_FORM_RULE,
            &INFORMATION_LIST_CONFIG,
            &USER_DICTIONARY,
            &ENTRY,
            &STORAGE,
        ];
        assert_eq!(messages.len(), ours.len(), "メッセージの数");
        for desc in ours {
            let (_, fields) = messages
                .iter()
                .find(|m| m.0 == desc.full_name)
                .unwrap_or_else(|| panic!("{} が .proto に無い", desc.full_name));
            let mine: Vec<ProtoField> = desc
                .fields
                .iter()
                .map(|f| {
                    (
                        f.number,
                        f.name.to_string(),
                        ty_name(f.ty),
                        f.repeated,
                        f.packed,
                    )
                })
                .collect();
            let mut theirs = fields.clone();
            theirs.sort_by_key(|f| f.0);
            assert_eq!(mine, theirs, "{}", desc.full_name);
        }
        let ours: [&'static EnumDesc; 12] = [
            &PREEDIT_METHOD,
            &SESSION_KEYMAP,
            &PUNCTUATION_METHOD,
            &SYMBOL_METHOD,
            &FUNDAMENTAL_CHARACTER_FORM,
            &HISTORY_LEARNING_LEVEL,
            &SELECTION_SHORTCUT,
            &CHARACTER_FORM,
            &SHIFT_KEY_MODE_SWITCH,
            &NUMPAD_CHARACTER_FORM,
            &YEN_SIGN_CHARACTER,
            &POS_TYPE,
        ];
        for e in ours {
            let (_, values) = enums
                .iter()
                .find(|x| x.0 == e.full_name)
                .unwrap_or_else(|| panic!("{} が .proto に無い", e.full_name));
            let mine: Vec<(String, i32)> =
                e.values.iter().map(|(n, v)| (n.to_string(), *v)).collect();
            assert_eq!(&mine, values, "{}", e.full_name);
        }
        // 項目の型にしていない enum は AutoConversionKey だけ (auto_conversion_key は uint32)
        let unused: Vec<&str> = enums
            .iter()
            .map(|e| e.0.as_str())
            .filter(|n| !ours.iter().any(|o| o.full_name == *n))
            .collect();
        assert_eq!(unused, vec!["mozc.config.Config.AutoConversionKey"]);
    }
}
