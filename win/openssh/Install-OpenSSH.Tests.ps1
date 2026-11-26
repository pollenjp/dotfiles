# win/openssh/Install-OpenSSH.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget やサービスに触る部分は、実機で -Check と本番を打って確かめる (win/README.md の「OpenSSH」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/openssh/Install-OpenSSH.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-OpenSSH.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-OpenSSH.ps1')

$script:Failures = 0

# Actual の scriptblock を走らせ、文字列にして Expected と比べる。
# 関数が無いなどで例外になったら、その文面を結果として失敗にする。
function Test-Case {
    param([string]$Name, $Expected, [scriptblock]$Actual)
    try {
        $got = & $Actual
    } catch {
        $got = "ERROR: $($_.Exception.Message)"
    }
    $e = @($Expected | ForEach-Object { "$_" }) -join ' '
    $a = @($got | ForEach-Object { "$_" }) -join ' '
    if ($e -ceq $a) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

$Id = 'Microsoft.OpenSSH.Preview'

# Get-OpenSshPlan: 入っている版と固定した版から、することを決める
Test-Case '入っていなければ install' 'install' { Get-OpenSshPlan -Installed $null -Target '10.0.0.0' }
Test-Case '古ければ upgrade (9.5 と 10.0 を文字列ではなく版で比べる)' 'upgrade' { Get-OpenSshPlan -Installed '9.5.0.0' -Target '10.0.0.0' }
Test-Case '新しければ downgrade' 'downgrade' { Get-OpenSshPlan -Installed '10.0.0.0' -Target '9.8.3.0' }
Test-Case '同じなら none' 'none' { Get-OpenSshPlan -Installed '10.0.0.0' -Target '10.0.0.0' }

# Get-WingetLatestVersion: winget show --versions の出力から最新版を拾う (2026-10-06 の実際の出力)
$show = @(
    'Found OpenSSH Preview [Microsoft.OpenSSH.Preview]'
    'Version'
    '--------'
    '10.0.0.0'
    '9.8.3.0'
    '9.8.2.0'
    '9.8.1.0'
    '9.8.0.0'
    '9.5.0.0'
)
Test-Case 'winget show --versions の先頭の版' '10.0.0.0' { Get-WingetLatestVersion -Lines $show }
Test-Case '版の行が無ければ空' '' { Get-WingetLatestVersion -Lines @('No package found matching input criteria.') }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか
Test-Case 'pin が無い (実際の出力)' 'False' { Test-WingetPinned -Lines @('There are no pins configured.') -PackageId $Id }
Test-Case 'pin の表に Id がある' 'True' {
    Test-WingetPinned -PackageId $Id -Lines @(
        'Name            Id                        Version  Source Pin type'
        '------------------------------------------------------------------'
        'OpenSSH Preview Microsoft.OpenSSH.Preview 10.0.0.0 winget Pinning'
    )
}
Test-Case '似た Id には当たらない' 'False' {
    Test-WingetPinned -PackageId $Id -Lines @(
        'Name    Id                         Version Source Pin type'
        '----------------------------------------------------------'
        'Foo Bar Microsoft.OpenSSH.PreviewX 1.0     winget Pinning'
    )
}

# Get-WingetCommands: plan ごとに打つ winget の引数
Test-Case 'upgrade は 1 回' 1 { @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version '10.0.0.0').Count }
Test-Case 'upgrade のサブコマンド' 'upgrade' { @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version '10.0.0.0')[0][0] }
Test-Case 'upgrade に --version を付ける' '10.0.0.0' {
    $a = @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version '10.0.0.0')[0]
    $a[$a.IndexOf('--version') + 1]
}
Test-Case 'upgrade は sshd を入れない' 'ADDLOCAL=Client' {
    $a = @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version '10.0.0.0')[0]
    $a[$a.IndexOf('--custom') + 1]
}
Test-Case 'install のサブコマンドと --version' 'install 10.0.0.0' {
    $a = @(Get-WingetCommands -Plan 'install' -PackageId $Id -Version '10.0.0.0')[0]
    $a[0]; $a[$a.IndexOf('--version') + 1]
}
Test-Case 'downgrade は uninstall してから install' 'uninstall install' {
    @(Get-WingetCommands -Plan 'downgrade' -PackageId $Id -Version '9.8.3.0') | ForEach-Object { $_[0] }
}
Test-Case 'downgrade の install に --version を付ける' '9.8.3.0' {
    $a = @(Get-WingetCommands -Plan 'downgrade' -PackageId $Id -Version '9.8.3.0')[1]
    $a[$a.IndexOf('--version') + 1]
}
Test-Case 'none なら何も打たない' 0 { @(Get-WingetCommands -Plan 'none' -PackageId $Id -Version '10.0.0.0').Count }
Test-Case 'install も sshd を入れない (Server は Install-Sshd.ps1 が足す)' 'ADDLOCAL=Client' {
    $a = @(Get-WingetCommands -Plan 'install' -PackageId $Id -Version '10.0.0.0')[0]
    $a[$a.IndexOf('--custom') + 1]
}
# Install-Sshd.ps1 が Server を足したマシン (-Server): 上げる・下げるときも Server を残す (ADDLOCAL を渡すと MSI は前の版の機能を
# 引き継がないので、Client だけで上げると sshd が消える)
Test-Case 'Server があれば upgrade は Client と Server を並べる' 'ADDLOCAL=Client,Server' {
    $a = @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version '10.0.0.0' -Server)[0]
    $a[$a.IndexOf('--custom') + 1]
}
Test-Case 'Server があれば、下げるときの install も Client と Server を並べる' 'ADDLOCAL=Client,Server' {
    $a = @(Get-WingetCommands -Plan 'downgrade' -PackageId $Id -Version '9.8.3.0' -Server)[1]
    $a[$a.IndexOf('--custom') + 1]
}

