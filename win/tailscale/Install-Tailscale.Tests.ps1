# win/tailscale/Install-Tailscale.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget やファイルに触る部分は、実機で -Check と本番を打って確かめる (win/README.md の「Tailscale を入れる」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/tailscale/Install-Tailscale.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Tailscale.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-Tailscale.ps1')

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
    # 文化に依存しない比較 (Ordinal)。-ceq は U+FE0F のような無視できる文字を無視するので、締めの行の ⚠️ を見分けられない
    if ([string]::Equals($e, $a, [System.StringComparison]::Ordinal)) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

$Id = 'Tailscale.Tailscale'
$V = '1.104.5'
$Old = '1.98.10'
$New = '1.106.2'
$X64 = 'C:\Program Files\Tailscale\tailscale.exe'
$X86 = 'C:\Program Files (x86)\Tailscale\tailscale.exe'
$Custom = 'D:\Apps\Tailscale\tailscale.exe'

# 2026-11-17 の winget-pkgs の manifests/t/Tailscale/Tailscale の版を、winget show --versions の形 (新しい順) にしたもの
$show = @(
    'Found Tailscale [Tailscale.Tailscale]'
    'Version'
    '-------'
    '1.104.7'
    '1.104.6'
    '1.104.5'
    '1.104.4'
    '1.104.2'
    '1.104.1'
    '1.102.4'
    '1.102.3'
    '1.98.10'
)
# 上の版の行だけ (関数を通さずに書く。関数が無い段階でもテストが最後まで流れるように)
$versions = @($show[3..11])

# tailscale.exe version の出力 (1.104.5 の cmd/tailscale/cli/version.go と version/print.go の形。1 行目が版)
$versionOut = @(
    $V
    '  tailscale commit: 0123456789abcdef0123456789abcdef01234567'
    '  long version: 1.104.5-t0123456789-g0123456789'
    '  other commit: fedcba9876543210fedcba9876543210fedcba98'
    '  go version: go1.26.3 (tailscale/go 0123456789)'
)

# ConvertTo-TailscaleVersion: 版の文字列 (X.Y.Z) を [version] にする
Test-Case 'X.Y.Z の形を読む' $V { ConvertTo-TailscaleVersion -Text $V }
Test-Case '前後の空白を落とす' $V { ConvertTo-TailscaleVersion -Text "  $V `r" }
Test-Case '4 つ区切りは読まない (winget の版は 3 つ区切り)' '' { ConvertTo-TailscaleVersion -Text '1.104.5.0' }
Test-Case '長い版 (hash 付き) は読まない' '' { ConvertTo-TailscaleVersion -Text '1.104.5-t0123456789-g0123456789' }
Test-Case '空なら空' '' { ConvertTo-TailscaleVersion -Text '' }
Test-Case '$null なら空' '' { ConvertTo-TailscaleVersion -Text $null }
Test-Case '[version] に収まらない数なら空 (例外にしない)' '' { ConvertTo-TailscaleVersion -Text '99999999999.1.0' }
Test-Case '文字列ではなく数で比べる (98 < 104)' $true { (ConvertTo-TailscaleVersion -Text $Old) -lt (ConvertTo-TailscaleVersion -Text $V) }

# Get-TailscaleCliVersion: tailscale.exe version の出力から版を拾う
Test-Case '1 行目の版を拾う' $V { Get-TailscaleCliVersion -Lines $versionOut }
Test-Case '前に別の行があっても、版だけの行を拾う' $V { Get-TailscaleCliVersion -Lines (@('Warning: something') + $versionOut) }
Test-Case '字下げした行 (long version など) の版は拾わない' '' { Get-TailscaleCliVersion -Lines @('  long version: 1.104.5-t0123456789-g0123456789') }
Test-Case '版の行が無ければ空' '' { Get-TailscaleCliVersion -Lines @('tailscale: command failed') }
Test-Case '出力が空なら空' '' { Get-TailscaleCliVersion -Lines @() }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを上から順に拾う (見出し・区切りは拾わない)' ($versions -join ' ') { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }

