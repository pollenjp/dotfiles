//! pjp-google-ime (`nix/pkgs/pjp-google-ime/google_ime.py`) を写したもの: Google 日本語入力の設定 (`config1.db`) とユーザー辞書
//! (`user_dictionary.db`) を、repo のテキストと行き来させる。Windows には触らない (読み書きするのは渡されたパスのファイルだけ)。
//!
//! テキストの形・組み立て・digest・取り込みの決まりと文は google_ime.py と同じ (同じテキストからは同じバイト列を組み立て、同じ digest を出す。
//! 試験が pjp-google-ime と突き合わせる)。辞書の語 (読み・単語・品詞・コメント) は、どの誤りの文にも出さない。
//!
//! - ファイルは UTF-8 で読み、改行を LF にそろえる (Python の `Path.read_text` と同じく、CRLF も単独の CR も LF にする)
//! - 辞書の名前が UTF-8 でない・語に UTF-8 でない字がある `user_dictionary.db` は、テキストにできないものとして止める (Python は TypeError で
//!   落ちる)。比べる digest は、名前が UTF-8 のものとそうでないものが混ざるときだけ出せない (Python の並べ替えが落ちる)
//! - 辞書の名前は Windows のファイル名にできるものだけにする (google_ime.py の決まりに、`<>:"|?*`・制御文字・装置の名前 (CON・NUL・COM1 など) と、
//!   大文字小文字だけが違う 2 つの名前を足して止める。`:` はドライブからの相対のパスや代替データストリームになり、置き場の外へ書いてしまう)
//! - 取り込みは、書くものを全部決めてから書く (今のテキストが読めなければ何も書かない)。大文字小文字だけを変えた辞書の TSV は、名前を替えてから
//!   比べる (Windows では同じファイルで、替えずに書くと古い名前のまま残り、「無くなった辞書」として消してしまう)

use super::pb::{self, Message, Value};
use super::textpb;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const CONFIG_DB: &str = "config1.db";
pub const DICTIONARY_DB: &str = "user_dictionary.db";
pub const TXTPB: &str = "config.txtpb";
pub const KEYMAP: &str = "keymap.tsv";
pub const ROMAJI: &str = "romaji.tsv";

/// `config.txtpb` の頭 (google_ime.py の TXTPB_HEADER と同じ字。WSL と同じテキストを書くため、WSL の --import を指したまま)
pub const TXTPB_HEADER: &str = "# Google 日本語入力の設定 (config1.db) のうち、キー設定 (keymap.tsv)・ローマ字テーブル (romaji.tsv)・\n\
# general_config を除いた全項目。protobuf のテキスト形式 (Mozc の mozc.config.Config)。\n\
# 画面で変えたら nix/scripts/bootstrap-windows-google-ime.sh --import で書き直す (ADR 015)。\n";

pub const KEYMAP_HEADER: &str = "status\tkey\tcommand";
/// Mozc の session/keymap.cc が受け付ける状態名 (Direct は DirectInput の別名)。コマンド名は確かめない
pub const KEYMAP_STATES: &[&str] = &[
    "DirectInput",
    "Direct",
    "Precomposition",
    "Composition",
    "Conversion",
    "ZeroQuerySuggestion",
    "Suggestion",
    "Prediction",
];

/// 辞書の品詞の名前。添え字が PosType の値 (google_ime.py の POS_NAMES と同じ並び。試験が .proto のコメントと突き合わせる)
pub const POS_NAMES: [&str; 45] = [
    "品詞なし",
    "名詞",
    "短縮よみ",
    "サジェストのみ",
    "固有名詞",
    "人名",
    "姓",
    "名",
    "組織",
    "地名",
    "名詞サ変",
    "名詞形動",
    "数",
    "アルファベット",
    "記号",
    "顔文字",
    "副詞",
    "連体詞",
    "接続詞",
    "感動詞",
    "接頭語",
    "助数詞",
    "接尾一般",
    "接尾人名",
    "接尾地名",
    "動詞ワ行五段",
    "動詞カ行五段",
    "動詞サ行五段",
    "動詞タ行五段",
    "動詞ナ行五段",
    "動詞マ行五段",
    "動詞ラ行五段",
    "動詞ガ行五段",
    "動詞バ行五段",
    "動詞ハ行四段",
    "動詞一段",
    "動詞カ変",
    "動詞サ変",
    "動詞ザ変",
    "動詞ラ変",
    "形容詞",
    "終助詞",
    "句読点",
    "独立語",
    "抑制単語",
];

/// Mozc の dictionary/user_dictionary_storage.cc の上限
const MAX_DICTIONARIES: usize = 100;
const MAX_ENTRIES: usize = 1_000_000;
/// session_keymap の CUSTOM
const CUSTOM: i32 = 0;
/// 語の品詞の既定 (NOUN = 名詞)
const DEFAULT_POS: i32 = 1;

/// テキストかバイナリが、組み立て・取り込みの決まりに合わない (google_ime.py の TextError)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextError(pub String);

impl std::fmt::Display for TextError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

fn err<T>(s: impl Into<String>) -> Result<T, TextError> {
    Err(TextError(s.into()))
}

