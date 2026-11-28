# win/fzf/Install-Fzf.ps1 (fzf の表) のテスト。Pester は使わない。流れ・見張り・終了コードの決まりは共通の枠の試験
# (win/winget/WingetPortable.Tests.ps1) が確かめ、ここは fzf の表の値がそこへ正しく渡るかを確かめる。winget やプロセスに触る本物の部分は、
# 実機で -Check と本番を打って確かめる (win/README.md の「ghq・fzf」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/fzf/Install-Fzf.Tests.ps1
#
# ## 確かめること
#
#   - 表: パッケージ ID は junegunn.fzf (版の知らせが読む $packageId の行)、fzf.exe は置き場所の直下 (無ければ置き場所の下を探す)
#   - fzf.exe --version の出力 (<版> (<commit>)) から版を拾い、winget show --versions の版の行だけを新しい順に拾う
#   - install には --installer-type portable を付け (付けないと winget は MSI を選ぶ)、change は uninstall → install。取得だけを確かめる
#     winget download も portable を名指しする
#   - PATH で引かれる fzf (winget の置き場所の直下・WinGet\Links なら winget の portable のもの。MSI の fzf もほかも other)
#   - MSI の fzf (%ProgramFiles%\fzf\bin\fzf.exe) があれば、終了コードは 1 (portable が入っていなくても 3 にしない)・表に ⚠ と外し方の ※・
#     締めの行は MSI の 1 行だけ (runner が読む字「MSI の fzf (machine スコープ) が入っている」)
#   - 状態の表の見出しと行・締めの行 (runner が読む字)・昇格した PowerShell の締めの行 (runner が読む字)
#   - 流れ: 入っていなければ入れて pin を足す。入れ替えは取得を確かめてから外して入れる。動いている fzf があれば・MSI の fzf があれば、
#     何も変えずに止まる
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Fzf.ps1 の末尾)。共通の枠も clone の win\winget\ から読む
. (Join-Path $PSScriptRoot 'Install-Fzf.ps1')

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

$Id = 'junegunn.fzf'
$V = '0.75.0'
$Older = '0.74.5'
$Newer = '0.76.0'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\junegunn.fzf_Microsoft.Winget.Source_8wekyb3d8bbwe'
# fzf.exe は置き場所の直下 (manifest の RelativeFilePath が fzf.exe)。winget が PATH に足すのも置き場所そのもの
$ExeDir = $Pkg
$Links = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links'
$Msi = 'C:\Program Files\fzf\bin\fzf.exe'

# fzf の表に、試験の置き場所を足して埋めたもの
function New-Tool {
    param([hashtable]$Change = @{})
    $t = Get-FzfTool
    $t.PackageDir = $Pkg
    $t.LinksDir = $Links
    foreach ($k in $Change.Keys) { $t[$k] = $Change[$k] }
    Complete-PortableTool -Tool $t
}
$T = New-Tool

# 2026-11-23 に winget-pkgs にあった junegunn.fzf の版の新しい方 (winget show --versions の並び) の頭に、まだ無い新しい版を足したもの
$show = @(
    'Found fzf [junegunn.fzf]'
    'Version'
    '-------'
    $Newer
    '0.75.0'
    '0.74.5'
    '0.74.4'
)
# 版の一覧 (新しい順)。上げ下げを確かめるため、固定した版より古い版も並べる
$versions = @($V, $Older)

# 表
Test-Case 'パッケージ ID は $packageId の行 (版の知らせが読む)' $Id { $T.PackageId }
Test-Case '名前・関数・PATH で引く名前・README の節' 'fzf|Install-Fzf|fzf|ghq・fzf' { "$($T.Name)|$($T.Command)|$($T.CommandName)|$($T.Readme)" }
Test-Case 'fzf.exe は置き場所の直下。無ければ置き場所の下を探す' 'fzf.exe True fzf.exe' { "$($T.ExePath) $($T.ExeSearch) $($T.ExeName)" }
Test-Case 'MSI の fzf は %ProgramFiles%\fzf\bin\fzf.exe を見る' 'fzf\bin\fzf.exe' { $T.Msi }
Test-Case 'portable を名指しする (付けないと winget は MSI を選ぶ)' 'portable' { $T.InstallerType }

