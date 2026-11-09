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

$Id = 'Herdr.Herdr'
$PreviewId = 'Herdr.Herdr.Preview'
$V = '0.9.5'
$Older = '0.9.4'
$Newer = '0.9.6'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Herdr.Herdr_Microsoft.Winget.Source_8wekyb3d8bbwe'
$PreviewPkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'

# 2026-11-09 に winget show --id Herdr.Herdr --exact --versions が出したもの (安定版はまだ 0.9.5 だけ)
$show = @(
    'Found herdr [Herdr.Herdr]'
    'Version'
    '-------'
    '0.9.5'
)
# 版の一覧 (新しい順)。上げ下げを確かめるため、固定した版より古い版も並べる
# (関数を通さずに書く。関数が無い段階でもテストが最後まで流れるように)
$versions = @($V, $Older)

# Get-HerdrVersionFromOutput: herdr.exe --version の出力から版を拾う
Test-Case '"herdr <版>" から版を拾う' $V { Get-HerdrVersionFromOutput -Lines @("herdr $V") }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-HerdrVersionFromOutput -Lines @("  herdr $V`r") }
Test-Case 'ほかの行が先にあっても拾う' '0.9.0' { Get-HerdrVersionFromOutput -Lines @('warning: config issues found', 'herdr 0.9.0') }
Test-Case '版の行が無ければ空' '' { Get-HerdrVersionFromOutput -Lines @('error: something went wrong') }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' $V { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }
Test-Case '数値だけの版 (OpenSSH の形) も拾う' '10.0.0.0' { Get-WingetVersionList -Lines @('Version', '--------', '10.0.0.0') }
Test-Case '後ろに印の付いた版 (Herdr.Herdr.Preview の形) も上から順に拾う' '0.9.4-preview.2026-10-14-fbd2ae23927f 0.9.3-preview.2026-10-12-6d697e1e75ff' { Get-WingetVersionList -Lines @('Version', '-------------------------------------', '0.9.4-preview.2026-10-14-fbd2ae23927f', '0.9.3-preview.2026-10-12-6d697e1e75ff') }

# Get-HerdrPlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-HerdrPlan -Exists $false -Installed $null -Target $V }
Test-Case '同じ版なら none' 'none' { Get-HerdrPlan -Exists $true -Installed $V -Target $V }
Test-Case '違う版なら change' 'change' { Get-HerdrPlan -Exists $true -Installed $Older -Target $V }
Test-Case 'herdr.exe があるのに版が読めなければ change' 'change' { Get-HerdrPlan -Exists $true -Installed $null -Target $V }
Test-Case '後ろに印の付いた版は、同じ数字でも change (版は文字列のまま比べる)' 'change' { Get-HerdrPlan -Exists $true -Installed "$V-rc1" -Target $V }

# Get-HerdrDirection: 入れ替えの向き (winget show --versions の並びで決める)
Test-Case '固定した版が新しければ up' 'up' { Get-HerdrDirection -Versions $versions -Installed $Older -Target $V }
Test-Case '固定した版が古ければ down' 'down' { Get-HerdrDirection -Versions $versions -Installed $V -Target $Older }
Test-Case '入っている版が一覧に無ければ unknown' 'unknown' { Get-HerdrDirection -Versions $versions -Installed '0.7.5' -Target $V }
Test-Case '一覧が読めなければ unknown' 'unknown' { Get-HerdrDirection -Versions @() -Installed $Older -Target $V }
Test-Case '同じなら same' 'same' { Get-HerdrDirection -Versions $versions -Installed $V -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか。2026-11-09 に
# winget pin list --id Herdr.Herdr --exact が出したもの (--id を付けても、ほかのパッケージの pin も並ぶ)
$pinsNow = @(
    'Name              Id                        Version     Source Pin type'
    '-----------------------------------------------------------------------'
    'Google 日本語入力 Google.JapaneseIME        3.34.6260.0 winget Pinning'
    'herdr (Preview)   Herdr.Herdr.Preview                   winget Pinning'
    'OpenSSH           Microsoft.OpenSSH.Preview 10.0.0.0    winget Pinning'
)
Test-Case 'Herdr.Herdr.Preview の pin しか無ければ、Herdr.Herdr は False' 'False' { Test-WingetPinned -Lines $pinsNow -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsNow + @("herdr             $Id                               winget Pinning")) -PackageId $Id }
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

