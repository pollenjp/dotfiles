<#
.SYNOPSIS
Windows の Claude Desktop (winget の Anthropic.Claude の MSIX) を、決めた版で入れる。

.DESCRIPTION
dotfiles の win/claude-desktop/Install-ClaudeDesktop.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-ClaudeDesktop から呼ぶ (win/README.md の「Claude Desktop」)。

winget の Anthropic.Claude は、MSIX (x64・arm64) と旧来の exe (Squirrel。user スコープで %LOCALAPPDATA%\AnthropicClaude に入る) の
2 種類の installer を並べ、--installer-type を付けないと winget は exe を選ぶ。Cowork (VM の中で動くエージェント) は MSIX でしか動かない
ので、--installer-type msix で名指しする。MSIX は Cowork の常駐 (CoworkVMService。localSystem で動く Windows のサービス) を持ち、Windows は
それを管理者の権限で入れたときだけ登録する (管理者の権限の無い登録は 0x80073D28 で断られる)。そこで winget を、昇格した Windows
PowerShell (System32 のもの) で流す。UAC の確認は入れる・上げるときの 1 回だけ出る。昇格した側の出力は受け取れないので、昇格した側が
winget の出力を一時ファイルに書いて winget の終了コードで終わり、こちらがそのファイルを読んで出す。MSIX は打ったユーザーに入る (UAC で
昇格しても同じユーザー)。

runner (手順 claude-desktop。ホストの値の [tools] windowsClaudeDesktop が on のマシンだけ。既定は personal) は入っていないときだけ
-IfMissing で入れ、上げはしない。Claude Desktop は自分で上がる (約 4 時間ごと) ので、入っている版の方が新しくても下げず、揃っている
扱いにする (固定した版は、新しく入れるときの版)。古いときは知らせ、上げるのは人がこのスクリプトを打つ。

入っている版は Get-AppxPackage -Name Claude の Version で読む (Anthropic の案内の検出の手。PackageFamilyName が Claude_pzs8sxrjxfjjc の
もの)。PowerShell 7 の Appx は読めないことがあるので、PowerShell 7 から打ったときは Windows PowerShell 5.1 に読ませる。

