<#
.SYNOPSIS
Windows の ntn (Notion の CLI。winget の Notion.ntn) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/ntn/Install-Ntn.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-Ntn から呼ぶ (win/README.md の「ntn」)。入れて揃えるのは WSL の setup --update
(bootstrap-windows-ntn.sh) か、受け持ちを runner に切り替えたホストでは Windows の runner の手順 ntn (dotfiles apply)。

中身は winget の portable の道具の共通の枠 (win/winget/WingetPortable.ps1。win/README.md の「winget の portable の道具」) で、ここは ntn の表だけを
持つ。常駐も UAC も無いので、版のずれも揃える (herdr のように知らせるだけにしない)。

ntn は zip の中の portable のパッケージで、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の
下に入る (ntn.exe は zip の中のディレクトリ ntn-x86_64-pc-windows-msvc の下)。winget のパッケージは x64 だけ。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Notion.ntn --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3
(昇格した PowerShell で winget を打てないときは、入っていなくても 1)。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.23.30',
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
$packageId = 'Notion.ntn'

# ntn の表 (key は WingetPortable.ps1 の頭の「道具の表」)
function Get-NtnTool {
    @{
        Name           = 'ntn'
        Command        = 'Install-Ntn'
        PackageId      = $packageId
        CommandName    = 'ntn'
        Readme         = 'ntn'
        # ntn.exe --version の出力 ("ntn <版>")
        VersionPattern = '^\s*ntn\s+(?<v>\S+)\s*$'
        # manifest の RelativeFilePath。zip の中の形が変わっても読めるよう、無ければ置き場所の下を探す
        ExePath        = 'ntn-x86_64-pc-windows-msvc\ntn.exe'
        ExeSearch      = $true
        Retry          = 'dotfiles apply・setup --update'
    }
}

# dot-source されたとき (試験) は関数だけを読み、本体は走らせない
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    exit (Start-WingetPortable -Tool (Get-NtnTool) -Version $Version -Check:$Check -IfMissing:$IfMissing)
}
