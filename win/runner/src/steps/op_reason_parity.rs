//! op-reason の手順 (ps1 の手順の型。`ps1::SPECS` の op-reason) を、WSL の `nix/scripts/bootstrap-windows-op-reason.sh` と突き合わせる試験。
//!
//! ## 確かめること
//!
//! WSL の版との突き合わせ (Linux。bash と jq があれば流れ、`DOTFILES_WIN_BASH_PARITY=1` なら無いと落ちる):
//! - WSL の script (setup の手順。引数なし) と runner の手順を、同じ偽の pwsh (`-Check` と揃える流れに、決めた出力と終了コードを返す) で流し、
//!   同じ判定 (揃っている・入れた・入れ替えた・入れられない・揃えられない・確かめられない) と終了コードになる。runner の check と dry-run は、WSL が
//!   `-Check` の後に進んだ道 (入れる・入れ替える) を missing・fix で出す
//! - 打った pwsh の引数と順が同じ (ps1 のパスと、runner だけが渡す SSH の中継の ` -SshRelay '<モード|off>'` のほかは 1 字も違わない)。check と
//!   dry-run は `-Check` だけを打つ。runner は記録を書かない
//! - SSH の中継を使うホスト (opReasonSshRelay = true) でも、runner は ` -SshRelay 'per-call'` を渡すほかは同じ判定・同じ知らせ・同じ呼び出し
//! - 手順の出力の行 (pwsh の出力を除く) が同じ字。揃えたときに見せる pwsh の出力も同じ (CRLF と色を落とす)
//! - 揃えられないときの直し方 (op の呼び出しが終わってから・PowerShell の Install-OpReason) と、確かめられないときに手で打つコマンドが同じ
//! - 対象の決め方: WSL の op の wrapper を入れないマシン (claude-op-reason.json の enable が false) と、ホストの値の onePassword が false の runner は、
//!   どちらも pwsh を打たずに飛ばす
//!
//! 本物の Install-OpReason.ps1 で (PATH に pwsh があれば。Windows の CI でも流れる):
//! - 置き場所 (`%LOCALAPPDATA%\Programs\op-reason`。一時ディレクトリに向ける) が無ければ missing、表のどの版とも合わない中身なら fix (runner が本物の
//!   状態の表の見出しと終了コードを読める)。check と dry-run だけを流す (落とさない。置き場所に書かない)
//! - (Linux で bash と jq があれば) WSL の script も、同じ本物の `-Check` から同じ判定になる (揃える流れは、偽物が打たずに断る)

use super::ps1::{Ps1Spec, Ps1Step, SPECS};
use super::{Mode, Step};
use crate::context::Ctx;
use crate::host::{Groups, parse};
use crate::manifest::Roots;
use crate::process::{CommandSpec, RealSys, RunResult, Sys};
use crate::report::{Kind, Row};
use crate::testutil::TempDir;
use std::path::{Path, PathBuf};

fn spec() -> &'static Ps1Spec {
    SPECS.iter().find(|s| s.id == "op-reason").unwrap()
}

/// ホストの値 (受け持ちは runner。apply も流す)
fn host(one_password: bool) -> String {
    format!("[tools]\nonePassword = {one_password}\n\n[runner]\nenable = true\n")
}

/// runner の外のコマンドの口: 本物の口で打ち、env を足す。`which` は pwsh だけを答える (Windows PowerShell へは落とさない)
struct TestSys {
    pwsh: Option<PathBuf>,
    envs: Vec<(String, String)>,
}

impl Sys for TestSys {
    fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
        let mut s = spec.clone();
        for (k, v) in &self.envs {
            s = s.env(k, v);
        }
        RealSys.run(&s, on_line)
    }

    fn which(&self, name: &str) -> Option<PathBuf> {
        if name == "pwsh" {
            self.pwsh.clone()
        } else {
            None
        }
    }

    fn env(&self, _name: &str) -> Option<String> {
        None
    }
}

/// runner の手順を流し (骨組みの execute で。on/off も見る)、締めの表の行と出力の行を返す。記録を書かないことも確かめる
fn run_runner(
    repo: &Path,
    root: &Path,
    sys: &TestSys,
    host: &str,
    mode: Mode,
) -> (Vec<Row>, Vec<String>) {
    let state = root.join("state");
    let mut out = Vec::new();
    let rows = {
        let mut ctx = Ctx {
            repo: repo.to_path_buf(),
            roots: Roots::from_home(&root.join("win-home")),
            state_dir: state.clone(),
            host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
            sys,
            out: &mut out,
        };
        let steps: Vec<Box<dyn Step>> = vec![Box::new(Ps1Step(spec()))];
        crate::runner::execute(&mut ctx, mode, &steps)
    };
    assert!(!state.exists(), "runner が記録を書いた");
    let lines = String::from_utf8(out)
        .unwrap()
        .lines()
        .map(str::to_string)
        .collect();
    (rows, lines)
}

