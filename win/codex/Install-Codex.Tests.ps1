# win/codex/Install-Codex.ps1 のうち、副作用の無い関数と、Windows に触る関数を偽物に差し替えた流れのテスト。Pester は使わない。
# winget やプロセスに触る本物の部分は、実機で -Check と本番を打って確かめる (win/README.md の「Codex CLI」)。
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
#   - winget を打てるか: 昇格した会話で winget が 1.30 以降なら elevated、昇格していない会話で開発者モードが off で winget が 1.29 以前なら old-winget、
#     ほかは direct (UAC で昇格して打つ道は無い)
#   - install は portable・user スコープ・依存なし (--skip-dependencies) で入れ、change と relink は uninstall → install (どれも upgrade を
#     打たず、--include-pinned も付けない)。取得だけを確かめる winget download も portable を名指しする
#   - PATH で引かれる codex (WinGet\Links\codex.exe は links、置き場所の codex.exe は package。npm の codex.cmd などは other)
#   - 同梱の rg: PATH の codex が置き場所の codex.exe (hardlink の形) なら、置き場所の codex-path が PATH にあるか
#   - 化けた codex-path の行 (winget uninstall が置き場所の部分だけを抜いた \codex-path) を見つけ、外す・入れ直す前に自分の codex-path の行と
#     一緒に PATH から外す
#   - 終了コード (揃っていれば 0・差があれば 1・入っていなければ 3。elevated・old-winget で入れる・入れ直すなら 1)・状態の表の行・締めの行 (runner が読む文言)
#   - 流れ: -Check と -IfMissing は入れ替えない。揃える流れは取得を確かめてから外して入れ、pin を足し、hardlink の形なら codex-path を PATH に
#     足す。動いている codex があれば・取得が落ちたら・固定した版が winget に無ければ・elevated・old-winget なら、何も変えずに止まる。PATH のずれ
#     だけなら winget を打たない
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-Codex.ps1 の末尾)
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
# 版の一覧 (新しい順)。上げ下げを確かめるため、固定した版より古い版も並べる
# (関数を通さずに書く。関数が無い段階でもテストが最後まで流れるように)
$versions = @($V, $Older)

# Get-CodexVersionFromOutput: codex --version の出力から版を拾う
Test-Case '"codex-cli <版>" から版を拾う' $V { Get-CodexVersionFromOutput -Lines @("codex-cli $V") }
Test-Case '"codex <版>" からも拾う' $Older { Get-CodexVersionFromOutput -Lines @("codex $Older") }
Test-Case '版だけの出力からも拾う' $Newer { Get-CodexVersionFromOutput -Lines @($Newer) }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-CodexVersionFromOutput -Lines @("  codex-cli $V`r") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-CodexVersionFromOutput -Lines @('WARNING: proceeding, even though we could not create PATH aliases', "codex-cli $V") }
Test-Case '版の行が無ければ空' '' { Get-CodexVersionFromOutput -Lines @('error: something went wrong') }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$Newer 0.171.0 $V $Older 0.169.0" { Get-WingetVersionList -Lines $show }
Test-Case 'パッケージが無ければ空' '' { Get-WingetVersionList -Lines @('No package found matching input criteria.') }

