//! `win/*/Install-*.ps1` を `-Check` してから入れる・揃える手順 (order 95〜97)。WSL の `nix/scripts/bootstrap-windows-<id>.sh` を写したもの。
//!
//! clone の中の ps1 を、PATH の pwsh (無ければ Windows PowerShell) の `-Command` で呼ぶ。出力は UTF-8 にしてから流し (捕まえると
//! PowerShell は端末の code page で書くため)、`$LASTEXITCODE` を 2 にしておく (ps1 が exit まで届かずに終わったとき、中の winget の 0 を
//! 返さないため)。どちらも WSL の wrapper の `pwsh_command` と同じ。
//!
//! 判断は手順ごとに WSL の wrapper と同じ (`SPECS` の表。dotfiles-private の docs/adr/060_win_runner_core_* の spec §6):
//!
//! - 0: 揃っている
//! - 3 (入っていない): `-IfMissing` で入れる (google-ime-install は、固定した版が winget に無ければ打たずに知らせる)
//! - 1 (揃っていない): 手順の `Policy` で、揃える (引数なし・`-IfMissing`)・知らせるだけ (※ の手順)
//! - 出力に状態の表の見出しが無い・ほかの終了コード: ps1 が動いていない (確かめられなかった)
//!
//! ps1 の締めの行の文言 (「→ Install-Ntn で揃える」など) を変えるときは、ここも直す (WSL の wrapper と同じ約束)。

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::process::{CommandSpec, Exit, RunResult, strip_ansi};
use crate::report::Kind;
use std::path::PathBuf;
use std::time::Duration;

/// 出力に状態の表の見出しがあるかの見方。
#[derive(Clone, Copy, Debug)]
pub enum Header {
    /// どこかの行がこれを含む
    Contains(&'static str),
    /// どこかの行がこれで始まる
    LineStartsWith(&'static str),
}

impl Header {
    fn found(self, lines: &[String]) -> bool {
        match self {
            Header::Contains(s) => lines.iter().any(|l| l.contains(s)),
            Header::LineStartsWith(s) => lines.iter().any(|l| l.starts_with(s)),
        }
    }
}

/// 1 (揃っていない) のときの扱い。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Policy {
    /// 知らせるだけ (※ の手順。入れ替えは人が決める)
    Warn,
    /// 締めの行が「→ <command> で揃える」なら引数なしで揃える。「→ ※ の手順で直す」だけ (PATH のずれ) なら知らせるだけ
    Sync,
    /// `-IfMissing` で揃える (herdr-app。入れる・上げる・フィードを書く。下げはしない)
    IfMissing,
    /// herdr: 知らせるだけで、Herdr.Herdr.Preview が残っていれば外す手順も出す。入れた後が 1 でも、残りが Preview のことだけなら入った扱い
    Herdr,
}

/// ps1 の手順の表の 1 行。
#[derive(Clone, Copy, Debug)]
pub struct Ps1Spec {
    pub id: &'static str,
    pub order: u16,
    pub title: &'static str,
    pub gate: Gate,
    /// repo からの ps1 のパス (`/` 区切り)
    pub script: &'static str,
    /// PowerShell の関数の名前 (`win/powershell/dotfiles.ps1`。締めの行と直し方に出る)
    pub command: &'static str,
    /// 確かめるもの (「Windows の ntn」)
    pub subject: &'static str,
    /// 入れるもの (「ntn (winget の Notion.ntn)」)
    pub package: &'static str,
    pub header: Header,
    pub check_secs: u64,
    pub install_secs: u64,
    pub policy: Policy,
    /// 入れるときに UAC の確認が出る (先に知らせ、時間切れなら UAC の見込みを添える)
    pub uac: bool,
    /// 揃っているときの 1 行
    pub ok_text: &'static str,
    /// 入れた後に添える行
    pub installed: &'static [&'static str],
    /// 揃えた後に添える行
    pub synced: &'static [&'static str],
    /// runner が揃えないとき (知らせるだけ) の直し方
    pub manual_fix: &'static [&'static str],
    /// 揃えられなかったときの直し方 (Sync・IfMissing)
    pub sync_fix: &'static [&'static str],
    /// `-ReleasesFile` に clone の nix/pkgs/herdr-core/releases.json を渡す (herdr-app。配った写しは隣の herdr-releases.json を読む)
    pub releases_file: bool,
    /// 3 でも、出力にこれがあれば入れられないので打たない (google-ime-install の「固定した版が winget に無い」)
    pub missing_blocked: Option<&'static str>,
    /// 出力の印ごとの直し方 (上から見て最初に当たったもの)。当たれば `manual_fix`・`sync_fix` の代わりに出す (google-ime-install の
    /// 「下げない」「winget に無い」「比べられない」。揃えるコマンドを打っても直らないとき)
    pub output_fixes: &'static [(&'static str, &'static str)],
}

const UAC_LEFT: &str = "Windows のデスクトップに UAC の確認が残っていれば、先に押すか閉じてから流し直す (残ったまま流し直すと、別のインストールが進行中 (1618) で落ちる)";

