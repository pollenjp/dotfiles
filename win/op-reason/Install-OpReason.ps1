<#
.SYNOPSIS
Windows の op-reason (pollenjp/op-reason の GitHub の Release の op-reason-windows.zip) を、決めた版に揃える。

.DESCRIPTION
dotfiles の win/op-reason/Install-OpReason.ps1 を %USERPROFILE%\.config\powershell\ へ配り、
PowerShell では dotfiles.ps1 の Install-OpReason から呼ぶ (win/README.md の「op-reason」)。

op-reason は 1Password CLI (op) の wrapper (自作の OSS)。WSL の op (dotfiles の home/modules/op-reason.nix が入れる、Release の
Linux の実行ファイル) は、呼び出しごとに Windows の op-reason.exe (動かないときは隣の launcher.ps1) を起こして承認の窓を出す。
その Windows の部品が op-reason-windows.zip (op-reason.exe・launcher.ps1・powershell-entry\・SKILL.md・README・ライセンス) で、
WSL の実行ファイルと同じ版にそろえる (呼び出しの取り決め (payload の版) が変わった版どうしでは断られる。0.1.0 から 0.3.0 まで同じ取り決め)。

固定した版の zip を GitHub の Release から落とし、SHA-256 が表 (Get-OpReasonReleases) の Zip と合うときだけ隣に展開し、
展開した中身が表の Tree と合えば %LOCALAPPDATA%\Programs\op-reason と入れ替える。合わなければ何も変えずに止まる。
WSL の op は、この置き場所の op-reason.exe を OPREASON_EXE で指す (home/modules/op-reason.nix)。Windows の PATH には足さない。

入っている版は、置き場所の中身の Tree (全部のファイルの SHA-256 と相対パスから作る値。Get-OpReasonTreeHash) を表と
突き合わせて決める。op-reason.exe は署名が無く Smart App Control に止められうるので、--version は聞かない。
動いている op-reason.exe (op の呼び出しの途中) があると置き場所を入れ替えられないので、入れ替えが要るときに動いていれば、
何も変えずに止まって知らせる (止めはしない。承認を待っている途中かもしれないため)。記録 (%LOCALAPPDATA%\op-reason) には
触らない。

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
#>
[CmdletBinding()]
param(
    [string]$Version = '0.3.0',
    [switch]$Check,
    [string]$InstallDir = ''
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

# 終了コード。入っていなければ 3、版が揃っていれば 0、ほかは 1
function Get-OpReasonExitCode {
    param($State)
    if ($State.Plan -eq 'install') { return 3 }
    if ($State.Plan -eq 'none') { return 0 }
    1
}

# 揃える前に止める理由。無ければ $null
#   busy: 入れ替えるのに、置き場所の op-reason.exe が動いている (op の呼び出しの途中で、置き場所を入れ替えられない)
function Get-OpReasonApplyBlocker {
    param([string]$Plan, [int]$BusyCount)
    if (($Plan -eq 'change') -and ($BusyCount -gt 0)) { return 'busy' }
    $null
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
# ほかは 2 字下げる。ずれそのものではないこと (動いている op-reason.exe がある) は ※ で添える
function Format-OpReasonState {
    param($State, [string]$Target, [string]$InstallDir)
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
        [pscustomobject]@{ Text = "※ op-reason.exe が $($State.BusyCount) 個動いている (op の呼び出しの途中)。入れ替えるには、その呼び出しが終わってから打ち直す (このスクリプトは止めない)"; Warn = $false }
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

# 状態の表を出す。直すことがある行 (⚠) は黄色にする
function Write-OpReasonState {
    param($State, [string]$Target, [string]$InstallDir)
    foreach ($row in (Format-OpReasonState -State $State -Target $Target -InstallDir $InstallDir)) {
        if ($row.Warn) { Write-Host $row.Text -ForegroundColor Yellow } else { Write-Host $row.Text }
    }
}

# 固定した版の zip を落として確かめ、展開した中身で置き場所を入れ替える。置けたら $true。
# 置けないときは、わけを出して $false を返し、何も変えない (落とした物と展開した物は消す。入れ替えの途中で落ちたら前の中身に戻す)
function Save-OpReason {
    param([string]$Url, [string]$ExpectedZip, [string]$ExpectedTree, [string]$InstallDir)
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
    param([string]$Version, [switch]$Check, [string]$InstallDir)
    $releases = Get-OpReasonReleases
    if (-not $releases.Contains($Version)) {
        Write-Host "版 $Version の SHA-256 が Install-OpReason.ps1 の表 (Get-OpReasonReleases) に無い。表にある版: $(@($releases.Keys) -join ', ')"
        return 2
    }
    if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\op-reason' }
    # 相対パスで渡されても、今の場所 (PowerShell の location) から解いた絶対パスにする。
    # [IO.File] などの .NET はプロセスの作業ディレクトリで解くので、相対のまま渡すと別の所を見る
    $InstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir).TrimEnd('\', '/')

    $state = Get-OpReasonState -InstallDir $InstallDir -Target $Version -Releases $releases
    Write-OpReasonState -State $state -Target $Version -InstallDir $InstallDir
    $code = Get-OpReasonExitCode -State $state

    # -Check は何も変えない
    if ($Check) {
        switch ($code) {
            0 { Write-Host '揃っている' }
            3 { Write-Host '⚠️ op-reason が入っていない → Install-OpReason で入れる ⚠️' -ForegroundColor Yellow }
            default { Write-Host '⚠️ 固定した版と揃っていない → Install-OpReason で揃える ⚠️' -ForegroundColor Yellow }
        }
        return $code
    }
    if ($code -eq 0) {
        Write-Host '揃っている。何もしない'
        return 0
    }

    if ((Get-OpReasonApplyBlocker -Plan $state.Plan -BusyCount $state.BusyCount) -eq 'busy') {
        Write-Host 'op-reason.exe が動いていて置き場所を入れ替えられない。op の呼び出しが終わってから打ち直す (このスクリプトは止めない):'
        foreach ($p in @(Get-OpReasonBusyProcess -InstallDir $InstallDir)) {
            Write-Host "  $($p.Id)  $($p.Path)"
        }
        return 1
    }

    $saved = Save-OpReason -Url (Get-OpReasonDownloadUrl -Version $Version) -ExpectedZip $releases[$Version].Zip -ExpectedTree $releases[$Version].Tree -InstallDir $InstallDir
    if (-not $saved) { return 1 }

    # 揃ったかを読み直して確かめる
    Write-Host ''
    $after = Get-OpReasonState -InstallDir $InstallDir -Target $Version -Releases $releases
    Write-OpReasonState -State $after -Target $Version -InstallDir $InstallDir
    if ((Get-OpReasonExitCode -State $after) -eq 0) {
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
        exit (Invoke-InstallOpReason -Version $Version -Check:$Check -InstallDir $InstallDir)
    } catch {
        Write-Host "エラーで止まった: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
        exit 2
    }
}