旧来の exe の Claude (%LOCALAPPDATA%\AnthropicClaude) は、そちらを開くと Cowork が無い。見つけたら外し方を出す (外すのは人。この
スクリプトは外さない)。旧来の exe があるうちは MSIX を入れない (winget は旧来の exe も Anthropic.Claude と数え、入れる手を上げる手に
切り替えるので、MSIX が入らないまま落ちる見込み)。Cowork には Windows の仮想マシン プラットフォーム (VirtualMachinePlatform) も要る。
off ならそう知らせる (on にするのは人。Windows の再起動が要る)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Anthropic.Claude --versions に出る値。版を変えるときはここの既定値を変える
(win/README.md の「Claude Desktop の新しい版が出たとき」)。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば (入っている版の方が新しいときも) 終了コード 0、
差があれば 1、入っていなければ 3、確かめられなければ 2。旧来の exe の Claude が残っていれば、MSIX が入っていなくても 1 (締めの行は
旧来の exe のこと。runner が UAC を出して入れにいかないように)。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す (UAC の確認が 1 回出る)。入っていれば -Check と同じで、上げはしない (runner が使う)。
旧来の exe の Claude が残っていれば、入れずに -Check と同じ (1)。
#>
[CmdletBinding()]
param(
    [string]$Version = '5.11492.5',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-ClaudeDesktop.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 版の文字列 ("5.11492.5"・"5.11492.5.0") を、4 つの数の [version] にする (無い 4 つ目は 0)。数字を . でつないだ 3 個か 4 個でなければ
# $null。winget の版は 3 個、Get-AppxPackage の Version (MSIX の Identity の版) は 4 個で、[version] のまま比べると 5.11492.5 が
# 5.11492.5.0 より小さくなる (足りない所が -1 になる) ので、4 個にそろえてから比べる
function ConvertTo-ClaudeDesktopVersion {
    param([string]$Text)
    if ("$Text" -notmatch '^\s*(\d+)\.(\d+)\.(\d+)(\.(\d+))?\s*$') { return $null }
    $revision = '0'
    if ($Matches[5]) { $revision = $Matches[5] }
    $v = $null
    if ([version]::TryParse(('{0}.{1}.{2}.{3}' -f $Matches[1], $Matches[2], $Matches[3], $revision), [ref]$v)) { return $v }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う (Install-T3Code.ps1 と同じ)。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# Get-AppxPackage の結果を 1 つ 1 行にした字 ("<Name><TAB><PackageFamilyName><TAB><Version><TAB><InstallLocation>") を読む。
# 欄の足りない行は飛ばす
function ConvertFrom-ClaudeAppxLines {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $fields = "$line".TrimEnd("`r").Split("`t")
        if ($fields.Count -lt 4) { continue }
        [pscustomobject]@{
            Name              = $fields[0]
            PackageFamilyName = $fields[1]
            Version           = $fields[2]
            InstallLocation   = $fields[3]
        }
    }
}

# Claude の MSIX (PackageFamilyName が一致するもの。名前が Claude でも発行元の違うものは数えない) のうち、版のいちばん新しいものを選ぶ。
# 版の読めないものは、ほかに無いときだけ選ぶ。無ければ $null
function Select-ClaudeAppxEntry {
    param([object[]]$Entries, [string]$FamilyName)
    $best = $null
    $bestVersion = $null
    foreach ($e in @($Entries | Where-Object { $_ })) {
        if ("$($e.PackageFamilyName)" -ine $FamilyName) { continue }
        $v = ConvertTo-ClaudeDesktopVersion -Text $e.Version
        if (($null -eq $best) -or (($null -ne $v) -and (($null -eq $bestVersion) -or ($v -gt $bestVersion)))) {
            $best = $e
            $bestVersion = $v
        }
    }
    $best
}

# 入っているか・入っている版・固定した版から、することを決める
#   install: 入っていない / upgrade: 古い / newer: 新しい (自動更新で上がった。下げない) / unknown: 版が読めない / none: 同じ
function Get-ClaudeDesktopPlan {
    param([bool]$Exists, [version]$Installed, [version]$Target)
    if (-not $Exists) { return 'install' }
    if ($null -eq $Installed) { return 'unknown' }
    if ($Installed -lt $Target) { return 'upgrade' }
    if ($Installed -gt $Target) { return 'newer' }
    'none'
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-T3Code.ps1 と同じ)
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。どちらも版と MSIX を名指しする (付けないと winget は旧来の exe を選ぶ)。--scope は付けない
# (MSIX は打ったユーザーに入る)。MSIX には installer の画面が無いので --silent も付けない。upgrade には --include-pinned を付ける (この
# script が足した pin に止められないよう。Install-T3Code.ps1 と同じ)。install は --include-pinned を受け付けない
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--version', $Version, '--installer-type', 'msix')
    $tail = @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    switch ($Plan) {
        'install' { , (@('install') + $common + $tail) }
        'upgrade' { , (@('upgrade') + $common + $tail + @('--include-pinned')) }
    }
}

# winget が pin に止められて落ちた (0x8A150068 = APPINSTALLER_CLI_ERROR_PACKAGE_IS_PINNED) ときに添える行。ほかの終了コードなら
# 何も返さない (Install-Tailscale.ps1 と同じ)
function Get-WingetPinnedHint {
    param([int]$ExitCode, [string]$PackageId)
    if ($ExitCode -ne -1978335128) { return }
    "※ winget の pin に止められた。winget pin list --id $PackageId --exact で pin を確かめ、winget pin remove --id $PackageId --exact で外してから打ち直す (打ち直すと、揃えた後に pin を足し直す)"
}

# 終了コード。入っていなければ 3 (旧来の exe の Claude があれば 1。入れられないので、runner が -IfMissing で入れにいかないように)、版
# (入っている版の方が新しいときも) と pin が揃っていて旧来の exe の Claude も無ければ 0、ほかは 1
function Get-ClaudeDesktopExitCode {
    param($State)
    if ($State.Plan -eq 'install') {
        if ($State.Legacy) { return 1 }
        return 3
    }
    if ((@('none', 'newer') -contains $State.Plan) -and $State.Pinned -and (-not $State.Legacy)) { return 0 }
    1
}