# winget の pin と打つ引数: 版を名指しした upgrade は、--include-pinned が無いと、この script が足した pin (Pinning) に
# 止められる (0x8A150068。2026-11-16 に example-host で 10.4.0.0 へ上げるときに落ちた)。install と uninstall は
# --include-pinned を受け付けない (下げるときの install は、uninstall で入っていない形にしてからなので pin を見ない)
Test-Case 'upgrade は自分の pin を越える (--include-pinned)' 'True' {
    @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version '10.0.0.0')[0] -contains '--include-pinned'
}
Test-Case 'install と、下げるときの uninstall・install には --include-pinned を付けない' 'False False False' {
    $commands = @(Get-WingetCommands -Plan 'install' -PackageId $Id -Version '10.0.0.0') + @(Get-WingetCommands -Plan 'downgrade' -PackageId $Id -Version '9.8.3.0')
    $commands | ForEach-Object { @($_) -contains '--include-pinned' }
}

# Get-WingetPinnedHint: winget が pin に止められて落ちた (0x8A150068) ときだけ、pin の見方と外し方を添える
Test-Case 'pin に止められたら、pin の種類の見方と外し方を出す' 'True True' {
    $h = @(Get-WingetPinnedHint -ExitCode -1978335128 -PackageId $Id)
    "$($h[0].Contains("winget pin list --id $Id --exact")) $($h[0].Contains("winget pin remove --id $Id --exact"))"
}
Test-Case 'ほかの終了コードなら何も添えない' '0 0' {
    "$(@(Get-WingetPinnedHint -ExitCode 1 -PackageId $Id).Count) $(@(Get-WingetPinnedHint -ExitCode -1978334964 -PackageId $Id).Count)"
}

# Test-SshAgentDisabled: ssh-agent が停止・無効か (サービスが無ければ問題なし)
Test-Case '停止・無効' 'True' { Test-SshAgentDisabled -Status 'Stopped' -StartType 'Disabled' }
Test-Case 'MSI が作り直した直後 (実行中・自動)' 'False' { Test-SshAgentDisabled -Status 'Running' -StartType 'Automatic' }
Test-Case '止まっていても自動なら次の起動で動く' 'False' { Test-SshAgentDisabled -Status 'Stopped' -StartType 'Automatic' }
Test-Case 'サービスが無い' 'True' { Test-SshAgentDisabled -Status $null -StartType $null }

