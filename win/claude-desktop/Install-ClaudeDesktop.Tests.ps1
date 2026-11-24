# win/claude-desktop/Install-ClaudeDesktop.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget・Appx・サービス・レジストリに触る部分は、実機で -Check と本番を打って確かめる (win/README.md の「Claude Desktop」)。
# 昇格した Windows PowerShell に渡す本文だけは、偽の winget を置いて今の PowerShell で実際に流し、出力と終了コードを読めるかを確かめる
# (昇格はしない)。
#
# WSL・Linux から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/claude-desktop/Install-ClaudeDesktop.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-ClaudeDesktop.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-ClaudeDesktop.ps1')

$script:Failures = 0

# Actual の scriptblock を走らせ、文字列にして Expected と比べる (Install-T3Code.Tests.ps1 と同じ)
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

$Id = 'Anthropic.Claude'
$Family = 'Claude_pzs8sxrjxfjjc'
$V = '5.11492.5'
$Loc = 'C:\Program Files\WindowsApps\Claude_5.11492.5.0_x64__pzs8sxrjxfjjc'

# 2026-11-24 の winget-pkgs の manifests/a/Anthropic/Claude の版 (新しいものから)を、winget show --versions の形にしたもの
$show = @(
    'Found Claude [Anthropic.Claude]'
    'Version'
    '-------'
    '6.28899.6'
    '6.28899.2'
    '5.11492.5'
    '5.11492.2'
)

# 状態 (Get-ClaudeDesktopState の形)。$Values で欄を差し替える
function New-State {
    param([hashtable]$Values = @{})
    $base = [ordered]@{
        Exists        = $true
        Location      = $Loc
        Installed     = [version]'5.11492.5.0'
        InstalledText = '5.11492.5.0'
        Plan          = 'none'
        Pinned        = $true
        Versions      = @('6.28899.6', '5.11492.5')
        Latest        = '6.28899.6'
        Service       = 'Running'
        VmPlatform    = 'on'
        Legacy        = $false
        LegacyVersion = $null
    }
    foreach ($k in $Values.Keys) { $base[$k] = $Values[$k] }
    [pscustomobject]$base
}

# ConvertTo-ClaudeDesktopVersion
Test-Case 'winget の版 (3 個) は 4 個目を 0 にする' '5.11492.5.0' { ConvertTo-ClaudeDesktopVersion -Text $V }
Test-Case 'MSIX の版 (4 個) はそのまま' '5.11492.5.2' { ConvertTo-ClaudeDesktopVersion -Text '5.11492.5.2' }
Test-Case '3 個と、0 を足した 4 個は同じ版 ([version] のままだと 3 個の方が小さい)' $true {
    (ConvertTo-ClaudeDesktopVersion -Text $V) -eq (ConvertTo-ClaudeDesktopVersion -Text '5.11492.5.0')
}
Test-Case '前後の空白を落とす' '6.28899.6.0' { ConvertTo-ClaudeDesktopVersion -Text "  6.28899.6 `r" }
Test-Case '2 個は読まない' '' { ConvertTo-ClaudeDesktopVersion -Text '5.11492' }
Test-Case '5 個は読まない' '' { ConvertTo-ClaudeDesktopVersion -Text '1.2.3.4.5' }
Test-Case '数字でないものは読まない' '' { ConvertTo-ClaudeDesktopVersion -Text '5.11492.5-beta' }
Test-Case '$null なら空' '' { ConvertTo-ClaudeDesktopVersion -Text $null }

# Get-WingetVersionList
Test-Case 'winget show --versions の版の行だけを新しい順に拾う' @('6.28899.6', '6.28899.2', '5.11492.5', '5.11492.2') { @(Get-WingetVersionList -Lines $show) }

