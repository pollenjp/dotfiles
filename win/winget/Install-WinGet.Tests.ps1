# win/winget/Install-WinGet.ps1 のうち、副作用の無い関数と、Windows に触る関数を偽物に差し替えた流れのテスト。Pester は使わない。
# GitHub から落とす・Add-AppxPackage を打つ本物の部分は、実機で -Check と本番 (-Force) を打って確かめる (win/README.md の「winget」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/winget/Install-WinGet.Tests.ps1
#
# ## 確かめること
#
#   - winget --version の出力 (v1.30.310・v1.31.10-preview) から版を拾い、固定した版の字を [version] にする
#   - 入っていなければ install、固定した版より古い・版が読めなければ upgrade、固定した版以上なら none (下げない)
#   - 固定できる版の表 (Get-WinGetRelease) に既定の版があり、sha256 は 64 桁の小文字の 16 進
#   - CPU (AMD64 → x64・ARM64 → arm64・ほかは入れられない)、依存の zip の中のこの CPU の appx だけを拾い、入っている framework の版が
#     足りないものだけを渡す
#   - 止めるわけ (CPU・表に無い版・curl.exe が無い) と、終了コード (0・1・3。入れられなければ入っていなくても 1)・状態の表・締めの行 (runner が
#     読む文言)
#   - Windows PowerShell に打たせる Add-AppxPackage・Get-AppxPackage の本文 (引用符・依存の有る無し・-ForceApplicationShutdown)
#   - 流れ: -Check と -IfMissing は入れ替えない。揃える流れは 2 つを落として sha256 を確かめてから依存と一緒に入れる。sha256 が違う・落とせない・
#     Add-AppxPackage が落ちたら止まる。固定した版より新しければ何もしない (-Force でも下げない)。-Force は同じ版なら入れ直す
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-WinGet.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-WinGet.ps1')

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

$V = '1.30.310'
$TargetV = [version]'1.30.310'

# Get-WinGetClientVersion: winget --version の出力から版を拾う
Test-Case 'v1.30.310 から版を拾う' '1.30.310' { Get-WinGetClientVersion -Lines @('v1.30.310') }
Test-Case 'preview の版からも拾う' '1.31.10' { Get-WinGetClientVersion -Lines @('v1.31.10-preview') }
Test-Case '行末の CR と前後の空白を落とす' '1.29.380' { Get-WinGetClientVersion -Lines @("  v1.29.380`r") }
Test-Case '版の行が無ければ空' '' { Get-WinGetClientVersion -Lines @('error') }

# ConvertTo-WinGetVersion: 固定した版の字
Test-Case '固定した版の字を [version] にする' '1.30.310' { ConvertTo-WinGetVersion -Text $V }
Test-Case '版の形でなければ空' '' { ConvertTo-WinGetVersion -Text 'v1.30' }

