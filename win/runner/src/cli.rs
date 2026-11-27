//! 引数を読み、コマンドを流す。
//!
//! 引数は手で読む (clap を足さない)。誤りは使い方と一緒に stderr へ出し、終了コード 2。

use crate::color::Paint;
use crate::context::Ctx;
use crate::host::{self, Groups};
use crate::manifest::{self, Roots};
use crate::process::{CommandSpec, RealSys, Stream, Sys};
use crate::runner;
use crate::steps::{self, Mode, Step};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const USAGE: &str = "\
dotfiles の Windows 側の runner (win/README.md の「runner」)。

使い方:
  dotfiles check   [--steps <id>,…] [--show-words] [--host-file <path>]
                                                          手順を順に確かめる (何も書かない)
  dotfiles apply   [--dry-run] [--force] [--steps <id>,…] [--show-words] [--host-file <path>]
                                                          手順を順に揃える (受け持ちが WSL のホスト (runner.enable が true でない) では、
                                                          Windows にしか無い手順だけ。ホストの値が無ければ止まる)
  dotfiles list    [--host-file <path>]                   手順と、このホストでの on/off・受け持ちを出す
  dotfiles import terminal [--host-file <path>]           Windows Terminal の settings.json の、衝突したキーの値を
                                                          win/windows-terminal/managed.json へ取り込む (settings.json には書かない。
                                                          commit は自分で。受け持ちが runner のホストだけ)
  dotfiles import international [--host-file <path>]      Windows の日付と時刻の形式の、衝突した値を
                                                          win/international/managed.json へ取り込む (Windows には書かない。commit は
                                                          自分で。受け持ちが runner のホストだけ)
  dotfiles import fancyzones <名前>… [--host-file <path>] PC の FancyZones のカスタムレイアウトを名前で選び、
                                                          win/powertoys/fancyzones/custom-layouts.json へ写す (同上。- で始まる
                                                          名前は -- の後ろに書く)
  dotfiles import google-ime [--host-file <path>]         Google 日本語入力の設定と辞書を、win/google-japanese-input/ と
                                                          dotfiles-private の google-japanese-input/dictionaries/ のテキストへ
                                                          取り込む (Google 日本語入力のファイルには書かない。commit は自分で。
                                                          dotfiles-private の diff には辞書の語が出るので自分の端末で見る。同上)
  dotfiles manifest [--json] [--windows-home <path>]      win/manifest.toml を検証する (--json は置き先を解いた計画)
  dotfiles --self-update [--dry-run] [<上の引数>…]        dotfiles・dotfiles-private・claude-skills の clone を fetch して fast-forward し、
                                                          上の引数があれば、その後にこの runner を流す (PowerShell の dotfiles 関数が
                                                          受け持ち、runner には来ない。win/README.md の「clone を進める」)
  dotfiles-win claude-hook <名前>                         Claude Code の hook (stdin の JSON を読む。claude-files が写した
                                                          %USERPROFILE%\\.claude\\hooks\\dotfiles-claude.exe を settings.json が呼ぶ口)
  dotfiles-win claude-statusline                          Claude Code の status line (同じ口)
  claude-<名前>.exe [引数…]                               この exe の写し (claude-accounts が %LOCALAPPDATA%\\dotfiles\\bin に置く)。
                                                          CLAUDE_CONFIG_DIR を %USERPROFILE%\\.claude-<名前> にして claude.exe を起こす
                                                          (token のアカウントは token のファイルの token を渡す)
  claude-account.exe <add|set-token|list|check|remove|help> …
                                                          同じ写し。アカウントを足す・消す・確かめる (claude-account.exe --help)
  dotfiles-win version                                    この exe の版と、作った key・commit (Release の exe か手元の build か) を出す

  --dry-run         apply がすることを出すだけ (何も書かない。runner.enable によらない)
  --force           衝突 (Windows 側で変わっていた・置いた記録が無い) も上書きする (files・ssh-config・port-forward・terminal・fancyzones・
                    記録つきのコピーの手順 (claude-skills・claude-accounts など)・herdr-app-keys ほか。手順ごとの中身は win/README.md)。
                    ssh-config・port-forward は元を <名前>.dotfiles-bak-<日時> に退避してから上書きし、ssh-config は、正本から消えたが
                    Windows 側で変わっていたファイルも退避して消す。terminal・fancyzones は元を %LOCALAPPDATA%\\dotfiles\\state\\ の下に退避
                    してから書き、fancyzones は PC で直した・消したレイアウトと手であてた組も上書きする。powertoys は変わっていなくても
                    Keyboard Manager に読み直させる。powershell-profile は、足した後で消した $PROFILE の読み込みの 1 行も足し直し、
                    starship-init は、足した後で消した (記録した手書きの行も) $PROFILE の starship の init の 1 行も足し直す。
                    international は、Windows 側で変わっていた日付と時刻の形式も managed.json の値で書く (退避は無い)。
                    google-ime は、画面で変えていた (読めない) 設定と辞書も、元を %LOCALAPPDATA%\\dotfiles\\state\\ の下に退避して
                    から置き直す。--steps で手順を絞って使う
  --show-words      google-ime の辞書の衝突で、語の diff も出す (出さなければ辞書ごとの行の数だけ)。自分の端末で打つ (Claude などの
                    ログに残る場所では流さない)
  --steps <id>,…    流す手順を id で絞る (id は dotfiles list で見る)
  --host-file <path> ホストの値のファイル (既定は %USERPROFILE%\\.config\\dotfiles\\host.toml、無ければ dotfiles-private の
                    win/hosts/<ユーザー>@<PC>.toml。両方あれば check は ⚠ を出し、apply は止まる)
  --windows-home <path> manifest の置き先を、この Windows のホストの下として解く (既定は環境変数)
  --repo <path>     dotfiles の clone (既定は、Release の exe なら %USERPROFILE%\\ghq\\github.com\\pollenjp\\dotfiles、手元の build なら
                    build した clone。PowerShell の dotfiles 関数はいつも渡す)

終了コード: 0 直すことが無い・3 入っていない・無いものだけ (apply で揃う)・1 ほかに直すことがある・2 runner が動けない";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    Check,
    Apply,
    List,
    Manifest,
    Import,
    Help,
    /// この exe の版と、作った key・commit (`build_info`)
    Version,
}

/// 取り込める手順 (WSL の script の `--import` を写したもの)
pub const IMPORTABLE: &[&str] = &["terminal", "fancyzones", "international", "google-ime"];

/// `--self-update` が runner に来たときの誤り (開いている PowerShell の dotfiles 関数が古い)
const SELF_UPDATE_OLD_FUNCTION: &str = "--self-update は PowerShell の dotfiles 関数が受け持つが、この PowerShell の dotfiles 関数は --self-update を\
知らない古いもの → dotfiles apply で dotfiles.ps1 を配ってから (受け持ちが WSL のホストは WSL の ~/dotfiles/setup --self-update --update)、\
新しい PowerShell を開く。clone も古ければ、先に一度だけ手で pull する (win/README.md の「clone を進める (dotfiles --self-update)」)";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Args {
    pub command: Command,
    pub dry_run: bool,
    pub force: bool,
    /// google-ime の辞書の衝突で語の diff も出す
    pub show_words: bool,
    pub steps: Option<Vec<String>>,
    pub host_file: Option<PathBuf>,
    pub json: bool,
    pub windows_home: Option<PathBuf>,
    pub repo: Option<PathBuf>,
    /// import の手順の id
    pub target: Option<String>,
    /// import の手順に渡す名前 (fancyzones のレイアウトの名前)
    pub names: Vec<String>,
}

impl Args {
    fn new(command: Command) -> Self {
        Args {
            command,
            dry_run: false,
            force: false,
            show_words: false,
            steps: None,
            host_file: None,
            json: false,
            windows_home: None,
            repo: None,
            target: None,
            names: Vec::new(),
        }
    }
}

