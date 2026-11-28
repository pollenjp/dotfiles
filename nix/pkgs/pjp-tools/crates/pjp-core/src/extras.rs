//! private な足し分 (claude-skills) があるか (dotfiles-private の ADR 124)。
//!
//! 公開の道具 (pjp hub・child・mark・pack と入口 pjp) は足し分を前提にしない。足し分があるときだけ、足し分の道具 (pjp ticket など) に
//! 渡す・その案内を出す:
//!
//! - 道具: claude-skills の shim `pjp-skills` が PATH か `<CARGO_HOME か ~/.cargo>/bin/` にある ([`shim`])。dotfiles の手順 pjp (Windows) と
//!   bootstrap-pjp.sh (Linux) が入れる
//! - skill: `~/.claude/skills/pjp-hc-hub-private/` がある ([`hub_skill_dir`])。ハブの雛形の重ね (`assets/hub/settings.overlay.json`) もここ

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use crate::{paths, process};

/// claude-skills の shim (private な道具の入口) の名前。
pub const SHIM: &str = "pjp-skills";
/// ハブの足し分の skill の名前。
pub const HUB_SKILL: &str = "pjp-hc-hub-private";

/// このマシンの `pjp-skills` の場所 (PATH → `$CARGO_HOME/bin` → `~/.cargo/bin`)。無ければ None。
pub fn shim() -> Option<PathBuf> {
    shim_in(
        std::env::var_os("PATH").as_deref(),
        std::env::var_os("CARGO_HOME").as_deref(),
        paths::home_dir().ok().as_deref(),
    )
}

/// `pjp-skills` を、PATH の形の `path_var` → `cargo_home` の `bin` → `home` の `.cargo/bin` の順に探す (Windows は `.exe` なども)。
/// 空の値は無いものとみる。
pub fn shim_in(
    path_var: Option<&OsStr>,
    cargo_home: Option<&OsStr>,
    home: Option<&Path>,
) -> Option<PathBuf> {
    let bins = cargo_home
        .filter(|v| !v.is_empty())
        .map(|c| Path::new(c).join("bin"))
        .into_iter()
        .chain(home.map(|h| h.join(".cargo").join("bin")));
    path_var
        .filter(|v| !v.is_empty())
        .and_then(|pv| process::find_in(pv, SHIM))
        .or_else(|| {
            bins.filter_map(|dir| std::env::join_paths([dir]).ok())
                .find_map(|pv| process::find_in(&pv, SHIM))
        })
}

/// ホーム `home` の下の、ハブの足し分の skill のディレクトリ (無ければ None)。
pub fn hub_skill_dir(home: &Path) -> Option<PathBuf> {
    let dir = home.join(".claude").join("skills").join(HUB_SKILL);
    dir.is_dir().then_some(dir)
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - pjp-skills は PATH → CARGO_HOME の bin → ~/.cargo/bin の順に探し、どこにも無ければ None。空の PATH・CARGO_HOME は無いものとみる
    //! - 実行できないファイル (Unix で実行の権限が無い) は数えない
    //! - ハブの足し分の skill は ~/.claude/skills/pjp-hc-hub-private がディレクトリのときだけ

    use super::*;
    use crate::testutil::TempDir;

    fn exe(t: &TempDir, dir: &str) -> PathBuf {
        let name = format!("{SHIM}{}", std::env::consts::EXE_SUFFIX);
        let p = t.write(&format!("{dir}/{name}"), "#!/bin/sh\nexit 0\n");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        p
    }

    fn pv(t: &TempDir, dir: &str) -> std::ffi::OsString {
        std::env::join_paths([t.path().join(dir)]).unwrap()
    }

    #[test]
    fn shim_is_found_in_path_then_cargo_home_then_home() {
        let t = TempDir::new("extras-shim");
        let home = t.path().join("home");
        let cargo = t.path().join("cargo");
        assert_eq!(
            shim_in(Some(&pv(&t, "path")), Some(cargo.as_os_str()), Some(&home)),
            None
        );
        let in_home = exe(&t, "home/.cargo/bin");
        assert_eq!(
            shim_in(Some(&pv(&t, "path")), Some(cargo.as_os_str()), Some(&home)).as_deref(),
            Some(in_home.as_path())
        );
        let in_cargo = exe(&t, "cargo/bin");
        assert_eq!(
            shim_in(Some(&pv(&t, "path")), Some(cargo.as_os_str()), Some(&home)).as_deref(),
            Some(in_cargo.as_path())
        );
        let in_path = exe(&t, "path");
        assert_eq!(
            shim_in(Some(&pv(&t, "path")), Some(cargo.as_os_str()), Some(&home)).as_deref(),
            Some(in_path.as_path())
        );
        // 空の PATH・CARGO_HOME は無いものとみる (~/.cargo/bin で見つかる)
        assert_eq!(
            shim_in(Some(OsStr::new("")), Some(OsStr::new("")), Some(&home)).as_deref(),
            Some(in_home.as_path())
        );
        assert_eq!(shim_in(None, None, None), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_file_without_the_execute_bit_is_not_the_shim() {
        let t = TempDir::new("extras-noexec");
        t.write(&format!("path/{SHIM}"), "#!/bin/sh\n");
        assert_eq!(shim_in(Some(&pv(&t, "path")), None, None), None);
    }

    #[test]
    fn hub_skill_dir_is_a_directory_under_claude_skills() {
        let t = TempDir::new("extras-skill");
        assert_eq!(hub_skill_dir(t.path()), None);
        t.write(".claude/skills/pjp-hc-hub-private", "not a dir");
        assert_eq!(hub_skill_dir(t.path()), None);
        let u = TempDir::new("extras-skill-dir");
        let d = u.path().join(".claude").join("skills").join(HUB_SKILL);
        std::fs::create_dir_all(&d).unwrap();
        assert_eq!(hub_skill_dir(u.path()), Some(d));
    }
}
