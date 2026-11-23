//! 手順 sshd の前段: ホストの値の `[sshd] authorizedKeys` から、sshd の鍵の写し (`%LOCALAPPDATA%\dotfiles\sshd\authorized_keys`) を置く・消す。
//!
//! WSL の `nix/scripts/bootstrap-windows-sshd.sh` の「鍵の写しを置く」を写したもの。受け持ちが runner のホストでだけ流す (受け持ちが WSL の
//! ホストは WSL の setup が写しを置く。runner は写しに触らない)。意味は Nix の `wsl.windowsFiles.sshd.authorizedKeys` と同じ
//! (dotfiles-private の docs/adr/078_win_sshd_tailscale_* §2 E):
//!
//! - 書かない (None): dotfiles は鍵を置かない。写しを置かず、前の写しは消す (Install-Sshd.ps1 は写しが無ければ鍵の中身に触らない)
//! - list: その鍵だけ。空の list は鍵 0 本 (誰も入れない)
//!
//! 写しは中身が同じなら書かない。check と dry-run は差を出すだけ、apply は置く・消す。写しを置いた後に
//! `administrators_authorized_keys` へ揃えるのは、PowerShell の `Install-Sshd` (UAC。手順 sshd はずれを知らせるだけ)。
//! 写しの頭には runner が書いた印 (`RUNNER_MARK`) を入れ、Install-Sshd.ps1 は、手で打たれたときもその印で、鍵の直し方を
//! TOML の値と dotfiles apply で案内する。

use super::{Mode, Outcome};
use crate::context::Ctx;
use crate::report::Kind;
use std::path::PathBuf;

/// 写しの頭の印 (Install-Sshd.ps1 の `$script:RunnerCopyMark` と同じ字)
pub const RUNNER_MARK: &str = "# dotfiles-keys-from: runner";

/// 写しの置き場 (Install-Sshd.ps1 の -KeysCopy の既定と同じ)
pub fn copy_path(ctx: &Ctx) -> PathBuf {
    ctx.roots
        .local_app_data
        .join("dotfiles")
        .join("sshd")
        .join("authorized_keys")
}

/// 写しの中身 (改行は LF。頭の 2 行は Install-Sshd.ps1 がコメントとして読み飛ばす)
pub fn copy_text(keys: &[String]) -> String {
    let mut s = String::from(
        "# dotfiles の写し (Windows の runner の手順 sshd が書く。手で直さない)。元は dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] authorizedKeys。\n",
    );
    s.push_str(RUNNER_MARK);
    s.push('\n');
    for k in keys {
        s.push_str(k);
        s.push('\n');
    }
    s
}

