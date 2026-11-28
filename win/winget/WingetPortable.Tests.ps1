# win/winget/WingetPortable.ps1 (winget の portable の道具の共通の枠) のうち、副作用の無い関数と、Windows に触る関数を偽物に差し替えた流れの
# テスト。Pester は使わない。道具ごとの値 (版の拾い方・exe の置き場所・MSI・見出しと締めの行の字) と custom の口の中身は、道具ごとの
# Install-*.Tests.ps1 が確かめる。winget やプロセスに触る本物の部分は、実機で -Check と本番を打って確かめる (win/README.md の
# 「winget の portable の道具」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/winget/WingetPortable.Tests.ps1
#
# ## 確かめること
#
#   - 道具の表: 既定の値で埋め、必須の key が無い・知らない key・知らない custom の口なら止める
#   - winget show --versions の版の行だけを新しい順に拾い、winget --version から winget 自身の版を拾う
#   - 入っていなければ install、版が違う・読めなければ change、版が同じで道具が入れ直すと決めれば relink、ほかは none
#   - install は portable を名指しし (表の InstallerType)、change と relink は uninstall → install (どれも upgrade を打たず、
#     --include-pinned も付けない)。取得だけを確かめる winget download も同じ installer を名指しする
#   - PATH で引かれるもの (WinGet\Links なら links、置き場所の exe のディレクトリなら package、custom の種類、ほかは other)。WinGet\Links の
#     symlink がほかのパッケージを指せば links にせず、指す先を出して、WinGet\Links を PATH から外させない直し方を添える
#   - 本物の Get-PortableState を、葉 (ファイルの有無・winget・PATH・symlink・MSI・昇格・動いている exe) だけ偽物にして流し、読んだ値の入り先と、
#     custom の口 (PathKind・ReadState・Reinstall) が受け取るものを見る
#   - custom の口が $null を返しても、行・止める理由・見張りにしない
#   - 見張り: MSI の道具 (入れるかによらず)・道具の見張り・昇格した会話の winget 1.30 以降 (入れる・入れ替える・入れ直すときだけ)。
#     当たれば終了コードは 1 (入っていなくても 3 にしない)、締めの行はその 1 行だけ、揃える流れは winget を 1 つも打たない
#   - 終了コード (揃っていれば 0・差があれば 1・入っていなければ 3)・状態の表の行・締めの行 (runner と WSL の wrapper が読む字)
#   - custom の口が、決まった段で呼ばれ、表と締めの行の決まった所に行を足す
#   - 流れ: -Check と -IfMissing は入れ替えない。揃える流れは取得を確かめてから外して入れ、pin を足す。動いている exe があれば・
#     取得が落ちたら・固定した版が winget に無ければ、何も変えずに止まる。人が直すことだけなら winget を打たない
#   - 入口 (Install-*.ps1): 配った写し (隣の WingetPortable.ps1) からも clone からも枠を読み、枠が無ければ終了コード 2。
#     版の知らせが読む 2 行 ([string]$Version = '<版>'・$packageId = '<ID>') を持つ
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'WingetPortable.ps1')

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

# 見本の道具 (Example.Tool)。tool.exe は置き場所の直下
$Id = 'Example.Tool'
$V = '1.2.0'
$Older = '1.1.0'
$Newer = '1.3.0'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Example.Tool_Microsoft.Winget.Source_8wekyb3d8bbwe'
$Links = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links'
$Msi = 'C:\Program Files\tool\bin\tool.exe'
$Pattern = '^\s*tool\s+v?(?<v>\d+(\.\d+)+)(\s|$)'

function New-RawTool {
    param([hashtable]$Change = @{})
    $t = @{
        Name = 'tool'; Command = 'Install-Tool'; PackageId = $Id; CommandName = 'tool'; Readme = 'tool の節'; VersionPattern = $Pattern
        PackageDir = $Pkg; LinksDir = $Links
    }
    foreach ($k in $Change.Keys) { $t[$k] = $Change[$k] }
    $t
}
function New-Tool {
    param([hashtable]$Change = @{})
    Complete-PortableTool -Tool (New-RawTool $Change)
}
$T = New-Tool

# ---------------------------------------------------------------------------
# 道具の表
# ---------------------------------------------------------------------------

Test-Case '既定の値: exe は <CommandName>.exe、探さない、版の字は <exe> --version' 'tool.exe tool.exe False tool.exe --version' { "$($T.ExePath) $($T.ExeName) $($T.ExeSearch) $($T.VersionLabel)" }
Test-Case '既定の値: portable を名指しし、install に足す引数は無い' 'portable 0' { "$($T.InstallerType) $(@($T.InstallArguments).Count)" }
Test-Case '既定の値: MSI は見ない・custom の口は無い' 'True 0' { "$($null -eq $T.Msi) $($T.Hooks.Count)" }
Test-Case '既定の値: 動いているものの字・揃った主語・打ち直しの手' 'tool.exe|動いている tool を終わらせる|版と pin|dotfiles apply' { "$($T.BusyName)|$($T.BusyFix)|$($T.Synced)|$($T.Retry)" }
Test-Case '既定の値: PATH の直し方' '{0} の {1} を消すか、{0} をユーザーの PATH から外す (win/README.md の「tool の節」)|tool の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id Example.Tool の後に Install-Tool で入れ直す' { "$($T.PathOtherFix)|$($T.PathNoneFix)" }
Test-Case '既定の値: PATH の行の字 (links と package)' 'winget の portable のもの (WinGet\Links の symlink)|winget の portable のもの (置き場所)' { "$($T.PathTexts.links)|$($T.PathTexts.package)" }
Test-Case 'ExePath を並べれば配列のまま、ExeName は 1 つ目の名前' 'a\x.exe b\x.exe|x.exe' { $t = New-Tool @{ ExePath = @('a\x.exe', 'b\x.exe') }; "$($t.ExePath)|$($t.ExeName)" }
Test-Case 'InstallerType に $null を渡せば名指ししない' 'True' { $null -eq (New-Tool @{ InstallerType = $null }).InstallerType }
Test-Case 'PathTexts は既定に重ねる' 'x|winget の portable のもの (置き場所)|y' { $t = New-Tool @{ PathTexts = @{ links = 'x'; preview = 'y' } }; "$($t.PathTexts.links)|$($t.PathTexts.package)|$($t.PathTexts.preview)" }
Test-Case '置き場所と Links の既定は %LOCALAPPDATA% の下' 'True True' {
    $saved = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = 'L'
        $raw = New-RawTool
        $raw.Remove('PackageDir')
        $raw.Remove('LinksDir')
        $t = Complete-PortableTool -Tool $raw
        "$($t.PackageDir -eq (Join-Path 'L' 'Microsoft\WinGet\Packages\Example.Tool_Microsoft.Winget.Source_8wekyb3d8bbwe')) $($t.LinksDir -eq (Join-Path 'L' 'Microsoft\WinGet\Links'))"
    } finally {
        $env:LOCALAPPDATA = $saved
    }
}
Test-Case '必須の key が無ければ止める' 'ERROR: 道具の表に Command が無い' { $raw = New-RawTool; $raw.Remove('Command'); Complete-PortableTool -Tool $raw }
Test-Case '知らない key があれば止める (綴りの誤りを通さない)' 'ERROR: 道具の表に知らない key がある: BusyFixx' { New-Tool @{ BusyFixx = 'x' } }
Test-Case '知らない custom の口があれば止める' 'ERROR: 道具の表の Hooks に知らない口がある: Before' { New-Tool @{ Hooks = @{ Before = 'x' } } }
Test-Case '埋めた表を埋め直しても同じ' 'tool.exe portable' { $t = Complete-PortableTool -Tool $T; "$($t.ExePath) $($t.InstallerType)" }

# Join-PortablePath: \ で区切った相対パスを Join-Path で組む
Test-Case '\ で区切った相対パスを組む' (Join-Path (Join-Path 'R' 'a') 'b.exe') { Join-PortablePath -Root 'R' -Relative 'a\b.exe' }
Test-Case '名前だけなら Join-Path と同じ' (Join-Path 'R' 'b.exe') { Join-PortablePath -Root 'R' -Relative 'b.exe' }

# ---------------------------------------------------------------------------
# 版・winget の版・昇格
# ---------------------------------------------------------------------------

Test-Case 'パターンの組 v から版を拾う' $V { Get-PortableVersionFromOutput -Lines @("tool $V (abc)") -Pattern $Pattern }
Test-Case 'ほかの行が先にあっても拾う・行末の CR を飛ばす' $V { Get-PortableVersionFromOutput -Lines @('warning', "  tool $V`r") -Pattern $Pattern }
Test-Case '版の行が無ければ空' '' { Get-PortableVersionFromOutput -Lines @('error') -Pattern $Pattern }

$show = @(
    'Found tool [Example.Tool]'
    'Version'
    '-------'
    $Newer
    $V
    $Older
    '1.0.0-rc.1'
)
Test-Case '版の行だけを拾う (見出し・区切りは拾わない。- の付いた版も拾う)' "$Newer $V $Older 1.0.0-rc.1" { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }

Test-Case 'winget --version の v1.30.310 は 1.30.310' '1.30.310' { "$(Get-WingetClientVersion -Lines @('v1.30.310'))" }
Test-Case 'preview の v1.30.140-preview も読む' '1.30.140' { "$(Get-WingetClientVersion -Lines @('v1.30.140-preview'))" }
Test-Case '版の行が無ければ空' '' { Get-WingetClientVersion -Lines @('error') }
Test-Case '1.30 以降は新しい portable の扱い・1.29 は古い・読めなければ決めない' 'True False True' { "$(Test-WingetModernPortable -WingetVersion ([version]'1.30.0')) $(Test-WingetModernPortable -WingetVersion ([version]'1.29.380')) $($null -eq (Test-WingetModernPortable -WingetVersion $null))" }
Test-Case '昇格した会話で 1.30 以降なら elevated' 'elevated' { Get-WingetRoute -Elevated $true -WingetVersion ([version]'1.30.310') }
Test-Case '昇格した会話でも 1.29 以前なら direct (winget は断らない)' 'direct' { Get-WingetRoute -Elevated $true -WingetVersion ([version]'1.29.380') }
Test-Case '昇格した会話でも winget の版が読めなければ direct (打ってみる)' 'direct' { Get-WingetRoute -Elevated $true -WingetVersion $null }
Test-Case '昇格していなければ direct' 'direct' { Get-WingetRoute -Elevated $false -WingetVersion ([version]'1.30.310') }

# ---------------------------------------------------------------------------
# することと winget の引数
# ---------------------------------------------------------------------------

Test-Case '入っていなければ install' 'install' { Get-PortablePlan -Exists $false -Installed $null -Target $V }
Test-Case '同じ版なら none' 'none' { Get-PortablePlan -Exists $true -Installed $V -Target $V }
Test-Case '違う版なら change' 'change' { Get-PortablePlan -Exists $true -Installed $Newer -Target $V }
Test-Case 'exe があるのに版が読めなければ change' 'change' { Get-PortablePlan -Exists $true -Installed $null -Target $V }
Test-Case '同じ版でも、道具が入れ直すと決めれば relink' 'relink' { Get-PortablePlan -Exists $true -Installed $V -Target $V -Reinstall $true }
Test-Case '版が違えば、入れ直すより入れ替え (change)' 'change' { Get-PortablePlan -Exists $true -Installed $Older -Target $V -Reinstall $true }
Test-Case '入っていなければ、入れ直すより install' 'install' { Get-PortablePlan -Exists $false -Installed $null -Target $V -Reinstall $true }

$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '固定した版が新しければ up' 'up' { Get-PortableDirection -Versions $showVersions -Installed $Older -Target $V }
Test-Case '入っている版の方が新しければ down' 'down' { Get-PortableDirection -Versions $showVersions -Installed $Newer -Target $V }
Test-Case '同じなら same' 'same' { Get-PortableDirection -Versions $showVersions -Installed $V -Target $V }
Test-Case '入っている版が一覧に無ければ unknown' 'unknown' { Get-PortableDirection -Versions $showVersions -Installed '0.9.0' -Target $V }
Test-Case '一覧が読めなければ unknown' 'unknown' { Get-PortableDirection -Versions @() -Installed $Older -Target $V }