# Get-TailscaleExeCandidates: 探す場所 (Program Files の Tailscale と、PATH で引いた tailscale.exe)
Test-Case '64 ビットと x86 の 2 か所 (同じ値は 1 つにする)' "$X64 $X86" { Get-TailscaleExeCandidates -Roots @('C:\Program Files', 'C:\Program Files', 'C:\Program Files (x86)') }
Test-Case '空の値は飛ばし、末尾の \ は落とす' $X64 { Get-TailscaleExeCandidates -Roots @($null, '', 'C:\Program Files\') }
Test-Case '大文字小文字だけ違う重複も 1 つにする' $X64 { Get-TailscaleExeCandidates -Roots @('C:\Program Files', 'C:\PROGRAM FILES') }
Test-Case 'PATH で引いたものを後ろに足す (別の置き場所に入れたとき)' "$X64 $Custom" { Get-TailscaleExeCandidates -Roots @('C:\Program Files') -OnPath $Custom }
Test-Case 'PATH で引いたものが Program Files のものなら足さない' $X64 { Get-TailscaleExeCandidates -Roots @('C:\Program Files') -OnPath 'c:\program files\tailscale\TAILSCALE.EXE' }

# Select-TailscaleExe: 見つかったもの (Path と、tailscale version で読んだ版の文字列 Text の組) から 1 つ選ぶ
$onX86 = [pscustomobject]@{ Path = $X86; Text = $Old }
$onX64 = [pscustomobject]@{ Path = $X64; Text = $V }
$broken = [pscustomobject]@{ Path = $X64; Text = '' }
Test-Case '1 つも無ければ空' '' { Select-TailscaleExe -Candidates @() }
Test-Case '1 つならそれ' "$X64 $V" { $c = Select-TailscaleExe -Candidates @($onX64); "$($c.Path) $($c.Version)" }
Test-Case '2 か所にあれば版の新しい方' "$X64 $V" { $c = Select-TailscaleExe -Candidates @($onX86, $onX64); "$($c.Path) $($c.Version)" }
Test-Case '版が読めないものより、読めるものを選ぶ' "$X86 $Old" { $c = Select-TailscaleExe -Candidates @($broken, $onX86); "$($c.Path) $($c.Version)" }
Test-Case '版が読めるものが無ければ、最初のもので版は空' "$X64 " { $c = Select-TailscaleExe -Candidates @($broken); "$($c.Path) $($c.Version)" }

# Get-TailscalePlan: することを決める ([version] で比べる)
Test-Case '入っていなければ install' 'install' { Get-TailscalePlan -Exists $false -Installed $null -Target $V }
Test-Case '古ければ upgrade' 'upgrade' { Get-TailscalePlan -Exists $true -Installed $Old -Target $V }
Test-Case '新しければ newer (自動更新で上がった。下げない)' 'newer' { Get-TailscalePlan -Exists $true -Installed $New -Target $V }
Test-Case '同じなら none' 'none' { Get-TailscalePlan -Exists $true -Installed $V -Target $V }
Test-Case 'あるのに版が読めなければ unknown' 'unknown' { Get-TailscalePlan -Exists $true -Installed $null -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか
$pinsOpenSsh = @(
    'Name    Id                        Version  Source Pin type'
    '----------------------------------------------------------'
    'OpenSSH Microsoft.OpenSSH.Preview 10.0.0.0 winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsOpenSsh -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsOpenSsh + @("Tailscale $Id $V winget Pinning")) -PackageId $Id }
Test-Case 'Id の前方一致では True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id)2 $V winget Pinning") -PackageId $Id }

# Get-WingetCommands: plan ごとに打つ winget の引数
$installArgs = "install --id $Id --exact --source winget --version $V --installer-type wix --accept-source-agreements --accept-package-agreements --disable-interactivity"
$upgradeArgs = "upgrade --id $Id --exact --source winget --version $V --accept-source-agreements --accept-package-agreements --disable-interactivity --include-pinned"
Test-Case 'install は版と MSI (wix) を名指しして入れる' $installArgs { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'upgrade は版を名指しして上げ、自分の pin を越える (installer は入っている形に合わせる)' $upgradeArgs { @(Get-WingetCommands -Plan upgrade -PackageId $Id -Version $V)[0] -join ' ' }
# per-machine の MSI は、管理者でない PowerShell から quiet (--silent) で流すと UAC が出ずに落ちる (gh で Error 1925)。
# --silent を付けず、winget の既定 (MSI なら /passive) で UAC を出させる
Test-Case 'install にも upgrade にも --silent を付けない' 'False False' { "$(@(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -contains '--silent') $(@(Get-WingetCommands -Plan upgrade -PackageId $Id -Version $V)[0] -contains '--silent')" }
# 版を名指しした upgrade は、--include-pinned が無いと、この script が足した pin (Pinning) に止められる (0x8A150068)。
# install は --include-pinned を受け付けない
Test-Case 'install には --include-pinned を付けない' 'False' { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -contains '--include-pinned' }
Test-Case 'install と upgrade は 1 本ずつ' '1 1' { "$(@(Get-WingetCommands -Plan install -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan upgrade -PackageId $Id -Version $V).Count)" }
Test-Case 'none・newer・unknown なら打たない' '0 0 0' { "$(@(Get-WingetCommands -Plan none -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan newer -PackageId $Id -Version $V).Count) $(@(Get-WingetCommands -Plan unknown -PackageId $Id -Version $V).Count)" }

# Get-WingetPinnedHint: winget が pin に止められて落ちた (0x8A150068) ときだけ、pin の見方と外し方を添える
Test-Case 'pin に止められたら、pin の種類の見方と外し方を出す' 'True True' {
    $h = @(Get-WingetPinnedHint -ExitCode -1978335128 -PackageId $Id)
    "$($h[0].Contains("winget pin list --id $Id --exact")) $($h[0].Contains("winget pin remove --id $Id --exact"))"
}
Test-Case 'ほかの終了コードなら何も添えない' '0' { @(Get-WingetPinnedHint -ExitCode 1 -PackageId $Id).Count }

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
$older = @{ Installed = [version]$Old; Plan = 'upgrade'; Pinned = $false }
$olderPinned = @{ Installed = [version]$Old; Plan = 'upgrade'; Pinned = $true }
$newer = @{ Installed = [version]$New; Plan = 'newer' }
$unknown = @{ Installed = $null; Plan = 'unknown' }

# Get-TailscaleExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-TailscaleExitCode -State (New-State) }
Test-Case '新しくても pin があれば 0 (Tailscale の自動更新で上がった。⚠ にしない)' 0 { Get-TailscaleExitCode -State (New-State $newer) }
Test-Case '新しくても pin が無ければ 1' 1 { Get-TailscaleExitCode -State (New-State ($newer + @{ Pinned = $false })) }
Test-Case 'pin が無ければ 1' 1 { Get-TailscaleExitCode -State (New-State @{ Pinned = $false }) }
Test-Case '古ければ 1' 1 { Get-TailscaleExitCode -State (New-State $olderPinned) }
Test-Case '版が読めなければ 1' 1 { Get-TailscaleExitCode -State (New-State $unknown) }
Test-Case '入っていなければ 3' 3 { Get-TailscaleExitCode -State (New-State $missing) }

# Get-TailscaleApplyBlocker: 揃える前に止める理由
Test-Case '入れられるなら止めない' '' { Get-TailscaleApplyBlocker -Plan install -Versions $versions -Target $V }
Test-Case '上げられるなら止めない' '' { Get-TailscaleApplyBlocker -Plan upgrade -Versions $versions -Target $V }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-TailscaleApplyBlocker -Plan upgrade -Versions $versions -Target '1.99.0' }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-TailscaleApplyBlocker -Plan install -Versions @() -Target $V }
Test-Case '新しくても止めない (pin を足すだけ)' '' { Get-TailscaleApplyBlocker -Plan newer -Versions $versions -Target $V }
Test-Case '版が読めなければ unknown で止める' 'unknown' { Get-TailscaleApplyBlocker -Plan unknown -Versions $versions -Target $V }
Test-Case 'pin を足すだけなら止めない' '' { Get-TailscaleApplyBlocker -Plan none -Versions @() -Target 'x' }

# Format-TailscaleState: 状態の表の行
function Get-Rows { param($State) @(Format-TailscaleState -State $State -Target $V) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていて winget の最新も同じなら表の 5 行だけ' 5 { (Get-Rows (New-State @{ Versions = @($V, $Old); Latest = $V })).Count }
Test-Case '見出しはパッケージ名' 'Tailscale (winget の Tailscale.Tailscale)' { (Get-Rows (New-State))[0].Text }
Test-Case '入っている版と置き場所' "  入っている版    : $V (C:\Program Files\Tailscale)" { (Get-Rows (New-State))[1].Text }
Test-Case '揃っているときの版の行' "  固定した版      : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case '入っていなければ「入っていない」' '  入っている版    : 入っていない' { (Get-Rows (New-State $missing))[1].Text }
Test-Case '入っていなければ「入れる」で ⚠' "⚠ 固定した版      : $V → 入れる" { (Get-Rows (New-State $missing))[2].Text }
Test-Case '古ければ「上げる」で ⚠' "⚠ 固定した版      : $V → 上げる" { (Get-Rows (New-State $older))[2].Text }
Test-Case 'pin が無ければ ⚠' '⚠ winget pin      : 無し → 足す' { (Get-Rows (New-State $older))[4].Text }
Test-Case '新しければ「下げない」で、⚠ にしない' "  固定した版      : $V → 入っている版の方が新しい (下げない)" { (Get-Rows (New-State $newer))[2].Text }
Test-Case '新しくて pin があれば ⚠ の行は無い' 0 { @((Get-Rows (New-State $newer)) | Where-Object { $_.Warn }).Count }
Test-Case '新しければ ※ で自動更新のことを添える' "※ 入っている版の方が新しい (Tailscale の自動更新で上がった?)。下げない。固定した版は、新しく入れるときの版 (自動更新の切り替えは Tailscale のタスクトレイの Preferences → Automatically install updates)" { (Get-Rows (New-State $newer))[-1].Text }
Test-Case '版が読めなければ「不明」' '  入っている版    : 不明 (tailscale.exe version が読めない。C:\Program Files\Tailscale)' { (Get-Rows (New-State $unknown))[1].Text }
Test-Case '版が読めなければ ⚠' "⚠ 固定した版      : $V → 比べられない" { (Get-Rows (New-State $unknown))[2].Text }
Test-Case '版が読めなければ ※ で確かめ方を添える' '※ 版が読めないので比べられない。winget list --id Tailscale.Tailscale で入っている版を確かめる' { (Get-Rows (New-State $unknown))[-1].Text }
Test-Case 'winget show が失敗したら最新版は不明' '  winget の最新版 : 不明 (winget show が失敗)' { (Get-Rows (New-State @{ Versions = @(); Latest = $null }))[3].Text }
Test-Case 'winget show が失敗したら、一覧についての ※/⚠ は出さない' 5 { (Get-Rows (New-State @{ Versions = @(); Latest = $null })).Count }
Test-Case '新しい版が winget にあれば ※ で知らせる' '※ winget に固定した版より新しい 1.104.7 がある。上げるなら Install-Tailscale.ps1 の -Version の既定値を変える (入っている Tailscale は、自動更新が有効なら自分で上がる)' { (Get-Rows (New-State))[5].Text }
Test-Case '新しい版が winget にあっても ⚠ にしない' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '固定した版が winget から消えても、入っていれば ※' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { (Get-Rows (New-State @{ Versions = @('1.104.7', $Old); Latest = '1.104.7' }))[5].Text }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @('1.104.7', $Old); Latest = '1.104.7' })))[5].Text }

