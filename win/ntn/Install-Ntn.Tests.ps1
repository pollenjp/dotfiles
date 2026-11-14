# win/ntn/Install-Ntn.ps1 のうち、副作用の無い関数と、Windows に触る関数を偽物に差し替えた流れのテスト。Pester は使わない。
# winget やプロセスに触る本物の部分は、実機で -Check と本番を打って確かめる (win/README.md の「ntn」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/ntn/Install-Ntn.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Ntn.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-Ntn.ps1')

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

$Id = 'Notion.ntn'
$V = '0.23.28'
$Older = '0.23.27'
$Newer = '0.23.30'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Notion.ntn_Microsoft.Winget.Source_8wekyb3d8bbwe'
$ExeDir = "$Pkg\ntn-x86_64-pc-windows-msvc"
$Links = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links'

# 2026-11-14 に winget-pkgs にあった Notion.ntn の版の新しい方 (winget show --versions の並び。0.23.24 は無い)
$show = @(
    'Found ntn [Notion.ntn]'
    'Version'
    '-------'
    '0.23.30'
    '0.23.29'
    '0.23.28'
    '0.23.27'
)
# 版の一覧 (新しい順)。上げ下げを確かめるため、固定した版より古い版も並べる
# (関数を通さずに書く。関数が無い段階でもテストが最後まで流れるように)
$versions = @($V, $Older)

# Get-NtnVersionFromOutput: ntn.exe --version の出力から版を拾う
Test-Case '"ntn <版>" から版を拾う' $Newer { Get-NtnVersionFromOutput -Lines @("ntn $Newer") }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-NtnVersionFromOutput -Lines @("  ntn $V`r") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-NtnVersionFromOutput -Lines @('warning: something', "ntn $V") }
Test-Case '版の行が無ければ空' '' { Get-NtnVersionFromOutput -Lines @('error: something went wrong') }
Test-Case 'Notion CLI の見出しの行は版と読まない' '' { Get-NtnVersionFromOutput -Lines @('Notion CLI (Beta)') }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$Newer 0.23.29 $V $Older" { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }

# Get-NtnPlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-NtnPlan -Exists $false -Installed $null -Target $V }
Test-Case '同じ版なら none' 'none' { Get-NtnPlan -Exists $true -Installed $V -Target $V }
Test-Case '違う版なら change' 'change' { Get-NtnPlan -Exists $true -Installed $Newer -Target $V }
Test-Case 'ntn.exe があるのに版が読めなければ change' 'change' { Get-NtnPlan -Exists $true -Installed $null -Target $V }

