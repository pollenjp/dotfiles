# win/ghq/Install-Ghq.ps1 (ghq の表) のテスト。Pester は使わない。流れ・見張り・終了コードの決まりは共通の枠の試験
# (win/winget/WingetPortable.Tests.ps1) が確かめ、ここは ghq の表の値がそこへ正しく渡るかを確かめる。winget やプロセスに触る本物の部分は、
# 実機で -Check と本番を打って確かめる (win/README.md の「ghq・fzf」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/ghq/Install-Ghq.Tests.ps1
#
# ## 確かめること
#
#   - 表: パッケージ ID は x-motemen.ghq (版の知らせが読む $packageId の行)、ghq.exe は ghq_windows_amd64 の下 (無ければ置き場所の下を探す。
#     arm64 の ghq_windows_arm64 も)。MSI は見ない
#   - ghq.exe --version の出力 (ghq version <版> (rev:…)) から版を拾い、winget show --versions の版の行だけを新しい順に拾う
#   - install には --installer-type portable を付け、change は uninstall → install。取得だけを確かめる winget download も portable を名指しする
#   - PATH で引かれる ghq (winget の置き場所の ghq_windows_amd64・WinGet\Links なら winget のもの。go install のもの・置き場所の直下は other)
#   - 状態の表の見出しと行・締めの行 (runner が読む字)・昇格した PowerShell の締めの行 (runner が読む字)
#   - 流れ: 入っていなければ入れて pin を足す。入れ替えは取得を確かめてから外して入れる。動いている ghq があれば何も変えずに止まる
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Ghq.ps1 の末尾)。共通の枠も clone の win\winget\ から読む
. (Join-Path $PSScriptRoot 'Install-Ghq.ps1')

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

$Id = 'x-motemen.ghq'
$V = '1.12.0'
$Older = '1.10.1'
$Newer = '1.13.0'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\x-motemen.ghq_Microsoft.Winget.Source_8wekyb3d8bbwe'
$ExeDir = "$Pkg\ghq_windows_amd64"
$Links = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links'

# ghq の表に、試験の置き場所を足して埋めたもの
function New-Tool {
    param([hashtable]$Change = @{})
    $t = Get-GhqTool
    $t.PackageDir = $Pkg
    $t.LinksDir = $Links
    foreach ($k in $Change.Keys) { $t[$k] = $Change[$k] }
    Complete-PortableTool -Tool $t
}
$T = New-Tool

# 2026-11-23 に winget-pkgs にあった x-motemen.ghq の版 (winget show --versions の並び。1.9.x・1.10.0・1.11.x は載っていない) の
# 頭に、まだ無い新しい版を足したもの
$show = @(
    'Found ghq [x-motemen.ghq]'
    'Version'
    '-------'
    $Newer
    '1.12.0'
    '1.10.1'
    '1.8.0'
    '1.7.1'
)
$versions = @($V, $Older)

# 表
Test-Case 'パッケージ ID は $packageId の行 (版の知らせが読む)' $Id { $T.PackageId }
Test-Case '名前・関数・PATH で引く名前・README の節' 'ghq|Install-Ghq|ghq|ghq・fzf' { "$($T.Name)|$($T.Command)|$($T.CommandName)|$($T.Readme)" }
Test-Case 'ghq.exe は ghq_windows_amd64 の下。無ければ置き場所の下を探す' 'ghq_windows_amd64\ghq.exe True ghq.exe' { "$($T.ExePath) $($T.ExeSearch) $($T.ExeName)" }
Test-Case 'MSI は見ない・portable を名指しする' 'True portable' { "$($null -eq $T.Msi) $($T.InstallerType)" }

