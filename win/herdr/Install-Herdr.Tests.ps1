# win/herdr/Install-Herdr.ps1 (herdr の表と、前の Herdr.Herdr.Preview を見る custom の関数) のテスト。Pester は使わない。流れ・見張り・終了コードの
# 決まりは共通の枠の試験 (win/winget/WingetPortable.Tests.ps1) が確かめ、ここは herdr の表の値と custom の関数がそこへ正しく渡るかを確かめる。
# winget やプロセスに触る本物の部分は、実機で -Check と本番を打って確かめる (win/README.md の「herdr を入れる」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/herdr/Install-Herdr.Tests.ps1
#
# ## 確かめること
#
#   - 表: パッケージ ID は Herdr.Herdr (版の知らせが読む $packageId の行)、herdr.exe は置き場所の直下。portable を名指しする
#   - herdr.exe --version の出力 (herdr <版>) から版を拾う (版は文字列のまま比べる)
#   - PATH で引かれる herdr: 置き場所 (開発者モードが off) と WinGet\Links の symlink (開発者モードが on) のどちらも winget のものとして読む。
#     Herdr.Herdr.Preview の置き場所のもの (WinGet\Links の symlink が Preview を指すものも) は preview、herdr update で入ったものは other
#     (揃える手順では直らないので ※ の手順で直す)
#   - Herdr.Herdr.Preview が残っていれば、終了コードは 1 (Herdr.Herdr が入っていなければ 3 で、並べて入れる)・表に ⚠ の行・締めの行に外す手順。
#     入れ替えるときは先に Preview を外させる (winget が Preview を Herdr.Herdr として数えるため)。Preview は外さない
#   - 状態の表の見出しと行・締めの行 (WSL の bootstrap-windows-herdr.sh と runner が読む字)・昇格した PowerShell の締めの行
#   - 本物の Get-PortableState に herdr の表を渡し (葉だけ偽物)、WinGet\Links の symlink の指す先で links と preview を読み分ける
#   - 流れ: 入っていなければ入れて pin を足す。動いている herdr があれば・Preview が残っていて入れ替えが要れば、何も変えずに止まる
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Herdr.ps1 の末尾)。共通の枠も clone の win\winget\ から読む
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
$PreviewProductCode = 'Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'
$V = '0.9.5'
$Older = '0.9.4'
$Newer = '0.9.6'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Herdr.Herdr_Microsoft.Winget.Source_8wekyb3d8bbwe'
$PreviewPkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'
$Links = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links'

# herdr の表に、試験の置き場所を足して埋めたもの
function New-Tool {
    param([hashtable]$Change = @{})
    $t = Get-HerdrTool
    $t.PackageDir = $Pkg
    $t.LinksDir = $Links
    foreach ($k in $Change.Keys) { $t[$k] = $Change[$k] }
    Complete-PortableTool -Tool $t
}
$T = New-Tool

# 2026-11-09 に winget show --id Herdr.Herdr --exact --versions が出したもの (安定版はまだ 0.9.5 だけ)
$show = @(
    'Found herdr [Herdr.Herdr]'
    'Version'
    '-------'
    '0.9.5'
)
$versions = @($V, $Older)

# 表
Test-Case 'パッケージ ID は $packageId の行 (版の知らせが読む)' $Id { $T.PackageId }
Test-Case '名前・関数・PATH で引く名前・README の節' 'herdr|Install-Herdr|herdr|herdr を入れる' { "$($T.Name)|$($T.Command)|$($T.CommandName)|$($T.Readme)" }
Test-Case 'herdr.exe は置き場所の直下 (探さない)・MSI は見ない・portable を名指しする (manifest は zip の中の portable)' 'herdr.exe False True portable' { "$($T.ExePath) $($T.ExeSearch) $($null -eq $T.Msi) $($T.InstallerType)" }
Test-Case 'Preview の置き場所は、Herdr.Herdr の置き場所と並ぶ' $PreviewPkg { Get-HerdrPreviewDir -Tool $T }