# MSIX の Claude Desktop の側 (版と pin) は揃っていて、残っているのが旧来の exe の Claude だけか (揃えるときに、することが無い)
function Test-ClaudeDesktopLegacyOnly {
    param($State)
    (@('none', 'newer') -contains $State.Plan) -and $State.Pinned -and $State.Legacy
}

# 揃える前に止める理由。無ければ $null
#   unknown:    版が読めないので比べられない
#   not-listed: 入れる・上げるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
#   legacy:     入れる・上げるのに、旧来の exe の Claude が残っている (winget は旧来の exe も Anthropic.Claude と数え、入れる手を上げる手に
#               切り替えるので、MSIX が入らないまま落ちる見込み。外してから入れる)
function Get-ClaudeDesktopApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target, [bool]$Legacy = $false)
    if ($Plan -eq 'unknown') { return 'unknown' }
    $known = @($Versions | Where-Object { $_ })
    if ((@('install', 'upgrade') -contains $Plan) -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    if ((@('install', 'upgrade') -contains $Plan) -and $Legacy) { return 'legacy' }
    $null
}

# Win32_OptionalFeature の InstallState (1 = 有効・2 = 無効・3 = 無い) を、仮想マシン プラットフォームの on・off にする。読めなければ unknown
function ConvertFrom-VmPlatformState {
    param($InstallState)
    switch ("$InstallState") {
        '1' { 'on' }
        '2' { 'off' }
        '3' { 'off' }
        default { 'unknown' }
    }
}

# 状態の表の見出し (見出しの字を足して、表示の幅 (全角を 2) を Width にそろえる)
function Format-ClaudeDesktopLabel {
    param([string]$Label, [int]$Width)
    $w = 0
    foreach ($c in $Label.ToCharArray()) {
        if ([int]$c -gt 0x7F) { $w += 2 } else { $w += 1 }
    }
    $Label + (' ' * [Math]::Max(0, $Width - $w))
}

# 旧来の exe の Claude を外す手順 (このスクリプトも runner も外さない。Anthropic の案内のとおり、管理者でない会話で打つ)
function Format-ClaudeLegacySteps {
    '旧来の exe の Claude を開くと Cowork が無い。外すには、Claude を終えてから (☰ > File > Exit)、管理者でない PowerShell で & "$env:LOCALAPPDATA\AnthropicClaude\Update.exe" --uninstall -s を打つ'
    '終わったら %LOCALAPPDATA%\AnthropicClaude と、スタートメニューの %APPDATA%\Microsoft\Windows\Start Menu\Programs\Claude.lnk を消す (win/README.md の「Claude Desktop」)'
}

