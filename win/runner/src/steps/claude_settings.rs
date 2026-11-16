//! Claude Code の `%USERPROFILE%\.claude\settings.json` を部分書き換えする手順 (claude-env・claude-hook・claude-statusline・claude-footer-links・
//! claude-skill-overrides) が共有する読み書き。
//!
//! settings.json は Claude Code 自身も書く (権限の「常に許可」など) ので、手順は自分の持つキーだけを直し、ほかのキーと順を残す (順を保つ JSON の
//! 型 `ojson`)。キーの順を見ずに同じなら書かない。書く前に前の中身を `%LOCALAPPDATA%\dotfiles\state\claude-settings\backup\` に写す (新しい方から
//! 10 個。dotfiles-private の docs/adr/064_win_w02_claude_skills_hub_* と docs/adr/065_win_claude_config_*)。

use super::{Mode, Outcome};
use crate::context::Ctx;
use crate::fsutil;
use crate::ojson::OValue;
use crate::report::Kind;
use std::path::{Path, PathBuf};

/// 書く前の settings.json を写す数
const BACKUPS: usize = 10;

/// settings.json の置き場
pub fn path(ctx: &Ctx) -> PathBuf {
    ctx.roots.user_profile.join(".claude").join("settings.json")
}

/// settings.json を読む。無ければ空の object (と false)。壊れている・object でない・読めないなら、締めの行の文を返す。
pub fn load(path: &Path) -> Result<(OValue, bool), String> {
    let shown = path.display();
    match std::fs::read_to_string(path) {
        Ok(text) => match OValue::parse(&text) {
            Ok(v @ OValue::Object(_)) => Ok((v, true)),
            Ok(_) => Err(format!(
                "{shown} が object でない (中身が {{…}} でない) → 手で直す"
            )),
            Err(e) => Err(format!("{shown} が JSON として壊れている → 手で直す ({e})")),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Ok((OValue::Object(Vec::new()), false))
        }
        Err(e) => Err(format!("{shown} が読めない ({e})")),
    }
}

/// `before` を `after` にする (キーの順を見ずに同じなら何もしない)。`what` は締めの行に出す名前 (「settings.json の statusLine」など)、
/// `done` は apply で書いたあとに出す 1 行。check と dry-run は書かない。
pub fn apply_change(
    ctx: &mut Ctx,
    mode: Mode,
    path: &Path,
    (before, existed): (&OValue, bool),
    after: &OValue,
    what: &str,
    done: &str,
) -> Outcome {
    let shown = path.display().to_string();
    if existed && before.to_value() == after.to_value() {
        ctx.say(format!("登録済みです: {shown} の {what}"));
        return Outcome::new(Kind::Ok, format!("settings.json の {what} は登録済み"));
    }
    let kind = if existed { Kind::Fix } else { Kind::Missing };
    match mode {
        Mode::Check => {
            ctx.say(format!("{what} を書く (apply で): {shown}"));
            Outcome::new(
                kind,
                format!("settings.json の {what} が無い・違う → apply で書く"),
            )
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] {what} を書く: {shown}"));
            Outcome::new(kind, format!("[dry-run] settings.json の {what} を書く"))
        }
        Mode::Apply { .. } => match store(ctx, path, after, existed) {
            Ok(()) => {
                ctx.say(format!("登録しました: {shown} の {what}"));
                ctx.say(done);
                Outcome::new(Kind::Ok, format!("settings.json の {what} を書いた"))
            }
            Err(e) => Outcome::new(Kind::Failed, e),
        },
    }
}

/// settings.json に書く (在れば前の中身を控えに写してから)。
pub fn store(ctx: &mut Ctx, path: &Path, value: &OValue, existed: bool) -> Result<(), String> {
    let shown = path.display();
    if existed && let Err(e) = backup(ctx, path) {
        return Err(format!("{shown} を控えに写せないので書かない ({e})"));
    }
    fsutil::write_atomic(path, value.to_pretty().as_bytes())
        .map_err(|e| format!("{shown} を書けない ({e})"))
}