pub const SPECS: &[Ps1Spec] = &[
    Ps1Spec {
        id: "google-ime-install",
        order: 95,
        title: "Google 日本語入力を固定した版で入れる (ずれていても上げない)",
        gate: Gate::Always,
        script: "win/google-japanese-input/Install-GoogleJapaneseInput.ps1",
        command: "Install-GoogleJapaneseInput",
        subject: "Windows の Google 日本語入力",
        package: "Google 日本語入力 (winget の Google.JapaneseIME)",
        header: Header::Contains("Google.JapaneseIME"),
        check_secs: 120,
        install_secs: 600,
        policy: Policy::Warn,
        uac: true,
        ok_text: "Windows の Google 日本語入力は、dotfiles で固定した版に揃っています。",
        installed: &[
            "設定を置く手順 (google-ime。runner にまだ無く、WSL の bootstrap-windows-google-ime.sh) が「まだ使われていません」と出したら、Google 日本語入力で一度何か打ってから流し直す",
        ],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-GoogleJapaneseInput を打つ (入れる・上げるときは Windows に UAC の確認が出る。上げる前に、日本語入力を使っているアプリをできるだけ閉じる。runner は上げない: 入れ替えるとアプリや Windows の再起動が要ることがある)",
        ],
        sync_fix: &[
            "入れるには PowerShell で Install-GoogleJapaneseInput を打つか、dotfiles apply --steps google-ime-install を流し直す (Windows に UAC の確認が出る)",
        ],
        releases_file: false,
        missing_blocked: Some("winget show --versions に無い"),
        output_fixes: &[
            (
                "(下げない)",
                "入っている版の方が新しいので、下げはしない。上の ※ のとおり、repo の版 (Install-GoogleJapaneseInput.ps1 の -Version) を上げる",
            ),
            (
                "winget show --versions に無い",
                "固定した版が winget に無いので、入れることも上げることもできない。repo の版 (Install-GoogleJapaneseInput.ps1 の -Version) を winget show --id Google.JapaneseIME --versions にある版へ変える",
            ),
            (
                "比べられない",
                "入っている版が読めないので、揃えられない。上の ※ のとおり、PowerShell で winget list --id Google.JapaneseIME を打って入っている版を確かめる",
            ),
        ],
    },
    Ps1Spec {
        id: "openssh",
        order: 96,
        title: "OpenSSH を固定した版で入れる (ずれていても揃えない)",
        gate: Gate::Always,
        script: "win/openssh/Install-OpenSSH.ps1",
        command: "Install-OpenSSH",
        subject: "Windows の OpenSSH",
        package: "OpenSSH (Microsoft.OpenSSH.Preview)",
        header: Header::Contains("Microsoft.OpenSSH.Preview"),
        check_secs: 120,
        install_secs: 600,
        policy: Policy::Warn,
        uac: true,
        ok_text: "Windows の OpenSSH は、dotfiles で固定した版に揃っています。",
        installed: &[
            "Windows の OpenSSH を入れました (固定した版。ssh-agent サービスは停止・無効、winget pin あり)。",
            "1Password の鍵は、1Password の SSH agent を有効にしてから PowerShell の Install-OpenSSH -Check で確かめる",
        ],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-OpenSSH を打つ (差があれば Windows に UAC が 1 回出る。runner は揃えない: UAC を押すまで止まり、動いている ssh も巻き込むため)",
        ],
        sync_fix: &[
            "入れ直すには PowerShell で Install-OpenSSH -IfMissing を打つ (Windows に UAC が 1 回出る)",
        ],
        releases_file: false,
        missing_blocked: None,
        output_fixes: &[],
    },
    Ps1Spec {
        id: "claude-code",
        order: 97,
        title: "Claude Code を固定した版に揃える",
        gate: Gate::Tool("windowsClaudeCode"),
        script: "win/claude-code/Install-ClaudeCode.ps1",
        command: "Install-ClaudeCode",
        subject: "Windows の Claude Code",
        package: "Claude Code (winget の Anthropic.ClaudeCode)",
        header: Header::Contains("Claude Code (winget の Anthropic.ClaudeCode"),
        check_secs: 120,
        // claude.exe は約 340 MB で、winget download と install で 2 回落とす (WSL の bootstrap-windows-claude-code.sh の apply_timeout)
        install_secs: 1800,
        policy: Policy::Sync,
        uac: false,
        ok_text: "Windows の Claude Code は、dotfiles で固定した版に揃っています。",
        installed: &["Windows の Claude Code を入れました (固定した版と pin が揃っています)。"],
        synced: &["Windows の Claude Code を揃えました (固定した版と pin が揃っています)。"],
        manual_fix: &[
            "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「Claude Code」)",
        ],
        sync_fix: &[
            "揃えるには PowerShell で Install-ClaudeCode を打つか、dotfiles apply --steps claude-code を流し直す (入れ替えるときは、Windows で開いている Claude Code の会話を先に閉じる)",
        ],
        releases_file: false,
        missing_blocked: None,
        output_fixes: &[],
    },
    Ps1Spec {
        id: "herdr-app",
        order: 97,
        title: "herdr-app と herdr-core を固定した版と取得元 (手元のフィード) に揃える",
        gate: Gate::Tool("windowsHerdr"),
        script: "win/herdr-app/Install-HerdrApp.ps1",
        command: "Install-HerdrApp",
        subject: "Windows の herdr-app",
        package: "herdr-app",
        header: Header::LineStartsWith("herdr-app ("),
        check_secs: 60,
        install_secs: 600,
        policy: Policy::IfMissing,
        uac: false,
        ok_text: "Windows の herdr-app と herdr-core は、固定した版と取得元 (手元のフィード) に揃っています。",
        installed: &["Windows に herdr-app を入れました。スタートメニューの Herdr から開けます。"],
        synced: &[
            "Windows の herdr-app を揃えました。開いている app は、閉じて開き直すと取得元の変更が効きます。",
        ],
        manual_fix: &[],
        sync_fix: &[
            "揃えるには PowerShell で Install-HerdrApp を打つか、dotfiles apply --steps herdr-app を流し直す (固定より新しい版が入っているときは下げない。上の出力を見る)",
        ],
        releases_file: true,
        missing_blocked: None,
        output_fixes: &[],
    },
    Ps1Spec {
        id: "herdr",
        order: 97,
        title: "herdr を固定した版で入れる (ずれていても入れ替えない)",
        gate: Gate::Tool("windowsHerdr"),
        script: "win/herdr/Install-Herdr.ps1",
        command: "Install-Herdr",
        subject: "Windows の herdr",
        package: "herdr (winget の Herdr.Herdr)",
        header: Header::Contains("herdr (winget の Herdr.Herdr"),
        check_secs: 120,
        install_secs: 600,
        policy: Policy::Herdr,
        uac: false,
        ok_text: "Windows の herdr は、dotfiles で固定した版に揃っています。",
        installed: &["Windows に herdr を入れました。"],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-Herdr を打つ (入れ替えるときは、先に herdr の外の PowerShell で hsvstop)",
        ],
        sync_fix: &["入れ直すには PowerShell で Install-Herdr -IfMissing を打つ"],
        releases_file: false,
        missing_blocked: None,
        output_fixes: &[],
    },
    Ps1Spec {
        id: "ntn",
        order: 97,
        title: "ntn (Notion の CLI) を固定した版に揃える",
        gate: Gate::Tool("windowsNtn"),
        script: "win/ntn/Install-Ntn.ps1",
        command: "Install-Ntn",
        subject: "Windows の ntn",
        package: "ntn (winget の Notion.ntn)",
        header: Header::Contains("ntn (winget の Notion.ntn"),
        check_secs: 120,
        install_secs: 600,
        policy: Policy::Sync,
        uac: false,
        ok_text: "Windows の ntn は、dotfiles で固定した版に揃っています。",
        installed: &["Windows の ntn を入れました (固定した版と pin が揃っています)。"],
        synced: &["Windows の ntn を揃えました (固定した版と pin が揃っています)。"],
        manual_fix: &[
            "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「ntn」)",
        ],
        sync_fix: &[
            "揃えるには PowerShell で Install-Ntn を打つか、dotfiles apply --steps ntn を流し直す (入れ替えるときは、動いている ntn を先に終わらせる)",
        ],
        releases_file: false,
        missing_blocked: None,
        output_fixes: &[],
    },
    Ps1Spec {
        id: "type-clipboard",
        order: 97,
        title: "type-clipboard を固定した版で入れる (ずれていても入れ替えない)",
        gate: Gate::Tool("windowsTypeClipboard"),
        script: "win/type-clipboard/Install-TypeClipboard.ps1",
        command: "Install-TypeClipboard",
        subject: "Windows の type-clipboard",
        package: "type-clipboard (GitHub の Release)",
        header: Header::Contains("type-clipboard (GitHub の Release"),
        check_secs: 60,
        install_secs: 300,
        policy: Policy::Warn,
        uac: false,
        ok_text: "Windows の type-clipboard は、dotfiles で固定した版に揃っています。",
        installed: &[
            "Windows に type-clipboard を入れました (スタートメニューの type-clipboard から起こす)。",
        ],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-TypeClipboard を打つ (入れ替えるときは、先に type-clipboard の窓を閉じる。動いていると止まる)",
        ],
        sync_fix: &["入れ直すには PowerShell で Install-TypeClipboard -IfMissing を打つ"],
        releases_file: false,
        missing_blocked: None,
        output_fixes: &[],
    },
];

