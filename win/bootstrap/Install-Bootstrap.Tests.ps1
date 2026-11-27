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

Test-Case '固定した版は param の既定値 (check-winget-version.sh が読む行の形)' '2.56.0.4 2.103.3 7.6.10.0 17.14.44 1.29.3' {
    $text = Get-Content -LiteralPath $Script -Encoding UTF8
    foreach ($p in @('GitVersion', 'GhVersion', 'PwshVersion', 'VsBuildToolsVersion', 'RustupVersion')) {
        $line = @($text | Where-Object { $_ -match "^\s*\[string\]\`$$p\s*=\s*'([^']*)'" })[0]
        if ($line -match "'([^']*)'") { $Matches[1] }
    }
}

Test-Case 'パッケージ ID は 1 行ずつの変数 (check-winget-version.sh が読む行の形)' 'Git.Git GitHub.cli Microsoft.PowerShell Microsoft.VisualStudio.2022.BuildTools Rustlang.Rustup' {
    $text = Get-Content -LiteralPath $Script -Encoding UTF8
    foreach ($v in @('gitPackageId', 'ghPackageId', 'pwshPackageId', 'vsBuildToolsPackageId', 'rustupPackageId')) {
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

# Get-PwshVersionFromOutput: pwsh --version の出力から版 (3 つの数) を拾う
Test-Case 'pwsh: PowerShell 7.6.10 は 7.6.10' '7.6.10' { Get-PwshVersionFromOutput -Lines @('PowerShell 7.6.10') }
Test-Case 'pwsh: 行末の CR と前後の空白を落とす' '7.7.0' { Get-PwshVersionFromOutput -Lines @("  PowerShell 7.7.0`r") }
Test-Case 'pwsh: preview とほかの行は版と読まない' '' { Get-PwshVersionFromOutput -Lines @('PowerShell 7.7.0-preview.5', 'error') }

# Test-PwshVersionAccepted: PowerShell 7 として認める版か (7.6.0 より古くない。入れ方は問わない)
Test-Case 'pwsh: 7.6.0・7.6.10・7.7.0 は認め、7.5.4・7.4.13 と読めない版は認めない' '7.6.0=True 7.6.10=True 7.7.0=True 7.5.4=False 7.4.13=False =False x=False' {
    (@('7.6.0', '7.6.10', '7.7.0', '7.5.4', '7.4.13', '', 'x') | ForEach-Object { "$_=$(Test-PwshVersionAccepted -Version $_)" }) -join ' '
}

# Get-PwshCandidates: 新しい窓の PATH のディレクトリごとの pwsh.exe を順に、その後ろに MSI の置き場所と MSIX の実行エイリアスを足す
$msiPwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$aliasPwsh = 'C:\Users\u\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
# PATH の項目は PATH の字のまま並ぶ (2 つ目は小文字)。MSI の置き場所と実行エイリアスは PATH にあるので、後ろに重ねない
Test-Case 'pwsh を探す順は PATH (空の項目と引用符と末尾の \ を落とす) → MSI の置き場所 → MSIX の実行エイリアスで、同じパスは 1 つ (大文字小文字は問わない)' 'C:\Program Files\PowerShell\7\pwsh.exe=True|c:\users\u\appdata\local\microsoft\windowsapps\pwsh.exe=True|C:\Tools\pwsh.exe=True' {
    $pathValue = 'C:\Program Files\PowerShell\7\;;c:\users\u\appdata\local\microsoft\windowsapps;"C:\Tools"'
    (@(Get-PwshCandidates -PathValue $pathValue -MsiPath $msiPwsh -AliasPath $aliasPwsh) | ForEach-Object { "$($_.Path)=$($_.OnPath)" }) -join '|'
}
Test-Case 'PATH に無い MSI の置き場所と MSIX の実行エイリアスは、PATH の後ろに PATH の外として並ぶ' 'C:\Windows\system32\pwsh.exe=True|C:\Program Files\PowerShell\7\pwsh.exe=False|C:\Users\u\AppData\Local\Microsoft\WindowsApps\pwsh.exe=False' {
    (@(Get-PwshCandidates -PathValue 'C:\Windows\system32' -MsiPath $msiPwsh -AliasPath $aliasPwsh) | ForEach-Object { "$($_.Path)=$($_.OnPath)" }) -join '|'
}

# Get-PwshInstallKind・Format-PwshInstallKind: 入れ方 (WindowsApps の下は MSIX、MSI の置き場所は MSI、ほかはパスを出す)
Test-Case 'pwsh の入れ方は、実行エイリアスと WindowsApps の実体が msix、MSI の置き場所が msi、ほかは other' 'msix msix msi other' {
    $real = 'C:\Program Files\WindowsApps\Microsoft.PowerShell-LTS_7.6.10.0_x64__8wekyb3d8bbwe\pwsh.exe'
    (@($aliasPwsh, $real, 'c:\program files\powershell\7\PWSH.EXE', 'C:\tools\pwsh\pwsh.exe') | ForEach-Object { Get-PwshInstallKind -Path $_ -MsiPath $msiPwsh }) -join ' '
}
Test-Case '表に出す入れ方は MSIX・MSI と、ほかの形のパス' 'MSIX|MSI|C:\tools\pwsh\pwsh.exe' {
    "$(Format-PwshInstallKind -Kind 'msix' -Path $aliasPwsh)|$(Format-PwshInstallKind -Kind 'msi' -Path $msiPwsh)|$(Format-PwshInstallKind -Kind 'other' -Path 'C:\tools\pwsh\pwsh.exe')"
}

# Get-PwshPinVersion: bootstrap が入れた PowerShell 7 に足す pin の版 (固定した版の線)
Test-Case 'pin の版は固定した版の線 (7.6.10.0 → 7.6.*)。読めなければ空' '7.6.*|' { "$(Get-PwshPinVersion -Version '7.6.10.0')|$(Get-PwshPinVersion -Version 'x')" }

# ---------------------------------------------------------------------------
# 普段のアカウントが管理者か (PowerShell 7 の入れ方を決める)
# ---------------------------------------------------------------------------

# WindowsIdentity の Claims の偽物 (Type と Value)。UAC で権限を落とした管理者のトークンでは、BUILTIN\Administrators (S-1-5-32-544) が
# deny-only のグループ (denyonlysid) で入る。Claims の種類の名前空間は種類ごとに違う (groupsid は 2008 の、denyonlysid は 2005 の名前空間)
function New-Claim { param([string]$Type, [string]$Value) [pscustomobject]@{ Type = $Type; Value = $Value } }
$claimNs = 'http://schemas.microsoft.com/ws/2008/06/identity/claims'
$claimNs2005 = 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims'
$filteredAdminClaims = @(
    (New-Claim "$claimNs2005/name" 'PC\u')
    (New-Claim "$claimNs/primarysid" 'S-1-5-21-1-2-3-1001')
    (New-Claim "$claimNs/primarygroupsid" 'S-1-5-21-1-2-3-513')
    (New-Claim "$claimNs/groupsid" 'S-1-5-21-1-2-3-513')
    (New-Claim "$claimNs/groupsid" 'S-1-1-0')
    (New-Claim "$claimNs2005/denyonlysid" 'S-1-5-114')
    (New-Claim "$claimNs2005/denyonlysid" 'S-1-5-32-544')
    (New-Claim "$claimNs/groupsid" 'S-1-5-32-545')
    (New-Claim "$claimNs/denyonlyprimarygroupsid" 'S-1-5-21-9-9-9-513')
)
$standardUserClaims = @(
    (New-Claim "$claimNs/primarysid" 'S-1-5-21-1-2-3-1002')
    (New-Claim "$claimNs/groupsid" 'S-1-1-0')
    (New-Claim "$claimNs/groupsid" 'S-1-5-32-545')
    (New-Claim "$claimNs/groupsid" 'S-1-5-11')
)

# Select-TokenGroupSids: Claims から、有効なグループ (groupsid) と deny-only のグループ (denyonlysid) の SID を拾う
Test-Case 'トークンのグループの SID は groupsid と denyonlysid の値 (primarysid・primarygroupsid・denyonlyprimarygroupsid・name は拾わない)' 'S-1-5-21-1-2-3-513 S-1-1-0 S-1-5-114 S-1-5-32-544 S-1-5-32-545' {
    @(Select-TokenGroupSids -Claims $filteredAdminClaims) -join ' '
}
Test-Case 'Claims が空なら SID も空' '0' { @(Select-TokenGroupSids -Claims @()).Count }

# Test-AdministratorsSid: SID の並びに BUILTIN\Administrators (S-1-5-32-544) があれば管理者
Test-Case 'S-1-5-32-544 があれば管理者、無ければ (Users の S-1-5-32-545 だけ・空) 管理者でない' 'True False False False' {
    "$(Test-AdministratorsSid -Sids @('S-1-1-0', 'S-1-5-32-544')) $(Test-AdministratorsSid -Sids @('S-1-1-0', 'S-1-5-32-545')) $(Test-AdministratorsSid -Sids @()) $(Test-AdministratorsSid -Sids $null)"
}
Test-Case 'UAC で権限を落とした管理者 (deny-only の S-1-5-32-544) は管理者、普通のユーザーは管理者でない' 'True False' {
    "$(Test-AdministratorsSid -Sids @(Select-TokenGroupSids -Claims $filteredAdminClaims)) $(Test-AdministratorsSid -Sids @(Select-TokenGroupSids -Claims $standardUserClaims))"
}
# Test-AccountAdmin: 今のトークンを読む。読めなければ (Windows でない・例外) 管理者でないとみなす
Test-Case '今のトークンを読む関数は、例外を出さずに真偽を返す (Windows でなければ読めないので管理者でない)' 'True True' {
    $admin = Test-AccountAdmin
    "$($admin -is [bool]) $(if ($IsWindows) { $true } else { -not $admin })"
}

# Test-PwshInstallNeeded: PowerShell 7 を入れるか。入っていないときと、管理者でない PC で MSIX でない pwsh が無いとき (MSI を入れる)
Test-Case 'PowerShell 7 を入れるのは、入っていないときと、管理者でない PC で MSIX しか無いとき' 'True True False True False' {
    $none = [pscustomobject]@{ Exists = $false; NonMsix = $false }
    $msixOnly = [pscustomobject]@{ Exists = $true; NonMsix = $false }
    $withMsi = [pscustomobject]@{ Exists = $true; NonMsix = $true }
    @(
        (Test-PwshInstallNeeded -Package $none -AccountAdmin $true)
        (Test-PwshInstallNeeded -Package $none -AccountAdmin $false)
        (Test-PwshInstallNeeded -Package $msixOnly -AccountAdmin $true)
        (Test-PwshInstallNeeded -Package $msixOnly -AccountAdmin $false)
        (Test-PwshInstallNeeded -Package $withMsi -AccountAdmin $false)
    ) -join ' '
}

# Test-PwshForceInstall: PowerShell 7 の MSI を --force で直に入れるか。pwsh がもう入っている (管理者でない PC で MSIX しか無い) ときだけ。
# winget の install は、入っている package (MSIX も Microsoft.PowerShell に結ばれる) が見つかると upgrade に替わり、入れ方 (MSIX → MSI) を
# 替えずに止まる。入っていない PC には付けない (--force は安全に関わらない問題も越えて続ける)
Test-Case 'MSI を --force で入れるのは、管理者でない PC で MSIX しか無いときだけ (入っていない・MSI がある・管理者の PC には付けない)' 'False False True False False' {
    $none = [pscustomobject]@{ Exists = $false; NonMsix = $false }
    $msixOnly = [pscustomobject]@{ Exists = $true; NonMsix = $false }
    $withMsi = [pscustomobject]@{ Exists = $true; NonMsix = $true }
    @(
        (Test-PwshForceInstall -Package $none -AccountAdmin $true)
        (Test-PwshForceInstall -Package $none -AccountAdmin $false)
        (Test-PwshForceInstall -Package $msixOnly -AccountAdmin $false)
        (Test-PwshForceInstall -Package $msixOnly -AccountAdmin $true)
        (Test-PwshForceInstall -Package $withMsi -AccountAdmin $false)
    ) -join ' '
}

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
# 昇格した winget (Invoke-ElevatedWinget) を UAC で断った・出せなかったときは ERROR_CANCELLED (1223) を返す
Test-Case 'UAC で昇格を断った (1223) も取り消し' 'True' { Test-WingetCancelled -ExitCode 1223 -Lines @('UAC: The operation was canceled by the user.') }

# Test-WingetAccessDenied: 昇格していない winget が machine の scope の source を開けずに落ちたか (0x80070005。入れたての Windows 11 の
# winget v1.11.510 で、Git の --scope machine の install が「Failed to open the predefined source」で落ちた)
Test-Case '0x80070005 (Access is denied) は、昇格していない winget が machine の scope を読めない落ち方' 'True' { Test-WingetAccessDenied -ExitCode -2147024891 -Lines @() }
Test-Case '「Failed to open the predefined source」の行があれば、終了コードが違っても同じ' 'True' { Test-WingetAccessDenied -ExitCode -1 -Lines @('Failed to open the predefined source; please report to winget maintainers.') }
Test-Case 'ほかの落ち方 (インストーラーの 1603)・0 は違う' 'False False' { "$(Test-WingetAccessDenied -ExitCode -1978335226 -Lines @('Installer failed with exit code: 1603')) $(Test-WingetAccessDenied -ExitCode 0 -Lines @())" }

# Get-ElevationFailureCode: 昇格した winget を起こせなかったときの終了コード。UAC で断った (Win32Exception の 1223。Start-Process は
# InvalidOperationException に包む) なら 1223 (取り消し)、ほか (UAC を出せない SSH の会話など) は -1 (取り消しとは言わない。流し直しても直らない)
Test-Case '昇格を UAC で断ったら 1223 (包まれていても)、ほかの理由で起こせなければ -1' '1223 1223 -1 -1' {
    $declined = New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList 1223
    $wrapped = New-Object -TypeName System.InvalidOperationException -ArgumentList @('This command cannot be run due to the error: The operation was canceled by the user.', $declined)
    $other = New-Object -TypeName System.ComponentModel.Win32Exception -ArgumentList 1326
    $plain = New-Object -TypeName System.InvalidOperationException -ArgumentList 'x'
    "$(Get-ElevationFailureCode -Exception $declined) $(Get-ElevationFailureCode -Exception $wrapped) $(Get-ElevationFailureCode -Exception $other) $(Get-ElevationFailureCode -Exception $plain)"
}

# Select-WingetOutputLines: winget の出力の行から、進み具合の表示 (回る棒・帯) を除く。日本語の行は残す
Test-Case 'winget の出力から回る棒と帯 (█▒) の行を除き、ほかの行 (日本語も) は残す' 'Successfully installed|インストールが完了しました' {
    @(Select-WingetOutputLines -Lines @('  - ', '  \ ', '', "  $([char]0x2588)$([char]0x2588)$([char]0x2592)  1 MB / 2 MB", 'Successfully installed', 'インストールが完了しました')) -join '|'
}

# ConvertTo-EncodedCommand: -EncodedCommand に渡す形 (UTF-16LE の base64)
Test-Case '-EncodedCommand の字は UTF-16LE の base64' "exit 3 'あ'" { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String((ConvertTo-EncodedCommand -Script "exit 3 'あ'"))) }

# Format-WingetMissingNote: 昇格した側で winget が見つからないとき (Install-OpenSSH.ps1 と同じ字)
Test-Case '昇格した側で winget が見つからなければ、そのアカウントと、サインインするか Add-AppxPackage で登録する手を出す' 'winget が見つからない (昇格した側のアカウント: it-admin)|True' {
    $lines = @(Format-WingetMissingNote -Account 'it-admin')
    "$($lines[0])|$($lines[1].Contains('Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'))"
}

# Get-ElevatedWingetScript: 昇格した Windows PowerShell に渡す本文。昇格した側の winget (実行エイリアス → PATH の .exe) を引いて打ち、出力を
# UTF-8 でログに書き、winget の終了コードで終わる。Linux の pwsh で本文をそのまま流して確かめる (偽の winget.exe を実行エイリアスの置き場に置く)
function Invoke-ElevatedScriptHere {
    param([bool]$HaveWinget)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('install-bootstrap-elevated-' + [guid]::NewGuid())
    $alias = Join-Path $root 'Microsoft/WindowsApps'
    New-Item -ItemType Directory -Force -Path $alias | Out-Null
    if ($HaveWinget) {
        # 帯 (UTF-8 の ██▒) と日本語の行を書き、受けた引数を出して 7 で終わる
        Set-Content -LiteralPath (Join-Path $alias 'winget.exe') -Value "#!/bin/sh`nprintf '  \342\226\210\342\226\210\342\226\222  1 MB / 2 MB\n'`nprintf '\343\201\202\343\201\204 ok\n'`necho `"args: `$*`"`nexit 7"
        & chmod +x (Join-Path $alias 'winget.exe')
    }
    $log = Join-Path $root "b'x.log"
    $script = Get-ElevatedWingetScript -Arguments @('install', '--id', 'Git.Git', '--scope', 'machine', "it's") -LogPath $log
    $saved = @{ LOCALAPPDATA = $env:LOCALAPPDATA; USERNAME = $env:USERNAME; PATH = $env:PATH }
    $env:LOCALAPPDATA = $root
    $env:USERNAME = 'it-admin'
    # PATH の winget は見ない (Linux の名前には .exe が付かないので、どのみち当たらない)
    try {
        $pwsh = (Get-Process -Id $PID).Path
        $null = & $pwsh -NoProfile -NonInteractive -EncodedCommand (ConvertTo-EncodedCommand -Script $script) 2>&1
        $code = $LASTEXITCODE
        $logged = @()
        if (Test-Path -LiteralPath $log) { $logged = @(Get-Content -LiteralPath $log -Encoding UTF8) }
    } finally {
        foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    "$code|$($logged -join '|')"
}
Test-Case '昇格した側の本文は、実行エイリアスの winget を引数どおりに打ち、出力を UTF-8 でログに書き (帯も書く。読む側が除く)、winget の終了コードで終わる' "7|  $([char]0x2588)$([char]0x2588)$([char]0x2592)  1 MB / 2 MB|あい ok|args: install --id Git.Git --scope machine it's" {
    Invoke-ElevatedScriptHere -HaveWinget $true
}
Test-Case '昇格した側に winget が無ければ、そのアカウントをログに書いて 2 で終わる (winget を打たない)' '2|winget が見つからない (昇格した側のアカウント: it-admin)' {
    Invoke-ElevatedScriptHere -HaveWinget $false
}
Test-Case '昇格した側の本文は Windows PowerShell 5.1 の書き方だけ (7 にしか無い書き方を使わない・構文の誤りが無い)' '0|' {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput((Get-ElevatedWingetScript -Arguments @('install') -LogPath 'C:\t.log'), [ref]$tokens, [ref]$errors)
    $bad = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
    "$(@($errors).Count)|$(@($tokens | Where-Object { "$($_.Kind)" -in $bad } | ForEach-Object { $_.Text }) -join ' ')"
}

# Get-WingetInstallArguments: 固定した版で入れる winget の引数
Test-Case 'install は版を名指しし、道具ごとの引数を後ろに足す' 'install --id Git.Git --exact --source winget --silent --accept-source-agreements --disable-interactivity --version 2.56.0.4 --accept-package-agreements --scope machine' { (Get-WingetInstallArguments -PackageId 'Git.Git' -Version '2.56.0.4' -Silent $true -Extra @('--scope', 'machine')) -join ' ' }
Test-Case '--silent を付けないとき (winget の既定の、進み具合の窓が出る形)' 'install --id GitHub.cli --exact --source winget --accept-source-agreements --disable-interactivity --version 2.103.3 --accept-package-agreements --installer-type wix' { (Get-WingetInstallArguments -PackageId 'GitHub.cli' -Version '2.103.3' -Silent $false -Extra @('--installer-type', 'wix')) -join ' ' }

# Get-BootstrapPackages: 入れる順と、道具ごとの引数。gh は -Private のときだけ、Build Tools と rustup は -Rust か -Private (-Rust を含む) の
# ときだけ。PowerShell 7 の入れ方は、普段のアカウントが管理者かで決まる
$packages = @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -Private -AccountAdmin $true)
$publicPackages = @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -AccountAdmin $true)
$rustPackages = @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -Rust -AccountAdmin $true)
$userPackages = @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -AccountAdmin $false)
Test-Case '-Private の入れる順は Git・gh・PowerShell 7・Build Tools・rustup (rustup-init が MSVC を見るので Build Tools を先に)' 'git gh pwsh vs-buildtools rustup' { ($packages | ForEach-Object { $_.Name }) -join ' ' }
# runner は dotfiles 関数が GitHub の Release から落とした exe で動くので、既定の形は Rust の道具を入れない
Test-Case '既定の形は gh も Build Tools も rustup も入れない (Git・PowerShell 7)' 'git pwsh' { ($publicPackages | ForEach-Object { $_.Name }) -join ' ' }
Test-Case '-Rust は既定の形に Build Tools と rustup を足す (Git・PowerShell 7・Build Tools・rustup。gh は入れない)' 'git pwsh vs-buildtools rustup' { ($rustPackages | ForEach-Object { $_.Name }) -join ' ' }
Test-Case '-Private に -Rust を重ねても同じ (-Private は -Rust を含む)' 'git gh pwsh vs-buildtools rustup' {
    (@(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -Private -Rust -AccountAdmin $true) | ForEach-Object { $_.Name }) -join ' '
}
# 入れ方 (Build Tools は --silent を付けず部品を名指し、rustup は MSVC の host で toolchain を入れない) は、-Rust でも -Private と変わらない
Test-Case 'Build Tools と rustup の入れ方は、-Rust でも -Private と同じ' 'True' {
    $render = { param($list) (@($list | Where-Object { $_.Name -in @('vs-buildtools', 'rustup') }) | ForEach-Object { "$($_.Name)|$($_.PackageId)|$($_.Version)|$($_.Silent)|$($_.Args -join ' ')|$($_.RetryElevated)" }) -join ';' }
    (& $render $rustPackages) -ceq (& $render $packages)
}
Test-Case '道具ごとの ID と版' 'Git.Git=2.56.0.4 GitHub.cli=2.103.3 Microsoft.PowerShell=7.6.10.0 Microsoft.VisualStudio.2022.BuildTools=17.14.44 Rustlang.Rustup=1.29.3' { ($packages | ForEach-Object { "$($_.PackageId)=$($_.Version)" }) -join ' ' }
Test-Case 'Git は machine の scope' '--scope machine' { $packages[0].Args -join ' ' }
# 昇格していない winget (入れたての Windows 11 の v1.11.510) は machine の scope の source を開けず、Git の install が 0x80070005 で落ちる
Test-Case '昇格した winget で入れ直すのは、machine の scope で入れる Git だけ' 'git=True gh=False pwsh=False vs-buildtools=False rustup=False' { ($packages | ForEach-Object { "$($_.Name)=$($_.RetryElevated)" }) -join ' ' }
Test-Case 'gh は MSI (wix)' '--installer-type wix' { $packages[1].Args -join ' ' }
# 7.6 の winget の版は MSI もあるので msix を名指しする (ユーザー単位に入り、UAC が要らない)
Test-Case '管理者の PC の PowerShell 7 は winget の MSIX' '--installer-type msix' { $packages[2].Args -join ' ' }
# 管理者でない PC は MSI (マシン単位。UAC で別の管理者のアカウントに昇格した側でも起こせる)。per-machine の MSI なので gh と同じく
# --silent を付けず、UAC で管理者の資格情報を入れる
Test-Case '管理者でない PC の PowerShell 7 は winget の MSI (wix) で、--silent を付けない' 'pwsh|--installer-type wix --custom USE_MU=0 ENABLE_MU=0|False' { "$($userPackages[1].Name)|$($userPackages[1].Args -join ' ')|$($userPackages[1].Silent)" }
# MSI の USE_MU・ENABLE_MU はどちらも既定が 1 (Microsoft Update の更新に入り、ENABLE_MU は Microsoft Update を自動更新に使う側へ入れる)
Test-Case 'PowerShell 7 の MSI は Microsoft Update の更新に入れない' 'USE_MU=0 ENABLE_MU=0' { Get-PwshMsiCustomArgument }
Test-Case 'Build Tools は C++ のワークロード・x64 の MSVC・Windows SDK を入れる' '--custom|--norestart --addProductLang En-us --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.26100' { $packages[3].Args -join '|' }
Test-Case 'rustup は MSVC の host にし、toolchain を入れない' '--custom|--default-host x86_64-pc-windows-msvc --default-toolchain none' { $packages[4].Args -join '|' }
# per-machine の MSI (gh) を、管理者でない PowerShell から quiet (--silent) で流すと UAC が出ずに落ちる。Build Tools は 10 分以上
# かかるので進み具合の窓を出す。Git は installer が自分で昇格し、PowerShell 7 の MSIX と rustup は user に入るので --silent でよい
Test-Case 'gh・Build Tools は --silent を付けない (UAC と進み具合の窓を出す)' 'git=True gh=False pwsh=True vs-buildtools=False rustup=True' { ($packages | ForEach-Object { "$($_.Name)=$($_.Silent)" }) -join ' ' }

