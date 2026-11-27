<#
.SYNOPSIS
Windows の Codex CLI (OpenAI のコーディング エージェントの CLI。winget の OpenAI.Codex の portable) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/codex/Install-Codex.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Codex から呼ぶ (win/README.md の「Codex CLI」)。
入れて揃えるのは Windows の runner の手順 codex (ホストの値の [tools] windowsCodex が on のマシンだけ。既定はグループで決まり、all で on)。

winget の OpenAI.Codex は zip の中の portable で、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の下に入る。置き場所の exe の
名前は codex-x86_64-pc-windows-msvc.exe (arm64 は codex-aarch64-pc-windows-msvc.exe) で、codex という名前は、winget が
%LOCALAPPDATA%\Microsoft\WinGet\Links に置く symlink (manifest の PortableCommandAlias) でだけ付く。winget は symlink を作れないと
(昇格していない winget は、開発者モードが off だと作れない)、symlink の代わりに置き場所をユーザーの PATH に足すだけにし、それでも
「Command line alias added: codex」と出す。その形では codex と打っても見つからない (codex-x86_64-pc-windows-msvc とは打てる)。
そこで、開発者モードが off なら winget を昇格した Windows PowerShell で打ち (UAC の確認が入れる・入れ直すときの 1 回だけ出る。昇格しても
同じユーザーなので、置き場所も symlink もこのユーザーのもの)、symlink を winget に作らせる。開発者モードが on か、もう昇格した会話なら、
そのまま打つ。symlink が無い形で入っていれば (前に手で winget install を打ったなど)、入れ直して作る。

codex は自分の置き場所の判定 (同梱の rg.exe と codex-resources を使うか) と、sandbox の helper (codex-command-runner.exe など) を探すのに、
実体の exe のパスと名前を使う (symlink は実体へたどる)。hardlink や名前を替えた写しでは判定が外れるので作らない。

winget の manifest の依存 (BurntSushi.ripgrep.MSVC と Microsoft.VCRedist.2015+) は入れない (--skip-dependencies)。codex の exe は
VC++ のランタイムを使わず (CRT を静的に持つ)、rg.exe は zip の中 (codex-path\rg.exe) にあって codex がそれを使う。VCRedist は machine に
入るので、入れると開発者モードの PC でも UAC の確認が出る。

codex.exe が動いている間は置き換えられないので、入れ替えが要るときに置き場所の exe が動いていれば、何も変えずに止める (止めはしない)。
形は Install-Fzf.ps1 と同じ (常駐が無いので、版のずれも揃える)。違うのは、symlink を見ることと、そのために昇格した winget を使うこと。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id OpenAI.Codex --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3
(winget が symlink を作れない PC (管理者でなく、開発者モードも off) では、入っていなくても 1)。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.170.0',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Codex.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# codex --version の出力 ("codex-cli <版>") から版を拾う。無ければ $null
function Get-CodexVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(codex(-cli)?\s+)?v?(\d+(\.\d+)+)(\s|$)') { return $Matches[3] }
    }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う (Install-Fzf.ps1 と同じ)。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# WinGet\Links の codex.exe が、置き場所の exe への symlink か。ok (そう) / missing (無い) / wrong (ほかを指す・symlink でない)。
# Target は Get-Item の Target (5.1 は配列、7 は文字列。呼ぶ側が 1 つにする)。比べるのは大文字小文字を区別しない (Windows のパスと同じ)
function Get-CodexLinkState {
    param([bool]$Exists, [string]$LinkType, [string]$Target, [string]$ExePath)
    if (-not $Exists) { return 'missing' }
    if ($LinkType -ne 'SymbolicLink') { return 'wrong' }
    if (-not $Target -or -not $ExePath) { return 'wrong' }
    if ($Target.TrimEnd('\') -eq $ExePath.TrimEnd('\')) { return 'ok' }
    'wrong'
}

# winget を昇格して打つか。direct (そのまま打っても symlink を作れる: 昇格した会話か、開発者モードが on) / elevated (このユーザーが
# 管理者なので、UAC で昇格した winget に作らせる) / blocked (管理者でなく、開発者モードも off。UAC で別のアカウントに昇格すると、
# 置き場所がそのアカウントのものになるので昇格しない。そのまま打っても symlink を作れない)
function Get-CodexInstallRoute {
    param([bool]$Elevated, [bool]$DeveloperMode, [bool]$Admin)
    if ($Elevated -or $DeveloperMode) { return 'direct' }
    if ($Admin) { return 'elevated' }
    'blocked'
}

# whoami /groups /fo csv /nh の出力に、Administrators (S-1-5-32-544) の行があるか。昇格していない管理者の token にも、
# 拒否にだけ使う形 (Group used for deny only) で並ぶ。管理者でないユーザーには無い
function Test-AdminMember {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '(^|,)"S-1-5-32-544"(,|$)') { return $true }
    }
    $false
}

