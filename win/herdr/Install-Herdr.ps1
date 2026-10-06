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
