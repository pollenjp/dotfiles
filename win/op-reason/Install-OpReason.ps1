<#
.SYNOPSIS
Windows の op-reason (pollenjp/op-reason の GitHub の Release の op-reason-windows.zip) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/op-reason/Install-OpReason.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-OpReason から呼ぶ (win/README.md の「op-reason」)。

op-reason は 1Password CLI (op) の wrapper (自作の OSS)。WSL の op (dotfiles の home/modules/op-reason.nix が入れる、Release の
Linux の実行ファイル) は、呼び出しごとに Windows の op-reason.exe (動かないときは隣の launcher.ps1) を起こして承認の窓を出す。
その Windows の部品が op-reason-windows.zip (op-reason.exe・launcher.ps1・powershell-entry\・SKILL.md・README・ライセンス) で、
WSL の実行ファイルと同じ版にそろえる (呼び出しの取り決め (payload の版) が変わった版どうしでは断られる。0.1.0 から 0.5.0 まで同じ取り決め)。

固定した版の zip を GitHub の Release から落とし、SHA-256 が表 (Get-OpReasonReleases) の Zip と合うときだけ隣に展開し、
展開した中身が表の Tree と合えば %LOCALAPPDATA%\Programs\op-reason と入れ替える。合わなければ何も変えずに止まる。
WSL の op は、この置き場所の op-reason.exe を OPREASON_EXE で指す (home/modules/op-reason.nix)。Windows の PATH には足さない。

入っている版は、置き場所の中身の Tree (全部のファイルの SHA-256 と相対パスから作る値。Get-OpReasonTreeHash) を表と
突き合わせて決める。op-reason.exe は署名が無く Smart App Control に止められうるので、--version は聞かない。
動いている op-reason.exe (op の呼び出しの途中) があると置き場所を入れ替えられないので、入れ替えが要るときに動いていれば、
何も変えずに止まって知らせる (止めはしない。承認を待っている途中かもしれないため)。記録 (%LOCALAPPDATA%\op-reason) には
触らない。

