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

# Test-SshAgentDisabled: ssh-agent が停止・無効か (サービスが無ければ問題なし)
Test-Case '停止・無効' 'True' { Test-SshAgentDisabled -Status 'Stopped' -StartType 'Disabled' }
Test-Case 'MSI が作り直した直後 (実行中・自動)' 'False' { Test-SshAgentDisabled -Status 'Running' -StartType 'Automatic' }
Test-Case '止まっていても自動なら次の起動で動く' 'False' { Test-SshAgentDisabled -Status 'Stopped' -StartType 'Automatic' }
Test-Case 'サービスが無い' 'True' { Test-SshAgentDisabled -Status $null -StartType $null }

# Format-OpenSshState: 状態の表の行。直すことがある行だけ ⚠ を付けて目立たせる
$dir = 'C:\Program Files\OpenSSH'
$drift = [pscustomobject]@{
    Installed = [version]'9.5.0.0'; Plan = 'upgrade'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
    AgentDisabled = $true; Pinned = $false; Latest = [version]'10.0.0.0'; Inbox = $false
}
$inSync = [pscustomobject]@{
    Installed = [version]'10.0.0.0'; Plan = 'none'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
    AgentDisabled = $true; Pinned = $true; Latest = [version]'10.0.0.0'; Inbox = $false
}
$agentBack = [pscustomobject]@{
    Installed = [version]'10.0.0.0'; Plan = 'none'; AgentStatus = 'Running'; AgentStartType = 'Automatic'
    AgentDisabled = $false; Pinned = $true; Latest = [version]'10.0.0.0'; Inbox = $false
}
$newer = [pscustomobject]@{
    Installed = [version]'10.0.0.0'; Plan = 'none'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
    AgentDisabled = $true; Pinned = $true; Latest = [version]'10.1.0.0'; Inbox = $false
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
Test-Case 'winget に新しい版があれば ※ で知らせる (ずれではないので ⚠ にはしない)' '※ winget に固定した版より新しい 10.1.0.0 がある。上げるなら Install-OpenSSH.ps1 の -Version の既定値を変える' {
    Format-OpenSshState -State $newer -Target '10.0.0.0' -InstallDir $dir | Where-Object { $_.Text -like '※*' } | ForEach-Object Text
}

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