# Get-HerdrPathKind: PATH で引かれる herdr.exe がどこのものか (Herdr.Herdr・Herdr.Herdr.Preview・ほか)
Test-Case 'winget の置き場所のものなら winget' 'winget' { Get-HerdrPathKind -Resolved "$Pkg\herdr.exe" -PackageDir $Pkg -PreviewDir $PreviewPkg }
Test-Case '大文字小文字が違っても winget' 'winget' { Get-HerdrPathKind -Resolved "$($Pkg.ToUpper())\herdr.exe" -PackageDir $Pkg -PreviewDir $PreviewPkg }
Test-Case 'Herdr.Herdr.Preview の置き場所のものなら preview' 'preview' { Get-HerdrPathKind -Resolved "$PreviewPkg\herdr.exe" -PackageDir $Pkg -PreviewDir $PreviewPkg }
Test-Case 'herdr update で入ったものなら other' 'other' { Get-HerdrPathKind -Resolved 'C:\Users\u\AppData\Local\Programs\Herdr\bin\herdr.exe' -PackageDir $Pkg -PreviewDir $PreviewPkg }
Test-Case '見つからなければ none' 'none' { Get-HerdrPathKind -Resolved $null -PackageDir $Pkg -PreviewDir $PreviewPkg }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$Pkg\herdr.exe"; PathKind = 'winget'; BusyCount = 0
        PreviewExists = $false
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# Herdr.Herdr.Preview が残っている (PATH で引かれるのは Herdr.Herdr のもの)
$previewLeft = @{ PreviewExists = $true }
# Herdr.Herdr.Preview が残っていて、PATH でも Preview の herdr が先に引かれる (Herdr.Herdr を後から並べて入れたとき)
$previewOnPath = @{ PreviewExists = $true; PathKind = 'preview'; PathResolved = "$PreviewPkg\herdr.exe" }
# Herdr.Herdr は入っておらず、Herdr.Herdr.Preview だけがある (Preview から移る前の PC)
$previewOnly = @{ Exists = $false; Installed = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'preview'; PathResolved = "$PreviewPkg\herdr.exe"; PreviewExists = $true }

# Test-HerdrDrift: Install-Herdr で直せる差 (版・pin・PATH) があるか
Test-Case '揃っていれば、Install-Herdr で直す差は無い' 'False' { Test-HerdrDrift -State (New-State) }
Test-Case 'pin が無ければ差がある' 'True' { Test-HerdrDrift -State (New-State @{ Pinned = $false }) }
Test-Case '版が違えば差がある' 'True' { Test-HerdrDrift -State (New-State @{ Installed = $Older; Plan = 'change' }) }
Test-Case '入っていなければ差がある' 'True' { Test-HerdrDrift -State (New-State $missing) }
Test-Case 'PATH で herdr update の herdr が先なら差がある' 'True' { Test-HerdrDrift -State (New-State @{ PathKind = 'other' }) }
Test-Case 'Preview が残っているだけなら、差には数えない' 'False' { Test-HerdrDrift -State (New-State $previewLeft) }
Test-Case 'PATH で Preview の herdr が先なのは、Preview を外せば直るので差には数えない' 'False' { Test-HerdrDrift -State (New-State $previewOnPath) }

# Get-HerdrExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-HerdrExitCode -State (New-State) }
Test-Case 'pin が無ければ 1' 1 { Get-HerdrExitCode -State (New-State @{ Pinned = $false }) }
Test-Case 'PATH で別の herdr が先なら 1' 1 { Get-HerdrExitCode -State (New-State @{ PathKind = 'other' }) }
Test-Case '版が違えば 1' 1 { Get-HerdrExitCode -State (New-State @{ Installed = $Older; Plan = 'change' }) }
Test-Case '入っていなければ 3' 3 { Get-HerdrExitCode -State (New-State $missing) }
Test-Case 'Herdr.Herdr が揃っていても、Preview が残っていれば 1' 1 { Get-HerdrExitCode -State (New-State $previewLeft) }
Test-Case 'PATH で Preview の herdr が先なら 1' 1 { Get-HerdrExitCode -State (New-State $previewOnPath) }
Test-Case 'Preview が残っていても、Herdr.Herdr が入っていなければ 3 (setup が並べて入れる)' 3 { Get-HerdrExitCode -State (New-State $previewOnly) }

