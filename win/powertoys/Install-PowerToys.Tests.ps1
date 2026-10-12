# win/powertoys/Install-PowerToys.ps1 のうち、副作用の無い関数のテスト。Pester は使わない。
# winget やファイルに触る部分は、実機で -Check を打って確かめる (win/README.md の「PowerToys を入れる」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/powertoys/Install-PowerToys.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-PowerToys.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-PowerToys.ps1')

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

$Id = 'Microsoft.PowerToys'
$User = 'C:\Users\u\AppData\Local\PowerToys\PowerToys.exe'
$Machine = 'C:\Program Files\PowerToys\PowerToys.exe'

# Get-PowerToysExeCandidate: 置き場所の候補 (user スコープ、machine スコープの順)
Test-Case 'user スコープ、machine スコープの順' "$User $Machine" { Get-PowerToysExeCandidate -LocalAppData 'C:\Users\u\AppData\Local' -ProgramFiles 'C:\Program Files' }
Test-Case '末尾の \ は落とす' "$User $Machine" { Get-PowerToysExeCandidate -LocalAppData 'C:\Users\u\AppData\Local\' -ProgramFiles 'C:\Program Files\' }
Test-Case '空の値は飛ばす' $Machine { Get-PowerToysExeCandidate -LocalAppData $null -ProgramFiles 'C:\Program Files' }

# Find-PowerToysExe: 候補を前から見て、最初にあったもの
Test-Case 'user スコープにあればそれ (この PC)' $User { Find-PowerToysExe -Candidates @($User, $Machine) -Exists { param($p) $p -eq $User } }
Test-Case 'machine スコープにだけあればそれ' $Machine { Find-PowerToysExe -Candidates @($User, $Machine) -Exists { param($p) $p -eq $Machine } }
Test-Case '両方にあれば先の user スコープ' $User { Find-PowerToysExe -Candidates @($User, $Machine) -Exists { param($p) $true } }
Test-Case 'どちらにも無ければ空' '' { Find-PowerToysExe -Candidates @($User, $Machine) -Exists { param($p) $false } }

# Get-PowerToysInstallArguments: 入れる winget の引数 (user スコープ、版は名指ししない)
Test-Case 'user スコープで入れる引数' "install --id $Id --exact --source winget --scope user --silent --accept-source-agreements --disable-interactivity --accept-package-agreements" { (Get-PowerToysInstallArguments -PackageId $Id) -join ' ' }

# Get-PowerToysExitCode: 終了コード
Test-Case '入っていれば 0' 0 { Get-PowerToysExitCode -State ([pscustomobject]@{ Exe = $User; Version = '0.100.2.0' }) }
Test-Case '入っていなければ 3' 3 { Get-PowerToysExitCode -State ([pscustomobject]@{ Exe = $null; Version = $null }) }

# Format-PowerToysState: 状態の表の行
$installed = [pscustomobject]@{ Exe = $User; Version = '0.100.2.0' }
$missing = [pscustomobject]@{ Exe = $null; Version = $null }
function Get-Rows { param($State) @(Format-PowerToysState -State $State) }
Test-Case '見出しはパッケージ名' 'PowerToys (winget の Microsoft.PowerToys。版は固定しない)' { (Get-Rows $installed)[0].Text }
Test-Case '入っていれば場所と版の 3 行で、⚠ は無い' '3 0' { $r = Get-Rows $installed; "$($r.Count) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '入っている場所' "  入っている場所 : $User" { (Get-Rows $installed)[1].Text }
Test-Case '入っている版' '  入っている版   : 0.100.2.0' { (Get-Rows $installed)[2].Text }
Test-Case '版が読めなければ不明' '  入っている版   : 不明 (PowerToys.exe の ProductVersion が読めない)' { (Get-Rows ([pscustomobject]@{ Exe = $User; Version = '' }))[2].Text }
Test-Case '入っていなければ 2 行で、⚠ を付ける' '2 1' { $r = Get-Rows $missing; "$($r.Count) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '入っていなければ入れると出す' '⚠ 入っている場所 : 入っていない → user スコープで入れる' { (Get-Rows $missing)[1].Text }

# 本体の入口: Linux の pwsh には %LOCALAPPDATA% も %ProgramFiles% も無いので「入っていない」の 3 になる。
# -Check だけを流す (付けずに流すと winget を探しに行くため)。子の PATH は空にする
# (WSL の PATH には Windows の winget.exe があり、名前が違っても本物を呼ばないように)
Test-Case '入口: -Check は入っていなければ終了コード 3' '3 True' {
    $pwsh = (Get-Process -Id $PID).Path
    $savedPath = $env:PATH
    try {
        $env:PATH = ''
        $out = @(& $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-PowerToys.ps1') -Check 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
    }
    "$code $(($out -join "`n") -like '*入っていない*')"
}

# ---------------------------------------------------------------------------
# Invoke-InstallPowerToys の流れ。Windows に触る関数を偽物に差し替えて、打つ winget と、
# 失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
function Invoke-Winget {
    param([string[]]$Arguments)
    $script:Calls.Add($Arguments[0])
    [pscustomobject]@{ ExitCode = $script:WingetCode; Lines = @() }
}
function Get-PowerToysState { $script:States.Dequeue() }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-PowerToysState が返す順 (入れる前と、入れた後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [int]$WingetCode = 0)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:WingetCode = $WingetCode
    $out = @(Invoke-InstallPowerToys -Check:$Check 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

Test-Case '-Check は入っていれば 0 で、winget を打たない' '0 []' { $r = Invoke-Flow -States @($installed) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は入っていなければ 3 で、winget を打たない' '3 []' { $r = Invoke-Flow -States @($missing) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '入っていれば何も打たずに 0' '0 []' { $r = Invoke-Flow -States @($installed); "$($r.Code) [$($r.Calls)]" }
Test-Case '入っていなければ install して 0' '0 [install]' { $r = Invoke-Flow -States @($missing, $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちて入らなければ 1 で、打ち直し方を出す' '1 [install] True' { $r = Invoke-Flow -States @($missing, $missing) -WingetCode 1; "$($r.Code) [$($r.Calls)] $($r.Text -like '*Install-PowerToys を打ち直す*')" }
Test-Case 'winget が無ければ 2' '2 []' {
    Remove-Item -LiteralPath function:winget
    try {
        $r = Invoke-Flow -States @($missing)
    } finally {
        function script:winget { }
    }
    "$($r.Code) [$($r.Calls)]"
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
