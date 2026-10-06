<#
.SYNOPSIS
Win32-OpenSSH (winget の Microsoft.OpenSSH.Preview) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/openssh/Install-OpenSSH.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-OpenSSH から呼ぶ (win/README.md の「OpenSSH」)。

MSI の更新は ssh-agent サービスを「自動・実行中」で作り直し、1Password の SSH agent と
\\.\pipe\openssh-ssh-agent を取り合う (Win32-OpenSSH の issue #2057)。揃えた後に
ssh-agent を停止・無効へ戻し、winget pin で winget upgrade --all から外す。

管理者が要るのは winget と ssh-agent を直す段だけで、そのときだけ UAC で自分を
起動し直す。-Check は何も変えない。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Microsoft.OpenSSH.Preview --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1。

.PARAMETER Force
ssh.exe などが動いていても入れ替える (使用中のファイルは再起動まで置き換わらないことがある)。

.PARAMETER LogPath
内部用。管理者で起動し直した子が、結果をこのファイルへ書いて親へ渡す。
#>
[CmdletBinding()]
param(
    [string]$Version = '10.0.0.0',
    [switch]$Check,
    [switch]$Force,
    [string]$LogPath
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-OpenSSH.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 入っている版 (無ければ $null) と固定した版から、することを決める
function Get-OpenSshPlan {
    param([version]$Installed, [version]$Target)
    if ($null -eq $Installed) { return 'install' }
    if ($Installed -lt $Target) { return 'upgrade' }
    if ($Installed -gt $Target) { return 'downgrade' }
    'none'
}

# winget show --versions の出力から、最新版 (版だけの行の先頭) を拾う。無ければ $null
function Get-WingetLatestVersion {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match '^\s*(\d+(\.\d+){1,3})\s*$') { return [version]$Matches[1] }
    }
    $null
}

# winget pin list の出力に、その Id を列に持つ行があるか。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。下げるときは、新しい版が入っていると
# MSI が止める (LaunchCondition) ので、先に外してから入れる
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    # ADDLOCAL=Client で sshd を入れない (ssh-agent はクライアント側の部品でもあるので入る)
    $put = $common + @('--version', $Version, '--custom', 'ADDLOCAL=Client', '--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        'upgrade' { , (@('upgrade') + $put) }
        'downgrade' {
            , (@('uninstall') + $common)
            , (@('install') + $put)
        }
    }
}

