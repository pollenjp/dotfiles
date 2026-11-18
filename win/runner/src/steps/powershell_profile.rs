//! powershell-profile (order 95): win/ から配った PowerShell の共有設定 (`dotfiles.ps1`) を、PowerShell 7 の `$PROFILE` から読ませる。WSL の
//! `nix/scripts/bootstrap-windows-powershell-profile.sh` を写したもの (書く行・書く先・記録・判定と文言をそろえる。受け持ちを runner に切り替えた
//! 後に、WSL の setup が足した行と同じものとして引き継ぐため)。
//!
//! `dotfiles.ps1` は files の手順が `%USERPROFILE%\.config\powershell\` へ配るが、PowerShell が自分で読むのは `$PROFILE` だけ。`$PROFILE` は
//! ドキュメントの下にあり、ドキュメントの位置は OneDrive の設定でマシンごとに変わるので、manifest の dst には書けない。そこで pwsh に `$PROFILE`
//! (CurrentUserCurrentHost) の場所を聞き、`dotfiles.ps1` を読む 1 行 (`LINE`) が無ければ足す:
//!
//! | `$PROFILE` | すること | 行の種類 (apply の前) |
//! | --- | --- | --- |
//! | `dotfiles.ps1` を読む行がある (書き方が違っても `.config\powershell\dotfiles.ps1` を含めばよい。頭に `#` を付けた行も) | 何もしない (記録が無ければ記録だけする) | ok |
//! | 行が無く、足した記録も無い | 1 行を足して記録する (`$PROFILE` が無ければ親ごと作る) | missing |
//! | 行が無いが、足した記録がある | Windows 側で外したものとして足し直さない (`--force` なら足す) | manual |
//! | UTF-16 | 書かない (ASCII を足すと壊れる) | manual |
//!
//! - 改行はファイルに合わせ (CR があれば CRLF)、末尾に改行が無ければ先に補う。書くのはファイルの末尾への追記 (WSL の `>>` と同じ。OneDrive が
//!   同期するファイルを置き換えない)
//! - 記録は `%LOCALAPPDATA%\dotfiles\state\windows-powershell-profile.json` (`$PROFILE` の Windows のパス → `"added"`)。名前と形は WSL の
//!   `~/.local/state/dotfiles/windows-powershell-profile.json` と同じで、鍵だけが Windows のパス。WSL の記録は読まない (dotfiles-private の
//!   docs/adr/058_win_runner_bootstrap_* §2 H。行があれば記録は作り直せる): 受け持ちを runner に切り替えた後の初めての apply は、WSL の setup が
//!   足した行を見て記録だけ作る (行を二重にしない)
//! - `dotfiles.ps1` がまだ無ければ飛ばす (files の手順が置いてから)。Windows PowerShell 5.1 の `$PROFILE` は扱わない (5.1 は実行ポリシーの既定が
//!   Restricted で、足しても読まれない。実行ポリシーはセキュリティの設定なので変えない。WSL と同じ)
//! - 自動で足せないとき (pwsh が無い・聞けない・UTF-16) は、同じ 1 行を手で足す `Add-Content` を添える

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::{Ctx, join_segments};
use crate::process::{CommandSpec, Exit};
use crate::record::Records;
use crate::report::Kind;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// 記録のファイル名 (WSL の `~/.local/state/dotfiles/` の記録と同じ名前)
pub const RECORD_FILE: &str = "windows-powershell-profile.json";
/// `$PROFILE` に足す 1 行 (WSL の script の `line` と同じ)。dotfiles.ps1 が無い PC (OneDrive の同期で `$PROFILE` だけが届いた PC など) でも
/// エラーを出さないよう `Test-Path` で囲む。`&` で呼ぶと子の scope で定義されて呼び終わりに消えるので dot-source で読む。`$HOME` は PowerShell が
/// 展開する
const LINE: &str = r#"if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }"#;
/// 「読む行がある」の判定 (WSL の script の `marker`)。書き方が違っても dotfiles.ps1 を指していればよい
const MARKER: &str = r".config\powershell\dotfiles.ps1";
/// files の手順が配る dotfiles.ps1 (ホームからの相対)
const DEPLOYED: &str = ".config/powershell/dotfiles.ps1";
/// pwsh に `$PROFILE` の場所を聞く式 (WSL と同じ。出力は UTF-8 にする (ドキュメントが化けないよう))
const QUERY: &str =
    "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $PROFILE.CurrentUserCurrentHost";
/// 聞くのを待つ上限 (WSL の `timeout 60`)
const QUERY_SECS: u64 = 60;
/// 記録の値 (足した・既にあった)
const ADDED: &str = "added";
/// 記録が壊れていたときの直し方 (WSL と同じ)
const BROKEN_HINT: &str = "消してから流し直してください (足した記録が無いものとして扱います)";