$pinsNow = @(
    'Name              Id                        Version     Source Pin type'
    '-----------------------------------------------------------------------'
    'OpenSSH           Microsoft.OpenSSH.Preview 10.0.0.0    winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsNow -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsNow + @("tool              $Id              $V       winget Pinning")) -PackageId $Id }
Test-Case 'Id の前方一致では True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id).Extra $V winget Pinning") -PackageId $Id }
Test-Case 'Id の大文字小文字が違えば True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id.ToLower()) $V winget Pinning") -PackageId $Id }

$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版と portable を名指しして入れる' "install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan install -Version $V)[0] -join ' ' }
Test-Case 'change は 2 本 (外してから入れる)' "uninstall $common|install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan change -Version $V | ForEach-Object { $_ -join ' ' }) -join '|' }
Test-Case 'relink も 2 本 (同じ版を外してから入れる)' "uninstall $common|install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan relink -Version $V | ForEach-Object { $_ -join ' ' }) -join '|' }
Test-Case 'none なら打たない' 0 { @(Get-WingetCommands -Tool $T -Plan none -Version $V).Count }
Test-Case 'InstallerType が無ければ名指ししない' "install $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Tool (New-Tool @{ InstallerType = $null }) -Plan install -Version $V)[0] -join ' ' }
Test-Case 'install に足す引数は --installer-type の後 (codex の --scope user --skip-dependencies)' "install $common --version $V --installer-type portable --scope user --skip-dependencies --accept-package-agreements" { @(Get-WingetCommands -Tool (New-Tool @{ InstallArguments = @('--scope', 'user', '--skip-dependencies') }) -Plan install -Version $V)[0] -join ' ' }
Test-Case 'どの plan も upgrade を打たず、--include-pinned も付けない' '' {
    @('install', 'change', 'relink', 'none') | ForEach-Object { @(Get-WingetCommands -Tool $T -Plan $_ -Version $V) } |
        Where-Object { ($_[0] -eq 'upgrade') -or (@($_) -contains '--include-pinned') } | ForEach-Object { $_ -join ' ' }
}
Test-Case '取得だけを確かめる winget download の引数 (portable を名指しする)' "download --id $Id --exact --source winget --version $V --installer-type portable --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -Tool $T -Version $V -Directory 'C:\tmp\dl') -join ' ' }
Test-Case 'InstallerType が無ければ download も名指ししない' "download --id $Id --exact --source winget --version $V --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -Tool (New-Tool @{ InstallerType = $null }) -Version $V -Directory 'C:\tmp\dl') -join ' ' }

Test-Case '0x8A15007D には、昇格していない PowerShell で打ち直す行を添える' '昇格した会話から user スコープの portable を扱うのを winget が断った (0x8A15007D)。昇格していない PowerShell で Install-Tool を打ち直す' { Get-WingetFailureHint -Tool $T -ExitCode -1978335107 }
Test-Case '0x8A150104 (依存を入れられない) には、依存を先に入れて打ち直す行を添える' 'winget が tool の依存のパッケージ (上の winget の行に出た VCRedist など) を入れられなかった (0x8A150104)。PowerShell で winget install --id <依存の ID> --exact を打って先に入れてから、Install-Tool を打ち直す (win/README.md の「tool の節」)' { Get-WingetFailureHint -Tool $T -ExitCode -1978334972 }
Test-Case 'ほかの終了コードには添えない' '' { Get-WingetFailureHint -Tool $T -ExitCode 1 }

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------

$exists = { param($p) $p -in @('C:\B\tool.exe', 'C:\A\tool.exe') }
Test-Case '前から見て最初に見つかったもの' 'C:\A\tool.exe' { Resolve-PortableOnPath -PathValue 'C:\A;C:\B' -Names @('tool.exe') -Exists $exists }
Test-Case '末尾の \・引用符・空白・空の要素を飛ばす' 'C:\B\tool.exe' { Resolve-PortableOnPath -PathValue ';; "C:\Z\" ; C:\B\ ;' -Names @('tool.exe') -Exists $exists }
Test-Case 'どこにも無ければ空' '' { Resolve-PortableOnPath -PathValue 'C:\Z;C:\Y' -Names @('tool.exe') -Exists $exists }
Test-Case '同じディレクトリなら名前を並べた順 (.exe が先)' 'C:\A\tool.exe' { Resolve-PortableOnPath -PathValue 'C:\A' -Names @('tool.exe', 'tool.cmd') -Exists { param($p) $true } }
Test-Case '前のディレクトリの .cmd (npm の global) が先に引かれる' 'C:\npm\tool.cmd' { Resolve-PortableOnPath -PathValue "C:\npm;$Pkg" -Names @('tool.exe', 'tool.cmd') -Exists { param($p) $p -in @('C:\npm\tool.cmd', "$Pkg\tool.exe") } }

Test-Case 'WinGet\Links の symlink なら links' 'links' { Get-PortablePathKind -Resolved "$Links\tool.exe" -ExeDir $Pkg -LinksDir $Links }
Test-Case '置き場所の exe のディレクトリなら package' 'package' { Get-PortablePathKind -Resolved "$Pkg\tool.exe" -ExeDir $Pkg -LinksDir $Links }
Test-Case '大文字小文字が違っても package' 'package' { Get-PortablePathKind -Resolved "$($Pkg.ToUpper())\tool.exe" -ExeDir $Pkg -LinksDir $Links }
Test-Case '置き場所の下でも exe のディレクトリでなければ other' 'other' { Get-PortablePathKind -Resolved "$Pkg\tool.exe" -ExeDir "$Pkg\tool_windows_amd64" -LinksDir $Links }
Test-Case 'ほかの場所なら other' 'other' { Get-PortablePathKind -Resolved 'C:\Users\u\scoop\shims\tool.exe' -ExeDir $Pkg -LinksDir $Links }
Test-Case '道具の custom の種類 (Links・置き場所でないとき)' 'preview' { Get-PortablePathKind -Resolved 'C:\P\tool.exe' -ExeDir $Pkg -LinksDir $Links -Custom 'preview' }
Test-Case 'Links・置き場所なら custom の種類より先' 'links' { Get-PortablePathKind -Resolved "$Links\tool.exe" -ExeDir $Pkg -LinksDir $Links -Custom 'preview' }
Test-Case '見つからなければ none' 'none' { Get-PortablePathKind -Resolved $null -ExeDir $Pkg -LinksDir $Links }
# WinGet\Links の symlink の指す先 (ほかのパッケージの同じ名前の symlink を links と読まない)
Test-Case 'Links の symlink が置き場所の exe を指せば links' 'links' { Get-PortablePathKind -Resolved "$Links\tool.exe" -ExeDir $Pkg -LinksDir $Links -LinkTarget "$Pkg\tool.exe" -PackageDir $Pkg }
Test-Case 'Links の symlink が置き場所の下 (exe のディレクトリでなくても) を指せば links' 'links' { Get-PortablePathKind -Resolved "$Links\tool.exe" -ExeDir "$Pkg\bin" -LinksDir $Links -LinkTarget "$($Pkg.ToUpper())\bin\tool.exe" -PackageDir $Pkg }
Test-Case 'Links の symlink がほかのパッケージを指せば other' 'other' { Get-PortablePathKind -Resolved "$Links\tool.exe" -ExeDir $Pkg -LinksDir $Links -LinkTarget 'C:\O\tool.exe' -PackageDir $Pkg }
Test-Case 'Links の symlink がほかを指せば、道具の custom の種類' 'preview' { Get-PortablePathKind -Resolved "$Links\tool.exe" -ExeDir $Pkg -LinksDir $Links -Custom 'preview' -LinkTarget 'C:\P\tool.exe' -PackageDir $Pkg }
Test-Case '名前の頭が同じだけのディレクトリ (置き場所 + X) は置き場所の下にしない' 'other' { Get-PortablePathKind -Resolved "$Links\tool.exe" -ExeDir $Pkg -LinksDir $Links -LinkTarget "${Pkg}X\tool.exe" -PackageDir $Pkg }
Test-Case 'Links の指す先が読めなければ links のまま' 'links' { Get-PortablePathKind -Resolved "$Links\tool.exe" -ExeDir $Pkg -LinksDir $Links -LinkTarget $null -PackageDir $Pkg }

Test-Case '\ で区切ったパスの親 (\ が無ければ空・末尾の \ は飛ばす)' 'C:\a|True|C:\a' { "$(Get-PortableParent -Path 'C:\a\b.exe')|$($null -eq (Get-PortableParent -Path 'b.exe'))|$(Get-PortableParent -Path 'C:\a\b\')" }
Test-Case '置き場所の下か (大文字小文字を区別しない・同じパスと頭が同じだけの名前は下にしない・空は下にしない)' 'True True False False False' {
    "$(Test-PortableUnder -Path 'C:\R\x.exe' -Root 'C:\R') $(Test-PortableUnder -Path 'c:\r\a\x.exe' -Root 'C:\R\') $(Test-PortableUnder -Path 'C:\R' -Root 'C:\R') $(Test-PortableUnder -Path 'C:\RX\x.exe' -Root 'C:\R') $(Test-PortableUnder -Path $null -Root 'C:\R')"
}

# ---------------------------------------------------------------------------
# 状態から決めること
# ---------------------------------------------------------------------------

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Exe = "$Pkg\tool.exe"; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = @($V, $Older); Latest = $V; PathResolved = "$Pkg\tool.exe"; PathLinkTarget = $null; PathKind = 'package'; BusyCount = 0
        MsiExe = $null; WingetVersion = [version]'1.30.310'; Elevated = $false; Route = 'direct'
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Exe = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 手で入れた新しい版 (pin も無い)
$handNewer = @{ Installed = $Newer; Plan = 'change'; Direction = 'down'; Pinned = $false; Versions = @($Newer, $V, $Older); Latest = $Newer }
$other = @{ PathKind = 'other'; PathResolved = 'C:\X\tool.exe' }
$elevated = @{ Elevated = $true; Route = 'elevated' }
# 状態の差し替えを重ねる (後ろが勝つ。hashtable の + は同じ key で止まる)
function Join-Change {
    $h = @{}
    foreach ($part in $args) { foreach ($k in $part.Keys) { $h[$k] = $part[$k] } }
    $h
}

Test-Case '揃っていれば差は無い' 'False False' { $s = New-State; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'pin が無ければ揃える手順で直る差' 'True False' { $s = New-State @{ Pinned = $false }; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case '入れ直すのも揃える手順で直る差' 'True' { Test-PortableDrift -Tool $T -State (New-State @{ Plan = 'relink' }) }
Test-Case 'PATH でほかのものが先なら、人が直す差 (揃える手順では直らない)' 'False True' { $s = New-State $other; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case '入っているのに PATH に無ければ PATH のずれ' 'True' { Test-PortablePathDrift -State (New-State @{ PathKind = 'none'; PathResolved = $null }) }
Test-Case '入っていないとき・入れ直すときに PATH に無いのは、ずれに数えない' 'False False' { "$(Test-PortablePathDrift -State (New-State $missing)) $(Test-PortablePathDrift -State (New-State @{ Plan = 'relink'; PathKind = 'none'; PathResolved = $null }))" }
Test-Case 'custom の種類は PATH のずれに数えない' 'False' { Test-PortablePathDrift -State (New-State @{ PathKind = 'preview'; PathResolved = 'C:\P\tool.exe' }) }

# 道具の custom の口 (この試験の関数)
function Test-SampleDrift { param($Tool, $State) $State.Installed -eq 'drift' }
function Test-SampleManual { param($Tool, $State) $State.Installed -eq 'manual' }
Test-Case '道具の Drift が $true なら揃える手順で直る差' 'True False' { $t = New-Tool @{ Hooks = @{ Drift = 'Test-SampleDrift' } }; $s = New-State @{ Installed = 'drift' }; "$(Test-PortableDrift -Tool $t -State $s) $(Test-PortableManual -Tool $t -State $s)" }
Test-Case '道具の Manual が $true なら人が直す差' 'False True' { $t = New-Tool @{ Hooks = @{ Manual = 'Test-SampleManual' } }; $s = New-State @{ Installed = 'manual' }; "$(Test-PortableDrift -Tool $t -State $s) $(Test-PortableManual -Tool $t -State $s)" }

# 見張り
$msiTool = New-Tool @{ Msi = 'tool\bin\tool.exe' }
$msiOnly = $missing.Clone()
$msiOnly.PathKind = 'other'
$msiOnly.PathResolved = $Msi
$msiOnly.MsiExe = $Msi
function Get-SampleHold {
    param($Tool, $State)
    if ($State.Installed -eq 'old') {
        New-PortableHold -Name 'old' -Rows @(@{ Text = '⚠ 古い'; Warn = $true }) -Verdict '⚠️ 古い → ※ の手順で直す ⚠️' -Message '古いので止める'
    }
}
$holdTool = New-Tool @{ Hooks = @{ Holds = 'Get-SampleHold' } }
Test-Case '揃っていれば見張りは当たらない' 'True' { $null -eq (Get-PortableHold -Tool $T -State (New-State)) }
Test-Case 'MSI の道具があれば msi (入れるかによらず)' 'msi msi' { "$((Get-PortableHold -Tool $msiTool -State (New-State @{ MsiExe = $Msi })).Name) $((Get-PortableHold -Tool $msiTool -State (New-State $msiOnly)).Name)" }
Test-Case '昇格した会話で 1.30 以降の winget なら、入れる・入れ替える・入れ直すときは elevated' 'elevated elevated elevated' {
    @('install', 'change', 'relink') | ForEach-Object { (Get-PortableHold -Tool $T -State (New-State ($elevated + @{ Plan = $_ }))).Name }
}
Test-Case '昇格した会話でも、winget を打たない (pin を足すだけ) なら当たらない' 'True' { $null -eq (Get-PortableHold -Tool $T -State (New-State ($elevated + @{ Pinned = $false }))) }
Test-Case '道具の見張り (Holds) が返せば、それ' 'old' { (Get-PortableHold -Tool $holdTool -State (New-State @{ Installed = 'old' })).Name }
Test-Case '並ぶ順は MSI → 道具の見張り → 昇格' 'msi old' {
    $t = New-Tool @{ Msi = 'tool\bin\tool.exe'; Hooks = @{ Holds = 'Get-SampleHold' } }
    "$((Get-PortableHold -Tool $t -State (New-State @{ Installed = 'old'; MsiExe = $Msi })).Name) $((Get-PortableHold -Tool $holdTool -State (New-State ($elevated + @{ Installed = 'old'; Plan = 'change' }))).Name)"
}

Test-Case '揃っていれば 0' 0 { Get-PortableExitCode -Tool $T -State (New-State) }
Test-Case 'pin が無ければ 1' 1 { Get-PortableExitCode -Tool $T -State (New-State @{ Pinned = $false }) }
Test-Case '版が違えば 1' 1 { Get-PortableExitCode -Tool $T -State (New-State $handNewer) }
Test-Case 'PATH でほかのものが先なら 1' 1 { Get-PortableExitCode -Tool $T -State (New-State $other) }
Test-Case '入っていなければ 3' 3 { Get-PortableExitCode -Tool $T -State (New-State $missing) }
Test-Case 'MSI の道具があれば、portable が入っていなくても 1 (runner に入れにいかせない)' 1 { Get-PortableExitCode -Tool $msiTool -State (New-State $msiOnly) }
Test-Case 'MSI の道具があれば、portable が揃っていても 1' 1 { Get-PortableExitCode -Tool $msiTool -State (New-State @{ MsiExe = $Msi }) }
Test-Case '昇格した会話で入れられなければ、入っていなくても 1' 1 { Get-PortableExitCode -Tool $T -State (New-State ($missing + $elevated)) }
Test-Case '昇格した会話でも、揃っていれば 0' 0 { Get-PortableExitCode -Tool $T -State (New-State $elevated) }
Test-Case '道具の Drift・Manual でも 1' '1 1' { "$(Get-PortableExitCode -Tool (New-Tool @{ Hooks = @{ Drift = 'Test-SampleDrift' } }) -State (New-State @{ Installed = 'drift' })) $(Get-PortableExitCode -Tool (New-Tool @{ Hooks = @{ Manual = 'Test-SampleManual' } }) -State (New-State @{ Installed = 'manual' }))" }

# 止める理由
function Get-SampleBlocker { param($Tool, $State) if ($State.Installed -eq 'blocked') { 'Preview が残っているので止める'; '  1. 外す' } }
$blockTool = New-Tool @{ Hooks = @{ Blocker = 'Get-SampleBlocker' } }
Test-Case '入れられるなら止めない' '' { Get-PortableApplyBlocker -Tool $T -State (New-State $missing) -Target $V }
Test-Case '固定した版が winget に無ければ not-listed (入れるとき)' 'not-listed' { Get-PortableApplyBlocker -Tool $T -State (New-State $missing) -Target '0.9.0' }
Test-Case '固定した版が winget に無ければ not-listed (入れ直すときも。download が落ちる)' 'not-listed' { Get-PortableApplyBlocker -Tool $T -State (New-State @{ Plan = 'relink' }) -Target '0.9.0' }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-PortableApplyBlocker -Tool $T -State (New-State (Join-Change $handNewer @{ Versions = @() })) -Target $V }
Test-Case '入れ替えるのに動いていれば busy' 'busy' { Get-PortableApplyBlocker -Tool $T -State (New-State ($handNewer + @{ BusyCount = 1 })) -Target $V }
Test-Case '入れ直すのに動いていれば busy' 'busy' { Get-PortableApplyBlocker -Tool $T -State (New-State @{ Plan = 'relink'; BusyCount = 1 }) -Target $V }
Test-Case '入れるだけなら動いている数は見ない' '' { Get-PortableApplyBlocker -Tool $T -State (New-State ($missing + @{ BusyCount = 2 })) -Target $V }
Test-Case 'pin を足すだけなら止めない' '' { Get-PortableApplyBlocker -Tool $T -State (New-State @{ Pinned = $false; Versions = @(); BusyCount = 3 }) -Target 'x' }
Test-Case '道具の止める理由 (Blocker が行を返す) は custom。動いているより先' 'custom' { Get-PortableApplyBlocker -Tool $blockTool -State (New-State (Join-Change $handNewer @{ Installed = 'blocked'; BusyCount = 1 })) -Target $V }
Test-Case 'winget に無いのは道具の止める理由より先' 'not-listed' { Get-PortableApplyBlocker -Tool $blockTool -State (New-State (Join-Change $handNewer @{ Installed = 'blocked' })) -Target '0.9.0' }
# 口が $null を返しても「無い」と同じ (return $null も 1 つの値になり、@() で包むと数に入る)
function Get-NullHook { param($Tool, $State) $null }
function Get-NullRows { param($Tool, $State) $null; @{ Label = '別名'; Value = 'ある'; Warn = $false }; $null }
Test-Case 'Blocker が $null を返しても止めない' '' { Get-PortableApplyBlocker -Tool (New-Tool @{ Hooks = @{ Blocker = 'Get-NullHook' } }) -State (New-State $handNewer) -Target $V }
Test-Case 'Holds が $null を返しても見張りは当たらない' 'True' { $null -eq (Get-PortableHold -Tool (New-Tool @{ Hooks = @{ Holds = 'Get-NullHook' } }) -State (New-State $handNewer)) }
Test-Case '見張りの行に $null が混ざっても行にしない' '⚠ 古い|※ 直す' { @((New-PortableHold -Name 'x' -Rows @($null, @{ Text = '⚠ 古い'; Warn = $true }, $null, @{ Text = '※ 直す'; Warn = $false }) -Verdict 'v' -Message 'm').Rows | ForEach-Object { $_['Text'] }) -join '|' }

# ---------------------------------------------------------------------------
# 状態の表と締めの行
# ---------------------------------------------------------------------------

Test-Case '見出しは字の幅で 16 桁にそろえる' '入っている版    : |winget の最新版 : |PATH の tool    : |PATH の starship: |codex の別名    : ' { @('入っている版', 'winget の最新版', 'PATH の tool', 'PATH の starship', 'codex の別名' | ForEach-Object { Format-PortableLabel -Label $_ }) -join '|' }
Test-Case '16 桁を超える見出しはそのまま「: 」を続ける' 'PATH の starship-x: ' { Format-PortableLabel -Label 'PATH の starship-x' }

function Get-Rows { param($State, $Tool = $T) @(Format-PortableState -Tool $Tool -State $State -Target $V) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 6 行だけ' "tool (winget の $Id、$Pkg)|  入っている版    : $V|  固定した版      : $V → そのまま|  winget の最新版 : $V|  winget pin      : あり|  PATH の tool    : winget の portable のもの (置き場所)" { @(Get-Rows (New-State) | ForEach-Object { $_.Text }) -join '|' }
Test-Case 'WinGet\Links の symlink なら、その形と出す' '  PATH の tool    : winget の portable のもの (WinGet\Links の symlink)' { (Get-Rows (New-State @{ PathKind = 'links'; PathResolved = "$Links\tool.exe" }))[5].Text }
Test-Case '手で入れた新しい版から下げるとき' "⚠ 固定した版      : $V → 入れ替える (下げる)" { (Get-Rows (New-State $handNewer))[2].Text }
Test-Case '古い版から上げるとき' "⚠ 固定した版      : $V → 入れ替える (上げる)" { (Get-Rows (New-State @{ Installed = $Older; Plan = 'change'; Direction = 'up' }))[2].Text }
Test-Case '入れ直す (relink) ときの版の行は「そのまま」で ⚠ にしない' "  固定した版      : $V → そのまま" { (Get-Rows (New-State @{ Plan = 'relink' }))[2].Text }
Test-Case 'pin が無ければ ⚠' '⚠ winget pin      : 無し → 足す' { (Get-Rows (New-State @{ Pinned = $false }))[4].Text }
Test-Case '入っていなければ「入っていない」と「入れる」' "  入っている版    : 入っていない ⚠ 固定した版      : $V → 入れる" { $r = Get-Rows (New-State $missing); "$($r[1].Text) $($r[2].Text)" }
Test-Case '入っていないときに PATH に無いのは ⚠ にしない' '  PATH の tool    : 見つからない' { (Get-Rows (New-State $missing))[5].Text }
Test-Case '入っているのに PATH に無ければ ⚠ と、足し方の ※' "⚠ PATH の tool    : 見つからない|※ tool の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $Id の後に Install-Tool で入れ直す" { $r = Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }); "$($r[5].Text)|$($r[-1].Text)" }
Test-Case '版が読めないとき' '  入っている版    : 不明 (tool.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH でほかのものが先なら、その場所を ⚠ で出し、直し方を ※ で添える (ファイルの名前は引かれたもの)' '⚠ PATH の tool    : C:\Users\u\scoop\shims\tool.cmd (winget の portable のものではない)|※ PATH のずれは Install-Tool では直らない。C:\Users\u\scoop\shims の tool.cmd を消すか、C:\Users\u\scoop\shims をユーザーの PATH から外す (win/README.md の「tool の節」)' { $r = Get-Rows (New-State @{ PathKind = 'other'; PathResolved = 'C:\Users\u\scoop\shims\tool.cmd' }); "$($r[5].Text)|$($r[-1].Text)" }
Test-Case '道具の PathOtherFix で直し方を替えられる' '※ PATH のずれは Install-Tool では直らない。C:\X をユーザーの PATH から外す' { (Get-Rows (New-State $other) (New-Tool @{ PathOtherFix = '{0} をユーザーの PATH から外す' }))[-1].Text }
Test-Case 'winget show が失敗したら最新版は不明で、一覧についての ※/⚠ は出さない' '  winget の最新版 : 不明 (winget show が失敗) 6' { $r = Get-Rows (New-State @{ Versions = @(); Latest = $null }); "$($r[3].Text) $($r.Count)" }
Test-Case '新しい版があれば ※ で知らせる (⚠ にしない)' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Tool.ps1 の -Version の既定値を変える 0" { $r = Get-Rows (New-State @{ Versions = @($Newer, $V, $Older); Latest = $Newer }); "$($r[6].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '固定した版が winget から消えても、入っていれば ※ (入れ直すときも)' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える|※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { "$((Get-Rows (New-State @{ Versions = @($Newer, $Older); Latest = $Newer }))[6].Text)|$((Get-Rows (New-State @{ Plan = 'relink'; Versions = @($Newer, $Older); Latest = $Newer }))[6].Text)" }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @($Newer, $Older); Latest = $Newer })))[6].Text }
Test-Case '入れ替えが要るのに動いていれば ※ で添える' '※ tool.exe が 1 個動いている。入れ替えるには、動いている tool を終わらせる' { (Get-Rows (New-State ($handNewer + @{ BusyCount = 1 })))[-1].Text }
Test-Case '入れ替えが要らなければ動いている数は出さない' 6 { (Get-Rows (New-State @{ BusyCount = 2 })).Count }
Test-Case 'MSI の道具があれば、⚠ で場所を出し、外し方を ※ で添える (PATH のずれの ※ は出さない)' "⚠ MSI の tool (machine スコープ。winget の既定の installer) が入っている: $Msi|※ portable と二重にしないため、MSI があるうちは Install-Tool は何も入れない。PowerShell で winget uninstall --id $Id --exact --scope machine を打って MSI を外し (UAC の確認が出る)、Install-Tool を打ち直す (win/README.md の「tool の節」)|8" { $r = Get-Rows (New-State $msiOnly) $msiTool; "$($r[6].Text)|$($r[7].Text)|$($r.Count)" }
Test-Case '昇格した会話で入れられなければ、⚠ で知らせ、打ち直し方を ※ で添える' '⚠ 昇格した PowerShell では winget が tool を入れない (winget 1.30.310 は、昇格した会話から user スコープの portable を入れる・外すのを断る)。Install-Tool は winget を打たない|※ 昇格していない PowerShell (デスクトップの普通の端末) で Install-Tool を打ち直す (win/README.md の「winget の portable の道具」)' { $r = Get-Rows (New-State ($handNewer + $elevated)); "$($r[7].Text)|$($r[8].Text)" }
Test-Case '昇格の見張りの後にも PATH のずれの ※ は出す' '※ PATH のずれは Install-Tool では直らない。C:\X の tool.exe を消すか、C:\X をユーザーの PATH から外す (win/README.md の「tool の節」)' { (Get-Rows (New-State ($handNewer + $elevated + $other)))[-1].Text }
Test-Case '昇格した会話でも、pin を足すだけなら見張りの行は出さない' 6 { (Get-Rows (New-State ($elevated + @{ Pinned = $false }))).Count }

