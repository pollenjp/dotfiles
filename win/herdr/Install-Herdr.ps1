<#
.SYNOPSIS
Windows の herdr (winget の Herdr.Herdr) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/herdr/Install-Herdr.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Herdr から呼ぶ (win/README.md の「herdr を入れる」)。

中身は winget の portable の道具の共通の枠 (win/winget/WingetPortable.ps1。win/README.md の「winget の portable の道具」) で、ここは herdr の表と、
前の Herdr.Herdr.Preview を見る custom の関数を持つ。PATH で引かれる herdr は、置き場所 (開発者モードが off) と WinGet\Links の symlink
(開発者モードが on) のどちらも winget のものとして読む。

herdr は portable (zip) のパッケージで、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の
下に入る。herdr server が動いている間は herdr.exe を置き換えられないので、入れ替えが要るときに
herdr が動いていれば、何も変えずに止める。server は止めない (herdr の pane の中で打つと自分ごと消える)。

herdr update (herdr 自身の更新) は %USERPROFILE%\.herdr に別に入れてユーザーの PATH の先頭に足し、
winget の管理から外れる。そこで PATH で先に引かれる herdr が winget のものかも確かめる (揃える手順では直らないので、※ の手順で直す)。

前は preview のパッケージ Herdr.Herdr.Preview で入れていた (winget に安定版が無かった)。置き場所が別なので、
Preview が残っていても Herdr.Herdr を並べて入れる。Preview の置き場所に herdr.exe が残っていれば、差として
知らせて外す手順を添える。Preview は外さない (動いている herdr server を止めることになり、pane が消える
ので、時期は人が選ぶ)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Herdr.Herdr --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1
(Herdr.Herdr.Preview が残っているとき・昇格した PowerShell で winget を打てないときも)、入っていなければ 3。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない (setup --update が使う)。
入れた後も Herdr.Herdr.Preview が残っていれば 1 を返す (締めの行が Preview のことだけなら、Herdr.Herdr は揃っている。
bootstrap-windows-herdr.sh はそれを締めの行で読み分ける)。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.9.5',
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
$packageId = 'Herdr.Herdr'
# 前に入れていた preview のパッケージ。置き場所が別なので並べて入れられる。残っていれば外す手順を出す (外さない)。
# 置き場所の名前は、winget が ARP に書く product code と同じ
$previewId = 'Herdr.Herdr.Preview'
$previewProductCode = 'Herdr.Herdr.Preview_Microsoft.Winget.Source_8wekyb3d8bbwe'

# herdr の表 (key は WingetPortable.ps1 の頭の「道具の表」)
function Get-HerdrTool {
    @{
        Name           = 'herdr'
        Command        = 'Install-Herdr'
        PackageId      = $packageId
        CommandName    = 'herdr'
        Readme         = 'herdr を入れる'
        # herdr.exe --version の出力 ("herdr <版>")。版は文字列のまま比べる (後ろに印の付いた版も)
        VersionPattern = '^\s*herdr\s+(?<v>\S+)\s*$'
        # herdr.exe は置き場所の直下 (manifest の RelativeFilePath)
        ExePath        = 'herdr.exe'
        # 置き場所から起動して動いているプロセス (herdr server・herdr --remote・conpty の OpenConsole.exe)
        BusyName       = 'herdr の exe (herdr.exe・OpenConsole.exe)'
        BusyFix        = 'herdr の外の PowerShell で hsvstop を打ち、herdr --remote の窓も閉じる'
        PathOtherFix   = '{0} をユーザーの PATH から外す (herdr update で入ったもの。外し方は win/README.md の「herdr を入れる」)'
        PathTexts      = @{ preview = "{0} ($previewId のもの)" }
        Synced         = $packageId
        Retry          = 'dotfiles apply・setup --update'
        Hooks          = @{
            ReadState     = 'Read-HerdrState'
            PathKind      = 'Get-HerdrPathKind'
            Manual        = 'Test-HerdrPreviewLeft'
            Blocker       = 'Get-HerdrPreviewBlocker'
            RowsAfterPath = 'Format-HerdrPreviewRow'
            Notes         = 'Format-HerdrPreviewNotes'
            Verdict       = 'Format-HerdrPreviewVerdict'
        }
    }
}

