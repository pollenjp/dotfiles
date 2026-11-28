//! pjp-tools (order 54): ハブと子の道具 (`nix/pkgs/pjp-tools` の workspace。入口 `pjp` と `pjp-hub`・`pjp-child`・`pjp-mark`・`pjp-pack`) の exe を、
//! clone の HEAD の workspace に合う GitHub の Release から落として `%LOCALAPPDATA%\dotfiles\bin\` に置き、置き場をユーザーの PATH に足す
//! (claude-selector と同じ置き場。win/README.md の「ハブと子の道具 (pjp-tools)」。dotfiles-private の docs/adr/124_*)。cargo の無い PC
//! (Build Tools と rustup を入れない minimum の PC) でも入る。
//!
//! - key: clone の `git rev-parse HEAD:nix/pkgs/pjp-tools` (workspace の git の tree の hash)。Release は `pjp-tools-<key の頭 12 字>`、asset は
//!   `pjp-tools-windows-x86_64.zip` (5 つの exe を root に) と `.sha256`。作るのは CI (`.github/workflows/pjp-tools-release.yml`)。`pjp --version`
//!   は埋めた key を `key=` の行で名乗る
//! - 写し: `%LOCALAPPDATA%\dotfiles\pjp-tools\<key>\` に 5 つの exe と印 `verified` (key・出どころ (release か cargo)・5 つの exe の sha256 の行)。
//!   印は写しの `pjp --version` が key を名乗るのを確かめてから付け、写しの exe を替えたら効かない (落とし直す)。新しい方 (印の時刻。印が無ければ
//!   dir の時刻) から、今の key を含めて 3 つを残す
//! - 決め方 (win/README.md の表): 印の効く写しがあれば bin に写す。無ければ Release から落とし、.sha256 と key を確かめて印を付けて写す。Release が
//!   無い (404)・届かないときは、cargo があれば workspace で `cargo build --release --locked` (`PJP_TOOLS_KEY=<key>`) で作り、無ければわけと直し方
//!   を出して止まる。sha256・key が合わない Release は、cargo があっても使わずに止まる (黙って cargo に戻らない。差し替えの印を隠さない)
//! - 手元の変更 (`git status --porcelain -- nix/pkgs/pjp-tools` が空でない): 写しを使わず・作らず、cargo で作って bin に直に置く (`PJP_TOOLS_KEY`
//!   は外す。手元の build は key を名乗らない)。cargo が無ければ止まる (手元の変更は Release に無い)
//! - bin に写す: 写しと sha256 が違う exe だけを、動いていても上書きできる `claude_files::replace_file` で。PATH は claude-selector と同じ
//! - check は何も落とさず・作らず、写しと印・bin の一致を見る (写しが無ければ、bin の `pjp --version` の key も添える)。dry-run は打つもの
//!   (落とす URL・作る cargo・写すファイル・消す古い写し) を出す。どちらも Release があるかは見ない (ネットワークに出ない)
//!
//! 落とすのと解くのは PowerShell (`Invoke-WebRequest -UseBasicParsing`・`Expand-Archive`。launcher の `Invoke-DotfilesRunner.ps1` と同じ道具)。
//! 値は env で渡し、script は ASCII だけにする (`user_path` と同じ)。止まっても、落ちるのはこの手順の行だけ (ほかの手順は進む)。
//!
//! gate は herdrHub か claudePrivateSkills (ハブの道具を使うホストと、claude-skills の道具を入口 `pjp` から起こすホスト)。

use super::claude_accounts::{BIN_DIR_REL, PathState, sync_user_path};
use super::claude_files::replace_file;
use super::pjp::{channel_ok, locate_cargo, read_toml_string};
use super::ps1::{find_powershell, run_streaming};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::build_info::is_object_name;
use crate::context::{Ctx, join_segments};
use crate::fsutil;
use crate::process::{CommandSpec, Exit, RunResult};
use crate::report::Kind;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// workspace の置き場 (dotfiles の clone からの相対。`/` 区切り)
pub const WORKSPACE_REL: &str = "nix/pkgs/pjp-tools";
/// key ごとの写しの置き場 (`%LOCALAPPDATA%` からの相対)
pub const CACHE_REL: &str = "dotfiles/pjp-tools";
/// Release の download の URL の根 (REST API は呼ばない)
pub const BASE_URL: &str = "https://github.com/pollenjp/dotfiles/releases/download";
/// Release の tag の頭 (後ろに key の頭 12 字)
pub const TAG_PREFIX: &str = "pjp-tools-";
/// Release の asset (5 つの exe を root に入れた zip と、その sha256)
pub const ZIP_NAME: &str = "pjp-tools-windows-x86_64.zip";
pub const SHA_NAME: &str = "pjp-tools-windows-x86_64.zip.sha256";
/// 写しを確かめた印 (写しの dir の中)
pub const MARK_NAME: &str = "verified";
/// 残す写しの数 (今の key を含む)
pub const KEEP: usize = 3;
/// 置く道具 (exe の名前は Windows なら `<名前>.exe`)
pub const TOOLS: [&str; 5] = ["pjp", "pjp-hub", "pjp-child", "pjp-mark", "pjp-pack"];
/// exe に key を埋める環境変数 (`pjp --version` の `key=` の行。nix/pkgs/pjp-tools/crates/pjp)
pub const KEY_ENV: &str = "PJP_TOOLS_KEY";
/// 落とす PowerShell に値を渡す環境変数
pub const SHA_URL_ENV: &str = "DOTFILES_PJP_TOOLS_SHA_URL";
pub const SHA_OUT_ENV: &str = "DOTFILES_PJP_TOOLS_SHA_OUT";
pub const ZIP_URL_ENV: &str = "DOTFILES_PJP_TOOLS_ZIP_URL";
pub const ZIP_OUT_ENV: &str = "DOTFILES_PJP_TOOLS_ZIP_OUT";
/// 解く PowerShell に値を渡す環境変数
pub const ZIP_ENV: &str = "DOTFILES_PJP_TOOLS_ZIP";
pub const DEST_ENV: &str = "DOTFILES_PJP_TOOLS_DEST";
/// cargo build の待ちの上限 (初めては 5 つの道具と依存を全部作る)
const BUILD_SECS: u64 = 1800;
/// 落とす PowerShell の待ちの上限 (中で .sha256 は 20 秒、zip は 300 秒で切る)
const DOWNLOAD_SECS: u64 = 400;
/// 解く PowerShell の待ちの上限
const EXPAND_SECS: u64 = 120;
/// git と exe の --version の待ちの上限
const QUICK_SECS: u64 = 30;
/// PATH に足したときに添える文
const NEW_TERMINAL: &str = "PATH は新しい端末から効く。herdr-app とその中の端末・動いている Claude Code には効かないので、herdr-app を上げ直すか、新しい PowerShell で pjp を打つ";
/// cargo の無いホストの check に添える文
const NO_CARGO: &str = "cargo が無い: key の Release が無ければ apply は止まる (merge の直後なら数分待つ。手元で作るなら Install-Bootstrap.ps1 -Rust で Build Tools と rustup を入れる)";
/// exe を起こせないときに添える文 (launcher の Get-DotfilesRunnerLaunchHint と同じ見方)
const LAUNCH_HINT: &str = "Smart App Control か App Control・AppLocker に止められたなら、Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 でオフにする (会社の PC の App Control・AppLocker は管理者に聞く。手元の cargo で作った exe も同じく止められる)。ウイルス対策に止められたなら「保護の履歴」を見る";

/// .sha256 と zip を落とす (launcher の Invoke-DotfilesRunnerDownload と同じ道具)。落とせなければ `status=<HTTP の状態の番号。無ければ 0>` と
/// `error=<文>` を出して 1 で終わる (try の中の exit は catch に捕まらない)。進み具合の表示は 5.1 で落とすのを大きく遅くするので切り、5.1 は
/// TLS 1.2 を足す。-UseBasicParsing は 5.1 の KB5074596 からの確かめを出させないため。.sha256 は小さいので、届かないネットワークで長く待たない
/// よう短く切る
pub const DOWNLOAD_SCRIPT: &str = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; try { if ($PSVersionTable.PSVersion.Major -lt 6) { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }; Invoke-WebRequest -Uri $env:DOTFILES_PJP_TOOLS_SHA_URL -OutFile $env:DOTFILES_PJP_TOOLS_SHA_OUT -UseBasicParsing -TimeoutSec 20; Invoke-WebRequest -Uri $env:DOTFILES_PJP_TOOLS_ZIP_URL -OutFile $env:DOTFILES_PJP_TOOLS_ZIP_OUT -UseBasicParsing -TimeoutSec 300; exit 0 } catch { $err = $_; $status = 0; try { $p = $err.Exception.PSObject.Properties['Response']; if (($null -ne $p) -and ($null -ne $p.Value)) { $status = [int]$p.Value.StatusCode } } catch { $status = 0 }; Write-Output ('status=' + $status); Write-Output ('error=' + $err.Exception.Message); exit 1 }";

/// zip を写しの dir に解く (上書き)。Windows PowerShell 5.1 の Expand-Archive は名前が .zip のファイルしか受けない。解けなければ `error=<文>` を
/// 出して 1 で終わる
pub const EXPAND_SCRIPT: &str = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; try { Expand-Archive -LiteralPath $env:DOTFILES_PJP_TOOLS_ZIP -DestinationPath $env:DOTFILES_PJP_TOOLS_DEST -Force; exit 0 } catch { Write-Output ('error=' + $_.Exception.Message); exit 1 }";

/// 道具の exe の名前 (Windows は `<名前>.exe`。ほかの OS の名前は試験のため)
pub fn exe_name(tool: &str) -> String {
    format!("{tool}{}", std::env::consts::EXE_SUFFIX)
}

/// 置く 5 つの exe の名前 (TOOLS の順)
pub fn exe_names() -> Vec<String> {
    TOOLS.iter().map(|t| exe_name(t)).collect()
}

/// key の頭 12 字 (出す行と tag に使う)
fn short(key: &str) -> String {
    key.chars().take(12).collect()
}

/// key の Release の tag
pub fn tag(key: &str) -> String {
    format!("{TAG_PREFIX}{}", short(key))
}

/// key の Release の asset の URL
pub fn asset_url(key: &str, name: &str) -> String {
    format!("{BASE_URL}/{}/{name}", tag(key))
}

/// 64 字の小文字の 16 進か (sha256)
fn is_sha256(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// .sha256 の中身 (sha256sum の形「<64 字>  <名前>」) の、1 行目の頭の 64 字の 16 進 (小文字)。無ければ None
pub fn parse_sha256(text: &str) -> Option<String> {
    let line = text.lines().map(str::trim).find(|l| !l.is_empty())?;
    let token = line.split_whitespace().next()?.to_ascii_lowercase();
    is_sha256(&token).then_some(token)
}

/// 写しの出どころ。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// key の Release から落とした
    Release,
    /// Release が無く、手元の cargo で作った
    Cargo,
}

