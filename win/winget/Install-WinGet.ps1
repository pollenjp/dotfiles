<#
.SYNOPSIS
Windows の winget (アプリ インストーラー。Microsoft.DesktopAppInstaller) を、dotfiles が固定した版以上に揃える (下げない)。

.DESCRIPTION
dotfiles の win/winget/Install-WinGet.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-WinGet から呼ぶ (win/README.md の「winget」)。
入れて揃えるのは Windows の runner の手順 winget (どのホストでも。order 6 で、winget を使うほかの手順より先に流す)。

dotfiles の Windows の道具 (Install-Codex など) は winget 1.30 以降を前提にする (1.30 で portable の入れ方が変わった。win/README.md の「winget」)。
新しく入れた Windows の winget は古いことがあり、Microsoft Store が使えない・止められた PC (会社の PC など) では Store の自動の更新でも上がらない。
そこで、GitHub の microsoft/winget-cli の Release から、固定した版の msixbundle と依存の zip (DesktopAppInstaller_Dependencies.zip) を落とし、
固定した sha256 と比べてから、Add-AppxPackage でこのユーザーに入れる。

- 管理者に昇格しない (UAC を出さない)。Add-AppxPackage はユーザー単位で入れる。-AllUsers・Add-AppxProvisionedPackage (管理者が要る) は使わない
  ので、Release の License の xml は要らない
- 入っている版 (winget --version) が固定した版以上なら何もしない (下げない。Store が上げた新しい版はそのまま)
- 依存 (VCLibs・WindowsAppRuntime の framework) は zip の中のこの CPU (x64・arm64) のものだけを使い、入っている framework の版が足りないものだけを
  -DependencyPath に渡す。zip の中の名前 (<arch>/<Name>_<Version>_<arch>.appx) から名前と版を読む (zip は sha256 を確かめた後に読む)
- Appx の cmdlet (Get-AppxPackage・Add-AppxPackage) は、PowerShell 7 からは読めないことがあるので、いつも System32 の Windows PowerShell に打たせる
- Add-AppxPackage には -ForceApplicationShutdown を付ける (動いている winget・アプリ インストーラーは終わる)

PSGallery の Microsoft.WinGet.Client の Repair-WinGetPackageManager は使わない (module を PSGallery から入れる手が増え、落とした物の sha256 を
dotfiles で固定できない。同じ GitHub の Release から落とす。dotfiles-private の docs/adr/121_win_winget_pin_*)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版 (winget --version の版。GitHub の microsoft/winget-cli の Release の tag は v<版>)。上げるときは、ここの既定値と
Get-WinGetRelease の表 (msixbundle と依存の zip の sha256) を一緒に変える (win/README.md の「winget の固定した版を上げる」)。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば (固定した版以上なら) 終了コード 0、古ければ 1、入っていなければ 3
(この PC に入れられないときは、入っていなくても 1)。

.PARAMETER IfMissing
入っていなければ固定した版を入れる。入っていれば -Check と同じで、上げはしない。

.PARAMETER Force
入っている版が固定した版と同じでも、落として入れ直す (落とす・sha256・依存・Add-AppxPackage の流れを確かめるため)。固定した版より新しければ
何もしない (下げない)。
#>
[CmdletBinding()]
param(
    [string]$Version = '1.30.310',
    [switch]$Check,
    [switch]$IfMissing,
    [switch]$Force
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-WinGet.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 固定できる版ごとの、GitHub の Release の物の sha256 (小文字の 16 進)。Bundle は Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle、
# Dependencies は DesktopAppInstaller_Dependencies.zip。値は GitHub の API の asset の digest (Release の <物>.txt の値と同じ)。
# 表に無い版は入れない (確かめられないため)。版を上げるときは行を足す (古い行は消してよい)
function Get-WinGetRelease {
    param([string]$Version)
    $table = @{
        '1.30.310' = @{
            Bundle       = '152d6e355abd8c17e2fd13fef2c65e795b9a83822a5c5af63dc79f787d099904'
            Dependencies = 'bf52a403c3d70cac68bfe3fd7dfefb497bd94e314fb77d33d5abfc3a35a4f8fd'
        }
    }
    if ($table.ContainsKey($Version)) { return $table[$Version] }
    $null
}

# winget --version の出力 ("v1.30.310" など。preview は "v1.31.10-preview") から winget の版を拾う。読めなければ $null
# (Install-Codex.ps1 の Get-WingetClientVersion と同じ)
function Get-WinGetClientVersion {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*v?(\d+)\.(\d+)(\.(\d+))?') {
            $build = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
            return [version]::new([int]$Matches[1], [int]$Matches[2], $build)
        }
    }
    $null
}

