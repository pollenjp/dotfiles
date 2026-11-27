//! `win/*/Install-*.ps1` を `-Check` してから入れる・揃える手順 (order 95〜97)。WSL の `nix/scripts/bootstrap-windows-<id>.sh` を写したもの。
//!
//! clone の中の ps1 を、PATH の pwsh (無ければ Windows PowerShell) の `-Command` で呼ぶ。出力は UTF-8 にしてから流し (捕まえると
//! PowerShell は端末の code page で書くため)、`$LASTEXITCODE` を 2 にしておく (ps1 が exit まで届かずに終わったとき、中の winget の 0 を
//! 返さないため)。どちらも WSL の wrapper の `pwsh_command` と同じ。
//!
//! 判断は手順ごとに WSL の wrapper と同じ (`SPECS` の表。dotfiles-private の docs/adr/060_win_runner_core_* の spec §6):
//!
//! - 0: 揃っている
//! - 3 (入っていない): `-IfMissing` で入れる (google-ime-install・tailscale は、固定した版が winget に無ければ打たずに知らせる。sshd は
//!   入れられないとき (OpenSSH が無いなど) は ps1 が 1 を返す。op-reason は ps1 が `-IfMissing` を持たないので引数なし)
//! - 1 (揃っていない): 手順の `Policy` で、揃える (引数なし・`-IfMissing`)・知らせるだけ (※ の手順)。op-reason は締めの行を見ずに引数なしで
//!   入れ替える (動いている op-reason.exe があれば、ps1 が何も変えずに止まる)。claude-desktop は Policy より先に、ps1 も runner も直さない
//!   もの (`leftover`) の印を見て、締めの行が人の切り替える設定 (`alerts`) だけなら揃っている扱いにする (設定の行は後ろに足す)
//! - 出力に状態の表の見出しが無い・ほかの終了コード: ps1 が動いていない (確かめられなかった)
//!
//! sshd は、受け持ちが runner のホストでは ps1 を流す前に鍵の写し (`sshd_keys`。WSL の wrapper が写しを置くのと同じ段) と、ユーザーと送り元の
//! 写し (`sshd_allow`。ホストの値の `[sshd] allowUsers`・`allowFrom`) を置く。
//!
//! Windows にしか無い手順 (t3-code・claude-desktop・ghq・fzf・starship・codex。`windows_only`) は WSL の wrapper を持たないので、判断は同じ型の Policy で
//! 決め、ps1 の締めの行の文言と出力の印は試験が ps1 の字と突き合わせる。
//!
//! ps1 の締めの行の文言 (「→ Install-Ntn で揃える」など) を変えるときは、ここも直す (WSL の wrapper と同じ約束)。

use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::host::HostValues;
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

/// 1 (揃っていない) のときの扱い (`Replace` は、3 (入っていない) のときに `-IfMissing` を付けないことも決める)。
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
    /// 締めの行を見ずに引数なしで揃え、3 (入っていない) も引数なしで入れる (op-reason。ps1 は `-IfMissing` を持たない。WSL の wrapper は
    /// 状態の表の見出しがあれば 1 も 3 も引数なしで流す。動いている op-reason.exe があれば ps1 が何も変えずに止まる)
    Replace,
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
    /// `-SshRelay` に、ホストの値の SSH の中継 (道具の switch opReasonSshRelay と `[opReason] sshRelayMode`) のモードを渡す。off なら
    /// `off` (残った task を止めて消す)。-Check にも揃える流れにも渡す (op-reason。WSL の script は渡さない)
    pub ssh_relay: bool,
    /// sshd の鍵の写し (`sshd_keys`) とユーザーと送り元の写し (`sshd_allow`) を、ps1 を流す前に揃え (受け持ちが runner のホストだけ)、
    /// `-KeysFrom` に受け持ち (runner・wsl) を渡す (Install-Sshd.ps1 が鍵とユーザー・送り元の直し方を、TOML の値と dotfiles apply か、Nix の値と
    /// WSL の setup で案内する)。sshd だけ
    pub sshd_keys: bool,
    /// 1Password の SSH agent の鍵を確かめる手順か (openssh)。道具の switch `onePassword` が off のホストでは、ps1 に `-NoOnePassword` を渡し
    /// (-Check にも入れる・揃える流れにも。ps1 は `ssh-add -l` の行と 1Password の案内を出さない)、手で打つ直し方のコマンドにも添える。入れた後に
    /// 添える 1Password の行 ([`ONE_PASSWORD_INSTALLED`]) は、on のホストでだけ出す
    pub one_password: bool,
    /// 3 でも、出力にこれがあれば入れられないので打たない (google-ime-install の「固定した版が winget に無い」)
    pub missing_blocked: Option<&'static str>,
    /// 出力の印ごとの直し方 (上から見て最初に当たったもの)。当たれば `manual_fix`・`sync_fix` の代わりに出す (google-ime-install の
    /// 「下げない」「winget に無い」「比べられない」。揃えるコマンドを打っても直らないとき)
    pub output_fixes: &'static [(&'static str, &'static str)],
    /// 入れる前に出す 1 行 (WSL の wrapper の字にするとき。無ければ「Windows に <package> が入っていないので、固定した版を入れます
    /// (<ps1><引数>。<秒> 秒まで待ちます)。」)
    pub install_notice: Option<&'static str>,
    /// 揃える前に出す 1 行 (同じく。無ければ「<subject> が固定した版と揃っていないので、揃えます (<ps1><引数>。<秒> 秒まで待ちます)。」)
    pub sync_notice: Option<&'static str>,
    /// `-Check` が時間切れのときに添える見込み (無ければ「winget の応答が止まっているかもしれない」)
    pub check_hang: Option<&'static str>,
    /// Windows にしか無い手順か (WSL の `bootstrap-windows-<id>.sh` を持たない。`StepInfo::windows_only`。受け持ちによらず runner が受け持つ)
    pub windows_only: bool,
    /// ps1 も runner も直さず、残っている間は揃わないもの (claude-desktop の旧来の exe の Claude)。ps1 は、それが残っているとき締めの行に
    /// `mark` を書いて 1 を返す (入っていなくても 3 にしない。入れられないので)。check も apply も、その 1 を「固定した版と揃っていない」の
    /// 代わりにこの行にし、何も打たない (人が外すまで知らせる)
    pub leftover: Option<Marked>,
    /// `-Check` の出力にあれば、知らせるだけの行 (·。終了コードに数えない) を足す印 (claude-desktop の仮想マシン プラットフォームが off・
    /// システムトレイとスタートアップ時に実行が読めない)。ps1 が動いて状態の表が出たときだけ見る (check・dry-run・apply のどれでも)
    pub notices: &'static [Marked],
    /// ps1 も runner も直さない、人が切り替える設定 (claude-desktop のシステムトレイ・スタートアップ時に実行が on)。ps1 は当たっているとき、
    /// 締めの行 (⚠️ で始まる行) に `mark` を書き、版が揃っていても 1 を返す。状態の表が出たとき、当たった印ごとに直すことがある行 (⚠。
    /// `Kind::Manual`) を足す (check・dry-run・apply のどれでも。何も打たない)。1 の締めの行がどれもこの印のものなら、版は揃っている扱い
    /// (入れた後の 1 も入った扱い)
    pub alerts: &'static [Marked],
}

/// ps1 の出力の印と、それが当たったときに締めの表へ出す行。
#[derive(Clone, Copy, Debug)]
pub struct Marked {
    /// 出力のどこかの行がこれを含めば当たり
    pub mark: &'static str,
    /// 行の文
    pub text: &'static str,
    /// 行の下に出す ※ の行
    pub notes: &'static [&'static str],
}

impl Marked {
    fn found(&self, lines: &[String]) -> bool {
        lines.iter().any(|l| l.contains(self.mark))
    }

    fn outcome(&self, kind: Kind) -> Outcome {
        self.notes
            .iter()
            .fold(Outcome::new(kind, self.text), |o, n| o.note(*n))
    }
}

/// SSH の中継を渡す手順 (`ssh_relay`。op-reason) で、版は揃っていて中継だけが違うときの ps1 の締めの行と、そのときの字
const RELAY_ONLY_MARK: &str = "⚠️ SSH の中継が揃っていない";
const RELAY_PENDING: &str = "SSH の中継が揃っていない";
const RELAY_NOTICE: &str = "Windows の op-reason の SSH の中継 (op-reason の task) が揃っていないので、揃えます (Install-OpReason.ps1)。";
const RELAY_SYNCED: &str = "Windows の op-reason の SSH の中継を揃えました。";

/// Install-Sshd.ps1 の締めの行「鍵の写しに読めない行がある」と、受け持ちが runner のホストでの直し方 (runner は TOML の読めない値を
/// 読む時点で止め、apply は -Check の前に写しを置き直すので、出るのは写しを手で書き換えた後の check)
const SSHD_BAD_KEYS: &str = "鍵の写しに読めない行がある";
const SSHD_BAD_KEYS_RUNNER: &str = "鍵の写し (%LOCALAPPDATA%\\dotfiles\\sshd\\authorized_keys) を手で書き換えていれば、dotfiles apply でホストの値 (dotfiles-private の win/hosts/<ユーザー>@<PC>.toml) の [sshd] authorizedKeys どおりに置き直す";

const UAC_LEFT: &str = "Windows のデスクトップに UAC の確認が残っていれば、先に押すか閉じてから流し直す (残ったまま流し直すと、別のインストールが進行中 (1618) で落ちる)";

/// 1Password の鍵を確かめる手順 (`one_password`) で、入れた後に 1Password を使うホスト (道具の switch onePassword が on) にだけ添える行
/// (WSL の bootstrap-windows-openssh.sh の入れた後の行と同じ字)
pub const ONE_PASSWORD_INSTALLED: &str = "1Password の鍵は、1Password の SSH agent を有効にしてから PowerShell の Install-OpenSSH -Check で確かめる";

/// 1Password を使わないホストで、ps1 に渡す引数と、手で打つ直し方のコマンドに添える字
const NO_ONE_PASSWORD: &str = " -NoOnePassword";

