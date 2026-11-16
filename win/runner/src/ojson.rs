//! 順を保つ JSON の値 (Claude Code の `settings.json` の部分書き換え)。
//!
//! serde_json の `Value` は object を BTreeMap に持ち、書き戻すとキーを並べ替える。ユーザーが手で足したキーとその順を残すため、object を
//! 出てきた順の `Vec` で持つ。読み書きは serde (serde_json の Deserializer・Serializer) に任せる。serde_json の preserve_order は foldhash を
//! 引き、`Map` の並びを crate 全体で変えるので使わない (dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_*)。

use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde::ser::{Serialize, SerializeMap, SerializeSeq, Serializer};
use std::fmt;

/// 順を保つ JSON の値。object はキーの出てきた順。
#[derive(Clone, Debug, PartialEq)]
pub enum OValue {
    Null,
    Bool(bool),
    Number(serde_json::Number),
    String(String),
    Array(Vec<OValue>),
    Object(Vec<(String, OValue)>),
}

impl OValue {
    /// JSON の文を読む (頭の BOM は読み飛ばす)。
    pub fn parse(text: &str) -> Result<OValue, String> {
        serde_json::from_str(text.trim_start_matches('\u{feff}')).map_err(|e| e.to_string())
    }

    /// 2 字下げの JSON と末尾の改行 (jq の既定の出力と同じ形)。
    pub fn to_pretty(&self) -> String {
        let text = serde_json::to_string_pretty(self).expect("OValue は JSON にいつも書ける");
        format!("{text}\n")
    }

    /// serde_json の値にする (キーの順を見ずに比べるため)。
    pub fn to_value(&self) -> serde_json::Value {
        match self {
            OValue::Null => serde_json::Value::Null,
            OValue::Bool(b) => serde_json::Value::Bool(*b),
            OValue::Number(n) => serde_json::Value::Number(n.clone()),
            OValue::String(s) => serde_json::Value::String(s.clone()),
            OValue::Array(items) => {
                serde_json::Value::Array(items.iter().map(OValue::to_value).collect())
            }
            OValue::Object(entries) => serde_json::Value::Object(
                entries
                    .iter()
                    .map(|(k, v)| (k.clone(), v.to_value()))
                    .collect(),
            ),
        }
    }

    /// object のキーの値 (object でなければ None)。
    pub fn get(&self, key: &str) -> Option<&OValue> {
        match self {
            OValue::Object(entries) => entries.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    /// object のキーに値を入れる。在ればその場所で替え、無ければ末尾に足す (object でなければ何もしない)。
    pub fn set(&mut self, key: &str, value: OValue) {
        if let OValue::Object(entries) = self {
            match entries.iter_mut().find(|(k, _)| k == key) {
                Some((_, v)) => *v = value,
                None => entries.push((key.to_string(), value)),
            }
        }
    }

    /// object のキーを外し、その値を返す。
    pub fn remove(&mut self, key: &str) -> Option<OValue> {
        match self {
            OValue::Object(entries) => {
                let i = entries.iter().position(|(k, _)| k == key)?;
                Some(entries.remove(i).1)
            }
            _ => None,
        }
    }
}

impl Serialize for OValue {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            OValue::Null => s.serialize_unit(),
            OValue::Bool(b) => s.serialize_bool(*b),
            OValue::Number(n) => n.serialize(s),
            OValue::String(t) => s.serialize_str(t),
            OValue::Array(items) => {
                let mut seq = s.serialize_seq(Some(items.len()))?;
                for item in items {
                    seq.serialize_element(item)?;
                }
                seq.end()
            }
            OValue::Object(entries) => {
                let mut map = s.serialize_map(Some(entries.len()))?;
                for (k, v) in entries {
                    map.serialize_entry(k, v)?;
                }
                map.end()
            }
        }
    }
}

impl<'de> Deserialize<'de> for OValue {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<OValue, D::Error> {
        d.deserialize_any(OValueVisitor)
    }
}

struct OValueVisitor;