# 固定した版の字 ("1.30.310") を [version] にする。読めなければ $null
function ConvertTo-WinGetVersion {
    param([string]$Text)
    if ("$Text" -match '^\s*(\d+)\.(\d+)\.(\d+)\s*$') {
        return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    }
    $null
}

# 入っているか・入っている版・固定した版から、することを決める。install (入っていない) / upgrade (固定した版より古い・版が読めない) /
# none (固定した版以上)。版が読めないときも、固定した版を入れて直す
function Get-WinGetPlan {
    param([bool]$Exists, $Installed, $Target)
    if (-not $Exists) { return 'install' }
    if ($null -eq $Installed) { return 'upgrade' }
    if ($Installed -lt $Target) { return 'upgrade' }
    'none'
}

# OS の CPU (PROCESSOR_ARCHITEW6432 があればそれ。32 bit のプロセスでも OS の CPU を見る) を、依存の zip のディレクトリの名前にする。
# 入れられない CPU なら $null
function Get-WinGetArch {
    param([string]$Architecture)
    switch ("$Architecture".ToUpperInvariant()) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        default { $null }
    }
}

# 依存の zip の中の名前から、この CPU の appx を拾う (<arch>/<Name>_<Version>_<arch>.appx)。Entry・Name・Version ([version])・Arch を返す
function Get-WinGetDependencyEntries {
    param([string[]]$Names, [string]$Arch)
    foreach ($name in $Names) {
        $n = "$name".Replace('\', '/')
        if ($n -match '^([^/]+)/([^/_]+)_(\d+(\.\d+){1,3})_([^/_]+)\.appx$') {
            if (($Matches[1] -ieq $Arch) -and ($Matches[5] -ieq $Arch)) {
                [pscustomobject]@{ Entry = $n; Name = $Matches[2]; Version = [version]$Matches[3]; Arch = $Arch }
            }
        }
    }
}

# Get-AppxPackage の結果を 1 つ 1 行にした字 ("<Name><TAB><Version><TAB><Architecture>") を読む。読めない行は飛ばす
function ConvertFrom-WinGetAppxLines {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $cols = "$line".TrimEnd("`r") -split "`t"
        if ($cols.Count -lt 3) { continue }
        $v = $null
        if (-not [version]::TryParse($cols[1], [ref]$v)) { continue }
        [pscustomobject]@{ Name = $cols[0]; Version = $v; Arch = $cols[2] }
    }
}

# 入れる依存のうち、入っている framework (同じ名前・同じ CPU) の版が足りないものだけを返す (足りていれば渡さない)
function Select-WinGetNeededDependencies {
    param([object[]]$Dependencies, [object[]]$Installed)
    foreach ($d in @($Dependencies)) {
        if ($null -eq $d) { continue }
        $have = @(@($Installed) | Where-Object {
                ($null -ne $_) -and ($_.Name -ieq $d.Name) -and ("$($_.Arch)" -ieq $d.Arch) -and ($_.Version -ge $d.Version)
            })
        if ($have.Count -eq 0) { $d }
    }
}

