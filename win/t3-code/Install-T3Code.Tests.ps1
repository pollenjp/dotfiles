# win/t3-code/Install-T3Code.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget やレジストリに触る部分は、実機で -Check と本番を打って確かめる (win/README.md の「T3 Code」)。
#
# WSL・Linux から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/t3-code/Install-T3Code.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-T3Code.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-T3Code.ps1')

$script:Failures = 0

# Actual の scriptblock を走らせ、文字列にして Expected と比べる (Install-Tailscale.Tests.ps1 と同じ)
function Test-Case {
    param([string]$Name, $Expected, [scriptblock]$Actual)
    try {
        $got = & $Actual
    } catch {
        $got = "ERROR: $($_.Exception.Message)"
    }
    $e = @($Expected | ForEach-Object { "$_" }) -join ' '
    $a = @($got | ForEach-Object { "$_" }) -join ' '
    if ([string]::Equals($e, $a, [System.StringComparison]::Ordinal)) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

$Id = 'T3Tools.T3Code'
$Pc = 'e9197887-efb3-55e0-985e-d6d3b5dd594a'
$V = '0.1.11'

# 2026-11-22 の winget-pkgs の manifests/t/T3Tools/T3Code の版を、winget show --versions の形 (新しい順) にしたもの
$show = @(
    'Found T3 Code [T3Tools.T3Code]'
    'Version'
    '-------'
    '0.1.11'
    '0.1.10'
    '0.1.9'
)

# ConvertTo-T3CodeVersion
Test-Case 'X.Y.Z の形を読む' $V { ConvertTo-T3CodeVersion -Text $V }
Test-Case '前後の空白を落とす' $V { ConvertTo-T3CodeVersion -Text "  $V `r" }
Test-Case 'nightly の版 (- の後ろ付き) は読まない' '' { ConvertTo-T3CodeVersion -Text '0.1.12-nightly.20261122.5071' }
Test-Case '空なら空' '' { ConvertTo-T3CodeVersion -Text '' }
Test-Case '$null なら空' '' { ConvertTo-T3CodeVersion -Text $null }

# Get-WingetVersionList
Test-Case 'winget show --versions の版の行だけを新しい順に拾う' @('0.1.11', '0.1.10', '0.1.9') { @(Get-WingetVersionList -Lines $show) }

# Select-T3CodeUninstallEntry
$byCode = [pscustomobject]@{ KeyName = $Pc; DisplayName = 'T3 Code 0.1.11'; DisplayVersion = '0.1.11'; InstallLocation = 'C:\Users\a\AppData\Local\Programs\t3code' }
$byName = [pscustomobject]@{ KeyName = 'other'; DisplayName = 'T3 Code'; DisplayVersion = '0.1.10'; InstallLocation = $null }
$other = [pscustomobject]@{ KeyName = 'x'; DisplayName = 'T3Code Helper Tools'; DisplayVersion = '9.9.9'; InstallLocation = $null }
Test-Case 'ProductCode のキーを先に選ぶ' '0.1.11' { (Select-T3CodeUninstallEntry -Entries @($other, $byName, $byCode) -ProductCode $Pc).DisplayVersion }
Test-Case '{} で囲んだ ProductCode のキーも選ぶ' '0.1.11' {
    $braced = [pscustomobject]@{ KeyName = "{$($Pc.ToUpperInvariant())}"; DisplayName = 'x'; DisplayVersion = '0.1.11'; InstallLocation = $null }
    (Select-T3CodeUninstallEntry -Entries @($braced) -ProductCode $Pc).DisplayVersion
}
Test-Case 'ProductCode のキーが無ければ DisplayName が T3 Code で始まるもの' '0.1.10' { (Select-T3CodeUninstallEntry -Entries @($other, $byName) -ProductCode $Pc).DisplayVersion }
Test-Case 'どれも当たらなければ空 (T3Code Helper は T3 Code でない)' '' { Select-T3CodeUninstallEntry -Entries @($other) -ProductCode $Pc }
Test-Case '項目が無ければ空' '' { Select-T3CodeUninstallEntry -Entries @() -ProductCode $Pc }

# Get-T3CodePlan
$t = [version]$V
Test-Case '入っていなければ install' 'install' { Get-T3CodePlan -Exists $false -Installed $null -Target $t }
Test-Case '版が読めなければ unknown' 'unknown' { Get-T3CodePlan -Exists $true -Installed $null -Target $t }
Test-Case '古ければ upgrade' 'upgrade' { Get-T3CodePlan -Exists $true -Installed ([version]'0.1.10') -Target $t }
Test-Case '新しければ newer (自動更新。下げない)' 'newer' { Get-T3CodePlan -Exists $true -Installed ([version]'0.1.12') -Target $t }
Test-Case '同じなら none' 'none' { Get-T3CodePlan -Exists $true -Installed $t -Target $t }

# Test-WingetPinned
Test-Case 'pin list に Id の列があれば true' $true { Test-WingetPinned -Lines @('Name    Id              Version', 'T3 Code T3Tools.T3Code  0.1.11') -PackageId $Id }
Test-Case 'pin list に Id が無ければ false' $false { Test-WingetPinned -Lines @('pin が見つかりませんでした') -PackageId $Id }

# Get-WingetCommands
Test-Case 'install は版と user スコープを名指しし、--silent で流す' 'install --id T3Tools.T3Code --exact --source winget --version 0.1.11 --scope user --silent --accept-source-agreements --accept-package-agreements --disable-interactivity' {
    @(Get-WingetCommands -Plan 'install' -PackageId $Id -Version $V)[0] -join ' '
}
Test-Case 'upgrade は --include-pinned も付ける' 'upgrade --id T3Tools.T3Code --exact --source winget --version 0.1.11 --scope user --silent --accept-source-agreements --accept-package-agreements --disable-interactivity --include-pinned' {
    @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version $V)[0] -join ' '
}
Test-Case 'none・newer では何も打たない' 0 { @(Get-WingetCommands -Plan 'none' -PackageId $Id -Version $V).Count }

