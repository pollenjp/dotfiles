# win/op-reason/Install-OpReason.ps1 のテスト。Pester は使わない (Install-TypeClipboard.Tests.ps1 と同じ作り)。
# 副作用の無い関数と、ファイルに触る関数 (中身の値・zip の展開・置き場所の入れ替え) を一時ディレクトリで、ネットワークと
# Windows に触る関数 (落とす・動いているプロセス・SSH の中継の task・--status・op-reason の lock) を偽物に差し替えた流れで
# 確かめる。落とす・動いているかを見る本物の部分は、実機で置き場所を一時ディレクトリに向けて確かめる (win/README.md の
# 「op-reason」)。本物の Task Scheduler と中継は、実機の確かめ (win/README.md の「SSH の中継」) で見る。
#
# WSL から流す (Linux の pwsh で動かすので、Windows 側には触らない):
#   nix shell nixpkgs#powershell -c pwsh -NoProfile -File win/op-reason/Install-OpReason.Tests.ps1
#
# BOM 付きの UTF-8 で保存すること (win/README.md の「dotfiles.ps1 を書くときの注意」)。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptPath = Join-Path $PSScriptRoot 'Install-OpReason.ps1'

# dot-source すると関数だけを読み、本体は走らない (Install-OpReason.ps1 の末尾)
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
function Get-TestTextSha256 { param([string]$Text) Get-TestSha256 ([Text.Encoding]::UTF8.GetBytes($Text)) }

# 中身 (相対パスと文字の組) の Tree を、関数を通さずに作る。並べ替えはせず、渡した順 (序数の順に並べて渡す) に行を作る
function Get-TestTree {
    param([object[]]$Files)
    $text = -join ($Files | ForEach-Object { "$(Get-TestTextSha256 $_[1])  $($_[0])`n" })
    Get-TestTextSha256 $text
}

$V = '0.1.0'
$Older = '0.0.9'
$Newer = '0.2.0'
$Dir = 'C:\Users\u\AppData\Local\Programs\op-reason'
$Exe = "$Dir\op-reason.exe"

# ---------------------------------------------------------------------------
# 表と落とす先
# ---------------------------------------------------------------------------

# Get-OpReasonReleases: 版ごとの zip の SHA-256 (Release の op-reason-windows.zip.sha256 の中身) と、展開した中身の値
Test-Case '0.1.0 の Zip は Release の op-reason-windows.zip.sha256 と同じ値' '4b664af358559faf8e94a1142f579236846d75a8e6698dee66dbf35bb0335fb0' { (Get-OpReasonReleases)['0.1.0'].Zip }
Test-Case '0.1.0 の Tree は Release の zip を展開した中身の値' 'b2b09e1c101a7b1da0a9facd81cac8f18ad4018d9a34ecac04db38133d9e796a' { (Get-OpReasonReleases)['0.1.0'].Tree }
Test-Case '0.2.0 の Zip は Release の op-reason-windows.zip.sha256 と同じ値' '6e9a104484a019da093726d0bad2ee3da7cedb2e238a592e12c67dcc2336dbf3' { (Get-OpReasonReleases)['0.2.0'].Zip }
Test-Case '0.2.0 の Tree は Release の zip を展開した中身の値' '5ced1fd007b3a92b3bc3539915babdb14c9064548dbb176031427b004342619b' { (Get-OpReasonReleases)['0.2.0'].Tree }
Test-Case '0.3.0 の Zip は Release の op-reason-windows.zip.sha256 と同じ値' '28bf706c426fbd3a64097aab8082bd26fda2b9b281cf5bbbfb22b3142bd4d7e1' { (Get-OpReasonReleases)['0.3.0'].Zip }
Test-Case '0.3.0 の Tree は Release の zip を展開した中身の値' 'db5677cc7535d97f78d3a9355dac60d22a92aa1fb02b9f771242b4552b57eb5a' { (Get-OpReasonReleases)['0.3.0'].Tree }
Test-Case '0.4.0 の Zip は Release の op-reason-windows.zip.sha256 と同じ値' '557ac348182f9adcddb1697db9f8820e551bf7abd7fc0ee0181a766cd543f3db' { (Get-OpReasonReleases)['0.4.0'].Zip }
Test-Case '0.4.0 の Tree は Release の zip を展開した中身の値' 'ccb6f0aa1380d4ae0257273d992cd6859b8189b57d0783a32d0aaf8b700730ee' { (Get-OpReasonReleases)['0.4.0'].Tree }
Test-Case '0.5.0 の Zip は Release の op-reason-windows.zip.sha256 と同じ値' 'ff7c40063b0201e5d0e66c1ed495047c479d5c5eaad21ce1c42889328b15826e' { (Get-OpReasonReleases)['0.5.0'].Zip }
Test-Case '0.5.0 の Tree は Release の zip を展開した中身の値' '7d72ad737aa4b9c87ed325b969fba1f9761cf0fa6cdddbff12edc197e5f20d66' { (Get-OpReasonReleases)['0.5.0'].Tree }
Test-Case '0.6.0 の Zip は Release の op-reason-windows.zip.sha256 と同じ値' '0a0ee1e06e3be572a2fc7b4e3e8eea199484410f063a992a4ed6d48581e14c41' { (Get-OpReasonReleases)['0.6.0'].Zip }
Test-Case '0.6.0 の Tree は Release の zip を展開した中身の値' '1a3d3ff97d38f7a2056b1295c5d62320e61dcb3f9b3ef8ea3061344a7eec4141' { (Get-OpReasonReleases)['0.6.0'].Tree }
Test-Case '0.7.0 の Zip は Release の op-reason-windows.zip.sha256 と同じ値' '998ce5648effca76c13b6851f237ad4297b56be20966ec9d70124353f43ea56d' { (Get-OpReasonReleases)['0.7.0'].Zip }
Test-Case '0.7.0 の Tree は Release の zip を展開した中身の値' '66643719adc0505c3b64010f573f8be56cc57ee1da652e42ce115502c8511dfc' { (Get-OpReasonReleases)['0.7.0'].Tree }
Test-Case '表のどの版にも Zip と Tree がある' 0 { @((Get-OpReasonReleases).Values | Where-Object { -not ($_.Zip -and $_.Tree) }).Count }
Test-Case '表の値はどれも 64 桁の小文字の 16 進' 0 { @((Get-OpReasonReleases).Values | ForEach-Object { $_.Zip; $_.Tree } | Where-Object { "$_" -cnotmatch '^[0-9a-f]{64}$' }).Count }
Test-Case '表の版はどれも X.Y.Z' 0 { @((Get-OpReasonReleases).Keys | Where-Object { "$_" -notmatch '^\d+\.\d+\.\d+$' }).Count }

# -Version の既定値 (固定した版) が表にある。既定値は param の AST から読む (関数からは見えない)
function Get-DefaultVersion {
    $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Version' }
    $param.DefaultValue.Value
}
Test-Case '-Version の既定値は表にある' 'True' { (Get-OpReasonReleases).Contains((Get-DefaultVersion)) }
# WSL の実行ファイル (repo の nix/pkgs/op-reason/default.nix の version) と同じ版にそろえる (呼び出しの取り決めが変わった版どうしでは断られる)
Test-Case '-Version の既定値は、WSL の nix/pkgs/op-reason/default.nix の version と同じ' 'True' {
    $nix = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../nix/pkgs/op-reason/default.nix'))
    $m = [regex]::Match($nix, '(?m)^\s*version = "([^"]+)";')
    $m.Success -and ($m.Groups[1].Value -ceq (Get-DefaultVersion))
}

# Get-OpReasonDownloadUrl: 版ごとの Release の zip
Test-Case '落とす先は版の tag の Release の op-reason-windows.zip' 'https://github.com/pollenjp/op-reason/releases/download/v0.1.0/op-reason-windows.zip' { Get-OpReasonDownloadUrl -Version $V }

# ---------------------------------------------------------------------------
# 中身の値 (Tree) の作り方
# ---------------------------------------------------------------------------

$H1 = '1' * 64
$H2 = '2' * 64
$H3 = '3' * 64
$H4 = '4' * 64

# Get-OpReasonTreeText: sha256sum の行を、相対パスの序数の順に並べる (大文字が小文字より先、. が / より先)
Test-Case '行は「SHA-256␣␣相対パス」で、相対パスの序数の順に並び、どの行も LF で終わる' "$H2  README.md`n$H1  launcher.ps1`n$H4  op-reason.exe`n$H3  powershell-entry/op-reason.ps1`n" {
    Get-OpReasonTreeText -Entries @{ 'launcher.ps1' = $H1; 'README.md' = $H2; 'powershell-entry/op-reason.ps1' = $H3; 'op-reason.exe' = $H4 }
}
Test-Case '並びは文化の順ではなく序数の順 (B が a より先)' "$H2  B`n$H1  a`n" { Get-OpReasonTreeText -Entries @{ 'a' = $H1; 'B' = $H2 } }
Test-Case '. は / より先 (LC_ALL=C の sort と同じ)' "$H1  a.b`n$H2  a/b`n" { Get-OpReasonTreeText -Entries @{ 'a/b' = $H2; 'a.b' = $H1 } }
Test-Case '大文字の 16 進は小文字にする' "$('ab' * 32)  x`n" { Get-OpReasonTreeText -Entries @{ 'x' = ('AB' * 32) } }
Test-Case '中身が無ければ空' '' { Get-OpReasonTreeText -Entries @{} }

# Get-OpReasonTextHash: UTF-8 (BOM なし) の SHA-256
Test-Case 'abc の SHA-256' 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' { Get-OpReasonTextHash -Text 'abc' }
Test-Case '空の文字列の SHA-256' 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' { Get-OpReasonTextHash -Text '' }
Test-Case '日本語は BOM なしの UTF-8 で数える' (Get-TestSha256 ([byte[]](0xe7, 0x90, 0x86, 0xe7, 0x94, 0xb1))) { Get-OpReasonTextHash -Text '理由' }

# ---------------------------------------------------------------------------
# 版と plan
# ---------------------------------------------------------------------------

$TreeOld9 = 'a' * 64
$TreeV1 = 'b' * 64
$FindTable = [ordered]@{ $Older = @{ Zip = $H1; Tree = $TreeOld9 }; $V = @{ Zip = $H2; Tree = $TreeV1 } }

# Find-OpReasonVersion: 中身の値から表の版を引く
Test-Case '中身の値が表にあればその版' $V { Find-OpReasonVersion -Releases $FindTable -Tree $TreeV1 }
Test-Case '古い版の値なら古い版' $Older { Find-OpReasonVersion -Releases $FindTable -Tree $TreeOld9 }
Test-Case '大文字の 16 進でも引ける' $V { Find-OpReasonVersion -Releases $FindTable -Tree $TreeV1.ToUpperInvariant() }
Test-Case 'zip の値では引かない (中身の値だけを見る)' '' { Find-OpReasonVersion -Releases $FindTable -Tree $H2 }
Test-Case '表に無い値なら空' '' { Find-OpReasonVersion -Releases $FindTable -Tree ('0' * 64) }
Test-Case '値が空なら空' '' { Find-OpReasonVersion -Releases $FindTable -Tree '' }

# Test-OpReasonHashMatch: SHA-256 が固定した値と同じか
Test-Case '同じなら True' 'True' { Test-OpReasonHashMatch -Expected $H1 -Actual $H1 }
Test-Case '大文字小文字だけの違いは True' 'True' { Test-OpReasonHashMatch -Expected $TreeV1 -Actual $TreeV1.ToUpperInvariant() }
Test-Case '違えば False' 'False' { Test-OpReasonHashMatch -Expected $H1 -Actual $H2 }
Test-Case '出せなければ (空) False' 'False' { Test-OpReasonHashMatch -Expected $H1 -Actual '' }
Test-Case '固定した値が空なら False (空どうしを同じと見ない)' 'False' { Test-OpReasonHashMatch -Expected '' -Actual '' }

# Get-OpReasonPlan: することを決める
Test-Case '入っていなければ install' 'install' { Get-OpReasonPlan -Exists $false -Installed $null -Target $V }
Test-Case '同じ版なら none' 'none' { Get-OpReasonPlan -Exists $true -Installed $V -Target $V }
Test-Case '違う版なら change' 'change' { Get-OpReasonPlan -Exists $true -Installed $Older -Target $V }
Test-Case '置き場所があるのに表のどの版でもなければ change' 'change' { Get-OpReasonPlan -Exists $true -Installed $null -Target $V }

# Get-OpReasonDirection: 入れ替えの向き (版を [version] で比べる)
Test-Case '固定した版が新しければ up' 'up' { Get-OpReasonDirection -Installed $Older -Target $V }
Test-Case '固定した版が古ければ down' 'down' { Get-OpReasonDirection -Installed $Newer -Target $V }
Test-Case '同じなら same' 'same' { Get-OpReasonDirection -Installed $V -Target $V }
Test-Case '入っている版が分からなければ unknown' 'unknown' { Get-OpReasonDirection -Installed $null -Target $V }
Test-Case '版の形でなければ unknown' 'unknown' { Get-OpReasonDirection -Installed '0.1.0-rc1' -Target $V }
Test-Case '0.10.0 は 0.9.0 より新しい (文字列で比べない)' 'up' { Get-OpReasonDirection -Installed '0.9.0' -Target '0.10.0' }

