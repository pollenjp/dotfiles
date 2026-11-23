# win/fzf/Install-Fzf.ps1 のうち、副作用の無い関数と、Windows に触る関数を偽物に差し替えた流れのテスト。Pester は使わない。
# winget やプロセスに触る本物の部分は、実機で -Check と本番を打って確かめる (win/README.md の「ghq・fzf」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/fzf/Install-Fzf.Tests.ps1
#
# ## 確かめること
#
#   - fzf.exe --version の出力 (<版> (<commit>)) から版を拾い、winget show --versions の版の行だけを新しい順に拾う
#   - 入っていなければ install、版が違う・読めなければ change (上げ下げは winget の版の並びで決める)、同じなら none
#   - install には --installer-type portable を付け (付けないと winget は MSI を選ぶ)、change は uninstall → install (どれも upgrade を
#     打たず、--include-pinned も付けない)。取得だけを確かめる winget download も portable を名指しする
#   - PATH で引かれる fzf (winget の置き場所の直下・WinGet\Links なら winget の portable のもの。MSI の fzf もほかも other)
#   - MSI の fzf (%ProgramFiles%\fzf\bin\fzf.exe) があれば、終了コードは 1 (portable が入っていなくても 3 にしない)・止める理由は msi・
#     表に ⚠ と外し方の ※・締めの行は MSI の 1 行だけ (runner が読む文言)
#   - 終了コード (揃っていれば 0・差があれば 1・入っていなければ 3)・状態の表の行・締めの行 (runner が読む文言)
#   - 流れ: -Check と -IfMissing は入れ替えない。揃える流れは取得を確かめてから外して入れ、pin を足す。動いている fzf があれば・
#     取得が落ちたら・固定した版が winget に無ければ・MSI の fzf があれば、何も変えずに止まる。PATH のずれだけなら winget を打たない
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Fzf.ps1 の末尾)
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
# (関数を通さずに書く。関数が無い段階でもテストが最後まで流れるように)
$versions = @($V, $Older)

# Get-FzfVersionFromOutput: fzf.exe --version の出力から版を拾う
Test-Case '"<版> (<commit>)" から版を拾う' $V { Get-FzfVersionFromOutput -Lines @("$V (7c3a2e9)") }
Test-Case 'nixpkgs の build の形 ("<版> (refs/tags/v<版>)") からも拾う' $Older { Get-FzfVersionFromOutput -Lines @("$Older (refs/tags/v$Older)") }
Test-Case 'commit の無い出力からも拾う' $Newer { Get-FzfVersionFromOutput -Lines @($Newer) }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-FzfVersionFromOutput -Lines @("  $V (7c3a2e9)`r") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-FzfVersionFromOutput -Lines @('warning: something', "$V (7c3a2e9)") }
Test-Case '版の行が無ければ空' '' { Get-FzfVersionFromOutput -Lines @('error: something went wrong') }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$Newer 0.75.0 0.74.5 0.74.4" { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }

# Get-FzfPlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-FzfPlan -Exists $false -Installed $null -Target $V }
Test-Case '同じ版なら none' 'none' { Get-FzfPlan -Exists $true -Installed $V -Target $V }
Test-Case '違う版なら change' 'change' { Get-FzfPlan -Exists $true -Installed $Newer -Target $V }
Test-Case 'fzf.exe があるのに版が読めなければ change' 'change' { Get-FzfPlan -Exists $true -Installed $null -Target $V }

