<#
.SYNOPSIS
Windows の Tailscale (winget の Tailscale.Tailscale) を、決めた版で入れる。

.DESCRIPTION
dotfiles の win/tailscale/Install-Tailscale.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Tailscale から呼ぶ (win/README.md の「Tailscale を入れる」)。

winget の Tailscale.Tailscale は machine スコープで、installer は burn (exe の束) と wix (MSI) の 2 つ。MSI を名指しし
(--installer-type wix。Tailscale の自動更新も MSI を使う)、--silent は付けない (winget の既定の /passive。per-machine の MSI は、
管理者でない PowerShell から quiet で流すと UAC が出ずに落ちる。Install-Bootstrap.ps1 の gh と同じ)。入れる・上げるときは
Windows のデスクトップに UAC の確認と、進み具合の小さな窓が出る。

setup (bootstrap-windows-tailscale.sh・runner の tailscale) は入っていないときだけ -IfMissing で入れ、上げはしない。Tailscale は
自分で上がる (自動更新。2024-02 以後に作った tailnet は既定で有効) ので、入っている版の方が新しくても下げず、揃っている扱いにする
(固定した版は、新しく入れるときの版)。古いときは知らせ、上げるのは人がこのスクリプトを打つ。tailnet へのログインには触らない。

版は tailscale.exe version の 1 行目で読む (Tailscale の version.Short()。daemon には聞かない)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Tailscale.Tailscale --versions に出る値。版を変えるときはここの既定値を変える
(win/README.md の「Tailscale の新しい版が出たとき」)。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば (入っている版の方が新しいときも) 終了コード 0、
差があれば 1、入っていなければ 3、確かめられなければ 2。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、上げはしない (setup --update が使う)。
#>
[CmdletBinding()]
param(
    [string]$Version = '1.104.5',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Tailscale.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 版の文字列 ("1.104.5") を [version] にする。数字を . でつないだ 3 個の形でなければ $null
# (winget の Tailscale.Tailscale の版と、tailscale version の 1 行目はどちらも X.Y.Z)
function ConvertTo-TailscaleVersion {
    param([string]$Text)
    $v = $null
    if (("$Text" -match '^\s*(\d+\.\d+\.\d+)\s*$') -and [version]::TryParse($Matches[1], [ref]$v)) {
        return $v
    }
    $null
}

# tailscale.exe version の出力から版を拾う (版だけの行の最初のもの)。字下げした続きの行 (long version など) は拾わない。
# 無ければ $null
function Get-TailscaleCliVersion {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^(\d+\.\d+\.\d+)\s*$') { return $Matches[1] }
    }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う (Install-GoogleJapaneseInput.ps1 と同じ)。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# tailscale.exe を探す場所: Program Files の候補ごとに Tailscale\tailscale.exe と、PATH で引いたもの (別の置き場所に入れたとき)。
# 空の値と、大文字小文字だけが違う重複は除く (64 ビットの PowerShell では ProgramW6432 と ProgramFiles が同じ)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Get-TailscaleExeCandidates {
    param([string[]]$Roots, [string]$OnPath)
    $seen = @{}
    $paths = @(foreach ($root in $Roots) {
            if (-not $root) { continue }
            "$($root.TrimEnd('\'))\Tailscale\tailscale.exe"
        })
    if ($OnPath) { $paths += $OnPath }
    foreach ($p in $paths) {
        $key = $p.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $p
    }
}

# 見つかった tailscale.exe (Path と、tailscale version で読んだ版の文字列 Text の組) から 1 つ選ぶ。2 か所にあれば版の
# 新しい方。版が読めるものが無ければ最初のもの (Version は $null)。1 つも無ければ $null
function Select-TailscaleExe {
    param([object[]]$Candidates)
    $best = $null
    foreach ($c in @($Candidates | Where-Object { $_ })) {
        $v = ConvertTo-TailscaleVersion -Text $c.Text
        if (($null -eq $best) -or (($null -ne $v) -and (($null -eq $best.Version) -or ($v -gt $best.Version)))) {
            $best = [pscustomobject]@{ Path = $c.Path; Version = $v }
        }
    }
    $best
}

