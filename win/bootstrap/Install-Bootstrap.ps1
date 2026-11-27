<#
.SYNOPSIS
新しい Windows で最初に流す setup。Rust の runner を動かせるところまで (Git for Windows・PowerShell 7・Visual Studio Build Tools・rustup と、
dotfiles の clone) を揃える。-Private では、GitHub CLI とそのログイン・dotfiles-private・claude-skills の clone も揃える。

.DESCRIPTION
dotfiles の win/bootstrap/Install-Bootstrap.ps1。新しい Windows では GitHub の raw の URL からファイルに落として流し、clone した後は
clone の中のものを流す (win/README.md の「bootstrap (新しい Windows で最初に流す)」。経緯は dotfiles-private の
docs/adr/058_win_runner_bootstrap_*・docs/adr/111_win_runner_without_gh_*)。manifest では配らない。

形は 2 つ:
  既定 (引数なし)  gh を入れず、ログインもしない (gh にログインできない PC・pollenjp の private な repo を取れない PC でも流せる)。public な
                   dotfiles だけを匿名の HTTPS で clone し (origin は https://github.com/pollenjp/dotfiles.git)、雛形
                   win/templates/host.minimum.toml を %USERPROFILE%\.config\dotfiles\host.toml に写す (あれば上書きしない。dotfiles-private の
                   clone がある PC でも写さない: ホストの値はそこから引く)
  -Private         gh を入れて github.com にログインし、dotfiles・dotfiles-private・claude-skills を gh の資格情報で clone する (origin は
                   WSL と同じ ssh の URL)。ホストの値は dotfiles-private の win/hosts/ から引くので、雛形は写さない。ホストの値の道具の switch
                   privateRepos を on にした PC で流す

すること (この順):
  0. 最初に Smart App Control (SAC) を確かめ、オフでなければ (オン・評価モード) 警告を出して続ける (止めない)。オンだと cargo が
     作った exe (Rust の runner・build script) が止められて動かないので、runner を流す前にオフにする (オフにするのはユーザー)
  1. 前提を見る: winget があるか・管理者の PowerShell でないか・CPU (x64 だけ)・普段のアカウントが管理者か (トークンに BUILTIN\Administrators が
     あるか。UAC で権限を落としていても管理者。PowerShell 7 の入れ方を決める)
  2. Git for Windows → (-Private なら GitHub CLI →) PowerShell 7 → Visual Studio Build Tools 2022 → rustup を、下の param の固定した版で
     winget から入れ、pin を足す (winget upgrade --all から外す)。PowerShell 7 は入れ方を問わず (MSI・MSIX (Microsoft Store・winget)・PATH の
     ほかの pwsh)、7.6.0 より古くなければ入っているとみなし、版も pin も揃えない。入っていなければ 7.6 (LTS) の版を winget で入れ、7.6 の線に
     留める pin (7.6.*) を足す。普段のアカウントが管理者の PC は MSIX (ユーザー単位で入り、UAC は出ない)、管理者でない PC は MSI (マシン単位。
     UAC で管理者の資格情報を入れる。Microsoft Update の更新には入れない)。管理者でない PC は UAC で別の管理者のアカウントに昇格し、その側では
     使う人ごとに登録される MSIX の pwsh を起こせないので、MSIX の pwsh しか無ければ MSI も入れる (--force で直に入れる。入っている MSIX があると、
     winget の install は upgrade に替わって止まる)。Build Tools には C++ のワークロード・MSVC (x64)・
     Windows SDK を入れ、入っている Build Tools に足りないものは Visual Studio Installer で足す。rustup は MSVC の host
     (x86_64-pc-windows-msvc) にし、toolchain は入れず、自己更新を止める (rustup-init が MSVC の有無を見るので、Build Tools を rustup より
     先に入れる)。GNU の host にしないのは、windows-sys 0.61 (windows-link の raw-dylib) の build に MinGW の dlltool と as が要り、GNU の
     toolchain に同梱のものだけでは作れないため
  3. (-Private だけ) gh が github.com にログインしていなければ gh auth login を流す (一回限りのコードはクリップボードに入る。ブラウザーで
     認める)。ログインの途中で Ctrl+C を押すと gh は止まるが、この script は止まらずに締めの表まで出し、終了コード 1 で終える
  4. clone する。既定の形は dotfiles を資格情報なしの HTTPS で、-Private は dotfiles・dotfiles-private・claude-skills を gh の資格情報で
     HTTPS を通す組 (dotfiles の nix/pkgs/git-gh と同じ) を -c で渡して (origin は ssh の URL のまま)、%USERPROFILE%\ghq\github.com\pollenjp\ に
     clone する。core.autocrlf=false で、WSL が配ったものとバイト列をそろえる。~/.gitconfig は書かない
  5. (既定の形だけ) 雛形を手元のホストの値に写す (上の「形は 2 つ」)
  6. 揃え終えたら (終了コード 0)、次に打つコマンド (clone の dotfiles.ps1 を読み込んで dotfiles apply) を出す。-Check では出さない (runner の
     手順 bootstrap が毎回 -Check を流すので)

入っている道具の版が固定した版と違っても揃えない (⚠ と ※ の手順を出すだけ。揃えるのは Rust の runner の受け持ち。PowerShell 7 は版を
固定した版と比べず、7.6.0 より古いときだけ ⚠ を出す。管理者でない PC で MSIX の pwsh しか無いときは、入っていないものとして MSI を足す)。※ の上げ方の
winget upgrade には --include-pinned を付ける (付けないと、bootstrap が足した pin に止められる)。あるディレクトリと clone には触らない
(確かめるだけ。取得もしない)。

何も変えずに止めるとき: 管理者の PowerShell (clone と rustup が管理者の持ち物になり、普通の権限の git が dubious ownership で止まる)・
x64 でない CPU。SAC がオフでないときは止めず、最初の警告と表の ⚠ の行で知らせる (終了コードは 1)。
UAC は winget と Visual Studio Installer が道具ごとに出す (管理者の PC の PowerShell 7 (MSIX) と rustup はユーザー単位に入るので出ない。
管理者でない PC の PowerShell 7 は MSI なので出る)。入れたての Windows 11 の winget (v1.11.510) は、昇格していないと machine の scope の source を
開けず、Git の install が 0x80070005 (Failed to open the predefined source) で落ちる。そのときだけ、同じ引数を昇格した winget (System32 の
Windows PowerShell を UAC で昇格させて打つ) で打ち直す (UAC の確認は Git の installer の代わりにそこで 1 回出る)。winget の出力は UTF-8 で読む
(コンソールの既定の CP932 で読むと、進み具合の帯と日本語のメッセージが化ける)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。新しい Windows には 5.1 しか
無いので、PowerShell 7 にしか無い書き方を使わない (Install-Bootstrap.Tests.ps1 が見る)。

.PARAMETER GitVersion
Git for Windows (winget の Git.Git) の固定する版。版を変えるときはここの既定値を変える (nix/scripts/check-winget-version.sh git が読む)。

.PARAMETER GhVersion
GitHub CLI (winget の GitHub.cli) の固定する版 (check-winget-version.sh gh が読む)。入れるのは -Private のときだけ。

.PARAMETER PwshVersion
PowerShell 7 (winget の Microsoft.PowerShell) の、入っていないときに入れる版 (check-winget-version.sh pwsh が読む。管理者の PC は MSIX、
管理者でない PC は MSI で入れる)。7.6 (LTS) の線の版にする: winget の 7.6 の MSIX は package Microsoft.PowerShell-LTS (Microsoft Store の
PowerShell-LTS と同じ) で、7.7 からの MSIX は別の package Microsoft.PowerShell (Store の PowerShell と同じ) なので、7.6 の MSIX の上げ先に
ならない。7.7 からは MSI も無いので、管理者でない PC に入れる MSI も 7.6 の線にしか無い。

.PARAMETER VsBuildToolsVersion
Visual Studio Build Tools 2022 (winget の Microsoft.VisualStudio.2022.BuildTools) の固定する版 (check-winget-version.sh vs-buildtools が読む)。

.PARAMETER RustupVersion
rustup (winget の Rustlang.Rustup) の固定する版 (check-winget-version.sh rustup が読む)。toolchain は入れない (Rust の runner の
rust-toolchain.toml が決める)。

.PARAMETER Private
gh を入れて github.com にログインし、pollenjp の private な repo (dotfiles-private・claude-skills) も clone する形にする。ホストの値の
道具の switch privateRepos を on にした PC で使う (runner の手順 bootstrap も、そのホストでは -Check -Private を流す)。

.PARAMETER Check
今の状態を出すだけで、何も変えない (SAC の警告は同じく最初に出す)。終了コードは 0 = 直すことが無い・3 = 入っていない・無いものだけ
(流せば揃う)・1 = ほかに直すことがある・2 = winget が無い・思わぬ例外。
#>
[CmdletBinding()]
param(
    [string]$GitVersion = '2.56.0.4',
    [string]$GhVersion = '2.103.3',
    [string]$PwshVersion = '7.6.10.0',
    [string]$VsBuildToolsVersion = '17.14.44',
    [string]$RustupVersion = '1.29.3',
    [switch]$Private,
    [switch]$Check
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Bootstrap.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# rustup の既定の host。GNU の host は windows-sys 0.61 (windows-link の raw-dylib) の build に MinGW の dlltool と as が要り、toolchain に
# 同梱の dlltool だけでは import library を作れないので、MSVC にする (dotfiles-private の ADR 058)
$script:RustHost = 'x86_64-pc-windows-msvc'

# Build Tools に入れるもの: C++ のワークロード (必須の部品だけ)・MSVC の x64 の build tools・Windows SDK。MSVC と SDK はワークロードの
# 推奨の部品で、ワークロードだけでは入らないので名指しする (rustup 1.29.3 が自分で Visual Studio を入れるときと同じ 2 つ)
$script:VsWorkload = 'Microsoft.VisualStudio.Workload.VCTools'
$script:VsToolsComponent = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'
$script:VsSdkComponent = 'Microsoft.VisualStudio.Component.Windows11SDK.26100'

# PowerShell 7 として認める一番古い版。入れ方 (MSI・MSIX・ほかの形) は問わない。7.4 (LTS) と 7.5 は 2026-11-10 でサポートが終わり、
# dotfiles の PowerShell のテストも 7.6 の線で流す (dotfiles-private の ADR 111)
$script:PwshMinimumVersion = '7.6.0'

# git --version の出力 ("git version 2.56.0.windows.4") を winget の Git.Git の版にする。.windows.1 は 3 つの数 (2.56.0)、
# ほかは 4 つ目に足す (2.56.0.4)。読めなければ $null
function Get-GitVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $t = "$line".Trim()
        if ($t -match '^git version (\d+\.\d+\.\d+)\.windows\.(\d+)$') {
            if ($Matches[2] -eq '1') { return $Matches[1] }
            return "$($Matches[1]).$($Matches[2])"
        }
        if ($t -match '^git version (\d+\.\d+\.\d+)$') { return $Matches[1] }
    }
    $null
}

# gh --version の 1 行目 ("gh version 2.103.3 (2026-10-26)") から版を拾う。無ければ $null
function Get-GhVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line".Trim() -match '^gh version (\d+\.\d+\.\d+)(\s|$)') { return $Matches[1] }
    }
    $null
}

# pwsh --version の出力 ("PowerShell 7.6.10") から版 (3 つの数。7.6.10) を拾う。preview などは読まない。無ければ $null
function Get-PwshVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line".Trim() -match '^PowerShell (\d+\.\d+\.\d+)$') { return $Matches[1] }
    }
    $null
}

