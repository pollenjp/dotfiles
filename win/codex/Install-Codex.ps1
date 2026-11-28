<#
.SYNOPSIS
Windows の Codex CLI (OpenAI のコーディング エージェントの CLI。winget の OpenAI.Codex の portable) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/codex/Install-Codex.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Codex から呼ぶ (win/README.md の「Codex CLI」)。
入れて揃えるのは Windows の runner の手順 codex (ホストの値の [tools] windowsCodex が on のマシンだけ。既定はグループで決まり、all で on)。

中身は winget の portable の道具の共通の枠 (win/winget/WingetPortable.ps1。win/README.md の「winget の portable の道具」) で、ここは Codex CLI の
表と、codex と打てる形・同梱の rg・化けた codex-path の行・古い winget を見る custom の関数を持つ。常駐が無いので、版のずれも揃える。

winget の OpenAI.Codex は zip の中の portable で、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の下に入る。置き場所の exe の
名前は codex-x86_64-pc-windows-msvc.exe (arm64 は codex-aarch64-pc-windows-msvc.exe) で、codex という名前 (manifest の PortableCommandAlias) は、
winget が次のどちらかの形で付ける (winget の PortableFlow.cpp・PortableInstaller.cpp):
  - symlink の形: %LOCALAPPDATA%\Microsoft\WinGet\Links\codex.exe (置き場所の exe への symlink)。winget が symlink を作れるとき (開発者モードが on か、
    昇格した winget)
  - hardlink の形: 置き場所の codex.exe (置き場所の exe の hardlink) と、置き場所をユーザーの PATH に足した行。winget 1.30 から。winget が symlink を
    作れないとき (昇格していない winget で、開発者モードが off) は、Links の代わりに置き場所を PATH に足し、その codex.exe が引かれる
winget 1.29 までは hardlink を作らず、symlink を作れないと置き場所を PATH に足すだけなので、codex と打っても見つからない。

winget は UAC で昇格して打たない (そのまま打つ)。昇格した会話で winget が 1.30 以降なら、共通の枠の見張りが winget を打たずに止める。
昇格していない会話で、開発者モードが off で、winget が 1.29 以前なら、入れても codex と打てないので、この表の見張り (Get-CodexHold) が
winget を打たずに止め、Install-WinGet (runner の手順 winget。codex より先に流れる) で winget を上げるか、開発者モードを on にする手を出す
(runner は知らせるだけ)。codex と打てる形が無い形で入っていれば (1.29 以前の winget で入れたなど)、同じ版を入れ直して作らせる (relink)。

codex は自分の置き場所の判定 (同梱の codex-path\rg.exe と codex-resources を使うか) を、実体の exe の名前が置き場所の codex-package.json の
entrypoint と同じかで行う (codex の codex-rs/install-context)。symlink は実体へたどるので当たるが、hardlink の codex.exe は名前が違うので外れ、
codex は rg を PATH から探す。そこで PATH で引かれる codex が置き場所の codex.exe (hardlink の形) なら、置き場所の codex-path (同梱の rg.exe が
ある) をユーザーの PATH に足す。sandbox の helper (codex-command-runner.exe など) と codex-code-mode-host.exe は exe の隣で探すので、どちらの形でも
見つかる。名前を替えた写しや .cmd の shim は作らない。

winget uninstall は、置き場所を PATH の文字列から部分一致で抜く。Install-Codex が足した codex-path の行 (置き場所\codex-path) は、置き場所の
部分だけが抜かれて \codex-path (C:\ の直下。普通のユーザーもフォルダを作れる) に化けて残る。そこで外す・入れ直す前に自分の codex-path の行を
ユーザーの PATH から抜き (入れた後に足し直す)、化けた行 (\codex-path) が残っていれば -Check で知らせて取り除く。

winget の manifest の依存 (BurntSushi.ripgrep.MSVC と Microsoft.VCRedist.2015+) は入れない (--skip-dependencies)。codex の exe は
VC++ のランタイムを使わず (CRT を静的に持つ)、rg.exe は zip の中 (codex-path\rg.exe) にある。VCRedist は machine に入るので、入れると UAC の確認が出る。

codex.exe が動いている間は置き換えられないので、入れ替えが要るときに置き場所の exe が動いていれば、何も変えずに止める (止めはしない)。

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

