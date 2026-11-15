<#
.SYNOPSIS
新しい Windows で最初に流す setup。Rust の runner を動かせるところまで (Git for Windows・GitHub CLI・Visual Studio Build Tools・
rustup と、dotfiles・dotfiles-private・claude-skills の clone) を揃える。

.DESCRIPTION
dotfiles の win/bootstrap/Install-Bootstrap.ps1。新しい Windows では GitHub の raw の URL からファイルに落として流し、clone した後は
clone の中のものを流す (win/README.md の「bootstrap (新しい Windows で最初に流す)」。経緯は dotfiles-private の
docs/adr/058_win_runner_bootstrap_*)。manifest では配らない。

すること (この順):
  1. 前提を見る: winget があるか・管理者の PowerShell でないか・CPU (x64 か ARM64)・Smart App Control (SAC)
  2. Git for Windows → GitHub CLI → Visual Studio Build Tools 2022 → rustup を、下の param の固定した版で winget から入れ、pin を
     足す (winget upgrade --all から外す)。Build Tools に足りない部品は Visual Studio Installer で足し、rustup は自己更新を止める
     (rustup-init が MSVC の有無を見るので、Build Tools を rustup より先に入れる)
  3. gh が github.com にログインしていなければ gh auth login を流す (ブラウザーで認める)
  4. dotfiles・dotfiles-private・claude-skills を %USERPROFILE%\ghq\github.com\pollenjp\ に clone する。gh の資格情報で HTTPS を通す組
     (dotfiles の nix/pkgs/git-gh と同じ) を -c で渡し、origin は WSL と同じ ssh の URL のまま。core.autocrlf=false で、WSL が配った
     ものとバイト列をそろえる。~/.gitconfig は書かない

入っている道具の版が固定した版と違っても揃えない (⚠ と ※ の手順を出すだけ。揃えるのは Rust の runner の受け持ち)。あるディレクトリと
clone には触らない (確かめるだけ。取得もしない)。

何も変えずに止めるとき: 管理者の PowerShell (clone と rustup が管理者の持ち物になり、普通の権限の git が dubious ownership で止まる)・
SAC がオン (cargo の産物の exe が止められ、Rust の runner を作れない)・知らない CPU。SAC の評価モードは ⚠ で知らせて進む。
UAC は winget と Visual Studio Installer が道具ごとに出す。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。新しい Windows には 5.1 しか
無いので、PowerShell 7 にしか無い書き方を使わない (Install-Bootstrap.Tests.ps1 が見る)。

.PARAMETER GitVersion
Git for Windows (winget の Git.Git) の固定する版。版を変えるときはここの既定値を変える (nix/scripts/check-winget-version.sh git が読む)。

.PARAMETER GhVersion
GitHub CLI (winget の GitHub.cli) の固定する版 (check-winget-version.sh gh が読む)。

.PARAMETER VsBuildToolsVersion
Visual Studio Build Tools 2022 (winget の Microsoft.VisualStudio.2022.BuildTools) の固定する版 (check-winget-version.sh vs-buildtools が読む)。

.PARAMETER RustupVersion
rustup (winget の Rustlang.Rustup) の固定する版 (check-winget-version.sh rustup が読む)。toolchain は入れない (Rust の runner の
rust-toolchain.toml が決める)。

