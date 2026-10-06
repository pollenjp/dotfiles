# win/herdr/Install-Herdr.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget やプロセスに触る部分は、実機で -Check と本番を打って確かめる (win/README.md の「herdr を入れる」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/herdr/Install-Herdr.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Herdr.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-Herdr.ps1')

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

$Id = 'Herdr.Herdr.Preview'
$V = '0.9.2-preview.2026-09-29-8e78f929d8f0'
$Older = '0.9.1-preview.2026-09-29-9dc3a1df2b56'
$Newer = '0.9.3-preview.2026-10-05-0123456789ab'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'

# 2026-10-06 に winget show --id Herdr.Herdr.Preview --exact --versions が出したもの
$show = @(
    'Found herdr (Preview) [Herdr.Herdr.Preview]'
    'Version'
    '-------------------------------------'
    '0.9.2-preview.2026-09-29-8e78f929d8f0'
    '0.9.1-preview.2026-09-29-9dc3a1df2b56'
    '0.9.1-preview.2026-09-28-80c0c07250d2'
    '0.9.0-preview.2026-09-16-2c29fb29e302'
    '0.9.0-preview.2026-09-08-62431dbd033b'
    '0.8.2-preview.2026-09-06-9e9bc8a14466'
    '0.8.2-preview.2026-08-31-b1ff4582e968'
    '0.8.2-preview.2026-08-19-b5c4a0176e91'
    '0.8.0-preview.2026-08-18-9fac51722653'
    '0.8.0-preview.2026-08-04-d78e3d3b5126'
)
# 上の版の行だけ (関数を通さずに書く。関数が無い段階でもテストが最後まで流れるように)
$versions = @($show[3..12])

# Get-HerdrVersionFromOutput: herdr.exe --version の出力から版を拾う
Test-Case '"herdr <版>" から版を拾う' $V { Get-HerdrVersionFromOutput -Lines @("herdr $V") }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-HerdrVersionFromOutput -Lines @("  herdr $V`r") }
Test-Case 'ほかの行が先にあっても拾う' '0.9.0' { Get-HerdrVersionFromOutput -Lines @('warning: config issues found', 'herdr 0.9.0') }
Test-Case '版の行が無ければ空' '' { Get-HerdrVersionFromOutput -Lines @('error: something went wrong') }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを上から順に拾う (見出し・区切りは拾わない)' ($versions -join ' ') { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }
Test-Case '数値だけの版 (OpenSSH の形) も拾う' '10.0.0.0' { Get-WingetVersionList -Lines @('Version', '--------', '10.0.0.0') }

# Get-HerdrPlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-HerdrPlan -Exists $false -Installed $null -Target $V }
Test-Case '同じ版なら none' 'none' { Get-HerdrPlan -Exists $true -Installed $V -Target $V }
Test-Case '違う版なら change' 'change' { Get-HerdrPlan -Exists $true -Installed $Older -Target $V }
Test-Case 'herdr.exe があるのに版が読めなければ change' 'change' { Get-HerdrPlan -Exists $true -Installed $null -Target $V }
Test-Case '大文字小文字だけ違っても change (版は文字列のまま比べる)' 'change' { Get-HerdrPlan -Exists $true -Installed $V.ToUpper() -Target $V }

