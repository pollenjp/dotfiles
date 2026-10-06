<#
.SYNOPSIS
Windows の herdr (winget の Herdr.Herdr.Preview) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/herdr/Install-Herdr.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Herdr から呼ぶ (win/README.md の「herdr を入れる」)。

herdr は portable (zip) のパッケージで、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の
下に入る。herdr server が動いている間は herdr.exe を置き換えられないので、入れ替えが要るときに
herdr が動いていれば、何も変えずに止める。server は止めない (herdr の pane の中で打つと自分ごと消える)。

herdr update (herdr 自身の更新) は %USERPROFILE%\.herdr に別に入れてユーザーの PATH の先頭に足し、
winget の管理から外れる。そこで PATH で先に引かれる herdr が winget のものかも確かめる。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Herdr.Herdr.Preview --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない (setup --update が使う)。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.9.2-preview.2026-09-29-8e78f929d8f0',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Herdr.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# herdr.exe --version の出力 ("herdr <版>") から版を拾う。無ければ $null
function Get-HerdrVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*herdr\s+(\S+)\s*$') { return $Matches[1] }
    }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# 入っているか・入っている版・固定した版から、することを決める。
# herdr.exe があるのに版が読めないときも入れ替える (外してから入れ直せば直る)
function Get-HerdrPlan {
    param([bool]$Exists, [string]$Installed, [string]$Target)
    if (-not $Exists) { return 'install' }
    if ($Installed -cne $Target) { return 'change' }
    'none'
}

# 入れ替えの向き。版の文字列は [version] にならないので、winget show --versions の
# 並び (新しい順) の位置で比べる
function Get-HerdrDirection {
    param([string[]]$Versions, [string]$Installed, [string]$Target)
    $list = @($Versions)
    $i = [array]::IndexOf($list, $Installed)
    $t = [array]::IndexOf($list, $Target)
    if ($i -lt 0 -or $t -lt 0) { return 'unknown' }
    if ($t -lt $i) { return 'up' }
    if ($t -gt $i) { return 'down' }
    'same'
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-OpenSSH.ps1 と同じ)。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。入れ替えは版の上げ下げによらず、外してから入れる
# (portable の置き場所は版によらず同じで、%APPDATA%\herdr の設定やセッションは消えない)
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    $put = $common + @('--version', $Version, '--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        'change' {
            , (@('uninstall') + $common)
            , (@('install') + $put)
        }
    }
}

# PATH (; 区切り) を前から見て、$Name が最初に見つかったパスを返す。無ければ $null。
# $Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Resolve-HerdrOnPath {
    param([string]$PathValue, [string]$Name, [scriptblock]$Exists)
    foreach ($entry in ($PathValue -split ';')) {
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if (-not $dir) { continue }
        $candidate = "$dir\$Name"
        if (& $Exists $candidate) { return $candidate }
    }
    $null
}