impl Source {
    fn as_str(self) -> &'static str {
        match self {
            Source::Release => "release",
            Source::Cargo => "cargo",
        }
    }

    fn parse(s: &str) -> Option<Source> {
        match s {
            "release" => Some(Source::Release),
            "cargo" => Some(Source::Cargo),
            _ => None,
        }
    }
}

/// 写しを確かめた印 (`verified`)。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mark {
    pub key: String,
    pub source: Source,
    /// exe の名前 → sha256
    pub sums: BTreeMap<String, String>,
}

impl Mark {
    /// 読む。key・出どころ・5 つの exe の sha256 が揃っていなければ None (知らない行は読み飛ばす)
    pub fn parse(text: &str) -> Option<Mark> {
        let fields: BTreeMap<&str, &str> = text
            .lines()
            .filter_map(|l| l.trim().split_once('='))
            .collect();
        let key = fields.get("key").filter(|k| is_object_name(k))?.to_string();
        let source = fields.get("source").and_then(|s| Source::parse(s))?;
        let mut sums = BTreeMap::new();
        for name in exe_names() {
            let sum = fields.get(name.as_str()).filter(|s| is_sha256(s))?;
            sums.insert(name, sum.to_string());
        }
        Some(Mark { key, source, sums })
    }

    /// 書く (key・出どころ・exe ごとの sha256 の行)
    pub fn render(&self) -> String {
        let mut s = format!("key={}\nsource={}\n", self.key, self.source.as_str());
        for name in exe_names() {
            if let Some(sum) = self.sums.get(&name) {
                s.push_str(&format!("{name}={sum}\n"));
            }
        }
        s
    }
}

/// 写しの様子。
enum Cache {
    /// 印が今の exe と合う
    Valid(Mark),
    /// 写しが無い (dir か印が無い)
    Missing,
    /// 印はあるが、今の exe と合わない・読めない (わけ)
    Stale(String),
}

/// key の写しの dir を読む (印を読み、5 つの exe の sha256 を印と比べる)
fn read_cache(dir: &Path, key: &str) -> Cache {
    let text = match std::fs::read_to_string(dir.join(MARK_NAME)) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Cache::Missing,
        Err(e) => return Cache::Stale(format!("印が読めない: {e}")),
    };
    let Some(mark) = Mark::parse(&text) else {
        return Cache::Stale("印が読めない形".to_string());
    };
    if mark.key != key {
        return Cache::Stale(format!("印の key が {}", short(&mark.key)));
    }
    for (name, want) in &mark.sums {
        match fsutil::sha256_file(&dir.join(name)) {
            Ok(have) if have == *want => {}
            Ok(_) => return Cache::Stale(format!("{name} が印と違う")),
            Err(_) => return Cache::Stale(format!("{name} が無い")),
        }
    }
    Cache::Valid(mark)
}

/// 落とした結果。
#[derive(Clone, Debug, PartialEq, Eq)]
enum Fetch {
    Done,
    /// Release が無い (HTTP 404)
    NotFound,
    /// 落とせない (わけ)。404 でない HTTP の誤り・届かない・時間切れ
    Failed(String),
}

/// 落とす PowerShell の結果を読む (`status=`・`error=` の行)
fn classify(r: &RunResult) -> Fetch {
    if r.code() == Some(0) {
        return Fetch::Done;
    }
    let field = |k: &str| {
        r.output
            .iter()
            .find_map(|l| l.trim().strip_prefix(k).map(str::to_string))
    };
    match field("status=").and_then(|s| s.parse::<u16>().ok()) {
        Some(404) => Fetch::NotFound,
        Some(n) if n > 0 => Fetch::Failed(format!("HTTP {n}")),
        _ => Fetch::Failed(match (&r.exit, field("error=").filter(|e| !e.is_empty())) {
            (Exit::TimedOut, _) => format!("{DOWNLOAD_SECS} 秒で時間切れ"),
            (_, Some(e)) => e,
            (exit, None) => format!("{exit:?}: {}", r.output.join(" / ")),
        }),
    }
}

/// 消す古い写しの dir。今の key は消さず、ほかを新しい方 (印の時刻。印が無ければ dir の時刻) から KEEP - 1 個残す。key の形 (40 字の 16 進) で
/// ない名前と、dir でないもの (リンクも) には触らない
pub fn stale_dirs(root: &Path, current: &str) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut others: Vec<(SystemTime, PathBuf)> = entries
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            is_object_name(&name) && name != current
        })
        .map(|e| (newness(&e.path()), e.path()))
        .collect();
    // 新しい順 (同じ時刻は名前の順)
    others.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    others
        .into_iter()
        .skip(KEEP.saturating_sub(1))
        .map(|(_, p)| p)
        .collect()
}

/// 写しの新しさ (印の時刻。印が無ければ dir の時刻)
fn newness(dir: &Path) -> SystemTime {
    std::fs::metadata(dir.join(MARK_NAME))
        .or_else(|_| std::fs::metadata(dir))
        .and_then(|m| m.modified())
        .unwrap_or(SystemTime::UNIX_EPOCH)
}

/// PowerShell で `script` を流すコマンド (値は呼ぶ側が env で渡す)
fn powershell(shell: &Path, script: &str, secs: u64) -> CommandSpec {
    CommandSpec::new(shell)
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(script)
        .timeout(Duration::from_secs(secs))
}

/// 止まるわけ (締めの表の行の文と、添える行)。
struct Stop {
    why: String,
    notes: Vec<String>,
}

impl Stop {
    fn new(why: impl Into<String>) -> Stop {
        Stop {
            why: why.into(),
            notes: Vec::new(),
        }
    }

    fn note(mut self, n: impl Into<String>) -> Stop {
        self.notes.push(n.into());
        self
    }
}

/// Release の中身が合わないので使わずに止まる (cargo があっても戻らない。差し替えの印を隠さない)
fn refused(key: &str, why: String) -> Stop {
    Stop::new(format!("{why}。使わずに止めた (cargo に戻らない)")).note(format!(
        "Release {} が壊れているか、差し替えられている → Release の asset を確かめる (CI の公開の job は、同じ key の Release の zip と .sha256 が合うかを見る)。置いてある bin の exe はそのまま",
        tag(key)
    ))
}

/// Release から落とせず、cargo も無いときの止まるわけと直し方
fn unavailable(ctx: &Ctx, key: &str, fetch: &Fetch) -> Stop {
    if let Fetch::Failed(why) = fetch {
        return Stop::new(format!(
            "key {} の Release を落とせず ({why})、cargo も無いので置けない",
            short(key)
        ))
        .note("github.com に届くか (ネットワーク・プロキシ) を確かめて dotfiles apply を打ち直す")
        .note("手元で作るなら Install-Bootstrap.ps1 -Rust で Build Tools と rustup を入れる");
    }
    Stop::new(format!(
        "key {} の Release ({}) が無く (HTTP 404)、cargo も無いので置けない",
        short(key),
        tag(key)
    ))
    .note("merge の直後なら、CI (.github/workflows/pjp-tools-release.yml) が exe を作り終えるまで数分待って dotfiles apply を打ち直す")
    .note(format!(
        "clone が main より先 ({WORKSPACE_REL} を変えた commit が手元にある) なら、main に戻す (git -C '{}' switch main) か merge まで待つ。手元で作るなら Install-Bootstrap.ps1 -Rust で Build Tools と rustup を入れる",
        super::ps1::ps_quote(&ctx.repo.to_string_lossy())
    ))
    .note("clone が古ければ dotfiles --self-update apply で進める (古い key の Release は 30 日で消える)")
}

/// 置き場所 (workspace・写しの根・bin)。
struct Places {
    ws: PathBuf,
    root: PathBuf,
    bin: PathBuf,
}

/// bin の exe の様子 (行の文の頭・種類・添える行)。
struct State {
    text: String,
    kind: Kind,
    notes: Vec<String>,
}

pub struct PjpTools;

impl Step for PjpTools {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "pjp-tools",
            // 手順 pjp (55) と hc-hub (60) より先 (どちらも pjp を打つ)
            order: 54,
            title: "ハブと子の道具 (pjp・pjp-hub・pjp-child・pjp-mark・pjp-pack) の exe を、clone の nix/pkgs/pjp-tools に合う Release から落として (無く、cargo があれば作って) %LOCALAPPDATA%\\dotfiles\\bin に置き、ユーザーの PATH に足す",
            gate: Gate::AnyTool(&["herdrHub", "claudePrivateSkills"]),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        vec![sync(ctx, mode)]
    }
}

/// 止まったときの行
fn failed(ctx: &mut Ctx, label: &str, stop: Stop) -> Outcome {
    ctx.say(format!("!! {}", stop.why));
    let mut o = Outcome::new(Kind::Failed, format!("{label}: {}", stop.why));
    for n in stop.notes {
        o = o.note(n);
    }
    o
}

fn sync(ctx: &mut Ctx, mode: Mode) -> Outcome {
    let places = Places {
        ws: ctx.repo_path(WORKSPACE_REL),
        root: join_segments(&ctx.roots.local_app_data, CACHE_REL),
        bin: join_segments(&ctx.roots.local_app_data, BIN_DIR_REL),
    };
    ctx.say(format!("==> {}", places.bin.display()));
    if !places.ws.join("Cargo.toml").is_file() {
        return failed(
            ctx,
            "pjp-tools",
            Stop::new(format!(
                "workspace が無い ({}。dotfiles の clone を進める: dotfiles --self-update apply)",
                places.ws.display()
            )),
        );
    }
    let (key, dirty) = match read_clone(ctx) {
        Ok(v) => v,
        Err(stop) => return failed(ctx, "pjp-tools", stop),
    };
    let cargo = locate_cargo(ctx);
    let (label, state) = if dirty {
        (
            "pjp-tools (手元の変更)".to_string(),
            worktree(ctx, mode, cargo.as_deref(), &places),
        )
    } else {
        (
            format!("pjp-tools {}", short(&key)),
            keyed(ctx, mode, cargo.as_deref(), &key, &places),
        )
    };
    match state {
        Ok(state) => finish(ctx, mode, &label, state, &places.bin),
        Err(stop) => failed(ctx, &label, stop),
    }
}