# 仮想マシン プラットフォームを on にする手順 (このスクリプトも runner も on にしない。Windows の再起動が要る)
function Format-VmPlatformSteps {
    'on にするには、管理者の PowerShell で Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All を打ち、Windows を再起動する (シャットダウンでなく再起動。dotfiles は on にしない)'
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。ずれではないこと
# (入っている版の方が新しい・winget に新しい版がある・Cowork の前提) は ※ で添える
function Format-ClaudeDesktopState {
    param($State, [string]$Target)
    # いちばん長い見出し (仮想マシン プラットフォーム) が 27 の幅
    $width = 28
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'upgrade' { '上げる' }
        'newer' { '入っている版の方が新しい (下げない)' }
        'unknown' { '比べられない' }
        default { 'そのまま' }
    }
    $where = if ($State.Location) { " ($($State.Location))" } else { '' }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($State.InstalledText) { "$($State.InstalledText)$where" } else { "不明 (Get-AppxPackage の Version が読めない$where)" }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $vmText = switch ($State.VmPlatform) {
        'on' { 'on' }
        'off' { 'off (Cowork は使えない)' }
        default { '不明 (Win32_OptionalFeature が読めない)' }
    }
    $rows = @(
        @{ Label = '入っている版'; Text = $installedText; Warn = $false }
        @{ Label = '固定した版'; Text = "$Target → $planText"; Warn = (@('none', 'newer') -notcontains $State.Plan) }
        @{ Label = 'winget の最新版'; Text = $latestText; Warn = $false }
        @{ Label = 'winget pin'; Text = $pinText; Warn = (-not $State.Pinned) }
    )
    # Cowork の常駐は、MSIX が入っているときだけ見せる (入っていないときは無くて当たり前)
    if ($State.Exists) {
        $serviceText = if ($State.Service) { "CoworkVMService ($($State.Service))" } else { '無い (CoworkVMService が無い)' }
        $rows += @{ Label = 'Cowork の常駐'; Text = $serviceText; Warn = $false }
    }
    $rows += @{ Label = '仮想マシン プラットフォーム'; Text = $vmText; Warn = $false }
    if ($State.Legacy) {
        $legacyVersion = if ($State.LegacyVersion) { "$($State.LegacyVersion)。" } else { '' }
        $rows += @{ Label = '旧来の exe の Claude'; Text = "入っている ($legacyVersion%LOCALAPPDATA%\AnthropicClaude) → ※ の手順で外す"; Warn = $true }
    }
    [pscustomobject]@{ Text = 'Claude Desktop (winget の Anthropic.Claude の MSIX)'; Warn = $false }
    foreach ($row in $rows) {
        $prefix = if ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$(Format-ClaudeDesktopLabel -Label $row.Label -Width $width): $($row.Text)"; Warn = [bool]$row.Warn }
    }
    $versions = @($State.Versions | Where-Object { $_ })
    if (($versions.Count -gt 0) -and ($versions -cnotcontains $Target)) {
        if (@('install', 'upgrade') -contains $State.Plan) {
            [pscustomobject]@{ Text = '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない'; Warn = $true }
        } else {
            [pscustomobject]@{ Text = '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える'; Warn = $false }
        }
    } elseif (($versions.Count -gt 0) -and ($versions[0] -cne $Target)) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-ClaudeDesktop.ps1 の -Version の既定値を変える (7 日の猶予を過ぎた版。入っている Claude Desktop は、自動更新で自分で上がる)"; Warn = $false }
    }
    if ($State.Plan -eq 'newer') {
        [pscustomobject]@{ Text = '※ 入っている版の方が新しい (Claude Desktop の自動更新で上がった?)。下げない。固定した版は、新しく入れるときの版'; Warn = $false }
    }
    if ($State.Plan -eq 'unknown') {
        [pscustomobject]@{ Text = '※ 版が読めないので比べられない。Get-AppxPackage -Name Claude で入っている版を確かめる'; Warn = $false }
    }
    if ($State.Exists -and (-not $State.Service)) {
        [pscustomobject]@{ Text = '※ MSIX は入っているが、Cowork の常駐 (CoworkVMService) が無い。Cowork は使えない (管理者の権限で入れていないかもしれない。win/README.md の「Claude Desktop」)'; Warn = $false }
    }
    if ($State.VmPlatform -eq 'off') {
        [pscustomobject]@{ Text = "※ 仮想マシン プラットフォーム (VirtualMachinePlatform) が off なので、Cowork (VM の中で動くエージェント) は使えない。$(Format-VmPlatformSteps)"; Warn = $false }
    }
    if ($State.Legacy) {
        foreach ($step in (Format-ClaudeLegacySteps)) {
            [pscustomobject]@{ Text = "※ $step"; Warn = $false }
        }
        if (@('install', 'upgrade') -contains $State.Plan) {
            [pscustomobject]@{ Text = '※ 旧来の exe の Claude があるうちは、MSIX を入れない・上げない (外した後に Install-ClaudeDesktop か dotfiles apply で入れる)'; Warn = $false }
        }
    }
}