# GitHub の Release の物の URL
function Get-WinGetDownloadUrl {
    param([string]$Version, [string]$Asset)
    "https://github.com/microsoft/winget-cli/releases/download/v$Version/$Asset"
}

# 落とした物の sha256 が固定した値と同じか (大文字小文字は問わない。どちらかが空なら違う)
function Test-WinGetHash {
    param([string]$Actual, [string]$Expected)
    if (-not $Actual -or -not $Expected) { return $false }
    $Actual.Trim() -ieq $Expected.Trim()
}

# 入れる・上げるのを止めるわけ。arch (入れられない CPU) / not-pinned (固定した版の sha256 が表に無い) / no-curl (curl.exe が無い) / $null (止めない)
function Get-WinGetBlocker {
    param([string]$Arch, $Release, [bool]$HasCurl)
    if (-not $Arch) { return 'arch' }
    if ($null -eq $Release) { return 'not-pinned' }
    if (-not $HasCurl) { return 'no-curl' }
    $null
}

# 止めるわけの文
function Get-WinGetBlockerText {
    param([string]$Blocker, [string]$Version, [string]$Architecture)
    switch ($Blocker) {
        'arch' { "この PC の CPU ($Architecture) 向けの winget は dotfiles では入れない (x64・arm64 だけ)" }
        'not-pinned' { "固定した版 $Version の sha256 が Install-WinGet.ps1 の表 (Get-WinGetRelease) に無い" }
        'no-curl' { 'curl.exe が無い (Windows 10 1803 以降に System32 にある)' }
        default { '' }
    }
}

# 終了コード (-Check と同じ)。0 = 固定した版以上、1 = 古い (入っていなくても、入れられなければ 1)、3 = 入っていない
function Get-WinGetExitCode {
    param($State)
    switch ($State.Plan) {
        'none' { 0 }
        'install' { if ($State.Blocker) { 1 } else { 3 } }
        default { 1 }
    }
}

