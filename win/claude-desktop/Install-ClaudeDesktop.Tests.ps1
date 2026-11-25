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

# 2026-11-24 の winget-pkgs の manifests/a/Anthropic/Claude の版の、新しいものから一部を、winget show --versions の形にしたもの
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
        Tray          = 'off'
        Startup       = 'off'
    }
    foreach ($k in $Values.Keys) { $base[$k] = $Values[$k] }
    [pscustomobject]$base
}

# 項目の並びを 1 つの字にする (空なら -。何も返さない関数の結果は、引数に渡すと $null 1 つになるので除く)
function Show-List {
    param($Items)
    $a = @($Items | Where-Object { $null -ne $_ })
    if ($a.Count -gt 0) { $a -join '+' } else { '-' }
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

# Get-ClaudeDesktopExitCode・Test-ClaudeDesktopManualOnly
Test-Case '入っていなければ 3' 3 { Get-ClaudeDesktopExitCode -State (New-State @{ Plan = 'install'; Pinned = $false }) }
Test-Case '入っていなくても、旧来の exe の Claude があれば 1 (入れられないので、runner が入れにいかない)' 1 { Get-ClaudeDesktopExitCode -State (New-State @{ Plan = 'install'; Pinned = $false; Legacy = $true }) }
Test-Case '同じで pin があれば 0' 0 { Get-ClaudeDesktopExitCode -State (New-State) }
Test-Case '新しくて pin があれば 0' 0 { Get-ClaudeDesktopExitCode -State (New-State @{ Plan = 'newer' }) }
Test-Case '同じでも pin が無ければ 1' 1 { Get-ClaudeDesktopExitCode -State (New-State @{ Pinned = $false }) }
Test-Case '古ければ 1' 1 { Get-ClaudeDesktopExitCode -State (New-State @{ Plan = 'upgrade' }) }
Test-Case '揃っていても旧来の exe の Claude が残っていれば 1' 1 { Get-ClaudeDesktopExitCode -State (New-State @{ Legacy = $true }) }
Test-Case 'システムトレイかスタートアップ時に実行が on なら、ほかが揃っていても 1 (不明・既定の off は数えない)' @(1, 1, 1, 1, 0, 0) {
    Get-ClaudeDesktopExitCode -State (New-State @{ Tray = 'on' })
    Get-ClaudeDesktopExitCode -State (New-State @{ Tray = 'unset' })
    Get-ClaudeDesktopExitCode -State (New-State @{ Tray = 'unopened'; Plan = 'newer' })
    Get-ClaudeDesktopExitCode -State (New-State @{ Startup = 'on' })
    Get-ClaudeDesktopExitCode -State (New-State @{ Tray = 'unknown'; Startup = 'unknown' })
    Get-ClaudeDesktopExitCode -State (New-State @{ Startup = 'unset' })
}
Test-Case '入っていなければ、設定によらず 3 (runner が入れにいく)' 3 {
    Get-ClaudeDesktopExitCode -State (New-State @{ Exists = $false; Plan = 'install'; Pinned = $false; Tray = 'on'; Startup = 'on' })
}
Test-Case '残りが人の直すもの (旧来の exe の Claude・on の設定) だけなら ManualOnly' @($true, $true, $true, $false, $false, $false) {
    Test-ClaudeDesktopManualOnly -State (New-State @{ Legacy = $true })
    Test-ClaudeDesktopManualOnly -State (New-State @{ Tray = 'on' })
    Test-ClaudeDesktopManualOnly -State (New-State @{ Startup = 'on'; Legacy = $true })
    Test-ClaudeDesktopManualOnly -State (New-State @{ Tray = 'on'; Pinned = $false })
    Test-ClaudeDesktopManualOnly -State (New-State @{ Legacy = $true; Pinned = $false })
    Test-ClaudeDesktopManualOnly -State (New-State)
}

# Get-ClaudeDesktopApplyBlocker
Test-Case '版が読めなければ unknown' 'unknown' { Get-ClaudeDesktopApplyBlocker -Plan 'unknown' -Versions @($V) -Target $V }
Test-Case '入れるのに固定した版が winget に無ければ not-listed' 'not-listed' { Get-ClaudeDesktopApplyBlocker -Plan 'install' -Versions @('6.28899.6') -Target $V }
Test-Case '版の一覧が読めなければ止めない' '' { Get-ClaudeDesktopApplyBlocker -Plan 'install' -Versions @() -Target $V }
Test-Case 'newer は止めない' '' { Get-ClaudeDesktopApplyBlocker -Plan 'newer' -Versions @('6.28899.6') -Target $V }
Test-Case '入れる・上げるのに旧来の exe の Claude があれば legacy (固定した版が無いときも legacy を先に)' @('legacy', 'legacy', 'legacy', '') {
    Get-ClaudeDesktopApplyBlocker -Plan 'install' -Versions @($V) -Target $V -Legacy $true
    Get-ClaudeDesktopApplyBlocker -Plan 'upgrade' -Versions @($V) -Target $V -Legacy $true
    Get-ClaudeDesktopApplyBlocker -Plan 'install' -Versions @('6.28899.6') -Target $V -Legacy $true
    Get-ClaudeDesktopApplyBlocker -Plan 'none' -Versions @($V) -Target $V -Legacy $true
}

# ConvertFrom-VmPlatformState
Test-Case 'InstallState 1 は on・2 と 3 は off・ほかは unknown' @('on', 'off', 'off', 'unknown', 'unknown') {
    ConvertFrom-VmPlatformState -InstallState 1
    ConvertFrom-VmPlatformState -InstallState 2
    ConvertFrom-VmPlatformState -InstallState ([uint32]3)
    ConvertFrom-VmPlatformState -InstallState 4
    ConvertFrom-VmPlatformState -InstallState $null
}

# Get-ClaudeDesktopConfigPath
Test-Case '設定のファイルは %LOCALAPPDATA%\Claude-Data\<PackageFamilyName の小文字>\claude_desktop_config.json' 'C:\Users\a\AppData\Local\Claude-Data\claude_pzs8sxrjxfjjc\claude_desktop_config.json' {
    Get-ClaudeDesktopConfigPath -LocalAppData 'C:\Users\a\AppData\Local' -FamilyName $Family
}
Test-Case '%LOCALAPPDATA% が空なら、設定のファイルの場所も空' '' { Get-ClaudeDesktopConfigPath -LocalAppData '' -FamilyName $Family }

# ConvertFrom-ClaudeTrayConfig
Test-Case 'システムトレイ: preferences.menuBarEnabled の true は on・false は off (ほかの鍵は見ない)' @('on', 'off') {
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":{"sidebarMode":"chat","menuBarEnabled":true}}'
    ConvertFrom-ClaudeTrayConfig -Text "{`r`n  `"coworkUserFilesPath`": `"C:\\x`",`r`n  `"preferences`": {`r`n    `"menuBarEnabled`": false`r`n  }`r`n}"
}
Test-Case 'システムトレイ: 値が無ければ unset (Claude の既定の on)・設定のファイルが無ければ unopened' @('unset', 'unset', 'unset', 'unset', 'unopened') {
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":{"sidebarMode":"chat"}}'
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":{}}'
    ConvertFrom-ClaudeTrayConfig -Text '{"mcpServers":{}}'
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":null}'
    ConvertFrom-ClaudeTrayConfig -Text $null
}
Test-Case 'システムトレイ: 鍵の大文字小文字は Claude と同じく区別する (Preferences・MenuBarEnabled は値が無いのと同じ)' @('unset', 'unset') {
    ConvertFrom-ClaudeTrayConfig -Text '{"Preferences":{"menuBarEnabled":false}}'
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":{"MenuBarEnabled":false}}'
}
Test-Case 'システムトレイ: 読めない JSON・オブジェクトでないもの・真偽値でない値は unknown' @('unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown', 'unknown') {
    ConvertFrom-ClaudeTrayConfig -Text ''
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":{"menuBarEnabled":fal'
    ConvertFrom-ClaudeTrayConfig -Text 'null'
    ConvertFrom-ClaudeTrayConfig -Text '[1,2]'
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":[1]}'
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":{"menuBarEnabled":"false"}}'
    ConvertFrom-ClaudeTrayConfig -Text '{"preferences":{"menuBarEnabled":null}}'
}

# ConvertFrom-ClaudeStartupTaskState
Test-Case 'スタートアップ: State の 2 (Enabled)・4 (EnabledByPolicy) は on、0・1・3 は off、無ければ unset、読めない鍵とほかの値は unknown' @('off', 'off', 'on', 'off', 'on', 'unset', 'unknown', 'unknown', 'unknown') {
    ConvertFrom-ClaudeStartupTaskState -State 0
    ConvertFrom-ClaudeStartupTaskState -State 1
    ConvertFrom-ClaudeStartupTaskState -State 2
    ConvertFrom-ClaudeStartupTaskState -State 3
    ConvertFrom-ClaudeStartupTaskState -State 4
    ConvertFrom-ClaudeStartupTaskState -State $null
    ConvertFrom-ClaudeStartupTaskState -State 'unreadable'
    ConvertFrom-ClaudeStartupTaskState -State 5
    ConvertFrom-ClaudeStartupTaskState -State 'x'
}

# Get-ClaudeDesktopOnSettings
Test-Case 'on の設定: システムトレイは on・unset・unopened、スタートアップ時に実行は on (off・不明・既定の off は数えない)' @('-', 'tray', 'tray', 'tray', '-', 'startup', '-', 'tray+startup') {
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State))
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State @{ Tray = 'on' }))
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State @{ Tray = 'unset' }))
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State @{ Tray = 'unopened' }))
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State @{ Tray = 'unknown'; Startup = 'unknown' }))
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State @{ Startup = 'on' }))
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State @{ Startup = 'unset' }))
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State @{ Tray = 'on'; Startup = 'on' }))
}
Test-Case 'on の設定: MSIX が入っていなければ数えない' '-' {
    Show-List (Get-ClaudeDesktopOnSettings -State (New-State @{ Exists = $false; Plan = 'install'; Tray = 'on'; Startup = 'on' }))
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
    "  システムトレイ$(' ' * 14): off"
    "  スタートアップ時に実行$(' ' * 6): off"
    '  仮想マシン プラットフォーム : on'
    '※ winget に固定した版より新しい 6.28899.6 がある。上げるなら Install-ClaudeDesktop.ps1 の -Version の既定値を変える (7 日の猶予を過ぎた版。入っている Claude Desktop は、自動更新で自分で上がる)'
) { (Format-ClaudeDesktopState -State (New-State) -Target $V).Text }
Test-Case '状態の表: システムトレイ・スタートアップ時に実行が on なら ⚠ の行 (Warn はその 2 行だけ) と、わけの ※ を 1 行ずつ' @(
    "⚠ システムトレイ$(' ' * 14): on → 設定 > デスクトップアプリ で off にする"
    "⚠ スタートアップ時に実行$(' ' * 6): on → 設定 > デスクトップアプリ で off にする"
    1
    1
) {
    $rows = @(Format-ClaudeDesktopState -State (New-State @{ Tray = 'on'; Startup = 'on' }) -Target $V)
    @($rows | Where-Object { $_.Warn }).Text
    @($rows | Where-Object { $_.Text.StartsWith('※ システムトレイが on だと') }).Count
    @($rows | Where-Object { $_.Text.StartsWith('※ スタートアップ時に実行が on だと') }).Count
}
Test-Case '状態の表: システムトレイの値が無ければ既定の on (⚠)。設定のファイルが無ければ、Claude を開いてから off にすると出す' @(
    "⚠ システムトレイ$(' ' * 14): on (既定のまま) → 設定 > デスクトップアプリ で off にする"
    "⚠ システムトレイ$(' ' * 14): on (既定。設定のファイルがまだ無い) → Claude を開いたら、設定 > デスクトップアプリ で off にする"
) {
    @((Format-ClaudeDesktopState -State (New-State @{ Tray = 'unset' }) -Target $V) | Where-Object { $_.Warn }).Text
    @((Format-ClaudeDesktopState -State (New-State @{ Tray = 'unopened' }) -Target $V) | Where-Object { $_.Warn }).Text
}
Test-Case '状態の表: 設定が読めなければ不明と出して ⚠ にせず、確かめ方の ※ を 1 行ずつ。スタートアップの鍵が無ければ既定の off' @(
    "  システムトレイ$(' ' * 14): 不明 (claude_desktop_config.json が読めない)"
    "  スタートアップ時に実行$(' ' * 6): 不明 (startup task の State が読めない)"
    0
    2
    "  スタートアップ時に実行$(' ' * 6): off (既定)"
) {
    $rows = @(Format-ClaudeDesktopState -State (New-State @{ Tray = 'unknown'; Startup = 'unknown' }) -Target $V)
    @($rows | Where-Object { $_.Text.StartsWith('  システムトレイ') -or $_.Text.StartsWith('  スタートアップ') }).Text
    @($rows | Where-Object { $_.Warn }).Count
    @($rows | Where-Object { $_.Text.StartsWith('※ ') -and $_.Text.Contains('Claude の設定 > デスクトップアプリ で確かめる') }).Count
    @((Format-ClaudeDesktopState -State (New-State @{ Startup = 'unset' }) -Target $V) | Where-Object { $_.Text.StartsWith('  スタートアップ') }).Text
}
Test-Case '状態の表: 入っていなければシステムトレイ・スタートアップ時に実行の行も ※ も出さない' 0 {
    $missing = New-State @{ Exists = $false; Plan = 'install'; Installed = $null; InstalledText = $null; Location = $null; Pinned = $false; Service = $null; Tray = $null; Startup = $null }
    @((Format-ClaudeDesktopState -State $missing -Target $V) | Where-Object { $_.Text.Contains('システムトレイ') -or $_.Text.Contains('スタートアップ') }).Count
}
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
Test-Case '状態の表: 入っていなくて旧来の exe の Claude があれば、入れないことも ※ で添える (古いときは上げないこと)' @(3, $true, $true) {
    $missing = New-State @{ Exists = $false; Plan = 'install'; Installed = $null; InstalledText = $null; Location = $null; Pinned = $false; Service = $null; Legacy = $true }
    $rows = @(Format-ClaudeDesktopState -State $missing -Target $V)
    @($rows | Where-Object { $_.Text.StartsWith('※ ') -and ($_.Text.Contains('Update.exe') -or $_.Text.Contains('Claude.lnk') -or $_.Text.Contains('MSIX を入れない')) }).Count
    @($rows | Where-Object { $_.Text -eq '※ 旧来の exe の Claude があるうちは、MSIX を入れない (外した後に dotfiles apply か Install-ClaudeDesktop で入れる)' }).Count -eq 1
    @((Format-ClaudeDesktopState -State (New-State @{ Plan = 'upgrade'; Legacy = $true }) -Target $V) | Where-Object { $_.Text -eq '※ 旧来の exe の Claude があるうちは、MSIX を上げない (外した後に Install-ClaudeDesktop で上げる)' }).Count -eq 1
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
$legacyBlocks = '⚠️ 旧来の exe の Claude が残っている → ※ の手順で外してから、Install-ClaudeDesktop で入れる・揃える (外すまで MSIX は入れない) ⚠️'
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
Test-Case '締めの行: 旧来の exe の Claude が残っていれば、pin より先にそのことを出す' $legacyOnly {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Legacy = $true; Pinned = $false }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 入っていない・古いのに旧来の exe の Claude があれば、外してから入れると出す (runner が読む文言を含む)' @($legacyBlocks, $legacyBlocks) {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'install'; Exists = $false; Legacy = $true }) -Code 1 -Blocker 'legacy' -Target $V -PackageId $Id).Text
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'upgrade'; Legacy = $true }) -Code 1 -Blocker 'legacy' -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 固定した版が winget に無くても、旧来の exe の Claude が残っていればそちらを先に出す' $legacyBlocks {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'install'; Exists = $false; Legacy = $true; Versions = @('6.28899.6') }) -Code 1 -Blocker 'legacy' -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 旧来の exe の行は、どちらも runner の印「旧来の exe の Claude が残っている」を含む' @($true, $true) {
    $legacyOnly.Contains('旧来の exe の Claude が残っている')
    $legacyBlocks.Contains('旧来の exe の Claude が残っている')
}
Test-Case '締めの行: 古い' '⚠️ 固定した版より古い → Install-ClaudeDesktop で揃える (Claude を終えてから。UAC の確認が 1 回出る) ⚠️' {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Plan = 'upgrade' }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 揃っていれば Warn でない・ほかは Warn' @($false, $true) {
    (Get-ClaudeDesktopVerdict -State (New-State) -Code 0 -Blocker $null -Target $V -PackageId $Id).Warn
    (Get-ClaudeDesktopVerdict -State (New-State @{ Legacy = $true }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Warn
}
$trayVerdict = '⚠️ Claude Desktop のシステムトレイが on → Claude の設定 > デスクトップアプリ の「システムトレイ」を off にする (Install-ClaudeDesktop は設定を書き換えない) ⚠️'
$trayUnopenedVerdict = '⚠️ Claude Desktop のシステムトレイが on (既定) → Claude を開いたら、設定 > デスクトップアプリ の「システムトレイ」を off にする (Install-ClaudeDesktop は設定を書き換えない) ⚠️'
$startupVerdict = '⚠️ Claude Desktop のスタートアップ時に実行が on → Claude の設定 > デスクトップアプリ の「スタートアップ時に実行」を off にする (Install-ClaudeDesktop は設定を書き換えない) ⚠️'
Test-Case '締めの行: MSIX の側が揃っていて設定だけが on なら、設定の行だけ (トレイ・スタートアップの順。どれも Warn)' @($trayVerdict, $startupVerdict, 0) {
    $rows = @(Get-ClaudeDesktopVerdict -State (New-State @{ Tray = 'on'; Startup = 'on' }) -Code 1 -Blocker $null -Target $V -PackageId $Id)
    $rows.Text
    @($rows | Where-Object { -not $_.Warn }).Count
}
Test-Case '締めの行: トレイの値が無ければ on と同じ行・設定のファイルが無ければ Claude を開いてから off にする行' @($trayVerdict, $trayUnopenedVerdict) {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Tray = 'unset' }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
    (Get-ClaudeDesktopVerdict -State (New-State @{ Tray = 'unopened' }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: pin が無い・旧来の exe と設定が重なれば、その行の後に設定の行' @('⚠️ winget pin が無い → Install-ClaudeDesktop で足す (UAC の確認は出ない) ⚠️', $trayVerdict, $legacyOnly, $startupVerdict) {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Pinned = $false; Tray = 'on' }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
    (Get-ClaudeDesktopVerdict -State (New-State @{ Legacy = $true; Startup = 'on' }) -Code 1 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 設定が不明なだけなら揃っている' '揃っている' {
    (Get-ClaudeDesktopVerdict -State (New-State @{ Tray = 'unknown'; Startup = 'unknown' }) -Code 0 -Blocker $null -Target $V -PackageId $Id).Text
}
Test-Case '締めの行: 設定の行は runner の印「Claude Desktop のシステムトレイが on」「Claude Desktop のスタートアップ時に実行が on」を含む' @($true, $true, $true) {
    $trayVerdict.Contains('Claude Desktop のシステムトレイが on')
    $trayUnopenedVerdict.Contains('Claude Desktop のシステムトレイが on')
    $startupVerdict.Contains('Claude Desktop のスタートアップ時に実行が on')
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

# Read-ClaudeDesktopConfigText (ファイルを読むだけなので、一時ファイルで今の PowerShell に読ませる。下の流れの試験は差し替える)
$configWork = Join-Path ([IO.Path]::GetTempPath()) ('claude-desktop-config-tests-{0}' -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $configWork | Out-Null
try {
    $withBom = Join-Path $configWork 'claude_desktop_config.json'
    [IO.File]::WriteAllText($withBom, '{"preferences":{"menuBarEnabled":false}}', (New-Object System.Text.UTF8Encoding $true))
    Test-Case '設定のファイル: 無ければ $null (unopened)・BOM 付きは BOM を除いた中身・場所が空なら空の字 (unknown)' @($true, '{"preferences":{"menuBarEnabled":false}}', 'off', $true) {
        $null -eq (Read-ClaudeDesktopConfigText -Path (Join-Path $configWork 'no-such.json'))
        Read-ClaudeDesktopConfigText -Path $withBom
        ConvertFrom-ClaudeTrayConfig -Text (Read-ClaudeDesktopConfigText -Path $withBom)
        $empty = Read-ClaudeDesktopConfigText -Path ''
        ($null -ne $empty) -and ($empty -eq '')
    }
} finally {
    Remove-Item -LiteralPath $configWork -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Invoke-InstallClaudeDesktop の流れ。Windows に触る関数を差し替えて流し、打った winget・昇格・締めの行・終了コードを見る
# (dot-source の後に同じ名前の関数を定義し直すと差し替わる。上の試験はもう流れたので、ここが最後)
# ---------------------------------------------------------------------------
$script:W = $null
function Reset-World {
    param([hashtable]$Values = @{})
    $script:W = [ordered]@{
        Msix        = $null
        Legacy      = $false
        Pinned      = $false
        Elevated    = $false
        Declined    = $false
        InstallExit = 0
        InstallAdds = $true
        PinAddExit  = 0
        WingetExe   = 'C:\Users\a\AppData\Local\Microsoft\WindowsApps\winget.exe'
        # 設定のファイルの中身 ($null は無い) と、startup task の State ($null は無い)
        TrayText    = '{"preferences":{"menuBarEnabled":false}}'
        StartupState = 0
        Calls       = New-Object System.Collections.ArrayList
    }
    foreach ($k in $Values.Keys) { $script:W[$k] = $Values[$k] }
}
# 設定のファイルと startup task の鍵は、この場所でだけ読める (場所を書き間違えると、ファイルも鍵も無いのと同じになる)
$LocalAppData = 'C:\Users\a\AppData\Local'
$ConfigPath = 'C:\Users\a\AppData\Local\Claude-Data\claude_pzs8sxrjxfjjc\claude_desktop_config.json'
$StartupKey = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\Claude_pzs8sxrjxfjjc\ClaudeStartup'
function Read-ClaudeDesktopConfigText {
    param([string]$Path)
    if ($Path -ceq $ConfigPath) { return $script:W.TrayText }
    $null
}
function Get-ClaudeStartupTaskState {
    param([string]$Key)
    if ($Key -ceq $StartupKey) { return $script:W.StartupState }
    $null
}
function Resolve-WingetExe { $script:W.WingetExe }
function Get-ClaudeAppxLines { if ($script:W.Msix) { "Claude`t$Family`t$($script:W.Msix)`t$Loc" } }
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = @($Arguments[0..1]) -join ' '
    [void]$script:W.Calls.Add("winget $verb")
    switch ($verb) {
        'pin list' {
            $lines = @('Name   Id               Version')
            if ($script:W.Pinned) { $lines += "Claude Anthropic.Claude $($script:W.Msix)" }
            return [pscustomobject]@{ ExitCode = 0; Lines = $lines }
        }
        'pin add' {
            if ($script:W.PinAddExit -eq 0) { $script:W.Pinned = $true }
            return [pscustomobject]@{ ExitCode = $script:W.PinAddExit; Lines = @() }
        }
        'pin remove' {
            $script:W.Pinned = $false
            return [pscustomobject]@{ ExitCode = 0; Lines = @() }
        }
    }
    if ($Arguments[0] -eq 'show') { return [pscustomobject]@{ ExitCode = 0; Lines = $show } }
    throw "思わぬ winget: $($Arguments -join ' ')"
}
function Invoke-ElevatedWinget {
    param([string]$Winget, [string[]]$Arguments)
    [void]$script:W.Calls.Add("elevated $($Arguments[0])$(if ($Arguments -contains '--include-pinned') { ' --include-pinned' })")
    if ($script:W.Declined) { return [pscustomobject]@{ ExitCode = 1223; Lines = @('UAC: The operation was canceled by the user.'); Declined = $true } }
    if (($script:W.InstallExit -eq 0) -and $script:W.InstallAdds) { $script:W.Msix = '5.11492.5.0' }
    [pscustomobject]@{ ExitCode = $script:W.InstallExit; Lines = @('winget の出力'); Declined = $false }
}
function Test-Elevated { $script:W.Elevated }
function Get-ClaudeLegacyState { [pscustomobject]@{ Exists = $script:W.Legacy; Dir = 'C:\Users\a\AppData\Local\AnthropicClaude'; Version = $null } }
function Get-CoworkServiceStatus { if ($script:W.Msix) { 'Running' } else { $null } }
function Get-VmPlatformInstallState { 1 }

# 流して、終了コード・出した行 (Write-Host)・打ったものを返す
function Invoke-Flow {
    param([hashtable]$World = @{}, [switch]$Check, [switch]$IfMissing)
    Reset-World $World
    $savedLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $LocalAppData
    try {
        $items = @(& { Invoke-InstallClaudeDesktop -Version $V -Check:$Check -IfMissing:$IfMissing } 6>&1)
    } finally {
        $env:LOCALAPPDATA = $savedLocalAppData
    }
    [pscustomobject]@{
        Code  = @($items | Where-Object { $_ -is [int] })[-1]
        Lines = @($items | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$($_.MessageData)" })
        Calls = @($script:W.Calls)
    }
}
function Test-Called {
    param($Run, [string]$Call)
    @($Run.Calls | Where-Object { $_ -eq $Call }).Count -gt 0
}

$notInstalled = '⚠️ Claude Desktop (MSIX) が入っていない → Install-ClaudeDesktop で入れる (UAC の確認が 1 回出る) ⚠️'
Test-Case '流れ: 入っていなければ昇格して入れ、pin を足して揃う (UAC の前置き・待つ間の文・サインインの案内)' @(0, 'elevated install', $true, $true, $true, $true) {
    $r = Invoke-Flow -IfMissing
    $r.Code
    @($r.Calls | Where-Object { $_.StartsWith('elevated') }) -join ','
    (Test-Called $r 'winget pin add') -and ([array]::IndexOf($r.Calls, 'winget pin add') -gt [array]::IndexOf($r.Calls, 'elevated install'))
    @($r.Lines | Where-Object { $_.StartsWith('Windows のデスクトップに UAC の確認が 1 回出る') }).Count -eq 1
    @($r.Lines | Where-Object { $_.StartsWith('winget の出力は、入れ終わってからまとめて出す') }).Count -eq 1
    @($r.Lines | Where-Object { $_.StartsWith('Claude のサインインは手でする') }).Count -eq 1 -and ($r.Lines[-1] -eq '揃った')
}
Test-Case '流れ: -Check は何も変えず、入っていなければ 3' @(3, $false, $false, $notInstalled) {
    $r = Invoke-Flow -Check
    $r.Code
    @($r.Calls | Where-Object { $_.StartsWith('elevated') }).Count -gt 0
    Test-Called $r 'winget pin add'
    $r.Lines[-1]
}
Test-Case '流れ: UAC を断ったら 1 で、pin を足さず、断ったと出す (runner が読む印)' @(1, $false, $true, $notInstalled) {
    $r = Invoke-Flow @{ Declined = $true } -IfMissing
    $r.Code
    Test-Called $r 'winget pin add'
    @($r.Lines | Where-Object { $_.StartsWith('UAC の確認を断った') }).Count -eq 1
    $r.Lines[-1]
}
Test-Case '流れ: 旧来の exe があれば、入っていなくても -Check は 1 で、締めの行は旧来の exe のこと' @(1, $legacyBlocks) {
    $r = Invoke-Flow @{ Legacy = $true } -Check
    $r.Code
    $r.Lines[-1]
}
Test-Case '流れ: 旧来の exe があれば、-IfMissing も引数なしも入れずに 1 (UAC を出さない)' @(1, 0, 1, 0) {
    foreach ($ifMissing in @($true, $false)) {
        $r = Invoke-Flow @{ Legacy = $true } -IfMissing:$ifMissing
        $r.Code
        @($r.Calls | Where-Object { $_.StartsWith('elevated') }).Count
    }
}
Test-Case '流れ: 古くて旧来の exe もあれば、引数なしでも pin を外さず、上げずに 1' @(1, $false, 0, $legacyBlocks) {
    $r = Invoke-Flow @{ Legacy = $true; Msix = '5.11492.2.0'; Pinned = $true }
    $r.Code
    Test-Called $r 'winget pin remove'
    @($r.Calls | Where-Object { $_.StartsWith('elevated') }).Count
    $r.Lines[-1]
}
Test-Case '流れ: 旧来の exe があり、固定した版が winget に無くても、-Check は 1 で締めの行は旧来の exe のこと' @(1, $legacyBlocks) {
    $saved = $show
    try {
        $show = @('Found Claude [Anthropic.Claude]', 'Version', '-------', '6.28899.6')
        $r = Invoke-Flow @{ Legacy = $true } -Check
    } finally {
        $show = $saved
    }
    $r.Code
    $r.Lines[-1]
}
Test-Case '流れ: MSIX が揃っていて旧来の exe だけが残っていれば、何も打たずに 1' @(1, 0, $false, $legacyOnly) {
    $r = Invoke-Flow @{ Legacy = $true; Msix = '5.11492.5.0'; Pinned = $true }
    $r.Code
    @($r.Calls | Where-Object { $_.StartsWith('elevated') }).Count
    Test-Called $r 'winget pin add'
    $r.Lines[-1]
}
Test-Case '流れ: MSIX は入っていて pin が無く、旧来の exe もあれば、pin だけ足して 1 (締めの行は旧来の exe のこと)' @(1, $true, $legacyOnly) {
    $r = Invoke-Flow @{ Legacy = $true; Msix = '5.11492.5.0' }
    $r.Code
    Test-Called $r 'winget pin add'
    $r.Lines[-1]
}
Test-Case '流れ: 古ければ (引数なし) pin を外し、--include-pinned で昇格して上げ、pin を足し直して揃う' @(0, $true, $true) {
    $r = Invoke-Flow @{ Msix = '5.11492.2.0'; Pinned = $true }
    $r.Code
    ([array]::IndexOf($r.Calls, 'winget pin remove') -lt [array]::IndexOf($r.Calls, 'elevated upgrade --include-pinned')) -and ([array]::IndexOf($r.Calls, 'elevated upgrade --include-pinned') -lt [array]::IndexOf($r.Calls, 'winget pin add'))
    @($r.Lines | Where-Object { $_.StartsWith('上げる前に Claude を終える') }).Count -eq 1
}
Test-Case '流れ: -IfMissing は入っていれば上げない (古くても 1 で、何も打たない)' @(1, 0) {
    $r = Invoke-Flow @{ Msix = '5.11492.2.0'; Pinned = $true } -IfMissing
    $r.Code
    @($r.Calls | Where-Object { $_.StartsWith('elevated') -or $_.StartsWith('winget pin add') -or $_.StartsWith('winget pin remove') }).Count
}
Test-Case '流れ: 入っている版の方が新しければ 0 で、下げない' @(0, '揃っている (入っている版の方が新しい。下げない)') {
    $r = Invoke-Flow @{ Msix = '6.28899.6.0'; Pinned = $true } -Check
    $r.Code
    $r.Lines[-1]
}
Test-Case '流れ: winget は終わったのにこのユーザーに出なければ、別のユーザーに入ったかもしれないと出して 1' @(1, $true) {
    $r = Invoke-Flow @{ InstallAdds = $false } -IfMissing
    $r.Code
    @($r.Lines | Where-Object { $_.StartsWith('※ winget は終わったが、このユーザーの Get-AppxPackage に Claude が出ない') }).Count -eq 1
}
Test-Case '流れ: winget が落ちたら 1 で、終了コードを出す' @(1, $true, $false) {
    $r = Invoke-Flow @{ InstallExit = -1978335189 } -IfMissing
    $r.Code
    @($r.Lines | Where-Object { $_.StartsWith('winget が失敗した (終了コード 0x8A15002B)') }).Count -eq 1
    Test-Called $r 'winget pin add'
}
Test-Case '流れ: 昇格した会話なら UAC を出さないと出す' @(0, $true) {
    $r = Invoke-Flow @{ Elevated = $true } -IfMissing
    $r.Code
    @($r.Lines | Where-Object { $_ -eq '管理者の権限で動いているので、UAC の確認を出さずに winget を打つ' }).Count -eq 1
}
Test-Case '流れ: winget (の exe) が見つからなければ 2' @(2, 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる') {
    $r = Invoke-Flow @{ WingetExe = $null } -Check
    $r.Code
    $r.Lines[-1]
}
Test-Case '流れ: MSIX が揃っていてシステムトレイが on なら、-Check も引数なしも何も打たずに 1 (締めの行はトレイのこと。引数なしも読み直さない)' @(1, 0, $trayVerdict, 1, 0, 1, $trayVerdict) {
    $tray = @{ Msix = '5.11492.5.0'; Pinned = $true; TrayText = '{"preferences":{"menuBarEnabled":true}}' }
    $r = Invoke-Flow $tray -Check
    $r.Code
    @($r.Calls | Where-Object { $_.StartsWith('elevated') -or ($_ -eq 'winget pin add') }).Count
    $r.Lines[-1]
    $r = Invoke-Flow $tray
    $r.Code
    @($r.Calls | Where-Object { $_.StartsWith('elevated') -or ($_ -eq 'winget pin add') }).Count
    @($r.Calls | Where-Object { $_ -eq 'winget show --id' }).Count
    $r.Lines[-1]
}
Test-Case '流れ: スタートアップ時に実行が on (startup task ClaudeStartup の State 2) なら、-Check は 1' @(1, $startupVerdict) {
    $r = Invoke-Flow @{ Msix = '5.11492.5.0'; Pinned = $true; StartupState = 2 } -Check
    $r.Code
    $r.Lines[-1]
}
Test-Case '流れ: 入れた直後で設定のファイルがまだ無ければ、入れたうえで 1 (版と pin は揃ったと先に書き、締めの行は、Claude を開いてからトレイを off にすること)' @(1, $true, $true, $false, '版と pin は揃った。残りは人が直すもの (下の ⚠️ の行)', $trayUnopenedVerdict) {
    $r = Invoke-Flow @{ TrayText = $null } -IfMissing
    $r.Code
    Test-Called $r 'elevated install'
    @($r.Lines | Where-Object { $_.StartsWith('Claude のサインインは手でする') }).Count -eq 1
    @($r.Lines | Where-Object { $_ -eq '揃った' }).Count -gt 0
    $r.Lines[-2]
    $r.Lines[-1]
}
Test-Case '流れ: pin が無くてシステムトレイも on なら、引数なしは pin を足し、読み直した締めの行はトレイのこと (1)' @(1, $true, $trayVerdict) {
    $r = Invoke-Flow @{ Msix = '5.11492.5.0'; TrayText = '{"preferences":{}}' }
    $r.Code
    Test-Called $r 'winget pin add'
    $r.Lines[-1]
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件が失敗した"
    exit 1
}
Write-Host '全部通った'
# 明示して 0 で終える (-Command から呼ぶと、上の試験の子の終了コード ($LASTEXITCODE の 2) を拾ってしまう)
exit 0
