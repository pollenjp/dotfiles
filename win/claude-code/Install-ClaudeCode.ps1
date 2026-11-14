<#
.SYNOPSIS
Windows の Claude Code (winget の Anthropic.ClaudeCode) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/claude-code/Install-ClaudeCode.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-ClaudeCode から呼ぶ (win/README.md の「Claude Code」)。

Claude Code は portable のパッケージ (claude.exe 1 つ) で、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の
下に入る。winget で入れた Claude Code は自分では上がらない (claude update は何もしない)。claude.exe が動いている間は
置き換えられないので、入れ替えが要るときに置き場所の claude.exe が動いていれば (Windows で Claude Code の会話を
開いていれば)、何も変えずに止める (止めはしない)。WSL の claude は別のもの (mise が入れる) で、ここでは見ない。

形は Install-Ntn.ps1 (Install-Herdr.ps1) と同じ。setup --update (bootstrap-windows-claude-code.sh) が版のずれも揃える。
CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE (Claude Code に winget upgrade を打たせる) は設定しない。設定されていれば
固定した版から外れうるので、※ で知らせる。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Anthropic.ClaudeCode --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない。
#>
[CmdletBinding()]
param(
    [string]$Version = '2.1.318',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-ClaudeCode.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# claude.exe --version の出力 ("<版> (Claude Code)") から版を拾う。無ければ $null
function Get-ClaudeCodeVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+)\s+\(Claude Code\)\s*$') { return $Matches[1] }
    }
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

# 入っているか・入っている版・固定した版から、することを決める。
# claude.exe があるのに版が読めないときも入れ替える (外してから入れ直せば直る)
function Get-ClaudeCodePlan {
    param([bool]$Exists, [string]$Installed, [string]$Target)
    if (-not $Exists) { return 'install' }
    if ($Installed -cne $Target) { return 'change' }
    'none'
}

# 入れ替えの向き。winget show --versions の並び (新しい順) の位置で比べる
function Get-ClaudeCodeDirection {
    param([string[]]$Versions, [string]$Installed, [string]$Target)
    $list = @($Versions)
    $i = [array]::IndexOf($list, $Installed)
    $t = [array]::IndexOf($list, $Target)
    if ($i -lt 0 -or $t -lt 0) { return 'unknown' }
    if ($t -lt $i) { return 'up' }
    if ($t -gt $i) { return 'down' }
    'same'
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

# plan ごとに打つ winget の引数 (配列の配列。Install-Herdr.ps1 と同じ)。入れ替えは版の上げ下げによらず、
# 外してから入れる (portable の置き場所は版によらず同じ。設定とログインの %USERPROFILE%\.claude は置き場所の外)
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

# 入れ替えの前に、固定した版の取得とハッシュだけを確かめる winget download の引数 (Install-Herdr.ps1 と同じ)
function Get-WingetDownloadArguments {
    param([string]$PackageId, [string]$Version, [string]$Directory)
    @('download', '--id', $PackageId, '--exact', '--source', 'winget', '--version', $Version,
        '--download-directory', $Directory, '--skip-dependencies', '--accept-package-agreements',
        '--accept-source-agreements', '--disable-interactivity')
}

# PATH (; 区切り) を前から見て、$Names のどれかが最初に見つかったパスを返す。無ければ $null。
# PowerShell は PATH のディレクトリの順に、.exe だけでなく .cmd・.bat・.ps1 も引く (npm の global は claude.cmd を置く) ので、
# ディレクトリごとに名前を並べて見る。$Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Resolve-ClaudeCodeOnPath {
    param([string]$PathValue, [string[]]$Names, [scriptblock]$Exists)
    foreach ($entry in ($PathValue -split ';')) {
        $dir = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if (-not $dir) { continue }
        foreach ($name in $Names) {
            $candidate = "$dir\$name"
            if (& $Exists $candidate) { return $candidate }
        }
    }
    $null
}