# Get-WingetClientVersion / Test-WingetModernPortable: winget --version から winget の版を拾い、1.30 以降かを見る
Test-Case 'v1.30.310 を拾う' '1.30.310' { "$(Get-WingetClientVersion -Lines @('v1.30.310'))" }
Test-Case 'preview の版も拾う' '1.30.140' { "$(Get-WingetClientVersion -Lines @('v1.30.140-preview'))" }
Test-Case 'v1.29.380 を拾う' '1.29.380' { "$(Get-WingetClientVersion -Lines @("v1.29.380`r"))" }
Test-Case '読めなければ空' '' { "$(Get-WingetClientVersion -Lines @('error'))" }
Test-Case '1.30 以降なら True・1.29 以前なら False・読めなければ空' 'True False True ' {
    "$(Test-WingetModernPortable -WingetVersion ([version]'1.30.310')) $(Test-WingetModernPortable -WingetVersion ([version]'1.29.380')) $(Test-WingetModernPortable -WingetVersion ([version]'1.31.0')) $(Test-WingetModernPortable -WingetVersion $null)"
}

# Get-CodexLinkState: WinGet\Links\codex.exe が置き場所の exe への symlink か
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

# Get-CodexInstallRoute: winget を打てるか (UAC で昇格する道は無い)
$w130 = [version]'1.30.310'
$w129 = [version]'1.29.380'
Test-Case '昇格していない会話で 1.30 なら、開発者モードが off でも direct (hardlink の形になる)' 'direct' { Get-CodexInstallRoute -Elevated $false -DeveloperMode $false -WingetVersion $w130 }
Test-Case '開発者モードなら 1.29 でも direct (symlink を作れる)' 'direct' { Get-CodexInstallRoute -Elevated $false -DeveloperMode $true -WingetVersion $w129 }
Test-Case '昇格していない会話で開発者モードが off で 1.29 なら old-winget' 'old-winget' { Get-CodexInstallRoute -Elevated $false -DeveloperMode $false -WingetVersion $w129 }
Test-Case '昇格した会話で 1.30 なら elevated (開発者モードでも)' 'elevated elevated' { "$(Get-CodexInstallRoute -Elevated $true -DeveloperMode $false -WingetVersion $w130) $(Get-CodexInstallRoute -Elevated $true -DeveloperMode $true -WingetVersion $w130)" }
Test-Case '昇格した会話で 1.29 なら direct (symlink を作れる)' 'direct' { Get-CodexInstallRoute -Elevated $true -DeveloperMode $false -WingetVersion $w129 }
Test-Case 'winget の版が読めなければ direct (打ってみる)' 'direct direct' { "$(Get-CodexInstallRoute -Elevated $false -DeveloperMode $false -WingetVersion $null) $(Get-CodexInstallRoute -Elevated $true -DeveloperMode $false -WingetVersion $null)" }

# Get-CodexPlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-CodexPlan -Exists $false -Installed $null -Target $V -AliasState 'missing' }
Test-Case 'symlink の形で揃っていれば none' 'none' { Get-CodexPlan -Exists $true -Installed $V -Target $V -AliasState 'symlink' }
Test-Case 'hardlink の形で揃っていれば none' 'none' { Get-CodexPlan -Exists $true -Installed $V -Target $V -AliasState 'hardlink' }
Test-Case '違う版なら change (codex と打てても)' 'change' { Get-CodexPlan -Exists $true -Installed $Newer -Target $V -AliasState 'hardlink' }
Test-Case 'exe があるのに版が読めなければ change' 'change' { Get-CodexPlan -Exists $true -Installed $null -Target $V -AliasState 'symlink' }
Test-Case '版が同じで codex と打てる形が無ければ relink' 'relink' { Get-CodexPlan -Exists $true -Installed $V -Target $V -AliasState 'missing' }
Test-Case '版が同じで codex と打てる形が違えば relink' 'relink' { Get-CodexPlan -Exists $true -Installed $V -Target $V -AliasState 'wrong' }

# Get-CodexDirection: 入れ替えの向き (winget show --versions の並びで決める)
$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '固定した版が新しければ up' 'up' { Get-CodexDirection -Versions $showVersions -Installed $Older -Target $V }
Test-Case '入っている版の方が新しければ down' 'down' { Get-CodexDirection -Versions $showVersions -Installed $Newer -Target $V }
Test-Case '入っている版が一覧に無ければ unknown' 'unknown' { Get-CodexDirection -Versions $showVersions -Installed '0.155.0' -Target $V }
Test-Case '一覧が読めなければ unknown' 'unknown' { Get-CodexDirection -Versions @() -Installed $Older -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか
$pinsNow = @(
    'Name              Id                        Version     Source Pin type'
    '-----------------------------------------------------------------------'
    'fzf               junegunn.fzf              0.75.0      winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsNow -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsNow + @("Codex             $Id              $V     winget Pinning")) -PackageId $Id }
Test-Case 'Id の前方一致では True にしない' 'False' { Test-WingetPinned -Lines @("x $($Id).Extra $V winget Pinning") -PackageId $Id }

# Get-WingetCommands: plan ごとに打つ winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
$put = "$common --version $V --installer-type portable --scope user --skip-dependencies --accept-package-agreements"
Test-Case 'install は版・portable・user スコープを名指しし、依存 (ripgrep・VCRedist) は入れない' "install $put" { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'change は 2 本 (外してから入れる)' "2 uninstall $common|install $put" { $c = @(Get-WingetCommands -Plan change -PackageId $Id -Version $V); "$($c.Count) $($c[0] -join ' ')|$($c[1] -join ' ')" }
Test-Case 'relink も 2 本 (同じ版を外してから入れ、winget に codex と打てる形を作らせる)' "2 uninstall $common|install $put" { $c = @(Get-WingetCommands -Plan relink -PackageId $Id -Version $V); "$($c.Count) $($c[0] -join ' ')|$($c[1] -join ' ')" }
Test-Case 'none なら打たない' 0 { @(Get-WingetCommands -Plan none -PackageId $Id -Version $V).Count }
# winget の pin と打つ引数 (Install-Ntn.Tests.ps1 と同じ): 入れ替えは uninstall → install で、upgrade を打たない
Test-Case 'どの plan も upgrade を打たず、--include-pinned も付けない' '' {
    @('install', 'change', 'relink', 'none') | ForEach-Object { @(Get-WingetCommands -Plan $_ -PackageId $Id -Version $V) } |
        Where-Object { ($_[0] -eq 'upgrade') -or (@($_) -contains '--include-pinned') } | ForEach-Object { $_ -join ' ' }
}
Test-Case '取得だけを確かめる winget download の引数 (portable を名指しする)' "download --id $Id --exact --source winget --version $V --installer-type portable --download-directory C:\tmp\dl --skip-dependencies --accept-package-agreements --accept-source-agreements --disable-interactivity" { (Get-WingetDownloadArguments -PackageId $Id -Version $V -Directory 'C:\tmp\dl') -join ' ' }

# Resolve-CodexOnPath: PATH を前から見て、最初に見つかった codex
$exists = { param($p) $p -in @($Link, $Npm, $Hard) }
Test-Case 'Links が先なら Links の codex.exe' $Link { Resolve-CodexOnPath -PathValue "$Links;C:\Users\u\AppData\Roaming\npm" -Names @('codex.exe', 'codex.cmd') -Exists $exists }
Test-Case 'npm の codex.cmd が先ならそれ' $Npm { Resolve-CodexOnPath -PathValue "C:\Users\u\AppData\Roaming\npm;$Links" -Names @('codex.exe', 'codex.cmd') -Exists $exists }
Test-Case '置き場所だけが PATH にある hardlink の形では、置き場所の codex.exe' $Hard { Resolve-CodexOnPath -PathValue $Pkg -Names @('codex.exe', 'codex.cmd', 'codex.bat', 'codex.ps1') -Exists $exists }
Test-Case '置き場所だけが PATH にあり hardlink が無い形 (winget 1.29 以前) では、codex は見つからない' '' { Resolve-CodexOnPath -PathValue $Pkg -Names @('codex.exe', 'codex.cmd', 'codex.bat', 'codex.ps1') -Exists { param($p) $p -eq $Exe } }
Test-Case '末尾の \・引用符・空白・空の要素を飛ばす' $Link { Resolve-CodexOnPath -PathValue ";; `"C:\Z\`" ; $Links\ ;" -Names @('codex.exe') -Exists $exists }

# Get-CodexPathKind: PATH で引かれる codex がどこのものか
Test-Case 'WinGet\Links\codex.exe なら links' 'links' { Get-CodexPathKind -Resolved $Link -LinksDir $Links -PackageDir $Pkg }
Test-Case '大文字小文字が違っても links' 'links' { Get-CodexPathKind -Resolved $Link.ToUpper() -LinksDir $Links -PackageDir $Pkg }
Test-Case '置き場所の codex.exe なら package' 'package' { Get-CodexPathKind -Resolved $Hard -LinksDir $Links -PackageDir $Pkg }
Test-Case 'npm の codex.cmd は other' 'other' { Get-CodexPathKind -Resolved $Npm -LinksDir $Links -PackageDir $Pkg }
Test-Case '公式の install.ps1 の codex.exe は other' 'other' { Get-CodexPathKind -Resolved 'C:\Users\u\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe' -LinksDir $Links -PackageDir $Pkg }
Test-Case '見つからなければ none' 'none' { Get-CodexPathKind -Resolved $null -LinksDir $Links -PackageDir $Pkg }

# Test-CodexPathListed / Get-CodexPathValueWithEntry: PATH に置き場所の codex-path があるか・足した値
Test-Case '末尾の \・引用符・大文字小文字の違いを寄せて見つける' 'True' { Test-CodexPathListed -Raw "C:\x;`"$($RgDir.ToUpper())\`"" -Dir $RgDir }
Test-Case '無ければ False' 'False' { Test-CodexPathListed -Raw "C:\x;$Pkg" -Dir $RgDir }
Test-Case '末尾の ; を落として足す' "C:\x;$Pkg;$RgDir" { Get-CodexPathValueWithEntry -Raw "C:\x;$Pkg;" -Dir $RgDir }
Test-Case 'あれば変えない (%VAR% の書き方も残す)' "C:\x;$RgDir;%USERPROFILE%\bin" { Get-CodexPathValueWithEntry -Raw "C:\x;$RgDir;%USERPROFILE%\bin" -Dir $RgDir }
Test-Case '空なら足すものだけ' $RgDir { Get-CodexPathValueWithEntry -Raw '' -Dir $RgDir }

# Test-CodexMangledPathEntry / Get-CodexMangledPathCount / Get-CodexPathValueWithoutEntries: 化けた codex-path の行と、外した PATH の値
Test-Case '\codex-path は化けた行 (末尾の \・引用符・大文字小文字も)' 'True True True' { "$(Test-CodexMangledPathEntry -Entry '\codex-path') $(Test-CodexMangledPathEntry -Entry ' "\Codex-Path\" ') $(Test-CodexMangledPathEntry -Entry '\CODEX-PATH')" }
Test-Case '置き場所の codex-path・ほかの codex-path は化けた行ではない' 'False False False' { "$(Test-CodexMangledPathEntry -Entry $RgDir) $(Test-CodexMangledPathEntry -Entry 'C:\tools\codex-path') $(Test-CodexMangledPathEntry -Entry '')" }
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

# Get-WingetFailureHint: 0x8A15007D (昇格した会話からの user スコープの portable) にだけ添える
Test-Case '0x8A15007D には、昇格していない PowerShell で打ち直すと添える' $true { (Get-WingetFailureHint -ExitCode -1978335107) -like '*昇格していない PowerShell で Install-Codex を打ち直す*' }
Test-Case 'ほかの終了コードには添えない' '' { Get-WingetFailureHint -ExitCode 1 }

# 状態の既定 (symlink の形で揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; ExeName = $ExeName; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; LinkState = 'ok'; LinkTarget = $Exe; HardlinkState = 'ok'; AliasState = 'symlink'
        PathResolved = $Link; PathKind = 'links'; RgState = 'na'; MangledPath = 0; WingetVersion = $w130; Route = 'direct'; BusyCount = 0
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; ExeName = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; LinkState = 'missing'; LinkTarget = ''; HardlinkState = 'missing'; AliasState = 'missing'; PathKind = 'none'; PathResolved = $null }
# 開発者モードが off の PC で、昇格していない winget 1.30 が入れた形 (Links に symlink が無く、置き場所の codex.exe と、置き場所の PATH の行)
$hardlinkForm = @{ LinkState = 'missing'; LinkTarget = ''; AliasState = 'hardlink'; PathKind = 'package'; PathResolved = $Hard; RgState = 'ok' }
$hardRgMissing = $hardlinkForm.Clone()
$hardRgMissing.RgState = 'missing'
$hardRgAbsent = $hardlinkForm.Clone()
$hardRgAbsent.RgState = 'absent'
# winget 1.29 以前が symlink を作れずに入れた形 (codex と打てる形が無く、置き場所が PATH にある。pin も無い)
$fallback = @{ Plan = 'relink'; LinkState = 'missing'; LinkTarget = ''; HardlinkState = 'missing'; AliasState = 'missing'; PathKind = 'none'; PathResolved = $null; Pinned = $false }
# 手で入れた新しい版 (pin も無い)
$handNewer = @{ Installed = $Newer; Plan = 'change'; Direction = 'down'; Pinned = $false; Versions = @($Newer, $V, $Older); Latest = $Newer }

# Test-CodexDrift / Test-CodexPathDrift / Test-CodexBlocked
Test-Case '揃っていれば差は無い' 'False False False' { $s = New-State; "$(Test-CodexDrift -State $s) $(Test-CodexPathDrift -State $s) $(Test-CodexBlocked -State $s)" }
Test-Case 'hardlink の形で揃っていても差は無い' 'False False False' { $s = New-State $hardlinkForm; "$(Test-CodexDrift -State $s) $(Test-CodexPathDrift -State $s) $(Test-CodexBlocked -State $s)" }
Test-Case 'pin が無ければ揃える手順で直る差' 'True False' { $s = New-State @{ Pinned = $false }; "$(Test-CodexDrift -State $s) $(Test-CodexPathDrift -State $s)" }
Test-Case 'hardlink の形で codex-path が PATH に無ければ揃える手順で直る差' 'True False' { $s = New-State $hardRgMissing; "$(Test-CodexDrift -State $s) $(Test-CodexPathDrift -State $s)" }
Test-Case 'ユーザーの PATH に化けた codex-path の行があれば揃える手順で直る差 (終了コード 1)' 'True False 1' { $s = New-State @{ MangledPath = 1 }; "$(Test-CodexDrift -State $s) $(Test-CodexPathDrift -State $s) $(Get-CodexExitCode -State $s)" }
Test-Case 'codex と打てる形が無いのは揃える手順で直る差 (PATH で見つからないのは、ずれに数えない)' 'True False' { $s = New-State $fallback; "$(Test-CodexDrift -State $s) $(Test-CodexPathDrift -State $s)" }
Test-Case 'PATH でほかの codex が先なら PATH のずれ (揃える手順では直らない)' 'False True' { $s = New-State @{ PathKind = 'other'; PathResolved = $Npm }; "$(Test-CodexDrift -State $s) $(Test-CodexPathDrift -State $s)" }
Test-Case 'codex と打てる形はあるのに PATH で見つからなければ PATH のずれ' 'True' { Test-CodexPathDrift -State (New-State @{ PathKind = 'none'; PathResolved = $null }) }
Test-Case '入っていないときに PATH に無いのは、ずれに数えない' 'False' { Test-CodexPathDrift -State (New-State $missing) }
Test-Case 'elevated・old-winget で入れる・入れ直す・入れ替えるなら Test-CodexBlocked は True' 'True True True True' { "$(Test-CodexBlocked -State (New-State ($missing + @{ Route = 'elevated' }))) $(Test-CodexBlocked -State (New-State ($missing + @{ Route = 'old-winget' }))) $(Test-CodexBlocked -State (New-State ($fallback + @{ Route = 'old-winget' }))) $(Test-CodexBlocked -State (New-State ($handNewer + @{ Route = 'elevated' })))" }
Test-Case 'elevated・old-winget でも版と codex と打てる形が揃っていれば (winget を打たないので) False' 'False False' { "$(Test-CodexBlocked -State (New-State @{ Route = 'elevated'; Pinned = $false })) $(Test-CodexBlocked -State (New-State @{ Route = 'old-winget' }))" }

# Get-CodexExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-CodexExitCode -State (New-State) }
Test-Case 'hardlink の形で揃っていれば 0' 0 { Get-CodexExitCode -State (New-State $hardlinkForm) }
Test-Case 'pin が無ければ 1' 1 { Get-CodexExitCode -State (New-State @{ Pinned = $false }) }
Test-Case '版が違えば 1' 1 { Get-CodexExitCode -State (New-State $handNewer) }
Test-Case 'codex と打てる形が無ければ 1' 1 { Get-CodexExitCode -State (New-State $fallback) }
Test-Case 'hardlink の形で codex-path が PATH に無ければ 1' 1 { Get-CodexExitCode -State (New-State $hardRgMissing) }
Test-Case 'PATH でほかの codex が先なら 1' 1 { Get-CodexExitCode -State (New-State @{ PathKind = 'other'; PathResolved = $Npm }) }
Test-Case '入っていなければ 3' 3 { Get-CodexExitCode -State (New-State $missing) }
Test-Case 'elevated・old-winget なら、入っていなくても 1 (runner に入れにいかせない)' '1 1' { "$(Get-CodexExitCode -State (New-State ($missing + @{ Route = 'elevated' }))) $(Get-CodexExitCode -State (New-State ($missing + @{ Route = 'old-winget' })))" }

# Get-CodexApplyBlocker: 揃える前に止める理由
Test-Case '入れられるなら止めない' '' { Get-CodexApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 0 -Route direct }
Test-Case 'elevated・old-winget で入れるなら、その理由 (ほかの理由より先)' 'elevated old-winget' { "$(Get-CodexApplyBlocker -Plan change -Versions $versions -Target '0.1.0' -BusyCount 1 -Route elevated) $(Get-CodexApplyBlocker -Plan relink -Versions $versions -Target $V -BusyCount 1 -Route old-winget)" }
Test-Case 'elevated でも pin を足すだけなら止めない' '' { Get-CodexApplyBlocker -Plan none -Versions $versions -Target $V -BusyCount 0 -Route elevated }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-CodexApplyBlocker -Plan install -Versions $versions -Target '0.1.0' -BusyCount 0 -Route direct }
Test-Case 'winget show が失敗して一覧が空なら、一覧では止めない' '' { Get-CodexApplyBlocker -Plan change -Versions @() -Target $V -BusyCount 0 -Route direct }
Test-Case '入れ替えるのに codex が動いていれば busy' 'busy' { Get-CodexApplyBlocker -Plan change -Versions $versions -Target $V -BusyCount 1 -Route direct }
Test-Case '入れ直すのに codex が動いていれば busy' 'busy' { Get-CodexApplyBlocker -Plan relink -Versions $versions -Target $V -BusyCount 2 -Route direct }
Test-Case '入れるだけなら動いている数は見ない' '' { Get-CodexApplyBlocker -Plan install -Versions $versions -Target $V -BusyCount 2 -Route direct }

# Format-CodexState: 状態の表の行
function Get-Rows { param($State) @(Format-CodexState -State $State -Target $V -PackageId $Id -PackageDir $Pkg) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 8 行だけ (同梱の rg の行も)' 8 { (Get-Rows (New-State)).Count }
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
Test-Case 'codex と打てる形はあるのに PATH で見つからなければ ⚠ と、PATH への足し方' "⚠ PATH の codex   : 見つからない|※ PATH で codex が見つからない。symlink の形なら %LOCALAPPDATA%\Microsoft\WinGet\Links を、hardlink の形なら置き場所 ($Pkg) をユーザーの PATH に足し、新しい PowerShell を開く" { $r = Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }); "$($r[6].Text)|$($r[-1].Text)" }
Test-Case '版が読めないとき' '  入っている版    : 不明 (codex --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'PATH でほかの codex が先なら、その場所を ⚠ で出し、外し方を ※ で添える' "⚠ PATH の codex   : $Npm (winget のものではない)|※ PATH のずれは Install-Codex では直らない。C:\Users\u\AppData\Roaming\npm の codex を外す (npm の @openai/codex なら npm uninstall -g @openai/codex) か、C:\Users\u\AppData\Roaming\npm をユーザーの PATH から外す (win/README.md の「Codex CLI」)" { $r = Get-Rows (New-State @{ PathKind = 'other'; PathResolved = $Npm }); "$($r[6].Text)|$($r[-1].Text)" }
Test-Case 'winget show が失敗したら最新版は不明で、一覧についての ※/⚠ は出さない' '  winget の最新版 : 不明 (winget show が失敗) 8' { $r = Get-Rows (New-State @{ Versions = @(); Latest = $null }); "$($r[3].Text) $($r.Count)" }
Test-Case '新しい版があれば ※ で知らせる (⚠ にしない)' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-Codex.ps1 の -Version の既定値を変える 0" { $r = Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }); "$($r[8].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '固定した版が winget から消えても、入っていれば ※' '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える' { (Get-Rows (New-State @{ Versions = @($Newer, $Older); Latest = $Newer }))[8].Text }
Test-Case '固定した版が winget に無くて入れられないなら ⚠' '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない' { (Get-Rows (New-State ($missing + @{ Versions = @($Newer, $Older); Latest = $Newer })))[7].Text }
Test-Case 'direct で入れ直すときは、昇格・UAC の行を出さない' 7 { (Get-Rows (New-State $fallback)).Count }
Test-Case 'elevated で入れるなら、⚠ と、昇格していない PowerShell で打ち直す ※ を添える' "⚠ 昇格した PowerShell では winget が codex を入れない (winget 1.30.310 は、昇格した会話から user スコープの portable を入れる・外すのを断る)。Install-Codex は winget を打たない|※ 昇格していない PowerShell (デスクトップの普通の端末) で Install-Codex を打ち直す (win/README.md の「Codex CLI」)" { $r = Get-Rows (New-State ($missing + @{ Route = 'elevated' })); "$($r[-2].Text)|$($r[-1].Text)" }
Test-Case 'old-winget で入れるなら、⚠ と、winget の更新か開発者モードの ※ を添える' "⚠ winget が古く、codex と打てる形を作れない (winget 1.29.380 は symlink を作れないときに codex.exe の hardlink を作らず、開発者モードも off)。入れても codex と打てないので、Install-Codex は入れない|※ Install-WinGet で winget を固定した版 (1.30 以降) に上げるか、開発者モードを on にして (設定 > システム > 開発者向け。管理者が要る)、Install-Codex を打ち直す (win/README.md の「winget」「Codex CLI」)" { $r = Get-Rows (New-State ($fallback + @{ Route = 'old-winget'; WingetVersion = $w129 })); "$($r[-2].Text)|$($r[-1].Text)" }
Test-Case '入れ替えが要るのに codex が動いていれば ※ で添える' '※ codex が 1 個動いている。入れ替えるには、動いている codex (ほかの端末の会話など) を終わらせる' { (Get-Rows (New-State ($handNewer + @{ BusyCount = 1 })))[-1].Text }
Test-Case '入れ替えが要らなければ動いている数は出さない' 8 { (Get-Rows (New-State @{ BusyCount = 2 })).Count }

# Format-CodexVerdict: 締めの行。Windows の runner (win/runner/src/steps/ps1.rs) がこの文言で、入れるか・揃えるか・知らせるだけかを決める
function Get-Verdict { param($State) (@(Format-CodexVerdict -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '揃っていれば締めの行は出さない' '' { Get-Verdict (New-State) }
Test-Case 'hardlink の形で揃っていても締めの行は出さない' '' { Get-Verdict (New-State $hardlinkForm) }
Test-Case '入っていなければ、Install-Codex で入れると出す' '⚠️ Codex CLI が入っていない → Install-Codex で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case '版か pin の差があれば、Install-Codex で揃えると出す' '⚠️ 固定した版と揃っていない → Install-Codex で揃える ⚠️' { Get-Verdict (New-State $handNewer) }
Test-Case 'codex と打てる形が無ければ、codex と打てないと出し、Install-Codex で揃える' "⚠️ 固定した版と揃っていない → Install-Codex で揃える ⚠️`n⚠️ codex と打てない (WinGet\Links の symlink も、置き場所の codex.exe の hardlink も無い・違う) → Install-Codex で揃える ⚠️" { Get-Verdict (New-State $fallback) }
$fallbackPinned = $fallback.Clone()
$fallbackPinned.Pinned = $true
Test-Case 'codex と打てる形だけが無ければ、その 1 行だけ' '⚠️ codex と打てない (WinGet\Links の symlink も、置き場所の codex.exe の hardlink も無い・違う) → Install-Codex で揃える ⚠️' { Get-Verdict (New-State $fallbackPinned) }
Test-Case 'hardlink の形で codex-path が PATH に無ければ、Install-Codex で揃えると出す' '⚠️ codex が同梱の rg を引けない (置き場所の codex-path が PATH に無い) → Install-Codex で揃える ⚠️' { Get-Verdict (New-State $hardRgMissing) }
Test-Case '化けた codex-path の行があれば、Install-Codex で揃えると出す' '⚠️ ユーザーの PATH に化けた codex-path の行 (\codex-path) が残っている → Install-Codex で揃える ⚠️' { Get-Verdict (New-State @{ MangledPath = 1 }) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す (揃えるとは言わない)' '⚠️ PATH の codex が winget のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = $Npm }) }
Test-Case 'elevated なら、その 1 行だけ (入れる・揃えるとは言わない)' '⚠️ 昇格した PowerShell では winget が codex を入れない (winget 1.30 から) → ※ の手順で直す ⚠️' { "$(Get-Verdict (New-State ($missing + @{ Route = 'elevated' })))" }
Test-Case 'old-winget なら、その 1 行だけ' '⚠️ winget が古く、codex と打てる形を作れない (winget 1.29 以前で、開発者モードも off) → ※ の手順で直す ⚠️' { "$(Get-Verdict (New-State ($fallback + @{ Route = 'old-winget' })))" }
Test-Case 'elevated でも揃っていれば締めの行は出さない' '' { Get-Verdict (New-State @{ Route = 'elevated' }) }

