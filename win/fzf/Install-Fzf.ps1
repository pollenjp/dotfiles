<#
.SYNOPSIS
Windows の fzf (行を絞り込んで選ぶ CLI。winget の junegunn.fzf の portable) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/fzf/Install-Fzf.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Fzf から呼ぶ (win/README.md の「ghq・fzf」)。
dotfiles.ps1 の cdrepo (ghq の repo を fzf で選んで移る) が使う。

winget の junegunn.fzf は 0.75.0 から、zip の中の portable と、machine スコープの MSI (%ProgramFiles%\fzf\bin。UAC が要る)
の 2 つの installer を並べ、winget の既定は MSI を選ぶ。dotfiles は portable (管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の
下に入る。fzf.exe は置き場所の直下) を、--installer-type portable で名指しして入れる。MSI の fzf が入っているマシンでは、portable と
二重になり winget の install・pin がどちらを指すか決まらないので、何も入れずに外し方を出す (外すのは人)。
fzf.exe が動いている間は置き換えられないので、入れ替えが要るときに置き場所の fzf.exe が動いていれば、何も変えずに止める (止めはしない)。

形は Install-Ntn.ps1 と同じ (常駐も UAC も無いので、版のずれも揃える)。違うのは、入れる・揃えるのが WSL の
setup ではなく Windows の runner の手順 fzf (win/runner/src/steps/ps1.rs。dotfiles apply) であることと、MSI の fzf を見ること。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id junegunn.fzf --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3
(MSI の fzf が入っていれば、portable が入っていなくても 1)。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.75.0',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Fzf.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# fzf.exe --version の出力 ("<版> (<commit>)") から版を拾う。無ければ $null
function Get-FzfVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*v?(\d+(\.\d+)+)(\s|$)') { return $Matches[1] }
    }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う (Install-Ntn.ps1 と同じ)。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# 入っているか・入っている版・固定した版から、することを決める。
# fzf.exe があるのに版が読めないときも入れ替える (外してから入れ直せば直る)
function Get-FzfPlan {
    param([bool]$Exists, [string]$Installed, [string]$Target)
    if (-not $Exists) { return 'install' }
    if ($Installed -cne $Target) { return 'change' }
    'none'
}

# 入れ替えの向き。winget show --versions の並び (新しい順) の位置で比べる
function Get-FzfDirection {
    param([string[]]$Versions, [string]$Installed, [string]$Target)
    $list = @($Versions)
    $i = [array]::IndexOf($list, $Installed)
    $t = [array]::IndexOf($list, $Target)
    if ($i -lt 0 -or $t -lt 0) { return 'unknown' }
    if ($t -lt $i) { return 'up' }
    if ($t -gt $i) { return 'down' }
    'same'
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-Ntn.ps1 と同じ)。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列。Install-Ntn.ps1 と同じ)。入れ替えは版の上げ下げによらず、
# 外してから入れる (portable の置き場所は版によらず同じ。fzf の設定 (環境変数 FZF_DEFAULT_OPTS など) は置き場所の外にある)。
# install には --installer-type portable を付ける (付けないと winget は MSI を選ぶ)
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    $put = $common + @('--version', $Version, '--installer-type', 'portable', '--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        'change' {
            , (@('uninstall') + $common)
            , (@('install') + $put)
        }
    }
}

