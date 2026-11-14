# win/claude-code/Install-ClaudeCode.ps1 のうち、副作用の無い関数と、Windows に触る関数を偽物に差し替えた流れのテスト。
# Pester は使わない。winget やプロセスに触る本物の部分は、実機で -Check と本番を打って確かめる (win/README.md の「Claude Code」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/claude-code/Install-ClaudeCode.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# dot-source すると関数だけを読み、本体は走らない (Install-ClaudeCode.ps1 の末尾)
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

# Get-ClaudeCodeVersionFromOutput: claude.exe --version の出力から版を拾う
Test-Case '"<版> (Claude Code)" から版を拾う' $V { Get-ClaudeCodeVersionFromOutput -Lines @("$V (Claude Code)") }
Test-Case '行末の CR と前後の空白を落とす' $V { Get-ClaudeCodeVersionFromOutput -Lines @("  $V (Claude Code)`r") }
Test-Case 'ほかの行が先にあっても拾う' $V { Get-ClaudeCodeVersionFromOutput -Lines @('Auto-update failed', "$V (Claude Code)") }
Test-Case '版の行が無ければ空' '' { Get-ClaudeCodeVersionFromOutput -Lines @('error: something went wrong') }
Test-Case '(Claude Code) の付かない数字だけの行は版と読まない' '' { Get-ClaudeCodeVersionFromOutput -Lines @('2.1.318') }

# Get-WingetVersionList: winget show --versions の出力から、版の行だけを新しい順に拾う
Test-Case '版の行だけを拾う (見出し・区切りは拾わない)' "$V $Older 2.1.316 2.1.314" { Get-WingetVersionList -Lines $show }

# Get-ClaudeCodePlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-ClaudeCodePlan -Exists $false -Installed $null -Target $V }
Test-Case '同じ版なら none (pjp-raiden の 2026-11-14 の今)' 'none' { Get-ClaudeCodePlan -Exists $true -Installed $V -Target $V }
Test-Case '違う版なら change' 'change' { Get-ClaudeCodePlan -Exists $true -Installed $Older -Target $V }
Test-Case 'claude.exe があるのに版が読めなければ change' 'change' { Get-ClaudeCodePlan -Exists $true -Installed $null -Target $V }

# Get-ClaudeCodeDirection: 入れ替えの向き
$showVersions = @(Get-WingetVersionList -Lines $show)
Test-Case '固定した版が新しければ up' 'up' { Get-ClaudeCodeDirection -Versions $showVersions -Installed '2.1.314' -Target $V }
Test-Case '固定した版が古ければ down' 'down' { Get-ClaudeCodeDirection -Versions $showVersions -Installed $V -Target '2.1.316' }
Test-Case '入っている版が winget に無ければ unknown (native の新しい版など)' 'unknown' { Get-ClaudeCodeDirection -Versions $showVersions -Installed '2.1.325' -Target $V }

# Test-WingetPinned: winget pin list の出力に、その Id の行があるか
$pinsNow = @(
    'Name              Id                        Version     Source Pin type'
    '-----------------------------------------------------------------------'
    'herdr             Herdr.Herdr               0.9.5       winget Pinning'
)
Test-Case 'ほかのパッケージの pin しか無ければ False' 'False' { Test-WingetPinned -Lines $pinsNow -PackageId $Id }
Test-Case 'Id の列が一致すれば True' 'True' { Test-WingetPinned -Lines ($pinsNow + @("Claude Code       $Id      $V     winget Pinning")) -PackageId $Id }

# Get-WingetCommands: plan ごとに打つ winget の引数
$common = "--id $Id --exact --source winget --silent --accept-source-agreements --disable-interactivity"
Test-Case 'install は版を名指しして入れる' "install $common --version $V --accept-package-agreements" { @(Get-WingetCommands -Plan install -PackageId $Id -Version $V)[0] -join ' ' }
Test-Case 'change は uninstall → install' "uninstall $common|install $common --version $V --accept-package-agreements" { (@(Get-WingetCommands -Plan change -PackageId $Id -Version $V) | ForEach-Object { $_ -join ' ' }) -join '|' }