# ConvertFrom-ClaudeAppxLines・Select-ClaudeAppxEntry
$appxLines = @(
    "Claude`tClaude_otherpublisher`t9.9.9.0`tC:\x"
    "Claude`t$Family`t5.11492.5.0`t$Loc"
    "欄の足りない行"
    "Claude`t$Family`t6.28899.6.0`tC:\Program Files\WindowsApps\Claude_6.28899.6.0_x64__pzs8sxrjxfjjc`r"
)
Test-Case 'Get-AppxPackage の 1 行を 4 つの欄に分ける (欄の足りない行は飛ばす)' 3 { @(ConvertFrom-ClaudeAppxLines -Lines $appxLines).Count }
Test-Case '置き場所の末尾の CR を落とす' 'C:\Program Files\WindowsApps\Claude_6.28899.6.0_x64__pzs8sxrjxfjjc' {
    @(ConvertFrom-ClaudeAppxLines -Lines $appxLines)[2].InstallLocation
}
Test-Case 'PackageFamilyName の合うもののうち、版のいちばん新しいものを選ぶ (発行元の違う Claude は数えない)' '6.28899.6.0' {
    (Select-ClaudeAppxEntry -Entries @(ConvertFrom-ClaudeAppxLines -Lines $appxLines) -FamilyName $Family).Version
}
Test-Case 'PackageFamilyName は大文字小文字を問わない' '5.11492.5.0' {
    $upper = [pscustomobject]@{ Name = 'Claude'; PackageFamilyName = $Family.ToUpperInvariant(); Version = '5.11492.5.0'; InstallLocation = $Loc }
    (Select-ClaudeAppxEntry -Entries @($upper) -FamilyName $Family).Version
}
Test-Case '版の読めないものは、ほかに無いときだけ選ぶ' @('?', '5.11492.5.0') {
    $odd = [pscustomobject]@{ Name = 'Claude'; PackageFamilyName = $Family; Version = '?'; InstallLocation = $Loc }
    $good = [pscustomobject]@{ Name = 'Claude'; PackageFamilyName = $Family; Version = '5.11492.5.0'; InstallLocation = $Loc }
    (Select-ClaudeAppxEntry -Entries @($odd) -FamilyName $Family).Version
    (Select-ClaudeAppxEntry -Entries @($odd, $good) -FamilyName $Family).Version
}
Test-Case '合うものが無ければ空' '' { Select-ClaudeAppxEntry -Entries @(ConvertFrom-ClaudeAppxLines -Lines @($appxLines[0])) -FamilyName $Family }
Test-Case '項目が無ければ空' '' { Select-ClaudeAppxEntry -Entries @() -FamilyName $Family }

# Get-ClaudeDesktopPlan
$t = ConvertTo-ClaudeDesktopVersion -Text $V
Test-Case '入っていなければ install' 'install' { Get-ClaudeDesktopPlan -Exists $false -Installed $null -Target $t }
Test-Case '版が読めなければ unknown' 'unknown' { Get-ClaudeDesktopPlan -Exists $true -Installed $null -Target $t }
Test-Case '古ければ upgrade' 'upgrade' { Get-ClaudeDesktopPlan -Exists $true -Installed ([version]'5.11492.2.0') -Target $t }
Test-Case '新しければ newer (自動更新。下げない)' 'newer' { Get-ClaudeDesktopPlan -Exists $true -Installed ([version]'6.28899.6.0') -Target $t }
Test-Case 'MSIX の版 (末尾 .0) が固定した版と同じなら none' 'none' {
    Get-ClaudeDesktopPlan -Exists $true -Installed (ConvertTo-ClaudeDesktopVersion -Text '5.11492.5.0') -Target $t
}

# Test-WingetPinned
Test-Case 'pin list に Id の列があれば true' $true { Test-WingetPinned -Lines @('Name   Id               Version', 'Claude Anthropic.Claude 5.11492.5.0') -PackageId $Id }
Test-Case 'pin list に Id が無ければ false (Anthropic.ClaudeCode は別のもの)' $false { Test-WingetPinned -Lines @('Claude Code Anthropic.ClaudeCode 2.1.318') -PackageId $Id }

# Get-WingetCommands
Test-Case 'install は版と MSIX を名指しする (付けないと winget は旧来の exe を選ぶ)' 'install --id Anthropic.Claude --exact --source winget --version 5.11492.5 --installer-type msix --accept-source-agreements --accept-package-agreements --disable-interactivity' {
    @(Get-WingetCommands -Plan 'install' -PackageId $Id -Version $V)[0] -join ' '
}
Test-Case 'upgrade は --include-pinned も付ける' 'upgrade --id Anthropic.Claude --exact --source winget --version 5.11492.5 --installer-type msix --accept-source-agreements --accept-package-agreements --disable-interactivity --include-pinned' {
    @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version $V)[0] -join ' '
}
Test-Case 'install・upgrade は --scope と --silent を付けない' $false {
    $all = @(Get-WingetCommands -Plan 'install' -PackageId $Id -Version $V)[0] + @(Get-WingetCommands -Plan 'upgrade' -PackageId $Id -Version $V)[0]
    ($all -contains '--scope') -or ($all -contains '--silent')
}
Test-Case 'none・newer では何も打たない' 0 { @(Get-WingetCommands -Plan 'none' -PackageId $Id -Version $V).Count }