# 締めの行 (-Check と、-IfMissing で入っていたとき・揃えた後に読み直したとき)。Text と、直すことがあるかの Warn (黄色にする)。旧来の
# exe の Claude が残っていれば、pin などより先にそのことを出す (外すまで入れない・上げない。pin を足すのは外した後でよい)。
# runner (win/runner/src/steps/ps1.rs) は、終了コードと「旧来の exe の Claude が残っている」の文言で行を決める (文言を変えるときは向こうも直す)
function Get-ClaudeDesktopVerdict {
    param($State, [int]$Code, [string]$Blocker, [string]$Target, [string]$PackageId)
    $text = if (($Code -eq 0) -and ($State.Plan -eq 'newer')) {
        '揃っている (入っている版の方が新しい。下げない)'
    } elseif ($Code -eq 0) {
        '揃っている'
    } elseif ($Blocker -eq 'not-listed') {
        "⚠️ 固定した版 $Target が winget に無い → Install-ClaudeDesktop.ps1 の -Version を winget show --id $PackageId --versions にある版へ変える ⚠️"
    } elseif ($State.Legacy -and (@('install', 'upgrade') -contains $State.Plan)) {
        '⚠️ 旧来の exe の Claude が残っている → ※ の手順で外してから、Install-ClaudeDesktop で入れる・揃える (外すまで MSIX は入れない) ⚠️'
    } elseif ($State.Legacy) {
        '⚠️ 旧来の exe の Claude が残っている → ※ の手順で外す (Install-ClaudeDesktop は外さない) ⚠️'
    } elseif ($Code -eq 3) {
        '⚠️ Claude Desktop (MSIX) が入っていない → Install-ClaudeDesktop で入れる (UAC の確認が 1 回出る) ⚠️'
    } elseif ($State.Plan -eq 'unknown') {
        '⚠️ 入っている版が読めない → Get-AppxPackage -Name Claude で入っている版を確かめる ⚠️'
    } elseif (@('none', 'newer') -contains $State.Plan) {
        '⚠️ winget pin が無い → Install-ClaudeDesktop で足す (UAC の確認は出ない) ⚠️'
    } else {
        '⚠️ 固定した版より古い → Install-ClaudeDesktop で揃える (Claude を終えてから。UAC の確認が 1 回出る) ⚠️'
    }
    [pscustomobject]@{ Text = $text; Warn = ($Code -ne 0) }
}

# PowerShell の一重引用符の文字列にする。' と、PowerShell が ' と同じに読む U+2018〜U+201B (‘ ’ ‚ ‛) は、どれも重ねる (runner の ps_quote と同じ)
function ConvertTo-PsLiteral {
    param([string]$Text)
    $quotes = @([char]0x27, [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in "$Text".ToCharArray()) {
        [void]$sb.Append($c)
        if ($quotes -contains $c) { [void]$sb.Append($c) }
    }
    "'" + $sb.ToString() + "'"
}

# 昇格した Windows PowerShell に渡す本文。winget (絶対パスで渡す) を打ち、出力 (stderr も) を UTF-8 で $LogPath に書き、winget の終了コード
# で終わる (Start-Process -Verb RunAs は昇格した process の出力を受け取れない)。winget を起こせなければ、そのわけを $LogPath に書いて 2 で
# 終わる ($LASTEXITCODE を先に 2 にしておく。起こせないまま exit $LASTEXITCODE に届くと 0 で終わり、入ったように見える)
function Get-ElevatedWingetScript {
    param([string]$Winget, [string[]]$Arguments, [string]$LogPath)
    $quotedArgs = @($Arguments | ForEach-Object { ConvertTo-PsLiteral -Text $_ }) -join ' '
    $log = ConvertTo-PsLiteral -Text $LogPath
    @(
        "`$ErrorActionPreference = 'Continue'"
        '$global:LASTEXITCODE = 2'
        '[Console]::OutputEncoding = [Text.Encoding]::UTF8'
        'try {'
        "    & $(ConvertTo-PsLiteral -Text $Winget) $quotedArgs 2>&1 | ForEach-Object { `"`$_`" } | Out-File -LiteralPath $log -Encoding utf8"
        '} catch {'
        "    ('winget を起こせなかった: ' + `$_.Exception.Message) | Out-File -LiteralPath $log -Encoding utf8 -Append"
        '    $global:LASTEXITCODE = 2'
        '}'
        'exit $LASTEXITCODE'
    ) -join "`n"
}

# PowerShell の本文を -EncodedCommand に渡す形 (UTF-16LE の base64) にする (runner の encode_command と同じ)
function ConvertTo-EncodedCommand {
    param([string]$Script)
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
}

# winget の出力の行から、進み具合の表示 (回る棒・帯) を除く (Invoke-Winget と同じ)
function Select-WingetOutputLines {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        $s = "$line"
        if (($s -notmatch '^\s*[-\\|/]?\s*$') -and ($s -notmatch '[█▒]')) { $s }
    }
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す (Install-T3Code.ps1 と同じ)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @(Select-WingetOutputLines -Lines $lines) }
}