# ghq.exe --version の出力から版を拾う
function Get-Version { param([string[]]$Lines) Get-PortableVersionFromOutput -Lines $Lines -Pattern $T.VersionPattern }
Test-Case '"ghq version <版> (rev:…)" から版を拾う' $V { Get-Version @("ghq version $V (rev:2c3e1f5)") }
Test-Case 'rev の無い出力からも拾う' $Newer { Get-Version @("ghq version $Newer") }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-Version @("  ghq version $V (rev:HEAD)`r") }
Test-Case '頭に v のある版も拾う' $V { Get-Version @("ghq version v$V (rev:HEAD)") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-Version @('warning: something', "ghq version $V (rev:HEAD)") }
Test-Case '版の行が無ければ空' '' { Get-Version @('error: something went wrong') }
Test-Case '版の形でなければ空' '' { Get-Version @('ghq version unknown') }

Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$Newer 1.12.0 1.10.1 1.8.0 1.7.1" { Get-WingetVersionList -Lines $show }
$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '入っている版が一覧に無ければ unknown (winget に無い 1.11.2)' 'unknown' { Get-PortableDirection -Versions $showVersions -Installed '1.11.2' -Target $V }

# winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版と portable を名指しして入れる' "install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan install -Version $V)[0] -join ' ' }
Test-Case 'change は uninstall → portable を名指しした install' "uninstall $common|install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan change -Version $V | ForEach-Object { $_ -join ' ' }) -join '|' }
Test-Case '取得だけを確かめる winget download の引数 (portable を名指しする)' "download --id $Id --exact --source winget --version $V --installer-type portable --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -Tool $T -Version $V -Directory 'C:\tmp\dl') -join ' ' }

# PATH
$goBin = 'C:\Users\u\go\bin'
$existsGo = { param($p) $p -in @("$goBin\ghq.exe", "$ExeDir\ghq.exe") }
Test-Case 'go install の ghq.exe が前のディレクトリにあれば、それが引かれる' "$goBin\ghq.exe" { Resolve-PortableOnPath -PathValue "$goBin;$ExeDir" -Names @('ghq.exe', 'ghq.cmd', 'ghq.bat', 'ghq.ps1') -Exists $existsGo }
Test-Case 'winget の置き場所の ghq_windows_amd64 なら package' 'package' { Get-PortablePathKind -Resolved "$ExeDir\ghq.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'WinGet\Links の symlink なら links' 'links' { Get-PortablePathKind -Resolved "$Links\ghq.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'go install の ghq.exe なら other' 'other' { Get-PortablePathKind -Resolved "$goBin\ghq.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case '置き場所の直下 (exe のディレクトリでない) は other' 'other' { Get-PortablePathKind -Resolved "$Pkg\ghq.exe" -ExeDir $ExeDir -LinksDir $Links }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Exe = "$ExeDir\ghq.exe"; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$ExeDir\ghq.exe"; PathLinkTarget = $null; PathKind = 'package'; BusyCount = 0; MsiExe = $null
        WingetVersion = [version]'1.30.310'; Elevated = $false; Route = 'direct'
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Exe = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 手で入れた新しい版 (pin も無い)
$handNewer = @{ Installed = $Newer; Plan = 'change'; Direction = 'down'; Pinned = $false; Versions = @($Newer, $V, $Older); Latest = $Newer }

# 状態の表の行
function Get-Rows { param($State) @(Format-PortableState -Tool $T -State $State -Target $V) }
Test-Case '見出しはパッケージ名と置き場所 (runner の ps1.rs がこの頭で見分ける)' "ghq (winget の x-motemen.ghq、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの PATH の行' '  PATH の ghq     : winget の portable のもの (置き場所)' { (Get-Rows (New-State))[5].Text }
Test-Case '版が読めないとき' '  入っている版    : 不明 (ghq.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH でほかの ghq が先なら、その場所を ⚠ で出す' "⚠ PATH の ghq     : $goBin\ghq.exe (winget の portable のものではない)" { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = "$goBin\ghq.exe" }))[5].Text }
Test-Case 'PATH でほかの ghq が先なら、直し方を ※ で添える' "※ PATH のずれは Install-Ghq では直らない。$goBin の ghq.exe を消すか、$goBin をユーザーの PATH から外す (win/README.md の「ghq・fzf」)" { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = "$goBin\ghq.exe" }))[-1].Text }
Test-Case '置き場所が PATH に無ければ、足し直し方を ※ で添える' "※ ghq の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $Id の後に Install-Ghq で入れ直す" { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[-1].Text }
Test-Case '新しい版があれば ※ で知らせる' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Ghq.ps1 の -Version の既定値を変える" { (Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }))[6].Text }
Test-Case '入れ替えが要るのに ghq が動いていれば ※ で添える' '※ ghq.exe が 1 個動いている。入れ替えるには、動いている ghq (ghq get など) を終わらせる' { (Get-Rows (New-State ($handNewer + @{ BusyCount = 1 })))[-1].Text }