# Get-FzfDirection: 入れ替えの向き (winget show --versions の並びで決める)
$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '固定した版が新しければ up' 'up' { Get-FzfDirection -Versions $showVersions -Installed $Older -Target $V }
Test-Case '入っている版の方が新しければ down' 'down' { Get-FzfDirection -Versions $showVersions -Installed $Newer -Target $V }
Test-Case '入っている版が一覧に無ければ unknown (winget に無い 0.66.1)' 'unknown' { Get-FzfDirection -Versions $showVersions -Installed '0.66.1' -Target $V }
Test-Case '一覧が読めなければ unknown' 'unknown' { Get-FzfDirection -Versions @() -Installed $Older -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか
$pinsNow = @(
    'Name              Id                        Version     Source Pin type'
    '-----------------------------------------------------------------------'
    'OpenSSH           Microsoft.OpenSSH.Preview 10.0.0.0    winget Pinning'
    'ghq               x-motemen.ghq             1.12.0      winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsNow -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsNow + @("fzf               $Id              $V      winget Pinning")) -PackageId $Id }
Test-Case 'Id の前方一致では True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id).Extra $V winget Pinning") -PackageId $Id }

# Get-WingetCommands: plan ごとに打つ winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版と portable を名指しして入れる (MSI を選ばせない)' "install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'change は 2 本 (外してから入れる)' 2 { @(Get-WingetCommands -Plan change -PackageId $Id -Version $V).Count }
Test-Case 'change の 1 本目は uninstall' "uninstall $common" { @(Get-WingetCommands -Plan change -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'change の 2 本目は portable を名指しした install' "install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Plan change -PackageId $Id -Version $V)[1] -join ' ' }
Test-Case 'none なら打たない' 0 { @(Get-WingetCommands -Plan none -PackageId $Id -Version $V).Count }
# winget の pin と打つ引数 (Install-Ntn.Tests.ps1 と同じ): 入れ替えは uninstall → install で、upgrade を打たない
Test-Case 'どの plan も upgrade を打たず、--include-pinned も付けない' '' {
    @('install', 'change', 'none') | ForEach-Object { @(Get-WingetCommands -Plan $_ -PackageId $Id -Version $V) } |
        Where-Object { ($_[0] -eq 'upgrade') -or (@($_) -contains '--include-pinned') } | ForEach-Object { $_ -join ' ' }
}
Test-Case '取得だけを確かめる winget download の引数 (portable を名指しする)' "download --id $Id --exact --source winget --version $V --installer-type portable --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -PackageId $Id -Version $V -Directory 'C:\tmp\dl') -join ' ' }

# Resolve-FzfOnPath: PATH を前から見て、最初に見つかった fzf.exe
$exists = { param($p) $p -in @('C:\B\fzf.exe', 'C:\A\fzf.exe') }
Test-Case '前から見て最初に見つかったもの' 'C:\A\fzf.exe' { Resolve-FzfOnPath -PathValue 'C:\A;C:\B' -Names @('fzf.exe') -Exists $exists }
Test-Case '末尾の \・引用符・空白・空の要素を飛ばす' 'C:\B\fzf.exe' { Resolve-FzfOnPath -PathValue ';; "C:\Z\" ; C:\B\ ;' -Names @('fzf.exe') -Exists $exists }
Test-Case 'どこにも無ければ空' '' { Resolve-FzfOnPath -PathValue 'C:\Z;C:\Y' -Names @('fzf.exe') -Exists $exists }
# マシンの PATH (MSI が足す %ProgramFiles%\fzf\bin) はユーザーの PATH (portable の置き場所) より前に並ぶ
$existsMsi = { param($p) $p -in @($Msi, "$ExeDir\fzf.exe") }
Test-Case 'MSI の fzf がマシンの PATH にあれば、portable より先に引かれる' $Msi { Resolve-FzfOnPath -PathValue "C:\Program Files\fzf\bin;$ExeDir" -Names @('fzf.exe', 'fzf.cmd', 'fzf.bat', 'fzf.ps1') -Exists $existsMsi }
Test-Case '同じディレクトリなら .exe を先に見る' "$ExeDir\fzf.exe" { Resolve-FzfOnPath -PathValue "$ExeDir" -Names @('fzf.exe', 'fzf.cmd') -Exists { param($p) $true } }

# Get-FzfPathKind: PATH で引かれる fzf.exe がどこのものか
Test-Case 'winget の置き場所の fzf.exe なら winget' 'winget' { Get-FzfPathKind -Resolved "$ExeDir\fzf.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case '大文字小文字が違っても winget' 'winget' { Get-FzfPathKind -Resolved "$($ExeDir.ToUpper())\fzf.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'WinGet\Links の symlink なら winget' 'winget' { Get-FzfPathKind -Resolved "$Links\fzf.exe" -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'MSI の fzf は other' 'other' { Get-FzfPathKind -Resolved $Msi -ExeDir $ExeDir -LinksDir $Links }
Test-Case 'scoop の fzf は other' 'other' { Get-FzfPathKind -Resolved 'C:\Users\u\scoop\shims\fzf.exe' -ExeDir $ExeDir -LinksDir $Links }
Test-Case '見つからなければ none' 'none' { Get-FzfPathKind -Resolved $null -ExeDir $ExeDir -LinksDir $Links }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$ExeDir\fzf.exe"; PathKind = 'winget'; BusyCount = 0; MsiExe = $null
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 手で入れた新しい版 (pin も無い)
$handNewer = @{ Installed = $Newer; Plan = 'change'; Direction = 'down'; Pinned = $false; Versions = @($Newer, $V, $Older); Latest = $Newer }
# winget install junegunn.fzf を手で打って MSI が入り、portable は入っていない (マシンの PATH の MSI の fzf が引かれる)
$msiOnly = $missing.Clone()
$msiOnly.PathKind = 'other'
$msiOnly.PathResolved = $Msi
$msiOnly.MsiExe = $Msi

# Test-FzfDrift / Test-FzfPathDrift / Test-FzfMsi: 揃える手順で直る差と、直らない PATH のずれと MSI の fzf
Test-Case '揃っていれば差は無い' 'False False False' { $s = New-State; "$(Test-FzfDrift -State $s) $(Test-FzfPathDrift -State $s) $(Test-FzfMsi -State $s)" }
Test-Case 'pin が無ければ揃える手順で直る差' 'True False' { "$(Test-FzfDrift -State (New-State @{ Pinned = $false })) $(Test-FzfPathDrift -State (New-State @{ Pinned = $false }))" }
Test-Case 'PATH でほかの fzf が先なら PATH のずれ (揃える手順では直らない)' 'False True' { $s = New-State @{ PathKind = 'other'; PathResolved = 'C:\X\fzf.exe' }; "$(Test-FzfDrift -State $s) $(Test-FzfPathDrift -State $s)" }
Test-Case '入っているのに PATH に無ければ PATH のずれ' 'True' { Test-FzfPathDrift -State (New-State @{ PathKind = 'none'; PathResolved = $null }) }
Test-Case '入っていないときに PATH に無いのは、ずれに数えない' 'False' { Test-FzfPathDrift -State (New-State $missing) }
Test-Case 'MSI の fzf があれば Test-FzfMsi は True' 'True' { Test-FzfMsi -State (New-State $msiOnly) }

# Get-FzfExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-FzfExitCode -State (New-State) }
Test-Case 'pin が無ければ 1' 1 { Get-FzfExitCode -State (New-State @{ Pinned = $false }) }
Test-Case '版が違えば 1' 1 { Get-FzfExitCode -State (New-State $handNewer) }
Test-Case 'PATH でほかの fzf が先なら 1' 1 { Get-FzfExitCode -State (New-State @{ PathKind = 'other'; PathResolved = 'C:\X\fzf.exe' }) }
Test-Case '入っていなければ 3' 3 { Get-FzfExitCode -State (New-State $missing) }
Test-Case 'MSI の fzf があれば、portable が入っていなくても 1 (runner に入れにいかせない)' 1 { Get-FzfExitCode -State (New-State $msiOnly) }
Test-Case 'MSI の fzf があれば、portable が揃っていても 1' 1 { Get-FzfExitCode -State (New-State @{ MsiExe = $Msi }) }

# Get-FzfApplyBlocker: 揃える前に止める理由
Test-Case '入れられるなら止めない' '' { Get-FzfApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 0 -Msi $false }
Test-Case 'MSI の fzf があれば msi (ほかの理由より先)' 'msi' { Get-FzfApplyBlocker -Plan change -Versions $versions -Target '0.66.1' -BusyCount 1 -Msi $true }
Test-Case '固定した版が winget に無ければ not-listed (winget に無い 0.66.1)' 'not-listed' { Get-FzfApplyBlocker -Plan install -Versions $versions -Target '0.66.1' -BusyCount 0 -Msi $false }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-FzfApplyBlocker -Plan change -Versions @() -Target $V -BusyCount 0 -Msi $false }
Test-Case '入れ替えるのに fzf が動いていれば busy' 'busy' { Get-FzfApplyBlocker -Plan change -Versions $versions -Target $V -BusyCount 1 -Msi $false }
Test-Case '入れるだけなら動いている数は見ない' '' { Get-FzfApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 2 -Msi $false }
Test-Case 'pin を足すだけなら止めない' '' { Get-FzfApplyBlocker -Plan none -Versions @() -Target 'x' -BusyCount 3 -Msi $false }

# Format-FzfState: 状態の表の行
function Get-Rows { param($State) @(Format-FzfState -State $State -Target $V -PackageId $Id -PackageDir $Pkg) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 6 行だけ' 6 { (Get-Rows (New-State)).Count }
Test-Case '見出しはパッケージ名と置き場所 (runner の ps1.rs がこの頭で見分ける)' "fzf (winget の junegunn.fzf、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの版の行' "  固定した版      : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case '揃っているときの PATH の行' '  PATH の fzf     : winget の portable のもの' { (Get-Rows (New-State))[5].Text }
Test-Case '手で入れた新しい版から下げるとき' "⚠ 固定した版      : $V → 入れ替える (下げる)" { (Get-Rows (New-State $handNewer))[2].Text }
Test-Case 'pin が無ければ ⚠' '⚠ winget pin      : 無し → 足す' { (Get-Rows (New-State @{ Pinned = $false }))[4].Text }
Test-Case '入っていなければ「入っていない」と「入れる」' "  入っている版    : 入っていない ⚠ 固定した版      : $V → 入れる" { $r = Get-Rows (New-State $missing); "$($r[1].Text) $($r[2].Text)" }
Test-Case '入っていないときに PATH に無いのは ⚠ にしない' '  PATH の fzf     : 見つからない' { (Get-Rows (New-State $missing))[5].Text }
Test-Case '入っているのに PATH に無ければ ⚠' '⚠ PATH の fzf     : 見つからない' { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[5].Text }
Test-Case '版が読めないとき' '  入っている版    : 不明 (fzf.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH でほかの fzf が先なら、その場所を ⚠ で出す' '⚠ PATH の fzf     : C:\Users\u\scoop\shims\fzf.exe (winget の portable のものではない)' { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\scoop\shims\fzf.exe' }))[5].Text }
Test-Case 'PATH でほかの fzf が先なら、直し方を ※ で添える' '※ PATH のずれは Install-Fzf では直らない。C:\Users\u\scoop\shims の fzf.exe を消すか、C:\Users\u\scoop\shims をユーザーの PATH から外す (win/README.md の「ghq・fzf」)' { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\scoop\shims\fzf.exe' }))[-1].Text }
Test-Case '置き場所が PATH に無ければ、足し直し方を ※ で添える' "※ fzf の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $Id の後に Install-Fzf で入れ直す" { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[-1].Text }
Test-Case 'winget show が失敗したら最新版は不明で、一覧についての ※/⚠ は出さない' '  winget の最新版 : 不明 (winget show が失敗) 6' { $r = Get-Rows (New-State @{ Versions = @(); Latest = $null }); "$($r[3].Text) $($r.Count)" }
Test-Case '新しい版があれば ※ で知らせる (⚠ にしない)' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Fzf.ps1 の -Version の既定値を変える 0" { $r = Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }); "$($r[6].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '固定した版が winget から消えても、入っていれば ※' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { (Get-Rows (New-State @{ Versions = @($Newer, $Older); Latest = $Newer }))[6].Text }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @($Newer, $Older); Latest = $Newer })))[6].Text }
Test-Case '入れ替えが要るのに fzf が動いていれば ※ で添える' '※ fzf.exe が 1 個動いている。入れ替えるには、動いている fzf (cdrepo の選ぶ画面など) を終わらせる' { (Get-Rows (New-State ($handNewer + @{ BusyCount = 1 })))[-1].Text }
Test-Case '入れ替えが要らなければ動いている数は出さない' 6 { (Get-Rows (New-State @{ BusyCount = 2 })).Count }
Test-Case 'MSI の fzf があれば、⚠ の行で場所を出す' "⚠ MSI の fzf (machine スコープ。winget の既定の installer) が入っている: $Msi" { (Get-Rows (New-State $msiOnly))[6].Text }
Test-Case 'MSI の fzf があれば、外し方を ※ で添える (PATH のずれの ※ は出さない)' "※ portable と二重にしないため、MSI があるうちは Install-Fzf は何も入れない。PowerShell で winget uninstall --id $Id --exact --scope machine を打って MSI を外し (UAC の確認が出る)、Install-Fzf を打ち直す (win/README.md の「ghq・fzf」) 8" { $r = Get-Rows (New-State $msiOnly); "$($r[-1].Text) $($r.Count)" }

# Format-FzfVerdict: 締めの行。Windows の runner (win/runner/src/steps/ps1.rs) がこの文言で、入れるか・揃えるか・知らせるだけかを決める
function Get-Verdict { param($State) (@(Format-FzfVerdict -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '揃っていれば締めの行は出さない' '' { Get-Verdict (New-State) }
Test-Case '入っていなければ、Install-Fzf で入れると出す' '⚠️ fzf が入っていない → Install-Fzf で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版か pin の差があれば、Install-Fzf で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Fzf で揃える ⚠️' { Get-Verdict (New-State $handNewer) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の fzf が winget の portable のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = 'C:\X\fzf.exe' }) }
Test-Case '版の差と PATH のずれが両方あれば、両方を出す' "⚠️ 固定した版と揃っていない → Install-Fzf で揃える ⚠️`n⚠️ PATH の fzf が winget の portable のものではない → ※ の手順で直す ⚠️" { Get-Verdict (New-State ($handNewer + @{ PathKind = 'other'; PathResolved = 'C:\X\fzf.exe' })) }
Test-Case 'MSI の fzf があれば、MSI の 1 行だけ (入れる・揃えるとは言わない)' '⚠️ MSI の fzf (machine スコープ) が入っている → ※ の手順で直す ⚠️' { Get-Verdict (New-State $msiOnly) }
Test-Case 'MSI の fzf と版の差があっても、MSI の 1 行だけ' '⚠️ MSI の fzf (machine スコープ) が入っている → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($handNewer + @{ MsiExe = $Msi })) }

# Get-FzfInstalledVersion: 起動できない fzf.exe (壊れた・0 バイト) でも例外で止まらず、版は空
$broken = Join-Path ([IO.Path]::GetTempPath()) "install-fzf-tests-broken-$PID.exe"
Set-Content -LiteralPath $broken -Value '' -NoNewline
if (-not $IsWindows) { chmod +x $broken }
Test-Case '起動できない fzf.exe なら版は空 (入れ替えの対象になる)' '' { Get-FzfInstalledVersion -Exe $broken }
Remove-Item -LiteralPath $broken -Force

# Find-FzfExe: manifest の場所 (置き場所の直下) を先に見て、無ければ置き場所の下を探す
$findRoot = Join-Path ([IO.Path]::GetTempPath()) "install-fzf-tests-find-$PID"
$top = Join-Path $findRoot 'fzf.exe'
$nested = Join-Path (Join-Path $findRoot 'fzf-other-layout') 'fzf.exe'
New-Item -ItemType File -Force -Path $nested | Out-Null
Test-Case 'zip の中の形が変わっても、置き場所の下の fzf.exe を見つける' $nested { Find-FzfExe -PackageDir $findRoot }
New-Item -ItemType File -Force -Path $top | Out-Null
Test-Case '置き場所の直下の fzf.exe を先に見る' $top { Find-FzfExe -PackageDir $findRoot }
Test-Case '置き場所が無ければ空' '' { Find-FzfExe -PackageDir (Join-Path $findRoot 'none') }
Remove-Item -LiteralPath $findRoot -Recurse -Force

# Find-FzfMsiExe: %ProgramFiles%\fzf\bin\fzf.exe があればそのパス
$pfRoot = Join-Path ([IO.Path]::GetTempPath()) "install-fzf-tests-pf-$PID"
$pfExe = Join-Path (Join-Path (Join-Path $pfRoot 'fzf') 'bin') 'fzf.exe'
Test-Case 'MSI の fzf が無ければ空' '' { Find-FzfMsiExe -ProgramFiles $pfRoot }
New-Item -ItemType File -Force -Path $pfExe | Out-Null
Test-Case 'MSI の fzf があればそのパス' $pfExe { Find-FzfMsiExe -ProgramFiles $pfRoot }
Test-Case 'ProgramFiles が無ければ (Linux の pwsh) 空' '' { Find-FzfMsiExe -ProgramFiles $null }
Remove-Item -LiteralPath $pfRoot -Recurse -Force

# 本体の入口: Linux の pwsh には $env:LOCALAPPDATA が無く、本体の最初で例外になる。
# それでも終了コード 2 で止まり、成功 (0) に見せない
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-Fzf.ps1') -Check 2>&1
    $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Invoke-InstallFzf の流れ。Windows に触る関数を偽物に差し替えて、打つ winget の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-fzf-tests-$PID"
$FakeExe = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\junegunn.fzf_Microsoft.Winget.Source_8wekyb3d8bbwe') 'fzf.exe'

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する (pin は 'pin add' のように 2 語)。install は fzf.exe を置き、uninstall は消す
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = if ($Arguments[0] -eq 'pin') { "pin $($Arguments[1])" } else { $Arguments[0] }
    $script:Calls.Add($verb)
    $code = 0
    if ($script:Fail.ContainsKey($verb)) { $code = $script:Fail[$verb] }
    if (($code -eq 0) -and ($verb -eq 'install')) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    if (($code -eq 0) -and ($verb -eq 'uninstall')) { Remove-Item -LiteralPath $FakeExe -Force -ErrorAction SilentlyContinue }
    $lines = @()
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("fzf $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Get-FzfState { param($PackageId, $PackageDir, $LinksDir, $Target) $script:States.Dequeue() }
function Get-FzfBusyProcess { param($PackageDir) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'fzf.exe -1 +m' } }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-FzfState が返す順 (揃える前と、揃えた後に読み直したもの)
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
    $out = @(Invoke-InstallFzf -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
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
Test-Case '動いている fzf があれば、winget を 1 つも打たずに止まり、PID とコマンドラインを出す' '1 [] True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*1001*fzf.exe -1 +m*')" }
Test-Case '取得が落ちたら、何も変えずに止まる' '1 [download] True' { $r = Invoke-Flow -States @($changeState) -Fail @{ download = 1 } -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*何も変えていない*')" }
Test-Case 'uninstall が落ちたら install せず、pin を足す (入っている版は残る)' '1 [download uninstall pin list pin add]' { $r = Invoke-Flow -States @($changeState, $changeState) -Fail @{ uninstall = 1 } -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'uninstall の後に install が落ちたら、入れ直し方を出す' $true { $r = Invoke-Flow -States @($changeState, (New-State $missing)) -Fail @{ install = 1 } -ExeExists; ($r.Code -eq 1) -and ($r.Text -like '*Install-Fzf を打ち直す*') }
Test-Case '固定した版が winget に無ければ、winget を打たずに止まる' '1 []' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @($Newer); Latest = $Newer }))); "$($r.Code) [$($r.Calls)]" }
$pathOnly = New-State @{ PathKind = 'other'; PathResolved = 'C:\X\fzf.exe' }
Test-Case 'PATH のずれだけなら winget を打たずに 1 で止まり、※ の手順で直すと出す' '1 [] True' { $r = Invoke-Flow -States @($pathOnly) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*※ の手順で直す*')" }
Test-Case '揃えた後も PATH のずれが残れば、版と pin は揃ったと出して 1' '1 True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ PathKind = 'other'; PathResolved = 'C:\X\fzf.exe' })), $pathOnly) -ExeExists; "$($r.Code) $($r.Text -like '*版と pin は揃った*')" }
# MSI の fzf があるうちは、portable を入れも入れ替えもしない (winget を 1 つも打たない)
Test-Case 'MSI の fzf があれば、-Check は 1 で MSI の締めの行を出す' '1 [] True' { $r = Invoke-Flow -States @((New-State $msiOnly)) -Check; "$($r.Code) [$($r.Calls)] $($r.Text -like '*MSI の fzf (machine スコープ) が入っている*')" }
Test-Case 'MSI の fzf があれば、-IfMissing でも portable を入れずに 1 で止まる' '1 [] True' { $r = Invoke-Flow -States @((New-State $msiOnly)) -IfMissing; "$($r.Code) [$($r.Calls)] $($r.Text -like '*portable を入れずに止める*')" }
Test-Case 'MSI の fzf があれば、引数なしでも portable を入れずに 1 で止まる' '1 [] True' { $r = Invoke-Flow -States @((New-State $msiOnly)); "$($r.Code) [$($r.Calls)] $($r.Text -like '*portable を入れずに止める*')" }
Test-Case 'MSI の fzf があれば、portable の入れ替えもしない' '1 []' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ MsiExe = $Msi }))) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
