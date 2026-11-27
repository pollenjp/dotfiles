<#
.SYNOPSIS
Windows の op-reason (pollenjp/op-reason の GitHub の Release の op-reason-windows.zip) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/op-reason/Install-OpReason.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-OpReason から呼ぶ (win/README.md の「op-reason」)。

op-reason は 1Password CLI (op) の wrapper (自作の OSS)。WSL の op (dotfiles の home/modules/op-reason.nix が入れる、Release の
Linux の実行ファイル) は、呼び出しごとに Windows の op-reason.exe (動かないときは隣の launcher.ps1) を起こして承認の窓を出す。
その Windows の部品が op-reason-windows.zip (op-reason.exe・launcher.ps1・powershell-entry\・SKILL.md・README・ライセンス) で、
WSL の実行ファイルと同じ版にそろえる (呼び出しの取り決め (payload の版) が変わった版どうしでは断られる。0.1.0 から 0.9.0 まで同じ取り決め)。

固定した版の zip を GitHub の Release から落とし、SHA-256 が表 (Get-OpReasonReleases) の Zip と合うときだけ隣に展開し、
展開した中身が表の Tree と合えば %LOCALAPPDATA%\Programs\op-reason と入れ替える。合わなければ何も変えずに止まる。
WSL の op は、この置き場所の op-reason.exe を OPREASON_EXE で指す (home/modules/op-reason.nix)。Windows の PATH には足さない。

入っている版は、置き場所の中身の Tree (全部のファイルの SHA-256 と相対パスから作る値。Get-OpReasonTreeHash) を表と
突き合わせて決める。op-reason.exe は署名が無く Smart App Control に止められうるので、--version は聞かない。
動いている op-reason.exe (op の呼び出しの途中) があると置き場所を入れ替えられないので、入れ替えが要るときに動いていれば、
何も変えずに止まって知らせる (止めはしない。承認を待っている途中かもしれないため)。記録 (%LOCALAPPDATA%\op-reason) には
触らない。

SSH の中継 (op-reason.exe --ssh-agent。1Password の SSH agent の前に立ち、鍵を使う呼び出しごとに窓を出す) は、0.7.0 から op-reason
自身の task (root のフォルダの \op-reason-ssh-relay-<SID>) が起こす。-SshRelay を渡されたら、その task と中継を op-reason の CLI
(op-reason.exe --settings check・set) で揃える (win/README.md の「SSH の中継」。op-reason の設計 2026-11-23-settings-design.md の §18)。
0.6.0 までこのスクリプトが置いた task (\pjp\op-reason-ssh-relay) は、中継を止めてから 1 回だけ消して移す。入れ替えのときに動いて
いる op-reason.exe が中継だけなら、中継を止め (op-reason の task のものは op-reason.exe --settings relay stop、前の task のものは
op-reason の lock (Local\op-reason) を取ってから)、入れ替えてから起こし直す。中継が窓を開いている間は止めず、今までどおり何も
変えずに止まる。中継を使わないホスト (-SshRelay off で、どちらの task も無い) では op-reason.exe を起こさない (Smart App Control)。

BOM 付きの UTF-8 で保存すること (Windows PowerShell 5.1 は BOM の無い UTF-8 を CP932 として読む)。

.PARAMETER Version
固定する版。表 (Get-OpReasonReleases) にある版。版を上げるときは、表に行を足してここの既定値を変える
(WSL の nix/pkgs/op-reason/default.nix の version と同じ版にする)。

.PARAMETER Check
今の状態と固定した版との差を出すだけで、何も変えない (ネットワークも使わない)。揃っていれば終了コード 0、差があれば 1、
入っていなければ 3。

.PARAMETER InstallDir
展開した中身を置くディレクトリ。既定は %LOCALAPPDATA%\Programs\op-reason (WSL の OPREASON_EXE の既定が指す場所)。
試すときだけ一時ディレクトリへ向ける。落とした zip と途中の物は、その隣 (同じ親ディレクトリ) に置く。

.PARAMETER SshRelay
SSH の中継をどうするか。per-call・show-only (中継のモード) なら、op-reason.exe --settings check relay.autostart=on
relay.mode=<モード> relay.running=on --json で比べ、違えば同じ値の set で揃える (op-reason が自分の task を作り、中継を起こして
答えるのを 15 秒待つ)。前の task (\pjp\op-reason-ssh-relay) があれば、先に中継を止めて消す。off なら、op-reason の task があれば
set relay.autostart=off (op-reason が中継を止めて task を消す)、前の task があれば中継を止めて消す。どちらも、中継が窓を開いて
いる間は止めない。-Check は比べるだけで何も変えず、check で確かめられなければ終了コード 2。--settings は 0.7.0 からの
op-reason.exe にだけ渡す (入れ替えが要れば、入れ替えた後の exe で打つ)。置き場所が既定 (%LOCALAPPDATA%\Programs\op-reason)
でなければ、task にも中継にも触らない (一時の置き場所で試すときに、本物の task をその置き場所の exe に向けない)。
Windows の runner の手順 op-reason が、ホストの値の道具の switch opReasonSshRelay と [opReason] sshRelayMode から渡す (switch が off
なら off)。渡さなければ (WSL の setup の bootstrap-windows-op-reason.sh・手で打つ Install-OpReason) task を作りも消しもしない
(入れ替えのときに中継を止めて起こし直すのは同じ)。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.9.0',
    [switch]$Check,
    [string]$InstallDir = '',
    [ValidateSet('per-call', 'show-only', 'off')]
    [string]$SshRelay
)

# ---------------------------------------------------------------------------
# 副作用の無い関数 (Install-OpReason.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 版ごとの SHA-256 (小文字の 16 進)。
#   Zip   Release に置いた op-reason-windows.zip.sha256 の中身
#   Tree  zip を展開した op-reason-windows の中身の値 (Get-OpReasonTreeText の文字列の SHA-256)。入っている版を決めるのに使う
# 版を上げるときは行を足して -Version の既定値を変える。古い版の行は、入っている版を名前で出すために残す
function Get-OpReasonReleases {
    [ordered]@{
        '0.1.0' = @{
            Zip  = '4b664af358559faf8e94a1142f579236846d75a8e6698dee66dbf35bb0335fb0'
            Tree = 'b2b09e1c101a7b1da0a9facd81cac8f18ad4018d9a34ecac04db38133d9e796a'
        }
        '0.2.0' = @{
            Zip  = '6e9a104484a019da093726d0bad2ee3da7cedb2e238a592e12c67dcc2336dbf3'
            Tree = '5ced1fd007b3a92b3bc3539915babdb14c9064548dbb176031427b004342619b'
        }
        '0.3.0' = @{
            Zip  = '28bf706c426fbd3a64097aab8082bd26fda2b9b281cf5bbbfb22b3142bd4d7e1'
            Tree = 'db5677cc7535d97f78d3a9355dac60d22a92aa1fb02b9f771242b4552b57eb5a'
        }
        '0.4.0' = @{
            Zip  = '557ac348182f9adcddb1697db9f8820e551bf7abd7fc0ee0181a766cd543f3db'
            Tree = 'ccb6f0aa1380d4ae0257273d992cd6859b8189b57d0783a32d0aaf8b700730ee'
        }
        '0.5.0' = @{
            Zip  = 'ff7c40063b0201e5d0e66c1ed495047c479d5c5eaad21ce1c42889328b15826e'
            Tree = '7d72ad737aa4b9c87ed325b969fba1f9761cf0fa6cdddbff12edc197e5f20d66'
        }
        '0.6.0' = @{
            Zip  = '0a0ee1e06e3be572a2fc7b4e3e8eea199484410f063a992a4ed6d48581e14c41'
            Tree = '1a3d3ff97d38f7a2056b1295c5d62320e61dcb3f9b3ef8ea3061344a7eec4141'
        }
        '0.7.0' = @{
            Zip  = '998ce5648effca76c13b6851f237ad4297b56be20966ec9d70124353f43ea56d'
            Tree = '66643719adc0505c3b64010f573f8be56cc57ee1da652e42ce115502c8511dfc'
        }
        '0.8.0' = @{
            Zip  = '94b1fff595c3684daa9d3be07c0eb65d37eaa4a2e68015ec66820d0aea9a41c1'
            Tree = '2c50f0f8068ffbc4a06875c840e268a338827b1ecca88473a2a87bd85c2c67ca'
        }
        '0.8.1' = @{
            Zip  = '3b47e7458d80169d1fed5a38bb207520459bfa0ee1bedb76abd4c50d45da36aa'
            Tree = '918cb136368299769d32194cd5765ccb3ab3b86619c1545fcec95f2f6b67f2e2'
        }
        '0.9.0' = @{
            Zip  = 'a7d591849cb06f03000e106e5a6d420cf44ec53bc1e3560cc9d110f158247775'
            Tree = 'd7276a312b9ec761940d7b4199fdc3fa1d2bed89f8e1baedb11dc628a9891b91'
        }
    }
}