/// Python の repr (誤りの文に出す。public なテキスト (キー設定・ローマ字テーブル・辞書の名前) だけに使う)
pub fn py_repr(s: &str) -> String {
    let quote = if s.contains('\'') && !s.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut out = String::new();
    out.push(quote);
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            c if c == quote => {
                out.push('\\');
                out.push(c);
            }
            c if (c as u32) < 0x20 || (0x7f..0xa0).contains(&(c as u32)) => {
                out.push_str(&format!("\\x{:02x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push(quote);
    out
}

// ------------------------------------------------------------------ 設定 (config1.db)

/// CRLF を LF にそろえ、末尾の改行を除いた行の並びにする (google_ime.py の split_lines)
pub fn split_lines(text: &str) -> Vec<String> {
    let text = text.replace("\r\n", "\n");
    let mut lines: Vec<String> = text.split('\n').map(str::to_string).collect();
    if lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    lines
}

/// keymap.tsv を確かめ、config1.db に入れる形 (LF・末尾に改行) にする
pub fn check_keymap(text: &str) -> Result<String, TextError> {
    let lines = split_lines(text);
    if lines.first().map(String::as_str) != Some(KEYMAP_HEADER) {
        return err(format!(
            "{KEYMAP}:1: 1 行目は見出しの「status<TAB>key<TAB>command」にする"
        ));
    }
    if lines.len() == 1 {
        return err(format!(
            "{KEYMAP}: キーの行が 1 つも無い (空のキー設定は配らない)"
        ));
    }
    for (i, line) in lines.iter().enumerate().skip(1) {
        let n = i + 1;
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() != 3 || fields.iter().any(|f| f.is_empty()) {
            return err(format!(
                "{KEYMAP}:{n}: 「状態<TAB>キー<TAB>コマンド」の 3 列になっていない: {}",
                py_repr(line)
            ));
        }
        if !KEYMAP_STATES.contains(&fields[0]) {
            let mut states = KEYMAP_STATES.to_vec();
            states.sort_unstable();
            return err(format!(
                "{KEYMAP}:{n}: 状態名 {} は Mozc に無い ({} のどれか)",
                py_repr(fields[0]),
                states.join("・")
            ));
        }
    }
    Ok(format!("{}\n", lines.join("\n")))
}

/// romaji.tsv を確かめ、config1.db に入れる形 (LF・末尾に改行) にする
pub fn check_romaji(text: &str) -> Result<String, TextError> {
    let lines = split_lines(text);
    if lines.is_empty() {
        return err(format!(
            "{ROMAJI}: 行が 1 つも無い (カスタムしないなら {ROMAJI} を置かない)"
        ));
    }
    for (i, line) in lines.iter().enumerate() {
        let fields: Vec<&str> = line.split('\t').collect();
        if !(2..=3).contains(&fields.len())
            || fields[0].is_empty()
            || fields[1..].iter().all(|f| f.is_empty())
        {
            return err(format!(
                "{ROMAJI}:{}: 「入力<TAB>出力[<TAB>次の入力]」になっていない: {}",
                i + 1,
                py_repr(line)
            ));
        }
    }
    Ok(format!("{}\n", lines.join("\n")))
}

/// verbose_level が無ければ既定の値 (0) を入れる (設定画面は保存のたびに入れるが、持たない config1.db もある)
pub fn fill_verbose_level(cfg: &mut Message) {
    if !cfg.has("verbose_level") {
        cfg.set("verbose_level", Value::I32(0));
    }
}

/// テキストから Config を組み立てる
pub fn config_from_text(
    txtpb: &str,
    keymap: Option<&str>,
    romaji: Option<&str>,
) -> Result<Message, TextError> {
    let mut cfg =
        textpb::parse(&pb::CONFIG, txtpb).map_err(|e| TextError(format!("{TXTPB}:{e}")))?;
    for (name, hint) in [
        (
            "general_config",
            "書かない (時刻・版・OS は Google 日本語入力が保存のたびに入れる)".to_string(),
        ),
        ("custom_keymap_table", format!("書かずに {KEYMAP} に置く")),
        ("custom_roman_table", format!("書かずに {ROMAJI} に置く")),
    ] {
        if cfg.has(name) {
            return err(format!("{TXTPB}: {name} は{hint}"));
        }
    }
    fill_verbose_level(&mut cfg);
    if let Some(k) = keymap {
        cfg.set(
            "custom_keymap_table",
            Value::Bytes(check_keymap(k)?.into_bytes()),
        );
    }
    if let Some(r) = romaji {
        cfg.set(
            "custom_roman_table",
            Value::Bytes(check_romaji(r)?.into_bytes()),
        );
    }
    if cfg.get_i32("session_keymap") == Some(CUSTOM) && keymap.is_none() {
        return err(format!(
            "{TXTPB}: session_keymap が CUSTOM なのに {KEYMAP} が無い"
        ));
    }
    Ok(cfg)
}

/// 設定のテキスト (config.txtpb・keymap.tsv・romaji.tsv。表が空なら None)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfigTexts {
    pub txtpb: String,
    pub keymap: Option<String>,
    pub romaji: Option<String>,
}

/// Config をテキストにする
pub fn config_to_text(cfg: &Message) -> Result<ConfigTexts, TextError> {
    if cfg.has_unknown() {
        return err(format!(
            "{CONFIG_DB} に今の .proto に無い項目がある (新しい版の Google 日本語入力が足した項目)。nix/pkgs/pjp-google-ime/proto/ の写しを新しくする"
        ));
    }
    let mut rest = cfg.clone();
    fill_verbose_level(&mut rest);
    let mut tables = Vec::new();
    for (name, file) in [
        ("custom_keymap_table", KEYMAP),
        ("custom_roman_table", ROMAJI),
    ] {
        let table = rest.get_bytes(name).map(<[u8]>::to_vec).unwrap_or_default();
        rest.clear(name);
        // 空の表は「無い」と同じ (設定画面は、カスタムしていないキー設定も空文字で入れる)
        if table.is_empty() {
            tables.push(None);
            continue;
        }
        match String::from_utf8(table) {
            Ok(s) => tables.push(Some(s)),
            Err(_) => {
                return err(format!(
                    "{CONFIG_DB} の {name} が UTF-8 ではないので {file} に書けない"
                ));
            }
        }
    }
    rest.clear("general_config");
    let romaji = tables.pop().flatten();
    let keymap = tables.pop().flatten();
    Ok(ConfigTexts {
        txtpb: format!("{TXTPB_HEADER}{}", textpb::print(&rest)),
        keymap,
        romaji,
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// 比べるための sha256 (general_config を外し、空の表は「無い」に、無い verbose_level は 0 にそろえる)
pub fn config_digest(cfg: &Message) -> String {
    let mut c = cfg.clone();
    c.clear("general_config");
    fill_verbose_level(&mut c);
    for name in ["custom_keymap_table", "custom_roman_table"] {
        if c.get_bytes(name).is_none_or(<[u8]>::is_empty) {
            c.clear(name);
        }
    }
    sha256_hex(&c.encode())
}

// ------------------------------------------------------------------ 辞書 (user_dictionary.db)

/// 辞書の id (乱数ではなく名前の sha256 の先頭 8 バイト。0 は使わない)
pub fn dictionary_id(name: &str) -> u64 {
    let d = Sha256::digest(name.as_bytes());
    let id = u64::from_be_bytes(d[..8].try_into().expect("8 バイト"));
    if id == 0 { 1 } else { id }
}

/// Windows が字の並びに関わらず装置の名前として読む名前 (拡張子の前がこれなら、どこに置いてもそのファイルにならない)
const RESERVED_NAMES: &[&str] = &[
    "CON",
    "PRN",
    "AUX",
    "NUL",
    "COM0",
    "COM1",
    "COM2",
    "COM3",
    "COM4",
    "COM5",
    "COM6",
    "COM7",
    "COM8",
    "COM9",
    "COM\u{b9}",
    "COM\u{b2}",
    "COM\u{b3}",
    "LPT0",
    "LPT1",
    "LPT2",
    "LPT3",
    "LPT4",
    "LPT5",
    "LPT6",
    "LPT7",
    "LPT8",
    "LPT9",
    "LPT\u{b9}",
    "LPT\u{b2}",
    "LPT\u{b3}",
];

/// 辞書の名前が TSV のファイル名にできるか (google_ime.py の check_dictionary_name に、Windows のファイル名にできない字 (`<>:"|?*` と制御文字) と
/// 装置の名前 (CON・NUL・COM1 など) を足したもの。`:` はドライブからの相対のパスや代替データストリームになり、置き場の外へ書いてしまう)
pub fn check_dictionary_name(name: &str) -> Result<(), TextError> {
    let stem = name
        .split('.')
        .next()
        .unwrap_or_default()
        .trim_end_matches([' ', '.']);
    if name.is_empty()
        || name.starts_with('.')
        || name
            .chars()
            .any(|c| "/\\\t\n\r\0<>:\"|?*".contains(c) || (c as u32) < 0x20)
        || RESERVED_NAMES.iter().any(|r| r.eq_ignore_ascii_case(stem))
    {
        return err(format!(
            "辞書の名前 {} はファイル名にできない (画面で名前を変える)",
            py_repr(name)
        ));
    }
    Ok(())
}

/// 大文字小文字を区別しない比べ方の鍵 (Windows のファイル名は大文字小文字を区別しない)
fn fold(name: &str) -> String {
    name.to_lowercase()
}

/// {辞書の名前: TSV の中身} から UserDictionaryStorage を組み立てる。誤りの文には語 (セルの中身) を出さない
pub fn dictionaries_from_tsv(files: &BTreeMap<String, String>) -> Result<Message, TextError> {
    if files.len() > MAX_DICTIONARIES {
        return err(format!(
            "辞書が {} 個ある (Mozc の上限は {MAX_DICTIONARIES} 個)",
            files.len()
        ));
    }
    let mut storage = Message::new(&pb::STORAGE);
    for (name, text) in files {
        check_dictionary_name(name)?;
        let lines = split_lines(text);
        if lines.len() > MAX_ENTRIES {
            return err(format!(
                "{name}.tsv: 語が {} 個ある (Mozc の上限は {MAX_ENTRIES} 個)",
                lines.len()
            ));
        }
        let mut d = Message::new(&pb::USER_DICTIONARY);
        d.set("id", Value::U64(dictionary_id(name)));
        d.set("name", Value::Bytes(name.as_bytes().to_vec()));
        for (i, line) in lines.iter().enumerate() {
            let n = i + 1;
            let mut fields: Vec<&str> = line.split('\t').collect();
            if fields.len() != 3 && fields.len() != 4 {
                return err(format!(
                    "{name}.tsv:{n}: 列が {} 個ある (「読み<TAB>単語<TAB>品詞<TAB>コメント」の 4 列。コメントが無ければ 3 列でもよい)",
                    fields.len()
                ));
            }
            if fields.len() == 3 {
                fields.push("");
            }
            let empty: Vec<&str> = [("1 列目の読み", fields[0]), ("2 列目の単語", fields[1])]
                .iter()
                .filter(|(_, cell)| cell.is_empty())
                .map(|(label, _)| *label)
                .collect();
            if !empty.is_empty() {
                return err(format!("{name}.tsv:{n}: {}が空", empty.join("と")));
            }
            let Some(pos) = POS_NAMES.iter().position(|p| *p == fields[2]) else {
                return err(format!(
                    "{name}.tsv:{n}: 3 列目の品詞が Mozc に無い (品詞の名前は Mozc の user_pos.def と同じ書き方。辞書ツールのエクスポートと同じ)"
                ));
            };
            let mut e = Message::new(&pb::ENTRY);
            e.set("key", Value::Bytes(fields[0].as_bytes().to_vec()));
            e.set("value", Value::Bytes(fields[1].as_bytes().to_vec()));
            // コメントは空でも必ず入れる (比べる digest は、無いのと同じに扱う)
            e.set("comment", Value::Bytes(fields[3].as_bytes().to_vec()));
            e.set("pos", Value::I32(pos as i32));
            d.push("entries", Value::Msg(e));
        }
        storage.push("dictionaries", Value::Msg(d));
    }
    Ok(storage)
}

/// 読みか単語が空の語か (Mozc は変換に使わない。「無い」と同じに扱う)
fn is_blank_entry(e: &Message) -> bool {
    e.get_bytes("key").is_none_or(<[u8]>::is_empty)
        || e.get_bytes("value").is_none_or(<[u8]>::is_empty)
}

fn msg(v: &Value) -> &Message {
    match v {
        Value::Msg(m) => m,
        _ => unreachable!("メッセージの項目にはメッセージしか入らない"),
    }
}

/// UserDictionaryStorage を {辞書の名前: TSV の中身} にする。読みか単語が空の語は書かない。誤りの文には語を出さない (何番目の語かだけ)
pub fn dictionaries_to_tsv(storage: &Message) -> Result<BTreeMap<String, String>, TextError> {
    if storage.has_unknown() {
        return err(format!(
            "{DICTIONARY_DB} に今の .proto に無い項目がある (新しい版の Google 日本語入力が足した項目)。nix/pkgs/pjp-google-ime/proto/ の写しを新しくする"
        ));
    }
    let mut files = BTreeMap::new();
    for (k, dv) in storage.values("dictionaries").iter().enumerate() {
        let d = msg(dv);
        let Ok(name) = std::str::from_utf8(d.get_bytes("name").unwrap_or_default()) else {
            return err(format!(
                "{} 番目の辞書の名前が UTF-8 ではないので、ファイル名にできない (画面で名前を変える)",
                k + 1
            ));
        };
        check_dictionary_name(name)?;
        if files.contains_key(name) {
            return err(format!(
                "辞書の名前 {} が 2 つある (画面で名前を変える)",
                py_repr(name)
            ));
        }
        // Windows では大文字小文字だけが違う 2 つの TSV は同じファイルになり、片方が消える
        if let Some(other) = files.keys().find(|k: &&String| fold(k) == fold(name)) {
            return err(format!(
                "辞書の名前 {} と {} は大文字小文字だけが違い、Windows では同じファイル名になる (画面で名前を変える)",
                py_repr(other),
                py_repr(name)
            ));
        }
        let mut rows = String::new();
        for (j, ev) in d.values("entries").iter().enumerate() {
            let i = j + 1;
            let e = msg(ev);
            if is_blank_entry(e) {
                continue;
            }
            if !e.get_bytes("locale").unwrap_or_default().is_empty() {
                return err(format!(
                    "辞書 {} の {i} 番目の語に locale が付いていて、TSV に書けない",
                    py_repr(name)
                ));
            }
            let mut cells = Vec::new();
            for field in ["key", "value", "comment"] {
                let Ok(cell) = std::str::from_utf8(e.get_bytes(field).unwrap_or_default()) else {
                    return err(format!(
                        "辞書 {} の {i} 番目の語に UTF-8 でない字があり、TSV に書けない",
                        py_repr(name)
                    ));
                };
                if cell.contains(['\t', '\n', '\r']) {
                    return err(format!(
                        "辞書 {} の {i} 番目の語にタブか改行が入っていて、TSV に書けない",
                        py_repr(name)
                    ));
                }
                cells.push(cell);
            }
            let pos = e.get_i32("pos").unwrap_or(DEFAULT_POS);
            let Some(pos_name) = usize::try_from(pos).ok().and_then(|p| POS_NAMES.get(p)) else {
                return err(format!(
                    "辞書 {} の {i} 番目の語の品詞が Mozc に無い",
                    py_repr(name)
                ));
            };
            rows.push_str(&format!(
                "{}\t{}\t{pos_name}\t{}\n",
                cells[0], cells[1], cells[2]
            ));
        }
        files.insert(name.to_string(), rows);
    }
    Ok(files)
}

/// 比べるための sha256 (辞書の id と辞書の並びを外し、読みか単語が空の語を外し、空のコメントは「無い」にそろえる)。名前が UTF-8 の辞書と
/// そうでない辞書が混ざると出せない (Python の並べ替えが str と bytes を比べて落ちる)
pub fn dictionary_digest(storage: &Message) -> Result<String, TextError> {
    let dicts = storage.values("dictionaries");
    let names: Vec<&[u8]> = dicts
        .iter()
        .map(|d| msg(d).get_bytes("name").unwrap_or_default())
        .collect();
    let valid = names
        .iter()
        .filter(|n| std::str::from_utf8(n).is_ok())
        .count();
    if valid != 0 && valid != names.len() {
        return err("辞書の名前に UTF-8 のものとそうでないものが混ざっていて、比べられない");
    }
    // UTF-8 のバイト列の順は字の順と同じ (Python の str の並べ替え)。並べ替えは安定
    let mut order: Vec<usize> = (0..dicts.len()).collect();
    order.sort_by(|a, b| names[*a].cmp(names[*b]));
    let mut s = storage.clone();
    s.clear("dictionaries");
    for i in order {
        let d = msg(&dicts[i]);
        let mut c = d.clone();
        c.clear("id");
        c.clear("entries");
        for ev in d.values("entries") {
            let e = msg(ev);
            if is_blank_entry(e) {
                continue;
            }
            let mut ce = e.clone();
            if ce.get_bytes("comment").is_none_or(<[u8]>::is_empty) {
                ce.clear("comment");
            }
            c.push("entries", Value::Msg(ce));
        }
        s.push("dictionaries", Value::Msg(c));
    }
    Ok(sha256_hex(&s.encode()))
}

// ------------------------------------------------------------------ ファイル

/// UTF-8 で読み、改行を LF にそろえる (Python の `Path.read_text(encoding="utf-8")`: CRLF も単独の CR も LF にする)
pub fn read_text(path: &Path) -> Result<String, TextError> {
    let bytes = std::fs::read(path)
        .map_err(|e| TextError(format!("{} を読めない ({e})", path.display())))?;
    let text = String::from_utf8(bytes)
        .map_err(|_| TextError(format!("{} が UTF-8 ではない", path.display())))?;
    Ok(text.replace("\r\n", "\n").replace('\r', "\n"))
}

/// `<config-dir>` から (config.txtpb, keymap.tsv か None, romaji.tsv か None) を読む
pub fn read_config_dir(dir: &Path) -> Result<ConfigTexts, TextError> {
    if !dir.join(TXTPB).is_file() {
        return err(format!("{} が無い", dir.join(TXTPB).display()));
    }
    let optional = |name: &str| -> Result<Option<String>, TextError> {
        let p = dir.join(name);
        if p.is_file() {
            read_text(&p).map(Some)
        } else {
            Ok(None)
        }
    };
    let keymap = optional(KEYMAP)?;
    let romaji = optional(ROMAJI)?;
    Ok(ConfigTexts {
        txtpb: read_text(&dir.join(TXTPB))?,
        keymap,
        romaji,
    })
}

/// ディレクトリの `*.tsv` (ファイルだけ。名前の大小文字はそのまま見る) を、名前の順に (辞書の名前, パス) で並べる (Python の
/// `sorted(Path(d).glob("*.tsv"))` の `is_file()`。`.` で始まる名前も拾う)
pub fn tsv_files(dir: &Path) -> Result<Vec<(String, std::path::PathBuf)>, TextError> {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return err(format!("{} を読めない ({e})", dir.display())),
    };
    let mut out = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| TextError(format!("{} を読めない ({e})", dir.display())))?;
        let file_name = entry.file_name();
        let Some(file_name) = file_name.to_str() else {
            return err(format!(
                "{} に、名前を読めないファイルがある",
                dir.display()
            ));
        };
        let Some(name) = file_name.strip_suffix(".tsv") else {
            continue;
        };
        let path = entry.path();
        if path.is_file() {
            out.push((name.to_string(), path));
        }
    }
    out.sort_by(|a, b| a.1.file_name().cmp(&b.1.file_name()));
    Ok(out)
}

/// `<dictionary-dir>` の `*.tsv` を {辞書の名前: 中身} にする
pub fn read_dictionary_dir(dir: &Path) -> Result<BTreeMap<String, String>, TextError> {
    let mut files = BTreeMap::new();
    for (name, path) in tsv_files(dir)? {
        files.insert(name, read_text(&path)?);
    }
    Ok(files)
}

/// バイナリを読む (読めなければ「壊れているか、Google 日本語入力のファイルではない」)
pub fn parse_db(
    desc: &'static pb::MsgDesc,
    bytes: &[u8],
    path: &str,
) -> Result<Message, TextError> {
    pb::decode(desc, bytes).map_err(|_| {
        TextError(format!(
            "{path} を読めない (壊れているか、Google 日本語入力のファイルではない)"
        ))
    })
}

fn read_db(desc: &'static pb::MsgDesc, path: &Path) -> Result<Message, TextError> {
    let bytes = std::fs::read(path)
        .map_err(|e| TextError(format!("{} を読めない ({e})", path.display())))?;
    parse_db(desc, &bytes, &path.display().to_string())
}

/// テキストのファイルへの書き込み 1 つ (取り込みは、読んで全部を決めてから書く)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FileOp {
    Write(PathBuf, String),
    Remove(PathBuf),
    /// 大文字小文字だけが違う名前に替える (Windows では同じファイル)
    Rename(PathBuf, PathBuf),
}

/// 中身が違えば書く (同じかは、読んだ字の改行を LF にそろえて比べる。今のファイルが UTF-8 でなければ止める)
fn plan_write(path: &Path, text: &str, ops: &mut Vec<FileOp>) -> Result<(), TextError> {
    if path.is_file() && read_text(path)? == text {
        return Ok(());
    }
    ops.push(FileOp::Write(path.to_path_buf(), text.to_string()));
    Ok(())
}

/// 設定のテキストを書く計画。無い表のファイルは消す
pub fn plan_config_texts(dir: &Path, texts: &ConfigTexts) -> Result<Vec<FileOp>, TextError> {
    let mut ops = Vec::new();
    plan_write(&dir.join(TXTPB), &texts.txtpb, &mut ops)?;
    for (name, text) in [(KEYMAP, &texts.keymap), (ROMAJI, &texts.romaji)] {
        match text {
            None if dir.join(name).is_file() => ops.push(FileOp::Remove(dir.join(name))),
            None => {}
            Some(t) => plan_write(&dir.join(name), t, &mut ops)?,
        }
    }
    Ok(ops)
}

/// 辞書の TSV を書く計画。無くなった辞書の TSV は消す。今ある TSV が大文字小文字だけ違う名前なら、名前を替えてから比べる (Windows では同じファイルで、
/// 替えずに書くと古い名前のまま残り、続く「無くなった辞書」で消してしまう)
pub fn plan_dictionary_texts(
    dir: &Path,
    files: &BTreeMap<String, String>,
) -> Result<Vec<FileOp>, TextError> {
    let existing = tsv_files(dir)?;
    let mut claimed: Vec<&str> = Vec::new();
    let mut ops = Vec::new();
    for (name, text) in files {
        let target = dir.join(format!("{name}.tsv"));
        if existing.iter().any(|(n, _)| n == name) {
            claimed.push(name);
            plan_write(&target, text, &mut ops)?;
            continue;
        }
        let renamed = existing.iter().find(|(n, _)| {
            fold(n) == fold(name) && !files.contains_key(n) && !claimed.contains(&n.as_str())
        });
        match renamed {
            Some((n, path)) => {
                claimed.push(n);
                ops.push(FileOp::Rename(path.clone(), target.clone()));
                if read_text(path)? != *text {
                    ops.push(FileOp::Write(target, text.clone()));
                }
            }
            None => ops.push(FileOp::Write(target, text.clone())),
        }
    }
    for (n, path) in &existing {
        if !files.contains_key(n) && !claimed.contains(&n.as_str()) {
            ops.push(FileOp::Remove(path.clone()));
        }
    }
    Ok(ops)
}

/// 計画どおりに書く。書いた・消した・名前を替えたファイルの行を返す。途中で書けなければ、それまでの行と誤りを返す
pub fn apply_ops(ops: &[FileOp]) -> Result<Vec<String>, (Vec<String>, TextError)> {
    let mut lines = Vec::new();
    for op in ops {
        let r = match op {
            FileOp::Write(p, text) => crate::fsutil::write_atomic(p, text.as_bytes())
                .map(|()| format!("書いた: {}", p.display()))
                .map_err(|e| format!("{} に書けない ({e})", p.display())),
            FileOp::Remove(p) => std::fs::remove_file(p)
                .map(|()| format!("消した: {}", p.display()))
                .map_err(|e| format!("{} を消せない ({e})", p.display())),
            FileOp::Rename(a, b) => std::fs::rename(a, b)
                .map(|()| format!("名前を替えた: {} → {}", a.display(), b.display()))
                .map_err(|e| format!("{} の名前を替えられない ({e})", a.display())),
        };
        match r {
            Ok(l) => lines.push(l),
            Err(e) => return Err((lines, TextError(e))),
        }
    }
    Ok(lines)
}

// ------------------------------------------------------------------ 組み立てと検証

/// `<config-dir>` から Config を組み立て、読み直しても同じ中身に戻ることを確かめる
pub fn build_config(dir: &Path) -> Result<Message, TextError> {
    let t = read_config_dir(dir)?;
    let cfg = config_from_text(&t.txtpb, t.keymap.as_deref(), t.romaji.as_deref())?;
    let back = config_to_text(&parse_db(&pb::CONFIG, &cfg.encode(), TXTPB)?)?;
    let again = config_from_text(&back.txtpb, back.keymap.as_deref(), back.romaji.as_deref())?;
    if again.encode() != cfg.encode() {
        return err(format!(
            "{}: 組み立てたものを読み直すと中身が変わる",
            dir.display()
        ));
    }
    Ok(cfg)
}

/// `<dictionary-dir>` から UserDictionaryStorage を組み立て、読み直しても同じ中身に戻ることを確かめる
pub fn build_dictionaries(dir: &Path) -> Result<Message, TextError> {
    let storage = dictionaries_from_tsv(&read_dictionary_dir(dir)?)?;
    let again = dictionaries_from_tsv(&dictionaries_to_tsv(&parse_db(
        &pb::STORAGE,
        &storage.encode(),
        DICTIONARY_DB,
    )?)?)?;
    if again.encode() != storage.encode() {
        return err(format!(
            "{}: 組み立てたものを読み直すと中身が変わる",
            dir.display()
        ));
    }
    Ok(storage)
}

/// 組み立てたもの (pjp-google-ime build の 2 つのファイルのバイト列。辞書は辞書のディレクトリを渡したときだけ)
pub struct Built {
    pub config: Vec<u8>,
    pub dictionary: Option<Vec<u8>>,
}

/// テキストから組み立てる (pjp-google-ime build。設定を先に、辞書を後に確かめる)
pub fn build(config_dir: &Path, dictionary_dir: Option<&Path>) -> Result<Built, TextError> {
    let cfg = build_config(config_dir)?;
    let dictionary = match dictionary_dir {
        Some(d) => Some(build_dictionaries(d)?.encode()),
        None => None,
    };
    Ok(Built {
        config: cfg.encode(),
        dictionary,
    })
}

/// ファイルの種類 (pjp-google-ime の --kind)。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Db {
    Config,
    Dictionary,
}

