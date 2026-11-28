# win/ntn/Install-Ntn.ps1 (ntn の表) のテスト。Pester は使わない。流れ・見張り・終了コードの決まりは共通の枠の試験
# (win/winget/WingetPortable.Tests.ps1) が確かめ、ここは ntn の表の値がそこへ正しく渡るかを確かめる。winget やプロセスに触る本物の部分は、
# 実機で -Check と本番を打って確かめる (win/README.md の「ntn」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/ntn/Install-Ntn.Tests.ps1
#
# ## 確かめること
#
#   - 表: パッケージ ID は Notion.ntn (版の知らせが読む $packageId の行)、ntn.exe は ntn-x86_64-pc-windows-msvc の下 (無ければ置き場所の下を
#     探す)。MSI は見ない。winget のパッケージは zip の中の portable なので、portable を名指しする
#   - ntn.exe --version の出力 (ntn <版>) から版を拾い、winget show --versions の版の行だけを新しい順に拾う
#   - PATH で引かれる ntn (winget の置き場所・WinGet\Links なら winget のもの。npm の global の ntn.cmd・cargo のものは other)
#   - 状態の表の見出しと行・締めの行 (WSL の bootstrap-windows-ntn.sh と runner が読む字)・昇格した PowerShell の締めの行
#   - 流れ: 入っていなければ入れて pin を足す。動いている ntn があれば何も変えずに止まる。install が落ちたら、打ち直し方を出す
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Ntn.ps1 の末尾)。共通の枠も clone の win\winget\ から読む
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

# ntn の表に、試験の置き場所を足して埋めたもの
function New-Tool {
    param([hashtable]$Change = @{})
    $t = Get-NtnTool
    $t.PackageDir = $Pkg
    $t.LinksDir = $Links
    foreach ($k in $Change.Keys) { $t[$k] = $Change[$k] }
    Complete-PortableTool -Tool $t
}
$T = New-Tool

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
$versions = @($V, $Older)

# 表
Test-Case 'パッケージ ID は $packageId の行 (版の知らせが読む)' $Id { $T.PackageId }
Test-Case '名前・関数・PATH で引く名前・README の節' 'ntn|Install-Ntn|ntn|ntn' { "$($T.Name)|$($T.Command)|$($T.CommandName)|$($T.Readme)" }
Test-Case 'ntn.exe は ntn-x86_64-pc-windows-msvc の下。無ければ置き場所の下を探す' 'ntn-x86_64-pc-windows-msvc\ntn.exe True ntn.exe' { "$($T.ExePath) $($T.ExeSearch) $($T.ExeName)" }
Test-Case 'MSI は見ない・portable を名指しする (manifest は zip の中の portable)' 'True portable' { "$($null -eq $T.Msi) $($T.InstallerType)" }

# ntn.exe --version の出力から版を拾う
function Get-Version { param([string[]]$Lines) Get-PortableVersionFromOutput -Lines $Lines -Pattern $T.VersionPattern }
Test-Case '"ntn <版>" から版を拾う' $Newer { Get-Version @("ntn $Newer") }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-Version @("  ntn $V`r") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-Version @('warning: something', "ntn $V") }
Test-Case '版の行が無ければ空' '' { Get-Version @('error: something went wrong') }
Test-Case 'Notion CLI の見出しの行は版と読まない' '' { Get-Version @('Notion CLI (Beta)') }

Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$Newer 0.23.29 $V $Older" { Get-WingetVersionList -Lines $show }
$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '入っている版の方が新しければ down (0.23.30 → 0.23.28)' 'down' { Get-PortableDirection -Versions $showVersions -Installed $Newer -Target $V }
Test-Case '入っている版が一覧に無ければ unknown' 'unknown' { Get-PortableDirection -Versions $showVersions -Installed '0.23.24' -Target $V }

