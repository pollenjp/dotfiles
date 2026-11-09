# win/herdr-app/Install-HerdrApp.ps1 のうち、副作用の無い関数と、Windows に触る関数を偽物に替えた流れのテスト。
# Pester は使わない (Install-Herdr.Tests.ps1 と同じ作り)。ダウンロード・署名・レジストリ・ショートカット・プロセスに触る部分は、
# 実機で -Check・本番・-Uninstall を打って確かめる (win/README.md の「herdr-app」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/herdr-app/Install-HerdrApp.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-HerdrApp.ps1 の末尾)
. (Join-Path $PSScriptRoot 'Install-HerdrApp.ps1')

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

$R = 'https://releases.herdr.dev'
$App = 'C:\Users\u\AppData\Local\Programs\herdr-app'
$Core = 'C:\Users\u\AppData\Local\Programs\herdr-core'
$Menu = 'C:\Users\u\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Herdr.lnk'
$Feed = 'C:\Users\u\AppData\Local\dotfiles\herdr-releases'
$FeedUrl = 'file:///C:/Users/u/AppData/Local/dotfiles/herdr-releases'
$AppExe = "$App\herdr-app.exe"
$ShaA = 'dc1b5663244ed91d96f42e7ddeec73304bb955474142975f290711cabcf0354a'
$ShaC = 'a212b69db0efb808882683f15e5da45ab9606da7bcc54b97b29ed4fa540f5491'
$Pins = [pscustomobject]@{ AppVersion = '0.1.12'; AppSha256 = $ShaA; CoreVersion = '0.1.17'; CoreSha256 = $ShaC; CoreGeneration = 1 }
# 2026-11-10 に Get-AuthenticodeSignature が app 0.1.12 の herdr-app.exe に返したもの
$GoodSig = [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=herdr, O=herdr, L=Wilmington, S=Delaware, C=US'; Issuer = 'CN=Microsoft ID Verified CS AOC CA 04, O=Microsoft Corporation, C=US' }
function New-Sig {
    param([hashtable]$Change)
    $s = [ordered]@{ Status = $GoodSig.Status; Subject = $GoodSig.Subject; Issuer = $GoodSig.Issuer }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}

# Get-HerdrAppArchitecture: 32 bit の PowerShell から呼ばれても OS の arch を見る
Test-Case '64 bit の PowerShell なら PROCESSOR_ARCHITECTURE' 'AMD64' { Get-HerdrAppArchitecture -Architecture 'AMD64' -Architecture6432 '' }
Test-Case '32 bit の PowerShell からは PROCESSOR_ARCHITEW6432 を見る' 'AMD64' { Get-HerdrAppArchitecture -Architecture 'x86' -Architecture6432 'AMD64' }
Test-Case 'ARM64 は ARM64 のまま' 'ARM64' { Get-HerdrAppArchitecture -Architecture 'ARM64' -Architecture6432 $null }

# Test-HerdrAppPins: 固定した版と sha256 の書き方
function Get-BadPins {
    param([hashtable]$Change)
    $p = [ordered]@{ AppVersion = $Pins.AppVersion; AppSha256 = $Pins.AppSha256; CoreVersion = $Pins.CoreVersion; CoreSha256 = $Pins.CoreSha256; CoreGeneration = $Pins.CoreGeneration }
    foreach ($k in $Change.Keys) { $p[$k] = $Change[$k] }
    Test-HerdrAppPins -Pins ([pscustomobject]$p)
}
Test-Case '正しい書き方なら空' '' { Test-HerdrAppPins -Pins $Pins }
Test-Case '版の形でなければ断る (JSON に書くので形を絞る)' 'AppVersion が版の形 (例 0.1.12) でない: 0.1.12"' { Get-BadPins @{ AppVersion = '0.1.12"' } }
Test-Case 'v 付きの版も断る' 'CoreVersion が版の形 (例 0.1.12) でない: v0.1.17' { Get-BadPins @{ CoreVersion = 'v0.1.17' } }
Test-Case '大文字の hex は断る' "AppSha256 が 64 桁の小文字の hex でない: $($ShaA.ToUpper())" { Get-BadPins @{ AppSha256 = $ShaA.ToUpper() } }
Test-Case '桁の足りない sha256 は断る' 'CoreSha256 が 64 桁の小文字の hex でない: abc' { Get-BadPins @{ CoreSha256 = 'abc' } }
Test-Case 'generation が 0 なら断る' 'CoreGeneration が 1 以上でない: 0' { Get-BadPins @{ CoreGeneration = 0 } }

# Get-HerdrAppArtifactUrl / Get-HerdrAppDownloadUrl
Test-Case 'app の版つきの成果物の URL' "$R/app/0.1.12/herdr-app-windows-x86_64.tar.gz" { Get-HerdrAppArtifactUrl -Releases $R -Kind 'app' -Version '0.1.12' }
Test-Case 'core の版つきの成果物の URL' "$R/core/0.1.17/herdr-core-windows-x86_64.zip" { Get-HerdrAppArtifactUrl -Releases $R -Kind 'core' -Version '0.1.17' }
Test-Case 'releases の素の URL には ?src= を付ける' "$R/app/0.1.12/a.tar.gz?src=install" { Get-HerdrAppDownloadUrl -Url "$R/app/0.1.12/a.tar.gz" -Releases $R -Src 'install' }
Test-Case '? を含む URL (mirror の署名付き) はそのまま' "$R/app/a.tar.gz?sig=1" { Get-HerdrAppDownloadUrl -Url "$R/app/a.tar.gz?sig=1" -Releases $R -Src 'install' }
Test-Case 'releases の前方一致 (releases.herdr.dev.example) には付けない' 'https://releases.herdr.dev.example/a' { Get-HerdrAppDownloadUrl -Url 'https://releases.herdr.dev.example/a' -Releases $R -Src 'install' }

# Get-HerdrAppFeedFiles: 手元のフィードに置くファイル
$files = @(Get-HerdrAppFeedFiles -Pins $Pins -Releases $R)
Test-Case 'フィードは app と core の latest.json と、core の版つきの manifest の 3 つ (install.ps1 は置かない)' 'app\latest.json core\latest.json core\0.1.17\manifest.json' { $files | ForEach-Object { $_.Path } }
Test-Case 'app/latest.json の中身 (LF・末尾に改行 1 つ)' (@('{', '  "version": "0.1.12",', '  "targets": {', '    "windows-x86_64": {', "      `"url`": `"$R/app/0.1.12/herdr-app-windows-x86_64.tar.gz`",", "      `"sha256`": `"$ShaA`"", '    }', '  }', '}', '') -join "`n") { $files[0].Text }
Test-Case 'core/latest.json は generation を持つ' 1 { ($files[1].Text | ConvertFrom-Json).generation }
Test-Case 'core/latest.json の成果物は固定した版の URL と sha256' "$R/core/0.1.17/herdr-core-windows-x86_64.zip $ShaC" { $t = ($files[1].Text | ConvertFrom-Json).targets.'windows-x86_64'; "$($t.url) $($t.sha256)" }
Test-Case 'core の版つきの manifest は core/latest.json と同じ中身' $true { $files[2].Text -ceq $files[1].Text }
Test-Case 'app/latest.json を JSON として読める (app が読む版)' '0.1.12' { ($files[0].Text | ConvertFrom-Json).version }
Test-Case 'CR を含まない' 0 { @($files | Where-Object { $_.Text.Contains("`r") }).Count }

# Get-HerdrAppFeedUrl: フィードを指す file:/// の URL
Test-Case 'Windows のパスを file:/// の URL にする' $FeedUrl { Get-HerdrAppFeedUrl -FeedDir "$Feed\" }
Test-Case '空白は %20 にする (curl.exe が読む)' 'file:///C:/Users/John%20Smith/AppData/Local/dotfiles/herdr-releases' { Get-HerdrAppFeedUrl -FeedDir 'C:\Users\John Smith\AppData\Local\dotfiles\herdr-releases' }

# Compare-HerdrAppVersion
Test-Case '古ければ -1' -1 { Compare-HerdrAppVersion -A '0.1.12' -B '0.1.13' }
Test-Case '新しければ 1' 1 { Compare-HerdrAppVersion -A '0.1.14' -B '0.1.12' }
Test-Case '同じなら 0' 0 { Compare-HerdrAppVersion -A '0.1.12' -B '0.1.12' }
Test-Case '数として比べる (0.1.9 < 0.1.10)' -1 { Compare-HerdrAppVersion -A '0.1.9' -B '0.1.10' }
Test-Case '版の形でなければ空' '' { Compare-HerdrAppVersion -A $null -B '0.1.12' }

# Get-HerdrAppDnValue / Test-HerdrAppSignature: herdr の正しい署名か
Test-Case '識別名から CN を拾う' 'herdr' { Get-HerdrAppDnValue -Dn $GoodSig.Subject -Key 'CN' }
Test-Case '識別名から O を拾う (大文字小文字を区別しない名前)' 'Microsoft Corporation' { Get-HerdrAppDnValue -Dn $GoodSig.Issuer -Key 'o' }
Test-Case '無い名前は空' '' { Get-HerdrAppDnValue -Dn $GoodSig.Subject -Key 'OU' }
Test-Case 'Valid で発行先が herdr、発行元が Microsoft ID Verified CS なら空' '' { Test-HerdrAppSignature -Signature $GoodSig }
Test-Case '発行元の CA の番号が違っても通す (AOC CA 03 と 04 の両方を見た)' '' { Test-HerdrAppSignature -Signature (New-Sig @{ Issuer = 'CN=Microsoft ID Verified CS AOC CA 03, O=Microsoft Corporation, C=US' }) }
Test-Case '署名を読めなければ断る' '署名を確かめられない (Get-AuthenticodeSignature が使えない)' { Test-HerdrAppSignature -Signature $null }
Test-Case '署名の無い exe は断る' '署名が Valid でない (NotSigned)' { Test-HerdrAppSignature -Signature (New-Sig @{ Status = 'NotSigned'; Subject = $null; Issuer = $null }) }
Test-Case '中身が署名と合わなければ断る' '署名が Valid でない (HashMismatch)' { Test-HerdrAppSignature -Signature (New-Sig @{ Status = 'HashMismatch' }) }
Test-Case '発行先が herdr でなければ断る' '発行先が herdr でない (CN=evil, O=herdr)' { Test-HerdrAppSignature -Signature (New-Sig @{ Subject = 'CN=evil, O=herdr' }) }
Test-Case '発行先の O が違えば断る' '発行先が herdr でない (CN=herdr, O=Herdr Inc)' { Test-HerdrAppSignature -Signature (New-Sig @{ Subject = 'CN=herdr, O=Herdr Inc' }) }
Test-Case '発行元が別の CA なら断る' '発行元が Microsoft ID Verified CS の CA でない (CN=Some CA, O=Microsoft Corporation)' { Test-HerdrAppSignature -Signature (New-Sig @{ Issuer = 'CN=Some CA, O=Microsoft Corporation' }) }
Test-Case '発行元の O が違えば断る' '発行元が Microsoft ID Verified CS の CA でない (CN=Microsoft ID Verified CS AOC CA 04, O=Evil)' { Test-HerdrAppSignature -Signature (New-Sig @{ Issuer = 'CN=Microsoft ID Verified CS AOC CA 04, O=Evil' }) }

# Test-HerdrAppPathEntry / Test-HerdrAppPathListed: PATH の要素が置き場所を指すか
Test-Case '同じ置き場所なら合う' 'True' { Test-HerdrAppPathEntry -Entry $App -Dir $App }
Test-Case '末尾の \・前後の空白・引用符・大文字小文字の違いは合う' 'True' { Test-HerdrAppPathEntry -Entry " `"$($App.ToUpper())\`" " -Dir $App }
Test-Case '%VAR% を展開してから比べる' 'True' { $env:HERDR_APP_TEST_LOCALAPPDATA = 'C:\Users\u\AppData\Local'; Test-HerdrAppPathEntry -Entry '%HERDR_APP_TEST_LOCALAPPDATA%\Programs\herdr-app' -Dir $App }
Test-Case '前方一致 (herdr-app2) は合わない' 'False' { Test-HerdrAppPathEntry -Entry "$($App)2" -Dir $App }
Test-Case '空の要素は合わない' 'False' { Test-HerdrAppPathEntry -Entry '' -Dir $App }
Test-Case 'どこかの要素が合えば listed' 'True' { Test-HerdrAppPathListed -Raw "C:\A;;$App\;C:\B" -Dir $App }
Test-Case '空の PATH は listed でない' 'False' { Test-HerdrAppPathListed -Raw '' -Dir $App }

# Get-PathValueWithEntry / Get-PathValueWithoutEntry
Test-Case '空の PATH なら置き場所だけ' $App { Get-PathValueWithEntry -Raw '' -Dir $App }
Test-Case '末尾の ; を落としてから足す' "C:\A;$App" { Get-PathValueWithEntry -Raw 'C:\A;' -Dir $App }
Test-Case '%VAR% の書き方はそのまま残して足す' "%USERPROFILE%\bin;C:\A;$App" { Get-PathValueWithEntry -Raw '%USERPROFILE%\bin;C:\A' -Dir $App }
Test-Case '既にあれば変えない (書き違いでも)' "C:\A;$($App.ToUpper())\" { Get-PathValueWithEntry -Raw "C:\A;$($App.ToUpper())\" -Dir $App }
Test-Case '置き場所の要素だけを外す' 'C:\A;C:\B' { Get-PathValueWithoutEntry -Raw "C:\A;$App;C:\B" -Dirs @($App) }
Test-Case '2 つの置き場所をまとめて外す' 'C:\A' { Get-PathValueWithoutEntry -Raw "C:\A;$App;$Core\" -Dirs @($App, $Core) }
Test-Case '%VAR% の行・空の要素・末尾の ; は残す' '%USERPROFILE%\bin;;C:\B;' { Get-PathValueWithoutEntry -Raw "%USERPROFILE%\bin;;$App;C:\B;" -Dirs @($App) }
Test-Case '%VAR% で書いた置き場所の行も外す' 'C:\A' { $env:HERDR_APP_TEST_LOCALAPPDATA = 'C:\Users\u\AppData\Local'; Get-PathValueWithoutEntry -Raw 'C:\A;%HERDR_APP_TEST_LOCALAPPDATA%\Programs\herdr-app' -Dirs @($App) }
Test-Case '置き場所だけの PATH は空になる' '' { Get-PathValueWithoutEntry -Raw $App -Dirs @($App) }

# Get-HerdrAppVersionFromOutput
Test-Case '"herdr-app <版>" から版を拾う' '0.1.12' { Get-HerdrAppVersionFromOutput -Lines @('herdr-app 0.1.12') -Name 'herdr-app' }
Test-Case '"hc <版>" から版を拾う' '0.1.17' { Get-HerdrAppVersionFromOutput -Lines @('hc 0.1.17') -Name 'hc' }
Test-Case '行末の CR と前後の空白を落とす' '0.1.12' { Get-HerdrAppVersionFromOutput -Lines @("  herdr-app 0.1.12`r") -Name 'herdr-app' }
Test-Case '名前が違えば拾わない' '' { Get-HerdrAppVersionFromOutput -Lines @('hc 0.1.17') -Name 'herdr-app' }

# Get-HerdrAppInstallPaths / Get-HerdrAppWatchDirs / Test-HerdrAppProcessPath
Test-Case '外すのは置き場所と、自己更新が隣に作る 4 つ' "$App $App.old $App.new $App.new.json $App.download" { Get-HerdrAppInstallPaths -AppDir "$App\" }
Test-Case '動いているかを見るのは app の 4 つのディレクトリと core' "$App $App.old $App.new $App.download $Core" { Get-HerdrAppWatchDirs -AppDir $App -CoreDir "$Core\" }
$watch = @(Get-HerdrAppWatchDirs -AppDir $App -CoreDir $Core)
Test-Case '入れ替えた後の herdr-app.old から動いているものも数える' 'True' { Test-HerdrAppProcessPath -Path "$App.old\herdr-app.exe" -Dirs $watch }
Test-Case 'core の conpty の OpenConsole.exe も数える (大文字小文字を区別しない)' 'True' { Test-HerdrAppProcessPath -Path "$($Core.ToUpper())\conpty\x64\OpenConsole.exe" -Dirs $watch }
Test-Case '前方一致 (herdr-app2) は数えない' 'False' { Test-HerdrAppProcessPath -Path "$($App)2\x.exe" -Dirs $watch }

# Get-HerdrAppFileSha256
$abc = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-app-tests-abc-$PID"
[IO.File]::WriteAllText($abc, 'abc')
Test-Case 'abc の sha256' 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' { Get-HerdrAppFileSha256 -Path $abc }
Remove-Item -LiteralPath $abc -Force

# Get-HerdrAppLnkKind / Resolve-HerdrAppOnPath
Test-Case 'lnk が無ければ missing' 'missing' { Get-HerdrAppLnkKind -Exists $false -Target $null -Exe $AppExe }
Test-Case 'app を指していれば ours (大文字小文字を区別しない)' 'ours' { Get-HerdrAppLnkKind -Exists $true -Target $AppExe.ToUpper() -Exe $AppExe }
Test-Case '別の場所を指していれば other' 'other' { Get-HerdrAppLnkKind -Exists $true -Target 'C:\winget\herdr-app.exe' -Exe $AppExe }
$exists = { param($p) $p -in @('C:\B\herdr-core.exe', 'C:\A\herdr-core.exe') }
Test-Case '前から見て最初に見つかったもの' 'C:\A\herdr-core.exe' { Resolve-HerdrAppOnPath -PathValue 'C:\A;C:\B' -Name 'herdr-core.exe' -Exists $exists }
Test-Case 'どこにも無ければ空' '' { Resolve-HerdrAppOnPath -PathValue 'C:\Z' -Name 'herdr-core.exe' -Exists $exists }

# 状態の既定 (揃っている)。差し替えは hashtable を並べて渡す (後ろのものが勝つ)
function New-State {
    param([Parameter(ValueFromRemainingArguments)][hashtable[]]$Changes)
    $s = [ordered]@{
        AppExe = $true; AppVersion = '0.1.12'; AppSignature = $GoodSig; AppPathsPresent = @($App); LnkKind = 'ours'; LnkTarget = $AppExe
        AppPathListed = $true; CoreExe = $true; CoreDirExists = $true; CoreVersion = '0.1.17'; CoreSignature = $GoodSig; CorePathListed = $true
        CoreElsewhere = $null; FeedDirExists = $true; FeedDiff = @(); FeedUrl = $FeedUrl; EnvValue = $FeedUrl
    }
    foreach ($change in @($Changes)) {
        if ($null -eq $change) { continue }
        foreach ($k in $change.Keys) { $s[$k] = $change[$k] }
    }
    [pscustomobject]$s
}
$none = @{
    AppExe = $false; AppVersion = $null; AppSignature = $null; AppPathsPresent = @(); LnkKind = 'missing'; LnkTarget = $null; AppPathListed = $false
    CoreExe = $false; CoreDirExists = $false; CoreVersion = $null; CoreSignature = $null; CorePathListed = $false; CoreElsewhere = $null
    FeedDirExists = $false; FeedDiff = @('app\latest.json', 'core\latest.json', 'core\0.1.17\manifest.json'); EnvValue = $null
}
$winget = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Herdr.HerdrCore_x\herdr-core.exe'
$coreWinget = @{ CoreExe = $false; CoreDirExists = $false; CoreVersion = $null; CoreSignature = $null; CorePathListed = $false; CoreElsewhere = $winget }
$badSig = New-Sig @{ Status = 'HashMismatch' }

# Get-HerdrAppInstallPlan: 揃えるときにすること
function Get-Plan { param($State) $p = Get-HerdrAppInstallPlan -State $State -Pins $Pins; "$($p.App) $($p.Core) lnk=$($p.Lnk) path=$($p.AppPath)/$($p.CorePath) feed=$($p.Feed) env=$($p.Env)" }
Test-Case '揃っていれば何もしない' 'none none lnk=False path=False/False feed=False env=False' { Get-Plan (New-State) }
Test-Case '何も無ければ全部入れて、全部足す・書く' 'install install lnk=True path=True/False feed=True env=True' { Get-Plan (New-State $none) }
Test-Case 'app が固定より古ければ上げる' 'upgrade' { (Get-HerdrAppInstallPlan -State (New-State @{ AppVersion = '0.1.11' }) -Pins $Pins).App }
Test-Case 'app の版が読めなければ入れ直す' 'upgrade' { (Get-HerdrAppInstallPlan -State (New-State @{ AppVersion = $null }) -Pins $Pins).App }
Test-Case 'app が固定より新しければ下げない (newer)' 'newer' { (Get-HerdrAppInstallPlan -State (New-State @{ AppVersion = '0.1.14' }) -Pins $Pins).App }
Test-Case 'app の署名が合わなければ入れ直す (repair)' 'repair' { (Get-HerdrAppInstallPlan -State (New-State @{ AppSignature = $badSig }) -Pins $Pins).App }
Test-Case 'app の署名を確かめられないだけなら入れ直さない' 'none' { (Get-HerdrAppInstallPlan -State (New-State @{ AppSignature = $null }) -Pins $Pins).App }
Test-Case 'core が固定より古ければ上げる' 'upgrade' { (Get-HerdrAppInstallPlan -State (New-State @{ CoreVersion = '0.1.16' }) -Pins $Pins).Core }
Test-Case 'core が固定より新しければそのまま (固定した版以上でよい)' 'none' { (Get-HerdrAppInstallPlan -State (New-State @{ CoreVersion = '0.1.19' }) -Pins $Pins).Core }
Test-Case 'core の署名が合わなければ入れ直す' 'repair' { (Get-HerdrAppInstallPlan -State (New-State @{ CoreSignature = $badSig }) -Pins $Pins).Core }
Test-Case 'core が公式と違う置き場所にあれば触らない' 'elsewhere' { (Get-HerdrAppInstallPlan -State (New-State $coreWinget) -Pins $Pins).Core }
Test-Case 'フィードが固定と違えば書く' 'True' { (Get-HerdrAppInstallPlan -State (New-State @{ FeedDiff = @('app\latest.json') }) -Pins $Pins).Feed }
Test-Case '環境変数が別の値なら書く' 'True' { (Get-HerdrAppInstallPlan -State (New-State @{ EnvValue = 'https://releases.herdr.dev' }) -Pins $Pins).Env }

# Get-HerdrAppExitCode / Get-HerdrAppProblems
Test-Case '揃っていれば 0' 0 { Get-HerdrAppExitCode -State (New-State) -Pins $Pins }
Test-Case 'app が無ければ 3' 3 { Get-HerdrAppExitCode -State (New-State @{ AppExe = $false }) -Pins $Pins }
Test-Case 'app が固定より新しければ 1' 1 { Get-HerdrAppExitCode -State (New-State @{ AppVersion = '0.1.14' }) -Pins $Pins }
Test-Case 'フィードが違えば 1' 1 { Get-HerdrAppExitCode -State (New-State @{ FeedDiff = @('core\latest.json') }) -Pins $Pins }
Test-Case '環境変数が無ければ 1' 1 { Get-HerdrAppExitCode -State (New-State @{ EnvValue = $null }) -Pins $Pins }
Test-Case '署名を確かめられなければ 1' 1 { Get-HerdrAppExitCode -State (New-State @{ AppSignature = $null }) -Pins $Pins }
Test-Case 'core が固定より新しいのは 0' 0 { Get-HerdrAppExitCode -State (New-State @{ CoreVersion = '0.1.19' }) -Pins $Pins }
Test-Case 'core が公式と違う置き場所にあるのは 0' 0 { Get-HerdrAppExitCode -State (New-State $coreWinget) -Pins $Pins }
Test-Case '揃っていないものの名前' 'app-version lnk app-path core feed env' { Get-HerdrAppProblems -State (New-State @{ AppVersion = '0.1.14'; LnkKind = 'missing'; AppPathListed = $false; CoreExe = $false; CorePathListed = $false; FeedDiff = @('x'); EnvValue = $null }) -Pins $Pins }
Test-Case '署名の合わない app と core は signature の名前' 'app-signature core-signature' { Get-HerdrAppProblems -State (New-State @{ AppSignature = $badSig; CoreSignature = $null }) -Pins $Pins }

# Format-HerdrAppState: 状態の表の行
function Get-Rows { param($State) @(Format-HerdrAppState -State $State -Pins $Pins -AppDir $App -CoreDir $Core -FeedDir $Feed) }
$full = @(
    'herdr-app (公式と同じ置き場所。版は dotfiles が決める: 0.1.12)'
    "  置き場所         : $App"
    '  入っている版     : 0.1.12 (固定した版)'
    '  署名             : Valid (CN=herdr, O=herdr。発行元 Microsoft ID Verified CS AOC CA 04)'
    '  スタートメニュー : Herdr.lnk'
    '  ユーザーの PATH  : あり'
    'herdr-core (無ければ入れる。版は dotfiles が決めた 0.1.17 以上)'
    "  置き場所         : $Core"
    '  入っている版     : 0.1.17 (固定した版 0.1.17 以上)'
    '  署名             : Valid (CN=herdr, O=herdr。発行元 Microsoft ID Verified CS AOC CA 04)'
    '  ユーザーの PATH  : あり'
    '更新の取得元 (HERDR_RELEASES_URL。app と core は、ここに載った版にだけ上がる)'
    "  フィード         : $Feed (app 0.1.12・core 0.1.17)"
    "  環境変数         : $FeedUrl"
)
Test-Case '揃っていれば表の 14 行だけで、⚠ は無い' ($full -join '|') { @((Get-Rows (New-State)) | ForEach-Object { $_.Text }) -join '|' }
Test-Case '揃っていれば Warn の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '固定より古い app は上げると出す' '⚠ 入っている版     : 0.1.11 → 0.1.12 に上げる' { (Get-Rows (New-State @{ AppVersion = '0.1.11' }))[2].Text }
Test-Case '版が読めない app は入れ直すと出す' '⚠ 入っている版     : 不明 (herdr-app.exe --version が読めない) → 0.1.12 に上げる' { (Get-Rows (New-State @{ AppVersion = $null }))[2].Text }
Test-Case '固定より新しい app は下げないと出す' '⚠ 入っている版     : 0.1.14 (固定した版 0.1.12 より新しい。下げはしない)' { (Get-Rows (New-State @{ AppVersion = '0.1.14' }))[2].Text }
Test-Case '固定より新しい app には ※ でわけと直し方を添える' $true { (Get-Rows (New-State @{ AppVersion = '0.1.14' }))[-1].Text -like '※ 入っている app は固定した版より新しい*Install-HerdrApp -Uninstall の後に入れ直す' }
Test-Case '署名が合わない app は ⚠ で入れ直すと出す' '⚠ 署名             : 署名が Valid でない (HashMismatch) → 0.1.12 を入れ直す' { (Get-Rows (New-State @{ AppSignature = $badSig }))[3].Text }
Test-Case '署名を確かめられなければ ⚠' '⚠ 署名             : 署名を確かめられない (Get-AuthenticodeSignature が使えない)' { (Get-Rows (New-State @{ AppSignature = $null }))[3].Text }
Test-Case '固定より古い core は上げると出す' '⚠ 入っている版     : 0.1.16 → 0.1.17 に上げる' { (Get-Rows (New-State @{ CoreVersion = '0.1.16' }))[8].Text }
Test-Case 'フィードが違えば、違うファイルを出して ⚠' "⚠ フィード         : $Feed (無い・固定と違う: app\latest.json・core\latest.json) → 書く" { (Get-Rows (New-State @{ FeedDiff = @('app\latest.json', 'core\latest.json') }))[12].Text }
Test-Case '環境変数が無ければ、公式から上がると出して ⚠' "⚠ 環境変数         : 無し (公式の releases.herdr.dev から上がる) → $FeedUrl にする" { (Get-Rows (New-State @{ EnvValue = $null }))[13].Text }
Test-Case '環境変数が別の値なら ⚠' "⚠ 環境変数         : https://example.test (フィードを指していない) → $FeedUrl にする" { (Get-Rows (New-State @{ EnvValue = 'https://example.test' }))[13].Text }
Test-Case 'app が無いときは、置き場所の行のほかは ⚠ にしない (入れるときに作る)' 2 { @((Get-Rows (New-State $none)) | Where-Object { $_.Warn }).Count }
Test-Case 'app が無ければ、入れる版を出す' "⚠ 置き場所         : $App → 入っていない (0.1.12 を入れる)" { (Get-Rows (New-State $none))[1].Text }
Test-Case 'core が無ければ、入れる版を出す' "⚠ 置き場所         : $Core → 入っていない (0.1.17 を入れる)" { (Get-Rows (New-State $none))[5].Text }
Test-Case 'core が公式と違う置き場所にあれば ⚠ にせず ※ を添える' '※ herdr-core は公式と違う置き場所にある (winget など)。dotfiles は入れず、-Uninstall も触らない' { (Get-Rows (New-State $coreWinget))[-1].Text }

# Get-HerdrAppUninstallPlan / Format-HerdrAppKept: -Uninstall で外すもの・残すもの
function Get-UPlan { param($State) @(Get-HerdrAppUninstallPlan -State $State -AppDir $App -CoreDir $Core -Menu $Menu -FeedDir $Feed | ForEach-Object { "$($_.Kind):$($_.Target)" }) -join '|' }
Test-Case '全部あれば、app と隣のもの・lnk・PATH の 2 行・core・フィード・環境変数を外す' "remove:$App|remove:$App.new|remove:$Menu|path:$App|remove:$Core|path:$Core|remove:$Feed|env:HERDR_RELEASES_URL" { Get-UPlan (New-State @{ AppPathsPresent = @($App, "$App.new") }) }
Test-Case '環境変数がフィードを指していなければ触らない' "remove:$App|remove:$Menu|path:$App|remove:$Core|path:$Core|remove:$Feed" { Get-UPlan (New-State @{ EnvValue = 'https://example.test' }) }
Test-Case 'Herdr.lnk が別の場所を指していれば外さない・core が公式と違う置き場所なら触らない' "remove:$App|path:$App|remove:$Feed|env:HERDR_RELEASES_URL" { Get-UPlan (New-State $coreWinget @{ LnkKind = 'other'; LnkTarget = 'C:\x\y.exe' }) }
Test-Case '何も無ければ外すものは無い' '' { Get-UPlan (New-State $none) }
$loc = [pscustomobject]@{
    AppDir = $App; CoreDir = $Core; Menu = $Menu; FeedDir = $Feed
    AppHome = 'C:\Users\u\.config\herdr-app'; CoreState = 'C:\Users\u\AppData\Local\herdr-core'; CoreConfig = 'C:\Users\u\AppData\Roaming\herdr-core'
}
Test-Case '設定と core の状態・設定があれば、残したと出す' "残した: $($loc.AppHome) (設定と mod)|残した: $($loc.CoreState) (herdr-core の状態)|残した: $($loc.CoreConfig) (herdr-core の設定)" {
    @(Format-HerdrAppKept -State (New-State) -Locations $loc -Exists { param($p) $true }) -join '|'
}
Test-Case 'フィードを指していない環境変数は残したと出す' '残した: ユーザーの環境変数 HERDR_RELEASES_URL = https://example.test (dotfiles のフィードを指していない)' {
    @(Format-HerdrAppKept -State (New-State @{ EnvValue = 'https://example.test' }) -Locations $loc -Exists { param($p) $false }) -join '|'
}

# Format-HerdrAppBusy / Test-HerdrAppBusyEntry: 動いているプロセスと止め方
$appProc = [pscustomobject]@{ Id = 1001; Name = 'herdr-app.exe'; Path = $AppExe; CommandLine = "`"$AppExe`"" }
$coreProc = [pscustomobject]@{ Id = 1002; Name = 'herdr-core.exe'; Path = "$Core\herdr-core.exe"; CommandLine = 'herdr-core.exe serve' }
$hiddenCore = [pscustomobject]@{ Id = 1003; Name = 'herdr-core.exe'; Path = $null; CommandLine = $null }
Test-Case 'app と core が動いていれば、両方の止め方と PID を出す' @(
    'herdr-app か herdr-core が動いている (2 個) ので、何も外していない。止めてから打ち直す:'
    '  app: 窓を閉じる'
    "  core: & '$Core\herdr-core.exe' server stop を打つ (core の中の terminal と、そこで動いているものも終わる)"
    "  1001  $AppExe  `"$AppExe`""
    "  1002  $Core\herdr-core.exe  herdr-core.exe serve"
) { Format-HerdrAppBusy -Processes @($appProc, $coreProc) -CoreDir $Core }
Test-Case 'パスが読めない herdr-core.exe は core として止め方を出し、読めないと添える' @(
    'herdr-app か herdr-core が動いている (1 個) ので、何も外していない。止めてから打ち直す:'
    "  core: & '$Core\herdr-core.exe' server stop を打つ (core の中の terminal と、そこで動いているものも終わる)"
    '  1003  herdr-core.exe (パスが読めないので名前で数えた。管理者で動いているなど)  '
) { Format-HerdrAppBusy -Processes @($hiddenCore) -CoreDir $Core }
Test-Case 'パスが置き場所の下なら数える' 'True' { Test-HerdrAppBusyEntry -Path "$Core\conpty\x64\OpenConsole.exe" -Name 'OpenConsole.exe' -Dirs $watch }
Test-Case 'パスがほかの場所なら、名前が herdr-core.exe でも数えない (winget など)' 'False' { Test-HerdrAppBusyEntry -Path $winget -Name 'herdr-core.exe' -Dirs $watch }
Test-Case 'パスが読めない HERDR-APP.EXE も数える (大文字小文字を区別しない)' 'True' { Test-HerdrAppBusyEntry -Path '' -Name 'HERDR-APP.EXE' -Dirs $watch }
Test-Case 'パスが読めない OpenConsole.exe は数えない (Windows Terminal も持つ)' 'False' { Test-HerdrAppBusyEntry -Path $null -Name 'OpenConsole.exe' -Dirs $watch }

# Get-HerdrAppExeVersion: 実行ファイルに --version を打って版を読む。壊れた・終わらないものでも止まらない
$tmpBin = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-app-tests-bin-$PID"
New-Item -ItemType Directory -Force $tmpBin | Out-Null
$okExe = Join-Path $tmpBin 'ok'
$hangExe = Join-Path $tmpBin 'hang'
$brokenExe = Join-Path $tmpBin 'broken'
Set-Content -LiteralPath $okExe -Value "#!/bin/sh`necho 'herdr-app 0.1.12'"
Set-Content -LiteralPath $hangExe -Value "#!/bin/sh`nsleep 30"
Set-Content -LiteralPath $brokenExe -Value '' -NoNewline
if (-not $IsWindows) { chmod +x $okExe $hangExe $brokenExe }
Test-Case '--version の出力から版を読む' '0.1.12' { Get-HerdrAppExeVersion -Exe $okExe -Name 'herdr-app' }
Test-Case '終わらなければ打ち切って空 (窓を開く版の app にあたっても止まらない)' '' { Get-HerdrAppExeVersion -Exe $hangExe -Name 'herdr-app' -TimeoutMs 500 }
Test-Case '起動できない (壊れた・0 バイト) なら空' '' { Get-HerdrAppExeVersion -Exe $brokenExe -Name 'herdr-app' }
Test-Case '無ければ空' '' { Get-HerdrAppExeVersion -Exe (Join-Path $tmpBin 'missing') -Name 'herdr-app' }
Remove-Item -LiteralPath $tmpBin -Recurse -Force

# Remove-HerdrAppItem / Remove-HerdrAppTree: 中身ごと消すが、リンクの先はたどらない (Remove-Item -Recurse がたどるかは
# PowerShell の版で違う)。Linux の .NET でも symlink は ReparsePoint として見えるので、ここで確かめられる
$tree = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-app-tests-tree-$PID"
$outside = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-app-tests-outside-$PID"
New-Item -ItemType Directory -Force (Join-Path $tree 'conpty/x64'), $outside | Out-Null
Set-Content -LiteralPath (Join-Path $tree 'conpty/x64/OpenConsole.exe') -Value 'x'
Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'keep'
$readonly = Join-Path $tree 'readonly.txt'
Set-Content -LiteralPath $readonly -Value 'r'
(Get-Item -LiteralPath $readonly).Attributes = 'ReadOnly'
New-Item -ItemType SymbolicLink -Path (Join-Path $tree 'dirlink') -Target $outside | Out-Null
New-Item -ItemType SymbolicLink -Path (Join-Path $tree 'filelink') -Target (Join-Path $outside 'keep.txt') | Out-Null
Test-Case '中身 (読み取り専用のファイルも) ごと消せば True' 'True' { Remove-HerdrAppItem -Path $tree }
Test-Case '消したディレクトリは残らない' 'False' { Test-Path -LiteralPath $tree }
Test-Case 'リンクの先 (置き場所の外) は消さない' 'True' { Test-Path -LiteralPath (Join-Path $outside 'keep.txt') }
Test-Case '無いものは消せずに False (理由を出す)' 'False' { Remove-HerdrAppItem -Path $tree 6>$null }
Remove-Item -LiteralPath $outside -Recurse -Force

# 本体の入口: Linux の pwsh には $env:LOCALAPPDATA が無く、本体の最初で例外になる。
# それでも終了コード 2 で止まり、成功 (0) に見せない
$pwsh = (Get-Process -Id $PID).Path
$entry = Join-Path $PSScriptRoot 'Install-HerdrApp.ps1'
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' { $null = & $pwsh -NoProfile -File $entry -Check 2>&1; $LASTEXITCODE }
Test-Case '-Uninstall と -Check を一緒に打つと終了コード 2' '2' { $null = & $pwsh -NoProfile -File $entry -Uninstall -Check 2>&1; $LASTEXITCODE }
Test-Case '固定した版の書き方が誤っていれば終了コード 2 (状態も読まない)' '2' { $null = & $pwsh -NoProfile -File $entry -Check -AppVersion 'latest' 2>&1; $LASTEXITCODE }

# ---------------------------------------------------------------------------
# Invoke-InstallHerdrApp の流れ。Windows に触る関数を偽物に差し替えて、すること (書く・入れる・作る・足す・外す) の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
function Get-Leaf { param([string]$Path) $Path.Substring($Path.LastIndexOf('\') + 1) }
function Get-DirName { param([string]$Dir) if ($Dir -eq $App) { 'app' } elseif ($Dir -eq $Core) { 'core' } else { $Dir } }

function Get-HerdrAppLocations { $loc }
function Get-HerdrAppState { param($Locations, $Pins, $Releases) $script:States.Dequeue() }
function Get-HerdrAppDownloadBlocker { param($Tar) $script:Blocker }
function Install-HerdrAppPackage {
    param($Pins, $AppDir, $Releases, $Tar)
    $script:Calls.Add('app')
    if ($script:Fail.ContainsKey('app')) { throw '落とした herdr-app.exe の署名が Valid でない (NotSigned)。入れない' }
}
function Install-HerdrCorePackage {
    param($Pins, $CoreDir, $Releases, $Tar)
    $script:Calls.Add('core')
    if ($script:Fail.ContainsKey('core')) { throw 'sha256 が違う' }
}
function Sync-HerdrAppFeed { param($FeedDir, $Pins, $Releases) $script:Calls.Add('feed') }
function Set-HerdrAppEnvValue { param($Value) $script:Calls.Add('env') }
function Remove-HerdrAppEnvValue { $script:Calls.Add('env-') }
function Remove-HerdrAppEmptyParent { param($Dir) $script:Calls.Add('rm-parent') }
function New-HerdrAppShortcut { param($Path, $Exe) $script:Calls.Add('lnk') }
function Add-HerdrAppUserPath { param($Dir, $Flag) $script:Calls.Add("path+$(Get-DirName $Dir)") }
function Remove-HerdrAppUserPath { param($Dirs) $script:Calls.Add('path-' + (@($Dirs | ForEach-Object { Get-DirName $_ }) -join ',')) }
function Remove-HerdrAppItem {
    param($Path)
    $leaf = Get-Leaf $Path
    $script:Calls.Add("rm:$leaf")
    -not $script:Fail.ContainsKey("rm:$leaf")
}
function Get-HerdrAppBusyProcess { param($Dirs) @($script:Busy) }

# 1 回ぶんの流れを走らせ、したこと・画面の行・終了コードを返す。
# $States は Get-HerdrAppState が返す順 (前と、した後に読み直したもの)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [switch]$Uninstall, [hashtable]$Fail = @{}, [object[]]$Busy = @(), [string]$Blocker = $null, $UsePins = $Pins)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:Busy = $Busy
    $script:Blocker = $Blocker
    $out = @(Invoke-InstallHerdrApp -Check:$Check -IfMissing:$IfMissing -Uninstall:$Uninstall -Pins $UsePins 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
        Ints  = @($out | Where-Object { $_ -is [int] }).Count
    }
}

$installed = New-State
$missing = New-State $none
Test-Case '-Check は何もしない (揃っていれば 0)' '0 []' { $r = Invoke-Flow -States @($installed) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は何もしない (入っていなければ 3)' '3 []' { $r = Invoke-Flow -States @($missing) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check は何もしない (フィードが違っても 1 で返すだけ)' '1 []' { $r = Invoke-Flow -States @((New-State @{ FeedDiff = @('app\latest.json') })) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '揃っていれば何もしない' '0 []' { $r = Invoke-Flow -States @($installed); "$($r.Code) [$($r.Calls)]" }
Test-Case '何も無ければ、フィードと環境変数を先に書いてから、app と core を入れて lnk と PATH の 2 行を足す' '0 [feed env app lnk path+app core path+core]' { $r = Invoke-Flow -States @($missing, $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing も同じことをする (付けなくても同じ)' '0 [feed env app lnk path+app core path+core]' { $r = Invoke-Flow -States @($missing, $installed) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '流れが返す値は終了コード 1 つだけ (exit に配列を渡さない)' 1 { (Invoke-Flow -States @($missing, $installed)).Ints }
Test-Case 'フィードだけ違えば、フィードだけを書く' '0 [feed]' { $r = Invoke-Flow -States @((New-State @{ FeedDiff = @('app\latest.json') }), $installed) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '環境変数だけ違えば、環境変数だけを書く' '0 [env]' { $r = Invoke-Flow -States @((New-State @{ EnvValue = $null }), $installed) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case 'app が固定より古ければ、固定した版を入れて上げる' '0 [app]' { $r = Invoke-Flow -States @((New-State @{ AppVersion = '0.1.11' }), $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case 'app が固定より新しければ下げず、⚠ のまま 1' '1 []' { $s = New-State @{ AppVersion = '0.1.14' }; $r = Invoke-Flow -States @($s, $s); "$($r.Code) [$($r.Calls)]" }
Test-Case '署名が合わない app は、固定した版を入れ直す' '0 [app]' { $r = Invoke-Flow -States @((New-State @{ AppSignature = $badSig }), $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case 'core が固定より古ければ、固定した版に上げる' '0 [core path+core]' { $r = Invoke-Flow -States @((New-State @{ CoreVersion = '0.1.16' }), $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case 'core が公式と違う置き場所にあれば、core は入れない' '0 [feed env app lnk path+app]' { $r = Invoke-Flow -States @((New-State $none $coreWinget), (New-State $coreWinget)); "$($r.Code) [$($r.Calls)]" }
Test-Case 'app を入れられなければ (署名が合わないなど)、lnk も PATH も core も触らずに 1' '1 [feed env app]' { $r = Invoke-Flow -States @($missing) -Fail @{ app = 1 }; "$($r.Code) [$($r.Calls)]" }
Test-Case 'app を入れられなければ、わけと打ち直し方を出す' $true { $r = Invoke-Flow -States @($missing) -Fail @{ app = 1 }; ($r.Text -like '*herdr-app を入れられなかった: 落とした herdr-app.exe の署名が Valid でない*') -and ($r.Text -like '*Install-HerdrApp を打ち直す*') }
Test-Case 'core を入れられなければ、app は入れたまま 1' '1 [feed env app lnk path+app core]' { $r = Invoke-Flow -States @($missing, (New-State @{ CoreExe = $false; CoreDirExists = $false; CorePathListed = $false })) -Fail @{ core = 1 }; "$($r.Code) [$($r.Calls)]" }
Test-Case '落として入れられない PC (x64 でない) なら、フィードと環境変数だけ書いて 1' '1 [feed env]' { $r = Invoke-Flow -States @($missing) -Blocker 'x64 だけ'; "$($r.Code) [$($r.Calls)]" }
Test-Case 'lnk を足すだけなら、落とせるかは見ない' '0 [lnk]' { $r = Invoke-Flow -States @((New-State @{ LnkKind = 'missing' }), $installed) -Blocker 'x64 だけ'; "$($r.Code) [$($r.Calls)]" }
Test-Case '固定した版の書き方が誤っていれば、状態も読まずに 2' '2 []' { $r = Invoke-Flow -States @() -UsePins ([pscustomobject]@{ AppVersion = 'latest'; AppSha256 = $ShaA; CoreVersion = '0.1.17'; CoreSha256 = $ShaC; CoreGeneration = 1 }); "$($r.Code) [$($r.Calls)]" }

$busy = @($appProc, $coreProc)
$full3 = New-State @{ AppPathsPresent = @($App, "$App.old") }
Test-Case '-Uninstall は動いていれば何も外さずに 1' '1 []' { $r = Invoke-Flow -States @($full3) -Uninstall -Busy $busy; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Uninstall は動いていれば止め方と PID を出す' $true { $r = Invoke-Flow -States @($full3) -Uninstall -Busy $busy; ($r.Text -like '*server stop*') -and ($r.Text -like '*1002*herdr-core.exe serve*') }
Test-Case '-Uninstall は止まっていれば、app と隣のもの・lnk・core・フィード・環境変数・PATH の 2 行を外して 0' '0 [rm:herdr-app rm:herdr-app.old rm:Herdr.lnk rm:herdr-core rm:herdr-releases rm-parent env- path-app,core]' { $r = Invoke-Flow -States @($full3, $missing) -Uninstall; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Uninstall は外したものと、setup が入れ直すことを出す' $true { $r = Invoke-Flow -States @($full3, $missing) -Uninstall; ($r.Text -like "*外した: $Feed*") -and ($r.Text -like '*外した: ユーザーの環境変数 HERDR_RELEASES_URL*') -and ($r.Text -like '*次の setup --update が入れ直す*') }
Test-Case '-Uninstall はフィードを指していない環境変数に触らない' '0 [rm:herdr-app rm:Herdr.lnk rm:herdr-core rm:herdr-releases rm-parent path-app,core]' { $s = New-State @{ EnvValue = 'https://example.test' }; $r = Invoke-Flow -States @($s, (New-State $none @{ EnvValue = 'https://example.test' })) -Uninstall; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Uninstall は何も無ければ何もせずに 0 (動いているかも見ない)' '0 []' { $r = Invoke-Flow -States @($missing) -Uninstall -Busy $busy; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Uninstall で外せないものがあれば 1 で、外せなかったものを出す' $true { $r = Invoke-Flow -States @($full3, (New-State $none @{ CoreDirExists = $true })) -Uninstall -Fail @{ 'rm:herdr-core' = 1 }; ($r.Code -eq 1) -and ($r.Text -like "*外せなかった: $Core*") }
Test-Case '-Uninstall の流れが返す値も終了コード 1 つだけ' 1 { (Invoke-Flow -States @($full3, $missing) -Uninstall).Ints }
Test-Case '-Uninstall と -IfMissing を一緒に打つと、状態も読まずに 2' '2 []' { $r = Invoke-Flow -States @() -Uninstall -IfMissing; "$($r.Code) [$($r.Calls)]" }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
