//! 文字のファイルの書き方 (spec §6.6 の「文字コード」と §8.5 の書き方)。改行は LF、一時ファイルに書いて置き換える。

use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::{Error, Result};

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// `text` の改行を LF にそろえ、`path` と同じディレクトリの一時ファイルに書いてから置き換える (途中で止まっても、
/// 読み手は前の中身か新しい中身のどちらかを読む)。親のディレクトリが無ければ作る。
pub fn write_atomic(path: &Path, text: &str) -> Result<()> {
    let dir = path
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)
        .map_err(|e| Error::io(format!("{} を作れません", dir.display()), &e))?;
    let name = path.file_name().ok_or_else(|| {
        Error::failure(format!(
            "{} はファイルの名前で終わっていません",
            path.display()
        ))
    })?;
    let tmp = dir.join(format!(
        ".{}.{}-{}.tmp",
        name.to_string_lossy(),
        std::process::id(),
        NEXT.fetch_add(1, Ordering::SeqCst)
    ));
    let body = text.replace("\r\n", "\n");
    let written = std::fs::write(&tmp, body).and_then(|()| std::fs::rename(&tmp, path));
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(Error::io(format!("{} を書けません", path.display()), &e));
    }
    Ok(())
}

/// 外から受けたバイト (stdin・ファイル) を文字にする。UTF-8 の BOM と UTF-16 の BOM (LE・BE) を見て、BOM が無ければ UTF-8
/// として読む (壊れたバイトは置き換える)。Windows の shell (PowerShell 5 の Out-File など) が UTF-16 で渡しても読める。
pub fn decode_text(bytes: &[u8]) -> String {
    let utf16 = |be: bool, rest: &[u8]| -> String {
        let units: Vec<u16> = rest
            .as_chunks::<2>()
            .0
            .iter()
            .map(|&pair| {
                if be {
                    u16::from_be_bytes(pair)
                } else {
                    u16::from_le_bytes(pair)
                }
            })
            .collect();
        String::from_utf16_lossy(&units)
    };
    match bytes {
        [0xEF, 0xBB, 0xBF, rest @ ..] => String::from_utf8_lossy(rest).into_owned(),
        [0xFF, 0xFE, rest @ ..] => utf16(false, rest),
        [0xFE, 0xFF, rest @ ..] => utf16(true, rest),
        _ => String::from_utf8_lossy(bytes).into_owned(),
    }
}

/// JSON の文 (serde_json の `to_string` の出力など) の ASCII でない文字を、4 桁の `\u` (BMP の外はサロゲートの組) に逃がす。
/// JSON の文字列の外に ASCII でない文字は出ないので、全体を逃がしても同じ値の JSON になる。Claude Code の hook の stdout に使う
/// (shell や code page が間に入っても化けない)。
pub fn json_ascii(json: &str) -> String {
    use std::fmt::Write as _;
    let mut out = String::with_capacity(json.len());
    for c in json.chars() {
        if c.is_ascii() {
            out.push(c);
        } else {
            let mut units = [0u16; 2];
            for u in c.encode_utf16(&mut units) {
                let _ = write!(out, "\\u{u:04x}");
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn json_ascii_escapes_non_ascii() {
        // BMP の字は 4 桁の \u、BMP の外 (U+1F5D1) はサロゲートの組。ASCII はそのまま
        assert_eq!(
            json_ascii("{\"a\":\"ハ\u{1F5D1} b\"}"),
            "{\"a\":\"\\u30cf\\ud83d\\uddd1 b\"}"
        );
        assert_eq!(json_ascii("{\"a\":[1,\"x\"]}"), "{\"a\":[1,\"x\"]}");
    }

    #[test]
    fn decode_text_handles_boms() {
        assert_eq!(decode_text(b"{\"a\":1}"), "{\"a\":1}");
        assert_eq!(decode_text("\u{feff}ハブ".as_bytes()), "ハブ");
        let le: Vec<u8> = [0xFF, 0xFE]
            .into_iter()
            .chain("ハブ".encode_utf16().flat_map(u16::to_le_bytes))
            .collect();
        assert_eq!(decode_text(&le), "ハブ");
        let be: Vec<u8> = [0xFE, 0xFF]
            .into_iter()
            .chain("x".encode_utf16().flat_map(u16::to_be_bytes))
            .collect();
        assert_eq!(decode_text(&be), "x");
        assert_eq!(decode_text(b"a\xffb"), "a\u{fffd}b");
        assert_eq!(decode_text(b""), "");
    }

    #[test]
    fn write_atomic_normalizes_newlines_and_replaces() {
        let t = TempDir::new("write-atomic");
        let path = t.path().join("pjp").join("inbox.json");
        write_atomic(&path, "{\r\n  \"a\": 1\r\n}\n").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"{\n  \"a\": 1\n}\n");
        write_atomic(&path, "x").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "x");
        // 一時ファイルは残さない
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, vec![std::ffi::OsString::from("inbox.json")]);
    }
}