impl Db {
    pub fn file_name(self) -> &'static str {
        match self {
            Db::Config => CONFIG_DB,
            Db::Dictionary => DICTIONARY_DB,
        }
    }
}

/// バイト列の digest (pjp-google-ime digest)
pub fn digest(kind: Db, bytes: &[u8], path: &str) -> Result<String, TextError> {
    match kind {
        Db::Config => Ok(config_digest(&parse_db(&pb::CONFIG, bytes, path)?)),
        Db::Dictionary => dictionary_digest(&parse_db(&pb::STORAGE, bytes, path)?),
    }
}

/// バイナリをテキストに戻したもの (pjp-google-ime decode)。
pub enum Decoded {
    Config(ConfigTexts),
    Dictionaries(BTreeMap<String, String>),
}

pub fn decode(kind: Db, bytes: &[u8], path: &str) -> Result<Decoded, TextError> {
    match kind {
        Db::Config => Ok(Decoded::Config(config_to_text(&parse_db(
            &pb::CONFIG,
            bytes,
            path,
        )?)?)),
        Db::Dictionary => Ok(Decoded::Dictionaries(dictionaries_to_tsv(&parse_db(
            &pb::STORAGE,
            bytes,
            path,
        )?)?)),
    }
}

/// 取り込みの結果 (pjp-google-ime import の出力。試験で pjp-google-ime と比べる)。
#[cfg(test)]
#[derive(Debug)]
pub struct Imported {
    /// 書いた・消したファイルの行 (無ければ「テキストは今のままで同じです。」)
    pub lines: Vec<String>,
    /// 辞書を取り込まなかったわけ (Windows 側に user_dictionary.db が無い)
    pub notice: Option<String>,
}