pub struct PowershellProfile;

impl Step for PowershellProfile {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "powershell-profile",
            order: 95,
            title: "$PROFILE から dotfiles.ps1 を読ませる",
            gate: Gate::Always,
            ported: true,
            windows_only: false,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode)]
    }
}

/// 手順の中身。WSL の script と同じ順に確かめる (dotfiles.ps1 → 記録 → pwsh → 読む行 → 足した記録 → UTF-16 → 足す)。
fn sync(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let deployed = join_segments(&ctx.roots.user_profile, DEPLOYED);
    if !deployed.is_file() {
        ctx.say(format!(
            "dotfiles.ps1 がまだ配られていません ({})。この手順は飛ばします。",
            deployed.display()
        ));
        return Outcome::new(
            Kind::Info,
            "dotfiles.ps1 がまだ無いので飛ばした (files の手順が置いてから $PROFILE に足す)",
        );
    }
    let record_path = ctx.state_dir.join(RECORD_FILE);
    let mut records = match Records::load_with(&record_path, BROKEN_HINT) {
        Ok(r) => r,
        Err(e) => {
            ctx.say(format!("!! {e}"));
            return Outcome::new(Kind::Failed, "足した記録が壊れている").note(e);
        }
    };
    let Some(pwsh) = ctx.sys.which("pwsh") else {
        warn(
            ctx,
            &with_manual(vec![
                "pwsh が見つかりません (PowerShell 7 が無いか、PATH に入っていない)。".to_string(),
            ]),
        );
        return Outcome::new(
            Kind::Manual,
            "PowerShell 7 (pwsh) が見つからないので $PROFILE の場所を聞けない",
        )
        .note(manual_note());
    };
    let r = ctx.sys.run(&query_command(pwsh), &mut |_| {});
    // 警告の続きの行に並べる pwsh の出力 (空の行は出さない)
    let shown = r.output.iter().filter(|l| !l.trim().is_empty()).cloned();
    let failure = match &r.exit {
        Exit::Code(0) => None,
        Exit::Code(c) => Some(format!("終了コード {c}")),
        Exit::NoCode => Some("終了コードが無い".to_string()),
        Exit::TimedOut => Some(format!("{QUERY_SECS} 秒たっても終わらなかった")),
        Exit::SpawnFailed(e) => Some(format!("起こせなかった: {e}")),
    };
    if let Some(why) = failure {
        let mut lines = vec![format!(
            "pwsh に $PROFILE の場所を聞けませんでした ({why}):"
        )];
        lines.extend(shown);
        warn(ctx, &with_manual(lines));
        return Outcome::new(
            Kind::Failed,
            format!("pwsh に $PROFILE の場所を聞けなかった ({why})"),
        )
        .note(manual_note());
    }
    let Some(win_profile) = profile_path(&r.output) else {
        let mut lines = vec!["pwsh が $PROFILE の場所を返しませんでした:".to_string()];
        lines.extend(shown);
        warn(ctx, &with_manual(lines));
        return Outcome::new(Kind::Failed, "pwsh が $PROFILE の場所を返さなかった")
            .note(manual_note());
    };
    let profile = PathBuf::from(&win_profile);
    if profile.is_dir() {
        ctx.say(format!(
            "!! $PROFILE の場所がディレクトリです: {win_profile}"
        ));
        return Outcome::new(Kind::Failed, "$PROFILE の場所がディレクトリ").note(format!(
            "{win_profile} を確かめる (PowerShell 7 で $PROFILE を打つと、同じ場所が出る)"
        ));
    }
    let current = match std::fs::read(&profile) {
        Ok(b) => Some(b),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            ctx.say(format!("!! $PROFILE が読めません: {win_profile} ({e})"));
            return Outcome::new(Kind::Failed, format!("$PROFILE が読めない ({e})"));
        }
    };
    let recorded = records.get(&win_profile) == Some(ADDED);

    if let Some(bytes) = &current
        && contains(bytes, MARKER.as_bytes())
    {
        ctx.say(format!("読み込み済みです: {win_profile}"));
        if !recorded {
            if mode.writes() {
                records.set(&win_profile, ADDED);
                if let Err(e) = records.save_if_changed() {
                    return record_failed(ctx, &record_path, e);
                }
            } else if ctx.host.runner_enable {
                ctx.say("足した記録はまだありません (apply で、この行を見て記録だけ作ります)。");
            } else {
                ctx.say("runner の記録はまだありません (受け持ちを runner に切り替えた後の apply で、この行を見て記録だけ作ります。WSL の setup の記録は WSL の ~/.local/state/dotfiles/windows-powershell-profile.json)。");
            }
        }
        return Outcome::new(Kind::Ok, "読み込み済み");
    }

    if recorded && !mode.force() {
        let again = again_command(ctx);
        warn(
            ctx,
            &[
                format!("以前 $PROFILE に足した 1 行が見当たりません: {win_profile}"),
                format!(
                    "Windows 側で外したのなら、そのままにします。足し直すなら --force を付けて流してください: {again}"
                ),
            ],
        );
        return Outcome::new(
            Kind::Manual,
            "以前 $PROFILE に足した 1 行が無い (Windows 側で外したのなら、そのままでよい)",
        )
        .note(format!("足し直すなら {again}"));
    }

    if let Some(bytes) = &current
        && is_utf16(bytes)
    {
        warn(
            ctx,
            &with_manual(vec![format!(
                "$PROFILE が UTF-16 なので書き足しません: {win_profile}"
            )]),
        );
        return Outcome::new(Kind::Manual, "$PROFILE が UTF-16 なので書き足さない")
            .note(manual_note());
    }

    let pending = || {
        Outcome::new(
            Kind::Missing,
            "読み込みの 1 行が無い → apply で $PROFILE に足す",
        )
    };
    match mode {
        Mode::Check => {
            ctx.say(format!(
                "読み込みの 1 行がありません (apply で足す): {win_profile}"
            ));
            pending()
        }
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] 1 行を足す: {win_profile}"));
            pending()
        }
        Mode::Apply { .. } => {
            if let Err(e) = append_line(&profile, current.as_deref()) {
                ctx.say(format!("!! $PROFILE に書けません: {win_profile} ({e})"));
                return Outcome::new(Kind::Failed, format!("$PROFILE に書けない ({e})"))
                    .note(manual_note());
            }
            ctx.say(format!("足しました: {win_profile}"));
            records.set(&win_profile, ADDED);
            if let Err(e) = records.save_if_changed() {
                return record_failed(ctx, &record_path, e);
            }
            ctx.say("開いている PowerShell では . $PROFILE で読み直してください。");
            Outcome::new(Kind::Ok, "$PROFILE に読み込みの 1 行を足した")
        }
    }
}

