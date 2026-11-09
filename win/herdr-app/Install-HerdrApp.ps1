<#
.SYNOPSIS
Windows の herdr-app (herdr の desktop app) と herdr-core を、公式の install.ps1 と同じ置き場所・手順で入れる・外す。

.DESCRIPTION
dotfiles の win/herdr-app/Install-HerdrApp.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-HerdrApp から呼ぶ (win/README.md の「herdr-app」)。

herdr-app は winget に無く、公式の入れ方は irm https://releases.herdr.dev/app/install.ps1 | iex だけ。
遠くの script は流さず、公式の app の install.ps1 と、それが呼ぶ core の install.ps1 と同じことをここで踏む
(写した中身の sha256 は win/herdr-app/upstream-installers.txt。公式が変わると週 1 回の CI が知らせる):

- app: releases.herdr.dev/app/latest.json の windows-x86_64 の tar.gz を落として sha256 を確かめ、
  %LOCALAPPDATA%\Programs\herdr-app に置き、スタートメニューに Herdr.lnk を作り、置き場所をユーザーの PATH に足す
- core: %LOCALAPPDATA%\Programs\herdr-core\herdr-core.exe も PATH の herdr-core も無ければ、core/latest.json の zip を
  落として確かめ、同じ置き場所に herdr-core.exe と conpty を置き (hc が無ければ hc.exe を hard link で作る)、PATH に足す

版は固定しない。release の app は 1 時間ごとに自分で新しい版を落とし、再起動か終了のときにフォルダごと差し替え、
その後に core も hc update で上げる (止める設定は無い)。そこで dotfiles は入っているか (app・Herdr.lnk・PATH の行・core)
だけを見て、版は出すが比べない。管理者は要らず、アプリと機能 (ARP) には載らない。

公式と違えるところ: HERDR_RELEASES_URL・HC_VERSION・HC_INSTALL_DIR は読まない (テストと版の選び方のためのもの)。
core を入れられなかったときは、app は入れたまま終了コード 1 で知らせる (公式は「app が開いたときに勧める」と出して終わる)。
PATH の行は %VAR% を展開してから置き場所と比べる (公式は展開しないので、%VAR% で書いた行があると二重に足す)。
curl.exe は、つながらない・転送が止まったときに打ち切る (公式は待ち続ける)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Check
入っているかを出すだけで、何も変えない。揃っていれば終了コード 0、欠けているものがあれば 1、app が入っていなければ 3。

.PARAMETER IfMissing
app が入っていなければ入れる (core も無ければ入れる)。入っていれば -Check と同じで、欠けているものも足さない
(setup --update の bootstrap-windows-herdr-app.sh が使う)。付けないときは、欠けているものだけを足す。

.PARAMETER Uninstall
置いたもの (app と、その自己更新が隣に作るもの・Herdr.lnk・PATH の 2 行・core の置き場所) を外す。設定 (~/.config/herdr-app)
と core の状態・設定は残し、公式と違う置き場所 (winget など) のものには触らない。app か core が動いていれば、何も外さずに
止める (core を止めると terminal も終わるので、止めるのは人)。人が打つときだけ使う (setup は打たない)。
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$IfMissing,
    [switch]$Uninstall
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-HerdrApp.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 公式と同じく、32 bit の PowerShell から呼ばれても OS の arch を見る (PROCESSOR_ARCHITEW6432 が先)
function Get-HerdrAppArchitecture {
    param([string]$Architecture, [string]$Architecture6432)
    if ($Architecture6432) { return $Architecture6432 }
    $Architecture
}

# ConvertFrom-Json の結果から、名前の値を読む。無ければ $null (StrictMode では、無いプロパティを直に読むと例外になる)
function Get-HerdrAppJsonValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

# latest.json から、target の版・URL・sha256 を拾う。url か sha256 が無ければ $null
function Get-HerdrAppRelease {
    param($Manifest, [string]$Target)
    $entry = Get-HerdrAppJsonValue -Object (Get-HerdrAppJsonValue -Object $Manifest -Name 'targets') -Name $Target
    $url = Get-HerdrAppJsonValue -Object $entry -Name 'url'
    $sha256 = Get-HerdrAppJsonValue -Object $entry -Name 'sha256'
    if (-not $url -or -not $sha256) { return $null }
    [pscustomobject]@{ Version = (Get-HerdrAppJsonValue -Object $Manifest -Name 'version'); Url = "$url"; Sha256 = "$sha256" }
}

# 公式と同じく、releases の素の URL (? も # も無い) にだけ ?src= を付ける (release の server のダウンロードの数の印。中身は同じ)
function Get-HerdrAppDownloadUrl {
    param([string]$Url, [string]$Releases, [string]$Src)
    $plain = $Url.StartsWith("$Releases/", [StringComparison]::Ordinal) -and ($Url.IndexOfAny([char[]]'?#') -lt 0)
    if ($plain) { return "$($Url)?src=$Src" }
    $Url
}

