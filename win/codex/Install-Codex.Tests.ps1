# win/codex/Install-Codex.ps1 (Codex CLI の表と、codex と打てる形・同梱の rg・化けた codex-path の行・古い winget を見る custom の関数) のテスト。
# Pester は使わない。流れ・見張り・終了コードの決まりは共通の枠の試験 (win/winget/WingetPortable.Tests.ps1) が確かめ、ここは Codex CLI の表の値と
# custom の関数がそこへ正しく渡るかを確かめる。winget やプロセスに触る本物の部分は、実機で -Check と本番を打って確かめる (win/README.md の「Codex CLI」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/codex/Install-Codex.Tests.ps1
#
# ## 確かめること
#
#   - codex --version の出力 (codex-cli <版>) から版を拾い、winget show --versions の版の行だけを新しい順に拾い、winget --version から winget の版を拾う
#   - codex と打てる形: WinGet\Links\codex.exe が置き場所の exe への symlink か (symlink の形)、置き場所の codex.exe が置き場所の exe の hardlink か
#     (hardlink の形。winget 1.30 から)。どちらでもよく、Links の codex.exe がほかを指せば wrong
#   - 入っていなければ install、版が違う・読めなければ change、版が同じで codex と打てる形が無い・違えば relink、揃っていれば none
#   - winget を打てるか: 昇格した会話で winget が 1.30 以降なら止める (共通の枠の見張り)、昇格していない会話で開発者モードが off で winget が
#     1.29 以前なら止める (この表の見張り old-winget)。ほかは打つ (UAC で昇格して打つ道は無い)
#   - install は portable・user スコープ・依存なし (--skip-dependencies) で入れ、change と relink は uninstall → install (どれも upgrade を
#     打たず、--include-pinned も付けない)。取得だけを確かめる winget download も portable を名指しする
#   - PATH で引かれる codex (WinGet\Links\codex.exe は links、置き場所の codex.exe は package。npm の codex.cmd などは other)
#   - 同梱の rg: PATH の codex が置き場所の codex.exe (hardlink の形) なら、置き場所の codex-path が PATH にあるか
#   - 化けた codex-path の行 (winget uninstall が置き場所の部分だけを抜いた \codex-path) を見つけ、外す・入れ直す前に自分の codex-path の行と
#     一緒に PATH から外す
#   - 終了コード (揃っていれば 0・差があれば 1・入っていなければ 3。昇格・old-winget で入れる・入れ直すなら 1)・状態の表の行・締めの行 (runner が読む字)
#   - 流れ: -Check と -IfMissing は入れ替えない。揃える流れは取得を確かめてから外して入れ、pin を足し、hardlink の形なら codex-path を PATH に
#     足す。動いている codex があれば・取得が落ちたら・固定した版が winget に無ければ・昇格・old-winget なら、何も変えずに止まる。PATH のずれ
#     だけなら winget を打たない
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Codex.ps1 の末尾)。共通の枠も clone の win\winget\ から読む
. (Join-Path $PSScriptRoot 'Install-Codex.ps1')

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

$Id = 'OpenAI.Codex'
$V = '0.170.0'
$Older = '0.169.1'
$Newer = '0.172.0'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe'
$ExeName = 'codex-x86_64-pc-windows-msvc.exe'
$Exe = "$Pkg\$ExeName"
$Hard = "$Pkg\codex.exe"
$RgDir = "$Pkg\codex-path"
$Links = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links'
$Link = "$Links\codex.exe"
$Npm = 'C:\Users\u\AppData\Roaming\npm\codex.cmd'
$w130 = [version]'1.30.310'
$w129 = [version]'1.29.380'

# この試験は x64 の PC として流す (Get-CodexTool が CPU の名前で exe を並べる)
$savedArch = $env:PROCESSOR_ARCHITECTURE
$savedWow = $env:PROCESSOR_ARCHITEW6432
$env:PROCESSOR_ARCHITEW6432 = $null
$env:PROCESSOR_ARCHITECTURE = 'AMD64'

# Codex CLI の表に、試験の置き場所を足して埋めたもの
function New-Tool {
    param([hashtable]$Change = @{})
    $t = Get-CodexTool
    $t.PackageDir = $Pkg
    $t.LinksDir = $Links
    foreach ($k in $Change.Keys) { $t[$k] = $Change[$k] }
    Complete-PortableTool -Tool $t
}
$T = New-Tool

# 2026-11-27 に winget-pkgs にあった OpenAI.Codex の版の新しい方 (winget show --versions の並び)
$show = @(
    'Found Codex [OpenAI.Codex]'
    'Version'
    '-------'
    $Newer
    '0.171.0'
    $V
    $Older
    '0.169.0'
)
$versions = @($V, $Older)

# 表
Test-Case 'パッケージ ID は $packageId の行 (版の知らせが読む)' $Id { $T.PackageId }
Test-Case '名前・関数・PATH で引く名前・README の節' 'Codex CLI|Install-Codex|codex|Codex CLI' { "$($T.Name)|$($T.Command)|$($T.CommandName)|$($T.Readme)" }
Test-Case '版が読めないときの字は codex --version・MSI は見ない・置き場所の下を探さない' 'codex --version True False' { "$($T.VersionLabel) $($null -eq $T.Msi) $($T.ExeSearch)" }