# 昇格して打つ winget.exe の絶対パス。アプリ インストーラーの実行エイリアス (%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe) があれば
# それ、無ければ PATH の winget のうち .exe の実行ファイルだけ (関数・alias・PATH の先の winget.cmd や winget.ps1 は、管理者の権限で
# 流さない)。無ければ $null
function Resolve-WingetExe {
    if ($env:LOCALAPPDATA) {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $alias) { return $alias }
    }
    $app = @(Get-Command -Name winget -CommandType Application -ErrorAction SilentlyContinue | Where-Object { "$($_.Source)" -like '*.exe' })
    if ($app.Count -gt 0) { return $app[0].Source }
    $null
}

# 今の PowerShell が管理者の権限で動いているか (昇格した会話なら、UAC を出さずにそのまま winget を打つ)
function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 管理者の権限で winget を打つ。昇格した会話でなければ、System32 の Windows PowerShell を Start-Process -Verb RunAs で昇格させて打たせる
# (UAC の確認が 1 回出る。昇格させるのは、同じユーザーが差し替えられない System32 のもの)。昇格した側は出力を一時ファイルに書き、winget の
# 終了コードで終わる。こちらはその終了コードと、ファイルの行 (進み具合の表示は除く) を返す。UAC を断った・出せなかった (SSH の会話など)
# ときは Declined を true にし、終了コードを 1223 (ERROR_CANCELLED) にする
function Invoke-ElevatedWinget {
    param([string]$Winget, [string[]]$Arguments)
    if (Test-Elevated) {
        $direct = Invoke-Winget -Arguments $Arguments
        return [pscustomobject]@{ ExitCode = $direct.ExitCode; Lines = $direct.Lines; Declined = $false }
    }
    $log = Join-Path ([IO.Path]::GetTempPath()) ('dotfiles-claude-desktop-{0}.log' -f [guid]::NewGuid().ToString('N'))
    $shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $encoded = ConvertTo-EncodedCommand -Script (Get-ElevatedWingetScript -Winget $Winget -Arguments $Arguments -LogPath $log)
    try {
        $p = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ ExitCode = 1223; Lines = @("UAC: $($_.Exception.Message)"); Declined = $true }
    }
    $lines = @()
    if (Test-Path -LiteralPath $log) {
        $lines = @(Select-WingetOutputLines -Lines @(Get-Content -LiteralPath $log -Encoding UTF8))
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Lines = $lines; Declined = $false }
}

# このユーザーに入っている Claude の MSIX を、1 つ 1 行の字 (ConvertFrom-ClaudeAppxLines が読む形) で返す。Windows PowerShell 5.1 なら
# そのまま Get-AppxPackage を打ち、PowerShell 7 なら System32 の Windows PowerShell に打たせる (PowerShell 7 の Appx は読めないことがある)。
# 打てなければ例外 (入っているか分からないまま入れにいかない)
function Get-ClaudeAppxLines {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return @(Get-AppxPackage -Name Claude -ErrorAction Stop | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.Name, $_.PackageFamilyName, $_.Version, $_.InstallLocation })
    }
    # 欄はどれも ASCII (名前・PackageFamilyName・版・C:\Program Files\WindowsApps の下の置き場所) なので、出力の文字コードはそろえない
    $shell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $text = "`$ErrorActionPreference = 'Stop'; Get-AppxPackage -Name Claude | ForEach-Object { '{0}`t{1}`t{2}`t{3}' -f `$_.Name, `$_.PackageFamilyName, `$_.Version, `$_.InstallLocation }"
    $ErrorActionPreference = 'Continue'
    $out = @(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand (ConvertTo-EncodedCommand -Script $text) 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell で Get-AppxPackage を打てなかった (終了コード $LASTEXITCODE): $($out -join ' / ')"
    }
    $out
}

# Cowork の常駐 (CoworkVMService) の状態 (Running など)。無ければ $null
function Get-CoworkServiceStatus {
    $service = Get-Service -Name 'CoworkVMService' -ErrorAction SilentlyContinue
    if ($service) { return "$($service.Status)" }
    $null
}

