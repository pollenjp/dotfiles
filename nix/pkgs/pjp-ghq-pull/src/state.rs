//! 前回の選択。Enter で始めたときに外していた repo の絶対パスを 1 行 1 つで残し、次に開いたときの初期値にする
//! (ここに無い repo は on で出す。初めて開いたときと、新しく ghq get した repo は on)。
//! 読めない・壊れているファイルは空 (全部 on) として読む。

use std::collections::HashSet;
use std::ffi::OsString;
use std::io::Write;
use std::path::{Path, PathBuf};

const HEADER: &str = "# pjp-ghq-pull: 前回 Enter で始めたときに外していた repo (1 行 1 つ)。ここに無い repo は on で出す\n";

/// $XDG_STATE_HOME/pjp-ghq-pull/deselected。XDG_STATE_HOME が空か相対パスなら ~/.local/state の下
pub fn path_from(xdg_state_home: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    let base = xdg_state_home
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| {
            home.map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .map(|h| h.join(".local/state"))
        })?;
    Some(base.join("pjp-ghq-pull/deselected"))
}

pub fn load(path: &Path) -> HashSet<PathBuf> {
    let Ok(text) = std::fs::read(path).map(String::from_utf8) else {
        return HashSet::new();
    };
    let Ok(text) = text else {
        return HashSet::new();
    };
    text.lines()
        .filter(|l| l.starts_with('/'))
        .map(PathBuf::from)
        .collect()
}

/// 一時ファイルに書いてから置き換える (途中で落ちても前の中身が残る)
pub fn save(path: &Path, deselected: &[PathBuf]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(HEADER.as_bytes())?;
        for p in deselected {
            writeln!(f, "{}", p.display())?;
        }
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path)
}