impl<'de> Visitor<'de> for OValueVisitor {
    type Value = OValue;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("JSON の値")
    }

    fn visit_unit<E: de::Error>(self) -> Result<OValue, E> {
        Ok(OValue::Null)
    }

    fn visit_none<E: de::Error>(self) -> Result<OValue, E> {
        Ok(OValue::Null)
    }

    fn visit_bool<E: de::Error>(self, b: bool) -> Result<OValue, E> {
        Ok(OValue::Bool(b))
    }

    fn visit_i64<E: de::Error>(self, n: i64) -> Result<OValue, E> {
        Ok(OValue::Number(n.into()))
    }

    fn visit_u64<E: de::Error>(self, n: u64) -> Result<OValue, E> {
        Ok(OValue::Number(n.into()))
    }

    fn visit_f64<E: de::Error>(self, n: f64) -> Result<OValue, E> {
        serde_json::Number::from_f64(n)
            .map(OValue::Number)
            .ok_or_else(|| E::custom("有限でない数"))
    }

    fn visit_str<E: de::Error>(self, s: &str) -> Result<OValue, E> {
        Ok(OValue::String(s.to_string()))
    }

    fn visit_string<E: de::Error>(self, s: String) -> Result<OValue, E> {
        Ok(OValue::String(s))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<OValue, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = seq.next_element()? {
            items.push(item);
        }
        Ok(OValue::Array(items))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<OValue, A::Error> {
        let mut obj = OValue::Object(Vec::new());
        while let Some((k, v)) = map.next_entry::<String, OValue>()? {
            // 同じキーが 2 度あれば、初めの場所に後の値 (serde_json の Value と同じく後の値が勝つ)
            obj.set(&k, v);
        }
        Ok(obj)
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 読んで書き戻すと、object のキーの順・入れ子・数 (整数・小数・u64 の上限)・null・真偽値・文字列がそのまま (2 字下げ・末尾の改行)
    //! - 頭の BOM は読み飛ばす。壊れた JSON は誤り
    //! - 同じキーが 2 度あれば、初めの場所に後の値 (serde_json と同じく後の値が勝つ)
    //! - `set` は在るキーをその場所で替え、無いキーは末尾に足す。`remove` は外す
    //! - `to_value` で比べると、キーの順は見ない

    use super::*;

    #[test]
    fn round_trip_keeps_order() {
        let text =
            r#"{"b":1,"a":{"y":true,"x":[1,"s",null,1.5,-3,18446744073709551615]},"日本":"語"}"#;
        let v = OValue::parse(text).unwrap();
        assert_eq!(
            v.to_pretty(),
            "{\n  \"b\": 1,\n  \"a\": {\n    \"y\": true,\n    \"x\": [\n      1,\n      \"s\",\n      null,\n      1.5,\n      -3,\n      18446744073709551615\n    ]\n  },\n  \"日本\": \"語\"\n}\n"
        );
    }

    #[test]
    fn bom_and_broken() {
        assert_eq!(
            OValue::parse("\u{feff}{\"a\": 1}").unwrap(),
            OValue::Object(vec![("a".into(), OValue::Number(1.into()))])
        );
        assert!(OValue::parse("{\"a\": ").is_err());
        assert!(OValue::parse("").is_err());
    }

    #[test]
    fn duplicate_keys_keep_first_place_last_value() {
        let v = OValue::parse(r#"{"a":1,"b":2,"a":3}"#).unwrap();
        assert_eq!(
            v,
            OValue::Object(vec![
                ("a".into(), OValue::Number(3.into())),
                ("b".into(), OValue::Number(2.into())),
            ])
        );
    }

    #[test]
    fn set_get_remove() {
        let mut v = OValue::parse(r#"{"a":1,"b":2}"#).unwrap();
        v.set("a", OValue::String("x".into()));
        v.set("c", OValue::Bool(false));
        assert_eq!(v.get("a"), Some(&OValue::String("x".into())));
        assert_eq!(
            v.to_pretty(),
            "{\n  \"a\": \"x\",\n  \"b\": 2,\n  \"c\": false\n}\n"
        );
        assert_eq!(v.remove("b"), Some(OValue::Number(2.into())));
        assert_eq!(v.remove("zz"), None);
        assert_eq!(v.get("b"), None);
        assert_eq!(OValue::Null.get("a"), None);
    }

    #[test]
    fn to_value_ignores_order() {
        let a = OValue::parse(r#"{"a":1,"b":{"x":1,"y":2}}"#).unwrap();
        let b = OValue::parse(r#"{"b":{"y":2,"x":1},"a":1}"#).unwrap();
        assert_ne!(a, b);
        assert_eq!(a.to_value(), b.to_value());
    }
}
