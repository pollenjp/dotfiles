<#
.SYNOPSIS
Windows の T3 Code (winget の T3Tools.T3Code) を、決めた版で入れる。

.DESCRIPTION
dotfiles の win/t3-code/Install-T3Code.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-T3Code から呼ぶ (win/README.md の「T3 Code」)。

winget の T3Tools.T3Code は user スコープの nullsoft (electron-builder の NSIS) の installer で、%LOCALAPPDATA%\Programs\t3code に入る。
管理者の権限は要らず、UAC の確認は出ない。

runner (手順 t3-code。ホストの値の [tools] windowsT3Code = true のマシンだけ) は入っていないときだけ -IfMissing で入れ、上げはしない。
T3 Code は自分で上がる (app の自動更新) ので、入っている版の方が新しくても下げず、揃っている扱いにする (固定した版は、新しく入れるときの
版)。古いときは知らせ、上げるのは人がこのスクリプトを打つ。テレメトリの環境変数と settings.json は runner の手順 t3-code-settings が
合わせる (ここでは触らない)。

入っている版は、winget の manifest の ProductCode (e9197887-efb3-55e0-985e-d6d3b5dd594a) の HKCU の Uninstall キーの DisplayVersion で読む
(winget list の表は表示言語で列が変わるので読まない)。そのキーが無ければ、HKCU の Uninstall のうち DisplayName が T3 Code で始まるものを
見る。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id T3Tools.T3Code --versions に出る値。版を変えるときはここの既定値を変え、Linux の nix/pkgs/t3-code の
version と揃える (win/README.md の「T3 Code の新しい版が出たとき」)。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば (入っている版の方が新しいときも) 終了コード 0、
差があれば 1、入っていなければ 3、確かめられなければ 2。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、上げはしない (runner が使う)。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.1.11',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-T3Code.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 版の文字列 ("0.1.11") を [version] にする。数字を . でつないだ 3 個の形でなければ $null
# (winget の T3Tools.T3Code の版と、Uninstall キーの DisplayVersion はどちらも X.Y.Z)
function ConvertTo-T3CodeVersion {
    param([string]$Text)
    $v = $null
    if (("$Text" -match '^\s*(\d+\.\d+\.\d+)\s*$') -and [version]::TryParse($Matches[1], [ref]$v)) {
        return $v
    }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う (Install-Tailscale.ps1 と同じ)。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# HKCU の Uninstall の項目 (KeyName・DisplayName・DisplayVersion・InstallLocation の組) から T3 Code のものを 1 つ選ぶ。ProductCode の
# キーがあればそれ、無ければ DisplayName が T3 Code で始まるもの (最初のもの)。無ければ $null
function Select-T3CodeUninstallEntry {
    param([object[]]$Entries, [string]$ProductCode)
    $entries = @($Entries | Where-Object { $_ })
    foreach ($e in $entries) {
        if ("$($e.KeyName)" -ieq $ProductCode -or "$($e.KeyName)" -ieq "{$ProductCode}") { return $e }
    }
    foreach ($e in $entries) {
        if ("$($e.DisplayName)" -match '^T3 Code\b') { return $e }
    }
    $null
}

# 入っているか・入っている版・固定した版から、することを決める
#   install: 入っていない / upgrade: 古い / newer: 新しい (自動更新で上がった。下げない) / unknown: 版が読めない / none: 同じ
function Get-T3CodePlan {
    param([bool]$Exists, [version]$Installed, [version]$Target)
    if (-not $Exists) { return 'install' }
    if ($null -eq $Installed) { return 'unknown' }
    if ($Installed -lt $Target) { return 'upgrade' }
    if ($Installed -gt $Target) { return 'newer' }
    'none'
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-Tailscale.ps1 と同じ)
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。どちらも版を名指しし、user スコープの installer を選ぶ (--scope user)。user スコープの
# NSIS は UAC を出さないので --silent で流す。upgrade には --include-pinned を付ける (この script が足した pin に止められないよう。
# Install-Tailscale.ps1 と同じ)。install は --include-pinned を受け付けない
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--version', $Version, '--scope', 'user', '--silent')
    $tail = @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    switch ($Plan) {
        'install' { , (@('install') + $common + $tail) }
        'upgrade' { , (@('upgrade') + $common + $tail + @('--include-pinned')) }
    }
}