.PARAMETER Check
今の状態を出すだけで、何も変えない。終了コードは 0 = 直すことが無い・3 = 入っていない・無いものだけ (流せば揃う)・
1 = ほかに直すことがある・2 = winget が無い・思わぬ例外。
#>
[CmdletBinding()]
param(
    [string]$GitVersion = '2.56.0.4',
    [string]$GhVersion = '2.103.3',
    [string]$VsBuildToolsVersion = '17.14.44',
    [string]$RustupVersion = '1.29.3',
    [switch]$Check
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Bootstrap.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# Windows SDK の部品。rustup 1.29.3 が自分で Visual Studio を入れるときと同じもの
$script:VsSdkComponent = 'Microsoft.VisualStudio.Component.Windows11SDK.26100'

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
# "<Major>." で始まる) を 1 つ選び、置き場所・版・入っている部品の ID を返す。無ければ $null。
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

# CPU (PROCESSOR_ARCHITECTURE の値) ごとの MSVC の部品。x64 と ARM64 のほかは返さない (対象外)
function Get-VsToolsComponent {
    param([string]$Arch)
    switch ($Arch) {
        'AMD64' { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
        'ARM64' { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' }
        default { }
    }
}

# Build Tools に入れる部品 (MSVC と Windows SDK)
function Get-VsRequiredComponents {
    param([string]$Arch)
    @((Get-VsToolsComponent -Arch $Arch), $script:VsSdkComponent) | Where-Object { $_ }
}

# 入っている部品のうち、足りないもの。Windows SDK は 10 か 11 の SDK のどれかがあれば足りたことにする (rustup と同じ考え)
function Get-VsMissingComponents {
    param([string[]]$Installed, [string]$Arch)
    $have = @($Installed | Where-Object { $_ })
    $tools = Get-VsToolsComponent -Arch $Arch
    if ($tools -and ($have -notcontains $tools)) { $tools }
    if (@($have | Where-Object { $_ -match '^Microsoft\.VisualStudio\.Component\.Windows1[01]SDK\.' }).Count -eq 0) { $script:VsSdkComponent }
}

# winget install の --custom に渡す、Build Tools の installer の引数 (英語の言語パック・再起動しない・部品)
function Get-VsInstallCustomArgument {
    param([string[]]$Components)
    $parts = @('--norestart', '--addProductLang', 'En-us')
    foreach ($c in $Components) { $parts += @('--add', $c) }
    $parts -join ' '
}

# 入っている Build Tools に部品を足す Visual Studio Installer (setup.exe) の引数。Start-Process の -ArgumentList は値を引用符で
# 囲まないので、空白を含む置き場は二重引用符で囲んだ 1 つの文字列にする
function Get-VsModifyArgumentList {
    param([string]$InstallPath, [string[]]$Components)
    $parts = @('modify', '--installPath', ('"{0}"' -f $InstallPath))
    foreach ($c in $Components) { $parts += @('--add', $c) }
    $parts += @('--quiet', '--norestart')
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

# winget pin list の出力に、その Id を列に持つ行があるか (Install-Herdr.ps1 と同じ)。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# 固定した版で入れる winget install の引数。道具ごとの引数 (scope・installer の種類・--custom) を後ろに足す
function Get-WingetInstallArguments {
    param([string]$PackageId, [string]$Version, [string[]]$Extra)
    @('install', '--id', $PackageId, '--exact', '--source', 'winget', '--silent', '--accept-source-agreements',
        '--disable-interactivity', '--version', $Version, '--accept-package-agreements') + @($Extra | Where-Object { $_ })
}

# 入れる道具。並びは入れる順 (rustup-init が MSVC の有無を見るので、Build Tools を rustup より先に)
function Get-BootstrapPackages {
    param([string]$GitVersion, [string]$GhVersion, [string]$VsBuildToolsVersion, [string]$RustupVersion, [string]$Arch)
    # パッケージ ID は 1 行ずつの変数に書く (nix/scripts/check-winget-version.sh がこの行を読む)
    $gitPackageId = 'Git.Git'
    $ghPackageId = 'GitHub.cli'
    $vsBuildToolsPackageId = 'Microsoft.VisualStudio.2022.BuildTools'
    $rustupPackageId = 'Rustlang.Rustup'
    $vsCustom = Get-VsInstallCustomArgument -Components @(Get-VsRequiredComponents -Arch $Arch)
    # Git は machine の scope (C:\Program Files\Git。インストーラーの選択肢は既定のまま)、gh は MSI (C:\Program Files\GitHub CLI。
    # zip の portable もある)、rustup は toolchain を入れない (版は Rust の runner の rust-toolchain.toml が決める)
    @(
        [pscustomobject]@{ Name = 'git'; Title = 'Git for Windows'; PackageId = $gitPackageId; Version = $GitVersion; Args = @('--scope', 'machine') }
        [pscustomobject]@{ Name = 'gh'; Title = 'GitHub CLI'; PackageId = $ghPackageId; Version = $GhVersion; Args = @('--installer-type', 'wix') }
        [pscustomobject]@{ Name = 'vs-buildtools'; Title = 'Visual Studio Build Tools 2022'; PackageId = $vsBuildToolsPackageId; Version = $VsBuildToolsVersion; Args = @('--custom', $vsCustom) }
        [pscustomobject]@{ Name = 'rustup'; Title = 'rustup'; PackageId = $rustupPackageId; Version = $RustupVersion; Args = @('--custom', '--default-toolchain none') }
    )
}

# clone する repo と置き場 (ghq の既定の root の下。後で ghq を入れても ghq root は同じ所を指す)
function Get-RepoTargets {
    param([string]$GhqRoot)
    $root = $GhqRoot.TrimEnd('\')
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

# 状態の表の 1 行。Kind は直すことの種類 ('' = 直すことが無い、missing = 入っていない・無い (流せば入れる・作る)、fix = 足りない
# (流せば足す)、manual = bootstrap では直らない、blocker = 止める理由)。Note は表の後ろに出す ※ の行
function New-BootstrapRow {
    param([string]$Label, [string]$Text, [string]$Kind, [string]$Note)
    [pscustomobject]@{ Label = $Label; Text = $Text; Kind = $Kind; Note = $Note }
}

# 状態から表の行を作る。状態の形は Get-BootstrapState (テストでは New-State) が返すもの
function Get-BootstrapRows {
    param($State)
    $sacNote = '※ Smart App Control は、Windows セキュリティ → アプリとブラウザーの制御 → スマート アプリ コントロールの設定 でオフにする (Windows によっては、戻すのに再インストールが要る)'
    switch ($State.Sac) {
        'on' { New-BootstrapRow 'Smart App Control' 'オン → オフにしてから流し直す (cargo の産物の exe が止められ、Rust の runner を作れない)' 'blocker' $sacNote }
        'eval' { New-BootstrapRow 'Smart App Control' '評価モード → オフにする (今は止めないが、いつオンに変わるか分からない)' 'manual' $sacNote }
        'off' { New-BootstrapRow 'Smart App Control' 'オフ' '' '' }
        default { New-BootstrapRow 'Smart App Control' 'この Windows には無い' '' '' }
    }
    if ($State.Elevated) {
        New-BootstrapRow '管理者の権限' '有り → 普通の (管理者でない) PowerShell で流し直す (clone と rustup が管理者の持ち物になる)' 'blocker' ''
    } else {
        New-BootstrapRow '管理者の権限' '無し (普通の PowerShell)' '' ''
    }
    switch ($State.Arch) {
        'AMD64' { New-BootstrapRow 'CPU' 'x64' '' '' }
        'ARM64' { New-BootstrapRow 'CPU' 'ARM64' '' '' }
        default { New-BootstrapRow 'CPU' "$($State.Arch) → 対象外 (x64 か ARM64 だけ)" 'blocker' '' }
    }
    foreach ($p in @($State.Packages)) {
        if (-not $p.Exists) {
            New-BootstrapRow $p.Title "入っていない → $($p.Target) を入れる" 'missing' ''
            continue
        }
        if (-not $p.Installed) {
            New-BootstrapRow $p.Title "入っているが版が読めない (固定した版は $($p.Target))" 'manual' "※ $($p.Title) の版が読めない。winget uninstall --id $($p.PackageId) の後に流し直すと、固定した版で入れ直す"
        } elseif ($p.Installed -cne $p.Target) {
            # rustup は winget upgrade でも rustup-init が走るので、toolchain を入れない引数をもう一度渡す
            $extra = ''
            if ($p.Name -eq 'rustup') { $extra = ' --custom "--default-toolchain none"' }
            New-BootstrapRow $p.Title "$($p.Installed) (固定した版は $($p.Target))" 'manual' "※ $($p.Title) を固定した版に揃えるのは bootstrap ではしない。上げるなら winget upgrade --id $($p.PackageId) --exact --version $($p.Target)$extra、下げるなら winget uninstall --id $($p.PackageId) の後に流し直す"
        } else {
            New-BootstrapRow $p.Title $p.Installed '' ''
        }
        if (-not $p.Pinned) { New-BootstrapRow "$($p.Title) の pin" '無し → 足す (winget upgrade --all から外す)' 'fix' '' }
        $lacking = @($p.MissingComponents | Where-Object { $_ })
        if ($lacking.Count -gt 0) { New-BootstrapRow 'Build Tools の部品' "足りない: $($lacking -join '・') → Visual Studio Installer で足す (UAC)" 'fix' '' }
        if (($p.Name -eq 'rustup') -and (-not $p.SelfUpdateDisabled)) { New-BootstrapRow 'rustup の自己更新' '有効 → 止める (rustup set auto-self-update disable)' 'fix' '' }
    }
    if ($null -eq $State.GhLoggedIn) {
        New-BootstrapRow 'gh のログイン' 'gh を入れた後にログインする (ブラウザーで認める)' 'missing' ''
    } elseif (-not $State.GhLoggedIn) {
        New-BootstrapRow 'gh のログイン' 'していない → gh auth login で github.com にログインする (ブラウザーで認める)' 'fix' ''
    } else {
        New-BootstrapRow 'gh のログイン' 'github.com にログインしている' '' ''
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

# 締めの行 (⚠️ で始めて ⚠️ で終える)。直すことが無ければ何も返さない。止める理由があれば、それだけを返す
function Format-BootstrapVerdict {
    param([object[]]$Rows)
    $kinds = @($Rows | Where-Object { $_.Kind } | ForEach-Object { $_.Kind })
    if ($kinds -contains 'blocker') {
        '⚠️ 止める理由があるので何も変えていない → ⚠ の行と ※ の手順で直してから流し直す ⚠️'
        return
    }
    if (($kinds -contains 'missing') -or ($kinds -contains 'fix')) { '⚠️ 入っていない・足りないものがある → 引数なしで流すと揃える ⚠️' }
    if ($kinds -contains 'manual') { '⚠️ bootstrap では直らない差がある → ※ の手順で直す ⚠️' }
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    exit 2
}