/// 取り込みの計画: Windows 側の 2 つのファイルを読んでテキストに戻し、書くものを決めたもの (まだ何も書いていない)。
#[derive(Debug)]
pub struct ImportPlan {
    /// テキストへ書く・消す・名前を替えるもの (設定が先、辞書が後)
    pub ops: Vec<FileOp>,
    pub notice: Option<String>,
    /// 読んだ config1.db の digest (記録する。読み直さないので、取り込みの間に画面で保存されても、テキストと記録が食い違わない)
    pub config_digest: String,
    /// 読んだ user_dictionary.db の digest (辞書を取り込んだときだけ)
    pub dictionary_digest: Option<String>,
}

/// Windows 側のファイルを読み、テキストを書き直す計画を作る (pjp-google-ime import の確かめの全部。何も書かない)
pub fn plan_import(
    windows_dir: &Path,
    config_dir: &Path,
    dictionary_dir: Option<&Path>,
) -> Result<ImportPlan, TextError> {
    let config_path = windows_dir.join(CONFIG_DB);
    if !config_path.is_file() {
        return err(format!("{} が無い", config_path.display()));
    }
    let cfg = read_db(&pb::CONFIG, &config_path)?;
    let texts = config_to_text(&cfg)?;
    let again = config_from_text(
        &texts.txtpb,
        texts.keymap.as_deref(),
        texts.romaji.as_deref(),
    )?;
    if config_digest(&again) != config_digest(&cfg) {
        return err(format!(
            "{CONFIG_DB} をテキストに戻すと中身が変わる (テキストで表せない項目がある)"
        ));
    }
    let mut files = None;
    let mut notice = None;
    let mut dict_digest = None;
    let dict_path = windows_dir.join(DICTIONARY_DB);
    if dictionary_dir.is_some() {
        if dict_path.is_file() {
            let storage = read_db(&pb::STORAGE, &dict_path)?;
            let tsv = dictionaries_to_tsv(&storage)?;
            let have = dictionary_digest(&storage)?;
            if dictionary_digest(&dictionaries_from_tsv(&tsv)?)? != have {
                return err(format!(
                    "{DICTIONARY_DB} をテキストに戻すと中身が変わる (TSV で表せない項目がある)"
                ));
            }
            files = Some(tsv);
            dict_digest = Some(have);
        } else {
            // ファイルが無いのは、まだ辞書を作っていないか置き場所が違うかで、辞書を全部消したのとは違う。TSV は消さずに残す
            notice = Some(format!(
                "{} が無いので、辞書は取り込みません (TSV はそのまま)",
                dict_path.display()
            ));
        }
    }
    let mut ops = plan_config_texts(config_dir, &texts)?;
    if let (Some(files), Some(d)) = (&files, dictionary_dir) {
        ops.extend(plan_dictionary_texts(d, files)?);
    }
    Ok(ImportPlan {
        ops,
        notice,
        config_digest: config_digest(&cfg),
        dictionary_digest: dict_digest,
    })
}