# 入っているか・入っている版・固定した版から、することを決める
#   install: 入っていない / upgrade: 古い / newer: 新しい (自動更新で上がった。下げない) / unknown: 版が読めない / none: 同じ
function Get-TailscalePlan {
    param([bool]$Exists, [version]$Installed, [version]$Target)
    if (-not $Exists) { return 'install' }
    if ($null -eq $Installed) { return 'unknown' }
    if ($Installed -lt $Target) { return 'upgrade' }
    if ($Installed -gt $Target) { return 'newer' }
    'none'
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-GoogleJapaneseInput.ps1 と同じ)。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。どちらも版を名指しする。
# install は MSI (wix) を名指しする (manifest は burn と wix を並べる)。upgrade は名指しせず、入っている形 (winget が見る) に合わせる。
# どちらにも --silent は付けない (winget の既定の /passive で、UAC と進み具合の小さな窓を出す。per-machine の MSI は quiet だと
# 管理者でない PowerShell から UAC を出せずに落ちる)。
# upgrade には --include-pinned を付ける。版を名指しした upgrade は、付けないとこの script が足した pin (Pinning) に止められる
# (0x8A150068)。上げる前に pin を外すが、外せなかったときも止められないようにする。install は --include-pinned を受け付けない
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--version', $Version)
    $tail = @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    switch ($Plan) {
        'install' { , (@('install') + $common + @('--installer-type', 'wix') + $tail) }
        'upgrade' { , (@('upgrade') + $common + $tail + @('--include-pinned')) }
    }
}

# winget が pin に止められて落ちた (0x8A150068 = APPINSTALLER_CLI_ERROR_PACKAGE_IS_PINNED) ときに添える行。ほかの終了コードなら
# 何も返さない (Install-GoogleJapaneseInput.ps1 と同じ)
function Get-WingetPinnedHint {
    param([int]$ExitCode, [string]$PackageId)
    if ($ExitCode -ne -1978335128) { return }
    "※ winget の pin に止められた。winget pin list --id $PackageId --exact で pin を確かめ、winget pin remove --id $PackageId --exact で外してから打ち直す (打ち直すと、揃えた後に pin を足し直す)"
}

# 終了コード。入っていなければ 3、版 (入っている版の方が新しいときも) と pin が揃っていれば 0、ほかは 1
function Get-TailscaleExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if ((@('none', 'newer') -contains $State.Plan) -and $State.Pinned) { return 0 }
    1
}

# 揃える前に止める理由。無ければ $null
#   unknown:    版が読めないので比べられない
#   not-listed: 入れる・上げるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
# 入っている版の方が新しい (newer) ときは止めない (下げずに、無ければ pin を足すだけ)
function Get-TailscaleApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target)
    if ($Plan -eq 'unknown') { return 'unknown' }
    $known = @($Versions | Where-Object { $_ })
    if ((@('install', 'upgrade') -contains $Plan) -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。ずれではないこと (入っている版の方が新しい・winget に新しい版がある) は ※ で添える
function Format-TailscaleState {
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
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($null -ne $State.Installed) { "$($State.Installed) ($dir)" } else { "不明 (tailscale.exe version が読めない。$dir)" }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $rows = @(
        @{ Text = 'Tailscale (winget の Tailscale.Tailscale)'; Warn = $false; Indent = $false }
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
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-Tailscale.ps1 の -Version の既定値を変える (入っている Tailscale は、自動更新が有効なら自分で上がる)"; Warn = $false }
    }
    if ($State.Plan -eq 'newer') {
        [pscustomobject]@{ Text = '※ 入っている版の方が新しい (Tailscale の自動更新で上がった?)。下げない。固定した版は、新しく入れるときの版 (自動更新の切り替えは Tailscale のタスクトレイの Preferences → Automatically install updates)'; Warn = $false }
    }
    if ($State.Plan -eq 'unknown') {
        [pscustomobject]@{ Text = '※ 版が読めないので比べられない。winget list --id Tailscale.Tailscale で入っている版を確かめる'; Warn = $false }
    }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-GoogleJapaneseInput.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
        Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[█▒]' }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

# Program Files (64 ビットと x86) と PATH にある tailscale.exe と、tailscale.exe version で読んだ版の文字列
function Get-TailscaleExeOnDisk {
    $onPath = $null
    $cmd = Get-Command tailscale.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $onPath = $cmd.Path }
    foreach ($exe in @(Get-TailscaleExeCandidates -Roots @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) -OnPath $onPath)) {
        if (Test-Path -LiteralPath $exe -PathType Leaf) {
            $text = $null
            try {
                # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
                $ErrorActionPreference = 'Continue'
                $text = Get-TailscaleCliVersion -Lines @(& $exe version 2>&1 | ForEach-Object { "$_" })
            } catch {
                $text = $null
            }
            [pscustomobject]@{ Path = $exe; Text = $text }
        }
    }
}