# 本体の入口: Linux の pwsh には winget が無いので、終了コード 2 で止まる (成功 (0) に見せない)。
# 子の PATH は空にする (WSL の PATH には Windows の winget.exe があり、名前が違っても本物を呼ばないように)
function Invoke-Entry {
    param([string[]]$Arguments)
    $pwsh = (Get-Process -Id $PID).Path
    $savedPath = $env:PATH
    try {
        $env:PATH = ''
        $out = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-Tailscale.ps1') @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
    }
    [pscustomobject]@{ Code = $code; Text = ($out -join "`n") }
}
Test-Case '入口: winget が無ければ終了コード 2' '2' { (Invoke-Entry -Arguments @('-Check')).Code }
Test-Case '入口: 書き間違えた -Version は例外を受け止めて終了コード 2' '2 True' { $r = Invoke-Entry -Arguments @('-Check', '-Version', 'not-a-version'); "$($r.Code) $($r.Text -like '*エラーで止まった*')" }

# ---------------------------------------------------------------------------
# Invoke-InstallTailscale の流れ。Windows に触る関数を偽物に差し替えて、打つ winget の順と、
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
    # pin の持ち方は winget と同じにする: 外せば無くなり、足せば付く。版を名指しした upgrade は、--include-pinned が無ければ
    # 付いている pin (Pinning) に止められる (0x8A150068)
    if (($code -eq 0) -and ($verb -eq 'pin remove')) { $script:PinnedNow = $false }
    if (($code -eq 0) -and ($verb -eq 'pin add')) { $script:PinnedNow = $true }
    if (($code -eq 0) -and ($verb -eq 'upgrade') -and $script:PinnedNow -and ($Arguments -notcontains '--include-pinned')) { $code = -1978335128 }
    if (($code -eq 0) -and (@('install', 'upgrade') -contains $verb)) { $script:InstalledNow = $true }
    $lines = @()
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("Tailscale $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Test-TailscaleInstalled { [bool]$script:InstalledNow }
function Get-TailscaleState { param($PackageId, $Target) $script:States.Dequeue() }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-TailscaleState が返す順 (揃える前と、揃えた後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [hashtable]$Fail = @{}, [switch]$Installed, [switch]$PinListed)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:InstalledNow = [bool]$Installed
    $script:PinListed = [bool]$PinListed
    # winget の pin の持ち方の初め (偽の Invoke-Winget が upgrade を止めるかに使う)。揃える前の状態の Pinned から取る
    $script:PinnedNow = [bool]$States[0].Pinned
    $out = @(Invoke-InstallTailscale -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$synced = New-State
Test-Case '-Check は winget を打たない' '1 []' { $r = Invoke-Flow -States @((New-State $older)) -Check -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は入っていなければ 3' '3 []' { $r = Invoke-Flow -States @((New-State $missing)) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は新しくても pin があれば 0' '0 []' { $r = Invoke-Flow -States @((New-State $newer)) -Check -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていれば上げない (pin も足さない)' '1 []' { $r = Invoke-Flow -States @((New-State $older)) -IfMissing -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ install して pin を足す' '0 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '入れる前に UAC の確認が出ると出す' $true { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; $r.Text -like '*UAC の確認が出る*' }
Test-Case '入れた後に、ログインは手でするよう出す' $true { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; $r.Text -like '*ログイン*' }
Test-Case '揃っていれば何も打たない' '0 []' { $r = Invoke-Flow -States @($synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '新しくて pin があれば何も打たない (下げない)' '0 []' { $r = Invoke-Flow -States @((New-State $newer)) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '新しくて pin が無ければ pin を足すだけ (下げない。UAC は出ない)' '0 [pin list pin add] False' { $r = Invoke-Flow -States @((New-State ($newer + @{ Pinned = $false })), (New-State $newer)) -Installed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*UAC*')" }
Test-Case 'pin だけ無ければ pin を足すだけ (UAC は出ない)' '0 [pin list pin add] False' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false }), $synced) -Installed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*UAC*')" }
Test-Case '古ければ upgrade して pin を足す' '0 [upgrade pin list pin add]' { $r = Invoke-Flow -States @((New-State $older), $synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '上げる前に、接続が少しの間切れると出す' $true { $r = Invoke-Flow -States @((New-State $older), $synced) -Installed; $r.Text -like '*接続が少しの間切れる*' }
Test-Case 'pin があるときは外してから上げ、足し直す' '0 [pin remove upgrade pin list pin add]' { $r = Invoke-Flow -States @((New-State $olderPinned), $synced) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case 'pin を外せなくても、上げる upgrade は自分の pin に止められない' '0 [pin remove upgrade pin list] False' {
    $r = Invoke-Flow -States @((New-State $olderPinned), $synced) -Installed -PinListed -Fail @{ 'pin remove' = 1 }
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*winget が失敗した*')"
}
Test-Case 'upgrade が pin に止められたら (Blocking の pin など)、pin の見方と外し方を出す' 'True' {
    $r = Invoke-Flow -States @((New-State $olderPinned), (New-State $olderPinned)) -Installed -PinListed -Fail @{ upgrade = -1978335128 }
    $r.Text -like "*winget pin list --id $Id --exact*"
}
Test-Case '版が読めなければ何も打たずに 1' '1 []' { $r = Invoke-Flow -States @((New-State $unknown)) -Installed; "$($r.Code) [$($r.Calls)]" }
Test-Case '固定した版が winget に無ければ何も打たずに 1' '1 []' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @('1.104.7'); Latest = '1.104.7' }))) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちたら (UAC で断った) pin を足さずに 1' '1 [install pin list]' { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -IfMissing -Fail @{ install = 0x8A150011 }; "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちたら、打ち直し方を出す' $true { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -IfMissing -Fail @{ install = 0x8A150011 }; $r.Text -like '*Install-Tailscale を打ち直す*' }

# -Check の締めの行 (最後の行) は、揃える経路が実際にすることを案内する
function Get-LastLine { param([string]$Text) @($Text -split "`n")[-1] }
Test-Case '-Check の締め: 揃っていれば「揃っている」' '揃っている' { $r = Invoke-Flow -States @($synced) -Check -Installed; Get-LastLine $r.Text }
Test-Case '-Check の締め: 新しければ下げないと添える' '揃っている (入っている版の方が新しい。下げない)' { $r = Invoke-Flow -States @((New-State $newer)) -Check -Installed; Get-LastLine $r.Text }
Test-Case '-Check の締め: 入っていなければ Install-Tailscale で入れると出す (UAC)' '⚠️ Tailscale が入っていない → Install-Tailscale で入れる (UAC の確認が出る) ⚠️' { $r = Invoke-Flow -States @((New-State $missing)) -Check; Get-LastLine $r.Text }
Test-Case '-Check の締め: 古ければ Install-Tailscale で揃えると出し、接続が切れることを添える' 'True True' { $r = Invoke-Flow -States @((New-State $olderPinned)) -Check -Installed; $l = Get-LastLine $r.Text; "$($l -like '*→ Install-Tailscale で揃える*') $($l -like '*接続が少しの間切れる*')" }
Test-Case '-Check の締め: 版が読めなければ winget list を案内し、揃えるとは言わない' 'True False' { $r = Invoke-Flow -States @((New-State $unknown)) -Check -Installed; $l = Get-LastLine $r.Text; "$($l -like '*winget list*') $($l -like '*で揃える*')" }
Test-Case '-Check の締め: 固定した版が winget に無ければ -Version を変えるよう出す (入れるとは言わない)' 'True False' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @('1.104.7'); Latest = '1.104.7' }))) -Check; $l = Get-LastLine $r.Text; "$($l -like '*-Version を*') $($l -like '*で入れる*')" }
Test-Case '-Check の締め: pin だけ無ければ pin を足すと出し、UAC は出ないと言う' 'True True' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false })) -Check -Installed; $l = Get-LastLine $r.Text; "$($l -like '*pin*') $($l -like '*UAC の確認は出ない*')" }
Test-Case '-Check の締めは FE0F 付きの ⚠️ で始まる (96 が見分ける)' $true { $r = Invoke-Flow -States @((New-State $older)) -Check -Installed; (Get-LastLine $r.Text).StartsWith("$([char]0x26A0)$([char]0xFE0F) ", [System.StringComparison]::Ordinal) }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