# ssh-agent が停止・無効か。サービスが無ければ 1Password とぶつからないので問題なし
function Test-SshAgentDisabled {
    param($Status, $StartType)
    if ($null -eq $Status) { return $true }
    ("$Status" -eq 'Stopped') -and ("$StartType" -eq 'Disabled')
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。winget に新しい版があるのはずれではないので、⚠ ではなく ※ で知らせる
function Format-OpenSshState {
    param($State, [version]$Target, [string]$InstallDir)
    $planText = @{ install = '入れる'; upgrade = '上げる'; downgrade = '下げる (外してから入れる)'; none = 'そのまま' }[$State.Plan]
    $installedText = if ($State.Installed) { "$($State.Installed)" } else { '入っていない' }
    $latestText = if ($State.Latest) { "$($State.Latest)" } else { '不明 (winget show が失敗)' }
    $agentText = if ($null -eq $State.AgentStatus) { 'サービス無し' } else { "$($State.AgentStatus) / $($State.AgentStartType)" }
    $agentTo = if ($State.AgentDisabled) { 'そのまま' } else { '停止・無効にする' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $rows = @(
        @{ Text = "OpenSSH (winget の Microsoft.OpenSSH.Preview、$InstallDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "ssh-agent       : $agentText → $agentTo"; Warn = (-not $State.AgentDisabled); Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    if ($State.Latest -and $State.Latest -gt $Target) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($State.Latest) がある。上げるなら Install-OpenSSH.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    if ($State.Inbox) {
        [pscustomobject]@{ Text = '※ Windows の機能の OpenSSH (System32\OpenSSH) も入っている。PATH では Program Files が先なので使われないが、ssh-agent サービスの名前がぶつかる'; Warn = $false }
    }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# 画面に出す。管理者で起動し直した子では、親が読めるようにファイルへも書く
function Write-Step {
    param([string]$Message)
    Write-Host $Message
    if ($script:StepLog) { Add-Content -LiteralPath $script:StepLog -Value $Message -Encoding utf8 }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[\u2588\u2592]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# 今の状態を読む (管理者は要らない)
function Get-OpenSshState {
    param([string]$PackageId, [string]$InstallDir, [version]$Target)
    $sshExe = Join-Path $InstallDir 'ssh.exe'
    $installed = $null
    if (Test-Path -LiteralPath $sshExe) {
        $fileVersion = (Get-Item -LiteralPath $sshExe).VersionInfo.FileVersion
        if ($fileVersion) { $installed = [version]$fileVersion }
    }
    $agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    $agentStatus = $null
    $agentStartType = $null
    if ($agent) {
        $agentStatus = "$($agent.Status)"
        $agentStartType = "$($agent.StartType)"
    }
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    [pscustomobject]@{
        Installed      = $installed
        Plan           = Get-OpenSshPlan -Installed $installed -Target $Target
        AgentStatus    = $agentStatus
        AgentStartType = $agentStartType
        AgentDisabled  = Test-SshAgentDisabled -Status $agentStatus -StartType $agentStartType
        Pinned         = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Latest         = Get-WingetLatestVersion -Lines $show.Lines
        Inbox          = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe')
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-OpenSshState {
    param($State, [version]$Target, [string]$InstallDir)
    foreach ($row in (Format-OpenSshState -State $State -Target $Target -InstallDir $InstallDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 入れ替えの邪魔になる、動いている ssh.exe などを返す
function Get-BusyOpenSshProcess {
    @(Get-Process -Name ssh, ssh-add, scp, sftp -ErrorAction SilentlyContinue)
}

# 管理者で行う段: winget で版を揃え、ssh-agent を停止・無効にする。成功なら $true
function Invoke-OpenSshFix {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $ok = $true
    foreach ($arguments in @(Get-WingetCommands -Plan $Plan -PackageId $PackageId -Version $Version)) {
        Write-Step "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Step "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Step ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
            $ok = $false
            break
        }
    }
    # winget が途中で失敗しても、MSI が ssh-agent を起動していることがあるので、後始末は必ずする
    $agent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($agent) {
        if ($agent.Status -ne 'Stopped') {
            Stop-Service -Name ssh-agent -Force
            Write-Step 'ssh-agent を止めた'
        }
        if ($agent.StartType -ne 'Disabled') {
            Set-Service -Name ssh-agent -StartupType Disabled
            Write-Step 'ssh-agent を無効にした'
        }
    }
    $ok
}

# 自分を管理者で起動し直して終わるのを待ち、子が書いたログを出す。成功なら $true
function Invoke-Elevated {
    param([string]$Version, [switch]$Force)
    $log = Join-Path $env:LOCALAPPDATA 'dotfiles\Install-OpenSSH.log'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    $hostExe = (Get-Process -Id $PID).Path
    # Start-Process は配列を空白でつなぐだけなので、パスは自分で "" で囲む
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath),
        '-Version', $Version, '-LogPath', ('"{0}"' -f $log))
    if ($Force) { $argumentList += '-Force' }
    Write-Host 'UAC で管理者の PowerShell を起動する (終わると閉じる)'
    try {
        $process = Start-Process -FilePath $hostExe -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
    } catch {
        Write-Host "管理者で起動できなかった (UAC で断った?): $($_.Exception.Message)"
        return $false
    }
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Encoding utf8 | ForEach-Object { Write-Host "  [管理者] $_" }
    }
    $process.ExitCode -eq 0
}

# 1Password の鍵が ssh-add から見えるか。見えれば本数、見えなければ $null
function Get-AgentKeyCount {
    param([string]$SshAddExe)
    if (-not (Test-Path -LiteralPath $SshAddExe)) { return $null }
    $ErrorActionPreference = 'Continue'
    $out = @(& $SshAddExe -l 2>&1)
    if ($LASTEXITCODE -ne 0) { return $null }
    $out.Count
}

function Invoke-InstallOpenSsh {
    param([string]$Version, [switch]$Check, [switch]$Force, [string]$LogPath)
    $packageId = 'Microsoft.OpenSSH.Preview'
    $installDir = Join-Path $env:ProgramFiles 'OpenSSH'
    $target = [version]$Version

    if ($LogPath) {
        # 管理者で起動し直された子: 揃える段だけをして、結果を $LogPath に書く
        $script:StepLog = $LogPath
        $installed = $null
        $sshExe = Join-Path $installDir 'ssh.exe'
        if (Test-Path -LiteralPath $sshExe) { $installed = [version](Get-Item -LiteralPath $sshExe).VersionInfo.FileVersion }
        $plan = Get-OpenSshPlan -Installed $installed -Target $target
        if (Invoke-OpenSshFix -Plan $plan -PackageId $packageId -Version $Version) { return 0 }
        return 1
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 1
    }

    $state = Get-OpenSshState -PackageId $packageId -InstallDir $installDir -Target $target
    Write-OpenSshState -State $state -Target $target -InstallDir $installDir
    $inSync = ($state.Plan -eq 'none') -and $state.AgentDisabled -and $state.Pinned
    if ($Check) {
        if ($inSync) {
            Write-Host '揃っている'
            return 0
        }
        Write-Host '⚠️ 固定した版と揃っていない → Install-OpenSSH で揃える (差があれば UAC が 1 回出る) ⚠️' -ForegroundColor Yellow
        return 1
    }
    if ($inSync) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    if ($state.Plan -ne 'none') {
        # @() で包む。関数が返す空の配列は呼び出し側で $null にほどけ、StrictMode では
        # $null.Count が例外になる (2026-10-06 の本番で、ssh.exe が 0 本のときにここで止まった)
        $busy = @(Get-BusyOpenSshProcess)
        if ($busy.Count -gt 0 -and -not $Force) {
            Write-Host '入れ替える ssh.exe などが動いている。閉じてから打ち直す (-Force で進む):'
            foreach ($p in $busy) {
                $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
                Write-Host "  $($p.Id)  $commandLine"
            }
            return 1
        }
    }

    if (($state.Plan -ne 'none') -or -not $state.AgentDisabled) {
        if (Test-IsAdmin) {
            [void](Invoke-OpenSshFix -Plan $state.Plan -PackageId $packageId -Version $Version)
        } else {
            [void](Invoke-Elevated -Version $Version -Force:$Force)
        }
    }

    if (-not $state.Pinned) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-OpenSshState -PackageId $packageId -InstallDir $installDir -Target $target
    Write-OpenSshState -State $after -Target $target -InstallDir $installDir
    $keys = Get-AgentKeyCount -SshAddExe (Join-Path $installDir 'ssh-add.exe')
    if ($null -eq $keys) {
        Write-Host '  ssh-add -l      : 鍵が見えない → 1Password をトレイから終了して起動し直し、もう一度 -Check で確かめる'
    } else {
        Write-Host "  ssh-add -l      : 鍵 $keys 本"
    }
    if (($after.Plan -eq 'none') -and $after.AgentDisabled -and $after.Pinned -and ($null -ne $keys)) {
        Write-Host '揃った'
        return 0
    }
    if ($after.Plan -ne 'none') {
        Write-Host '版が揃っていない。ssh.exe が使用中で再起動待ちになったなら、再起動してからもう一度打つ'
    }
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallOpenSsh -Version $Version -Check:$Check -Force:$Force -LogPath $LogPath)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
