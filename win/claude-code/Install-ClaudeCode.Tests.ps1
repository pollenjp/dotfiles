# win/claude-code/Install-ClaudeCode.ps1 (Claude Code の表と、自動更新の変数を見る custom の関数) のテスト。Pester は使わない。
# 流れ・見張り・終了コードの決まりは共通の枠の試験 (win/winget/WingetPortable.Tests.ps1) が確かめ、ここは Claude Code の表の値と custom の関数が
# そこへ正しく渡るかを確かめる。winget やプロセスに触る本物の部分は、実機で -Check と本番を打って確かめる (win/README.md の「Claude Code」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/claude-code/Install-ClaudeCode.Tests.ps1
#
# ## 確かめること
#
#   - 表: パッケージ ID は Anthropic.ClaudeCode (版の知らせが読む $packageId の行)、claude.exe は置き場所の直下 (探さない)。portable を名指しする
#   - claude.exe --version の出力 (<版> (Claude Code)) から版を拾い、winget show --versions の版の行だけを新しい順に拾う
#   - PATH で引かれる claude (winget の置き場所・WinGet\Links なら winget のもの。native の installer・npm のものは other)
#   - CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE が有効 (環境変数か settings.json の env) なら ※ で知らせる (差には数えない)
#   - 状態の表の見出しと行・締めの行 (WSL の bootstrap-windows-claude-code.sh と runner が読む字)・昇格した PowerShell の締めの行
#   - 流れ: 入っていなければ入れて pin を足す。pin を足すだけなら claude が動いていても止めない。入れ替えが要るのに動いていれば止まる
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-ClaudeCode.ps1 の末尾)。共通の枠も clone の win\winget\ から読む
. (Join-Path $PSScriptRoot 'Install-ClaudeCode.ps1')

$script:Failures = 0

# Actual の scriptblock を走らせ、文字列にして Expected と比べる。
# 関数が無いなどで例外になったら、その文面を結果として失敗にする。
function Test-Case {
    param([string]$Name, $Expected, [scriptblock]$Actual)
    try {
        $got = & $Actual
    } catch {
        $got = "ERROR: $($_.Exception.Message)"
    }
    $e = @($Expected | ForEach-Object { "$_" }) -join ' '
    $a = @($got | ForEach-Object { "$_" }) -join ' '
    if ($e -ceq $a) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        Write-Host "     expected: [$e]"
        Write-Host "     actual:   [$a]"
        $script:Failures++
    }
}

$Id = 'Anthropic.ClaudeCode'
$V = '2.1.318'
$Older = '2.1.317'
$Newer = '2.1.321'
$Pkg = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Packages\Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe'
$Links = 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links'
$Native = 'C:\Users\u\.local\bin\claude.exe'

# Claude Code の表に、試験の置き場所を足して埋めたもの
function New-Tool {
    param([hashtable]$Change = @{})
    $t = Get-ClaudeCodeTool
    $t.PackageDir = $Pkg
    $t.LinksDir = $Links
    foreach ($k in $Change.Keys) { $t[$k] = $Change[$k] }
    Complete-PortableTool -Tool $t
}
$T = New-Tool

# 2026-11-14 に winget-pkgs にあった Anthropic.ClaudeCode の版の新しい方 (winget show --versions の並び。
# 2.1.313・2.1.315 は無い)
$show = @(
    'Found Claude Code [Anthropic.ClaudeCode]'
    'Version'
    '-------'
    '2.1.318'
    '2.1.317'
    '2.1.316'
    '2.1.314'
)
$versions = @($V, $Older)

# 表
Test-Case 'パッケージ ID は $packageId の行 (版の知らせが読む)' $Id { $T.PackageId }
Test-Case '名前・関数・PATH で引く名前・README の節' 'Claude Code|Install-ClaudeCode|claude|Claude Code' { "$($T.Name)|$($T.Command)|$($T.CommandName)|$($T.Readme)" }
Test-Case 'claude.exe は置き場所の直下 (探さない)・MSI は見ない・portable を名指しする' 'claude.exe False True portable' { "$($T.ExePath) $($T.ExeSearch) $($null -eq $T.Msi) $($T.InstallerType)" }
Test-Case 'custom の口は、状態に足す値と表の終わりの行' 'Notes=Format-ClaudeCodeNotes ReadState=Read-ClaudeCodeState' { (@($T.Hooks.Keys | Sort-Object) | ForEach-Object { "$_=$($T.Hooks[$_])" }) -join ' ' }

