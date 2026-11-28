<#
.SYNOPSIS
Windows の Claude Code (winget の Anthropic.ClaudeCode) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/claude-code/Install-ClaudeCode.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-ClaudeCode から呼ぶ (win/README.md の「Claude Code」)。入れて揃えるのは WSL の setup --update
(bootstrap-windows-claude-code.sh) か、受け持ちを runner に切り替えたホストでは Windows の runner の手順 claude-code (dotfiles apply)。

中身は winget の portable の道具の共通の枠 (win/winget/WingetPortable.ps1。win/README.md の「winget の portable の道具」) で、ここは Claude Code の
表と、自動更新の変数を見る custom の関数 (Read-ClaudeCodeState・Format-ClaudeCodeNotes) を持つ。常駐も UAC も無いので、版のずれも揃える。

Claude Code は portable のパッケージ (claude.exe 1 つ) で、管理者無しで %LOCALAPPDATA%\Microsoft\WinGet\Packages の
下に入る。winget で入れた Claude Code は自分では上がらない (claude update は何もしない)。claude.exe が動いている間は
置き換えられないので、入れ替えが要るときに置き場所の claude.exe が動いていれば (Windows で Claude Code の会話を
開いていれば)、何も変えずに止める (止めはしない)。WSL の claude は別のもの (mise が入れる) で、ここでは見ない。

CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE (Claude Code に winget upgrade を打たせる) は設定しない。設定されていれば
固定した版から外れうるので、※ で知らせる。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。winget show --id Anthropic.ClaudeCode --versions に出る値。版を変えるときはここの既定値を変える。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない。揃っていれば終了コード 0、差があれば 1、入っていなければ 3
(昇格した PowerShell で winget を打てないときは、入っていなくても 1)。

.PARAMETER IfMissing
入っていなければ固定した版を入れて pin を足す。入っていれば -Check と同じで、入れ替えはしない。
#>
[CmdletBinding()]
param(
    [string]$Version = '2.1.330',
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
$packageId = 'Anthropic.ClaudeCode'

# Claude Code の表 (key は WingetPortable.ps1 の頭の「道具の表」)
function Get-ClaudeCodeTool {
    @{
        Name           = 'Claude Code'
        Command        = 'Install-ClaudeCode'
        PackageId      = $packageId
        CommandName    = 'claude'
        Readme         = 'Claude Code'
        # claude.exe --version の出力 ("<版> (Claude Code)")。(Claude Code) の付かない数字だけの行は版と読まない
        VersionPattern = '^\s*(?<v>\d+(\.\d+)+)\s+\(Claude Code\)\s*$'
        # claude.exe は置き場所の直下 (portable の exe 1 つ)
        ExePath        = 'claude.exe'
        BusyFix        = 'Windows で開いている Claude Code の会話を閉じる (WSL の claude は別のもの)'
        # native の installer・claude install は %USERPROFILE%\.local\bin に、npm の global は claude.cmd を置く
        PathOtherFix   = '{0} の {1} を外す (native の installer・claude install・npm で入れたものの外し方は win/README.md の「Claude Code」)'
        Retry          = 'dotfiles apply・setup --update'
        Hooks          = @{ ReadState = 'Read-ClaudeCodeState'; Notes = 'Format-ClaudeCodeNotes' }
    }
}

# ---------------------------------------------------------------------------
# custom の関数 (Install-ClaudeCode.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE の値が、Claude Code に winget upgrade を打たせる値か
function Test-ClaudeCodeAutoUpdateValue {
    param([string]$Value)
    "$Value".Trim() -in @('1', 'true')
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

# ③ 状態に足す値: 自動更新の変数が有効になっている所 (無ければ $null)
function Read-ClaudeCodeState {
    param($Tool, $State)
    @{ AutoUpdate = Get-ClaudeCodeAutoUpdateSource }
}

# ⑥ 表の終わりに足す行: 自動更新の変数が有効なら ※ で知らせる (差には数えない。dotfiles は設定しない)
function Format-ClaudeCodeNotes {
    param($Tool, $State)
    if ($State.AutoUpdate) {
        @{ Text = "※ CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE が $($State.AutoUpdate) で有効になっている。Claude Code が自分で winget upgrade を打ち、固定した版から外れうる (dotfiles は設定しない。外すなら消す)"; Warn = $false }
    }
}

# dot-source されたとき (試験) は関数だけを読み、本体は走らせない
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    exit (Start-WingetPortable -Tool (Get-ClaudeCodeTool) -Version $Version -Check:$Check -IfMissing:$IfMissing)
}
