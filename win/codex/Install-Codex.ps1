<#
.SYNOPSIS
Windows の Codex CLI (OpenAI のコーディング エージェントの CLI。winget の OpenAI.Codex の portable) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/codex/Install-Codex.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Codex から呼ぶ (win/README.md の「Codex CLI」)。
入れて揃えるのは Windows の runner の手順 codex (ホストの値の [tools] windowsCodex が on のマシンだけ。既定はグループで決まり、all で on)。

winget の OpenAI.Codex は zip の中の portable で、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の下に入る。置き場所の exe の
名前は codex-x86_64-pc-windows-msvc.exe (arm64 は codex-aarch64-pc-windows-msvc.exe) で、codex という名前 (manifest の PortableCommandAlias) は、
winget が次のどちらかの形で付ける (winget の PortableFlow.cpp・PortableInstaller.cpp):
  - symlink の形: %LOCALAPPDATA%\Microsoft\WinGet\Links\codex.exe (置き場所の exe への symlink)。winget が symlink を作れるとき (開発者モードが on か、
    昇格した winget)
  - hardlink の形: 置き場所の codex.exe (置き場所の exe の hardlink) と、置き場所をユーザーの PATH に足した行。winget 1.30 から。winget が symlink を
    作れないとき (昇格していない winget で、開発者モードが off) は、Links の代わりに置き場所を PATH に足し、その codex.exe が引かれる
winget 1.29 までは hardlink を作らず、symlink を作れないと置き場所を PATH に足すだけなので、codex と打っても見つからない。

winget は UAC で昇格して打たない (そのまま打つ)。winget 1.30 は、昇格した会話 (UAC で昇格した token) から user スコープの portable を入れる・外すのを
0x8A15007D で断る。次のときは winget を打たずに止め、直し方を出す (runner は知らせるだけ):
  - 昇格した会話で、winget が 1.30 以降 (昇格していない PowerShell で打ち直す)
  - 昇格していない会話で、開発者モードが off で、winget が 1.29 以前 (入れても codex と打てない。アプリ インストーラーを更新するか、開発者モードを on にする)
codex と打てる形が無い形で入っていれば (1.29 以前の winget で入れたなど)、同じ版を入れ直して作らせる。

codex は自分の置き場所の判定 (同梱の codex-path\rg.exe と codex-resources を使うか) を、実体の exe の名前が置き場所の codex-package.json の
entrypoint と同じかで行う (codex の codex-rs/install-context)。symlink は実体へたどるので当たるが、hardlink の codex.exe は名前が違うので外れ、
codex は rg を PATH から探す。そこで PATH で引かれる codex が置き場所の codex.exe (hardlink の形) なら、置き場所の codex-path (同梱の rg.exe が
ある) をユーザーの PATH に足す。sandbox の helper (codex-command-runner.exe など) と codex-code-mode-host.exe は exe の隣で探すので、どちらの形でも
見つかる。名前を替えた写しや .cmd の shim は作らない。

winget の manifest の依存 (BurntSushi.ripgrep.MSVC と Microsoft.VCRedist.2015+) は入れない (--skip-dependencies)。codex の exe は
VC++ のランタイムを使わず (CRT を静的に持つ)、rg.exe は zip の中 (codex-path\rg.exe) にある。VCRedist は machine に入るので、入れると UAC の確認が出る。

codex.exe が動いている間は置き換えられないので、入れ替えが要るときに置き場所の exe が動いていれば、何も変えずに止める (止めはしない)。
形は Install-Fzf.ps1 と同じ (常駐が無いので、版のずれも揃える)。違うのは、codex と打てる形 (symlink か hardlink) と、同梱の rg を見ること。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id OpenAI.Codex --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3
(winget を打てない会話・入れても codex と打てない PC では、入っていなくても 1)。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.170.0',
    [switch]$Check,
    [switch]$IfMissing
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-Codex.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# codex --version の出力 ("codex-cli <版>") から版を拾う。無ければ $null
function Get-CodexVersionFromOutput {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(codex(-cli)?\s+)?v?(\d+(\.\d+)+)(\s|$)') { return $Matches[3] }
    }
    $null
}

# winget show --versions の出力から、版の行だけを上から順 (= 新しい順) に拾う (Install-Fzf.ps1 と同じ)。
# 呼ぶ側は @() で包む (1 つも無いと $null にほどける)
function Get-WingetVersionList {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*(\d+(\.\d+)+(-[0-9A-Za-z][0-9A-Za-z.-]*)?)\s*$') { $Matches[1] }
    }
}

# winget --version の出力 ("v1.30.310" など。preview は "v1.30.140-preview") から winget 自身の版を拾う。読めなければ $null
function Get-WingetClientVersion {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ("$line" -match '^\s*v?(\d+)\.(\d+)(\.(\d+))?') {
            $build = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
            return [version]::new([int]$Matches[1], [int]$Matches[2], $build)
        }
    }
    $null
}

# winget が、symlink を作れないときに置き場所へ codex.exe の hardlink を作り、昇格した会話からの user スコープの portable を断る版 (1.30 以降) か。
# 読めなければ $null (どちらとも決めない)
function Test-WingetModernPortable {
    param($WingetVersion)
    if ($null -eq $WingetVersion) { return $null }
    $WingetVersion -ge [version]'1.30'
}