# custom の口で足す行
function Get-SampleRowsBefore { param($Tool, $State) @{ Label = '別名'; Value = 'ある'; Warn = $false } }
function Get-SampleRowsAfter { param($Tool, $State) @{ Label = '同梱の rg'; Value = '無い → 足す'; Warn = $true }; @{ Label = '化けた行'; Value = '1 行'; Warn = $true } }
function Get-SampleNotes { param($Tool, $State) @{ Text = '※ 自動更新が有効'; Warn = $false } }
$rowTool = New-Tool @{ Hooks = @{ RowsBeforePath = 'Get-SampleRowsBefore'; RowsAfterPath = 'Get-SampleRowsAfter'; Notes = 'Get-SampleNotes' } }
Test-Case 'RowsBeforePath は PATH の行の前、RowsAfterPath は後、Notes は終わりに足す' '  別名            : ある|  PATH の tool    : winget の portable のもの (置き場所)|⚠ 同梱の rg       : 無い → 足す|⚠ 化けた行        : 1 行|※ 自動更新が有効' { @((Get-Rows (New-State) $rowTool) | Select-Object -Skip 5 | ForEach-Object { $_.Text }) -join '|' }
Test-Case '足した行の ⚠ は Warn になる' 2 { @((Get-Rows (New-State) $rowTool) | Where-Object { $_.Warn }).Count }
Test-Case '行・終わりの行の口が $null を返しても行にしない (混ざった $null も除く)' '6 7 6' {
    "$((Get-Rows (New-State) (New-Tool @{ Hooks = @{ RowsBeforePath = 'Get-NullHook'; RowsAfterPath = 'Get-NullHook' } })).Count) $((Get-Rows (New-State) (New-Tool @{ Hooks = @{ RowsAfterPath = 'Get-NullRows' } })).Count) $((Get-Rows (New-State) (New-Tool @{ Hooks = @{ Notes = 'Get-NullHook' } })).Count)"
}
# WinGet\Links の symlink がほかを指すとき: 指す先も出し、WinGet\Links を PATH から外させない
$foreignLink = @{ PathKind = 'other'; PathResolved = "$Links\tool.exe"; PathLinkTarget = 'C:\O\tool.exe' }
Test-Case 'Links の symlink がほかのパッケージを指せば、指す先を ⚠ で出し、外し方を ※ で添える (表の PathOtherFix は使わない)' "⚠ PATH の tool    : $Links\tool.exe → C:\O\tool.exe (winget の portable のものではない)|※ PATH のずれは Install-Tool では直らない。$Links の tool.exe は C:\O\tool.exe を指す (ほかのパッケージの symlink)。指す先を入れたパッケージを winget uninstall で外すか、その symlink を消す (win/README.md の「tool の節」)" {
    $r = Get-Rows (New-State $foreignLink) (New-Tool @{ PathOtherFix = '{0} をユーザーの PATH から外す' }); "$($r[5].Text)|$($r[-1].Text)"
}
Test-Case 'custom の種類でも、Links の symlink なら {0} に指す先も入れる' "⚠ PATH の tool    : $Links\tool.exe → C:\P\tool.exe (Preview のもの)" { (Get-Rows (New-State @{ PathKind = 'preview'; PathResolved = "$Links\tool.exe"; PathLinkTarget = 'C:\P\tool.exe' }) (New-Tool @{ PathTexts = @{ preview = '{0} (Preview のもの)' } }))[5].Text }
Test-Case 'Links の symlink が置き場所を指せば (links) 指す先は出さない' '  PATH の tool    : winget の portable のもの (WinGet\Links の symlink) 6' { $r = Get-Rows (New-State @{ PathKind = 'links'; PathResolved = "$Links\tool.exe"; PathLinkTarget = "$Pkg\tool.exe" }); "$($r[5].Text) $($r.Count)" }
Test-Case 'Links の symlink がほかを指せば、締めの行は PATH のずれ' '⚠️ PATH の tool が winget の portable のものではない → ※ の手順で直す ⚠️' { (@(Format-PortableVerdict -Tool $T -State (New-State $foreignLink)) | ForEach-Object { "$_" }) -join "`n" }
Test-Case 'custom の種類の PATH は PathTexts の字 ({0} は引かれたもの)。入れる前でなければ ⚠' '⚠ PATH の tool    : C:\P\tool.exe (Preview のもの)' { (Get-Rows (New-State @{ PathKind = 'preview'; PathResolved = 'C:\P\tool.exe' }) (New-Tool @{ PathTexts = @{ preview = '{0} (Preview のもの)' } }))[5].Text }
Test-Case 'custom の種類の PATH は、入れる前なら ⚠ にしない' '  PATH の tool    : C:\P\tool.exe (Preview のもの)' { (Get-Rows (New-State (Join-Change $missing @{ PathKind = 'preview'; PathResolved = 'C:\P\tool.exe' })) (New-Tool @{ PathTexts = @{ preview = '{0} (Preview のもの)' } }))[5].Text }