# fzf.exe --version の出力から版を拾う
function Get-Version { param([string[]]$Lines) Get-PortableVersionFromOutput -Lines $Lines -Pattern $T.VersionPattern }
Test-Case '"<版> (<commit>)" から版を拾う' $V { Get-Version @("$V (7c3a2e9)") }
Test-Case 'nixpkgs の build の形 ("<版> (refs/tags/v<版>)") からも拾う' $Older { Get-Version @("$Older (refs/tags/v$Older)") }
Test-Case 'commit の無い出力からも拾う' $Newer { Get-Version @($Newer) }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-Version @("  $V (7c3a2e9)`r") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-Version @('warning: something', "$V (7c3a2e9)") }
Test-Case '版の行が無ければ空' '' { Get-Version @('error: something went wrong') }

Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$Newer 0.75.0 0.74.5 0.74.4" { Get-WingetVersionList -Lines $show }
$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '入っている版が一覧に無ければ unknown (winget に無い 0.66.1)' 'unknown' { Get-PortableDirection -Versions $showVersions -Installed '0.66.1' -Target $V }

# winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版と portable を名指しして入れる (MSI を選ばせない)' "install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan install -Version $V)[0] -join ' ' }
Test-Case 'change は uninstall → portable を名指しした install' "uninstall $common|install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan change -Version $V | ForEach-Object { $_ -join ' ' }) -join '|' }
Test-Case '取得だけを確かめる winget download の引数 (portable を名指しする)' "download --id $Id --exact --source winget --version $V --installer-type portable --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -Tool $T -Version $V -Directory 'C:\tmp\dl') -join ' ' }