# Resolve-ClaudeCodeOnPath・Get-ClaudeCodePathKind: PATH で引かれる claude.exe がどこのものか
$exists = { param($p) $p -in @($Native, "$Pkg\claude.exe") }
Test-Case 'native の installer の置き場所が先なら、それが引かれる' $Native { Resolve-ClaudeCodeOnPath -PathValue "C:\Users\u\.local\bin;$Pkg" -Names @('claude.exe') -Exists $exists }
$npm = 'C:\Users\u\AppData\Roaming\npm'
Test-Case 'npm の global の claude.cmd が前のディレクトリにあれば、それが引かれる' "$npm\claude.cmd" { Resolve-ClaudeCodeOnPath -PathValue "$npm;$Pkg" -Names @('claude.exe', 'claude.cmd', 'claude.bat', 'claude.ps1') -Exists { param($p) $p -in @("$npm\claude.cmd", "$Pkg\claude.exe") } }
Test-Case 'winget の置き場所の claude.exe なら winget' 'winget' { Get-ClaudeCodePathKind -Resolved "$Pkg\claude.exe" -ExeDir $Pkg -LinksDir $Links }
Test-Case 'WinGet\Links の symlink なら winget' 'winget' { Get-ClaudeCodePathKind -Resolved "$Links\claude.exe" -ExeDir $Pkg -LinksDir $Links }
Test-Case 'native の installer (%USERPROFILE%\.local\bin) なら other' 'other' { Get-ClaudeCodePathKind -Resolved $Native -ExeDir $Pkg -LinksDir $Links }
Test-Case '見つからなければ none' 'none' { Get-ClaudeCodePathKind -Resolved $null -ExeDir $Pkg -LinksDir $Links }

# Test-ClaudeCodeAutoUpdateValue: Claude Code に winget upgrade を打たせる値か
Test-Case '1 と true (大文字小文字によらず) は有効' 'True True True' { "$(Test-ClaudeCodeAutoUpdateValue -Value '1') $(Test-ClaudeCodeAutoUpdateValue -Value 'true') $(Test-ClaudeCodeAutoUpdateValue -Value ' TRUE ')" }
Test-Case '0・空・null は無効' 'False False False' { "$(Test-ClaudeCodeAutoUpdateValue -Value '0') $(Test-ClaudeCodeAutoUpdateValue -Value '') $(Test-ClaudeCodeAutoUpdateValue -Value $null)" }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Installed = $V; Plan = 'none'; Direction = 'same'; Pinned = $true
        Versions = $versions; Latest = $versions[0]; PathResolved = "$Pkg\claude.exe"; PathKind = 'winget'; BusyCount = 0
        AutoUpdate = $null
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Installed = $null; Plan = 'install'; Direction = 'unknown'; Pinned = $false; PathKind = 'none'; PathResolved = $null }
# 手で入れた固定した版 (pjp-raiden の 2026-11-14 の今。pin だけが無い)
$handSame = @{ Pinned = $false }
$changeUp = @{ Installed = $Older; Plan = 'change'; Direction = 'up' }

# Get-ClaudeCodeExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-ClaudeCodeExitCode -State (New-State) }
Test-Case '同じ版で pin が無ければ 1' 1 { Get-ClaudeCodeExitCode -State (New-State $handSame) }
Test-Case 'native の claude が先なら 1' 1 { Get-ClaudeCodeExitCode -State (New-State @{ PathKind = 'other'; PathResolved = $Native }) }
Test-Case '入っていなければ 3' 3 { Get-ClaudeCodeExitCode -State (New-State $missing) }
Test-Case '自動更新の変数は差に数えない (揃っていれば 0)' 0 { Get-ClaudeCodeExitCode -State (New-State @{ AutoUpdate = 'User の環境変数' }) }

# Get-ClaudeCodeApplyBlocker: 揃える前に止める理由
Test-Case '入れ替えるのに claude が動いていれば busy' 'busy' { Get-ClaudeCodeApplyBlocker -Plan change -Versions $versions -Target $V -BusyCount 1 }
Test-Case 'pin を足すだけなら、動いていても止めない' '' { Get-ClaudeCodeApplyBlocker -Plan none -Versions $versions -Target $V -BusyCount 1 }
Test-Case '固定した版が winget に無ければ not-listed' 'not-listed' { Get-ClaudeCodeApplyBlocker -Plan install -Versions $versions -Target '2.1.325' -BusyCount 0 }