# Test-OpReasonBusyPath: 動いている op-reason.exe が置き場所のものか (入れ替えの邪魔になるか)
Test-Case '置き場所の exe なら True' 'True' { Test-OpReasonBusyPath -Path $Exe -InstallDir $Dir }
Test-Case '大文字小文字が違っても True' 'True' { Test-OpReasonBusyPath -Path $Exe.ToUpperInvariant() -InstallDir $Dir }
Test-Case '置き場所の末尾に \ があっても True' 'True' { Test-OpReasonBusyPath -Path $Exe -InstallDir "$Dir\" }
Test-Case '置き場所の下のディレクトリの exe も True' 'True' { Test-OpReasonBusyPath -Path "$Dir\powershell-entry\x.exe" -InstallDir $Dir }
Test-Case 'ほかの場所の exe なら False' 'False' { Test-OpReasonBusyPath -Path 'C:\Users\u\Downloads\op-reason.exe' -InstallDir $Dir }
Test-Case '名前が前方一致するだけのディレクトリは False' 'False' { Test-OpReasonBusyPath -Path 'C:\Users\u\AppData\Local\Programs\op-reason-dev\op-reason.exe' -InstallDir $Dir }
Test-Case 'パスが読めなければ (管理者で動いているなど) 念のため True' 'True' { Test-OpReasonBusyPath -Path $null -InstallDir $Dir }

# Test-OpReasonLeftoverName: 前の実行が残した途中の物か
Test-Case '落とした zip は途中の物' 'True' { Test-OpReasonLeftoverName -Name 'op-reason.download-123.zip' -Leaf 'op-reason' }
Test-Case '展開した物は途中の物' 'True' { Test-OpReasonLeftoverName -Name 'op-reason.new-123' -Leaf 'op-reason' }
Test-Case '前の中身は途中の物' 'True' { Test-OpReasonLeftoverName -Name 'op-reason.old-123' -Leaf 'op-reason' }
Test-Case '置き場所そのものは途中の物ではない' 'False' { Test-OpReasonLeftoverName -Name 'op-reason' -Leaf 'op-reason' }
Test-Case '名前が前方一致するだけのものは途中の物ではない' 'False' { Test-OpReasonLeftoverName -Name 'op-reason-dev' -Leaf 'op-reason' }
Test-Case 'ほかのアプリの物は途中の物ではない' 'False' { Test-OpReasonLeftoverName -Name 'type-clipboard' -Leaf 'op-reason' }

# 状態の既定 (揃っている)。テストごとに一部を差し替える
function New-State {
    param([hashtable]$Change = @{})
    $s = [ordered]@{ Exists = $true; Tree = $TreeV1; Installed = $V; Plan = 'none'; Direction = 'same'; BusyCount = 0 }
    foreach ($k in $Change.Keys) { $s[$k] = $Change[$k] }
    [pscustomobject]$s
}
$missing = @{ Exists = $false; Tree = $null; Installed = $null; Plan = 'install'; Direction = 'unknown' }
$old = @{ Installed = $Older; Tree = $TreeOld9; Plan = 'change'; Direction = 'up' }

# Get-OpReasonExitCode: 終了コード
Test-Case '揃っていれば 0' 0 { Get-OpReasonExitCode -State (New-State) }
Test-Case '版が違えば 1' 1 { Get-OpReasonExitCode -State (New-State $old) }
Test-Case '表のどの版でもなければ 1' 1 { Get-OpReasonExitCode -State (New-State @{ Installed = $null; Tree = $H3; Plan = 'change'; Direction = 'unknown' }) }
Test-Case '入っていなければ 3' 3 { Get-OpReasonExitCode -State (New-State $missing) }

# Format-OpReasonState: 状態の表の行
function Get-Rows { param($State) @(Format-OpReasonState -State $State -Target $V -InstallDir $Dir) }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-Rows (New-State)) | Where-Object { $_.Warn }).Count }
Test-Case '揃っていれば表の 3 行だけ' 3 { (Get-Rows (New-State)).Count }
Test-Case '見出しは取り先と置き場所' "op-reason (GitHub の Release、$Dir)" { (Get-Rows (New-State))[0].Text }
Test-Case '揃っているときの入っている版の行' "  入っている版     : $V" { (Get-Rows (New-State))[1].Text }
Test-Case '揃っているときの固定した版の行' "  固定した版       : $V → そのまま" { (Get-Rows (New-State))[2].Text }
Test-Case '入っていなければ「入っていない」' '  入っている版     : 入っていない' { (Get-Rows (New-State $missing))[1].Text }
Test-Case '入っていなければ「入れる」で ⚠' "⚠ 固定した版       : $V → 入れる" { (Get-Rows (New-State $missing))[2].Text }
Test-Case '古い版から上げるとき' "⚠ 固定した版       : $V → 入れ替える (上げる)" { (Get-Rows (New-State $old))[2].Text }
Test-Case '古い版は名前で出す' "  入っている版     : $Older" { (Get-Rows (New-State $old))[1].Text }
Test-Case '新しい版から下げるとき' "⚠ 固定した版       : $V → 入れ替える (下げる)" { (Get-Rows (New-State @{ Installed = $Newer; Plan = 'change'; Direction = 'down' }))[2].Text }
Test-Case '表のどの版でもない中身のとき' '  入っている版     : 不明 (中身が表のどの版とも合わない)' { (Get-Rows (New-State @{ Tree = $H3; Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case '中身が読めないときは、表と合わないとは言わない' '  入っている版     : 不明 (中身を読めない)' { (Get-Rows (New-State @{ Tree = $null; Installed = $null; Plan = 'change'; Direction = 'unknown' }))[1].Text }
Test-Case '表のどの版でもない中身は「入れ替える」(向きは出さない)' "⚠ 固定した版       : $V → 入れ替える" { (Get-Rows (New-State @{ Installed = $null; Plan = 'change'; Direction = 'unknown' }))[2].Text }
Test-Case '入れ替えが要るのに動いていれば ※ で待ち方を添える (止めはしない)' '※ op-reason.exe が 2 個動いている (op の呼び出しの途中)。入れ替えるには、その呼び出しが終わってから打ち直す (このスクリプトは止めない)' { (Get-Rows (New-State ($old + @{ BusyCount = 2 })))[-1].Text }
Test-Case '入れ替えが要らなければ動いている数は出さない' 3 { (Get-Rows (New-State @{ BusyCount = 2 })).Count }
Test-Case '動いているのが task の中継だけなら、※ で止めて起こし直すことを添える' '※ 動いている op-reason.exe は SSH の中継だけ。入れ替えるときは中継を止め、入れ替えてから起こし直す (中継が窓を開いていれば止めない)' {
    (@(Format-OpReasonState -State (New-State ($old + @{ BusyCount = 1 })) -Target $V -InstallDir $Dir -BusyNote 'relay'))[-1].Text
}

# ---------------------------------------------------------------------------
# SSH の中継 (op-reason の task と前の task)
# ---------------------------------------------------------------------------

$Sid = 'S-1-5-21-1-2-3-1001'

# 名前と、--settings を持つ版
Test-Case '前の task は \pjp\op-reason-ssh-relay' '\pjp\ op-reason-ssh-relay' { $i = Get-OpReasonLegacyTaskId; "$($i.Path) $($i.Name)" }
Test-Case 'op-reason の task は root の op-reason-ssh-relay-<SID> (op-reason の設計 §9.1)' "op-reason-ssh-relay-$Sid" { Get-OpReasonOwnTaskName -Sid $Sid }
Test-Case '--settings は 0.7.0 から (0.10.0 は新しい。空・読めない版は持たないと見る)' 'True True False False False False' {
    @('0.7.0', '0.10.0', '0.6.0', '0.1.0', '', 'x') | ForEach-Object { Test-OpReasonSettingsVersion -Installed $_ }
}

# Get-OpReasonSettingsArguments: op-reason の設計 §18 の CLI
Test-Case 'check は 3 つの値と --json' '--settings check relay.autostart=on relay.mode=show-only relay.running=on --json' { Get-OpReasonSettingsArguments -Act 'check' -Mode 'show-only' }
Test-Case 'set は同じ 3 つの値' '--settings set relay.autostart=on relay.mode=per-call relay.running=on' { Get-OpReasonSettingsArguments -Act 'set' -Mode 'per-call' }
Test-Case 'off は relay.autostart=off だけ' '--settings set relay.autostart=off' { Get-OpReasonSettingsArguments -Act 'off' }
Test-Case '入れ替えの前後は relay stop と relay start' '--settings relay stop / --settings relay start' { "$(Get-OpReasonSettingsArguments -Act 'stop') / $(Get-OpReasonSettingsArguments -Act 'start')" }
Test-Case '持ち主を読むのは get relay.running --json' '--settings get relay.running --json' { Get-OpReasonSettingsArguments -Act 'running' }

# op-reason の --json の 1 行 (op-reason の crates/op-reason-core/src/settings/cli.rs の形。check は項目に wanted と same を足す)
function New-SettingItem {
    param([string]$Name, $Value, [string]$State = 'ok', [hashtable]$Detail = @{}, [string]$Wanted = '', [bool]$Same = $true)
    [pscustomobject]@{ name = $Name; kind = 'system'; value = $Value; default = $null; state = $State; detail = [pscustomobject]$Detail; where = ''; wanted = $Wanted; same = $Same }
}
function New-SettingsJson {
    param([object[]]$Items, $Same = $null)
    $o = [ordered]@{ v = 1 }
    if ($null -ne $Same) { $o['same'] = [bool]$Same }
    $o['settings'] = @($Items)
    [pscustomobject]$o | ConvertTo-Json -Compress -Depth 5
}
$ItAutoOff = New-SettingItem 'relay.autostart' 'off' -Wanted 'on' -Same $false
$ItMode = New-SettingItem 'relay.mode' 'per-call' -Wanted 'per-call'
$ItRunLegacy = New-SettingItem 'relay.running' 'on' 'running' @{ pid = 4242; ours = $false; by = '\pjp\op-reason-ssh-relay' } -Wanted 'on'
$CkDiff = New-SettingsJson -Items @($ItAutoOff, $ItMode, $ItRunLegacy) -Same $false

# ConvertFrom-OpReasonSettingsCheck: 0 同じ・1 違う・2 読めない (op-reason の設計 §7.3)
Test-Case 'check が 1 なら different で、項目を読む' 'different relay.autostart relay.mode relay.running' {
    $c = ConvertFrom-OpReasonSettingsCheck -Code 1 -Lines @($CkDiff); "$($c.Status) $(@($c.Items | ForEach-Object { $_.Name }) -join ' ')"
}
Test-Case '項目の値・望み・同じか・state' 'off on False ok / on True running 4242' {
    $c = ConvertFrom-OpReasonSettingsCheck -Code 1 -Lines @($CkDiff)
    "$($c.Items[0].Value) $($c.Items[0].Wanted) $($c.Items[0].Same) $($c.Items[0].State) / $($c.Items[2].Value) $($c.Items[2].Same) $($c.Items[2].State) $($c.Items[2].Detail.pid)"
}
Test-Case 'check が 0 で JSON の same も true なら same' 'same' { (ConvertFrom-OpReasonSettingsCheck -Code 0 -Lines @((New-SettingsJson -Items @($ItMode) -Same $true))).Status }
Test-Case 'JSON の前後にほかの行があっても読む' 'different' { (ConvertFrom-OpReasonSettingsCheck -Code 1 -Lines @('', $CkDiff, 'x')).Status }
Test-Case '終了コードと JSON の same が食い違えば unknown' 'unknown' { (ConvertFrom-OpReasonSettingsCheck -Code 0 -Lines @($CkDiff)).Status }
Test-Case '2 (読めない) なら unknown で、読めなかった設定の error を添える' $true {
    $bad = New-SettingItem 'relay.autostart' $null 'unreadable' @{ error = 'Task Scheduler: access denied' } -Wanted 'on' -Same $false
    $c = ConvertFrom-OpReasonSettingsCheck -Code 2 -Lines @((New-SettingsJson -Items @($bad) -Same $false))
    ($c.Status -eq 'unknown') -and ($c.Why -like '*終了コード 2*') -and ($c.Why -like '*relay.autostart: Task Scheduler: access denied*')
}
Test-Case '起こせなければ unknown で、わけを添える' 'unknown / op-reason.exe を起こせなかった: blocked' {
    $c = ConvertFrom-OpReasonSettingsCheck -Code $null -Failure 'blocked'; "$($c.Status) / $($c.Why)"
}
Test-Case 'JSON が無ければ unknown (0.6.0 までの exe なら --settings を op に回す)' $true {
    $c = ConvertFrom-OpReasonSettingsCheck -Code 1 -Lines @('[ERROR] unknown flag: --settings'); ($c.Status -eq 'unknown') -and ($c.Why -like '*JSON を読めなかった*')
}

# ConvertFrom-OpReasonRelayRunning・Get-OpReasonRelayOwner: 答えている中継の持ち主 (op-reason が決めた ours と by)
function Get-OwnerText {
    param([hashtable]$Detail, [string]$Value = 'on', [string]$State = 'running', $Code = 0)
    $o = ConvertFrom-OpReasonRelayRunning -Code $Code -Lines @((New-SettingsJson -Items @((New-SettingItem 'relay.running' $Value $State $Detail))))
    "$($o.Owner) $($o.Pid)"
}
Test-Case 'op-reason の task の中継なら own と PID' 'own 4242' { Get-OwnerText @{ pid = 4242; ours = $true; by = $null } }
Test-Case '前の task が起こした中継なら legacy' 'legacy 4242' { Get-OwnerText @{ pid = 4242; ours = $false; by = '\pjp\op-reason-ssh-relay' } }
Test-Case 'task の名前の大文字小文字は問わない' 'legacy 4242' { Get-OwnerText @{ pid = 4242; ours = $false; by = '\PJP\op-reason-ssh-relay' } }
Test-Case 'ほかの task や端末が起こした中継なら other' 'other 4242 / other 4242' {
    "$(Get-OwnerText @{ pid = 4242; ours = $false; by = $null }) / $(Get-OwnerText @{ pid = 4242; ours = $false; by = '\other\task' })"
}
Test-Case '答える中継が無ければ none' 'none ' { Get-OwnerText @{} -Value 'off' -State 'task-off' }
Test-Case '読めなければ unknown (終了コード 2・起こせない・JSON が無い)' 'unknown  / unknown  / unknown ' {
    $a = Get-OwnerText @{} -Value $null -State 'unreadable' -Code 2
    $b = ConvertFrom-OpReasonRelayRunning -Code $null
    $c = ConvertFrom-OpReasonRelayRunning -Code 0 -Lines @('x')
    "$a / $($b.Owner) $($b.Pid) / $($c.Owner) $($c.Pid)"
}
Test-Case 'check の relay.running の項目からも同じに読む' 'legacy 4242' {
    $c = ConvertFrom-OpReasonSettingsCheck -Code 1 -Lines @($CkDiff)
    $o = Get-OpReasonRelayOwner -Item ($c.Items | Where-Object { $_.Name -eq 'relay.running' })
    "$($o.Owner) $($o.Pid)"
}

# Get-OpReasonRelayPlan: 中継にすること (Legacy/Own)
$TaskRun = [pscustomobject]@{ State = 'Running'; Enabled = $true }
$TaskReady = [pscustomobject]@{ State = 'Ready'; Enabled = $true }
$TaskOff = [pscustomobject]@{ State = 'Disabled'; Enabled = $false }
$CkSame = [pscustomobject]@{ Status = 'same'; Items = @(); Why = '' }
$CkDifferent = [pscustomobject]@{ Status = 'different'; Items = @(); Why = '' }
$CkUnknown = [pscustomobject]@{ Status = 'unknown'; Items = @(); Why = 'x' }
function Get-PlanText {
    param([string]$Want = 'per-call', [bool]$InScope = $true, $Own = $null, $Legacy = $null, [bool]$Capable = $true, $Check = $null)
    $p = Get-OpReasonRelayPlan -Want $Want -InScope $InScope -OwnTask $Own -LegacyTask $Legacy -Capable $Capable -Check $Check
    "$($p.Legacy)/$($p.Own)"
}
Test-Case '渡さなければ (WSL の setup・手で打つとき) task があっても何もしない' 'none/none' { Get-PlanText -Want '' -Own $TaskRun -Legacy $TaskRun -Check $CkDifferent }
Test-Case '置き場所が既定でなければ何もしない' 'none/none' { Get-PlanText -InScope $false -Legacy $TaskRun -Check $CkDifferent }
Test-Case 'モードで check が同じで前の task が無ければ何もしない' 'none/none' { Get-PlanText -Own $TaskRun -Check $CkSame }
Test-Case 'モードで check が違えば set' 'none/set' { Get-PlanText -Check $CkDifferent }
Test-Case 'モードで前の task があれば、check が同じでも消して set (答えている中継は前の task のもの)' 'remove/set' { Get-PlanText -Legacy $TaskRun -Check $CkSame }
Test-Case 'モードで check を打っていなければ (入れる・入れ替える・--settings を持たない) after-swap' 'remove/after-swap remove/after-swap' {
    (Get-PlanText -Legacy $TaskRun -Capable $false), (Get-PlanText -Legacy $TaskRun -Capable $true -Check $null)
}
Test-Case 'モードで check が読めなければ unknown' 'none/unknown' { Get-PlanText -Check $CkUnknown }
Test-Case 'off でどちらの task も無ければ何もしない' 'none/none' { Get-PlanText -Want 'off' }
Test-Case 'off で op-reason の task があれば off (無効でも)' 'none/off none/off' { (Get-PlanText -Want 'off' -Own $TaskRun), (Get-PlanText -Want 'off' -Own $TaskOff) }
Test-Case 'off で前の task があれば remove' 'remove/none' { Get-PlanText -Want 'off' -Legacy $TaskReady }

# Get-OpReasonSwapAction: 置き場所を入れ替える前に止めるもの
Test-Case '入れるだけ・揃っていれば swap (動いている数は見ない)' 'swap swap' {
    (Get-OpReasonSwapAction -Plan 'install' -Busy @(1) -Owner 'other'), (Get-OpReasonSwapAction -Plan 'none' -Busy @(1, 2))
}
Test-Case '入れ替えで何も動いておらず、op-reason の task も有効でなければ swap' 'swap swap' {
    (Get-OpReasonSwapAction -Plan 'change' -Busy @() -Owner 'none' -OwnActive $false -Capable $true),
    (Get-OpReasonSwapAction -Plan 'change' -Busy @() -Owner 'none' -OwnActive $true -Capable $false)
}
Test-Case '動いているのが前の task の中継だけなら stop-legacy' 'stop-legacy' { Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid 4242 -Owner 'legacy' -Capable $false }
Test-Case '動いているのが op-reason の task の中継だけなら stop-own' 'stop-own' { Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid 4242 -Owner 'own' -OwnActive $true -Capable $true }
Test-Case '何も動いていなくても op-reason の task が有効なら stop-own (1 分ごとの trigger に古い exe を起こさせない)' 'stop-own stop-own' {
    (Get-OpReasonSwapAction -Plan 'change' -Busy @() -Owner 'none' -OwnActive $true -Capable $true),
    (Get-OpReasonSwapAction -Plan 'change' -Busy @() -Owner 'own' -OwnActive $true -Capable $true)
}
Test-Case '何も動いていなくても、ほかで起こした中継・持ち主の分からない中継が答えていれば relay stop を打たない (swap)' 'swap swap' {
    (Get-OpReasonSwapAction -Plan 'change' -Busy @() -Owner 'other' -OwnActive $true -Capable $true),
    (Get-OpReasonSwapAction -Plan 'change' -Busy @() -Owner 'unknown' -OwnActive $true -Capable $true)
}
Test-Case 'ほかの op-reason.exe (op の呼び出し) も動いていれば busy' 'busy busy' {
    (Get-OpReasonSwapAction -Plan 'change' -Busy @(4242, 77) -RelayPid 4242 -Owner 'own' -OwnActive $true -Capable $true),
    (Get-OpReasonSwapAction -Plan 'change' -Busy @(4242, 77) -RelayPid 4242 -Owner 'legacy')
}
Test-Case '中継を task の外で起こした・持ち主が分からなければ busy' 'busy busy' {
    (Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid 4242 -Owner 'other' -OwnActive $true -Capable $true),
    (Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid 4242 -Owner 'unknown' -OwnActive $true -Capable $true)
}
Test-Case '入っている exe が --settings を持たなければ、op-reason の task の中継でも busy' 'busy' { Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid 4242 -Owner 'own' -OwnActive $true -Capable $false }
Test-Case '中継が答えないのに動いていれば busy' 'busy' { Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid $null -Owner 'none' -OwnActive $true -Capable $true }

# Get-OpReasonExitCode: 中継の計画も見る
function New-RelayPlan { param([string]$Legacy = 'none', [string]$Own = 'none') [pscustomobject]@{ Legacy = $Legacy; Own = $Own } }
Test-Case '版も中継も揃っていれば 0 (中継の計画が無ければ版だけで決める)' '0 0' { (Get-OpReasonExitCode -State (New-State) -RelayPlan (New-RelayPlan)), (Get-OpReasonExitCode -State (New-State)) }
Test-Case '版は揃っていて中継にすることがあれば 1' '1 1 1' {
    (Get-OpReasonExitCode -State (New-State) -RelayPlan (New-RelayPlan -Legacy 'remove')),
    (Get-OpReasonExitCode -State (New-State) -RelayPlan (New-RelayPlan -Own 'set')),
    (Get-OpReasonExitCode -State (New-State) -RelayPlan (New-RelayPlan -Own 'off'))
}
Test-Case '中継を確かめられなければ 2' 2 { Get-OpReasonExitCode -State (New-State) -RelayPlan (New-RelayPlan -Own 'unknown') }
Test-Case '入っていなければ中継によらず 3' 3 { Get-OpReasonExitCode -State (New-State $missing) -RelayPlan (New-RelayPlan -Own 'after-swap') }

# Format-OpReasonRelayState: 状態の表の中継の行
function New-View {
    param([string]$Want = 'per-call', $Own = $null, $Legacy = $null, $Check = $null, [bool]$Capable = $true, [bool]$InScope = $true)
    [pscustomobject]@{
        InScope = $InScope; OwnName = "op-reason-ssh-relay-$Sid"; Own = $Own; Legacy = $Legacy; Capable = $Capable; Check = $Check
        Plan    = (Get-OpReasonRelayPlan -Want $Want -InScope $InScope -OwnTask $Own -LegacyTask $Legacy -Capable $Capable -Check $Check)
        Shown   = $true
    }
}
function Get-RelayRows {
    param([string]$Want = 'per-call', [bool]$Installed = $true, $Own = $null, $Legacy = $null, $Check = $null, [bool]$Capable = $true, [bool]$InScope = $true)
    @(Format-OpReasonRelayState -Want $Want -Installed $Installed -View (New-View -Want $Want -Own $Own -Legacy $Legacy -Check $Check -Capable $Capable -InScope $InScope))
}
function Get-RelayRow { param([object[]]$Rows, [string]$Like) @($Rows | Where-Object { $_.Text -like $Like })[0].Text }
$CheckDiff = ConvertFrom-OpReasonSettingsCheck -Code 1 -Lines @($CkDiff)
Test-Case '見出しは op-reason の task の名前' "SSH の中継 (op-reason の task \op-reason-ssh-relay-$Sid)" { (Get-RelayRows -Check $CheckDiff)[0].Text }
Test-Case '望む形の行 (per-call・show-only・off・引数なし)' $true {
    ((Get-RelayRows -Check $CheckDiff)[1].Text -eq '  望む形           : per-call (relay.autostart=on relay.mode=per-call relay.running=on)') -and
    ((Get-RelayRows -Want 'show-only' -Check $CkSame)[1].Text -eq '  望む形           : show-only (relay.autostart=on relay.mode=show-only relay.running=on)') -and
    ((Get-RelayRows -Want 'off')[1].Text -eq '  望む形           : 置かない (-SshRelay off)') -and
    ((Get-RelayRows -Want '' -Own $TaskRun)[1].Text -eq '  望む形           : 決めない (-SshRelay なし。task には触らない)')
}
Test-Case 'op-reason の task の行 (無い・動いている・止まっている・無効)' '  task             : 無い /   task             : ある (動いている) /   task             : ある (止まっている) /   task             : ある (無効)' {
    @($null, $TaskRun, $TaskReady, $TaskOff | ForEach-Object { (Get-RelayRows -Want '' -Own $_)[2].Text }) -join ' / '
}
Test-Case 'off で op-reason の task があれば ⚠ で消し方を出す' '⚠ task             : ある (動いている) → 止めて消す (op-reason.exe --settings set relay.autostart=off)' { (Get-RelayRows -Want 'off' -Own $TaskRun)[2].Text }
Test-Case '前の task はモードなら ⚠ で移すと出す' '⚠ 前の task        : \pjp\op-reason-ssh-relay (動いている) → 中継を止めて消す (op-reason の task に移す)' {
    Get-RelayRow (Get-RelayRows -Legacy $TaskRun -Check $CheckDiff) '*前の task*'
}
Test-Case '前の task は off なら ⚠ で止めて消すと出す' '⚠ 前の task        : \pjp\op-reason-ssh-relay (止まっている) → 中継を止めて消す' { Get-RelayRow (Get-RelayRows -Want 'off' -Legacy $TaskReady) '*前の task*' }
Test-Case '引数なしなら前の task は行だけ (⚠ なし)' '  前の task        : \pjp\op-reason-ssh-relay (動いている)' { Get-RelayRow (Get-RelayRows -Want '' -Legacy $TaskRun) '*前の task*' }
Test-Case '前の task が無ければ行を出さない' 0 { @((Get-RelayRows -Check $CheckDiff) | Where-Object { $_.Text -like '*前の task*' }).Count }
Test-Case 'check の項目は 1 行ずつ。違えば ⚠ と「今 → 望み」' '⚠ relay.autostart  : off → on' { Get-RelayRow (Get-RelayRows -Check $CheckDiff) '*relay.autostart  :*' }
Test-Case '同じ項目は 2 字下げ' '  relay.mode       : per-call' { Get-RelayRow (Get-RelayRows -Check $CheckDiff) '*relay.mode       :*' }
Test-Case '答えている中継の持ち主を添える (前の task)' '  relay.running    : on (pid 4242。\pjp\op-reason-ssh-relay が起こした)' { Get-RelayRow (Get-RelayRows -Check $CheckDiff) '*relay.running    :*' }
Test-Case '答えている中継の持ち主を添える (op-reason の task・task の外)' '  relay.running    : on (pid 5151。op-reason の task が起こした) /   relay.running    : on (pid 77。task の外で起こした)' {
    $a = ConvertFrom-OpReasonSettingsCheck -Code 0 -Lines @((New-SettingsJson -Items @((New-SettingItem 'relay.running' 'on' 'running' @{ pid = 5151; ours = $true; by = $null } -Wanted 'on')) -Same $true))
    $b = ConvertFrom-OpReasonSettingsCheck -Code 0 -Lines @((New-SettingsJson -Items @((New-SettingItem 'relay.running' 'on' 'running' @{ pid = 77; ours = $false; by = $null } -Wanted 'on')) -Same $true))
    "$(Get-RelayRow (Get-RelayRows -Check $a) '*relay.running    :*') / $(Get-RelayRow (Get-RelayRows -Check $b) '*relay.running    :*')"
}
Test-Case '動いている中継のモードが違えば、値は同じでも ⚠ で添える' '⚠ relay.mode       : show-only (動いている中継 (pid 4242) は per-call で動いている)' {
    $it = New-SettingItem 'relay.mode' 'show-only' 'relay-differs' @{ relay = 'per-call'; pid = 4242 } -Wanted 'show-only' -Same $false
    $c = ConvertFrom-OpReasonSettingsCheck -Code 1 -Lines @((New-SettingsJson -Items @($it) -Same $false))
    Get-RelayRow (Get-RelayRows -Want 'show-only' -Check $c) '*relay.mode       :*'
}
Test-Case '止めた中継は task が無効と添える' '⚠ relay.running    : off → on (task が無効 (relay stop で止めた))' {
    $c = ConvertFrom-OpReasonSettingsCheck -Code 1 -Lines @((New-SettingsJson -Items @((New-SettingItem 'relay.running' 'off' 'task-off' -Wanted 'on' -Same $false)) -Same $false))
    Get-RelayRow (Get-RelayRows -Check $c) '*relay.running    :*'
}
Test-Case '--settings を持たない版では、版を揃えてから確かめる' '  設定             : 版を揃えてから確かめる (入っている op-reason.exe は --settings を持たない)' { Get-RelayRow (Get-RelayRows -Capable $false) '*設定*' }
Test-Case '入れ替える前の exe では確かめない' '  設定             : 版を揃えてから確かめる (入れ替えた後の op-reason.exe で)' { Get-RelayRow (Get-RelayRows -Capable $true) '*設定*' }
Test-Case '入っていなければ、入れてから確かめる' '  設定             : 入れてから確かめる' { Get-RelayRow (Get-RelayRows -Installed $false -Capable $false) '*設定*' }
Test-Case 'check が読めなければ ⚠ でわけ' '⚠ 設定             : 確かめられない (x)' { Get-RelayRow (Get-RelayRows -Check $CkUnknown) '*設定*' }
Test-Case 'off と引数なしには設定の行を出さない' 0 { @((Get-RelayRows -Want 'off' -Own $TaskRun) + (Get-RelayRows -Want '' -Own $TaskRun) | Where-Object { $_.Text -like '*設定*' }).Count }
Test-Case '揃っていれば ⚠ の行は無い' 0 {
    $c = ConvertFrom-OpReasonSettingsCheck -Code 0 -Lines @((New-SettingsJson -Items @($ItMode) -Same $true))
    @((Get-RelayRows -Own $TaskRun -Check $c) | Where-Object { $_.Warn }).Count
}
Test-Case '置き場所が既定でなければ、見ないことだけを出す' 'SSH の中継 /   望む形           : per-call (relay.autostart=on relay.mode=per-call relay.running=on) → 置き場所が既定でないので、task も中継も見ない (-SshRelay は %LOCALAPPDATA%\Programs\op-reason でだけ効く)' {
    $r = Get-RelayRows -InScope $false -Legacy $TaskRun; "$($r[0].Text) / $($r[1].Text)"
}

# ---------------------------------------------------------------------------
# ファイルに触る IO (一時ディレクトリ。Windows には触らない)
# ---------------------------------------------------------------------------

$work = Join-Path ([IO.Path]::GetTempPath()) "install-op-reason-tests-$PID"
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-TestFile {
    param([string]$Path, [string]$Text)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllBytes($Path, [Text.Encoding]::UTF8.GetBytes($Text))
}

# Get-OpReasonFileHash: ファイルの SHA-256 (小文字)。読めなければ空
$sample = Join-Path $work 'sample.bin'
Write-TestFile $sample 'fake op-reason.exe 0.1.0'
Test-Case 'ファイルの SHA-256 を小文字で出す' (Get-TestTextSha256 'fake op-reason.exe 0.1.0') { Get-OpReasonFileHash -Path $sample }
Test-Case '無いファイルなら空' '' { Get-OpReasonFileHash -Path (Join-Path $work 'nothing.bin') }
# PowerShell 7 から起こした Windows PowerShell 5.1 は PSModulePath を継いで 7 の Microsoft.PowerShell.Utility を読み、
# Get-FileHash (5.1 では script の関数) が見つからない (type-clipboard で 2026-11-10 に踏んだ)。その形を偽の関数で作る
Test-Case 'Get-FileHash が見つからない PowerShell でも SHA-256 を出す' (Get-TestTextSha256 'fake op-reason.exe 0.1.0') {
    function Get-FileHash { throw "The term 'Get-FileHash' is not recognized as the name of a cmdlet" }
    Get-OpReasonFileHash -Path $sample
}

# Get-OpReasonTreeHash: 中のファイル全部 (下のディレクトリのものも) の SHA-256 と相対パスから作る値
$tree = Join-Path $work 'tree'
Write-TestFile (Join-Path $tree 'op-reason.exe') 'exe'
Write-TestFile (Join-Path $tree 'launcher.ps1') 'launcher'
Write-TestFile (Join-Path $tree 'README.md') 'readme'
Write-TestFile (Join-Path $tree 'powershell-entry/op-reason.ps1') 'entry'
$treeWant = Get-TestTree @(@('README.md', 'readme'), @('launcher.ps1', 'launcher'), @('op-reason.exe', 'exe'), @('powershell-entry/op-reason.ps1', 'entry'))
Test-Case '中身の値は、相対パスの序数の順の sha256sum の行の SHA-256' $treeWant { Get-OpReasonTreeHash -Dir $tree }
Test-Case '置き場所の末尾に区切りがあっても同じ値' $treeWant { Get-OpReasonTreeHash -Dir "$tree/" }
Test-Case '置き場所が無ければ空' '' { Get-OpReasonTreeHash -Dir (Join-Path $work 'no-such-dir') }
Test-Case '中のファイルが 1 つ変われば値が変わる' 'True' {
    $t2 = Join-Path $work 'tree-changed'
    Copy-Item -LiteralPath $tree -Destination $t2 -Recurse
    Write-TestFile (Join-Path $t2 'powershell-entry/op-reason.ps1') 'entry!'
    (Get-OpReasonTreeHash -Dir $t2) -ne $treeWant
}
Test-Case 'ファイルが 1 つ増えれば値が変わる' 'True' {
    $t3 = Join-Path $work 'tree-added'
    Copy-Item -LiteralPath $tree -Destination $t3 -Recurse
    Write-TestFile (Join-Path $t3 'desktop.ini') ''
    (Get-OpReasonTreeHash -Dir $t3) -ne $treeWant
}
Test-Case '空のディレクトリは数えない (ファイルだけを見る)' $treeWant {
    $t4 = Join-Path $work 'tree-emptydir'
    Copy-Item -LiteralPath $tree -Destination $t4 -Recurse
    New-Item -ItemType Directory -Force -Path (Join-Path $t4 'empty') | Out-Null
    Get-OpReasonTreeHash -Dir $t4
}

# Expand-OpReasonZip: zip を展開する (zip の中の op-reason-windows/ のフォルダーごと)
function New-TestZip {
    param([string]$From, [string]$Zip, [switch]$NoBaseDirectory)
    Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
    [IO.Compression.ZipFile]::CreateFromDirectory($From, $Zip, [IO.Compression.CompressionLevel]::Optimal, (-not $NoBaseDirectory))
}
Test-Case 'zip を展開すると、中の op-reason-windows/ と下のディレクトリのファイルができる' 'entry' {
    $src = Join-Path $work 'zip-src/op-reason-windows'
    Write-TestFile (Join-Path $src 'powershell-entry/op-reason.ps1') 'entry'
    $zip = Join-Path $work 'expand.zip'
    New-TestZip -From $src -Zip $zip
    $to = Join-Path $work 'expanded'
    Expand-OpReasonZip -ZipPath $zip -Destination $to
    [IO.File]::ReadAllText((Join-Path $to 'op-reason-windows/powershell-entry/op-reason.ps1'))
}

# 本体の入口: Linux の pwsh には $env:LOCALAPPDATA が無く、置き場所を決めるところで例外になる。
# それでも終了コード 2 で止まり、成功 (0) に見せない
Test-Case '思わぬ例外では終了コード 2 で止まる' '2' {
    $pwsh = (Get-Process -Id $PID).Path
    $null = & $pwsh -NoProfile -File $ScriptPath -Check 2>&1
    $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# Invoke-InstallOpReason の流れ。落とす・動いているプロセスを偽物に差し替え、置き場所は一時ディレクトリに向ける
# (zip の SHA-256・展開・中身の値・置き場所の入れ替えは本物のファイルで確かめる)。ここより後ろでは、差し替えた関数の
# 本物は使えない
# ---------------------------------------------------------------------------

# 作り物の zip (op-reason-windows/ の 1 フォルダー)。中身の値は関数を通さずに作る (並びは序数の順で渡す)
function New-Fixture {
    param([string]$Tag, [switch]$NoBaseDirectory)
    $base = Join-Path $work "fixture-$Tag"
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    $content = Join-Path $base 'op-reason-windows'
    $files = @(
        @('SKILL.md', "skill $Tag"),
        @('launcher.ps1', "fake launcher $Tag"),
        @('op-reason.exe', "fake op-reason.exe $Tag"),
        @('powershell-entry/op-reason.ps1', "fake entry $Tag")
    )
    foreach ($f in $files) { Write-TestFile (Join-Path $content $f[0]) $f[1] }
    $zip = Join-Path $work "fixture-$Tag.zip"
    New-TestZip -From $content -Zip $zip -NoBaseDirectory:$NoBaseDirectory
    $bytes = [IO.File]::ReadAllBytes($zip)
    [pscustomobject]@{ Content = $content; Bytes = $bytes; Zip = (Get-TestSha256 $bytes); Tree = (Get-TestTree $files) }
}
$FixV = New-Fixture -Tag $V
$FixOld = New-Fixture -Tag $Older
$FixBad = New-Fixture -Tag 'tampered'
$FixFlat = New-Fixture -Tag 'flat' -NoBaseDirectory

$FlowParent = Join-Path $work 'Programs'
$FlowInstallDir = Join-Path $FlowParent 'op-reason'
$FlowExe = Join-Path $FlowInstallDir 'op-reason.exe'

# 表は作り物の zip の値にする (本物の値で落とせる zip はテストに無い)。テストごとに $script:Table を差し替えられる
function New-FlowTable {
    [ordered]@{
        $Older  = @{ Zip = $FixOld.Zip; Tree = $FixOld.Tree }
        $V      = @{ Zip = $FixV.Zip; Tree = $FixV.Tree }
        '0.6.0' = @{ Zip = $FixR6.Zip; Tree = $FixR6.Tree }
        '0.7.0' = @{ Zip = $FixR7.Zip; Tree = $FixR7.Tree }
        '0.8.0' = @{ Zip = $FixR8.Zip; Tree = $FixR8.Tree }
    }
}
function Get-OpReasonReleases { $script:Table }
# 落とす: 頼まれた URL を記録し、$script:Serve の中身を書く ($script:DownloadError があれば例外。$script:Serve が
# $null なら何も書かない = 落とした物が読めない)
function Invoke-OpReasonDownload {
    param([string]$Url, [string]$OutFile)
    $script:Downloads.Add($Url)
    $script:Calls.Add('Download')
    if ($script:DownloadError) { throw $script:DownloadError }
    if ($null -eq $script:Serve) { return }
    [IO.File]::WriteAllBytes($OutFile, $script:Serve)
}
function Get-OpReasonBusyProcess { param([string]$InstallDir) @($script:Busy) }

# 中継の偽物。前の task は $script:Legacy、op-reason の task は $script:Own (どちらも State・Enabled か $null)。答える中継は
# $script:RelayPid とその持ち主 $script:RelayOwner (own・legacy・other)、そのモード $script:RelayMode、settings.json の relay.mode は
# $script:FileMode ('' なら書いていない = per-call)。動いている op-reason.exe は $script:Busy。
# op-reason.exe --settings は Invoke-OpReasonSettings の偽物が、op-reason の engine (engine.rs の check・set・relay stop/start・get) の
# 要るところだけを真似る。打った exe の版 (作り物の op-reason.exe の中身) も控え、0.7.0 より前の exe には「--settings を知らない」で答える。
# 呼ばれたものを順に $script:Calls に残す (Settings は「Set@0.7.0」のように版を添える)。$script:LockHeld なら lock を取れない (窓が
# 開いている)、$script:NoAnswer なら起こしても答えない、$script:StopHangs なら止めてもプロセスが終わらない、$script:CheckFails なら
# check が 2 (読めない)、$script:Blocked なら op-reason.exe を起こせない (Smart App Control)、$script:RegisterFails なら op-reason の task を
# 作れない、$script:Drains なら中継が stop event に応える (0.7.0 からの中継)
$RelayOldPid = 4242
$RelayNewPid = 5151
$LegacyPath = '\pjp\op-reason-ssh-relay'
$FixR6 = New-Fixture -Tag '0.6.0'
$FixR7 = New-Fixture -Tag '0.7.0'
$FixR8 = New-Fixture -Tag '0.8.0'

function Get-OpReasonUserSid { $script:Sid }
function Get-OpReasonDefaultInstallDir { $script:DefaultDir }
function Get-OpReasonTask {
    param([string]$Path, [string]$Name)
    if ($Path -eq '\pjp\') { return $script:Legacy }
    if (($Path -eq '\') -and ($Name -eq "op-reason-ssh-relay-$($script:Sid)")) { return $script:Own }
    $null
}
function Stop-FakeRelay {
    $script:Busy = @($script:Busy | Where-Object { $_.Id -ne $script:RelayPid })
    if (($script:RelayOwner -eq 'legacy') -and $script:Legacy) { $script:Legacy.State = $(if ($script:Legacy.Enabled) { 'Ready' } else { 'Disabled' }) }
    if (($script:RelayOwner -eq 'own') -and $script:Own) { $script:Own.State = $(if ($script:Own.Enabled) { 'Ready' } else { 'Disabled' }) }
    $script:RelayPid = $null
    $script:RelayOwner = $null
}
function Start-FakeOwnRelay {
    if ($script:NoAnswer) { return $false }
    $script:RelayPid = $RelayNewPid
    $script:RelayOwner = 'own'
    $script:RelayMode = $(if ($script:FileMode) { $script:FileMode } else { 'per-call' })
    $script:Own.State = 'Running'
    $true
}
function Set-OpReasonLegacyTaskEnabled {
    param([bool]$Enabled)
    $script:Calls.Add("LegacyEnabled $Enabled")
    $script:Legacy.Enabled = $Enabled
    if ((-not $Enabled) -and ($script:Legacy.State -ne 'Running')) { $script:Legacy.State = 'Disabled' }
    if ($Enabled -and ($script:Legacy.State -eq 'Disabled')) { $script:Legacy.State = 'Ready' }
}
function Stop-OpReasonLegacyTask {
    $script:Calls.Add('LegacyStop')
    if ($script:StopHangs) { return }
    if ($script:RelayOwner -eq 'legacy') { Stop-FakeRelay }
    $script:Legacy.State = $(if ($script:Legacy.Enabled) { 'Ready' } else { 'Disabled' })
}
function Start-OpReasonLegacyTask {
    $script:Calls.Add('LegacyStart')
    if ($script:Legacy -and $script:Legacy.Enabled -and -not $script:NoAnswer) {
        $script:RelayPid = $RelayNewPid
        $script:RelayOwner = 'legacy'
        $script:Legacy.State = 'Running'
    }
}
function Unregister-OpReasonLegacyTask { $script:Calls.Add('LegacyUnregister'); $script:Legacy = $null }
function Request-OpReasonRelayStop {
    param([int]$RelayPid)
    $script:Calls.Add("Drain $RelayPid")
    if (-not $script:Drains) { return $false }
    if (-not $script:StopHangs) { Stop-FakeRelay }
    $true
}
function Get-OpReasonRelayPid { param([string]$Exe) $script:Calls.Add('Status'); $script:RelayPid }
function Wait-OpReasonRelayPid { param([string]$Exe, [int]$Seconds) $script:Calls.Add('Wait'); $script:RelayPid }
function Wait-OpReasonProcessExit { param([int]$Id, [int]$Seconds) $script:Calls.Add("WaitExit $Id"); -not $script:StopHangs }
function Enter-OpReasonLock {
    $script:Calls.Add('Lock')
    if ($script:LockHeld) { return $null }
    [pscustomobject]@{ FakeLock = $true }
}
function Exit-OpReasonLock { param($Lock) if ($Lock) { $script:Calls.Add('Unlock') } }

# op-reason の check の 3 つの項目 (engine.rs の item と same の真似)
function Get-FakeCheckItems {
    param([string]$Mode)
    $file = if ($script:FileMode) { $script:FileMode } else { 'per-call' }
    $by = if ($script:RelayOwner -eq 'legacy') { $LegacyPath } else { $null }
    if ($script:CheckFails) {
        $auto = New-SettingItem 'relay.autostart' $null 'unreadable' @{ error = 'Task Scheduler: access denied' } -Wanted 'on' -Same $false
    } elseif ($script:Own) {
        $other = [bool]($script:Own.Enabled -and $script:RelayPid -and ($script:RelayOwner -ne 'own'))
        $auto = if ($other) {
            New-SettingItem 'relay.autostart' 'on' 'other-relay' @{ pid = $script:RelayPid; by = $by } -Wanted 'on' -Same $true
        } else {
            New-SettingItem 'relay.autostart' 'on' -Wanted 'on' -Same $true
        }
    } else {
        $auto = New-SettingItem 'relay.autostart' 'off' -Wanted 'on' -Same $false
    }
    $differs = [bool]($script:RelayPid -and ($script:RelayOwner -eq 'own') -and ($script:RelayMode -ne $file))
    $modeItem = if ($differs) {
        New-SettingItem 'relay.mode' $file 'relay-differs' @{ relay = $script:RelayMode; pid = $script:RelayPid } -Wanted $Mode -Same $false
    } else {
        New-SettingItem 'relay.mode' $file -Wanted $Mode -Same ($file -eq $Mode)
    }
    $run = if ($script:RelayPid) {
        New-SettingItem 'relay.running' 'on' 'running' @{ pid = $script:RelayPid; ours = ($script:RelayOwner -eq 'own'); by = $by } -Wanted 'on' -Same $true
    } else {
        $st = if ($script:Own -and -not $script:Own.Enabled) { 'task-off' } elseif ($script:Own) { 'task-starting' } else { 'ok' }
        New-SettingItem 'relay.running' 'off' $st -Wanted 'on' -Same $false
    }
    @($auto, $modeItem, $run)
}

function Invoke-OpReasonSettings {
    param([string]$Exe, [string[]]$Arguments)
    $ver = if (Test-Path -LiteralPath $Exe) { [IO.File]::ReadAllText($Exe) -replace '^fake op-reason\.exe ', '' } else { 'none' }
    $words = (@($Arguments) | Select-Object -Skip 1) -join ' '
    $name = switch -Wildcard ($words) {
        'check *' { 'Check' }
        'set relay.autostart=on *' { 'Set' }
        'set relay.autostart=off' { 'Off' }
        'relay stop' { 'Stop' }
        'relay start' { 'Start' }
        'get relay.running --json' { 'Get' }
        default { "?$words" }
    }
    $script:Calls.Add("$name@$ver")
    $result = { param($Code, [string[]]$Lines) [pscustomobject]@{ Code = $Code; Lines = @($Lines); Failure = '' } }
    if ($script:Blocked) { return [pscustomobject]@{ Code = $null; Lines = @(); Failure = 'An Application Control policy has blocked this file.' } }
    if (-not (Test-OpReasonSettingsVersion -Installed $ver)) { return (& $result 2 @('[ERROR] unknown flag: --settings')) }
    switch ($name) {
        'Check' {
            $mode = ($words -split ' ' | Where-Object { $_ -like 'relay.mode=*' }) -replace '^relay\.mode=', ''
            $items = Get-FakeCheckItems -Mode $mode
            $same = -not @($items | Where-Object { -not $_.same })
            $code = if ($script:CheckFails) { 2 } elseif ($same) { 0 } else { 1 }
            return (& $result $code @((New-SettingsJson -Items $items -Same $same)))
        }
        'Get' {
            $run = @(Get-FakeCheckItems -Mode 'per-call')[2]
            return (& $result 0 @((New-SettingsJson -Items @($run))))
        }
        'Set' {
            $mode = ($words -split ' ' | Where-Object { $_ -like 'relay.mode=*' }) -replace '^relay\.mode=', ''
            $lines = @()
            $failed = $false
            $pidBefore = $script:RelayPid
            $script:FileMode = $mode
            if (-not $script:Own) {
                if ($script:RegisterFails) {
                    $lines += 'relay.autostart: off → on: failed: register'
                    $failed = $true
                } else {
                    $other = [bool]($script:RelayPid -and ($script:RelayOwner -ne 'own'))
                    $script:Own = [pscustomobject]@{ State = 'Ready'; Enabled = (-not $other) }
                    $lines += 'relay.autostart: off → on: done'
                }
            }
            if (-not $script:RelayPid) {
                if (-not $script:Own) {
                    $lines += 'relay.running: off → on: failed: no-task'
                    $failed = $true
                } else {
                    $script:Own.Enabled = $true
                    if (Start-FakeOwnRelay) { $lines += 'relay.running: off → on: done' } else { $lines += 'relay.running: off → on: failed: no-answer'; $failed = $true }
                }
            } elseif (($script:RelayPid -eq $pidBefore) -and ($script:RelayOwner -eq 'own') -and ($script:RelayMode -ne $mode)) {
                if ($script:LockHeld) {
                    $lines += 'relay.running: on → on: failed: locked'
                    $failed = $true
                } else {
                    Stop-FakeRelay
                    [void](Start-FakeOwnRelay)
                    $lines += 'relay.running: on → on: done (restarted)'
                }
            }
            return (& $result $(if ($failed) { 1 } else { 0 }) $lines)
        }
        'Off' {
            if ($script:Own) {
                if ($script:RelayPid -and ($script:RelayOwner -eq 'own')) {
                    if ($script:LockHeld) { return (& $result 1 @('relay.autostart: on → off: failed: locked')) }
                    Stop-FakeRelay
                }
                $script:Own = $null
                return (& $result 0 @('relay.autostart: on → off: done'))
            }
            return (& $result 0 @('relay.autostart: off → off: same'))
        }
        'Stop' {
            if (-not $script:RelayPid) {
                if ($script:Own -and $script:Own.Enabled) { $script:Own.Enabled = $false; $script:Own.State = 'Disabled' }
                return (& $result 0 @('relay.running: off → off: done'))
            }
            if ($script:RelayOwner -eq 'own') {
                if ($script:LockHeld) { return (& $result 1 @('relay.running: on → off: failed: locked')) }
                $script:Own.Enabled = $false
                $script:Own.State = 'Disabled'
                Stop-FakeRelay
                return (& $result 0 @('relay.running: on → off: done'))
            }
            if ($script:Own -and $script:Own.Enabled) { $script:Own.Enabled = $false; $script:Own.State = 'Disabled' }
            return (& $result 1 @('relay.running: on → off: failed: not-ours'))
        }
        'Start' {
            if ($script:RelayPid) { return (& $result 0 @('relay.running: on → on: same')) }
            if (-not $script:Own) { return (& $result 1 @('relay.running: off → on: failed: no-task')) }
            $script:Own.Enabled = $true
            if (Start-FakeOwnRelay) { return (& $result 0 @('relay.running: off → on: done')) }
            return (& $result 1 @('relay.running: off → on: failed: no-answer'))
        }
    }
    & $result 2 @("[ERROR] $words")
}

# 1 回ぶんの流れを走らせ、落とした URL・画面の行・終了コードと、終わった後の置き場所を返す。
#   -Have: 置き場所にある中身 ('' なら無い。V・Old・Bad・R6・R7・R8 は作り物の中身を写す)。-Serve: 落とすと返る中身 (-ServeNothing なら
#   何も書かない)。-Busy: 動いている数。-DownloadError: 落とすと出る例外の文。-NoParent: 置き場所の親ディレクトリも無い
#   -Stale・-Fresh: 前の実行が残した途中の物 (1 時間前・今) を置き場所の隣に置く
#   -SshRelay: スクリプトに渡す値 (per-call・show-only・off。'' なら渡さない)。-Legacy・-Own: 前の task・op-reason の task (running は
#   その task の中継が答えていて、入っていればそのプロセスも動いている op-reason.exe に数える。ready は止まっている・disabled は無効。
#   '' なら無い。両方 running なら答えている中継は op-reason の task のもの)。-FileMode・-RelayMode: settings.json の relay.mode と、
#   op-reason の task の中継が動いているモード。-Terminal: task の外で起こした中継が答えている (両方の task の中継より後に決める)。
#   -RelayElsewhere: 中継のプロセスを置き場所のものに数えない。-NotDefault: 置き場所を
#   既定でないものにする。-LockHeld・-NoAnswer・-StopHangs・-CheckFails・-Blocked・-RegisterFails・-Drains は上の偽物の説明
function Invoke-Flow {
    param(
        [string]$Have = '', [byte[]]$Serve = $FixV.Bytes, [int]$Busy = 0, [string]$DownloadError = '',
        [string]$Version = $V, [switch]$Check, [switch]$ServeNothing, [switch]$NoParent, [switch]$Stale, [switch]$Fresh,
        [string]$SshRelay = '', [string]$Legacy = '', [string]$Own = '', [string]$FileMode = '', [string]$RelayMode = '',
        [switch]$Terminal, [switch]$RelayElsewhere, [switch]$NotDefault, [switch]$LockHeld, [switch]$NoAnswer, [switch]$StopHangs, [switch]$CheckFails,
        [switch]$Blocked, [switch]$RegisterFails, [switch]$Drains
    )
    Remove-Item -LiteralPath $FlowParent -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $NoParent) { New-Item -ItemType Directory -Force -Path $FlowParent | Out-Null }
    $from = switch ($Have) {
        'V' { $FixV.Content } 'Old' { $FixOld.Content } 'Bad' { $FixBad.Content }
        'R6' { $FixR6.Content } 'R7' { $FixR7.Content } 'R8' { $FixR8.Content }
        default { $null }
    }
    if ($from) { Copy-Item -LiteralPath $from -Destination $FlowInstallDir -Recurse }
    if ($Stale) {
        foreach ($n in 'op-reason.download-99999.zip', 'op-reason.new-99999', 'op-reason.old-99999') {
            $p = Join-Path $FlowParent $n
            if ($n.EndsWith('.zip')) { Write-TestFile $p 'stale' } else { Write-TestFile (Join-Path $p 'x') 'stale' }
            (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddHours(-1)
        }
    }
    if ($Fresh) { Write-TestFile (Join-Path $FlowParent 'op-reason.download-88888.zip') 'fresh' }
    $script:Downloads = [System.Collections.Generic.List[string]]::new()
    $script:Serve = if ($ServeNothing) { $null } else { $Serve }
    $script:DownloadError = $DownloadError
    $script:Busy = @()
    if ($Busy -gt 0) { $script:Busy = @(1..$Busy | ForEach-Object { [pscustomobject]@{ Id = 1000 + $_; Path = $FlowExe } }) }
    $script:Calls = [System.Collections.Generic.List[string]]::new()
    foreach ($s in 'LockHeld', 'NoAnswer', 'StopHangs', 'CheckFails', 'Blocked', 'RegisterFails', 'Drains') {
        Set-Variable -Scope Script -Name $s -Value ([bool](Get-Variable -Name $s -ValueOnly))
    }
    $script:DefaultDir = if ($NotDefault) { Join-Path $work 'elsewhere/op-reason' } else { $FlowInstallDir }
    $script:FileMode = $FileMode
    $script:Legacy = $null
    $script:Own = $null
    $script:RelayPid = $null
    $script:RelayOwner = $null
    $script:RelayMode = ''
    $shapes = @{ running = @('Running', $true); ready = @('Ready', $true); disabled = @('Disabled', $false) }
    if ($Legacy) {
        $script:Legacy = [pscustomobject]@{ State = $shapes[$Legacy][0]; Enabled = $shapes[$Legacy][1] }
        if ($Legacy -eq 'running') { $script:RelayPid = $RelayOldPid; $script:RelayOwner = 'legacy' }
    }
    if ($Own) {
        $script:Own = [pscustomobject]@{ State = $shapes[$Own][0]; Enabled = $shapes[$Own][1] }
        if ($Own -eq 'running') {
            $script:RelayPid = $RelayOldPid
            $script:RelayOwner = 'own'
            $script:RelayMode = $(if ($RelayMode) { $RelayMode } elseif ($FileMode) { $FileMode } else { 'per-call' })
        }
    }
    if ($Terminal) {
        $script:RelayPid = $RelayOldPid
        $script:RelayOwner = 'other'
    }
    # 置き場所から動いている中継は、入れ替えの邪魔になる op-reason.exe でもある
    if ($script:RelayPid -and $from -and -not $RelayElsewhere) { $script:Busy = @([pscustomobject]@{ Id = $RelayOldPid; Path = $FlowExe }) + @($script:Busy) }
    $relayArgs = @{}
    if ($SshRelay) { $relayArgs['SshRelay'] = $SshRelay }
    $out = @(Invoke-InstallOpReason -Version $Version -Check:$Check -InstallDir $FlowInstallDir @relayArgs 6>&1)
    $leftover = @()
    if (Test-Path -LiteralPath $FlowParent) {
        $leftover = @(Get-ChildItem -LiteralPath $FlowParent -Force | Where-Object { $_.Name -ne 'op-reason' } | ForEach-Object { $_.Name } | Sort-Object)
    }
    [pscustomobject]@{
        Code         = @($out | Where-Object { $_ -is [int] })[-1]
        Text         = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Downloads    = ($script:Downloads -join ' ')
        # 置き場所の op-reason.exe の中身 (作り物の文字) と、中身の値
        Exe          = $(if (Test-Path -LiteralPath $FlowExe) { [IO.File]::ReadAllText($FlowExe) } else { 'none' })
        Tree         = $(if (Test-Path -LiteralPath $FlowInstallDir) { Get-OpReasonTreeHash -Dir $FlowInstallDir } else { 'none' })
        ParentExists = (Test-Path -LiteralPath $FlowParent)
        Leftover     = ($leftover -join ' ')
        # パイプラインに出たもの (Write-Host の行を除く) の数。終了コードの 1 つだけのはず
        Outputs      = @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count
        # 偽物が呼ばれた順 (Download と中継の偽物)・終わった後の 2 つの task (状態/有効。無ければ none)・答える中継 (PID/持ち主)
        Calls        = ($script:Calls -join ' ')
        LegacyAfter  = $(if ($script:Legacy) { "$($script:Legacy.State)/$($script:Legacy.Enabled)" } else { 'none' })
        OwnAfter     = $(if ($script:Own) { "$($script:Own.State)/$($script:Own.Enabled)" } else { 'none' })
        RelayAfter   = "$($script:RelayPid)/$($script:RelayOwner)"
        FileMode     = $script:FileMode
    }
}

$script:Table = New-FlowTable
$url = 'https://github.com/pollenjp/op-reason/releases/download/v0.1.0/op-reason-windows.zip'
$exeV = "fake op-reason.exe $V"
$exeOld = "fake op-reason.exe $Older"

# -Check: 何も落とさず、何も変えない
Test-Case '-Check は入っていなければ 3 で、何も落とさず、置き場所も作らない' '3 [] none' { $r = Invoke-Flow -Check; "$($r.Code) [$($r.Downloads)] $($r.Exe)" }
Test-Case '-Check は揃っていれば 0' '0 []' { $r = Invoke-Flow -Have V -Check; "$($r.Code) [$($r.Downloads)]" }
Test-Case '-Check は古い版なら 1 で、入れ替えない' "1 [] $exeOld" { $r = Invoke-Flow -Have Old -Check; "$($r.Code) [$($r.Downloads)] $($r.Exe)" }
Test-Case '-Check は表のどの版でもない中身なら 1' '1 []' { $r = Invoke-Flow -Have Bad -Check; "$($r.Code) [$($r.Downloads)]" }
Test-Case '-Check の締めは、入っていなければ入れ方を出す' $true { $r = Invoke-Flow -Check; $r.Text -like '*⚠️ op-reason が入っていない → Install-OpReason で入れる ⚠️*' }
Test-Case '-Check の締めは、差があれば揃え方を出す' $true { $r = Invoke-Flow -Have Old -Check; $r.Text -like '*⚠️ 固定した版と揃っていない → Install-OpReason で揃える ⚠️*' }
Test-Case '-Check は入れ替えが要るのに動いていても 1 で、※ で待ち方を添える' $true { $r = Invoke-Flow -Have Old -Busy 1 -Check; ($r.Code -eq 1) -and ($r.Text -like '*※ op-reason.exe が 1 個動いている*') }

# 揃える (引数なし)
Test-Case '入っていなければ落として展開し、置き場所に置いて 0' "0 [$url] $exeV" { $r = Invoke-Flow; "$($r.Code) [$($r.Downloads)] $($r.Exe)" }
Test-Case '入れた中身の値は、固定した版の値' $FixV.Tree { (Invoke-Flow).Tree }
Test-Case '入れた後に、落とした zip と途中の物を置き場所の隣に残さない' '' { (Invoke-Flow).Leftover }
Test-Case '入れた後は「揃った」と出す' $true { (Invoke-Flow).Text -like '*揃った*' }
Test-Case '揃っていれば何もしない (落とさない)' '0 []' { $r = Invoke-Flow -Have V; "$($r.Code) [$($r.Downloads)]" }
Test-Case '古い版を入れ替える' "0 [$url] $exeV" { $r = Invoke-Flow -Have Old; "$($r.Code) [$($r.Downloads)] $($r.Exe)" }
Test-Case '古い版を入れ替えた後に、前の中身を残さない' '' { (Invoke-Flow -Have Old).Leftover }
Test-Case '表のどの版でもない中身も入れ替える' "0 [$url] $exeV" { $r = Invoke-Flow -Have Bad; "$($r.Code) [$($r.Downloads)] $($r.Exe)" }
Test-Case '置き場所の親ディレクトリが無くても作って入れる' "0 $exeV" { $r = Invoke-Flow -NoParent; "$($r.Code) $($r.Exe)" }

# 動いているとき: 止めずに知らせる
Test-Case '入れ替えが要るのに動いていれば、落とさずに止まる (古い版はそのまま)' "1 [] $exeOld" { $r = Invoke-Flow -Have Old -Busy 2; "$($r.Code) [$($r.Downloads)] $($r.Exe)" }
Test-Case '動いていれば、待ち方と PID を出す' $true { $r = Invoke-Flow -Have Old -Busy 2; ($r.Text -like '*op の呼び出しが終わってから*') -and ($r.Text -like '*1001*') -and ($r.Text -like '*1002*') }
Test-Case '入れるだけなら、動いている別の op-reason.exe は気にしない' "0 [$url]" { $r = Invoke-Flow -Busy 1; "$($r.Code) [$($r.Downloads)]" }

# 落とせない・SHA-256 が合わないとき: 何も置かない
Test-Case '落とせなければ 1 で、何も置かない' '1 none' { $r = Invoke-Flow -DownloadError 'The remote name could not be resolved'; "$($r.Code) $($r.Exe)" }
Test-Case '落とせなければ、途中の物を残さない' '' { (Invoke-Flow -DownloadError 'timeout').Leftover }
Test-Case '落とせなければ、わけと何も変えていないことを出す' $true { $r = Invoke-Flow -DownloadError 'The remote name could not be resolved'; ($r.Text -like '*could not be resolved*') -and ($r.Text -like '*何も変えていない*') }
Test-Case '落とせないときは、ネットワークだけでなく URL (Release の版と zip の名前) も確かめるよう出す' $true { $r = Invoke-Flow -DownloadError 'Response status code does not indicate success: 404 (Not Found).'; ($r.Text -like '*404 (Not Found)*') -and ($r.Text -like '*上の URL (Release の版と zip の名前)*') }
Test-Case '落とせなければ、作った親ディレクトリも残さない' 'False' { (Invoke-Flow -NoParent -DownloadError 'timeout').ParentExists }
Test-Case 'zip の SHA-256 が合わなければ置かない (古い版はそのまま)' "1 $exeOld" { $r = Invoke-Flow -Have Old -Serve $FixBad.Bytes; "$($r.Code) $($r.Exe)" }
Test-Case 'zip の SHA-256 が合わなければ、落とした物を残さない' '' { (Invoke-Flow -Have Old -Serve $FixBad.Bytes).Leftover }
Test-Case 'zip の SHA-256 が合わなければ、固定した値と落とした物の値を出す' $true { $r = Invoke-Flow -Serve $FixBad.Bytes; ($r.Text -like "*$($FixV.Zip)*") -and ($r.Text -like "*$($FixBad.Zip)*") -and ($r.Text -like '*置かない*') }
Test-Case 'zip の SHA-256 が合わなければ、入っていないときも置かない' '1 none' { $r = Invoke-Flow -Serve $FixBad.Bytes; "$($r.Code) $($r.Exe)" }
Test-Case '落とした物が読めなければ、Release の差し替えや表の誤りとは言わない' $true { $r = Invoke-Flow -ServeNothing; ($r.Code -eq 1) -and ($r.Text -like '*落とした物を読めなかった*') -and ($r.Text -notlike '*差し替えられた*') -and ($r.Leftover -eq '') }

# zip は合うのに展開した中身が表と合わない (表の Tree の書き誤り・zip の中の並びが変わった): 置かない
Test-Case '展開した中身の値が表と合わなければ置かない (古い版はそのまま)' "1 $exeOld" {
    $script:Table = New-FlowTable
    $script:Table[$V] = @{ Zip = $FixV.Zip; Tree = ('0' * 64) }
    try { $r = Invoke-Flow -Have Old } finally { $script:Table = New-FlowTable }
    "$($r.Code) $($r.Exe)"
}
Test-Case '展開した中身の値が表と合わなければ、固定した値と展開した物の値を出し、途中の物を残さない' $true {
    $script:Table = New-FlowTable
    $script:Table[$V] = @{ Zip = $FixV.Zip; Tree = ('0' * 64) }
    try { $r = Invoke-Flow } finally { $script:Table = New-FlowTable }
    ($r.Text -like "*$('0' * 64)*") -and ($r.Text -like "*$($FixV.Tree)*") -and ($r.Leftover -eq '') -and ($r.Exe -eq 'none')
}
Test-Case 'zip の中に op-reason-windows のフォルダーが無ければ置かない' $true {
    $script:Table = New-FlowTable
    $script:Table[$V] = @{ Zip = $FixFlat.Zip; Tree = $FixFlat.Tree }
    try { $r = Invoke-Flow -Serve $FixFlat.Bytes } finally { $script:Table = New-FlowTable }
    ($r.Code -eq 1) -and ($r.Exe -eq 'none') -and ($r.Text -like '*op-reason-windows のフォルダーが無いか*') -and ($r.Leftover -eq '')
}

# 止められた前の実行が残した途中の物は、古ければ消す (同時に走っている実行の物は残す)
Test-Case '前の実行が残した古い途中の物 (zip・展開した物・前の中身) は消し、新しいものは残す' '0 op-reason.download-88888.zip' { $r = Invoke-Flow -Stale -Fresh; "$($r.Code) $($r.Leftover)" }

# パイプラインに出すのは終了コードの 1 つだけ (本体の exit (…) に配列を渡さない)
Test-Case 'どの流れでも、パイプラインに出すのは終了コードの 1 つだけ' '1 1 1 1 1 1' {
    @((Invoke-Flow -Check).Outputs, (Invoke-Flow).Outputs, (Invoke-Flow -Have Old).Outputs,
        (Invoke-Flow -Have Old -Busy 1).Outputs, (Invoke-Flow -DownloadError 'x').Outputs, (Invoke-Flow -Serve $FixBad.Bytes).Outputs)
}

# 置き場所を相対パスで渡しても、今の場所 (PowerShell の location) から解く ([IO.File] はプロセスの作業ディレクトリで解くため)
Test-Case '置き場所を相対パスで渡しても、今の場所から解いて入れる' $true {
    $rel = Join-Path $work 'rel'
    Remove-Item -LiteralPath $rel -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $rel | Out-Null
    $script:Downloads = [System.Collections.Generic.List[string]]::new()
    $script:Serve = $FixV.Bytes
    $script:DownloadError = ''
    $script:Busy = @()
    Push-Location -LiteralPath $rel
    try {
        $out = @(Invoke-InstallOpReason -Version $V -InstallDir 'Programs/op-reason' 6>&1)
    } finally {
        Pop-Location
    }
    $code = @($out | Where-Object { $_ -is [int] })[-1]
    ($code -eq 0) -and ([IO.File]::ReadAllText((Join-Path $rel 'Programs/op-reason/op-reason.exe')) -eq $exeV)
}

# 入れ替えが落ちたとき。ここからは置き場所の名前替えを偽物にする
# 1. 前の中身をよけられない (中のファイルを開いているプロセスがある): 何も変えずに止まる
function Move-OpReasonDirectory {
    param([string]$Source, [string]$Destination)
    if ($Source -eq $FlowInstallDir) { throw 'The process cannot access the file because it is being used by another process.' }
    [IO.Directory]::Move($Source, $Destination)
}
Test-Case '前の中身をよけられなければ 1 で、古い版はそのまま' "1 $exeOld" { $r = Invoke-Flow -Have Old; "$($r.Code) $($r.Exe)" }
Test-Case '前の中身をよけられなければ、途中の物を残さず、待ち方を出す' $true { $r = Invoke-Flow -Have Old; ($r.Leftover -eq '') -and ($r.Text -like '*being used by another process*') -and ($r.Text -like '*終わってから打ち直す*') }

# 2. 前の中身をよけた後に、展開した物を置けない: 前の中身に戻す
function Move-OpReasonDirectory {
    param([string]$Source, [string]$Destination)
    if ((Split-Path -Leaf $Source) -eq 'op-reason-windows') { throw 'Access to the path is denied.' }
    [IO.Directory]::Move($Source, $Destination)
}
Test-Case '展開した物を置けなければ、前の中身に戻して 1' "1 $exeOld" { $r = Invoke-Flow -Have Old; "$($r.Code) $($r.Exe)" }
Test-Case '前の中身に戻したら、そう出し、途中の物を残さない' $true { $r = Invoke-Flow -Have Old; ($r.Text -like '*前の中身に戻した*') -and ($r.Leftover -eq '') -and ($r.Tree -eq $FixOld.Tree) }
Test-Case '入っていなかったときに展開した物を置けなければ、何も置かず途中の物も残さない' '1 none' { $r = Invoke-Flow; "$($r.Code) $($r.Exe) $($r.Leftover)".Trim() }

# 3. 前の中身にも戻せない: 前の中身を消さずに残し、その場所と入れ直し方を出す
function Move-OpReasonDirectory {
    param([string]$Source, [string]$Destination)
    if ((Split-Path -Leaf $Source) -eq 'op-reason-windows') { throw 'Access to the path is denied.' }
    if ($Destination -eq $FlowInstallDir) { throw 'Access to the path is denied (restore).' }
    [IO.Directory]::Move($Source, $Destination)
}
Test-Case '前の中身にも戻せなければ、前の中身を消さずに残し、場所と入れ直し方を出す (何も変えていないとは言わない)' $true {
    $r = Invoke-Flow -Have Old
    ($r.Code -eq 1) -and ($r.Exe -eq 'none') -and ($r.Leftover -eq "op-reason.old-$PID") -and ($r.Text -like '*前の中身を戻せなかった*') -and ($r.Text -like "*op-reason.old-$PID*") -and ($r.Text -notlike '*何も変えていない*')
}
# 偽物を元に戻す
function Move-OpReasonDirectory { param([string]$Source, [string]$Destination) [IO.Directory]::Move($Source, $Destination) }

# 表に無い版
Test-Case '表に無い版を渡すと、何も見ずに 2' '2 []' { $r = Invoke-Flow -Version '9.9.9'; "$($r.Code) [$($r.Downloads)]" }
Test-Case '表に無い版を渡すと、表にある版を出す' $true { $r = Invoke-Flow -Version '9.9.9'; ($r.Text -like '*9.9.9*') -and ($r.Text -like '*0.1.0*') }

# ---------------------------------------------------------------------------
# SSH の中継 (-SshRelay と、中継の task のあるホストの版上げ)。task・op-reason.exe --settings・--status・lock は上の偽物 (呼ばれた順を
# Calls に残す)。版は 0.6.0 (--settings を持たない)・0.7.0・0.8.0 の作り物
# ---------------------------------------------------------------------------

$S6 = $FixR6.Bytes
$S7 = $FixR7.Bytes
$S8 = $FixR8.Bytes
$exe6 = 'fake op-reason.exe 0.6.0'
$exe7 = 'fake op-reason.exe 0.7.0'
$exe8 = 'fake op-reason.exe 0.8.0'
# 前の task の中継を lock を取って止める (0.6.0 までの中継は stop event を持たない)
$StopLegacy = "Lock LegacyEnabled False Drain $RelayOldPid LegacyStop WaitExit $RelayOldPid"
$RestartLegacy = 'LegacyEnabled True LegacyStart Wait'

# -SshRelay を渡さず task も無いホスト (WSL の setup と、中継を使ったことの無いホスト) は今までどおり
Test-Case '-SshRelay も task も無ければ、中継の行を出さず、op-reason.exe も task も呼ばない' $true {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7
    ($r.Code -eq 0) -and ($r.Calls -eq 'Download') -and ($r.Text -notlike '*SSH の中継*') -and ($r.Exe -eq $exe7)
}
Test-Case '-SshRelay は 0.7.0 より前の版には渡さない (何も見ずに 2)' $true {
    $r = Invoke-Flow -Have R6 -Version '0.6.0' -Serve $S6 -SshRelay per-call -Legacy running
    ($r.Code -eq 2) -and ($r.Calls -eq '') -and ($r.Text -like '*-SshRelay は 0.7.0 からの版で使う*') -and ($r.LegacyAfter -eq 'Running/True')
}

# この PC の初めての apply: 0.6.0 と前の task から、0.7.0 と op-reason の task へ (1 回だけの移し)
Test-Case '初めての apply は、前の task の中継を lock を取って止め、入れ替え、lock を放して set、通ってから前の task を消す' "0 Status Download $StopLegacy Unlock Set@0.7.0 LegacyUnregister Check@0.7.0 / $exe7 none Running/True $RelayNewPid/own" {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running
    "$($r.Code) $($r.Calls) / $($r.Exe) $($r.LegacyAfter) $($r.OwnAfter) $($r.RelayAfter)"
}
Test-Case '初めての apply は、settings.json に relay.mode を書く (show-only)' 'show-only' {
    (Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay show-only -Legacy running).FileMode
}
Test-Case '初めての apply の締めは「揃った」で、読み直した中継の行に op-reason の task が出る' $true {
    $t = (Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running).Text
    ($t -like '*前の task を消した: \pjp\op-reason-ssh-relay (op-reason の task に移した)*') -and ($t -like "*relay.running    : on (pid $RelayNewPid。op-reason の task が起こした)*") -and ($t -like '*揃った*')
}
Test-Case '初めての apply で中継が窓を開いていれば (lock を取れない)、入れ替えず、task に触らずに 1 (落とした物は残さない)' "1 Status Download Lock / $exe6 Running/True none []" {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running -LockHeld
    "$($r.Code) $($r.Calls) / $($r.Exe) $($r.LegacyAfter) $($r.OwnAfter) [$($r.Leftover)]"
}
Test-Case '前の task の中継が止まらなければ、入れ替えず、前の task を有効に戻して 1' "1 Status Download $StopLegacy LegacyEnabled True Unlock / $exe6 Running/True" {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running -StopHangs
    "$($r.Code) $($r.Calls) / $($r.Exe) $($r.LegacyAfter)"
}
Test-Case '版上げでほかの op-reason.exe (op の呼び出し) も動いていれば、落とさずに 1 で PID を出す' $true {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running -Busy 1
    ($r.Code -eq 1) -and ($r.Calls -eq 'Status') -and ($r.Text -like '*1001*') -and ($r.Exe -eq $exe6) -and ($r.LegacyAfter -eq 'Running/True')
}

# set が落ちたとき (前の task は無効にして止めてある)
Test-Case 'set が落ちて op-reason の task ができていなければ、前の task を起こし直して 1 (次の apply が移す)' "1 Check@0.7.0 Get@0.7.0 $StopLegacy Unlock Set@0.7.0 $RestartLegacy / Running/True none" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -RegisterFails -Version '0.7.0'
    "$($r.Code) $($r.Calls) / $($r.LegacyAfter) $($r.OwnAfter)"
}
Test-Case 'set が落ちても op-reason の task ができていれば、前の task を消して 1 (task を 2 つ残さない)' "1 Check@0.7.0 Get@0.7.0 $StopLegacy Unlock Set@0.7.0 LegacyUnregister / none Ready/True" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -NoAnswer -Version '0.7.0'
    "$($r.Code) $($r.Calls) / $($r.LegacyAfter) $($r.OwnAfter)"
}
Test-Case 'set が落ちたら、op-reason の行とわけを見せる' $true {
    $t = (Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -RegisterFails -Version '0.7.0').Text
    ($t -like '*op-reason.exe --settings set relay.autostart=on relay.mode=per-call relay.running=on*') -and ($t -like '*  relay.autostart: off → on: failed: register*') -and
    ($t -like '*(終了コード 1。上の行がわけ)*') -and ($t -like '*op-reason の task を作れなかったので、前の task に戻す*')
}

# 版は揃っていて (0.7.0 を手で入れた後など)、前の task が残っている
Test-Case '版が揃っていて前の task が動いていれば、check の後に持ち主を読み、lock を取って止めて移す' "0 Check@0.7.0 Get@0.7.0 $StopLegacy Unlock Set@0.7.0 LegacyUnregister Check@0.7.0" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -Version '0.7.0'; "$($r.Code) $($r.Calls)"
}
Test-Case '0.7.0 の中継を前の task で動かしていれば、stop event で止まるのを待つ (止まれば終わった task に Stop-ScheduledTask を打たない)' "0 Check@0.7.0 Get@0.7.0 Lock LegacyEnabled False Drain $RelayOldPid WaitExit $RelayOldPid WaitExit $RelayOldPid Unlock Set@0.7.0 LegacyUnregister Check@0.7.0" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -Drains -Version '0.7.0'; "$($r.Code) $($r.Calls)"
}
Test-Case '前の task が一瞬 Running に見えても、答えている中継が op-reason の task のものなら止めない (lock も取らない)' "0 Check@0.7.0 Get@0.7.0 LegacyEnabled False LegacyStop Set@0.7.0 LegacyUnregister Check@0.7.0 / $RelayOldPid/own" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -Own running -Version '0.7.0'; "$($r.Code) $($r.Calls) / $($r.RelayAfter)"
}
Test-Case '前の task が動いていても、答えている中継がほかで起こしたものなら、lock を取ってから前の task だけを止める' "0 Check@0.7.0 Get@0.7.0 Lock LegacyEnabled False LegacyStop Unlock Set@0.7.0 LegacyUnregister Check@0.7.0 / $RelayOldPid/other Ready/False" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -Terminal -RelayElsewhere -Version '0.7.0'; "$($r.Code) $($r.Calls) / $($r.RelayAfter) $($r.OwnAfter)"
}
Test-Case '前の task が動いていて、ほかで起こした中継が答えていても、窓が開いていれば (lock を取れない) 何も変えずに 1' "1 Check@0.7.0 Get@0.7.0 Lock / Running/True none" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -Terminal -RelayElsewhere -LockHeld -Version '0.7.0'; "$($r.Code) $($r.Calls) / $($r.LegacyAfter) $($r.OwnAfter)"
}
Test-Case 'off で前の task の 0.7.0 の中継は、stop event で止まるのを待ってから消す' "0 Get@0.7.0 Lock LegacyEnabled False Drain $RelayOldPid WaitExit $RelayOldPid WaitExit $RelayOldPid LegacyUnregister Unlock none" {
    $r = Invoke-Flow -Have R7 -SshRelay off -Legacy running -Drains -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.LegacyAfter)"
}
Test-Case '前の task が止まっていれば、無効にしてから消す (lock を取らない)' "0 Check@0.7.0 LegacyEnabled False Set@0.7.0 LegacyUnregister Check@0.7.0" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Legacy ready -Version '0.7.0'; "$($r.Code) $($r.Calls)"
}