# Get-WingetPinAddArguments: pin (pinning) と、版の範囲に留める pin (gating)
Test-Case 'pin add は版を渡さなければ pinning、渡せば gating (その範囲に留める)' 'pin add --id Git.Git --exact --accept-source-agreements --disable-interactivity|pin add --id Microsoft.PowerShell --exact --version 7.6.* --accept-source-agreements --disable-interactivity' {
    "$((Get-WingetPinAddArguments -PackageId 'Git.Git') -join ' ')|$((Get-WingetPinAddArguments -PackageId 'Microsoft.PowerShell' -Version '7.6.*') -join ' ')"
}

# ---------------------------------------------------------------------------
# clone
# ---------------------------------------------------------------------------

# Get-RepoTargets: clone する repo と置き場 (ghq の既定の root の下)
Test-Case '-Private で clone するのは dotfiles・dotfiles-private・claude-skills (ssh の URL)' 'dotfiles|git@github.com:pollenjp/dotfiles.git|C:\Users\u\ghq\github.com\pollenjp\dotfiles dotfiles-private|git@github.com:pollenjp/dotfiles-private.git|C:\Users\u\ghq\github.com\pollenjp\dotfiles-private claude-skills|git@github.com:pollenjp/claude-skills.git|C:\Users\u\ghq\github.com\pollenjp\claude-skills' {
    (Get-RepoTargets -GhqRoot 'C:\Users\u\ghq' -Private | ForEach-Object { "$($_.Name)|$($_.Url)|$($_.Directory)" }) -join ' '
}
Test-Case '既定の形で clone するのは public な dotfiles だけ (資格情報なしの HTTPS の URL)' 'dotfiles|https://github.com/pollenjp/dotfiles.git|C:\Users\u\ghq\github.com\pollenjp\dotfiles' {
    (Get-RepoTargets -GhqRoot 'C:\Users\u\ghq' | ForEach-Object { "$($_.Name)|$($_.Url)|$($_.Directory)" }) -join ' '
}