# Format-ClaudeCodeState: 状態の表の行
function Get-Rows { param($State) @(Format-ClaudeCodeState -State $State -Target $V -PackageId $Id -PackageDir $Pkg) }
Test-Case '揃っていれば ⚠ の行は無く、表の 6 行だけ' '0 6' { $r = Get-Rows (New-State); "$(@($r | Where-Object { $_.Warn }).Count) $($r.Count)" }
Test-Case '見出しはパッケージ名と置き場所 (bootstrap-windows-claude-code.sh がこの頭で見分ける)' "Claude Code (winget の Anthropic.ClaudeCode、$Pkg)" { (Get-Rows (New-State))[0].Text }
Test-Case '同じ版で pin が無ければ、pin の行だけ ⚠' '⚠ winget pin      : 無し → 足す 1' { $r = Get-Rows (New-State $handSame); "$($r[4].Text) $(@($r | Where-Object { $_.Warn }).Count)" }
Test-Case '古い版から上げるとき' "⚠ 固定した版      : $V → 入れ替える (上げる)" { (Get-Rows (New-State $changeUp))[2].Text }
Test-Case 'PATH の行の幅は ntn と同じにそろえる' '  PATH の claude  : winget のもの' { (Get-Rows (New-State))[5].Text }
Test-Case 'native の claude が先なら、その場所を ⚠ で出し、外し方を ※ で添える' "⚠ PATH の claude  : $Native (winget のものではない)|※ PATH のずれは Install-ClaudeCode では直らない。C:\Users\u\.local\bin の claude.exe を外す (native の installer・claude install・npm で入れたものの外し方は win/README.md の「Claude Code」)" { $r = Get-Rows (New-State @{ PathKind = 'other'; PathResolved = $Native }); "$($r[5].Text)|$($r[-1].Text)" }
Test-Case '新しい版があれば ※ で知らせる' "※ winget に固定した版より新しい $Newer がある。上げるなら Install-ClaudeCode.ps1 の -Version の既定値を変える" { (Get-Rows (New-State @{ Versions = @($Newer) + $versions; Latest = $Newer }))[6].Text }
Test-Case '入れ替えが要るのに claude が動いていれば、会話を閉じるよう ※ で添える' '※ claude.exe が 2 個動いている。入れ替えるには、Windows で開いている Claude Code の会話を閉じる (WSL の claude は別のもの)' { (Get-Rows (New-State ($changeUp + @{ BusyCount = 2 })))[-1].Text }
Test-Case '自動更新の変数が有効なら ※ で知らせる (⚠ にしない)' '※ CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE が User の環境変数 で有効になっている。Claude Code が自分で winget upgrade を打ち、固定した版から外れうる (dotfiles は設定しない。外すなら消す) 0' { $r = Get-Rows (New-State @{ AutoUpdate = 'User の環境変数' }); "$($r[-1].Text) $(@($r | Where-Object { $_.Warn }).Count)" }

# Format-ClaudeCodeVerdict: 締めの行
function Get-Verdict { param($State) (@(Format-ClaudeCodeVerdict -State $State) | ForEach-Object { "$_" }) -join "`n" }
Test-Case '揃っていれば締めの行は出さない' '' { Get-Verdict (New-State) }
Test-Case '入っていなければ、Install-ClaudeCode で入れると出す' '⚠️ Claude Code が入っていない → Install-ClaudeCode で入れる ⚠️' { Get-Verdict (New-State $missing) }
Test-Case 'pin が無ければ、Install-ClaudeCode で揃えると出す' '⚠️ 固定した版と揃っていない → Install-ClaudeCode で揃える ⚠️' { Get-Verdict (New-State $handSame) }
Test-Case 'PATH のずれだけなら、※ の手順で直すと出す' '⚠️ PATH の claude が winget のものではない → ※ の手順で直す ⚠️' { Get-Verdict (New-State @{ PathKind = 'other'; PathResolved = $Native }) }