# Get-NtnDirection: 入れ替えの向き (winget show --versions の並びで決める)
$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '固定した版が新しければ up' 'up' { Get-NtnDirection -Versions $showVersions -Installed $Older -Target $V }
Test-Case '入っている版の方が新しければ down (0.23.30 → 0.23.28)' 'down' { Get-NtnDirection -Versions $showVersions -Installed $Newer -Target $V }
Test-Case '入っている版が一覧に無ければ unknown' 'unknown' { Get-NtnDirection -Versions $showVersions -Installed '0.23.24' -Target $V }
Test-Case '一覧が読めなければ unknown' 'unknown' { Get-NtnDirection -Versions @() -Installed $Older -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか。2026-11-14 に pjp-raiden の
# winget pin list が出したもの (Notion.ntn の pin はまだ無い)
$pinsNow = @(
    'Name              Id                        Version     Source Pin type'
    '-----------------------------------------------------------------------'
    'Google 日本語入力 Google.JapaneseIME        3.34.6260.0 winget Pinning'
    'OpenSSH           Microsoft.OpenSSH.Preview 10.0.0.0    winget Pinning'
    'herdr             Herdr.Herdr               0.9.5       winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsNow -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsNow + @("ntn               $Id                $V     winget Pinning")) -PackageId $Id }
Test-Case 'Id の前方一致では True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id).Extra $V winget Pinning") -PackageId $Id }

# Get-WingetCommands: plan ごとに打つ winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版を名指しして入れる' "install $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'change は 2 本 (外してから入れる)' 2 { @(Get-WingetCommands -Plan change -PackageId $Id -Version $V).Count }
Test-Case 'change の 1 本目は uninstall' "uninstall $common" { @(Get-WingetCommands -Plan change -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'none なら打たない' 0 { @(Get-WingetCommands -Plan none -PackageId $Id -Version $V).Count }
Test-Case '取得だけを確かめる winget download の引数' "download --id $Id --exact --source winget --version $V --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -PackageId $Id -Version $V -Directory 'C:\tmp\dl') -join ' ' }

# Resolve-NtnOnPath: PATH を前から見て、最初に見つかった ntn.exe
$exists = { param($p) $p -in @('C:\B\ntn.exe', 'C:\A\ntn.exe') }
Test-Case '前から見て最初に見つかったもの' 'C:\A\ntn.exe' { Resolve-NtnOnPath -PathValue 'C:\A;C:\B' -Names @('ntn.exe') -Exists $exists }
Test-Case '末尾の \・引用符・空白・空の要素を飛ばす' 'C:\B\ntn.exe' { Resolve-NtnOnPath -PathValue ';; "C:\Z\" ; C:\B\ ;' -Names @('ntn.exe') -Exists $exists }
Test-Case 'どこにも無ければ空' '' { Resolve-NtnOnPath -PathValue 'C:\Z;C:\Y' -Names @('ntn.exe') -Exists $exists }
$npm = 'C:\Users\u\AppData\Roaming\npm'
$existsNpm = { param($p) $p -in @("$npm\ntn.cmd", "$ExeDir\ntn.exe") }
Test-Case 'npm の global の ntn.cmd が前のディレクトリにあれば、それが引かれる' "$npm\ntn.cmd" { Resolve-NtnOnPath -PathValue "$npm;$ExeDir" -Names @('ntn.exe', 'ntn.cmd', 'ntn.bat', 'ntn.ps1') -Exists $existsNpm }
Test-Case '同じディレクトリなら .exe を先に見る' "$ExeDir\ntn.exe" { Resolve-NtnOnPath -PathValue "$ExeDir" -Names @('ntn.exe', 'ntn.cmd') -Exists { param($p) $true } }
Test-Case 'npm の ntn.cmd は other' 'other' { Get-NtnPathKind -Resolved "$npm\ntn.cmd" -ExeDir $ExeDir -LinksDir $Links }

# Get-NtnPathKind: PATH で引かれる ntn.exe がどこのものか
Test-Case 'winget の置き場所の ntn.exe なら winget' 'winget' { Get-NtnPathKind -Resolved "$ExeDir\ntn.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case '大文字小文字が違っても winget' 'winget' { Get-NtnPathKind -Resolved "$($ExeDir.ToUpper())\ntn.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'WinGet\Links の symlink なら winget' 'winget' { Get-NtnPathKind -Resolved "$Links\ntn.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'ほかの場所なら other' 'other' { Get-NtnPathKind -Resolved 'C:\Users\u\.cargo\bin\ntn.exe' -ExeDir $ExeDir -LinksDir $Links }
Test-Case '置き場所の直下 (exe のディレクトリでない) は other' 'other' { Get-NtnPathKind -Resolved "$Pkg\ntn.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case '見つからなければ none' 'none' { Get-NtnPathKind -Resolved $null -ExeDir $ExeDir -LinksDir $Links }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$ExeDir\ntn.exe"; PathKind = 'winget'; BusyCount = 0
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 手で入れた新しい版 (pjp-raiden の 2026-11-14 の今。pin も無い)
$handNewer = @{ Installed = $Newer; Plan = 'change'; Direction = 'down'; Pinned = $false; Versions = @($Newer, $V, $Older); Latest = $Newer }

# Test-NtnDrift / Test-NtnPathDrift: 揃える手順で直る差と、直らない PATH のずれ
Test-Case '揃っていれば差は無い' 'False False' { "$(Test-NtnDrift -State (New-State)) $(Test-NtnPathDrift -State (New-State))" }
Test-Case 'pin が無ければ揃える手順で直る差' 'True False' { "$(Test-NtnDrift -State (New-State @{ Pinned = $false })) $(Test-NtnPathDrift -State (New-State @{ Pinned = $false }))" }
Test-Case 'PATH でほかの ntn が先なら PATH のずれ (揃える手順では直らない)' 'False True' { $s = New-State @{ PathKind = 'other'; PathResolved = 'C:\X\ntn.exe' }; "$(Test-NtnDrift -State $s) $(Test-NtnPathDrift -State $s)" }
Test-Case '入っているのに PATH に無ければ PATH のずれ' 'True' { Test-NtnPathDrift -State (New-State @{ PathKind = 'none'; PathResolved = $null }) }
Test-Case '入っていないときに PATH に無いのは、ずれに数えない' 'False' { Test-NtnPathDrift -State (New-State $missing) }

# Get-NtnExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-NtnExitCode -State (New-State) }
Test-Case 'pin が無ければ 1' 1 { Get-NtnExitCode -State (New-State @{ Pinned = $false }) }
Test-Case '版が違えば 1' 1 { Get-NtnExitCode -State (New-State $handNewer) }
Test-Case 'PATH でほかの ntn が先なら 1' 1 { Get-NtnExitCode -State (New-State @{ PathKind = 'other'; PathResolved = 'C:\X\ntn.exe' }) }
Test-Case '入っていなければ 3' 3 { Get-NtnExitCode -State (New-State $missing) }

# Get-NtnApplyBlocker: 揃える前に止める理由
Test-Case '入れられるなら止めない' '' { Get-NtnApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 0 }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-NtnApplyBlocker -Plan install -Versions $versions -Target '0.23.24' -BusyCount 0 }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-NtnApplyBlocker -Plan change -Versions @() -Target $V -BusyCount 0 }
Test-Case '入れ替えるのに ntn が動いていれば busy' 'busy' { Get-NtnApplyBlocker -Plan change -Versions $versions -Target $V -BusyCount 1 }
Test-Case '入れるだけなら動いている数は見ない' '' { Get-NtnApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 2 }
Test-Case 'pin を足すだけなら止めない' '' { Get-NtnApplyBlocker -Plan none -Versions @() -Target 'x' -BusyCount 3 }

# Format-NtnState: 状態の表の行
function Get-Rows { param($State) @(Format-NtnState -State $State -Target $V -PackageId $Id -PackageDir $Pkg) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 6 行だけ' 6 { (Get-Rows (New-State)).Count }
Test-Case '見出しはパッケージ名と置き場所 (bootstrap-windows-ntn.sh がこの頭で見分ける)' "ntn (winget の Notion.ntn、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの版の行' "  固定した版      : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case '手で入れた新しい版から下げるとき' "⚠ 固定した版      : $V → 入れ替える (下げる)" { (Get-Rows (New-State $handNewer))[2].Text }
Test-Case 'pin が無ければ ⚠' '⚠ winget pin      : 無し → 足す' { (Get-Rows (New-State @{ Pinned = $false }))[4].Text }
Test-Case '入っていなければ「入っていない」と「入れる」' "  入っている版    : 入っていない ⚠ 固定した版      : $V → 入れる" { $r = Get-Rows (New-State $missing); "$($r[1].Text) $($r[2].Text)" }
Test-Case '入っていないときに PATH に無いのは ⚠ にしない' '  PATH の ntn     : 見つからない' { (Get-Rows (New-State $missing))[5].Text }
Test-Case '入っているのに PATH に無ければ ⚠' '⚠ PATH の ntn     : 見つからない' { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[5].Text }
Test-Case '版が読めないとき' '  入っている版    : 不明 (ntn.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH でほかの ntn が先なら、その場所を ⚠ で出す' '⚠ PATH の ntn     : C:\Users\u\.cargo\bin\ntn.exe (winget のものではない)' { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\.cargo\bin\ntn.exe' }))[5].Text }
Test-Case 'PATH でほかの ntn が先なら、直し方を ※ で添える' '※ PATH のずれは Install-Ntn では直らない。C:\Users\u\.cargo\bin の ntn.exe を消すか、C:\Users\u\.cargo\bin をユーザーの PATH から外す (win/README.md の「ntn」)' { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\.cargo\bin\ntn.exe' }))[-1].Text }
Test-Case '置き場所が PATH に無ければ、足し直し方を ※ で添える' "※ ntn の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $Id の後に Install-Ntn で入れ直す" { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[-1].Text }
Test-Case 'winget show が失敗したら最新版は不明で、一覧についての ※/⚠ は出さない' '  winget の最新版 : 不明 (winget show が失敗) 6' { $r = Get-Rows (New-State @{ Versions = @(); Latest = $null }); "$($r[3].Text) $($r.Count)" }
Test-Case '新しい版があれば ※ で知らせる (⚠ にしない)' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Ntn.ps1 の -Version の既定値を変える 0" { $r = Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }); "$($r[6].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '固定した版が winget から消えても、入っていれば ※' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { (Get-Rows (New-State @{ Versions = @($Newer, $Older); Latest = $Newer }))[6].Text }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @($Newer, $Older); Latest = $Newer })))[6].Text }
Test-Case '入れ替えが要るのに ntn が動いていれば ※ で添える' '※ ntn.exe が 1 個動いている。入れ替えるには、動いている ntn を終わらせる' { (Get-Rows (New-State ($handNewer + @{ BusyCount = 1 })))[-1].Text }
Test-Case '入れ替えが要らなければ動いている数は出さない' 6 { (Get-Rows (New-State @{ BusyCount = 2 })).Count }

# Format-NtnVerdict: 締めの行。bootstrap-windows-ntn.sh がこの文言で、入れるか・揃えるか・知らせるだけかを決める
function Get-Verdict { param($State) (@(Format-NtnVerdict -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '揃っていれば締めの行は出さない' '' { Get-Verdict (New-State) }
Test-Case '入っていなければ、Install-Ntn で入れると出す' '⚠️ ntn が入っていない → Install-Ntn で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版か pin の差があれば、Install-Ntn で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Ntn で揃える ⚠️' { Get-Verdict (New-State $handNewer) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の ntn が winget のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = 'C:\X\ntn.exe' }) }
Test-Case '版の差と PATH のずれが両方あれば、両方を出す' "⚠️ 固定した版と揃っていない → Install-Ntn で揃える ⚠️`n⚠️ PATH の ntn が winget のものではない → ※ の手順で直す ⚠️" { Get-Verdict (New-State ($handNewer + @{ PathKind = 'other'; PathResolved = 'C:\X\ntn.exe' })) }

# Get-NtnInstalledVersion: 起動できない ntn.exe (壊れた・0 バイト) でも例外で止まらず、版は空
$broken = Join-Path ([IO.Path]::GetTempPath()) "install-ntn-tests-broken-$PID.exe"
Set-Content -LiteralPath $broken -Value '' -NoNewline
if (-not $IsWindows) { chmod +x $broken }
Test-Case '起動できない ntn.exe なら版は空 (入れ替えの対象になる)' '' { Get-NtnInstalledVersion -Exe $broken }
Remove-Item -LiteralPath $broken -Force

# Find-NtnExe: manifest の場所を先に見て、無ければ置き場所の下を探す
$findRoot = Join-Path ([IO.Path]::GetTempPath()) "install-ntn-tests-find-$PID"
$nested = Join-Path (Join-Path $findRoot 'ntn-other-layout') 'ntn.exe'
New-Item -ItemType File -Force -Path $nested | Out-Null
Test-Case 'zip の中の形が変わっても、置き場所の下の ntn.exe を見つける' $nested { Find-NtnExe -PackageDir $findRoot }
Test-Case '置き場所が無ければ空' '' { Find-NtnExe -PackageDir (Join-Path $findRoot 'none') }
Remove-Item -LiteralPath $findRoot -Recurse -Force

# 本体の入口: Linux の pwsh には $env:LOCALAPPDATA が無く、本体の最初で例外になる。
# それでも終了コード 2 で止まり、成功 (0) に見せない
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-Ntn.ps1') -Check 2>&1
    $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Invoke-InstallNtn の流れ。Windows に触る関数を偽物に差し替えて、打つ winget の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-ntn-tests-$PID"
$FakeExe = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Notion.ntn_Microsoft.Winget.Source_8wekyb3d8bbwe') 'ntn-x86_64-pc-windows-msvc\ntn.exe'

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する (pin は 'pin add' のように 2 語)。install は ntn.exe を置き、uninstall は消す
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = if ($Arguments[0] -eq 'pin') { "pin $($Arguments[1])" } else { $Arguments[0] }
    $script:Calls.Add($verb)
    $code = 0
    if ($script:Fail.ContainsKey($verb)) { $code = $script:Fail[$verb] }
    if (($code -eq 0) -and ($verb -eq 'install')) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    if (($code -eq 0) -and ($verb -eq 'uninstall')) { Remove-Item -LiteralPath $FakeExe -Force -ErrorAction SilentlyContinue }
    $lines = @()
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("ntn $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Get-NtnState { param($PackageId, $PackageDir, $LinksDir, $Target) $script:States.Dequeue() }
function Get-NtnBusyProcess { param($PackageDir) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'ntn.exe api /v1/users/me' } }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-NtnState が返す順 (揃える前と、揃えた後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [hashtable]$Fail = @{}, [int]$Busy = 0, [switch]$ExeExists, [switch]$PinListed)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:Busy = @()
    if ($Busy -gt 0) { $script:Busy = @(1..$Busy | ForEach-Object { [pscustomobject]@{ Id = 1000 + $_ } }) }
    $script:PinListed = [bool]$PinListed
    Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
    if ($ExeExists) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    $out = @(Invoke-InstallNtn -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$changeState = New-State $handNewer
$synced = New-State
Test-Case '-Check は winget を打たない' '1 []' { $r = Invoke-Flow -States @($changeState) -Check -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていれば何も打たない (版がずれていても入れ替えない)' '1 []' { $r = Invoke-Flow -States @($changeState) -IfMissing -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ install して pin を足す' '0 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '揃っていれば何も打たない' '0 []' { $r = Invoke-Flow -States @($synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'pin だけ無ければ pin を足すだけ' '0 [pin list pin add]' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false }), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '下げる入れ替えも、取得を確かめてから uninstall → install して pin を足す' '0 [download uninstall install pin list pin add]' { $r = Invoke-Flow -States @($changeState, $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
$pinnedNewer = $handNewer.Clone()
$pinnedNewer.Pinned = $true
Test-Case 'pin があれば、入れ替えの前に外す' '0 [download pin remove uninstall install pin list pin add]' { $r = Invoke-Flow -States @((New-State $pinnedNewer), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '動いている ntn があれば、winget を 1 つも打たずに止まり、PID とコマンドラインを出す' '1 [] True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*1001*ntn.exe api*')" }
Test-Case '取得が落ちたら、何も変えずに止まる' '1 [download] True' { $r = Invoke-Flow -States @($changeState) -Fail @{ download = 1 } -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*何も変えていない*')" }
Test-Case 'uninstall が落ちたら install せず、pin を足す (入っている版は残る)' '1 [download uninstall pin list pin add]' { $r = Invoke-Flow -States @($changeState, $changeState) -Fail @{ uninstall = 1 } -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'uninstall の後に install が落ちたら、入れ直し方を出す' $true { $r = Invoke-Flow -States @($changeState, (New-State $missing)) -Fail @{ install = 1 } -ExeExists; ($r.Code -eq 1) -and ($r.Text -like '*Install-Ntn を打ち直す*') }
Test-Case '固定した版が winget に無ければ、winget を打たずに止まる' '1 []' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @($Newer); Latest = $Newer }))); "$($r.Code) [$($r.Calls)]" }
$pathOnly = New-State @{ PathKind = 'other'; PathResolved = 'C:\X\ntn.exe' }
Test-Case 'PATH のずれだけなら winget を打たずに 1 で止まり、※ の手順で直すと出す' '1 [] True' { $r = Invoke-Flow -States @($pathOnly) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*※ の手順で直す*')" }
Test-Case '揃えた後も PATH のずれが残れば、版と pin は揃ったと出して 1' '1 True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ PathKind = 'other'; PathResolved = 'C:\X\ntn.exe' })), $pathOnly) -ExeExists; "$($r.Code) $($r.Text -like '*版と pin は揃った*')" }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
