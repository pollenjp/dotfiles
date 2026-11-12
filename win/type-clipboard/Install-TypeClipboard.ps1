<#
.SYNOPSIS
Windows の type-clipboard (pollenjp/type-clipboard の GitHub の Release の exe) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/type-clipboard/Install-TypeClipboard.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-TypeClipboard から呼ぶ (win/README.md の「type-clipboard」)。

type-clipboard は、クリップボードの文字を選んだ窓へキー入力として打ち込む自作の GUI のアプリで、単一の exe
(インストーラも署名も無い)。固定した版の type-clipboard.exe を GitHub の Release から落とし、SHA-256 が
表 (Get-TypeClipboardReleases) の値と合うときだけ %LOCALAPPDATA%\Programs\type-clipboard に置き、
スタートメニューにショートカットを作る。合わなければ何も置かずに止まる。

入っている版は、置き場所の exe の SHA-256 を表と突き合わせて決める (exe は版の情報を持たず、GUI なので
--version のような問い合わせもしない)。動いている type-clipboard.exe は置き換えられないので、入れ替えが要る
ときに動いていれば、何も変えずに止まって知らせる (止めはしない。打っている途中かもしれないため)。
設定 (%APPDATA%\type-clipboard\settings.ini) には触らない。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。表 (Get-TypeClipboardReleases) にある版。版を上げるときは、表に行を足してここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3。

.PARAMETER IfMissing
入っていなければ固定した版を入れ、ショートカットを作る。入っていれば -Check と同じで、何も変えない (setup --update が使う)。

.PARAMETER InstallDir
exe を置くディレクトリ。既定は %LOCALAPPDATA%\Programs\type-clipboard。試すときだけ一時ディレクトリへ向ける。

.PARAMETER ShortcutDir
ショートカット (type-clipboard.lnk) を置くディレクトリ。既定はスタートメニューのプログラム
(%APPDATA%\Microsoft\Windows\Start Menu\Programs)。試すときだけ一時ディレクトリへ向ける。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.2.1',
    [switch]$Check,
    [switch]$IfMissing,
    [string]$InstallDir = '',
    [string]$ShortcutDir = ''
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-TypeClipboard.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 版ごとの type-clipboard.exe の SHA-256 (Release に置いた type-clipboard.exe.sha256 の中身。小文字の 16 進)。
# 版を上げるときは行を足して -Version の既定値を変える。古い版の行は、入っている版を名前で出すために残す
function Get-TypeClipboardReleases {
    [ordered]@{
        '0.1.0' = '6788930f8c18aa1c786297f7a40044ab94931449a84d51fabaa5a5c45457c840'
        '0.2.0' = '5335259f39fc68163087307159eaa2c5ee283fd31f014dfa9b79c68aef3cac15'
        '0.2.1' = 'a0c94c37a186d5f57c3c07a6ec2c3371c80fe2543ce6dfacda9027b559241be3'
    }
}

# 版の Release の exe の URL
function Get-TypeClipboardDownloadUrl {
    param([string]$Version)
    "https://github.com/pollenjp/type-clipboard/releases/download/v$Version/type-clipboard.exe"
}

# exe の SHA-256 から表の版を引く。無ければ $null (-eq は大文字小文字を区別しない)
function Find-TypeClipboardVersion {
    param($Releases, [string]$Hash)
    if (-not $Hash) { return $null }
    foreach ($key in $Releases.Keys) {
        if ($Releases[$key] -eq $Hash) { return $key }
    }
    $null
}

# 落とした物の SHA-256 が固定した値と同じか。どちらかが空なら同じと見ない
function Test-TypeClipboardHashMatch {
    param([string]$Expected, [string]$Actual)
    [bool]($Expected -and $Actual -and ($Expected -eq $Actual))
}

# 入っているか・入っている版・固定した版から、することを決める。
# exe があるのに表のどの版でもないときも入れ替える (固定した版にすれば揃う)
function Get-TypeClipboardPlan {
    param([bool]$Exists, [string]$Installed, [string]$Target)
    if (-not $Exists) { return 'install' }
    if ($Installed -cne $Target) { return 'change' }
    'none'
}