# Test-RepoOrigin: origin (設定ファイルの値) がその repo の GitHub の URL か
Test-Case 'origin: ssh の URL' 'True' { Test-RepoOrigin -Url 'git@github.com:pollenjp/dotfiles.git' -Owner 'pollenjp' -Repo 'dotfiles' }
Test-Case 'origin: https の URL (.git なし) と ssh:// の URL' 'True True' { "$(Test-RepoOrigin -Url 'https://github.com/pollenjp/dotfiles' -Owner 'pollenjp' -Repo 'dotfiles') $(Test-RepoOrigin -Url 'ssh://git@github.com/pollenjp/dotfiles.git' -Owner 'pollenjp' -Repo 'dotfiles')" }
Test-Case 'origin: 大文字小文字は問わない' 'True' { Test-RepoOrigin -Url 'git@github.com:PollenJP/Dotfiles.git' -Owner 'pollenjp' -Repo 'dotfiles' }
Test-Case 'origin: 別の owner・別の repo は偽' 'False False' { "$(Test-RepoOrigin -Url 'git@github.com:someone/dotfiles.git' -Owner 'pollenjp' -Repo 'dotfiles') $(Test-RepoOrigin -Url 'git@github.com:pollenjp/dotfiles-private.git' -Owner 'pollenjp' -Repo 'dotfiles')" }
Test-Case 'origin: 空は偽' 'False' { Test-RepoOrigin -Url '' -Owner 'pollenjp' -Repo 'dotfiles' }