# 締めの行。Windows の runner (win/runner/src/steps/ps1.rs) がこの字で、入れるか・揃えるか・知らせるだけかを決め、昇格の行で直し方を選ぶ
function Get-Verdict { param($State) (@(Format-PortableVerdict -Tool $T -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '入っていなければ、Install-Ghq で入れると出す' '⚠️ ghq が入っていない → Install-Ghq で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版か pin の差があれば、Install-Ghq で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Ghq で揃える ⚠️' { Get-Verdict (New-State $handNewer) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の ghq が winget の portable のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = 'C:\X\ghq.exe' }) }
Test-Case '昇格した PowerShell で入れられなければ、昇格の 1 行だけ' '⚠️ 昇格した PowerShell では winget が ghq を入れない (winget 1.30 から) → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($missing + @{ Elevated = $true; Route = 'elevated' })) }

# Find-PortableExe: manifest の x64 の場所 (ghq_windows_amd64\ghq.exe) を先に見て、無ければ置き場所の下を探す (arm64 の ghq_windows_arm64 も)
$findRoot = Join-Path ([IO.Path]::GetTempPath()) "install-ghq-tests-find-$PID"
$x64 = Join-Path (Join-Path $findRoot 'ghq_windows_amd64') 'ghq.exe'
$arm64 = Join-Path (Join-Path $findRoot 'ghq_windows_arm64') 'ghq.exe'
Test-Case '置き場所が無ければ空' '' { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot }) }
New-Item -ItemType File -Force -Path $arm64 | Out-Null
Test-Case 'x64 の場所に無ければ、置き場所の下の ghq.exe (arm64) を見つける' $arm64 { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot }) }
New-Item -ItemType File -Force -Path $x64 | Out-Null
Test-Case 'x64 の場所 (ghq_windows_amd64\ghq.exe) を先に見る' $x64 { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot }) }
Remove-Item -LiteralPath $findRoot -Recurse -Force

# ---------------------------------------------------------------------------
# 入口から流れまで (Start-WingetPortable に ghq の表を渡す)。Windows に触る関数を偽物に差し替えて、打つ winget の順を確かめる。
# ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-ghq-tests-$PID"
$FakeExe = Join-PortablePath -Root (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\x-motemen.ghq_Microsoft.Winget.Source_8wekyb3d8bbwe') -Relative 'ghq_windows_amd64\ghq.exe'

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する。install は ghq.exe を置き、uninstall は消す
function Invoke-Winget {
    param([string[]]$Arguments)
    $script:Calls.Add($Arguments -join ' ')
    if ($Arguments[0] -eq 'install') { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    if ($Arguments[0] -eq 'uninstall') { Remove-Item -LiteralPath $FakeExe -Force -ErrorAction SilentlyContinue }
    [pscustomobject]@{ ExitCode = 0; Lines = @() }
}
function Get-PortableState { param($Tool, $Target) $script:States.Dequeue() }
function Get-PortableBusyProcess { param($Tool) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'ghq.exe get github.com/x-motemen/ghq' } }

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
    $out = @(Start-WingetPortable -Tool (Get-GhqTool) -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = @($script:Calls)
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$synced = New-State
Test-Case '-IfMissing は入っていなければ portable を入れ、ghq_windows_amd64 の ghq.exe を見て pin を足す' "0|install $common --version $V --installer-type portable --accept-package-agreements|pin add --id $Id --exact --accept-source-agreements --disable-interactivity" { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code)|$($r.Calls[0])|$($r.Calls[-1])" }
Test-Case '入れ替えは、取得を確かめてから uninstall → install して pin を足す' '0 download uninstall install pin pin' { $r = Invoke-Flow -States @((New-State $handNewer), $synced) -ExeExists; "$($r.Code) $(@($r.Calls | ForEach-Object { ($_ -split ' ')[0] }) -join ' ')" }
Test-Case '動いている ghq があれば、winget を 1 つも打たずに止まり、PID とコマンドラインを出す' '1 0 True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) $($r.Calls.Count) $($r.Text -like '*1001*ghq.exe get*')" }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