/// herdr の Herdr.Herdr.Preview を外す手順 (Install-Herdr.ps1 の締めの行と同じ中身)
const HERDR_PREVIEW_FIX: &[&str] = &[
    "Herdr.Herdr.Preview を外すには (runner は外さない。herdr server を止めると pane が消えるので、時期を選んで打つ):",
    "  1. herdr の外の PowerShell (Windows Terminal など) で hsvstop を打ち、herdr --remote の窓も閉じる",
    "  2. PowerShell で winget uninstall --product-code Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe を打つ",
    "  3. 続けて winget pin remove --id Herdr.Herdr.Preview --exact を打つ (Preview の pin を外す)",
    "  4. 新しい PowerShell から herdr を起動し直す",
];

/// ps1 の締めの行から読んだ、直すこと。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Verdict {
    install: bool,
    sync: bool,
    path: bool,
    preview: bool,
}

fn read_verdict(spec: &Ps1Spec, lines: &[String]) -> Verdict {
    let has = |s: &str| lines.iter().any(|l| l.contains(s));
    let mut v = Verdict {
        install: has(&format!("→ {} で入れる", spec.command)),
        sync: has(&format!("→ {} で揃える", spec.command)),
        path: has("→ ※ の手順で直す"),
        preview: has("⚠️ Herdr.Herdr.Preview が残っている"),
    };
    if spec.policy == Policy::Herdr {
        // WSL の wrapper と同じく、⚠️ で始まる締めの行の「→ Install-Herdr で揃える・入れる」だけを差として読む
        v.sync = lines.iter().any(|l| {
            l.starts_with("⚠️ ")
                && (l.contains("→ Install-Herdr で揃える")
                    || l.contains("→ Install-Herdr で入れる"))
        });
    }
    v
}

pub struct Ps1Step(pub &'static Ps1Spec);

/// PowerShell の一重引用符の中に入れる。`'` と、PowerShell が `'` と同じに読む U+2018〜U+201B (‘ ’ ‚ ‛) は、どれも重ねる。
pub fn ps_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        out.push(c);
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            out.push(c);
        }
    }
    out
}

/// pwsh (無ければ Windows PowerShell) で ps1 を流すコマンド。`script_args` は ps1 に渡す引数 (`" -Check"` など。空なら揃える)。
pub fn powershell_command(
    shell: PathBuf,
    script: &str,
    script_args: &str,
    timeout: Duration,
) -> CommandSpec {
    let command = format!(
        "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $global:LASTEXITCODE = 2; & '{}'{script_args}; exit $LASTEXITCODE",
        ps_quote(script)
    );
    CommandSpec::new(shell)
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(command)
        .timeout(timeout)
}

/// PATH の pwsh、無ければ Windows PowerShell。
pub fn find_powershell(ctx: &Ctx) -> Option<PathBuf> {
    ctx.sys
        .which("pwsh")
        .or_else(|| ctx.sys.which("powershell"))
}

/// コマンドを流し、出力を字下げして流しながら、色を落とした写しを返す。
pub fn run_streaming(ctx: &mut Ctx, spec: &CommandSpec) -> RunResult {
    let sys = ctx.sys;
    let out = &mut *ctx.out;
    let mut r = sys.run(spec, &mut |l| {
        let _ = writeln!(out, "    {}", strip_ansi(l));
    });
    r.output = r.output.iter().map(|l| strip_ansi(l)).collect();
    r
}