# Get-GitAnonymousCloneArguments: 既定の形の clone は github.com の credential helper を空にし (Git Credential Manager を呼ばない)、HTTPS の URL のまま
Test-Case '既定の形の clone は helper を空にし、HTTPS の URL のまま clone する' '-c|credential.https://github.com.helper=|clone|-c|core.autocrlf=false|https://github.com/pollenjp/dotfiles.git|C:\Users\u\ghq\github.com\pollenjp\dotfiles' {
    (Get-GitAnonymousCloneArguments -Url 'https://github.com/pollenjp/dotfiles.git' -Directory 'C:\Users\u\ghq\github.com\pollenjp\dotfiles') -join '|'
}

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
        InstallPath = $null; MissingComponents = @(); SelfUpdateDisabled = $true; DefaultHost = $Msvc; Path = $null; OnPath = $false; Kind = $null
        NonMsix = $false
    }
    foreach ($k in $Change.Keys) { $p[$k] = $Change[$k] }
    [pscustomobject]$p
}
# PowerShell 7 の揃っている状態: PATH で先に当たる MSIX の実行エイリアスの 7.6.10 (pin は見ないので無い。MSIX でない pwsh は無い)。
# 状態は普段のアカウントが管理者の PC (New-State・New-PublicState の AccountAdmin)。$Change で差し替える
function New-PwshPackage {
    param([hashtable]$Change = @{})
    $c = @{ Installed = '7.6.10'; Pinned = $false; Path = $aliasPwsh; OnPath = $true; Kind = 'msix' }
    foreach ($k in $Change.Keys) { $c[$k] = $Change[$k] }
    New-Package 'pwsh' 'PowerShell 7' 'Microsoft.PowerShell' '7.6.10.0' $c
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
$HostFilePath = 'C:\Users\u\.config\dotfiles\host.toml'
function New-HostFile {
    param([hashtable]$Change = @{})
    $h = [ordered]@{ Path = $HostFilePath; Exists = $true; PrivateClone = $false }
    foreach ($k in $Change.Keys) { $h[$k] = $Change[$k] }
    [pscustomobject]$h
}
# -Private の形で揃っている状態 (gh とログイン・3 つの clone と、Rust の道具の Build Tools・rustup)。手元のホストの値は無い (ホストの値は
# dotfiles-private から引く)
function New-State {
    param([hashtable]$Change = @{}, [hashtable]$Git = @{}, [hashtable]$Gh = @{}, [hashtable]$Pwsh = @{}, [hashtable]$Vs = @{}, [hashtable]$Rustup = @{}, [hashtable]$Dotfiles = @{}, [hashtable]$Private = @{})
    $s = [ordered]@{
        Elevated     = $false
        AccountAdmin = $true
        Arch         = 'AMD64'
        Sac        = 'off'
        Private    = $true
        Rust       = $true
        Packages   = @(
            (New-Package 'git' 'Git for Windows' 'Git.Git' '2.56.0.4' $Git)
            (New-Package 'gh' 'GitHub CLI' 'GitHub.cli' '2.103.3' $Gh)
            (New-PwshPackage $Pwsh)
            (New-Package 'vs-buildtools' 'Visual Studio Build Tools 2022' 'Microsoft.VisualStudio.2022.BuildTools' '17.14.44' $Vs)
            (New-Package 'rustup' 'rustup' 'Rustlang.Rustup' '1.29.3' $Rustup)
        )
        GhLoggedIn = $true
        Repos      = @((New-Repo 'dotfiles' $Dotfiles), (New-Repo 'dotfiles-private' $Private), (New-Repo 'claude-skills'))
        HostFile   = (New-HostFile @{ Exists = $false; PrivateClone = $true })
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
# 既定の形 (gh なし) で揃っている状態: gh も Build Tools も rustup も読まず (Get-BootstrapState は、その形で入れる道具だけを読む)、dotfiles を
# https の URL で clone し、手元のホストの値がある。-Rust は、Build Tools と rustup も入れる・確かめる形 (-Vs と -Rustup はそのときだけ効く)
function New-PublicState {
    param([hashtable]$Change = @{}, [hashtable]$Git = @{}, [hashtable]$Pwsh = @{}, [hashtable]$Vs = @{}, [hashtable]$Rustup = @{}, [hashtable]$Dotfiles = @{}, [hashtable]$HostFile = @{}, [switch]$Rust)
    $repo = @{ Url = 'https://github.com/pollenjp/dotfiles.git'; Origin = 'https://github.com/pollenjp/dotfiles.git' }
    foreach ($k in $Dotfiles.Keys) { $repo[$k] = $Dotfiles[$k] }
    $items = @((New-Package 'git' 'Git for Windows' 'Git.Git' '2.56.0.4' $Git), (New-PwshPackage $Pwsh))
    if ($Rust) {
        $items += @(
            (New-Package 'vs-buildtools' 'Visual Studio Build Tools 2022' 'Microsoft.VisualStudio.2022.BuildTools' '17.14.44' $Vs)
            (New-Package 'rustup' 'rustup' 'Rustlang.Rustup' '1.29.3' $Rustup)
        )
    }
    $s = [ordered]@{
        Elevated     = $false
        AccountAdmin = $true
        Arch         = 'AMD64'
        Sac        = 'off'
        Private    = $false
        Rust       = [bool]$Rust
        Packages   = $items
        GhLoggedIn = $null
        Repos      = @((New-Repo 'dotfiles' $repo))
        HostFile   = (New-HostFile $HostFile)
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$fresh = @{ Exists = $false; Installed = $null; Pinned = $false }
$freshRepo = @{ State = 'missing'; Origin = $null; AutoCrlf = $null }
function New-FreshState {
    $s = New-State -Git $fresh -Gh $fresh -Pwsh $fresh -Vs $fresh -Rustup ($fresh + @{ SelfUpdateDisabled = $false; DefaultHost = $null }) -Dotfiles $freshRepo -Private $freshRepo
    $s.GhLoggedIn = $null
    $s.Repos[2] = New-Repo 'claude-skills' $freshRepo
    $s.HostFile = New-HostFile @{ Exists = $false; PrivateClone = $false }
    $s
}
# まっさらな PC の既定の形 (手元のホストの値も dotfiles-private の clone も無い)。-Rust は Build Tools と rustup も入っていない
function New-FreshPublicState {
    param([switch]$Rust)
    New-PublicState -Rust:$Rust -Git $fresh -Pwsh $fresh -Vs $fresh -Rustup ($fresh + @{ SelfUpdateDisabled = $false; DefaultHost = $null }) -Dotfiles $freshRepo -HostFile @{ Exists = $false }
}

# 行のうち、直すことがあるもの (Kind が空でない) を「ラベル=種類」で並べる
function Get-Kinds { param($State) (@(Get-BootstrapRows -State $State | Where-Object { $_.Kind }) | ForEach-Object { "$($_.Label)=$($_.Kind)" }) -join ' ' }

Test-Case '揃っていれば直すことは無い' '' { Get-Kinds (New-State) }
Test-Case 'まっさらな PC (-Private) は、入っていない・無いものだけ' 'Git for Windows=missing GitHub CLI=missing PowerShell 7=missing Visual Studio Build Tools 2022=missing rustup=missing gh のログイン=missing dotfiles=missing dotfiles-private=missing claude-skills=missing' { Get-Kinds (New-FreshState) }
Test-Case 'まっさらな PC (既定の形) は gh・Build Tools・rustup の行が無く、手元のホストの値を写す (終了コード 3)' 'Git for Windows=missing PowerShell 7=missing dotfiles=missing ホストの値 (手元)=missing|3|0' {
    $s = New-FreshPublicState
    $rows = @(Get-BootstrapRows -State $s)
    "$(Get-Kinds $s)|$(Get-BootstrapExitCode -Rows $rows)|$(@($rows | Where-Object { $_.Label -like '*Build Tools*' -or $_.Label -like 'rustup*' }).Count)"
}
Test-Case 'まっさらな PC (-Rust) は、既定の形に Build Tools と rustup の行が足される (終了コード 3)' 'Git for Windows=missing PowerShell 7=missing Visual Studio Build Tools 2022=missing rustup=missing dotfiles=missing ホストの値 (手元)=missing|3' {
    $s = New-FreshPublicState -Rust
    "$(Get-Kinds $s)|$(Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State $s))"
}
Test-Case '既定の形で揃っていれば直すことは無い' '' { Get-Kinds (New-PublicState) }
Test-Case '-Rust で揃っていれば直すことは無い' '' { Get-Kinds (New-PublicState -Rust) }
# 表の行は状態の Rust で決まる (既定の形の Get-BootstrapState は Build Tools と rustup をそもそも読まない)。Rust が偽なら、状態に Build Tools と
# rustup があっても、ずれ (版・部品・自己更新・既定の host・pin) の行を出さず、終了コードにも数えない
Test-Case '状態の Rust が偽なら、Build Tools と rustup がずれていても行を出さず終了コードは 0 (Rust が真なら出して 1)' '|0|Visual Studio Build Tools 2022=manual Build Tools の部品=fix rustup の pin=fix rustup の自己更新=fix rustup の既定の host=fix|1' {
    $off = New-PublicState -Rust -Vs @{ Installed = '17.14.40'; MissingComponents = @('Microsoft.VisualStudio.Workload.VCTools'); InstallPath = 'C:\BT' } -Rustup @{ Pinned = $false; SelfUpdateDisabled = $false; DefaultHost = $Gnu }
    $off.Rust = $false
    $on = New-PublicState -Rust -Vs @{ Installed = '17.14.40'; MissingComponents = @('Microsoft.VisualStudio.Workload.VCTools'); InstallPath = 'C:\BT' } -Rustup @{ Pinned = $false; SelfUpdateDisabled = $false; DefaultHost = $Gnu }
    "$(Get-Kinds $off)|$(Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State $off))|$(Get-Kinds $on)|$(Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State $on))"
}
# PowerShell 7 は入れ方を問わず、7.6.0 より古くなければ揃っている (固定した版と比べず、pin も見ない)
Test-Case 'PowerShell 7 は固定した版と違っても、7.6.0 より古くなければ揃っている (Microsoft Store の 7.7.0・7.6 の線の古い版)' '||' {
    "$(Get-Kinds (New-State -Pwsh @{ Installed = '7.7.0' }))|$(Get-Kinds (New-State -Pwsh @{ Installed = '7.6.0' }))|$(Get-Kinds (New-PublicState -Pwsh @{ Installed = '7.6.9' }))"
}
Test-Case 'PowerShell 7 は MSI でも PATH のほかの形でも、版が足りていれば揃っている' '|' {
    "$(Get-Kinds (New-State -Pwsh @{ Kind = 'msi'; Path = $msiPwsh }))|$(Get-Kinds (New-State -Pwsh @{ Kind = 'other'; Path = 'C:\tools\pwsh\pwsh.exe' }))"
}
Test-Case 'PowerShell 7 は pin を見ない (bootstrap が入れたときだけ足す)' '' { Get-Kinds (New-State -Pwsh @{ Pinned = $false }) }
Test-Case 'PowerShell 7 が 7.6.0 より古ければ bootstrap では直らない差' 'PowerShell 7=manual' { Get-Kinds (New-State -Pwsh @{ Installed = '7.4.13'; Kind = 'msi'; Path = $msiPwsh }) }
Test-Case 'PowerShell 7 の版が読めなければ bootstrap では直らない差' 'PowerShell 7=manual' { Get-Kinds (New-State -Pwsh @{ Installed = $null }) }
Test-Case 'PowerShell 7 が PATH の外でだけ見つかれば bootstrap では直らない差 (runner と herdr は PATH の pwsh を起こす)' 'PowerShell 7=manual' { Get-Kinds (New-State -Pwsh @{ OnPath = $false }) }
# 普段のアカウントが管理者でない PC: PowerShell 7 が MSIX でしか見つからなければ (PATH のディレクトリと MSI の置き場所に MSIX でない pwsh が
# 無ければ) 入っていないもの (流せば MSI を足す)。UAC で別の管理者のアカウントに昇格した側では、MSIX の pwsh を起こせないため
$userAdmin = @{ AccountAdmin = $false }
Test-Case '管理者でない PC で PowerShell 7 が MSIX しか無ければ、入っていないもの (流せば MSI を足す。終了コード 3)' 'PowerShell 7=missing|3' {
    $s = New-State $userAdmin
    "$(Get-Kinds $s)|$(Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State $s))"
}
Test-Case '管理者でない PC でも、MSI か PATH のほかの形の pwsh があれば揃っている (先に当たるのが MSIX でも)' '||' {
    "$(Get-Kinds (New-State $userAdmin -Pwsh @{ Kind = 'msi'; Path = $msiPwsh; NonMsix = $true }))|$(Get-Kinds (New-State $userAdmin -Pwsh @{ Kind = 'other'; Path = 'C:\tools\pwsh\pwsh.exe'; NonMsix = $true }))|$(Get-Kinds (New-State $userAdmin -Pwsh @{ NonMsix = $true }))"
}
Test-Case '管理者でない PC で MSIX しか無ければ、古くても PATH の外でも MSI を足す (MSI はマシンの PATH に入る)' 'PowerShell 7=missing|PowerShell 7=missing' {
    "$(Get-Kinds (New-State $userAdmin -Pwsh @{ Installed = '7.5.4' }))|$(Get-Kinds (New-State $userAdmin -Pwsh @{ OnPath = $false }))"
}
Test-Case '管理者でない PC のまっさらな PC も、入っていない・無いものだけ (終了コード 3)' '3' { $s = New-FreshPublicState; $s.AccountAdmin = $false; Get-BootstrapExitCode -Rows @(Get-BootstrapRows -State $s) }
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
Test-Case '-Rust の表は Build Tools と rustup の行に版を出し、既定の形の表には出さない' '  Visual Studio Build Tools 2022 : 17.14.44|  rustup : 1.29.3 (既定の host は x86_64-pc-windows-msvc)|0' {
    $l = Get-Lines (New-PublicState -Rust)
    "$(@($l | Where-Object { $_ -like '*Build Tools 2022 :*' })[0])|$(@($l | Where-Object { $_ -like '*rustup :*' })[0])|$(@(Get-Lines (New-PublicState) | Where-Object { ($_ -like '*Build Tools*') -or ($_ -like '*rustup*') }).Count)"
}
Test-Case '既定の host が読めなければ、rustup の行は読めないと出す (空のまま出さない)' '  rustup : 1.29.3 (既定の host が読めない)' { @(Get-Lines (New-State -Rustup @{ DefaultHost = $null }) | Where-Object { $_ -like '*rustup :*' })[0] }
Test-Case '入っていなければ固定した版を入れると出す' '⚠ GitHub CLI : 入っていない → 2.103.3 を入れる' { @(Get-Lines (New-State -Gh $fresh) | Where-Object { $_ -like '*GitHub CLI :*' })[0] }
Test-Case 'PowerShell 7 が入っていなければ、固定した版を winget の MSIX で入れると出す (UAC は出ない)' '⚠ PowerShell 7 : 入っていない → 7.6.10.0 を winget の MSIX で入れる (ユーザー単位。UAC は出ない)' {
    @(Get-Lines (New-State -Pwsh $fresh) | Where-Object { $_ -like '*PowerShell 7 :*' })[0]
}
Test-Case 'PowerShell 7 が古ければ、入れた形のまま上げるか、外して流し直すと ※ で出す' '⚠ PowerShell 7 : 7.4.13 (MSI) → 7.6.0 より古い|※ PowerShell 7 (C:\Program Files\PowerShell\7\pwsh.exe) が古い。入れた形のまま上げる (MSI は winget upgrade --id Microsoft.PowerShell --exact --version 7.6.10.0 --include-pinned --installer-type wix で、UAC が出る。Microsoft Store の MSIX は Store のライブラリで更新する) か、外してから流し直す (winget の MSIX で 7.6.10.0 を入れる)' {
    $l = Get-Lines (New-State -Pwsh @{ Installed = '7.4.13'; Kind = 'msi'; Path = $msiPwsh }); "$(@($l | Where-Object { $_ -like '*PowerShell 7 :*' })[0])|$(@($l | Where-Object { $_ -like '※*' })[0])"
}
Test-Case 'PowerShell 7 が PATH の外でだけ見つかれば、ディレクトリを Path に足すと ※ で出す' "⚠ PowerShell 7 : 7.6.10 (MSIX) → PATH に無い|※ PowerShell 7 ($aliasPwsh) のディレクトリが PATH に無い (runner と herdr は PATH の pwsh を起こす)。ユーザーの環境変数 Path に足す" {
    $l = Get-Lines (New-State -Pwsh @{ OnPath = $false }); "$(@($l | Where-Object { $_ -like '*PowerShell 7 :*' })[0])|$(@($l | Where-Object { $_ -like '※*' })[0])"
}
# 管理者でない PC の PowerShell 7 の行: 入れるのは MSI で、わけ (昇格した側で MSIX の pwsh を起こせない) を ※ で出す
$msiNote = '※ 普段のアカウントが管理者でない PC では、UAC で別の管理者のアカウントの資格情報を入れて昇格する。MSIX の PowerShell 7 は使う人ごとに登録されるので、昇格した側 (そのアカウント) では起こせず、Install-OpenSSH・Install-Sshd が自分を昇格し直せない。MSI はマシン単位に入り、どのアカウントからも起こせる (win/README.md の「PowerShell 7 の MSIX の限り」)'
Test-Case '管理者でない PC で PowerShell 7 が入っていなければ、winget の MSI で入れると出し、わけを ※ で出す' "⚠ PowerShell 7 : 入っていない → 7.6.10.0 を winget の MSI で入れる (管理者でない PC。マシン単位に入り、UAC で管理者の資格情報を入れる)|$msiNote" {
    $l = Get-Lines (New-State $userAdmin -Pwsh $fresh); "$(@($l | Where-Object { $_ -like '*PowerShell 7 :*' })[0])|$(@($l | Where-Object { $_ -like '※*' })[0])"
}
Test-Case '管理者でない PC で MSIX しか無ければ、見つかった版と入れ方・MSI も入れることを出し、わけを ※ で出す' "⚠ PowerShell 7 : 7.6.10 (MSIX) → 管理者でない PC なので、MSI の 7.6.10.0 も入れる (UAC で管理者の資格情報を入れる)|$msiNote" {
    $l = Get-Lines (New-State $userAdmin); "$(@($l | Where-Object { $_ -like '*PowerShell 7 :*' })[0])|$(@($l | Where-Object { $_ -like '※*' })[0])"
}
Test-Case '管理者でない PC で MSIX の版が読めなくても、MSI を足すと出す' '⚠ PowerShell 7 : 版が読めない (MSIX) → 管理者でない PC なので、MSI の 7.6.10.0 も入れる (UAC で管理者の資格情報を入れる)' {
    @(Get-Lines (New-State $userAdmin -Pwsh @{ Installed = $null }) | Where-Object { $_ -like '*PowerShell 7 :*' })[0]
}
Test-Case '管理者でない PC で MSI が古ければ、外してから流し直すと MSI で入ると ※ で出す' '※ PowerShell 7 (C:\Program Files\PowerShell\7\pwsh.exe) が古い。入れた形のまま上げる (MSI は winget upgrade --id Microsoft.PowerShell --exact --version 7.6.10.0 --include-pinned --installer-type wix で、UAC が出る。Microsoft Store の MSIX は Store のライブラリで更新する) か、外してから流し直す (winget の MSI で 7.6.10.0 を入れる)' {
    @(Get-Lines (New-State $userAdmin -Pwsh @{ Installed = '7.4.13'; Kind = 'msi'; Path = $msiPwsh; NonMsix = $true }) | Where-Object { $_ -like '※*' })[0]
}
Test-Case '管理者でない PC で MSI があれば、行は版と入れ方だけ' '  PowerShell 7 : 7.6.10 (MSI)' {
    @(Get-Lines (New-State $userAdmin -Pwsh @{ Kind = 'msi'; Path = $msiPwsh; NonMsix = $true }) | Where-Object { $_ -like '*PowerShell 7 :*' })[0]
}
Test-Case '版のずれは ※ で上げ方と下げ方を出す' '⚠ Git for Windows : 2.55.0.5 (固定した版は 2.56.0.4)|※ Git for Windows を固定した版に揃えるのは bootstrap ではしない。上げるなら winget upgrade --id Git.Git --exact --version 2.56.0.4 --include-pinned、下げるなら winget uninstall --id Git.Git の後に流し直す' {
    $l = Get-Lines (New-State -Git @{ Installed = '2.55.0.5' }); "$(@($l | Where-Object { $_ -like '*Git for Windows :*' })[0])|$(@($l | Where-Object { $_ -like '※*' })[0])"
}
Test-Case 'rustup の上げ方には MSVC の host と toolchain を入れない引数を添える' '※ rustup を固定した版に揃えるのは bootstrap ではしない。上げるなら winget upgrade --id Rustlang.Rustup --exact --version 1.29.3 --include-pinned --custom "--default-host x86_64-pc-windows-msvc --default-toolchain none"、下げるなら winget uninstall --id Rustlang.Rustup の後に流し直す' {
    @(Get-Lines (New-State -Rustup @{ Installed = '1.28.2' }) | Where-Object { $_ -like '※*' })[0]
}
# 版を名指しした winget upgrade は、--include-pinned が無いと bootstrap が足した pin (Pinning) に止められる (0x8A150068。
# 2026-11-16 に example-host の OpenSSH で起きた形)。版を揃える 4 つの道具のどれの上げ方にも付ける (PowerShell 7 は版を揃えない)
Test-Case '版を揃える 4 つの道具の上げ方は、どれも bootstrap が足した pin を越える (--include-pinned)' 'Git.Git=True GitHub.cli=True Microsoft.VisualStudio.2022.BuildTools=True Rustlang.Rustup=True' {
    $s = New-State -Git @{ Installed = '2.55.0.5' } -Gh @{ Installed = '2.100.0' } -Pwsh @{ Installed = '7.6.9' } -Vs @{ Installed = '17.14.40' } -Rustup @{ Installed = '1.28.2' }
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
# SAC は出どころによらず、評判も署名も無い exe を止める (GitHub の Release から落とした runner の exe も、cargo の産物も)
Test-Case 'SAC がオンなら、オフにする場所と戻せないことがあるのを ※ で出す' '⚠ Smart App Control : オン → オフにする (runner の exe (配った exe も cargo の産物も) が止められて動かない)|※ Smart App Control は、Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 でオフにする (Windows によっては、戻すのに再インストールが要る)' {
    $l = Get-Lines (New-State @{ Sac = 'on' }); "$(@($l | Where-Object { $_ -like '*Smart App Control :*' })[0])|$(@($l | Where-Object { $_ -like '※*' })[0])"
}
Test-Case 'clone が無ければ置き場を出す' "⚠ dotfiles : 無い → $Ghq\dotfiles に clone する" { @(Get-Lines (New-State -Dotfiles $freshRepo) | Where-Object { $_ -like '*dotfiles :*' })[0] }
Test-Case 'PowerShell 7 の行は版と入れ方を出す (MSIX・MSI。ほかの形はパス)' '  PowerShell 7 : 7.6.10 (MSIX)|  PowerShell 7 : 7.7.0 (MSI)|  PowerShell 7 : 7.6.10 (C:\tools\pwsh\pwsh.exe)' {
    $states = @((New-State), (New-State -Pwsh @{ Installed = '7.7.0'; Kind = 'msi'; Path = $msiPwsh }), (New-State -Pwsh @{ Kind = 'other'; Path = 'C:\tools\pwsh\pwsh.exe' }))
    (@($states | ForEach-Object { @(Get-Lines $_ | Where-Object { $_ -like '*PowerShell 7 :*' })[0] })) -join '|'
}
Test-Case '既定の形は gh の行を出さない' '0' { @(Get-Lines (New-PublicState) | Where-Object { $_ -like '*gh のログイン*' }).Count }
Test-Case '-Private は手元のホストの値の行を出さない' '0' { @(Get-Lines (New-State) | Where-Object { $_ -like '*ホストの値 (手元)*' }).Count }
Test-Case '既定の形で手元のホストの値があれば、置き場を出す' "  ホストの値 (手元) : $HostFilePath" { @(Get-Lines (New-PublicState) | Where-Object { $_ -like '*ホストの値 (手元)*' })[0] }
Test-Case '既定の形で dotfiles-private の clone があれば、雛形を写さない (直すことは無い)' '  ホストの値 (手元) : 写さない (dotfiles-private の clone がある。ホストの値はそこから引く)' {
    @(Get-Lines (New-PublicState -HostFile @{ Exists = $false; PrivateClone = $true }) | Where-Object { $_ -like '*ホストの値 (手元)*' })[0]
}
Test-Case '既定の形で手元のホストの値が無ければ、雛形を写すと出す' "⚠ ホストの値 (手元) : 無い → 雛形 (win\templates\host.minimum.toml) を $HostFilePath に写す" {
    @(Get-Lines (New-PublicState -HostFile @{ Exists = $false }) | Where-Object { $_ -like '*ホストの値 (手元)*' })[0]
}

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

# Format-BootstrapNextSteps: 揃え終えたときに出す、次に打つコマンド (clone の dotfiles.ps1 を読み込んで dotfiles apply) とホストの値の行。
# 既定の形 (と -Rust) は、初めての dotfiles apply が runner の exe を GitHub の Release から落とすことも添える
$nextDir = 'C:\Users\u\ghq\github.com\pollenjp\dotfiles'
$runnerExeLine = '初めての dotfiles apply は、runner の exe を GitHub の Release から落とす (github.com と release-assets.githubusercontent.com に届くこと)'
Test-Case '次に打つのは、PowerShell 7 の新しい窓で dotfiles.ps1 を読み込んで dotfiles apply (既定の形は runner の exe を落とすことと手元のホストの値を出す)' "|次に打つ (PowerShell 7 の新しい窓で。この窓は PATH が古い):|  . '$nextDir\win\powershell\dotfiles.ps1'|  dotfiles apply|$runnerExeLine|ホストの値は $HostFilePath (minimum の雛形を写したもの)。使う道具は [tools] に 1 行ずつ足す (書き方は dotfiles の win\README.md の「ホストの値」)" {
    (@(Format-BootstrapNextSteps -DotfilesDir $nextDir -HostFile $HostFilePath -HostFileExists $true) | ForEach-Object { "$_" }) -join '|'
}
Test-Case '-Private は dotfiles-private のホストの値を出し、手元のホストの値があれば両方で止まることを足す' 'ホストの値は dotfiles-private の win\hosts\<ユーザー>@<PC>.toml。無ければ dotfiles check が ⚠ を出し、apply は止まる (先に書く。書き方は dotfiles の win\README.md の「ホストの値」)|False|True' {
    $plain = @(Format-BootstrapNextSteps -DotfilesDir $nextDir -Private -HostFile $HostFilePath -HostFileExists $false)
    $both = @(Format-BootstrapNextSteps -DotfilesDir $nextDir -Private -HostFile $HostFilePath -HostFileExists $true)
    "$($plain[-1])|$(@($plain | Where-Object { $_ -like '※*' }).Count -gt 0)|$("$($both[-1])".StartsWith("※ 手元のホストの値 ($HostFilePath) もある。"))"
}
Test-Case '置き場の一重引用符は重ねる (空白と一緒に、PowerShell にそのまま打てる形)' "  . 'C:\Users\o''brien x\ghq\github.com\pollenjp\dotfiles\win\powershell\dotfiles.ps1'" {
    @(Format-BootstrapNextSteps -DotfilesDir "C:\Users\o'brien x\ghq\github.com\pollenjp\dotfiles" -HostFile $HostFilePath -HostFileExists $true)[2]
}

# Format-SacWarning: 最初に出す SAC の警告 (オフでなければ出し、bootstrap は続ける)
$sacWhere = '   オフにする場所: Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 (Windows によっては、戻すのに再インストールが要る)'
Test-Case 'SAC がオフなら警告しない' '' { (@(Format-SacWarning -Sac 'off') | ForEach-Object { "$_" }) -join '|' }
Test-Case 'SAC の無い Windows は警告しない' '' { (@(Format-SacWarning -Sac 'unavailable') | ForEach-Object { "$_" }) -join '|' }
# 配った runner の exe (GitHub の Release から落とす) も cargo の産物も、評判も署名も無いので SAC に止められる
Test-Case 'SAC がオンなら、runner の exe (配った exe も cargo の産物も) が止められるので、Rust の runner を流す前にオフにするよう警告して続ける' "⚠️ Smart App Control がオンになっている。runner の exe (配った exe も cargo の産物も) は止められて動かないので、Rust の runner を流す前にオフにする (bootstrap はこのまま続ける)|$sacWhere" { (@(Format-SacWarning -Sac 'on') | ForEach-Object { "$_" }) -join '|' }
Test-Case 'SAC が評価モードなら、オンになると runner の exe (配った exe も cargo の産物も) が止められるので、オフにしておくよう警告して続ける' "⚠️ Smart App Control が評価モードになっている。いつオンに変わるか分からず、オンになると runner の exe (配った exe も cargo の産物も) が止められるので、オフにしておく (bootstrap はこのまま続ける)|$sacWhere" { (@(Format-SacWarning -Sac 'eval') | ForEach-Object { "$_" }) -join '|' }

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

# Invoke-Winget (本物): winget は管へ UTF-8 で書く。コンソールの文字コードが UTF-8 でない窓 (日本語の Windows の既定の CP932。ここでは
# ISO-8859-1 で代える) でも、打つ間だけ UTF-8 で読み、帯 (█▒) の行を除いて日本語を化けさせない (CP932 で読むと「笆遺毎」になり、帯も
# 除けない)。打った後は元の文字コードに戻す。偽の winget を PATH の先頭に置く (Linux)
Test-Case 'winget の出力は UTF-8 で読み (帯を除き、日本語は化けない)、終わったらコンソールの文字コードを戻す' '7|あい ok|28591' {
    $bin = Join-Path ([IO.Path]::GetTempPath()) ('install-bootstrap-winget-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $bin | Out-Null
    Set-Content -LiteralPath (Join-Path $bin 'winget') -Value "#!/bin/sh`nprintf '  \342\226\210\342\226\210\342\226\222  1 MB / 2 MB\n'`nprintf '\343\201\202\343\201\204 ok\n'`nexit 7"
    & chmod +x (Join-Path $bin 'winget')
    $savedPath = $env:PATH
    $savedEncoding = [Console]::OutputEncoding
    $env:PATH = "$bin$([IO.Path]::PathSeparator)$savedPath"
    try {
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding('ISO-8859-1')
        $r = Invoke-Winget -Arguments @('install')
        $after = [Console]::OutputEncoding.CodePage
    } finally {
        [Console]::OutputEncoding = $savedEncoding
        $env:PATH = $savedPath
        Remove-Item -LiteralPath $bin -Recurse -Force
    }
    "$($r.ExitCode)|$($r.Lines -join '|')|$after"
}

# ---------------------------------------------------------------------------
# 状態を読む (本物の Get-BootstrapState。Windows に触る一番下の関数だけを偽物にし、道具の置き場所は一時ディレクトリの空のファイル)
# ---------------------------------------------------------------------------

$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('install-bootstrap-tests-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $stateRoot | Out-Null
foreach ($f in @('git.exe', 'gh.exe', 'pwsh.exe', 'rustup.exe')) { Set-Content -LiteralPath (Join-Path $stateRoot $f) -Value '' }
# PATH のディレクトリと、MSIX の実行エイリアスの置き場にも pwsh.exe を置く (MSI の置き場所は上の $stateRoot の pwsh.exe)
foreach ($d in @('path-dir', 'WindowsApps')) {
    New-Item -ItemType Directory -Path (Join-Path $stateRoot $d) | Out-Null
    Set-Content -LiteralPath (Join-Path (Join-Path $stateRoot $d) 'pwsh.exe') -Value ''
}
# settings.toml の既定の host は GNU のまま。rustup show が MSVC を出せば、host は rustup show から読んでいる
Set-Content -LiteralPath (Join-Path $stateRoot 'settings.toml') -Value "version = `"12`"`ndefault_host_tuple = `"x86_64-pc-windows-gnu`"`nauto_self_update = `"disable`"`n"
# MSIX の実行エイリアスは Windows の字 (\WindowsApps\) で渡す (入れ方を WindowsApps の下かで決めるので)
$statePaths = [pscustomobject]@{
    Git = (Join-Path $stateRoot 'git.exe'); Gh = (Join-Path $stateRoot 'gh.exe'); Pwsh = (Join-Path $stateRoot 'pwsh.exe'); Rustup = (Join-Path $stateRoot 'rustup.exe')
    PwshAlias = "$stateRoot\WindowsApps\pwsh.exe"
    RustupSettings = (Join-Path $stateRoot 'settings.toml'); VsWhere = (Join-Path $stateRoot 'vswhere.exe'); VsSetup = (Join-Path $stateRoot 'setup.exe')
    GhqRoot = (Join-Path $stateRoot 'ghq'); HostFile = (Join-Path $stateRoot 'host.toml')
}
# 新しい窓の PATH (レジストリのマシン → ユーザーの Path) の偽物。Windows の字 (\ でつなぐ) のまま渡す (Linux の pwsh も \ を区切りとして読む)
$script:RegistryPath = "$stateRoot\path-dir"
function Get-RegistryPathValue { $script:RegistryPath }
# 手元のホストの値はある。dotfiles-private の clone は無い
Set-Content -LiteralPath $statePaths.HostFile -Value 'group = "minimum"'
$script:NativeLog = [System.Collections.Generic.List[string]]::new()
# MSVC とワークロードはあるが、SDK は版の付かない UCRT だけの Build Tools 2022
$script:VsJson = '[{"productId":"Microsoft.VisualStudio.Product.BuildTools","installationPath":"C:\\BT","catalog":{"productDisplayVersion":"17.14.44"},"packages":[{"id":"Microsoft.VisualStudio.Workload.VCTools","type":"Workload"},{"id":"Microsoft.VisualStudio.Component.VC.Tools.x86.x64","type":"Component"},{"id":"Microsoft.VisualStudio.Component.Windows10SDK","type":"Component"}]}]'
function Test-Elevated { $false }
function Get-BootstrapSac { 'off' }
# vswhere を読んだ回数も数える (既定の形は Build Tools を読まない)
$script:VsWhereReads = 0
function Read-VsWhere { param([string]$VsWhere) $script:VsWhereReads++; $script:VsJson }
# winget は打った引数を書き留め、pin list には Id の列を持つ行を返す (pin がある)
$script:WingetLog = [System.Collections.Generic.List[string]]::new()
function Invoke-Winget { param([string[]]$Arguments) $script:WingetLog.Add($Arguments -join ' '); [pscustomobject]@{ ExitCode = 0; Lines = @("x $($Arguments[3])") } }
# 打ったものを「exe 引数 [打ったときの RUSTUP_AUTO_INSTALL]」で書き留め、道具ごとの出力を返す
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Utf8)
    $leaf = Split-Path -Leaf $FilePath
    $script:NativeLog.Add("$leaf $($Arguments -join ' ') [RUSTUP_AUTO_INSTALL=$($env:RUSTUP_AUTO_INSTALL)]")
    $lines = @()
    switch ("$leaf $($Arguments -join ' ')") {
        'git.exe --version' { $lines = @('git version 2.56.0.windows.4') }
        'gh.exe --version' { $lines = @('gh version 2.103.3 (2026-10-26)') }
        'pwsh.exe --version' { $lines = @('PowerShell 7.6.10') }
        'rustup.exe --version' { $lines = @('rustup 1.29.3 (8c9a7b0c1 2026-11-03)') }
        'rustup.exe show' { $lines = @('Default host: x86_64-pc-windows-msvc', 'rustup home:  C:\Users\u\.rustup', '', 'no active toolchain') }
    }
    [pscustomobject]@{ ExitCode = 0; Lines = $lines }
}
# gh を使わずに Rust の道具も読む形 (-Rust)。Build Tools と rustup の読み方を見る
$statePackages = @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -Rust -AccountAdmin $false)
$env:RUSTUP_AUTO_INSTALL = 'keep'
try {
    $readState = Get-BootstrapState -Packages $statePackages -Paths $statePaths -Arch 'AMD64' -Rust -AccountAdmin $false
    $afterEnv = $env:RUSTUP_AUTO_INSTALL
    $readNative = @($script:NativeLog)
    $readWinget = @($script:WingetLog)
    # 既定の形 (-Rust なし) は、Build Tools と rustup を読まない (vswhere も rustup も打たず、その pin も見ない)
    $script:NativeLog.Clear()
    $script:WingetLog.Clear()
    $script:VsWhereReads = 0
    $defaultState = Get-BootstrapState -Packages @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -AccountAdmin $false) -Paths $statePaths -Arch 'AMD64' -AccountAdmin $false
    $defaultNative = @($script:NativeLog)
    $defaultWinget = @($script:WingetLog)
    $defaultVsWhereReads = $script:VsWhereReads
    # -Private は -Rust を含む (状態の Rust は真)
    $privateState = Get-BootstrapState -Packages @(Get-BootstrapPackages -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -Private -AccountAdmin $false) -Paths $statePaths -Arch 'AMD64' -Private -AccountAdmin $false
    # PATH に pwsh が無ければ MSI の置き場所、それも無ければ MSIX の実行エイリアスを読む (どちらも PATH の外)。どれも無ければ入っていない
    $script:RegistryPath = ''
    $msiRead = @((Get-BootstrapState -Packages $statePackages -Paths $statePaths -Arch 'AMD64' -AccountAdmin $true).Packages | Where-Object { $_.Name -eq 'pwsh' })[0]
    Remove-Item -LiteralPath $statePaths.Pwsh
    $aliasRead = @((Get-BootstrapState -Packages $statePackages -Paths $statePaths -Arch 'AMD64' -AccountAdmin $true).Packages | Where-Object { $_.Name -eq 'pwsh' })[0]
    # MSIX の実行エイリアスのディレクトリ (ユーザーの PATH の既定の項目) が PATH にあり、MSI が無い
    $script:RegistryPath = "$stateRoot\WindowsApps"
    $aliasOnPathRead = @((Get-BootstrapState -Packages $statePackages -Paths $statePaths -Arch 'AMD64' -AccountAdmin $true).Packages | Where-Object { $_.Name -eq 'pwsh' })[0]
    Remove-Item -LiteralPath $statePaths.PwshAlias
    $noneRead = @((Get-BootstrapState -Packages $statePackages -Paths $statePaths -Arch 'AMD64' -AccountAdmin $true).Packages | Where-Object { $_.Name -eq 'pwsh' })[0]
} finally {
    $env:RUSTUP_AUTO_INSTALL = $null
    Remove-Item -LiteralPath $stateRoot -Recurse -Force
}
$readRustup = @($readState.Packages | Where-Object { $_.Name -eq 'rustup' })[0]
$readVs = @($readState.Packages | Where-Object { $_.Name -eq 'vs-buildtools' })[0]
$readPwsh = @($readState.Packages | Where-Object { $_.Name -eq 'pwsh' })[0]

# rustup 1.29.3 は --version・show でも、cwd の rust-toolchain.toml の入っていない toolchain を入れにいく。-Check は何も変えない
Test-Case 'rustup は --version も show も RUSTUP_AUTO_INSTALL=0 で打つ (toolchain を入れさせない)' 'rustup.exe --version [RUSTUP_AUTO_INSTALL=0]|rustup.exe show [RUSTUP_AUTO_INSTALL=0]' {
    @($readNative | Where-Object { $_ -like 'rustup.exe *' }) -join '|'
}
Test-Case '打った後は RUSTUP_AUTO_INSTALL を元の値に戻す' 'keep' { $afterEnv }
Test-Case '既定の host は rustup show から読む (settings.toml の default_host_tuple は読まない)' 'x86_64-pc-windows-msvc|1.29.3|True' { "$($readRustup.DefaultHost)|$($readRustup.Installed)|$($readRustup.SelfUpdateDisabled)" }
Test-Case 'PowerShell 7 は新しい窓の PATH で先に当たる pwsh を読む (版は pwsh --version)' "True|7.6.10|$stateRoot\path-dir\pwsh.exe|True" {
    "$($readPwsh.Exists)|$($readPwsh.Installed)|$($readPwsh.Path)|$($readPwsh.OnPath)"
}
Test-Case 'pin を読むのは PowerShell 7 のほかの道具だけ (PowerShell 7 の pin は見ない)' 'Git.Git Microsoft.VisualStudio.2022.BuildTools Rustlang.Rustup' {
    (@($readWinget | Where-Object { $_ -like 'pin list *' }) | ForEach-Object { ($_ -split ' ')[3] }) -join ' '
}
Test-Case 'PATH に無ければ MSI の置き場所、それも無ければ MSIX の実行エイリアスを読み (どちらも PATH の外)、どれも無ければ入っていない' "$($statePaths.Pwsh)=False|$($statePaths.PwshAlias)=False|False" {
    "$($msiRead.Path)=$($msiRead.OnPath)|$($aliasRead.Path)=$($aliasRead.OnPath)|$($noneRead.Exists)"
}
# NonMsix: PATH のディレクトリと MSI の置き場所に、MSIX でない pwsh があるか (管理者でない PC は、無ければ MSI を足す)。先に当たる pwsh が
# MSIX でも、後ろに MSIX でない pwsh があれば True
Test-Case 'MSIX でない pwsh は PATH のほかの形・MSI の置き場所で見つけ、MSIX (実行エイリアス。PATH にあっても) だけなら無い' 'other=True|msi=True|msix=False|msix=False|=False' {
    (@($readPwsh, $msiRead, $aliasRead, $aliasOnPathRead, $noneRead) | ForEach-Object { "$($_.Kind)=$($_.NonMsix)" }) -join '|'
}
Test-Case 'PATH にある実行エイリアスは PATH の中として読む' 'True' { $aliasOnPathRead.OnPath }
Test-Case '状態には、普段のアカウントが管理者かを渡されたまま持つ' 'False' { $readState.AccountAdmin }
Test-Case '-Rust (gh を使わない形) は gh を読まず (auth status も打たない)、手元のホストの値と dotfiles-private の clone の有無を読む' 'False|False|True|False' {
    "$($readState.Private)|$(@($readNative | Where-Object { $_ -like 'gh.exe *' }).Count -gt 0)|$($readState.HostFile.Exists)|$($readState.HostFile.PrivateClone)"
}
Test-Case 'Build Tools は vswhere から版・置き場所・足りないもの (版の付いた SDK) を読む' 'True|17.14.44|C:\BT|Microsoft.VisualStudio.Component.Windows11SDK.26100' {
    "$($readVs.Exists)|$($readVs.Installed)|$($readVs.InstallPath)|$(@($readVs.MissingComponents) -join ',')"
}
# 既定の形の runner は配った exe で動くので、Build Tools と rustup は確かめもしない (表の行も出ない)
Test-Case '既定の形は Build Tools と rustup を読まない (vswhere も rustup も gh も打たず、pin は Git のものだけ見る)' 'git pwsh|0|0|0|Git.Git' {
    "$((@($defaultState.Packages) | ForEach-Object { $_.Name }) -join ' ')|$defaultVsWhereReads|$(@($defaultNative | Where-Object { $_ -like 'rustup.exe *' }).Count)|$(@($defaultNative | Where-Object { $_ -like 'gh.exe *' }).Count)|$((@($defaultWinget | Where-Object { $_ -like 'pin list *' }) | ForEach-Object { ($_ -split ' ')[3] }) -join ' ')"
}
Test-Case '状態の Rust は、Rust の道具を入れる形 (-Rust・-Private) のときだけ真 (既定・-Rust・-Private の順)' 'False|True|True' {
    "$($defaultState.Rust)|$($readState.Rust)|$($privateState.Rust)"
}

# ---------------------------------------------------------------------------
# 流れ (Windows に触る関数を偽物に差し替える。ここより後ろは、上の関数のテストに戻らない)
# ---------------------------------------------------------------------------

# 呼んだものを $script:Calls に「何を・どれに」で書き留める偽物
function Test-WingetAvailable { $script:HaveWinget }
function Get-OsArchitecture { 'AMD64' }
# 普段のアカウントが管理者か (流れの最初の状態の AccountAdmin と同じ値にする)
function Test-AccountAdmin { $script:AccountAdmin }
function Get-BootstrapSac { $script:Sac }
function Get-BootstrapPaths {
    [pscustomobject]@{
        Git = 'C:\Program Files\Git\cmd\git.exe'; Gh = 'C:\Program Files\GitHub CLI\gh.exe'; Pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
        PwshAlias = $aliasPwsh
        Rustup = 'C:\Users\u\.cargo\bin\rustup.exe'; RustupSettings = 'C:\Users\u\.rustup\settings.toml'; VsWhere = 'C:\vswhere.exe'
        VsSetup = 'C:\setup.exe'; GhqRoot = 'C:\Users\u\ghq'; HostFile = $HostFilePath
    }
}
function Invoke-Winget {
    param([string[]]$Arguments)
    $id = $Arguments[[array]::IndexOf($Arguments, '--id') + 1]
    $verb = $Arguments[0]
    # 版の範囲に留める pin (gating) は「pin-add <Id> <範囲>」
    $range = ''
    if (($verb -eq 'pin') -and ($Arguments -contains '--version')) { $range = " $($Arguments[[array]::IndexOf($Arguments, '--version') + 1])" }
    if ($verb -eq 'pin') { $verb = "pin-$($Arguments[1])" }
    if (($verb -eq 'install') -and ($Arguments -notcontains '--silent')) { $verb = 'install-with-progress' }
    # PowerShell 7 を入れた引数は全部控える (MSIX か MSI か・--silent の有無を見る)
    if (($Arguments[0] -eq 'install') -and ($id -eq 'Microsoft.PowerShell')) { $script:PwshInstallArgs = $Arguments -join ' ' }
    $script:Calls.Add("$verb $id$range")
    $code = 0
    if ($script:Fail.ContainsKey("$verb $id")) { $code = $script:Fail["$verb $id"] }
    $lines = @()
    if ($script:FailLines.ContainsKey("$verb $id")) { $lines = @($script:FailLines["$verb $id"]) }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
# 昇格した winget は「install-elevated <Id>」。終了コードと行は Fail・FailLines の同じ名前で決める
function Invoke-ElevatedWinget {
    param([string[]]$Arguments)
    $id = $Arguments[[array]::IndexOf($Arguments, '--id') + 1]
    $script:Calls.Add("install-elevated $id")
    $script:ElevatedArgs = $Arguments -join ' '
    $code = 0
    if ($script:Fail.ContainsKey("install-elevated $id")) { $code = $script:Fail["install-elevated $id"] }
    $lines = @()
    if ($script:FailLines.ContainsKey("install-elevated $id")) { $lines = @($script:FailLines["install-elevated $id"]) }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Utf8)
    $script:Calls.Add("native $($Arguments -join ' ')")
    [pscustomobject]@{ ExitCode = 0; Lines = @() }
}
# gh の資格情報で通す clone は「clone <名前>」、資格情報なしの clone (既定の形) は「clone-anon <名前>」
function Invoke-GitClone {
    param([string]$GitPath, [string[]]$Arguments)
    $verb = 'clone-anon'
    if (@($Arguments | Where-Object { "$_" -like '*auth git-credential' }).Count -gt 0) { $verb = 'clone' }
    $script:Calls.Add("$verb $($Arguments[-1] -replace '^.*\\', '')")
    [pscustomobject]@{ ExitCode = 0; Lines = @() }
}
function Copy-HostTemplate {
    param([string]$Template, [string]$Destination)
    $script:Calls.Add("copy-template $($Template -replace '^.*\\pollenjp\\', '') -> $Destination")
    'copied'
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
    param([object[]]$Packages, $Paths, [string]$Arch, [switch]$Private)
    if ($script:States.Count -gt 1) { return $script:States.Dequeue() }
    $script:States.Peek()
}

# 流れを流す。-Public $true は既定の形 (gh なし)、ほかは -Private の形 (状態は New-State・New-FreshState の -Private の形)。-Rust $true は、
# 既定の形に -Rust を付ける (状態は New-PublicState -Rust の形)
function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [hashtable]$Fail = @{}, [hashtable]$FailLines = @{}, [int]$LoginCode = 0, [bool]$Winget = $true, [bool]$Public = $false, [bool]$Rust = $false)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:FailLines = $FailLines
    $script:LoginCode = $LoginCode
    $script:HaveWinget = $Winget
    $script:PwshInstallArgs = ''
    # 最初に確かめる SAC と、普段のアカウントが管理者かは、最初の状態と同じ値にする
    $script:Sac = $States[0].Sac
    $script:AccountAdmin = [bool]$States[0].AccountAdmin
    $out = @(Invoke-InstallBootstrap -GitVersion '2.56.0.4' -GhVersion '2.103.3' -PwshVersion '7.6.10.0' -VsBuildToolsVersion '17.14.44' -RustupVersion '1.29.3' -Rust:$Rust -Private:(-not $Public) -Check:$Check 6>&1)
    [pscustomobject]@{
        Calls    = ($script:Calls -join ' | ')
        Text     = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code     = @($out | Where-Object { $_ -is [int] })[-1]
        PwshArgs = $script:PwshInstallArgs
    }
}

# 道具が入ったが、pin が無く、rustup の自己更新が止まっておらず、gh はログインしていない・clone は無い状態 (入れた直後)
function New-InstalledState {
    $s = New-State -Git @{ Pinned = $false } -Gh @{ Pinned = $false } -Pwsh @{ Pinned = $false } -Vs @{ Pinned = $false } -Rustup @{ Pinned = $false; SelfUpdateDisabled = $false } -Dotfiles $freshRepo -Private $freshRepo
    $s.GhLoggedIn = $false
    $s.Repos[2] = New-Repo 'claude-skills' $freshRepo
    $s
}
function New-LoggedInState {
    $s = New-State -Dotfiles $freshRepo -Private $freshRepo
    $s.Repos[2] = New-Repo 'claude-skills' $freshRepo
    $s
}
# PowerShell 7 は MSIX を --silent で入れ、入れた直後に 7.6 の線に留める pin を足す (後の pin の段では足さない)
$freshCalls = 'install Git.Git | install-with-progress GitHub.cli | install Microsoft.PowerShell | pin-add Microsoft.PowerShell 7.6.* | install-with-progress Microsoft.VisualStudio.2022.BuildTools | install Rustlang.Rustup | pin-add Git.Git | pin-add GitHub.cli | pin-add Microsoft.VisualStudio.2022.BuildTools | pin-add Rustlang.Rustup | native set auto-self-update disable | gh-login | clone dotfiles | clone dotfiles-private | clone claude-skills'
# 既定の形の、道具が入ったが pin が無く、clone も手元のホストの値も無い状態 (入れた直後)。-Rust は Build Tools と rustup も入ったが、pin が無く、
# rustup の自己更新が止まっていない
function New-PublicInstalledState {
    param([switch]$Rust)
    New-PublicState -Rust:$Rust -Git @{ Pinned = $false } -Pwsh @{ Pinned = $false } -Vs @{ Pinned = $false } -Rustup @{ Pinned = $false; SelfUpdateDisabled = $false } -Dotfiles $freshRepo -HostFile @{ Exists = $false }
}
# 既定の形は Git と PowerShell 7 だけを入れる (Build Tools と rustup は入れず、rustup の設定もしない)
$freshPublicCalls = 'install Git.Git | install Microsoft.PowerShell | pin-add Microsoft.PowerShell 7.6.* | pin-add Git.Git | clone-anon dotfiles | copy-template dotfiles\win\templates\host.minimum.toml -> C:\Users\u\.config\dotfiles\host.toml'
# -Rust は、既定の形に Build Tools と rustup を足す (入れる順と入れ方は -Private と同じ。Build Tools を rustup より先に)
$freshRustCalls = 'install Git.Git | install Microsoft.PowerShell | pin-add Microsoft.PowerShell 7.6.* | install-with-progress Microsoft.VisualStudio.2022.BuildTools | install Rustlang.Rustup | pin-add Git.Git | pin-add Microsoft.VisualStudio.2022.BuildTools | pin-add Rustlang.Rustup | native set auto-self-update disable | clone-anon dotfiles | copy-template dotfiles\win\templates\host.minimum.toml -> C:\Users\u\.config\dotfiles\host.toml'

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
# PowerShell 7 は入れ方を問わず認めるので、ほかの形で入っていた PowerShell 7 (Microsoft Store の MSIX など) に pin を足さない
Test-Case '入っている道具の pin が無ければ足すが、入っている PowerShell 7 には足さない' '0 [pin-add Git.Git]' {
    $s = New-State -Git @{ Pinned = $false } -Pwsh @{ Installed = '7.7.0' }
    $r = Invoke-Flow -States @($s, $s, (New-State)); "$($r.Code) [$($r.Calls)]"
}
Test-Case 'PowerShell 7 の install が落ちたら pin を足さずに 1' '1 [install Microsoft.PowerShell]' {
    $s = New-State -Pwsh $fresh
    $r = Invoke-Flow -States @($s, $s) -Fail @{ 'install Microsoft.PowerShell' = 1 }; "$($r.Code) [$($r.Calls)]"
}
Test-Case 'PowerShell 7 の pin を足せなくても進み、足せなかったと出す' '0 [install Microsoft.PowerShell | pin-add Microsoft.PowerShell 7.6.*] True' {
    $r = Invoke-Flow -States @((New-State -Pwsh $fresh), (New-State), (New-State)) -Fail @{ 'pin-add Microsoft.PowerShell' = 1 }
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*PowerShell 7: winget pin add が失敗した (終了コード 0x00000001)*')"
}
Test-Case '管理者の PC は PowerShell 7 を MSIX で --silent で入れ、7.6 の線に留める pin を足す' '0 [install Microsoft.PowerShell | pin-add Microsoft.PowerShell 7.6.*] install --id Microsoft.PowerShell --exact --source winget --silent --accept-source-agreements --disable-interactivity --version 7.6.10.0 --accept-package-agreements --installer-type msix True' {
    $r = Invoke-Flow -States @((New-State -Pwsh $fresh), (New-State), (New-State))
    "$($r.Code) [$($r.Calls)] $($r.PwshArgs) $($r.Text -like '*PowerShell 7: winget pin を足した (7.6.* に留める。winget upgrade --all は 7.7 へ上げない)*')"
}

# 普段のアカウントが管理者でない PC: PowerShell 7 は MSI (--silent を付けず、UAC で管理者の資格情報を入れる) で入れ、MSIX しか無ければ MSI を足す
$userMsiArgs = 'install --id Microsoft.PowerShell --exact --source winget --accept-source-agreements --disable-interactivity --version 7.6.10.0 --accept-package-agreements --installer-type wix --custom USE_MU=0 ENABLE_MU=0'
# MSI を入れた後の状態 (MSI の置き場所はマシンの PATH に入り、先に当たる)
function New-UserMsiState { New-State @{ AccountAdmin = $false } -Pwsh @{ Kind = 'msi'; Path = $msiPwsh; NonMsix = $true } }
Test-Case '管理者でない PC で PowerShell 7 が入っていなければ、MSI を UAC で入れ、7.6 の線に留める pin を足す' "0 [install-with-progress Microsoft.PowerShell | pin-add Microsoft.PowerShell 7.6.*] $userMsiArgs True" {
    $r = Invoke-Flow -States @((New-State @{ AccountAdmin = $false } -Pwsh $fresh), (New-UserMsiState), (New-UserMsiState))
    "$($r.Code) [$($r.Calls)] $($r.PwshArgs) $($r.Text -like '*  (管理者でない PC なので、PowerShell 7 は MSI (マシン単位) で入れる。UAC で管理者の資格情報を入れる)*')"
}
# 入っている MSIX があると winget の install は upgrade に替わって止まるので、--force で直に入れる (入っていない PC の上の試験には付かない)
Test-Case '管理者でない PC で PowerShell 7 が MSIX しか無ければ、MSI を --force で足して 0' "0 [install-with-progress Microsoft.PowerShell | pin-add Microsoft.PowerShell 7.6.*] $userMsiArgs --force" {
    $r = Invoke-Flow -States @((New-State @{ AccountAdmin = $false }), (New-UserMsiState), (New-UserMsiState))
    "$($r.Code) [$($r.Calls)] $($r.PwshArgs)"
}
Test-Case '管理者でない PC で MSI があれば、PowerShell 7 は何も打たない' '0 []' { $r = Invoke-Flow -States @((New-UserMsiState)); "$($r.Code) [$($r.Calls)]" }
Test-Case '管理者でない PC の -Check で MSIX しか無ければ、何も打たずに 3' '3 []' { $r = Invoke-Flow -States @((New-State @{ AccountAdmin = $false })) -Check; "$($r.Code) [$($r.Calls)]" }
Test-Case '管理者でない PC で MSI が入らなければ (UAC を断ったなど)、pin を足さずに 1' '1 [install-with-progress Microsoft.PowerShell] True' {
    $s = New-State @{ AccountAdmin = $false }
    $key = 'install-with-progress Microsoft.PowerShell'
    $r = Invoke-Flow -States @($s, $s) -Fail @{ $key = -1978334964 }
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*PowerShell 7 のインストーラーが取り消された (UAC で「はい」を押さなかった・窓を閉じた)*')"
}
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

# 既定の形 (gh なし): gh を入れず、ログインせず、dotfiles を資格情報なしで clone し、手元のホストの値に雛形を写す。Build Tools と rustup は
# 入れない (runner は dotfiles 関数が GitHub の Release から落とした exe で動く)
Test-Case '既定の形のまっさらな PC は、Git と PowerShell 7 だけを入れ (Build Tools と rustup は入れない)、ログインせずに dotfiles を匿名で clone し、雛形を写して 0' "0 [$freshPublicCalls] True" {
    $cloned = New-PublicState -HostFile @{ Exists = $false }
    $r = Invoke-Flow -Public $true -States @((New-FreshPublicState), (New-PublicInstalledState), $cloned, (New-PublicState))
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*gh を使わず、public な dotfiles だけを clone する*')"
}
Test-Case '既定の形の -Check は何も打たず (まっさらな PC は 3)、表に Build Tools と rustup の行を出さない' '3 [] False False' {
    $r = Invoke-Flow -Public $true -States @((New-FreshPublicState)) -Check
    "$($r.Code) [$($r.Calls)] $($r.Text.Contains('Build Tools')) $($r.Text.Contains('rustup'))"
}
# -Rust: 既定の形に Build Tools と rustup を足す (gh の無い PC で、runner を手元で build する・claude-selector を作る)
Test-Case '-Rust のまっさらな PC は、既定の形に Build Tools と rustup を足して入れ (Build Tools を rustup より先に)、pin と rustup の自己更新の止めを足して 0' "0 [$freshRustCalls] True" {
    $cloned = New-PublicState -Rust -HostFile @{ Exists = $false }
    $r = Invoke-Flow -Public $true -Rust $true -States @((New-FreshPublicState -Rust), (New-PublicInstalledState -Rust), $cloned, (New-PublicState -Rust))
    "$($r.Code) [$($r.Calls)] $($r.Text -like '*Install-Bootstrap.ps1 -Rust。gh を使わず、public な dotfiles だけを clone し、runner を手元で build する Visual Studio Build Tools と rustup も入れる*')"
}
Test-Case '-Rust の -Check は何も打たず (まっさらな PC は 3)、表に Build Tools と rustup の行を出す' '3 [] True True' {
    $r = Invoke-Flow -Public $true -Rust $true -States @((New-FreshPublicState -Rust)) -Check
    "$($r.Code) [$($r.Calls)] $($r.Text.Contains('⚠ Visual Studio Build Tools 2022 : 入っていない → 17.14.44 を入れる')) $($r.Text.Contains('⚠ rustup : 入っていない → 1.29.3 を入れる'))"
}
# 入れた後の手 (pin・Build Tools の足りない部品・rustup の自己更新の止めと既定の host) も、Rust の道具を入れる形のときだけ。既定の形の
# Get-BootstrapState は Build Tools と rustup を読まないが、状態にあっても触らない
$rustDrift = @{ Vs = @{ Pinned = $false; MissingComponents = @('Microsoft.VisualStudio.Workload.VCTools'); InstallPath = 'C:\BT' }; Rustup = @{ Pinned = $false; SelfUpdateDisabled = $false; DefaultHost = $Gnu } }
Test-Case '既定の形は、状態に Build Tools と rustup があっても、pin も部品も rustup の自己更新の止めも既定の host も足さない' '0 [pin-add Git.Git]' {
    $s = New-PublicState -Rust -Git @{ Pinned = $false } -Vs $rustDrift.Vs -Rustup $rustDrift.Rustup
    $s.Rust = $false
    $r = Invoke-Flow -Public $true -States @($s, $s, (New-PublicState)); "$($r.Code) [$($r.Calls)]"
}
Test-Case '-Rust は、入っている Build Tools と rustup に pin・足りない部品・rustup の自己更新の止めと既定の host を足す' '0 [pin-add Git.Git | pin-add Microsoft.VisualStudio.2022.BuildTools | vs-modify Microsoft.VisualStudio.Workload.VCTools | pin-add Rustlang.Rustup | native set auto-self-update disable | native set default-host x86_64-pc-windows-msvc]' {
    $s = New-PublicState -Rust -Git @{ Pinned = $false } -Vs $rustDrift.Vs -Rustup $rustDrift.Rustup
    $r = Invoke-Flow -Public $true -Rust $true -States @($s, $s, (New-PublicState -Rust)); "$($r.Code) [$($r.Calls)]"
}
Test-Case '既定の形で dotfiles-private の clone があれば、雛形を写さない' '0 [clone-anon dotfiles]' {
    $noClone = New-PublicState -Dotfiles $freshRepo -HostFile @{ Exists = $false; PrivateClone = $true }
    $cloned = New-PublicState -HostFile @{ Exists = $false; PrivateClone = $true }
    $r = Invoke-Flow -Public $true -States @($noClone, $noClone, $cloned, $cloned); "$($r.Code) [$($r.Calls)]"
}
Test-Case '既定の形で手元のホストの値があれば、上書きしない' '0 [clone-anon dotfiles]' {
    $noClone = New-PublicState -Dotfiles $freshRepo
    $r = Invoke-Flow -Public $true -States @($noClone, $noClone, (New-PublicState), (New-PublicState)); "$($r.Code) [$($r.Calls)]"
}
Test-Case '既定の形で Git が入らなければ、clone も雛形もせずに 1 (gh のことは言わない)' '1 [install Git.Git] True False' {
    $s = New-FreshPublicState
    $r = Invoke-Flow -Public $true -States @($s, $s) -Fail @{ 'install Git.Git' = 1 } -FailLines @{}
    "$($r.Code) [$(@($r.Calls -split ' \| ' | Where-Object { $_ -notlike 'install-with-progress*' -and $_ -notlike 'install Rustlang*' -and $_ -notlike 'install Microsoft.PowerShell' -and $_ -notlike 'pin-add*' -and $_ -notlike 'native*' }) -join ' | ')] $($r.Text -like '*Git for Windows が入っていないので、clone しない*') $($r.Text -like '*gh*ログイン*')"
}

# 入れたての Windows 11 の winget (v1.11.510) は、昇格していないと machine の scope の source を開けず、Git の install が 0x80070005 で落ちる。
# そのときだけ、同じ引数を昇格した winget で打ち直す (UAC の確認が 1 回出る)。Git のほかの道具・ほかの落ち方では打ち直さない
$accessDenied = -2147024891
$freshPublicElevatedCalls = $freshPublicCalls -replace '^install Git\.Git \| ', 'install Git.Git | install-elevated Git.Git | '
Test-Case '入れたての Windows で Git の install が 0x80070005 で落ちたら、同じ引数を昇格した winget で打ち直して続け、0 で終える' "0 [$freshPublicElevatedCalls] True True True" {
    $cloned = New-PublicState -HostFile @{ Exists = $false }
    $r = Invoke-Flow -Public $true -States @((New-FreshPublicState), (New-PublicInstalledState), $cloned, (New-PublicState)) -Fail @{ 'install Git.Git' = $accessDenied } -FailLines @{ 'install Git.Git' = @('Failed to open the predefined source; please report to winget maintainers.') }
    $said = $r.Text.Contains('昇格していない winget が machine の scope を読めなかった (終了コード 0x80070005)。昇格した winget で入れ直す (UAC の確認が 1 回出る')
    $sameArgs = $script:ElevatedArgs -eq ((Get-WingetInstallArguments -PackageId 'Git.Git' -Version '2.56.0.4' -Silent $true -Extra @('--scope', 'machine')) -join ' ')
    $notCancelled = -not $r.Text.Contains('取り消された')
    "$($r.Code) [$($r.Calls)] $said $sameArgs $notCancelled"
}
Test-Case 'Git のほかの道具 (-Rust の rustup) が 0x80070005 で落ちても・Git がほかの終了コードで落ちても、昇格して打ち直さない' 'True False False' {
    $rustState = New-FreshPublicState -Rust
    $rustup = Invoke-Flow -Public $true -Rust $true -States @($rustState, $rustState) -Fail @{ 'install Rustlang.Rustup' = $accessDenied }
    $s = New-FreshPublicState
    $git = Invoke-Flow -Public $true -States @($s, $s) -Fail @{ 'install Git.Git' = 1 }
    "$($rustup.Calls -like '*install Rustlang.Rustup*') $($rustup.Calls -like '*install-elevated*') $($git.Calls -like '*install-elevated*')"
}
Test-Case '昇格した側に winget が無ければ (UAC で別の管理者のアカウントに昇格した)、そのアカウントと登録の手を出して 1' '1 True True' {
    $s = New-FreshPublicState
    $r = Invoke-Flow -Public $true -States @($s, $s) -Fail @{ 'install Git.Git' = $accessDenied; 'install-elevated Git.Git' = 2 } -FailLines @{ 'install-elevated Git.Git' = @('winget が見つからない (昇格した側のアカウント: it-admin)') }
    "$($r.Code) $($r.Text -like '*winget が見つからない (昇格した側のアカウント: it-admin)*') $($r.Text -like '*Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe*')"
}
Test-Case '昇格の UAC で断ったら (1223)、Git のインストーラーが取り消されたと出して 1' '1 True' {
    $s = New-FreshPublicState
    $r = Invoke-Flow -Public $true -States @($s, $s) -Fail @{ 'install Git.Git' = $accessDenied; 'install-elevated Git.Git' = 1223 } -FailLines @{ 'install-elevated Git.Git' = @('UAC: The operation was canceled by the user.') }
    "$($r.Code) $($r.Text -like '*Git for Windows のインストーラーが取り消された*')"
}

# 締めの案内: 揃え終えたとき (初めから揃っていたときも) に、次に打つコマンドとホストの値の行を出す。-Check と 1 で終えたときは出さない
Test-Case '揃え終えたら、PowerShell 7 の新しい窓で dotfiles.ps1 を読み込んで dotfiles apply と出す (既定の形は runner の exe を落とすことと手元のホストの値)' 'True True True True' {
    $r = Invoke-Flow -Public $true -States @((New-PublicState))
    "$($r.Text -like '*次に打つ (PowerShell 7 の新しい窓で。この窓は PATH が古い):*') $($r.Text -like "*  . 'C:\Users\u\ghq\github.com\pollenjp\dotfiles\win\powershell\dotfiles.ps1'*") $($r.Text.Contains($runnerExeLine)) $($r.Text -like "*ホストの値は $HostFilePath (minimum の雛形を写したもの)*")"
}
Test-Case '-Rust で揃え終えたときも、初めての dotfiles apply が runner の exe を GitHub の Release から落とすことと手元のホストの値を出す' 'True True' {
    $r = Invoke-Flow -Public $true -Rust $true -States @((New-PublicState -Rust))
    "$($r.Text.Contains($runnerExeLine)) $($r.Text -like "*ホストの値は $HostFilePath (minimum の雛形を写したもの)*")"
}
Test-Case '-Private で揃え終えたら dotfiles-private のホストの値を出し、手元のホストの値もあれば両方で止まることを足す' 'True False True' {
    $plain = Invoke-Flow -States @((New-State))
    $both = Invoke-Flow -States @((New-State @{ HostFile = (New-HostFile @{ Exists = $true; PrivateClone = $true }) }))
    "$($plain.Text -like '*ホストの値は dotfiles-private の win\hosts\*') $($plain.Text -like '*※ 手元のホストの値*') $($both.Text -like "*※ 手元のホストの値 ($HostFilePath) もある。*")"
}
Test-Case '-Check と、揃いきらずに 1 で終えたときは、次に打つコマンドを出さない' 'False False' {
    $check = Invoke-Flow -Public $true -States @((New-PublicState)) -Check
    $s = New-State -Git $fresh -Dotfiles $freshRepo
    $failed = Invoke-Flow -States @($s, $s) -Fail @{ 'install Git.Git' = 1 }
    "$($check.Text -like '*次に打つ*') $($failed.Text -like '*次に打つ*')"
}

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