# codex --version の出力から版を拾う
function Get-Version { param([string[]]$Lines) Get-PortableVersionFromOutput -Lines $Lines -Pattern $T.VersionPattern }
Test-Case '"codex-cli <版>" から版を拾う' $V { Get-Version @("codex-cli $V") }
Test-Case '"codex <版>" からも拾う' $Older { Get-Version @("codex $Older") }
Test-Case '版だけの出力からも拾う' $Newer { Get-Version @($Newer) }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-Version @("  codex-cli $V`r") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-Version @('WARNING: proceeding, even though we could not create PATH aliases', "codex-cli $V") }
Test-Case '版の行が無ければ空' '' { Get-Version @('error: something went wrong') }

Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$Newer 0.171.0 $V $Older 0.169.0" { Get-WingetVersionList -Lines $show }
Test-Case 'winget --version の v1.29.380 (行末の CR) を拾う' '1.29.380' { "$(Get-WingetClientVersion -Lines @("v1.29.380`r"))" }
Test-Case '1.30 以降なら True・1.29 以前なら False・1.31 も True・読めなければ空' 'True False True ' {
    "$(Test-WingetModernPortable -WingetVersion ([version]'1.30.310')) $(Test-WingetModernPortable -WingetVersion ([version]'1.29.380')) $(Test-WingetModernPortable -WingetVersion ([version]'1.31.0')) $(Test-WingetModernPortable -WingetVersion $null)"
}

# Get-CodexLinkState: WinGet\Links の codex.exe が置き場所の exe への symlink か
Test-Case '置き場所の exe を指す symlink なら ok' 'ok' { Get-CodexLinkState -Exists $true -LinkType 'SymbolicLink' -Target $Exe -ExePath $Exe }
Test-Case '大文字小文字が違っても ok' 'ok' { Get-CodexLinkState -Exists $true -LinkType 'SymbolicLink' -Target $Exe.ToUpper() -ExePath $Exe }
Test-Case '無ければ missing' 'missing' { Get-CodexLinkState -Exists $false -LinkType '' -Target '' -ExePath $Exe }
Test-Case 'ほかを指す symlink なら wrong' 'wrong' { Get-CodexLinkState -Exists $true -LinkType 'SymbolicLink' -Target 'C:\other\codex.exe' -ExePath $Exe }
Test-Case 'symlink でないファイル (写し・hardlink) なら wrong' 'wrong' { Get-CodexLinkState -Exists $true -LinkType 'HardLink' -Target '' -ExePath $Exe }
Test-Case '置き場所の exe が無いのに symlink があれば wrong' 'wrong' { Get-CodexLinkState -Exists $true -LinkType 'SymbolicLink' -Target $Exe -ExePath $null }

# Get-CodexHardlinkState: 置き場所の codex.exe が置き場所の exe の hardlink か
Test-Case '置き場所の exe と同じ大きさのファイルなら ok' 'ok' { Get-CodexHardlinkState -Exists $true -LinkType '' -Length 100 -ExeLength 100 }
Test-Case '無ければ missing' 'missing' { Get-CodexHardlinkState -Exists $false -LinkType '' -Length 0 -ExeLength 100 }
Test-Case '大きさが違えば wrong (前の版の写しなど)' 'wrong' { Get-CodexHardlinkState -Exists $true -LinkType '' -Length 99 -ExeLength 100 }
Test-Case 'reparse point (symlink など) なら wrong' 'wrong' { Get-CodexHardlinkState -Exists $true -LinkType 'ReparsePoint' -Length 100 -ExeLength 100 }
Test-Case '置き場所の exe が無ければ wrong' 'wrong' { Get-CodexHardlinkState -Exists $true -LinkType '' -Length 100 -ExeLength -1 }

# Get-CodexAliasState: codex と打てる形
Test-Case 'Links の symlink があれば symlink (hardlink もあっても)' 'symlink symlink' { "$(Get-CodexAliasState -LinkState ok -HardlinkState missing) $(Get-CodexAliasState -LinkState ok -HardlinkState ok)" }
Test-Case 'Links が無く置き場所の hardlink があれば hardlink' 'hardlink' { Get-CodexAliasState -LinkState missing -HardlinkState ok }
Test-Case 'Links がほかを指せば、hardlink があっても wrong' 'wrong' { Get-CodexAliasState -LinkState wrong -HardlinkState ok }
Test-Case 'Links が無く置き場所の codex.exe が違えば wrong' 'wrong' { Get-CodexAliasState -LinkState missing -HardlinkState wrong }
Test-Case 'どちらも無ければ missing (winget 1.29 以前が symlink を作れなかった形)' 'missing' { Get-CodexAliasState -LinkState missing -HardlinkState missing }

# することを決める (codex と打てる形が無い・違えば relink)
function Get-Plan { param([bool]$Exists, $Installed, $AliasState) Get-PortablePlan -Exists $Exists -Installed $Installed -Target $V -Reinstall (Test-CodexReinstall -Tool $T -State ([pscustomobject]@{ AliasState = $AliasState })) }
Test-Case '入っていなければ install' 'install' { Get-Plan $false $null 'missing' }
Test-Case 'symlink の形で揃っていれば none' 'none' { Get-Plan $true $V 'symlink' }
Test-Case 'hardlink の形で揃っていれば none' 'none' { Get-Plan $true $V 'hardlink' }
Test-Case '違う版なら change (codex と打てても)' 'change' { Get-Plan $true $Newer 'hardlink' }
Test-Case 'exe があるのに版が読めなければ change' 'change' { Get-Plan $true $null 'symlink' }
Test-Case '版が同じで codex と打てる形が無ければ relink' 'relink' { Get-Plan $true $V 'missing' }
Test-Case '版が同じで codex と打てる形が違えば relink' 'relink' { Get-Plan $true $V 'wrong' }

# winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
$put = "$common --version $V --installer-type portable --scope user --skip-dependencies --accept-package-agreements"
Test-Case 'install は版・portable・user スコープを名指しし、依存 (ripgrep・VCRedist) は入れない' "install $put" { @(Get-WingetCommands -Tool $T -Plan install -Version $V)[0] -join ' ' }
Test-Case 'change は 2 本 (外してから入れる)' "2 uninstall $common|install $put" { $c = @(Get-WingetCommands -Tool $T -Plan change -Version $V); "$($c.Count) $($c[0] -join ' ')|$($c[1] -join ' ')" }
Test-Case 'relink も 2 本 (同じ版を外してから入れ、winget に codex と打てる形を作らせる)' "2 uninstall $common|install $put" { $c = @(Get-WingetCommands -Tool $T -Plan relink -Version $V); "$($c.Count) $($c[0] -join ' ')|$($c[1] -join ' ')" }
Test-Case '取得だけを確かめる winget download の引数 (portable を名指しする)' "download --id $Id --exact --source winget --version $V --installer-type portable --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -Tool $T -Version $V -Directory 'C:\tmp\dl') -join ' ' }
Test-Case '0x8A15007D には、昇格していない PowerShell で Install-Codex を打ち直すと添える' $true { (Get-WingetFailureHint -Tool $T -ExitCode -1978335107) -like '*昇格していない PowerShell で Install-Codex を打ち直す*' }

# PATH で引かれる codex
$exists = { param($p) $p -in @($Link, $Npm, $Hard) }
Test-Case 'Links が先なら Links の codex.exe' $Link { Resolve-PortableOnPath -PathValue "$Links;C:\Users\u\AppData\Roaming\npm" -Names @('codex.exe', 'codex.cmd') -Exists $exists }
Test-Case 'npm の codex.cmd が先ならそれ' $Npm { Resolve-PortableOnPath -PathValue "C:\Users\u\AppData\Roaming\npm;$Links" -Names @('codex.exe', 'codex.cmd') -Exists $exists }
Test-Case '置き場所だけが PATH にある hardlink の形では、置き場所の codex.exe' $Hard { Resolve-PortableOnPath -PathValue $Pkg -Names @('codex.exe', 'codex.cmd', 'codex.bat', 'codex.ps1') -Exists $exists }
Test-Case '置き場所だけが PATH にあり hardlink が無い形 (winget 1.29 以前) では、codex は見つからない' '' { Resolve-PortableOnPath -PathValue $Pkg -Names @('codex.exe', 'codex.cmd', 'codex.bat', 'codex.ps1') -Exists { param($p) $p -eq $Exe } }
Test-Case 'WinGet\Links\codex.exe なら links' 'links' { Get-PortablePathKind -Resolved $Link -ExeDir $Pkg -LinksDir $Links }
Test-Case '大文字小文字が違っても links' 'links' { Get-PortablePathKind -Resolved $Link.ToUpper() -ExeDir $Pkg -LinksDir $Links }
Test-Case '置き場所の codex.exe なら package' 'package' { Get-PortablePathKind -Resolved $Hard -ExeDir $Pkg -LinksDir $Links }
Test-Case 'npm の codex.cmd は other' 'other' { Get-PortablePathKind -Resolved $Npm -ExeDir $Pkg -LinksDir $Links }
Test-Case '公式の install.ps1 の codex.exe は other' 'other' { Get-PortablePathKind -Resolved 'C:\Users\u\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe' -ExeDir $Pkg -LinksDir $Links }

# Test-CodexPathListed / Get-CodexPathValueWithEntry: PATH に置き場所の codex-path があるか・足した値
Test-Case '末尾の \・引用符・大文字小文字の違いを寄せて見つける' 'True' { Test-CodexPathListed -Raw "C:\x;`"$($RgDir.ToUpper())\`"" -Dir $RgDir }
Test-Case '無ければ False' 'False' { Test-CodexPathListed -Raw "C:\x;$Pkg" -Dir $RgDir }
Test-Case '末尾の ; を落として足す' "C:\x;$Pkg;$RgDir" { Get-CodexPathValueWithEntry -Raw "C:\x;$Pkg;" -Dir $RgDir }
Test-Case 'あれば変えない (%VAR% の書き方も残す)' "C:\x;$RgDir;%USERPROFILE%\bin" { Get-CodexPathValueWithEntry -Raw "C:\x;$RgDir;%USERPROFILE%\bin" -Dir $RgDir }
Test-Case '空なら足すものだけ' $RgDir { Get-CodexPathValueWithEntry -Raw '' -Dir $RgDir }

# Test-CodexMangledPathEntry / Get-CodexMangledPathCount / Get-CodexPathValueWithoutEntries: 化けた codex-path の行と、外した PATH の値
Test-Case '\codex-path は化けた行 (末尾の \・引用符・大文字小文字も)' 'True True True' { "$(Test-CodexMangledPathEntry -Entry '\codex-path') $(Test-CodexMangledPathEntry -Entry ' "\Codex-Path\" ') $(Test-CodexMangledPathEntry -Entry '\CODEX-PATH')" }
Test-Case '置き場所の codex-path・ほかの codex-path は化けた行ではない' 'False False False' { "$(Test-CodexMangledPathEntry -Entry $RgDir) $(Test-CodexMangledPathEntry -Entry 'C:\tools\codex-path') $(Test-CodexMangledPathEntry -Entry 'codex-path')" }
Test-Case '化けた行を数える' 2 { Get-CodexMangledPathCount -Raw "C:\x;\codex-path;$Pkg;\codex-path\" }
Test-Case '化けた行が無ければ 0' 0 { Get-CodexMangledPathCount -Raw "C:\x;$RgDir" }
Test-Case '自分の codex-path の行と化けた行を外し、ほかの行 (%VAR%・空の要素・末尾の ;) は残す' "C:\x;;%USERPROFILE%\bin;$Pkg;" { Get-CodexPathValueWithoutEntries -Raw "C:\x;\codex-path;;%USERPROFILE%\bin;$Pkg;$RgDir;" -Dirs @($RgDir) }
Test-Case '外す行を渡さなければ、化けた行だけを外す' "C:\x;$RgDir" { Get-CodexPathValueWithoutEntries -Raw "C:\x;\codex-path;$RgDir" -Dirs @() }
Test-Case '外すものが無ければ変えない' "C:\x;$Pkg" { Get-CodexPathValueWithoutEntries -Raw "C:\x;$Pkg" -Dirs @($RgDir) }

# Get-CodexRgState: 同梱の rg を codex が引けるか (hardlink の形のときだけ見る)
Test-Case 'symlink の形 (PATH の codex が Links) なら na' 'na' { Get-CodexRgState -PathKind links -BundledRg $true -PathValue $Links -RgDir $RgDir }
Test-Case 'hardlink の形で codex-path が PATH に無ければ missing' 'missing' { Get-CodexRgState -PathKind package -BundledRg $true -PathValue "C:\x;$Pkg" -RgDir $RgDir }
Test-Case 'hardlink の形で codex-path が PATH にあれば ok' 'ok' { Get-CodexRgState -PathKind package -BundledRg $true -PathValue "$Pkg;$RgDir" -RgDir $RgDir }
Test-Case '置き場所に codex-path\rg.exe が無ければ absent (足さない)' 'absent' { Get-CodexRgState -PathKind package -BundledRg $false -PathValue $Pkg -RgDir $RgDir }

# 状態の既定 (symlink の形で揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Exe = $Exe; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = $Link; PathLinkTarget = $null; PathKind = 'links'; BusyCount = 0
        MsiExe = $null; WingetVersion = $w130; Elevated = $false; Route = 'direct'
        ExeName = $ExeName; LinkState = 'ok'; LinkTarget = $Exe; HardlinkState = 'ok'; AliasState = 'symlink'; RgState = 'na'; MangledPath = 0
        DeveloperMode = $false
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
# 状態の差し替えを重ねる (後ろが勝つ。hashtable の + は同じ key で止まる)
function Join-Change {
    $h = @{}
    foreach ($part in $args) { foreach ($k in $part.Keys) { $h[$k] = $part[$k] } }
    $h
}
$missing = @{ Exists = $false; Installed = $null; Exe = $null; ExeName = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; LinkState = 'missing'; LinkTarget = ''; HardlinkState = 'missing'; AliasState = 'missing'; PathKind = 'none'; PathResolved = $null }
# 開発者モードが off の PC で、昇格していない winget 1.30 が入れた形 (Links に symlink が無く、置き場所の codex.exe と、置き場所の PATH の行)
$hardlinkForm = @{ LinkState = 'missing'; LinkTarget = ''; AliasState = 'hardlink'; PathKind = 'package'; PathResolved = $Hard; RgState = 'ok' }
$hardRgMissing = Join-Change $hardlinkForm @{ RgState = 'missing' }
$hardRgAbsent = Join-Change $hardlinkForm @{ RgState = 'absent' }
# winget 1.29 以前が symlink を作れずに入れた形 (codex と打てる形が無く、置き場所が PATH にある。pin も無い)
$fallback = @{ Plan = 'relink'; LinkState = 'missing'; LinkTarget = ''; HardlinkState = 'missing'; AliasState = 'missing'; PathKind = 'none'; PathResolved = $null; Pinned = $false }
# 手で入れた新しい版 (pin も無い)
$handNewer = @{ Installed = $Newer; Plan = 'change'; Direction = 'down'; Pinned = $false; Versions = @($Newer, $V, $Older); Latest = $Newer }
# 昇格した会話 (winget 1.30 以降) と、昇格していない会話で開発者モードが off の 1.29 以前の winget
$elevated = @{ Elevated = $true; Route = 'elevated' }
$oldWinget = @{ Elevated = $false; DeveloperMode = $false; WingetVersion = $w129 }

# 見張り: 昇格は共通の枠、古い winget (old-winget) はこの表 (Get-CodexHold)
function Get-HoldName { param($State) $h = Get-PortableHold -Tool $T -State $State; if ($h) { $h.Name } else { 'none' } }
Test-Case '昇格していない会話で 1.30 なら、開発者モードが off でも止めない (hardlink の形になる)' 'none' { Get-HoldName (New-State $missing) }
Test-Case '開発者モードなら 1.29 でも止めない (symlink を作れる)' 'none' { Get-HoldName (New-State (Join-Change $missing $oldWinget @{ DeveloperMode = $true })) }
Test-Case '昇格していない会話で開発者モードが off で 1.29 なら old-winget' 'old-winget' { Get-HoldName (New-State (Join-Change $missing $oldWinget)) }
Test-Case '昇格した会話で 1.30 なら elevated (開発者モードでも)' 'elevated elevated' { "$(Get-HoldName (New-State ($missing + $elevated))) $(Get-HoldName (New-State (Join-Change $missing $elevated @{ DeveloperMode = $true })))" }
Test-Case '昇格した会話で 1.29 なら止めない (symlink を作れる)' 'none' { Get-HoldName (New-State (Join-Change $missing $oldWinget @{ Elevated = $true; Route = 'direct' })) }
Test-Case 'winget の版が読めなければ止めない (打ってみる)' 'none none' { "$(Get-HoldName (New-State (Join-Change $missing @{ WingetVersion = $null }))) $(Get-HoldName (New-State (Join-Change $missing @{ WingetVersion = $null; Elevated = $true; Route = 'direct' })))" }
Test-Case '入れる・入れ直す・入れ替えるときに当たる' 'elevated old-winget old-winget elevated' { "$(Get-HoldName (New-State ($missing + $elevated))) $(Get-HoldName (New-State (Join-Change $missing $oldWinget))) $(Get-HoldName (New-State (Join-Change $fallback $oldWinget))) $(Get-HoldName (New-State ($handNewer + $elevated)))" }
Test-Case '版と codex と打てる形が揃っていれば (winget を打たないので) 当たらない' 'none none' { "$(Get-HoldName (New-State ($elevated + @{ Pinned = $false }))) $(Get-HoldName (New-State $oldWinget))" }

# 揃える手順で直る差と、人が直す差
Test-Case '揃っていれば差は無い' 'False False' { $s = New-State; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'hardlink の形で揃っていても差は無い' 'False False' { $s = New-State $hardlinkForm; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'pin が無ければ揃える手順で直る差' 'True False' { $s = New-State @{ Pinned = $false }; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'hardlink の形で codex-path が PATH に無ければ揃える手順で直る差' 'True False' { $s = New-State $hardRgMissing; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'ユーザーの PATH に化けた codex-path の行があれば揃える手順で直る差 (終了コード 1)' 'True False 1' { $s = New-State @{ MangledPath = 1 }; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s) $(Get-PortableExitCode -Tool $T -State $s)" }
Test-Case 'codex と打てる形が無いのは揃える手順で直る差 (PATH で見つからないのは、ずれに数えない)' 'True False' { $s = New-State $fallback; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'PATH でほかの codex が先なら PATH のずれ (揃える手順では直らない)' 'False True' { $s = New-State @{ PathKind = 'other'; PathResolved = $Npm }; "$(Test-PortableDrift -Tool $T -State $s) $(Test-PortableManual -Tool $T -State $s)" }
Test-Case 'codex と打てる形はあるのに PATH で見つからなければ PATH のずれ' 'True' { Test-PortablePathDrift -State (New-State @{ PathKind = 'none'; PathResolved = $null }) }
Test-Case '入っていないときに PATH に無いのは、ずれに数えない' 'False' { Test-PortablePathDrift -State (New-State $missing) }

# 終了コード
Test-Case '揃っていれば 0 (symlink の形も hardlink の形も)' '0 0' { "$(Get-PortableExitCode -Tool $T -State (New-State)) $(Get-PortableExitCode -Tool $T -State (New-State $hardlinkForm))" }
Test-Case 'pin が無い・版が違う・codex と打てる形が無い・codex-path が PATH に無い・PATH でほかが先なら 1' '1 1 1 1 1' { @((New-State @{ Pinned = $false }), (New-State $handNewer), (New-State $fallback), (New-State $hardRgMissing), (New-State @{ PathKind = 'other'; PathResolved = $Npm })) | ForEach-Object { Get-PortableExitCode -Tool $T -State $_ } }
Test-Case '入っていなければ 3' 3 { Get-PortableExitCode -Tool $T -State (New-State $missing) }
Test-Case '昇格・old-winget なら、入っていなくても 1 (runner に入れにいかせない)' '1 1' { "$(Get-PortableExitCode -Tool $T -State (New-State ($missing + $elevated))) $(Get-PortableExitCode -Tool $T -State (New-State (Join-Change $missing $oldWinget)))" }

# 見張りを通った後に止める理由
function Get-Blocker { param($State, $Target = $V) Get-PortableApplyBlocker -Tool $T -State $State -Target $Target }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-Blocker (New-State $missing) '0.1.0' }
Test-Case '入れ替えるのに codex が動いていれば busy' 'busy' { Get-Blocker (New-State ($handNewer + @{ BusyCount = 1 })) }
Test-Case '入れ直すのに codex が動いていれば busy' 'busy' { Get-Blocker (New-State ($fallback + @{ BusyCount = 2 })) }
Test-Case '入れるだけなら動いている数は見ない' '' { Get-Blocker (New-State ($missing + @{ BusyCount = 2 })) }

# 状態の表の行
function Get-Rows { param($State) @(Format-PortableState -Tool $T -State $State -Target $V) }
Test-Case '揃っていれば ⚠ の行は無く、表の 8 行だけ (同梱の rg の行も)' '0 8' { $r = Get-Rows (New-State); "$(@($r | Where-Object { $_.Warn }).Count) $($r.Count)" }
Test-Case '見出しはパッケージ名と置き場所 (runner の ps1.rs がこの頭で見分ける)' "Codex CLI (winget の $Id、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの版の行' "  固定した版      : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case 'symlink の形の別名・PATH・同梱の rg の行' "  codex の別名    : WinGet\Links\codex.exe (置き場所の $ExeName への symlink)|  PATH の codex   : winget の symlink (WinGet\Links\codex.exe)|  同梱の rg       : codex が置き場所の codex-path\rg.exe を自分で使う (symlink の形)" { $r = Get-Rows (New-State); "$($r[5].Text)|$($r[6].Text)|$($r[7].Text)" }
Test-Case 'hardlink の形の別名・PATH・同梱の rg の行 (⚠ にしない)' "  codex の別名    : 置き場所の codex.exe ($ExeName の hardlink。winget が symlink を作れずに、置き場所を PATH に足した形)|  PATH の codex   : winget の hardlink (置き場所の codex.exe)|  同梱の rg       : 置き場所の codex-path が PATH にある (hardlink の形の codex は同梱の rg を自分では見つけないので、PATH で引かせる)|0" { $r = Get-Rows (New-State $hardlinkForm); "$($r[5].Text)|$($r[6].Text)|$($r[7].Text)|$(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case 'hardlink の形で codex-path が PATH に無ければ、同梱の rg の行を ⚠ にする' '⚠ 同梱の rg       : 置き場所の codex-path が PATH に無い → ユーザーの PATH に足す (hardlink の形の codex は同梱の rg を自分では見つけない)' { (Get-Rows (New-State $hardRgMissing))[7].Text }
Test-Case '化けた codex-path の行があれば、⚠ の行で知らせる' '⚠ 化けた PATH の行: \codex-path が 2 行 → 取り除く (winget uninstall が codex-path の行から置き場所の部分だけを抜いた残り。ドライブの直下を指す)' { (Get-Rows (New-State @{ MangledPath = 2 }))[8].Text }
Test-Case '置き場所に codex-path\rg.exe が無ければ、⚠ にせずそう出す' '  同梱の rg       : 置き場所に codex-path\rg.exe が無い (codex は PATH の rg を使う)' { (Get-Rows (New-State $hardRgAbsent))[7].Text }
Test-Case '手で入れた新しい版から下げるとき' "⚠ 固定した版      : $V → 入れ替える (下げる)" { (Get-Rows (New-State $handNewer))[2].Text }
Test-Case 'pin が無ければ ⚠' '⚠ winget pin      : 無し → 足す' { (Get-Rows (New-State @{ Pinned = $false }))[4].Text }
Test-Case 'codex と打てる形が無ければ、版は ⚠ にせず、別名の行を ⚠ にする' "  固定した版      : $V → そのまま ⚠ codex の別名    : 無い → 入れ直す (winget 1.29 以前が symlink を作れずに、置き場所を PATH に足しただけの形。codex と打っても見つからない)" { $r = Get-Rows (New-State $fallback); "$($r[2].Text) $($r[5].Text)" }
Test-Case 'codex と打てる形が無ければ、PATH で見つからないのを ⚠ にせず、同梱の rg の行も出さない' '  PATH の codex   : 見つからない 7' { $r = Get-Rows (New-State $fallback); "$($r[6].Text) $($r.Count)" }
Test-Case 'Links の codex.exe がほかを指せば、指す先を出す' '⚠ codex の別名    : WinGet\Links\codex.exe が置き場所の exe を指していない (C:\other\codex.exe) → 入れ直す' { (Get-Rows (New-State @{ Plan = 'relink'; LinkState = 'wrong'; AliasState = 'wrong'; LinkTarget = 'C:\other\codex.exe' }))[5].Text }
Test-Case '置き場所の codex.exe が違えば、そう出す' "⚠ codex の別名    : 置き場所の codex.exe が $ExeName の hardlink ではない → 入れ直す" { (Get-Rows (New-State @{ Plan = 'relink'; LinkState = 'missing'; HardlinkState = 'wrong'; AliasState = 'wrong' }))[5].Text }
Test-Case '入っていなければ「入っていない」と「入れる」、別名は入れるときに作ると出す (⚠ にしない)' "  入っている版    : 入っていない ⚠ 固定した版      : $V → 入れる   codex の別名    : 入れるときに winget が作る (WinGet\Links\codex.exe の symlink か、置き場所の codex.exe の hardlink)" { $r = Get-Rows (New-State $missing); "$($r[1].Text) $($r[2].Text) $($r[5].Text)" }
Test-Case 'codex と打てる形はあるのに PATH で見つからなければ ⚠ と、PATH への足し方 (置き場所を入れて)' "⚠ PATH の codex   : 見つからない|※ PATH で codex が見つからない。symlink の形なら %LOCALAPPDATA%\Microsoft\WinGet\Links を、hardlink の形なら置き場所 ($Pkg) をユーザーの PATH に足し、新しい PowerShell を開く" { $r = Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }); "$($r[6].Text)|$($r[-1].Text)" }
Test-Case '版が読めないとき' '  入っている版    : 不明 (codex --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH でほかの codex が先なら、その場所を ⚠ で出し、外し方を ※ で添える' "⚠ PATH の codex   : $Npm (winget の portable のものではない)|※ PATH のずれは Install-Codex では直らない。C:\Users\u\AppData\Roaming\npm の codex を外す (npm の @openai/codex なら npm uninstall -g @openai/codex) か、C:\Users\u\AppData\Roaming\npm をユーザーの PATH から外す (win/README.md の「Codex CLI」)" { $r = Get-Rows (New-State @{ PathKind = 'other'; PathResolved = $Npm }); "$($r[6].Text)|$($r[-1].Text)" }
Test-Case 'winget show が失敗したら最新版は不明で、一覧についての ※/⚠ は出さない' '  winget の最新版 : 不明 (winget show が失敗) 8' { $r = Get-Rows (New-State @{ Versions = @(); Latest = $null }); "$($r[3].Text) $($r.Count)" }
Test-Case '新しい版があれば ※ で知らせる (⚠ にしない)' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Codex.ps1 の -Version の既定値を変える 0" { $r = Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }); "$($r[8].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '固定した版が winget から消えても、入っていれば ※ (入れ直すときも)' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { (Get-Rows (New-State @{ Versions = @($Newer, $Older); Latest = $Newer }))[8].Text }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @($Newer, $Older); Latest = $Newer })))[7].Text }
Test-Case 'そのまま打てる会話で入れ直すときは、見張りの行を出さない' 7 { (Get-Rows (New-State $fallback)).Count }
Test-Case '昇格した会話で入れるなら、⚠ と、昇格していない PowerShell で打ち直す ※ を添える' "⚠ 昇格した PowerShell では winget が Codex CLI を入れない (winget 1.30.310 は、昇格した会話から user スコープの portable を入れる・外すのを断る)。Install-Codex は winget を打たない|※ 昇格していない PowerShell (デスクトップの普通の端末) で Install-Codex を打ち直す (win/README.md の「winget の portable の道具」)" { $r = Get-Rows (New-State ($missing + $elevated)); "$($r[-2].Text)|$($r[-1].Text)" }
Test-Case 'old-winget で入れるなら、⚠ と、winget の更新か開発者モードの ※ を添える' "⚠ winget が古く、codex と打てる形を作れない (winget 1.29.380 は symlink を作れないときに codex.exe の hardlink を作らず、開発者モードも off)。入れても codex と打てないので、Install-Codex は入れない|※ Install-WinGet で winget を固定した版 (1.30 以降) に上げるか、開発者モードを on にして (設定 > システム > 開発者向け。管理者が要る)、Install-Codex を打ち直す (win/README.md の「winget」「Codex CLI」)" { $r = Get-Rows (New-State (Join-Change $fallback $oldWinget)); "$($r[-2].Text)|$($r[-1].Text)" }
Test-Case '入れ替えが要るのに codex が動いていれば ※ で添える' '※ codex が 1 個動いている。入れ替えるには、動いている codex (ほかの端末の会話など) を終わらせる' { (Get-Rows (New-State ($handNewer + @{ BusyCount = 1 })))[-1].Text }
Test-Case '入れ替えが要らなければ動いている数は出さない' 8 { (Get-Rows (New-State @{ BusyCount = 2 })).Count }

# 締めの行。Windows の runner (win/runner/src/steps/ps1.rs) がこの字で、入れるか・揃えるか・知らせるだけかを決め、見張りの行で直し方を選ぶ
function Get-Verdict { param($State) (@(Format-PortableVerdict -Tool $T -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '揃っていれば締めの行は出さない (symlink の形も hardlink の形も)' '|' { "$(Get-Verdict (New-State))|$(Get-Verdict (New-State $hardlinkForm))" }
Test-Case '入っていなければ、Install-Codex で入れると出す' '⚠️ Codex CLI が入っていない → Install-Codex で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版か pin の差があれば、Install-Codex で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Codex で揃える ⚠️' { Get-Verdict (New-State $handNewer) }
Test-Case 'codex と打てる形が無ければ、codex と打てないと出し、Install-Codex で揃える' "⚠️ 固定した版と揃っていない → Install-Codex で揃える ⚠️`n⚠️ codex と打てない (WinGet\Links の symlink も、置き場所の codex.exe の hardlink も無い・違う) → Install-Codex で揃える ⚠️" { Get-Verdict (New-State $fallback) }
Test-Case 'codex と打てる形だけが無ければ、その 1 行だけ' '⚠️ codex と打てない (WinGet\Links の symlink も、置き場所の codex.exe の hardlink も無い・違う) → Install-Codex で揃える ⚠️' { Get-Verdict (New-State (Join-Change $fallback @{ Pinned = $true })) }
Test-Case 'hardlink の形で codex-path が PATH に無ければ、Install-Codex で揃えると出す' '⚠️ codex が同梱の rg を引けない (置き場所の codex-path が PATH に無い) → Install-Codex で揃える ⚠️' { Get-Verdict (New-State $hardRgMissing) }
Test-Case '化けた codex-path の行があれば、Install-Codex で揃えると出す' '⚠️ ユーザーの PATH に化けた codex-path の行 (\codex-path) が残っている → Install-Codex で揃える ⚠️' { Get-Verdict (New-State @{ MangledPath = 1 }) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の codex が winget の portable のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = $Npm }) }
Test-Case '昇格した会話なら、その 1 行だけ (入れる・揃えるとは言わない)' '⚠️ 昇格した PowerShell では winget が Codex CLI を入れない (winget 1.30 から) → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($missing + $elevated)) }
Test-Case 'old-winget なら、その 1 行だけ' '⚠️ winget が古く、codex と打てる形を作れない (winget 1.29 以前で、開発者モードも off) → ※ の手順で直す ⚠️' { Get-Verdict (New-State (Join-Change $fallback $oldWinget)) }
Test-Case '昇格した会話でも揃っていれば締めの行は出さない' '' { Get-Verdict (New-State $elevated) }

# 昇格して winget を打つ道は無い (UAC を出さない)
Test-Case 'Install-Codex.ps1 と共通の枠は Start-Process -Verb RunAs を使わない' 'False False' { "$((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-Codex.ps1') -Raw) -match 'RunAs') $((Get-Content -LiteralPath (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'winget') 'WingetPortable.ps1') -Raw) -match 'RunAs')" }

# Find-PortableExe: この PC の CPU の名前を先に見て、無ければもう一方。hardlink の codex.exe は置き場所の exe としては拾わない
$findRoot = Join-Path ([IO.Path]::GetTempPath()) "install-codex-tests-find-$PID"
$x64 = Join-Path $findRoot 'codex-x86_64-pc-windows-msvc.exe'
$arm = Join-Path $findRoot 'codex-aarch64-pc-windows-msvc.exe'
New-Item -ItemType Directory -Force -Path $findRoot | Out-Null
function Find-Exe { $t = Get-CodexTool; $t.PackageDir = $findRoot; $t.LinksDir = $Links; Find-PortableExe -Tool (Complete-PortableTool -Tool $t) }
Test-Case '置き場所に無ければ空' '' { Find-Exe }
New-Item -ItemType File -Force -Path (Join-Path $findRoot 'codex.exe') | Out-Null
Test-Case 'codex.exe (hardlink) だけなら空' '' { Find-Exe }
New-Item -ItemType File -Force -Path $arm | Out-Null
Test-Case 'x64 の PC でも、arm64 の exe しか無ければそれ' $arm { Find-Exe }
New-Item -ItemType File -Force -Path $x64 | Out-Null
Test-Case 'x64 の PC では x86_64 の exe を先に見る' $x64 { Find-Exe }
$env:PROCESSOR_ARCHITECTURE = 'ARM64'
Test-Case 'arm64 の PC では aarch64 の exe を先に見る' $arm { Find-Exe }
$env:PROCESSOR_ARCHITEW6432 = 'ARM64'
$env:PROCESSOR_ARCHITECTURE = 'x86'
Test-Case '32 bit の PowerShell でも、PROCESSOR_ARCHITEW6432 の CPU の名前で見る' $arm { Find-Exe }
$env:PROCESSOR_ARCHITEW6432 = $null
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
Remove-Item -LiteralPath $findRoot -Recurse -Force

# ---------------------------------------------------------------------------
# 入口から流れまで (Start-WingetPortable に Codex CLI の表を渡す)。Windows に触る関数を偽物に差し替えて、打つ winget の順と、custom の口で
# codex-path の行を外す・足す段と、途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-codex-tests-$PID"
$FakeExe = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe') 'codex-x86_64-pc-windows-msvc.exe'

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
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("Codex $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Get-PortableState { param($Tool, $Target) $script:States.Dequeue() }
function Get-PortableBusyProcess { param($Tool) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'codex.exe exec hello' } }
# 入れた後の PATH の codex と同梱の rg (揃える流れが codex-path を足すかを決める)。足したら 'path add' を記録する
function Get-CodexPathState { param($Tool) [pscustomobject]@{ Resolved = $null; Kind = 'package'; RgDir = (Join-Path $Tool.PackageDir 'codex-path'); RgState = $script:RgAfter; MangledPath = 0 } }
function Add-CodexUserPath { param($Dir) $script:Calls.Add("path add $(Split-Path -Leaf $Dir)") }
# 外す行 (自分の codex-path) を記録する。化けた行は渡さなくても外す
function Remove-CodexUserPath { param([string[]]$Dirs) $script:Calls.Add("path remove [$(@($Dirs | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ }) -join ' ')]"); 0 }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-PortableState が返す順 (揃える前と、揃えた後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [hashtable]$Fail = @{}, [int]$Busy = 0, [switch]$ExeExists, [switch]$PinListed, [string]$RgAfter = 'na')
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:Busy = @()
    if ($Busy -gt 0) { $script:Busy = @(1..$Busy | ForEach-Object { [pscustomobject]@{ Id = 1000 + $_ } }) }
    $script:PinListed = [bool]$PinListed
    $script:RgAfter = $RgAfter
    Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
    if ($ExeExists) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    $out = @(Start-WingetPortable -Tool (Get-CodexTool) -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$changeState = New-State $handNewer
$synced = New-State
$syncedHard = New-State $hardlinkForm
$fallbackState = New-State $fallback
Test-Case '-Check は winget を打たない' '1 []' { $r = Invoke-Flow -States @($changeState) -Check -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていれば何も打たない (版がずれていても入れ替えない)' '1 []' { $r = Invoke-Flow -States @($changeState) -IfMissing -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ、昇格せずに install して pin を足す' '0 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '入れた後が hardlink の形で codex-path が PATH に無ければ、ユーザーの PATH に足す' '0 [install pin list pin add path add codex-path]' { $r = Invoke-Flow -States @((New-State $missing), $syncedHard) -IfMissing -RgAfter missing; "$($r.Code) [$($r.Calls)]" }
Test-Case '揃っていれば何も打たない' '0 []' { $r = Invoke-Flow -States @($synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'pin だけ無ければ pin を足すだけ' '0 [pin list pin add]' { $r = Invoke-Flow -States @((New-State @{ Pinned = $false }), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'hardlink の形で codex-path だけが PATH に無ければ、winget を打たずに PATH に足す' '0 [pin list path add codex-path]' { $r = Invoke-Flow -States @((New-State $hardRgMissing), $syncedHard) -ExeExists -PinListed -RgAfter missing; "$($r.Code) [$($r.Calls)]" }
Test-Case '下げる入れ替えは、取得を確かめてから、自分の codex-path の行を外して uninstall → install して pin を足す' '0 [download path remove [codex-path] uninstall install pin list pin add]' { $r = Invoke-Flow -States @($changeState, $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'codex と打てる形が無い形は、取得を確かめてから入れ直す' '0 [download path remove [codex-path] uninstall install pin list pin add]' { $r = Invoke-Flow -States @($fallbackState, $syncedHard) -ExeExists; "$($r.Code) [$($r.Calls)]" }
$pinnedNewer = Join-Change $handNewer @{ Pinned = $true }
Test-Case 'pin があれば、入れ替えの前に外す (codex-path の行は pin の後・winget の前に外す)' '0 [download pin remove path remove [codex-path] uninstall install pin list pin add]' { $r = Invoke-Flow -States @((New-State $pinnedNewer), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '動いている codex があれば、winget を 1 つも打たずに止まり、PID とコマンドラインを出す' '1 [] True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*1001*codex.exe exec hello*')" }
Test-Case '取得が落ちたら、何も変えずに止まる' '1 [download] True' { $r = Invoke-Flow -States @($changeState) -Fail @{ download = 1 } -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*何も変えていない*')" }
Test-Case 'uninstall が落ちたら install せず、pin を足す (入っている版は残る)' '1 [download path remove [codex-path] uninstall pin list pin add]' { $r = Invoke-Flow -States @($changeState, $changeState) -Fail @{ uninstall = 1 } -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'uninstall の後に install が落ちたら、入れ直し方を出す' $true { $r = Invoke-Flow -States @($changeState, (New-State $missing)) -Fail @{ install = 1 } -ExeExists; ($r.Code -eq 1) -and ($r.Calls -eq 'download path remove [codex-path] uninstall install pin list') -and ($r.Text -like '*Install-Codex を打ち直す*') }
Test-Case 'winget が 0x8A15007D で断ったら、昇格していない PowerShell で打ち直すと出す' $true { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -Fail @{ install = -1978335107 } -IfMissing; ($r.Code -eq 1) -and ($r.Text -like '*0x8A15007D*昇格していない PowerShell で Install-Codex を打ち直す*') }
Test-Case 'hardlink の形で入れ替えたら、外した codex-path の行を入れた後に足し直す' '0 [download path remove [codex-path] uninstall install pin list pin add path add codex-path]' { $r = Invoke-Flow -States @((New-State ($handNewer + $hardlinkForm)), $syncedHard) -ExeExists -RgAfter missing; "$($r.Code) [$($r.Calls)]" }
Test-Case '化けた codex-path の行だけが残っていれば、winget を打たずに化けた行だけを外す' '0 [path remove [] pin list]' { $r = Invoke-Flow -States @((New-State @{ MangledPath = 1 }), $synced) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)]" }
Test-Case '入っていないときに化けた行があれば、入れる前に外す' '0 [path remove [] install pin list pin add]' { $r = Invoke-Flow -States @((New-State ($missing + @{ MangledPath = 1 })), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は化けた行があっても PATH を変えない' '1 []' { $r = Invoke-Flow -States @((New-State @{ MangledPath = 1 })) -Check -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '固定した版が winget に無ければ、winget を打たずに止まる' '1 []' { $r = Invoke-Flow -States @((New-State ($missing + @{ Versions = @($Newer); Latest = $Newer }))); "$($r.Code) [$($r.Calls)]" }
Test-Case '昇格した会話なら、引数なしでも winget を打たずに 1 で止まり、昇格していない PowerShell で打ち直すと出す' '1 [] True' { $r = Invoke-Flow -States @((New-State ($missing + $elevated))); "$($r.Code) [$($r.Calls)] $($r.Text -like '*昇格していない PowerShell で Install-Codex を打ち直す*')" }
Test-Case 'old-winget なら、引数なしでも winget を打たずに 1 で止まり、winget の更新の手を出す' '1 [] True' { $r = Invoke-Flow -States @((New-State (Join-Change $fallback $oldWinget))) -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*winget を更新するか開発者モードを on にしてから打ち直す*')" }
Test-Case '昇格・old-winget なら、-IfMissing でも入れずに 1 (codex-path も触らない)' '1 [] 1 []' { $a = Invoke-Flow -States @((New-State (Join-Change $missing $elevated @{ MangledPath = 1 }))) -IfMissing; $b = Invoke-Flow -States @((New-State (Join-Change $missing $oldWinget))) -IfMissing; "$($a.Code) [$($a.Calls)] $($b.Code) [$($b.Calls)]" }
$pathOnly = New-State @{ PathKind = 'other'; PathResolved = $Npm }
Test-Case 'PATH のずれだけなら winget を打たずに 1 で止まり、※ の手順で直すと出す' '1 [] True' { $r = Invoke-Flow -States @($pathOnly) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*※ の手順で直す*')" }
Test-Case '揃えた後も PATH のずれが残れば、版と pin と codex と打てる形は揃ったと出して 1' '1 True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ PathKind = 'other'; PathResolved = $Npm })), $pathOnly) -ExeExists; "$($r.Code) $($r.Text -like '*版と pin と codex と打てる形 は揃った*')" }
Test-Case '揃えたら、揃ったと出す' $true { $r = Invoke-Flow -States @($fallbackState, $syncedHard) -ExeExists; ($r.Code -eq 0) -and ($r.Text -like '*揃った*') }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
$env:PROCESSOR_ARCHITECTURE = $savedArch
$env:PROCESSOR_ARCHITEW6432 = $savedWow

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