# Get-WinGetRelease: 固定できる版の表
Test-Case '固定した版は表にある' $true { $null -ne (Get-WinGetRelease -Version $V) }
Test-Case 'param の既定値は上の固定した版と同じ (表にある版)' $V {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Install-WinGet.ps1'), [ref]$null, [ref]$null)
    ($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Version' }).DefaultValue.Value
}
Test-Case 'sha256 は 64 桁の小文字の 16 進' 'True True' { $r = Get-WinGetRelease -Version $V; "$($r.Bundle -cmatch '^[0-9a-f]{64}$') $($r.Dependencies -cmatch '^[0-9a-f]{64}$')" }
Test-Case '表に無い版は空' $true { $null -eq (Get-WinGetRelease -Version '1.30.999') }

# Get-WinGetPlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-WinGetPlan -Exists $false -Installed $null -Target $TargetV }
Test-Case '固定した版より古ければ upgrade' 'upgrade' { Get-WinGetPlan -Exists $true -Installed ([version]'1.29.380') -Target $TargetV }
Test-Case '1.11 (入れたての Windows 11 の古い版) も upgrade' 'upgrade' { Get-WinGetPlan -Exists $true -Installed ([version]'1.11.510') -Target $TargetV }
Test-Case '版が読めなければ upgrade' 'upgrade' { Get-WinGetPlan -Exists $true -Installed $null -Target $TargetV }
Test-Case '同じ版なら none' 'none' { Get-WinGetPlan -Exists $true -Installed $TargetV -Target $TargetV }
Test-Case '新しい版 (Store が上げた) なら none (下げない)' 'none' { Get-WinGetPlan -Exists $true -Installed ([version]'1.31.10') -Target $TargetV }
Test-Case '同じ minor の新しい build も none' 'none' { Get-WinGetPlan -Exists $true -Installed ([version]'1.30.400') -Target $TargetV }

# Get-WinGetArch: OS の CPU
Test-Case 'AMD64 は x64' 'x64' { Get-WinGetArch -Architecture 'AMD64' }
Test-Case 'ARM64 は arm64 (大文字小文字を問わない)' 'arm64' { Get-WinGetArch -Architecture 'arm64' }
Test-Case 'x86 は入れられない' '' { Get-WinGetArch -Architecture 'x86' }
Test-Case '空は入れられない' '' { Get-WinGetArch -Architecture '' }

# Get-WinGetDependencyEntries: 依存の zip (v1.30.310 の DesktopAppInstaller_Dependencies.zip の中の名前) からこの CPU の appx を拾う
$zipNames = @(
    'arm64/Microsoft.VCLibs.140.00_14.0.33519.0_arm64.appx'
    'arm64/Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_arm64.appx'
    'arm64/Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_arm64.appx'
    'x64/Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx'
    'x64/Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx'
    'x64/Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64.appx'
    'x86/Microsoft.VCLibs.140.00_14.0.33519.0_x86.appx'
    'x86/Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x86.appx'
    'x86/Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x86.appx'
    'x64/'
    'README.txt'
)
Test-Case 'x64 の appx を 3 つ拾う (名前と版)' 'Microsoft.VCLibs.140.00 14.0.33519.0 Microsoft.VCLibs.140.00.UWPDesktop 14.0.33728.0 Microsoft.WindowsAppRuntime.1.8 8000.616.304.0' {
    @(Get-WinGetDependencyEntries -Names $zipNames -Arch 'x64') | ForEach-Object { "$($_.Name) $($_.Version)" }
}
Test-Case 'Entry は zip の中の名前のまま' 'x64/Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx' { @(Get-WinGetDependencyEntries -Names $zipNames -Arch 'x64')[0].Entry }
Test-Case 'arm64 は arm64 のものだけ' 3 { @(Get-WinGetDependencyEntries -Names $zipNames -Arch 'arm64' | Where-Object { $_.Entry -like 'arm64/*' }).Count }
Test-Case '\ 区切りの名前も読む' 1 { @(Get-WinGetDependencyEntries -Names @('x64\Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx') -Arch 'x64').Count }
Test-Case 'CPU の合わない appx は拾わない' 0 { @(Get-WinGetDependencyEntries -Names @('x64/Microsoft.VCLibs.140.00_14.0.33519.0_x86.appx') -Arch 'x64').Count }

# ConvertFrom-WinGetAppxLines と Select-WinGetNeededDependencies: 足りない依存だけを渡す
$entries = @(Get-WinGetDependencyEntries -Names $zipNames -Arch 'x64')
$appx = @(ConvertFrom-WinGetAppxLines -Lines @(
        "Microsoft.VCLibs.140.00`t14.0.33519.0`tX64"
        "Microsoft.VCLibs.140.00`t14.0.33519.0`tX86"
        "Microsoft.VCLibs.140.00.UWPDesktop`t14.0.30704.0`tX64"
        "Microsoft.WindowsAppRuntime.1.8`t8000.700.1.0`tX64"
        'broken line'
        "Microsoft.Other`tnot-a-version`tX64"
    ))
Test-Case 'Get-AppxPackage の行を読み、読めない行は飛ばす' 4 { $appx.Count }
Test-Case '同じ版・新しい版が入っていれば渡さず、古い版しか無いものだけを渡す' 'Microsoft.VCLibs.140.00.UWPDesktop' { @(Select-WinGetNeededDependencies -Dependencies $entries -Installed $appx) | ForEach-Object { $_.Name } }
Test-Case 'CPU の違うものは数えない' 'Microsoft.VCLibs.140.00 Microsoft.VCLibs.140.00.UWPDesktop Microsoft.WindowsAppRuntime.1.8' {
    $x86only = @(ConvertFrom-WinGetAppxLines -Lines @("Microsoft.VCLibs.140.00`t14.0.33519.0`tX86"))
    @(Select-WinGetNeededDependencies -Dependencies $entries -Installed $x86only) | ForEach-Object { $_.Name }
}
Test-Case '何も入っていなければ全部を渡す' 3 { @(Select-WinGetNeededDependencies -Dependencies $entries -Installed @()).Count }

# Get-WinGetDownloadUrl・Test-WinGetHash
Test-Case 'Release の物の URL' 'https://github.com/microsoft/winget-cli/releases/download/v1.30.310/DesktopAppInstaller_Dependencies.zip' { Get-WinGetDownloadUrl -Version $V -Asset 'DesktopAppInstaller_Dependencies.zip' }
Test-Case 'sha256 は大文字小文字を問わず比べる' $true { Test-WinGetHash -Actual 'ABCDEF' -Expected 'abcdef' }
Test-Case 'sha256 が違えば false' $false { Test-WinGetHash -Actual 'abcdef' -Expected 'abcde0' }
Test-Case '落とした物の sha256 が読めなければ false' $false { Test-WinGetHash -Actual $null -Expected 'abcdef' }

# Get-WinGetBlocker
$rel = Get-WinGetRelease -Version $V
Test-Case '止めるわけが無ければ空' '' { Get-WinGetBlocker -Arch 'x64' -Release $rel -HasCurl $true }
Test-Case 'CPU が合わなければ arch' 'arch' { Get-WinGetBlocker -Arch $null -Release $rel -HasCurl $true }
Test-Case '表に無い版なら not-pinned' 'not-pinned' { Get-WinGetBlocker -Arch 'x64' -Release $null -HasCurl $true }
Test-Case 'curl.exe が無ければ no-curl' 'no-curl' { Get-WinGetBlocker -Arch 'x64' -Release $rel -HasCurl $false }

# 状態 (Get-WinGetState の形)
function New-State {
    param([hashtable]$Over = @{})
    $s = @{
        Exists        = $true
        Exe           = 'C:\Users\u\AppData\Local\Microsoft\WindowsApps\winget.exe'
        Installed     = $TargetV
        TargetVersion = $TargetV
        Architecture  = 'AMD64'
        Arch          = 'x64'
        Plan          = 'none'
        Blocker       = $null
    }
    foreach ($k in $Over.Keys) { $s[$k] = $Over[$k] }
    [pscustomobject]$s
}
$old = @{ Installed = [version]'1.29.380'; Plan = 'upgrade' }
$missing = @{ Exists = $false; Exe = $null; Installed = $null; Plan = 'install' }

# Get-WinGetExitCode
Test-Case '固定した版以上なら 0' 0 { Get-WinGetExitCode -State (New-State) }
Test-Case '古ければ 1' 1 { Get-WinGetExitCode -State (New-State $old) }
Test-Case '入っていなければ 3' 3 { Get-WinGetExitCode -State (New-State $missing) }
Test-Case '入っていなくても、入れられなければ 1 (runner が -IfMissing で入れにいかない)' 1 { Get-WinGetExitCode -State (New-State ($missing + @{ Blocker = 'arch'; Arch = $null; Architecture = 'x86' })) }

# Format-WinGetState: 状態の表
function Get-Rows { param($State) @(Format-WinGetState -State $State -Target $V) }
Test-Case '見出しは runner が見る字で始まる' $true { (Get-Rows (New-State))[0].Text.StartsWith('winget (アプリ インストーラー') }
Test-Case '揃っていれば ⚠ は無い' 0 { @(Get-Rows (New-State) | Where-Object { $_.Warn }).Count }
Test-Case '入っている版の行に exe を添える' '  入っている版 : 1.30.310 (C:\Users\u\AppData\Local\Microsoft\WindowsApps\winget.exe)' { (Get-Rows (New-State))[1].Text }
Test-Case '古ければ固定した版の行を ⚠ で「上げる」' '⚠ 固定した版   : 1.30.310 以上 → 上げる' { (Get-Rows (New-State $old))[2].Text }
Test-Case '入っていなければ「入れる」' '  入っている版 : 入っていない ⚠ 固定した版   : 1.30.310 以上 → 入れる' { $r = Get-Rows (New-State $missing); "$($r[1].Text) $($r[2].Text)" }
Test-Case '新しい版なら下げないと出す' '  固定した版   : 1.30.310 以上 → そのまま (固定した版より新しい。下げない)' { (Get-Rows (New-State @{ Installed = [version]'1.31.10' }))[2].Text }
Test-Case '版が読めなければ不明と出す' '  入っている版 : 不明 (winget --version が読めない。C:\Users\u\AppData\Local\Microsoft\WindowsApps\winget.exe)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'upgrade' }))[1].Text }
Test-Case '入れられなければ、わけを ⚠ で、直し方を ※ で添える' '⚠ winget を入れられない (この PC の CPU (x86) 向けの winget は dotfiles では入れない (x64・arm64 だけ))|※ この PC では、Microsoft Store の「アプリ インストーラー」を更新して winget を上げる (win/README.md の「winget」)' {
    $r = Get-Rows (New-State ($old + @{ Blocker = 'arch'; Arch = $null; Architecture = 'x86' }))
    "$($r[-2].Text)|$($r[-1].Text)"
}
Test-Case 'CPU の行も ⚠ にする' '⚠ CPU          : x86 (入れられない)' { (Get-Rows (New-State ($old + @{ Blocker = 'arch'; Arch = $null; Architecture = 'x86' })))[3].Text }
Test-Case '揃っていれば、止めるわけがあっても出さない' 4 { (Get-Rows (New-State @{ Blocker = 'no-curl' })).Count }

# Format-WinGetVerdict: 締めの行。Windows の runner (win/runner/src/steps/ps1.rs) がこの文言で、入れるか・揃えるか・知らせるだけかを決める
function Get-Verdict { param($State) (@(Format-WinGetVerdict -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '揃っていれば締めの行は出さない' '' { Get-Verdict (New-State) }
Test-Case '入っていなければ、Install-WinGet で入れると出す' '⚠️ winget が入っていない → Install-WinGet で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '古ければ、Install-WinGet で揃えると出す' '⚠️ winget が固定した版より古い → Install-WinGet で揃える ⚠️' { Get-Verdict (New-State $old) }
Test-Case '入れられなければ、※ の手順で直すと出す (入れる・揃えるとは言わない)' '⚠️ winget を入れられない (上の ※ の行) → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($old + @{ Blocker = 'no-curl' })) }

# Windows PowerShell に打たせる本文
Test-Case 'Add-AppxPackage は依存と -ForceApplicationShutdown を付ける' $true {
    $s = Get-WinGetAddAppxScript -Bundle 'C:\T\b.msixbundle' -Dependencies @('C:\T\a.appx', 'C:\T\c.appx')
    $s.Contains("Add-AppxPackage -Path 'C:\T\b.msixbundle' -DependencyPath @('C:\T\a.appx', 'C:\T\c.appx') -ForceApplicationShutdown")
}
Test-Case '依存が無ければ -DependencyPath を付けない' $true {
    $s = Get-WinGetAddAppxScript -Bundle 'C:\T\b.msixbundle' -Dependencies @()
    $s.Contains("Add-AppxPackage -Path 'C:\T\b.msixbundle' -ForceApplicationShutdown")
}
Test-Case "パスの ' は二重にする" "'C:\Users\o''brien\b.msixbundle'" { ConvertTo-WinGetQuoted -Text "C:\Users\o'brien\b.msixbundle" }
Test-Case '本文は PowerShell として読める (Add-AppxPackage・Get-AppxPackage)' '0 0' {
    $e1 = $null; $e2 = $null
    $null = [Management.Automation.Language.Parser]::ParseInput((Get-WinGetAddAppxScript -Bundle "C:\o'b\b.msixbundle" -Dependencies @('C:\a.appx')), [ref]$null, [ref]$e1)
    $null = [Management.Automation.Language.Parser]::ParseInput((Get-WinGetAppxQueryScript -Names @('Microsoft.VCLibs.140.00', 'Microsoft.WindowsAppRuntime.1.8')), [ref]$null, [ref]$e2)
    "$(@($e1).Count) $(@($e2).Count)"
}
Test-Case 'Get-AppxPackage は名前ごとに打ち、名前・版・CPU をタブで並べる' $true {
    $s = Get-WinGetAppxQueryScript -Names @('Microsoft.VCLibs.140.00')
    $s.Contains("foreach (`$n in @('Microsoft.VCLibs.140.00'))") -and $s.Contains("Get-AppxPackage -Name `$n")
}

# Get-WinGetAppxFailureHint
Test-Case 'サイドロードを止めた PC の HRESULT には方針の ※' $true { (Get-WinGetAppxFailureHint -Lines @('x', 'HRESULT 0x80073CFF')) -like '*方針で止めている*' }
Test-Case '使用中なら窓を閉じる ※' $true { (Get-WinGetAppxFailureHint -Lines @('HRESULT 0x80073D02')) -like '*閉じてから打ち直す*' }
Test-Case 'ほかは何も添えない' '' { Get-WinGetAppxFailureHint -Lines @('HRESULT 0x80070005') }

# 本体の入口: Linux の pwsh には Windows PowerShell が無いが、-Check は winget を読むだけなので、思わぬ例外でなく 3 か 1 で終わる
Test-Case '-Check は Linux でも例外にならず、入っていない (3) か入れられない (1) で終わる' $true {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-WinGet.ps1') -Check 2>&1
    $LASTEXITCODE -in @(1, 3)
}

# ---------------------------------------------------------------------------
# Invoke-InstallWinGet の流れ。Windows に触る関数を偽物に差し替えて、落とす・確かめる・入れる順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
function Find-WinGetExe { if ($null -ne $script:Installed) { 'C:\W\winget.exe' } else { $null } }
function Get-WinGetInstalledVersion { param($Exe) $script:Installed }
function Get-WinGetOsArchitecture { $script:OsArch }
function Test-WinGetCurl { $script:HasCurl }
# 作業のディレクトリは本物の一時ディレクトリ (流れの最後に消す)
function New-WinGetWorkDir { $d = Join-Path ([IO.Path]::GetTempPath()) "install-winget-tests-$PID"; New-Item -ItemType Directory -Force -Path $d | Out-Null; $d }
function Invoke-WinGetDownload {
    param($Url, $OutFile)
    $name = Split-Path -Leaf $Url
    $script:Calls.Add("download $name")
    if ($script:Fail.ContainsKey('download')) { throw 'curl.exe の終了コード 28' }
}
function Get-WinGetFileHash {
    param($Path)
    $r = Get-WinGetRelease -Version $V
    if ($script:Fail.ContainsKey('hash')) { return ('0' * 64) }
    if ($Path -like '*.msixbundle') { $r.Bundle } else { $r.Dependencies }
}
function Get-WinGetZipEntryNames { param($ZipPath) $zipNames }
function Get-WinGetInstalledFrameworks { param($Names) $script:Calls.Add('appx list'); @($script:Frameworks) }
function Expand-WinGetZipEntry { param($ZipPath, $Entry, $Destination) "C:\T\$(Split-Path -Leaf $Entry)" }
function Invoke-WinGetAddAppx {
    param($Bundle, $Dependencies)
    $script:Calls.Add("add $(@($Dependencies).Count)")
    if ($script:Fail.ContainsKey('add')) {
        return [pscustomobject]@{ ExitCode = 1; Lines = @('Deployment failed', 'HRESULT 0x80073CFF') }
    }
    $script:Installed = $script:AfterInstall
    [pscustomobject]@{ ExitCode = 0; Lines = @() }
}

# 1 回ぶんの流れを走らせ、した操作・画面の行・終了コードを返す
function Invoke-Flow {
    param($Installed, [switch]$Check, [switch]$IfMissing, [switch]$Force, [hashtable]$Fail = @{}, [string]$OsArch = 'AMD64', [bool]$HasCurl = $true,
        $After = $TargetV, [object[]]$Frameworks = @(), [string]$Version = $V)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:Installed = $Installed
    $script:AfterInstall = $After
    $script:Fail = $Fail
    $script:OsArch = $OsArch
    $script:HasCurl = $HasCurl
    $script:Frameworks = $Frameworks
    $out = @(Invoke-InstallWinGet -Version $Version -Check:$Check -IfMissing:$IfMissing -Force:$Force 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ', ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$fullFlow = 'download Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle, download DesktopAppInstaller_Dependencies.zip, appx list, add 3'
$older = [version]'1.29.380'
Test-Case '-Check は何もしない (古くても 1)' '1 []' { $r = Invoke-Flow -Installed $older -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は入っていなければ 3' '3 []' { $r = Invoke-Flow -Installed $null -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていれば上げない' '1 []' { $r = Invoke-Flow -Installed $older -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ入れる' "0 [$fullFlow]" { $r = Invoke-Flow -Installed $null -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '古ければ、2 つを落として確かめ、依存と一緒に入れる' "0 [$fullFlow] True" { $r = Invoke-Flow -Installed $older; "$($r.Code) [$($r.Calls)] $($r.Text -like '*揃った*')" }
Test-Case 'sha256 を確かめたと出す' $true { $r = Invoke-Flow -Installed $older; $r.Text -like '*sha256 を確かめた: DesktopAppInstaller_Dependencies.zip*' }
Test-Case '足りている依存は渡さない' 'add 1' {
    $fw = @(ConvertFrom-WinGetAppxLines -Lines @("Microsoft.VCLibs.140.00`t14.0.33519.0`tX64", "Microsoft.WindowsAppRuntime.1.8`t8000.616.304.0`tX64"))
    $r = Invoke-Flow -Installed $older -Frameworks $fw
    @($r.Calls -split ', ')[-1]
}
Test-Case '揃っていれば何もしない' '0 []' { $r = Invoke-Flow -Installed $TargetV; "$($r.Code) [$($r.Calls)]" }
Test-Case '新しい版なら何もしない (下げない)' '0 []' { $r = Invoke-Flow -Installed ([version]'1.31.10'); "$($r.Code) [$($r.Calls)]" }
Test-Case '-Force は同じ版なら入れ直す' "0 [$fullFlow]" { $r = Invoke-Flow -Installed $TargetV -Force; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Force でも新しい版なら何もしない (下げない)' '0 [] True' { $r = Invoke-Flow -Installed ([version]'1.31.10') -Force; "$($r.Code) [$($r.Calls)] $($r.Text -like '*下げない*')" }
Test-Case '落とせなければ、何も変えずに止まる' '1 [download Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle] True' { $r = Invoke-Flow -Installed $older -Fail @{ download = 1 }; "$($r.Code) [$($r.Calls)] $($r.Text -like '*何も変えていない*')" }
Test-Case 'sha256 が違えば、入れずに止まる' '1 [download Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle] True' { $r = Invoke-Flow -Installed $older -Fail @{ hash = 1 }; "$($r.Code) [$($r.Calls)] $($r.Text -like '*sha256 が固定した値と違う*')" }
Test-Case 'Add-AppxPackage が落ちたら 1 で、HRESULT の直し方を添える' "1 [$fullFlow] True" { $r = Invoke-Flow -Installed $older -Fail @{ add = 1 }; "$($r.Code) [$($r.Calls)] $($r.Text -like '*方針で止めている*')" }
Test-Case '入っていないときに落ちたら、入っていないと出す' $true { $r = Invoke-Flow -Installed $null -Fail @{ add = 1 }; $r.Text -like '*winget は入っていない。Install-WinGet を打ち直す*' }
Test-Case '入れた後も版が上がらなければ 1' '1 True' { $r = Invoke-Flow -Installed $older -After $older; "$($r.Code) $($r.Text -like '*固定した版にならない*')" }
Test-Case 'CPU が合わなければ、何もせずに 1' '1 [] True' { $r = Invoke-Flow -Installed $older -OsArch 'x86'; "$($r.Code) [$($r.Calls)] $($r.Text -like '*※ の手順で直す*')" }
Test-Case 'curl.exe が無ければ、何もせずに 1' '1 []' { $r = Invoke-Flow -Installed $null -HasCurl $false; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check でも、入れられなければ入っていなくても 1' '1 []' { $r = Invoke-Flow -Installed $null -HasCurl $false -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '表に無い版を固定すると、入れずに 1' '1 [] True' { $r = Invoke-Flow -Installed $older -Version '1.30.999'; "$($r.Code) [$($r.Calls)] $($r.Text -like '*Get-WinGetRelease*')" }
Test-Case '版の形でない -Version は 2' '2' { (Invoke-Flow -Installed $older -Version 'latest').Code }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