# Get-WingetPinnedHint
Test-Case 'pin に止められた (0x8A150068) なら外し方を添える' $true { (Get-WingetPinnedHint -ExitCode -1978335128 -PackageId $Id).Contains('winget pin remove --id Anthropic.Claude --exact') }
Test-Case 'ほかの終了コードなら何も添えない' '' { Get-WingetPinnedHint -ExitCode 1 -PackageId $Id }

# Get-ClaudeDesktopExitCode・Test-ClaudeDesktopLegacyOnly
Test-Case '入っていなければ 3 (旧来の exe の Claude があっても)' 3 { Get-ClaudeDesktopExitCode -State (New-State @{ Plan = 'install'; Pinned = $false; Legacy = $true }) }
Test-Case '同じで pin があれば 0' 0 { Get-ClaudeDesktopExitCode -State (New-State) }
Test-Case '新しくて pin があれば 0' 0 { Get-ClaudeDesktopExitCode -State (New-State @{ Plan = 'newer' }) }
Test-Case '同じでも pin が無ければ 1' 1 { Get-ClaudeDesktopExitCode -State (New-State @{ Pinned = $false }) }
Test-Case '古ければ 1' 1 { Get-ClaudeDesktopExitCode -State (New-State @{ Plan = 'upgrade' }) }
Test-Case '揃っていても旧来の exe の Claude が残っていれば 1' 1 { Get-ClaudeDesktopExitCode -State (New-State @{ Legacy = $true }) }
Test-Case '残りが旧来の exe の Claude だけなら LegacyOnly' @($true, $false, $false) {
    Test-ClaudeDesktopLegacyOnly -State (New-State @{ Legacy = $true })
    Test-ClaudeDesktopLegacyOnly -State (New-State @{ Legacy = $true; Pinned = $false })
    Test-ClaudeDesktopLegacyOnly -State (New-State)
}

# Get-ClaudeDesktopApplyBlocker
Test-Case '版が読めなければ unknown' 'unknown' { Get-ClaudeDesktopApplyBlocker -Plan 'unknown' -Versions @($V) -Target $V }
Test-Case '入れるのに固定した版が winget に無ければ not-listed' 'not-listed' { Get-ClaudeDesktopApplyBlocker -Plan 'install' -Versions @('6.28899.6') -Target $V }
Test-Case '版の一覧が読めなければ止めない' '' { Get-ClaudeDesktopApplyBlocker -Plan 'install' -Versions @() -Target $V }
Test-Case 'newer は止めない' '' { Get-ClaudeDesktopApplyBlocker -Plan 'newer' -Versions @('6.28899.6') -Target $V }

# ConvertFrom-VmPlatformState
Test-Case 'InstallState 1 は on・2 と 3 は off・ほかは unknown' @('on', 'off', 'off', 'unknown', 'unknown') {
    ConvertFrom-VmPlatformState -InstallState 1
    ConvertFrom-VmPlatformState -InstallState 2
    ConvertFrom-VmPlatformState -InstallState ([uint32]3)
    ConvertFrom-VmPlatformState -InstallState 4
    ConvertFrom-VmPlatformState -InstallState $null
}

# Format-ClaudeDesktopLabel
Test-Case '見出しは表示の幅 (全角を 2) でそろえる' @('[abc  ]', '[仮想マシン プラットフォーム ]', '[長すぎる見出し]') {
    "[$(Format-ClaudeDesktopLabel -Label 'abc' -Width 5)]"
    "[$(Format-ClaudeDesktopLabel -Label '仮想マシン プラットフォーム' -Width 28)]"
    "[$(Format-ClaudeDesktopLabel -Label '長すぎる見出し' -Width 4)]"
}

