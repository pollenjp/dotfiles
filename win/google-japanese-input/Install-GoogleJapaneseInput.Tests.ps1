# win/google-japanese-input/Install-GoogleJapaneseInput.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget やファイルに触る部分は、実機で -Check と本番を打って確かめる (win/README.md の「Google 日本語入力を入れる」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/google-japanese-input/Install-GoogleJapaneseInput.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-GoogleJapaneseInput.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-GoogleJapaneseInput.ps1')

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

$Id = 'Google.JapaneseIME'
$V = '3.34.6260.0'
$Old = '2.29.5370.0'
$X64 = 'C:\Program Files\Google\Google Japanese Input\GoogleIMEJaConverter.exe'
$X86 = 'C:\Program Files (x86)\Google\Google Japanese Input\GoogleIMEJaConverter.exe'

# 2026-10-12 に winget show --id Google.JapaneseIME --exact --versions が出したもの
$show = @(
    'Found Google 日本語入力 [Google.JapaneseIME]'
    'Version'
    '-----------'
    '3.34.6260.0'
    '3.34.6230.0'
    '3.33.6130.0'
    '3.33.6088.0'
    '2.32.5990.0'
    '2.31.5840.0'
    '2.30.5620.0'
    '2.30.5610.0'
    '2.29.5370.0'
    '2.28.4650.0'
)
# 上の版の行だけ (関数を通さずに書く。関数が無い段階でもテストが最後まで流れるように)
$versions = @($show[3..12])

# ConvertTo-GoogleImeVersion: ProductVersion の文字列を [version] にする
Test-Case 'ProductVersion の形を読む' $Old { ConvertTo-GoogleImeVersion -Text $Old }
Test-Case '前後の空白を落とす' $V { ConvertTo-GoogleImeVersion -Text "  $V `r" }
Test-Case 'FileVersion の形 (build 付き) は読まない' '' { ConvertTo-GoogleImeVersion -Text '2.29.5370.0  (build 63)' }
Test-Case '空なら空' '' { ConvertTo-GoogleImeVersion -Text '' }
Test-Case '$null なら空' '' { ConvertTo-GoogleImeVersion -Text $null }
Test-Case '[version] に収まらない数なら空 (例外にしない)' '' { ConvertTo-GoogleImeVersion -Text '99999999999.1' }
Test-Case '3 つ区切りは 4 つ目を 0 にそろえる' '3.34.6260.0' { ConvertTo-GoogleImeVersion -Text '3.34.6260' }
Test-Case '3 つ区切りと 4 つ区切りの同じ版は等しい' $true { (ConvertTo-GoogleImeVersion -Text '3.34.6260') -eq (ConvertTo-GoogleImeVersion -Text '3.34.6260.0') }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを上から順に拾う (見出し・区切りは拾わない)' ($versions -join ' ') { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }

# Get-GoogleImeConverterPath: 探す場所
Test-Case '64 ビットと x86 の 2 か所 (同じ値は 1 つにする)' "$X64 $X86" { Get-GoogleImeConverterPath -Roots @('C:\Program Files', 'C:\Program Files', 'C:\Program Files (x86)') }
Test-Case '空の値は飛ばし、末尾の \ は落とす' $X64 { Get-GoogleImeConverterPath -Roots @($null, '', 'C:\Program Files\') }
Test-Case '大文字小文字だけ違う重複も 1 つにする' $X64 { Get-GoogleImeConverterPath -Roots @('C:\Program Files', 'C:\PROGRAM FILES') }

# Select-GoogleImeConverter: 見つかったものから 1 つ選ぶ
$onX86 = [pscustomobject]@{ Path = $X86; ProductVersion = $Old }
$onX64 = [pscustomobject]@{ Path = $X64; ProductVersion = $V }
$broken = [pscustomobject]@{ Path = $X64; ProductVersion = '' }
Test-Case '1 つも無ければ空' '' { Select-GoogleImeConverter -Candidates @() }
Test-Case '1 つならそれ (この PC の 2.29)' "$X86 $Old" { $c = Select-GoogleImeConverter -Candidates @($onX86); "$($c.Path) $($c.Version)" }
Test-Case '2 か所にあれば版の新しい方' "$X64 $V" { $c = Select-GoogleImeConverter -Candidates @($onX86, $onX64); "$($c.Path) $($c.Version)" }
Test-Case '版が読めないものより、読めるものを選ぶ' "$X86 $Old" { $c = Select-GoogleImeConverter -Candidates @($broken, $onX86); "$($c.Path) $($c.Version)" }
Test-Case '版が読めるものが無ければ、最初のもので版は空' "$X64 " { $c = Select-GoogleImeConverter -Candidates @($broken); "$($c.Path) $($c.Version)" }

# Get-GoogleImePlan: することを決める ([version] で比べる)
Test-Case '入っていなければ install' 'install' { Get-GoogleImePlan -Exists $false -Installed $null -Target $V }
Test-Case '古ければ upgrade (この PC の 2.29 → 3.34)' 'upgrade' { Get-GoogleImePlan -Exists $true -Installed $Old -Target $V }
Test-Case '新しければ newer (下げない)' 'newer' { Get-GoogleImePlan -Exists $true -Installed '3.35.0.0' -Target $V }
Test-Case '文字列ではなく数で比べる (6260 < 10000)' 'newer' { Get-GoogleImePlan -Exists $true -Installed '3.34.10000.0' -Target $V }
Test-Case '同じなら none' 'none' { Get-GoogleImePlan -Exists $true -Installed $V -Target $V }
Test-Case 'あるのに版が読めなければ unknown' 'unknown' { Get-GoogleImePlan -Exists $true -Installed $null -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか
$pinsOpenSsh = @(
    'Name    Id                        Version  Source Pin type'
    '----------------------------------------------------------'
    'OpenSSH Microsoft.OpenSSH.Preview 10.0.0.0 winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsOpenSsh -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsOpenSsh + @("Google 日本語入力 $Id $V winget Pinning")) -PackageId $Id }
Test-Case 'Id の前方一致では True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id)2 $V winget Pinning") -PackageId $Id }

# Get-WingetCommands: plan ごとに打つ winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版を名指しして入れる' "install $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'upgrade は版を名指しして上げる' "upgrade $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Plan upgrade -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'install と upgrade は 1 本ずつ' '1 1' { "$(@(Get-WingetCommands -Plan install -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan upgrade -PackageId $Id -Version $V).Count)" }
Test-Case 'none・newer・unknown なら打たない' '0 0 0' { "$(@(Get-WingetCommands -Plan none -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan newer -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan unknown -PackageId $Id -Version $V).Count)" }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Path = $X64; Installed = [version]$V; Plan = 'none'; Pinned = $true
        Versions = $versions; Latest = $versions[0]
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Path = $null; Installed = $null; Plan = 'install'; Pinned = $false }
# この PC (2026-10-12): x86 に 2.29 があり、pin は無い
$thisPc = @{ Path = $X86; Installed = [version]$Old; Plan = 'upgrade'; Pinned = $false }
$thisPcPinned = @{ Path = $X86; Installed = [version]$Old; Plan = 'upgrade'; Pinned = $true }
$newer = @{ Installed = [version]'3.35.0.0'; Plan = 'newer' }

# Get-GoogleImeExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-GoogleImeExitCode -State (New-State) }
Test-Case 'pin が無ければ 1' 1 { Get-GoogleImeExitCode -State (New-State @{ Pinned = $false }) }
Test-Case '古ければ 1' 1 { Get-GoogleImeExitCode -State (New-State $thisPc) }
Test-Case '新しくても 1' 1 { Get-GoogleImeExitCode -State (New-State $newer) }
Test-Case '版が読めなければ 1' 1 { Get-GoogleImeExitCode -State (New-State @{ Installed = $null; Plan = 'unknown' }) }
Test-Case '入っていなければ 3' 3 { Get-GoogleImeExitCode -State (New-State $missing) }

# Get-GoogleImeApplyBlocker: 揃える前に止める理由
Test-Case '入れられるなら止めない' '' { Get-GoogleImeApplyBlocker -Plan install -Versions $versions -Target $V }
Test-Case '上げられるなら止めない' '' { Get-GoogleImeApplyBlocker -Plan upgrade -Versions $versions -Target $V }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-GoogleImeApplyBlocker -Plan upgrade -Versions $versions -Target '3.99.0.0' }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-GoogleImeApplyBlocker -Plan install -Versions @() -Target $V }
Test-Case '新しければ newer で止める' 'newer' { Get-GoogleImeApplyBlocker -Plan newer -Versions $versions -Target $V }
Test-Case '版が読めなければ unknown で止める' 'unknown' { Get-GoogleImeApplyBlocker -Plan unknown -Versions $versions -Target $V }
Test-Case 'pin を足すだけなら止めない' '' { Get-GoogleImeApplyBlocker -Plan none -Versions @() -Target 'x' }

# Format-GoogleImeState: 状態の表の行
function Get-Rows { param($State) @(Format-GoogleImeState -State $State -Target $V) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 5 行だけ' 5 { (Get-Rows (New-State)).Count }
Test-Case '見出しはパッケージ名' 'Google 日本語入力 (winget の Google.JapaneseIME)' { (Get-Rows (New-State))[0].Text }
Test-Case '入っている版と置き場所' "  入っている版    : $V (C:\Program Files\Google\Google Japanese Input)" { (Get-Rows (New-State))[1].Text }
Test-Case '揃っているときの版の行' "  固定した版      : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case 'この PC: x86 の 2.29 を出す' "  入っている版    : $Old (C:\Program Files (x86)\Google\Google Japanese Input)" { (Get-Rows (New-State $thisPc))[1].Text }
Test-Case 'この PC: 上げるで ⚠' "⚠ 固定した版      : $V → 上げる" { (Get-Rows (New-State $thisPc))[2].Text }
Test-Case 'この PC: pin が無くて ⚠' '⚠ winget pin      : 無し → 足す' { (Get-Rows (New-State $thisPc))[4].Text }
Test-Case '入っていなければ「入っていない」' '  入っている版    : 入っていない' { (Get-Rows (New-State $missing))[1].Text }
Test-Case '入っていなければ「入れる」で ⚠' "⚠ 固定した版      : $V → 入れる" { (Get-Rows (New-State $missing))[2].Text }
Test-Case '新しければ「下げない」で ⚠' "⚠ 固定した版      : $V → 入っている版の方が新しい (下げない)" { (Get-Rows (New-State $newer))[2].Text }
Test-Case '新しければ ※ で repo の版の上げ方を添える' '※ 入っている版の方が新しい (Google 日本語入力が自分で上がった?)。下げずに、Install-GoogleJapaneseInput.ps1 の -Version の既定値を 3.35.0.0 に上げ、bootstrap-windows-google-ime.sh の --dry-run と --import で設定を読み書きできるかを確かめてから commit する' { (Get-Rows (New-State $newer))[-1].Text }
Test-Case '版が読めなければ「不明」' '  入っている版    : 不明 (GoogleIMEJaConverter.exe の ProductVersion が読めない。C:\Program Files\Google\Google Japanese Input)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'unknown' }))[1].Text }
Test-Case '版が読めなければ ※ で確かめ方を添える' '※ 版が読めないので比べられない。winget list --id Google.JapaneseIME で入っている版を確かめる' { (Get-Rows (New-State @{ Installed = $null; Plan = 'unknown' }))[-1].Text }
Test-Case 'winget show が失敗したら最新版は不明' '  winget の最新版 : 不明 (winget show が失敗)' { (Get-Rows (New-State @{ Versions = @(); Latest = $null }))[3].Text }
Test-Case 'winget show が失敗したら、一覧についての ※/⚠ は出さない' 5 { (Get-Rows (New-State @{ Versions = @(); Latest = $null })).Count }
Test-Case '新しい版が winget にあれば ※ で知らせる' '※ winget に固定した版より新しい 3.35.6300.0 がある。上げるなら Install-GoogleJapaneseInput.ps1 の -Version の既定値を変える' { (Get-Rows (New-State @{ Versions = @('3.35.6300.0') + $versions; Latest = '3.35.6300.0' }))[5].Text }
Test-Case '新しい版が winget にあっても ⚠ にしない' 0 { @((Get-Rows (New-State @{ Versions = @('3.35.6300.0') + $versions; Latest = '3.35.6300.0' })) | Where-Object { $_.Warn }).Count }
Test-Case '固定した版が winget から消えても、入っていれば ※' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { (Get-Rows (New-State @{ Versions = @('3.35.6300.0', $Old); Latest = '3.35.6300.0' }))[5].Text }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @('3.35.6300.0', $Old); Latest = '3.35.6300.0' })))[5].Text }