# 仮想マシン プラットフォームの InstallState (管理者の権限は要らない。Get-WindowsOptionalFeature は管理者が要る)。読めなければ $null
function Get-VmPlatformInstallState {
    try {
        $feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction Stop
        if ($feature) { return $feature.InstallState }
    } catch {
        return $null
    }
    $null
}

# 旧来の exe の Claude (Squirrel。%LOCALAPPDATA%\AnthropicClaude と、HKCU の Uninstall の AnthropicClaude (winget の manifest の ProductCode))
function Get-ClaudeLegacyState {
    $dir = $null
    $updateExists = $false
    if ($env:LOCALAPPDATA) {
        $dir = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
        $updateExists = Test-Path -LiteralPath (Join-Path $dir 'Update.exe')
    }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnthropicClaude'
    $keyExists = Test-Path -LiteralPath $key
    $legacyVersion = $null
    if ($keyExists) {
        $p = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($p -and (@($p.PSObject.Properties.Name) -contains 'DisplayVersion')) { $legacyVersion = [string]$p.DisplayVersion }
    }
    [pscustomobject]@{ Exists = ($updateExists -or $keyExists); Dir = $dir; Version = $legacyVersion }
}

# 今の状態を読む (何も変えない)
function Get-ClaudeDesktopState {
    param([string]$PackageId, [string]$FamilyName, [version]$Target)
    $entry = Select-ClaudeAppxEntry -Entries @(ConvertFrom-ClaudeAppxLines -Lines @(Get-ClaudeAppxLines)) -FamilyName $FamilyName
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $exists = $null -ne $entry
    $installed = $null
    $installedText = $null
    $location = $null
    if ($exists) {
        $installedText = "$($entry.Version)"
        $installed = ConvertTo-ClaudeDesktopVersion -Text $installedText
        $location = $entry.InstallLocation
    }
    $legacy = Get-ClaudeLegacyState
    [pscustomobject]@{
        Exists        = $exists
        Location      = $location
        Installed     = $installed
        InstalledText = $installedText
        Plan          = Get-ClaudeDesktopPlan -Exists $exists -Installed $installed -Target $Target
        Pinned        = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions      = $versions
        Latest        = $latest
        Service       = Get-CoworkServiceStatus
        VmPlatform    = ConvertFrom-VmPlatformState -InstallState (Get-VmPlatformInstallState)
        Legacy        = [bool]$legacy.Exists
        LegacyVersion = $legacy.Version
    }
}