/// clone の HEAD の workspace の key と、workspace に commit していない変更 (未追跡のファイルも) があるか
fn read_clone(ctx: &Ctx) -> Result<(String, bool), Stop> {
    let shown = ctx.repo.display().to_string();
    let Some(git) = ctx.sys.which("git") else {
        return Err(Stop::new(format!(
            "git が見つからない (clone ({shown}) の {WORKSPACE_REL} の key を読めない。git は bootstrap が入れる)"
        )));
    };
    let r = ctx.sys.run(
        &CommandSpec::new(&git)
            .arg("-C")
            .arg(ctx.repo.as_os_str())
            .arg("rev-parse")
            .arg(format!("HEAD:{WORKSPACE_REL}"))
            .timeout(Duration::from_secs(QUICK_SECS)),
        &mut |_| {},
    );
    // 出力は stdout と stderr (落ちたときに git の文 (dubious ownership など) を添える)。うまくいけば hash の 1 行だけ
    let got = r
        .output
        .iter()
        .map(|l| l.trim())
        .find(|l| !l.is_empty())
        .unwrap_or_default()
        .to_string();
    if r.code() != Some(0) || !is_object_name(&got) {
        return Err(Stop::new(format!(
            "clone ({shown}) の HEAD の {WORKSPACE_REL} を読めない (git -C '{shown}' rev-parse HEAD:{WORKSPACE_REL}。{:?}。{got})",
            r.exit
        )));
    }
    // --no-optional-locks は index を書かないため。--untracked-files=normal は、未追跡を見せない設定でも見るため
    let r = ctx.sys.run(
        &CommandSpec::new(&git)
            .arg("--no-optional-locks")
            .arg("-C")
            .arg(ctx.repo.as_os_str())
            .arg("status")
            .arg("--porcelain")
            .arg("--untracked-files=normal")
            .arg("--")
            .arg(WORKSPACE_REL)
            .timeout(Duration::from_secs(QUICK_SECS)),
        &mut |_| {},
    );
    if r.code() != Some(0) {
        return Err(Stop::new(format!(
            "{WORKSPACE_REL} に commit していない変更があるかを確かめられない (git status。{:?}: {})",
            r.exit,
            r.output.join(" / ")
        )));
    }
    Ok((got, r.output.iter().any(|l| !l.trim().is_empty())))
}

/// workspace の rust-toolchain.toml の channel (作るときの RUSTUP_TOOLCHAIN)
fn read_channel(ws: &Path) -> Result<String, Stop> {
    let toolchain = ws.join("rust-toolchain.toml");
    let channel = read_toml_string(&toolchain, "toolchain", "channel").unwrap_or_default();
    if channel_ok(&channel) {
        Ok(channel)
    } else {
        Err(Stop::new(format!(
            "{WORKSPACE_REL} の rust-toolchain.toml の [toolchain] の channel を読めない ({})",
            toolchain.display()
        )))
    }
}

/// 打つ cargo の行 (出す字)
fn cargo_line(ws: &Path, channel: &str, key: Option<&str>) -> String {
    let key = match key {
        Some(k) => format!("{KEY_ENV}={k}"),
        None => format!("{KEY_ENV} は外す"),
    };
    format!(
        "cargo build --release --locked --manifest-path {} --target-dir {} (cwd は workspace、RUSTUP_TOOLCHAIN={channel}・{key})",
        ws.join("Cargo.toml").display(),
        ws.join("target").display()
    )
}

/// workspace で cargo build を打ち、作った exe の dir (`target\release`) を返す。`key` は PJP_TOOLS_KEY に (None なら外す)。channel は
/// RUSTUP_TOOLCHAIN に付ける (Windows の rustup は既定の toolchain を持たず、`cargo run` で起こした runner には runner の版が付いているため)
fn build(
    ctx: &mut Ctx,
    cargo: &Path,
    ws: &Path,
    channel: &str,
    key: Option<&str>,
) -> Result<PathBuf, Stop> {
    let target = ws.join("target");
    ctx.say(format!("+ {}", cargo_line(ws, channel, key)));
    let spec = CommandSpec::new(cargo)
        .arg("build")
        .arg("--release")
        .arg("--locked")
        .arg("--manifest-path")
        .arg(ws.join("Cargo.toml").as_os_str())
        .arg("--target-dir")
        .arg(target.as_os_str())
        .current_dir(ws)
        .env("RUSTUP_TOOLCHAIN", channel)
        .timeout(Duration::from_secs(BUILD_SECS));
    let spec = match key {
        Some(k) => spec.env(KEY_ENV, k),
        None => spec.env_remove(KEY_ENV),
    };
    let r = run_streaming(ctx, &spec);
    if r.code() != Some(0) {
        return Err(Stop::new(format!(
            "cargo build が落ちた (上の cargo の出力。{:?})",
            r.exit
        ))
        .note(
            "直してから dotfiles apply --steps pjp-tools を流し直す (置いてある exe はそのまま)",
        ));
    }
    Ok(target.join("release"))
}

/// exe の `--version` が名乗る key (`key=` の行。無ければ空)。起こせない・0 でなく終わったならわけ
fn exe_key(ctx: &Ctx, exe: &Path) -> Result<String, String> {
    let r = ctx.sys.run(
        &CommandSpec::new(exe)
            .arg("--version")
            .stdout_only()
            .timeout(Duration::from_secs(QUICK_SECS)),
        &mut |_| {},
    );
    if r.code() != Some(0) {
        return Err(format!(
            "--version が {:?} で終わった: {}",
            r.exit,
            r.output.join(" / ")
        ));
    }
    Ok(r.output
        .iter()
        .find_map(|l| l.trim().strip_prefix("key=").map(|k| k.trim().to_string()))
        .unwrap_or_default())
}

/// 写しが無いときの check に添える、bin の pjp が名乗る key (bin に無ければ None)
fn bin_key_note(ctx: &Ctx, bin: &Path, key: &str) -> Option<String> {
    let exe = bin.join(exe_name("pjp"));
    if !exe.is_file() {
        return None;
    }
    Some(match exe_key(ctx, &exe) {
        Ok(k) if k == key => format!("bin の pjp の key は clone の key と同じ ({})", short(key)),
        Ok(k) if k.is_empty() => "bin の pjp は key を名乗らない (手元の build)".to_string(),
        Ok(k) => format!(
            "bin の pjp の key は {} (clone の key {} と違う)",
            short(&k),
            short(key)
        ),
        Err(e) => format!("bin の pjp の key を読めない ({e})"),
    })
}

/// bin の exe のうち、写し (`sums`) と sha256 が違うもの (TOOLS の順。true は bin にあって中身が違う、false は bin に無い)
fn bin_diff(bin: &Path, sums: &BTreeMap<String, String>) -> Vec<(String, bool)> {
    let mut diff = Vec::new();
    for name in exe_names() {
        match fsutil::sha256_file(&bin.join(&name)) {
            Ok(have) if sums.get(&name) == Some(&have) => {}
            Ok(_) => diff.push((name, true)),
            Err(_) => diff.push((name, false)),
        }
    }
    diff
}

/// 差の字 (`足す: a・b / 替える: c`)
fn diff_text(diff: &[(String, bool)]) -> String {
    let pick = |existed: bool| {
        diff.iter()
            .filter(|(_, e)| *e == existed)
            .map(|(n, _)| n.as_str())
            .collect::<Vec<_>>()
            .join("・")
    };
    let mut parts = Vec::new();
    let add = pick(false);
    if !add.is_empty() {
        parts.push(format!("足す: {add}"));
    }
    let replace = pick(true);
    if !replace.is_empty() {
        parts.push(format!("替える: {replace}"));
    }
    parts.join(" / ")
}

/// 写しと bin の差の様子 (check・dry-run。無い物だけなら missing、違う物があれば fix)
fn diff_state(diff: &[(String, bool)], source: Source) -> State {
    if diff.is_empty() {
        return same(source);
    }
    let kind = if diff.iter().any(|(_, existed)| *existed) {
        Kind::Fix
    } else {
        Kind::Missing
    };
    State {
        text: format!("bin に写す ({})", diff_text(diff)),
        kind,
        notes: Vec::new(),
    }
}

/// bin が写しと同じ
fn same(source: Source) -> State {
    State {
        text: format!("写しと同じ (出どころ {})", source.as_str()),
        kind: Kind::Ok,
        notes: Vec::new(),
    }
}

/// `src` の exe のうち `diff` のものを bin へ写す (動いている exe も、退けてから置く)
fn place(ctx: &mut Ctx, src: &Path, diff: &[(String, bool)], bin: &Path) -> Result<(), Stop> {
    for (name, _) in diff {
        let from = src.join(name);
        let dest = bin.join(name);
        let bytes = std::fs::read(&from)
            .map_err(|e| Stop::new(format!("{} が読めない ({e})", from.display())))?;
        replace_file(&bytes, &dest).map_err(|e| {
            Stop::new(format!("{} を書けない ({e})", dest.display())).note(
                "pjp の道具を使っている端末・会話 (ハブの hook の pjp hub guard など) があれば閉じてから dotfiles apply --steps pjp-tools を流し直す",
            )
        })?;
        ctx.say(format!("置きました: {}", dest.display()));
    }
    Ok(())
}

/// dry-run で写すファイルを出す
fn say_copies(ctx: &mut Ctx, names: &[String], bin: &Path) {
    if !names.is_empty() {
        ctx.say(format!(
            "[dry-run] 写す: {} → {}",
            names.join("・"),
            bin.display()
        ));
    }
}

/// 古い key の写しを消す (dry-run は出すだけ、check は何もしない。動いていて消せないものは次に回す)
fn prune(ctx: &mut Ctx, mode: Mode, stale: &[PathBuf]) {
    for dir in stale {
        match mode {
            Mode::Check => {}
            Mode::DryRun { .. } => {
                ctx.say(format!(
                    "[dry-run] 消す (古い key の写し): {}",
                    dir.display()
                ));
            }
            Mode::Apply { .. } => match std::fs::remove_dir_all(dir) {
                Ok(()) => ctx.say(format!("消しました (古い key の写し): {}", dir.display())),
                Err(e) => ctx.say(format!(
                    "!! 古い key の写しを消せない (次の apply で消す): {} ({e})",
                    dir.display()
                )),
            },
        }
    }
}