# PowerShell 7 として認める版か ($script:PwshMinimumVersion より古くない)。読めない版は認めない
function Test-PwshVersionAccepted {
    param([string]$Version, [string]$Minimum = $script:PwshMinimumVersion)
    $v = $null
    $m = $null
    if (-not [version]::TryParse("$Version", [ref]$v)) { return $false }
    if (-not [version]::TryParse("$Minimum", [ref]$m)) { return $false }
    $v -ge $m
}

# pwsh を探す場所。新しい窓の PATH (レジストリのマシン → ユーザーの Path。runner と herdr はこの PATH の pwsh を起こす) のディレクトリごとの
# pwsh.exe を順に並べ、その後ろに MSI の既定の置き場所と MSIX の実行エイリアス (PATH から外れていても見つけるため) を足す。同じパス
# (大文字小文字は問わない) は 1 つにする。OnPath は PATH のディレクトリから組んだものか。Windows のパスは字でつなぐ (Join-Path は、
# テストを流す Linux の pwsh で C: のドライブを探しに行く)
function Get-PwshCandidates {
    param([string]$PathValue, [string]$MsiPath, [string]$AliasPath)
    # @{} の鍵は大文字小文字を区別しない
    $seen = @{}
    foreach ($entry in ("$PathValue" -split ';')) {
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if (-not $dir) { continue }
        $path = "$dir\pwsh.exe"
        if ($seen.ContainsKey($path)) { continue }
        $seen[$path] = $true
        [pscustomobject]@{ Path = $path; OnPath = $true }
    }
    foreach ($path in @($MsiPath, $AliasPath)) {
        if ((-not $path) -or $seen.ContainsKey($path)) { continue }
        $seen[$path] = $true
        [pscustomobject]@{ Path = $path; OnPath = $false }
    }
}

# pwsh の入れ方。WindowsApps の下 (MSIX の実行エイリアス・実体) は msix、MSI の既定の置き場所は msi、ほかは other
function Get-PwshInstallKind {
    param([string]$Path, [string]$MsiPath)
    if ("$Path" -match '\\WindowsApps\\') { return 'msix' }
    if ($MsiPath -and ("$Path" -eq $MsiPath)) { return 'msi' }
    'other'
}

# 表の行に出す PowerShell 7 の入れ方 (MSIX・MSI。ほかの形はパス)
function Format-PwshInstallKind {
    param([string]$Kind, [string]$Path)
    switch ($Kind) {
        'msix' { return 'MSIX' }
        'msi' { return 'MSI' }
    }
    $Path
}

# bootstrap が入れた PowerShell 7 に足す pin の版 (固定した版の線。7.6.10.0 → 7.6.*)。winget upgrade --all は、この線の中でだけ上げ、
# 7.7 (MSI が無く、MSIX は別の package) へは上げない。読めなければ $null (pin を足さない)
function Get-PwshPinVersion {
    param([string]$Version)
    if ("$Version" -match '^(\d+)\.(\d+)\.') { return "$($Matches[1]).$($Matches[2]).*" }
    $null
}

# トークンのグループの SID。WindowsIdentity の Claims のうち、種類が有効なグループ (groupsid) か deny-only のグループ (denyonlysid) のものの
# 値を、並びのまま返す。種類の名前空間は種類ごとに違う (groupsid は http://schemas.microsoft.com/ws/2008/06/identity/claims/、denyonlysid は
# http://schemas.xmlsoap.org/ws/2005/05/identity/claims/) ので、最後の語で見る。WindowsIdentity.Groups は deny-only のグループを除く
# (UAC で権限を落とした管理者の BUILTIN\Administrators が入らない) ので使わない
function Select-TokenGroupSids {
    param([object[]]$Claims)
    foreach ($claim in @($Claims | Where-Object { $null -ne $_ })) {
        if ("$($claim.Type)" -match '/(groupsid|denyonlysid)$') { "$($claim.Value)" }
    }
}

# 普段のアカウントが管理者か (トークンのグループの SID の並びに BUILTIN\Administrators (S-1-5-32-544) があるか)。UAC で権限を落とした
# 管理者のトークンでも deny-only のグループで入るので、管理者とみなす。管理者でない PC (UAC で別の管理者のアカウントの資格情報を入れて
# 昇格する) には、PowerShell 7 を MSI で入れる
function Test-AdministratorsSid {
    param([string[]]$Sids)
    @($Sids) -contains 'S-1-5-32-544'
}

# PowerShell 7 を入れるか。入っていないときと、普段のアカウントが管理者でない PC で MSIX でない pwsh (PATH のディレクトリ・MSI の置き場所) が
# 無いとき (MSI を入れる。UAC で別の管理者のアカウントに昇格した側では、使う人ごとに登録される MSIX の pwsh を起こせないため)
function Test-PwshInstallNeeded {
    param($Package, [bool]$AccountAdmin)
    if (-not $Package.Exists) { return $true }
    (-not $AccountAdmin) -and (-not $Package.NonMsix)
}

# PowerShell 7 の MSI を --force で直に入れるか。pwsh がもう入っている (管理者でない PC で MSIX しか無い) ときだけ。winget の install は、
# 入っている package (MSIX も Microsoft.PowerShell に結ばれる) が見つかると upgrade に替わり、--version が入っている版より新しくなければ止まり、
# 新しくても入れ方 (MSIX → MSI) を替えない (winget-cli の InstallCommand.cpp・UpdateFlow.cpp。winget install --help の文: 既定では入っているかを
# 見て upgrade を試み、--force で直に入れる)。入っていない PC には付けない (--force は安全に関わらない問題も越えて続ける意味も持つ)
function Test-PwshForceInstall {
    param($Package, [bool]$AccountAdmin)
    [bool]$Package.Exists -and (Test-PwshInstallNeeded -Package $Package -AccountAdmin $AccountAdmin)
}

# PowerShell 7 の MSI に渡す property (winget の --custom。msiexec の引数の後ろに足される)。Microsoft Update の更新に入れない (どちらも
# 既定は 1。ENABLE_MU=1 は Microsoft Update を自動更新に使う側へ入れる)。版の線は winget の pin で留め、Windows Update の設定にも触らない
# (管理者でない PC は、管理する人が更新の設定を決めていることが多い)
function Get-PwshMsiCustomArgument {
    'USE_MU=0 ENABLE_MU=0'
}

# rustup --version の出力から rustup の版 ("rustup 1.29.3 (…)") を拾う。info の行や rustc の行は読まない。無ければ $null
function Get-RustupVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line".Trim() -match '^rustup (\d+\.\d+\.\d+)(\s|$)') { return $Matches[1] }
    }
    $null
}

# JSON から作ったオブジェクトの項目を読む (無ければ $null。Set-StrictMode の下でも止まらない)
function Get-JsonProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

# vswhere -format json -include packages の出力から、Build Tools (productId) でメジャーの合うもの (catalog の productDisplayVersion が
# "<Major>." で始まる) を 1 つ選び、置き場所・版・入っているワークロードと部品の ID を返す。無ければ $null。
# 5.1 の ConvertFrom-Json は配列を 1 つの値として返すので、パイプでほどいてから見る
function Get-VsBuildToolsInstance {
    param([string]$Json, [int]$Major)
    if (-not "$Json".Trim()) { return $null }
    $parsed = ConvertFrom-Json -InputObject $Json
    foreach ($i in @($parsed | ForEach-Object { $_ })) {
        if ("$(Get-JsonProperty $i 'productId')" -ne 'Microsoft.VisualStudio.Product.BuildTools') { continue }
        $display = "$(Get-JsonProperty (Get-JsonProperty $i 'catalog') 'productDisplayVersion')"
        if (-not $display.StartsWith("$Major.")) { continue }
        $ids = @(@(Get-JsonProperty $i 'packages') | Where-Object { $_ } | ForEach-Object { "$(Get-JsonProperty $_ 'id')" })
        return [pscustomobject]@{ Path = "$(Get-JsonProperty $i 'installationPath')"; Version = $display; Packages = $ids }
    }
    $null
}

# Build Tools に入れるもの (C++ のワークロード・MSVC・Windows SDK)
function Get-VsRequiredComponents {
    @($script:VsWorkload, $script:VsToolsComponent, $script:VsSdkComponent)
}

# 入っているもののうち、足りないもの。Windows SDK は 10 か 11 の SDK のどれかがあれば足りたことにする (rustup と同じ考え。
# ワークロードの必須の部品の Windows10SDK (UCRT) は版の付かない ID なので、SDK とは数えない)
function Get-VsMissingComponents {
    param([string[]]$Installed)
    $have = @($Installed | Where-Object { $_ })
    if ($have -notcontains $script:VsWorkload) { $script:VsWorkload }
    if ($have -notcontains $script:VsToolsComponent) { $script:VsToolsComponent }
    if (@($have | Where-Object { $_ -match '^Microsoft\.VisualStudio\.Component\.Windows1[01]SDK\.' }).Count -eq 0) { $script:VsSdkComponent }
}

# winget install の --custom に渡す、Build Tools の installer の引数 (英語の言語パック・再起動しない・入れるもの)
function Get-VsInstallCustomArgument {
    param([string[]]$Components)
    $parts = @('--norestart', '--addProductLang', 'En-us')
    foreach ($c in $Components) { $parts += @('--add', $c) }
    $parts -join ' '
}

# 入っている Build Tools に足りないものを足す Visual Studio Installer (setup.exe) の引数。進み具合の窓を出し (--passive)、再起動しない。
# Start-Process の -ArgumentList は値を引用符で囲まないので、空白を含む置き場は二重引用符で囲んだ 1 つの文字列にする
function Get-VsModifyArgumentList {
    param([string]$InstallPath, [string[]]$Components)
    $parts = @('modify', '--installPath', ('"{0}"' -f $InstallPath))
    foreach ($c in $Components) { $parts += @('--add', $c) }
    $parts += @('--passive', '--norestart')
    $parts -join ' '
}

# Smart App Control の状態。レジストリの VerifiedAndReputablePolicyState (0 = オフ・1 = オン・2 = 評価モード) を先に、読めなければ
# Defender の SmartAppControlState (Off・On・Eval) を読む。どちらも無ければ、この Windows には無い (unavailable)
function Get-SmartAppControlState {
    param($PolicyState, $DefenderState)
    if (($null -ne $PolicyState) -and ("$PolicyState" -ne '')) {
        switch ([int]$PolicyState) {
            0 { return 'off' }
            1 { return 'on' }
            2 { return 'eval' }
        }
    }
    switch ("$DefenderState".Trim().ToLowerInvariant()) {
        'off' { return 'off' }
        'on' { return 'on' }
        'eval' { return 'eval' }
    }
    'unavailable'
}

# rustup の settings.toml の中身に auto_self_update = "disable" があるか (check-only は止めたことにしない)
function Test-RustupSelfUpdateDisabled {
    param([string]$SettingsText)
    foreach ($line in ("$SettingsText" -split "`r?`n")) {
        if ($line -match '^\s*auto_self_update\s*=\s*"disable"\s*$') { return $true }
    }
    $false
}

# rustup show の出力の "Default host: x86_64-pc-windows-msvc" から、rustup が今使う既定の host を拾う。無ければ $null。
# settings.toml は読まない (キーの名前が rustup の版で変わり (default_host_triple → default_host_tuple)、書いていなければ rustup の
# build の host が使われる)
function Get-RustupDefaultHost {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line".Trim() -match '^Default host:\s*(\S+)$') { return $Matches[1] }
    }
    $null
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-Herdr.ps1 と同じ)。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# winget install が「取り消された」(UAC で「はい」を押さなかった・installer の窓を閉じた) で落ちたか。winget の「取り消した」
# (0x8A15010C。MSI の 1602 は winget がこれにする) か、出力のインストーラーの終了コードが 1602 (取り消し)・1223 (UAC を断った) か。
# exe の installer の終了コードは、winget が 0x8A150006 にして「Installer failed with exit code: 1602」(日本語なら
# 「インストーラーが終了コードで失敗しました: 1602」) と出す。コロンの直後の数だけを見る (URL の中の数を拾わない)。昇格した winget
# (Invoke-ElevatedWinget) を UAC で断ったときは、ERROR_CANCELLED (1223) を終了コードにする (Get-ElevationFailureCode)
function Test-WingetCancelled {
    param([int]$ExitCode, [string[]]$Lines)
    if ($ExitCode -eq 0) { return $false }
    if (($ExitCode -eq -1978334964) -or ($ExitCode -eq 1223)) { return $true }
    foreach ($line in $Lines) {
        if ("$line".Trim() -match '[:：]\s*(1602|1223)$') { return $true }
    }
    $false
}

