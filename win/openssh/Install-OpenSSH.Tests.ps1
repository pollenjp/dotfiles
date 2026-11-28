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

# 普段のアカウントが管理者か (Install-Bootstrap.ps1 と同じ形): トークンのグループの SID (WindowsIdentity の Claims の groupsid と denyonlysid) に
# BUILTIN\Administrators (S-1-5-32-544) があるか。UAC で権限を落とした管理者のトークンでは deny-only のグループで入る
function New-Claim { param([string]$Type, [string]$Value) [pscustomobject]@{ Type = $Type; Value = $Value } }
$filteredAdminClaims = @(
    (New-Claim 'http://schemas.microsoft.com/ws/2008/06/identity/claims/primarysid' 'S-1-5-21-1-2-3-1001')
    (New-Claim 'http://schemas.microsoft.com/ws/2008/06/identity/claims/groupsid' 'S-1-1-0')
    (New-Claim 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/denyonlysid' 'S-1-5-32-544')
)
$standardUserClaims = @(
    (New-Claim 'http://schemas.microsoft.com/ws/2008/06/identity/claims/groupsid' 'S-1-1-0')
    (New-Claim 'http://schemas.microsoft.com/ws/2008/06/identity/claims/groupsid' 'S-1-5-32-545')
)
Test-Case 'トークンのグループの SID は groupsid と denyonlysid の値 (primarysid は拾わない)' 'S-1-1-0 S-1-5-32-544' { @(Select-TokenGroupSids -Claims $filteredAdminClaims) -join ' ' }
Test-Case 'UAC で権限を落とした管理者 (deny-only の S-1-5-32-544) は管理者、普通のユーザー・空は管理者でない' 'True False False' {
    "$(Test-AdministratorsSid -Sids @(Select-TokenGroupSids -Claims $filteredAdminClaims)) $(Test-AdministratorsSid -Sids @(Select-TokenGroupSids -Claims $standardUserClaims)) $(Test-AdministratorsSid -Sids @())"
}
Test-Case '今のトークンを読む関数は、例外を出さずに真偽を返す (Windows でなければ読めないので管理者でない)' 'True True' {
    $admin = Test-AccountAdmin
    "$($admin -is [bool]) $(if ($IsWindows) { $true } else { -not $admin })"
}

# Select-ElevationHost: 自分を管理者で起動し直す host。今の pwsh が MSIX (WindowsApps の下) なら、MSI の pwsh があればそれを使い、無ければ
# 管理者の PC は MSIX のまま (同じアカウントで昇格する)、管理者でない PC は止める (UAC で別の管理者のアカウントに昇格した側では、MSIX の pwsh を
# 起こせない)。ほかは今の host
$msixPwsh = 'C:\Program Files\WindowsApps\Microsoft.PowerShell-LTS_7.6.10.0_x64__8wekyb3d8bbwe\pwsh.exe'
$msiPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$winPs = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
Test-Case '今の pwsh が MSIX で MSI の pwsh があれば、管理者かを問わず MSI の pwsh で昇格し直す' "$msiPwsh|$msiPwsh" {
    "$(Select-ElevationHost -CurrentHost $msixPwsh -MsiPwsh $msiPwsh -MsiPwshExists $true -AccountAdmin $true)|$(Select-ElevationHost -CurrentHost $msixPwsh -MsiPwsh $msiPwsh -MsiPwshExists $true -AccountAdmin $false)"
}
Test-Case '今の pwsh が MSIX で MSI の pwsh が無ければ、管理者の PC は MSIX のまま、管理者でない PC は止める (空)' "$msixPwsh|" {
    "$(Select-ElevationHost -CurrentHost $msixPwsh -MsiPwsh $msiPwsh -MsiPwshExists $false -AccountAdmin $true)|$(Select-ElevationHost -CurrentHost $msixPwsh -MsiPwsh $msiPwsh -MsiPwshExists $false -AccountAdmin $false)"
}
Test-Case 'MSI・Windows PowerShell 5.1・ほかの pwsh は、管理者でない PC で MSI が無くても今の host' "$msiPwsh|$winPs|C:\tools\pwsh\pwsh.exe" {
    (@($msiPwsh, $winPs, 'C:\tools\pwsh\pwsh.exe') | ForEach-Object { Select-ElevationHost -CurrentHost $_ -MsiPwsh $msiPwsh -MsiPwshExists $false -AccountAdmin $false }) -join '|'
}

# Format-ElevationStopNote: 止めるとき (Select-ElevationHost が空) は、UAC を出さずに止めたことと、bootstrap を流し直すと MSI が入ることを出す
Test-Case '止めるときは UAC を出さずに止めたことと、わけ・bootstrap を流し直すと MSI の PowerShell 7 が入ることを ※ で出す' "UAC は出さずに止めた (この pwsh は MSIX: $msixPwsh)|True|True|True" {
    $lines = @(Format-ElevationStopNote -CurrentHost $msixPwsh -MsiPwsh $msiPwsh)
    $why = $lines[1].StartsWith('※ 普段のアカウントが管理者でない PC では')
    $noMsi = $lines[1].Contains("MSI の PowerShell 7 ($msiPwsh) も無い")
    $bootstrap = $lines[1].Contains('win\bootstrap\Install-Bootstrap.ps1) を普通の PowerShell で流し直すと、管理者でない PC には MSI の PowerShell 7 が入る')
    "$($lines[0])|$why|$noMsi|$bootstrap"
}

# Format-WingetMissingNote: 昇格した側で winget が見つからないとき。別の管理者のアカウントには App Installer (winget) が登録されていないことがある
# (その PC に一度もサインインしていない)。登録はこちらではせず、手を ※ で出す (Microsoft の winget の文書の手)
Test-Case '昇格した側で winget が見つからなければ、そのアカウントと、サインインするか Add-AppxPackage で登録する手を ※ で出す' 'winget が見つからない (昇格した側のアカウント: it-admin)|True|True' {
    $lines = @(Format-WingetMissingNote -Account 'it-admin')
    "$($lines[0])|$($lines[1].StartsWith('※ UAC で別の管理者のアカウントの資格情報を入れたなら'))|$($lines[1].Contains('Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'))"
}

# Invoke-Elevated: 選んだ host で起動し直す・止める・子がログを書かずに落ちたときの行。Get-Process・Test-AccountAdmin・Start-Process・Write-Host を
# 偽物に替え、LOCALAPPDATA と ProgramFiles (MSI の pwsh の置き場所) は一時ディレクトリにする
function Invoke-ElevatedScenario {
    param([string]$HostExe, [bool]$Admin = $true, [bool]$Msi = $false, [bool]$Throw = $false, [int]$ExitCode = 0)
    $said = [System.Collections.Generic.List[string]]::new()
    $started = [System.Collections.Generic.List[string]]::new()
    function Get-Process { param($Id) [pscustomobject]@{ Path = $HostExe } }
    function Test-AccountAdmin { $Admin }
    function Start-Process {
        param([string]$FilePath, [string[]]$ArgumentList, [string]$Verb, [switch]$Wait, [switch]$PassThru)
        $started.Add($FilePath)
        if ($Throw) { throw 'アクセスが拒否されました。' }
        [pscustomobject]@{ ExitCode = $ExitCode }
    }
    function Write-Host { param($Object, $ForegroundColor) $said.Add("$Object") }
    $savedLocal = $env:LOCALAPPDATA
    $savedPf = $env:ProgramFiles
    $root = Join-Path ([IO.Path]::GetTempPath()) "install-openssh-elevated-$PID"
    $env:LOCALAPPDATA = Join-Path $root 'local'
    $env:ProgramFiles = Join-Path $root 'pf'
    $msiPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if ($Msi) {
        New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $env:ProgramFiles 'PowerShell') '7') | Out-Null
        Set-Content -LiteralPath $msiPath -Value ''
    }
    try {
        $result = Invoke-Elevated -Version '10.4.0.0'
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = $savedLocal
        $env:ProgramFiles = $savedPf
    }
    [pscustomobject]@{ Result = $result; Started = (@($started) -join ','); Said = @($said); MsiPath = $msiPath }
}
Test-Case '管理者でない PC で今の pwsh が MSIX でも、MSI の pwsh があればそれで昇格し直し、そう出す' 'True|True|True' {
    $r = Invoke-ElevatedScenario -HostExe $msixPwsh -Admin $false -Msi $true
    "$($r.Result)|$($r.Started -eq $r.MsiPath)|$(@($r.Said | Where-Object { $_.StartsWith('昇格した側は MSI の PowerShell 7') }).Count -eq 1)"
}
Test-Case '管理者でない PC で今の pwsh が MSIX で MSI の pwsh が無ければ、UAC を出さずに止め、※ を出す' 'False||True|True' {
    $r = Invoke-ElevatedScenario -HostExe $msixPwsh -Admin $false -Msi $false
    "$($r.Result)|$($r.Started)|$(@($r.Said | Where-Object { $_.StartsWith('UAC は出さずに止めた') }).Count -eq 1)|$(@($r.Said | Where-Object { $_.StartsWith('※ 普段のアカウントが管理者でない PC では') }).Count -eq 1)"
}
Test-Case '管理者の PC は、MSI の pwsh が無ければ MSIX の pwsh のまま昇格し直す (同じアカウントで昇格する)' "True|$msixPwsh" {
    $r = Invoke-ElevatedScenario -HostExe $msixPwsh -Admin $true -Msi $false; "$($r.Result)|$($r.Started)"
}
Test-Case 'MSI の pwsh は、管理者でない PC でもそのまま使う' "True|$msiPwsh" { $r = Invoke-ElevatedScenario -HostExe $msiPwsh -Admin $false -Msi $false; "$($r.Result)|$($r.Started)" }
Test-Case '子がログを書かずに落ちたら、終了コードを出して失敗にする (MSIX の ※ は出さない)' 'False|True|0' {
    $r = Invoke-ElevatedScenario -HostExe $msiPwsh -ExitCode -1073741515
    "$($r.Result)|$(@($r.Said | Where-Object { $_ -eq '管理者の PowerShell がログを書く前に終わった (終了コード 0xC0000135)' }).Count -eq 1)|$(@($r.Said | Where-Object { $_.StartsWith('※') }).Count)"
}
Test-Case '昇格を起こせなければ (UAC で断った)、そう出して失敗にする' 'False|True' {
    $r = Invoke-ElevatedScenario -HostExe $msixPwsh -Admin $true -Throw $true
    "$($r.Result)|$(@($r.Said | Where-Object { $_.StartsWith('管理者で起動できなかった (UAC で断った?)') }).Count -eq 1)"
}

