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
# SSH の中継 (logon の task)
# ---------------------------------------------------------------------------

# Get-OpReasonRelayTaskId: task の場所と名前
Test-Case '中継の task は \pjp\op-reason-ssh-relay' '\pjp\ op-reason-ssh-relay' { $i = Get-OpReasonRelayTaskId; "$($i.Path) $($i.Name)" }

# Get-OpReasonRelayArguments: モードごとの中継の引数 (op-reason の README の「Starting it」)
Test-Case 'per-call の引数は --ssh-agent だけ (op-reason の既定のモード)' '--ssh-agent' { Get-OpReasonRelayArguments -Mode 'per-call' }
Test-Case 'show-only の引数は --mode show-only を足す' '--ssh-agent --mode show-only' { Get-OpReasonRelayArguments -Mode 'show-only' }

# Get-OpReasonRelayWant: 置きたい task の形
$WantPC = Get-OpReasonRelayWant -Mode 'per-call' -Exe $Exe
Test-Case '置きたい task の動作は置き場所の op-reason.exe' $Exe { $WantPC.Execute }
Test-Case '置きたい task の trigger は今のユーザーの logon と、置いた時刻から 1 分ごと (期限なし)' 'logon+every PT1M' { $WantPC.Trigger }
Test-Case '置きたい task は Interactive (窓を出す)・Limited (権限を上げない)' 'Interactive Limited' { "$($WantPC.LogonType) $($WantPC.RunLevel)" }
Test-Case '時間の上限なし・2 つ目を起こさない (動いている間の 1 分ごとの trigger は何もしない)' 'PT0S IgnoreNew' { "$($WantPC.TimeLimit) $($WantPC.Multiple)" }
Test-Case '失敗したら起こし直す設定は置かない (0 でない終わり方では効かない。1 分ごとの trigger が起こし直す)' '0 []' { "$($WantPC.RestartCount) [$($WantPC.RestartInterval)]" }
Test-Case '電池でも起こして止めない・隠す・優先度は通常 (5)' 'True True 5' { "$($WantPC.Batteries) $($WantPC.Hidden) $($WantPC.Priority)" }