# 共通の枠。配った写し (%USERPROFILE%\.config\powershell) なら隣に、clone なら win\winget\ にある
$frame = @((Join-Path $PSScriptRoot 'WingetPortable.ps1'), (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'winget') 'WingetPortable.ps1')) |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $frame) {
    $missing = "winget の portable の道具の共通の枠 (WingetPortable.ps1) が $PSScriptRoot に無い。dotfiles apply (受け持ちが WSL のホストは WSL の setup --update) で配り直す"
    if ($MyInvocation.InvocationName -eq '.') { throw $missing }
    Write-Host $missing -ForegroundColor Red
    exit 2
}
. $frame

# winget のパッケージ ID (版の知らせ (runner の pin-updates・WSL の check-winget-version.sh) がこの行を読む)
$packageId = 'OpenAI.Codex'

# Codex CLI の表 (key は WingetPortable.ps1 の頭の「道具の表」)。置き場所の exe は、この PC の CPU の名前 (x64 は codex-x86_64-pc-windows-msvc.exe、
# arm64 は codex-aarch64-pc-windows-msvc.exe) を先に見て、無ければもう一方。winget 1.30 が置く hardlink の codex.exe は、置き場所の exe としては拾わない
function Get-CodexTool {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $exes = if ($arch -eq 'ARM64') { @('codex-aarch64-pc-windows-msvc.exe', 'codex-x86_64-pc-windows-msvc.exe') } else { @('codex-x86_64-pc-windows-msvc.exe', 'codex-aarch64-pc-windows-msvc.exe') }
    @{
        Name             = 'Codex CLI'
        Command          = 'Install-Codex'
        PackageId        = $packageId
        CommandName      = 'codex'
        Readme           = 'Codex CLI'
        # codex --version の出力 ("codex-cli <版>")
        VersionPattern   = '^\s*(codex(-cli)?\s+)?v?(?<v>\d+(\.\d+)+)(\s|$)'
        ExePath          = $exes
        VersionLabel     = 'codex --version'
        # user スコープで入れ、manifest の依存 (ripgrep・VCRedist) は入れない (頭の説明)
        InstallArguments = @('--scope', 'user', '--skip-dependencies')
        BusyName         = 'codex'
        BusyFix          = '動いている codex (ほかの端末の会話など) を終わらせる'
        PathTexts        = @{ links = 'winget の symlink (WinGet\Links\codex.exe)'; package = 'winget の hardlink (置き場所の codex.exe)' }
        PathOtherFix     = '{0} の codex を外す (npm の @openai/codex なら npm uninstall -g @openai/codex) か、{0} をユーザーの PATH から外す (win/README.md の「Codex CLI」)'
        PathNoneFix      = 'PATH で codex が見つからない。symlink の形なら %LOCALAPPDATA%\Microsoft\WinGet\Links を、hardlink の形なら置き場所 ({0}) をユーザーの PATH に足し、新しい PowerShell を開く'
        Synced           = '版と pin と codex と打てる形'
        Hooks            = @{
            ReadState      = 'Read-CodexState'
            Reinstall      = 'Test-CodexReinstall'
            Holds          = 'Get-CodexHold'
            Drift          = 'Test-CodexDrift'
            BeforeWinget   = 'Invoke-CodexBeforeWinget'
            AfterWinget    = 'Invoke-CodexAfterWinget'
            RowsBeforePath = 'Format-CodexAliasRow'
            RowsAfterPath  = 'Format-CodexRgRows'
            Verdict        = 'Format-CodexVerdictLines'
        }
    }
}

# ---------------------------------------------------------------------------
# custom の関数のうち、副作用の無いもの (Install-Codex.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

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