# PATH
# マシンの PATH (MSI が足す %ProgramFiles%\fzf\bin) はユーザーの PATH (portable の置き場所) より前に並ぶ
$existsMsi = { param($p) $p -in @($Msi, "$ExeDir\fzf.exe") }
Test-Case 'MSI の fzf がマシンの PATH にあれば、portable より先に引かれる' $Msi { Resolve-PortableOnPath -PathValue "C:\Program Files\fzf\bin;$ExeDir" -Names @('fzf.exe', 'fzf.cmd', 'fzf.bat', 'fzf.ps1') -Exists $existsMsi }
Test-Case 'winget の置き場所の fzf.exe なら package' 'package' { Get-PortablePathKind -Resolved "$ExeDir\fzf.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'WinGet\Links の symlink なら links' 'links' { Get-PortablePathKind -Resolved "$Links\fzf.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'MSI の fzf は other' 'other' { Get-PortablePathKind -Resolved $Msi -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'scoop の fzf は other' 'other' { Get-PortablePathKind -Resolved 'C:\Users\u\scoop\shims\fzf.exe' -ExeDir $ExeDir -LinksDir $Links }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Exe = "$ExeDir\fzf.exe"; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$ExeDir\fzf.exe"; PathKind = 'package'; BusyCount = 0; MsiExe = $null
        WingetVersion = [version]'1.30.310'; Elevated = $false; Route = 'direct'
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Exe = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 手で入れた新しい版 (pin も無い)
$handNewer = @{ Installed = $Newer; Plan = 'change'; Direction = 'down'; Pinned = $false; Versions = @($Newer, $V, $Older); Latest = $Newer }
# winget install junegunn.fzf を手で打って MSI が入り、portable は入っていない (マシンの PATH の MSI の fzf が引かれる)
$msiOnly = $missing.Clone()
$msiOnly.PathKind = 'other'
$msiOnly.PathResolved = $Msi
$msiOnly.MsiExe = $Msi

# 終了コード
Test-Case '揃っていれば 0・入っていなければ 3・版が違えば 1' '0 3 1' { "$(Get-PortableExitCode -Tool $T -State (New-State)) $(Get-PortableExitCode -Tool $T -State (New-State $missing)) $(Get-PortableExitCode -Tool $T -State (New-State $handNewer))" }
Test-Case 'MSI の fzf があれば、portable が入っていなくても 1 (runner に入れにいかせない)' 1 { Get-PortableExitCode -Tool $T -State (New-State $msiOnly) }

# 状態の表の行
function Get-Rows { param($State) @(Format-PortableState -Tool $T -State $State -Target $V) }
Test-Case '見出しはパッケージ名と置き場所 (runner の ps1.rs がこの頭で見分ける)' "fzf (winget の junegunn.fzf、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの PATH の行' '  PATH の fzf     : winget の portable のもの (置き場所)' { (Get-Rows (New-State))[5].Text }
Test-Case '版が読めないとき' '  入っている版    : 不明 (fzf.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH でほかの fzf が先なら、直し方を ※ で添える' '※ PATH のずれは Install-Fzf では直らない。C:\Users\u\scoop\shims の fzf.exe を消すか、C:\Users\u\scoop\shims をユーザーの PATH から外す (win/README.md の「ghq・fzf」)' { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\scoop\shims\fzf.exe' }))[-1].Text }
Test-Case '置き場所が PATH に無ければ、足し直し方を ※ で添える' "※ fzf の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $Id の後に Install-Fzf で入れ直す" { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[-1].Text }
Test-Case '新しい版があれば ※ で知らせる' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Fzf.ps1 の -Version の既定値を変える" { (Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }))[6].Text }
Test-Case '入れ替えが要るのに fzf が動いていれば ※ で添える' '※ fzf.exe が 1 個動いている。入れ替えるには、動いている fzf (cdrepo の選ぶ画面など) を終わらせる' { (Get-Rows (New-State ($handNewer + @{ BusyCount = 1 })))[-1].Text }
Test-Case 'MSI の fzf があれば、⚠ の行で場所を出す' "⚠ MSI の fzf (machine スコープ。winget の既定の installer) が入っている: $Msi" { (Get-Rows (New-State $msiOnly))[6].Text }
Test-Case 'MSI の fzf があれば、外し方を ※ で添える (PATH のずれの ※ は出さない)' "※ portable と二重にしないため、MSI があるうちは Install-Fzf は何も入れない。PowerShell で winget uninstall --id $Id --exact --scope machine を打って MSI を外し (UAC の確認が出る)、Install-Fzf を打ち直す (win/README.md の「ghq・fzf」) 8" { $r = Get-Rows (New-State $msiOnly); "$($r[-1].Text) $($r.Count)" }

# 締めの行。Windows の runner (win/runner/src/steps/ps1.rs) がこの字で、入れるか・揃えるか・知らせるだけかを決め、MSI と昇格の行で直し方を選ぶ
function Get-Verdict { param($State) (@(Format-PortableVerdict -Tool $T -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '入っていなければ、Install-Fzf で入れると出す' '⚠️ fzf が入っていない → Install-Fzf で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版か pin の差があれば、Install-Fzf で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Fzf で揃える ⚠️' { Get-Verdict (New-State $handNewer) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の fzf が winget の portable のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = 'C:\X\fzf.exe' }) }
Test-Case 'MSI の fzf があれば、MSI の 1 行だけ (入れる・揃えるとは言わない)' '⚠️ MSI の fzf (machine スコープ) が入っている → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($handNewer + @{ MsiExe = $Msi })) }
Test-Case '昇格した PowerShell で入れられなければ、昇格の 1 行だけ' '⚠️ 昇格した PowerShell では winget が fzf を入れない (winget 1.30 から) → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($missing + @{ Elevated = $true; Route = 'elevated' })) }

# Find-PortableExe: manifest の場所 (置き場所の直下) を先に見て、無ければ置き場所の下を探す
$findRoot = Join-Path ([IO.Path]::GetTempPath()) "install-fzf-tests-find-$PID"
$top = Join-Path $findRoot 'fzf.exe'
$nested = Join-Path (Join-Path $findRoot 'fzf-other-layout') 'fzf.exe'
New-Item -ItemType File -Force -Path $nested | Out-Null
Test-Case 'zip の中の形が変わっても、置き場所の下の fzf.exe を見つける' $nested { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot }) }
New-Item -ItemType File -Force -Path $top | Out-Null
Test-Case '置き場所の直下の fzf.exe を先に見る' $top { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot }) }
Remove-Item -LiteralPath $findRoot -Recurse -Force