impl Ps1Step {
    fn script_name(&self) -> &'static str {
        self.0.script.rsplit('/').next().unwrap_or(self.0.script)
    }

    fn args(&self, ctx: &Ctx, base: &str) -> String {
        if self.0.releases_file {
            let rel = ctx.repo_path("nix/pkgs/herdr-core/releases.json");
            format!(
                "{base} -ReleasesFile '{}'",
                ps_quote(&rel.to_string_lossy())
            )
        } else {
            base.to_string()
        }
    }

    /// 直し方: 出力の印 (`output_fixes`) に当たればそれ、無ければ `default`。
    fn fixes(&self, lines: &[String], default: &[&'static str]) -> Vec<String> {
        for (marker, fix) in self.0.output_fixes {
            if lines.iter().any(|l| l.contains(marker)) {
                return vec![fix.to_string()];
            }
        }
        default.iter().map(|n| n.to_string()).collect()
    }

    fn manual_command(&self) -> String {
        format!(
            "PowerShell で {} -Check を打つと、同じことを確かめられる",
            self.0.command
        )
    }

    /// `-Check` が見せた状態から、apply がすること (`None` は揃っている・知らせるだけ・確かめられない)。
    fn plan(&self, code: Option<i32>, header: bool, v: Verdict, lines: &[String]) -> Plan {
        let s = self.0;
        match (code, header) {
            (Some(0), _) => Plan::Ok,
            (Some(3), true) => {
                if let Some(marker) = s.missing_blocked
                    && lines.iter().any(|l| l.contains(marker))
                {
                    Plan::Blocked
                } else {
                    Plan::Install
                }
            }
            (Some(1), true) => match s.policy {
                Policy::Warn => Plan::Warn,
                Policy::Herdr => Plan::HerdrWarn,
                Policy::IfMissing => Plan::SyncIfMissing,
                Policy::Sync => {
                    if v.sync {
                        Plan::Sync
                    } else {
                        Plan::PathOnly
                    }
                }
            },
            _ => Plan::CheckFailed,
        }
    }
}

/// `-Check` の後に apply がすること。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Plan {
    Ok,
    /// `-IfMissing` で入れる
    Install,
    /// 入っていないが、入れられない (固定した版が winget に無い)
    Blocked,
    /// 引数なしで揃える
    Sync,
    /// `-IfMissing` で揃える (herdr-app)
    SyncIfMissing,
    /// 知らせるだけ
    Warn,
    /// herdr の知らせるだけ (Preview と差)
    HerdrWarn,
    /// PATH のずれだけ (知らせるだけ)
    PathOnly,
    /// 確かめられなかった
    CheckFailed,
}

impl Step for Ps1Step {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: self.0.id,
            order: self.0.order,
            title: self.0.title,
            gate: self.0.gate,
            ported: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let s = self.0;
        let script = ctx.repo_path(s.script);
        if !script.is_file() {
            ctx.say(format!("!! {} がありません", script.display()));
            return vec![Outcome::new(
                Kind::Failed,
                format!("{} が clone に無い", s.script),
            )];
        }
        let Some(shell) = find_powershell(ctx) else {
            ctx.say("!! pwsh も powershell も PATH に見つかりません");
            return vec![
                Outcome::new(Kind::Failed, "PowerShell が見つからない (pwsh・powershell)")
                    .note(self.manual_command()),
            ];
        };
        let script_str = script.to_string_lossy().into_owned();
        let check = powershell_command(
            shell.clone(),
            &script_str,
            &self.args(ctx, " -Check"),
            Duration::from_secs(s.check_secs),
        );
        let r = run_streaming(ctx, &check);
        let header = s.header.found(&r.output);
        let v = read_verdict(s, &r.output);
        if r.exit == Exit::TimedOut {
            return vec![
                Outcome::new(
                    Kind::Failed,
                    format!(
                        "{} -Check が {} 秒たっても終わらなかった (時間切れ。winget の応答が止まっているかもしれない)",
                        self.script_name(),
                        s.check_secs
                    ),
                )
                .note(self.manual_command()),
            ];
        }
        let plan = self.plan(r.code(), header, v, &r.output);
        let name = self.script_name();
        match plan {
            Plan::Ok => {
                ctx.say(s.ok_text);
                vec![Outcome::new(Kind::Ok, "揃っている")]
            }
            Plan::CheckFailed => {
                let why = match &r.exit {
                    Exit::SpawnFailed(e) => format!("起こせなかった: {e}"),
                    Exit::Code(c) if !header => format!("終了コード {c}。状態の表が出ていない"),
                    Exit::Code(c) => format!("終了コード {c}"),
                    _ => "終了コードが無い".to_string(),
                };
                vec![
                    Outcome::new(
                        Kind::Failed,
                        format!("{name} -Check で確かめられなかった ({why})"),
                    )
                    .note(self.manual_command()),
                ]
            }
            Plan::Blocked => {
                let mut o = Outcome::new(
                    Kind::Manual,
                    format!(
                        "入っていないが、固定した版が winget に無いので入れられない ({name} の -Version)"
                    ),
                );
                for n in self.fixes(
                    &r.output,
                    &["上の出力の ⚠️ の行の手順で -Version を winget にある版へ変える"],
                ) {
                    o = o.note(n);
                }
                vec![o]
            }
            Plan::Warn | Plan::HerdrWarn | Plan::PathOnly => self.warn(plan, v, &r.output),
            Plan::Install | Plan::Sync | Plan::SyncIfMissing => {
                let (args, label) = match plan {
                    Plan::Install => (" -IfMissing", "入れる"),
                    Plan::Sync => ("", "揃える"),
                    _ => (" -IfMissing", "揃える"),
                };
                let shown = format!("{name}{args}");
                match mode {
                    Mode::Check => vec![self.pending_outcome(plan, &shown)],
                    Mode::DryRun { .. } => {
                        ctx.say(format!("[dry-run] {shown} を流す ({label})"));
                        vec![self.pending_outcome(plan, &shown)]
                    }
                    Mode::Apply { .. } => self.act(ctx, shell, &script_str, plan, args),
                }
            }
        }
    }
}

impl Ps1Step {
    /// apply の前の行 (check・dry-run)
    fn pending_outcome(&self, plan: Plan, shown: &str) -> Outcome {
        match plan {
            Plan::Install => Outcome::new(
                Kind::Missing,
                format!("入っていない → apply で入れる ({shown})"),
            ),
            _ => Outcome::new(
                Kind::Fix,
                format!("固定した版と揃っていない → apply で揃える ({shown})"),
            ),
        }
    }

