# win/type-clipboard/Install-TypeClipboard.ps1 のテスト。Pester は使わない (Install-Herdr.Tests.ps1 と同じ作り)。
# 副作用の無い関数と、Windows に触る関数 (落とす・ショートカット・プロセス) を偽物に差し替えた流れを確かめる。
# 落とす・ショートカットを作る・動いているかを見る本物の部分は、実機で置き場所を一時ディレクトリに向けて確かめる
# (win/README.md の「type-clipboard」)。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/type-clipboard/Install-TypeClipboard.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptPath = Join-Path $PSScriptRoot 'Install-TypeClipboard.ps1'

# dot-source すると関数だけを読み、本体は走らない (Install-TypeClipboard.ps1 の末尾)
. $ScriptPath

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

# 関数を通さずに SHA-256 を出す (テストの値を、確かめる関数に頼らずに作る)
function Get-TestSha256 {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

$V = '0.1.0'
$Older = '0.0.9'
$Newer = '0.2.0'
$Dir = 'C:\Users\u\AppData\Local\Programs\type-clipboard'
$Exe = "$Dir\type-clipboard.exe"
$HashV = Get-TestSha256 ([Text.Encoding]::UTF8.GetBytes('fake type-clipboard 0.1.0'))
$HashOld = Get-TestSha256 ([Text.Encoding]::UTF8.GetBytes('fake type-clipboard 0.0.9'))
$Table = [ordered]@{ $Older = $HashOld; $V = $HashV }

# ---------------------------------------------------------------------------
# 表と落とす先
# ---------------------------------------------------------------------------

# Get-TypeClipboardReleases: 版ごとの SHA-256 (Release の type-clipboard.exe.sha256 の中身)
Test-Case '0.1.0 は Release の type-clipboard.exe.sha256 と同じ値' '6788930f8c18aa1c786297f7a40044ab94931449a84d51fabaa5a5c45457c840' { (Get-TypeClipboardReleases)['0.1.0'] }
Test-Case '0.2.0 は Release の type-clipboard.exe.sha256 と同じ値' '5335259f39fc68163087307159eaa2c5ee283fd31f014dfa9b79c68aef3cac15' { (Get-TypeClipboardReleases)['0.2.0'] }
Test-Case '0.2.1 は Release の type-clipboard.exe.sha256 と同じ値' 'a0c94c37a186d5f57c3c07a6ec2c3371c80fe2543ce6dfacda9027b559241be3' { (Get-TypeClipboardReleases)['0.2.1'] }
Test-Case '表の値はどれも 64 桁の小文字の 16 進' 0 { @((Get-TypeClipboardReleases).Values | Where-Object { "$_" -cnotmatch '^[0-9a-f]{64}$' }).Count }
Test-Case '表の版はどれも X.Y.Z' 0 { @((Get-TypeClipboardReleases).Keys | Where-Object { "$_" -notmatch '^\d+\.\d+\.\d+$' }).Count }

# -Version の既定値 (固定した版) が表にある。既定値は param の AST から読む (関数からは見えない)
Test-Case '-Version の既定値は表にある' 'True' {
    $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Version' }
    (Get-TypeClipboardReleases).Contains($param.DefaultValue.Value)
}

# Get-TypeClipboardDownloadUrl: 版ごとの Release の exe
Test-Case '落とす先は版の tag の Release の type-clipboard.exe' 'https://github.com/pollenjp/type-clipboard/releases/download/v0.1.0/type-clipboard.exe' { Get-TypeClipboardDownloadUrl -Version $V }

# ---------------------------------------------------------------------------
# 版と plan
# ---------------------------------------------------------------------------

# Find-TypeClipboardVersion: exe の SHA-256 から表の版を引く
Test-Case 'SHA-256 が表にあればその版' $V { Find-TypeClipboardVersion -Releases $Table -Hash $HashV }
Test-Case '古い版の SHA-256 なら古い版' $Older { Find-TypeClipboardVersion -Releases $Table -Hash $HashOld }
Test-Case '大文字の 16 進でも引ける' $V { Find-TypeClipboardVersion -Releases $Table -Hash $HashV.ToUpperInvariant() }
Test-Case '表に無い SHA-256 なら空' '' { Find-TypeClipboardVersion -Releases $Table -Hash ('0' * 64) }
Test-Case 'SHA-256 が空なら空' '' { Find-TypeClipboardVersion -Releases $Table -Hash '' }

# Test-TypeClipboardHashMatch: 落とした物の SHA-256 が固定した値と同じか
Test-Case '同じなら True' 'True' { Test-TypeClipboardHashMatch -Expected $HashV -Actual $HashV }
Test-Case '大文字小文字だけの違いは True' 'True' { Test-TypeClipboardHashMatch -Expected $HashV -Actual $HashV.ToUpperInvariant() }
Test-Case '違えば False' 'False' { Test-TypeClipboardHashMatch -Expected $HashV -Actual $HashOld }
Test-Case '落とした物の SHA-256 が出せなければ (空) False' 'False' { Test-TypeClipboardHashMatch -Expected $HashV -Actual '' }
Test-Case '固定した値が空なら False (空どうしを同じと見ない)' 'False' { Test-TypeClipboardHashMatch -Expected '' -Actual '' }

# Get-TypeClipboardPlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-TypeClipboardPlan -Exists $false -Installed $null -Target $V }
Test-Case '同じ版なら none' 'none' { Get-TypeClipboardPlan -Exists $true -Installed $V -Target $V }
Test-Case '違う版なら change' 'change' { Get-TypeClipboardPlan -Exists $true -Installed $Older -Target $V }
Test-Case 'exe があるのに表のどの版でもなければ change' 'change' { Get-TypeClipboardPlan -Exists $true -Installed $null -Target $V }

# Get-TypeClipboardDirection: 入れ替えの向き (版を [version] で比べる)
Test-Case '固定した版が新しければ up' 'up' { Get-TypeClipboardDirection -Installed $Older -Target $V }
Test-Case '固定した版が古ければ down' 'down' { Get-TypeClipboardDirection -Installed $Newer -Target $V }
Test-Case '同じなら same' 'same' { Get-TypeClipboardDirection -Installed $V -Target $V }
Test-Case '入っている版が分からなければ unknown' 'unknown' { Get-TypeClipboardDirection -Installed $null -Target $V }
Test-Case '版の形でなければ unknown' 'unknown' { Get-TypeClipboardDirection -Installed '0.1.0-rc1' -Target $V }
Test-Case '0.10.0 は 0.9.0 より新しい (文字列で比べない)' 'up' { Get-TypeClipboardDirection -Installed '0.9.0' -Target '0.10.0' }

# Get-TypeClipboardShortcutKind: スタートメニューのショートカットが exe を指しているか
Test-Case 'exe を指していれば ok' 'ok' { Get-TypeClipboardShortcutKind -Exists $true -LinkTarget $Exe -Exe $Exe }
Test-Case '大文字小文字が違っても ok' 'ok' { Get-TypeClipboardShortcutKind -Exists $true -LinkTarget $Exe.ToUpperInvariant() -Exe $Exe }
Test-Case '無ければ missing' 'missing' { Get-TypeClipboardShortcutKind -Exists $false -LinkTarget $null -Exe $Exe }
Test-Case 'ほかを指していれば other' 'other' { Get-TypeClipboardShortcutKind -Exists $true -LinkTarget 'C:\Users\u\Downloads\type-clipboard.exe' -Exe $Exe }
Test-Case '中身が読めなければ (空) other' 'other' { Get-TypeClipboardShortcutKind -Exists $true -LinkTarget '' -Exe $Exe }

# Test-TypeClipboardBusyPath: 動いている type-clipboard.exe が置き場所のものか (置き換えの邪魔になるか)
Test-Case '置き場所の exe なら True' 'True' { Test-TypeClipboardBusyPath -Path $Exe -InstallDir $Dir }
Test-Case '大文字小文字が違っても True' 'True' { Test-TypeClipboardBusyPath -Path $Exe.ToUpperInvariant() -InstallDir $Dir }
Test-Case '置き場所の末尾に \ があっても True' 'True' { Test-TypeClipboardBusyPath -Path $Exe -InstallDir "$Dir\" }
Test-Case 'ほかの場所の exe なら False' 'False' { Test-TypeClipboardBusyPath -Path 'C:\Users\u\Downloads\type-clipboard.exe' -InstallDir $Dir }
Test-Case '名前が前方一致するだけのディレクトリは False' 'False' { Test-TypeClipboardBusyPath -Path 'C:\Users\u\AppData\Local\Programs\type-clipboard-dev\type-clipboard.exe' -InstallDir $Dir }
Test-Case 'パスが読めなければ (管理者で動いているなど) 念のため True' 'True' { Test-TypeClipboardBusyPath -Path $null -InstallDir $Dir }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{
        Exists = $true; Hash = $HashV; Installed = $V; Plan = 'none'; Direction = 'same'
        ShortcutKind = 'ok'; ShortcutTarget = $Exe; BusyCount = 0
    }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Hash = $null; Installed = $null; Plan = 'install'; Direction = 'unknown'; ShortcutKind = 'missing'; ShortcutTarget = $null }
$old = @{ Installed = $Older; Plan = 'change'; Direction = 'up' }

# Get-TypeClipboardExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-TypeClipboardExitCode -State (New-State) }
Test-Case '版が違えば 1' 1 { Get-TypeClipboardExitCode -State (New-State $old) }
Test-Case 'ショートカットが無ければ 1' 1 { Get-TypeClipboardExitCode -State (New-State @{ ShortcutKind = 'missing'; ShortcutTarget = $null }) }
Test-Case 'ショートカットがほかを指していれば 1' 1 { Get-TypeClipboardExitCode -State (New-State @{ ShortcutKind = 'other'; ShortcutTarget = 'C:\x.exe' }) }
Test-Case '入っていなければ 3' 3 { Get-TypeClipboardExitCode -State (New-State $missing) }

# Get-TypeClipboardApplyBlocker: 揃える前に止める理由
Test-Case '入れるだけなら止めない (動いている数は見ない)' '' { Get-TypeClipboardApplyBlocker -Plan install -BusyCount 2 }
Test-Case '入れ替えるのに動いていれば busy' 'busy' { Get-TypeClipboardApplyBlocker -Plan change -BusyCount 1 }
Test-Case '入れ替えでも動いていなければ止めない' '' { Get-TypeClipboardApplyBlocker -Plan change -BusyCount 0 }
Test-Case 'ショートカットを作るだけなら止めない' '' { Get-TypeClipboardApplyBlocker -Plan none -BusyCount 3 }

# Format-TypeClipboardState: 状態の表の行
function Get-Rows { param($State) @(Format-TypeClipboardState -State $State -Target $V -InstallDir $Dir) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 4 行だけ' 4 { (Get-Rows (New-State)).Count }
Test-Case '見出しは取り先と置き場所' "type-clipboard (GitHub の Release、$Dir)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの入っている版の行' "  入っている版     : $V" { (Get-Rows (New-State))[1].Text }
Test-Case '揃っているときの固定した版の行' "  固定した版       : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case '揃っているときのスタートメニューの行' '  スタートメニュー : あり' { (Get-Rows (New-State))[3].Text }
Test-Case '入っていなければ「入っていない」' '  入っている版     : 入っていない' { (Get-Rows (New-State $missing))[1].Text }
Test-Case '入っていなければ「入れる」で ⚠' "⚠ 固定した版       : $V → 入れる" { (Get-Rows (New-State $missing))[2].Text }
Test-Case 'ショートカットが無ければ「作る」で ⚠' '⚠ スタートメニュー : 無し → 作る' { (Get-Rows (New-State $missing))[3].Text }
Test-Case '古い版から上げるとき' "⚠ 固定した版       : $V → 入れ替える (上げる)" { (Get-Rows (New-State $old))[2].Text }
Test-Case '古い版は名前で出す' "  入っている版     : $Older" { (Get-Rows (New-State $old))[1].Text }
Test-Case '新しい版から下げるとき' "⚠ 固定した版       : $V → 入れ替える (下げる)" { (Get-Rows (New-State @{ Installed = $Newer; Plan = 'change'; Direction = 'down' }))[2].Text }
Test-Case '表のどの版でもない exe のとき' '  入っている版     : 不明 (SHA-256 が表のどの版とも合わない)' { (Get-Rows (New-State @{ Hash = $HashOld.Replace('a', 'b'); Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case '置き場所の exe が読めないときは、表と合わないとは言わない' '  入っている版     : 不明 (exe を読めない)' { (Get-Rows (New-State @{ Hash = $null; Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case '表のどの版でもない exe は「入れ替える」(向きは出さない)' "⚠ 固定した版       : $V → 入れ替える" { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[2].Text }
Test-Case 'ショートカットがほかを指していれば、その先を ⚠ で出す' '⚠ スタートメニュー : C:\Users\u\Downloads\type-clipboard.exe を指している → 作り直す' { (Get-Rows (New-State @{ ShortcutKind = 'other'; ShortcutTarget = 'C:\Users\u\Downloads\type-clipboard.exe' }))[3].Text }
Test-Case 'ショートカットの中身が読めなければ、そう出す' '⚠ スタートメニュー : 中身が読めない → 作り直す' { (Get-Rows (New-State @{ ShortcutKind = 'other'; ShortcutTarget = '' }))[3].Text }
Test-Case '入れ替えが要るのに動いていれば ※ で閉じ方を添える (止めはしない)' '※ type-clipboard.exe が 2 個動いている。入れ替えるには、type-clipboard の窓を閉じてから打ち直す (このスクリプトは止めない)' { (Get-Rows (New-State ($old + @{ BusyCount = 2 })))[-1].Text }
Test-Case '入れ替えが要らなければ動いている数は出さない' 4 { (Get-Rows (New-State @{ BusyCount = 2 })).Count }

# ---------------------------------------------------------------------------
# Windows に触らない IO
# ---------------------------------------------------------------------------

$work = Join-Path ([IO.Path]::GetTempPath()) "install-type-clipboard-tests-$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Get-TypeClipboardFileHash: ファイルの SHA-256 (小文字)。読めなければ空
$sample = Join-Path $work 'sample.bin'
[IO.File]::WriteAllBytes($sample, [Text.Encoding]::UTF8.GetBytes('fake type-clipboard 0.1.0'))
Test-Case 'ファイルの SHA-256 を小文字で出す' $HashV { Get-TypeClipboardFileHash -Path $sample }
Test-Case '無いファイルなら空' '' { Get-TypeClipboardFileHash -Path (Join-Path $work 'nothing.bin') }
# PowerShell 7 から起こした Windows PowerShell 5.1 は PSModulePath を継いで 7 の Microsoft.PowerShell.Utility を読み、
# Get-FileHash (5.1 では script の関数) が見つからない (2026-11-10 に pjp-raiden で踏んだ)。その形を偽の関数で作る
Test-Case 'Get-FileHash が見つからない PowerShell でも SHA-256 を出す' $HashV {
    function Get-FileHash { throw "The term 'Get-FileHash' is not recognized as the name of a cmdlet" }
    Get-TypeClipboardFileHash -Path $sample
}

# 本体の入口: Linux の pwsh には $env:LOCALAPPDATA が無く、置き場所を決めるところで例外になる。
# それでも終了コード 2 で止まり、成功 (0) に見せない
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File $ScriptPath -Check 2>&1
    $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Invoke-InstallTypeClipboard の流れ。落とす・ショートカット・プロセスを偽物に差し替え、置き場所は
# 一時ディレクトリに向ける (exe の置き換えと SHA-256 は本物のファイルで確かめる)。ここより後ろでは、
# 差し替えた関数の本物は使えない
# ---------------------------------------------------------------------------

$BytesV = [Text.Encoding]::UTF8.GetBytes('fake type-clipboard 0.1.0')
$BytesOld = [Text.Encoding]::UTF8.GetBytes('fake type-clipboard 0.0.9')
$BytesBad = [Text.Encoding]::UTF8.GetBytes('tampered type-clipboard')
$FlowInstallDir = Join-Path $work 'Programs/type-clipboard'
$FlowShortcutDir = Join-Path $work 'StartMenu'
$FlowExe = Join-Path $FlowInstallDir 'type-clipboard.exe'
$FlowLnk = Join-Path $FlowShortcutDir 'type-clipboard.lnk'

# 表は作り物の exe の値にする (本物の値で落とせる exe はテストに無い)
function Get-TypeClipboardReleases { [ordered]@{ '0.0.9' = $HashOld; '0.1.0' = $HashV } }
# 落とす: 頼まれた URL を記録し、$script:Serve の中身を書く ($script:DownloadError があれば例外。$script:Serve が
# $null なら何も書かない = 落とした物が読めない)
function Invoke-TypeClipboardDownload {
    param([string]$Url, [string]$OutFile)
    $script:Downloads.Add($Url)
    if ($script:DownloadError) { throw $script:DownloadError }
    if ($null -eq $script:Serve) { return }
    [IO.File]::WriteAllBytes($OutFile, $script:Serve)
}
# ショートカット: 指す先を文字で書く・読む (本物は WScript.Shell の COM)
function New-TypeClipboardShortcut {
    param([string]$Path, [string]$Target)
    $script:ShortcutWrites++
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Target)
}
function Get-TypeClipboardShortcutTarget { param([string]$Path) [IO.File]::ReadAllText($Path) }
function Get-TypeClipboardBusyProcess { param([string]$InstallDir) @($script:Busy) }

# 1 回ぶんの流れを走らせ、落とした URL・画面の行・終了コードと、終わった後の置き場所を返す。
#   -Have: 置き場所にある exe の中身 ($null なら無い)。-Link: ショートカットが指す先 ($null なら無い)
#   -Serve: 落とすと返る中身 (-ServeNothing なら何も書かない)。-Busy: 動いている数。-DownloadError: 落とすと出る例外の文
#   -KeepDir: 置き場所を前から作っておき、ほかのファイル keep.txt を置く
#   -Stale・-Fresh: 前の実行が残した途中の物 (1 時間前・今) を置き場所に置く
function Invoke-Flow {
    param(
        [byte[]]$Have, $Link, [byte[]]$Serve = $BytesV, [int]$Busy = 0, [string]$DownloadError = '',
        [string]$Version = $V, [switch]$Check, [switch]$IfMissing,
        [switch]$ServeNothing, [switch]$KeepDir, [switch]$Stale, [switch]$Fresh
    )
    Remove-Item -LiteralPath $FlowInstallDir, $FlowShortcutDir -Recurse -Force -ErrorAction SilentlyContinue
    if (($null -ne $Have) -or $KeepDir -or $Stale -or $Fresh) {
        New-Item -ItemType Directory -Force -Path $FlowInstallDir | Out-Null
    }
    if ($null -ne $Have) {
        [IO.File]::WriteAllBytes($FlowExe, $Have)
    }
    if ($KeepDir) { [IO.File]::WriteAllText((Join-Path $FlowInstallDir 'keep.txt'), 'keep') }
    if ($Stale) {
        $staleFile = Join-Path $FlowInstallDir 'type-clipboard.exe.download-99999'
        [IO.File]::WriteAllText($staleFile, 'stale')
        (Get-Item -LiteralPath $staleFile).LastWriteTime = (Get-Date).AddHours(-1)
    }
    if ($Fresh) { [IO.File]::WriteAllText((Join-Path $FlowInstallDir 'type-clipboard.exe.download-88888'), 'fresh') }
    if ($null -ne $Link) {
        New-Item -ItemType Directory -Force -Path $FlowShortcutDir | Out-Null
        [IO.File]::WriteAllText($FlowLnk, $Link)
    }
    $script:Downloads = [System.Collections.Generic.List[string]]::new()
    $script:Serve = if ($ServeNothing) { $null } else { $Serve }
    $script:DownloadError = $DownloadError
    $script:ShortcutWrites = 0
    $script:Busy = @()
    if ($Busy -gt 0) { $script:Busy = @(1..$Busy | ForEach-Object { [pscustomobject]@{ Id = 1000 + $_; Path = $FlowExe } }) }
    $out = @(Invoke-InstallTypeClipboard -Version $Version -Check:$Check -IfMissing:$IfMissing -InstallDir $FlowInstallDir -ShortcutDir $FlowShortcutDir 6>&1)
    $leftover = @()
    if (Test-Path -LiteralPath $FlowInstallDir) {
        $leftover = @(Get-ChildItem -LiteralPath $FlowInstallDir -Force | Where-Object { $_.Name -ne 'type-clipboard.exe' } | ForEach-Object { $_.Name })
    }
    [pscustomobject]@{
        Code      = @($out | Where-Object { $_ -is [int] })[-1]
        Text      = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Downloads = ($script:Downloads -join ' ')
        ExeHash   = $(if (Test-Path -LiteralPath $FlowExe) { Get-TestSha256 ([IO.File]::ReadAllBytes($FlowExe)) } else { 'none' })
        Link      = $(if (Test-Path -LiteralPath $FlowLnk) { [IO.File]::ReadAllText($FlowLnk) } else { 'none' })
        DirExists = (Test-Path -LiteralPath $FlowInstallDir)
        Leftover  = ($leftover -join ' ')
        LinkWrites = $script:ShortcutWrites
        # パイプラインに出たもの (Write-Host の行を除く) の数。終了コードの 1 つだけのはず
        Outputs   = @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count
    }
}

$url = 'https://github.com/pollenjp/type-clipboard/releases/download/v0.1.0/type-clipboard.exe'

# -Check: 何も落とさず、何も変えない
Test-Case '-Check は入っていなければ 3 で、何も落とさない' '3 [] none none' { $r = Invoke-Flow -Check; "$($r.Code) [$($r.Downloads)] $($r.ExeHash) $($r.Link)" }
Test-Case '-Check は揃っていれば 0' '0 []' { $r = Invoke-Flow -Have $BytesV -Link $FlowExe -Check; "$($r.Code) [$($r.Downloads)]" }
Test-Case '-Check は古い版なら 1 で、入れ替えない' "1 [] $HashOld" { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe -Check; "$($r.Code) [$($r.Downloads)] $($r.ExeHash)" }
Test-Case '-Check はショートカットが無ければ 1 で、作らない' '1 none 0' { $r = Invoke-Flow -Have $BytesV -Check; "$($r.Code) $($r.Link) $($r.LinkWrites)" }
Test-Case '-Check の締めは、入っていなければ入れ方を出す' $true { $r = Invoke-Flow -Check; $r.Text -like '*⚠️ type-clipboard が入っていない → Install-TypeClipboard で入れる ⚠️*' }
Test-Case '-Check の締めは、差があれば揃え方を出す' $true { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe -Check; $r.Text -like '*⚠️ 固定した版と揃っていない → Install-TypeClipboard で揃える ⚠️*' }

# -IfMissing: 入っていないときだけ入れる
Test-Case '-IfMissing は入っていなければ落として置き、ショートカットを作って 0' "0 [$url] $HashV $FlowExe" { $r = Invoke-Flow -IfMissing; "$($r.Code) [$($r.Downloads)] $($r.ExeHash) $($r.Link)" }
Test-Case '-IfMissing で入れた後に、落とした途中の物を残さない' '' { $r = Invoke-Flow -IfMissing; $r.Leftover }
Test-Case '-IfMissing は入っていれば落とさない (古い版でも)' "1 [] $HashOld" { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe -IfMissing; "$($r.Code) [$($r.Downloads)] $($r.ExeHash)" }
Test-Case '-IfMissing は入っていればショートカットも作らない' '1 0' { $r = Invoke-Flow -Have $BytesV -IfMissing; "$($r.Code) $($r.LinkWrites)" }

# 揃える (引数なし)
Test-Case '揃っていれば何もしない' '0 [] 0' { $r = Invoke-Flow -Have $BytesV -Link $FlowExe; "$($r.Code) [$($r.Downloads)] $($r.LinkWrites)" }
Test-Case '古い版を入れ替える' "0 [$url] $HashV" { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe; "$($r.Code) [$($r.Downloads)] $($r.ExeHash)" }
Test-Case '表のどの版でもない exe も入れ替える' "0 [$url] $HashV" { $r = Invoke-Flow -Have $BytesBad -Link $FlowExe; "$($r.Code) [$($r.Downloads)] $($r.ExeHash)" }
Test-Case 'ショートカットだけ無ければ、落とさずに作るだけ' "0 [] $FlowExe" { $r = Invoke-Flow -Have $BytesV; "$($r.Code) [$($r.Downloads)] $($r.Link)" }
Test-Case 'ショートカットがほかを指していれば作り直す' "0 $FlowExe" { $r = Invoke-Flow -Have $BytesV -Link 'C:\Users\u\Downloads\type-clipboard.exe'; "$($r.Code) $($r.Link)" }

# 動いているとき: 止めずに知らせる
Test-Case '入れ替えが要るのに動いていれば、落とさずに止まる (古い版はそのまま)' "1 [] $HashOld" { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe -Busy 2; "$($r.Code) [$($r.Downloads)] $($r.ExeHash)" }
Test-Case '動いていれば、閉じ方と PID を出す' $true { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe -Busy 2; ($r.Text -like '*窓を閉じてから*') -and ($r.Text -like '*1001*') -and ($r.Text -like '*1002*') }
Test-Case '入れるだけなら、動いている別の type-clipboard は気にしない' "0 [$url]" { $r = Invoke-Flow -Busy 1; "$($r.Code) [$($r.Downloads)]" }

# 落とせない・SHA-256 が合わないとき: 何も置かない
Test-Case '落とせなければ 1 で、何も置かない' '1 none' { $r = Invoke-Flow -DownloadError 'The remote name could not be resolved'; "$($r.Code) $($r.ExeHash)" }
Test-Case '落とせなければ、作った置き場所も残さない' 'False' { $r = Invoke-Flow -DownloadError 'timeout'; $r.DirExists }
Test-Case '落とせなければ、わけと何も変えていないことを出す' $true { $r = Invoke-Flow -DownloadError 'The remote name could not be resolved'; ($r.Text -like '*could not be resolved*') -and ($r.Text -like '*何も変えていない*') }
Test-Case '落とせなければ、ショートカットも作らない' '0' { $r = Invoke-Flow -DownloadError 'timeout'; $r.LinkWrites }
Test-Case 'SHA-256 が合わなければ置かない (古い版はそのまま)' "1 $HashOld" { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe -Serve $BytesBad; "$($r.Code) $($r.ExeHash)" }
Test-Case 'SHA-256 が合わなければ、落とした物を残さない' '' { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe -Serve $BytesBad; $r.Leftover }
Test-Case 'SHA-256 が合わなければ、固定した値と落とした物の値を出す' $true { $r = Invoke-Flow -Serve $BytesBad; ($r.Text -like "*$HashV*") -and ($r.Text -like "*$(Get-TestSha256 $BytesBad)*") -and ($r.Text -like '*置かない*') }
Test-Case 'SHA-256 が合わなければ、入っていないときも置かず、置き場所も残さない' '1 none False' { $r = Invoke-Flow -Serve $BytesBad; "$($r.Code) $($r.ExeHash) $($r.DirExists)" }

# 前からある置き場所 (中にほかのファイル) は、入れられなくても消さない (消すのは、この実行で作った置き場所だけ)
Test-Case '前からある置き場所は、落とせなくても消さない (中のほかのファイルも)' '1 True keep.txt' { $r = Invoke-Flow -KeepDir -DownloadError 'timeout'; "$($r.Code) $($r.DirExists) $($r.Leftover)" }
Test-Case '前からある置き場所は、SHA-256 が合わなくても消さない' '1 True keep.txt' { $r = Invoke-Flow -KeepDir -Serve $BytesBad; "$($r.Code) $($r.DirExists) $($r.Leftover)" }

# 落とした物が読めない・Release に無い (404) ときは、そのわけを出す
Test-Case '落とした物が読めなければ、Release の差し替えや表の誤りとは言わない' $true { $r = Invoke-Flow -ServeNothing; ($r.Code -eq 1) -and ($r.Text -like '*落とした物を読めなかった*') -and ($r.Text -notlike '*差し替えられた*') -and ($r.Leftover -eq '') }
Test-Case '落とせないときは、ネットワークだけでなく URL (Release の版と exe の名前) も確かめるよう出す' $true { $r = Invoke-Flow -DownloadError 'Response status code does not indicate success: 404 (Not Found).'; ($r.Text -like '*404 (Not Found)*') -and ($r.Text -like '*上の URL (Release の版と exe の名前)*') }

# 止められた前の実行が残した途中の物は、古ければ消す (同時に走っている実行の物は残す)
Test-Case '前の実行が残した古い途中の物は消し、新しいものは残す' '0 type-clipboard.exe.download-88888' { $r = Invoke-Flow -Stale -Fresh -IfMissing; "$($r.Code) $($r.Leftover)" }

# パイプラインに出すのは終了コードの 1 つだけ (本体の exit (…) に配列を渡さない)
Test-Case 'どの流れでも、パイプラインに出すのは終了コードの 1 つだけ' '1 1 1 1 1 1' {
    @((Invoke-Flow -Check).Outputs, (Invoke-Flow -IfMissing).Outputs, (Invoke-Flow -Have $BytesOld -Link $FlowExe).Outputs,
        (Invoke-Flow -Have $BytesOld -Link $FlowExe -Busy 1).Outputs, (Invoke-Flow -DownloadError 'x').Outputs, (Invoke-Flow -Serve $BytesBad).Outputs)
}

# 置き場所を相対パスで渡しても、今の場所 (PowerShell の location) から解く ([IO.File] はプロセスの作業ディレクトリで解くため)
Test-Case '置き場所を相対パスで渡しても、今の場所から解いて入れ、ショートカットは絶対パスを指す' $true {
    $rel = Join-Path $work 'rel'
    Remove-Item -LiteralPath $rel -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $rel | Out-Null
    $script:Downloads = [System.Collections.Generic.List[string]]::new()
    $script:Serve = $BytesV
    $script:DownloadError = ''
    $script:ShortcutWrites = 0
    $script:Busy = @()
    Push-Location -LiteralPath $rel
    try {
        $out = @(Invoke-InstallTypeClipboard -Version $V -IfMissing -InstallDir 'Programs/type-clipboard' -ShortcutDir 'StartMenu' 6>&1)
    } finally {
        Pop-Location
    }
    $relExe = Join-Path $rel 'Programs/type-clipboard/type-clipboard.exe'
    $code = @($out | Where-Object { $_ -is [int] })[-1]
    ($code -eq 0) -and ((Get-TestSha256 ([IO.File]::ReadAllBytes($relExe))) -eq $HashV) -and ([IO.File]::ReadAllText((Join-Path $rel 'StartMenu/type-clipboard.lnk')) -eq $relExe)
}

# ショートカットだけ作れなかったとき: exe は置き、わけを出して 1 (読み直した表でスタートメニューが ⚠)
function New-TypeClipboardShortcut { param([string]$Path, [string]$Target) $script:ShortcutWrites++; throw 'Exception from HRESULT: 0x80070005 (E_ACCESSDENIED)' }
Test-Case 'ショートカットだけ作れなければ、exe は置いて 1 を返し、わけを出す' $true { $r = Invoke-Flow -IfMissing; ($r.Code -eq 1) -and ($r.ExeHash -eq $HashV) -and ($r.Text -like '*ショートカットを置けなかった: *E_ACCESSDENIED*') -and ($r.Text -like '*⚠ スタートメニュー : 無し → 作る*') }
# 偽物を元に戻す
function New-TypeClipboardShortcut {
    param([string]$Path, [string]$Target)
    $script:ShortcutWrites++
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Target)
}

# 置き換えが落ちたとき (落とした後に起動された、など): 落とした物を残さずに止まる
function Move-TypeClipboardFile { param([string]$Source, [string]$Destination) throw 'The process cannot access the file because it is being used by another process.' }
Test-Case '置き換えが落ちたら 1 で、古い版はそのまま' "1 $HashOld" { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe; "$($r.Code) $($r.ExeHash)" }
Test-Case '置き換えが落ちたら、落とした物を残さず、閉じ方を出す' $true { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe; ($r.Leftover -eq '') -and ($r.Text -like '*being used by another process*') -and ($r.Text -like '*窓を閉じて*') }

# 置き換えの途中 (古い exe を消した後) で落ちたとき (5.1 の Move-Item -Force は置き先を消してから名前を変える): 消えたと出す
function Move-TypeClipboardFile { param([string]$Source, [string]$Destination) Remove-Item -LiteralPath $Destination -Force; throw 'The process cannot access the file because it is being used by another process.' }
Test-Case '古い exe を消したあとで置き換えが落ちたら、消えたことと入れ直し方を出す (何も変えていないとは言わない)' $true { $r = Invoke-Flow -Have $BytesOld -Link $FlowExe; ($r.Code -eq 1) -and ($r.ExeHash -eq 'none') -and ($r.Text -like '*消えた*') -and ($r.Text -notlike '*何も変えていない*') -and ($r.Leftover -eq '') }

# 表に無い版
Test-Case '表に無い版を渡すと、何も見ずに 2' '2 []' { $r = Invoke-Flow -Version '9.9.9'; "$($r.Code) [$($r.Downloads)]" }
Test-Case '表に無い版を渡すと、表にある版を出す' $true { $r = Invoke-Flow -Version '9.9.9'; ($r.Text -like '*9.9.9*') -and ($r.Text -like '*0.1.0*') }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