# op-reason の task (0.7.0 から)
Test-Case '揃っていれば check だけで何もしない (0)' '0 Check@0.7.0' { $r = Invoke-Flow -Have R7 -SshRelay per-call -Own running -Version '0.7.0'; "$($r.Code) $($r.Calls)" }
Test-Case 'モードが違えば set で揃える (op-reason が中継を起こし直す)' "0 Check@0.7.0 Set@0.7.0 Check@0.7.0 per-call $RelayNewPid/own" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Own running -FileMode show-only -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.FileMode) $($r.RelayAfter)"
}
Test-Case 'op-reason の task が無ければ set で作って起こす' "0 Check@0.7.0 Set@0.7.0 Check@0.7.0 Running/True" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.OwnAfter)"
}
Test-Case '止めた中継 (relay stop で task が無効) も set で起こす' "0 Check@0.7.0 Set@0.7.0 Check@0.7.0 Running/True" {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Own disabled -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.OwnAfter)"
}
Test-Case 'check が 2 (読めない) なら、何も変えずに 2' '2 Check@0.7.0' { $r = Invoke-Flow -Have R7 -SshRelay per-call -Own running -CheckFails -Version '0.7.0'; "$($r.Code) $($r.Calls)" }
Test-Case 'op-reason.exe を起こせなければ (Smart App Control)、わけを出して 2' $true {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Own running -Blocked -Version '0.7.0'
    ($r.Code -eq 2) -and ($r.Text -like '*確かめられない (op-reason.exe を起こせなかった: An Application Control policy has blocked this file.)*') -and ($r.Text -like '*何も変えない*')
}