# 昇格していない winget が、machine の scope の source を開けずに落ちたか。入れたての Windows 11 の winget (v1.11.510) は、--scope machine の
# install (と list) を「Failed to open the predefined source」「0x80070005 : Access is denied」で落とす (昇格した winget は開ける)。終了コード
# 0x80070005 か、その英語の行で見る
function Test-WingetAccessDenied {
    param([int]$ExitCode, [string[]]$Lines)
    if ($ExitCode -eq 0) { return $false }
    if ($ExitCode -eq -2147024891) { return $true }
    foreach ($line in $Lines) {
        if ("$line" -match 'Failed to open the predefined source') { return $true }
    }
    $false
}

# 昇格した winget を起こせなかったとき (Start-Process -Verb RunAs の例外) の終了コード。UAC で断った (Win32Exception の ERROR_CANCELLED。
# Start-Process は InvalidOperationException に包む) なら 1223 (Test-WingetCancelled が取り消しと読む)、ほか (UAC を出せない SSH の会話など。
# 流し直しても直らない) は -1
function Get-ElevationFailureCode {
    param([Exception]$Exception)
    $e = $Exception
    while ($null -ne $e) {
        if (($e -is [System.ComponentModel.Win32Exception]) -and ($e.NativeErrorCode -eq 1223)) { return 1223 }
        $e = $e.InnerException
    }
    -1
}

# winget の出力の行から、進み具合の表示 (回る棒・帯 █▒) を除く。帯の字は UTF-8 で読んだときだけ除ける (CP932 で読むと「笆遺毎」に化ける。
# Invoke-Winget が UTF-8 で読む)
function Select-WingetOutputLines {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $s = "$line"
        if (($s -notmatch '^\s*[-\\|/]?\s*$') -and ($s -notmatch '[\u2588\u2592]')) { $s }
    }
}

