<#
.SYNOPSIS
新しい Windows で最初に流す setup。Rust の runner を動かせるところまで (Git for Windows・GitHub CLI・Visual Studio Build Tools・
rustup と、dotfiles・dotfiles-private・claude-skills の clone) を揃える。

.DESCRIPTION
dotfiles の win/bootstrap/Install-Bootstrap.ps1。新しい Windows では GitHub の raw の URL からファイルに落として流し、clone した後は
clone の中のものを流す (win/README.md の「bootstrap (新しい Windows で最初に流す)」。経緯は dotfiles-private の
docs/adr/058_win_runner_bootstrap_*)。manifest では配らない。

すること (この順):
  0. 最初に Smart App Control (SAC) を確かめ、オフでなければ (オン・評価モード) 警告を出して続ける (止めない)。オンだと cargo が
     作った exe (Rust の runner・build script) が止められて動かないので、runner を流す前にオフにする (オフにするのはユーザー)
  1. 前提を見る: winget があるか・管理者の PowerShell でないか・CPU (x64 か ARM64)
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
知らない CPU。SAC がオフでないときは止めず、最初の警告と表の ⚠ の行で知らせる (終了コードは 1)。
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
今の状態を出すだけで、何も変えない (SAC の警告は同じく最初に出す)。終了コードは 0 = 直すことが無い・3 = 入っていない・無いものだけ (流せば揃う)・
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

# gh auth login の引数。ブラウザーで認める。--git-protocol ssh は、gh に ~/.gitconfig の credential helper を書かせないため
# (https を選ぶと、書くかを聞いてくる)。ssh の鍵は作らない・上げない
function Get-GhLoginArguments {
    @('auth', 'login', '--hostname', 'github.com', '--web', '--git-protocol', 'ssh', '--skip-ssh-key')
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

# 道具の置き場所。Git と gh は machine の scope の既定の置き場所、rustup は CARGO_HOME (無ければ %USERPROFILE%\.cargo) の下。
# 32 ビットの PowerShell では ProgramFiles が (x86) を指すので、64 ビットの方 (ProgramW6432) を先に見る
function Get-BootstrapPaths {
    $cargoHome = $env:CARGO_HOME
    if (-not $cargoHome) { $cargoHome = Join-Path $env:USERPROFILE '.cargo' }
    $rustupHome = $env:RUSTUP_HOME
    if (-not $rustupHome) { $rustupHome = Join-Path $env:USERPROFILE '.rustup' }
    $programFiles = $env:ProgramW6432
    if (-not $programFiles) { $programFiles = $env:ProgramFiles }
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if (-not $programFilesX86) { $programFilesX86 = $programFiles }
    $installer = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer'
    [pscustomobject]@{
        Git            = Join-Path $programFiles 'Git\cmd\git.exe'
        Gh             = Join-Path $programFiles 'GitHub CLI\gh.exe'
        Rustup         = Join-Path $cargoHome 'bin\rustup.exe'
        RustupSettings = Join-Path $rustupHome 'settings.toml'
        VsWhere        = Join-Path $installer 'vswhere.exe'
        VsSetup        = Join-Path $installer 'setup.exe'
        GhqRoot        = Join-Path $env:USERPROFILE 'ghq'
    }
}

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-Herdr.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# exe を打ち、出力の行と終了コードを返す。起動できなければ終了コード -1。-Utf8 は、UTF-8 で書く exe (vswhere -utf8) の出力を
# 読むあいだだけ、コンソールの文字コードを UTF-8 にする (日本語の Windows の既定は CP932)
function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [switch]$Utf8)
    $ErrorActionPreference = 'Continue'
    $saved = $null
    if ($Utf8) {
        $saved = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    }
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch {
        $lines = @("$($_.Exception.Message)")
        $code = -1
    } finally {
        if ($null -ne $saved) { [Console]::OutputEncoding = $saved }
    }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
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

# PATH をレジストリ (マシン → ユーザー) から読み直す。winget で入れた道具を、このプロセスと、ここから起こす git などから引けるように
function Update-ProcessPath {
    $parts = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }
    $env:Path = $parts -join ';'
}

# 入っている Build Tools に部品を足す (Visual Studio Installer。UAC が出る)。終了コードを返す (3010 は再起動待ちで、足せている)
function Invoke-VsModify {
    param([string]$VsSetup, [string]$InstallPath, [string[]]$Components)
    $argumentList = Get-VsModifyArgumentList -InstallPath $InstallPath -Components $Components
    try {
        $p = Start-Process -FilePath $VsSetup -ArgumentList $argumentList -Verb RunAs -Wait -PassThru
        return $p.ExitCode
    } catch {
        Write-Host "Visual Studio Installer を起動できなかった (UAC を断った・見つからない): $($_.Exception.Message)"
        return -1
    }
}