function Get-Verdict { param($State, $Tool = $T) (@(Format-PortableVerdict -Tool $Tool -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '揃っていれば締めの行は出さない' '' { Get-Verdict (New-State) }
Test-Case '入っていなければ、入れると出す' '⚠️ tool が入っていない → Install-Tool で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版か pin の差があれば、揃えると出す' '⚠️ 固定した版と揃っていない → Install-Tool で揃える ⚠️' { Get-Verdict (New-State $handNewer) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の tool が winget の portable のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State $other) }
Test-Case '版の差と PATH のずれが両方あれば、両方を出す' "⚠️ 固定した版と揃っていない → Install-Tool で揃える ⚠️`n⚠️ PATH の tool が winget の portable のものではない → ※ の手順で直す ⚠️" { Get-Verdict (New-State ($handNewer + $other)) }
Test-Case 'MSI の道具があれば、MSI の 1 行だけ (入れる・揃えるとは言わない)' '⚠️ MSI の tool (machine スコープ) が入っている → ※ の手順で直す ⚠️|⚠️ MSI の tool (machine スコープ) が入っている → ※ の手順で直す ⚠️' { "$(Get-Verdict (New-State $msiOnly) $msiTool)|$(Get-Verdict (New-State ($handNewer + @{ MsiExe = $Msi })) $msiTool)" }
Test-Case '昇格した会話で入れられなければ、昇格の 1 行だけ (入っていなくても)' '⚠️ 昇格した PowerShell では winget が tool を入れない (winget 1.30 から) → ※ の手順で直す ⚠️|⚠️ 昇格した PowerShell では winget が tool を入れない (winget 1.30 から) → ※ の手順で直す ⚠️' { "$(Get-Verdict (New-State ($missing + $elevated)))|$(Get-Verdict (New-State ($handNewer + $elevated + $other)))" }
Test-Case '昇格した会話でも、pin を足すだけなら揃えると出す' '⚠️ 固定した版と揃っていない → Install-Tool で揃える ⚠️' { Get-Verdict (New-State ($elevated + @{ Pinned = $false })) }
Test-Case '入れ直す (relink) だけなら、揃えるの行は出さない (道具の Verdict が言う)' '' { Get-Verdict (New-State @{ Plan = 'relink' }) }
function Get-SampleVerdict { param($Tool, $State) "⚠️ 道具の行 ($($State.Plan)) ⚠️" }
$verdictTool = New-Tool @{ Hooks = @{ Verdict = 'Get-SampleVerdict' } }
Test-Case '道具の Verdict は、入れるときは「入れる」の後' "⚠️ tool が入っていない → Install-Tool で入れる ⚠️`n⚠️ 道具の行 (install) ⚠️" { Get-Verdict (New-State $missing) $verdictTool }
Test-Case '道具の Verdict は、ほかは「揃える」と PATH の行の間' "⚠️ 固定した版と揃っていない → Install-Tool で揃える ⚠️`n⚠️ 道具の行 (change) ⚠️`n⚠️ PATH の tool が winget の portable のものではない → ※ の手順で直す ⚠️" { Get-Verdict (New-State ($handNewer + $other)) $verdictTool }
Test-Case '道具の見張りがあれば、その 1 行だけ' '⚠️ 古い → ※ の手順で直す ⚠️' { Get-Verdict (New-State (Join-Change $handNewer @{ Installed = 'old' })) $holdTool }
Test-Case '締めの行の口が $null を返しても行にしない' '0 1' { $t = New-Tool @{ Hooks = @{ Verdict = 'Get-NullHook' } }; "$(@(Format-PortableVerdict -Tool $t -State (New-State)).Count) $(@(Format-PortableVerdict -Tool $t -State (New-State $handNewer)).Count)" }

# ---------------------------------------------------------------------------
# Windows に触る関数のうち、Linux でも確かめられるもの
# ---------------------------------------------------------------------------

# Get-PortableInstalledVersion: 起動できない exe (壊れた・0 バイト) でも例外で止まらず、版は空
$broken = Join-Path ([IO.Path]::GetTempPath()) "winget-portable-tests-broken-$PID.exe"
Set-Content -LiteralPath $broken -Value '' -NoNewline
if (-not $IsWindows) { chmod +x $broken }
Test-Case '起動できない exe なら版は空 (入れ替えの対象になる)' '' { Get-PortableInstalledVersion -Exe $broken -Pattern $Pattern }
Remove-Item -LiteralPath $broken -Force

# Find-PortableExe: 表の ExePath を前から見て、無ければ (ExeSearch なら) 置き場所の下を探す
$findRoot = Join-Path ([IO.Path]::GetTempPath()) "winget-portable-tests-find-$PID"
$x64 = Join-PortablePath -Root $findRoot -Relative 'tool_windows_amd64\tool.exe'
$arm64 = Join-PortablePath -Root $findRoot -Relative 'tool_windows_arm64\tool.exe'
$findTool = New-Tool @{ PackageDir = $findRoot; ExePath = 'tool_windows_amd64\tool.exe'; ExeSearch = $true }
Test-Case '置き場所が無ければ空' '' { Find-PortableExe -Tool $findTool }
New-Item -ItemType File -Force -Path $arm64 | Out-Null
Test-Case 'ExePath に無ければ、置き場所の下の同じ名前の exe を見つける' $arm64 { Find-PortableExe -Tool $findTool }
Test-Case 'ExeSearch でなければ探さない' '' { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot; ExePath = 'tool_windows_amd64\tool.exe' }) }
New-Item -ItemType File -Force -Path $x64 | Out-Null
Test-Case 'ExePath (\ 区切り) を先に見る' $x64 { Find-PortableExe -Tool $findTool }
Test-Case 'ExePath を並べれば前から見る' $arm64 { Find-PortableExe -Tool (New-Tool @{ PackageDir = $findRoot; ExePath = @('tool_windows_arm64\tool.exe', 'tool_windows_amd64\tool.exe') }) }
Remove-Item -LiteralPath $findRoot -Recurse -Force