# 入っているか・入っている版・固定した版・symlink から、することを決める。exe があるのに版が読めないときも入れ替える。
# 版が揃っていて symlink だけが無い・違うときは relink (同じ版を入れ直して、winget に symlink を作らせる)
function Get-CodexPlan {
    param([bool]$Exists, [string]$Installed, [string]$Target, [string]$LinkState)
    if (-not $Exists) { return 'install' }
    if ($Installed -cne $Target) { return 'change' }
    if ($LinkState -ne 'ok') { return 'relink' }
    'none'
}

# 入れ替えの向き。winget show --versions の並び (新しい順) の位置で比べる (Install-Fzf.ps1 と同じ)
function Get-CodexDirection {
    param([string[]]$Versions, [string]$Installed, [string]$Target)
    $list = @($Versions)
    $i = [array]::IndexOf($list, $Installed)
    $t = [array]::IndexOf($list, $Target)
    if ($i -lt 0 -or $t -lt 0) { return 'unknown' }
    if ($t -lt $i) { return 'up' }
    if ($t -gt $i) { return 'down' }
    'same'
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-Fzf.ps1 と同じ)。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。入れ替え・入れ直しは、外してから入れる (portable の置き場所は版によらず同じ。codex の
# 設定とログイン (%USERPROFILE%\.codex) は置き場所の外にある)。install は portable を名指しし、user スコープで入れ (昇格した winget が
# machine スコープを選ばないように)、manifest の依存 (ripgrep・VCRedist) は入れない (頭の説明)
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    $put = $common + @('--version', $Version, '--installer-type', 'portable', '--scope', 'user', '--skip-dependencies',
        '--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        { $_ -in @('change', 'relink') } {
            , (@('uninstall') + $common)
            , (@('install') + $put)
        }
    }
}

# 入れ替え・入れ直しの前に、固定した版の取得とハッシュだけを確かめる winget download の引数 (Install-Fzf.ps1 と同じ)
function Get-WingetDownloadArguments {
    param([string]$PackageId, [string]$Version, [string]$Directory)
    @('download', '--id', $PackageId, '--exact', '--source', 'winget', '--version', $Version,
        '--installer-type', 'portable', '--download-directory', $Directory, '--skip-dependencies',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
}

# PATH (; 区切り) を前から見て、$Names のどれかが最初に見つかったパスを返す。無ければ $null (Install-Fzf.ps1 と同じ)。
# PowerShell は PATH のディレクトリの順に、.exe だけでなく .cmd・.bat・.ps1 も引くので、ディレクトリごとに名前を並べて見る。
# $Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Resolve-CodexOnPath {
    param([string]$PathValue, [string[]]$Names, [scriptblock]$Exists)
    foreach ($entry in ($PathValue -split ';')) {
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if (-not $dir) { continue }
        foreach ($name in $Names) {
            $candidate = "$dir\$name"
            if (& $Exists $candidate) { return $candidate }
        }
    }
    $null
}

# PATH で引かれる codex がどこのものか。'winget' (WinGet\Links の codex.exe) / 'other' (npm の codex.cmd・公式の install.ps1 の
# codex.exe など) / 'none'
function Get-CodexPathKind {
    param([string]$Resolved, [string]$LinksDir)
    if (-not $Resolved) { return 'none' }
    # -eq は大文字小文字を区別しない (Windows のパスと同じ)
    if ($LinksDir -and ($Resolved -eq "$($LinksDir.TrimEnd('\'))\codex.exe")) { return 'winget' }
    'other'
}

# 揃える手順 (Install-Codex) で直す差 (版・pin・symlink) があるか
function Test-CodexDrift {
    param($State)
    ($State.Plan -ne 'none') -or (-not $State.Pinned)
}