# Test-WingetPinned: 2026-11-14 に、ある PC の winget pin list が出したもの (Notion.ntn の pin はまだ無い)
$pinsNow = @(
    'Name              Id                        Version     Source Pin type'
    '-----------------------------------------------------------------------'
    'Google 日本語入力 Google.JapaneseIME        3.34.6260.0 winget Pinning'
    'OpenSSH           Microsoft.OpenSSH.Preview 10.0.0.0    winget Pinning'
    'herdr             Herdr.Herdr               0.9.5       winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsNow -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsNow + @("ntn               $Id                $V     winget Pinning")) -PackageId $Id }

# winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版と portable を名指しして入れる' "install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan install -Version $V)[0] -join ' ' }
Test-Case 'change は uninstall → install' "uninstall $common|install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan change -Version $V | ForEach-Object { $_ -join ' ' }) -join '|' }
Test-Case '取得だけを確かめる winget download の引数 (portable を名指しする)' "download --id $Id --exact --source winget --version $V --installer-type portable --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -Tool $T -Version $V -Directory 'C:\tmp\dl') -join ' ' }

# PATH
$npm = 'C:\Users\u\AppData\Roaming\npm'
$existsNpm = { param($p) $p -in @("$npm\ntn.cmd", "$ExeDir\ntn.exe") }
Test-Case 'npm の global の ntn.cmd が前のディレクトリにあれば、それが引かれる' "$npm\ntn.cmd" { Resolve-PortableOnPath -PathValue "$npm;$ExeDir" -Names @('ntn.exe', 'ntn.cmd', 'ntn.bat', 'ntn.ps1') -Exists $existsNpm }
Test-Case 'winget の置き場所の ntn.exe なら package' 'package' { Get-PortablePathKind -Resolved "$ExeDir\ntn.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'WinGet\Links の symlink なら links' 'links' { Get-PortablePathKind -Resolved "$Links\ntn.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'npm の ntn.cmd は other' 'other' { Get-PortablePathKind -Resolved "$npm\ntn.cmd" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'ほかの場所なら other' 'other' { Get-PortablePathKind -Resolved 'C:\Users\u\.cargo\bin\ntn.exe' -ExeDir $ExeDir -LinksDir $Links }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Exe = "$ExeDir\ntn.exe"; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$ExeDir\ntn.exe"; PathKind = 'package'; BusyCount = 0; MsiExe = $null
        WingetVersion = [version]'1.30.310'; Elevated = $false; Route = 'direct'
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Exe = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 手で入れた新しい版 (ある PC の 2026-11-14 の今。pin も無い)
$handNewer = @{ Installed = $Newer; Plan = 'change'; Direction = 'down'; Pinned = $false; Versions = @($Newer, '0.23.29', $V, $Older); Latest = $Newer }

# 状態の表の行
function Get-Rows { param($State) @(Format-PortableState -Tool $T -State $State -Target $V) }
Test-Case '見出しはパッケージ名と置き場所 (bootstrap-windows-ntn.sh と runner がこの頭で見分ける)' "ntn (winget の Notion.ntn、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの PATH の行' '  PATH の ntn     : winget の portable のもの (置き場所)' { (Get-Rows (New-State))[5].Text }
Test-Case '版が読めないとき' '  入っている版    : 不明 (ntn.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH でほかの ntn が先なら、その場所を ⚠ で出す' '⚠ PATH の ntn     : C:\Users\u\.cargo\bin\ntn.exe (winget の portable のものではない)' { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\.cargo\bin\ntn.exe' }))[5].Text }
Test-Case 'PATH でほかの ntn が先なら、直し方を ※ で添える' '※ PATH のずれは Install-Ntn では直らない。C:\Users\u\.cargo\bin の ntn.exe を消すか、C:\Users\u\.cargo\bin をユーザーの PATH から外す (win/README.md の「ntn」)' { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\.cargo\bin\ntn.exe' }))[-1].Text }
Test-Case '置き場所が PATH に無ければ、足し直し方を ※ で添える' "※ ntn の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $Id の後に Install-Ntn で入れ直す" { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[-1].Text }
Test-Case '入れ替えが要るのに ntn が動いていれば ※ で添える' '※ ntn.exe が 1 個動いている。入れ替えるには、動いている ntn を終わらせる' { (Get-Rows (New-State ($handNewer + @{ BusyCount = 1 })))[-1].Text }

# 締めの行。WSL の bootstrap-windows-ntn.sh と Windows の runner がこの字で、入れるか・揃えるか・知らせるだけかを決め、昇格の行で直し方を選ぶ
function Get-Verdict { param($State) (@(Format-PortableVerdict -Tool $T -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '入っていなければ、Install-Ntn で入れると出す' '⚠️ ntn が入っていない → Install-Ntn で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版か pin の差があれば、Install-Ntn で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Ntn で揃える ⚠️' { Get-Verdict (New-State $handNewer) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の ntn が winget の portable のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = 'C:\X\ntn.exe' }) }
Test-Case '昇格した PowerShell で入れられなければ、昇格の 1 行だけ' '⚠️ 昇格した PowerShell では winget が ntn を入れない (winget 1.30 から) → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($missing + @{ Elevated = $true; Route = 'elevated' })) }

# Find-PortableExe: manifest の場所を先に見て、無ければ置き場所の下を探す
$findRoot = Join-Path ([IO.Path]::GetTempPath()) "install-ntn-tests-find-$PID"
$manifestExe = Join-Path (Join-Path $findRoot 'ntn-x86_64-pc-windows-msvc') 'ntn.exe'
$nested = Join-Path (Join-Path $findRoot 'ntn-other-layout') 'ntn.exe'
New-Item -ItemType File -Force -Path $nested | Out-Null
Test-Case 'zip の中の形が変わっても、置き場所の下の ntn.exe を見つける' $nested { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot }) }
New-Item -ItemType File -Force -Path $manifestExe | Out-Null
Test-Case 'manifest の場所の ntn.exe を先に見る' $manifestExe { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot }) }
Remove-Item -LiteralPath $findRoot -Recurse -Force

# ---------------------------------------------------------------------------
# 入口から流れまで (Start-WingetPortable に ntn の表を渡す)。Windows に触る関数を偽物に差し替えて、打つ winget の順を確かめる。
# ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-ntn-tests-$PID"
$FakeExe = Join-PortablePath -Root (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Notion.ntn_Microsoft.Winget.Source_8wekyb3d8bbwe') -Relative 'ntn-x86_64-pc-windows-msvc\ntn.exe'

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する。install は ntn.exe を置き、uninstall は消す。$script:FailInstall なら install を落とす
function Invoke-Winget {
    param([string[]]$Arguments)
    $script:Calls.Add($Arguments -join ' ')
    $code = 0
    if (($Arguments[0] -eq 'install') -and $script:FailInstall) { $code = 1 }
    if (($code -eq 0) -and ($Arguments[0] -eq 'install')) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    if ($Arguments[0] -eq 'uninstall') { Remove-Item -LiteralPath $FakeExe -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{ ExitCode = $code; Lines = @() }
}
function Get-PortableState { param($Tool, $Target) $script:States.Dequeue() }
function Get-PortableBusyProcess { param($Tool) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'ntn.exe api /v1/users/me' } }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [int]$Busy = 0, [switch]$ExeExists, [switch]$FailInstall)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Busy = @()
    if ($Busy -gt 0) { $script:Busy = @(1..$Busy | ForEach-Object { [pscustomobject]@{ Id = 1000 + $_ } }) }
    $script:FailInstall = [bool]$FailInstall
    Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
    if ($ExeExists) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    $out = @(Start-WingetPortable -Tool (Get-NtnTool) -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = @($script:Calls)
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$synced = New-State
Test-Case '-IfMissing は入っていなければ portable を入れ、manifest の場所の ntn.exe を見て pin を足す' "0|install $common --version $V --installer-type portable --accept-package-agreements|pin add --id $Id --exact --accept-source-agreements --disable-interactivity" { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code)|$($r.Calls[0])|$($r.Calls[-1])" }
Test-Case '動いている ntn があれば、winget を 1 つも打たずに止まり、PID とコマンドラインを出す' '1 0 True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) $($r.Calls.Count) $($r.Text -like '*1001*ntn.exe api*')" }
Test-Case 'install が落ちたら、WSL の setup でも runner でも入ると添えて打ち直し方を出す' 'True' { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -FailInstall; $r.Text -like '*ntn が入っていないことがある。ネットワークを確かめて Install-Ntn を打ち直す (dotfiles apply・setup --update でも入る)*' }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