# 終了コード。入っていなければ 3、版 (入っている版の方が新しいときも) と pin が揃っていれば 0、ほかは 1
function Get-T3CodeExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if ((@('none', 'newer') -contains $State.Plan) -and $State.Pinned) { return 0 }
    1
}

# 揃える前に止める理由。無ければ $null
#   unknown:    版が読めないので比べられない
#   not-listed: 入れる・上げるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
function Get-T3CodeApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target)
    if ($Plan -eq 'unknown') { return 'unknown' }
    $known = @($Versions | Where-Object { $_ })
    if ((@('install', 'upgrade') -contains $Plan) -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。ずれではないこと
# (入っている版の方が新しい・winget に新しい版がある) は ※ で添える
function Format-T3CodeState {
    param($State, [string]$Target)
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'upgrade' { '上げる' }
        'newer' { '入っている版の方が新しい (下げない)' }
        'unknown' { '比べられない' }
        default { 'そのまま' }
    }
    $where = if ($State.Location) { " ($($State.Location))" } else { '' }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($null -ne $State.Installed) { "$($State.Installed)$where" } else { "不明 (DisplayVersion が読めない$where)" }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $rows = @(
        @{ Text = 'T3 Code (winget の T3Tools.T3Code)'; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = (@('none', 'newer') -notcontains $State.Plan); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    $versions = @($State.Versions | Where-Object { $_ })
    if (($versions.Count -gt 0) -and ($versions -cnotcontains $Target)) {
        if (@('install', 'upgrade') -contains $State.Plan) {
            [pscustomobject]@{ Text = '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない'; Warn = $true }
        } else {
            [pscustomobject]@{ Text = '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える'; Warn = $false }
        }
    } elseif (($versions.Count -gt 0) -and ($versions[0] -cne $Target)) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-T3Code.ps1 の -Version の既定値と nix/pkgs/t3-code の version を変える (入っている T3 Code は、自動更新で自分で上がる)"; Warn = $false }
    }
    if ($State.Plan -eq 'newer') {
        [pscustomobject]@{ Text = '※ 入っている版の方が新しい (T3 Code の自動更新で上がった?)。下げない。固定した版は、新しく入れるときの版'; Warn = $false }
    }
    if ($State.Plan -eq 'unknown') {
        [pscustomobject]@{ Text = '※ 版が読めないので比べられない。winget list --id T3Tools.T3Code で入っている版を確かめる'; Warn = $false }
    }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-Tailscale.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# HKCU の Uninstall の項目を読む (KeyName・DisplayName・DisplayVersion・InstallLocation)
function Get-T3CodeUninstallEntries {
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    if (-not (Test-Path -LiteralPath $root)) { return }
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $names = @($p.PSObject.Properties.Name)
        [pscustomobject]@{
            KeyName         = $key.PSChildName
            DisplayName     = if ($names -contains 'DisplayName') { [string]$p.DisplayName } else { $null }
            DisplayVersion  = if ($names -contains 'DisplayVersion') { [string]$p.DisplayVersion } else { $null }
            InstallLocation = if ($names -contains 'InstallLocation') { [string]$p.InstallLocation } else { $null }
        }
    }
}

# 今の状態を読む (何も変えない)
function Get-T3CodeState {
    param([string]$PackageId, [string]$ProductCode, [version]$Target)
    $entry = Select-T3CodeUninstallEntry -Entries @(Get-T3CodeUninstallEntries) -ProductCode $ProductCode
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $exists = $null -ne $entry
    $installed = $null
    $location = $null
    if ($exists) {
        $installed = ConvertTo-T3CodeVersion -Text $entry.DisplayVersion
        $location = $entry.InstallLocation
    }
    [pscustomobject]@{
        Exists    = $exists
        Location  = $location
        Installed = $installed
        Plan      = Get-T3CodePlan -Exists $exists -Installed $installed -Target $Target
        Pinned    = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions  = $versions
        Latest    = $latest
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-T3CodeState {
    param($State, [string]$Target)
    foreach ($row in (Format-T3CodeState -State $State -Target $Target)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

function Invoke-InstallT3Code {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'T3Tools.T3Code'
    $productCode = 'e9197887-efb3-55e0-985e-d6d3b5dd594a'
    # 書き間違えた -Version は、winget を打つ前にここで例外になる (終了コード 2)
    $target = ConvertTo-T3CodeVersion -Text $Version
    if (-not $target) { throw "-Version の形が違う: $Version" }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-T3CodeState -PackageId $packageId -ProductCode $productCode -Target $target
    Write-T3CodeState -State $state -Target $Version
    $code = Get-T3CodeExitCode -State $state
    $blocker = Get-T3CodeApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if (($code -eq 0) -and ($state.Plan -eq 'newer')) {
            Write-Host '揃っている (入っている版の方が新しい。下げない)'
        } elseif ($code -eq 0) {
            Write-Host '揃っている'
        } elseif ($blocker -eq 'not-listed') {
            Write-Host "⚠️ 固定した版 $Version が winget に無い → Install-T3Code.ps1 の -Version を winget show --id $packageId --versions にある版へ変える ⚠️" -ForegroundColor Yellow
        } elseif ($code -eq 3) {
            Write-Host '⚠️ T3 Code が入っていない → Install-T3Code で入れる ⚠️' -ForegroundColor Yellow
        } elseif ($state.Plan -eq 'unknown') {
            Write-Host "⚠️ 入っている版が読めない → winget list --id $packageId で入っている版を確かめる ⚠️" -ForegroundColor Yellow
        } elseif (@('none', 'newer') -contains $state.Plan) {
            Write-Host '⚠️ winget pin が無い → Install-T3Code で足す ⚠️' -ForegroundColor Yellow
        } else {
            Write-Host '⚠️ 固定した版より古い → Install-T3Code で揃える (T3 Code を閉じてから) ⚠️' -ForegroundColor Yellow
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    if ($blocker -eq 'unknown') {
        Write-Host "T3 Code の版が読めないので、何もしない。winget list --id $packageId で入っている版を確かめる"
        return 1
    }
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }

    if ($state.Plan -eq 'upgrade') {
        Write-Host '上げる前に T3 Code を閉じる (動いている app は入れ替えられない。T3 の会話は止まる)'
        if ($state.Pinned) {
            $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
            if ($unpin.ExitCode -ne 0) { Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode) }
        }
    }
    foreach ($arguments in @(Get-WingetCommands -Plan $state.Plan -PackageId $packageId -Version $Version)) {
        Write-Host "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Host ('winget が失敗した (終了コード 0x{0:X8})。T3 Code が動いていれば閉じてから、Install-T3Code を打ち直す' -f $result.ExitCode)
            break
        }
    }
    # 入っていれば pin を足す (上げた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $installedNow = $null -ne (Select-T3CodeUninstallEntry -Entries @(Get-T3CodeUninstallEntries) -ProductCode $productCode)
    if ($installedNow -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる。T3 Code の自動更新は止めない)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-T3CodeState -PackageId $packageId -ProductCode $productCode -Target $target
    Write-T3CodeState -State $after -Target $Version
    if ((Get-T3CodeExitCode -State $after) -eq 0) {
        if ($state.Plan -eq 'install') {
            Write-Host 'T3 Code のサインイン (T3 Connect)・Claude のログインは手でする (win/README.md の「T3 Code」)'
        }
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
        exit (Invoke-InstallT3Code -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