# 入れ替えの向き。版は X.Y.Z なので [version] で比べる (0.10.0 は 0.9.0 より新しい)
function Get-TypeClipboardDirection {
    param([string]$Installed, [string]$Target)
    $i = $null
    $t = $null
    if ((-not $Installed) -or (-not [version]::TryParse($Installed, [ref]$i)) -or (-not [version]::TryParse($Target, [ref]$t))) {
        return 'unknown'
    }
    if ($t -gt $i) { return 'up' }
    if ($t -lt $i) { return 'down' }
    'same'
}

# スタートメニューのショートカットが exe を指しているか。'ok' / 'missing' / 'other'
function Get-TypeClipboardShortcutKind {
    param([bool]$Exists, [string]$LinkTarget, [string]$Exe)
    if (-not $Exists) { return 'missing' }
    # -eq は大文字小文字を区別しない (Windows のパスと同じ)
    if ($LinkTarget -and ($LinkTarget -eq $Exe)) { return 'ok' }
    'other'
}

# 動いている type-clipboard.exe が、置き場所の exe を置き換える邪魔になるか。
# パスが読めない (管理者として動いているなど) ときは、置き場所のものかもしれないので邪魔と見る
function Test-TypeClipboardBusyPath {
    param([string]$Path, [string]$InstallDir)
    if (-not $Path) { return $true }
    $Path.StartsWith($InstallDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

# 終了コード。入っていなければ 3、版とショートカットが揃っていれば 0、ほかは 1
function Get-TypeClipboardExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if (($State.Plan -eq 'none') -and ($State.ShortcutKind -eq 'ok')) { return 0 }
    1
}

# 揃える前に止める理由。無ければ $null
#   busy: 入れ替えるのに、置き場所の type-clipboard.exe が動いている (置き換えられない)
function Get-TypeClipboardApplyBlocker {
    param([string]$Plan, [int]$BusyCount)
    if (($Plan -eq 'change') -and ($BusyCount -gt 0)) { return 'busy' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。ずれそのものではないこと (動いている type-clipboard がある) は ※ で添える
function Format-TypeClipboardState {
    param($State, [string]$Target, [string]$InstallDir)
    $direction = if ($State.Direction -eq 'up') { ' (上げる)' } elseif ($State.Direction -eq 'down') { ' (下げる)' } else { '' }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'change' { "入れ替える$direction" }
        default { 'そのまま' }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' }
    elseif ($State.Installed) { $State.Installed }
    elseif (-not $State.Hash) { '不明 (exe を読めない)' }
    else { '不明 (SHA-256 が表のどの版とも合わない)' }
    $shortcutText = switch ($State.ShortcutKind) {
        'ok' { 'あり' }
        'missing' { '無し → 作る' }
        default {
            if ($State.ShortcutTarget) { "$($State.ShortcutTarget) を指している → 作り直す" } else { '中身が読めない → 作り直す' }
        }
    }
    $rows = @(
        @{ Text = "type-clipboard (GitHub の Release、$InstallDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版     : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版       : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
        @{ Text = "スタートメニュー : $shortcutText"; Warn = ($State.ShortcutKind -ne 'ok'); Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    if (($State.Plan -eq 'change') -and ($State.BusyCount -gt 0)) {
        [pscustomobject]@{ Text = "※ type-clipboard.exe が $($State.BusyCount) 個動いている。入れ替えるには、type-clipboard の窓を閉じてから打ち直す (このスクリプトは止めない)"; Warn = $false }
    }
}

# ---------------------------------------------------------------------------
# ファイル・ネットワーク・Windows に触る関数 (テストでは偽物に差し替える。
# 実機では置き場所を一時ディレクトリに向けて -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# ファイルの SHA-256 (小文字の 16 進)。読めなければ $null。
# Get-FileHash は使わない。Windows PowerShell 5.1 では script の関数で、PowerShell 7 から起こした 5.1 は
# PSModulePath を継いで 7 の Microsoft.PowerShell.Utility を読み、Get-FileHash が見つからなくなる
function Get-TypeClipboardFileHash {
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

# URL の中身を OutFile に落とす。落とせなければ例外
function Invoke-TypeClipboardDownload {
    param([string]$Url, [string]$OutFile)
    # 進み具合の表示は Windows PowerShell 5.1 で落とすのを大きく遅くする
    $ProgressPreference = 'SilentlyContinue'
    # 5.1 (.NET Framework) は既定で TLS 1.2 を使わないことがあり、GitHub に断られる
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
}

# 落とした物を置き場所の exe にする (同じディレクトリの中なので名前を変えるだけ)。置けなければ例外。
# PowerShell 7 (.NET) の File.Move の上書きは 1 回の rename で置き換え (Windows では MoveFileEx の REPLACE_EXISTING)、
# 置き先が動いている exe なら置き先を消さずに落ちる。Windows PowerShell 5.1 (.NET Framework) の File.Move は上書きできず、
# Move-Item -Force は置き先を消してから名前を変えるので、その間で落ちると exe が無くなる (呼ぶ側が確かめて知らせる)
function Move-TypeClipboardFile {
    param([string]$Source, [string]$Destination)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        [IO.File]::Move($Source, $Destination, $true)
    } else {
        Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    }
}

# ショートカットが指す先。読めなければ空 (WScript.Shell の COM。Windows だけ)
function Get-TypeClipboardShortcutTarget {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    try {
        "$($shell.CreateShortcut($Path).TargetPath)"
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

# exe を指すショートカットを作る (あれば上書きする)
function New-TypeClipboardShortcut {
    param([string]$Path, [string]$Target)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($Path)
        $link.TargetPath = $Target
        $link.WorkingDirectory = Split-Path -Parent $Target
        $link.Description = 'クリップボードの文字を、選んだ窓へキー入力として打ち込む'
        $link.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

# 置き場所の exe を置き換える邪魔になる、動いている type-clipboard.exe
function Get-TypeClipboardBusyProcess {
    param([string]$InstallDir)
    @(Get-Process -Name 'type-clipboard' -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            Test-TypeClipboardBusyPath -Path $path -InstallDir $InstallDir
        })
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-TypeClipboardState {
    param([string]$Exe, [string]$Shortcut, [string]$InstallDir, [string]$Target, $Releases)
    $exists = Test-Path -LiteralPath $Exe -PathType Leaf
    $hash = $null
    if ($exists) { $hash = Get-TypeClipboardFileHash -Path $Exe }
    $installed = Find-TypeClipboardVersion -Releases $Releases -Hash $hash
    $linkExists = Test-Path -LiteralPath $Shortcut -PathType Leaf
    $linkTarget = $null
    if ($linkExists) { $linkTarget = Get-TypeClipboardShortcutTarget -Path $Shortcut }
    [pscustomobject]@{
        Exists         = $exists
        Hash           = $hash
        Installed      = $installed
        Plan           = Get-TypeClipboardPlan -Exists $exists -Installed $installed -Target $Target
        Direction      = Get-TypeClipboardDirection -Installed $installed -Target $Target
        ShortcutKind   = Get-TypeClipboardShortcutKind -Exists $linkExists -LinkTarget $linkTarget -Exe $Exe
        ShortcutTarget = $linkTarget
        BusyCount      = @(Get-TypeClipboardBusyProcess -InstallDir $InstallDir).Count
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-TypeClipboardState {
    param($State, [string]$Target, [string]$InstallDir)
    foreach ($row in (Format-TypeClipboardState -State $State -Target $Target -InstallDir $InstallDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 固定した版を落とし、SHA-256 が合えば置き場所の exe にする。置けたら $true。
# 置けないときは、わけを出して $false を返し、何も変えない (落とした物と、ここで作った置き場所は消す)
function Save-TypeClipboardExe {
    param([string]$Url, [string]$Expected, [string]$InstallDir, [string]$Exe)
    $created = $false
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        $created = $true
    }
    # 止められた前の実行 (setup の時間切れなど) が残した途中の物を消す。同時に走っている実行の物は消さないよう、
    # 10 分より古いものだけ
    $leaf = Split-Path -Leaf $Exe
    Get-ChildItem -LiteralPath $InstallDir -Filter "$leaf.download-*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # 置き場所と同じディレクトリに落とし、確かめてから名前を変える (途中で落ちても壊れた exe を残さない)
    $download = "$Exe.download-$PID"
    $existed = Test-Path -LiteralPath $Exe -PathType Leaf
    try {
        Write-Host "落とす: $Url"
        try {
            Invoke-TypeClipboardDownload -Url $Url -OutFile $download
        } catch {
            Write-Host "落とせなかった: $($_.Exception.Message)"
            Write-Host '何も変えていない。ネットワークと、上の URL (Release の版と exe の名前) を確かめて打ち直す'
            return $false
        }
        $actual = Get-TypeClipboardFileHash -Path $download
        if (-not $actual) {
            Write-Host '落とした物を読めなかった (何も変えていない)。打ち直す'
            return $false
        }
        if (-not (Test-TypeClipboardHashMatch -Expected $Expected -Actual $actual)) {
            Write-Host 'SHA-256 が固定した値と合わないので置かない (何も変えていない)'
            Write-Host "  固定した値 : $Expected"
            Write-Host "  落とした物 : $actual"
            Write-Host 'Release の exe が差し替えられたか、表の値の書き誤り。どちらかを確かめるまで入れない'
            return $false
        }
        try {
            Move-TypeClipboardFile -Source $download -Destination $Exe
        } catch {
            Write-Host "置けなかった: $($_.Exception.Message)"
            if ($existed -and -not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
                # Windows PowerShell 5.1 の Move-Item -Force が、古い exe を消した後で落ちたとき
                Write-Host '入っていた exe は消えた。Install-TypeClipboard を打ち直せば入る (setup --update でも入る)'
            } else {
                Write-Host 'type-clipboard が動いていれば、窓を閉じてから打ち直す (何も変えていない)'
            }
            return $false
        }
        Write-Host "置いた: $Exe"
        return $true
    } finally {
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
        if ($created -and -not (Test-Path -LiteralPath $Exe)) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-InstallTypeClipboard {
    param([string]$Version, [switch]$Check, [switch]$IfMissing, [string]$InstallDir, [string]$ShortcutDir)
    $releases = Get-TypeClipboardReleases
    if (-not $releases.Contains($Version)) {
        Write-Host "版 $Version の SHA-256 が Install-TypeClipboard.ps1 の表 (Get-TypeClipboardReleases) に無い。表にある版: $(@($releases.Keys) -join ', ')"
        return 2
    }
    if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\type-clipboard' }
    if (-not $ShortcutDir) { $ShortcutDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
    # 相対パスで渡されても、今の場所 (PowerShell の location) から解いた絶対パスにする。
    # [IO.File] などの .NET はプロセスの作業ディレクトリで解くので、相対のまま渡すと別の所を見る
    $InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)
    $ShortcutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ShortcutDir)
    $exe = Join-Path $InstallDir 'type-clipboard.exe'
    $shortcut = Join-Path $ShortcutDir 'type-clipboard.lnk'

    $state = Get-TypeClipboardState -Exe $exe -Shortcut $shortcut -InstallDir $InstallDir -Target $Version -Releases $releases
    Write-TypeClipboardState -State $state -Target $Version -InstallDir $InstallDir
    $code = Get-TypeClipboardExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        switch ($code) {
            0 { Write-Host '揃っている' }
            3 { Write-Host '⚠️ type-clipboard が入っていない → Install-TypeClipboard で入れる ⚠️' -ForegroundColor Yellow }
            default { Write-Host '⚠️ 固定した版と揃っていない → Install-TypeClipboard で揃える ⚠️' -ForegroundColor Yellow }
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    if ((Get-TypeClipboardApplyBlocker -Plan $state.Plan -BusyCount $state.BusyCount) -eq 'busy') {
        Write-Host 'type-clipboard.exe が動いていて置き換えられない。type-clipboard の窓を閉じてから打ち直す (このスクリプトは止めない):'
        foreach ($p in @(Get-TypeClipboardBusyProcess -InstallDir $InstallDir)) {
            Write-Host "  $($p.Id)  $($p.Path)"
        }
        return 1
    }

    if ($state.Plan -ne 'none') {
        $saved = Save-TypeClipboardExe -Url (Get-TypeClipboardDownloadUrl -Version $Version) -Expected $releases[$Version] -InstallDir $InstallDir -Exe $exe
        if (-not $saved) { return 1 }
    }
    if ($state.ShortcutKind -ne 'ok') {
        try {
            New-TypeClipboardShortcut -Path $shortcut -Target $exe
            Write-Host "ショートカットを置いた: $shortcut"
        } catch {
            Write-Host "ショートカットを置けなかった: $($_.Exception.Message)"
        }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-TypeClipboardState -Exe $exe -Shortcut $shortcut -InstallDir $InstallDir -Target $Version -Releases $releases
    Write-TypeClipboardState -State $after -Target $Version -InstallDir $InstallDir
    if ((Get-TypeClipboardExitCode -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の外部コマンドの 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallTypeClipboard -Version $Version -Check:$Check -IfMissing:$IfMissing -InstallDir $InstallDir -ShortcutDir $ShortcutDir)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