    /// 知らせるだけの行
    fn warn(&self, plan: Plan, v: Verdict, lines: &[String]) -> Vec<Outcome> {
        let s = self.0;
        match plan {
            Plan::PathOnly => {
                let mut o = Outcome::new(
                    Kind::Manual,
                    format!(
                        "PATH で引かれるものが winget のものではない ({} -Check の ※ の行)",
                        s.command
                    ),
                );
                for n in s.manual_fix {
                    o = o.note(*n);
                }
                vec![o]
            }
            Plan::HerdrWarn if v.preview && !v.sync => {
                let mut o = Outcome::new(
                    Kind::Manual,
                    "前の herdr (Herdr.Herdr.Preview) が残っている",
                );
                for n in HERDR_PREVIEW_FIX {
                    o = o.note(*n);
                }
                vec![o]
            }
            _ => {
                let mut o = Outcome::new(
                    Kind::Manual,
                    "固定した版と揃っていない → ※ の手順で直す (runner は揃えない)",
                );
                if plan == Plan::HerdrWarn && v.preview {
                    for n in HERDR_PREVIEW_FIX {
                        o = o.note(*n);
                    }
                }
                for n in self.fixes(lines, s.manual_fix) {
                    o = o.note(n);
                }
                vec![o]
            }
        }
    }

    /// apply で入れる・揃える。打った後の終了コードと締めの行で行を決める。
    fn act(
        &self,
        ctx: &mut Ctx,
        shell: PathBuf,
        script: &str,
        plan: Plan,
        args: &str,
    ) -> Vec<Outcome> {
        let s = self.0;
        let name = self.script_name();
        let installing = plan == Plan::Install;
        if installing {
            ctx.say(format!(
                "Windows に {} が入っていないので、固定した版を入れます ({name}{args}。{} 秒まで待ちます)。",
                s.package, s.install_secs
            ));
        } else {
            ctx.say(format!(
                "{} が固定した版と揃っていないので、揃えます ({name}{args}。{} 秒まで待ちます)。",
                s.subject, s.install_secs
            ));
        }
        if s.uac {
            ctx.say(
                "Windows のデスクトップに UAC の確認が出ます。出たら「はい」を押してください。",
            );
        }
        let spec = powershell_command(
            shell,
            script,
            &self.args(ctx, args),
            Duration::from_secs(s.install_secs),
        );
        let r = run_streaming(ctx, &spec);
        let v = read_verdict(s, &r.output);
        let did = if installing { "入れ" } else { "揃え" };
        if r.exit == Exit::TimedOut {
            let mut o = Outcome::new(
                Kind::Failed,
                format!(
                    "{}られなかった ({} 秒待っても終わらない)",
                    did, s.install_secs
                ),
            );
            if s.uac {
                o = o.note(UAC_LEFT);
            }
            for n in self.fixes(&r.output, s.sync_fix) {
                o = o.note(n);
            }
            return vec![o];
        }
        let code = r.code();
        // herdr: Preview が残っていると -IfMissing は 1 を返す。締めの行が Preview のことだけなら入った扱い
        let herdr_preview_only =
            s.policy == Policy::Herdr && code == Some(1) && v.preview && !v.sync;
        if code == Some(0) || herdr_preview_only {
            for l in if installing { s.installed } else { s.synced } {
                ctx.say(*l);
            }
            let mut out = vec![Outcome::new(Kind::Ok, format!("{did}た"))];
            if herdr_preview_only {
                let mut o = Outcome::new(
                    Kind::Manual,
                    "前の herdr (Herdr.Herdr.Preview) が残っている",
                );
                for n in HERDR_PREVIEW_FIX {
                    o = o.note(*n);
                }
                out.push(o);
            }
            return out;
        }
        // Sync: 版と pin は揃ったが、PATH のずれだけが残った
        if s.policy == Policy::Sync && code == Some(1) && v.path && !v.sync && !v.install {
            let mut o = Outcome::new(
                Kind::Manual,
                format!(
                    "版と pin は揃ったが、PATH で引かれるものが winget のものではない ({} -Check の ※ の行)",
                    s.command
                ),
            );
            for n in s.manual_fix {
                o = o.note(*n);
            }
            return vec![o];
        }
        let why = match &r.exit {
            Exit::Code(c) => format!("終了コード {c}"),
            Exit::SpawnFailed(e) => format!("起こせなかった: {e}"),
            _ => "終了コードが無い".to_string(),
        };
        let mut o = Outcome::new(
            Kind::Failed,
            format!("{did}られなかった ({why}。上の出力を見る)"),
        );
        for n in self.fixes(&r.output, s.sync_fix) {
            o = o.note(n);
        }
        if v.path && s.policy == Policy::Sync {
            for n in s.manual_fix {
                o = o.note(*n);
            }
        }
        vec![o]
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること (WSL の bootstrap-windows-<id>.sh の分かれ道と同じ)
    //!
    //! - 0 は揃っている。check と dry-run は -Check だけを打つ (dry-run は打つはずのものを出す)
    //! - 3 は apply で -IfMissing を打つ。google-ime-install は、固定した版が winget に無ければ打たずに知らせる
    //! - 1 は手順ごと: ntn・claude-code は「→ … で揃える」なら引数なしで揃え、PATH のずれだけなら知らせる。herdr-app は -IfMissing で
    //!   揃える。openssh・type-clipboard・google-ime-install は知らせるだけ。herdr は知らせるだけで、Preview が残っていれば外す手順も出す
    //! - 入れた後が 1 でも、herdr は残りが Preview だけなら入った扱い。ntn は PATH のずれだけなら知らせる
    //! - 見出しが無い・時間切れ・PowerShell が無い・ps1 が無いのは確かめられなかった
    //! - PowerShell のコマンドの組み立て (UTF-8・$LASTEXITCODE = 2・' の重ね・herdr-app の -ReleasesFile・pwsh が無ければ powershell)

    use super::*;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::process::RunResult;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    fn spec(id: &str) -> &'static Ps1Spec {
        SPECS.iter().find(|s| s.id == id).unwrap()
    }

    fn header_line(s: &Ps1Spec) -> String {
        match s.header {
            Header::Contains(h) => format!("  {h}) 0.1.0"),
            Header::LineStartsWith(h) => format!("{h}x) 0.1.0"),
        }
    }