# 版の Release の zip の URL
function Get-OpReasonDownloadUrl {
    param([string]$Version)
    "https://github.com/pollenjp/op-reason/releases/download/v$Version/op-reason-windows.zip"
}

# 中身の値 (Tree) から表の版を引く。無ければ $null (-eq は大文字小文字を区別しない)
function Find-OpReasonVersion {
    param($Releases, [string]$Tree)
    if (-not $Tree) { return $null }
    foreach ($key in $Releases.Keys) {
        if ($Releases[$key].Tree -eq $Tree) { return $key }
    }
    $null
}

# SHA-256 が固定した値と同じか。どちらかが空なら同じと見ない
function Test-OpReasonHashMatch {
    param([string]$Expected, [string]$Actual)
    [bool]($Expected -and $Actual -and ($Expected -eq $Actual))
}

# 中身の一覧 (相対パス → SHA-256) から、Tree の元になる文字列を作る。sha256sum の出力と同じ「<SHA-256>␣␣<相対パス>」の行を、
# 相対パスの序数の順 (ordinal。LC_ALL=C の sort と同じ) に並べ、どの行も LF で終える。相対パスの区切りは /
function Get-OpReasonTreeText {
    param([hashtable]$Entries)
    [string[]]$paths = @($Entries.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $sb = [Text.StringBuilder]::new()
    foreach ($p in $paths) {
        [void]$sb.Append("$($Entries[$p].ToLowerInvariant())  $p`n")
    }
    $sb.ToString()
}

# 文字列の UTF-8 (BOM なし) の SHA-256 (小文字の 16 進)
function Get-OpReasonTextHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
    }
}

# 入っているか・入っている版・固定した版から、することを決める。
# 置き場所があるのに表のどの版でもないときも入れ替える (固定した版にすれば揃う)
function Get-OpReasonPlan {
    param([bool]$Exists, [string]$Installed, [string]$Target)
    if (-not $Exists) { return 'install' }
    if ($Installed -cne $Target) { return 'change' }
    'none'
}

# 入れ替えの向き。版は X.Y.Z なので [version] で比べる (0.10.0 は 0.9.0 より新しい)
function Get-OpReasonDirection {
    param([string]$Installed, [string]$Target)
    $i = $null
    $t = $null
    if ((-not $Installed) -or (-not [version]::TryParse($Installed, [ref]$i)) -or (-not [version]::TryParse($Target, [ref]$t))) {
        return 'unknown'
    }
    if ($t -gt $i) { return 'up' }
    if ($t -lt $i) { return 'down' }
    'same'
}