# 行を出す。直すことがある行 (⚠) は黄色にする
function Write-ClaudeDesktopRows {
    param([object[]]$Rows)
    foreach ($row in $Rows) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

function Invoke-InstallClaudeDesktop {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'Anthropic.Claude'
    $familyName = 'Claude_pzs8sxrjxfjjc'
    # 書き間違えた -Version は、winget を打つ前にここで例外になる (終了コード 2)
    $target = ConvertTo-ClaudeDesktopVersion -Text $Version
    if (-not $target) { throw "-Version の形が違う: $Version" }

    $wingetExe = Resolve-WingetExe
    if (-not $wingetExe) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-ClaudeDesktopState -PackageId $packageId -FamilyName $familyName -Target $target
    Write-ClaudeDesktopRows -Rows @(Format-ClaudeDesktopState -State $state -Target $Version)
    $code = Get-ClaudeDesktopExitCode -State $state
    $blocker = Get-ClaudeDesktopApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version -Legacy $state.Legacy

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        Write-ClaudeDesktopRows -Rows @(Get-ClaudeDesktopVerdict -State $state -Code $code -Blocker $blocker -Target $Version -PackageId $packageId)
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    if ($blocker -eq 'unknown') {
        Write-Host '入っている Claude Desktop の版が読めないので、何もしない。Get-AppxPackage -Name Claude で入っている版を確かめる'
        return 1
    }
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }
    # 旧来の exe の Claude が残っていれば、MSIX を入れない・上げない。MSIX の側が揃っていて残りがそれだけなら、することが無い
    # (どちらも外すのは人。上の ※ の手順)
    if (($blocker -eq 'legacy') -or (Test-ClaudeDesktopLegacyOnly -State $state)) {
        Write-ClaudeDesktopRows -Rows @(Get-ClaudeDesktopVerdict -State $state -Code $code -Blocker $blocker -Target $Version -PackageId $packageId)
        return $code
    }

    $wingetFailed = $false
    if (@('install', 'upgrade') -contains $state.Plan) {
        if ($state.Plan -eq 'upgrade') {
            Write-Host '上げる前に Claude を終える (☰ > File > Exit。動いている Claude は入れ替えられない)'
            # 古い版の pin を残さないよう先に外す (上げた後に足し直す)。外せなくても、upgrade に付けた --include-pinned で pin を越える
            if ($state.Pinned) {
                $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
                if ($unpin.ExitCode -ne 0) { Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode) }
            }
        }
        if (Test-Elevated) {
            Write-Host '管理者の権限で動いているので、UAC の確認を出さずに winget を打つ'
        } else {
            Write-Host 'Windows のデスクトップに UAC の確認が 1 回出る (Windows PowerShell が winget で Claude Desktop を管理者の権限で入れる)。「はい」を押す'
        }
        # 昇格した側の窓は隠すので、終わるまで winget の出力は出ない
        Write-Host 'winget の出力は、入れ終わってからまとめて出す (MSIX は約 300 MB。数分かかる)'
        foreach ($arguments in @(Get-WingetCommands -Plan $state.Plan -PackageId $packageId -Version $Version)) {
            Write-Host "winget $($arguments -join ' ') (管理者の権限で)"
            $result = Invoke-ElevatedWinget -Winget $wingetExe -Arguments $arguments
            $result.Lines | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" }
            if ($result.Declined) {
                Write-Host 'UAC の確認を断った・出せなかった (SSH の会話では出せない)。デスクトップの PowerShell で Install-ClaudeDesktop を打ち直す'
                $wingetFailed = $true
                break
            }
            if ($result.ExitCode -ne 0) {
                Write-Host ('winget が失敗した (終了コード 0x{0:X8})。Claude が動いていれば終えてから、Install-ClaudeDesktop を打ち直す' -f $result.ExitCode)
                Get-WingetPinnedHint -ExitCode $result.ExitCode -PackageId $packageId | ForEach-Object { Write-Host $_ }
                $wingetFailed = $true
                break
            }
        }
    }

    # 入っていれば pin を足す (上げた後は、上で外したので足し直しになる)。pin は管理者の権限が要らない
    $installedNow = $null -ne (Select-ClaudeAppxEntry -Entries @(ConvertFrom-ClaudeAppxLines -Lines @(Get-ClaudeAppxLines)) -FamilyName $familyName)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ($installedNow -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) {
            Write-Host 'winget pin を足した (winget upgrade --all から外れる。Claude Desktop の自動更新は止めない)'
        } else {
            Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode)
            if ($state.Legacy) {
                Write-Host '※ 旧来の exe の Claude も Anthropic.Claude として数えられ、winget が pin の相手を決められないことがある。旧来の exe の Claude を外してから Install-ClaudeDesktop を打ち直す'
            }
        }
    }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-ClaudeDesktopState -PackageId $packageId -FamilyName $familyName -Target $target
    Write-ClaudeDesktopRows -Rows @(Format-ClaudeDesktopState -State $after -Target $Version)
    $afterCode = Get-ClaudeDesktopExitCode -State $after
    if (($state.Plan -eq 'install') -and $after.Exists) {
        Write-Host 'Claude のサインインは手でする (スタートメニューの Claude を開く。dotfiles はサインインに触らない)'
    }
    if (($state.Plan -eq 'install') -and (-not $after.Exists) -and (-not $wingetFailed)) {
        Write-Host '※ winget は終わったが、このユーザーの Get-AppxPackage に Claude が出ない。UAC で別のユーザー (管理者) の資格情報を入れたなら、Claude はそのユーザーに入った (Cowork を使うには、このユーザーが管理者であることが要る)'
    }
    if ($afterCode -eq 0) {
        Write-Host '揃った'
        return 0
    }
    Write-ClaudeDesktopRows -Rows @(Get-ClaudeDesktopVerdict -State $after -Code $afterCode -Blocker (Get-ClaudeDesktopApplyBlocker -Plan $after.Plan -Versions $after.Versions -Target $Version -Legacy $after.Legacy) -Target $Version -PackageId $packageId)
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallClaudeDesktop -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