/// 写しを揃える。check・dry-run は差の行を返し、apply は置く・消す (落ちたときだけ行を返す)。揃っていれば行は無い。
/// 受け持ちが WSL のホストでは何もしない (TOML に鍵を書いていれば、使わないことを 1 行出す)。
pub fn sync(ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
    if !ctx.host.runner_enable {
        if ctx.host.sshd_keys.is_some() {
            ctx.say("※ ホストの値の [sshd] authorizedKeys は使わない (受け持ちが WSL の setup のホストでは、WSL の setup が Nix の wsl.windowsFiles.sshd.authorizedKeys から鍵の写しを置く)");
        }
        return Vec::new();
    }
    let path = copy_path(ctx);
    let shown = path.display().to_string();
    let current = match std::fs::read(&path) {
        Ok(b) => Some(b),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            return vec![
                Outcome::new(Kind::Failed, format!("鍵の写しを読めない ({shown}: {e})"))
                    .note("下の sshd の行は、写しの今の中身で確かめた"),
            ];
        }
    };
    match ctx.host.sshd_keys.clone() {
        None => {
            if current.is_none() {
                return Vec::new();
            }
            match mode {
                Mode::Check => vec![Outcome::new(
                    Kind::Fix,
                    "鍵の写しが残っている (ホストの値に [sshd] authorizedKeys が無い。dotfiles は鍵を置かない) → apply で消す",
                )
                .note(format!("鍵の写し: {shown}"))],
                Mode::DryRun { .. } => {
                    ctx.say(format!("[dry-run] 鍵の写しを消す (ホストの値に [sshd] authorizedKeys が無い): {shown}"));
                    vec![Outcome::new(
                        Kind::Fix,
                        "鍵の写しが残っている → apply で消す",
                    )]
                }
                Mode::Apply { .. } => match std::fs::remove_file(&path) {
                    Ok(()) => {
                        ctx.say(format!("鍵の写しを消しました (ホストの値に [sshd] authorizedKeys が無い。dotfiles は鍵を置かない): {shown}"));
                        Vec::new()
                    }
                    Err(e) => vec![Outcome::new(
                        Kind::Failed,
                        format!("鍵の写しを消せなかった ({shown}: {e})"),
                    )],
                },
            }
        }
        Some(keys) => {
            let want = copy_text(&keys);
            if current.as_deref() == Some(want.as_bytes()) {
                return Vec::new();
            }
            let what = if current.is_none() {
                "鍵の写しが無い"
            } else {
                "鍵の写しがホストの値と違う"
            };
            let n = keys.len();
            match mode {
                Mode::Check => vec![Outcome::new(
                    Kind::Fix,
                    format!("{what} → apply で置く (ホストの値の [sshd] authorizedKeys の {n} 本)"),
                )
                .note(format!("鍵の写し: {shown}"))
                .note("置いた後に administrators_authorized_keys へ揃えるのは、PowerShell の Install-Sshd (UAC)")],
                Mode::DryRun { .. } => {
                    ctx.say(format!("[dry-run] 鍵の写しを置く ({n} 本): {shown}"));
                    vec![Outcome::new(
                        Kind::Fix,
                        format!("{what} → apply で置く ({n} 本)"),
                    )]
                }
                Mode::Apply { .. } => {
                    match crate::fsutil::write_atomic(&path, want.as_bytes()) {
                        Ok(()) => {
                            ctx.say(format!("鍵の写しを置きました ({n} 本。ホストの値の [sshd] authorizedKeys): {shown}"));
                            Vec::new()
                        }
                        Err(e) => vec![Outcome::new(
                            Kind::Failed,
                            format!("鍵の写しを置けなかった ({shown}: {e})"),
                        )
                        .note("下の sshd の行は、写しの今の中身で確かめた")],
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 受け持ちが runner のホスト: list は写しを置き (頭に runner の印。改行は LF)、中身が同じなら書かない。空の list は頭だけ。
    //!   書かない (None) は前の写しを消し、無ければ何もしない。check と dry-run は差の行を出すだけで書かない
    //! - 受け持ちが WSL のホスト: 写しに触らない (TOML に鍵があれば、使わないと 1 行出す)

    use super::*;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    const KEY: &str =
        r#"from="100.64.0.1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE herdr@phone"#;

    fn run(t: &TempDir, host: &str, mode: Mode) -> (Vec<Outcome>, String) {
        let sys = FakeSys::new(|_| unreachable!("外のコマンドは打たない"));
        let mut out = Vec::new();
        let host = parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap();
        let o = {
            let mut ctx = Ctx {
                repo: t.path().to_path_buf(),
                roots: Roots::from_home(t.path()),
                state_dir: t.path().join("state"),
                host,
                sys: &sys,
                out: &mut out,
            };
            sync(&mut ctx, mode)
        };
        (o, String::from_utf8(out).unwrap())
    }

    fn copy(t: &TempDir) -> PathBuf {
        Roots::from_home(t.path())
            .local_app_data
            .join("dotfiles/sshd/authorized_keys")
    }

    const APPLY: Mode = Mode::Apply { force: false };
    const RUNNER: &str = "[runner]\nenable = true\n";

    #[test]
    fn copy_text_has_the_runner_mark_and_lf() {
        let t = copy_text(&[KEY.to_string()]);
        assert_eq!(t.lines().nth(1), Some(RUNNER_MARK));
        assert!(t.ends_with(&format!("{KEY}\n")));
        assert!(!t.contains('\r'));
        assert_eq!(copy_text(&[]).lines().count(), 2);
    }

    #[test]
    fn runner_host_places_the_list_and_skips_when_same() {
        let t = TempDir::new("sshd-keys");
        let host = format!("{RUNNER}[sshd]\nauthorizedKeys = ['{KEY}']\n");
        // check・dry-run は書かない
        let (o, _) = run(&t, &host, Mode::Check);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(
            o[0].text.starts_with("鍵の写しが無い → apply で置く"),
            "{}",
            o[0].text
        );
        let (o, out) = run(&t, &host, Mode::DryRun { force: false });
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(out.contains("[dry-run] 鍵の写しを置く (1 本)"));
        assert!(!copy(&t).exists());
        // apply は置く (行は無い)
        let (o, out) = run(&t, &host, APPLY);
        assert!(o.is_empty(), "{o:?}");
        assert!(out.contains("鍵の写しを置きました (1 本"));
        assert_eq!(
            std::fs::read_to_string(copy(&t)).unwrap(),
            copy_text(&[KEY.to_string()])
        );
        // 同じなら書かない・何も出さない
        let (o, out) = run(&t, &host, APPLY);
        assert!(o.is_empty() && out.is_empty(), "{o:?} {out}");
        let (o, _) = run(&t, &host, Mode::Check);
        assert!(o.is_empty());
        // 違えば check は差を出し、apply は書き直す
        std::fs::write(
            copy(&t),
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHEROTHER x\n",
        )
        .unwrap();
        let (o, _) = run(&t, &host, Mode::Check);
        assert!(
            o[0].text.starts_with("鍵の写しがホストの値と違う"),
            "{}",
            o[0].text
        );
        run(&t, &host, APPLY);
        assert_eq!(
            std::fs::read_to_string(copy(&t)).unwrap(),
            copy_text(&[KEY.to_string()])
        );
    }

    #[test]
    fn runner_host_empty_list_is_zero_keys() {
        let t = TempDir::new("sshd-keys");
        let host = format!("{RUNNER}[sshd]\nauthorizedKeys = []\n");
        let (o, out) = run(&t, &host, APPLY);
        assert!(o.is_empty());
        assert!(out.contains("(0 本"));
        assert_eq!(std::fs::read_to_string(copy(&t)).unwrap(), copy_text(&[]));
    }

    #[test]
    fn runner_host_without_keys_removes_the_copy() {
        let t = TempDir::new("sshd-keys");
        // 無ければ何もしない
        let (o, out) = run(&t, RUNNER, APPLY);
        assert!(o.is_empty() && out.is_empty());
        std::fs::create_dir_all(copy(&t).parent().unwrap()).unwrap();
        std::fs::write(copy(&t), copy_text(&[KEY.to_string()])).unwrap();
        let (o, _) = run(&t, RUNNER, Mode::Check);
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(o[0].text.contains("→ apply で消す"));
        assert!(copy(&t).exists());
        let (o, out) = run(&t, RUNNER, APPLY);
        assert!(o.is_empty());
        assert!(out.contains("鍵の写しを消しました"));
        assert!(!copy(&t).exists());
    }

    #[test]
    fn wsl_host_does_not_touch_the_copy() {
        let t = TempDir::new("sshd-keys");
        std::fs::create_dir_all(copy(&t).parent().unwrap()).unwrap();
        std::fs::write(copy(&t), "x\n").unwrap();
        let (o, out) = run(&t, "", APPLY);
        assert!(o.is_empty() && out.is_empty());
        let (o, out) = run(&t, &format!("[sshd]\nauthorizedKeys = ['{KEY}']\n"), APPLY);
        assert!(o.is_empty());
        assert!(out.contains("[sshd] authorizedKeys は使わない"));
        assert_eq!(std::fs::read_to_string(copy(&t)).unwrap(), "x\n");
    }
}