    /// 偽の pwsh。`-Check` には check の (終了コード, 行) を、ほかには act の (終了コード, 行) を返す
    fn sys(check: (i32, Vec<String>), act: (i32, Vec<String>)) -> FakeSys {
        FakeSys::new(move |c| {
            let cmd = c.args_lossy().last().cloned().unwrap_or_default();
            let (code, lines) = if cmd.contains("' -Check") {
                check.clone()
            } else {
                act.clone()
            };
            RunResult {
                exit: if code < 0 {
                    Exit::TimedOut
                } else {
                    Exit::Code(code)
                },
                output: lines,
            }
        })
        .with_program("pwsh", "C:/pwsh/pwsh.exe")
    }

    fn run(id: &str, sys: &FakeSys, mode: Mode) -> (Vec<Outcome>, String, Vec<String>) {
        let t = TempDir::new("ps1");
        t.write(spec(id).script, "# ps1\n");
        let mut out = Vec::new();
        let outcomes = {
            let mut ctx = Ctx {
                repo: t.path().to_path_buf(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: t.path().join("state"),
                host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
                sys,
                out: &mut out,
            };
            Ps1Step(spec(id)).run(&mut ctx, mode)
        };
        let calls: Vec<String> = sys
            .calls
            .borrow()
            .iter()
            .map(|c| c.args_lossy().last().cloned().unwrap_or_default())
            .collect();
        (outcomes, String::from_utf8(out).unwrap(), calls)
    }

    const APPLY: Mode = Mode::Apply { force: false };

    fn ends(calls: &[String]) -> Vec<String> {
        calls
            .iter()
            .map(|c| {
                let after = c.rsplit_once(".ps1'").map(|(_, a)| a).unwrap_or("");
                after.split(';').next().unwrap_or("").trim().to_string()
            })
            .collect()
    }

    #[test]
    fn ok_runs_only_check() {
        let s = spec("ntn");
        let sys = sys(
            (0, vec![header_line(s), "※ winget に新しい版".into()]),
            (9, vec![]),
        );
        let (o, out, calls) = run("ntn", &sys, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃っている")]);
        assert_eq!(ends(&calls), vec!["-Check"]);
        assert!(out.contains("    ※ winget に新しい版"));
        assert!(out.contains("Windows の ntn は、dotfiles で固定した版に揃っています。"));
    }

    #[test]
    fn missing_installs_with_if_missing_only_in_apply() {
        let s = spec("ntn");
        let check = (
            3,
            vec![
                header_line(s),
                "⚠️ ntn が入っていない → Install-Ntn で入れる ⚠️".into(),
            ],
        );
        let sys1 = sys(check.clone(), (0, vec!["入れた".into()]));
        let (o, _, calls) = run("ntn", &sys1, Mode::Check);
        assert_eq!(o[0].kind, Kind::Missing);
        assert_eq!(
            o[0].text,
            "入っていない → apply で入れる (Install-Ntn.ps1 -IfMissing)"
        );
        assert_eq!(ends(&calls), vec!["-Check"]);

        let sys2 = sys(check.clone(), (0, vec![]));
        let (o, out, calls) = run("ntn", &sys2, Mode::DryRun { force: false });
        assert_eq!(o[0].kind, Kind::Missing);
        assert!(out.contains("[dry-run] Install-Ntn.ps1 -IfMissing を流す (入れる)"));
        assert_eq!(ends(&calls), vec!["-Check"]);

        let sys3 = sys(check, (0, vec!["入れた".into()]));
        let (o, out, calls) = run("ntn", &sys3, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")]);
        assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"]);
        assert!(out.contains("Windows の ntn を入れました"));
    }

    #[test]
    fn sync_policy_syncs_drift_and_warns_path() {
        let s = spec("claude-code");
        let drift = (
            1,
            vec![
                header_line(s),
                "⚠️ 固定した版と揃っていない → Install-ClaudeCode で揃える ⚠️".into(),
            ],
        );
        let sys1 = sys(drift.clone(), (0, vec![]));
        let (o, _, calls) = run("claude-code", &sys1, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃えた")]);
        assert_eq!(ends(&calls), vec!["-Check", ""]);
        let sys1c = sys(drift, (0, vec![]));
        let (o, _, _) = run("claude-code", &sys1c, Mode::Check);
        assert_eq!(o[0].kind, Kind::Fix);
        assert_eq!(
            o[0].text,
            "固定した版と揃っていない → apply で揃える (Install-ClaudeCode.ps1)"
        );

        let path_only = (
            1,
            vec![
                header_line(s),
                "⚠️ PATH の claude が winget のものではない → ※ の手順で直す ⚠️".into(),
            ],
        );
        let sys2 = sys(path_only, (0, vec![]));
        let (o, _, calls) = run("claude-code", &sys2, APPLY);
        assert_eq!(o[0].kind, Kind::Manual);
        assert!(
            o[0].text
                .contains("PATH で引かれるものが winget のものではない")
        );
        assert_eq!(ends(&calls), vec!["-Check"]);
    }

    #[test]
    fn sync_that_leaves_only_path_drift_is_manual() {
        let s = spec("ntn");
        let drift = (
            1,
            vec![
                header_line(s),
                "⚠️ 固定した版と揃っていない → Install-Ntn で揃える ⚠️".into(),
            ],
        );
        let after = (
            1,
            vec!["⚠️ PATH の ntn が winget のものではない → ※ の手順で直す ⚠️".into()],
        );
        let sys1 = sys(drift.clone(), after);
        let (o, _, _) = run("ntn", &sys1, APPLY);
        assert_eq!(o[0].kind, Kind::Manual);
        assert!(o[0].text.starts_with("版と pin は揃ったが"));
        let sys2 = sys(
            drift,
            (
                1,
                vec!["⚠️ ntn.exe が動いている → 止めてから Install-Ntn で揃える ⚠️".into()],
            ),
        );
        let (o, _, _) = run("ntn", &sys2, APPLY);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(o[0].text.starts_with("揃えられなかった (終了コード 1"));
        assert!(o[0].notes[0].contains("Install-Ntn"));
    }

    #[test]
    fn herdr_app_syncs_drift_with_if_missing() {
        let s = spec("herdr-app");
        let sys1 = sys((1, vec![header_line(s)]), (0, vec![]));
        let (o, out, calls) = run("herdr-app", &sys1, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃えた")]);
        assert_eq!(calls.len(), 2);
        assert!(calls[0].contains("' -Check -ReleasesFile '"));
        assert!(calls[0].contains("releases.json'"));
        assert!(calls[1].contains("' -IfMissing -ReleasesFile '"));
        assert!(out.contains("Windows の herdr-app を揃えました"));
        let sys2 = sys((1, vec!["見出しの無い出力".into()]), (0, vec![]));
        let (o, _, _) = run("herdr-app", &sys2, APPLY);
        assert_eq!(o[0].kind, Kind::Failed);
    }

    #[test]
    fn warn_policies_do_not_touch_drift() {
        for id in ["openssh", "type-clipboard", "google-ime-install"] {
            let s = spec(id);
            let sys1 = sys((1, vec![header_line(s)]), (0, vec![]));
            let (o, _, calls) = run(id, &sys1, APPLY);
            assert_eq!(o[0].kind, Kind::Manual, "{id}");
            assert_eq!(ends(&calls), vec!["-Check"], "{id}");
            assert!(!o[0].notes.is_empty(), "{id}");
        }
    }

    #[test]
    fn google_ime_missing_but_not_in_winget_is_not_installed() {
        let s = spec("google-ime-install");
        let sys1 = sys(
            (
                3,
                vec![
                    header_line(s),
                    "⚠ 固定した版      : 3.35 → winget show --versions に無い".into(),
                ],
            ),
            (0, vec![]),
        );
        let (o, _, calls) = run("google-ime-install", &sys1, APPLY);
        assert_eq!(o[0].kind, Kind::Manual);
        assert_eq!(ends(&calls), vec!["-Check"]);
        let sys2 = sys((3, vec![header_line(s)]), (0, vec![]));
        let (o, out, calls) = run("google-ime-install", &sys2, APPLY);
        assert_eq!(o[0].kind, Kind::Ok);
        assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"]);
        assert!(out.contains("UAC の確認が出ます"));
    }

    #[test]
    fn herdr_preview_handling() {
        let s = spec("herdr");
        let preview = "⚠️ Herdr.Herdr.Preview が残っている → 外す ⚠️".to_string();
        let sync = "⚠️ 固定した版と揃っていない → Install-Herdr で揃える ⚠️".to_string();
        // 1: Preview だけ
        let sys1 = sys((1, vec![header_line(s), preview.clone()]), (0, vec![]));
        let (o, _, calls) = run("herdr", &sys1, APPLY);
        assert_eq!(o[0].text, "前の herdr (Herdr.Herdr.Preview) が残っている");
        assert_eq!(ends(&calls), vec!["-Check"]);
        // 1: Preview と差
        let sys2 = sys(
            (1, vec![header_line(s), preview.clone(), sync.clone()]),
            (0, vec![]),
        );
        let (o, _, _) = run("herdr", &sys2, APPLY);
        assert!(o[0].text.contains("※ の手順で直す"));
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("Herdr.Herdr.Preview を外すには"))
        );
        assert!(o[0].notes.iter().any(|n| n.contains("hsvstop")));
        // 3 → -IfMissing が Preview だけで 1 を返しても入った扱い
        let sys3 = sys((3, vec![header_line(s)]), (1, vec![preview.clone()]));
        let (o, out, calls) = run("herdr", &sys3, APPLY);
        assert_eq!(o[0], Outcome::new(Kind::Ok, "入れた"));
        assert_eq!(o[1].kind, Kind::Manual);
        assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"]);
        assert!(out.contains("Windows に herdr を入れました。"));
        // 3 → -IfMissing が差で 1 なら入れられなかった (Preview を外す手順は出さない)
        let sys4 = sys((3, vec![header_line(s)]), (1, vec![sync]));
        let (o, _, _) = run("herdr", &sys4, APPLY);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(!o[0].notes.iter().any(|n| n.contains("Preview")));
    }

    #[test]
    fn failures() {
        let s = spec("openssh");
        // 見出しが無い
        let sys1 = sys((1, vec!["何か".into()]), (0, vec![]));
        let (o, _, _) = run("openssh", &sys1, Mode::Check);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(o[0].text.contains("状態の表が出ていない"));
        assert!(o[0].notes[0].contains("Install-OpenSSH -Check"));
        // 時間切れ (-Check)
        let sys2 = sys((-1, vec![]), (0, vec![]));
        let (o, _, _) = run("openssh", &sys2, Mode::Check);
        assert!(o[0].text.contains("120 秒たっても終わらなかった"));
        // 時間切れ (入れる)。UAC の見込みを添える
        let sys3 = sys((3, vec![header_line(s)]), (-1, vec![]));
        let (o, _, _) = run("openssh", &sys3, APPLY);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("UAC の確認が残っていれば"))
        );
        // PowerShell が無い
        let none = FakeSys::new(|_| unreachable!());
        let (o, _, _) = run("openssh", &none, Mode::Check);
        assert!(o[0].text.contains("PowerShell が見つからない"));
    }

    #[test]
    fn missing_script_fails() {
        let sys1 = sys((0, vec![]), (0, vec![]));
        let mut out = Vec::new();
        let mut ctx = Ctx {
            repo: PathBuf::from("/no/such/repo"),
            roots: Roots::from_home(Path::new("/h")),
            state_dir: PathBuf::from("/s"),
            host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
            sys: &sys1,
            out: &mut out,
        };
        let o = Ps1Step(spec("ntn")).run(&mut ctx, Mode::Check);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(sys1.calls.borrow().is_empty());
    }

    #[test]
    fn builds_powershell_command() {
        let c = powershell_command(
            PathBuf::from("pwsh"),
            "C:\\Users\\o'neil\\Install-Ntn.ps1",
            " -Check",
            Duration::from_secs(5),
        );
        assert_eq!(
            c.args_lossy(),
            vec![
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $global:LASTEXITCODE = 2; & 'C:\\Users\\o''neil\\Install-Ntn.ps1' -Check; exit $LASTEXITCODE",
            ]
        );
        assert_eq!(c.timeout, Some(Duration::from_secs(5)));
    }

    #[test]
    fn falls_back_to_windows_powershell() {
        let s = spec("ntn");
        let line = header_line(s);
        let fake = FakeSys::new(move |_| RunResult {
            exit: Exit::Code(0),
            output: vec![line.clone()],
        })
        .with_program("powershell", "C:/Windows/powershell.exe");
        let (o, _, _) = run("ntn", &fake, Mode::Check);
        assert_eq!(o[0].kind, Kind::Ok);
        assert_eq!(
            fake.calls.borrow()[0].program,
            PathBuf::from("C:/Windows/powershell.exe")
        );
    }

    /// 待つ秒数が WSL の wrapper (nix/scripts/bootstrap-windows-<id>.sh の timeout) と同じ
    #[test]
    fn timeouts_match_wsl_wrappers() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        for s in SPECS {
            let script = repo
                .join("nix")
                .join("scripts")
                .join(format!("bootstrap-windows-{}.sh", s.id));
            let text = std::fs::read_to_string(&script).unwrap();
            // apply_timeout=1800 のような、数を入れる変数
            let vars: std::collections::BTreeMap<&str, u64> = text
                .lines()
                .filter_map(|l| {
                    let (k, v) = l.trim().split_once('=')?;
                    if k.chars().all(|c| c.is_ascii_lowercase() || c == '_') {
                        Some((k, v.parse().ok()?))
                    } else {
                        None
                    }
                })
                .collect();
            let secs = |line: &str| -> Option<u64> {
                let rest = line.split("timeout ").nth(1)?;
                let tok = rest.split_whitespace().next()?.trim_matches('"');
                match tok.strip_prefix("${").and_then(|t| t.strip_suffix('}')) {
                    Some(var) => vars.get(var).copied(),
                    None => tok.parse().ok(),
                }
            };
            let timed = |l: &&str| l.contains("timeout ") && l.contains("pwsh.exe");
            let checks: Vec<u64> = text
                .lines()
                .filter(timed)
                .filter(|l| l.contains("pwsh_command \" -Check\""))
                .filter_map(secs)
                .collect();
            let acts: Vec<u64> = text
                .lines()
                .filter(timed)
                .filter(|l| {
                    l.contains("pwsh_command \" -IfMissing\"") || l.contains("pwsh_command \"\")")
                })
                .filter_map(secs)
                .collect();
            assert_eq!(checks, vec![s.check_secs], "{} の -Check", s.id);
            assert!(!acts.is_empty(), "{} の入れる・揃える", s.id);
            for a in acts {
                assert_eq!(a, s.install_secs, "{} の入れる・揃える", s.id);
            }
        }
    }