# 版上げ (0.7.0 → 0.8.0): op-reason の task の中継は relay stop で止め、入れ替えた後の exe で起こす
Test-Case '版上げで動いているのが op-reason の task の中継だけなら、持ち主を読み、relay stop・入れ替え・新しい exe で set' "0 Get@0.7.0 Download Stop@0.7.0 Set@0.8.0 Check@0.8.0 / $exe8 Running/True" {
    $r = Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -SshRelay per-call -Own running; "$($r.Code) $($r.Calls) / $($r.Exe) $($r.OwnAfter)"
}
Test-Case '版上げで op-reason の task の中継が窓を開いていれば (relay stop が 1)、入れ替えず 1' "1 Get@0.7.0 Download Stop@0.7.0 / $exe7 Running/True []" {
    $r = Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -SshRelay per-call -Own running -LockHeld; "$($r.Code) $($r.Calls) / $($r.Exe) $($r.OwnAfter) [$($r.Leftover)]"
}
Test-Case '版上げで何も動いていなくても op-reason の task が有効なら、持ち主を読み、relay stop で止めてから入れ替える' "0 Get@0.7.0 Download Stop@0.7.0 Set@0.8.0 Check@0.8.0" {
    $r = Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -SshRelay per-call -Own ready; "$($r.Code) $($r.Calls)"
}
Test-Case '版上げで置き場所に何も動いておらず、ほかで起こした中継が答えていれば、relay stop を打たずに入れ替える (op-reason の task を無効にしない)' "0 Get@0.7.0 Download Set@0.8.0 Check@0.8.0 / Ready/True $RelayOldPid/other" {
    $r = Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -SshRelay per-call -Own ready -Terminal -RelayElsewhere; "$($r.Code) $($r.Calls) / $($r.OwnAfter) $($r.RelayAfter)"
}
Test-Case '引数なしの版上げでも、ほかで起こした中継が答えていれば relay stop を打たない' "0 Get@0.7.0 Download / Ready/True" {
    $r = Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -Own ready -Terminal -RelayElsewhere; "$($r.Code) $($r.Calls) / $($r.OwnAfter)"
}
Test-Case '引数なしの版上げは、relay stop・入れ替え・新しい exe で relay start (task は作り直さない)' "0 Get@0.7.0 Download Stop@0.7.0 Start@0.8.0 / Running/True" {
    $r = Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -Own running; "$($r.Code) $($r.Calls) / $($r.OwnAfter)"
}
Test-Case '引数なしの版上げで、止めていた中継 (task が無効) は起こさない' "0 Download / Disabled/False" {
    $r = Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -Own disabled; "$($r.Code) $($r.Calls) / $($r.OwnAfter)"
}
Test-Case '引数なしの版上げで、前の task の中継は今までどおり止めて入れ替え、起こし直す (task は消さない)' "0 Status Download $StopLegacy $RestartLegacy Unlock / $exe7 Running/True" {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -Legacy running; "$($r.Code) $($r.Calls) / $($r.Exe) $($r.LegacyAfter)"
}
Test-Case 'op-reason の task があれば 0.7.0 より前の版には入れ替えない (1)' $true {
    $r = Invoke-Flow -Have R7 -Version '0.6.0' -Serve $S6 -Own running
    ($r.Code -eq 1) -and ($r.Calls -eq 'Get@0.7.0') -and ($r.Exe -eq $exe7) -and ($r.Text -like '*0.7.0 より前の版には入れ替えない*')
}
# 止めた後に入れ替えが落ちたら、止めた中継を起こし直す (前の中身のまま)
function Move-OpReasonDirectory {
    param([string]$Source, [string]$Destination)
    if ($Source -eq $FlowInstallDir) { throw 'The process cannot access the file because it is being used by another process.' }
    [IO.Directory]::Move($Source, $Destination)
}
Test-Case '初めての apply で入れ替えが落ちたら、前の task を有効に戻して起こし直し、移さずに 1' "1 Status Download $StopLegacy $RestartLegacy Unlock / $exe6 Running/True none" {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running; "$($r.Code) $($r.Calls) / $($r.Exe) $($r.LegacyAfter) $($r.OwnAfter)"
}
Test-Case 'op-reason の task の版上げで入れ替えが落ちたら、前の exe で relay start して 1' "1 Get@0.7.0 Download Stop@0.7.0 Start@0.7.0 / $exe7 Running/True" {
    $r = Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -SshRelay per-call -Own running; "$($r.Code) $($r.Calls) / $($r.Exe) $($r.OwnAfter)"
}
Test-Case 'off の版上げで入れ替えが落ちても、前の task は消す (中継を止めるのが望む形)' "1 Status Download $StopLegacy LegacyUnregister Unlock / $exe6 none" {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay off -Legacy running; "$($r.Code) $($r.Calls) / $($r.Exe) $($r.LegacyAfter)"
}
function Move-OpReasonDirectory { param([string]$Source, [string]$Destination) [IO.Directory]::Move($Source, $Destination) }