# Invoke-OpenSshFix: 昇格した側で winget が見つからなければ、winget を打たずに ※ を書いて失敗にする (ssh-agent の後始末は winget が要らないので
# する)。Get-Command・Invoke-Winget・Write-Step・サービスの cmdlet を偽物に替える
function Invoke-FixScenario {
    param([string]$Plan, [bool]$HaveWinget)
    $fixSteps = [System.Collections.Generic.List[string]]::new()
    $fixWinget = [System.Collections.Generic.List[string]]::new()
    $fixAgent = [System.Collections.Generic.List[string]]::new()
    function Get-Command { param($Name, $ErrorAction) if ($HaveWinget) { [pscustomobject]@{ Name = 'winget' } } }
    function Invoke-Winget { param([string[]]$Arguments) $fixWinget.Add($Arguments[0]); [pscustomobject]@{ ExitCode = 0; Lines = @() } }
    function Write-Step { param([string]$Message) $fixSteps.Add($Message) }
    function Get-Service { param($Name, $ErrorAction) [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
    function Stop-Service { param($Name, [switch]$Force) $fixAgent.Add('stop') }
    function Set-Service { param($Name, $StartupType) $fixAgent.Add("set-$StartupType") }
    $saved = $env:USERNAME
    $env:USERNAME = 'it-admin'
    try {
        $ok = Invoke-OpenSshFix -Plan $Plan -PackageId $Id -Version '10.4.0.0'
    } finally {
        $env:USERNAME = $saved
    }
    "$ok|$($fixWinget -join ',')|$($fixAgent -join ',')|$(@($fixSteps | Where-Object { $_ -eq 'winget が見つからない (昇格した側のアカウント: it-admin)' }).Count)"
}
Test-Case '昇格した側で winget が見つからなければ、winget を打たずに ※ を書いて失敗にし、ssh-agent の後始末はする' 'False||stop,set-Disabled|1' { Invoke-FixScenario -Plan 'install' -HaveWinget $false }
Test-Case '揃えるのが ssh-agent だけなら、winget が無くても ssh-agent を止めて成功にする' 'True||stop,set-Disabled|0' { Invoke-FixScenario -Plan 'none' -HaveWinget $false }
Test-Case 'winget があれば打つ' 'True|install|stop,set-Disabled|0' { Invoke-FixScenario -Plan 'install' -HaveWinget $true }

# Invoke-InstallOpenSsh を管理者の窓から直に打った形 (-LogPath なし・Test-IsAdmin が真) で流す。Write-Step と Invoke-OpenSshFix は本物のまま
# にし、状態の読み取り・動いている ssh.exe など・winget・サービスの cmdlet・ssh-add・Write-Host を偽物に替える。本体と同じく StrictMode の下で、
# $script:StepLog を一度も代入していない形 (打った直後の本体) から始める。偽物が使う変数は、本体の関数の中の変数 ($agent など) と名前を分ける
# (偽物は呼んだ側の変数も見えるので、同じ名前だと本体の変数を拾う)
function Invoke-AdminDirectScenario {
    param([string]$Plan, [version]$Installed)
    $adminSaid = [System.Collections.Generic.List[string]]::new()
    $adminWinget = [System.Collections.Generic.List[string]]::new()
    $adminAgent = [System.Collections.Generic.List[string]]::new()
    # 1 回目は揃える前 (ssh-agent が自動・実行中)、2 回目は揃えた後に読み直した状態
    $adminStates = [System.Collections.Generic.Queue[object]]::new()
    $adminStates.Enqueue([pscustomobject]@{
            Installed = $Installed; Plan = $Plan; AgentStatus = 'Running'; AgentStartType = 'Automatic'
            AgentDisabled = $false; Pinned = $true; Latest = [version]'10.4.0.0'; Inbox = $false; Server = $false
        })
    $adminStates.Enqueue([pscustomobject]@{
            Installed = [version]'10.4.0.0'; Plan = 'none'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
            AgentDisabled = $true; Pinned = $true; Latest = [version]'10.4.0.0'; Inbox = $false; Server = $false
        })
    function Get-Command { param($Name, $ErrorAction) [pscustomobject]@{ Name = 'winget' } }
    function Get-OpenSshState { param($PackageId, $InstallDir, $Target) $adminStates.Dequeue() }
    function Get-BusyOpenSshProcess { @() }
    function Test-IsAdmin { $true }
    function Invoke-Winget { param([string[]]$Arguments) $adminWinget.Add($Arguments[0]); [pscustomobject]@{ ExitCode = 0; Lines = @() } }
    function Get-Service { param($Name, $ErrorAction) [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
    function Stop-Service { param($Name, [switch]$Force) $adminAgent.Add('stop') }
    function Set-Service { param($Name, $StartupType) $adminAgent.Add("set-$StartupType") }
    function Get-AgentKeyCount { param($SshAddExe) 2 }
    function Write-Host { param($Object, $ForegroundColor) $adminSaid.Add("$Object") }
    Remove-Variable -Name StepLog -Scope Script -ErrorAction SilentlyContinue
    $savedPf = $env:ProgramFiles
    $env:ProgramFiles = Join-Path ([IO.Path]::GetTempPath()) "install-openssh-admin-$PID"
    try {
        $code = Invoke-InstallOpenSsh -Version '10.4.0.0'
    } finally {
        $env:ProgramFiles = $savedPf
    }
    $wingetShown = @($adminSaid | Where-Object { $_.StartsWith("winget $Plan --id $Id ") }).Count
    $stopShown = @($adminSaid | Where-Object { $_ -eq 'ssh-agent を止めた' }).Count
    $disableShown = @($adminSaid | Where-Object { $_ -eq 'ssh-agent を無効にした' }).Count
    "$code|$($adminWinget -join ',')|$($adminAgent -join ',')|$wingetShown|$stopShown|$disableShown"
}
Test-Case '管理者の窓から直に打つ (-LogPath なし) と、StepLog を代入していない形からでも、winget と ssh-agent の行を画面に出して揃える' '0|upgrade|stop,set-Disabled|1|1|1' {
    Invoke-AdminDirectScenario -Plan 'upgrade' -Installed '10.0.0.0'
}
Test-Case '管理者の窓から直に打ち、ssh-agent だけ直すときも、止めてから無効にするまで進む' '0||stop,set-Disabled|0|1|1' {
    Invoke-AdminDirectScenario -Plan 'none' -Installed '10.4.0.0'
}

# 管理者で起動し直した子 (-LogPath): 揃える段の行を画面とログのファイルの両方に書く (親がログを読んで出す)。Write-Step と Invoke-OpenSshFix は
# 本物のまま、winget・サービスの cmdlet・Write-Host を偽物に替える。ProgramFiles は一時ディレクトリにする (ssh.exe が無いので入れる)。
# 終わったら、子の道が代入した $script:StepLog を消す (後ろの試験に残さない)
function Invoke-ChildLogScenario {
    $childWinget = [System.Collections.Generic.List[string]]::new()
    function Get-Command { param($Name, $ErrorAction) [pscustomobject]@{ Name = 'winget' } }
    function Invoke-Winget { param([string[]]$Arguments) $childWinget.Add($Arguments[0]); [pscustomobject]@{ ExitCode = 0; Lines = @() } }
    function Get-Service { param($Name, $ErrorAction) [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
    function Stop-Service { param($Name, [switch]$Force) }
    function Set-Service { param($Name, $StartupType) }
    function Write-Host { param($Object, $ForegroundColor) }
    $savedPf = $env:ProgramFiles
    $root = Join-Path ([IO.Path]::GetTempPath()) "install-openssh-child-$PID"
    $env:ProgramFiles = Join-Path $root 'pf'
    $log = Join-Path $root 'Install-OpenSSH.log'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    try {
        $code = Invoke-InstallOpenSsh -Version '10.4.0.0' -LogPath $log
        $logged = @(Get-Content -LiteralPath $log -Encoding utf8)
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        $env:ProgramFiles = $savedPf
        Remove-Variable -Name StepLog -Scope Script -ErrorAction SilentlyContinue
    }
    "$code|$($childWinget -join ',')|$($logged.Count)|$($logged[0].StartsWith("winget install --id $Id "))|$($logged[1])|$($logged[2])"
}
Test-Case '管理者で起動し直した子 (-LogPath) は、揃える段の行をログのファイルにも書く (親が読んで出す)' '0|install|3|True|ssh-agent を止めた|ssh-agent を無効にした' {
    Invoke-ChildLogScenario
}

# Invoke-Winget (本物): winget は管へ UTF-8 で書く。コンソールの文字コードが UTF-8 でない窓 (UAC で昇格し直した子の窓・手で打った窓。日本語の
# Windows の既定は CP932。ここでは ISO-8859-1 で代える) でも、打つ間だけ UTF-8 で読み、帯 (█▒) の行を除いて日本語を化けさせず、打った後は
# 元に戻す。もう UTF-8 の窓 (runner と WSL の wrapper は [Text.Encoding]::UTF8 にしてから流す) では替えない。偽の winget を PATH の先頭に置く (Linux)
function Invoke-RealWinget {
    param([Text.Encoding]$Console)
    $bin = Join-Path ([IO.Path]::GetTempPath()) ('install-openssh-winget-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $bin | Out-Null
    Set-Content -LiteralPath (Join-Path $bin 'winget') -Value "#!/bin/sh`nprintf '  \342\226\210\342\226\210\342\226\222  1 MB / 2 MB\n'`nprintf '\343\201\202\343\201\204 ok\n'`nexit 7"
    & chmod +x (Join-Path $bin 'winget')
    $savedPath = $env:PATH
    $savedEncoding = [Console]::OutputEncoding
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
    try {
        [Console]::OutputEncoding = $Console
        $r = Invoke-Winget -Arguments @('install')
        $after = [Console]::OutputEncoding
    } finally {
        [Console]::OutputEncoding = $savedEncoding
        $env:PATH = $savedPath
        Remove-Item -LiteralPath $bin -Recurse -Force
    }
    "$($r.ExitCode)|$($r.Lines -join '|')|$($after.CodePage)|$($after.GetPreamble().Length)"
}
Test-Case 'winget の出力は UTF-8 で読み (帯を除き、日本語は化けない)、終わったらコンソールの文字コードを戻す' '7|あい ok|28591|0' {
    Invoke-RealWinget -Console ([Text.Encoding]::GetEncoding('ISO-8859-1'))
}
Test-Case 'もう UTF-8 の窓 (runner・WSL の wrapper の BOM 付きの UTF-8) では文字コードを替えない' '7|あい ok|65001|3' {
    Invoke-RealWinget -Console ([Text.Encoding]::UTF8)
}

# 写しの関数の本文 (`{ … }`)。改行は LF にそろえて比べる (Windows の core.autocrlf の clone では、.gitattributes で -text の
# Install-PowerToys.ps1 だけが LF のまま残る)。関数が無ければ $null
function Get-FunctionBody {
    param([string]$Path, [string]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $Name) }, $true))
    if ($fn.Count -eq 0) { return $null }
    $fn[0].Body.Extent.Text -replace "`r`n", "`n"
}
$winScripts = @(Get-ChildItem -Path (Join-Path (Split-Path -Parent $PSScriptRoot) '*\*.ps1') -File | Where-Object { $_.Name -notlike '*.Tests.ps1' } | Sort-Object FullName)
function Get-ScriptLabel { param($File) "$($File.Directory.Name)/$($File.Name)" }

# winget の出力を取り込むほかの ps1 (Install-Sshd.ps1・Install-Herdr.ps1 など) の Invoke-Winget は、上で確かめたこの ps1 の Invoke-Winget と
# 同じ本文 (どの窓から打っても UTF-8 で読む。写しをそろえる)。bootstrap だけは Invoke-Native -Utf8 を通す別の形で、自分の試験で確かめる
Test-Case 'winget を打つほかの ps1 の Invoke-Winget は、この ps1 と同じ本文 (bootstrap を除く)' '' {
    $want = Get-FunctionBody -Path (Join-Path $PSScriptRoot 'Install-OpenSSH.ps1') -Name 'Invoke-Winget'
    @($winScripts | Where-Object { (Get-ScriptLabel $_) -ne 'bootstrap/Install-Bootstrap.ps1' } | ForEach-Object {
            $body = Get-FunctionBody -Path $_.FullName -Name 'Invoke-Winget'
            if (($null -ne $body) -and ($body -cne $want)) { Get-ScriptLabel $_ }
        }) -join ' '
}
# Invoke-Winget を持つ ps1 の数 (増えた・減ったら、ここと win/README.md の「Install-OpenSSH.ps1 を書くときの注意」を直す)。winget の portable の
# 道具 (fzf・ghq・starship・ntn) は、共通の枠 (winget/WingetPortable.ps1) の 1 本を使う
Test-Case 'Invoke-Winget を持つ ps1 は 12 本 (bootstrap と、同じ本文の 11 本)' 12 {
    @($winScripts | Where-Object { $null -ne (Get-FunctionBody -Path $_.FullName -Name 'Invoke-Winget') }).Count
}

# Format-WingetMissingNote (昇格した側で winget が見つからないときの行) は、bootstrap・Install-OpenSSH・Install-Sshd で同じ本文
Test-Case 'Format-WingetMissingNote は bootstrap・Install-OpenSSH・Install-Sshd にあり、同じ本文' 'bootstrap/Install-Bootstrap.ps1 openssh/Install-OpenSSH.ps1 openssh/Install-Sshd.ps1|' {
    $want = Get-FunctionBody -Path (Join-Path $PSScriptRoot 'Install-OpenSSH.ps1') -Name 'Format-WingetMissingNote'
    $have = @($winScripts | Where-Object { $null -ne (Get-FunctionBody -Path $_.FullName -Name 'Format-WingetMissingNote') })
    $differ = @($have | Where-Object { (Get-FunctionBody -Path $_.FullName -Name 'Format-WingetMissingNote') -cne $want } | ForEach-Object { Get-ScriptLabel $_ })
    "$(@($have | ForEach-Object { Get-ScriptLabel $_ }) -join ' ')|$($differ -join ' ')"
}

# 揃えた・入れた後の ssh-add -l の行。1Password の SSH agent を使わないホスト (-NoOnePassword) は出さない
Test-Case 'ssh-add -l の行: 鍵が見えれば本数' '  ssh-add -l      : 鍵 2 本' { Format-AgentKeyLine -Keys 2 }
Test-Case 'ssh-add -l の行: 入れたばかり (-IfMissing) で見えなければ、1Password の SSH agent を有効にした後の確かめ方' '  ssh-add -l      : 鍵が見えない → 1Password の SSH agent を有効にしたら、Install-OpenSSH -Check で確かめる' {
    Format-AgentKeyLine -Keys $null -IfMissing
}
Test-Case 'ssh-add -l の行: 揃えた後に見えなければ、1Password を起動し直す手' '  ssh-add -l      : 鍵が見えない → 1Password をトレイから終了して起動し直し、もう一度 -Check で確かめる' {
    Format-AgentKeyLine -Keys $null
}
Test-Case 'ssh-add -l の行: 1Password を使わないホスト (-NoOnePassword) は、見えても見えなくても出さない' '0 0 0' {
    "$(@(Format-AgentKeyLine -Keys $null -IfMissing -NoOnePassword).Count) $(@(Format-AgentKeyLine -Keys $null -NoOnePassword).Count) $(@(Format-AgentKeyLine -Keys 2 -NoOnePassword).Count)"
}
# 引数なしで揃えた後の「揃った」: 版・ssh-agent・pin に加えて 1Password の鍵が見えること。-NoOnePassword は鍵を数えない
Test-Case '揃った: 鍵が見えなければ揃っていない。1Password を使わないホストは鍵を数えない' 'True False True False' {
    $synced = [pscustomobject]@{ Plan = 'none'; AgentDisabled = $true; Pinned = $true }
    "$(Test-OpenSshSynced -State $synced -Keys 1) $(Test-OpenSshSynced -State $synced -Keys $null) $(Test-OpenSshSynced -State $synced -Keys $null -NoOnePassword) $(Test-OpenSshSynced -State $unpinned -Keys $null -NoOnePassword)"
}

# 入っていない PC で -IfMissing を打った形 (管理者の窓から。Test-IsAdmin が真) で流し、画面に出た行を返す。-NoOnePassword なら ssh-add -l を
# 打たず、1Password の行を出さない。状態の読み取り・winget・サービスの cmdlet・ssh-add・Write-Host を偽物に替える
function Invoke-IfMissingScenario {
    param([switch]$NoOnePassword)
    $missSaid = [System.Collections.Generic.List[string]]::new()
    $missKeys = [System.Collections.Generic.List[string]]::new()
    $missStates = [System.Collections.Generic.Queue[object]]::new()
    $missStates.Enqueue([pscustomobject]@{
            Installed = $null; Plan = 'install'; AgentStatus = $null; AgentStartType = $null
            AgentDisabled = $true; Pinned = $false; Latest = [version]'10.4.0.0'; Inbox = $true; Server = $false
        })
    $missStates.Enqueue([pscustomobject]@{
            Installed = [version]'10.4.0.0'; Plan = 'none'; AgentStatus = 'Stopped'; AgentStartType = 'Disabled'
            AgentDisabled = $true; Pinned = $true; Latest = [version]'10.4.0.0'; Inbox = $true; Server = $false
        })
    function Get-Command { param($Name, $ErrorAction) [pscustomobject]@{ Name = 'winget' } }
    function Get-OpenSshState { param($PackageId, $InstallDir, $Target) $missStates.Dequeue() }
    function Test-IsAdmin { $true }
    function Invoke-Winget { param([string[]]$Arguments) [pscustomobject]@{ ExitCode = 0; Lines = @() } }
    function Get-Service { param($Name, $ErrorAction) $null }
    function Get-AgentKeyCount { param($SshAddExe) $missKeys.Add('ssh-add'); $null }
    function Write-Host { param($Object, $ForegroundColor) $missSaid.Add("$Object") }
    Remove-Variable -Name StepLog -Scope Script -ErrorAction SilentlyContinue
    $savedPf = $env:ProgramFiles
    $env:ProgramFiles = Join-Path ([IO.Path]::GetTempPath()) "install-openssh-ifmissing-$PID"
    try {
        $code = Invoke-InstallOpenSsh -Version '10.4.0.0' -IfMissing -NoOnePassword:$NoOnePassword
    } finally {
        $env:ProgramFiles = $savedPf
    }
    $onePassword = @($missSaid | Where-Object { $_.Contains('1Password') }).Count
    "$code|$($missKeys.Count)|$onePassword|$(@($missSaid | Where-Object { $_.Contains('入れた') }).Count -gt 0)"
}
Test-Case '-IfMissing で入れた後、鍵が見えなければ 1Password の SSH agent の案内を出す' '0|1|1|True' { Invoke-IfMissingScenario }
Test-Case '-IfMissing -NoOnePassword で入れた後は、ssh-add -l を打たず、1Password の行を出さない' '0|0|0|True' { Invoke-IfMissingScenario -NoOnePassword }

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