    #[test]
    fn google_ime_picks_fix_by_output() {
        let s = spec("google-ime-install");
        for (line, want) in [
            (
                "⚠ 固定した版 : 3.35 → 入っている版の方が新しい (下げない)",
                "下げはしない",
            ),
            ("⚠ 入っている版 : 比べられない", "入っている版が読めない"),
            (
                "⚠ 固定した版 : 3.35 → 上げる",
                "Install-GoogleJapaneseInput を打つ",
            ),
        ] {
            let sys1 = sys((1, vec![header_line(s), line.to_string()]), (0, vec![]));
            let (o, _, _) = run("google-ime-install", &sys1, APPLY);
            assert_eq!(o[0].kind, Kind::Manual);
            assert_eq!(o[0].notes.len(), 1, "{line}");
            assert!(o[0].notes[0].contains(want), "{line}: {:?}", o[0].notes);
        }
        let blocked = sys(
            (
                3,
                vec![
                    header_line(s),
                    "⚠ 固定した版 : 3.35 → winget show --versions に無い".into(),
                ],
            ),
            (0, vec![]),
        );
        let (o, _, _) = run("google-ime-install", &blocked, APPLY);
        assert!(o[0].notes[0].contains("winget show --id Google.JapaneseIME --versions"));
    }

    #[test]
    fn claude_code_waits_like_wsl_when_syncing() {
        let s = spec("claude-code");
        let drift = (
            1,
            vec![
                header_line(s),
                "⚠️ 固定した版と揃っていない → Install-ClaudeCode で揃える ⚠️".into(),
            ],
        );
        let sys1 = sys(drift, (0, vec![]));
        let _ = run("claude-code", &sys1, APPLY);
        let calls = sys1.calls.borrow();
        assert_eq!(calls[0].timeout, Some(Duration::from_secs(120)));
        assert_eq!(calls[1].timeout, Some(Duration::from_secs(1800)));
    }