# 入れ替えの前に、固定した版の取得とハッシュだけを確かめる winget download の引数 (Install-Ntn.ps1 と同じ。入れるものと
# 同じ portable を名指しする)
function Get-WingetDownloadArguments {
    param([string]$PackageId, [string]$Version, [string]$Directory)
    @('download', '--id', $PackageId, '--exact', '--source', 'winget', '--version', $Version,
        '--installer-type', 'portable', '--download-directory', $Directory, '--skip-dependencies',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
}

# PATH (; 区切り) を前から見て、$Names のどれかが最初に見つかったパスを返す。無ければ $null (Install-Ntn.ps1 と同じ)。
# PowerShell は PATH のディレクトリの順に、.exe だけでなく .cmd・.bat・.ps1 も引くので、ディレクトリごとに名前を並べて見る。
# $Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Resolve-FzfOnPath {
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

# PATH で引かれる fzf.exe がどこのものか。'winget' (junegunn.fzf の portable の fzf.exe のあるディレクトリか、winget が
# symlink を置く WinGet\Links) / 'other' (MSI の fzf も) / 'none'
function Get-FzfPathKind {
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

# 揃える手順 (Install-Fzf) で直る差 (版・pin) があるか
function Test-FzfDrift {
    param($State)
    ($State.Plan -ne 'none') -or (-not $State.Pinned)
}

# PATH のずれ (ほかの fzf.exe が先に引かれる・入っているのに PATH に無い) があるか。揃える手順では直らないので、
# ※ の行で直し方を添える。入っていないときに PATH に無いのは当たり前なので数えない
function Test-FzfPathDrift {
    param($State)
    ($State.PathKind -eq 'other') -or (($State.PathKind -eq 'none') -and ($State.Plan -ne 'install'))
}

# MSI の fzf (winget の既定の installer。machine スコープで %ProgramFiles%\fzf\bin に入る) が入っているか。
# 入っている間は portable を入れも入れ替えもしない (揃える手順では直らない)
function Test-FzfMsi {
    param($State)
    [bool]$State.MsiExe
}

# 終了コード。MSI の fzf が入っていれば 1 (portable が入っていなくても 3 にしない。runner が -IfMissing で入れにいかないように)、
# 入っていなければ 3、版・pin・PATH が揃っていれば 0、ほかは 1
function Get-FzfExitCode {
    param($State)
    if (Test-FzfMsi -State $State) { return 1 }
    if ($State.Plan -eq 'install') { return 3 }
    if ((Test-FzfDrift -State $State) -or (Test-FzfPathDrift -State $State)) { return 1 }
    0
}

# 揃える前に止める理由。無ければ $null
#   msi:        MSI の fzf が入っている (portable と二重になり、winget の install・pin がどちらを指すか決まらない)
#   not-listed: 入れる・入れ替えるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
#   busy:       入れ替えるのに、置き場所の fzf.exe が動いている (置き換えられない)
function Get-FzfApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target, [int]$BusyCount, [bool]$Msi)
    if ($Msi) { return 'msi' }
    $known = @($Versions | Where-Object { $_ })
    if (($Plan -ne 'none') -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    if (($Plan -eq 'change') -and ($BusyCount -gt 0)) { return 'busy' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。ずれではないこと (新しい版がある・動いている fzf がある) は ※ で添える
function Format-FzfState {
    param($State, [string]$Target, [string]$PackageId, [string]$PackageDir)
    $direction = if ($State.Direction -eq 'up') { ' (上げる)' } elseif ($State.Direction -eq 'down') { ' (下げる)' } else { '' }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'change' { "入れ替える$direction" }
        default { 'そのまま' }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($State.Installed) { $State.Installed } else { '不明 (fzf.exe --version が読めない)' }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $pathText = switch ($State.PathKind) {
        'winget' { 'winget の portable のもの' }
        'other' { "$($State.PathResolved) (winget の portable のものではない)" }
        default { '見つからない' }
    }
    $rows = @(
        @{ Text = "fzf (winget の $PackageId、$PackageDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
        @{ Text = "PATH の fzf     : $pathText"; Warn = (Test-FzfPathDrift -State $State); Indent = $true }
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
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-Fzf.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    # MSI の fzf は揃える手順 (Install-Fzf) では外さないので、外し方を添える。PATH で引かれるのがその fzf でも、先に外す
    # (外した後に読み直せば、PATH の行は portable の fzf になる)
    if (Test-FzfMsi -State $State) {
        [pscustomobject]@{ Text = "⚠ MSI の fzf (machine スコープ。winget の既定の installer) が入っている: $($State.MsiExe)"; Warn = $true }
        [pscustomobject]@{ Text = "※ portable と二重にしないため、MSI があるうちは Install-Fzf は何も入れない。PowerShell で winget uninstall --id $PackageId --exact --scope machine を打って MSI を外し (UAC の確認が出る)、Install-Fzf を打ち直す (win/README.md の「ghq・fzf」)"; Warn = $false }
    } elseif ($State.PathKind -eq 'other') {
        # PATH のずれは揃える手順 (Install-Fzf) では直らないので、直し方を添える
        $cut = $State.PathResolved.LastIndexOf('\')
        $dir = if ($cut -ge 0) { $State.PathResolved.Substring(0, $cut) } else { $State.PathResolved }
        [pscustomobject]@{ Text = "※ PATH のずれは Install-Fzf では直らない。$dir の fzf.exe を消すか、$dir をユーザーの PATH から外す (win/README.md の「ghq・fzf」)"; Warn = $false }
    } elseif (($State.PathKind -eq 'none') -and ($State.Plan -ne 'install')) {
        [pscustomobject]@{ Text = "※ fzf の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $PackageId の後に Install-Fzf で入れ直す"; Warn = $false }
    }
    if (($State.Plan -eq 'change') -and ($State.BusyCount -gt 0)) {
        [pscustomobject]@{ Text = "※ fzf.exe が $($State.BusyCount) 個動いている。入れ替えるには、動いている fzf (cdrepo の選ぶ画面など) を終わらせる"; Warn = $false }
    }
}

# 締めの行 (-Check の最後と、揃えた後の最後)。揃っていれば何も返さない。直すことごとに ⚠️ で始まる行を返す。
# Windows の runner (win/runner/src/steps/ps1.rs) は「→ Install-Fzf で入れる」「→ Install-Fzf で揃える」「→ ※ の手順で直す」の
# 文言で、入れるか・揃えるか・知らせるだけかを決め、MSI の行 (「MSI の fzf (machine スコープ) が入っている」) で直し方を選ぶ
# (文言を変えるときは向こうも直す)。MSI の fzf が入っていれば、その 1 行だけ (外すまで portable を入れも揃えもしない)
function Format-FzfVerdict {
    param($State)
    if (Test-FzfMsi -State $State) {
        '⚠️ MSI の fzf (machine スコープ) が入っている → ※ の手順で直す ⚠️'
        return
    }
    if ((Get-FzfExitCode -State $State) -eq 3) {
        '⚠️ fzf が入っていない → Install-Fzf で入れる ⚠️'
        return
    }
    if (Test-FzfDrift -State $State) { '⚠️ 固定した版と揃っていない → Install-Fzf で揃える ⚠️' }
    if (Test-FzfPathDrift -State $State) { '⚠️ PATH の fzf が winget の portable のものではない → ※ の手順で直す ⚠️' }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-Ntn.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# 置き場所の fzf.exe を探す。manifest の RelativeFilePath (fzf.exe。置き場所の直下) を先に見て、
# 無ければ置き場所の下を深さ 3 まで探す (zip の中の形が変わっても読めるように)。無ければ $null
function Find-FzfExe {
    param([string]$PackageDir)
    $default = Join-Path $PackageDir 'fzf.exe'
    if (Test-Path -LiteralPath $default -PathType Leaf) { return $default }
    if (-not (Test-Path -LiteralPath $PackageDir -PathType Container)) { return $null }
    $found = @(Get-ChildItem -LiteralPath $PackageDir -Filter 'fzf.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($found.Count -gt 0) { return $found[0].FullName }
    $null
}

# MSI の fzf の fzf.exe (manifest の DefaultInstallLocation の %ProgramFiles%\fzf\bin)。無ければ $null。
# Join-Path を重ねて組む (\ を書かないので、Linux の pwsh で流すテストでも同じに読む。5.1 には 3 つ以上を渡す Join-Path が無い)
function Find-FzfMsiExe {
    param([string]$ProgramFiles)
    if (-not $ProgramFiles) { return $null }
    $exe = Join-Path (Join-Path (Join-Path $ProgramFiles 'fzf') 'bin') 'fzf.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    $null
}

# fzf.exe に版を聞く。読めなければ $null
function Get-FzfInstalledVersion {
    param([string]$Exe)
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe --version 2>&1 | ForEach-Object { "$_" })
    } catch {
        # 起動できない (壊れた・0 バイト・方針で止められた) ときも、版が読めないとして入れ替えの対象にする
        return $null
    }
    Get-FzfVersionFromOutput -Lines $out
}

# これから開く PowerShell が使う PATH (マシン → ユーザーの順)。今のプロセスの PATH は古いことがある
function Get-FzfPathValue {
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}

# 置き場所の下の exe から起動して動いているプロセス
function Get-FzfBusyProcess {
    param([string]$PackageDir)
    $prefix = $PackageDir.TrimEnd('\') + '\'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            $path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        })
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-FzfState {
    param([string]$PackageId, [string]$PackageDir, [string]$LinksDir, [string]$Target)
    $exe = Find-FzfExe -PackageDir $PackageDir
    $exists = [bool]$exe
    $installed = $null
    if ($exists) { $installed = Get-FzfInstalledVersion -Exe $exe }
    # 入っていなければ、winget が足すはずのディレクトリ (manifest の RelativeFilePath の親 = 置き場所) で PATH を見る
    $exeDir = if ($exe) { Split-Path -Parent $exe } else { $PackageDir }
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $resolved = Resolve-FzfOnPath -PathValue (Get-FzfPathValue) -Names @('fzf.exe', 'fzf.cmd', 'fzf.bat', 'fzf.ps1') -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    [pscustomobject]@{
        Exists       = $exists
        Installed    = $installed
        Plan         = Get-FzfPlan -Exists $exists -Installed $installed -Target $Target
        Direction    = Get-FzfDirection -Versions $versions -Installed $installed -Target $Target
        Pinned       = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions     = $versions
        Latest       = $latest
        PathResolved = $resolved
        PathKind     = Get-FzfPathKind -Resolved $resolved -ExeDir $exeDir -LinksDir $LinksDir
        BusyCount    = @(Get-FzfBusyProcess -PackageDir $PackageDir).Count
        MsiExe       = Find-FzfMsiExe -ProgramFiles $env:ProgramFiles
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-FzfState {
    param($State, [string]$Target, [string]$PackageId, [string]$PackageDir)
    foreach ($row in (Format-FzfState -State $State -Target $Target -PackageId $PackageId -PackageDir $PackageDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 締めの行 (直すこと) を黄色で出す。揃っていれば何も出さない
function Write-FzfVerdict {
    param($State)
    foreach ($line in (Format-FzfVerdict -State $State)) {
        Write-Host $line -ForegroundColor Yellow
    }
}

function Invoke-InstallFzf {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'junegunn.fzf'
    # portable の置き場所は <Id>_<ソースの識別子>。winget のソースから入れると、どのマシンでも同じ名前になる
    $packageDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\junegunn.fzf_Microsoft.Winget.Source_8wekyb3d8bbwe'
    $linksDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-FzfState -PackageId $packageId -PackageDir $packageDir -LinksDir $linksDir -Target $Version
    Write-FzfState -State $state -Target $Version -PackageId $packageId -PackageDir $packageDir
    $code = Get-FzfExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if ($code -eq 0) { Write-Host '揃っている' }
        Write-FzfVerdict -State $state
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }
    # 揃える手順で直す差 (版・pin) が無く、残っているのは PATH のずれ (か MSI の fzf) だけ
    if (-not (Test-FzfDrift -State $state)) {
        Write-Host '版と pin は揃っている。PATH のずれ (MSI の fzf) は Install-Fzf では直らない (上の ※ の行の手順で直す)'
        Write-FzfVerdict -State $state
        return 1
    }

    $blocker = Get-FzfApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version -BusyCount $state.BusyCount -Msi (Test-FzfMsi -State $state)
    if ($blocker -eq 'msi') {
        Write-Host 'MSI の fzf が入っているので、portable を入れずに止める。上の ※ の行の手順で MSI を外してから打ち直す'
        Write-FzfVerdict -State $state
        return 1
    }
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }
    if ($blocker -eq 'busy') {
        Write-Host 'fzf.exe が動いていて置き換えられない。動いている fzf を終わらせてから打ち直す:'
        foreach ($p in @(Get-FzfBusyProcess -PackageDir $packageDir)) {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
            Write-Host "  $($p.Id)  $commandLine"
        }
        return 1
    }

    # 入れ替えは外してから入れるので、取得が落ちると fzf が消えたまま終わる。
    # 外す前に、固定した版を取得してハッシュまで確かめる (落ちたら何も変えずに止める)
    if ($state.Plan -eq 'change') {
        $downloadDir = Join-Path ([IO.Path]::GetTempPath()) "install-fzf-$PID"
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
                Write-Host 'install が落ちたので、fzf が入っていないことがある。ネットワークを確かめて Install-Fzf を打ち直す (dotfiles apply でも入る)'
            }
            break
        }
    }
    # 入っていれば pin を足す (入れ替えた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Find-FzfExe -PackageDir $packageDir) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-FzfState -PackageId $packageId -PackageDir $packageDir -LinksDir $linksDir -Target $Version
    Write-FzfState -State $after -Target $Version -PackageId $packageId -PackageDir $packageDir
    if ((Get-FzfExitCode -State $after) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    # 版と pin は揃い、残っているのは PATH のずれだけ
    if (-not (Test-FzfDrift -State $after)) { Write-Host '版と pin は揃った' }
    Write-FzfVerdict -State $after
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallFzf -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