# claude.exe --version の出力から版を拾う
function Get-Version { param([string[]]$Lines) Get-PortableVersionFromOutput -Lines $Lines -Pattern $T.VersionPattern }
Test-Case '"<版> (Claude Code)" から版を拾う' $V { Get-Version @("$V (Claude Code)") }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-Version @("  $V (Claude Code)`r") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-Version @('Auto-update failed', "$V (Claude Code)") }
Test-Case '版の行が無ければ空' '' { Get-Version @('error: something went wrong') }
Test-Case '(Claude Code) の付かない数字だけの行は版と読まない' '' { Get-Version @('2.1.318') }

Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$V $Older 2.1.316 2.1.314" { Get-WingetVersionList -Lines $show }
$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '固定した版が古ければ down' 'down' { Get-PortableDirection -Versions $showVersions -Installed $V -Target '2.1.316' }
Test-Case '入っている版が winget に無ければ unknown (native の新しい版など)' 'unknown' { Get-PortableDirection -Versions $showVersions -Installed '2.1.325' -Target $V }

# winget の引数 (portable の exe 1 つ。portable を名指しする)
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版と portable を名指しして入れる' "install $common --version $V --installer-type portable --accept-package-agreements" { @(Get-WingetCommands -Tool $T -Plan install -Version $V)[0] -join ' ' }
Test-Case 'change は uninstall → install' "uninstall $common|install $common --version $V --installer-type portable --accept-package-agreements" { (@(Get-WingetCommands -Tool $T -Plan change -Version $V) | ForEach-Object { $_ -join ' ' }) -join '|' }

# PATH で引かれる claude.exe がどこのものか
$exists = { param($p) $p -in @($Native, "$Pkg\claude.exe") }
Test-Case 'native の installer の置き場所が先なら、それが引かれる' $Native { Resolve-PortableOnPath -PathValue "C:\Users\u\.local\bin;$Pkg" -Names @('claude.exe') -Exists $exists }
$npm = 'C:\Users\u\AppData\Roaming\npm'
Test-Case 'npm の global の claude.cmd が前のディレクトリにあれば、それが引かれる' "$npm\claude.cmd" { Resolve-PortableOnPath -PathValue "$npm;$Pkg" -Names @('claude.exe', 'claude.cmd', 'claude.bat', 'claude.ps1') -Exists { param($p) $p -in @("$npm\claude.cmd", "$Pkg\claude.exe") } }
Test-Case 'winget の置き場所の claude.exe なら package' 'package' { Get-PortablePathKind -Resolved "$Pkg\claude.exe" -ExeDir $Pkg -LinksDir $Links }
Test-Case 'WinGet\Links の symlink なら links' 'links' { Get-PortablePathKind -Resolved "$Links\claude.exe" -ExeDir $Pkg -LinksDir $Links }
Test-Case 'native の installer (%USERPROFILE%\.local\bin) なら other' 'other' { Get-PortablePathKind -Resolved $Native -ExeDir $Pkg -LinksDir $Links }

# Test-ClaudeCodeAutoUpdateValue: Claude Code に winget upgrade を打たせる値か
Test-Case '1 と true (大文字小文字によらず) は有効' 'True True True' { "$(Test-ClaudeCodeAutoUpdateValue -Value '1') $(Test-ClaudeCodeAutoUpdateValue -Value 'true') $(Test-ClaudeCodeAutoUpdateValue -Value ' TRUE ')" }
Test-Case '0・空・null は無効' 'False False False' { "$(Test-ClaudeCodeAutoUpdateValue -Value '0') $(Test-ClaudeCodeAutoUpdateValue -Value '') $(Test-ClaudeCodeAutoUpdateValue -Value $null)" }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Exe = "$Pkg\claude.exe"; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$Pkg\claude.exe"; PathLinkTarget = $null; PathKind = 'package'; BusyCount = 0
        MsiExe = $null; WingetVersion = [version]'1.30.310'; Elevated = $false; Route = 'direct'; AutoUpdate = $null
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Exe = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 手で入れた固定した版 (ある PC の 2026-11-14 の今。pin だけが無い)
$handSame = @{ Pinned = $false }
$changeUp = @{ Installed = $Older; Plan = 'change'; Direction = 'up' }