# PowerShell の一重引用符の文字列にする (中の ' を重ねる。全角の引用符も PowerShell は ' と読むので重ねる。Install-ClaudeDesktop.ps1 と同じ)
function ConvertTo-PsLiteral {
    param([string]$Text)
    $quotes = @([char]0x27, [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in "$Text".ToCharArray()) {
        [void]$sb.Append($c)
        if ($quotes -contains $c) { [void]$sb.Append($c) }
    }
    "'" + $sb.ToString() + "'"
}

# PowerShell の本文を -EncodedCommand に渡す形 (UTF-16LE の base64) にする
function ConvertTo-EncodedCommand {
    param([string]$Script)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

# 昇格した Windows PowerShell に渡す本文 (Windows PowerShell 5.1 の書き方だけ)。昇格した側のアカウントの winget を引き (実行エイリアス
# %LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe、無ければ PATH の winget の .exe だけ。関数・alias・.cmd・.ps1 は管理者の権限で流さない)、
# 引数を渡して打ち、出力 (stderr も) を UTF-8 で読んで $LogPath に UTF-8 で書き、winget の終了コードで終わる (Start-Process -Verb RunAs は
# 昇格した process の出力を受け取れない)。winget が無ければ、そのアカウントを $LogPath に書いて 2 で終わる (UAC で別の管理者のアカウントに
# 昇格すると、そのアカウントに winget が登録されていないことがある)。起こせなければ、わけを書いて 2 で終わる ($LASTEXITCODE を先に 2 に
# しておく。起こせないまま exit $LASTEXITCODE に届くと 0 で終わり、入ったように見える)
function Get-ElevatedWingetScript {
    param([string[]]$Arguments, [string]$LogPath)
    $quotedArgs = @($Arguments | ForEach-Object { ConvertTo-PsLiteral -Text $_ }) -join ' '
    $log = ConvertTo-PsLiteral -Text $LogPath
    @(
        "`$ErrorActionPreference = 'Continue'"
        '$global:LASTEXITCODE = 2'
        'try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }'
        '$w = $null'
        'if ($env:LOCALAPPDATA) {'
        "    `$alias = Join-Path `$env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'"
        '    if (Test-Path -LiteralPath $alias) { $w = $alias }'
        '}'
        'if (-not $w) {'
        '    $found = @(Get-Command -Name winget -CommandType Application -ErrorAction SilentlyContinue | Where-Object { "$($_.Source)" -like ''*.exe'' })'
        '    if ($found.Count -gt 0) { $w = $found[0].Source }'
        '}'
        'if (-not $w) {'
        "    ('winget が見つからない (昇格した側のアカウント: ' + `$env:USERNAME + ')') | Out-File -LiteralPath $log -Encoding utf8"
        '    exit 2'
        '}'
        'try {'
        "    & `$w $quotedArgs 2>&1 | ForEach-Object { `"`$_`" } | Out-File -LiteralPath $log -Encoding utf8"
        '} catch {'
        "    ('winget を起こせなかった: ' + `$_.Exception.Message) | Out-File -LiteralPath $log -Encoding utf8 -Append"
        '    $global:LASTEXITCODE = 2'
        '}'
        'exit $LASTEXITCODE'
    ) -join "`n"
}

# 昇格した側で winget が見つからないときの行 (Install-OpenSSH.ps1・Install-Sshd.ps1 と同じ字)
function Format-WingetMissingNote {
    param([string]$Account)
    "winget が見つからない (昇格した側のアカウント: $Account)"
    '※ UAC で別の管理者のアカウントの資格情報を入れたなら、そのアカウントには winget (App Installer) が登録されていないことがある (winget は Windows にサインインしたときに使う人ごとに登録され、この PC に一度もサインインしていないアカウントには無い)。そのアカウントでこの PC に一度サインインするか、そのアカウントの管理者の PowerShell (Windows PowerShell を「管理者として実行」で開き、UAC でそのアカウントの資格情報を入れる) で Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe を打ってから、流し直す。普段のアカウントのまま昇格したなら、Microsoft Store の「アプリ インストーラー」を入れる (更新する)'
}

# 固定した版で入れる winget install の引数。道具ごとの引数 (scope・installer の種類・--custom) を後ろに足す。-Silent $false なら
# --silent を付けず、winget の既定 (進み具合の小さな窓が出る形。MSI なら /passive) で流す
function Get-WingetInstallArguments {
    param([string]$PackageId, [string]$Version, [bool]$Silent = $true, [string[]]$Extra)
    $silentArgs = @()
    if ($Silent) { $silentArgs = @('--silent') }
    @('install', '--id', $PackageId, '--exact', '--source', 'winget') + $silentArgs + @('--accept-source-agreements',
        '--disable-interactivity', '--version', $Version, '--accept-package-agreements') + @($Extra | Where-Object { $_ })
}

# winget pin add の引数。-Version を渡すと、その版の範囲 (7.6.* など) に留める pin (gating) にする。渡さなければ pin (pinning)
function Get-WingetPinAddArguments {
    param([string]$PackageId, [string]$Version)
    $versionArgs = @()
    if ($Version) { $versionArgs = @('--version', $Version) }
    @('pin', 'add', '--id', $PackageId, '--exact') + $versionArgs + @('--accept-source-agreements', '--disable-interactivity')
}

# rustup-init に渡す引数 (winget の --custom。rustup-init の -y -q の後ろに足される)。MSVC の host にし、toolchain は入れない
function Get-RustupInitArgument {
    "--default-host $script:RustHost --default-toolchain none"
}

# 入れる道具。並びは入れる順 (rustup-init が MSVC の有無を見るので、Build Tools を rustup より先に)。gh は -Private のときだけ。
# AccountAdmin は普段のアカウントが管理者か (PowerShell 7 の入れ方を決める。Test-AccountAdmin)
function Get-BootstrapPackages {
    param([string]$GitVersion, [string]$GhVersion, [string]$PwshVersion, [string]$VsBuildToolsVersion, [string]$RustupVersion, [switch]$Private, [bool]$AccountAdmin)
    # パッケージ ID は 1 行ずつの変数に書く (nix/scripts/check-winget-version.sh がこの行を読む)
    $gitPackageId = 'Git.Git'
    $ghPackageId = 'GitHub.cli'
    $pwshPackageId = 'Microsoft.PowerShell'
    $vsBuildToolsPackageId = 'Microsoft.VisualStudio.2022.BuildTools'
    $rustupPackageId = 'Rustlang.Rustup'
    $vsCustom = Get-VsInstallCustomArgument -Components @(Get-VsRequiredComponents)
    # Git は machine の scope (C:\Program Files\Git。インストーラーの選択肢は既定のまま)、gh は MSI (C:\Program Files\GitHub CLI。
    # zip の portable もある)、PowerShell 7 は普段のアカウントが管理者の PC なら MSIX (ユーザー単位。7.6 の winget の版は MSI もあるので、
    # msix を名指しする)、管理者でない PC なら MSI (マシン単位。UAC で別の管理者のアカウントに昇格した側でも起こせる。Microsoft Update の
    # 更新には入れない)、rustup は MSVC の host で toolchain を入れない (版は Rust の runner の rust-toolchain.toml が決める)。
    # Silent: gh の MSI は per-machine なので、管理者でない PowerShell から quiet (--silent → /quiet) で流すと UAC が出ずに落ちる
    # (Error 1925)。--silent を付けず、winget の既定 (/passive) で UAC を出させる (管理者でない PC の PowerShell 7 の MSI も同じ)。
    # Build Tools も --silent を付けず (--passive)、数 GB を落とす 10 分以上の間、進み具合の窓を出す (UAC は installer が自分で出す)。
    # Git の installer は自分で昇格し、管理者の PC の PowerShell 7 (MSIX) と rustup は user に入るので --silent でよい
    $pwshSilent = $true
    $pwshArgs = @('--installer-type', 'msix')
    if (-not $AccountAdmin) {
        $pwshSilent = $false
        $pwshArgs = @('--installer-type', 'wix', '--custom', (Get-PwshMsiCustomArgument))
    }
    # RetryElevated: 昇格していない winget が machine の scope の source を開けずに落ちたら (Test-WingetAccessDenied。入れたての Windows 11 の
    # winget v1.11.510)、同じ引数を昇格した winget で打ち直す。--scope machine で入れる Git だけ (ほかは scope を名指ししない)
    $all = @(
        [pscustomobject]@{ Name = 'git'; Title = 'Git for Windows'; PackageId = $gitPackageId; Version = $GitVersion; Silent = $true; Args = @('--scope', 'machine'); RetryElevated = $true }
        [pscustomobject]@{ Name = 'gh'; Title = 'GitHub CLI'; PackageId = $ghPackageId; Version = $GhVersion; Silent = $false; Args = @('--installer-type', 'wix'); RetryElevated = $false }
        [pscustomobject]@{ Name = 'pwsh'; Title = 'PowerShell 7'; PackageId = $pwshPackageId; Version = $PwshVersion; Silent = $pwshSilent; Args = $pwshArgs; RetryElevated = $false }
        [pscustomobject]@{ Name = 'vs-buildtools'; Title = 'Visual Studio Build Tools 2022'; PackageId = $vsBuildToolsPackageId; Version = $VsBuildToolsVersion; Silent = $false; Args = @('--custom', $vsCustom); RetryElevated = $false }
        [pscustomobject]@{ Name = 'rustup'; Title = 'rustup'; PackageId = $rustupPackageId; Version = $RustupVersion; Silent = $true; Args = @('--custom', (Get-RustupInitArgument)); RetryElevated = $false }
    )
    $all | Where-Object { $Private -or ($_.Name -ne 'gh') }
}

# clone する repo と置き場 (ghq の既定の root の下。後で ghq を入れても ghq root は同じ所を指す)。既定の形は public な dotfiles だけを
# 資格情報なしの HTTPS の URL で、-Private は 3 つを WSL と同じ ssh の URL で
function Get-RepoTargets {
    param([string]$GhqRoot, [switch]$Private)
    $root = $GhqRoot.TrimEnd('\')
    if (-not $Private) {
        return [pscustomobject]@{ Name = 'dotfiles'; Url = 'https://github.com/pollenjp/dotfiles.git'; Directory = "$root\github.com\pollenjp\dotfiles" }
    }
    foreach ($name in @('dotfiles', 'dotfiles-private', 'claude-skills')) {
        [pscustomobject]@{ Name = $name; Url = "git@github.com:pollenjp/$name.git"; Directory = "$root\github.com\pollenjp\$name" }
    }
}

# origin (設定ファイルの値) が、その repo の GitHub の URL (ssh・ssh://・https。.git の有無と大文字小文字は問わない) か
function Test-RepoOrigin {
    param([string]$Url, [string]$Owner, [string]$Repo)
    $u = "$Url".Trim()
    if (-not $u) { return $false }
    foreach ($form in @("git@github.com:$Owner/$Repo", "ssh://git@github.com/$Owner/$Repo", "https://github.com/$Owner/$Repo")) {
        # -eq は大文字小文字を区別しない (GitHub の owner と repo の名前と同じ)
        if (($u -eq $form) -or ($u -eq "$form.git")) { return $true }
    }
    $false
}

# clone の git の引数。github.com の credential helper を空にしてから gh を足し、GitHub の ssh の URL を https に読み替える組を -c で
# 渡す (dotfiles の nix/pkgs/git-gh と同じ組。~/.gitconfig は書かない。origin の URL は ssh のまま)。gh のパスは、git が helper を流す
# sh が読めるよう / にして一重引用符で囲む。clone -c core.autocrlf=false は、その repo の設定に残る
function Get-GitCloneArguments {
    param([string]$GhPath, [string]$Url, [string]$Directory)
    $gh = $GhPath -replace '\\', '/'
    @('-c', 'credential.https://github.com.helper=',
        '-c', "credential.https://github.com.helper=!'$gh' auth git-credential",
        '-c', 'url.https://github.com/.insteadOf=git@github.com:',
        'clone', '-c', 'core.autocrlf=false', $Url, $Directory)
}

# 既定の形の clone の git の引数。github.com の credential helper を空にし (Git Credential Manager を呼ばない。public な repo は資格情報を
# 求められない)、HTTPS の URL のまま clone する。clone -c core.autocrlf=false は、その repo の設定に残る
function Get-GitAnonymousCloneArguments {
    param([string]$Url, [string]$Directory)
    @('-c', 'credential.https://github.com.helper=', 'clone', '-c', 'core.autocrlf=false', $Url, $Directory)
}

# 揃え終えたときに出す、次に打つコマンド (runner の dotfiles 関数を clone から読み込み、dotfiles apply を流す)。dotfiles apply の手順
# powershell-profile が $PROFILE に読み込みの 1 行を足すので、2 回目からは新しい PowerShell で dotfiles を打てる。HostFile は手元の
# ホストの値の置き場、HostFileExists はそれがあるか
function Format-BootstrapNextSteps {
    param([string]$DotfilesDir, [switch]$Private, [string]$HostFile, [bool]$HostFileExists)
    # Windows のパスは字でつなぐ (Join-Path は、テストを流す Linux の pwsh で C: のドライブを探しに行く)
    $ps1 = "$($DotfilesDir.TrimEnd('\'))\win\powershell\dotfiles.ps1" -replace "'", "''"
    ''
    '次に打つ (PowerShell 7 の新しい窓で。この窓は PATH が古い):'
    "  . '$ps1'"
    '  dotfiles apply'
    if ($Private) {
        'ホストの値は dotfiles-private の win\hosts\<ユーザー>@<PC>.toml。無ければ dotfiles check が ⚠ を出し、apply は止まる (先に書く。書き方は dotfiles の win\README.md の「ホストの値」)'
        if ($HostFileExists) {
            "※ 手元のホストの値 ($HostFile) もある。dotfiles-private の win\hosts\ のファイルもあると、dotfiles apply は止まる (どちらを使うか決まらない)。dotfiles-private の値を使うなら、手元の host.toml を退ける"
        }
    } else {
        "ホストの値は $HostFile (minimum の雛形を写したもの)。使う道具は [tools] に 1 行ずつ足す (書き方は dotfiles の win\README.md の「ホストの値」)"
    }
}

# gh auth login の引数。ブラウザーで認める。--git-protocol ssh は、gh に ~/.gitconfig の credential helper を書かせないため
# (https を選ぶと、書くかを聞いてくる)。ssh の鍵は作らない・上げない。一回限りのコードは gh がクリップボードに入れる (--clipboard。
# 手で写そうとして Ctrl+C を押すと、gh が止まる)
function Get-GhLoginArguments {
    @('auth', 'login', '--hostname', 'github.com', '--web', '--clipboard', '--git-protocol', 'ssh', '--skip-ssh-key')
}

# 状態の表の 1 行。Kind は直すことの種類 ('' = 直すことが無い、missing = 入っていない・無い (流せば入れる・作る)、fix = 足りない
# (流せば足す)、manual = bootstrap では直らない、blocker = 止める理由)。Note は表の後ろに出す ※ の行
function New-BootstrapRow {
    param([string]$Label, [string]$Text, [string]$Kind, [string]$Note)
    [pscustomobject]@{ Label = $Label; Text = $Text; Kind = $Kind; Note = $Note }
}

# PowerShell 7 の行。入れ方を問わず、$script:PwshMinimumVersion より古くなければ揃っている (固定した版と比べず、pin も見ない。Microsoft
# Store が上げる MSIX もあるため)。PATH の外でだけ見つかったときは、runner と herdr が起こせないので直すことにする。
# 普段のアカウントが管理者でない PC (AccountAdmin が $false) は、入れるのが MSI で、MSIX でない pwsh (PATH のディレクトリ・MSI の置き場所) が
# 無ければ入っていないもの (流せば MSI を足す) にする (Test-PwshInstallNeeded)
function Get-PwshRow {
    param($Package, [bool]$AccountAdmin)
    $msiNote = '※ 普段のアカウントが管理者でない PC では、UAC で別の管理者のアカウントの資格情報を入れて昇格する。MSIX の PowerShell 7 は使う人ごとに登録されるので、昇格した側 (そのアカウント) では起こせず、Install-OpenSSH・Install-Sshd が自分を昇格し直せない。MSI はマシン単位に入り、どのアカウントからも起こせる (win/README.md の「PowerShell 7 の MSIX の限り」)'
    if (-not $Package.Exists) {
        if (-not $AccountAdmin) {
            return New-BootstrapRow $Package.Title "入っていない → $($Package.Target) を winget の MSI で入れる (管理者でない PC。マシン単位に入り、UAC で管理者の資格情報を入れる)" 'missing' $msiNote
        }
        return New-BootstrapRow $Package.Title "入っていない → $($Package.Target) を winget の MSIX で入れる (ユーザー単位。UAC は出ない)" 'missing' ''
    }
    $how = Format-PwshInstallKind -Kind $Package.Kind -Path $Package.Path
    if (Test-PwshInstallNeeded -Package $Package -AccountAdmin $AccountAdmin) {
        # 管理者でない PC で MSIX しか無い。古い・PATH の外でも、MSI を足せばマシンの PATH の MSI が先に当たる
        $found = "$($Package.Installed)"
        if (-not $found) { $found = '版が読めない' }
        return New-BootstrapRow $Package.Title "$found ($how) → 管理者でない PC なので、MSI の $($Package.Target) も入れる (UAC で管理者の資格情報を入れる)" 'missing' $msiNote
    }
    # 外してから流し直すときに入る形 (管理者の PC は MSIX、管理者でない PC は MSI)
    $reinstall = 'winget の MSIX'
    if (-not $AccountAdmin) { $reinstall = 'winget の MSI' }
    if (-not $Package.Installed) {
        return New-BootstrapRow $Package.Title "入っているが版が読めない ($how)" 'manual' "※ PowerShell 7 ($($Package.Path)) の版が読めない。--version で確かめる ($script:PwshMinimumVersion より古くなければ、入れ方は問わない)"
    }
    if (-not (Test-PwshVersionAccepted -Version $Package.Installed)) {
        return New-BootstrapRow $Package.Title "$($Package.Installed) ($how) → $script:PwshMinimumVersion より古い" 'manual' "※ PowerShell 7 ($($Package.Path)) が古い。入れた形のまま上げる (MSI は winget upgrade --id $($Package.PackageId) --exact --version $($Package.Target) --include-pinned --installer-type wix で、UAC が出る。Microsoft Store の MSIX は Store のライブラリで更新する) か、外してから流し直す ($reinstall で $($Package.Target) を入れる)"
    }
    if (-not $Package.OnPath) {
        return New-BootstrapRow $Package.Title "$($Package.Installed) ($how) → PATH に無い" 'manual' "※ PowerShell 7 ($($Package.Path)) のディレクトリが PATH に無い (runner と herdr は PATH の pwsh を起こす)。ユーザーの環境変数 Path に足す"
    }
    New-BootstrapRow $Package.Title "$($Package.Installed) ($how)" '' ''
}

# 状態から表の行を作る。状態の形は Get-BootstrapState (テストでは New-State) が返すもの
function Get-BootstrapRows {
    param($State)
    $sacNote = '※ Smart App Control は、Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 でオフにする (Windows によっては、戻すのに再インストールが要る)'
    # SAC がオフでなくても止めない (ユーザーの決まり。最初の警告と、この行の ⚠ で知らせる)
    switch ($State.Sac) {
        'on' { New-BootstrapRow 'Smart App Control' 'オン → オフにする (cargo の産物の exe が止められ、Rust の runner を作れない)' 'manual' $sacNote }
        'eval' { New-BootstrapRow 'Smart App Control' '評価モード → オフにする (今は止めないが、いつオンに変わるか分からない)' 'manual' $sacNote }
        'off' { New-BootstrapRow 'Smart App Control' 'オフ' '' '' }
        default { New-BootstrapRow 'Smart App Control' 'この Windows には無い' '' '' }
    }
    if ($State.Elevated) {
        New-BootstrapRow '管理者の権限' '有り → 普通の (管理者でない) PowerShell で流し直す (clone と rustup が管理者の持ち物になる)' 'blocker' ''
    } else {
        New-BootstrapRow '管理者の権限' '無し (普通の PowerShell)' '' ''
    }
    if ($State.Arch -eq 'AMD64') {
        New-BootstrapRow 'CPU' 'x64' '' ''
    } else {
        New-BootstrapRow 'CPU' "$($State.Arch) → 対象外 (x64 だけ。Rust は MSVC の host $script:RustHost を使う)" 'blocker' ''
    }
    foreach ($p in @($State.Packages)) {
        if ($p.Name -eq 'pwsh') {
            Get-PwshRow -Package $p -AccountAdmin ([bool]$State.AccountAdmin)
            continue
        }
        if (-not $p.Exists) {
            New-BootstrapRow $p.Title "入っていない → $($p.Target) を入れる" 'missing' ''
            continue
        }
        $hostText = ''
        if ($p.Name -eq 'rustup') {
            if ($p.DefaultHost) { $hostText = " (既定の host は $($p.DefaultHost))" } else { $hostText = ' (既定の host が読めない)' }
        }
        if (-not $p.Installed) {
            New-BootstrapRow $p.Title "入っているが版が読めない (固定した版は $($p.Target))" 'manual' "※ $($p.Title) の版が読めない。winget uninstall --id $($p.PackageId) の後に流し直すと、固定した版で入れ直す"
        } elseif ($p.Installed -cne $p.Target) {
            # 版を名指しした winget upgrade は、--include-pinned が無いと bootstrap が足した pin (Pinning) に止められる (0x8A150068)。
            # rustup は winget upgrade でも rustup-init が走るので、MSVC の host と toolchain を入れない引数をもう一度渡す
            $extra = ''
            if ($p.Name -eq 'rustup') { $extra = " --custom `"$(Get-RustupInitArgument)`"" }
            New-BootstrapRow $p.Title "$($p.Installed) (固定した版は $($p.Target))" 'manual' "※ $($p.Title) を固定した版に揃えるのは bootstrap ではしない。上げるなら winget upgrade --id $($p.PackageId) --exact --version $($p.Target) --include-pinned$extra、下げるなら winget uninstall --id $($p.PackageId) の後に流し直す"
        } else {
            New-BootstrapRow $p.Title "$($p.Installed)$hostText" '' ''
        }
        if (-not $p.Pinned) { New-BootstrapRow "$($p.Title) の pin" '無し → 足す (winget upgrade --all から外す)' 'fix' '' }
        $lacking = @($p.MissingComponents | Where-Object { $_ })
        if ($lacking.Count -gt 0) { New-BootstrapRow 'Build Tools の部品' "足りない: $($lacking -join '・') → Visual Studio Installer で足す (UAC)" 'fix' '' }
        if ($p.Name -eq 'rustup') {
            if (-not $p.SelfUpdateDisabled) { New-BootstrapRow 'rustup の自己更新' '有効 → 止める (rustup set auto-self-update disable)' 'fix' '' }
            if ("$($p.DefaultHost)" -ne $script:RustHost) {
                $current = "$($p.DefaultHost)"
                if (-not $current) { $current = '読めない' }
                New-BootstrapRow 'rustup の既定の host' "$current → $script:RustHost にする (rustup set default-host $script:RustHost)" 'fix' ''
            }
        }
    }
    # gh のログインは -Private の形だけ (既定の形は gh を使わない)
    if ($State.Private) {
        if ($null -eq $State.GhLoggedIn) {
            New-BootstrapRow 'gh のログイン' 'gh を入れた後にログインする (ブラウザーで認める)' 'missing' ''
        } elseif (-not $State.GhLoggedIn) {
            New-BootstrapRow 'gh のログイン' 'していない → gh auth login で github.com にログインする (ブラウザーで認める)' 'fix' ''
        } else {
            New-BootstrapRow 'gh のログイン' 'github.com にログインしている' '' ''
        }
    }
    foreach ($r in @($State.Repos)) {
        switch ($r.State) {
            'missing' { New-BootstrapRow $r.Name "無い → $($r.Directory) に clone する" 'missing' '' }
            'unknown' { New-BootstrapRow $r.Name "$($r.Directory) はあるが、git が無いので確かめられない (Git for Windows を入れた後に確かめる)" 'missing' '' }
            'not-git' { New-BootstrapRow $r.Name "$($r.Directory) は git の repo ではない" 'manual' "※ $($r.Directory) を退けて (名前を変えるか消して) 流し直すと clone する" }
            'other-origin' { New-BootstrapRow $r.Name "origin が $($r.Origin) ($($r.Url) ではない)" 'manual' "※ $($r.Directory) は別の repo の clone。退けて流し直すと clone する" }
            'autocrlf' { New-BootstrapRow $r.Name "core.autocrlf が $($r.AutoCrlf) (false でないと、WSL が配ったものとバイト列がずれる)" 'manual' "※ $($r.Directory) を退けて流し直すと、core.autocrlf=false で clone し直す" }
            default { New-BootstrapRow $r.Name $r.Directory '' '' }
        }
    }
    # 手元のホストの値 (既定の形だけ。-Private はホストの値を dotfiles-private から引く)
    if ((-not $State.Private) -and $State.HostFile) {
        if ($State.HostFile.Exists) {
            New-BootstrapRow 'ホストの値 (手元)' $State.HostFile.Path '' ''
        } elseif ($State.HostFile.PrivateClone) {
            New-BootstrapRow 'ホストの値 (手元)' '写さない (dotfiles-private の clone がある。ホストの値はそこから引く)' '' ''
        } else {
            New-BootstrapRow 'ホストの値 (手元)' "無い → 雛形 (win\templates\host.minimum.toml) を $($State.HostFile.Path) に写す" 'missing' ''
        }
    }
}

# 最初に出す SAC の警告 (オフでなければ出す。bootstrap は止めずに続ける)。オフ・この Windows に無いときは何も返さない
function Format-SacWarning {
    param([string]$Sac)
    $where = '   オフにする場所: Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 (Windows によっては、戻すのに再インストールが要る)'
    switch ($Sac) {
        'on' {
            '⚠️ Smart App Control がオンになっている。cargo が作った exe (Rust の runner・build script) は止められて動かないので、Rust の runner を流す前にオフにする (bootstrap はこのまま続ける)'
            $where
        }
        'eval' {
            '⚠️ Smart App Control が評価モードになっている。いつオンに変わるか分からず、オンになると cargo が作った exe が止められるので、オフにしておく (bootstrap はこのまま続ける)'
            $where
        }
    }
}

# 終了コード。直すことが無ければ 0、入っていない・無いものだけなら 3 (流せば揃う)、ほかは 1
function Get-BootstrapExitCode {
    param([object[]]$Rows)
    $kinds = @($Rows | Where-Object { $_.Kind } | ForEach-Object { $_.Kind })
    if ($kinds.Count -eq 0) { return 0 }
    if (@($kinds | Where-Object { $_ -ne 'missing' }).Count -eq 0) { return 3 }
    1
}

# 表の文字の行。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。※ の行は表の後ろにまとめる
function Format-BootstrapRows {
    param([object[]]$Rows)
    foreach ($r in $Rows) {
        $prefix = '  '
        if ($r.Kind) { $prefix = '⚠ ' }
        "$prefix$($r.Label) : $($r.Text)"
    }
    foreach ($r in $Rows) {
        if ($r.Note) { $r.Note }
    }
}

# 締めの行 (⚠️ で始めて ⚠️ で終える)。直すことが無ければ何も返さない。止める理由があれば、それだけを返す。
# 行は種類ごとに分ける (今の Install-*.ps1 の「入っていない → 入れる」と「揃っていない → 揃える」と同じ)。入っていない・無い (missing)
# だけなら終了コード 3、足りない・ずれている (fix。流せば直る) や bootstrap では直らない差 (manual) があれば 1 なので、その行も並べる
function Format-BootstrapVerdict {
    param([object[]]$Rows)
    $kinds = @($Rows | Where-Object { $_.Kind } | ForEach-Object { $_.Kind })
    if ($kinds -contains 'blocker') {
        '⚠️ 止める理由があるので何も変えていない → ⚠ の行と ※ の手順で直してから流し直す ⚠️'
        return
    }
    if ($kinds -contains 'missing') { '⚠️ 入っていない・無いものがある → 引数なしで流すと揃える ⚠️' }
    if ($kinds -contains 'fix') { '⚠️ 足りないもの・ずれているものがある → 引数なしで流すと直す ⚠️' }
    if ($kinds -contains 'manual') { '⚠️ bootstrap では直らない差がある → ※ の手順で直す ⚠️' }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる。テストでは偽物に差し替える)
# ---------------------------------------------------------------------------

function Test-WingetAvailable {
    [bool](Get-Command winget -ErrorAction SilentlyContinue)
}

# CPU。32 ビットの PowerShell でも OS の CPU を返す (AMD64・ARM64 など)
function Get-OsArchitecture {
    $a = $env:PROCESSOR_ARCHITEW6432
    if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
    "$a".ToUpperInvariant()
}

# 道具の置き場所。Git・gh は machine の scope の既定の置き場所、PowerShell 7 は MSI の既定の置き場所と MSIX の実行エイリアス (どちらも
# PATH の pwsh の後ろに見る。Get-PwshCandidates)、rustup は CARGO_HOME (無ければ %USERPROFILE%\.cargo) の下、vswhere と Visual Studio
# Installer は Program Files (x86) の下。手元のホストの値は %USERPROFILE%\.config\dotfiles\host.toml。
# 32 ビットの PowerShell では ProgramFiles が (x86) を指すので、64 ビットの方 (ProgramW6432) を先に見る
function Get-BootstrapPaths {
    $cargoHome = $env:CARGO_HOME
    if (-not $cargoHome) { $cargoHome = Join-Path $env:USERPROFILE '.cargo' }
    $rustupHome = $env:RUSTUP_HOME
    if (-not $rustupHome) { $rustupHome = Join-Path $env:USERPROFILE '.rustup' }
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) { $localAppData = Join-Path $env:USERPROFILE 'AppData\Local' }
    $programFiles = $env:ProgramW6432
    if (-not $programFiles) { $programFiles = $env:ProgramFiles }
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if (-not $programFilesX86) { $programFilesX86 = $programFiles }
    $installer = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer'
    [pscustomobject]@{
        Git            = Join-Path $programFiles 'Git\cmd\git.exe'
        Gh             = Join-Path $programFiles 'GitHub CLI\gh.exe'
        Pwsh           = Join-Path $programFiles 'PowerShell\7\pwsh.exe'
        PwshAlias      = Join-Path $localAppData 'Microsoft\WindowsApps\pwsh.exe'
        Rustup         = Join-Path $cargoHome 'bin\rustup.exe'
        RustupSettings = Join-Path $rustupHome 'settings.toml'
        VsWhere        = Join-Path $installer 'vswhere.exe'
        VsSetup        = Join-Path $installer 'setup.exe'
        GhqRoot        = Join-Path $env:USERPROFILE 'ghq'
        HostFile       = Join-Path $env:USERPROFILE '.config\dotfiles\host.toml'
    }
}

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す。winget は管へ UTF-8 で書くので、UTF-8 で読む (Invoke-Native -Utf8)。
# bootstrap は Windows PowerShell 5.1 の窓で流し、日本語の Windows のコンソールの既定は CP932 なので、そのまま読むと進み具合の帯 (█▒) が
# 「笆遺毎」に化けて除けず、日本語のメッセージ (取り消しの「…: 1602」も) も化ける
function Invoke-Winget {
    param([string[]]$Arguments)
    $r = Invoke-Native -FilePath 'winget' -Arguments $Arguments -Utf8
    [pscustomobject]@{ ExitCode = $r.ExitCode; Lines = @(Select-WingetOutputLines -Lines $r.Lines) }
}

# 昇格した winget で打つ (UAC の確認が 1 回出る。確認なしで昇格する設定の PC では出ない)。System32 の Windows PowerShell (同じユーザーが
# 差し替えられないもの) を Start-Process -Verb RunAs で昇格させ、Get-ElevatedWingetScript の本文を -EncodedCommand で渡す。昇格した側は
# 出力を一時ファイルに書き、winget の終了コードで終わる。こちらはその終了コードと、ファイルの行 (進み具合の表示は除く) を返す。UAC を断った・
# 起こせなかったときは、UAC で断ったなら終了コードを 1223 (ERROR_CANCELLED。取り消し)、ほか (UAC を出せない SSH の会話など) なら -1 にする
# (Get-ElevationFailureCode。Install-ClaudeDesktop.ps1 の Invoke-ElevatedWinget と同じ形で、取り消しと言うのは断ったときだけにした)。
# 待つのは昇格した PowerShell だけ (-Wait は付けず、handle を掴んで WaitForExit。5.1 の -Wait は子孫のプロセスまで待つ。Invoke-VsModify と同じ)
function Invoke-ElevatedWinget {
    param([string[]]$Arguments)
    $log = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-bootstrap-winget-{0}.log' -f [guid]::NewGuid().ToString('N'))
    $shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $encoded = ConvertTo-EncodedCommand -Script (Get-ElevatedWingetScript -Arguments $Arguments -LogPath $log)
    try {
        $p = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        $null = $p.Handle
        $p.WaitForExit()
    } catch {
        return [pscustomobject]@{ ExitCode = (Get-ElevationFailureCode -Exception $_.Exception); Lines = @("UAC: $($_.Exception.Message)") }
    }
    $lines = @()
    if (Test-Path -LiteralPath $log) {
        $lines = @(Select-WingetOutputLines -Lines @(Get-Content -LiteralPath $log -Encoding UTF8))
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Lines = $lines }
}

# exe を打ち、出力の行と終了コードを返す。起動できなければ終了コード -1。-Utf8 は、UTF-8 で書く exe (winget・vswhere -utf8) の出力を
# 読むあいだだけ、コンソールの文字コードを UTF-8 にする (日本語の Windows の既定は CP932)。もう UTF-8 なら替えない。コンソールの無い host で
# 替えられなければ、替えずに読む
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Utf8)
    $ErrorActionPreference = 'Continue'
    $saved = $null
    if ($Utf8) {
        try {
            if ([Console]::OutputEncoding.CodePage -ne 65001) {
                $current = [Console]::OutputEncoding
                [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
                $saved = $current
            }
        } catch {
            $saved = $null
        }
    }
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $lines = @("$($_.Exception.Message)")
        $code = -1
    } finally {
        if ($null -ne $saved) {
            try { [Console]::OutputEncoding = $saved } catch { }
        }
    }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}

# rustup を打つ。cwd に rust-toolchain.toml があっても toolchain を入れさせない (RUSTUP_AUTO_INSTALL=0)。rustup 1.29.3 は
# --version・show でも、入っていない active toolchain を入れにいく (-Check は何も変えない・bootstrap は toolchain を入れない)。
# rustup はどれもこれで打つ
function Invoke-Rustup {
    param([string]$RustupPath, [string[]]$Arguments)
    $saved = $env:RUSTUP_AUTO_INSTALL
    $env:RUSTUP_AUTO_INSTALL = '0'
    try {
        Invoke-Native -FilePath $RustupPath -Arguments $Arguments
    } finally {
        $env:RUSTUP_AUTO_INSTALL = $saved
    }
}

# clone を流す。git にも Git Credential Manager にも対話のプロンプトを出させない (取れなければ落ちて、締めの行で知らせる)
function Invoke-GitClone {
    param([string]$GitPath, [string[]]$Arguments)
    $savedPrompt = $env:GIT_TERMINAL_PROMPT
    $savedGcm = $env:GCM_INTERACTIVE
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'never'
    try {
        Invoke-Native -FilePath $GitPath -Arguments $Arguments
    } finally {
        $env:GIT_TERMINAL_PROMPT = $savedPrompt
        $env:GCM_INTERACTIVE = $savedGcm
    }
}

# 新しい窓の PATH (レジストリのマシン → ユーザーの Path を ; でつないだもの)
function Get-RegistryPathValue {
    (@([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }) -join ';'
}

# PATH をレジストリ (マシン → ユーザー) から読み直す。winget で入れた道具を、このプロセスと、ここから起こす git などから引けるように
function Update-ProcessPath {
    $env:Path = Get-RegistryPathValue
}

# 入っている Build Tools に部品を足す (Visual Studio Installer。UAC が出る)。終了コードを返す (3010 は再起動待ちで、足せている)。
# -Wait は使わない (5.1 の -Wait は子孫のプロセスまで待つ)。handle を先に掴んでから WaitForExit で setup.exe だけを待つ
function Invoke-VsModify {
    param([string]$VsSetup, [string]$InstallPath, [string[]]$Components)
    $argumentList = Get-VsModifyArgumentList -InstallPath $InstallPath -Components $Components
    try {
        $p = Start-Process -FilePath $VsSetup -ArgumentList $argumentList -Verb RunAs -PassThru
        $null = $p.Handle
        $p.WaitForExit()
        return $p.ExitCode
    } catch {
        Write-Host "Visual Studio Installer を起動できなかった (UAC を断った・見つからない): $($_.Exception.Message)"
        return -1
    }
}

# この PowerShell のプロセスだけ、Ctrl+C と Ctrl+Break を受け止めて何もしない (-Ignore $true) か、元に戻す (-Ignore $false)。
# kernel32 の SetConsoleCtrlHandler に handler を足す・外す (CTRL_C_EVENT = 0 と CTRL_BREAK_EVENT = 1 だけを受け止め、窓を閉じる・
# サインアウト・シャットダウンは既定の動きのまま)。Ctrl+C は同じコンソールのプロセスのどれにも届くので、足しておくと子の gh は
# 止まり、この script は止まらずに続きを流せる (足さないと、gh と一緒に script も黙って止まり、終了コードが 0 に見える)。
# 足せない・外せないとき (Add-Type が使えない Windows など) は $false
function Set-ConsoleBreakIgnored {
    param([bool]$Ignore)
    try {
        if (-not ('DotfilesBootstrap.ConsoleBreak' -as [type])) {
            # Windows PowerShell 5.1 の Add-Type は C# 5 で読むので、それより新しい書き方を使わない
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace DotfilesBootstrap
{
    public static class ConsoleBreak
    {
        private delegate bool HandlerRoutine(uint ctrlType);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

        private static readonly HandlerRoutine Handler = IgnoreBreak;

        private static bool IgnoreBreak(uint ctrlType)
        {
            return ctrlType == 0 || ctrlType == 1;
        }

        public static bool Set(bool ignore)
        {
            return SetConsoleCtrlHandler(Handler, ignore);
        }
    }
}
'@
        }
        return [bool]([DotfilesBootstrap.ConsoleBreak]::Set($Ignore))
    } catch {
        return $false
    }
}

# gh auth login を、このコンソールで対話で流す (一回限りのコードが出て、ブラウザーで認める)。終了コードを返す。
# & で呼ぶと関数の出力として stdout を受けることになり、gh が端末でないと見て対話をやめうるので、Start-Process でコンソールをそのまま渡す。
# -Wait は使わない (5.1 の -Wait は子孫のプロセスまで待つので、gh が開いたブラウザーを閉じるまで返らない)。handle を先に掴んでから
# WaitForExit で gh だけを待つ (掴まないと、終わった後に ExitCode が読めない)。
# 待つあいだは Ctrl+C を受け止める (Set-ConsoleBreakIgnored)。押すと gh だけが止まり (0 以外の終了コード)、続きの読み直しと締めの表を流せる
function Invoke-GhLogin {
    param([string]$GhPath)
    $ignored = Set-ConsoleBreakIgnored -Ignore $true
    try {
        $p = Start-Process -FilePath $GhPath -ArgumentList ((Get-GhLoginArguments) -join ' ') -NoNewWindow -PassThru
        $null = $p.Handle
        $p.WaitForExit()
        return $p.ExitCode
    } catch {
        Write-Host "gh を起動できなかった: $($_.Exception.Message)"
        return -1
    } finally {
        if ($ignored) { $null = Set-ConsoleBreakIgnored -Ignore $false }
    }
}

# 雛形 (clone の win\templates\host.minimum.toml) を手元のホストの値に写す (親のディレクトリを作る)。copied (写した)・no-template (clone に
# 雛形が無い。古い clone)・failed (写せなかった) を返す
function Copy-HostTemplate {
    param([string]$Template, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) { return 'no-template' }
    try {
        $parent = Split-Path -Parent $Destination
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $Template -Destination $Destination -ErrorAction Stop
        return 'copied'
    } catch {
        Write-Host "雛形を写せなかった ($Destination): $($_.Exception.Message)"
        return 'failed'
    }
}

# clone の置き場の親ディレクトリを作る (%USERPROFILE%\ghq\github.com\pollenjp)
function New-CloneParent {
    param([string]$Directory)
    $parent = Split-Path -Parent $Directory
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
}

# 管理者として動いているか (UAC で昇格したプロセス)
function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 普段のアカウントが管理者か。今のトークンのグループの SID (WindowsIdentity の Claims。UAC で権限を落としたトークンでも、BUILTIN\Administrators は
# deny-only のグループで入る) から決める (Test-AdministratorsSid)。読めなければ (Windows でない・例外) 管理者でないとみなす (MSI はどちらの PC
# でも動く)
function Test-AccountAdmin {
    $sids = @()
    try {
        $sids = @(Select-TokenGroupSids -Claims @([Security.Principal.WindowsIdentity]::GetCurrent().Claims))
    } catch {
        $sids = @()
    }
    Test-AdministratorsSid -Sids $sids
}

# Smart App Control の値を、レジストリと Defender から読む (どちらも管理者は要らない。読めなければ $null)
function Get-SmartAppControlRaw {
    $policy = $null
    try {
        $item = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop
        $policy = $item.VerifiedAndReputablePolicyState
    } catch {
        $policy = $null
    }
    $defender = $null
    if ($null -eq $policy) {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $prop = $mp.PSObject.Properties['SmartAppControlState']
            if ($prop) { $defender = "$($prop.Value)" }
        } catch {
            $defender = $null
        }
    }
    [pscustomobject]@{ PolicyState = $policy; DefenderState = $defender }
}

# 今の Smart App Control の状態 (off・on・eval・unavailable)
function Get-BootstrapSac {
    $raw = Get-SmartAppControlRaw
    Get-SmartAppControlState -PolicyState $raw.PolicyState -DefenderState $raw.DefenderState
}

# vswhere で Build Tools を読む (JSON の文字列。vswhere が無い・落ちたら空)
function Read-VsWhere {
    param([string]$VsWhere)
    if (-not (Test-Path -LiteralPath $VsWhere -PathType Leaf)) { return '' }
    $r = Invoke-Native -FilePath $VsWhere -Arguments @('-products', 'Microsoft.VisualStudio.Product.BuildTools', '-format', 'json', '-include', 'packages', '-utf8') -Utf8
    if ($r.ExitCode -ne 0) { return '' }
    $r.Lines -join "`n"
}

# git の設定の値を 1 つ読む (無ければ空)。core.autocrlf は system の設定 (Git for Windows の既定は true) も込みで読む
function Get-GitConfigValue {
    param([string]$GitPath, [string]$Directory, [string]$Key)
    $r = Invoke-Native -FilePath $GitPath -Arguments @('-C', $Directory, 'config', '--get', $Key)
    if ($r.ExitCode -ne 0) { return '' }
    "$(@($r.Lines)[0])".Trim()
}

# clone の置き場の状態 (missing・unknown・not-git・other-origin・autocrlf・ok)。あるものには触らない
function Get-RepoState {
    param($Target, [string]$GitPath, [bool]$HaveGit)
    $dir = $Target.Directory
    $state = 'ok'
    $origin = $null
    $crlf = $null
    if (-not (Test-Path -LiteralPath $dir)) {
        $state = 'missing'
    } elseif (-not $HaveGit) {
        $state = 'unknown'
    } elseif (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        $state = 'not-git'
    } else {
        # origin は設定ファイルの値を読む (git remote get-url は insteadOf を当てた後の URL を返す)
        $origin = Get-GitConfigValue -GitPath $GitPath -Directory $dir -Key 'remote.origin.url'
        $crlf = Get-GitConfigValue -GitPath $GitPath -Directory $dir -Key 'core.autocrlf'
        if (-not (Test-RepoOrigin -Url $origin -Owner 'pollenjp' -Repo $Target.Name)) {
            $state = 'other-origin'
        } elseif ($crlf -in @('true', 'yes', 'on', '1')) {
            # 取り出すときに LF を CRLF にするのは true だけ (input は取り出しを変えない。空は git の既定の false)
            $state = 'autocrlf'
        }
    }
    [pscustomobject]@{ Name = $Target.Name; Url = $Target.Url; Directory = $dir; State = $state; Origin = $origin; AutoCrlf = $crlf }
}

# 今の状態を読む (何も変えない。管理者は要らない)。-Private なら gh のログインを、既定の形なら手元のホストの値を読む。AccountAdmin は
# 普段のアカウントが管理者か (Test-AccountAdmin で 1 回読んだもの。状態に持たせ、PowerShell 7 の行を決める)
function Get-BootstrapState {
    param([object[]]$Packages, $Paths, [string]$Arch, [switch]$Private, [bool]$AccountAdmin)
    $states = foreach ($p in $Packages) {
        $exists = $false
        $installed = $null
        $installPath = $null
        $lacking = @()
        $selfUpdateDisabled = $true
        $defaultHost = $null
        $foundPath = $null
        $onPath = $false
        $kind = $null
        $nonMsix = $false
        switch ($p.Name) {
            'git' {
                $exists = Test-Path -LiteralPath $Paths.Git -PathType Leaf
                if ($exists) { $installed = Get-GitVersionFromOutput -Lines (Invoke-Native -FilePath $Paths.Git -Arguments @('--version')).Lines }
            }
            'gh' {
                $exists = Test-Path -LiteralPath $Paths.Gh -PathType Leaf
                if ($exists) { $installed = Get-GhVersionFromOutput -Lines (Invoke-Native -FilePath $Paths.Gh -Arguments @('--version')).Lines }
            }
            'pwsh' {
                # 入れ方を問わず、新しい窓の PATH で先に当たる pwsh を読む (PATH に無ければ、MSI の置き場所・MSIX の実行エイリアス)。
                # 後ろの候補も見て、MSIX でない pwsh (PATH のほかの形・MSI) があるかを控える (管理者でない PC は、無ければ MSI を足す)
                foreach ($c in @(Get-PwshCandidates -PathValue (Get-RegistryPathValue) -MsiPath $Paths.Pwsh -AliasPath $Paths.PwshAlias)) {
                    if (-not (Test-Path -LiteralPath $c.Path -PathType Leaf)) { continue }
                    $candidateKind = Get-PwshInstallKind -Path $c.Path -MsiPath $Paths.Pwsh
                    if (-not $exists) {
                        $exists = $true
                        $foundPath = $c.Path
                        $onPath = $c.OnPath
                        $kind = $candidateKind
                        $installed = Get-PwshVersionFromOutput -Lines (Invoke-Native -FilePath $c.Path -Arguments @('--version')).Lines
                    }
                    if ($candidateKind -ne 'msix') {
                        $nonMsix = $true
                        break
                    }
                }
            }
            'vs-buildtools' {
                $instance = Get-VsBuildToolsInstance -Json (Read-VsWhere -VsWhere $Paths.VsWhere) -Major 17
                if ($instance) {
                    $exists = $true
                    $installed = $instance.Version
                    $installPath = $instance.Path
                    $lacking = @(Get-VsMissingComponents -Installed $instance.Packages)
                }
            }
            'rustup' {
                $exists = Test-Path -LiteralPath $Paths.Rustup -PathType Leaf
                if ($exists) {
                    $installed = Get-RustupVersionFromOutput -Lines (Invoke-Rustup -RustupPath $Paths.Rustup -Arguments @('--version')).Lines
                    $settings = $null
                    if (Test-Path -LiteralPath $Paths.RustupSettings -PathType Leaf) { $settings = Get-Content -LiteralPath $Paths.RustupSettings -Raw }
                    $selfUpdateDisabled = Test-RustupSelfUpdateDisabled -SettingsText $settings
                    # 既定の host は、rustup が今使う値 (rustup show の Default host) を読む
                    $defaultHost = Get-RustupDefaultHost -Lines (Invoke-Rustup -RustupPath $Paths.Rustup -Arguments @('show')).Lines
                }
            }
        }
        # PowerShell 7 の pin は見ない (入れ方を問わず認める。bootstrap が入れたときだけ、入れた直後に足す)
        $pinned = $false
        if ($exists -and ($p.Name -ne 'pwsh')) {
            $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $p.PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
            $pinned = Test-WingetPinned -Lines $pins.Lines -PackageId $p.PackageId
        }
        [pscustomobject]@{
            Name = $p.Name; Title = $p.Title; PackageId = $p.PackageId; Target = $p.Version; Exists = [bool]$exists; Installed = $installed
            Pinned = $pinned; InstallPath = $installPath; MissingComponents = $lacking; SelfUpdateDisabled = [bool]$selfUpdateDisabled
            DefaultHost = $defaultHost; Path = $foundPath; OnPath = [bool]$onPath; Kind = $kind; NonMsix = [bool]$nonMsix
        }
    }
    $states = @($states)
    $git = @($states | Where-Object { $_.Name -eq 'git' })[0]
    # gh のログインは -Private の形だけ読む。gh が無ければ $null (入れた後にログインする)。gh auth status は token を GitHub に確かめる
    # (0 = ログインしている)
    $loggedIn = $null
    if ($Private) {
        $gh = @($states | Where-Object { $_.Name -eq 'gh' })[0]
        if ($gh.Exists) { $loggedIn = ((Invoke-Native -FilePath $Paths.Gh -Arguments @('auth', 'status', '--hostname', 'github.com')).ExitCode -eq 0) }
    }
    # 手元のホストの値と、dotfiles-private の clone があるか (既定の形は、どちらも無ければ雛形を写す。-Private は、手元の値があれば締めで知らせる)
    $hostFile = [pscustomobject]@{
        Path         = $Paths.HostFile
        Exists       = [bool](Test-Path -LiteralPath $Paths.HostFile)
        PrivateClone = [bool](Test-Path -LiteralPath (Join-Path $Paths.GhqRoot 'github.com\pollenjp\dotfiles-private'))
    }
    $repos = foreach ($t in @(Get-RepoTargets -GhqRoot $Paths.GhqRoot -Private:$Private)) { Get-RepoState -Target $t -GitPath $Paths.Git -HaveGit $git.Exists }
    [pscustomobject]@{
        Elevated     = [bool](Test-Elevated)
        AccountAdmin = [bool]$AccountAdmin
        Arch         = $Arch
        Sac          = Get-BootstrapSac
        Private      = [bool]$Private
        Packages     = $states
        GhLoggedIn   = $loggedIn
        Repos        = @($repos)
        HostFile     = $hostFile
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-BootstrapRows {
    param([object[]]$Rows)
    foreach ($line in @(Format-BootstrapRows -Rows $Rows)) {
        if ($line.StartsWith('⚠')) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line }
    }
}

# 締めの行を黄色で出す。直すことが無ければ何も出さない
function Write-BootstrapVerdict {
    param([object[]]$Rows)
    foreach ($line in @(Format-BootstrapVerdict -Rows $Rows)) { Write-Host $line -ForegroundColor Yellow }
}

# winget の出力の終わりの数行を字下げして出す
function Write-Tail {
    param([string[]]$Lines)
    $Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
}

# 揃え終えたときの、次に打つコマンドを出す (dotfiles の clone の場所と、手元のホストの値は状態から引く)
function Write-BootstrapNextSteps {
    param($State)
    $dotfiles = @($State.Repos | Where-Object { $_.Name -eq 'dotfiles' })[0]
    foreach ($line in @(Format-BootstrapNextSteps -DotfilesDir $dotfiles.Directory -Private:$State.Private -HostFile $State.HostFile.Path -HostFileExists $State.HostFile.Exists)) {
        Write-Host $line
    }
}

function Invoke-InstallBootstrap {
    param([string]$GitVersion, [string]$GhVersion, [string]$PwshVersion, [string]$VsBuildToolsVersion, [string]$RustupVersion, [switch]$Private, [switch]$Check)
    # 最初に SAC を確かめ、オフでなければ警告して続ける (止めない。オフにするのはユーザー)
    $sacWarning = @(Format-SacWarning -Sac (Get-BootstrapSac))
    if ($sacWarning.Count -gt 0) {
        foreach ($line in $sacWarning) { Write-Host $line -ForegroundColor Yellow }
        Write-Host ''
    }
    if (-not (Test-WingetAvailable)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる (更新する) と使えるようになる'
        return 2
    }
    $arch = Get-OsArchitecture
    # 普段のアカウントが管理者か (1 回だけ読む)。PowerShell 7 の入れ方 (管理者の PC は MSIX、管理者でない PC は MSI) と表の行を決める
    $accountAdmin = [bool](Test-AccountAdmin)
    $packages = @(Get-BootstrapPackages -GitVersion $GitVersion -GhVersion $GhVersion -PwshVersion $PwshVersion -VsBuildToolsVersion $VsBuildToolsVersion -RustupVersion $RustupVersion -Private:$Private -AccountAdmin $accountAdmin)
    $paths = Get-BootstrapPaths
    if ($Private) {
        Write-Host 'Windows の bootstrap (dotfiles の win/bootstrap/Install-Bootstrap.ps1 -Private。gh で github.com にログインし、dotfiles・dotfiles-private・claude-skills を clone する)'
    } else {
        Write-Host 'Windows の bootstrap (dotfiles の win/bootstrap/Install-Bootstrap.ps1。gh を使わず、public な dotfiles だけを clone する。private な repo も使う PC は -Private)'
    }

    $state = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch -Private:$Private -AccountAdmin $accountAdmin
    $rows = @(Get-BootstrapRows -State $state)
    Write-BootstrapRows -Rows $rows
    $code = Get-BootstrapExitCode -Rows $rows

    # -Check は何も変えない
    if ($Check) {
        if ($code -eq 0) { Write-Host '揃っている' }
        Write-BootstrapVerdict -Rows $rows
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        Write-BootstrapNextSteps -State $state
        return 0
    }
    # 止める理由 (管理者の PowerShell・x64 でない CPU) があれば、何も変えない
    if (@($rows | Where-Object { $_.Kind -eq 'blocker' }).Count -gt 0) {
        Write-BootstrapVerdict -Rows $rows
        return 1
    }

    # 1. 入っていない道具を、固定した版で入れる (入れた順に PATH を読み直す)。PowerShell 7 は、管理者でない PC で MSIX しか無ければ MSI も入れる
    foreach ($p in $packages) {
        $s = @($state.Packages | Where-Object { $_.Name -eq $p.Name })[0]
        if ($p.Name -eq 'pwsh') {
            if (-not (Test-PwshInstallNeeded -Package $s -AccountAdmin $accountAdmin)) { continue }
        } elseif ($s.Exists) {
            continue
        }
        $extra = @($p.Args)
        # MSIX しか無い管理者でない PC で MSI を足すときは、入っている MSIX に引かれて upgrade に替わらないよう、直に入れる
        if (($p.Name -eq 'pwsh') -and (Test-PwshForceInstall -Package $s -AccountAdmin $accountAdmin)) { $extra += '--force' }
        $arguments = @(Get-WingetInstallArguments -PackageId $p.PackageId -Version $p.Version -Silent $p.Silent -Extra $extra)
        Write-Host ''
        Write-Host "winget $($arguments -join ' ')"
        if ($p.Name -eq 'vs-buildtools') { Write-Host '  (Build Tools は数 GB を落として入れるので、10 分以上かかることがある。UAC と進み具合の窓が出る)' }
        if (($p.Name -eq 'pwsh') -and (-not $accountAdmin)) { Write-Host '  (管理者でない PC なので、PowerShell 7 は MSI (マシン単位) で入れる。UAC で管理者の資格情報を入れる)' }
        $result = Invoke-Winget -Arguments $arguments
        # 入れたての Windows 11 の winget (v1.11.510) は、昇格していないと machine の scope の source を開けずに落ちる (0x80070005)。Git
        # (machine の scope) だけ、同じ引数を昇格した winget で打ち直す。今動いている PC (新しい winget) は普通に入るので、昇格しない
        if ($p.RetryElevated -and (Test-WingetAccessDenied -ExitCode $result.ExitCode -Lines $result.Lines)) {
            Write-Tail -Lines $result.Lines
            Write-Host ('昇格していない winget が machine の scope を読めなかった (終了コード 0x{0:X8})。昇格した winget で入れ直す (UAC の確認が 1 回出る。出たら「はい」を押す。昇格した側の進み具合は出ず、終わるまで数分かかることがある)' -f $result.ExitCode)
            $result = Invoke-ElevatedWinget -Arguments $arguments
            # UAC で別の管理者のアカウントに昇格し、そのアカウントに winget が無かった: そのアカウントと登録の手を出す
            $missing = @($result.Lines | Where-Object { "$_" -match '^winget が見つからない \(昇格した側のアカウント: (.*)\)$' })
            if ($missing.Count -gt 0) {
                $account = $missing[0] -replace '^winget が見つからない \(昇格した側のアカウント: (.*)\)$', '$1'
                foreach ($line in @(Format-WingetMissingNote -Account $account)) { Write-Host "  $line" -ForegroundColor Yellow }
                $result = [pscustomobject]@{ ExitCode = $result.ExitCode; Lines = @($result.Lines | Where-Object { "$_" -notin $missing }) }
            }
        }
        Write-Tail -Lines $result.Lines
        if ($result.ExitCode -ne 0) {
            # 再起動待ち (Build Tools の 3010 など) でも 0 以外で返る。入ったかは読み直して決める
            Write-Host ('winget が 0 以外で終わった (終了コード 0x{0:X8})。入ったかは読み直して確かめる' -f $result.ExitCode)
            if (Test-WingetCancelled -ExitCode $result.ExitCode -Lines $result.Lines) {
                Write-Host "$($p.Title) のインストーラーが取り消された (UAC で「はい」を押さなかった・窓を閉じた)。流し直すと、もう一度入れる" -ForegroundColor Yellow
            }
        }
        # PowerShell 7 は、入れたときだけ固定した版の線に留める pin (gating) を足す (MSIX も MSI も。ほかの形で入っていた PowerShell 7 には
        # 足さない。線の中の新しい版は winget upgrade --all でも Microsoft Store でも上がってよい)。MSIX と MSI が並んで入っていても、--id を
        # 渡した pin add は入っているものを探さず、available の package (ID と source) に付けるので、1 つに決められずに落ちることは無い
        # (winget-cli の PinCommand.cpp)
        if (($p.Name -eq 'pwsh') -and ($result.ExitCode -eq 0)) {
            $pinVersion = Get-PwshPinVersion -Version $p.Version
            if ($pinVersion) {
                $pin = Invoke-Winget -Arguments (Get-WingetPinAddArguments -PackageId $p.PackageId -Version $pinVersion)
                if ($pin.ExitCode -eq 0) { Write-Host "$($p.Title): winget pin を足した ($pinVersion に留める。winget upgrade --all は 7.7 へ上げない)" }
                else { Write-Host ('{0}: winget pin add が失敗した (終了コード 0x{1:X8})' -f $p.Title, $pin.ExitCode) }
            }
        }
        Update-ProcessPath
    }

    # 2. 読み直して、入っている道具に pin・Build Tools の足りないもの・rustup の自己更新の止めと既定の host を足す (PowerShell 7 の pin は
    # 1 で入れたときだけ)
    $state = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch -Private:$Private -AccountAdmin $accountAdmin
    foreach ($s in @($state.Packages)) {
        if (-not $s.Exists) { continue }
        if ((-not $s.Pinned) -and ($s.Name -ne 'pwsh')) {
            $pin = Invoke-Winget -Arguments (Get-WingetPinAddArguments -PackageId $s.PackageId)
            if ($pin.ExitCode -eq 0) { Write-Host "$($s.Title): winget pin を足した (winget upgrade --all から外れる)" }
            else { Write-Host ('{0}: winget pin add が失敗した (終了コード 0x{1:X8})' -f $s.Title, $pin.ExitCode) }
        }
        $lacking = @($s.MissingComponents | Where-Object { $_ })
        if ($lacking.Count -gt 0) {
            Write-Host "Build Tools に足りないものを足す (Visual Studio Installer。UAC と進み具合の窓が出る): $($lacking -join ' ')"
            $vs = Invoke-VsModify -VsSetup $paths.VsSetup -InstallPath $s.InstallPath -Components $lacking
            if (($vs -ne 0) -and ($vs -ne 3010)) { Write-Host "Visual Studio Installer が失敗した (終了コード $vs)" }
        }
        if ($s.Name -ne 'rustup') { continue }
        if (-not $s.SelfUpdateDisabled) {
            $r = Invoke-Rustup -RustupPath $paths.Rustup -Arguments @('set', 'auto-self-update', 'disable')
            if ($r.ExitCode -eq 0) { Write-Host 'rustup: 自己更新を止めた (rustup update が rustup 自身を上げない)' }
            else { Write-Host "rustup: 自己更新を止められなかった (終了コード $($r.ExitCode))" }
        }
        if ("$($s.DefaultHost)" -ne $script:RustHost) {
            $r = Invoke-Rustup -RustupPath $paths.Rustup -Arguments @('set', 'default-host', $script:RustHost)
            if ($r.ExitCode -eq 0) { Write-Host "rustup: 既定の host を $script:RustHost にした" }
            else { Write-Host "rustup: 既定の host を変えられなかった (終了コード $($r.ExitCode))" }
        }
    }

    # 3. (-Private だけ) gh が github.com にログインしていなければ、ログインする (ブラウザーで認める)。したら読み直す。
    # 途中で止めても (Ctrl+C)、ここで止まらずに読み直しと締めの表まで流し、終了コード 1 で終える
    if ($Private) {
        $gh = @($state.Packages | Where-Object { $_.Name -eq 'gh' })[0]
        if ($gh.Exists -and ($state.GhLoggedIn -eq $false)) {
            Write-Host ''
            Write-Host 'gh を github.com にログインさせる。一回限りのコードはクリップボードに入るので、Enter で開いたブラウザーに貼り付けて認める (Ctrl+C は押さない。gh が止まる)'
            $login = Invoke-GhLogin -GhPath $paths.Gh
            if ($login -ne 0) {
                Write-Host ('gh のログインが終わらなかった (止めた・失敗した。終了コード 0x{0:X8})。clone はしない。流し直すと、ログインからやり直す' -f $login) -ForegroundColor Yellow
            }
            $state = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch -Private:$Private -AccountAdmin $accountAdmin
        }
    }

    # 4. 無い repo を clone する。-Private は gh の資格情報で HTTPS を通し (origin は ssh の URL のまま)、既定の形は public な dotfiles を
    # 資格情報なしの HTTPS で
    $missingRepos = @($state.Repos | Where-Object { $_.State -eq 'missing' })
    if ($missingRepos.Count -gt 0) {
        $git = @($state.Packages | Where-Object { $_.Name -eq 'git' })[0]
        $ready = $git.Exists
        if ($Private) {
            $gh = @($state.Packages | Where-Object { $_.Name -eq 'gh' })[0]
            $ready = $git.Exists -and $gh.Exists -and ($state.GhLoggedIn -eq $true)
        }
        if (-not $ready) {
            Write-Host ''
            if ($Private) {
                Write-Host 'Git for Windows か gh が入っていない・gh が github.com にログインしていないので、clone しない'
            } else {
                Write-Host 'Git for Windows が入っていないので、clone しない'
            }
        } else {
            foreach ($r in $missingRepos) {
                New-CloneParent -Directory $r.Directory
                Write-Host ''
                Write-Host "clone: $($r.Url) → $($r.Directory)"
                if ($Private) {
                    $cloneArgs = @(Get-GitCloneArguments -GhPath $paths.Gh -Url $r.Url -Directory $r.Directory)
                } else {
                    $cloneArgs = @(Get-GitAnonymousCloneArguments -Url $r.Url -Directory $r.Directory)
                }
                $result = Invoke-GitClone -GitPath $paths.Git -Arguments $cloneArgs
                if ($result.ExitCode -ne 0) {
                    Write-Tail -Lines $result.Lines
                    if ($Private) {
                        Write-Host "clone が失敗した (終了コード $($result.ExitCode))。gh auth status で、この repo を読めるアカウントか確かめる"
                    } else {
                        Write-Host "clone が失敗した (終了コード $($result.ExitCode))。github.com につながるか確かめる (プロキシの内側なら、git の http.proxy)"
                    }
                }
            }
        }
    }

    # 5. (既定の形だけ) 手元のホストの値が無く、dotfiles-private の clone も無ければ、clone の雛形を写す (あれば上書きしない)
    if (-not $Private) {
        $state = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch -Private:$Private -AccountAdmin $accountAdmin
        $dotfiles = @($state.Repos | Where-Object { $_.Name -eq 'dotfiles' })[0]
        if ((-not $state.HostFile.Exists) -and (-not $state.HostFile.PrivateClone) -and ($dotfiles.State -eq 'ok')) {
            $template = "$($dotfiles.Directory.TrimEnd('\'))\win\templates\host.minimum.toml"
            Write-Host ''
            switch (Copy-HostTemplate -Template $template -Destination $state.HostFile.Path) {
                'copied' { Write-Host "ホストの値の雛形を写した: $template → $($state.HostFile.Path) (設定グループ minimum。使う道具は [tools] に足す)" }
                'no-template' { Write-Host "dotfiles の clone に雛形が無い ($template)。clone が古いなら進めてから流し直す" -ForegroundColor Yellow }
            }
        }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch -Private:$Private -AccountAdmin $accountAdmin
    $rows = @(Get-BootstrapRows -State $after)
    Write-BootstrapRows -Rows $rows
    if ((Get-BootstrapExitCode -Rows $rows) -eq 0) {
        Write-Host '揃った'
        Write-BootstrapNextSteps -State $after
        return 0
    }
    Write-BootstrapVerdict -Rows $rows
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える。
# Ctrl+C で止めると catch を通らずに finally だけが流れ、そのままだと何も出さずに終了コード 0 で終わる (Windows PowerShell 5.1 の
# -File)。finally で止めたことを出し、終了コード 1 で終える (finally の exit は、Ctrl+C の止めより先に効く)
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    $exitCode = $null
    try {
        $exitCode = Invoke-InstallBootstrap -GitVersion $GitVersion -GhVersion $GhVersion -PwshVersion $PwshVersion -VsBuildToolsVersion $VsBuildToolsVersion -RustupVersion $RustupVersion -Private:$Private -Check:$Check
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        $exitCode = 2
    } finally {
        if ($null -eq $exitCode) {
            # 止めている最中の finally でも Write-Host は画面に出る (5.1 で確かめた)
            Write-Host ''
            Write-Host '⚠️ 途中で止めた (Ctrl+C)。終わっていないので、流し直す ⚠️' -ForegroundColor Yellow
            exit 1
        }
    }
    exit $exitCode
}