/// pwsh に `$PROFILE` の場所を聞くコマンド (WSL と同じ式。-NoProfile: これから書き換える `$PROFILE` を読ませない)。
fn query_command(pwsh: PathBuf) -> CommandSpec {
    CommandSpec::new(pwsh)
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-Command")
        .arg(QUERY)
        .timeout(Duration::from_secs(QUERY_SECS))
}

/// pwsh の出力から `$PROFILE` の場所を拾う: 絶対パスの行のうち最後のもの。WSL は `^[A-Za-z]:\` の行を拾う (wslpath で直すため) が、runner は
/// Windows のパスをそのまま使うので、ドキュメントをネットワークの場所へ移した PC の UNC (`\\server\share\…`) も拾う。
fn profile_path(lines: &[String]) -> Option<String> {
    lines
        .iter()
        .rev()
        .map(|l| {
            l.trim_start_matches('\u{feff}')
                .trim_end_matches(['\r', '\n'])
        })
        .find(|l| Path::new(l).is_absolute())
        .map(str::to_string)
}

/// `$PROFILE` の末尾に `LINE` を足す。改行はファイルに合わせ (CR があれば CRLF)、末尾に改行が無ければ先に補う。無ければ親ごと作る。
fn append_line(profile: &Path, current: Option<&[u8]>) -> std::io::Result<()> {
    let nl: &[u8] = match current {
        Some(b) if b.contains(&b'\r') => b"\r\n",
        _ => b"\n",
    };
    let prefix: &[u8] = match current {
        Some(b) if !b.is_empty() && b.last() != Some(&b'\n') => nl,
        _ => b"",
    };
    if current.is_none()
        && let Some(dir) = profile.parent()
    {
        std::fs::create_dir_all(dir)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(profile)?;
    f.write_all(&[prefix, LINE.as_bytes(), nl].concat())
}

/// `haystack` に `needle` があるか (WSL の `grep -qF`。バイト列で比べる)。
fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

/// UTF-16 の BOM で始まるか (WSL の script と同じく、頭の 2 バイトで見る)。
fn is_utf16(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff])
}

/// 足し直すコマンド。受け持ちが WSL の間は、runner の apply はこの手順を流さないので、WSL の script を出す。
fn again_command(ctx: &Ctx) -> &'static str {
    if ctx.host.runner_enable {
        "dotfiles apply --steps powershell-profile --force"
    } else {
        "WSL で nix/scripts/bootstrap-windows-powershell-profile.sh --force (受け持ちが WSL の setup の間。runner の apply はこの手順を流さない)"
    }
}

/// 手順を止めない警告を、WSL の script の warn と同じ形で出す (1 行目の頭に `!!`、続きの行は 3 字下げ)。
fn warn(ctx: &mut Ctx, lines: &[String]) {
    for (i, l) in lines.iter().enumerate() {
        if i == 0 {
            ctx.say(format!("!! {l}"));
        } else {
            ctx.say(format!("   {l}"));
        }
    }
}