# Find-PortableMsiExe: %ProgramFiles% と %ProgramFiles(x86)% の下を並べた順に見る
$pfRoot = Join-Path ([IO.Path]::GetTempPath()) "winget-portable-tests-pf-$PID"
$pf64 = Join-Path $pfRoot 'pf'
$pf86 = Join-Path $pfRoot 'pf86'
$pf64Exe = Join-PortablePath -Root $pf64 -Relative 'tool\bin\tool.exe'
$pf86Exe = Join-PortablePath -Root $pf86 -Relative 'tool\bin\tool.exe'
Test-Case 'MSI の exe が無ければ空' '' { Find-PortableMsiExe -ProgramFiles @($pf64, $pf86) -Relative 'tool\bin\tool.exe' }
New-Item -ItemType File -Force -Path $pf86Exe | Out-Null
Test-Case 'x86 の MSI (%ProgramFiles(x86)% の下) も見つける' $pf86Exe { Find-PortableMsiExe -ProgramFiles @($pf64, $pf86) -Relative 'tool\bin\tool.exe' }
New-Item -ItemType File -Force -Path $pf64Exe | Out-Null
Test-Case '両方にあれば %ProgramFiles% の下を先に見る' $pf64Exe { Find-PortableMsiExe -ProgramFiles @($pf64, $pf86) -Relative 'tool\bin\tool.exe' }
Test-Case 'ProgramFiles が無ければ (Linux の pwsh) 空' '' { Find-PortableMsiExe -ProgramFiles @($null, '') -Relative 'tool\bin\tool.exe' }
Remove-Item -LiteralPath $pfRoot -Recurse -Force

# Test-WingetElevated: token を読めなければ (Linux の pwsh では WindowsIdentity が無い) 昇格していないとして winget を打つ
Test-Case 'token を読めなければ昇格していないとする (管理者のロールで代えない)' 'False' { Test-WingetElevated }

# Get-PortableState: 本物の Get-PortableState を、葉 (ファイルの有無・Join-Path・exe の版・winget・PATH・symlink・MSI・昇格・動いている exe)
# だけ偽物にして流し、読んだ値が状態のどこに入るかと、custom の口 (PathKind・ReadState・Reinstall) が何を受け取るかを確かめる。偽物は
# Get-WiredState の中で定義するので、外の試験には漏れない (呼んだ関数からは、呼び出し元の関数が見える)
function Get-WiredState {
    param([hashtable]$World = @{}, [hashtable]$Change = @{})
    $wired = @{
        Files = @("$Pkg\tool.exe"); Installed = $V; Winget = 'v1.30.310'; Pinned = $true; PathValue = "C:\Windows;$Pkg"; Links = @{}
        Msi = $null; Elevated = $false; Busy = 0
    }
    foreach ($k in $World.Keys) { $wired[$k] = $World[$k] }
    function Test-Path { param([string]$LiteralPath, [string]$PathType) $wired.Files -contains $LiteralPath }
    function Join-Path { param([Parameter(Position = 0)][string]$Path, [Parameter(Position = 1)][string]$ChildPath) "$($Path.TrimEnd('\'))\$ChildPath" }
    function Get-PortableInstalledVersion { param($Exe, $Pattern) $wired.Installed }
    function Invoke-Winget {
        param([string[]]$Arguments)
        $lines = switch ($Arguments[0]) {
            '--version' { @($wired.Winget) }
            'pin' { if ($wired.Pinned) { @('Name Id Version Source Pin type', "tool $Id $V winget Pinning") } else { @('none') } }
            'show' { @('Found tool [Example.Tool]', 'Version', '-------', $Newer, $V, $Older) }
            default { @() }
        }
        [pscustomobject]@{ ExitCode = 0; Lines = @($lines) }
    }
    function Get-PortablePathValue { $wired.PathValue }
    function Get-PortableLinkTarget { param($Path) $wired.Links[$Path] }
    function Find-PortableMsiExe { param($ProgramFiles, $Relative) $wired.Msi }
    function Test-WingetElevated { $wired.Elevated }
    function Get-PortableBusyProcess { param($Tool) @(for ($i = 0; $i -lt $wired.Busy; $i++) { [pscustomobject]@{ Id = 1000 + $i } }) }
    Get-PortableState -Tool (New-Tool $Change) -Target $V
}
function Format-Wired { param($State) "$($State.Exists) $($State.Installed) $($State.Plan) $($State.Direction) $($State.Pinned) $($State.PathKind) $($State.Route)" }
# custom の口 (受け取った State の Plan と、ReadState が足した値を見る)
function Get-SampleWiredPathKind { param($Tool, $Resolved, $LinkTarget) if ((Test-PortableUnder -Path $LinkTarget -Root 'C:\P') -or (Test-PortableUnder -Path $Resolved -Root 'C:\P')) { 'preview' } }
function Read-SampleWiredState { param($Tool, $State) @{ Extra = 'x'; PlanSeen = ($null -eq $State.Plan) } }
function Test-SampleWiredReinstall { param($Tool, $State) ($State.Extra -eq 'x') -and ($null -eq $State.Plan) }