# PATH の 1 つの要素が、winget uninstall が置き場所の部分だけを抜いて化けた codex-path の行 (\codex-path) か。置き場所\codex-path の
# 行から winget が置き場所を部分一致で抜くと残る。ドライブの直下を指すので、PATH に残さない
function Test-CodexMangledPathEntry {
    param([string]$Entry)
    $value = $Entry.Trim().Trim('"').TrimEnd('\')
    $value -ieq '\codex-path'
}

# PATH の値 (; 区切り) にある、化けた codex-path の行の数
function Get-CodexMangledPathCount {
    param([string]$Raw)
    @(($Raw -split ';') | Where-Object { Test-CodexMangledPathEntry -Entry $_ }).Count
}

# $Dirs を指す要素と、化けた codex-path の行を外した PATH の生の値。ほかの要素 (%VAR% の書き方・空の要素・末尾の ;) はそのまま残す
# (Install-HerdrApp.ps1 の Get-PathValueWithoutEntry に、化けた行も足したもの)
function Get-CodexPathValueWithoutEntries {
    param([string]$Raw, [string[]]$Dirs)
    $kept = foreach ($entry in ($Raw -split ';')) {
        $drop = Test-CodexMangledPathEntry -Entry $entry
        foreach ($dir in @($Dirs | Where-Object { $_ })) {
            if (Test-CodexPathEntry -Entry $entry -Dir $dir) { $drop = $true }
        }
        if (-not $drop) { $entry }
    }
    @($kept) -join ';'
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

# ④ 版が揃っていても、codex と打てる形が無い・違えば入れ直す (relink。同じ版を外して入れ、winget に作らせる)
function Test-CodexReinstall {
    param($Tool, $State)
    $State.AliasState -notin @('symlink', 'hardlink')
}

# ② 道具の見張り: 昇格していない会話で、開発者モードが off で、winget が 1.29 以前なら、symlink も hardlink も作れず、入れても codex と打てない。
# 入れる・入れ替える・入れ直すときだけ当たる。昇格した会話の 1.29 以前の winget は symlink を作れるので当たらない (1.30 以降の昇格した会話は、
# 共通の枠の見張りが止める)。winget の版が読めなければ当てない (打ってみる)
function Get-CodexHold {
    param($Tool, $State)
    if ($State.Plan -notin @('install', 'change', 'relink')) { return $null }
    if ($State.Elevated -or $State.DeveloperMode) { return $null }
    if ((Test-WingetModernPortable -WingetVersion $State.WingetVersion) -ne $false) { return $null }
    $wingetText = if ($State.WingetVersion) { "winget $($State.WingetVersion)" } else { 'winget' }
    New-PortableHold -Name 'old-winget' -Rows @(
        @{ Text = "⚠ winget が古く、codex と打てる形を作れない ($wingetText は symlink を作れないときに codex.exe の hardlink を作らず、開発者モードも off)。入れても codex と打てないので、$($Tool.Command) は入れない"; Warn = $true }
        @{ Text = "※ Install-WinGet で winget を固定した版 (1.30 以降) に上げるか、開発者モードを on にして (設定 > システム > 開発者向け。管理者が要る)、$($Tool.Command) を打ち直す (win/README.md の「winget」「Codex CLI」)"; Warn = $false }
    ) -Verdict '⚠️ winget が古く、codex と打てる形を作れない (winget 1.29 以前で、開発者モードも off) → ※ の手順で直す ⚠️' -Message '入れても codex と打てないので、入れずに止める。上の ※ の行の手順で winget を更新するか開発者モードを on にしてから打ち直す'
}

# ④ 揃える手順で直る差: 同梱の rg の置き場所が PATH に無い (hardlink の形)・化けた codex-path の行がユーザーの PATH にある
function Test-CodexDrift {
    param($Tool, $State)
    ($State.RgState -eq 'missing') -or ($State.MangledPath -gt 0)
}

# ⑥ PATH の行の前に足す行: codex と打てる形
function Format-CodexAliasRow {
    param($Tool, $State)
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
    @{ Label = 'codex の別名'; Value = $aliasText; Warn = (($State.Plan -ne 'install') -and ($State.AliasState -notin @('symlink', 'hardlink'))) }
}

# ⑥ PATH の行の後に足す行: 同梱の rg (PATH の codex が winget のものなら) と、化けた codex-path の行
function Format-CodexRgRows {
    param($Tool, $State)
    if ($State.PathKind -eq 'links') {
        @{ Label = '同梱の rg'; Value = 'codex が置き場所の codex-path\rg.exe を自分で使う (symlink の形)'; Warn = $false }
    } elseif ($State.PathKind -eq 'package') {
        $rgText = switch ($State.RgState) {
            'ok' { '置き場所の codex-path が PATH にある (hardlink の形の codex は同梱の rg を自分では見つけないので、PATH で引かせる)' }
            'missing' { '置き場所の codex-path が PATH に無い → ユーザーの PATH に足す (hardlink の形の codex は同梱の rg を自分では見つけない)' }
            default { '置き場所に codex-path\rg.exe が無い (codex は PATH の rg を使う)' }
        }
        @{ Label = '同梱の rg'; Value = $rgText; Warn = ($State.RgState -eq 'missing') }
    }
    if ($State.MangledPath -gt 0) {
        @{ Label = '化けた PATH の行'; Value = "\codex-path が $($State.MangledPath) 行 → 取り除く (winget uninstall が codex-path の行から置き場所の部分だけを抜いた残り。ドライブの直下を指す)"; Warn = $true }
    }
}

# ⑥ 締めの行に足す行 (どれも Install-Codex で揃えること)。runner は「→ Install-Codex で揃える」で揃える。入れるときは足さない
function Format-CodexVerdictLines {
    param($Tool, $State)
    if ($State.Plan -eq 'install') { return }
    if ($State.AliasState -notin @('symlink', 'hardlink')) { '⚠️ codex と打てない (WinGet\Links の symlink も、置き場所の codex.exe の hardlink も無い・違う) → Install-Codex で揃える ⚠️' }
    if ($State.RgState -eq 'missing') { '⚠️ codex が同梱の rg を引けない (置き場所の codex-path が PATH に無い) → Install-Codex で揃える ⚠️' }
    if ($State.MangledPath -gt 0) { '⚠️ ユーザーの PATH に化けた codex-path の行 (\codex-path) が残っている → Install-Codex で揃える ⚠️' }
}

# ---------------------------------------------------------------------------
# custom の関数のうち、Windows に触るもの (実機で -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

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

# ユーザーの PATH の生の値 (%VAR% を展開しない) と値の型。無ければ '' と ExpandString (Install-HerdrApp.ps1 と同じ)
function Get-CodexUserPathRaw {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false)
    if ($null -eq $key) { return [pscustomobject]@{ Raw = ''; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString } }
    try {
        if ($key.GetValueNames() -contains 'Path') {
            return [pscustomobject]@{ Raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = $key.GetValueKind('Path') }
        }
        [pscustomobject]@{ Raw = ''; Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    } finally {
        $key.Close()
    }
}

# ユーザーの PATH を書き直す。値の型 (REG_EXPAND_SZ など) を保ち、user 変数を書いて消して、動いているプログラムに環境変数が変わったことを
# 知らせる (Install-HerdrApp.ps1 と同じ)
function Set-CodexUserPathRaw {
    param([string]$Value, $Kind)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $key.SetValue('Path', $Value, $Kind)
    } finally {
        $key.Close()
    }
    [Environment]::SetEnvironmentVariable('DOTFILES_CODEX_PATH_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('DOTFILES_CODEX_PATH_REFRESH', $null, 'User')
}

# $Dir をユーザーの PATH の末尾に足す (無いときだけ)。今のプロセスの PATH にも足す
function Add-CodexUserPath {
    param([string]$Dir)
    $user = Get-CodexUserPathRaw
    if (-not (Test-CodexPathListed -Raw $user.Raw -Dir $Dir)) {
        Set-CodexUserPathRaw -Value (Get-CodexPathValueWithEntry -Raw $user.Raw -Dir $Dir) -Kind $user.Kind
        Write-Host "ユーザーの PATH に $Dir を足した (codex が同梱の rg を引く。新しく開くシェルから効く)"
    }
    if (-not (Test-CodexPathListed -Raw $env:Path -Dir $Dir)) { $env:Path = Get-CodexPathValueWithEntry -Raw $env:Path -Dir $Dir }
}

# $Dirs を指す行と、化けた codex-path の行 (\codex-path) をユーザーの PATH から外す。今のプロセスの PATH からも外す。外した数を返す
function Remove-CodexUserPath {
    param([string[]]$Dirs)
    $user = Get-CodexUserPathRaw
    $new = Get-CodexPathValueWithoutEntries -Raw $user.Raw -Dirs $Dirs
    $removed = @($user.Raw -split ';').Count - @($new -split ';').Count
    if ($new -cne $user.Raw) {
        Set-CodexUserPathRaw -Value $new -Kind $user.Kind
        Write-Host "ユーザーの PATH から codex-path の行を $removed 行外した (winget uninstall が置き場所の部分だけを抜いて \codex-path に化かさないよう、外す・入れ直す前に外す。化けた行も外す)"
    }
    $env:Path = Get-CodexPathValueWithoutEntries -Raw $env:Path -Dirs $Dirs
    $removed
}

# PATH で引かれる codex と、同梱の rg の状態と、化けた codex-path の行の数を読む (状態を読むときと、入れた後の AfterWinget で使う)
function Get-CodexPathState {
    param($Tool)
    $pathValue = Get-PortablePathValue
    $resolved = Resolve-PortableOnPath -PathValue $pathValue -Names @('codex.exe', 'codex.cmd', 'codex.bat', 'codex.ps1') -Exists { param($p) Test-Path -LiteralPath $p -PathType Leaf }
    $kind = Get-PortablePathKind -Resolved $resolved -ExeDir $Tool.PackageDir -LinksDir $Tool.LinksDir
    $rgDir = Join-Path $Tool.PackageDir 'codex-path'
    $bundled = Test-Path -LiteralPath (Join-Path $rgDir 'rg.exe') -PathType Leaf
    [pscustomobject]@{
        Resolved    = $resolved
        Kind        = $kind
        RgDir       = $rgDir
        RgState     = Get-CodexRgState -PathKind $kind -BundledRg $bundled -PathValue $pathValue -RgDir $rgDir
        MangledPath = Get-CodexMangledPathCount -Raw (Get-CodexUserPathRaw).Raw
    }
}

# ③ 状態に足す値: codex と打てる形 (WinGet\Links の symlink・置き場所の codex.exe の hardlink)・同梱の rg・化けた codex-path の行・開発者モード
function Read-CodexState {
    param($Tool, $State)
    $link = Get-CodexLink -LinksDir $Tool.LinksDir
    $linkState = Get-CodexLinkState -Exists $link.Exists -LinkType $link.LinkType -Target $link.Target -ExePath $State.Exe
    $hardlinkState = Get-CodexHardlink -PackageDir $Tool.PackageDir -ExePath $State.Exe
    $path = Get-CodexPathState -Tool $Tool
    @{
        ExeName       = $(if ($State.Exe) { Split-Path -Leaf $State.Exe } else { $null })
        LinkState     = $linkState
        LinkTarget    = $link.Target
        HardlinkState = $hardlinkState
        AliasState    = Get-CodexAliasState -LinkState $linkState -HardlinkState $hardlinkState
        RgState       = $path.RgState
        MangledPath   = $path.MangledPath
        DeveloperMode = Test-DeveloperMode
    }
}

# ⑤ winget を打つ前: 外す・入れ直す前に、自分が足した codex-path の行をユーザーの PATH から外す (winget uninstall が置き場所の部分だけを抜いて
# \codex-path に化かすため。入れた後に AfterWinget が足し直す)。化けた行 (前に手で winget uninstall を打ったなど) もここで外す
function Invoke-CodexBeforeWinget {
    param($Tool, $State)
    $replacing = $State.Plan -in @('change', 'relink')
    if ($replacing -or ($State.MangledPath -gt 0)) {
        $null = Remove-CodexUserPath -Dirs $(if ($replacing) { @(Join-Path $Tool.PackageDir 'codex-path') } else { @() })
    }
}

# ⑤ winget を打った後: hardlink の形で PATH の codex が置き場所の codex.exe なら、同梱の rg (置き場所の codex-path) をユーザーの PATH に足す
# (入れた後の PATH で決める。winget が置き場所を PATH に足すのは、入れたとき)
function Invoke-CodexAfterWinget {
    param($Tool, $State)
    $pathNow = Get-CodexPathState -Tool $Tool
    if ($pathNow.RgState -eq 'missing') { Add-CodexUserPath -Dir $pathNow.RgDir }
}

# dot-source されたとき (試験) は関数だけを読み、本体は走らせない
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    exit (Start-WingetPortable -Tool (Get-CodexTool) -Version $Version -Check:$Check -IfMissing:$IfMissing)
}