# PATH のずれ (ほかの codex が先に引かれる・symlink はあるのに PATH で見つからない) があるか。揃える手順では直らないので、※ の行で
# 直し方を添える。入れる・入れ直す前 (symlink が無い) に見つからないのは当たり前なので数えない
function Test-CodexPathDrift {
    param($State)
    ($State.PathKind -eq 'other') -or (($State.PathKind -eq 'none') -and ($State.Plan -notin @('install', 'relink')))
}

# 入れる・入れ直すのに、winget が symlink を作れない (管理者でなく、開発者モードも off) か。揃える手順では直らない (人が開発者モードを
# on にする)。版が揃っていて symlink があれば、入れ直さないので当たらない
function Test-CodexBlocked {
    param($State)
    ($State.Route -eq 'blocked') -and ($State.Plan -in @('install', 'change', 'relink'))
}

# 終了コード。winget が symlink を作れないなら 1 (入っていなくても 3 にしない。runner が -IfMissing で入れにいかないように)、
# 入っていなければ 3、版・pin・symlink・PATH が揃っていれば 0、ほかは 1
function Get-CodexExitCode {
    param($State)
    if (Test-CodexBlocked -State $State) { return 1 }
    if ($State.Plan -eq 'install') { return 3 }
    if ((Test-CodexDrift -State $State) -or (Test-CodexPathDrift -State $State)) { return 1 }
    0
}