# Get-T3CodeExitCode
Test-Case '入っていなければ 3' 3 { Get-T3CodeExitCode -State ([pscustomobject]@{ Plan = 'install'; Pinned = $false }) }
Test-Case '同じで pin があれば 0' 0 { Get-T3CodeExitCode -State ([pscustomobject]@{ Plan = 'none'; Pinned = $true }) }
Test-Case '新しくて pin があれば 0' 0 { Get-T3CodeExitCode -State ([pscustomobject]@{ Plan = 'newer'; Pinned = $true }) }
Test-Case '同じでも pin が無ければ 1' 1 { Get-T3CodeExitCode -State ([pscustomobject]@{ Plan = 'none'; Pinned = $false }) }
Test-Case '古ければ 1' 1 { Get-T3CodeExitCode -State ([pscustomobject]@{ Plan = 'upgrade'; Pinned = $true }) }

# Get-T3CodeApplyBlocker
Test-Case '版が読めなければ unknown' 'unknown' { Get-T3CodeApplyBlocker -Plan 'unknown' -Versions @($V) -Target $V }
Test-Case '入れるのに固定した版が winget に無ければ not-listed' 'not-listed' { Get-T3CodeApplyBlocker -Plan 'install' -Versions @('0.1.12') -Target $V }
Test-Case '版の一覧が読めなければ止めない' '' { Get-T3CodeApplyBlocker -Plan 'install' -Versions @() -Target $V }
Test-Case 'newer は止めない' '' { Get-T3CodeApplyBlocker -Plan 'newer' -Versions @('0.1.12') -Target $V }

# Format-T3CodeState
$state = [pscustomobject]@{ Plan = 'none'; Installed = $t; Location = 'C:\Users\a\AppData\Local\Programs\t3code'; Latest = '0.1.11'; Pinned = $false; Versions = @('0.1.11', '0.1.10') }
Test-Case '状態の表: 見出しと、pin が無い行だけ ⚠' @(
    'T3 Code (winget の T3Tools.T3Code)'
    '  入っている版    : 0.1.11 (C:\Users\a\AppData\Local\Programs\t3code)'
    '  固定した版      : 0.1.11 → そのまま'
    '  winget の最新版 : 0.1.11'
    '⚠ winget pin      : 無し → 足す'
) { (Format-T3CodeState -State $state -Target $V).Text }
$newer = [pscustomobject]@{ Plan = 'newer'; Installed = [version]'0.1.12'; Location = $null; Latest = '0.1.12'; Pinned = $true; Versions = @('0.1.12', '0.1.11') }
Test-Case '状態の表: 新しい版が入っていれば ※ を 2 行 (winget の新しい版・下げない)' 2 {
    @((Format-T3CodeState -State $newer -Target $V) | Where-Object { $_.Text.StartsWith('※') }).Count
}
$missing = [pscustomobject]@{ Plan = 'install'; Installed = $null; Location = $null; Latest = '0.1.12'; Pinned = $false; Versions = @('0.1.12') }
Test-Case '状態の表: 入れるのに固定した版が無ければ ⚠ の行' $true {
    @((Format-T3CodeState -State $missing -Target $V) | Where-Object { $_.Warn -and $_.Text.Contains('winget show --versions に無い') }).Count -eq 1
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件が失敗した"
    exit 1
}
Write-Host '全部通った'