/// 手元の変更が無いとき: key の写しを使う (無ければ作る) 決め方の表
fn keyed(
    ctx: &mut Ctx,
    mode: Mode,
    cargo: Option<&Path>,
    key: &str,
    places: &Places,
) -> Result<State, Stop> {
    let dir = places.root.join(key);
    let bin = &places.bin;
    ctx.say(format!("key {key} (clone の HEAD の {WORKSPACE_REL})"));
    let cache = read_cache(&dir, key);
    let stale = stale_dirs(&places.root, key);
    if let Cache::Valid(mark) = &cache {
        ctx.say(format!(
            "写し: {} (印あり。出どころ {})",
            dir.display(),
            mark.source.as_str()
        ));
        let diff = bin_diff(bin, &mark.sums);
        return match mode {
            Mode::Check => {
                if !diff.is_empty() {
                    ctx.say(format!("bin に写す (apply で): {}", diff_text(&diff)));
                }
                Ok(diff_state(&diff, mark.source))
            }
            Mode::DryRun { .. } => {
                let names: Vec<String> = diff.iter().map(|(n, _)| n.clone()).collect();
                say_copies(ctx, &names, bin);
                prune(ctx, mode, &stale);
                Ok(diff_state(&diff, mark.source))
            }
            Mode::Apply { .. } => {
                place(ctx, &dir, &diff, bin)?;
                prune(ctx, mode, &stale);
                if diff.is_empty() {
                    Ok(same(mark.source))
                } else {
                    Ok(State {
                        text: format!("写しから置いた ({})", diff_text(&diff)),
                        kind: Kind::Ok,
                        notes: Vec::new(),
                    })
                }
            }
        };
    }
    let (kind, what) = match &cache {
        Cache::Stale(why) => (Kind::Fix, format!("写しが印と合わない ({why})")),
        _ => (Kind::Missing, "写しが無い".to_string()),
    };
    let mut notes = Vec::new();
    match mode {
        Mode::Check => {
            ctx.say(format!(
                "{what} → Release から落として置く (apply で): {}",
                dir.display()
            ));
            notes.extend(bin_key_note(ctx, bin, key));
            if cargo.is_none() {
                notes.push(NO_CARGO.to_string());
            }
            Ok(State {
                text: format!("{what} → Release から落として置く"),
                kind,
                notes,
            })
        }
        Mode::DryRun { .. } => {
            for name in [SHA_NAME, ZIP_NAME] {
                ctx.say(format!("[dry-run] 落とす: {}", asset_url(key, name)));
            }
            ctx.say(format!(
                "[dry-run] sha256 を確かめて解く: {}",
                dir.display()
            ));
            if cargo.is_some() {
                let channel = read_channel(&places.ws).unwrap_or_else(|_| "?".to_string());
                ctx.say(format!(
                    "[dry-run] Release が無ければ: {}",
                    cargo_line(&places.ws, &channel, Some(key))
                ));
            } else {
                ctx.say("[dry-run] Release が無ければ止まる (cargo が無い)");
            }
            say_copies(ctx, &exe_names(), bin);
            prune(ctx, mode, &stale);
            Ok(State {
                text: format!("{what} → Release から落として置く"),
                kind,
                notes,
            })
        }
        Mode::Apply { .. } => {
            if let Cache::Stale(why) = &cache {
                ctx.say(format!("!! 写しが印と合わない ({why}) → 落とし直す"));
            }
            let (mark, fallback) = match acquire(ctx, key, &dir, &places.ws, cargo) {
                Ok(v) => v,
                Err(stop) => {
                    // 確かめていない中身を残さない (印は付けていないので使われないが、片付ける)
                    let _ = std::fs::remove_dir_all(&dir);
                    return Err(stop);
                }
            };
            let diff = bin_diff(bin, &mark.sums);
            place(ctx, &dir, &diff, bin)?;
            prune(ctx, mode, &stale);
            let how = match mark.source {
                Source::Release => "Release から落として",
                Source::Cargo => "cargo で作って",
            };
            let text = if diff.is_empty() {
                format!("{how}写しを作った (bin と同じ)")
            } else {
                format!("{how}置いた ({})", diff_text(&diff))
            };
            notes.extend(fallback);
            Ok(State {
                text,
                kind: Kind::Ok,
                notes,
            })
        }
    }
}

/// 落とした zip と .sha256 を、成否によらず消す
struct Downloads(PathBuf);

impl Drop for Downloads {
    fn drop(&mut self) {
        for name in [ZIP_NAME, SHA_NAME] {
            let _ = std::fs::remove_file(self.0.join(name));
        }
    }
}

/// 写しを作る: key の Release から落として確かめる。落とせない (無い・届かない) ときは cargo があれば作る。できた印と、cargo で作ったなら
/// Release を使えなかったわけ
fn acquire(
    ctx: &mut Ctx,
    key: &str,
    dir: &Path,
    ws: &Path,
    cargo: Option<&Path>,
) -> Result<(Mark, Option<String>), Stop> {
    // 前の印は先に外す (途中で止まっても、確かめていない中身を写しに見せない)
    let _ = std::fs::remove_file(dir.join(MARK_NAME));
    std::fs::create_dir_all(dir)
        .map_err(|e| Stop::new(format!("写しの置き場を作れない: {} ({e})", dir.display())))?;
    let fetch = match find_powershell(ctx) {
        None => Fetch::Failed("PowerShell が見つからない (pwsh・powershell)".to_string()),
        Some(shell) => {
            let _cleanup = Downloads(dir.to_path_buf());
            for name in [SHA_NAME, ZIP_NAME] {
                ctx.say(format!("+ 落とす: {}", asset_url(key, name)));
            }
            let spec = powershell(&shell, DOWNLOAD_SCRIPT, DOWNLOAD_SECS)
                .env(SHA_URL_ENV, asset_url(key, SHA_NAME))
                .env(SHA_OUT_ENV, dir.join(SHA_NAME))
                .env(ZIP_URL_ENV, asset_url(key, ZIP_NAME))
                .env(ZIP_OUT_ENV, dir.join(ZIP_NAME));
            match classify(&ctx.sys.run(&spec, &mut |_| {})) {
                Fetch::Done => return from_release(ctx, &shell, key, dir).map(|m| (m, None)),
                other => other,
            }
        }
    };
    let reason = match &fetch {
        Fetch::Failed(why) => format!("Release を落とせない ({why})"),
        _ => format!("Release ({}) が無い (HTTP 404)", tag(key)),
    };
    let Some(cargo) = cargo else {
        return Err(unavailable(ctx, key, &fetch));
    };
    ctx.say(format!(
        "· key {} の {reason} ので、cargo で作る",
        short(key)
    ));
    let channel = read_channel(ws)?;
    let out = build(ctx, cargo, ws, &channel, Some(key))?;
    for name in exe_names() {
        std::fs::copy(out.join(&name), dir.join(&name)).map_err(|e| {
            Stop::new(format!(
                "作った {} を写しに入れられない ({e})",
                out.join(&name).display()
            ))
        })?;
    }
    let mark = verify(ctx, key, dir, Source::Cargo)?;
    Ok((
        mark,
        Some(format!(
            "key {} の {reason} ので、cargo で作った",
            short(key)
        )),
    ))
}

/// 落とした zip の sha256 を .sha256 と比べ、合えば写しの dir に解いて確かめる
fn from_release(ctx: &mut Ctx, shell: &Path, key: &str, dir: &Path) -> Result<Mark, Stop> {
    let expected = std::fs::read_to_string(dir.join(SHA_NAME))
        .ok()
        .and_then(|t| parse_sha256(&t))
        .ok_or_else(|| {
            refused(
                key,
                format!("Release の {SHA_NAME} が読めない (sha256sum の形でない)"),
            )
        })?;
    let zip = dir.join(ZIP_NAME);
    let actual = fsutil::sha256_file(&zip)
        .map_err(|e| refused(key, format!("落とした {ZIP_NAME} が読めない ({e})")))?;
    if actual != expected {
        return Err(refused(
            key,
            format!(
                "落とした zip の sha256 ({actual}) が Release の {SHA_NAME} の値 ({expected}) と合わない"
            ),
        ));
    }
    ctx.say(format!("sha256 が合う。解く: {}", dir.display()));
    let r = ctx.sys.run(
        &powershell(shell, EXPAND_SCRIPT, EXPAND_SECS)
            .env(ZIP_ENV, &zip)
            .env(DEST_ENV, dir),
        &mut |_| {},
    );
    if r.code() != Some(0) {
        let why = r
            .output
            .iter()
            .find_map(|l| l.trim().strip_prefix("error=").map(str::to_string))
            .filter(|e| !e.is_empty())
            .unwrap_or_else(|| format!("{:?}: {}", r.exit, r.output.join(" / ")));
        return Err(refused(key, format!("Release の zip を解けない ({why})")));
    }
    verify(ctx, key, dir, Source::Release)
}

/// 写しの dir の 5 つの exe が揃い、pjp が clone の key を名乗るのを確かめて、印を書く
fn verify(ctx: &mut Ctx, key: &str, dir: &Path, source: Source) -> Result<Mark, Stop> {
    let what = match source {
        Source::Release => "Release の zip",
        Source::Cargo => "作った exe",
    };
    let fail = |why: String| match source {
        Source::Release => refused(key, why),
        Source::Cargo => Stop::new(why).note(format!(
            "{WORKSPACE_REL} の target を消して dotfiles apply --steps pjp-tools を流し直す"
        )),
    };
    let mut sums = BTreeMap::new();
    for name in exe_names() {
        let sum = fsutil::sha256_file(&dir.join(&name))
            .map_err(|_| fail(format!("{what} に {name} が無い")))?;
        sums.insert(name, sum);
    }
    let pjp = dir.join(exe_name("pjp"));
    let got = exe_key(ctx, &pjp).map_err(|e| {
        Stop::new(format!("{} を起こせない ({e})", pjp.display())).note(LAUNCH_HINT)
    })?;
    if got != key {
        let shown = if got.is_empty() {
            "無い".to_string()
        } else {
            short(&got)
        };
        return Err(fail(format!(
            "{what} の pjp が名乗る key ({shown}) が clone の key ({}) と合わない",
            short(key)
        )));
    }
    let mark = Mark {
        key: key.to_string(),
        source,
        sums,
    };
    let path = dir.join(MARK_NAME);
    fsutil::write_atomic(&path, mark.render().as_bytes())
        .map_err(|e| Stop::new(format!("印を書けない: {} ({e})", path.display())))?;
    ctx.say(format!(
        "確かめて印を付けた: {} (key {}・出どころ {})",
        dir.display(),
        short(key),
        source.as_str()
    ));
    Ok(mark)
}

/// 手元の変更があるとき: 写しを使わず・作らず、cargo で作って bin に直に置く
fn worktree(
    ctx: &mut Ctx,
    mode: Mode,
    cargo: Option<&Path>,
    places: &Places,
) -> Result<State, Stop> {
    ctx.say(format!(
        "· {WORKSPACE_REL} に commit していない変更がある → key の写しを使わず、cargo で作って bin に直に置く (写しにも印にもしない)"
    ));
    let Some(cargo) = cargo else {
        return Err(Stop::new(format!(
            "{WORKSPACE_REL} に commit していない変更があるが、cargo が無いので置けない (手元の変更は Release に無い)"
        ))
        .note("commit して merge した後に流し直すか、変更を退ける。手元で作るなら Install-Bootstrap.ps1 -Rust で Build Tools と rustup を入れる"));
    };
    let ws = &places.ws;
    let channel = read_channel(ws)?;
    let todo = State {
        text: format!(
            "{WORKSPACE_REL} に commit していない変更がある → apply で cargo で作って bin に直に置く (key の写しは使わない)"
        ),
        kind: Kind::Info,
        notes: Vec::new(),
    };
    match mode {
        Mode::Check => Ok(todo),
        Mode::DryRun { .. } => {
            ctx.say(format!("[dry-run] {}", cargo_line(ws, &channel, None)));
            ctx.say(format!(
                "[dry-run] 写す: {} の {} → {}",
                ws.join("target").join("release").display(),
                exe_names().join("・"),
                places.bin.display()
            ));
            Ok(todo)
        }
        Mode::Apply { .. } => {
            let out = build(ctx, cargo, ws, &channel, None)?;
            let mut sums = BTreeMap::new();
            for name in exe_names() {
                let path = out.join(&name);
                let sum = fsutil::sha256_file(&path).map_err(|e| {
                    Stop::new(format!("作った {} が読めない ({e})", path.display()))
                })?;
                sums.insert(name, sum);
            }
            let diff = bin_diff(&places.bin, &sums);
            place(ctx, &out, &diff, &places.bin)?;
            let text = if diff.is_empty() {
                "手元の変更から cargo で作った (bin と同じ)".to_string()
            } else {
                format!("手元の変更から cargo で作って置いた ({})", diff_text(&diff))
            };
            Ok(State {
                text,
                kind: Kind::Ok,
                notes: Vec::new(),
            })
        }
    }
}

