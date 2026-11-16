# win/bootstrap/Install-Bootstrap.ps1 のうち、副作用の無い関数と、Windows に触る関数を偽物に差し替えた流れのテスト。
# Pester は使わない。winget・UAC・vswhere・gh のログイン (Ctrl+C の受け止めも)・clone の本物の動きは、Windows の実機で -Check と本番を打って確かめる
# (win/README.md の「bootstrap (新しい Windows で最初に流す)」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell --inputs-from ./nix nixpkgs#powershell --command pwsh -NoProfile -NonInteractive -File win/bootstrap/Install-Bootstrap.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Script = Join-Path $PSScriptRoot 'Install-Bootstrap.ps1'

# dot-source すると関数だけを読み、本体は走らない (Install-Bootstrap.ps1 の末尾)
. $Script

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

# ---------------------------------------------------------------------------
# ファイルそのもの
# ---------------------------------------------------------------------------

# Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読み、日本語の文字列が壊れる。BOM が 2 つ重なると、2 つ目が文字として
# 残って先頭の <# が読めなくなる
Test-Case 'BOM 付きの UTF-8 で保存してある (BOM は 1 つだけ)' 'EF BB BF 3C 23' {
    $bytes = [IO.File]::ReadAllBytes($Script)
    ($bytes[0..4] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
}

# 新しい Windows には Windows PowerShell 5.1 しか無い。7 にしか無い書き方は 5.1 で構文エラーになり、何も動かない
Test-Case 'PowerShell 7 にしか無い書き方 (??・?.・三項演算子・&&・||・-AsHashtable) を使っていない' '' {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
    $bad = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
    @($tokens | Where-Object { ("$($_.Kind)" -in $bad) -or ($_.Text -eq '-AsHashtable') } |
            ForEach-Object { "$($_.Text)@$($_.Extent.StartLineNumber)" }) -join ' '
}

Test-Case 'Join-Path に 3 つ目の引数を渡していない (5.1 は 2 つまで)' '' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    @($ast.FindAll({
                param($n)
                ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Join-Path') -and
                ($n.CommandElements.Count -gt 3)
            }, $true) | ForEach-Object { $_.Extent.StartLineNumber }) -join ' '
}

# 5.1 の Start-Process -Wait は、起こしたプロセスの子孫 (gh が開いたブラウザーなど) が全部終わるまで返らない
Test-Case 'Start-Process に -Wait を付けていない (gh のログインの後、ブラウザーを閉じるまで止まる)' '' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
    @($ast.FindAll({
                param($n)
                ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Start-Process') -and
                (@($n.CommandElements | Where-Object { ($_ -is [System.Management.Automation.Language.CommandParameterAst]) -and ($_.ParameterName -eq 'Wait') }).Count -gt 0)
            }, $true) | ForEach-Object { $_.Extent.StartLineNumber }) -join ' '
}

Test-Case '固定した版は param の既定値 (check-winget-version.sh が読む行の形)' '2.56.0.4 2.103.3 17.14.44 1.29.3' {
    $text = Get-Content -LiteralPath $Script -Encoding UTF8
    foreach ($p in @('GitVersion', 'GhVersion', 'VsBuildToolsVersion', 'RustupVersion')) {
        $line = @($text | Where-Object { $_ -match "^\s*\[string\]\`$$p\s*=\s*'([^']*)'" })[0]
        if ($line -match "'([^']*)'") { $Matches[1] }
    }
}

Test-Case 'パッケージ ID は 1 行ずつの変数 (check-winget-version.sh が読む行の形)' 'Git.Git GitHub.cli Microsoft.VisualStudio.2022.BuildTools Rustlang.Rustup' {
    $text = Get-Content -LiteralPath $Script -Encoding UTF8
    foreach ($v in @('gitPackageId', 'ghPackageId', 'vsBuildToolsPackageId', 'rustupPackageId')) {
        $line = @($text | Where-Object { $_ -match "^\s*\`$$v\s*=\s*'[A-Za-z0-9][A-Za-z0-9.-]*'" })[0]
        if ($line -match "'([^']*)'") { $Matches[1] }
    }
}

# ---------------------------------------------------------------------------
# 入っている版の読み方
# ---------------------------------------------------------------------------

# Get-GitVersionFromOutput: git --version の出力を winget の版にする
Test-Case 'git: .windows.4 は 4 つの数の版' '2.56.0.4' { Get-GitVersionFromOutput -Lines @('git version 2.56.0.windows.4') }
Test-Case 'git: .windows.1 は 3 つの数の版 (winget の Git.Git の版と同じ)' '2.56.0' { Get-GitVersionFromOutput -Lines @('git version 2.56.0.windows.1') }
Test-Case 'git: 行末の CR と前後の空白を落とす' '2.56.0.4' { Get-GitVersionFromOutput -Lines @("  git version 2.56.0.windows.4`r") }
Test-Case 'git: 版の行が無ければ空' '' { Get-GitVersionFromOutput -Lines @('error: something went wrong') }

# Get-GhVersionFromOutput: gh --version の 1 行目から版を拾う
Test-Case 'gh: 1 行目の版を拾う' '2.103.3' { Get-GhVersionFromOutput -Lines @('gh version 2.103.3 (2026-10-26)', 'https://github.com/cli/cli/releases/tag/v2.103.3') }
Test-Case 'gh: 版の行が無ければ空' '' { Get-GhVersionFromOutput -Lines @('gh: command failed') }

# Get-RustupVersionFromOutput: rustup --version の出力から版を拾う (info の行や rustc の行が混ざる)
Test-Case 'rustup: 版を拾う (ほかの行が先にあっても)' '1.29.3' { Get-RustupVersionFromOutput -Lines @('info: This is the version for the rustup toolchain manager, not the rustc compiler.', 'rustup 1.29.3 (8c9a7b0c1 2026-11-03)') }
Test-Case 'rustup: rustc の行は版と読まない' '' { Get-RustupVersionFromOutput -Lines @('rustc 1.91.0 (f8297e351 2025-10-28)') }

# ---------------------------------------------------------------------------
# Visual Studio Build Tools
# ---------------------------------------------------------------------------

$bt2022 = '{"productId":"Microsoft.VisualStudio.Product.BuildTools","installationPath":"C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools","installationVersion":"17.14.36616.10","catalog":{"productDisplayVersion":"17.14.44"},"packages":[{"id":"Microsoft.VisualStudio.Workload.VCTools","type":"Workload"},{"id":"Microsoft.VisualStudio.Component.VC.Tools.x86.x64","type":"Component"},{"id":"Microsoft.VisualStudio.Component.Windows11SDK.26100","type":"Component"}]}'
$bt2026 = '{"productId":"Microsoft.VisualStudio.Product.BuildTools","installationPath":"C:\\Program Files (x86)\\Microsoft Visual Studio\\18\\BuildTools","installationVersion":"18.11.11222.10","catalog":{"productDisplayVersion":"18.11.3"},"packages":[]}'
$community = '{"productId":"Microsoft.VisualStudio.Product.Community","installationPath":"C:\\Program Files\\Microsoft Visual Studio\\2022\\Community","installationVersion":"17.14.36616.10","catalog":{"productDisplayVersion":"17.14.44"},"packages":[{"id":"Microsoft.VisualStudio.Component.VC.Tools.x86.x64","type":"Component"}]}'