    #[test]
    fn quotes_powershell_single_quotes_and_lookalikes() {
        assert_eq!(ps_quote("a'b"), "a''b");
        assert_eq!(
            ps_quote("o\u{2019}neil\u{2018}x"),
            "o\u{2019}\u{2019}neil\u{2018}\u{2018}x"
        );
        assert_eq!(ps_quote("C:\\Users\\a b"), "C:\\Users\\a b");
    }

    /// 本物の PowerShell で、空白と ' を含むパスの ps1 を呼び、UTF-8 の ⚠️ と終了コードが届く (Windows の CI)
    #[cfg(windows)]
    #[test]
    fn real_powershell_runs_a_script_with_awkward_path() {
        use crate::process::{RealSys, Sys};
        let t = TempDir::new("pwsh path");
        let dir = t.path().join("a b'c");
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("Install-Test.ps1");
        std::fs::write(
            &script,
            "\u{feff}param([switch]$Check)\nif ($Check) { Write-Output '⚠️ テスト → Install-Test で入れる ⚠️'; exit 3 }\nexit 0\n",
        )
        .unwrap();
        for shell in ["powershell", "pwsh"] {
            let Some(path) = RealSys.which(shell) else {
                continue;
            };
            let spec = powershell_command(
                path,
                &script.to_string_lossy(),
                " -Check",
                Duration::from_secs(60),
            );
            let r = RealSys.run(&spec, &mut |_| {});
            assert_eq!(r.exit, Exit::Code(3), "{shell}: {:?}", r.output);
            assert!(
                r.output
                    .iter()
                    .any(|l| l == "⚠️ テスト → Install-Test で入れる ⚠️"),
                "{shell}: {:?}",
                r.output
            );
        }
    }
}