/// Windows 側のファイルを読み、テキストを書き直す (pjp-google-ime import)。確かめが全部通ってから書く (確かめで止まれば、何も書かない)
#[cfg(test)]
pub fn import(
    windows_dir: &Path,
    config_dir: &Path,
    dictionary_dir: Option<&Path>,
) -> Result<Imported, TextError> {
    let plan = plan_import(windows_dir, config_dir, dictionary_dir)?;
    let mut lines = apply_ops(&plan.ops).map_err(|(_, e)| e)?;
    if lines.is_empty() {
        lines.push("テキストは今のままで同じです。".to_string());
    }
    Ok(Imported {
        lines,
        notice: plan.notice,
    })
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (nix/pkgs/pjp-google-ime/test_google_ime.py のケースを写したもの。値は pjp-google-ime と突き合わせる試験 (mod.rs の
    //! parity) でも比べる)
    //!
    //! - 品詞の名前が .proto のコメントと同じ並び
    //! - 設定: テキストとバイナリを行き来して戻る・同じテキストから同じバイト列・general_config を書かない・CRLF と末尾の改行の有無で同じ
    //!   バイト列・テキストに general_config か表を書いたら止める・読めないテキストはファイルと行を出す・CUSTOM なのに keymap.tsv が無い
    //! - キー設定・ローマ字テーブルの確かめ (見出し・列・状態名・空)
    //! - digest: general_config と空の表と無い verbose_level を外す・設定の違いは見る
    //! - 知らない項目のある設定は取り込まない
    //! - 辞書: 行き来して戻る・id は名前から・名前の順・コメントは必ず入れる・3 列はコメントが空・品詞・列・名前の誤り・タブを含む語は書けない・
    //!   digest は id と並びと空のコメントと空の語を外す・語とコメントの違いは見る・空の語は TSV に書かない
    //! - 辞書の誤りの文に語を出さない
    //! - 取り込み: Windows 側を写す・2 度目は「同じ」・知らない項目や書けない名前では何も書かない・単語登録の形 (コメントの無い語) も取り込める・
    //!   空の語は書かない・辞書のファイルが無ければ TSV に触らない

    use super::*;
    use crate::testutil::TempDir;

    const TXTPB_MIN: &str = "session_keymap: CUSTOM\npunctuation_method: TOUTEN_KUTEN\n";
    const KEYMAP_MIN: &str =
        "status\tkey\tcommand\nDirectInput\tF13\tIMEOn\nPrecomposition\tF13\tIMEOff\n";

    fn cfg(txtpb: &str, keymap: Option<&str>, romaji: Option<&str>) -> Message {
        config_from_text(txtpb, keymap, romaji).unwrap()
    }

    fn files(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn pos_names_match_proto_comments() {
        let proto = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../nix/pkgs/pjp-google-ime/proto/user_dictionary_storage.proto"),
        )
        .unwrap();
        // `NOUN = 1;  // "名詞"` の形の行から、番号と名前を拾う
        let mut found: Vec<(usize, String)> = Vec::new();
        for line in proto.lines() {
            let Some((decl, comment)) = line.split_once("//") else {
                continue;
            };
            let Some((_, num)) = decl.split_once('=') else {
                continue;
            };
            let Ok(n) = num.trim().trim_end_matches(';').trim().parse::<usize>() else {
                continue;
            };
            let c = comment.trim();
            if c.starts_with('"') && c.ends_with('"') && c.len() > 2 {
                found.push((n, c[1..c.len() - 1].to_string()));
            }
        }
        assert_eq!(found.len(), POS_NAMES.len());
        for (n, name) in found {
            assert_eq!(POS_NAMES[n], name);
        }
    }

    #[test]
    fn config_roundtrip_and_determinism() {
        let c = cfg(TXTPB_MIN, Some(KEYMAP_MIN), None);
        let t = config_to_text(&c).unwrap();
        assert!(t.txtpb.starts_with(TXTPB_HEADER));
        assert_eq!(t.keymap.as_deref(), Some(KEYMAP_MIN));
        assert_eq!(t.romaji, None);
        let again = config_from_text(&t.txtpb, t.keymap.as_deref(), None).unwrap();
        assert_eq!(again.encode(), c.encode());
        assert_eq!(c.encode(), cfg(TXTPB_MIN, Some(KEYMAP_MIN), None).encode());
        assert!(!c.has("general_config"));
        // CRLF と末尾の改行の有無で同じバイト列
        let crlf = KEYMAP_MIN.replace('\n', "\r\n");
        assert_eq!(cfg(TXTPB_MIN, Some(&crlf), None).encode(), c.encode());
        assert_eq!(
            cfg(TXTPB_MIN, Some(KEYMAP_MIN.trim_end_matches('\n')), None).encode(),
            c.encode()
        );
    }

    #[test]
    fn config_text_errors() {
        let e = config_from_text(
            &format!("{TXTPB_MIN}general_config {{ config_version: 1 }}\n"),
            Some(KEYMAP_MIN),
            None,
        )
        .unwrap_err();
        assert!(e.0.contains("general_config"), "{e}");
        let e = config_from_text(
            &format!("{TXTPB_MIN}custom_keymap_table: \"x\"\n"),
            Some(KEYMAP_MIN),
            None,
        )
        .unwrap_err();
        assert!(e.0.contains(KEYMAP), "{e}");
        let e = config_from_text("session_keymap: NOPE\n", Some(KEYMAP_MIN), None).unwrap_err();
        assert!(e.0.starts_with("config.txtpb:1:"), "{e}");
        let e = config_from_text(TXTPB_MIN, None, None).unwrap_err();
        assert!(e.0.contains("CUSTOM"), "{e}");
    }

    #[test]
    fn keymap_and_romaji_checks() {
        assert!(
            check_keymap("DirectInput\tF13\tIMEOn\n")
                .unwrap_err()
                .0
                .contains(":1:")
        );
        assert!(
            check_keymap("status\tkey\tcommand\nDirectInput\tF13\n")
                .unwrap_err()
                .0
                .contains("keymap.tsv:2:")
        );
        assert!(
            check_keymap("status\tkey\tcommand\nDirect input\tF13\tIMEOn\n")
                .unwrap_err()
                .0
                .contains("keymap.tsv:2:")
        );
        assert!(
            check_keymap("status\tkey\tcommand\n")
                .unwrap_err()
                .0
                .contains("1 つも無い")
        );
        // コマンド名は確かめない
        assert!(check_keymap("status\tkey\tcommand\nComposition\tF13\tNoSuchCommandYet\n").is_ok());
        assert!(check_romaji("a\tb\n").is_ok());
        assert!(check_romaji("a\tb\tc\n").is_ok());
        assert!(check_romaji("a\n").is_err());
        assert!(check_romaji("a\tb\tc\td\n").is_err());
        assert!(check_romaji("a\t\t\n").is_err());
        assert!(check_romaji("a\t\tc\n").is_ok());
        assert!(check_romaji("").is_err());
    }

    #[test]
    fn config_digest_ignores_general_config_empty_tables_and_missing_verbose_level() {
        let c = cfg(TXTPB_MIN, Some(KEYMAP_MIN), None);
        let mut g = c.clone();
        let mut gc = Message::new(&pb::GENERAL_CONFIG);
        gc.set("last_modified_time", Value::U64(123));
        g.set("general_config", Value::Msg(gc));
        assert_eq!(config_digest(&g), config_digest(&c));
        let mut e = c.clone();
        e.set("custom_roman_table", Value::Bytes(Vec::new()));
        assert_eq!(config_digest(&e), config_digest(&c));
        let mut v = c.clone();
        v.clear("verbose_level");
        assert_eq!(config_digest(&v), config_digest(&c));
        v.set("verbose_level", Value::I32(1));
        assert_ne!(config_digest(&v), config_digest(&c));
        let other = cfg(
            "session_keymap: CUSTOM\npunctuation_method: COMMA_PERIOD\n",
            Some(KEYMAP_MIN),
            None,
        );
        assert_ne!(config_digest(&other), config_digest(&c));
        // 空の表は「無い」としてテキストにする
        let t = config_to_text(&e).unwrap();
        assert_eq!(t.romaji, None);
    }

    #[test]
    fn unknown_fields_are_refused_by_to_text() {
        let mut bytes = cfg(TXTPB_MIN, Some(KEYMAP_MIN), None).encode();
        bytes.extend([0xf8, 0x07, 0x01]);
        let c = pb::decode(&pb::CONFIG, &bytes).unwrap();
        assert!(config_to_text(&c).unwrap_err().0.contains(".proto"));
    }

    #[test]
    fn dictionaries_roundtrip_ids_and_comments() {
        let f = files(&[
            ("b", "よみ\tたんご\t名詞\tこめんと\n"),
            ("a", "あ\tア\t固有名詞\n"),
        ]);
        let s = dictionaries_from_tsv(&f).unwrap();
        let names: Vec<String> = s
            .values("dictionaries")
            .iter()
            .map(|d| String::from_utf8(msg(d).get_bytes("name").unwrap().to_vec()).unwrap())
            .collect();
        assert_eq!(names, vec!["a", "b"]);
        let a = msg(&s.values("dictionaries")[0]);
        assert_eq!(a.get("id"), Some(&Value::U64(dictionary_id("a"))));
        // 3 列はコメントが空で、コメントは必ず入る
        let e = msg(&a.values("entries")[0]);
        assert_eq!(e.get_bytes("comment"), Some(&b""[..]));
        assert_eq!(e.get_i32("pos"), Some(4));
        let back = dictionaries_to_tsv(&s).unwrap();
        assert_eq!(back.get("a").unwrap(), "あ\tア\t固有名詞\t\n");
        assert_eq!(back.get("b").unwrap(), "よみ\tたんご\t名詞\tこめんと\n");
        assert_eq!(dictionaries_from_tsv(&back).unwrap().encode(), s.encode());
        // 名前の sha256 の先頭 8 バイト (big endian)
        assert_eq!(dictionary_id("テスト辞書"), {
            let d = Sha256::digest("テスト辞書".as_bytes());
            u64::from_be_bytes(d[..8].try_into().unwrap())
        });
    }

    #[test]
    fn dictionary_errors_do_not_show_words() {
        let secret = "ひみつのよみ";
        for (text, want) in [
            (format!("{secret}\n"), "列が 1 個"),
            (format!("{secret}\t{secret}\t名詞\tx\ty\n"), "列が 5 個"),
            (format!("\t{secret}\t名詞\n"), "1 列目の読みが空"),
            (format!("{secret}\t\t名詞\n"), "2 列目の単語が空"),
            ("\t\t名詞\n".to_string(), "1 列目の読みと2 列目の単語が空"),
            (
                format!("{secret}\t{secret}\t{secret}\n"),
                "品詞が Mozc に無い",
            ),
        ] {
            let e = dictionaries_from_tsv(&files(&[("d", &text)])).unwrap_err();
            assert!(e.0.contains(want) && e.0.starts_with("d.tsv:1:"), "{e}");
            assert!(!e.0.contains(secret), "語が出た: {e}");
        }
        for bad in ["", ".x", "a/b", "a\\b", "a\tb"] {
            assert!(
                dictionaries_from_tsv(&files(&[(bad, "")])).is_err(),
                "{bad:?}"
            );
        }
        // TSV に書けない語 (タブ・改行・locale) も語を出さない
        let mut s = dictionaries_from_tsv(&files(&[("d", "あ\tア\t名詞\n")])).unwrap();
        let mut d = msg(&s.values("dictionaries")[0]).clone();
        let mut e = Message::new(&pb::ENTRY);
        e.set("key", Value::Bytes(format!("{secret}\t").into_bytes()));
        e.set("value", Value::Bytes(b"v".to_vec()));
        d.push("entries", Value::Msg(e));
        s.clear("dictionaries");
        s.push("dictionaries", Value::Msg(d.clone()));
        let err = dictionaries_to_tsv(&s).unwrap_err();
        assert!(
            err.0.contains("2 番目の語にタブか改行") && !err.0.contains(secret),
            "{err}"
        );
        let mut e = Message::new(&pb::ENTRY);
        e.set("key", Value::Bytes(b"k".to_vec()));
        e.set("value", Value::Bytes(b"v".to_vec()));
        e.set("locale", Value::Bytes(b"ja".to_vec()));
        let mut d2 = msg(&dictionaries_from_tsv(&files(&[("d", "")]))
            .unwrap()
            .values("dictionaries")[0])
        .clone();
        d2.push("entries", Value::Msg(e));
        let mut s2 = Message::new(&pb::STORAGE);
        s2.push("dictionaries", Value::Msg(d2));
        assert!(dictionaries_to_tsv(&s2).unwrap_err().0.contains("locale"));
    }

    #[test]
    fn dictionary_digest_ignores_id_order_blank_and_empty_comment() {
        let s = dictionaries_from_tsv(&files(&[
            ("a", "あ\tア\t名詞\n"),
            ("b", "い\tイ\t名詞\tc\n"),
        ]))
        .unwrap();
        let base = dictionary_digest(&s).unwrap();
        // id を替え、並びを逆にし、空のコメントを外し、空の語を足す
        let mut t = Message::new(&pb::STORAGE);
        for dv in s.values("dictionaries").iter().rev() {
            let mut d = msg(dv).clone();
            d.set("id", Value::U64(42));
            let entries: Vec<Value> = d.values("entries").to_vec();
            d.clear("entries");
            for ev in entries {
                let mut e = msg(&ev).clone();
                if e.get_bytes("comment") == Some(b"") {
                    e.clear("comment");
                }
                d.push("entries", Value::Msg(e));
            }
            let mut blank = Message::new(&pb::ENTRY);
            blank.set("pos", Value::I32(1));
            d.push("entries", Value::Msg(blank));
            t.push("dictionaries", Value::Msg(d));
        }
        assert_eq!(dictionary_digest(&t).unwrap(), base);
        // 空の語は TSV に書かない
        assert_eq!(
            dictionaries_to_tsv(&t).unwrap().get("a").unwrap(),
            "あ\tア\t名詞\t\n"
        );
        // 語・コメントの違いは見る
        let w = dictionaries_from_tsv(&files(&[
            ("a", "あ\tア\t名詞\n"),
            ("b", "い\tイ\t名詞\td\n"),
        ]))
        .unwrap();
        assert_ne!(dictionary_digest(&w).unwrap(), base);
    }

    #[test]
    fn dictionary_digest_refuses_mixed_name_types() {
        let mut s = dictionaries_from_tsv(&files(&[("a", ""), ("b", "")])).unwrap();
        let mut d = msg(&s.values("dictionaries")[1]).clone();
        d.set("name", Value::Bytes(vec![0xff]));
        let first = s.values("dictionaries")[0].clone();
        s.clear("dictionaries");
        s.push("dictionaries", first);
        s.push("dictionaries", Value::Msg(d.clone()));
        assert!(dictionary_digest(&s).is_err());
        // 1 つだけなら比べない (並べ替えで落ちない)
        let mut one = Message::new(&pb::STORAGE);
        one.push("dictionaries", Value::Msg(d));
        assert!(dictionary_digest(&one).is_ok());
        assert!(dictionaries_to_tsv(&one).is_err());
    }

    #[test]
    fn read_text_normalizes_newlines_like_python() {
        let t = TempDir::new("ime-read-text");
        let p = t.path().join("a.tsv");
        std::fs::write(&p, b"a\r\nb\rc\n").unwrap();
        assert_eq!(read_text(&p).unwrap(), "a\nb\nc\n");
        std::fs::write(&p, b"\xff").unwrap();
        assert!(read_text(&p).unwrap_err().0.contains("UTF-8"));
    }

    #[test]
    fn tsv_files_like_pathlib_glob() {
        let t = TempDir::new("ime-glob");
        for n in [
            ".hidden.tsv",
            ".tsv",
            "Z.tsv",
            "a.tsv",
            "B.TSV",
            "c.tsv.bak",
            "あ.tsv",
        ] {
            std::fs::write(t.path().join(n), "").unwrap();
        }
        std::fs::create_dir(t.path().join("sub.tsv")).unwrap();
        let names: Vec<String> = tsv_files(t.path())
            .unwrap()
            .into_iter()
            .map(|x| x.0)
            .collect();
        assert_eq!(names, vec![".hidden", "", "Z", "a", "あ"]);
        // . で始まる名前と空の名前は辞書の名前にできない
        assert!(build_dictionaries(t.path()).is_err());
    }

    /// Windows 側のディレクトリと、取り込むテキストのディレクトリを作る
    fn import_dirs(t: &TempDir) -> (std::path::PathBuf, std::path::PathBuf, std::path::PathBuf) {
        let win = t.path().join("win");
        let conf = t.path().join("conf");
        let dict = t.path().join("dict");
        for d in [&win, &conf, &dict] {
            std::fs::create_dir_all(d).unwrap();
        }
        (win, conf, dict)
    }

    #[test]
    fn import_mirrors_windows_and_reports_no_change_the_second_time() {
        let t = TempDir::new("ime-import");
        let (win, conf, dict) = import_dirs(&t);
        let c = cfg(TXTPB_MIN, Some(KEYMAP_MIN), None);
        std::fs::write(win.join(CONFIG_DB), c.encode()).unwrap();
        let s =
            dictionaries_from_tsv(&files(&[("テスト辞書", "てすと\tテスト\t名詞\t\n")])).unwrap();
        std::fs::write(win.join(DICTIONARY_DB), s.encode()).unwrap();
        std::fs::write(conf.join(ROMAJI), "x\ty\n").unwrap();
        std::fs::write(dict.join("消えた辞書.tsv"), "").unwrap();
        let r = import(&win, &conf, Some(&dict)).unwrap();
        assert_eq!(r.notice, None);
        assert!(
            r.lines
                .iter()
                .any(|l| l.starts_with("消した: ") && l.ends_with("romaji.tsv")),
            "{:?}",
            r.lines
        );
        assert!(
            r.lines
                .iter()
                .any(|l| l.starts_with("消した: ") && l.ends_with("消えた辞書.tsv"))
        );
        assert!(
            r.lines
                .iter()
                .any(|l| l.starts_with("書いた: ") && l.ends_with("テスト辞書.tsv"))
        );
        assert_eq!(
            std::fs::read_to_string(conf.join(KEYMAP)).unwrap(),
            KEYMAP_MIN
        );
        let r = import(&win, &conf, Some(&dict)).unwrap();
        assert_eq!(r.lines, vec!["テキストは今のままで同じです。"]);
        // 組み立て直すと Windows 側と同じ digest
        let built = build(&conf, Some(&dict)).unwrap();
        assert_eq!(
            digest(Db::Config, &built.config, "x").unwrap(),
            config_digest(&c)
        );
        assert_eq!(
            digest(Db::Dictionary, built.dictionary.as_ref().unwrap(), "x").unwrap(),
            dictionary_digest(&s).unwrap()
        );
    }

    #[test]
    fn import_refuses_without_writing() {
        let t = TempDir::new("ime-import-refuse");
        let (win, conf, dict) = import_dirs(&t);
        // 知らない項目
        let mut bytes = cfg(TXTPB_MIN, Some(KEYMAP_MIN), None).encode();
        bytes.extend([0xf8, 0x07, 0x01]);
        std::fs::write(win.join(CONFIG_DB), &bytes).unwrap();
        assert!(import(&win, &conf, Some(&dict)).is_err());
        assert!(!conf.join(TXTPB).exists());
        // 書けない辞書の名前: 設定のテキストも書かない
        std::fs::write(
            win.join(CONFIG_DB),
            cfg(TXTPB_MIN, Some(KEYMAP_MIN), None).encode(),
        )
        .unwrap();
        let mut s = Message::new(&pb::STORAGE);
        let mut d = Message::new(&pb::USER_DICTIONARY);
        d.set("name", Value::Bytes(b"a/b".to_vec()));
        s.push("dictionaries", Value::Msg(d));
        std::fs::write(win.join(DICTIONARY_DB), s.encode()).unwrap();
        assert!(import(&win, &conf, Some(&dict)).is_err());
        assert!(!conf.join(TXTPB).exists());
        // Windows 側に辞書が無い: 辞書は取り込まず (TSV はそのまま)、設定だけ取り込む
        std::fs::remove_file(win.join(DICTIONARY_DB)).unwrap();
        std::fs::write(dict.join("のこす.tsv"), "あ\tア\t名詞\t\n").unwrap();
        let r = import(&win, &conf, Some(&dict)).unwrap();
        assert!(r.notice.unwrap().contains("取り込みません"));
        assert!(dict.join("のこす.tsv").exists() && conf.join(TXTPB).exists());
        // config1.db が無い
        std::fs::remove_file(win.join(CONFIG_DB)).unwrap();
        assert!(
            import(&win, &conf, Some(&dict))
                .unwrap_err()
                .0
                .contains("無い")
        );
    }

    #[test]
    fn import_word_registered_and_blank_entries() {
        let t = TempDir::new("ime-import-wordreg");
        let (win, conf, dict) = import_dirs(&t);
        std::fs::write(
            win.join(CONFIG_DB),
            cfg(TXTPB_MIN, Some(KEYMAP_MIN), None).encode(),
        )
        .unwrap();
        // 単語登録の形 (comment の無い語) と、読みも単語も空の語
        let mut d = Message::new(&pb::USER_DICTIONARY);
        d.set("id", Value::U64(11_262_860_659_733_797_146));
        d.set("name", Value::Bytes("テスト辞書".as_bytes().to_vec()));
        let mut e = Message::new(&pb::ENTRY);
        e.set("key", Value::Bytes("かくうのよみ".as_bytes().to_vec()));
        e.set("value", Value::Bytes("架空の単語".as_bytes().to_vec()));
        e.set("pos", Value::I32(1));
        d.push("entries", Value::Msg(e));
        let mut blank = Message::new(&pb::ENTRY);
        blank.set("pos", Value::I32(1));
        d.push("entries", Value::Msg(blank));
        let mut s = Message::new(&pb::STORAGE);
        s.push("dictionaries", Value::Msg(d));
        std::fs::write(win.join(DICTIONARY_DB), s.encode()).unwrap();
        import(&win, &conf, Some(&dict)).unwrap();
        assert_eq!(
            std::fs::read_to_string(dict.join("テスト辞書.tsv")).unwrap(),
            "かくうのよみ\t架空の単語\t名詞\t\n"
        );
        let built = build(&conf, Some(&dict)).unwrap();
        assert_eq!(
            digest(Db::Dictionary, built.dictionary.as_ref().unwrap(), "x").unwrap(),
            dictionary_digest(&s).unwrap()
        );
    }

    #[test]
    fn dictionary_names_must_be_windows_file_names() {
        for bad in [
            "C:foo",
            "a:b",
            "a<b",
            "a>b",
            "a\"b",
            "a|b",
            "a?b",
            "a*b",
            "a\u{1}b",
            "CON",
            "con",
            "nul.x",
            "Com1",
            "LPT\u{b9}",
            "CON ",
            "aux.",
            "",
        ] {
            assert!(check_dictionary_name(bad).is_err(), "{bad:?}");
        }
        for ok in [
            "a b",
            "テスト辞書",
            "😀",
            "CONSOLE",
            "x.con",
            "COM10",
            "名前.v2",
        ] {
            assert!(check_dictionary_name(ok).is_ok(), "{ok:?}");
        }
        // Windows では大文字小文字だけが違う 2 つの辞書は同じファイルになる: テキストにしない
        let mut s = Message::new(&pb::STORAGE);
        for n in ["Foo", "foo"] {
            let mut d = Message::new(&pb::USER_DICTIONARY);
            d.set("name", Value::Bytes(n.as_bytes().to_vec()));
            s.push("dictionaries", Value::Msg(d));
        }
        let e = dictionaries_to_tsv(&s).unwrap_err();
        assert!(e.0.contains("大文字小文字だけが違い"), "{e}");
    }

    /// 画面で辞書の名前の大文字小文字だけを替えた: TSV の名前を替える (Windows では同じファイルなので、書かずに消すと辞書が消える)
    #[test]
    fn import_renames_tsv_whose_name_differs_only_in_case() {
        let t = TempDir::new("ime-import-case");
        let (win, conf, dict) = import_dirs(&t);
        std::fs::write(
            win.join(CONFIG_DB),
            cfg(TXTPB_MIN, Some(KEYMAP_MIN), None).encode(),
        )
        .unwrap();
        let tsv = "あ\tア\t名詞\t\n";
        std::fs::write(dict.join("Tech.tsv"), tsv).unwrap();
        std::fs::write(dict.join("Other.tsv"), "い\tイ\t名詞\t\n").unwrap();
        let s =
            dictionaries_from_tsv(&files(&[("tech", tsv), ("other", "う\tウ\t名詞\t\n")])).unwrap();
        std::fs::write(win.join(DICTIONARY_DB), s.encode()).unwrap();
        let r = import(&win, &conf, Some(&dict)).unwrap();
        assert!(
            r.lines
                .iter()
                .any(|l| l.starts_with("名前を替えた: ") && l.ends_with("tech.tsv")),
            "{:?}",
            r.lines
        );
        let mut names: Vec<String> = std::fs::read_dir(&dict)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, vec!["other.tsv", "tech.tsv"]);
        assert_eq!(std::fs::read_to_string(dict.join("tech.tsv")).unwrap(), tsv);
        assert_eq!(
            std::fs::read_to_string(dict.join("other.tsv")).unwrap(),
            "う\tウ\t名詞\t\n"
        );
        // 組み立て直すと Windows 側と同じ
        let built = build(&conf, Some(&dict)).unwrap();
        assert_eq!(
            digest(Db::Dictionary, built.dictionary.as_ref().unwrap(), "x").unwrap(),
            dictionary_digest(&s).unwrap()
        );
    }

    /// 書き直す前のテキストが読めない (UTF-8 でない) なら、何も書かずに止まる (確かめてから書く)
    #[test]
    fn import_checks_everything_before_writing() {
        let t = TempDir::new("ime-import-plan");
        let (win, conf, dict) = import_dirs(&t);
        let gui_keymap = "status\tkey\tcommand\nDirectInput\tF13\tIMEOn\n";
        std::fs::write(
            win.join(CONFIG_DB),
            cfg(TXTPB_MIN, Some(gui_keymap), None).encode(),
        )
        .unwrap();
        let s = dictionaries_from_tsv(&files(&[("d", "あ\tア\t名詞\t\n")])).unwrap();
        std::fs::write(win.join(DICTIONARY_DB), s.encode()).unwrap();
        std::fs::write(conf.join(TXTPB), TXTPB_MIN).unwrap();
        std::fs::write(conf.join(KEYMAP), KEYMAP_MIN).unwrap();
        std::fs::write(dict.join("d.tsv"), [0xff, 0xfe]).unwrap();
        let e = import(&win, &conf, Some(&dict)).unwrap_err();
        assert!(e.0.contains("UTF-8"), "{e}");
        assert_eq!(
            std::fs::read_to_string(conf.join(KEYMAP)).unwrap(),
            KEYMAP_MIN
        );
        assert_eq!(
            std::fs::read_to_string(conf.join(TXTPB)).unwrap(),
            TXTPB_MIN
        );
    }

    #[test]
    fn the_repo_texts_build() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../win/google-japanese-input");
        let c = build_config(&dir).unwrap();
        assert!(c.has("custom_keymap_table") && !c.has("general_config"));
        // repo の config.txtpb は取り込みが書く形のまま (読み直して書くと同じ字)
        let t = config_to_text(&c).unwrap();
        assert_eq!(
            t.txtpb.replace("\r\n", "\n"),
            read_text(&dir.join(TXTPB)).unwrap()
        );
    }
}