# Get-HerdrApplyBlocker: 揃える前に止める理由
Test-Case '入れられるなら止めない' '' { Get-HerdrApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 0 }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-HerdrApplyBlocker -Plan install -Versions $versions -Target '9.9.9-preview.typo' -BusyCount 0 }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-HerdrApplyBlocker -Plan change -Versions @() -Target $V -BusyCount 0 }
Test-Case '入れ替えるのに herdr が動いていれば busy' 'busy' { Get-HerdrApplyBlocker -Plan change -Versions $versions -Target $V -BusyCount 2 }
Test-Case '入れるだけなら動いている数は見ない' '' { Get-HerdrApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 2 }
Test-Case 'pin を足すだけなら止めない' '' { Get-HerdrApplyBlocker -Plan none -Versions @() -Target 'x' -BusyCount 3 }

# Format-HerdrState: 状態の表の行
function Get-Rows { param($State) @(Format-HerdrState -State $State -Target $V -PackageId $Id -PackageDir $Pkg -PreviewId $PreviewId) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 6 行だけ (Preview の行は出さない)' 6 { (Get-Rows (New-State)).Count }
Test-Case '見出しはパッケージ名と置き場所' "herdr (winget の Herdr.Herdr、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case 'Preview が残っていれば、表の最後に ⚠ の行を足す' '⚠ 前の Preview    : Herdr.Herdr.Preview が残っている → 外す' { (Get-Rows (New-State $previewLeft))[6].Text }
Test-Case 'Preview が残っているだけなら、ほかの行は ⚠ にしない' 1 { @((Get-Rows (New-State $previewLeft)) | Where-Object { $_.Warn }).Count }
Test-Case 'PATH で Preview の herdr が先なら、その場所を ⚠ で出す' "⚠ PATH の herdr   : $PreviewPkg\herdr.exe (Herdr.Herdr.Preview のもの)" { (Get-Rows (New-State $previewOnPath))[5].Text }
Test-Case 'PATH で Preview の herdr が先なら、Preview を外せば直ると ※ で添える' '※ PATH で先に引かれる herdr は Herdr.Herdr.Preview のもの。Preview を外せば直る (外すと winget がその置き場所を PATH から消す)' { (Get-Rows (New-State $previewOnPath))[-1].Text }
Test-Case 'PATH で Preview の herdr が先でも、「PATH から外す」とは言わない' 0 { @((Get-Rows (New-State $previewOnPath)) | Where-Object { $_.Text -like '*PATH から外す*' }).Count }
Test-Case 'Herdr.Herdr が入っていなくて Preview だけがあるときも、Preview の行を出す' '⚠ 前の Preview    : Herdr.Herdr.Preview が残っている → 外す' { (Get-Rows (New-State $previewOnly))[6].Text }
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
Test-Case '新しい版があれば ※ で知らせる' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Herdr.ps1 の -Version の既定値を変える" { (Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }))[6].Text }
Test-Case '新しい版は ⚠ にしない' 0 { @((Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer })) | Where-Object { $_.Warn }).Count }
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

# PATH のずれは Install-Herdr では直らないので、直し方を ※ で添える (レビューの I2)
$rel = 'C:\Users\u\.herdr\packages\standalone\releases\0.9.3-x86_64-pc-windows-msvc'
Test-Case 'PATH で別の herdr が先なら、外すディレクトリを ※ で添える' "※ PATH のずれは Install-Herdr では直らない。$rel をユーザーの PATH から外す (win/README.md の「herdr を入れる」)" { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = "$rel\herdr.exe" }))[6].Text }
Test-Case 'winget の置き場所が PATH に無ければ、足し直し方を ※ で添える' '※ winget の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id Herdr.Herdr の後に Install-Herdr で入れ直す' { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[6].Text }
Test-Case '入っていないときは PATH の ※ を出さない' 6 { (Get-Rows (New-State $missing)).Count }