# Format-ClaudeDesktopState
Test-Case '状態の表: 見出し・揃っている行・winget の新しい版の ※' @(
    'Claude Desktop (winget の Anthropic.Claude の MSIX)'
    "  入っている版$(' ' * 16): 5.11492.5.0 ($Loc)"
    "  固定した版$(' ' * 18): 5.11492.5 → そのまま"
    "  winget の最新版$(' ' * 13): 6.28899.6"
    "  winget pin$(' ' * 18): あり"
    "  Cowork の常駐$(' ' * 15): CoworkVMService (Running)"
    '  仮想マシン プラットフォーム : on'
    '※ winget に固定した版より新しい 6.28899.6 がある。上げるなら Install-ClaudeDesktop.ps1 の -Version の既定値を変える (7 日の猶予を過ぎた版。入っている Claude Desktop は、自動更新で自分で上がる)'
) { (Format-ClaudeDesktopState -State (New-State) -Target $V).Text }
Test-Case '状態の表: pin が無い行だけ ⚠ (Warn)' @("⚠ winget pin$(' ' * 18): 無し → 足す") {
    @((Format-ClaudeDesktopState -State (New-State @{ Pinned = $false }) -Target $V) | Where-Object { $_.Warn }).Text
}
Test-Case '状態の表: 入っていなければ Cowork の常駐の行を出さない' 0 {
    $missing = New-State @{ Exists = $false; Plan = 'install'; Installed = $null; InstalledText = $null; Location = $null; Pinned = $false; Service = $null }
    @((Format-ClaudeDesktopState -State $missing -Target $V) | Where-Object { $_.Text.Contains('Cowork の常駐') -or $_.Text.Contains('CoworkVMService') }).Count
}
Test-Case '状態の表: 入っているのに Cowork の常駐が無ければ、無いと出して ※ で添える' @("  Cowork の常駐$(' ' * 15): 無い (CoworkVMService が無い)", $true) {
    $rows = @(Format-ClaudeDesktopState -State (New-State @{ Service = $null }) -Target $V)
    @($rows | Where-Object { $_.Text.Contains('Cowork の常駐') -and -not $_.Text.StartsWith('※') }).Text
    @($rows | Where-Object { $_.Text.StartsWith('※ MSIX は入っているが、Cowork の常駐 (CoworkVMService) が無い') }).Count -eq 1
}
Test-Case '状態の表: 仮想マシン プラットフォームが off なら、行と、on にする手の ※ (どちらも ⚠ にしない)' @('  仮想マシン プラットフォーム : off (Cowork は使えない)', $true, 0) {
    $rows = @(Format-ClaudeDesktopState -State (New-State @{ VmPlatform = 'off' }) -Target $V)
    @($rows | Where-Object { $_.Text.StartsWith('  仮想マシン') }).Text
    @($rows | Where-Object { $_.Text.StartsWith('※ 仮想マシン プラットフォーム (VirtualMachinePlatform) が off') -and $_.Text.Contains('Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All') }).Count -eq 1
    @($rows | Where-Object { $_.Warn }).Count
}
Test-Case '状態の表: 仮想マシン プラットフォームが読めなければ不明と出し、※ は出さない' @('  仮想マシン プラットフォーム : 不明 (Win32_OptionalFeature が読めない)', 0) {
    $rows = @(Format-ClaudeDesktopState -State (New-State @{ VmPlatform = 'unknown' }) -Target $V)
    @($rows | Where-Object { $_.Text.StartsWith('  仮想マシン') }).Text
    @($rows | Where-Object { $_.Text.StartsWith('※ 仮想マシン') }).Count
}
Test-Case '状態の表: 旧来の exe の Claude が残っていれば ⚠ の行と、外す手順の ※ を 2 行' @("⚠ 旧来の exe の Claude$(' ' * 8): 入っている (0.14.10。%LOCALAPPDATA%\AnthropicClaude) → ※ の手順で外す", 2, $true) {
    $rows = @(Format-ClaudeDesktopState -State (New-State @{ Legacy = $true; LegacyVersion = '0.14.10' }) -Target $V)
    @($rows | Where-Object { $_.Warn }).Text
    @($rows | Where-Object { $_.Text.StartsWith('※ ') -and ($_.Text.Contains('Update.exe') -or $_.Text.Contains('Claude.lnk')) }).Count
    @($rows | Where-Object { $_.Text.Contains('& "$env:LOCALAPPDATA\AnthropicClaude\Update.exe" --uninstall -s') }).Count -eq 1
}
Test-Case '状態の表: 旧来の exe の Claude の版が読めなければ、版を書かない' @("⚠ 旧来の exe の Claude$(' ' * 8): 入っている (%LOCALAPPDATA%\AnthropicClaude) → ※ の手順で外す") {
    @((Format-ClaudeDesktopState -State (New-State @{ Legacy = $true }) -Target $V) | Where-Object { $_.Warn }).Text
}
Test-Case '状態の表: 新しい版が入っていれば ※ を 2 行 (winget の新しい版・下げない)' 2 {
    $newer = New-State @{ Plan = 'newer'; Installed = [version]'6.28899.6.0'; InstalledText = '6.28899.6.0'; Versions = @('6.28899.6', '5.11492.5') }
    @((Format-ClaudeDesktopState -State $newer -Target $V) | Where-Object { $_.Text.StartsWith('※ winget に') -or $_.Text.StartsWith('※ 入っている版の方が新しい') }).Count
}
Test-Case '状態の表: 入れるのに固定した版が無ければ ⚠ の行 (runner が打たずに知らせる印)' $true {
    $missing = New-State @{ Exists = $false; Plan = 'install'; Installed = $null; InstalledText = $null; Location = $null; Pinned = $false; Service = $null; Versions = @('6.28899.6') }
    @((Format-ClaudeDesktopState -State $missing -Target $V) | Where-Object { $_.Warn -and $_.Text.Contains('winget show --versions に無い') }).Count -eq 1
}
Test-Case '状態の表: 版が読めなければ「比べられない」と ※' 2 {
    $odd = New-State @{ Plan = 'unknown'; Installed = $null; InstalledText = '?' }
    @((Format-ClaudeDesktopState -State $odd -Target $V) | Where-Object { $_.Text.Contains('比べられない') }).Count
}