/// 書く前の settings.json を `<state_dir>\claude-settings\backup\settings-<秒>-<ナノ秒>.json` に写し、新しい方から 10 個だけ残す。
pub fn backup(ctx: &mut Ctx, path: &Path) -> std::io::Result<()> {
    let dir = ctx.state_dir.join("claude-settings").join("backup");
    std::fs::create_dir_all(&dir)?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let mut name = format!(
        "settings-{:012}-{:09}.json",
        now.as_secs(),
        now.subsec_nanos()
    );
    // 同じ時刻の写しを上書きしない
    let mut n = 0;
    while dir.join(&name).exists() {
        n += 1;
        name = format!(
            "settings-{:012}-{:09}-{n}.json",
            now.as_secs(),
            now.subsec_nanos()
        );
    }
    std::fs::copy(path, dir.join(&name))?;
    let mut olds: Vec<String> = std::fs::read_dir(&dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("settings-") && n.ends_with(".json"))
        .collect();
    olds.sort();
    while olds.len() > BACKUPS {
        let old = olds.remove(0);
        let _ = std::fs::remove_file(dir.join(old));
    }
    ctx.say(format!(
        "前の中身を写しました: {}",
        dir.join(&name).display()
    ));
    Ok(())
}

/// runner が写す hook の口 (`%USERPROFILE%\.claude\hooks\dotfiles-claude.exe`)。claude-files が写し、claude-hook と claude-statusline が登録する
pub fn hook_exe(ctx: &Ctx) -> PathBuf {
    ctx.roots
        .user_profile
        .join(".claude")
        .join("hooks")
        .join(HOOK_EXE)
}

/// hook の口の名前
pub const HOOK_EXE: &str = "dotfiles-claude.exe";

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 無ければ空の object、壊れている・object でなければ締めの行の文
    //! - 同じなら書かない。違えば check と dry-run は書かず、apply は前の中身を写してから書く (無かったら写さない)

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};

    #[test]
    fn load_reads_or_explains() {
        let t = TempDir::new("claude-settings-load");
        let p = t.path().join("settings.json");
        assert_eq!(load(&p).unwrap(), (OValue::Object(Vec::new()), false));
        std::fs::write(&p, "{\"a\": 1}").unwrap();
        assert!(load(&p).unwrap().1);
        std::fs::write(&p, "[1]").unwrap();
        assert!(load(&p).unwrap_err().contains("object でない"));
        std::fs::write(&p, "{").unwrap();
        assert!(load(&p).unwrap_err().contains("壊れている"));
    }

    #[test]
    fn writes_only_when_changed() {
        let t = TempDir::new("claude-settings-apply");
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let mut ctx = Ctx {
            repo: t.path().join("dotfiles"),
            roots: Roots::from_home(&t.path().join("home")),
            state_dir: t.path().join("state"),
            host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
            sys: &sys,
            out: &mut out,
        };
        let p = path(&ctx);
        let before = OValue::parse("{\"b\": 1, \"a\": 2}").unwrap();
        let mut after = before.clone();
        after.set("c", OValue::Bool(true));
        // 無いときの check は missing・書かない
        let o = apply_change(
            &mut ctx,
            Mode::Check,
            &p,
            (&before, false),
            &after,
            "c",
            "x",
        );
        assert_eq!(o.kind, Kind::Missing);
        assert!(!p.exists());
        let o = apply_change(
            &mut ctx,
            Mode::Apply { force: false },
            &p,
            (&before, false),
            &after,
            "c",
            "x",
        );
        assert_eq!(o.kind, Kind::Ok);
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            "{\n  \"b\": 1,\n  \"a\": 2,\n  \"c\": true\n}\n"
        );
        assert!(
            !ctx.state_dir.join("claude-settings").exists(),
            "無かったものは写さない"
        );
        // 順だけ違うものは同じ
        let reordered = OValue::parse("{\"a\": 2, \"c\": true, \"b\": 1}").unwrap();
        let o = apply_change(
            &mut ctx,
            Mode::Check,
            &p,
            (&after, true),
            &reordered,
            "c",
            "x",
        );
        assert_eq!(o.kind, Kind::Ok);
        // 在るものを直すときは写す
        let mut again = after.clone();
        again.set("c", OValue::Bool(false));
        let o = apply_change(
            &mut ctx,
            Mode::Apply { force: false },
            &p,
            (&after, true),
            &again,
            "c",
            "x",
        );
        assert_eq!(o.kind, Kind::Ok);
        let backups = std::fs::read_dir(ctx.state_dir.join("claude-settings").join("backup"))
            .unwrap()
            .count();
        assert_eq!(backups, 1);
    }
}