# off: 中継を使わないホスト。どちらの task も無ければ op-reason.exe を起こさない
Test-Case 'off でどちらの task も無ければ何もしない (op-reason.exe も --status も呼ばない)' '0 ' { $r = Invoke-Flow -Have R7 -SshRelay off -Version '0.7.0'; "$($r.Code) $($r.Calls)" }
Test-Case 'off の入れ替えでも、どちらの task も無ければ op-reason.exe を起こさない' "0 Download $exe7" { $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay off; "$($r.Code) $($r.Calls) $($r.Exe)" }
Test-Case 'off で op-reason の task があれば set relay.autostart=off (op-reason が中継を止めて消す)' '0 Off@0.7.0 none /' {
    $r = Invoke-Flow -Have R7 -SshRelay off -Own running -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.OwnAfter) $($r.RelayAfter)"
}
Test-Case 'off で op-reason の task の中継が窓を開いていれば 1 (task は残る)' '1 Off@0.7.0 Running/True' {
    $r = Invoke-Flow -Have R7 -SshRelay off -Own running -LockHeld -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.OwnAfter)"
}
Test-Case 'off で前の task が動いていれば、持ち主を読み、lock を取って止めて消す' "0 Get@0.7.0 $StopLegacy LegacyUnregister Unlock none" {
    $r = Invoke-Flow -Have R7 -SshRelay off -Legacy running -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.LegacyAfter)"
}
Test-Case 'off で前の task の中継が窓を開いていれば止めずに 1 (task は残る)' "1 Get@0.7.0 Lock Running/True" {
    $r = Invoke-Flow -Have R7 -SshRelay off -Legacy running -LockHeld -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.LegacyAfter)"
}
Test-Case 'off で止まっている前の task は、lock を取らずに無効にして消す' '0 LegacyEnabled False LegacyUnregister none' {
    $r = Invoke-Flow -Have R7 -SshRelay off -Legacy ready -Version '0.7.0'; "$($r.Code) $($r.Calls) $($r.LegacyAfter)"
}