# 揃える前に止める理由。無ければ $null
#   blocked:    入れる・入れ直すのに、winget が symlink を作れない (入れても codex と打てない)
#   not-listed: 入れる・入れ替えるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
#   busy:       入れ替える・入れ直すのに、置き場所の exe が動いている (置き換えられない)
function Get-CodexApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target, [int]$BusyCount, [string]$Route)
    if (($Route -eq 'blocked') -and ($Plan -in @('install', 'change', 'relink'))) { return 'blocked' }
    $known = @($Versions | Where-Object { $_ })
    if (($Plan -ne 'none') -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    if (($Plan -in @('change', 'relink')) -and ($BusyCount -gt 0)) { return 'busy' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。ずれではないこと
# (新しい版がある・動いている codex がある・昇格して打つ) は ※ で添える
function Format-CodexState {
    param($State, [string]$Target, [string]$PackageId, [string]$PackageDir)
    $direction = if ($State.Direction -eq 'up') { ' (上げる)' } elseif ($State.Direction -eq 'down') { ' (下げる)' } else { '' }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'change' { "入れ替える$direction" }
        default { 'そのまま' }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($State.Installed) { $State.Installed } else { '不明 (codex --version が読めない)' }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $exeName = if ($State.ExeName) { $State.ExeName } else { 'codex-x86_64-pc-windows-msvc.exe' }
    $linkText = switch ($State.LinkState) {
        'ok' { "WinGet\Links\codex.exe (置き場所の $exeName への symlink)" }
        'wrong' { "WinGet\Links\codex.exe が置き場所の exe を指していない ($($State.LinkTarget)) → 入れ直す" }
        default {
            if ($State.Plan -eq 'install') { '入れるときに winget が WinGet\Links\codex.exe を作る' }
            else { '無い → 入れ直す (winget が symlink を作れずに、置き場所を PATH に足した形。codex と打っても見つからない)' }
        }
    }
    $pathText = switch ($State.PathKind) {
        'winget' { 'winget の symlink (WinGet\Links\codex.exe)' }
        'other' { "$($State.PathResolved) (winget の symlink ではない)" }
        default { '見つからない' }
    }
    $rows = @(
        @{ Text = "Codex CLI (winget の $PackageId、$PackageDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -in @('install', 'change')); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
        @{ Text = "codex の別名    : $linkText"; Warn = (($State.Plan -ne 'install') -and ($State.LinkState -ne 'ok')); Indent = $true }
        @{ Text = "PATH の codex   : $pathText"; Warn = (Test-CodexPathDrift -State $State); Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    $versions = @($State.Versions | Where-Object { $_ })
    if (($versions.Count -gt 0) -and ($versions -cnotcontains $Target)) {
        if ($State.Plan -in @('none', 'relink')) {
            [pscustomobject]@{ Text = '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える'; Warn = $false }
        } else {
            [pscustomobject]@{ Text = '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない'; Warn = $true }
        }
    } elseif (($versions.Count -gt 0) -and ($versions[0] -cne $Target)) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-Codex.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    if (Test-CodexBlocked -State $State) {
        [pscustomobject]@{ Text = '⚠ winget が codex の symlink を作れない (このアカウントは管理者でなく、開発者モードも off)。入れても codex と打てないので、Install-Codex は入れない'; Warn = $true }
        [pscustomobject]@{ Text = '※ 管理者に開発者モードを on にしてもらい (設定 > システム > 開発者向け)、Install-Codex を打ち直す (win/README.md の「Codex CLI」)'; Warn = $false }
    } elseif (($State.Route -eq 'elevated') -and ($State.Plan -in @('install', 'change', 'relink'))) {
        [pscustomobject]@{ Text = '※ 開発者モードが off なので、Install-Codex は winget を UAC で昇格して打つ (昇格しない winget は symlink を作れず、codex と打てない形で入る)'; Warn = $false }
    }
    if ($State.PathKind -eq 'other') {
        # PATH のずれは揃える手順 (Install-Codex) では直らないので、直し方を添える
        $cut = $State.PathResolved.LastIndexOf('\')
        $dir = if ($cut -ge 0) { $State.PathResolved.Substring(0, $cut) } else { $State.PathResolved }
        [pscustomobject]@{ Text = "※ PATH のずれは Install-Codex では直らない。$dir の codex を外す (npm の @openai/codex なら npm uninstall -g @openai/codex) か、$dir をユーザーの PATH から外す (win/README.md の「Codex CLI」)"; Warn = $false }
    } elseif (($State.PathKind -eq 'none') -and ($State.Plan -notin @('install', 'relink'))) {
        [pscustomobject]@{ Text = '※ WinGet\Links がユーザーの PATH に無い。%LOCALAPPDATA%\Microsoft\WinGet\Links をユーザーの PATH に足し、新しい PowerShell を開く'; Warn = $false }
    }
    if (($State.Plan -in @('change', 'relink')) -and ($State.BusyCount -gt 0)) {
        [pscustomobject]@{ Text = "※ codex が $($State.BusyCount) 個動いている。入れ替えるには、動いている codex (ほかの端末の会話など) を終わらせる"; Warn = $false }
    }
}

# 締めの行 (-Check の最後と、揃えた後の最後)。揃っていれば何も返さない。直すことごとに ⚠️ で始まる行を返す。
# Windows の runner (win/runner/src/steps/ps1.rs) は「→ Install-Codex で入れる」「→ Install-Codex で揃える」「→ ※ の手順で直す」の
# 文言で、入れるか・揃えるか・知らせるだけかを決め、symlink を作れない行 (「winget が codex の symlink を作れない」) で直し方を選ぶ
# (文言を変えるときは向こうも直す)。symlink を作れないなら、その 1 行だけ (入れも入れ直しもしない)
function Format-CodexVerdict {
    param($State)
    if (Test-CodexBlocked -State $State) {
        '⚠️ winget が codex の symlink を作れない (管理者でなく、開発者モードも off) → ※ の手順で直す ⚠️'
        return
    }
    if ($State.Plan -eq 'install') {
        '⚠️ Codex CLI が入っていない → Install-Codex で入れる ⚠️'
        return
    }
    if (($State.Plan -eq 'change') -or (-not $State.Pinned)) { '⚠️ 固定した版と揃っていない → Install-Codex で揃える ⚠️' }
    if ($State.LinkState -ne 'ok') { '⚠️ codex と打てない (WinGet\Links に codex.exe の symlink が無い) → Install-Codex で揃える ⚠️' }
    if (Test-CodexPathDrift -State $State) { '⚠️ PATH の codex が winget の symlink ではない → ※ の手順で直す ⚠️' }
}

# 昇格した winget を起こせなかったとき (Start-Process -Verb RunAs の例外) の終了コード。UAC で断った (Win32Exception の ERROR_CANCELLED。
# Start-Process は InvalidOperationException に包む) なら 1223、ほか (UAC を出せない SSH の会話など) は -1 (Install-Bootstrap.ps1 と同じ)
function Get-ElevationFailureCode {
    param([Exception]$Exception)
    $e = $Exception
    while ($null -ne $e) {
        if (($e -is [System.ComponentModel.Win32Exception]) -and ($e.NativeErrorCode -eq 1223)) { return 1223 }
        $e = $e.InnerException
    }
    -1
}

# winget の出力の行から、進み具合の表示 (回る棒・帯 █▒) を除く (Install-Bootstrap.ps1 と同じ)
function Select-WingetOutputLines {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $s = "$line"
        if (($s -notmatch '^\s*[-\\|/]?\s*$') -and ($s -notmatch '[\u2588\u2592]')) { $s }
    }
}

# PowerShell の一重引用符の文字列にする (中の ' を重ねる。全角の引用符も PowerShell は ' と読むので重ねる。Install-Bootstrap.ps1 と同じ)
function ConvertTo-PsLiteral {
    param([string]$Text)
    $quotes = @([char]0x27, [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in "$Text".ToCharArray()) {
        [void]$sb.Append($c)
        if ($quotes -contains $c) { [void]$sb.Append($c) }
    }
    "'" + $sb.ToString() + "'"
}

# PowerShell の本文を -EncodedCommand に渡す形 (UTF-16LE の base64) にする
function ConvertTo-EncodedCommand {
    param([string]$Script)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

# 昇格した Windows PowerShell に渡す本文 (Windows PowerShell 5.1 の書き方だけ)。1 行目に昇格した側のアカウントを書き、そのアカウントの
# winget (実行エイリアス %LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe、無ければ PATH の winget の .exe だけ。関数・alias・.cmd・.ps1 は
# 管理者の権限で流さない) で $Commands を上から打ち、出力 (stderr も) を UTF-8 で読んで $LogPath に UTF-8 で書き足す。0 で終わらない
# winget があれば、そこで止めてその終了コードで終わる (外した後に入れられなかったときも、Install-Codex が読み直して知らせる)。
# winget が無い・起こせなければ、わけを書いて 2 で終わる ($LASTEXITCODE を先に 2 にしておく。起こせないまま exit に届くと 0 で終わり、
# 入ったように見える)。Start-Process -Verb RunAs は昇格した process の出力を受け取れないので、ファイルで返す
function Get-ElevatedWingetScript {
    param([object[]]$Commands, [string]$LogPath)
    $log = ConvertTo-PsLiteral -Text $LogPath
    $lines = @(
        "`$ErrorActionPreference = 'Continue'"
        '$global:LASTEXITCODE = 2'
        'try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }'
        "('account: ' + `$env:USERNAME) | Out-File -LiteralPath $log -Encoding utf8"
        '$w = $null'
        'if ($env:LOCALAPPDATA) {'
        "    `$alias = Join-Path `$env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'"
        '    if (Test-Path -LiteralPath $alias) { $w = $alias }'
        '}'
        'if (-not $w) {'
        '    $found = @(Get-Command -Name winget -CommandType Application -ErrorAction SilentlyContinue | Where-Object { "$($_.Source)" -like ''*.exe'' })'
        '    if ($found.Count -gt 0) { $w = $found[0].Source }'
        '}'
        'if (-not $w) {'
        "    ('winget が見つからない (昇格した側のアカウント: ' + `$env:USERNAME + ')') | Out-File -LiteralPath $log -Encoding utf8 -Append"
        '    exit 2'
        '}'
        '$commands = @()'
    )
    foreach ($command in $Commands) {
        $lines += '$commands += , @(' + (@($command | ForEach-Object { ConvertTo-PsLiteral -Text $_ }) -join ', ') + ')'
    }
    $lines += @(
        '$code = 0'
        'foreach ($c in $commands) {'
        "    ('> winget ' + (`$c -join ' ')) | Out-File -LiteralPath $log -Encoding utf8 -Append"
        '    try {'
        "        & `$w @c 2>&1 | ForEach-Object { `"`$_`" } | Out-File -LiteralPath $log -Encoding utf8 -Append"
        '        $code = $LASTEXITCODE'
        '    } catch {'
        "        ('winget を起こせなかった: ' + `$_.Exception.Message) | Out-File -LiteralPath $log -Encoding utf8 -Append"
        '        $code = 2'
        '    }'
        '    if ($code -ne 0) { break }'
        '}'
        'exit $code'
    )
    $lines -join "`n"
}

# 昇格した側のログの 1 行目 (account: <名前>) から、昇格した側のアカウントを読む。無ければ $null
function Get-ElevatedAccount {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*account:\s*(.+?)\s*$') { return $Matches[1] }
    }
    $null
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す。winget は管へ UTF-8 で書くので、コンソールの文字コードが UTF-8 でなければ
# 打つ間だけ UTF-8 にする (日本語の Windows の既定は CP932。手で打った窓・UAC で昇格し直した子の窓。そのまま読むと進み具合の帯と日本語の
# メッセージが化ける。runner と WSL の wrapper は UTF-8 にしてから流すので替えない)。本文は Install-OpenSSH.ps1 の Invoke-Winget と同じ
# (Install-OpenSSH.Tests.ps1 が突き合わせる)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $saved = $null
    try {
        if ([Console]::OutputEncoding.CodePage -ne 65001) {
            $current = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
            $saved = $current
        }
    } catch {
        $saved = $null
    }
    try {
        $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
            Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[\u2588\u2592]' }
        $code = $LASTEXITCODE
    } finally {
        if ($null -ne $saved) {
            try { [Console]::OutputEncoding = $saved } catch { }
        }
    }
    [pscustomobject]@{ ExitCode = $code; Lines = @($lines) }
}

# 昇格した winget で $Commands を打つ (UAC の確認が 1 回出る。確認なしで昇格する設定の PC では出ない)。System32 の Windows PowerShell
# (同じユーザーが差し替えられないもの) を Start-Process -Verb RunAs で昇格させ、Get-ElevatedWingetScript の本文を -EncodedCommand で渡す。
# 昇格した側は出力を一時ファイルに書き、最後に打った winget の終了コードで終わる。こちらはその終了コードと、ファイルの行 (進み具合の表示は
# 除く) と、昇格した側のアカウントを返す。UAC を断った・起こせなかったときは、UAC で断ったなら 1223、ほか (UAC を出せない SSH の会話など) は
# -1 (Get-ElevationFailureCode)。待つのは昇格した PowerShell だけ (5.1 の -Wait は子孫のプロセスまで待つので、handle を掴んで WaitForExit)
function Invoke-ElevatedWinget {
    param([object[]]$Commands)
    $log = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-codex-winget-{0}.log' -f [guid]::NewGuid().ToString('N'))
    $shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $encoded = ConvertTo-EncodedCommand -Script (Get-ElevatedWingetScript -Commands $Commands -LogPath $log)
    try {
        $p = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        $null = $p.Handle
        $p.WaitForExit()
    } catch {
        return [pscustomobject]@{ ExitCode = (Get-ElevationFailureCode -Exception $_.Exception); Lines = @("UAC: $($_.Exception.Message)"); Account = $null }
    }
    $lines = @()
    if (Test-Path -LiteralPath $log) {
        $lines = @(Select-WingetOutputLines -Lines @(Get-Content -LiteralPath $log -Encoding UTF8))
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Lines = @($lines | Where-Object { $_ -notmatch '^\s*account:' }); Account = (Get-ElevatedAccount -Lines $lines) }
}

# 置き場所の codex の exe を探す。この PC の CPU の名前 (x64 は codex-x86_64-pc-windows-msvc.exe、arm64 は codex-aarch64-pc-windows-msvc.exe)
# を先に見て、無ければもう一方。どちらも無ければ $null
function Find-CodexExe {
    param([string]$PackageDir)
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $names = if ($arch -eq 'ARM64') { @('codex-aarch64-pc-windows-msvc.exe', 'codex-x86_64-pc-windows-msvc.exe') } else { @('codex-x86_64-pc-windows-msvc.exe', 'codex-aarch64-pc-windows-msvc.exe') }
    foreach ($name in $names) {
        $p = Join-Path $PackageDir $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $null
}

# codex に版を聞く。読めなければ $null
function Get-CodexInstalledVersion {
    param([string]$Exe)
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe --version 2>&1 | ForEach-Object { "$_" })
    } catch {
        # 起動できない (壊れた・0 バイト・方針で止められた) ときも、版が読めないとして入れ替えの対象にする
        return $null
    }
    Get-CodexVersionFromOutput -Lines $out
}

# WinGet\Links\codex.exe を読む (有るか・種類・指す先)。Target は 5.1 では配列、7 では文字列なので、1 つ目を取る
function Get-CodexLink {
    param([string]$LinksDir)
    $path = Join-Path $LinksDir 'codex.exe'
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return [pscustomobject]@{ Exists = $false; LinkType = ''; Target = '' } }
    $target = @($item.Target | Where-Object { $_ }) | Select-Object -First 1
    [pscustomobject]@{ Exists = $true; LinkType = "$($item.LinkType)"; Target = "$target" }
}

# 開発者モード (設定 > システム > 開発者向け) が on か。on なら、昇格していない winget も symlink を作れる
function Test-DeveloperMode {
    $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
    [bool]($key -and ($key.AllowDevelopmentWithoutDevLicense -eq 1))
}

# 今の PowerShell が管理者の権限で動いているか (昇格した会話なら、UAC を出さずにそのまま winget を打つ)
function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# このユーザーが管理者 (Administrators) か。昇格していない token でも whoami /groups に出る
function Test-IsAdminAccount {
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& whoami.exe /groups /fo csv /nh 2>&1 | ForEach-Object { "$_" })
    } catch {
        return $false
    }
    Test-AdminMember -Lines $out
}

# これから開く PowerShell が使う PATH (マシン → ユーザーの順)。今のプロセスの PATH は古いことがある
function Get-CodexPathValue {
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}

# 置き場所の下の exe (codex・同梱の helper) か、WinGet\Links\codex.exe から起動して動いているプロセス
function Get-CodexBusyProcess {
    param([string]$PackageDir, [string]$LinksDir)
    $prefix = $PackageDir.TrimEnd('\') + '\'
    $link = Join-Path $LinksDir 'codex.exe'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            $path -and ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $path.Equals($link, [StringComparison]::OrdinalIgnoreCase))
        })
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-CodexState {
    param([string]$PackageId, [string]$PackageDir, [string]$LinksDir, [string]$Target)
    $exe = Find-CodexExe -PackageDir $PackageDir
    $exists = [bool]$exe
    $installed = $null
    if ($exists) { $installed = Get-CodexInstalledVersion -Exe $exe }
    $link = Get-CodexLink -LinksDir $LinksDir
    $linkState = Get-CodexLinkState -Exists $link.Exists -LinkType $link.LinkType -Target $link.Target -ExePath $exe
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $resolved = Resolve-CodexOnPath -PathValue (Get-CodexPathValue) -Names @('codex.exe', 'codex.cmd', 'codex.bat', 'codex.ps1') -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    [pscustomobject]@{
        Exists       = $exists
        Installed    = $installed
        ExeName      = $(if ($exe) { Split-Path -Leaf $exe } else { $null })
        Plan         = Get-CodexPlan -Exists $exists -Installed $installed -Target $Target -LinkState $linkState
        Direction    = Get-CodexDirection -Versions $versions -Installed $installed -Target $Target
        Pinned       = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions     = $versions
        Latest       = $latest
        LinkState    = $linkState
        LinkTarget   = $link.Target
        PathResolved = $resolved
        PathKind     = Get-CodexPathKind -Resolved $resolved -LinksDir $LinksDir
        Route        = Get-CodexInstallRoute -Elevated (Test-Elevated) -DeveloperMode (Test-DeveloperMode) -Admin (Test-IsAdminAccount)
        BusyCount    = @(Get-CodexBusyProcess -PackageDir $PackageDir -LinksDir $LinksDir).Count
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-CodexState {
    param($State, [string]$Target, [string]$PackageId, [string]$PackageDir)
    foreach ($row in (Format-CodexState -State $State -Target $Target -PackageId $PackageId -PackageDir $PackageDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 締めの行 (直すこと) を黄色で出す。揃っていれば何も出さない
function Write-CodexVerdict {
    param($State)
    foreach ($line in (Format-CodexVerdict -State $State)) {
        Write-Host $line -ForegroundColor Yellow
    }
}

function Invoke-InstallCodex {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'OpenAI.Codex'
    # portable の置き場所は <Id>_<ソースの識別子>。winget のソースから入れると、どのマシンでも同じ名前になる
    $packageDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe'
    $linksDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-CodexState -PackageId $packageId -PackageDir $packageDir -LinksDir $linksDir -Target $Version
    Write-CodexState -State $state -Target $Version -PackageId $packageId -PackageDir $packageDir
    $code = Get-CodexExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if ($code -eq 0) { Write-Host '揃っている' }
        Write-CodexVerdict -State $state
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }
    # 揃える手順で直す差 (版・pin・symlink) が無く、残っているのは PATH のずれだけ
    if (-not (Test-CodexDrift -State $state)) {
        Write-Host '版と pin と symlink は揃っている。PATH のずれは Install-Codex では直らない (上の ※ の行の手順で直す)'
        Write-CodexVerdict -State $state
        return 1
    }

    $blocker = Get-CodexApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version -BusyCount $state.BusyCount -Route $state.Route
    if ($blocker -eq 'blocked') {
        Write-Host 'winget が codex の symlink を作れないので、入れずに止める。上の ※ の行の手順で開発者モードを on にしてから打ち直す'
        Write-CodexVerdict -State $state
        return 1
    }
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }
    if ($blocker -eq 'busy') {
        Write-Host 'codex が動いていて置き換えられない。動いている codex を終わらせてから打ち直す:'
        foreach ($p in @(Get-CodexBusyProcess -PackageDir $packageDir -LinksDir $linksDir)) {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
            Write-Host "  $($p.Id)  $commandLine"
        }
        return 1
    }

    # 入れ替え・入れ直しは外してから入れるので、取得が落ちると codex が消えたまま終わる。
    # 外す前に、固定した版を取得してハッシュまで確かめる (落ちたら何も変えずに止める)
    if ($state.Plan -in @('change', 'relink')) {
        $downloadDir = Join-Path ([IO.Path]::GetTempPath()) "install-codex-$PID"
        $arguments = @(Get-WingetDownloadArguments -PackageId $packageId -Version $Version -Directory $downloadDir)
        Write-Host "winget $($arguments -join ' ')"
        $download = Invoke-Winget -Arguments $arguments
        Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($download.ExitCode -ne 0) {
            $download.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
            Write-Host ('固定した版を取得できなかった (終了コード 0x{0:X8})。何も変えていない。ネットワークを確かめて打ち直す' -f $download.ExitCode)
            return 1
        }
    }

    # 入れ替えるときは、古い版の pin を残さないよう先に外す (入れた後に足し直す)
    if (($state.Plan -in @('change', 'relink')) -and $state.Pinned) {
        $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($unpin.ExitCode -ne 0) { Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode) }
    }
    $commands = @(Get-WingetCommands -Plan $state.Plan -PackageId $packageId -Version $Version)
    if ($commands.Count -gt 0) {
        if ($state.Route -eq 'elevated') {
            # 外す・入れるを 1 回の昇格で打つ (UAC を断れば、どちらも打たない)
            foreach ($arguments in $commands) { Write-Host "[管理者] winget $($arguments -join ' ')" }
            Write-Host 'Windows のデスクトップに UAC の確認が出る。出たら「はい」を押す (昇格した側の窓は隠すので、終わるまで winget の出力は出ない)'
            $result = Invoke-ElevatedWinget -Commands $commands
            $result.Lines | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
            if (($null -ne $result.Account) -and ($result.Account -ne $env:USERNAME)) {
                Write-Host "昇格した側のアカウント ($($result.Account)) が、このユーザー ($env:USERNAME) と違う。codex はそのアカウントの置き場所に入ったかもしれないので、そのアカウントで winget uninstall --id $packageId --exact を打って外す"
            }
            if ($result.ExitCode -eq 1223) {
                Write-Host 'UAC の確認で「はい」を押さなかったので、何も変えていない。Install-Codex を打ち直して「はい」を押す'
            } elseif ($result.ExitCode -eq -1) {
                Write-Host '昇格した winget を起こせなかった (UAC を出せない SSH の会話など)。Windows のデスクトップの PowerShell で Install-Codex を打ち直す'
            } elseif ($result.ExitCode -ne 0) {
                Write-Host ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
                if ($state.Plan -ne 'install') {
                    Write-Host '外した後に入れられなかったことがある。ネットワークを確かめて Install-Codex を打ち直す (dotfiles apply でも入る)'
                }
            }
        } else {
            foreach ($arguments in $commands) {
                Write-Host "winget $($arguments -join ' ')"
                $result = Invoke-Winget -Arguments $arguments
                $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
                if ($result.ExitCode -ne 0) {
                    Write-Host ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
                    if ($arguments[0] -eq 'install') {
                        Write-Host 'install が落ちたので、codex が入っていないことがある。ネットワークを確かめて Install-Codex を打ち直す (dotfiles apply でも入る)'
                    }
                    break
                }
            }
        }
    }
    # 入っていれば pin を足す (入れ替えた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Find-CodexExe -PackageDir $packageDir) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-CodexState -PackageId $packageId -PackageDir $packageDir -LinksDir $linksDir -Target $Version
    Write-CodexState -State $after -Target $Version -PackageId $packageId -PackageDir $packageDir
    if ((Get-CodexExitCode -State $after) -eq 0) {
        Write-Host '揃った (新しい PowerShell から codex と打てる)'
        return 0
    }
    # 版と pin と symlink は揃い、残っているのは PATH のずれだけ
    if (-not (Test-CodexDrift -State $after)) { Write-Host '版と pin と symlink は揃った' }
    Write-CodexVerdict -State $after
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallCodex -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