SSH の中継 (op-reason.exe --ssh-agent。1Password の SSH agent の前に立ち、鍵を使う呼び出しごとに窓を出す) は、-SshRelay で
logon の task (\pjp\op-reason-ssh-relay) として置いて起こす (win/README.md の「SSH の中継」)。動いている op-reason.exe が
その task の中継だけなら、入れ替えのときに中継を止め、入れ替えてから起こし直す。止めるのは op-reason の lock (Local\op-reason。
中継は窓を開いている間と、呼び出しの最初の依頼が 1Password を待つ間に持つ) を取れたときだけで、取れなければ (窓が開いている)
今までどおり何も変えずに止まる。lock は止めてから起こし直すまで持つ (その間に窓が開かない)。

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
SSH の中継の logon の task をどうするか。per-call・show-only (中継のモード) なら、task を置き (形が違えば置き直し)、中継が
答えなければ起こして、--status が答えるのを 15 秒待つ。off なら、task を止めて消す。どちらも中継が窓を開いている間は止めない。
task の形: 動作は <置き場所>\op-reason.exe --ssh-agent (show-only は --mode show-only を足す)・今のユーザーの logon・Interactive・
Limited・時間の上限なし・電池でも起こして止めない・2 つ目を起こさない・失敗したら 1 分後に起こし直す (999 回まで)・隠す・優先度 5。
WSL の setup (bootstrap-windows-op-reason.sh) が dotfiles.opReason.sshRelay から渡す。渡さなければ (Windows の runner) task を置きも
消しもしない (task の中継を止めて入れ替えて起こし直すのは同じ)。
#>
[CmdletBinding()]
param(
    [string]$Version = '0.5.0',
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

# 終了コード。入っていなければ 3、版と SSH の中継 (Get-OpReasonRelayPlan) が揃っていれば 0、ほかは 1
function Get-OpReasonExitCode {
    param($State, [string]$RelayPlan = 'none')
    if ($State.Plan -eq 'install') { return 3 }
    if (($State.Plan -eq 'none') -and ((-not $RelayPlan) -or ($RelayPlan -eq 'none'))) { return 0 }
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
# BusyNote が relay なら、動いているのは task の SSH の中継だけ (入れ替えるときに止めて起こし直す。Get-OpReasonSwapAction)
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
# SSH の中継 (logon の task) の副作用の無い関数 (Install-OpReason.Tests.ps1 で確かめる)
# ---------------------------------------------------------------------------

# 中継の logon の task の場所と名前
function Get-OpReasonRelayTaskId {
    [pscustomobject]@{ Path = '\pjp\'; Name = 'op-reason-ssh-relay' }
}

# モードごとの中継の引数 (op-reason の README の「Starting it」。per-call は op-reason の既定のモード)
function Get-OpReasonRelayArguments {
    param([string]$Mode)
    if ($Mode -eq 'show-only') { return '--ssh-agent --mode show-only' }
    '--ssh-agent'
}

# 置きたい task の形 (Get-OpReasonRelayTask が読む今の形と同じ欄。Compare-OpReasonRelayTask で比べる)。
#   Trigger   今のユーザーの logon の trigger 1 つなら logon
#   Batteries 電池でも起こし、電池に替わっても止めない
#   Priority  task の既定 (7) は通常より下なので、窓が遅れないよう通常 (5) にする
function Get-OpReasonRelayWant {
    param([string]$Mode, [string]$Exe)
    [pscustomobject]@{
        Execute         = $Exe
        Arguments       = (Get-OpReasonRelayArguments -Mode $Mode)
        Trigger         = 'logon'
        LogonType       = 'Interactive'
        RunLevel        = 'Limited'
        TimeLimit       = 'PT0S'
        Multiple        = 'IgnoreNew'
        RestartCount    = 999
        RestartInterval = 'PT1M'
        Batteries       = $true
        Hidden          = $true
        Priority        = 5
    }
}

# 今の task の形と置きたい形の、違う欄の名前 (欄の順)。無効なら Enabled も。置き場所 (Execute) は大文字小文字を問わない
function Compare-OpReasonRelayTask {
    param($Have, $Want)
    $diff = @()
    foreach ($name in 'Execute', 'Arguments', 'Trigger', 'LogonType', 'RunLevel', 'TimeLimit', 'Multiple', 'RestartCount', 'RestartInterval', 'Batteries', 'Hidden', 'Priority') {
        $h = "$($Have.$name)"
        $w = "$($Want.$name)"
        $same = if ($name -eq 'Execute') { $h -eq $w } else { $h -ceq $w }
        if (-not $same) { $diff += $name }
    }
    if (-not $Have.Enabled) { $diff += 'Enabled' }
    $diff
}

# --status の出力から、答えた中継の PID。答えていなければ (終了コード 0 でない・PID の無い文) $null
function ConvertFrom-OpReasonRelayStatus {
    param([int]$Code, [string]$Text)
    if ($Code -ne 0) { return $null }
    if ($Text -match '\(pid (\d+)\)') { return [int]$Matches[1] }
    $null
}

# 中継にすること。Want は -SshRelay の値 ('' は runner: task に触らない)
#   none 何もしない・register task を置いて起こす・update 置き直して起こし直す・start 起こす・restart 止めて起こし直す
#   (動いているのに答えない)・remove 止めて消す
function Get-OpReasonRelayPlan {
    param([string]$Want, $Task, [string[]]$Diff, $RelayPid)
    if (-not $Want) { return 'none' }
    if ($Want -eq 'off') {
        if ($Task) { return 'remove' }
        return 'none'
    }
    if (-not $Task) { return 'register' }
    if (@($Diff).Count -gt 0) { return 'update' }
    if (-not $RelayPid) {
        if ($Task.State -eq 'Running') { return 'restart' }
        return 'start'
    }
    'none'
}

# 置き場所を入れ替える前にすること。swap 止めるものが無い・stop-relay 動いている op-reason.exe が task の中継 (--status の PID) だけ
# (lock を取れたら止める)・busy ほかの op-reason.exe か、task の外の中継が動いている (止めずに知らせる)
function Get-OpReasonSwapAction {
    param([string]$Plan, [int[]]$Busy, $RelayPid, [bool]$TaskRunning)
    if ($Plan -ne 'change') { return 'swap' }
    $ids = @($Busy)
    if ($ids.Count -eq 0) { return 'swap' }
    if ($RelayPid -and $TaskRunning -and ($ids.Count -eq 1) -and ($ids[0] -eq $RelayPid)) { return 'stop-relay' }
    'busy'
}

# 状態の表の中継の行 (見出し・望む形・task・中継)。中継の行は、モードを望むときか task があるときだけ
function Format-OpReasonRelayState {
    param([string]$Want, $Task, [string[]]$Diff, $RelayPid, [string]$Plan)
    $id = Get-OpReasonRelayTaskId
    $wantText = switch ($Want) {
        'per-call' { 'per-call (op-reason.exe --ssh-agent)' }
        'show-only' { 'show-only (op-reason.exe --ssh-agent --mode show-only)' }
        'off' { '置かない (-SshRelay off)' }
        default { '決めない (-SshRelay なし。task には触らない)' }
    }
    $taskState = if (-not $Task) { '無い' }
    elseif ($Task.State -eq 'Running') { 'ある (動いている)' }
    elseif ($Task.State -eq 'Disabled') { 'ある (無効)' }
    else { 'ある (止まっている)' }
    $taskWarn = $false
    switch ($Plan) {
        'register' { $taskState = '無い → 置いて起こす'; $taskWarn = $true }
        'update' { $taskState = "形が違う ($(@($Diff) -join '・')) → 置き直して起こし直す"; $taskWarn = $true }
        'remove' { $taskState = "$taskState → 止めて消す"; $taskWarn = $true }
    }
    $relayWarn = $Plan -in 'start', 'restart'
    $relayState = if ($RelayPid) { "答えている (pid $RelayPid)" } elseif ($Plan -eq 'start') { '答えない → 起こす' } elseif ($Plan -eq 'restart') { '答えない → 起こし直す' } else { '答えない' }
    $rows = @(
        @{ Text = "SSH の中継 (logon の task $($id.Path)$($id.Name))"; Warn = $false; Indent = $false }
        @{ Text = "望む形           : $wantText"; Warn = $false; Indent = $true }
        @{ Text = "task             : $taskState"; Warn = $taskWarn; Indent = $true }
    )
    if (($Want -in 'per-call', 'show-only') -or $Task) {
        $rows += @{ Text = "中継             : $relayState"; Warn = $relayWarn; Indent = $true }
    }
    foreach ($row in $rows) {
        $prefix = if (-not $row.Indent) { '' } elseif ($row.Warn) { '⚠ ' } else { '  ' }
        [pscustomobject]@{ Text = "$prefix$($row.Text)"; Warn = [bool]$row.Warn }
    }
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

# 中継の task の今の形 (Get-OpReasonRelayWant と同じ欄に Enabled と State を足したもの)。無ければ $null。
# ScheduledTasks の module が無い (Linux の pwsh の試験) ときも $null
function Get-OpReasonRelayTask {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
    $id = Get-OpReasonRelayTaskId
    $t = Get-ScheduledTask -TaskPath $id.Path -TaskName $id.Name -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $action = @($t.Actions)[0]
    $triggers = @($t.Triggers)
    # logon の trigger 1 つで、今のユーザーのもの (DOMAIN\ の有る無しは問わない) なら logon。ほかは trigger の種類を並べる
    $me = ([Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1]
    $trigger = (@($triggers | ForEach-Object { $_.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', '' }) -join '+')
    if (($triggers.Count -eq 1) -and ($triggers[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') -and
        (("$($triggers[0].UserId)" -split '\\')[-1] -eq $me)) {
        $trigger = 'logon'
    }
    $s = $t.Settings
    [pscustomobject]@{
        Execute         = "$($action.Execute)"
        Arguments       = "$($action.Arguments)"
        Trigger         = $trigger
        LogonType       = "$($t.Principal.LogonType)"
        RunLevel        = "$($t.Principal.RunLevel)"
        TimeLimit       = "$($s.ExecutionTimeLimit)"
        Multiple        = "$($s.MultipleInstances)"
        RestartCount    = [int]$s.RestartCount
        RestartInterval = "$($s.RestartInterval)"
        Batteries       = (-not $s.DisallowStartIfOnBatteries) -and (-not $s.StopIfGoingOnBatteries)
        Hidden          = [bool]$s.Hidden
        Priority        = [int]$s.Priority
        Enabled         = [bool]$s.Enabled
        State           = "$($t.State)"
    }
}

# 中継の task を置きたい形で置く (あれば置き直す)。権限は上げない (今のユーザーの Interactive・Limited)
function Register-OpReasonRelayTask {
    param($Want)
    $id = Get-OpReasonRelayTaskId
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $Want.Execute -Argument $Want.Arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount $Want.RestartCount -RestartInterval ([Xml.XmlConvert]::ToTimeSpan($Want.RestartInterval)) `
        -Hidden -Priority $Want.Priority
    Register-ScheduledTask -TaskPath $id.Path -TaskName $id.Name -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force `
        -Description 'op-reason の SSH の中継 (dotfiles の Install-OpReason.ps1 -SshRelay が置く。-SshRelay off で消す。win/README.md の「SSH の中継」)' |
        Out-Null
}

function Unregister-OpReasonRelayTask {
    $id = Get-OpReasonRelayTaskId
    Unregister-ScheduledTask -TaskPath $id.Path -TaskName $id.Name -Confirm:$false
}

function Start-OpReasonRelayTask {
    $id = Get-OpReasonRelayTaskId
    Start-ScheduledTask -TaskPath $id.Path -TaskName $id.Name
}

function Stop-OpReasonRelayTask {
    $id = Get-OpReasonRelayTaskId
    Stop-ScheduledTask -TaskPath $id.Path -TaskName $id.Name
}

# task を有効・無効にする (無効の間は、失敗したときの起こし直しも trigger も起こさない)
function Set-OpReasonRelayTaskEnabled {
    param([bool]$Enabled)
    $id = Get-OpReasonRelayTaskId
    if ($Enabled) {
        Enable-ScheduledTask -TaskPath $id.Path -TaskName $id.Name | Out-Null
    } else {
        Disable-ScheduledTask -TaskPath $id.Path -TaskName $id.Name | Out-Null
    }
}

# 既定の pipe で答える中継の PID (op-reason.exe --ssh-agent --status)。答えない・起こせないときは $null
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

# task の中継を止める (lock を持っている前提)。task を無効にしてから止め (起こし直しを起こさない)、プロセスが終わるのを
# 10 秒待つ。終われば $true。終わらなければ task を有効に戻して $false
function Stop-OpReasonRelay {
    param($RelayPid)
    Set-OpReasonRelayTaskEnabled -Enabled $false
    Stop-OpReasonRelayTask
    if ($RelayPid -and -not (Wait-OpReasonProcessExit -Id $RelayPid -Seconds 10)) {
        Set-OpReasonRelayTaskEnabled -Enabled $true
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

# 中継の今の様子 (task・答える PID・計画)。Want は -SshRelay の値
function Get-OpReasonRelayView {
    param([string]$Want, $State, [string]$Exe)
    $task = Get-OpReasonRelayTask
    $wantShape = $null
    if ($Want -in 'per-call', 'show-only') { $wantShape = Get-OpReasonRelayWant -Mode $Want -Exe $Exe }
    $diff = @()
    if ($task -and $wantShape) { $diff = @(Compare-OpReasonRelayTask -Have $task -Want $wantShape) }
    # --status は置き場所の op-reason.exe で聞く。task も望む形も無ければ聞かない (中継を使わないホストでは今までどおり)
    $relayPid = $null
    if (($task -or $wantShape) -and $State.Exists) { $relayPid = Get-OpReasonRelayPid -Exe $Exe }
    [pscustomobject]@{
        Task  = $task
        Want  = $wantShape
        Diff  = $diff
        Pid   = $relayPid
        Plan  = (Get-OpReasonRelayPlan -Want $Want -Task $task -Diff $diff -RelayPid $relayPid)
        Shown = [bool]($Want -or $task)
    }
}

# task の中継を、lock を取ってから止める。止めたら $true (lock は $Ctx.Lock に残し、起こし直すまで持つ)。
# lock を取れない (中継が窓を開いている・1Password の確認を待っている) か、止まらなければ、わけを出して $false
function Stop-OpReasonRelayLocked {
    param($Ctx, $RelayPid)
    if (-not $Ctx.Lock) { $Ctx.Lock = Enter-OpReasonLock }
    if (-not $Ctx.Lock) {
        Write-Host 'SSH の中継が窓を開いている (か、1Password の確認を待っている) ので、中継を止めない。窓に答えてから打ち直す (このスクリプトは止めない)'
        return $false
    }
    if (-not (Stop-OpReasonRelay -RelayPid $RelayPid)) {
        Write-Host "SSH の中継 (pid $RelayPid) が 10 秒たっても止まらなかった。中継は動いたまま (task は有効に戻した)"
        return $false
    }
    $Ctx.Stopped = $true
    $true
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
    if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\op-reason' }
    # 相対パスで渡されても、今の場所 (PowerShell の location) から解いた絶対パスにする。
    # [IO.File] などの .NET はプロセスの作業ディレクトリで解くので、相対のまま渡すと別の所を見る
    $InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir).TrimEnd('\', '/')
    $exe = Join-Path $InstallDir 'op-reason.exe'
    $fix = if ($SshRelay) { "Install-OpReason -SshRelay $SshRelay" } else { 'Install-OpReason' }

    $state = Get-OpReasonState -InstallDir $InstallDir -Target $Version -Releases $releases
    $relay = Get-OpReasonRelayView -Want $SshRelay -State $state -Exe $exe
    # 入れ替えの前に止めるもの。動いている op-reason.exe が task の SSH の中継だけなら、止めて入れ替えて起こし直す
    $swap = 'swap'
    if ($state.Plan -eq 'change') {
        $busyIds = @(Get-OpReasonBusyProcess -InstallDir $InstallDir | ForEach-Object { $_.Id })
        $taskRunning = [bool]($relay.Task -and ($relay.Task.State -eq 'Running'))
        $swap = Get-OpReasonSwapAction -Plan $state.Plan -Busy $busyIds -RelayPid $relay.Pid -TaskRunning $taskRunning
    }
    Write-OpReasonState -State $state -Target $Version -InstallDir $InstallDir -BusyNote $(if ($swap -eq 'stop-relay') { 'relay' } else { '' })
    if ($relay.Shown) {
        Write-OpReasonRows -Rows (Format-OpReasonRelayState -Want $SshRelay -Task $relay.Task -Diff $relay.Diff -RelayPid $relay.Pid -Plan $relay.Plan)
    }
    $code = Get-OpReasonExitCode -State $state -RelayPlan $relay.Plan

    # -Check は何も変えない (task と --status を見るだけ)
    if ($Check) {
        switch ($code) {
            0 { Write-Host '揃っている' }
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

    if ($swap -eq 'busy') {
        Write-Host 'op-reason.exe が動いていて置き場所を入れ替えられない。op の呼び出しが終わってから打ち直す (このスクリプトは止めない):'
        foreach ($p in @(Get-OpReasonBusyProcess -InstallDir $InstallDir)) {
            Write-Host "  $($p.Id)  $($p.Path)"
        }
        return 1
    }

    # 中継を止めたら (lock を取り、task を無効にした)、起こし直すまで lock を持つ
    $relayCtx = @{ Lock = $null; Stopped = $false }
    $relayPid = $relay.Pid
    $relayUp = [bool]($relayPid -or ($relay.Task -and ($relay.Task.State -eq 'Running')))
    $result = 0
    $start = $false
    try {
        if ($state.Plan -ne 'none') {
            # 落として確かめてから止める (落とす間は lock を持たず、op の呼び出しを待たせない)
            $before = $null
            if ($swap -eq 'stop-relay') { $before = { Stop-OpReasonRelayLocked -Ctx $relayCtx -RelayPid $relayPid } }
            $saved = Save-OpReason -Url (Get-OpReasonDownloadUrl -Version $Version) -ExpectedZip $releases[$Version].Zip -ExpectedTree $releases[$Version].Tree -InstallDir $InstallDir -BeforeSwap $before
            if (-not $saved) { $result = 1 }
        }

        if (($result -eq 0) -and ($SshRelay -in 'per-call', 'show-only')) {
            # 形が替わった・動いているのに答えない中継は、止めてから置き直して起こす (動いている中継はモードが替わらない)
            if (($relay.Plan -in 'update', 'restart') -and $relayUp -and -not $relayCtx.Stopped) {
                if (-not (Stop-OpReasonRelayLocked -Ctx $relayCtx -RelayPid $relayPid)) { $result = 1 }
            }
            if ($result -eq 0) {
                if ($relay.Plan -in 'register', 'update') {
                    Register-OpReasonRelayTask -Want $relay.Want
                    $id = Get-OpReasonRelayTaskId
                    Write-Host "logon の task を置いた: $($id.Path)$($id.Name) ($($relay.Want.Execute) $($relay.Want.Arguments))"
                }
                $start = $true
            }
        } elseif (($result -eq 0) -and ($SshRelay -eq 'off') -and $relay.Task) {
            if ($relayUp -and -not $relayCtx.Stopped) {
                if (-not (Stop-OpReasonRelayLocked -Ctx $relayCtx -RelayPid $relayPid)) { $result = 1 }
            }
            if ($result -eq 0) {
                Unregister-OpReasonRelayTask
                $relayCtx.Stopped = $false
                Write-Host 'logon の task を消した (SSH の中継は止まっている)'
            }
        }

        # 止めた中継 (入れ替えが落ちたときも、前の中身のまま) と、置いた task を起こし、答えるのを見る
        if ($relayCtx.Stopped -or $start) {
            if ($relayCtx.Stopped) { Set-OpReasonRelayTaskEnabled -Enabled $true }
            $id = Get-OpReasonRelayTaskId
            Write-Host "SSH の中継を起こす (task $($id.Path)$($id.Name))"
            Start-OpReasonRelayTask
            $relayCtx.Stopped = $false
            $answered = Wait-OpReasonRelayPid -Exe $exe -Seconds 15
            if ($answered) {
                Write-Host "SSH の中継が答えた (pid $answered)"
            } else {
                Write-Host "SSH の中継が答えない (15 秒待った)。op-reason.exe が止められていないか (Smart App Control など)、task の最後の結果 (Get-ScheduledTaskInfo -TaskPath '$($id.Path)' -TaskName '$($id.Name)') を見る"
                $result = 1
            }
        }
    } finally {
        Exit-OpReasonLock -Lock $relayCtx.Lock
    }
    if ($result -ne 0) { return $result }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-OpReasonState -InstallDir $InstallDir -Target $Version -Releases $releases
    $relayAfter = Get-OpReasonRelayView -Want $SshRelay -State $after -Exe $exe
    Write-OpReasonState -State $after -Target $Version -InstallDir $InstallDir
    if ($relayAfter.Shown) {
        Write-OpReasonRows -Rows (Format-OpReasonRelayState -Want $SshRelay -Task $relayAfter.Task -Diff $relayAfter.Diff -RelayPid $relayAfter.Pid -Plan $relayAfter.Plan)
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
