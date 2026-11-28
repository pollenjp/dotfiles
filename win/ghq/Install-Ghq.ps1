<#
.SYNOPSIS
Windows の ghq (repo の clone を決まった木に並べる CLI。winget の x-motemen.ghq) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/ghq/Install-Ghq.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Ghq から呼ぶ (win/README.md の「ghq・fzf」)。
dotfiles.ps1 の cdrepo (ghq の repo を fzf で選んで移る) が使う。入れて揃えるのは Windows の runner の手順 ghq (win/runner/src/steps/ps1.rs。
dotfiles apply)。

中身は winget の portable の道具の共通の枠 (win/winget/WingetPortable.ps1。win/README.md の「winget の portable の道具」) で、ここは ghq の表だけを
持つ。常駐も UAC も無いので、版のずれも揃える。

ghq は zip の中の portable のパッケージで、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の
下に入る (ghq.exe は zip の中のディレクトリ ghq_windows_amd64 の下。arm64 は ghq_windows_arm64)。
入れるときは --installer-type portable で portable を名指しする (今の manifest は portable だけだが、
fzf のように MSI が足されると winget の既定がそちらに替わるので、先に名指ししておく)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id x-motemen.ghq --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3
(昇格した PowerShell で winget を打てないときは、入っていなくても 1)。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない。
#>
[CmdletBinding()]
param(
    [string]$Version = '1.12.0',
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
$packageId = 'x-motemen.ghq'

# ghq の表 (key は WingetPortable.ps1 の頭の「道具の表」)
function Get-GhqTool {
    @{
        Name           = 'ghq'
        Command        = 'Install-Ghq'
        PackageId      = $packageId
        CommandName    = 'ghq'
        Readme         = 'ghq・fzf'
        # ghq.exe --version の出力 ("ghq version <版> (rev:<commit>)")
        VersionPattern = '^\s*ghq\s+version\s+v?(?<v>\d+(\.\d+)+)(\s|$)'
        # manifest の x64 の RelativeFilePath。無ければ置き場所の下を探す (arm64 の ghq_windows_arm64 や、zip の中の形が変わっても読めるように)
        ExePath        = 'ghq_windows_amd64\ghq.exe'
        ExeSearch      = $true
        BusyFix        = '動いている ghq (ghq get など) を終わらせる'
    }
}

# dot-source されたとき (試験) は関数だけを読み、本体は走らせない
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    exit (Start-WingetPortable -Tool (Get-GhqTool) -Version $Version -Check:$Check -IfMissing:$IfMissing)
}