# 既定でない置き場所 (一時の置き場所で試す): task も中継も見ず・触らない
Test-Case '既定でない置き場所に -SshRelay を渡しても、task も中継も触らず、版だけ揃える' $true {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running -RelayElsewhere -NotDefault
    ($r.Code -eq 0) -and ($r.Calls -eq 'Download') -and ($r.Exe -eq $exe7) -and ($r.LegacyAfter -eq 'Running/True') -and ($r.Text -like '*置き場所が既定でないので、task も中継も見ない*')
}

# -Check: 何も変えない (task を読み、版が揃っていれば check を打つだけ)
Test-Case '-Check (初めて) は版の差で 1。前の task を移すことと、版を揃えてから確かめることを出し、--status だけを打つ' $true {
    $r = Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running -Check
    ($r.Code -eq 1) -and ($r.Calls -eq 'Status') -and ($r.LegacyAfter -eq 'Running/True') -and ($r.Exe -eq $exe6) -and
    ($r.Text -like '*⚠ 前の task        : \pjp\op-reason-ssh-relay (動いている) → 中継を止めて消す (op-reason の task に移す)*') -and
    ($r.Text -like '*  設定             : 版を揃えてから確かめる (入っている op-reason.exe は --settings を持たない)*') -and
    ($r.Text -like '*※ 動いている op-reason.exe は SSH の中継だけ*') -and
    ($r.Text -like '*⚠️ 固定した版と揃っていない → Install-OpReason -SshRelay per-call で揃える ⚠️*')
}
Test-Case '-Check で揃っていれば 0' '0 Check@0.7.0' { $r = Invoke-Flow -Have R7 -SshRelay per-call -Own running -Check -Version '0.7.0'; "$($r.Code) $($r.Calls)" }
Test-Case '-Check で中継だけ違えば 1 で、締めの行は中継の揃え方 (何も変えない)' $true {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Own running -FileMode show-only -Check -Version '0.7.0'
    ($r.Code -eq 1) -and ($r.Calls -eq 'Check@0.7.0') -and ($r.FileMode -eq 'show-only') -and
    ($r.Text -like '*⚠ relay.mode       : show-only → per-call*') -and ($r.Text -like '*⚠️ SSH の中継が揃っていない → Install-OpReason -SshRelay per-call で揃える ⚠️*')
}
Test-Case '-Check で確かめられなければ 2 で、締めの行はわけの見方' $true {
    $r = Invoke-Flow -Have R7 -SshRelay per-call -Own running -CheckFails -Check -Version '0.7.0'
    ($r.Code -eq 2) -and ($r.Text -like '*⚠️ SSH の中継を確かめられない (op-reason.exe --settings check) → 上の「設定」の行のわけを見る ⚠️*') -and ($r.Text -like '*Task Scheduler: access denied*')
}
Test-Case '-Check の off は op-reason.exe を起こさず、op-reason の task があれば 1' $true {
    $r = Invoke-Flow -Have R7 -SshRelay off -Own running -Check -Version '0.7.0'
    ($r.Code -eq 1) -and ($r.Calls -eq '') -and ($r.Text -like '*⚠ task             : ある (動いている) → 止めて消す (op-reason.exe --settings set relay.autostart=off)*')
}
Test-Case '-Check の off は op-reason.exe を起こさず、前の task があれば 1' '1 ' { $r = Invoke-Flow -Have R7 -SshRelay off -Legacy running -Check -Version '0.7.0'; "$($r.Code) $($r.Calls)" }
Test-Case 'off でどちらの task も無ければ中継の行を出さない (runner はいつも -SshRelay を渡すので、中継を使わないホストの出力は今までどおり)' $true {
    $r = Invoke-Flow -Have R7 -SshRelay off -Check -Version '0.7.0'
    ($r.Code -eq 0) -and ($r.Text -notlike '*SSH の中継*')
}
Test-Case '引数なしでも task があれば中継の行を出す (task には触らず、終了コードに数えない)' $true {
    $r = Invoke-Flow -Have R7 -Own running -Legacy ready -Check -Version '0.7.0'
    ($r.Code -eq 0) -and ($r.Calls -eq '') -and ($r.Text -like '*決めない (-SshRelay なし。task には触らない)*') -and ($r.Text -like '*  前の task        : \pjp\op-reason-ssh-relay (止まっている)*')
}