# Format-OpenSshState: 状態の表の行。直すことがある行だけ ⚠ を付けて目立たせる
$dir = 'C:\Program Files\OpenSSH'
$drift = [pscustomobject]@{
    Installed = [version]'9.5.0.0'; Plan = 'upgrade'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
    AgentDisabled = $true; Pinned = $false; Latest = [version]'10.0.0.0'; Inbox = $false; Server = $false
}
$inSync = [pscustomobject]@{
    Installed = [version]'10.0.0.0'; Plan = 'none'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
    AgentDisabled = $true; Pinned = $true; Latest = [version]'10.0.0.0'; Inbox = $false; Server = $false
}
$agentBack = [pscustomobject]@{
    Installed = [version]'10.0.0.0'; Plan = 'none'; AgentStatus = 'Running'; AgentStartType = 'Automatic'
    AgentDisabled = $false; Pinned = $true; Latest = [version]'10.0.0.0'; Inbox = $false; Server = $false
}
$newer = [pscustomobject]@{
    Installed = [version]'10.0.0.0'; Plan = 'none'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
    AgentDisabled = $true; Pinned = $true; Latest = [version]'10.1.0.0'; Inbox = $false; Server = $false
}
Test-Case '版と pin がずれていれば、その 2 行だけ ⚠' @('⚠ 固定した版      : 10.0.0.0 → 上げる', '⚠ winget pin      : 無し → 足す') {
    Format-OpenSshState -State $drift -Target '10.0.0.0' -InstallDir $dir | Where-Object Warn | ForEach-Object Text
}
Test-Case 'ずれていない行は ⚠ を付けず 2 字下げる' '  入っている版    : 9.5.0.0' {
    Format-OpenSshState -State $drift -Target '10.0.0.0' -InstallDir $dir | Where-Object { $_.Text -like '*入っている版*' } | ForEach-Object Text
}
Test-Case '揃っていれば ⚠ の行は無い' 0 {
    @(Format-OpenSshState -State $inSync -Target '10.0.0.0' -InstallDir $dir | Where-Object Warn).Count
}
Test-Case 'ssh-agent が自動・実行中に戻っていれば ⚠' '⚠ ssh-agent       : Running / Automatic → 停止・無効にする' {
    Format-OpenSshState -State $agentBack -Target '10.0.0.0' -InstallDir $dir | Where-Object Warn | ForEach-Object Text
}
Test-Case 'sshd (Server) も入っていて上げるなら、一緒に入れ直して Install-Sshd で揃えると ※ で添える' 'True' {
    $s = $drift.PSObject.Copy()
    $s.Server = $true
    [bool](@(Format-OpenSshState -State $s -Target '10.0.0.0' -InstallDir $dir | Where-Object { $_.Text -like '※ sshd (Server の機能) も入っている*Install-Sshd*' }).Count -eq 1)
}
Test-Case 'sshd (Server) が入っていても、揃っていれば何も添えない' 0 {
    $s = $inSync.PSObject.Copy()
    $s.Server = $true
    @(Format-OpenSshState -State $s -Target '10.0.0.0' -InstallDir $dir | Where-Object { $_.Text -like '※ sshd*' }).Count
}
Test-Case 'winget に新しい版があれば ※ で知らせる (ずれではないので ⚠ にはしない)' '※ winget に固定した版より新しい 10.1.0.0 がある。上げるなら Install-OpenSSH.ps1 の -Version の既定値を変える' {
    Format-OpenSshState -State $newer -Target '10.0.0.0' -InstallDir $dir | Where-Object { $_.Text -like '※*' } | ForEach-Object Text
}

# Get-OpenSshExitCode: -Check の終了コード。入っていなければ 3、版・ssh-agent・pin が揃えば 0、ほかは 1
$missing = [pscustomobject]@{
    Installed = $null; Plan = 'install'; AgentStatus = $null; AgentStartType = $null
    AgentDisabled = $true; Pinned = $false; Latest = [version]'10.0.0.0'; Inbox = $true; Server = $false
}
$unpinned = [pscustomobject]@{
    Installed = [version]'10.0.0.0'; Plan = 'none'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
    AgentDisabled = $true; Pinned = $false; Latest = [version]'10.0.0.0'; Inbox = $false; Server = $false
}
Test-Case '入っていなければ 3' 3 { Get-OpenSshExitCode -State $missing }
Test-Case '版・ssh-agent・pin が揃えば 0' 0 { Get-OpenSshExitCode -State $inSync }
Test-Case 'pin が無ければ 1' 1 { Get-OpenSshExitCode -State $unpinned }
Test-Case 'ssh-agent が自動・実行中に戻っていれば 1' 1 { Get-OpenSshExitCode -State $agentBack }
Test-Case '古ければ 1' 1 { Get-OpenSshExitCode -State $drift }

# Test-OpenSshNeedsIdle: 動いている ssh.exe などを見るのは、ファイルを置き換える (上げる・下げる) ときだけ。
# 入れるときは置き換えるファイルが無い (Windows の機能の OpenSSH の ssh.exe が動いていても入れられる)
Test-Case '入れる (install) ときは見ない' 'False' { Test-OpenSshNeedsIdle -Plan 'install' }
Test-Case '上げるときは見る' 'True' { Test-OpenSshNeedsIdle -Plan 'upgrade' }
Test-Case '下げるときは見る' 'True' { Test-OpenSshNeedsIdle -Plan 'downgrade' }
Test-Case '揃っていれば見ない' 'False' { Test-OpenSshNeedsIdle -Plan 'none' }