Test-Case '本物の Get-PortableState: 置き場所の exe が PATH で引かれ、版と pin が揃っている' 'True 1.2.0 none same True package direct' { Format-Wired (Get-WiredState) }
Test-Case '本物の Get-PortableState: winget の版の一覧・最新版・winget 自身の版・exe・動いている数・MSI・Links の指す先' "$Newer $V $Older|$Newer|1.30.310|$Pkg\tool.exe|0|True|True" {
    $s = Get-WiredState; "$($s.Versions)|$($s.Latest)|$($s.WingetVersion)|$($s.Exe)|$($s.BusyCount)|$($null -eq $s.MsiExe)|$($null -eq $s.PathLinkTarget)"
}
Test-Case '本物の Get-PortableState: 入っていなければ install (PATH に無いのは none)' 'False  install unknown True none direct' { Format-Wired (Get-WiredState @{ Files = @(); Installed = $null }) }
Test-Case '本物の Get-PortableState: 版が違えば change、pin が無ければ Pinned は False' 'True 1.1.0 change up False package direct' { Format-Wired (Get-WiredState @{ Installed = $Older; Pinned = $false }) }
Test-Case '本物の Get-PortableState: WinGet\Links の symlink が置き場所を指せば links (指す先も状態に入る)' "True 1.2.0 none same True links direct|$Pkg\tool.exe" {
    $s = Get-WiredState @{ Files = @("$Pkg\tool.exe", "$Links\tool.exe"); PathValue = "$Links;$Pkg"; Links = @{ "$Links\tool.exe" = "$Pkg\tool.exe" } }; "$(Format-Wired $s)|$($s.PathLinkTarget)"
}
Test-Case '本物の Get-PortableState: WinGet\Links の symlink がほかのパッケージを指せば other' 'other|C:\O\tool.exe' {
    $s = Get-WiredState @{ Files = @("$Pkg\tool.exe", "$Links\tool.exe"); PathValue = "$Links;$Pkg"; Links = @{ "$Links\tool.exe" = 'C:\O\tool.exe' } }; "$($s.PathKind)|$($s.PathLinkTarget)"
}
Test-Case '本物の Get-PortableState: PathKind の口は Links の指す先も受け取る' 'preview preview' {
    $c = @{ Hooks = @{ PathKind = 'Get-SampleWiredPathKind' } }
    $viaLink = Get-WiredState @{ Files = @("$Pkg\tool.exe", "$Links\tool.exe"); PathValue = "$Links;$Pkg"; Links = @{ "$Links\tool.exe" = 'C:\P\tool.exe' } } $c
    $direct = Get-WiredState @{ Files = @("$Pkg\tool.exe", 'C:\P\tool.exe'); PathValue = "C:\P;$Pkg" } $c
    "$($viaLink.PathKind) $($direct.PathKind)"
}
Test-Case '本物の Get-PortableState: Links の外の PATH では symlink を読まない' 'True' { $null -eq (Get-WiredState @{ Links = @{ "$Pkg\tool.exe" = 'C:\O\tool.exe' } }).PathLinkTarget }
Test-Case '本物の Get-PortableState: 昇格した会話で winget 1.30 以降なら elevated、1.29 なら direct' 'elevated direct' { "$((Get-WiredState @{ Elevated = $true }).Route) $((Get-WiredState @{ Elevated = $true; Winget = 'v1.29.380' }).Route)" }
Test-Case '本物の Get-PortableState: 表に Msi があれば MSI の exe を読み、動いている数を数える' "$Msi 2" { $s = Get-WiredState @{ Msi = $Msi; Busy = 2 } @{ Msi = 'tool\bin\tool.exe' }; "$($s.MsiExe) $($s.BusyCount)" }
Test-Case '本物の Get-PortableState: ReadState と Reinstall は Plan が決まる前の State を受け取り、Reinstall が $true なら relink' 'x True relink' {
    $s = Get-WiredState @{} @{ Hooks = @{ ReadState = 'Read-SampleWiredState'; Reinstall = 'Test-SampleWiredReinstall' } }; "$($s.Extra) $($s.PlanSeen) $($s.Plan)"
}

# ---------------------------------------------------------------------------
# 入口 (Install-*.ps1)。枠を使う入口を全部見る
# ---------------------------------------------------------------------------