/// 文の中の「終了コード <数>」の数
fn code_in(s: &str) -> Option<i32> {
    let rest = s.split("終了コード ").nth(1)?;
    rest.chars()
        .take_while(char::is_ascii_digit)
        .collect::<String>()
        .parse()
        .ok()
}

/// `-Check` の後に進む道 (runner の check と dry-run が出すもの)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Planned {
    Skipped,
    Ok,
    Install,
    Sync,
    CheckFailed(i32),
}

/// runner の check・dry-run の行から
fn runner_planned(rows: &[Row]) -> Planned {
    assert_eq!(rows.len(), 1, "{rows:?}");
    let r = &rows[0];
    let t = r.text.as_str();
    match r.kind {
        Kind::Off => Planned::Skipped,
        Kind::Ok if t == "揃っている" => Planned::Ok,
        Kind::Missing if t == "入っていない → apply で入れる (Install-OpReason.ps1)" => {
            Planned::Install
        }
        Kind::Fix if t == "固定した版と揃っていない → apply で揃える (Install-OpReason.ps1)" => {
            Planned::Sync
        }
        Kind::Failed
            if t.starts_with("Install-OpReason.ps1 -Check で確かめられなかった (終了コード ") =>
        {
            Planned::CheckFailed(code_in(t).unwrap())
        }
        _ => panic!("知らない行: {r:?}"),
    }
}

/// PATH の本物の pwsh (PowerShell 7)。無ければ None (試験を飛ばす)。WSL で流しても /mnt の下 (本物の Windows の pwsh) は探さない
fn real_pwsh() -> Option<PathBuf> {
    if cfg!(windows) {
        return RealSys.which("pwsh");
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .filter(|d| !d.starts_with("/mnt"))
        .map(|d| d.join("pwsh"))
        .find(|p| p.is_file())
}

/// 本物の Install-OpReason.ps1 の `-Check` を、置き場所を一時ディレクトリに向けて流す (PATH に pwsh が無ければ飛ばす。GitHub Actions の
/// ubuntu と windows の image にはある)。置き場所が無ければ missing、表のどの版とも合わない中身なら fix。落とさない・置き場所に書かない
#[test]
fn reads_the_state_table_of_the_real_ps1() {
    let Some(pwsh) = real_pwsh() else {
        return;
    };
    let t = TempDir::new("op-reason-real");
    let root = t.path().to_path_buf();
    let local = root.join("local");
    std::fs::create_dir_all(&local).unwrap();
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
    let sys = TestSys {
        pwsh: Some(pwsh),
        envs: vec![
            ("LOCALAPPDATA".into(), local.display().to_string()),
            ("HOME".into(), root.join("home").display().to_string()),
        ],
    };
    let (rows, out) = run_runner(&repo, &root, &sys, &host(true), Mode::Check);
    assert_eq!(runner_planned(&rows), Planned::Install, "{out:?}");
    assert_eq!(
        (rows[0].order, rows[0].id.as_str()),
        (Some(90), "op-reason")
    );
    assert!(!local.join("Programs").exists(), "置き場所を作った");

    // 表のどの版とも合わない中身 (入っている版が不明): 入れ替える道
    let dir = local.join("Programs").join("op-reason");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("README.txt"), "作り物\n").unwrap();
    let (rows, out) = run_runner(
        &repo,
        &root,
        &sys,
        &host(true),
        Mode::DryRun { force: false },
    );
    assert_eq!(runner_planned(&rows), Planned::Sync, "{out:?}");
    assert!(
        out.iter()
            .any(|l| l == "[dry-run] Install-OpReason.ps1 を流す (揃える)"),
        "{out:?}"
    );
    let names: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, vec!["README.txt"], "置き場所を変えた");
}

#[cfg(unix)]
mod wsl {
    use super::*;
    use crate::hooks::parity as bash;
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Command, Stdio};

    /// 偽の pwsh (WSL の pwsh.exe と runner の pwsh)。引数を FAKE_LOG に 1 行で足し、-Command の中の `' -Check;` (runner は
    /// `' -Check -SshRelay `) の有無で、FAKE_DIR の check.{out,rc} (-Check) か apply.{out,rc} (揃える流れ) から答える (出力は行ごとに
    /// CRLF。無ければ何も出さず 0)
    const FAKE_PWSH: &str = r#"printf '%s\n' "$*" >>"${FAKE_LOG}"
case $* in
  *"' -Check; exit "* | *"' -Check -SshRelay "*) f=${FAKE_DIR}/check ;;
  *) f=${FAKE_DIR}/apply ;;
