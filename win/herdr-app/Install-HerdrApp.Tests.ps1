# win/herdr-app/Install-HerdrApp.ps1 のうち、副作用の無い関数と、Windows に触る関数を偽物に替えた流れのテスト。
# Pester は使わない (Install-Herdr.Tests.ps1 と同じ作り)。ダウンロード・レジストリ・ショートカット・プロセスに触る部分は、
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
$AppExe = "$App\herdr-app.exe"

# Get-HerdrAppArchitecture: 32 bit の PowerShell から呼ばれても OS の arch を見る
Test-Case '64 bit の PowerShell なら PROCESSOR_ARCHITECTURE' 'AMD64' { Get-HerdrAppArchitecture -Architecture 'AMD64' -Architecture6432 '' }
Test-Case '32 bit の PowerShell からは PROCESSOR_ARCHITEW6432 を見る' 'AMD64' { Get-HerdrAppArchitecture -Architecture 'x86' -Architecture6432 'AMD64' }
Test-Case 'ARM64 は ARM64 のまま' 'ARM64' { Get-HerdrAppArchitecture -Architecture 'ARM64' -Architecture6432 $null }

# Get-HerdrAppRelease: 2026-11-09 の app/latest.json (targets を 2 つに減らしたもの)
$latest = @'
{
  "version": "0.1.14",
  "core_min": "0.1.11",
  "notes": "Herdr 0.1.14",
  "targets": {
    "linux-x86_64": {
      "url": "https://releases.herdr.dev/app/0.1.14/herdr-app-linux-x86_64.tar.gz",
      "sha256": "475a383f8f439e3191a86635b5c1286ce4dfd2d9fcdf1e7cbdfdd6c7176f8ff3"
    },
    "windows-x86_64": {
      "url": "https://releases.herdr.dev/app/0.1.14/herdr-app-windows-x86_64.tar.gz",
      "sha256": "c8a9da0e1b7c8ec85e2e131006797ba0fe0fc7793f3ab80e482f7622a5516b01"
    }
  }
}
'@ | ConvertFrom-Json
Test-Case 'windows-x86_64 の版・URL・sha256 を拾う' '0.1.14 https://releases.herdr.dev/app/0.1.14/herdr-app-windows-x86_64.tar.gz c8a9da0e1b7c8ec85e2e131006797ba0fe0fc7793f3ab80e482f7622a5516b01' {
    $r = Get-HerdrAppRelease -Manifest $latest -Target 'windows-x86_64'
    "$($r.Version) $($r.Url) $($r.Sha256)"
}
Test-Case 'target が無ければ空' '' { Get-HerdrAppRelease -Manifest $latest -Target 'windows-aarch64' }
Test-Case 'sha256 が無ければ空' '' { Get-HerdrAppRelease -Manifest ('{"version":"1","targets":{"windows-x86_64":{"url":"https://x"}}}' | ConvertFrom-Json) -Target 'windows-x86_64' }
Test-Case 'targets が無ければ空' '' { Get-HerdrAppRelease -Manifest ('{"version":"1"}' | ConvertFrom-Json) -Target 'windows-x86_64' }

# Get-HerdrAppDownloadUrl: releases の素の URL にだけ ?src= を付ける (公式と同じ)
Test-Case 'releases の素の URL には ?src= を付ける' "$R/app/0.1.14/a.tar.gz?src=install" { Get-HerdrAppDownloadUrl -Url "$R/app/0.1.14/a.tar.gz" -Releases $R -Src 'install' }
Test-Case '? を含む URL (mirror の署名付き) はそのまま' "$R/app/a.tar.gz?sig=1" { Get-HerdrAppDownloadUrl -Url "$R/app/a.tar.gz?sig=1" -Releases $R -Src 'install' }
Test-Case '# を含む URL もそのまま' "$R/app/a.tar.gz#x" { Get-HerdrAppDownloadUrl -Url "$R/app/a.tar.gz#x" -Releases $R -Src 'install' }
Test-Case 'ほかのホストの URL はそのまま' 'https://mirror.example/app/a.tar.gz' { Get-HerdrAppDownloadUrl -Url 'https://mirror.example/app/a.tar.gz' -Releases $R -Src 'install' }
Test-Case 'releases の前方一致 (releases.herdr.dev.example) には付けない' 'https://releases.herdr.dev.example/a' { Get-HerdrAppDownloadUrl -Url 'https://releases.herdr.dev.example/a' -Releases $R -Src 'install' }