/// PATH を揃えて締めの行にする (claude-selector と同じ形)
fn finish(ctx: &mut Ctx, mode: Mode, label: &str, state: State, bin: &Path) -> Outcome {
    let State {
        text: exe_text,
        kind: exe_kind,
        mut notes,
    } = state;
    let path = sync_user_path(ctx, mode, bin);
    let path_text = match &path {
        Ok(PathState::Listed) => "入っている",
        Ok(PathState::ToAdd) => {
            notes.push(format!(
                "置き場 {} をユーザーの PATH の末尾に足す (値の型と、ほかの要素の %VAR% の書き方は変えない)",
                bin.display()
            ));
            "足す"
        }
        Ok(PathState::Added) => {
            notes.push(NEW_TERMINAL.to_string());
            "足した"
        }
        Err(e) => {
            ctx.say(format!("!! {e}"));
            notes.push(e.clone());
            "確かめられない"
        }
    };
    let to_add = matches!(path, Ok(PathState::ToAdd));
    let needs_apply = matches!(exe_kind, Kind::Missing | Kind::Fix);
    let mut text = format!("{label}: {exe_text} / PATH: {path_text}");
    if !mode.writes() && (needs_apply || to_add) {
        text.push_str(" → dotfiles apply で揃える");
    }
    if matches!(mode, Mode::DryRun { .. }) {
        text = format!("[dry-run] {text}");
    }
    let kind = if path.is_err() {
        Kind::Failed
    } else if needs_apply {
        exe_kind
    } else if to_add {
        Kind::Missing
    } else {
        exe_kind
    };
    let mut o = Outcome::new(kind, text);
    for n in notes {
        o = o.note(n);
    }
    o
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 決め方の表の 1 行目: 印の効く写しがあれば、落とさず・cargo も exe も打たずに、bin と sha256 が違う exe だけを写す (check と dry-run は
    //!   差を出すだけで書かない)。bin が写しと同じなら何もしない
    //! - 2 行目: 写しが無ければ、apply は .sha256 と zip を落とし (URL の tag は key の頭 12 字)、sha256 を確かめて写しの dir に解き、写しの
    //!   pjp の --version の key を確かめて印 (release) を付け、bin に写して PATH に足す。落とした zip と .sha256 は消す。check は何も落とさず
    //!   missing、dry-run は落とす URL・解く先・Release が無いときの cargo・写すファイルを出すだけ
    //! - 3 行目: sha256 が合わない・.sha256 が読めない・key が合わない・zip に exe が足りない → failed。cargo があっても打たず、写し・印・PATH に
    //!   触らず、置いてある bin の exe もそのまま (落とした物と解いた物は消す)。sha256 の合わない zip は解かない
    //! - 4 行目: Release が無い (404)・届かない → cargo があれば workspace で cargo build --release --locked (RUSTUP_TOOLCHAIN は workspace の版、
    //!   PJP_TOOLS_KEY は key) を打ち、写しに入れて印 (cargo) を付けて写す。Release を使えなかったわけを添える
    //! - 5 行目: Release が無い・cargo も無い → failed で、わけに直し方 (数分待って打ち直す・main に戻す・--self-update)。届かないなら github.com。
    //!   check と dry-run は落とさないので、cargo が無いことだけを添える
    //! - 写しの exe が印と合わない (替わった) → fix。apply で落とし直す。印の無い写しは無いのと同じ (missing)
    //! - 写しが無いときの check は、bin の pjp の --version の key を添える (同じ・違う)
    //! - 手元の変更 (git status が空でない): 写しを使わず・作らず・消さず、cargo で作って bin に直に置く (PJP_TOOLS_KEY は外す)。check は info で
    //!   cargo を打たない。cargo が無ければ、どの流し方でも failed (手元の変更は Release に無い)
    //! - 古い key の写し: 今の key と、ほかを新しい方 (印の時刻。印が無ければ dir の時刻) から 2 つ残して消す。key の形でない名前には触らない。
    //!   dry-run は消すものを出すだけ、check は消さない
    //! - workspace が無い・git が無い・key を読めない・git status が落ちる・channel を読めない → failed
    //! - 印の形 (書いて読み戻す・CRLF・欠けた行・知らない出どころ)・.sha256 の読み方・落とす PowerShell の結果の読み方・script が ASCII だけ
    //! - 本物の PowerShell (5.1 と 7) で、手元の HTTP server から落とし (404 も見分け)、Expand-Archive で解く (Windows だけ)

    use super::*;
    use crate::context::join_segments;
    use crate::fsutil;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::Exit;
    use crate::steps::claude_accounts::BIN_DIR_REL;
    use crate::testutil::{FakeSys, TempDir};
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::time::{Duration, SystemTime};

    /// clone の key (40 字の 16 進)
    const KEY: &str = "0123456789abcdef0123456789abcdef01234567";
    /// 別の key
    const OTHER: &str = "fedcba9876543210fedcba9876543210fedcba98";
    const APPLY: Mode = Mode::Apply { force: false };
    const DRY_RUN: Mode = Mode::DryRun { force: false };

    /// 偽の Release
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Release {
        /// 合う zip と .sha256
        Good,
        /// .sha256 が zip と合わない
        BadSha,
        /// .sha256 が sha256sum の形でない
        BadShaFile,
        /// zip の中の pjp が別の key を名乗る
        WrongKey,
        /// zip に pjp-pack が無い
        Incomplete,
        /// Release が無い (HTTP 404)
        Missing,
        /// github.com に届かない
        Unreachable,
    }

    struct World {
        t: TempDir,
        /// registry のユーザーの PATH の生の値 (偽物が読み書きする)
        reg: Rc<RefCell<String>>,
    }

    impl World {
        fn new() -> Self {
            let t = TempDir::new("pjp-tools");
            t.write(
                "g/dotfiles/nix/pkgs/pjp-tools/Cargo.toml",
                "[workspace]\nmembers = [\"crates/*\"]\n",
            );
            t.write(
                "g/dotfiles/nix/pkgs/pjp-tools/rust-toolchain.toml",
                "[toolchain]\nchannel = \"1.99.1\"\n",
            );
            t.write(
                &format!("home/.cargo/bin/cargo{}", std::env::consts::EXE_SUFFIX),
                "cargo",
            );
            World {
                t,
                reg: Rc::new(RefCell::new("C:\\Windows".to_string())),
            }
        }

        fn home(&self) -> PathBuf {
            self.t.path().join("home")
        }

        fn ws(&self) -> PathBuf {
            join_segments(self.t.path(), "g/dotfiles/nix/pkgs/pjp-tools")
        }

        fn bin(&self) -> PathBuf {
            join_segments(&join_segments(&self.home(), "AppData/Local"), BIN_DIR_REL)
        }

        fn root(&self) -> PathBuf {
            join_segments(&self.home(), "AppData/Local/dotfiles/pjp-tools")
        }

        fn cache(&self) -> PathBuf {
            self.root().join(KEY)
        }

        fn remove_cargo(&self) {
            std::fs::remove_file(
                self.home()
                    .join(".cargo")
                    .join("bin")
                    .join(format!("cargo{}", std::env::consts::EXE_SUFFIX)),
            )
            .unwrap();
        }

        fn sys(&self, release: Release) -> FakeSys {
            self.sys_with(release, false)
        }

        /// 偽の git (key と、`dirty` なら workspace の変更の行)・PowerShell (落とす・解く・ユーザーの PATH)・cargo・exe の --version
        fn sys_with(&self, release: Release, dirty: bool) -> FakeSys {
            let reg = self.reg.clone();
            FakeSys::new(move |c| {
                let args = c.args_lossy();
                let done = |output: Vec<String>| RunResult {
                    exit: Exit::Code(0),
                    output,
                };
                if c.program == Path::new("git") {
                    if args.iter().any(|a| a == "rev-parse") {
                        assert_eq!(args.last().unwrap(), &format!("HEAD:{WORKSPACE_REL}"));
                        return done(vec![KEY.to_string()]);
                    }
                    if args.iter().any(|a| a == "status") {
                        assert_eq!(args.last().unwrap(), WORKSPACE_REL);
                        return done(if dirty {
                            vec![format!(" M {WORKSPACE_REL}/crates/pjp/src/main.rs")]
                        } else {
                            Vec::new()
                        });
                    }
                }
                if args.first().is_some_and(|a| a == "build") {
                    let i = args.iter().position(|a| a == "--target-dir").unwrap();
                    let out = PathBuf::from(&args[i + 1]).join("release");
                    std::fs::create_dir_all(&out).unwrap();
                    let k = c.env_value(KEY_ENV).unwrap_or_default();
                    for tool in TOOLS {
                        std::fs::write(out.join(exe_name(tool)), format!("{tool} key={k} cargo"))
                            .unwrap();
                    }
                    return done(vec!["   Compiling pjp v0.1.0".to_string()]);
                }
                if let Some(zip_out) = c.env_value(ZIP_OUT_ENV) {
                    let zip = match release {
                        Release::Missing => {
                            return RunResult {
                                exit: Exit::Code(1),
                                output: vec![
                                    "status=404".to_string(),
                                    "error=Response status code does not indicate success: 404 (Not Found).".to_string(),
                                ],
                            };
                        }
                        Release::Unreachable => {
                            return RunResult {
                                exit: Exit::Code(1),
                                output: vec![
                                    "status=0".to_string(),
                                    "error=No such host is known. (github.com:443)".to_string(),
                                ],
                            };
                        }
                        Release::WrongKey => format!("zip key={OTHER}"),
                        Release::Incomplete => format!("zip key={KEY} lacks=pjp-pack"),
                        _ => format!("zip key={KEY}"),
                    };
                    let sha = match release {
                        Release::BadSha => format!("{}  {ZIP_NAME}\n", fsutil::sha256_bytes(b"other")),
                        Release::BadShaFile => "<html>not a hash</html>\n".to_string(),
                        _ => format!("{}  {ZIP_NAME}\n", fsutil::sha256_bytes(zip.as_bytes())),
                    };
                    std::fs::write(c.env_value(SHA_OUT_ENV).unwrap(), sha).unwrap();
                    std::fs::write(zip_out, zip).unwrap();
                    return done(Vec::new());
                }
                if let Some(dest) = c.env_value(DEST_ENV) {
                    let zip = std::fs::read_to_string(c.env_value(ZIP_ENV).unwrap()).unwrap();
                    let k = zip.split("key=").nth(1).unwrap().split_whitespace().next().unwrap();
                    let lacks = zip.split_whitespace().find_map(|w| w.strip_prefix("lacks="));
                    for tool in TOOLS {
                        if lacks != Some(tool) {
                            std::fs::write(Path::new(&dest).join(exe_name(tool)), format!("{tool} key={k}"))
                                .unwrap();
                        }
                    }
                    return done(Vec::new());
                }
                if args == ["--version"] {
                    // 版は stdout だけから読む
                    assert!(c.stdout_only, "--version は stdout だけを読む");
                    let text = std::fs::read_to_string(&c.program).unwrap();
                    let k = text
                        .split("key=")
                        .nth(1)
                        .unwrap_or("")
                        .split_whitespace()
                        .next()
                        .unwrap_or("");
                    return done(vec![
                        "pjp 0.1.0".to_string(),
                        format!("key={k}"),
                        "pjp-skills=無い".to_string(),
                    ]);
                }
                if let Some(new) = c.env_value("DOTFILES_USER_PATH_NEW") {
                    *reg.borrow_mut() = new;
                    return done(Vec::new());
                }
                if args
                    .last()
                    .is_some_and(|a| a.contains("DoNotExpandEnvironmentNames"))
                {
                    return done(vec![
                        "kind=ExpandString".to_string(),
                        format!("raw={}", reg.borrow()),
                    ]);
                }
                panic!("知らないコマンド: {:?} {args:?}", c.program);
            })
            .with_program("pwsh", "pwsh")
            .with_program("git", "git")
        }

        fn run(&self, mode: Mode, sys: &FakeSys) -> (Outcome, String) {
            let mut out = Vec::new();
            let o = {
                let mut ctx = Ctx {
                    repo: self.t.path().join("g").join("dotfiles"),
                    roots: Roots::from_home(&self.home()),
                    state_dir: self.t.path().join("state"),
                    host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                    sys,
                    out: &mut out,
                };
                PjpTools.run(&mut ctx, mode)
            };
            assert_eq!(o.len(), 1, "{o:?}");
            (
                o.into_iter().next().unwrap(),
                String::from_utf8(out).unwrap(),
            )
        }

        fn read(&self, dir: &Path, tool: &str) -> String {
            std::fs::read_to_string(dir.join(exe_name(tool))).unwrap()
        }

        fn mark(&self) -> Mark {
            Mark::parse(&std::fs::read_to_string(self.cache().join(MARK_NAME)).unwrap()).unwrap()
        }
    }

    fn calls(sys: &FakeSys, f: impl Fn(&CommandSpec) -> bool) -> Vec<CommandSpec> {
        sys.calls
            .borrow()
            .iter()
            .filter(|c| f(c))
            .cloned()
            .collect()
    }

    fn downloads(sys: &FakeSys) -> Vec<CommandSpec> {
        calls(sys, |c| c.env_value(ZIP_URL_ENV).is_some())
    }

    fn expands(sys: &FakeSys) -> Vec<CommandSpec> {
        calls(sys, |c| c.env_value(DEST_ENV).is_some())
    }

    fn builds(sys: &FakeSys) -> Vec<CommandSpec> {
        calls(sys, |c| {
            c.args_lossy().first().is_some_and(|a| a == "build")
        })
    }

    fn versions(sys: &FakeSys) -> Vec<CommandSpec> {
        calls(sys, |c| c.args_lossy() == ["--version"])
    }

    /// ファイルの更新の時刻を 1970 年からの `secs` 秒にする
    fn set_mtime(path: &Path, secs: u64) {
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(secs))
            .unwrap();
    }

    #[test]
    fn info() {
        let i = PjpTools.info();
        assert_eq!((i.id, i.order), ("pjp-tools", 54));
        assert_eq!(i.gate, Gate::AnyTool(&["herdrHub", "claudePrivateSkills"]));
        assert!(i.ported && i.windows_only);
    }

    #[test]
    fn tags_and_urls() {
        assert_eq!(tag(KEY), "pjp-tools-0123456789ab");
        assert_eq!(
            asset_url(KEY, ZIP_NAME),
            "https://github.com/pollenjp/dotfiles/releases/download/pjp-tools-0123456789ab/pjp-tools-windows-x86_64.zip"
        );
    }

    /// 表の 2 行目 (写しが無い・Release がある) と、続けて流したときの 1 行目 (写しも bin も合う)
    #[test]
    fn downloads_verifies_and_places_from_the_release() {
        let w = World::new();
        let sys = w.sys(Release::Good);
        let (o, out) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Missing, "{o:?}\n{out}");
        assert!(
            o.text.contains(&format!("pjp-tools {}", &KEY[..12])),
            "{o:?}"
        );
        assert!(o.text.contains("写しが無い"), "{o:?}");
        assert!(o.text.contains("PATH: 足す"), "{o:?}");
        let (o, out) = w.run(DRY_RUN, &sys);
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(o.text.starts_with("[dry-run] "), "{o:?}");
        for name in [SHA_NAME, ZIP_NAME] {
            assert!(
                out.contains(&format!(
                    "[dry-run] 落とす: https://github.com/pollenjp/dotfiles/releases/download/pjp-tools-{}/{name}",
                    &KEY[..12]
                )),
                "{out}"
            );
        }
        assert!(
            out.contains(&format!(
                "[dry-run] sha256 を確かめて解く: {}",
                w.cache().display()
            )),
            "{out}"
        );
        assert!(
            out.contains("[dry-run] Release が無ければ: cargo build --release --locked"),
            "{out}"
        );
        assert!(out.contains(&format!("{KEY_ENV}={KEY}")), "{out}");
        assert!(
            out.contains(&format!("[dry-run] 写す: {} ", exe_names().join("・"))),
            "{out}"
        );
        assert!(downloads(&sys).is_empty() && expands(&sys).is_empty());
        assert!(builds(&sys).is_empty() && versions(&sys).is_empty());
        assert!(!w.root().exists() && !w.bin().exists());
        assert_eq!(*w.reg.borrow(), "C:\\Windows");

        let (o, out) = w.run(APPLY, &sys);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        assert!(o.text.contains("Release から落として置いた"), "{o:?}");
        assert!(o.text.contains("PATH: 足した"), "{o:?}");
        let d = downloads(&sys);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].program, Path::new("pwsh"));
        assert_eq!(
            d[0].env_value(SHA_URL_ENV).unwrap(),
            asset_url(KEY, SHA_NAME)
        );
        assert_eq!(
            d[0].env_value(ZIP_URL_ENV).unwrap(),
            asset_url(KEY, ZIP_NAME)
        );
        assert_eq!(
            d[0].env_value(ZIP_OUT_ENV).unwrap(),
            w.cache().join(ZIP_NAME).to_string_lossy()
        );
        assert_eq!(d[0].args_lossy().last().unwrap(), DOWNLOAD_SCRIPT);
        let e = expands(&sys);
        assert_eq!(e.len(), 1);
        assert_eq!(
            e[0].env_value(DEST_ENV).unwrap(),
            w.cache().to_string_lossy()
        );
        assert_eq!(
            e[0].env_value(ZIP_ENV).unwrap(),
            w.cache().join(ZIP_NAME).to_string_lossy()
        );
        let v = versions(&sys);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].program, w.cache().join(exe_name("pjp")));
        assert!(builds(&sys).is_empty());
        for tool in TOOLS {
            let want = format!("{tool} key={KEY}");
            assert_eq!(w.read(&w.cache(), tool), want);
            assert_eq!(w.read(&w.bin(), tool), want);
        }
        assert!(!w.cache().join(ZIP_NAME).exists() && !w.cache().join(SHA_NAME).exists());
        let mark = w.mark();
        assert_eq!((mark.key.as_str(), mark.source), (KEY, Source::Release));
        assert_eq!(
            mark.sums.get(&exe_name("pjp-hub")).unwrap(),
            &fsutil::sha256_bytes(format!("pjp-hub key={KEY}").as_bytes())
        );
        assert_eq!(
            *w.reg.borrow(),
            format!("C:\\Windows;{}", w.bin().display())
        );
        assert!(
            o.notes.iter().any(|n| n.contains("新しい端末から効く")),
            "{o:?}"
        );

        // 2 回目 (表の 1 行目): 写しも bin も合うので、落とさず・起こさず・写さない
        let sys = w.sys(Release::Good);
        for mode in [Mode::Check, APPLY] {
            let (o, _) = w.run(mode, &sys);
            assert_eq!(o.kind, Kind::Ok, "{mode:?} {o:?}");
            assert!(o.text.contains("写しと同じ"), "{o:?}");
            assert!(o.text.ends_with("/ PATH: 入っている"), "{o:?}");
        }
        assert!(downloads(&sys).is_empty() && builds(&sys).is_empty());
        assert!(versions(&sys).is_empty());
    }

    /// 表の 1 行目: 写しと sha256 が違う exe だけを写す
    #[test]
    fn copies_only_what_differs_from_the_cache() {
        let w = World::new();
        w.run(APPLY, &w.sys(Release::Good));
        std::fs::write(w.bin().join(exe_name("pjp-hub")), "old").unwrap();
        std::fs::remove_file(w.bin().join(exe_name("pjp-mark"))).unwrap();
        let sys = w.sys(Release::Good);
        let (o, _) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        assert!(
            o.text.contains(&format!("足す: {}", exe_name("pjp-mark"))),
            "{o:?}"
        );
        assert!(
            o.text.contains(&format!("替える: {}", exe_name("pjp-hub"))),
            "{o:?}"
        );
        assert!(o.text.contains("dotfiles apply で揃える"), "{o:?}");
        let (o, out) = w.run(DRY_RUN, &sys);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        assert!(
            out.contains(&format!(
                "[dry-run] 写す: {}・{} ",
                exe_name("pjp-hub"),
                exe_name("pjp-mark")
            )),
            "{out}"
        );
        assert_eq!(w.read(&w.bin(), "pjp-hub"), "old");
        let (o, out) = w.run(APPLY, &sys);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        assert!(o.text.contains("写しから置いた"), "{o:?}");
        for tool in TOOLS {
            assert_eq!(w.read(&w.bin(), tool), w.read(&w.cache(), tool), "{tool}");
        }
        assert!(downloads(&sys).is_empty() && builds(&sys).is_empty());
        assert!(versions(&sys).is_empty());

        // bin に 1 つも無ければ missing
        std::fs::remove_dir_all(w.bin()).unwrap();
        let (o, _) = w.run(Mode::Check, &w.sys(Release::Good));
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
    }

    /// 表の 3 行目: 合わない Release は使わずに止まり、cargo に戻らない
    #[test]
    fn refuses_a_release_that_does_not_match() {
        for (release, why) in [
            (Release::BadSha, "sha256"),
            (Release::BadShaFile, "読めない"),
            (Release::WrongKey, "名乗る key"),
            (Release::Incomplete, "pjp-pack"),
        ] {
            let w = World::new();
            w.t.write(
                &format!("home/AppData/Local/dotfiles/bin/{}", exe_name("pjp")),
                "old",
            );
            let sys = w.sys(release);
            let (o, out) = w.run(APPLY, &sys);
            assert_eq!(o.kind, Kind::Failed, "{release:?} {o:?}\n{out}");
            assert!(o.text.contains(why), "{release:?} {o:?}");
            assert!(o.text.contains("cargo に戻らない"), "{release:?} {o:?}");
            assert!(
                o.notes
                    .iter()
                    .any(|n| n.contains(&format!("pjp-tools-{}", &KEY[..12]))),
                "{release:?} {o:?}"
            );
            assert!(out.contains("!! "), "{out}");
            assert!(builds(&sys).is_empty(), "{release:?}");
            assert!(!w.cache().exists(), "{release:?}");
            assert_eq!(w.read(&w.bin(), "pjp"), "old", "{release:?}");
            assert!(!w.bin().join(exe_name("pjp-hub")).exists(), "{release:?}");
            assert_eq!(*w.reg.borrow(), "C:\\Windows", "{release:?}");
            if release == Release::BadSha {
                assert!(expands(&sys).is_empty(), "sha256 の合わない zip は解かない");
            }
        }
    }

    /// 表の 4 行目: Release が無い・届かないときは、cargo があれば手元で作る
    #[test]
    fn builds_with_cargo_when_the_release_is_missing() {
        for (release, why) in [
            (Release::Missing, "HTTP 404"),
            (Release::Unreachable, "No such host"),
        ] {
            let w = World::new();
            let sys = w.sys(release);
            let (o, out) = w.run(APPLY, &sys);
            assert_eq!(o.kind, Kind::Ok, "{release:?} {o:?}\n{out}");
            assert!(o.text.contains("cargo で作って置いた"), "{o:?}");
            assert!(o.notes.iter().any(|n| n.contains(why)), "{release:?} {o:?}");
            let b = builds(&sys);
            assert_eq!(b.len(), 1);
            let args = b[0].args_lossy();
            assert_eq!(args[..3], ["build", "--release", "--locked"]);
            assert_eq!(
                args[3..],
                [
                    "--manifest-path".to_string(),
                    w.ws().join("Cargo.toml").to_string_lossy().into_owned(),
                    "--target-dir".to_string(),
                    w.ws().join("target").to_string_lossy().into_owned(),
                ]
            );
            assert_eq!(b[0].cwd.as_deref(), Some(w.ws().as_path()));
            assert_eq!(
                b[0].env_value("RUSTUP_TOOLCHAIN").as_deref(),
                Some("1.99.1")
            );
            assert_eq!(b[0].env_value(KEY_ENV).as_deref(), Some(KEY));
            assert!(expands(&sys).is_empty());
            let v = versions(&sys);
            assert_eq!(v.len(), 1);
            assert_eq!(v[0].program, w.cache().join(exe_name("pjp")));
            for tool in TOOLS {
                let want = format!("{tool} key={KEY} cargo");
                assert_eq!(w.read(&w.cache(), tool), want);
                assert_eq!(w.read(&w.bin(), tool), want);
            }
            assert_eq!(w.mark().source, Source::Cargo);
            assert!(!w.cache().join(ZIP_NAME).exists());
            assert_eq!(
                *w.reg.borrow(),
                format!("C:\\Windows;{}", w.bin().display())
            );
        }
    }

    /// 表の 5 行目: Release が無く cargo も無ければ、わけと直し方を出して止まる
    #[test]
    fn stops_without_a_release_or_cargo() {
        let cases: [(Release, &[&str]); 2] = [
            (
                Release::Missing,
                &["数分待って", "main に戻す", "--self-update"],
            ),
            (Release::Unreachable, &["github.com に届くか"]),
        ];
        for (release, hints) in cases {
            let w = World::new();
            w.remove_cargo();
            let sys = w.sys(release);
            let (o, out) = w.run(APPLY, &sys);
            assert_eq!(o.kind, Kind::Failed, "{release:?} {o:?}\n{out}");
            assert!(o.text.contains("cargo も無い"), "{o:?}");
            for h in hints {
                assert!(o.notes.iter().any(|n| n.contains(h)), "{h}: {o:?}");
            }
            assert!(out.contains("!! "), "{out}");
            assert!(!w.cache().exists() && !w.bin().exists());
            assert_eq!(*w.reg.borrow(), "C:\\Windows");
        }

        // check と dry-run は落とさないので、cargo が無いことだけを添える
        let w = World::new();
        w.remove_cargo();
        let sys = w.sys(Release::Missing);
        let (o, _) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(o.notes.iter().any(|n| n.contains("cargo が無い")), "{o:?}");
        let (_, out) = w.run(DRY_RUN, &sys);
        assert!(
            out.contains("[dry-run] Release が無ければ止まる (cargo が無い)"),
            "{out}"
        );
        assert!(downloads(&sys).is_empty());
    }

    /// 写しの exe が印と合わない (替わった) なら fix。apply で落とし直す。印の無い写しは無いのと同じ
    #[test]
    fn redownloads_when_the_cache_does_not_match_its_mark() {
        let w = World::new();
        w.run(APPLY, &w.sys(Release::Good));
        std::fs::write(w.cache().join(exe_name("pjp-hub")), "tampered").unwrap();
        let sys = w.sys(Release::Good);
        let (o, _) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Fix, "{o:?}");
        assert!(o.text.contains("印と合わない"), "{o:?}");
        assert!(downloads(&sys).is_empty());
        let (o, out) = w.run(APPLY, &sys);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        assert_eq!(downloads(&sys).len(), 1);
        assert_eq!(w.read(&w.cache(), "pjp-hub"), format!("pjp-hub key={KEY}"));
        let (o, _) = w.run(Mode::Check, &w.sys(Release::Good));
        assert_eq!(o.kind, Kind::Ok, "{o:?}");

        std::fs::remove_file(w.cache().join(MARK_NAME)).unwrap();
        let (o, _) = w.run(Mode::Check, &w.sys(Release::Good));
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
    }

    /// 写しが無いときの check は、bin の pjp が名乗る key を添える
    #[test]
    fn check_reads_the_bin_key_without_a_cache() {
        let w = World::new();
        w.run(APPLY, &w.sys(Release::Good));
        std::fs::remove_dir_all(w.root()).unwrap();
        let sys = w.sys(Release::Good);
        let (o, _) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains("bin の pjp の key は clone の key と同じ")),
            "{o:?}"
        );
        let v = versions(&sys);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].program, w.bin().join(exe_name("pjp")));
        std::fs::write(w.bin().join(exe_name("pjp")), format!("pjp key={OTHER}")).unwrap();
        let (o, _) = w.run(Mode::Check, &w.sys(Release::Good));
        assert!(
            o.notes
                .iter()
                .any(|n| n.contains(&OTHER[..12]) && n.contains("違う")),
            "{o:?}"
        );
        assert!(!w.root().exists(), "check は写しを作らない");
    }

    /// 手元の変更があれば、写しを使わず・作らず、cargo で作って bin に直に置く
    #[test]
    fn local_changes_build_into_bin_directly() {
        let w = World::new();
        w.run(APPLY, &w.sys(Release::Good));
        let mark_before = std::fs::read(w.cache().join(MARK_NAME)).unwrap();
        let sys = w.sys_with(Release::Good, true);
        let (o, out) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Info, "{o:?}\n{out}");
        assert!(o.text.contains("commit していない変更"), "{o:?}");
        let (o, out) = w.run(DRY_RUN, &sys);
        assert_eq!(o.kind, Kind::Info, "{o:?}");
        assert!(
            out.contains("[dry-run] cargo build --release --locked"),
            "{out}"
        );
        assert!(out.contains(&format!("{KEY_ENV} は外す")), "{out}");
        assert!(builds(&sys).is_empty() && downloads(&sys).is_empty());
        assert!(versions(&sys).is_empty());

        let (o, out) = w.run(APPLY, &sys);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        assert!(
            o.text.contains("手元の変更から cargo で作って置いた"),
            "{o:?}"
        );
        let b = builds(&sys);
        assert_eq!(b.len(), 1);
        assert!(b[0].removes_env(KEY_ENV), "{:?}", b[0]);
        assert_eq!(
            b[0].env_value("RUSTUP_TOOLCHAIN").as_deref(),
            Some("1.99.1")
        );
        assert!(downloads(&sys).is_empty());
        for tool in TOOLS {
            assert_eq!(w.read(&w.bin(), tool), format!("{tool} key= cargo"));
        }
        // 写しと印には触らない
        assert_eq!(
            std::fs::read(w.cache().join(MARK_NAME)).unwrap(),
            mark_before
        );
        assert_eq!(w.read(&w.cache(), "pjp"), format!("pjp key={KEY}"));
        // 2 回目も作るが (cargo が作り直すかを決める)、bin と同じなら写さない
        let (o, _) = w.run(APPLY, &w.sys_with(Release::Good, true));
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        assert!(o.text.contains("bin と同じ"), "{o:?}");

        // cargo が無ければ、どの流し方でも failed
        let w = World::new();
        w.remove_cargo();
        for mode in [Mode::Check, DRY_RUN, APPLY] {
            let sys = w.sys_with(Release::Good, true);
            let (o, _) = w.run(mode, &sys);
            assert_eq!(o.kind, Kind::Failed, "{mode:?} {o:?}");
            assert!(o.text.contains("手元の変更は Release に無い"), "{o:?}");
            assert!(downloads(&sys).is_empty());
            assert!(!w.bin().exists() && !w.root().exists());
        }
    }

    /// 古い key の写しは、今の key と、ほかを新しい方から 2 つ残して消す
    #[test]
    fn prunes_old_keys_keeping_the_newest() {
        let w = World::new();
        w.run(APPLY, &w.sys(Release::Good));
        let keys = [
            "1111111111111111111111111111111111111111",
            "2222222222222222222222222222222222222222",
            "3333333333333333333333333333333333333333",
            "4444444444444444444444444444444444444444",
        ];
        for (i, k) in keys.iter().enumerate() {
            let mark = w.t.write(
                &format!("home/AppData/Local/dotfiles/pjp-tools/{k}/{MARK_NAME}"),
                &format!("key={k}\n"),
            );
            set_mtime(&mark, 1_000 * (i as u64 + 1));
        }
        // 印の無い写しは dir の時刻 (今。いちばん新しい)
        let fresh = "5555555555555555555555555555555555555555";
        std::fs::create_dir_all(w.root().join(fresh)).unwrap();
        // 今の key の印がいちばん古くても残す
        set_mtime(&w.cache().join(MARK_NAME), 500);
        // key の形でない名前には触らない
        std::fs::create_dir_all(w.root().join("notes")).unwrap();
        w.t.write("home/AppData/Local/dotfiles/pjp-tools/README.txt", "x");

        let sys = w.sys(Release::Good);
        w.run(Mode::Check, &sys);
        for k in keys {
            assert!(w.root().join(k).exists(), "check は消さない: {k}");
        }
        let (_, out) = w.run(DRY_RUN, &sys);
        let line = |k: &str| {
            format!(
                "[dry-run] 消す (古い key の写し): {}",
                w.root().join(k).display()
            )
        };
        for k in &keys[..3] {
            assert!(out.contains(&line(k)), "{k}\n{out}");
        }
        for k in [keys[3], fresh, KEY] {
            assert!(!out.contains(&line(k)), "{k}\n{out}");
        }
        for k in keys {
            assert!(w.root().join(k).exists(), "dry-run は消さない: {k}");
        }
        let (o, out) = w.run(APPLY, &sys);
        assert_eq!(o.kind, Kind::Ok, "{o:?}\n{out}");
        for k in &keys[..3] {
            assert!(!w.root().join(k).exists(), "{k}");
        }
        for k in [keys[3], fresh, KEY, "notes", "README.txt"] {
            assert!(w.root().join(k).exists(), "{k}");
        }
        assert_eq!(stale_dirs(&w.root(), KEY), Vec::<PathBuf>::new());
    }

    #[test]
    fn refuses_without_workspace_git_or_key() {
        let w = World::new();
        std::fs::remove_dir_all(w.ws()).unwrap();
        let (o, _) = w.run(Mode::Check, &w.sys(Release::Good));
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("workspace が無い"), "{o:?}");

        let w = World::new();
        let sys =
            FakeSys::new(|c| panic!("打たない: {:?}", c.program)).with_program("pwsh", "pwsh");
        let (o, _) = w.run(Mode::Check, &sys);
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("git が見つからない"), "{o:?}");

        // rev-parse が落ちる・git status が落ちる
        for (fail_at, why) in [
            ("rev-parse", "not a git repository"),
            ("status", "確かめられない"),
        ] {
            let sys = FakeSys::new(move |c| {
                let args = c.args_lossy();
                if args.iter().any(|a| a == fail_at) {
                    return RunResult {
                        exit: Exit::Code(128),
                        output: vec!["fatal: not a git repository".to_string()],
                    };
                }
                RunResult {
                    exit: Exit::Code(0),
                    output: vec![KEY.to_string()],
                }
            })
            .with_program("git", "git");
            let (o, _) = w.run(Mode::Check, &sys);
            assert_eq!(o.kind, Kind::Failed, "{fail_at}: {o:?}");
            assert!(o.text.contains(why), "{fail_at}: {o:?}");
        }

        // 作るときに channel を読めない
        let w = World::new();
        w.t.write(
            "g/dotfiles/nix/pkgs/pjp-tools/rust-toolchain.toml",
            "[toolchain]\n",
        );
        let sys = w.sys_with(Release::Good, true);
        let (o, _) = w.run(APPLY, &sys);
        assert_eq!(o.kind, Kind::Failed, "{o:?}");
        assert!(o.text.contains("channel を読めない"), "{o:?}");
        assert!(builds(&sys).is_empty());
    }

    #[test]
    fn mark_round_trips_and_rejects_broken_ones() {
        let sums: BTreeMap<String, String> = exe_names()
            .into_iter()
            .enumerate()
            .map(|(i, n)| (n, format!("{i:064x}")))
            .collect();
        let m = Mark {
            key: KEY.to_string(),
            source: Source::Cargo,
            sums,
        };
        let text = m.render();
        assert!(
            text.starts_with(&format!("key={KEY}\nsource=cargo\n")),
            "{text}"
        );
        assert!(
            text.contains(&format!("{}={:064x}\n", exe_name("pjp-hub"), 1)),
            "{text}"
        );
        assert_eq!(Mark::parse(&text), Some(m.clone()));
        assert_eq!(Mark::parse(&text.replace('\n', "\r\n")), Some(m.clone()));
        let without_pjp: String = text
            .lines()
            .filter(|l| !l.starts_with(&format!("{}=", exe_name("pjp"))))
            .map(|l| format!("{l}\n"))
            .collect();
        assert_eq!(Mark::parse(&without_pjp), None);
        assert_eq!(
            Mark::parse(&text.replace("source=cargo", "source=hand")),
            None
        );
        assert_eq!(
            Mark::parse(&text.replace(&format!("key={KEY}"), "key=abc")),
            None
        );
        assert_eq!(
            Mark::parse(&text.replace(&format!("{:064x}", 1), "xyz")),
            None
        );
        let release = Mark {
            source: Source::Release,
            ..m
        };
        assert_eq!(Mark::parse(&release.render()), Some(release));
    }

    #[test]
    fn reads_sha256_files() {
        let h = "ab".repeat(32);
        assert_eq!(parse_sha256(&format!("{h}  {ZIP_NAME}\n")), Some(h.clone()));
        assert_eq!(
            parse_sha256(&format!("{}  x\r\n", h.to_uppercase())),
            Some(h.clone())
        );
        assert_eq!(parse_sha256(&format!("\n{h}\n")), Some(h.clone()));
        assert_eq!(parse_sha256("<html>"), None);
        assert_eq!(parse_sha256(""), None);
        assert_eq!(parse_sha256(&"ab".repeat(31)), None);
    }

    #[test]
    fn classifies_download_results() {
        let r = |exit: Exit, lines: &[&str]| RunResult {
            exit,
            output: lines.iter().map(|l| l.to_string()).collect(),
        };
        assert_eq!(classify(&r(Exit::Code(0), &[])), Fetch::Done);
        assert_eq!(
            classify(&r(Exit::Code(1), &["status=404", "error=Not Found"])),
            Fetch::NotFound
        );
        assert_eq!(
            classify(&r(
                Exit::Code(1),
                &["status=503", "error=Service Unavailable"]
            )),
            Fetch::Failed("HTTP 503".to_string())
        );
        assert_eq!(
            classify(&r(
                Exit::Code(1),
                &["status=0", "error=No such host is known."]
            )),
            Fetch::Failed("No such host is known.".to_string())
        );
        let Fetch::Failed(why) = classify(&r(Exit::TimedOut, &[])) else {
            panic!("時間切れは落とせない")
        };
        assert!(why.contains("時間切れ"), "{why}");
        let Fetch::Failed(why) = classify(&r(Exit::Code(1), &["boom"])) else {
            panic!("status の行が無ければ落とせない")
        };
        assert!(why.contains("boom"), "{why}");
    }

    /// PowerShell に渡す script は ASCII だけ (引用符と文字コードに頼らない)。値は env で渡す
    #[test]
    fn scripts_are_ascii_and_read_values_from_env() {
        for s in [DOWNLOAD_SCRIPT, EXPAND_SCRIPT] {
            assert!(s.is_ascii(), "{s}");
            assert!(s.contains("$ErrorActionPreference = 'Stop'"), "{s}");
            assert!(s.contains("exit 1 }"), "{s}");
        }
        for env in [SHA_URL_ENV, SHA_OUT_ENV, ZIP_URL_ENV, ZIP_OUT_ENV] {
            assert!(DOWNLOAD_SCRIPT.contains(&format!("$env:{env} ")), "{env}");
        }
        assert!(DOWNLOAD_SCRIPT.contains("-UseBasicParsing"));
        assert!(DOWNLOAD_SCRIPT.contains("Tls12"));
        for env in [ZIP_ENV, DEST_ENV] {
            assert!(EXPAND_SCRIPT.contains(&format!("$env:{env} ")), "{env}");
        }
        assert!(EXPAND_SCRIPT.contains("Expand-Archive -LiteralPath"));
        let spec = powershell(Path::new("pwsh"), EXPAND_SCRIPT, 60);
        assert_eq!(
            spec.args_lossy(),
            [
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                EXPAND_SCRIPT
            ]
        );
        assert_eq!(spec.timeout, Some(Duration::from_secs(60)));
    }

    /// 本物の PowerShell (Windows PowerShell 5.1 と、あれば 7) で、手元の HTTP server から落とし (404 も見分け)、Expand-Archive で解く
    /// (Windows の CI)
    #[cfg(windows)]
    #[test]
    fn real_powershell_downloads_and_expands() {
        use crate::process::{RealSys, Sys};
        use std::io::{BufRead, BufReader, Write};
        let Some(first) = RealSys
            .which("powershell")
            .or_else(|| RealSys.which("pwsh"))
        else {
            return;
        };
        let t = TempDir::new("pjp-tools-real");
        let src = t.path().join("src");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("pjp.exe"), b"fake exe").unwrap();
        let zip_path = t.path().join(ZIP_NAME);
        let r = RealSys.run(
            &powershell(
                &first,
                "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; Compress-Archive -Path (Join-Path $env:T_SRC '*') -DestinationPath $env:T_ZIP",
                120,
            )
            .env("T_SRC", &src)
            .env("T_ZIP", &zip_path),
            &mut |_| {},
        );
        assert_eq!(r.exit, Exit::Code(0), "{:?}", r.output);
        let zip = std::fs::read(&zip_path).unwrap();
        let sha = format!("{}  {ZIP_NAME}\n", fsutil::sha256_bytes(&zip));
        // /<tag>/<asset> だけを答え、ほかは 404
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let tagged = format!("/{}/", tag(KEY));
        let served = (format!("{tagged}{ZIP_NAME}"), format!("{tagged}{SHA_NAME}"));
        let (zip_body, sha_body) = (zip.clone(), sha.into_bytes());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut s) = stream else { continue };
                let Ok(clone) = s.try_clone() else { continue };
                let mut reader = BufReader::new(clone);
                let mut first_line = String::new();
                if reader.read_line(&mut first_line).is_err() {
                    continue;
                }
                loop {
                    let mut h = String::new();
                    match reader.read_line(&mut h) {
                        Ok(n) if n > 0 && h != "\r\n" => {}
                        _ => break,
                    }
                }
                let path = first_line.split_whitespace().nth(1).unwrap_or("");
                let (status, body) = if path == served.0 {
                    ("200 OK", zip_body.clone())
                } else if path == served.1 {
                    ("200 OK", sha_body.clone())
                } else {
                    ("404 Not Found", b"not found".to_vec())
                };
                let _ = write!(
                    s,
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(&body);
            }
        });
        let base = format!("http://127.0.0.1:{port}");
        for name in ["powershell", "pwsh"] {
            let Some(shell) = RealSys.which(name) else {
                continue;
            };
            let dir = t.path().join(name);
            std::fs::create_dir_all(&dir).unwrap();
            let fetch = |tagged: &str| {
                RealSys.run(
                    &powershell(&shell, DOWNLOAD_SCRIPT, 120)
                        .env(SHA_URL_ENV, format!("{base}{tagged}{SHA_NAME}"))
                        .env(SHA_OUT_ENV, dir.join(SHA_NAME))
                        .env(ZIP_URL_ENV, format!("{base}{tagged}{ZIP_NAME}"))
                        .env(ZIP_OUT_ENV, dir.join(ZIP_NAME)),
                    &mut |_| {},
                )
            };
            let r = fetch(&tagged);
            assert_eq!(classify(&r), Fetch::Done, "{name}: {r:?}");
            assert_eq!(std::fs::read(dir.join(ZIP_NAME)).unwrap(), zip, "{name}");
            assert_eq!(
                parse_sha256(&std::fs::read_to_string(dir.join(SHA_NAME)).unwrap()),
                Some(fsutil::sha256_bytes(&zip)),
                "{name}"
            );
            let r = fetch(&format!("/{TAG_PREFIX}000000000000/"));
            assert_eq!(classify(&r), Fetch::NotFound, "{name}: {r:?}");
            // 2 回目も上書きで通る
            for _ in 0..2 {
                let r = RealSys.run(
                    &powershell(&shell, EXPAND_SCRIPT, 120)
                        .env(ZIP_ENV, dir.join(ZIP_NAME))
                        .env(DEST_ENV, &dir),
                    &mut |_| {},
                );
                assert_eq!(r.exit, Exit::Code(0), "{name}: {:?}", r.output);
                assert_eq!(
                    std::fs::read(dir.join("pjp.exe")).unwrap(),
                    b"fake exe",
                    "{name}"
                );
            }
        }
    }
}