# 今の task の形 (Get-OpReasonRelayTask の値)。置きたい形に Enabled と State を足し、一部を差し替える
function New-TaskShape {
    param([hashtable]$Change = @{}, [string]$Mode = 'per-call', [string]$ExePath = $Exe)
    $w = Get-OpReasonRelayWant -Mode $Mode -Exe $ExePath
    $h = [ordered]@{}
    foreach ($p in $w.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h['Enabled'] = $true
    $h['State'] = 'Running'
    foreach ($k in $Change.Keys) { $h[$k] = $Change[$k] }
    [pscustomobject]$h
}

# Compare-OpReasonRelayTask: 今の task と置きたい形の違う欄
Test-Case '同じ形なら違いは無い' '' { Compare-OpReasonRelayTask -Have (New-TaskShape) -Want $WantPC }
Test-Case '置き場所は大文字小文字を問わない (Windows のパス)' '' { Compare-OpReasonRelayTask -Have (New-TaskShape @{ Execute = $Exe.ToUpperInvariant() }) -Want $WantPC }
Test-Case 'モードが違えば Arguments' 'Arguments' { Compare-OpReasonRelayTask -Have (New-TaskShape -Mode 'show-only') -Want $WantPC }
Test-Case '無効なら Enabled' 'Enabled' { Compare-OpReasonRelayTask -Have (New-TaskShape @{ Enabled = $false; State = 'Disabled' }) -Want $WantPC }
Test-Case '手で直された欄を並べる (欄の順)' 'Trigger RestartCount Hidden' { Compare-OpReasonRelayTask -Have (New-TaskShape @{ Trigger = 'logon+Time'; RestartCount = 3; Hidden = $false }) -Want $WantPC }
Test-Case '前の形 (logon だけ・失敗したら 1 分後に起こし直す設定つき) なら、Trigger と起こし直しの欄が違う (置き直す)' 'Trigger RestartCount RestartInterval' {
    Compare-OpReasonRelayTask -Have (New-TaskShape @{ Trigger = 'logon'; RestartCount = 999; RestartInterval = 'PT1M' }) -Want $WantPC
}

# Get-OpReasonRelayTriggerText: 読んだ trigger を、置きたい形の Trigger と比べる字にする。
# 偽の trigger は Get-ScheduledTask の Triggers (CIM) の形にする。UserId は logon の trigger にだけある (本物も、ほかの種類には無い)
function New-TestTrigger {
    param([string]$Kind, $UserId = $null, $Interval = $null, $Duration = $null, [string]$Start = '2026-11-22T10:00:00+09:00')
    $h = [ordered]@{
        CimClass      = [pscustomobject]@{ CimClassName = "MSFT_Task${Kind}Trigger" }
        StartBoundary = $Start
        Repetition    = [pscustomobject]@{ Interval = $Interval; Duration = $Duration; StopAtDurationEnd = $false }
    }
    if ($Kind -eq 'Logon') { $h['UserId'] = $UserId }
    [pscustomobject]$h
}
$LogonMe = New-TestTrigger -Kind 'Logon' -UserId 'PJP-RAIDEN\polle'
$EveryMinute = New-TestTrigger -Kind 'Time' -Interval 'PT1M'
Test-Case '今のユーザーの logon と 1 分ごと (期限なし) は、置きたい形と同じ字' 'logon+every PT1M' { Get-OpReasonRelayTriggerText -Triggers @($LogonMe, $EveryMinute) -Me 'polle' }
Test-Case '1 分ごとの trigger の始まりの時刻 (置いた時刻) は見ない (apply のたびに置き直さない)' 'logon+every PT1M' {
    Get-OpReasonRelayTriggerText -Triggers @($LogonMe, (New-TestTrigger -Kind 'Time' -Interval 'PT1M' -Start '2026-12-01T09:30:00+09:00')) -Me 'polle'
}
Test-Case 'DOMAIN\ の無い UserId も今のユーザーの logon' 'logon+every PT1M' { Get-OpReasonRelayTriggerText -Triggers @((New-TestTrigger -Kind 'Logon' -UserId 'polle'), $EveryMinute) -Me 'polle' }
Test-Case '間隔が違えば字も違う (置き直す)' 'logon+every PT5M' { Get-OpReasonRelayTriggerText -Triggers @($LogonMe, (New-TestTrigger -Kind 'Time' -Interval 'PT5M')) -Me 'polle' }
Test-Case '期限があれば for を足す (置き直す)' 'logon+every PT1M for P1D' { Get-OpReasonRelayTriggerText -Triggers @($LogonMe, (New-TestTrigger -Kind 'Time' -Interval 'PT1M' -Duration 'P1D')) -Me 'polle' }
Test-Case '前の形 (logon の trigger だけ) は logon' 'logon' { Get-OpReasonRelayTriggerText -Triggers @($LogonMe) -Me 'polle' }
Test-Case 'ほかのユーザーの logon は種類の名前' 'Logon+every PT1M' { Get-OpReasonRelayTriggerText -Triggers @((New-TestTrigger -Kind 'Logon' -UserId 'PJP-RAIDEN\alice'), $EveryMinute) -Me 'polle' }
Test-Case 'ユーザーを決めない logon (だれの logon でも) は種類の名前' 'Logon' { Get-OpReasonRelayTriggerText -Triggers @(New-TestTrigger -Kind 'Logon' -UserId $null) -Me 'polle' }
Test-Case '繰り返さない 1 回の trigger と、ほかの種類は種類の名前' 'logon+Time+Daily' {
    Get-OpReasonRelayTriggerText -Triggers @($LogonMe, (New-TestTrigger -Kind 'Time'), (New-TestTrigger -Kind 'Daily')) -Me 'polle'
}
Test-Case 'trigger が無ければ空' '' { Get-OpReasonRelayTriggerText -Triggers @() -Me 'polle' }

# ConvertFrom-OpReasonRelayStatus: --status の出力の PID (op-reason の relay_status の文。英語と日本語)
Test-Case '英語の出力から PID' 4242 { ConvertFrom-OpReasonRelayStatus -Code 0 -Text 'the SSH relay answers on \\.\pipe\op-reason-ssh-agent (pid 4242)' }
Test-Case '日本語の出力から PID' 4242 { ConvertFrom-OpReasonRelayStatus -Code 0 -Text 'SSH の中継が \\.\pipe\op-reason-ssh-agent で答えています (pid 4242)' }
Test-Case '答えていなければ (終了コード 1) 空' '' { ConvertFrom-OpReasonRelayStatus -Code 1 -Text 'nothing answers on \\.\pipe\op-reason-ssh-agent' }
Test-Case '終了コードが 0 でも PID の無い文なら空' '' { ConvertFrom-OpReasonRelayStatus -Code 0 -Text 'unexpected' }
Test-Case '終了コードが 0 でなければ PID のある文でも空' '' { ConvertFrom-OpReasonRelayStatus -Code 2 -Text '(pid 1)' }

# Get-OpReasonRelayPlan: 中継にすること
$TaskRunning = New-TaskShape
$TaskReady = New-TaskShape @{ State = 'Ready' }
Test-Case '引数なし (runner) は task があっても none (task に触らない)' 'none' { Get-OpReasonRelayPlan -Want '' -Task $TaskRunning -Diff @('Arguments') -RelayPid $null }
Test-Case 'off で task があれば remove' 'remove' { Get-OpReasonRelayPlan -Want 'off' -Task $TaskRunning -Diff @() -RelayPid 4242 }
Test-Case 'off で task が無ければ none' 'none' { Get-OpReasonRelayPlan -Want 'off' -Task $null -Diff @() -RelayPid $null }
Test-Case 'モードで task が無ければ register' 'register' { Get-OpReasonRelayPlan -Want 'per-call' -Task $null -Diff @() -RelayPid $null }
Test-Case '形が違えば update' 'update' { Get-OpReasonRelayPlan -Want 'per-call' -Task $TaskRunning -Diff @('Arguments') -RelayPid 4242 }
Test-Case '同じ形で答えず、task が動いていれば restart' 'restart' { Get-OpReasonRelayPlan -Want 'per-call' -Task $TaskRunning -Diff @() -RelayPid $null }
Test-Case '同じ形で答えず、task が止まっていれば start' 'start' { Get-OpReasonRelayPlan -Want 'per-call' -Task $TaskReady -Diff @() -RelayPid $null }
Test-Case '同じ形で答えていれば none' 'none' { Get-OpReasonRelayPlan -Want 'show-only' -Task $TaskRunning -Diff @() -RelayPid 4242 }

# Get-OpReasonSwapAction: 置き場所を入れ替える前に止めるもの (中継の無いホストでは、入れ替えるのに動いていれば busy)
Test-Case '入れるだけなら swap (動いている数は見ない)' 'swap' { Get-OpReasonSwapAction -Plan 'install' -Busy @(1) -RelayPid $null -TaskRunning $false }
Test-Case '揃っていれば swap (入れ替えないので止めない)' 'swap' { Get-OpReasonSwapAction -Plan 'none' -Busy @(1, 2, 3) -RelayPid $null -TaskRunning $false }
Test-Case '中継の無いホストで入れ替えるのに動いていれば busy' 'busy' { Get-OpReasonSwapAction -Plan 'change' -Busy @(1001) -RelayPid $null -TaskRunning $false }
Test-Case '入れ替えで動いていなければ swap' 'swap' { Get-OpReasonSwapAction -Plan 'change' -Busy @() -RelayPid 4242 -TaskRunning $true }
Test-Case '動いているのが task の中継だけなら stop-relay' 'stop-relay' { Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid 4242 -TaskRunning $true }
Test-Case 'ほかの op-reason.exe (op の呼び出し) も動いていれば busy' 'busy' { Get-OpReasonSwapAction -Plan 'change' -Busy @(4242, 77) -RelayPid 4242 -TaskRunning $true }
Test-Case '中継が task のものでなければ (手で起こした) busy' 'busy' { Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid 4242 -TaskRunning $false }
Test-Case '中継が答えないのに動いていれば busy' 'busy' { Get-OpReasonSwapAction -Plan 'change' -Busy @(4242) -RelayPid $null -TaskRunning $true }

# Get-OpReasonExitCode: 中継の計画も見る
Test-Case '版も中継も揃っていれば 0' 0 { Get-OpReasonExitCode -State (New-State) -RelayPlan 'none' }
Test-Case '版は揃っていて中継にすることがあれば 1' 1 { Get-OpReasonExitCode -State (New-State) -RelayPlan 'start' }
Test-Case '入っていなければ中継によらず 3' 3 { Get-OpReasonExitCode -State (New-State $missing) -RelayPlan 'register' }

# Format-OpReasonRelayState: 状態の表の中継の行 (見出し・望む形・task・中継)
function Get-RelayRows {
    param([string]$Want, $Task, [string[]]$Diff = @(), $RelayPid, [string]$Plan = 'none')
    @(Format-OpReasonRelayState -Want $Want -Task $Task -Diff $Diff -RelayPid $RelayPid -Plan $Plan)
}
Test-Case '見出しは task の場所と名前' 'SSH の中継 (logon の task \pjp\op-reason-ssh-relay)' { (Get-RelayRows -Want 'per-call' -Task $TaskRunning -RelayPid 4242)[0].Text }
Test-Case '揃っていれば ⚠ の行は無い' 0 { @((Get-RelayRows -Want 'per-call' -Task $TaskRunning -RelayPid 4242) | Where-Object { $_.Warn }).Count }
Test-Case '望む形の行 (per-call)' '  望む形           : per-call (op-reason.exe --ssh-agent)' { (Get-RelayRows -Want 'per-call' -Task $TaskRunning -RelayPid 4242)[1].Text }
Test-Case '望む形の行 (show-only)' '  望む形           : show-only (op-reason.exe --ssh-agent --mode show-only)' { (Get-RelayRows -Want 'show-only' -Task $null -RelayPid $null -Plan 'register')[1].Text }
Test-Case '望む形の行 (off)' '  望む形           : 置かない (-SshRelay off)' { (Get-RelayRows -Want 'off' -Task $null -RelayPid $null)[1].Text }
Test-Case '望む形の行 (引数なし)' '  望む形           : 決めない (-SshRelay なし。task には触らない)' { (Get-RelayRows -Want '' -Task $TaskRunning -RelayPid 4242)[1].Text }
Test-Case '動いている task の行' '  task             : ある (動いている)' { (Get-RelayRows -Want 'per-call' -Task $TaskRunning -RelayPid 4242)[2].Text }
Test-Case '答えている中継の行' '  中継             : 答えている (pid 4242)' { (Get-RelayRows -Want 'per-call' -Task $TaskRunning -RelayPid 4242)[3].Text }
Test-Case 'task が無ければ置いて起こすで ⚠' '⚠ task             : 無い → 置いて起こす' { (Get-RelayRows -Want 'per-call' -Task $null -RelayPid $null -Plan 'register')[2].Text }
Test-Case '形が違えば違う欄を出して置き直すで ⚠' '⚠ task             : 形が違う (Arguments・Enabled) → 置き直して起こし直す' { (Get-RelayRows -Want 'per-call' -Task $TaskRunning -Diff @('Arguments', 'Enabled') -RelayPid 4242 -Plan 'update')[2].Text }
Test-Case '答えず止まっていれば起こすで ⚠' '⚠ 中継             : 答えない → 起こす' { (Get-RelayRows -Want 'per-call' -Task $TaskReady -RelayPid $null -Plan 'start')[3].Text }
Test-Case '答えず動いていれば起こし直すで ⚠' '⚠ 中継             : 答えない → 起こし直す' { (Get-RelayRows -Want 'per-call' -Task $TaskRunning -RelayPid $null -Plan 'restart')[3].Text }
Test-Case 'off で task があれば止めて消すで ⚠' '⚠ task             : ある (動いている) → 止めて消す' { (Get-RelayRows -Want 'off' -Task $TaskRunning -RelayPid 4242 -Plan 'remove')[2].Text }
Test-Case 'off で task が無ければ task の行まで (中継の行は出さない)' '3 /   task             : 無い' { $r = Get-RelayRows -Want 'off' -Task $null -RelayPid $null; "$($r.Count) / $($r[-1].Text)" }

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
    [ordered]@{ $Older = @{ Zip = $FixOld.Zip; Tree = $FixOld.Tree }; $V = @{ Zip = $FixV.Zip; Tree = $FixV.Tree } }
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

# 中継の偽物。task は $script:Task (今の形)、中継は $script:RelayPid (答える PID か $null)、動いている op-reason.exe は $script:Busy。
# 呼ばれたもの (Get-OpReasonRelayTask のほか) を順に $script:Calls に残す。$script:LockHeld なら lock を取れない (窓が開いている)、
# $script:NoAnswer なら task を起こしても中継が答えない、$script:StopHangs なら task を止めても中継のプロセスが終わらない
$RelayOldPid = 4242
$RelayNewPid = 5151
function Get-OpReasonRelayTask { $script:Task }
function Register-OpReasonRelayTask {
    param($Want)
    $script:Calls.Add("Register $($Want.Arguments)")
    $script:Task = New-TaskShape -Mode $(if ($Want.Arguments -like '*show-only*') { 'show-only' } else { 'per-call' }) -ExePath $Want.Execute -Change @{ State = 'Ready' }
}
function Unregister-OpReasonRelayTask { $script:Calls.Add('Unregister'); $script:Task = $null }
function Start-OpReasonRelayTask {
    $script:Calls.Add('Start')
    if ($script:Task -and $script:Task.Enabled -and -not $script:NoAnswer) {
        $script:RelayPid = $RelayNewPid
        $script:Task.State = 'Running'
    }
}
function Stop-OpReasonRelayTask {
    $script:Calls.Add('Stop')
    if ($script:StopHangs) { return }
    $script:Busy = @($script:Busy | Where-Object { $_.Id -ne $script:RelayPid })
    $script:RelayPid = $null
    if ($script:Task) { $script:Task.State = $(if ($script:Task.Enabled) { 'Ready' } else { 'Disabled' }) }
}
function Set-OpReasonRelayTaskEnabled {
    param([bool]$Enabled)
    $script:Calls.Add("Enabled $Enabled")
    $script:Task.Enabled = $Enabled
    if (-not $Enabled -and $script:Task.State -ne 'Running') { $script:Task.State = 'Disabled' }
    if ($Enabled -and $script:Task.State -eq 'Disabled') { $script:Task.State = 'Ready' }
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

# 1 回ぶんの流れを走らせ、落とした URL・画面の行・終了コードと、終わった後の置き場所を返す。
#   -Have: 置き場所にある中身 ('' なら無い。V・Old・Bad は作り物の中身を写す)。-Serve: 落とすと返る中身 (-ServeNothing なら何も書かない)
#   -Busy: 動いている数。-DownloadError: 落とすと出る例外の文。-NoParent: 置き場所の親ディレクトリも無い
#   -Stale・-Fresh: 前の実行が残した途中の物 (1 時間前・今) を置き場所の隣に置く
#   -SshRelay: スクリプトに渡す値 (per-call・show-only・off。'' なら渡さない)。-Task: 今の中継の task (running・show-only は答える中継が
#   動いていて、入っていればそのプロセスも動いている op-reason.exe に数える。ready は止まっている・disabled は無効・silent は動いているのに
#   答えない。'' なら無い)。-LockHeld・-NoAnswer・-StopHangs は上の偽物の説明
function Invoke-Flow {
    param(
        [string]$Have = '', [byte[]]$Serve = $FixV.Bytes, [int]$Busy = 0, [string]$DownloadError = '',
        [string]$Version = $V, [switch]$Check, [switch]$ServeNothing, [switch]$NoParent, [switch]$Stale, [switch]$Fresh,
        [string]$SshRelay = '', [string]$Task = '', [switch]$LockHeld, [switch]$NoAnswer, [switch]$StopHangs
    )
    Remove-Item -LiteralPath $FlowParent -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $NoParent) { New-Item -ItemType Directory -Force -Path $FlowParent | Out-Null }
    $from = switch ($Have) { 'V' { $FixV.Content } 'Old' { $FixOld.Content } 'Bad' { $FixBad.Content } default { $null } }
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
    $script:LockHeld = [bool]$LockHeld
    $script:NoAnswer = [bool]$NoAnswer
    $script:StopHangs = [bool]$StopHangs
    $script:Task = $null
    $script:RelayPid = $null
    switch ($Task) {
        'running' { $script:Task = New-TaskShape -ExePath $FlowExe; $script:RelayPid = $RelayOldPid }
        'show-only' { $script:Task = New-TaskShape -Mode 'show-only' -ExePath $FlowExe; $script:RelayPid = $RelayOldPid }
        'ready' { $script:Task = New-TaskShape -ExePath $FlowExe -Change @{ State = 'Ready' } }
        'disabled' { $script:Task = New-TaskShape -ExePath $FlowExe -Change @{ Enabled = $false; State = 'Disabled' } }
        'silent' { $script:Task = New-TaskShape -ExePath $FlowExe }
    }
    # 置き場所から動いている中継は、入れ替えの邪魔になる op-reason.exe でもある
    if ($script:RelayPid -and $from) { $script:Busy = @([pscustomobject]@{ Id = $RelayOldPid; Path = $FlowExe }) + @($script:Busy) }
    $relayArgs = @{}
    if ($SshRelay) { $relayArgs['SshRelay'] = $SshRelay }
    $out = @(Invoke-InstallOpReason -Version $Version -Check:$Check -InstallDir $FlowInstallDir @relayArgs 6>&1)
    $leftover = @()
    if (Test-Path -LiteralPath $FlowParent) {
        $leftover = @(Get-ChildItem -LiteralPath $FlowParent -Force | Where-Object { $_.Name -ne 'op-reason' } | ForEach-Object { $_.Name } | Sort-Object)
    }
    [pscustomobject]@{
        Code       = @($out | Where-Object { $_ -is [int] })[-1]
        Text       = (@($out | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
        Downloads  = ($script:Downloads -join ' ')
        # 置き場所の op-reason.exe の中身 (作り物の文字) と、中身の値
        Exe        = $(if (Test-Path -LiteralPath $FlowExe) { [IO.File]::ReadAllText($FlowExe) } else { 'none' })
        Tree       = $(if (Test-Path -LiteralPath $FlowInstallDir) { Get-OpReasonTreeHash -Dir $FlowInstallDir } else { 'none' })
        ParentExists = (Test-Path -LiteralPath $FlowParent)
        Leftover   = ($leftover -join ' ')
        # パイプラインに出たもの (Write-Host の行を除く) の数。終了コードの 1 つだけのはず
        Outputs    = @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count
        # 偽物が呼ばれた順 (Download と中継の偽物)・終わった後の task (引数と状態。無ければ none)・答える中継の PID
        Calls      = ($script:Calls -join ' ')
        TaskAfter  = $(if ($script:Task) { "$($script:Task.Arguments) $($script:Task.State)" } else { 'none' })
        RelayAfter = $script:RelayPid
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
# SSH の中継 (-SshRelay と、task のあるホストの版上げ)。task・--status・lock は上の偽物 (呼ばれた順を Calls に残す)
# ---------------------------------------------------------------------------

$PCReg = 'Register --ssh-agent'
$Stop4242 = "Lock Enabled False Stop WaitExit $RelayOldPid"

# -SshRelay を渡さず task も無いホスト (runner と、中継を使ったことの無いホスト) は今までどおり
Test-Case '-SshRelay も task も無ければ、中継の行を出さず、--status も task も呼ばない' $true {
    $r = Invoke-Flow -Have Old
    ($r.Code -eq 0) -and ($r.Calls -eq 'Download') -and ($r.Text -notlike '*SSH の中継*')
}

# 置く・起こす
Test-Case 'per-call で入っていなければ、入れてから task を置いて起こし、答えるのを見て 0' "0 Download $PCReg Start Wait Status $exeV" {
    $r = Invoke-Flow -SshRelay per-call; "$($r.Code) $($r.Calls) $($r.Exe)"
}
Test-Case '揃っていて task が無ければ、落とさずに task を置いて起こす' "0 [] Status $PCReg Start Wait Status" {
    $r = Invoke-Flow -Have V -SshRelay per-call; "$($r.Code) [$($r.Downloads)] $($r.Calls)"
}
Test-Case '置いた task の引数はモードのもの (show-only)' '--ssh-agent --mode show-only Running' { (Invoke-Flow -Have V -SshRelay show-only).TaskAfter }
Test-Case '起こしても答えなければ、わけと見る所を出して 1' $true {
    $r = Invoke-Flow -Have V -SshRelay per-call -NoAnswer
    ($r.Code -eq 1) -and ($r.Calls -eq "Status $PCReg Start Wait") -and ($r.Text -like '*SSH の中継が答えない*') -and ($r.Text -like '*Get-ScheduledTaskInfo*')
}
Test-Case 'task も中継も揃っていれば何もしない (0)' '0 Status' { $r = Invoke-Flow -Have V -SshRelay per-call -Task running; "$($r.Code) $($r.Calls)" }
Test-Case 'task が止まっていれば起こす' '0 Status Start Wait Status' { $r = Invoke-Flow -Have V -SshRelay per-call -Task ready; "$($r.Code) $($r.Calls)" }
Test-Case '無効な task は置き直して起こす (止める中継は無い)' "0 Status $PCReg Start Wait Status" { $r = Invoke-Flow -Have V -SshRelay per-call -Task disabled; "$($r.Code) $($r.Calls)" }
Test-Case 'task が動いているのに答えなければ、lock を取って止めてから起こし直す' '0 Status Lock Enabled False Stop Enabled True Start Wait Unlock Status' {
    $r = Invoke-Flow -Have V -SshRelay per-call -Task silent; "$($r.Code) $($r.Calls)"
}

# モードを替える: 動いている中継は起こし直さないとモードが替わらない
Test-Case 'モードが替われば、lock を取って止め、置き直して起こし直す' "0 Status $Stop4242 Register --ssh-agent --mode show-only Enabled True Start Wait Unlock Status" {
    $r = Invoke-Flow -Have V -SshRelay show-only -Task running; "$($r.Code) $($r.Calls)"
}
Test-Case 'モードが替わっても、中継が窓を開いていれば (lock を取れない) 何も変えずに 1' '1 Status Lock / --ssh-agent Running' {
    $r = Invoke-Flow -Have V -SshRelay show-only -Task running -LockHeld; "$($r.Code) $($r.Calls) / $($r.TaskAfter)"
}
Test-Case '窓が開いていて止めないときは、答えてから打ち直すよう出す' $true {
    $r = Invoke-Flow -Have V -SshRelay show-only -Task running -LockHeld
    ($r.Text -like '*窓を開いている*') -and ($r.Text -like '*答えてから打ち直す*')
}

# off: task を止めて消す (窓が開いていれば止めない)
Test-Case 'off で task があれば、lock を取って止めて消す' "0 Status $Stop4242 Unregister Unlock / none" {
    $r = Invoke-Flow -Have V -SshRelay off -Task running; "$($r.Code) $($r.Calls) / $($r.TaskAfter)"
}
Test-Case 'off で窓が開いていれば止めずに 1 (task は残る)' '1 Status Lock / --ssh-agent Running' {
    $r = Invoke-Flow -Have V -SshRelay off -Task running -LockHeld; "$($r.Code) $($r.Calls) / $($r.TaskAfter)"
}
Test-Case 'off で止まっている task は lock を取らずに消す' '0 Status Unregister / none' {
    $r = Invoke-Flow -Have V -SshRelay off -Task ready; "$($r.Code) $($r.Calls) / $($r.TaskAfter)"
}
Test-Case 'off で task が無ければ何もしない (--status も呼ばない)' '0 ' { $r = Invoke-Flow -Have V -SshRelay off; "$($r.Code) $($r.Calls)" }

# 版上げ: 動いているのが task の中継だけなら、落として確かめてから lock を取って止め、入れ替えて起こし直す
Test-Case '版上げで動いているのが中継だけなら、落として確かめてから止め、入れ替えて起こし直す' "0 Status Download $Stop4242 Enabled True Start Wait Unlock Status $exeV" {
    $r = Invoke-Flow -Have Old -SshRelay per-call -Task running; "$($r.Code) $($r.Calls) $($r.Exe)"
}
Test-Case '版上げで中継が窓を開いていれば、入れ替えず、task に触らずに 1 (落とした物は残さない)' "1 Status Download Lock $exeOld [] --ssh-agent Running" {
    $r = Invoke-Flow -Have Old -SshRelay per-call -Task running -LockHeld; "$($r.Code) $($r.Calls) $($r.Exe) [$($r.Leftover)] $($r.TaskAfter)"
}
Test-Case '版上げでほかの op-reason.exe (op の呼び出し) も動いていれば、落とさずに 1 で PID を出す' $true {
    $r = Invoke-Flow -Have Old -SshRelay per-call -Task running -Busy 1
    ($r.Code -eq 1) -and ($r.Calls -eq 'Status') -and ($r.Text -like '*1001*') -and ($r.Exe -eq $exeOld)
}
Test-Case 'runner (引数なし) の版上げでも、task の中継だけなら止めて入れ替えて起こし直す (task は置き直さない)' "0 Status Download $Stop4242 Enabled True Start Wait Unlock Status $exeV --ssh-agent Running" {
    $r = Invoke-Flow -Have Old -Task running; "$($r.Code) $($r.Calls) $($r.Exe) $($r.TaskAfter)"
}
Test-Case '中継のプロセスが止まらなければ、入れ替えず、task を有効に戻して 1' "1 Status Download $Stop4242 Enabled True Unlock $exeOld" {
    $r = Invoke-Flow -Have Old -SshRelay per-call -Task running -StopHangs; "$($r.Code) $($r.Calls) $($r.Exe)"
}
Test-Case 'off に替えた版上げは、止めて入れ替えてから task を消す (起こし直さない)' "0 Status Download $Stop4242 Unregister Unlock $exeV none" {
    $r = Invoke-Flow -Have Old -SshRelay off -Task running; "$($r.Code) $($r.Calls) $($r.Exe) $($r.TaskAfter)"
}
# 止めた後に入れ替えが落ちたら、止めた中継を起こし直す (前の中身のまま)
function Move-OpReasonDirectory {
    param([string]$Source, [string]$Destination)
    if ($Source -eq $FlowInstallDir) { throw 'The process cannot access the file because it is being used by another process.' }
    [IO.Directory]::Move($Source, $Destination)
}
Test-Case '止めた後に入れ替えが落ちたら、有効に戻して起こし直し、1' "1 Status Download $Stop4242 Enabled True Start Wait Unlock $exeOld" {
    $r = Invoke-Flow -Have Old -SshRelay per-call -Task running; "$($r.Code) $($r.Calls) $($r.Exe)"
}
function Move-OpReasonDirectory { param([string]$Source, [string]$Destination) [IO.Directory]::Move($Source, $Destination) }

# -Check: task と --status を見るだけ
Test-Case '-Check は task と --status を見るだけで、何も変えない (中継だけ違えば 1)' '1 Status none' {
    $r = Invoke-Flow -Have V -SshRelay per-call -Check; "$($r.Code) $($r.Calls) $($r.TaskAfter)"
}
Test-Case '-Check で中継だけ違えば、締めの行は中継の揃え方' $true {
    (Invoke-Flow -Have V -SshRelay per-call -Check).Text -like '*⚠️ SSH の中継が揃っていない → Install-OpReason -SshRelay per-call で揃える ⚠️*'
}
Test-Case '-Check で版が違えば、締めの行の揃え方に -SshRelay を添える' $true {
    (Invoke-Flow -Have Old -SshRelay per-call -Task running -Check).Text -like '*⚠️ 固定した版と揃っていない → Install-OpReason -SshRelay per-call で揃える ⚠️*'
}
Test-Case '-Check で動いているのが中継だけなら、※ で止めて起こし直すことを添える' $true {
    $t = (Invoke-Flow -Have Old -SshRelay per-call -Task running -Check).Text
    ($t -like '*※ 動いている op-reason.exe は SSH の中継だけ*') -and ($t -notlike '*op の呼び出しの途中*')
}
Test-Case '-Check は中継の行を出す (見出し・望む形・task・中継)' $true {
    $t = (Invoke-Flow -Have V -SshRelay per-call -Task running -Check).Text
    ($t -like '*SSH の中継 (logon の task \pjp\op-reason-ssh-relay)*') -and ($t -like '*答えている (pid 4242)*')
}
Test-Case '引数なしでも task があれば、中継の行を出す (task には触らない)' $true {
    $r = Invoke-Flow -Have V -Task running -Check
    ($r.Code -eq 0) -and ($r.Text -like '*決めない (-SshRelay なし。task には触らない)*')
}

# パイプラインに出すのは終了コードの 1 つだけ
Test-Case '中継の流れでも、パイプラインに出すのは終了コードの 1 つだけ' '1 1 1 1 1 1' {
    @((Invoke-Flow -SshRelay per-call).Outputs, (Invoke-Flow -Have V -SshRelay per-call -NoAnswer).Outputs,
        (Invoke-Flow -Have V -SshRelay show-only -Task running).Outputs, (Invoke-Flow -Have V -SshRelay off -Task running).Outputs,
        (Invoke-Flow -Have Old -SshRelay per-call -Task running).Outputs, (Invoke-Flow -Have Old -SshRelay per-call -Task running -LockHeld).Outputs)
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) 件失敗"
    exit 1
}
Write-Host 'すべて通った'