# 状態の表の行 (Text と Warn)。runner (win/runner/src/steps/ps1.rs) は見出しの「winget (アプリ インストーラー」で、ps1 が動いたかを見る
function Format-WinGetState {
    param($State, [string]$Target)
    $installedText = if (-not $State.Exists) { '入っていない' }
    elseif ($State.Installed) { "$($State.Installed) ($($State.Exe))" }
    else { "不明 (winget --version が読めない。$($State.Exe))" }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'upgrade' { '上げる' }
        default { if ($State.Installed -and $State.TargetVersion -and ($State.Installed -gt $State.TargetVersion)) { 'そのまま (固定した版より新しい。下げない)' } else { 'そのまま' } }
    }
    $archText = if ($State.Arch) { $State.Arch } else { "$($State.Architecture) (入れられない)" }
    $rows = @(
        @{ Text = 'winget (アプリ インストーラー。Microsoft.DesktopAppInstaller。GitHub の microsoft/winget-cli の Release から入れる)'; Warn = $false; Indent = $false }
        @{ Text = "入っている版 : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版   : $Target 以上 → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
        @{ Text = "CPU          : $archText"; Warn = (-not $State.Arch); Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    if (($State.Plan -ne 'none') -and $State.Blocker) {
        $why = Get-WinGetBlockerText -Blocker $State.Blocker -Version $Target -Architecture $State.Architecture
        [pscustomobject]@{ Text = "⚠ winget を入れられない ($why)"; Warn = $true }
        $fix = switch ($State.Blocker) {
            'arch' { '※ この PC では、Microsoft Store の「アプリ インストーラー」を更新して winget を上げる (win/README.md の「winget」)' }
            'not-pinned' { '※ Install-WinGet.ps1 の -Version の既定値と Get-WinGetRelease の表を揃える (win/README.md の「winget の固定した版を上げる」)' }
            default { '※ curl.exe のある Windows (10 1803 以降) で打つか、Microsoft Store の「アプリ インストーラー」を更新して winget を上げる (win/README.md の「winget」)' }
        }
        [pscustomobject]@{ Text = $fix; Warn = $false }
    }
}

# 締めの行 (-Check の最後と、揃えた後の最後)。揃っていれば何も返さない。Windows の runner (win/runner/src/steps/ps1.rs) は
# 「→ Install-WinGet で入れる」「→ Install-WinGet で揃える」「→ ※ の手順で直す」の文言で、入れるか・揃えるか・知らせるだけかを決め、
# 「winget を入れられない」の印で直し方を選ぶ (文言を変えるときは向こうも直す)
function Format-WinGetVerdict {
    param($State)
    if ($State.Plan -eq 'none') { return }
    if ($State.Blocker) {
        '⚠️ winget を入れられない (上の ※ の行) → ※ の手順で直す ⚠️'
        return
    }
    if ($State.Plan -eq 'install') {
        '⚠️ winget が入っていない → Install-WinGet で入れる ⚠️'
        return
    }
    '⚠️ winget が固定した版より古い → Install-WinGet で揃える ⚠️'
}

# Windows PowerShell に渡す字の中の文字列 ('…' の中。' は '' にする)
function ConvertTo-WinGetQuoted {
    param([string]$Text)
    "'" + "$Text".Replace("'", "''") + "'"
}

# Windows PowerShell に打たせる Add-AppxPackage の本文。落ちたら、例外の文と HRESULT を出して 1 で終わる
function Get-WinGetAddAppxScript {
    param([string]$Bundle, [string[]]$Dependencies)
    $deps = @($Dependencies | Where-Object { $_ })
    $depArg = ''
    if ($deps.Count -gt 0) {
        $depArg = ' -DependencyPath @(' + (($deps | ForEach-Object { ConvertTo-WinGetQuoted -Text $_ }) -join ', ') + ')'
    }
    @(
        "`$ErrorActionPreference = 'Stop'"
        "`$ProgressPreference = 'SilentlyContinue'"
        'try {'
        "    Add-AppxPackage -Path $(ConvertTo-WinGetQuoted -Text $Bundle)$depArg -ForceApplicationShutdown"
        '    exit 0'
        '} catch {'
        "    Write-Output `$_.Exception.Message"
        "    Write-Output ('HRESULT 0x{0:X8}' -f `$_.Exception.HResult)"
        '    exit 1'
        '}'
    ) -join "`n"
}

# Windows PowerShell に打たせる Get-AppxPackage の本文 (名前ごとに、"<Name><TAB><Version><TAB><Architecture>" の行)
function Get-WinGetAppxQueryScript {
    param([string[]]$Names)
    $list = (@($Names) | ForEach-Object { ConvertTo-WinGetQuoted -Text $_ }) -join ', '
    @(
        "`$ErrorActionPreference = 'Stop'"
        "foreach (`$n in @($list)) {"
        "    Get-AppxPackage -Name `$n | ForEach-Object { '{0}`t{1}`t{2}' -f `$_.Name, `$_.Version, `$_.Architecture }"
        '}'
    ) -join "`n"
}

# Add-AppxPackage が落ちたときに、HRESULT から添える直し方 (無ければ $null)
function Get-WinGetAppxFailureHint {
    param([string[]]$Lines)
    $text = @($Lines) -join ' '
    if ($text -match '0x80073CFF|0x80073D2E') {
        return '※ この PC は、Microsoft Store の外からのアプリの追加 (サイドロード) を方針で止めている見込み。管理者に頼むか、Microsoft Store の「アプリ インストーラー」を更新する'
    }
    if ($text -match '0x80073D02') {
        return '※ 動いている winget・アプリ インストーラーが閉じられなかった。winget を使っている窓を閉じてから打ち直す'
    }
    if ($text -match '0x80073D06') {
        return '※ もっと新しいアプリ インストーラーが入っている。winget --version を確かめる (固定した版以上なら、何もしなくてよい)'
    }
    $null
}

function ConvertTo-WinGetEncodedCommand {
    param([string]$Script)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget の exe。PATH の winget (.exe だけ) を先に見て、無ければ実行エイリアス (%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe。入れた直後は
# このプロセスの PATH に無いことがある)。無ければ $null
function Find-WinGetExe {
    $found = @(Get-Command -Name winget -CommandType Application -ErrorAction SilentlyContinue | Where-Object { "$($_.Source)" -like '*.exe' })
    if ($found.Count -gt 0) { return $found[0].Source }
    if ($env:LOCALAPPDATA) {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $alias) { return $alias }
    }
    $null
}

# winget --version を読む。読めなければ $null
function Get-WinGetInstalledVersion {
    param([string]$Exe)
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe --version 2>&1 | ForEach-Object { "$_" })
    } catch {
        return $null
    }
    Get-WinGetClientVersion -Lines $out
}

# OS の CPU の字 (AMD64・ARM64 など)
function Get-WinGetOsArchitecture {
    if ($env:PROCESSOR_ARCHITEW6432) { return $env:PROCESSOR_ARCHITEW6432 }
    "$env:PROCESSOR_ARCHITECTURE"
}

function Test-WinGetCurl {
    [bool](Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue)
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-WinGetState {
    param([string]$Target, $Release)
    $exe = Find-WinGetExe
    $installed = $null
    if ($exe) { $installed = Get-WinGetInstalledVersion -Exe $exe }
    $targetVersion = ConvertTo-WinGetVersion -Text $Target
    $architecture = Get-WinGetOsArchitecture
    $arch = Get-WinGetArch -Architecture $architecture
    $plan = Get-WinGetPlan -Exists ([bool]$exe) -Installed $installed -Target $targetVersion
    $blocker = $null
    if ($plan -ne 'none') { $blocker = Get-WinGetBlocker -Arch $arch -Release $Release -HasCurl (Test-WinGetCurl) }
    [pscustomobject]@{
        Exists        = [bool]$exe
        Exe           = $exe
        Installed     = $installed
        TargetVersion = $targetVersion
        Architecture  = $architecture
        Arch          = $arch
        Plan          = $plan
        Blocker       = $blocker
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-WinGetState {
    param($State, [string]$Target)
    foreach ($row in (Format-WinGetState -State $State -Target $Target)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 締めの行 (直すこと) を黄色で出す。揃っていれば何も出さない
function Write-WinGetVerdict {
    param($State)
    foreach ($line in (Format-WinGetVerdict -State $State)) {
        Write-Host $line -ForegroundColor Yellow
    }
}

# URL の中身を OutFile に落とす (Install-HerdrApp.ps1 と同じく curl.exe。つながらない (30 秒)・転送が止まった (60 秒のあいだ 1 KB/s 未満) ときは
# 打ち切る)。落とせなければ例外
function Invoke-WinGetDownload {
    param([string]$Url, [string]$OutFile)
    $ErrorActionPreference = 'Continue'
    $out = @(& curl.exe -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 $Url -o $OutFile 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "$Url を落とせない (curl.exe の終了コード $LASTEXITCODE) $($out -join ' ')" }
}

# ファイルの SHA-256 (小文字の 16 進)。読めなければ $null。Get-FileHash は使わない (PowerShell 7 から起こした 5.1 では見つからないことがある。
# Install-OpReason.ps1 と同じ)
function Get-WinGetFileHash {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        } finally {
            $stream.Dispose()
        }
    } catch {
        $null
    } finally {
        $sha.Dispose()
    }
}

# zip の中の名前の一覧
function Get-WinGetZipEntryNames {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        @($zip.Entries | ForEach-Object { $_.FullName })
    } finally {
        $zip.Dispose()
    }
}

# zip の中の Entry を Destination の直下に出し、出したパスを返す。出せなければ例外。Expand-Archive は使わない (Install-OpReason.ps1 と同じ)
function Expand-WinGetZipEntry {
    param([string]$ZipPath, [string]$Entry, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $item = $zip.GetEntry($Entry)
        if ($null -eq $item) { throw "$ZipPath に $Entry が無い" }
        $out = Join-Path $Destination ([IO.Path]::GetFileName($Entry))
        [IO.Compression.ZipFileExtensions]::ExtractToFile($item, $out, $true)
        $out
    } finally {
        $zip.Dispose()
    }
}

# System32 の Windows PowerShell に本文を打たせ、出力の行と終了コードを返す (PowerShell 7 の Appx は読めないことがあるので、5.1 から打つときも
# 子の 5.1 にそろえる。Install-ClaudeDesktop.ps1 の Get-ClaudeAppxLines と同じ形)
function Invoke-WinGetWindowsPowerShell {
    param([string]$Script)
    $shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand (ConvertTo-WinGetEncodedCommand -Script $Script) 2>&1 | ForEach-Object { "$_" })
    } catch {
        return [pscustomobject]@{ ExitCode = 2; Lines = @("$shell を起こせない: $($_.Exception.Message)") }
    }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out }
}