# 昇格して winget を打つ道は無い (UAC を出さない)
Test-Case 'Install-Codex.ps1 は Start-Process -Verb RunAs を使わない' $false { (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Install-Codex.ps1') -Raw) -match 'RunAs' }

# Get-CodexInstalledVersion: 起動できない exe (壊れた・0 バイト) でも例外で止まらず、版は空
$broken = Join-Path ([IO.Path]::GetTempPath()) "install-codex-tests-broken-$PID.exe"
Set-Content -LiteralPath $broken -Value '' -NoNewline
if (-not $IsWindows) { chmod +x $broken }
Test-Case '起動できない exe なら版は空 (入れ替えの対象になる)' '' { Get-CodexInstalledVersion -Exe $broken }
Remove-Item -LiteralPath $broken -Force

# Find-CodexExe: この PC の CPU の名前を先に見て、無ければもう一方
$findRoot = Join-Path ([IO.Path]::GetTempPath()) "install-codex-tests-find-$PID"
$x64 = Join-Path $findRoot 'codex-x86_64-pc-windows-msvc.exe'
$arm = Join-Path $findRoot 'codex-aarch64-pc-windows-msvc.exe'
New-Item -ItemType Directory -Force -Path $findRoot | Out-Null
Test-Case '置き場所に無ければ空' '' { Find-CodexExe -PackageDir $findRoot }
# winget 1.30 が置く hardlink の codex.exe は、置き場所の exe としては拾わない
New-Item -ItemType File -Force -Path (Join-Path $findRoot 'codex.exe') | Out-Null
Test-Case 'codex.exe (hardlink) だけなら空' '' { Find-CodexExe -PackageDir $findRoot }
New-Item -ItemType File -Force -Path $arm | Out-Null
$savedArch = $env:PROCESSOR_ARCHITECTURE
$savedWow = $env:PROCESSOR_ARCHITEW6432
$env:PROCESSOR_ARCHITEW6432 = $null
$env:PROCESSOR_ARCHITECTURE = 'AMD64'
Test-Case 'x64 の PC でも、arm64 の exe しか無ければそれ' $arm { Find-CodexExe -PackageDir $findRoot }
New-Item -ItemType File -Force -Path $x64 | Out-Null
Test-Case 'x64 の PC では x86_64 の exe を先に見る' $x64 { Find-CodexExe -PackageDir $findRoot }
$env:PROCESSOR_ARCHITECTURE = 'ARM64'
Test-Case 'arm64 の PC では aarch64 の exe を先に見る' $arm { Find-CodexExe -PackageDir $findRoot }
$env:PROCESSOR_ARCHITECTURE = $savedArch
$env:PROCESSOR_ARCHITEW6432 = $savedWow
Remove-Item -LiteralPath $findRoot -Recurse -Force

# 本体の入口: Linux の pwsh には $env:LOCALAPPDATA が無く、本体の最初で例外になる。
# それでも終了コード 2 で止まり、成功 (0) に見せない
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-Codex.ps1') -Check 2>&1
    $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Invoke-InstallCodex の流れ。Windows に触る関数を偽物に差し替えて、打つ winget の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-codex-tests-$PID"
$FakeExe = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe') 'codex-x86_64-pc-windows-msvc.exe'
$env:PROCESSOR_ARCHITEW6432 = $null
$env:PROCESSOR_ARCHITECTURE = 'AMD64'

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
    if (($Arguments[0] -eq 'pin') -and ($Arguments[1] -eq 'list') -and $script:PinListed) { $lines = @("Codex $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Get-CodexState { param($PackageId, $PackageDir, $LinksDir, $Target) $script:States.Dequeue() }
function Get-CodexBusyProcess { param($PackageDir, $LinksDir) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'codex.exe exec hello' } }
# 入れた後の PATH の codex と同梱の rg (揃える流れが codex-path を足すかを決める)。足したら 'path add' を記録する
function Get-CodexPathState { param($PackageDir, $LinksDir) [pscustomobject]@{ Resolved = $null; Kind = 'package'; RgDir = "$PackageDir\codex-path"; RgState = $script:RgAfter } }
function Add-CodexUserPath { param($Dir) $script:Calls.Add("path add $(Split-Path -Leaf $Dir)") }
# 外す行 (自分の codex-path) を記録する。化けた行は渡さなくても外す
function Remove-CodexUserPath { param([string[]]$Dirs) $script:Calls.Add("path remove [$(@($Dirs | Where-Object { $_ } | ForEach-Object { Split-Path -Leaf $_ }) -join ' ')]"); 0 }

# 1 回ぶんの流れを走らせ、打った winget・画面の行・終了コードを返す。
# $States は Get-CodexState が返す順 (揃える前と、揃えた後に読み直したもの)
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
    $out = @(Invoke-InstallCodex -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
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
$pinnedNewer = $handNewer.Clone()
$pinnedNewer.Pinned = $true
Test-Case 'pin があれば、入れ替えの前に外す' '0 [download pin remove path remove [codex-path] uninstall install pin list pin add]' { $r = Invoke-Flow -States @((New-State $pinnedNewer), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
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
Test-Case 'elevated なら、引数なしでも winget を打たずに 1 で止まり、昇格していない PowerShell で打ち直すと出す' '1 [] True' { $r = Invoke-Flow -States @((New-State ($missing + @{ Route = 'elevated' }))); "$($r.Code) [$($r.Calls)] $($r.Text -like '*昇格していない PowerShell で Install-Codex を打ち直す*')" }
Test-Case 'old-winget なら、引数なしでも winget を打たずに 1 で止まり、winget の更新の手を出す' '1 [] True' { $r = Invoke-Flow -States @((New-State ($fallback + @{ Route = 'old-winget' }))) -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*winget を更新するか開発者モードを on にしてから打ち直す*')" }
Test-Case 'elevated・old-winget なら、-IfMissing でも入れずに 1' '1 [] 1 []' { $a = Invoke-Flow -States @((New-State ($missing + @{ Route = 'elevated' }))) -IfMissing; $b = Invoke-Flow -States @((New-State ($missing + @{ Route = 'old-winget' }))) -IfMissing; "$($a.Code) [$($a.Calls)] $($b.Code) [$($b.Calls)]" }
$pathOnly = New-State @{ PathKind = 'other'; PathResolved = $Npm }
Test-Case 'PATH のずれだけなら winget を打たずに 1 で止まり、※ の手順で直すと出す' '1 [] True' { $r = Invoke-Flow -States @($pathOnly) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)] $($r.Text -like '*※ の手順で直す*')" }
Test-Case '揃えた後も PATH のずれが残れば、版と pin と codex と打てる形は揃ったと出して 1' '1 True' { $r = Invoke-Flow -States @((New-State ($handNewer + @{ PathKind = 'other'; PathResolved = $Npm })), $pathOnly) -ExeExists; "$($r.Code) $($r.Text -like '*版と pin と codex と打てる形は揃った*')" }
Test-Case '揃えたら、新しい PowerShell から codex と打てると出す' $true { $r = Invoke-Flow -States @($fallbackState, $syncedHard) -ExeExists; $r.Text -like '*揃った (新しい PowerShell から codex と打てる)*' }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