# PATH で引かれる claude.exe がどこのものか。'winget' (Anthropic.ClaudeCode の置き場所か、winget が symlink を置く
# WinGet\Links) / 'other' (native の installer や claude install が置く %USERPROFILE%\.local\bin、npm の global など) / 'none'
function Get-ClaudeCodePathKind {
    param([string]$Resolved, [string]$ExeDir, [string]$LinksDir)
    if (-not $Resolved) { return 'none' }
    $cut = $Resolved.LastIndexOf('\')
    if ($cut -lt 0) { return 'other' }
    $dir = $Resolved.Substring(0, $cut)
    foreach ($d in @($ExeDir, $LinksDir)) {
        # -eq は大文字小文字を区別しない (Windows のパスと同じ)
        if ($d -and ($dir -eq $d.TrimEnd('\'))) { return 'winget' }
    }
    'other'
}

# CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE の値が、Claude Code に winget upgrade を打たせる値か
function Test-ClaudeCodeAutoUpdateValue {
    param([string]$Value)
    "$Value".Trim() -in @('1', 'true')
}

# 揃える手順 (Install-ClaudeCode) で直る差 (版・pin) があるか
function Test-ClaudeCodeDrift {
    param($State)
    ($State.Plan -ne 'none') -or (-not $State.Pinned)
}

# PATH のずれ (ほかの claude.exe が先に引かれる・入っているのに PATH に無い) があるか。揃える手順では直らないので、
# ※ の行で直し方を添える。入っていないときに PATH に無いのは当たり前なので数えない
function Test-ClaudeCodePathDrift {
    param($State)
    ($State.PathKind -eq 'other') -or (($State.PathKind -eq 'none') -and ($State.Plan -ne 'install'))
}

# 終了コード。入っていなければ 3、版・pin・PATH が揃っていれば 0、ほかは 1。自動更新の変数は差に数えない
function Get-ClaudeCodeExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if ((Test-ClaudeCodeDrift -State $State) -or (Test-ClaudeCodePathDrift -State $State)) { return 1 }
    0
}

# 揃える前に止める理由。無ければ $null
#   not-listed: 入れる・入れ替えるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
#   busy:       入れ替えるのに、置き場所の claude.exe が動いている (置き換えられない)
function Get-ClaudeCodeApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target, [int]$BusyCount)
    $known = @($Versions | Where-Object { $_ })
    if (($Plan -ne 'none') -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    if (($Plan -eq 'change') -and ($BusyCount -gt 0)) { return 'busy' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。ずれではないこと (新しい版がある・動いている・自動更新の変数) は ※ で添える
function Format-ClaudeCodeState {
    param($State, [string]$Target, [string]$PackageId, [string]$PackageDir)
    $direction = if ($State.Direction -eq 'up') { ' (上げる)' } elseif ($State.Direction -eq 'down') { ' (下げる)' } else { '' }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'change' { "入れ替える$direction" }
        default { 'そのまま' }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($State.Installed) { $State.Installed } else { '不明 (claude.exe --version が読めない)' }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $pathText = switch ($State.PathKind) {
        'winget' { 'winget のもの' }
        'other' { "$($State.PathResolved) (winget のものではない)" }
        default { '見つからない' }
    }
    $rows = @(
        @{ Text = "Claude Code (winget の $PackageId、$PackageDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
        @{ Text = "PATH の claude  : $pathText"; Warn = (Test-ClaudeCodePathDrift -State $State); Indent = $true }
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
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-ClaudeCode.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    # PATH のずれは揃える手順 (Install-ClaudeCode) では直らないので、直し方を添える
    if ($State.PathKind -eq 'other') {
        $cut = $State.PathResolved.LastIndexOf('\')
        $dir = if ($cut -ge 0) { $State.PathResolved.Substring(0, $cut) } else { $State.PathResolved }
        [pscustomobject]@{ Text = "※ PATH のずれは Install-ClaudeCode では直らない。$dir の claude.exe を外す (native の installer・claude install・npm で入れたものの外し方は win/README.md の「Claude Code」)"; Warn = $false }
    } elseif (($State.PathKind -eq 'none') -and ($State.Plan -ne 'install')) {
        [pscustomobject]@{ Text = "※ Claude Code の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $PackageId の後に Install-ClaudeCode で入れ直す"; Warn = $false }
    }
    if (($State.Plan -eq 'change') -and ($State.BusyCount -gt 0)) {
        [pscustomobject]@{ Text = "※ claude.exe が $($State.BusyCount) 個動いている。入れ替えるには、Windows で開いている Claude Code の会話を閉じる (WSL の claude は別のもの)"; Warn = $false }
    }
    if ($State.AutoUpdate) {
        [pscustomobject]@{ Text = "※ CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE が $($State.AutoUpdate) で有効になっている。Claude Code が自分で winget upgrade を打ち、固定した版から外れうる (dotfiles は設定しない。外すなら消す)"; Warn = $false }
    }
}

# 締めの行 (-Check の最後と、揃えた後の最後)。揃っていれば何も返さない。直すことごとに ⚠️ で始まる行を返す。
# bootstrap-windows-claude-code.sh は ⚠️ で始まる行を枠の本文から落とし、「→ Install-ClaudeCode で入れる」
# 「→ Install-ClaudeCode で揃える」「→ ※ の手順で直す」の文言で、入れるか・揃えるか・知らせるだけかを決める
# (文言を変えるときは向こうも直す)
function Format-ClaudeCodeVerdict {
    param($State)
    if ((Get-ClaudeCodeExitCode -State $State) -eq 3) {
        '⚠️ Claude Code が入っていない → Install-ClaudeCode で入れる ⚠️'
        return
    }
    if (Test-ClaudeCodeDrift -State $State) { '⚠️ 固定した版と揃っていない → Install-ClaudeCode で揃える ⚠️' }
    if (Test-ClaudeCodePathDrift -State $State) { '⚠️ PATH の claude が winget のものではない → ※ の手順で直す ⚠️' }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-Herdr.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# claude.exe に版を聞く。読めなければ $null
function Get-ClaudeCodeInstalledVersion {
    param([string]$Exe)
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe --version 2>&1 | ForEach-Object { "$_" })
    } catch {
        # 起動できない (壊れた・0 バイト・方針で止められた) ときも、版が読めないとして入れ替えの対象にする
        return $null
    }
    Get-ClaudeCodeVersionFromOutput -Lines $out
}

# CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE が有効になっている所 (ユーザー・マシンの環境変数か、
# %USERPROFILE%\.claude\settings.json の env)。無ければ $null。settings.json が読めなければ黙る
function Get-ClaudeCodeAutoUpdateSource {
    $name = 'CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE'
    foreach ($scope in @('User', 'Machine')) {
        if (Test-ClaudeCodeAutoUpdateValue -Value ([Environment]::GetEnvironmentVariable($name, $scope))) {
            return "$scope の環境変数"
        }
    }
    $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (Test-Path -LiteralPath $settings -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.PSObject.Properties['env'] -and $json.env -and $json.env.PSObject.Properties[$name]) {
                if (Test-ClaudeCodeAutoUpdateValue -Value "$($json.env.$name)") { return "$settings の env" }
            }
        } catch {
            return $null
        }
    }
    $null
}

# これから開く PowerShell が使う PATH (マシン → ユーザーの順)。今のプロセスの PATH は古いことがある
function Get-ClaudeCodePathValue {
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}

# 置き場所の下の exe から起動して動いているプロセス (Windows で開いている Claude Code の会話)
function Get-ClaudeCodeBusyProcess {
    param([string]$PackageDir)
    $prefix = $PackageDir.TrimEnd('\') + '\'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            $path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        })
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-ClaudeCodeState {
    param([string]$PackageId, [string]$PackageDir, [string]$LinksDir, [string]$Target)
    $exe = Join-Path $PackageDir 'claude.exe'
    $exists = Test-Path -LiteralPath $exe -PathType Leaf
    $installed = $null
    if ($exists) { $installed = Get-ClaudeCodeInstalledVersion -Exe $exe }
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $resolved = Resolve-ClaudeCodeOnPath -PathValue (Get-ClaudeCodePathValue) -Names @('claude.exe', 'claude.cmd', 'claude.bat', 'claude.ps1') -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    [pscustomobject]@{
        Exists       = $exists
        Installed    = $installed
        Plan         = Get-ClaudeCodePlan -Exists $exists -Installed $installed -Target $Target
        Direction    = Get-ClaudeCodeDirection -Versions $versions -Installed $installed -Target $Target
        Pinned       = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions     = $versions
        Latest       = $latest
        PathResolved = $resolved
        PathKind     = Get-ClaudeCodePathKind -Resolved $resolved -ExeDir $PackageDir -LinksDir $LinksDir
        BusyCount    = @(Get-ClaudeCodeBusyProcess -PackageDir $PackageDir).Count
        AutoUpdate   = Get-ClaudeCodeAutoUpdateSource
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-ClaudeCodeState {
    param($State, [string]$Target, [string]$PackageId, [string]$PackageDir)
    foreach ($row in (Format-ClaudeCodeState -State $State -Target $Target -PackageId $PackageId -PackageDir $PackageDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 締めの行 (直すこと) を黄色で出す。揃っていれば何も出さない
function Write-ClaudeCodeVerdict {
    param($State)
    foreach ($line in (Format-ClaudeCodeVerdict -State $State)) {
        Write-Host $line -ForegroundColor Yellow
    }
}

function Invoke-InstallClaudeCode {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'Anthropic.ClaudeCode'
    # portable の置き場所は <Id>_<ソースの識別子>。winget のソースから入れると、どのマシンでも同じ名前になる
    $packageDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe'
    $linksDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-ClaudeCodeState -PackageId $packageId -PackageDir $packageDir -LinksDir $linksDir -Target $Version
    Write-ClaudeCodeState -State $state -Target $Version -PackageId $packageId -PackageDir $packageDir
    $code = Get-ClaudeCodeExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if ($code -eq 0) { Write-Host '揃っている' }
        Write-ClaudeCodeVerdict -State $state
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }
    # 揃える手順で直す差 (版・pin) が無く、残っているのは PATH のずれだけ
    if (-not (Test-ClaudeCodeDrift -State $state)) {
        Write-Host '版と pin は揃っている。PATH のずれは Install-ClaudeCode では直らない (上の ※ の行の手順で直す)'
        Write-ClaudeCodeVerdict -State $state
        return 1
    }

    $blocker = Get-ClaudeCodeApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version -BusyCount $state.BusyCount
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }
    if ($blocker -eq 'busy') {
        Write-Host 'claude.exe が動いていて置き換えられない。Windows で開いている Claude Code の会話を閉じてから打ち直す:'
        foreach ($p in @(Get-ClaudeCodeBusyProcess -PackageDir $packageDir)) {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
            Write-Host "  $($p.Id)  $commandLine"
        }
        return 1
    }

    # 入れ替えは外してから入れるので、取得が落ちると Claude Code が消えたまま終わる。
    # 外す前に、固定した版を取得してハッシュまで確かめる (落ちたら何も変えずに止める)
    if ($state.Plan -eq 'change') {
        $downloadDir = Join-Path ([IO.Path]::GetTempPath()) "install-claude-code-$PID"
        $arguments = @(Get-WingetDownloadArguments -PackageId $packageId -Version $Version -Directory $downloadDir)
        Write-Host "winget $($arguments -join ' ')"
        $download = Invoke-Winget -Arguments $arguments
        Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($download.ExitCode -ne 0) {
            $download.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
            Write-Host ('固定した版を取得できなかった (終了コード 0x{0:X8})。何も変えていない。ネットワークを確かめて打ち直す' -f $download.ExitCode)
            return 1
        }
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
            if ($arguments[0] -eq 'install') {
                Write-Host 'install が落ちたので、Claude Code が入っていないことがある。ネットワークを確かめて Install-ClaudeCode を打ち直す (setup --update でも入る)'
            }
            break
        }
    }
    # 入っていれば pin を足す (入れ替えた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Test-Path -LiteralPath (Join-Path $packageDir 'claude.exe')) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-ClaudeCodeState -PackageId $packageId -PackageDir $packageDir -LinksDir $linksDir -Target $Version
    Write-ClaudeCodeState -State $after -Target $Version -PackageId $packageId -PackageDir $packageDir
    if ((Get-ClaudeCodeExitCode -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    # 版と pin は揃い、残っているのは PATH のずれだけ
    if (-not (Test-ClaudeCodeDrift -State $after)) { Write-Host '版と pin は揃った' }
    Write-ClaudeCodeVerdict -State $after
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallClaudeCode -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