esac
if [[ -e ${f}.out ]]; then
  while IFS= read -r l || [[ -n ${l} ]]; do printf '%s\r\n' "${l}"; done <"${f}.out"
fi
rc=0
[[ ! -e ${f}.rc ]] || rc=$(<"${f}.rc")
exit "${rc}"
"#;

    /// WSL の script が Windows のパスに直した、配った Install-OpReason.ps1 (偽の wslpath が返す)
    const WIN_PS1: &str = r"C:\Users\tester\.config\powershell\Install-OpReason.ps1";

    /// 打った pwsh の引数 (ps1 のパスは <ps1> にしたもの)
    const CHECK_CALL: &str = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command [Console]::OutputEncoding = [Text.Encoding]::UTF8; $global:LASTEXITCODE = 2; & '<ps1>' -Check; exit $LASTEXITCODE";
    const APPLY_CALL: &str = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command [Console]::OutputEncoding = [Text.Encoding]::UTF8; $global:LASTEXITCODE = 2; & '<ps1>'; exit $LASTEXITCODE";

    /// WSL の script が出す字 (nix/scripts/bootstrap-windows-op-reason.sh)
    const WSL_OK: &str = "Windows の op-reason は、dotfiles で固定した版に揃っています。";
    const WSL_INSTALLED: &str = "Windows に op-reason を入れました (%LOCALAPPDATA%\\Programs\\op-reason。WSL の op が OPREASON_EXE で使う)。";
    const WSL_SYNCED: &str = "Windows の op-reason を、dotfiles で固定した版に揃えました。";
    const WSL_INSTALL_FAILED: &str = "⚠️  Windows に op-reason を入れられませんでした (終了コード ";
    const WSL_SYNC_FAILED: &str =
        "⚠️  Windows の op-reason を、dotfiles で固定した版に揃えられませんでした (終了コード ";
    const WSL_CHECK_FAILED: &str =
        "!! pwsh.exe で Windows の op-reason を確かめられませんでした (終了コード ";
    const WSL_SKIPPED: &str = "このマシンには WSL の op の wrapper (op-reason) を入れません";

    /// 揃えられないときの直し方で、WSL と runner が同じ字で添えること
    const WHILE_BUSY: &str = "(op-reason.exe が動いているときは、op の呼び出しが終わってから)";

    /// runner のホストの値の SSH の中継の switch (opReasonSshRelay)
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Relay {
        Off,
        On,
    }

    /// runner だけが渡す SSH の中継の引数 (WSL の script は渡さない)。どの呼び出しにもあることを確かめてから外す
    fn without_relay(calls: Vec<String>, relay: Relay) -> Vec<String> {
        let arg = match relay {
            Relay::Off => " -SshRelay 'off'",
            Relay::On => " -SshRelay 'per-call'",
        };
        calls
            .into_iter()
            .map(|c| {
                assert!(c.contains(arg), "runner が{arg} を渡していない: {c}");
                c.replacen(arg, "", 1)
            })
            .collect()
    }

    /// 手順が最後にどうなったか
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Verdict {
        /// 流さなかった (対象の外・off)
        Skipped,
        Ok,
        Installed,
        Synced,
        InstallFailed(i32),
        SyncFailed(i32),
        CheckFailed(i32),
    }

    impl Verdict {
        fn planned(self) -> Planned {
            match self {
                Verdict::Skipped => Planned::Skipped,
                Verdict::Ok => Planned::Ok,
                Verdict::Installed | Verdict::InstallFailed(_) => Planned::Install,
                Verdict::Synced | Verdict::SyncFailed(_) => Planned::Sync,
                Verdict::CheckFailed(c) => Planned::CheckFailed(c),
            }
        }
    }

    /// runner の apply の行から
    fn runner_verdict(rows: &[Row]) -> Verdict {
        assert_eq!(rows.len(), 1, "{rows:?}");
        let r = &rows[0];
        let t = r.text.as_str();
        match r.kind {
            Kind::Off => Verdict::Skipped,
            Kind::Ok if t == "揃っている" => Verdict::Ok,
            Kind::Ok if t == "入れた" => Verdict::Installed,
            Kind::Ok if t == "揃えた" => Verdict::Synced,
            Kind::Failed if t.starts_with("入れられなかった (終了コード ") => {
                Verdict::InstallFailed(code_in(t).unwrap())
            }
            Kind::Failed if t.starts_with("揃えられなかった (終了コード ") => {
                Verdict::SyncFailed(code_in(t).unwrap())
            }
            Kind::Failed
                if t.starts_with(
                    "Install-OpReason.ps1 -Check で確かめられなかった (終了コード ",
                ) =>
            {
                Verdict::CheckFailed(code_in(t).unwrap())
            }
            _ => panic!("知らない行: {r:?}"),
        }
    }

    /// 偽の pwsh の答え (終了コードと、行ごとの出力)
    type Answer = (i32, String);

    /// WSL と runner を同じ偽の pwsh で流す組
    struct World {
        _t: TempDir,
        root: PathBuf,
        sys_bin: PathBuf,
        fake_bin: PathBuf,
        /// runner の clone
        repo: PathBuf,
        /// WSL の HOME (windows-files.json・claude-op-reason.json)
        wsl_home: PathBuf,
        /// 配った Install-OpReason.ps1 (WSL の script が見る)
        deployed: PathBuf,
        /// 足す env (WSL の script にも runner の pwsh にも)
        envs: Vec<(String, String)>,
        /// WSL の script が pwsh.exe に渡す ps1 のパス
        wsl_ps1: String,
    }

    impl World {
        /// `real` が無ければ偽の pwsh (FAKE_DIR から答える)。あれば本物の pwsh で -Check だけを流し、揃える流れは打たずに断る偽物
        /// (本物の Install-OpReason.ps1 を配って、runner は本物の clone の ps1 を読む)
        fn new(real: Option<&Path>) -> Option<World> {
            if !bash::available() {
                return None;
            }
            let t = TempDir::new("op-reason-parity");
            let root = std::fs::canonicalize(t.path()).unwrap();
            let sys_bin = root.join("sys-bin");
            let fake_bin = root.join("fake-bin");
            std::fs::create_dir_all(&sys_bin).unwrap();
            std::fs::create_dir_all(&fake_bin).unwrap();
            // WSL の本物の pwsh.exe と wslpath を見せない (要るコマンドだけを並べた PATH。/mnt の下は探さない)
            let path = std::env::var_os("PATH").unwrap_or_default();
            for c in [
                "bash", "env", "jq", "grep", "sed", "tr", "cat", "dirname", "timeout",
            ] {
                let found = std::env::split_paths(&path)
                    .filter(|d| !d.starts_with("/mnt"))
                    .map(|d| d.join(c))
                    .find(|p| p.is_file())
                    .unwrap_or_else(|| panic!("{c} が無い"));
                std::os::unix::fs::symlink(found, sys_bin.join(c)).unwrap();
            }
            let wsl_home = root.join("wsl-home");
            let win_home = root.join("win-home");
            let deployed = win_home
                .join(".config")
                .join("powershell")
                .join("Install-OpReason.ps1");
            std::fs::create_dir_all(deployed.parent().unwrap()).unwrap();
            let real_ps1 = bash::repo_file(spec().script);
            let (repo, wsl_ps1, pwsh_body) = match real {
                None => {
                    let repo = root.join("repo");
                    let ps1 = crate::context::join_segments(&repo, spec().script);
                    std::fs::create_dir_all(ps1.parent().unwrap()).unwrap();
                    std::fs::write(&ps1, "# 作り物\n").unwrap();
                    std::fs::write(&deployed, "# 作り物\n").unwrap();
                    (repo, WIN_PS1.to_string(), FAKE_PWSH.to_string())
                }
                Some(pwsh) => {
                    std::fs::copy(&real_ps1, &deployed).unwrap();
                    let repo = std::fs::canonicalize(bash::repo_file("")).unwrap();
                    let body = format!(
                        "printf '%s\\n' \"$*\" >>\"${{FAKE_LOG}}\"\ncase $* in\n  *\"' -Check; exit \"* | *\"' -Check -SshRelay \"*) exec '{}' \"$@\" ;;\nesac\nprintf '%s\\n' '(試験のため、揃える流れは打たない)'\nexit 1\n",
                        pwsh.display()
                    );
                    (repo, deployed.display().to_string(), body)
                }
            };
            let bash_path = sys_bin.join("bash");
            let wslpath = format!("[[ $1 == -w ]] || exit 1\nprintf '%s\\n' '{}'\n", wsl_ps1);
            for (name, body) in [
                ("pwsh.exe", pwsh_body.as_str()),
                ("pwsh", pwsh_body.as_str()),
                ("wslpath", wslpath.as_str()),
            ] {
                let f = fake_bin.join(name);
                std::fs::write(&f, format!("#!{}\n{body}", bash_path.display())).unwrap();
                std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            let fx = root.join("fx");
            let local = root.join("local");
            for d in [&fx, &local, &wsl_home.join(".local/state/dotfiles")] {
                std::fs::create_dir_all(d).unwrap();
            }
            std::fs::write(
                wsl_home.join(".local/state/dotfiles/windows-files.json"),
                serde_json::json!({"enable": true, "version": 1, "windowsHome": win_home.display().to_string()})
                    .to_string(),
            )
            .unwrap();
            let envs = vec![
                ("FAKE_DIR".to_string(), fx.display().to_string()),
                ("LOCALAPPDATA".to_string(), local.display().to_string()),
                ("LC_ALL".to_string(), "C.UTF-8".to_string()),
            ];
            let w = World {
                _t: t,
                root,
                sys_bin,
                fake_bin,
                repo,
                wsl_home,
                deployed,
                envs,
                wsl_ps1,
            };
            w.op_reason(true);
            Some(w)
        }

        /// WSL の op の wrapper を入れるマシンか (claude-op-reason.json の enable)
        fn op_reason(&self, enable: bool) {
            std::fs::write(
                self.wsl_home
                    .join(".local/state/dotfiles/claude-op-reason.json"),
                serde_json::json!({ "enable": enable }).to_string(),
            )
            .unwrap();
        }

        /// 偽の pwsh の答え (`-Check` と、揃える流れ。出力は行ごと)
        fn answer(&self, check: (i32, &str), apply: (i32, &str)) {
            let fx = self.root.join("fx");
            for (kind, (rc, out)) in [("check", check), ("apply", apply)] {
                std::fs::write(fx.join(format!("{kind}.out")), out).unwrap();
                std::fs::write(fx.join(format!("{kind}.rc")), rc.to_string()).unwrap();
            }
        }

        fn local(&self) -> PathBuf {
            self.root.join("local")
        }

        /// 打たれた pwsh の引数 (ps1 のパスを <ps1> にして)
        fn calls(&self, side: &str, ps1: &str) -> Vec<String> {
            let log = self.root.join(format!("{side}.log"));
            let calls = std::fs::read_to_string(&log)
                .unwrap_or_default()
                .lines()
                .map(|l| l.replace(ps1, "<ps1>"))
                .collect();
            let _ = std::fs::remove_file(&log);
            calls
        }

        /// WSL の setup の手順を流す (stdout の行・stderr の行・打った pwsh の引数)。setup の手順はどれも exit 0
        fn wsl(&self) -> (Vec<String>, Vec<String>, Vec<String>) {
            let mut c = Command::new(self.sys_bin.join("bash"));
            c.arg(bash::repo_file(
                "nix/scripts/bootstrap-windows-op-reason.sh",
            ))
            .env_clear()
            .env("HOME", &self.wsl_home)
            .env(
                "PATH",
                format!("{}:{}", self.fake_bin.display(), self.sys_bin.display()),
            )
            .env("FAKE_LOG", self.root.join("wsl.log"))
            .stdin(Stdio::null());
            for (k, v) in &self.envs {
                c.env(k, v);
            }
            let o = c.output().unwrap();
            let lines = |b: &[u8]| -> Vec<String> {
                String::from_utf8_lossy(b)
                    .lines()
                    .map(str::to_string)
                    .collect()
            };
            let (stdout, stderr) = (lines(&o.stdout), lines(&o.stderr));
            assert_eq!(o.status.code(), Some(0), "{stdout:?} {stderr:?}");
            (stdout, stderr, self.calls("wsl", &self.wsl_ps1))
        }

        /// runner の手順を流す (締めの表の行・出力の行・打った pwsh の引数。runner だけが渡す -SshRelay は外して返す)
        fn runner(
            &self,
            mode: Mode,
            one_password: bool,
            relay: Relay,
        ) -> (Vec<Row>, Vec<String>, Vec<String>) {
            let mut envs = self.envs.clone();
            envs.push((
                "FAKE_LOG".to_string(),
                self.root.join("rn.log").display().to_string(),
            ));
            envs.push((
                "HOME".to_string(),
                self.root.join("rn-home").display().to_string(),
            ));
            let sys = TestSys {
                pwsh: Some(self.fake_bin.join("pwsh")),
                envs,
            };
            let host_text = match relay {
                Relay::Off => host(one_password),
                Relay::On => host(one_password).replacen(
                    "[tools]\n",
                    "[tools]\nopReasonSshRelay = true\n",
                    1,
                ),
            };
            let (rows, out) = run_runner(&self.repo, &self.root, &sys, &host_text, mode);
            let ps1 = crate::context::join_segments(&self.repo, spec().script)
                .display()
                .to_string();
            (rows, out, without_relay(self.calls("rn", &ps1), relay))
        }
    }

    /// WSL の出力の行から
    fn wsl_verdict(stdout: &[String], stderr: &[String]) -> Verdict {
        let has = |lines: &[String], text: &str| lines.iter().any(|l| l == text);
        let failed = |head: &str| {
            stderr
                .iter()
                .find(|l| l.starts_with(head))
                .and_then(|l| code_in(l))
        };
        if has(stdout, WSL_OK) {
            Verdict::Ok
        } else if has(stdout, WSL_INSTALLED) {
            Verdict::Installed
        } else if has(stdout, WSL_SYNCED) {
            Verdict::Synced
        } else if let Some(c) = failed(WSL_INSTALL_FAILED) {
            Verdict::InstallFailed(c)
        } else if let Some(c) = failed(WSL_SYNC_FAILED) {
            Verdict::SyncFailed(c)
        } else if let Some(c) = failed(WSL_CHECK_FAILED) {
            Verdict::CheckFailed(c)
        } else if stdout.iter().any(|l| l.starts_with(WSL_SKIPPED)) {
            Verdict::Skipped
        } else {
            panic!("WSL の出力が読めない: {stdout:?} {stderr:?}")
        }
    }

    /// 手順の行 (pwsh の出力を除く。WSL は 2 字、runner は 4 字下げて pwsh の出力を出す。runner の手順の見出しも除く)
    fn notices(lines: &[String], indent: &str) -> Vec<String> {
        lines
            .iter()
            .filter(|l| !l.is_empty() && !l.starts_with(indent) && !l.starts_with("━━ "))
            .cloned()
            .collect()
    }

    /// 字下げして出した pwsh の出力 (字下げを外して)
    fn shown(lines: &[String], indent: &str) -> Vec<String> {
        lines
            .iter()
            .filter_map(|l| l.strip_prefix(indent))
            .map(str::to_string)
            .collect()
    }

    /// 1 つの答えで WSL と runner (check・dry-run・apply) を流して突き合わせ、判定を返す
    fn same(w: &World, name: &str) -> Verdict {
        same_on(w, name, Relay::Off)
    }

    /// `same` を、runner のホストの値の SSH の中継の switch を決めて流す
    fn same_on(w: &World, name: &str, relay: Relay) -> Verdict {
        let (stdout, stderr, wsl_calls) = w.wsl();
        let v = wsl_verdict(&stdout, &stderr);
        let want_calls: Vec<&str> = match v {
            Verdict::Skipped => vec![],
            Verdict::Ok | Verdict::CheckFailed(_) => vec![CHECK_CALL],
            _ => vec![CHECK_CALL, APPLY_CALL],
        };
        assert_eq!(wsl_calls, want_calls, "{name}: WSL が打った pwsh");

        let (rows, out, calls) =
            w.runner(Mode::Apply { force: false }, v != Verdict::Skipped, relay);
        assert_eq!(runner_verdict(&rows), v, "{name}: {rows:?}\n{out:?}");
        assert_eq!(calls, wsl_calls, "{name}: runner の apply が打った pwsh");
        if v != Verdict::Skipped {
            assert_eq!(
                notices(&out, "    "),
                notices(&stdout, "  "),
                "{name}: 手順の行"
            );
        }
        match v {
            Verdict::Installed | Verdict::Synced => {
                // WSL は揃える流れの出力を見せる。runner は -Check の出力に続けて流す
                let wsl_shown = shown(&stdout, "  ");
                let rn_shown = shown(&out, "    ");
                assert!(!wsl_shown.is_empty(), "{name}");
                assert!(
                    rn_shown.ends_with(&wsl_shown),
                    "{name}: 見せた pwsh の出力\n{rn_shown:?}\n{wsl_shown:?}"
                );
            }
            Verdict::InstallFailed(_) | Verdict::SyncFailed(_) => {
                assert!(
                    stderr
                        .iter()
                        .any(|l| l.contains(WHILE_BUSY) && l.contains("揃えるには"))
                        && stderr
                            .iter()
                            .any(|l| l.trim_end().ends_with("PowerShell: Install-OpReason")),
                    "{name}: WSL の直し方 {stderr:?}"
                );
                assert!(
                    rows[0].notes.iter().any(|n| n.contains(WHILE_BUSY)
                        && n.contains("PowerShell で Install-OpReason を打つ")),
                    "{name}: runner の直し方 {:?}",
                    rows[0].notes
                );
            }
            Verdict::CheckFailed(_) => {
                assert!(
                    stderr.iter().any(|l| l.trim() == "Install-OpReason -Check"),
                    "{name}: WSL の手で打つコマンド {stderr:?}"
                );
                assert!(
                    rows[0]
                        .notes
                        .iter()
                        .any(|n| n.contains("PowerShell で Install-OpReason -Check を打つ")),
                    "{name}: runner の手で打つコマンド {:?}",
                    rows[0].notes
                );
            }
            _ => {}
        }

        // check と dry-run は -Check だけを打ち、WSL が進んだ道を出す
        for mode in [Mode::Check, Mode::DryRun { force: false }] {
            let (rows, out, calls) = w.runner(mode, v != Verdict::Skipped, relay);
            assert_eq!(
                runner_planned(&rows),
                v.planned(),
                "{name} {mode:?}: {out:?}"
            );
            assert_eq!(
                calls,
                wsl_calls[..wsl_calls.len().min(1)],
                "{name} {mode:?}"
            );
            let dry = out.iter().find(|l| l.starts_with("[dry-run] "));
            let want = match (mode, v.planned()) {
                (Mode::DryRun { .. }, Planned::Install) => {
                    Some("[dry-run] Install-OpReason.ps1 を流す (入れる)")
                }
                (Mode::DryRun { .. }, Planned::Sync) => {
                    Some("[dry-run] Install-OpReason.ps1 を流す (揃える)")
                }
                _ => None,
            };
            assert_eq!(dry.map(String::as_str), want, "{name} {mode:?}");
        }
        v
    }

    const DIR: &str = r"C:\Users\tester\AppData\Local\Programs\op-reason";

    /// Install-OpReason.ps1 の状態の表 (入っている版・固定した版の行と、続く行)
    fn table(installed: &str, plan: &str, rest: &[&str]) -> String {
        let mut s = format!(
            "op-reason (GitHub の Release、{DIR})\n  入っている版     : {installed}\n{plan}\n"
        );
        for l in rest {
            s.push_str(l);
            s.push('\n');
        }
        s
    }

    fn drift(rest: &[&str]) -> String {
        table(
            "0.0.9",
            "⚠ 固定した版       : 0.3.0 → 入れ替える (上げる)",
            rest,
        )
    }

    fn missing() -> String {
        table(
            "入っていない",
            "⚠ 固定した版       : 0.3.0 → 入れる",
            &["⚠️ op-reason が入っていない → Install-OpReason で入れる ⚠️"],
        )
    }

    fn applied() -> String {
        format!(
            "{}落とす: https://github.com/pollenjp/op-reason/releases/download/v0.3.0/op-reason-windows.zip\n置いた: {DIR}\n\n{}揃った\n",
            drift(&[]),
            table("0.3.0", "  固定した版       : 0.3.0 → そのまま", &[])
        )
    }

    const BUSY: &str = "※ op-reason.exe が 1 個動いている (op の呼び出しの途中)。入れ替えるには、その呼び出しが終わってから打ち直す (このスクリプトは止めない)";
    const SYNC_LINE: &str = "⚠️ 固定した版と揃っていない → Install-OpReason で揃える ⚠️";

    /// 同じ -Check の答えから、同じ判定・同じ知らせ・同じ pwsh の呼び出し (WSL の試験 nix/tests/bootstrap-windows-op-reason.test.sh のケース)
    #[test]
    fn matches_the_wsl_script() {
        let Some(w) = World::new(None) else {
            return;
        };
        let synced = table(
            "0.3.0",
            "  固定した版       : 0.3.0 → そのまま",
            &["揃っている"],
        );
        let busy_out = drift(&[
            BUSY,
            "op-reason.exe が動いていて置き場所を入れ替えられない。op の呼び出しが終わってから打ち直す (このスクリプトは止めない):",
            r"  4242  C:\Users\tester\AppData\Local\Programs\op-reason\op-reason.exe",
        ]);
        let cases: Vec<(&str, Answer, Answer, Verdict)> = vec![
            (
                "揃っている",
                (0, synced.clone()),
                (9, String::new()),
                Verdict::Ok,
            ),
            // 0 なら見出しは見ない
            (
                "見出しの無い 0",
                (0, "揃っている\n".into()),
                (9, String::new()),
                Verdict::Ok,
            ),
            (
                "差 → 入れ替えた",
                (1, drift(&[SYNC_LINE])),
                (0, applied()),
                Verdict::Synced,
            ),
            // 1 なら締めの行は見ない
            (
                "締めの行の無い 1 → 入れ替えた",
                (1, drift(&[])),
                (0, applied()),
                Verdict::Synced,
            ),
            (
                "無い → 入れた",
                (3, missing()),
                (0, applied()),
                Verdict::Installed,
            ),
            (
                "無い → 入れられない",
                (3, missing()),
                (
                    1,
                    "zip の SHA-256 が固定した値と合わないので置かない (何も変えていない)\n".into(),
                ),
                Verdict::InstallFailed(1),
            ),
            (
                "動いている → 入れ替えられない",
                (1, drift(&[BUSY, SYNC_LINE])),
                (1, busy_out),
                Verdict::SyncFailed(1),
            ),
            (
                "差 → エラーで止まった",
                (1, drift(&[SYNC_LINE])),
                (
                    2,
                    "エラーで止まった: The remote name could not be resolved\n".into(),
                ),
                Verdict::SyncFailed(2),
            ),
            (
                "1 だが見出しが無い",
                (
                    1,
                    "The term is not recognized as a name of a cmdlet\n".into(),
                ),
                (0, applied()),
                Verdict::CheckFailed(1),
            ),
            (
                "3 だが見出しが無い",
                (3, "Exec format error\n".into()),
                (0, applied()),
                Verdict::CheckFailed(3),
            ),
            (
                "起こせない",
                (126, String::new()),
                (0, applied()),
                Verdict::CheckFailed(126),
            ),
            (
                "見出しはあるが 2",
                (2, format!("{}エラーで止まった: 何か\n", drift(&[]))),
                (0, applied()),
                Verdict::CheckFailed(2),
            ),
        ];
        for (name, check, apply, want) in cases {
            w.answer((check.0, &check.1), (apply.0, &apply.1));
            assert_eq!(same(&w, name), want, "{name}");
        }

        // pwsh の出力の色と CRLF は、どちらも落として見せる
        let colored = format!(
            "{}\u{1b}[33m⚠ 固定した版       : 0.3.0 → そのまま\u{1b}[0m\n揃った\n",
            table("0.3.0", "  固定した版       : 0.3.0 → そのまま", &[])
        );
        w.answer((1, &drift(&[SYNC_LINE])), (0, &colored));
        assert_eq!(same(&w, "色"), Verdict::Synced);
        let (stdout, _, _) = w.wsl();
        let want = vec![
            format!("op-reason (GitHub の Release、{DIR})"),
            "  入っている版     : 0.3.0".to_string(),
            "  固定した版       : 0.3.0 → そのまま".to_string(),
            "⚠ 固定した版       : 0.3.0 → そのまま".to_string(),
            "揃った".to_string(),
        ];
        assert_eq!(shown(&stdout, "  "), want);
        let (_, out, _) = w.runner(Mode::Apply { force: false }, true, Relay::Off);
        assert!(shown(&out, "    ").ends_with(&want), "{out:?}");
        assert!(!out.iter().any(|l| l.contains('\u{1b}') || l.contains('\r')));

        // 対象の外: WSL の op の wrapper を入れないマシンと、onePassword が false の runner は pwsh を打たない
        w.op_reason(false);
        w.answer((0, &synced), (0, &applied()));
        assert_eq!(same(&w, "対象の外"), Verdict::Skipped);
    }

    /// SSH の中継を使うホストでも、runner は ` -SshRelay 'per-call'` を渡すほかは WSL の script と同じ (WSL の setup は中継に触らない)
    #[test]
    fn matches_the_wsl_script_with_the_relay_on() {
        let Some(w) = World::new(None) else {
            return;
        };
        let synced = table(
            "0.3.0",
            "  固定した版       : 0.3.0 → そのまま",
            &["揃っている"],
        );
        let cases: Vec<(&str, Answer, Answer, Verdict)> = vec![
            (
                "中継: 揃っている",
                (0, synced),
                (9, String::new()),
                Verdict::Ok,
            ),
            (
                "中継: 差 → 入れ替えた",
                (1, drift(&[SYNC_LINE])),
                (0, applied()),
                Verdict::Synced,
            ),
            (
                "中継: 無い → 入れた",
                (3, missing()),
                (0, applied()),
                Verdict::Installed,
            ),
            (
                "中継: 動いている → 入れ替えられない",
                (1, drift(&[BUSY, SYNC_LINE])),
                (1, drift(&[BUSY])),
                Verdict::SyncFailed(1),
            ),
        ];
        for (name, check, apply, want) in cases {
            w.answer((check.0, &check.1), (apply.0, &apply.1));
            assert_eq!(same_on(&w, name, Relay::On), want, "{name}");
        }
    }

    /// 本物の Install-OpReason.ps1 の -Check で、WSL の script と runner が同じ判定になる (揃える流れは偽物が打たずに断る)。PATH に pwsh が
    /// 無ければ飛ばす
    #[test]
    fn matches_the_wsl_script_with_the_real_check() {
        let Some(pwsh) = real_pwsh() else {
            return;
        };
        let Some(w) = World::new(Some(&pwsh)) else {
            return;
        };
        assert_eq!(
            std::fs::read(&w.deployed).unwrap(),
            std::fs::read(bash::repo_file(spec().script)).unwrap()
        );
        // 置き場所が無い: 入れに行き、偽物が断る
        assert_eq!(same(&w, "本物: 無い"), Verdict::InstallFailed(1));
        assert!(!w.local().join("Programs").exists(), "置き場所を作った");
        // 表のどの版とも合わない中身: 入れ替えに行き、偽物が断る
        let dir = w.local().join("Programs").join("op-reason");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("README.txt"), "作り物\n").unwrap();
        assert_eq!(same(&w, "本物: 合わない"), Verdict::SyncFailed(1));
        assert_eq!(
            std::fs::read_dir(&dir).unwrap().count(),
            1,
            "置き場所を変えた"
        );
    }
}