# Get-HerdrDirection: 入れ替えの向き (winget show --versions の並びで決める)
Test-Case '固定した版が新しければ up' 'up' { Get-HerdrDirection -Versions $versions -Installed $Older -Target $V }
Test-Case '固定した版が古ければ down' 'down' { Get-HerdrDirection -Versions $versions -Installed $V -Target $Older }
Test-Case '入っている版が一覧に無ければ unknown' 'unknown' { Get-HerdrDirection -Versions $versions -Installed '0.7.5' -Target $V }
Test-Case '一覧が読めなければ unknown' 'unknown' { Get-HerdrDirection -Versions @() -Installed $Older -Target $V }
Test-Case '同じなら same' 'same' { Get-HerdrDirection -Versions $versions -Installed $V -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか (2026-10-06 の出力)
$pinsOpenSsh = @(
    'Name    Id                        Version  Source Pin type'
    '----------------------------------------------------------'
    'OpenSSH Microsoft.OpenSSH.Preview 10.0.0.0 winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsOpenSsh -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsOpenSsh + @("herdr (Preview) $Id $V winget Pinning")) -PackageId $Id }
Test-Case 'Id の前方一致では True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id).Extra $V winget Pinning") -PackageId $Id }

# Get-WingetCommands: plan ごとに打つ winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は 1 本' 1 { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V).Count }
Test-Case 'install は版を名指しして入れる' "install $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'change は 2 本 (外してから入れる)' 2 { @(Get-WingetCommands -Plan change -PackageId $Id -Version $V).Count }
Test-Case 'change の 1 本目は uninstall' "uninstall $common" { @(Get-WingetCommands -Plan change -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'change の 2 本目は版を名指しした install' "install $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Plan change -PackageId $Id -Version $V)[1] -join ' ' }
Test-Case 'none なら打たない' 0 { @(Get-WingetCommands -Plan none -PackageId $Id -Version $V).Count }

# Resolve-HerdrOnPath: PATH を前から見て、最初に見つかった herdr.exe
$exists = { param($p) $p -in @('C:\B\herdr.exe', 'C:\A\herdr.exe') }
Test-Case '前から見て最初に見つかったもの' 'C:\A\herdr.exe' { Resolve-HerdrOnPath -PathValue 'C:\A;C:\B' -Name 'herdr.exe' -Exists $exists }
Test-Case '前に無ければ次を見る' 'C:\B\herdr.exe' { Resolve-HerdrOnPath -PathValue 'C:\Z;C:\B' -Name 'herdr.exe' -Exists $exists }
Test-Case '末尾の \・引用符・空白・空の要素を飛ばす' 'C:\B\herdr.exe' { Resolve-HerdrOnPath -PathValue ';; "C:\Z\" ; C:\B\ ;' -Name 'herdr.exe' -Exists $exists }
Test-Case '%VAR% を展開してから見る' 'C:\B\herdr.exe' { $env:TKT112_HERDR_TEST = 'C:\B'; Resolve-HerdrOnPath -PathValue '%TKT112_HERDR_TEST%' -Name 'herdr.exe' -Exists $exists }
Test-Case 'どこにも無ければ空' '' { Resolve-HerdrOnPath -PathValue 'C:\Z;C:\Y' -Name 'herdr.exe' -Exists $exists }

# Get-HerdrPathKind: PATH で引かれる herdr.exe が winget の置き場所のものか
Test-Case 'winget の置き場所のものなら winget' 'winget' { Get-HerdrPathKind -Resolved "$Pkg\herdr.exe" -PackageDir $Pkg }
Test-Case '大文字小文字が違っても winget' 'winget' { Get-HerdrPathKind -Resolved "$($Pkg.ToUpper())\herdr.exe" -PackageDir $Pkg }
Test-Case 'herdr update で入ったものなら other' 'other' { Get-HerdrPathKind -Resolved 'C:\Users\u\AppData\Local\Programs\Herdr\bin\herdr.exe' -PackageDir $Pkg }
Test-Case '見つからなければ none' 'none' { Get-HerdrPathKind -Resolved $null -PackageDir $Pkg }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$Pkg\herdr.exe"; PathKind = 'winget'; BusyCount = 0
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }

# Get-HerdrExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-HerdrExitCode -State (New-State) }
Test-Case 'pin が無ければ 1' 1 { Get-HerdrExitCode -State (New-State @{ Pinned = $false }) }
Test-Case 'PATH で別の herdr が先なら 1' 1 { Get-HerdrExitCode -State (New-State @{ PathKind = 'other' }) }
Test-Case '版が違えば 1' 1 { Get-HerdrExitCode -State (New-State @{ Installed = $Older; Plan = 'change' }) }
Test-Case '入っていなければ 3' 3 { Get-HerdrExitCode -State (New-State $missing) }

# Get-HerdrApplyBlocker: 揃える前に止める理由
Test-Case '入れられるなら止めない' '' { Get-HerdrApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 0 }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-HerdrApplyBlocker -Plan install -Versions $versions -Target '9.9.9-preview.typo' -BusyCount 0 }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-HerdrApplyBlocker -Plan change -Versions @() -Target $V -BusyCount 0 }
Test-Case '入れ替えるのに herdr が動いていれば busy' 'busy' { Get-HerdrApplyBlocker -Plan change -Versions $versions -Target $V -BusyCount 2 }
Test-Case '入れるだけなら動いている数は見ない' '' { Get-HerdrApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 2 }
Test-Case 'pin を足すだけなら止めない' '' { Get-HerdrApplyBlocker -Plan none -Versions @() -Target 'x' -BusyCount 3 }

# Format-HerdrState: 状態の表の行
function Get-Rows { param($State) @(Format-HerdrState -State $State -Target $V -PackageDir $Pkg) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 6 行だけ' 6 { (Get-Rows (New-State)).Count }
Test-Case '見出しはパッケージ名と置き場所' "herdr (winget の Herdr.Herdr.Preview、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの版の行' "  固定した版      : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case 'pin が無ければ ⚠' '⚠ winget pin      : 無し → 足す' { (Get-Rows (New-State @{ Pinned = $false }))[4].Text }
Test-Case '入っていなければ「入っていない」' '  入っている版    : 入っていない' { (Get-Rows (New-State $missing))[1].Text }
Test-Case '入っていなければ「入れる」で ⚠' "⚠ 固定した版      : $V → 入れる" { (Get-Rows (New-State $missing))[2].Text }
Test-Case '入っていないときに PATH に無いのは ⚠ にしない' '  PATH の herdr   : 見つからない' { (Get-Rows (New-State $missing))[5].Text }
Test-Case '入っているのに PATH に無ければ ⚠' '⚠ PATH の herdr   : 見つからない' { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[5].Text }
Test-Case '古い版から上げるとき' "⚠ 固定した版      : $V → 入れ替える (上げる)" { (Get-Rows (New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up' }))[2].Text }
Test-Case '新しい版から下げるとき' "⚠ 固定した版      : $V → 入れ替える (下げる)" { (Get-Rows (New-State @{ Installed = $Newer; Plan = 'change'; Direction = 'down' }))[2].Text }
Test-Case '版が読めないとき' '  入っている版    : 不明 (herdr.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH で別の herdr が先なら、その場所を ⚠ で出す' '⚠ PATH の herdr   : C:\Users\u\AppData\Local\Programs\Herdr\bin\herdr.exe (winget のものではない)' { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\AppData\Local\Programs\Herdr\bin\herdr.exe' }))[5].Text }
Test-Case 'winget show が失敗したら最新版は不明' '  winget の最新版 : 不明 (winget show が失敗)' { (Get-Rows (New-State @{ Versions = @(); Latest = $null }))[3].Text }
Test-Case 'winget show が失敗したら、一覧についての ※/⚠ は出さない' 6 { (Get-Rows (New-State @{ Versions = @(); Latest = $null })).Count }
Test-Case '新しい preview があれば ※ で知らせる' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Herdr.ps1 の -Version の既定値を変える" { (Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }))[6].Text }
Test-Case '新しい preview は ⚠ にしない' 0 { @((Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer })) | Where-Object { $_.Warn }).Count }
Test-Case '固定した版が winget から消えても、入っていれば ※' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { (Get-Rows (New-State @{ Versions = @($Newer, $Older); Latest = $Newer }))[6].Text }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @($Newer, $Older); Latest = $Newer })))[6].Text }
Test-Case '入れ替えが要るのに herdr が動いていれば ※ で止め方を添える' '※ herdr.exe などが 2 個動いている。入れ替えるには、herdr の外の PowerShell で hsvstop を打ち、herdr --remote の窓も閉じる' { (Get-Rows (New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up'; BusyCount = 2 }))[-1].Text }
Test-Case '入れ替えが要らなければ動いている数は出さない' 6 { (Get-Rows (New-State @{ BusyCount = 2 })).Count }

# 本体の入口: Linux の pwsh には $env:LOCALAPPDATA が無く、本体の最初で例外になる。
# それでも終了コード 2 で止まり、成功 (0) に見せない
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-Herdr.ps1') -Check 2>&1
    $LASTEXITCODE
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