# Get-ClaudeDesktopVerdict
$legacyOnly = '⚠️ 旧来の exe の Claude が残っている → ※ の手順で外す (Install-ClaudeDesktop は外さない) ⚠️'
Test-Case '締めの行: 揃っている (新しい版なら下げないと添える)' @('揃っている', '揃っている (入っている版の方が新しい。下げない)') {
    (Get-ClaudeDesktopVerdict -State (New-State) -Code 0 -Blocker $null -Target $V -PackageId $Id).Text
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'newer' }) -Code 0 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 入っていない (UAC の確認が 1 回出る)' '⚠️ Claude Desktop (MSIX) が入っていない → Install-ClaudeDesktop で入れる (UAC の確認が 1 回出る) ⚠️' {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'install'; Exists = $false }) -Code 3 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 固定した版が winget に無い' '⚠️ 固定した版 5.11492.5 が winget に無い → Install-ClaudeDesktop.ps1 の -Version を winget show --id Anthropic.Claude --versions にある版へ変える ⚠️' {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'install'; Exists = $false }) -Code 3 -Blocker 'not-listed' -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 版が読めない' '⚠️ 入っている版が読めない → Get-AppxPackage -Name Claude で入っている版を確かめる ⚠️' {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'unknown' }) -Code 1 -Blocker 'unknown' -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 残りが旧来の exe の Claude だけ (runner が読む文言)' $legacyOnly {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Legacy = $true }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: pin も無ければ pin のことを先に出す (旧来の exe の Claude の行にしない)' '⚠️ winget pin が無い → Install-ClaudeDesktop で足す (UAC の確認は出ない) ⚠️' {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Legacy = $true; Pinned = $false }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 古い' '⚠️ 固定した版より古い → Install-ClaudeDesktop で揃える (Claude を終えてから。UAC の確認が 1 回出る) ⚠️' {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'upgrade' }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 揃っていれば Warn でない・ほかは Warn' @($false, $true) {
    (Get-ClaudeDesktopVerdict -State (New-State) -Code 0 -Blocker $null -Target $V -PackageId $Id).Warn
    (Get-ClaudeDesktopVerdict -State (New-State @{ Legacy = $true }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Warn
}

# Select-WingetOutputLines
Test-Case 'winget の進み具合の表示 (回る棒・帯・空行) を除く' @('Found Claude [Anthropic.Claude] Version 5.11492.5', '正常にインストールされました') {
    Select-WingetOutputLines -Lines @('  -', '\', '', 'Found Claude [Anthropic.Claude] Version 5.11492.5', '  ██████▒▒▒▒  100 MB / 285 MB', '正常にインストールされました')
}

# ConvertTo-PsLiteral・ConvertTo-EncodedCommand
Test-Case "' と ‘ ’ ‚ ‛ は重ね、ほかはそのまま一重引用符で囲む" @("'C:\Users\a b\x'", "'it''s'", "'a‘‘b’’c‚‚d‛‛'") {
    ConvertTo-PsLiteral -Text 'C:\Users\a b\x'
    ConvertTo-PsLiteral -Text "it's"
    ConvertTo-PsLiteral -Text "a$([char]0x2018)b$([char]0x2019)c$([char]0x201A)d$([char]0x201B)"
}
Test-Case '-EncodedCommand の形は UTF-16LE の base64 (runner の encode_command と同じ字)' 'ZQB4AGkAdAAgADMA' { ConvertTo-EncodedCommand -Script 'exit 3' }

# Get-ElevatedWingetScript
$args1 = @(Get-WingetCommands -Plan 'install' -PackageId $Id -Version $V)[0]
$elevated = Get-ElevatedWingetScript -Winget "C:\Users\o'neil\AppData\Local\Microsoft\WindowsApps\winget.exe" -Arguments $args1 -LogPath 'C:\Users\a b\AppData\Local\Temp\dotfiles-claude-desktop-x.log'
Test-Case '昇格した側の本文は PowerShell として読める' 0 {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($elevated, [ref]$null, [ref]$errors)
    @($errors).Count
}
Test-Case '昇格した側の本文: winget を絶対パスで打ち、引数を 1 つずつ囲み、出力を UTF-8 のファイルに書いて winget の終了コードで終わる' @($true, $true, $true, $true) {
    $elevated.Contains("& 'C:\Users\o''neil\AppData\Local\Microsoft\WindowsApps\winget.exe' 'install' '--id' 'Anthropic.Claude' '--exact'")
    $elevated.Contains("'--installer-type' 'msix'")
    $elevated.Contains("Out-File -LiteralPath 'C:\Users\a b\AppData\Local\Temp\dotfiles-claude-desktop-x.log' -Encoding utf8")
    $elevated.EndsWith('exit $LASTEXITCODE')
}

# 昇格した側の本文を、偽の winget で実際に流す (昇格はしない。今の PowerShell を -EncodedCommand で起こす)。出力 (stdout と stderr) が
# ファイルに入り、終了コードが winget のものになること。winget を起こせなければ、わけがファイルに入って 2 で終わること (0 にしない)
$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-tests-{0}' -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $onWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    if ($onWindows) {
        $fake = Join-Path $work 'fake-winget.cmd'
        [IO.File]::WriteAllText($fake, "@echo off`r`necho line one %1`r`n>&2 echo line two`r`nexit /b 7`r`n")
    } else {
        $fake = Join-Path $work 'fake-winget'
        [IO.File]::WriteAllText($fake, "#!/bin/sh`necho `"line one `$1`"`necho 'line two' 1>&2`nexit 7`n")
        & chmod +x $fake
    }
    $self = (Get-Process -Id $PID).Path
    $log = Join-Path $work 'out.log'
    # 子は一時ディレクトリで起こす (WSL から流すと今の場所が \\wsl.localhost\… になり、cmd が UNC の警告を stderr に足す)
    $run = {
        param([string]$Winget, [string]$LogPath)
        $encoded = ConvertTo-EncodedCommand -Script (Get-ElevatedWingetScript -Winget $Winget -Arguments @('install', '--id', $Id) -LogPath $LogPath)
        Push-Location -LiteralPath $work
        try {
            & $self -NoProfile -NonInteractive -EncodedCommand $encoded | Out-Null
            $LASTEXITCODE
        } finally {
            Pop-Location
        }
    }
    # stdout と stderr の行の順は、2 本の pipe のどちらが先に届くかで変わるので、並べ替えて比べる
    Test-Case '偽の winget: 出力 (stderr も) がファイルに入り、終了コードは winget のもの (7)' @(7, 'line one install', 'line two') {
        & $run $fake $log
        Select-WingetOutputLines -Lines @(Get-Content -LiteralPath $log -Encoding UTF8) | Sort-Object
    }
    $log2 = Join-Path $work 'missing.log'
    Test-Case 'winget を起こせなければ、わけがファイルに入って 2 で終わる' @(2, $true) {
        & $run (Join-Path $work 'no-such-winget.exe') $log2
        @(Get-Content -LiteralPath $log2 -Encoding UTF8 | Where-Object { "$_".StartsWith('winget を起こせなかった: ') }).Count -eq 1
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件が失敗した"
    exit 1
}
Write-Host '全部通った'
# 明示して 0 で終える (-Command から呼ぶと、上の試験の子の終了コード ($LASTEXITCODE の 2) を拾ってしまう)
exit 0