# Format-HerdrVerdict: 締めの行。bootstrap-windows-herdr.sh がこの文言で枠の見出しと直し方を決める。
# Preview は product code で外す (Herdr.Herdr を並べて入れると、winget は Preview を Herdr.Herdr として数え、
# winget list --id Herdr.Herdr.Preview --exact では見つからなくなる。2026-11-09 に実機で確かめた)。
# pin は Preview を外した後に外す (先に打つと、Herdr.Herdr に結ばれた Preview の行に当たりうる)
$PreviewProductCode = 'Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'
function Get-Verdict { param($State) (@(Format-HerdrVerdict -State $State -PackageId $Id -PreviewId $PreviewId -PreviewProductCode $PreviewProductCode) | ForEach-Object { "$_" }) -join "`n" }
$previewSteps = @(
    '⚠️   1. herdr の外の PowerShell (Windows Terminal など) で hsvstop を打ち、herdr --remote の窓も閉じる'
    '⚠️   2. winget uninstall --product-code Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe を打つ'
    '⚠️   3. winget pin remove --id Herdr.Herdr.Preview --exact を打つ (Preview の pin を外す)'
    '⚠️   4. 新しい PowerShell から herdr を起動し直す'
) -join "`n"
Test-Case '揃っていれば締めの行は出さない' '' { Get-Verdict (New-State) }
Test-Case '入っていなければ、Install-Herdr で入れると出す' '⚠️ herdr が入っていない → Install-Herdr で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版・pin・PATH の差があれば、Install-Herdr で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Herdr で揃える ⚠️' { Get-Verdict (New-State @{ Pinned = $false }) }
Test-Case 'Preview が残っていれば、外す手順を出す' "⚠️ Herdr.Herdr.Preview が残っている → 次の手順で外す (Install-Herdr は外さない) ⚠️`n$previewSteps" { Get-Verdict (New-State $previewOnPath) }
Test-Case '差があって Preview も残っていれば、揃えることを先に出す' "⚠️ 固定した版と揃っていない → Install-Herdr で揃える ⚠️`n⚠️ Herdr.Herdr.Preview が残っている → 次の手順で外す (Install-Herdr は外さない) ⚠️`n$previewSteps" { Get-Verdict (New-State ($previewLeft + @{ Pinned = $false })) }
Test-Case 'Herdr.Herdr が入っていなければ、入れてから Preview を外すと出す' "⚠️ herdr が入っていない → Install-Herdr で入れる ⚠️`n⚠️ Herdr.Herdr.Preview が残っている → Herdr.Herdr を入れてから、次の手順で外す (Install-Herdr は外さない) ⚠️`n$previewSteps" { Get-Verdict (New-State $previewOnly) }

# Get-HerdrInstalledVersion: 起動できない herdr.exe (壊れた・0 バイト) でも例外で止まらず、版は空 (レビューの M2)
$broken = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-tests-broken-$PID.exe"
Set-Content -LiteralPath $broken -Value '' -NoNewline
if (-not $IsWindows) { chmod +x $broken }
Test-Case '起動できない herdr.exe なら版は空 (入れ替えの対象になる)' '' { Get-HerdrInstalledVersion -Exe $broken }
Remove-Item -LiteralPath $broken -Force

# Get-WingetDownloadArguments: 入れ替えの前に、取得とハッシュだけを確かめる引数 (レビューの I1)
Test-Case '取得だけを確かめる winget download の引数' "download --id $Id --exact --source winget --version $V --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -PackageId $Id -Version $V -Directory 'C:\tmp\dl') -join ' ' }