# ---------------------------------------------------------------------------
# custom の関数: 前の Herdr.Herdr.Preview (Install-Herdr.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# Herdr.Herdr.Preview の置き場所 (Herdr.Herdr の置き場所と並ぶ)。\ で組む (Linux の pwsh で流す試験でも同じ文字列になるよう、Join-Path は使わない)
function Get-HerdrPreviewDir {
    param($Tool)
    $dir = $Tool.PackageDir.TrimEnd('\')
    "$($dir.Substring(0, $dir.LastIndexOf('\')))\$previewProductCode"
}

# ③ PATH で引かれる herdr が Herdr.Herdr.Preview の置き場所のものなら preview (表の PathTexts の字で出す)
function Get-HerdrPathKind {
    param($Tool, [string]$Resolved)
    if (-not $Resolved) { return $null }
    $cut = $Resolved.LastIndexOf('\')
    if ($cut -lt 0) { return $null }
    # -eq は大文字小文字を区別しない (Windows のパスと同じ)
    if ($Resolved.Substring(0, $cut) -eq (Get-HerdrPreviewDir -Tool $Tool)) { return 'preview' }
    $null
}

# ③ 状態に足す値: Herdr.Herdr.Preview は、置き場所に herdr.exe があれば残っているとみなす (winget list より速く、ネットワークも要らない)
function Read-HerdrState {
    param($Tool, $State)
    @{ PreviewExists = Test-Path -LiteralPath "$(Get-HerdrPreviewDir -Tool $Tool)\herdr.exe" -PathType Leaf }
}

# ④ 揃える手順では直らない差: Preview が残っている (外すのは人。PATH で Preview の herdr が先に引かれるのも、Preview を外せば直る)
function Test-HerdrPreviewLeft {
    param($Tool, $State)
    [bool]$State.PreviewExists
}

# Herdr.Herdr.Preview を外す手順の 1〜3 (4 は呼ぶ側で足す)。Preview は product code (ARP の UninstallString と
# 同じ) で外す。Herdr.Herdr を並べて入れると、winget は Preview を Herdr.Herdr として数え、
# --id Herdr.Herdr.Preview --exact では見つからなくなる (2026-11-09、winget v1.29.380 で確かめた)。pin は Preview を
# 外した後に外す (先に打つと、Herdr.Herdr に結ばれた Preview の行に当たりうる)
function Format-HerdrPreviewSteps {
    '1. herdr の外の PowerShell (Windows Terminal など) で hsvstop を打ち、herdr --remote の窓も閉じる'
    "2. winget uninstall --product-code $previewProductCode を打つ"
    "3. winget pin remove --id $previewId --exact を打つ (Preview の pin を外す)"
}

# ④ 止める理由: 入れ替えるのに Preview が残っている。winget は並べて入れた Preview を Herdr.Herdr として数えるので、
# winget uninstall --id Herdr.Herdr がどちらに当たるかが定まらない。先に Preview を外させる (どちらも hsvstop が要るので手間は増えない)。
# 入れる・pin を足すだけなら止めない
function Get-HerdrPreviewBlocker {
    param($Tool, $State)
    if (($State.Plan -notin @('change', 'relink')) -or (-not $State.PreviewExists)) { return }
    "$previewId が残っているので入れ替えない (winget が Preview を $($Tool.PackageId) として数え、どちらを外すかが定まらない)。先に $previewId を外してから打ち直す:"
    foreach ($step in (Format-HerdrPreviewSteps)) { "  $step" }
    "  4. 新しい PowerShell で $($Tool.Command) を打ち直す"
}

# ⑥ PATH の行の後に足す行: 前に入れていた preview のパッケージ。残っていなければ行を出さない (移り終えた PC で毎回出さない)。
# Herdr.Herdr が入る前に外すと herdr が無くなるので、入っていなければ「入れてから外す」にする
function Format-HerdrPreviewRow {
    param($Tool, $State)
    if (-not $State.PreviewExists) { return }
    $when = if ($State.Plan -eq 'install') { "$($Tool.PackageId) を入れてから外す" } else { '外す' }
    @{ Label = '前の Preview'; Value = "$previewId が残っている → $when"; Warn = $true }
}

# ⑥ 表の終わりに足す行: PATH で Preview の herdr が先に引かれる (入れる前は当たり前なので出さない)
function Format-HerdrPreviewNotes {
    param($Tool, $State)
    if (($State.PathKind -eq 'preview') -and ($State.Plan -ne 'install')) {
        @{ Text = "※ PATH で先に引かれる herdr は $previewId のもの。Preview を外せば直る (外すと置き場所が消え、ユーザーの PATH に残る行は飛ばされる)"; Warn = $false }
    }
}

# ⑥ 締めの行に足す行: Preview を外す手順。bootstrap-windows-herdr.sh と runner は「<Preview の ID> が残っている」の字で読む
# (字を変えるときは向こうも直す)。Preview を外すのは Herdr.Herdr が入った後 (入っていなければ「入れてから」と添える)
function Format-HerdrPreviewVerdict {
    param($Tool, $State)
    if (-not $State.PreviewExists) { return }
    $first = if ($State.Plan -eq 'install') { "$($Tool.PackageId) を入れてから、" } else { '' }
    "⚠️ $previewId が残っている → ${first}次の手順で外す ($($Tool.Command) は外さない) ⚠️"
    foreach ($step in (Format-HerdrPreviewSteps)) { "⚠️   $step" }
    '⚠️   4. 新しい PowerShell から herdr を起動し直す'
}

# dot-source されたとき (試験) は関数だけを読み、本体は走らせない
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    exit (Start-WingetPortable -Tool (Get-HerdrTool) -Version $Version -Check:$Check -IfMissing:$IfMissing)
}