# herdr.exe --version の出力から版を拾う
function Get-Version { param([string[]]$Lines) Get-PortableVersionFromOutput -Lines $Lines -Pattern $T.VersionPattern }
Test-Case '"herdr <版>" から版を拾う' $V { Get-Version @("herdr $V") }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-Version @("  herdr $V`r") }
Test-Case 'ほかの行が先にあっても拾う' '0.9.0' { Get-Version @('warning: config issues found', 'herdr 0.9.0') }
Test-Case '版の行が無ければ空' '' { Get-Version @('error: something went wrong') }
Test-Case '後ろに印の付いた版は、同じ数字でも change (版は文字列のまま比べる)' 'change' { Get-PortablePlan -Exists $true -Installed (Get-Version @("herdr $V-rc1")) -Target $V }

Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' $V { Get-WingetVersionList -Lines $show }
Test-Case '後ろに印の付いた版 (Herdr.Herdr.Preview の形) も上から順に拾う' '0.9.4-preview.2026-10-14-fbd2ae23927f 0.9.3-preview.2026-10-12-6d697e1e75ff' { Get-WingetVersionList -Lines @('Version', '-------------------------------------', '0.9.4-preview.2026-10-14-fbd2ae23927f', '0.9.3-preview.2026-10-12-6d697e1e75ff') }

# Test-WingetPinned: 2026-11-09 に winget pin list --id Herdr.Herdr --exact が出したもの (--id を付けても、ほかのパッケージの pin も並ぶ)
$pinsNow = @(
    'Name              Id                        Version     Source Pin type'
    '-----------------------------------------------------------------------'
    'Google 日本語入力 Google.JapaneseIME        3.34.6260.0 winget Pinning'
    'herdr (Preview)   Herdr.Herdr.Preview                   winget Pinning'
    'OpenSSH           Microsoft.OpenSSH.Preview 10.0.0.0    winget Pinning'
)
Test-Case 'Herdr.Herdr.Preview の pin しか無ければ、Herdr.Herdr は False' 'False' { Test-WingetPinned -Lines $pinsNow -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsNow + @("herdr             $Id                               winget Pinning")) -PackageId $Id }

# winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版と portable を名指しして入れる' "install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan install -Version $V)[0] -join ' ' }
Test-Case 'change は uninstall → install' "uninstall $common|install $common --version $V --installer-type portable --accept-package-agreements" { (@(Get-WingetCommands -Tool $T -Plan change -Version $V) | ForEach-Object { $_ -join ' ' }) -join '|' }
Test-Case '取得だけを確かめる winget download の引数 (portable を名指しする)' "download --id $Id --exact --source winget --version $V --installer-type portable --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -Tool $T -Version $V -Directory 'C:\tmp\dl') -join ' ' }