# Get-ClaudeCodeInstalledVersion: 起動できない claude.exe (壊れた・0 バイト) でも例外で止まらず、版は空
$broken = Join-Path ([IO.Path]::GetTempPath()) "install-claude-code-tests-broken-$PID.exe"
Set-Content -LiteralPath $broken -Value '' -NoNewline
if (-not $IsWindows) { chmod +x $broken }
Test-Case '起動できない claude.exe なら版は空 (入れ替えの対象になる)' '' { Get-ClaudeCodeInstalledVersion -Exe $broken }
Remove-Item -LiteralPath $broken -Force

# Get-ClaudeCodeAutoUpdateSource: settings.json の env を読む (読めなければ黙る)。環境変数はテストで触らない
$profileDir = Join-Path ([IO.Path]::GetTempPath()) "install-claude-code-tests-profile-$PID"
$savedProfile = $env:USERPROFILE
$env:USERPROFILE = $profileDir
$settingsFile = Join-Path $profileDir '.claude\settings.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsFile) | Out-Null
Set-Content -LiteralPath $settingsFile -Value '{"env":{"CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE":"1"}}' -Encoding UTF8
Test-Case 'settings.json の env で 1 なら、その場所を返す' "$settingsFile の env" { Get-ClaudeCodeAutoUpdateSource }
Set-Content -LiteralPath $settingsFile -Value '{"env":{"OTHER":"1"},"model":"x"}' -Encoding UTF8
Test-Case 'settings.json に変数が無ければ空' '' { Get-ClaudeCodeAutoUpdateSource }
Set-Content -LiteralPath $settingsFile -Value '{"model":"x"}' -Encoding UTF8
Test-Case 'settings.json に env が無ければ空' '' { Get-ClaudeCodeAutoUpdateSource }
Set-Content -LiteralPath $settingsFile -Value '{ not json' -Encoding UTF8
Test-Case 'settings.json が読めなければ空 (止まらない)' '' { Get-ClaudeCodeAutoUpdateSource }
$env:USERPROFILE = $savedProfile
Remove-Item -LiteralPath $profileDir -Recurse -Force

# 本体の入口: Linux の pwsh には $env:LOCALAPPDATA が無く、本体の最初で例外になる。
# それでも終了コード 2 で止まり、成功 (0) に見せない
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Install-ClaudeCode.ps1') -Check 2>&1
    $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Invoke-InstallClaudeCode の流れ。Windows に触る関数を偽物に差し替えて、打つ winget の順と、
# 途中で失敗したときの扱いを確かめる。ここより後ろでは本物の関数は使えない
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
function Get-ClaudeCodeState { param($PackageId, $PackageDir, $LinksDir, $Target) $script:States.Dequeue() }
function Get-ClaudeCodeBusyProcess { param($PackageDir) @($script:Busy) }
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
    $out = @(Invoke-InstallClaudeCode -Version $V -Check:$Check -IfMissing:$IfMissing 6>&1)
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
Test-Case '入れ替えが要るのに claude が動いていれば、winget を打たずに止まり、閉じるよう出す' '1 [] True True' { $r = Invoke-Flow -States @((New-State ($changeUp + @{ BusyCount = 1 }))) -Busy 1 -ExeExists; "$($r.Code) [$($r.Calls)] $($r.Text -like '*会話を閉じて*') $($r.Text -like '*1001*claude.exe --dangerously*')" }
Test-Case '取得が落ちたら、何も変えずに止まる' '1 [download]' { $r = Invoke-Flow -States @((New-State $changeUp)) -Fail @{ download = 1 } -ExeExists; "$($r.Code) [$($r.Calls)]" }
Test-Case 'native の claude が先なだけなら、winget を打たずに 1 で止まる' '1 []' { $r = Invoke-Flow -States @((New-State @{ PathKind = 'other'; PathResolved = $Native })) -ExeExists -PinListed; "$($r.Code) [$($r.Calls)]" }
Remove-Item -LiteralPath $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