# WinGet\Links の codex.exe が、置き場所の exe への symlink か。ok (そう) / missing (無い) / wrong (ほかを指す・symlink でない)。
# Target は Get-Item の Target (5.1 は配列、7 は文字列。呼ぶ側が 1 つにする)。比べるのは大文字小文字を区別しない (Windows のパスと同じ)
function Get-CodexLinkState {
    param([bool]$Exists, [string]$LinkType, [string]$Target, [string]$ExePath)
    if (-not $Exists) { return 'missing' }
    if ($LinkType -ne 'SymbolicLink') { return 'wrong' }
    if (-not $Target -or -not $ExePath) { return 'wrong' }
    if ($Target.TrimEnd('\') -eq $ExePath.TrimEnd('\')) { return 'ok' }
    'wrong'
}

# 置き場所の codex.exe が、置き場所の exe の hardlink か。ok (そう) / missing (無い) / wrong (symlink などの reparse point・大きさが違う・
# 置き場所の exe が無い)。hardlink は同じファイルなので大きさが同じ (winget が hardlink を作れずに写しにしたときも同じ)
function Get-CodexHardlinkState {
    param([bool]$Exists, [string]$LinkType, [long]$Length, [long]$ExeLength)
    if (-not $Exists) { return 'missing' }
    if ($LinkType) { return 'wrong' }
    if (($ExeLength -lt 0) -or ($Length -ne $ExeLength)) { return 'wrong' }
    'ok'
}

# codex と打てる形。symlink (WinGet\Links の symlink) / hardlink (置き場所の codex.exe) / wrong (Links の codex.exe がほかを指す・置き場所の
# codex.exe が違う) / missing (どちらも無い)。Links の codex.exe がほかを指していれば、置き場所の hardlink があっても wrong にする
# (Links が PATH で先に引かれる。入れ直すと winget が Links の codex.exe を消してから作り直す)
function Get-CodexAliasState {
    param([string]$LinkState, [string]$HardlinkState)
    if ($LinkState -eq 'ok') { return 'symlink' }
    if ($LinkState -eq 'wrong') { return 'wrong' }
    if ($HardlinkState -eq 'ok') { return 'hardlink' }
    if ($HardlinkState -eq 'wrong') { return 'wrong' }
    'missing'
}

# winget を打てるか。direct (そのまま打つ) / elevated (昇格した会話で winget が 1.30 以降。winget が user スコープの portable を断る) /
# old-winget (昇格していない会話で、開発者モードが off で、winget が 1.29 以前。symlink も hardlink も作れず、入れても codex と打てない)。
# winget の版が読めなければ direct (打ってみる)。昇格した会話の 1.29 以前の winget は symlink を作れるので direct
function Get-CodexInstallRoute {
    param([bool]$Elevated, [bool]$DeveloperMode, $WingetVersion)
    $modern = Test-WingetModernPortable -WingetVersion $WingetVersion
    if ($Elevated) {
        if ($modern -eq $true) { return 'elevated' }
        return 'direct'
    }
    if ($DeveloperMode -or ($modern -ne $false)) { return 'direct' }
    'old-winget'
}

# 入っているか・入っている版・固定した版・codex と打てる形から、することを決める。exe があるのに版が読めないときも入れ替える。
# 版が揃っていて codex と打てる形だけが無い・違うときは relink (同じ版を入れ直して、winget に作らせる)
function Get-CodexPlan {
    param([bool]$Exists, [string]$Installed, [string]$Target, [string]$AliasState)
    if (-not $Exists) { return 'install' }
    if ($Installed -cne $Target) { return 'change' }
    if ($AliasState -notin @('symlink', 'hardlink')) { return 'relink' }
    'none'
}

# 入れ替えの向き。winget show --versions の並び (新しい順) の位置で比べる (Install-Fzf.ps1 と同じ)
function Get-CodexDirection {
    param([string[]]$Versions, [string]$Installed, [string]$Target)
    $list = @($Versions)
    $i = [array]::IndexOf($list, $Installed)
    $t = [array]::IndexOf($list, $Target)
    if ($i -lt 0 -or $t -lt 0) { return 'unknown' }
    if ($t -lt $i) { return 'up' }
    if ($t -gt $i) { return 'down' }
    'same'
}

# winget pin list の出力に、その Id を列に持つ行があるか (Install-Fzf.ps1 と同じ)。
# 見出しや「pin が無い」の文言は表示言語で変わるので、Id の一致だけを見る
function Test-WingetPinned {
    param([string[]]$Lines, [string]$PackageId)
    foreach ($line in $Lines) {
        if (($line -split '\s+') -ccontains $PackageId) { return $true }
    }
    $false
}

# plan ごとに打つ winget の引数 (配列の配列)。入れ替え・入れ直しは、外してから入れる (portable の置き場所は版によらず同じ。codex の
# 設定とログイン (%USERPROFILE%\.codex) は置き場所の外にある)。install は portable を名指しし、user スコープで入れ、manifest の依存
# (ripgrep・VCRedist) は入れない (頭の説明)
function Get-WingetCommands {
    param([string]$Plan, [string]$PackageId, [string]$Version)
    $common = @('--id', $PackageId, '--exact', '--source', 'winget', '--silent',
        '--accept-source-agreements', '--disable-interactivity')
    $put = $common + @('--version', $Version, '--installer-type', 'portable', '--scope', 'user', '--skip-dependencies',
        '--accept-package-agreements')
    switch ($Plan) {
        'install' { , (@('install') + $put) }
        { $_ -in @('change', 'relink') } {
            , (@('uninstall') + $common)
            , (@('install') + $put)
        }
    }
}

# 入れ替え・入れ直しの前に、固定した版の取得とハッシュだけを確かめる winget download の引数 (Install-Fzf.ps1 と同じ)
function Get-WingetDownloadArguments {
    param([string]$PackageId, [string]$Version, [string]$Directory)
    @('download', '--id', $PackageId, '--exact', '--source', 'winget', '--version', $Version,
        '--installer-type', 'portable', '--download-directory', $Directory, '--skip-dependencies',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
}

# PATH (; 区切り) を前から見て、$Names のどれかが最初に見つかったパスを返す。無ければ $null (Install-Fzf.ps1 と同じ)。
# PowerShell は PATH のディレクトリの順に、.exe だけでなく .cmd・.bat・.ps1 も引くので、ディレクトリごとに名前を並べて見る。
# $Exists はファイルがあるかを答える scriptblock (テストでは偽物を渡す)。
# 区切りは \ で組む (Linux の pwsh で流すテストでも同じ文字列になるよう、Join-Path は使わない)
function Resolve-CodexOnPath {
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

# PATH で引かれる codex がどこのものか。'links' (WinGet\Links\codex.exe。symlink の形) / 'package' (置き場所の codex.exe。hardlink の形) /
# 'other' (npm の codex.cmd・公式の install.ps1 の codex.exe など) / 'none'
function Get-CodexPathKind {
    param([string]$Resolved, [string]$LinksDir, [string]$PackageDir)
    if (-not $Resolved) { return 'none' }
    # -eq は大文字小文字を区別しない (Windows のパスと同じ)
    if ($LinksDir -and ($Resolved -eq "$($LinksDir.TrimEnd('\'))\codex.exe")) { return 'links' }
    if ($PackageDir -and ($Resolved -eq "$($PackageDir.TrimEnd('\'))\codex.exe")) { return 'package' }
    'other'
}

# PATH の 1 つの要素が $Dir を指すか。前後の空白と " を落とし、%VAR% を展開し、末尾の \ を落としてから、大文字小文字を区別せずに比べる
# (Install-HerdrApp.ps1 と同じ)
function Test-CodexPathEntry {
    param([string]$Entry, [string]$Dir)
    $value = [Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim('"')).TrimEnd('\')
    if (-not $value) { return $false }
    $value -ieq $Dir.TrimEnd('\')
}

# PATH の値 (; 区切り) に、$Dir を指す要素があるか
function Test-CodexPathListed {
    param([string]$Raw, [string]$Dir)
    foreach ($entry in ($Raw -split ';')) {
        if (Test-CodexPathEntry -Entry $entry -Dir $Dir) { return $true }
    }
    $false
}

# $Dir を末尾に足した PATH の生の値 (末尾の ; を落として ;<Dir>)。既にあれば変えない (Install-HerdrApp.ps1 と同じ)
function Get-CodexPathValueWithEntry {
    param([string]$Raw, [string]$Dir)
    if (Test-CodexPathListed -Raw $Raw -Dir $Dir) { return $Raw }
    if ($Raw) { return "$($Raw.TrimEnd(';'));$Dir" }
    $Dir
}

# 同梱の rg を codex が引けるか。PATH で引かれる codex が置き場所の codex.exe (hardlink の形) のときだけ見る (codex は同梱の rg を自分では
# 見つけないので、置き場所の codex-path を PATH に置いて引かせる)。na (hardlink の形でない) / absent (置き場所に codex-path\rg.exe が無い) /
# ok (codex-path が PATH にある) / missing (無い。Install-Codex がユーザーの PATH に足す)
function Get-CodexRgState {
    param([string]$PathKind, [bool]$BundledRg, [string]$PathValue, [string]$RgDir)
    if ($PathKind -ne 'package') { return 'na' }
    if (-not $BundledRg) { return 'absent' }
    if (Test-CodexPathListed -Raw $PathValue -Dir $RgDir) { return 'ok' }
    'missing'
}

# 揃える手順 (Install-Codex) で直す差 (版・pin・codex と打てる形・同梱の rg の PATH) があるか
function Test-CodexDrift {
    param($State)
    ($State.Plan -ne 'none') -or (-not $State.Pinned) -or ($State.RgState -eq 'missing')
}

# PATH のずれ (ほかの codex が先に引かれる・codex と打てる形はあるのに PATH で見つからない) があるか。揃える手順では直らないので、※ の行で
# 直し方を添える。入れる・入れ直す前 (codex と打てる形が無い) に見つからないのは当たり前なので数えない
function Test-CodexPathDrift {
    param($State)
    ($State.PathKind -eq 'other') -or (($State.PathKind -eq 'none') -and ($State.Plan -notin @('install', 'relink')))
}

# 入れる・入れ替える・入れ直すのに、winget を打てない (昇格した会話の 1.30 以降の winget) か、打っても codex と打てない (1.29 以前の winget で
# 開発者モードが off) か。揃える手順では直らない (人が打ち直す・winget を更新する)。版が揃っていて codex と打てれば、winget を打たないので当たらない
function Test-CodexBlocked {
    param($State)
    ($State.Route -in @('elevated', 'old-winget')) -and ($State.Plan -in @('install', 'change', 'relink'))
}

# 終了コード。winget を打てない・打っても codex と打てないなら 1 (入っていなくても 3 にしない。runner が -IfMissing で入れにいかないように)、
# 入っていなければ 3、版・pin・codex と打てる形・同梱の rg の PATH・PATH が揃っていれば 0、ほかは 1
function Get-CodexExitCode {
    param($State)
    if (Test-CodexBlocked -State $State) { return 1 }
    if ($State.Plan -eq 'install') { return 3 }
    if ((Test-CodexDrift -State $State) -or (Test-CodexPathDrift -State $State)) { return 1 }
    0
}

# 揃える前に止める理由。無ければ $null
#   elevated:   入れる・入れ直すのに、昇格した会話で winget が 1.30 以降 (winget が user スコープの portable を断る)
#   old-winget: 入れる・入れ直すのに、winget が 1.29 以前で開発者モードが off (入れても codex と打てない)
#   not-listed: 入れる・入れ替えるのに、固定した版が winget に無い (版の一覧が読めたときだけ判断する)
#   busy:       入れ替える・入れ直すのに、置き場所の exe が動いている (置き換えられない)
function Get-CodexApplyBlocker {
    param([string]$Plan, [string[]]$Versions, [string]$Target, [int]$BusyCount, [string]$Route)
    if (($Route -in @('elevated', 'old-winget')) -and ($Plan -in @('install', 'change', 'relink'))) { return $Route }
    $known = @($Versions | Where-Object { $_ })
    if (($Plan -ne 'none') -and ($known.Count -gt 0) -and ($known -cnotcontains $Target)) { return 'not-listed' }
    if (($Plan -in @('change', 'relink')) -and ($BusyCount -gt 0)) { return 'busy' }
    $null
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、ほかは 2 字下げる。ずれではないこと
# (新しい版がある・動いている codex がある) は ※ で添える
function Format-CodexState {
    param($State, [string]$Target, [string]$PackageId, [string]$PackageDir)
    $direction = if ($State.Direction -eq 'up') { ' (上げる)' } elseif ($State.Direction -eq 'down') { ' (下げる)' } else { '' }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'change' { "入れ替える$direction" }
        default { 'そのまま' }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' } elseif ($State.Installed) { $State.Installed } else { '不明 (codex --version が読めない)' }
    $latestText = if ($State.Latest) { $State.Latest } else { '不明 (winget show が失敗)' }
    $pinText = if ($State.Pinned) { 'あり' } else { '無し → 足す' }
    $exeName = if ($State.ExeName) { $State.ExeName } else { 'codex-x86_64-pc-windows-msvc.exe' }
    $aliasText = switch ($State.AliasState) {
        'symlink' { "WinGet\Links\codex.exe (置き場所の $exeName への symlink)" }
        'hardlink' { "置き場所の codex.exe ($exeName の hardlink。winget が symlink を作れずに、置き場所を PATH に足した形)" }
        'wrong' {
            if ($State.LinkState -eq 'wrong') { "WinGet\Links\codex.exe が置き場所の exe を指していない ($($State.LinkTarget)) → 入れ直す" }
            else { "置き場所の codex.exe が $exeName の hardlink ではない → 入れ直す" }
        }
        default {
            if ($State.Plan -eq 'install') { '入れるときに winget が作る (WinGet\Links\codex.exe の symlink か、置き場所の codex.exe の hardlink)' }
            else { '無い → 入れ直す (winget 1.29 以前が symlink を作れずに、置き場所を PATH に足しただけの形。codex と打っても見つからない)' }
        }
    }
    $pathText = switch ($State.PathKind) {
        'links' { 'winget の symlink (WinGet\Links\codex.exe)' }
        'package' { 'winget の hardlink (置き場所の codex.exe)' }
        'other' { "$($State.PathResolved) (winget のものではない)" }
        default { '見つからない' }
    }
    $rows = @(
        @{ Text = "Codex CLI (winget の $PackageId、$PackageDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版    : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版      : $Target → $planText"; Warn = ($State.Plan -in @('install', 'change')); Indent = $true }
        @{ Text = "winget の最新版 : $latestText"; Warn = $false; Indent = $true }
        @{ Text = "winget pin      : $pinText"; Warn = (-not $State.Pinned); Indent = $true }
        @{ Text = "codex の別名    : $aliasText"; Warn = (($State.Plan -ne 'install') -and ($State.AliasState -notin @('symlink', 'hardlink'))); Indent = $true }
        @{ Text = "PATH の codex   : $pathText"; Warn = (Test-CodexPathDrift -State $State); Indent = $true }
    )
    if ($State.PathKind -eq 'links') {
        $rows += @{ Text = '同梱の rg       : codex が置き場所の codex-path\rg.exe を自分で使う (symlink の形)'; Warn = $false; Indent = $true }
    } elseif ($State.PathKind -eq 'package') {
        $rgText = switch ($State.RgState) {
            'ok' { '置き場所の codex-path が PATH にある (hardlink の形の codex は同梱の rg を自分では見つけないので、PATH で引かせる)' }
            'missing' { '置き場所の codex-path が PATH に無い → ユーザーの PATH に足す (hardlink の形の codex は同梱の rg を自分では見つけない)' }
            default { '置き場所に codex-path\rg.exe が無い (codex は PATH の rg を使う)' }
        }
        $rows += @{ Text = "同梱の rg       : $rgText"; Warn = ($State.RgState -eq 'missing'); Indent = $true }
    }
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    $versions = @($State.Versions | Where-Object { $_ })
    if (($versions.Count -gt 0) -and ($versions -cnotcontains $Target)) {
        if ($State.Plan -in @('none', 'relink')) {
            [pscustomobject]@{ Text = '※ 固定した版が winget から消えている。新しいマシンには入れられないので、-Version を winget にある版へ変える'; Warn = $false }
        } else {
            [pscustomobject]@{ Text = '⚠ 固定した版が winget show --versions に無い (書き間違いか、winget から消えた) ので入れられない'; Warn = $true }
        }
    } elseif (($versions.Count -gt 0) -and ($versions[0] -cne $Target)) {
        [pscustomobject]@{ Text = "※ winget に固定した版より新しい $($versions[0]) がある。上げるなら Install-Codex.ps1 の -Version の既定値を変える"; Warn = $false }
    }
    if (Test-CodexBlocked -State $State) {
        $wingetText = if ($State.WingetVersion) { "winget $($State.WingetVersion)" } else { 'winget' }
        if ($State.Route -eq 'elevated') {
            [pscustomobject]@{ Text = "⚠ 昇格した PowerShell では winget が codex を入れない ($wingetText は、昇格した会話から user スコープの portable を入れる・外すのを断る)。Install-Codex は winget を打たない"; Warn = $true }
            [pscustomobject]@{ Text = '※ 昇格していない PowerShell (デスクトップの普通の端末) で Install-Codex を打ち直す (win/README.md の「Codex CLI」)'; Warn = $false }
        } else {
            [pscustomobject]@{ Text = "⚠ winget が古く、codex と打てる形を作れない ($wingetText は symlink を作れないときに codex.exe の hardlink を作らず、開発者モードも off)。入れても codex と打てないので、Install-Codex は入れない"; Warn = $true }
            [pscustomobject]@{ Text = '※ Microsoft Store で「アプリ インストーラー」を更新して winget を 1.30 以降にするか、開発者モードを on にして (設定 > システム > 開発者向け。管理者が要る)、Install-Codex を打ち直す (win/README.md の「Codex CLI」)'; Warn = $false }
        }
    }
    if ($State.PathKind -eq 'other') {
        # PATH のずれは揃える手順 (Install-Codex) では直らないので、直し方を添える
        $cut = $State.PathResolved.LastIndexOf('\')
        $dir = if ($cut -ge 0) { $State.PathResolved.Substring(0, $cut) } else { $State.PathResolved }
        [pscustomobject]@{ Text = "※ PATH のずれは Install-Codex では直らない。$dir の codex を外す (npm の @openai/codex なら npm uninstall -g @openai/codex) か、$dir をユーザーの PATH から外す (win/README.md の「Codex CLI」)"; Warn = $false }
    } elseif (($State.PathKind -eq 'none') -and ($State.Plan -notin @('install', 'relink'))) {
        [pscustomobject]@{ Text = "※ PATH で codex が見つからない。symlink の形なら %LOCALAPPDATA%\Microsoft\WinGet\Links を、hardlink の形なら置き場所 ($PackageDir) をユーザーの PATH に足し、新しい PowerShell を開く"; Warn = $false }
    }
    if (($State.Plan -in @('change', 'relink')) -and ($State.BusyCount -gt 0)) {
        [pscustomobject]@{ Text = "※ codex が $($State.BusyCount) 個動いている。入れ替えるには、動いている codex (ほかの端末の会話など) を終わらせる"; Warn = $false }
    }
}

# 締めの行 (-Check の最後と、揃えた後の最後)。揃っていれば何も返さない。直すことごとに ⚠️ で始まる行を返す。
# Windows の runner (win/runner/src/steps/ps1.rs) は「→ Install-Codex で入れる」「→ Install-Codex で揃える」「→ ※ の手順で直す」の
# 文言で、入れるか・揃えるか・知らせるだけかを決め、winget を打てない行 (「昇格した PowerShell では winget が codex を入れない」
# 「winget が古く、codex と打てる形を作れない」) で直し方を選ぶ (文言を変えるときは向こうも直す)。winget を打てないなら、その 1 行だけ
function Format-CodexVerdict {
    param($State)
    if (Test-CodexBlocked -State $State) {
        if ($State.Route -eq 'elevated') {
            '⚠️ 昇格した PowerShell では winget が codex を入れない (winget 1.30 から) → ※ の手順で直す ⚠️'
        } else {
            '⚠️ winget が古く、codex と打てる形を作れない (winget 1.29 以前で、開発者モードも off) → ※ の手順で直す ⚠️'
        }
        return
    }
    if ($State.Plan -eq 'install') {
        '⚠️ Codex CLI が入っていない → Install-Codex で入れる ⚠️'
        return
    }
    if (($State.Plan -eq 'change') -or (-not $State.Pinned)) { '⚠️ 固定した版と揃っていない → Install-Codex で揃える ⚠️' }
    if ($State.AliasState -notin @('symlink', 'hardlink')) { '⚠️ codex と打てない (WinGet\Links の symlink も、置き場所の codex.exe の hardlink も無い・違う) → Install-Codex で揃える ⚠️' }
    if ($State.RgState -eq 'missing') { '⚠️ codex が同梱の rg を引けない (置き場所の codex-path が PATH に無い) → Install-Codex で揃える ⚠️' }
    if (Test-CodexPathDrift -State $State) { '⚠️ PATH の codex が winget のものではない → ※ の手順で直す ⚠️' }
}

# winget の失敗の終了コードに添える行。無ければ $null。0x8A15007D (APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED) は、昇格した会話から
# user スコープの portable を入れる・外すのを winget が断ったとき (会話の昇格を見誤ったとき。Get-CodexInstallRoute が先に止める)
function Get-WingetFailureHint {
    param([int]$ExitCode)
    if ($ExitCode -eq -1978335107) {
        return '昇格した会話から user スコープの portable を入れる・外すのを winget が断った (0x8A15007D)。昇格していない PowerShell で Install-Codex を打ち直す'
    }
    $null
}

# ---------------------------------------------------------------------------
# Windows に触る関数 (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# winget を打ち、出力の行 (進み具合の表示は除く) と終了コードを返す。winget は管へ UTF-8 で書くので、コンソールの文字コードが UTF-8 でなければ
# 打つ間だけ UTF-8 にする (日本語の Windows の既定は CP932。手で打った窓・UAC で昇格し直した子の窓。そのまま読むと進み具合の帯と日本語の
# メッセージが化ける。runner と WSL の wrapper は UTF-8 にしてから流すので替えない)。本文は Install-OpenSSH.ps1 の Invoke-Winget と同じ
# (Install-OpenSSH.Tests.ps1 が突き合わせる)
function Invoke-Winget {
    param([string[]]$Arguments)
    # 5.1 では Stop のままだと、外部コマンドの stderr の 1 行目で止まる
    $ErrorActionPreference = 'Continue'
    $saved = $null
    try {
        if ([Console]::OutputEncoding.CodePage -ne 65001) {
            $current = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
            $saved = $current
        }
    } catch {
        $saved = $null
    }
    try {
        $lines = & winget @Arguments 2>&1 | ForEach-Object { "$_" } |
            Where-Object { $_ -notmatch '^\s*[-\\|/]?\s*$' -and $_ -notmatch '[\u2588\u2592]' }
        $code = $LASTEXITCODE
    } finally {
        if ($null -ne $saved) {
            try { [Console]::OutputEncoding = $saved } catch { }
        }
    }
    [pscustomobject]@{ ExitCode = $code; Lines = @($lines) }
}

# 置き場所の codex の exe を探す。この PC の CPU の名前 (x64 は codex-x86_64-pc-windows-msvc.exe、arm64 は codex-aarch64-pc-windows-msvc.exe)
# を先に見て、無ければもう一方。どちらも無ければ $null
function Find-CodexExe {
    param([string]$PackageDir)
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $names = if ($arch -eq 'ARM64') { @('codex-aarch64-pc-windows-msvc.exe', 'codex-x86_64-pc-windows-msvc.exe') } else { @('codex-x86_64-pc-windows-msvc.exe', 'codex-aarch64-pc-windows-msvc.exe') }
    foreach ($name in $names) {
        $p = Join-Path $PackageDir $name
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $null
}

# codex に版を聞く。読めなければ $null
function Get-CodexInstalledVersion {
    param([string]$Exe)
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe --version 2>&1 | ForEach-Object { "$_" })
    } catch {
        # 起動できない (壊れた・0 バイト・方針で止められた) ときも、版が読めないとして入れ替えの対象にする
        return $null
    }
    Get-CodexVersionFromOutput -Lines $out
}

# WinGet\Links\codex.exe を読む (有るか・種類・指す先)。Target は 5.1 では配列、7 では文字列なので、1 つ目を取る
function Get-CodexLink {
    param([string]$LinksDir)
    $path = Join-Path $LinksDir 'codex.exe'
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return [pscustomobject]@{ Exists = $false; LinkType = ''; Target = '' } }
    $target = @($item.Target | Where-Object { $_ }) | Select-Object -First 1
    [pscustomobject]@{ Exists = $true; LinkType = "$($item.LinkType)"; Target = "$target" }
}

# 置き場所の codex.exe (winget 1.30 が置く hardlink) が、置き場所の exe の hardlink かを読む
function Get-CodexHardlink {
    param([string]$PackageDir, [string]$ExePath)
    $item = Get-Item -LiteralPath (Join-Path $PackageDir 'codex.exe') -Force -ErrorAction SilentlyContinue
    if (-not $item) { return 'missing' }
    # LinkType は hardlink なら HardLink、symlink なら SymbolicLink。reparse point (symlink・junction) かは Attributes で見る
    $reparse = if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'ReparsePoint' } else { '' }
    $exeLength = -1
    if ($ExePath) {
        $exeItem = Get-Item -LiteralPath $ExePath -Force -ErrorAction SilentlyContinue
        if ($exeItem) { $exeLength = $exeItem.Length }
    }
    Get-CodexHardlinkState -Exists $true -LinkType $reparse -Length $item.Length -ExeLength $exeLength
}

# 開発者モード (設定 > システム > 開発者向け) が on か。on なら、昇格していない winget も symlink を作れる
function Test-DeveloperMode {
    $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
    [bool]($key -and ($key.AllowDevelopmentWithoutDevLicense -eq 1))
}

# 今の PowerShell が UAC で昇格した token (TokenElevationTypeFull) で動いているか。winget 1.30 が user スコープの portable を断るのと同じ見方
# (winget の Runtime::IsRunningWithNonDefaultFullToken)。UAC の分かれていない管理者 (Administrator・UAC が off) は Default なので当たらない。
# token を読めなければ、管理者のロールで代える
function Test-Elevated {
    try {
        if (-not ('DotfilesCodex.TokenInfo' -as [type])) {
            Add-Type -Namespace DotfilesCodex -Name TokenInfo -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool GetTokenInformation(IntPtr token, int infoClass, out int info, int length, out int returnLength);
'@
        }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $type = 0
        $returned = 0
        # 18 は TokenElevationType。1 = Default、2 = Full (UAC で昇格した)、3 = Limited
        if ([DotfilesCodex.TokenInfo]::GetTokenInformation($identity.Token, 18, [ref]$type, 4, [ref]$returned)) { return ($type -eq 2) }
    } catch {
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# これから開く PowerShell が使う PATH (マシン → ユーザーの順)。今のプロセスの PATH は古いことがある
function Get-CodexPathValue {
    @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}

# PATH で引かれる codex と、同梱の rg の状態を読む
function Get-CodexPathState {
    param([string]$PackageDir, [string]$LinksDir)
    $pathValue = Get-CodexPathValue
    $resolved = Resolve-CodexOnPath -PathValue $pathValue -Names @('codex.exe', 'codex.cmd', 'codex.bat', 'codex.ps1') -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    $kind = Get-CodexPathKind -Resolved $resolved -LinksDir $LinksDir -PackageDir $PackageDir
    $rgDir = Join-Path $PackageDir 'codex-path'
    $bundled = Test-Path -LiteralPath (Join-Path $rgDir 'rg.exe') -PathType Leaf
    [pscustomobject]@{
        Resolved = $resolved
        Kind     = $kind
        RgDir    = $rgDir
        RgState  = Get-CodexRgState -PathKind $kind -BundledRg $bundled -PathValue $pathValue -RgDir $rgDir
    }
}

# $Dir をユーザーの PATH の末尾に足す (無いときだけ)。値の型 (REG_EXPAND_SZ など) を保ち、user 変数を書いて消して、動いているプログラムに
# 環境変数が変わったことを知らせる (Install-HerdrApp.ps1 と同じ)。今のプロセスの PATH にも足す
function Add-CodexUserPath {
    param([string]$Dir)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $has = $key.GetValueNames() -contains 'Path'
        $raw = if ($has) { [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { '' }
        if (-not (Test-CodexPathListed -Raw $raw -Dir $Dir)) {
            $kind = if ($has) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            $key.SetValue('Path', (Get-CodexPathValueWithEntry -Raw $raw -Dir $Dir), $kind)
            Write-Host "ユーザーの PATH に $Dir を足した (codex が同梱の rg を引く。新しく開くシェルから効く)"
        }
    } finally {
        $key.Close()
    }
    [Environment]::SetEnvironmentVariable('DOTFILES_CODEX_PATH_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('DOTFILES_CODEX_PATH_REFRESH', $null, 'User')
    if (-not (Test-CodexPathListed -Raw $env:Path -Dir $Dir)) { $env:Path = Get-CodexPathValueWithEntry -Raw $env:Path -Dir $Dir }
}

# 置き場所の下の exe (codex・同梱の helper) か、WinGet\Links\codex.exe から起動して動いているプロセス
function Get-CodexBusyProcess {
    param([string]$PackageDir, [string]$LinksDir)
    $prefix = $PackageDir.TrimEnd('\') + '\'
    $link = Join-Path $LinksDir 'codex.exe'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            $path -and ($path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or $path.Equals($link, [StringComparison]::OrdinalIgnoreCase))
        })
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-CodexState {
    param([string]$PackageId, [string]$PackageDir, [string]$LinksDir, [string]$Target)
    $exe = Find-CodexExe -PackageDir $PackageDir
    $exists = [bool]$exe
    $installed = $null
    if ($exists) { $installed = Get-CodexInstalledVersion -Exe $exe }
    $link = Get-CodexLink -LinksDir $LinksDir
    $linkState = Get-CodexLinkState -Exists $link.Exists -LinkType $link.LinkType -Target $link.Target -ExePath $exe
    $hardlinkState = Get-CodexHardlink -PackageDir $PackageDir -ExePath $exe
    $aliasState = Get-CodexAliasState -LinkState $linkState -HardlinkState $hardlinkState
    $wingetVersion = Get-WingetClientVersion -Lines (Invoke-Winget -Arguments @('--version')).Lines
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $PackageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    $show = Invoke-Winget -Arguments @('show', '--id', $PackageId, '--exact', '--versions', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    # @() で包む。関数が返す空の配列は呼び出し側で $null にほどける (Install-OpenSSH.ps1 で踏んだ)
    $versions = @(Get-WingetVersionList -Lines $show.Lines)
    $latest = $null
    if ($versions.Count -gt 0) { $latest = $versions[0] }
    $path = Get-CodexPathState -PackageDir $PackageDir -LinksDir $LinksDir
    [pscustomobject]@{
        Exists        = $exists
        Installed     = $installed
        ExeName       = $(if ($exe) { Split-Path -Leaf $exe } else { $null })
        Plan          = Get-CodexPlan -Exists $exists -Installed $installed -Target $Target -AliasState $aliasState
        Direction     = Get-CodexDirection -Versions $versions -Installed $installed -Target $Target
        Pinned        = Test-WingetPinned -Lines $pins.Lines -PackageId $PackageId
        Versions      = $versions
        Latest        = $latest
        LinkState     = $linkState
        LinkTarget    = $link.Target
        HardlinkState = $hardlinkState
        AliasState    = $aliasState
        PathResolved  = $path.Resolved
        PathKind      = $path.Kind
        RgState       = $path.RgState
        WingetVersion = $wingetVersion
        Route         = Get-CodexInstallRoute -Elevated (Test-Elevated) -DeveloperMode (Test-DeveloperMode) -WingetVersion $wingetVersion
        BusyCount     = @(Get-CodexBusyProcess -PackageDir $PackageDir -LinksDir $LinksDir).Count
    }
}

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-CodexState {
    param($State, [string]$Target, [string]$PackageId, [string]$PackageDir)
    foreach ($row in (Format-CodexState -State $State -Target $Target -PackageId $PackageId -PackageDir $PackageDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 締めの行 (直すこと) を黄色で出す。揃っていれば何も出さない
function Write-CodexVerdict {
    param($State)
    foreach ($line in (Format-CodexVerdict -State $State)) {
        Write-Host $line -ForegroundColor Yellow
    }
}

function Invoke-InstallCodex {
    param([string]$Version, [switch]$Check, [switch]$IfMissing)
    $packageId = 'OpenAI.Codex'
    # portable の置き場所は <Id>_<ソースの識別子>。winget のソースから入れると、どのマシンでも同じ名前になる
    $packageDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenAI.Codex_Microsoft.Winget.Source_8wekyb3d8bbwe'
    $linksDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'winget が見つからない。Microsoft Store の「アプリ インストーラー」を入れる'
        return 2
    }

    $state = Get-CodexState -PackageId $packageId -PackageDir $packageDir -LinksDir $linksDir -Target $Version
    Write-CodexState -State $state -Target $Version -PackageId $packageId -PackageDir $packageDir
    $code = Get-CodexExitCode -State $state

    # -Check は何も変えない。-IfMissing は入っていないときだけ入れ、入っていれば -Check と同じ
    if ($Check -or ($IfMissing -and ($state.Plan -ne 'install'))) {
        if ($code -eq 0) { Write-Host '揃っている' }
        Write-CodexVerdict -State $state
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }
    # 揃える手順で直す差 (版・pin・codex と打てる形・同梱の rg の PATH) が無く、残っているのは PATH のずれだけ
    if (-not (Test-CodexDrift -State $state)) {
        Write-Host '版と pin と codex と打てる形は揃っている。PATH のずれは Install-Codex では直らない (上の ※ の行の手順で直す)'
        Write-CodexVerdict -State $state
        return 1
    }

    $blocker = Get-CodexApplyBlocker -Plan $state.Plan -Versions $state.Versions -Target $Version -BusyCount $state.BusyCount -Route $state.Route
    if ($blocker -eq 'elevated') {
        Write-Host '昇格した PowerShell では winget が codex を入れないので、何も変えずに止める。昇格していない PowerShell で Install-Codex を打ち直す'
        Write-CodexVerdict -State $state
        return 1
    }
    if ($blocker -eq 'old-winget') {
        Write-Host '入れても codex と打てないので、入れずに止める。上の ※ の行の手順で winget を更新するか開発者モードを on にしてから打ち直す'
        Write-CodexVerdict -State $state
        return 1
    }
    if ($blocker -eq 'not-listed') {
        Write-Host "固定した版 $Version が winget に無いので入れられない。-Version を winget show --id $packageId --versions にある版へ変える"
        return 1
    }
    if ($blocker -eq 'busy') {
        Write-Host 'codex が動いていて置き換えられない。動いている codex を終わらせてから打ち直す:'
        foreach ($p in @(Get-CodexBusyProcess -PackageDir $packageDir -LinksDir $linksDir)) {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
            Write-Host "  $($p.Id)  $commandLine"
        }
        return 1
    }

    # 入れ替え・入れ直しは外してから入れるので、取得が落ちると codex が消えたまま終わる。
    # 外す前に、固定した版を取得してハッシュまで確かめる (落ちたら何も変えずに止める)
    if ($state.Plan -in @('change', 'relink')) {
        $downloadDir = Join-Path ([IO.Path]::GetTempPath()) "install-codex-$PID"
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
    if (($state.Plan -in @('change', 'relink')) -and $state.Pinned) {
        $unpin = Invoke-Winget -Arguments @('pin', 'remove', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($unpin.ExitCode -ne 0) { Write-Host ('winget pin remove が失敗した (終了コード 0x{0:X8})' -f $unpin.ExitCode) }
    }
    foreach ($arguments in @(Get-WingetCommands -Plan $state.Plan -PackageId $packageId -Version $Version)) {
        Write-Host "winget $($arguments -join ' ')"
        $result = Invoke-Winget -Arguments $arguments
        $result.Lines | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
        if ($result.ExitCode -ne 0) {
            Write-Host ('winget が失敗した (終了コード 0x{0:X8})' -f $result.ExitCode)
            $hint = Get-WingetFailureHint -ExitCode $result.ExitCode
            if ($hint) { Write-Host $hint }
            if ($arguments[0] -eq 'install') {
                Write-Host 'install が落ちたので、codex が入っていないことがある。ネットワークを確かめて Install-Codex を打ち直す (dotfiles apply でも入る)'
            }
            break
        }
    }
    # 入っていれば pin を足す (入れ替えた後は、上で外したので足し直しになる)
    $pins = Invoke-Winget -Arguments @('pin', 'list', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
    if ((Find-CodexExe -PackageDir $packageDir) -and -not (Test-WingetPinned -Lines $pins.Lines -PackageId $packageId)) {
        $pin = Invoke-Winget -Arguments @('pin', 'add', '--id', $packageId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        if ($pin.ExitCode -eq 0) { Write-Host 'winget pin を足した (winget upgrade --all から外れる)' }
        else { Write-Host ('winget pin add が失敗した (終了コード 0x{0:X8})' -f $pin.ExitCode) }
    }
    # hardlink の形で PATH の codex が置き場所の codex.exe なら、同梱の rg (置き場所の codex-path) をユーザーの PATH に足す (入れた後の
    # PATH で決める。winget が置き場所を PATH に足すのは、入れたとき)
    $pathNow = Get-CodexPathState -PackageDir $packageDir -LinksDir $linksDir
    if ($pathNow.RgState -eq 'missing') { Add-CodexUserPath -Dir $pathNow.RgDir }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-CodexState -PackageId $packageId -PackageDir $packageDir -LinksDir $linksDir -Target $Version
    Write-CodexState -State $after -Target $Version -PackageId $packageId -PackageDir $packageDir
    if ((Get-CodexExitCode -State $after) -eq 0) {
        Write-Host '揃った (新しい PowerShell から codex と打てる)'
        return 0
    }
    # 版と pin と codex と打てる形は揃い、残っているのは PATH のずれだけ
    if (-not (Test-CodexDrift -State $after)) { Write-Host '版と pin と codex と打てる形は揃った' }
    Write-CodexVerdict -State $after
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の winget の 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallCodex -Version $Version -Check:$Check -IfMissing:$IfMissing)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