# PATH で引かれる herdr.exe がどこのものか
Test-Case '%VAR% を展開してから見る' 'C:\B\herdr.exe' { $env:TKT112_HERDR_TEST = 'C:\B'; Resolve-PortableOnPath -PathValue '%TKT112_HERDR_TEST%' -Names @('herdr.exe') -Exists { param($p) $p -eq 'C:\B\herdr.exe' } }
function Get-PathKind {
    param([string]$Resolved, [string]$LinkTarget)
    Get-PortablePathKind -Resolved $Resolved -ExeDir $Pkg -LinksDir $Links -Custom (Get-HerdrPathKind -Tool $T -Resolved $Resolved -LinkTarget $LinkTarget) -LinkTarget $LinkTarget -PackageDir $Pkg
}
Test-Case 'winget の置き場所のもの (開発者モードが off) なら package' 'package' { Get-PathKind "$Pkg\herdr.exe" }
Test-Case '大文字小文字が違っても package' 'package' { Get-PathKind "$($Pkg.ToUpper())\herdr.exe" }
Test-Case 'WinGet\Links の symlink (開発者モードが on) も winget のもの (links)' 'links' { Get-PathKind "$Links\herdr.exe" }
Test-Case 'Herdr.Herdr.Preview の置き場所のものなら preview' 'preview' { Get-PathKind "$PreviewPkg\herdr.exe" }
Test-Case 'herdr update で入ったものなら other' 'other' { Get-PathKind 'C:\Users\u\AppData\Local\Programs\Herdr\bin\herdr.exe' }
Test-Case '見つからなければ none' 'none' { Get-PathKind $null }
# WinGet\Links の symlink の指す先 (Herdr.Herdr.Preview を開発者モードが on で入れた PC は、Preview の symlink が WinGet\Links に残る)
Test-Case 'WinGet\Links の symlink が Herdr.Herdr の置き場所を指せば links' 'links' { Get-PathKind "$Links\herdr.exe" "$Pkg\herdr.exe" }
Test-Case 'WinGet\Links の symlink が Herdr.Herdr.Preview の置き場所を指せば preview' 'preview' { Get-PathKind "$Links\herdr.exe" "$PreviewPkg\herdr.exe" }
Test-Case 'WinGet\Links の symlink がほかを指せば other' 'other' { Get-PathKind "$Links\herdr.exe" 'C:\Users\u\AppData\Local\Programs\Herdr\bin\herdr.exe' }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Exe = "$Pkg\herdr.exe"; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$Pkg\herdr.exe"; PathLinkTarget = $null; PathKind = 'package'; BusyCount = 0
        MsiExe = $null; WingetVersion = [version]'1.30.310'; Elevated = $false; Route = 'direct'; PreviewExists = $false
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Exe = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 開発者モードが on の PC (winget が WinGet\Links に symlink を置き、置き場所を PATH に足さない)
$linksForm = @{ PathKind = 'links'; PathResolved = "$Links\herdr.exe" }
# Herdr.Herdr.Preview が残っている (PATH で引かれるのは Herdr.Herdr のもの)
$previewLeft = @{ PreviewExists = $true }
# Herdr.Herdr.Preview が残っていて、PATH でも Preview の herdr が先に引かれる (Herdr.Herdr を後から並べて入れたとき)
$previewOnPath = @{ PreviewExists = $true; PathKind = 'preview'; PathResolved = "$PreviewPkg\herdr.exe" }
# Herdr.Herdr.Preview が残っていて、WinGet\Links の Preview の symlink が先に引かれる (Preview を開発者モードが on で入れたとき)
$previewViaLink = @{ PreviewExists = $true; PathKind = 'preview'; PathResolved = "$Links\herdr.exe"; PathLinkTarget = "$PreviewPkg\herdr.exe" }
# Herdr.Herdr は入っておらず、Herdr.Herdr.Preview だけがある (Preview から移る前の PC)
$previewOnly = @{ Exists = $false; Installed = $null; Exe = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'preview'; PathResolved = "$PreviewPkg\herdr.exe"; PreviewExists = $true }
$herdrUpdate = @{ PathKind = 'other'; PathResolved = 'C:\Users\u\AppData\Local\Programs\Herdr\bin\herdr.exe' }

