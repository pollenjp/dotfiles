//! 手順 sshd の前段: ホストの値の `[sshd] allowUsers`・`allowFrom` から、sshd のユーザーと送り元の写し
//! (`%LOCALAPPDATA%\dotfiles\sshd\allow.json`) を置く・消す。
//!
//! 鍵の写し (`sshd_keys`) と同じ段・同じ置き場で、受け持ちが runner のホストでだけ流す。`Install-Sshd.ps1` は既定でこの写しを読み、
//! sshd_config の AllowUsers と Match Address に書く (手で打つ `Install-Sshd` (UAC で揃える本番) も同じ値を使う。引数で渡すだけだと、手で
//! 打つ `Install-Sshd` が値を知らず既定に書き戻す)。意味は `[sshd] authorizedKeys` と同じ流儀:
//!
//! - どちらも書かない (None): 写しを置かず、前の写しは消す。Install-Sshd は既定 (流したユーザーと、tailnet と localhost) で書く
//! - 片方だけ書く: 書いた方はその値、書かない方は写しの null (Install-Sshd の既定)
//! - 空の list: ユーザー 0 人 (誰も入れない)・送り元 0 (どこからも入れない)
//!
//! 写しは中身が同じなら書かない。check と dry-run は差を出すだけ、apply は置く・消す。値を sshd_config に揃えるのは、PowerShell の
//! `Install-Sshd` (UAC。手順 sshd はずれを知らせるだけ)。受け持ちが WSL のホストでは触らない (WSL の `bootstrap-windows-sshd.sh` は、
//! 受け持ちが runner だったときの写しが残っていれば消す。WSL のホストのユーザーと送り元は既定のまま)。

use super::{Mode, Outcome};
use crate::context::Ctx;
use crate::ojson::OValue;
use crate::report::Kind;
use std::path::PathBuf;

/// 写しの置き場 (Install-Sshd.ps1 の -AllowCopy の既定と同じ)
pub fn copy_path(ctx: &Ctx) -> PathBuf {
    ctx.roots
        .local_app_data
        .join("dotfiles")
        .join("sshd")
        .join("allow.json")
}

/// 写しの中身 (2 字下げの JSON と末尾の改行。BOM は付けない)。欄の並びは version・note・allowUsers・allowFrom で、書かない欄は null。
/// Install-Sshd.ps1 の ConvertFrom-AllowCopy が読む (Install-Sshd.Tests.ps1 に同じ形の写しを置いて確かめる)
pub fn copy_text(users: Option<&[String]>, from: Option<&[String]>) -> String {
    let list = |v: Option<&[String]>| match v {
        None => OValue::Null,
        Some(items) => OValue::Array(items.iter().map(|s| OValue::String(s.clone())).collect()),
    };
    OValue::Object(vec![
        ("version".to_string(), OValue::Number(1.into())),
        (
            "note".to_string(),
            OValue::String(
                "dotfiles の写し (Windows の runner の手順 sshd が書く。手で直さない)。元は dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] allowUsers・allowFrom。Install-Sshd が sshd_config の AllowUsers と Match Address に書く (null は既定)"
                    .to_string(),
            ),
        ),
        ("allowUsers".to_string(), list(users)),
        ("allowFrom".to_string(), list(from)),
    ])
    .to_pretty()
}

/// 出力に添える値の言い方 (「allowUsers = alice・bob」「allowFrom は書いていない (既定: tailnet と localhost)」)
fn describe(users: Option<&[String]>, from: Option<&[String]>) -> String {
    let one = |key: &str, v: Option<&[String]>, default: &str, zero: &str| match v {
        None => format!("{key} は書いていない (既定: {default})"),
        Some([]) => format!("{key} = [] ({zero})"),
        Some(items) => format!("{key} = {}", items.join("・")),
    };
    format!(
        "{}・{}",
        one(
            "allowUsers",
            users,
            "Install-Sshd を流したユーザー",
            "誰も入れない"
        ),
        one(
            "allowFrom",
            from,
            "tailnet と localhost",
            "どこからも入れない"
        )
    )
}