# 依存の framework の、このユーザーに入っている版 (ConvertFrom-WinGetAppxLines の形)。読めなければ例外 (足りるか分からないまま入れにいかない)
function Get-WinGetInstalledFrameworks {
    param([string[]]$Names)
    $r = Invoke-WinGetWindowsPowerShell -Script (Get-WinGetAppxQueryScript -Names $Names)
    if ($r.ExitCode -ne 0) { throw "Windows PowerShell で Get-AppxPackage を打てなかった (終了コード $($r.ExitCode)): $($r.Lines -join ' / ')" }
    @(ConvertFrom-WinGetAppxLines -Lines $r.Lines)
}

# msixbundle を依存と一緒にこのユーザーに入れる
function Invoke-WinGetAddAppx {
    param([string]$Bundle, [string[]]$Dependencies)
    Invoke-WinGetWindowsPowerShell -Script (Get-WinGetAddAppxScript -Bundle $Bundle -Dependencies $Dependencies)
}

function New-WinGetWorkDir {
    $dir = Join-Path ([IO.Path]::GetTempPath()) "install-winget-$PID"
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $dir
}

# 固定した版を落とし、sha256 を確かめ、足りない依存と一緒に入れる。入れられたら $true。わけは Write-Host で出す
function Install-WinGetRelease {
    param([string]$Version, $Release, [string]$Arch)
    $work = New-WinGetWorkDir
    try {
        $bundleName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        $depsName = 'DesktopAppInstaller_Dependencies.zip'
        $bundle = Join-Path $work $bundleName
        $deps = Join-Path $work $depsName
        foreach ($item in @(@{ Name = $bundleName; Path = $bundle; Hash = $Release.Bundle }, @{ Name = $depsName; Path = $deps; Hash = $Release.Dependencies })) {
            $url = Get-WinGetDownloadUrl -Version $Version -Asset $item.Name
            Write-Host "落とす: $url"
            try {
                Invoke-WinGetDownload -Url $url -OutFile $item.Path
            } catch {
                Write-Host "落とせなかった: $($_.Exception.Message)"
                Write-Host '何も変えていない。ネットワーク (github.com と release-assets.githubusercontent.com に出られるか) を確かめて打ち直す'
                return $false
            }
            $actual = Get-WinGetFileHash -Path $item.Path
            if (-not (Test-WinGetHash -Actual $actual -Expected $item.Hash)) {
                Write-Host "sha256 が固定した値と違う: $($item.Name) (落とした物 $actual・固定した値 $($item.Hash))"
                Write-Host '何も変えていない。途中で書き換わった物を入れないため止める (繰り返すなら、Release の物が差し替わっていないかを確かめる)'
                return $false
            }
            Write-Host "sha256 を確かめた: $($item.Name)"
        }
        $entries = @(Get-WinGetDependencyEntries -Names (Get-WinGetZipEntryNames -ZipPath $deps) -Arch $Arch)
        if ($entries.Count -eq 0) {
            Write-Host "依存の zip に $Arch の appx が無い。何も変えていない (zip の形が変わった見込み。Install-WinGet.ps1 の読み方を直す)"
            return $false
        }
        $installed = @(Get-WinGetInstalledFrameworks -Names @($entries | ForEach-Object { $_.Name }))
        $needed = @(Select-WinGetNeededDependencies -Dependencies $entries -Installed $installed)
        $paths = @()
        foreach ($d in $needed) {
            Write-Host "依存を足す: $($d.Name) $($d.Version) ($Arch)"
            $paths += Expand-WinGetZipEntry -ZipPath $deps -Entry $d.Entry -Destination $work
        }
        if ($needed.Count -eq 0) { Write-Host '依存 (VCLibs・WindowsAppRuntime) は足りている' }
        Write-Host 'Add-AppxPackage でこのユーザーに入れる (動いている winget・アプリ インストーラーは終わる)'
        $result = Invoke-WinGetAddAppx -Bundle $bundle -Dependencies $paths
        if ($result.ExitCode -ne 0) {
            $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
            Write-Host "Add-AppxPackage が落ちた (終了コード $($result.ExitCode))"
            $hint = Get-WinGetAppxFailureHint -Lines $result.Lines
            if ($hint) { Write-Host $hint }
            return $false
        }
        $true
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-InstallWinGet {
    param([string]$Version, [switch]$Check, [switch]$IfMissing, [switch]$Force)
    $release = Get-WinGetRelease -Version $Version
    if ($null -eq (ConvertTo-WinGetVersion -Text $Version)) {
        Write-Host "固定した版 $Version が版の形 (X.Y.Z) でない"
        return 2
    }

    $state = Get-WinGetState -Target $Version -Release $release
    Write-WinGetState -State $state -Target $Version
    $code = Get-WinGetExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if ($code -eq 0) { Write-Host '揃っている' }
        Write-WinGetVerdict -State $state
        return $code
    }
    if ($state.Plan -eq 'none') {
        if (-not $Force) {
            Write-Host '揃っている。何もしない'
            return 0
        }
        if ($state.Installed -gt $state.TargetVersion) {
            Write-Host '固定した版より新しいので、-Force でも入れ直さない (下げない)'
            return 0
        }
        Write-Host '-Force: 固定した版と同じだが、落として入れ直す'
        $state.Blocker = Get-WinGetBlocker -Arch $state.Arch -Release $release -HasCurl (Test-WinGetCurl)
    }
    if ($state.Blocker) {
        Write-Host 'winget を入れられないので、何も変えずに止める (上の ※ の行の手順で直す)'
        Write-WinGetVerdict -State $state
        return 1
    }

    $ok = Install-WinGetRelease -Version $Version -Release $release -Arch $state.Arch
    if (-not $ok) {
        if ($state.Exists) { Write-Host '入っている winget はそのまま。Install-WinGet を打ち直す (dotfiles apply でも揃える)' }
        else { Write-Host 'winget は入っていない。Install-WinGet を打ち直す (dotfiles apply でも入る)' }
        return 1
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-WinGetState -Target $Version -Release $release
    Write-WinGetState -State $after -Target $Version
    if ((Get-WinGetExitCode -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    Write-Host 'Add-AppxPackage は通ったが、winget --version が固定した版にならない。新しい PowerShell で winget --version を確かめる'
    Write-WinGetVerdict -State $after
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallWinGet -Version $Version -Check:$Check -IfMissing:$IfMissing -Force:$Force)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