# 終了コード
Test-Case '揃っていれば 0' 0 { Get-PortableExitCode -Tool $T -State (New-State) }
Test-Case '同じ版で pin が無ければ 1' 1 { Get-PortableExitCode -Tool $T -State (New-State $handSame) }
Test-Case 'native の claude が先なら 1' 1 { Get-PortableExitCode -Tool $T -State (New-State @{ PathKind = 'other'; PathResolved = $Native }) }
Test-Case '入っていなければ 3' 3 { Get-PortableExitCode -Tool $T -State (New-State $missing) }
Test-Case '自動更新の変数は差に数えない (揃っていれば 0)' 0 { Get-PortableExitCode -Tool $T -State (New-State @{ AutoUpdate = 'User の環境変数' }) }

# 揃える前に止める理由
Test-Case '入れ替えるのに claude が動いていれば busy' 'busy' { Get-PortableApplyBlocker -Tool $T -State (New-State ($changeUp + @{ BusyCount = 1 })) -Target $V }
Test-Case 'pin を足すだけなら、動いていても止めない' '' { Get-PortableApplyBlocker -Tool $T -State (New-State ($handSame + @{ BusyCount = 1 })) -Target $V }

# 状態の表の行
function Get-Rows { param($State) @(Format-PortableState -Tool $T -State $State -Target $V) }
Test-Case '揃っていれば ⚠ の行は無く、表の 6 行だけ' '0 6' { $r = Get-Rows (New-State); "$(@($r | Where-Object { $_.Warn }).Count) $($r.Count)" }
Test-Case '見出しはパッケージ名と置き場所 (bootstrap-windows-claude-code.sh と runner がこの頭で見分ける)' "Claude Code (winget の Anthropic.ClaudeCode、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '同じ版で pin が無ければ、pin の行だけ ⚠' '⚠ winget pin      : 無し → 足す 1' { $r = Get-Rows (New-State $handSame); "$($r[4].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '古い版から上げるとき' "⚠ 固定した版      : $V → 入れ替える (上げる)" { (Get-Rows (New-State $changeUp))[2].Text }
Test-Case 'PATH の行の幅はほかの行と同じにそろえる' '  PATH の claude  : winget の portable のもの (置き場所)' { (Get-Rows (New-State))[5].Text }
Test-Case '版が読めないとき' '  入っている版    : 不明 (claude.exe --version が読めない)' { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case 'native の claude が先なら、その場所を ⚠ で出し、外し方を ※ で添える' "⚠ PATH の claude  : $Native (winget の portable のものではない)|※ PATH のずれは Install-ClaudeCode では直らない。C:\Users\u\.local\bin の claude.exe を外す (native の installer・claude install・npm で入れたものの外し方は win/README.md の「Claude Code」)" { $r = Get-Rows (New-State @{ PathKind = 'other'; PathResolved = $Native }); "$($r[5].Text)|$($r[-1].Text)" }
Test-Case '置き場所が PATH に無ければ、足し直し方を ※ で添える' "※ Claude Code の置き場所がユーザーの PATH に無い。PATH に足すか、winget uninstall --id $Id の後に Install-ClaudeCode で入れ直す" { (Get-Rows (New-State @{ PathKind = 'none'; PathResolved = $null }))[-1].Text }
Test-Case '新しい版があれば ※ で知らせる' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-ClaudeCode.ps1 の -Version の既定値を変える" { (Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }))[6].Text }
Test-Case '入れ替えが要るのに claude が動いていれば、会話を閉じるよう ※ で添える' '※ claude.exe が 2 個動いている。入れ替えるには、Windows で開いている Claude Code の会話を閉じる (WSL の claude は別のもの)' { (Get-Rows (New-State ($changeUp + @{ BusyCount = 2 })))[-1].Text }
Test-Case '自動更新の変数が有効なら ※ で知らせる (⚠ にしない)' '※ CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE が User の環境変数 で有効になっている。Claude Code が自分で winget upgrade を打ち、固定した版から外れうる (dotfiles は設定しない。外すなら消す) 0' { $r = Get-Rows (New-State @{ AutoUpdate = 'User の環境変数' }); "$($r[-1].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '自動更新の ※ は、動いている claude の ※ の後ろ' '※ claude.exe が 1 個動いている。入れ替えるには、Windows で開いている Claude Code の会話を閉じる (WSL の claude は別のもの)|※ CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE が User の環境変数 で有効になっている。Claude Code が自分で winget upgrade を打ち、固定した版から外れうる (dotfiles は設定しない。外すなら消す)' { $r = Get-Rows (New-State ($changeUp + @{ BusyCount = 1; AutoUpdate = 'User の環境変数' })); "$($r[-2].Text)|$($r[-1].Text)" }

# 締めの行。WSL の bootstrap-windows-claude-code.sh と Windows の runner がこの字で、入れるか・揃えるか・知らせるだけかを決め、昇格の行で直し方を選ぶ
function Get-Verdict { param($State) (@(Format-PortableVerdict -Tool $T -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '揃っていれば締めの行は出さない (自動更新の変数があっても)' '' { Get-Verdict (New-State @{ AutoUpdate = 'User の環境変数' }) }
Test-Case '入っていなければ、Install-ClaudeCode で入れると出す' '⚠️ Claude Code が入っていない → Install-ClaudeCode で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case 'pin が無ければ、Install-ClaudeCode で揃えると出す' '⚠️ 固定した版と揃っていない → Install-ClaudeCode で揃える ⚠️' { Get-Verdict (New-State $handSame) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す' '⚠️ PATH の claude が winget の portable のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = $Native }) }
Test-Case '昇格した PowerShell で入れられなければ、昇格の 1 行だけ' '⚠️ 昇格した PowerShell では winget が Claude Code を入れない (winget 1.30 から) → ※ の手順で直す ⚠️' { Get-Verdict (New-State ($changeUp + @{ Elevated = $true; Route = 'elevated' })) }

# Get-ClaudeCodeAutoUpdateSource: settings.json の env を読む (読めなければ黙る)。環境変数はテストで触らない
$profileDir = Join-Path ([IO.Path]::GetTempPath()) "install-claude-code-tests-profile-$PID"
$savedProfile = $env:USERPROFILE
$env:USERPROFILE = $profileDir
$settingsFile = Join-Path $profileDir '.claude\settings.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsFile) | Out-Null
Set-Content -LiteralPath $settingsFile -Value '{"env":{"CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE":"1"}}' -Encoding UTF8
Test-Case 'settings.json の env で 1 なら、その場所を返す' "$settingsFile の env" { Get-ClaudeCodeAutoUpdateSource }
Test-Case 'Read-ClaudeCodeState は、その場所を状態の AutoUpdate にする' "$settingsFile の env" { (Read-ClaudeCodeState -Tool $T -State (New-State)).AutoUpdate }
Set-Content -LiteralPath $settingsFile -Value '{"env":{"OTHER":"1"},"model":"x"}' -Encoding UTF8
Test-Case 'settings.json に変数が無ければ空' '' { Get-ClaudeCodeAutoUpdateSource }
Set-Content -LiteralPath $settingsFile -Value '{"model":"x"}' -Encoding UTF8
Test-Case 'settings.json に env が無ければ空' '' { Get-ClaudeCodeAutoUpdateSource }
Set-Content -LiteralPath $settingsFile -Value '{ not json' -Encoding UTF8
Test-Case 'settings.json が読めなければ空 (止まらない)' '' { Get-ClaudeCodeAutoUpdateSource }
$env:USERPROFILE = $savedProfile
Remove-Item -LiteralPath $profileDir -Recurse -Force

# ---------------------------------------------------------------------------
# 入口から流れまで (Start-WingetPortable に Claude Code の表を渡す)。Windows に触る関数を偽物に差し替えて、打つ winget の順を確かめる。
# ここより後ろでは本物の関数は使えない
# ---------------------------------------------------------------------------
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) "install-claude-code-tests-$PID"
$FakeExe = Join-Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Anthropic.ClaudeCode_Microsoft.Winget.Source_8wekyb3d8bbwe') 'claude.exe'

function winget { }
function Invoke-Winget {
    param([string[]]$Arguments)
    $verb = if ($Arguments[0] -eq 'pin') { "pin $($Arguments[1])" } else { $Arguments[0] }
    $script:Calls.Add($verb)
    $code = 0
    if ($script:Fail.ContainsKey($verb)) { $code = $script:Fail[$verb] }
    if (($code -eq 0) -and ($verb -eq 'install')) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    if (($code -eq 0) -and ($verb -eq 'uninstall')) { Remove-Item -LiteralPath $FakeExe -Force -ErrorAction SilentlyContinue }
    $lines = @()
    if (($verb -eq 'pin list') -and $script:PinListed) { $lines = @("Claude Code $Id $V winget Pinning") }
    [pscustomobject]@{ ExitCode = $code; Lines = $lines }
}
function Get-PortableState { param($Tool, $Target) $script:States.Dequeue() }
function Get-PortableBusyProcess { param($Tool) @($script:Busy) }
function Get-CimInstance { [pscustomobject]@{ CommandLine = 'claude.exe --dangerously-skip-permissions' } }

function Invoke-Flow {
    param([object[]]$States, [switch]$Check, [switch]$IfMissing, [hashtable]$Fail = @{}, [int]$Busy = 0, [switch]$ExeExists, [switch]$PinListed)
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    $script:States = [System.Collections.Generic.Queue[object]]::new()
    foreach ($s in $States) { $script:States.Enqueue($s) }
    $script:Fail = $Fail
    $script:Busy = @()
    if ($Busy -gt 0) { $script:Busy = @(1..$Busy | ForEach-Object { [pscustomobject]@{ Id = 1000 + $_ } }) }
    $script:PinListed = [bool]$PinListed
    Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue
    if ($ExeExists) { New-Item -ItemType File -Force -Path $FakeExe | Out-Null }
    $out = @(Start-WingetPortable -Tool (Get-ClaudeCodeTool) -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
    [pscustomobject]@{
        Calls = ($script:Calls -join ' ')
        Text  = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Code  = @($out | Where-Object { $_ -is [int] })[-1]
    }
}

$synced = New-State
Test-Case '-Check は winget を打たない' '1 []' { $r = Invoke-Flow -States @((New-State $handSame)) -Check -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '-IfMissing は入っていなければ install して pin を足す' '0 [install pin list pin add]' { $r = Invoke-Flow -States @((New-State $missing), $synced) -IfMissing; "$($r.Code) [$($r.Calls)]" }
Test-Case '同じ版で pin だけ無ければ、pin を足すだけ (claude が動いていても)' '0 [pin list pin add]' { $r = Invoke-Flow -States @((New-State ($handSame + @{ BusyCount = 1 })), $synced) -Busy 1 -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '入れ替えは取得を確かめてから uninstall → install して pin を足す' '0 [download pin remove uninstall install pin list pin add]' { $r = Invoke-Flow -States @((New-State $changeUp), $synced) -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case '入れ替えが要るのに claude が動いていれば、winget を打たずに止まり、会話を閉じるよう出す' '1 [] True True' { $r = Invoke-Flow -States @((New-State ($changeUp + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*会話を閉じる*') $($r.Text -like '*1001*claude.exe --dangerously*')" }
Test-Case '取得が落ちたら、何も変えずに止まる' '1 [download]' { $r = Invoke-Flow -States @((New-State $changeUp)) -Fail @{ download = 1 } -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'native の claude が先なだけなら、winget を打たずに 1 で止まる' '1 []' { $r = Invoke-Flow -States @((New-State @{ PathKind = 'other'; PathResolved = $Native })) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)]" }
Test-Case 'install が落ちたら、WSL の setup でも runner でも入ると添えて打ち直し方を出す' 'True' { $r = Invoke-Flow -States @((New-State $missing), (New-State $missing)) -Fail @{ install = 1 } -IfMissing; $r.Text -like '*Claude Code が入っていないことがある。ネットワークを確かめて Install-ClaudeCode を打ち直す (dotfiles apply・setup --update でも入る)*' }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