/// 引数を読む。誤りは文で返す (呼ぶ側が使い方と一緒に出す)。
pub fn parse(args: &[String]) -> Result<Args, String> {
    let mut iter = args.iter();
    let Some(first) = iter.next() else {
        return Err("コマンドがありません".to_string());
    };
    let command = match first.as_str() {
        "check" => Command::Check,
        "apply" => Command::Apply,
        "list" => Command::List,
        "manifest" => Command::Manifest,
        "import" => Command::Import,
        "help" | "-h" | "--help" => return Ok(Args::new(Command::Help)),
        // 後ろの引数は読まない (launcher は runner の引数の 1 つ目の後ろに --repo を差し込む)
        "version" | "--version" => return Ok(Args::new(Command::Version)),
        // --self-update は PowerShell の dotfiles 関数 (win/powershell/dotfiles.ps1) が受け持ち、runner には渡さない。ここに来たのは、開いている
        // PowerShell の dotfiles 関数が --self-update を知らない古いもの
        "--self-update" => return Err(SELF_UPDATE_OLD_FUNCTION.to_string()),
        other => return Err(format!("知らないコマンドです: {other}")),
    };
    let mut a = Args::new(command);
    // import の `--` の後ろは、- で始まっても名前として読む (- で始まるレイアウトの名前)
    let mut names_only = false;
    while let Some(arg) = iter.next() {
        if command == Command::Import && (names_only || arg == "--") {
            if names_only {
                if a.target.is_none() {
                    a.target = Some(arg.clone());
                } else {
                    a.names.push(arg.clone());
                }
            }
            names_only = true;
            continue;
        }
        let (name, inline) = match arg.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n, Some(v.to_string())),
            _ => (arg.as_str(), None),
        };
        let mut value = |name: &str| -> Result<String, String> {
            match &inline {
                Some(v) => Ok(v.clone()),
                None => iter
                    .next()
                    .cloned()
                    .ok_or_else(|| format!("{name} の値がありません")),
            }
        };
        let allowed = |commands: &[Command]| -> Result<(), String> {
            if commands.contains(&command) {
                Ok(())
            } else {
                Err(format!(
                    "{name} は {} には付けられません",
                    command_name(command)
                ))
            }
        };
        match name {
            "-h" | "--help" => return Ok(Args::new(Command::Help)),
            "--dry-run" => {
                allowed(&[Command::Apply])?;
                a.dry_run = true;
            }
            "--force" => {
                allowed(&[Command::Apply])?;
                a.force = true;
            }
            "--show-words" => {
                allowed(&[Command::Check, Command::Apply])?;
                a.show_words = true;
            }
            "--json" => {
                allowed(&[Command::Manifest])?;
                a.json = true;
            }
            "--steps" => {
                allowed(&[Command::Check, Command::Apply])?;
                let v = value(name)?;
                let ids: Vec<String> = v
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .collect();
                if ids.is_empty() {
                    return Err("--steps に手順の id がありません".to_string());
                }
                a.steps = Some(ids);
            }
            "--host-file" => {
                allowed(&[
                    Command::Check,
                    Command::Apply,
                    Command::List,
                    Command::Import,
                ])?;
                a.host_file = Some(PathBuf::from(value(name)?));
            }
            "--windows-home" => {
                allowed(&[Command::Manifest])?;
                a.windows_home = Some(PathBuf::from(value(name)?));
            }
            "--repo" => a.repo = Some(PathBuf::from(value(name)?)),
            // import の手順の id と、その後ろの名前 (- で始まらない引数)
            other if command == Command::Import && !other.starts_with('-') => {
                if a.target.is_none() {
                    a.target = Some(other.to_string());
                } else {
                    a.names.push(other.to_string());
                }
            }
            other => return Err(format!("知らない引数です: {other}")),
        }
        if inline.is_some() && matches!(name, "--dry-run" | "--force" | "--json" | "--show-words") {
            return Err(format!("{name} は値を取りません"));
        }
    }
    if command == Command::Import {
        match a.target.as_deref() {
            None => {
                return Err(format!(
                    "import には取り込む手順の id を付けてください ({})",
                    IMPORTABLE.join("・")
                ));
            }
            Some(t) if !IMPORTABLE.contains(&t) => {
                return Err(format!(
                    "{t} は取り込めません (取り込める手順: {})",
                    IMPORTABLE.join("・")
                ));
            }
            Some(t @ ("terminal" | "international" | "google-ime")) if !a.names.is_empty() => {
                return Err(format!(
                    "import {t} は名前を取りません: {}",
                    a.names.join(" ")
                ));
            }
            Some("fancyzones") if a.names.is_empty() => {
                return Err(
                    "import fancyzones には、取り込むレイアウトの名前 (PC のエディターに出る名前) を付けてください".to_string(),
                );
            }
            Some(_) => {}
        }
    }
    Ok(a)
}

fn command_name(c: Command) -> &'static str {
    match c {
        Command::Check => "check",
        Command::Apply => "apply",
        Command::List => "list",
        Command::Manifest => "manifest",
        Command::Import => "import",
        Command::Help => "help",
        Command::Version => "version",
    }
}

/// `dotfiles-win` の本体。終了コードを返す。
pub fn main(args: Vec<String>) -> i32 {
    let stdout = std::io::stdout();
    let stderr = std::io::stderr();
    // claude-files が写した hook の口 (dotfiles-claude.exe) は、hook と status line だけを受ける (古い写しで runner を流さない)
    let hook_exe = std::env::args_os()
        .next()
        .and_then(|a| {
            Path::new(&a)
                .file_stem()
                .map(|s| s.to_string_lossy().eq_ignore_ascii_case("dotfiles-claude"))
        })
        .unwrap_or(false);
    if let Some(code) = claude_entry(
        &args,
        hook_exe,
        &mut std::io::stdin().lock(),
        &RealSys,
        &mut stdout.lock(),
        &mut stderr.lock(),
    ) {
        return code;
    }
    run(&args, &RealSys, &mut stdout.lock(), &mut stderr.lock())
}