# Get-VsBuildToolsInstance: vswhere の JSON から、Build Tools でメジャーの合うものを選ぶ
Test-Case 'vswhere: 何も入っていなければ空' '' { Get-VsBuildToolsInstance -Json '[]' -Major 17 }
Test-Case 'vswhere: 2022 の Build Tools の置き場所と版と、入っているワークロードと部品' 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools|17.14.44|3' { $i = Get-VsBuildToolsInstance -Json "[$bt2022]" -Major 17; "$($i.Path)|$($i.Version)|$(@($i.Packages).Count)" }
Test-Case 'vswhere: 2026 と 2022 があれば 2022 を選ぶ' '17.14.44' { (Get-VsBuildToolsInstance -Json "[$bt2026,$bt2022]" -Major 17).Version }
Test-Case 'vswhere: Community だけなら空 (Build Tools は入っていない)' '' { Get-VsBuildToolsInstance -Json "[$community]" -Major 17 }

# Get-VsRequiredComponents・Get-VsMissingComponents: 入れるもの (C++ のワークロードと、rustup 1.29.3 が自分で入れるときと同じ 2 つの部品)
$vsAll = @('Microsoft.VisualStudio.Workload.VCTools', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.Windows11SDK.26100')
Test-Case 'Build Tools に入れるのは C++ のワークロード・x64 の MSVC・Windows SDK' ($vsAll -join ' ') { Get-VsRequiredComponents }
Test-Case '何も入っていなければ 3 つとも足りない' ($vsAll -join ' ') { Get-VsMissingComponents -Installed @() }
Test-Case '3 つともあれば足りないものは無い' '' { Get-VsMissingComponents -Installed $vsAll }
Test-Case 'Windows SDK は 10 や 11 の別の版でも足りる' '' { Get-VsMissingComponents -Installed @('Microsoft.VisualStudio.Workload.VCTools', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.Windows10SDK.20348') }
Test-Case 'ワークロードの必須の部品の Windows10SDK (UCRT。版の付かない ID) は SDK と数えない' 'Microsoft.VisualStudio.Component.Windows11SDK.26100' { Get-VsMissingComponents -Installed @('Microsoft.VisualStudio.Workload.VCTools', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.Windows10SDK') }
Test-Case 'MSVC と SDK だけ (ワークロードが無い) なら、ワークロードを足す' 'Microsoft.VisualStudio.Workload.VCTools' { Get-VsMissingComponents -Installed @('Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.Windows11SDK.26100') }

# Get-VsInstallCustomArgument・Get-VsModifyArgumentList: installer に渡す引数
Test-Case 'winget の --custom に渡す引数 (英語の言語パックと再起動しない)' '--norestart --addProductLang En-us --add A --add B' { Get-VsInstallCustomArgument -Components @('A', 'B') }
Test-Case 'modify は進み具合の窓を出し、置き場を二重引用符で囲む (空白を含む)' 'modify --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" --add A --passive --norestart' { Get-VsModifyArgumentList -InstallPath 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools' -Components @('A') }

# ---------------------------------------------------------------------------
# Smart App Control・rustup・winget
# ---------------------------------------------------------------------------

# Get-SmartAppControlState: レジストリの値 (0/1/2) を先に、無ければ Defender の値を読む
Test-Case 'SAC: レジストリの 0 はオフ' 'off' { Get-SmartAppControlState -PolicyState 0 -DefenderState $null }
Test-Case 'SAC: レジストリの 1 はオン' 'on' { Get-SmartAppControlState -PolicyState 1 -DefenderState $null }
Test-Case 'SAC: レジストリの 2 は評価モード' 'eval' { Get-SmartAppControlState -PolicyState 2 -DefenderState $null }
Test-Case 'SAC: レジストリが無ければ Defender の値 (大文字小文字は問わない)' 'on eval off' { "$(Get-SmartAppControlState -PolicyState $null -DefenderState 'On') $(Get-SmartAppControlState -PolicyState $null -DefenderState 'Eval') $(Get-SmartAppControlState -PolicyState $null -DefenderState 'off')" }
Test-Case 'SAC: どちらも無ければ、この Windows には無い' 'unavailable' { Get-SmartAppControlState -PolicyState $null -DefenderState $null }

# Test-RustupSelfUpdateDisabled: rustup の settings.toml に auto_self_update = "disable" があるか (rustup 1.29.3 が書く形)
$rustupSettings = "version = `"12`"`ndefault_host_tuple = `"x86_64-pc-windows-msvc`"`nprofile = `"default`"`nauto_self_update = `"disable`"`n"
Test-Case 'rustup の自己更新を止めてある' 'True' { Test-RustupSelfUpdateDisabled -SettingsText $rustupSettings }
Test-Case 'rustup の自己更新の行が無ければ止まっていない' 'False' { Test-RustupSelfUpdateDisabled -SettingsText "version = `"12`"`nprofile = `"default`"`n" }
Test-Case 'check-only は止めたことにしない' 'False' { Test-RustupSelfUpdateDisabled -SettingsText "auto_self_update = `"check-only`"`n" }
Test-Case 'settings.toml が無ければ止まっていない' 'False' { Test-RustupSelfUpdateDisabled -SettingsText $null }

# Get-RustupDefaultHost: rustup show の出力の Default host (無ければ空)。settings.toml のキーの名前 (default_host_triple・
# default_host_tuple) は rustup の版で変わるので、rustup が今使う値を出す rustup show を読む
Test-Case 'rustup show の Default host を読む (toolchain が無いとき)' 'x86_64-pc-windows-msvc' { Get-RustupDefaultHost -Lines @('Default host: x86_64-pc-windows-msvc', 'rustup home:  C:\Users\u\.rustup', '', 'no active toolchain') }
Test-Case 'GNU の host も読む (行末の CR を落とす)' 'x86_64-pc-windows-gnu' { Get-RustupDefaultHost -Lines @("Default host: x86_64-pc-windows-gnu`r", "rustup home:  C:\Users\u\.rustup`r") }
Test-Case 'Default host の行が無ければ空 (settings.toml の中身は読まない)' '' { Get-RustupDefaultHost -Lines @($rustupSettings -split "`n") }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか (今の ps1 と同じ)
$pins = @(
    'Name             Id          Version   Source Pin type'
    '------------------------------------------------------'
    'Git              Git.Git     2.56.0.4  winget Pinning'
)
Test-Case 'pin の行があれば True' 'True' { Test-WingetPinned -Lines $pins -PackageId 'Git.Git' }
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pins -PackageId 'GitHub.cli' }

# Test-WingetCancelled: winget install が「取り消された」(UAC で「はい」を押さなかった・窓を閉じた) で落ちたか。winget の
# 「取り消した」(0x8A15010C。MSI の 1602 は winget がこれにする) か、出力のインストーラーの終了コード (「…exit code: 1602」・
# 「インストーラーが終了コードで失敗しました: 1602」。exe の installer は winget が 0x8A150006 にする) が 1602・1223 か
Test-Case 'winget の「取り消した」(0x8A15010C) は取り消し' 'True' { Test-WingetCancelled -ExitCode -1978334964 -Lines @() }
Test-Case 'インストーラーの終了コード 1602 (英語の出力) は取り消し' 'True' { Test-WingetCancelled -ExitCode -1978335226 -Lines @('Installer failed with exit code: 1602') }
Test-Case 'インストーラーの終了コード 1602 (日本語の出力) も取り消し' 'True' { Test-WingetCancelled -ExitCode -1978335226 -Lines @('ダウンロード中 https://example.invalid/vs_BuildTools.exe', 'インストーラーが終了コードで失敗しました: 1602') }
Test-Case 'UAC を断ったときの 1223 も取り消し' 'True' { Test-WingetCancelled -ExitCode -1978335226 -Lines @('Installer failed with exit code: 1223') }
Test-Case 'ほかの終了コード (1603) は取り消しではない' 'False' { Test-WingetCancelled -ExitCode -1978335226 -Lines @('Installer failed with exit code: 1603') }
Test-Case 'URL の中の 1602 は終了コードと読まない' 'False' { Test-WingetCancelled -ExitCode -1978335226 -Lines @('ダウンロード中 https://download.visualstudio.microsoft.com/download/pr/6bd63d7f-1602-4e03/vs_BuildTools.exe') }
Test-Case 'winget が 0 で終わったら取り消しではない' 'False' { Test-WingetCancelled -ExitCode 0 -Lines @('Installer failed with exit code: 1602') }

# Get-WingetInstallArguments: 固定した版で入れる winget の引数
Test-Case 'install は版を名指しし、道具ごとの引数を後ろに足す' 'install --id Git.Git --exact --source winget --silent --accept-source-agreements --disable-interactivity --version 2.56.0.4 --accept-package-agreements --scope machine' { (Get-WingetInstallArguments -PackageId 'Git.Git' -Version '2.56.0.4' -Silent $true -Extra @('--scope', 'machine')) -join ' ' }
Test-Case '--silent を付けないとき (winget の既定の、進み具合の窓が出る形)' 'install --id GitHub.cli --exact --source winget --accept-source-agreements --disable-interactivity --version 2.103.3 --accept-package-agreements --installer-type wix' { (Get-WingetInstallArguments -PackageId 'GitHub.cli' -Version '2.103.3' -Silent $false -Extra @('--installer-type', 'wix')) -join ' ' }

# Get-BootstrapPackages: 入れる順と、道具ごとの引数
$packages = @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3')
Test-Case '入れる順は Git・gh・Build Tools・rustup (rustup-init が MSVC を見るので Build Tools を先に)' 'git gh vs-buildtools rustup' { ($packages | ForEach-Object { $_.Name }) -join ' ' }
Test-Case '道具ごとの ID と版' 'Git.Git=2.56.0.4 GitHub.cli=2.103.3 Microsoft.VisualStudio.2022.BuildTools=17.14.44 Rustlang.Rustup=1.29.3' { ($packages | ForEach-Object { "$($_.PackageId)=$($_.Version)" }) -join ' ' }
Test-Case 'Git は machine の scope' '--scope machine' { $packages[0].Args -join ' ' }
Test-Case 'gh は MSI (wix)' '--installer-type wix' { $packages[1].Args -join ' ' }
Test-Case 'Build Tools は C++ のワークロード・x64 の MSVC・Windows SDK を入れる' '--custom|--norestart --addProductLang En-us --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.26100' { $packages[2].Args -join '|' }
Test-Case 'rustup は MSVC の host にし、toolchain を入れない' '--custom|--default-host x86_64-pc-windows-msvc --default-toolchain none' { $packages[3].Args -join '|' }
# per-machine の MSI (gh) を、管理者でない PowerShell から quiet (--silent) で流すと UAC が出ずに落ちる。Build Tools は 10 分以上
# かかるので進み具合の窓を出す。Git は installer が自分で昇格し、rustup は user に入るので --silent でよい
Test-Case 'gh と Build Tools は --silent を付けない (UAC と進み具合の窓を出す)' 'git=True gh=False vs-buildtools=False rustup=True' { ($packages | ForEach-Object { "$($_.Name)=$($_.Silent)" }) -join ' ' }

# ---------------------------------------------------------------------------
# clone
# ---------------------------------------------------------------------------

# Get-RepoTargets: clone する repo と置き場 (ghq の既定の root の下)
Test-Case 'clone するのは dotfiles・dotfiles-private・claude-skills' 'dotfiles|git@github.com:pollenjp/dotfiles.git|C:\Users\u\ghq\github.com\pollenjp\dotfiles dotfiles-private|git@github.com:pollenjp/dotfiles-private.git|C:\Users\u\ghq\github.com\pollenjp\dotfiles-private claude-skills|git@github.com:pollenjp/claude-skills.git|C:\Users\u\ghq\github.com\pollenjp\claude-skills' {
    (Get-RepoTargets -GhqRoot 'C:\Users\u\ghq' | ForEach-Object { "$($_.Name)|$($_.Url)|$($_.Directory)" }) -join ' '
}

# Test-RepoOrigin: origin (設定ファイルの値) がその repo の GitHub の URL か
Test-Case 'origin: ssh の URL' 'True' { Test-RepoOrigin -Url 'git@github.com:pollenjp/dotfiles.git' -Owner 'pollenjp' -Repo 'dotfiles' }
Test-Case 'origin: https の URL (.git なし) と ssh:// の URL' 'True True' { "$(Test-RepoOrigin -Url 'https://github.com/pollenjp/dotfiles' -Owner 'pollenjp' -Repo 'dotfiles') $(Test-RepoOrigin -Url 'ssh://git@github.com/pollenjp/dotfiles.git' -Owner 'pollenjp' -Repo 'dotfiles')" }
Test-Case 'origin: 大文字小文字は問わない' 'True' { Test-RepoOrigin -Url 'git@github.com:PollenJP/Dotfiles.git' -Owner 'pollenjp' -Repo 'dotfiles' }
Test-Case 'origin: 別の owner・別の repo は偽' 'False False' { "$(Test-RepoOrigin -Url 'git@github.com:someone/dotfiles.git' -Owner 'pollenjp' -Repo 'dotfiles') $(Test-RepoOrigin -Url 'git@github.com:pollenjp/dotfiles-private.git' -Owner 'pollenjp' -Repo 'dotfiles')" }
Test-Case 'origin: 空は偽' 'False' { Test-RepoOrigin -Url '' -Owner 'pollenjp' -Repo 'dotfiles' }

# Get-GitCloneArguments: gh の資格情報で HTTPS を通す組 (dotfiles の nix/pkgs/git-gh と同じ) を -c で渡す。~/.gitconfig は書かない
Test-Case 'clone の組は gh のパスを / にして一重引用符で囲む' '-c|credential.https://github.com.helper=|-c|credential.https://github.com.helper=!''C:/Program Files/GitHub CLI/gh.exe'' auth git-credential|-c|url.https://github.com/.insteadOf=git@github.com:|clone|-c|core.autocrlf=false|git@github.com:pollenjp/dotfiles.git|C:\Users\u\ghq\github.com\pollenjp\dotfiles' {
    (Get-GitCloneArguments -GhPath 'C:\Program Files\GitHub CLI\gh.exe' -Url 'git@github.com:pollenjp/dotfiles.git' -Directory 'C:\Users\u\ghq\github.com\pollenjp\dotfiles') -join '|'
}

# ---------------------------------------------------------------------------
# 状態の行・終了コード・締めの行
# ---------------------------------------------------------------------------

$Ghq = 'C:\Users\u\ghq\github.com\pollenjp'
$Msvc = 'x86_64-pc-windows-msvc'
$Gnu = 'x86_64-pc-windows-gnu'

# 揃っている状態。テストごとに一部を差し替える
function New-Package {
    param([string]$Name, [string]$Title, [string]$Id, [string]$Target, [hashtable]$Change = @{})
    $p = [ordered]@{
        Name = $Name; Title = $Title; PackageId = $Id; Target = $Target; Exists = $true; Installed = $Target; Pinned = $true
        InstallPath = $null; MissingComponents = @(); SelfUpdateDisabled = $true; DefaultHost = $Msvc
    }
    foreach ($k in $Change.Keys) { $p[$k] = $Change[$k] }
    [pscustomobject]$p
}
function New-Repo {
    param([string]$Name, [hashtable]$Change = @{})
    $r = [ordered]@{
        Name = $Name; Url = "git@github.com:pollenjp/$Name.git"; Directory = "$Ghq\$Name"; State = 'ok'
        Origin = "git@github.com:pollenjp/$Name.git"; AutoCrlf = 'false'
    }
    foreach ($k in $Change.Keys) { $r[$k] = $Change[$k] }
    [pscustomobject]$r
}
function New-State {
    param([hashtable]$Change = @{}, [hashtable]$Git = @{}, [hashtable]$Gh = @{}, [hashtable]$Vs = @{}, [hashtable]$Rustup = @{}, [hashtable]$Dotfiles = @{}, [hashtable]$Private = @{})
    $s = [ordered]@{
        Elevated   = $false
        Arch       = 'AMD64'
        Sac        = 'off'
        Packages   = @(
            (New-Package 'git' 'Git for Windows' 'Git.Git' '2.56.0.4' $Git)
            (New-Package 'gh' 'GitHub CLI' 'GitHub.cli' '2.103.3' $Gh)
            (New-Package 'vs-buildtools' 'Visual Studio Build Tools 2022' 'Microsoft.VisualStudio.2022.BuildTools' '17.14.44' $Vs)
            (New-Package 'rustup' 'rustup' 'Rustlang.Rustup' '1.29.3' $Rustup)
        )
        GhLoggedIn = $true
        Repos      = @((New-Repo 'dotfiles' $Dotfiles), (New-Repo 'dotfiles-private' $Private), (New-Repo 'claude-skills'))
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$fresh = @{ Exists = $false; Installed = $null; Pinned = $false }
$freshRepo = @{ State = 'missing'; Origin = $null; AutoCrlf = $null }
function New-FreshState {
    $s = New-State -Git $fresh -Gh $fresh -Vs $fresh -Rustup ($fresh + @{ SelfUpdateDisabled = $false; DefaultHost = $null }) -Dotfiles $freshRepo -Private $freshRepo
    $s.GhLoggedIn = $null
    $s.Repos[2] = New-Repo 'claude-skills' $freshRepo
    $s
}

# 行のうち、直すことがあるもの (Kind が空でない) を「ラベル=種類」で並べる
function Get-Kinds { param($State) (@(Get-BootstrapRows -State $State | Where-Object { $_.Kind }) | ForEach-Object { "$($_.Label)=$($_.Kind)" }) -join ' ' }

Test-Case '揃っていれば直すことは無い' '' { Get-Kinds (New-State) }
Test-Case 'まっさらな PC は、入っていない・無いものだけ' 'Git for Windows=missing GitHub CLI=missing Visual Studio Build Tools 2022=missing rustup=missing gh のログイン=missing dotfiles=missing dotfiles-private=missing claude-skills=missing' { Get-Kinds (New-FreshState) }
Test-Case 'SAC がオンでも止める理由にはせず、bootstrap では直らない差 (警告して続ける)' 'Smart App Control=manual' { Get-Kinds (New-State @{ Sac = 'on' }) }
Test-Case 'SAC が評価モードなら bootstrap では直らない差' 'Smart App Control=manual' { Get-Kinds (New-State @{ Sac = 'eval' }) }
Test-Case 'SAC の無い Windows は直すことが無い' '' { Get-Kinds (New-State @{ Sac = 'unavailable' }) }
Test-Case '管理者の PowerShell は止める理由' '管理者の権限=blocker' { Get-Kinds (New-State @{ Elevated = $true }) }
Test-Case 'ARM64 は今は対象外 (Rust は x64 の MSVC の host だけ)' 'CPU=blocker' { Get-Kinds (New-State @{ Arch = 'ARM64' }) }
Test-Case '知らない CPU は止める理由' 'CPU=blocker' { Get-Kinds (New-State @{ Arch = 'x86' }) }
Test-Case '版のずれは bootstrap では直らない差' 'Git for Windows=manual' { Get-Kinds (New-State -Git @{ Installed = '2.55.0.5' }) }
Test-Case '版が読めなければ bootstrap では直らない差' 'GitHub CLI=manual' { Get-Kinds (New-State -Gh @{ Installed = $null }) }
Test-Case 'pin が無ければ足りない' 'GitHub CLI の pin=fix' { Get-Kinds (New-State -Gh @{ Pinned = $false }) }
Test-Case 'Build Tools の部品が足りなければ足りない' 'Build Tools の部品=fix' { Get-Kinds (New-State -Vs @{ MissingComponents = @('Microsoft.VisualStudio.Component.Windows11SDK.26100'); InstallPath = 'C:\BT' }) }
Test-Case 'rustup の自己更新が止まっていなければ足りない' 'rustup の自己更新=fix' { Get-Kinds (New-State -Rustup @{ SelfUpdateDisabled = $false }) }
Test-Case 'rustup の既定の host が GNU なら足りない (MSVC に直す)' 'rustup の既定の host=fix' { Get-Kinds (New-State -Rustup @{ DefaultHost = $Gnu }) }
Test-Case 'rustup の既定の host が読めなければ足りない' 'rustup の既定の host=fix' { Get-Kinds (New-State -Rustup @{ DefaultHost = $null }) }
Test-Case 'gh がログインしていなければ足りない' 'gh のログイン=fix' { Get-Kinds (New-State @{ GhLoggedIn = $false }) }
Test-Case 'git の repo でないディレクトリ・別の origin の clone は bootstrap では直らない差' 'dotfiles=manual dotfiles-private=manual' { Get-Kinds (New-State -Dotfiles @{ State = 'not-git' } -Private @{ State = 'other-origin'; Origin = 'git@github.com:someone/dotfiles-private.git' }) }
Test-Case '改行が false でない clone' 'dotfiles=manual' { Get-Kinds (New-State -Dotfiles @{ State = 'autocrlf'; AutoCrlf = 'true' }) }
Test-Case 'git が無くて確かめられないディレクトリは、入れた後に確かめる (入っていないものと同じ)' 'dotfiles=missing' { Get-Kinds (New-State -Dotfiles @{ State = 'unknown' }) }

# Get-BootstrapExitCode: 0 = 直すことが無い・3 = 入っていない・無いものだけ・1 = ほかに直すことがある
Test-Case '揃っていれば 0' 0 { Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State (New-State)) }
Test-Case 'まっさらな PC は 3' 3 { Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State (New-FreshState)) }
Test-Case 'pin が無ければ 1' 1 { Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State (New-State -Gh @{ Pinned = $false })) }
Test-Case 'まっさらでも SAC がオンなら 1' 1 { $s = New-FreshState; $s.Sac = 'on'; Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State $s) }

# Format-BootstrapRows: 表の行。直すことがある行だけ先頭に ⚠、ほかは 2 字下げ。※ の行は表の後ろ
function Get-Lines { param($State) @(Format-BootstrapRows -Rows @(Get-BootstrapRows -State $State)) }
Test-Case '揃っていれば ⚠ の行は無い' '0' { @(Get-Lines (New-State) | Where-Object { $_ -like '⚠*' }).Count }
Test-Case 'Git の行は版を出す' '  Git for Windows : 2.56.0.4' { @(Get-Lines (New-State) | Where-Object { $_ -like '*Git for Windows*' })[0] }
Test-Case 'rustup の行は版と既定の host を出す' '  rustup : 1.29.3 (既定の host は x86_64-pc-windows-msvc)' { @(Get-Lines (New-State) | Where-Object { $_ -like '*rustup :*' })[0] }
Test-Case '既定の host が読めなければ、rustup の行は読めないと出す (空のまま出さない)' '  rustup : 1.29.3 (既定の host が読めない)' { @(Get-Lines (New-State -Rustup @{ DefaultHost = $null }) | Where-Object { $_ -like '*rustup :*' })[0] }
Test-Case '入っていなければ固定した版を入れると出す' '⚠ GitHub CLI : 入っていない → 2.103.3 を入れる' { @(Get-Lines (New-State -Gh $fresh) | Where-Object { $_ -like '*GitHub CLI :*' })[0] }
Test-Case '版のずれは ※ で上げ方と下げ方を出す' '⚠ Git for Windows : 2.55.0.5 (固定した版は 2.56.0.4)|※ Git for Windows を固定した版に揃えるのは bootstrap ではしない。上げるなら winget upgrade --id Git.Git --exact --version 2.56.0.4 --include-pinned、下げるなら winget uninstall --id Git.Git の後に流し直す' {
    $l = Get-Lines (New-State -Git @{ Installed = '2.55.0.5' }); "$(@($l | Where-Object { $_ -like '*Git for Windows :*' })[0])|$(@($l | Where-Object { $_ -like '※*' })[0])"
}
Test-Case 'rustup の上げ方には MSVC の host と toolchain を入れない引数を添える' '※ rustup を固定した版に揃えるのは bootstrap ではしない。上げるなら winget upgrade --id Rustlang.Rustup --exact --version 1.29.3 --include-pinned --custom "--default-host x86_64-pc-windows-msvc --default-toolchain none"、下げるなら winget uninstall --id Rustlang.Rustup の後に流し直す' {
    @(Get-Lines (New-State -Rustup @{ Installed = '1.28.2' }) | Where-Object { $_ -like '※*' })[0]
}
# 版を名指しした winget upgrade は、--include-pinned が無いと bootstrap が足した pin (Pinning) に止められる (0x8A150068。
# 2026-11-16 に pjp-raiden の OpenSSH で起きた形)。4 つの道具のどれの上げ方にも付ける
Test-Case '4 つの道具の上げ方は、どれも bootstrap が足した pin を越える (--include-pinned)' 'Git.Git=True GitHub.cli=True Microsoft.VisualStudio.2022.BuildTools=True Rustlang.Rustup=True' {
    $s = New-State -Git @{ Installed = '2.55.0.5' } -Gh @{ Installed = '2.100.0' } -Vs @{ Installed = '17.14.40' } -Rustup @{ Installed = '1.28.2' }
    $notes = @(Get-Lines $s | Where-Object { $_ -like '※*' })
    @('Git.Git', 'GitHub.cli', 'Microsoft.VisualStudio.2022.BuildTools', 'Rustlang.Rustup') | ForEach-Object {
        $id = $_
        $note = @($notes | Where-Object { $_.Contains("winget upgrade --id $id ") })[0]
        "$id=$("$note".Contains("winget upgrade --id $id --exact --version") -and "$note".Contains('--include-pinned'))"
    }
}
Test-Case '既定の host が GNU なら、rustup set default-host で MSVC に直すと出す' '⚠ rustup の既定の host : x86_64-pc-windows-gnu → x86_64-pc-windows-msvc にする (rustup set default-host x86_64-pc-windows-msvc)' {
    @(Get-Lines (New-State -Rustup @{ DefaultHost = $Gnu }) | Where-Object { $_ -like '*既定の host :*' })[0]
}
Test-Case '既定の host が読めなければ、読めないと出して直す' '⚠ rustup の既定の host : 読めない → x86_64-pc-windows-msvc にする (rustup set default-host x86_64-pc-windows-msvc)' {
    @(Get-Lines (New-State -Rustup @{ DefaultHost = $null }) | Where-Object { $_ -like '*既定の host :*' })[0]
}
Test-Case 'Build Tools の部品が足りなければ、足りないものと Visual Studio Installer で足すことを出す' '⚠ Build Tools の部品 : 足りない: Microsoft.VisualStudio.Workload.VCTools → Visual Studio Installer で足す (UAC)' {
    @(Get-Lines (New-State -Vs @{ MissingComponents = @('Microsoft.VisualStudio.Workload.VCTools'); InstallPath = 'C:\BT' }) | Where-Object { $_ -like '*Build Tools の部品 :*' })[0]
}
Test-Case 'SAC がオンなら、オフにする場所と戻せないことがあるのを ※ で出す' '⚠ Smart App Control : オン → オフにする (cargo の産物の exe が止められ、Rust の runner を作れない)|※ Smart App Control は、Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 でオフにする (Windows によっては、戻すのに再インストールが要る)' {
    $l = Get-Lines (New-State @{ Sac = 'on' }); "$(@($l | Where-Object { $_ -like '*Smart App Control :*' })[0])|$(@($l | Where-Object { $_ -like '※*' })[0])"
}
Test-Case 'clone が無ければ置き場を出す' "⚠ dotfiles : 無い → $Ghq\dotfiles に clone する" { @(Get-Lines (New-State -Dotfiles $freshRepo) | Where-Object { $_ -like '*dotfiles :*' })[0] }

# Format-BootstrapVerdict: 締めの行 (⚠️ で始めて ⚠️ で終える)
function Get-Verdict { param($State) (@(Format-BootstrapVerdict -Rows @(Get-BootstrapRows -State $State)) | ForEach-Object { "$_" }) -join '|' }
Test-Case '揃っていれば締めの行は出さない' '' { Get-Verdict (New-State) }
Test-Case 'まっさらな PC は、引数なしで流すと揃えると出す' '⚠️ 入っていない・無いものがある → 引数なしで流すと揃える ⚠️' { Get-Verdict (New-FreshState) }
# 足りない・ずれている (fix) は流せば直るが、終了コードは 1 (3 は入っていない・無いものだけ)。3 のときと同じ文にしない
Test-Case 'pin が無いだけなら、足りないもの・ずれているものを直すと出す' '⚠️ 足りないもの・ずれているものがある → 引数なしで流すと直す ⚠️' { Get-Verdict (New-State -Gh @{ Pinned = $false }) }
Test-Case '入っていないものと host のずれが混ざれば、2 つの行を出す (終了コードは 1)' '⚠️ 入っていない・無いものがある → 引数なしで流すと揃える ⚠️|⚠️ 足りないもの・ずれているものがある → 引数なしで流すと直す ⚠️|1' {
    $s = New-State -Vs $fresh -Rustup @{ DefaultHost = $Gnu }
    "$(Get-Verdict $s)|$(Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State $s))"
}
Test-Case '止める理由があれば、何も変えていないことと、直してから流し直すことだけを出す' '⚠️ 止める理由があるので何も変えていない → ⚠ の行と ※ の手順で直してから流し直す ⚠️' { Get-Verdict (New-State @{ Elevated = $true } -Gh @{ Pinned = $false }) }
Test-Case '版のずれだけなら、※ の手順で直すと出す' '⚠️ bootstrap では直らない差がある → ※ の手順で直す ⚠️' { Get-Verdict (New-State -Git @{ Installed = '2.55.0.5' }) }

# Format-SacWarning: 最初に出す SAC の警告 (オフでなければ出し、bootstrap は続ける)
$sacWhere = '   オフにする場所: Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 (Windows によっては、戻すのに再インストールが要る)'
Test-Case 'SAC がオフなら警告しない' '' { (@(Format-SacWarning -Sac 'off') | ForEach-Object { "$_" }) -join '|' }
Test-Case 'SAC の無い Windows は警告しない' '' { (@(Format-SacWarning -Sac 'unavailable') | ForEach-Object { "$_" }) -join '|' }
Test-Case 'SAC がオンなら、Rust の runner を流す前にオフにするよう警告して続ける' "⚠️ Smart App Control がオンになっている。cargo が作った exe (Rust の runner・build script) は止められて動かないので、Rust の runner を流す前にオフにする (bootstrap はこのまま続ける)|$sacWhere" { (@(Format-SacWarning -Sac 'on') | ForEach-Object { "$_" }) -join '|' }
Test-Case 'SAC が評価モードなら、オフにしておくよう警告して続ける' "⚠️ Smart App Control が評価モードになっている。いつオンに変わるか分からず、オンになると cargo が作った exe が止められるので、オフにしておく (bootstrap はこのまま続ける)|$sacWhere" { (@(Format-SacWarning -Sac 'eval') | ForEach-Object { "$_" }) -join '|' }

# Get-GhLoginArguments: gh のログイン。--git-protocol ssh は、gh に ~/.gitconfig の credential helper を書かせないため。
# 一回限りのコードは gh がクリップボードに入れる (手で写そうとして Ctrl+C を押すと gh が止まる)
Test-Case 'gh のログインはブラウザーで、コードはクリップボードに入れ、ssh の鍵は作らない・上げない' 'auth login --hostname github.com --web --clipboard --git-protocol ssh --skip-ssh-key' { (Get-GhLoginArguments) -join ' ' }

# Set-ConsoleBreakIgnored: gh のログインのあいだ Ctrl+C を受け止める handler。C# は Add-Type で読めること (Windows でなければ
# kernel32 が無いので、足せずに $false を返す。Windows で足したら、すぐ外す) と、例外を出さずに真偽を返すことを見る
Test-Case 'Ctrl+C を受け止める handler の C# を読め、足す・外すは例外を出さずに真偽を返す' 'True True True' {
    $set = Set-ConsoleBreakIgnored -Ignore $true
    $unset = Set-ConsoleBreakIgnored -Ignore $false
    "$([bool]('DotfilesBootstrap.ConsoleBreak' -as [type])) $($set -is [bool]) $($unset -is [bool])"
}

# ---------------------------------------------------------------------------
# 状態を読む (本物の Get-BootstrapState。Windows に触る一番下の関数だけを偽物にし、道具の置き場所は一時ディレクトリの空のファイル)
# ---------------------------------------------------------------------------

$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('install-bootstrap-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stateRoot | Out-Null
foreach ($f in @('git.exe', 'gh.exe', 'rustup.exe')) { Set-Content -LiteralPath (Join-Path $stateRoot $f) -Value '' }
# settings.toml の既定の host は GNU のまま。rustup show が MSVC を出せば、host は rustup show から読んでいる
Set-Content -LiteralPath (Join-Path $stateRoot 'settings.toml') -Value "version = `"12`"`ndefault_host_tuple = `"x86_64-pc-windows-gnu`"`nauto_self_update = `"disable`"`n"
$statePaths = [pscustomobject]@{
    Git = (Join-Path $stateRoot 'git.exe'); Gh = (Join-Path $stateRoot 'gh.exe'); Rustup = (Join-Path $stateRoot 'rustup.exe')
    RustupSettings = (Join-Path $stateRoot 'settings.toml'); VsWhere = (Join-Path $stateRoot 'vswhere.exe'); VsSetup = (Join-Path $stateRoot 'setup.exe')
    GhqRoot = (Join-Path $stateRoot 'ghq')
}
$script:NativeLog = [System.Collections.Generic.List[string]]::new()
# MSVC とワークロードはあるが、SDK は版の付かない UCRT だけの Build Tools 2022
$script:VsJson = '[{"productId":"Microsoft.VisualStudio.Product.BuildTools","installationPath":"C:\\BT","catalog":{"productDisplayVersion":"17.14.44"},"packages":[{"id":"Microsoft.VisualStudio.Workload.VCTools","type":"Workload"},{"id":"Microsoft.VisualStudio.Component.VC.Tools.x86.x64","type":"Component"},{"id":"Microsoft.VisualStudio.Component.Windows10SDK","type":"Component"}]}]'
function Test-Elevated { $false }
function Get-BootstrapSac { 'off' }
function Read-VsWhere { param([string]$VsWhere) $script:VsJson }
function Invoke-Winget { param([string[]]$Arguments) [pscustomobject]@{ ExitCode = 0; Lines = @("x $($Arguments[3])") } }
# 打ったものを「exe 引数 [打ったときの RUSTUP_AUTO_INSTALL]」で書き留め、道具ごとの出力を返す
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Utf8)
    $leaf = Split-Path -Leaf $FilePath
    $script:NativeLog.Add("$leaf $($Arguments -join ' ') [RUSTUP_AUTO_INSTALL=$($env:RUSTUP_AUTO_INSTALL)]")
    $lines = @()
    switch ("$leaf $($Arguments -join ' ')") {
        'git.exe --version' { $lines = @('git version 2.56.0.windows.4') }
        'gh.exe --version' { $lines = @('gh version 2.103.3 (2026-10-26)') }
        'rustup.exe --version' { $lines = @('rustup 1.29.3 (8c9a7b0c1 2026-11-03)') }
        'rustup.exe show' { $lines = @('Default host: x86_64-pc-windows-msvc', 'rustup home:  C:\Users\u\.rustup', '', 'no active toolchain') }
    }
    [pscustomobject]@{ ExitCode = 0; Lines = $lines }
}
$statePackages = @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3')
$env:RUSTUP_AUTO_INSTALL = 'keep'
try {
    $readState = Get-BootstrapState -Packages $statePackages -Paths $statePaths -Arch 'AMD64'
    $afterEnv = $env:RUSTUP_AUTO_INSTALL
} finally {
    $env:RUSTUP_AUTO_INSTALL = $null
    Remove-Item -LiteralPath $stateRoot -Recurse -Force
}
$readRustup = @($readState.Packages | Where-Object { $_.Name -eq 'rustup' })[0]
$readVs = @($readState.Packages | Where-Object { $_.Name -eq 'vs-buildtools' })[0]

# rustup 1.29.3 は --version・show でも、cwd の rust-toolchain.toml の入っていない toolchain を入れにいく。-Check は何も変えない
Test-Case 'rustup は --version も show も RUSTUP_AUTO_INSTALL=0 で打つ (toolchain を入れさせない)' 'rustup.exe --version [RUSTUP_AUTO_INSTALL=0]|rustup.exe show [RUSTUP_AUTO_INSTALL=0]' {
    @($script:NativeLog | Where-Object { $_ -like 'rustup.exe *' }) -join '|'
}
Test-Case '打った後は RUSTUP_AUTO_INSTALL を元の値に戻す' 'keep' { $afterEnv }
Test-Case '既定の host は rustup show から読む (settings.toml の default_host_tuple は読まない)' 'x86_64-pc-windows-msvc|1.29.3|True' { "$($readRustup.DefaultHost)|$($readRustup.Installed)|$($readRustup.SelfUpdateDisabled)" }
Test-Case 'Build Tools は vswhere から版・置き場所・足りないもの (版の付いた SDK) を読む' 'True|17.14.44|C:\BT|Microsoft.VisualStudio.Component.Windows11SDK.26100' {
    "$($readVs.Exists)|$($readVs.Installed)|$($readVs.InstallPath)|$(@($readVs.MissingComponents) -join ',')"
}

# ---------------------------------------------------------------------------
# 流れ (Windows に触る関数を偽物に差し替える。ここより後ろは、上の関数のテストに戻らない)
# ---------------------------------------------------------------------------

# 呼んだものを $script:Calls に「何を・どれに」で書き留める偽物
function Test-WingetAvailable { $script:HaveWinget }
function Get-OsArchitecture { 'AMD64' }
function Get-BootstrapSac { $script:Sac }
function Get-BootstrapPaths {
    [pscustomobject]@{
        Git = 'C:\Program Files\Git\cmd\git.exe'; Gh = 'C:\Program Files\GitHub CLI\gh.exe'; Rustup = 'C:\Users\u\.cargo\bin\rustup.exe'
        RustupSettings = 'C:\Users\u\.rustup\settings.toml'; VsWhere = 'C:\vswhere.exe'; VsSetup = 'C:\setup.exe'; GhqRoot = 'C:\Users\u\ghq'
    }
}
function Invoke-Winget {
    param([string[]]$Arguments)
    $id = $Arguments[[array]::IndexOf($Arguments, '--id') + 1]
    $verb = $Arguments[0]
    if ($verb -eq 'pin') { $verb = "pin-$($Arguments[1])" }
    if (($verb -eq 'install') -and ($Arguments -notcontains '--silent')) { $verb = 'install-with-progress' }
    $script:Calls.Add("$verb $id")
    $code = 0
    if ($script:Fail.ContainsKey("$verb $id")) { $code = $script:Fail["$verb $id"] }
    $lines = @()
    if ($script:FailLines.ContainsKey("$verb $id")) { $lines = @($script:FailLines["$verb $id"]) }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Utf8)
    $script:Calls.Add("native $($Arguments -join ' ')")
    [pscustomobject]@{ ExitCode = 0; Lines = @() }
}
function Invoke-GitClone {
    param([string]$GitPath, [string[]]$Arguments)
    $script:Calls.Add("clone $($Arguments[-1] -replace '^.*\\', '')")
    [pscustomobject]@{ ExitCode = 0; Lines = @() }
}
function Invoke-VsModify {
    param([string]$VsSetup, [string]$InstallPath, [string[]]$Components)
    $script:Calls.Add("vs-modify $($Components -join ',')")
    0
}
function Invoke-GhLogin {
    param([string]$GhPath)
    $script:Calls.Add('gh-login')
    $script:LoginCode
}
function Update-ProcessPath { }
function New-CloneParent { param([string]$Directory) }
# 状態は渡した順に返し、最後の 1 つは何度でも返す (読み直す回数に縛られない)
function Get-BootstrapState {
    param([object[]]$Packages, $Paths, [string]$Arch)
    if ($script:States.Count -gt 1) { return $script:States.Dequeue() }
    $script:States.Peek()
}

function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [hashtable]$Fail = @{}, [hashtable]$FailLines = @{}, [int]$LoginCode = 0, [bool]$Winget = $true)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:FailLines = $FailLines
    $script:LoginCode = $LoginCode
    $script:HaveWinget = $Winget
    # 最初に確かめる SAC は、最初の状態と同じ値にする
    $script:Sac = $States[0].Sac
    $out = @(Invoke-InstallBootstrap -GitVersion '2.56.0.4' -GhVersion '2.103.3' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -Check:$Check 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' | ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

# 道具が入ったが、pin が無く、rustup の自己更新が止まっておらず、gh はログインしていない・clone は無い状態 (入れた直後)
function New-InstalledState {
    $s = New-State -Git @{ Pinned = $false } -Gh @{ Pinned = $false } -Vs @{ Pinned = $false } -Rustup @{ Pinned = $false; SelfUpdateDisabled = $false } -Dotfiles $freshRepo -Private $freshRepo
    $s.GhLoggedIn = $false
    $s.Repos[2] = New-Repo 'claude-skills' $freshRepo
    $s
}
function New-LoggedInState {
    $s = New-State -Dotfiles $freshRepo -Private $freshRepo
    $s.Repos[2] = New-Repo 'claude-skills' $freshRepo
    $s
}
$freshCalls = 'install Git.Git | install-with-progress GitHub.cli | install-with-progress Microsoft.VisualStudio.2022.BuildTools | install Rustlang.Rustup | pin-add Git.Git | pin-add GitHub.cli | pin-add Microsoft.VisualStudio.2022.BuildTools | pin-add Rustlang.Rustup | native set auto-self-update disable | gh-login | clone dotfiles | clone dotfiles-private | clone claude-skills'

Test-Case '-Check は何も打たない (まっさらな PC は 3)' '3 []' { $r = Invoke-Flow -States @((New-FreshState)) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check で揃っていれば 0' '0 []' { $r = Invoke-Flow -States @((New-State)) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '-Check で既定の host が GNU なら、直さずに 1' '1 []' { $r = Invoke-Flow -States @((New-State -Rustup @{ DefaultHost = $Gnu })) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case 'まっさらな PC は、4 つを入れ、pin と自己更新の止めを足し、ログインして 3 つを clone する' "0 [$freshCalls]" {
    $r = Invoke-Flow -States @((New-FreshState), (New-InstalledState), (New-LoggedInState), (New-State)); "$($r.Code) [$($r.Calls)]"
}
Test-Case '揃っていれば何も打たずに 0' '0 []' { $r = Invoke-Flow -States @((New-State)); "$($r.Code) [$($r.Calls)]" }
Test-Case 'SAC がオンでも止めず、最初に警告を出してから揃え、締めは 1' "1 [$freshCalls] True" {
    $states = @((New-FreshState), (New-InstalledState), (New-LoggedInState), (New-State))
    foreach ($s in $states) { $s.Sac = 'on' }
    $r = Invoke-Flow -States $states
    $lines = @($r.Text -split "`n")
    # 警告は表 (最初の行は見出し) より前、出力の 1 行目に出す
    "$($r.Code) [$($r.Calls)] $($lines[0] -like '⚠️ Smart App Control がオンになっている*')"
}
Test-Case '-Check でも SAC の警告を最初に出す' '1 True' { $s = New-State @{ Sac = 'eval' }; $r = Invoke-Flow -States @($s) -Check; "$($r.Code) $(@($r.Text -split "`n")[0] -like '⚠️ Smart App Control が評価モードになっている*')" }
Test-Case 'winget が無くても、SAC の警告は先に出す' '2 True' { $s = New-State @{ Sac = 'on' }; $r = Invoke-Flow -States @($s) -Winget $false; "$($r.Code) $(@($r.Text -split "`n")[0] -like '⚠️ Smart App Control*')" }
Test-Case '管理者の PowerShell なら、まっさらでも何も打たずに 1' '1 []' { $s = New-FreshState; $s.Elevated = $true; $r = Invoke-Flow -States @($s); "$($r.Code) [$($r.Calls)]" }
Test-Case 'SAC の評価モードは止めずに進み、締めは 1' '1 [install-with-progress GitHub.cli | pin-add GitHub.cli]' {
    $before = New-State @{ Sac = 'eval' } -Gh $fresh; $after = New-State @{ Sac = 'eval' }
    $r = Invoke-Flow -States @($before, (New-State @{ Sac = 'eval' } -Gh @{ Pinned = $false }), $after); "$($r.Code) [$($r.Calls)]"
}
Test-Case '版のずれは入れ替えず、ほかに直すことが無ければ何も打たずに 1' '1 []' { $r = Invoke-Flow -States @((New-State -Git @{ Installed = '2.55.0.5' })); "$($r.Code) [$($r.Calls)]" }
Test-Case 'rustup の既定の host が GNU なら、rustup set default-host で MSVC に直す' '0 [native set default-host x86_64-pc-windows-msvc]' {
    $gnu = New-State -Rustup @{ DefaultHost = $Gnu }
    $r = Invoke-Flow -States @($gnu, $gnu, (New-State)); "$($r.Code) [$($r.Calls)]"
}
Test-Case '既定の host が MSVC と読めれば、流し直しても host を設定し直さない' '0 []' { $r = Invoke-Flow -States @((New-State), (New-State)); "$($r.Code) [$($r.Calls)]" }
Test-Case 'Build Tools の部品が足りなければ、Visual Studio Installer で足りないものだけを足す' '0 [vs-modify Microsoft.VisualStudio.Workload.VCTools,Microsoft.VisualStudio.Component.Windows11SDK.26100]' {
    $lack = New-State -Vs @{ MissingComponents = @('Microsoft.VisualStudio.Workload.VCTools', 'Microsoft.VisualStudio.Component.Windows11SDK.26100'); InstallPath = 'C:\BT' }
    $r = Invoke-Flow -States @($lack, $lack, (New-State)); "$($r.Code) [$($r.Calls)]"
}
Test-Case 'install が 0 以外でも入っていれば入ったとして進む (再起動待ちなど)' '0 [install Git.Git | pin-add Git.Git] True' {
    $r = Invoke-Flow -States @((New-State -Git $fresh), (New-State -Git @{ Pinned = $false }), (New-State)) -Fail @{ 'install Git.Git' = -1978335135 }
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*0x8A150061*')"
}
Test-Case 'install が落ちて入らなければ、pin も clone もせずに 1' '1 [install Git.Git]' {
    $s = New-State -Git $fresh -Dotfiles $freshRepo
    $r = Invoke-Flow -States @($s, $s) -Fail @{ 'install Git.Git' = 1 }; "$($r.Code) [$($r.Calls)]"
}
Test-Case 'Build Tools のインストーラーが取り消されたら (1602)、取り消されたことと流し直すことを出して 1' '1 [install-with-progress Microsoft.VisualStudio.2022.BuildTools] True' {
    $s = New-State -Vs $fresh
    $key = 'install-with-progress Microsoft.VisualStudio.2022.BuildTools'
    $r = Invoke-Flow -States @($s, $s) -Fail @{ $key = -1978335226 } -FailLines @{ $key = @('インストーラーが終了コードで失敗しました: 1602') }
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*Visual Studio Build Tools 2022 のインストーラーが取り消された (UAC で「はい」を押さなかった・窓を閉じた)。流し直すと、もう一度入れる*')"
}
Test-Case '取り消しでない失敗には、取り消しの文を出さない' 'False' {
    $s = New-State -Git $fresh
    $r = Invoke-Flow -States @($s, $s) -Fail @{ 'install Git.Git' = -1978335226 } -FailLines @{ 'install Git.Git' = @('Installer failed with exit code: 1603') }
    $r.Text -like '*取り消された*'
}
Test-Case 'ログインできなければ clone しない' '1 [gh-login] True' {
    $s = New-State -Dotfiles $freshRepo; $s.GhLoggedIn = $false
    $r = Invoke-Flow -States @($s, $s) -LoginCode 1; "$($r.Code) [$($r.Calls)] $($r.Text -like '*clone しない*')"
}
# Ctrl+C で止めた gh は 0xC000013A (STATUS_CONTROL_C_EXIT) で終わる。script は止まらず、止まったことを出して締めの表まで流し、1 で終える
Test-Case 'gh のログインを Ctrl+C で止めたら、止まったことを出し、clone せずに 1 で終える' '1 [gh-login] True True' {
    $s = New-State -Dotfiles $freshRepo; $s.GhLoggedIn = $false
    $r = Invoke-Flow -States @($s, $s) -LoginCode -1073741510
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*gh のログインが終わらなかった (止めた・失敗した。終了コード 0xC000013A)*') $($r.Text -like '*⚠ gh のログイン : していない*')"
}
Test-Case 'git の repo でないディレクトリは clone せず、ほかの無い repo だけ clone する' '1 [clone dotfiles-private]' {
    $s = New-State -Dotfiles @{ State = 'not-git' } -Private $freshRepo
    $r = Invoke-Flow -States @($s, $s, (New-State -Dotfiles @{ State = 'not-git' })); "$($r.Code) [$($r.Calls)]"
}
Test-Case 'winget が無ければ、何も読まずに 2' '2 [] True' { $r = Invoke-Flow -States @((New-State)) -Winget $false; "$($r.Code) [$($r.Calls)] $($r.Text -like '*アプリ インストーラー*')" }

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
