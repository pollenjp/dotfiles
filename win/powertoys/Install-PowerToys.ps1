<#
.SYNOPSIS
Windows の PowerToys (winget の Microsoft.PowerToys) が入っていなければ、user スコープで入れる。

.DESCRIPTION
dotfiles の win/powertoys/Install-PowerToys.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-PowerToys から呼ぶ (win/README.md の「PowerToys を入れる」)。

版は固定しない。PowerToys は自分で新しい版を知らせるので、winget pin も足さない (ADR 017)。
入っているかは、PowerToys.exe が %LOCALAPPDATA%\PowerToys\ (user スコープ) か
%ProgramFiles%\PowerToys\ (machine スコープ) にあるかで見る。入れるときは user スコープの
installer (PowerToysUserSetup-…exe) にするので、管理者は要らない。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Check
入っているかを出すだけで、何も変えない。入っていれば終了コード 0、入っていなければ 3、確かめられなければ 2。

.PARAMETER IfMissing
入っていなければ入れる。入っていれば -Check と同じ (setup --update の bootstrap-windows-powertoys.sh が使う)。
版を固定しないので揃えることが他に無く、付けずに打っても同じことをする。
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-PowerToys.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# PowerToys.exe の置き場所の候補 (user スコープ、machine スコープの順)。空の値は飛ばす。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Get-PowerToysExeCandidate {
    param([string]$LocalAppData, [string]$ProgramFiles)
    foreach ($root in @($LocalAppData, $ProgramFiles)) {
        if ($root) { "$($root.TrimEnd('\'))\PowerToys\PowerToys.exe" }
    }
}

# 候補を前から見て、最初にあったもの。無ければ $null。
# $Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)
function Find-PowerToysExe {
    param([string[]]$Candidates, [scriptblock]$Exists)
    foreach ($candidate in $Candidates) {
        if (& $Exists $candidate) { return $candidate }
    }
    $null
}

# 入れる winget の引数。user スコープの installer を選び、版は名指ししない (そのときの最新を入れる)
function Get-PowerToysInstallArguments {
    param([string]$PackageId)
    @('install', '--id', $PackageId, '--exact', '--source', 'winget', '--scope', 'user', '--silent',
        '--accept-source-agreements', '--disable-interactivity', '--accept-package-agreements')
}

# 終了コード。入っていれば 0、入っていなければ 3
function Get-PowerToysExitCode {
    param($State)
    if ($State.Exe) { return 0 }
    3
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。入っていなければ ⚠ を付ける
function Format-PowerToysState {
    param($State)
    [pscustomobject]@{ Text = 'PowerToys (winget の Microsoft.PowerToys。版は固定しない)'; Warn = $false }
    if ($State.Exe) {
        $versionText = if ($State.Version) { $State.Version } else { '不明 (PowerToys.exe の ProductVersion が読めない)' }
        [pscustomobject]@{ Text = "  入っている場所 : $($State.Exe)"; Warn = $false }
        [pscustomobject]@{ Text = "  入っている版   : $versionText"; Warn = $false }
    } else {
        [pscustomobject]@{ Text = '⚠ 入っている場所 : 入っていない → user スコープで入れる'; Warn = $true }
    }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-OpenSSH.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[\u2588\u2592]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# 今の状態を読む (何も変えない。winget も使わない)
function Get-PowerToysState {
    $candidates = @(Get-PowerToysExeCandidate -LocalAppData $env:LOCALAPPDATA -ProgramFiles $env:ProgramFiles)
    $exe = Find-PowerToysExe -Candidates $candidates -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    $version = $null
    if ($exe) { $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
    [pscustomobject]@{ Exe = $exe; Version = $version }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-PowerToysState {
    param($State)
    foreach ($row in (Format-PowerToysState -State $State)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

function Invoke-InstallPowerToys {
    param([switch]$Check)
    $packageId = 'Microsoft.PowerToys'

    $state = Get-PowerToysState
    Write-PowerToysState -State $state
    $code = Get-PowerToysExitCode -State $state

    # 入っていれば何もしない (-Check でも、付けなくても)。-Check は入っていなくても何も変えない
    if ($code -eq 0) {
        Write-Host '入っている'
        return 0
    }
    if ($Check) {
        Write-Host '⚠️ PowerToys が入っていない → Install-PowerToys で入れる ⚠️' -ForegroundColor Yellow
        return $code
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }
    $arguments = @(Get-PowerToysInstallArguments -PackageId $packageId)
    Write-Host "winget $($arguments -join ' ')"
    $result = Invoke-Winget -Arguments $arguments
    $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
    if ($result.ExitCode -ne 0) {
        Write-Host ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
    }

    # 入ったかを読み直して確かめる
    Write-Host ''
    $after = Get-PowerToysState
    Write-PowerToysState -State $after
    if ((Get-PowerToysExitCode -State $after) -eq 0) {
        Write-Host '入った'
        return 0
    }
    Write-Host '入らなかった。ネットワークを確かめて Install-PowerToys を打ち直す (setup --update でも、もう一度入れにいく)'
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える。
# -IfMissing は付けなくても同じなので、本体には渡さない (bootstrap が herdr と同じ形で呼ぶために受け取る)
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallPowerToys -Check:$Check)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