# gh auth login を、このコンソールで対話で流す (一回限りのコードが出て、ブラウザーで認める)。終了コードを返す。
# & で呼ぶと関数の出力として stdout を受けることになり、gh が端末でないと見て対話をやめうるので、Start-Process でコンソールをそのまま渡す
function Invoke-GhLogin {
    param([string]$GhPath)
    try {
        $p = Start-Process -FilePath $GhPath -ArgumentList ((Get-GhLoginArguments) -join ' ') -NoNewWindow -Wait -PassThru
        return $p.ExitCode
    } catch {
        Write-Host "gh を起動できなかった: $($_.Exception.Message)"
        return -1
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

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-BootstrapState {
    param([object[]]$Packages, $Paths, [string]$Arch)
    $states = foreach ($p in $Packages) {
        $exists = $false
        $installed = $null
        $installPath = $null
        $lacking = @()
        $selfUpdateDisabled = $true
        switch ($p.Name) {
            'git' {
                $exists = Test-Path -LiteralPath $Paths.Git -PathType Leaf
                if ($exists) { $installed = Get-GitVersionFromOutput -Lines (Invoke-Native -FilePath $Paths.Git -Arguments @('--version')).Lines }
            }
            'gh' {
                $exists = Test-Path -LiteralPath $Paths.Gh -PathType Leaf
                if ($exists) { $installed = Get-GhVersionFromOutput -Lines (Invoke-Native -FilePath $Paths.Gh -Arguments @('--version')).Lines }
            }
            'vs-buildtools' {
                $instance = Get-VsBuildToolsInstance -Json (Read-VsWhere -VsWhere $Paths.VsWhere) -Major 17
                if ($instance) {
                    $exists = $true
                    $installed = $instance.Version
                    $installPath = $instance.Path
                    $lacking = @(Get-VsMissingComponents -Installed $instance.Packages -Arch $Arch)
                }
            }
            'rustup' {
                $exists = Test-Path -LiteralPath $Paths.Rustup -PathType Leaf
                if ($exists) {
                    $installed = Get-RustupVersionFromOutput -Lines (Invoke-Native -FilePath $Paths.Rustup -Arguments @('--version')).Lines
                    $settings = $null
                    if (Test-Path -LiteralPath $Paths.RustupSettings -PathType Leaf) { $settings = Get-Content -LiteralPath $Paths.RustupSettings -Raw }
                    $selfUpdateDisabled = Test-RustupSelfUpdateDisabled -SettingsText $settings
                }
            }
        }
        $pinned = $false
        if ($exists) {
            $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $p.PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
            $pinned = Test-WingetPinned -Lines $pins.Lines -PackageId $p.PackageId
        }
        [pscustomobject]@{
            Name = $p.Name; Title = $p.Title; PackageId = $p.PackageId; Target = $p.Version; Exists = [bool]$exists; Installed = $installed
            Pinned = $pinned; InstallPath = $installPath; MissingComponents = $lacking; SelfUpdateDisabled = [bool]$selfUpdateDisabled
        }
    }
    $states = @($states)
    $git = @($states | Where-Object { $_.Name -eq 'git' })[0]
    $gh = @($states | Where-Object { $_.Name -eq 'gh' })[0]
    # gh が無ければ $null (入れた後にログインする)。gh auth status は token を GitHub に確かめる (0 = ログインしている)
    $loggedIn = $null
    if ($gh.Exists) { $loggedIn = ((Invoke-Native -FilePath $Paths.Gh -Arguments @('auth', 'status', '--hostname', 'github.com')).ExitCode -eq 0) }
    $repos = foreach ($t in @(Get-RepoTargets -GhqRoot $Paths.GhqRoot)) { Get-RepoState -Target $t -GitPath $Paths.Git -HaveGit $git.Exists }
    [pscustomobject]@{
        Elevated   = [bool](Test-Elevated)
        Arch       = $Arch
        Sac        = Get-BootstrapSac
        Packages   = $states
        GhLoggedIn = $loggedIn
        Repos      = @($repos)
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

function Invoke-InstallBootstrap {
    param([string]$GitVersion, [string]$GhVersion, [string]$VsBuildToolsVersion, [string]$RustupVersion, [switch]$Check)
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
    $packages = @(Get-BootstrapPackages -GitVersion $GitVersion -GhVersion $GhVersion -VsBuildToolsVersion $VsBuildToolsVersion -RustupVersion $RustupVersion -Arch $arch)
    $paths = Get-BootstrapPaths
    Write-Host 'Windows の bootstrap (dotfiles の win/bootstrap/Install-Bootstrap.ps1)'

    $state = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch
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
        return 0
    }
    # 止める理由 (管理者の PowerShell・知らない CPU) があれば、何も変えない
    if (@($rows | Where-Object { $_.Kind -eq 'blocker' }).Count -gt 0) {
        Write-BootstrapVerdict -Rows $rows
        return 1
    }

    # 1. 入っていない道具を、固定した版で入れる (入れた順に PATH を読み直す)
    foreach ($p in $packages) {
        $s = @($state.Packages | Where-Object { $_.Name -eq $p.Name })[0]
        if ($s.Exists) { continue }
        $arguments = @(Get-WingetInstallArguments -PackageId $p.PackageId -Version $p.Version -Extra $p.Args)
        Write-Host ''
        Write-Host "winget $($arguments -join ' ')"
        if ($p.Name -eq 'vs-buildtools') { Write-Host '  (Build Tools は数 GB を落として入れるので、10 分以上かかることがある。UAC が出る)' }
        $result = Invoke-Winget -Arguments $arguments
        Write-Tail -Lines $result.Lines
        if ($result.ExitCode -ne 0) {
            # 再起動待ち (Build Tools の 3010 など) でも 0 以外で返る。入ったかは読み直して決める
            Write-Host ('winget が 0 以外で終わった (終了コード 0x{0:X8})。入ったかは読み直して確かめる' -f $result.ExitCode)
        }
        Update-ProcessPath
    }

    # 2. 読み直して、入っている道具に pin・Build Tools の部品・rustup の自己更新の止めを足す
    $state = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch
    foreach ($s in @($state.Packages)) {
        if (-not $s.Exists) { continue }
        if (-not $s.Pinned) {
            $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $s.PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
            if ($pin.ExitCode -eq 0) { Write-Host "$($s.Title): winget pin を足した (winget upgrade --all から外れる)" }
            else { Write-Host ('{0}: winget pin add が失敗した (終了コード 0x{1:X8})' -f $s.Title, $pin.ExitCode) }
        }
        $lacking = @($s.MissingComponents | Where-Object { $_ })
        if ($lacking.Count -gt 0) {
            Write-Host "Build Tools に部品を足す (Visual Studio Installer。UAC が出る): $($lacking -join ' ')"
            $vs = Invoke-VsModify -VsSetup $paths.VsSetup -InstallPath $s.InstallPath -Components $lacking
            if (($vs -ne 0) -and ($vs -ne 3010)) { Write-Host "Visual Studio Installer が失敗した (終了コード $vs)" }
        }
        if (($s.Name -eq 'rustup') -and (-not $s.SelfUpdateDisabled)) {
            $r = Invoke-Native -FilePath $paths.Rustup -Arguments @('set', 'auto-self-update', 'disable')
            if ($r.ExitCode -eq 0) { Write-Host 'rustup: 自己更新を止めた (rustup update が rustup 自身を上げない)' }
            else { Write-Host "rustup: 自己更新を止められなかった (終了コード $($r.ExitCode))" }
        }
    }

    # 3. gh が github.com にログインしていなければ、ログインする (ブラウザーで認める)。したら読み直す
    $gh = @($state.Packages | Where-Object { $_.Name -eq 'gh' })[0]
    if ($gh.Exists -and ($state.GhLoggedIn -eq $false)) {
        Write-Host ''
        Write-Host 'gh を github.com にログインさせる。出てきた一回限りのコードを、ブラウザーで入れて認める'
        $login = Invoke-GhLogin -GhPath $paths.Gh
        if ($login -ne 0) { Write-Host "gh auth login が失敗した (終了コード $login)" }
        $state = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch
    }

    # 4. 無い repo を clone する (gh の資格情報で HTTPS。origin は ssh の URL のまま)
    $missingRepos = @($state.Repos | Where-Object { $_.State -eq 'missing' })
    if ($missingRepos.Count -gt 0) {
        $git = @($state.Packages | Where-Object { $_.Name -eq 'git' })[0]
        $gh = @($state.Packages | Where-Object { $_.Name -eq 'gh' })[0]
        if (-not ($git.Exists -and $gh.Exists -and ($state.GhLoggedIn -eq $true))) {
            Write-Host ''
            Write-Host 'Git for Windows か gh が入っていない・gh が github.com にログインしていないので、clone しない'
        } else {
            foreach ($r in $missingRepos) {
                New-CloneParent -Directory $r.Directory
                Write-Host ''
                Write-Host "clone: $($r.Url) → $($r.Directory)"
                $result = Invoke-GitClone -GitPath $paths.Git -Arguments @(Get-GitCloneArguments -GhPath $paths.Gh -Url $r.Url -Directory $r.Directory)
                if ($result.ExitCode -ne 0) {
                    Write-Tail -Lines $result.Lines
                    Write-Host "clone が失敗した (終了コード $($result.ExitCode))。gh auth status で、この repo を読めるアカウントか確かめる"
                }
            }
        }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-BootstrapState -Packages $packages -Paths $paths -Arch $arch
    $rows = @(Get-BootstrapRows -State $after)
    Write-BootstrapRows -Rows $rows
    if ((Get-BootstrapExitCode -Rows $rows) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    Write-BootstrapVerdict -Rows $rows
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallBootstrap -GitVersion $GitVersion -GhVersion $GhVersion -VsBuildToolsVersion $VsBuildToolsVersion -RustupVersion $RustupVersion -Check:$Check)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