# 動いている op-reason.exe が、置き場所を入れ替える邪魔になるか。
# パスが読めない (管理者として動いているなど) ときは、置き場所のものかもしれないので邪魔と見る
function Test-OpReasonBusyPath {
    param([string]$Path, [string]$InstallDir)
    if (-not $Path) { return $true }
    $Path.StartsWith($InstallDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

# 終了コード。入っていなければ 3、SSH の中継を確かめられなければ (Get-OpReasonRelayPlan の Own が unknown) 2、版と中継が
# 揃っていれば 0、ほかは 1。RelayPlan が無ければ中継は見ない
function Get-OpReasonExitCode {
    param($State, $RelayPlan = $null)
    if ($State.Plan -eq 'install') { return 3 }
    if ($RelayPlan -and ($RelayPlan.Own -eq 'unknown')) { return 2 }
    $relaySame = (-not $RelayPlan) -or (($RelayPlan.Legacy -eq 'none') -and ($RelayPlan.Own -eq 'none'))
    if (($State.Plan -eq 'none') -and $relaySame) { return 0 }
    1
}

# 前の実行が残した途中の物か (置き場所の隣の <置き場所の名前>.download-*・.new-*・.old-*)
function Test-OpReasonLeftoverName {
    param([string]$Name, [string]$Leaf)
    foreach ($kind in 'download', 'new', 'old') {
        if ($Name.StartsWith("$Leaf.$kind-", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# 状態の表の行 (Text と、直すことがあるかの Warn)。直すことがある行だけ先頭に ⚠ を付け、
# ほかは 2 字下げる。ずれそのものではないこと (動いている op-reason.exe がある) は ※ で添える。
# BusyNote が relay なら、動いているのは SSH の中継だけ (op-reason の task のものも前の task のものも、入れ替えるときに止めて起こし直す。
# Get-OpReasonSwapAction)
function Format-OpReasonState {
    param($State, [string]$Target, [string]$InstallDir, [string]$BusyNote = '')
    $direction = if ($State.Direction -eq 'up') { ' (上げる)' } elseif ($State.Direction -eq 'down') { ' (下げる)' } else { '' }
    $planText = switch ($State.Plan) {
        'install' { '入れる' }
        'change' { "入れ替える$direction" }
        default { 'そのまま' }
    }
    $installedText = if ($State.Plan -eq 'install') { '入っていない' }
    elseif ($State.Installed) { $State.Installed }
    elseif (-not $State.Tree) { '不明 (中身を読めない)' }
    else { '不明 (中身が表のどの版とも合わない)' }
    $rows = @(
        @{ Text = "op-reason (GitHub の Release、$InstallDir)"; Warn = $false; Indent = $false }
        @{ Text = "入っている版     : $installedText"; Warn = $false; Indent = $true }
        @{ Text = "固定した版       : $Target → $planText"; Warn = ($State.Plan -ne 'none'); Indent = $true }
    )
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
    if (($State.Plan -eq 'change') -and ($State.BusyCount -gt 0)) {
        if ($BusyNote -eq 'relay') {
            [pscustomobject]@{ Text = '※ 動いている op-reason.exe は SSH の中継だけ。入れ替えるときは中継を止め、入れ替えてから起こし直す (中継が窓を開いていれば止めない)'; Warn = $false }
        } else {
            [pscustomobject]@{ Text = "※ op-reason.exe が $($State.BusyCount) 個動いている (op の呼び出しの途中)。入れ替えるには、その呼び出しが終わってから打ち直す (このスクリプトは止めない)"; Warn = $false }
        }
    }
}

# ---------------------------------------------------------------------------
# SSH の中継 (op-reason の task と前の task) の副作用の無い関数 (Install-OpReason.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 前の task (0.6.0 までの、このスクリプトの -SshRelay が置いた logon と 1 分ごとの task) の場所と名前。0.7.0 からは op-reason
# 自身の task (Get-OpReasonOwnTaskName) が中継を起こすので、-SshRelay を渡されたら中継を止めて 1 回だけ消す。どのホストにも
# 残っていなければ、この task を扱う関数は外してよい (dotfiles-private の ADR 098)
function Get-OpReasonLegacyTaskId {
    [pscustomobject]@{ Path = '\pjp\'; Name = 'op-reason-ssh-relay' }
}

# op-reason 自身の task の名前 (root のフォルダの op-reason-ssh-relay-<SID>。op-reason の設計 2026-11-23-settings-design.md の §9.1)
function Get-OpReasonOwnTaskName {
    param([string]$Sid)
    "op-reason-ssh-relay-$Sid"
}

# 入っている版の op-reason.exe が --settings (設定の CLI) を持つか。0.7.0 から。版が分からない (表のどの版でもない) なら持たない
# と見る (0.6.0 までの exe は --settings を知らず、op の引数として回す)
function Test-OpReasonSettingsVersion {
    param([string]$Installed)
    $v = $null
    if ((-not $Installed) -or (-not [version]::TryParse($Installed, [ref]$v))) { return $false }
    $v -ge [version]'0.7.0'
}

# op-reason.exe に渡す --settings の引数 (op-reason の設計 §18)。Mode は per-call・show-only (check と set だけが使う)
#   check  望む形 (op-reason の task がある・そのモード・中継が答える) と比べる (JSON。終了コードは 0 同じ・1 違う・2 読めない)
#   set    望む形にする (task を作り、中継を起こして答えるのを待つ。2 回打っても変わらない)
#   off    op-reason の task を消す (op-reason の task の中継なら、op-reason が lock を取って止める)
#   stop・start  入れ替えの前後に、op-reason の task の中継を止める (task を無効に)・起こす (task を有効に)
#   running  答えている中継と、その持ち主 (op-reason の task か、どの task か) を読む (JSON)
function Get-OpReasonSettingsArguments {
    param([string]$Act, [string]$Mode = '')
    $want = @('relay.autostart=on', "relay.mode=$Mode", 'relay.running=on')
    switch ($Act) {
        'check' { return @('--settings', 'check') + $want + @('--json') }
        'set' { return @('--settings', 'set') + $want }
        'off' { return @('--settings', 'set', 'relay.autostart=off') }
        'stop' { return @('--settings', 'relay', 'stop') }
        'start' { return @('--settings', 'relay', 'start') }
        'running' { return @('--settings', 'get', 'relay.running', '--json') }
    }
    throw "Get-OpReasonSettingsArguments: 知らない Act ($Act)"
}

# JSON の object の欄。無ければ $null (Set-StrictMode でも落ちない)
function Get-OpReasonField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

# op-reason.exe --settings の --json の出力の行から、settings の欄のある JSON の object (1 行)。無ければ $null
function ConvertFrom-OpReasonSettingsJson {
    param([string[]]$Lines = @())
    foreach ($line in @($Lines)) {
        $t = "$line".Trim()
        if (-not $t.StartsWith('{')) { continue }
        $json = $null
        try { $json = ConvertFrom-Json -InputObject $t -ErrorAction Stop } catch { $json = $null }
        if ($json -and $json.PSObject.Properties['settings']) { return $json }
    }
    $null
}

# JSON の settings の項目 (Name・Value・Wanted・Same・State・Detail。Wanted と Same は check だけにある)
function ConvertFrom-OpReasonSettingItems {
    param($Json)
    foreach ($s in @($Json.settings)) {
        [pscustomobject]@{
            Name   = "$(Get-OpReasonField $s 'name')"
            Value  = (Get-OpReasonField $s 'value')
            Wanted = "$(Get-OpReasonField $s 'wanted')"
            Same   = [bool](Get-OpReasonField $s 'same')
            State  = "$(Get-OpReasonField $s 'state')"
            Detail = (Get-OpReasonField $s 'detail')
        }
    }
}

# relay.running の項目から、答えている中継の持ち主と PID。Owner は own (op-reason の task が起こした)・legacy (前の task が起こした)・
# other (ほかの task か端末が起こした)・none (答える中継が無い)・unknown (読めない)。持ち主は op-reason が決める (relay.json に
# op-reason の task の名前があるか・動いている task のどれの動作か。op-reason の設計 §9.5)
function Get-OpReasonRelayOwner {
    param($Item)
    if (-not $Item) { return [pscustomobject]@{ Owner = 'unknown'; Pid = $null } }
    if ("$($Item.Value)" -eq 'off') { return [pscustomobject]@{ Owner = 'none'; Pid = $null } }
    if ($Item.State -ne 'running') { return [pscustomobject]@{ Owner = 'unknown'; Pid = $null } }
    $d = $Item.Detail
    $relayId = Get-OpReasonField $d 'pid'
    $id = Get-OpReasonLegacyTaskId
    $owner = if (Get-OpReasonField $d 'ours') { 'own' } elseif ("$(Get-OpReasonField $d 'by')" -eq "$($id.Path)$($id.Name)") { 'legacy' } else { 'other' }
    [pscustomobject]@{ Owner = $owner; Pid = $(if ($null -ne $relayId) { [int]$relayId } else { $null }) }
}

# op-reason.exe --settings get relay.running --json の終了コードと出力の行から、答えている中継の持ち主と PID (Get-OpReasonRelayOwner)
function ConvertFrom-OpReasonRelayRunning {
    param($Code, [string[]]$Lines = @())
    if ($Code -ne 0) { return Get-OpReasonRelayOwner -Item $null }
    $json = ConvertFrom-OpReasonSettingsJson -Lines $Lines
    if (-not $json) { return Get-OpReasonRelayOwner -Item $null }
    $item = @(ConvertFrom-OpReasonSettingItems -Json $json | Where-Object { $_.Name -eq 'relay.running' }) | Select-Object -First 1
    Get-OpReasonRelayOwner -Item $item
}

# op-reason.exe --settings check … --json の終了コード (Code) と出力の行 (Lines) から、比べた結果を読む。Code が $null なら
# op-reason.exe を起こせなかった (Failure にわけ)。
#   Status  same (0 で JSON の same も true)・different (1 で false)・unknown (2・起こせない・JSON を読めない・終了コードと JSON が食い違う)
#   Items   設定ごとの Name・Value・Wanted・Same・State (op-reason の state の符号)・Detail (その事実)
#   Why     unknown のわけ (読めなかった設定の error も添える)
function ConvertFrom-OpReasonSettingsCheck {
    param($Code, [string[]]$Lines = @(), [string]$Failure = '')
    $out = [pscustomobject]@{ Status = 'unknown'; Items = @(); Why = '' }
    if ($null -eq $Code) {
        $out.Why = "op-reason.exe を起こせなかった: $Failure"
        return $out
    }
    $json = ConvertFrom-OpReasonSettingsJson -Lines $Lines
    if (-not $json) {
        $out.Why = "op-reason.exe --settings check が終了コード $Code で終わり、JSON を読めなかった"
        return $out
    }
    $out.Items = @(ConvertFrom-OpReasonSettingItems -Json $json)
    $same = [bool](Get-OpReasonField $json 'same')
    if (($Code -eq 0) -and $same) {
        $out.Status = 'same'
        return $out
    }
    if (($Code -eq 1) -and (-not $same)) {
        $out.Status = 'different'
        return $out
    }
    $why = "op-reason.exe --settings check が終了コード $Code で終わった"
    $bad = @($out.Items | Where-Object { $_.State -eq 'unreadable' } | ForEach-Object { "$($_.Name): $(Get-OpReasonField $_.Detail 'error')" })
    if ($bad.Count -gt 0) { $why += " (読めない: $($bad -join '・'))" }
    $out.Why = $why
    $out
}

# check の 1 項目の添え書き (op-reason の state の符号と detail を状態の表の字に)。添えることが無ければ空
function Format-OpReasonSettingNote {
    param($Item)
    $d = $Item.Detail
    $relayId = Get-OpReasonField $d 'pid'
    $by = Get-OpReasonField $d 'by'
    switch ($Item.State) {
        'ok' { return '' }
        'ignored' { return "settings.json の値 ($(Get-OpReasonField $d 'raw')) は op-reason が使わないので既定" }
        'relay-differs' { return "動いている中継 (pid $relayId) は $(Get-OpReasonField $d 'relay') で動いている" }
        'task-differs' { return "task の形が違う ($(@(Get-OpReasonField $d 'fields') -join '・'))" }
        'task-off' { return 'task が無効 (relay stop で止めた)' }
        'task-starting' { return 'task が 1 分のうちに起こす' }
        'other-relay' {
            $who = if ($by) { "$by が起こした" } else { 'task の外で起こした' }
            return "ほかの中継 (pid $relayId。$who) が動いている"
        }
        'running' {
            $who = if (Get-OpReasonField $d 'ours') { 'op-reason の task が起こした' } elseif ($by) { "$by が起こした" } else { 'task の外で起こした' }
            return "pid $relayId。$who"
        }
        'unreadable' { return "読めない: $(Get-OpReasonField $d 'error')" }
    }
    $Item.State
}

# task の様子 (Get-OpReasonTask の値) の字 (動いている・無効・止まっている)
function Get-OpReasonTaskStateWord {
    param($Task)
    if ($Task.State -eq 'Running') { return '動いている' }
    if (($Task.State -eq 'Disabled') -or (-not $Task.Enabled)) { return '無効' }
    '止まっている'
}

# task の有る無しと様子の字 (無い・ある (動いている) など)
function Format-OpReasonTaskState {
    param($Task)
    if (-not $Task) { return '無い' }
    "ある ($(Get-OpReasonTaskStateWord -Task $Task))"
}

# 中継にすること。Want は -SshRelay の値 ('' は渡さない: task に触らない)、InScope は置き場所が既定か (ほかの置き場所では task に
# 触らない)、Capable は入っている op-reason.exe が --settings を持つか、Check は ConvertFrom-OpReasonSettingsCheck の値 (打たなければ $null)。
#   Legacy  none・remove (前の task の中継を止めて task を消す。-SshRelay を渡されたときだけ)
#   Own     none・set (op-reason.exe --settings set relay.autostart=on relay.mode=<モード> relay.running=on)・off (set relay.autostart=off)・
#           after-swap (入れる・入れ替えるので、入れた後の exe で set。入れ替える前の exe では check を打たない)・unknown (check で
#           確かめられない。版は揃っているので、何も変えない)
# check が同じでも前の task があれば set (答えている中継は前の task のもので、消した後に op-reason の task を作って起こす)
function Get-OpReasonRelayPlan {
    param([string]$Want, [bool]$InScope, $OwnTask, $LegacyTask, [bool]$Capable, $Check)
    $plan = [pscustomobject]@{ Legacy = 'none'; Own = 'none' }
    if ((-not $Want) -or (-not $InScope)) { return $plan }
    if ($LegacyTask) { $plan.Legacy = 'remove' }
    if ($Want -eq 'off') {
        if ($OwnTask) { $plan.Own = 'off' }
        return $plan
    }
    if ((-not $Capable) -or (-not $Check)) {
        $plan.Own = 'after-swap'
        return $plan
    }
    switch ($Check.Status) {
        'unknown' { $plan.Own = 'unknown' }
        'different' { $plan.Own = 'set' }
        default { if ($LegacyTask) { $plan.Own = 'set' } }
    }
    $plan
}

# 置き場所を入れ替える前に止めるもの (win/README.md の「SSH の中継」の「版上げ」)。Busy は置き場所から動いている op-reason.exe の PID、
# RelayPid と Owner は答えている中継の PID と持ち主 (Get-OpReasonRelayOwner)、OwnActive は op-reason の task が有効か動いているか、
# Capable は入っている op-reason.exe が --settings を持つか。
#   swap         止めるものが無い (入れるだけ・揃っている・何も動いておらず op-reason の task も有効でない)
#   stop-legacy  動いている op-reason.exe が前の task の中継だけ。lock を取って前の task を無効にし、中継を止める
#   stop-own     動いているのが op-reason の task の中継だけか、何も動いておらず op-reason の task が有効 (答えている中継が無いか、
#                op-reason の task のもの)。op-reason.exe --settings relay stop (op-reason が task を無効にし、lock を取って中継を止める)。
#                何も動いていなくても止めておく (1 分ごとの trigger が入れ替えの途中に古い exe を起こさないよう)。ほかで起こした中継が
#                答えていれば打たない (relay stop は持ち主の違う中継には op-reason の task を無効にしてから 1 で終わる)
#   busy         ほかの op-reason.exe (op の呼び出し) も動いている・中継の持ち主がほか (task の外で起こした) か分からない・止める手が
#                無い。止めずに知らせる
function Get-OpReasonSwapAction {
    param([string]$Plan, [int[]]$Busy = @(), $RelayPid, [string]$Owner = 'none', [bool]$OwnActive, [bool]$Capable)
    if ($Plan -ne 'change') { return 'swap' }
    $ids = @($Busy)
    $others = @($ids | Where-Object { $_ -ne $RelayPid })
    if ($others.Count -gt 0) { return 'busy' }
    if ($ids.Count -gt 0) {
        if ($Owner -eq 'legacy') { return 'stop-legacy' }
        if (($Owner -eq 'own') -and $Capable) { return 'stop-own' }
        return 'busy'
    }
    if ($OwnActive -and $Capable -and ($Owner -in 'own', 'none')) { return 'stop-own' }
    'swap'
}

# check の 1 項目の行 (違えば ⚠ と「今 → 望み」に、添え書き。値は望みと同じで、動いている中継の値だけが違うときは値だけ)
function Format-OpReasonSettingRow {
    param($Item)
    $value = if ($null -eq $Item.Value) { '-' } else { "$($Item.Value)" }
    $text = if ($Item.Same -or ($value -eq $Item.Wanted)) { $value } else { "$value → $($Item.Wanted)" }
    $note = Format-OpReasonSettingNote -Item $Item
    if ($note) { $text += " ($note)" }
    @{ Text = "$("$($Item.Name)".PadRight(17)): $text"; Warn = (-not $Item.Same); Indent = $true }
}

# 状態の表の中継の行 (見出し・望む形・task・前の task・設定)。View は Get-OpReasonRelayView の値、Want は -SshRelay の値、
# Installed は op-reason が入っているか
function Format-OpReasonRelayState {
    param([string]$Want, $View, [bool]$Installed = $true)
    $wantText = switch ($Want) {
        'per-call' { 'per-call (relay.autostart=on relay.mode=per-call relay.running=on)' }
        'show-only' { 'show-only (relay.autostart=on relay.mode=show-only relay.running=on)' }
        'off' { '置かない (-SshRelay off)' }
        default { '決めない (-SshRelay なし。task には触らない)' }
    }
    $rows = @()
    if (-not $View.InScope) {
        $rows += @{ Text = 'SSH の中継'; Warn = $false; Indent = $false }
        $rows += @{ Text = "望む形           : $wantText → 置き場所が既定でないので、task も中継も見ない (-SshRelay は %LOCALAPPDATA%\Programs\op-reason でだけ効く)"; Warn = $false; Indent = $true }
    } else {
        $rows += @{ Text = "SSH の中継 (op-reason の task \$($View.OwnName))"; Warn = $false; Indent = $false }
        $rows += @{ Text = "望む形           : $wantText"; Warn = $false; Indent = $true }
        $ownText = Format-OpReasonTaskState -Task $View.Own
        $ownWarn = $View.Plan.Own -eq 'off'
        if ($ownWarn) { $ownText += ' → 止めて消す (op-reason.exe --settings set relay.autostart=off)' }
        $rows += @{ Text = "task             : $ownText"; Warn = $ownWarn; Indent = $true }
        if ($View.Legacy) {
            $id = Get-OpReasonLegacyTaskId
            $legacyText = "$($id.Path)$($id.Name) ($(Get-OpReasonTaskStateWord -Task $View.Legacy))"
            $legacyWarn = $View.Plan.Legacy -eq 'remove'
            if ($legacyWarn) {
                $legacyText += if ($Want -eq 'off') { ' → 中継を止めて消す' } else { ' → 中継を止めて消す (op-reason の task に移す)' }
            }
            $rows += @{ Text = "前の task        : $legacyText"; Warn = $legacyWarn; Indent = $true }
        }
        if ($Want -in 'per-call', 'show-only') {
            if ($View.Plan.Own -eq 'after-swap') {
                $why = if (-not $Installed) { '入れてから確かめる' } elseif (-not $View.Capable) { '版を揃えてから確かめる (入っている op-reason.exe は --settings を持たない)' } else { '版を揃えてから確かめる (入れ替えた後の op-reason.exe で)' }
                $rows += @{ Text = "設定             : $why"; Warn = $false; Indent = $true }
            } elseif ($View.Check) {
                if ($View.Check.Status -eq 'unknown') {
                    $rows += @{ Text = "設定             : 確かめられない ($($View.Check.Why))"; Warn = $true; Indent = $true }
                }
                foreach ($item in @($View.Check.Items)) { $rows += Format-OpReasonSettingRow -Item $item }
            }
        }
    }
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
}

# --status の出力から、答えた中継の PID。答えていなければ (終了コード 0 でない・PID の無い文) $null
function ConvertFrom-OpReasonRelayStatus {
    param([int]$Code, [string]$Text)
    if ($Code -ne 0) { return $null }
    if ($Text -match '\(pid (\d+)\)') { return [int]$Matches[1] }
    $null
}

# ---------------------------------------------------------------------------
# ファイル・ネットワーク・Windows に触る関数 (テストでは偽物に差し替えるか、一時ディレクトリで確かめる。
# 実機では置き場所を一時ディレクトリに向けて -Check と本番を打って確かめる)
# ---------------------------------------------------------------------------

# ファイルの SHA-256 (小文字の 16 進)。読めなければ $null。
# Get-FileHash は使わない。Windows PowerShell 5.1 では script の関数で、PowerShell 7 から起こした 5.1 は
# PSModulePath を継いで 7 の Microsoft.PowerShell.Utility を読み、Get-FileHash が見つからなくなる
function Get-OpReasonFileHash {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            -join ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') })
        } finally {
            $stream.Dispose()
        }
    } catch {
        $null
    } finally {
        $sha.Dispose()
    }
}

# ディレクトリの中身の値 (Tree)。中の全部のファイル (下のディレクトリのものも) の SHA-256 と、ディレクトリからの相対パス
# (区切りは /) から Get-OpReasonTreeText の文字列を作り、その SHA-256 を返す。ディレクトリが無い・読めないファイルがあれば $null
function Get-OpReasonTreeHash {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    $root = [IO.Path]::GetFullPath($Dir).TrimEnd('\', '/')
    $entries = @{}
    try {
        foreach ($file in [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
            $hash = Get-OpReasonFileHash -Path $file
            if (-not $hash) { return $null }
            $entries[$file.Substring($root.Length + 1).Replace('\', '/')] = $hash
        }
    } catch {
        return $null
    }
    Get-OpReasonTextHash -Text (Get-OpReasonTreeText -Entries $entries)
}

# URL の中身を OutFile に落とす。落とせなければ例外
function Invoke-OpReasonDownload {
    param([string]$Url, [string]$OutFile)
    # 進み具合の表示は Windows PowerShell 5.1 で落とすのを大きく遅くする
    $ProgressPreference = 'SilentlyContinue'
    # 5.1 (.NET Framework) は既定で TLS 1.2 を使わないことがあり、GitHub に断られる
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
}

# zip を Destination に展開する。展開できなければ例外。
# Expand-Archive は使わない (Get-FileHash と同じく、PowerShell 7 から起こした 5.1 では見つからないことがある)
function Expand-OpReasonZip {
    param([string]$ZipPath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

# ディレクトリの名前を変える (同じ親ディレクトリの中なので移すだけ)。中のファイルを開いているプロセスがあると例外
function Move-OpReasonDirectory {
    param([string]$Source, [string]$Destination)
    [IO.Directory]::Move($Source, $Destination)
}

# 置き場所を入れ替える邪魔になる、動いている op-reason.exe
function Get-OpReasonBusyProcess {
    param([string]$InstallDir)
    @(Get-Process -Name 'op-reason' -ErrorAction SilentlyContinue | Where-Object {
            $path = $null
            try { $path = $_.Path } catch { $path = $null }
            Test-OpReasonBusyPath -Path $path -InstallDir $InstallDir
        })
}

# task の今の様子 (State・Enabled)。無ければ $null。ScheduledTasks の module が無い (Linux の pwsh の試験) ときも $null。
# op-reason の task も前の task もこれで読む (op-reason.exe を起こさないので、中継を使わないホストでも読める)
function Get-OpReasonTask {
    param([string]$Path, [string]$Name)
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
    $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    [pscustomobject]@{ State = "$($t.State)"; Enabled = [bool]$t.Settings.Enabled }
}

# 今のユーザーの SID (op-reason の task の名前に入る)。読めなければ (Windows でない) $null
function Get-OpReasonUserSid {
    try {
        $sid = "$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
    } catch {
        return $null
    }
    if ($sid) { return $sid }
    $null
}

# 既定の置き場所 (WSL の op の OPREASON_EXE の既定と、runner が使う所)。LOCALAPPDATA が無ければ $null
function Get-OpReasonDefaultInstallDir {
    if (-not $env:LOCALAPPDATA) { return $null }
    Join-Path $env:LOCALAPPDATA 'Programs\op-reason'
}

# 置き場所が既定か (大文字小文字を問わない)。-SshRelay は既定の置き場所でだけ効く (一時の置き場所で試すときに、本物の task を
# その置き場所の exe に向けない・本物の中継を止めない。op-reason の set は打った exe を task の動作にする)
function Test-OpReasonDefaultInstallDir {
    param([string]$InstallDir)
    $default = Get-OpReasonDefaultInstallDir
    if (-not $default) { return $false }
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($default).TrimEnd('\', '/')
    [string]::Equals($resolved, $InstallDir.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)
}

# op-reason.exe --settings … を打ち、終了コード (Code) と出力の行 (stdout と stderr。Lines) を返す。起こせなければ Code は $null で、
# Failure にわけ (exe が無い・Smart App Control に止められた)。打つ間だけ [Console]::OutputEncoding を UTF-8 にする (op-reason は
# UTF-8 で書く。手で打った PowerShell の既定の code page のままだと日本語の行が化ける)。ここだけ ErrorActionPreference を Continue に
# する (Windows PowerShell 5.1 は、2>&1 で受けた stderr の行を Stop のときに例外にする)
function Invoke-OpReasonSettings {
    param([string]$Exe, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
        return [pscustomobject]@{ Code = $null; Lines = @(); Failure = "$Exe が無い" }
    }
    $ErrorActionPreference = 'Continue'
    $saved = $null
    try {
        $saved = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    } catch {
        $saved = $null
    }
    try {
        $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $lines; Failure = '' }
    } catch {
        [pscustomobject]@{ Code = $null; Lines = @(); Failure = $_.Exception.Message }
    } finally {
        if ($saved) {
            try { [Console]::OutputEncoding = $saved } catch { $saved = $null }
        }
    }
}

# 前の task を消す・起こす・止める・有効と無効を替える (無効の間は、logon の trigger も 1 分ごとの trigger も起こさない)
function Unregister-OpReasonLegacyTask {
    $id = Get-OpReasonLegacyTaskId
    Unregister-ScheduledTask -TaskPath $id.Path -TaskName $id.Name -Confirm:$false
}

function Start-OpReasonLegacyTask {
    $id = Get-OpReasonLegacyTaskId
    Start-ScheduledTask -TaskPath $id.Path -TaskName $id.Name
}

function Stop-OpReasonLegacyTask {
    $id = Get-OpReasonLegacyTaskId
    Stop-ScheduledTask -TaskPath $id.Path -TaskName $id.Name
}

function Set-OpReasonLegacyTaskEnabled {
    param([bool]$Enabled)
    $id = Get-OpReasonLegacyTaskId
    if ($Enabled) {
        Enable-ScheduledTask -TaskPath $id.Path -TaskName $id.Name | Out-Null
    } else {
        Disable-ScheduledTask -TaskPath $id.Path -TaskName $id.Name | Out-Null
    }
}

# 既定の pipe で答える中継の PID (op-reason.exe --ssh-agent --status。0.4.0 から 0.9.0 まで同じ)。答えない・起こせないときは $null
function Get-OpReasonRelayPid {
    param([string]$Exe)
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    try {
        $text = (& $Exe '--ssh-agent' '--status' 2>&1 | Out-String)
        ConvertFrom-OpReasonRelayStatus -Code $LASTEXITCODE -Text $text
    } catch {
        $null
    }
}

# 中継が答えるのを、最大 Seconds 秒待つ。答えた PID か $null
function Wait-OpReasonRelayPid {
    param([string]$Exe, [int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        $found = Get-OpReasonRelayPid -Exe $Exe
        if ($found) { return $found }
        if ((Get-Date) -ge $deadline) { return $null }
        Start-Sleep -Milliseconds 500
    }
}

# プロセスが終わるのを最大 Seconds 秒待つ。終わった (か、もう無い) なら $true
function Wait-OpReasonProcessExit {
    param([int]$Id, [int]$Seconds)
    $p = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $p) { return $true }
    $p.WaitForExit($Seconds * 1000)
}

# op-reason の lock (名前付き mutex Local\op-reason。op-reason.exe・launcher.ps1・中継が窓を出す間に持つ) を待たずに取る。
# 取れたら mutex、ほかが持っていれば $null。前の持ち主が放さずに終わっていたら (AbandonedMutexException) 取れたとみなす
function Enter-OpReasonLock {
    $m = [Threading.Mutex]::new($false, 'Local\op-reason')
    try {
        if ($m.WaitOne(0)) { return $m }
    } catch [Threading.AbandonedMutexException] {
        return $m
    }
    $m.Dispose()
    $null
}

function Exit-OpReasonLock {
    param($Lock)
    if (-not $Lock) { return }
    try { $Lock.ReleaseMutex() } catch { }
    $Lock.Dispose()
}

# 0.7.0 からの中継に止まるよう頼む (stop event Local\op-reason-ssh-relay-stop-<pid> を立てる。中継は新しい依頼を断り、1Password に
# 渡った依頼を終えてから (25 秒まで) 自分で終わる。op-reason の設計 §8.2)。event が無ければ (0.6.0 までの中継) $false
function Request-OpReasonRelayStop {
    param([int]$RelayPid)
    try {
        $e = [Threading.EventWaitHandle]::OpenExisting("Local\op-reason-ssh-relay-stop-$RelayPid")
    } catch {
        return $false
    }
    try { [void]$e.Set() } finally { $e.Dispose() }
    $true
}

# 前の task がまだ動いていれば止める (読み直して Running のときだけ Stop-ScheduledTask を打つ。終わった task には打たない)
function Stop-OpReasonLegacyTaskIfRunning {
    $id = Get-OpReasonLegacyTaskId
    $t = Get-OpReasonTask -Path $id.Path -Name $id.Name
    if ($t -and ($t.State -eq 'Running')) { Stop-OpReasonLegacyTask }
}

# 前の task の中継を止める (lock を持っている前提)。task を無効にしてから (1 分ごとの trigger に起こさせない)、0.7.0 からの中継には
# 止まるよう頼んで 30 秒待ち (op-reason が自分の中継を止めるのと同じ)、残っていれば task ごと止め、プロセスが終わるのを 10 秒待つ。
# 終われば $true。終わらなければ task を有効に戻して $false
function Stop-OpReasonLegacyRelay {
    param($RelayPid)
    Set-OpReasonLegacyTaskEnabled -Enabled $false
    if ($RelayPid -and (Request-OpReasonRelayStop -RelayPid $RelayPid)) {
        [void](Wait-OpReasonProcessExit -Id $RelayPid -Seconds 30)
    }
    Stop-OpReasonLegacyTaskIfRunning
    if ($RelayPid -and -not (Wait-OpReasonProcessExit -Id $RelayPid -Seconds 10)) {
        Set-OpReasonLegacyTaskEnabled -Enabled $true
        return $false
    }
    $true
}

# 今の状態を読む (何も変えない。管理者は要らない)
function Get-OpReasonState {
    param([string]$InstallDir, [string]$Target, $Releases)
    $exists = Test-Path -LiteralPath $InstallDir -PathType Container
    $tree = $null
    if ($exists) { $tree = Get-OpReasonTreeHash -Dir $InstallDir }
    $installed = Find-OpReasonVersion -Releases $Releases -Tree $tree
    [pscustomobject]@{
        Exists    = $exists
        Tree      = $tree
        Installed = $installed
        Plan      = Get-OpReasonPlan -Exists $exists -Installed $installed -Target $Target
        Direction = Get-OpReasonDirection -Installed $installed -Target $Target
        BusyCount = @(Get-OpReasonBusyProcess -InstallDir $InstallDir).Count
    }
}

# 状態の表の行を出す。直すことがある行 (⚠) は黄色にする
function Write-OpReasonRows {
    param($Rows)
    foreach ($row in $Rows) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 状態の表を出す
function Write-OpReasonState {
    param($State, [string]$Target, [string]$InstallDir, [string]$BusyNote = '')
    Write-OpReasonRows -Rows (Format-OpReasonState -State $State -Target $Target -InstallDir $InstallDir -BusyNote $BusyNote)
}

# 中継の今の様子と、すること。Want は -SshRelay の値、State は Get-OpReasonState の値。op-reason の task と前の task は
# Get-ScheduledTask で読み (op-reason.exe を起こさない)、check は -SshRelay がモードで、版が揃っていて (入れ替える前の exe では
# 確かめない)、入っている exe が --settings を持つときだけ打つ。置き場所が既定でなければ、どちらも見ない
function Get-OpReasonRelayView {
    param([string]$Want, $State, [string]$Exe, [string]$InstallDir)
    $inScope = [bool](Test-OpReasonDefaultInstallDir -InstallDir $InstallDir)
    $sid = $null
    $own = $null
    $legacy = $null
    if ($inScope) {
        $sid = Get-OpReasonUserSid
        if ($sid) { $own = Get-OpReasonTask -Path '\' -Name (Get-OpReasonOwnTaskName -Sid $sid) }
        $lid = Get-OpReasonLegacyTaskId
        $legacy = Get-OpReasonTask -Path $lid.Path -Name $lid.Name
    }
    $capable = [bool]($State.Exists -and (Test-OpReasonSettingsVersion -Installed $State.Installed))
    $check = $null
    if ($inScope -and ($Want -in 'per-call', 'show-only') -and $capable -and ($State.Plan -eq 'none')) {
        $r = Invoke-OpReasonSettings -Exe $Exe -Arguments (Get-OpReasonSettingsArguments -Act 'check' -Mode $Want)
        $check = ConvertFrom-OpReasonSettingsCheck -Code $r.Code -Lines $r.Lines -Failure $r.Failure
    }
    $ownName = Get-OpReasonOwnTaskName -Sid $(if ($sid) { $sid } else { '<SID>' })
    [pscustomobject]@{
        InScope = $inScope
        OwnName = $ownName
        Own     = $own
        Legacy  = $legacy
        Capable = $capable
        Check   = $check
        Plan    = (Get-OpReasonRelayPlan -Want $Want -InScope $inScope -OwnTask $own -LegacyTask $legacy -Capable $capable -Check $check)
        # 中継の行は、-SshRelay がモードのときか、どちらかの task があるとき (と、既定でない置き場所に -SshRelay を渡されたとき) だけ
        # 出す (runner は中継を使わないホストにも -SshRelay off を渡すので、off でどちらの task も無ければ今までどおり何も出さない)
        Shown   = [bool](($Want -and (-not $inScope)) -or ($inScope -and (($Want -in 'per-call', 'show-only') -or $own -or $legacy)))
    }
}

# 打った op-reason.exe --settings の行と、その出力 (2 字下げる)。0 で終われば $true。ほかは終了コードかわけを添えて $false
function Invoke-OpReasonSettingsAct {
    param([string]$Exe, [string]$Act, [string]$Mode = '')
    $a = Get-OpReasonSettingsArguments -Act $Act -Mode $Mode
    Write-Host "op-reason.exe $($a -join ' ')"
    $r = Invoke-OpReasonSettings -Exe $Exe -Arguments $a
    foreach ($l in @($r.Lines)) { Write-Host "  $l" }
    if ($r.Code -eq 0) { return $true }
    if ($null -eq $r.Code) {
        Write-Host "  op-reason.exe を起こせなかった: $($r.Failure)"
    } else {
        Write-Host "  (終了コード $($r.Code)。上の行がわけ)"
    }
    $false
}

# 前の task の中継を、lock を取ってから止める。止めたら $true (lock は $Ctx.Lock に残し、消すか起こし直すまで持つ)。
# lock を取れない (中継が窓を開いている・1Password の確認を待っている) か、止まらなければ、わけを出して $false
function Stop-OpReasonLegacyRelayLocked {
    param($Ctx, $RelayPid)
    if (-not $Ctx.Lock) { $Ctx.Lock = Enter-OpReasonLock }
    if (-not $Ctx.Lock) {
        Write-Host 'SSH の中継が窓を開いている (か、1Password の確認を待っている) ので、中継を止めない。窓に答えてから打ち直す (このスクリプトは止めない)'
        return $false
    }
    if (-not (Stop-OpReasonLegacyRelay -RelayPid $RelayPid)) {
        Write-Host "SSH の中継 (pid $RelayPid) が 10 秒たっても止まらなかった。中継は動いたまま (前の task は有効に戻した)"
        return $false
    }
    $Ctx.LegacyStopped = $true
    $true
}

# op-reason の task の中継を止める (op-reason.exe --settings relay stop。op-reason が task を無効にし、lock を取って中継を止める)。
# 止めたら $true。断られたら (窓が開いている・op-reason の task の中継でない)、op-reason の行を見せて $false
function Stop-OpReasonOwnRelay {
    param($Ctx, [string]$Exe)
    if (-not (Invoke-OpReasonSettingsAct -Exe $Exe -Act 'stop')) {
        Write-Host 'op-reason の task の SSH の中継を止められなかった。窓が開いていれば、答えてから打ち直す (このスクリプトは止めない)'
        return $false
    }
    $Ctx.OwnStopped = $true
    $true
}

# 答えている中継の持ち主と PID (Get-OpReasonRelayOwner の形)。Capable なら op-reason.exe --settings get relay.running --json (op-reason が
# relay.json と動いている task から決める)。--settings を持たない版なら --status の PID と前の task の様子から決める (その版では
# op-reason の task は無いので、前の task が動いていればその中継、ほかは task の外で起こした中継と見る)
function Get-OpReasonRelayOwnerNow {
    param([string]$Exe, [bool]$Capable, [bool]$LegacyRunning)
    if ($Capable) {
        $r = Invoke-OpReasonSettings -Exe $Exe -Arguments (Get-OpReasonSettingsArguments -Act 'running')
        return ConvertFrom-OpReasonRelayRunning -Code $r.Code -Lines $r.Lines
    }
    $relayId = Get-OpReasonRelayPid -Exe $Exe
    $owner = if (-not $relayId) { 'none' } elseif ($LegacyRunning) { 'legacy' } else { 'other' }
    [pscustomobject]@{ Owner = $owner; Pid = $relayId }
}

# 動いている前の task を止める (持ち主は Get-OpReasonRelayOwnerNow の値)。legacy (前の task の中継)・unknown (持ち主を読めない) は、
# lock を取って中継を止める (unknown の PID は --status。0.7.0 の中継なら stop event で止める)。own (答えている中継は op-reason の
# task のもの) なら、前の task の 1 分ごとの起動が一瞬だけ Running に見えているだけなので、lock を取らずに task を止める。other・
# none は、op-reason が持ち主を見落としても窓を開いている中継を止めないよう、lock を取ってから task だけを止める。止めたら $true
function Stop-OpReasonLegacyInstance {
    param($Ctx, [string]$Exe, $Owner)
    if ($Owner.Owner -in 'legacy', 'unknown') {
        $relayId = if ($Owner.Pid) { $Owner.Pid } else { Get-OpReasonRelayPid -Exe $Exe }
        return (Stop-OpReasonLegacyRelayLocked -Ctx $Ctx -RelayPid $relayId)
    }
    if ($Owner.Owner -ne 'own') {
        if (-not $Ctx.Lock) { $Ctx.Lock = Enter-OpReasonLock }
        if (-not $Ctx.Lock) {
            Write-Host 'SSH の中継が窓を開いている (か、1Password の確認を待っている) ので、前の task を止めない。窓に答えてから打ち直す (このスクリプトは止めない)'
            return $false
        }
    }
    Set-OpReasonLegacyTaskEnabled -Enabled $false
    Stop-OpReasonLegacyTaskIfRunning
    $true
}

# 移すために、前の task を無効にして中継を止める (消すのは呼ぶ側。モードなら op-reason の set が通った後)。動いていなければ先に
# 無効にし、その間に 1 分ごとの trigger が起こしていれば止める。動いていれば、答えている中継の持ち主ごとに止める
# (Stop-OpReasonLegacyInstance)。止めた・無効にしたら $true ($Ctx.LegacyStopped)。止められなければ、無効にする前に戻して $false
function Stop-OpReasonLegacyForMove {
    param($Ctx, [string]$Exe, [bool]$Capable)
    if ($Ctx.LegacyStopped) { return $true }
    $id = Get-OpReasonLegacyTaskId
    $t = Get-OpReasonTask -Path $id.Path -Name $id.Name
    if (-not $t) { return $true }
    # ここで無効にしたか (止められなければ有効に戻す。止める関数は、止めかけて落ちたときに自分で戻す)
    $disabledHere = $false
    if ($t.State -ne 'Running') {
        $disabledHere = [bool]$t.Enabled
        Set-OpReasonLegacyTaskEnabled -Enabled $false
        $t = Get-OpReasonTask -Path $id.Path -Name $id.Name
    }
    if ($t -and ($t.State -eq 'Running')) {
        $o = Get-OpReasonRelayOwnerNow -Exe $Exe -Capable $Capable -LegacyRunning $true
        if (-not (Stop-OpReasonLegacyInstance -Ctx $Ctx -Exe $Exe -Owner $o)) {
            if ($disabledHere) { Set-OpReasonLegacyTaskEnabled -Enabled $true }
            return $false
        }
    }
    $Ctx.LegacyStopped = $true
    $true
}

# 止めた前の task を消す (-SshRelay を渡されたときに 1 回だけ)
function Remove-OpReasonLegacyTask {
    param($Ctx, [string]$Why)
    Unregister-OpReasonLegacyTask
    $Ctx.LegacyStopped = $false
    $id = Get-OpReasonLegacyTaskId
    Write-Host "前の task を消した: $($id.Path)$($id.Name) ($Why)"
}

# 止めた前の task の中継を起こし直す (有効に戻して起こし、答えるのを 15 秒待つ)。答えれば $true
function Start-OpReasonLegacyRelay {
    param([string]$Exe)
    $id = Get-OpReasonLegacyTaskId
    Set-OpReasonLegacyTaskEnabled -Enabled $true
    Write-Host "SSH の中継を起こす (前の task $($id.Path)$($id.Name))"
    Start-OpReasonLegacyTask
    $answered = Wait-OpReasonRelayPid -Exe $Exe -Seconds 15
    if ($answered) {
        Write-Host "SSH の中継が答えた (pid $answered)"
        return $true
    }
    Write-Host "SSH の中継が答えない (15 秒待った)。op-reason.exe が止められていないか (Smart App Control など)、task の最後の結果 (Get-ScheduledTaskInfo -TaskPath '$($id.Path)' -TaskName '$($id.Name)') を見る"
    $false
}

# 固定した版の zip を落として確かめ、展開した中身で置き場所を入れ替える。置けたら $true。
# 置けないときは、わけを出して $false を返し、何も変えない (落とした物と展開した物は消す。入れ替えの途中で落ちたら前の中身に戻す)。
# BeforeSwap は、確かめた後・前の中身をよける前に呼ぶ (task の SSH の中継を止める)。$true を返さなければ、何も変えずに $false
function Save-OpReason {
    param([string]$Url, [string]$ExpectedZip, [string]$ExpectedTree, [string]$InstallDir, [scriptblock]$BeforeSwap)
    $parent = Split-Path -Parent $InstallDir
    $leaf = Split-Path -Leaf $InstallDir
    $createdParent = $false
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $createdParent = $true
    }
    # 止められた前の実行 (setup の時間切れなど) が残した途中の物を消す。同時に走っている実行の物は消さないよう、
    # 10 分より古いものだけ
    Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
        Where-Object { (Test-OpReasonLeftoverName -Name $_.Name -Leaf $leaf) -and ($_.LastWriteTime -lt (Get-Date).AddMinutes(-10)) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    # 置き場所と同じ親ディレクトリに落として展開し、確かめてから名前を変える (途中で落ちても壊れた中身を残さない)
    $download = Join-Path $parent "$leaf.download-$PID.zip"
    $staging = Join-Path $parent "$leaf.new-$PID"
    $old = Join-Path $parent "$leaf.old-$PID"
    $keepOld = $false
    try {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "落とす: $Url"
        try {
            Invoke-OpReasonDownload -Url $Url -OutFile $download
        } catch {
            Write-Host "落とせなかった: $($_.Exception.Message)"
            Write-Host '何も変えていない。ネットワークと、上の URL (Release の版と zip の名前) を確かめて打ち直す'
            return $false
        }
        $actual = Get-OpReasonFileHash -Path $download
        if (-not $actual) {
            Write-Host '落とした物を読めなかった (何も変えていない)。打ち直す'
            return $false
        }
        if (-not (Test-OpReasonHashMatch -Expected $ExpectedZip -Actual $actual)) {
            Write-Host 'zip の SHA-256 が固定した値と合わないので置かない (何も変えていない)'
            Write-Host "  固定した値 : $ExpectedZip"
            Write-Host "  落とした物 : $actual"
            Write-Host 'Release の zip が差し替えられたか、表の値の書き誤り。どちらかを確かめるまで入れない'
            return $false
        }
        try {
            Expand-OpReasonZip -ZipPath $download -Destination $staging
        } catch {
            Write-Host "展開できなかった: $($_.Exception.Message)"
            Write-Host '何も変えていない。打ち直す'
            return $false
        }
        # zip の中は op-reason-windows の 1 フォルダー (op-reason の Release の .github/scripts/windows-dist.ps1)
        $content = Join-Path $staging 'op-reason-windows'
        $tree = Get-OpReasonTreeHash -Dir $content
        if (-not (Test-OpReasonHashMatch -Expected $ExpectedTree -Actual $tree)) {
            Write-Host '展開した中身が固定した値 (Tree) と合わないので置かない (何も変えていない)'
            Write-Host "  固定した値 : $ExpectedTree"
            Write-Host "  展開した物 : $(if ($tree) { $tree } else { '(op-reason-windows のフォルダーが無いか、読めない)' })"
            Write-Host 'zip の中の並びが変わったか、表の値の書き誤り。どちらかを確かめるまで入れない'
            return $false
        }
        if ($BeforeSwap -and -not [bool](@(& $BeforeSwap)[-1])) {
            Write-Host '置き場所は何も変えていない'
            return $false
        }
        $existed = Test-Path -LiteralPath $InstallDir
        if ($existed) {
            try {
                Move-OpReasonDirectory -Source $InstallDir -Destination $old
            } catch {
                Write-Host "置けなかった: $($_.Exception.Message)"
                Write-Host 'op の呼び出し (op-reason.exe か launcher.ps1) が動いていれば、終わってから打ち直す (何も変えていない)'
                return $false
            }
        }
        try {
            Move-OpReasonDirectory -Source $content -Destination $InstallDir
        } catch {
            Write-Host "置けなかった: $($_.Exception.Message)"
            if ($existed) {
                try {
                    Move-OpReasonDirectory -Source $old -Destination $InstallDir
                    Write-Host '前の中身に戻した (何も変えていない)。打ち直す'
                } catch {
                    $keepOld = $true
                    Write-Host "前の中身を戻せなかった: $($_.Exception.Message)"
                    Write-Host "前の中身は $old に残してある。Install-OpReason を打ち直せば入る (setup --update でも入る)"
                }
            } else {
                Write-Host '何も変えていない。打ち直す'
            }
            return $false
        }
        Write-Host "置いた: $InstallDir"
        return $true
    } finally {
        Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $keepOld) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
        if ($createdParent -and -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-InstallOpReason {
    param([string]$Version, [switch]$Check, [string]$InstallDir, [string]$SshRelay = '')
    $releases = Get-OpReasonReleases
    if (-not $releases.Contains($Version)) {
        Write-Host "版 $Version の SHA-256 が Install-OpReason.ps1 の表 (Get-OpReasonReleases) に無い。表にある版: $(@($releases.Keys) -join ', ')"
        return 2
    }
    if ($SshRelay -and -not (Test-OpReasonSettingsVersion -Installed $Version)) {
        Write-Host "-SshRelay は 0.7.0 からの版で使う (SSH の中継の task を op-reason.exe --settings で揃えるため)。-Version $Version には渡さない"
        return 2
    }
    if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\op-reason' }
    # 相対パスで渡されても、今の場所 (PowerShell の location) から解いた絶対パスにする。
    # [IO.File] などの .NET はプロセスの作業ディレクトリで解くので、相対のまま渡すと別の所を見る
    $InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir).TrimEnd('\', '/')
    $exe = Join-Path $InstallDir 'op-reason.exe'
    $fix = if ($SshRelay) { "Install-OpReason -SshRelay $SshRelay" } else { 'Install-OpReason' }
    $modes = @('per-call', 'show-only')

    $state = Get-OpReasonState -InstallDir $InstallDir -Target $Version -Releases $releases
    $relay = Get-OpReasonRelayView -Want $SshRelay -State $state -Exe $exe -InstallDir $InstallDir
    # 入れ替えの前に止めるもの。置き場所から動いている op-reason.exe があり、中継の task があれば、答えている中継の持ち主を読む
    $swap = 'swap'
    $relayPid = $null
    $blocked = $false
    if ($state.Plan -eq 'change') {
        $busyIds = @(Get-OpReasonBusyProcess -InstallDir $InstallDir | ForEach-Object { $_.Id })
        $legacyRunning = [bool]($relay.Legacy -and ($relay.Legacy.State -eq 'Running'))
        $ownActive = [bool]($relay.Own -and ($relay.Own.Enabled -or ($relay.Own.State -eq 'Running')))
        $owner = 'none'
        if ((($busyIds.Count -gt 0) -and ($relay.Own -or $relay.Legacy)) -or ($ownActive -and $relay.Capable)) {
            $o = Get-OpReasonRelayOwnerNow -Exe $exe -Capable $relay.Capable -LegacyRunning $legacyRunning
            $owner = $o.Owner
            $relayPid = $o.Pid
        }
        $swap = Get-OpReasonSwapAction -Plan $state.Plan -Busy $busyIds -RelayPid $relayPid -Owner $owner -OwnActive $ownActive -Capable $relay.Capable
        # op-reason の task は --task を渡すので、0.7.0 より前の版には入れ替えない (task の中継が起きなくなる)
        $blocked = [bool]($relay.Own -and -not (Test-OpReasonSettingsVersion -Installed $Version))
    }
    Write-OpReasonState -State $state -Target $Version -InstallDir $InstallDir -BusyNote $(if ($swap -in 'stop-legacy', 'stop-own') { 'relay' } else { '' })
    if ($relay.Shown) {
        Write-OpReasonRows -Rows (Format-OpReasonRelayState -Want $SshRelay -View $relay -Installed $state.Exists)
    }
    if ($blocked) {
        Write-Host '※ op-reason の task があるので、0.7.0 より前の版には入れ替えない (先に op-reason.exe --settings set relay.autostart=off で task を消す)'
    }
    $code = Get-OpReasonExitCode -State $state -RelayPlan $relay.Plan

    # -Check は何も変えない (task と check を見るだけ)
    if ($Check) {
        switch ($code) {
            0 { Write-Host '揃っている' }
            2 { Write-Host '⚠️ SSH の中継を確かめられない (op-reason.exe --settings check) → 上の「設定」の行のわけを見る ⚠️' -ForegroundColor Yellow }
            3 { Write-Host "⚠️ op-reason が入っていない → $fix で入れる ⚠️" -ForegroundColor Yellow }
            default {
                if ($state.Plan -eq 'none') {
                    Write-Host "⚠️ SSH の中継が揃っていない → $fix で揃える ⚠️" -ForegroundColor Yellow
                } else {
                    Write-Host "⚠️ 固定した版と揃っていない → $fix で揃える ⚠️" -ForegroundColor Yellow
                }
            }
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }
    if ($code -eq 2) {
        Write-Host 'SSH の中継を確かめられないので、何も変えない (上の「設定」の行のわけを見る)'
        return 2
    }
    if ($blocked) { return 1 }
    if ($swap -eq 'busy') {
        Write-Host 'op-reason.exe が動いていて置き場所を入れ替えられない。op の呼び出しが終わってから打ち直す (このスクリプトは止めない):'
        foreach ($p in @(Get-OpReasonBusyProcess -InstallDir $InstallDir)) {
            Write-Host "  $($p.Id)  $($p.Path)"
        }
        return 1
    }

    # 前の task の中継を lock を取って止めたら、起こし直すか移すまで lock を持つ (op-reason.exe --settings は自分で lock を取るので、
    # それを打つ前に放す)
    $relayCtx = @{ Lock = $null; LegacyStopped = $false; OwnStopped = $false }
    $result = 0
    # 置き場所の exe が固定した版か (入れ替えたら $true。入れ替えが落ちたら前の中身のまま)
    $current = $state.Plan -eq 'none'
    # 前の task を op-reason の task に移す途中か (無効にして止めてあり、op-reason の set が通ったら消す)
    $moving = $false
    try {
        if ($state.Plan -ne 'none') {
            # 落として確かめてから止める (落とす間は止めず、op の呼び出しを待たせない)
            $before = $null
            if ($swap -eq 'stop-legacy') { $before = { Stop-OpReasonLegacyRelayLocked -Ctx $relayCtx -RelayPid $relayPid } }
            if ($swap -eq 'stop-own') { $before = { Stop-OpReasonOwnRelay -Ctx $relayCtx -Exe $exe } }
            $saved = Save-OpReason -Url (Get-OpReasonDownloadUrl -Version $Version) -ExpectedZip $releases[$Version].Zip -ExpectedTree $releases[$Version].Tree -InstallDir $InstallDir -BeforeSwap $before
            if ($saved) { $current = $true } else { $result = 1 }
        }
        # 前の task は、-SshRelay を渡されたら止めて消す (1 回だけの移し)。off なら入れ替えが落ちても消す (中継を止めるのが望む形)。
        # モードなら、入れた版で op-reason の task を作れるときだけ移す (消すのは set が通った後)
        if ($relay.Plan.Legacy -eq 'remove') {
            if ($SshRelay -eq 'off') {
                if (Stop-OpReasonLegacyForMove -Ctx $relayCtx -Exe $exe -Capable $relay.Capable) {
                    Remove-OpReasonLegacyTask -Ctx $relayCtx -Why 'SSH の中継は止まっている'
                } else {
                    $result = 1
                }
            } elseif (($result -eq 0) -and $current) {
                if (Stop-OpReasonLegacyForMove -Ctx $relayCtx -Exe $exe -Capable $true) { $moving = $true } else { $result = 1 }
            }
        }
        # 止めたままの前の task の中継 (-SshRelay を渡さない入れ替え・入れ替えが落ちた) は、lock を持ったまま起こし直す
        if ($relayCtx.LegacyStopped -and -not $moving) {
            if (-not (Start-OpReasonLegacyRelay -Exe $exe)) { $result = 1 }
            $relayCtx.LegacyStopped = $false
        }
    } finally {
        Exit-OpReasonLock -Lock $relayCtx.Lock
        $relayCtx.Lock = $null
    }

    # op-reason の task と中継 (op-reason.exe --settings)
    $done = $false
    if ($relay.InScope) {
        $act = ''
        if ($SshRelay -in $modes) {
            # set は 2 回打っても変わらないので、揃える流れでは毎回打つ (入れ替えで止めた中継も、relay.running=on で起こす)
            if (($result -eq 0) -and $current) { $act = 'set' } elseif ($relayCtx.OwnStopped) { $act = 'start' }
        } elseif ($SshRelay -eq 'off') {
            if ($relay.Own) { $act = 'off' }
        } elseif ($relayCtx.OwnStopped) {
            $act = 'start'
        }
        if ($act) {
            $capable = if ($current) { Test-OpReasonSettingsVersion -Installed $Version } else { $relay.Capable }
            if (-not $capable) {
                Write-Host "入っている op-reason.exe は --settings を持たないので、op-reason の task に触れない (op-reason.exe --settings を打たない)"
                $result = 1
            } elseif (Invoke-OpReasonSettingsAct -Exe $exe -Act $act -Mode $SshRelay) {
                $done = $true
            } else {
                $result = 1
            }
        }
    }
    # 移す途中の前の task: set が通れば消す。通らなくても op-reason の task ができていれば消し (task を 2 つ残さない。op-reason の
    # task が 1 分のうちに中継を起こし直す)、できていなければ前の task を起こし直す (次の apply が移す)
    if ($moving) {
        if ($done) {
            Remove-OpReasonLegacyTask -Ctx $relayCtx -Why 'op-reason の task に移した'
        } elseif ($relay.InScope -and (Get-OpReasonTask -Path '\' -Name $relay.OwnName)) {
            Remove-OpReasonLegacyTask -Ctx $relayCtx -Why 'op-reason の task はできた。中継はその task が起こし直す'
        } else {
            Write-Host 'op-reason の task を作れなかったので、前の task に戻す'
            if (-not (Start-OpReasonLegacyRelay -Exe $exe)) { $result = 1 }
            $relayCtx.LegacyStopped = $false
        }
    }
    if ($result -ne 0) { return $result }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-OpReasonState -InstallDir $InstallDir -Target $Version -Releases $releases
    $relayAfter = Get-OpReasonRelayView -Want $SshRelay -State $after -Exe $exe -InstallDir $InstallDir
    Write-OpReasonState -State $after -Target $Version -InstallDir $InstallDir
    if ($relayAfter.Shown) {
        Write-OpReasonRows -Rows (Format-OpReasonRelayState -Want $SshRelay -View $relayAfter -Installed $after.Exists)
    }
    if ((Get-OpReasonExitCode -State $after -RelayPlan $relayAfter.Plan) -eq 0) {
        Write-Host '揃った'
        return 0
    }
    return 1
}

# dot-source されたとき (テスト) は関数だけを読み、本体は走らせない。
# 思わぬ例外は受け止めて終了コード 2 で終える。受け止めないと exit まで届かず、
# -Command から呼んだとき外側の exit $LASTEXITCODE が中の外部コマンドの 0 を返して成功に見える
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    try {
        exit (Invoke-InstallOpReason -Version $Version -Check:$Check -InstallDir $InstallDir -SshRelay $SshRelay)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