# Get-OpenSshCheckMessage: -Check の締めの 1 行
Test-Case '-Check の締め: 入っていなければ、-IfMissing で入れるコマンドと UAC を出し、⚠️ で始まる' 'True True True' {
    $m = Get-OpenSshCheckMessage -State $missing
    "$($m.StartsWith('⚠️')) $($m.Contains('入っていない → Install-OpenSSH -IfMissing で入れる')) $($m.Contains('UAC'))"
}

# Get-OpenSshIfMissingMessage: -IfMissing で入れたあとの締めの 1 行。入れ直しも -IfMissing で打たせる
# (付けないで打つと、入れたあと 1Password の鍵が見えないのを失敗と数える)
Test-Case '-IfMissing の締め: 入れたら「入れた」' '入れた' { Get-OpenSshIfMissingMessage -Code 0 }
Test-Case '-IfMissing の締め: 入れられなければ -IfMissing で打ち直させる' 'True' {
    (Get-OpenSshIfMissingMessage -Code 1).Contains('Install-OpenSSH -IfMissing を打ち直す')
}
Test-Case '-Check の締め: 揃っていれば「揃っている」' '揃っている' { Get-OpenSshCheckMessage -State $inSync }
Test-Case '-Check の締め: ずれていれば「揃っていない」' 'True' { (Get-OpenSshCheckMessage -State $drift).Contains('固定した版と揃っていない') }

# Format-MsixElevationNote: 自分を起動し直す pwsh が MSIX (WindowsApps の下) なら、別の管理者のアカウントでは起こせないことを ※ で出す
$msixPwsh = 'C:\Program Files\WindowsApps\Microsoft.PowerShell-LTS_7.6.10.0_x64__8wekyb3d8bbwe\pwsh.exe'
$msiPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
Test-Case 'MSIX の pwsh なら、別の管理者のアカウントのことと MSI を足す手を ※ で出し、MSI の pwsh なら何も出さない' 'True True 0' {
    $note = @(Format-MsixElevationNote -HostExe $msixPwsh)
    "$($note[0].StartsWith('※ この pwsh は MSIX')) $($note[0].Contains('MSI の PowerShell 7 を足して')) $(@(Format-MsixElevationNote -HostExe $msiPwsh).Count)"
}

# Invoke-Elevated: 昇格を起こせなかった・子がログを書かずに落ちたときに、pwsh が MSIX なら ※ を足す。Get-Process・Start-Process・
# Write-Host を偽物に替え、LOCALAPPDATA は一時ディレクトリにする
function Invoke-ElevatedScenario {
    param([string]$HostExe, [bool]$Throw, [int]$ExitCode = 0)
    $said = [System.Collections.Generic.List[string]]::new()
    function Get-Process { param($Id) [pscustomobject]@{ Path = $HostExe } }
    function Start-Process {
        param([string]$FilePath, [string[]]$ArgumentList, [string]$Verb, [switch]$Wait, [switch]$PassThru)
        if ($Throw) { throw 'アクセスが拒否されました。' }
        [pscustomobject]@{ ExitCode = $ExitCode }
    }
    function Write-Host { param($Object, $ForegroundColor) $said.Add("$Object") }
    $saved = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-openssh-elevated-$PID"
    try {
        $result = Invoke-Elevated -Version '10.4.0.0'
    } finally {
        Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = $saved
    }
    "$result $(@($said | Where-Object { $_.StartsWith('※ この pwsh は MSIX') }).Count)"
}
Test-Case 'MSIX の pwsh で昇格を起こせなければ、別の管理者のアカウントのことを ※ で出す' 'False 1' { Invoke-ElevatedScenario -HostExe $msixPwsh -Throw $true }
Test-Case 'MSIX の pwsh の子がログを書かずに落ちたときも、同じ ※ を出す' 'False 1' { Invoke-ElevatedScenario -HostExe $msixPwsh -Throw $false -ExitCode -1073741515 }
Test-Case 'MSI の pwsh で昇格を起こせなくても、MSIX の ※ は出さない' 'False 0' { Invoke-ElevatedScenario -HostExe $msiPwsh -Throw $true }
Test-Case '子が 0 で終われば成功で、※ は出さない' 'True 0' { Invoke-ElevatedScenario -HostExe $msixPwsh -Throw $false -ExitCode 0 }

# 本体の入口: 思わぬ例外でも、終了コード 2 で止まる (成功に見せない)。
# Linux の pwsh には $env:ProgramFiles が無く、本体の最初で例外になるのを使う
# (2026-10-06 の本番で、例外のあと外側の exit $LASTEXITCODE が中の winget の 0 を返し「揃いました」と出た)
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-OpenSSH.ps1') -Check 2>&1
    $LASTEXITCODE
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