# ---------------------------------------------------------------------------
# Invoke-InstallHerdr の流れ (レビューの I3)。Windows に触る関数を偽物に差し替えて、
# 打つ winget の順と、途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-tests-$PID"
$FakeExe = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Herdr.Herdr_Microsoft.Winget.Source_8wekyb3d8bbwe') 'herdr.exe'

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する (pin は 'pin add' のように 2 語)。install は herdr.exe を置き、uninstall は消す
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = if ($Arguments[0] -eq 'pin') { "pin $($Arguments[1])" } else { $Arguments[0] }
    $script:Calls.Add($verb)
    $code = 0
    if ($script:Fail.ContainsKey($verb)) { $code = $script:Fail[$verb] }
    if (($code -eq 0) -and ($verb -eq 'install')) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    if (($code -eq 0) -and ($verb -eq 'uninstall')) { Remove-Item -LiteralPath $FakeExe -Force -ErrorAction SilentlyContinue }
    $lines = @()
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("herdr $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Get-HerdrState { param($PackageId, $PackageDir, $PreviewDir, $Target) $script:States.Dequeue() }
function Get-HerdrBusyProcess { param($PackageDir) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'herdr.exe server' } }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-HerdrState が返す順 (揃える前と、揃えた後に読み直したもの)
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
    $out = @(Invoke-InstallHerdr -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$changeState = New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up' }
$synced = New-State
Test-Case '-Check は winget を打たない' '1 []' { $r = Invoke-Flow -States @($changeState) -Check -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていれば何も打たない (pin が無くても足さない)' '1 []' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false })) -IfMissing -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ install して pin を足す' '0 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '揃っていれば何も打たない' '0 []' { $r = Invoke-Flow -States @($synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'pin だけ無ければ pin を足すだけ' '0 [pin list pin add]' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false }), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '動いている herdr があれば、winget を 1 つも打たずに止まる' '1 []' { $r = Invoke-Flow -States @((New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up'; BusyCount = 2 })) -Busy 2 -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '動いている herdr があれば、止め方と PID を出す' $true { $r = Invoke-Flow -States @((New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up'; BusyCount = 2 })) -Busy 2 -ExeExists; ($r.Text -like '*hsvstop*') -and ($r.Text -like '*1001*herdr.exe server*') }
Test-Case '入れ替えは取得を確かめてから pin を外し、uninstall → install して pin を足す' '0 [download pin remove uninstall install pin list pin add]' { $r = Invoke-Flow -States @($changeState, $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '取得が落ちたら、何も変えずに止まる' '1 [download]' { $r = Invoke-Flow -States @($changeState) -Fail @{ download = 1 } -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '取得が落ちたら、何も変えていないと出す' $true { $r = Invoke-Flow -States @($changeState) -Fail @{ download = 1 } -ExeExists; $r.Text -like '*何も変えていない*' }
Test-Case 'uninstall が落ちたら install せず、外した pin を足し直す' '1 [download pin remove uninstall pin list pin add]' { $r = Invoke-Flow -States @($changeState, $changeState) -Fail @{ uninstall = 1 } -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'uninstall の後に install が落ちたら、入れ直し方を出す' $true { $r = Invoke-Flow -States @($changeState, (New-State $missing)) -Fail @{ install = 1 } -ExeExists; ($r.Code -eq 1) -and ($r.Text -like '*Install-Herdr を打ち直す*') }

# Herdr.Herdr.Preview が残っているとき。Preview は外さず (pin remove も uninstall も打たない)、外す手順を出す
$previewState = New-State $previewOnPath
Test-Case '-Check は Preview が残っていれば 1 で、winget は打たない' '1 []' { $r = Invoke-Flow -States @($previewState) -Check -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は Preview が残っていれば、外す手順を出し、揃っているとは言わない' $true { $r = Invoke-Flow -States @($previewState) -Check -ExeExists; ($r.Text -like "*winget uninstall --product-code $PreviewProductCode*") -and ($r.Text -notlike '*揃っている*') }
Test-Case '-IfMissing は Preview が残っていても、Herdr.Herdr が無ければ並べて入れて pin を足す' '1 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $previewOnly), $previewState) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '並べて入れた後は、Herdr.Herdr は揃ったと出し、Preview を外す手順を出す (Install-Herdr で揃えるとは言わない)' $true { $r = Invoke-Flow -States @((New-State $previewOnly), $previewState) -IfMissing; ($r.Text -like "*$Id は揃った*") -and ($r.Text -like "*winget uninstall --product-code $PreviewProductCode*") -and ($r.Text -notlike '*Install-Herdr で揃える*') }
Test-Case '揃えるとき、残っているのが Preview だけなら winget を打たずに 1 で止まる' '1 []' { $r = Invoke-Flow -States @($previewState) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)]" }
Test-Case '残っているのが Preview だけなら、Herdr.Herdr は揃っていると出し、外す手順を出す' $true { $r = Invoke-Flow -States @($previewState) -ExeExists -PinListed; ($r.Text -like "*$Id は揃っている*") -and ($r.Text -like "*winget pin remove --id $PreviewId --exact*") }
Test-Case '揃えるとき、pin が無くて Preview も残っていれば、pin だけ足して Preview を外す手順を出す' '1 [pin list pin add] True' { $r = Invoke-Flow -States @((New-State ($previewOnPath + @{ Pinned = $false })), $previewState) -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like "*winget uninstall --product-code $PreviewProductCode*")" }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