/// Claude Code の hook と status line の口 (`claude-hook <名前>`・`claude-statusline`)。そのどちらでもなければ None (runner のコマンド)。
/// hook の口の写し (`hook_exe`) では、ほかのコマンドは何もせずに知らせるだけにする。どれも終了コードは 0 (止めるときは JSON の
/// permissionDecision)。登録の args が欠けて写しが引数なしで呼ばれても、PreToolUse の tool を止めないように (2 は止める合図で、Git Bash の
/// 無い Windows の shell form では 0 と 2 のほかも止めうる)。
pub fn claude_entry(
    args: &[String],
    hook_exe: bool,
    stdin: &mut dyn std::io::Read,
    sys: &dyn Sys,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Option<i32> {
    let mut read_stdin = || {
        let mut buf = Vec::new();
        let _ = stdin.read_to_end(&mut buf);
        String::from_utf8_lossy(&buf).into_owned()
    };
    match args.first().map(String::as_str) {
        Some("claude-hook") => {
            let input = read_stdin();
            match args.get(1) {
                Some(name) if args.len() == 2 => {
                    if let Some(answer) = crate::hooks::run(name, &input, sys) {
                        let _ = out.write_all(answer.as_bytes());
                    }
                }
                _ => {
                    let _ = writeln!(
                        err,
                        "claude-hook: hook の名前を 1 つ渡してください ({})",
                        crate::hooks::NAMES.join("・")
                    );
                }
            }
            Some(0)
        }
        Some("claude-statusline") => {
            let input = read_stdin();
            let _ = out.write_all(crate::hooks::statusline::line(&input, sys).as_bytes());
            Some(0)
        }
        _ if hook_exe => {
            let _ = writeln!(
                err,
                "!! この exe は Claude Code の hook と status line の口 (claude-hook・claude-statusline) です。runner は PowerShell の dotfiles 関数で流してください (何もしていません)"
            );
            Some(0)
        }
        _ => None,
    }
}

/// `--repo` が無いときの clone。Release の exe (`release_key` がある。`build_info::KEY`) は bootstrap が clone する所
/// (`%USERPROFILE%\ghq\github.com\pollenjp\dotfiles`。build した場所は CI のパスなので使えない)、手元の build は build した clone
/// (`win/runner` の 2 つ上)。
pub fn default_repo(release_key: Option<&str>, sys: &dyn Sys) -> Result<PathBuf, String> {
    if release_key.is_some() {
        let home = sys
            .env("USERPROFILE")
            .filter(|s| !s.is_empty())
            .ok_or("環境変数 USERPROFILE がありません (dotfiles の clone の場所を決められない。--repo で渡す)")?;
        return Ok(["ghq", "github.com", "pollenjp", "dotfiles"]
            .iter()
            .fold(PathBuf::from(home), |p, s| p.join(s)));
    }
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    Ok(dir
        .parent()
        .and_then(Path::parent)
        .unwrap_or(dir)
        .to_path_buf())
}

/// Release の exe (`expected` がある) なら、clone の HEAD の `win/runner` の tree が自分を作った key と同じかを確かめる (違う中身の runner が
/// clone の manifest・ps1 を読まないように。直に打った・選び間違えたときの守り)。手元の build (`expected` が None) は何もしない。
pub fn check_runner_key(expected: Option<&str>, repo: &Path, sys: &dyn Sys) -> Result<(), String> {
    let Some(expected) = expected else {
        return Ok(());
    };
    let short = |k: &str| k.chars().take(12).collect::<String>();
    let shown = repo.display();
    let git = sys.which("git").ok_or(format!(
        "git が見つからない (この runner の exe は、clone ({shown}) の HEAD の win/runner が自分と同じかを git で確かめてから流す。git は bootstrap が入れる)"
    ))?;
    let r = sys.run(
        &CommandSpec::new(git)
            .arg("-C")
            .arg(repo.as_os_str())
            .arg("rev-parse")
            .arg("HEAD:win/runner")
            .stdout_only()
            .timeout(Duration::from_secs(30)),
        &mut |_| {},
    );
    let got = r
        .output
        .iter()
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .unwrap_or_default()
        .to_string();
    if r.code() != Some(0) || !crate::build_info::is_object_name(&got) {
        return Err(format!(
            "clone ({shown}) の HEAD の win/runner を読めない (git -C '{shown}' rev-parse HEAD:win/runner。{:?})。この runner の exe は、clone に合うかを確かめてから流す → PowerShell の dotfiles 関数から打つ",
            r.exit
        ));
    }
    if got != expected {
        return Err(format!(
            "この runner の exe は win/runner {} から作ったもの。clone ({shown}) の HEAD の win/runner は {} → PowerShell の dotfiles 関数から打つ (clone に合う exe を落とす)。手元で build するなら $env:DOTFILES_RUNNER = 'cargo'",
            short(expected),
            short(&got)
        ));
    }
    Ok(())
}

/// PC の名前 (`hostname` の出力を小文字に。読めなければ `%COMPUTERNAME%` を小文字に)。
fn pc_name(sys: &dyn Sys) -> Option<String> {
    let r = sys.run(
        &CommandSpec::new("hostname").timeout(Duration::from_secs(10)),
        &mut |_| {},
    );
    if r.code() == Some(0)
        && let Some(name) = r.output.iter().map(|l| l.trim()).find(|l| !l.is_empty())
    {
        return Some(name.to_lowercase());
    }
    sys.env("COMPUTERNAME")
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
}

/// stderr に出す誤りの行 (`!! …`)。stderr が端末で NO_COLOR が無ければ赤にする (setup.sh の `ERROR` と同じ。`color`)。
fn error_line(sys: &dyn Sys, e: impl std::fmt::Display) -> String {
    Paint::detect(sys, Stream::Stderr).red(&format!("!! {e}"))
}

/// 引数・環境・出力を受けて流す (試験はここを呼ぶ)。
pub fn run(args: &[String], sys: &dyn Sys, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let a = match parse(args) {
        Ok(a) => a,
        Err(e) => {
            let _ = writeln!(err, "{}\n\n{USAGE}", error_line(sys, e));
            return 2;
        }
    };
    match a.command {
        Command::Help => {
            let _ = writeln!(out, "{USAGE}");
            return 0;
        }
        Command::Version => {
            for l in crate::build_info::lines(crate::build_info::KEY, crate::build_info::COMMIT) {
                let _ = writeln!(out, "{l}");
            }
            return 0;
        }
        _ => {}
    }
    // 相対パスの --repo は絶対パスにする (隣の clone・控え (claude-skills-dir)・cargo install --path が、cwd を移した後に別の場所を指さない)
    let repo = match a.repo.clone() {
        Some(p) => std::path::absolute(&p).unwrap_or(p),
        None => match default_repo(crate::build_info::KEY, sys) {
            Ok(r) => r,
            Err(e) => {
                let _ = writeln!(err, "{}", error_line(sys, e));
                return 2;
            }
        },
    };
    if let Err(e) = check_runner_key(crate::build_info::KEY, &repo, sys) {
        let _ = writeln!(err, "{}", error_line(sys, e));
        return 2;
    }
    match a.command {
        Command::Help | Command::Version => 0,
        Command::Manifest => manifest_command(&a, &repo, sys, out, err),
        Command::Check | Command::Apply | Command::List | Command::Import => {
            match steps_command(&a, repo, sys, out) {
                Ok(code) => code,
                Err(e) => {
                    let _ = writeln!(err, "{}", error_line(sys, e));
                    2
                }
            }
        }
    }
}

fn manifest_command(
    a: &Args,
    repo: &Path,
    sys: &dyn Sys,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> i32 {
    let roots = match &a.windows_home {
        Some(h) => Roots::from_home(h),
        None => Roots::from_env(&|n| sys.env(n))
            .unwrap_or_else(|_| Roots::from_home(Path::new("C:/Users/CHECK"))),
    };
    match manifest::load(repo, &roots) {
        Ok(plan) => {
            if a.json {
                let _ = writeln!(out, "{}", manifest::plan_json(&plan));
            } else {
                let _ = writeln!(out, "win/manifest.toml: OK ({} 件)", plan.files.len());
            }
            0
        }
        Err(e) => {
            let _ = writeln!(err, "{}", error_line(sys, e));
            1
        }
    }
}

fn steps_command(
    a: &Args,
    repo: PathBuf,
    sys: &dyn Sys,
    out: &mut dyn Write,
) -> Result<i32, String> {
    let all = steps::all_with(steps::Options {
        show_words: a.show_words,
    });
    let selected: Vec<Box<dyn Step>> = match &a.steps {
        None => all,
        Some(ids) => {
            for id in ids {
                if !all.iter().any(|s| s.info().id == id) {
                    return Err(format!("知らない手順です: {id} (dotfiles list で見る)"));
                }
            }
            all.into_iter()
                .filter(|s| ids.iter().any(|id| id == s.info().id))
                .collect()
        }
    };
    let groups = Groups::embedded()?;
    // ホストの値を引く順: --host-file → 手元の %USERPROFILE%\.config\dotfiles\host.toml → dotfiles-private (host.rs の resolve)
    let host = match &a.host_file {
        Some(p) => host::load(p, groups)?,
        None => {
            let user = sys
                .env("USERNAME")
                .filter(|s| !s.is_empty())
                .ok_or("環境変数 USERNAME がありません (ホストの値の名前を決められない。--host-file で渡す)")?;
            let pc = pc_name(sys).ok_or(
                "PC の名前が分かりません (hostname も COMPUTERNAME も読めない。--host-file で渡す)",
            )?;
            let user_profile = sys
                .env("USERPROFILE")
                .filter(|s| !s.is_empty())
                .map(PathBuf::from);
            let private = host::default_path(&repo, user_profile.as_deref(), &user, &pc);
            match &user_profile {
                Some(up) => host::resolve(&host::local_path(up), &private, groups)?,
                None => host::load(&private, groups)?,
            }
        }
    };
    // list は置き先を使わないので、環境変数が無くても流せる (試すとき)
    let roots = match Roots::from_env(&|n| sys.env(n)) {
        Ok(r) => r,
        Err(_) if a.command == Command::List => Roots::from_home(Path::new("C:/Users/CHECK")),
        Err(e) => return Err(e),
    };
    let state_dir = roots.local_app_data.join("dotfiles").join("state");
    let mut ctx = Ctx {
        repo,
        roots,
        state_dir,
        host,
        sys,
        out,
    };
    match a.command {
        Command::List => {
            runner::list(&mut ctx, &selected);
            Ok(0)
        }
        Command::Import => {
            let target = a.target.as_deref().unwrap_or_default();
            ctx.heading(format!(
                "==> dotfiles import {target} (Windows 側の値を repo のファイルへ取り込む。PC の設定のファイルには書かない)"
            ));
            runner::describe_host(&mut ctx);
            let rows = runner::import(&mut ctx, target, &a.names);
            Ok(runner::finish(&mut ctx, "import", &rows))
        }
        Command::Check => {
            ctx.heading("==> dotfiles check (確かめるだけ。何も書かない)");
            runner::describe_host(&mut ctx);
            let rows = runner::execute(&mut ctx, Mode::Check, &selected);
            Ok(runner::finish(&mut ctx, "check", &rows))
        }
        _ if a.dry_run => {
            ctx.heading("==> dotfiles apply --dry-run (することを出すだけ。何も書かない)");
            runner::describe_host(&mut ctx);
            if let Some(b) = runner::apply_blocker(&ctx.host, &selected) {
                ctx.say(format!("※ 本番の apply は止まる: {}", b.text));
            } else if !ctx.host.runner_enable {
                ctx.say("※ 本番の apply は、受け持ちが WSL の setup なので Windows にしか無い手順だけを流す。WSL の setup と同じ手順 (files・ps1・powershell-profile など) の [dry-run] は、受け持ちを runner に切り替えたときにすること");
            }
            let rows = runner::execute(&mut ctx, Mode::DryRun { force: a.force }, &selected);
            Ok(runner::finish(&mut ctx, "apply --dry-run", &rows))
        }
        _ => {
            ctx.heading("==> dotfiles apply");
            runner::describe_host(&mut ctx);
            if let Some(b) = runner::apply_blocker(&ctx.host, &selected) {
                let mut rows = runner::host_rows(&ctx.host);
                rows.push(b);
                return Ok(runner::finish(&mut ctx, "apply", &rows));
            }
            let rows = runner::execute(&mut ctx, Mode::Apply { force: a.force }, &selected);
            Ok(runner::finish(&mut ctx, "apply", &rows))
        }
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - コマンドと引数の読み方 (`--opt value` と `--opt=value`・`--steps` の分け方)
    //! - コマンドが無い・知らない・付けられない引数・値が無いのは誤り (呼ぶ側が終了コード 2 にする)

    use super::*;

    fn p(args: &[&str]) -> Result<Args, String> {
        parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn reads_commands() {
        assert_eq!(p(&["check"]).unwrap().command, Command::Check);
        assert_eq!(p(&["apply"]).unwrap().command, Command::Apply);
        assert_eq!(p(&["list"]).unwrap().command, Command::List);
        assert_eq!(p(&["manifest"]).unwrap().command, Command::Manifest);
        let i = p(&["import", "terminal", "--host-file", "h.toml"]).unwrap();
        assert_eq!(i.command, Command::Import);
        assert_eq!(i.target.as_deref(), Some("terminal"));
        assert!(i.names.is_empty());
        assert_eq!(i.host_file, Some(PathBuf::from("h.toml")));
        let n = p(&["import", "international"]).unwrap();
        assert_eq!(n.target.as_deref(), Some("international"));
        assert!(n.names.is_empty());
        let g = p(&["import", "google-ime"]).unwrap();
        assert_eq!(g.target.as_deref(), Some("google-ime"));
        assert!(g.names.is_empty() && !g.show_words);
        let f = p(&["import", "fancyzones", "4k-43inch", "1080p"]).unwrap();
        assert_eq!(f.target.as_deref(), Some("fancyzones"));
        assert_eq!(f.names, vec!["4k-43inch".to_string(), "1080p".to_string()]);
        // -- の後ろは - で始まっても名前
        let d = p(&[
            "import",
            "fancyzones",
            "--host-file",
            "h.toml",
            "--",
            "-x",
            "--y",
        ])
        .unwrap();
        assert_eq!(d.names, vec!["-x".to_string(), "--y".to_string()]);
        assert_eq!(d.host_file, Some(PathBuf::from("h.toml")));
        let d = p(&["import", "--", "fancyzones", "-x"]).unwrap();
        assert_eq!(d.target.as_deref(), Some("fancyzones"));
        assert_eq!(d.names, vec!["-x".to_string()]);
        assert_eq!(p(&["--help"]).unwrap().command, Command::Help);
        assert_eq!(p(&["check", "-h"]).unwrap().command, Command::Help);
    }

    #[test]
    fn reads_options() {
        let a = p(&[
            "apply",
            "--dry-run",
            "--force",
            "--steps",
            "files, ntn",
            "--host-file=h.toml",
            "--repo",
            "/r",
        ])
        .unwrap();
        assert!(a.dry_run && a.force);
        assert_eq!(a.steps, Some(vec!["files".to_string(), "ntn".to_string()]));
        assert_eq!(a.host_file, Some(PathBuf::from("h.toml")));
        assert_eq!(a.repo, Some(PathBuf::from("/r")));
        assert!(!a.show_words);
        // --show-words は check と apply (dry-run も) に付けられる
        assert!(p(&["check", "--show-words"]).unwrap().show_words);
        assert!(
            p(&["apply", "--dry-run", "--show-words"])
                .unwrap()
                .show_words
        );
        let m = p(&["manifest", "--json", "--windows-home", "/mnt/c/Users/x"]).unwrap();
        assert!(m.json);
        assert_eq!(m.windows_home, Some(PathBuf::from("/mnt/c/Users/x")));
    }

    #[test]
    fn rejects_bad_arguments() {
        for args in [
            &[][..],
            &["frobnicate"][..],
            &["check", "--dry-run"][..],
            &["list", "--force"][..],
            &["check", "--json"][..],
            &["apply", "--steps"][..],
            &["apply", "--steps", ","][..],
            &["check", "--what"][..],
            &["apply", "--dry-run=yes"][..],
            &["manifest", "--host-file", "x"][..],
            &["import"][..],
            &["import", "files"][..],
            &["import", "terminal", "x"][..],
            &["import", "international", "x"][..],
            &["import", "google-ime", "x"][..],
            &["import", "google-ime", "--show-words"][..],
            &["list", "--show-words"][..],
            &["check", "--show-words=yes"][..],
            &["import", "fancyzones"][..],
            &["import", "terminal", "--force"][..],
            &["import", "terminal", "--steps", "terminal"][..],
            &["check", "terminal"][..],
            &["--self-update"][..],
        ] {
            assert!(p(args).is_err(), "{args:?}");
        }
    }

    /// --self-update は PowerShell の dotfiles 関数が受け持つ。runner に来たら、関数が古いことと直し方を出す (知らないコマンドとは出さない)
    #[test]
    fn self_update_is_for_the_powershell_function() {
        for args in [&["--self-update"][..], &["--self-update", "apply"][..]] {
            let e = p(args).unwrap_err();
            assert!(
                e.starts_with("--self-update は PowerShell の dotfiles 関数が受け持つ"),
                "{e}"
            );
            assert!(e.contains("新しい PowerShell を開く"), "{e}");
        }
        assert!(USAGE.contains("dotfiles --self-update [--dry-run]"));
    }

    /// hook と status line の口: stdin を読んで答え、いつも 0。hook の口の写しは runner のコマンドを流さない (0)。ほかは runner へ (None)
    #[test]
    fn claude_entry_points() {
        let sys = crate::testutil::FakeSys::new(|_| unreachable!());
        let call = |args: &[&str], hook_exe: bool, stdin: &str| {
            let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
            let (mut out, mut err) = (Vec::new(), Vec::new());
            let code = claude_entry(
                &args,
                hook_exe,
                &mut stdin.as_bytes(),
                &sys,
                &mut out,
                &mut err,
            );
            (
                code,
                String::from_utf8(out).unwrap(),
                String::from_utf8(err).unwrap(),
            )
        };
        let skill = "{\"tool_name\": \"Skill\", \"tool_input\": {\"skill\": \"superpowers:brainstorming\"}}";
        let (code, out, _) = call(&["claude-hook", "run-through-nudge"], true, skill);
        assert_eq!(code, Some(0));
        assert!(out.contains("[走り切り]") && out.ends_with('\n'), "{out}");
        let (code, out, err) = call(&["claude-hook"], false, skill);
        assert_eq!((code, out.as_str()), (Some(0), ""));
        assert!(err.contains("docs-guard"), "{err}");
        let (code, out, _) = call(&["claude-hook", "nope"], false, "{}");
        assert_eq!((code, out.as_str()), (Some(0), ""));
        let (code, out, _) = call(
            &["claude-statusline"],
            true,
            "{\"model\": {\"display_name\": \"Opus\"}}",
        );
        assert_eq!(code, Some(0));
        assert!(out.contains("Opus") && !out.ends_with('\n'), "{out:?}");
        // hook の口の写しは runner のコマンドを流さず、引数が欠けても 0 で終える (PreToolUse の tool を止めない)
        for args in [&["apply"][..], &[][..]] {
            let (code, out, err) = call(args, true, "");
            assert_eq!((code, out.as_str()), (Some(0), ""), "{args:?}");
            assert!(err.contains("dotfiles 関数"), "{err}");
        }
        assert_eq!(call(&["check"], false, "").0, None);
        assert_eq!(call(&[], false, "").0, None);
    }

    mod release {
        //! ## 確かめること (Release の exe の口。dotfiles-private の docs/adr/117_win_runner_exe_release_*)
        //!
        //! - `version`・`--version` は後ろの引数を読まず、外のコマンドを打たずに版と build の情報を出す (終了コード 0)
        //! - 既定の clone は、Release の exe なら `%USERPROFILE%\ghq\github.com\pollenjp\dotfiles` (USERPROFILE が無ければ誤り)、手元の build なら
        //!   build した clone
        //! - key の守りは、手元の build では git を打たない。Release の exe は clone の HEAD の win/runner と比べ、違う・読めない・git が無いなら誤り

        use super::super::*;
        use crate::process::{Exit, RunResult};
        use crate::testutil::FakeSys;

        const K: &str = "261aff1f714694bfe0c0199428617dfc448336a4";
        const OTHER: &str = "0123456789abcdef0123456789abcdef01234567";

        fn answer(code: i32, lines: &[&str]) -> RunResult {
            RunResult {
                exit: Exit::Code(code),
                output: lines.iter().map(|s| s.to_string()).collect(),
            }
        }

        #[test]
        fn reads_version() {
            let p = |args: &[&str]| parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>());
            assert_eq!(p(&["version"]).unwrap().command, Command::Version);
            assert_eq!(
                p(&["--version", "--repo", "x"]).unwrap().command,
                Command::Version
            );
        }

        #[test]
        fn version_prints_build_info_without_commands() {
            let sys = FakeSys::new(|_| answer(0, &[]));
            let (mut out, mut err) = (Vec::new(), Vec::new());
            let code = run(
                &["version".to_string(), "--repo".to_string(), "x".to_string()],
                &sys,
                &mut out,
                &mut err,
            );
            let out = String::from_utf8(out).unwrap();
            assert_eq!(code, 0, "{out}");
            assert!(out.starts_with("dotfiles-win "), "{out}");
            assert!(out.contains("\nkey="), "{out}");
            assert!(out.contains("\nbuild="), "{out}");
            assert!(sys.calls.borrow().is_empty());
            assert!(err.is_empty());
        }

        #[test]
        fn default_repo_for_release_and_local() {
            let sys = FakeSys::new(|_| answer(0, &[])).with_env("USERPROFILE", "C:/Users/a");
            assert_eq!(
                default_repo(Some(K), &sys).unwrap(),
                Path::new("C:/Users/a")
                    .join("ghq")
                    .join("github.com")
                    .join("pollenjp")
                    .join("dotfiles")
            );
            let none = FakeSys::new(|_| answer(0, &[]));
            assert!(
                default_repo(Some(K), &none)
                    .unwrap_err()
                    .contains("--repo で渡す")
            );
            let built = Path::new(env!("CARGO_MANIFEST_DIR"))
                .parent()
                .and_then(Path::parent)
                .unwrap()
                .to_path_buf();
            assert_eq!(default_repo(None, &none).unwrap(), built);
        }

        #[test]
        fn local_build_skips_the_key_check() {
            let sys = FakeSys::new(|_| answer(0, &[OTHER])).with_program("git", "/fake/git");
            assert!(check_runner_key(None, Path::new("/r"), &sys).is_ok());
            assert!(sys.calls.borrow().is_empty());
        }

        #[test]
        fn release_build_compares_the_clone_key() {
            let same = FakeSys::new(|_| answer(0, &[K])).with_program("git", "/fake/git");
            assert!(check_runner_key(Some(K), Path::new("/r"), &same).is_ok());
            assert_eq!(same.call_args(), vec!["-C /r rev-parse HEAD:win/runner"]);

            let other = FakeSys::new(|_| answer(0, &[OTHER])).with_program("git", "/fake/git");
            let e = check_runner_key(Some(K), Path::new("/r"), &other).unwrap_err();
            assert!(e.contains(&K[..12]) && e.contains(&OTHER[..12]), "{e}");
            assert!(e.contains("dotfiles 関数から打つ"), "{e}");

            let broken = FakeSys::new(|_| answer(128, &["fatal: not a git repository"]))
                .with_program("git", "/fake/git");
            assert!(
                check_runner_key(Some(K), Path::new("/r"), &broken)
                    .unwrap_err()
                    .contains("読めない")
            );

            let no_git = FakeSys::new(|_| answer(0, &[K]));
            assert!(
                check_runner_key(Some(K), Path::new("/r"), &no_git)
                    .unwrap_err()
                    .contains("git が見つからない")
            );
        }
    }

    mod flow {
        //! ## 確かめること (コマンドの流れ。偽の Sys と一時ディレクトリで)
        //!
        //! - check は何も書かず、入っていないものだけなら 3。apply は、受け持ちが WSL のホストでは Windows にしか無い手順だけを流し、
        //!   それを選んでいなければ止めて 1。runner.enable = true のホストは全部を揃える
        //! - apply --dry-run は何も書かず、本番が止まる・Windows にしか無い手順だけを流すことを知らせる
        //! - 相対パスの --repo は絶対パスにしてから使う (隣の clone と控えに相対パスを書かない)
        //! - ホストの値の既定の場所は、USERNAME と hostname (小文字) から。list は環境変数が無くても流せる
        //! - 知らない手順・ホストの値の誤り・環境変数が無いのは 2。manifest の誤りは 1
        //! - 色は出す先が端末で NO_COLOR が無いときだけ: stdout は見出しと締めの行、stderr は `!!` の誤りの行 (赤)

        use super::super::*;
        use crate::process::{Exit, RunResult, Stream};
        use crate::testutil::{FakeSys, TempDir};

        struct World {
            t: TempDir,
        }

        impl World {
            fn new(host: Option<&str>) -> Self {
                let t = TempDir::new("cli");
                t.write(
                    "g/dotfiles/win/manifest.toml",
                    "[[files]]\nsrc = \"app/a.json\"\ndst = \"%USERPROFILE%/.app/a.json\"\n",
                );
                t.write("g/dotfiles/win/app/a.json", "A\n");
                if let Some(h) = host {
                    t.write("g/dotfiles-private/win/hosts/alice@example-host.toml", h);
                }
                World { t }
            }

            fn sys(&self) -> FakeSys {
                let home = self.t.path().join("home");
                FakeSys::new(|c| {
                    if c.program == Path::new("hostname") {
                        RunResult {
                            exit: Exit::Code(0),
                            output: vec!["Example-Host".into()],
                        }
                    } else {
                        RunResult {
                            exit: Exit::Code(0),
                            output: vec![],
                        }
                    }
                })
                .with_env("USERNAME", "alice")
                .with_env("USERPROFILE", &home.to_string_lossy())
                .with_env(
                    "APPDATA",
                    &home.join("AppData").join("Roaming").to_string_lossy(),
                )
                .with_env(
                    "LOCALAPPDATA",
                    &home.join("AppData").join("Local").to_string_lossy(),
                )
            }

            fn run(&self, args: &[&str]) -> (i32, String, String) {
                self.run_with(&self.sys(), args)
            }

            fn run_with(&self, sys: &FakeSys, args: &[&str]) -> (i32, String, String) {
                let mut full: Vec<String> = args.iter().map(|s| s.to_string()).collect();
                full.push("--repo".into());
                full.push(
                    self.t
                        .path()
                        .join("g")
                        .join("dotfiles")
                        .to_string_lossy()
                        .into_owned(),
                );
                let (mut out, mut err) = (Vec::new(), Vec::new());
                let code = run(&full, sys, &mut out, &mut err);
                (
                    code,
                    String::from_utf8(out).unwrap(),
                    String::from_utf8(err).unwrap(),
                )
            }

            fn dst(&self) -> PathBuf {
                self.t.path().join("home").join(".app").join("a.json")
            }

            fn record(&self) -> PathBuf {
                self.t
                    .path()
                    .join("home")
                    .join("AppData")
                    .join("Local")
                    .join("dotfiles")
                    .join("state")
                    .join("windows-files.deployed.json")
            }
        }

        #[test]
        fn check_writes_nothing() {
            let w = World::new(Some("group = \"minimum\"\n"));
            let (code, out, _) = w.run(&["check", "--steps", "files"]);
            assert_eq!(code, 3, "{out}");
            assert!(out.contains("==> dotfiles check"));
            assert!(out.contains("alice@example-host.toml (グループ minimum)"));
            assert!(out.contains("受け持ち: WSL の setup"));
            assert!(out.contains("⚠️ 入っていない・無いものがある → dotfiles apply で揃える ⚠️"));
            assert!(!w.dst().exists());
            assert!(!w.record().exists());
        }

        #[test]
        fn apply_stops_unless_runner_enabled() {
            let w = World::new(Some(""));
            let (code, out, _) = w.run(&["apply", "--steps", "files"]);
            assert_eq!(code, 1);
            assert!(out.contains(
                "受け持ちは WSL の setup (runner.enable が true でない) なので apply は止めた"
            ));
            assert!(out.contains("止めたので何も変えていない"));
            assert!(!w.dst().exists());

            let (code, out, _) = w.run(&["apply", "--dry-run", "--steps", "files"]);
            assert_eq!(code, 3);
            assert!(out.contains("※ 本番の apply は止まる"));
            assert!(out.contains("[dry-run] コピー: "));
            assert!(!w.dst().exists());
        }

        /// 受け持ちが WSL のホストでも、Windows にしか無い手順 (claude-notion) は apply が書き、WSL と同じ手順 (files) は流さない
        #[test]
        fn wsl_host_applies_windows_only_steps() {
            let w = World::new(Some(
                "[tools]\nwindowsClaudeCode = true\n[claude.notion]\nprofile = \"personal\"\n",
            ));
            let notion =
                w.t.path()
                    .join("home")
                    .join(".local")
                    .join("state")
                    .join("dotfiles")
                    .join("claude-notion.json");
            let (code, out, _) = w.run(&["apply", "--dry-run", "--steps", "files,claude-notion"]);
            assert_eq!(code, 3, "{out}");
            assert!(out.contains("※ 本番の apply は、受け持ちが WSL の setup なので Windows にしか無い手順だけを流す"), "{out}");
            assert!(!notion.exists());

            let (code, out, _) = w.run(&["apply", "--steps", "files,claude-notion"]);
            assert_eq!(code, 0, "{out}");
            assert!(out.contains("受け持ち: WSL の setup (runner.enable が true でない。apply は Windows にしか無い手順だけを流す)"), "{out}");
            assert!(out.contains("受け持ちは WSL の setup なので apply では流さない (WSL の setup の bootstrap-windows-files.sh が流す)"), "{out}");
            assert_eq!(
                std::fs::read_to_string(&notion).unwrap(),
                "{\"override\":{},\"profile\":\"personal\",\"routes\":{}}\n"
            );
            assert!(!w.dst().exists());
            assert!(!w.record().exists());
        }

        #[test]
        fn apply_copies_when_runner_enabled() {
            let w = World::new(Some("[runner]\nenable = true\n"));
            let (code, out, _) = w.run(&["apply", "--steps", "files"]);
            assert_eq!(code, 0, "{out}");
            assert_eq!(std::fs::read_to_string(w.dst()).unwrap(), "A\n");
            assert!(w.record().exists());
            assert!(out.contains("✔ 直すことはありません"));
            let (code, _, _) = w.run(&["check", "--steps", "files"]);
            assert_eq!(code, 0);
        }

        #[test]
        fn missing_host_file_checks_with_defaults_but_blocks_apply() {
            let w = World::new(None);
            let (code, out, _) = w.run(&["check", "--steps", "files"]);
            assert_eq!(code, 1);
            assert!(out.contains("ホストの値が無い ("));
            // 見た 2 つの場所 (手元の host.toml と dotfiles-private) を、引く順に並べる
            let local =
                w.t.path()
                    .join("home")
                    .join(".config")
                    .join("dotfiles")
                    .join("host.toml");
            let private =
                w.t.path()
                    .join("g")
                    .join("dotfiles-private")
                    .join("win")
                    .join("hosts")
                    .join("alice@example-host.toml");
            assert!(
                out.contains(&format!(
                    "ホストの値: 無い ({}・{})",
                    local.display(),
                    private.display()
                )),
                "{out}"
            );
            let (code, out, _) = w.run(&["apply", "--steps", "files"]);
            assert_eq!(code, 1);
            assert!(out.contains("ホストの値が無いので apply は止めた"));
            assert!(!w.dst().exists());
        }

        #[test]
        fn list_shows_steps_without_windows_env() {
            let w = World::new(Some("[tools]\nwindowsTypeClipboard = true\n"));
            let sys = FakeSys::new(|_| RunResult {
                exit: Exit::Code(0),
                output: vec!["example-host".into()],
            })
            .with_env("USERNAME", "alice");
            let (code, out, _) = w.run_with(&sys, &["list"]);
            assert_eq!(code, 0, "{out}");
            assert!(out.contains("[90] files"));
            // まだ無い手順の印は、PENDING にある手順にだけ付く (今は空: WSL の setup の Windows の手順は全部 runner に移した)
            match crate::steps::pending::PENDING.first() {
                None => assert!(!out.contains("runner にまだ無い"), "{out}"),
                Some(p) => assert!(
                    out.contains(&format!(
                        "runner にまだ無い。WSL の bootstrap-windows-{}.sh",
                        p.id
                    )),
                    "{out}"
                ),
            }
            // 移した op-reason は onePassword (minimum では既定が off) で on/off
            let op_reason = out
                .lines()
                .find(|l| l.contains("] op-reason "))
                .unwrap_or_else(|| panic!("{out}"));
            assert!(
                op_reason.contains("  off  WSL の op の Windows の部品 (op-reason の zip) を固定した版に揃える (onePassword = false。グループ minimum の既定)"),
                "{op_reason}"
            );
            assert!(out.contains("[97] type-clipboard"));
            assert!(!out.contains("type-clipboard を固定した版で入れる (ずれていても入れ替えない) (windowsTypeClipboard"));
            // runner に移した powershell-profile は on の手順として出る (まだ無い手順の印は付かない)
            let profile = out
                .lines()
                .find(|l| l.contains("] powershell-profile "))
                .unwrap_or_else(|| panic!("{out}"));
            assert!(
                profile.contains("  on   $PROFILE から dotfiles.ps1 を読ませる"),
                "{profile}"
            );
            assert!(!profile.contains("runner にまだ無い"), "{profile}");
        }

        /// runner に移した WSL と同じ手順 (powershell-profile) は、受け持ちが WSL のホストの apply では流さず ($PROFILE に触らず、pwsh も
        /// 呼ばない)、check は今の $PROFILE を確かめて、揃えるのは WSL の setup だと添える
        #[test]
        fn wsl_host_leaves_powershell_profile_to_wsl() {
            let w = World::new(Some(
                "[tools]\nwindowsClaudeCode = true\n[claude.notion]\nprofile = \"personal\"\n",
            ));
            w.t.write("home/.config/powershell/dotfiles.ps1", "# dotfiles.ps1\n");
            let home = w.t.path().join("home");
            let profile = home
                .join("Documents")
                .join("PowerShell")
                .join("Microsoft.PowerShell_profile.ps1");
            let answer = profile.to_string_lossy().into_owned();
            let sys = FakeSys::new(move |c| {
                let output = if c.program == Path::new("hostname") {
                    vec!["Example-Host".to_string()]
                } else {
                    vec![answer.clone()]
                };
                RunResult {
                    exit: Exit::Code(0),
                    output,
                }
            })
            .with_program("pwsh", "/fake/pwsh")
            .with_env("USERNAME", "alice")
            .with_env("USERPROFILE", &home.to_string_lossy())
            .with_env(
                "APPDATA",
                &home.join("AppData").join("Roaming").to_string_lossy(),
            )
            .with_env(
                "LOCALAPPDATA",
                &home.join("AppData").join("Local").to_string_lossy(),
            );
            let pwsh_calls = |sys: &FakeSys| {
                sys.calls
                    .borrow()
                    .iter()
                    .filter(|c| c.program == Path::new("/fake/pwsh"))
                    .count()
            };

            let (code, out, _) = w.run_with(
                &sys,
                &["apply", "--steps", "claude-notion,powershell-profile"],
            );
            assert_eq!(code, 0, "{out}");
            assert!(out.contains("受け持ちは WSL の setup なので apply では流さない (WSL の setup の bootstrap-windows-powershell-profile.sh が流す)"), "{out}");
            assert!(!profile.exists());
            assert_eq!(pwsh_calls(&sys), 0);

            let (code, out, _) = w.run_with(&sys, &["check", "--steps", "powershell-profile"]);
            assert_eq!(code, 3, "{out}");
            assert!(
                out.contains(
                    "━━ [95] powershell-profile: $PROFILE から dotfiles.ps1 を読ませる ━━"
                ),
                "{out}"
            );
            assert!(
                out.contains("揃えるのは WSL の ~/dotfiles/setup --update"),
                "{out}"
            );
            assert_eq!(pwsh_calls(&sys), 1);
            assert!(!profile.exists());
        }

        /// 取り込みは受け持ちが runner のホストだけ (WSL の間は WSL の script の --import を案内して止める)。Windows 側には書かず、repo のファイルを書く
        #[test]
        fn import_terminal_needs_the_runner() {
            let w = World::new(Some(""));
            let (code, out, _) = w.run(&["import", "terminal"]);
            assert_eq!(code, 1, "{out}");
            assert!(out.contains("==> dotfiles import terminal"), "{out}");
            assert!(out.contains("なので取り込みは止めた"), "{out}");
            assert!(
                out.contains("nix/scripts/bootstrap-windows-terminal.sh --import を打つ"),
                "{out}"
            );
            // fancyzones は名前ごとに --import を付け、bash の一重引用符で囲む
            let (code, out, _) = w.run(&["import", "fancyzones", "a b", "it's"]);
            assert_eq!(code, 1, "{out}");
            assert!(
                out.contains(
                    "nix/scripts/bootstrap-windows-fancyzones.sh --import 'a b' --import 'it'\\''s' を打つ"
                ),
                "{out}"
            );

            let w = World::new(Some("[runner]\nenable = true\n"));
            let managed = w.t.write(
                "g/dotfiles/win/windows-terminal/managed.json",
                "{\n    \"copyOnSelect\": true\n}\n",
            );
            let settings = w.t.write(
                "home/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json",
                "{\"copyOnSelect\": false}\n",
            );
            let sys = w.sys().with_program("git", "/fake/git");
            let (code, out, _) = w.run_with(&sys, &["import", "terminal"]);
            assert_eq!(code, 0, "{out}");
            assert!(out.contains("==> 結果 (import)"), "{out}");
            assert_eq!(
                std::fs::read_to_string(&managed).unwrap(),
                "{\n    \"copyOnSelect\": false\n}\n"
            );
            assert_eq!(
                std::fs::read_to_string(&settings).unwrap(),
                "{\"copyOnSelect\": false}\n"
            );
            assert!(sys.call_args().iter().any(|a| a.contains(
                "status --porcelain --untracked-files=normal -- win/windows-terminal/managed.json"
            )));
        }

        /// international も、受け持ちが WSL の間は WSL の script の --import を案内して止める (名前は取らない)
        #[test]
        fn import_international_needs_the_runner() {
            let w = World::new(Some(""));
            let (code, out, _) = w.run(&["import", "international"]);
            assert_eq!(code, 1, "{out}");
            assert!(out.contains("==> dotfiles import international"), "{out}");
            assert!(
                out.contains("nix/scripts/bootstrap-windows-international.sh --import を打つ"),
                "{out}"
            );
        }

        /// google-ime も、受け持ちが WSL の間は WSL の script の --import を案内して止める (名前は取らない)
        #[test]
        fn import_google_ime_needs_the_runner() {
            let w = World::new(Some(""));
            let (code, out, _) = w.run(&["import", "google-ime"]);
            assert_eq!(code, 1, "{out}");
            assert!(out.contains("==> dotfiles import google-ime"), "{out}");
            assert!(
                out.contains("nix/scripts/bootstrap-windows-google-ime.sh --import を打つ"),
                "{out}"
            );
        }

        #[test]
        fn errors_exit_2() {
            let w = World::new(Some(""));
            let (code, _, err) = w.run(&["check", "--steps", "nope"]);
            assert_eq!(code, 2);
            assert!(err.contains("知らない手順です: nope"));

            let bad = World::new(Some("grop = 1\n"));
            let (code, _, err) = bad.run(&["check"]);
            assert_eq!(code, 2);
            assert!(err.contains("知らないキーがあります"));

            let no_env = FakeSys::new(|_| RunResult {
                exit: Exit::Code(1),
                output: vec![],
            });
            let (code, _, err) = w.run_with(&no_env, &["check"]);
            assert_eq!(code, 2);
            assert!(err.contains("USERNAME"));
        }

        /// 出す先が端末で NO_COLOR が無いときだけ色を付ける。stdout は見出しと締めの行、stderr は runner が動けない・manifest の誤りの
        /// `!!` の行 (赤)。端末かは出す先ごとに見る
        #[test]
        fn colors_only_terminals_without_no_color() {
            let w = World::new(Some("group = \"minimum\"\n"));
            let tty = || {
                w.sys()
                    .with_terminal(Stream::Stdout)
                    .with_terminal(Stream::Stderr)
            };
            let (code, out, _) = w.run_with(&tty(), &["check", "--steps", "files"]);
            assert_eq!(code, 3, "{out}");
            assert!(
                out.starts_with(
                    "\u{1b}[1m==> dotfiles check (確かめるだけ。何も書かない)\u{1b}[0m\n"
                ),
                "{out:?}"
            );
            assert!(
                out.contains(
                    "\n\u{1b}[1;33m⚠️ 入っていない・無いものがある → dotfiles apply で揃える ⚠️\u{1b}[0m\n"
                ),
                "{out:?}"
            );
            let (code, out, _) = w.run_with(&tty(), &["apply", "--dry-run", "--steps", "files"]);
            assert_eq!(code, 3, "{out}");
            assert!(
                out.starts_with(
                    "\u{1b}[1m==> dotfiles apply --dry-run (することを出すだけ。何も書かない)\u{1b}[0m\n"
                ),
                "{out:?}"
            );
            let (code, _, err) = w.run_with(&tty(), &["check", "--steps", "nope"]);
            assert_eq!(code, 2);
            assert_eq!(
                err,
                "\u{1b}[31m!! 知らない手順です: nope (dotfiles list で見る)\u{1b}[0m\n"
            );
            let (code, _, err) = w.run_with(&tty(), &["frobnicate"]);
            assert_eq!(code, 2);
            assert!(
                err.starts_with(
                    "\u{1b}[31m!! 知らないコマンドです: frobnicate\u{1b}[0m\n\ndotfiles の Windows 側の runner"
                ),
                "{err:?}"
            );
            w.t.write("g/dotfiles/win/manifest.toml", "x = 1\n");
            let (code, _, err) = w.run_with(&tty(), &["manifest"]);
            assert_eq!(code, 1);
            assert!(
                err.starts_with("\u{1b}[31m!! ") && err.ends_with("\u{1b}[0m\n"),
                "{err:?}"
            );

            // 端末でない・NO_COLOR があるなら、どちらにも色の字を出さない
            for sys in [w.sys(), tty().with_env("NO_COLOR", "1")] {
                let (_, out, err) = w.run_with(&sys, &["manifest"]);
                assert!(
                    !out.contains('\u{1b}') && !err.contains('\u{1b}'),
                    "{err:?}"
                );
                let (_, _, err) = w.run_with(&sys, &["check", "--steps", "nope"]);
                assert_eq!(err, "!! 知らない手順です: nope (dotfiles list で見る)\n");
            }
            // stdout だけが端末なら stderr には付けない
            let out_only = w.sys().with_terminal(Stream::Stdout);
            let (_, _, err) = w.run_with(&out_only, &["check", "--steps", "nope"]);
            assert_eq!(err, "!! 知らない手順です: nope (dotfiles list で見る)\n");
        }

        #[test]
        fn manifest_command() {
            let w = World::new(None);
            let (code, out, _) = w.run(&["manifest"]);
            assert_eq!(code, 0);
            assert_eq!(out, "win/manifest.toml: OK (1 件)\n");
            let (code, out, _) = w.run(&["manifest", "--json", "--windows-home", "/mnt/c/Users/x"]);
            assert_eq!(code, 0);
            let v: serde_json::Value = serde_json::from_str(&out).unwrap();
            assert_eq!(v["files"][0]["repoPath"], "win/app/a.json");
            w.t.write("g/dotfiles/win/manifest.toml", "x = 1\n");
            let (code, _, err) = w.run(&["manifest"]);
            assert_eq!(code, 1);
            assert!(err.contains("知らないキーがあります"));
        }

        /// 手元の %USERPROFILE%\.config\dotfiles\host.toml を、dotfiles-private より先に読む (gh にログインできない PC。bootstrap が雛形を写す)
        #[test]
        fn local_host_file_is_read_before_dotfiles_private() {
            let w = World::new(None);
            let local = w.t.write(
                "home/.config/dotfiles/host.toml",
                "[runner]\nenable = true\n",
            );
            let (code, out, _) = w.run(&["list"]);
            assert_eq!(code, 0, "{out}");
            assert!(
                out.contains(&format!(
                    "ホストの値: {} (グループ minimum)",
                    local.display()
                )),
                "{out}"
            );
            assert!(out.contains("受け持ち: runner"), "{out}");
            // 手元の値で apply できる
            let (code, out, _) = w.run(&["apply", "--steps", "files"]);
            assert_eq!(code, 0, "{out}");
            assert!(w.dst().exists());
        }

        /// 手元の host.toml と dotfiles-private の両方があれば、check は手元の値で確かめて ⚠ を出し、apply は書かずに止まる。--host-file なら 1 つだけ読む
        #[test]
        fn both_host_files_warn_on_check_and_stop_apply() {
            let w = World::new(Some("[runner]\nenable = true\n"));
            w.t.write(
                "home/.config/dotfiles/host.toml",
                "group = \"all\"\n[runner]\nenable = true\n",
            );
            let (code, out, _) = w.run(&["check", "--steps", "files"]);
            assert_eq!(code, 1, "{out}");
            assert!(out.contains("ホストの値が 2 つある ("), "{out}");
            assert!(
                out.contains("(グループ all)。dotfiles-private の "),
                "{out}"
            );
            let (code, out, _) = w.run(&["apply", "--steps", "files"]);
            assert_eq!(code, 1, "{out}");
            assert!(
                out.contains("ホストの値が 2 つある (手元の host.toml と dotfiles-private) ので apply は止めた"),
                "{out}"
            );
            assert!(!w.dst().exists());
            let (code, out, _) = w.run(&["apply", "--dry-run", "--steps", "files"]);
            assert_eq!(code, 1, "{out}");
            assert!(
                out.contains("※ 本番の apply は止まる: ホストの値が 2 つある"),
                "{out}"
            );
            // --host-file で渡せば、両方を見ずにその 1 つを読む
            let private =
                w.t.path()
                    .join("g")
                    .join("dotfiles-private")
                    .join("win")
                    .join("hosts")
                    .join("alice@example-host.toml");
            let (code, out, _) = w.run(&[
                "apply",
                "--steps",
                "files",
                "--host-file",
                &private.to_string_lossy(),
            ]);
            assert_eq!(code, 0, "{out}");
            assert!(!out.contains("2 つある"), "{out}");
            assert!(w.dst().exists());
        }

        /// 一時の場所の clone から流しても、ホストの値を bootstrap の置き場 (%USERPROFILE%\ghq\github.com\pollenjp\dotfiles-private) で見つける
        #[test]
        fn host_file_falls_back_to_bootstrap_place() {
            let w = World::new(None);
            w.t.write(
                "home/ghq/github.com/pollenjp/dotfiles-private/win/hosts/alice@example-host.toml",
                "group = \"all\"\n",
            );
            let (code, out, _) = w.run(&["list"]);
            assert_eq!(code, 0, "{out}");
            let want =
                w.t.path()
                    .join("home")
                    .join("ghq")
                    .join("github.com")
                    .join("pollenjp")
                    .join("dotfiles-private")
                    .join("win")
                    .join("hosts")
                    .join("alice@example-host.toml");
            assert!(
                out.contains(&format!("ホストの値: {} (グループ all)", want.display())),
                "{out}"
            );
        }

        /// 相対パスの --repo は絶対パスにしてから使う (cargo test の cwd は win/runner なので ../.. は dotfiles の root)
        #[test]
        fn relative_repo_becomes_absolute() {
            let sys = FakeSys::new(|_| RunResult {
                exit: Exit::Code(0),
                output: vec!["example-host".into()],
            })
            .with_env("USERNAME", "alice");
            let args: Vec<String> = ["list", "--repo", "../.."]
                .iter()
                .map(|s| s.to_string())
                .collect();
            let (mut out, mut err) = (Vec::new(), Vec::new());
            assert_eq!(run(&args, &sys, &mut out, &mut err), 0);
            let out = String::from_utf8(out).unwrap();
            let line = out.lines().find(|l| l.starts_with("ホストの値: ")).unwrap();
            // 「ホストの値: <path> (グループ …)」か「ホストの値: 無い (<path>)。…」
            let rest = line.trim_start_matches("ホストの値: ");
            let shown = match rest.strip_prefix("無い (") {
                Some(r) => r.split(')').next().unwrap(),
                None => rest.split(" (").next().unwrap(),
            };
            assert!(Path::new(shown).is_absolute(), "{line}");
        }

        #[test]
        fn hostname_falls_back_to_computername() {
            let w = World::new(Some(""));
            let sys = FakeSys::new(|_| RunResult {
                exit: Exit::SpawnFailed("x".into()),
                output: vec![],
            })
            .with_env("USERNAME", "alice")
            .with_env("COMPUTERNAME", "EXAMPLE-HOST");
            let (code, out, _) = w.run_with(&sys, &["list"]);
            assert_eq!(code, 0);
            assert!(
                out.contains("alice@example-host.toml (グループ minimum)"),
                "{out}"
            );
        }
    }
}