$winDir = Split-Path -Parent $PSScriptRoot
$entries = @(Get-ChildItem -Path (Join-Path $winDir '*\Install-*.ps1') -File | Where-Object { $_.Name -notlike '*.Tests.ps1' } |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match '(?m)^\. \$frame\s*$' } | Sort-Object FullName)
Test-Case '枠を使う入口がある' 'True' { $entries.Count -gt 0 }
Test-Case '入口は版の知らせが読む 2 行 ([string]$Version の既定値・$packageId) を持つ' '' {
    @($entries | Where-Object {
            $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            ($text -notmatch "(?m)^\s*\[string\]\`$Version\s*=\s*'[^']+'") -or ($text -notmatch "(?m)^\s*\`$packageId\s*=\s*'[A-Za-z0-9][A-Za-z0-9.-]*'")
        } | ForEach-Object { $_.Name }) -join ' '
}
Test-Case '入口は BOM 付きの UTF-8 (枠も)' '' {
    @(@($entries) + @(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'WingetPortable.ps1')) | Where-Object {
            $bytes = [IO.File]::ReadAllBytes($_.FullName)
            -not (($bytes.Count -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF))
        } | ForEach-Object { $_.Name }) -join ' '
}
# 配った写し (%USERPROFILE%\.config\powershell) の形: 入口と枠が同じディレクトリに並ぶ。Linux の pwsh には $env:LOCALAPPDATA が無く、
# 枠を読めたら本体の最初で例外になり、終了コード 2 で止まる (成功 (0) に見せない)。枠が無ければ、配り直しを出して 2
$pwsh = (Get-Process -Id $PID).Path
$deployed = Join-Path ([IO.Path]::GetTempPath()) "winget-portable-tests-deployed-$PID"
foreach ($entry in $entries) {
    Remove-Item -LiteralPath $deployed -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $deployed | Out-Null
    Copy-Item -LiteralPath $entry.FullName -Destination $deployed
    $copy = Join-Path $deployed $entry.Name
    Test-Case "$($entry.Name): 枠が隣に無ければ、配り直しを出して終了コード 2" '2 True' {
        $out = @(& $pwsh -NoProfile -NonInteractive -File $copy -Check 2>&1 | ForEach-Object { "$_" })
        "$LASTEXITCODE $(($out -join "`n") -like '*共通の枠 (WingetPortable.ps1)*')"
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WingetPortable.ps1') -Destination $deployed
    Test-Case "$($entry.Name): 隣の枠を読み、思わぬ例外では終了コード 2 で止まる" '2 True' {
        $out = @(& $pwsh -NoProfile -NonInteractive -File $copy -Check 2>&1 | ForEach-Object { "$_" })
        "$LASTEXITCODE $(($out -join "`n") -like '*エラーで止まった*')"
    }
    Test-Case "$($entry.Name): clone の win\winget\ の枠を読み、思わぬ例外では終了コード 2 で止まる" '2 True' {
        $out = @(& $pwsh -NoProfile -NonInteractive -File $entry.FullName -Check 2>&1 | ForEach-Object { "$_" })
        "$LASTEXITCODE $(($out -join "`n") -like '*エラーで止まった*')"
    }
}
Remove-Item -LiteralPath $deployed -Recurse -Force -ErrorAction SilentlyContinue
Test-Case 'Start-WingetPortable は表の誤りでも終了コード 2 を返す' 2 { $raw = New-RawTool; $raw.Remove('Name'); @(Start-WingetPortable -Tool $raw -Version $V -Check 6>$null)[-1] }

# ---------------------------------------------------------------------------
# Invoke-WingetPortable の流れ。Windows に触る関数を偽物に差し替えて、打つ winget の順と、途中で失敗したときの扱いと、custom の口を
# 呼ぶ段を確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$FlowPkg = Join-Path ([IO.Path]::GetTempPath()) "winget-portable-tests-flow-$PID"
$FakeExe = Join-Path $FlowPkg 'tool.exe'

# Get-Command winget を通すためだけの関数 (呼ばれるのは下の Invoke-Winget)
function winget { }
# 打った winget を記録する (pin は 'pin add' のように 2 語)。install は exe を置き、uninstall は消す
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = if ($Arguments[0] -eq 'pin') { "pin $($Arguments[1])" } else { $Arguments[0] }
    $script:Calls.Add($verb)
    $code = 0
    if ($script:Fail.ContainsKey($verb)) { $code = $script:Fail[$verb] }
    if (($code -eq 0) -and ($verb -eq 'install')) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    if (($code -eq 0) -and ($verb -eq 'uninstall')) { Remove-Item -LiteralPath $FakeExe -Force -ErrorAction SilentlyContinue }
    $lines = @()
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("tool $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Get-PortableState { param($Tool, $Target) $script:States.Dequeue() }
function Get-PortableBusyProcess { param($Tool) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'tool.exe run' } }
# custom の口 (どの段で呼ばれたかを記録する)
function Invoke-SampleBefore { param($Tool, $State) $script:Calls.Add('before') }
function Invoke-SampleAfter { param($Tool, $State) $script:Calls.Add('after') }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-PortableState が返す順 (揃える前と、揃えた後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [hashtable]$Fail = @{}, [int]$Busy = 0, [switch]$ExeExists, [switch]$PinListed, [hashtable]$Change = @{})
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:Busy = @()
    if ($Busy -gt 0) { $script:Busy = @(1..$Busy | ForEach-Object { [pscustomobject]@{ Id = 1000 + $_ } }) }
    $script:PinListed = [bool]$PinListed
    Remove-Item -LiteralPath $FlowPkg -Recurse -Force -ErrorAction SilentlyContinue
    if ($ExeExists) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    $raw = New-RawTool (@{ PackageDir = $FlowPkg } + $Change)
    $out = @(Invoke-WingetPortable -Tool $raw -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
        Ints  = @($out | Where-Object { $_ -is [int] }).Count
    }
}

$changeState = New-State $handNewer
$synced = New-State
Test-Case '-Check は winget を打たない' '1 []' { $r = Invoke-Flow -States @($changeState) -Check -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check で揃っていれば 0 と「揃っている」' '0 True' { $r = Invoke-Flow -States @($synced) -Check -ExeExists; "$($r.Code) $($r.Text -like '*揃っている*')" }
Test-Case '-IfMissing は入っていれば何も打たない (版がずれていても入れ替えない)' '1 []' { $r = Invoke-Flow -States @($changeState) -IfMissing -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ install して pin を足す' '0 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '揃っていれば何も打たない' '0 []' { $r = Invoke-Flow -States @($synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'pin だけ無ければ pin を足すだけ' '0 [pin list pin add]' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false }), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '下げる入れ替えも、取得を確かめてから uninstall → install して pin を足す' '0 [download uninstall install pin list pin add]' { $r = Invoke-Flow -States @($changeState, $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
$pinnedNewer = $handNewer.Clone()
$pinnedNewer.Pinned = $true
Test-Case 'pin があれば、入れ替えの前に外す' '0 [download pin remove uninstall install pin list pin add]' { $r = Invoke-Flow -States @((New-State $pinnedNewer), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '入れ直す (relink) も、取得を確かめてから pin を外し、uninstall → install して pin を足す' '0 [download pin remove uninstall install pin list pin add]' { $r = Invoke-Flow -States @((New-State @{ Plan = 'relink' }), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '動いていれば、winget を 1 つも打たずに止まり、PID とコマンドラインを出す' '1 [] True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*1001*tool.exe run*')" }
Test-Case '取得が落ちたら、何も変えずに止まる' '1 [download] True' { $r = Invoke-Flow -States @($changeState) -Fail @{ download = 1 } -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*何も変えていない*')" }
Test-Case 'uninstall が落ちたら install せず、pin を足す (入っている版は残る)' '1 [download uninstall pin list pin add]' { $r = Invoke-Flow -States @($changeState, $changeState) -Fail @{ uninstall = 1 } -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'uninstall の後に install が落ちたら、入れ直し方を出す' 'True True' { $r = Invoke-Flow -States @($changeState, (New-State $missing)) -Fail @{ install = 1 } -ExeExists; "$($r.Code -eq 1) $($r.Text -like '*Install-Tool を打ち直す (dotfiles apply でも入る)*')" }
Test-Case '0x8A15007D で落ちたら、昇格していない PowerShell で打ち直す行を添える' 'True' { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -Fail @{ install = -1978335107 }; $r.Text -like '*0x8A15007D*昇格していない PowerShell で Install-Tool を打ち直す*' }
Test-Case 'install が依存で落ちたら (0x8A150104)、依存を先に入れて打ち直す行と、入れ直し方を出す' '1 [install pin list] True' {
    $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -Fail @{ install = -1978334972 }
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*winget が失敗した (終了コード 0x8A150104)*winget install --id <依存の ID> --exact を打って先に入れてから*Install-Tool を打ち直す*')"
}
Test-Case '昇格した会話で pin を足すだけのとき、winget が断ったら (0x8A15007D) 打ち直す行を添える' '1 [pin list pin add] True' {
    $pinOnly = New-State ($elevated + @{ Pinned = $false })
    $r = Invoke-Flow -States @($pinOnly, $pinOnly) -ExeExists -Fail @{ 'pin add' = -1978335107 }
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*pin add が失敗した (終了コード 0x8A15007D)*昇格していない PowerShell で Install-Tool を打ち直す*')"
}
Test-Case 'pin を外すのを winget が断っても (0x8A15007D)、打ち直す行を添える' 'True' { $r = Invoke-Flow -States @((New-State $pinnedNewer), $synced) -ExeExists -Fail @{ 'pin remove' = -1978335107 }; $r.Text -like '*pin remove が失敗した (終了コード 0x8A15007D)*昇格していない PowerShell で Install-Tool を打ち直す*' }
Test-Case '固定した版が winget に無ければ、winget を打たずに止まる' '1 []' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @($Newer); Latest = $Newer }))); "$($r.Code) [$($r.Calls)]" }
$pathOnly = New-State $other
Test-Case 'PATH のずれだけなら winget を打たずに 1 で止まり、※ の手順で直すと出す' '1 [] True' { $r = Invoke-Flow -States @($pathOnly) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*※ の手順で直す*')" }
Test-Case '揃えた後も PATH のずれが残れば、版と pin は揃ったと出して 1' '1 True' { $r = Invoke-Flow -States @((New-State ($handNewer + $other)), $pathOnly) -ExeExists; "$($r.Code) $($r.Text -like '*版と pin は揃った*')" }
Test-Case '流れは終了コードのほかに数を出さない (表と行は Write-Host)' 1 { (Invoke-Flow -States @($changeState, $synced) -ExeExists).Ints }
# 見張り: winget を 1 つも打たない
$msiChange = @{ Msi = 'tool\bin\tool.exe' }
Test-Case 'MSI の道具があれば、-Check は 1 で MSI の締めの行を出す' '1 [] True' { $r = Invoke-Flow -States @((New-State $msiOnly)) -Check -Change $msiChange; "$($r.Code) [$($r.Calls)] $($r.Text -like '*MSI の tool (machine スコープ) が入っている*')" }
Test-Case 'MSI の道具があれば、-IfMissing でも portable を入れずに 1 で止まる' '1 [] True' { $r = Invoke-Flow -States @((New-State $msiOnly)) -IfMissing -Change $msiChange; "$($r.Code) [$($r.Calls)] $($r.Text -like '*portable を入れずに止める*')" }
Test-Case 'MSI の道具があれば、引数なしでも入れ替えもしない' '1 [] True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ MsiExe = $Msi }))) -ExeExists -Change $msiChange; "$($r.Code) [$($r.Calls)] $($r.Text -like '*portable を入れずに止める*')" }
Test-Case '昇格した会話で入っていなければ、-Check は 1 で昇格の締めの行を出す (3 にしない)' '1 [] True' { $r = Invoke-Flow -States @((New-State ($missing + $elevated))) -Check; "$($r.Code) [$($r.Calls)] $($r.Text -like '*昇格した PowerShell では winget が tool を入れない*')" }
Test-Case '昇格した会話では、-IfMissing でも入れずに 1 で止まる' '1 [] True' { $r = Invoke-Flow -States @((New-State ($missing + $elevated))) -IfMissing; "$($r.Code) [$($r.Calls)] $($r.Text -like '*昇格していない PowerShell で Install-Tool を打ち直す*')" }
Test-Case '昇格した会話では、入れ替えもしない' '1 []' { $r = Invoke-Flow -States @((New-State ($handNewer + $elevated))) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '昇格した会話でも、pin を足すだけなら足す' '0 [pin list pin add]' { $r = Invoke-Flow -States @((New-State ($elevated + @{ Pinned = $false })), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '道具の見張りに当たれば、winget を打たずにその行を出して 1' '1 [] True' { $r = Invoke-Flow -States @((New-State (Join-Change $handNewer @{ Installed = 'old' }))) -ExeExists -Change @{ Hooks = @{ Holds = 'Get-SampleHold' } }; "$($r.Code) [$($r.Calls)] $($r.Text -like '*古いので止める*')" }
# custom の口の段
Test-Case 'BeforeWinget は pin を外した後・winget の前、AfterWinget は pin を足した後・読み直す前' '0 [download pin remove before uninstall install pin list pin add after]' { $r = Invoke-Flow -States @((New-State $pinnedNewer), $synced) -ExeExists -Change @{ Hooks = @{ BeforeWinget = 'Invoke-SampleBefore'; AfterWinget = 'Invoke-SampleAfter' } }; "$($r.Code) [$($r.Calls)]" }
Test-Case '人が直すことだけなら、BeforeWinget・AfterWinget も呼ばない' '1 []' { $r = Invoke-Flow -States @($pathOnly) -ExeExists -PinListed -Change @{ Hooks = @{ BeforeWinget = 'Invoke-SampleBefore'; AfterWinget = 'Invoke-SampleAfter' } }; "$($r.Code) [$($r.Calls)]" }
Test-Case '道具の止める理由があれば、その行を出して winget を打たない' '1 [] True' { $r = Invoke-Flow -States @((New-State (Join-Change $handNewer @{ Installed = 'blocked' }))) -ExeExists -Change @{ Hooks = @{ Blocker = 'Get-SampleBlocker' } }; "$($r.Code) [$($r.Calls)] $($r.Text -like '*Preview が残っているので止める*1. 外す*')" }
Test-Case '道具の Drift だけでも揃える流れに入る (winget は plan のとおり)' '0 [pin list after]' { $r = Invoke-Flow -States @((New-State @{ Installed = 'drift'; Plan = 'none' }), $synced) -ExeExists -PinListed -Change @{ Hooks = @{ Drift = 'Test-SampleDrift'; AfterWinget = 'Invoke-SampleAfter' } }; "$($r.Code) [$($r.Calls)]" }
Test-Case '道具の Manual だけなら揃えない (人が直す)' '1 []' { $r = Invoke-Flow -States @((New-State @{ Installed = 'manual' })) -ExeExists -PinListed -Change @{ Hooks = @{ Manual = 'Test-SampleManual'; AfterWinget = 'Invoke-SampleAfter' } }; "$($r.Code) [$($r.Calls)]" }
Test-Case 'Synced で「揃った」の主語を替える' 'True' { $r = Invoke-Flow -States @((New-State ($handNewer + $other)), $pathOnly) -ExeExists -Change @{ Synced = '版と pin と別名' }; $r.Text -like '*版と pin と別名 は揃った*' }
Remove-Item -LiteralPath $FlowPkg -Recurse -Force -ErrorAction SilentlyContinue

# winget が無ければ 2 (Get-Command winget が見つからない)
Remove-Item -LiteralPath function:winget
Test-Case 'winget が無ければ、Install-WinGet を案内して 2' '2 True' {
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $out = @(Invoke-WingetPortable -Tool (New-RawTool) -Version $V -Check 6>&1)
    "$(@($out | Where-Object { $_ -is [int] })[-1]) $((@($out | ForEach-Object { "$_" }) -join "`n") -like '*Install-WinGet*')"
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
