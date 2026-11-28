<#
.SYNOPSIS
Windows の fzf (行を絞り込んで選ぶ CLI。winget の junegunn.fzf の portable) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/fzf/Install-Fzf.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Fzf から呼ぶ (win/README.md の「ghq・fzf」)。
dotfiles.ps1 の cdrepo (ghq の repo を fzf で選んで移る) が使う。入れて揃えるのは Windows の runner の手順 fzf (win/runner/src/steps/ps1.rs。
dotfiles apply)。

中身は winget の portable の道具の共通の枠 (win/winget/WingetPortable.ps1。win/README.md の「winget の portable の道具」) で、ここは fzf の表だけを
持つ。常駐も UAC も無いので、版のずれも揃える。

winget の junegunn.fzf は 0.75.0 から、zip の中の portable と、machine スコープの MSI (%ProgramFiles%\fzf\bin。UAC が要る)
の 2 つの installer を並べ、winget の既定は MSI を選ぶ。dotfiles は portable (管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の
下に入る。fzf.exe は置き場所の直下) を、--installer-type portable で名指しして入れる。MSI の fzf が入っているマシンでは、portable と
二重になり winget の install・pin がどちらを指すか決まらないので、何も入れずに外し方を出す (外すのは人。表の Msi)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id junegunn.fzf --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3
(MSI の fzf が入っている・昇格した PowerShell で winget を打てないときは、portable が入っていなくても 1)。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.75.0',
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
$packageId = 'junegunn.fzf'

# fzf の表 (key は WingetPortable.ps1 の頭の「道具の表」)
function Get-FzfTool {
    @{
        Name           = 'fzf'
        Command        = 'Install-Fzf'
        PackageId      = $packageId
        CommandName    = 'fzf'
        Readme         = 'ghq・fzf'
        # fzf.exe --version の出力 ("<版> (<commit>)")
        VersionPattern = '^\s*v?(?<v>\d+(\.\d+)+)(\s|$)'
        # manifest の RelativeFilePath (置き場所の直下)。zip の中の形が変わっても読めるよう、無ければ置き場所の下を探す
        ExePath        = 'fzf.exe'
        ExeSearch      = $true
        # MSI の fzf (manifest の DefaultInstallLocation の %ProgramFiles%\fzf\bin)
        Msi            = 'fzf\bin\fzf.exe'
        BusyFix        = '動いている fzf (cdrepo の選ぶ画面など) を終わらせる'
    }
}

# dot-source されたとき (試験) は関数だけを読み、本体は走らせない
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    exit (Start-WingetPortable -Tool (Get-FzfTool) -Version $Version -Check:$Check -IfMissing:$IfMissing)
}