# 揃える手順で直る差と、人が直す差
Test-Case '揃っていれば差は無い' 'False False' { $s = New-State; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'Links の symlink の形で揃っていても差は無い (開発者モードが on の PC)' 'False False 0' { $s = New-State $linksForm; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s) $(Get-PortableExitCode -Tool $T -State $s)" }
Test-Case 'pin が無い・版が違うのは揃える手順で直る差' 'True True' { "$(Test-PortableDrift -Tool $T -State (New-State @{ Pinned = $false })) $(Test-PortableDrift -Tool $T -State (New-State @{ Installed = $Older; Plan = 'change' }))" }
Test-Case 'PATH で herdr update の herdr が先なのは、人が直す差 (揃える手順では直らない)' 'False True' { $s = New-State $herdrUpdate; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'Preview が残っているだけなら、人が直す差' 'False True' { $s = New-State $previewLeft; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'PATH で Preview の herdr が先なのは、PATH のずれには数えない (Preview を外せば直る)' 'False' { Test-PortablePathDrift -State (New-State $previewOnPath) }

# 終了コード
Test-Case '揃っていれば 0' 0 { Get-PortableExitCode -Tool $T -State (New-State) }
Test-Case 'pin が無ければ 1' 1 { Get-PortableExitCode -Tool $T -State (New-State @{ Pinned = $false }) }
Test-Case 'PATH で別の herdr が先なら 1' 1 { Get-PortableExitCode -Tool $T -State (New-State $herdrUpdate) }
Test-Case '入っていなければ 3' 3 { Get-PortableExitCode -Tool $T -State (New-State $missing) }
Test-Case 'Herdr.Herdr が揃っていても、Preview が残っていれば 1' 1 { Get-PortableExitCode -Tool $T -State (New-State $previewLeft) }
Test-Case 'PATH で Preview の herdr が先なら 1' 1 { Get-PortableExitCode -Tool $T -State (New-State $previewOnPath) }
Test-Case 'Preview が残っていても、Herdr.Herdr が入っていなければ 3 (setup が並べて入れる)' 3 { Get-PortableExitCode -Tool $T -State (New-State $previewOnly) }

# 揃える前に止める理由。Preview が残っている間は入れ替えない。winget が Preview を Herdr.Herdr として数え、uninstall --id Herdr.Herdr が
# どちらに当たるかが定まらない。入れる・pin を足すだけなら止めない
function Get-Blocker { param($State, $Target = $V) Get-PortableApplyBlocker -Tool $T -State $State -Target $Target }
Test-Case '入れ替えるのに herdr が動いていれば busy' 'busy' { Get-Blocker (New-State @{ Installed = $Older; Plan = 'change'; BusyCount = 2 }) }
Test-Case '入れ替えるのに Preview が残っていれば止める (custom)' 'custom' { Get-Blocker (New-State ($previewLeft + @{ Installed = $Older; Plan = 'change' })) }
Test-Case '入れ替えるのに Preview が残っていて herdr も動いていれば、Preview を先に言う' 'custom' { Get-Blocker (New-State ($previewLeft + @{ Installed = $Older; Plan = 'change'; BusyCount = 2 })) }
Test-Case '入れるだけなら、Preview が残っていても止めない (並べて入れる)' '' { Get-Blocker (New-State $previewOnly) }
Test-Case 'pin を足すだけなら、Preview が残っていても止めない' '' { Get-Blocker (New-State ($previewLeft + @{ Pinned = $false })) }
Test-Case '固定した版が winget に無ければ not-listed (Preview より先)' 'not-listed' { Get-Blocker (New-State $previewOnly) '9.9.9-preview.typo' }
Test-Case '止めるときは、Preview を外す手順と打ち直しを出す' "$PreviewId が残っているので入れ替えない (winget が Preview を $Id として数え、どちらを外すかが定まらない)。先に $PreviewId を外してから打ち直す:|  1. herdr の外の PowerShell (Windows Terminal など) で hsvstop を打ち、herdr --remote の窓も閉じる|  2. winget uninstall --product-code $PreviewProductCode を打つ|  3. winget pin remove --id $PreviewId --exact を打つ (Preview の pin を外す)|  4. 新しい PowerShell で Install-Herdr を打ち直す" { @(Get-HerdrPreviewBlocker -Tool $T -State (New-State ($previewLeft + @{ Installed = $Older; Plan = 'change' }))) -join '|' }

# 状態の表の行
function Get-Rows { param($State) @(Format-PortableState -Tool $T -State $State -Target $V) }
Test-Case '揃っていれば ⚠ の行は無く、表の 6 行だけ (Preview の行は出さない)' '0 6' { $r = Get-Rows (New-State); "$(@($r | Where-Object { $_.Warn }).Count) $($r.Count)" }
Test-Case '見出しはパッケージ名と置き場所 (bootstrap-windows-herdr.sh と runner がこの頭で見分ける)' "herdr (winget の Herdr.Herdr、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case 'PATH の行の幅はほかの行と同じにそろえる' '  PATH の herdr   : winget の portable のもの (置き場所)' { (Get-Rows (New-State))[5].Text }
Test-Case 'Links の symlink の形は ⚠ にしない (開発者モードが on の PC)' "  PATH の herdr   : winget の portable のもの (WinGet\Links の symlink) 0" { $r = Get-Rows (New-State $linksForm); "$($r[5].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case 'Preview が残っていれば、PATH の行の後に ⚠ の行を足す' '⚠ 前の Preview    : Herdr.Herdr.Preview が残っている → 外す' { (Get-Rows (New-State $previewLeft))[6].Text }
Test-Case 'Preview が残っているだけなら、ほかの行は ⚠ にしない' 1 { @((Get-Rows (New-State $previewLeft)) | Where-Object { $_.Warn }).Count }
Test-Case 'PATH で Preview の herdr が先なら、その場所を ⚠ で出す' "⚠ PATH の herdr   : $PreviewPkg\herdr.exe (Herdr.Herdr.Preview のもの)" { (Get-Rows (New-State $previewOnPath))[5].Text }
Test-Case 'PATH で Preview の herdr が先なら、Preview を外せば直ると ※ で添える' '※ PATH で先に引かれる herdr は Herdr.Herdr.Preview のもの。Preview を外せば直る (外すと置き場所と、WinGet\Links の Preview の symlink (あれば) が消え、ユーザーの PATH に残る行は飛ばされる)' { (Get-Rows (New-State $previewOnPath))[-1].Text }
Test-Case 'PATH で Preview の herdr が先でも、「PATH から外す」とは言わない' 0 { @((Get-Rows (New-State $previewOnPath)) | Where-Object { $_.Text -like '*PATH から外す*' }).Count }
Test-Case 'WinGet\Links の symlink が Preview を指せば、指す先も ⚠ で出し、Preview を外せば直ると ※ で添える (WinGet\Links を PATH から外させない)' "⚠ PATH の herdr   : $Links\herdr.exe → $PreviewPkg\herdr.exe (Herdr.Herdr.Preview のもの)|True|0" {
    $r = Get-Rows (New-State $previewViaLink); "$($r[5].Text)|$($r[-1].Text -like '※ PATH で先に引かれる herdr は Herdr.Herdr.Preview のもの*')|$(@($r | Where-Object { $_.Text -like '*PATH から外す*' }).Count)"
}
# Herdr.Herdr が入っていない間は、Preview を外せと読める行を出さない (入れる前に外すと herdr が無くなる)
Test-Case 'Herdr.Herdr が入っていなくて Preview だけがあるときは、Preview の行を「入れてから外す」にする' '⚠ 前の Preview    : Herdr.Herdr.Preview が残っている → Herdr.Herdr を入れてから外す' { (Get-Rows (New-State $previewOnly))[6].Text }
Test-Case 'Herdr.Herdr が入っていなければ、PATH で Preview の herdr が引かれても ⚠ にしない' "  PATH の herdr   : $PreviewPkg\herdr.exe (Herdr.Herdr.Preview のもの)" { (Get-Rows (New-State $previewOnly))[5].Text }
Test-Case 'Herdr.Herdr が入っていなければ、「Preview を外せば直る」の ※ は出さない (表の 7 行だけ)' 7 { (Get-Rows (New-State $previewOnly)).Count }
Test-Case '版が読めないとき' '  入っている版    : 不明 (herdr.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH で別の herdr が先なら、その場所を ⚠ で出す' '⚠ PATH の herdr   : C:\Users\u\AppData\Local\Programs\Herdr\bin\herdr.exe (winget の portable のものではない)' { (Get-Rows (New-State $herdrUpdate))[5].Text }
$rel = 'C:\Users\u\.herdr\packages\standalone\releases\0.9.3-x86_64-pc-windows-msvc'
Test-Case 'PATH で別の herdr が先なら、外すディレクトリを ※ で添える' "※ PATH のずれは Install-Herdr では直らない。$rel をユーザーの PATH から外す (herdr update で入ったもの。外し方は win/README.md の「herdr を入れる」)" { (Get-Rows (New-State @{ PathKind = 'other'; PathResolved = "$rel\herdr.exe" }))[6].Text }
Test-Case '置き場所が PATH に無ければ、足し直し方を ※ で添える' '※ herdr の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id Herdr.Herdr の後に Install-Herdr で入れ直す' { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[6].Text }
Test-Case '新しい版があれば ※ で知らせる' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Herdr.ps1 の -Version の既定値を変える" { (Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }))[6].Text }
Test-Case '入れ替えが要るのに herdr が動いていれば ※ で止め方を添える' '※ herdr の exe (herdr.exe・OpenConsole.exe) が 2 個動いている。入れ替えるには、herdr の外の PowerShell で hsvstop を打ち、herdr --remote の窓も閉じる' { (Get-Rows (New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up'; BusyCount = 2 }))[-1].Text }

# 締めの行。bootstrap-windows-herdr.sh と runner がこの字で枠の見出しと直し方を決める。
# Preview は product code で外す (Herdr.Herdr を並べて入れると、winget は Preview を Herdr.Herdr として数え、
# winget list --id Herdr.Herdr.Preview --exact では見つからなくなる。2026-11-09 に実機で確かめた)。
# pin は Preview を外した後に外す (先に打つと、Herdr.Herdr に結ばれた Preview の行に当たりうる)
function Get-Verdict { param($State) (@(Format-PortableVerdict -Tool $T -State $State) | ForEach-Object { "$_" }) -join "`n" }
$previewSteps = @(
    '⚠️   1. herdr の外の PowerShell (Windows Terminal など) で hsvstop を打ち、herdr --remote の窓も閉じる'
    '⚠️   2. winget uninstall --product-code Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe を打つ'
    '⚠️   3. winget pin remove --id Herdr.Herdr.Preview --exact を打つ (Preview の pin を外す)'
    '⚠️   4. 新しい PowerShell から herdr を起動し直す'
) -join "`n"
Test-Case '揃っていれば締めの行は出さない (Links の symlink の形でも)' '|' { "$(Get-Verdict (New-State))|$(Get-Verdict (New-State $linksForm))" }
Test-Case '入っていなければ、Install-Herdr で入れると出す' '⚠️ herdr が入っていない → Install-Herdr で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版・pin の差があれば、Install-Herdr で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Herdr で揃える ⚠️' { Get-Verdict (New-State @{ Pinned = $false }) }
Test-Case 'PATH で herdr update の herdr が先なら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の herdr が winget の portable のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State $herdrUpdate) }
Test-Case 'Preview が残っていれば、外す手順を出す' "⚠️ Herdr.Herdr.Preview が残っている → 次の手順で外す (Install-Herdr は外さない) ⚠️`n$previewSteps" { Get-Verdict (New-State $previewOnPath) }
Test-Case '差があって Preview も残っていれば、揃える行と Preview を外す手順を出す' "⚠️ 固定した版と揃っていない → Install-Herdr で揃える ⚠️`n⚠️ Herdr.Herdr.Preview が残っている → 次の手順で外す (Install-Herdr は外さない) ⚠️`n$previewSteps" { Get-Verdict (New-State ($previewLeft + @{ Pinned = $false })) }
Test-Case 'Herdr.Herdr が入っていなければ、入れてから Preview を外すと出す' "⚠️ herdr が入っていない → Install-Herdr で入れる ⚠️`n⚠️ Herdr.Herdr.Preview が残っている → Herdr.Herdr を入れてから、次の手順で外す (Install-Herdr は外さない) ⚠️`n$previewSteps" { Get-Verdict (New-State $previewOnly) }
Test-Case '昇格した PowerShell で入れられなければ、昇格の 1 行だけ (Preview が残っていても)' '⚠️ 昇格した PowerShell では winget が herdr を入れない (winget 1.30 から) → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($previewOnly + @{ Elevated = $true; Route = 'elevated' })) }

# Read-HerdrState: Preview の置き場所に herdr.exe があれば残っているとみなす
$previewRoot = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-tests-preview-$PID"
$previewTool = New-Tool @{ PackageDir = "$previewRoot\Herdr.Herdr_Microsoft.Winget.Source_8wekyb3d8bbwe" }
Test-Case 'Preview の置き場所に herdr.exe が無ければ、残っていない' 'False' { (Read-HerdrState -Tool $previewTool -State (New-State)).PreviewExists }
New-Item -ItemType File -Force -Path "$previewRoot\$PreviewProductCode\herdr.exe" | Out-Null
Test-Case 'Preview の置き場所に herdr.exe があれば、残っている' 'True' { (Read-HerdrState -Tool $previewTool -State (New-State)).PreviewExists }
Remove-Item -LiteralPath $previewRoot -Recurse -Force

# 本物の Get-PortableState に herdr の表を渡し、葉 (ファイルの有無・Join-Path・exe の版・winget・PATH・symlink・昇格・動いている exe) だけを
# 偽物にして、herdr の custom の口 (PathKind・ReadState) が状態に入るかを見る。偽物は Get-WiredHerdrState の中で定義し、外に漏らさない
function Get-WiredHerdrState {
    param([hashtable]$World = @{})
    $wired = @{ Files = @("$Pkg\herdr.exe"); PathValue = "C:\Windows;$Pkg"; Links = @{} }
    foreach ($k in $World.Keys) { $wired[$k] = $World[$k] }
    function Test-Path { param([string]$LiteralPath, [string]$PathType) $wired.Files -contains $LiteralPath }
    function Join-Path { param([Parameter(Position = 0)][string]$Path, [Parameter(Position = 1)][string]$ChildPath) "$($Path.TrimEnd('\'))\$ChildPath" }
    function Get-PortableInstalledVersion { param($Exe, $Pattern) $V }
    function Invoke-Winget {
        param([string[]]$Arguments)
        $lines = switch ($Arguments[0]) {
            '--version' { @('v1.30.310') }
            'pin' { @("herdr $Id $V winget Pinning") }
            'show' { @('Version', '-------', $V, $Older) }
            default { @() }
        }
        [pscustomobject]@{ ExitCode = 0; Lines = @($lines) }
    }
    function Get-PortablePathValue { $wired.PathValue }
    function Get-PortableLinkTarget { param($Path) $wired.Links[$Path] }
    function Test-WingetElevated { $false }
    function Get-PortableBusyProcess { param($Tool) @() }
    Get-PortableState -Tool $T -Target $V
}
$wiredLinks = @("$Pkg\herdr.exe", "$Links\herdr.exe")
Test-Case '本物の Get-PortableState: 開発者モードが on の PC (WinGet\Links の symlink が Herdr.Herdr を指す) は links で揃い' 'links False 0' {
    $s = Get-WiredHerdrState @{ Files = $wiredLinks; PathValue = "$Links;C:\Windows"; Links = @{ "$Links\herdr.exe" = "$Pkg\herdr.exe" } }
    "$($s.PathKind) $($s.PreviewExists) $(Get-PortableExitCode -Tool $T -State $s)"
}
Test-Case '本物の Get-PortableState: WinGet\Links の symlink が Preview を指せば preview と読み、Preview が残っているので 1' "preview True 1|⚠ PATH の herdr   : $Links\herdr.exe → $PreviewPkg\herdr.exe (Herdr.Herdr.Preview のもの)" {
    $s = Get-WiredHerdrState @{ Files = $wiredLinks + @("$PreviewPkg\herdr.exe"); PathValue = "$Links;$Pkg"; Links = @{ "$Links\herdr.exe" = "$PreviewPkg\herdr.exe" } }
    "$($s.PathKind) $($s.PreviewExists) $(Get-PortableExitCode -Tool $T -State $s)|$((Get-Rows $s)[5].Text)"
}

# ---------------------------------------------------------------------------
# 入口から流れまで (Start-WingetPortable に herdr の表を渡す)。Windows に触る関数を偽物に差し替えて、打つ winget の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
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
function Get-PortableState { param($Tool, $Target) $script:States.Dequeue() }
function Get-PortableBusyProcess { param($Tool) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'herdr.exe server' } }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-PortableState が返す順 (揃える前と、揃えた後に読み直したもの)
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
    $out = @(Start-WingetPortable -Tool (Get-HerdrTool) -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
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
Test-Case 'Links の symlink の形で揃っていれば何も打たない (開発者モードが on の PC)' '0 []' { $r = Invoke-Flow -States @((New-State $linksForm)) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '動いている herdr があれば、winget を 1 つも打たずに止まり、止め方と PID を出す' '1 [] True' { $r = Invoke-Flow -States @((New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up'; BusyCount = 2 })) -Busy 2 -ExeExists; "$($r.Code) [$($r.Calls)] $(($r.Text -like '*hsvstop*') -and ($r.Text -like '*1001*herdr.exe server*'))" }
Test-Case '入れ替えは取得を確かめてから pin を外し、uninstall → install して pin を足す' '0 [download pin remove uninstall install pin list pin add]' { $r = Invoke-Flow -States @((New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up'; Pinned = $true }), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'uninstall の後に install が落ちたら、入れ直し方を出す' 'True' { $r = Invoke-Flow -States @($changeState, (New-State $missing)) -Fail @{ install = 1 } -ExeExists; ($r.Code -eq 1) -and ($r.Text -like '*Install-Herdr を打ち直す (dotfiles apply・setup --update でも入る)*') }
Test-Case 'PATH で herdr update の herdr が先なだけなら、winget を打たずに 1 で止まり、※ の手順で直すと出す' '1 [] True' { $r = Invoke-Flow -States @((New-State $herdrUpdate)) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*→ ※ の手順で直す*')" }

# Herdr.Herdr.Preview が残っているとき。Preview は外さず (pin remove も uninstall も打たない)、外す手順を出す
$previewState = New-State $previewOnPath
Test-Case '-Check は Preview が残っていれば 1 で、winget は打たない。外す手順を出し、揃っているとは言わない' '1 [] True' { $r = Invoke-Flow -States @($previewState) -Check -ExeExists; "$($r.Code) [$($r.Calls)] $(($r.Text -like "*winget uninstall --product-code $PreviewProductCode*") -and ($r.Text -notlike '*揃っている*'))" }
Test-Case '-IfMissing は Preview が残っていても、Herdr.Herdr が無ければ並べて入れて pin を足す' '1 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $previewOnly), $previewState) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '並べて入れた後は、Herdr.Herdr は揃ったと出し、Preview を外す手順を出す (Install-Herdr で揃えるとは言わない)' $true { $r = Invoke-Flow -States @((New-State $previewOnly), $previewState) -IfMissing; ($r.Text -like "*$Id は揃った*") -and ($r.Text -like "*winget uninstall --product-code $PreviewProductCode*") -and ($r.Text -notlike '*Install-Herdr で揃える*') }
Test-Case '揃えるとき、残っているのが Preview だけなら winget を打たずに 1 で止まり、Herdr.Herdr は揃っていると出す' '1 [] True' { $r = Invoke-Flow -States @($previewState) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)] $(($r.Text -like "*$Id は揃っている*") -and ($r.Text -like "*winget pin remove --id $PreviewId --exact*"))" }
Test-Case '揃えるとき、pin が無くて Preview も残っていれば、pin だけ足して Preview を外す手順を出す' '1 [pin list pin add] True' { $r = Invoke-Flow -States @((New-State ($previewOnPath + @{ Pinned = $false })), $previewState) -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like "*winget uninstall --product-code $PreviewProductCode*")" }
$changeWithPreview = New-State ($previewOnPath + @{ Installed = $Older; Plan = 'change'; Direction = 'up' })
Test-Case '入れ替えが要るのに Preview が残っていれば、winget を 1 つも打たずに止まり、先に Preview を外すよう手順を出す' '1 [] True' { $r = Invoke-Flow -States @($changeWithPreview) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)] $(($r.Text -like "*先に $PreviewId を外*") -and ($r.Text -like "*winget uninstall --product-code $PreviewProductCode*"))" }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