# PATH で引かれる herdr.exe が winget の置き場所のものか。'winget' / 'other' / 'none'
function Get-HerdrPathKind {
    param([string]$Resolved, [string]$PackageDir)
    if (-not $Resolved) { return 'none' }
    $cut = $Resolved.LastIndexOf('\')
    if ($cut -lt 0) { return 'other' }
    # -eq は大文字小文字を区別しない (Windows のパスと同じ)
    if ($Resolved.Substring(0, $cut) -eq $PackageDir.TrimEnd('\')) { return 'winget' }
    'other'
}

# 終了コード。入っていなければ 3、版・pin・PATH が揃っていれば 0、ほかは 1
function Get-HerdrExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if (($State.Plan -eq 'none') -and $State.Pinned -and ($State.PathKind -eq 'winget')) { return 0 }
    1
}

# 揃える前に止める理由。無ければ $null
#   not-listed: 入れる・入れ替えるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
#   busy:       入れ替えるのに、winget の置き場所の herdr.exe などが動いている (置き換えられない)
function Get-HerdrApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target, [int]$BusyCount)
    $known = @($Versions | Where-Object { $_ })
    if (($Plan -ne 'none') -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    if (($Plan -eq 'change') -and ($BusyCount -gt 0)) { return 'busy' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。ずれではないこと (新しい版がある・動いている herdr がある) は ※ で添える
function Format-HerdrState {
    param($State, [string]$Target, [string]$PackageDir)
    $direction = if ($State.Direction -eq 'up') { ' (上げる)' } elseif ($State.Direction -eq 'down') { ' (下げる)' } else { '' }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'change' { "入れ替える$direction" }
        default { 'そのまま' }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($State.Installed) { $State.Installed } else { '不明 (herdr.exe --version が読めない)' }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $pathText = switch ($State.PathKind) {
        'winget' { 'winget のもの' }
        'other' { "$($State.PathResolved) (winget のものではない)" }
        default { '見つからない' }
    }
    # 入っていないときに PATH に無いのは当たり前なので、⚠ にしない
    $pathWarn = ($State.PathKind -eq 'other') -or (($State.PathKind -eq 'none') -and ($State.Plan -ne 'install'))
    $rows = @(
        @{ Text = "herdr (winget の Herdr.Herdr.Preview、$PackageDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
        @{ Text = "PATH の herdr   : $pathText"; Warn = $pathWarn; Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    $versions = @($State.Versions | Where-Object { $_ })
    if (($versions.Count -gt 0) -and ($versions -cnotcontains $Target)) {
        if ($State.Plan -eq 'none') {
            [pscustomobject]@{ Text = '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える'; Warn = $false }
        } else {
            [pscustomobject]@{ Text = '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない'; Warn = $true }
        }
    } elseif (($versions.Count -gt 0) -and ($versions[0] -cne $Target)) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-Herdr.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    if (($State.Plan -eq 'change') -and ($State.BusyCount -gt 0)) {
        [pscustomobject]@{ Text = "※ herdr.exe などが $($State.BusyCount) 個動いている。入れ替えるには、herdr の外の PowerShell で hsvstop を打ち、herdr --remote の窓も閉じる"; Warn = $false }
    }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-OpenSSH.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[\u2588\u2592]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# winget の置き場所の herdr.exe に版を聞く (herdr.exe には FileVersion が無い)。読めなければ $null
function Get-HerdrInstalledVersion {
    param([string]$Exe)
    $ErrorActionPreference = 'Continue'
    $out = @(& $Exe --version 2>&1 | ForEach-Object { "$_" })
    Get-HerdrVersionFromOutput -Lines $out
}

# これから開く PowerShell が使う PATH (マシン → ユーザーの順)。今のプロセスの PATH は古いことがある
function Get-HerdrPathValue {
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}

# winget の置き場所から起動して動いているプロセス (herdr server・herdr --remote・conpty の OpenConsole.exe)
function Get-HerdrBusyProcess {
    param([string]$PackageDir)
    $prefix = $PackageDir.TrimEnd('\') + '\'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            $path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        })
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-HerdrState {
    param([string]$PackageId, [string]$PackageDir, [string]$Target)
    $exe = Join-Path $PackageDir 'herdr.exe'
    $exists = Test-Path -LiteralPath $exe -PathType Leaf
    $installed = $null
    if ($exists) { $installed = Get-HerdrInstalledVersion -Exe $exe }
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $resolved = Resolve-HerdrOnPath -PathValue (Get-HerdrPathValue) -Name 'herdr.exe' -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    [pscustomobject]@{
        Exists       = $exists
        Installed    = $installed
        Plan         = Get-HerdrPlan -Exists $exists -Installed $installed -Target $Target
        Direction    = Get-HerdrDirection -Versions $versions -Installed $installed -Target $Target
        Pinned       = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions     = $versions
        Latest       = $latest
        PathResolved = $resolved
        PathKind     = Get-HerdrPathKind -Resolved $resolved -PackageDir $PackageDir
        BusyCount    = @(Get-HerdrBusyProcess -PackageDir $PackageDir).Count
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-HerdrState {
    param($State, [string]$Target, [string]$PackageDir)
    foreach ($row in (Format-HerdrState -State $State -Target $Target -PackageDir $PackageDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

function Invoke-InstallHerdr {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'Herdr.Herdr.Preview'
    # portable の置き場所は <Id>_<ソースの識別子>。winget のソースから入れると、どのマシンでも同じ名前になる
    $packageDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-HerdrState -PackageId $packageId -PackageDir $packageDir -Target $Version
    Write-HerdrState -State $state -Target $Version -PackageDir $packageDir
    $code = Get-HerdrExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        switch ($code) {
            0 { Write-Host '揃っている' }
            3 { Write-Host '⚠️ herdr が入っていない → Install-Herdr で入れる ⚠️' -ForegroundColor Yellow }
            default { Write-Host '⚠️ 固定した版と揃っていない → Install-Herdr で揃える ⚠️' -ForegroundColor Yellow }
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    $blocker = Get-HerdrApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version -BusyCount $state.BusyCount
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }
    if ($blocker -eq 'busy') {
        Write-Host 'herdr.exe などが動いていて置き換えられない。herdr の外の PowerShell (Windows Terminal など) で hsvstop を打ち、herdr --remote の窓も閉じてから打ち直す:'
        foreach ($p in @(Get-HerdrBusyProcess -PackageDir $packageDir)) {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
            Write-Host "  $($p.Id)  $commandLine"
        }
        return 1
    }

    # 入れ替えるときは、古い版の pin を残さないよう先に外す (入れた後に足し直す)
    if (($state.Plan -eq 'change') -and $state.Pinned) {
        $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($unpin.ExitCode -ne 0) { Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode) }
    }
    foreach ($arguments in @(Get-WingetCommands -Plan $state.Plan -PackageId $packageId -Version $Version)) {
        Write-Host "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Host ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
            break
        }
    }
    # 入っていれば pin を足す (入れ替えた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Test-Path -LiteralPath (Join-Path $packageDir 'herdr.exe')) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-HerdrState -PackageId $packageId -PackageDir $packageDir -Target $Version
    Write-HerdrState -State $after -Target $Version -PackageDir $packageDir
    if ($after.PathKind -eq 'other') {
        Write-Host 'PATH で先に引かれる herdr は、herdr update で入ったもの。外し方は win/README.md の「herdr を入れる」'
    }
    if ((Get-HerdrExitCode -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallHerdr -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