/// 写しを揃える。check・dry-run は差の行を返し、apply は置く・消す (落ちたときだけ行を返す)。揃っていれば行は無い。
/// 受け持ちが WSL のホストでは何もしない (TOML に値を書いていれば、使わないことを 1 行出す)。
pub fn sync(ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
    let users = ctx.host.sshd_allow_users.clone();
    let from = ctx.host.sshd_allow_from.clone();
    if !ctx.host.runner_enable {
        if users.is_some() || from.is_some() {
            ctx.say("※ ホストの値の [sshd] allowUsers・allowFrom は使わない (受け持ちが WSL の setup のホストでは、Install-Sshd が既定 (流したユーザーと、tailnet と localhost) で書く)");
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
                Outcome::new(
                    Kind::Failed,
                    format!("ユーザーと送り元の写しを読めない ({shown}: {e})"),
                )
                .note("下の sshd の行は、写しの今の中身で確かめた"),
            ];
        }
    };
    if users.is_none() && from.is_none() {
        if current.is_none() {
            return Vec::new();
        }
        return match mode {
            Mode::Check => vec![
                Outcome::new(
                    Kind::Fix,
                    "ユーザーと送り元の写しが残っている (ホストの値に [sshd] allowUsers・allowFrom が無い。Install-Sshd は既定で書く) → apply で消す",
                )
                .note(format!("ユーザーと送り元の写し: {shown}"))
                .note("消した後に sshd_config へ揃えるのは、PowerShell の Install-Sshd (UAC)"),
            ],
            Mode::DryRun { .. } => {
                ctx.say(format!("[dry-run] ユーザーと送り元の写しを消す (ホストの値に [sshd] allowUsers・allowFrom が無い): {shown}"));
                vec![Outcome::new(
                    Kind::Fix,
                    "ユーザーと送り元の写しが残っている → apply で消す",
                )]
            }
            Mode::Apply { .. } => match std::fs::remove_file(&path) {
                Ok(()) => {
                    ctx.say(format!("ユーザーと送り元の写しを消しました (ホストの値に [sshd] allowUsers・allowFrom が無い。Install-Sshd は既定で書く): {shown}"));
                    Vec::new()
                }
                Err(e) => vec![Outcome::new(
                    Kind::Failed,
                    format!("ユーザーと送り元の写しを消せなかった ({shown}: {e})"),
                )],
            },
        };
    }
    let want = copy_text(users.as_deref(), from.as_deref());
    if current.as_deref() == Some(want.as_bytes()) {
        return Vec::new();
    }
    let what = if current.is_none() {
        "ユーザーと送り元の写しが無い"
    } else {
        "ユーザーと送り元の写しがホストの値と違う"
    };
    let values = describe(users.as_deref(), from.as_deref());
    match mode {
        Mode::Check => vec![
            Outcome::new(
                Kind::Fix,
                format!("{what} → apply で置く (ホストの値の [sshd] allowUsers・allowFrom)"),
            )
            .note(format!("ホストの値: {values}"))
            .note(format!("ユーザーと送り元の写し: {shown}"))
            .note("置いた後に sshd_config へ揃えるのは、PowerShell の Install-Sshd (UAC)"),
        ],
        Mode::DryRun { .. } => {
            ctx.say(format!(
                "[dry-run] ユーザーと送り元の写しを置く ({values}): {shown}"
            ));
            vec![Outcome::new(Kind::Fix, format!("{what} → apply で置く"))]
        }
        Mode::Apply { .. } => match crate::fsutil::write_atomic(&path, want.as_bytes()) {
            Ok(()) => {
                ctx.say(format!(
                    "ユーザーと送り元の写しを置きました ({values}): {shown}"
                ));
                Vec::new()
            }
            Err(e) => vec![
                Outcome::new(
                    Kind::Failed,
                    format!("ユーザーと送り元の写しを置けなかった ({shown}: {e})"),
                )
                .note("下の sshd の行は、写しの今の中身で確かめた"),
            ],
        },
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 写しの中身は 2 字下げの JSON (version・note・allowUsers・allowFrom の並び) と末尾の改行で、書かない欄は null、[] は空の配列
    //!   (Install-Sshd.Tests.ps1 が読む写しと 1 バイトも違わない)
    //! - 受け持ちが runner のホスト: 値を書けば写しを置き (片方だけでも。もう片方は null)、中身が同じなら書かない。どちらも書かなければ前の
    //!   写しを消し、無ければ何もしない。check と dry-run は差の行を出すだけで書かない (check はホストの値を添える)
    //! - 受け持ちが WSL のホスト: 写しに触らない (TOML に値があれば、使わないと 1 行出す)

    use super::*;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

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
            .join("dotfiles/sshd/allow.json")
    }

    const APPLY: Mode = Mode::Apply { force: false };
    const RUNNER: &str = "[runner]\nenable = true\n";

    fn strings(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    /// Install-Sshd.Tests.ps1 の「runner の手順 sshd が書く写しを読め」と同じ中身
    #[test]
    fn copy_text_is_the_json_that_install_sshd_reads() {
        let want = "{\n  \"version\": 1,\n  \"note\": \"dotfiles の写し (Windows の runner の手順 sshd が書く。手で直さない)。元は dotfiles-private の win/hosts/<ユーザー>@<PC>.toml の [sshd] allowUsers・allowFrom。Install-Sshd が sshd_config の AllowUsers と Match Address に書く (null は既定)\",\n  \"allowUsers\": [\n    \"alice\"\n  ],\n  \"allowFrom\": null\n}\n";
        assert_eq!(copy_text(Some(&strings(&["alice"])), None), want);
        let t = copy_text(
            Some(&[]),
            Some(&strings(&["100.64.0.1", "fd7a:115c:a1e0::/48"])),
        );
        assert!(t.contains("\"allowUsers\": [],\n"), "{t}");
        assert!(
            t.contains("\"allowFrom\": [\n    \"100.64.0.1\",\n    \"fd7a:115c:a1e0::/48\"\n  ]\n"),
            "{t}"
        );
        assert!(!t.contains('\r') && !t.starts_with('\u{feff}'));
    }

    #[test]
    fn runner_host_places_the_values_and_skips_when_same() {
        let t = TempDir::new("sshd-allow");
        let host = format!(
            "{RUNNER}[sshd]\nallowUsers = [\"alice\"]\nallowFrom = [\"100.64.0.0/10\", \"127.0.0.1\"]\n"
        );
        // check・dry-run は書かない (check はホストの値を添える)
        let (o, _) = run(&t, &host, Mode::Check);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(
            o[0].text
                .starts_with("ユーザーと送り元の写しが無い → apply で置く"),
            "{}",
            o[0].text
        );
        assert!(
            o[0].notes.contains(
                &"ホストの値: allowUsers = alice・allowFrom = 100.64.0.0/10・127.0.0.1".to_string()
            ),
            "{:?}",
            o[0].notes
        );
        let (o, out) = run(&t, &host, Mode::DryRun { force: false });
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(out.contains("[dry-run] ユーザーと送り元の写しを置く (allowUsers = alice・allowFrom = 100.64.0.0/10・127.0.0.1)"), "{out}");
        assert!(!copy(&t).exists());
        // apply は置く (行は無い)
        let (o, out) = run(&t, &host, APPLY);
        assert!(o.is_empty(), "{o:?}");
        assert!(out.contains("ユーザーと送り元の写しを置きました"), "{out}");
        assert_eq!(
            std::fs::read_to_string(copy(&t)).unwrap(),
            copy_text(
                Some(&strings(&["alice"])),
                Some(&strings(&["100.64.0.0/10", "127.0.0.1"]))
            )
        );
        // 同じなら書かない・何も出さない
        let (o, out) = run(&t, &host, APPLY);
        assert!(o.is_empty() && out.is_empty(), "{o:?} {out}");
        let (o, _) = run(&t, &host, Mode::Check);
        assert!(o.is_empty());
        // 違えば check は差を出し、apply は書き直す
        std::fs::write(copy(&t), "{\"version\":1,\"allowUsers\":[\"mallory\"]}\n").unwrap();
        let (o, _) = run(&t, &host, Mode::Check);
        assert!(
            o[0].text
                .starts_with("ユーザーと送り元の写しがホストの値と違う"),
            "{}",
            o[0].text
        );
        run(&t, &host, APPLY);
        assert!(
            std::fs::read_to_string(copy(&t))
                .unwrap()
                .contains("\"alice\"")
        );
    }

    /// 片方だけ書けば、もう片方は null (Install-Sshd の既定)。[] は空の配列 (誰も・どこからも入れない)
    #[test]
    fn runner_host_writes_null_for_the_unwritten_side_and_keeps_empty_lists() {
        let t = TempDir::new("sshd-allow");
        let (o, out) = run(
            &t,
            &format!("{RUNNER}[sshd]\nallowFrom = [\"100.64.0.1\"]\n"),
            APPLY,
        );
        assert!(o.is_empty());
        assert!(out.contains("allowUsers は書いていない (既定: Install-Sshd を流したユーザー)・allowFrom = 100.64.0.1"), "{out}");
        assert_eq!(
            std::fs::read_to_string(copy(&t)).unwrap(),
            copy_text(None, Some(&strings(&["100.64.0.1"])))
        );
        let (o, out) = run(
            &t,
            &format!("{RUNNER}[sshd]\nallowUsers = []\nallowFrom = []\n"),
            APPLY,
        );
        assert!(o.is_empty());
        assert!(
            out.contains("allowUsers = [] (誰も入れない)・allowFrom = [] (どこからも入れない)"),
            "{out}"
        );
        assert_eq!(
            std::fs::read_to_string(copy(&t)).unwrap(),
            copy_text(Some(&[]), Some(&[]))
        );
    }

    #[test]
    fn runner_host_without_values_removes_the_copy() {
        let t = TempDir::new("sshd-allow");
        // 無ければ何もしない (鍵だけ書いたホストも同じ)
        let (o, out) = run(&t, RUNNER, APPLY);
        assert!(o.is_empty() && out.is_empty());
        let keys_only = format!("{RUNNER}[sshd]\nauthorizedKeys = []\n");
        let (o, out) = run(&t, &keys_only, APPLY);
        assert!(o.is_empty() && out.is_empty());
        std::fs::create_dir_all(copy(&t).parent().unwrap()).unwrap();
        std::fs::write(copy(&t), copy_text(Some(&strings(&["alice"])), None)).unwrap();
        let (o, _) = run(&t, &keys_only, Mode::Check);
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(o[0].text.contains("→ apply で消す"), "{}", o[0].text);
        let (o, out) = run(&t, &keys_only, Mode::DryRun { force: false });
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(out.contains("[dry-run] ユーザーと送り元の写しを消す"));
        assert!(copy(&t).exists());
        let (o, out) = run(&t, &keys_only, APPLY);
        assert!(o.is_empty());
        assert!(out.contains("ユーザーと送り元の写しを消しました"));
        assert!(!copy(&t).exists());
    }

    #[test]
    fn wsl_host_does_not_touch_the_copy() {
        let t = TempDir::new("sshd-allow");
        std::fs::create_dir_all(copy(&t).parent().unwrap()).unwrap();
        std::fs::write(copy(&t), "x\n").unwrap();
        let (o, out) = run(&t, "", APPLY);
        assert!(o.is_empty() && out.is_empty());
        let (o, out) = run(&t, "[sshd]\nallowUsers = [\"alice\"]\n", APPLY);
        assert!(o.is_empty());
        assert!(
            out.contains("[sshd] allowUsers・allowFrom は使わない"),
            "{out}"
        );
        assert_eq!(std::fs::read_to_string(copy(&t)).unwrap(), "x\n");
    }
}