# Test-HerdrAppPathEntry / Test-HerdrAppPathListed: PATH の要素が置き場所を指すか
Test-Case '同じ置き場所なら合う' 'True' { Test-HerdrAppPathEntry -Entry $App -Dir $App }
Test-Case '末尾の \・前後の空白・引用符・大文字小文字の違いは合う' 'True' { Test-HerdrAppPathEntry -Entry " `"$($App.ToUpper())\`" " -Dir $App }
Test-Case '%VAR% を展開してから比べる' 'True' { $env:HERDR_APP_TEST_LOCALAPPDATA = 'C:\Users\u\AppData\Local'; Test-HerdrAppPathEntry -Entry '%HERDR_APP_TEST_LOCALAPPDATA%\Programs\herdr-app' -Dir $App }
Test-Case '前方一致 (herdr-app2) は合わない' 'False' { Test-HerdrAppPathEntry -Entry "$($App)2" -Dir $App }
Test-Case '空の要素は合わない' 'False' { Test-HerdrAppPathEntry -Entry '' -Dir $App }
Test-Case 'どこかの要素が合えば listed' 'True' { Test-HerdrAppPathListed -Raw "C:\A;;$App\;C:\B" -Dir $App }
Test-Case 'どの要素も合わなければ listed でない' 'False' { Test-HerdrAppPathListed -Raw 'C:\A;C:\B' -Dir $App }
Test-Case '空の PATH は listed でない' 'False' { Test-HerdrAppPathListed -Raw '' -Dir $App }

# Get-PathValueWithEntry: 末尾に足す (公式と同じ形)。既にあれば変えない
Test-Case '空の PATH なら置き場所だけ' $App { Get-PathValueWithEntry -Raw '' -Dir $App }
Test-Case '末尾の ; を落としてから足す' "C:\A;$App" { Get-PathValueWithEntry -Raw 'C:\A;' -Dir $App }
Test-Case '%VAR% の書き方はそのまま残して足す' "%USERPROFILE%\bin;C:\A;$App" { Get-PathValueWithEntry -Raw '%USERPROFILE%\bin;C:\A' -Dir $App }
Test-Case '既にあれば変えない (書き違いでも)' "C:\A;$($App.ToUpper())\" { Get-PathValueWithEntry -Raw "C:\A;$($App.ToUpper())\" -Dir $App }

# Get-PathValueWithoutEntry: 置き場所を指す要素だけを外し、ほかはそのまま残す
Test-Case '置き場所の要素だけを外す' 'C:\A;C:\B' { Get-PathValueWithoutEntry -Raw "C:\A;$App;C:\B" -Dirs @($App) }
Test-Case '2 つの置き場所をまとめて外す' 'C:\A' { Get-PathValueWithoutEntry -Raw "C:\A;$App;$Core\" -Dirs @($App, $Core) }
Test-Case '%VAR% の行・空の要素・末尾の ; は残す' '%USERPROFILE%\bin;;C:\B;' { Get-PathValueWithoutEntry -Raw "%USERPROFILE%\bin;;$App;C:\B;" -Dirs @($App) }
Test-Case '%VAR% で書いた置き場所の行も外す' 'C:\A' { $env:HERDR_APP_TEST_LOCALAPPDATA = 'C:\Users\u\AppData\Local'; Get-PathValueWithoutEntry -Raw 'C:\A;%HERDR_APP_TEST_LOCALAPPDATA%\Programs\herdr-app' -Dirs @($App) }
Test-Case '置き場所だけの PATH は空になる' '' { Get-PathValueWithoutEntry -Raw $App -Dirs @($App) }
Test-Case '無ければ変えない' 'C:\A;C:\B' { Get-PathValueWithoutEntry -Raw 'C:\A;C:\B' -Dirs @($App, $Core) }

# Get-HerdrAppVersionFromOutput: <名前> --version の出力から版を拾う
Test-Case '"herdr-app <版>" から版を拾う' '0.1.14' { Get-HerdrAppVersionFromOutput -Lines @('herdr-app 0.1.14') -Name 'herdr-app' }
Test-Case '"hc <版>" から版を拾う' '0.1.19' { Get-HerdrAppVersionFromOutput -Lines @('hc 0.1.19') -Name 'hc' }
Test-Case '行末の CR と前後の空白を落とす' '0.1.14' { Get-HerdrAppVersionFromOutput -Lines @("  herdr-app 0.1.14`r") -Name 'herdr-app' }
Test-Case 'ほかの行が先にあっても拾う' '0.1.19' { Get-HerdrAppVersionFromOutput -Lines @('warning: x', 'hc 0.1.19') -Name 'hc' }
Test-Case '名前が違えば拾わない' '' { Get-HerdrAppVersionFromOutput -Lines @('hc 0.1.19') -Name 'herdr-app' }

# Get-HerdrAppInstallPaths / Get-HerdrAppWatchDirs / Test-HerdrAppProcessPath
Test-Case '外すのは置き場所と、自己更新が隣に作る 4 つ' "$App $App.old $App.new $App.new.json $App.download" { Get-HerdrAppInstallPaths -AppDir "$App\" }
Test-Case '動いているかを見るのは app の 4 つのディレクトリと core' "$App $App.old $App.new $App.download $Core" { Get-HerdrAppWatchDirs -AppDir $App -CoreDir "$Core\" }
$watch = @(Get-HerdrAppWatchDirs -AppDir $App -CoreDir $Core)
Test-Case '置き場所の herdr-app.exe は動いているものに数える' 'True' { Test-HerdrAppProcessPath -Path $AppExe -Dirs $watch }
Test-Case '入れ替えた後の herdr-app.old から動いているものも数える' 'True' { Test-HerdrAppProcessPath -Path "$App.old\herdr-app.exe" -Dirs $watch }
Test-Case 'core の conpty の OpenConsole.exe も数える (大文字小文字を区別しない)' 'True' { Test-HerdrAppProcessPath -Path "$($Core.ToUpper())\conpty\x64\OpenConsole.exe" -Dirs $watch }
Test-Case '前方一致 (herdr-app2) は数えない' 'False' { Test-HerdrAppProcessPath -Path "$($App)2\x.exe" -Dirs $watch }
Test-Case 'パスが読めないプロセスは数えない' 'False' { Test-HerdrAppProcessPath -Path $null -Dirs $watch }

# Get-HerdrAppFileSha256: .NET で求めた小文字の hex
$abc = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-app-tests-abc-$PID"
[IO.File]::WriteAllText($abc, 'abc')
Test-Case 'abc の sha256' 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' { Get-HerdrAppFileSha256 -Path $abc }
Remove-Item -LiteralPath $abc -Force

# Get-HerdrAppLnkKind: Herdr.lnk が app を指すか
Test-Case 'lnk が無ければ missing' 'missing' { Get-HerdrAppLnkKind -Exists $false -Target $null -Exe $AppExe }
Test-Case 'app を指していれば ours (大文字小文字を区別しない)' 'ours' { Get-HerdrAppLnkKind -Exists $true -Target $AppExe.ToUpper() -Exe $AppExe }
Test-Case '別の場所を指していれば other' 'other' { Get-HerdrAppLnkKind -Exists $true -Target 'C:\winget\herdr-app.exe' -Exe $AppExe }
Test-Case 'TargetPath が読めなければ other' 'other' { Get-HerdrAppLnkKind -Exists $true -Target '' -Exe $AppExe }

# Resolve-HerdrAppOnPath: PATH を前から見て、最初に見つかった herdr-core.exe
$exists = { param($p) $p -in @('C:\B\herdr-core.exe', 'C:\A\herdr-core.exe') }
Test-Case '前から見て最初に見つかったもの' 'C:\A\herdr-core.exe' { Resolve-HerdrAppOnPath -PathValue 'C:\A;C:\B' -Name 'herdr-core.exe' -Exists $exists }
Test-Case '末尾の \・引用符・空の要素を飛ばす' 'C:\B\herdr-core.exe' { Resolve-HerdrAppOnPath -PathValue ';; "C:\Z\" ; C:\B\ ;' -Name 'herdr-core.exe' -Exists $exists }
Test-Case 'どこにも無ければ空' '' { Resolve-HerdrAppOnPath -PathValue 'C:\Z' -Name 'herdr-core.exe' -Exists $exists }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
# 差し替えは hashtable を並べて渡す (後ろのものが勝つ)。New-State $none @{ LnkKind = 'ours' } のように重ねられる
function New-State {
    param([Parameter(ValueFromRemainingArguments)][hashtable[]]$Changes)
    $s = [ordered]@{
        AppExe = $true; AppVersion = '0.1.14'; AppPathsPresent = @($App); LnkKind = 'ours'; LnkTarget = $AppExe
        AppPathListed = $true; CoreExe = $true; CoreDirExists = $true; CoreVersion = '0.1.19'; CorePathListed = $true; CoreElsewhere = $null
    }
    foreach ($change in @($Changes)) {
        if ($null -eq $change) { continue }
        foreach ($k in $change.Keys) { $s[$k] = $change[$k] }
    }
    [pscustomobject]$s
}
$none = @{
    AppExe = $false; AppVersion = $null; AppPathsPresent = @(); LnkKind = 'missing'; LnkTarget = $null; AppPathListed = $false
    CoreExe = $false; CoreDirExists = $false; CoreVersion = $null; CorePathListed = $false; CoreElsewhere = $null
}
$winget = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Herdr.HerdrCore_x\herdr-core.exe'
$coreWinget = @{ CoreExe = $false; CoreDirExists = $false; CoreVersion = $null; CorePathListed = $false; CoreElsewhere = $winget }

# Get-HerdrAppExitCode
Test-Case '揃っていれば 0' 0 { Get-HerdrAppExitCode -State (New-State) }
Test-Case 'app が無ければ 3 (lnk や PATH が残っていても)' 3 { Get-HerdrAppExitCode -State (New-State @{ AppExe = $false }) }
Test-Case 'Herdr.lnk が無ければ 1' 1 { Get-HerdrAppExitCode -State (New-State @{ LnkKind = 'missing' }) }
Test-Case 'Herdr.lnk が別の場所を指していれば 1' 1 { Get-HerdrAppExitCode -State (New-State @{ LnkKind = 'other' }) }
Test-Case 'app の PATH の行が無ければ 1' 1 { Get-HerdrAppExitCode -State (New-State @{ AppPathListed = $false }) }
Test-Case 'core が無ければ 1' 1 { Get-HerdrAppExitCode -State (New-State @{ CoreExe = $false; CorePathListed = $false }) }
Test-Case 'core の PATH の行が無ければ 1' 1 { Get-HerdrAppExitCode -State (New-State @{ CorePathListed = $false }) }
Test-Case 'core が公式と違う置き場所にあれば 0' 0 { Get-HerdrAppExitCode -State (New-State $coreWinget) }

# Format-HerdrAppState: 状態の表の行
function Get-Rows { param($State) @(Format-HerdrAppState -State $State -AppDir $App -CoreDir $Core) }
$full = @(
    'herdr-app (公式の install.ps1 と同じ置き場所。版は app が自分で上げる)'
    "  置き場所         : $App"
    '  入っている版     : 0.1.14'
    '  スタートメニュー : Herdr.lnk'
    '  ユーザーの PATH  : あり'
    'herdr-core (無ければ入れる。上げるのは app)'
    "  置き場所         : $Core"
    '  入っている版     : 0.1.19'
    '  ユーザーの PATH  : あり'
)
Test-Case '揃っていれば表の 9 行だけで、⚠ は無い' ($full -join '|') { @((Get-Rows (New-State)) | ForEach-Object { $_.Text }) -join '|' }
Test-Case '揃っていれば Warn の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case 'app が無ければ置き場所の行を ⚠ にする' "⚠ 置き場所         : $App → 入っていない (入れる)" { (Get-Rows (New-State $none))[1].Text }
Test-Case 'app が無いときの Herdr.lnk は ⚠ にしない' '  スタートメニュー : Herdr.lnk が無い' { (Get-Rows (New-State $none))[2].Text }
Test-Case 'app が無いときの PATH は ⚠ にしない' '  ユーザーの PATH  : 無し' { (Get-Rows (New-State $none))[3].Text }
Test-Case 'app が無いときは版の行を出さない (core はある)' 8 { (Get-Rows (New-State @{ AppExe = $false; AppVersion = $null })).Count }
Test-Case 'core が無ければ置き場所の行を ⚠ にする' "⚠ 置き場所         : $Core → 入っていない (入れる)" { (Get-Rows (New-State $none))[5].Text }
Test-Case 'app が無く core も無ければ ⚠ は 2 行' 2 { @((Get-Rows (New-State $none)) | Where-Object { $_.Warn }).Count }
Test-Case 'Herdr.lnk が無ければ ⚠ で作る' '⚠ スタートメニュー : Herdr.lnk が無い → 作る' { (Get-Rows (New-State @{ LnkKind = 'missing'; LnkTarget = $null }))[3].Text }
Test-Case 'Herdr.lnk が別の場所を指していれば ⚠ で作り直す' '⚠ スタートメニュー : Herdr.lnk が別の場所を指している (C:\x\y.exe) → 作り直す' { (Get-Rows (New-State @{ LnkKind = 'other'; LnkTarget = 'C:\x\y.exe' }))[3].Text }
Test-Case 'Herdr.lnk の TargetPath が読めなければそう出す' '⚠ スタートメニュー : Herdr.lnk が別の場所を指している (読めない) → 作り直す' { (Get-Rows (New-State @{ LnkKind = 'other'; LnkTarget = '' }))[3].Text }
Test-Case 'app の PATH の行が無ければ ⚠ で足す' '⚠ ユーザーの PATH  : 無し → 足す' { (Get-Rows (New-State @{ AppPathListed = $false }))[4].Text }
Test-Case 'app の版が読めなければ不明' '  入っている版     : 不明 (herdr-app.exe --version が読めない)' { (Get-Rows (New-State @{ AppVersion = $null }))[2].Text }
Test-Case 'core の PATH の行が無ければ ⚠ で足す' '⚠ ユーザーの PATH  : 無し → 足す' { (Get-Rows (New-State @{ CorePathListed = $false }))[8].Text }
Test-Case 'core が公式と違う置き場所にあれば ⚠ にせず、その場所を出す' "  置き場所         : 公式の置き場所には無い。PATH の $winget を使う" { (Get-Rows (New-State $coreWinget))[6].Text }
Test-Case 'core が公式と違う置き場所にあれば ※ を添える' '※ herdr-core は公式と違う置き場所にある (winget など)。dotfiles は入れず、-Uninstall も触らない' { (Get-Rows (New-State $coreWinget))[-1].Text }
Test-Case 'core が公式と違う置き場所にあれば ⚠ は無い' 0 { @((Get-Rows (New-State $coreWinget)) | Where-Object { $_.Warn }).Count }

# Get-HerdrAppUninstallPlan: -Uninstall で外すもの
function Get-Plan { param($State) @(Get-HerdrAppUninstallPlan -State $State -AppDir $App -CoreDir $Core -Menu $Menu | ForEach-Object { "$($_.Kind):$($_.Target)" }) -join '|' }
Test-Case '全部あれば、app と隣のもの・lnk・PATH の 2 行・core を外す' "remove:$App|remove:$App.new|remove:$App.new.json|remove:$Menu|path:$App|remove:$Core|path:$Core" { Get-Plan (New-State @{ AppPathsPresent = @($App, "$App.new", "$App.new.json") }) }
Test-Case 'Herdr.lnk が別の場所を指していれば外さない' "remove:$App|path:$App|remove:$Core|path:$Core" { Get-Plan (New-State @{ LnkKind = 'other'; LnkTarget = 'C:\x\y.exe' }) }
Test-Case 'core が公式と違う置き場所にあれば触らない' "remove:$App|remove:$Menu|path:$App" { Get-Plan (New-State $coreWinget) }
Test-Case 'app が無くても、残った lnk と PATH の行は外す' "remove:$Menu|path:$App" { Get-Plan (New-State $none @{ LnkKind = 'ours'; LnkTarget = $AppExe; AppPathListed = $true }) }
Test-Case '何も無ければ外すものは無い' '' { Get-Plan (New-State $none) }

# Format-HerdrAppKept: -Uninstall で残したもの (設定・core の状態と設定・別の場所の lnk と core)
$loc = [pscustomobject]@{
    AppDir = $App; CoreDir = $Core; Menu = $Menu
    AppHome = 'C:\Users\u\.config\herdr-app'; CoreState = 'C:\Users\u\AppData\Local\herdr-core'; CoreConfig = 'C:\Users\u\AppData\Roaming\herdr-core'
}
$all = { param($p) $true }
$nothing = { param($p) $false }
Test-Case '設定と core の状態・設定があれば、残したと出す' "残した: $($loc.AppHome) (設定と mod)|残した: $($loc.CoreState) (herdr-core の状態)|残した: $($loc.CoreConfig) (herdr-core の設定)" {
    @(Format-HerdrAppKept -State (New-State) -Locations $loc -Exists $all) -join '|'
}
Test-Case '別の場所を指す lnk と、公式と違う置き場所の core も残したと出す' "残した: $Menu (C:\x\y.exe を指している)|残した: $winget (公式と違う置き場所の herdr-core)" {
    @(Format-HerdrAppKept -State (New-State $coreWinget @{ LnkKind = 'other'; LnkTarget = 'C:\x\y.exe' }) -Locations $loc -Exists $nothing) -join '|'
}
Test-Case '残すものが無ければ何も出さない' '' { @(Format-HerdrAppKept -State (New-State) -Locations $loc -Exists $nothing) -join '|' }

# Format-HerdrAppBusy: 動いているプロセスと止め方
$appProc = [pscustomobject]@{ Id = 1001; Name = 'herdr-app.exe'; Path = $AppExe; CommandLine = "`"$AppExe`"" }
$coreProc = [pscustomobject]@{ Id = 1002; Name = 'herdr-core.exe'; Path = "$Core\herdr-core.exe"; CommandLine = 'herdr-core.exe server' }
# 管理者で動いているなどで、実行ファイルのパスが読めない core
$hiddenCore = [pscustomobject]@{ Id = 1003; Name = 'herdr-core.exe'; Path = $null; CommandLine = $null }
Test-Case 'app と core が動いていれば、両方の止め方と PID を出す' @(
    'herdr-app か herdr-core が動いている (2 個) ので、何も外していない。止めてから打ち直す:'
    '  app: 窓を閉じる'
    "  core: & '$Core\herdr-core.exe' server stop を打つ (core の中の terminal と、そこで動いているものも終わる)"
    "  1001  $AppExe  `"$AppExe`""
    "  1002  $Core\herdr-core.exe  herdr-core.exe server"
) { Format-HerdrAppBusy -Processes @($appProc, $coreProc) -CoreDir $Core }
Test-Case 'app だけなら core の止め方は出さない' 0 { @(Format-HerdrAppBusy -Processes @($appProc) -CoreDir $Core | Where-Object { $_ -like '*server stop*' }).Count }
Test-Case 'core だけなら app の止め方は出さない' 0 { @(Format-HerdrAppBusy -Processes @($coreProc) -CoreDir $Core | Where-Object { $_ -like '*窓を閉じる*' }).Count }
Test-Case 'パスが読めない herdr-core.exe は core として止め方を出し、読めないと添える' @(
    'herdr-app か herdr-core が動いている (1 個) ので、何も外していない。止めてから打ち直す:'
    "  core: & '$Core\herdr-core.exe' server stop を打つ (core の中の terminal と、そこで動いているものも終わる)"
    '  1003  herdr-core.exe (パスが読めないので名前で数えた。管理者で動いているなど)  '
) { Format-HerdrAppBusy -Processes @($hiddenCore) -CoreDir $Core }

# Test-HerdrAppBusyEntry: 動いているプロセスに数えるか (パスが読めなければ名前で)
Test-Case 'パスが置き場所の下なら数える' 'True' { Test-HerdrAppBusyEntry -Path "$Core\conpty\x64\OpenConsole.exe" -Name 'OpenConsole.exe' -Dirs $watch }
Test-Case 'パスがほかの場所なら、名前が herdr-core.exe でも数えない (winget など)' 'False' { Test-HerdrAppBusyEntry -Path $winget -Name 'herdr-core.exe' -Dirs $watch }
Test-Case 'パスが読めない herdr-core.exe は数える' 'True' { Test-HerdrAppBusyEntry -Path $null -Name 'herdr-core.exe' -Dirs $watch }
Test-Case 'パスが読めない HERDR-APP.EXE も数える (大文字小文字を区別しない)' 'True' { Test-HerdrAppBusyEntry -Path '' -Name 'HERDR-APP.EXE' -Dirs $watch }
Test-Case 'パスが読めない hc.exe も数える' 'True' { Test-HerdrAppBusyEntry -Path $null -Name 'hc.exe' -Dirs $watch }
Test-Case 'パスが読めない OpenConsole.exe は数えない (Windows Terminal も持つ)' 'False' { Test-HerdrAppBusyEntry -Path $null -Name 'OpenConsole.exe' -Dirs $watch }
Test-Case 'パスが読めないほかのプロセスは数えない' 'False' { Test-HerdrAppBusyEntry -Path $null -Name 'pwsh.exe' -Dirs $watch }

# Get-HerdrAppExeVersion: 実行ファイルに --version を打って版を読む。壊れた・終わらないものでも止まらない
$tmpBin = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-app-tests-bin-$PID"
New-Item -ItemType Directory -Force $tmpBin | Out-Null
$okExe = Join-Path $tmpBin 'ok'
$hangExe = Join-Path $tmpBin 'hang'
$brokenExe = Join-Path $tmpBin 'broken'
Set-Content -LiteralPath $okExe -Value "#!/bin/sh`necho 'herdr-app 0.1.14'"
Set-Content -LiteralPath $hangExe -Value "#!/bin/sh`nsleep 30"
Set-Content -LiteralPath $brokenExe -Value '' -NoNewline
if (-not $IsWindows) { chmod +x $okExe $hangExe $brokenExe }
Test-Case '--version の出力から版を読む' '0.1.14' { Get-HerdrAppExeVersion -Exe $okExe -Name 'herdr-app' }
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
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-HerdrApp.ps1') -Check 2>&1
    $LASTEXITCODE
}
Test-Case '-Uninstall と -Check を一緒に打つと終了コード 2' '2' {
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-HerdrApp.ps1') -Uninstall -Check 2>&1
    $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Invoke-InstallHerdrApp の流れ。Windows に触る関数を偽物に差し替えて、すること (入れる・作る・足す・外す) の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
function Get-Leaf { param([string]$Path) $Path.Substring($Path.LastIndexOf('\') + 1) }
function Get-DirName { param([string]$Dir) if ($Dir -eq $App) { 'app' } elseif ($Dir -eq $Core) { 'core' } else { $Dir } }

function Get-HerdrAppLocations { $loc }
function Get-HerdrAppState { param($Locations) $script:States.Dequeue() }
function Get-HerdrAppDownloadBlocker { param($Tar) $script:Blocker }
function Install-HerdrAppPackage {
    param($AppDir, $Releases, $Target, $Tar)
    $script:Calls.Add('app')
    if ($script:Fail.ContainsKey('app')) { throw 'curl.exe の終了コード 6' }
    '0.1.14'
}
function Install-HerdrCorePackage {
    param($CoreDir, $Releases, $Target, $Tar)
    $script:Calls.Add('core')
    if ($script:Fail.ContainsKey('core')) { throw 'sha256 が違う' }
    '0.1.19'
}
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
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [switch]$Uninstall, [hashtable]$Fail = @{}, [object[]]$Busy = @(), [string]$Blocker = $null)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:Busy = $Busy
    $script:Blocker = $Blocker
    $out = @(Invoke-InstallHerdrApp -Check:$Check -IfMissing:$IfMissing -Uninstall:$Uninstall 6>&1)
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
Test-Case '-Check で入っていなければ、入れ方を出す' $true { $r = Invoke-Flow -States @($missing) -Check; $r.Text -like '*Install-HerdrApp で入れる*' }
Test-Case '-IfMissing は app があれば、欠けているものがあっても何もしない' '1 []' { $r = Invoke-Flow -States @((New-State @{ LnkKind = 'missing' })) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は app が無ければ、app と core を入れて lnk と PATH の 2 行を足す' '0 [app lnk path+app core path+core]' { $r = Invoke-Flow -States @($missing, $installed) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '流れが返す値は終了コード 1 つだけ (exit に配列を渡さない)' 1 { (Invoke-Flow -States @($missing, $installed) -IfMissing).Ints }
Test-Case '揃っていれば何もしない' '0 []' { $r = Invoke-Flow -States @($installed); "$($r.Code) [$($r.Calls)]" }
Test-Case '付けないときは、欠けた Herdr.lnk だけを作る' '0 [lnk]' { $r = Invoke-Flow -States @((New-State @{ LnkKind = 'missing' }), $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case '付けないときは、別の場所を指す Herdr.lnk を作り直す' '0 [lnk]' { $r = Invoke-Flow -States @((New-State @{ LnkKind = 'other'; LnkTarget = 'C:\x\y.exe' }), $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case '付けないときは、欠けた core の PATH の行だけを足す' '0 [path+core]' { $r = Invoke-Flow -States @((New-State @{ CorePathListed = $false }), $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case '付けないときは、欠けた core だけを入れる' '0 [core path+core]' { $r = Invoke-Flow -States @((New-State @{ CoreExe = $false; CoreDirExists = $false; CorePathListed = $false }), $installed); "$($r.Code) [$($r.Calls)]" }
Test-Case 'core が公式と違う置き場所にあれば、core は入れない' '0 [app lnk path+app]' { $r = Invoke-Flow -States @((New-State $none $coreWinget), (New-State $coreWinget)); "$($r.Code) [$($r.Calls)]" }
Test-Case 'core を入れられなければ、app は入れたまま 1' '1 [app lnk path+app core]' { $r = Invoke-Flow -States @($missing, (New-State @{ CoreExe = $false; CoreDirExists = $false; CorePathListed = $false })) -Fail @{ core = 1 }; "$($r.Code) [$($r.Calls)]" }
Test-Case 'core を入れられなければ、わけを出す' $true { $r = Invoke-Flow -States @($missing, (New-State @{ CoreExe = $false; CorePathListed = $false })) -Fail @{ core = 1 }; $r.Text -like '*herdr-core を入れられなかった: sha256 が違う*' }
Test-Case 'app を入れられなければ、lnk も PATH も触らずに 1' '1 [app]' { $r = Invoke-Flow -States @($missing) -Fail @{ app = 1 }; "$($r.Code) [$($r.Calls)]" }
Test-Case 'app を入れられなければ、打ち直し方を出す' $true { $r = Invoke-Flow -States @($missing) -Fail @{ app = 1 }; ($r.Text -like '*herdr-app を入れられなかった: curl.exe の終了コード 6*') -and ($r.Text -like '*Install-HerdrApp を打ち直す*') }
Test-Case '落として入れられない PC (x64 でない) なら何もせずに 1' '1 []' { $r = Invoke-Flow -States @($missing) -Blocker 'x64 だけ'; "$($r.Code) [$($r.Calls)]" }
Test-Case 'lnk と PATH を足すだけなら、落とせるかは見ない' '0 [lnk]' { $r = Invoke-Flow -States @((New-State @{ LnkKind = 'missing' }), $installed) -Blocker 'x64 だけ'; "$($r.Code) [$($r.Calls)]" }

$busy = @($appProc, $coreProc)
$full3 = New-State @{ AppPathsPresent = @($App, "$App.old") }
Test-Case '-Uninstall は動いていれば何も外さずに 1' '1 []' { $r = Invoke-Flow -States @($full3) -Uninstall -Busy $busy; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Uninstall は動いていれば止め方と PID を出す' $true { $r = Invoke-Flow -States @($full3) -Uninstall -Busy $busy; ($r.Text -like '*server stop*') -and ($r.Text -like '*1002*herdr-core.exe server*') }
Test-Case '-Uninstall は止まっていれば、app と隣のもの・lnk・core・PATH の 2 行を外して 0' '0 [rm:herdr-app rm:herdr-app.old rm:Herdr.lnk rm:herdr-core path-app,core]' { $r = Invoke-Flow -States @($full3, $missing) -Uninstall; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Uninstall は外したものを出す' $true { $r = Invoke-Flow -States @($full3, $missing) -Uninstall; ($r.Text -like "*外した: $App.old*") -and ($r.Text -like "*外した: ユーザーの PATH の $Core*") }
Test-Case '-Uninstall は別の場所の lnk と core に触らない' '0 [rm:herdr-app path-app]' { $r = Invoke-Flow -States @((New-State $coreWinget @{ LnkKind = 'other'; LnkTarget = 'C:\x\y.exe' }), (New-State $none $coreWinget @{ LnkKind = 'other'; LnkTarget = 'C:\x\y.exe' })) -Uninstall; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Uninstall は何も無ければ何もせずに 0 (動いているかも見ない)' '0 []' { $r = Invoke-Flow -States @($missing) -Uninstall -Busy $busy; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Uninstall で外せないものがあれば 1' 1 { $r = Invoke-Flow -States @($full3, (New-State $none @{ CoreDirExists = $true })) -Uninstall -Fail @{ 'rm:herdr-core' = 1 }; $r.Code }
Test-Case '-Uninstall で外せなかったものを出す' $true { $r = Invoke-Flow -States @($full3, (New-State $none @{ CoreDirExists = $true })) -Uninstall -Fail @{ 'rm:herdr-core' = 1 }; $r.Text -like "*外せなかった: $Core*" }
Test-Case '-Uninstall の流れが返す値も終了コード 1 つだけ' 1 { (Invoke-Flow -States @($full3, $missing) -Uninstall).Ints }
Test-Case '-Uninstall と -IfMissing を一緒に打つと、状態も読まずに 2' '2 []' { $r = Invoke-Flow -States @() -Uninstall -IfMissing; "$($r.Code) [$($r.Calls)]" }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