# 本体の入口: Linux の pwsh には winget が無いので、終了コード 2 で止まる (成功 (0) に見せない)。
# 子の PATH は空にする (WSL の PATH には Windows の winget.exe があり、名前が違っても本物を呼ばないように)
function Invoke-Entry {
    param([string[]]$Arguments)
    $pwsh = (Get-Process -Id $PID).Path
    $savedPath = $env:PATH
    try {
        $env:PATH = ''
        $out = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-GoogleJapaneseInput.ps1') @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
    }
    [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}
Test-Case '入口: winget が無ければ終了コード 2' '2' { (Invoke-Entry -Arguments @('-Check')).Code }
Test-Case '入口: 書き間違えた -Version は例外を受け止めて終了コード 2' '2 True' { $r = Invoke-Entry -Arguments @('-Check', '-Version', 'not-a-version'); "$($r.Code) $($r.Text -like '*エラーで止まった*')" }

# ---------------------------------------------------------------------------
# Invoke-InstallGoogleJapaneseInput の流れ。Windows に触る関数を偽物に差し替えて、打つ winget の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する (pin は 'pin add' のように 2 語)。install と upgrade は入った状態にする
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = if ($Arguments[0] -eq 'pin') { "pin $($Arguments[1])" } else { $Arguments[0] }
    $script:Calls.Add($verb)
    $code = 0
    if ($script:Fail.ContainsKey($verb)) { $code = $script:Fail[$verb] }
    if (($code -eq 0) -and (@('install', 'upgrade') -contains $verb)) { $script:InstalledNow = $true }
    $lines = @()
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("Google 日本語入力 $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Test-GoogleImeInstalled { [bool]$script:InstalledNow }
function Get-GoogleImeState { param($PackageId, $Target) $script:States.Dequeue() }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-GoogleImeState が返す順 (揃える前と、揃えた後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [hashtable]$Fail = @{}, [switch]$Installed, [switch]$PinListed)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:InstalledNow = [bool]$Installed
    $script:PinListed = [bool]$PinListed
    $out = @(Invoke-InstallGoogleJapaneseInput -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$synced = New-State
Test-Case '-Check は winget を打たない' '1 []' { $r = Invoke-Flow -States @((New-State $thisPc)) -Check -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は入っていなければ 3' '3 []' { $r = Invoke-Flow -States @((New-State $missing)) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていれば上げない (pin も足さない)' '1 []' { $r = Invoke-Flow -States @((New-State $thisPc)) -IfMissing -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ install して pin を足す' '0 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '入れる前に UAC の確認が出ると出す' $true { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; $r.Text -like '*UAC の確認が出る*' }
Test-Case '揃っていれば何も打たない' '0 []' { $r = Invoke-Flow -States @($synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case 'pin だけ無ければ pin を足すだけ (UAC は出ない)' '0 [pin list pin add] False' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false }), $synced) -Installed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*UAC*')" }
Test-Case 'この PC: upgrade して pin を足す' '0 [upgrade pin list pin add]' { $r = Invoke-Flow -States @((New-State $thisPc), $synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '上げる前に、アプリを閉じるよう出す' $true { $r = Invoke-Flow -States @((New-State $thisPc), $synced) -Installed; $r.Text -like '*アプリをできるだけ閉じる*' }
Test-Case 'pin があるときは外してから上げ、足し直す' '0 [pin remove upgrade pin list pin add]' { $r = Invoke-Flow -States @((New-State $thisPcPinned), $synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '新しければ何も打たずに 1 (下げない)' '1 [] True' { $r = Invoke-Flow -States @((New-State $newer)) -Installed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*下げない*')" }
Test-Case '版が読めなければ何も打たずに 1' '1 []' { $r = Invoke-Flow -States @((New-State @{ Installed = $null; Plan = 'unknown' })) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '固定した版が winget に無ければ何も打たずに 1' '1 []' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @('3.35.6300.0'); Latest = '3.35.6300.0' }))) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちたら (UAC で断った) pin を足さずに 1' '1 [install pin list]' { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -IfMissing -Fail @{ install = 0x8A150011 }; "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちたら、打ち直し方を出す' $true { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -IfMissing -Fail @{ install = 0x8A150011 }; $r.Text -like '*Install-GoogleJapaneseInput を打ち直す*' }
Test-Case '上げても版が古いまま (再起動待ち) なら、再起動を案内して 1' '1 True' { $r = Invoke-Flow -States @((New-State $thisPc), (New-State $thisPcPinned)) -Installed; "$($r.Code) $($r.Text -like '*再起動してから*')" }

# -Check の締めの行 (最後の行) は、揃える経路が実際にすることを案内する
function Get-LastLine { param([string]$Text) @($Text -split "`n")[-1] }
Test-Case '-Check の締め: 揃っていれば「揃っている」' '揃っている' { $r = Invoke-Flow -States @($synced) -Check -Installed; Get-LastLine $r.Text }
Test-Case '-Check の締め: 版が読めなければ winget list を案内し、揃えるとは言わない' 'True False' { $r = Invoke-Flow -States @((New-State @{ Installed = $null; Plan = 'unknown' })) -Check -Installed; $l = Get-LastLine $r.Text; "$($l -like '*winget list*') $($l -like '*で揃える*')" }
Test-Case '-Check の締め: 固定した版が winget に無ければ -Version を変えるよう出す (入れるとは言わない)' 'True False' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @('3.35.6300.0'); Latest = '3.35.6300.0' }))) -Check; $l = Get-LastLine $r.Text; "$($l -like '*-Version を*') $($l -like '*で入れる*')" }
Test-Case '-Check の締め: pin だけ無ければ pin を足すと出し、UAC は出ないと言う' 'True True' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false })) -Check -Installed; $l = Get-LastLine $r.Text; "$($l -like '*pin*') $($l -like '*UAC の確認は出ない*')" }
Test-Case '-Check の締めは FE0F 付きの ⚠️ で始まる (95 が見分ける)' $true { $r = Invoke-Flow -States @((New-State $thisPc)) -Check -Installed; (Get-LastLine $r.Text).StartsWith("$([char]0x26A0)$([char]0xFE0F) ") }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