/// 警告の行に、同じ 1 行を手で足すコマンドを続ける (WSL の script の manual と同じ)。
fn with_manual(mut lines: Vec<String>) -> Vec<String> {
    lines.push("PowerShell 7 で次を 1 回打つと、同じ 1 行が足されます:".to_string());
    lines.push(format!("  {}", manual_command()));
    lines
}

fn manual_command() -> String {
    format!("Add-Content -Path $PROFILE -Value '{LINE}'")
}

/// 締めの表の ※ の行に出す、手で足す道。
fn manual_note() -> String {
    format!(
        "PowerShell 7 で {} を 1 回打つと、同じ 1 行が足される",
        manual_command()
    )
}

fn record_failed(ctx: &mut Ctx, path: &Path, e: std::io::Error) -> Outcome {
    ctx.say(format!(
        "!! 足した記録を書けません: {} ({e})",
        path.display()
    ));
    Outcome::new(Kind::Failed, format!("足した記録を書けない ({e})"))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (WSL の nix/tests/bootstrap-windows-powershell-profile.test.sh と同じケースに、受け持ちで替える案内を足したもの)
    //!
    //! - dotfiles.ps1 が配られていなければ pwsh を呼ばずに飛ばす (· で知らせる)
    //! - pwsh が無い・失敗する・時間切れ・パスを返さないときは、何も書かずに手で打つコマンドを添える
    //! - $PROFILE が無ければ親ごと作って 1 行を書き (LF)、記録する。pwsh には WSL と同じ式を -NoProfile で、WSL と同じ秒数で聞く。
    //!   2 回流しても変わらない
    //! - 改行は $PROFILE に合わせる (CRLF / LF。末尾に改行が無ければ先に補う)
    //! - 1 行が既にあれば変えない (書き方が違っても dotfiles.ps1 を指していればよい)。記録が無ければ apply で記録だけ付け、check は書かずに
    //!   いつ記録を作るかを出す
    //! - 足した記録があって消えていたら足し直さず、--force を案内する (受け持ちで案内を替える)。--force なら足し直す
    //! - check と --dry-run は $PROFILE も記録も書かない。UTF-16 の $PROFILE には書かない。壊れた記録・ディレクトリの置き先では止まる
    //! - pwsh の出力から、最後の絶対パスの行を $PROFILE の場所として拾う。本物の pwsh が返す場所も読める (pwsh が PATH にあるとき)
    //! - WSL の script と同じ $PROFILE から、同じバイト列を書いて同じく記録する (bash の版と突き合わせる。bash と jq がある Linux)

    use super::*;
    use crate::hooks::parity;
    use crate::host::{Groups, parse};
    use crate::manifest::Roots;
    use crate::process::RunResult;
    use crate::testutil::{FakeSys, TempDir};

    /// WSL の script が足す 1 行 (nix/tests/bootstrap-windows-powershell-profile.test.sh の `line` と同じ字を手で書いたもの)
    const WSL_LINE: &str = r#"if (Test-Path "$HOME\.config\powershell\dotfiles.ps1") { . "$HOME\.config\powershell\dotfiles.ps1" }"#;
    const RUNNER_HOST: &str = "[runner]\nenable = true\n";
    const WSL_HOST: &str = "group = \"personal\"\n";
    const APPLY: Mode = Mode::Apply { force: false };

    struct Env {
        t: TempDir,
    }

    impl Env {
        /// `deployed` なら dotfiles.ps1 を配ったホーム
        fn new(deployed: bool) -> Self {
            let t = TempDir::new("pwsh-profile");
            if deployed {
                t.write("home/.config/powershell/dotfiles.ps1", "# dotfiles.ps1\n");
            }
            Env { t }
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        /// pwsh が返す $PROFILE の場所 (ドキュメントが OneDrive の下にある PC の形)
        fn profile(&self) -> PathBuf {
            self.home()
                .join("OneDrive")
                .join("ドキュメント")
                .join("PowerShell")
                .join("Microsoft.PowerShell_profile.ps1")
        }

        fn record(&self) -> PathBuf {
            self.t.path().join("state").join(RECORD_FILE)
        }

        fn write_profile(&self, bytes: &[u8]) {
            std::fs::create_dir_all(self.profile().parent().unwrap()).unwrap();
            std::fs::write(self.profile(), bytes).unwrap();
        }

        fn read_profile(&self) -> Vec<u8> {
            std::fs::read(self.profile()).unwrap()
        }

        /// 記録 (JSON) を値で
        fn record_json(&self) -> serde_json::Value {
            serde_json::from_str(&std::fs::read_to_string(self.record()).unwrap()).unwrap()
        }

        /// 記録に、この $PROFILE を足した印 (added) があるか
        fn recorded(&self) -> bool {
            self.record().exists()
                && self.record_json()[self.profile().to_string_lossy().as_ref()] == "added"
        }

        /// pwsh が PATH にあり、$PROFILE の場所を答える偽の口
        fn sys(&self) -> FakeSys {
            let p = self.profile().to_string_lossy().into_owned();
            FakeSys::new(move |_| RunResult {
                exit: Exit::Code(0),
                output: vec![p.clone()],
            })
            .with_program("pwsh", "/fake/pwsh")
        }

        /// 手順を流し、行 (1 つ) と出力を返す
        fn run(&self, sys: &FakeSys, host: &str, mode: Mode) -> (Outcome, String) {
            let mut out = Vec::new();
            let mut outcomes = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap(),
                    sys,
                    out: &mut out,
                };
                PowershellProfile.run(&mut ctx, mode)
            };
            let out = String::from_utf8(out).unwrap();
            assert_eq!(outcomes.len(), 1, "{outcomes:?}\n{out}");
            (outcomes.remove(0), out)
        }
    }

    fn has_note(o: &Outcome, part: &str) -> bool {
        o.notes.iter().any(|n| n.contains(part))
    }

    #[test]
    fn skips_until_dotfiles_ps1_is_deployed() {
        let e = Env::new(false);
        let sys = e.sys();
        for mode in [Mode::Check, APPLY] {
            let (o, out) = e.run(&sys, RUNNER_HOST, mode);
            assert_eq!(o.kind, Kind::Info, "{mode:?}: {out}");
            assert!(out.contains("dotfiles.ps1 がまだ配られていません"), "{out}");
        }
        assert!(sys.calls.borrow().is_empty());
        assert!(!e.profile().exists());
    }

    #[test]
    fn without_pwsh_shows_the_manual_command() {
        let e = Env::new(true);
        let sys = FakeSys::new(|_| unreachable!());
        let (o, out) = e.run(&sys, RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        let manual = format!("Add-Content -Path $PROFILE -Value '{WSL_LINE}'");
        assert!(has_note(&o, &manual), "{o:?}");
        // その場の出力は WSL の warn と同じ形 (1 行目に !!、手で打つコマンドは 5 字下げ)
        assert!(out.starts_with("!! pwsh が見つかりません"), "{out}");
        assert!(out.contains(&format!("\n     {manual}\n")), "{out}");
        assert!(!e.profile().exists());
        assert!(!e.record().exists());
    }

    #[test]
    fn pwsh_failures_write_nothing() {
        for (exit, output, want) in [
            (
                Exit::Code(126),
                vec!["boom".to_string()],
                "!! pwsh に $PROFILE の場所を聞けませんでした (終了コード 126):\n   boom\n",
            ),
            (
                Exit::SpawnFailed("no such file".to_string()),
                vec![],
                "!! pwsh に $PROFILE の場所を聞けませんでした (起こせなかった: no such file):\n",
            ),
            (
                Exit::TimedOut,
                vec![],
                "!! pwsh に $PROFILE の場所を聞けませんでした (60 秒たっても終わらなかった):\n",
            ),
            (
                Exit::Code(0),
                vec!["WARNING: something".to_string()],
                "!! pwsh が $PROFILE の場所を返しませんでした:\n   WARNING: something\n",
            ),
        ] {
            let e = Env::new(true);
            let r = RunResult { exit, output };
            let sys = FakeSys::new(move |_| r.clone()).with_program("pwsh", "/fake/pwsh");
            let (o, out) = e.run(&sys, RUNNER_HOST, APPLY);
            assert_eq!(o.kind, Kind::Failed, "{want}: {out}");
            assert!(out.contains(want), "{out}");
            assert!(has_note(&o, "Add-Content -Path $PROFILE"), "{o:?}");
            assert!(!e.profile().exists());
            assert!(!e.record().exists());
        }
    }

    #[test]
    fn adds_the_line_to_a_new_profile_and_records_it() {
        let e = Env::new(true);
        let sys = e.sys();
        let shown = e.profile().to_string_lossy().into_owned();
        let (o, out) = e.run(&sys, RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Missing, "{out}");
        let (o, out) = e.run(&sys, RUNNER_HOST, Mode::DryRun { force: false });
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(
            out.contains(&format!("[dry-run] 1 行を足す: {shown}")),
            "{out}"
        );
        assert!(!e.profile().exists());
        assert!(!e.record().exists());

        let (o, out) = e.run(&sys, RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.read_profile(), format!("{WSL_LINE}\n").into_bytes());
        assert_eq!(
            e.record_json(),
            serde_json::json!({ shown.clone(): "added" })
        );
        assert!(out.contains(&format!("足しました: {shown}")), "{out}");
        assert!(
            out.contains("開いている PowerShell では . $PROFILE で読み直してください。"),
            "{out}"
        );
        // pwsh には WSL と同じ式を、-NoProfile (これから書き換える $PROFILE を読ませない) で、WSL と同じ秒数で聞く
        {
            let calls = sys.calls.borrow();
            assert_eq!(calls[0].program, PathBuf::from("/fake/pwsh"));
            assert_eq!(
                calls[0].args_lossy(),
                vec![
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $PROFILE.CurrentUserCurrentHost",
                ]
            );
            assert_eq!(calls[0].timeout, Some(Duration::from_secs(60)));
        }

        // 2 回流しても変わらない
        let (o, out) = e.run(&sys, RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(out.contains(&format!("読み込み済みです: {shown}")), "{out}");
        assert_eq!(e.read_profile(), format!("{WSL_LINE}\n").into_bytes());
    }

    #[test]
    fn follows_the_newlines_of_the_profile() {
        for (name, before, after) in [
            (
                "CRLF・末尾の改行なし",
                "Invoke-Expression (&starship init powershell)\r\n# 末尾に改行なし".to_string(),
                format!(
                    "Invoke-Expression (&starship init powershell)\r\n# 末尾に改行なし\r\n{WSL_LINE}\r\n"
                ),
            ),
            (
                "LF・末尾の改行あり",
                "Set-PSReadLineOption -EditMode Emacs\n".to_string(),
                format!("Set-PSReadLineOption -EditMode Emacs\n{WSL_LINE}\n"),
            ),
            (
                "LF・末尾の改行なし",
                "Set-PSReadLineOption -EditMode Emacs".to_string(),
                format!("Set-PSReadLineOption -EditMode Emacs\n{WSL_LINE}\n"),
            ),
            ("空", String::new(), format!("{WSL_LINE}\n")),
        ] {
            let e = Env::new(true);
            e.write_profile(before.as_bytes());
            let (o, out) = e.run(&e.sys(), RUNNER_HOST, APPLY);
            assert_eq!(o.kind, Kind::Ok, "{name}: {out}");
            assert_eq!(
                String::from_utf8(e.read_profile()).unwrap(),
                after,
                "{name}"
            );
            assert!(e.recorded(), "{name}");
        }
    }

    #[test]
    fn existing_line_is_kept_and_only_recorded() {
        let e = Env::new(true);
        let before = b". \"$HOME\\.config\\powershell\\dotfiles.ps1\"\n";
        e.write_profile(before);
        let sys = e.sys();
        // check は書かず、記録がまだ無いことと、いつ作るかを出す (受け持ちで替える)
        let (o, out) = e.run(&sys, WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains(
                "受け持ちを runner に切り替えた後の apply で、この行を見て記録だけ作ります"
            ),
            "{out}"
        );
        let (o, out) = e.run(&sys, RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(
            out.contains("(apply で、この行を見て記録だけ作ります)"),
            "{out}"
        );
        assert!(!e.record().exists());

        // apply は変えずに記録だけ付ける。付けた後の check は記録のことを言わない
        let (o, out) = e.run(&sys, RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(e.read_profile(), before.to_vec());
        assert!(e.recorded());
        let (o, out) = e.run(&sys, RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert!(!out.contains("記録"), "{out}");
    }

    #[test]
    fn removed_line_is_not_added_back_without_force() {
        let e = Env::new(true);
        let sys = e.sys();
        let shown = e.profile().to_string_lossy().into_owned();
        e.run(&sys, RUNNER_HOST, APPLY);
        let removed = "Invoke-Expression (&starship init powershell)\n";
        e.write_profile(removed.as_bytes());

        let (o, out) = e.run(&sys, RUNNER_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual, "{out}");
        assert!(
            out.contains(&format!(
                "!! 以前 $PROFILE に足した 1 行が見当たりません: {shown}"
            )),
            "{out}"
        );
        assert!(
            has_note(&o, "dotfiles apply --steps powershell-profile --force"),
            "{o:?}"
        );
        let (o, _) = e.run(&sys, RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Manual);
        assert_eq!(e.read_profile(), removed.as_bytes());
        // 受け持ちが WSL の間は、runner の apply はこの手順を流さないので、WSL の script の --force を案内する
        let (o, _) = e.run(&sys, WSL_HOST, Mode::Check);
        assert_eq!(o.kind, Kind::Manual);
        assert!(
            has_note(
                &o,
                "WSL で nix/scripts/bootstrap-windows-powershell-profile.sh --force"
            ),
            "{o:?}"
        );

        let (o, out) = e.run(&sys, RUNNER_HOST, Mode::DryRun { force: true });
        assert_eq!(o.kind, Kind::Missing, "{out}");
        assert!(
            out.contains(&format!("[dry-run] 1 行を足す: {shown}")),
            "{out}"
        );
        assert_eq!(e.read_profile(), removed.as_bytes());
        let (o, out) = e.run(&sys, RUNNER_HOST, Mode::Apply { force: true });
        assert_eq!(o.kind, Kind::Ok, "{out}");
        assert_eq!(
            String::from_utf8(e.read_profile()).unwrap(),
            format!("{removed}{WSL_LINE}\n")
        );
    }

    #[test]
    fn utf16_profile_is_left_alone() {
        for before in [&b"\xff\xfe#\x00\n\x00"[..], &b"\xfe\xff\x00#\x00\n"[..]] {
            let e = Env::new(true);
            e.write_profile(before);
            let (o, out) = e.run(&e.sys(), RUNNER_HOST, APPLY);
            assert_eq!(o.kind, Kind::Manual, "{out}");
            assert!(
                out.contains("!! $PROFILE が UTF-16 なので書き足しません: "),
                "{out}"
            );
            assert!(has_note(&o, "Add-Content -Path $PROFILE"), "{o:?}");
            assert_eq!(e.read_profile(), before);
            assert!(!e.record().exists());
        }
    }

    #[test]
    fn broken_record_and_directory_stop() {
        let e = Env::new(true);
        e.t.write("state/windows-powershell-profile.json", "not json\n");
        let sys = e.sys();
        let (o, out) = e.run(&sys, RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("が壊れています (JSON の object ではありません)。"),
            "{out}"
        );
        assert!(
            out.contains("消してから流し直してください (足した記録が無いものとして扱います)"),
            "{out}"
        );
        assert!(!e.profile().exists());
        // WSL と同じく、記録を確かめてから pwsh に聞く
        assert!(sys.calls.borrow().is_empty());

        let e = Env::new(true);
        std::fs::create_dir_all(e.profile()).unwrap();
        let (o, out) = e.run(&e.sys(), RUNNER_HOST, APPLY);
        assert_eq!(o.kind, Kind::Failed, "{out}");
        assert!(
            out.contains("!! $PROFILE の場所がディレクトリです: "),
            "{out}"
        );
    }

    #[test]
    fn picks_the_last_absolute_path_line() {
        let abs = |rest: &str| {
            if cfg!(windows) {
                format!("C:\\Users\\u\\{rest}")
            } else {
                format!("/home/u/{rest}")
            }
        };
        let lines = vec![
            "WARNING: x".to_string(),
            format!("\u{feff}{}", abs("a.ps1")),
            format!("{}\r", abs("b.ps1")),
            String::new(),
        ];
        assert_eq!(profile_path(&lines), Some(abs("b.ps1")));
        assert_eq!(
            profile_path(&["WARNING: x".to_string(), "Documents\\p.ps1".to_string()]),
            None
        );
        // Windows はドキュメントをネットワークの場所へ移した PC の UNC も拾う (WSL は wslpath で直せないので拾わない)
        if cfg!(windows) {
            let unc = r"\\server\share\Documents\PowerShell\Microsoft.PowerShell_profile.ps1";
            assert_eq!(profile_path(&[unc.to_string()]), Some(unc.to_string()));
        }
    }

    /// 手順の順番・on/off・聞く式と秒数は WSL の script と同じ (違うと、切り替えた後に別の $PROFILE へ書いたり、判定がずれたりする)
    #[test]
    fn settings_match_the_wsl_script() {
        let text = std::fs::read_to_string(parity::repo_file(
            "nix/scripts/bootstrap-windows-powershell-profile.sh",
        ))
        .unwrap();
        let info = PowershellProfile.info();
        assert!(
            text.lines()
                .any(|l| l == format!("# order: {}", info.order))
        );
        assert!(!text.lines().any(|l| l.starts_with("# tool: ")));
        assert_eq!(info.gate, Gate::Always);
        assert!(
            text.contains(&format!(
                "timeout {QUERY_SECS} pwsh.exe -NoProfile -NonInteractive -Command '{QUERY}'"
            )),
            "WSL の script の pwsh.exe の行と違う"
        );
        assert!(text.contains(&format!("record_file=\"${{state_dir}}/{RECORD_FILE}\"")));
    }

    /// 本物の pwsh が返す $PROFILE の場所を読める (出力の文字コード・BOM・改行)。聞くだけで $PROFILE には触らない。pwsh が PATH に
    /// 無ければ飛ばす (GitHub Actions の ubuntu と windows の image にはある)
    #[test]
    fn reads_the_profile_path_from_real_pwsh() {
        use crate::process::{RealSys, Sys};
        let Some(pwsh) = RealSys.which("pwsh") else {
            return;
        };
        let r = RealSys.run(&query_command(pwsh), &mut |_| {});
        assert_eq!(r.exit, Exit::Code(0), "{:?}", r.output);
        let p = profile_path(&r.output).unwrap_or_else(|| panic!("{:?}", r.output));
        assert!(p.ends_with("Microsoft.PowerShell_profile.ps1"), "{p}");
    }

    /// WSL の script と同じ $PROFILE から、同じバイト列を書いて同じく記録する (bash の版と突き合わせる。bash と jq が無ければ飛ばし、
    /// CI の Linux の job は DOTFILES_WIN_BASH_PARITY=1 で飛ばさない)
    #[cfg(unix)]
    #[test]
    fn writes_the_same_bytes_as_the_wsl_script() {
        if !parity::available() {
            return;
        }
        let script = parity::repo_file("nix/scripts/bootstrap-windows-powershell-profile.sh");
        let cases: Vec<(&str, Option<&[u8]>)> = vec![
            ("無い", None),
            ("空", Some(b"")),
            (
                "LF・末尾の改行あり",
                Some(b"Set-PSReadLineOption -EditMode Emacs\n"),
            ),
            (
                "CRLF・末尾の改行なし",
                Some(
                    "Invoke-Expression (&starship init powershell)\r\n# 末尾に改行なし".as_bytes(),
                ),
            ),
            (
                "書き方の違う行がある",
                Some(b". \"$HOME\\.config\\powershell\\dotfiles.ps1\"\n"),
            ),
            (
                "頭に # を付けた行がある",
                Some(b"# if (Test-Path \"$HOME\\.config\\powershell\\dotfiles.ps1\") { }\r\n"),
            ),
            ("UTF-16LE", Some(b"\xff\xfe#\x00\n\x00")),
        ];
        for (name, before) in cases {
            let wsl = wsl_run(&script, before);
            let e = Env::new(true);
            if let Some(b) = before {
                e.write_profile(b);
            }
            let (o, out) = e.run(&e.sys(), RUNNER_HOST, APPLY);
            let runner = (std::fs::read(e.profile()).ok(), e.recorded());
            assert_eq!(runner, wsl, "{name}: {o:?}\n{out}");
        }
    }

    /// WSL の script を、使い捨ての HOME と偽の pwsh.exe・wslpath で流し (nix/tests/bootstrap-windows-powershell-profile.test.sh と同じ形)、
    /// 流した後の $PROFILE の中身と、足した印を記録したかを返す
    #[cfg(unix)]
    fn wsl_run(script: &Path, before: Option<&[u8]>) -> (Option<Vec<u8>>, bool) {
        use std::os::unix::fs::PermissionsExt;
        let t = TempDir::new("pwsh-profile-wsl");
        let h = t.path();
        t.write("win/.config/powershell/dotfiles.ps1", "# dotfiles.ps1\n");
        t.write(
            ".local/state/dotfiles/windows-files.json",
            &serde_json::json!({"enable": true, "version": 1, "windowsHome": h.join("win")})
                .to_string(),
        );
        let profile = h
            .join("mnt/c/Users/tester/OneDrive")
            .join("ドキュメント")
            .join("PowerShell")
            .join("Microsoft.PowerShell_profile.ps1");
        if let Some(b) = before {
            std::fs::create_dir_all(profile.parent().unwrap()).unwrap();
            std::fs::write(&profile, b).unwrap();
        }
        // 偽の pwsh.exe は Windows のパスを CRLF で答え、偽の wslpath は C:\… を <HOME>/mnt/c/… にする。PATH の頭に置くので、
        // WSL の本物の pwsh.exe は呼ばれない (本物の $PROFILE に触らない)
        let bash = std::env::split_paths(&std::env::var_os("PATH").unwrap())
            .map(|d| d.join("bash"))
            .find(|p| p.is_file())
            .unwrap();
        let fakes = [
            (
                "bin/pwsh.exe",
                r"printf '%s\r\n' 'C:\Users\tester\OneDrive\ドキュメント\PowerShell\Microsoft.PowerShell_profile.ps1'",
            ),
            (
                "bin/wslpath",
                "[[ $1 == -u ]] || exit 1\np=${2//\\\\//}\nprintf '%s\\n' \"${HOME}/mnt/c${p#C:}\"",
            ),
        ];
        for (rel, body) in fakes {
            let p = t.write(rel, &format!("#!{}\n{body}\n", bash.display()));
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let mut path = std::ffi::OsString::from(h.join("bin"));
        path.push(":");
        path.push(std::env::var_os("PATH").unwrap());
        let o = std::process::Command::new(&bash)
            .arg(script)
            .env("HOME", h)
            .env("PATH", path)
            .env_remove("DOTFILES_SETUP_WARNINGS")
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        assert_eq!(
            o.status.code(),
            Some(0),
            "{}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        );
        let recorded = std::fs::read_to_string(h.join(".local/state/dotfiles").join(RECORD_FILE))
            .ok()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .is_some_and(|v| v[profile.to_string_lossy().as_ref()] == "added");
        (std::fs::read(&profile).ok(), recorded)
    }
}