# どの流れでも、0.7.0 より前の exe に --settings を渡さない (偽物は「?…」か「@0.6.0」で控える)
Test-Case '0.7.0 より前の exe に --settings を渡さない' 0 {
    $all = @(
        (Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running),
        (Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay off -Legacy running),
        (Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -Legacy running),
        (Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running -Check)
    )
    @($all | Where-Object { $_.Calls.Contains('@0.6.0') -or $_.Calls.Contains('?') }).Count
}

# パイプラインに出すのは終了コードの 1 つだけ
Test-Case '中継の流れでも、パイプラインに出すのは終了コードの 1 つだけ' '1 1 1 1 1 1 1' {
    @((Invoke-Flow -Have R6 -Version '0.7.0' -Serve $S7 -SshRelay per-call -Legacy running).Outputs,
        (Invoke-Flow -Have R7 -SshRelay per-call -Legacy running -RegisterFails -Version '0.7.0').Outputs,
        (Invoke-Flow -Have R7 -SshRelay per-call -Own running -FileMode show-only -Version '0.7.0').Outputs,
        (Invoke-Flow -Have R7 -SshRelay off -Own running -Version '0.7.0').Outputs,
        (Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -SshRelay per-call -Own running).Outputs,
        (Invoke-Flow -Have R7 -Version '0.8.0' -Serve $S8 -SshRelay per-call -Own running -LockHeld).Outputs,
        (Invoke-Flow -Have R7 -SshRelay per-call -Own running -CheckFails -Version '0.7.0').Outputs)
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