# PATH の 1 つの要素が置き場所を指すか。前後の空白と " を落とし、%VAR% を展開し、末尾の \ を落としてから、
# 大文字小文字を区別せずに比べる
function Test-HerdrAppPathEntry {
    param([string]$Entry, [string]$Dir)
    $value = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\')
    if (-not $value) { return $false }
    $value -ieq $Dir.TrimEnd('\')
}

# PATH の生の値 (; 区切り) に、置き場所を指す要素があるか
function Test-HerdrAppPathListed {
    param([string]$Raw, [string]$Dir)
    foreach ($entry in ($Raw -split ';')) {
        if (Test-HerdrAppPathEntry -Entry $entry -Dir $Dir) { return $true }
    }
    $false
}

# 置き場所を末尾に足した PATH の生の値 (公式と同じ形: 末尾の ; を落として ;<置き場所>)。既にあれば変えない
function Get-PathValueWithEntry {
    param([string]$Raw, [string]$Dir)
    if (Test-HerdrAppPathListed -Raw $Raw -Dir $Dir) { return $Raw }
    if ($Raw) { return "$($Raw.TrimEnd(';'));$Dir" }
    $Dir
}

# 置き場所を指す要素を外した PATH の生の値。ほかの要素 (%VAR% の書き方・空の要素・末尾の ;) はそのまま残す
function Get-PathValueWithoutEntry {
    param([string]$Raw, [string[]]$Dirs)
    $kept = foreach ($entry in ($Raw -split ';')) {
        $ours = $false
        foreach ($dir in $Dirs) {
            if (Test-HerdrAppPathEntry -Entry $entry -Dir $dir) { $ours = $true }
        }
        if (-not $ours) { $entry }
    }
    @($kept) -join ';'
}

# <名前> --version の出力 ("herdr-app 0.1.14"・"hc 0.1.19") から版を拾う。無ければ $null
function Get-HerdrAppVersionFromOutput {
    param([string[]]$Lines, [string]$Name)
    foreach ($line in $Lines) {
        if ("$line" -match ('^\s*' + [regex]::Escape($Name) + '\s+(\S+)\s*$')) { return $Matches[1] }
    }
    $null
}

# app の置き場所と、自己更新が隣に作るもの (落として展開する .download・待っている .new と受け取りの .new.json・
# 入れ替えた古い .old)。-Uninstall はこれを外す
function Get-HerdrAppInstallPaths {
    param([string]$AppDir)
    $dir = $AppDir.TrimEnd('\')
    @($dir, "$dir.old", "$dir.new", "$dir.new.json", "$dir.download")
}

# 動いているかを見るディレクトリ (app の置き場所と隣のディレクトリ、core の置き場所)
function Get-HerdrAppWatchDirs {
    param([string]$AppDir, [string]$CoreDir)
    $dir = $AppDir.TrimEnd('\')
    @($dir, "$dir.old", "$dir.new", "$dir.download", $CoreDir.TrimEnd('\'))
}

# プロセスの実行ファイルが、どれかのディレクトリの下にあるか (大文字小文字を区別しない)
function Test-HerdrAppProcessPath {
    param([string]$Path, [string[]]$Dirs)
    if (-not $Path) { return $false }
    foreach ($dir in $Dirs) {
        if ($Path.StartsWith($dir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# ファイルの sha256 (小文字の hex)。公式と同じく .NET で求める (Get-FileHash は PowerShell 7 から 5.1 を起こすと落ちる)
function Get-HerdrAppFileSha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Close()
    }
}

# Herdr.lnk が app を指すか。ours (TargetPath が置き場所の herdr-app.exe) / other (別の場所・読めない) / missing
function Get-HerdrAppLnkKind {
    param([bool]$Exists, [string]$Target, [string]$Exe)
    if (-not $Exists) { return 'missing' }
    if ($Target -and ($Target -ieq $Exe)) { return 'ours' }
    'other'
}

# PATH (; 区切り) を前から見て、$Name が最初に見つかったパスを返す。無ければ $null。
# $Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Resolve-HerdrAppOnPath {
    param([string]$PathValue, [string]$Name, [scriptblock]$Exists)
    foreach ($entry in ($PathValue -split ';')) {
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if (-not $dir) { continue }
        $candidate = "$dir\$Name"
        if (& $Exists $candidate) { return $candidate }
    }
    $null
}

# core が揃っているか: 公式の置き場所にあれば PATH の行も要る。無ければ、公式と違う置き場所 (PATH) にあればよい
# (公式も、PATH に herdr-core があれば core を入れない)
function Test-HerdrCoreReady {
    param($State)
    if ($State.CoreExe) { return [bool]$State.CorePathListed }
    [bool]$State.CoreElsewhere
}

# 終了コード。app が無ければ 3、app・Herdr.lnk (app を指す)・app の PATH の行・core が揃っていれば 0、ほかは 1
function Get-HerdrAppExitCode {
    param($State)
    if (-not $State.AppExe) { return 3 }
    if (($State.LnkKind -eq 'ours') -and $State.AppPathListed -and (Test-HerdrCoreReady -State $State)) { return 0 }
    1
}

# 状態の表の 1 行。ラベルは全角 2 桁・半角 1 桁で数えて 16 桁にそろえる
function New-HerdrAppRow {
    param([string]$Key, [string]$Value, [bool]$Warn)
    $label = switch ($Key) {
        'Dir' { '置き場所        ' }
        'Version' { '入っている版    ' }
        'Menu' { 'スタートメニュー' }
        default { 'ユーザーの PATH ' }
    }
    $prefix = if ($Warn) { '⚠ ' } else { '  ' }
    [pscustomobject]@{ Text = "$prefix$label : $Value"; Warn = $Warn }
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。
# app が無いときの Herdr.lnk と PATH の行は ⚠ にしない (入れるときに作る)。版は出すが比べない
function Format-HerdrAppState {
    param($State, [string]$AppDir, [string]$CoreDir)
    $appMissing = -not $State.AppExe
    [pscustomobject]@{ Text = 'herdr-app (公式の install.ps1 と同じ置き場所。版は app が自分で上げる)'; Warn = $false }
    if ($appMissing) {
        New-HerdrAppRow -Key 'Dir' -Value "$AppDir → 入っていない (入れる)" -Warn $true
    } else {
        New-HerdrAppRow -Key 'Dir' -Value $AppDir -Warn $false
        $appVersion = if ($State.AppVersion) { $State.AppVersion } else { '不明 (herdr-app.exe --version が読めない)' }
        New-HerdrAppRow -Key 'Version' -Value $appVersion -Warn $false
    }
    $fix = -not $appMissing
    switch ($State.LnkKind) {
        'ours' { New-HerdrAppRow -Key 'Menu' -Value 'Herdr.lnk' -Warn $false }
        'other' {
            $target = if ($State.LnkTarget) { $State.LnkTarget } else { '読めない' }
            $tail = if ($fix) { ' → 作り直す' } else { '' }
            New-HerdrAppRow -Key 'Menu' -Value "Herdr.lnk が別の場所を指している ($target)$tail" -Warn $fix
        }
        default {
            $tail = if ($fix) { ' → 作る' } else { '' }
            New-HerdrAppRow -Key 'Menu' -Value "Herdr.lnk が無い$tail" -Warn $fix
        }
    }
    $appPath = if ($State.AppPathListed) { 'あり' } elseif ($fix) { '無し → 足す' } else { '無し' }
    New-HerdrAppRow -Key 'Path' -Value $appPath -Warn ($fix -and -not $State.AppPathListed)

    [pscustomobject]@{ Text = 'herdr-core (無ければ入れる。上げるのは app)'; Warn = $false }
    if ($State.CoreExe) {
        New-HerdrAppRow -Key 'Dir' -Value $CoreDir -Warn $false
        $coreVersion = if ($State.CoreVersion) { $State.CoreVersion } else { '不明 (herdr-core.exe --version が読めない)' }
        New-HerdrAppRow -Key 'Version' -Value $coreVersion -Warn $false
        $corePath = if ($State.CorePathListed) { 'あり' } else { '無し → 足す' }
        New-HerdrAppRow -Key 'Path' -Value $corePath -Warn (-not $State.CorePathListed)
    } elseif ($State.CoreElsewhere) {
        New-HerdrAppRow -Key 'Dir' -Value "公式の置き場所には無い。PATH の $($State.CoreElsewhere) を使う" -Warn $false
        [pscustomobject]@{ Text = '※ herdr-core は公式と違う置き場所にある (winget など)。dotfiles は入れず、-Uninstall も触らない'; Warn = $false }
    } else {
        New-HerdrAppRow -Key 'Dir' -Value "$CoreDir → 入っていない (入れる)" -Warn $true
    }
}

# -Uninstall で外すもの (Kind = remove: ファイルかディレクトリを消す / path: ユーザーの PATH の行を外す)。
# Herdr.lnk は app を指すときだけ、core は公式の置き場所にあるときだけ。公式と違う置き場所のものは入れない
function Get-HerdrAppUninstallPlan {
    param($State, [string]$AppDir, [string]$CoreDir, [string]$Menu)
    foreach ($path in @($State.AppPathsPresent)) {
        if ($path) { [pscustomobject]@{ Kind = 'remove'; Target = $path } }
    }
    if ($State.LnkKind -eq 'ours') { [pscustomobject]@{ Kind = 'remove'; Target = $Menu } }
    if ($State.AppPathListed) { [pscustomobject]@{ Kind = 'path'; Target = $AppDir } }
    if ($State.CoreDirExists) { [pscustomobject]@{ Kind = 'remove'; Target = $CoreDir } }
    if ($State.CorePathListed) { [pscustomobject]@{ Kind = 'path'; Target = $CoreDir } }
}

# -Uninstall が残したもの (あるものだけ)。$Exists はあるかを答える scriptblock (テストでは偽物を渡す)
function Format-HerdrAppKept {
    param($State, $Locations, [scriptblock]$Exists)
    if (& $Exists $Locations.AppHome) { "残した: $($Locations.AppHome) (設定と mod)" }
    if (& $Exists $Locations.CoreState) { "残した: $($Locations.CoreState) (herdr-core の状態)" }
    if (& $Exists $Locations.CoreConfig) { "残した: $($Locations.CoreConfig) (herdr-core の設定)" }
    if ($State.LnkKind -eq 'other') {
        $target = if ($State.LnkTarget) { $State.LnkTarget } else { '読めない場所' }
        "残した: $($Locations.Menu) ($target を指している)"
    }
    if ((-not $State.CoreExe) -and $State.CoreElsewhere) { "残した: $($State.CoreElsewhere) (公式と違う置き場所の herdr-core)" }
}

# 動いているプロセスの行と、止め方。core を止めると、その中の terminal も終わる
function Format-HerdrAppBusy {
    param([object[]]$Processes, [string]$CoreDir)
    $list = @($Processes)
    # パスが読めないものは名前で分ける (Test-HerdrAppBusyEntry と同じ)
    $core = @($list | Where-Object {
            if ($_.Path) { Test-HerdrAppProcessPath -Path $_.Path -Dirs @($CoreDir) } else { $_.Name -in @('herdr-core.exe', 'hc.exe') }
        })
    "herdr-app か herdr-core が動いている ($($list.Count) 個) ので、何も外していない。止めてから打ち直す:"
    if ($core.Count -lt $list.Count) { '  app: 窓を閉じる' }
    if ($core.Count -gt 0) {
        "  core: & '$($CoreDir.TrimEnd('\'))\herdr-core.exe' server stop を打つ (core の中の terminal と、そこで動いているものも終わる)"
    }
    foreach ($p in $list) {
        $path = if ($p.Path) { $p.Path } else { "$($p.Name) (パスが読めないので名前で数えた。管理者で動いているなど)" }
        "  $($p.Id)  $path  $($p.CommandLine)"
    }
}

# 動いているプロセスに数えるか。実行ファイルのパスが読めれば置き場所の下か、読めなければ (管理者で動いている、など)
# 名前が herdr-app・herdr-core・hc か (大文字小文字を区別しない)。OpenConsole.exe は Windows Terminal も持つので名前では数えない
function Test-HerdrAppBusyEntry {
    param([string]$Path, [string]$Name, [string[]]$Dirs)
    if ($Path) { return (Test-HerdrAppProcessPath -Path $Path -Dirs $Dirs) }
    $Name -in @('herdr-app.exe', 'herdr-core.exe', 'hc.exe')
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check・本番・-Uninstall を打って確かめる)
# ---------------------------------------------------------------------------

# 置き場所 (公式と同じ)。データの置き場所は、-Uninstall で「残した」と出すためだけに使う
function Get-HerdrAppLocations {
    $programs = Join-Path $env:LOCALAPPDATA 'Programs'
    $appHome = if ($env:HERDR_APP_HOME) { $env:HERDR_APP_HOME }
    elseif ($env:XDG_CONFIG_HOME) { Join-Path $env:XDG_CONFIG_HOME 'herdr-app' }
    else { Join-Path $env:USERPROFILE '.config\herdr-app' }
    $stateHome = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { $env:LOCALAPPDATA }
    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { $env:APPDATA }
    [pscustomobject]@{
        AppDir     = Join-Path $programs 'herdr-app'
        CoreDir    = Join-Path $programs 'herdr-core'
        Menu       = Join-Path ([Environment]::GetFolderPath('Programs')) 'Herdr.lnk'
        AppHome    = $appHome
        CoreState  = Join-Path $stateHome 'herdr-core'
        CoreConfig = Join-Path $configHome 'herdr-core'
    }
}

# 外部コマンドを打ち、出力の行と終了コードを返す。5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
function Invoke-HerdrAppNative {
    param([string]$FilePath, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

# <exe> --version を打って版を読む。窓を開く版の app にあたっても止まらないよう打ち切る。読めなければ $null
function Get-HerdrAppExeVersion {
    param([string]$Exe, [string]$Name, [int]$TimeoutMs = 10000)
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $Exe
        $info.Arguments = '--version'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill() } catch { $null = $_ }
            return $null
        }
        Get-HerdrAppVersionFromOutput -Lines ($stdout.Result -split "`r?`n") -Name $Name
    } catch {
        $null
    }
}

# ユーザーの PATH の生の値 (%VAR% を展開しない)。無ければ ''
function Get-HerdrAppUserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if ($null -eq $key) { return '' }
    try {
        [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        $key.Close()
    }
}

# ユーザーの PATH を書き直す (公式と同じく、値の型 (REG_EXPAND_SZ など) を保つ)。$Flag の user 変数を書いて消し、
# 動いているプログラムに環境変数が変わったことを知らせる
function Set-HerdrAppUserPathRaw {
    param([string]$Value, [string]$Flag)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $kind = if ($key.GetValueNames() -contains 'Path') { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $key.SetValue('Path', $Value, $kind)
    } finally {
        $key.Close()
    }
    [Environment]::SetEnvironmentVariable($Flag, '1', 'User')
    [Environment]::SetEnvironmentVariable($Flag, $null, 'User')
}

# 置き場所をユーザーの PATH の末尾に足す (無いときだけ)。今のプロセスの PATH にも足す (公式と同じ。打った PowerShell で
# すぐ引ける)
function Add-HerdrAppUserPath {
    param([string]$Dir, [string]$Flag)
    $raw = Get-HerdrAppUserPathRaw
    if (-not (Test-HerdrAppPathListed -Raw $raw -Dir $Dir)) {
        Set-HerdrAppUserPathRaw -Value (Get-PathValueWithEntry -Raw $raw -Dir $Dir) -Flag $Flag
        Write-Host "ユーザーの PATH に $Dir を足した (新しく開くシェルから効く)"
    }
    if (-not (Test-HerdrAppPathListed -Raw $env:Path -Dir $Dir)) { $env:Path = Get-PathValueWithEntry -Raw $env:Path -Dir $Dir }
}

# 置き場所を指す行をユーザーの PATH から外す。今のプロセスの PATH からも外す
function Remove-HerdrAppUserPath {
    param([string[]]$Dirs)
    $raw = Get-HerdrAppUserPathRaw
    $new = Get-PathValueWithoutEntry -Raw $raw -Dirs $Dirs
    if ($new -cne $raw) { Set-HerdrAppUserPathRaw -Value $new -Flag 'HERDR_INSTALLING' }
    $env:Path = Get-PathValueWithoutEntry -Raw $env:Path -Dirs $Dirs
}

# Herdr.lnk の TargetPath。無ければ $null、読めなければ ''
function Get-HerdrAppShortcutTarget {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        [string](New-Object -ComObject WScript.Shell).CreateShortcut($Path).TargetPath
    } catch {
        ''
    }
}

# スタートメニューに Herdr.lnk を作る (公式と同じ中身。あれば上書きする)
function New-HerdrAppShortcut {
    param([string]$Path, [string]$Exe)
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $link.TargetPath = $Exe
    $link.WorkingDirectory = $env:USERPROFILE
    $link.Description = 'Terminals and coding agents that keep running'
    $link.Save()
    Write-Host "スタートメニューに $Path を作った"
}

# これから開くシェルが使う PATH (マシン → ユーザーの順)。今のプロセスの PATH は古いことがある
function Get-HerdrAppMachineUserPath {
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}

# 今の状態を読む (何も変えない。ネットワークも使わない。管理者は要らない)
function Get-HerdrAppState {
    param($Locations)
    $appExePath = Join-Path $Locations.AppDir 'herdr-app.exe'
    $coreExePath = Join-Path $Locations.CoreDir 'herdr-core.exe'
    $appExe = Test-Path -LiteralPath $appExePath -PathType Leaf
    $coreExe = Test-Path -LiteralPath $coreExePath -PathType Leaf
    $lnkTarget = Get-HerdrAppShortcutTarget -Path $Locations.Menu
    $raw = Get-HerdrAppUserPathRaw
    $elsewhere = $null
    if (-not $coreExe) {
        $found = Resolve-HerdrAppOnPath -PathValue (Get-HerdrAppMachineUserPath) -Name 'herdr-core.exe' -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
        if ($found -and -not (Test-HerdrAppProcessPath -Path $found -Dirs @($Locations.CoreDir))) { $elsewhere = $found }
    }
    [pscustomobject]@{
        AppExe          = $appExe
        AppVersion      = $(if ($appExe) { Get-HerdrAppExeVersion -Exe $appExePath -Name 'herdr-app' } else { $null })
        AppPathsPresent = @(Get-HerdrAppInstallPaths -AppDir $Locations.AppDir | Where-Object { Test-Path -LiteralPath $_ })
        LnkKind         = Get-HerdrAppLnkKind -Exists ($null -ne $lnkTarget) -Target $lnkTarget -Exe $appExePath
        LnkTarget       = $lnkTarget
        AppPathListed   = Test-HerdrAppPathListed -Raw $raw -Dir $Locations.AppDir
        CoreExe         = $coreExe
        CoreDirExists   = Test-Path -LiteralPath $Locations.CoreDir -PathType Container
        CoreVersion     = $(if ($coreExe) { Get-HerdrAppExeVersion -Exe $coreExePath -Name 'hc' } else { $null })
        CorePathListed  = Test-HerdrAppPathListed -Raw $raw -Dir $Locations.CoreDir
        CoreElsewhere   = $elsewhere
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-HerdrAppState {
    param($State, $Locations)
    foreach ($row in (Format-HerdrAppState -State $State -AppDir $Locations.AppDir -CoreDir $Locations.CoreDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 置き場所の下から起動して動いているプロセス (app・core・core の conpty の OpenConsole.exe) と、実行ファイルのパスが
# 読めない herdr-app・herdr-core・hc。Win32_Process で見る (Process.Path は、32 bit の PowerShell から見た 64 bit の
# プロセスや、管理者で動くプロセスでは読めない)。読めなければ例外 (何も外さずに止まる)
function Get-HerdrAppBusyProcess {
    param([string[]]$Dirs)
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        if (Test-HerdrAppBusyEntry -Path $p.ExecutablePath -Name $p.Name -Dirs $Dirs) {
            [pscustomobject]@{ Id = $p.ProcessId; Name = $p.Name; Path = $p.ExecutablePath; CommandLine = $p.CommandLine }
        }
    }
}

# ファイルかディレクトリを中身ごと消す。リンク (junction・symlink) はリンクだけを消し、先はたどらない
# (Remove-Item -Recurse がリンクの先をたどるかは PowerShell の版で違い、古い版は先の中身まで消す。公式の置き場所の外を
# 消さないよう、たどらないことをここで決める)。読み取り専用のファイルも消す
function Remove-HerdrAppTree {
    param([IO.FileSystemInfo]$Item)
    $isLink = [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (($Item -is [IO.DirectoryInfo]) -and -not $isLink) {
        foreach ($child in @($Item.EnumerateFileSystemInfos())) { Remove-HerdrAppTree -Item $child }
    }
    if ($Item.Attributes -band [IO.FileAttributes]::ReadOnly) {
        $Item.Attributes = $Item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
    }
    $Item.Delete()
}

# ファイルかディレクトリを消す (リンクの先はたどらない)。消せなければ理由を出して $false
function Remove-HerdrAppItem {
    param([string]$Path)
    try {
        Remove-HerdrAppTree -Item (Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
        $true
    } catch {
        Write-Host "  $($_.Exception.Message)"
        $false
    }
}

# 落として入れられるか (公式と同じ条件: x64・curl.exe・System32\tar.exe)。入れられなければ理由、入れられれば $null
function Get-HerdrAppDownloadBlocker {
    param([string]$Tar)
    $arch = Get-HerdrAppArchitecture -Architecture $env:PROCESSOR_ARCHITECTURE -Architecture6432 $env:PROCESSOR_ARCHITEW6432
    if ($arch -ne 'AMD64') { return "herdr-app と herdr-core の Windows 版は x64 だけ ($arch の版は無い)" }
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue) -or -not (Test-Path -LiteralPath $Tar -PathType Leaf)) {
        return 'curl.exe と System32\tar.exe が要る (Windows 10 1803 以降)'
    }
    $null
}

# 公式と同じく curl.exe で落とす。落とせなければ例外。公式と違い、つながらない (30 秒)・転送が止まった (60 秒のあいだ
# 1 KB/s を下回る) ときは打ち切る (setup の中で、bootstrap の打ち切りの 600 秒まで止まらないよう)
function Save-HerdrAppDownload {
    param([string]$Url, [string]$OutFile)
    $result = Invoke-HerdrAppNative -FilePath 'curl.exe' -Arguments @('-fsSL', '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '60', $Url, '-o', $OutFile)
    if ($result.ExitCode -ne 0) { throw "$Url を落とせない (curl.exe の終了コード $($result.ExitCode)) $($result.Lines -join ' ')" }
}

# manifest (latest.json) を落として、target の版・URL・sha256 を読む
function Get-HerdrAppRemoteRelease {
    param([string]$ManifestUrl, [string]$Target, [string]$Tmp)
    $file = Join-Path $Tmp 'manifest.json'
    Save-HerdrAppDownload -Url $ManifestUrl -OutFile $file
    $release = Get-HerdrAppRelease -Manifest (Get-Content -Raw -LiteralPath $file | ConvertFrom-Json) -Target $Target
    if (-not $release) { throw "$ManifestUrl に $Target の url と sha256 が無い" }
    $release
}

# 落としたファイルの sha256 を manifest の値と比べる (大文字小文字は区別しない)。違えば例外
function Assert-HerdrAppSha256 {
    param([string]$Path, [string]$Expected)
    $got = Get-HerdrAppFileSha256 -Path $Path
    if ($got -ne $Expected) { throw "落としたファイルが壊れている (sha256 が $got で、manifest は $Expected)。打ち直す" }
}

# app を公式の手順で入れる: app/latest.json → tar.gz を落とす (?src=install) → sha256 → System32\tar.exe で展開 →
# herdr-app.exe があるか → .old を経て置く。入れた版を返す
function Install-HerdrAppPackage {
    param([string]$AppDir, [string]$Releases, [string]$Target, [string]$Tar)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-app-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $release = Get-HerdrAppRemoteRelease -ManifestUrl "$Releases/app/latest.json" -Target $Target -Tmp $tmp
        Write-Host "herdr-app $($release.Version) を落とす: $($release.Url)"
        $archive = Join-Path $tmp 'app.tar.gz'
        Save-HerdrAppDownload -Url (Get-HerdrAppDownloadUrl -Url $release.Url -Releases $Releases -Src 'install') -OutFile $archive
        Assert-HerdrAppSha256 -Path $archive -Expected $release.Sha256
        $untar = Invoke-HerdrAppNative -FilePath $Tar -Arguments @('-xzf', $archive, '-C', $tmp)
        $unpacked = Join-Path $tmp 'herdr-app'
        if (($untar.ExitCode -ne 0) -or -not (Test-Path -LiteralPath (Join-Path $unpacked 'herdr-app.exe') -PathType Leaf)) {
            throw "落とした tar.gz に herdr-app\herdr-app.exe が無い (tar.exe の終了コード $($untar.ExitCode))"
        }
        # 動いている app のフォルダは rename できるが消せない。古いものは消せれば今、だめなら次に入れるときに消す (公式と同じ)
        New-Item -ItemType Directory -Force (Split-Path $AppDir) | Out-Null
        Remove-Item -LiteralPath "$AppDir.old" -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $AppDir) { Rename-Item -LiteralPath $AppDir -NewName "$(Split-Path $AppDir -Leaf).old" }
        Move-Item -LiteralPath $unpacked -Destination $AppDir
        Remove-Item -LiteralPath "$AppDir.old" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "herdr-app $($release.Version) を $AppDir に置いた"
        $release.Version
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# core を公式の手順で入れる (公式の置き場所に herdr-core.exe が無いときだけ呼ぶ): core/latest.json → zip を落とす
# (?src=install) → sha256 → System32\tar.exe で展開 → conpty と --version を確かめる → 置く → hc が無ければ hc.exe を
# hard link で作る。入れた版を返す
function Install-HerdrCorePackage {
    param([string]$CoreDir, [string]$Releases, [string]$Target, [string]$Tar)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "install-herdr-core-$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $release = Get-HerdrAppRemoteRelease -ManifestUrl "$Releases/core/latest.json" -Target $Target -Tmp $tmp
        Write-Host "herdr-core $($release.Version) を落とす: $($release.Url)"
        $archive = Join-Path $tmp 'hc.zip'
        Save-HerdrAppDownload -Url (Get-HerdrAppDownloadUrl -Url $release.Url -Releases $Releases -Src 'install') -OutFile $archive
        Assert-HerdrAppSha256 -Path $archive -Expected $release.Sha256
        $unpacked = Join-Path $tmp 'hc'
        New-Item -ItemType Directory -Force $unpacked | Out-Null
        $unzip = Invoke-HerdrAppNative -FilePath $Tar -Arguments @('-xf', $archive, '-C', $unpacked)
        if (($unzip.ExitCode -ne 0) -or -not (Test-Path -LiteralPath (Join-Path $unpacked 'conpty\conpty.dll') -PathType Leaf)) {
            throw "落とした zip に conpty\conpty.dll が無い (tar.exe の終了コード $($unzip.ExitCode))"
        }
        $new = Join-Path $unpacked 'herdr-core.exe'
        $version = Get-HerdrAppExeVersion -Exe $new -Name 'hc'
        if (-not $version) { throw '落とした herdr-core.exe がこの PC で動かない (--version が読めない)' }
        New-Item -ItemType Directory -Force $CoreDir | Out-Null
        Copy-Item -LiteralPath $new, (Join-Path $unpacked 'conpty') -Destination $CoreDir -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $unpacked 'THIRD-PARTY-NOTICES') -Destination $CoreDir -Recurse -Force -ErrorAction SilentlyContinue
        $exe = Join-Path $CoreDir 'herdr-core.exe'
        $hc = Join-Path $CoreDir 'hc.exe'
        if (-not (Get-Command hc -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $hc)) {
            New-Item -ItemType HardLink -Path $hc -Target $exe | Out-Null
            Write-Host 'hc.exe を herdr-core.exe への hard link で作った'
        }
        Write-Host "herdr-core $version を $CoreDir に置いた"
        $version
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -Uninstall の本体。外すものがあれば、動いているかを見て、止まっていれば外す。外した後に読み直し、外すものが残って
# いなければ 0
function Invoke-UninstallHerdrApp {
    param($State, $Locations)
    $plan = @(Get-HerdrAppUninstallPlan -State $State -AppDir $Locations.AppDir -CoreDir $Locations.CoreDir -Menu $Locations.Menu)
    Write-Host 'herdr-app と herdr-core を外す (公式の install.ps1 と同じ置き場所のものだけ。設定は残す)'
    if ($plan.Count -eq 0) {
        Write-Host '  外すもの (app・Herdr.lnk・PATH の行・core) は無い。何もしない'
        foreach ($line in @(Format-HerdrAppKept -State $State -Locations $Locations -Exists { param($p) Test-Path -LiteralPath $p })) { Write-Host "  $line" }
        return 0
    }
    $busy = @(Get-HerdrAppBusyProcess -Dirs (Get-HerdrAppWatchDirs -AppDir $Locations.AppDir -CoreDir $Locations.CoreDir))
    if ($busy.Count -gt 0) {
        foreach ($line in @(Format-HerdrAppBusy -Processes $busy -CoreDir $Locations.CoreDir)) { Write-Host $line -ForegroundColor Yellow }
        return 1
    }
    $failed = $false
    $pathDirs = @()
    foreach ($step in $plan) {
        if ($step.Kind -eq 'path') {
            $pathDirs += $step.Target
            continue
        }
        if (Remove-HerdrAppItem -Path $step.Target) { Write-Host "  外した: $($step.Target)" }
        else {
            Write-Host "  外せなかった: $($step.Target)" -ForegroundColor Yellow
            $failed = $true
        }
    }
    if ($pathDirs.Count -gt 0) {
        Remove-HerdrAppUserPath -Dirs $pathDirs
        foreach ($dir in $pathDirs) { Write-Host "  外した: ユーザーの PATH の $dir" }
    }
    foreach ($line in @(Format-HerdrAppKept -State $State -Locations $Locations -Exists { param($p) Test-Path -LiteralPath $p })) { Write-Host "  $line" }

    # 外しきれたかを読み直して確かめる
    $after = Get-HerdrAppState -Locations $Locations
    $left = @(Get-HerdrAppUninstallPlan -State $after -AppDir $Locations.AppDir -CoreDir $Locations.CoreDir -Menu $Locations.Menu)
    if (($left.Count -eq 0) -and -not $failed) {
        Write-Host '外した'
        Write-Host '※ dotfiles が管理する間は、次の setup --update が入れ直す (winget に移るときは win/README.md の「winget に載ったら」の順で)'
        return 0
    }
    foreach ($step in $left) {
        $text = if ($step.Kind -eq 'path') { "ユーザーの PATH の $($step.Target)" } else { $step.Target }
        Write-Host "  残っている: $text" -ForegroundColor Yellow
    }
    Write-Host '⚠️ 外しきれなかった。上の理由を見て直し、Install-HerdrApp -Uninstall を打ち直す ⚠️' -ForegroundColor Yellow
    return 1
}

function Invoke-InstallHerdrApp {
    param([switch]$Check, [switch]$IfMissing, [switch]$Uninstall)
    if ($Uninstall -and ($Check -or $IfMissing)) {
        Write-Host '-Uninstall は -Check・-IfMissing と一緒に使えない'
        return 2
    }
    $releases = 'https://releases.herdr.dev'
    $target = 'windows-x86_64'
    $locations = Get-HerdrAppLocations
    $state = Get-HerdrAppState -Locations $locations
    if ($Uninstall) { return (Invoke-UninstallHerdrApp -State $state -Locations $locations) }

    Write-HerdrAppState -State $state -Locations $locations
    $code = Get-HerdrAppExitCode -State $state
    # -Check は何も変えない。-IfMissing は app が無いときだけ入れ、あれば -Check と同じ (欠けているものも足さない)
    if ($Check -or ($IfMissing -and ($code -ne 3))) {
        switch ($code) {
            0 { Write-Host '入っている' }
            3 { Write-Host '⚠️ herdr-app が入っていない → Install-HerdrApp で入れる ⚠️' -ForegroundColor Yellow }
            default { Write-Host '⚠️ herdr-app に欠けているものがある → Install-HerdrApp で足す ⚠️' -ForegroundColor Yellow }
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '入っている。何もしない'
        return 0
    }

    # 欠けているものだけを足す。app があれば落とし直さない (上げるのは app)
    $needApp = -not $state.AppExe
    $needCore = (-not $state.CoreExe) -and (-not $state.CoreElsewhere)
    # ここのパスは Join-Path で組まない (C: も SystemRoot も無い Linux の pwsh で流すテストでも組めるように)
    $tar = "$env:SystemRoot\System32\tar.exe"
    if ($needApp -or $needCore) {
        $blocker = Get-HerdrAppDownloadBlocker -Tar $tar
        if ($blocker) {
            Write-Host "入れられない: $blocker"
            return 1
        }
    }
    if ($needApp) {
        try {
            $null = Install-HerdrAppPackage -AppDir $locations.AppDir -Releases $releases -Target $target -Tar $tar
        } catch {
            Write-Host "herdr-app を入れられなかった: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host 'ネットワークを確かめて Install-HerdrApp を打ち直す (setup --update でも、もう一度入れにいく)'
            return 1
        }
    }
    if ($state.LnkKind -ne 'ours') { New-HerdrAppShortcut -Path $locations.Menu -Exe "$($locations.AppDir)\herdr-app.exe" }
    if (-not $state.AppPathListed) { Add-HerdrAppUserPath -Dir $locations.AppDir -Flag 'HERDR_INSTALLING' }
    if ($needCore) {
        $coreInstalled = $false
        try {
            $null = Install-HerdrCorePackage -CoreDir $locations.CoreDir -Releases $releases -Target $target -Tar $tar
            $coreInstalled = $true
        } catch {
            Write-Host "herdr-core を入れられなかった: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host 'Install-HerdrApp を打ち直す (app を開いたときにも、app が core を入れるよう勧める)'
        }
        # PATH に足すのは入れられたときだけ (足すときの失敗は、入れられなかったことと分けて出す)
        if ($coreInstalled) { Add-HerdrAppUserPath -Dir $locations.CoreDir -Flag 'HC_INSTALLING' }
    } elseif ($state.CoreExe -and -not $state.CorePathListed) {
        Add-HerdrAppUserPath -Dir $locations.CoreDir -Flag 'HC_INSTALLING'
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-HerdrAppState -Locations $locations
    Write-HerdrAppState -State $after -Locations $locations
    if ((Get-HerdrAppExitCode -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    Write-Host '⚠️ まだ欠けているものがある (上の ⚠ の行) → Install-HerdrApp を打ち直す ⚠️' -ForegroundColor Yellow
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の curl.exe などの 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallHerdrApp -Check:$Check -IfMissing:$IfMissing -Uninstall:$Uninstall)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