pub const SPECS: &[Ps1Spec] = &[
    Ps1Spec {
        id: "google-ime-install",
        windows_only: false,
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
            "設定を置く手順 (google-ime。受け持ちが WSL の間は WSL の bootstrap-windows-google-ime.sh) が「まだ使われていません」と出したら、Google 日本語入力で一度何か打ってから流し直す",
        ],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-GoogleJapaneseInput を打つ (入れる・上げるときは Windows に UAC の確認が出る。上げる前に、日本語入力を使っているアプリをできるだけ閉じる。runner は上げない: 入れ替えるとアプリや Windows の再起動が要ることがある)",
        ],
        sync_fix: &[
            "入れるには PowerShell で Install-GoogleJapaneseInput を打つか、dotfiles apply --steps google-ime-install を流し直す (Windows に UAC の確認が出る)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
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
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "openssh",
        windows_only: false,
        order: 96,
        title: "OpenSSH を固定した版で入れる (ずれていても揃えない)",
        // Windows には OpenSSH (System32) が初めから入っているので、固定した版に入れ替えるのは使うホストだけ (minimum では off)
        gate: Gate::Tool("windowsOpenssh"),
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
        // 1Password の鍵の確かめ方の行は、1Password を使うホストでだけ後ろに足す (ONE_PASSWORD_INSTALLED)
        installed: &[
            "Windows の OpenSSH を入れました (固定した版。ssh-agent サービスは停止・無効、winget pin あり)。",
        ],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-OpenSSH を打つ (差があれば Windows に UAC が 1 回出る。runner は揃えない: UAC を押すまで止まり、動いている ssh も巻き込むため)",
        ],
        sync_fix: &[
            "入れ直すには PowerShell で Install-OpenSSH -IfMissing を打つ (Windows に UAC が 1 回出る)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: true,
        missing_blocked: None,
        output_fixes: &[],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "sshd",
        windows_only: false,
        order: 96,
        title: "sshd を OpenSSH の MSI に足し、Tailscale と localhost からだけ鍵で入れる形に揃える (ずれていても揃えない)",
        gate: Gate::Tool("windowsSshd"),
        script: "win/openssh/Install-Sshd.ps1",
        command: "Install-Sshd",
        subject: "Windows の sshd",
        package: "sshd (OpenSSH Server。Microsoft.OpenSSH.Preview の MSI の Server の機能)",
        header: Header::Contains("sshd (OpenSSH Server"),
        check_secs: 120,
        install_secs: 600,
        // 揃えるには UAC の確認が要り (外から流すと押す人がいない)、sshd を起こし直すと、つないでいる SSH が切れることがある。
        // runner は WSL の wrapper と同じく、入っていないときだけ入れ、ずれは知らせるだけにする
        policy: Policy::Warn,
        uac: true,
        ok_text: "Windows の sshd は、dotfiles の形 (Tailscale と localhost からだけ、鍵でだけ入れる) に揃っています。",
        // Herdr を開いたままにする案内は ps1 の出力 (上に流れている) に入っている (重ねて出さない)
        installed: &[
            "Windows に sshd を入れて揃えました (Tailscale と localhost からだけ、鍵でだけ入れます)。",
        ],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-Sshd を打つ (Windows に UAC の確認が 1 回出る。sshd を起こし直すと、つないでいる SSH が切れることがある。runner は揃えない)",
        ],
        // 入れかけで止まると ps1 は 1 (ずれ) を返し、-IfMissing は何もしないので、引数なしの Install-Sshd を案内する
        sync_fix: &[
            "揃えるには PowerShell で Install-Sshd を打つ (Windows に UAC の確認が 1 回出る。入れかけで止まったときも、これで続きを揃える)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: true,
        one_password: false,
        missing_blocked: None,
        // 揃える前に人が直すこと (Install-Sshd.ps1 の締めの行の文言)。揃えるコマンドを打っても直らない
        output_fixes: &[
            (
                "OpenSSH が入っていない → 先に Install-OpenSSH",
                "sshd は dotfiles が固定した OpenSSH の MSI に足すので、先に OpenSSH を入れる (ホストの値の [tools] に windowsOpenssh = true を書いて dotfiles apply を流すか、PowerShell で Install-OpenSSH -IfMissing。Windows に UAC の確認が出る)",
            ),
            (
                "Windows の機能の OpenSSH Server が入っている",
                "二重にしないため、先に Windows の機能の OpenSSH Server を外す (管理者の PowerShell で Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0)",
            ),
            (
                "AllowUsers に書けないユーザー名",
                "Windows のユーザー名を AllowUsers に書けないので、このユーザーでは dotfiles の sshd を使えない (英小文字・数字・. _ - の名前のユーザーだけ。win/README.md の「sshd」)",
            ),
            (
                "Windows Firewall が効いていないプロファイルがある",
                "拒否の規則が効かないので揃えない。管理者の PowerShell で Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True を打つ (グループ ポリシーがローカルの規則を止めている PC では、dotfiles の sshd は使えない)",
            ),
            (
                "sshd.exe はあるがサービス sshd が無い",
                "MSI の入り方が崩れている。win/README.md の「sshd を止める・外す」の手順で Server の機能を外してから、PowerShell で Install-Sshd を打つ",
            ),
            // 受け持ちが runner のホストでは SSHD_BAD_KEYS_RUNNER に替える (`fixes`)
            (
                SSHD_BAD_KEYS,
                "鍵の写し (%LOCALAPPDATA%\\dotfiles\\sshd\\authorized_keys) の元、ホストの値の wsl.windowsFiles.sshd.authorizedKeys の、authorized_keys の行として読めない値を直す",
            ),
            // ユーザーと送り元の写しは runner だけが置く (runner は TOML の書けない値を読む時点で止め、apply は -Check の前に写しを置き直すので、
            // 出るのは写しを手で書き換えた後の check)
            (
                "ユーザーと送り元の写しに読めない値がある",
                "ユーザーと送り元の写し (%LOCALAPPDATA%\\dotfiles\\sshd\\allow.json) を手で書き換えていれば、dotfiles apply でホストの値 (dotfiles-private の win/hosts/<ユーザー>@<PC>.toml) の [sshd] allowUsers・allowFrom どおりに置き直す (受け持ちが WSL のホストなら、WSL の setup が消す)",
            ),
        ],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "tailscale",
        windows_only: false,
        order: 96,
        title: "Tailscale を固定した版で入れる (ずれていても上げない)",
        gate: Gate::Tool("windowsTailscale"),
        script: "win/tailscale/Install-Tailscale.ps1",
        command: "Install-Tailscale",
        subject: "Windows の Tailscale",
        package: "Tailscale (winget の Tailscale.Tailscale)",
        header: Header::Contains("Tailscale (winget の Tailscale.Tailscale"),
        check_secs: 120,
        install_secs: 600,
        // 入っている版の方が新しいとき (Tailscale の自動更新で上がった) は ps1 が 0 を返す。1 は古い・pin が無い・版が読めない
        policy: Policy::Warn,
        uac: true,
        ok_text: "Windows の Tailscale は、dotfiles で固定した版以上で入っています。",
        // tailnet へのログインは手でする、の案内は ps1 の出力 (上に流れている) に入っている (重ねて出さない)
        installed: &["Windows に Tailscale を入れました。"],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-Tailscale を打つ (上げるときは Windows に UAC の確認が出て、上げる間 Tailscale の接続が少しの間切れる。pin を足すだけなら UAC は出ない。runner は上げない: Tailscale の自動更新を有効にしてあれば、自分で上がる)",
        ],
        sync_fix: &[
            "入れるには PowerShell で Install-Tailscale を打つか、dotfiles apply --steps tailscale を流し直す (Windows に UAC の確認が出る)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: Some("winget show --versions に無い"),
        output_fixes: &[
            (
                "winget show --versions に無い",
                "固定した版が winget に無いので、入れることも上げることもできない。repo の版 (Install-Tailscale.ps1 の -Version) を winget show --id Tailscale.Tailscale --versions にある版へ変える",
            ),
            (
                "比べられない",
                "入っている版が読めないので、揃えられない。上の ※ のとおり、PowerShell で winget list --id Tailscale.Tailscale を打って入っている版を確かめる",
            ),
        ],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "claude-code",
        windows_only: false,
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
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "herdr-app",
        windows_only: false,
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
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "herdr",
        windows_only: false,
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
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "ntn",
        windows_only: false,
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
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "op-reason",
        windows_only: false,
        // WSL の script と同じ 90 (files の後・ssh-config (91) の前)。SSH の中継を使うホストでは、ここで起こした中継が答えるのを
        // 手順 ssh-config が見てから IdentityAgent を書く
        order: 90,
        title: "WSL の op の Windows の部品 (op-reason の zip) を固定した版に揃える",
        // WSL の script の `# tool: onePassword`。WSL の script は、さらに WSL の op の wrapper を入れるマシン (claude-op-reason.json の enable。
        // wsl.enable と onePassword.enable が両方 true) に絞るが、runner は WSL の記録を読まず、ホストの値の onePassword で決める (Windows の
        // claude-<名前> の op の token も op-reason.exe で読む)
        gate: Gate::Tool("onePassword"),
        script: "win/op-reason/Install-OpReason.ps1",
        command: "Install-OpReason",
        subject: "Windows の op-reason",
        package: "op-reason (GitHub の Release)",
        header: Header::Contains("op-reason (GitHub の Release"),
        // -Check はネットワークを使わない。落とすのは 500 KB ほどの zip 1 つ (中の Invoke-WebRequest は 120 秒で切る)
        check_secs: 60,
        install_secs: 300,
        // WSL の op の実行ファイルは switch で上がり、呼び出しの取り決め (payload の版) が変わった版どうしでは断られるので、版のずれも
        // 入れ替える (type-clipboard と違う)。op-reason.exe は op の呼び出しの間しか動かない
        policy: Policy::Replace,
        uac: false,
        // 前に出す行・揃ったときの行・揃っているときの行は WSL の bootstrap-windows-op-reason.sh と同じ字 (op_reason_parity が突き合わせる)
        ok_text: "Windows の op-reason は、dotfiles で固定した版に揃っています。",
        installed: &[
            "Windows に op-reason を入れました (%LOCALAPPDATA%\\Programs\\op-reason。WSL の op が OPREASON_EXE で使う)。",
        ],
        synced: &["Windows の op-reason を、dotfiles で固定した版に揃えました。"],
        manual_fix: &[],
        sync_fix: &[
            "揃えるには PowerShell で Install-OpReason を打つか、dotfiles apply --steps op-reason を流し直す (op-reason.exe が動いているときは、op の呼び出しが終わってから)",
        ],
        releases_file: false,
        ssh_relay: true,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[],
        install_notice: Some(
            "Windows に op-reason が入っていないので、GitHub の Release から固定した版を入れます (Install-OpReason.ps1)。",
        ),
        sync_notice: Some(
            "Windows の op-reason が dotfiles で固定した版と揃っていないので、入れ替えます (Install-OpReason.ps1)。",
        ),
        check_hang: Some("-Check はネットワークを使わないので、pwsh が止まっているかもしれない"),
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    Ps1Spec {
        id: "type-clipboard",
        windows_only: false,
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
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    // T3 Code (Windows にしか無い手順。WSL の setup には無い。dotfiles-private の docs/adr/091_t3_code_opt_in_*)。テレメトリの環境変数と
    // settings.json は t3-code-settings が合わせる
    Ps1Spec {
        id: "t3-code",
        windows_only: true,
        order: 97,
        title: "T3 Code を固定した版で入れる (ずれていても上げない)",
        gate: Gate::Tool("windowsT3Code"),
        script: "win/t3-code/Install-T3Code.ps1",
        command: "Install-T3Code",
        subject: "Windows の T3 Code",
        package: "T3 Code (winget の T3Tools.T3Code)",
        header: Header::Contains("T3 Code (winget の T3Tools.T3Code"),
        check_secs: 120,
        install_secs: 600,
        // 入っている版の方が新しいとき (T3 Code の自動更新で上がった) は ps1 が 0 を返す。1 は古い・pin が無い・版が読めない
        policy: Policy::Warn,
        // user スコープの nullsoft の installer で、UAC の確認は出ない
        uac: false,
        ok_text: "Windows の T3 Code は、dotfiles で固定した版以上で入っています。",
        // サインインとログインは手でする、の案内は ps1 の出力 (上に流れている) に入っている (重ねて出さない)
        installed: &["Windows に T3 Code を入れました。"],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-T3Code を打つ (上げるときは先に T3 Code を閉じる。pin を足すだけなら閉じなくてよい。runner は上げない: T3 Code は自動更新で自分で上がる)",
        ],
        sync_fix: &[
            "入れるには PowerShell で Install-T3Code を打つか、dotfiles apply --steps t3-code を流し直す",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: Some("winget show --versions に無い"),
        output_fixes: &[
            (
                "winget show --versions に無い",
                "固定した版が winget に無いので、入れることも上げることもできない。repo の版 (Install-T3Code.ps1 の -Version と nix/pkgs/t3-code の version) を winget show --id T3Tools.T3Code --versions にある版へ変える",
            ),
            (
                "比べられない",
                "入っている版が読めないので、揃えられない。上の ※ のとおり、PowerShell で winget list --id T3Tools.T3Code を打って入っている版を確かめる",
            ),
        ],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    // Claude Desktop (Windows にしか無い手順。WSL の setup には無い)。winget の Anthropic.Claude の MSIX を、昇格した Windows PowerShell の winget で
    // 入れる (Cowork の常駐 CoworkVMService は管理者の権限で入れたときだけ登録される。UAC の確認が 1 回出る)。版の扱いは T3 Code と同じ
    // (入っていないときだけ入れ、自動更新で上がった版は下げない)。旧来の exe の Claude が残っていれば、入れずに外し方を (ps1 は入っていなくても
    // 1 を返す)、仮想マシン プラットフォームが off なら Cowork が使えないことを知らせ、Claude の設定のシステムトレイ・スタートアップ時に実行が
    // on なら直すことがある行で off にする手を出す (dotfiles-private の docs/adr/099_win_claude_desktop_msix_*)
    Ps1Spec {
        id: "claude-desktop",
        windows_only: true,
        order: 97,
        title: "Claude Desktop (MSIX) を固定した版で入れる (ずれていても上げない)",
        gate: Gate::Tool("windowsClaudeDesktop"),
        script: "win/claude-desktop/Install-ClaudeDesktop.ps1",
        command: "Install-ClaudeDesktop",
        subject: "Windows の Claude Desktop",
        package: "Claude Desktop (winget の Anthropic.Claude の MSIX)",
        header: Header::Contains("Claude Desktop (winget の Anthropic.Claude"),
        check_secs: 120,
        // MSIX は約 300 MB。UAC の確認を押すまでの間も待つ
        install_secs: 1800,
        // 入っている版の方が新しいとき (Claude Desktop の自動更新で上がった) は ps1 が 0 を返す。1 は古い・pin が無い・版が読めない・旧来の
        // exe の Claude が残っている (入っていなくても)
        policy: Policy::Warn,
        uac: true,
        ok_text: "Windows の Claude Desktop は、dotfiles で固定した版以上で入っています。",
        // サインインは手でする、の案内は ps1 の出力 (上に流れている) に入っている (重ねて出さない)
        installed: &["Windows に Claude Desktop (MSIX) を入れました。"],
        synced: &[],
        manual_fix: &[
            "揃えるには PowerShell で Install-ClaudeDesktop を打つ (上げるときは先に Claude を終え (☰ > File > Exit)、UAC の確認が 1 回出る。pin を足すだけなら UAC は出ない。runner は上げない: Claude Desktop は自動更新で自分で上がる)",
        ],
        sync_fix: &[
            "入れるには PowerShell で Install-ClaudeDesktop を打つか、dotfiles apply --steps claude-desktop を流し直す (Windows のデスクトップに UAC の確認が出る。SSH の会話では出せないので、デスクトップの端末で流す)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: Some("winget show --versions に無い"),
        output_fixes: &[
            (
                "winget show --versions に無い",
                "固定した版が winget に無いので、入れることも上げることもできない。repo の版 (Install-ClaudeDesktop.ps1 の -Version) を winget show --id Anthropic.Claude --versions にある版 (7 日の猶予を過ぎたもの) へ変える",
            ),
            (
                "比べられない",
                "入っている版が読めないので、揃えられない。上の ※ のとおり、PowerShell で Get-AppxPackage -Name Claude を打って入っている版を確かめる",
            ),
            (
                "UAC の確認を断った",
                "UAC の確認で「はい」を押さなかったか、出せなかった (SSH の会話など)。デスクトップの PowerShell で Install-ClaudeDesktop を打つか、dotfiles apply --steps claude-desktop を流し直して「はい」を押す",
            ),
        ],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: Some(Marked {
            mark: "旧来の exe の Claude が残っている",
            text: "旧来の exe の Claude (Squirrel。%LOCALAPPDATA%\\AnthropicClaude) が残っている → ※ の手順で外す (runner は外さない。MSIX が入っていなければ、外した後の dotfiles apply で入れる)",
            notes: &[
                "旧来の exe の Claude を開くと Cowork が無い。外すには、Claude を終えてから (☰ > File > Exit)、管理者でない PowerShell で & \"$env:LOCALAPPDATA\\AnthropicClaude\\Update.exe\" --uninstall -s を打つ",
                "終わったら %LOCALAPPDATA%\\AnthropicClaude と、スタートメニューの %APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Claude.lnk を消す (win/README.md の「Claude Desktop」)",
            ],
        }),
        notices: &[
            Marked {
                mark: "仮想マシン プラットフォーム (VirtualMachinePlatform) が off",
                text: "仮想マシン プラットフォーム (VirtualMachinePlatform) が off なので、Cowork は使えない (runner は on にしない)",
                notes: &[
                    "on にするには、管理者の PowerShell で Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All を打ち、Windows を再起動する (シャットダウンでなく再起動。win/README.md の「Claude Desktop」)",
                ],
            },
            // 下の 2 つの設定が読めない (書いている途中など。⚠ にはしないが、締めの表で無事に見えないように知らせる)
            Marked {
                mark: "システムトレイの設定 (claude_desktop_config.json の preferences.menuBarEnabled) が読めない",
                text: "Claude Desktop のシステムトレイの設定が読めない (claude_desktop_config.json の preferences.menuBarEnabled)",
                notes: &[
                    "Claude の設定 > デスクトップアプリ で確かめる (on なら off にする。runner は書き換えない)",
                ],
            },
            Marked {
                mark: "スタートアップ時に実行の状態 (startup task ClaudeStartup の State) が読めない",
                text: "Claude Desktop のスタートアップ時に実行の状態が読めない (startup task ClaudeStartup の State)",
                notes: &[
                    "Claude の設定 > デスクトップアプリ で確かめる (on なら off にする。runner は書き換えない)",
                ],
            },
        ],
        // Claude の設定 > デスクトップアプリ の 2 つの切り替え。runner は書き換えない (システムトレイの値は、開いている Claude が自分で書き直す
        // ファイルにある)
        alerts: &[
            Marked {
                mark: "Claude Desktop のシステムトレイが on",
                text: "Claude Desktop のシステムトレイが on → Claude の設定 > デスクトップアプリ の「システムトレイ」を off にする (runner は設定を書き換えない)",
                notes: &[
                    "窓を閉じても Claude は終わらずにトレイで動き続ける。開いていないときにリモートから操作されないよう、off にしておく (win/README.md の「Claude Desktop」)",
                ],
            },
            Marked {
                mark: "Claude Desktop のスタートアップ時に実行が on",
                text: "Claude Desktop のスタートアップ時に実行が on → Claude の設定 > デスクトップアプリ の「スタートアップ時に実行」を off にする (runner は設定を書き換えない)",
                notes: &[
                    "Windows にサインインしたときに Claude が起きる (win/README.md の「Claude Desktop」)",
                ],
            },
        ],
    },
    // ghq と fzf (Windows にしか無い手順。WSL の setup には無い。dotfiles.ps1 の cdrepo が使う。dotfiles-private の
    // docs/adr/092_win_cdrepo_ghq_fzf_*)。どちらも minimum の基本の道具の CLI で、Linux はどのグループでも入れるので、いつも on。ntn と同じく
    // 常駐も UAC も無いので、版のずれも揃える (Policy::Sync)
    Ps1Spec {
        id: "ghq",
        windows_only: true,
        order: 97,
        title: "ghq (cdrepo が使う) を固定した版に揃える",
        gate: Gate::Always,
        script: "win/ghq/Install-Ghq.ps1",
        command: "Install-Ghq",
        subject: "Windows の ghq",
        package: "ghq (winget の x-motemen.ghq)",
        header: Header::Contains("ghq (winget の x-motemen.ghq"),
        check_secs: 120,
        install_secs: 600,
        policy: Policy::Sync,
        uac: false,
        ok_text: "Windows の ghq は、dotfiles で固定した版に揃っています。",
        installed: &["Windows の ghq を入れました (固定した版と pin が揃っています)。"],
        synced: &["Windows の ghq を揃えました (固定した版と pin が揃っています)。"],
        manual_fix: &[
            "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「ghq・fzf」)",
        ],
        sync_fix: &[
            "揃えるには PowerShell で Install-Ghq を打つか、dotfiles apply --steps ghq を流し直す (入れ替えるときは、動いている ghq を先に終わらせる)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    // fzf は winget の既定の installer (machine スコープの MSI) を避けて portable を入れる。MSI の fzf が入っていれば、ps1 は portable を
    // 入れずに 1 を返し、締めの行は「→ ※ の手順で直す」だけになる (PATH のずれと同じく知らせるだけ)。その行の印で外し方を出す
    Ps1Spec {
        id: "fzf",
        windows_only: true,
        order: 97,
        title: "fzf (cdrepo が使う) を固定した版 (portable) に揃える",
        gate: Gate::Always,
        script: "win/fzf/Install-Fzf.ps1",
        command: "Install-Fzf",
        subject: "Windows の fzf",
        package: "fzf (winget の junegunn.fzf)",
        header: Header::Contains("fzf (winget の junegunn.fzf"),
        check_secs: 120,
        install_secs: 600,
        policy: Policy::Sync,
        uac: false,
        ok_text: "Windows の fzf は、dotfiles で固定した版に揃っています。",
        installed: &["Windows の fzf を入れました (固定した版と pin が揃っています)。"],
        synced: &["Windows の fzf を揃えました (固定した版と pin が揃っています)。"],
        manual_fix: &[
            "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「ghq・fzf」)",
        ],
        sync_fix: &[
            "揃えるには PowerShell で Install-Fzf を打つか、dotfiles apply --steps fzf を流し直す (入れ替えるときは、動いている fzf を先に終わらせる)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[(
            "MSI の fzf (machine スコープ) が入っている",
            "MSI の fzf (winget の既定の installer) が入っているので、portable を入れない。PowerShell で winget uninstall --id junegunn.fzf --exact --scope machine を打って外し (UAC の確認が出る)、dotfiles apply --steps fzf を流し直す (win/README.md の「ghq・fzf」)",
        )],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    // starship (プロンプト。Windows にしか無い手順。WSL の setup には無い。$PROFILE の init の 1 行は手順 starship-init が足す)。minimum の基本の
    // 道具で、Linux はどのグループでも home-manager が入れるので、いつも on。fzf と同じく winget の既定の installer (machine スコープの MSI) を
    // 避けて portable を入れ、版のずれも揃える (Policy::Sync)。MSI の starship が入っていれば、ps1 は portable を入れずに 1 を返し、締めの行は
    // 「→ ※ の手順で直す」だけになる。その行の印で外し方を出す
    Ps1Spec {
        id: "starship",
        windows_only: true,
        order: 97,
        title: "starship (プロンプト) を固定した版 (portable) に揃える",
        gate: Gate::Always,
        script: "win/starship/Install-Starship.ps1",
        command: "Install-Starship",
        subject: "Windows の starship",
        package: "starship (winget の Starship.Starship)",
        header: Header::Contains("starship (winget の Starship.Starship"),
        check_secs: 120,
        install_secs: 600,
        policy: Policy::Sync,
        uac: false,
        ok_text: "Windows の starship は、dotfiles で固定した版に揃っています。",
        installed: &[
            "Windows の starship を入れました (固定した版と pin が揃っています)。新しい PowerShell から starship のプロンプトになります (herdr-app の中の端末なら herdr-app を上げ直してから)。",
        ],
        synced: &["Windows の starship を揃えました (固定した版と pin が揃っています)。"],
        manual_fix: &[
            "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「starship」)",
        ],
        sync_fix: &[
            "揃えるには PowerShell で Install-Starship を打つか、dotfiles apply --steps starship を流し直す (入れ替えるときは、動いている starship を先に終わらせる)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[(
            "MSI の starship (machine スコープ) が入っている",
            "MSI の starship (winget の既定の installer) が入っているので、portable を入れない。PowerShell で winget uninstall --id Starship.Starship --exact --scope machine を打って外し (UAC の確認が出る)、続けて dotfiles apply --steps starship を流す (win/README.md の「starship」)",
        )],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
    },
    // Codex CLI (OpenAI のコーディング エージェントの CLI。Windows にしか無い手順。WSL の setup には無い)。道具の switch windowsCodex で on/off
    // (minimum では off)。winget の portable を固定した版で入れ、版のずれも揃える (Policy::Sync)。codex と打てるのは winget が WinGet\Links に
    // 置く symlink だけなので、開発者モードが off なら ps1 が winget を UAC で昇格して打ち (UAC の確認が 1 回出る)、symlink の無い形 (手で
    // winget install を打った) は入れ直す。管理者でなく開発者モードも off なら、ps1 は入れずに 1 を返し、締めの行は「→ ※ の手順で直す」だけに
    // なる。その行の印で直し方を出す (dotfiles-private の docs/adr/118_codex_cli_*)
    Ps1Spec {
        id: "codex",
        windows_only: true,
        order: 97,
        title: "Codex CLI を固定した版 (portable) に揃え、codex と打てる symlink を置く",
        gate: Gate::Tool("windowsCodex"),
        script: "win/codex/Install-Codex.ps1",
        command: "Install-Codex",
        subject: "Windows の Codex CLI",
        package: "Codex CLI (winget の OpenAI.Codex)",
        header: Header::Contains("Codex CLI (winget の OpenAI.Codex"),
        check_secs: 120,
        // zip は約 200 MB (展開して約 600 MB)。UAC の確認を押すまでの間も待つ
        install_secs: 1800,
        policy: Policy::Sync,
        // 開発者モードが off の PC では、winget を UAC で昇格して打つ (on なら出ない)
        uac: true,
        ok_text: "Windows の Codex CLI は、dotfiles で固定した版に揃っています。",
        installed: &[
            "Windows に Codex CLI を入れました (固定した版と pin と、codex と打つ WinGet\\Links の symlink が揃っています)。新しい PowerShell から codex と打てます (herdr-app の中の端末なら herdr-app を上げ直してから)。ログインは codex を起こして手でする。",
        ],
        synced: &[
            "Windows の Codex CLI を揃えました (固定した版と pin と、codex と打つ WinGet\\Links の symlink が揃っています)。",
        ],
        manual_fix: &[
            "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「Codex CLI」)",
        ],
        sync_fix: &[
            "揃えるには PowerShell で Install-Codex を打つか、dotfiles apply --steps codex を流し直す (開発者モードが off なら UAC の確認が出る。SSH の会話では出せないので、デスクトップの端末で流す。入れ替えるときは、動いている codex を先に終わらせる)",
        ],
        releases_file: false,
        ssh_relay: false,
        sshd_keys: false,
        one_password: false,
        missing_blocked: None,
        output_fixes: &[(
            "winget が codex の symlink を作れない",
            "このアカウントは管理者でなく、開発者モードも off なので、winget は codex の symlink を作れない (入れても codex と打てない)。管理者に開発者モードを on にしてもらい (設定 > システム > 開発者向け)、dotfiles apply --steps codex を流し直す (win/README.md の「Codex CLI」)",
        )],
        install_notice: None,
        sync_notice: None,
        check_hang: None,
        leftover: None,
        notices: &[],
        alerts: &[],
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
    /// 版は揃っていて、SSH の中継だけが違う (`ssh_relay` の手順の「⚠️ SSH の中継が揃っていない」)
    relay: bool,
}

fn read_verdict(spec: &Ps1Spec, lines: &[String]) -> Verdict {
    let has = |s: &str| lines.iter().any(|l| l.contains(s));
    let mut v = Verdict {
        install: has(&format!("→ {} で入れる", spec.command)),
        sync: has(&format!("→ {} で揃える", spec.command)),
        path: has("→ ※ の手順で直す"),
        preview: has("⚠️ Herdr.Herdr.Preview が残っている"),
        relay: spec.ssh_relay && has(RELAY_ONLY_MARK),
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

/// PowerShell の本文を `-EncodedCommand` に渡す形 (UTF-16LE の base64) にする。複数行で `"` を含む本文 (C# の `DllImport("user32.dll")` など) を、
/// コマンドラインの引用符の扱いに左右されずに渡すため (WSL の fancyzones・international も `-EncodedCommand`)。
pub fn encode_command(script: &str) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk.len();
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let v = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..4 {
            if i <= n {
                out.push(TABLE[((v >> (18 - 6 * i)) & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Windows PowerShell (`powershell`。無ければ pwsh) で PowerShell の本文を流すコマンド (`-NoProfile -NonInteractive -OutputFormat Text
/// -EncodedCommand`。WSL の fancyzones と同じ引数)。`-OutputFormat Text` で pwsh はエラーを平文で出すが、Windows PowerShell 5.1 は
/// `-EncodedCommand` で起こして stderr を写すと、付けてもエラー・警告・進み具合を CLIXML で返す (Windows の CI で確かめた)。人に見せる行は
/// [`plain_lines`] で平文に直す。
pub fn encoded_command(shell: PathBuf, script: &str, timeout: Duration) -> CommandSpec {
    CommandSpec::new(shell)
        .arg("-NoProfile")
        .arg("-NonInteractive")
        .arg("-OutputFormat")
        .arg("Text")
        .arg("-EncodedCommand")
        .arg(encode_command(script))
        .timeout(timeout)
}

/// PowerShell の出力の行のうち、Windows PowerShell 5.1 が stderr に返す CLIXML (`#< CLIXML` の行と、`<Objs …>` で始まる 1 行) を、平文の
/// 行に直す (`-Command` で起こしたときに出る形。WSL の PowerToys の `2>&1` の写しに近づける)。エラーの文はそのまま、警告などは
/// `WARNING: ` のような頭を付ける。進み具合 (`Preparing modules for first use.` など) は落とす (平文でも、写した出力には出ない)。ほかの行は
/// そのまま。
pub fn plain_lines(lines: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for line in lines {
        let t = line.trim_end_matches('\r');
        if t == "#< CLIXML" {
            continue;
        }
        if t.starts_with("<Objs ") && t.contains("schemas.microsoft.com/powershell") {
            let text = clixml_text(t);
            if text.is_empty() {
                continue;
            }
            let text = text.strip_suffix('\n').unwrap_or(&text);
            out.extend(
                text.split('\n')
                    .map(|l| l.trim_end_matches('\r').to_string()),
            );
            continue;
        }
        out.push(line.clone());
    }
    out
}

/// CLIXML の 1 行から、流れ (`<S S="Error">` など) の文をつなげて取り出す。進み具合などの `<Obj>` は飛ばす。
fn clixml_text(xml: &str) -> String {
    let mut text = String::new();
    let mut rest = xml;
    while let Some(i) = rest.find("<S S=\"") {
        rest = &rest[i + "<S S=\"".len()..];
        let Some(q) = rest.find("\">") else { break };
        let stream = &rest[..q];
        rest = &rest[q + 2..];
        let end = rest.find("</S>").unwrap_or(rest.len());
        let mut s = clixml_unescape(&rest[..end]);
        rest = &rest[(end + "</S>".len()).min(rest.len())..];
        if !stream.eq_ignore_ascii_case("error") {
            s = format!("{}: {s}", stream.to_ascii_uppercase());
            if !s.ends_with('\n') {
                s.push('\n');
            }
        }
        text.push_str(&s);
    }
    text
}

/// CLIXML の文を戻す: XML の実体参照 (`&lt;`・`&#10;` など) と、PowerShell の `_xHHHH_` (UTF-16 の 1 単位。改行は `_x000D__x000A_`)。
fn clixml_unescape(s: &str) -> String {
    fn push(c: char, units: &mut Vec<u16>) {
        let mut buf = [0u16; 2];
        units.extend_from_slice(c.encode_utf16(&mut buf));
    }
    let mut units: Vec<u16> = Vec::new();
    let mut rest = s;
    while let Some(c) = rest.chars().next() {
        if c == '&' {
            let entity = rest[1..]
                .find(';')
                .filter(|&end| end <= 10)
                .and_then(|end| {
                    let name = &rest[1..1 + end];
                    let ch = match name {
                        "lt" => Some('<'),
                        "gt" => Some('>'),
                        "amp" => Some('&'),
                        "quot" => Some('"'),
                        "apos" => Some('\''),
                        _ => name
                            .strip_prefix("#x")
                            .or_else(|| name.strip_prefix("#X"))
                            .filter(|h| !h.is_empty() && h.bytes().all(|b| b.is_ascii_hexdigit()))
                            .and_then(|h| u32::from_str_radix(h, 16).ok())
                            .or_else(|| {
                                name.strip_prefix('#')
                                    .filter(|d| {
                                        !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit())
                                    })
                                    .and_then(|d| d.parse::<u32>().ok())
                            })
                            .and_then(char::from_u32),
                    };
                    ch.map(|ch| (ch, end + 2))
                });
            if let Some((ch, len)) = entity {
                push(ch, &mut units);
                rest = &rest[len..];
                continue;
            }
        }
        let b = rest.as_bytes();
        if c == '_'
            && b.get(1) == Some(&b'x')
            && b.get(2..6)
                .is_some_and(|h| h.iter().all(u8::is_ascii_hexdigit))
            && b.get(6) == Some(&b'_')
            && let Ok(u) = u16::from_str_radix(&rest[2..6], 16)
        {
            units.push(u);
            rest = &rest[7..];
            continue;
        }
        push(c, &mut units);
        rest = &rest[c.len_utf8()..];
    }
    String::from_utf16_lossy(&units)
}

/// Windows PowerShell 5.1 (`powershell`)、無ければ pwsh。WSL が `powershell.exe` で流す本文 (PowerToys の停止・起動・イベント、FancyZones の
/// ディスプレイ) を流す口。
pub fn find_windows_powershell(ctx: &Ctx) -> Option<PathBuf> {
    ctx.sys
        .which("powershell")
        .or_else(|| ctx.sys.which("pwsh"))
}

/// 試験で、`-EncodedCommand` の引数を本文に戻す。
#[cfg(test)]
pub fn decode_command(spec: &CommandSpec) -> Option<String> {
    let args = spec.args_lossy();
    let i = args.iter().position(|a| a == "-EncodedCommand")?;
    let text = args.get(i + 1)?;
    let val = |c: u8| -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32)
    };
    let mut bytes = Vec::new();
    for chunk in text.as_bytes().chunks(4) {
        let pad = chunk.iter().filter(|&&c| c == b'=').count();
        let mut v = 0u32;
        for &c in chunk {
            v = (v << 6) | if c == b'=' { 0 } else { val(c)? };
        }
        let three = [(v >> 16) as u8, (v >> 8) as u8, v as u8];
        bytes.extend_from_slice(&three[..3 - pad]);
    }
    let units: Vec<u16> = bytes
        .chunks(2)
        .map(|c| u16::from_le_bytes([c[0], *c.get(1).unwrap_or(&0)]))
        .collect();
    String::from_utf16(&units).ok()
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
        let mut a = base.to_string();
        if self.0.releases_file {
            let rel = ctx.repo_path("nix/pkgs/herdr-core/releases.json");
            a.push_str(&format!(
                " -ReleasesFile '{}'",
                ps_quote(&rel.to_string_lossy())
            ));
        }
        if self.0.ssh_relay {
            a.push_str(&format!(
                " -SshRelay '{}'",
                ctx.host.ssh_relay().unwrap_or("off")
            ));
        }
        if self.0.sshd_keys {
            a.push_str(&format!(" -KeysFrom '{}'", keys_from(ctx)));
        }
        if self.without_one_password(&ctx.host) {
            a.push_str(NO_ONE_PASSWORD);
        }
        a
    }

    /// 1Password の鍵を確かめる手順 (`one_password`) で、このホストが 1Password を使わない (道具の switch onePassword が off) か
    fn without_one_password(&self, host: &HostValues) -> bool {
        self.0.one_password && !host.tool("onePassword")
    }

    /// 直し方: 出力の印 (`output_fixes`) に当たればそれ、無ければ `default`。sshd の鍵の写しの読めない行は、受け持ちが runner の
    /// ホストなら TOML の値と dotfiles apply で直す。1Password を使わないホストの openssh は、手で打つコマンド (`<command> を打つ`・
    /// `<command> -IfMissing を打つ`) に -NoOnePassword を添える
    fn fixes(&self, host: &HostValues, lines: &[String], default: &[&'static str]) -> Vec<String> {
        let found = self
            .0
            .output_fixes
            .iter()
            .find(|(marker, _)| lines.iter().any(|l| l.contains(marker)));
        let picked: Vec<String> = match found {
            Some((marker, _))
                if self.0.sshd_keys && host.runner_enable && *marker == SSHD_BAD_KEYS =>
            {
                vec![SSHD_BAD_KEYS_RUNNER.to_string()]
            }
            Some((_, fix)) => vec![fix.to_string()],
            None => default.iter().map(|n| n.to_string()).collect(),
        };
        if !self.without_one_password(host) {
            return picked;
        }
        let command = self.0.command;
        picked
            .into_iter()
            .map(|n| {
                n.replace(
                    &format!("{command} -IfMissing を打つ"),
                    &format!("{command} -IfMissing{NO_ONE_PASSWORD} を打つ"),
                )
                .replace(
                    &format!("{command} を打つ"),
                    &format!("{command}{NO_ONE_PASSWORD} を打つ"),
                )
            })
            .collect()
    }

    /// 締めの行 (⚠️ で始まる行) があり、どれも人が切り替える設定 (`alerts`) の印のものか (1 のわけが、それだけ)
    fn alerts_only(&self, lines: &[String]) -> bool {
        let mut verdicts = lines.iter().filter(|l| l.starts_with("⚠️")).peekable();
        verdicts.peek().is_some()
            && verdicts.all(|l| self.0.alerts.iter().any(|m| l.contains(m.mark)))
    }

    /// 出力に当たった、人が切り替える設定 (`alerts`) の印ごとの直すことがある行 (⚠)
    fn alert_outcomes(&self, lines: &[String]) -> Vec<Outcome> {
        self.0
            .alerts
            .iter()
            .filter(|m| m.found(lines))
            .map(|m| m.outcome(Kind::Manual))
            .collect()
    }

    /// 手で打つ -Check (SSH の中継を渡す手順で中継が on なら、そのモードも添える。sshd は受け持ちが runner なら -KeysFrom runner も)
    fn manual_command(&self, ctx: &Ctx) -> String {
        let mut relay = match ctx.host.ssh_relay() {
            Some(m) if self.0.ssh_relay => format!(" -SshRelay {m}"),
            _ => String::new(),
        };
        if self.0.sshd_keys && ctx.host.runner_enable {
            relay.push_str(" -KeysFrom runner");
        }
        format!(
            "PowerShell で {} -Check{relay} を打つと、同じことを確かめられる",
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
            // ps1 も runner も直さないもの (claude-desktop の旧来の exe の Claude) が残っている。手順の Policy によらず、その行を出す
            (Some(1), true) if s.leftover.is_some_and(|m| m.found(lines)) => Plan::Leftover,
            // 1 のわけが、人が切り替える設定 (claude-desktop のシステムトレイ・スタートアップ時に実行) だけ。版は揃っている (設定の行は
            // run_ps1 が後ろに足す)
            (Some(1), true) if self.alerts_only(lines) => Plan::Ok,
            (Some(1), true) => match s.policy {
                Policy::Warn => Plan::Warn,
                Policy::Herdr => Plan::HerdrWarn,
                Policy::IfMissing => Plan::SyncIfMissing,
                Policy::Replace => Plan::Sync,
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
    /// 入れる (`-IfMissing`。op-reason は引数なし)
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
    /// ps1 も runner も直さないもの (`Ps1Spec::leftover`) が残っている (知らせるだけ)
    Leftover,
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
            windows_only: self.0.windows_only,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        // sshd: ps1 を流す前に鍵の写しとユーザーと送り元の写しを揃える (PowerShell が無いときも。WSL の wrapper と同じ)。-Check は写しの今の
        // 中身で確かめる
        let mut out = if self.0.sshd_keys {
            let mut o = super::sshd_keys::sync(ctx, mode);
            o.extend(super::sshd_allow::sync(ctx, mode));
            o
        } else {
            Vec::new()
        };
        out.extend(self.run_ps1(ctx, mode));
        out
    }
}

/// sshd の鍵の写しをどの受け持ちが置くか (Install-Sshd.ps1 の -KeysFrom)
fn keys_from(ctx: &Ctx) -> &'static str {
    if ctx.host.runner_enable {
        "runner"
    } else {
        "wsl"
    }
}

impl Ps1Step {
    fn run_ps1(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
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
                    .note(self.manual_command(ctx)),
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
                        "{} -Check が {} 秒たっても終わらなかった (時間切れ。{})",
                        self.script_name(),
                        s.check_secs,
                        s.check_hang
                            .unwrap_or("winget の応答が止まっているかもしれない")
                    ),
                )
                .note(self.manual_command(ctx)),
            ];
        }
        let plan = self.plan(r.code(), header, v, &r.output);
        let name = self.script_name();
        let mut out = match plan {
            Plan::Ok => {
                ctx.say(s.ok_text);
                vec![Outcome::new(Kind::Ok, "揃っている")]
            }
            Plan::Leftover => s
                .leftover
                .map_or_else(Vec::new, |m| vec![m.outcome(Kind::Manual)]),
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
                    .note(self.manual_command(ctx)),
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
                    &ctx.host,
                    &r.output,
                    &["上の出力の ⚠️ の行の手順で -Version を winget にある版へ変える"],
                ) {
                    o = o.note(n);
                }
                vec![o]
            }
            Plan::Warn | Plan::HerdrWarn | Plan::PathOnly => {
                self.warn(&ctx.host, plan, v, &r.output)
            }
            Plan::Install | Plan::Sync | Plan::SyncIfMissing => {
                let (args, label) = match plan {
                    // Install-OpReason.ps1 は -IfMissing を持たない (引数なしで入れる)
                    Plan::Install if s.policy == Policy::Replace => ("", "入れる"),
                    Plan::Install => (" -IfMissing", "入れる"),
                    Plan::Sync => ("", "揃える"),
                    _ => (" -IfMissing", "揃える"),
                };
                let shown = format!("{name}{args}");
                // 版は揃っていて SSH の中継だけが違う (入れ替えずに task と中継を揃える)
                let relay_only = plan == Plan::Sync && v.relay;
                match mode {
                    Mode::Check => vec![self.pending_outcome(plan, relay_only, &shown)],
                    Mode::DryRun { .. } => {
                        ctx.say(format!("[dry-run] {shown} を流す ({label})"));
                        vec![self.pending_outcome(plan, relay_only, &shown)]
                    }
                    Mode::Apply { .. } => self.act(ctx, shell, &script_str, plan, relay_only, args),
                }
            }
        };
        // 人が切り替える設定 (claude-desktop のシステムトレイ・スタートアップ時に実行が on) と、知らせるだけの印 (仮想マシン プラットフォームが
        // off)。ps1 が動いて状態の表が出たときだけ。入れた・揃えたときの設定の行は、打った後の出力から act が足す
        if header && plan != Plan::CheckFailed {
            let acted = matches!(mode, Mode::Apply { .. })
                && matches!(plan, Plan::Install | Plan::Sync | Plan::SyncIfMissing);
            if !acted {
                out.extend(self.alert_outcomes(&r.output));
            }
            out.extend(
                s.notices
                    .iter()
                    .filter(|m| m.found(&r.output))
                    .map(|m| m.outcome(Kind::Info)),
            );
        }
        out
    }
}

impl Ps1Step {
    /// apply の前の行 (check・dry-run)
    fn pending_outcome(&self, plan: Plan, relay_only: bool, shown: &str) -> Outcome {
        match plan {
            Plan::Install => Outcome::new(
                Kind::Missing,
                format!("入っていない → apply で入れる ({shown})"),
            ),
            _ if relay_only => Outcome::new(
                Kind::Fix,
                format!("{RELAY_PENDING} → apply で揃える ({shown})"),
            ),
            _ => Outcome::new(
                Kind::Fix,
                format!("固定した版と揃っていない → apply で揃える ({shown})"),
            ),
        }
    }

    /// 知らせるだけの行
    fn warn(&self, host: &HostValues, plan: Plan, v: Verdict, lines: &[String]) -> Vec<Outcome> {
        let s = self.0;
        match plan {
            Plan::PathOnly => {
                // 出力の印 (fzf の「MSI の fzf (machine スコープ) が入っている」) に当たれば、その印を見出しにして直し方を出す。
                // 無ければ PATH のずれの見出しと manual_fix
                let text = match s
                    .output_fixes
                    .iter()
                    .find(|(m, _)| lines.iter().any(|l| l.contains(m)))
                {
                    Some((marker, _)) => format!(
                        "{marker} ({} -Check の ※ の行。runner は直さない)",
                        s.command
                    ),
                    None => format!(
                        "PATH で引かれるものが winget のものではない ({} -Check の ※ の行)",
                        s.command
                    ),
                };
                let mut o = Outcome::new(Kind::Manual, text);
                for n in self.fixes(host, lines, s.manual_fix) {
                    o = o.note(n);
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
                for n in self.fixes(host, lines, s.manual_fix) {
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
        relay_only: bool,
        args: &str,
    ) -> Vec<Outcome> {
        let s = self.0;
        let name = self.script_name();
        let installing = plan == Plan::Install;
        match (installing, s.install_notice, s.sync_notice) {
            _ if relay_only => ctx.say(RELAY_NOTICE),
            (true, Some(n), _) | (false, _, Some(n)) => ctx.say(n),
            (true, None, _) => ctx.say(format!(
                "Windows に {} が入っていないので、固定した版を入れます ({name}{args}。{} 秒まで待ちます)。",
                s.package, s.install_secs
            )),
            (false, _, None) => ctx.say(format!(
                "{} が固定した版と揃っていないので、揃えます ({name}{args}。{} 秒まで待ちます)。",
                s.subject, s.install_secs
            )),
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
            for n in self.fixes(&ctx.host, &r.output, s.sync_fix) {
                o = o.note(n);
            }
            return vec![o];
        }
        let code = r.code();
        // herdr: Preview が残っていると -IfMissing は 1 を返す。締めの行が Preview のことだけなら入った扱い
        let herdr_preview_only =
            s.policy == Policy::Herdr && code == Some(1) && v.preview && !v.sync;
        // 1 のわけが人の切り替える設定 (`alerts`) だけなら入った扱い (claude-desktop の、まだ開いていない Claude のシステムトレイは既定で on)
        let alerts_only = code == Some(1) && self.alerts_only(&r.output);
        if code == Some(0) || herdr_preview_only || alerts_only {
            if relay_only {
                ctx.say(RELAY_SYNCED);
            } else {
                for l in if installing { s.installed } else { s.synced } {
                    ctx.say(*l);
                }
                // 1Password の鍵の確かめ方は、1Password を使うホストでだけ添える
                if installing && s.one_password && !self.without_one_password(&ctx.host) {
                    ctx.say(ONE_PASSWORD_INSTALLED);
                }
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
            out.extend(self.alert_outcomes(&r.output));
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
            for n in self.fixes(&ctx.host, &r.output, s.manual_fix) {
                o = o.note(n);
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
        for n in self.fixes(&ctx.host, &r.output, s.sync_fix) {
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
    //! - 3 は apply で -IfMissing を打つ。google-ime-install・tailscale は、固定した版が winget に無ければ打たずに知らせる
    //! - 1 は手順ごと: ntn・claude-code は「→ … で揃える」なら引数なしで揃え、PATH のずれだけなら知らせる。herdr-app は -IfMissing で
    //!   揃える。openssh・sshd・tailscale・type-clipboard・google-ime-install は知らせるだけ。herdr は知らせるだけで、Preview が残っていれば外す手順も出す
    //! - tailscale は道具の switch (windowsTailscale) で on/off し、入れた後にログインは手でと出す (入っている版の方が新しいときは ps1 が 0)
    //! - sshd は道具の switch (windowsSshd) で on/off し、3 は UAC を先に知らせて -IfMissing で入れる。1 は知らせるだけで、揃える前に人が
    //!   直すこと (OpenSSH が無い・Windows の機能の OpenSSH Server がある・書けないユーザー名・鍵の写しの読めない行・拒否の規則が効かない
    //!   プロファイル・サービスの無い sshd.exe) はその直し方を出す。入れかけで止まったら、引数なしの Install-Sshd を案内する
    //! - sshd は -KeysFrom に受け持ち (runner・wsl) を渡す。受け持ちが runner のホストでは、ps1 を流す前にホストの値の [sshd] authorizedKeys
    //!   から鍵の写しを置き (apply。PowerShell が無くても)、check は差の行を前に足す。鍵の写しの読めない行の直し方は TOML と dotfiles apply、
    //!   手で打つ -Check に -KeysFrom runner を添える。受け持ちが WSL のホストでは写しに触らない (写しの置き方は `sshd_keys`)
    //! - sshd は、受け持ちが runner のホストでは、ps1 を流す前にホストの値の [sshd] allowUsers・allowFrom からユーザーと送り元の写しも置き
    //!   (apply。PowerShell が無くても。鍵の写しの後)、check は差の行を前に足す。写しの読めない値の直し方は、写しを置き直す dotfiles apply
    //!   (写しの置き方は `sshd_allow`)
    //! - op-reason は道具の switch (onePassword) で on/off し、3 も 1 (締めの行を見ない) も -SshRelay だけで流す (ps1 は -IfMissing を持たない)。
    //!   -SshRelay は、-Check にも揃える流れにも、SSH の中継の switch (opReasonSshRelay) が on ならモード (per-call・show-only)、off なら off を
    //!   渡す (受け持ちが WSL のホストの check も同じ)。ほかの手順には渡さない。版は揃っていて中継だけが違えば (ps1 の「SSH の中継が
    //!   揃っていない」)、行と前に出す行を中継の字にする。手で打つ -Check にも中継のモードを添える。前に出す行は手順の字 (無い手順は型の字と
    //!   待つ秒数)、-Check の時間切れに winget の見込みを添えない。WSL の script との突き合わせは `op_reason_parity`
    //! - openssh は道具の switch (windowsOpenssh) で on/off する (minimum では off。Windows に初めからある OpenSSH のまま)
    //! - openssh は、1Password を使わないホスト (道具の switch onePassword が off) では -Check にも入れる流れにも -NoOnePassword を渡し、入れた後の
    //!   1Password の行を出さず、手で打つ直し方のコマンドにも -NoOnePassword を添える。on のホストは渡さず、入れた後に 1Password の行を出す
    //! - ghq・fzf・starship は Windows にしか無い手順で、いつも on。ntn と同じく 3 は -IfMissing で入れ、「→ … で揃える」なら引数なしで揃え、
    //!   PATH のずれだけなら知らせる。fzf・starship は MSI の締めの行 (「→ ※ の手順で直す」だけ) なら打たずに知らせ、MSI の外し方を出す
    //! - codex は Windows にしか無い手順で、道具の switch (windowsCodex) で on/off。fzf と同じく入れる・揃える (codex と打つ symlink が無い形も
    //!   「→ Install-Codex で揃える」で揃える) が、入れる・揃える前に UAC を知らせる。winget が symlink を作れない締めの行 (「→ ※ の手順で直す」
    //!   だけ) なら打たずに知らせ、開発者モードの手を出す
    //! - claude-desktop は Windows にしか無い手順で、道具の switch (windowsClaudeDesktop) で on/off。3 は UAC を先に知らせて -IfMissing で
    //!   入れ (固定した版が winget に無ければ打たない)、1 は知らせるだけ。旧来の exe の Claude が残っている (締めの行。入っていなくても 1) なら、
    //!   check も apply もその外し方の行にして何も打たない。仮想マシン プラットフォームが off (出力の印) なら、状態の表が出たときだけ
    //!   知らせるだけの行 (·) を後ろに足す。Claude の設定のシステムトレイ・スタートアップ時に実行が on (締めの行の印。ps1 は版が揃って
    //!   いても 1 を返す) なら、印ごとの直すことがある行 (⚠) を足して何も打たず (dry-run も)、締めの行がそれだけなら揃っている扱い
    //!   (入れた後の 1 も入った扱い)。2 つの設定が読めなければ、知らせるだけの行 (·) を足す。ほかの手順は残りもの・知らせ・設定の印を
    //!   持たない
    //! - Windows にしか無い手順の ps1 は、runner が読む締めの行の文言 (Sync は「→ … で入れる」「→ … で揃える」「→ ※ の手順で直す」) と、
    //!   出力の印 (output_fixes・missing_blocked・leftover・notices・alerts) を持つ (WSL の wrapper との突き合わせの代わり)
    //! - 入れた後が 1 でも、herdr は残りが Preview だけなら入った扱い。ntn は PATH のずれだけなら知らせる
    //! - 見出しが無い・時間切れ・PowerShell が無い・ps1 が無いのは確かめられなかった
    //! - PowerShell のコマンドの組み立て (UTF-8・$LASTEXITCODE = 2・' の重ね・herdr-app の -ReleasesFile・pwsh が無ければ powershell)
    //! - -EncodedCommand の本文 (UTF-16LE の base64。PowerShell の [Convert]::ToBase64String と同じ字。本物の PowerShell が " と改行を含む本文を
    //!   そのまま流す (Windows))

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
        run_host(id, sys, mode, None)
    }

    /// `host` はホストの値の文 (None ならファイルが無いときの値)
    fn run_host(
        id: &str,
        sys: &FakeSys,
        mode: Mode,
        host: Option<&str>,
    ) -> (Vec<Outcome>, String, Vec<String>) {
        let t = TempDir::new("ps1");
        t.write(spec(id).script, "# ps1\n");
        let mut out = Vec::new();
        let groups = Groups::embedded().unwrap();
        let host = match host {
            Some(text) => crate::host::parse(text, Path::new("h.toml"), groups).unwrap(),
            None => HostValues::missing(Path::new("h.toml"), groups),
        };
        let outcomes = {
            let mut ctx = Ctx {
                repo: t.path().to_path_buf(),
                roots: Roots::from_home(Path::new("/h")),
                state_dir: t.path().join("state"),
                host,
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

    /// ghq・fzf・starship: Windows にしか無い手順で、いつも on。ntn と同じく入れる・揃える・PATH のずれは知らせる
    #[test]
    fn ghq_fzf_and_starship_sync_like_ntn() {
        for (id, command, name, path_owner, section) in [
            ("ghq", "Install-Ghq", "ghq", "winget のもの", "ghq・fzf"),
            (
                "fzf",
                "Install-Fzf",
                "fzf",
                "winget の portable のもの",
                "ghq・fzf",
            ),
            (
                "starship",
                "Install-Starship",
                "starship",
                "winget の portable のもの",
                "starship",
            ),
        ] {
            let s = spec(id);
            assert!(s.windows_only, "{id}");
            assert_eq!(s.gate, Gate::Always, "{id}");
            assert_eq!(s.order, 97, "{id}");
            assert_eq!(s.policy, Policy::Sync, "{id}");
            // 3: -IfMissing で入れる (UAC は出ない)
            let sys1 = sys(
                (
                    3,
                    vec![
                        header_line(s),
                        format!("⚠️ {name} が入っていない → {command} で入れる ⚠️"),
                    ],
                ),
                (0, vec![]),
            );
            let (o, out, calls) = run(id, &sys1, APPLY);
            assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")], "{id}");
            assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"], "{id}");
            assert!(
                out.contains(&format!(
                    "Windows に {} が入っていないので、固定した版を入れます ({command}.ps1 -IfMissing。600 秒まで待ちます)。",
                    s.package
                )),
                "{out}"
            );
            assert!(!out.contains("UAC"), "{id}");
            assert!(
                out.contains(&format!("Windows の {name} を入れました")),
                "{id}"
            );
            // 1 (版か pin のずれ): 引数なしで揃える
            let sys2 = sys(
                (
                    1,
                    vec![
                        header_line(s),
                        format!("⚠️ 固定した版と揃っていない → {command} で揃える ⚠️"),
                    ],
                ),
                (0, vec![]),
            );
            let (o, out, calls) = run(id, &sys2, APPLY);
            assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃えた")], "{id}");
            assert_eq!(ends(&calls), vec!["-Check", ""], "{id}");
            assert!(
                out.contains(&format!("Windows の {name} を揃えました")),
                "{id}"
            );
            // 1 (PATH のずれだけ): 知らせるだけ
            let sys3 = sys(
                (
                    1,
                    vec![
                        header_line(s),
                        format!("⚠️ PATH の {name} が {path_owner}ではない → ※ の手順で直す ⚠️"),
                    ],
                ),
                (0, vec![]),
            );
            let (o, _, calls) = run(id, &sys3, APPLY);
            assert_eq!(o[0].kind, Kind::Manual, "{id}");
            assert_eq!(ends(&calls), vec!["-Check"], "{id}");
            assert_eq!(
                o[0].text,
                format!("PATH で引かれるものが winget のものではない ({command} -Check の ※ の行)"),
                "{id}"
            );
            assert_eq!(
                o[0].notes,
                vec![format!(
                    "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「{section}」)"
                )],
                "{id}"
            );
        }
    }

    /// starship: fzf と同じく、MSI の starship が入っていると ps1 は portable を入れずに 1 を返す (締めの行は「→ ※ の手順で直す」だけ)。
    /// runner は打たずに知らせ、MSI の外し方を出す (PATH のずれの直し方の代わり)
    #[test]
    fn starship_msi_is_manual_with_the_uninstall_fix() {
        let s = spec("starship");
        let msi = (
            1,
            vec![
                header_line(s),
                "⚠ MSI の starship (machine スコープ。winget の既定の installer) が入っている: C:\\Program Files\\starship\\bin\\starship.exe".into(),
                "⚠️ MSI の starship (machine スコープ) が入っている → ※ の手順で直す ⚠️".into(),
            ],
        );
        for mode in [Mode::Check, APPLY] {
            let sys1 = sys(msi.clone(), (0, vec![]));
            let (o, _, calls) = run("starship", &sys1, mode);
            assert_eq!(o.len(), 1);
            assert_eq!(o[0].kind, Kind::Manual);
            assert_eq!(
                o[0].text,
                "MSI の starship (machine スコープ) が入っている (Install-Starship -Check の ※ の行。runner は直さない)"
            );
            assert_eq!(ends(&calls), vec!["-Check"]);
            assert_eq!(o[0].notes.len(), 1);
            assert!(
                o[0].notes[0]
                    .contains("winget uninstall --id Starship.Starship --exact --scope machine"),
                "{:?}",
                o[0].notes
            );
            assert!(
                o[0].notes[0].contains("dotfiles apply --steps starship"),
                "{:?}",
                o[0].notes
            );
        }
    }

    /// fzf: MSI の fzf が入っていると ps1 は portable を入れずに 1 を返す (締めの行は「→ ※ の手順で直す」だけ)。runner は打たずに
    /// 知らせ、MSI の外し方を出す (PATH のずれの直し方の代わり)
    #[test]
    fn fzf_msi_is_manual_with_the_uninstall_fix() {
        let s = spec("fzf");
        let msi = (
            1,
            vec![
                header_line(s),
                "⚠ MSI の fzf (machine スコープ。winget の既定の installer) が入っている: C:\\Program Files\\fzf\\bin\\fzf.exe".into(),
                "⚠️ MSI の fzf (machine スコープ) が入っている → ※ の手順で直す ⚠️".into(),
            ],
        );
        for mode in [Mode::Check, APPLY] {
            let sys1 = sys(msi.clone(), (0, vec![]));
            let (o, _, calls) = run("fzf", &sys1, mode);
            assert_eq!(o.len(), 1);
            assert_eq!(o[0].kind, Kind::Manual);
            assert_eq!(
                o[0].text,
                "MSI の fzf (machine スコープ) が入っている (Install-Fzf -Check の ※ の行。runner は直さない)"
            );
            assert_eq!(ends(&calls), vec!["-Check"]);
            assert_eq!(o[0].notes.len(), 1);
            assert!(
                o[0].notes[0]
                    .contains("winget uninstall --id junegunn.fzf --exact --scope machine"),
                "{:?}",
                o[0].notes
            );
        }
    }

    /// codex: 道具の switch (windowsCodex) で on/off の Windows にしか無い手順。fzf と同じく 3 は -IfMissing で入れ、「→ Install-Codex で揃える」
    /// (版・pin のずれと、codex と打つ symlink が無い形) なら引数なしで揃え、PATH のずれだけなら知らせる。開発者モードが off の PC では ps1 が
    /// winget を UAC で昇格して打つので、入れる・揃える前に UAC を知らせる。winget が symlink を作れない (管理者でなく開発者モードも off) なら、
    /// ps1 は入れずに 1 を返し、締めの行は「→ ※ の手順で直す」だけになる。runner は打たずに知らせ、開発者モードの手を出す
    #[test]
    fn codex_syncs_with_uac_and_reports_when_the_symlink_cannot_be_made() {
        let s = spec("codex");
        assert!(s.windows_only);
        assert_eq!(s.gate, Gate::Tool("windowsCodex"));
        assert_eq!(s.order, 97);
        assert_eq!(s.policy, Policy::Sync);
        assert!(s.uac);
        // minimum のホストでは off (使うホストが [tools] windowsCodex = true を書く)
        let minimum = crate::host::parse(
            "group = \"minimum\"\n",
            Path::new("h.toml"),
            Groups::embedded().unwrap(),
        )
        .unwrap();
        assert_eq!(
            s.gate.off_reason(&minimum).unwrap(),
            "このホストでは off (windowsCodex = false。グループ minimum の既定)"
        );
        // 3: UAC を先に知らせて -IfMissing で入れ、新しい PowerShell から codex と打てると添える
        let sys1 = sys(
            (
                3,
                vec![
                    header_line(s),
                    "⚠️ Codex CLI が入っていない → Install-Codex で入れる ⚠️".into(),
                ],
            ),
            (0, vec![]),
        );
        let (o, out, calls) = run("codex", &sys1, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")]);
        assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"]);
        assert!(
            out.contains("Windows に Codex CLI (winget の OpenAI.Codex) が入っていないので、固定した版を入れます (Install-Codex.ps1 -IfMissing。1800 秒まで待ちます)。"),
            "{out}"
        );
        assert!(out.contains("UAC の確認が出ます"), "{out}");
        assert!(
            out.contains("新しい PowerShell から codex と打てます"),
            "{out}"
        );
        // 1 (codex と打つ symlink が無い形): 引数なしで揃える (ps1 が入れ直す)
        let sys2 = sys(
            (
                1,
                vec![
                    header_line(s),
                    "⚠️ codex と打てない (WinGet\\Links に codex.exe の symlink が無い) → Install-Codex で揃える ⚠️".into(),
                ],
            ),
            (0, vec![]),
        );
        let (o, out, calls) = run("codex", &sys2, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃えた")]);
        assert_eq!(ends(&calls), vec!["-Check", ""]);
        assert!(out.contains("Windows の Codex CLI を揃えました"), "{out}");
        // check と dry-run は -Check だけを打つ
        let sys2_check = sys(
            (
                1,
                vec![
                    header_line(s),
                    "⚠️ codex と打てない (WinGet\\Links に codex.exe の symlink が無い) → Install-Codex で揃える ⚠️".into(),
                ],
            ),
            (0, vec![]),
        );
        let (o, _, calls) = run("codex", &sys2_check, Mode::Check);
        assert_eq!(o[0].kind, Kind::Fix);
        assert_eq!(ends(&calls), vec!["-Check"]);
        // 1 (PATH のずれだけ): 知らせるだけ
        let sys3 = sys(
            (
                1,
                vec![
                    header_line(s),
                    "⚠️ PATH の codex が winget の symlink ではない → ※ の手順で直す ⚠️".into(),
                ],
            ),
            (0, vec![]),
        );
        let (o, _, calls) = run("codex", &sys3, APPLY);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Manual);
        assert_eq!(ends(&calls), vec!["-Check"]);
        assert_eq!(
            o[0].notes,
            vec![
                "PATH のずれは揃える手順では直らない。上の ※ の行の手順で直す (win/README.md の「Codex CLI」)"
                    .to_string()
            ]
        );
        // winget が symlink を作れない: 打たずに知らせ、開発者モードの手を出す (check も apply も)
        let blocked = (
            1,
            vec![
                header_line(s),
                "⚠ winget が codex の symlink を作れない (このアカウントは管理者でなく、開発者モードも off)。入れても codex と打てないので、Install-Codex は入れない".into(),
                "⚠️ winget が codex の symlink を作れない (管理者でなく、開発者モードも off) → ※ の手順で直す ⚠️".into(),
            ],
        );
        for mode in [Mode::Check, APPLY] {
            let sys4 = sys(blocked.clone(), (0, vec![]));
            let (o, _, calls) = run("codex", &sys4, mode);
            assert_eq!(o.len(), 1);
            assert_eq!(o[0].kind, Kind::Manual);
            assert_eq!(
                o[0].text,
                "winget が codex の symlink を作れない (Install-Codex -Check の ※ の行。runner は直さない)"
            );
            assert_eq!(ends(&calls), vec!["-Check"]);
            assert_eq!(o[0].notes.len(), 1);
            assert!(
                o[0].notes[0].contains("開発者モードを on"),
                "{:?}",
                o[0].notes
            );
            assert!(
                o[0].notes[0].contains("dotfiles apply --steps codex"),
                "{:?}",
                o[0].notes
            );
        }
    }

    /// ps1 の字からコメント (`<# … #>` の塊と、`#` で始まる行) を除く。突き合わせを、コメントに写した文言で通さないため
    fn ps1_code(text: &str) -> String {
        let mut out = String::new();
        let mut in_block = false;
        for line in text.lines() {
            let t = line.trim_start_matches('\u{feff}').trim_start();
            if in_block {
                in_block = !t.contains("#>");
                continue;
            }
            if t.starts_with("<#") {
                in_block = !t.contains("#>");
                continue;
            }
            if t.starts_with('#') {
                continue;
            }
            out.push_str(line);
            out.push('\n');
        }
        out
    }

    #[test]
    fn ps1_code_drops_comments() {
        let text = "\u{feff}<#\n.SYNOPSIS\n→ Install-X で揃える\n#>\nparam()\n  # → Install-X で入れる\n'⚠️ → Install-X で揃える ⚠️'\n<# 1 行 #>\nx # 行末\n";
        assert_eq!(
            ps1_code(text),
            "param()\n'⚠️ → Install-X で揃える ⚠️'\nx # 行末\n"
        );
    }

    /// Windows にしか無い手順の ps1 は、runner が読む締めの行の文言と出力の印を、コメントでない行に持つ (WSL の wrapper との突き合わせの
    /// 代わり。文言を変えたら両方を直す)
    #[test]
    fn windows_only_scripts_carry_the_phrases_the_runner_reads() {
        let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        let only: Vec<&Ps1Spec> = SPECS.iter().filter(|s| s.windows_only).collect();
        assert_eq!(
            only.iter().map(|s| s.id).collect::<Vec<_>>(),
            vec![
                "t3-code",
                "claude-desktop",
                "ghq",
                "fzf",
                "starship",
                "codex"
            ]
        );
        for s in only {
            let text = ps1_code(&std::fs::read_to_string(repo.join(s.script)).unwrap());
            if s.policy == Policy::Sync {
                for phrase in [
                    format!("→ {} で入れる", s.command),
                    format!("→ {} で揃える", s.command),
                    "→ ※ の手順で直す".to_string(),
                ] {
                    assert!(text.contains(&phrase), "{} に「{phrase}」が無い", s.script);
                }
            }
            for marker in s
                .output_fixes
                .iter()
                .map(|(m, _)| *m)
                .chain(s.missing_blocked)
                .chain(s.leftover.map(|m| m.mark))
                .chain(s.notices.iter().map(|m| m.mark))
                .chain(s.alerts.iter().map(|m| m.mark))
            {
                assert!(text.contains(marker), "{} に「{marker}」が無い", s.script);
            }
        }
    }

    /// claude-desktop: 道具の switch (windowsClaudeDesktop) で on/off の Windows にしか無い手順。3 は UAC を先に知らせて -IfMissing で入れ、
    /// 固定した版が winget に無ければ打たない。1 は知らせるだけで、旧来の exe の Claude が残っている (締めの行) ならその外し方の行にして何も
    /// 打たない (入っていなくても)。仮想マシン プラットフォームが off なら、状態の表が出たときだけ知らせるだけの行 (·) を足す
    #[test]
    fn claude_desktop_installs_with_uac_and_reports_leftovers_and_notices() {
        let s = spec("claude-desktop");
        assert!(s.windows_only);
        assert_eq!(s.gate, Gate::Tool("windowsClaudeDesktop"));
        assert_eq!(s.order, 97);
        assert_eq!(s.policy, Policy::Warn);
        assert!(s.uac);
        assert_eq!(s.install_secs, 1800);
        let legacy = "⚠️ 旧来の exe の Claude が残っている → ※ の手順で外す (Install-ClaudeDesktop は外さない) ⚠️";
        let vm_off = "※ 仮想マシン プラットフォーム (VirtualMachinePlatform) が off なので、Cowork (VM の中で動くエージェント) は使えない。on にするには…";

        // 3: UAC を先に知らせてから -IfMissing。サインインの案内は ps1 が出す 1 行だけ (重ねて出さない)
        let signin = "Claude のサインインは手でする (スタートメニューの Claude を開く。dotfiles はサインインに触らない)";
        let sys1 = sys(
            (3, vec![header_line(s)]),
            (0, vec![signin.to_string(), "揃った".into()]),
        );
        let (o, out, calls) = run("claude-desktop", &sys1, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")]);
        assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"]);
        assert!(
            out.contains(
                "Windows に Claude Desktop (winget の Anthropic.Claude の MSIX) が入っていないので、固定した版を入れます (Install-ClaudeDesktop.ps1 -IfMissing。1800 秒まで待ちます)。"
            ),
            "{out}"
        );
        assert!(out.contains("UAC の確認が出ます"));
        assert!(out.contains("Windows に Claude Desktop (MSIX) を入れました。"));
        assert_eq!(
            out.matches("Claude のサインインは手でする").count(),
            1,
            "{out}"
        );

        // check の 3 は入れる見込み (打つのは -Check だけ)
        let sys1c = sys((3, vec![header_line(s)]), (9, vec![]));
        let (o, _, calls) = run("claude-desktop", &sys1c, Mode::Check);
        assert_eq!(
            o,
            vec![Outcome::new(
                Kind::Missing,
                "入っていない → apply で入れる (Install-ClaudeDesktop.ps1 -IfMissing)"
            )]
        );
        assert_eq!(ends(&calls), vec!["-Check"]);

        // 3 でも固定した版が winget に無ければ打たない
        let blocked = sys(
            (
                3,
                vec![
                    header_line(s),
                    "⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない"
                        .into(),
                ],
            ),
            (0, vec![]),
        );
        let (o, _, calls) = run("claude-desktop", &blocked, APPLY);
        assert_eq!(o[0].kind, Kind::Manual);
        assert_eq!(ends(&calls), vec!["-Check"]);
        assert!(o[0].notes[0].contains("winget show --id Anthropic.Claude --versions"));

        // 1 で旧来の exe の Claude が残っている: 外し方の行 (「固定した版と揃っていない」にしない)。MSIX が揃っていて残りがそれだけの
        // 締めの行も、入っていない・古いのに旧来の exe があるので入れない締めの行も同じ。check も apply も打つのは -Check だけ (UAC を出さない)
        let blocks = "⚠️ 旧来の exe の Claude が残っている → ※ の手順で外してから、Install-ClaudeDesktop で入れる・揃える (外すまで MSIX は入れない) ⚠️";
        for line in [legacy, blocks] {
            for mode in [Mode::Check, APPLY] {
                let sys2 = sys((1, vec![header_line(s), line.to_string()]), (0, vec![]));
                let (o, out, calls) = run("claude-desktop", &sys2, mode);
                assert_eq!(o.len(), 1, "{line}");
                assert_eq!(o[0].kind, Kind::Manual, "{line}");
                assert_eq!(
                    o[0].text,
                    "旧来の exe の Claude (Squirrel。%LOCALAPPDATA%\\AnthropicClaude) が残っている → ※ の手順で外す (runner は外さない。MSIX が入っていなければ、外した後の dotfiles apply で入れる)",
                    "{line}"
                );
                assert_eq!(o[0].notes.len(), 2, "{line}");
                assert!(o[0].notes[0].contains("Update.exe\" --uninstall -s"));
                assert!(o[0].notes[1].contains("Claude.lnk"));
                assert_eq!(ends(&calls), vec!["-Check"], "{line}");
                assert!(!out.contains("UAC の確認が出ます"), "{line}");
            }
        }

        // 入れた後の 1 は、旧来の exe の印があっても入った扱いにしない (ps1 は旧来の exe があるうちは入れないので、そこには来ない)
        let sys3 = sys(
            (3, vec![header_line(s)]),
            (1, vec![header_line(s), legacy.to_string()]),
        );
        let (o, _, _) = run("claude-desktop", &sys3, APPLY);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(o[0].text.starts_with("入れられなかった (終了コード 1"));

        // 3 → 入れた後が 1 で、ほかのわけ (UAC を断った): 入れられなかった。直し方は UAC の印のもの
        let sys4 = sys(
            (3, vec![header_line(s)]),
            (
                1,
                vec![
                    "UAC の確認を断った・出せなかった (SSH の会話では出せない)。デスクトップの PowerShell で Install-ClaudeDesktop を打ち直す"
                        .into(),
                ],
            ),
        );
        let (o, _, _) = run("claude-desktop", &sys4, APPLY);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(o[0].text.starts_with("入れられなかった (終了コード 1"));
        assert_eq!(o[0].notes.len(), 1);
        assert!(o[0].notes[0].contains("「はい」を押す"), "{:?}", o[0].notes);
        // 時間切れには、UAC の確認が残っているかもしれないことを添える
        let sys5 = sys((3, vec![header_line(s)]), (-1, vec![]));
        let (o, _, _) = run("claude-desktop", &sys5, APPLY);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("UAC の確認が残っていれば")),
            "{:?}",
            o[0].notes
        );

        // 1 (古い・pin が無い): 知らせるだけで、Install-ClaudeDesktop を案内する。版が読めなければ確かめ方
        for (line, want) in [
            (
                "⚠ 固定した版                  : 5.11492.5 → 上げる",
                "PowerShell で Install-ClaudeDesktop を打つ",
            ),
            (
                "⚠ 固定した版                  : 5.11492.5 → 比べられない",
                "Get-AppxPackage -Name Claude",
            ),
        ] {
            let sys6 = sys((1, vec![header_line(s), line.to_string()]), (0, vec![]));
            let (o, _, calls) = run("claude-desktop", &sys6, APPLY);
            assert_eq!(o.len(), 1, "{line}");
            assert_eq!(o[0].kind, Kind::Manual, "{line}");
            assert_eq!(
                o[0].text, "固定した版と揃っていない → ※ の手順で直す (runner は揃えない)",
                "{line}"
            );
            assert_eq!(ends(&calls), vec!["-Check"], "{line}");
            assert_eq!(o[0].notes.len(), 1, "{line}");
            assert!(o[0].notes[0].contains(want), "{line}: {:?}", o[0].notes);
        }

        // 仮想マシン プラットフォームが off: 行の後ろに知らせるだけの行 (·) を足す (0・3 の apply と check)
        let sys7 = sys((0, vec![header_line(s), vm_off.to_string()]), (9, vec![]));
        let (o, out, _) = run("claude-desktop", &sys7, APPLY);
        assert_eq!(o.len(), 2);
        assert_eq!(o[0], Outcome::new(Kind::Ok, "揃っている"));
        assert_eq!(o[1].kind, Kind::Info);
        assert!(
            o[1].text
                .starts_with("仮想マシン プラットフォーム (VirtualMachinePlatform) が off")
        );
        assert!(o[1].notes[0].contains(
            "Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All"
        ));
        assert!(
            out.contains("Windows の Claude Desktop は、dotfiles で固定した版以上で入っています。")
        );
        for mode in [APPLY, Mode::Check] {
            let sys8 = sys((3, vec![header_line(s), vm_off.to_string()]), (0, vec![]));
            let (o, _, _) = run("claude-desktop", &sys8, mode);
            let kinds: Vec<Kind> = o.iter().map(|x| x.kind).collect();
            let first = if mode == APPLY {
                Kind::Ok
            } else {
                Kind::Missing
            };
            assert_eq!(kinds, vec![first, Kind::Info], "{mode:?}");
        }
        // 状態の表が出ていない (ps1 が動いていない) ときは、印があっても足さない
        let sys9 = sys((2, vec![vm_off.to_string()]), (0, vec![]));
        let (o, _, _) = run("claude-desktop", &sys9, Mode::Check);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Failed);

        // ほかの手順は残りもの・知らせ・人が切り替える設定の印を持たない
        for other in SPECS.iter().filter(|x| x.id != "claude-desktop") {
            assert!(
                other.leftover.is_none() && other.notices.is_empty() && other.alerts.is_empty(),
                "{}",
                other.id
            );
        }
    }

    /// claude-desktop: Claude の設定のシステムトレイ・スタートアップ時に実行が on (締めの行の印。ps1 は版が揃っていても 1) なら、check も
    /// apply も、印ごとの直すことがある行 (⚠) を足して何も打たない。版が揃っていれば揃っている行の後ろに、版のずれ・旧来の exe と重なれば
    /// その行の後ろに足す。入れた後の 1 のわけがそれだけ (まだ開いていない Claude のトレイは既定で on) なら、入った扱い
    #[test]
    fn claude_desktop_reports_tray_and_startup_settings() {
        let s = spec("claude-desktop");
        let tray = "⚠️ Claude Desktop のシステムトレイが on → Claude の設定 > デスクトップアプリ の「システムトレイ」を off にする (Install-ClaudeDesktop は設定を書き換えない) ⚠️";
        let tray_unopened = "⚠️ Claude Desktop のシステムトレイが on (既定) → Claude を開いたら、設定 > デスクトップアプリ の「システムトレイ」を off にする (Install-ClaudeDesktop は設定を書き換えない) ⚠️";
        let startup = "⚠️ Claude Desktop のスタートアップ時に実行が on → Claude の設定 > デスクトップアプリ の「スタートアップ時に実行」を off にする (Install-ClaudeDesktop は設定を書き換えない) ⚠️";
        let tray_line = "Claude Desktop のシステムトレイが on → Claude の設定 > デスクトップアプリ の「システムトレイ」を off にする (runner は設定を書き換えない)";
        let startup_line = "Claude Desktop のスタートアップ時に実行が on → Claude の設定 > デスクトップアプリ の「スタートアップ時に実行」を off にする (runner は設定を書き換えない)";
        let lines = |o: &[Outcome]| -> Vec<(Kind, String)> {
            o.iter().map(|x| (x.kind, x.text.clone())).collect()
        };

        // 1 のわけが設定だけ: 揃っている行の後ろに、印ごとの ⚠ の行 (トレイ・スタートアップの順)。check も apply も打つのは -Check だけ
        for mode in [Mode::Check, APPLY] {
            let sys1 = sys(
                (1, vec![header_line(s), tray.into(), startup.into()]),
                (9, vec![]),
            );
            let (o, out, calls) = run("claude-desktop", &sys1, mode);
            assert_eq!(
                lines(&o),
                vec![
                    (Kind::Ok, "揃っている".to_string()),
                    (Kind::Manual, tray_line.to_string()),
                    (Kind::Manual, startup_line.to_string()),
                ],
                "{mode:?}"
            );
            assert!(
                o[1].notes[0].contains("リモートから操作されない"),
                "{:?}",
                o[1].notes
            );
            assert!(
                o[2].notes[0].contains("サインインしたときに Claude が起きる"),
                "{:?}",
                o[2].notes
            );
            assert_eq!(ends(&calls), vec!["-Check"], "{mode:?}");
            assert!(
                out.contains(
                    "Windows の Claude Desktop は、dotfiles で固定した版以上で入っています。"
                ),
                "{out}"
            );
        }
        // まだ開いていない Claude のトレイ (既定で on) も、同じ印の行
        let sys2 = sys((1, vec![header_line(s), tray_unopened.into()]), (9, vec![]));
        let (o, _, _) = run("claude-desktop", &sys2, Mode::Check);
        assert_eq!(
            lines(&o),
            vec![
                (Kind::Ok, "揃っている".to_string()),
                (Kind::Manual, tray_line.to_string()),
            ]
        );

        // 版のずれ (pin が無い) と重なれば、知らせるだけの行の後ろに足す
        let pin = "⚠️ winget pin が無い → Install-ClaudeDesktop で足す (UAC の確認は出ない) ⚠️";
        let sys3 = sys(
            (1, vec![header_line(s), pin.into(), tray.into()]),
            (9, vec![]),
        );
        let (o, _, calls) = run("claude-desktop", &sys3, APPLY);
        assert_eq!(
            lines(&o),
            vec![
                (
                    Kind::Manual,
                    "固定した版と揃っていない → ※ の手順で直す (runner は揃えない)".to_string()
                ),
                (Kind::Manual, tray_line.to_string()),
            ]
        );
        assert_eq!(ends(&calls), vec!["-Check"]);
        // 旧来の exe と重なれば、外し方の行の後ろに足す
        let legacy = "⚠️ 旧来の exe の Claude が残っている → ※ の手順で外す (Install-ClaudeDesktop は外さない) ⚠️";
        let sys4 = sys(
            (1, vec![header_line(s), legacy.into(), startup.into()]),
            (9, vec![]),
        );
        let (o, _, _) = run("claude-desktop", &sys4, Mode::Check);
        let kinds: Vec<Kind> = o.iter().map(|x| x.kind).collect();
        assert_eq!(kinds, vec![Kind::Manual, Kind::Manual]);
        assert!(
            o[0].text.starts_with("旧来の exe の Claude (Squirrel。"),
            "{}",
            o[0].text
        );
        assert_eq!(o[1].text, startup_line);
        // 知らせるだけの行 (仮想マシン プラットフォームが off) は、設定の行の後ろ
        let vm_off = "※ 仮想マシン プラットフォーム (VirtualMachinePlatform) が off なので、Cowork (VM の中で動くエージェント) は使えない。on にするには…";
        let sys5 = sys(
            (1, vec![header_line(s), vm_off.into(), tray.into()]),
            (9, vec![]),
        );
        let (o, _, _) = run("claude-desktop", &sys5, Mode::Check);
        let kinds: Vec<Kind> = o.iter().map(|x| x.kind).collect();
        assert_eq!(kinds, vec![Kind::Ok, Kind::Manual, Kind::Info]);

        // 入れた後の 1 のわけが設定だけ (まだ開いていない Claude のトレイ): 入った扱いにして、設定の行を足す
        let sys6 = sys(
            (3, vec![header_line(s)]),
            (1, vec![header_line(s), tray_unopened.into()]),
        );
        let (o, out, calls) = run("claude-desktop", &sys6, APPLY);
        assert_eq!(
            lines(&o),
            vec![
                (Kind::Ok, "入れた".to_string()),
                (Kind::Manual, tray_line.to_string()),
            ]
        );
        assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"]);
        assert!(
            out.contains("Windows に Claude Desktop (MSIX) を入れました。"),
            "{out}"
        );
        // 入れた後の 1 に、設定のほかの締めの行もあれば、入れられなかった (設定の行は足さない)
        let missing = "⚠️ Claude Desktop (MSIX) が入っていない → Install-ClaudeDesktop で入れる (UAC の確認が 1 回出る) ⚠️";
        let sys7 = sys(
            (3, vec![header_line(s)]),
            (1, vec![header_line(s), missing.into(), tray.into()]),
        );
        let (o, _, _) = run("claude-desktop", &sys7, APPLY);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(
            o[0].text.starts_with("入れられなかった (終了コード 1"),
            "{}",
            o[0].text
        );

        // 状態の表が出ていない 1 は、設定の印があっても確かめられなかった
        let sys8 = sys((1, vec![tray.into()]), (9, vec![]));
        let (o, _, _) = run("claude-desktop", &sys8, Mode::Check);
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Failed);

        // dry-run も打たずに同じ行を出す。入れる見込み (3) のときも、-Check の出力の設定の行を出す (打つのは apply だけで、そのときは
        // 打った後の出力から足す)
        let dry = Mode::DryRun { force: false };
        let sys9 = sys((1, vec![header_line(s), tray.into()]), (9, vec![]));
        let (o, _, calls) = run("claude-desktop", &sys9, dry);
        assert_eq!(
            lines(&o),
            vec![
                (Kind::Ok, "揃っている".to_string()),
                (Kind::Manual, tray_line.to_string()),
            ]
        );
        assert_eq!(ends(&calls), vec!["-Check"]);
        for mode in [Mode::Check, dry] {
            let sys10 = sys((3, vec![header_line(s), startup.into()]), (9, vec![]));
            let (o, _, calls) = run("claude-desktop", &sys10, mode);
            let kinds: Vec<Kind> = o.iter().map(|x| x.kind).collect();
            assert_eq!(kinds, vec![Kind::Missing, Kind::Manual], "{mode:?}");
            assert_eq!(o[1].text, startup_line, "{mode:?}");
            assert_eq!(ends(&calls), vec!["-Check"], "{mode:?}");
        }

        // 設定が読めない (ps1 の ※ の行): 数えない知らせの行 (·) を、トレイ・スタートアップの順に足す
        let tray_unknown = "※ システムトレイの設定 (claude_desktop_config.json の preferences.menuBarEnabled) が読めない。Claude の設定 > デスクトップアプリ で確かめる";
        let startup_unknown = "※ スタートアップ時に実行の状態 (startup task ClaudeStartup の State) が読めない。Claude の設定 > デスクトップアプリ で確かめる";
        let sys11 = sys(
            (
                0,
                vec![header_line(s), tray_unknown.into(), startup_unknown.into()],
            ),
            (9, vec![]),
        );
        let (o, _, _) = run("claude-desktop", &sys11, Mode::Check);
        let kinds: Vec<Kind> = o.iter().map(|x| x.kind).collect();
        assert_eq!(kinds, vec![Kind::Ok, Kind::Info, Kind::Info]);
        assert!(
            o[1].text
                .starts_with("Claude Desktop のシステムトレイの設定が読めない"),
            "{}",
            o[1].text
        );
        assert!(
            o[2].text
                .starts_with("Claude Desktop のスタートアップ時に実行の状態が読めない"),
            "{}",
            o[2].text
        );
        assert!(
            o[1].notes[0].contains("Claude の設定 > デスクトップアプリ で確かめる"),
            "{:?}",
            o[1].notes
        );
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
        for id in [
            "openssh",
            "sshd",
            "tailscale",
            "type-clipboard",
            "google-ime-install",
        ] {
            let s = spec(id);
            let sys1 = sys((1, vec![header_line(s)]), (0, vec![]));
            let (o, _, calls) = run(id, &sys1, APPLY);
            assert_eq!(o[0].kind, Kind::Manual, "{id}");
            // sshd は受け持ち (ファイルが無いホストは WSL) も渡す。openssh は、1Password を使わないホスト (ファイルが無いときは minimum の
            // 既定で onePassword が off) なので -NoOnePassword も渡す
            let check = match id {
                "sshd" => "-Check -KeysFrom 'wsl'",
                "openssh" => "-Check -NoOnePassword",
                _ => "-Check",
            };
            assert_eq!(ends(&calls), vec![check], "{id}");
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

    /// tailscale: 道具の switch (windowsTailscale) で on/off。3 は UAC を先に知らせて -IfMissing で入れ、入れた後にログインは手でと出す。
    /// 固定した版が winget に無ければ打たない。1 は知らせるだけで、出力の印ごとに直し方を選ぶ
    #[test]
    fn tailscale_installs_only_when_missing_and_only_warns_drift() {
        let s = spec("tailscale");
        assert_eq!(s.gate, Gate::Tool("windowsTailscale"));
        assert_eq!(s.order, 96);
        // 3: UAC を先に知らせてから -IfMissing。ログインの案内は ps1 が出す 1 行だけ (重ねて出さない)
        let login = "tailnet へのログインは手でする (タスクトレイの Tailscale のアイコンから Log in。dotfiles はログインに触らない)";
        let sys1 = sys(
            (3, vec![header_line(s)]),
            (0, vec![login.to_string(), "揃った".into()]),
        );
        let (o, out, calls) = run("tailscale", &sys1, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")]);
        assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"]);
        assert!(out.contains("UAC の確認が出ます"));
        assert!(out.contains("Windows に Tailscale を入れました。"));
        assert_eq!(
            out.matches("tailnet へのログインは手でする").count(),
            1,
            "{out}"
        );
        // 3 でも固定した版が winget に無ければ打たない
        let blocked = sys(
            (
                3,
                vec![
                    header_line(s),
                    "⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない"
                        .into(),
                ],
            ),
            (0, vec![]),
        );
        let (o, _, calls) = run("tailscale", &blocked, APPLY);
        assert_eq!(o[0].kind, Kind::Manual);
        assert_eq!(ends(&calls), vec!["-Check"]);
        assert!(o[0].notes[0].contains("winget show --id Tailscale.Tailscale --versions"));
        // 1: 古い・pin が無いなら Install-Tailscale を案内する (runner は上げない)。版が読めなければ確かめ方
        for (line, want) in [
            (
                "⚠ 固定した版      : 1.104.5 → 上げる",
                "PowerShell で Install-Tailscale を打つ",
            ),
            (
                "⚠ 固定した版      : 1.104.5 → 比べられない",
                "winget list --id Tailscale.Tailscale",
            ),
        ] {
            let sys2 = sys((1, vec![header_line(s), line.to_string()]), (0, vec![]));
            let (o, _, calls) = run("tailscale", &sys2, APPLY);
            assert_eq!(o[0].kind, Kind::Manual, "{line}");
            assert_eq!(ends(&calls), vec!["-Check"], "{line}");
            assert_eq!(o[0].notes.len(), 1, "{line}");
            assert!(o[0].notes[0].contains(want), "{line}: {:?}", o[0].notes);
        }
        // 0 (入っている版の方が新しいときも ps1 は 0): 揃っている
        let sys3 = sys(
            (
                0,
                vec![
                    header_line(s),
                    "  固定した版      : 1.104.5 → 入っている版の方が新しい (下げない)".into(),
                ],
            ),
            (9, vec![]),
        );
        let (o, out, calls) = run("tailscale", &sys3, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃っている")]);
        assert_eq!(ends(&calls), vec!["-Check"]);
        assert!(out.contains("Windows の Tailscale は、dotfiles で固定した版以上で入っています。"));
    }

    /// sshd: 道具の switch (windowsSshd) で on/off。3 は UAC を先に知らせて -IfMissing で入れる。1 は知らせるだけで、揃える前に人が
    /// 直すことは出力の印ごとに直し方を選ぶ
    #[test]
    fn sshd_installs_only_when_missing_and_only_warns_drift() {
        let s = spec("sshd");
        assert_eq!(s.gate, Gate::Tool("windowsSshd"));
        assert_eq!(s.order, 96);
        assert_eq!(s.script, "win/openssh/Install-Sshd.ps1");
        // 3: UAC を先に知らせてから -IfMissing
        let sys1 = sys(
            (
                3,
                vec![
                    header_line(s),
                    "⚠️ sshd が入っていない → Install-Sshd -IfMissing で入れる (UAC の確認が 1 回出る) ⚠️".into(),
                ],
            ),
            (0, vec!["入れた".into()]),
        );
        let (o, out, calls) = run("sshd", &sys1, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")]);
        assert_eq!(
            ends(&calls),
            vec!["-Check -KeysFrom 'wsl'", "-IfMissing -KeysFrom 'wsl'"]
        );
        assert!(out.contains("UAC の確認が出ます"));
        assert!(out.contains("Windows に sshd を入れて揃えました"));
        // check では -Check だけを打ち、apply で入れると出す
        let sys1c = sys((3, vec![header_line(s)]), (0, vec![]));
        let (o, _, calls) = run("sshd", &sys1c, Mode::Check);
        assert_eq!(o[0].kind, Kind::Missing);
        assert_eq!(
            o[0].text,
            "入っていない → apply で入れる (Install-Sshd.ps1 -IfMissing)"
        );
        assert_eq!(ends(&calls), vec!["-Check -KeysFrom 'wsl'"]);
        // 1: ずれは Install-Sshd を案内する (runner は揃えない)。揃える前に人が直すことは、その直し方
        for (line, want) in [
            (
                "⚠️ dotfiles の形と揃っていない → Install-Sshd で揃える (UAC の確認が 1 回出る。sshd を起こし直すと、つないでいる SSH が切れることがある) ⚠️",
                "PowerShell で Install-Sshd を打つ",
            ),
            (
                "⚠️ OpenSSH が入っていない → 先に Install-OpenSSH -IfMissing で入れる (sshd はその MSI に足す) ⚠️",
                "Install-OpenSSH -IfMissing",
            ),
            (
                "⚠️ Windows の機能の OpenSSH Server が入っている → 先に外す (二重にしない。上の ※ の行) ⚠️",
                "Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0",
            ),
            (
                "⚠️ AllowUsers に書けないユーザー名 → このユーザーでは dotfiles の sshd を使えない (上の ※ の行) ⚠️",
                "このユーザーでは dotfiles の sshd を使えない",
            ),
            (
                "⚠️ Windows Firewall が効いていないプロファイルがある → 先に有効にする (拒否の規則が効かない。上の ※ の行) ⚠️",
                "Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True",
            ),
            (
                "⚠️ sshd.exe はあるがサービス sshd が無い → Server の機能を外してから入れ直す (上の ※ の行) ⚠️",
                "sshd を止める・外す",
            ),
            (
                "⚠️ 鍵の写しに読めない行がある → ホストの値 (wsl.windowsFiles.sshd.authorizedKeys) を直して setup を流し直す ⚠️",
                "wsl.windowsFiles.sshd.authorizedKeys",
            ),
            (
                "⚠️ ユーザーと送り元の写しに読めない値がある → ホストの値 (dotfiles-private の win/hosts の TOML の [sshd] allowUsers・allowFrom) を直して dotfiles apply を流し直す ⚠️",
                "[sshd] allowUsers・allowFrom どおりに置き直す",
            ),
        ] {
            let sys2 = sys((1, vec![header_line(s), line.to_string()]), (0, vec![]));
            let (o, _, calls) = run("sshd", &sys2, APPLY);
            assert_eq!(o[0].kind, Kind::Manual, "{line}");
            assert_eq!(ends(&calls), vec!["-Check -KeysFrom 'wsl'"], "{line}");
            assert_eq!(o[0].notes.len(), 1, "{line}");
            assert!(o[0].notes[0].contains(want), "{line}: {:?}", o[0].notes);
        }
        // 入れかけで止まった (-IfMissing が 1): 引数なしの Install-Sshd を案内する (-IfMissing は 1 のとき何もしない)
        let sys4 = sys(
            (3, vec![header_line(s)]),
            (1, vec!["msiexec が失敗した (終了コード 1603)".into()]),
        );
        let (o, _, calls) = run("sshd", &sys4, APPLY);
        assert_eq!(o[0].kind, Kind::Failed);
        assert_eq!(
            ends(&calls),
            vec!["-Check -KeysFrom 'wsl'", "-IfMissing -KeysFrom 'wsl'"]
        );
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("PowerShell で Install-Sshd を打つ")
                    && !n.contains("-IfMissing")),
            "{:?}",
            o[0].notes
        );
        // 0: 揃っている
        let sys3 = sys((0, vec![header_line(s), "揃っている".into()]), (9, vec![]));
        let (o, out, calls) = run("sshd", &sys3, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃っている")]);
        assert_eq!(ends(&calls), vec!["-Check -KeysFrom 'wsl'"]);
        assert!(out.contains("Windows の sshd は、dotfiles の形"));
    }

    /// sshd の鍵の写し: 受け持ちが runner のホストでは、ps1 を流す前に TOML の [sshd] authorizedKeys から写しを置き (apply)、check は
    /// 差の行を前に足す。-KeysFrom は runner を渡し、手で打つ -Check にも添える。鍵の写しの読めない行の直し方は TOML と dotfiles apply。
    /// PowerShell が無くても写しは先に揃える。受け持ちが WSL のホストでは写しに触らず、-KeysFrom wsl
    #[test]
    fn sshd_places_the_keys_copy_on_runner_hosts() {
        let s = spec("sshd");
        let key =
            r#"from="100.64.0.1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE herdr@phone"#;
        let runner_host = format!(
            "[runner]\nenable = true\n[tools]\nwindowsSshd = true\n[sshd]\nauthorizedKeys = ['{key}']\n"
        );
        let go = |sys: &FakeSys, mode: Mode, host: &str, home: &Path| {
            let t = TempDir::new("ps1");
            t.write(s.script, "# ps1\n");
            let mut out = Vec::new();
            let host =
                crate::host::parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap();
            let o = {
                let mut ctx = Ctx {
                    repo: t.path().to_path_buf(),
                    roots: Roots::from_home(home),
                    state_dir: t.path().join("state"),
                    host,
                    sys,
                    out: &mut out,
                };
                Ps1Step(s).run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        };
        let home = TempDir::new("ps1-home");
        let copy = Roots::from_home(home.path())
            .local_app_data
            .join("dotfiles/sshd/authorized_keys");
        let drift = "⚠️ dotfiles の形と揃っていない → Install-Sshd で揃える (UAC の確認が 1 回出る。sshd を起こし直すと、つないでいる SSH が切れることがある) ⚠️";
        // check: 写しの差の行が前に付き、写しは置かない
        let sys0 = sys((0, vec![header_line(s), "揃っている".into()]), (9, vec![]));
        let (o, _) = go(&sys0, Mode::Check, &runner_host, home.path());
        assert_eq!(o.len(), 2, "{o:?}");
        assert_eq!(o[0].kind, Kind::Fix);
        assert!(o[0].text.starts_with("鍵の写しが無い → apply で置く"));
        assert_eq!(o[1], Outcome::new(Kind::Ok, "揃っている"));
        assert!(!copy.exists());
        let calls: Vec<String> = sys0.call_args();
        assert!(
            calls
                .iter()
                .any(|c| c.contains("-Check -KeysFrom 'runner'")),
            "{calls:?}"
        );
        // apply: 写しを置いてから -Check (ずれは Install-Sshd を案内するだけ)
        let sys1 = sys((1, vec![header_line(s), drift.into()]), (0, vec![]));
        let (o, out) = go(&sys1, APPLY, &runner_host, home.path());
        assert_eq!(o.len(), 1, "{o:?}");
        assert_eq!(o[0].kind, Kind::Manual);
        assert!(o[0].notes[0].contains("PowerShell で Install-Sshd を打つ"));
        assert!(out.contains("鍵の写しを置きました (1 本"));
        assert_eq!(
            std::fs::read_to_string(&copy).unwrap(),
            super::super::sshd_keys::copy_text(&[key.to_string()])
        );
        // 鍵の写しの読めない行: 受け持ちが runner なら TOML と dotfiles apply で直す
        let bad = "⚠️ 鍵の写しに読めない行がある → ホストの値 (dotfiles-private の win/hosts の TOML の [sshd] authorizedKeys) を直して dotfiles apply を流し直す ⚠️";
        let sys2 = sys((1, vec![header_line(s), bad.into()]), (0, vec![]));
        let (o, _) = go(&sys2, Mode::Check, &runner_host, home.path());
        assert_eq!(o.len(), 1);
        assert!(
            o[0].notes[0].contains("[sshd] authorizedKeys どおりに置き直す"),
            "{:?}",
            o[0].notes
        );
        // -Check の時間切れ: 手で打つ -Check に -KeysFrom runner
        let sys3 = sys((-1, vec![]), (0, vec![]));
        let (o, _) = go(&sys3, Mode::Check, &runner_host, home.path());
        assert!(
            o[0].notes[0].contains("Install-Sshd -Check -KeysFrom runner"),
            "{:?}",
            o[0].notes
        );
        // PowerShell が無くても、写しは先に揃える (鍵を外すと写しを消す)
        let nopwsh = FakeSys::new(|_| unreachable!());
        let (o, out) = go(
            &nopwsh,
            APPLY,
            "[runner]\nenable = true\n[tools]\nwindowsSshd = true\n",
            home.path(),
        );
        assert!(out.contains("鍵の写しを消しました"), "{out}");
        assert!(!copy.exists());
        assert_eq!(o.last().unwrap().kind, Kind::Failed);
        // 受け持ちが WSL のホスト: 写しに触らず、-KeysFrom wsl
        std::fs::write(&copy, "x\n").unwrap();
        let sys4 = sys((0, vec![header_line(s), "揃っている".into()]), (9, vec![]));
        let (o, _) = go(&sys4, APPLY, "[tools]\nwindowsSshd = true\n", home.path());
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃っている")]);
        assert_eq!(std::fs::read_to_string(&copy).unwrap(), "x\n");
        assert!(
            sys4.call_args()
                .iter()
                .any(|c| c.contains("-Check -KeysFrom 'wsl'"))
        );
    }

    /// sshd のユーザーと送り元の写し: 受け持ちが runner のホストでは、ps1 を流す前に TOML の [sshd] allowUsers・allowFrom から写しを置き
    /// (apply。鍵の写しの後。PowerShell が無くても)、check は差の行を鍵の写しの行の後ろ・ps1 の行の前に足す。受け持ちが WSL のホストでは
    /// 写しに触らない
    #[test]
    fn sshd_places_the_allow_copy_on_runner_hosts() {
        let s = spec("sshd");
        let key =
            r#"from="100.64.0.1" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKE herdr@phone"#;
        let runner_host = format!(
            "[runner]\nenable = true\n[tools]\nwindowsSshd = true\n[sshd]\nauthorizedKeys = ['{key}']\nallowUsers = [\"alice\"]\nallowFrom = [\"100.64.0.1\", \"::1\"]\n"
        );
        let go = |sys: &FakeSys, mode: Mode, host: &str, home: &Path| {
            let t = TempDir::new("ps1");
            t.write(s.script, "# ps1\n");
            let mut out = Vec::new();
            let host =
                crate::host::parse(host, Path::new("h.toml"), Groups::embedded().unwrap()).unwrap();
            let o = {
                let mut ctx = Ctx {
                    repo: t.path().to_path_buf(),
                    roots: Roots::from_home(home),
                    state_dir: t.path().join("state"),
                    host,
                    sys,
                    out: &mut out,
                };
                Ps1Step(s).run(&mut ctx, mode)
            };
            (o, String::from_utf8(out).unwrap())
        };
        let home = TempDir::new("ps1-home");
        let allow = Roots::from_home(home.path())
            .local_app_data
            .join("dotfiles/sshd/allow.json");
        // check: 鍵の写しの行・ユーザーと送り元の写しの行・ps1 の行の順。写しは置かない
        let sys0 = sys((0, vec![header_line(s), "揃っている".into()]), (9, vec![]));
        let (o, _) = go(&sys0, Mode::Check, &runner_host, home.path());
        assert_eq!(o.len(), 3, "{o:?}");
        assert!(o[0].text.starts_with("鍵の写しが無い → apply で置く"));
        assert!(
            o[1].text
                .starts_with("ユーザーと送り元の写しが無い → apply で置く"),
            "{}",
            o[1].text
        );
        assert_eq!(o[2], Outcome::new(Kind::Ok, "揃っている"));
        assert!(!allow.exists());
        // apply: 写しを置いてから -Check
        let sys1 = sys((0, vec![header_line(s), "揃っている".into()]), (9, vec![]));
        let (o, out) = go(&sys1, APPLY, &runner_host, home.path());
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃っている")]);
        assert!(
            out.contains("ユーザーと送り元の写しを置きました (allowUsers = alice・allowFrom = 100.64.0.1・::1)"),
            "{out}"
        );
        assert_eq!(
            std::fs::read_to_string(&allow).unwrap(),
            super::super::sshd_allow::copy_text(
                Some(&["alice".to_string()]),
                Some(&["100.64.0.1".to_string(), "::1".to_string()])
            )
        );
        // PowerShell が無くても、写しは先に揃える (値を外すと写しを消す)
        let nopwsh = FakeSys::new(|_| unreachable!());
        let (o, out) = go(
            &nopwsh,
            APPLY,
            "[runner]\nenable = true\n[tools]\nwindowsSshd = true\n",
            home.path(),
        );
        assert!(out.contains("ユーザーと送り元の写しを消しました"), "{out}");
        assert!(!allow.exists());
        assert_eq!(o.last().unwrap().kind, Kind::Failed);
        // 受け持ちが WSL のホスト: 写しに触らない (TOML の値は使わないと出す)
        std::fs::write(&allow, "x\n").unwrap();
        let sys2 = sys((0, vec![header_line(s), "揃っている".into()]), (9, vec![]));
        let (o, out) = go(
            &sys2,
            APPLY,
            "[tools]\nwindowsSshd = true\n[sshd]\nallowUsers = [\"alice\"]\n",
            home.path(),
        );
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃っている")]);
        assert!(
            out.contains("[sshd] allowUsers・allowFrom は使わない"),
            "{out}"
        );
        assert_eq!(std::fs::read_to_string(&allow).unwrap(), "x\n");
    }

    /// op-reason: 道具の switch (onePassword) で on/off。Install-OpReason.ps1 は -IfMissing を持たないので、3 (入っていない) も 1 (揃って
    /// いない。締めの行は見ない) も引数なしで流す (WSL の bootstrap-windows-op-reason.sh と同じ)。前に出す行は手順の字 (WSL と同じ字かは
    /// op_reason_parity が WSL の script を流して比べる)
    #[test]
    fn op_reason_installs_and_replaces_with_only_the_relay_argument() {
        let s = spec("op-reason");
        assert_eq!(s.gate, Gate::Tool("onePassword"));
        assert_eq!(s.order, 90);
        assert_eq!(s.script, "win/op-reason/Install-OpReason.ps1");
        let install_notice = s.install_notice.unwrap();
        let sync_notice = s.sync_notice.unwrap();
        let missing = (
            3,
            vec![
                header_line(s),
                "⚠️ op-reason が入っていない → Install-OpReason で入れる ⚠️".into(),
            ],
        );
        // 3: check は -Check (と中継の -SshRelay) だけで missing、dry-run は打つはずのもの (ps1 の名前) を出す
        let sys1 = sys(missing.clone(), (9, vec![]));
        let (o, _, calls) = run("op-reason", &sys1, Mode::Check);
        assert_eq!(
            o,
            vec![Outcome::new(
                Kind::Missing,
                "入っていない → apply で入れる (Install-OpReason.ps1)"
            )]
        );
        assert_eq!(ends(&calls), vec![OFF_CHECK]);
        let sys2 = sys(missing.clone(), (9, vec![]));
        let (o, out, calls) = run("op-reason", &sys2, Mode::DryRun { force: false });
        assert_eq!(o[0].kind, Kind::Missing);
        assert!(
            out.contains("[dry-run] Install-OpReason.ps1 を流す (入れる)\n"),
            "{out}"
        );
        assert_eq!(ends(&calls), vec![OFF_CHECK]);
        // 3 → apply は -SshRelay だけで入れ、手順の字の前置きと入れた後の行を出す
        let sys3 = sys(missing.clone(), (0, vec!["揃った".into()]));
        let (o, out, calls) = run("op-reason", &sys3, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")]);
        assert_eq!(ends(&calls), vec![OFF_CHECK, OFF]);
        assert!(calls[1].contains("Install-OpReason.ps1' -SshRelay 'off'; exit $LASTEXITCODE"));
        assert!(out.contains(&format!("{install_notice}\n")), "{out}");
        assert!(!out.contains("秒まで待ちます"), "{out}");
        for l in s.installed {
            assert!(out.contains(&format!("{l}\n")), "{out}");
        }
        // 1: 締めの行が無くても (WSL は見ない) -SshRelay だけで入れ替える。check は fix
        let drift = (
            1,
            vec![
                header_line(s),
                "⚠ 固定した版 : 0.3.0 → 入れ替える (上げる)".into(),
            ],
        );
        let sys4 = sys(drift.clone(), (9, vec![]));
        let (o, _, calls) = run("op-reason", &sys4, Mode::Check);
        assert_eq!(
            o,
            vec![Outcome::new(
                Kind::Fix,
                "固定した版と揃っていない → apply で揃える (Install-OpReason.ps1)"
            )]
        );
        assert_eq!(ends(&calls), vec![OFF_CHECK]);
        let sys5 = sys(drift.clone(), (0, vec!["揃った".into()]));
        let (o, out, calls) = run("op-reason", &sys5, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃えた")]);
        assert_eq!(ends(&calls), vec![OFF_CHECK, OFF]);
        assert!(out.contains(&format!("{sync_notice}\n")), "{out}");
        for l in s.synced {
            assert!(out.contains(&format!("{l}\n")), "{out}");
        }
        // 揃えられない (動いている op-reason.exe で止まった・落とせない): failed。直し方は PowerShell と apply で、op の呼び出しが終わってから
        for (check, did) in [(missing, "入れられなかった"), (drift, "揃えられなかった")]
        {
            let sys6 = sys(
                check,
                (
                    1,
                    vec!["op-reason.exe が動いていて置き場所を入れ替えられない。".into()],
                ),
            );
            let (o, _, calls) = run("op-reason", &sys6, APPLY);
            assert_eq!(o.len(), 1);
            assert_eq!(o[0].kind, Kind::Failed);
            assert_eq!(o[0].text, format!("{did} (終了コード 1。上の出力を見る)"));
            assert_eq!(ends(&calls), vec![OFF_CHECK, OFF]);
            assert!(
                o[0].notes
                    .iter()
                    .any(|n| n.contains("PowerShell で Install-OpReason を打つ")
                        && n.contains("dotfiles apply --steps op-reason")
                        && n.contains("op の呼び出しが終わってから")),
                "{:?}",
                o[0].notes
            );
        }
        // 0: 揃っている
        let sys7 = sys((0, vec![header_line(s), "揃っている".into()]), (9, vec![]));
        let (o, out, calls) = run("op-reason", &sys7, APPLY);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃っている")]);
        assert_eq!(ends(&calls), vec![OFF_CHECK]);
        assert!(out.contains(&format!("{}\n", s.ok_text)), "{out}");
        // -Check の時間切れ: -Check はネットワークも winget も使わないので、winget の見込みは添えない
        let sys8 = sys((-1, vec![]), (9, vec![]));
        let (o, _, calls) = run("op-reason", &sys8, APPLY);
        assert_eq!(o[0].kind, Kind::Failed);
        assert!(
            o[0].text.contains("60 秒たっても終わらなかった"),
            "{}",
            o[0].text
        );
        assert!(!o[0].text.contains("winget"), "{}", o[0].text);
        assert_eq!(ends(&calls), vec![OFF_CHECK]);
    }

    /// 中継の switch が off のホスト (ファイルが無いときも) の op-reason の引数
    const OFF_CHECK: &str = "-Check -SshRelay 'off'";
    const OFF: &str = "-SshRelay 'off'";
    /// 中継を使うホスト (1Password の switch も要る)
    const RELAY_ON: &str = "[tools]\nonePassword = true\nopReasonSshRelay = true\nprivateRepos = true\n[runner]\nenable = true\n";

    /// op-reason は、中継の switch が on ならモードを、off なら off を、-Check にも揃える流れにも -SshRelay で渡す
    #[test]
    fn op_reason_passes_the_ssh_relay_switch() {
        let s = spec("op-reason");
        let drift = (
            1,
            vec![
                header_line(s),
                "⚠ 固定した版 : 0.3.0 → 入れ替える (上げる)".into(),
            ],
        );
        let show_only = format!("{RELAY_ON}[opReason]\nsshRelayMode = \"show-only\"\n");
        let off_switch =
            "[tools]\nonePassword = true\nopReasonSshRelay = false\n[runner]\nenable = true\n";
        for (host, mode) in [
            (RELAY_ON, "per-call"),
            (show_only.as_str(), "show-only"),
            (off_switch, "off"),
            // 1Password が off なら中継は効かない (groups.nix の requires)。手順そのものは走らせて確かめる
            (
                "[tools]\nopReasonSshRelay = true\nprivateRepos = true\n[runner]\nenable = true\n",
                "off",
            ),
        ] {
            let sys1 = sys(drift.clone(), (0, vec!["揃った".into()]));
            let (o, _, calls) = run_host("op-reason", &sys1, APPLY, Some(host));
            assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃えた")], "{host}");
            assert_eq!(
                ends(&calls),
                vec![
                    format!("-Check -SshRelay '{mode}'"),
                    format!("-SshRelay '{mode}'")
                ],
                "{host}"
            );
            // check と dry-run も、-Check に同じ -SshRelay を渡す
            for m in [Mode::Check, Mode::DryRun { force: false }] {
                let sys2 = sys(drift.clone(), (9, vec![]));
                let (_, _, calls) = run_host("op-reason", &sys2, m, Some(host));
                assert_eq!(
                    ends(&calls),
                    vec![format!("-Check -SshRelay '{mode}'")],
                    "{host} {m:?}"
                );
            }
        }
        // 受け持ちが WSL のホスト (runner は check だけ) も、同じ引数で確かめる
        let sys3 = sys(drift.clone(), (9, vec![]));
        let (_, _, calls) = run_host(
            "op-reason",
            &sys3,
            Mode::Check,
            Some("[tools]\nonePassword = true\nopReasonSshRelay = true\nprivateRepos = true\n"),
        );
        assert_eq!(ends(&calls), vec!["-Check -SshRelay 'per-call'"]);
        // ほかの手順には渡さない
        let n = spec("ntn");
        let sys4 = sys((0, vec![header_line(n)]), (9, vec![]));
        let (_, _, calls) = run_host("ntn", &sys4, Mode::Check, Some(RELAY_ON));
        assert_eq!(ends(&calls), vec!["-Check"]);
        // 確かめられないときに手で打つ -Check にも、中継のモードを添える
        let sys5 = sys((-1, vec![]), (9, vec![]));
        let (o, _, _) = run_host("op-reason", &sys5, Mode::Check, Some(RELAY_ON));
        assert!(
            o[0].notes
                .iter()
                .any(|n| n
                    .contains("PowerShell で Install-OpReason -Check -SshRelay per-call を打つ")),
            "{:?}",
            o[0].notes
        );
        let sys6 = sys((-1, vec![]), (9, vec![]));
        let (o, _, _) = run_host("op-reason", &sys6, Mode::Check, Some(off_switch));
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("PowerShell で Install-OpReason -Check を打つ")),
            "{:?}",
            o[0].notes
        );
    }

    /// 版は揃っていて SSH の中継だけが違う (ps1 の締めの行「SSH の中継が揃っていない」) なら、行と前に出す行を中継の字にする
    #[test]
    fn op_reason_names_the_relay_when_only_the_relay_differs() {
        let s = spec("op-reason");
        let relay_only = (
            1,
            vec![
                header_line(s),
                "  固定した版       : 0.5.0 → そのまま".into(),
                "SSH の中継 (op-reason の task \\op-reason-ssh-relay-S-1-5-21-1-2-3-1001)".into(),
                "⚠ relay.autostart  : off → on".into(),
                "⚠️ SSH の中継が揃っていない → Install-OpReason -SshRelay per-call で揃える ⚠️"
                    .into(),
            ],
        );
        let sys1 = sys(relay_only.clone(), (9, vec![]));
        let (o, _, _) = run_host("op-reason", &sys1, Mode::Check, Some(RELAY_ON));
        assert_eq!(
            o,
            vec![Outcome::new(
                Kind::Fix,
                "SSH の中継が揃っていない → apply で揃える (Install-OpReason.ps1)"
            )]
        );
        let sys2 = sys(relay_only.clone(), (0, vec!["揃った".into()]));
        let (o, out, calls) = run_host("op-reason", &sys2, APPLY, Some(RELAY_ON));
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "揃えた")]);
        assert_eq!(
            ends(&calls),
            vec!["-Check -SshRelay 'per-call'", "-SshRelay 'per-call'"]
        );
        assert!(
            out.contains("Windows の op-reason の SSH の中継 (op-reason の task) が揃っていないので、揃えます (Install-OpReason.ps1)。\n"),
            "{out}"
        );
        assert!(
            out.contains("Windows の op-reason の SSH の中継を揃えました。\n"),
            "{out}"
        );
        assert!(!out.contains(s.sync_notice.unwrap()), "{out}");
        // 揃えられない (中継が窓を開いている・答えない): 版の字のまま failed (直し方は上の出力と、op の呼び出しが終わってから)
        let sys3 = sys(
            relay_only,
            (
                1,
                vec!["SSH の中継が窓を開いている (か、1Password の確認を待っている) ので、中継を止めない。".into()],
            ),
        );
        let (o, _, _) = run_host("op-reason", &sys3, APPLY, Some(RELAY_ON));
        assert_eq!(o.len(), 1);
        assert_eq!(o[0].kind, Kind::Failed);
        assert_eq!(o[0].text, "揃えられなかった (終了コード 1。上の出力を見る)");
    }

    /// 前に出す行を持たない手順は、ps1 の手順の型の字 (どの手順の前置きか・待つ秒数) を出す
    #[test]
    fn generic_notices_name_the_package_and_the_wait() {
        let s = spec("type-clipboard");
        assert_eq!(s.install_notice, None);
        let sys1 = sys((3, vec![header_line(s)]), (0, vec![]));
        let (_, out, _) = run("type-clipboard", &sys1, APPLY);
        assert!(
            out.contains("Windows に type-clipboard (GitHub の Release) が入っていないので、固定した版を入れます (Install-TypeClipboard.ps1 -IfMissing。300 秒まで待ちます)。\n"),
            "{out}"
        );
        let s = spec("ntn");
        assert_eq!(s.sync_notice, None);
        let sys2 = sys(
            (
                1,
                vec![
                    header_line(s),
                    "⚠️ 固定した版と揃っていない → Install-Ntn で揃える ⚠️".into(),
                ],
            ),
            (0, vec![]),
        );
        let (_, out, _) = run("ntn", &sys2, APPLY);
        assert!(
            out.contains("Windows の ntn が固定した版と揃っていないので、揃えます (Install-Ntn.ps1。600 秒まで待ちます)。\n"),
            "{out}"
        );
        // -Check の時間切れ: winget の見込みを添える
        let sys3 = sys((-1, vec![]), (0, vec![]));
        let (o, _, _) = run("ntn", &sys3, Mode::Check);
        assert_eq!(
            o[0].text,
            "Install-Ntn.ps1 -Check が 120 秒たっても終わらなかった (時間切れ。winget の応答が止まっているかもしれない)"
        );
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

    /// openssh: 1Password の SSH agent を使わないホスト (道具の switch onePassword が off。minimum の既定) では、-Check にも入れる流れにも
    /// -NoOnePassword を渡し、入れた後の 1Password の行を出さない。手で打つ直し方のコマンドにも -NoOnePassword を添える。on のホストは今のまま
    #[test]
    fn openssh_leaves_out_1password_on_hosts_without_it() {
        let s = spec("openssh");
        assert_eq!(s.gate, Gate::Tool("windowsOpenssh"));
        let missing = (
            3,
            vec![
                header_line(s),
                "⚠️ OpenSSH が入っていない → Install-OpenSSH -IfMissing で入れる (UAC が 1 回出る) ⚠️".into(),
            ],
        );
        let off = Some("[runner]\nenable = true\n");
        let sys1 = sys(missing.clone(), (0, vec!["入れた".into()]));
        let (o, out, calls) = run_host("openssh", &sys1, APPLY, off);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")]);
        assert_eq!(
            ends(&calls),
            vec!["-Check -NoOnePassword", "-IfMissing -NoOnePassword"]
        );
        assert!(out.contains(&format!("{}\n", s.installed[0])), "{out}");
        assert!(!out.contains("1Password"), "{out}");
        // 揃っていない (知らせるだけ)・入れられなかったときの直し方
        let sys2 = sys((1, vec![header_line(s)]), (0, vec![]));
        let (o, _, _) = run_host("openssh", &sys2, APPLY, off);
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("PowerShell で Install-OpenSSH -NoOnePassword を打つ")),
            "{o:?}"
        );
        let sys3 = sys(missing.clone(), (1, vec![]));
        let (o, _, _) = run_host("openssh", &sys3, APPLY, off);
        assert!(
            o[0].notes
                .iter()
                .any(|n| n
                    .contains("PowerShell で Install-OpenSSH -IfMissing -NoOnePassword を打つ")),
            "{o:?}"
        );
        // on: 渡さず、入れた後に 1Password の行を出す
        let on = Some("[runner]\nenable = true\n[tools]\nonePassword = true\n");
        let sys4 = sys(missing, (0, vec!["入れた".into()]));
        let (o, out, calls) = run_host("openssh", &sys4, APPLY, on);
        assert_eq!(o, vec![Outcome::new(Kind::Ok, "入れた")]);
        assert_eq!(ends(&calls), vec!["-Check", "-IfMissing"]);
        assert!(
            out.contains(&format!("{ONE_PASSWORD_INSTALLED}\n")),
            "{out}"
        );
        let sys5 = sys((1, vec![header_line(s)]), (0, vec![]));
        let (o, _, _) = run_host("openssh", &sys5, APPLY, on);
        assert!(
            o[0].notes
                .iter()
                .any(|n| n.contains("PowerShell で Install-OpenSSH を打つ")),
            "{o:?}"
        );
        // ほかの手順には渡さない
        assert!(
            SPECS
                .iter()
                .filter(|x| x.one_password)
                .map(|x| x.id)
                .eq(["openssh"])
        );
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
        // Windows にしか無い手順 (t3-code) は WSL の wrapper を持たない
        for s in SPECS.iter().filter(|s| !s.windows_only) {
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

    /// -EncodedCommand の本文を、PowerShell の [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(…)) と同じ字にする
    #[test]
    fn encodes_commands_like_powershell() {
        // [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('…')) と同じ字
        assert_eq!(encode_command(""), "");
        assert_eq!(encode_command("a"), "YQA=");
        assert_eq!(encode_command("ab"), "YQBiAA==");
        assert_eq!(encode_command("abc"), "YQBiAGMA");
        assert_eq!(encode_command("日"), "5WU=");
        let body = "$x = \"user32.dll\"\n'ok'; 'ä😀'";
        let spec = encoded_command(PathBuf::from("powershell"), body, Duration::from_secs(5));
        assert_eq!(
            spec.args_lossy()[..5],
            [
                "-NoProfile",
                "-NonInteractive",
                "-OutputFormat",
                "Text",
                "-EncodedCommand"
            ]
        );
        assert_eq!(decode_command(&spec).as_deref(), Some(body));
    }

    /// 本物の PowerShell が、" と改行を含む本文を -EncodedCommand でそのまま流す。エラーは、Windows PowerShell 5.1 が -OutputFormat Text でも
    /// CLIXML (#< CLIXML) で返すことがあるので、plain_lines で平文の行に直して読む (進み具合は落ちる)
    #[cfg(windows)]
    #[test]
    fn real_powershell_runs_an_encoded_command() {
        use crate::process::{RealSys, Sys};
        let body = "$ProgressPreference = 'SilentlyContinue'; $q = \"user32.dll\"\nWrite-Output \"q=$q\"\n'done'";
        // $ProgressPreference を付けないので、初めて読むモジュールの進み具合も出うる
        let failing = "Write-Error 'boom'; 'after'";
        for shell in ["powershell", "pwsh"] {
            let Some(path) = RealSys.which(shell) else {
                continue;
            };
            let r = RealSys.run(
                &encoded_command(path.clone(), body, Duration::from_secs(60)),
                &mut |_| {},
            );
            assert_eq!(r.exit, Exit::Code(0), "{shell}: {:?}", r.output);
            assert_eq!(r.output, vec!["q=user32.dll", "done"], "{shell}");
            let r = RealSys.run(
                &encoded_command(path, failing, Duration::from_secs(60)),
                &mut |_| {},
            );
            let lines = plain_lines(&r.output);
            assert!(
                lines.iter().any(|l| l == "after"),
                "{shell}: {:?}",
                r.output
            );
            assert!(
                lines.iter().any(|l| l.contains("boom")),
                "{shell}: {:?}",
                r.output
            );
            assert!(
                !lines.iter().any(|l| l.contains("CLIXML")
                    || l.contains("<Objs")
                    || l.contains("Preparing modules")),
                "{shell}: {lines:?}"
            );
        }
    }

    /// Windows PowerShell 5.1 の CLIXML (Windows の CI で -OutputFormat Text -EncodedCommand の Write-Error から返ったもの) を、平文の行に直す
    #[test]
    fn plain_lines_reads_clixml() {
        let lines: Vec<String> = [
            "#< CLIXML",
            "after",
            "<Objs Version=\"1.1.0.1\" xmlns=\"http://schemas.microsoft.com/powershell/2004/04\"><Obj S=\"progress\" RefId=\"0\"><TN RefId=\"0\"><T>System.Management.Automation.PSCustomObject</T><T>System.Object</T></TN><MS><I64 N=\"SourceId\">1</I64><PR N=\"Record\"><AV>Preparing modules for first use.</AV><AI>0</AI><Nil /><PI>-1</PI><PC>-1</PC><T>Completed</T><SR>-1</SR><SD> </SD></PR></MS></Obj><S S=\"Error\">Write-Error 'boom'; 'after' : boom_x000D__x000A_</S><S S=\"Error\">    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException_x000D__x000A_</S><S S=\"Error\">    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException_x000D__x000A_</S><S S=\"Error\"> _x000D__x000A_</S></Objs>",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        assert_eq!(
            plain_lines(&lines),
            vec![
                "after",
                "Write-Error 'boom'; 'after' : boom",
                "    + CategoryInfo          : NotSpecified: (:) [Write-Error], WriteErrorException",
                "    + FullyQualifiedErrorId : Microsoft.PowerShell.Commands.WriteErrorException",
                " ",
            ]
        );
        // 進み具合だけなら何も出さない。CLIXML でない行 (先頭が <Objs でも、PowerShell の名前空間が無いもの) はそのまま
        let only_progress = vec![
            "#< CLIXML".to_string(),
            "<Objs Version=\"1.1.0.1\" xmlns=\"http://schemas.microsoft.com/powershell/2004/04\"><Obj S=\"progress\" RefId=\"0\"><MS><PR N=\"Record\"><AV>Preparing modules for first use.</AV></PR></MS></Obj></Objs>\r".to_string(),
            "<Objs x>".to_string(),
        ];
        assert_eq!(plain_lines(&only_progress), vec!["<Objs x>"]);
        // 警告などは頭を付ける。実体参照・_xHHHH_ (サロゲートの対も)・_x005F_ (字の _)・閉じていない (時間切れで切れた) もの
        let mixed = vec![
            "<Objs Version=\"1.1.0.1\" xmlns=\"http://schemas.microsoft.com/powershell/2004/04\"><S S=\"warning\">a &lt;b&gt; &amp; &quot;c&quot; &#x41;&#66; &amp;lt; _x005F_x0041_ _xD83D__xDE00_</S><S S=\"Error\">x &unknown; &; _x00_ _xZZZZ_ 末尾".to_string(),
        ];
        assert_eq!(
            plain_lines(&mixed),
            vec![
                "WARNING: a <b> & \"c\" AB &lt; _x0041_ 😀",
                "x &unknown; &; _x00_ _xZZZZ_ 末尾",
            ]
        );
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