# Find-PortableMsiExe: %ProgramFiles%\fzf\bin\fzf.exe があればそのパス
$pfRoot = Join-Path ([IO.Path]::GetTempPath()) "install-fzf-tests-pf-$PID"
$pfExe = Join-Path (Join-Path (Join-Path $pfRoot 'fzf') 'bin') 'fzf.exe'
Test-Case 'MSI の fzf が無ければ空' '' { Find-PortableMsiExe -ProgramFiles @($pfRoot) -Relative $T.Msi }
New-Item -ItemType File -Force -Path $pfExe | Out-Null
Test-Case 'MSI の fzf があればそのパス' $pfExe { Find-PortableMsiExe -ProgramFiles @($pfRoot) -Relative $T.Msi }
Remove-Item -LiteralPath $pfRoot -Recurse -Force

# ---------------------------------------------------------------------------
# 入口から流れまで (Start-WingetPortable に fzf の表を渡す)。Windows に触る関数を偽物に差し替えて、打つ winget の順を確かめる。
# ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-fzf-tests-$PID"
$FakeExe = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\junegunn.fzf_Microsoft.Winget.Source_8wekyb3d8bbwe') 'fzf.exe'

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する (pin は 'pin add' のように 2 語)。install は fzf.exe を置き、uninstall は消す
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = if ($Arguments[0] -eq 'pin') { "pin $($Arguments[1])" } else { $Arguments[0] }
    $script:Calls.Add("$verb $($Arguments -join ' ')")
    $code = 0
    if (($code -eq 0) -and ($verb -eq 'install')) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    if (($code -eq 0) -and ($verb -eq 'uninstall')) { Remove-Item -LiteralPath $FakeExe -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{ ExitCode = $code; Lines = @() }
}
function Get-PortableState { param($Tool, $Target) $script:States.Dequeue() }
function Get-PortableBusyProcess { param($Tool) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'fzf.exe -1 +m' } }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [int]$Busy = 0, [switch]$ExeExists)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Busy = @()
    if ($Busy -gt 0) { $script:Busy = @(1..$Busy | ForEach-Object { [pscustomobject]@{ Id = 1000 + $_ } }) }
    Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
    if ($ExeExists) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    $out = @(Start-WingetPortable -Tool (Get-FzfTool) -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = @($script:Calls)
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$synced = New-State
Test-Case '-IfMissing は入っていなければ portable を入れて pin を足す (置き場所の fzf.exe を見て)' "0|install install --id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity --version $V --installer-type portable --accept-package-agreements|pin add" { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code)|$($r.Calls[0])|$(($r.Calls[2] -split ' ')[0..1] -join ' ')" }
Test-Case '入れ替えは、取得を確かめてから uninstall → install して pin を足す' '0 download uninstall install pin pin' { $r = Invoke-Flow -States @((New-State $handNewer), $synced) -ExeExists; "$($r.Code) $(@($r.Calls | ForEach-Object { ($_ -split ' ')[0] }) -join ' ')" }
Test-Case '動いている fzf があれば、winget を 1 つも打たずに止まり、PID とコマンドラインを出す' '1 0 True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) $($r.Calls.Count) $($r.Text -like '*1001*fzf.exe -1 +m*')" }
Test-Case 'MSI の fzf があれば、-IfMissing でも portable を入れずに 1 で止まる' '1 0 True' { $r = Invoke-Flow -States @((New-State $msiOnly)) -IfMissing; "$($r.Code) $($r.Calls.Count) $($r.Text -like '*MSI の fzf が入っているので、portable を入れずに止める*')" }
Test-Case 'MSI の fzf があれば、引数なしでも入れ替えない' '1 0' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ MsiExe = $Msi }))) -ExeExists; "$($r.Code) $($r.Calls.Count)" }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