# 入っているか (揃えた後に pin を足すかを決める)
function Test-TailscaleInstalled {
    @(Get-TailscaleExeOnDisk).Count -gt 0
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-TailscaleState {
    param([string]$PackageId, [version]$Target)
    $exe = Select-TailscaleExe -Candidates @(Get-TailscaleExeOnDisk)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $exists = $null -ne $exe
    $path = $null
    $installed = $null
    if ($exists) {
        $path = $exe.Path
        $installed = $exe.Version
    }
    [pscustomobject]@{
        Exists    = $exists
        Path      = $path
        Installed = $installed
        Plan      = Get-TailscalePlan -Exists $exists -Installed $installed -Target $Target
        Pinned    = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions  = $versions
        Latest    = $latest
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-TailscaleState {
    param($State, [string]$Target)
    foreach ($row in (Format-TailscaleState -State $State -Target $Target)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

function Invoke-InstallTailscale {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'Tailscale.Tailscale'
    # 書き間違えた -Version は、winget を打つ前にここで例外になる (終了コード 2)
    $target = ConvertTo-TailscaleVersion -Text $Version
    if (-not $target) { throw "-Version の形が違う: $Version" }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-TailscaleState -PackageId $packageId -Target $target
    Write-TailscaleState -State $state -Target $Version
    $code = Get-TailscaleExitCode -State $state
    $blocker = Get-TailscaleApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if (($code -eq 0) -and ($state.Plan -eq 'newer')) {
            Write-Host '揃っている (入っている版の方が新しい。下げない)'
        } elseif ($code -eq 0) {
            Write-Host '揃っている'
        } elseif ($blocker -eq 'not-listed') {
            Write-Host "⚠️ 固定した版 $Version が winget に無い → Install-Tailscale.ps1 の -Version を winget show --id $packageId --versions にある版へ変える ⚠️" -ForegroundColor Yellow
        } elseif ($code -eq 3) {
            Write-Host '⚠️ Tailscale が入っていない → Install-Tailscale で入れる (UAC の確認が出る) ⚠️' -ForegroundColor Yellow
        } elseif ($state.Plan -eq 'unknown') {
            Write-Host "⚠️ 入っている版が読めない → winget list --id $packageId で入っている版を確かめる ⚠️" -ForegroundColor Yellow
        } elseif (@('none', 'newer') -contains $state.Plan) {
            Write-Host '⚠️ winget pin が無い → Install-Tailscale で足す (UAC の確認は出ない) ⚠️' -ForegroundColor Yellow
        } else {
            Write-Host '⚠️ 固定した版より古い → Install-Tailscale で揃える (UAC の確認が出る。上げる間、Tailscale の接続が少しの間切れる) ⚠️' -ForegroundColor Yellow
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    if ($blocker -eq 'unknown') {
        Write-Host "tailscale.exe の版が読めないので、何もしない。winget list --id $packageId で入っている版を確かめる"
        return 1
    }
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }

    if ($state.Plan -eq 'upgrade') {
        Write-Host '上げる間、Tailscale の接続が少しの間切れる (Tailscale 越しにこの PC へつないでいる接続も切れる)'
    }
    if (@('install', 'upgrade') -contains $state.Plan) {
        Write-Host 'Windows のデスクトップに UAC の確認が出る。「はい」を押す (進み具合の小さな窓も出る)'
    }
    # 上げるときは、古い版の pin を残さないよう先に外す (上げた後に足し直す。Install-GoogleJapaneseInput.ps1 と同じ)。外せなくても、
    # upgrade に付けた --include-pinned で pin を越える (Get-WingetCommands)
    if (($state.Plan -eq 'upgrade') -and $state.Pinned) {
        $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($unpin.ExitCode -ne 0) { Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode) }
    }
    foreach ($arguments in @(Get-WingetCommands -Plan $state.Plan -PackageId $packageId -Version $Version)) {
        Write-Host "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Host ('winget が失敗した (終了コード 0x{0:X8})。UAC で「いいえ」を押したなら、Install-Tailscale を打ち直す' -f $result.ExitCode)
            Get-WingetPinnedHint -ExitCode $result.ExitCode -PackageId $packageId | ForEach-Object { Write-Host $_ }
            break
        }
    }
    # 入っていれば pin を足す (上げた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Test-TailscaleInstalled) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる。Tailscale の自動更新は止めない)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-TailscaleState -PackageId $packageId -Target $target
    Write-TailscaleState -State $after -Target $Version
    if ((Get-TailscaleExitCode -State $after) -eq 0) {
        if ($state.Plan -eq 'install') {
            Write-Host 'tailnet へのログインは手でする (タスクトレイの Tailscale のアイコンから Log in。dotfiles はログインに触らない)'
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
        exit (Invoke-InstallTailscale -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
