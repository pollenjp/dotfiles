<#
.SYNOPSIS
Windows の Google 日本語入力 (winget の Google.JapaneseIME) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/google-japanese-input/Install-GoogleJapaneseInput.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-GoogleJapaneseInput から呼ぶ (win/README.md の「Google 日本語入力を入れる」)。

winget の Google.JapaneseIME は machine スコープの MSI (wix) だけで、入れる・上げるときは Windows の
デスクトップに UAC の確認が出る。日本語入力は全部のアプリに読み込まれているので、上げるとアプリや
Windows の再起動が要ることがある。そこで setup (bootstrap-windows-google-ime-install.sh) は入っていない
ときだけ -IfMissing で入れ、上げるのは人がこのスクリプトを打つ (ADR 016)。入っている版の方が新しくても
下げない (repo の版を上げるよう案内する)。

版は GoogleIMEJaConverter.exe の ProductVersion で読む (FileVersion は "2.29.5370.0  (build 63)" の形で、
winget の版と書き方が違う)。置き場所は版によって Program Files と Program Files (x86) のどちらかなので、両方を見る。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Google.JapaneseIME --versions に出る値。版を変えるときはここの既定値を変える
(win/README.md の「Google 日本語入力を入れる」の手順で、設定を読み書きできるかを確かめてから commit する)。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、
入っていなければ 3、確かめられなければ 2。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、上げはしない (setup --update が使う)。
#>
[CmdletBinding()]
param(
    [string]$Version = '3.34.6260.0',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-GoogleJapaneseInput.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 版の文字列 ("2.29.5370.0") を [version] にする。数字を . でつないだ 2〜4 個の形でなければ $null
# (FileVersion の "2.29.5370.0  (build 63)" のような形は読まない)
function ConvertTo-GoogleImeVersion {
    param([string]$Text)
    $v = $null
    if (("$Text" -match '^\s*(\d+(\.\d+){1,3})\s*$') -and [version]::TryParse($Matches[1], [ref]$v)) { return $v }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う (Install-Herdr.ps1 と同じ)。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# GoogleIMEJaConverter.exe を探す場所 (Program Files の候補ごとに 1 つ)。空の値と、大文字小文字だけが
# 違う重複は除く (64 ビットの PowerShell では ProgramW6432 と ProgramFiles が同じ)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Get-GoogleImeConverterPath {
    param([string[]]$Roots)
    $seen = @{}
    foreach ($root in $Roots) {
        if (-not $root) { continue }
        $dir = $root.TrimEnd('\')
        $key = $dir.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        "$dir\Google\Google Japanese Input\GoogleIMEJaConverter.exe"
    }
}

# 見つかった GoogleIMEJaConverter.exe (Path と ProductVersion の組) から 1 つ選ぶ。2 か所にあれば版の
# 新しい方。版が読めるものが無ければ最初のもの (Version は $null)。1 つも無ければ $null
function Select-GoogleImeConverter {
    param([object[]]$Candidates)
    $best = $null
    foreach ($c in @($Candidates | Where-Object { $_ })) {
        $v = ConvertTo-GoogleImeVersion -Text $c.ProductVersion
        if (($null -eq $best) -or (($null -ne $v) -and (($null -eq $best.Version) -or ($v -gt $best.Version)))) {
            $best = [pscustomobject]@{ Path = $c.Path; Version = $v }
        }
    }
    $best
}

# 入っているか・入っている版・固定した版から、することを決める
#   install: 入っていない / upgrade: 古い / newer: 新しい (下げない) / unknown: 版が読めない / none: 同じ
function Get-GoogleImePlan {
    param([bool]$Exists, [version]$Installed, [version]$Target)
    if (-not $Exists) { return 'install' }
    if ($null -eq $Installed) { return 'unknown' }
    if ($Installed -lt $Target) { return 'upgrade' }
    if ($Installed -gt $Target) { return 'newer' }
    'none'
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

# plan ごとに打つ winget の引数 (配列の配列)。上げるときは winget upgrade に版を名指しする
# (MSI の更新で入れ替わる。Install-OpenSSH.ps1 と同じ)
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    $put = $common + @('--version', $Version, '--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        'upgrade' { , (@('upgrade') + $put) }
    }
}

# 終了コード。入っていなければ 3、版と pin が揃っていれば 0、ほかは 1
function Get-GoogleImeExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if (($State.Plan -eq 'none') -and $State.Pinned) { return 0 }
    1
}

# 揃える前に止める理由。無ければ $null
#   newer:      入っている版の方が新しい (下げない)
#   unknown:    版が読めないので比べられない
#   not-listed: 入れる・上げるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
function Get-GoogleImeApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target)
    if ($Plan -eq 'newer') { return 'newer' }
    if ($Plan -eq 'unknown') { return 'unknown' }
    $known = @($Versions | Where-Object { $_ })
    if ((@('install', 'upgrade') -contains $Plan) -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。ずれではないこと (winget に新しい版がある) は ※ で添える
function Format-GoogleImeState {
    param($State, [string]$Target)
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'upgrade' { '上げる' }
        'newer' { '入っている版の方が新しい (下げない)' }
        'unknown' { '比べられない' }
        default { 'そのまま' }
    }
    $dir = ''
    if ($State.Path) {
        $cut = $State.Path.LastIndexOf('\')
        $dir = if ($cut -ge 0) { $State.Path.Substring(0, $cut) } else { $State.Path }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($null -ne $State.Installed) { "$($State.Installed) ($dir)" } else { "不明 (GoogleIMEJaConverter.exe の ProductVersion が読めない。$dir)" }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $rows = @(
        @{ Text = 'Google 日本語入力 (winget の Google.JapaneseIME)'; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
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
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-GoogleJapaneseInput.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    if ($State.Plan -eq 'newer') {
        [pscustomobject]@{ Text = "※ 入っている版の方が新しい (Google 日本語入力が自分で上がった?)。下げずに、Install-GoogleJapaneseInput.ps1 の -Version の既定値を $($State.Installed) に上げ、bootstrap-windows-google-ime.sh の --dry-run と --import で設定を読み書きできるかを確かめてから commit する"; Warn = $false }
    }
    if ($State.Plan -eq 'unknown') {
        [pscustomobject]@{ Text = '※ 版が読めないので比べられない。winget list --id Google.JapaneseIME で入っている版を確かめる'; Warn = $false }
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
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# Program Files (64 ビットと x86) にある GoogleIMEJaConverter.exe と、その ProductVersion
function Get-GoogleImeConverterOnDisk {
    foreach ($exe in @(Get-GoogleImeConverterPath -Roots @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}))) {
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            [pscustomobject]@{ Path = $exe; ProductVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
        }
    }
}

# 入っているか (揃えた後に pin を足すかを決める)
function Test-GoogleImeInstalled {
    @(Get-GoogleImeConverterOnDisk).Count -gt 0
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-GoogleImeState {
    param([string]$PackageId, [version]$Target)
    $converter = Select-GoogleImeConverter -Candidates @(Get-GoogleImeConverterOnDisk)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $exists = $null -ne $converter
    $path = $null
    $installed = $null
    if ($exists) {
        $path = $converter.Path
        $installed = $converter.Version
    }
    [pscustomobject]@{
        Exists    = $exists
        Path      = $path
        Installed = $installed
        Plan      = Get-GoogleImePlan -Exists $exists -Installed $installed -Target $Target
        Pinned    = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions  = $versions
        Latest    = $latest
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-GoogleImeState {
    param($State, [string]$Target)
    foreach ($row in (Format-GoogleImeState -State $State -Target $Target)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

function Invoke-InstallGoogleJapaneseInput {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'Google.JapaneseIME'
    # 書き間違えた -Version は、winget を打つ前にここで例外になる (終了コード 2)
    $target = [version]$Version

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-GoogleImeState -PackageId $packageId -Target $target
    Write-GoogleImeState -State $state -Target $Version
    $code = Get-GoogleImeExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if ($code -eq 0) {
            Write-Host '揃っている'
        } elseif ($code -eq 3) {
            Write-Host '⚠️ Google 日本語入力が入っていない → Install-GoogleJapaneseInput で入れる (UAC の確認が出る) ⚠️' -ForegroundColor Yellow
        } elseif ($state.Plan -eq 'newer') {
            Write-Host '⚠️ 入っている版の方が新しい → 下げずに Install-GoogleJapaneseInput.ps1 の -Version を上げる ⚠️' -ForegroundColor Yellow
        } else {
            Write-Host '⚠️ 固定した版と揃っていない → Install-GoogleJapaneseInput で揃える (上げるときは UAC の確認が出る) ⚠️' -ForegroundColor Yellow
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    $blocker = Get-GoogleImeApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version
    if ($blocker -eq 'newer') {
        Write-Host "入っている版 ($($state.Installed)) の方が固定した版 ($Version) より新しいので、下げない。Install-GoogleJapaneseInput.ps1 の -Version の既定値を上げる (win/README.md の「Google 日本語入力を入れる」)"
        return 1
    }
    if ($blocker -eq 'unknown') {
        Write-Host "GoogleIMEJaConverter.exe の版が読めないので、何もしない。winget list --id $packageId で入っている版を確かめる"
        return 1
    }
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }

    if ($state.Plan -eq 'upgrade') {
        Write-Host '上げる前に、日本語入力を使っているアプリをできるだけ閉じる (使用中のファイルは、Windows を再起動するまで置き換わらないことがある)'
    }
    if ($state.Plan -ne 'none') {
        Write-Host 'Windows のデスクトップに UAC の確認が出る。「はい」を押す'
    }
    # 上げるときは、古い版の pin を残さないよう先に外す (上げた後に足し直す。Install-Herdr.ps1 と同じ)
    if (($state.Plan -eq 'upgrade') -and $state.Pinned) {
        $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($unpin.ExitCode -ne 0) { Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode) }
    }
    foreach ($arguments in @(Get-WingetCommands -Plan $state.Plan -PackageId $packageId -Version $Version)) {
        Write-Host "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Host ('winget が失敗した (終了コード 0x{0:X8})。UAC で「いいえ」を押したなら、Install-GoogleJapaneseInput を打ち直す' -f $result.ExitCode)
            break
        }
    }
    # 入っていれば pin を足す (上げた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Test-GoogleImeInstalled) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-GoogleImeState -PackageId $packageId -Target $target
    Write-GoogleImeState -State $after -Target $Version
    if ((Get-GoogleImeExitCode -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    if ($after.Plan -eq 'upgrade') {
        Write-Host '版が揃っていない。使用中のファイルが Windows の再起動待ちになったなら、再起動してから Install-GoogleJapaneseInput -Check で確かめる'
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
        exit (Invoke-InstallGoogleJapaneseInput -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
